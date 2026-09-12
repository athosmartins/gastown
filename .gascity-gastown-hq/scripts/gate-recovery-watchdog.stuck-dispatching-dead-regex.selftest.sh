#!/usr/bin/env bash
# Selftest for gate-recovery-watchdog.py — ga-iodjh7 regression only.
#
# BUG: stuck_dispatching()'s only in-flight signal was a regex on a "Verdicts: G/N
# received (elapsed: Ys)" dispatcher-log line — the SAME format ga-z0xx1/ga-ohz0x already
# proved dead in the sibling file pipeline-throughput-heartbeat.py (identical DISPATCH_LOG,
# same historical format, confirmed zero emitting sites in quality-gate-dispatcher.sh).
# Since the regex never matches, `vm` stays None and the function unconditionally
# `return False`s — the "marker stuck dispatching w/ no reviewers" arm of the gate-down
# check in main() (ga-recovery-watchdog.py:~3888) was permanently, silently disabled.
#
# FIX: match the dispatcher's CURRENT in-flight-poll line instead — "Phase C: gate-run
# <id> (branch=<b>) still in flight (G/N verdicts, ELAPSEDs/TIMEOUTs) — leaving for a
# future sweep." (quality-gate-dispatcher.sh:~7671; verified live against the real,
# currently-running dispatcher log, 2026-09-12: a real gate-run, ga-bri9hr, was observed
# mid-flight with exactly this shape, 0/1 verdicts, elapsed climbing past 700s against a
# 1380s timeout — scenario 1 below uses those exact real numbers). New STUCK_INFLIGHT_RE
# captures the verdict-received count too (the sibling's PHASE_C_INFLIGHT_RE does not,
# since gate_merge_stall() never needs it) — this detector's "got == 0" check is central
# to its semantics (only fire on ZERO progress, not merely "slow"), so it gets its own
# pattern rather than reusing PHASE_C_INFLIGHT_RE.
#
# DELIBERATELY NOT ported from the sibling: comparing elapsed against the run's OWN
# diff-scaled timeout instead of the fixed DISPATCH_STUCK_SEC (720s) constant. That was
# the right fix in pipeline-throughput-heartbeat.py because gate_merge_stall() has no
# other corroboration and REVIEW_FRESH_SEC (2700s) was simply too small a threshold for a
# run legitimately scaled near the dispatcher's 50min/3000s cap. Here DISPATCH_STUCK_SEC
# is deliberately much SHORTER than any run's own timeout (720s vs 1200-3000s) BY DESIGN
# — its own comment calls it a "marker dispatching >12min w/ no active reviewers = spawn
# fail" grace period, not a stand-in for the full per-run budget — and stuck_dispatching()
# already has independent corroboration the sibling lacks (no active gate-reviewer
# session, checked via `gc session list`). Scenario 3 below proves that corroboration
# alone already protects a legitimately-slow-but-active run, so widening the elapsed
# threshold to the run's own (much larger) timeout would only delay real detections, not
# fix a false-positive that exists here.
#
# Exercises stuck_dispatching() end-to-end against a REAL temp file standing in for
# DISPATCH_LOG (this function reads it directly via open()/os.path.getmtime(), unlike the
# sibling's file_fresh()/tail_lines() helpers, so there is nothing to monkeypatch for the
# file-read path itself) with `sh()` (the `gc session list` subprocess wrapper) mocked so
# no real subprocess ever runs.
#
# NOT a general test harness for this file — scoped narrowly to this one bug, same
# convention as gate-recovery-watchdog.selftest.sh (gt-mqkwj) and the sibling
# pipeline-throughput-heartbeat.gate-merge-scaled-timeout.selftest.sh (ga-z0xx1).
#
# Run: bash scripts/gate-recovery-watchdog.stuck-dispatching-dead-regex.selftest.sh
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="${WD_OVERRIDE:-$SELF_DIR/gate-recovery-watchdog.py}"
[ -f "$WD" ] || { echo "FATAL: gate-recovery-watchdog.py not found at $WD"; exit 1; }

