#!/usr/bin/env bash
# gate-guard-ga-bz4nsi-neverbranched.selftest.sh — Drift-guard for ga-bz4nsi.
#
# Bug (Mayor, 2026-08-21, wa-qfb6j P0): an OPEN story:in-flight bead with no
# gate:passed, no pilot:dispatched, no live assignee and NO fix/feature branch
# EVER created (the never-started shape) was unconditionally safe-skipped
# forever by the GAP-1 reconciler in quality-gate-guard.sh — permanently
# leaking its Pilot lane slot while staying invisible to every dispatch query.
# classify_inflight_gap1's own pure-function assertions for the new "none"
# input live in quality-gate-reconcile.selftest.sh (section 5b); THIS file
# covers the two supporting helpers ga-bz4nsi added, which classify_inflight_gap1
# alone can't exercise:
#
#   _gap1_city_ready_for_branch_check <city> — an empty branch search only
#     counts as evidence of "no branch" when git is actually usable for that
#     city (real work tree + resolvable origin remote). Verified live against
#     this city's own rig list (2026-08-22): some rig paths error "fatal: this
#     operation must be run in a work tree" on ANY git -C invocation, and
#     others are real work trees with no "origin" remote configured — both
#     make `git ls-remote origin <pattern>` return empty for reasons that have
#     NOTHING to do with whether a branch exists.
#
#   _gap1_ensure_lifecycle_backstop <city> <bead_id> — after a GAP-1 strip, a
#     feature left with zero lifecycle label is invisible to every
#     candidate query all over again. Must put it back in the funnel's INPUT
#     (story:triage) in exactly that case, and be a no-op otherwise. It must
#     NEVER write story:approved: only Athos approves (ga-1oibsf — the original
#     ga-bz4nsi stamp re-approved leaked Tier-1 chore/task and hand-parked beads).
#
# This harness (1) unit-tests both live functions (sourced via
# GATE_GUARD_LIB_ONLY=1, mirroring gate-guard-gap1-content-merge-check's
# pattern) against real throwaway git repos / a mock bd, and (2) drift-guards
# that the live GAP-1 loop actually wires the "no branch found" case through
# classify_inflight_gap1's "none" input (not a bare unconditional skip) and
# calls the backstop after both strip actions.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

echo "── gate-guard GAP-1 never-branched release drift-guard (ga-bz4nsi) ──"

if [ ! -f "$GUARD" ]; then
  bad "quality-gate-guard.sh not found next to selftest at $GUARD"
  echo
  echo "── results: $PASS passed, $FAIL failed ──"
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gc-ga-bz4nsi-selftest-XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# ── Fixtures for _gap1_city_ready_for_branch_check ───────────────────────────
# 1. A real work tree WITH a resolvable origin remote — the healthy case.
READY_REPO="$WORK/ready-repo"
git init --quiet "$READY_REPO"
git -C "$READY_REPO" config user.email "selftest@gascity.local"
git -C "$READY_REPO" config user.name  "selftest"
( cd "$READY_REPO" && echo base > base.txt && git add base.txt && git commit --quiet -m "base" )
# A local bare repo as the "origin" — get-url only needs the remote configured
# and resolvable, it never has to actually fetch.
ORIGIN_BARE="$WORK/origin-bare.git"
git init --quiet --bare "$ORIGIN_BARE"
git -C "$READY_REPO" remote add origin "$ORIGIN_BARE"

# 2. A plain directory that is NOT a git repo at all — mirrors the
#    "fatal: this operation must be run in a work tree" rig shape.
NOTAREPO="$WORK/not-a-repo"
mkdir -p "$NOTAREPO"

# 3. A real work tree with NO origin remote configured — mirrors the
#    "real repo, wrong/missing remote name" rig shape.
NOORIGIN_REPO="$WORK/no-origin-repo"
git init --quiet "$NOORIGIN_REPO"
git -C "$NOORIGIN_REPO" config user.email "selftest@gascity.local"
git -C "$NOORIGIN_REPO" config user.name  "selftest"
( cd "$NOORIGIN_REPO" && echo base > base.txt && git add base.txt && git commit --quiet -m "base" )

# ── Source the guard in lib-only mode (no I/O, no main loop) ────────────────
# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # the guard sources with set -euo pipefail; this harness counts its own pass/fail

