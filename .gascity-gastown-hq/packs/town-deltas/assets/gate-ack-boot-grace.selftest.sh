#!/usr/bin/env bash
# gate-ack-boot-grace.selftest.sh (ga-xwdl)
#
# Bug ga-xwdl: a gate FAILED with "TIMEOUT: reviewers did not submit verdicts
# within 29 minutes" even though the reviewer session was ALIVE the entire
# run (zero "Re-convening dead reviewer" lines) — it simply never received
# its review task.
#
# Root cause (run ga-wisp-k6s25f): Step 7b's ga-aknox optimization skips the
# re-queue nudge when `gc session peek` reports "session not found" on
# stderr, on the theory that the session has already drained and re-convene
# (ga-4u16h) will re-spawn it. But a `gc session new --no-attach` deferred
# start can take ~210s to boot (ga-flfo), and DURING that window
# `gc session peek` ALSO answers "session not found" — the IDENTICAL string
# a genuinely-drained session produces. Step 7b's own attempts land at
# spawn_age ~20-60s (ACK_MAX_RETRIES=4, ACK_WAIT_SECS=20s), deep inside that
# boot window, so the ORIGINAL unconditional check misread a booting
# reviewer as drained at 33s, skipped its nudge, and — because the very next
# attempt's peek succeeded (ACK) and stopped all further re-queuing — the
# task was NEVER (re)delivered. The reviewer sat alive-but-untasked for the
# full 29m outer timeout.
#
# This is the SAME root class as ga-flfo (a few hundred lines below in the
# same file, in the Step 8 re-convene loop) and ga-ipf6: a confounded signal
# (peek "not found") is trusted without asking whether the session could
# instead be in a state — booting — it legitimately passes through while
# alive. FIX: gate the ga-aknox skip behind the SAME discriminator the
# re-convene loop already trusts: session_is_booting(state) and
# RECONVENE_GRACE_SECS. Only treat "peek says gone" as a confirmed drain once
# the session is not currently booting AND has been alive long enough that
# boot could not still explain a "not found" read. Any inconclusive read
# (list call failed, empty state, missing spawn epoch) falls through to
# re-queue too — never skip on uncertain evidence.
#
# Step 7b's ACK loop is inline top-level script (not a function), so — like
# quality-gate-reconvene.selftest.sh for the sibling ga-flfo fix — this
# harness sources the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY)
# to get the REAL session_is_booting/session_peek_reports_dead helpers, then
# re-derives the EXACT new gating expression as a small simulation function
# so it can be driven with controlled inputs (no live Dolt/gc/launchd).
#
# Mutation-tested (ga-xwdl acceptance criterion 3): reproducing the PRE-FIX
# bare formula (peek-dead alone, no booting/age gate) against the SAME
# 33s-booting inputs flips the outcome to "skip" — proving the guard added
# here is what makes scenario (a) pass, not a vacuous assertion.
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
hasF()    { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

echo "── 0. compile-guard: dispatcher parses cleanly ──"
if bash -n "$DISPATCHER" 2>/dev/null; then ok "dispatcher: bash -n clean"; else bad "dispatcher: bash -n FAILED"; fi

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ───────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type session_is_booting >/dev/null 2>&1 \
  || { echo "FATAL: session_is_booting not defined (ga-flfo missing?)"; exit 1; }
type session_peek_reports_dead >/dev/null 2>&1 \
  || { echo "FATAL: session_peek_reports_dead not defined (ga-h9o17 missing?)"; exit 1; }

# Quiet logging noise from sourced helpers.
log()  { :; }
warn() { :; }
err()  { :; }

echo "── 1. sanity: RECONVENE_GRACE_SECS default survived sourcing ──"
eq "RECONVENE_GRACE_SECS defaults to 360 (ga-flfo)" "$RECONVENE_GRACE_SECS" "360"

# ── Simulation: mirrors the Step 7b ga-aknox gate EXACTLY (ga-xwdl fix) ──────
# sim_ack_decision <state> <spawn_age> <grace> <peek_kind: gone|found>
#   → "skip" (ACK skip, ga-aknox fires) | "requeue" (nudge re-sent)
sim_ack_decision() {
  local state="$1" spawn_age="$2" grace="$3" peek_kind="$4"
  local booting peek_dead
  booting=$(session_is_booting "$state")
  case "$peek_kind" in
    gone) peek_dead=$(session_peek_reports_dead 'gc session peek: session not found: "sX"') ;;
    *)    peek_dead=$(session_peek_reports_dead 'live terminal scrollback for sX') ;;
  esac
  if [ "$peek_dead" = "1" ] && [ "$booting" != "1" ] && [ "$spawn_age" -ge "$grace" ]; then
    echo "skip"
  else
    echo "requeue"
  fi
}

# sim_ack_decision_prefix <peek_kind> — the ORIGINAL (pre-ga-xwdl) ga-aknox
# formula: trusts session_peek_reports_dead UNCONDITIONALLY, no booting/age
# gate at all. Used ONLY by the mutation test to prove the gate matters.
sim_ack_decision_prefix() {
  local peek_kind="$1" peek_dead
  case "$peek_kind" in
    gone) peek_dead=$(session_peek_reports_dead 'gc session peek: session not found: "sX"') ;;
    *)    peek_dead=$(session_peek_reports_dead 'live terminal scrollback for sX') ;;
  esac
  if [ "$peek_dead" = "1" ]; then echo "skip"; else echo "requeue"; fi
}

echo "── 2. sim_ack_decision: the ga-xwdl bug scenario ──"
eq "(a) 33s booting (state=creating), peek=gone → requeue (NEVER skip delivery)" \
  "$(sim_ack_decision creating 33 360 gone)" "requeue"
