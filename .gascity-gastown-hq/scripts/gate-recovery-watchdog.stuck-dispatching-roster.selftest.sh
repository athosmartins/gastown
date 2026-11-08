#!/usr/bin/env bash
# Selftest for gate-recovery-watchdog.py — ga-fwuo49i regression.
#
# BUG (measured 08/11, Mayor): four times between 18:56Z and 20:44Z the alarm "O gate parou… marcador dispatching travado sem
# revisores ativos" (REPAIR beads ga-z9olaxr, ga-7pbwt5r, ga-9b771gv, ga-c00aopc) fired while the run's REMOTE reviewer was alive and
# working (gate-reviewer-remote-adhoc-bb3dcb8c46 at 1185s of 2100s). ga-yg3e22c (29/10) already counts the template
# gate-reviewer-remote and is live: of the 145 runs served only by the node whose first verdict took > 800 s on 07-08/11 (counted
# off their verdict beads), 135 never alarmed. What is left is a read that does not ALWAYS see the live reviewer — the roster of
# those instants is gone, so WHICH hole did it was not read off the mini; the read had three, and each turned a miss into the claim
# "no reviewer is alive":
#   1. UNREADABLE was read as EMPTY: `sessions = json.loads(rs.stdout).get("sessions", []) if rs else []`. A `gc session list --json`
#      that timed out (sh() returns None after 20 s; crew-no-session-alarm MEASURED this call at 5-37 s at load 50-80), exited
#      non-zero, answered an error envelope or a body with no list, became "nobody is alive" (ga-iodjh7 documented the None case as a
#      fail-open and invited a later bead to revisit it; ga-yg3e22c's builder flagged it again).
#   2. A reviewer was recognised by `template == <literal>` only. Remote reviewers can have a bare session bead (agent_name/
#      session_name/state, NO template or alias: ga-2hd02v.3.27, session bead ga-axm0ves) and the list was inferred to come out
#      without them; a template can come qualified (`<pack>.x`, `<rig>/x`: the Hetzner reaper tolerates both).
#   3. Alive meant `state == "active"`; the city's LIVE set is {active, awake} (bead_state.LIVE_SESSION_STATES), and a row flagged
#      closed was still counted.
#
# FIX: the roster has THREE outcomes — a list, an empty list, "could not read" (_session_roster) — and only a READABLE roster may say
# "no reviewer alive"; a reviewer is recognised by template OR name (qualified or not), alive = {active, awake} and not closed; the
# read waits as long as the city's other readers of the same call; each verdict leaves a log line with what was seen.
#
# Must NOT regress what the detector exists for: a readable roster with no live reviewer (none at all, or only start-pending / asleep /
# closed ones, or look-alike names) still fires.
#
# Exercises stuck_dispatching_detail() end to end against a REAL temp file standing in for DISPATCH_LOG, sh() mocked for the two
# subprocess calls involved (`gc session list --json` and the `bd list -l gate-run:<id>` verdict query). No real subprocess runs.
#
# Run: bash scripts/gate-recovery-watchdog.stuck-dispatching-roster.selftest.sh
#      WD_OVERRIDE=<path to an older gate-recovery-watchdog.py> ... → proves the scenarios fail there
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="${WD_OVERRIDE:-$SELF_DIR/gate-recovery-watchdog.py}"
[ -f "$WD" ] || { echo "FATAL: gate-recovery-watchdog.py not found at $WD"; exit 1; }

python3 - "$WD" <<'PY'
import importlib.util, sys, time, os, tempfile, json, io, contextlib

