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
# A verdict is a log ENTRY, not a physical line: fixtures here use the production shape (one prefixed line + the
# reviewer's prefix-less continuation lines, the TIMEOUT sentence ending the last one) — gate-run ga-ic6882.
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
    # The REAL shape of a reviewer FAIL entry (quality-gate-dispatcher.sh:9882 → log "Gate FAILED: $FAIL_REASONS"): ONE prefixed
    # line, then the reviewer's multi-line comment WITHOUT a prefix. Measured on the live log 29/09: 448 of 448 such entries
    # are multi-line, 0 single-line — so a fixture that puts the whole FAIL on one physical line tests a shape production never emits.
    return ("%s [quality-gate-dispatcher] Gate FAILED: Reviewer 1 FAIL: VERDICT: FAIL\n"
            "Lens: CORRECTNESS. Reviewed abc123.\n"
            "\n"
            "Blocking issue 1: the guard never fires.\\n\n" % logts(epoch))

def later(epoch):
    # any LATER entry — what the dispatcher writes right after a verdict (labels, nudges…). It is the proof that the entry
    # before it is complete (a multi-line entry that is the LAST thing in the log may still be being written).
    return "%s [quality-gate-dispatcher] Marking ga-x gate:needs-fix (attempt 1/3) for autonomous Pilot re-dispatch\n" % logts(epoch)

def timeout_fail(epoch):
    return "%s [quality-gate-dispatcher] Gate FAILED: TIMEOUT: reviewers did not submit verdicts within 28 minutes.\n" % logts(epoch)

def pilot_passed(epoch, branch="crew/wa-worker/wa-2auxx"):
    # The REAL Pilot-origin PASS form: quality-gate-dispatcher.sh:8232 puts " (origin=Pilot)" BEFORE the colon.
    # 209 of 1184 PASS lines in the live log (18%) are this form — the first cut of the sweep could not see them.
    return "%s [quality-gate-dispatcher] Gate PASSED (origin=Pilot): branch=%s tier=NON-CODE merge_sha=abc123 elapsed=412s\n" % (logts(epoch), branch)

def composite_fail(epoch):
    # quality-gate-dispatcher.sh:9882 + :10535 (ga-h8vc8y): a Phase C timeout that ALSO collected a real reviewer FAIL.
    # FAIL_REASONS = "Reviewer 1 FAIL: <multi-line comment>" + a LITERAL backslash-n + "TIMEOUT: …", and log() writes only the
    # first line with the prefix — so the TIMEOUT sentence ends the LAST CONTINUATION line. This is the shape gate-run ga-ic6882
    # showed the first cut could not see (its fixture had the whole thing on one physical line: 0 of 448 in production).
    return ("%s [quality-gate-dispatcher] Gate FAILED: Reviewer 1 FAIL: VERDICT: FAIL\n"
            "Lens: CORRECTNESS. Reviewed abc123.\n"
            "\n"
            "Non-blocking findings: none\\nTIMEOUT: reviewers did not submit verdicts within 34 minutes.\n" % logts(epoch))

def phys(*chunks):
    # the reader gets PHYSICAL lines (str.splitlines of the log bytes) — flatten multi-line fixtures the same way.
    return "".join(chunks).splitlines()

def bead(bid, created, assignee=""):
    return {"id": bid, "created_at": created if isinstance(created, str) else iso(created), "assignee": assignee,
            "status": "open", "labels": ["pilot:no-auto-dispatch", m.REPAIR_AUDIT_LABEL]}

class CP:
    def __init__(self, stdout="", returncode=0):
        self.stdout, self.returncode = stdout, returncode

