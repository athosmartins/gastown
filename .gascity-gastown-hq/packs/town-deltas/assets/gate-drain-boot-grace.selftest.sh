#!/usr/bin/env bash
# gate-drain-boot-grace.selftest.sh (ga-wcd86)
#
# Bug ga-wcd86: gate-reviewer-adhoc-1d1eb9c5ed (session_id=ga-wfvxy) was
# excluded from LIVE_REVIEWERS at age=0m, seconds after being respawned to
# keep its pool slot warm, and sat idle+untasked for its entire life while
# the dispatcher paid the cost of spawning a brand-new reviewer instead.
#
# Root cause (packs/town-deltas/assets/quality-gate-dispatcher.sh, Step 0a-2,
# the gt-bewtm drained-exclusion block): `gc session peek` reports "session
# not found" on stderr for BOTH a genuinely drained/ended session AND one
# still inside its ~210s deferred-start boot window (ga-flfo) — the identical
# string session_peek_reports_dead() matches for "gone". Step 0a-2 trusted
# that signal UNCONDITIONALLY, with no lower-bound grace period, so a
# newborn reviewer peeked while still booting read as "drained" and got
# excluded from the headroom denominator. Nothing ever reconsiders an
# excluded-but-still-alive session, so the exclusion is permanent for that
# session's whole life.
#
# This is the SAME root class as ga-xwdl (a few hundred lines below, in Step
# 7b's ACK loop) — which already carries the fix: gate the "peek says gone"
# signal behind session_is_booting(state) and RECONVENE_GRACE_SECS, and only
# trust it as a confirmed drain once the session is not currently booting AND
# has been alive long enough that boot could not still explain a "not found"
# read. ga-wcd86 extends that SAME guard to Step 0a-2.
#
# Step 0a-2 is inline top-level script (not a function) — like
# gate-ack-boot-grace.selftest.sh for the sibling ga-xwdl fix, this harness
# sources the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY) to get
# the REAL session_is_booting/session_peek_reports_dead/RECONVENE_GRACE_SECS,
# then re-derives the EXACT new gating expression as a small simulation
# function so it can be driven with controlled inputs (no live Dolt/gc/
# launchd).
#
# Mutation-tested (AC2's acceptance criterion): reproducing the PRE-FIX bare
# formula (peek-dead alone, no booting/age gate) against the SAME age=0m
# booting-reviewer inputs from the live incident flips the outcome to
# "drained" — proving the guard added here is what makes the fixed scenario
# pass, not a vacuous assertion.
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

# ── Simulation: mirrors Step 0a-2's DRAINED_REVIEWERS gate EXACTLY (ga-wcd86) ─
# sim_step0a2_drain_decision <state> <age_seconds> <grace> <peek_kind: gone|found>
#   → "drained" (excluded from LIVE_REVIEWERS) | "live" (counted, not excluded)
sim_step0a2_drain_decision() {
  local state="$1" age_seconds="$2" grace="$3" peek_kind="$4"
  local booting peek_dead
  booting=$(session_is_booting "$state")
  case "$peek_kind" in
    gone) peek_dead=$(session_peek_reports_dead 'gc session peek: session not found: "sX"') ;;
    *)    peek_dead=$(session_peek_reports_dead 'live terminal scrollback for sX') ;;
  esac
  if [ "$peek_dead" = "1" ] && [ "$booting" != "1" ] && [ "$age_seconds" -ge "$grace" ]; then
    echo "drained"
  else
    echo "live"
  fi
}

# sim_step0a2_drain_decision_prefix <peek_kind> — the ORIGINAL (pre-ga-wcd86)
# Step 0a-2 formula: trusts session_peek_reports_dead UNCONDITIONALLY, no
# booting/age gate at all. Used ONLY by the mutation test to prove the gate
# matters.
sim_step0a2_drain_decision_prefix() {
  local peek_kind="$1" peek_dead
  case "$peek_kind" in
    gone) peek_dead=$(session_peek_reports_dead 'gc session peek: session not found: "sX"') ;;
    *)    peek_dead=$(session_peek_reports_dead 'live terminal scrollback for sX') ;;
  esac
  if [ "$peek_dead" = "1" ]; then echo "drained"; else echo "live"; fi
}

echo "── 2. sim_step0a2_drain_decision: the ga-wcd86 live-incident scenario ──"
# gate-reviewer-adhoc-1d1eb9c5ed (ga-wfvxy): respawned at 11:39:23, drained by
# Step 0a-2 at 11:39:54 — age=31s, state=creating (start-pending), peek=gone.
eq "(a) age=0s, state=creating, peek=gone → live (NEVER exclude a newborn)" \
  "$(sim_step0a2_drain_decision creating 0 360 gone)" "live"
eq "(a2) age=31s, state=creating, peek=gone → live (the EXACT live-incident timing)" \
  "$(sim_step0a2_drain_decision creating 31 360 gone)" "live"
eq "(a3) age=60s, state=creating, peek=gone → live (still inside a real ~210s boot)" \
  "$(sim_step0a2_drain_decision creating 60 360 gone)" "live"

echo "── 3. sim_step0a2_drain_decision: genuinely drained (AC3 non-regression) ──"
eq "(b) not booting, past grace (400>=360), peek=gone → drained (excluded, as before)" \
  "$(sim_step0a2_drain_decision asleep 400 360 gone)" "drained"

echo "── 4. sim_step0a2_drain_decision: ambiguous-early is NOT enough to exclude ──"
eq "(c) not booting per list, but still inside grace (40<360), peek=gone → live" \
  "$(sim_step0a2_drain_decision asleep 40 360 gone)" "live"

