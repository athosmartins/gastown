#!/usr/bin/env bash
# quality-gate-guard.selftest.sh — regression harness for the pure decision
# functions of the gate guard (ga-jfo7 AWOL-run recovery). Sources the guard in
# GATE_GUARD_LIB_ONLY=1 mode so only the pure functions load (no main loop, no I/O).
#
# Focus (ga-jfo7 review-2 blocker): verdict_bead_count_for_run conflated a FAILED
# bd query with a confirmed-empty result via `bd ... || echo "[]"`, so a Dolt
# timeout (rc!=0) read as "0 verdict beads" — identical to a genuinely reviewer-
# AWOL run — and fired supersede:requeue-marker against a HEALTHY run. Dolt-hot is
# exactly when both the query fails AND real AWOLs happen, so the conflation is
# maximally dangerous. The pure verdict_count_from_query() must return a NON-numeric
# "unknown" on query failure so the caller's ''|*[!0-9]* fail-safe defers.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/quality-gate-guard.sh"
# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # the guard sources with `set -euo pipefail`; the harness counts its own pass/fail

P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

# ── verdict_count_from_query <rc> <stdout> — the ga-jfo7 review-2 fix ─────────
echo "verdict_count_from_query: query-failure must NOT read as 0 verdicts"
r=$(verdict_count_from_query 0 '[{"a":1},{"b":2}]'); [ "$r" = "2" ] && ok "rc0 2-elem array → 2" || bad "rc0 2-elem got '$r'"
r=$(verdict_count_from_query 0 '[{"a":1}]');        [ "$r" = "1" ] && ok "rc0 1-elem array → 1" || bad "rc0 1-elem got '$r'"
r=$(verdict_count_from_query 0 '[]');               [ "$r" = "0" ] && ok "rc0 empty array → 0 (genuine confirmed-empty)" || bad "rc0 [] got '$r'"
# THE regression: a failed query (nonzero rc) must be 'unknown', never numeric 0.
r=$(verdict_count_from_query 1 '');   case "$r" in ''|*[!0-9]*) ok "rc1 (Dolt query FAILED) → non-numeric unknown ('$r')" ;; *) bad "REGRESSION: rc1 mapped to numeric '$r' — the || echo [] bug: a query failure would supersede a HEALTHY run" ;; esac
r=$(verdict_count_from_query 1 '[]'); case "$r" in ''|*[!0-9]*) ok "rc1 with stale [] payload → still unknown (rc wins)" ;; *) bad "REGRESSION: rc1 [] mapped to numeric '$r'" ;; esac
r=$(verdict_count_from_query 2 '[{"a":1}]'); case "$r" in ''|*[!0-9]*) ok "rc2 with a real-looking payload → unknown (never trust a failed query's body)" ;; *) bad "REGRESSION: rc2 mapped to numeric '$r'" ;; esac
r=$(verdict_count_from_query 0 'not json');  case "$r" in ''|*[!0-9]*) ok "rc0 unparseable body → unknown (jq failure ≠ 0)" ;; *) bad "unparseable got numeric '$r'" ;; esac
r=$(verdict_count_from_query 0 '');          case "$r" in ''|*[!0-9]*) ok "rc0 empty body → unknown (bd returns [] for 0 matches; '' is anomalous)" ;; *) bad "rc0 empty body got numeric '$r'" ;; esac

# ── the caller contract (line ~638): unknown must fail-safe to 1 (skip), not 0 ─
echo "caller fail-safe: query-failure must NOT trigger the supersede branch"
zv=$(verdict_count_from_query 1 ''); case "$zv" in ''|*[!0-9]*) zv=1 ;; esac
[ "$zv" = "1" ] && ok "query-failure → ZV_TOTAL=1 → the 'if ZV_TOTAL = 0' supersede branch is skipped" || bad "fail-safe gave zv='$zv' — would enter the supersede branch"
zv=$(verdict_count_from_query 0 '[]'); case "$zv" in ''|*[!0-9]*) zv=1 ;; esac
[ "$zv" = "0" ] && ok "genuine confirmed-0 still flows to the supersede branch (recovery still works)" || bad "confirmed-0 became zv='$zv' — recovery would never fire"

