#!/usr/bin/env bash
# gate-guard-ga-v0gj8-direct-main-commit.selftest.sh — Drift-guard for ga-v0gj8.
#
# Bug: GAP-2's merge-search only ever looked for a branch matching one of the
# fix/feat/feature/refactor/docs/chore/test/crew name patterns, then checked
# whether THAT branch's tip was merged into origin/main. A fix committed
# DIRECTLY to main — no side branch ever created — matches none of those
# patterns, so GAP-2 read the empty branch search as "not delivered" even
# though origin/main already carries the fix.
#
# Confirmed live impact (2026-08-30T19:11–19:36Z, ga-4kxdc): a human/Mayor
# commit (dd2a1e9a3, subject "fix(ga-4kxdc): boot/deacon get
# provider=claude-headless (RC-off)") landed straight on origin/main with no
# branch at all. GAP-2 misread this as non-delivery, re-armed
# gate:needs-fix+gate:needs-remerge, Pilot escalated to gate:needs-human, an
# auto-unblock pass cleared that (also missing the commit), and Pilot
# dispatched a fresh builder to "fix" a bug already 24 minutes resolved.
#
# This harness (1) proves the underlying git-log mechanism actually resolves
# a direct-to-main commit by its subject line, including negative cases
# proving it rejects a commit that merely CITES the id in its body rather
# than being that bead's own delivery, and (2) drift-guards that the live
# guard source still carries this fallback check.
#
# ga-8z7jw gate-fix (2026-08-30): attempt 1's find_direct_commit (and the
# matching code in quality-gate-guard.sh) used a SINGLE git log --grep -E
# pass and trusted the ^-anchor to restrict matches to the commit's subject
# line. That claim is FALSE: git's --grep with -E anchors ^ at the start of
# EVERY line in the (possibly multi-paragraph) commit message, not just the
# first line. A reviewer proved this with a realistic trigger: GitHub's
# default squash-and-merge concatenates every squashed commit's own subject
# line into the resulting squash commit's BODY, so a squash-merged PR that
# ever contained a commit like "fix(<id>): wip" would mark that bead
# "delivered" on the squash commit even if the fix was never actually
# completed. The original BODY_ONLY_ID case below did NOT exercise this —
# its body text doesn't begin with the tag pattern at a line start, so it
# fails to match under EITHER single- or multi-line anchor semantics, which
# gave false confidence. SQUASH_BODY_ID below is the faithful repro, and
# find_direct_commit is now a two-pass check: --grep only narrows candidates,
# then each candidate's own subject (via `git log --format=%s`, which never
# contains embedded newlines) is re-tested before being trusted.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "── gate-guard GAP-2 direct-to-main-commit fallback drift-guard (ga-v0gj8) ──"

if [ ! -f "$GUARD" ]; then
  bad "quality-gate-guard.sh not found next to selftest at $GUARD"
  echo
  echo "── results: $PASS passed, $FAIL failed ──"
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gc-ga-v0gj8-selftest-XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

echo "── 1. mechanism proof: subject-anchored git log --grep on a real repo ──"

SRC="$WORK/src"
git init --quiet "$SRC"
git -C "$SRC" config user.email "selftest@gascity.local"
git -C "$SRC" config user.name  "selftest"
( cd "$SRC" && echo base > base.txt && git add base.txt && git commit --quiet -m base )
git -C "$SRC" branch -m main 2>/dev/null || true

FAKE_ID="ga-v0gj8fake"
ALT_ID="ga-v0gj8alt"
BODY_ONLY_ID="ga-v0gj8body"
NEVER_ID="ga-v0gj8never"
SQUASH_BODY_ID="ga-v0gj8squash"

# Positive case 1: direct-to-main commit, parens convention (the dominant
# one: 365/400 sampled commits on the live repo's real origin/main).
( cd "$SRC" && echo one > f1.txt && git add f1.txt \
  && git commit --quiet -m "fix(${FAKE_ID}): direct commit, no branch ever created" )

# Positive case 2: direct-to-main commit, the rarer parens-free convention
# ("fix bug <id>:" — 5/400 sampled, same template Pilot's dispatch-wisp
# titles use).
( cd "$SRC" && echo two > f2.txt && git add f2.txt \
  && git commit --quiet -m "fix bug ${ALT_ID}: also direct, no branch" )

