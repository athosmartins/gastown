#!/usr/bin/env bash
# gate-qukyp-merge-rebase-fallback.selftest.sh — ga-qukyp drift-guard.
#
# Bug: the gate's merge-time integration step (do_merge_ff in
# quality-gate-dispatcher.sh) rebases the branch onto origin/$DEFAULT_BRANCH
# before pushing. `git rebase` REPLAYS each commit as a flat patch against the
# new base. A branch containing its OWN prior re-anchor merge commit (a
# normal, recommended pattern — see gate-reanchor-merge-when-tip-is-merge-
# commit doctrine) can hit a REAL rebase conflict this way even though the
# two sides' FINAL TREES don't actually disagree — replay and 3-way-merge are
# different algorithms that can legitimately produce different answers for
# the same two endpoints. When this fires, an all-PASS-reviewed branch gets
# mislabeled gate:needs-human, looking like a quality rejection when the code
# was never in question.
#
# Measured live (ga-x3e7p, gate_run ga-pc0yz, 2026-08-10): branch tip
# b13428b6e6720c4020c22e836aefd99038674865, origin/main tip
# 06ab085eec47ec9e8a7d17702eaca2e632eece62 (2 commits ahead of the true
# merge-base, touching only an unrelated file). These exact SHAs are used
# below as a REAL fixture (not a synthetic repro — an earlier synthetic
# attempt with only ONE merge commit in the branch's history did NOT
# reproduce the bug, so a hand-built minimal case risks being unrepresentative;
# the real commits are permanently reachable, being ancestors of origin/main).
#
# Fix: when rebase fails but the merge-tree pre-check (rig_merge_has_conflict,
# already computed as MR_CONFLICT before the rebase attempt) says the two
# sides merge clean, fall back to an actual `git merge` — which validates
# against final tree state, not replayed patches — and push it as a genuine
# fast-forward of the branch ref (no force needed, since merge never rewrites
# existing commits).
#
# This harness (1) proves the rebase-vs-merge discrepancy is REAL using the
# actual incident's commits, (2) proves the fix's mechanism (merge succeeds
# where rebase fails) against those same commits, (3) drift-guards that the
# fallback code exists in the dispatcher and is correctly gated behind
# MR_CONFLICT=0, and (4) proves the REGRESSION case — a branch with a genuine
# content conflict — still fails, both at the merge-tree pre-check (which
# gates the fallback out) and at a real merge attempt. Exit 0 iff all hold.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

# Single combined cleanup — a second `trap ... EXIT` would silently REPLACE
# this one rather than add to it, leaking whichever resource the first trap
# was meant to remove. All temp resources below are cleaned from ONE handler.
RB_WT=""
CONFLICT_ROOT=""
cleanup() {
  [ -n "$RB_WT" ] && { git -C "$SELF_DIR" worktree remove --force "$RB_WT" >/dev/null 2>&1 || rm -rf "$RB_WT"; }
  [ -n "$CONFLICT_ROOT" ] && rm -rf "$CONFLICT_ROOT"
}
trap cleanup EXIT

echo "── gate merge-rebase-fallback drift-guard (ga-qukyp) ──"

REAL_TIP="b13428b6e6720c4020c22e836aefd99038674865"
REAL_MAIN="06ab085eec47ec9e8a7d17702eaca2e632eece62"

# Both fixture commits must actually be present (ancestors of origin/main by
# construction) before trusting any assertion below.
if ! git -C "$SELF_DIR" cat-file -e "$REAL_TIP" 2>/dev/null || \
   ! git -C "$SELF_DIR" cat-file -e "$REAL_MAIN" 2>/dev/null; then
  bad "fixture commits not reachable from this checkout — cannot run live git assertions (shallow clone or history rewritten?)"
  echo
  echo "── results: $PASS passed, $FAIL failed ──"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

