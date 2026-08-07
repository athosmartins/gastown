#!/bin/bash
# log-reaper.selftest.sh — unit + end-to-end tests for log-reaper.sh.
#
# Hermetic: sources the script as a LIBRARY (LOG_REAPER_LIB=1) so main()
# never runs at source time, points LOG at a throwaway path. Every main()
# scenario below points LOG_REAPER_PATHS at synthetic files under a disposable
# tmpdir — never the real six production log paths.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/log-reaper.sh"

export LOG_REAPER_LIB=1
export LOG_REAPER_LOG="/tmp/log-reaper-selftest-$$.log"
# shellcheck disable=SC1090
. "$SCRIPT"

# Captured immediately after the ONLY source of this file, before any test
# below reassigns LOG_REAPER_REAL_DEFAULT_PATHS for hermetic fixture
# scenarios — mirrors scratchpad-reaper.selftest.sh's own
# PRODUCTION_REAL_DEFAULT_ROOT capture (ga-h565g production-constant check
# near the end of this file).
PRODUCTION_REAL_DEFAULT_PATHS="$LOG_REAPER_REAL_DEFAULT_PATHS"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== log-reaper.selftest.sh ==="

# ── _should_rotate: numeric size vs threshold, boundary inclusive ───────────
_should_rotate 100 50          && ok "should_rotate: size > threshold → true"                              || bad "100 vs 50 should rotate"
_should_rotate 50 50           && ok "should_rotate: size == threshold → true (boundary inclusive)"         || bad "exactly-at-threshold should be inclusive"
_should_rotate 49 50           && bad "should_rotate: size < threshold must NOT rotate"                     || ok "should_rotate: 49 vs 50 → false"
_should_rotate "" 50           && bad "should_rotate: empty size must NEVER authorize (fail toward keep)"   || ok "should_rotate: empty size → false"
_should_rotate "abc" 50        && bad "should_rotate: non-numeric size must NEVER authorize"                || ok "should_rotate: non-numeric size → false"
_should_rotate 100 ""          && bad "should_rotate: empty threshold must NEVER authorize"                 || ok "should_rotate: empty threshold → false"
_should_rotate 100 "abc"       && bad "should_rotate: non-numeric threshold must NEVER authorize"           || ok "should_rotate: non-numeric threshold → false"

echo ""
echo "=== _prod_sentinel_active: same ga-h565g pattern as the sibling reapers ==="
_prod_sentinel_active "a
b" "a
b" ""  && ok "prod_sentinel_active: paths==real default, no PROD → active (blocks)"          || bad "paths==default+no PROD should be active"
_prod_sentinel_active "a
b" "a
b" "0" && ok "prod_sentinel_active: paths==real default, PROD=0 → active (blocks)"           || bad "paths==default+PROD=0 should be active"
_prod_sentinel_active "a
b" "a
b" "1" && bad "prod_sentinel_active: PROD=1 must disable the sentinel even when paths==default" || ok "prod_sentinel_active: paths==default+PROD=1 → not active (allowed)"
_prod_sentinel_active "x" "a
b" ""      && bad "prod_sentinel_active: a DIFFERENT (fixture) path list must never trip the sentinel" || ok "prod_sentinel_active: fixture paths != default → not active"

echo ""
echo "=== _file_size_bytes: thin stat wrapper ==="
TESTFILE="$(mktemp /tmp/log-reaper-selftest-size.XXXXXX)"
head -c 12345 /dev/zero > "$TESTFILE"
GOT="$(_file_size_bytes "$TESTFILE")"
[ "$GOT" = "12345" ] && ok "file_size_bytes: reads correct byte count" || bad "file_size_bytes: expected 12345, got '$GOT'"
GOT_MISSING="$(_file_size_bytes "/nonexistent/path-$$")"
[ -z "$GOT_MISSING" ] && ok "file_size_bytes: missing file → empty (not a crash, not zero)" || bad "file_size_bytes: missing file should be empty, got '$GOT_MISSING'"
rm -f "$TESTFILE"

echo ""
echo "=== main(): end-to-end rotation against fixture files (never real paths) ==="
FIXDIR="$(mktemp -d /tmp/log-reaper-selftest-fixture.XXXXXX)"
# Keep this fixture's default DIFFERENT from any real production path so the
# production sentinel never accidentally engages in these ordinary scenarios.
LOG_REAPER_REAL_DEFAULT_PATHS="/tmp/log-reaper-nonexistent-marker-$$"
# shellcheck disable=SC2034  # read by main() in the sourced script
THRESHOLD_MB=1
THRESHOLD_BYTES=$(( 1 * 1024 * 1024 ))
# shellcheck disable=SC2034  # read by main() in the sourced script
ENABLED=1
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=0
# shellcheck disable=SC2034  # read by _prod_sentinel_active() in the sourced script
PROD=0

