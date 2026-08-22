#!/usr/bin/env bash
# gate-guard-ga-bz4nsi-neverbranched.selftest.sh — Drift-guard for ga-bz4nsi.
#
# Bug (Mayor, 2026-08-21, wa-qfb6j P0): an OPEN story:in-flight bead with no
# gate:passed, no pilot:dispatched, no live assignee and NO fix/feature branch
# EVER created (the never-started shape) was unconditionally safe-skipped
# forever by the GAP-1 reconciler in quality-gate-guard.sh — permanently
# leaking its Pilot lane slot while staying invisible to every dispatch query.
# classify_inflight_gap1's own pure-function assertions for the new "none"
# input live in quality-gate-reconcile.selftest.sh (section 5b); THIS file
# covers the two supporting helpers ga-bz4nsi added, which classify_inflight_gap1
# alone can't exercise:
#
#   _gap1_city_ready_for_branch_check <city> — an empty branch search only
#     counts as evidence of "no branch" when git is actually usable for that
#     city (real work tree + resolvable origin remote). Verified live against
#     this city's own rig list (2026-08-22): some rig paths error "fatal: this
#     operation must be run in a work tree" on ANY git -C invocation, and
#     others are real work trees with no "origin" remote configured — both
#     make `git ls-remote origin <pattern>` return empty for reasons that have
#     NOTHING to do with whether a branch exists.
#
#   _gap1_ensure_lifecycle_backstop <city> <bead_id> — after a GAP-1 strip, a
#     bead left with zero dispatchable lifecycle label (not type=bug, no
#     tech-debt label, no story:approved) is invisible to every candidate
#     query all over again. Must re-stamp story:approved in exactly that case,
#     and be a no-op otherwise.
#
# This harness (1) unit-tests both live functions (sourced via
# GATE_GUARD_LIB_ONLY=1, mirroring gate-guard-gap1-content-merge-check's
# pattern) against real throwaway git repos / a mock bd, and (2) drift-guards
# that the live GAP-1 loop actually wires the "no branch found" case through
# classify_inflight_gap1's "none" input (not a bare unconditional skip) and
# calls the backstop after both strip actions.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

echo "── gate-guard GAP-1 never-branched release drift-guard (ga-bz4nsi) ──"

if [ ! -f "$GUARD" ]; then
  bad "quality-gate-guard.sh not found next to selftest at $GUARD"
  echo
  echo "── results: $PASS passed, $FAIL failed ──"
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gc-ga-bz4nsi-selftest-XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# ── Fixtures for _gap1_city_ready_for_branch_check ───────────────────────────
# 1. A real work tree WITH a resolvable origin remote — the healthy case.
READY_REPO="$WORK/ready-repo"
git init --quiet "$READY_REPO"
git -C "$READY_REPO" config user.email "selftest@gascity.local"
git -C "$READY_REPO" config user.name  "selftest"
( cd "$READY_REPO" && echo base > base.txt && git add base.txt && git commit --quiet -m "base" )
# A local bare repo as the "origin" — get-url only needs the remote configured
# and resolvable, it never has to actually fetch.
ORIGIN_BARE="$WORK/origin-bare.git"
git init --quiet --bare "$ORIGIN_BARE"
git -C "$READY_REPO" remote add origin "$ORIGIN_BARE"

# 2. A plain directory that is NOT a git repo at all — mirrors the
#    "fatal: this operation must be run in a work tree" rig shape.
NOTAREPO="$WORK/not-a-repo"
mkdir -p "$NOTAREPO"

# 3. A real work tree with NO origin remote configured — mirrors the
#    "real repo, wrong/missing remote name" rig shape.
NOORIGIN_REPO="$WORK/no-origin-repo"
git init --quiet "$NOORIGIN_REPO"
git -C "$NOORIGIN_REPO" config user.email "selftest@gascity.local"
git -C "$NOORIGIN_REPO" config user.name  "selftest"
( cd "$NOORIGIN_REPO" && echo base > base.txt && git add base.txt && git commit --quiet -m "base" )

# ── Source the guard in lib-only mode (no I/O, no main loop) ────────────────
# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # the guard sources with set -euo pipefail; this harness counts its own pass/fail

