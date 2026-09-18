#!/usr/bin/env bash
# story-delivery-closed-bead-guard.selftest.sh — Prove the ga-rugqks fix in
# isolation, with NO live Dolt/gc/launchd:
#
#   BUG (ga-rugqks): story-delivery.sh's Step 1 selector decides which beads
#   enter the per-story loop by LABEL (story:approved + gate:passed, minus
#   story:done) — a snapshot taken once at the top of the sweep. The loop
#   body then never re-checks a bead's CURRENT status before mutating it; it
#   only ever reads $STORY_LABELS, that same stale snapshot. A bead closed
#   OUT OF BAND (a human closing it directly after independently verifying
#   delivery) between the snapshot and this iteration's own mutations gets
#   reprocessed as if still live. Step 5b's own daemon-refresh subprocess
#   alone is documented elsewhere in this file
#   (task_reconciler_gate_passed_too_fresh's header, wa-n27z0) to take up to
#   6.5-10 minutes per cycle — plenty of time for exactly that race.
#
#   Live case: the Mayor closed wa-a7tca at 21:23:57 (delivered, verified
#   live). The sweep re-added delivery:failed + delivery:deploy-pending,
#   commented, and re-nudged its owner at 21:33:55 — ~10 minutes later, over
#   work that was already done and already had proof.
#
#   FIX: story-delivery.sh now defines story_bead_closed_now(store, id),
#   which always re-queries live status via `bd show` (never trusts
#   $STORY_LABELS) and fails OPEN (not-closed) on any bd error/empty/
#   unparseable result. It is called at two points in the main per-story
#   loop:
#     (a) immediately after entering each iteration, before the
#         story:done/delivery:running idempotency skips, before the
#         delivery:running claim, and before Step 2 (rig determination) —
#         this is the primary guard, and also prevents re-running
#         reconcile/merge-verify/deploy against an already-closed bead;
#     (b) immediately after the daemon-refresh subprocess returns, before
#         evaluating REFRESH_VERDICT — this is the one step in the loop
#         documented to take several minutes on its own, and is exactly
#         where the live incident's own timestamps land.
#   Either guard `continue`s (no label/comment/nudge mutation) the instant
#   it finds the bead already closed.
#
# This harness sources story-delivery.sh in lib-only mode to unit-test the
# REAL function (one source of truth, no copy-drift), then DRIFT-GUARDS the
# live script so a future refactor can't drop, reorder, or defang either
# call site silently. Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/story-delivery.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── 0. bash -n clean ─────────────────────────────────────────────────────────
echo "── 0. bash -n (syntax) ──"
if bash -n "$SCRIPT" 2>/tmp/sd-closed-guard-syntax.$$; then
  ok "bash -n $SCRIPT"
else
  bad "bash -n $SCRIPT: $(cat /tmp/sd-closed-guard-syntax.$$)"
fi
rm -f /tmp/sd-closed-guard-syntax.$$

# ── Load the REAL function (lib-only = no live sweep) ───────────────────────
STORY_DELIVERY_LIB_ONLY=1 source "$SCRIPT" \
  || { echo "FATAL: could not source story-delivery.sh in lib-only mode"; exit 1; }
type story_bead_closed_now >/dev/null 2>&1 \
  || { echo "FATAL: story_bead_closed_now not defined by story-delivery.sh"; exit 1; }

# ── 1. story_bead_closed_now — pure decision, every branch (mock bd) ───────
echo "── 1. story_bead_closed_now (mock bd show) ──"
MOCK_SHOW_OUT=""
MOCK_SHOW_RC=0
bd() {
  case " $* " in
    *" show "*) printf '%s\n' "$MOCK_SHOW_OUT"; return "$MOCK_SHOW_RC" ;;
    *) return 0 ;;
  esac
}

MOCK_SHOW_OUT='{"id":"wa-a7tca","status":"closed"}'; MOCK_SHOW_RC=0
if story_bead_closed_now store wa-a7tca; then
  ok "(a) status=closed (object shape) -> true"
else
  bad "(a) status=closed (object shape) -> expected true, got false"
fi

MOCK_SHOW_OUT='[{"id":"wa-a7tca","status":"closed"}]'; MOCK_SHOW_RC=0
if story_bead_closed_now store wa-a7tca; then
  ok "(b) status=closed (array shape, --json list-style) -> true"
else
  bad "(b) status=closed (array shape) -> expected true, got false"
fi

MOCK_SHOW_OUT='{"id":"wa-a7tca","status":"open"}'; MOCK_SHOW_RC=0
if story_bead_closed_now store wa-a7tca; then
  bad "(c) status=open -> expected false, got true (THE BUG SHAPE if this fires)"
