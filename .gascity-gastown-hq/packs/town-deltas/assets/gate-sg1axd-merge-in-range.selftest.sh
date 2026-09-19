#!/usr/bin/env bash
# gate-sg1axd-merge-in-range.selftest.sh — Prove the ga-sg1axd fix in
# isolation, with NO live Dolt/gc/launchd:
#
#   BUG (ga-sg1axd): wa-q0crq (P0) fell into gate-status:needs-rebase TWICE
#   (markers ga-ee8ki4, ga-hfijr6) even though `git merge-tree --write-tree
#   origin/main origin/crew/wa-worker/wa-q0crq` was CLEAN (zero CONFLICT).
#   The branch's real shape: a re-anchor merge commit (merge-last, city
#   recipe) + ONE ordinary commit on top (deploy_deps.json regenerated after
#   the merge, per doctrine). The old predicate, branch_tip_is_merge_commit(),
#   tested ONLY the branch's tip commit (`<ref>^2`) — since the tip here is
#   the ordinary commit, not the merge, it returned "0", so the gate routed
#   through `git rebase`, which does not replay merge commits at all and can
#   silently drop whatever that merge itself resolved.
#
#   FIX: branch_has_merge_in_range() replaces the tip-only test with a check
#   over the WHOLE upstream..branch interval (`git rev-list --merges -n1`),
#   so any branch carrying a merge commit not yet on the default branch — at
#   the tip or further back — routes to `git merge` instead of `git rebase`,
#   while a real linear branch is unaffected (AC3 non-regression), and the
#   pre-existing tip-is-merge case (ga-kyxih/ga-ffop9/ga-mmdm2) still returns
#   "1" exactly as before.
#
# This harness sources the dispatcher in lib-only mode to unit-test the REAL
# predicate against throwaway temp repos shaped like the actual incident,
# then DRIFT-GUARDS the live script so a future refactor can't silently
# revert to a tip-only check. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
hasF() { if grep -qF "$2" "$1"; then ok "$3"; else bad "$3 — string not found: $2"; fi; }

# ── Load the REAL predicate from the dispatcher (lib-only = no live run) ────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type branch_has_merge_in_range >/dev/null 2>&1 \
  || { echo "FATAL: branch_has_merge_in_range not defined by dispatcher (lib-only) — was it renamed again without updating this test?"; exit 1; }

# git_rig (the live wrapper) is defined AFTER the GATE_DISPATCHER_LIB_ONLY
# cutoff — it needs IS_CONTAINER_RIG/GIT_DIR_PATH, only resolved in a live
# run — so it does not exist here (same reason
# gate-branch-content-coherence.selftest.sh's own harness avoids relying on
# it). Shim a trivial pass-through against this test's own throwaway repo;
# the live call site's own git_rig wiring is untouched by this test.
git_rig() { git -C "$TESTREPO" "$@"; }

# Quiet logging from the sourced helpers during the test.
log()  { :; }
warn() { :; }
err()  { :; }

FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gate-sg1axd-selftest.XXXXXX")"
cleanup() { command -v safe-clean >/dev/null 2>&1 && safe-clean "$FIXTURE_ROOT" >/dev/null 2>&1 || rm -rf "$FIXTURE_ROOT"; }
trap cleanup EXIT

# ── 1. real-git: wa-q0crq's exact shape (merge NOT at the tip) ──────────────
echo "── 1. real-git: wa-q0crq's exact shape (merge commit further back, not at the tip) ──"

TESTREPO="$FIXTURE_ROOT/incident"
mkdir -p "$TESTREPO"
git -C "$TESTREPO" init -q -b main
git -C "$TESTREPO" config user.email "test@gascity.local"
git -C "$TESTREPO" config user.name "Test"

echo "base" > "$TESTREPO/f.txt"; git -C "$TESTREPO" add f.txt; git -C "$TESTREPO" commit -q -m "base"

git -C "$TESTREPO" checkout -q -b feature
echo "feature work" >> "$TESTREPO/f.txt"; git -C "$TESTREPO" commit -qam "fix(wa-q0crq): feature work"

