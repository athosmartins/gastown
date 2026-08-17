#!/usr/bin/env bash
# story-delivery-sibling-marker-hold.selftest.sh — Prove the ga-0m6tgc fix in
# isolation, with NO live Dolt/gc/launchd:
#
#   BUG (ga-0m6tgc): quality-gate-dispatcher.sh adds gate:passed to a source
#   bead unconditionally, per-marker, with no check for a sibling gate marker
#   still open on the SAME bead (source-bead: label). story-delivery.sh's
#   Step 1 selects any story:approved + gate:passed bead not yet story:done —
#   for a cross-rig or resubmitted story with TWO markers, the FIRST to reach
#   PASS+merge makes the story selectable while a SECOND marker, submitted
#   separately, is still open/under review elsewhere. Nothing stopped Step 1
#   from deploying and marking story:done right then — silently shipping
#   only part of the story's acceptance criteria while the rest sat unmerged
#   with nothing left watching it (a closed story no longer matches Step 1's
#   own selector, so no future sweep ever re-checks the abandoned marker).
#   Live case: ga-dxyvxr closed story:done with one marker (ga-exo8qs)
#   passed+merged while its sibling (ga-z9npl3) sat gate-status:failed and
#   closed — out of any selector's reach. Verified via `git diff` that the
#   failed sibling's branch was byte-identical to the merged one on every
#   feature file (a duplicate submission, not missing scope), so no content
#   correction was needed for that specific bead — documented on ga-dxyvxr's
#   own thread. The CLASS of bug is real regardless: a genuine second
#   deliverable would have been silently dropped exactly the same way.
#
#   FIX: story-delivery.sh's main per-story loop now calls
#   gate_bead_sibling_status_lines (quality-gate-guard.sh — ga-0m6tgc moved
#   it there from quality-gate-dispatcher.sh specifically so this file could
#   reach it via its own existing GATE_GUARD_LIB_ONLY source) right after the
#   story:done/delivery:running idempotency skips and before claiming
#   delivery:running. A non-empty result (>=1 still-OPEN marker/gate-run
#   citing this story via source-bead:) holds delivery — labels
#   delivery:blocked-sibling, comments the evidence, and `continue`s to the
#   next story, retried every sweep — instead of proceeding to Step 2+
#   (rig/deploy/story:done). This branch's OWN marker is always already
#   closed by the time gate:passed lands on the bead (the PASS path in
#   quality-gate-dispatcher.sh closes the marker before setting the label,
#   same invocation), so the ordinary single-marker story — the overwhelming
#   majority — sees an empty result and nothing about its behavior changes.
#
# This harness sources story-delivery.sh in lib-only mode to unit-test the
# REAL bd-backed resolver (gate_bead_sibling_status_lines, transitively
# pulled in via story-delivery.sh's own guard.sh source — proving THIS
# file's sourcing chain works, not just quality-gate-dispatcher.sh's, which
# gate-sibling-branch-guard.selftest.sh already covers), replays the exact
# two-marker shape from the bug report against an in-shell bd mock, then
# DRIFT-GUARDS the live script so a future refactor can't drop or reorder
# the fix silently. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORY_DELIVERY="$SELF_DIR/story-delivery.sh"
GUARD="$SELF_DIR/quality-gate-guard.sh"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

# ── Load the REAL helpers from story-delivery.sh (lib-only = no live sweep) ──
STORY_DELIVERY_LIB_ONLY=1 source "$STORY_DELIVERY" \
  || { echo "FATAL: could not source story-delivery.sh in lib-only mode"; exit 1; }

# ga-0m6tgc: this is the actual regression this whole file exists to catch —
# gate_bead_sibling_status_lines must be reachable from story-delivery.sh's
# OWN lib-only source (via its existing GATE_GUARD_LIB_ONLY include of
# quality-gate-guard.sh), not just from quality-gate-dispatcher.sh's.
type gate_bead_sibling_status_lines >/dev/null 2>&1 \
  || { echo "FATAL: gate_bead_sibling_status_lines not reachable from story-delivery.sh (lib-only) — this fires on pre-fix code, proving the test is load-bearing"; exit 1; }

