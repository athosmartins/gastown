#!/usr/bin/env bash
# Selftest for pipeline-throughput-heartbeat.py — ga-z0xx1 regression only.
#
# BUG: gate_merge_stall()'s in-flight guard (_fresh_review_in_progress) suppressed the
# "zero merges under demand" alarm only while a review's elapsed stayed under the FIXED
# REVIEW_FRESH_SEC constant (45min). But quality-gate-dispatcher.sh scales its own verdict
# timeout by diff size up to a 50min cap (ga-ltr3c) — so a large, entirely healthy diff
# review running past 45min (but still inside its own <=50min budget) could trip a false
# "REPARO AUTÔNOMO" spawn. Directly evidenced live in ga-59ifv (dispatcher log showed a
# scaled timeout of 22m->29m for one run and another run at 677s/2100s elapsed/cap while
# the heartbeat's snapshot judged the queue stalled). ga-w29x0 is a PRIOR occurrence of
# this same detector's alarm misfiring, but its own close reason attributes that one to a
# transient disk/RAM crisis, not to this scaled-timeout mechanism — cited here as
# corroborating this detector alarms falsely under load in general, not as a second
# confirmed repro of this exact root cause.
#
# FIX: read the run's OWN reported timeout directly off the dispatcher's "Phase C: ...
# still in flight (G/N verdicts, ELAPSEDs/TIMEOUTs)" log line (PHASE_C_INFLIGHT_RE) instead
# of comparing elapsed to the fixed constant, PROJECTING that line's elapsed forward by the
# gap since it was logged (a stale line's own elapsed is only accurate as of when it was
# written). Verified live (2026-09-11) that this line is the dispatcher's real in-flight
# signal today — VERDICTS_RE (the pattern the OLD in-flight check relied on) matches zero
# lines in the live 19.8k-line dispatcher log.
#
# Scenarios 4-6 below cover a gap an adversarial review found in the first version of this
# fix: that version widened the outer scan-loop bound (REVIEW_SCAN_HORIZON_SEC) but left
# the PHASE_C_INFLIGHT_RE branch gated on a much tighter POLL_SEC*2 (10min) recency check —
# making the widened bound a no-op. Confirmed via mutation testing (running these same
# scenarios against the pre-fix code) that the fix produces a real behavior change, not a
# tautological test.
#
# Exercises gate_merge_stall() end-to-end (not just the inner helper) via synthetic log
# lines and an explicit `now`, so no real dispatcher log or Dolt access is needed.
#
# NOT a general test harness for this file — scoped narrowly to this one bug, same
# convention as the sibling pipeline-throughput-heartbeat.selftest.sh (ga-30xi3) and
# pipeline-throughput-heartbeat.compliance-marker-text-veto.selftest.sh (ga-4s4t6).
#
# Run: bash scripts/pipeline-throughput-heartbeat.gate-merge-scaled-timeout.selftest.sh
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HB="${HB_OVERRIDE:-$SELF_DIR/pipeline-throughput-heartbeat.py}"
[ -f "$HB" ] || { echo "FATAL: pipeline-throughput-heartbeat.py not found at $HB"; exit 1; }

python3 - "$HB" <<'PY'
import importlib.util, sys, time

spec = importlib.util.spec_from_file_location("pth", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.argv = ["pth"]                      # __name__ != "__main__" → main() never runs
spec.loader.exec_module(m)

if not hasattr(m, "PHASE_C_INFLIGHT_RE"):
    print("FATAL: PHASE_C_INFLIGHT_RE not found — has ga-z0xx1 landed?", file=sys.stderr)
    sys.exit(2)

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)

NOW = time.time()

def ts(secs_ago):
    """A dispatcher-log timestamp prefix `secs_ago` seconds before NOW."""
    return time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(NOW - secs_ago))

def marker_line(secs_ago=30, n=1):
    return "%s [quality-gate-dispatcher] Found %d queued marker(s)\n" % (ts(secs_ago), n)

def inflight_line(secs_ago, elapsed_s, timeout_s, run_id="ga-testrun", branch="crew/x/wa-1"):
    return ("%s [quality-gate-dispatcher] Phase C: gate-run %s (branch=%s) still in "
            "flight (0/1 verdicts, %ds/%ds) — leaving for a future sweep.\n"
            % (ts(secs_ago), run_id, branch, elapsed_s, timeout_s))

