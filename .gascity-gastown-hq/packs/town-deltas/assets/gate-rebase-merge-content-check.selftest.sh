#!/usr/bin/env bash
# gate-rebase-merge-content-check.selftest.sh — Drift-guard for ga-01yq.
#
# Bug: quality-gate-dispatcher.sh's Step 4b "Already-merged detection" used
# ONLY `git merge-base --is-ancestor origin/$BRANCH origin/$DEFAULT_BRANCH` to
# decide whether a branch's work is already in main. After a REBASE-MERGE
# (which is exactly what the gate's own auto-rebase step does — and what a
# manual "git rebase" does too), the branch's original commits get replayed
# onto main under NEW shas. The branch tip is then NEVER an ancestor of main
# again, even though 100% of its content already landed. The naive check
# misread this as "not merged", which (1) generates permanent needs-rebase
# noise for every branch the gate itself merges, and (2) the suggested
# remediation for a genuine needs-rebase ("manually rebase onto main, re-run
# /gate-done") would, if followed on a false positive, re-submit PRE-REBASE
# file versions on top of newer work already in main — a real regression, not
# just noise. Caught live by batista-wa (wa-jaxt8: e5b376ff -> 99fd153b, byte-
# identical content, byte-identical message) and reproduced by the Mayor on
# crew/peter/ga-fr5d before either branch was wrongly bounced/reworked.
#
# Fix: quality-gate-dispatcher.sh now falls back to a patch-id CONTENT check
# (rig_content_merged(), mirroring merged-bead-janitor.sh's proven
# content_in_main()) whenever the naive is-ancestor check says "not merged" —
# `git rev-list --count --cherry-pick --right-only <main>...<branch>` == 0
# means every branch commit's patch is already present in main under some
# (possibly different) sha, so the branch is merged-by-content. A non-zero
# count means real, unmerged work exists — the existing needs-rebase/bounce
# path is left completely unchanged for that case.
#
# This harness (1) reproduces the bug class with real throwaway git repos,
# proving the naive is-ancestor check really does misclassify a rebase-merged
# branch as unmerged, (2) proves the patch-id content check classifies both
# the merged-by-rebase case AND a genuinely-unmerged case correctly (the two
# acceptance directions from ga-01yq), (3) is itself the MUTATION TEST the bug
# demands: assertion §2 IS "revert the patch-id check to plain is-ancestor" —
# it directly shows that reverted state misclassifies case (1) as unmerged,
# and (4) drift-guards that the live dispatcher actually wires the content
# check into Step 4b, and that no remediation text anywhere in the file tells
# an author to run git operations in a rig's ROOT worktree (ga-01yq fix item
# 3 / acceptance criterion 4 — crew must always use their OWN clone/worktree).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "── gate rebase-merge content-check drift-guard (ga-01yq) ──"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gc-ga-01yq-selftest-XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

R="$WORK/repo"
git init --quiet "$R"
git -C "$R" config user.email "selftest@gascity.local"
git -C "$R" config user.name  "selftest"

( cd "$R" && echo base > base.txt && git add base.txt && git commit --quiet -m "base commit" )
git -C "$R" branch -M main

# ── Fixture 1: merged-by-rebase — a branch whose content is FULLY in main,
#    but whose tip is NOT an ancestor (the gate's own rebase-merge replayed it
#    under a new sha). This is the exact wa-jaxt8 shape: same diff, same
#    message, different sha. ─────────────────────────────────────────────────
git -C "$R" checkout --quiet -b topic-merged main
( cd "$R" && echo "topic feature" > feature.txt && git add feature.txt && git commit --quiet -m "feat: topic feature" )
git -C "$R" checkout --quiet main
( cd "$R" && echo "unrelated main progress" > progress.txt && git add progress.txt && git commit --quiet -m "chore: main moved on" )
# Replay topic-merged's commit onto main under a NEW sha (same diff, same
# message) — this is what a rebase-merge (or the gate's own auto-rebase)
# produces. `git cherry-pick` is the simplest faithful reproduction.
git -C "$R" cherry-pick --quiet topic-merged >/dev/null 2>&1

# ── Fixture 2: genuinely unmerged — a branch with UNIQUE content never
#    replayed onto main. Must NEVER be reported merged (acceptance dir. 2). ──
git -C "$R" checkout --quiet -b topic-unmerged main
( cd "$R" && echo "real unmerged work" > unmerged.txt && git add unmerged.txt && git commit --quiet -m "feat: real unmerged work" )
git -C "$R" checkout --quiet main

# ── 1. Reproduce: naive is-ancestor says topic-merged is NOT merged ─────────
if git -C "$R" merge-base --is-ancestor topic-merged main 2>/dev/null; then
  bad "fixture is broken: topic-merged unexpectedly IS an ancestor of main (cherry-pick landed as a fast-forward?)"
else
  ok "topic-merged tip is NOT an ancestor of main (rebase-merge changed the sha) — bug is reproducible"
fi

