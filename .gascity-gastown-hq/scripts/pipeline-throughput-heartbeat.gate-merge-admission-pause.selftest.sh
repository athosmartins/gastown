#!/usr/bin/env bash
# Selftest for pipeline-throughput-heartbeat.py — ga-wduv5z regression only.
#
# BUG: gate_merge_stall() has two suppressors for a gate that is slow ON PURPOSE — a live
# review (ga-z0xx1) and a Dolt headroom DEFER (ga-r1u20) — but none for the dispatcher's
# other deliberate admission pauses. While the RAM-pressure guard (ga-jezvn) pauses new-run
# admission the gate is healthy and throttled, yet the heartbeat saw "N markers queued, zero
# merges in 30min, no review in flight" and dispatched a repair dog — a fresh dog session at
# the exact moment the machine is short of RAM, i.e. it worsened what the guard protects.
# Measured 05/10/2026 (ga-fjlurc): swap 7.66 GB, 483 'PAUSING new-run admission' lines in the
# live dispatcher log, last merge 13:44 with admission paused since.
#
# FIX: _admission_pause_deferring() — the MOST RECENT admission decision in the window being
# a deliberate pause (RAM pressure, global variable-session cap, drain window, quiet hours)
# means throttled-not-stalled. Three guards keep it from becoming a blind spot:
#   * a pause older than FLOW_WINDOW_SEC does not suppress;
#   * any later decision that got PAST the pause gates (Headroom OK/DEFER, a merge, the
#     fail-CLOSED probe error) ends the pause — "admitting and STILL not merging" alarms;
#   * a CONDITION-driven pause (RAM, cap) stops suppressing after
#     ADMISSION_PAUSE_CEILING_SEC (scheduled pauses are bounded by the clock and exempt).
#
# Exercises gate_merge_stall() end-to-end via synthetic log lines and an explicit `now` (same
# harness as pipeline-throughput-heartbeat.gate-merge-scaled-timeout.selftest.sh). The
# pause/decision lines in scenario 9 are copied VERBATIM from the live dispatcher log, so the
# test fails if a regex drifts from what quality-gate-dispatcher.sh really writes.
#
# NOT a general test harness for this file — scoped narrowly to this one bug.
#
# Run: bash scripts/pipeline-throughput-heartbeat.gate-merge-admission-pause.selftest.sh
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

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)

NOW = time.time()
REQUESTED_N = []   # every `n` gate_merge_stall() asked tail_lines() for
# Read with a default so the scenarios still RUN (and fail visibly) against the pre-fix code.
CEIL = getattr(m, "ADMISSION_PAUSE_CEILING_SEC", 7200)

def ts(secs_ago):
    return time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(NOW - secs_ago))

def L(secs_ago, text):
    return "%s [quality-gate-dispatcher] %s\n" % (ts(secs_ago), text)

def marker_line(secs_ago=30, n=17):
    return L(secs_ago, "Found %d queued marker(s)" % n)

def ram_pause(secs_ago, level="WARN"):
    return L(secs_ago, "RAM pressure %s (ram-pressure-monitor.sh, ~/.gastown/run/ram-pressure-monitor.level) "
                       "— PAUSING new-run admission this sweep (mirrors Pilot's ga-m2gqb gate), leaving 17 "
                       "marker(s) queued (ga-jezvn)." % level)

def cap_hit(secs_ago):
    return L(secs_ago, "GLOBAL variable-session cap hit (9/9: wa-worker+ps-worker+gate-reviewer combined) "
                       "— QUEUED, leaving 2 marker(s) queued, retried next sweep (ga-jezvn).")

def drain_pause(secs_ago):
    return L(secs_ago, "Drain window (nightly-reboot.sh, ~/.gastown/run/city-drain.level: ate 00:30, gravado ha "
                       "4min) — PAUSING new-run admission this sweep so the nightly reboot finds the gate idle, "
                       "leaving 3 marker(s) queued; in-flight reviews finish and queued markers resume after "
                       "the reboot (ga-a2v0bz).")

def quiet_pause(secs_ago):
    return L(secs_ago, "Quiet hours (city-night-window.sh, ~/.gastown/run/city-quiet-hours.level) — PAUSING "
                       "new-run admission this sweep (00h-08h, Athos 2026-08-16), leaving 3 marker(s) queued "
                       "(ga-dxyvxr).")

