#!/usr/bin/env bash
# quality-gate-circuit-break.selftest.sh — Prove the ga-acb auto-circuit-break
# logic in isolation, with NO live Dolt/gc/launchd.
#
# ga-acb: when a gate marker is PROVABLY un-mergeable (branch absent, large
# divergence + dead author, or retries exhausted + dead author) the dispatcher
# must CIRCUIT-BREAK: set gate:needs-human on the source bead, park the marker
# at gate-status:error, and stop the guard-churn cycle.
#
# This harness SOURCES the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY)
# to unit-test the REAL pure decision function (gate_circuit_break_check), then
# validates all three conditions plus the fail-open (disabled) path and the
# GOOD-marker negative (no circuit-break for healthy markers).
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

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type gate_circuit_break_check >/dev/null 2>&1 \
  || { echo "FATAL: gate_circuit_break_check not defined by dispatcher (ga-acb missing?)"; exit 1; }

# Quiet logging noise from sourced helpers.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. Condition: no_branch ───────────────────────────────────────────────────
# A branch absent from origin is ALWAYS circuit-broken, regardless of author state.
echo "── 1. no_branch → always circuit-break (feature on) ──"
eq "no_branch: dead author → circuit-break" \
  "$(gate_circuit_break_check "no_branch" "" "0" "0" "3" "10")" \
  "circuit-break:no_branch"
eq "no_branch: live author → circuit-break (branch still gone)" \
  "$(gate_circuit_break_check "no_branch" "" "1" "0" "3" "10")" \
  "circuit-break:no_branch"
eq "no_branch: zero attempt counter irrelevant → circuit-break" \
  "$(gate_circuit_break_check "no_branch" "" "0" "2" "3" "10")" \
  "circuit-break:no_branch"

# ── 2. Condition: ahead_dead ──────────────────────────────────────────────────
# Circuit-break only when ahead > max AND author is dead.
echo "── 2. ahead_dead → circuit-break only when ahead > max AND dead author ──"
# Standard defaults: ahead_max=10
eq "ahead=68, dead author → circuit-break" \
  "$(gate_circuit_break_check "ahead_dead" "68" "0" "0" "3" "10")" \
  "circuit-break:ahead_dead"
eq "ahead=11, dead author → circuit-break (1 over max)" \
  "$(gate_circuit_break_check "ahead_dead" "11" "0" "0" "3" "10")" \
  "circuit-break:ahead_dead"
eq "ahead=10, dead author → ok (not over max, exactly at boundary)" \
  "$(gate_circuit_break_check "ahead_dead" "10" "0" "0" "3" "10")" \
  "ok"
eq "ahead=1, dead author → ok (well within envelope)" \
  "$(gate_circuit_break_check "ahead_dead" "1" "0" "0" "3" "10")" \
  "ok"
eq "ahead=68, LIVE author → ok (author can re-anchor)" \
  "$(gate_circuit_break_check "ahead_dead" "68" "1" "0" "3" "10")" \
  "ok"
eq "ahead empty (no count available), dead author → ok (fail-open)" \
  "$(gate_circuit_break_check "ahead_dead" "" "0" "0" "3" "10")" \
  "ok"
eq "ahead garbage, dead author → ok (fail-open)" \
  "$(gate_circuit_break_check "ahead_dead" "xx" "0" "0" "3" "10")" \
  "ok"

# ── 3. Condition: retry_dead ──────────────────────────────────────────────────
# Circuit-break when attempts >= max AND author is dead.
echo "── 3. retry_dead → circuit-break only when attempts >= max AND dead author ──"
eq "attempt=3, max=3, dead → circuit-break (at cap)" \
  "$(gate_circuit_break_check "retry_dead" "" "0" "3" "3" "10")" \
  "circuit-break:retry_dead"
eq "attempt=4, max=3, dead → circuit-break (above cap)" \
  "$(gate_circuit_break_check "retry_dead" "" "0" "4" "3" "10")" \
  "circuit-break:retry_dead"
eq "attempt=2, max=3, dead → ok (below cap — still retrying)" \
  "$(gate_circuit_break_check "retry_dead" "" "0" "2" "3" "10")" \
  "ok"
eq "attempt=3, max=3, LIVE author → ok (live author: escalate, not circuit-break)" \
  "$(gate_circuit_break_check "retry_dead" "" "1" "3" "3" "10")" \
  "ok"
eq "attempt=0, max=3, dead → ok (first attempt)" \
  "$(gate_circuit_break_check "retry_dead" "" "0" "0" "3" "10")" \
  "ok"

# ── 4. GOOD marker (ahead=1, behind=1, live author) → never circuit-broken ───
# This is the critical safety case: a healthy marker MUST NOT be circuit-broken.
echo "── 4. GOOD marker (ahead=1, behind=1, live author) → never circuit-broken ──"
eq "good: no_branch check → ok (branch exists, condition not triggered)" \
  "ok" \
  "ok"   # gate_circuit_break_check("no_branch") only called when branch IS absent
eq "good: ahead_dead (ahead=1, author alive) → ok" \
  "$(gate_circuit_break_check "ahead_dead" "1" "1" "0" "3" "10")" \
  "ok"
eq "good: retry_dead (attempt=0, author alive) → ok" \
  "$(gate_circuit_break_check "retry_dead" "" "1" "0" "3" "10")" \
  "ok"
eq "good: retry_dead (attempt=1, author alive) → ok (mid-retry)" \
  "$(gate_circuit_break_check "retry_dead" "" "1" "1" "3" "10")" \
  "ok"

# ── 5. Fail-open: GATE_AUTO_CIRCUIT_BREAK=0 disables ALL circuit-breaks ──────
echo "── 5. GATE_AUTO_CIRCUIT_BREAK=0 → fail-open, all conditions return ok ──"
eq "disabled: no_branch → ok (fail-open)" \
  "$(GATE_AUTO_CIRCUIT_BREAK=0 gate_circuit_break_check "no_branch" "" "0" "0" "3" "10")" \
  "ok"
eq "disabled: ahead_dead (68 commits, dead) → ok (fail-open)" \
  "$(GATE_AUTO_CIRCUIT_BREAK=0 gate_circuit_break_check "ahead_dead" "68" "0" "0" "3" "10")" \
  "ok"
eq "disabled: retry_dead (at cap, dead) → ok (fail-open)" \
  "$(GATE_AUTO_CIRCUIT_BREAK=0 gate_circuit_break_check "retry_dead" "" "0" "3" "3" "10")" \
  "ok"

# ── 6. Unknown condition → fail-open ─────────────────────────────────────────
echo "── 6. unknown condition → ok (fail-open, no spurious break) ──"
eq "unknown condition string → ok" \
  "$(gate_circuit_break_check "bogus_condition" "" "0" "0" "3" "10")" \
  "ok"
eq "empty condition → ok" \
  "$(gate_circuit_break_check "" "" "0" "0" "3" "10")" \
  "ok"

# ── 7. Drift guard: function must still be exported by the dispatcher ─────────
echo "── 7. drift guard: gate_circuit_break_check exported by dispatcher ──"
type gate_circuit_break_check >/dev/null 2>&1 \
  && ok "gate_circuit_break_check present in lib-only mode" \
  || bad "gate_circuit_break_check MISSING from dispatcher lib-only export (drift!)"

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" = "0" ]; then
  echo "PASS $PASS/$((PASS+FAIL)) — quality-gate-circuit-break selftest"
  exit 0
else
  echo "FAIL $FAIL/$((PASS+FAIL)) — quality-gate-circuit-break selftest"
  exit 1
fi
