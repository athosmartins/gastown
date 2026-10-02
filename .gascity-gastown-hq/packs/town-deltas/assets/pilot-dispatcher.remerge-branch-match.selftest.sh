#!/usr/bin/env bash
# pilot-dispatcher.remerge-branch-match.selftest.sh — regression guard for
# ga-r7uec: _beadid_needs_remerge_branch (ga-e2n96's own branch-existence
# probe for the "resubmit the existing branch vs escalate to
# gate:needs-human" decision) only matched refs/heads/fix/<bead>-* — a
# mandatory "-" plus suffix right after the bead id. A branch pushed
# WITHOUT a slug (bare fix/<bead>) never matched, so the guard concluded
# "no branch exists" for a bead that had one and escalated a good,
# already-reviewed commit to gate:needs-human. Concrete real-world hit:
# ga-y9a1d (branch origin/fix/ga-y9a1d, no slug, tip 48a365ae, 2 commits) —
# walked step-by-step in ga-r7uec's description.
#
# This test never uses the PILOT_TEST_REMERGE_BEADS mock seam — that seam
# returns a canned ref unconditionally and bypasses the real git
# for-each-ref/ls-remote glob entirely, so it cannot see this bug or prove
# the fix. Instead: a real, disposable git sandbox repo with actual
# branches, and _OWNERSHIP_GUARD_REPOS/_OWNERSHIP_GUARD_REPOS_DONE
# pre-seeded directly (the documented ga-130et memoization shape) so
# _ownership_guard_repos's own `if [ -z "$_OWNERSHIP_GUARD_REPOS_DONE" ]`
# skips its `gc rig list` fetch and just hands back our sandbox path — no
# `gc`/network stub needed, and the sandbox has no remote configured so the
# ls-remote fallback branch never engages either (for-each-ref alone
# resolves every case below).
#
# Extracts the real function bodies from pilot-dispatcher.sh (the canonical
# copy) rather than re-typing them, so this test can't silently drift from
# the shipped code — same philosophy as this directory's other
# extract_fn-based harnesses (e.g. pilot-dispatcher.ns-rig-list-gc-failure
# .selftest.sh).
#
# ga-x7m5rg (second bug in the same helper, same family): it only knew
# fix/<bead>[-*], while the GAP-2 reconciler that ARMS this path also accepts
# feat/ feature/ refactor/ docs/ chore/ test/ crew/*/. A bead delivered on
# feat/ga-atsahv was found by GAP-2, re-armed gate:needs-remerge, then called
# "no existing fix/ branch" here → false gate:needs-human (measured 2x). The
# prefix list now lives in delivery-branch-patterns.sh (sourced below, and
# drift-guarded against quality-gate-guard.sh by its own selftest). The helper
# is also THREE-state now: rc 0 found / rc 1 looked everywhere, nothing /
# rc 2 could not look (ls-remote failed, rig list failed, no git, no lib) —
# a lookup that could not read must never be mistaken for "no branch".
#
# PILOT_DISPATCHER_UNDER_TEST overrides the dispatcher file (used to prove
# these cases fail against the pre-fix helper). Exit 0 iff every assertion holds.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_UNDER_TEST:-$HERE/pilot-dispatcher.sh}"
LIB="$HERE/delivery-branch-patterns.sh"
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

# extract_fn <name> <file> — prints a top-level `name() { ... }` function
# body (brace opens on the `name() {` line, closes on a bare `}` at column
# 0). Same helper as pilot-dispatcher.ns-rig-list-gc-failure.selftest.sh.
extract_fn() {
  awk -v fn="$1" '
    $0 == fn"() {" { p=1 }
    p { print; if ($0 == "}") exit }
  ' "$2"
}

P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

echo "== pilot-dispatcher.remerge-branch-match.selftest (ga-r7uec) =="

