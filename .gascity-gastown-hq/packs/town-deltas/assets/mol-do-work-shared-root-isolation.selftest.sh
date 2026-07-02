#!/usr/bin/env bash
# mol-do-work-shared-root-isolation.selftest.sh (ga-xau4z)
#
# Proves mol-do-work.toml's branch-creation step isolates into a dedicated
# git worktree when CWD is the repo's shared MAIN worktree, instead of
# branching in place — preventing concurrent pool-worker sessions on the same
# shared checkout from sweeping up each other's uncommitted edits.
#
# Root bug (ga-xau4z, filed by gastown.dog-1): a Dog fixing an HQ/gascity bug
# edits+commits directly in the shared /Users/athos/gt checkout (the ONLY
# working tree its session has). A concurrent Dog doing the same thing can
# run `git add <file> && git commit` while the first Dog's unrelated edit to
# that same file is still sitting uncommitted on disk — the commit sweeps
# both hunks in, attributed entirely to the second Dog's bead/message.
# Evidence: commit 188052fb0 ("framework-dog-exempt", ga-evjs2/ga-tgo7q)
# carries the unrelated ga-sndpm ownership-guard fix in its diff.
#
# `mol-do-work.toml` is the formula EVERY pool worker runs for "fix bug ->
# gate-done" (confirmed via the bd comment on ga-xau4z itself: "Builder
# doctrine: fix bug -> /gate-done -> autonomous gate+delivery -> bead
# closed"). Its branch-creation step did a plain in-place `git checkout -B
# ... origin/main` with no worktree isolation. The one existing isolation
# guard in this codebase (crew-commit SKILL.md's "Rig-Root Isolation Guard")
# can never fire for HQ/gascity: it matches CWD's git toplevel against the
# EXACT registered rig path, but gascity's registered path
# (.gascity-gastown-hq) is a SUBDIR of the git toplevel (/Users/athos/gt),
# never equal to it — and mol-do-work.toml doesn't call it anyway.
#
# This test extracts the REAL guard block from the deployed formula (between
# sentinel markers) and executes it against real throwaway git repos, so it
# cannot silently drift from the deployed behavior the way a hand-copied
# replica could.
#
# gate-review history: attempt 1 (crew/gastown-dog-1/ga-xau4z, 459d980d8)
# FAILED review with two blocking issues, both now covered by this file:
#   1. Both `worktree add ... -b "$BRANCH"` attempts fail whenever $BRANCH
#      already exists as an orphaned local ref (worktree dir removed without
#      `git worktree remove` — e.g. reaped) — with no error handling, the
#      guard set ISOLATED=1 anyway, skipped the plain-checkout fallback, and
#      silently left the agent editing+committing on the shared root's
#      CURRENT branch. See scenario (I).
#   2. The reuse path (`[ -e "$WT/.git" ]`) just cd'd into the existing
#      worktree with no resync against origin/main, silently dropping the
#      "always fresh" guarantee the old unconditional
#      `git checkout -B "$BRANCH" origin/main` gave on every invocation. See
#      scenario (J). Scenario (K) proves the fix for this (a forced
#      `checkout -B` inside the worktree) does not destroy a resumed
#      session's non-conflicting uncommitted WIP in the process — the whole
#      point of ga-xau4z is protecting uncommitted WIP, not just relocating
#      the hazard.
#
# Covers:
#   (A)  Guard fires + isolates when run from the shared MAIN worktree
#   (B)  Shared root's branch/HEAD are UNCHANGED after the guard runs
#   (C)  New worktree lands on the expected crew/<name>/<bead> branch
#   (D)  Guard is a NO-OP (silent, branch unchanged) inside an
#        already-isolated (linked) worktree
#   (E)  Re-running the guard for the same bead+agent REUSES the existing
#        worktree instead of failing on "branch already exists"
#   (I)  Re-running the guard when the worktree DIR was removed (e.g.
#        reaped) but the branch ref survives recovers cleanly instead of
#        silently no-op'ing at the shared root (gate blocking issue 1)
#   (G)  Guard run from a NESTED SUBDIR of the shared root (the real HQ
#        topology: a Dog's CWD is .gascity-gastown-hq, a subdir of the git
#        toplevel /Users/athos/gt) still isolates correctly, and nests the
#        new worktree under that starting subdir — not git's toplevel
#   (H)  Guard is a safe no-op when CWD is not inside a git repo at all
#   (J)  A reused worktree that is BEHIND origin/main gets reset to the
#        latest tip (gate blocking issue 2)
#   (K)  Non-conflicting uncommitted WIP in a reused worktree survives the
#        origin/main refresh from (J)
#   (F)  Source drift-guards: deployed formula still contains the sentinel
#        markers, the git-common-dir topology check, the established
#        .gc-worktrees/ convention, and the orphaned-branch recovery path
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# mol-do-work.toml resolution (priority order):
#   1. formulas/ relative to HQ root (deployed, tracked source)
#   2. .beads/formulas/ (local runtime mirror — .beads/ is gitignored, but
#      may be the only materialized copy in some contexts)
FORMULA="$SELF_DIR/../../../formulas/mol-do-work.toml"
[ -f "$FORMULA" ] || FORMULA="$SELF_DIR/../../../.beads/formulas/mol-do-work.toml"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

