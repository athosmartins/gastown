#!/bin/bash
# dolt-restore-verify.sh (ga-jz7gg, scope items 3+4) — read-only, disk-safe
# weekly integrity check: restores each backed-up db to a scratch dir,
# compares its issue count against what the live db held WHEN THE BACKUP WAS
# TAKEN (ga-jsk5p8 — not against the live db of right now, except when the
# snapshot time cannot be determined: then the old strict live-now rule
# applies; see the snapshot-baseline block below), deletes the scratch copy,
# and files ONE summary bead per run so the result surfaces in the digest
# (see mol-digest-generate.toml's "Restore-verify" collect-data section).
#
# WHY A DISK PRECHECK BEFORE *EACH* DB, NOT JUST ONCE AT THE START: the
# 25/08 lesson this story is named after — a manual restore-verify at peak
# time almost brought the disk down (see ga-jz7gg's own parent epic, and the
# aborted manual reseed attempt at 14:46 the same day). Checking headroom
# once at the top of a multi-db loop is not enough: each restore consumes
# and then frees space, and a LATER db in the loop can find less headroom
# than the first one did. Re-check live, right before each individual
# restore — never trust a start-of-run snapshot for a db reached minutes
# later.
#
# READ-ONLY: unlike dolt-backup-reseed.sh (ga-ydrg9), this script never
# touches the live db or the backup itself — it only restores a COPY under
# /tmp and deletes that copy afterward. Nothing here can corrupt or replace
# a backup; a bug here can waste disk/time, never lose data.
#
# TEST: bash scripts/dolt-restore-verify.selftest.sh
# Library mode: RESTORE_VERIFY_LIB=1 source dolt-restore-verify.sh
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
# Export (not just a local var): "$GC_BIN dolt sql" below needs GC_CITY_PATH
# in ITS OWN environment to discover the city. Without this, gc falls back to
# CWD-based auto-discovery — fine interactively, but this script also runs
# under launchd (ga-jz7gg's hq-restore-verify-once.sh, 03:17 one-shot), where
# a plist with no WorkingDirectory leaves CWD at launchd's default (not under
# the city tree). With no city discoverable, gc's "dolt" pack-subcommand
# never registers at all, so "gc dolt sql -q ..." fails in under a second
# with a root-command usage error on stderr — swallowed by the 2>/dev/null
# below — and live_count comes back empty, indistinguishable from a genuine
# Dolt outage. Root-caused live 2026-09-03 (ga-ymsl0): hq's one-shot run
# reported SKIP(sem-baseline) even though Dolt itself was healthy throughout;
# reproduced by running this exact query with GC_CITY_PATH unset and CWD=/.
export GC_CITY_PATH="$CITY"
BACKUP_ROOT="${GC_BACKUP_ARTIFACT_DIR:-$CITY/.dolt-backup}"
DOLTDIR="$CITY/.beads/dolt"
LOG="${RESTORE_VERIFY_LOG:-$CITY/.gc/logs/dolt-restore-verify.log}"
DOLT_BIN="${DOLT_BIN:-dolt}"
GC_BIN="${GC_BIN:-gc}"
BD_BIN="${BD_BIN:-bd}"
NOTIFY="${NOTIFY:-/Users/athos/.local/bin/notify}"
# Own, independently-tunable margin — deliberately NOT the same env var name
# as dolt-backup-reseed.sh's RESEED_DISK_MARGIN_PCT, so tuning one script's
# safety margin can never silently change the other's. 200% (not 250%) is
# intentional: this script's peak is ONLY the restored copy (~1x live) plus
# writer slack, since — unlike reseed — there is no second "new backup"
# directory coexisting with a "verify" directory at the same time.
DISK_MARGIN_PCT="${RESTORE_VERIFY_DISK_MARGIN_PCT:-200}"
ONLY_DBS="${RESTORE_VERIFY_ONLY_DBS:-}"   # space-separated allowlist; empty = every backed-up db

