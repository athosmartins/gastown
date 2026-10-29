#!/usr/bin/env bash
# Selftest for gate-recovery-watchdog.py — ga-yg3e22c regression.
#
# BUG (measured 29/10 02:27, Mayor): the alarm "O gate parou… marcador dispatching travado sem
# revisores ativos (run ga-zkc35pk, branch crew/wa-worker/wa-zmxywv.3)" fired while the run's reviewer
# was ALIVE: gate-reviewer-remote-adhoc-086a570954 was `active` in `gc session list` and in the node's
# tmux, at 787s of its own 2160s budget. stuck_dispatching_detail() counted as "active reviewer" only
# sessions with template == "gate-reviewer". Since 29/10 (flag gate-remote-reviewers.on) the gate serves
# runs from the remote node, whose sessions carry template "gate-reviewer-remote" — so EVERY run served
# by the node that passed DISPATCH_STUCK_SEC (720s) looked abandoned.
#
# FIX: the corroboration counts an active session of EITHER template (_active_reviewer_sessions /
# ACTIVE_REVIEWER_TEMPLATES). It is deliberately NOT applied to reap_frozen_reviewers(): that one
# measures the silence of a LOCAL tmux pane, which a remote reviewer does not have.
#
# Must NOT regress the real case this detector exists for: no active session of either template (a
# remote reviewer that is start-pending / asleep / closed is NOT alive) and no delivered verdict still
# fires True. Also pins the helper directly (state and template are BOTH required) and that
# reap_frozen_reviewers() still leaves the remote template alone.
#
# Exercises stuck_dispatching() end-to-end against a REAL temp file standing in for DISPATCH_LOG, with
# sh() mocked for the two subprocess calls involved (`gc session list --json` and the
# `bd list -l gate-run:<id> --json` verdict query). No real subprocess ever runs.
#
# Same scoped convention as gate-recovery-watchdog.stuck-dispatching-delivered-verdict.selftest.sh.
#
# Run: bash scripts/gate-recovery-watchdog.stuck-dispatching-remote-reviewer.selftest.sh
#      WD_OVERRIDE=<path to an older gate-recovery-watchdog.py> ... → proves the scenarios fail there
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

NOW = time.time()   # freshness is driven via the temp file's REAL mtime, relative to wall clock

def ts(secs_ago):
    return time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(NOW - secs_ago))

def inflight_line(got, total, elapsed_s, timeout_s, run_id="ga-zkc35pk", branch="crew/wa-worker/wa-zmxywv.3"):
    # The REAL shape (see gate-inflight-line-contract.selftest.sh, which renders the producer's own line).
    return ("%s [quality-gate-dispatcher] Phase C: gate-run %s (branch=%s) still in "
            "flight (%d/%d verdicts, %ds/%ds, anchor=task-sent+52s) — leaving for a future sweep.\n"
            % (ts(30), run_id, branch, got, total, elapsed_s, timeout_s))

class FakeCompleted:
    def __init__(self, stdout, returncode=0):
        self.stdout = stdout
        self.returncode = returncode

def run(lines, sessions, verdict_rows=None):
    """Write `lines` to a REAL temp file as DISPATCH_LOG, mock m.sh so `gc session list --json`
    answers `sessions` (list of dicts, passed through verbatim) and the verdict-bead query answers
    `verdict_rows`, then call stuck_dispatching()."""
    fd, path = tempfile.mkstemp(prefix="grw-dispatch-log-")
    try:
        with os.fdopen(fd, "w") as f:
            f.writelines(lines)
        os.utime(path, (NOW - 5, NOW - 5))

        orig_log, orig_sh = m.DISPATCH_LOG, m.sh
        m.DISPATCH_LOG = path

        def fake_sh(args, timeout=20, stdin=None):
            is_bd_list = bool(args) and "list" in args and any("gate-run:" in a for a in args if isinstance(a, str))
            if is_bd_list:
                return FakeCompleted(json.dumps(verdict_rows if verdict_rows is not None else []))
            return FakeCompleted(json.dumps({"sessions": sessions}))
        m.sh = fake_sh

        try:
            return m.stuck_dispatching()
        finally:
            m.DISPATCH_LOG, m.sh = orig_log, orig_sh
    finally:
        os.unlink(path)

# The run from the incident: 0/1 verdicts, 787s of 2160s — past DISPATCH_STUCK_SEC (720s), well inside its budget.
LINE = [inflight_line(got=0, total=1, elapsed_s=787, timeout_s=2160)]

# ── Scenario 1: the exact reported bug — an ACTIVE REMOTE reviewer must suppress the alarm ──
# FAILS against the pre-fix code (it only counted template == "gate-reviewer").
r1 = run(LINE, [{"template": "gate-reviewer-remote", "state": "active",
                 "session_name": "gate-reviewer-remote-adhoc-086a570954"}])
