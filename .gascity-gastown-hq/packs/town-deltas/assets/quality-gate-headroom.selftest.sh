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
#
# ga-92azu additions (the reservation-vs-consumption bug + Mayor's resource-
# brake amendment on the same bead):
#   AC5 (bead)   the admission unit (GATE_REVIEWERS_PER_RUN) reserves what a
#                CODE run ACTUALLY consumes (GATE_CODE_REVIEWERS, deployed=1),
#                not a stale worst-case of 3 — so ceiling=6/perrun=1 admits
#                THREE concurrent runs where the old perrun=3 admitted only two.
#   AC6 (bead)   if a tier ever needs 3 reviewers again, the reservation still
#                reserves 3 — the fix ties two constants together, it does not
#                hardcode 1.
#   AC7 (Mayor)  admission also respects a MACHINE resource floor (free swap):
#                logical ceiling 6 + Dolt calm but swap below the floor → still
#                opens NO new run, and logs a reason distinct from every other
#                defer path ('swap-low', never confusable with "queue empty").
#   AC8 (Mayor)  with swap healthy AND Dolt calm, admission scales to the full
#                ceiling exactly as before — the resource brake is a floor, not
#                a permanent throttle.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
TMPDIR_309="$(mktemp -d 2>/dev/null || echo /tmp/ga309v3-$$)"
trap 'rm -rf "$TMPDIR_309" 2>/dev/null || true' EXIT

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
type gate_swap_free_mb      >/dev/null 2>&1 || { echo "FATAL: gate_swap_free_mb not defined"; exit 1; }

# Quiet any logging from sourced helpers (none call it today, but be safe).
log()  { :; }
warn() { :; }
err()  { :; }

# Fixed thresholds for the matrix (the dispatcher's defaults).
#   gate_headroom_decision <cpu> <lat> <qlim> <inflight> \
#     <cpu_hot=180> <cpu_warm=100> <lat_hot=2500> <maxr=6> <perrun=3> <failopen> \
#     [<swap_free_mb> <swap_floor_mb>]
# swap args default to "" (no signal → never blocks) so every existing call
# below keeps exercising ONLY the Dolt/quota matrix, unchanged.
HD() { gate_headroom_decision "$1" "$2" "$3" "$4" 180 100 2500 6 3 "${5:-1}" "${6:-}" "${7:-}"; }

# HDSW <cpu> <lat> <qlim> <inflight> <swap_free_mb> <swap_floor_mb> — same fixed
# Dolt/quota thresholds as HD(), fail-open forced on, but exercises the ga-92azu
# resource brake explicitly instead of leaving swap args empty.
HDSW() { gate_headroom_decision "$1" "$2" "$3" "$4" 180 100 2500 6 3 1 "$5" "$6"; }

# _derived_perrun_for <GATE_CODE_REVIEWERS, "" = unset> [<GATE_REVIEWERS_PER_RUN
# override, "" = unset>] → what GATE_REVIEWERS_PER_RUN resolves to when the
# dispatcher is sourced FRESH with that env. Runs in an isolated subprocess —
# the copy already sourced at the top of this file has its constants fixed from
# ITS OWN env and must not be re-sourced in-process with different values.
_derived_perrun_for() {
  env GATE_DISPATCHER_LIB_ONLY=1 GATE_CODE_REVIEWERS="${1:-}" GATE_REVIEWERS_PER_RUN="${2:-}" \
    bash -c 'source "$0" >/dev/null 2>&1; echo "$GATE_REVIEWERS_PER_RUN"' "$DISPATCHER"
}

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

echo "── 26. ga-92azu AC5/AC6: GATE_REVIEWERS_PER_RUN derives from GATE_CODE_REVIEWERS ──"
# The bug: the deployed plist sets GATE_CODE_REVIEWERS=1 (995 logged CODE runs
# all used required_reviewers=1, zero used 3) but GATE_REVIEWERS_PER_RUN stayed
# hardcoded at 3 — the admission unit no longer matched what a run actually
# consumes. The fix ties the two together instead of hardcoding a fresh number,
# per the bead's own warning: "não troque a constante por 1 fixo sem amarrar ao
# tier" — so if a tier ever needs 3 again, bumping GATE_CODE_REVIEWERS alone
# must be enough.
eq "unset GATE_CODE_REVIEWERS → bare default (2), perrun follows"     "$(_derived_perrun_for '')"  "2"
eq "REAL deployed value (1) → perrun follows to 1 (was stuck at 3)"   "$(_derived_perrun_for 1)"   "1"
eq "AC6 control: tier reverts to 3 → perrun follows to 3, not stuck"  "$(_derived_perrun_for 3)"   "3"
eq "explicit GATE_REVIEWERS_PER_RUN override still wins over the derived default" \
  "$(_derived_perrun_for 1 5)" "5"