# ── Snapshot baseline (ga-jsk5p8) ───────────────────────────────────────────
# A backup is a snapshot of the PAST; the live db keeps growing after it. The
# old rule ("restored < live-now => FAIL") therefore condemned a perfect backup
# whenever ONE row was created between the snapshot and the live read: ga-fd84uf
# (WA, 20/09: restored 5107 < live 5108; the extra row was created 8 min AFTER
# the backup and the row-ID diff proved nothing else was missing) and, earlier,
# ga-o6e6y (hq, an ad-hoc run 19h after the backup). It only ever passed on
# quiet Sundays because no row happened to land in the 31 min between the reseed
# (~04:29) and this job (05:00).
# The fix is to charge the backup only for rows that existed when it was taken:
#   expected = live_now - (live rows created AFTER the snapshot)
# and to keep, EXPLICITLY, the one thing the old rule caught by accident — a
# DEAD backup job (old backup => restored < live): if the db has changed since
# the backup and the backup is older than MAX_BACKUP_AGE_H, that is a FAIL of
# its own. A quiet db (nothing created since) may keep an old backup: nothing
# is missing from it.
#   SNAPSHOT_SLACK_SEC: how far BEFORE the manifest's mtime the real snapshot
#     may sit (the manifest is written when the sync FINISHES; hq's sync takes
#     minutes). Rows created inside that window are not charged to the backup.
#   MAX_BACKUP_AGE_H: age ceiling, applied only when the db changed since.
# KNOWN TRADE-OFF (accepted): rows created inside the slack window are never
# charged to the backup, so if the backup DID capture some of them it can mask
# an equal number of lost OLDER rows. The slack is the price of not
# false-alarming on a slow sync; RESTORE_VERIFY_SNAPSHOT_SLACK_SEC=0 removes the
# masking window at the cost of possible false alarms when a sync is slow.
SNAPSHOT_SLACK_SEC="${RESTORE_VERIFY_SNAPSHOT_SLACK_SEC:-900}"
MAX_BACKUP_AGE_H="${RESTORE_VERIFY_MAX_BACKUP_AGE_H:-36}"
# A typo'd override must not turn into an empty arithmetic operand later.
case "$SNAPSHOT_SLACK_SEC" in ''|*[!0-9]*) SNAPSHOT_SLACK_SEC=900 ;; esac
case "$MAX_BACKUP_AGE_H" in ''|*[!0-9]*) MAX_BACKUP_AGE_H=36 ;; esac
# A leading zero ("0900") would be read as OCTAL inside $(( )) and abort the run.
SNAPSHOT_SLACK_SEC=$((10#$SNAPSHOT_SLACK_SEC)); MAX_BACKUP_AGE_H=$((10#$MAX_BACKUP_AGE_H))

mkdir -p "$(dirname "$LOG")" 2>/dev/null
# File-only, never stdout: _verify_one_db's stdout is a RETURN CHANNEL (its
# final "db=STATUS(...)" line is captured via command substitution by both
# main() and callers), and dolt-compact-routine.sh's own log() sets the
# precedent for exactly this reason — a log line mixed into that channel
# would corrupt every caller's parsed result, not just look noisy.
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [restore-verify] $*" >> "$LOG" 2>/dev/null || true; }

# _avail_gb — macOS: `df /` reports the sealed SYSTEM volume and lies about
# free space; same gotcha already documented in dolt-backup-reseed.sh and
# dolt-disk-floor-guard.sh. Fail-closed (empty, never 0) on any read failure.
_avail_gb() {
  local kb
  kb=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')
  case "$kb" in ''|*[!0-9]*) echo ""; return ;; esac
  echo $(( kb / 1024 / 1024 ))
}

# _need_gb <live_kb> <margin_pct> — pure arithmetic. Fail-closed (empty) on
# non-numeric input so a read failure can never masquerade as "need 0GB".
# ORDER MATTERS: multiply by pct BEFORE dividing down to GB. Dividing to GB
# first (live_kb/1024/1024) truncates to 0 for any live db under 1GB —
# whatsapp_automation (~788MB) is a real one — which then discards the whole
# margin (0 * pct = 0) regardless of DISK_MARGIN_PCT. Multiplying first keeps
# the sub-GB precision alive until the final division.
_need_gb() {
  local live_kb="$1" pct="$2"
  case "$live_kb" in ''|*[!0-9]*) echo ""; return ;; esac
  case "$pct" in ''|*[!0-9]*) echo ""; return ;; esac
  echo $(( (live_kb * pct / 100) / 1024 / 1024 + 1 ))
}

