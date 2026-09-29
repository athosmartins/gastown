#!/usr/bin/env bash
# Selftest for gate-recovery-watchdog.py — ga-hqrnmu regression.
#
# BUG (measured 29/09 07:30, Mayor's triage of ga-kr9p5c): with no positive Dolt signal,
# spawn_repair_agent() files an UNROUTED audit bead for the Mayor (ga-rwpwz8 — correct, no
# destructive runbook goes to an unsupervised dog). NOTHING EVER CLOSED IT. The normal outcome of
# this alarm is a transient stall that clears by itself, so six "REPAIR gate-watchdog (gate):
# marcador dispatching travado sem revisores ativos" beads piled up in Travadas between 26/09
# 21:53 and 29/09 07:05 — while the gate was flowing (07:28 PASSed ga-7vmcr1 with 2 reviewers).
# None said WHICH run was stuck (they cited only the lesson, ga-rwpwz8). The Mayor closed all six by hand.
#
# FIX (FIX 10): (a) the alarm bead names the stuck run + branch (title and body) and carries
# REPAIR_AUDIT_LABEL; (b) close_recovered_repair_audit_beads() closes an UNOWNED labelled bead
# once a real gate verdict (Gate PASSED, or a reviewer FAIL) appears AFTER its created_at, quoting
# the verdict. Three states, never two: verdict-after -> close; log read + no verdict -> leave;
# log unreadable / created_at unparsable -> leave. `Gate FAILED: TIMEOUT` is the fault itself, not a verdict.
#
# Exercises close_recovered_repair_audit_beads() end-to-end against a REAL temp file standing in for
# DISPATCH_LOG, with sh() mocked (no real subprocess, no real bd, no real Dolt).
#
# Run: bash scripts/gate-recovery-watchdog.repair-audit-autoclose.selftest.sh
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="${WD_OVERRIDE:-$SELF_DIR/gate-recovery-watchdog.py}"
[ -f "$WD" ] || { echo "FATAL: gate-recovery-watchdog.py not found at $WD"; exit 1; }

python3 - "$WD" <<'PY'
import importlib.util, sys, time, os, tempfile, json, datetime

spec = importlib.util.spec_from_file_location("grw", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.argv = ["grw"]                      # __name__ != "__main__" → main() never runs
spec.loader.exec_module(m)

for sym in ("close_recovered_repair_audit_beads", "repair_audit_verdict", "REPAIR_AUDIT_LABEL",
            "stuck_dispatching_detail"):
    if not hasattr(m, sym):
        print("FATAL: %s missing — ga-hqrnmu has not landed in this watchdog" % sym, file=sys.stderr)
        sys.exit(2)

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)
def check(cond, good, badmsg):
    ok(good) if cond else bad(badmsg)

NOW = time.time()
T = NOW - 3 * 3600                      # the REPAIR bead was created 3h ago

def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def logts(epoch):
    return time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(epoch))

def passed(epoch, branch="fix/ga-7vmcr1"):
    return "%s [quality-gate-dispatcher] Gate PASSED: branch=%s tier=CODE merge_sha=abc123 elapsed=641s\n" % (logts(epoch), branch)

def reviewer_fail(epoch):
    return "%s [quality-gate-dispatcher] Gate FAILED: Reviewer 1 FAIL: VERDICT: FAIL\n" % logts(epoch)

def timeout_fail(epoch):
    return "%s [quality-gate-dispatcher] Gate FAILED: TIMEOUT: reviewers did not submit verdicts within 28 minutes.\n" % logts(epoch)

def bead(bid, created, assignee=""):
    return {"id": bid, "created_at": created if isinstance(created, str) else iso(created), "assignee": assignee,
            "status": "open", "labels": ["pilot:no-auto-dispatch", m.REPAIR_AUDIT_LABEL]}

class CP:
    def __init__(self, stdout="", returncode=0):
        self.stdout, self.returncode = stdout, returncode