# ── 2. MUTATION TEST (ga-01yq acceptance criterion 3): the naive check IS the
#    "reverted" state. This assertion proves that if the patch-id fallback
#    were removed (reverting to is-ancestor / rev-list --count alone), case
#    (1) — a merged-by-rebase branch — would be misclassified as unmerged.
#    Same command class the bug report calls out as WRONG (rev-list --count /
#    is-ancestor measure sha reachability, not content). ─────────────────────
NAIVE_AHEAD="$(git -C "$R" rev-list --count main..topic-merged 2>/dev/null || echo ERR)"
if git -C "$R" merge-base --is-ancestor topic-merged main 2>/dev/null; then
  bad "MUTATION CHECK: naive is-ancestor unexpectedly says merged — fixture invalid, cannot prove the mutation matters"
elif [ "$NAIVE_AHEAD" != "0" ]; then
  ok "MUTATION CHECK: naive sha-reachability (rev-list --count / is-ancestor) says NOT merged (ahead=$NAIVE_AHEAD) on a fully-content-merged branch — confirms reverting the fix re-breaks case (1) VERMELHO"
else
  bad "MUTATION CHECK: naive rev-list --count reported 0 ahead — fixture invalid"
fi

# ── 3. Prove the fix: patch-id content check says topic-merged IS merged ───
CONTENT_MERGED_COUNT="$(git -C "$R" rev-list --count --cherry-pick --right-only main...topic-merged 2>/dev/null || echo ERR)"
if [ "$CONTENT_MERGED_COUNT" = "0" ]; then
  ok "patch-id content check (rev-list --cherry-pick --right-only) says topic-merged IS fully merged (count=0) — ga-01yq fix works for case 1"
else
  bad "patch-id content check did NOT recognize topic-merged as merged (count='$CONTENT_MERGED_COUNT') — fix broken"
fi

# ── 4. Negative direction (acceptance criterion 2): genuinely unmerged branch
#    must NEVER be reported merged, so real work still bounces to needs-rebase
#    exactly as before — no regression. ──────────────────────────────────────
CONTENT_UNMERGED_COUNT="$(git -C "$R" rev-list --count --cherry-pick --right-only main...topic-unmerged 2>/dev/null || echo ERR)"
if [ "$CONTENT_UNMERGED_COUNT" != "0" ] && [ "$CONTENT_UNMERGED_COUNT" != "ERR" ]; then
  ok "patch-id content check correctly says topic-unmerged is NOT merged (count=$CONTENT_UNMERGED_COUNT) — real work still flagged, no regression"
else
  bad "patch-id content check WRONGLY reported topic-unmerged as merged (count='$CONTENT_UNMERGED_COUNT') — would silently drop real work (DANGEROUS)"
fi

# ── 5. Drift-guard: the live dispatcher must actually wire rig_content_merged
#    into Step 4b (ALREADY_MERGED), as the fallback taken only when the naive
#    is-ancestor check fails. ────────────────────────────────────────────────
if [ -f "$GATE" ]; then
  if grep -q '^rig_content_merged()' "$GATE"; then
    ok "dispatcher defines rig_content_merged()"
  else
    bad "dispatcher is MISSING rig_content_merged() (ga-01yq regression)"
  fi

  # Scope the drift-guard to the DETECTION lines only (before the ALREADY_MERGED=1
  # if-block's messages), so it can't false-pass by matching this selftest's own
  # descriptive bead-comment text (which names the technique for human audit)
  # instead of the real code path.
  STEP4B_DETECT="$(awk '/Step 4b: Already-merged detection/{c=1} c{print} /^if \[ "\$ALREADY_MERGED" = "1" \]; then/{exit}' "$GATE" 2>/dev/null || true)"
  if printf '%s' "$STEP4B_DETECT" | grep -q 'elif rig_content_merged "origin/\$DEFAULT_BRANCH" "origin/\$BRANCH"; then'; then
    ok "Step 4b's detection calls rig_content_merged as a fallback when is-ancestor fails"
  else
    bad "Step 4b's detection does NOT call rig_content_merged — the naive is-ancestor check alone still governs ALREADY_MERGED (ga-01yq regression)"
  fi
else
  bad "quality-gate-dispatcher.sh not found next to selftest at $GATE"
fi

# ── 6. Regression guard (ga-01yq acceptance criterion 4): no remediation/
#    alert text anywhere in the dispatcher may instruct an author to run git
#    operations in a rig's ROOT worktree — crew must always use their OWN
#    clone/worktree (see crew-commit's Rig-Root Isolation Guard / pilot-
#    dispatcher.sh's worktree_directive_for()). Currently the file mentions no
#    filesystem path in its needs-rebase text at all; this permanently guards
#    against that changing without the isolation caveat. ────────────────────
if [ -f "$GATE" ]; then
  if grep -qi 'root worktree' "$GATE"; then
    bad "dispatcher mentions 'root worktree' somewhere — verify any such text points at the crew's OWN clone/worktree, never the shared rig root (ga-01yq acceptance criterion 4)"
  else
    ok "dispatcher's alert/remediation text does not mention a rig ROOT worktree (ga-01yq acceptance criterion 4)"
  fi
else
  bad "quality-gate-dispatcher.sh not found next to selftest at $GATE"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
