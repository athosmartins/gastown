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
    ("reap_hung_runs(sessions, now, rstate, open_running_runs)", "main() reaps hung reviewers each loop"),  # ga-dr1g9: needle updated for ga-7e7a's open_running_runs dedup param (was stale 3-arg form)
    ("requeue_error_markers(now, rstate)", "main() requeues stuck error markers each loop"),
    ("def set_gate_status_py(", "canonical gate-status transition helper is defined"),
    # ga-m1o5: Pilot-silence sleep/wake grace (ports daemon-presence-watchdog.sh's DPW_WAKE_GRACE)
    ("def secs_since_avail(", "secs_since_avail() boottime/waketime helper is defined"),
    ("def pilot_stall_verdict(", "pure pilot_stall_verdict() decision is defined"),
    ("GRW_WAKE_GRACE", "GRW_WAKE_GRACE opt-out constant is present"),
    ("pilot_stall_verdict(now - mtime, secs_since_avail(now), PILOT_STALL_SEC, GRW_WAKE_GRACE)",
     "pilot_jammed() actually wires the grace-aware verdict in (not just defined-but-unused)"),
    # FIX9 (ga-7b19e): needs-rebase silent-park recovery — defined + wired into main()
    ("def needs_rebase_verdict(", "FIX9 pure needs-rebase decision is defined"),
    ("def recover_needs_rebase_markers(", "FIX9 recover_needs_rebase_markers() driver is defined"),
    ("recover_needs_rebase_markers(now, rstate)", "main() recovers/escalates needs-rebase markers each loop"),
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
print("Scenario 14 (FIX2 iv): source bead CLOSED + branch VERIFIED merged/absent → close marker, NOT requeue")
if m.error_requeue_verdict(ETH + 600, ETH, True, True, False, 0, KMAX, "merged") == "close:source-done":
    ok("done marker (closed source bead, branch MERGED) is closed, never re-queued")
else:
    bad("expected close:source-done, got %r" % (m.error_requeue_verdict(ETH + 600, ETH, True, True, False, 0, KMAX, "merged"),))
if m.error_requeue_verdict(30, ETH, True, True, False, 0, KMAX, "merged") == "close:source-done":
    ok("closed source + branch MERGED short-circuits BEFORE the age gate — a done marker closes immediately, doesn't wait")
else:
    bad("expected close:source-done for young+closed+merged")
if m.error_requeue_verdict(ETH + 600, ETH, True, True, False, 0, KMAX, "missing") == "close:source-done":
    ok("done marker (closed source bead, branch MISSING/abandoned) is also closed — same as merged")
else:
    bad("expected close:source-done for closed+missing, got %r" % (m.error_requeue_verdict(ETH + 600, ETH, True, True, False, 0, KMAX, "missing"),))

# ── Scenario 14b (FIX2 iv, ga-hckn3): closed source ALONE does NOT prove done ──
# The ga-w5agg/ga-d2jil bug class, ported here from FIX 4's orphan_marker_verdict via
# ga-gd706's FIX 7 hardening: the normal dog-self-closes-its-sling-bead-on-submission
# doctrine closes the source bead immediately after /gate-done, regardless of whether a
# reviewer ever ran — so "source closed" alone is common, not rare, and must NEVER
# false-close a marker whose branch never actually landed.
print("Scenario 14b (FIX2 iv, ga-hckn3): source CLOSED but branch UNMERGED/UNKNOWN → NEVER close, falls through")
if m.error_requeue_verdict(ETH + 600, ETH, True, True, False, 0, KMAX, "unmerged") == "requeue":
    ok("closed source + branch UNMERGED (real stranding) → falls through to requeue, NEVER false-close")
else:
    bad("expected requeue for closed+unmerged (must NOT false-close), got %r" % (m.error_requeue_verdict(ETH + 600, ETH, True, True, False, 0, KMAX, "unmerged"),))
if m.error_requeue_verdict(ETH + 600, ETH, True, True, False, 0, KMAX, "unknown") == "requeue":
    ok("closed source + branch state UNKNOWN (git check couldn't verify) → falls through to requeue, fail-safe")
else:
    bad("expected requeue for closed+unknown (fail-safe), got %r" % (m.error_requeue_verdict(ETH + 600, ETH, True, True, False, 0, KMAX, "unknown"),))
if m.error_requeue_verdict(ETH + 600, ETH, True, True, False, 0, KMAX) == "requeue":
    ok("branch_state omitted defaults to 'unknown' — never close-as-done without explicit verification")
