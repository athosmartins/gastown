#!/usr/bin/env bash
# worktree-reaper.selftest.sh — prove the ga-pdrij pool-worktree coverage + merged-only
# branch cleanup in isolation, against a TEMP git repo (no touch to the real $GT).
#
# Asserts: (1) a stale+CLEAN pool worktree (under <rig>/crew/worker-*) is reaped; (2) its
# orphan local branch is deleted IFF merged into origin/<default>; (3) an UNMERGED branch's
# worktree is reaped but the branch is KEPT (no data loss); (4) a DIRTY pool worktree is
# skipped (live WIP protected); (5) a FRESH worktree is kept (age gate). Exit 0 iff all hold.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$SELF_DIR/worktree-reaper.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# ── build a temp "town" ($TMP) containing one rig repo with an origin/main ───────
TOWN="$TMP/town"; mkdir -p "$TOWN"
REMOTE="$TMP/remote.git"; git init -q --bare "$REMOTE"
RIG="$TOWN/testrig"
git init -q -b main "$RIG"
( cd "$RIG"
  git remote add origin "$REMOTE"
  echo a > a.txt; git add a.txt; git commit -qm "base"
  git push -q origin main
  git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  # merged branch: points at main (no new commits → merged into origin/main)
  git branch crew/x/merged main
  # unmerged branch: one commit ahead of main (NOT merged)
  git branch crew/x/unmerged main
  git worktree add -q "$RIG/crew/worker-merged"   crew/x/merged
  git worktree add -q "$RIG/crew/worker-unmerged" crew/x/unmerged
  ( cd "$RIG/crew/worker-unmerged"; echo b > b.txt; git add b.txt; git commit -qm "ahead" )
  git worktree add -q "$RIG/crew/worker-dirty"    -b crew/x/dirty main
  ( cd "$RIG/crew/worker-dirty"; echo dirty > dirty.txt )   # uncommitted → dirty
  git worktree add -q "$RIG/crew/worker-fresh"    -b crew/x/fresh main
) >/dev/null 2>&1

# backdate the three "stale" worktrees to ~3h ago; leave -fresh at now
for w in worker-merged worker-unmerged worker-dirty; do
  touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$RIG/crew/$w" 2>/dev/null || true
done

# ── run the reaper against the temp town, STALE_HOURS=1 ──────────────────────────
WORKTREE_REAPER_GT="$TOWN" \
WORKTREE_REAPER_LOG="$TMP/reaper.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 \
WORKTREE_REAPER_ENABLED=1 \
  bash "$REAPER" >/dev/null 2>&1

# match by path SUFFIX — macOS mktemp gives /var/... but git reports the realpath
# /private/var/..., so an exact full-line compare false-negatives every worktree.
wt_exists()     { git -C "$RIG" worktree list --porcelain 2>/dev/null | grep -qE "^worktree .*/crew/$1\$"; }
branch_exists() { git -C "$RIG" rev-parse --verify -q "refs/heads/$1" >/dev/null 2>&1; }

echo "── ga-pdrij pool-worktree reaping ──"
wt_exists worker-merged   && bad "stale+clean merged worktree NOT reaped"        || ok "stale+clean merged pool worktree reaped"
branch_exists crew/x/merged   && bad "merged orphan branch NOT deleted"          || ok "merged orphan branch deleted (unblocks _filter_built)"
wt_exists worker-unmerged && bad "stale+clean unmerged worktree NOT reaped"      || ok "stale+clean unmerged pool worktree reaped"
branch_exists crew/x/unmerged && ok "UNMERGED branch KEPT (no data loss)"        || bad "unmerged branch wrongly deleted (DATA LOSS!)"
wt_exists worker-dirty    && ok "dirty worktree SKIPPED (live WIP protected)"    || bad "dirty worktree wrongly reaped (WIP loss!)"
branch_exists crew/x/dirty    && ok "dirty worktree's branch kept"              || bad "dirty worktree's branch wrongly deleted"
wt_exists worker-fresh    && ok "fresh worktree KEPT (age gate)"                 || bad "fresh worktree wrongly reaped"

# ── kill switch: ENABLED=0 → would_reap only, no mutation ────────────────────────
echo "── kill switch (ENABLED=0 = dry) ──"
git -C "$RIG" worktree add -q "$RIG/crew/worker-ks" -b crew/x/ks main >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$RIG/crew/worker-ks" 2>/dev/null || true
WORKTREE_REAPER_GT="$TOWN" WORKTREE_REAPER_LOG="$TMP/reaper2.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=0 \
  bash "$REAPER" >/dev/null 2>&1
wt_exists worker-ks && ok "ENABLED=0: stale worktree NOT removed (dry-run)" || bad "ENABLED=0 still removed a worktree"
grep -q '"event":"would_reap_pool"' "$TMP/reaper2.jsonl" 2>/dev/null && ok "ENABLED=0: logged would_reap_pool intent" || bad "ENABLED=0: did not log dry intent"

# ── per-sweep CAP: 3 stale clean worktrees, cap=2 → exactly 2 reaped, 1 survives ──
echo "── per-sweep cap (ga-pdrij backlog drains gradually) ──"
RIG2="$TOWN/caprig"; git init -q -b main "$RIG2"
( cd "$RIG2"
  git remote add origin "$REMOTE"   # reuse the bare remote; push a separate ref
  echo c > c.txt; git add c.txt; git commit -qm capbase
  for n in 1 2 3; do git worktree add -q "$RIG2/crew/worker-cap$n" -b crew/c/cap$n main >/dev/null 2>&1; done
) >/dev/null 2>&1
for n in 1 2 3; do
  touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$RIG2/crew/worker-cap$n" 2>/dev/null || true
done
WORKTREE_REAPER_GT="$TOWN" WORKTREE_REAPER_LOG="$TMP/reaper3.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 WORKTREE_REAPER_MAX_PER_SWEEP=2 \
  bash "$REAPER" >/dev/null 2>&1
_capreaped=$(grep -c '"event":"reaped_pool".*caprig' "$TMP/reaper3.jsonl" 2>/dev/null || echo 0)
[ "$_capreaped" = "2" ] && ok "cap=2 reaped exactly 2 of 3 (capped)" || bad "cap=2 reaped $_capreaped (expected 2)"
_capsurv=$(git -C "$RIG2" worktree list --porcelain 2>/dev/null | grep -cE "^worktree .*/crew/worker-cap[0-9]\$")
[ "$_capsurv" = "1" ] && ok "1 capped worktree survives this sweep (drains next)" || bad "expected 1 survivor, got $_capsurv"
grep -q '"event":"pool_cap_hit"' "$TMP/reaper3.jsonl" 2>/dev/null && ok "cap-hit logged (no silent truncation)" || bad "cap-hit NOT logged"

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
