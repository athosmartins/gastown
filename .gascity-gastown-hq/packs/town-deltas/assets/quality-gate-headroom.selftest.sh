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

echo "── 2. AC1+AC3: Dolt HOT adds no run to a plane the gate is ALREADY loading ──"
# ga-q4gqq: the hot rule is "don't ADD to a hot plane", not "never start". It
# only bites while the gate HAS runs in flight — those are load the gate owns
# and can shed by waiting. With in-flight == 0 the gate owns NO load, so
# deferring sheds nothing and the ceiling=0 becomes a self-deadlock (see § 2b).
eq "hot + 1 run          → defer"              "$(HD 220 120 0 3)" "defer 0 dolt-hot"
eq "hot + 2 runs         → defer"              "$(HD 220 120 0 6)" "defer 0 dolt-hot"

echo "── 2b. ga-q4gqq: HOT + in-flight==0 → floor of ONE run (stall → slow) ──"
# Measured 2026-07-30: 37 sweeps deferred at ceiling=0 with in-flight=0 while an
# UNRELATED load source (the per-session `gc nudge` 2s poll, ~47% of Dolt load)
# held ambient cpu over the hot threshold. The gate starved on load it does not
# produce and cannot reduce. A floor of exactly one run converts an unbounded
# stall into bounded slowness, and never exceeds ONE run while hot (§ 2 above).
eq "hot (cpu>180) + idle → admit ONE run"      "$(HD 220 120 0 0)" "admit 3 dolt-hot-floor"
eq "latency hot (>2500) + idle → admit ONE"    "$(HD 50 9000 0 0)" "admit 3 dolt-hot-floor"
eq "very hot + idle → still exactly ONE"       "$(HD 900 120 0 0)" "admit 3 dolt-hot-floor"

echo "── 3. AC3: Dolt WARM allows exactly ONE run (serializes; no herd) ──"
eq "warm (100<cpu≤180) idle → admit one run"   "$(HD 140 120 0 0)" "admit 3 dolt-warm"
eq "warm + 1 run already     → defer 2nd"      "$(HD 140 120 0 3)" "defer 3 dolt-warm-cap-reached"

echo "── 4. quota limit is an independent hard-stop (even on a calm Dolt) ──"
eq "calm Dolt but quota LIMITED → defer"       "$(HD 50 120 1 0)" "defer 0 quota-limited"
# ga-q4gqq: the in-flight==0 floor must NOT leak into the quota stop. Dolt-hot
# is a soft signal the gate can trade against; an exhausted 5h window is a HARD
# limit — admitting there burns the run into a quota-stop and re-queues it, so
# "idle" is never a reason to start. These two idle cases must diverge.
eq "quota LIMITED + idle → STILL defer"        "$(HD 50 120 1 0)" "defer 0 quota-limited"
eq "quota LIMITED + hot + idle → defer"        "$(HD 220 120 1 0)" "defer 0 quota-limited"

echo "── 5. boundaries are strict (> not ≥): exactly-at threshold is the cooler tier ──"
eq "cpu == warm(100) → calm, not warm"         "$(HD 100 120 0 0)" "admit 6 dolt-calm"
eq "cpu == hot(180)  → warm, not hot"          "$(HD 180 120 0 0)" "admit 3 dolt-warm"
eq "lat == hot(2500) → not hot"                "$(HD 50 2500 0 0)" "admit 6 dolt-calm"

echo "── 6. no-signal fail-OPEN (default) vs fail-CLOSED (opt-in) ──"
# A wedged probe must NEVER deadlock the critical-path gate → default proceeds.
eq "no cpu/lat + failopen=1 → admit (max)"     "$(HD '' '' 0 0 1)" "admit 6 no-signal-failopen"
eq "no cpu/lat + failopen=0 → defer"           "$(HD '' '' 0 0 0)" "defer 0 no-signal-failclosed"
# A positively-measured hot reading still caps at ONE run under fail-open
# (ga-q4gqq floor: idle → one run; with a run already in flight → defer).
eq "failopen + measured hot + idle → ONE run"  "$(HD 220 '' 0 0 1)" "admit 3 dolt-hot-floor"
eq "failopen + measured hot + 1 run → defer"   "$(HD 220 '' 0 3 1)" "defer 0 dolt-hot"

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

