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

# ── marker_status_from_labels <labels> — ga-i0n83 ambiguity guard ────────────
# set_gate_status now ADDs before it REMOVEs (ga-i0n83), so an interrupted
# transition can leave a marker with TWO gate-status:* labels instead of the
# pre-existing zero-label failure mode. Both must route to the SAME safe
# "skip" outcome via reconcile_zero_verdict_run_action — never guess between
# two candidates via a blind first-match pick.
echo "marker_status_from_labels: exactly-one-match extraction, never a blind first-match guess"
r=$(marker_status_from_labels 'type:quality-gate-marker gate-status:queued branch:fix/x');
[ "$r" = "queued" ] && ok "single gate-status label → extracted cleanly (the common case, unchanged)" || bad "single-label got '$r'"
r=$(marker_status_from_labels 'type:quality-gate-marker branch:fix/x');
[ "$r" = "" ] && ok "zero gate-status labels → empty (the pre-existing ga-5jyo8 invisible-forever case)" || bad "zero-label got '$r'"
r=$(marker_status_from_labels 'gate-status:claimed gate-status:queued type:quality-gate-marker');
[ "$r" = "" ] && ok "TWO gate-status labels (mid-transition, ga-i0n83) → empty, NEVER a blind head-1 guess between claimed/queued" || bad "REGRESSION ga-i0n83: two-label input resolved to '$r' instead of empty — a blind pick could feed reconcile_zero_verdict_run_action a stale status"
r=$(marker_status_from_labels '');
[ "$r" = "" ] && ok "empty label string → empty (no crash, no false match)" || bad "empty input got '$r'"
# End-to-end: the two-label case must reach the SAME safe outcome as zero-label.
r=$(reconcile_zero_verdict_run_action 30 15 "$(marker_status_from_labels 'gate-status:claimed gate-status:queued')")
[ "$r" = "skip" ] && ok "end-to-end: two-label marker_status feeds reconcile_zero_verdict_run_action → skip (never supersede:requeue-marker on an ambiguous read)" || bad "REGRESSION ga-i0n83: two-label chain produced '$r', not skip"

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

# ── classify_parent_gap2 <dispatched> <live_assignee> <sling_found> <sling_needs_fix> <sling_closed> [sling_refused] ─
echo "classify_parent_gap2: dispatch/assignee/sling routing"
r=$(classify_parent_gap2 1 0 1 1 0); [ "$r" = "free:fail-stranded" ] && ok "sling gate-failed → free:fail-stranded" || bad "sling-failed got '$r'"
r=$(classify_parent_gap2 1 0 1 0 1); [ "$r" = "free:pass-stranded" ] && ok "sling gate-passed+closed → free:pass-stranded" || bad "sling-passed got '$r'"
r=$(classify_parent_gap2 0 0 1 0 1); [ "$r" = "skip:not-dispatched" ] && ok "not pilot:dispatched → skip:not-dispatched" || bad "not-dispatched got '$r'"
r=$(classify_parent_gap2 1 1 1 0 1); [ "$r" = "skip:live-assignee" ] && ok "live assignee → skip:live-assignee (never race a live builder)" || bad "live-assignee got '$r'"
r=$(classify_parent_gap2 1 0 0 0 0); [ "$r" = "skip:no-sling" ] && ok "no 'Sling task bead' comment found → skip:no-sling" || bad "no-sling got '$r'"
r=$(classify_parent_gap2 1 0 1 0 0); [ "$r" = "skip:active-sling" ] && ok "sling still open/active → skip:active-sling" || bad "active-sling got '$r'"
# ga-eu75w: every line above omits the 6th arg entirely (the pre-existing 5-arg
# call shape) — this whole block passing unchanged IS the backward-compat proof
# that sling_refused defaults to 0 and reproduces the exact old routing.

