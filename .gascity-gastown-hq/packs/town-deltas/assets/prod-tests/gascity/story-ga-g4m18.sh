#!/usr/bin/env bash
# prod-tests/gascity/story-ga-g4m18.sh — prod test for ga-g4m18: Vector B
# (quality-gate-guard.sh) cascade-closes a gate-run's own OPEN
# type:quality-gate-verdict beads when it supersedes that gate-run via the
# dead-reviewer rule (supersede:dead-reviewers, ga-o57gn). Before this fix,
# reviewers_alive_for_run confirmed every open verdict bead was assigned to a
# dead session, the gate-run bead itself got closed right there — but the
# verdict beads never did, leaving them open+in_progress, assigned to a
# ghost session, indefinitely (observed live: ga-ydf9v/ga-z8erc, hand-closed
# by the Mayor as a one-off).
#
# Verifies the fix landed on the DEPLOYED quality-gate-guard.sh: the pure
# projection (open_verdict_ids_from_json) and I/O wrapper
# (close_dead_reviewer_verdicts) are both present, the wrapper is wired into
# the supersede:dead-reviewers case specifically (not a sibling branch), then
# reuses the feature's own selftest (quality-gate-reconcile.selftest.sh —
# 236 assertions, covers the pure projection end-to-end plus drift-guards +
# a mutation-lock proving the wiring check isn't vacuous) rather than
# re-asserting the same checks here.
#
# Called by run.sh after deploy (STORY_ID=ga-g4m18). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
GUARD="$CITY/packs/town-deltas/assets/quality-gate-guard.sh"
SELFTEST="$CITY/packs/town-deltas/assets/quality-gate-reconcile.selftest.sh"

log()  { echo "[prod-test:gascity ga-g4m18] $*"; }
fail() { echo "[prod-test:gascity ga-g4m18] FAIL: $*" >&2; exit 1; }

[[ -f "$GUARD" ]]    || fail "quality-gate-guard.sh missing: $GUARD"
# Invoked via `bash "$SELFTEST"` below rather than requiring -x: this file
# (like 9 of its 103 selftest siblings, pre-existing and unrelated to this
# fix) is checked into git as 100644, not 100755.
[[ -f "$SELFTEST" ]] || fail "selftest missing: $SELFTEST"

log "Checking the pure projection is present..."
grep -qF 'open_verdict_ids_from_json()' "$GUARD" \
  || fail "open_verdict_ids_from_json not found in deployed quality-gate-guard.sh — the fix did not deploy"
log "  open_verdict_ids_from_json present ✓"

log "Checking the I/O wrapper is present..."
grep -qF 'close_dead_reviewer_verdicts()' "$GUARD" \
  || fail "close_dead_reviewer_verdicts not found in deployed quality-gate-guard.sh"
log "  close_dead_reviewer_verdicts present ✓"

log "Checking the wrapper is wired specifically into supersede:dead-reviewers..."
DEAD_ARM="$(sed -n '/supersede:dead-reviewers)/,/;;/p' "$GUARD")"
printf '%s\n' "$DEAD_ARM" | grep -qF 'close_dead_reviewer_verdicts "$GR_ID"' \
  || fail "close_dead_reviewer_verdicts is not called inside supersede:dead-reviewers) on the deployed guard"
log "  wired into supersede:dead-reviewers ✓"

log "Running the feature's own selftest (covers the pure projection end-to-end, drift-guards, and a mutation-lock)..."
if ! bash "$SELFTEST" >/tmp/.story-ga-g4m18-selftest.$$ 2>&1; then
    tail -30 "/tmp/.story-ga-g4m18-selftest.$$" >&2
    rm -f "/tmp/.story-ga-g4m18-selftest.$$"
    fail "selftest did not pass on the deployed artifact"
fi
rm -f "/tmp/.story-ga-g4m18-selftest.$$"
log "  selftest PASS ✓"

log "PASS — verdict cascade-close deployed and wired into supersede:dead-reviewers"
exit 0
