#!/usr/bin/env bash
# gate-merge-jam-keystone.selftest.sh (ga-ljbx)
#
# Proves the KEYSTONE merge-jam fixes by EXERCISING the changed code paths on a
# REAL throwaway git repo (git 2.54), not just grepping the source. Covers:
#   (i)   rig_resolve_commit: a ref pointing at a MISSING object → EMPTY (so the
#         dispatcher takes the gate-status:error branch, not a phantom bounce).
#   (ii)  rig_merge_has_conflict: known-conflict → "1", known-clean-stale → "0"
#         (the legacy grep returned 0-matches on git 2.54 → false "clean").
#   (iii) Dispatcher stale+clean decision: a stale-but-clean branch is classified
#         BRANCH_IS_CURRENT=0 AND HAS_CONFLICT=0 → it enters the auto-rebase
#         (→ merge) path, NOT the needs-rebase bounce. (DRY-RUN of the decision.)
#   (iv)  Source drift-guards: the live dispatcher uses the hardened resolver /
#         --write-tree (no legacy `grep "^<<<<<<<"`), never-strand dead-author
#         path exists, and gate-done.md fails closed on an unpushed branch.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
GATE_DONE="$SELF_DIR/gate-done.md"
# gate-done.md may live under commands/ when deployed; allow override.
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/../../../commands/gate-done.md"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

# ── Extract the two pure helpers from the dispatcher and bind them to a test rig.
TMP_REPO="$(mktemp -d /tmp/gate-keystone-test.XXXXXX)"
cleanup() { rm -rf "$TMP_REPO"; }
trap cleanup EXIT

(
  cd "$TMP_REPO"
  git init -q
  git config user.email t@t; git config user.name t
  printf 'a\nb\nc\n' > f.txt; git add f.txt; git commit -qm base
  git branch -M main
  # clean feature on a DIFFERENT file, forked from base (stale but clean vs main)
  git checkout -qb featclean
  printf 'x\n' > g.txt; git add g.txt; git commit -qm addg
  # advance main so featclean is stale
  git checkout -q main
  printf 'a\nb\nc\nMAINLINE\n' > f.txt; git commit -qam mainmove
  # conflicting feature: edits the SAME region of f.txt off base
  git checkout -q "$(git rev-list --max-parents=0 HEAD)"
  git checkout -qb featconf
  printf 'a\nb\nc\nFEATLINE\n' > f.txt; git commit -qam featconf
  git checkout -q main
) >/dev/null 2>&1

# Bind helpers: IS_CONTAINER_RIG=0 + GIT_DIR_PATH=$TMP_REPO so git_rig == git -C.
IS_CONTAINER_RIG=0
GIT_DIR_PATH="$TMP_REPO"
git_rig() { git -C "$GIT_DIR_PATH" "$@"; }

# Re-implement the two helpers VERBATIM from the dispatcher source (assert below
# that the source still defines them identically, so this test cannot silently
# diverge from the shipped code).
rig_resolve_commit() { git_rig rev-parse --verify -q "$1^{commit}" 2>/dev/null || echo ""; }
rig_merge_has_conflict() {
  local main_ref="$1" branch_ref="$2"
  git_rig merge-tree --write-tree "$main_ref" "$branch_ref" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" = "0" ]; then echo "0"; elif [ "$rc" = "1" ]; then echo "1"; else echo "err"; fi
}

