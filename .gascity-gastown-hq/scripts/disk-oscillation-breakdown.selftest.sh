#!/usr/bin/env bash
# disk-oscillation-breakdown.selftest.sh — Regression harness for ga-lc17m.
#
# Proves the PURE gap-arithmetic core of disk-oscillation-breakdown.sh in
# isolation (no live disk, no du/df calls). It SOURCES the script in
# lib-only mode (DISK_OSCILLATION_LIB=1) so the tested function IS the
# shipped one.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${DISK_OSCILLATION_BREAKDOWN:-$SELF_DIR/disk-oscillation-breakdown.sh}"

# shellcheck disable=SC1090
DISK_OSCILLATION_LIB=1 . "$TARGET"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   — %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL — %s\n' "$1"; }

# summary <desc> <used_kb> <measured_kb> <blocked_n> <expect_substr...>
check_summary() {
  local desc="$1" used="$2" measured="$3" blocked="$4"; shift 4
  local got; got="$(dob_gap_summary "$used" "$measured" "$blocked")"
  local all_found=1 needle
  for needle in "$@"; do
    case "$got" in
      *"$needle"*) ;;
      *) all_found=0 ;;
    esac
  done
  if [ "$all_found" -eq 1 ]; then
    ok "$desc (=$got)"
  else
    bad "$desc: expected to contain [$*], got '$got'"
  fi
}

echo "== dob_gap_summary =="

# Same order of magnitude as ga-lc17m's own reading (~176G used, ~117G
# measured) -> ~33% gap (integer division)
check_summary "gap percentage matches expected magnitude" 184320000 122683392 4 \
  "used=184320000K" "measured=122683392K" "gap=61636608K(33%)"

# No gap: fully measured, nothing blocked
check_summary "zero gap when fully measured" 1000 1000 0 "gap=0K(0%)"

# measured > used (rounding/timing skew across two separate df/du reads):
# gap must clamp to 0, never go negative
check_summary "clamps negative gap to 0" 1000 1200 0 "gap=0K(0%)"

# used=0 must not divide-by-zero
check_summary "used=0 does not divide by zero" 0 0 0 "gap=0K(0%)"

# blocked_dirs propagates through untouched
check_summary "blocked_dirs count passes through" 500 100 7 "blocked_dirs=7"

echo
echo "== summary: ${pass} ok, ${fail} failed =="
[ "$fail" -eq 0 ]
