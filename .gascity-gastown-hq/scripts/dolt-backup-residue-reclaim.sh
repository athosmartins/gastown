#!/bin/bash
# dolt-backup-residue-reclaim.sh (ga-8f1uh0) — releases retired
# .dolt-backup/<db>.old residue LEFT BEHIND by dolt-backup-reseed.sh, once S3
# proves it is safe, so no human ever has to run that rm by hand.
#
# ═══ WHY ═══
#
# dolt-backup-reseed.sh (ga-ydrg9) fixes .dolt-backup/<db>'s unbounded growth by
# building a fresh backup, RESTORING it, verifying the row count against the
# live source, and only then swapping it in — but it deliberately never deletes
# the retired copy: "NÃO apagamos o antigo automaticamente. Ele fica em .old
# para um humano remover depois de olhar." That was the right call when the
# mechanism was new and unproven. It has a real cost now: every future reseed
# for a given db REFUSES outright while its own prior .old residue still sits
# there (see dolt-s3-backup.sh's is_stale_residue_refusal) — so without this
# script, each db can self-heal its bloat AT MOST ONCE before going back to
# needing a human, forever, exactly the opposite of what ga-8f1uh0 asks for.
#
# Athos, escalating this bead to P0 (2026-09-16, quoted verbatim on the bead):
# "se tem algo que você consegue dizer que é seguro fazer, inclusive tem
# backup, não deveria ter motivo para você deixar de fazer... seria você agora
# assumir como uma bead P0, como que a nossa própria infraestrutura consegue
# rodar esse comando quando ela identificar que é seguro fazer isso." And, on
# what "safe" means here (relayed by peter-wa, same day): what he approves is
# the CLASS, not the case — "staging de backup com cópia remota verificada
# pode ser liberado pelo sistema", once, for good, never asking him again.
#
# The Mayor's own framing of the boundary this script must respect: the AGENT
# (an LLM, mid-incident, partial context) stays PERMANENTLY barred from
# `rm -rf` on anything under a Dolt-adjacent directory — that guard is what
# keeps a bad day from becoming data loss, and this script does not touch it.
# The INFRASTRUCTURE (this script: deterministic, running as the real user
# under launchd, gated by a hard, auditable, fail-closed precondition) is a
# different capability, and is the one Athos's approval actually grants.
#
# ═══ WHAT ═══
#
# Invoked as a reclaim lever by dolt-disk-floor-guard.sh (ga-gpzr) — i.e. only
# when Dolt's data-dir filesystem (the SAME APFS container .dolt-backup lives
# on) has already crossed its WARN/CRITICAL floor. Pressure-triggered, not
# calendar-triggered (Mayor's ACEITE #1) — a healthy disk means this never
# runs at all, and .old residue is left alone for the settle window below even
# when it does.
#
# For each "$BACKUP_ROOT"/<db>.old directory found:
#   1. Age gate: must be older than RESIDUE_SETTLE_SECS (default 2h) since its
#      own mtime — the swap that created it already passed dolt-backup-
#      reseed.sh's own restore+row-count proof; this is not a safety check,
#      it is a deliberate settle window (a human or another guard cycle gets
#      a look before this becomes irreversible).
#   2. S3 verification (Mayor's ACEITE #2/#6 — "não basta 'existe algo no
#      S3'"), THREE independent checks, ALL required:
#        a. manifest presence — a REAL `aws s3api head-object` on
#           "$db/manifest" (the literal file that makes a Dolt file://
#           backup restorable; probing this directly, not inferring it from
#           a listing, is what "manifest presente" means literally).
#        b. generation — the run that produced $BUCKET/_meta/latest.json
#           must be NEWER than the .old residue's own mtime: proof that the
#           CURRENT (already reseed-verified) backup has been S3-synced at
#           least once since the swap, i.e. the fingerprint describes the
#           replacement, not the retiree.
#        c. size coherence — that fingerprint's recorded backup_size for
#           <db>, converted to bytes, must be within MIN_SIZE_RATIO_PCT
#           (default 50%) of what is ACTUALLY on disk at "$BACKUP_ROOT"/<db>
#           right now — catches a truncated/corrupt upload that still
#           produced a manifest object.
#   3. Only if ALL of the above hold: delete "$BACKUP_ROOT"/<db>.old.
#      Fail-closed by construction (_should_release_residue, pure/tested):
#      any missing/unparseable/stale input returns false, never true.
#
# A settle-window miss (fingerprint not yet fresher than the residue) is
# EXPECTED and self-healing — logged, not alarmed, exactly like dolt-s3-
# backup.sh's own is_disk_margin_refusal framing. A manifest/size-coherence
# miss is a REAL verification gap and notify_fail's, same as dolt-s3-
# backup.sh's is_stale_residue_refusal framing — these are NOT the same
# failure class and must not share one log line (ga-p5q3: error and "not yet"
# must not collapse to the same value).
#
# ═══ IDEMPOTENT + LIMITED (Mayor's ACEITE #5) ═══
#
# Only ever globs "$BACKUP_ROOT"/*.old — structurally cannot reach
# .beads/dolt (live data; a different directory tree entirely), cannot reach
# disk-ballast-guard.sh's ballast file (also a different directory), and the
# real `rm -rf` is additionally guarded by a `case "$old_dir" in
# "$BACKUP_ROOT"/*.old)` pattern immediately before it fires — the same
# defense-in-depth shape dolt-s3-backup.sh's own stale-manifest auto-reinit
# already uses. Running twice on an already-cleared .old is a no-op (the glob
# simply finds nothing).
#
# ═══ SAFETY RAILS (mirrors scratchpad-reaper.sh / transcript-reaper.sh / ═══
# ═══ log-reaper.sh — the other launchd-driven delegate reapers this file's ═══
# ═══ own caller, dolt-disk-floor-guard.sh, already uses) ═══
#
#   DOLT_BACKUP_RESIDUE_RECLAIM_ENABLED=0  → skip entirely (notify-only mode)
#   DOLT_BACKUP_RESIDUE_RECLAIM_DRY_RUN=1  → log what would happen, delete nothing
#   DOLT_BACKUP_RESIDUE_RECLAIM_PROD=1     → REQUIRED, together with BACKUP_ROOT
#                                             resolving to its real default, to
#                                             ever actually delete anything
#                                             (ga-h565g production-sentinel
#                                             pattern: a harness bug that
#                                             leaves BACKUP_ROOT at its real
#                                             default must never be able to
#                                             delete real data just because it
#                                             ALSO forgot to opt in — see
#                                             _prod_sentinel_active).
#
# TEST (hermetic; no real AWS call, no real deletion, no real notify):
#   bash scripts/dolt-backup-residue-reclaim.selftest.sh
# Library mode: `DOLT_BACKUP_RESIDUE_RECLAIM_LIB=1 source dolt-backup-residue-reclaim.sh`
# defines the pure decision functions WITHOUT scanning or deleting anything.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
BACKUP_ROOT_REAL_DEFAULT="$CITY/.dolt-backup"
BACKUP_ROOT="${DOLT_BACKUP_RESIDUE_RECLAIM_BACKUP_ROOT:-$BACKUP_ROOT_REAL_DEFAULT}"
BUCKET="${DOLT_BACKUP_RESIDUE_RECLAIM_BUCKET:-urblink-dolt-backups}"
LOG="${DOLT_BACKUP_RESIDUE_RECLAIM_LOG:-$CITY/.gc/logs/dolt-backup-residue-reclaim.log}"
NOTIFY="${DOLT_BACKUP_RESIDUE_RECLAIM_NOTIFY:-/Users/athos/.local/bin/notify}"
AWS="$(command -v aws || echo /opt/homebrew/bin/aws)"
PY="$(command -v python3 || echo /usr/bin/python3)"

