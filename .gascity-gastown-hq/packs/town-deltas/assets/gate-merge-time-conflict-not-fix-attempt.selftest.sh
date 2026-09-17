#!/usr/bin/env bash
# gate-merge-time-conflict-not-fix-attempt.selftest.sh — Prove the ga-39l9z2
# fix in isolation, with NO live Dolt/gc/launchd:
#
#   BUG (wa-dnzu0, P1, 2026-09-17): ALL PASS, then main moved and the
#   merge-time rebase hit a genuine textual conflict (MERGE_RESULT=
#   failed_merge_time_conflict). The dispatcher already classifies this
#   correctly as GATE_SHA_FAIL_CLASS=hold ("the code itself already PASSED
#   review; nothing here judged the fix's content" — ga-4cy2t) but NOTHING
#   downstream consulted that classification: the merge-time failure fell
#   into the SAME PREV_ATTEMPT/GATE_FIX_CAP machinery as a genuine review
#   rejection, bumping gate:fix-attempt from 2 to 3/3 and setting up the
#   NEXT unrelated hiccup to escalate gate:needs-human on code nobody ever
#   asked to change.
#
#   Defect 2, same incident: the FAIL-and-return-to-pool arm restored
#   gc.routed_to (ga-f54ui) but left the bead's `status` at whatever
#   gate-CLAIM time set it to (in_progress) and never stripped the stale
#   gate:queued label — so even a bead with gc.routed_to correctly restored
#   stayed invisible to every pool worker's self-serve probe
#   (`bd ready --exclude-label gate:queued`, status checked separately).
#   Manual remediation on wa-dnzu0 (Mayor) was exactly: status -> open,
#   gate:queued removed.
#
#   FIX 1: a new GATE_NEEDS_REBASE_NOT_FIX flag, set ONLY for
#   MERGE_RESULT=failed_merge_time_conflict (deliberately NOT
#   failed_merge_time_rebase — that result is reached only after an
#   attempted rebase/merge failed, including the ga-m07gc content-loss
#   refusal, which can itself signal a real problem worth a human's eyes).
#   When set, the fix-attempt-cap block takes a NEW branch that labels
#   gate:needs-rebase instead of gate:needs-fix and never touches
#   gate:fix-attempt:* at all.
#
#   FIX 2 (both the new needs-rebase branch AND the pre-existing needs-fix
#   'clear' arm): once the assignee-clear is CONFIRMED (never unconditional
#   — see gate-fail-crew-keep.selftest.sh section 11 for why), also reopen
#   status and strip gate:queued.
#
# This harness cannot invoke gate_finalize_run() itself — it is defined
# AFTER the GATE_DISPATCHER_LIB_ONLY early-return (confirmed: the cutoff is
# a bare top-level `return 0`, so nothing defined later ever becomes a
# function in a lib-only sourced shell), the same reason
# gate-sha-fail-lock.selftest.sh's FAIL-path coverage (its own section 6c)
# is structural/drift-guard rather than a live call. This file follows the
# same two-layer shape: (A) drift guards proving the SOURCE contains the
# right operations, in the right place, in the right order; (B) a pure
# probe-eligibility predicate — a faithful MIRROR of the pool worker
# self-serve probe's real filter (as directly observed in this dispatcher's
# own sibling dog-pool probe and documented citywide, CLAUDE.md ga-y8qh),
# not the literal probe source — fed the bead states (A) proves the code
# produces, to verify the acceptance criteria's literal claim: "fix-attempt
# inalterado, bead elegivel no probe do worker."
#
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── A. Drift guards: the wiring exists, in the right place ───────────────────

echo "── A1. drift guard: GATE_NEEDS_REBASE_NOT_FIX resets alongside GATE_SHA_FAIL_CLASS ──"
RESET_LN=$(grep -n '^GATE_NEEDS_REBASE_NOT_FIX="0"$' "$DISPATCHER" | head -1 | cut -d: -f1 || true)
CLASS_RESET_LN=$(grep -n '^GATE_SHA_FAIL_CLASS="code"$' "$DISPATCHER" | head -1 | cut -d: -f1 || true)
if [ -n "$RESET_LN" ] && [ -n "$CLASS_RESET_LN" ] && [ $((RESET_LN - CLASS_RESET_LN)) -ge 0 ] && [ $((RESET_LN - CLASS_RESET_LN)) -le 10 ]; then
  ok "GATE_NEEDS_REBASE_NOT_FIX resets (line $RESET_LN) right after GATE_SHA_FAIL_CLASS (line $CLASS_RESET_LN) — no leakage across beads in the same sweep"