eq "degenerate GATE_CODE_REVIEWERS=0 → floored to 1 (never 0 — 0 would disable the reservation entirely)" \
  "$(_derived_perrun_for 0)" "1"

echo "── 27. ga-92azu AC5 FIXTURE (bead's own acceptance criterion 1, verbatim): ceiling=6, Dolt calm, REAL perrun=1 → THREE queued CODE runs are ALL admitted (old perrun=3 admitted only two — see § 1's 'calm + 2 runs (6) → defer' with perrun=3) ──"
eq "run 1 (idle)"                    "$(gate_headroom_decision 50 120 0 0 180 100 2500 6 1 1)" "admit 6 dolt-calm"
eq "run 2 (1 already live)"          "$(gate_headroom_decision 50 120 0 1 180 100 2500 6 1 1)" "admit 6 dolt-calm"
eq "run 3 — THE fixture: old code deferred here" "$(gate_headroom_decision 50 120 0 2 180 100 2500 6 1 1)" "admit 6 dolt-calm"
eq "scales all the way to the full ceiling (run 6, 5 live)" "$(gate_headroom_decision 50 120 0 5 180 100 2500 6 1 1)" "admit 6 dolt-calm"
eq "7th would exceed the ceiling → defer (cap still respected)" "$(gate_headroom_decision 50 120 0 6 180 100 2500 6 1 1)" "defer 6 dolt-calm-cap-reached"

echo "── 28. ga-92azu AC7 (Mayor's amendment, bead's acceptance criterion 5, verbatim): logical ceiling 6 + Dolt calm + swap BELOW floor → NO new run, reason is NOT confusable with an empty queue ──"
eq "calm Dolt, idle, swap critically low → defer (independent of Dolt state)" \
  "$(HDSW 50 120 0 0 800 1024)" "defer 0 swap-low"
eq "calm Dolt, runs already live, swap low → still defer (never revokes in-flight, never admits new)" \
  "$(HDSW 50 120 0 3 800 1024)" "defer 0 swap-low"
eq "swap-low overrides even the dolt-hot-floor idle carve-out (§ 2b does not apply — different mechanism)" \
  "$(gate_headroom_decision 220 120 0 0 180 100 2500 6 3 1 800 1024)" "defer 0 swap-low"
eq "reason string is 'swap-low' — distinct from 'no queued markers' (a totally separate early-exit path) and from every other defer reason" \
  "$(HDSW 50 120 0 0 800 1024 | cut -d' ' -f3)" "swap-low"

echo "── 29. ga-92azu AC8 (Mayor's amendment, bead's acceptance criterion 6, verbatim): swap HEALTHY + Dolt calm → scales to the full ceiling exactly as before (the brake is a floor, not a permanent throttle) ──"
eq "ample free swap + calm Dolt, idle → admits at the full ceiling"      "$(HDSW 50 120 0 0 4096 1024)" "admit 6 dolt-calm"
# HDSW fixes perrun=3 (matching HD's reference value) — inflight=3 is the last
# slot that still fits (3+3<=6); this proves the ceiling is reached, not
# artificially capped short of it by the swap check being always-on.
eq "ample free swap + calm Dolt, 3 live (last run that still fits) → admits"   "$(HDSW 50 120 0 3 4096 1024)" "admit 6 dolt-calm"

echo "── 30. ga-92azu: swap-floor boundary is strict (< not ≤) — exactly-at-floor is safe, matching § 5's cpu boundary convention ──"
eq "swap == floor exactly → NOT low"      "$(HDSW 50 120 0 0 1024 1024)" "admit 6 dolt-calm"
eq "swap == floor-1 → low"                "$(HDSW 50 120 0 0 1023 1024)" "defer 0 swap-low"

