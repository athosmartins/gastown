#!/usr/bin/env bash
# gate-dpnpu5-already-merged-collapse.selftest.sh — ga-dpnpu5 drift-guard.
#
# BUG (measured live, 2 same-day occurrences, 2026-09-16): do_merge_ff's
# "Merge-time rebase" step (the review->merge starvation-window handler —
# main moved between reviewers' PASS and push) unconditionally rebases the
# branch onto the fresh main whenever IS_ANC (is main an ancestor of the
# branch?) is "no". It never asks the OPPOSITE question first: is the
# branch's tip ALREADY an ancestor of the fresh main? That happens when an
# earlier attempt in the same run (or a concurrent process) already
# fast-forwarded this exact branch, and main has since moved further ahead
# on OTHER, unrelated commits — IS_ANC is then correctly "no" (the branch's
# stale ref doesn't contain those later commits) but there is nothing left
# to rebase or push.
#
# Rebasing anyway makes every replayed commit collapse to an empty patch
# (its content is already upstream): the range CUR_MAIN..NEW_TIP is empty,
# branch_bead_commit_verdict returns "skip", and ga-y9a1d's own collapse
# guard (added to catch a REAL rebase-drops-your-commits bug) can't tell
# this apart from that real bug — it refuses to push and degrades an
# all-PASS review to FAIL on work that had already landed.
#
# wa-epazz: FF-merged at 15:00:02 (sha=04cc723d0, confirmed ancestor of
# origin/main). A guard re-enqueued the marker anyway (saw no live
# companion session); the 2nd review passed at 1/1 verdicts; at 15:14:20
# main had moved to 9f3f467e3 (unrelated commits landed meanwhile); the
# merge-time rebase collapsed and refused to push at 15:14:25; overall
# verdict FAIL at 15:15:10. ga-mxcnwm: same shape, different trigger
# (reviewer timeout during a disk-saturation window, not a guard
# re-enqueue) — the underlying collapse-vs-already-merged ambiguity is
# identical.
#
# FIX: reuse gate_branch_already_merged (ga-88sl7's reusable predicate —
# the SAME is-ancestor-then-patch-id-fallback check Step 4b already uses
# to ask this exact question before review) at the IS_ANC-check point
# inside do_merge_ff, before the rebase attempt. On a hit: nothing to
# push, set MERGE_RESULT=already_merged (return 0, skipping the rebase and
# — via an extended guard — the post-push diff-integrity check, which
# would otherwise compare against a possibly-stale MAIN_HEAD_SHA baseline
# and risk a false integrity-fail that force-reverts main for content that
# never moved this run). On a miss (fail-closed, matches ga-88sl7's own
# contract): falls through to the existing rebase attempt exactly as
# before — this fix narrows a false-FAIL window, it does not touch the
# genuine-conflict or genuine-divergence paths at all.
#
# This harness (1) proves the underlying git mechanism — a rebase of an
# already-merged branch onto a further-advanced main really does collapse
# to zero unique commits — using a real, disposable git repo, not a
# hypothetical; (2) drift-guards that do_merge_ff's new short-circuit
# exists, is gated behind IS_ANC != yes, calls gate_branch_already_merged,
# and sets MERGE_SHA/MERGE_RESULT/return before the rebase attempt line;
# (3) drift-guards that the diff-integrity check's guard excludes
# already_merged; (4) regression guard — a genuinely diverged branch (real
# unique commit, not yet merged) must NOT trip the short-circuit, so the
# existing rebase path stays reachable for real work. Exit 0 iff all hold.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

echo "── 1. real-git mechanism: rebasing an already-merged branch onto an advanced main collapses to empty ──"

_FIXTURE_REPO="$(mktemp -d "${TMPDIR:-/tmp}/gc-gate-dpnpu5-fixture.XXXXXX")"
git -C "$_FIXTURE_REPO" init -q -b trunk
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" commit -q --allow-empty -m "root"

