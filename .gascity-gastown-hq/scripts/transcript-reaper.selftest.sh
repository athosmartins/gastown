#!/bin/bash
# transcript-reaper.selftest.sh — unit tests for the PURE decision logic of
# transcript-reaper.sh (liveness lookup, mtime staleness, composed reap gate),
# PLUS an end-to-end integration test of main() against a disposable tmp root.
#
# Hermetic: sources the script as a LIBRARY (TRANSCRIPT_REAPER_LIB=1) so
# main() never auto-runs. The unit-test section never calls `gc session list`
# or touches any real file. The integration section DOES call the real
# main()/rm, but only against a throwaway TRANSCRIPT_REAPER_ROOT under /tmp
# that this file creates and removes — never real ~/.claude/projects data —
# with `_fetch_live_keys` stubbed so no real `gc`/jq call happens either.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/transcript-reaper.sh"

export TRANSCRIPT_REAPER_LIB=1
export TRANSCRIPT_REAPER_LOG="/tmp/transcript-reaper-selftest-$$.log"
# shellcheck disable=SC1090
. "$SCRIPT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== transcript-reaper.selftest.sh ==="

# ── fixture: a live-keys file with two known session ids ────────────────────
KEYFILE="$(mktemp /tmp/transcript-reaper-selftest-keys.XXXXXX)"
printf 'alive-session-1\nalive-session-2\n' > "$KEYFILE"
trap 'rm -f "$KEYFILE"' EXIT

# ── _session_is_live: exact-line membership, not substring/prefix ───────────
_session_is_live "alive-session-1" "$KEYFILE" && ok "session_is_live: exact match in keyfile → true" || bad "should be live"
_session_is_live "dead-session-9" "$KEYFILE"   && bad "session_is_live: absent id should be false" || ok "session_is_live: absent id → false"
_session_is_live "alive-session"  "$KEYFILE"   && bad "session_is_live: PREFIX match must NOT count as live (substring false-positive)" || ok "session_is_live: prefix-only is not a match (-x exact line)"
_session_is_live "alive-session-1" "/nonexistent/keyfile-$$" && bad "session_is_live: missing keyfile should be false (fail toward dead, not live)" || ok "session_is_live: missing keyfile → false"

# ── _is_stale: hour-boundary math, non-numeric fail-closed (never stale) ────
NOW=1000000
_is_stale $(( NOW - 73*3600 )) "$NOW" 72 && ok "is_stale: 73h old, min 72h → stale" || bad "73h should be stale at min=72h"
_is_stale $(( NOW - 72*3600 )) "$NOW" 72 && ok "is_stale: exactly 72h old → stale (boundary inclusive)" || bad "72h boundary should be inclusive"
_is_stale $(( NOW - 71*3600 )) "$NOW" 72 && bad "is_stale: 71h old should NOT be stale yet" || ok "is_stale: 71h old → not stale"
_is_stale ""    "$NOW" 72 && bad "is_stale: empty mtime (stat failed) must NOT be stale (never authorize deletion on unreadable mtime)" || ok "is_stale: empty mtime → false (fail toward keep)"
_is_stale "abc" "$NOW" 72 && bad "is_stale: non-numeric mtime should be false" || ok "is_stale: non-numeric mtime → false"

# ── _should_reap: composed gate — self-protection beats everything, then
#    liveness, then staleness ────────────────────────────────────────────────
OLD=$(( NOW - 96*3600 ))
RECENT=$(( NOW - 1*3600 ))
_should_reap "dead-session-9"  "$KEYFILE" "$OLD"    "$NOW" 72 ""               && ok "should_reap: dead + stale + no self set → reap"                            || bad "dead+stale should reap"
_should_reap "alive-session-1" "$KEYFILE" "$OLD"    "$NOW" 72 ""               && bad "should_reap: live session must NEVER reap regardless of age"             || ok "should_reap: live session → never reap"
_should_reap "dead-session-9"  "$KEYFILE" "$RECENT" "$NOW" 72 ""               && bad "should_reap: dead but too recent must NOT reap"                          || ok "should_reap: dead-but-fresh → not yet"
_should_reap "dead-session-9"  "$KEYFILE" "$OLD"    "$NOW" 72 "dead-session-9" && bad "should_reap: CURRENT session id must NEVER reap even if it otherwise qualifies" || ok "should_reap: self-protection overrides dead+stale"
_should_reap "alive-session-1" "$KEYFILE" "$OLD"    "$NOW" 72 "dead-session-9" && bad "should_reap: unrelated self id must not change a live session's outcome" || ok "should_reap: self set but different id → still protected by liveness"