echo "── 31. ga-92azu: swap check is fail-OPEN — a missing/partial reading never blocks (same contract as every other probe here) ──"
eq "no swap args at all (HD default) → unaffected, normal calm admit" "$(HD 50 120 0 0)" "admit 6 dolt-calm"
eq "swap_free present but swap_floor missing → no check fires (both required)" \
  "$(gate_headroom_decision 50 120 0 0 180 100 2500 6 3 1 800 '')" "admit 6 dolt-calm"
eq "swap_floor present but swap_free missing → no check fires (both required)" \
  "$(gate_headroom_decision 50 120 0 0 180 100 2500 6 3 1 '' 1024)" "admit 6 dolt-calm"
eq "non-numeric swap_free → treated as no-signal, never blocks" \
  "$(gate_headroom_decision 50 120 0 0 180 100 2500 6 3 1 NaN 1024)" "admit 6 dolt-calm"

echo "── 32. gate_swap_free_mb — override seam + live sysctl probe shape ──"
eq "override seam returns the forced value" "$(GATE_SWAP_FREE_OVERRIDE_MB=777 gate_swap_free_mb)" "777"
# No override: read the REAL live sysctl. Don't assert a specific number (it
# changes every run) — assert it is a plain non-negative integer, proving the
# parser actually extracts something usable from `sysctl vm.swapusage` rather
# than silently degrading to empty on every real machine.
LIVE_SWAP=$(gate_swap_free_mb)
case "$LIVE_SWAP" in
  ''|*[!0-9]*) bad "live gate_swap_free_mb did not return a plain integer (got [$LIVE_SWAP])" ;;
  *)           ok "live gate_swap_free_mb returned a plain integer ($LIVE_SWAP MB)" ;;
esac

echo "── 33. ga-92azu drift-guards: live wiring ──"
has "$DISPATCHER" 'gate_swap_free_mb\(\)'                    "swap-free probe is defined"
has "$DISPATCHER" 'GATE_SWAP_FREE_FLOOR_MB'                  "swap-free floor threshold configured"
has "$DISPATCHER" 'GATE_SWAP_FREE_OVERRIDE_MB'                "swap override seam wired"
has "$DISPATCHER" 'GATE_CODE_REVIEWERS'                       "code-tier reviewer knob configured (perrun derivation source)"
has "$DISPATCHER" 'GATE_REVIEWERS_PER_RUN:-\$GATE_CODE_REVIEWERS' "perrun default derives from the code-reviewer knob, not a bare constant"
has "$DISPATCHER" 'HR_SWAP_FREE=\$\(gate_swap_free_mb\)'      "swap probe called from the live sweep"
has "$DISPATCHER" 'swap_free='                                "log surfaces the swap_free reading (both OK and DEFER lines)"