ENABLED="${DOLT_BACKUP_RESIDUE_RECLAIM_ENABLED:-1}"
DRY_RUN="${DOLT_BACKUP_RESIDUE_RECLAIM_DRY_RUN:-0}"
PROD="${DOLT_BACKUP_RESIDUE_RECLAIM_PROD:-0}"

# 2h default: not a safety requirement (the swap that produced .old already
# passed dolt-backup-reseed.sh's own restore+row-count proof before this
# script ever sees it) but a deliberate settle window — gives a human or
# another guard cycle a look at fresh residue before it becomes irreversible.
# Pressure-gated by the caller (dolt-disk-floor-guard.sh only calls this at/
# below its own floor), so a healthy disk never even reaches this clock.
SETTLE_SECS="${DOLT_BACKUP_RESIDUE_RECLAIM_SETTLE_SECS:-7200}"

# How far the S3 fingerprint's recorded backup_size for <db> is allowed to
# fall below what is actually on disk right now before treating the upload as
# incoherent (truncated/corrupt) rather than merely "grew a bit since the
# fingerprint was captured" (the city never stops writing). 50% is generous
# to normal growth/shrink drift while still catching a gross mismatch.
MIN_SIZE_RATIO_PCT="${DOLT_BACKUP_RESIDUE_RECLAIM_MIN_SIZE_RATIO_PCT:-50}"

