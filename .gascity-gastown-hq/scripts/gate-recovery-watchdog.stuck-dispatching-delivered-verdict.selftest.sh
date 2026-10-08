#!/usr/bin/env bash
# Selftest for gate-recovery-watchdog.py — ga-rzd08j regression.
#
# BUG (measured 27/09 08:13-08:14, Mayor's own audit — see ga-mgqt0f): stuck_dispatching()'s
# only corroboration for "no active gate-reviewer session" is `gc session list --json`
# filtered to state=="active". A reviewer that just DELIVERED its verdict and exited
# ALSO shows zero active sessions there — that is not "spawn failed, nobody ever showed
# up", it is "the run already has its verdict, Phase C just hasn't harvested it yet".
#
# Real timeline that produced this bead:
#   07:58:38  dispatcher creates gate-run ga-d0z3i8, spawns reviewer session
#   08:12:59  dispatcher log: "still in flight (0/1 verdicts, 860s/2520s)"
#   08:13:43  reviewer SESSION closes (delivered its verdict, then exited)
#   08:13:53  watchdog runs stuck_dispatching() → fires TRUE (false positive: alarmed
#             the Mayor with an infra runbook for a gate that was NOT stuck)
#   08:14:15  dispatcher's own Phase C harvests the verdict, overall=PASS
#   08:14:32  merge
#
# FIX: before concluding "no active reviewer means abandoned", also check whether the
# run already has a DELIVERED (closed) verdict bead recorded — label gate-run:<id>,
# via the existing `_run_verdicts()` helper (already used elsewhere in this file for the
# same "has this run's verdict landed" question). A closed verdict bead proves a reviewer
# clearly showed up and did the work; Phase C just hasn't collected it yet. The run id is
# parsed from the SAME dispatcher-log line STUCK_INFLIGHT_RE already matches — "Phase C:
# gate-run <id> (branch=<b>) still in flight (...)" (quality-gate-dispatcher.sh:~10579)
# always carries it.
#
# Must NOT regress the real case this detector exists for: a genuinely abandoned run
# (spawn failed / reviewer start-pending or dead) with NO verdict ever delivered and NO
# active session still fires True.
#
# Exercises stuck_dispatching() end-to-end against a REAL temp file standing in for
# DISPATCH_LOG, with `sh()` mocked to answer BOTH subprocess calls this function (and the
# `_run_verdicts()` helper it now also calls) makes: `gc session list --json` and the
# `bd list -l gate-run:<id> --json` verdict-bead query. No real subprocess ever runs.
#
# NOT a general test harness for this file — scoped narrowly to this one bug, same
# convention as gate-recovery-watchdog.stuck-dispatching-dead-regex.selftest.sh (ga-iodjh7).
#
# Run: bash scripts/gate-recovery-watchdog.stuck-dispatching-delivered-verdict.selftest.sh
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="${WD_OVERRIDE:-$SELF_DIR/gate-recovery-watchdog.py}"
[ -f "$WD" ] || { echo "FATAL: gate-recovery-watchdog.py not found at $WD"; exit 1; }

python3 - "$WD" <<'PY'
import importlib.util, sys, time, os, tempfile, json

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
                     # point exists — so freshness is driven via the temp file's REAL
                     # mtime, set relative to wall clock.

def ts(secs_ago):
    return time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(NOW - secs_ago))

def inflight_line(got, total, elapsed_s, timeout_s, run_id="ga-d0z3i8", branch="crew/x/wa-13be2"):
    # The REAL shape (ga-ufskhy added the ", anchor=..." suffix inside the parens) — see
    # gate-inflight-line-contract.selftest.sh, which renders the producer's own line (ga-49l8kr).
    return ("%s [quality-gate-dispatcher] Phase C: gate-run %s (branch=%s) still in "
            "flight (%d/%d verdicts, %ds/%ds, anchor=task-sent+52s) — leaving for a future sweep.\n"
            % (ts(30), run_id, branch, got, total, elapsed_s, timeout_s))

class FakeCompleted:
    """Stand-in for the subprocess.CompletedProcess sh() normally returns. Carries
    returncode (the pre-existing dead-regex selftest's FakeCompleted did not — fine
    there because its mock never had to survive a call into _run_verdicts(), which
    checks r.returncode before touching stdout)."""
    def __init__(self, stdout, returncode=0):
        self.stdout = stdout
        self.returncode = returncode

