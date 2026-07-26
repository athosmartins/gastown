#!/bin/bash
# scratchpad-reaper.selftest.sh — unit tests for the PURE decision logic of
# scratchpad-reaper.sh: liveness lookup, mtime staleness, and the composed
# reap gate (dead AND stale AND not-self).
#
# Hermetic: sources the script as a LIBRARY (SCRATCHPAD_REAPER_LIB=1) so
# main() never runs, points the log at a throwaway path. Never calls
# `gc session list`, never `rm -rf`s anything, never touches real
# /private/tmp/claude-* data — all fixtures are synthetic temp files/values.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/scratchpad-reaper.sh"

export SCRATCHPAD_REAPER_LIB=1
export SCRATCHPAD_REAPER_LOG="/tmp/scratchpad-reaper-selftest-$$.log"
# shellcheck disable=SC1090
. "$SCRIPT"

# Captured immediately after the ONLY source of this file, before any test
# below overrides SCRATCH_REAL_DEFAULT_ROOT for hermetic fixture scenarios —
# this is the pristine production value (ga-h565g production-constant check
# near the end of this file). Deliberately NOT re-sourced later: main()'s
# `trap ... RETURN` (harmless in production, where every real invocation is a
# fresh subprocess) leaks past a single function return in bash and fires
# again on the next sourced-script completion in the SAME shell, by which
# point the original invocation's local $keyfile is out of scope — re-sourcing
# after this file's main() scenarios run would hit that landmine under `set -u`.
PRODUCTION_REAL_DEFAULT_ROOT="$SCRATCH_REAL_DEFAULT_ROOT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== scratchpad-reaper.selftest.sh ==="

# ── fixture: a live-keys file with two known session ids ────────────────────
KEYFILE="$(mktemp /tmp/scratchpad-reaper-selftest-keys.XXXXXX)"
printf 'alive-session-1\nalive-session-2\n' > "$KEYFILE"
trap 'rm -f "$KEYFILE"' EXIT

# ── _session_is_live: exact-line membership, not substring/prefix ───────────
_session_is_live "alive-session-1" "$KEYFILE" && ok "session_is_live: exact match in keyfile → true" || bad "should be live"
_session_is_live "dead-session-9" "$KEYFILE"   && bad "session_is_live: absent id should be false" || ok "session_is_live: absent id → false"
_session_is_live "alive-session"  "$KEYFILE"   && bad "session_is_live: PREFIX match must NOT count as live (substring false-positive)" || ok "session_is_live: prefix-only is not a match (-x exact line)"
_session_is_live "alive-session-1" "/nonexistent/keyfile-$$" && bad "session_is_live: missing keyfile should be false (fail toward dead, not live)" || ok "session_is_live: missing keyfile → false"

# ── _is_stale: hour-boundary math, non-numeric fail-closed (never stale) ────
NOW=1000000
_is_stale $(( NOW - 25*3600 )) "$NOW" 24 && ok "is_stale: 25h old, min 24h → stale" || bad "25h should be stale at min=24h"
_is_stale $(( NOW - 24*3600 )) "$NOW" 24 && ok "is_stale: exactly 24h old → stale (boundary inclusive)" || bad "24h boundary should be inclusive"
_is_stale $(( NOW - 23*3600 )) "$NOW" 24 && bad "is_stale: 23h old should NOT be stale yet" || ok "is_stale: 23h old → not stale"
_is_stale ""    "$NOW" 24 && bad "is_stale: empty mtime (stat failed) must NOT be stale (never authorize deletion on unreadable mtime)" || ok "is_stale: empty mtime → false (fail toward keep)"
_is_stale "abc" "$NOW" 24 && bad "is_stale: non-numeric mtime should be false" || ok "is_stale: non-numeric mtime → false"

# ── _should_reap: composed gate — self-protection beats everything, then
#    liveness, then staleness ────────────────────────────────────────────────
OLD=$(( NOW - 48*3600 ))
RECENT=$(( NOW - 1*3600 ))
_should_reap "dead-session-9"  "$KEYFILE" "$OLD"    "$NOW" 24 ""               && ok "should_reap: dead + stale + no self set → reap"                            || bad "dead+stale should reap"
_should_reap "alive-session-1" "$KEYFILE" "$OLD"    "$NOW" 24 ""               && bad "should_reap: live session must NEVER reap regardless of age"             || ok "should_reap: live session → never reap"
_should_reap "dead-session-9"  "$KEYFILE" "$RECENT" "$NOW" 24 ""               && bad "should_reap: dead but too recent must NOT reap"                          || ok "should_reap: dead-but-fresh → not yet"
_should_reap "dead-session-9"  "$KEYFILE" "$OLD"    "$NOW" 24 "dead-session-9" && bad "should_reap: CURRENT session id must NEVER reap even if it otherwise qualifies" || ok "should_reap: self-protection overrides dead+stale"
_should_reap "alive-session-1" "$KEYFILE" "$OLD"    "$NOW" 24 "dead-session-9" && bad "should_reap: unrelated self id must not change a live session's outcome" || ok "should_reap: self set but different id → still protected by liveness"