def sweep(log_lines, beads, list_fails=False, close_rc=0, log_missing=False, dry_run=False, log_bytes=None):
    """Run close_recovered_repair_audit_beads() against a temp dispatcher log. Returns
    (closed_ids, close_reasons, list_args, output-was-printed?) — closed_ids = beads a `bd close` was issued for."""
    fd, path = tempfile.mkstemp(prefix="grw-dispatch-log-")
    lfd, lpath = tempfile.mkstemp(prefix="grw-recovery-log-")
    os.close(lfd)
    closes, calls = [], []
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(log_bytes if log_bytes is not None else "".join(log_lines).encode("utf-8"))
        saved = (m.DISPATCH_LOG, m.sh, m.RECOVERY_LOG, m.GRW_DRY_RUN, m.GRW_ENABLED)
        m.DISPATCH_LOG = "/nonexistent/grw-dispatch.log" if log_missing else path
        m.RECOVERY_LOG = lpath
        m.GRW_DRY_RUN = dry_run

        def fake_sh(args, timeout=20, stdin=None):
            calls.append(list(args))
            if "close" in args and "bd" in args[0:1]:
                closes.append((args[args.index("close") + 1], args[args.index("-r") + 1] if "-r" in args else ""))
                return CP("", close_rc)
            if "list" in args:
                return None if list_fails else CP(json.dumps(beads))
            return CP("")
        m.sh = fake_sh
        try:
            m.close_recovered_repair_audit_beads(NOW)
        finally:
            m.DISPATCH_LOG, m.sh, m.RECOVERY_LOG, m.GRW_DRY_RUN, m.GRW_ENABLED = saved
        with open(lpath) as f:
            ledger = [json.loads(x) for x in f if x.strip()]
        return closes, calls, ledger
    finally:
        os.unlink(path); os.unlink(lpath)

# ── 1. THE reported bug: REPAIR at T, verdict at T+10min → closed ─────────────────────────────────
closes, calls, ledger = sweep([passed(T + 600)], [bead("ga-mvnkw5", T)])
check([c[0] for c in closes] == ["ga-mvnkw5"],
      "REPAIR created at T + Gate PASSED at T+10min → closed (the six-beads-in-Travadas case)",
      "REPAIR with a later PASS was NOT closed: %r" % (closes,))
check(closes and "Gate PASSED" in closes[0][1] and "fix/ga-7vmcr1" in closes[0][1],
      "the close reason QUOTES the verdict (branch + 'Gate PASSED') so anyone can audit it",
      "close reason does not quote the verdict: %r" % (closes,))
check(any(e.get("event") == "closed_recovered_repair_audit" and e.get("bead") == "ga-mvnkw5" for e in ledger),
      "the close is written to the recovery ledger (durable audit)", "no ledger record for the close: %r" % (ledger,))

# ── 2. verdict BEFORE creation → stays open ───────────────────────────────────────────────────────
closes, _, _ = sweep([passed(T - 600)], [bead("ga-x1", T)])
check(closes == [], "verdict at T-10min (before the REPAIR existed) → stays OPEN", "closed on a verdict older than the bead: %r" % (closes,))

# ── 3. only a TIMEOUT after creation → stays open (closing on the fault itself is the trap) ───────
closes, _, _ = sweep([timeout_fail(T + 600)], [bead("ga-x2", T)])
check(closes == [], "only 'Gate FAILED: TIMEOUT' after T → stays OPEN (a timeout is the failure, not a verdict)",
      "closed because of a TIMEOUT line: %r" % (closes,))

# ── 4. a reviewer FAIL is a delivered verdict → the gate is producing verdicts → closes ───────────
closes, _, _ = sweep([reviewer_fail(T + 600)], [bead("ga-x3", T)])
check([c[0] for c in closes] == ["ga-x3"], "a reviewer FAIL after T counts as a verdict → closed", "reviewer FAIL not counted: %r" % (closes,))

# ── 5. THREE states: unreadable log is NOT 'no verdict' and NOT 'resolved' ────────────────────────
closes, _, _ = sweep([passed(T + 600)], [bead("ga-x4", T)], log_missing=True)
check(closes == [], "dispatcher log unreadable → stays OPEN (cannot tell)", "closed although the log could not be read: %r" % (closes,))
closes, _, _ = sweep([], [bead("ga-x5", T)])
check(closes == [], "log readable but EMPTY (zero verdicts) → stays OPEN", "closed on an empty log: %r" % (closes,))

# The three states must stay DISTINGUISHABLE at the reader (the outcome above is 'open' for both, so only
# the reader's own return value can prove 'could not read' never collapses into 'read, found nothing').
_saved_log = m.DISPATCH_LOG
try:
    m.DISPATCH_LOG = "/nonexistent/grw-dispatch.log"
    unreadable = m._read_gate_verdicts()
    _efd, _epath = tempfile.mkstemp(prefix="grw-empty-log-"); os.close(_efd)
    m.DISPATCH_LOG = _epath
    empty = m._read_gate_verdicts()
    os.unlink(_epath)
finally:
    m.DISPATCH_LOG = _saved_log
check(unreadable is None and empty == [],
      "reader: missing log → None ('cannot know'), empty log → [] ('read, none') — never the same value",
      "reader collapsed unreadable/empty: unreadable=%r empty=%r" % (unreadable, empty))

# ── 6. bead query failed → nothing closed ─────────────────────────────────────────────────────────
closes, calls, _ = sweep([passed(T + 600)], [bead("ga-x6", T)], list_fails=True)
check(closes == [], "bd list failed → fail-safe skip, nothing closed", "closed with no bead list: %r" % (closes,))