def sweep(log_lines, beads, list_fails=False, close_rc=0, log_missing=False, dry_run=False, log_bytes=None, repeat=1,
          enabled=True, close_enabled=True, max_per_sweep=None):
    """Run close_recovered_repair_audit_beads() `repeat` times against a temp dispatcher log. Returns
    (closes, calls, ledger) — closes = [(bead_id, reason)] for every `bd close` issued.
    enabled / close_enabled / max_per_sweep drive the two kill switches and the per-sweep cap (restored afterwards)."""
    fd, path = tempfile.mkstemp(prefix="grw-dispatch-log-")
    lfd, lpath = tempfile.mkstemp(prefix="grw-recovery-log-")
    os.close(lfd)
    closes, calls = [], []
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(log_bytes if log_bytes is not None else "".join(log_lines).encode("utf-8"))
        saved = (m.DISPATCH_LOG, m.sh, m.RECOVERY_LOG, m.GRW_DRY_RUN, m.GRW_ENABLED,
                 m.GRW_CLOSE_REPAIR_AUDIT_ENABLED, m.REPAIR_AUDIT_MAX_PER_SWEEP)
        m.DISPATCH_LOG = "/nonexistent/grw-dispatch.log" if log_missing else path
        m.RECOVERY_LOG = lpath
        m.GRW_DRY_RUN = dry_run
        m.GRW_ENABLED = enabled
        m.GRW_CLOSE_REPAIR_AUDIT_ENABLED = close_enabled
        if max_per_sweep is not None:
            m.REPAIR_AUDIT_MAX_PER_SWEEP = max_per_sweep

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
            for _ in range(repeat):
                m.close_recovered_repair_audit_beads(NOW)
        finally:
            (m.DISPATCH_LOG, m.sh, m.RECOVERY_LOG, m.GRW_DRY_RUN, m.GRW_ENABLED,
             m.GRW_CLOSE_REPAIR_AUDIT_ENABLED, m.REPAIR_AUDIT_MAX_PER_SWEEP) = saved
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
closes, _, _ = sweep([reviewer_fail(T + 600), later(T + 660)], [bead("ga-x3", T)])
check([c[0] for c in closes] == ["ga-x3"], "a (multi-line) reviewer FAIL after T counts as a verdict → closed", "reviewer FAIL not counted: %r" % (closes,))
check(closes and "Gate FAILED: Reviewer 1 FAIL" in closes[0][1] and "Blocking issue" not in closes[0][1],
      "the close reason quotes the entry's PREFIXED head line only, not the reviewer's whole comment",
      "close reason quotes the wrong text for a multi-line entry: %r" % (closes,))

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
# The merge-failure line is FOLLOWED by a later entry (gate-run ga-gbdzt9). A FAILED entry that is the LAST thing in the log is
# dropped by the completeness rule (17b) before the reviewer-FAIL prefix guard is ever reached — the first cut of this fixture
# ended on it, so the whole check passed with that guard deleted. Only the guard may reject it here.
noise = ["%s [some-other] Logged for digest (infra mirror off): Quality Gate PASSED\n" % logts(T + 600),
         "%s [some-other] Logged for digest (infra mirror off): 🤖 Pilot Gate PASSED\n" % logts(T + 700),
         "%s [quality-gate-dispatcher] Gate FAILED: Merge failed after all-PASS verdict. Merge result: x\n" % logts(T + 800),
         later(T + 810)]
closes, _, _ = sweep(noise, [bead("ga-x10", T)])
check(closes == [], "digest lines / merge-failure lines are not verdicts → stays OPEN", "closed on a non-verdict line: %r" % (closes,))