# Simulate the incident: "topic" gets its own real commit, then gets
# fast-forward merged into main (main == topic's tip at that instant).
# Main then moves further ahead on unrelated work. topic's ref itself
# never moves again — exactly like origin/$BRANCH after an earlier FF in
# the same dispatcher run.
git -C "$_FIXTURE_REPO" checkout -q -b topic
echo "the bead's actual fix" > "$_FIXTURE_REPO/fix.txt"
git -C "$_FIXTURE_REPO" add fix.txt
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" commit -q -m "wa-epazz: the real fix"
git -C "$_FIXTURE_REPO" branch main topic
git -C "$_FIXTURE_REPO" checkout -q main
for i in 1 2 3; do
  echo "unrelated commit $i" > "$_FIXTURE_REPO/unrelated-$i.txt"
  git -C "$_FIXTURE_REPO" add "unrelated-$i.txt"
  git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" commit -q -m "unrelated main commit $i (landed after topic's FF)"
done

# gate_branch_already_merged() always resolves "origin/$branch" /
# "origin/$default_branch" internally (it's built to run against a rig's
# real remote-tracking refs) — this fixture has no actual remote, so mint
# local branches literally named with an "origin/" prefix pointing at the
# same commits, the same trick gate-needs-rebase-terminality-reap's own
# fixture uses for the identical reason.
git -C "$_FIXTURE_REPO" branch origin/topic topic
git -C "$_FIXTURE_REPO" branch origin/main main

IS_ANC_TOPIC_HAS_MAIN=$(git -C "$_FIXTURE_REPO" merge-base --is-ancestor main topic 2>/dev/null && echo yes || echo no)
eq "premise: IS_ANC (is main an ancestor of topic?) is 'no' — topic's stale ref lacks the 3 unrelated commits, exactly what triggers the rebase block" \
  "$IS_ANC_TOPIC_HAS_MAIN" "no"

IS_TOPIC_ALREADY_IN_MAIN=$(git -C "$_FIXTURE_REPO" merge-base --is-ancestor topic main 2>/dev/null && echo yes || echo no)
eq "premise: topic's tip IS already an ancestor of main (the FF really landed it)" \
  "$IS_TOPIC_ALREADY_IN_MAIN" "yes"

git -C "$_FIXTURE_REPO" worktree add -q "$_FIXTURE_REPO/.wt-rebase" topic
if git -C "$_FIXTURE_REPO/.wt-rebase" -c user.email="t@t" -c user.name="t" rebase main >/dev/null 2>&1; then
  REBASE_RANGE_COUNT=$(git -C "$_FIXTURE_REPO/.wt-rebase" rev-list --count "main..HEAD" 2>/dev/null || echo "")
  eq "the OLD unconditional-rebase behavior: replaying topic onto main collapses to ZERO unique commits (this is what ga-y9a1d's guard then misreads as 'rebase dropped your commits')" \
    "$REBASE_RANGE_COUNT" "0"
else
  bad "rebase of already-merged topic onto main unexpectedly conflicted — fixture assumption broken"
fi
git -C "$_FIXTURE_REPO" worktree remove --force "$_FIXTURE_REPO/.wt-rebase" 2>/dev/null || true

echo "── 2. gate_branch_already_merged correctly catches this exact shape (reused predicate, not re-implemented) ──"

GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }
type gate_branch_already_merged >/dev/null 2>&1 \
  || { echo "FATAL: gate_branch_already_merged not defined (ga-88sl7 fix missing?)"; exit 1; }
log()  { :; }
warn() { :; }
err()  { :; }
git_rig() { git -C "$_FIXTURE_REPO" "$@"; }

eq "gate_branch_already_merged(topic, main) → 1 for the already-FF'd-but-main-moved-on shape (ga-dpnpu5's exact trigger)" \
  "$(gate_branch_already_merged "topic" "main")" "1"

unset -f git_rig
rm -rf "$_FIXTURE_REPO"

echo "── 3. drift-guard: do_merge_ff's short-circuit exists, is correctly placed and correctly gated ──"

