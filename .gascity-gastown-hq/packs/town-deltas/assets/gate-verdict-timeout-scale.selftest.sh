#!/usr/bin/env bash
# gate-verdict-timeout-scale.selftest.sh — Prove the ga-ltr3c "scale the
# verdict-timeout by diff size" logic in isolation, with NO live Dolt/gc/launchd.
#
# Bug ga-ltr3c: reviews of a LARGE-but-green package (build map + embed dashboard
# + sweep + consolidate + tests — 1000s of lines across dozens of files; thies-wa
# wa-vnqx / digo-wa wa-bu2t) legitimately outran the FIXED VERDICT_TIMEOUT_MINUTES
# (22m) and were killed as "zombie" (age>verdict-timeout, no live reviewer) BEFORE
# emitting a verdict → an infinite re-submit loop on GOOD code.
#
# The fix scales the effective verdict timeout by the diff size:
#   effective = base + files×PER_FILE + (lines÷100)×PER_100L , clamped to [base, MAX].
# The MAX cap bounds worst-case dead-reviewer detection via the OUTER timeout; a
# genuinely DEAD reviewer is caught far sooner by the ga-4u16h re-convene probe
# (session gone/closed), which is INDEPENDENT of this outer timeout — so raising
# the ceiling never masks a stuck reviewer, it only stops false-FAILing big-but-
# live reviews.
#
# This harness SOURCES the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY)
# to unit-test the REAL pure function (gate_scaled_verdict_timeout), proves the
# config sanitization, and DRIFT-GUARDS the live script so a future refactor that
# drops the wiring fails loudly. Exit 0 iff every assertion holds.

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

type gate_scaled_verdict_timeout >/dev/null 2>&1 \
  || { echo "FATAL: gate_scaled_verdict_timeout not defined by dispatcher"; exit 1; }

# Quiet logging from the sourced helpers during the test.
log()  { :; }
warn() { :; }
err()  { :; }

# Reset scaling knobs to documented defaults for the deterministic cases below.
VERDICT_TIMEOUT_PER_FILE_MINUTES=1
VERDICT_TIMEOUT_PER_100_LINES_MINUTES=1
VERDICT_TIMEOUT_MAX_MINUTES=50

# ── 1. core scaling: effective = base + files + lines/100, clamped [base, MAX] ─
echo "── 1. gate_scaled_verdict_timeout core math ──"
eq "no diff (0,0) → base"                 "$(gate_scaled_verdict_timeout 22 0 0)"      "22"
eq "tiny (1 file, 10 lines) → base+1"     "$(gate_scaled_verdict_timeout 22 1 10)"     "23"
eq "5 files, 300 lines → 22+5+3"          "$(gate_scaled_verdict_timeout 22 5 300)"    "30"
eq "10 files, 999 lines → 22+10+9"        "$(gate_scaled_verdict_timeout 22 10 999)"   "41"
eq "lines floor: 99 lines → +0"           "$(gate_scaled_verdict_timeout 22 0 99)"     "22"
eq "lines: 100 lines → +1"                "$(gate_scaled_verdict_timeout 22 0 100)"    "23"

# ── 2. cap: a huge diff is clamped to MAX, never unbounded ────────────────────
echo "── 2. cap at VERDICT_TIMEOUT_MAX_MINUTES ──"
eq "huge (40 files, 5000 lines) → cap 50" "$(gate_scaled_verdict_timeout 22 40 5000)"  "50"
eq "exactly at cap stays at cap"          "$(gate_scaled_verdict_timeout 22 28 0)"     "50"
VERDICT_TIMEOUT_MAX_MINUTES=35
eq "lower cap honored (MAX=35)"           "$(gate_scaled_verdict_timeout 22 40 5000)"  "35"
VERDICT_TIMEOUT_MAX_MINUTES=50

# ── 3. fail-safe: non-numeric inputs contribute 0 → never below base ──────────
echo "── 3. fail-safe on garbage inputs (never drops below base) ──"
eq "files=foo → 0 contribution"           "$(gate_scaled_verdict_timeout 22 foo 300)"  "25"
eq "lines=bar → 0 contribution"           "$(gate_scaled_verdict_timeout 22 5 bar)"    "27"
eq "both garbage → base"                  "$(gate_scaled_verdict_timeout 22 x y)"      "22"
eq "empty inputs → base"                  "$(gate_scaled_verdict_timeout 22 '' '')"    "22"
eq "garbage base → default base 22"       "$(gate_scaled_verdict_timeout zz 0 0)"      "22"

