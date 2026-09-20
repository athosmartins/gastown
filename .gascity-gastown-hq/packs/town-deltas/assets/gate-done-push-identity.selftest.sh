#!/usr/bin/env bash
# gate-done-push-identity.selftest.sh — Prove /gate-done's Step 1 push
# verification is fail-closed on a REJECTED push, even when the branch
# already exists on origin from a prior push.
#
# Bug ga-d3n094: Step 1 ran `git push origin HEAD` without checking its exit
# code, then "verified" the push only via `git ls-remote --heads origin
# $BRANCH` being non-empty — existence, not identity. On a re-anchor/resubmit
# (the branch is already on origin from an EARLIER push), a push rejected by
# a guard (e.g. a pre-push hook) leaves origin's ref at the OLD sha, and the
# existence check still passes: "Push verified" printed and a marker would
# be created pointing the gate at stale code (measured live: batista-wa,
# 2026-09-18, wa-q0crq re-anchor, Guard #5c changelog-version-collision).
#
# This harness extracts the ACTUAL Step 1 bash block from gate-done.md — never
# a hand-copied duplicate — and runs it against a real fixture git repo plus a
# bare "origin", so a future edit to that block is tested as it really reads.
#
# Exit 0 iff every assertion holds.

set -uo pipefail  # no -e: we deliberately provoke non-zero exits and must capture them

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_DONE_MD="${GATE_DONE_MD:-$SELF_DIR/../../../commands/gate-done.md}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

if [ ! -f "$GATE_DONE_MD" ]; then
  echo "FATAL: gate-done.md not found at $GATE_DONE_MD"
  exit 1
fi

# ── Extract the REAL Step 1 bash block (drift-safe: never a hand copy) ────────
STEP1_SCRIPT=$(awk '
  /^## Step 1: Push your branch/ { found=1; next }
  found && /^```bash/ { incode=1; next }
  found && incode && /^```/ { exit }
  found && incode { print }
' "$GATE_DONE_MD")

if [ -z "$STEP1_SCRIPT" ] || ! printf '%s' "$STEP1_SCRIPT" | grep 'git push origin HEAD' >/dev/null; then
  echo "FATAL: could not extract Step 1's bash block from $GATE_DONE_MD"
  echo "  (heading '## Step 1: Push your branch' or its \`\`\`bash fence may have moved)."
  exit 1
fi

FIXTURE_ROOT=$(mktemp -d)
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

STEP1_FILE="$FIXTURE_ROOT/step1.sh"
printf '%s\n' "$STEP1_SCRIPT" > "$STEP1_FILE"

ORIGIN="$FIXTURE_ROOT/origin.git"
WORK="$FIXTURE_ROOT/work"

git init --bare -q -b main "$ORIGIN" || { echo "FATAL: could not init fixture bare origin"; exit 1; }
git init -q -b main "$WORK" || { echo "FATAL: could not init fixture work repo"; exit 1; }
git -C "$WORK" config user.email "selftest@example.com"
git -C "$WORK" config user.name "gate-done-push-identity selftest"
git -C "$WORK" remote add origin "$ORIGIN"

echo "init" > "$WORK/README.md"
git -C "$WORK" add README.md
git -C "$WORK" commit -q -m "init"
git -C "$WORK" push -q origin main || { echo "FATAL: fixture setup push (main) failed"; exit 1; }

BRANCH_NAME="fix/ga-test0001-demo"
git -C "$WORK" checkout -q -b "$BRANCH_NAME"
echo "first" >> "$WORK/README.md"
git -C "$WORK" commit -q -am "$BRANCH_NAME: first push"
git -C "$WORK" push -q origin "$BRANCH_NAME" || { echo "FATAL: fixture setup push (branch, 1st) failed"; exit 1; }
OLD_SHA=$(git -C "$WORK" rev-parse HEAD)
REMOTE_SHA_BEFORE=$(git -C "$ORIGIN" rev-parse "refs/heads/$BRANCH_NAME" 2>/dev/null || echo "")
if [ -z "$OLD_SHA" ] || [ "$REMOTE_SHA_BEFORE" != "$OLD_SHA" ]; then
  echo "FATAL: fixture did not reach the expected pre-state (branch on origin at OLD_SHA)"
  exit 1
fi

echo "── 1. rejected push on a branch that already exists on origin (ga-d3n094) ──"

# Simulate a resubmit: a new local commit, and a guard that rejects the push
# (e.g. Guard #5c changelog-version-collision in the real incident).
echo "second" >> "$WORK/README.md"
git -C "$WORK" commit -q -am "$BRANCH_NAME: second push (resubmit)"
cat > "$WORK/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
echo "pre-push: rejecting (selftest simulated guard)" >&2
exit 1
HOOK
chmod +x "$WORK/.git/hooks/pre-push"

STEP1_OUT=$(cd "$WORK" && bash "$STEP1_FILE" 2>&1)
STEP1_RC=$?

if [ "$STEP1_RC" -ne 0 ]; then
  ok "Step 1 aborted (exit $STEP1_RC) when the push was rejected"
else
  bad "Step 1 exited 0 despite the push being rejected by the pre-push hook"
fi

if printf '%s' "$STEP1_OUT" | grep "Push verified" >/dev/null; then
  bad "Step 1 printed 'Push verified' even though the push was rejected — output:\n$STEP1_OUT"
else
  ok "Step 1 did not claim 'Push verified' on a rejected push"
fi

REMOTE_SHA_AFTER=$(git -C "$ORIGIN" rev-parse "refs/heads/$BRANCH_NAME" 2>/dev/null || echo "")
eq "origin's branch is still at the OLD sha (rejected push never landed)" "$REMOTE_SHA_AFTER" "$OLD_SHA"

echo "── 2. happy path: a clean push still verifies (no regression) ──"

rm -f "$WORK/.git/hooks/pre-push"
HAPPY_BRANCH="fix/ga-test0002-happy"
git -C "$WORK" checkout -q -b "$HAPPY_BRANCH" main
echo "happy" >> "$WORK/README.md"
git -C "$WORK" commit -q -am "$HAPPY_BRANCH: normal push"
HAPPY_SHA=$(git -C "$WORK" rev-parse HEAD)

HAPPY_OUT=$(cd "$WORK" && bash "$STEP1_FILE" 2>&1)
HAPPY_RC=$?

if [ "$HAPPY_RC" -eq 0 ]; then
  ok "Step 1 succeeded (exit 0) on a clean push"
else
  bad "Step 1 failed (exit $HAPPY_RC) on a clean push with nothing rejecting it — output:\n$HAPPY_OUT"
fi

if printf '%s' "$HAPPY_OUT" | grep -F "Push verified: $HAPPY_BRANCH present on origin at $HAPPY_SHA" >/dev/null; then
  ok "Step 1 printed the expected verified line with the correct sha"
else
  bad "Step 1 did not print the expected verified line — output:\n$HAPPY_OUT"
fi

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