# ── Load the real functions under test ─────────────────────────────────────
for fn in _ownership_guard_repos _beadid_needs_remerge_branch; do
  src="$(extract_fn "$fn" "$DISPATCHER")"
  if [ -z "$src" ]; then
    echo "FATAL: $fn() not found in $DISPATCHER — extraction failed (did it move/rename?)" >&2
    exit 2
  fi
  eval "$src"
  if ! type "$fn" >/dev/null 2>&1; then
    echo "FATAL: extraction ran but did not define a callable $fn" >&2
    exit 2
  fi
done

# The helper depends on the shared prefix list; a missing lib must fail LOUDLY
# here (the production caller degrades to rc 2 "unknown" instead — see below).
[ -r "$LIB" ] || { echo "FATAL: $LIB missing — shared prefix list not found" >&2; exit 2; }
# shellcheck disable=SC1090
. "$LIB"

# ── Build a real, disposable git sandbox repo with crafted branches ────────
SANDBOX="$(mktemp -d)"
git -C "$SANDBOX" init -q .
git -C "$SANDBOX" -c user.email=test@test.local -c user.name=test commit -q --allow-empty -m init

# fix/<bead>-<slug> — the documented dispatch_one() convention, must keep
# working (control — proves the fix doesn't narrow the existing match).
git -C "$SANDBOX" branch fix/rmg-suffix-case-a-real-slug
# bare fix/<bead> — no slug (the ga-y9a1d shape this bug missed).
git -C "$SANDBOX" branch fix/rmg-bare-case
# decoy: a DIFFERENT, longer bead id that merely starts with the bare
# case's id as a prefix — proves the exact-match pattern added for the
# bare shape doesn't start matching-by-prefix (the same hazard this file's
# sibling helpers' own doc comments warn about for the "-*" glob).
git -C "$SANDBOX" branch fix/rmg-bare-caseXYZ-decoy-belongs-to-other-bead
# rmg-no-branch-case: deliberately nothing created — the genuine no-branch
# control (must still report "no match" so the caller still escalates to
# gate:needs-human; ga-r7uec ACEITE #2).

# ── ga-x7m5rg: every non-fix delivery prefix GAP-2 recognises ──
git -C "$SANDBOX" branch feat/rmg-feat-bare                    # THE ga-atsahv shape (no slug)
git -C "$SANDBOX" branch feat/rmg-feat-slug-real-slug
git -C "$SANDBOX" branch feature/rmg-feature-case
git -C "$SANDBOX" branch refactor/rmg-refactor-case
git -C "$SANDBOX" branch docs/rmg-docs-case
git -C "$SANDBOX" branch chore/rmg-chore-case
git -C "$SANDBOX" branch test/rmg-test-case
git -C "$SANDBOX" branch crew/some-agent/rmg-crew-case
git -C "$SANDBOX" branch crew/some-agent/rmg-crew-slug-real-slug
# priority: a bead with BOTH a fix/ and a feat/ branch resolves to fix/ (the
# documented dispatch_one() convention, first in the shared list).
git -C "$SANDBOX" branch fix/rmg-prio-case
git -C "$SANDBOX" branch feat/rmg-prio-case
# decoy under a non-fix prefix: a longer id that merely starts with rmg-feat-bare
git -C "$SANDBOX" branch feat/rmg-feat-bareXYZ-decoy-belongs-to-other-bead

_OWNERSHIP_GUARD_REPOS="$SANDBOX"
_OWNERSHIP_GUARD_REPOS_DONE=1
_OWNERSHIP_GUARD_REPOS_FAILED=""

echo "-- suffixed branch (fix/<bead>-<slug>) still matches (control, must not regress) --"
_rt="$(_beadid_needs_remerge_branch "rmg-suffix-case-a" 2>/dev/null)"; _rc=$?
if [ "$_rc" -eq 0 ] && [ "${_rt#*$'\t'}" = "fix/rmg-suffix-case-a-real-slug" ]; then
  ok "suffixed branch matched, ref='${_rt#*$'\t'}'"
else
  bad "suffixed branch: expected match on fix/rmg-suffix-case-a-real-slug, got rc=$_rc ref='${_rt#*$'\t'}'"
fi