else
  ok "(c) status=open -> false (proceed as normal)"
fi

MOCK_SHOW_OUT='{"id":"wa-a7tca","status":"in_progress"}'; MOCK_SHOW_RC=0
if story_bead_closed_now store wa-a7tca; then
  bad "(d) status=in_progress -> expected false, got true"
else
  ok "(d) status=in_progress -> false"
fi

# ga-rugqks / *error=empty=F doctrine: a bd hiccup must never look identical
# to "already closed" — that would silently swallow a genuine delivery
# halt/failure instead of reporting it. Fail OPEN (not-closed) in all three.
MOCK_SHOW_OUT=""; MOCK_SHOW_RC=1
if story_bead_closed_now store wa-a7tca; then
  bad "(e) bd show FAILS (rc=1, empty output) -> expected false (fail open), got true"
else
  ok "(e) bd show FAILS (rc=1, empty output) -> false (fails open, never silently 'closed')"
fi

MOCK_SHOW_OUT=""; MOCK_SHOW_RC=0
if story_bead_closed_now store wa-a7tca; then
  bad "(f) bd show returns EMPTY (rc=0) -> expected false (fail open), got true"
else
  ok "(f) bd show returns EMPTY (rc=0) -> false (fails open)"
fi

MOCK_SHOW_OUT='not valid json {{{'; MOCK_SHOW_RC=0
if story_bead_closed_now store wa-a7tca; then
  bad "(g) bd show returns unparseable garbage -> expected false (fail open), got true"
else
  ok "(g) bd show returns unparseable garbage -> false (fails open)"
fi

MOCK_SHOW_OUT='{"id":"wa-a7tca"}'; MOCK_SHOW_RC=0
if story_bead_closed_now store wa-a7tca; then
  bad "(h) status field entirely absent -> expected false (fail open), got true"
else
  ok "(h) status field entirely absent -> false (fails open)"
fi

# ── 2. DRIFT GUARD: guard (a) — top-of-iteration, before any mutation ──────
echo "── 2. drift guard: top-of-iteration guard wired correctly ──"
grep -q 'story_bead_closed_now "\$STORY_STORE" "\$STORY_ID"' "$SCRIPT" \
  && ok "main loop calls story_bead_closed_now with STORY_STORE/STORY_ID" \
  || bad "main loop does not call story_bead_closed_now with STORY_STORE/STORY_ID"

GUARD_A_LN=$(grep -n 'if story_bead_closed_now "\$STORY_STORE" "\$STORY_ID"; then' "$SCRIPT" | head -1 | cut -d: -f1)
STORY_DONE_SKIP_LN=$(grep -n '# Skip if already marked story:done' "$SCRIPT" | head -1 | cut -d: -f1)
CLAIM_LN=$(grep -n '# Mark as running (claim)' "$SCRIPT" | head -1 | cut -d: -f1)
STEP2_LN=$(grep -n '── Step 2: Determine rig' "$SCRIPT" | head -1 | cut -d: -f1)
FIRST_DELIVERY_FAILED_LN=$(grep -n 'label add    "\$STORY_ID" "delivery:failed"' "$SCRIPT" | head -1 | cut -d: -f1)

if [ -n "$GUARD_A_LN" ] && [ -n "$STORY_DONE_SKIP_LN" ] && [ "$GUARD_A_LN" -lt "$STORY_DONE_SKIP_LN" ]; then
  ok "guard (a) (line $GUARD_A_LN) precedes the story:done idempotency skip (line $STORY_DONE_SKIP_LN)"
else
  bad "expected guard (a) before story:done skip (guard=$GUARD_A_LN skip=$STORY_DONE_SKIP_LN)"
fi
if [ -n "$GUARD_A_LN" ] && [ -n "$CLAIM_LN" ] && [ "$GUARD_A_LN" -lt "$CLAIM_LN" ]; then
  ok "guard (a) (line $GUARD_A_LN) precedes the delivery:running claim (line $CLAIM_LN)"
else
  bad "expected guard (a) before delivery:running claim (guard=$GUARD_A_LN claim=$CLAIM_LN)"
fi
if [ -n "$GUARD_A_LN" ] && [ -n "$STEP2_LN" ] && [ "$GUARD_A_LN" -lt "$STEP2_LN" ]; then
  ok "guard (a) (line $GUARD_A_LN) precedes Step 2/rig determination (line $STEP2_LN)"
else
  bad "expected guard (a) before Step 2 (guard=$GUARD_A_LN step2=$STEP2_LN)"