if r1 is False:
    ok("ga-yg3e22c: one ACTIVE gate-reviewer-remote session — correctly NOT stuck")
else:
    bad("ga-yg3e22c REGRESSION: fired with a live remote reviewer working the run: %r" % (r1,))

# ── Scenario 2: the live shape of 29/10 — one active remote + two start-pending remotes ───
r2 = run(LINE, [
    {"template": "gate-reviewer-remote", "state": "start-pending", "session_name": "gate-reviewer-remote-adhoc-2a36a19f81"},
    {"template": "gate-reviewer-remote", "state": "start-pending", "session_name": "gate-reviewer-remote-adhoc-c3646703e0"},
    {"template": "gate-reviewer-remote", "state": "active", "session_name": "gate-reviewer-remote-adhoc-086a570954"},
])
if r2 is False:
    ok("the live 29/10 mix (1 active + 2 start-pending remote) — NOT stuck")
else:
    bad("the live 29/10 session mix still fires: %r" % (r2,))

# ── Scenario 3: a LOCAL active reviewer still suppresses (pre-existing behavior) ──────────
r3 = run(LINE, [{"template": "gate-reviewer", "state": "active"}])
if r3 is False:
    ok("an active LOCAL gate-reviewer still suppresses the alarm (pre-existing behavior)")
else:
    bad("REGRESSION: an active local reviewer no longer suppresses the alarm: %r" % (r3,))

# ── Scenario 4: the real stuck case must still fire — remote sessions that are NOT alive ──
# Only start-pending / asleep / closed remote sessions: nobody is working the run.
r4 = run(LINE, [
    {"template": "gate-reviewer-remote", "state": "start-pending"},
    {"template": "gate-reviewer-remote", "state": "asleep"},
    {"template": "gate-reviewer-remote", "state": "closed"},
])
if r4 is True:
    ok("remote sessions that are start-pending/asleep/closed (none active) — still fires (genuinely stuck)")
else:
    bad("REGRESSION: a non-active remote session suppressed a real alarm: %r" % (r4,))

# ── Scenario 5: no session at all, no verdict — still fires ──────────────────────────────
r5 = run(LINE, [])
if r5 is True:
    ok("no session of either template, no verdict — still fires (genuinely stuck)")
else:
    bad("REGRESSION: stopped firing on an abandoned run: %r" % (r5,))

# ── Scenario 6: an active session of an UNRELATED template must not count as a reviewer ──
# The fix widens to exactly one more template; it must not turn into "any active session".
r6 = run(LINE, [{"template": "gastown.dog", "state": "active"}, {"template": "wa-worker", "state": "active"}])
if r6 is True:
    ok("active sessions of unrelated templates (dog, wa-worker) do not count as a reviewer — still fires")
else:
    bad("an unrelated active session suppressed the alarm: %r" % (r6,))

# ── Scenario 7: the helper itself — template AND state are both required ─────────────────
if hasattr(m, "_active_reviewer_sessions"):
    h = m._active_reviewer_sessions([
        {"template": "gate-reviewer", "state": "active"},
        {"template": "gate-reviewer-remote", "state": "active"},
        {"template": "gate-reviewer-remote", "state": "start-pending"},
        {"template": "gate-reviewer", "state": "asleep"},
        {"template": "other", "state": "active"},
        {"state": "active"},
        {"template": "gate-reviewer-remote"},
    ])
    if len(h) == 2 and {x["template"] for x in h} == {"gate-reviewer", "gate-reviewer-remote"}:
        ok("_active_reviewer_sessions keeps exactly the active local+remote reviewers (template AND state required)")
    else:
        bad("_active_reviewer_sessions picked the wrong rows: %r" % (h,))
else:
    bad("_active_reviewer_sessions not found — the fix is not in this watchdog")

# ── Scenario 8: reap_frozen_reviewers() must keep ignoring the remote template ──────────
# It measures the silence of a LOCAL tmux pane; a remote reviewer has none, so a "frozen" verdict on one
# would kill a healthy reviewer. Pinned at the source: the candidate filter still names only the local template.
import inspect
try:
    seg = inspect.getsource(m.reap_frozen_reviewers)
except Exception as e:           # not found / source unreadable → say so, never a silent pass
    seg = None
    bad("cannot read reap_frozen_reviewers() source to pin it: %r" % (e,))
if seg is not None:
    if 's.get("template") != "gate-reviewer"' in seg and "gate-reviewer-remote" not in seg:
        ok("reap_frozen_reviewers() still filters on the LOCAL template only (remote has no local pane to measure)")
    else:
        bad("reap_frozen_reviewers() candidate filter changed — a remote reviewer must stay out of the frozen-pane kill")

print("")
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
rc=$?
echo ""
[ "$rc" = "0" ] && echo "SELFTEST: PASS" || echo "SELFTEST: FAIL (rc=$rc)"
exit $rc
