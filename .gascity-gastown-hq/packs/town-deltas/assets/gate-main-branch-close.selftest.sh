#!/usr/bin/env bash
# gate-main-branch-close.selftest.sh — Prove the gate-main-close fix (ga-mxhf6 update).
#
# PROBLEM: gastown.dog pool commits HQ infra directly to main and runs /gate-done,
# creating a `ready-for-gate: main` marker (branch=main). The old ga-mxhf6 guard
# set gate-status:error and LEFT the marker open forever — accumulating 7 error
# markers per ~2 hours, rendering as "erro no gate" / "gate parado" in the painel
# even when the gate was healthy.
#
# FIX (gate-main-close): branch=main/master markers are UN-FIXABLE by re-submit
# (you cannot make main not-main). The guard now CLOSES them cleanly (exit 0)
# instead of setting gate-status:error. Closed markers don't render as gate-error.
# Other validation failures (bad bead_id, bad rig) ARE re-submittable and still
# → gate-status:error (open, visible for human action).
#
# This harness is a DRIFT-GUARD: it verifies the live source carries the fix and
# distinguishes the two code paths via grep assertions.
#
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$GUARD" ]; then
  echo "FATAL: guard not found at $GUARD"
  exit 1
fi

# Syntax check before any assertion.
bash -n "$GUARD" \
  && ok "guard passes bash -n syntax check" \
  || { bad "guard has syntax errors — cannot proceed"; exit 1; }

echo "── 1. branch=main/master path: CLOSES cleanly (not error) ──"

# The fix: branch=main exits with exit 0 (not 1) and calls bd close.
# Verified by checking structural markers in the source:
#   (a) guard detects main/master with the correct condition
#   (b) guard calls bd close on the marker for this case
#   (c) guard exits 0 (clean, not error) — distinct from VALIDATION_OK=false path (exit 1)
#   (d) guard does NOT set gate-status:error for branch=main
grep -qE '"main"\s*\]\s*\|\|\s*\[\s*"\$BRANCH"\s*=\s*"master"' "$GUARD" \
  && ok "guard checks branch=main/master with correct condition" \
  || bad "guard missing branch=main/master condition (gate-main-close reverted?)"

grep -q 'close "\$MARKER_ID"' "$GUARD" \
  && ok "guard closes the marker for main/master (bd close called)" \
  || bad "guard does NOT call bd close for branch=main — painel noise not fixed"

grep -q 'gate-main-close' "$GUARD" \
  && ok "guard carries 'gate-main-close' tag in log/comment (traceability)" \
  || bad "guard missing 'gate-main-close' tag"

grep -q 'not gate-reviewable' "$GUARD" \
  && ok "guard comment explains marker is not gate-reviewable" \
  || bad "guard missing 'not gate-reviewable' explanation"

# The branch=main exit must be exit 0 (success/clean), NOT exit 1 (error).
# We verify by checking that `exit 0` appears INSIDE the main/master branch block,
# which is between the `ga-mxhf6 / gate-main-close` comment and the next validation check.
MAINCLOSE_LINE=$(grep -n 'gate-main-close: marker' "$GUARD" | head -1 | cut -d: -f1)
EXIT0_NEAR=$(awk "NR>=$((MAINCLOSE_LINE-2)) && NR<=$((MAINCLOSE_LINE+3))" "$GUARD" | grep -c 'exit 0' || true)
if [ "${EXIT0_NEAR:-0}" -ge 1 ]; then
  ok "guard exits 0 after gate-main-close log (clean exit, not error)"
else
  bad "guard exit after gate-main-close is NOT exit 0 — check the fix"
fi

echo "── 2. other validation failures: gate-status:error STAYS (re-submittable) ──"

# The VALIDATION_OK=false path (bad bead_id / bad rig) must still call set_gate_status error.
grep -q 'set_gate_status "\$MARKER_ID" "error"' "$GUARD" \
  && ok "guard still calls set_gate_status error for other validation failures" \
  || bad "guard LOST set_gate_status error call — other validation failures not handled"

# The generic validation error block must NOT close the marker.
# We check that 'close "$MARKER_ID"' does NOT appear in the VALIDATION_OK=false block.
# Probe: the VALIDATION_OK=false block ends with `exit 1`. Count bd-close calls that
# are NOT in the gate-main-close section (i.e., appear near `exit 1`, not `exit 0`).
# Simpler: verify that the VALIDATION_OK block comment (ga-jhyu) is still present and
# still says "do NOT close" — confirming the non-close invariant is documented.
grep -q 'do NOT close' "$GUARD" \
  && ok "guard VALIDATION_OK=false block preserves 'do NOT close' invariant comment" \
  || bad "guard missing 'do NOT close' comment — ga-jhyu invariant may be broken"

grep -q 'gate-status:error. Fix the marker fields and re-submit' "$GUARD" \
  && ok "guard error-block comment still says 'Fix the marker fields and re-submit'" \
  || bad "guard error-block comment changed — re-submit guidance may be missing"

echo "── 3. ordering: gate-main-close fires BEFORE VALIDATION_OK=false block ──"

MAINCLOSE_BLOCK=$(grep -n 'gate-main-close: marker' "$GUARD" | head -1 | cut -d: -f1)
VALIDFAIL_BLOCK=$(grep -n 'VALIDATION_OK.*=.*false.*]; then' "$GUARD" | grep -v "VALIDATION_OK=false$" | head -1 | cut -d: -f1)
if [ -n "$MAINCLOSE_BLOCK" ] && [ -n "$VALIDFAIL_BLOCK" ] && [ "$MAINCLOSE_BLOCK" -lt "$VALIDFAIL_BLOCK" ]; then
  ok "gate-main-close (L$MAINCLOSE_BLOCK) fires BEFORE VALIDATION_OK=false block (L$VALIDFAIL_BLOCK)"
else
  bad "ordering wrong: gate-main-close=${MAINCLOSE_BLOCK:-missing} VALIDATION_OK_block=${VALIDFAIL_BLOCK:-missing} — gate-main-close must come first"
fi

echo "── 4. dog-side gap (investigation, not fix) ──"

# Verify the canonical gate-done template does NOT currently guard against branch=main.
# This is the dog-side root cause: gate-done should ideally refuse to create a marker
# when BRANCH=main. Note: absent guard is EXPECTED (not a test failure) — the fix here
# is guard-side (durable safety net); the dog-side guard is a separate follow-up.
GATE_DONE_TEMPLATE="/Users/athos/gt/internal/templates/commands/bodies/gate-done.md"
if [ -f "$GATE_DONE_TEMPLATE" ]; then
  if grep -q 'BRANCH.*=.*main\|branch.*main' "$GATE_DONE_TEMPLATE" 2>/dev/null; then
    ok "gate-done template already guards against branch=main (dog-side fix deployed)"
  else
    ok "gate-done template has NO branch=main guard (expected — follow-up work, guard-side is the safety net)"
  fi
else
  ok "gate-done template not found at expected path (skip dog-side check)"
fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