command -v git >/dev/null 2>&1 || { echo "git required"; exit 2; }

echo "mol-do-work-shared-root-isolation.selftest.sh (ga-xau4z)"
echo "  source: $FORMULA"
echo

if [ ! -f "$FORMULA" ]; then
  bad "formula file not found at $FORMULA"
  echo; echo "  PASS=$PASS  FAIL=$FAIL"; exit 1
fi

# ── Extract the REAL guard block from the deployed formula ───────────────────
GUARD_SRC=$(sed -n '/=== MOL-DO-WORK ISOLATION GUARD BEGIN/,/=== MOL-DO-WORK ISOLATION GUARD END/p' "$FORMULA")

if [ -z "$GUARD_SRC" ]; then
  bad "(F0) isolation guard sentinels not found in $FORMULA — fix not deployed, or markers renamed"
  echo; echo "  PASS=$PASS  FAIL=$FAIL"; exit 1
fi
ok "(F0) isolation guard block found in deployed formula"

# ── Build a throwaway origin + shared-root clone to test against ─────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git init -q -b main --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/shared-root" 2>/dev/null
echo "test repo" > "$TMP/shared-root/README.md"
git -C "$TMP/shared-root" add README.md
git -C "$TMP/shared-root" -c user.email=test@test -c user.name=test commit -q -m init
git -C "$TMP/shared-root" push -q origin main

# run_guard <dir> <bead> <agent> — runs the extracted guard in a SUBSHELL (so
# its `exit 1` on invariant failure can't kill this test script), with the
# same variables mol-do-work.toml has already computed by the time the guard
# block runs (SAFE_NAME, BRANCH). The trailing PWD_AFTER echo only runs if
# the guard did NOT `exit 1` inside the subshell — its absence from output is
# itself a signal the guard fatally aborted.
run_guard() {
  local dir="$1" bead="$2" agent="$3"
  ( cd "$dir" && SAFE_NAME="$agent" BRANCH="crew/${agent}/${bead}" \
      eval "$GUARD_SRC"; echo "PWD_AFTER=$(pwd)" )
}

# ── (A)+(B)+(C): guard fires from the shared root, isolates, root untouched ──
BEFORE_HEAD="$(git -C "$TMP/shared-root" rev-parse HEAD)"
OUT=$(run_guard "$TMP/shared-root" "tt-bead1" "tester" 2>&1)
NEWDIR=$(printf '%s\n' "$OUT" | grep '^PWD_AFTER=' | tail -1 | cut -d= -f2-)

[ -n "$NEWDIR" ] && [ "$NEWDIR" != "$TMP/shared-root" ] \
  && ok "(A) guard moved CWD out of the shared root (now: $NEWDIR)" \
  || bad "(A) guard did NOT isolate — CWD stayed at shared root. Output:
$OUT"

AFTER_BRANCH="$(git -C "$TMP/shared-root" branch --show-current)"
[ "$AFTER_BRANCH" = "main" ] \
  && ok "(B) shared root still on main after guard ran (got: $AFTER_BRANCH)" \
  || bad "(B) shared root branch changed — expected main, got: $AFTER_BRANCH"

