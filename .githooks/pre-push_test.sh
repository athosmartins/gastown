#!/bin/bash
# Test suite for the pre-push hook integration branch guardrails.
# Creates temporary git repos to simulate push scenarios.
#
# Usage: bash .githooks/pre-push_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/pre-push"
PASS=0
FAIL=0
TMPDIR=""
DEFAULT_BRANCH=""

cleanup() {
  cd /tmp  # Ensure CWD exists before removing TMPDIR
  if [[ -n "$TMPDIR" && -d "$TMPDIR" ]]; then
    rm -rf "$TMPDIR"
  fi
  TMPDIR=""
}
trap cleanup EXIT

setup_repos() {
  TMPDIR=$(mktemp -d)
  # Create a bare "remote" repo
  git init --bare "$TMPDIR/remote.git" >/dev/null 2>&1
  # Clone it as the "local" repo
  git clone "$TMPDIR/remote.git" "$TMPDIR/local" >/dev/null 2>&1
  cd "$TMPDIR/local"
  git config user.email "test@test.com"
  git config user.name "Test"
  # Initial commit
  echo "init" > file.txt
  git add file.txt
  git commit -m "initial" >/dev/null 2>&1
  # Detect the default branch name (main or master)
  DEFAULT_BRANCH=$(git branch --show-current)
  git push origin "$DEFAULT_BRANCH" >/dev/null 2>&1
  # Set up origin/HEAD so hook can detect default branch
  git remote set-head origin "$DEFAULT_BRANCH" >/dev/null 2>&1
  # Copy the hook
  cp "$HOOK" "$TMPDIR/local/.git/hooks/pre-push"
  chmod +x "$TMPDIR/local/.git/hooks/pre-push"
}

run_hook() {
  # Simulate pre-push stdin: local_ref local_sha remote_ref remote_sha
  local local_ref=$1 local_sha=$2 remote_ref=$3 remote_sha=$4
  echo "$local_ref $local_sha $remote_ref $remote_sha" | bash "$HOOK" "origin" 2>&1
}

get_sha() {
  git rev-parse "$1"
}

assert_pass() {
  local test_name=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS: $test_name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $test_name (expected pass, got block)"
    FAIL=$((FAIL + 1))
  fi
}

assert_block() {
  local test_name=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  FAIL: $test_name (expected block, got pass)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $test_name"
    PASS=$((PASS + 1))
  fi
}

echo "=== Pre-push hook test suite ==="
echo ""

# Test 1: Normal push to default branch (no integration content)
echo "Test 1: Normal push to default branch (no integration content)"
setup_repos
cd "$TMPDIR/local"
remote_sha=$(get_sha HEAD)
echo "change1" >> file.txt
git add file.txt && git commit -m "normal change" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
assert_pass "Normal push allowed" run_hook "refs/heads/$DEFAULT_BRANCH" "$local_sha" "refs/heads/$DEFAULT_BRANCH" "$remote_sha"
cleanup

# Test 2: Push to polecat/* branch
echo "Test 2: Push to polecat/* branch"
setup_repos
cd "$TMPDIR/local"
git checkout -b polecat/worker1 >/dev/null 2>&1
echo "polecat work" >> file.txt
git add file.txt && git commit -m "polecat work" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
assert_pass "Polecat push allowed" run_hook "refs/heads/polecat/worker1" "$local_sha" "refs/heads/polecat/worker1" "0000000000000000000000000000000000000000"
cleanup

# Test 3: Push to integration/* branch
echo "Test 3: Push to integration/* branch"
setup_repos
cd "$TMPDIR/local"
git checkout -b integration/epic-1 >/dev/null 2>&1
echo "integration work" >> file.txt
git add file.txt && git commit -m "integration work" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
assert_pass "Integration branch push allowed" run_hook "refs/heads/integration/epic-1" "$local_sha" "refs/heads/integration/epic-1" "0000000000000000000000000000000000000000"
cleanup

# Test 4: Push to fix/* branch (crew-commit convention)
echo "Test 4: Push to fix/* branch"
setup_repos
cd "$TMPDIR/local"
git checkout -b fix/ga-12345-thing >/dev/null 2>&1
echo "fix work" >> file.txt
git add file.txt && git commit -m "fix work" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
assert_pass "fix/* push allowed" run_hook "refs/heads/fix/ga-12345-thing" "$local_sha" "refs/heads/fix/ga-12345-thing" "0000000000000000000000000000000000000000"
cleanup

# Test 5: Push to feat/* branch (crew-commit convention)
echo "Test 5: Push to feat/* branch"
setup_repos
cd "$TMPDIR/local"
git checkout -b feat/ga-12345-thing >/dev/null 2>&1
echo "feat work" >> file.txt
git add file.txt && git commit -m "feat work" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
assert_pass "feat/* push allowed" run_hook "refs/heads/feat/ga-12345-thing" "$local_sha" "refs/heads/feat/ga-12345-thing" "0000000000000000000000000000000000000000"
cleanup