def headroom_ok(secs_ago):
    return L(secs_ago, "Headroom OK: gate em 4 runs (Dolt cpu=117% [ambient; post-janitor=13%] lat=283ms / "
                       "cota=ok / swap_free=758MB mem_pressure=1 disk_free=10101MB) — dolt-calm; ceiling=6 "
                       "reviewers, admitting a new run (ga-cw4pm).")

def failclosed(secs_ago):
    return L(secs_ago, "cannot read the global variable-session count (gc session list failed, timed out "
                       "after 30s, or returned no .sessions array) — fail CLOSED: QUEUED, leaving 1 marker(s) "
                       "queued, retried next sweep (ga-z4jhda).")

def noise(secs_ago):
    """Lines every sweep writes whether or not it admits — must not count as a decision."""
    return (L(secs_ago, "=== Dispatcher sweep start (DRY_RUN=0) ===")
            + L(secs_ago, "Phase C: sweeping 1 in-flight gate-run(s) for completion/timeout (ga-eqjo)."))

def run_of(fn, start_ago, end_ago, step=300):
    """Chronological (oldest first) lines of one decision kind, every `step`s, with sweep noise."""
    out, t = [], start_ago
    while t >= end_ago:
        out.append(noise(t))
        out.append(fn(t))
        t -= step
    return out

def run(lines):
    """gate_merge_stall() on synthetic log content + fixed `now`. file_fresh() is stubbed True and
    tail_lines() returns the fixture whole; the `n` it was asked for lands in REQUESTED_N."""
    orig_file_fresh, orig_tail_lines = m.file_fresh, m.tail_lines
    m.file_fresh = lambda path, max_age=None, now=None: True
    def _tail(path, n):
        REQUESTED_N.append(n)
        return lines
    m.tail_lines = _tail
    try:
        return m.gate_merge_stall(now=NOW)
    finally:
        m.file_fresh, m.tail_lines = orig_file_fresh, orig_tail_lines

# ── 1: the reported false positive ──────────────────────────────────────────────────────
r = run([marker_line()] + run_of(ram_pause, 600, 30, step=90))
if r is None:
    ok("ga-wduv5z: fresh RAM-pressure pause, queue>0, no merges → suppressed (no repair dog)")
else:
    bad("ga-wduv5z: RAM-pressure pause still false-positives: %r" % (r,))

# ── 2: a stale pause must not suppress ──────────────────────────────────────────────────
r = run([marker_line()] + run_of(ram_pause, m.FLOW_WINDOW_SEC + 900, m.FLOW_WINDOW_SEC + 300, step=90))
if r is not None:
    ok("ga-wduv5z: pause older than FLOW_WINDOW_SEC does not suppress")
else:
    bad("ga-wduv5z: a stale pause wrongly suppressed the alarm")

# ── 3: pause lifted, gate admitted and STILL isn't merging → must alarm ─────────────────
r = run([marker_line()] + run_of(ram_pause, 900, 400, step=90) + [headroom_ok(200)])
if r is not None:
    ok("ga-wduv5z: pause followed by a Headroom OK (admitting) with no merge still alarms")
else:
    bad("ga-wduv5z: suppressed although the pause ended and the gate is admitting but not merging")

# ── 4: condition-driven pause longer than the ceiling must stop suppressing ─────────────
r = run([headroom_ok(CEIL + 3600), marker_line()] + run_of(ram_pause, CEIL + 3000, 30, step=300))
if r is not None and "teto" in r:
    ok("ga-wduv5z: RAM pause past the ceiling alarms, with a reason that names the ceiling")
else:
    bad("ga-wduv5z: prolonged RAM pause neither alarmed nor named the ceiling: %r" % (r,))

# ── 5: scheduled pauses (quiet hours / drain) are bounded by the clock → exempt ─────────
r_q = run([headroom_ok(CEIL + 3600), marker_line()] + run_of(quiet_pause, CEIL + 3000, 30, step=300))
r_d = run([headroom_ok(CEIL + 3600), marker_line()] + run_of(drain_pause, CEIL + 3000, 30, step=300))
if r_q is None and r_d is None:
    ok("ga-wduv5z: quiet-hours and drain-window pauses suppress even past the ceiling")
else:
    bad("ga-wduv5z: scheduled pause alarmed (quiet=%r drain=%r)" % (r_q, r_d))

# ── 6: global variable-session cap — same class, different wording ──────────────────────
r_fresh = run([marker_line()] + run_of(cap_hit, 600, 30, step=90))
r_long = run([headroom_ok(CEIL + 3600), marker_line()] + run_of(cap_hit, CEIL + 3000, 30, step=300))
if r_fresh is None and r_long is not None and "teto" in r_long:
    ok("ga-wduv5z: session-cap pause suppresses while fresh and alarms past the ceiling")
