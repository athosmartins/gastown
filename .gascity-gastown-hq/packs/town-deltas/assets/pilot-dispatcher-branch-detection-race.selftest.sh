#!/usr/bin/env bash
# pilot-dispatcher-branch-detection-race.selftest.sh — regression guard for
# ga-8w22n: _beadid_has_branch, _beadid_has_crew_branch, and
# _beadid_matched_crew_branch_ref each pipe an unbounded
# `git for-each-ref refs/heads refs/remotes` straight into an early-exiting
# consumer (`grep -q...`, or `grep ... | head -1`). Under this file's own
# `set -euo pipefail`, on a checkout with many refs, the consumer can exit
# before for-each-ref finishes writing, so for-each-ref (or, for the third
# function, grep itself once `head -1` closes) catches SIGPIPE — reported as
# the pipeline's exit status even though a real match existed.
#
# Same class and same fix pattern as ga-vfob8 (daemon-presence-watchdog.sh
# strings|grep) and ga-sb1wu (the same file's awk|grep): capture the
# producer's output to a variable first, then match via a herestring —
# removing the live pipe (and the SIGPIPE mechanism) entirely, not just
# narrowing its window.
#
# Function bodies are extracted dynamically by awk (signature line to the
# matching top-level closing brace), never by hardcoded line numbers — this
# file is edited constantly and a hardcoded range would silently go stale.
#
# Run: bash pilot-dispatcher-branch-detection-race.selftest.sh
# Exit: 0 = all pass, 1 = any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PILOT="$SCRIPT_DIR/pilot-dispatcher.sh"

PASS=0; FAIL=0
_pass() { PASS=$((PASS+1)); printf "[PASS] %s\n" "$1"; }
_fail() { FAIL=$((FAIL+1)); printf "[FAIL] %s\n" "$1"; }