AWS_TIMEOUT_SECS="${DOLT_BACKUP_RESIDUE_RECLAIM_AWS_TIMEOUT_SECS:-20}"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }
notify_fail() { "$NOTIFY" -t "Dolt backup residue reclaim" -p 4 "🚨 $*" 2>/dev/null || true; }

# ════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTIONS — unit-tested by dolt-backup-residue-reclaim.selftest.sh.
# No side effects; every input is caller-supplied so the selftest can exercise
# arbitrary combinations without touching real files, AWS, or the clock.
# ════════════════════════════════════════════════════════════════════════════

# _prod_sentinel_active <resolved_root> <real_default_root> <prod_flag> → 0
# (true) iff resolved_root exactly equals real_default_root AND prod_flag is
# not "1". Same contract, same reasoning, as scratchpad-reaper.sh's function
# of the same name (ga-h565g): a caller that fails to override the root must
# never be able to trigger deletion just because it ALSO forgot to opt in.
_prod_sentinel_active() {
  local root="$1" real_default="$2" prod="$3"
  [ "$root" = "$real_default" ] && [ "$prod" != "1" ]
}

# _size_coherent <fingerprint_bytes> <local_bytes> <min_ratio_pct> → 0 (true)
# only when both sizes are valid non-negative integers, local_bytes is
# nonzero (a live backup dir reading as 0 bytes is itself suspicious and must
# never validate anything), and fingerprint_bytes*100 >= local_bytes*
# min_ratio_pct. Empty/non-numeric input fails CLOSED (ga-p5q3) — never guess
# coherence from an unmeasured size.
_size_coherent() {
  local fp_bytes="$1" local_bytes="$2" min_ratio_pct="$3"
  case "$fp_bytes" in ''|*[!0-9]*) return 1 ;; esac
  case "$local_bytes" in ''|*[!0-9]*) return 1 ;; esac
  case "$min_ratio_pct" in ''|*[!0-9]*) return 1 ;; esac
  [ "$local_bytes" -eq 0 ] && return 1
  awk -v a="$fp_bytes" -v b="$local_bytes" -v p="$min_ratio_pct" 'BEGIN{ exit !(a*100 >= b*p) }'
}

# _should_release_residue <old_mtime_epoch> <now_epoch> <settle_secs>
#   <fingerprint_run_epoch> <manifest_ok:0|1> <size_ok:0|1> → 0 (true) only
# when ALL hold: the residue has cleared its settle window, the S3
# fingerprint's run is strictly NEWER than the residue's own mtime (proof the
# fingerprint describes the replacement backup, not the retiree), the direct
# manifest HEAD-object probe succeeded, and the size-coherence check passed.
# Any empty/non-numeric input fails CLOSED — this is the single gate every
# real deletion in this file must pass, and it must never guess.
_should_release_residue() {
  local old_mtime="$1" now="$2" settle="$3" run_epoch="$4" manifest_ok="$5" size_ok="$6"
  case "$old_mtime" in ''|*[!0-9]*) return 1 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  case "$settle" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( now - old_mtime )) -ge "$settle" ] || return 1
  case "$run_epoch" in ''|*[!0-9]*) return 1 ;; esac
  [ "$run_epoch" -gt "$old_mtime" ] || return 1
  [ "$manifest_ok" = "1" ] || return 1
  [ "$size_ok" = "1" ] || return 1
  return 0
}