echo "-- bare branch (fix/<bead>, no slug) now matches — THE ga-y9a1d REGRESSION CASE --"
_rt="$(_beadid_needs_remerge_branch "rmg-bare-case" 2>/dev/null)"; _rc=$?
if [ "$_rc" -eq 0 ] && [ "${_rt#*$'\t'}" = "fix/rmg-bare-case" ]; then
  ok "bare branch matched, ref='${_rt#*$'\t'}' — the ga-e2n96 false-escalation bug is fixed"
else
  bad "REGRESSION (ga-r7uec/ga-y9a1d): bare branch fix/rmg-bare-case exists but was NOT matched (rc=$_rc ref='${_rt#*$'\t'}') — guard would wrongly escalate a built, reviewed bead to gate:needs-human"
fi

echo "-- no branch at all -> still correctly reports no match (ACEITE #2 control) --"
_rt="$(_beadid_needs_remerge_branch "rmg-no-branch-case" 2>/dev/null)"; _rc=$?
if [ "$_rc" -ne 0 ] && [ -z "$_rt" ]; then
  ok "genuinely branchless bead correctly reported no match — escalation path still protected"
else
  bad "REGRESSION: rmg-no-branch-case had NO branch pushed but matched anyway (rc=$_rc ref='$_rt') — would silently resubmit a nonexistent branch"
fi

echo "-- decoy: a longer id sharing the bare id as a prefix must NOT false-match --"
_rt="$(_beadid_needs_remerge_branch "rmg-bare-case" 2>/dev/null)"
case "$_rt" in
  *decoy*) bad "REGRESSION: bare-id exact match against fix/rmg-bare-case picked up the unrelated decoy branch fix/rmg-bare-caseXYZ-decoy-belongs-to-other-bead" ;;
  *) ok "decoy branch correctly ignored — exact-match pattern has no prefix-collision" ;;
esac

# expect <label> <bead> <want_rc> <want_ref> — run the REAL helper, compare rc and ref.
expect() {
  local _label="$1" _id="$2" _want_rc="$3" _want_ref="$4" _got _rc
  _got="$(_beadid_needs_remerge_branch "$_id" 2>/dev/null)"; _rc=$?
  if [ "$_rc" -eq "$_want_rc" ] && [ "${_got#*$'\t'}" = "$_want_ref" ] \
     && { [ "$_want_rc" -ne 0 ] || [ "${_got%%$'\t'*}" != "$_got" ]; }; then
    ok "$_label (rc=$_rc ref='${_got#*$'\t'}')"
  else
    bad "$_label: want rc=$_want_rc ref='$_want_ref', got rc=$_rc out='$_got'"
  fi
}

echo "-- ga-x7m5rg: every non-fix prefix GAP-2 accepts must resolve (feat/ is THE ga-atsahv bug) --"
expect "feat/<bead> (bare, no slug) — THE ga-atsahv REGRESSION CASE" rmg-feat-bare   0 "feat/rmg-feat-bare"
expect "feat/<bead>-<slug>"                                           rmg-feat-slug   0 "feat/rmg-feat-slug-real-slug"
expect "feature/<bead>"                                               rmg-feature-case 0 "feature/rmg-feature-case"
expect "refactor/<bead>"                                              rmg-refactor-case 0 "refactor/rmg-refactor-case"
expect "docs/<bead>"                                                  rmg-docs-case   0 "docs/rmg-docs-case"
expect "chore/<bead>"                                                 rmg-chore-case  0 "chore/rmg-chore-case"
expect "test/<bead>"                                                  rmg-test-case   0 "test/rmg-test-case"
expect "crew/<agent>/<bead>"                                          rmg-crew-case   0 "crew/some-agent/rmg-crew-case"
expect "crew/<agent>/<bead>-<slug>"                                   rmg-crew-slug   0 "crew/some-agent/rmg-crew-slug-real-slug"

echo "-- priority: fix/ beats feat/ when a bead has both --"
expect "fix/<bead> wins over feat/<bead>" rmg-prio-case 0 "fix/rmg-prio-case"

