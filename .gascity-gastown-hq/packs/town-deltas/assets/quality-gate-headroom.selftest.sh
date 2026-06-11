#!/usr/bin/env bash
# quality-gate-headroom.selftest.sh — Prove the ga-cw4pm dynamic-concurrency
# (Dolt + Claude-quota headroom) gate in isolation, with NO live Dolt/gc/quota.
#
# Bug ga-cw4pm: the gate's concurrency was STATIC. The gate-reviewer template's
# max_active_sessions=6 admits up to 2 CODE runs (3 reviewers each) regardless of
# how loaded the Dolt :52756 data plane is. When Dolt was already saturated (by a
# sibling run, the supervisor's per-rig reconcile scan, or the Pilot) the gate
# STILL opened a second run × 3 reviewers → thundering herd → Dolt 200%+ →
# reviewers boot-stall on `gc prime` → verdict timeout → FALSE-FAIL on good code.
#
# The fix adds a DYNAMIC ceiling on concurrent reviewer sessions, computed from
# live Dolt CPU/latency + quota (mirroring the Pilot's dispatch-to-capacity gate,
# ga-rk5va). Before opening a new run the dispatcher probes headroom and either
# admits (Dolt calm → scale to the static 6; warm → one run only) or DEFERs
# (Dolt hot OR quota limited → open no run, leave the FIFO marker queued).
#
# This harness SOURCES the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY)
# to unit-test its REAL pure decision (gate_headroom_decision) and the REAL probe
# helpers (gate_dolt_cpu, gate_quota_limited) across the full matrix, then
# DRIFT-GUARDS the live wiring so a future refactor that drops the gate, the
# override seams, the fail-open default, or the AC4 log fails loudly.
# Exit 0 iff every assertion holds.
#
# Acceptance criteria proven:
#   AC1 Dolt hot → opens NO new run (defer), instead of saturating.
#   AC2 Dolt calm → scales up to the ceiling (admits run 1 then run 2, caps at 6).
#   AC3 zero thundering-herd: a 2nd run is deferred while one run keeps Dolt warm,
#       and ALL runs are deferred once Dolt crosses the hot ceiling.
#   AC4 logs 'gate em N runs (Dolt X% / cota Y%)'.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ─────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type gate_headroom_decision >/dev/null 2>&1 || { echo "FATAL: gate_headroom_decision not defined"; exit 1; }
type gate_dolt_cpu          >/dev/null 2>&1 || { echo "FATAL: gate_dolt_cpu not defined"; exit 1; }
type gate_quota_limited     >/dev/null 2>&1 || { echo "FATAL: gate_quota_limited not defined"; exit 1; }

# Quiet any logging from sourced helpers (none call it today, but be safe).
log()  { :; }
warn() { :; }
err()  { :; }

# Fixed thresholds for the matrix (the dispatcher's defaults).
#   gate_headroom_decision <cpu> <lat> <qlim> <inflight> \
#     <cpu_hot=180> <cpu_warm=100> <lat_hot=2500> <maxr=6> <perrun=3> <failopen>
HD() { gate_headroom_decision "$1" "$2" "$3" "$4" 180 100 2500 6 3 "${5:-1}"; }

echo "── 1. AC2: Dolt CALM scales up to the ceiling (static 6) ──"
eq "calm + 0 in-flight   → admit run 1"        "$(HD 50 120 0 0)" "admit 6 dolt-calm"
eq "calm + 1 run (3)     → admit run 2"        "$(HD 50 120 0 3)" "admit 6 dolt-calm"
eq "calm + 2 runs (6)    → defer (cap=6)"      "$(HD 50 120 0 6)" "defer 6 dolt-calm-cap-reached"

echo "── 2. AC1+AC3: Dolt HOT opens NO run, regardless of in-flight ──"
eq "hot (cpu>180) + idle → defer"              "$(HD 220 120 0 0)" "defer 0 dolt-hot"
eq "hot + 1 run          → defer"              "$(HD 220 120 0 3)" "defer 0 dolt-hot"
eq "latency hot (>2500)  → defer"              "$(HD 50 9000 0 0)" "defer 0 dolt-hot"

echo "── 3. AC3: Dolt WARM allows exactly ONE run (serializes; no herd) ──"
eq "warm (100<cpu≤180) idle → admit one run"   "$(HD 140 120 0 0)" "admit 3 dolt-warm"
eq "warm + 1 run already     → defer 2nd"      "$(HD 140 120 0 3)" "defer 3 dolt-warm-cap-reached"

echo "── 4. quota limit is an independent hard-stop (even on a calm Dolt) ──"
eq "calm Dolt but quota LIMITED → defer"       "$(HD 50 120 1 0)" "defer 0 quota-limited"

echo "── 5. boundaries are strict (> not ≥): exactly-at threshold is the cooler tier ──"
eq "cpu == warm(100) → calm, not warm"         "$(HD 100 120 0 0)" "admit 6 dolt-calm"
eq "cpu == hot(180)  → warm, not hot"          "$(HD 180 120 0 0)" "admit 3 dolt-warm"
eq "lat == hot(2500) → not hot"                "$(HD 50 2500 0 0)" "admit 6 dolt-calm"

echo "── 6. no-signal fail-OPEN (default) vs fail-CLOSED (opt-in) ──"
# A wedged probe must NEVER deadlock the critical-path gate → default proceeds.
eq "no cpu/lat + failopen=1 → admit (max)"     "$(HD '' '' 0 0 1)" "admit 6 no-signal-failopen"
eq "no cpu/lat + failopen=0 → defer"           "$(HD '' '' 0 0 0)" "defer 0 no-signal-failclosed"
# A positively-measured hot reading still defers even under fail-open.
eq "failopen but measured hot → still defer"   "$(HD 220 '' 0 0 1)" "defer 0 dolt-hot"

