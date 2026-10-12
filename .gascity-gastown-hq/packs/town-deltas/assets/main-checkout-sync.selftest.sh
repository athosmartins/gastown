#!/usr/bin/env bash
# main-checkout-sync.selftest.sh — prove the ga-7wtwvx fix in isolation, with NO live Dolt/gc/launchd,
# NO network, and real git on throwaway repos.
#
# Bug ga-7wtwvx: a container rig is a bare .repo.git with linked worktrees; `refinery/rig` has `main`
# checked out. The gate advances the bare `main` with `git update-ref refs/heads/main <sha>` (plumbing),
# which moves the branch a worktree's HEAD points at but NOT that worktree's index or files. HEAD runs
# ahead, the index stays on the old snapshot, and `git status` shows the whole delta as staged
# "reverts" — property_scrapers sat 121 commits behind (105 files) since 04/09, one `git commit -a`
# away from reverting them all.
#
# Fix: main-checkout-sync.sh, called from the dispatcher's Step 0a-3 loop for every container rig,
# compares each worktree's index tree with HEAD's tree and brings a STALE SNAPSHOT (index == the tree
# of an earlier commit of main's own history, files clean, nothing in progress) back to HEAD with a
# two-way `git read-tree -m -u`. Anything it cannot prove safe — staged work that matches no snapshot,
# unstaged edits, an operation in progress, a git call that failed — is reported as attention:<kind>
# and left exactly as it was.
#
# This harness: (1) reproduces the bug (the negative control commits the stale index and shows the
# revert), (2) runs the script over every state, (3) DRIFT-GUARDS the dispatcher wiring.
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
SCRIPT="$SELF_DIR/main-checkout-sync.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$2] unexpectedly contains [$3]" ;; *) ok "$1" ;; esac; }

[ -x "$SCRIPT" ] || { echo "FATAL: $SCRIPT missing or not executable"; exit 1; }

export GIT_AUTHOR_NAME=selftest  GIT_AUTHOR_EMAIL=selftest@local
export GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@local

T="$(mktemp -d 2>/dev/null || mktemp -d -t gartmcs)"
T="$(cd "$T" && pwd -P)"   # git prints realpaths (macOS /var → /private/var); compare like with like
cleanup() { rm -rf "$T" 2>/dev/null || true; }
trap cleanup EXIT

# mkfix <name> → $T/<name>/{seed,bare.git,wt}. bare main = C2, wt has main checked out but its index and
# files are still C1 — exactly what `git update-ref` leaves behind. C1: a.txt d.txt sub/s.txt.
# C2: a.txt changed, b.txt added, d.txt deleted.
mkfix() {
  local d="$T/$1"
  mkdir -p "$d"
  git init -q -b main "$d/seed"
  ( cd "$d/seed"
    echo one > a.txt; echo keep > d.txt; mkdir sub; echo s > sub/s.txt
    git add -A; git commit -q -m C1 )
  git init -q --bare -b main "$d/bare.git"
  git -C "$d/seed" push -q "$d/bare.git" main
  git --git-dir="$d/bare.git" worktree add -q "$d/wt" main
  ( cd "$d/seed"; echo two > a.txt; echo new > b.txt; git rm -q d.txt; git add -A; git commit -q -m C2 )
  git --git-dir="$d/bare.git" fetch -q "$d/seed" main:refs/tmp/c2
  git --git-dir="$d/bare.git" update-ref refs/heads/main "$(git --git-dir="$d/bare.git" rev-parse refs/tmp/c2)"
}
tree_of() { git -C "$1" rev-parse "$2^{tree}"; }
idx_tree() { git -C "$1" write-tree; }
staged_n() { git -C "$1" diff --cached --name-only | wc -l | tr -d ' '; }

# run_mcs <bare> [VAR=val ...] → OUT RC. Defaults: grace 0 (fixtures are brand new), throwaway state dir.
run_mcs() {
  local bare="$1"; shift
  OUT=""; RC=0
  OUT=$(env MCS_STATE_DIR="$T/state" MCS_GRACE_SECS=0 "$@" bash "$SCRIPT" "$bare" main 2>&1) || RC=$?
}