# extract_fn <function_name> <out_file> — signature line through the first
# top-level "}" that follows it (mirrors this suite's existing grep -A
# convention, generalized to find the boundary dynamically instead of
# guessing a fixed -A count).
extract_fn() {
  local _name="$1" _out="$2"
  awk -v fn="^${_name}\\\\(\\\\)" '
    $0 ~ fn { found=1 }
    found { print; if ($0 == "}") exit }
  ' "$PILOT" > "$_out"
  [ -s "$_out" ] || { printf 'extract_fn: %s not found in %s\n' "$_name" "$PILOT" >&2; return 1; }
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_fn _beadid_has_branch "$TMP/fn1.sh"
extract_fn _beadid_has_crew_branch "$TMP/fn2.sh"
extract_fn _beadid_matched_crew_branch_ref "$TMP/fn3.sh"

echo "Scenario 1: extracted function bodies are non-empty and syntactically valid"
for f in fn1 fn2 fn3; do
  if bash -n "$TMP/$f.sh" 2>/dev/null; then
    _pass "$f.sh: valid bash syntax"
  else
    _fail "$f.sh: syntax error (extraction boundary likely wrong)"
  fi
done

# ── Build ONE synthetic repo shared by all scenarios below ──────────────────
# Bulk ref creation via `update-ref --stdin` (not a `git branch` loop — one
# process for thousands of refs, not thousands of processes). Refs must
# genuinely OUTNUMBER what a single pipe buffer can hold, or the race this
# guards against simply never has a chance to manifest (confirmed live while
# building the fix: 600 refs raced ~73% of the time, 1500+ raced ~100%).
REPO="$TMP/repo"
git init -q "$REPO"
git -C "$REPO" config user.email t@t.com
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
SHA=$(git -C "$REPO" rev-parse HEAD)
{
  # Sorts alphabetically FIRST (for-each-ref's default order), so an
  # early-exiting consumer is maximally likely to close the pipe while
  # thousands of later refs are still pending — the exact shape of the race.
  echo "create refs/heads/0000-ga-racetarget1 $SHA"
  # _beadid_matched_crew_branch_ref's race needs MANY matching lines, not
  # just many total refs: its vulnerable stage is grep|head, and grep (fed
  # from an already-materialized herestring after the fix, but a LIVE pipe
  # before it) only risks SIGPIPE from `head -1` closing early if it still
  # has more matches queued to write when head exits — one match lets grep
  # finish instantly, never triggering it. Confirmed live while building the
  # fix: 40 matches never reproduced the crash; 3000 did, reliably (15/15).
  for i in $(seq 1 3000); do
    printf 'create refs/heads/0000-crew/owner%04d/ga-racetarget1 %s\n' "$i" "$SHA"
  done
  for i in $(seq 1 500); do
    printf 'create refs/heads/zzzz-filler-%05d %s\n' "$i" "$SHA"
  done
} | git -C "$REPO" update-ref --stdin

RUNS=25

echo ""
echo "Scenario 2 (ga-8w22n): _beadid_has_branch finds a real branch on EVERY run, not just most"
_ok=0
for _ in $(seq 1 "$RUNS"); do
  if bash -c '
    set -euo pipefail
    source "$1"
    _NS_RIG_LIST_OK=1
    _NS_BRANCH_REPOS="$2"
    _beadid_has_branch "ga-racetarget1"
  ' _ "$TMP/fn1.sh" "$REPO" >/dev/null 2>&1; then
    _ok=$((_ok+1))
  fi
done
[ "$_ok" -eq "$RUNS" ] \
  && _pass "_beadid_has_branch: $_ok/$RUNS runs found the real branch (no SIGPIPE false-negative)" \
  || _fail "_beadid_has_branch: only $_ok/$RUNS runs found the real branch — race still present"

echo ""
echo "Scenario 3 (ga-8w22n): _beadid_has_crew_branch finds a real crew branch on EVERY run"
_ok=0
for _ in $(seq 1 "$RUNS"); do
  if bash -c '
    set -euo pipefail
    _ownership_guard_repos() { :; }
    source "$1"
    _OWNERSHIP_GUARD_REPOS="$2"
    _beadid_has_crew_branch "ga-racetarget1"
  ' _ "$TMP/fn2.sh" "$REPO" >/dev/null 2>&1; then
    _ok=$((_ok+1))
  fi
done
[ "$_ok" -eq "$RUNS" ] \
  && _pass "_beadid_has_crew_branch: $_ok/$RUNS runs found the real crew branch" \
  || _fail "_beadid_has_crew_branch: only $_ok/$RUNS runs found the real crew branch — race still present"

echo ""
echo "Scenario 4 (ga-8w22n): _beadid_matched_crew_branch_ref finds a match on EVERY run and never crashes the caller"
_ok=0
_crashed=0
for _ in $(seq 1 "$RUNS"); do
  # set +e / set -e around the assignment, not `|| true` on it: pre-fix,
  # this subshell can legitimately exit 141 (SIGPIPE), and a bare
  # `x=$(cmd)` propagating that would trip this selftest's OWN set -e —
  # exactly the class of bug under test (caught live while writing this
  # scenario: the selftest crashed instead of reporting RED, silently
  # hiding the very failure it exists to show). `|| true` alone is not
  # enough here: it would mask $?  back to 0 too, losing the 141 this
  # scenario needs to detect.
  set +e
  _out=$(bash -c '
    set -euo pipefail
    _ownership_guard_repos() { :; }
    source "$1"
    _OWNERSHIP_GUARD_REPOS="$2"
    _beadid_matched_crew_branch_ref "ga-racetarget1"
  ' _ "$TMP/fn3.sh" "$REPO" 2>&1)
  _rc=$?
  set -e
  if [ "$_rc" -eq 141 ]; then
    _crashed=$((_crashed+1))
  elif [ "$_rc" -eq 0 ] && [ -n "$_out" ]; then
    _ok=$((_ok+1))
  fi
done
[ "$_crashed" -eq 0 ] \
  && _pass "_beadid_matched_crew_branch_ref: 0/$RUNS runs crashed with SIGPIPE (exit 141)" \
  || _fail "_beadid_matched_crew_branch_ref: $_crashed/$RUNS runs crashed with SIGPIPE (exit 141) — pre-fix this reproduced at up to 15/15"
[ "$_ok" -eq "$RUNS" ] \
  && _pass "_beadid_matched_crew_branch_ref: $_ok/$RUNS runs returned a real match" \
  || _fail "_beadid_matched_crew_branch_ref: only $_ok/$RUNS runs returned a real match"

echo ""
echo "Scenario 5 (ga-8w22n): no live pipe remains into any early-exiting consumer for these three functions"
# Static regression guard, complementary to the dynamic scenarios above: the
# dynamic tests prove CORRECT BEHAVIOR on this machine right now, but a
# future edit could reintroduce the live-pipe shape and still pass them by
# sheer luck (SIGPIPE timing is probabilistic, never guaranteed on every
# machine/load). Assert the SOURCE no longer contains the vulnerable shape
# for these three functions specifically — bounded to their own extracted
# bodies, so this can never accidentally match a DIFFERENT, already-safe
# for-each-ref call elsewhere in the file (e.g. the bead-scoped-glob ones).
for f in fn1 fn2 fn3; do
  # Join backslash line-continuations first — this file's own style wraps
  # the `for-each-ref ... \` / `| grep ...` shape across two physical
  # lines, so a plain single-line grep never matched either the buggy OR
  # the fixed shape (confirmed live while writing this selftest: it
  # silently passed against the UNFIXED source too, proving it wasn't
  # testing anything). Then strip comment lines — this selftest's own
  # explanatory prose (describing the OLD, buggy shape) literally contains
  # the string "for-each-ref | grep" and self-triggers otherwise (the
  # exact self-triggering-fixture class this session's own memory warns
  # about — hit twice while writing this one check).
  _joined=$(awk '{ if (sub(/\\$/, "")) { printf "%s ", $0; next } print }' "$TMP/$f.sh" \
    | grep -v '^[[:space:]]*#')
  if grep -qE 'for-each-ref.*\|[[:space:]]*grep' <<< "$_joined"; then
    _fail "$f.sh: still pipes for-each-ref directly into grep — regression"
  else
    _pass "$f.sh: for-each-ref output is captured before matching, not piped live"
  fi
done

echo ""
echo "pilot-dispatcher-branch-detection-race selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