else:
    bad("expected requeue when branch_state omitted (default must be fail-safe), got %r" % (m.error_requeue_verdict(ETH + 600, ETH, True, True, False, 0, KMAX),))

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

# ═══ ga-gd706: FIX 7's close:source-done branch gains a branch_state guard ════
# RAIZ: deferred_requeue_verdict()'s close:source-done fired purely off
# (source_resolved AND source_closed) — but the NORMAL dog-self-closes-its-own-
# sling-bead-on-submission doctrine closes the branch-embedded source bead
# immediately after /gate-done, regardless of whether a reviewer ever ran. A
# marker only REACHES gate-status:deferred because authorship couldn't be
# verified in the first place (guard.sh Step 5) — so "source closed" is the
# COMMON case here, not a rare one, and closing on it alone silently stranded
# every multi-attempt gate-fix cycle whose branch-embedded bead got
# force-reclaimed (assignee nulled) mid-cycle: the deferred marker got closed
# as "superseded", which reads as routine cleanup, while the branch itself
# never merged. Same discipline FIX 4's orphan_marker_verdict already applies
# (ga-w5agg/ga-d2jil) — branch_state is the truth, a closed source is not.
DTH = m.DEFERRED_REQUEUE_MINUTES * 60
DMAX = m.DEFERRED_REQUEUE_MAX_ATTEMPTS

print("Scenario 19 (ga-gd706 i): source CLOSED but branch UNMERGED (real stranding) → NOT closed")
v = m.deferred_requeue_verdict(DTH + 600, DTH, True, True, False, True, 0, DMAX, branch_state="unmerged")
if v == "requeue":
    ok("closed source + unmerged branch + derivable author → requeue (give the dispatcher a real shot), never silently superseded")
else:
    bad("REGRESSION ga-gd706: expected requeue for closed-source/unmerged-branch, got %r" % (v,))

print("Scenario 20 (ga-gd706 ii): source CLOSED, branch UNMERGED, author NOT derivable, cap exhausted → LOUD close, never silent")
v = m.deferred_requeue_verdict(DTH + 600, DTH, True, True, False, False, DMAX, DMAX, branch_state="unmerged")
if v == "close:unresolvable":
    ok("still terminates (doesn't rot forever) but via the LOUD, explicit close:unresolvable path — not the silent close:source-done")
else:
    bad("expected close:unresolvable, got %r" % (v,))

print("Scenario 21 (ga-gd706 iii): source CLOSED, branch_state UNKNOWN (git check failed) → fail-safe, NOT closed")
v = m.deferred_requeue_verdict(DTH + 600, DTH, True, True, False, True, 0, DMAX, branch_state="unknown")
if v == "requeue":
    ok("can't verify branch state → never treat as done (fail-safe), falls through to normal resolvable handling")
else:
    bad("expected requeue (fail-safe fallthrough) for unknown branch_state, got %r" % (v,))

print("Scenario 22 (ga-gd706 iv): source CLOSED and branch actually MERGED → close:source-done (unchanged happy path)")
v = m.deferred_requeue_verdict(DTH + 600, DTH, True, True, False, True, 0, DMAX, branch_state="merged")
if v == "close:source-done":
    ok("genuinely landed work still closes normally — the fix doesn't block the true-done case")
else:
    bad("REGRESSION: expected close:source-done when branch is actually merged, got %r" % (v,))

print("Scenario 22b (ga-gd706 iv-b): closed+merged still short-circuits BEFORE the age gate (unchanged FIX7 ordering)")
v = m.deferred_requeue_verdict(30, DTH, True, True, False, True, 0, DMAX, branch_state="merged")
if v == "close:source-done":
    ok("young+closed+merged still closes immediately — the branch_state guard doesn't disturb the existing closed-before-age ordering")
else:
    bad("REGRESSION: closed+merged should short-circuit before the age gate regardless of age, got %r" % (v,))

print("Scenario 23 (ga-gd706 v): source CLOSED and branch MISSING (deleted/renamed) → close:source-done (abandoned)")
v = m.deferred_requeue_verdict(DTH + 600, DTH, True, True, False, True, 0, DMAX, branch_state="missing")
if v == "close:source-done":
    ok("no branch left to ever review → safe to close as abandoned")
else:
    bad("expected close:source-done for a missing branch, got %r" % (v,))