# ── 10b. every non-reviewer `Gate FAILED:` shape in the live log is not a verdict (the prefix guard, in isolation) ──
# One REAL line per shape: every non-reviewer, non-TIMEOUT `Gate FAILED:` form present in the live dispatcher log on 29/09
# (TIMEOUT has its own checks, #3/#16). That is what the log HAS held, not a proof of what the dispatcher could ever emit — the
# guard rejects by exclusion, so a new form is rejected too. GATE_REVIEWER_FAIL_RE.match(...) is the ONLY thing between these and
# a "recovery" that closes a real alarm (the destructive direction). Each entry is followed by a LATER entry, so it is FINISHED (the
# completeness rule cannot be what rejects it) and none carries the TIMEOUT sentence (the sentinel test cannot either).
# Gate-run ga-gbdzt9: with the guard replaced by `if False:` the suite stayed 62/62 green.
NONREVIEWER_FAILED = [
    ("merge failed (rebase)",   "Merge failed after all-PASS verdict. Merge result: failed_merge_time_rebase. Check git state of rig whatsapp_automation."),
    ("merge failed (conflict)", "Merge failed after all-PASS verdict. Merge result: failed_merge_time_conflict. Check git state of rig whatsapp_automation."),
    ("dead reviewer (verdict:pending)", "Reviewer 1 verdict:pending: verdict bead closed without explicit PASS (no verdict:PASS label and no explicit PASS comment).\\n"),
    ("live re-check unreadable", "the live re-check immediately before push could not read source bead wa-zdzc8 (bd show failed, returned empty, or did not parse) — refusing to push blind (ga-360a7l)"),
    ("source bead parked", "Source bead wa-llq1a now carries a park-worthy label (park:needs-human) applied after this gate-run began — re-checked live immediately before merge (ga-lxz5w)."),
    ("source bead already closed", "Source bead ga-rhzbii is already closed — a different branch/process resolved it after this gate-run began (ga-lxz5w: 2-branch race, sequential variant)."),
    ("commit already has a FAIL", "Commit 6b84f74f712f81e0d3d8c4cb2ea025e9942292ae already carries a recorded FAIL verdict from an earlier, independent gate-run (fail-closed by SHA, ga-nooaw)."),
    ("branch does not name the bead", "Branch crew/wa-worker/wa-zyfoe's own commits (1 unique vs main) do not reference source bead wa-zyfoe anywhere (ga-y9a1d: branch-content-coherence)."),
]
def failed_entry(epoch, text, origin=""):
    return "%s [quality-gate-dispatcher] Gate FAILED%s: %s\n" % (logts(epoch), origin, text)
for _name, _txt in NONREVIEWER_FAILED:
    _v = m._gate_verdicts_in(phys(failed_entry(T + 600, _txt), later(T + 660)))
    check(_v == [], "pure: a FINISHED '%s' FAILED entry is not a verdict" % _name,
          "a '%s' FAILED entry was read as a gate verdict: %r" % (_name, _v))
_v = m._gate_verdicts_in(phys(failed_entry(T + 600, NONREVIEWER_FAILED[0][1], origin=" (origin=Pilot)"), later(T + 660)))
check(_v == [], "pure: …and the same with the Pilot-origin tag on the FAILED line", "an origin-tagged merge failure was read as a verdict: %r" % (_v,))
_shapes_log = "".join(failed_entry(T + 600 + 10 * i, t) + later(T + 605 + 10 * i) for i, (_n, t) in enumerate(NONREVIEWER_FAILED))
closes, _, _ = sweep([_shapes_log], [bead("ga-x10b", T)])
check(closes == [], "sweep: every non-reviewer FAILED shape, each finished → the alarm stays OPEN",
      "closed on a non-reviewer FAILED entry: %r" % (closes,))
# positive control: a real, finished reviewer FAIL AFTER them still closes, and the evidence is IT, not one of the non-verdicts
closes, _, _ = sweep([_shapes_log, reviewer_fail(T + 900), later(T + 960)], [bead("ga-x10c", T)])
check([c[0] for c in closes] == ["ga-x10c"] and "Reviewer 1 FAIL" in closes[0][1] and "Merge failed" not in closes[0][1],
      "…and a real reviewer FAIL after them closes it, quoting THAT verdict (the non-verdicts neither mask nor replace it)",
      "wrong evidence / not closed: %r" % (closes,))

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
check(lq and "--status" in lq[0] and lq[0][lq[0].index("--status") + 1] == "open",
      "…and ONLY open ones (--status open) — a closed alarm is never re-closed, nor a stale one re-quoted",
      "list query is not scoped to open beads: %r" % (lq,))