BIG="$FIXDIR/big.log"
SMALL="$FIXDIR/small.log"
head -c $(( THRESHOLD_BYTES + 1024 )) /dev/zero > "$BIG"
head -c $(( THRESHOLD_BYTES - 1024 )) /dev/zero > "$SMALL"
BIG_INODE_BEFORE="$(stat -f %i "$BIG")"

LOG_REAPER_PATHS="$BIG
$SMALL
$FIXDIR/does-not-exist.log"
: > "$LOG_REAPER_LOG"
main

BIG_SIZE_AFTER="$(_file_size_bytes "$BIG")"
[ "$BIG_SIZE_AFTER" = "0" ] && ok "main(): oversized file truncated to 0 bytes" || bad "main(): expected BIG truncated to 0, got '$BIG_SIZE_AFTER'"

BIG_INODE_AFTER="$(stat -f %i "$BIG")"
[ "$BIG_INODE_AFTER" = "$BIG_INODE_BEFORE" ] && ok "main(): truncate preserves the inode (safe for a live writer's open fd)" || bad "main(): inode changed ($BIG_INODE_BEFORE -> $BIG_INODE_AFTER) — a live writer's fd would now point at the wrong file"

BACKUP_SIZE="$(_file_size_bytes "$BIG.1")"
[ "$BACKUP_SIZE" = "$(( THRESHOLD_BYTES + 1024 ))" ] && ok "main(): backup .1 holds the pre-truncate content/size" || bad "main(): expected backup size $(( THRESHOLD_BYTES + 1024 )), got '$BACKUP_SIZE'"

SMALL_SIZE_AFTER="$(_file_size_bytes "$SMALL")"
[ "$SMALL_SIZE_AFTER" = "$(( THRESHOLD_BYTES - 1024 ))" ] && ok "main(): under-threshold file left untouched" || bad "main(): SMALL should be untouched, got size '$SMALL_SIZE_AFTER'"

grep -q "does not exist" "$LOG_REAPER_LOG" && ok "main(): missing configured path logged, not a crash" || bad "main(): expected a 'does not exist' log line for the missing fixture path"

grep -q "cycle complete: checked=3 rotated=1 skipped=1 missing=1" "$LOG_REAPER_LOG" && ok "main(): cycle summary counts are correct (checked/rotated/skipped/missing)" || bad "main(): cycle summary mismatch — got: $(grep 'cycle complete' "$LOG_REAPER_LOG")"

echo ""
echo "=== main(): DRY_RUN never mutates ==="
rm -rf "$FIXDIR"; mkdir -p "$FIXDIR"
BIG="$FIXDIR/big.log"
head -c $(( THRESHOLD_BYTES + 1024 )) /dev/zero > "$BIG"
LOG_REAPER_PATHS="$BIG"
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=1
: > "$LOG_REAPER_LOG"
main
DRY_SIZE="$(_file_size_bytes "$BIG")"
[ "$DRY_SIZE" = "$(( THRESHOLD_BYTES + 1024 ))" ] && ok "main(): DRY_RUN=1 leaves an oversized file untouched" || bad "main(): DRY_RUN mutated the file — size is now '$DRY_SIZE'"
grep -q "DRY-RUN would rotate" "$LOG_REAPER_LOG" && ok "main(): DRY_RUN logs the intended action" || bad "main(): expected a 'DRY-RUN would rotate' log line"
[ ! -f "$BIG.1" ] && ok "main(): DRY_RUN creates no backup file" || bad "main(): DRY_RUN should not have created $BIG.1"
DRY_RUN=0

echo ""
echo "=== main(): ENABLED=0 is a total no-op ==="
rm -rf "$FIXDIR"; mkdir -p "$FIXDIR"
BIG="$FIXDIR/big.log"
head -c $(( THRESHOLD_BYTES + 1024 )) /dev/zero > "$BIG"
LOG_REAPER_PATHS="$BIG"
# shellcheck disable=SC2034  # read by main() in the sourced script
ENABLED=0
main
NOOP_SIZE="$(_file_size_bytes "$BIG")"
[ "$NOOP_SIZE" = "$(( THRESHOLD_BYTES + 1024 )) " ] || [ "$NOOP_SIZE" = "$(( THRESHOLD_BYTES + 1024 ))" ] && ok "main(): ENABLED=0 leaves an oversized file untouched" || bad "main(): ENABLED=0 should not mutate — size is now '$NOOP_SIZE'"
# shellcheck disable=SC2034  # read by main() in later scenarios below
ENABLED=1