fi
if [ -n "$GUARD_A_LN" ] && [ -n "$FIRST_DELIVERY_FAILED_LN" ] && [ "$GUARD_A_LN" -lt "$FIRST_DELIVERY_FAILED_LN" ]; then
  ok "guard (a) (line $GUARD_A_LN) precedes the first delivery:failed label-add (line $FIRST_DELIVERY_FAILED_LN)"
else
  bad "expected guard (a) before any delivery:failed label-add (guard=$GUARD_A_LN first=$FIRST_DELIVERY_FAILED_LN)"
fi

# guard (a)'s own continue must fire in the same if-block, right after it —
# i.e. no mutation between the check and the skip.
GUARD_A_BLOCK_END=$((GUARD_A_LN + 6))
GUARD_A_CONTINUE=$(sed -n "${GUARD_A_LN},${GUARD_A_BLOCK_END}p" "$SCRIPT" | grep -c '^  continue$')
if [ "$GUARD_A_CONTINUE" -ge 1 ]; then
  ok "guard (a) skips via 'continue' within its own if-block (no mutation in between)"
else
  bad "guard (a) does not 'continue' immediately — could fall through into a mutation"
fi

# ── 3. DRIFT GUARD: guard (b) — right after the daemon-refresh subprocess ──
echo "── 3. drift guard: post-daemon-refresh guard wired correctly ──"
REFRESH_CALL_LN=$(grep -n 'bash "\$REFRESH_HELPER" || true)' "$SCRIPT" | head -1 | cut -d: -f1)
GUARD_B_LN=$(grep -n 'if story_bead_closed_now "\$STORY_STORE" "\$STORY_ID"; then' "$SCRIPT" | tail -1 | cut -d: -f1)
VERDICT_CASE_LN=$(grep -n 'case "\$REFRESH_VERDICT" in' "$SCRIPT" | head -1 | cut -d: -f1)
STEP5B_DELIVERY_FAILED_LN=$(grep -n 'label add    "\$STORY_ID" "delivery:failed"  -q 2>/dev/null || true' "$SCRIPT" | awk -F: -v lo="$VERDICT_CASE_LN" '$1 > lo {print $1; exit}')

if [ -n "$REFRESH_CALL_LN" ] && [ -n "$GUARD_B_LN" ] && [ "$GUARD_B_LN" -gt "$REFRESH_CALL_LN" ]; then
  ok "guard (b) (line $GUARD_B_LN) sits right after the REFRESH_HELPER subprocess call (line $REFRESH_CALL_LN)"
else
  bad "expected guard (b) after the REFRESH_HELPER call (call=$REFRESH_CALL_LN guard=$GUARD_B_LN)"
fi
if [ -n "$GUARD_B_LN" ] && [ -n "$VERDICT_CASE_LN" ] && [ "$GUARD_B_LN" -lt "$VERDICT_CASE_LN" ]; then
  ok "guard (b) (line $GUARD_B_LN) precedes the REFRESH_VERDICT case statement (line $VERDICT_CASE_LN)"
else
  bad "expected guard (b) before the verdict case (guard=$GUARD_B_LN case=$VERDICT_CASE_LN)"
fi
if [ -n "$GUARD_B_LN" ] && [ -n "$STEP5B_DELIVERY_FAILED_LN" ] && [ "$GUARD_B_LN" -lt "$STEP5B_DELIVERY_FAILED_LN" ]; then
  ok "guard (b) (line $GUARD_B_LN) precedes Step 5b's own delivery:failed label-add (line $STEP5B_DELIVERY_FAILED_LN)"
else
  bad "expected guard (b) before Step 5b's delivery:failed add (guard=$GUARD_B_LN add=$STEP5B_DELIVERY_FAILED_LN)"
fi
if [ -n "$GUARD_A_LN" ] && [ -n "$GUARD_B_LN" ] && [ "$GUARD_B_LN" -gt "$GUARD_A_LN" ]; then
  ok "two distinct guard call sites confirmed (a=$GUARD_A_LN, b=$GUARD_B_LN)"
else
  bad "expected two distinct, ordered guard call sites (a=$GUARD_A_LN b=$GUARD_B_LN)"
fi

GUARD_B_BLOCK_END=$((GUARD_B_LN + 6))
GUARD_B_CONTINUE=$(sed -n "${GUARD_B_LN},${GUARD_B_BLOCK_END}p" "$SCRIPT" | grep -c '^    continue$')
if [ "$GUARD_B_CONTINUE" -ge 1 ]; then
  ok "guard (b) skips via 'continue' within its own if-block (no verdict handling/mutation in between)"
else
  bad "guard (b) does not 'continue' immediately — could fall through into verdict handling/mutation"
fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