echo "-- decoy under feat/: a longer id sharing the bare id as a prefix must NOT match --"
expect "feat/<longer-id>-... does not match the shorter bead id" rmg-feat-bare 0 "feat/rmg-feat-bare"
_rt="$(_beadid_needs_remerge_branch "rmg-feat-ba" 2>/dev/null)"; _rc=$?
if [ "$_rc" -eq 1 ] && [ -z "$_rt" ]; then
  ok "id that is only a PREFIX of existing branch ids matches nothing (rc=1)"
else
  bad "prefix-only id false-matched: rc=$_rc out='$_rt'"
fi

echo "-- no branch under ANY prefix -> rc 1 (genuine none: the caller still escalates) --"
expect "no branch anywhere" rmg-truly-nothing 1 ""

# ── three-state: a lookup that could not READ is rc 2, never rc 1 ──────────
echo "-- origin unreachable (ls-remote fails) + no local match -> rc 2 UNKNOWN, not 'no branch' --"
DEADREMOTE="$(mktemp -d)"
git -C "$DEADREMOTE" init -q .
git -C "$DEADREMOTE" -c user.email=test@test.local -c user.name=test commit -q --allow-empty -m init
git -C "$DEADREMOTE" remote add origin "$DEADREMOTE/does-not-exist.git"
_OWNERSHIP_GUARD_REPOS="$DEADREMOTE"
expect "ls-remote failing, nothing local" rmg-anything 2 ""
git -C "$DEADREMOTE" branch feat/rmg-local-wins
expect "ls-remote failing BUT the branch is local -> found (positive evidence beats a failed probe)" rmg-local-wins 0 "feat/rmg-local-wins"

echo "-- branch only on origin (never fetched locally) is found via ls-remote --"
ORIGIN="$(mktemp -d)"; git init -q --bare "$ORIGIN"
CLONE="$(mktemp -d)"; git -C "$CLONE" init -q .
git -C "$CLONE" -c user.email=test@test.local -c user.name=test commit -q --allow-empty -m init
git -C "$CLONE" remote add origin "$ORIGIN"
git -C "$CLONE" push -q origin HEAD:refs/heads/feat/rmg-remote-only
git -C "$CLONE" push -q origin HEAD:refs/heads/crew/some-agent/rmg-remote-crew
git -C "$CLONE" push -q origin HEAD:refs/heads/feat/rmg-remote-onlyXYZ-decoy
_OWNERSHIP_GUARD_REPOS="$CLONE"
expect "remote-only feat/<bead>"        rmg-remote-only 0 "feat/rmg-remote-only"
expect "remote-only crew/<agent>/<bead>" rmg-remote-crew 0 "crew/some-agent/rmg-remote-crew"
expect "remote reachable, nothing there -> rc 1 (a READABLE miss is a real none)" rmg-remote-missing 1 ""

echo "-- rig list failed (only HQ was searched) + no match -> rc 2; a match is still honoured --"
_OWNERSHIP_GUARD_REPOS="$SANDBOX"
_OWNERSHIP_GUARD_REPOS_FAILED=1
expect "degraded repo list, nothing found" rmg-truly-nothing 2 ""
expect "degraded repo list, but the branch is right there" rmg-feat-bare 0 "feat/rmg-feat-bare"
_OWNERSHIP_GUARD_REPOS_FAILED=""

echo "-- a path that is not a git repo is skipped, not treated as unreadable --"
NOTGIT="$(mktemp -d)"
_OWNERSHIP_GUARD_REPOS="$NOTGIT
$SANDBOX"
expect "non-git rig dir + real repo, nothing found -> rc 1" rmg-truly-nothing 1 ""
expect "non-git rig dir + real repo, branch found"          rmg-feat-bare 0 "feat/rmg-feat-bare"
_OWNERSHIP_GUARD_REPOS="$NOTGIT"
expect "ONLY non-git paths (looked nowhere) -> rc 2" rmg-truly-nothing 2 ""
_OWNERSHIP_GUARD_REPOS="$SANDBOX"