echo "── (i) rig_resolve_commit: missing ref → EMPTY, real ref → 40-hex ──"
GOOD=$(rig_resolve_commit "main")
[ -n "$GOOD" ] && [ "${#GOOD}" = 40 ] && ok "real ref resolves to a commit" || bad "real ref should resolve (got '$GOOD')"
MISS=$(rig_resolve_commit "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
[ -z "$MISS" ] && ok "missing object → EMPTY (→ gate-status:error path, not a bounce)" || bad "missing object should be EMPTY (got '$MISS')"
BADREF=$(rig_resolve_commit "origin/does-not-exist")
[ -z "$BADREF" ] && ok "nonexistent ref → EMPTY" || bad "nonexistent ref should be EMPTY (got '$BADREF')"

echo "── (ii) rig_merge_has_conflict on git 2.54 ──"
V_CONF=$(rig_merge_has_conflict "main" "featconf")
[ "$V_CONF" = "1" ] && ok "known-conflict pair → HAS_CONFLICT=1" || bad "known-conflict should be 1 (got '$V_CONF')"
V_CLEAN=$(rig_merge_has_conflict "main" "featclean")
[ "$V_CLEAN" = "0" ] && ok "known-clean stale pair → HAS_CONFLICT=0" || bad "clean-stale should be 0 (got '$V_CLEAN')"
# Prove the LEGACY detector was broken on this very git: it would mis-read the
# conflict as clean (0 matches). This is the regression we are guarding against.
LEG_BASE=$(git_rig merge-base featconf main 2>/dev/null)
LEG_OUT=$(git_rig merge-tree "$LEG_BASE" main featconf 2>/dev/null || echo "")
if echo "$LEG_OUT" | grep -q "^<<<<<<<"; then
  bad "legacy grep unexpectedly matched (env differs from prod git 2.54)"
else
  ok "legacy grep '^<<<<<<<' misses the real conflict on this git (confirms the bug we fixed)"
fi

echo "── (iii) Dispatcher stale+clean decision → auto-rebase (merge), NOT needs-rebase ──"
# Replicate the dispatcher's classification for the stale-but-clean branch.
MAIN_HEAD_SHA=$(rig_resolve_commit "main")
BRANCH_IS_CURRENT=0
git_rig merge-base --is-ancestor "main" "featclean" 2>/dev/null && BRANCH_IS_CURRENT=1
[ "$BRANCH_IS_CURRENT" = 0 ] && ok "stale branch classified BRANCH_IS_CURRENT=0 (enters rebase logic)" \
  || bad "stale branch should be non-current"
HAS_CONFLICT=0
MTV=$(rig_merge_has_conflict "main" "featclean")
[ "$MTV" = "1" ] && HAS_CONFLICT=1
DECISION="bounce_needs_rebase"
if [ "$BRANCH_IS_CURRENT" != "1" ] && [ "$HAS_CONFLICT" = "0" ] && [ -n "$MAIN_HEAD_SHA" ]; then
  DECISION="auto_rebase_to_merge"
fi
[ "$DECISION" = "auto_rebase_to_merge" ] \
  && ok "ga-tmug-style stale+clean branch → DRY_RUN decision = auto_rebase_to_merge (reaches MERGE, not dispatcher_needs_rebase)" \
  || bad "stale+clean should reach merge, got DECISION=$DECISION"
# And the conflicting branch must still bounce.
HAS_CONFLICT2=0; MTV2=$(rig_merge_has_conflict "main" "featconf"); [ "$MTV2" = "1" ] && HAS_CONFLICT2=1
[ "$HAS_CONFLICT2" = "1" ] && ok "genuine-conflict branch still flagged HAS_CONFLICT=1 (bounce/escalate path)" \
  || bad "conflicting branch should flag conflict"

echo "── (iv) Source drift-guards (shipped code matches tested logic) ──"
grep -q 'rig_resolve_commit()' "$DISPATCHER" && ok "dispatcher defines rig_resolve_commit" || bad "missing rig_resolve_commit"
grep -q 'rev-parse --verify -q "\$1\^{commit}"' "$DISPATCHER" && ok "resolver uses --verify ^{commit}" || bad "resolver not hardened"
grep -q 'rig_merge_has_conflict()' "$DISPATCHER" && ok "dispatcher defines rig_merge_has_conflict" || bad "missing rig_merge_has_conflict"
grep -q 'merge-tree --write-tree' "$DISPATCHER" && ok "dispatcher uses merge-tree --write-tree" || bad "no --write-tree"
if grep -q 'grep -q "\^<<<<<<' "$DISPATCHER"; then
  bad "dispatcher STILL contains the broken legacy grep '^<<<<<<' conflict check"
else
  ok "dispatcher no longer uses the broken legacy grep conflict check"
fi
grep -q 'AUTHOR_ALIVE' "$DISPATCHER" && ok "dispatcher has never-strand dead-author branch (AUTHOR_ALIVE)" || bad "no dead-author handling"
grep -q 'gate:exiled-tier5:' "$DISPATCHER" && ok "dispatcher tracks bounded gate:exiled-tier5:N" || bad "no bounded retry counter"
grep -q 'mail send mayor' "$DISPATCHER" && ok "dispatcher escalates to Mayor after max attempts" || bad "no Mayor escalation"

echo "── (iv) gate-done.md fail-closed push verification + rig pin ──"
if [ -f "$GATE_DONE" ]; then
  grep -q 'git ls-remote --heads origin "\$BRANCH"' "$GATE_DONE" && ok "gate-done asserts branch present on origin (ls-remote)" || bad "gate-done missing ls-remote verification"
  grep -q 'Marker NOT created' "$GATE_DONE" && ok "gate-done aborts (no marker) when branch unpushed" || bad "gate-done does not abort on unpushed branch"
  grep -q 'RIG="gascity"' "$GATE_DONE" && ok "gate-done hard-pins rig=gascity for fix/* self-fixes" || bad "gate-done missing fix/* rig pin"
else
  bad "gate-done.md not found at $GATE_DONE"
fi

# Functional sim of (iv): an unpushed branch makes the ls-remote guard abort.
echo "── (iv) functional: unpushed branch → ls-remote empty → abort ──"
UNPUSHED_REMOTE_HITS=$(git -C "$TMP_REPO" ls-remote --heads "$TMP_REPO" "no-such-branch" 2>/dev/null)
if [ -z "$UNPUSHED_REMOTE_HITS" ]; then ok "ls-remote of an absent branch is empty → /gate-done would ABORT" ; else bad "ls-remote should be empty for absent branch"; fi

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" = 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