# ── 4. env-tunable per-axis increments (0 disables an axis) ───────────────────
echo "── 4. per-axis increments are env-tunable ──"
VERDICT_TIMEOUT_PER_FILE_MINUTES=0
eq "PER_FILE=0 disables file axis"        "$(gate_scaled_verdict_timeout 22 40 0)"     "22"
VERDICT_TIMEOUT_PER_FILE_MINUTES=2
eq "PER_FILE=2 doubles file axis"         "$(gate_scaled_verdict_timeout 22 5 0)"      "32"
VERDICT_TIMEOUT_PER_FILE_MINUTES=1
VERDICT_TIMEOUT_PER_100_LINES_MINUTES=0
eq "PER_100L=0 disables line axis"        "$(gate_scaled_verdict_timeout 22 0 5000)"   "22"
VERDICT_TIMEOUT_PER_100_LINES_MINUTES=1

# ── 5. incoherent cap (MAX < base) floors at base, never below ────────────────
echo "── 5. MAX below base is incoherent → floored at base ──"
VERDICT_TIMEOUT_MAX_MINUTES=10
eq "MAX=10 < base=22 → base"              "$(gate_scaled_verdict_timeout 22 5 300)"    "22"
VERDICT_TIMEOUT_MAX_MINUTES=50

# ── 6. config defaults + sanitization (re-source with hostile env) ────────────
echo "── 6. config block sanitization ──"
( VERDICT_TIMEOUT_MAX_MINUTES="garbage" GATE_DISPATCHER_LIB_ONLY=1 \
    bash -c 'source "'"$DISPATCHER"'"; echo "$VERDICT_TIMEOUT_MAX_MINUTES"' 2>/dev/null ) \
  | { read -r v; eq "garbage MAX → default 50" "$v" "50"; }
( VERDICT_TIMEOUT_MAX_MINUTES="5" GATE_DISPATCHER_LIB_ONLY=1 \
    bash -c 'source "'"$DISPATCHER"'"; echo "$VERDICT_TIMEOUT_MAX_MINUTES"' 2>/dev/null ) \
  | { read -r v; eq "MAX below base floored to base (15 floor)" "$v" "22"; }
( VERDICT_TIMEOUT_PER_FILE_MINUTES="nope" GATE_DISPATCHER_LIB_ONLY=1 \
    bash -c 'source "'"$DISPATCHER"'"; echo "$VERDICT_TIMEOUT_PER_FILE_MINUTES"' 2>/dev/null ) \
  | { read -r v; eq "garbage PER_FILE → default 1" "$v" "1"; }

# ── 7. REVIEWER_SESSION_TTL derives from the MAX cap (reaper-safety) ───────────
echo "── 7. reviewer-session TTL tracks the scaled ceiling ──"
( GATE_DISPATCHER_LIB_ONLY=1 bash -c 'source "'"$DISPATCHER"'"; echo "$REVIEWER_SESSION_TTL_MINUTES $VERDICT_TIMEOUT_MAX_MINUTES" ' 2>/dev/null ) \
  | { read -r ttl maxm; eq "TTL = MAX + 20 margin" "$ttl" "$((maxm + 20))"; }

# ── 8. DRIFT-GUARD: live script must wire the scaling into the sweep ──────────
echo "── 8. drift-guard: wiring present in live dispatcher ──"
if grep -q 'VERDICT_TIMEOUT_MINUTES=$(gate_scaled_verdict_timeout' "$DISPATCHER"; then
  ok "sweep calls gate_scaled_verdict_timeout to override the timeout"
else
  bad "sweep does NOT wire gate_scaled_verdict_timeout — scaling is dead code"
fi
if grep -q 'diff --numstat' "$DISPATCHER"; then
  ok "sweep computes changed-line count (--numstat)"
else
  bad "sweep does NOT compute changed-line count — line axis is dead"
fi
if grep -q 'REVIEWER_SESSION_TTL_MINUTES.*VERDICT_TIMEOUT_MAX_MINUTES' "$DISPATCHER"; then
  ok "REVIEWER_SESSION_TTL derives from VERDICT_TIMEOUT_MAX_MINUTES"
else
  bad "REVIEWER_SESSION_TTL does NOT track the scaled ceiling — reaper may kill live big reviews"
fi

# ── 9. ga-4158gs: gate_heavy_selftest_floor_minutes — cost-of-companion-selftest ──
# Bug ga-4158gs: ga-wnojmm was a 2-file/~170-line diff to pilot-dispatcher.sh.
# gate_scaled_verdict_timeout (section 1-6 above) scaled that to only ~25m — but
# the reviewer's own A/B check runs pilot-dispatcher.selftest.sh (its ~900-scenario
# companion) TWICE, branch and base, inside that window. Directly measured
# (2026-09-19, quiet host): one solo run = 892/892 passed in 1099.84s (~18.3m) wall-
# clock, far more than the diff-size scaler ever assigns a 170-line diff. This
# function floors the timeout independently of diff size when a known-heavy file
# is touched.
echo "── 9. gate_heavy_selftest_floor_minutes: cost-of-companion-selftest floor ──"
type gate_heavy_selftest_floor_minutes >/dev/null 2>&1 \
  || { echo "FATAL: gate_heavy_selftest_floor_minutes not defined by dispatcher"; exit 1; }