type _gap1_city_ready_for_branch_check >/dev/null 2>&1 || { echo "FATAL: _gap1_city_ready_for_branch_check not defined by guard (ga-bz4nsi)"; exit 1; }
type _gap1_ensure_lifecycle_backstop   >/dev/null 2>&1 || { echo "FATAL: _gap1_ensure_lifecycle_backstop not defined by guard (ga-bz4nsi)"; exit 1; }
type classify_inflight_gap1            >/dev/null 2>&1 || { echo "FATAL: classify_inflight_gap1 not defined by guard"; exit 1; }

echo "── 1. _gap1_city_ready_for_branch_check ──"
if _gap1_city_ready_for_branch_check "$READY_REPO"; then
  ok "real work tree + resolvable origin → ready (safe to trust an empty branch search)"
else
  bad "real work tree + resolvable origin was wrongly reported NOT ready"
fi

if _gap1_city_ready_for_branch_check "$NOTAREPO"; then
  bad "a plain non-git directory was wrongly reported ready — would trust a false 'no branch' from a broken git checkout"
else
  ok "not a git work tree at all → not ready (matches the 'fatal: not a work tree' rig shape)"
fi

if _gap1_city_ready_for_branch_check "$NOORIGIN_REPO"; then
  bad "a work tree with no origin remote was wrongly reported ready — ls-remote origin would fail for a reason unrelated to branch existence"
else
  ok "real work tree but no origin remote → not ready (matches the 'no such remote origin' rig shape)"
fi

echo "── 2. _gap1_ensure_lifecycle_backstop (mock bd) ──"
# One mock bd for every case below. _MOCK_SHOW_MODE picks what `bd show` answers:
#   ok        → a bead of type $_MOCK_TYPE carrying $_MOCK_LABELS
#   empty     → nothing at all, rc=1 (Dolt hiccup / unreadable bead)
#   garbage   → rc=0 but not JSON
#   badlabels → valid JSON whose "labels" is not an array (the labels cannot be read)
_MOCK_TYPE=""
_MOCK_LABELS=""
_MOCK_SHOW_MODE="ok"
_MOCK_LABEL_ADD_LOG=""
_MOCK_UPDATE_LOG=""
_MOCK_COMMENT_LOG=""
_ALL_LABEL_ADDS=""   # every label any scenario below wrote, for the class assertion at the end
bd() {
  local verb="$3"
  case "$verb" in
    show)
      case "$_MOCK_SHOW_MODE" in
        empty)     printf ''; return 1 ;;
        garbage)   printf 'not json at all'; return 0 ;;
        badlabels) printf '[{"issue_type":"%s","labels":"oops-not-an-array"}]' "$_MOCK_TYPE"; return 0 ;;
      esac
      local arr="" l
      for l in $_MOCK_LABELS; do arr="${arr}\"$l\","; done
      printf '[{"issue_type":"%s","labels":[%s]}]' "$_MOCK_TYPE" "${arr%,}"
      return 0 ;;
    label)
      local op="$4" lbl="$6"
      [ "$op" = "add" ] && _MOCK_LABEL_ADD_LOG="$_MOCK_LABEL_ADD_LOG $lbl"
      return 0 ;;
    update)  _MOCK_UPDATE_LOG="$_MOCK_UPDATE_LOG [$*]"; return 0 ;;
    comment) _MOCK_COMMENT_LOG="$_MOCK_COMMENT_LOG [$5]"; return 0 ;;
  esac
  return 0
}

# backstop_case <issue_type> <space-separated labels> [show-mode]
# Runs the real backstop against the mock; the city path is a placeholder (the backstop no longer maps a city to a pool).
backstop_case() {
  _MOCK_TYPE="$1"; _MOCK_LABELS="$2"; _MOCK_SHOW_MODE="${3:-ok}"
  _MOCK_LABEL_ADD_LOG=""; _MOCK_UPDATE_LOG=""; _MOCK_COMMENT_LOG=""
  _gap1_ensure_lifecycle_backstop /tmp/fake-city fake-bead >/dev/null 2>&1
  _ALL_LABEL_ADDS="$_ALL_LABEL_ADDS $_MOCK_LABEL_ADD_LOG"
}
# expect_untouched <what>: the backstop wrote nothing — no label, no metadata
expect_untouched() {
  if [ -z "$_MOCK_LABEL_ADD_LOG" ] && [ -z "$_MOCK_UPDATE_LOG" ]; then
    ok "$1: backstop leaves the bead untouched"
  else
    bad "$1: backstop wrote labels [$_MOCK_LABEL_ADD_LOG ] / updates [$_MOCK_UPDATE_LOG ] on a bead it must not touch"
  fi
}