# Must appear strictly between the IS_ANC assignment and the pre-existing
# "Main moved during review" rebase-attempt line — i.e. it runs BEFORE any
# rebase is attempted, not after (a fix placed after the rebase already ran
# would be too late: the false FAIL already happened by then).
AWK_SLICE=$(awk '
  /IS_ANC=\$\(git_rig merge-base --is-ancestor "origin\/\$DEFAULT_BRANCH" "origin\/\$BRANCH"/ { grab=1 }
  grab { print }
  /Main moved during review — attempt inline rebase before push/ { exit }
' "$DISPATCHER")

if printf '%s' "$AWK_SLICE" | grep -qF 'gate_branch_already_merged "$BRANCH" "$DEFAULT_BRANCH"'; then
  ok "do_merge_ff calls gate_branch_already_merged between the IS_ANC check and the rebase attempt"
else
  bad "gate_branch_already_merged call NOT found between IS_ANC and the rebase attempt (ga-dpnpu5 fix missing or misplaced)"
fi

if printf '%s' "$AWK_SLICE" | grep -qF 'MERGE_RESULT="already_merged"' \
  && printf '%s' "$AWK_SLICE" | grep -qF 'MERGE_SHA="$CUR_BRANCH"' \
  && printf '%s' "$AWK_SLICE" | grep -qF 'return 0'; then
  ok "the short-circuit sets MERGE_SHA, sets MERGE_RESULT=already_merged, and returns 0 (non-failure) before the rebase attempt"
else
  bad "short-circuit does not set the expected MERGE_SHA/MERGE_RESULT/return 0 triple"
fi

echo "── 4. drift-guard: post-push diff-integrity check excludes already_merged ──"

if grep -qF '[ "$MERGE_RESULT" != "already_merged" ]' "$DISPATCHER"; then
  ok "diff-integrity guard extended to skip MERGE_RESULT=already_merged (avoids a false integrity-fail / main-revert against a stale baseline)"
else
  bad "diff-integrity guard does NOT exclude already_merged — a superseded run could still trip the revert path"
fi

echo "── 5. regression guard: a genuinely diverged (not-yet-merged) branch must NOT trip the short-circuit ──"

_FIXTURE_REPO2="$(mktemp -d "${TMPDIR:-/tmp}/gc-gate-dpnpu5-regress.XXXXXX")"
git -C "$_FIXTURE_REPO2" init -q -b trunk
git -C "$_FIXTURE_REPO2" -c user.email="t@t" -c user.name="t" commit -q --allow-empty -m "root"
git -C "$_FIXTURE_REPO2" branch main
git -C "$_FIXTURE_REPO2" checkout -q -b topic-real-unmerged-work
echo "real unmerged work, not yet in main" > "$_FIXTURE_REPO2/pending.txt"
git -C "$_FIXTURE_REPO2" add pending.txt
git -C "$_FIXTURE_REPO2" -c user.email="t@t" -c user.name="t" commit -q -m "genuine unmerged fix"
git -C "$_FIXTURE_REPO2" checkout -q main
git -C "$_FIXTURE_REPO2" -c user.email="t@t" -c user.name="t" commit -q --allow-empty -m "main moved too (genuine divergence)"
git -C "$_FIXTURE_REPO2" branch origin/topic-real-unmerged-work topic-real-unmerged-work
git -C "$_FIXTURE_REPO2" branch origin/main main

git_rig() { git -C "$_FIXTURE_REPO2" "$@"; }
eq "gate_branch_already_merged(topic-real-unmerged-work, main) → 0 for a genuinely diverged branch — real work must still reach the rebase path, never get swallowed as 'already merged'" \
  "$(gate_branch_already_merged "topic-real-unmerged-work" "main")" "0"
unset -f git_rig
rm -rf "$_FIXTURE_REPO2"

# ── Summary ─────────────────────────────────────────────────────────────────
if [ "$FAIL" = "0" ]; then
  echo "PASS $PASS/$((PASS+FAIL)) — gate-dpnpu5-already-merged-collapse selftest"
  exit 0
else
  echo "FAIL $FAIL/$((PASS+FAIL)) — gate-dpnpu5-already-merged-collapse selftest"
  exit 1
fi
