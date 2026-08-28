#!/usr/bin/env bash
# gate-shallow-clone-mergebase.selftest.sh — Drift-guard for ga-ymbv.
#
# Bug: quality-gate-dispatcher.sh's conflict pre-check (merge-base / merge-tree
# via git_rig) misreports "no common ancestor" (MT_VERDICT=err, gate-status:error)
# for two branches that ARE related, whenever the shared rig checkout is a
# SHALLOW clone and the branches' common ancestor sits past the shallow fetch
# boundary. Discovered live on ga-x8m6r's round-2 marker
# (fix/ga-x8m6r-claude-commands-gitignore-sync): `git merge-base` returned
# nothing purely because of clone depth, not because the histories were
# genuinely unrelated. Filed as ga-ymbv; `git fetch origin --unshallow` on the
# shared checkout fixed ancestry resolution for every branch, confirming the
# root cause.
#
# Fix: quality-gate-dispatcher.sh now checks `git rev-parse
# --is-shallow-repository` right after its existing preflight fetch (before
# BRANCH_SHA / any merge-base call runs) and, if shallow, runs
# `git fetch origin --unshallow` once so all downstream ancestry checks operate
# on full history.
#
# ga-0eh7o: that preflight only runs ONCE, before review starts. A review can
# take 15-20+ minutes, and something can re-shallow the shared git-dir DURING
# that window — confirmed live, byte-verified via `git cat-file -p` that the
# truncated commit's own parent link was intact (a pure shallow-boundary
# problem, not object corruption). The Step-4 preflight had already passed
# clean, but do_merge_ff()'s own ancestry checks (IS_ANC / merge-base /
# merge-tree via rig_merge_has_conflict) then silently misread the
# re-introduced truncation as "no common ancestor" and failed non-retryably
# (failed_sha_resolution) even though the branch really was mergeable. Fix:
# the identical is-shallow-repository + fetch --unshallow check now also runs
# at the top of do_merge_ff() itself, so every merge attempt/retry (up to
# MAX_MERGE_RETRIES) self-heals independently of the one-time preflight.
#
# This harness (1) reproduces the bug class in isolation with real throwaway
# git repos to prove shallow clones actually cause merge-base/merge-tree to
# misreport ancestry this way, (2) proves --unshallow fixes it, (3)
# drift-guards the Step-4 preflight fix in the dispatcher source, and (4)
# drift-guards the do_merge_ff() re-check (ga-0eh7o). Exit 0 iff all hold.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "── gate shallow-clone merge-base drift-guard (ga-ymbv) ──"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gc-ga-ymbv-selftest-XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# ── Fixture: a "remote" with 5 commits on main, then a 1-commit "topic"
#    branch forked off main's tip. main's tip commit IS an ancestor of
#    topic's tip — a textbook clean, related history. ─────────────────────────
REMOTE="$WORK/remote.git"
git init --quiet --bare "$REMOTE"

SEED="$WORK/seed"
git init --quiet "$SEED"
git -C "$SEED" config user.email "selftest@gascity.local"
git -C "$SEED" config user.name  "selftest"
git -C "$SEED" remote add origin "$REMOTE"

for i in 1 2 3 4 5; do
  echo "line $i" >> "$SEED/file.txt"
  git -C "$SEED" add file.txt
  git -C "$SEED" commit --quiet -m "main commit $i"
done
git -C "$SEED" branch -M main
git -C "$SEED" push --quiet origin main
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main 2>/dev/null || true

git -C "$SEED" checkout --quiet -b topic
echo "topic change" >> "$SEED/topic.txt"
git -C "$SEED" add topic.txt
git -C "$SEED" commit --quiet -m "topic commit"
git -C "$SEED" push --quiet origin topic

EXPECTED="$(git -C "$SEED" merge-base topic main 2>/dev/null || echo "")"

# NOTE: `--depth` is silently ignored on local-path clones ("use file://
# instead" — verified empirically); the file:// URL forces the real
# smart-protocol fetch-pack negotiation that actually produces a shallow
# boundary.
SHALLOW="$WORK/shallow"
git clone --quiet --depth=1 --no-single-branch "file://$REMOTE" "$SHALLOW" >/dev/null 2>&1

