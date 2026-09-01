#!/usr/bin/env bash
# prod-tests/gascity/story-ga-311q7.sh — prod test for ga-311q7:
# quiet-hours-check.sh's header described the night-window mechanism as
# active, citing only Athos's 2026-08-16 "turn it on" decision. The
# 2026-08-20 "turn it off" decision (launchctl bootout of
# com.gascity.city-night-window, commit 38ebc51ed, permanent) only appeared
# ~50 lines down, inside _quiet_hours_unreadable()'s comment — so a reader
# of just the header drew the wrong conclusion. That cost a real
# investigation (ga-ka2c2, opened as a P2 bug on the inverted premise,
# closed as non-bug).
#
# Verifies the DEPLOYED quiet-hours-check.sh and city-night-window.sh both
# state the 2026-08-20 shutdown, with the commit citation, within the first
# 20 lines — not merely somewhere in the file — plus a functional regression
# check that the header-only edit did not change runtime behavior.
#
# Called by run.sh after deploy (STORY_ID=ga-311q7). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
QHC="$CITY/packs/town-deltas/assets/quiet-hours-check.sh"
CNW="$CITY/scripts/city-night-window.sh"
HEADER_LINE_BUDGET=20

log()  { echo "[prod-test:gascity ga-311q7] $*"; }
fail() { echo "[prod-test:gascity ga-311q7] FAIL: $*" >&2; exit 1; }

[[ -f "$QHC" ]] || fail "missing: $QHC"
[[ -f "$CNW" ]] || fail "missing: $CNW"

# ── helper: first line number where $2 (grep -E pattern) matches in $1 ─────────
first_match_line() {
    grep -nE "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1
}

# ── 1. quiet-hours-check.sh header states the 2026-08-20 shutdown + commit ─────
log "Checking quiet-hours-check.sh header for the 2026-08-20 shutdown..."
L=$(first_match_line "$QHC" '2026-08-20')
[[ -n "$L" ]] || fail "no mention of 2026-08-20 in quiet-hours-check.sh"
[[ "$L" -le "$HEADER_LINE_BUDGET" ]] || fail "2026-08-20 mentioned at line $L — not within the first $HEADER_LINE_BUDGET (buried again, same defect class as ga-ka2c2)"
log "  found at line $L ✓"

L=$(first_match_line "$QHC" '38ebc51ed')
[[ -n "$L" ]] || fail "commit 38ebc51ed not cited in quiet-hours-check.sh"
[[ "$L" -le "$HEADER_LINE_BUDGET" ]] || fail "38ebc51ed cited at line $L — not within the first $HEADER_LINE_BUDGET"
log "  commit citation at line $L ✓"

# The pre-existing 2026-08-16 "turned it on" decision must still be present
# (added ALONGSIDE, not replacing it — per the story's explicit ask).
grep -q '2026-08-16' "$QHC" || fail "2026-08-16 decision no longer mentioned — must be kept, not replaced"
log "  2026-08-16 decision still present ✓"

# ── 2. city-night-window.sh header states the same, in its own language ────────
log "Checking city-night-window.sh header for the 20/08 shutdown..."
L=$(first_match_line "$CNW" '20/08')
[[ -n "$L" ]] || fail "no mention of 20/08 in city-night-window.sh"
[[ "$L" -le "$HEADER_LINE_BUDGET" ]] || fail "20/08 mentioned at line $L — not within the first $HEADER_LINE_BUDGET"
log "  found at line $L ✓"

L=$(first_match_line "$CNW" '38ebc51ed')
[[ -n "$L" ]] || fail "commit 38ebc51ed not cited in city-night-window.sh"
[[ "$L" -le "$HEADER_LINE_BUDGET" ]] || fail "38ebc51ed cited at line $L — not within the first $HEADER_LINE_BUDGET"
log "  commit citation at line $L ✓"

grep -q '16/08' "$CNW" || fail "16/08 decision no longer mentioned — must be kept, not replaced"
log "  16/08 decision still present ✓"

# ── 3. Syntax: comment-only edit must not have broken either script ────────────
log "Checking bash syntax..."
bash -n "$QHC" || fail "quiet-hours-check.sh has a syntax error"
bash -n "$CNW" || fail "city-night-window.sh has a syntax error"
log "  syntax OK ✓"

# ── 4. Functional regression: sourcing + the 3 functions still behave ──────────
# Today's real production state is "mechanism off, level file absent" — this
# is also exactly the state the new header now describes, so this doubles as
# a check that the doc now matches the artifact.
log "Checking _quiet_hours_* functions still behave correctly for the current (absent-file) state..."
# shellcheck disable=SC1090
(
    QUIET_HOURS_LEVEL_FILE="/tmp/.story-ga-311q7-nonexistent-level-$$"
    unset QUIET_HOURS_OVERRIDE 2>/dev/null || true
    source "$QHC"
    BLOCKS=$(_quiet_hours_blocks)
    STATE=$(_quiet_hours_state)
    UNREADABLE=$(_quiet_hours_unreadable)
    [[ "$BLOCKS" == "0" ]] || { echo "_quiet_hours_blocks=$BLOCKS, want 0 (absent file must fail open)" >&2; exit 1; }
    [[ "$STATE" == "" ]] || { echo "_quiet_hours_state=$STATE, want empty (absent file)" >&2; exit 1; }
    [[ "$UNREADABLE" == "0" ]] || { echo "_quiet_hours_unreadable=$UNREADABLE, want 0 (ga-w8kbf: absent is silent, not an anomaly)" >&2; exit 1; }
) || fail "functional regression in quiet-hours-check.sh's absent-file handling"
log "  functional behavior unchanged ✓"

log "PASS — both headers lead with 16/08 \"on\" -> 20/08 \"off\" (commit 38ebc51ed), within $HEADER_LINE_BUDGET lines; runtime behavior unchanged"
exit 0
