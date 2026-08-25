#!/usr/bin/env bash
# disk-oscillation-breakdown.sh — accounts for the gap between `df`'s used
# bytes and what `du` can actually sum on this machine's data volume.
#
# WHY THIS EXISTS (ga-lc17m, 2026-08-25): the Mini's disk usage swings
# ~10-14GB within hours, and a `du` sweep only summed ~117G against df's
# ~176G used (~59G unexplained gap, suspected in Containers/Group
# Containers/CloudStorage/var-folders).
#
# The OSCILLATION half of this bug was root-caused separately by reading
# disk-pressure-monitor.log, not by new instrumentation: that monitor's OWN
# hourly cleanup pass clears multi-hundred-MB-to-multi-GB caches
# (~/.cache/gdrive_reader alone regenerates 0.9-1.4GB EVERY hour) that
# legitimately regenerate from live agent/build activity between runs — a
# sawtooth, not a leak. See ga-lc17m comment history for the log excerpt.
#
# THIS script covers the GAP half: naming which roots du CAN and can't sum,
# so the gap becomes an accounted, tracked number instead of a mystery that
# floor alerts misread as "vazamento" (leak).
#
# READ-ONLY / DETECTION-ONLY BY CONSTRUCTION: never deletes, never kills,
# never touches TCC/permission settings. Safe to run any time, by any agent
# or human, as often as wanted.
#
# Full Disk Access residual: several roots below (Apple system Group
# Containers, some app Containers) return "Operation not permitted" without
# Full Disk Access granted to the invoking terminal/app in System Settings >
# Privacy & Security > Full Disk Access — a one-time GUI grant no headless
# agent can perform. Until granted, this script's blocked-dir count stays
# nonzero; that is expected, not a bug in the script.
#
# Usage:
#   bash disk-oscillation-breakdown.sh [--json]
#   DISK_OSCILLATION_LIB=1 to source only the pure/testable functions
#     (used by disk-oscillation-breakdown.selftest.sh — no live disk I/O).

set -uo pipefail

JSON_OUT=0
[ "${1:-}" = "--json" ] && JSON_OUT=1

MACHINE_NAME="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
LOG_TAG="disk-oscillation-breakdown [${MACHINE_NAME}]"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [${LOG_TAG}] $*" >&2; }

# ── pure: gap arithmetic (selftest-covered, no filesystem access) ──────────
# dob_gap_summary <used_kb> <measured_kb> <blocked_count>
# Prints one summary line. All-integer arithmetic (bash), no floats.
dob_gap_summary() {
  local used_kb="$1" measured_kb="$2" blocked_n="$3"
  local gap_kb=$(( used_kb - measured_kb ))
  [ "$gap_kb" -lt 0 ] && gap_kb=0
  local gap_pct=0
  if [ "$used_kb" -gt 0 ]; then
    gap_pct=$(( gap_kb * 100 / used_kb ))
  fi
  printf 'used=%sK measured=%sK gap=%sK(%s%%) blocked_dirs=%s' \
    "$used_kb" "$measured_kb" "$gap_kb" "$gap_pct" "$blocked_n"
}

# Allow sourcing just the pure functions above for the selftest, without
# running the live-filesystem collection pass below.
if [ "${DISK_OSCILLATION_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# ── collection (live filesystem below this line; not selftest-covered) ────
# Historically-heavy roots per ga-lc17m's own gap hypothesis, plus a couple
# of previously-confirmed culprits from earlier disk incidents (shared/data,
# caches) so one run gives the fuller picture.
DARWIN_TMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null | sed 's:/$::')"
TARGETS=(
  "$HOME/Library/Containers"
  "$HOME/Library/Group Containers"
  "$HOME/Library/CloudStorage"
  "$DARWIN_TMP"
  "$HOME/shared/data"
  "$HOME/.cache"
  "$HOME/Library/Caches"
  "$HOME/gt"
)
# CloudStorage in particular is known to sit in slow/uninterruptible I/O on
# this machine (FUSE-like on-demand materialization) — bounded timeout is a
# best-effort kill, not a guarantee; a target that times out is counted as
# fully blocked rather than forced to complete.
PER_TARGET_TIMEOUT="${DISK_OSCILLATION_TIMEOUT_SECS:-60}"

used_kb="$(df -k /System/Volumes/Data | awk 'NR==2 {print $3}')"
avail_human="$(df -h /System/Volumes/Data | awk 'NR==2 {print $4}')"
log "df /System/Volumes/Data: used=${used_kb}K avail=${avail_human}"

measured_kb=0
blocked_n=0
for t in "${TARGETS[@]}"; do
  [ -n "$t" ] || continue
  [ -d "$t" ] || { log "  skip (not a dir): $t"; continue; }
  errfile="$(mktemp)"
  sz_line="$(timeout "$PER_TARGET_TIMEOUT" du -sk "$t" 2>"$errfile")"
  rc=$?
  err_n="$(wc -l < "$errfile" | tr -d ' ')"
  rm -f "$errfile"
  if [ "$rc" -eq 124 ]; then
    log "  TIMEOUT (${PER_TARGET_TIMEOUT}s): $t — counted as fully blocked, not summed"
    blocked_n=$((blocked_n + 1))
    continue
  fi
  sz_kb="$(printf '%s' "$sz_line" | awk '{print $1}')"
  [ -n "$sz_kb" ] || sz_kb=0
  measured_kb=$((measured_kb + sz_kb))
  [ "$err_n" -gt 0 ] && blocked_n=$((blocked_n + 1))
  log "  ${sz_kb}K  ${t}  (permission-errors: ${err_n})"
done

summary="$(dob_gap_summary "$used_kb" "$measured_kb" "$blocked_n")"
log "SUMMARY: $summary"

if [ "$JSON_OUT" -eq 1 ]; then
  printf '{"used_kb":%s,"measured_kb":%s,"blocked_dirs":%s}\n' \
    "$used_kb" "$measured_kb" "$blocked_n"
else
  echo "$summary"
fi