# ── 7. an OWNED bead is never touched (a dog/Mayor is on it) ──────────────────────────────────────
closes, _, _ = sweep([passed(T + 600)], [bead("ga-x7", T, assignee="mayor")])
check(closes == [], "bead with an assignee → left alone", "closed a bead somebody owns: %r" % (closes,))

# ── 8. unparsable created_at → cannot order → stays open ──────────────────────────────────────────
closes, _, _ = sweep([passed(T + 600)], [bead("ga-x8", "not-a-date")])
check(closes == [], "unparsable created_at → stays OPEN (unknown age, never 'resolved')", "closed with an unparsable created_at: %r" % (closes,))

# ── 9. mixed set: only the bead older than the verdict closes ─────────────────────────────────────
closes, _, _ = sweep([passed(T + 600)], [bead("ga-old", T), bead("ga-new", T + 1200)])
check([c[0] for c in closes] == ["ga-old"], "old bead closes, bead created AFTER the verdict stays open", "wrong subset closed: %r" % (closes,))

# ── 10. digest / non-dispatcher lines that merely CONTAIN 'Gate PASSED' are not verdicts ──────────
noise = ["%s [some-other] Logged for digest (infra mirror off): Quality Gate PASSED\n" % logts(T + 600),
         "%s [some-other] Logged for digest (infra mirror off): 🤖 Pilot Gate PASSED\n" % logts(T + 700),
         "%s [quality-gate-dispatcher] Gate FAILED: Merge failed after all-PASS verdict. Merge result: x\n" % logts(T + 800)]
closes, _, _ = sweep(noise, [bead("ga-x10", T)])
check(closes == [], "digest lines / merge-failure lines are not verdicts → stays OPEN", "closed on a non-verdict line: %r" % (closes,))

# ── 11. a non-UTF-8 byte in the log must not blank the read (ga-b1iulk class) ─────────────────────
raw = b"\xff\xfe garbage forensics line\n" + passed(T + 600).encode("utf-8")
closes, _, _ = sweep([], [bead("ga-x11", T)], log_bytes=raw)
check([c[0] for c in closes] == ["ga-x11"], "an odd byte in the log does not hide the verdict → closed", "non-UTF-8 byte broke the read: %r" % (closes,))

# ── 12. bd close failing must not crash and must not be reported as closed ────────────────────────
closes, _, ledger = sweep([passed(T + 600)], [bead("ga-x12", T)], close_rc=1)
check(not any(e.get("event") == "closed_recovered_repair_audit" for e in ledger),
      "bd close returned nonzero → NOT recorded as closed (retried next sweep)", "recorded a close that failed: %r" % (ledger,))

# ── 13. dry-run: no bd close, but a would_ ledger line ────────────────────────────────────────────
closes, _, ledger = sweep([passed(T + 600)], [bead("ga-x13", T)], dry_run=True)
check(closes == [] and any(e.get("event") == "would_close_recovered_repair_audit" for e in ledger),
      "GRW_DRY_RUN → no bd close, 'would_close' ledger record", "dry-run misbehaved: closes=%r ledger=%r" % (closes, ledger))

# ── 14. the list query is scoped by the label and lifts bd's silent 50-row cap ────────────────────
_, calls, _ = sweep([passed(T + 600)], [bead("ga-x14", T)])
lq = [c for c in calls if "list" in c]
check(lq and m.REPAIR_AUDIT_LABEL in lq[0] and "--limit" in lq[0] and lq[0][lq[0].index("--limit") + 1] == "0",
      "the sweep lists ONLY REPAIR_AUDIT_LABEL beads, with --limit 0 (ga-21kmp)", "list query wrong: %r" % (lq,))

# ── 15. pure decision function: the four states ───────────────────────────────────────────────────
v = [(T - 600, "old"), (T + 600, "first-after"), (T + 900, "later")]
check(m.repair_audit_verdict(T, v) == ("close", (T + 600, "first-after")), "pure: closes on the EARLIEST verdict after created_at", "pure close wrong")
check(m.repair_audit_verdict(T, [(T - 5, "x")])[0] == "keep:no-verdict", "pure: only-older verdicts → keep:no-verdict", "pure no-verdict wrong")
check(m.repair_audit_verdict(T, None)[0] == "keep:unreadable", "pure: None (unreadable) → keep:unreadable", "pure unreadable wrong")
check(m.repair_audit_verdict(None, v)[0] == "keep:unknown-age", "pure: no created_at → keep:unknown-age", "pure unknown-age wrong")
check(m.repair_audit_verdict(T, [(T, "same-second")])[0] == "keep:no-verdict", "pure: a verdict in the SAME second is not 'after' (strict)", "pure strictness wrong")

