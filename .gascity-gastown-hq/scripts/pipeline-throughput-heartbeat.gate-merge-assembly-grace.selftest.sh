#!/usr/bin/env bash
# Selftest for pipeline-throughput-heartbeat.py — ga-7wcq1l regression only.
#
# BUG: gate_merge_stall() suppresses for a live review (ga-z0xx1), a Dolt headroom DEFER
# (ga-r1u20) and a deliberate admission pause (ga-wduv5z), but not for a run that is still being
# ASSEMBLED. When a pause ends, the first run logs `Headroom OK` -> `Marker X claimed for
# dispatching.` -> `Spawning N independent reviewer session(s)` -> `Reviewer session N spawned`
# -> `Verdicts requested` -> `Run X admitted: ...`, and only the NEXT sweep's Phase C writes the
# first `still in flight` line, the one in-flight signal _fresh_review_in_progress() reads. That
# assembly takes p50 141s / p99 438s / max 814s (2546 claim -> admitted pairs, dispatcher log
# 2026-09-09..10-05) — often longer than the 5-min tick — so CONFIRM_TICKS=2 spawned a repair dog
# on two healthy runs (10-04 23:55 and 10-05 15:35, both right after a pause ended).
#
# FIX: _run_assembling() — the newest `Spawning N independent reviewer session(s)` line is still
# OPEN (nothing after it admitted, completed or aborted it) and the chain of spawn attempts it
# belongs to is no older than ASSEMBLY_CEILING_SEC. Guards that keep it from becoming a blind spot:
#   * the evidence is the `Spawning` line, NOT the bare claim: 508 of 3137 claims are handed
#     straight back (`sweep complete ... verdict=QUEUED`) and none of them reaches `Spawning`. A
#     QUEUED retry loop (2026-09-25 03:41-04:05) is a real stall and must keep alarming;
#   * the CHAIN is bounded, not the newest attempt: a dead attempt is re-claimed on a later sweep
#     (one measured stall re-claimed 64x over 156min) and per-attempt grace would hide it forever.
#     An aborted attempt or a handed-back claim between attempts does NOT reset the chain;
#     admission, a merge, a headroom DEFER or a deliberate pause does;
#   * an admitted / aborted / completed attempt is closed — nothing is assembling any more;
#   * a hole in the log wider than FLOW_WINDOW_SEC is not assembly time.
#
# Exercises gate_merge_stall() end-to-end via synthetic log lines and an explicit `now` (same
# harness as pipeline-throughput-heartbeat.gate-merge-admission-pause.selftest.sh). The lines in
# scenario 13 are copied VERBATIM from the live dispatcher log, so the test fails if a regex
# drifts from what quality-gate-dispatcher.sh really writes.
#
# NOT a general test harness for this file — scoped narrowly to this one bug. Must FAIL on the
# pre-fix code: HB_OVERRIDE=<pre-fix copy> bash <this file>.
#
# Run: bash scripts/pipeline-throughput-heartbeat.gate-merge-assembly-grace.selftest.sh
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
# Read with a default so the scenarios still RUN (and fail visibly) against the pre-fix code.
CEIL = getattr(m, "ASSEMBLY_CEILING_SEC", 900)

def ts(secs_ago):
    return time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(NOW - secs_ago))

def L(secs_ago, text):
    return "%s [quality-gate-dispatcher] %s\n" % (ts(secs_ago), text)

def marker_line(secs_ago=30, n=15):
    return L(secs_ago, "Found %d queued marker(s)" % n)

def headroom_ok(secs_ago):
    return L(secs_ago, "Headroom OK: gate em 1 runs (Dolt cpu=120% [ambient; post-janitor=105%] lat=200ms / "
                       "cota=ok / swap_free=1410MB mem_pressure=2 disk_free=8354MB) — dolt-calm; ceiling=6 "
                       "reviewers, admitting a new run (ga-cw4pm).")

def headroom_defer(secs_ago):
    return L(secs_ago, "Headroom DEFER: gate em 0 runs (Dolt cpu=141% [ambient; post-janitor=19%] lat=75ms / "
                       "cota=LIMITED / swap_free=1067MB) — quota-limited; ceiling=0 reviewers, leaving 5 "
                       "marker(s) queued (ga-cw4pm).")

def ram_pause(secs_ago):
    return L(secs_ago, "RAM pressure WARN (ram-pressure-monitor.sh, ~/.gastown/run/ram-pressure-monitor.level) "
                       "— PAUSING new-run admission this sweep (mirrors Pilot's ga-m2gqb gate), leaving 15 "
                       "marker(s) queued (ga-jezvn).")

