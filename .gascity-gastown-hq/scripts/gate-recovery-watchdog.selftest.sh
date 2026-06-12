#!/usr/bin/env bash
# gate-recovery-watchdog.selftest.sh — Regression harness for the gate watchdog's
# orphaned-queued-marker detector (gt-mqkwj).
#
# The detector closes a blind spot the other three checks miss: a
# gate-status:queued marker whose gate_run was DROPPED during a dispatcher outage
# is leapfrogged forever — its source bead stays in_progress and the reconciler
# re-spawns a worker ~6x onto finished work. It is invisible to recent_timeouts
# (no TIMEOUT), stuck_dispatching (not 'dispatching'), and headofline_stall (the
# queue drains for OTHER branches).
#
# These scenarios drive the PURE core _detect_orphan_markers() (and _iso_epoch())
# against synthetic fixtures — no live Dolt, no live log, no gc/bd. The key risk
# the harness pins down is the FALSE-POSITIVE surface: the literal AC ("queued
# marker older than the newest sweep-complete + zero mentions") would fire on a
# whole normal FIFO backlog, so the detector adds a leapfrog proof (a strictly-
# newer queued marker IS being dispatched) plus a drain-freshness gate. Scenarios
# 2/3/4/5/6 are the guards; Scenario 8 replays the real 2026-06-12 incident shape
# (dispatcher wedged on its current run, NOT draining) to prove no false fire.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="$SCRIPT_DIR/gate-recovery-watchdog.py"

/usr/bin/python3 - "$WD" <<'PY'
import sys, importlib.util, datetime

wd_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("gate_recovery_watchdog", wd_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)   # top-level only defines; main() is guarded by __main__

PASS = 0
FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)

NOW = 1_000_000.0   # fixed synthetic "now" (epoch seconds)
MIN_AGE = m.ORPHAN_MIN_AGE_SEC
DRAIN = m.ORPHAN_DRAIN_FRESH_SEC

def mk(mid, branch, age_sec):
    """marker tuple created `age_sec` ago."""
    return (mid, branch, NOW - age_sec)

# A fresh drain: a completed sweep 60s ago (within DRAIN window).
FRESH_SWEEPS = [NOW - 60]
# A stale drain: newest completed sweep is older than the DRAIN window.
STALE_SWEEPS = [NOW - (DRAIN + 600)]

# ── Scenario 1: TRUE orphan (leapfrog) is detected ───────────────────────────
print("Scenario 1: leapfrogged orphan detected (old+unmentioned, newer marker IS dispatched)")
markers = [
    mk("ga-wisp-orphan", "crew/wa/wa-uzai", MIN_AGE + 3600),   # old, will be unmentioned
    mk("ga-wisp-newer",  "crew/wa/wa-newer", MIN_AGE - 600),   # newer, IS mentioned
]
log = "[..] claimed branch=crew/wa/wa-newer for dispatching\nVerdicts: 1/3\n"
res = m._detect_orphan_markers(markers, FRESH_SWEEPS, log, NOW)
ids = [r[0] for r in res]
if ids == ["ga-wisp-orphan"]:
    ok("the old unmentioned marker is flagged; the newer (mentioned) one is not")
else:
    bad("expected ['ga-wisp-orphan'], got %r" % (ids,))

# ── Scenario 2: NO false fire on a normal FIFO backlog (nothing leapfrogged) ──
print("Scenario 2: normal backlog — old unmentioned markers but NOTHING is leapfrogged → silent")
markers = [
    mk("ga-wisp-a", "crew/wa/wa-a", MIN_AGE + 3600),
    mk("ga-wisp-b", "crew/wa/wa-b", MIN_AGE + 1800),
]
log = "[..] sweep complete: branch=crew/other/done verdict=PASS\n"  # neither queued branch mentioned
res = m._detect_orphan_markers(markers, FRESH_SWEEPS, log, NOW)
if res == []:
    ok("no newer queued marker is being dispatched → no leapfrog → no orphan (no false positive)")