type _gap1_city_ready_for_branch_check >/dev/null 2>&1 || { echo "FATAL: _gap1_city_ready_for_branch_check not defined by guard (ga-bz4nsi)"; exit 1; }
type _gap1_ensure_lifecycle_backstop   >/dev/null 2>&1 || { echo "FATAL: _gap1_ensure_lifecycle_backstop not defined by guard (ga-bz4nsi)"; exit 1; }
type classify_inflight_gap1            >/dev/null 2>&1 || { echo "FATAL: classify_inflight_gap1 not defined by guard"; exit 1; }

echo "── 1. _gap1_city_ready_for_branch_check ──"
if _gap1_city_ready_for_branch_check "$READY_REPO"; then
  ok "real work tree + resolvable origin → ready (safe to trust an empty branch search)"
else
  bad "real work tree + resolvable origin was wrongly reported NOT ready"
fi

if _gap1_city_ready_for_branch_check "$NOTAREPO"; then
  bad "a plain non-git directory was wrongly reported ready — would trust a false 'no branch' from a broken git checkout"
else
  ok "not a git work tree at all → not ready (matches the 'fatal: not a work tree' rig shape)"
fi

if _gap1_city_ready_for_branch_check "$NOORIGIN_REPO"; then
  bad "a work tree with no origin remote was wrongly reported ready — ls-remote origin would fail for a reason unrelated to branch existence"
else
  ok "real work tree but no origin remote → not ready (matches the 'no such remote origin' rig shape)"
fi

echo "── 2. _gap1_ensure_lifecycle_backstop (mock bd) ──"
_MOCK_TYPE=""
_MOCK_LABELS=""
_MOCK_LABEL_ADD_LOG=""
bd() {
  local verb="$3"
  if [ "$verb" = "show" ]; then
    local arr="" l
    for l in $_MOCK_LABELS; do arr="${arr}\"$l\","; done
    printf '[{"issue_type":"%s","labels":[%s]}]' "$_MOCK_TYPE" "${arr%,}"
    return 0
  fi
  if [ "$verb" = "label" ]; then
    local op="$4" lbl="$6"
    [ "$op" = "add" ] && _MOCK_LABEL_ADD_LOG="$_MOCK_LABEL_ADD_LOG $lbl"
    return 0
  fi
  return 0   # comment (and anything else): no-op success
}

_MOCK_TYPE="bug"; _MOCK_LABELS=""; _MOCK_LABEL_ADD_LOG=""
_gap1_ensure_lifecycle_backstop /tmp/fake-city fake-bead-bug
[ -z "$_MOCK_LABEL_ADD_LOG" ] \
  && ok "type=bug: backstop is a no-op (bugs never need story:approved)" \
  || bad "backstop wrongly touched a bug-typed bead: added [$_MOCK_LABEL_ADD_LOG]"

# ga-bz4nsi third-state regression: a failed/unreadable bd show must NOT
# collapse to "read succeeded, bead needs no approval" — that would stamp
# story:approved based on nothing (the bead could well be a bug we simply
# couldn't verify). Swap in a bd() that returns EMPTY on "show" specifically,
# simulating a Dolt hiccup / unreadable bead, and confirm the backstop stays
# inert rather than guessing.
_MOCK_LABEL_ADD_LOG=""
bd() {
  local verb="$3"
  [ "$verb" = "show" ] && { printf ''; return 1; }
  if [ "$verb" = "label" ]; then
    local op="$4" lbl="$6"
    [ "$op" = "add" ] && _MOCK_LABEL_ADD_LOG="$_MOCK_LABEL_ADD_LOG $lbl"
    return 0
  fi
  return 0
}
_gap1_ensure_lifecycle_backstop /tmp/fake-city fake-bead-unreadable
[ -z "$_MOCK_LABEL_ADD_LOG" ] \
  && ok "bd show failure: backstop stays inert (does not guess story:approved on an unverified bead, ga-bz4nsi third-state guard)" \
  || bad "REGRESSION: backstop stamped story:approved despite an unreadable bd show — collapsed 'could not verify' into 'confirmed needs approval': added [$_MOCK_LABEL_ADD_LOG]"