# _headroom_ok <avail_gb> <need_gb> — fail-closed on any non-numeric input.
_headroom_ok() {
  local avail="$1" need="$2"
  case "$avail" in ''|*[!0-9]*) return 1 ;; esac
  case "$need" in ''|*[!0-9]*) return 1 ;; esac
  [ "$avail" -ge "$need" ]
}

# _discover_dbs <backup_root> — every backed-up db name, excluding the
# .new/.old in-progress-reseed artifacts dolt-backup-reseed.sh (ga-ydrg9)
# creates transiently — those are not stable, checkable backups.
_discover_dbs() {
  local root="$1"
  [ -d "$root" ] || return 0
  (cd "$root" 2>/dev/null && ls -1 2>/dev/null) | grep -vE '\.(new|old)$' || true
}

# _now_epoch — wall clock, epoch seconds. RESTORE_VERIFY_NOW_EPOCH is a TEST
# HOOK (pins "now" so the age tests do not depend on the real clock); nothing
# in production sets it, and a non-numeric value is ignored (real clock), never
# fed into the age arithmetic.
_now_epoch() {
  case "${RESTORE_VERIFY_NOW_EPOCH:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) echo "$RESTORE_VERIFY_NOW_EPOCH" ;;
  esac
}

# _backup_mtime_epoch <db> — mtime (epoch) of the backup's manifest. dolt
# writes the manifest LAST, when a sync/reseed finishes, so it is the closest
# external clock for "when was this backup taken" — external on purpose: a
# clock derived from the backup's own rows (its newest created_at, its HEAD
# commit date) would shrink together with a truncated backup and hide the loss.
# Prints NOTHING (never 0) when there is no manifest or it is unreadable: the
# caller reads that as UNKNOWN and keeps the strict rule.
_backup_mtime_epoch() {
  local mf="$BACKUP_ROOT/$1/manifest" m=""
  [ -f "$mf" ] || return 0
  m=$(stat -f %m "$mf" 2>/dev/null)                                    # BSD / macOS
  case "$m" in ''|*[!0-9]*) m=$(stat -c %Y "$mf" 2>/dev/null) ;; esac  # GNU
  case "$m" in ''|*[!0-9]*) return 0 ;; esac
  echo "$m"
}

# _epoch_to_utc <epoch> — "YYYY-MM-DD HH:MM:SS" in UTC, the timezone bd stores
# created_at in (calibrated live: a bead's SQL created_at equals its JSON ...Z
# time). Prints NOTHING on a non-numeric/negative epoch or an odd date output,
# and the shape is checked before it is ever spliced into SQL.
_epoch_to_utc() {
  local e="$1" out=""
  case "$e" in ''|*[!0-9]*) return 0 ;; esac
  out=$(date -u -r "$e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)                                  # BSD / macOS
  case "$out" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
    *) out=$(date -u -d "@$e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) ;;                          # GNU
  esac
  case "$out" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) echo "$out" ;; esac
}

# _live_counts_with_post <db> <cutoff_utc> — ONE atomic query, prints
# "<live> <post>": the live issue count, and how many of those rows were created
# AFTER cutoff (rows a backup taken at cutoff cannot contain). One statement, so
# both numbers describe the same instant — two queries seconds apart would let a
# row created in between count as "post-backup" and quietly widen the tolerance.
# Prints NOTHING if the query fails or its output is not two numbers.
_live_counts_with_post() {
  local db="$1" cutoff="$2" row
  row=$(timeout 60 "$GC_BIN" dolt sql -q "SELECT COUNT(*), COALESCE(SUM(created_at > '$cutoff'),0) FROM \`$db\`.issues" 2>/dev/null \
        | grep -E '^\| *[0-9]+ *\| *[0-9]+ *\|' | head -1)
  [ -n "$row" ] || return 0
  printf '%s\n' "$row" | awk -F'|' '{gsub(/[[:space:]]/,"",$2); gsub(/[[:space:]]/,"",$3); print $2, $3}'
}