print("Scenario 24 (ga-gd706 vi): omitting branch_state defaults to 'unknown' — fail-safe, never a silent close-by-omission")
v = m.deferred_requeue_verdict(DTH + 600, DTH, True, True, False, True, 0, DMAX)
if v == "requeue":
    ok("callers that forget to pass branch_state get the fail-safe default, not the old silent-close behavior")
else:
    bad("expected requeue when branch_state is omitted (safe default), got %r" % (v,))

# ── Drift guard: the wiring actually computes and passes branch_state ────────
print("Scenario 25 (ga-gd706 vii): requeue_deferred_markers() wiring computes branch_state before trusting a closed source")
if 'branch_state = _branch_merged_state(branch, rig_name) if (resolved and sclosed) else "unknown"' in src:
    ok("wiring gates the git-ancestry check the same lazy way FIX 4 does (only when resolved+closed)")
else:
    bad("MISSING: requeue_deferred_markers does not compute branch_state — the pure-function fix is unreachable from the real sweep")
if ("def requeue_deferred_markers(" in src
        and "DEFERRED_REQUEUE_MAX_ATTEMPTS, branch_state)" in src):
    ok("branch_state is actually threaded into the deferred_requeue_verdict() call, not just computed and dropped")
else:
    bad("MISSING: branch_state computed but not passed into deferred_requeue_verdict()")

# ═══ ga-5t5w: FIX5 stranded-verdict recovery anchored on LAST-VERDICT time ════
# RAIZ: reap_stranded_verdict_runs anchored its age on the RUN's created_at instead
# of the LAST VERDICT's delivered_at. A slow-but-healthy review and a genuinely
# wedged finalize both keep a run open a long time; only recency of the last
# verdict tells them apart. Measuring from run-creation made a 16-minute (healthy)
# review indistinguishable from a dead finalizer and discarded 11 COMPLETE,
# delivered verdicts in a single day (4 escalated to a human). These scenarios
# pin the PURE stranded_verdict_verdict() contract, the _run_verdicts() data
# plumbing that derives the new anchor from real bd rows, and a drift-guard that
# the caller is actually wired to the new anchor (not silently reverted).
SRM = m.STRANDED_RUN_MINUTES * 60

# ── Scenario 15b (FIX5 i): all verdicts in, stale since last delivery → recover ──
print("Scenario 15b (FIX5 i): verdicts complete, stale since LAST delivery → recover")
if m.stranded_verdict_verdict(SRM + 300, SRM, 3, 3) == "recover":
    ok("total>=1, delivered==total, age(since last verdict)>=threshold → recover")
else:
    bad("expected recover, got %r" % (m.stranded_verdict_verdict(SRM + 300, SRM, 3, 3),))

# ── Scenario 15c (FIX5 ii): fail-safe skips ───────────────────────────────────
print("Scenario 15c (FIX5 ii): every ambiguous/incomplete case is fail-safe SKIPPED")
skip_cases = [
    ("query-failed",        m.stranded_verdict_verdict(SRM + 300, SRM, -1, -1),   "skip:query-failed"),
    ("not-a-run",           m.stranded_verdict_verdict(SRM + 300, SRM, 0, 0),     "skip:not-a-run"),
    ("collecting",          m.stranded_verdict_verdict(SRM + 300, SRM, 1, 3),     "skip:collecting"),
    ("verdict-time-unknown",m.stranded_verdict_verdict(None,     SRM, 3, 3),      "skip:verdict-time-unknown"),
    ("young",               m.stranded_verdict_verdict(SRM - 60, SRM, 3, 3),      "skip:young"),
]
_all5c = True
for name, got, want in skip_cases:
    if got != want:
        _all5c = False; bad("skip case %s: got %r want %r" % (name, got, want))
if _all5c:
    ok("query-failed, not-a-run, collecting, verdict-time-unknown, young all → skip (never act ambiguously)")

# ── Scenario 15d (THE mutation, ga-5t5w core fix): old RUN, fresh VERDICT ─────
# The exact incident shape: a review takes 20 minutes (run age = 20m) but the
# reviewer finished ON TIME and the last verdict landed just 1 minute ago. Anchor
# on the RUN's age (the bug) → wrongly "recover" (discards a live finalize-in-
# progress). Anchor on the LAST VERDICT's age (the fix) → correctly "skip:young".
print("Scenario 15d (THE mutation, ga-5t5w): run=20m old, last verdict delivered 1m ago")
RUN_AGE_SEC = 20 * 60
VERDICT_AGE_SEC = 60
buggy_anchor_verdict = m.stranded_verdict_verdict(RUN_AGE_SEC, SRM, 3, 3)      # what the OLD code effectively asked
fixed_anchor_verdict = m.stranded_verdict_verdict(VERDICT_AGE_SEC, SRM, 3, 3)  # what the NEW code asks
if fixed_anchor_verdict == "skip:young":
    ok("anchored on last-verdict-delivered (1m ago) → skip:young — the dispatcher still gets its chance to finalize")