echo "── 34. ga-92azu drift-guard: swap probe is called BEFORE the decision, and the decision consumes it ──"
SWAP_CALL_LN=$(grep -n 'HR_SWAP_FREE=\$(gate_swap_free_mb)' "$DISPATCHER" | head -1 | cut -d: -f1)
DECISION_CALL_LN=$(grep -n 'HR_DECISION=\$(gate_headroom_decision' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$SWAP_CALL_LN" ] && [ -n "$DECISION_CALL_LN" ] && [ "$SWAP_CALL_LN" -lt "$DECISION_CALL_LN" ]; then
  ok "swap probe (L$SWAP_CALL_LN) precedes the decision call (L$DECISION_CALL_LN)"
else
  bad "ordering wrong: swap probe=L${SWAP_CALL_LN:-?} decision=L${DECISION_CALL_LN:-?} (decision could consume a stale/empty swap reading)"
fi
has "$DISPATCHER" '"\${HR_SWAP_FREE:-}" "\$GATE_SWAP_FREE_FLOOR_MB"' "decision call passes the live swap reading + floor through"

# ── ga-309v3: multi-admit rounds (re-exec continuation) ───────────────────────
# The gate admitted exactly ONE marker per sweep, so with runs lasting 11-17min
# and a 4-6min cadence the concurrent-run count settled at ~1 no matter how high
# the headroom ceiling was (measured 2026-08-06: ceiling=6, observed 1). The fix
# continues the burst by RE-EXECing the dispatcher instead of looping Step
# 0b..Step 8 in-process — a fresh process image resets every global, so marker A
# can never leak its branch/sha/tier into marker B (which would merge the WRONG
# branch). These tests pin the properties that, if broken, take the gate DOWN.
echo "── ga-309v3: multi-admit burst ──"

# AC-lock (the wedge risk): a continuation round presents the INHERITED token, so
# the final round must still be able to release the lock. A token mismatch here
# would leave the lock held until GATE_LOCK_MAX_AGE (30min) with NO sweep running
# — the gate would look alive and silently process nothing.
_T309="$TMPDIR_309"
mkdir -p "$_T309" 2>/dev/null || true
(
  export GATE_LOCK_DIR="$_T309/lock.d" GATE_LOCK_HB="$_T309/lock.d/heartbeat"
  export GATE_LOCK_TOKEN="12345:inherited-token"
  mkdir -p "$GATE_LOCK_DIR" 2>/dev/null
  printf '%s\n' "$GATE_LOCK_TOKEN" > "$GATE_LOCK_HB"
  _release_gate_lock
  [ ! -d "$GATE_LOCK_DIR" ]
) && ok "ga-309v3 AC-lock: inherited token still releases the lock (no 30min wedge)" \
  || bad "ga-309v3 AC-lock: inherited token did NOT release the lock — burst would wedge the gate"

# A FOREIGN token must NOT release someone else's lock (pre-existing guarantee
# that the inheritance change must not weaken).
(
  export GATE_LOCK_DIR="$_T309/lock2.d" GATE_LOCK_HB="$_T309/lock2.d/heartbeat"
  export GATE_LOCK_TOKEN="99999:mine"
  mkdir -p "$GATE_LOCK_DIR" 2>/dev/null
  printf '%s\n' "77777:someone-else" > "$GATE_LOCK_HB"
  _release_gate_lock
  [ -d "$GATE_LOCK_DIR" ]
) && ok "ga-309v3: a foreign token still cannot release another holder's lock (unchanged)" \
  || bad "ga-309v3 REGRESSION: token-mismatch release guard weakened — a peer can free our lock"

# AC5 non-regression: default entry (no GATE_ADMIT_ROUND) must behave exactly as
# before — round 0, and a max of 1 disables the burst entirely.
has "$DISPATCHER" 'GATE_ADMIT_ROUND="\$\{GATE_ADMIT_ROUND:-0\}"' \
  "ga-309v3 AC5: unset GATE_ADMIT_ROUND defaults to 0 (normal launchd entry unchanged)"
has "$DISPATCHER" 'GATE_LOCK_TOKEN="\$\{GATE_LOCK_TOKEN:-\$\$:' \
  "ga-309v3: lock token is inheritable but falls back to the original pid:random form"
has "$DISPATCHER" 'GATE_MAX_ADMITS_PER_SWEEP="\$\{GATE_MAX_ADMITS_PER_SWEEP:-3\}"' \
  "ga-309v3 AC1: admits-per-sweep is configurable (default 3)"

# AC3 (isolation): the continuation MUST be an exec of a fresh process — that is
# the whole reason cross-marker state leakage is impossible. If someone ever
# "simplifies" this into an in-process loop, this guard fails loudly.
has "$DISPATCHER" 'exec bash "\$0"' \
  "ga-309v3 AC3: continuation is a fresh exec (globals reset by construction — no cross-marker leak)"
# Anchored to real shell loop SYNTAX at statement start — an earlier version of
# this guard matched `while|for` anywhere on the line and tripped on the
# dispatcher's own log string ("re-exec for round $GATE_ADMIT_ROUND"), i.e. it
# fired on PROSE about the mechanism rather than the mechanism. Same trap as
# ga-w3vn3, where a veto regex matched a bead that merely cited the label name.
if grep -qE '^[[:space:]]*(while|until|for)[[:space:]].*GATE_ADMIT_ROUND' "$DISPATCHER"; then
  bad "ga-309v3 AC3: an in-process LOOP over admit rounds was introduced — reintroduces the state-leak risk exec was chosen to eliminate"
else
  ok "ga-309v3 AC3: no in-process loop over admit rounds (exec-only continuation)"
fi

# AC2: the lock must be held across the whole burst. GATE_SWEEP_HAS_MORE_WORK
# has to be set BEFORE cleanup runs, or cleanup frees the lock and a concurrent
# launchd fire starts a second sweep mid-burst.
_L309_FLAG=$(grep -n 'GATE_SWEEP_HAS_MORE_WORK=1' "$DISPATCHER" | tail -1 | cut -d: -f1)
_L309_CLEAN=$(grep -n '^    cleanup_reviewer_sessions$' "$DISPATCHER" | tail -1 | cut -d: -f1)
_L309_EXEC=$(grep -n 'exec bash "\$0"' "$DISPATCHER" | tail -1 | cut -d: -f1)
if [ -n "$_L309_FLAG" ] && [ -n "$_L309_CLEAN" ] && [ -n "$_L309_EXEC" ] \
   && [ "$_L309_FLAG" -lt "$_L309_CLEAN" ] && [ "$_L309_CLEAN" -lt "$_L309_EXEC" ]; then
  ok "ga-309v3 AC2: HAS_MORE_WORK set (L$_L309_FLAG) BEFORE cleanup (L$_L309_CLEAN) BEFORE exec (L$_L309_EXEC) — lock survives the burst"
else
  bad "ga-309v3 AC2: ordering broken (flag=$_L309_FLAG cleanup=$_L309_CLEAN exec=$_L309_EXEC) — the lock can be freed mid-burst"
fi

# AC4 + bound: the burst is capped by the counter, and every round re-runs the
# real headroom probe (no duplicated policy that could drift from Step 0b-1).
has "$DISPATCHER" '\$\(\(GATE_ADMIT_ROUND \+ 1\)\)" -lt "\$GATE_MAX_ADMITS_PER_SWEEP' \
  "ga-309v3 AC1: burst is hard-bounded by GATE_MAX_ADMITS_PER_SWEEP"
has "$DISPATCHER" 'export GATE_ADMIT_ROUND=' \
  "ga-309v3: the round counter is exported so the bound actually advances across the exec"

# ── ga-309v3 BLOCKER regressions (found by adversarial review, 2026-08-06) ────
# Two blockers were caught BEFORE ship. These tests exist so they cannot return.
echo "── ga-309v3: blocker regressions ──"

# BLOCKER 1 — ownership must come from the LOCK, not from inherited env.
# export GATE_ADMIT_ROUND/GATE_LOCK_TOKEN reach every DESCENDANT, including the
# gate-reviewer sessions a round spawns. A reviewer that later runs the
# dispatcher by hand would inherit "I am round N", skip the single-instance
# guard, run a concurrent sweep and then delete the live holder's lock.
# The pid half is the discriminator: exec preserves $$, a descendant does not.
has "$DISPATCHER" '\$\{GATE_LOCK_TOKEN%%:\*\}" = "\$\$"' \
  "ga-309v3 BLOCKER-1: skip-acquire requires the token's pid half to equal \$\$ (a descendant cannot impersonate a continuation)"
has "$DISPATCHER" '\[ -d "\$GATE_LOCK_DIR" \]' \
  "ga-309v3 BLOCKER-1: skip-acquire requires the lock dir to actually exist (no 'continuing under the lock' while unlocked)"
has "$DISPATCHER" '_gate_hb_tok" = "\$GATE_LOCK_TOKEN"' \
  "ga-309v3 BLOCKER-1: skip-acquire compares the ON-DISK heartbeat token, not just the env var"

# Behavioural: the 4-way guard must FAIL CLOSED for a descendant — same token,
# same lock dir, but a different pid. This is the exact impersonation scenario.
_t309b="$TMPDIR_309/b1"; mkdir -p "$_t309b" 2>/dev/null
(
  GATE_LOCK_DIR="$_t309b/lock.d"; GATE_LOCK_HB="$GATE_LOCK_DIR/heartbeat"
  mkdir -p "$GATE_LOCK_DIR" 2>/dev/null
  GATE_LOCK_TOKEN="999999:tok"                 # pid half is NOT this shell's $$
  printf '%s\n' "$GATE_LOCK_TOKEN" > "$GATE_LOCK_HB"
  GATE_ADMIT_ROUND=1
  _hb=$(head -n1 "$GATE_LOCK_HB" 2>/dev/null || true)
  if [ "$GATE_ADMIT_ROUND" -gt 0 ] && [ -d "$GATE_LOCK_DIR" ] \
     && [ "$_hb" = "$GATE_LOCK_TOKEN" ] && [ "${GATE_LOCK_TOKEN%%:*}" = "$$" ]; then
    exit 1   # took the skip-acquire path => impersonation succeeded => BAD
  fi
  exit 0
) && ok "ga-309v3 BLOCKER-1 (behavioural): a descendant with the inherited token+round FAILS the guard and falls through to a real acquire" \
  || bad "ga-309v3 BLOCKER-1 (behavioural): a foreign-pid process was accepted as a continuation round — concurrent-sweep risk is back"

# And the genuine continuation (token pid == our own $$) must still be accepted,
# or the burst deadlocks against its own lock on every round.
(
  GATE_LOCK_DIR="$_t309b/lock2.d"; GATE_LOCK_HB="$GATE_LOCK_DIR/heartbeat"
  mkdir -p "$GATE_LOCK_DIR" 2>/dev/null
  GATE_LOCK_TOKEN="$$:realtoken"
  printf '%s\n' "$GATE_LOCK_TOKEN" > "$GATE_LOCK_HB"
  GATE_ADMIT_ROUND=1
  _hb=$(head -n1 "$GATE_LOCK_HB" 2>/dev/null || true)
  [ "$GATE_ADMIT_ROUND" -gt 0 ] && [ -d "$GATE_LOCK_DIR" ] \
    && [ "$_hb" = "$GATE_LOCK_TOKEN" ] && [ "${GATE_LOCK_TOKEN%%:*}" = "$$" ]
) && ok "ga-309v3 BLOCKER-1: a GENUINE continuation (exec preserves \$\$) is still accepted — burst does not deadlock on itself" \
  || bad "ga-309v3 BLOCKER-1: genuine continuation REJECTED — every burst would re-acquire and yield, silently disabling multi-admit"

# BLOCKER 2 — the burst must add back its own spawns before the headroom probe.
# Step 0a-2's drained-exclusion has no booting guard, so a round's own reviewers
# (still inside the ~210s deferred-start window) read as drained and LIVE_REVIEWERS
# collapses to 0 — leaving the burst with NO brake at all.
has "$DISPATCHER" 'GATE_ADMIT_ROUND \* GATE_REVIEWERS_PER_RUN' \
  "ga-309v3 BLOCKER-2: prior rounds' spawns are added back into LIVE_REVIEWERS"
_L309_LR=$(grep -n '^LIVE_REVIEWERS=\$(headroom_live_reviewers' "$DISPATCHER" | tail -1 | cut -d: -f1)
_L309_ADD=$(grep -n 'GATE_ADMIT_ROUND \* GATE_REVIEWERS_PER_RUN' "$DISPATCHER" | tail -1 | cut -d: -f1)
_L309_USE=$(grep -n '"\$HR_QLIM" "\$LIVE_REVIEWERS"' "$DISPATCHER" | tail -1 | cut -d: -f1)
if [ -n "$_L309_LR" ] && [ -n "$_L309_ADD" ] && [ -n "$_L309_USE" ] \
   && [ "$_L309_LR" -lt "$_L309_ADD" ] && [ "$_L309_ADD" -lt "$_L309_USE" ]; then
  ok "ga-309v3 BLOCKER-2: correction applied AFTER the count (L$_L309_LR->L$_L309_ADD) and BEFORE the headroom decision (L$_L309_USE)"
else
  bad "ga-309v3 BLOCKER-2: ordering broken (count=$_L309_LR add=$_L309_ADD decide=$_L309_USE) — the burst would run unbraked"
fi

# Bound hygiene (adversarial MINORs): upper clamp + octal safety.
has "$DISPATCHER" 'GATE_MAX_ADMITS_PER_SWEEP" -le 6' \
  "ga-309v3: admits-per-sweep has an UPPER clamp (a typo cannot spawn past the reviewer cap)"
# (zero-strip correctness is covered BEHAVIOURALLY below by _real_knob
#  GATE_MAX_ADMITS_PER_SWEEP=0/00/000 -> 1, which drives the real code.)

# ── ga-309v3 round 2: drive the REAL dispatcher code, not a re-implementation ──
# The first cut of these tests re-implemented the ownership guard inline, so they
# would have kept passing while the real one drifted. These source the dispatcher
# in lib-only mode with a hostile env and read back what IT actually computed.
echo "── ga-309v3: real-code behaviour (round-2 review) ──"

# _real_token <inherited GATE_LOCK_TOKEN> → the token the dispatcher settles on.
_real_token() {
  env GATE_DISPATCHER_LIB_ONLY=1 GATE_LOCK_TOKEN="$1" \
    bash -c 'source "$0" >/dev/null 2>&1; echo "$GATE_LOCK_TOKEN"' "$DISPATCHER"
}
# _real_knob <VAR> <value> → what the dispatcher clamps that knob to.
_real_knob() {
  # The var NAME is interpolated into the inner script at definition time —
  # inside `bash -c`, $1 is the subshell's own positional, not this function's
  # argument, so an eval on "$1" there reads the wrong thing (and trips set -u).
  env GATE_DISPATCHER_LIB_ONLY=1 "$1=$2" \
    bash -c "source \"\$0\" >/dev/null 2>&1; printf '%s' \"\$$1\"" "$DISPATCHER" 2>/dev/null
}

# BLOCKER-3 (round 2): a token inherited from a DEAD parent must be rejected and
# re-minted. If kept, the acquiring process writes a heartbeat advertising a dead
# pid; the next sweep's holder-dead check then reclaims the lock FROM THE LIVE
# HOLDER → two concurrent sweeps → concurrent merges.
_tok_foreign=$(_real_token "999999:stale-from-dead-parent")
case "$_tok_foreign" in
  999999:*) bad "ga-309v3 BLOCKER-3: a foreign-pid token was KEPT — heartbeat would advertise a dead holder and the lock gets reclaimed from a live sweep (got: $_tok_foreign)" ;;
  *:*)      ok  "ga-309v3 BLOCKER-3: foreign-pid token re-minted to our own pid (got pid half: ${_tok_foreign%%:*})" ;;
  *)        bad "ga-309v3 BLOCKER-3: token malformed after re-mint (got: $_tok_foreign)" ;;
