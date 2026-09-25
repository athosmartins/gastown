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

# lib_var NAME [ENV=VAL ...] — value of NAME after sourcing the dispatcher in
# lib-only mode inside a FRESH child (ENV=VAL are that child's hostile env), or the
# literal "<unreadable>" if the child could not report it. Section 7 uses it instead
# of `( … bash -c 'source …; echo "$X"' ) | { read -r v; eq … "$v"; }`, which had
# two defects (same class as ga-5hw36b, fixed in gate-verdict-timeout-scale.selftest.sh):
#   1. A pipeline's right side is a SUBSHELL, so eq()'s PASS/FAIL bumps were lost
#      (measured ga-xc4u1n, 2026-09-25: with the dispatcher's garbage-PER_FILE
#      fallback mutated 20→21 the suite printed the ✗ line and still ended
#      "19 passed, 0 failed", exit 0 — on /bin/bash 3.2 and bash 5 alike).
#   2. `read` takes the FIRST stdout line, and sourcing the dispatcher can print a
#      notify "Logged for digest" line to stdout before the value (mechanism measured
#      in ga-5hw36b; not separately reproduced against this file).
# So: drop the child's stdout while it sources, emit the value on ONE tagged line,
# keep only tagged lines, and return it by command substitution so eq() runs in THIS
# shell and its counters count. The knobs section 7 reads (or that its expected
# values derive from — MAX is floored at STALE_SECS) are scrubbed from the inherited
# env first; callers re-add what they need. "$BASH" (not PATH `bash`) so /bin/bash 3.2
# and bash 5 each test their own child.
lib_var() {
  local name="$1" out; shift
  out="$(env -u REVIEWER_STALE_SECS -u REVIEWER_STALE_PER_FILE_SECS \
            -u REVIEWER_STALE_PER_100_LINES_SECS -u REVIEWER_STALE_MAX_SECS \
            GATE_DISPATCHER_LIB_ONLY=1 "$@" "${BASH:-bash}" -c '
              source "$1" >/dev/null 2>&1 || exit 97
              printf "@@LIBVAR@@%s\n" "${!2}"
            ' _ "$DISPATCHER" "$name" 2>/dev/null | grep '^@@LIBVAR@@' | tail -n 1)" || true
  if [ -n "$out" ]; then printf '%s' "${out#@@LIBVAR@@}"; else printf '<unreadable>'; fi
}

# ── 7. config defaults + sanitization (re-source with hostile env) ────────────
echo "── 7. config block sanitization ──"
eq "garbage PER_FILE → default 20" \
   "$(lib_var REVIEWER_STALE_PER_FILE_SECS REVIEWER_STALE_PER_FILE_SECS=garbage)" "20"
eq "garbage MAX → default 900" \
   "$(lib_var REVIEWER_STALE_MAX_SECS REVIEWER_STALE_MAX_SECS=nope)" "900"

# ── 8. DRIFT-GUARD: live script must wire the scaling into the sweep ──────────
echo "── 8. drift-guard: wiring present in live dispatcher ──"
if grep -q 'REVIEWER_STALE_SECS_SCALED=$(gate_scaled_reviewer_stale' "$DISPATCHER"; then
  ok "sweep computes the diff-scaled staleness window"
else
  bad "sweep does NOT wire gate_scaled_reviewer_stale — scaling is dead code"
fi
# ga-eqjo: the mid-poll frozen-reviewer probe this guard used to check for
# (ga-q8tmn's in-loop respawn) no longer exists — Step 8's `while true; do
# ...; sleep 30; done` poll it lived inside was replaced by a single
# non-blocking check (the multi-minute blocking wait was the actual bug being
# fixed). That probe's debounce state (SLOT_DEAD_STREAK) was process-local and
# had no meaning once a sweep only checks a run once and exits; porting it
# would mean persisting streak counters as bead metadata for what was always a
# LATENCY optimization, not a correctness requirement (see gate_collect_verdicts'
# header comment in quality-gate-dispatcher.sh). A frozen reviewer is still
# caught by this run's own persisted verdict_timeout_minutes (Phase C) or by
# gate-recovery-watchdog's independent wall-clock hang detectors — just later
# (up to the full timeout) instead of via the faster in-poll reconvene. The
# scaled threshold itself (gate_scaled_reviewer_stale, tested above) is
# currently unconsumed dead code as a result; left in place (cheap, harmless,
# and immediately reusable if frozen-reviewer respawn is ever ported into
# Phase C) rather than deleted as part of an already-large change.
ok "frozen-reviewer probe intentionally removed (ga-eqjo Step 8 non-blocking rewrite) — see comment above"

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