# ── classify_parent_gap2 sling_refused (ga-eu75w: a refusal ≠ a gate-pass) ───
# Bug: "sling closed + no gate:needs-fix" used to be read as "gate-passed",
# silently conflating an explicit pool:refused[:reason] worker refusal (which
# never reached a gate review at all) with a genuine pass. The observed
# consequence: parents re-armed with gate:needs-fix/gate:needs-remerge with no
# branch and no gate-run anywhere, which gate-orphaned-label-watchdog.sh then
# flagged every cycle forever (ga-1ztxb, ga-6bghe, ga-aw0db/ga-avvu2, one night).
echo "classify_parent_gap2: sling_refused must not be read as gate-passed"
r=$(classify_parent_gap2 1 0 1 0 1 1); [ "$r" = "free:refused-stranded" ] && ok "sling closed via refusal → free:refused-stranded (NOT free:pass-stranded)" || bad "refused-closed got '$r'"
r=$(classify_parent_gap2 1 0 1 0 1 0); [ "$r" = "free:pass-stranded" ] && ok "sling closed, explicitly NOT refused → free:pass-stranded unchanged" || bad "explicit-not-refused got '$r'"
r=$(classify_parent_gap2 1 0 1 0 0 1); [ "$r" = "skip:active-sling" ] && ok "refused but sling still OPEN (not closed) → skip:active-sling (inflight-reclaim-guard.py owns that in-flight window, not GAP-2)" || bad "refused-but-open got '$r'"
r=$(classify_parent_gap2 1 0 1 1 0 1); [ "$r" = "free:fail-stranded" ] && ok "ga-eu75w ACCEPTANCE CRITERION: a genuine gate-FAIL beats a coincidental refused signal — never swallow a real rejection" || bad "fail-beats-refused got '$r'"
r=$(classify_parent_gap2 1 0 1 1 1 1); [ "$r" = "free:fail-stranded" ] && ok "gate-failed AND closed AND refused-token all present → still free:fail-stranded (fail wins regardless)" || bad "fail-wins-all got '$r'"
r=$(classify_parent_gap2 1 1 1 0 1 1); [ "$r" = "skip:live-assignee" ] && ok "live assignee still short-circuits even with a refused sling" || bad "live-assignee-with-refused got '$r'"

# ── gap2_refused_token <sling_labels> <parent_labels> <sling_close_reason> — ga-eu75w ─
# Three-tier scan, priority order, because the real refusal location varies:
# documented ps-worker/wa-worker path labels the SLING; the ga-1ztxb/ga-0hela
# live incident instead labeled the PARENT and left the reason only in the
# sling's own close_reason text (confirmed: ga-0hela's real labels were just
# ["ctx:ready","exec:auto"] — no pool:refused anywhere on the sling itself).
echo "gap2_refused_token: three-tier detection (sling label > parent label > close_reason text)"
r=$(gap2_refused_token "pool:refused:engine-rebuild-required" "" ""); [ "$r" = "pool:refused:engine-rebuild-required" ] && ok "sling's own label (documented path) → found" || bad "sling-label got '$r'"
r=$(gap2_refused_token "ctx:ready exec:auto" "pool:refused:engine-rebuild-required" ""); [ "$r" = "pool:refused:engine-rebuild-required" ] && ok "parent's own label (ga-1ztxb precedent: sling carries no pool:refused label at all) → found" || bad "parent-label got '$r'"
r=$(gap2_refused_token "ctx:ready exec:auto" "framework:observability lane:small" "pool:refused:engine-rebuild-required — see comment + label on target bead ga-1ztxb."); [ "$r" = "pool:refused:engine-rebuild-required" ] && ok "close_reason text only (real ga-0hela shape: neither sling nor parent labeled yet) → found" || bad "close-reason got '$r'"
r=$(gap2_refused_token "pool:refused" "" ""); [ "$r" = "pool:refused" ] && ok "bare pool:refused (no reason suffix) is a valid complete match" || bad "bare-refused got '$r'"
r=$(gap2_refused_token "pool:refused:sling-reason" "pool:refused:parent-reason" ""); [ "$r" = "pool:refused:sling-reason" ] && ok "sling label wins over parent label when both present (documented source takes priority)" || bad "priority-order got '$r'"
r=$(gap2_refused_token "gate:needs-fix" "story:in-flight pilot:dispatched" "gate-failed, see review comments"); [ "$r" = "" ] && ok "no pool:refused anywhere → empty (this is the pass/fail-stranded case, not refused)" || bad "no-match got '$r'"
r=$(gap2_refused_token "" "" ""); [ "$r" = "" ] && ok "all-empty inputs → empty, no crash" || bad "all-empty got '$r'"

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

