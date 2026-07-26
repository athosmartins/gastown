#!/bin/bash
# orphan-session-dir-reaper.selftest.sh — unit tests for the PURE decision logic of
# orphan-session-dir-reaper.sh: liveness lookup, mtime staleness, and the composed
# reap gate (dead AND no-matching-jsonl AND stale AND not-self).
#
# Hermetic: sources the script as a LIBRARY (ORPHAN_SESSION_DIR_REAPER_LIB=1) so
# main() never runs, points the log at a throwaway path. Never calls `gc session
# list`, never `rm -rf`s anything, never touches real ~/.claude/projects data — all
# fixtures are synthetic temp files/values.
#
# ga-t1ub9 INCIDENT LESSON (2026-07-26): a sibling reaper's selftest set the WRONG
# env var name to redirect its root at a tmp fixture (a typo'd prefix), so main()
# silently fell back to its default and ran against the REAL ~/.claude/projects with
# a stubbed liveness list — 185 real transcripts (62MB) deleted. This selftest
# structurally cannot repeat that failure mode: it never invokes main() at all (LIB
# mode short-circuits it below), so there is no root-path override for a typo to
# defeat in the first place.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/orphan-session-dir-reaper.sh"

export ORPHAN_SESSION_DIR_REAPER_LIB=1
export ORPHAN_SESSION_DIR_REAPER_LOG="/tmp/orphan-session-dir-reaper-selftest-$$.log"
# shellcheck disable=SC1090
. "$SCRIPT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== orphan-session-dir-reaper.selftest.sh ==="

# ── _looks_like_session_id: UUID-shape pre-filter — every entry actually
#    written by Claude Code under a project dir is `<uuid>.jsonl` or `<uuid>/`;
#    this keeps a coincidentally-named unrelated directory from ever becoming a
#    reap candidate in the first place (defense in depth, cheap to check) ────
_looks_like_session_id "02a9ccad-daa3-4838-b705-5574ea57cb58" && ok "looks_like_session_id: real UUID shape → true" || bad "valid UUID should match"
_looks_like_session_id "tool-results"                          && bad "looks_like_session_id: non-UUID dir name must NOT match"          || ok "looks_like_session_id: non-UUID name → false"
_looks_like_session_id "-Users-athos-gt-some-project-slug"     && bad "looks_like_session_id: project-dir-shaped slug must NOT match"    || ok "looks_like_session_id: project-slug shape → false"
_looks_like_session_id ""                                      && bad "looks_like_session_id: empty string must NOT match"              || ok "looks_like_session_id: empty → false"

# ── fixture: a live-keys file with two known session ids ────────────────────
KEYFILE="$(mktemp /tmp/orphan-session-dir-reaper-selftest-keys.XXXXXX)"
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

# ── _should_reap: composed gate — self-protection, then liveness, then
#    has-jsonl (the differentiator vs scratchpad-reaper's gate), then staleness ──
OLD=$(( NOW - 96*3600 ))
RECENT=$(( NOW - 1*3600 ))
# args: sid keyfile has_jsonl mtime now min_hours self
_should_reap "dead-session-9"  "$KEYFILE" 0 "$OLD"    "$NOW" 72 ""               && ok "should_reap: dead + no-jsonl + stale + no self set → reap"                     || bad "dead+no-jsonl+stale should reap"
_should_reap "alive-session-1" "$KEYFILE" 0 "$OLD"    "$NOW" 72 ""               && bad "should_reap: live session must NEVER reap regardless of age/jsonl"          || ok "should_reap: live session → never reap"
_should_reap "dead-session-9"  "$KEYFILE" 1 "$OLD"    "$NOW" 72 ""               && bad "should_reap: a matching .jsonl means NOT orphan — must never reap"          || ok "should_reap: has-jsonl (not orphan) → never reap"
_should_reap "dead-session-9"  "$KEYFILE" 0 "$RECENT" "$NOW" 72 ""               && bad "should_reap: dead+no-jsonl but too recent must NOT reap"                    || ok "should_reap: dead+no-jsonl-but-fresh → not yet"
_should_reap "dead-session-9"  "$KEYFILE" 0 "$OLD"    "$NOW" 72 "dead-session-9" && bad "should_reap: CURRENT session id must NEVER reap even if it otherwise qualifies" || ok "should_reap: self-protection overrides dead+no-jsonl+stale"
_should_reap "alive-session-1" "$KEYFILE" 0 "$OLD"    "$NOW" 72 "dead-session-9" && bad "should_reap: unrelated self id must not change a live session's outcome"     || ok "should_reap: self set but different id → still protected by liveness"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