VERDICT_TIMEOUT_HEAVY_SELFTEST_MARGIN_MINUTES=5
unset VERDICT_TIMEOUT_HEAVY_COST_PILOT_DISPATCHER_MINUTES

eq "no changed files → no floor" \
   "$(gate_heavy_selftest_floor_minutes '')" "0"
eq "diff touches only a light file → no floor" \
   "$(gate_heavy_selftest_floor_minutes 'packs/town-deltas/assets/some-other-script.sh')" "0"
eq "diff touches a selftest SIBLING (not the file itself) → no floor" \
   "$(gate_heavy_selftest_floor_minutes 'packs/town-deltas/assets/pilot-dispatcher.lock.selftest.sh')" "0"
PD_COST="${VERDICT_TIMEOUT_HEAVY_COST_PILOT_DISPATCHER_MINUTES:-20}"
eq "diff touches pilot-dispatcher.sh → floor = cost×2+margin" \
   "$(gate_heavy_selftest_floor_minutes 'packs/town-deltas/assets/pilot-dispatcher.sh')" \
   "$((PD_COST * 2 + 5))"
eq "match works within a multi-file CHANGED_FILES list, any position" \
   "$(gate_heavy_selftest_floor_minutes "$(printf 'a.md\npacks/town-deltas/assets/pilot-dispatcher.sh\nb.py\n')")" \
   "$((PD_COST * 2 + 5))"

echo "── 9b. floor is env-tunable (re-measurement never needs a code change) ──"
VERDICT_TIMEOUT_HEAVY_COST_PILOT_DISPATCHER_MINUTES=35
eq "cost override raises the floor" \
   "$(gate_heavy_selftest_floor_minutes 'packs/town-deltas/assets/pilot-dispatcher.sh')" "75"
VERDICT_TIMEOUT_HEAVY_SELFTEST_MARGIN_MINUTES=0
eq "margin override of 0 is honored" \
   "$(gate_heavy_selftest_floor_minutes 'packs/town-deltas/assets/pilot-dispatcher.sh')" "70"
VERDICT_TIMEOUT_HEAVY_COST_PILOT_DISPATCHER_MINUTES="garbage"
eq "non-numeric cost override → entry skipped, no floor (fail-safe)" \
   "$(gate_heavy_selftest_floor_minutes 'packs/town-deltas/assets/pilot-dispatcher.sh')" "0"
unset VERDICT_TIMEOUT_HEAVY_COST_PILOT_DISPATCHER_MINUTES VERDICT_TIMEOUT_HEAVY_SELFTEST_MARGIN_MINUTES

echo "── 9c. own ceiling: a runaway cost is clamped, never unbounded ──"
VERDICT_TIMEOUT_HEAVY_COST_PILOT_DISPATCHER_MINUTES=1000
eq "runaway cost override is clamped to the default 120m ceiling" \
   "$(gate_heavy_selftest_floor_minutes 'packs/town-deltas/assets/pilot-dispatcher.sh')" "120"
VERDICT_TIMEOUT_HEAVY_SELFTEST_FLOOR_MAX_MINUTES=30
eq "ceiling itself is env-tunable" \
   "$(gate_heavy_selftest_floor_minutes 'packs/town-deltas/assets/pilot-dispatcher.sh')" "30"
unset VERDICT_TIMEOUT_HEAVY_COST_PILOT_DISPATCHER_MINUTES VERDICT_TIMEOUT_HEAVY_SELFTEST_FLOOR_MAX_MINUTES

echo "── 9d. drift-guard: the floor is actually wired into the sweep, and WINS ──"
if grep -q 'gate_heavy_selftest_floor_minutes "\$CHANGED_FILES"' "$DISPATCHER"; then
  ok "sweep calls gate_heavy_selftest_floor_minutes with the real changed-files list"
else
  bad "sweep does NOT call gate_heavy_selftest_floor_minutes — heavy-file floor is dead code"
fi
if grep -q '_VT_HEAVY_FLOOR" -gt "\$VERDICT_TIMEOUT_MINUTES"' "$DISPATCHER"; then
  ok "sweep raises VERDICT_TIMEOUT_MINUTES when the heavy floor exceeds the diff-scaled value"
else
  bad "sweep does NOT compare the heavy floor against the scaled timeout — floor can never win"
fi
if grep -q 'VERDICT_TIMEOUT_MINUTES + 20))" -gt "\$REVIEWER_SESSION_TTL_MINUTES"' "$DISPATCHER"; then
  ok "sweep also raises REVIEWER_SESSION_TTL_MINUTES so the reviewer session outlives the heavy floor"
else
  bad "REVIEWER_SESSION_TTL_MINUTES is NOT kept in sync with the heavy floor — reviewer session could be reaped before the floored verdict timeout elapses"
fi

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