spec = importlib.util.spec_from_file_location("grw", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.argv = ["grw"]                      # __name__ != "__main__" → main() never runs
spec.loader.exec_module(m)

PASS = FAIL = 0
def check(cond, good, wrong):
    global PASS, FAIL
    if cond: PASS += 1; print("  ok: %s" % good)
    else: FAIL += 1; print("  BAD: %s" % wrong)

NOW = time.time()   # freshness is driven via the temp file's REAL mtime, relative to wall clock
RUN, BRANCH = "ga-zkc35pk", "crew/wa-worker/wa-zmxywv.3"
REV = "gate-reviewer-remote-adhoc-bb3dcb8c46"

def inflight_line(got=0, total=1, elapsed_s=None, timeout_s=2160):
    # The REAL shape (see gate-inflight-line-contract.selftest.sh, which renders the producer's own line).
    elapsed_s = m.DISPATCH_STUCK_SEC + 67 if elapsed_s is None else elapsed_s     # past the grace period, whatever the constant is
    return ("%s [quality-gate-dispatcher] Phase C: gate-run %s (branch=%s) still in flight (%d/%d verdicts, %ds/%ds, "
            "anchor=task-sent+52s) — leaving for a future sweep.\n"
            % (time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(NOW - 30)), RUN, BRANCH, got, total, elapsed_s, timeout_s))

class FakeCompleted:
    def __init__(self, stdout, returncode=0):
        self.stdout, self.returncode = stdout, returncode

def good(sessions): return FakeCompleted(json.dumps({"sessions": sessions}))
def raw(stdout, rc=0): return FakeCompleted(stdout, rc)
def row(**kw):
    d = {"id": "ga-x1", "state": "active", "attached": False, "closed": False}
    d.update(kw)
    return d

@contextlib.contextmanager
def sh_says(reply, seen=None):
    """m.sh answers `gc session list` with `reply` (a FakeCompleted, or None = sh() failed/timed out) and the verdict-bead query with no rows."""
    orig = m.sh
    def fake_sh(args, timeout=20, stdin=None):
        if any(isinstance(a, str) and "gate-run:" in a for a in args):
            return FakeCompleted("[]")
        if list(args[:3]) == ["gc", "session", "list"]:
            if seen is not None: seen["timeout"] = timeout
            return reply
        raise AssertionError("unexpected subprocess: %r" % (args,))
    m.sh = fake_sh
    try: yield
    finally: m.sh = orig

def go(reply, detail=False):
    """(result, printed, timeout asked of the roster read) of the detector fed one stuck-looking in-flight line; an exception is the result ("EXC", repr)."""
    fd, path = tempfile.mkstemp(prefix="grw-roster-log-")
    seen, buf, orig_log = {}, io.StringIO(), m.DISPATCH_LOG
    try:
        with os.fdopen(fd, "w") as f: f.write(inflight_line())
        os.utime(path, (NOW - 5, NOW - 5))
        m.DISPATCH_LOG = path
        with sh_says(reply, seen), contextlib.redirect_stdout(buf):
            try: res = m.stuck_dispatching_detail() if detail else m.stuck_dispatching()
            except Exception as e: res = ("EXC", repr(e))
        return res, buf.getvalue(), seen.get("timeout")
    finally:
        m.DISPATCH_LOG = orig_log
        os.unlink(path)

def scen(label, reply, want):
    res = go(reply)[0]
    check(res == want, "%s → %r" % (label, want), "%s: wanted %r, got %r" % (label, want, res))

# ── A. UNREADABLE is not EMPTY: nobody may be called "not alive" off a read that did not answer ──────────────────────────
UNREADABLE = [
    ("sh() failed or timed out (None)", None),
    ("gc exited 1 with a well-formed empty body", raw('{"sessions": []}', 1)),
    ("gc exited 124 and printed nothing", raw("", 124)),
    ("gc was killed by a signal (rc=-9) after printing a well-formed body", raw('{"sessions": []}', -9)),
    ("envelope whose ok is null", raw('{"ok": null, "sessions": []}')),
    ("empty stdout", raw("")),
    ("stdout is not JSON", raw("Error: dolt unavailable")),
    ("error envelope with no list", raw('{"ok": false, "error": "dolt down"}')),
    ("error envelope that carries an empty list", raw('{"ok": false, "sessions": []}')),
    ("JSON object without `sessions`", raw("{}")),
    ("`sessions` is null", raw('{"sessions": null}')),
    ("`sessions` is not a list", raw('{"sessions": "oops"}')),
    ("JSON that is not an object", raw("[]")),
    ("an entry of the list that is not an object", raw('{"sessions": [5]}')),
    ("a dead reviewer row next to an entry that is not an object", raw(json.dumps({"sessions": [row(session_name=REV, state="asleep"), 5]}))),
    ("stdout is None", FakeCompleted(None)),
]
for label, reply in UNREADABLE:
    scen("roster unreadable (%s) is NOT 'no reviewer alive'" % label, reply, False)