# ── 1. the bug, reproduced: update-ref leaves HEAD ahead of the index ──────────────────────────
echo "── 1. negative control: the stale index is a loaded revert ──"
mkfix ctl
CTL="$T/ctl/wt"
C1_TREE=$(tree_of "$CTL" "main~1"); C2_TREE=$(tree_of "$CTL" main)
eq "HEAD moved to C2 under the worktree"               "$(tree_of "$CTL" HEAD)" "$C2_TREE"
eq "…but the index is still C1's tree"                 "$(idx_tree "$CTL")"     "$C1_TREE"
[ "$(staged_n "$CTL")" -ge 3 ] && ok "git status shows the delta as staged changes ($(staged_n "$CTL") paths)" \
                                || bad "expected staged 'reverts', got $(staged_n "$CTL") paths"
git -C "$CTL" commit -qam "agent commits what is staged"
eq "a plain commit -a lands C1's tree again (the revert)" "$(tree_of "$CTL" HEAD)" "$C1_TREE"
git -C "$CTL" cat-file -e HEAD:b.txt 2>/dev/null && bad "b.txt survived (control did not reproduce)" || ok "…and b.txt (added by C2) is gone from the commit"

# ── 2. the heal ───────────────────────────────────────────────────────────────────────────────
echo "── 2. stale snapshot → healed ──"
mkfix heal
H="$T/heal"
HEAD_BEFORE=$(git -C "$H/wt" rev-parse HEAD)
# GIT_DIR / GIT_INDEX_FILE exported by the caller must not leak into the worktree's git calls.
run_mcs "$H/bare.git" GIT_DIR="$T/nowhere" GIT_INDEX_FILE="$T/nowhere/index"
eq   "exit 0 after a heal"                              "$RC" "0"
has  "prints healed + the worktree path"                "$OUT" "healed $H/wt"
eq   "index == HEAD tree"                               "$(idx_tree "$H/wt")" "$(tree_of "$H/wt" HEAD)"
eq   "git status is clean"                              "$(git -C "$H/wt" status --porcelain)" ""
eq   "a.txt follows C2"                                 "$(cat "$H/wt/a.txt")" "two"
[ -f "$H/wt/b.txt" ] && ok "b.txt (added by C2) is on disk" || bad "b.txt missing after heal"
[ ! -e "$H/wt/d.txt" ] && ok "d.txt (deleted by C2) is gone" || bad "d.txt still on disk after heal"
eq   "HEAD did not move"                                "$(git -C "$H/wt" rev-parse HEAD)" "$HEAD_BEFORE"
run_mcs "$H/bare.git"
eq   "second run: silent"                               "$OUT" ""
eq   "second run: exit 0"                               "$RC" "0"

echo "── 2b. dry run reports and touches nothing ──"
mkfix dry
run_mcs "$T/dry/bare.git" MCS_DRY_RUN=1
has  "would-heal reported"                              "$OUT" "would-heal $T/dry/wt"
eq   "exit 2 (something needs doing)"                   "$RC" "2"
eq   "index untouched"                                  "$(idx_tree "$T/dry/wt")" "$(tree_of "$T/dry/wt" main~1)"

# ── 3. everything that is not provably a stale snapshot is left alone ────────────────────────────
echo "── 3. unstaged edit on a stale index → attention:stale-dirty, nothing touched ──"
mkfix dirty
echo "my edit" > "$T/dirty/wt/a.txt"
run_mcs "$T/dirty/bare.git"
has  "attention:stale-dirty"                            "$OUT" "attention:stale-dirty $T/dirty/wt"
eq   "exit 2"                                           "$RC" "2"
eq   "the edit is still on disk"                        "$(cat "$T/dirty/wt/a.txt")" "my edit"
eq   "index still C1"                                   "$(idx_tree "$T/dirty/wt")" "$(tree_of "$T/dirty/wt" main~1)"

echo "── 4. staged work matching no snapshot → attention:diverged, nothing touched ──"
mkfix div
echo x > "$T/div/wt/staged.txt"; git -C "$T/div/wt" add staged.txt
DIV_IDX=$(idx_tree "$T/div/wt")
run_mcs "$T/div/bare.git"
has  "attention:diverged"                               "$OUT" "attention:diverged $T/div/wt"
has  "says it was NOT healed"                           "$OUT" "NOT healed"
eq   "exit 2"                                           "$RC" "2"
eq   "index unchanged"                                  "$(idx_tree "$T/div/wt")" "$DIV_IDX"
git -C "$T/div/wt" diff --cached --name-only | grep -qx staged.txt && ok "staged.txt is still staged" || bad "staged.txt lost"
run_mcs "$T/div/bare.git"
eq   "same state again within the repeat window: line throttled" "$OUT" ""
eq   "…but the exit code still says attention"          "$RC" "2"
run_mcs "$T/div/bare.git" MCS_WARN_REPEAT_SECS=0
has  "repeat window 0: printed again"                   "$OUT" "attention:diverged"