# Quiet logging from the sourced helpers during the test.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. gate_bead_sibling_status_lines, reached via story-delivery.sh's own
#      sourcing chain — replay the exact ga-dxyvxr two-marker shape ─────────
echo "── 1. gate_bead_sibling_status_lines via story-delivery.sh's sourcing (mock bd) ──"
MOCK_LIST_JSON='[]'
bd() {
  case " $* " in
    *" list "*) printf '%s\n' "$MOCK_LIST_JSON" ;;
    *) : ;;
  esac
  return 0
}

MOCK_LIST_JSON='[]'
eq "(a) no markers at all → '' (proceed — nothing to hold on)" \
  "$(gate_bead_sibling_status_lines city 'ga-dxyvxr')" ""

# Real-shape single-marker story: ITS OWN marker is already closed by the
# time gate:passed landed (the PASS path closes it first, same invocation) —
# the overwhelming common case must see nothing here.
MOCK_LIST_JSON='[{"id":"m1","status":"closed","labels":["type:quality-gate-marker","gate-status:passed","source-bead:ga-dxyvxr","branch:feat/ga-dxyvxr-hq"],"description":""}]'
eq "(b) ordinary single-marker story, own marker already closed → '' (zero behavior change for the common case)" \
  "$(gate_bead_sibling_status_lines city 'ga-dxyvxr')" ""

# The live ga-dxyvxr shape: ONE marker closed+passed (the one that made the
# bead selectable), a SECOND marker for the SAME story still OPEN elsewhere.
MOCK_LIST_JSON='[{"id":"m1","status":"closed","labels":["type:quality-gate-marker","gate-status:passed","source-bead:ga-dxyvxr","branch:feat/ga-dxyvxr-hq"],"description":""},{"id":"m2","status":"open","labels":["type:quality-gate-marker","gate-status:queued","source-bead:ga-dxyvxr","branch:feat/ga-dxyvxr"],"description":""}]'
eq "(c) THE BUG SHAPE: sibling marker still OPEN → non-empty (must hold, not deploy)" \
  "$(gate_bead_sibling_status_lines city 'ga-dxyvxr')" \
  "$(printf 'feat/ga-dxyvxr\tqueued\t')"

# Same two markers, but the second one has now ALSO reached a terminal state
# (closed, whether passed or failed) — acceptance criteria's "once the
# second marker also resolves, proceeds normally".
MOCK_LIST_JSON='[{"id":"m1","status":"closed","labels":["type:quality-gate-marker","gate-status:passed","source-bead:ga-dxyvxr","branch:feat/ga-dxyvxr-hq"],"description":""},{"id":"m2","status":"closed","labels":["type:quality-gate-marker","gate-status:failed","source-bead:ga-dxyvxr","branch:feat/ga-dxyvxr"],"description":""}]'
eq "(d) both markers now terminal (2nd closed too) → '' (proceeds normally, per AC)" \
  "$(gate_bead_sibling_status_lines city 'ga-dxyvxr')" ""

# ── 2. DRIFT GUARD: the hold-check is wired into the main loop, in the right
#      place (after idempotency skips, before the delivery:running claim,
#      before Step 2/rig determination and Step 8/story:done) ──────────────
echo "── 2. drift guard: sibling hold-check wired correctly into story-delivery.sh ──"
has "$STORY_DELIVERY" 'gate_bead_sibling_status_lines "\$GC_CITY" "\$STORY_ID"' \
  "main loop calls gate_bead_sibling_status_lines with GC_CITY/STORY_ID"
has "$STORY_DELIVERY" 'label add "\$STORY_ID" "delivery:blocked-sibling"' \
  "hold path labels the story delivery:blocked-sibling"