# Test 6: Push to refactor/* branch (crew-commit convention)
echo "Test 6: Push to refactor/* branch"
setup_repos
cd "$TMPDIR/local"
git checkout -b refactor/ga-12345-thing >/dev/null 2>&1
echo "refactor work" >> file.txt
git add file.txt && git commit -m "refactor work" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
assert_pass "refactor/* push allowed" run_hook "refs/heads/refactor/ga-12345-thing" "$local_sha" "refs/heads/refactor/ga-12345-thing" "0000000000000000000000000000000000000000"
cleanup

# Test 7: Push to docs/* branch (crew-commit convention)
echo "Test 7: Push to docs/* branch"
setup_repos
cd "$TMPDIR/local"
git checkout -b docs/ga-12345-thing >/dev/null 2>&1
echo "docs work" >> file.txt
git add file.txt && git commit -m "docs work" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
assert_pass "docs/* push allowed" run_hook "refs/heads/docs/ga-12345-thing" "$local_sha" "refs/heads/docs/ga-12345-thing" "0000000000000000000000000000000000000000"
cleanup

# Test 8: Push to chore/* branch (crew-commit convention)
echo "Test 8: Push to chore/* branch"
setup_repos
cd "$TMPDIR/local"
git checkout -b chore/ga-12345-thing >/dev/null 2>&1
echo "chore work" >> file.txt
git add file.txt && git commit -m "chore work" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
assert_pass "chore/* push allowed" run_hook "refs/heads/chore/ga-12345-thing" "$local_sha" "refs/heads/chore/ga-12345-thing" "0000000000000000000000000000000000000000"
cleanup

# Test 9: Push to test/* branch (crew-commit convention)
echo "Test 9: Push to test/* branch"
setup_repos
cd "$TMPDIR/local"
git checkout -b test/ga-12345-thing >/dev/null 2>&1
echo "test work" >> file.txt
git add file.txt && git commit -m "test work" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
assert_pass "test/* push allowed" run_hook "refs/heads/test/ga-12345-thing" "$local_sha" "refs/heads/test/ga-12345-thing" "0000000000000000000000000000000000000000"
cleanup

# Test 10: Push to crew/<name> branch (single segment)
echo "Test 10: Push to crew/<name> branch"
setup_repos
cd "$TMPDIR/local"
git checkout -b crew/gastown-dog-1 >/dev/null 2>&1
echo "crew work" >> file.txt
git add file.txt && git commit -m "crew work" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
assert_pass "crew/<name> push allowed" run_hook "refs/heads/crew/gastown-dog-1" "$local_sha" "refs/heads/crew/gastown-dog-1" "0000000000000000000000000000000000000000"
cleanup

# Test 11: Push to crew/<name>/<bead> branch (nested, real-world shape)
echo "Test 11: Push to crew/<name>/<bead> branch (nested)"
setup_repos
cd "$TMPDIR/local"
git checkout -b crew/oracle/wa-cir23 >/dev/null 2>&1
echo "crew nested work" >> file.txt
git add file.txt && git commit -m "crew nested work" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
assert_pass "crew/<name>/<bead> push allowed" run_hook "refs/heads/crew/oracle/wa-cir23" "$local_sha" "refs/heads/crew/oracle/wa-cir23" "0000000000000000000000000000000000000000"
cleanup

# Test 12: Push to a genuinely unexpected branch name (blocked, no upstream)
echo "Test 12: Push to arbitrary unexpected branch name"
setup_repos
cd "$TMPDIR/local"
git checkout -b some-random-branch >/dev/null 2>&1
echo "random" >> file.txt
git add file.txt && git commit -m "random" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
assert_block "Arbitrary branch name still blocked (no upstream)" run_hook "refs/heads/some-random-branch" "$local_sha" "refs/heads/some-random-branch" "0000000000000000000000000000000000000000"
cleanup

# Test 13: Push to feature/* without upstream remote (blocked — NOT a crew-commit prefix)
echo "Test 13: Push to feature/* without upstream remote"
setup_repos
cd "$TMPDIR/local"
git checkout -b feature/thing >/dev/null 2>&1
echo "feature" >> file.txt
git add file.txt && git commit -m "feature" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
assert_block "Feature branch blocked (no upstream)" run_hook "refs/heads/feature/thing" "$local_sha" "refs/heads/feature/thing" "0000000000000000000000000000000000000000"
cleanup

