#!/bin/bash
# dolt-backup-status.sh (ga-odtd3f) — diagnostic report of .dolt-backup's
# real state, per db: size, age, and — the one number that actually matters
# — whether each copy has a manifest.
#
# WHY THIS EXISTS: measured 2026-09-21 (ga-odtd3f), during a live ~5h20
# outage: .dolt-backup/hq had TWO 6.8G directories, 'hq' and 'hq.new'. The
# two heuristics a human reaches for FIRST both point the WRONG way —
#   name:  '.new' reads as "disposable staging", 'hq' reads as "the real one"
#   mtime: 'hq' was the MORE RECENTLY touched of the two
# — and neither is true. 'hq' was a sync interrupted by the disk-full crash
# (no manifest — does not restore). 'hq.new' was the last backup that
# actually completed (manifest present — the only one that restores). A
# human clearing space "by feel" from the name/mtime would have deleted the
# only good copy. The discriminator is the manifest file, and nothing else:
# "there's a large recently-touched directory here" and "there's a backup
# here" are different facts, and this script exists to stop conflating them.
#
# This is READ-ONLY. It never deletes, moves, or writes anything under
# .dolt-backup — deleting residue safely is dolt-backup-residue-reclaim.sh's
# job (S3-proof gated); this script only reports what a human or another
# script would need to know before touching anything by hand.
#
# Exit code: 0 if every db's primary copy has a manifest, 1 if any primary
# is missing one (a real "no valid local backup for this db" condition,
# worth a nonzero signal even though this script itself does nothing about
# it) or a directory's size/age could not be read at all (fail-closed, same
# posture as every other check in this city's Dolt backup scripts, applied
# here to REPORTING rather than to a destructive action).
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
BACKUP_ROOT="${GC_BACKUP_ARTIFACT_DIR:-$CITY/.dolt-backup}"

# _status_now_epoch — testable clock (same pattern as
# dolt-restore-verify.sh's _now_epoch): a real call in normal use, but
# override-able so tests can pin "now" instead of racing the wall clock.
_status_now_epoch() {
  if [ -n "${STATUS_NOW_EPOCH:-}" ]; then
    printf '%s' "$STATUS_NOW_EPOCH"
  else
    date +%s
  fi
}

# _status_age_human <seconds> — "5h13m" / "42m" / "3d" style, for the age-
# since-mtime a human actually needs to judge "is this an operation still
# running, or abandoned residue?" at a glance.
_status_age_human() {
  local secs="$1"
  case "$secs" in ''|*[!0-9]*) printf '?'; return ;; esac
  local d=$(( secs / 86400 )) h=$(( (secs % 86400) / 3600 )) m=$(( (secs % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  else printf '%dm' "$m"
  fi
}

# _status_one_copy <dir> — prints "<size>\t<mtime_epoch>\t<manifest:OK|AUSENTE>"
# for one backup directory, or empty fields (still tab-separated) if <dir>
# doesn't exist. Fail-closed on unreadable size/mtime: an empty field is
# always treated as "unknown", never coerced to 0/OK.
_status_one_copy() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    printf '\t\t\n'
    return
  fi
  local size_kb mtime manifest
  size_kb="$(du -sk "$dir" 2>/dev/null | awk '{print $1}')"
  mtime="$(stat -f '%m' "$dir" 2>/dev/null)"
  if [ -f "$dir/manifest" ]; then manifest="OK"; else manifest="AUSENTE"; fi
  printf '%s\t%s\t%s\n' "${size_kb:-}" "${mtime:-}" "$manifest"
}

_status_kb_human() {
  local kb="$1"
  case "$kb" in ''|*[!0-9]*) printf '?'; return ;; esac
  if [ "$kb" -ge 1048576 ]; then
    awk -v k="$kb" 'BEGIN{printf "%.1fG", k/1048576}'
  elif [ "$kb" -ge 1024 ]; then
    awk -v k="$kb" 'BEGIN{printf "%.0fM", k/1024}'
  else
    # Below 1024KB, an M-rounded value can read as "0M" for a genuinely
    # nonzero, real directory (measured live: several small city dbs did
    # exactly this) — that looks like "empty" when it isn't. Show the exact
    # KB instead of a misleadingly-rounded-to-zero M figure.
    printf '%sK' "$kb"
  fi
}