eq "(a2) 60s booting, peek=gone → requeue (still inside a real ~210s boot)" \
  "$(sim_ack_decision creating 60 360 gone)" "requeue"

echo "── 3. sim_ack_decision: genuinely drained (non-regression of ga-aknox) ──"
eq "(b) not booting, past grace (400>=360), peek=gone → skip (re-convene will re-spawn)" \
  "$(sim_ack_decision active 400 360 gone)" "skip"

echo "── 4. sim_ack_decision: ambiguous-early is NOT enough to skip ──"
eq "(c) not booting per list, but still inside grace (40<360), peek=gone → requeue" \
  "$(sim_ack_decision active 40 360 gone)" "requeue"

echo "── 5. sim_ack_decision: booting always wins, even past grace ──"
eq "(d) state=creating for 9999s (wedged boot) → requeue (booting overrides age)" \
  "$(sim_ack_decision creating 9999 360 gone)" "requeue"

echo "── 6. sim_ack_decision: inconclusive list read fails safe ──"
eq "(e) empty state (list call failed/unparseable), inside grace, peek=gone → requeue" \
  "$(sim_ack_decision "" 40 360 gone)" "requeue"
eq "(e2) empty state, but spawn_age is independently PAST grace → skip (an unparseable list read only fails safe DURING the grace window; session_is_booting(\"\")=0 so an empty read is never itself treated as 'booting' — only a literal state=creating is)" \
  "$(sim_ack_decision "" 400 360 gone)" "skip"

echo "── 7. sim_ack_decision: a live peek never skips, regardless of age/state ──"
eq "(f) not booting, past grace, peek=found (alive) → requeue (never skip a live reviewer)" \
  "$(sim_ack_decision active 400 360 found)" "requeue"
eq "(f2) booting, peek=found → requeue" \
  "$(sim_ack_decision creating 33 360 found)" "requeue"

echo "── 8. sim_ack_decision: grace boundary (>= is inclusive) ──"
eq "(g) spawn_age == grace exactly (360==360) → skip" \
  "$(sim_ack_decision active 360 360 gone)" "skip"
eq "(h) spawn_age one second short of grace (359<360) → requeue" \
  "$(sim_ack_decision active 359 360 gone)" "requeue"

echo "── (mutation) MUTATION TEST: the booting+age guard is load-bearing ──"
# Reproduce the exact PRE-ga-xwdl formula (peek-dead alone) for scenario (a)'s
# IDENTICAL inputs (a booting reviewer at 33s whose peek reports gone). If this
# pre-fix formula does NOT diverge from the fixed behavior in §2, scenario (a)
# would pass vacuously (i.e. even a reverted fix would pass it) — this proves
# it does not: the pre-fix formula flips straight to "skip", reproducing the
# exact ga-xwdl incident (task never delivered, reviewer idle 29m).
_prefix_result=$(sim_ack_decision_prefix gone)
eq "pre-ga-xwdl fold (no booting/age guard) reads the SAME scenario-(a) inputs as SKIP" \
  "$_prefix_result" "skip"
if [ "$_prefix_result" != "$(sim_ack_decision creating 33 360 gone)" ]; then
  ok "pre-fix (skip) vs post-fix (requeue, §2) diverge — the booting+age guard is what makes the difference"
else
  bad "pre-fix and post-fix formulas agree on scenario (a) — mutation test failed to demonstrate the guard matters"
fi

echo "── 9. drift-guard: dispatcher wires the ga-xwdl gate at the ga-aknox call site ──"
hasF "$DISPATCHER" '_ack_booting=$(session_is_booting "$_ack_state_flag")' \
  "ACK loop computes _ack_booting via the REAL session_is_booting helper"
hasF "$DISPATCHER" '_ack_spawn_age=$(( _ack_now - ${SLOT_SPAWN_EPOCH[$k]:-$_ack_now} ))' \
  "ACK loop computes _ack_spawn_age from the shared SLOT_SPAWN_EPOCH (ga-4u16h), fail-safe default=now"
hasF "$DISPATCHER" 'if [ "$(session_peek_reports_dead "$_ack_peek_stderr")" = "1" ] && [ "$_ack_booting" != "1" ] && [ "$_ack_spawn_age" -ge "$RECONVENE_GRACE_SECS" ]; then' \
  "ACK skip requires peek-dead AND not-booting AND past-grace (all three conjuncts present)"
hasF "$DISPATCHER" 'ACK skip (ga-aknox): reviewer $((k+1)) session=$_sid drained during startup (stale_async_start race) — nudge skipped, re-convene will re-spawn' \
  "original ga-aknox skip log message preserved (still reachable for genuinely-drained sessions)"
hasF "$DISPATCHER" 'session still booting (state=creating, spawn_age=${_ack_spawn_age}s, ga-xwdl) — re-queuing task session=$_sid' \
  "new booting-aware log message present (no longer claims a re-convene that will not fire)"

echo "── 10. non-regression: ga-flfo grace default + ga-67hae drain-exempt pin untouched ──"
hasF "$DISPATCHER" 'RECONVENE_GRACE_SECS="${RECONVENE_GRACE_SECS:-360}"' \
  "ga-flfo RECONVENE_GRACE_SECS default (360) unchanged"
hasF "$DISPATCHER" 'gc --city "$GC_CITY" session pin "$SESSION_ID" 2>/dev/null || true' \
  "ga-67hae drain-exempt session pin unchanged"

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" = "0" ]; then
  echo "PASS $PASS/$((PASS+FAIL)) — gate-ack-boot-grace selftest"
  exit 0
else
  echo "FAIL $FAIL/$((PASS+FAIL)) — gate-ack-boot-grace selftest"
  exit 1
fi