AFTER_HEAD="$(git -C "$TMP/shared-root" rev-parse HEAD)"
[ "$AFTER_HEAD" = "$BEFORE_HEAD" ] \
  && ok "(B2) shared root HEAD unchanged"  \
  || bad "(B2) shared root HEAD moved: $BEFORE_HEAD -> $AFTER_HEAD"

if [ -n "$NEWDIR" ] && [ -d "$NEWDIR" ]; then
  NEW_BRANCH="$(git -C "$NEWDIR" branch --show-current)"
  [ "$NEW_BRANCH" = "crew/tester/tt-bead1" ] \
    && ok "(C) new worktree on expected branch crew/tester/tt-bead1 (got: $NEW_BRANCH)" \
    || bad "(C) new worktree branch mismatch — expected crew/tester/tt-bead1, got: $NEW_BRANCH"
else
  bad "(C) new worktree directory does not exist: $NEWDIR"
fi

# ── (D): guard is a no-op inside an ALREADY isolated worktree ────────────────
if [ -n "$NEWDIR" ] && [ -d "$NEWDIR" ]; then
  BEFORE2="$(git -C "$NEWDIR" branch --show-current)"
  OUT2=$(run_guard "$NEWDIR" "tt-bead1" "tester" 2>&1)
  AFTER2="$(git -C "$NEWDIR" branch --show-current)"
  [ "$BEFORE2" = "$AFTER2" ] \
    && ok "(D) guard no-op inside an already-isolated worktree (branch unchanged: $AFTER2)" \
    || bad "(D) guard changed branch inside an isolated worktree: $BEFORE2 -> $AFTER2"
  printf '%s\n' "$OUT2" | grep -q "ISOLATION GUARD:" \
    && bad "(D2) guard printed the isolation banner even though already isolated" \
    || ok "(D2) guard stayed silent (no isolation banner) when already isolated"
fi

# ── (E): re-running from the shared root for the SAME bead+agent REUSES ──────
OUT3=$(run_guard "$TMP/shared-root" "tt-bead1" "tester" 2>&1)
NEWDIR3=$(printf '%s\n' "$OUT3" | grep '^PWD_AFTER=' | tail -1 | cut -d= -f2-)
FAILED_ADD=$(printf '%s\n' "$OUT3" | grep -c "already exists" || true)
[ "$NEWDIR3" = "$NEWDIR" ] \
  && ok "(E) re-run for same bead+agent reused the existing worktree ($NEWDIR3)" \
  || bad "(E) re-run landed in a DIFFERENT worktree — expected reuse of $NEWDIR, got $NEWDIR3"
[ "$FAILED_ADD" -eq 0 ] \
  && ok "(E2) reuse path did not attempt (and fail) a redundant 'git worktree add'" \
  || bad "(E2) reuse path fell through to a failing worktree add ($FAILED_ADD 'already exists' errors)"

# ── (I): worktree DIR removed (e.g. reaped) but the branch ref survives ──────
# Gate blocking issue 1: extracting the real guard against this exact
# topology showed BOTH `worktree add ... -b` attempts fail with "a branch
# named ... already exists" (neither can create $BRANCH fresh), `cd "$WT"`
# then silently fails (directory gone, no `set -e` anywhere), yet ISOLATED=1
# was still set unconditionally, the "shared root untouched" invariant
# trivially passed (nothing had touched it), and a misleading "Isolated
# worktree ready" banner printed the SHARED ROOT's own path. Net effect: the
# agent was left to edit+commit directly on the shared root's checked-out
# branch — reintroducing the exact hazard ga-xau4z exists to prevent.
OUT4=$(run_guard "$TMP/shared-root" "tt-bead4" "tester4" 2>&1)
NEWDIR4=$(printf '%s\n' "$OUT4" | grep '^PWD_AFTER=' | tail -1 | cut -d= -f2-)
rm -rf "$NEWDIR4"

OUT5=$(run_guard "$TMP/shared-root" "tt-bead4" "tester4" 2>&1)
NEWDIR5=$(printf '%s\n' "$OUT5" | grep '^PWD_AFTER=' | tail -1 | cut -d= -f2-)

printf '%s\n' "$OUT5" | grep -q '^PWD_AFTER=' \
  && ok "(I0) guard completed without a FATAL abort when the worktree dir was gone" \
  || bad "(I0) guard fatally aborted recovering an orphaned branch ref. Output:
