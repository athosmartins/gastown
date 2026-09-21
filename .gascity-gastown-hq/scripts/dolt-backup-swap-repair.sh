#!/bin/bash
# dolt-backup-swap-repair.sh (ga-b14btl) — completes a reseed swap that was
# INTERRUPTED, turning a state nothing in this city could act on into the
# ordinary <db>.old residue that dolt-backup-residue-reclaim.sh already owns.
#
# ═══ WHY ═══
#
# dolt-backup-reseed.sh builds "$BACKUP_ROOT"/<db>.new, RESTORES it, verifies
# the row count against the live db, and only then renames <db> -> <db>.old
# and <db>.new -> <db>. Measured 2026-09-21 (ga-odtd3f, ga-b14btl): the 04:15
# run ended ok=7 failed=1 and hq was the failure, so the rename never
# happened and the city was left with:
#
#   .dolt-backup/hq      7.4G  manifest ABSENT  <- append-only remote KEEPS
#                                                  growing into it, ~300MB/h,
#                                                  and it can never restore
#   .dolt-backup/hq.new  6.8G  manifest PRESENT <- the only copy that restores
#
# Nothing could act on that. dolt-backup-residue-reclaim.sh only knows
# <db>.old (grep '.new' in it: zero hits). dolt-disk-floor-guard.sh ran under
# real pressure and freed 0MB. And the AGENT is permanently barred from
# `rm -rf` anywhere near Dolt — correctly; that bar is what keeps a bad day
# from becoming data loss. So the only actor left was a human, mid-incident,
# which is exactly what ga-8f1uh0 exists to eliminate. Meanwhile the Dolt
# server had already died three times that morning on "no space left on
# device: error syncing journal" (~04:20, ~09:07, ~09:33) — ~5h20 of city
# downtime whose root cause was a backup eating the disk it was meant to
# protect.
#
# ═══ WHAT — and what it deliberately does NOT do ═══
#
# This script NEVER DELETES ANYTHING. It renames:
#     <db>      -> <db>.old      (the invalid copy is retired, not destroyed)
#     <db>.new  -> <db>          (the verified copy is promoted)
# Deletion of <db>.old stays where it already is: dolt-backup-residue-reclaim.sh,
# which is S3-proof gated, settle-windowed and already reviewed. One deleter in
# the city, not two. That also means a wrong call here is RECOVERABLE by hand —
# both directories still exist afterwards.
#
# ═══ THE DISCRIMINATOR IS THE MANIFEST, AND NOTHING ELSE ═══
#
# The two heuristics a human reaches for first BOTH pointed the wrong way in
# the real incident:
#     name:  '.new' reads as "disposable staging", '<db>' reads as "the real one"
#     mtime: the INVALID copy was the MORE recently touched of the two (the
#            append-only remote was still writing to it)
# A Mayor stated out loud, in the live incident, that hq.new was "the orphan
# staging, safe to delete" — it was the only intact backup. This script must
# therefore never branch on name or mtime. It branches on `manifest`.
#
# ═══ FAIL-CLOSED ═══
#
# _should_complete_swap() is pure and returns false for every input it cannot
# positively verify. "There is no interrupted swap here" and "I could not tell"
# must NOT produce the same action — they produce the same INACTION, but they
# are logged as different lines, because a check that cannot distinguish them
# is the defect class this whole city keeps paying for.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
BACKUP_ROOT="${DOLT_BACKUP_SWAP_REPAIR_BACKUP_ROOT:-$CITY/.dolt-backup}"
LOG="${DOLT_BACKUP_SWAP_REPAIR_LOG:-$CITY/.gc/logs/dolt-backup-swap-repair.log}"
NOTIFY="${DOLT_BACKUP_SWAP_REPAIR_NOTIFY:-/Users/athos/.local/bin/notify}"
DRY_RUN="${DOLT_BACKUP_SWAP_REPAIR_DRY_RUN:-1}"   # default DRY: acting is opt-in

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] swap-repair: $*" >> "$LOG" 2>/dev/null || true; }
notify_fail() { "$NOTIFY" -t "Dolt backup swap repair" -p 4 "🚨 $*" 2>/dev/null || true; }

# ════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTIONS — unit-tested by dolt-backup-swap-repair.selftest.sh.
# Every input is caller-supplied so the selftest can exercise them with no
# filesystem, no Dolt and no real backup anywhere.
# ════════════════════════════════════════════════════════════════════════════

# _classify_copy <has_dir> <has_manifest>  ->  prints one of:
#   MISSING   — the directory is not there at all
#   VALID     — directory + manifest: a copy that restores
#   INVALID   — directory, no manifest: an interrupted sync; NOT a backup
#   UNKNOWN   — could not read one of the inputs
# Exists so that "not a backup" and "could not tell" are never the same token.
_classify_copy() {
  local has_dir="${1-}" has_man="${2-}"
  case "$has_dir" in
    0) printf 'MISSING'; return 0 ;;
    1) : ;;
    *) printf 'UNKNOWN'; return 0 ;;
  esac
  case "$has_man" in
    1) printf 'VALID' ;;
    0) printf 'INVALID' ;;
    *) printf 'UNKNOWN' ;;
  esac
}