# Types that never go through the refino funnel. Pilot Tier 1 dispatches bug/chore/task with NO
# approval (ga-ciyypt), so a stamp on them is both unnecessary and a forged approval.
for _t in bug chore task; do
  backstop_case "$_t" ""
  expect_untouched "type=$_t with no lifecycle label (Tier 1 dispatches it unapproved)"
done

# ga-bz4nsi third-state guard: a read that fails or cannot be parsed must NOT collapse into
# "read fine, nothing to approve" — and must not stamp anything either. Inert on every unreadable shape.
backstop_case feature "" empty
expect_untouched "bd show returned nothing (Dolt hiccup)"
backstop_case feature "" garbage
expect_untouched "bd show returned non-JSON"
backstop_case feature "" badlabels
expect_untouched "bd show OK but labels field unreadable (labels is not an array) — 'could not read the labels' must not equal 'has no labels'"

backstop_case feature "tech-debt"
expect_untouched "tech-debt-labeled feature"

# The bug itself (ga-1oibsf): a feature left with NO lifecycle label used to get story:approved,
# i.e. "Athos approved this". Nobody did. It goes back to Triagem (story:triage, the refino daemon's
# input — never dispatched by the Pilot), which makes it visible again without approving anything.
backstop_case feature "ctx:ready exec:auto"
if [ "$_MOCK_LABEL_ADD_LOG" = " story:triage" ]; then
  ok "type=feature with no lifecycle label: stamped story:triage and nothing else"
else
  bad "type=feature with no lifecycle label: expected exactly ' story:triage', got [$_MOCK_LABEL_ADD_LOG ] (REGRESSION ga-1oibsf if it says story:approved: a forged Athos approval)"
fi
# type=story is refino raw material by the ABSENCE of any story:* label (auto-refino-dispatcher's RAW
# path), while its explicit story:triage query is `--type feature` only. Stamping story:triage on a
# story-typed bead would take it out of BOTH paths — a new invisible limbo — so it is left alone.
backstop_case story "ctx:ready exec:auto"
expect_untouched "type=story (raw ingest already covers it; story:triage would hide it from the --type feature query)"

# The route backfill + needs-human flag existed only because of the story:approved stamp (a bead
# approved with no gc.routed_to is invisible to the Pilot). A Triagem stamp needs no route, so the
# backstop must not write metadata nor flag needs-human — even in a city that maps to no pool.
backstop_case feature ""
if [ -z "$_MOCK_UPDATE_LOG" ] && ! printf '%s\n' $_MOCK_LABEL_ADD_LOG | grep -qx 'needs-human'; then
  ok "story:triage stamp writes no gc.routed_to and flags no needs-human (the route backfill belonged to the approved stamp)"
else
  bad "story:triage stamp still did route/needs-human work: updates [$_MOCK_UPDATE_LOG ] labels [$_MOCK_LABEL_ADD_LOG ]"
fi
case "$_MOCK_COMMENT_LOG" in
  *story:triage*) ok "the audit comment names the label actually written (story:triage)" ;;
  *)              bad "the audit comment does not mention story:triage: [$_MOCK_COMMENT_LOG ]" ;;
esac
case "$_MOCK_COMMENT_LOG" in
  *"stamped story:approved"*) bad "the audit comment still claims 'stamped story:approved' while the code writes story:triage: [$_MOCK_COMMENT_LOG ]" ;;
  *) ok "the audit comment does not claim an approval it did not write" ;;
esac

# Only a type that can actually enter the funnel gets a stamp. Unknown/odd type → inert, not "stamp anyway".
backstop_case epic ""
expect_untouched "type=epic (never dispatched, not a refino input)"
backstop_case "" ""
expect_untouched "issue_type missing from a readable bead (type unknown ≠ feature)"
backstop_case decision ""
expect_untouched "type=decision (not a funnel type)"

# A bead already wearing ANY pipeline label has a place in the pipeline. Stamping anything over
# story:refino-review / story:needs-approval would skip the review gate and Athos's own approval, and
# stamping story:triage on a delivered bead would re-ingest finished work (ga-bt1hjs). Mirrors the refino
# daemon's own "past/inside the pipeline" skip list: any story:*, gate:* or delivery:* label plus its markers.
for _l in story:approved story:triage story:unrefined story:refinement-in-progress story:refino-review \
          story:refino-escalado story:needs-approval story:in-flight story:done story:cancelled \
          gate:passed gate:reviewing gate:needs-fix delivery:partial delivery:merged \
          auto-refino:refining auto-refino:escalated refino-gate:reviewing; do
  backstop_case feature "$_l"
  expect_untouched "feature already carrying $_l"