# _verify_one_db <db> — echoes "<db>=OK(n)" / "SKIP(reason)" / "FAIL(reason)"
# to stdout and returns 0 for OK/SKIP, 1 for FAIL. SKIP is deliberately NOT a
# failure: "could not check right now" (no baseline, no disk headroom) is a
# different, honest third state from "checked and it's broken" — collapsing
# them would either mask a real integrity failure as routine, or alarm on a
# transient disk squeeze that isn't the backup's fault.
_verify_one_db() {
  local db="$1"
  if [ ! -d "$DOLTDIR/$db" ]; then
    log "pulando '$db': sem banco vivo correspondente em $DOLTDIR"
    echo "${db}=SKIP(sem-banco-vivo)"
    return 0
  fi
  if [ ! -d "$BACKUP_ROOT/$db" ]; then
    log "pulando '$db': sem backup em $BACKUP_ROOT"
    echo "${db}=SKIP(sem-backup)"
    return 0
  fi

  # Baseline = the live db as it was WHEN THE BACKUP WAS TAKEN (see the
  # "Snapshot baseline" block at the top). Everything below fails toward the OLD
  # strict rule: no readable manifest, a bad timestamp, or a failed/garbled
  # combined query all leave post_count EMPTY, and the verdict then compares
  # against the plain live count exactly as before. Unknown never means a
  # weaker check — only a measured post-snapshot row count can widen it.
  local snap_epoch cutoff="" live_count="" post_count="" both="" read_epoch
  snap_epoch=$(_backup_mtime_epoch "$db")
  if [ -n "$snap_epoch" ]; then
    cutoff=$(_epoch_to_utc $(( snap_epoch - SNAPSHOT_SLACK_SEC )))
  fi
  if [ -n "$cutoff" ]; then
    both=$(_live_counts_with_post "$db" "$cutoff")
    if [ -n "$both" ]; then
      live_count="${both% *}"
      post_count="${both#* }"
      # Post-snapshot rows are a SUBSET of the live rows: post > live is not a
      # measurement (garbled / mis-parsed read). Discard it — the strict rule
      # applies — rather than let an impossible number widen the tolerance.
      if [ "$post_count" -gt "$live_count" ]; then live_count=""; post_count=""; fi
    fi
  fi
  read_epoch=$(_now_epoch)
  if [ -z "$live_count" ]; then
    post_count=""
    live_count=$(timeout 60 "$GC_BIN" dolt sql -q "SELECT COUNT(*) FROM \`$db\`.issues" 2>/dev/null \
                 | grep -oE '^\| *[0-9]+' | grep -oE '[0-9]+' | head -1)
  fi
  if [ -z "$live_count" ]; then
    log "'$db': nao consegui ler a contagem viva — sem baseline nao ha verificacao possivel"
    echo "${db}=SKIP(sem-baseline)"
    return 0
  fi

  local live_kb need_gb avail_gb
  live_kb=$(du -sk "$DOLTDIR/$db" 2>/dev/null | awk '{print $1}')
  need_gb=$(_need_gb "$live_kb" "$DISK_MARGIN_PCT")
  avail_gb=$(_avail_gb)
  log "'$db': preciso ~${need_gb:-?}GB (margem ${DISK_MARGIN_PCT}%), livre ${avail_gb:-?}GB"
  if ! _headroom_ok "$avail_gb" "$need_gb"; then
    log "'$db': disco insuficiente AGORA — pulando (nao e falha do backup; tentar novamente numa janela com mais disco livre)"
    echo "${db}=SKIP(disco:${avail_gb:-?}GB<${need_gb:-?}GB)"
    return 0
  fi

  local verify_dir restored_count=""
  verify_dir=$(mktemp -d "/tmp/restore-verify-$db.XXXXXX") || {
    log "'$db': falha ao criar diretorio temporario de verificacao"
    echo "${db}=SKIP(mktemp-falhou)"
    return 0
  }
  if ( cd "$verify_dir" && timeout 1800 "$DOLT_BIN" backup restore "file://$BACKUP_ROOT/$db" "${db}_verify" >/dev/null 2>&1 ); then
    restored_count=$(cd "$verify_dir/${db}_verify" 2>/dev/null && timeout 120 "$DOLT_BIN" sql -q "SELECT COUNT(*) FROM issues" 2>/dev/null \
                     | grep -oE '^\| *[0-9]+' | grep -oE '[0-9]+' | head -1)
  fi
  rm -rf "$verify_dir" 2>/dev/null

  if [ -z "$restored_count" ]; then
    log "'$db': backup NAO RESTAURA ou nao consegui ler a contagem pos-restore"
    echo "${db}=FAIL(nao-restaura-ou-sem-leitura)"
    return 1
  fi
  if [ -z "$post_count" ]; then
    # No snapshot baseline (manifest unknown / combined query failed): the
    # STRICT pre-ga-jsk5p8 rule — the restored copy must cover everything the
    # live db holds right now. It can false-alarm on a busy db; it never
    # accepts a restore with FEWER rows than the live db holds right now.
    if [ "$restored_count" -lt "$live_count" ]; then
      log "'$db': restaurado ($restored_count) < vivo ($live_count) — backup pode estar defasado ou incompleto (sem baseline do snapshot: regra estrita)"
      echo "${db}=FAIL(restaurado:${restored_count}<vivo:${live_count})"
      return 1
    fi
    log "'$db': OK (restaurado=$restored_count >= vivo=$live_count; sem baseline do snapshot: regra estrita)"
    echo "${db}=OK(${restored_count})"
    return 0
  fi

  # Snapshot baseline. The restored copy has to hold every row that existed
  # when the backup was taken; rows created after it are not its fault. (The
  # live read above happens BEFORE the restore, so growth DURING this
  # verification is irrelevant — what matters is growth AFTER THE SNAPSHOT.)
  local expected age_s age_h
  expected=$(( live_count - post_count ))
  if [ "$expected" -lt 0 ]; then expected=0; fi
  if [ "$restored_count" -lt "$expected" ]; then
    log "'$db': restaurado ($restored_count) < esperado no snapshot ($expected = vivo $live_count - $post_count criadas apos o backup) — linhas que existiam no backup NAO voltaram no restore"
    echo "${db}=FAIL(restaurado:${restored_count}<esperado:${expected},vivo:${live_count},pos-backup:${post_count})"
    return 1
  fi
  # Freshness, explicit. Tolerating post-snapshot rows would otherwise blind
  # this check to a dead backup job (old backup => big gap => "just growth").
  # Only when the db HAS changed since: a quiet db may keep an old backup.
  age_s=$(( read_epoch - snap_epoch ))
  if [ "$age_s" -lt 0 ]; then age_s=0; fi
  age_h=$(( age_s / 3600 ))
  if [ "$post_count" -gt 0 ] && [ "$age_s" -gt $(( MAX_BACKUP_AGE_H * 3600 )) ]; then
    log "'$db': backup com ${age_h}h (limite ${MAX_BACKUP_AGE_H}h) e o banco JA mudou desde ele ($post_count issues novas) — o job de backup nao esta acompanhando o banco"
    echo "${db}=FAIL(defasado:${age_h}h>${MAX_BACKUP_AGE_H}h,pos-backup:${post_count})"
    return 1
  fi
  log "'$db': OK (restaurado=$restored_count >= esperado no snapshot=$expected; vivo=$live_count, criadas apos o backup=$post_count, backup com ${age_h}h)"
  echo "${db}=OK(${restored_count})"
  return 0
}

