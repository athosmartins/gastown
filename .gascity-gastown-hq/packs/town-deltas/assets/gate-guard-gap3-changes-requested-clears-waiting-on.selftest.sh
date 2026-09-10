#!/usr/bin/env bash
# gate-guard-gap3-changes-requested-clears-waiting-on.selftest.sh — regression
# guard for ga-w8mvq.
#
# ROOT BUG: GAP-3's terminal transitions (merged / closed-without-merge /
# changes-requested) always removed story:awaiting-external-merge but never
# touched the waiting-on:pr-<N> label some agents ALSO apply alongside it
# when re-parking a bead after pushing a fix (see the Mayor's "AO
# RE-ESTACIONAR" contract on ga-wpdum's own comment thread). Pilot's
# _filter_dispatch_gates (pilot-dispatcher.sh) treats ANY waiting-on:* label
# as an unconditional dispatch veto — so a changes-requested transition into
# gate:needs-fix (the exact signal meant to make Pilot dispatch a builder
# right now) left the bead permanently stuck behind its own stale label.
# Live evidence: ga-wpdum/#5393, ga-7uoua/#5470, ga-r8haw/#5384 all sat ~2h40
# with gate:needs-fix and zero dispatch attempts, until the Mayor removed
# waiting-on:pr-<N> by hand.
#
# FIX: compute the bead's current waiting-on:pr-* labels once (from the
# $EXT_SHOW already fetched earlier in the sweep — a pure jq read, no side
# effect) and clear them in all three terminal arms. Not hardcoded to the
# freshly-parsed $EXT_NUM alone, so a stale label left behind by an earlier
# abandoned PR (different number) is also cleared. Nothing is lost: the PR
# reference already lives durably in the bead's own `external_ref` field (set
# at initial dispatch, ga-ycsl9) and GAP-3 re-derives it from comments on
# every sweep regardless (EXT_PR_REF) — waiting-on:pr-<N> is a display
# convenience label, not GAP-3's own source of truth.
#
# Strategy: pull the live EXT_ACTION/case snippet VERBATIM out of
# quality-gate-guard.sh (anchored on stable literal substrings, same
# technique as gate-guard-gap3-ext-show-failure-detection.selftest.sh) and
# exercise each arm in an isolated subshell with a fake `bd`/`log`/`warn` and
# a stubbed classify_external_pr_gap3 (already exhaustively tested on its own
# in quality-gate-guard.selftest.sh — this file tests the SIDE EFFECTS of
# each arm, not the classification decision). Pure bash + awk/jq. Never runs
# gc/bd, never touches the live city or beads — safe to run on a live host.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "== gate-guard-gap3-changes-requested-clears-waiting-on.selftest (ga-w8mvq) =="

if [ ! -f "$GUARD" ]; then
  bad "quality-gate-guard.sh not found next to selftest at $GUARD"
  echo
  echo "── results: $PASS passed, $FAIL failed ──"
  exit 1
fi

# extract_ext_action_case_snippet <file> — pulls the EXT_ACTION assignment
# plus the full `case "$EXT_ACTION" in ... esac` block verbatim: from the
# `EXT_ACTION=$(classify_external_pr_gap3 ...)` opener through the `esac`
# that closes the block (3 lines after the skip:indeterminate) label: its log
# line, its `;;`, and `esac`). Anchored on literal substrings via awk's
# index(), same technique as the sibling GAP-3 selftests, since the
# surrounding shell is full of literal $ and quote characters a regex would
# have to escape.
extract_ext_action_case_snippet() {
  local file="$1"
  awk '
    index($0, "EXT_ACTION=$(classify_external_pr_gap3") > 0 { grabbing=1 }
    grabbing { print }
    grabbing && index($0, "skip:indeterminate)") > 0 { trail=3; next }
    trail > 0 { trail--; if (trail == 0) exit }
  ' "$file"
}

echo "── 1. live source carries the expected EXT_ACTION/case block ──"
LIVE_SNIPPET="$(extract_ext_action_case_snippet "$GUARD")"
if [ -z "$LIVE_SNIPPET" ]; then
  bad "could not extract the EXT_ACTION/case block from $GUARD — anchors drifted?"
  echo
  echo "── results: $PASS passed, $FAIL failed ──"
  exit 1
else
  ok "extracted EXT_ACTION/case block from live source"
fi

# run_snippet <forced_action> <ext_show_json> — execs the live snippet in an
# isolated subshell (same set -euo pipefail as the real script) with a fake
# classify_external_pr_gap3 that returns exactly <forced_action> (the real
# decision function is exhaustively tested elsewhere — this harness tests
# what each arm DOES, not which arm gets picked), a fake bd that echoes every
# invocation prefixed BD_CALL:, and $EXT_SHOW set to the caller's fixture.
run_snippet() {
  local forced_action="$1" ext_show_json="$2"
  bash -c '
    set -euo pipefail
    FORCED_ACTION="$1"
    GC_CITY="/fake/city"
    EXT_ID="ga-test"
    EXT_STATE="OPEN"
    EXT_REVIEW="CHANGES_REQUESTED"
    EXT_CHANGES_ADDRESSED="0"
    EXT_MERGE_SHA=""
    EXT_URL="https://github.com/gastownhall/beads/pull/5393"
    EXT_REPO="gastownhall/beads"
    EXT_NUM="5393"
    EXT_VERDICT_SOURCE=""
    EXT_HEAD_SHA=""
    EXT_CR_COMMIT=""
    EXT_SHOW="$2"
    classify_external_pr_gap3() { printf "%s" "$FORCED_ACTION"; }
    bd()   { echo "BD_CALL:$*"; return 0; }
    log()  { echo "LOG:$*"; }
    warn() { echo "WARN:$*"; }
    for _once in 1; do
'"$LIVE_SNIPPET"'
    done
  ' _ "$forced_action" "$ext_show_json" 2>&1
}