# ── reconcile_dead_reviewer_verdict_action <age> <grace> <reviewer_alive> <parent_terminal> ─
# ga-u07fn: verdict-scoped sibling of reconcile_gaterun_action — releases ONE
# stuck verdict for re-convocation (parent run still alive) or closes it
# (parent run terminal), instead of Vector B's only option of superseding the
# WHOLE run. Worked examples are the live cases Mayor triaged by hand
# (ga-jeicm comment, 2026-08-07T23:29:11Z) that this function must reproduce.
echo "reconcile_dead_reviewer_verdict_action: release vs close vs skip, verdict-scoped"
r=$(reconcile_dead_reviewer_verdict_action 63 15 0 0); [ "$r" = "release" ] && ok "ga-k2na1 case: 63min dead, run active → release" || bad "ga-k2na1 case got '$r'"
r=$(reconcile_dead_reviewer_verdict_action 88 15 0 1); [ "$r" = "close" ] && ok "ga-u8e1h case: 88min dead, run terminal → close" || bad "ga-u8e1h case got '$r'"
r=$(reconcile_dead_reviewer_verdict_action 13 15 0 0); [ "$r" = "skip" ] && ok "ga-vvmc4 case: 13min, no live session, run active → skip (still might be booting, 13<=15 grace)" || bad "ga-vvmc4 case got '$r'"
r=$(reconcile_dead_reviewer_verdict_action 13 15 0 1); [ "$r" = "skip" ] && ok "young + run terminal → still skip (grace wins regardless of parent state)" || bad "young+terminal got '$r'"
r=$(reconcile_dead_reviewer_verdict_action 999 15 1 0); [ "$r" = "skip" ] && ok "reviewer_alive=1 wins over everything, even a very old verdict → skip (nothing wrong)" || bad "alive-old got '$r'"
r=$(reconcile_dead_reviewer_verdict_action 999 15 1 1); [ "$r" = "skip" ] && ok "reviewer_alive=1 + parent terminal → still skip (a live reviewer on a run that just closed isn't THIS function's problem)" || bad "alive-terminal got '$r'"
r=$(reconcile_dead_reviewer_verdict_action 16 15 0 0); [ "$r" = "release" ] && ok "just past grace (16>15), run active → release" || bad "just-past-grace-active got '$r'"
r=$(reconcile_dead_reviewer_verdict_action 15 15 0 0); [ "$r" = "skip" ] && ok "exactly at grace boundary (15<=15) → skip (inclusive, mirrors reconcile_zero_verdict_run_action's own <= convention)" || bad "boundary got '$r'"

# ── reconcile_orphaned_verdict_action <age> <grace> <has_gate_run_label> <parent_lookup_state> ─
# ga-qtc16: Step 0b.2's sibling of reconcile_dead_reviewer_verdict_action above,
# for verdicts whose PARENT gate-run bead is gone entirely (not just a dead
# reviewer on an otherwise-live run). parent_lookup_state is a 3-state string
# ("found"/"not_found"/"unknown") — "unknown" must behave identically to
# "found" here (both skip), since only a CONFIRMED absence is ever safe to act
# on (root-class:error-vs-empty).
echo "reconcile_orphaned_verdict_action: close only on confirmed-absent parent, past grace, with a gate-run label"
r=$(reconcile_orphaned_verdict_action 100 15 1 not_found); [ "$r" = "close" ] && ok "old, has label, parent confirmed not_found → close" || bad "old+notfound got '$r'"
r=$(reconcile_orphaned_verdict_action 5 15 1 not_found); [ "$r" = "skip" ] && ok "young (5<=15 grace), otherwise closeable → skip (replication-lag guard wins)" || bad "young+notfound got '$r'"
r=$(reconcile_orphaned_verdict_action 15 15 1 not_found); [ "$r" = "skip" ] && ok "exactly at grace boundary (15<=15) → skip (inclusive, same convention as the sibling function)" || bad "boundary got '$r'"
r=$(reconcile_orphaned_verdict_action 16 15 1 not_found); [ "$r" = "close" ] && ok "just past grace (16>15), confirmed not_found → close" || bad "just-past-grace got '$r'"
r=$(reconcile_orphaned_verdict_action 100 15 1 found); [ "$r" = "skip" ] && ok "old, has label, parent FOUND → skip (genuinely pending, not orphaned — must never touch this case)" || bad "old+found got '$r'"
r=$(reconcile_orphaned_verdict_action 100 15 1 unknown); [ "$r" = "skip" ] && ok "old, has label, parent lookup UNKNOWN (query failed) → skip (unknown is never confirmed-absent, the whole point of this function)" || bad "old+unknown got '$r'"
r=$(reconcile_orphaned_verdict_action 100 15 0 not_found); [ "$r" = "skip" ] && ok "old, NO gate-run label at all → skip (nothing to check parent liveness against, never guess)" || bad "no-label got '$r'"
r=$(reconcile_orphaned_verdict_action 999999 15 1 unknown); [ "$r" = "skip" ] && ok "even a VERY old verdict with unknown parent state stays skip — age alone never overrides an unconfirmed lookup" || bad "very-old+unknown got '$r'"

