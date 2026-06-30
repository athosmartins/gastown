#!/usr/bin/env bash
# gate-reviewer-stale-scale.selftest.sh — Prove the ga-evjs2 "scale the frozen-
# reviewer staleness window by diff size" logic in isolation, NO live Dolt/gc/launchd.
#
# Bug ga-evjs2: the frozen-reviewer probe (ga-q8tmn) declared a reviewer DEAD after a
# FIXED REVIEWER_STALE_SECS (300s) of silence. A reviewer reading a LARGE diff is
# legitimately quiet longer than one on a 1-file change, so big-diff reviewers were
# false-reaped at 5min → respawn → re-read the same huge diff, silent >5min again →
# reaped again → DEATH-SPIRAL (observed 2026-06-30: a 3885-line re-land bead drove a
# 72% reviewer-death rate over 3h, 213 respawns, gate merged nothing ~10h).
#
# The fix scales the staleness window by diff size, mirroring the verdict-timeout
# scaler (ga-ltr3c) but in SECONDS:
#   effective = base + files×PER_FILE_SECS + (lines÷100)×PER_100L_SECS, clamped [base, MAX].
# The MAX cap keeps a genuinely-frozen reviewer reaped well under the OUTER verdict
# timeout; the grace + dead-streak guards in the caller remain the backstops. A base of
# 0 (probe disabled) passes straight through so the disable knob is honored.
#
# This harness SOURCES the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY) to
# unit-test the REAL pure function (gate_scaled_reviewer_stale), proves the config
# sanitization, and DRIFT-GUARDS the live wiring. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type gate_scaled_reviewer_stale >/dev/null 2>&1 \
  || { echo "FATAL: gate_scaled_reviewer_stale not defined by dispatcher"; exit 1; }

# Quiet logging from the sourced helpers during the test.
log()  { :; }
warn() { :; }
err()  { :; }

# Reset scaling knobs to documented defaults for the deterministic cases below.
REVIEWER_STALE_PER_FILE_SECS=20
REVIEWER_STALE_PER_100_LINES_SECS=15
REVIEWER_STALE_MAX_SECS=900

# ── 1. core scaling: effective = base + files×20 + (lines/100)×15, clamped ─────
echo "── 1. gate_scaled_reviewer_stale core math ──"
eq "no diff (0,0) → base"                 "$(gate_scaled_reviewer_stale 300 0 0)"      "300"
eq "tiny (1 file, 50 lines) → base+20"    "$(gate_scaled_reviewer_stale 300 1 50)"     "320"
eq "5 files, 300 lines → 300+100+45"      "$(gate_scaled_reviewer_stale 300 5 300)"    "445"
eq "lines floor: 99 lines → +0"           "$(gate_scaled_reviewer_stale 300 0 99)"     "300"
eq "lines: 100 lines → +15"               "$(gate_scaled_reviewer_stale 300 0 100)"    "315"

# ── 2. cap: a huge diff is clamped to MAX, never unbounded ────────────────────
echo "── 2. cap at REVIEWER_STALE_MAX_SECS ──"
eq "the spiral diff (8 files, 3885) → cap" "$(gate_scaled_reviewer_stale 300 8 3885)"  "900"
eq "the sibling diff (12 files, 2513) → cap" "$(gate_scaled_reviewer_stale 300 12 2513)" "900"
REVIEWER_STALE_MAX_SECS=600
eq "lower cap honored (MAX=600)"          "$(gate_scaled_reviewer_stale 300 40 5000)"  "600"
REVIEWER_STALE_MAX_SECS=900

# ── 3. disabled base (probe off) passes straight through ──────────────────────
echo "── 3. base=0 (probe disabled) → 0 regardless of diff ──"
eq "disabled stays disabled"              "$(gate_scaled_reviewer_stale 0 8 3885)"     "0"

# ── 4. fail-safe: non-numeric inputs contribute 0 → never below base ──────────
echo "── 4. fail-safe on garbage inputs (never drops below base) ──"
eq "files=foo → 0 contribution"           "$(gate_scaled_reviewer_stale 300 foo 300)"  "345"
eq "lines=bar → 0 contribution"           "$(gate_scaled_reviewer_stale 300 5 bar)"    "400"
eq "both garbage → base"                  "$(gate_scaled_reviewer_stale 300 x y)"      "300"
eq "empty inputs → base"                  "$(gate_scaled_reviewer_stale 300 '' '')"    "300"
eq "garbage base → default base 300"      "$(gate_scaled_reviewer_stale zz 0 0)"       "300"

# ── 5. per-axis increments are env-tunable (0 disables an axis) ───────────────
echo "── 5. per-axis increments are env-tunable ──"
REVIEWER_STALE_PER_FILE_SECS=0
eq "PER_FILE=0 disables file axis"        "$(gate_scaled_reviewer_stale 300 40 0)"     "300"
REVIEWER_STALE_PER_FILE_SECS=20
REVIEWER_STALE_PER_100_LINES_SECS=0
eq "PER_100L=0 disables line axis"        "$(gate_scaled_reviewer_stale 300 0 5000)"   "300"
REVIEWER_STALE_PER_100_LINES_SECS=15

# ── 6. incoherent cap (MAX < base) floors at base, never below ────────────────
echo "── 6. MAX below base is incoherent → floored at base ──"
REVIEWER_STALE_MAX_SECS=100
eq "MAX=100 < base=300 → base"            "$(gate_scaled_reviewer_stale 300 5 300)"    "300"
REVIEWER_STALE_MAX_SECS=900

# ── 7. config defaults + sanitization (re-source with hostile env) ────────────
echo "── 7. config block sanitization ──"
( REVIEWER_STALE_PER_FILE_SECS="garbage" GATE_DISPATCHER_LIB_ONLY=1 \
    bash -c 'source "'"$DISPATCHER"'"; echo "$REVIEWER_STALE_PER_FILE_SECS"' 2>/dev/null ) \
  | { read -r v; eq "garbage PER_FILE → default 20" "$v" "20"; }
( REVIEWER_STALE_MAX_SECS="nope" GATE_DISPATCHER_LIB_ONLY=1 \
    bash -c 'source "'"$DISPATCHER"'"; echo "$REVIEWER_STALE_MAX_SECS"' 2>/dev/null ) \
  | { read -r v; eq "garbage MAX → default 900" "$v" "900"; }

# ── 8. DRIFT-GUARD: live script must wire the scaling into the sweep ──────────
echo "── 8. drift-guard: wiring present in live dispatcher ──"
if grep -q 'REVIEWER_STALE_SECS_SCALED=$(gate_scaled_reviewer_stale' "$DISPATCHER"; then
  ok "sweep computes the diff-scaled staleness window"
else
  bad "sweep does NOT wire gate_scaled_reviewer_stale — scaling is dead code"
fi
if grep -q '_stale_thresh=' "$DISPATCHER" && grep -q 'reviewer_last_active_stale "\$_last_active" "\$NOW_EPOCH" "\$_stale_thresh"' "$DISPATCHER"; then
  ok "frozen-reviewer probe consumes the scaled threshold (_stale_thresh)"
else
  bad "frozen-reviewer probe still uses the FIXED window — scaling is not consumed"
fi

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