# 1. Reproduce the bug: rebase-replay of the REAL branch tip onto the REAL
#    main-at-time-of-failure produces an actual conflict (proves this isn't
#    hypothetical). Run in an isolated worktree so this never touches the
#    caller's working tree, and always clean up.
RB_WT=$(mktemp -d)
if git -C "$SELF_DIR" worktree add -q --detach "$RB_WT" "$REAL_TIP" 2>/dev/null; then
  git -C "$RB_WT" -c user.email="selftest@local" -c user.name="selftest" \
    rebase "$REAL_MAIN" >/dev/null 2>&1
  rb_rc=$?
  git -C "$RB_WT" rebase --abort >/dev/null 2>&1 || true
  if [ "$rb_rc" -ne 0 ]; then
    ok "rebase-replay of the real branch tip onto the real main DOES conflict (rc=$rb_rc) — bug is real, not hypothetical"
  else
    bad "rebase-replay unexpectedly succeeded — fixture no longer reproduces the bug (main history rewritten since?)"
  fi
else
  bad "could not create worktree at $REAL_TIP — fixture unusable"
fi

# 2. Prove the discriminator the fix relies on: merge-tree (the SAME check
#    rig_merge_has_conflict uses) says this exact pair is clean.
git -C "$SELF_DIR" merge-tree --write-tree "$REAL_MAIN" "$REAL_TIP" >/dev/null 2>&1
mt_rc=$?
if [ "$mt_rc" -eq 0 ]; then
  ok "merge-tree pre-check says CLEAN for the same pair rebase conflicts on (rc=$mt_rc) — replay and final-state comparison genuinely disagree"
else
  bad "merge-tree pre-check says CONFLICT (rc=$mt_rc) — fixture does not demonstrate a discrepancy, MR_CONFLICT gate would correctly exclude this case anyway"
fi

# 3. Prove the fix's actual mechanism: a real `git merge` (not rebase) of the
#    same two endpoints succeeds cleanly — this is what the fallback code
#    does instead of giving up after the rebase failure in step 1.
MG_WT=$(mktemp -d)
if git -C "$SELF_DIR" worktree add -q --detach "$MG_WT" "$REAL_MAIN" 2>/dev/null; then
  git -C "$MG_WT" -c user.email="selftest@local" -c user.name="selftest" \
    merge --no-edit "$REAL_TIP" >/dev/null 2>&1
  mg_rc=$?
  if [ "$mg_rc" -eq 0 ]; then
    ok "real merge of the same two endpoints succeeds cleanly (rc=$mg_rc) — the fallback's mechanism works on the actual incident"
  else
    bad "real merge FAILED (rc=$mg_rc) — the fix's core assumption does not hold for this fixture"
  fi
  git -C "$SELF_DIR" worktree remove --force "$MG_WT" >/dev/null 2>&1 || rm -rf "$MG_WT"
else
  bad "could not create worktree at $REAL_MAIN — fixture unusable"
fi

# 4. Drift-guard: the fallback code must actually exist in the dispatcher,
#    gated on MR_CONFLICT (never attempted when a real conflict was already
#    detected), and must push the merge WITHOUT --force-with-lease (a merge
#    commit never rewrites the branch's existing commits, so a plain push is
#    both sufficient and strictly safer than force).
# grep -c already prints "0" (exit 1) on no-match — an `|| echo 0` fallback
# here would DOUBLE-print on that path ("0\n0"), breaking the -eq check below.
FALLBACK_COUNT=$(grep -c 'gate auto-merge fallback — rebase-replay failed despite zero merge-tree conflict, ga-qukyp' "$GATE" 2>/dev/null)
FALLBACK_COUNT=${FALLBACK_COUNT:-0}
if [ "$FALLBACK_COUNT" -eq 2 ]; then
  ok "merge fallback present at both call sites (container-rig + self-repo), $FALLBACK_COUNT occurrences"
else
  bad "expected merge fallback at exactly 2 call sites (container-rig + self-repo), found $FALLBACK_COUNT"
fi

