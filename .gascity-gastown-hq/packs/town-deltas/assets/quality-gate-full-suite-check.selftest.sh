#!/usr/bin/env bash
# quality-gate-full-suite-check.selftest.sh — Prove the ga-3wgx8 full-suite
# regression decision table in isolation, with NO live Dolt/gc/launchd.
#
# ga-3wgx8: the gate's reviewer is a diff-scoped LLM code review — nothing in
# it ever runs the rig's own test suite (grep for "pytest" across this whole
# file: zero matches). A branch can add a new file (e.g. a launchd .plist)
# that breaks a PRE-EXISTING, unrelated, parametrized test (tests/
# test_plists_parseiam.py, which auto-collects every tracked .plist) without
# the diff ever touching that test's own file — no reviewer has any
# structural reason to notice, and the branch merges anyway. Measured live:
# origin/main (whatsapp_automation) went red on that exact test after branch
# crew/wa-worker/wa-updf6 merged with a PASSED verdict.
#
# gate_full_suite_check (defined later in the dispatcher, alongside git_rig)
# closes this gap: opt-in per rig (a .gate-full-suite.sh at the branch tip),
# it runs that script against the branch tip and, if red, ALSO against the
# default branch before blocking — a regression is "red on branch, green on
# main", never "red on branch" alone, so pre-existing debt (main is red RIGHT
# NOW, from this very incident, until wa-xtyn1 lands) never permanently locks
# the rig out of merging. gate_full_suite_verdict is the PURE decision table
# behind that call — this harness unit-tests it directly, the same way
# quality-gate-circuit-break.selftest.sh unit-tests gate_circuit_break_check.
#
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── Load the REAL helper from the dispatcher (lib-only = no live run) ─────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type gate_full_suite_verdict >/dev/null 2>&1 \
  || { echo "FATAL: gate_full_suite_verdict not defined by dispatcher (ga-3wgx8 missing?)"; exit 1; }

# ── 1. Branch green → pass, regardless of main's state ────────────────────────
# The common case: branch's own .gate-full-suite.sh exits 0. main is never
# even measured (main_measured=0) — this is what keeps the common case to a
# single suite run.
echo "── 1. branch green → pass (main never measured) ──"
eq "branch=0, main unmeasured → pass" \
  "$(gate_full_suite_verdict "0" "1" "0")" "pass"
eq "branch=0, main=0 (measured anyway) → still pass" \
  "$(gate_full_suite_verdict "0" "0" "1")" "pass"

# ── 2. Branch red, main green → regression (THE wa-updf6 shape) ───────────────
# This is the exact incident: a branch breaks a pre-existing test main never
# had broken. Before this fix, NOTHING in the dispatcher ever ran a rig's
# test suite at all — the branch's own gate-full-suite exit code was never
# even gathered, so this case could not have been distinguished from "pass".
echo "── 2. branch red, main green → regression (wa-updf6 shape) ──"
eq "branch=1, main=0, measured → regression" \
  "$(gate_full_suite_verdict "1" "0" "1")" "regression"
eq "branch=137 (killed/timeout), main=0, measured → still regression" \
  "$(gate_full_suite_verdict "137" "0" "1")" "regression"

# ── 3. Branch red, main ALSO red → preexisting-debt, never blocks ─────────────
# Without this branch, the gate would permanently lock the rig out of
# merging ANYTHING the moment any debt exists — which is main's own state
# RIGHT NOW (tests/test_plists_parseiam.py is red on origin/main until
# wa-xtyn1 lands). This is what makes the fix safe to ship without first
# achieving a flawless baseline.
echo "── 3. branch red, main also red → preexisting-debt (never a lockout) ──"
eq "branch=1, main=1, measured → preexisting-debt" \
  "$(gate_full_suite_verdict "1" "1" "1")" "preexisting-debt"

# ── 4. Branch red, main unmeasurable → unmeasured, fail-open ──────────────────
# Any uncertainty about main's own baseline (worktree creation failed, script
# missing on main, timeout) must never block a branch on a comparison that
# was never actually made — this is the check's own "must never become a new
# false-FAIL source" posture, mirrored from ga-y9a1d immediately above its
# call site in the dispatcher.
echo "── 4. branch red, main unmeasurable → unmeasured, fail-open ──"
eq "branch=1, main=<n/a>, NOT measured → unmeasured" \
  "$(gate_full_suite_verdict "1" "0" "0")" "unmeasured"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