# ── _prod_sentinel_active: PRODUCTION SENTINEL (ga-h565g) — a resolved root
#    equal to the real default with no explicit prod opt-in must block
#    deletion. Pure/no filesystem access: these pass plain strings; the actual
#    production constant is exercised separately below via main() ──────────
_prod_sentinel_active "/private/tmp/claude-501" "/private/tmp/claude-501" ""  && ok "prod_sentinel_active: root==real default, no PROD → active (blocks)"        || bad "root==default+no PROD should be active"
_prod_sentinel_active "/private/tmp/claude-501" "/private/tmp/claude-501" "0" && ok "prod_sentinel_active: root==real default, PROD=0 → active (blocks)"         || bad "root==default+PROD=0 should be active"
_prod_sentinel_active "/private/tmp/claude-501" "/private/tmp/claude-501" "1" && bad "prod_sentinel_active: PROD=1 must disable the sentinel even when root==default" || ok "prod_sentinel_active: root==default+PROD=1 → not active (allowed)"
_prod_sentinel_active "/tmp/some-fixture-root"  "/private/tmp/claude-501" ""  && bad "prod_sentinel_active: a DIFFERENT (fixture) root must never trip the sentinel"  || ok "prod_sentinel_active: fixture root != default → not active"
_prod_sentinel_active "/tmp/some-fixture-root"  "/private/tmp/claude-501" "1" && bad "prod_sentinel_active: fixture root + PROD=1 must still be inactive"        || ok "prod_sentinel_active: fixture root + PROD=1 → not active"

echo ""
echo "=== main(): production sentinel end-to-end (ga-h565g) ==="
# Hermetic trick: reassign SCRATCH_REAL_DEFAULT_ROOT (a plain global, not
# readonly) to a disposable tmp path so these scenarios exercise the REAL
# main() sentinel-forcing logic end-to-end without ever pointing at the
# actual /private/tmp/claude-<uid> — the sentinel compares SCRATCH_ROOT
# against WHATEVER SCRATCH_REAL_DEFAULT_ROOT currently holds, so this is a
# faithful exercise of the same code path production uses, just pointed at a
# throwaway fixture. A separate check further below (outside this override)
# confirms the constant's REAL value is the actual expected production path.
_fetch_live_keys() { : > "$1"; }  # nobody "live" — every candidate is dead
OLD_TS="$(date -v-5d +%Y%m%d%H%M.%S)"
SENTINEL_ROOT="$(mktemp -d /tmp/scratchpad-reaper-selftest-sentinel.XXXXXX)"

make_sentinel_fixture() {
  rm -rf "$SENTINEL_ROOT"
  mkdir -p "$SENTINEL_ROOT/proj/dead-old/scratchpad"
  touch -t "$OLD_TS" "$SENTINEL_ROOT/proj/dead-old/scratchpad"
}

SCRATCH_REAL_DEFAULT_ROOT="$SENTINEL_ROOT"   # pretend this tmp dir IS "the real default"
SCRATCH_ROOT="$SENTINEL_ROOT"                # and the resolved root equals it exactly
# shellcheck disable=SC2034  # read by main() in the sourced script
ENABLED=1
# shellcheck disable=SC2034  # read by main()/_should_reap in the sourced script
MIN_AGE_HOURS=24
# shellcheck disable=SC2034  # read by main()/_should_reap in the sourced script
SELF_SESSION_ID=""

# Scenario: real-default root, no PROD opt-in → must NOT delete.
make_sentinel_fixture
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=0
# shellcheck disable=SC2034  # read by main() in the sourced script
PROD=0
main
[ -d "$SENTINEL_ROOT/proj/dead-old/scratchpad" ] && ok "main(): root==real-default + no PROD opt-in → candidate survives (sentinel blocks deletion)" || bad "main(): sentinel FAILED to block — real-default root deleted data with no PROD opt-in"

# Scenario: same root, PROD=1 → normal reap resumes (real launchd-path behavior).
make_sentinel_fixture
DRY_RUN=0; PROD=1
main
[ -d "$SENTINEL_ROOT/proj/dead-old/scratchpad" ] && bad "main(): PROD=1 should allow the real launchd path to reap normally" || ok "main(): root==real-default + PROD=1 → reaps normally (opt-in respected)"

rm -rf "$SENTINEL_ROOT"

# Non-regression: a FIXTURE root (never equal to the real default) must reap
# normally with no PROD opt-in at all — the sentinel must never fire for
# ordinary test/tmp-fixture roots, only for the literal real-default value.
FIXTURE_ROOT="$(mktemp -d /tmp/scratchpad-reaper-selftest-fixture.XXXXXX)"
mkdir -p "$FIXTURE_ROOT/proj/dead-old/scratchpad"
touch -t "$OLD_TS" "$FIXTURE_ROOT/proj/dead-old/scratchpad"
SCRATCH_REAL_DEFAULT_ROOT="/private/tmp/claude-nonexistent-marker-$$"  # deliberately NOT $FIXTURE_ROOT
# shellcheck disable=SC2034  # read by main() in the sourced script
SCRATCH_ROOT="$FIXTURE_ROOT"
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=0
# shellcheck disable=SC2034  # read by main() in the sourced script
PROD=0
main
[ -d "$FIXTURE_ROOT/proj/dead-old/scratchpad" ] && bad "main(): fixture root (!= real default) must reap normally, sentinel must not fire" || ok "main(): fixture root (!= real default) → sentinel inactive, reaps normally (no regression)"
rm -rf "$FIXTURE_ROOT"

echo ""
echo "=== production constant sanity (ga-h565g) ==="
# Uses the value captured immediately after this file's ONLY source (top of
# file), before any scenario above overrode SCRATCH_REAL_DEFAULT_ROOT for
# hermetic testing — confirms the constant actually used in production is
# exactly the expected real default (catches drift between the
# default-resolution line and the sentinel-comparison constant).
[ "$PRODUCTION_REAL_DEFAULT_ROOT" = "/private/tmp/claude-$(id -u)" ] && ok "production constant: SCRATCH_REAL_DEFAULT_ROOT matches the expected real default path" || bad "production constant drifted: got '$PRODUCTION_REAL_DEFAULT_ROOT'"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