git -C "$TESTREPO" checkout -q main
echo "main moved on" > "$TESTREPO/g.txt"; git -C "$TESTREPO" add g.txt; git -C "$TESTREPO" commit -q -m "unrelated main progress"
MAIN_TIP="$(git -C "$TESTREPO" rev-parse HEAD)"

# The re-anchor: author merges main into feature by hand (city recipe,
# merge-last), zero conflicts.
git -C "$TESTREPO" checkout -q feature
git -C "$TESTREPO" -c user.email="test@gascity.local" -c user.name="Test" merge -q main -m "Merge main into feature (re-anchor)"

# ...then ONE ordinary commit on top — deploy_deps.json regenerated after
# the merge, exactly like wa-q0crq's cc317800d.
echo "deploy_deps regenerated" > "$TESTREPO/deploy_deps.json"
git -C "$TESTREPO" add deploy_deps.json
git -C "$TESTREPO" commit -q -m "chore: regenerate deploy_deps.json"
FEATURE_TIP="$(git -C "$TESTREPO" rev-parse HEAD)"

# Sanity-check the bug report's own precondition: merge-tree between main
# and this branch really is clean (exit 0 = no conflict).
if git -C "$TESTREPO" merge-tree --write-tree "$MAIN_TIP" "$FEATURE_TIP" >/dev/null 2>&1; then
  ok "precondition: merge-tree(main, feature) is clean (zero CONFLICT), matching wa-q0crq"
else
  bad "precondition: merge-tree(main, feature) unexpectedly conflicted — fixture does not match the incident"
fi

# The bug, demonstrated directly: the OLD test (tip-only, \`^2\`) says "no"
# for this exact shape, because the tip is the plain deploy_deps commit, not
# the merge.
if git -C "$TESTREPO" rev-parse --verify -q "${FEATURE_TIP}^2" >/dev/null 2>&1; then
  bad "sanity: expected the branch TIP to NOT itself be a merge commit (fixture is wrong)"
else
  ok "sanity: branch tip is a plain commit — the old tip-only predicate returned \"0\" here (the bug)"
fi

eq "branch_has_merge_in_range: wa-q0crq shape (merge NOT at tip) -> 1" \
  "$(branch_has_merge_in_range "$FEATURE_TIP" "$MAIN_TIP")" "1"

rm -rf "$TESTREPO"

# ── 2. real-git: pre-existing tip-is-merge case (must still return 1) ───────
echo "── 2. real-git: pre-existing tip-is-merge case (ga-kyxih/ga-ffop9/ga-mmdm2) — must still return 1 ──"

TESTREPO="$FIXTURE_ROOT/tip-is-merge"
mkdir -p "$TESTREPO"
git -C "$TESTREPO" init -q -b main
git -C "$TESTREPO" config user.email "test@gascity.local"
git -C "$TESTREPO" config user.name "Test"

echo "base" > "$TESTREPO/f.txt"; git -C "$TESTREPO" add f.txt; git -C "$TESTREPO" commit -q -m "base"

git -C "$TESTREPO" checkout -q -b feature2
echo "feature work" >> "$TESTREPO/f.txt"; git -C "$TESTREPO" commit -qam "fix(ga-ffop9): feature work"

git -C "$TESTREPO" checkout -q main
echo "main moved on" > "$TESTREPO/g.txt"; git -C "$TESTREPO" add g.txt; git -C "$TESTREPO" commit -q -m "unrelated main progress"
MAIN_TIP2="$(git -C "$TESTREPO" rev-parse HEAD)"

git -C "$TESTREPO" checkout -q feature2
git -C "$TESTREPO" -c user.email="test@gascity.local" -c user.name="Test" merge -q main -m "Merge main into feature2 (tip is the merge itself)"
FEATURE2_TIP="$(git -C "$TESTREPO" rev-parse HEAD)"

if git -C "$TESTREPO" rev-parse --verify -q "${FEATURE2_TIP}^2" >/dev/null 2>&1; then
  ok "sanity: branch tip IS itself a merge commit — the predicate's original positive case"
else
  bad "sanity: expected the branch tip to be a merge commit (fixture is wrong)"
fi

eq "branch_has_merge_in_range: tip-is-merge (original ga-kyxih case) -> 1" \
  "$(branch_has_merge_in_range "$FEATURE2_TIP" "$MAIN_TIP2")" "1"

rm -rf "$TESTREPO"