# ══ Part 2 — the REPAIR names WHAT is stuck ═══════════════════════════════════════════════════════
def inflight_line(run_id="ga-q2n5yw", branch="crew/ps-worker/ps-5c35", got=0, elapsed=860, timeout=2520):
    return ("%s [quality-gate-dispatcher] Phase C: gate-run %s (branch=%s) still in flight "
            "(%d/1 verdicts, %ds/%ds) — leaving for a future sweep.\n" % (logts(NOW - 30), run_id, branch, got, elapsed, timeout))

def stuck(lines, active=0):
    fd, path = tempfile.mkstemp(prefix="grw-dispatch-log-")
    try:
        with os.fdopen(fd, "w") as f:
            f.writelines(lines)
        saved = (m.DISPATCH_LOG, m.sh)
        m.DISPATCH_LOG = path
        m.sh = lambda args, timeout=20, stdin=None: CP(json.dumps({"sessions": [{"template": "gate-reviewer", "state": "active"}] * active})
                                                        if "session" in args else "[]")
        try:
            return m.stuck_dispatching_detail(), m.stuck_dispatching()
        finally:
            m.DISPATCH_LOG, m.sh = saved
    finally:
        os.unlink(path)

(det, boolean) = stuck([inflight_line()])
check(det == (True, "ga-q2n5yw", "crew/ps-worker/ps-5c35") and boolean is True,
      "stuck_dispatching_detail() returns (True, run_id, branch); stuck_dispatching() still a plain True",
      "detail/bool wrong: %r %r" % (det, boolean))
(det, boolean) = stuck([inflight_line()], active=1)
check(det == (False, None, None) and boolean is False, "not stuck → (False, None, None) / False", "not-stuck shape wrong: %r %r" % (det, boolean))

# The alarm bead itself: title + body name the run/branch, label + no assignee.
creates = []
label_adds = []
def cap_sh(args, timeout=20, stdin=None):
    if "create" in args:
        creates.append((list(args), stdin))
        return CP(json.dumps([{"id": "ga-newrepair"}]))
    if "label" in args and "add" in args:
        label_adds.append(list(args))
    return CP("")
saved_sh, saved_mayor = m.sh, m.mayor_session
m.sh, m.mayor_session = cap_sh, (lambda: None)
try:
    reason = "marcador dispatching travado sem revisores ativos (run ga-q2n5yw, branch crew/ps-worker/ps-5c35)"
    how, sid = m.spawn_repair_agent(reason, "/tmp/diag", 0, "gate")     # dolt_hits=0 → the unrouted audit path
finally:
    m.sh, m.mayor_session = saved_sh, saved_mayor
check(len(creates) == 1, "exactly one audit bead created on the no-Dolt-signal path", "creates=%d" % len(creates))
if creates:
    cargs, cbody = creates[0]
    title = cargs[cargs.index("create") + 1]
    check("ga-q2n5yw" in title and "crew/ps-worker/ps-5c35" in title,
          "TITLE names the stuck run + branch (six identical-looking cards was half the bug)", "title does not name run/branch: %r" % title)
    check("O QUE TRAVOU" in cbody and "ga-q2n5yw" in cbody and "crew/ps-worker/ps-5c35" in cbody,
          "BODY opens with what is stuck and names run + branch", "body does not name run/branch")
    check("FECHA sozinho" in cbody, "BODY says the watchdog closes it itself (so the Mayor knows not to act on a stale card)", "body omits the auto-close contract")
    labels = cargs[cargs.index("-l") + 1].split(",") if "-l" in cargs else []
    check(m.REPAIR_AUDIT_LABEL in labels,
          "created WITH REPAIR_AUDIT_LABEL atomically (the sweep finds the bead by it; no label-add window)", "audit label not on the create: %r" % (labels,))
    check(any("pilot:no-auto-dispatch" in c and "ga-newrepair" in c for c in label_adds),
          "pilot:no-auto-dispatch veto still applied to the new bead (ga-rwpwz8 invariant untouched)", "no pilot:no-auto-dispatch label add: %r" % (label_adds,))
    check("--assignee" not in cargs, "still UNASSIGNED (no gc.routed_to — ga-rwpwz8 invariant)", "audit bead got an assignee: %r" % (cargs,))

# main() must actually feed the detail into the reason (structural — main() is an endless loop).
import inspect
src = inspect.getsource(m.main)
check("stuck_dispatching_detail()" in src and "stuck_run" in src and "reason +=" in src,
      "main() unpacks stuck_dispatching_detail() and appends run/branch to the alarm reason", "main() does not carry run/branch into the reason")
check("close_recovered_repair_audit_beads(now)" in src, "main() runs the FIX 10 sweep every loop", "FIX 10 sweep is not wired into main()")

print("\nrepair-audit-autoclose selftest: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