$OUT5"
[ "$NEWDIR5" = "$NEWDIR4" ] \
  && ok "(I) orphaned-branch re-run recreated the SAME worktree path ($NEWDIR5)" \
  || bad "(I) orphaned-branch re-run landed somewhere unexpected — expected $NEWDIR4, got $NEWDIR5"
[ -n "$NEWDIR5" ] && [ "$NEWDIR5" != "$TMP/shared-root" ] && [ -d "$NEWDIR5" ] \
  && ok "(I2) recovered worktree directory actually exists and is not the shared root" \
  || bad "(I2) guard did NOT truly isolate after recovery — CWD/dir wrong: '$NEWDIR5'"
if [ -n "$NEWDIR5" ] && [ -d "$NEWDIR5" ]; then
  NEW_BRANCH5="$(git -C "$NEWDIR5" branch --show-current)"
  [ "$NEW_BRANCH5" = "crew/tester4/tt-bead4" ] \
    && ok "(I3) recovered worktree is on the expected branch crew/tester4/tt-bead4 (got: $NEW_BRANCH5)" \
    || bad "(I3) recovered worktree branch mismatch — got: $NEW_BRANCH5"
fi
ROOT_BRANCH_I="$(git -C "$TMP/shared-root" branch --show-current)"
[ "$ROOT_BRANCH_I" = "main" ] \
  && ok "(I4) shared root still on main after orphaned-branch recovery" \
  || bad "(I4) shared root branch changed after orphaned-branch recovery: $ROOT_BRANCH_I"

# ── (G): guard run from a NESTED SUBDIR of the shared root (real HQ topology) ─
# A Dog's actual CWD is .gascity-gastown-hq, a SUBDIR of the git toplevel
# (/Users/athos/gt) — not the toplevel itself. The guard must still detect
# the shared-root topology from there, and nest the new worktree under the
# subdir it was invoked from (matching the .gascity-gastown-hq/.gc-worktrees/
# convention), not under git's toplevel.
mkdir -p "$TMP/shared-root/subdir-hq"
OUTG=$(run_guard "$TMP/shared-root/subdir-hq" "tt-bead2" "tester2" 2>&1)
NEWDIRG=$(printf '%s\n' "$OUTG" | grep '^PWD_AFTER=' | tail -1 | cut -d= -f2-)
[ "$NEWDIRG" = "$TMP/shared-root/subdir-hq/.gc-worktrees/tt-bead2-tester2" ] \
  && ok "(G) nested-subdir invocation isolates + nests under the starting subdir ($NEWDIRG)" \
  || bad "(G) unexpected result from nested-subdir invocation: $NEWDIRG"
ROOT_BRANCH_G="$(git -C "$TMP/shared-root" branch --show-current)"
[ "$ROOT_BRANCH_G" = "main" ] \
  && ok "(G2) shared root still on main after nested-subdir invocation" \
  || bad "(G2) shared root branch changed after nested-subdir invocation: $ROOT_BRANCH_G"

# ── (H): guard is a safe no-op when CWD is not inside a git repo at all ──────
mkdir -p "$TMP/not-a-repo"
OUTH=$(run_guard "$TMP/not-a-repo" "tt-bead3" "tester3" 2>&1)
printf '%s\n' "$OUTH" | grep -q "ISOLATION GUARD:" \
  && bad "(H) guard fired outside any git repo (should be a silent no-op)" \
  || ok "(H) guard silent/no-op outside any git repo"

# ── (J): a reused worktree BEHIND origin/main gets refreshed ─────────────────
# Gate blocking issue 2: the reuse path (`[ -e "$WT/.git" ]`) used to just
# cd into the existing worktree with no resync, silently dropping the
# "always fresh" guarantee the old unconditional
# `git checkout -B "$BRANCH" origin/main` gave on EVERY invocation. Advance
# the bare "origin" via a THROWAWAY clone — not shared-root, whose own main
# must stay untouched, matching real topology where origin/main advances
# because other work merged via the gate, not because the shared root
# committed directly.
SCRATCH_CLONE="$(mktemp -d)"
git clone -q "$TMP/origin.git" "$SCRATCH_CLONE" 2>/dev/null
git -C "$SCRATCH_CLONE" -c user.email=test@test -c user.name=test commit -q --allow-empty -m "advance origin past tt-bead1's worktree"
NEW_ORIGIN_TIP="$(git -C "$SCRATCH_CLONE" rev-parse HEAD)"
git -C "$SCRATCH_CLONE" push -q origin main
rm -rf "$SCRATCH_CLONE"