echo "── 18. ga-x3nmz: quota-stop re-queue (a quota-exhausted stall is NOT a FAIL) ──"
type gate_quota_stop_verdict >/dev/null 2>&1 || { echo "FATAL: gate_quota_stop_verdict not defined"; exit 1; }
type quota_reset_eta         >/dev/null 2>&1 || { echo "FATAL: quota_reset_eta not defined"; exit 1; }
# Pure decision: a no-verdict stall is a quota-stop (→ requeue) iff quota limited.
eq "quota LIMITED (1) → requeue"               "$(gate_quota_stop_verdict 1)"  "requeue"
eq "quota ok (0)      → proceed (genuine fail)" "$(gate_quota_stop_verdict 0)"  "proceed"
eq "junk/empty arg    → proceed (fail-safe)"   "$(gate_quota_stop_verdict '')" "proceed"
# Reset-ETA reader: override seam short-circuits the live checker.
eq "ETA override seam returns the forced text" "$(GATE_QUOTA_ETA_OVERRIDE='resets 5pm (in 9min)' quota_reset_eta)" "resets 5pm (in 9min)"
eq "ETA absent checker → empty (fail-soft)"    "$(GC_CITY=/nonexistent-x3nmz-test quota_reset_eta)" ""

echo "── 19. ga-x3nmz drift-guard: the re-queue path is wired into the live poll ──"
has "$DISPATCHER" 'gate_quota_stop_verdict\(\)'                 "pure quota-stop decision is defined"
has "$DISPATCHER" 'quota_reset_eta\(\)'                         "reset-ETA reader is defined"
has "$DISPATCHER" 'QUOTA_REQUEUE=0'                             "QUOTA_REQUEUE state initialized"
# ga-eqjo: the blocking poll loop this decision used to live inside (checking
# "$POLL_QUOTA_LIMITED" once per 30s poll iteration) was replaced by a
# non-blocking Step 8 + a later sweep's Phase C, which re-checks a run's own
# persisted timeout instead of an in-process poll. The quota-stop decision
# moved with it: Phase C now calls it as "$PC_QLIM" at TIMEOUT-detection time
# (there is no other point at which a quota-stop is meaningful — Step 8's
# fast path only fires once verdicts are ALREADY complete).
has "$DISPATCHER" 'gate_quota_stop_verdict "\$PC_QLIM"' "quota decision called from Phase C's timeout check (ga-eqjo)"
has "$DISPATCHER" 'verdict:REQUEUED'                            "pending verdicts parked as REQUEUED (not TIMEOUT)"
has "$DISPATCHER" 'QUOTA-STOP re-queue'                         "marker re-queue comment present"
has "$DISPATCHER" 'Gate pausado: cota 5h'                       "AC4 quota-pause notify present"

echo "── 20. ga-x3nmz: a quota-stop re-queues (queued) instead of FAILing the marker ──"
# The handler must set gate-status:queued (re-runnable), never gate-status:failed.
if awk '/QUOTA_REQUEUE:-0/{f=1} f&&/label add    "\$MARKER_ID" "gate-status:queued"/{print "ok"; exit}' "$DISPATCHER" | grep -q ok; then
  ok "re-queue handler restores gate-status:queued"
else
  bad "re-queue handler does not set gate-status:queued"
fi
# ga-eqjo: this handler now lives inside gate_finalize_run() (called from
# TWO places — the same-sweep fast path AND Phase C — not just the tail of a
# single blocking invocation), so it must `return` to its caller rather than
# `exit` the whole process: an `exit 0` here would abandon any OTHER run bead
# Phase C still has queued to check this same sweep, and skip Step 0a onward
# for the same-sweep fast-path caller. `return 0` is the function-context
# equivalent of the old top-level `exit 0` — it still skips both the PASS and
# FAIL branches below.
if awk '/QUOTA_REQUEUE:-0/{f=1} f&&/return 0/{print "ok"; exit} f&&/OVERALL_VERDICT" = "PASS"/{exit}' "$DISPATCHER" | grep -q ok; then
  ok "re-queue handler returns 0 (skips both PASS and FAIL paths, ga-eqjo function context)"
else
  bad "re-queue handler does not return 0 before the verdict branches"
fi