# ── session_alive_for_assignee <assignee> <sess_snap_json> — single-assignee liveness ─
echo "session_alive_for_assignee: matches id/session_name/session_id, excludes closed"
SNAP='[{"id":"gate-reviewer-adhoc-abc123","closed":false},{"session_name":"gate-reviewer-adhoc-dead999","closed":true},{"session_id":"gate-reviewer-adhoc-xyz","closed":false}]'
r=$(session_alive_for_assignee "gate-reviewer-adhoc-abc123" "$SNAP"); [ "$r" = "1" ] && ok "matches by .id, open → alive" || bad "id-match got '$r'"
r=$(session_alive_for_assignee "gate-reviewer-adhoc-xyz" "$SNAP"); [ "$r" = "1" ] && ok "matches by .session_id, open → alive" || bad "session_id-match got '$r'"
r=$(session_alive_for_assignee "gate-reviewer-adhoc-dead999" "$SNAP"); [ "$r" = "0" ] && ok "matches by .session_name but closed:true → NOT alive" || bad "closed-session got '$r'"
r=$(session_alive_for_assignee "gate-reviewer-adhoc-nowhere" "$SNAP"); [ "$r" = "0" ] && ok "no matching session at all → not alive" || bad "no-match got '$r'"
r=$(session_alive_for_assignee "" "$SNAP"); [ "$r" = "0" ] && ok "empty assignee → not alive, no crash (never was assigned to anyone)" || bad "empty-assignee got '$r'"
r=$(session_alive_for_assignee "gate-reviewer-adhoc-abc123" '{"sessions":[{"id":"gate-reviewer-adhoc-abc123","closed":false}]}'); [ "$r" = "1" ] && ok "wrapped {sessions:[...]} shape (not bare array) → still matches" || bad "wrapped-shape got '$r'"
r=$(session_alive_for_assignee "gate-reviewer-adhoc-abc123" 'not json'); [ "$r" = "0" ] && ok "unparseable snapshot → fail-safe not-alive (never crashes the sweep)" || bad "unparseable-snap got '$r'"
r=$(session_alive_for_assignee "gate-reviewer-adhoc-abc123" ''); [ "$r" = "0" ] && ok "empty snapshot → fail-safe not-alive" || bad "empty-snap got '$r'"

# ── gaterun_status_terminal <gate-status-value> — exhaustive gate-run vocabulary ─
# The 4 terminal + 2 non-terminal values below are the FULL set ever assigned
# to a gate-run bead (verified by grepping every set_gate_status "$GR_ID"/
# "$GATE_RUN_ID" call site — see the function's own docstring). Marker-only
# values (error, done, queued, ready, ...) deliberately are NOT tested here as
# "non-terminal" cases — a gate-run is never observed carrying them, so what
# this function does with them is moot; the fail-safe default (non-terminal)
# just happens to also cover that hypothetical.
echo "gaterun_status_terminal: exhaustive real gate-run vocabulary"
r=$(gaterun_status_terminal superseded); [ "$r" = "1" ] && ok "superseded → terminal" || bad "superseded got '$r'"
r=$(gaterun_status_terminal aborted);    [ "$r" = "1" ] && ok "aborted → terminal" || bad "aborted got '$r'"
r=$(gaterun_status_terminal passed);     [ "$r" = "1" ] && ok "passed → terminal" || bad "passed got '$r'"
r=$(gaterun_status_terminal failed);     [ "$r" = "1" ] && ok "failed → terminal" || bad "failed got '$r'"
r=$(gaterun_status_terminal running);    [ "$r" = "0" ] && ok "running → NOT terminal (live run)" || bad "running got '$r'"
r=$(gaterun_status_terminal claimed);    [ "$r" = "0" ] && ok "claimed → NOT terminal (guard's own tracking bead, still live)" || bad "claimed got '$r'"
r=$(gaterun_status_terminal '');         [ "$r" = "0" ] && ok "empty/unreadable → fail-safe NOT terminal (never close a verdict on a guess)" || bad "empty got '$r'"
r=$(gaterun_status_terminal weird-future-status); [ "$r" = "0" ] && ok "unrecognized future value → fail-safe NOT terminal" || bad "unrecognized got '$r'"

echo ""
echo "Results: $P passed, $F failed"
[ "$F" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; } || { echo "SELFTEST FAIL"; exit 1; }
