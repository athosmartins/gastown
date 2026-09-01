#!/usr/bin/env bash
# gate-done-merged-branch-guard.selftest.sh (ga-us6fc)
#
# Proves /gate-done refuses to create a ready-for-gate marker when the
# submitting branch's HEAD is ALREADY an ancestor of a freshly-fetched
# origin/main — i.e. the diff about to be submitted for review is EMPTY.
#
# Root bug (ga-us6fc, filed by ps-worker after a live incident on ps-i9jf,
# property_scrapers, 2026-08-31): a resumed session's local origin/main ref
# was stale (last fetched before its own prior incarnation's fix had
# merged), so ITS worktree diff check looked non-empty even though the
# branch had already fully merged. Step 2 DOES `git fetch origin main
# --quiet` and compute BASE_COMMIT=$(git rev-parse origin/main) — a FRESH
# value — but never compared it against the branch's own HEAD. Result:
# BASE_COMMIT == HEAD, the diff about to be reviewed was empty, and
# gate-done still happily created a marker (ga-tcadu) + tracking bead
# (ga-drtty), parking a zero-line diff for a reviewer to eventually spend a
# session reviewing nothing.
#
# Covers:
#   (A) branch fully merged into origin/main (HEAD is an ancestor, after a
#       fresh fetch) -> guard fires: exits 1, prints an explanatory error.
#   (B) branch has a real, unmerged commit ahead of origin/main (the golden
#       path) -> guard does NOT fire, execution proceeds past the check.
#   (C) source drift-guard: gate-done.md resolves identically from all 3
#       paths a caller might read it from. Two are independent real files
#       hand-synced with no generator (internal/templates/commands/bodies/
#       and .gascity-gastown-hq/commands/ — confirmed via `git log` on each
#       path separately: real commit history on both, not one file plus a
#       redirect); the third, .claude/commands/gate-done.md, is a git-mode
#       120000 symlink to the .gascity-gastown-hq/commands/ copy, so it
#       tracks that one automatically. A fix landing in only one of the two
#       REAL files silently ships a partial deploy — the symlink side would
#       still show the fix (misleadingly, since it just follows whichever
#       real file it points to), while a caller reading the OTHER real path
#       gets stale behavior.
#
# We extract and EXECUTE the real shipped bash block (not a hand-replica):
# `git merge-base --is-ancestor` is a single git primitive, not town-specific
# derivation logic, so there is nothing meaningful to reimplement — running
# the real block against a real temp git sandbox is both simpler and
# strictly more faithful than copying it.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# gate-done.md resolution (priority order, mirrors sibling selftests):
#   1. commands/ relative to pack root (deployed HQ context)
#   2. internal/templates/.../bodies/ (worktree / binary-repo context)
#   3. local sibling (manual copy / test fixture)
GATE_DONE="$SELF_DIR/../../../commands/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/../../../internal/templates/commands/bodies/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/gate-done.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

command -v git >/dev/null 2>&1 || { echo "git required"; exit 2; }
[ -f "$GATE_DONE" ] || { echo "FATAL: gate-done.md not found (tried commands/, internal/templates/commands/bodies/, sibling)"; exit 1; }
echo "  source: $GATE_DONE"

# Extract the merge-check block: from the line starting the guard's `if` to
# its matching `fi`. The block is flat (no nested if/fi), so the first `fi`
# line after the anchor is the correct terminator.
extract_guard_block() {
  awk '
    /^if git merge-base --is-ancestor HEAD origin\/main/ { found=1 }
    found { print }
    found && /^fi$/ { exit }
  ' "$1"
}
GUARD_SNIPPET="$(extract_guard_block "$GATE_DONE")"
# Deliberately NOT gated on GUARD_SNIPPET being non-empty: pre-fix, this is
# "", `eval ""` is a harmless no-op, and the (A)/(B) assertions below then
# correctly observe "guard never fired" — which is exactly the bug.

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ORIGIN="$TMPROOT/origin.git"
git init --quiet --bare "$ORIGIN"