# ── reconcile_zero_verdict_run_action regression (age-anchor contract, attempt 1) ─
echo "reconcile_zero_verdict_run_action: age anchor + marker-status routing"
r=$(reconcile_zero_verdict_run_action 5 15 dispatching);  [ "$r" = "skip" ] && ok "young (5≤15) → skip regardless of status (fresh handoff needs a moment)" || bad "young got '$r'"
r=$(reconcile_zero_verdict_run_action 30 15 queued);      [ "$r" = "supersede:still-queued" ] && ok "aged+queued → still-queued (close orphan bookkeeping, don't touch a healthily-queued marker)" || bad "aged queued got '$r'"
r=$(reconcile_zero_verdict_run_action 30 15 dispatching); [ "$r" = "supersede:requeue-marker" ] && ok "aged+dispatching → requeue-marker (dispatcher died mid-flight)" || bad "aged dispatching got '$r'"
r=$(reconcile_zero_verdict_run_action 30 15 claimed);     [ "$r" = "supersede:requeue-marker" ] && ok "aged+claimed → requeue-marker" || bad "aged claimed got '$r'"
r=$(reconcile_zero_verdict_run_action 30 15 '');          [ "$r" = "skip" ] && ok "aged+empty-status → skip (fail-safe, never guess)" || bad "empty status got '$r'"
r=$(reconcile_zero_verdict_run_action 30 15 reviewing);   [ "$r" = "skip" ] && ok "aged+unrecognized-status → skip (fail-safe)" || bad "unrecognized status got '$r'"

# ── dedup_gaterun_action <group_count> <is_newest> — ga-f1ngu ────────────────
# This is what retires the guard's own claim-receipt bead (gate-status:claimed
# as of ga-f1ngu) the sweep after a real gate-run bead (gate-status:running)
# lands for the same marker_id — group_count=2, the claim receipt is always
# older so is_newest=0 → supersede:duplicate; the real run is is_newest=1 → keep.
echo "dedup_gaterun_action: keep-newest across a shared marker_id group"
r=$(dedup_gaterun_action 1 1); [ "$r" = "keep" ] && ok "lone run (group_count=1) → keep, nothing to dedup" || bad "lone run got '$r'"
r=$(dedup_gaterun_action 0 1); [ "$r" = "keep" ] && ok "group_count=0 (no key / unmatched) → keep" || bad "group_count=0 got '$r'"
r=$(dedup_gaterun_action 2 1); [ "$r" = "keep" ] && ok "2-member group, this IS newest (the real dispatcher run) → keep" || bad "newest-of-2 got '$r'"
r=$(dedup_gaterun_action 2 0); [ "$r" = "supersede:duplicate" ] && ok "2-member group, NOT newest (the guard's stale claim receipt) → supersede:duplicate" || bad "oldest-of-2 got '$r'"
r=$(dedup_gaterun_action 3 0); [ "$r" = "supersede:duplicate" ] && ok "3-member group (re-queued marker spawned another retry), not newest → supersede:duplicate" || bad "oldest-of-3 got '$r'"
r=$(dedup_gaterun_action 3 1); [ "$r" = "keep" ] && ok "3-member group, this IS newest → keep" || bad "newest-of-3 got '$r'"
r=$(dedup_gaterun_action abc 0); [ "$r" = "keep" ] && ok "non-numeric group_count → keep (fail-safe, never guess)" || bad "non-numeric group_count got '$r'"
r=$(dedup_gaterun_action '' 0);  [ "$r" = "keep" ] && ok "empty group_count → keep (fail-safe)" || bad "empty group_count got '$r'"

# ── classify_parent_gap2 <dispatched> <live_assignee> <sling_found> <sling_needs_fix> <sling_closed> ─
echo "classify_parent_gap2: dispatch/assignee/sling routing"
r=$(classify_parent_gap2 1 0 1 1 0); [ "$r" = "free:fail-stranded" ] && ok "sling gate-failed → free:fail-stranded" || bad "sling-failed got '$r'"
r=$(classify_parent_gap2 1 0 1 0 1); [ "$r" = "free:pass-stranded" ] && ok "sling gate-passed+closed → free:pass-stranded" || bad "sling-passed got '$r'"
r=$(classify_parent_gap2 0 0 1 0 1); [ "$r" = "skip:not-dispatched" ] && ok "not pilot:dispatched → skip:not-dispatched" || bad "not-dispatched got '$r'"
r=$(classify_parent_gap2 1 1 1 0 1); [ "$r" = "skip:live-assignee" ] && ok "live assignee → skip:live-assignee (never race a live builder)" || bad "live-assignee got '$r'"
r=$(classify_parent_gap2 1 0 0 0 0); [ "$r" = "skip:no-sling" ] && ok "no 'Sling task bead' comment found → skip:no-sling" || bad "no-sling got '$r'"
r=$(classify_parent_gap2 1 0 1 0 0); [ "$r" = "skip:active-sling" ] && ok "sling still open/active → skip:active-sling" || bad "active-sling got '$r'"