# ── ga-x7m5rg gate feedback (attempt 1, both reviewers): "git could not OPEN it" ≠ "not a repo" ──
# A repo whose .git is damaged (truncated HEAD — plausible on a machine that runs near disk-full)
# answers `git rev-parse --git-dir` with the SAME rc 128 "not a git repository" as a plain directory.
# The first version skipped both identically and did not count either, so with one healthy repo read
# cleanly the result was rc 1 → gate:needs-human: the exact false escalation this bead removes, one
# level down. Only the presence of .git tells the two apart; a registered path that no longer exists
# is likewise unreadable, not "cannot hold the branch".
echo "-- a repo git could not OPEN (present .git, rev-parse fails) is UNKNOWN, not 'cannot hold the branch' --"
CORRUPT="$(mktemp -d)"
git -C "$CORRUPT" init -q .
: > "$CORRUPT/.git/HEAD"
if git -C "$CORRUPT" rev-parse --git-dir >/dev/null 2>&1; then
  bad "PRECONDITION: the corrupt sandbox repo still opens — the cases below would prove nothing"
elif [ ! -e "$CORRUPT/.git" ]; then
  bad "PRECONDITION: the corrupt sandbox has no .git — it is a plain directory, not a damaged repo"
else
  ok "precondition: sandbox repo has a .git but git cannot open it (rc 128, same as a plain dir)"
fi
_OWNERSHIP_GUARD_REPOS="$CORRUPT
$SANDBOX"
expect "corrupt repo + healthy repo, nothing found -> rc 2 (was rc 1: false gate:needs-human)" rmg-truly-nothing 2 ""
expect "corrupt repo + healthy repo, branch found -> rc 0 (positive evidence still wins)"      rmg-feat-bare 0 "feat/rmg-feat-bare"
_OWNERSHIP_GUARD_REPOS="$SANDBOX
$CORRUPT"
expect "corrupt repo listed AFTER the healthy one, nothing found -> rc 2 (order must not matter)" rmg-truly-nothing 2 ""

echo "-- a registered path that no longer exists is UNKNOWN, not 'cannot hold the branch' --"
MISSING="$(mktemp -d)/gone-rig"   # parent exists, the rig dir itself was never created
_OWNERSHIP_GUARD_REPOS="$MISSING
$SANDBOX"
expect "missing registered path + healthy repo, nothing found -> rc 2" rmg-truly-nothing 2 ""
expect "missing registered path + healthy repo, branch found -> rc 0"  rmg-feat-bare 0 "feat/rmg-feat-bare"
_OWNERSHIP_GUARD_REPOS="$SANDBOX"

echo "-- shared lib missing at runtime -> rc 2 (deploy fault must not escalate beads) --"
(
  unset -f gc_delivery_branch_globs gc_delivery_branch_pick
  _rt="$(_beadid_needs_remerge_branch "rmg-feat-bare" 2>/dev/null)"; _rc=$?
  [ "$_rc" -eq 2 ] && [ -z "$_rt" ]
) && ok "no gc_delivery_branch_globs -> rc 2, no output" \
  || bad "missing lib did not degrade to rc 2"

echo "-- test seam: PILOT_TEST_REMERGE_UNKNOWN_BEADS yields rc 2 --"
(
  PILOT_TEST_REMERGE_BEADS="x"; PILOT_TEST_REMERGE_UNKNOWN_BEADS="rmg-seam"
  _beadid_needs_remerge_branch "rmg-seam" >/dev/null 2>&1; [ $? -eq 2 ]
) && ok "UNKNOWN seam -> rc 2" || bad "UNKNOWN seam did not return rc 2"

rm -rf "$SANDBOX" "$DEADREMOTE" "$ORIGIN" "$CLONE" "$NOTGIT" "$CORRUPT" "${MISSING%/*}" 2>/dev/null || true

echo ""
if [ "$F" -eq 0 ]; then echo "SELFTEST PASS ($P ok)"; exit 0
else echo "SELFTEST FAIL ($F bad, $P ok)"; exit 1
fi