echo ""
echo "=== main(): end-to-end integration against a disposable tmp root ==="
# Fixture layout under a throwaway TRANSCRIPT_ROOT (never real ~/.claude/projects):
#   proj/live-sess.jsonl        — LIVE session, OLD mtime  → must survive (liveness beats age)
#   proj/dead-old.jsonl         — DEAD session, OLD mtime, HAS sibling dir → both removed
#   proj/dead-old/tool-results/x.txt   (the sibling dir contents)
#   proj/dead-fresh.jsonl       — DEAD session, FRESH mtime → must survive (grace period)
#   proj/dead-old-nodir.jsonl   — DEAD session, OLD mtime, NO sibling dir → jsonl removed, no error
#   proj/self-sess.jsonl        — DEAD-per-liveness-list but IS SELF → must survive
TMPROOT="$(mktemp -d /tmp/transcript-reaper-selftest-root.XXXXXX)"
mkdir -p "$TMPROOT/proj/dead-old/tool-results"
echo x > "$TMPROOT/proj/dead-old/tool-results/x.txt"
: > "$TMPROOT/proj/live-sess.jsonl"
: > "$TMPROOT/proj/dead-old.jsonl"
: > "$TMPROOT/proj/dead-fresh.jsonl"
: > "$TMPROOT/proj/dead-old-nodir.jsonl"
: > "$TMPROOT/proj/self-sess.jsonl"

OLD_TS="$(date -v-5d +%Y%m%d%H%M.%S)"
touch -t "$OLD_TS" "$TMPROOT/proj/live-sess.jsonl"
touch -t "$OLD_TS" "$TMPROOT/proj/dead-old.jsonl"
touch -t "$OLD_TS" "$TMPROOT/proj/dead-old/tool-results/x.txt"
touch -t "$OLD_TS" "$TMPROOT/proj/dead-old-nodir.jsonl"
touch -t "$OLD_TS" "$TMPROOT/proj/self-sess.jsonl"
# dead-fresh.jsonl deliberately left at "just created" (now) — within the grace window

# Stub liveness: only "live-sess" is in the live set (no real `gc`/jq call).
_fetch_live_keys() { printf 'live-sess\n' > "$1"; }

# NOTE: these must be the script's INTERNAL variable names (TRANSCRIPT_ROOT,
# ENABLED, DRY_RUN), not their TRANSCRIPT_REAPER_* env-var counterparts — the
# env vars are only read ONCE at source time (already resolved to defaults by
# now); reassigning the env-var names here would silently no-op and leave
# main() scanning the REAL ~/.claude/projects instead of this fixture.
TRANSCRIPT_ROOT="$TMPROOT"
ENABLED=1
DRY_RUN=0
MIN_AGE_HOURS=72
SELF_SESSION_ID="self-sess"

main

[ -f "$TMPROOT/proj/live-sess.jsonl" ] && ok "main(): LIVE session's old transcript survives (liveness beats age)" || bad "main(): live-sess.jsonl was wrongly reaped"
[ -f "$TMPROOT/proj/dead-old.jsonl" ]  && bad "main(): dead+stale transcript should have been reaped" || ok "main(): dead+stale transcript reaped"
[ -d "$TMPROOT/proj/dead-old" ]       && bad "main(): dead+stale transcript's sibling dir should have been reaped too" || ok "main(): dead+stale transcript's sibling dir reaped alongside it"
[ -f "$TMPROOT/proj/dead-fresh.jsonl" ] && ok "main(): dead-but-FRESH transcript survives (grace period)" || bad "main(): dead-fresh.jsonl was wrongly reaped before its grace period elapsed"
[ -f "$TMPROOT/proj/dead-old-nodir.jsonl" ] && bad "main(): dead+stale transcript with no sibling dir should still be reaped" || ok "main(): dead+stale transcript with no sibling dir reaped cleanly (no error from missing dir)"
[ -f "$TMPROOT/proj/self-sess.jsonl" ] && ok "main(): CALLER's own session transcript survives even though absent from the (stubbed) live list" || bad "main(): self-sess.jsonl was wrongly reaped — self-protection failed"

rm -rf "$TMPROOT"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