python3 - "$WD" <<'PY'
import importlib.util, sys, time, os, tempfile, subprocess, json

spec = importlib.util.spec_from_file_location("grw", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.argv = ["grw"]                      # __name__ != "__main__" → main() never runs
spec.loader.exec_module(m)

if not hasattr(m, "STUCK_INFLIGHT_RE"):
    print("FATAL: STUCK_INFLIGHT_RE not found — has ga-iodjh7 landed?", file=sys.stderr)
    sys.exit(2)

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)

NOW = time.time()   # stuck_dispatching() calls time.time() internally — no injection
                     # point exists (unlike gate_merge_stall(now=...)) — so freshness is
                     # driven via the temp file's REAL mtime, set relative to wall clock.

def ts(secs_ago):
    return time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(NOW - secs_ago))

def inflight_line(got, total, elapsed_s, timeout_s, run_id="ga-testrun", branch="crew/x/wa-1"):
    return ("%s [quality-gate-dispatcher] Phase C: gate-run %s (branch=%s) still in "
            "flight (%d/%d verdicts, %ds/%ds) — leaving for a future sweep.\n"
            % (ts(30), run_id, branch, got, total, elapsed_s, timeout_s))

def sweep_complete_line(secs_ago=10):
    return "%s [quality-gate-dispatcher] sweep complete\n" % ts(secs_ago)

class FakeCompleted:
    """Stand-in for the subprocess.CompletedProcess sh() normally returns."""
    def __init__(self, stdout):
        self.stdout = stdout

def run(lines, mtime_age_s=5, active_reviewers=0, sessions_call_fails=False):
    """Write `lines` to a REAL temp file, point m.DISPATCH_LOG at it with a controlled
    mtime, mock m.sh so no real `gc session list` subprocess runs, call
    stuck_dispatching(), then restore/clean up."""
    fd, path = tempfile.mkstemp(prefix="grw-dispatch-log-")
    try:
        with os.fdopen(fd, "w") as f:
            f.writelines(lines)
        os.utime(path, (NOW - mtime_age_s, NOW - mtime_age_s))

        orig_log, orig_sh = m.DISPATCH_LOG, m.sh
        m.DISPATCH_LOG = path

        def fake_sh(args, timeout=20, stdin=None):
            if sessions_call_fails:
                return None
            sessions = [{"template": "gate-reviewer", "state": "active"}] * active_reviewers
            return FakeCompleted(json.dumps({"sessions": sessions}))
        m.sh = fake_sh

        try:
            return m.stuck_dispatching()
        finally:
            m.DISPATCH_LOG, m.sh = orig_log, orig_sh
    finally:
        os.unlink(path)

# ── Scenario 1: the exact reported bug — dead regex fix ──────────────────────────────
# Real numbers observed live 2026-09-12 against the actual dispatcher log for a genuine
# in-flight run (ga-bri9hr): 0/1 verdicts, elapsed past DISPATCH_STUCK_SEC(720s) but well
# inside its own 1380s timeout, fresh log, no active reviewer. Must fire — this is the
# scenario that FAILS against the pre-fix code (old regex never matches → always False).
r1 = run([inflight_line(got=0, total=1, elapsed_s=800, timeout_s=1380)], active_reviewers=0)
if r1 is True:
    ok("ga-iodjh7: 0/1 verdicts past DISPATCH_STUCK_SEC, no active reviewer — now fires")
else:
    bad("ga-iodjh7 REGRESSION: still never fires on a genuinely stuck run: %r" % (r1,))

# ── Scenario 2: grace period — elapsed under DISPATCH_STUCK_SEC must NOT fire ─────────
r2 = run([inflight_line(got=0, total=1, elapsed_s=300, timeout_s=1380)], active_reviewers=0)
if r2 is False:
    ok("elapsed(300s) under DISPATCH_STUCK_SEC(720s) grace period — correctly quiet")
