#!/usr/bin/env bash
# gate-verdict-assign-log-matches-outcome.selftest.sh — Prove the ga-590nx fix:
# the dispatcher's "Verdict bead X assigned to Y" log line only fires when
# assign_verdict_bead_verified() actually verified the link; a failed/degraded
# assignment is logged as a loud WARN, never as "assigned".
#
# Bug ga-590nx: assign_verdict_bead_verified() (ga-vdurb/ga-mo7q/ga-qqtoo)
# already does the hard part — write, read back, 4 retries with backoff, a
# metadata.gc.session_name fallback, and a WARN + verdict:assignee-degraded
# label on total exhaustion. But BOTH call sites (initial spawn ~Step 7/8, and
# respawn_reviewer_slot's re-convene path) threw that verified/not-verified
# result away with `|| true` and then logged "Verdict bead X assigned to Y +
# task embedded" UNCONDITIONALLY on the very next line — so the helper's own
# loud WARN on a real failure was immediately followed by a line claiming
# success anyway.
#
# MEASURED LIVE 2026-09-06 (same sweep, same code path): verdict bead ga-zpch2
# (assignee never persisted, only metadata.gc.session_name did) and verdict
# bead ga-dmnxm (assignee persisted normally) produced the IDENTICAL dispatcher
# log line "Verdict bead <id> assigned to <session>" — no way to tell a healthy
# write from a degraded one without re-querying the bead by hand. A third
# reviewer (gate-reviewer-adhoc-c02bf946d3) exhausted all 8 polling checks
# (both the --assignee query AND the ga-mo7q metadata fallback) and died
# orphaned — the run flew blind until the 30-36min timeout.
#
# Fix: branch on assign_verdict_bead_verified()'s real exit code at both call
# sites. Verified (0) → unchanged "assigned...+task embedded" log. Not
# verified (1) → a distinct, loud WARN instead — the task comment is still
# embedded as a last-resort channel (comment-embed is independent of the
# assignee/metadata channels and must not be skipped), but the log never
# claims a link that was never confirmed. assign_verdict_bead_verified() ITSELF
# is untouched — same 4 retries, same metadata fallback, same degraded label
# (ACEITE #3: don't remove the reader's safety net, fix the writer's claim).
#
# This harness mirrors the PURE outcome→message contract for direct unit
# testing (Section 1/2 — same technique every *.selftest.sh in this directory
# uses: no live bd/Dolt calls), then drift-guards the real shipped file to
# prove the unconditional-log shape is actually gone and the conditional shape
# actually replaced it at BOTH call sites (Section 3) — mirrors the structural
# checks in gate-verdict-assignee-fallback.selftest.sh Section 3.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }
absent() { if grep -qE "$2" "$1"; then bad "$3 — pattern still present: $2"; else ok "$3"; fi; }

# ── The PURE contract the caller MUST implement: the summary log message is a
# function of assign_verdict_bead_verified()'s real exit code, never constant.
# $1 = "0" (verified) or "1" (not verified) — mirrors $? from the helper.
caller_log_message_fixed() {
  local _verify_rc="$1"
  if [ "$_verify_rc" = "0" ]; then
    echo "assigned"
  else
    echo "degraded"
  fi
}

# The ORIGINAL bug: the message ignores the outcome entirely (this is what
# `assign_verdict_bead_verified ... || true` followed by an unconditional log
# actually does — the exit code is discarded before the log line runs).
caller_log_message_buggy() {
  local _verify_rc="$1"
  echo "assigned"
}

echo "── 1. contract: log message must reflect the real verify outcome ──"
eq "verified (rc=0) → 'assigned'"     "$(caller_log_message_fixed 0)" "assigned"
eq "not verified (rc=1) → 'degraded'" "$(caller_log_message_fixed 1)" "degraded"

echo
echo "── 2. mutation: neutralizing the branch reproduces the ORIGINAL ga-590nx bug ──"
# Same not-verified input, but through the buggy (unconditional) message
# function — this is exactly what shipped before the fix. It MUST say
# "assigned" even though verification failed; that collapse (success and
# failure producing the same log line) IS the bug ga-590nx reports.
buggy_result="$(caller_log_message_buggy 1)"
if [ "$buggy_result" = "assigned" ]; then
  ok "unconditional-log variant claims 'assigned' even when rc=1 (not verified) — reproduces the original bug, proves the branch is what fixes it"
else
  bad "unconditional-log variant unexpectedly said [$buggy_result] for rc=1 — mirror no longer matches the real bug"
fi
eq "healthy case unaffected either way (rc=0)" "$(caller_log_message_buggy 0)" "assigned"