BOOT="$TMPROOT/bootstrap"
git init --quiet "$BOOT"
git -C "$BOOT" remote add origin "$ORIGIN"
git -C "$BOOT" config user.email "selftest@gascity.local"
git -C "$BOOT" config user.name "selftest"
git -C "$BOOT" checkout --quiet -b main
echo "seed" > "$BOOT/seed.txt"
git -C "$BOOT" add seed.txt
git -C "$BOOT" commit --quiet -m "seed"
git -C "$BOOT" push --quiet origin main
# Pin the bare repo's HEAD explicitly so a clone reliably checks out "main"
# regardless of this machine's init.defaultBranch setting.
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main

seed_clone() {
  local dir="$1"
  git clone --quiet "$ORIGIN" "$dir"
  git -C "$dir" config user.email "selftest@gascity.local"
  git -C "$dir" config user.name "selftest"
}

# run_guard <repo-dir>: replicates the guard's own precondition (a fresh
# `git fetch origin main` and $BRANCH already being set, both true at this
# point in the real Step 2) then executes the extracted block.
run_guard() {
  local repo="$1"
  ( cd "$repo" \
    && git fetch origin main --quiet 2>/dev/null \
    && BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) \
    && eval "$GUARD_SNIPPET" )
}

echo "── (A) branch already fully merged into origin/main — must REFUSE ──"
ALREADY_MERGED="$TMPROOT/already-merged"
seed_clone "$ALREADY_MERGED"
git -C "$ALREADY_MERGED" checkout --quiet -b fix/already-merged
# No new commits: HEAD IS origin/main's tip — the exact "resumed session,
# stale local ref, branch already merged in a prior incarnation" shape.
OUT_A="$(run_guard "$ALREADY_MERGED" 2>&1)"; RC_A=$?
if [ "$RC_A" -eq 1 ]; then
  ok "(A1) guard exits 1 when HEAD is already an ancestor of origin/main"
else
  bad "(A1) guard did NOT exit 1 for an already-merged branch (rc=$RC_A) — ga-us6fc bug reproduces"
fi
case "$OUT_A" in
  *"already"*"merged"*|*"nothing to review"*|*"Marker NOT created"*)
    ok "(A2) guard prints an explanatory error, not a silent exit" ;;
  *)
    bad "(A2) guard produced no recognizable error text: [$OUT_A]" ;;
esac

echo "── (B) branch has a real unmerged commit — must NOT refuse ──"
GOLDEN="$TMPROOT/golden-path"
seed_clone "$GOLDEN"
git -C "$GOLDEN" checkout --quiet -b fix/golden-path
echo "real change" > "$GOLDEN/newfile.txt"
git -C "$GOLDEN" add newfile.txt
git -C "$GOLDEN" commit --quiet -m "fix: real change ahead of origin/main"
OUT_B="$(run_guard "$GOLDEN" 2>&1)"; RC_B=$?
if [ "$RC_B" -eq 0 ]; then
  ok "(B1) guard does NOT fire on a real unmerged commit (golden path preserved)"
else
  bad "(B1) guard WRONGLY fired on a real unmerged commit (rc=$RC_B, out=[$OUT_B]) — would block legitimate submissions"
fi

echo "── (C) source drift-guard: all 3 tracked copies stay byte-identical ──"
REPO_ROOT="$(cd "$SELF_DIR/../../../.." && pwd)"
COPY1="$REPO_ROOT/internal/templates/commands/bodies/gate-done.md"
COPY2="$REPO_ROOT/.gascity-gastown-hq/commands/gate-done.md"
COPY3="$REPO_ROOT/.claude/commands/gate-done.md"
if [ -f "$COPY1" ] && [ -f "$COPY2" ] && [ -f "$COPY3" ]; then
  H1=$(shasum -a 256 "$COPY1" | cut -d' ' -f1)
  H2=$(shasum -a 256 "$COPY2" | cut -d' ' -f1)
  H3=$(shasum -a 256 "$COPY3" | cut -d' ' -f1)
  if [ "$H1" = "$H2" ] && [ "$H2" = "$H3" ]; then
    ok "(C) all 3 tracked gate-done.md copies are byte-identical"
  else
    bad "(C) tracked gate-done.md copies have DIVERGED (internal/templates=$H1, .gascity-gastown-hq/commands=$H2, .claude/commands=$H3) — this repo hand-syncs 3 copies with no generator; a fix landing in only one silently ships a partial deploy"
  fi
else
  echo "  (skip C: not all 3 copies found under REPO_ROOT=$REPO_ROOT)"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