# ── 15. pure decision function: the four states ───────────────────────────────────────────────────
v = [(T - 600, "old"), (T + 600, "first-after"), (T + 900, "later")]
check(m.repair_audit_verdict(T, v) == ("close", (T + 600, "first-after")), "pure: closes on the EARLIEST verdict after created_at", "pure close wrong")
check(m.repair_audit_verdict(T, [(T - 5, "x")])[0] == "keep:no-verdict", "pure: only-older verdicts → keep:no-verdict", "pure no-verdict wrong")
check(m.repair_audit_verdict(T, None)[0] == "keep:unreadable", "pure: None (unreadable) → keep:unreadable", "pure unreadable wrong")
check(m.repair_audit_verdict(None, v)[0] == "keep:unknown-age", "pure: no created_at → keep:unknown-age", "pure unknown-age wrong")
check(m.repair_audit_verdict(T, [(T, "same-second")])[0] == "keep:no-verdict", "pure: a verdict in the SAME second is not 'after' (strict)", "pure strictness wrong")
# the decision function's own doc must not promise what "keep:no-verdict" cannot know (same class as the card body, ga-lor9cy #2)
_rav_doc = m.repair_audit_verdict.__doc__ or ""
check("gate not recovered" not in _rav_doc and "no evidence of recovery" in _rav_doc,
      "repair_audit_verdict doc says keep:no-verdict = 'no evidence of recovery', not the absolute 'gate not recovered'",
      "repair_audit_verdict doc still claims the gate has not recovered: %r" % (_rav_doc[:300],))

# ── 16. THE Pilot-origin PASS (gate-run ga-lor9cy, blocking issue 1): 18% of production PASS lines ──
# A recovered gate whose latest verdict is a Pilot merge kept its alarm open until the next PLAIN pass
# (median 19 min later, p90 78 min, max 6.6 h) — the very symptom ga-hqrnmu exists to remove — and silently.
closes, _, _ = sweep([pilot_passed(T + 600)], [bead("ga-x16", T)])
check([c[0] for c in closes] == ["ga-x16"],
      "a Pilot-origin 'Gate PASSED (origin=Pilot):' after T counts as a verdict → closed",
      "Pilot-origin PASS was not recognised as a verdict: %r" % (closes,))
check(closes and "origin=Pilot" in closes[0][1] and "wa-2auxx" in closes[0][1],
      "the close reason quotes the Pilot line (branch + origin) as evidence",
      "close reason does not quote the Pilot verdict: %r" % (closes,))
_pl = m._gate_verdicts_in([pilot_passed(T + 600), passed(T + 700)])
check(len(_pl) == 2, "pure: _gate_verdicts_in sees BOTH the Pilot-origin and the plain PASS form",
      "pure reader missed a PASS form: %r" % (_pl,))
# origin tag on a FAILED line must not turn a non-verdict into one: the TIMEOUT rule still applies.
_of = m._gate_verdicts_in(["%s [quality-gate-dispatcher] Gate FAILED (origin=Pilot): TIMEOUT: reviewers did not submit verdicts\n" % logts(T + 600)])
check(_of == [], "an origin-tagged FAILED that is a TIMEOUT is still NOT a verdict", "origin-tagged TIMEOUT counted as a verdict: %r" % (_of,))

# ── 17. composite: a reviewer FAIL collected by a run that ALSO timed out (ga-h8vc8y) → stays open ─────
# The run timed out — that is the fault these alarms report. Leaving it open only ever costs a longer alarm.
# The REAL shape (gate-run ga-ic6882): the TIMEOUT sentence is on the last CONTINUATION line of a multi-line entry, so a
# reader that looks at physical lines never sees it. The composite is followed by a later entry (as it always is in
# production) so the completeness rule cannot be what keeps it open — only the sentinel test can.
closes, _, _ = sweep([composite_fail(T + 600), later(T + 660)], [bead("ga-x17", T)])
check(closes == [], "reviewer-FAIL + TIMEOUT (real multi-line shape, TIMEOUT on the last continuation line) → stays OPEN",
      "closed on a composite TIMEOUT entry — a timed-out run read as a recovery: %r" % (closes,))