# ── B. a READABLE roster with nobody alive still fires, and names the run ────────────────────────────────────────────
scen("readable EMPTY roster (nobody running) — genuinely stuck", good([]), True)
scen("readable roster of unrelated sessions only (mayor, dog, wa-worker)", good([
    row(template="gastown.mayor", session_name="mayor"), row(template="gastown.dog", session_name="gastown.dog-1"),
    row(template="wa-worker", session_name="wa-worker-3")]), True)
res = go(good([]), detail=True)[0]
check(res == (True, RUN, BRANCH), "fires with the run and branch the REPAIR bead names", "wrong triple: %r" % (res,))

# ── C. a live reviewer, however the list spells it, is never 'no reviewer' ───────────────────────────────────────────
ALIVE = [
    ("bare bead of a remote reviewer: session_name + state only (the ga-axm0ves shape)", row(session_name=REV)),
    ("...agent_name only", row(agent_name=REV)), ("...alias only", row(alias=REV)), ("...name only", row(name=REV)),
    ("template \"\" and the name", row(template="", session_name=REV)),
    ("template null and the name", row(template=None, session_name=REV)),
    ("bare bead of a LOCAL reviewer", row(session_name="gate-reviewer-adhoc-12d22287ac")),
    ("a name that is exactly the local template", row(session_name="gate-reviewer")),
    ("a name that is exactly the remote template", row(session_name="gate-reviewer-remote")),
    ("remote template qualified by pack", row(template="gastown.gate-reviewer-remote")),
    ("remote template qualified by rig", row(template="gascity/gate-reviewer-remote")),
    ("local template qualified", row(template="gastown.gate-reviewer")),
    ("state awake (the city's LIVE set) on a remote reviewer", row(template="gate-reviewer-remote", state="awake")),
    ("state awake on a bare bead", row(session_name=REV, state="awake")),
    ("state in capitals", row(template="gate-reviewer-remote", state="ACTIVE")),
]
for label, r in ALIVE:
    scen("live reviewer — %s" % label, good([r]), False)

# ── D. NOT a live reviewer → still fires ──────────────────────────────────────────────────────────────────────────────
NOT_ALIVE = [
    ("start-pending (a spawn that never materialized)", row(session_name=REV, state="start-pending")),
    ("asleep", row(session_name=REV, state="asleep")), ("state closed", row(session_name=REV, state="closed")),
    ("drained", row(template="gate-reviewer-remote", state="drained")),
    ("closed flag on a row whose state still says active", row(template="gate-reviewer-remote", closed=True)),
    ("closed flag on a bare bead", row(session_name=REV, closed=True)),
    ("no state", {"session_name": REV}), ("state that is not a string", row(session_name=REV, state=1)),
    ("name only LOOKS like a reviewer: gate-reviewerX-1", row(session_name="gate-reviewerX-1")),
    ("...xgate-reviewer-1", row(session_name="xgate-reviewer-1")),
    ("...dog-remote-gate-reviewer-1", row(session_name="dog-remote-gate-reviewer-1")),
    ("...gate-review-1", row(session_name="gate-review-1")),
    ("template gate-reviewer-remotex", row(template="gate-reviewer-remotex")),
]
for label, r in NOT_ALIVE:
    scen("no live reviewer — %s" % label, good([r]), True)
scen("one dead reviewer next to one live bare bead", good([row(session_name=REV + "x", state="asleep"), row(session_name=REV)]), False)

# ── E. every verdict leaves a line saying what was seen (the next false alarm must explain itself) ────────────────
res, out, _t = go(good([row(session_name=REV, state="start-pending"), row(template="dog-remote", session_name="dog-remote-2"),
                        row(session_name=REV + "c", closed=True)]), detail=True)
check(res[0] is True and RUN in out and BRANCH in out and REV + ":start-pending" in out and REV + "c:active/closed" in out and "3 session" in out,
      "a positive detection logs run, branch, how many sessions it read and the reviewer-like rows with their state (and closed flag)",
      "positive detection did not explain itself: %r / %r" % (res, out))