# ── 1. Reproduce: a --depth=1 clone can't find the (real) common ancestor ────
IS_SHALLOW="$(git -C "$SHALLOW" rev-parse --is-shallow-repository 2>/dev/null || echo "")"
if [ "$IS_SHALLOW" = "true" ]; then
  ok "fixture clone is shallow (rev-parse --is-shallow-repository=true)"
else
  bad "fixture clone did NOT come up shallow — test environment cannot reproduce the bug (got: '$IS_SHALLOW')"
fi

MB_SHALLOW="$(git -C "$SHALLOW" merge-base origin/topic origin/main 2>/dev/null || echo "")"
MT_RC_SHALLOW=0
git -C "$SHALLOW" merge-tree --write-tree origin/main origin/topic >/dev/null 2>&1 || MT_RC_SHALLOW=$?
if [ -z "$MB_SHALLOW" ] || [ "$MT_RC_SHALLOW" -gt 1 ]; then
  ok "shallow clone misreports ancestry (merge-base='${MB_SHALLOW:-<empty>}', merge-tree rc=$MT_RC_SHALLOW) — bug is real"
else
  bad "shallow clone resolved ancestry fine (merge-base=$MB_SHALLOW, merge-tree rc=$MT_RC_SHALLOW) — fixture does not reproduce ga-ymbv"
fi

# ── 2. Prove the fix: --unshallow resolves it correctly ──────────────────────
git -C "$SHALLOW" fetch --quiet origin --unshallow >/dev/null 2>&1
MB_FULL="$(git -C "$SHALLOW" merge-base origin/topic origin/main 2>/dev/null || echo "")"
if [ -n "$MB_FULL" ] && [ -n "$EXPECTED" ] && [ "$MB_FULL" = "$EXPECTED" ]; then
  ok "after 'fetch --unshallow', merge-base resolves correctly ($MB_FULL)"
else
  bad "after 'fetch --unshallow', merge-base still wrong (got '$MB_FULL', expected '$EXPECTED')"
fi

# ── 3. Drift-guard: the real dispatcher must run this preflight before any
#    merge-base/merge-tree call — right after its existing preflight fetch,
#    ahead of BRANCH_SHA=$(rig_resolve_commit ...). ───────────────────────────
if [ -f "$GATE" ]; then
  PREFLIGHT_BLOCK="$(awk '/git_rig fetch origin 2>\/dev\/null \|\| warn/{c=1} c{print} /^BRANCH_SHA=/{if(c) exit}' "$GATE" 2>/dev/null || true)"
  if printf '%s' "$PREFLIGHT_BLOCK" | grep -q -- 'is-shallow-repository' \
     && printf '%s' "$PREFLIGHT_BLOCK" | grep -q -- 'fetch origin --unshallow'; then
    ok "dispatcher runs the shallow-clone preflight (is-shallow-repository + fetch --unshallow) before BRANCH_SHA resolution"
  else
    bad "dispatcher is MISSING the shallow-clone preflight ahead of BRANCH_SHA resolution (ga-ymbv regression)"
  fi
else
  bad "quality-gate-dispatcher.sh not found next to selftest at $GATE"
fi

# ── 4. Drift-guard (ga-0eh7o): the SAME preflight must ALSO run at the top of
#    do_merge_ff(), immediately before its own ancestry checks (IS_ANC /
#    merge-base), not just once at Step 4 above — closing the window where a
#    repo re-shallows DURING the review window, after Step 4 already passed
#    clean. ────────────────────────────────────────────────────────────────
if [ -f "$GATE" ]; then
  MERGE_FF_BLOCK="$(awk '/^[[:space:]]*do_merge_ff\(\) \{/{c=1} c{print} /^[[:space:]]*local IS_ANC/{if(c) exit}' "$GATE" 2>/dev/null || true)"
  if printf '%s' "$MERGE_FF_BLOCK" | grep -q -- 'is-shallow-repository' \
     && printf '%s' "$MERGE_FF_BLOCK" | grep -q -- 'fetch origin --unshallow'; then
    ok "do_merge_ff() re-checks shallow state before its own ancestry checks (ga-0eh7o)"
  else
    bad "do_merge_ff() is MISSING the shallow-clone re-check before its ancestry checks (ga-0eh7o regression: a repo re-shallowed DURING review would silently fail merge with failed_sha_resolution even though the branch is mergeable)"
  fi
else
  bad "quality-gate-dispatcher.sh not found next to selftest at $GATE"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
