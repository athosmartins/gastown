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

# ── 1b. GATE-FEEDBACK regression (attempt 2, gate-run ga-ihxdja): a bd/Dolt
#       query FAILURE must NOT read the same as "confirmed zero siblings" ──
# The reviewer reproduced this by hand with a failing bd() mock: pre-fix,
# `siblings_json=$(bd ... || echo "[]")` swallowed the failure and this
# function returned "" — byte-identical to test (a) above (genuinely zero
# markers) — so story-delivery.sh's `if [ -n "$OPEN_SIBLINGS" ]` took the
# PROCEED branch on a transient hiccup exactly as readily as on a real
# all-clear. This section is RED on the attempt-1 code, GREEN after the fix.
echo "── 1b. bd query FAILURE must NOT collapse to '' (gate-run ga-ihxdja fix) ──"
bd() {
  case " $* " in
    *" list "*) echo "bd: connection refused (mock failure)" >&2; return 1 ;;
    *) return 0 ;;
  esac
}
FAIL_RESULT=$(gate_bead_sibling_status_lines city 'ga-dxyvxr' 2>/dev/null)
FAIL_STDERR=$(gate_bead_sibling_status_lines city 'ga-dxyvxr' 2>&1 1>/dev/null)

if [ -n "$FAIL_RESULT" ]; then
  ok "(e) bd query FAILS → non-empty result: [$FAIL_RESULT] (must hold, not read as 'no siblings')"
else
  bad "(e) bd query FAILS → got EMPTY result — indistinguishable from confirmed-zero-siblings, the exact regression this section exists to catch"
fi

FAIL_STATUS=$(printf '%s' "$FAIL_RESULT" | head -1 | cut -f2)
if [ "$FAIL_STATUS" = "failed" ]; then
  bad "(e2) bd-failure sentinel's status is the literal string 'failed' ([$FAIL_STATUS]) — would be misread as a genuine terminal-failed sibling by gate_pick_terminal_failed_sibling's exact-match check"
else
  ok "(e2) bd-failure sentinel's status ([$FAIL_STATUS]) is not the literal 'failed' — inert to gate_pick_terminal_failed_sibling's exact-match"
fi

case "$FAIL_STDERR" in
  *ALERT*) ok "(e3) bd query failure is surfaced on stderr (visible/counted, not silent)" ;;
  *) bad "(e3) expected an ALERT on stderr for a bd query failure, got: [$FAIL_STDERR]" ;;
esac

# Restore the success-shaped mock so nothing appended below this point is
# affected by the failure mock.
bd() {
  case " $* " in
    *" list "*) printf '%s\n' "$MOCK_LIST_JSON" ;;
    *) : ;;
  esac
  return 0
}

# ga-0m6tgc gate-fix (attempt 2): the story-delivery.sh call site must not
# suppress this function's own stderr — a local `2>/dev/null` there would
# silently discard the ALERT just proven above. Static drift guard (the
# runtime alert-delivery is proven end-to-end by the 1c end-to-end replay
# below, which sources this exact line).
echo "── 1b2. drift guard: story-delivery.sh call site does not suppress stderr ──"
CALL_SITE_LINE=$(grep -n 'OPEN_SIBLINGS=\$(gate_bead_sibling_status_lines' "$STORY_DELIVERY" | head -1 | cut -d: -f2-)
case "$CALL_SITE_LINE" in
  *"2>/dev/null"*) bad "story-delivery.sh's call site still redirects stderr to /dev/null — this discards the bd-query-failure ALERT: $CALL_SITE_LINE" ;;
  *) ok "story-delivery.sh's call site does not suppress stderr — the bd-query-failure ALERT reaches the script's own log" ;;
esac

# ── 1c. END-TO-END: replay story-delivery.sh's OWN call-site expression
#       (not a re-implementation of it) under the failing mock ────────────
echo "── 1c. end-to-end: story-delivery.sh's real OPEN_SIBLINGS expression, bd failing ──"
bd() {
  case " $* " in
    *" list "*) echo "bd: connection refused (mock failure)" >&2; return 1 ;;
    *) return 0 ;;
  esac
}
GC_CITY="city"
STORY_ID="ga-dxyvxr"
# Extract and eval the actual assignment line from the live script, so a
# future edit to it (e.g. reintroducing 2>/dev/null, or changing the `||`
# fallback) is caught here even if nobody thinks to update this test.
REAL_ASSIGNMENT=$(grep -E '^OPEN_SIBLINGS=\$\(gate_bead_sibling_status_lines' "$STORY_DELIVERY" | head -1)
if [ -z "$REAL_ASSIGNMENT" ]; then
  bad "could not find the OPEN_SIBLINGS assignment line in story-delivery.sh to replay"
else
  eval "$REAL_ASSIGNMENT"
  if [ -n "$OPEN_SIBLINGS" ]; then
    ok "(f) story-delivery.sh's actual OPEN_SIBLINGS expression is non-empty under a failing bd query — takes the HOLD branch, not PROCEED"
  else
    bad "(f) story-delivery.sh's actual OPEN_SIBLINGS expression is EMPTY under a failing bd query — takes the PROCEED branch, the exact silent/irreversible regression this bead exists to close"
  fi
fi
unset GC_CITY STORY_ID OPEN_SIBLINGS

# Restore the success-shaped mock again before the (unrelated) drift-guard
# and syntax sections below.
bd() {
  case " $* " in
    *" list "*) printf '%s\n' "$MOCK_LIST_JSON" ;;
    *) : ;;
  esac
  return 0
}

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