# ── 3. real-git: plain linear branch (AC3 non-regression) ───────────────────
echo "── 3. real-git: plain linear multi-commit branch (AC3 non-regression) ──"

TESTREPO="$FIXTURE_ROOT/linear"
mkdir -p "$TESTREPO"
git -C "$TESTREPO" init -q -b main
git -C "$TESTREPO" config user.email "test@gascity.local"
git -C "$TESTREPO" config user.name "Test"

echo "base" > "$TESTREPO/f.txt"; git -C "$TESTREPO" add f.txt; git -C "$TESTREPO" commit -q -m "base"
MAIN_TIP3="$(git -C "$TESTREPO" rev-parse HEAD)"

git -C "$TESTREPO" checkout -q -b feature3
echo "l1" >> "$TESTREPO/f.txt"; git -C "$TESTREPO" commit -qam "fix(ga-xxxxx): step 1"
echo "l2" >> "$TESTREPO/f.txt"; git -C "$TESTREPO" commit -qam "fix(ga-xxxxx): step 2"
FEATURE3_TIP="$(git -C "$TESTREPO" rev-parse HEAD)"

eq "branch_has_merge_in_range: plain multi-commit linear branch -> 0 (unchanged)" \
  "$(branch_has_merge_in_range "$FEATURE3_TIP" "$MAIN_TIP3")" "0"

rm -rf "$TESTREPO"

# ── 4. fail-closed edge cases ────────────────────────────────────────────────
echo "── 4. fail-closed edge cases ──"
TESTREPO="$FIXTURE_ROOT/linear"  # unused by these calls; git_rig shim just needs a valid cwd
mkdir -p "$TESTREPO"
eq "empty branch_ref -> 0" "$(branch_has_merge_in_range "" "main")" "0"
eq "empty upstream_ref -> 0" "$(branch_has_merge_in_range "main" "")" "0"
eq "both empty -> 0" "$(branch_has_merge_in_range "" "")" "0"

# ── 5. DRIFT GUARD: call site passes an upstream ref, not just the branch ───
echo "── 5. drift guard: call site is wired for the interval check, not tip-only ──"
hasF "$DISPATCHER" 'BRANCH_HAS_MERGE_IN_RANGE=$(branch_has_merge_in_range "origin/$BRANCH" "origin/$DEFAULT_BRANCH")' \
  "call site passes BOTH branch and upstream (not the old single-arg tip-only call)"
hasF "$DISPATCHER" 'git_rig rev-list --merges -n1 "${upstream_ref}..${branch_ref}"' \
  "predicate body checks the whole interval via rev-list --merges, not a tip-only ^2 test"

# ── 6. DRIFT GUARD: no remaining reference to the retired tip-only predicate
echo "── 6. drift guard: no live call site or variable still uses the retired tip-only predicate ──"
OLD_CALLS=$(grep -c 'branch_tip_is_merge_commit()' "$DISPATCHER" || true)
eq "zero live definitions/calls of the retired branch_tip_is_merge_commit()" "${OLD_CALLS:-0}" "0"
OLD_VAR_USES=$(grep -c 'BRANCH_TIP_IS_MERGE_COMMIT' "$DISPATCHER" || true)
eq "zero remaining uses of the retired BRANCH_TIP_IS_MERGE_COMMIT variable" "${OLD_VAR_USES:-0}" "0"

# ── 7. DRIFT GUARD: helper defined before the lib-only cutoff (testable) ────
echo "── 7. drift guard: helper is selftest-sourceable (defined before lib-only guard) ──"
CUTOFF_LN=$(grep -n 'if \[ -n "\${GATE_DISPATCHER_LIB_ONLY:-}" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
DEF_LN=$(grep -n '^branch_has_merge_in_range() {' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$DEF_LN" ] && [ -n "$CUTOFF_LN" ] && [ "$DEF_LN" -lt "$CUTOFF_LN" ]; then
  ok "branch_has_merge_in_range (line $DEF_LN) defined before the lib-only cutoff (line $CUTOFF_LN)"
else
  bad "branch_has_merge_in_range must be defined before the GATE_DISPATCHER_LIB_ONLY cutoff (def=$DEF_LN cutoff=$CUTOFF_LN)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
