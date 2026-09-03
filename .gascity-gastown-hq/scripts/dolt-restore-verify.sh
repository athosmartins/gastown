#!/bin/bash
# dolt-restore-verify.sh (ga-jz7gg, scope items 3+4) — read-only, disk-safe
# weekly integrity check: restores each backed-up db to a scratch dir,
# compares its issue count against the live db, deletes the scratch copy,
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

  local live_count
  live_count=$(timeout 60 "$GC_BIN" dolt sql -q "SELECT COUNT(*) FROM \`$db\`.issues" 2>/dev/null \
               | grep -oE '^\| *[0-9]+' | grep -oE '[0-9]+' | head -1)
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
  # A origem pode crescer durante a verificacao (a cidade escreve o tempo
  # todo) — por isso >=, nunca ==. Mesma regra do dolt-backup-reseed.sh.
  if [ "$restored_count" -lt "$live_count" ]; then
    log "'$db': restaurado ($restored_count) < vivo ($live_count) — backup pode estar defasado ou incompleto"
    echo "${db}=FAIL(restaurado:${restored_count}<vivo:${live_count})"
    return 1
  fi
  log "'$db': OK (restaurado=$restored_count >= vivo=$live_count)"
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