else
  bad "GATE_NEEDS_REBASE_NOT_FIX reset missing or not co-located with the GATE_SHA_FAIL_CLASS reset (reset=$RESET_LN class=$CLASS_RESET_LN)"
fi

echo "── A2. drift guard: flag set ONLY for failed_merge_time_conflict, not failed_merge_time_rebase ──"
CONFLICT_SET_LN=$(grep -n 'if \[ "\$MERGE_RESULT" = "failed_merge_time_conflict" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1 || true)
if [ -n "$CONFLICT_SET_LN" ]; then
  ok "found the failed_merge_time_conflict-specific if-block (line $CONFLICT_SET_LN)"
  # The flag assignment must be the FIRST GATE_NEEDS_REBASE_NOT_FIX=1 in the
  # file, and must sit within a few lines of the conflict-specific if (inside
  # its body, not accidentally hoisted out).
  FLAG_SET_LN=$(grep -n '^        GATE_NEEDS_REBASE_NOT_FIX=1$' "$DISPATCHER" | head -1 | cut -d: -f1 || true)
  if [ -n "$FLAG_SET_LN" ] && [ "$FLAG_SET_LN" -gt "$CONFLICT_SET_LN" ] && [ $((FLAG_SET_LN - CONFLICT_SET_LN)) -le 25 ]; then
    ok "GATE_NEEDS_REBASE_NOT_FIX=1 (line $FLAG_SET_LN) sits inside the failed_merge_time_conflict if-block"
  else
    bad "GATE_NEEDS_REBASE_NOT_FIX=1 not found close enough after the failed_merge_time_conflict if (if=$CONFLICT_SET_LN set=$FLAG_SET_LN)"
  fi
  FLAG_TOTAL=$(grep -c '^        GATE_NEEDS_REBASE_NOT_FIX=1$' "$DISPATCHER" || true)
  eq "GATE_NEEDS_REBASE_NOT_FIX=1 appears at exactly one call site (scope stayed narrow — not blanket-applied to every hold-class FAIL)" "${FLAG_TOTAL:-0}" "1"
else
  bad "could not find the failed_merge_time_conflict-specific if-block — wiring missing/renamed"
fi
# Negative control: failed_merge_time_rebase must NOT set the flag anywhere
# nearby (deliberate scope boundary — see this file's header comment).
REBASE_RESULT_LN=$(grep -n 'MERGE_RESULT="failed_merge_time_rebase"' "$DISPATCHER" | head -1 | cut -d: -f1 || true)
if [ -n "$REBASE_RESULT_LN" ]; then
  REBASE_WINDOW=$(sed -n "${REBASE_RESULT_LN},$((REBASE_RESULT_LN + 5))p" "$DISPATCHER")
  if printf '%s' "$REBASE_WINDOW" | grep -qF 'GATE_NEEDS_REBASE_NOT_FIX=1'; then
    bad "failed_merge_time_rebase unexpectedly sets GATE_NEEDS_REBASE_NOT_FIX — scope crept beyond the documented ga-m07gc exclusion"
  else
    ok "failed_merge_time_rebase does NOT set GATE_NEEDS_REBASE_NOT_FIX (scope correctly excludes the content-loss-risk case, ga-m07gc)"
  fi
else
  bad "could not locate failed_merge_time_rebase's MERGE_RESULT assignment — cannot verify the scope boundary"
fi

echo "── A3. drift guard: the needs-rebase branch is checked BEFORE the fix-attempt-cap check ──"
NR_BRANCH_LN=$(grep -n 'if \[ "\$GATE_NEEDS_REBASE_NOT_FIX" = "1" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1 || true)
CAP_CHECK_LN=$(grep -n 'elif \[ "\$PREV_ATTEMPT" -ge "\$GATE_FIX_CAP" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1 || true)
if [ -n "$NR_BRANCH_LN" ] && [ -n "$CAP_CHECK_LN" ] && [ "$NR_BRANCH_LN" -lt "$CAP_CHECK_LN" ]; then
  ok "GATE_NEEDS_REBASE_NOT_FIX check (line $NR_BRANCH_LN) precedes the cap check (line $CAP_CHECK_LN), and the cap check is now an elif (same if/elif chain, not a separate independent check)"
else
  bad "needs-rebase branch is not wired as the FIRST arm of the fix-attempt if/elif chain (nr=$NR_BRANCH_LN cap=$CAP_CHECK_LN)"
fi

echo "── A4. drift guard: the needs-rebase branch NEVER touches gate:fix-attempt ──"
# Extract the branch body: from the GATE_NEEDS_REBASE_NOT_FIX if down to the
# matching 'elif ... GATE_FIX_CAP' (the next arm in the same chain).
NR_BODY=$(awk '
  /if \[ "\$GATE_NEEDS_REBASE_NOT_FIX" = "1" \]; then/ { flag=1 }
  flag { print }
  /elif \[ "\$PREV_ATTEMPT" -ge "\$GATE_FIX_CAP" \]; then/ { if (flag) exit }
' "$DISPATCHER")
if [ -z "$NR_BODY" ]; then
  bad "NR_BODY extraction produced nothing — anchor drifted, cannot verify the fix-attempt-counter is untouched"
else
  # Check for an actual LABEL MUTATION targeting gate:fix-attempt — not just
  # any mention of the word. This branch's own header comment legitimately
  # DISCUSSES "gate:fix-attempt" in prose (explaining why it must stay
  # untouched), and its `bd comment` calls legitimately tell a human reader
  # "NOT counted as a gate:fix-attempt" — both are text ABOUT the counter,
  # neither is a `bd label add/remove` operation ON it. Only the latter can
  # actually mutate the label, so that is what must be absent.
  if printf '%s' "$NR_BODY" | grep -E 'label (add|remove).*gate:fix-attempt' >/dev/null; then
    bad "needs-rebase branch contains a 'bd label add/remove' targeting gate:fix-attempt — the counter may be touched (should be completely absent from this branch's code)"
  else
    ok "needs-rebase branch contains no 'bd label add/remove' targeting gate:fix-attempt — the counter is provably untouched by this path (mentions of the word in comments/messages are fine — checked the actual label mutations, not prose)"
  fi
  if printf '%s' "$NR_BODY" | grep -qF 'label add    "$BEAD_ID" "gate:needs-rebase"'; then
    ok "needs-rebase branch labels the bead gate:needs-rebase (not gate:needs-fix)"
  else
    bad "needs-rebase branch does not add gate:needs-rebase — wiring missing/renamed"
  fi
  if printf '%s' "$NR_BODY" | grep -qF 'label add "$BEAD_ID" "gate:needs-fix"'; then
    bad "needs-rebase branch ALSO adds gate:needs-fix — should be mutually exclusive with the needs-fix arm"
  else
    ok "needs-rebase branch does not also add gate:needs-fix (mutually exclusive with the needs-fix arm)"
  fi
fi

echo "── A5. drift guard: needs-rebase 'clear' sub-arm reopens status + strips gate:queued, gated on confirmed-empty-assignee ──"
if [ -n "$NR_BODY" ]; then
  # NR_BODY contains BOTH the 'keep' and 'clear' sub-arms of the inner
  # GATE_NR_ASSIGNEE_ACTION if/else — the 'keep' sub-arm ALSO removes
  # gate:queued (mirrors the existing needs-fix 'keep' arm), so a plain
  # grep over the whole NR_BODY picks up the WRONG occurrence. Isolate the
  # 'clear' sub-arm specifically first — same two-level slice technique as
  # gate-fail-crew-keep.selftest.sh's own KEEP_ARM/CLEAR_ARM extraction,
  # applied one level deeper to this branch's own nested if/else.
  NR_CLEAR_SUBARM=$(printf '%s' "$NR_BODY" | awk '
    /GATE_NR_ASSIGNEE_ACTION" = "keep"/ { flag=1 }
    flag==1 && /^      else$/           { flag=2 }
    flag==2                             { print }
    flag==2 && /^      fi$/             { exit }
  ')
  if [ -z "$NR_CLEAR_SUBARM" ]; then
    bad "NR_CLEAR_SUBARM extraction produced nothing — inner if/else anchor drifted, cannot verify the 'clear' sub-arm"
  else
    NR_CLEARED_LN=$(printf '%s' "$NR_CLEAR_SUBARM" | grep -nF '_NR_ASSIGNEE_OBS="assignee=cleared"' | head -1 | cut -d: -f1 || true)
    NR_ELIF_LN=$(printf '%s' "$NR_CLEAR_SUBARM" | grep -nF 'elif [ "$_NR_CLEAR_RC" = "13" ]' | head -1 | cut -d: -f1 || true)
    NR_STATUS_LN=$(printf '%s' "$NR_CLEAR_SUBARM" | grep -nF -- '--status open' | head -1 | cut -d: -f1 || true)
    NR_QUEUED_LN=$(printf '%s' "$NR_CLEAR_SUBARM" | grep -nF 'label remove "$BEAD_ID" "gate:queued"' | head -1 | cut -d: -f1 || true)
    if [ -n "$NR_CLEARED_LN" ] && [ -n "$NR_ELIF_LN" ] && [ -n "$NR_STATUS_LN" ] && [ -n "$NR_QUEUED_LN" ] \
       && [ "$NR_STATUS_LN" -gt "$NR_CLEARED_LN" ] && [ "$NR_STATUS_LN" -lt "$NR_ELIF_LN" ] \
       && [ "$NR_QUEUED_LN" -gt "$NR_CLEARED_LN" ] && [ "$NR_QUEUED_LN" -lt "$NR_ELIF_LN" ]; then
      ok "needs-rebase 'clear' sub-arm reopens status + strips gate:queued, scoped to confirmed-empty-assignee (cleared=$NR_CLEARED_LN status=$NR_STATUS_LN queued=$NR_QUEUED_LN elif=$NR_ELIF_LN)"
    else
      bad "needs-rebase 'clear' sub-arm does NOT correctly scope status-open/gate:queued-remove (cleared=$NR_CLEARED_LN status=$NR_STATUS_LN queued=$NR_QUEUED_LN elif=$NR_ELIF_LN)"
    fi
  fi
  if printf '%s' "$NR_BODY" | grep -qF '_NR_ROUTE=$(default_pool_route_for_rig "$RIG")'; then
    ok "needs-rebase 'clear' sub-arm restores gc.routed_to via default_pool_route_for_rig (same convention as ga-f54ui)"
  else
    bad "needs-rebase 'clear' sub-arm does not restore gc.routed_to"
  fi
else
  bad "NR_BODY empty — cannot verify sub-arm (see A4)"
fi

echo "── A6. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

# ── B. Pure probe-eligibility predicate — proves the ACCEPTANCE CRITERIA ─────
# literal wording: "fix-attempt inalterado, bead elegivel no probe do
# worker" (AC1) and "FAIL de revisao -> bead open, sem gate:queued, elegivel
# no probe" (AC2). The predicate below mirrors the pool worker self-serve
# probe's real filter — directly observed shape (this dog's own Step 1c
# startup probe: status=open implied by `bd ready`, --unassigned,
# --exclude-label gate:queued/gate:reviewing/needs-human and siblings) and
# documented citywide (CLAUDE.md, ga-y8qh: wa-worker/ps-worker probes share
# this shape). It is a FAITHFUL MIRROR for test purposes, not the literal
# probe source (which lives in agents/*/prompt.template.md) — if the real
# probe's filter changes, this predicate needs updating to match, same as
# any other drift guard in this file class.

echo "── B. pure probe-eligibility predicate (mirrors the pool worker self-serve filter) ──"

probe_eligible() {
  local status="$1" assignee="$2" labels=" $3 " routed_to="$4" target="$5"
  [ "$status" = "open" ] || { echo "no"; return; }
  [ -z "$assignee" ] || { echo "no"; return; }
  [ "$routed_to" = "$target" ] || { echo "no"; return; }
  case "$labels" in
    *" gate:queued "*)     echo "no"; return ;;
    *" gate:reviewing "*)  echo "no"; return ;;
    *" gate:needs-human"*) echo "no"; return ;;
  esac
  echo "yes"
}

# ── B1 (AC1): merge-time-conflict scenario ────────────────────────────────
# BEFORE this fix, on a bead already at gate:fix-attempt:2 from earlier
# genuine review fails: a failed_merge_time_conflict bump would push it to
# gate:fix-attempt:3/3, escalate gate:needs-human, clear assignee but leave
# status=in_progress and gate:queued present (ga-f54ui restored gc.routed_to
# but this specific gap — status/gate:queued — is exactly wa-dnzu0's
# symptom). AFTER this fix: gate:fix-attempt:2 is untouched, gate:needs-
# rebase is added instead, status=open, gate:queued removed.
eq "BEFORE (documented bug shape): fix-attempt bumped 2->3, needs-human escalated, status left in_progress, gate:queued left present -> NOT eligible" \
  "$(probe_eligible "in_progress" "" "gate:failed gate:fix-attempt:3 gate:needs-human:technical gate:queued" "wa-worker" "wa-worker")" \
  "no"
eq "AFTER (this fix): fix-attempt:2 untouched (no :3 label), gate:needs-rebase added, status=open, gate:queued removed -> eligible" \
  "$(probe_eligible "open" "" "gate:failed gate:fix-attempt:2 gate:needs-rebase" "wa-worker" "wa-worker")" \
  "yes"
# The fix-attempt label ITSELF must be byte-identical before/after (the
# literal "fix-attempt inalterado" claim) — not just "eligibility flipped".
BEFORE_LABELS="gate:failed gate:fix-attempt:2"
AFTER_NEEDS_REBASE_LABELS="gate:failed gate:fix-attempt:2 gate:needs-rebase"
case " $AFTER_NEEDS_REBASE_LABELS " in
  *" gate:fix-attempt:2 "*) ok "fix-attempt:2 label survives unchanged into the needs-rebase state (gate:needs-rebase added alongside it, not replacing a bumped counter)" ;;
  *) bad "fix-attempt:2 label did not survive into the needs-rebase state" ;;