# Negative case: id appears only in a commit BODY (a citation/tag, like the
# "(ga-0ndi)"-style inline references used throughout this guard's own
# history), never as the commit's own subject. Must NOT match — this is the
# precision the ^-anchor exists for.
( cd "$SRC" && echo three > f3.txt && git add f3.txt \
  && git commit --quiet -m "chore: unrelated cleanup

See also (${BODY_ONLY_ID}) for background, not this commit's own delivery." )

# Negative case 2 (the ACTUAL ga-8z7jw regression case): a squash-merge-
# shaped commit whose SUBJECT is unrelated, but whose BODY has a line that
# itself starts with a fix(<id>): tag — exactly what GitHub's default
# squash-and-merge produces when one of the squashed commits carried that
# subject. This id was never this commit's own delivery; it's just still
# sitting in the body. Unlike BODY_ONLY_ID above, this line DOES begin with
# the tag pattern at its own line-start, so it actually exercises the
# multi-line ^-anchor hazard.
( cd "$SRC" && echo four > f4.txt && git add f4.txt \
  && git commit --quiet -m "chore: unrelated subject line

fix(${SQUASH_BODY_ID}): this id-shaped line lives in the BODY, not the subject" )

MAIN_REF="$(git -C "$SRC" symbolic-ref --short HEAD)"

# The FIXED implementation: mirrors the two-pass check now in
# quality-gate-guard.sh. Pass 1 (--grep) is only a cheap candidate filter
# over full messages; pass 2 re-tests the same pattern against ONLY each
# candidate's own subject line before trusting it.
find_direct_commit() {
  local id="$1"
  local sha subj
  for sha in $(git -C "$SRC" log "$MAIN_REF" -E \
      --grep="^[a-z]+\(${id}\):" \
      --grep="^fix bug ${id}:" \
      --format=%H 2>/dev/null); do
    subj=$(git -C "$SRC" log --format=%s -n 1 "$sha" 2>/dev/null)
    if printf '%s\n' "$subj" | grep -Eq "^[a-z]+\(${id}\):|^fix bug ${id}:"; then
      printf '%s\n' "$sha"
      return 0
    fi
  done
  return 1
}

# The OLD (buggy) single-pass implementation from fix-attempt 1 — kept ONLY
# to prove the SQUASH_BODY_ID repro is real and that the fix above actually
# closes it, not as behavior under test.
find_direct_commit_single_pass_buggy() {
  local id="$1"
  git -C "$SRC" log "$MAIN_REF" -E \
    --grep="^[a-z]+\(${id}\):" \
    --grep="^fix bug ${id}:" \
    --format=%H -n 1 2>/dev/null
}

if [ -n "$(find_direct_commit "$FAKE_ID")" ]; then
  ok "finds the direct-to-main commit via the fix(<id>): convention"
else
  bad "did NOT find the direct-to-main commit via the fix(<id>): convention"
fi

if [ -n "$(find_direct_commit "$ALT_ID")" ]; then
  ok "finds the direct-to-main commit via the 'fix bug <id>:' convention"
else
  bad "did NOT find the direct-to-main commit via the 'fix bug <id>:' convention"
fi

if [ -z "$(find_direct_commit "$BODY_ONLY_ID")" ]; then
  ok "correctly ignores an id cited only in a commit BODY, not its subject (no false positive)"
else
  bad "REGRESSION: matched an id that only appears in a commit body — the ^-anchor is not restricting to the subject line"
fi

if [ -z "$(find_direct_commit "$NEVER_ID")" ]; then
  ok "correctly finds nothing for an id with no commit at all"
else
  bad "matched something for an id that has no commit anywhere (should be impossible)"
fi

echo "── 1b. regression proof: squash-merge body-only tag (ga-8z7jw) ──"

if [ -n "$(find_direct_commit_single_pass_buggy "$SQUASH_BODY_ID")" ]; then
  ok "repro confirmed: the OLD single-pass --grep DOES match a body-only line (this is the bug ga-8z7jw reported)"
else
  bad "could not reproduce the reported bug with the single-pass implementation — repro may be stale, re-verify against the reviewer's report before trusting the fix below"
fi

if [ -z "$(find_direct_commit "$SQUASH_BODY_ID")" ]; then
  ok "the FIXED two-pass find_direct_commit correctly rejects the same body-only line (ga-8z7jw closed)"
else
  bad "REGRESSION (ga-8z7jw): fixed find_direct_commit still matches a commit via a body-only line — git --grep's ^ anchors every line in the message, not just the subject"
fi

echo "── 2. drift-guard: live guard source still carries the fallback check ──"

if grep -Fq 'ga-v0gj8' "$GUARD"; then
  ok "guard source still references ga-v0gj8 (fallback block not silently dropped)"
else
  bad "guard source no longer mentions ga-v0gj8 — fallback block may have been removed"
fi

if grep -Fq -e '--grep="^[a-z]+\(${GAP2_TRY_ID}\):"' "$GUARD"; then
  ok "guard source still has the type(<id>): subject-anchored --grep pattern"
else
  bad "guard source is MISSING the type(<id>): subject-anchored --grep pattern (ga-v0gj8 regression)"
fi

if grep -Fq -e '--grep="^fix bug ${GAP2_TRY_ID}:"' "$GUARD"; then
  ok "guard source still has the 'fix bug <id>:' --grep pattern"
else
  bad "guard source is MISSING the 'fix bug <id>:' --grep pattern (ga-v0gj8 regression)"
fi

if grep -Fq 'GAP2_CAND_SUBJ' "$GUARD"; then
  ok "guard source performs the two-pass subject-only re-check (GAP2_CAND_SUBJ) before trusting a --grep candidate"
else
  bad "REGRESSION (ga-8z7jw): guard source no longer re-verifies candidates against their own subject line — may have reverted to the single-pass --grep bug"
fi

if grep -Fq 'GAP2_MERGE_VERIFIED" != "1"' "$GUARD"; then
  ok "fallback is still gated on the branch-search having failed first (does not shadow the primary check)"
else
  bad "could not confirm the fallback is gated behind GAP2_MERGE_VERIFIED != 1 — may now run unconditionally"
fi

echo "── 3. sanity: quality-gate-guard.sh still parses cleanly ──"
if bash -n "$GUARD" 2>/dev/null; then
  ok "quality-gate-guard.sh parses cleanly (bash -n)"
else
  bad "quality-gate-guard.sh FAILED bash -n syntax check"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