else:
    bad("fired too early, inside the dispatch grace period: %r" % (r2,))

# ── Scenario 3: corroboration — an active reviewer suppresses even past the threshold ─
# Same shape as Scenario 1 (would otherwise fire), but a gate-reviewer session IS active.
# Proves the existing reviewer-liveness check already covers "legitimately slow", which is
# why this fix does NOT need the sibling's run's-own-timeout comparison.
r3 = run([inflight_line(got=0, total=1, elapsed_s=800, timeout_s=1380)], active_reviewers=1)
if r3 is False:
    ok("an active gate-reviewer session suppresses the alarm (legitimately working, not stuck)")
else:
    bad("fired despite an active reviewer session — corroboration check not respected: %r" % (r3,))

# ── Scenario 4: progress guard — got > 0 must NOT fire regardless of elapsed ──────────
# This detector is specifically about ZERO progress; the sibling's PHASE_C_INFLIGHT_RE
# doesn't need this distinction, which is why STUCK_INFLIGHT_RE captures the verdict
# count and the sibling's pattern does not.
r4 = run([inflight_line(got=1, total=1, elapsed_s=5000, timeout_s=1380)], active_reviewers=0)
if r4 is False:
    ok("got=1 (a verdict arrived) never fires even at huge elapsed — not the zero-progress case")
else:
    bad("fired with a verdict already received — got==0 guard not respected: %r" % (r4,))

# ── Scenario 5: stale log file — dispatcher not actively polling, not this detector's job ─
r5 = run([inflight_line(got=0, total=1, elapsed_s=800, timeout_s=1380)],
         mtime_age_s=200, active_reviewers=0)
if r5 is False:
    ok("stale DISPATCH_LOG (mtime>120s) — correctly deferred to ENGINE-STALL, not flagged here")
else:
    bad("fired on a stale log file — the file-freshness gate was bypassed: %r" % (r5,))

# ── Scenario 6: sweep already concluded — most recent run is done, not stuck ──────────
r6 = run([inflight_line(got=0, total=1, elapsed_s=800, timeout_s=1380),
          sweep_complete_line(secs_ago=5)], active_reviewers=0)
if r6 is False:
    ok("a 'sweep complete' line after the in-flight line — correctly not stuck")
else:
    bad("fired even though the most recent line shows the sweep concluded: %r" % (r6,))

# ── Scenario 7: no in-flight evidence at all — baseline, unrelated log noise ──────────
r7 = run(["%s [quality-gate-dispatcher] Found 2 queued marker(s)\n" % ts(30)],
         active_reviewers=0)
if r7 is False:
    ok("no matching in-flight line at all — correctly quiet (vm stays None)")
else:
    bad("fired with zero in-flight evidence in the tail: %r" % (r7,))

# ── Scenario 8: session-list call itself fails — documents PRE-EXISTING fail-open ─────
# Not a new design choice from this fix: this whole tail (lines computing `active` from
# `sh()`) was UNREACHABLE before ga-iodjh7 (vm was always None), so this is the first time
# it has ever actually run. `rs=None` → `sessions=[]` → `active=[]` → returns True: the
# pre-existing code fails OPEN toward alarming when it can't corroborate, rather than
# silently swallowing a possibly-real stuck state. Documented here, not endorsed or
# changed — a future bead can revisit if this turns out wrong now that it's reachable.
r8 = run([inflight_line(got=0, total=1, elapsed_s=800, timeout_s=1380)],
         sessions_call_fails=True)
if r8 is True:
    ok("`gc session list` failure fails OPEN toward alarming (pre-existing, now reachable, behavior)")
else:
    bad("session-list failure handling changed from the pre-existing fail-open shape: %r" % (r8,))

print("")
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
rc=$?
echo ""
[ "$rc" = "0" ] && echo "SELFTEST: PASS" || echo "SELFTEST: FAIL (rc=$rc)"
exit $rc