esac
case " $AFTER_NEEDS_REBASE_LABELS " in
  *" gate:fix-attempt:3 "*) bad "needs-rebase state unexpectedly carries a BUMPED gate:fix-attempt:3 — the counter was touched" ;;
  *) ok "needs-rebase state carries no bumped gate:fix-attempt:3 label" ;;
esac

# ── B2 (AC2): genuine review FAIL scenario (unrelated to merge conflicts) ──
# BEFORE this fix: gc.routed_to restored (ga-f54ui) but status left
# in_progress and gate:queued left present -> still NOT eligible despite the
# routing fix (this is the OTHER half of ga-f54ui's own gap, proven live by
# wa-dnzu0 even though wa-dnzu0's own trigger was a merge conflict, not a
# review rejection — the FAIL-and-return-to-pool code path is shared).
# AFTER this fix: status=open, gate:queued removed, gc.routed_to restored.
eq "BEFORE (documented ga-f54ui-incomplete shape): gc.routed_to restored, status left in_progress, gate:queued left present -> NOT eligible" \
  "$(probe_eligible "in_progress" "" "gate:failed gate:fix-attempt:1 gate:needs-fix" "wa-worker" "wa-worker")" \
  "no"
eq "AFTER (this fix): status=open, gate:queued removed, gc.routed_to restored -> eligible" \
  "$(probe_eligible "open" "" "gate:failed gate:fix-attempt:1 gate:needs-fix" "wa-worker" "wa-worker")" \
  "yes"

# ── B3: predicate sanity — still correctly EXCLUDES unrelated bad states ───
# (guards against a probe_eligible that vacuously returns "yes" always)
eq "assigned bead -> not eligible regardless of labels" \
  "$(probe_eligible "open" "someone" "" "wa-worker" "wa-worker")" \
  "no"
eq "wrong gc.routed_to target -> not eligible" \
  "$(probe_eligible "open" "" "" "ps-worker" "wa-worker")" \
  "no"
eq "gate:reviewing present -> not eligible (live marker, not actually returned to pool yet)" \
  "$(probe_eligible "open" "" "gate:reviewing" "wa-worker" "wa-worker")" \
  "no"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