# _should_complete_swap <primary_class> <new_class> <old_exists> <verified>
# True (0) ONLY when all four hold:
#   primary is INVALID   (an interrupted sync sitting where the backup belongs)
#   new     is VALID     (a copy with a manifest, ready to be promoted)
#   old_exists == 0      (a pre-existing <db>.old means the previous cycle's
#                         residue was never reclaimed; promoting now would
#                         overwrite it and destroy the one recoverable copy —
#                         residue-reclaim must run first)
#   verified   == 1      (the .new passed the SAME restore+row-count proof the
#                         reseed demands before its own swap — a manifest only
#                         proves the build finished, never that it restores)
# Anything else, including any unparseable input, returns false.
_should_complete_swap() {
  local primary="${1-}" new="${2-}" old_exists="${3-}" verified="${4-}"
  [ "$primary" = "INVALID" ] || return 1
  [ "$new" = "VALID" ]       || return 1
  [ "$old_exists" = "0" ]    || return 1
  [ "$verified" = "1" ]      || return 1
  return 0
}

# _refusal_reason <primary_class> <new_class> <old_exists> <verified>
# The counterpart to the above: says WHY nothing happened, so a no-op is never
# silent. Order matters — report the first unmet precondition, most structural
# first, so the log names the real blocker instead of a downstream symptom.
_refusal_reason() {
  local primary="${1-}" new="${2-}" old_exists="${3-}" verified="${4-}"
  if [ "$primary" = "UNKNOWN" ] || [ "$new" = "UNKNOWN" ]; then
    printf 'INDETERMINADO: nao consegui ler uma das copias (primary=%s new=%s) — nao e "nada a fazer"' "$primary" "$new"; return 0
  fi
  if [ "$primary" = "MISSING" ]; then
    printf 'nada a reparar: nao existe copia primaria'; return 0
  fi
  if [ "$primary" = "VALID" ]; then
    printf 'nada a reparar: a copia primaria TEM manifest (backup saudavel)'; return 0
  fi
  if [ "$new" = "MISSING" ]; then
    printf 'PRIMARIA INVALIDA E SEM .new PARA PROMOVER — este banco esta sem backup valido; so um reseed resolve'; return 0
  fi
  if [ "$new" = "INVALID" ]; then
    printf 'PRIMARIA INVALIDA E .new TAMBEM SEM MANIFEST — nenhuma copia restaura; so um reseed resolve'; return 0
  fi
  if [ "$old_exists" != "0" ]; then
    printf 'ja existe <db>.old do ciclo anterior — promover agora sobrescreveria a unica copia recuperavel; residue-reclaim precisa rodar antes'; return 0
  fi
  if [ "$verified" != "1" ]; then
    printf 'o .new NAO passou na prova de restore+contagem — manifest prova que o build terminou, nao que restaura'; return 0
  fi
  printf 'sem motivo de recusa (nao deveria acontecer)'
}

# ════════════════════════════════════════════════════════════════════════════
# Lib mode: the selftest sources this file to unit-test the pure functions
# above without executing anything.
# ════════════════════════════════════════════════════════════════════════════
if [ "${DOLT_BACKUP_SWAP_REPAIR_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

echo "dolt-backup-swap-repair.sh — inspecionando $BACKUP_ROOT (DRY_RUN=$DRY_RUN)"
log "inicio (BACKUP_ROOT=$BACKUP_ROOT DRY_RUN=$DRY_RUN)"
[ -d "$BACKUP_ROOT" ] || { echo "ERRO: $BACKUP_ROOT nao existe"; log "ERRO: BACKUP_ROOT ausente"; exit 1; }

found=0
for new_dir in "$BACKUP_ROOT"/*.new; do
  [ -d "$new_dir" ] || continue
  db="$(basename "$new_dir")"; db="${db%.new}"
  primary_dir="$BACKUP_ROOT/$db"

  ph=0; [ -d "$primary_dir" ] && ph=1
  pm=0; [ -f "$primary_dir/manifest" ] && pm=1
  nh=1
  nm=0; [ -f "$new_dir/manifest" ] && nm=1
  oe=0; [ -d "$BACKUP_ROOT/$db.old" ] && oe=1

  pclass="$(_classify_copy "$ph" "$pm")"
  nclass="$(_classify_copy "$nh" "$nm")"
  found=$((found+1))

  # Verification is NOT implemented here on purpose: the restore+row-count
  # proof already exists inside dolt-backup-reseed.sh and must not be
  # reimplemented (a second implementation is a second thing to drift). Until
  # this consumes it, `verified` is 0 and the script REFUSES — visibly. That
  # is the honest state: it can already tell you exactly what is wrong and
  # will not act on a copy nobody proved.
  verified="${DOLT_BACKUP_SWAP_REPAIR_VERIFIED:-0}"

  if _should_complete_swap "$pclass" "$nclass" "$oe" "$verified"; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "  $db: TROCA INTERROMPIDA — completaria (DRY_RUN=1, nada feito)"
      log "$db: DRY_RUN, troca interrompida detectada e nao aplicada"
    else
      mv "$primary_dir" "$BACKUP_ROOT/$db.old" \
        && mv "$new_dir" "$primary_dir" \
        && { echo "  $db: troca completada (invalida -> .old, .new promovida)"
             log "$db: troca completada"; } \
        || { echo "  $db: FALHOU ao renomear"; log "$db: FALHA no rename"; notify_fail "$db: rename falhou"; }
    fi
  else
    echo "  $db: nao age — $(_refusal_reason "$pclass" "$nclass" "$oe" "$verified")"
    log "$db: recusa — $(_refusal_reason "$pclass" "$nclass" "$oe" "$verified")"
  fi
done

[ "$found" = "0" ] && { echo "  nenhum <db>.new presente — nenhuma troca interrompida"; log "nenhum .new"; }
log "fim"
exit 0