_cv = m._gate_verdicts_in(phys(composite_fail(T + 600), later(T + 660)))
check(_cv == [], "pure: the composite entry is not a verdict", "pure reader counted the composite as a verdict: %r" % (_cv,))
closes, _, _ = sweep([composite_fail(T + 600), later(T + 660), pilot_passed(T + 900)], [bead("ga-x17b", T)])
check([c[0] for c in closes] == ["ga-x17b"] and "origin=Pilot" in closes[0][1],
      "…and a real verdict AFTER the composite entry still closes it, quoting THAT verdict, not the composite",
      "composite entry masked or replaced the real verdict: %r" % (closes,))
# the plain (non-composite) multi-line reviewer FAIL right before it must NOT be swept up by the sentinel test
closes, _, _ = sweep([reviewer_fail(T + 600), later(T + 660)], [bead("ga-x17c", T)])
check([c[0] for c in closes] == ["ga-x17c"],
      "a multi-line reviewer FAIL WITHOUT the TIMEOUT sentence is still a verdict (the sentinel test does not over-reach)",
      "the composite guard swallowed a plain reviewer FAIL: %r" % (closes,))

# ── 17b. an entry is only trusted once a LATER entry proves it is complete (the third state: 'still being written') ──
# The TIMEOUT tail is the LAST thing written into a multi-line FAILED entry. An entry that is the final thing in the
# log cannot be told from a plain FAIL, so it is not counted yet; the next log line resolves it either way.
closes, _, _ = sweep([reviewer_fail(T + 600)], [bead("ga-x17d", T)])
check(closes == [], "a FAILED entry that is the LAST thing in the log → not counted yet (may be half-written) → stays OPEN",
      "closed on a possibly half-written FAILED entry: %r" % (closes,))
_lv = m._gate_verdicts_in(phys(reviewer_fail(T + 600)))
check(_lv == [], "pure: the trailing FAILED entry is not a verdict until a later entry exists", "pure reader counted an unfinished entry: %r" % (_lv,))
_lv = m._gate_verdicts_in(phys(reviewer_fail(T + 600), later(T + 601)))
check(len(_lv) == 1, "pure: …and the same entry IS a verdict once a later entry exists", "pure reader dropped a finished entry: %r" % (_lv,))
closes, _, _ = sweep([passed(T + 600)], [bead("ga-x17e", T)])
check([c[0] for c in closes] == ["ga-x17e"],
      "a single-line PASS as the LAST line still closes at once (no completeness wait — it is one atomic line)",
      "a trailing PASS was held back: %r" % (closes,))

# ── 17c. grouping: continuation lines belong to the entry above; a window cut mid-entry drops its orphan lines ──
_ents = m._log_entries(phys(reviewer_fail(T + 600), later(T + 660)))
check(len(_ents) == 2 and len(_ents[0][1]) == 3 and _ents[0][2] is True and _ents[1][2] is False,
      "pure: _log_entries groups the 3 continuation lines under their prefixed head; only the LAST entry is unfinished",
      "_log_entries grouped wrongly: %r" % (_ents,))
_orphan = m._gate_verdicts_in(["Non-blocking findings: none\\nTIMEOUT: reviewers did not submit verdicts within 34 minutes."]
                              + phys(passed(T + 600)))
check(len(_orphan) == 1 and "Gate PASSED" in _orphan[0][1],
      "pure: continuation lines BEFORE the first prefixed line (tail read cut mid-entry) are dropped, and do not hide the next verdict",
      "orphan continuation line broke the reader: %r" % (_orphan,))