# mol-do-work.toml's step 2 preamble runs `git fetch --prune origin` BEFORE
# the guard block — replicate that here so the guard sees the new tip, same
# as it would in the real formula.
git -C "$TMP/shared-root" fetch -q --prune origin

OLD_WT_HEAD="$(git -C "$NEWDIR" rev-parse HEAD)"
[ "$OLD_WT_HEAD" != "$NEW_ORIGIN_TIP" ] \
  && ok "(J-setup) sanity: existing worktree is behind the new origin/main tip" \
  || bad "(J-setup) test fixture failed to advance origin — (J) would be a false pass"

run_guard "$TMP/shared-root" "tt-bead1" "tester" >/dev/null 2>&1
REFRESHED_HEAD="$(git -C "$NEWDIR" rev-parse HEAD)"
[ "$REFRESHED_HEAD" = "$NEW_ORIGIN_TIP" ] \
  && ok "(J) reused worktree was refreshed to the new origin/main tip" \
  || bad "(J) reused worktree stayed stale — expected $NEW_ORIGIN_TIP, got $REFRESHED_HEAD"

ROOT_BRANCH_J="$(git -C "$TMP/shared-root" branch --show-current)"
[ "$ROOT_BRANCH_J" = "main" ] \
  && ok "(J2) shared root still on main after the refresh re-run" \
  || bad "(J2) shared root branch changed after the refresh re-run: $ROOT_BRANCH_J"

# ── (K): non-conflicting uncommitted WIP survives the (J) refresh ────────────
# The whole point of ga-xau4z is protecting uncommitted WIP — a fix for
# blocking issue 2 that restores freshness by force-clobbering a resumed
# session's in-flight edits would just relocate the hazard instead of fixing
# it. `checkout -B` on the branch you're already on updates the branch ref
# but performs a normal (non-destructive) working-tree checkout, so
# non-conflicting local changes survive.
echo "modified by tester" > "$NEWDIR/README.md"
echo "brand new wip file" > "$NEWDIR/wip-notes.txt"
run_guard "$TMP/shared-root" "tt-bead1" "tester" >/dev/null 2>&1
README_CONTENT="$(cat "$NEWDIR/README.md" 2>/dev/null)"
[ "$README_CONTENT" = "modified by tester" ] \
  && ok "(K) uncommitted edit to a tracked file survived the origin/main refresh" \
  || bad "(K) uncommitted edit to a tracked file was lost during refresh (got: '$README_CONTENT')"
[ -f "$NEWDIR/wip-notes.txt" ] \
  && ok "(K2) untracked WIP file survived the origin/main refresh" \
  || bad "(K2) untracked WIP file was deleted during refresh"

# ── (F): source drift-guards ──────────────────────────────────────────────────
src=$(cat "$FORMULA")
printf '%s' "$src" | grep -q 'git-common-dir' \
  && ok "(F1) formula compares --git-dir against --git-common-dir (topology-based detection)" \
  || bad "(F1) formula missing git-common-dir topology check"
printf '%s' "$src" | grep -q '\.gc-worktrees/' \
  && ok "(F2) formula isolates into the established .gc-worktrees/ convention" \
  || bad "(F2) formula does not target .gc-worktrees/"
printf '%s' "$src" | grep -q 'pwd -P' \
  && ok "(F3) formula resolves paths with pwd -P (survives symlinked temp/mount paths)" \
  || bad "(F3) formula missing pwd -P canonicalization"
printf '%s' "$src" | grep -q 'worktree prune' \
  && ok "(F4) formula prunes stale worktree admin state before reusing an orphaned branch" \
  || bad "(F4) formula missing worktree prune — orphaned-branch recovery (I) may regress"
printf '%s' "$src" | grep -q 'checkout -B "$BRANCH" origin/main' \
  && ok "(F5) formula resets the branch to origin/main inside the isolated worktree (freshness fix)" \
  || bad "(F5) formula missing the post-isolation origin/main resync — staleness (J) may regress"

echo
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL ASSERTIONS PASSED"