# _file_summary_bead <results-string> <overall_rc> — ONE bead per run, not
# one per db (avoids bead spam). A clean run (overall_rc=0) is a routine
# record — filed as a closed chore, matching how the digest's own Incidents
# convention treats things resolved the instant they're filed. A run with
# any FAIL is actionable — filed as an OPEN bug, routed to gastown.dog (the
# pool that owns this domain), and deliberately left open: closing it here
# would hide the exact failure this whole story exists to surface.
# overall_rc=2 is a THIRD state (gate-caught, ga-jz7gg fix-attempt 1): every
# db SKIPped, so nothing was actually verified this run — e.g. dolt
# unreachable, or disk tight city-wide for every db in turn. Filing this
# identically to overall_rc=0 would record "checked, all clean" for a run
# that checked nothing — the exact SKIP/OK collapse _verify_one_db's own
# header warns against, just one level up. Filed as an open bug like FAIL,
# but lower priority: it needs eyes, but it isn't a proven integrity break.
_file_summary_bead() {
  local results="$1" overall_rc="$2" title body bead_id meta
  body="Verificacao de restore automatizada (ga-jz7gg). Resultado por banco:
$results

Log completo: $LOG"
  if [ "$overall_rc" -eq 0 ]; then
    title="Restore-verify semanal OK: $results"
    bead_id=$(timeout 30 "$BD_BIN" -C "$CITY" create --title="$title" --type=chore --priority=3 --labels=restore-verify --description="$body" --silent 2>/dev/null)
    [ -n "$bead_id" ] && timeout 30 "$BD_BIN" -C "$CITY" close "$bead_id" --reason "restore-verify semanal limpo" -q 2>/dev/null
  elif [ "$overall_rc" -eq 2 ]; then
    title="Restore-verify semanal SEM VERIFICACAO (todos os bancos SKIP): $results"
    meta='{"gc.routed_to":"gastown.dog"}'
    bead_id=$(timeout 30 "$BD_BIN" -C "$CITY" create --title="$title" --type=bug --priority=2 --labels=restore-verify --description="$body" --metadata="$meta" --silent 2>/dev/null)
  else
    title="Restore-verify semanal FALHOU: $results"
    meta='{"gc.routed_to":"gastown.dog"}'
    bead_id=$(timeout 30 "$BD_BIN" -C "$CITY" create --title="$title" --type=bug --priority=1 --labels=restore-verify --description="$body" --metadata="$meta" --silent 2>/dev/null)
  fi
  if [ -n "$bead_id" ]; then
    log "bead de resumo: $bead_id"
  else
    # The summary bead is the ONLY channel mol-digest-generate.toml's
    # restore-verify section reads — a log-only warning here is invisible to
    # anything not tailing this exact file. notify is an INDEPENDENT channel
    # (a plain HTTP POST to ntfy.sh, no bd/Dolt dependency at all), so it
    # still fires even when bd itself is the thing that's down — exactly the
    # case a log line alone cannot cover.
    log "AVISO: falhei ao criar o bead de resumo — resultado so existe no log ($LOG)"
    "$NOTIFY" -t "Dolt restore-verify" -p 4 "⚠️ restore-verify rodou mas falhou ao registrar o bead de resumo (bd indisponivel?) — resultado: $results ver $LOG" 2>/dev/null || true
  fi
}