def run(lines, mtime_age_s=5, active_reviewers=0, verdict_rows=None, bd_list_fails=False):
    """Write `lines` to a REAL temp file, point m.DISPATCH_LOG at it with a controlled
    mtime, mock m.sh so no real subprocess runs for EITHER the `gc session list` call
    or the `bd list -l gate-run:<id>` call _run_verdicts() makes, call
    stuck_dispatching(), then restore/clean up.

    verdict_rows: rows _run_verdicts() should see for the run's verdict beads (label
    gate-run:<id>) — e.g. [{"status": "closed", "assignee": "gate-reviewer-adhoc-x"}]
    to simulate a reviewer that already delivered. None → no verdict bead at all."""
    fd, path = tempfile.mkstemp(prefix="grw-dispatch-log-")
    try:
        with os.fdopen(fd, "w") as f:
            f.writelines(lines)
        os.utime(path, (NOW - mtime_age_s, NOW - mtime_age_s))

        orig_log, orig_sh = m.DISPATCH_LOG, m.sh
        m.DISPATCH_LOG = path

        def fake_sh(args, timeout=20, stdin=None):
            is_bd_list = bool(args) and "list" in args and any("gate-run:" in a for a in args if isinstance(a, str))
            if is_bd_list:
                if bd_list_fails:
                    return None
                return FakeCompleted(json.dumps(verdict_rows if verdict_rows is not None else []))
            # the `gc session list --json` call
            sessions = [{"template": "gate-reviewer", "state": "active"}] * active_reviewers
            return FakeCompleted(json.dumps({"sessions": sessions}))
        m.sh = fake_sh

        try:
            return m.stuck_dispatching()
        finally:
            m.DISPATCH_LOG, m.sh = orig_log, orig_sh
    finally:
        os.unlink(path)

# ── Scenario 1: the exact reported bug — delivered verdict must suppress the alarm ────
# Real numbers from the ga-rzd08j incident: 0/1 verdicts as of the last logged Phase C
# poll, elapsed(860s) past DISPATCH_STUCK_SEC(720s), no active reviewer (it already
# closed) — BUT the run's verdict bead is already CLOSED (delivered). This is the
# scenario that FAILS against the pre-fix code (old code has no such corroboration and
# unconditionally returns True here).
r1 = run([inflight_line(got=0, total=1, elapsed_s=860, timeout_s=2520)],
         active_reviewers=0,
         verdict_rows=[{"status": "closed", "assignee": "gate-reviewer-adhoc-296c707c20"}])
if r1 is False:
    ok("ga-rzd08j: delivered (closed) verdict bead + no active reviewer — correctly NOT stuck (awaiting Phase C harvest)")
else:
    bad("ga-rzd08j REGRESSION: fired despite the run already having a delivered verdict: %r" % (r1,))

# ── Scenario 2: regression guard — the REAL stuck case must still fire ────────────────
# Same shape as Scenario 1, but NO verdict was ever delivered (spawn genuinely failed /
# reviewer start-pending or dead). Must remain True — this fix must not widen the
# window stuck_dispatching() exists to close.
r2 = run([inflight_line(got=0, total=1, elapsed_s=860, timeout_s=2520)],
         active_reviewers=0, verdict_rows=[])
if r2 is True:
    ok("no delivered verdict, no active reviewer — still correctly fires (genuinely stuck)")
else:
    bad("REGRESSION: stopped firing on a genuinely abandoned run: %r" % (r2,))

# ── Scenario 3: a PENDING (open, undelivered) verdict bead must NOT suppress ──────────
# A verdict bead existing but still open only proves a reviewer was assigned/spawned at
# some point, not that it finished. Only a CLOSED (delivered) bead should count.
r3 = run([inflight_line(got=0, total=1, elapsed_s=860, timeout_s=2520)],
         active_reviewers=0,
         verdict_rows=[{"status": "open", "assignee": "gate-reviewer-adhoc-x"}])
if r3 is True:
    ok("verdict bead exists but is still OPEN (not delivered) — correctly still fires")
else:
    bad("suppressed the alarm on a merely-pending (undelivered) verdict bead: %r" % (r3,))

# ── Scenario 4: the verdict-bead query itself fails — fail-safe to the prior verdict ──
# bd/Dolt unreachable while checking corroboration must NEVER suppress a real alarm —
# fail-safe keeps the pre-existing (reachable-signal-only) answer, same fail-open
# philosophy already documented for the `gc session list` failure path.
r4 = run([inflight_line(got=0, total=1, elapsed_s=860, timeout_s=2520)],
         active_reviewers=0, bd_list_fails=True)
if r4 is True:
    ok("verdict-bead query failure fails safe — keeps firing rather than silently suppressing")
else:
    bad("a failed corroboration query suppressed a real alarm instead of failing safe: %r" % (r4,))

# ── Scenario 5: an active reviewer still short-circuits before the new check ──────────
# Unchanged pre-existing behavior — must not regress.
r5 = run([inflight_line(got=0, total=1, elapsed_s=860, timeout_s=2520)],
         active_reviewers=1, verdict_rows=[])
if r5 is False:
    ok("an active gate-reviewer session still suppresses the alarm (pre-existing behavior)")
else:
    bad("REGRESSION: active reviewer no longer suppresses the alarm: %r" % (r5,))

print("")
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
rc=$?
echo ""
[ "$rc" = "0" ] && echo "SELFTEST: PASS" || echo "SELFTEST: FAIL (rc=$rc)"
exit $rc
