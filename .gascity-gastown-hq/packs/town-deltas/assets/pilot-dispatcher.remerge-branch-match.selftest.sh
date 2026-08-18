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
# Exit 0 iff every assertion holds.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$HERE/pilot-dispatcher.sh"
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

echo ""
if [ "$F" -eq 0 ]; then echo "SELFTEST PASS ($P ok)"; exit 0
else echo "SELFTEST FAIL ($F bad, $P ok)"; exit 1
fi
