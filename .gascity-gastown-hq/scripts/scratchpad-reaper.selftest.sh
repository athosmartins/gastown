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

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
