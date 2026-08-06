#!/usr/bin/env bash
# gate-needs-rebase-terminality-reap.selftest.sh — ga-88sl7 mutation test.
#
# BUG (measured live, Mayor 2026-08-06): of 10 open gate markers, 8 carried
# gate-status:needs-rebase, and 5 of those 8 were for branches ALREADY FULLY
# MERGED into main (git merge-base --is-ancestor confirmed true for all 5;
# two had behind=256/314). All 5 source beads were already closed — the work
# shipped some other way. The marker never noticed, because:
#
#   - Step 0b's queued-marker selection is `-l gate-status:queued` only.
#   - quality-gate-guard.sh's own reclaim (Vector A) explicitly treats
#     needs-rebase as terminal and does not touch it.
#
# So Step 4b's already-merged detection — which DOES correctly prevent a
# fresh classification from bouncing an already-merged branch to
# needs-rebase — only ever runs ONCE, at that marker's original dispatch.
# Nothing re-checks an EXISTING needs-rebase marker against the CURRENT
# state of main. A marker correctly classified at the time becomes immortal
# the moment the underlying work ships through any other route afterward.
#
# FIX: gate_branch_already_merged() is a reusable predicate (same detection
# Step 4b already uses: is-ancestor, then rig_content_merged's patch-id
# fallback for a rebase-merge) callable independently of Step 4b's per-sweep
# candidate. Step 0a-4 is a new periodic janitor sweep — cheap, no author/
# session IO, no push/nudge — that re-checks every OPEN needs-rebase marker
# each sweep and reaps (supersede + close) any whose branch is now merged.
# A genuinely-still-diverged branch (ahead>0 AND behind>0) is untouched —
# AC4 non-regression: it must keep going to needs-rebase exactly as before.
#
# This harness SOURCES the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY)
# to unit-test the REAL function against a disposable, real git repo — no
# live Dolt/gc/launchd, no string-matching stand-in for git's own ancestry
# logic. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── Load the REAL helper from the dispatcher (lib-only = no live run) ─────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

for _fn in gate_branch_already_merged; do
  type "$_fn" >/dev/null 2>&1 \
    || { echo "FATAL: $_fn not defined by dispatcher (ga-88sl7 fix missing?)"; exit 1; }
done

# Quiet logging noise from sourced helpers.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. gate_branch_already_merged: real git fixtures, not string matching ─────
echo "── 1. gate_branch_already_merged: is-ancestor + content-merged fallback ──"

_FIXTURE_REPO="$(mktemp -d "${TMPDIR:-/tmp}/gc-gate-needsrebase-reap-fixture.XXXXXX")"
git -C "$_FIXTURE_REPO" init -q -b trunk
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" commit -q --allow-empty -m "root"

# origin/merged-branch is pinned HERE, at the fork point. origin/main then
# moves several commits ahead. merged-branch's tip stays an ancestor of main
# throughout — behind=N (a handful stands in for the real incident's
# behind=256/314; the mechanism, merge-base --is-ancestor, is O(ref) not
# O(N) so magnitude doesn't change what's being proven), ahead=0.
git -C "$_FIXTURE_REPO" branch origin/merged-branch
git -C "$_FIXTURE_REPO" branch origin/main
git -C "$_FIXTURE_REPO" checkout -q origin/main
for i in 1 2 3 4 5; do
  git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" commit -q --allow-empty -m "main commit $i"
done

# origin/diverged-branch: forks from root, gets its OWN unique commit
# (ahead=1) while main is ALSO ahead by 5 (behind=5) — genuinely diverged.
# This is the AC4 non-regression case: must NOT read as already-merged.
# The commit carries REAL file content (not --allow-empty): the
# content-merged fallback compares patch-ids, and every OTHER commit in
# this fixture is --allow-empty — an empty diff has no distinguishing
# content, so an empty "unique" commit can spuriously patch-id-match one of
# main's equally-empty commits and false-positive as cherry-pick-equivalent.
git -C "$_FIXTURE_REPO" checkout -q trunk
git -C "$_FIXTURE_REPO" branch origin/diverged-branch
git -C "$_FIXTURE_REPO" checkout -q origin/diverged-branch
echo "unique diverged-branch content, never touched by main" > "$_FIXTURE_REPO/diverged-only.txt"
git -C "$_FIXTURE_REPO" add diverged-only.txt
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" commit -q -m "diverged branch's own unique commit"

# git_rig, as sourced from the dispatcher in lib-only mode, is UNDEFINED here
# (defined AFTER the GATE_DISPATCHER_LIB_ONLY early-return by design). Shim
# it to the fixture repo — same technique this file's other real-git tests use.
git_rig() { git -C "$_FIXTURE_REPO" "$@"; }

eq "merged branch (behind=5, ahead=0, tip IS an ancestor of main) → 1 (reapable — the real ga-88sl7 shape)" \
  "$(gate_branch_already_merged "merged-branch" "main")" \
  "1"
eq "diverged branch (ahead=1 AND behind=5) → 0 (NOT reapable — AC4: must still go to needs-rebase, never swallow real work)" \
  "$(gate_branch_already_merged "diverged-branch" "main")" \
  "0"
eq "unresolvable branch ref → 0 (fail-closed: never reap on doubt, mirrors rig_content_merged's own FAIL-CLOSED contract)" \
  "$(gate_branch_already_merged "does-not-exist-xyz" "main")" \
  "0"
eq "empty branch arg → 0 (fail-closed, no git call attempted)" \
  "$(gate_branch_already_merged "" "main")" \
  "0"
eq "empty default_branch arg → 0 (fail-closed, no git call attempted)" \
  "$(gate_branch_already_merged "merged-branch" "")" \
  "0"

unset -f git_rig
rm -rf "$_FIXTURE_REPO"

# ── 2. drift-guard: Step 0a-4 sweep is actually wired to reap stranded markers ─
# A correct gate_branch_already_merged() sitting unused would leave the
# original bug exactly as broken as before this fix — the reap loop's
# existence (not just the predicate) is the actual fix. Grep the dispatcher's
# own source for the literal call inside the needs-rebase query loop, the
# same "drift guard" convention this file's other selftests already use for
# wiring that can't be isolated as a pure function.
echo "── 2. drift-guard: Step 0a-4 sweep queries needs-rebase markers and calls the predicate ──"

if grep -qF -- '-l gate-status:needs-rebase' "$DISPATCHER" \
  && grep -qF 'gate_branch_already_merged "$NR_BRANCH" "$DEFAULT_BRANCH"' "$DISPATCHER"; then
  ok "Step 0a-4 queries gate-status:needs-rebase markers and calls gate_branch_already_merged on each"
else
  bad "Step 0a-4 wiring NOT found — gate_branch_already_merged exists but nothing calls it over needs-rebase markers (ga-88sl7 regressed to bug-present)"
fi

if grep -qF 'set_gate_status "$NR_MARKER_ID" "superseded"' "$DISPATCHER"; then
  ok "Step 0a-4 supersedes the reaped marker via the same atomic set_gate_status helper Step 4b uses"
else
  bad "Step 0a-4 does NOT supersede the reaped marker via set_gate_status"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
if [ "$FAIL" = "0" ]; then
  echo "PASS $PASS/$((PASS+FAIL)) — gate-needs-rebase-terminality-reap selftest"
  exit 0
else
  echo "FAIL $FAIL/$((PASS+FAIL)) — gate-needs-rebase-terminality-reap selftest"
  exit 1
fi