echo ""
echo "=== main(): production sentinel end-to-end (ga-h565g) ==="
# Hermetic trick: reassign LOG_REAPER_REAL_DEFAULT_PATHS to a fixture path so
# this exercises the REAL main() sentinel-forcing logic without ever pointing
# at the actual six production log paths — mirrors scratchpad-reaper's own
# sentinel end-to-end scenario.
rm -rf "$FIXDIR"; mkdir -p "$FIXDIR"
SENTINEL_FILE="$FIXDIR/sentinel.log"
head -c $(( THRESHOLD_BYTES + 1024 )) /dev/zero > "$SENTINEL_FILE"
LOG_REAPER_PATHS="$SENTINEL_FILE"
LOG_REAPER_REAL_DEFAULT_PATHS="$SENTINEL_FILE"   # pretend this IS "the real default"
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=0
# shellcheck disable=SC2034  # read by _prod_sentinel_active() in the sourced script
PROD=0
main
[ "$(_file_size_bytes "$SENTINEL_FILE")" = "$(( THRESHOLD_BYTES + 1024 ))" ] && ok "main(): paths==real-default + no PROD opt-in → sentinel blocks truncation" || bad "main(): sentinel FAILED to block — real-default-equal path truncated with no PROD opt-in"

head -c $(( THRESHOLD_BYTES + 1024 )) /dev/zero > "$SENTINEL_FILE"
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=0   # ga-h565g leak: the PRIOR main() call's sentinel forced DRY_RUN=1
            # INSIDE main() (no `local`, by design — see scratchpad-reaper's
            # own identical re-set between scenarios) and that mutation
            # persists in this shell across calls; must be reset explicitly
            # before every scenario that expects a real mutation.
PROD=1
main
[ "$(_file_size_bytes "$SENTINEL_FILE")" = "0" ] && ok "main(): PROD=1 allows the real launchd path to rotate normally" || bad "main(): PROD=1 should have allowed rotation"
# shellcheck disable=SC2034  # read by _prod_sentinel_active() via the next main() call below
PROD=0

# Non-regression: a fixture path that never equals the real default must
# rotate normally with no PROD opt-in — the sentinel must never fire for
# ordinary test paths.
rm -rf "$FIXDIR"; mkdir -p "$FIXDIR"
NONDEFAULT_FILE="$FIXDIR/nondefault.log"
head -c $(( THRESHOLD_BYTES + 1024 )) /dev/zero > "$NONDEFAULT_FILE"
# shellcheck disable=SC2034  # read by main() in the sourced script
LOG_REAPER_PATHS="$NONDEFAULT_FILE"
LOG_REAPER_REAL_DEFAULT_PATHS="/tmp/log-reaper-nonexistent-marker-2-$$"   # deliberately NOT $NONDEFAULT_FILE
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=0
main
[ "$(_file_size_bytes "$NONDEFAULT_FILE")" = "0" ] && ok "main(): fixture path (!= real default) rotates normally, sentinel inactive" || bad "main(): fixture path should have rotated — sentinel misfired"

rm -rf "$FIXDIR"

echo ""
echo "=== production constant sanity (ga-h565g) ==="
# Uses the value captured immediately after this file's ONLY source (top of
# file), before any scenario above overrode LOG_REAPER_REAL_DEFAULT_PATHS —
# confirms the six paths actually shipped in production match what this
# bead's incident measured (catches drift between the default list and
# whatever a future edit changes it to).
EXPECTED_PATHS="/private/tmp/appium_server.log
/Users/athos/shared/logs/db_sync_stdout.log
/Users/athos/shared/logs/db_sync.log
/Users/athos/shared/logs/daemon_dashboard.log
/Users/athos/shared/logs/daemon_dashboard_stderr.log
/Users/athos/shared/logs/classification_dashboard_stderr.log"
[ "$PRODUCTION_REAL_DEFAULT_PATHS" = "$EXPECTED_PATHS" ] && ok "production constant: default path list matches the six paths from the bead's own incident" || bad "production constant drifted: got '$PRODUCTION_REAL_DEFAULT_PATHS'"

rm -f "$LOG_REAPER_LOG"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