# The push lives a few lines after the merge invocation (post-merge verdict
# check in between), not on the immediately next line — window wide enough to
# span that, matching the actual distance in the source (verified: 11 lines).
FALLBACK_BLOCK=$(grep -A15 'gate auto-merge fallback — rebase-replay failed despite zero merge-tree conflict, ga-qukyp' "$GATE" 2>/dev/null)
if printf '%s\n' "$FALLBACK_BLOCK" | grep -q 'push origin "HEAD:refs/heads/\$BRANCH" 2>/dev/null; then' \
   && ! printf '%s\n' "$FALLBACK_BLOCK" | grep -q -- '--force-with-lease'; then
  ok "merge fallback pushes the branch ref with a PLAIN push, no --force-with-lease anywhere in that block — correct, since merge never rewrites existing commits"
else
  bad "merge fallback's push does not match the expected plain (non-forced) form"
fi

MERGE_GATE_COUNT=$(grep -c 'if \[ "\$MR_CONFLICT" = "0" \] && git -C "\$TMP_MR_WT"' "$GATE" 2>/dev/null)
MERGE_GATE_COUNT=${MERGE_GATE_COUNT:-0}
if [ "$MERGE_GATE_COUNT" -eq 2 ]; then
  ok "merge fallback is gated on MR_CONFLICT=0 at both call sites — never attempted when the pre-check already found a real conflict"
else
  bad "expected the MR_CONFLICT=0 gate at exactly 2 call sites, found $MERGE_GATE_COUNT"
fi

# 5. REGRESSION GUARD (the acceptance criterion that actually protects the
#    check's value): a branch with a genuine SAME-LINE content conflict must
#    still fail, at BOTH the merge-tree pre-check (which gates the new
#    fallback out entirely — MR_CONFLICT stays 1, do_merge_ff never reaches
#    the merge fallback) and a real merge attempt (belt-and-suspenders — even
#    if something upstream mis-gated it, the merge itself would still fail).
CONFLICT_ROOT=$(mktemp -d)
(
  set -e
  cd "$CONFLICT_ROOT"
  git init -q -b main real.git
  cd real.git
  git config user.email "t@t.local"; git config user.name "t"
  printf 'line1\nline2\nline3\n' > shared.txt
  git add shared.txt && git commit -q -m "base"
  git checkout -q -b feature
  printf 'line1\nBRANCH-CHANGE\nline3\n' > shared.txt
  git commit -q -am "branch changes line2"
  git checkout -q main
  printf 'line1\nMAIN-CHANGE\nline3\n' > shared.txt
  git commit -q -am "main changes the SAME line2"
) >/dev/null 2>&1

if [ -d "$CONFLICT_ROOT/real.git" ]; then
  git -C "$CONFLICT_ROOT/real.git" merge-tree --write-tree main feature >/dev/null 2>&1
  conflict_mt_rc=$?
  if [ "$conflict_mt_rc" -ne 0 ]; then
    ok "regression guard: merge-tree correctly detects the genuine same-line conflict (rc=$conflict_mt_rc) — MR_CONFLICT would be 1, fallback never reached"
  else
    bad "regression guard: merge-tree did NOT detect a genuine same-line conflict — pre-check is not trustworthy, fallback gate would be unsafe"
  fi

  git -C "$CONFLICT_ROOT/real.git" -c user.email="t@t.local" -c user.name="t" \
    checkout -q main
  git -C "$CONFLICT_ROOT/real.git" -c user.email="t@t.local" -c user.name="t" \
    merge --no-edit feature >/dev/null 2>&1
  conflict_mg_rc=$?
  git -C "$CONFLICT_ROOT/real.git" merge --abort >/dev/null 2>&1 || true
  if [ "$conflict_mg_rc" -ne 0 ]; then
    ok "regression guard: a real merge attempt on the genuine conflict ALSO fails (rc=$conflict_mg_rc) — the fallback mechanism itself would not paper over a real conflict even if mis-gated"
  else
    bad "regression guard: real merge succeeded on what should be a genuine conflict — test fixture is broken"
  fi
else
  bad "regression-guard fixture repo failed to initialize"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