else:
    bad("expected [] (backlog, not orphan), got %r" % (res,))

# ── Scenario 3: dispatcher WEDGED on current run (not draining) → silent ──────
print("Scenario 3: dispatcher not draining (newest sweep-complete is stale) → silent")
markers = [
    mk("ga-wisp-orphan", "crew/wa/wa-uzai", MIN_AGE + 3600),
    mk("ga-wisp-newer",  "crew/wa/wa-newer", MIN_AGE - 600),
]
log = "[..] claimed branch=crew/wa/wa-newer for dispatching\n"
res = m._detect_orphan_markers(markers, STALE_SWEEPS, log, NOW)
if res == []:
    ok("stale newest-sweep → dispatcher wedged on its current run, a different failure mode → silent")
else:
    bad("expected [] (not draining), got %r" % (res,))

# ── Scenario 4: a mentioned marker is never flagged (it IS being dispatched) ──
print("Scenario 4: the orphan candidate's branch IS mentioned → excluded")
markers = [
    mk("ga-wisp-cur", "crew/wa/wa-cur", MIN_AGE + 3600),       # old but currently dispatched
    mk("ga-wisp-newer", "crew/wa/wa-newer", MIN_AGE - 600),
]
log = "[..] claimed branch=crew/wa/wa-cur for dispatching\nVerdicts: 0/3\nclaimed branch=crew/wa/wa-newer\n"
res = m._detect_orphan_markers(markers, FRESH_SWEEPS, log, NOW)
if res == []:
    ok("a marker mentioned in the log is being/already dispatched, not orphaned")
else:
    bad("expected [] (mentioned → not orphan), got %r" % (res,))

# ── Scenario 5: a just-created marker (under MIN_AGE) is never flagged ────────
print("Scenario 5: too-fresh marker (age < ORPHAN_MIN_AGE_SEC) → not yet 'skipped'")
markers = [
    mk("ga-wisp-fresh", "crew/wa/wa-fresh", MIN_AGE - 60),     # just created
    mk("ga-wisp-newer", "crew/wa/wa-newer", MIN_AGE - 600),
]
log = "[..] claimed branch=crew/wa/wa-newer for dispatching\n"
res = m._detect_orphan_markers(markers, FRESH_SWEEPS, log, NOW)
if res == []:
    ok("a marker younger than the min-age floor is not called an orphan")
else:
    bad("expected [] (too fresh), got %r" % (res,))

# ── Scenario 6: no completed sweeps at all → silent (can't prove draining) ────
print("Scenario 6: no 'sweep complete' epochs → silent")
markers = [mk("ga-wisp-orphan", "crew/wa/wa-uzai", MIN_AGE + 3600),
           mk("ga-wisp-newer", "crew/wa/wa-newer", MIN_AGE - 600)]
log = "[..] claimed branch=crew/wa/wa-newer for dispatching\n"
res = m._detect_orphan_markers(markers, [], log, NOW)
if res == []:
    ok("no sweep evidence → cannot establish draining → no fire")
else:
    bad("expected [] (no sweeps), got %r" % (res,))

# ── Scenario 7: _iso_epoch parses UTC and compares across the tz boundary ─────
print("Scenario 7: _iso_epoch — UTC marker time compares correctly with local log epoch")
e = m._iso_epoch("2026-06-12T23:00:37Z")
if e is None:
    bad("_iso_epoch returned None for a valid UTC stamp")
else:
    # same instant via datetime → epoch
    want = datetime.datetime(2026, 6, 12, 23, 0, 37, tzinfo=datetime.timezone.utc).timestamp()
    if abs(e - want) < 1e-6:
        ok("UTC 'Z' stamp → correct absolute epoch (%.0f)" % e)
    else:
        bad("epoch mismatch: got %r want %r" % (e, want))
if m._iso_epoch("garbage") is None and m._iso_epoch(None) is None:
    ok("malformed/empty created_at → None (fail-safe)")