def claim(secs_ago, marker="ga-vi8y38"):
    return L(secs_ago, "Marker %s claimed for dispatching." % marker)

def spawning(secs_ago):
    return L(secs_ago, "Spawning 1 independent reviewer session(s) ...")

def spawned(secs_ago):
    return L(secs_ago, "  Reviewer session 1 spawned: session_id=ga-wisp-hx0kcn verdict_bead=ga-2uzjnz")

def verdicts_requested(secs_ago):
    return L(secs_ago, "Verdicts requested (timeout=50m) — checking once now; if incomplete, a future sweep's "
                       "Phase C finalizes (ga-eqjo, no longer blocking here).")

def admitted(secs_ago):
    return L(secs_ago, "Run ga-aglpqb admitted: 0/2 verdict(s) in so far — reviewers keep working independently "
                       "(Phase B); a future sweep's Phase C will finalize (ga-eqjo).")

def abort(secs_ago):
    return L(secs_ago, "ERROR: Failed to spawn reviewer session 1 (ga-mzc3h). Aborting gate. spawn_err=[mysql] "
                       "2026/09/19 13:32:02 packets.go:58 read tcp 127.0.0.1:50609->127.0.0.1:52756: i/o timeout")

def handed_back(secs_ago):
    return L(secs_ago, "=== Dispatcher sweep complete: branch=crew/wa-worker/wa-rvnkk-reanchor verdict=QUEUED "
                       "(merge-tree proven clean, transient failures repeat, staying in bounded retry — "
                       "ga-y5c29l) ===")

def noise(secs_ago):
    """Lines every sweep writes whether or not it assembles — must not count as evidence."""
    return (L(secs_ago, "=== Dispatcher sweep start (DRY_RUN=0) ===")
            + L(secs_ago, "Phase C: sweeping 1 in-flight gate-run(s) for completion/timeout (ga-eqjo)."))

def assembly(start_ago, with_admit_ago=None):
    """One healthy assembly as the dispatcher logs it, oldest line first, starting `start_ago` s
    back. The admission line is only written when `with_admit_ago` is given."""
    out = [noise(start_ago + 30), headroom_ok(start_ago + 20), claim(start_ago),
           spawning(start_ago - 8), spawned(start_ago - 140), verdicts_requested(start_ago - 200)]
    if with_admit_ago is not None:
        out.append(admitted(with_admit_ago))
    return out

def run(lines):
    """gate_merge_stall() on synthetic log content + fixed `now`. file_fresh() is stubbed True and
    tail_lines() returns the fixture whole."""
    orig_file_fresh, orig_tail_lines = m.file_fresh, m.tail_lines
    m.file_fresh = lambda path, max_age=None, now=None: True
    m.tail_lines = lambda path, n: lines
    try:
        return m.gate_merge_stall(now=NOW)
    finally:
        m.file_fresh, m.tail_lines = orig_file_fresh, orig_tail_lines

# ── 1: the reported false positive (the bead's fixture) ─────────────────────────────────
# Headroom OK + a recent claim + zero merges, the run still being assembled (no admission yet).
r = run([marker_line()] + assembly(290))
if r is None:
    ok("ga-7wcq1l: Headroom OK + recent claim + reviewers spawning + zero merges → suppressed")
else:
    bad("ga-7wcq1l: a run mid-assembly still false-positives: %r" % (r,))

# ── 2: the same run past the ceiling must alarm ─────────────────────────────────────────
r = run([marker_line()] + assembly(CEIL + 120))
if r is not None:
    ok("ga-7wcq1l: the same assembly older than ASSEMBLY_CEILING_SEC (%ds) still alarms" % CEIL)
else:
    bad("ga-7wcq1l: an assembly older than the ceiling was suppressed — the guard has no bound")

# ── 3: pause just ended, the run is assembling (the 10-04 / 10-05 shape) ────────────────
pause = []
t = 1500
while t >= 620:
    pause += [noise(t), ram_pause(t)]
    t -= 90
r = run([marker_line()] + pause + assembly(290))
if r is None:
    ok("ga-7wcq1l: admission pause ended, first run still assembling → suppressed")
else:
    bad("ga-7wcq1l: first run after a pause false-positives: %r" % (r,))

# ── 4: a dead-attempt chain is bounded by its START, not by the newest attempt ──────────
# Reviewers spawned every ~150s for 20min, never admitted (a dead sweep is re-claimed). The
# newest attempt is only 60s old, but the chain has run past the ceiling → this IS the stall.
chain = []
t = 1200
while t >= 60:
    chain += [noise(t + 30), headroom_ok(t + 20), claim(t), spawning(t - 8)]
    t -= 150
