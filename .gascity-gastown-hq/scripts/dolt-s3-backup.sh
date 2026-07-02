#!/bin/bash
# dolt-s3-backup.sh — OFF-BOX (S3) backup of the city's Dolt bead stores.
#
# WHY: the single Dolt server (port from gc dolt status) holds every rig's beads —
# issues, mail, work history, and sensitive debt/CPF work. `gc doctor` flagged that
# NO off-box backup existed: a disk/host loss would lose it all. This closes that gap.
#
# MECHANISM (empirically chosen for Dolt 2.1.8 — see the header of the commit / report):
#   Dolt 2.1.8 does NOT accept a plain s3:// backup URL ("unknown url scheme: 's3'"),
#   and its aws:// scheme REQUIRES a DynamoDB manifest table (extra infra + couples
#   restore to DynamoDB). So we use the canonical Gas Town two-stage pattern, off-boxed
#   to S3 instead of iCloud:
#     1. native, transactionally-consistent  CALL DOLT_BACKUP('sync', <db>-backup)
#        -> a LOCAL file:// staging store at .dolt-backup/<db> (also what gc doctor
#        checks for; kept because it makes both stages INCREMENTAL and enables an
#        instant local restore). Dolt GCs on backup, so staging << live noms.
#     2. aws s3 sync .dolt-backup/<db>/ -> s3://<bucket>/<db>/  (incremental; --delete
#        prunes orphans; bucket VERSIONING retains history so a stable prefix gives
#        point-in-time recovery without a full copy per day).
#
# SAFETY: READ + export only. Never stops/restarts Dolt, never touches a live .dolt or
# noms/LOCK. If the server is unreachable it SKIPS (never restarts). Silent on success
# (Athos preference); notifies via `notify` only on failure. Bounded by per-db timeouts
# and a single-instance lock. Restore procedure: see RESTORE section at the bottom.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
DOLT_CFG="$CITY/.gc/runtime/packs/dolt/dolt-config.yaml"
BACKUP_ROOT="$CITY/.dolt-backup"          # local staging (incremental; gc-doctor expects it)
BUCKET="urblink-dolt-backups"
S3="s3://$BUCKET"
LOG="$CITY/.gc/logs/dolt-s3-backup.log"
NOTIFY="/Users/athos/.local/bin/notify"
AWS="$(command -v aws || echo /opt/homebrew/bin/aws)"
DOLT="$(command -v dolt || echo /opt/homebrew/bin/dolt)"
HOST="127.0.0.1"
LOCKDIR="$CITY/.gc/logs/.dolt-s3-backup.lock.d"
LOCK_STALE_MIN=180                        # reclaim a lock older than this (crash recovery)
SYNC_TIMEOUT=600                          # per-db native DOLT_BACKUP sync
S3_TIMEOUT=1200                           # per-db aws s3 sync
PREFLIGHT_TIMEOUT=30                       # server reachability probe

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }
notify_fail() { "$NOTIFY" -t "Dolt S3 backup" -p 4 "🚨 $*" 2>/dev/null || true; }

mkdir -p "$CITY/.gc/logs" "$BACKUP_ROOT" 2>/dev/null || true

# --- single-instance lock (portable; no flock dependency) with staleness reclaim ---
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +"$LOCK_STALE_MIN" 2>/dev/null)" ]; then
    log "reclaiming stale lock (> ${LOCK_STALE_MIN}m): $LOCKDIR"
    rmdir "$LOCKDIR" 2>/dev/null && mkdir "$LOCKDIR" 2>/dev/null || { log "lock race — exiting"; exit 0; }
  else
    log "another run holds the lock — exiting"
    exit 0
  fi
fi
META="$(mktemp)"; RAW="$(mktemp)"
cleanup() { rmdir "$LOCKDIR" 2>/dev/null || true; rm -f "$META" "$RAW" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# --- read the Dolt port from the authoritative config each run (NEVER hardcode) ---
PORT="$(awk '/^listener:/{f=1} f&&/port:/{print $2; exit}' "$DOLT_CFG" 2>/dev/null)"
case "${PORT:-}" in ''|*[!0-9]*) PORT="" ;; esac
if [ -z "$PORT" ]; then   # fallback: LISTEN port of the running dolt sql-server
  PORT="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '/dolt/{n=split($9,a,":"); print a[n]; exit}')"
fi
case "${PORT:-}" in ''|*[!0-9]*) PORT="" ;; esac
if [ -z "$PORT" ]; then log "FATAL: could not determine Dolt port"; notify_fail "backup off-box abortado: porta do Dolt desconhecida"; exit 0; fi

dsql() { DOLT_CLI_PASSWORD='' "$DOLT" --host "$HOST" --port "$PORT" --user root --no-tls sql "$@"; }

log "=== run start (port=$PORT bucket=$BUCKET) ==="

# --- pre-flight: server must be reachable; NEVER touch a hung server ---
if ! DOLT_CLI_PASSWORD='' timeout "$PREFLIGHT_TIMEOUT" "$DOLT" --host "$HOST" --port "$PORT" \
      --user root --no-tls sql -q "SELECT 1" --result-format csv >/dev/null 2>&1; then
  log "FATAL: Dolt server unreachable on $HOST:$PORT — skipping (NOT restarting)"
  notify_fail "backup off-box: Dolt inacessível em $HOST:$PORT — pulado (sem restart)"
  exit 0
fi

# --- discover all real databases (exclude system schemas) ---
DBS="$(dsql -q "SHOW DATABASES" --result-format csv 2>/dev/null | tail -n +2 \
        | grep -vxE 'information_schema|mysql|dolt')"