# _status_report_db <db> — prints the human-readable block for one db and
# returns 1 if that db's PRIMARY copy is invalid or unreadable (drives the
# overall exit code), 0 otherwise. Pure w.r.t. its inputs (BACKUP_ROOT,
# filesystem state) — no deletion, no network call.
_status_report_db() {
  local db="$1" now; now="$(_status_now_epoch)"
  local rc=0

  local primary_line new_line old_line
  primary_line="$(_status_one_copy "$BACKUP_ROOT/$db")"
  new_line="$(_status_one_copy "$BACKUP_ROOT/$db.new")"
  old_line="$(_status_one_copy "$BACKUP_ROOT/$db.old")"

  local p_size p_mtime p_manifest
  IFS="$(printf '\t')" read -r p_size p_mtime p_manifest <<< "$primary_line"

  if [ -z "$p_manifest" ]; then
    printf '%s: PRIMARY ausente em %s\n' "$db" "$BACKUP_ROOT/$db"
    rc=1
  elif [ "$p_manifest" = "AUSENTE" ]; then
    printf '%s: PRIMARY %s mtime=%s MANIFEST=AUSENTE — NAO E UM BACKUP VALIDO (sync interrompido; nao restaura), mesmo sendo o de nome/mtime mais \xe2\x80\x9cobvio\xe2\x80\x9d\n' \
      "$db" "$(_status_kb_human "$p_size")" "$(date -r "${p_mtime:-0}" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '?')"
    rc=1
  else
    printf '%s: PRIMARY %s mtime=%s MANIFEST=OK\n' \
      "$db" "$(_status_kb_human "$p_size")" "$(date -r "${p_mtime:-0}" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '?')"
  fi

  local n_size n_mtime n_manifest
  IFS="$(printf '\t')" read -r n_size n_mtime n_manifest <<< "$new_line"
  if [ -n "$n_manifest" ]; then
    local age; age="$(_status_age_human "$(( now - ${n_mtime:-$now} ))")"
    printf '    .new RESIDUO %s mtime=%s (%s atras) MANIFEST=%s%s\n' \
      "$(_status_kb_human "$n_size")" "$(date -r "${n_mtime:-0}" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '?')" \
      "$age" "$n_manifest" \
      "$([ "$n_manifest" = "OK" ] && [ "$p_manifest" = "AUSENTE" ] && printf ' <- ESTE presta, o PRIMARY acima nao' || true)"
  fi

  local o_size o_mtime o_manifest
  IFS="$(printf '\t')" read -r o_size o_mtime o_manifest <<< "$old_line"
  if [ -n "$o_manifest" ]; then
    local age; age="$(_status_age_human "$(( now - ${o_mtime:-$now} ))")"
    printf '    .old residuo (normal — reseed nunca apaga sozinho; aguarda residue-reclaim com prova do S3) %s mtime=%s (%s atras) MANIFEST=%s\n' \
      "$(_status_kb_human "$o_size")" "$(date -r "${o_mtime:-0}" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '?')" \
      "$age" "$o_manifest"
  fi

  # .new residue is the genuinely anomalous case worth the strong warning —
  # a completed reseed always renames .new away, so its presence alone means
  # an INCOMPLETE swap, unlike routine .old residue above. Firing this same
  # warning on every routine .old would cry wolf on the normal case and bury
  # the one that actually matters (measured lesson from ga-odtd3f itself:
  # the manifest is the only reliable signal — don't also make the WARNING
  # unreliable by over-firing it).
  if [ -n "$n_manifest" ]; then
    printf '    \xe2\x9a\xa0\xef\xb8\x8f .new presente = troca INCOMPLETA (reseed sempre renomeia .new embora ao terminar). O discriminador de qual copia presta e SEMPRE o MANIFEST acima, NUNCA o nome nem o mtime — os dois ja apontaram pro lado errado numa incidente real (ga-odtd3f, 2026-09-21)\n'
  fi

  return "$rc"
}

# Library mode: `DOLT_BACKUP_STATUS_LIB=1 source dolt-backup-status.sh`
# defines the functions above without running the report — used by
# dolt-backup-status.selftest.sh.
if [ "${DOLT_BACKUP_STATUS_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

echo "=== dolt-backup-status.sh — $(date '+%Y-%m-%d %H:%M:%S') — $BACKUP_ROOT ==="
overall_rc=0
found_any=0
for entry in "$BACKUP_ROOT"/*/; do
  [ -d "$entry" ] || continue
  name="$(basename "$entry")"
  case "$name" in
    *.new|*.old) continue ;;
  esac
  found_any=1
  _status_report_db "$name" || overall_rc=1
done

if [ "$found_any" -eq 0 ]; then
  echo "(nenhum banco encontrado em $BACKUP_ROOT)"
fi

echo "==="
if [ "$overall_rc" -eq 0 ]; then
  echo "resultado: todos os backups primarios tem manifest (validos)."
else
  echo "resultado: pelo menos um banco tem PRIMARY sem manifest (invalido) — ver acima."
fi
exit "$overall_rc"