echo "── 5. index touched inside the grace period → left alone, silent ──"
mkfix young
run_mcs "$T/young/bare.git" MCS_GRACE_SECS=3600
eq   "silent"                                           "$OUT" ""
eq   "exit 0"                                           "$RC" "0"
eq   "index still C1"                                   "$(idx_tree "$T/young/wt")" "$(tree_of "$T/young/wt" main~1)"

echo "── 5b. looking must not touch the index (it is the age evidence, and someone else's file) ──"
# `git write-tree` on the real index rewrites it (persists the cache-tree) and so resets its mtime to
# now: a sweep that did that would make every index look 'just touched' and never heal anything.
mkfix aging
AG_GD=$(git -C "$T/aging/wt" rev-parse --absolute-git-dir)
touch -t 202001010000 "$AG_GD/index"
AG_SUM_BEFORE=$(cksum < "$AG_GD/index"); AG_MT_BEFORE=$(stat -f %m "$AG_GD/index" 2>/dev/null || stat -c %Y "$AG_GD/index")
run_mcs "$T/aging/bare.git" MCS_DRY_RUN=1
eq   "dry run left the index file byte-identical"       "$(cksum < "$AG_GD/index")" "$AG_SUM_BEFORE"
eq   "dry run left the index mtime alone"               "$(stat -f %m "$AG_GD/index" 2>/dev/null || stat -c %Y "$AG_GD/index")" "$AG_MT_BEFORE"
run_mcs "$T/aging/bare.git" MCS_GRACE_SECS=600
has  "a years-old stale index heals under the DEFAULT grace" "$OUT" "healed $T/aging/wt"
mkfix fresh
run_mcs "$T/fresh/bare.git" MCS_GRACE_SECS=600
eq   "a just-created index is within the 600s grace: silent" "$OUT" ""
eq   "…and stays unhealed"                              "$(idx_tree "$T/fresh/wt")" "$(tree_of "$T/fresh/wt" main~1)"

echo "── 6. operation in progress → attention:busy, nothing touched ──"
mkfix busy
BUSY_GD=$(git -C "$T/busy/wt" rev-parse --absolute-git-dir)
git -C "$T/busy/wt" rev-parse main~1 > "$BUSY_GD/MERGE_HEAD"
run_mcs "$T/busy/bare.git"
has  "attention:busy:MERGE_HEAD"                        "$OUT" "attention:busy:MERGE_HEAD $T/busy/wt"
eq   "exit 2"                                           "$RC" "2"
eq   "index still C1"                                   "$(idx_tree "$T/busy/wt")" "$(tree_of "$T/busy/wt" main~1)"

echo "── 7. read-tree refuses (untracked file in the way) → attention:heal-failed, nothing lost ──"
mkfix coll
echo mine > "$T/coll/wt/b.txt"
run_mcs "$T/coll/bare.git"
has  "attention:heal-failed"                            "$OUT" "attention:heal-failed $T/coll/wt"
eq   "exit 2"                                           "$RC" "2"
eq   "the untracked file is intact"                     "$(cat "$T/coll/wt/b.txt")" "mine"
eq   "index still C1"                                   "$(idx_tree "$T/coll/wt")" "$(tree_of "$T/coll/wt" main~1)"

echo "── 8. a git call that fails is 'could not tell', never 'in sync' ──"
mkfix corrupt
CORRUPT_GD=$(git -C "$T/corrupt/wt" rev-parse --absolute-git-dir)
echo "not an index" > "$CORRUPT_GD/index"
run_mcs "$T/corrupt/bare.git"
has  "attention:unknown:index-unreadable"               "$OUT" "attention:unknown:index-unreadable $T/corrupt/wt"
eq   "exit 2"                                           "$RC" "2"
eq   "the index file was not rewritten"                 "$(cat "$CORRUPT_GD/index")" "not an index"
run_mcs "$T/no/such/dir.git"
has  "missing bare dir → attention:unknown:bare-unreadable" "$OUT" "attention:unknown:bare-unreadable"
eq   "missing bare dir → exit 1"                        "$RC" "1"
mkdir -p "$T/notgit"
run_mcs "$T/notgit"
has  "not a git dir → attention:unknown:worktree-list-failed" "$OUT" "attention:unknown:worktree-list-failed"
eq   "not a git dir → exit 1 (never 'no worktrees')"    "$RC" "1"

