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
import sys, importlib.util, datetime, time, tempfile, os

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

# ── Scenario 9b: _queued_markers() excludes a closed marker with a stale label ──
# (ga-huke4: a marker closed via the ad-hoc withdrawal path — e.g. "WITHDRAWN as
# duplicate" — often keeps its gate-status:queued label; --all (needed to reveal
# the gate-marker type at all) must not let that stale label make a dead marker
# look like a live one to _detect_orphan_markers.)
print("Scenario 9b: _queued_markers() filters out a closed marker with a stale gate-status:queued label")
def _fake_sh_rows(rows):
    class _R:
        def __init__(self):
            self.returncode = 0
            self.stdout = m.json.dumps(rows)
    def _inner(args, timeout=25, stdin=None):
        return _R()
    return _inner
_real_sh_qm = m.sh
m.sh = _fake_sh_rows([
    {"id": "ga-wisp-open", "status": "open",
     "labels": ["type:quality-gate-marker", "gate-status:queued", "branch:crew/wa/wa-open"],
     "created_at": "2026-07-16T00:00:00Z"},
    {"id": "ga-wisp-withdrawn", "status": "closed",
     "labels": ["type:quality-gate-marker", "gate-status:queued", "branch:crew/wa/wa-withdrawn"],
     "created_at": "2026-06-30T00:48:57Z"},
])
qm_ids = [q[0] for q in m._queued_markers()]
m.sh = _real_sh_qm
if qm_ids == ["ga-wisp-open"]:
    ok("closed marker excluded even though it still carries the gate-status:queued label")
else:
    bad("expected only ['ga-wisp-open'], got %r — closed/withdrawn marker leaked through" % (qm_ids,))

# ── Drift guard: the live script actually wires the detector in ──────────────
print("Scenario 10: drift-guard — detector defined and wired into main()")
src = open(wd_path).read()
for needle, desc in [
    ("def orphaned_queued_marker(", "public orphaned_queued_marker() is defined"),
    ("def _detect_orphan_markers(", "pure _detect_orphan_markers() is defined"),
    ("def _iso_epoch(", "_iso_epoch() helper is defined"),
    ("orphan_id, orphan_branch, orphan_age = orphaned_queued_marker()", "main() calls the detector each loop"),
    ('"gate-orphan", orphan_branch', "gate-orphan repair is dispatched"),  # ga: needle updated to the governed_spawn refactor (was stale kind="gate-orphan")
    ("ORPHAN_DRAIN_FRESH_SEC", "drain-freshness guard constant present"),
    # direct self-heal (the two manual toils) — defined + wired into main()
    ("def hung_run_verdict(", "FIX1 pure reap decision is defined"),
    ("def reap_hung_runs(", "FIX1 reap_hung_runs() driver is defined"),
    ("def error_requeue_verdict(", "FIX2 pure requeue decision is defined"),
    ("def requeue_error_markers(", "FIX2 requeue_error_markers() driver is defined"),
    ("reap_hung_runs(sessions, now, rstate)", "main() reaps hung reviewers each loop"),
    ("requeue_error_markers(now, rstate)", "main() requeues stuck error markers each loop"),
    ("def set_gate_status_py(", "canonical gate-status transition helper is defined"),
    # ga-m1o5: Pilot-silence sleep/wake grace (ports daemon-presence-watchdog.sh's DPW_WAKE_GRACE)
    ("def secs_since_avail(", "secs_since_avail() boottime/waketime helper is defined"),
    ("def pilot_stall_verdict(", "pure pilot_stall_verdict() decision is defined"),
    ("GRW_WAKE_GRACE", "GRW_WAKE_GRACE opt-out constant is present"),
    ("pilot_stall_verdict(now - mtime, secs_since_avail(now), PILOT_STALL_SEC, GRW_WAKE_GRACE)",
     "pilot_jammed() actually wires the grace-aware verdict in (not just defined-but-unused)"),
]:
    if needle in src:
        ok(desc)
    else:
        bad("MISSING: %s (needle %r)" % (desc, needle))

# ═══ DIRECT SELF-HEAL — the two toils the Mayor fixed by hand (pure decisions) ═══
HANG = m.REVIEW_HANG_MINUTES * 60

# ── Scenario 11 (FIX1 i): a genuinely HUNG run is reaped ──────────────────────
print("Scenario 11 (FIX1 i): old run + 0 verdicts + dead reviewer sustained → reap + (marker re-queued)")
if m.hung_run_verdict(HANG + 1800, HANG, 3, 0, False, 0) == "reap":
    ok("age>threshold, real review run (3 verdict beads), 0 delivered, reviewer inactive both samples → reap")
else:
    bad("expected reap, got %r" % (m.hung_run_verdict(HANG + 1800, HANG, 3, 0, False, 0),))