BEAD_WITH_MATCHING_LABEL='{"labels":["story:awaiting-external-merge","waiting-on:pr-5393","pilot:no-auto-dispatch"]}'
BEAD_WITH_STALE_LABEL='{"labels":["story:awaiting-external-merge","waiting-on:pr-9999","pilot:no-auto-dispatch"]}'
BEAD_WITH_NO_WAITING_LABEL='{"labels":["story:awaiting-external-merge","pilot:no-auto-dispatch"]}'

echo "── 2. flag:changes-requested clears the matching waiting-on:pr-<N> label ──"
OUT="$(run_snippet "flag:changes-requested" "$BEAD_WITH_MATCHING_LABEL")"
case "$OUT" in
  *"BD_CALL:-C /fake/city label remove ga-test waiting-on:pr-5393 -q"*)
    ok "cleared waiting-on:pr-5393 on the changes-requested transition — the exact dead-end ga-w8mvq exists to close" ;;
  *) bad "did NOT clear waiting-on:pr-5393 on changes-requested — bead would stay un-dispatchable behind its own label. Output: $OUT" ;;
esac
case "$OUT" in
  *"BD_CALL:-C /fake/city label add ga-test gate:needs-fix -q"*)
    ok "still adds gate:needs-fix (existing behavior unchanged)" ;;
  *) bad "gate:needs-fix add regressed. Output: $OUT" ;;
esac
case "$OUT" in
  *"BD_CALL:-C /fake/city label remove ga-test story:awaiting-external-merge -q"*)
    ok "still removes story:awaiting-external-merge (existing behavior unchanged)" ;;
  *) bad "story:awaiting-external-merge removal regressed. Output: $OUT" ;;
esac

echo "── 3. flag:changes-requested clears a STALE waiting-on:pr-<N> even if its number doesn't match \$EXT_NUM ──"
OUT="$(run_snippet "flag:changes-requested" "$BEAD_WITH_STALE_LABEL")"
case "$OUT" in
  *"BD_CALL:-C /fake/city label remove ga-test waiting-on:pr-9999 -q"*)
    ok "cleared the stale waiting-on:pr-9999 (left over from an earlier abandoned PR) — not hardcoded to \$EXT_NUM" ;;
  *) bad "did NOT clear the mismatched-number stale label. Output: $OUT" ;;
esac

echo "── 4. flag:changes-requested is a safe no-op when no waiting-on:pr-* label is present ──"
OUT="$(run_snippet "flag:changes-requested" "$BEAD_WITH_NO_WAITING_LABEL")"
case "$OUT" in
  *"BD_CALL:"*"label remove ga-test "*"waiting-on"*)
    bad "called bd label remove with an empty/bogus waiting-on argument when none was present. Output: $OUT" ;;
  *) ok "no bd label-remove call for waiting-on when the bead never had one (no malformed empty-arg call)" ;;
esac
case "$OUT" in
  *"BD_CALL:-C /fake/city label add ga-test gate:needs-fix -q"*)
    ok "gate:needs-fix still gets added even with no waiting-on label to clear" ;;
  *) bad "gate:needs-fix add broke in the no-waiting-on-label case. Output: $OUT" ;;
esac

echo "── 5. close:merged also clears waiting-on:pr-<N> ──"
OUT="$(run_snippet "close:merged" "$BEAD_WITH_MATCHING_LABEL")"
case "$OUT" in
  *"BD_CALL:-C /fake/city label remove ga-test waiting-on:pr-5393 -q"*)
    ok "close:merged clears waiting-on:pr-5393 too (same class of stale-label cleanup)" ;;
  *) bad "close:merged left the stale waiting-on:pr-5393 label behind. Output: $OUT" ;;
esac

echo "── 6. flag:closed-not-merged also clears waiting-on:pr-<N> ──"
OUT="$(run_snippet "flag:closed-not-merged" "$BEAD_WITH_MATCHING_LABEL")"
case "$OUT" in
  *"BD_CALL:-C /fake/city label remove ga-test waiting-on:pr-5393 -q"*)
    ok "flag:closed-not-merged clears waiting-on:pr-5393 too (same class of stale-label cleanup)" ;;
  *) bad "flag:closed-not-merged left the stale waiting-on:pr-5393 label behind. Output: $OUT" ;;
esac

echo "── 7. genuinely-still-waiting arms must NOT touch waiting-on:pr-<N> ──"
for action in "wait:pending" "wait:awaiting-rereview" "skip:indeterminate"; do
  OUT="$(run_snippet "$action" "$BEAD_WITH_MATCHING_LABEL")"
  case "$OUT" in
    *"BD_CALL:"*"label remove"*"waiting-on"*)
      bad "$action incorrectly removed a waiting-on label — the external wait is NOT over in this arm. Output: $OUT" ;;
    *) ok "$action correctly leaves waiting-on:pr-5393 alone (still genuinely waiting)" ;;
  esac
done

echo "── 8. sanity: quality-gate-guard.sh still parses cleanly ──"
if bash -n "$GUARD" 2>/dev/null; then
  ok "quality-gate-guard.sh parses cleanly (bash -n)"
else
  bad "quality-gate-guard.sh FAILED bash -n"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