r = run([marker_line()] + chain)
if r is not None:
    ok("ga-7wcq1l: a spawn chain re-claimed past the ceiling alarms (newest attempt only 60s old)")
else:
    bad("ga-7wcq1l: a dead-attempt chain kept getting fresh grace and was never alarmed")

# ── 5: the same chain inside the ceiling is still just an assembly ──────────────────────
chain = []
t = 450
while t >= 60:
    chain += [noise(t + 30), headroom_ok(t + 20), claim(t), spawning(t - 8)]
    t -= 150
r = run([marker_line()] + chain)
if r is None:
    ok("ga-7wcq1l: a short chain of spawn attempts (inside the ceiling) is suppressed")
else:
    bad("ga-7wcq1l: a fresh multi-attempt chain false-positives: %r" % (r,))

# ── 6: an admitted run is no longer 'assembling' ────────────────────────────────────────
# Phase C owns it from here; if its first in-flight line never shows up, that is a stall again.
r = run([marker_line()] + assembly(600, with_admit_ago=500))
if r is not None:
    ok("ga-7wcq1l: admission closes the assembly — no in-flight line afterwards alarms")
else:
    bad("ga-7wcq1l: an already admitted run was still treated as being assembled")

# ── 7: an aborted attempt is closed ─────────────────────────────────────────────────────
r = run([marker_line(), noise(150), headroom_ok(140), claim(130), spawning(120), abort(60)])
if r is not None:
    ok("ga-7wcq1l: 'Aborting gate' closes the attempt — nothing is assembling")
else:
    bad("ga-7wcq1l: an aborted attempt was still treated as being assembled")

# ── 8: a QUEUED retry loop is NOT assembly (bare claims are no evidence) ────────────────
# 2026-09-25 03:41-04:05: claim -> `sweep complete verdict=QUEUED` ~25s later, every ~2.3min,
# for two hours. The claim is open for ~20s of each cycle; counting it would suppress ~1 tick
# in 5 of a real stall. The newest claim here is 10s old and not yet handed back.
def queued_loop(first_ago):
    out, t = [], first_ago
    while t >= 150:
        out += [noise(t + 30), headroom_ok(t + 20), claim(t, "ga-r6bore"), handed_back(t - 25)]
        t -= 140
    return out + [noise(40), headroom_ok(30), claim(10, "ga-r6bore")]

r_young = run([marker_line()] + queued_loop(600))     # loop younger than the ceiling
r_old = run([marker_line()] + queued_loop(1500))      # loop older than the ceiling
if r_young is not None and r_old is not None:
    ok("ga-7wcq1l: claim -> QUEUED retry loop alarms, young or old (a bare claim is not assembly evidence)")
else:
    bad("ga-7wcq1l: a claim -> QUEUED retry loop was suppressed (young=%r old=%r) — the 09-25 stall "
        "would be hidden" % (r_young, r_old))

# ── 9: an aborted attempt between spawns does not reset the chain ───────────────────────
# Spawn -> abort every 5min for 25min (Dolt i/o timeouts), the newest attempt 60s old and open.
cyc = []
t = 1500
while t >= 400:
    cyc += [noise(t + 30), headroom_ok(t + 20), claim(t), spawning(t - 8), abort(t - 120)]
    t -= 300
cyc += [noise(90), headroom_ok(80), claim(70), spawning(60)]
r = run([marker_line()] + cyc)
if r is not None:
    ok("ga-7wcq1l: spawn -> abort cycles do not reset the chain — a 25min loop alarms")
else:
    bad("ga-7wcq1l: aborted attempts reset the chain and handed out fresh grace each time")

# ── 10: a handed-back claim between spawn attempts does not reset the chain either ──────
r = run([marker_line(), spawning(CEIL + 100), claim(400, "ga-r6bore"), handed_back(375),
         headroom_ok(90), claim(80), spawning(70)])
if r is not None:
    ok("ga-7wcq1l: a handed-back claim between attempts leaves the chain start where it was")
else:
    bad("ga-7wcq1l: a handed-back claim reset the chain")

# ── 11: a Headroom DEFER is a decline — it ends the chain ───────────────────────────────
# An attempt that died long ago, a deliberate DEFER, then a fresh attempt: the fresh one gets
# its own grace instead of inheriting the minutes the gate spent throttled.
r = run([marker_line(), spawning(CEIL + 600), headroom_defer(CEIL + 300), headroom_ok(90),
         claim(80), spawning(70)])
if r is None:
    ok("ga-7wcq1l: a headroom DEFER ends the chain — the attempt after it gets its own grace")
else:
    bad("ga-7wcq1l: a stale attempt before a DEFER was counted into the new chain: %r" % (r,))