res, out, _t = go(good([]))
check(res is True and "among the 0 session(s) read" in out and "reviewer-like rows: none" in out,
      "a positive detection on an empty roster says so ('0 session(s)', rows: none)", "empty-roster detection logged %r / %r" % (res, out))
res, out, _t = go(good([row(session_name="gate-reviewer-remote-adhoc-%d" % i, state="asleep") for i in range(8)]))
check(res is True and "(+2 more)" in out and out.count("gate-reviewer-remote-adhoc-") == 6,
      "a crowd of dead reviewer rows is summarised in the log (6 listed, '+2 more'), not dumped", "reviewer-rows summary misbehaved: %r / %r" % (res, out))
for label, reply, word in (("timeout", None, "timeout"), ("exit code", raw("", 7), "rc=7"), ("error envelope", raw('{"ok": false}'), "ok=")):
    res, out, _t = go(reply)
    check(res is False and "unavailable" in out and RUN in out and word in out,
          "unreadable roster (%s) is logged as unavailable, with the run and the reason" % label,
          "unreadable roster (%s) left no usable line: %r / %r" % (label, res, out))

# ── F. the read waits as long as the city's other readers of the same call ───────────────────────────────────────────
t = go(good([]))[2]
check(isinstance(t, (int, float)) and t >= 30, "`gc session list` is given %ss (the dispatcher waits 30 s for the same call)" % t,
      "the roster read only waits %r s (sh() default 20 s is below the 5-37 s the city measured)" % (t,))

# ── G. the helpers themselves ─────────────────────────────────────────────────────────────────────────────────────────
def safe(fn, *a):
    try: return fn(*a)
    except Exception as e: return ("EXC", repr(e))

if hasattr(m, "_session_roster"):
    for label, reply in UNREADABLE:
        with sh_says(reply): got = safe(m._session_roster)
        check(isinstance(got, tuple) and len(got) == 2 and got[0] is None and isinstance(got[1], str) and got[1],
              "_session_roster: %s → (None, reason)" % label, "_session_roster: %s → %r" % (label, got))
    with sh_says(good([])): got = safe(m._session_roster)
    check(got == ([], None), "_session_roster: a readable empty roster is ([], None), not unreadable", "empty roster came back %r" % (got,))
    with sh_says(good([row(session_name=REV)])): got = safe(m._session_roster)
    check(got[1] is None and len(got[0]) == 1, "_session_roster: a readable roster comes back whole", "readable roster came back %r" % (got,))
else:
    check(False, "", "_session_roster not found — the fix is not in this watchdog")
for label, reply in UNREADABLE:     # the loop-wide reader (governor, hung-run reaper) is strict in the same way: None = "cannot verify, skip"
    with sh_says(reply): got = safe(m._session_list_json)
    check(got is None, "_session_list_json: %s → None" % label, "_session_list_json: %s → %r (a caller would read it as 'no sessions')" % (label, got))
with sh_says(good([])): got = safe(m._session_list_json)
check(got == [], "_session_list_json: a readable empty roster stays []", "empty roster came back %r" % (got,))
if hasattr(m, "_active_reviewer_sessions"):
    keep_rows = [row(template="gate-reviewer"), row(template="gate-reviewer-remote"), row(session_name=REV, state="awake"),
                 row(template="x.gate-reviewer-remote")]
    drop_rows = [row(template="gate-reviewer", state="asleep"), row(template="gate-reviewer-remote", state="start-pending"),
                 row(template="gate-reviewer-remote", closed=True), row(template="other"), row(session_name="gate-reviewerX-1"),
                 {"state": "active"}, {"template": "gate-reviewer-remote"}, 5, None]
    keep = safe(m._active_reviewer_sessions, keep_rows + drop_rows)
    check(keep == keep_rows, "_active_reviewer_sessions keeps exactly the live, open reviewers (by template or name) and shrugs at junk rows",
          "_active_reviewer_sessions picked %r" % (keep,))
else:
    check(False, "", "_active_reviewer_sessions not found")

print("")
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
rc=$?
echo ""
[ "$rc" = "0" ] && echo "SELFTEST: PASS" || echo "SELFTEST: FAIL (rc=$rc)"
exit $rc