done

# A bead someone deliberately holds (Athos parked it by hand, a gate withdrew it, it waits on a
# decision or a dependency) must stay held — the in-flight strip frees the lane, nothing more.
# Every label here is one the town already treats as a hold: context_check_is_parked (the canonical
# consumer) plus the Pilot's own dispatch vetoes (_filter_label_vetoes, exec:manual, _pilot_hold_or_escalate).
for _l in story:blocked story:needs-human needs-human needs-human:x needs-human-decision \
          pilot:no-auto-dispatch no-auto-dispatch pilot:held pilot:held-until:1790000000 \
          pool:refused:no-scope pilot:refused-reason:x needs:engine-window \
          blocked:needs-remeasure blocked-on:ga-x1 depends-on:ga-x1 waiting-on:ga-x1 \
          gate:needs-human gate:needs-human:technical gate:needs-human:partial-delivery gate:withdraw gate:withdraw:x \
          exec:manual next-action:mayor next-action:athos next-action:revisar \
          next-action:mayor-constroi next-action:crew-corrige-gate next-action:crew-corrige; do
  backstop_case feature "$_l"
  expect_untouched "feature parked by $_l"
done
backstop_case feature "ctx:ready story:blocked"
expect_untouched "feature with a park label next to unrelated labels"

# Labels that are NOT holds must not stop the stamp: lane:* / ctx:ready are what the Pilot itself writes.
# (next-action:*constroi|*corrige are holds HERE even though the Pilot's own veto lets them through: refino,
# which consumes story:triage, drops every next-action:*, so the backstop must not force them into its queue.)
backstop_case feature "lane:small ctx:ready"
if [ "$_MOCK_LABEL_ADD_LOG" = " story:triage" ]; then
  ok "lane:small ctx:ready are not holds: the story:triage stamp still happens"
else
  bad "lane:small ctx:ready wrongly treated as a hold or mis-stamped: [$_MOCK_LABEL_ADD_LOG ]"
fi

# THE CLASS (ga-1oibsf): across every scenario above, the reconciler never wrote story:approved.
# Only Athos approves (auto-refino-dispatcher.sh header); a reconciler that stamps it forges that.
if printf '%s\n' $_ALL_LABEL_ADDS | grep -qx 'story:approved'; then
  bad "REGRESSION ga-1oibsf: the backstop wrote story:approved in at least one scenario — a forged Athos approval"
else
  ok "class: across all $(printf '%s\n' $_ALL_LABEL_ADDS | grep -c .) label write(s) in this section, story:approved was never written"
fi
unset -f bd

echo "── 2b. gap1_backstop_action (pure decision) ──"
if type gap1_backstop_action >/dev/null 2>&1; then
  eq "feature, no labels"                   "$(gap1_backstop_action feature '')"                     "stamp:triage"
  eq "story-typed (raw ingest owns it)"     "$(gap1_backstop_action story 'ctx:ready exec:auto')"    "skip:type-story"
  eq "feature with a lane label"            "$(gap1_backstop_action feature 'lane:small')"           "stamp:triage"
  eq "bug"                                  "$(gap1_backstop_action bug '')"                         "skip:type-exempt"
  eq "chore"                                "$(gap1_backstop_action chore '')"                       "skip:type-exempt"
  eq "task"                                 "$(gap1_backstop_action task '')"                        "skip:type-exempt"
  eq "chore wearing a park label (type decides first)" "$(gap1_backstop_action chore 'story:blocked')" "skip:type-exempt"
  eq "feature tech-debt"                    "$(gap1_backstop_action feature 'tech-debt')"            "skip:tech-debt"
  eq "epic"                                 "$(gap1_backstop_action epic '')"                        "skip:type-not-funnel"
  eq "unknown (empty) type"                 "$(gap1_backstop_action '' '')"                          "skip:type-not-funnel"
  eq "feature parked by story:blocked"      "$(gap1_backstop_action feature 'story:blocked')"        "skip:parked"
  eq "feature parked by next-action:mayor"  "$(gap1_backstop_action feature 'next-action:mayor')"    "skip:parked"
  eq "feature parked by gate:needs-human:technical" "$(gap1_backstop_action feature 'gate:needs-human:technical')" "skip:parked"
  eq "feature already story:approved"       "$(gap1_backstop_action feature 'story:approved')"       "skip:has-lifecycle"
  eq "feature in story:refino-review"       "$(gap1_backstop_action feature 'story:refino-review')"  "skip:has-lifecycle"
  eq "feature in story:needs-approval"      "$(gap1_backstop_action feature 'story:needs-approval')" "skip:has-lifecycle"
  eq "feature delivered (delivery:merged)"  "$(gap1_backstop_action feature 'delivery:merged')"      "skip:has-lifecycle"
  eq "feature with next-action:*-constroi (refino drops it)" "$(gap1_backstop_action feature 'next-action:mayor-constroi')" "skip:parked"
  eq "feature held by pilot:held-until:N"   "$(gap1_backstop_action feature 'pilot:held-until:1790000000')" "skip:parked"
  eq "feature with only lane/ctx labels"    "$(gap1_backstop_action feature 'lane:small ctx:ready')" "stamp:triage"
  eq "park beats lifecycle (story:approved + story:blocked)" "$(gap1_backstop_action feature 'story:approved story:blocked')" "skip:parked"