has "$STORY_DELIVERY" 'label remove "\$STORY_ID" "delivery:blocked-sibling"' \
  "proceed path clears a stale delivery:blocked-sibling from a prior sweep"

DELIVERY_RUNNING_SKIP_LN=$(grep -n 'already has delivery:running' "$STORY_DELIVERY" | head -1 | cut -d: -f1)
SIBLING_CHECK_LN=$(grep -n 'gate_bead_sibling_status_lines "\$GC_CITY" "\$STORY_ID"' "$STORY_DELIVERY" | head -1 | cut -d: -f1)
CLAIM_LN=$(grep -n '# Mark as running (claim)' "$STORY_DELIVERY" | head -1 | cut -d: -f1)
STEP2_LN=$(grep -n '── Step 2: Determine rig' "$STORY_DELIVERY" | head -1 | cut -d: -f1)
STEP8_LN=$(grep -n '── Step 8: Mark story:done' "$STORY_DELIVERY" | head -1 | cut -d: -f1)
HOLD_BLOCK_END=$((SIBLING_CHECK_LN + 40))
CONTINUE_LN=$(sed -n "${SIBLING_CHECK_LN},${HOLD_BLOCK_END}p" "$STORY_DELIVERY" | grep -n '^  continue$' | head -1 | cut -d: -f1)
[ -n "$CONTINUE_LN" ] && CONTINUE_LN=$((SIBLING_CHECK_LN + CONTINUE_LN - 1))

if [ -n "$DELIVERY_RUNNING_SKIP_LN" ] && [ -n "$SIBLING_CHECK_LN" ] && [ "$DELIVERY_RUNNING_SKIP_LN" -lt "$SIBLING_CHECK_LN" ]; then
  ok "sibling check (line $SIBLING_CHECK_LN) sits after the delivery:running idempotency skip (line $DELIVERY_RUNNING_SKIP_LN)"
else
  bad "expected delivery:running skip before sibling check (skip=$DELIVERY_RUNNING_SKIP_LN sibling=$SIBLING_CHECK_LN)"
fi
if [ -n "$SIBLING_CHECK_LN" ] && [ -n "$CLAIM_LN" ] && [ "$SIBLING_CHECK_LN" -lt "$CLAIM_LN" ]; then
  ok "sibling check (line $SIBLING_CHECK_LN) precedes the delivery:running claim (line $CLAIM_LN)"
else
  bad "expected sibling check before delivery:running claim (sibling=$SIBLING_CHECK_LN claim=$CLAIM_LN)"
fi
if [ -n "$SIBLING_CHECK_LN" ] && [ -n "$STEP2_LN" ] && [ "$SIBLING_CHECK_LN" -lt "$STEP2_LN" ]; then
  ok "sibling check (line $SIBLING_CHECK_LN) precedes Step 2/rig determination (line $STEP2_LN)"
else
  bad "expected sibling check before Step 2 (sibling=$SIBLING_CHECK_LN step2=$STEP2_LN)"
fi
if [ -n "$CONTINUE_LN" ] && [ -n "$STEP8_LN" ] && [ "$CONTINUE_LN" -lt "$STEP8_LN" ]; then
  ok "the hold path's continue (line $CONTINUE_LN) sits before Step 8/story:done (line $STEP8_LN) — a held story can never reach story:done in the same iteration"
else
  bad "expected hold's continue shortly after the sibling check, before Step 8 (continue=$CONTINUE_LN step8=$STEP8_LN)"
fi

# ── 3. syntax ─────────────────────────────────────────────────────────────
echo "── 3. syntax ──"
if bash -n "$STORY_DELIVERY"; then ok "story-delivery.sh passes bash -n"; else bad "story-delivery.sh bash -n FAILED"; fi
if bash -n "$GUARD"; then ok "quality-gate-guard.sh passes bash -n"; else bad "quality-gate-guard.sh bash -n FAILED"; fi
if bash -n "$DISPATCHER"; then ok "quality-gate-dispatcher.sh passes bash -n"; else bad "quality-gate-dispatcher.sh bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