esac
_tok_unset=$(_real_token "")
case "$_tok_unset" in
  *:*) ok "ga-309v3: with no inherited token the dispatcher still mints the normal pid:random form" ;;
  *)   bad "ga-309v3: unset-token path produced a malformed token (got: $_tok_unset)" ;;
esac

# The kill switch must actually kill. An operator typing the universal "off"
# value during an incident must NOT get the maximum burst — an inverted kill
# switch is worse than none. (A bare `sed 's/^0*//'` mapped "0" -> "" -> default 3.)
for _z in 0 00 000; do
  _got=$(_real_knob GATE_MAX_ADMITS_PER_SWEEP "$_z")
  if [ "$_got" = "1" ]; then
    ok "ga-309v3: GATE_MAX_ADMITS_PER_SWEEP=$_z disables the burst (clamped to 1, not the default 3)"
  else
    bad "ga-309v3: KILL SWITCH INVERTED — GATE_MAX_ADMITS_PER_SWEEP=$_z resolved to $_got (expected 1)"
  fi
done
# Octal-looking values must not blow up $(( )) — an arithmetic error at the
# re-exec site fires AFTER `trap - EXIT` and leaks the lock.
for _o in 08 09 010; do
  _got=$(_real_knob GATE_MAX_ADMITS_PER_SWEEP "$_o")
  case "$_got" in
    ''|*[!0-9]*) bad "ga-309v3: octal-ish '$_o' produced a non-numeric knob ($_got) — \$(( )) would abort after trap removal" ;;
    *)           ok  "ga-309v3: octal-ish '$_o' sanitized to a plain integer ($_got)" ;;
  esac
done
_got=$(_real_knob GATE_MAX_ADMITS_PER_SWEEP 30)
[ "$_got" = "6" ] \
  && ok "ga-309v3: an over-large admits knob (30) is clamped to the reviewer cap (6)" \
  || bad "ga-309v3: upper clamp not applied — 30 resolved to $_got (would spawn past max_active_sessions, ga-zl277)"

# SERIOUS (round 2): the yield branch must install a release trap, or an owner
# that fails the guard exits holding its own lock.
_L309_ELSE=$(grep -n '^  else$' "$DISPATCHER" | awk -F: -v a="$(grep -n 'elif _acquire_gate_lock; then' "$DISPATCHER" | head -1 | cut -d: -f1)" '$1>a{print $1; exit}')
if [ -n "$_L309_ELSE" ] && sed -n "$((_L309_ELSE)),$((_L309_ELSE+22))p" "$DISPATCHER" | grep -q "trap '_release_gate_lock' EXIT"; then
  ok "ga-309v3: the yield branch installs a release trap (an owner that fails the guard cannot leak its own lock)"
else
  bad "ga-309v3: yield branch has NO release trap — a guard-fail while owning the lock wedges the gate (30min under pid reuse)"
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