else
  bad "gap1_backstop_action is not defined by the guard (ga-1oibsf)"
fi

echo "── 3. drift-guard: GAP-1 loop actually wires the new case in, not a bare skip ──"
# ga-8upzkk: the call sites no longer name classify_inflight_gap1 directly —
# they decide through gap1_never_branched_action, which feeds the classifier
# branch_merged=none (the never-branched input) in each of its owner outcomes.
# Assert BOTH halves so the wiring cannot be cut at either joint.
if grep -Fq 'continue' "$GUARD" \
   && grep -Fq 'gap1_never_branched_action "$OI_SHOW" "$SESSION_JSON"' "$GUARD" \
   && grep -Fq 'classify_inflight_gap1 open 0 0 none' "$GUARD"; then
  ok "GAP-1's 'no branch found' path calls classify_inflight_gap1 with branch_merged=none (via gap1_never_branched_action, ga-8upzkk)"
else
  bad "GAP-1's 'no branch found' path does NOT call classify_inflight_gap1(...,\"none\") — regression to the old unconditional safe-skip (ga-bz4nsi)"
fi

if grep -Fq 'strip:no-branch)' "$GUARD"; then
  ok "GAP-1 loop has a case arm handling strip:no-branch"
else
  bad "GAP-1 loop is missing a case arm for strip:no-branch — classify_inflight_gap1 can return it but nothing acts on it"
fi

if grep -Fq '_gap1_city_ready_for_branch_check "$GC_CITY"' "$GUARD"; then
  ok "GAP-1 loop gates the never-branched release on git-readiness for the city, not a bare empty-search result"
else
  bad "GAP-1 loop does NOT check _gap1_city_ready_for_branch_check before trusting an empty branch search — a broken git checkout could masquerade as 'no branch' (ga-bz4nsi)"
fi

_BACKSTOP_CALLS=$(grep -c '_gap1_ensure_lifecycle_backstop "\$GC_CITY" "\$OI_ID"' "$GUARD")
if [ "$_BACKSTOP_CALLS" -ge 2 ]; then
  ok "lifecycle backstop is called after BOTH GAP-1 strip actions (strip:merged and strip:no-branch), found $_BACKSTOP_CALLS call site(s)"
else
  bad "lifecycle backstop is called after fewer than 2 strip actions (found $_BACKSTOP_CALLS) — at least one GAP-1 release path can still leave a bead with zero dispatchable lifecycle label"
fi

# ga-1oibsf: the guard runs under `set -e`. The backstop returns 1 when it cannot read the bead (its
# third-state guard), and `raw=$(bd ... show)` itself exits non-zero on a Dolt hiccup — called BARE, either
# one kills the whole guard mid-sweep instead of staying inert. Every call site must absorb it with `|| true`
# (inside a `||` list errexit is off for the whole function body, so the rest of the sweep carries on).
_BACKSTOP_ALL=$(grep -c '^ *_gap1_ensure_lifecycle_backstop "' "$GUARD")
_BACKSTOP_SAFE=$(grep -c '^ *_gap1_ensure_lifecycle_backstop "[^"]*" "[^"]*" || true$' "$GUARD")
if [ "$_BACKSTOP_ALL" -ge 2 ] && [ "$_BACKSTOP_ALL" = "$_BACKSTOP_SAFE" ]; then
  ok "every backstop call site ($_BACKSTOP_ALL) ends in '|| true' — an unreadable bead cannot abort the guard under set -e"
else
  bad "$_BACKSTOP_SAFE of $_BACKSTOP_ALL backstop call sites end in '|| true' — a bd show hiccup would abort the whole guard under set -e (ga-1oibsf)"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