else:
    bad("expected None for malformed/empty created_at")

# ── Scenario 8: REPLAY the live 2026-06-12 incident shape → must stay SILENT ──
print("Scenario 8: live-incident replay — 12 markers older than a STALE newest-sweep, oldest IS mentioned")
# Real shape: dispatcher recovered with ONE sweep at 19:45 then wedged on the
# current run (ga-v3z4z, which HAS mentions). Newest completed sweep is ~33min
# stale → not draining. None of the backlog should be flagged.
markers = [mk("ga-wisp-v3z4z", "fix/ga-v3z4z-pilot-neverstarted-recovery", MIN_AGE + 2400)]
markers += [mk("ga-wisp-b%d" % i, "crew/wa/wa-b%d" % i, MIN_AGE + 600 + i*120) for i in range(11)]
incident_log = "[2026-06-12 20:13:40] Re-convening dead reviewer slot 0 ... branch=fix/ga-v3z4z-pilot-neverstarted-recovery\n" * 9
res = m._detect_orphan_markers(markers, STALE_SWEEPS, incident_log, NOW)
if res == []:
    ok("a normal backlog stuck behind a wedged current run does NOT false-fire (the literal AC would have flagged 12)")
else:
    bad("REGRESSION: live-incident backlog falsely flagged as orphan: %r" % (res,))
# And even if we PRETEND the dispatcher is draining, the oldest (ga-v3z4z) is
# mentioned so it is excluded, and the rest have no newer-mentioned sibling.
res2 = m._detect_orphan_markers(markers, FRESH_SWEEPS, incident_log, NOW)
if all(r[0] != "ga-wisp-v3z4z" for r in res2):
    ok("the current (mentioned) run is never flagged even when draining")
else:
    bad("REGRESSION: the actively-worked run ga-v3z4z was flagged as orphan")

# ── Scenario 9: oldest-first ordering when multiple orphans exist ─────────────
print("Scenario 9: multiple orphans → oldest returned first")
markers = [
    mk("ga-wisp-old",  "crew/wa/wa-old",  MIN_AGE + 7200),
    mk("ga-wisp-mid",  "crew/wa/wa-mid",  MIN_AGE + 3600),
    mk("ga-wisp-newer","crew/wa/wa-newer", MIN_AGE - 600),    # mentioned → the leapfrogger
]
log = "[..] claimed branch=crew/wa/wa-newer for dispatching\n"
res = m._detect_orphan_markers(markers, FRESH_SWEEPS, log, NOW)
res.sort(key=lambda o: o[2], reverse=True)  # mirror orphaned_queued_marker()
if res and res[0][0] == "ga-wisp-old":
    ok("oldest orphan (ga-wisp-old) is first; %d orphans found" % len(res))
else:
    bad("expected oldest-first ['ga-wisp-old', ...], got %r" % ([r[0] for r in res],))

# ── Drift guard: the live script actually wires the detector in ──────────────
print("Scenario 10: drift-guard — detector defined and wired into main()")
src = open(wd_path).read()
for needle, desc in [
    ("def orphaned_queued_marker(", "public orphaned_queued_marker() is defined"),
    ("def _detect_orphan_markers(", "pure _detect_orphan_markers() is defined"),
    ("def _iso_epoch(", "_iso_epoch() helper is defined"),
    ("orphan_id, orphan_branch, orphan_age = orphaned_queued_marker()", "main() calls the detector each loop"),
    ('kind="gate-orphan"', "gate-orphan repair is dispatched"),
    ("ORPHAN_DRAIN_FRESH_SEC", "drain-freshness guard constant present"),
]:
    if needle in src:
        ok(desc)
    else:
        bad("MISSING: %s (needle %r)" % (desc, needle))

print("")
print("Results: %d passed, %d failed" % (PASS, FAIL))
if FAIL == 0:
    print("SELFTEST PASS"); sys.exit(0)
print("SELFTEST FAIL"); sys.exit(1)
PY