else:
    bad("REGRESSION ga-5t5w: verdict-anchored age wrongly returned %r (want skip:young) — "
        "a just-finished healthy review would be superseded again" % (fixed_anchor_verdict,))
if buggy_anchor_verdict == "recover":
    ok("(confirms the OLD run-creation anchor WOULD have wrongly fired 'recover' here — this is exactly the bug)")
else:
    bad("expected the OLD anchor to demonstrate 'recover' for contrast, got %r — mutation control invalid" % (buggy_anchor_verdict,))

# ── Scenario 15e (regression guard): a GENUINELY stranded run is still recovered ──
# Verdicts complete 10 minutes ago (well past the new 5min default) and the run
# itself might be arbitrarily old or young — recovery must still fire; the fix
# must never overcorrect into "nothing is ever recovered".
print("Scenario 15e (regression): verdicts complete 10m ago, dispatcher dead → STILL recovered")
if m.stranded_verdict_verdict(10 * 60, SRM, 2, 2) == "recover":
    ok("a truly stale, fully-delivered run is still recovered under the new anchor (no false 'always skip')")
else:
    bad("REGRESSION: genuinely stranded run (10m since last verdict) not recovered, got %r"
        % (m.stranded_verdict_verdict(10 * 60, SRM, 2, 2),))

# ── Scenario 15f: _run_verdicts() derives last_delivered_epoch from CLOSED rows'
#    updated_at (the MAX among them), never from an open/pending row ──────────
print("Scenario 15f: _run_verdicts() last_delivered_epoch = newest updated_at among CLOSED verdict beads")
def _fake_sh_verdicts(rows):
    class _R:
        def __init__(self):
            self.returncode = 0
            self.stdout = m.json.dumps(rows)
    def _inner(args, timeout=25, stdin=None):
        return _R()
    return _inner
_real_sh_rv = m.sh
m.sh = _fake_sh_verdicts([
    {"id": "v1", "assignee": "gate-reviewer-a", "status": "closed", "updated_at": "2026-07-17T09:00:00Z"},
    {"id": "v2", "assignee": "gate-reviewer-b", "status": "closed", "updated_at": "2026-07-17T09:05:00Z"},
    {"id": "v3", "assignee": "gate-reviewer-c", "status": "open",   "updated_at": "2026-07-17T09:59:59Z"},
])
names, delivered, total, last_delivered = m._run_verdicts("ga-wisp-fake")
m.sh = _real_sh_rv
want_epoch = m._iso_epoch("2026-07-17T09:05:00Z")
if delivered == 2 and total == 3 and last_delivered == want_epoch:
    ok("2/3 delivered; last_delivered_epoch is the newer CLOSED row's updated_at (09:05), ignoring the still-open row's later timestamp")
else:
    bad("expected (delivered=2, total=3, last_delivered=%r), got (delivered=%r, total=%r, last_delivered=%r)"
        % (want_epoch, delivered, total, last_delivered))

# ── Scenario 15g: drift-guard — the caller is actually wired to the new anchor ──
print("Scenario 15g: drift-guard — reap_stranded_verdict_runs anchors on _run_verdicts' 4th value, not run started_at")
src2 = open(wd_path).read()
import re as _re_dg
fn_match = _re_dg.search(r"def reap_stranded_verdict_runs\(now, open_running_runs\):.*?(?=\ndef )", src2, _re_dg.S)  # ga-dr1g9: signature gained open_running_runs (ga-7e7a dedup); was stale \(now\)-only pattern
if not fn_match:
    bad("could not isolate reap_stranded_verdict_runs() body for drift-guard scan")
else:
    body = fn_match.group(0)
    for needle, desc in [
        ("_run_verdicts(rid)", "calls _run_verdicts for the primary sample"),
        ("last_delivered", "binds the 4th (last-delivered-epoch) return value"),
        ("stranded_verdict_verdict(age", "feeds the derived age into the pure decision function"),
    ]:
        if needle in body:
            ok(desc)
        else:
            bad("MISSING in reap_stranded_verdict_runs(): %s (needle %r)" % (desc, needle))
    if '_parse_run_field(desc, "started_at")' in body:
        bad("REGRESSION ga-5t5w: reap_stranded_verdict_runs() reads started_at again — "
            "the run-creation anchor is back, the original bug has returned")
    else:
        ok("no reference to started_at — the run-creation anchor was fully removed from FIX5's age computation")