# ── 12: a hole in the log is not assembly time ──────────────────────────────────────────
r = run([marker_line(), spawning(m.FLOW_WINDOW_SEC + 2000), headroom_ok(90), claim(80), spawning(70)])
if r is None:
    ok("ga-7wcq1l: a >FLOW_WINDOW_SEC hole between attempts splits the chain")
else:
    bad("ga-7wcq1l: a silent gap was counted as assembly time and tripped the ceiling: %r" % (r,))

# ── 12b: an undated Spawning line is no evidence ────────────────────────────────────────
r = run([marker_line(), "[quality-gate-dispatcher] Spawning 1 independent reviewer session(s) ...\n"])
if r is not None:
    ok("ga-7wcq1l: an undated 'Spawning' line cannot be aged, so it does not suppress")
else:
    bad("ga-7wcq1l: an undated 'Spawning' line suppressed the alarm")

# ── 13: verbatim live lines are recognised (guards against regex drift) ─────────────────
# 2026-10-05 15:29-15:36 (ga-aglpqb, the incident) and 2026-09-17 / 09-19 outcomes, copied from
# the live dispatcher log.
verbatim = {
    "spawning":  "Spawning 1 independent reviewer session(s) ...",
    "admitted":  "Run ga-aglpqb admitted: 0/2 verdict(s) in so far — reviewers keep working independently "
                 "(Phase B); a future sweep's Phase C will finalize (ga-eqjo).",
    "sweepdone": "=== Dispatcher sweep complete: branch=crew/wa-worker/wa-h140n verdict=QUEUED "
                 "(retry 1/3, dead author) ===",
    "abort":     "ERROR: Failed to spawn reviewer session 1 (ga-mzc3h). Aborting gate. spawn_err=[mysql] "
                 "2026/09/19 13:32:02 packets.go:58 read tcp 127.0.0.1:50609->127.0.0.1:52756: i/o timeout",
}
pre = getattr(m, "ASSEMBLY_SPAWNING_RE", None)
miss = []
if pre is None or not pre.search(verbatim["spawning"]):
    miss.append("spawning")
if getattr(m, "ASSEMBLY_ADMITTED_RE", None) is None or not m.ASSEMBLY_ADMITTED_RE.search(verbatim["admitted"]):
    miss.append("admitted")
if getattr(m, "ASSEMBLY_SWEEP_DONE_RE", None) is None or not m.ASSEMBLY_SWEEP_DONE_RE.search(verbatim["sweepdone"]):
    miss.append("sweepdone")
if getattr(m, "ASSEMBLY_ABORT_RE", None) is None or not m.ASSEMBLY_ABORT_RE.search(verbatim["abort"]):
    miss.append("abort")
# ...and the claim line, which is deliberately NOT evidence, must not match the evidence regex
if pre is not None and pre.search("Marker ga-vi8y38 claimed for dispatching."):
    miss.append("claim-matched-as-evidence")
if not miss:
    ok("ga-7wcq1l: every verbatim live line (spawning, admitted, sweep complete, abort) is recognised")
else:
    bad("ga-7wcq1l: live-format lines NOT recognised / wrongly recognised: %s" % ", ".join(miss))

# The incident itself, line for line (10-05 15:28-15:36, tick at 15:35:00): Headroom OK 15:28:41,
# claim 15:29:00, Spawning 15:29:08, session spawned 15:31:27, Verdicts requested 15:36:15,
# admitted 15:36:18 — at the 15:35:00 tick (= now) the run is mid-assembly. Offsets are seconds
# before that tick.
r = run([marker_line(),
         L(379, "Headroom OK: gate em 1 runs (Dolt cpu=120% [ambient; post-janitor=105%] lat=200ms / cota=ok / "
                "swap_free=1410MB mem_pressure=2 disk_free=8354MB) — dolt-calm; ceiling=6 reviewers, admitting "
                "a new run (ga-cw4pm)."),
         L(360, "Marker ga-vi8y38 claimed for dispatching."),
         L(352, verbatim["spawning"]),
         L(213, "  Reviewer session 1 spawned: session_id=ga-wisp-hx0kcn verdict_bead=ga-2uzjnz")])
if r is None:
    ok("ga-7wcq1l: the 10-05 15:35 incident, replayed line for line, no longer alarms")
else:
    bad("ga-7wcq1l: the 10-05 15:35 incident still alarms: %r" % (r,))

print("")
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
rc=$?
echo ""
[ "$rc" = "0" ] && echo "SELFTEST: PASS" || echo "SELFTEST: FAIL (rc=$rc)"
exit $rc