echo "── 7. junk inputs degrade safely (no crash; sane default tier) ──"
eq "non-numeric cpu (lat ok, calm) → admit"    "$(HD NaN 120 0 0)" "admit 6 dolt-calm"
eq "non-numeric inflight → treated as 0"       "$(HD 50 120 0 NaN)" "admit 6 dolt-calm"

echo "── 8. gate_dolt_cpu — override seam + no-pid → empty (no live ps) ──"
eq "override seam returns the forced value"    "$(GATE_DOLT_CPU_OVERRIDE=77 gate_dolt_cpu TEST)" "77"
eq "no pid → empty (cannot read ps)"           "$(gate_dolt_cpu '')" ""
eq "TEST pid (no override) → empty"            "$(gate_dolt_cpu TEST)" ""

echo "── 9. gate_quota_limited — override seam + fail-open when checker absent ──"
eq "override 2 → LIMITED (1)"                  "$(GATE_QUOTA_OVERRIDE=2 gate_quota_limited)" "1"
eq "override 0 → ok (0)"                       "$(GATE_QUOTA_OVERRIDE=0 gate_quota_limited)" "0"
# No override, but point GC_CITY at a dir with no checker → fail-open (0), never block.
eq "checker absent → fail-open (0)"            "$(GC_CITY=/nonexistent-gate-headroom-test gate_quota_limited)" "0"

echo "── 10. drift-guard: the real dispatcher still DEFINES the helpers ──"
has "$DISPATCHER" 'gate_headroom_decision\(\)'  "pure decision is defined"
has "$DISPATCHER" 'gate_dolt_cpu\(\)'           "Dolt CPU probe is defined"
has "$DISPATCHER" 'gate_quota_limited\(\)'      "quota probe is defined"

echo "── 11. drift-guard: thresholds + escape hatches are configured ──"
has "$DISPATCHER" 'GATE_DOLT_CPU_HOT'           "hot CPU threshold configured"
has "$DISPATCHER" 'GATE_DOLT_CPU_WARM'          "warm CPU threshold configured"
has "$DISPATCHER" 'GATE_DOLT_LATENCY_HOT_MS'    "hot latency threshold configured"
has "$DISPATCHER" 'GATE_MAX_REVIEWERS'          "max-reviewers ceiling configured"
has "$DISPATCHER" 'GATE_REVIEWERS_PER_RUN'      "reviewers-per-run unit configured"
has "$DISPATCHER" 'GATE_HEADROOM_ENABLED'       "whole-gate escape hatch present"
has "$DISPATCHER" 'GATE_HEADROOM_FAILOPEN'      "fail-open knob present"

echo "── 12. drift-guard: fail-open is the DEFAULT (critical-path safety) ──"
has "$DISPATCHER" 'GATE_HEADROOM_FAILOPEN:-1'   "fail-open defaults to 1"

echo "── 13. drift-guard: selftest override seams are wired into the live probe ──"
has "$DISPATCHER" 'GATE_DOLT_LATENCY_OVERRIDE_MS' "latency override seam wired"
has "$DISPATCHER" 'GATE_DOLT_CPU_OVERRIDE'        "cpu override seam wired"
has "$DISPATCHER" 'GATE_QUOTA_OVERRIDE'           "quota override seam wired"

echo "── 14. drift-guard: the headroom gate is wired in + counts live reviewers ──"
has "$DISPATCHER" 'Step 0b-1'                    "headroom gate block present"
has "$DISPATCHER" 'LIVE_REVIEWERS='              "live reviewer-session count computed"
has "$DISPATCHER" 'HR_DECISION=\$\(gate_headroom_decision' "decision called from the live sweep"

echo "── 15. AC4 drift-guard: the log line uses the mandated phrasing ──"
has "$DISPATCHER" "gate em .* runs"             "log says 'gate em N runs'"
has "$DISPATCHER" 'cota='                       "log includes the quota (cota) field"
has "$DISPATCHER" 'Headroom DEFER'              "defer path logs a DEFER line"
has "$DISPATCHER" 'Headroom OK'                 "admit path logs an OK line"

echo "── 16. ORDERING guard: the headroom gate runs BEFORE the atomic claim ──"
# On defer we must exit 0 WITHOUT mutating any marker — so the Step 0b-1 block
# must appear strictly before the first 'label remove … gate-status:queued'.
HG_LINE=$(grep -n 'Step 0b-1' "$DISPATCHER" | head -1 | cut -d: -f1)
CLAIM_LINE=$(grep -n 'label remove "\$MARKER_ID" "gate-status:queued"' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$HG_LINE" ] && [ -n "$CLAIM_LINE" ] && [ "$HG_LINE" -lt "$CLAIM_LINE" ]; then
  ok "headroom gate (L$HG_LINE) precedes the atomic claim (L$CLAIM_LINE)"
else
  bad "ordering wrong: headroom=L${HG_LINE:-?} claim=L${CLAIM_LINE:-?} (defer could strand a marker)"
fi

echo "── 17. drift-guard: defer path exits 0 (leaves the marker queued) ──"
# The DEFER branch must `exit 0` (clean, no claim) so the FIFO marker is retried.
if awk '/Headroom DEFER/{f=1} f&&/exit 0/{print "found"; exit}' "$DISPATCHER" | grep -q found; then
  ok "DEFER branch exits 0 without claiming"
else
  bad "DEFER branch does not exit 0 after the log (would fall through into the claim)"
fi

echo ""
echo "──────────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  SELFTEST FAILED"
  exit 1
fi
echo "  SELFTEST OK"
exit 0