# ── classify_gap2_bugtask_verdict <merge_verified> <has_untracked_marker> — ga-6ync4: sling-passed ≠ parent-fix-merged ─
echo "classify_gap2_bugtask_verdict: a passed+closed sling must NOT alone close the parent"
r=$(classify_gap2_bugtask_verdict 1); [ "$r" = "close:merge-verified" ] && ok "merged (branch/content evidence found) → close:merge-verified" || bad "merged got '$r'"
r=$(classify_gap2_bugtask_verdict 0); [ "$r" = "keep:merge-not-verified" ] && ok "NOT merged (sling passed but parent's own fix absent from origin/main) → keep:merge-not-verified (regression guard for ga-h565g-class false-close)" || bad "not-merged got '$r'"
r=$(classify_gap2_bugtask_verdict ''); [ "$r" = "keep:merge-not-verified" ] && ok "empty/anomalous input → keep:merge-not-verified (fail-safe, never guess merged)" || bad "empty input got '$r'"
# ga-x2x63: delivery:untracked marker must short-circuit to close, WITHOUT needing a branch
r=$(classify_gap2_bugtask_verdict 0 1); [ "$r" = "close:untracked-delivery" ] && ok "not merged but delivery:untracked marker present → close:untracked-delivery (ga-x2x63 false-positive fix)" || bad "untracked-marker got '$r'"
r=$(classify_gap2_bugtask_verdict '' 1); [ "$r" = "close:untracked-delivery" ] && ok "empty merge_verified + untracked marker → close:untracked-delivery" || bad "empty+untracked-marker got '$r'"
r=$(classify_gap2_bugtask_verdict 0 0); [ "$r" = "keep:merge-not-verified" ] && ok "not merged, no untracked marker → keep:merge-not-verified (unchanged legitimate-failure path)" || bad "not-merged-no-marker got '$r'"
r=$(classify_gap2_bugtask_verdict 1 1); [ "$r" = "close:merge-verified" ] && ok "merge_verified=1 wins over untracked marker (evidence beats trust)" || bad "verified-and-marker got '$r'"

# ── classify_external_pr_gap3 <pr_state> <review_decision> — ga-jto05: re-check
# story:awaiting-external-merge beads against the real gh pr view state instead
# of leaving the label to a human sweep forever. ─────────────────────────────
echo "classify_external_pr_gap3: external PR state routing"
r=$(classify_external_pr_gap3 MERGED); [ "$r" = "close:merged" ] && ok "MERGED → close:merged" || bad "MERGED got '$r'"
r=$(classify_external_pr_gap3 MERGED APPROVED); [ "$r" = "close:merged" ] && ok "MERGED (with a review decision too) → close:merged (state wins, review_decision irrelevant once terminal)" || bad "MERGED+APPROVED got '$r'"
r=$(classify_external_pr_gap3 CLOSED); [ "$r" = "flag:closed-not-merged" ] && ok "CLOSED (not merged — rejected/abandoned upstream) → flag:closed-not-merged" || bad "CLOSED got '$r'"
r=$(classify_external_pr_gap3 OPEN); [ "$r" = "wait:pending" ] && ok "OPEN, no review_decision → wait:pending (genuinely still pending, ga-yp9r8's actual live state)" || bad "OPEN got '$r'"
r=$(classify_external_pr_gap3 OPEN ''); [ "$r" = "wait:pending" ] && ok "OPEN, explicit empty review_decision → wait:pending" || bad "OPEN+empty got '$r'"
r=$(classify_external_pr_gap3 OPEN REVIEW_REQUIRED); [ "$r" = "wait:pending" ] && ok "OPEN, review_decision=REVIEW_REQUIRED → wait:pending (not a rejection)" || bad "OPEN+REVIEW_REQUIRED got '$r'"
r=$(classify_external_pr_gap3 OPEN APPROVED); [ "$r" = "wait:pending" ] && ok "OPEN, review_decision=APPROVED but not yet merged → wait:pending (nothing to fix, just waiting on the merge itself)" || bad "OPEN+APPROVED got '$r'"
r=$(classify_external_pr_gap3 OPEN CHANGES_REQUESTED); [ "$r" = "flag:changes-requested" ] && ok "OPEN, review_decision=CHANGES_REQUESTED → flag:changes-requested (ga-e2n96: the one case gate:needs-fix should actually mean — a reviewer really did reject the code)" || bad "OPEN+CHANGES_REQUESTED got '$r'"
r=$(classify_external_pr_gap3 ''); [ "$r" = "skip:indeterminate" ] && ok "empty pr_state (gh call failed / PR not found) → skip:indeterminate (fail-safe, never guess)" || bad "empty pr_state got '$r'"
r=$(classify_external_pr_gap3 DRAFT); [ "$r" = "skip:indeterminate" ] && ok "unrecognized pr_state → skip:indeterminate (fail-safe)" || bad "unrecognized pr_state got '$r'"

echo ""
echo "Results: $P passed, $F failed"
[ "$F" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; } || { echo "SELFTEST FAIL"; exit 1; }