# an INDENTED quote of a verdict inside a comment is a continuation line, never an entry (the live log holds one, ga-ic6882's own feedback)
_iq = m._gate_verdicts_in(phys(reviewer_fail(T - 600),
                               "  %s [quality-gate-dispatcher] Gate PASSED: branch=x tier=CODE\n" % logts(T + 600),
                               later(T - 500)))
check(len(_iq) == 1 and _iq[0][0] < T,
      "pure: an indented quote of a PASS line inside a reviewer comment is not a verdict (only the real FAIL, dated before T, is)",
      "an indented quote was read as a verdict: %r" % (_iq,))

# ── 18. dry-run must not write the same would_close ledger line on every 120s sweep ─────────────────
closes, _, ledger = sweep([passed(T + 600)], [bead("ga-x18", T)], dry_run=True, repeat=3)
_wc = [e for e in ledger if e.get("event") == "would_close_recovered_repair_audit" and e.get("bead") == "ga-x18"]
check(closes == [] and len(_wc) == 1,
      "dry-run over 3 sweeps → exactly ONE would_close ledger line for the bead (no unbounded growth)",
      "dry-run ledger grew per sweep: %d lines" % len(_wc))

# ── 19. the sweep DECIDES a close from the list → it must read LIVE, not through the 5s cache ─────────
# bd-list-cached.sh's own header: a call site that itself closes a bead from the result should use BD_CACHE_FRESH=1.
_, calls, _ = sweep([passed(T + 600)], [bead("ga-x19", T)])
lq = [c for c in calls if "list" in c]
check(lq and "BD_CACHE_FRESH=1" in lq[0] and lq[0].index("BD_CACHE_FRESH=1") < lq[0].index("list"),
      "the open-bead list is a FRESH read (BD_CACHE_FRESH=1) — the ownership/open check that gates a close is never cached",
      "list query is not a fresh read: %r" % (lq,))

# ── 20. last_pass_epoch() has the SAME blindness class → same recognizer, so a Pilot PASS counts ───────
def last_pass(lines):
    fd, path = tempfile.mkstemp(prefix="grw-dispatch-log-")
    try:
        with os.fdopen(fd, "w") as f:
            f.writelines(lines)
        saved = m.DISPATCH_LOG
        m.DISPATCH_LOG = path
        try:
            return m.last_pass_epoch()
        finally:
            m.DISPATCH_LOG = saved
    finally:
        os.unlink(path)
_e = T + 600
check(int(last_pass([pilot_passed(_e)])) == int(_e),
      "last_pass_epoch() finds a Pilot-origin PASS (the 'gate recovered' reset no longer waits for a plain pass)",
      "last_pass_epoch() is blind to the Pilot-origin PASS: %r" % (last_pass([pilot_passed(_e)]),))
check(last_pass(["%s [some-other] Logged for digest (infra mirror off): 🤖 Pilot Gate PASSED\n" % logts(_e)]) == 0,
      "…while a digest line that merely says 'Pilot Gate PASSED' is still not a pass", "digest noise counted as a pass")
check(last_pass([composite_fail(_e), timeout_fail(_e + 5)]) == 0,
      "…and FAILED lines are never a pass", "a FAILED line was counted as a pass")

