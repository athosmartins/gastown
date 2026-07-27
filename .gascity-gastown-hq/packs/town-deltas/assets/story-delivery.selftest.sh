#!/usr/bin/env bash
# story-delivery.selftest.sh — prove the ga-266z8 task-reconciler merge-verification
# guard in isolation, with NO live Dolt/gc/launchd and NO network.
#
# Sources story-delivery.sh in lib-only mode for the REAL functions (one source
# of truth, no copy-drift), unit-tests the pure verdict decision across every
# branch, then runs a real-git integration test for the content-check helper
# (commit-subject scan with conventional-commit-scope discrimination). Exit 0
# iff every assertion holds.
#
# Covers the ga-266z8 DoD:
#   1. A non-story bead with gate:passed but NO commit scoped to it in
#      origin/<default_branch> is NOT closed by the sweep (verdict = keep).
#   2. A bead carrying BOTH gate:passed and gate:needs-fix/gate:failed is NOT
#      closed, regardless of merge state (contradiction guard wins).
#   3. A genuinely-merged bead (a real commit scoped to its id exists in the
#      ref's history) still closes normally (no regression).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/story-delivery.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
rc0() { if "$@" >/dev/null 2>&1; then ok "rc0: $*"; else bad "expected rc0: $*"; fi; }
rc1() { if "$@" >/dev/null 2>&1; then bad "expected non-zero: $*"; else ok "rc!=0: $*"; fi; }

# ── 0. bash -n clean ─────────────────────────────────────────────────────────
echo "── 0. bash -n (syntax) ──"
if bash -n "$SCRIPT" 2>/tmp/story-delivery-selftest-syntax.$$; then
  ok "bash -n $SCRIPT"
else
  bad "bash -n $SCRIPT: $(cat /tmp/story-delivery-selftest-syntax.$$)"
fi
rm -f /tmp/story-delivery-selftest-syntax.$$

# ── Load the REAL functions (lib-only = no live sweep) ──────────────────────
STORY_DELIVERY_LIB_ONLY=1 source "$SCRIPT" \
  || { echo "FATAL: could not source story-delivery.sh in lib-only mode"; exit 1; }
for fn in rig_gitdir git_in token_bounded subject_impl_scopes_bead \
          scan_commit_subject_for_bead task_reconciler_verdict; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by story-delivery.sh"; exit 1; }
done

# ── 1. task_reconciler_verdict — pure decision, every branch ────────────────
# Args: <is_contradicted> <is_merge_verified>
echo "── 1. task_reconciler_verdict (pure verdict) ──"
eq "DoD#1: unverified, not contradicted → keep (never trust label alone)" \
   "$(task_reconciler_verdict 0 0)" "keep:merge-not-verified"
eq "DoD#2: contradicted, unverified → keep (contradiction guard)" \
   "$(task_reconciler_verdict 1 0)" "keep:contradicted-by-gate-failed-or-needs-fix"
eq "DoD#2: contradicted EVEN IF merge-verified → keep (contradiction wins)" \
   "$(task_reconciler_verdict 1 1)" "keep:contradicted-by-gate-failed-or-needs-fix"
eq "DoD#3: verified, not contradicted → close (no regression on real merges)" \
   "$(task_reconciler_verdict 0 1)" "close:commit-in-origin-main"
eq "verb-only check: unverified is keep"     "$(task_reconciler_verdict 0 0 | cut -d: -f1)" "keep"
eq "verb-only check: contradicted is keep"   "$(task_reconciler_verdict 1 0 | cut -d: -f1)" "keep"
eq "verb-only check: verified is close"      "$(task_reconciler_verdict 0 1 | cut -d: -f1)" "close"

# ── 2. rig_gitdir — container vs self-repo detection ────────────────────────
echo "── 2. rig_gitdir (container vs self-repo) ──"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

SELFREPO="$TMPROOT/self-repo"
mkdir -p "$SELFREPO"
PAIR=$(rig_gitdir "$SELFREPO")
eq "self-repo gdir"      "${PAIR%$'\t'*}" "$SELFREPO"
eq "self-repo container" "${PAIR#*$'\t'}" "0"

CONTAINERREPO="$TMPROOT/container-repo"
mkdir -p "$CONTAINERREPO/.repo.git"
PAIR=$(rig_gitdir "$CONTAINERREPO")
eq "container gdir"      "${PAIR%$'\t'*}" "$CONTAINERREPO/.repo.git"
eq "container flag"      "${PAIR#*$'\t'}" "1"