# ── Scenario 12 (FIX1 ii): a genuinely-working / slow review is NEVER reaped ──
print("Scenario 12 (FIX1 ii): a working-or-slow review is fail-safe KEPT (6 ways)")
keep_cases = [
    ("young",            m.hung_run_verdict(HANG - 60,   HANG, 3, 0, False, 0), "skip:young"),
    ("reviewer-active",  m.hung_run_verdict(HANG + 1800, HANG, 3, 0, True,  0), "skip:reviewer-active"),
    ("producing",        m.hung_run_verdict(HANG + 1800, HANG, 3, 1, False, 0), "skip:producing"),
    ("verdict-landed",   m.hung_run_verdict(HANG + 1800, HANG, 3, 0, False, 1), "skip:verdict-landed"),
    ("liveness-unknown", m.hung_run_verdict(HANG + 1800, HANG, 3, 0, None,  0), "skip:liveness-unknown"),
    ("tracking-run",     m.hung_run_verdict(HANG + 1800, HANG, 0, 0, False, 0), "skip:not-a-review-run"),
]
_all = True
for name, got, want in keep_cases:
    if got != want:
        _all = False; bad("keep case %s: got %r want %r" % (name, got, want))
if _all:
    ok("slow/working review NEVER reaped: young, reviewer-active, producing, verdict-landed, liveness-unknown, guard-tracking-run all → skip")

# ── Scenario 13 (FIX2 iii): stuck error marker, branch unmerged → requeue ─────
ETH = m.ERROR_REQUEUE_MINUTES * 60
KMAX = m.ERROR_REQUEUE_MAX_ATTEMPTS
print("Scenario 13 (FIX2 iii): error>threshold, source bead OPEN (branch unmerged), under cap → requeue")
if m.error_requeue_verdict(ETH + 600, ETH, True, False, False, 0, KMAX) == "requeue":
    ok("old error marker whose source bead is still open → error→queued requeue")
else:
    bad("expected requeue, got %r" % (m.error_requeue_verdict(ETH + 600, ETH, True, False, False, 0, KMAX),))
if m.error_requeue_verdict(ETH + 600, ETH, False, False, False, 0, KMAX) == "requeue":
    ok("unresolved source (rig bead unreadable) fails toward recovery → requeue (dispatcher re-validates)")
else:
    bad("expected requeue for unresolved source")

# ── Scenario 14 (FIX2 iv): error marker whose source bead is CLOSED → close ───
print("Scenario 14 (FIX2 iv): source bead CLOSED (merged/abandoned) → close marker, NOT requeue")
if m.error_requeue_verdict(ETH + 600, ETH, True, True, False, 0, KMAX) == "close:source-done":
    ok("done marker (closed source bead) is closed, never re-queued")
else:
    bad("expected close:source-done, got %r" % (m.error_requeue_verdict(ETH + 600, ETH, True, True, False, 0, KMAX),))
if m.error_requeue_verdict(30, ETH, True, True, False, 0, KMAX) == "close:source-done":
    ok("closed source short-circuits BEFORE the age gate — a done marker closes immediately, doesn't wait")
else:
    bad("expected close:source-done for young+closed")

# ── Scenario 15 (FIX2 v): oscillating marker (K re-errors) → escalate ─────────
print("Scenario 15 (FIX2 v): marker re-errored ERROR_REQUEUE_MAX_ATTEMPTS times → escalate, NOT infinite requeue")
if m.error_requeue_verdict(ETH + 600, ETH, True, False, False, KMAX, KMAX) == "escalate:oscillating":
    ok("at the requeue cap the marker escalates to the Mayor instead of looping forever")
else:
    bad("expected escalate:oscillating, got %r" % (m.error_requeue_verdict(ETH + 600, ETH, True, False, False, KMAX, KMAX),))
if m.error_requeue_verdict(ETH + 600, ETH, True, False, True, 0, KMAX) == "skip:parked-needs-human":
    ok("a ga-acb needs-human parked marker is left for the human, never requeued")
else:
    bad("expected skip:parked-needs-human")

# ═══ ga-m1o5: Pilot-silence sleep/wake grace ══════════════════════════════════
# Incident ga-me4x: a machine sleep spanning the 40min PILOT_STALL_SEC threshold
# made pilot-dispatcher.log look "silent >40min" and triggered an unnecessary
# repair-dog dispatch, even though Pilot self-resumed and was never actually
# dead. daemon-presence-watchdog.sh already suppresses this exact shape for its
# heartbeat-WEDGE check (DPW_WAKE_GRACE / _secs_since_avail); these scenarios
# pin the ported equivalent here.

class _FakeResult:
    def __init__(self, returncode, stdout):
        self.returncode = returncode
        self.stdout = stdout

def _fake_sh(responses):
    """Stand-in for m.sh() keyed on the last arg (the sysctl key). Missing
    keys behave like a failed sysctl call (returncode=1), matching how
    secs_since_avail() treats any sh() failure — `continue` past that key."""
    def _inner(args, timeout=20, stdin=None):
        key = args[-1] if args else None
        if key in responses:
            rc, out = responses[key]
            return _FakeResult(rc, out)
        return _FakeResult(1, "")
    return _inner

_real_sh = m.sh