# ── 21. QUOTED verdict text inside a multi-line reviewer comment is NOT a log line ───────────────────
# dispatcher log() is `echo "[ts] [quality-gate-dispatcher] $*"`; a reviewer's FAIL comment is multi-line, so its
# 2nd+ lines land in the log WITHOUT the prefix. When such a comment QUOTES a verdict line (a reviewer explaining
# a regex bug does exactly that), an unanchored recognizer takes the quote as a verdict — and log_ts_epoch()
# then dates it by the quoted timestamp. Measured on the live log 29/09: 1 such line in ~1700 verdict-shaped
# lines, and it is the very feedback of this bead's first gate run (ga-lor9cy). It fails in the DESTRUCTIVE
# direction (a fabricated verdict closes a real alarm), so the line must start with the dispatcher's prefix.
def quoted_in_comment(epoch_real, epoch_quoted):
    return [
        "%s [quality-gate-dispatcher] Gate FAILED: Reviewer 1 FAIL: VERDICT: FAIL\n" % logts(epoch_real),
        "Lens: CORRECTNESS. Fact-checked: m._gate_verdicts_in([\"%s [quality-gate-dispatcher] Gate PASSED "
        "(origin=Pilot): branch=crew/wa-worker/wa-2auxx tier=NON-CODE\"]) returns []\n" % logts(epoch_quoted),
        "Plain form quoted too: %s [quality-gate-dispatcher] Gate PASSED: branch=x tier=CODE\n" % logts(epoch_quoted),
        later(epoch_real + 5),      # the entry is finished, so the real FAIL is countable — only the QUOTES must not be
    ]
# real reviewer-FAIL BEFORE the bead exists; the only thing AFTER T is text quoted inside its comment
closes, _, _ = sweep(quoted_in_comment(T - 600, T + 600), [bead("ga-x21", T)])
check(closes == [],
      "a verdict QUOTED on a continuation line (no `[ts] [quality-gate-dispatcher]` prefix) is not a verdict → stays OPEN",
      "closed on quoted text inside a reviewer comment: %r" % (closes,))
_qv = m._gate_verdicts_in(quoted_in_comment(T - 600, T + 600))
check(len(_qv) == 1 and _qv[0][0] < T,
      "pure: only the REAL prefixed line is a verdict, dated by ITS timestamp (not the quoted one)",
      "pure reader took quoted text as a verdict: %r" % (_qv,))
check(last_pass(quoted_in_comment(T - 600, T + 600)) == 0,
      "last_pass_epoch() does not take quoted 'Gate PASSED' text as a pass either",
      "last_pass_epoch() returned %r for quoted text" % (last_pass(quoted_in_comment(T - 600, T + 600)),))

# ── 22. guards the mutation sweep found unpinned (gate-run ga-gbdzt9's class: a check that passes without exercising its guard) ──
# Method: each guard in the FIX 10 code was replaced, one at a time, by its inert form; a guard whose removal left the suite green
# had no test. The ones below are the survivors that were real gaps (the reviewer-FAIL prefix guard is pinned by 10b above).

# 22a. the TIMEOUT sentinel can sit on the HEAD line too: a reviewer comment with no line break makes the composite ONE physical line
# (FAIL_REASONS = "Reviewer 1 FAIL: <comment>" + literal backslash-n + "TIMEOUT: …"). The live log has 0 of these today (gate-run
# ga-ic6882 measured 448 of 448 reviewer-FAIL entries multi-line), which is exactly why a reader that only searches the continuation lines would ship unnoticed until one appears.
def oneline_composite(epoch):
    return ("%s [quality-gate-dispatcher] Gate FAILED: Reviewer 1 FAIL: VERDICT: FAIL. Non-blocking: none"
            "\\nTIMEOUT: reviewers did not submit verdicts within 34 minutes.\n" % logts(epoch))
_oc = m._gate_verdicts_in(phys(oneline_composite(T + 600), later(T + 660)))
check(_oc == [], "pure: a composite whose TIMEOUT sentence is on the HEAD line (one-line comment) is not a verdict",
      "a one-line composite was read as a verdict — a timed-out run counted as a recovery: %r" % (_oc,))
closes, _, _ = sweep([oneline_composite(T + 600), later(T + 660)], [bead("ga-x22a", T)])
check(closes == [], "sweep: the one-line composite leaves the alarm OPEN", "closed on a one-line composite: %r" % (closes,))