# ── 3. scan_commit_subject_for_bead — real-git integration (content check) ──
# Build a throwaway git repo with a real merge history so the DoD's "branch is
# an ancestor" and "no commit landed" scenarios are proven against real git,
# not simulated booleans.
echo "── 3. scan_commit_subject_for_bead (real-git content check) ──"
REPO="$TMPROOT/repo.git"
git init -q --bare "$REPO"
WORK="$TMPROOT/work"
git clone -q "$REPO" "$WORK"
git -C "$WORK" config user.email "test@example.com"
git -C "$WORK" config user.name "Test"
git -C "$WORK" checkout -q -b main
echo "seed" > "$WORK/seed.txt"
git -C "$WORK" add seed.txt
git -C "$WORK" commit -q -m "chore: seed repo"

# DoD#3 fixture: a genuinely-merged bead — a commit whose SUBJECT SCOPE is the
# bead id lands on main.
echo "fix1" > "$WORK/fix1.txt"
git -C "$WORK" add fix1.txt
git -C "$WORK" commit -q -m "fix(ga-266z8-merged): implements the fix for ga-266z8-merged"

# DoD#1 fixture (negative control): a commit exists that MENTIONS a different
# bead id only as trailing context, never as the implementing scope — must NOT
# count as merged (this is exactly the wa-iy9s8 false-positive class the
# subject-scope discriminator prevents).
echo "fix2" > "$WORK/fix2.txt"
git -C "$WORK" add fix2.txt
git -C "$WORK" commit -q -m "fix(unrelated): tweak unrelated area (ga-266z8-context-only)"

git -C "$WORK" push -q origin main

BARE_PAIR=$(rig_gitdir "$REPO")
BARE_GDIR="${BARE_PAIR%$'\t'*}"
BARE_CONTAINER="${BARE_PAIR#*$'\t'}"

rc0 scan_commit_subject_for_bead "$BARE_GDIR" "$BARE_CONTAINER" "main" "ga-266z8-merged"
rc1 scan_commit_subject_for_bead "$BARE_GDIR" "$BARE_CONTAINER" "main" "ga-266z8-context-only"
rc1 scan_commit_subject_for_bead "$BARE_GDIR" "$BARE_CONTAINER" "main" "ga-266z8-never-landed"
rc1 scan_commit_subject_for_bead "$BARE_GDIR" "$BARE_CONTAINER" "no-such-ref" "ga-266z8-merged"

FOUND_SHA=$(scan_commit_subject_for_bead "$BARE_GDIR" "$BARE_CONTAINER" "main" "ga-266z8-merged" 2>/dev/null || true)
if [ -n "$FOUND_SHA" ]; then ok "scan prints a sha for the merged bead ($FOUND_SHA)"; else bad "scan printed no sha for the merged bead"; fi

# ── 4. End-to-end: verdict wiring matches the real content-check outcome ────
echo "── 4. End-to-end verdict wiring ──"
if scan_commit_subject_for_bead "$BARE_GDIR" "$BARE_CONTAINER" "main" "ga-266z8-merged" >/dev/null 2>&1; then
  MERGED_VERIFIED=1
else
  MERGED_VERIFIED=0
fi
eq "DoD#3 e2e: real merged bead → close verdict" \
   "$(task_reconciler_verdict 0 "$MERGED_VERIFIED")" "close:commit-in-origin-main"

if scan_commit_subject_for_bead "$BARE_GDIR" "$BARE_CONTAINER" "main" "ga-266z8-never-landed" >/dev/null 2>&1; then
  UNMERGED_VERIFIED=1
else
  UNMERGED_VERIFIED=0
fi
eq "DoD#1 e2e: never-landed bead → keep verdict (not closed)" \
   "$(task_reconciler_verdict 0 "$UNMERGED_VERIFIED")" "keep:merge-not-verified"

# A bead that DID land (by content) but ALSO carries gate:needs-fix must still
# be kept — contradiction beats even real merge evidence (DoD#2, no regression
# vs DoD#3's independent proof that the content-check machinery itself works).
eq "DoD#2 e2e: merged bead but contradicted by gate:needs-fix → keep" \
   "$(task_reconciler_verdict 1 "$MERGED_VERIFIED")" "keep:contradicted-by-gate-failed-or-needs-fix"

echo ""
echo "═══════════════════════════════════════"
echo "PASS=$PASS FAIL=$FAIL"
echo "═══════════════════════════════════════"
[ "$FAIL" -eq 0 ]