# Restore the full show-capable mock for the remaining cases below.
bd() {
  local verb="$3"
  if [ "$verb" = "show" ]; then
    local arr="" l
    for l in $_MOCK_LABELS; do arr="${arr}\"$l\","; done
    printf '[{"issue_type":"%s","labels":[%s]}]' "$_MOCK_TYPE" "${arr%,}"
    return 0
  fi
  if [ "$verb" = "label" ]; then
    local op="$4" lbl="$6"
    [ "$op" = "add" ] && _MOCK_LABEL_ADD_LOG="$_MOCK_LABEL_ADD_LOG $lbl"
    return 0
  fi
  return 0
}

_MOCK_TYPE="feature"; _MOCK_LABELS="tech-debt"; _MOCK_LABEL_ADD_LOG=""
_gap1_ensure_lifecycle_backstop /tmp/fake-city fake-bead-techdebt
[ -z "$_MOCK_LABEL_ADD_LOG" ] \
  && ok "tech-debt-labeled bead: backstop is a no-op" \
  || bad "backstop wrongly touched a tech-debt-labeled bead: added [$_MOCK_LABEL_ADD_LOG]"

_MOCK_TYPE="feature"; _MOCK_LABELS="story:approved"; _MOCK_LABEL_ADD_LOG=""
_gap1_ensure_lifecycle_backstop /tmp/fake-city fake-bead-already-approved
[ -z "$_MOCK_LABEL_ADD_LOG" ] \
  && ok "bead already carrying story:approved: backstop is a no-op" \
  || bad "backstop wrongly re-stamped an already-approved bead: [$_MOCK_LABEL_ADD_LOG]"

_MOCK_TYPE="feature"; _MOCK_LABELS=""; _MOCK_LABEL_ADD_LOG=""
_gap1_ensure_lifecycle_backstop /tmp/fake-city fake-bead-orphaned
printf '%s\n' $_MOCK_LABEL_ADD_LOG | grep -qx "story:approved" \
  && ok "feature with NO lifecycle label: backstop stamps story:approved (ga-bz4nsi requirement 3)" \
  || bad "REGRESSION: backstop did not stamp story:approved on an otherwise permanently-invisible feature bead: got [$_MOCK_LABEL_ADD_LOG]"
unset -f bd

echo "── 3. drift-guard: GAP-1 loop actually wires the new case in, not a bare skip ──"
if grep -Fq 'continue' "$GUARD" && grep -Fq 'classify_inflight_gap1 "open" "0" "$HAS_LIVE_ASSIGNEE" "none"' "$GUARD"; then
  ok "GAP-1's 'no branch found' path calls classify_inflight_gap1 with branch_merged=none"
else
  bad "GAP-1's 'no branch found' path does NOT call classify_inflight_gap1(...,\"none\") — regression to the old unconditional safe-skip (ga-bz4nsi)"
fi

if grep -Fq 'strip:no-branch)' "$GUARD"; then
  ok "GAP-1 loop has a case arm handling strip:no-branch"
else
  bad "GAP-1 loop is missing a case arm for strip:no-branch — classify_inflight_gap1 can return it but nothing acts on it"
fi

if grep -Fq '_gap1_city_ready_for_branch_check "$GC_CITY"' "$GUARD"; then
  ok "GAP-1 loop gates the never-branched release on git-readiness for the city, not a bare empty-search result"
else
  bad "GAP-1 loop does NOT check _gap1_city_ready_for_branch_check before trusting an empty branch search — a broken git checkout could masquerade as 'no branch' (ga-bz4nsi)"
fi

_BACKSTOP_CALLS=$(grep -c '_gap1_ensure_lifecycle_backstop "\$GC_CITY" "\$OI_ID"' "$GUARD")
if [ "$_BACKSTOP_CALLS" -ge 2 ]; then
  ok "lifecycle backstop is called after BOTH GAP-1 strip actions (strip:merged and strip:no-branch), found $_BACKSTOP_CALLS call site(s)"
else
  bad "lifecycle backstop is called after fewer than 2 strip actions (found $_BACKSTOP_CALLS) — at least one GAP-1 release path can still leave a bead with zero dispatchable lifecycle label"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