def run(lines):
    """Call gate_merge_stall() with synthetic log content + a fixed `now` — no real
    dispatcher log or Dolt access. file_fresh() is stubbed True so the DISPATCH_LOG
    freshness gate at the top of gate_merge_stall() doesn't short-circuit on the (real,
    on-disk) log file's actual mtime."""
    orig_file_fresh, orig_tail_lines = m.file_fresh, m.tail_lines
    m.file_fresh = lambda path, max_age=None, now=None: True
    m.tail_lines = lambda path, n: lines
    try:
        return m.gate_merge_stall(now=NOW)
    finally:
        m.file_fresh, m.tail_lines = orig_file_fresh, orig_tail_lines

# ── Scenario 1: the exact reported false positive — fixed ────────────────────────────
# A diff-scaled review at 47min elapsed (2820s) — PAST the old fixed 45min(2700s)
# REVIEW_FRESH_SEC — but still inside its OWN reported 50min(3000s) cap, logged recently.
# Must NOT fire.
r1 = run([marker_line(), inflight_line(secs_ago=60, elapsed_s=2820, timeout_s=3000)])
if r1 is None:
    ok("ga-z0xx1: review at 47min/50min-cap (past old 45min const) correctly suppressed")
else:
    bad("ga-z0xx1 REGRESSION: still false-positives on a run inside its own scaled cap: %r" % (r1,))

# ── Scenario 2: a fresh line already past its OWN cap must still fire ────────────────
# Same shape, but pc_elapsed >= pc_timeout at log time — proves the fix doesn't
# blanket-suppress every in-flight-looking line, only ones inside their own budget.
r2 = run([marker_line(), inflight_line(secs_ago=60, elapsed_s=3050, timeout_s=3000)])
if r2 is not None:
    ok("ga-z0xx1: review already past its OWN reported cap still alarms (not over-suppressed)")
else:
    bad("ga-z0xx1 REGRESSION: a run past its own cap was wrongly suppressed")

# ── Scenario 3: no in-flight evidence at all — baseline stall detection unchanged ─────
r3 = run([marker_line()])
if r3 is not None:
    ok("ga-z0xx1: genuine stall (backlog>0, zero in-flight evidence) still detected")
else:
    bad("ga-z0xx1 REGRESSION: baseline stall-with-no-evidence case stopped firing")

# ── Scenario 4: stale-but-in-horizon line, PROJECTION correctly suppresses ───────────
# Adversarial-review gap: a line 1200s (20min) old reporting elapsed=500s/timeout=2700s
# at LOG time. Projected to now: 500+1200=1700s < 2700s → still legitimately in budget.
# The first (buggy) version of this fix required recency <600s and would have missed
# this — reintroducing a milder version of the reported bug for any line older than 10min.
r4 = run([marker_line(), inflight_line(secs_ago=1200, elapsed_s=500, timeout_s=2700)])
if r4 is None:
    ok("ga-z0xx1: 20min-stale in-flight line, projected elapsed still under cap — suppressed")
else:
    bad("ga-z0xx1 REGRESSION: projection not applied — stale-but-valid line wrongly alarmed: %r" % (r4,))

# ── Scenario 5: stale line whose PROJECTED elapsed now exceeds its cap must fire ──────
# Same 1200s-old line, but elapsed=2600s/timeout=2700s at log time (looked fine when
# logged). Projected: 2600+1200=3800s >= 2700s → the run's own budget would be spent by
# now even without a newer update. Proves projection doesn't over-suppress just because a
# line once looked fresh.
r5 = run([marker_line(), inflight_line(secs_ago=1200, elapsed_s=2600, timeout_s=2700)])
if r5 is not None:
    ok("ga-z0xx1: stale line whose projected elapsed exceeds its own cap still alarms")
else:
    bad("ga-z0xx1 REGRESSION: projection over-suppressed a line that aged past its own cap")

# ── Scenario 6: beyond the outer scan horizon, evidence is never even considered ─────
# A line 3400s old (past REVIEW_SCAN_HORIZON_SEC=3300s) with numbers that WOULD suppress
# if reached (elapsed=10, timeout=5000 — deliberately unrealistic, chosen only to isolate
# whether the outer `break` bound is doing real work). Must fire — proves the scan-loop
# cutoff itself still matters now that the inner branch no longer has its own tight gate.
r6 = run([marker_line(), inflight_line(secs_ago=3400, elapsed_s=10, timeout_s=5000)])
if r6 is not None:
    ok("ga-z0xx1: line beyond the outer scan horizon is correctly never considered")
else:
    bad("ga-z0xx1 REGRESSION: outer scan horizon (REVIEW_SCAN_HORIZON_SEC) not enforced")

print("")
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
rc=$?
echo ""
[ "$rc" = "0" ] && echo "SELFTEST: PASS" || echo "SELFTEST: FAIL (rc=$rc)"
exit $rc