# ── Scenario 16: secs_since_avail() — sysctl 'sec' parsing (mirrors DPW bash Scenario 7e) ──
print("Scenario 16: secs_since_avail() — boottime/waketime sysctl parsing")
m.sh = _fake_sh({
    "kern.boottime": (0, "{ sec = 1000000000, usec = 999999 } Fake Boot Date"),
    "kern.waketime": (0, "{ sec = 0, usec = 0 } Thu Jan  1 00:00:00 1970"),
})
av = m.secs_since_avail(1000000500)
if av == 500:
    ok("parses the 'sec' field (not the usec collision) and ignores unpopulated waketime=0")
else:
    bad("mis-parsed boottime (got %r; expected 500 — usec-collision regex regression?)" % (av,))

m.sh = _fake_sh({
    "kern.boottime": (0, "{ sec = 1000000000, usec = 0 }"),
    "kern.waketime": (0, "{ sec = 1000000400, usec = 0 }"),  # later epoch (Intel-style sleep)
})
av2 = m.secs_since_avail(1000000900)
if av2 == 500:
    ok("takes MAX(boottime, waketime) — the later (more-recently-available) epoch wins")
else:
    bad("expected 500 (now - max epoch), got %r" % (av2,))

m.sh = _fake_sh({})  # both sysctls fail/unparseable
av3 = m.secs_since_avail(1000000900)
if av3 is None:
    ok("returns None when neither sysctl parses (fail-OPEN contract for the caller)")
else:
    bad("expected None when both sysctls fail, got %r" % (av3,))
m.sh = _real_sh

# ── Scenario 17: pilot_stall_verdict() — pure grace decision ─────────────────
print("Scenario 17: pilot_stall_verdict() — wake/boot grace suppresses ONLY a sleep-explained silence")
TH = m.PILOT_STALL_SEC
if m.pilot_stall_verdict(TH - 1, 50, TH, True) == False:
    ok("silence under threshold → never a stall, regardless of avail_age")
else:
    bad("expected False for silence <= threshold")

if m.pilot_stall_verdict(TH + 600, None, TH, True) == True:
    ok("avail_age unknown (neither sysctl parsed) fails OPEN — judged on silence alone")
else:
    bad("expected True when avail_age_sec is None (fail-open)")

if m.pilot_stall_verdict(TH + 600, 100, TH, True) == False:
    ok("recent wake/boot (avail_age < threshold) fully explains the silence → suppressed (the ga-m1o5 fix)")
else:
    bad("REGRESSION ga-m1o5: recent-wake case not suppressed — false-positive dispatch would recur")

if m.pilot_stall_verdict(TH + 600, TH + 1, TH, True) == True:
    ok("machine long since up (avail_age >= threshold) → silence is a REAL stall, still fires")
else:
    bad("expected True when avail_age_sec >= threshold (genuine stall must still fire)")

if m.pilot_stall_verdict(TH + 600, 100, TH, False) == True:
    ok("GRW_WAKE_GRACE=0 (wake_grace=False) reverts to legacy behaviour — fires even right after wake")
else:
    bad("expected True with wake_grace=False (explicit opt-out)")

# ── Scenario 18: pilot_jammed() end-to-end — replays the ga-me4x incident shape ──
print("Scenario 18: pilot_jammed() end-to-end — recent wake fully explains a stale pilot log")
_tmp_log = tempfile.NamedTemporaryFile(delete=False)
_tmp_log.close()
_stale_mtime = time.time() - (m.PILOT_STALL_SEC + 600)  # log silent > threshold
os.utime(_tmp_log.name, (_stale_mtime, _stale_mtime))

_real_pilot_log = m.PILOT_LOG
m.PILOT_LOG = _tmp_log.name
try:
    m.sh = _fake_sh({"kern.boottime": (0, "{ sec = %d, usec = 0 }" % int(time.time() - 100))})  # woke 100s ago
    jammed, reason = m.pilot_jammed()
    if jammed == False:
        ok("stale pilot log right after a machine wake is NOT reported jammed (ga-me4x false-positive fixed)")
    else:
        bad("REGRESSION ga-m1o5: pilot_jammed() fired on a sleep-explained stale log: %r" % (reason,))

    # Same stale log, but the machine has been up far longer than the threshold → genuine stall.
    m.sh = _fake_sh({"kern.boottime": (0, "{ sec = %d, usec = 0 }" % int(time.time() - (m.PILOT_STALL_SEC * 3)))})
    jammed2, reason2 = m.pilot_jammed()
    if jammed2 == True and "silencioso" in reason2:
        ok("same stale log but machine long-since up → genuinely jammed, still detected")
    else:
        bad("expected a genuine stall to still fire when avail_age >= threshold, got jammed=%r reason=%r" % (jammed2, reason2))
finally:
    m.PILOT_LOG = _real_pilot_log
    m.sh = _real_sh
    os.unlink(_tmp_log.name)

print("")
print("Results: %d passed, %d failed" % (PASS, FAIL))
if FAIL == 0:
    print("SELFTEST PASS"); sys.exit(0)
print("SELFTEST FAIL"); sys.exit(1)
PY