# Test 14: Push to feature/* with upstream remote (allowed)
echo "Test 14: Push to feature/* with upstream remote"
setup_repos
cd "$TMPDIR/local"
git remote add upstream "$TMPDIR/remote.git" >/dev/null 2>&1
git checkout -b feature/thing >/dev/null 2>&1
echo "feature" >> file.txt
git add file.txt && git commit -m "feature" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
assert_pass "Feature branch allowed (upstream exists)" run_hook "refs/heads/feature/thing" "$local_sha" "refs/heads/feature/thing" "0000000000000000000000000000000000000000"
cleanup

# Test 15: Push to default branch with integration merge (no env var) — BLOCKED
echo "Test 15: Push to default branch with integration merge (no env var)"
setup_repos
cd "$TMPDIR/local"
# Create and push an integration branch
git checkout -b integration/epic-2 >/dev/null 2>&1
echo "epic work" >> file.txt
git add file.txt && git commit -m "epic work" >/dev/null 2>&1
git push origin integration/epic-2 >/dev/null 2>&1
# Fetch so refs/remotes/origin/integration/epic-2 exists
git fetch origin >/dev/null 2>&1
# Back to default branch, merge the integration branch
git checkout "$DEFAULT_BRANCH" >/dev/null 2>&1
remote_sha=$(get_sha HEAD)
git merge --no-ff integration/epic-2 -m "land integration" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
unset GT_INTEGRATION_LAND 2>/dev/null || true
assert_block "Integration merge blocked (no env var)" run_hook "refs/heads/$DEFAULT_BRANCH" "$local_sha" "refs/heads/$DEFAULT_BRANCH" "$remote_sha"
cleanup

# Test 16: Push to default branch with integration merge + GT_INTEGRATION_LAND=1 — ALLOWED
echo "Test 16: Push to default branch with integration merge + GT_INTEGRATION_LAND=1"
setup_repos
cd "$TMPDIR/local"
git checkout -b integration/epic-3 >/dev/null 2>&1
echo "epic work" >> file.txt
git add file.txt && git commit -m "epic work" >/dev/null 2>&1
git push origin integration/epic-3 >/dev/null 2>&1
git fetch origin >/dev/null 2>&1
git checkout "$DEFAULT_BRANCH" >/dev/null 2>&1
remote_sha=$(get_sha HEAD)
git merge --no-ff integration/epic-3 -m "land integration" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
GT_INTEGRATION_LAND=1 assert_pass "Integration merge allowed (env var set)" run_hook "refs/heads/$DEFAULT_BRANCH" "$local_sha" "refs/heads/$DEFAULT_BRANCH" "$remote_sha"
cleanup

# Test 17: Push to default branch with non-integration merge — allowed
echo "Test 17: Push to default branch with non-integration merge"
setup_repos
cd "$TMPDIR/local"
# Create a local feature branch and merge it (no need to push to origin)
git checkout -b feature/normal >/dev/null 2>&1
echo "feature work" >> file.txt
git add file.txt && git commit -m "feature work" >/dev/null 2>&1
git checkout "$DEFAULT_BRANCH" >/dev/null 2>&1
remote_sha=$(get_sha HEAD)
git merge --no-ff feature/normal -m "merge feature" >/dev/null 2>&1
local_sha=$(get_sha HEAD)
assert_pass "Non-integration merge allowed" run_hook "refs/heads/$DEFAULT_BRANCH" "$local_sha" "refs/heads/$DEFAULT_BRANCH" "$remote_sha"
cleanup

# Test 18: Tag push — allowed
echo "Test 18: Tag push"
setup_repos
cd "$TMPDIR/local"
local_sha=$(get_sha HEAD)
assert_pass "Tag push allowed" run_hook "refs/tags/v1.0.0" "$local_sha" "refs/tags/v1.0.0" "0000000000000000000000000000000000000000"
cleanup

# Test 19: Push to default branch with fast-forward integration merge (no merge commit) — BLOCKED
echo "Test 19: Push to default branch with ff integration merge (no merge commit)"
setup_repos
cd "$TMPDIR/local"
git checkout -b integration/epic-4 >/dev/null 2>&1
echo "epic ff work" >> file.txt
git add file.txt && git commit -m "epic ff work" >/dev/null 2>&1
git push origin integration/epic-4 >/dev/null 2>&1
git fetch origin >/dev/null 2>&1
git checkout "$DEFAULT_BRANCH" >/dev/null 2>&1
remote_sha=$(get_sha HEAD)
git merge --ff-only integration/epic-4 >/dev/null 2>&1
local_sha=$(get_sha HEAD)
unset GT_INTEGRATION_LAND 2>/dev/null || true
assert_block "FF integration merge blocked" run_hook "refs/heads/$DEFAULT_BRANCH" "$local_sha" "refs/heads/$DEFAULT_BRANCH" "$remote_sha"
cleanup

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