else:
    bad("ga-wduv5z: session-cap handling wrong (fresh=%r long=%r)" % (r_fresh, r_long))

# ── 7: probe error is NOT a deliberate throttle (error ≠ 'paused') ──────────────────────
r = run([marker_line()] + run_of(ram_pause, 900, 400, step=90) + [failclosed(120)])
if r is not None:
    ok("ga-wduv5z: fail-CLOSED probe error after a pause ends it — not treated as a throttle")
else:
    bad("ga-wduv5z: a fail-CLOSED session-list error was swallowed as a deliberate pause")

# ── 8: log tail shorter than the ceiling, no breaker visible → benefit of the doubt ─────
r = run([marker_line()] + run_of(ram_pause, 1200, 30, step=90))
if r is None:
    ok("ga-wduv5z: pause run whose start is beyond the tail still suppresses (fresh evidence)")
else:
    bad("ga-wduv5z: truncated-tail pause run alarmed: %r" % (r,))

# ── 9: verbatim live-format lines are recognised (guards against regex drift) ───────────
verbatim = [
    ("RAM", "[%s] [quality-gate-dispatcher] RAM pressure WARN (ram-pressure-monitor.sh, "
            "~/.gastown/run/ram-pressure-monitor.level) — PAUSING new-run admission this sweep (mirrors "
            "Pilot's ga-m2gqb gate), leaving 17 marker(s) queued (ga-jezvn).\n"),
    ("RAM-EMERGENCY", "[%s] [quality-gate-dispatcher] RAM pressure EMERGENCY (ram-pressure-monitor.sh, "
            "~/.gastown/run/ram-pressure-monitor.level) — PAUSING new-run admission this sweep (mirrors "
            "Pilot's ga-m2gqb gate), leaving 17 marker(s) queued (ga-jezvn).\n"),
    ("cap", "[%s] [quality-gate-dispatcher] GLOBAL variable-session cap hit (9/9: "
            "wa-worker+ps-worker+gate-reviewer combined) — QUEUED, leaving 2 marker(s) queued, retried "
            "next sweep (ga-jezvn).\n"),
    ("drain", "[%s] [quality-gate-dispatcher] Drain window (nightly-reboot.sh, "
              "~/.gastown/run/city-drain.level: ate 00:30, gravado ha 4min) — PAUSING new-run admission "
              "this sweep so the nightly reboot finds the gate idle, leaving 3 marker(s) queued; in-flight "
              "reviews finish and queued markers resume after the reboot (ga-a2v0bz).\n"),
]
misses = []
for name, tpl in verbatim:
    got = run([marker_line(), tpl % time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(NOW - 60))])
    if got is not None:
        misses.append(name)
if not misses:
    ok("ga-wduv5z: every verbatim live pause line (RAM WARN/EMERGENCY, cap, drain) is recognised")
else:
    bad("ga-wduv5z: live-format pause lines NOT recognised: %s" % ", ".join(misses))

# ── 10: UNREADABLE fail-open line is not a pause ────────────────────────────────────────
r = run([marker_line(),
         L(60, "RAM-pressure signal UNREADABLE (stale/corrupt /Users/athos/.gastown/run/ram-pressure-monitor.level)"
               " — fail-open, admission proceeding normally this sweep (ga-jezvn).")])
if r is not None:
    ok("ga-wduv5z: a fail-open 'signal UNREADABLE' line is not mistaken for a pause")
else:
    bad("ga-wduv5z: 'RAM-pressure signal UNREADABLE' (admission proceeding) suppressed the alarm")

# ── 11: the tail must reach back past the ceiling, or the ceiling cannot be enforced ────
# A paused log is ~3.8 lines/min (measured live), a busier one far more; the line count asked of
# tail_lines() has to cover CEIL at a conservative 25 lines/min or a long pause is under-measured
# and suppressed past the ceiling without anyone noticing.
asked = max(REQUESTED_N) if REQUESTED_N else 0
need = CEIL // 60 * 25
if asked >= need:
    ok("ga-wduv5z: gate_merge_stall reads %d log lines (≥ %d needed to span the ceiling at 25 lines/min)"
       % (asked, need))
else:
    bad("ga-wduv5z: gate_merge_stall reads only %d log lines; %d are needed to span the ceiling" % (asked, need))

print("")
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
rc=$?
echo ""
[ "$rc" = "0" ] && echo "SELFTEST: PASS" || echo "SELFTEST: FAIL (rc=$rc)"
exit $rc
