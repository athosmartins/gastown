#!/usr/bin/env bash
# quality-gate-base-commit-trust.selftest.sh — ga-iwcu23.
#
# Proves the fix for: nothing validated that a quality-gate-marker's
# self-declared base_commit actually existed on ORIGIN. A marker could
# record a base_commit real only in the author's local worktree — every
# downstream consumer then measured against a base it couldn't resolve,
# SILENTLY (the "error and empty produce the same value" class). Measured
# live in marker ga-jvzpb (branch crew/oracle/wa-qtwh3):
#
#   base_commit gravado: d2e0f98f88ecc11dea6be921852c88ab5266ba00
#   - existed in the root worktree: `git cat-file -t` -> commit
#   - absent from origin: `git fetch origin d2e0f98f...` -> "not our ref"
#
# ...which fed a confident "117 commits behind main" into the ga-6dp9
# circuit-breaker (real, merge-base-verified distance: 36) and permanently
# parked the marker (gate:needs-human, story stranded).
#
# Two sections:
#   1. Unit-tests the new pure decision function gate_base_commit_trust()
#      via the same lib-only sourcing every other gate selftest uses.
#   2. Reproduces the incident's actual git mechanics end-to-end against a
#      real, disposable, local-only git repo (a commit present in the
#      working repo but never pushed to its "origin") — proving the git
#      plumbing the dispatcher's call site relies on (rig_resolve_commit +
#      merge-base --is-ancestor) actually behaves as gate_base_commit_trust
#      assumes, not just that the pure function's own truth table is right.
#
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

for _fn in gate_base_commit_trust; do
  type "$_fn" >/dev/null 2>&1 \
    || { echo "FATAL: $_fn not defined by dispatcher (ga-iwcu23 fix missing?)"; exit 1; }
done
# NOTE: rig_resolve_commit is defined AFTER the GATE_DISPATCHER_LIB_ONLY
# early-return (like git_rig itself), so it is not sourceable here — same
# constraint every other gate selftest lives with. Section 2 below mirrors
# rig_resolve_commit's exact one-line implementation
# (`rev-parse --verify -q "$1^{commit}"`) inline against a real fixture repo
# instead of calling through the function, which is why its checks are
# labeled "-equivalent".

# Quiet logging noise from sourced helpers.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. gate_base_commit_trust: pure decision table ────────────────────────────
echo "── 1. gate_base_commit_trust: pure decision table ──"

eq "fetch failed → unverifiable regardless of anything else (even a good-looking base)" \
  "$(gate_base_commit_trust "deadbeef" "deadbeef" "1" "0")" \
  "unverifiable:fetch_failed"

eq "no base_commit declared, fetch ok → trusted (absence is pre-existing, unchanged behavior)" \
  "$(gate_base_commit_trust "" "" "0" "1")" \
  "trusted"

eq "base_commit literally 'unknown', fetch ok → trusted (same permissive treatment as empty)" \
  "$(gate_base_commit_trust "unknown" "" "0" "1")" \
  "trusted"

eq "base_commit declared but does not resolve to any object → unverifiable:object_missing" \
  "$(gate_base_commit_trust "d2e0f98f88ecc11dea6be921852c88ab5266ba0" "" "0" "1")" \
  "unverifiable:object_missing"

eq "base_commit resolves locally but is NOT an ancestor of origin/main (the ga-jvzpb shape) → unverifiable:not_origin_ancestor" \
  "$(gate_base_commit_trust "d2e0f98f88ecc11dea6be921852c88ab5266ba0" "d2e0f98f88ecc11dea6be921852c88ab5266ba0" "0" "1")" \
  "unverifiable:not_origin_ancestor"

eq "base_commit resolves AND is an ancestor of origin/main → trusted (the healthy/common case)" \
  "$(gate_base_commit_trust "4111777df55ba13df95d2e3155ac826ca2e708a1" "4111777df55ba13df95d2e3155ac826ca2e708a1" "1" "1")" \
  "trusted"