echo
echo "── 3. DRIFT-GUARD: the real shipped file actually branches on the outcome ──"

# 3a. Initial-spawn call site (~Step 7/8): the OLD unconditional shape — call
# with a swallowed `|| true` and no conditional around it — must be GONE.
absent "$GATE" 'assign_verdict_bead_verified "\$VERDICT_BEAD_ID" "\$SESSION_NAME" "initial slot \$i" \|\| true' \
    "quality-gate-dispatcher.sh: initial-spawn call site no longer discards the verify result with a bare || true"

# 3b. ...and the NEW conditional shape must be present in its place.
has "$GATE" 'if assign_verdict_bead_verified "\$VERDICT_BEAD_ID" "\$SESSION_NAME" "initial slot \$i"; then' \
    "quality-gate-dispatcher.sh: initial-spawn call site branches on assign_verdict_bead_verified's real exit code"

# 3c. Re-convene call site (respawn_reviewer_slot): same two checks.
absent "$GATE" 'assign_verdict_bead_verified "\$\{VERDICT_BEAD_IDS\[\$_idx\]\}" "\$_new_sname" "re-convene slot \$\{_idx\}" \|\| true' \
    "quality-gate-dispatcher.sh: re-convene call site no longer discards the verify result with a bare || true"

has "$GATE" 'if assign_verdict_bead_verified "\$\{VERDICT_BEAD_IDS\[\$_idx\]\}" "\$_new_sname" "re-convene slot \$\{_idx\}"; then' \
    "quality-gate-dispatcher.sh: re-convene call site branches on assign_verdict_bead_verified's real exit code"

# 3d. Both failure branches must warn loudly and distinctly — not silently
# fall through to the same "assigned" claim. Count must be exactly 2 (one per
# call site); either 0 (not wired) or 1 (only one site fixed) is a failure.
DID_NOT_VERIFY_COUNT=$(grep -c 'DID NOT VERIFY after retries' "$GATE" 2>/dev/null || echo 0)
eq "both call sites (initial spawn + re-convene) warn loudly on a failed verify" "${DID_NOT_VERIFY_COUNT:-0}" "2"

# 3e. The healthy-path log message is unchanged (still says "assigned...+task
# embedded") — this fix must not alter behavior on the success path.
ASSIGNED_LOG_COUNT=$(grep -cE '(assigned to \$SESSION_NAME|re-assigned to NEW session name \$\{_new_sname\}) \+? ?(task embedded)?' "$GATE" 2>/dev/null || echo 0)
if [ "${ASSIGNED_LOG_COUNT:-0}" -ge 2 ]; then
  ok "success-path log wording is preserved at both call sites (count=$ASSIGNED_LOG_COUNT)"
else
  bad "success-path log wording missing or reduced (count=${ASSIGNED_LOG_COUNT:-0}) — fix must not touch the healthy path"
fi

# 3f. The comment-embed (independent durable-pull channel) must still fire
# UNCONDITIONALLY — regression guard: the fix must branch the LOG only, never
# wrap the comment-embed itself inside the verified-only branch (that would
# silently drop a working fallback for degraded beads while "fixing" the log —
# ACEITE #3: don't weaken the safety net). Exact lines, unchanged from before
# the fix, must still be present at both call sites.
has "$GATE" 'bd -C "\$GC_CITY" comment "\$VERDICT_BEAD_ID" "\$REVIEW_TASK" 2>/dev/null \|\| true' \
    "quality-gate-dispatcher.sh: initial-spawn comment-embed line still present, unconditional"
has "$GATE" 'bd -C "\$GC_CITY" comment "\$\{VERDICT_BEAD_IDS\[\$_idx\]\}" "\$\{REVIEW_TASKS\[\$_idx\]\}" 2>/dev/null \|\| true' \
    "quality-gate-dispatcher.sh: re-convene comment-embed line still present, unconditional"

echo
echo "── 4. DRIFT-GUARD: assign_verdict_bead_verified() itself is untouched (ACEITE #3) ──"
# Same checks gate-verdict-assignee-fallback.selftest.sh already makes — this
# fix must not weaken the helper's own retry/fallback/label logic, only fix
# how its callers log the result.
has "$GATE" 'for _try in 1 2 3 4' \
    "quality-gate-dispatcher.sh: assign_verdict_bead_verified still retries 4x"
has "$GATE" 'verdict:assignee-degraded' \
    "quality-gate-dispatcher.sh: still labels the bead on final assign failure"
has "$GATE" 'metadata\.gc\.session_name did .*— durable link present via the fallback channel' \
    "quality-gate-dispatcher.sh: metadata fallback success path still present (ga-mo7q net not removed)"

echo
echo "── RESULT: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