main() {
  local db_list results="" overall_rc=0 db one_result one_rc ok_count=0 fail_seen=0
  if [ -n "$ONLY_DBS" ]; then db_list="$ONLY_DBS"; else db_list="$(_discover_dbs "$BACKUP_ROOT")"; fi
  if [ -z "$db_list" ]; then
    log "nenhum banco encontrado em $BACKUP_ROOT — nada a verificar"
    return 0
  fi
  for db in $db_list; do
    log "=== restore-verify de '$db' ==="
    one_result="$(_verify_one_db "$db")"; one_rc=$?
    results="${results}${one_result} "
    case "$one_result" in "${db}=OK("*) ok_count=$((ok_count + 1)) ;; esac
    [ "$one_rc" -ne 0 ] && fail_seen=1
  done
  if [ "$fail_seen" -eq 1 ]; then
    overall_rc=1
  elif [ "$ok_count" -eq 0 ]; then
    # Every db this run SKIPped -- nothing was actually verified. Distinct
    # from overall_rc=0, which requires at least one real restore+compare;
    # collapsing this into rc=0 would file a "clean" bead on a run that
    # proved nothing (see _file_summary_bead's overall_rc=2 branch).
    overall_rc=2
  fi
  log "=== resumo: $results ==="
  _file_summary_bead "$results" "$overall_rc"
  return "$overall_rc"
}

if [ "${RESTORE_VERIFY_LIB:-0}" != "1" ]; then
  main
  exit $?
fi