# ── 2. Real git mechanics: local-only commit vs. a pushed one ─────────────────
# Builds a throwaway repo + a separate bare "origin", reproducing the exact
# ga-jvzpb shape (a commit real in the working tree, absent from origin) next
# to the healthy shape (a commit that IS on origin) — no network involved.
echo "── 2. real git plumbing: rig_resolve_commit + merge-base --is-ancestor ──"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

git init -q --bare "$TMPROOT/origin.git"
git init -q "$TMPROOT/work"
git -C "$TMPROOT/work" config user.email "selftest@example.com"
git -C "$TMPROOT/work" config user.name "selftest"
git -C "$TMPROOT/work" remote add origin "$TMPROOT/origin.git"

git -C "$TMPROOT/work" commit -q --allow-empty -m "root"
git -C "$TMPROOT/work" branch -M main
git -C "$TMPROOT/work" commit -q --allow-empty -m "on origin/main"
PUSHED_SHA=$(git -C "$TMPROOT/work" rev-parse HEAD)
git -C "$TMPROOT/work" push -q origin main

# A commit made AFTER the push, on a local-only branch, never pushed anywhere
# — mirrors "base_commit existed in the root worktree, absent from origin".
git -C "$TMPROOT/work" checkout -qb local-only-branch
git -C "$TMPROOT/work" commit -q --allow-empty -m "never pushed"
LOCAL_ONLY_SHA=$(git -C "$TMPROOT/work" rev-parse HEAD)
git -C "$TMPROOT/work" checkout -q main

# Minimal git_rig-equivalent for this throwaway repo (dispatcher's real
# git_rig wraps rig-context plumbing not relevant to a single-repo fixture).
_fixture_git() { git -C "$TMPROOT/work" "$@"; }

RESOLVED_LOCAL_ONLY=$(_fixture_git rev-parse --verify -q "${LOCAL_ONLY_SHA}^{commit}" 2>/dev/null || echo "")
[ "$RESOLVED_LOCAL_ONLY" = "$LOCAL_ONLY_SHA" ] \
  && ok "rig_resolve_commit-equivalent: local-only commit resolves in the WORKING repo (present locally, same as ga-jvzpb's root worktree)" \
  || bad "rig_resolve_commit-equivalent: expected local-only commit to resolve locally, got [$RESOLVED_LOCAL_ONLY]"

if _fixture_git merge-base --is-ancestor "$LOCAL_ONLY_SHA" origin/main 2>/dev/null; then
  bad "merge-base --is-ancestor: local-only commit should NOT be an ancestor of origin/main"
else
  ok "merge-base --is-ancestor: local-only commit correctly rejected as an origin/main ancestor (this is the ga-jvzpb bug's exact shape)"
fi

IS_ANCESTOR_LOCAL_ONLY=0
_fixture_git merge-base --is-ancestor "$LOCAL_ONLY_SHA" origin/main 2>/dev/null && IS_ANCESTOR_LOCAL_ONLY=1
eq "end-to-end: local-only base_commit → unverifiable:not_origin_ancestor (would have blocked ga-jvzpb's false 117)" \
  "$(gate_base_commit_trust "$LOCAL_ONLY_SHA" "$RESOLVED_LOCAL_ONLY" "$IS_ANCESTOR_LOCAL_ONLY" "1")" \
  "unverifiable:not_origin_ancestor"

RESOLVED_PUSHED=$(_fixture_git rev-parse --verify -q "${PUSHED_SHA}^{commit}" 2>/dev/null || echo "")
IS_ANCESTOR_PUSHED=0
_fixture_git merge-base --is-ancestor "$PUSHED_SHA" origin/main 2>/dev/null && IS_ANCESTOR_PUSHED=1
eq "end-to-end: a real pushed-to-origin base_commit → trusted (no regression for the healthy case)" \
  "$(gate_base_commit_trust "$PUSHED_SHA" "$RESOLVED_PUSHED" "$IS_ANCESTOR_PUSHED" "1")" \
  "trusted"

rm -rf "$TMPROOT"
trap - EXIT

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" = "0" ]; then
  echo "PASS $PASS/$((PASS+FAIL)) — quality-gate-base-commit-trust selftest"
  exit 0
else
  echo "FAIL $FAIL/$((PASS+FAIL)) — quality-gate-base-commit-trust selftest"
  exit 1
fi