# 22b. an UNDATABLE verdict (the regex accepts any digits: month 13, hour 99) proves nothing about being AFTER the bead → skipped,
# never carried as (None, line) — comparing None to the bead's epoch would crash the whole sweep and strand every alarm behind it.
_bad_ts = "[2026-13-45 99:99:99] [quality-gate-dispatcher] Gate PASSED: branch=fix/ga-undatable tier=CODE merge_sha=abc elapsed=1s\n"
_ud = m._gate_verdicts_in([_bad_ts])
check(_ud == [], "pure: a verdict line whose timestamp does not parse is skipped, not returned undated", "undatable verdict returned: %r" % (_ud,))
try:
    closes, _, _ = sweep([_bad_ts, passed(T + 700)], [bead("ga-x22b", T)])
except Exception as ex:          # noqa: BLE001 — the point is that NO exception escapes the sweep
    closes = ex
check(isinstance(closes, list) and [c[0] for c in closes] == ["ga-x22b"] and "ga-7vmcr1" in closes[0][1] and "undatable" not in closes[0][1],
      "sweep: an undatable verdict neither crashes the sweep nor becomes the evidence — the next datable verdict closes the bead",
      "undatable verdict broke the sweep or was quoted as evidence: %r" % (closes,))

# 22c. the per-sweep cap bounds the work of one sweep, OLDEST first (beads deliberately handed over out of age order).
_cap_beads = [bead("ga-c3", T + 3), bead("ga-c1", T + 1), bead("ga-c2", T + 2)]
closes, _, _ = sweep([passed(T + 600)], _cap_beads, max_per_sweep=2)
check([c[0] for c in closes] == ["ga-c1", "ga-c2"],
      "the per-sweep cap holds (REPAIR_AUDIT_MAX_PER_SWEEP=2 → 2 closes, the OLDEST two; the third waits for the next sweep)",
      "cap not honoured or not oldest-first: %r" % ([c[0] for c in closes],))

# 22d. both kill switches turn the sweep off COMPLETELY — not one bd query, not one close. (The card body tells the Mayor that
# 'auto-fechamento desligado' is a reason an alarm stays open; that promise is only true if the switches really do it.)
for _kw, _nm in (({"enabled": False}, "GRW_ENABLED=0"), ({"close_enabled": False}, "GRW_CLOSE_REPAIR_AUDIT_ENABLED=0")):
    closes, calls, _ = sweep([passed(T + 600)], [bead("ga-x22d", T)], **_kw)
    check(closes == [] and calls == [], "%s → the sweep does nothing (no bd query, no close)" % _nm,
          "%s did not switch the sweep off: closes=%r calls=%r" % (_nm, closes, calls))

# 22e. a bd reply that is valid JSON but NOT a list (an error object) is 'query failed' → skip, never iterated as beads.
try:
    closes, _, _ = sweep([passed(T + 600)], {"error": "database is locked"})
except Exception as ex:          # noqa: BLE001
    closes = ex
check(closes == [], "a bd reply that is a JSON object, not a list, is a failed query → nothing closed, nothing raised",
      "a non-list bd reply was treated as beads: %r" % (closes,))

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
    # gate-run ga-lor9cy, blocking issue 2: "still open ⇒ the gate did NOT recover" is false whenever the bead is open for
    # any OTHER reason (kill switch, unreadable log, bead query down, failing bd close, a verdict the recognizer missed).
    check("não viu (ou não conseguiu verificar) um veredito posterior" in cbody,
          "BODY words 'still open' as 'the watchdog did not see (or could not verify) a later verdict' — the ambiguous case is named",
          "body does not state the ambiguity of an open card")
    check("NÃO voltou a produzir" not in cbody and "gate NÃO voltou" not in cbody,
          "BODY no longer claims the absolute 'the gate did NOT resume producing verdicts'",
          "body still asserts the gate did not recover: %r" % (cbody[:400],))
    check("confira o gate" in cbody.lower(), "BODY tells the reader to CHECK the gate rather than assume", "body does not point at checking the gate")
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