echo "── 21. ORDERING guard: the re-queue handler precedes the merge/FAIL branches ──"
RQ_LINE=$(grep -n 'QUOTA_REQUEUE:-0' "$DISPATCHER" | head -1 | cut -d: -f1)
MERGE_LINE=$(grep -n 'ALL PASS — proceeding to merge' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$RQ_LINE" ] && [ -n "$MERGE_LINE" ] && [ "$RQ_LINE" -lt "$MERGE_LINE" ]; then
  ok "re-queue handler (L$RQ_LINE) precedes the merge branch (L$MERGE_LINE)"
else
  bad "ordering wrong: requeue=L${RQ_LINE:-?} merge=L${MERGE_LINE:-?} (quota-stop could fall into PASS/FAIL)"
fi

echo "── 22. ga-bgvc0: ambient-vs-post-janitor CPU selection (self-deadlock fix) ──"
# The headroom gate self-deadlocked: it sampled Dolt %cpu AFTER ~30s of its own
# Step 0a/0a-2/0a-3 janitors inflated the reading (ambient ~155% WARM, but
# post-janitor ~200% HOT) → permanent DEFER. The fix samples ambient %cpu at
# sweep start and prefers it. gate_effective_headroom_cpu(ambient, now) is the
# pure selector.
type gate_effective_headroom_cpu >/dev/null 2>&1 \
  && ok "gate_effective_headroom_cpu is defined" \
  || bad "gate_effective_headroom_cpu not defined"
eq "ambient present → prefer ambient"            "$(gate_effective_headroom_cpu 155 200)" "155"
eq "ambient absent  → fall back to post-janitor" "$(gate_effective_headroom_cpu '' 200)"  "200"
eq "both absent      → empty (→ fail-open)"       "$(gate_effective_headroom_cpu '' '')"   ""
eq "now absent       → ambient still used"        "$(gate_effective_headroom_cpu 90 '')"  "90"
# End-to-end VALUE proof: the SAME plane that DEFERs on the post-janitor reading
# ADMITs one run on the ambient reading — exactly the deadlock this fixes.
# ga-q4gqq: probed with a run ALREADY in flight, because that is now the regime
# where hot still DEFERs. At in-flight==0 both readings admit (the § 2b floor),
# which would make this comparison pass for the wrong reason — it must keep
# discriminating hot from warm, so it is asserted where the two verdicts differ.
eq "post-janitor reading (200) alone → DEFER"    "$(HD 200 120 0 3)" "defer 0 dolt-hot"
eq "ambient reading (155) → ADMIT (warm, 1 run)" "$(HD 155 120 0 0)" "admit 3 dolt-warm"
eq "selector picks ambient → flips DEFER→ADMIT"  "$(HD "$(gate_effective_headroom_cpu 155 200)" 120 0 3)" "defer 3 dolt-warm-cap-reached"
# A genuinely hot ambient still DEFERs while a run is in flight (the fix must
# not blind the gate)...
eq "ambient genuinely HOT (220) + 1 run → DEFER" "$(HD "$(gate_effective_headroom_cpu 220 240)" 120 0 3)" "defer 0 dolt-hot"
# ...and even when idle (floor) it is still CLASSIFIED hot — never silently
# demoted to warm/calm. The reason string is the proof the threshold still bites.
eq "ambient genuinely HOT (220) + idle → hot-floor" "$(HD "$(gate_effective_headroom_cpu 220 240)" 120 0 0)" "admit 3 dolt-hot-floor"

echo "── 23. ga-bgvc0: live wiring drift guards ──"
has "$DISPATCHER" 'gate_effective_headroom_cpu\(\)'                   "selector helper defined"
has "$DISPATCHER" 'GATE_AMBIENT_DOLT_CPU=\$\(gate_dolt_cpu'          "ambient %cpu snapshotted at sweep start"
has "$DISPATCHER" 'HR_CPU=\$\(gate_effective_headroom_cpu'           "headroom decision consumes the ambient-preferred cpu"
has "$DISPATCHER" 'post-janitor='                                    "log surfaces both ambient + post-janitor readings"
# ORDERING: the ambient snapshot MUST be captured before the first janitor (Step
# 0a), else it is just another post-janitor reading and the fix is a no-op.
AMB_LINE=$(grep -nE 'GATE_AMBIENT_DOLT_CPU=\$\(gate_dolt_cpu' "$DISPATCHER" | head -1 | cut -d: -f1)
STEP0A_LINE=$(grep -nF 'Step 0a: TTL recovery' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$AMB_LINE" ] && [ -n "$STEP0A_LINE" ] && [ "$AMB_LINE" -lt "$STEP0A_LINE" ]; then
  ok "ambient snapshot (L$AMB_LINE) precedes Step 0a janitors (L$STEP0A_LINE)"
else
  bad "ordering wrong: ambient=L${AMB_LINE:-?} step0a=L${STEP0A_LINE:-?} (ambient must precede janitors)"
fi

echo "── 24. ga-cru9: BEHAVIORAL proof — a Dolt-hot DEFER can never reach run creation ──"
# ga-cru9 reported: "the gate-RUN is already created (gate-status:running) before
# the headroom check defers, so ceiling=0 orphans it for 15min until the reaper
# cleans up." Verified against the live source (and 868/868 historical log lines,
# zero exceptions): this mechanism does NOT exist. Step 0b-1's DEFER branch (log
# "Headroom DEFER..." + exit 0) is bare top-level script — not inside a function
# or subshell — so its `exit 0` unconditionally terminates the whole sweep.
# Assertions 16/17 already proved (a) Step 0b-1 precedes the atomic claim and
# (b) SOME `exit 0` follows the DEFER log later in the file. This assertion
# closes the gap ga-cru9's acceptance criteria actually asked for ("assert no
# type:quality-gate-run is created that sweep"): capture the EXACT line of that
# exit and the EXACT line of the run-bead creation (Step 6), and prove the
# former strictly precedes the latter — a DEFER sweep is textually incapable of
# ever executing the `bd create -l type:quality-gate-run` call, mirroring how
# assertion 3 in gate-dup-run-guard.selftest.sh proves its own guard-before-
# create ordering.
#
# ANCHOR (gate review on gate_run=ga-wisp-vek7zn caught a real hole here): a
# first version scanned open-ended — `/Headroom DEFER/{f=1} f&&/exit 0/{print
# NR; exit}` — which, once triggered, latches onto the FIRST `exit 0` ANYWHERE
# later in the file, not necessarily the one in the DEFER if-block. Mutation-
# tested: replacing L1534's `exit 0` with `true` (reproducing the exact bug
# ga-cru9 describes — DEFER logs but falls through) made that scan skip past
# the mutation and match an unrelated `exit 0` at L1630 (the Step 1 atomic-
# claim race-check, nothing to do with headroom) — DEFER_EXIT_LN=1630 still
# < RUN_CREATE_LN, so the assertion reported PASS on a regressed dispatcher.
# Fixed by bounding the scan to the DEFER if-block itself: walk forward from
# the log line and stop at the block's own closing `fi`; only report a line
# if `exit 0` is found strictly before that boundary. Re-ran the same
# mutation against the fixed scan: DEFER_EXIT_LN comes back empty (the block
# closes via `fi` before any `exit 0` is seen) and the assertion correctly
# fails.
DEFER_EXIT_LN=$(awk '
  in_block {
    if ($0 ~ /^[[:space:]]*exit 0[[:space:]]*$/) { print NR; exit }
    if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/)      { exit }
  }
  /Headroom DEFER/ { in_block=1 }
' "$DISPATCHER")
RUN_CREATE_LN=$(grep -n 'GATE_RUN_ID=\$(bd -C "\$GC_CITY" create' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$DEFER_EXIT_LN" ] && [ -n "$RUN_CREATE_LN" ] && [ "$DEFER_EXIT_LN" -lt "$RUN_CREATE_LN" ]; then
  ok "DEFER's exit (L$DEFER_EXIT_LN) strictly precedes gate-run creation (L$RUN_CREATE_LN) — no run bead can be created that sweep"
else
  bad "cannot prove DEFER never reaches run creation: exit=L${DEFER_EXIT_LN:-?} create=L${RUN_CREATE_LN:-?}"
fi

echo "── 25. ga-cru9: incident replay — production threshold (cpu_hot=250) still DEFERs on the exact reported reading ──"
# The 2026-07-14 05:46 incident (quality-gate-dispatcher.log) measured cpu=275%
# lat=48ms against the PRODUCTION plist override GATE_DOLT_CPU_HOT=250 (the
# script's own coded default is 180 — com.gascity.quality-gate-dispatcher.plist
# raises it). Prove the pure decision defers at the real deployed threshold, not
# just the test harness's hardcoded-180 HD() helper used above.
# ga-q4gqq: the claim under test is "the DEPLOYED threshold (250) is honored,
# not the harness's 180" — i.e. cpu=275 must classify as HOT. That is asserted
# two ways so the § 2b floor cannot mask a threshold regression:
#   (a) with a run in flight → the hot rule still DEFERs outright;
#   (b) idle → admits at most ONE run and is still REASONED as hot-floor
#       (a broken threshold would surface here as dolt-warm/dolt-calm).
eq "production threshold (250): cpu=275 + 1 run → defer" \
  "$(gate_headroom_decision 275 48 0 3 250 130 2500 6 3 1)" "defer 0 dolt-hot"
eq "production threshold (250): cpu=275 + idle → hot-floor (ONE run)" \
  "$(gate_headroom_decision 275 48 0 0 250 130 2500 6 3 1)" "admit 3 dolt-hot-floor"
# Control: just BELOW the deployed hot threshold is warm, not hot — proves the
# 250 boundary is the thing being read (and that 'hot-floor' is not a catch-all).
eq "production threshold (250): cpu=249 + idle → warm" \
  "$(gate_headroom_decision 249 48 0 0 250 130 2500 6 3 1)" "admit 3 dolt-warm"

echo ""
echo "──────────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  SELFTEST FAILED"
  exit 1
fi
echo "  SELFTEST OK"
exit 0