# ═══ ga-m1o5: Pilot-silence sleep/wake grace ══════════════════════════════════
# Incident ga-me4x: a machine sleep spanning the 40min PILOT_STALL_SEC threshold
# made pilot-dispatcher.log look "silent >40min" and triggered an unnecessary
# repair-dog dispatch, even though Pilot self-resumed and was never actually
# dead. daemon-presence-watchdog.sh already suppresses this exact shape for its
# heartbeat-WEDGE check (DPW_WAKE_GRACE / _secs_since_avail); these scenarios
# pin the ported equivalent here.

class _FakeResult:
    def __init__(self, returncode, stdout, stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr

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

# ═══ ga-42nfj: reap_frozen_reviewers() must not kill a session blocked on a REAL ═══
# ═══ permission-prompt dialog (same bug class as ga-lxk26, different mechanism) ═══
# FIX 3 kills any gate-reviewer session that reads state=active but has been silent
# past FROZEN_KILL_SECS — with no check for whether that silence is a wedged Claude
# (the case it exists to fix) or a reviewer sitting at a permission dialog waiting on
# a human keypress. Killing a session blocked on a real dialog destroys the evidence
# and never even asks (ga-lxk26 fixed the analogous gap in agent-stuck-escalation.sh's
# separate stall path; this is the DIFFERENT mechanism the fix's own follow-up noted).

print("Scenario ga-42nfj-1: pane_shows_permission_prompt() — FAIL-CLOSED contract")

def _fake_sh_peek(rc, out):
    def _inner(args, timeout=20, stdin=None):
        return _FakeResult(rc, out)
    return _inner

_real_sh_pp = m.sh

m.sh = _fake_sh_peek(0, "Permission rule Bash(rm -rf:*) requires confirmation for this command.\nDo you want to proceed?\n1. Yes\n2. Yes, and don't ask again\n3. No")
if m.pane_shows_permission_prompt("any-sid") is True:
    ok("confirmed dialog ('Do you want to proceed?') in the tail -> True")
else:
    bad("expected True for a confirmed dialog in the tail")

m.sh = _fake_sh_peek(0, "some tool is blocked and this action requires confirmation before it can continue")
if m.pane_shows_permission_prompt("any-sid") is True:
    ok("'requires confirmation' alone in the tail -> True")
else:
    bad("expected True for 'requires confirmation' in the tail")

m.sh = _fake_sh_peek(0, "Reading file foo.py...\nWriting file bar.py...\nRunning tests...\nAll green.")
if m.pane_shows_permission_prompt("any-sid") is False:
    ok("normal reviewer output, no dialog signature -> False")
else:
    bad("REGRESSION: normal output false-flagged as a permission prompt")

_stale_lines = ["Do you want to proceed?"] + ["normal output line %d" % i for i in range(20)]
m.sh = _fake_sh_peek(0, "\n".join(_stale_lines))
if m.pane_shows_permission_prompt("any-sid") is False:
    ok("dialog phrase present but pushed out of the last-12-line tail (old scrollback) -> False (not a currently-open dialog)")
else:
    bad("REGRESSION: matched a stale scrollback mention outside the tail window -- would false-positive on e.g. an agent discussing this very check")

m.sh = _fake_sh_peek(1, "")
if m.pane_shows_permission_prompt("any-sid") is False:
    ok("peek command fails (non-zero rc) -> False (fail-closed, never blocks a legitimate kill on a read error)")
else:
    bad("expected False when the peek command itself fails")

m.sh = _fake_sh_peek(0, "")
if m.pane_shows_permission_prompt("any-sid") is False:
    ok("empty peek output -> False (fail-closed)")
else:
    bad("expected False for empty peek output")

def _fake_sh_none(args, timeout=20, stdin=None):
    return None
m.sh = _fake_sh_none
if m.pane_shows_permission_prompt("any-sid") is False:
    ok("sh() itself returns None (gc unreachable) -> False (fail-closed)")
else:
    bad("expected False when sh() returns None")

m.sh = _real_sh_pp

print("Scenario ga-42nfj-2: reap_frozen_reviewers() -- FIXTURE (dialog open) skipped, CONTROL (no dialog) still killed, same sweep")

NOW42 = 3_000_000.0
FROZEN_LA_42 = datetime.datetime.utcfromtimestamp(NOW42 - m.FROZEN_KILL_SECS - 120).strftime("%Y-%m-%dT%H:%M:%SZ")
FIXTURE_SID = "gate-reviewer-permblocked"
CONTROL_SID = "gate-reviewer-genuinelyfrozen"

def _mk_frozen_reviewer(sid):
    return {"id": sid, "template": "gate-reviewer", "closed": False, "state": "active", "last_active": FROZEN_LA_42}

_PANE_BY_SID = {
    FIXTURE_SID: "Permission rule Bash(rm -rf:*) requires confirmation for this command.\nDo you want to proceed?\n1. Yes\n2. Yes, and don't ask again\n3. No",
    CONTROL_SID: "Reading file foo.py...\nWriting file bar.py...\nStill thinking...",
}
_kill_calls = []
_peek_calls = []

def _fake_sh_reap(args, timeout=20, stdin=None):
    if len(args) >= 3 and args[0] == "gc" and args[1] == "session" and args[2] == "list":
        rows = [_mk_frozen_reviewer(FIXTURE_SID), _mk_frozen_reviewer(CONTROL_SID)]
        return _FakeResult(0, m.json.dumps({"sessions": rows}))
    if len(args) >= 4 and args[0] == "gc" and args[1] == "session" and args[2] == "peek":
        _peek_calls.append(args[3])
        return _FakeResult(0, _PANE_BY_SID.get(args[3], ""))
    if len(args) >= 4 and args[0] == "gc" and args[1] == "session" and args[2] == "kill":
        _kill_calls.append(args[3])
        return _FakeResult(0, "")
    return _FakeResult(0, "")

_real_sh_42 = m.sh
_real_resample_42 = m.LIVENESS_RESAMPLE_SEC
_real_reclog_42 = m.RECOVERY_LOG
_tmp_reclog_42 = tempfile.NamedTemporaryFile(delete=False, suffix=".jsonl")
_tmp_reclog_42.close()
m.RECOVERY_LOG = _tmp_reclog_42.name
try:
    m.sh = _fake_sh_reap
    m.LIVENESS_RESAMPLE_SEC = 0  # skip the real 8s SUSTAINED-confirm gap in the test
    sessions42 = [_mk_frozen_reviewer(FIXTURE_SID), _mk_frozen_reviewer(CONTROL_SID)]
    m.reap_frozen_reviewers(sessions42, NOW42, None, None)

    if FIXTURE_SID in _peek_calls and CONTROL_SID in _peek_calls:
        ok("both SUSTAINED-confirmed-frozen candidates were pane-checked before any kill decision")
    else:
        bad("expected both %r and %r to be peeked, got peek_calls=%r" % (FIXTURE_SID, CONTROL_SID, _peek_calls))

    if FIXTURE_SID not in _kill_calls:
        ok("FIXTURE (pane shows an open permission dialog) was NOT killed -- ga-42nfj fail-safe")
    else:
        bad("REGRESSION ga-42nfj: killed a reviewer session that was blocked on a real permission dialog")

    if CONTROL_SID in _kill_calls:
        ok("CONTROL (frozen, no dialog) was still killed -- the pre-existing FIX 3 behavior is unchanged")
    else:
        bad("REGRESSION: a genuinely-frozen reviewer with no permission dialog was no longer killed")

    if _kill_calls == [CONTROL_SID]:
        ok("the SAME sweep produced two DIFFERENT outcomes for the two candidates -- proves the check discriminates, not a blanket suppress")
    else:
        bad("expected kill_calls == [%r] exactly, got %r" % (CONTROL_SID, _kill_calls))

    # ── Scenario ga-42nfj-3: operator escape hatch -- toggle OFF reverts to legacy kill-on-sight ──
    print("Scenario ga-42nfj-3: GRW_FROZEN_PERMISSION_CHECK_ENABLED=False reverts to legacy kill-on-sight (operator escape hatch)")
    _kill_calls3 = []

    def _fake_sh_reap3(args, timeout=20, stdin=None):
        if len(args) >= 3 and args[0] == "gc" and args[1] == "session" and args[2] == "list":
            rows = [_mk_frozen_reviewer(FIXTURE_SID)]
            return _FakeResult(0, m.json.dumps({"sessions": rows}))
        if len(args) >= 4 and args[0] == "gc" and args[1] == "session" and args[2] == "peek":
            return _FakeResult(0, _PANE_BY_SID[FIXTURE_SID])
        if len(args) >= 4 and args[0] == "gc" and args[1] == "session" and args[2] == "kill":
            _kill_calls3.append(args[3])
            return _FakeResult(0, "")
        return _FakeResult(0, "")

    _real_toggle_43 = m.GRW_FROZEN_PERMISSION_CHECK_ENABLED
    m.sh = _fake_sh_reap3
    m.GRW_FROZEN_PERMISSION_CHECK_ENABLED = False
    try:
        m.reap_frozen_reviewers([_mk_frozen_reviewer(FIXTURE_SID)], NOW42, None, None)
    finally:
        m.GRW_FROZEN_PERMISSION_CHECK_ENABLED = _real_toggle_43

    if _kill_calls3 == [FIXTURE_SID]:
        ok("toggle OFF -> the SAME dialog-blocked session is killed exactly as pre-ga-42nfj code -- confirms the new check (not something else) gates the skip")
    else:
        bad("expected the toggle-off path to kill %r regardless of the open dialog, got kill_calls=%r" % (FIXTURE_SID, _kill_calls3))
finally:
    m.sh = _real_sh_42
    m.LIVENESS_RESAMPLE_SEC = _real_resample_42
    m.RECOVERY_LOG = _real_reclog_42
    os.unlink(_tmp_reclog_42.name)

# ── ga-o2dlg8: _close_pending_verdicts_for_run actually closes in production ──
# ga-9as9h built this reclaim step but its `bd close` call (no --force, no
# explicit actor override) refuses deterministically: the watchdog's own actor
# resolves to "automation" (BD_ACTOR in the launchd plist), which never
# matches a verdict bead's assignee (a per-session name). Confirmed live:
# every real close attempt since ga-9as9h shipped failed silently (only 4
# close_pending_verdict_on_supersede ledger events ever, all from the
# 2026-08-10 TESTCTX selftest run, zero from real production triggers) while
# the "Closing this verdict bead" comment was posted unconditionally BEFORE
# the close was even attempted — so the bead's own thread narrated success
# that never happened. These two scenarios drive the REAL function against a
# fake `bd` that reproduces the exact observed refusal (verified live via
# `env -u BEADS_ACTOR BD_ACTOR=automation bd close <id>` — see ga-o2dlg8), so
# Scenario RECLAIM-1 would FAIL against the pre-fix code (no --force in the
# close argv -> the fake refuses -> closed stays empty) and only PASSES once
# --force is present. RECLAIM-2 is the negative control: even with --force,
# an unrelated close failure (Dolt hiccup, etc.) must be reported, never
# silently claimed as success.

FIXTURE_RID = "ga-fixture-run-o2dlg8"
FIXTURE_VID = "ga-fixture-verdict-o2dlg8"

def _mk_pending_verdict_row(vid):
    return {"id": vid, "status": "in_progress", "assignee": "gate-reviewer-adhoc-fixture"}

print("Scenario RECLAIM-1: close succeeds only once --force is sent (reproduces the real actor!=assignee refusal)")
_calls_r1 = []
def _fake_sh_reclaim1(args, timeout=20, stdin=None):
    _calls_r1.append(list(args))
    if args and args[0] == "bash":
        return _FakeResult(0, m.json.dumps([_mk_pending_verdict_row(FIXTURE_VID)]))
    if "close" in args:
        if "--force" in args:
            return _FakeResult(0, "")
        return _FakeResult(1, "", 'cannot close %s: assignee is "gate-reviewer-adhoc-fixture", actor is "automation"; reclaim or use --force to override' % FIXTURE_VID)
    if "comment" in args:
        return _FakeResult(0, "")
    return _FakeResult(0, "")

_real_sh_r1 = m.sh
_real_reclog_r1 = m.RECOVERY_LOG
_tmp_reclog_r1 = tempfile.NamedTemporaryFile(delete=False, suffix=".jsonl")
_tmp_reclog_r1.close()
m.RECOVERY_LOG = _tmp_reclog_r1.name
m.sh = _fake_sh_reclaim1
m.GRW_ENABLED = True
m.GRW_SUPERSEDE_RECLAIM_VERDICTS_ENABLED = True
m.GRW_DRY_RUN = False
try:
    closed_r1 = m._close_pending_verdicts_for_run(FIXTURE_RID, "run superseded", "RECLAIM1")
finally:
    m.sh = _real_sh_r1
    ledger_r1 = [m.json.loads(l) for l in open(_tmp_reclog_r1.name) if l.strip()]
    m.RECOVERY_LOG = _real_reclog_r1
    os.unlink(_tmp_reclog_r1.name)

close_calls_r1 = [c for c in _calls_r1 if "close" in c]
comment_calls_r1 = [c for c in _calls_r1 if "comment" in c]
if len(close_calls_r1) == 1 and "--force" in close_calls_r1[0]:
    ok("close call carries --force (the real fix -- pre-fix code never sent this)")
else:
    bad("expected exactly one close call containing --force, got %r" % (close_calls_r1,))
if closed_r1 == [FIXTURE_VID]:
    ok("verdict bead reported closed after the forced close succeeded")
else:
    bad("expected closed==[%r], got %r" % (FIXTURE_VID, closed_r1))
if len(comment_calls_r1) == 1 and "Closed this verdict bead" in comment_calls_r1[0][-1]:
    ok("success comment uses past tense ('Closed', not 'Closing') and was posted")
else:
    bad("expected exactly one past-tense success comment, got %r" % (comment_calls_r1,))
if comment_calls_r1 and close_calls_r1 and _calls_r1.index(comment_calls_r1[0]) > _calls_r1.index(close_calls_r1[0]):
    ok("comment posted AFTER the close call, not before -- fixes the unconditional-announce bug")
else:
    bad("expected the comment call to occur strictly after the close call in %r" % (_calls_r1,))
success_events_r1 = [e for e in ledger_r1 if e.get("event") == "close_pending_verdict_on_supersede"]
if len(success_events_r1) == 1 and success_events_r1[0].get("verdict") == FIXTURE_VID:
    ok("ledger recorded close_pending_verdict_on_supersede for the closed bead")
else:
    bad("expected one close_pending_verdict_on_supersede ledger event for %r, got %r" % (FIXTURE_VID, ledger_r1))

print("Scenario RECLAIM-2: close fails even WITH --force (e.g. unrelated Dolt hiccup) -> reported, never silently claimed as success")
_calls_r2 = []
def _fake_sh_reclaim2(args, timeout=20, stdin=None):
    _calls_r2.append(list(args))
    if args and args[0] == "bash":
        return _FakeResult(0, m.json.dumps([_mk_pending_verdict_row(FIXTURE_VID)]))
    if "close" in args:
        return _FakeResult(1, "", "dolt: connection refused")
    if "comment" in args:
        return _FakeResult(0, "")
    return _FakeResult(0, "")

_real_sh_r2 = m.sh
_real_reclog_r2 = m.RECOVERY_LOG
_tmp_reclog_r2 = tempfile.NamedTemporaryFile(delete=False, suffix=".jsonl")
_tmp_reclog_r2.close()
m.RECOVERY_LOG = _tmp_reclog_r2.name
m.sh = _fake_sh_reclaim2
try:
    closed_r2 = m._close_pending_verdicts_for_run(FIXTURE_RID, "run superseded", "RECLAIM2")
finally:
    m.sh = _real_sh_r2
    ledger_r2 = [m.json.loads(l) for l in open(_tmp_reclog_r2.name) if l.strip()]
    m.RECOVERY_LOG = _real_reclog_r2
    os.unlink(_tmp_reclog_r2.name)

comment_calls_r2 = [c for c in _calls_r2 if "comment" in c]
if closed_r2 == []:
    ok("a real close failure does NOT get reported as closed")
else:
    bad("expected closed==[] on close failure, got %r" % (closed_r2,))
if not any("Closed this verdict bead" in c[-1] for c in comment_calls_r2):
    ok("no success comment posted when the close actually failed -- the exact ga-1pej8n regression this fix closes")
else:
    bad("posted a success comment despite the close failing: %r" % (comment_calls_r2,))
failed_events_r2 = [e for e in ledger_r2 if e.get("event") == "close_pending_verdict_on_supersede_FAILED"]
if len(failed_events_r2) == 1 and failed_events_r2[0].get("returncode") == 1 and "dolt" in failed_events_r2[0].get("stderr", ""):
    ok("ledger recorded the FAILED event with returncode+stderr for diagnosis -- symmetric with this function's existing query-failure fail-safe prints")
else:
    bad("expected one close_pending_verdict_on_supersede_FAILED ledger event with returncode/stderr, got %r" % (ledger_r2,))

print("")
print("Results: %d passed, %d failed" % (PASS, FAIL))
if FAIL == 0:
    print("SELFTEST PASS"); sys.exit(0)
print("SELFTEST FAIL"); sys.exit(1)
PY