if [ -z "$DBS" ]; then log "FATAL: no databases discovered"; notify_fail "backup off-box: nenhum banco descoberto"; exit 0; fi

total=0; ok=0; failed=0; FAILED_DBS=""
for db in $DBS; do
  total=$((total+1))
  dest="$BACKUP_ROOT/$db"
  # ensure the backup remote is registered (idempotent — tolerate "already exists")
  dsql -q "USE \`$db\`; CALL DOLT_BACKUP('add', '${db}-backup', 'file://${dest}');" >/dev/null 2>&1 || true
  # capture the commit we are about to back up BEFORE syncing. On an append-only beads
  # store this pre-sync HEAD is always an ancestor of (or equal to) what the sync
  # captures, so it is GUARANTEED present in the backup — which makes the recorded
  # fingerprint verifiable in a restore ("... issues AS OF '<head>'"). Reading it AFTER
  # the sync instead would race a hot store (e.g. hq) and record a commit newer than
  # the backup actually contains.
  head="$(dsql -q "SELECT commit_hash FROM \`$db\`.dolt_log ORDER BY date DESC LIMIT 1" --result-format csv 2>/dev/null | tail -1)"
  # 1) native consistent backup -> local staging (incremental)
  if ! DOLT_CLI_PASSWORD='' timeout "$SYNC_TIMEOUT" "$DOLT" --host "$HOST" --port "$PORT" \
        --user root --no-tls sql -q "USE \`$db\`; CALL DOLT_BACKUP('sync', '${db}-backup');" >> "$LOG" 2>&1; then
    log "$db: DOLT_BACKUP sync FAILED"; failed=$((failed+1)); FAILED_DBS="$FAILED_DBS ${db}(sync)"; continue
  fi
  # 2) off-box mirror -> S3 (incremental; prune orphans; versioning retains history)
  if ! timeout "$S3_TIMEOUT" "$AWS" s3 sync "$dest/" "$S3/$db/" --delete --only-show-errors >> "$LOG" 2>&1; then
    log "$db: aws s3 sync FAILED"; failed=$((failed+1)); FAILED_DBS="$FAILED_DBS ${db}(s3)"; continue
  fi
  # fingerprint: issue count AS OF the exact captured commit (self-consistent + present
  # in the backup), so a restorer can verify: restore, then COUNT(*) issues AS OF <head>.
  if [ -n "$head" ]; then
    cnt="$(dsql -q "USE \`$db\`; SELECT COUNT(*) FROM issues AS OF '$head'" --result-format csv 2>/dev/null | tail -1)"
  else
    cnt="$(dsql -q "SELECT COUNT(*) FROM \`$db\`.issues" --result-format csv 2>/dev/null | tail -1)"
  fi
  sz="$(du -sh "$dest" 2>/dev/null | awk '{print $1}')"
  case "${cnt:-}" in ''|*[!0-9]*) cnt="-1" ;; esac
  printf '%s\t%s\t%s\t%s\n' "$db" "$cnt" "${head:-}" "${sz:-}" >> "$RAW"
  log "$db: OK (issues=$cnt head=${head:-?} size=${sz:-?})"
  ok=$((ok+1))
done

# --- publish a run fingerprint to S3 (small; latest + dated) ---
RUN_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if "$AWS" --version >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  python3 - "$RAW" "$RUN_UTC" "$PORT" "$ok" "$failed" "$total" > "$META" <<'PY'
import json, sys
raw, run_utc, port, ok, failed, total = sys.argv[1:7]
dbs = {}
try:
    with open(raw) as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) >= 4:
                dbs[p[0]] = {"issues": int(p[1]), "head": p[2], "backup_size": p[3]}
except FileNotFoundError:
    pass
json.dump({"run_utc": run_utc, "port": int(port), "bucket": "urblink-dolt-backups",
           "ok": int(ok), "failed": int(failed), "total": int(total),
           "databases": dbs}, sys.stdout, indent=2)
PY
  "$AWS" s3 cp "$META" "$S3/_meta/latest.json" --only-show-errors >> "$LOG" 2>&1 || true
  "$AWS" s3 cp "$META" "$S3/_meta/$(date -u +%Y%m%d-%H%M%S).json" --only-show-errors >> "$LOG" 2>&1 || true
fi

log "=== run complete: ok=$ok failed=$failed total=$total ==="
if [ "$failed" -gt 0 ]; then
  notify_fail "backup off-box: $failed/$total store(s) FALHARAM:${FAILED_DBS}"
fi
exit 0

# ============================================================================
# RESTORE PROCEDURE (verified working — never touches the live store)
# ----------------------------------------------------------------------------
#   BUCKET=urblink-dolt-backups ; DB=property_scrapers ; SCRATCH=/tmp/dolt-restore
#   rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/pull/$DB"
#   aws s3 sync "s3://$BUCKET/$DB/" "$SCRATCH/pull/$DB/"          # pull backup from S3
#   cd "$SCRATCH"
#   dolt backup restore "file://$SCRATCH/pull/$DB" "restored_$DB" # NO DOLT_CLI_PASSWORD (local CLI)
#   cd "restored_$DB"
#   dolt sql -q "SELECT COUNT(*) FROM issues"                     # verify vs _meta/latest.json
#   dolt sql -q "SELECT commit_hash FROM dolt_log ORDER BY date DESC LIMIT 1"
# To adopt into the live server you would `dolt sql-server`-import the restored dir on a
# SCRATCH data-dir first and reconcile — NEVER overwrite the running .beads/dolt/<db>.
# ============================================================================