echo "── 9. worktrees that do not have main checked out are never touched ──"
mkfix other
O="$T/other"
C2_SHA=$(git -C "$O/wt" rev-parse main)
C1_SHA=$(git -C "$O/wt" rev-parse main~1)
git --git-dir="$O/bare.git" worktree add -q --detach "$O/detached" "$C2_SHA"
git --git-dir="$O/bare.git" worktree add -q -b side "$O/sidewt" "$C2_SHA"
git -C "$O/detached" read-tree -u --reset "$C1_SHA"      # detached at C2, index+files at C1: looks stale
git -C "$O/sidewt"   read-tree -u --reset "$C1_SHA"      # branch `side`, same look
run_mcs "$O/bare.git"
has  "main's worktree was healed"                       "$OUT" "healed $O/wt"
hasnt "detached worktree not mentioned"                 "$OUT" "$O/detached"
hasnt "side-branch worktree not mentioned"              "$OUT" "$O/sidewt"
eq   "detached worktree index untouched"                "$(idx_tree "$O/detached")" "$(tree_of "$O/detached" "$C1_SHA")"
eq   "side-branch worktree index untouched"             "$(idx_tree "$O/sidewt")"   "$(tree_of "$O/sidewt" "$C1_SHA")"

echo "── 10. a registered main worktree whose directory is gone → attention, not 'nothing to check' ──"
mkfix gone
rm -rf "$T/gone/wt"
run_mcs "$T/gone/bare.git"
has  "attention:unknown:worktree-dir-missing"           "$OUT" "attention:unknown:worktree-dir-missing $T/gone/wt"
eq   "exit 2"                                           "$RC" "2"

echo "── 11. in sync is silent ──"
mkfix sync
git -C "$T/sync/wt" read-tree -m -u "$(tree_of "$T/sync/wt" main~1)" "$(tree_of "$T/sync/wt" main)"
run_mcs "$T/sync/bare.git"
eq   "silent"                                           "$OUT" ""
eq   "exit 0"                                           "$RC" "0"

# ── 12. drift-guard: the dispatcher actually runs it ────────────────────────────────────────────
echo "── 12. drift-guard: dispatcher wiring ──"
grep -q 'main-checkout-sync.sh' "$DISPATCHER" \
  && ok "dispatcher calls main-checkout-sync.sh" || bad "dispatcher does not call main-checkout-sync.sh"
grep -q 'bash "\$GC_CITY/packs/town-deltas/assets/main-checkout-sync.sh" "\$RC_PATH/.repo.git" "\$RC_BRANCH"' "$DISPATCHER" \
  && ok "called once per container rig with its bare dir + default branch" || bad "per-rig call (bare dir + branch) not found"
grep -q 'MCS_OUT=$(bash .*main-checkout-sync.sh.*) || MCS_RC=$?' "$DISPATCHER" \
  && ok "call is set -e safe (|| rc capture)" || bad "call not guarded against set -e"
grep -q 'attention:\*) *warn "Main-checkout sync:' "$DISPATCHER" \
  && ok "attention lines surface as WARN" || bad "attention lines not logged as WARN"
# It must run AFTER the bare main was reconciled to origin, inside the same container-rig loop.
# (|| true: a missing line must reach the bad() below, not kill the harness under set -e/pipefail)
RECON_LN=$(grep -n 'RC_OUT=$(reconcile_bare_main_to_origin' "$DISPATCHER" | head -n 1 | cut -d: -f1) || true
MCS_LN=$(grep -n 'MCS_OUT=$(bash' "$DISPATCHER" | head -n 1 | cut -d: -f1) || true
if [ -n "$RECON_LN" ] && [ -n "$MCS_LN" ] && [ "$MCS_LN" -gt "$RECON_LN" ]; then ok "sync runs after the bare-main reconcile (L$RECON_LN → L$MCS_LN)"; else bad "sync is not after the reconcile (reconcile=$RECON_LN sync=$MCS_LN)"; fi
[ -x "$SCRIPT" ] && ok "main-checkout-sync.sh is executable" || bad "main-checkout-sync.sh not executable"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