echo "── 5. sim_step0a2_drain_decision: booting always wins, even past grace ──"
eq "(d) state=creating for 9999s (wedged boot) → live (booting overrides age)" \
  "$(sim_step0a2_drain_decision creating 9999 360 gone)" "live"

echo "── 6. sim_step0a2_drain_decision: inconclusive list read fails safe ──"
eq "(e) empty state (list call failed/unparseable), inside grace, peek=gone → live" \
  "$(sim_step0a2_drain_decision "" 40 360 gone)" "live"
eq "(e2) empty state, but age is independently PAST grace → drained (an unparseable list read only fails safe DURING the grace window; session_is_booting(\"\")=0 so an empty read is never itself treated as 'booting' — only a literal state=creating is)" \
  "$(sim_step0a2_drain_decision "" 400 360 gone)" "drained"

echo "── 7. sim_step0a2_drain_decision: a live peek never excludes, regardless of age/state ──"
eq "(f) not booting, past grace, peek=found (alive) → live (never exclude a live reviewer)" \
  "$(sim_step0a2_drain_decision asleep 400 360 found)" "live"
eq "(f2) booting, peek=found → live" \
  "$(sim_step0a2_drain_decision creating 33 360 found)" "live"

echo "── 8. sim_step0a2_drain_decision: grace boundary (>= is inclusive) ──"
eq "(g) age == grace exactly (360==360) → drained" \
  "$(sim_step0a2_drain_decision asleep 360 360 gone)" "drained"
eq "(h) age one second short of grace (359<360) → live" \
  "$(sim_step0a2_drain_decision asleep 359 360 gone)" "live"

echo "── (mutation) MUTATION TEST: the booting+age guard is load-bearing (AC2) ──"
# Reproduce the exact PRE-ga-wcd86 formula (peek-dead alone) for scenario
# (a2)'s IDENTICAL inputs (the live incident: age=31s, state=creating,
# peek=gone). If this pre-fix formula does NOT diverge from the fixed
# behavior in §2, scenario (a2) would pass vacuously (i.e. even a reverted fix
# would pass it) — this proves it does not: the pre-fix formula flips straight
# to "drained", reproducing the exact ga-wcd86 incident (newborn reviewer
# excluded from LIVE_REVIEWERS at age=0m, sat idle its whole life).
_prefix_result=$(sim_step0a2_drain_decision_prefix gone)
eq "pre-ga-wcd86 fold (no booting/age guard) reads the SAME scenario-(a2) inputs as DRAINED" \
  "$_prefix_result" "drained"
if [ "$_prefix_result" != "$(sim_step0a2_drain_decision creating 31 360 gone)" ]; then
  ok "pre-fix (drained) vs post-fix (live, §2) diverge — the booting+age guard is what makes the difference"
else
  bad "pre-fix and post-fix formulas agree on scenario (a2) — mutation test failed to demonstrate the guard matters"
fi

echo "── 9. drift-guard: dispatcher wires the ga-wcd86 gate at the Step 0a-2 call site ──"
hasF "$DISPATCHER" 'R_AGE_SECONDS=$(( NOW_EPOCH_R - R_EPOCH ))' \
  "Step 0a-2 computes R_AGE_SECONDS from the same NOW_EPOCH_R/R_EPOCH already used for R_AGE_MINUTES"
hasF "$DISPATCHER" 'R_BOOTING=$(session_is_booting "$R_STATE")' \
  "Step 0a-2 computes R_BOOTING via the REAL session_is_booting helper, from R_STATE already fetched this sweep"
hasF "$DISPATCHER" 'if [ "$R_BOOTING" != "1" ] && [ "$R_AGE_SECONDS" -ge "$RECONVENE_GRACE_SECS" ]; then' \
  "drain-exclusion requires not-booting AND past-grace before trusting peek-dead (both conjuncts present)"
hasF "$DISPATCHER" 'session_peek_reports_dead "$_R_PEEK_ERR"' \
  "outer gate still uses session_peek_reports_dead as the peek discriminator (unchanged)"
hasF "$DISPATCHER" 'excluding from headroom LIVE_REVIEWERS (gt-bewtm).' \
  "original gt-bewtm drain-exclusion log message preserved (still reachable for genuinely-drained sessions)"
hasF "$DISPATCHER" 'peek reports session-gone but NOT excluded from headroom (ga-wcd86): booting=$R_BOOTING age=${R_AGE_SECONDS}s vs RECONVENE_GRACE_SECS=${RECONVENE_GRACE_SECS}s.' \
  "new boot-grace log message present (no longer silently excludes a newborn reviewer) — states facts, not a specific inequality (the log must stay accurate even in the wedged-boot case, booting=1 past grace)"

echo "── 10. non-regression: DRAINED_REVIEWERS counting + ga-flfo grace default untouched ──"
hasF "$DISPATCHER" 'DRAINED_REVIEWERS=$((DRAINED_REVIEWERS + 1))' \
  "DRAINED_REVIEWERS still incremented for confirmed drains (only the gate above it changed)"
hasF "$DISPATCHER" 'RECONVENE_GRACE_SECS="${RECONVENE_GRACE_SECS:-360}"' \
  "ga-flfo RECONVENE_GRACE_SECS default (360) unchanged"
hasF "$DISPATCHER" 'session peek "$R_ID" --lines 1 2>&1 >/dev/null' \
  "drained peek still captures stderr-only (live scrollback can't false-match) — ga-h9o17 unchanged"

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" = "0" ]; then
  echo "PASS $PASS/$((PASS+FAIL)) — gate-drain-boot-grace selftest"
  exit 0
else
  echo "FAIL $FAIL/$((PASS+FAIL)) — gate-drain-boot-grace selftest"
  exit 1
fi