# _parse_fingerprint_to_file <json_file> <db> <out_file> — writes
# "<run_epoch>\t<size_bytes>\t<head>" to out_file on success, or leaves it
# empty on ANY parse failure (unreadable/invalid JSON, missing/malformed
# run_utc, no entry for <db>, missing/unparseable backup_size) — never
# guesses (ga-p5q3). Redirects the python3 heredoc's stdout straight to a
# file rather than through a command substitution wrapping the heredoc
# itself, matching dolt-s3-backup.sh's own _meta-writer precedent (a heredoc
# nested inside "$(...)" mis-parses under bash 3.2 when it contains an
# apostrophe — this script's heredoc has none, but the file-redirect shape
# sidesteps the question entirely rather than relying on that).
#
# ga-6xo4r0: a PER-DB run_utc (databases.<db>.run_utc — written by an ad hoc
# single-db fingerprint refresh, see dolt-backup-reseed.sh's own
# _publish_db_fingerprint) takes priority over the shared top-level run_utc
# (written once a day, for every db at once, by dolt-s3-backup.sh). An ad
# hoc reseed only ever touches ONE db, so it can only ever prove freshness
# for that db's own entry — bumping the shared top-level field instead would
# falsely vouch for every OTHER db too. Falls back to the top-level field
# whenever the per-db one is absent (every fingerprint published before this
# change, and every sibling db an ad hoc reseed didn't touch), so untouched
# entries parse EXACTLY as before — fully backward compatible.
_parse_fingerprint_to_file() {
  local json_file="$1" db="$2" out_file="$3"
  "$PY" - "$json_file" "$db" > "$out_file" 2>/dev/null <<'PY'
import sys, json, re
from datetime import datetime, timezone

path, db = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

entry = (data.get("databases") or {}).get(db)
if not isinstance(entry, dict):
    sys.exit(0)

run_utc = entry.get("run_utc")
if not isinstance(run_utc, str):
    run_utc = data.get("run_utc")
if not isinstance(run_utc, str):
    sys.exit(0)
try:
    dt = datetime.strptime(run_utc, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
except Exception:
    sys.exit(0)
run_epoch = int(dt.timestamp())

size_str = entry.get("backup_size")
if not isinstance(size_str, str):
    sys.exit(0)
m = re.match(r"^([0-9]+(?:\.[0-9]+)?)\s*([KMGTkmgt]?)[Bb]?$", size_str.strip())
if not m:
    sys.exit(0)
n = float(m.group(1))
mult = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}[m.group(2).upper()]
size_bytes = int(n * mult)

head = entry.get("head") or ""
sys.stdout.write(str(run_epoch) + "\t" + str(size_bytes) + "\t" + str(head) + "\n")
PY
}

# ════════════════════════════════════════════════════════════════════════════
# EXECUTION (side-effecting; NOT exercised by the selftest's pure-function
# assertions — proven instead via stubbed aws/notify binaries, same pattern
# dolt-s3-backup.sh's own _reseed_staging_if_enabled test uses).
# ════════════════════════════════════════════════════════════════════════════

# _reclaim_one_residue <old_dir> — evaluate and (if authorized) release ONE
# .old residue directory. Caller's glob already guarantees the *.old shape;
# re-checked again immediately before the real rm -rf as defense in depth.
_reclaim_one_residue() {
  local old_dir="$1" base db old_mtime now
  base="$(basename "$old_dir")"
  db="${base%.old}"
  if [ "$db" = "$base" ] || [ -z "$db" ]; then
    log "residue-reclaim: SKIP ${base} — does not match <db>.old shape"
    return
  fi

  old_mtime="$(stat -f %m "$old_dir" 2>/dev/null)"
  now=$(date +%s)
  if [ -z "$old_mtime" ]; then
    log "residue-reclaim: ${base} — SPARED (could not stat mtime; never guess age)"
    return
  fi

  local fp_file parsed_file
  fp_file="$(mktemp "${TMPDIR:-/tmp}/dolt-residue-fp.XXXXXX" 2>/dev/null)" || { log "residue-reclaim: ${base} — SPARED (could not create temp file for S3 fetch)"; return; }
  parsed_file="$(mktemp "${TMPDIR:-/tmp}/dolt-residue-parsed.XXXXXX" 2>/dev/null)" || { rm -f "$fp_file"; log "residue-reclaim: ${base} — SPARED (could not create temp file for parse output)"; return; }

  if timeout "$AWS_TIMEOUT_SECS" "$AWS" s3 cp "s3://$BUCKET/_meta/latest.json" "$fp_file" >/dev/null 2>&1; then
    _parse_fingerprint_to_file "$fp_file" "$db" "$parsed_file"
  fi

  local run_epoch="" size_bytes="" head=""
  if [ -s "$parsed_file" ]; then
    IFS="$(printf '\t')" read -r run_epoch size_bytes head < "$parsed_file"
  fi
  rm -f "$fp_file" "$parsed_file" 2>/dev/null

  local manifest_ok=0
  if timeout "$AWS_TIMEOUT_SECS" "$AWS" s3api head-object --bucket "$BUCKET" --key "$db/manifest" >/dev/null 2>&1; then
    manifest_ok=1
  fi

  local local_bytes=""
  if [ -d "$BACKUP_ROOT/$db" ]; then
    local local_kb; local_kb="$(du -sk "$BACKUP_ROOT/$db" 2>/dev/null | awk '{print $1}')"
    case "$local_kb" in ''|*[!0-9]*) : ;; *) local_bytes=$(( local_kb * 1024 )) ;; esac
  fi

  local size_ok=0
  if _size_coherent "${size_bytes:-}" "${local_bytes:-}" "$MIN_SIZE_RATIO_PCT"; then
    size_ok=1
  fi

  local old_kb old_mb=""
  old_kb="$(du -sk "$old_dir" 2>/dev/null | awk '{print $1}')"
  case "$old_kb" in ''|*[!0-9]*) : ;; *) old_mb=$(( old_kb / 1024 )) ;; esac

  if _should_release_residue "$old_mtime" "$now" "$SETTLE_SECS" "${run_epoch:-}" "$manifest_ok" "$size_ok"; then
    log "residue-reclaim: ${base} (~${old_mb:-?}MB) VERIFIED SAFE — manifest present (head-object OK for ${db}/manifest), fingerprint run newer than residue (run_epoch=${run_epoch} > old_mtime=${old_mtime}), size coherent (fingerprint=${size_bytes:-?}B vs live ${local_bytes:-?}B, min_ratio=${MIN_SIZE_RATIO_PCT}%), head=${head:-?}"
    if [ "$ENABLED" != "1" ] || [ "$DRY_RUN" = "1" ] || _prod_sentinel_active "$BACKUP_ROOT" "$BACKUP_ROOT_REAL_DEFAULT" "$PROD"; then
      log "residue-reclaim: ${base} — DRY-RUN (enabled=$ENABLED dry_run=$DRY_RUN prod=$PROD backup_root=$BACKUP_ROOT) — would delete and free ~${old_mb:-?}MB"
      return
    fi
    case "$old_dir" in
      "$BACKUP_ROOT"/*.old)
        if rm -rf "$old_dir" 2>>"$LOG"; then
          log "residue-reclaim: ${base} — DELETED, freed ~${old_mb:-?}MB (proof: see VERIFIED SAFE line above)"
        else
          log "residue-reclaim: ${base} — DELETE FAILED (rm nonzero exit)"
          notify_fail "backup residue reclaim: rm -rf falhou para ${old_dir} — ver $LOG"
        fi
        ;;
      *)
        log "residue-reclaim: ${base} — REFUSING delete, path '${old_dir}' outside \$BACKUP_ROOT/*.old shape (safety guard)"
        ;;
    esac
  else
    local age=$(( now - old_mtime ))
    if [ "$manifest_ok" != "1" ] || [ "$size_ok" != "1" ]; then
      log "residue-reclaim: ${base} (~${old_mb:-?}MB, age=${age}s) — SPARED (manifest_ok=${manifest_ok} size_ok=${size_ok} fingerprint_size=${size_bytes:-?}B live_size=${local_bytes:-?}B) — real verification gap, escalating"
      notify_fail "backup residue reclaim: ${db}.old não liberado — verificação S3 falhou (manifest_ok=${manifest_ok} size_ok=${size_ok}, db=${db}). Ver $LOG."
    else
      log "residue-reclaim: ${base} (~${old_mb:-?}MB, age=${age}s) — SPARED (settle window or fingerprint not yet fresher than residue: run_epoch=${run_epoch:-none} old_mtime=${old_mtime} settle=${SETTLE_SECS}s) — expected, self-healing next cycle"
    fi
  fi
}

# _reap_backup_residue — top-level sweep. Scans "$BACKUP_ROOT"/*.old ONLY
# (never .beads/dolt, never the live non-.old staging, never disk-ballast-
# guard.sh's ballast file — those live under entirely different paths this
# glob cannot reach). This IS the function dolt-disk-floor-guard.sh's own
# lever delegates to, and the function this file's top-level execution below
# calls when run standalone.
_reap_backup_residue() {
  if [ "$ENABLED" != "1" ]; then
    log "residue-reclaim SKIP — DOLT_BACKUP_RESIDUE_RECLAIM_ENABLED=0 (notify-only mode)"
    return
  fi
  if ! command -v "$AWS" >/dev/null 2>&1 && [ ! -x "$AWS" ]; then
    log "residue-reclaim SKIP — aws CLI not found ($AWS)"
    return
  fi
  if [ ! -d "$BACKUP_ROOT" ]; then
    log "residue-reclaim SKIP — $BACKUP_ROOT not found"
    return
  fi
  local considered=0 dir
  for dir in "$BACKUP_ROOT"/*.old; do
    [ -d "$dir" ] || continue
    considered=$((considered+1))
    _reclaim_one_residue "$dir"
  done
  if [ "$considered" -eq 0 ]; then
    log "residue-reclaim: no *.old residue under $BACKUP_ROOT"
  fi
}

# Library mode: `DOLT_BACKUP_RESIDUE_RECLAIM_LIB=1 source dolt-backup-residue-reclaim.sh`
# defines the functions above without scanning or deleting anything.
if [ "${DOLT_BACKUP_RESIDUE_RECLAIM_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
_reap_backup_residue
