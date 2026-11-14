#!/usr/bin/env bash
# quorum-convergence-watchdog.approved-restore.selftest.sh — ga-btr2dof (follow-up of ga-w6a9xps): the quorum's `reclaim` action stripped story:in-flight to send a bead "back to the
# pool" and never gave story:approved back. The builder's own claim had already dropped it, so a STORY came out with NO story:* label — which auto-refino's RAW sweep reads as a fresh idea
# and sends back to Athos for a second approval (wa-tvrs41.5, 13/11). It also read no exit code and returned True always, so the cycle labelled the quorum `resolved` with nothing done.
# Now: the bead is READ first; story:approved goes back (confirmed by a read-back, not by the exit code) BEFORE story:in-flight comes off; anything not confirmed aborts before the strip (the bead is left
# as it was, or approved+in-flight) and the quorum stays open for the next cycle (bounded by QUORUM_EXEC_MAX_ATTEMPTS).
#
# The fake `bd` is a STRICT stateful store: an argv shape it does not know FAILS the call and is recorded (scenario 10 then fails: a fake that ignores unknown calls passes by construction, and the watchdog's _run swallows a raise), the fixture is the shape of the real
# `bd show --json` (list of one object; a bead with no labels has NO `labels` key — measured 14/11), and the invariant "a story never sits with zero story:* labels" is checked after EVERY call.
#
# Scenarios: 1 fixture shape · 2 _approved_verdict table · 3 _label_set_verified · 4 reclaim on a story (order + invariant) · 5 bd drops the label · 6 unreadable bead (every way a read fails)
#            7 bug / tech-debt feature (Tier-1 bypass) / no-proof feature never get story:approved · 8 label strip fails → assignee/status untouched · 9 _run_cycle retries then gives up · 10 the fake modelled every call
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="${WATCHDOG_UNDER_TEST:-$SCRIPT_DIR/../../../scripts/quorum-convergence-watchdog.py}"
[ -f "$WD" ] || { echo "FAIL: quorum-convergence-watchdog.py not found at $WD"; exit 1; }
PY="${PYTHON3:-/usr/bin/python3}"; [ -x "$PY" ] || PY="$(command -v python3)"

"$PY" -I - "$WD" <<'PY'
import sys, os, types, json, importlib.util, subprocess

PASS = FAIL = 0
# a crash inside the code under test is a FAILURE with a clean line, not a traceback (the node's apport excepthook spins 20 s+ CPU on an uncaught exception)
sys.excepthook = lambda t, v, tb: (print("  BAD: selftest crashed: %s: %s" % (t.__name__, v)), print("SELFTEST FAIL"), sys.stdout.flush(), os._exit(1))
def check(cond, msg_ok, msg_bad):
    global PASS, FAIL
    if cond: PASS += 1; print("  ok: %s" % msg_ok)
    else: FAIL += 1; print("  BAD: %s" % msg_bad)

os.environ["QUORUM_DRY_RUN"] = "0"
led = types.ModuleType("gc_ledger"); led.gc_ledger_append = lambda *a, **k: None; sys.modules["gc_ledger"] = led
spec = importlib.util.spec_from_file_location("qcw_approved_restore", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.BD, m.GC, m.NOTIFY, m.DRY_RUN = "bd", "gc", "notify", False   # the node exports BD_BIN/GC_BIN shims: pin the argv this test matches
m.time.sleep = lambda *_a, **_k: None
EMITS = []
m._emit = lambda tag, msg: EMITS.append((tag, msg))

class R:
    def __init__(self, rc=0, out="", err=""): self.returncode, self.stdout, self.stderr = rc, out, err

UNMODELLED = []   # argv the fake does not know (the watchdog's _run swallows exceptions, so the fake records instead of raising); must stay empty

class Store:
    """ONE bead as bd shows it + the trace of every call. drop_add / drop_remove: labels whose add/remove exits 0 but never lands. stale_after_add: the first N `show` after an add still
    read the pre-add labels. show_rc / show_out / show_raises: the three ways a read fails (non-zero exit, garbage or empty output, subprocess.run itself raising). add_raises: label add raises."""
    def __init__(self, labels, typ="feature", meta=None, drop_add=(), drop_remove=(), show_rc=0, show_out=None, show_raises=False, add_raises=False, stale_after_add=0):
        self.labels, self.typ, self.meta = list(labels), typ, dict(meta if meta is not None else {"pilot.dispatched_at": "1790000000"})
        self.assignee, self.status = "oracle-wa", "in_progress"
        self.drop_add, self.drop_remove = set(drop_add), set(drop_remove)
        self.show_rc, self.show_out, self.show_raises, self.add_raises = show_rc, show_out, show_raises, add_raises
        self.stale_after_add, self._stale_left, self._pre_add = stale_after_add, 0, None
        self.calls, self.trace = [], []
        self.had_story = any(x.startswith("story:") for x in labels)

    def bead(self, labels=None):
        ls = self.labels if labels is None else labels
        b = {"id": "wa-x", "issue_type": self.typ, "status": self.status, "assignee": self.assignee, "metadata": dict(self.meta)}
        if ls: b["labels"] = list(ls)   # the real bd OMITS the key for a bead with no labels
        return b

    def run(self, cmd, capture_output=True, text=True, timeout=None, **_kw):
        cmd = list(cmd); self.calls.append(cmd); verb = cmd[1] if len(cmd) > 1 else ""
        out = R()
        if cmd[0] == "notify": return out
        if verb == "show" and cmd[3:] == ["--json"]:
            if self.show_raises: raise subprocess.TimeoutExpired(cmd, timeout or 0)
            if self.show_rc != 0: return R(self.show_rc, "", "bd: boom")
            if self.show_out is not None: return R(0, self.show_out)
            ls = self._pre_add if self._stale_left > 0 and self._pre_add is not None else self.labels
            if ls is self._pre_add: self._stale_left -= 1
            return R(0, json.dumps([self.bead(ls)]))
        if verb == "label" and len(cmd) == 6 and cmd[2] in ("add", "remove") and cmd[5] == "-q":
            op, lbl = cmd[2], cmd[4]
            if op == "add":
                if self.add_raises: raise OSError("bd: not executable")
                if lbl not in self.drop_add and lbl not in self.labels:
                    self._pre_add = list(self.labels); self._stale_left = self.stale_after_add; self.labels.append(lbl)
            elif lbl not in self.drop_remove:
                self.labels = [x for x in self.labels if x != lbl]
        elif verb == "update" and cmd[3:] == ["--assignee", ""]: self.assignee = ""
        elif verb == "reopen" and len(cmd) == 3: self.status = "open"
        elif verb == "comment" and len(cmd) == 4: pass
        elif verb == "list": out = R(0, "[]")
        else:
            UNMODELLED.append(cmd); return R(1, "", "fake bd: argv shape not modelled")
        if self.had_story: self.trace.append((verb, tuple(cmd[2:5]), [x for x in self.labels if x.startswith("story:")]))
        return out

    def writes(self): return [c for c in self.calls if len(c) > 1 and c[1] in ("label", "update", "reopen", "comment", "close")]
    def zero_story_moments(self): return [t for t in self.trace if not t[2]]

def install(st):
    orig = m.subprocess.run; m.subprocess.run = st.run; return orig

def reclaim(st):
    orig = install(st)
    try: return m._execute_action("wa-x", "reclaim")
    finally: m.subprocess.run = orig

STORY = ["story:in-flight", "pilot:dispatched", "lane:small"]
have = hasattr(m, "_approved_verdict") and hasattr(m, "_label_set_verified")

# ── 1. fixture shape ─────────────────────────────────────────────────────────
print("Scenario 1: the fake bd prints the shape of the real `bd show --json`")
shown = json.loads(Store(STORY).run(["bd", "show", "wa-x", "--json"]).stdout)
check(isinstance(shown, list) and len(shown) == 1 and isinstance(shown[0].get("labels"), list) and isinstance(shown[0].get("metadata"), dict) and {"id", "issue_type", "status", "assignee"} <= set(shown[0]),
      "list of ONE object with labels(list), metadata(dict), issue_type, status, assignee", "fixture shape drifted from the real bd show: %r" % (shown,))
check("labels" not in json.loads(Store([]).run(["bd", "show", "wa-x", "--json"]).stdout)[0], "a bead with no labels has NO `labels` key", "label-less fixture carries a labels key")

# ── 2. verdict table ─────────────────────────────────────────────────────────
print("Scenario 2: _approved_verdict")
if not have: check(False, "", "_approved_verdict/_label_set_verified do not exist in the watchdog (the fix is absent)")
else:
    def vd(labels, typ="feature", meta=None):
        b = {"id": "wa-x", "labels": labels, "issue_type": typ}
        if meta is not None: b["metadata"] = meta
        return m._approved_verdict([b])
    TD = {"pilot.dispatched_at": "1790000000"}
    for name, got, want in [
        ("feature, in-flight, dispatch label",            vd(["story:in-flight", "pilot:dispatched"]),                    "restore"),
        ("story type, in-flight, dispatch label",         vd(["story:in-flight", "pilot:dispatched"], "story"),           "restore"),
        ("proof = pilot.dispatched_at",                   vd(["story:in-flight"], meta=TD),                               "restore"),
        ("proof = story.aprovado_por",                    vd(["story:in-flight"], meta={"story.aprovado_por": "athos"}),  "restore"),
        ("bare object, not wrapped in a list",            m._approved_verdict({"id": "wa-x", "labels": ["story:in-flight", "pilot:dispatched"], "issue_type": "feature"}), "restore"),
        ("NO trace (maybe parked by hand)",               vd(["story:in-flight"]),                                        "no-proof"),
        ("stamps present but empty",                      vd(["story:in-flight"], meta={"pilot.dispatched_at": "", "story.aprovado_por": ""}), "no-proof"),
        ("metadata not a dict is never proof",            vd(["story:in-flight"], meta="oops"),                           "no-proof"),
        ("tech-debt feature: Tier-1 dispatches it with NO approval", vd(["story:in-flight", "pilot:dispatched", "tech-debt"]), "tier1-bypass"),
        ("tech-debt story type",                          vd(["story:in-flight", "pilot:dispatched", "tech-debt"], "story"), "tier1-bypass"),
        ("tech-debt bug is just not a story",             vd(["story:in-flight", "tech-debt"], "bug"),                    "not-story"),
        ("already has story:approved",                    vd(["story:in-flight", "story:approved"]),                      "has-approved"),
        ("no story:in-flight",                            vd(["lane:small"]),                                             "not-in-flight"),
        ("in-flight + story:done (never overwrite)",      vd(["story:in-flight", "story:done"]),                          "other-story-state"),
        ("in-flight + story:triage",                      vd(["story:in-flight", "story:triage"]),                        "other-story-state"),
        ("bug",                                           vd(["story:in-flight"], "bug", TD),                             "not-story"),
        ("task / chore / unknown type",                   (vd(["story:in-flight"], "task", TD), vd(["story:in-flight"], "chore", TD), vd(["story:in-flight"], None, TD)), ("not-story",) * 3),
        ("label-less bead: bd omits `labels`, that is NOT unreadable", m._approved_verdict([{"id": "wa-x", "issue_type": "feature"}]), "not-in-flight"),
        ("labels null",                                   m._approved_verdict([{"id": "wa-x", "labels": None}]),          "not-in-flight"),
        ("None / empty list / a string",                  (m._approved_verdict(None), m._approved_verdict([]), m._approved_verdict("nope")), (None,) * 3),
        ("error envelope (no id, no labels)",             m._approved_verdict([{"error": "not found"}]),                  None),
        ("error envelope WITH an id",                     m._approved_verdict([{"id": "wa-x", "error": "boom"}]),         None),
        ("labels is not a list",                          m._approved_verdict([{"id": "wa-x", "labels": "story:in-flight"}]), None),
        ("labels is a FALSY non-list (\"\" / {}) is not 'none' either", (m._approved_verdict([{"id": "wa-x", "labels": ""}]), m._approved_verdict([{"id": "wa-x", "labels": {}}])), (None, None)),
    ]: check(got == want, "%s -> %r" % (name, want), "%s: expected %r, got %r" % (name, want, got))

    # ── 3. _label_set_verified ───────────────────────────────────────────────
    print("Scenario 3: _label_set_verified (add / remove, confirmed by reading the bead back)")
    def lsv(st, op, lbl, **kw):
        orig = install(st)
        try: return m._label_set_verified("wa-x", op, lbl, delay_secs=0, **kw)
        finally: m.subprocess.run = orig
    s = Store(STORY); r = lsv(s, "add", "story:approved")
    check(r is True and "story:approved" in s.labels, "add: lands and reads back -> True", "res=%r labels=%r" % (r, s.labels))
    check(next(i for i, c in enumerate(s.calls) if "label" in c) < max(i for i, c in enumerate(s.calls) if "show" in c), "the write is followed by a read-back", "calls=%r" % s.calls)
    s = Store(STORY, stale_after_add=1); r = lsv(s, "add", "story:approved")
    check(r is True, "a stale read-back right after the add is retried -> True", "res=%r labels=%r" % (r, s.labels))
    s = Store(STORY, drop_add={"story:approved"}); r = lsv(s, "add", "story:approved", attempts=3)
    check(r is False and sum(1 for c in s.calls if c[1:3] == ["label", "add"]) == 3, "bd that accepts-and-drops the label -> False after 3 tries (the exit code is not proof)", "res=%r calls=%r" % (r, s.calls))
    s = Store(STORY, add_raises=True); r = lsv(s, "add", "story:approved", attempts=2)
    check(r is False and "story:approved" not in s.labels and "story:in-flight" in s.labels, "label add RAISES (bd missing) -> False, labels untouched", "res=%r labels=%r" % (r, s.labels))
    s = Store(STORY); r = lsv(s, "remove", "story:in-flight")
    check(r is True and "story:in-flight" not in s.labels, "remove: gone and read back -> True", "res=%r labels=%r" % (r, s.labels))
    s = Store(STORY, drop_remove={"story:in-flight"}); r = lsv(s, "remove", "story:in-flight")
    check(r is False, "bd that accepts-and-drops the removal -> False", "res=%r" % (r,))
    for why, st in (("show exits 1", Store(STORY, show_rc=1)), ("show prints nothing", Store(STORY, show_out="")), ("show prints garbage", Store(STORY, show_out="not json {{{")),
                    ("show RAISES (timeout)", Store(STORY, show_raises=True)), ("show prints an error envelope", Store(STORY, show_out='[{"error":"not found"}]'))):
        r = lsv(st, "add", "story:approved", attempts=2)
        check(r is False, "%s -> never confirmed -> False" % why, "%s: res=%r" % (why, r))

# ── 4. reclaim end to end on a story ─────────────────────────────────────
print("Scenario 4 (ga-btr2dof): quorum `reclaim` on an approved story whose builder died")
s = Store(STORY); r = reclaim(s)
check(r is True, "reclaim returned True", "reclaim returned %r" % (r,))
check("story:approved" in s.labels, "the story comes out WITH story:approved", "final labels=%r (no story:* label = auto-refino RAW takes it for a new idea)" % s.labels)
check("story:in-flight" not in s.labels and "pilot:dispatched" not in s.labels and "lane:small" in s.labels, "story:in-flight and pilot:dispatched are gone, other labels kept", "labels=%r" % s.labels)
check(s.assignee == "" and s.status == "open", "assignee cleared, status open (the reclaim itself is unchanged)", "assignee=%r status=%r" % (s.assignee, s.status))
check(not s.zero_story_moments(), "the story never sat with zero story:* labels, at ANY call", "zero-story-label moments: %r" % s.zero_story_moments()[:3])
add_i = next((i for i, c in enumerate(s.calls) if c[1:3] == ["label", "add"] and "story:approved" in c), -1)
rm_i = next((i for i, c in enumerate(s.calls) if c[1:3] == ["label", "remove"] and "story:in-flight" in c), -1)
check(0 <= add_i < rm_i, "story:approved goes back BEFORE story:in-flight comes off (call %d < %d)" % (add_i, rm_i), "order: add=%d remove=%d" % (add_i, rm_i))
check(any(t == "RECLAIM" and "restore" in msg for t, msg in EMITS), "the verdict is logged for the audit trail", "emits=%r" % EMITS[-4:])

# ── 5. bd drops the label ────────────────────────────────────────────────
print("Scenario 5: story:approved cannot be confirmed -> abort, bead untouched")
s = Store(STORY, drop_add={"story:approved"}); r = reclaim(s)
check(r is False, "reclaim returned False", "reclaim returned %r" % (r,))
check(set(s.labels) == set(STORY) and s.assignee == "oracle-wa" and s.status == "in_progress", "labels, assignee and status exactly as they were", "labels=%r assignee=%r status=%r" % (s.labels, s.assignee, s.status))
other = [c for c in s.writes() if not (c[1:3] == ["label", "add"] and "story:approved" in c)]
check(not other, "no write other than the story:approved attempts", "other writes: %r" % other[:4])
check(not s.zero_story_moments(), "never zero story:* labels", "zero-story-label moments: %r" % s.zero_story_moments()[:3])

# ── 6. unreadable bead ───────────────────────────────────────────────────
print("Scenario 6: the bead cannot be read -> abort, NOTHING written (unreadable is not empty)")
for why, st in (("bd show exits 1", Store(STORY, show_rc=1)), ("bd show prints nothing", Store(STORY, show_out="")), ("bd show prints garbage", Store(STORY, show_out="not json {{{")),
                ("bd show RAISES (timeout)", Store(STORY, show_raises=True)), ("bd show prints an error envelope", Store(STORY, show_out='[{"error":"not found"}]'))):
    r = reclaim(st)
    check(r is False and not st.writes(), "%s -> False and no write at all" % why, "%s: res=%r writes=%r" % (why, r, st.writes()[:3]))

if have:
    orig_verdict = m._approved_verdict; m._approved_verdict = lambda b: None   # a verdict that cannot be given on a bead that WAS read (the two functions diverged): inert
    s = Store(STORY); r = reclaim(s); m._approved_verdict = orig_verdict
    check(r is False and not s.writes(), "no verdict on a readable bead -> False and no write", "res=%r writes=%r" % (r, s.writes()[:3]))

# ── 7. never invent an approval ──────────────────────────────────────────
print("Scenario 7: bug / tech-debt feature / feature with no trace never get story:approved; the release itself is unchanged")
for why, st in (("bug", Store(["story:in-flight", "pilot:dispatched"], typ="bug")),
                ("tech-debt feature (Tier-1 bypass: dispatched with NO approval)", Store(["story:in-flight", "pilot:dispatched", "tech-debt"])),
                ("feature with no trace of dispatch/approval (maybe parked by hand)", Store(["story:in-flight"], meta={}))):
    r = reclaim(st)
    check(r is True and "story:approved" not in st.labels and not any("story:approved" in c for c in st.calls), "%s: story:approved NOT written" % why, "%s: res=%r labels=%r" % (why, r, st.labels))
    check("story:in-flight" not in st.labels and st.assignee == "" and st.status == "open", "%s: released as before" % why, "%s: labels=%r assignee=%r status=%r" % (why, st.labels, st.assignee, st.status))
s = Store([], typ="feature"); r = reclaim(s)
check(r is True and s.assignee == "" and s.status == "open", "a bead with NO labels at all (key omitted) is released, not refused as unreadable", "res=%r assignee=%r status=%r" % (r, s.assignee, s.status))

# ── 8. the strip fails ───────────────────────────────────────────────────
print("Scenario 8: story:in-flight cannot be removed -> False, assignee/status untouched (nothing half-done)")
s = Store(STORY, drop_remove={"story:in-flight"}); r = reclaim(s)
check(r is False, "reclaim returned False (the cycle must not call it resolved)", "reclaim returned %r" % (r,))
check("story:approved" in s.labels and "story:in-flight" in s.labels and s.assignee == "oracle-wa" and s.status == "in_progress",
      "approved+in-flight (a consistent state), owner and status untouched", "labels=%r assignee=%r status=%r" % (s.labels, s.assignee, s.status))
check(not any(c[1] in ("update", "reopen") for c in s.calls), "no assignee/status write after the failed strip", "calls=%r" % [c for c in s.calls if c[1] in ("update", "reopen")])

# ── 9. the cycle ─────────────────────────────────────────────────────────
print("Scenario 9: _run_cycle keeps the quorum open after an unconfirmed reclaim, retries, and gives up after QUORUM_EXEC_MAX_ATTEMPTS")
m._collect_votes = lambda qid, crews: {"mila-wa": "reclaim", "oracle-wa": "reclaim"}
m.EXEC_MAX_ATTEMPTS = 3
def cycle(st, state):
    orig = install(st)
    try: m._run_cycle(state, 2000000000.0)
    finally: m.subprocess.run = orig
sess = {"original_bead_id": "wa-x", "crews": ["mila-wa", "oracle-wa", "digo-wa"], "convened_at": 2000000000.0 - 60, "decided": False}
state = {"active_quorums": {"q-1": sess}}; EMITS.clear()
s = Store(STORY + ["quorum:convening"], drop_add={"story:approved"})
cycle(s, state)
check("q-1" in state["active_quorums"] and not sess["decided"] and sess.get("exec_failures") == 1, "1st failure: the quorum stays open, exec_failures=1", "state=%r" % (state,))
check("quorum:resolved" not in s.labels and "quorum:convening" in s.labels and "story:in-flight" in s.labels, "not labelled resolved, bead intact", "labels=%r" % s.labels)
check(not any(c[1] == "comment" for c in s.calls), "no 'executed autonomously' comment on the bead", "comments=%r" % [c for c in s.calls if c[1] == "comment"])
s.drop_add = set(); cycle(s, state)
check("q-1" not in state["active_quorums"], "2nd cycle, bd healthy: executed, the quorum is closed", "state=%r labels=%r" % (state, s.labels))
check("story:approved" in s.labels and "story:in-flight" not in s.labels and "quorum:resolved" in s.labels and "quorum:convening" not in s.labels, "story:approved back, in-flight off, quorum:resolved", "labels=%r" % s.labels)
check(any(c[1] == "comment" for c in s.calls), "the audit comment is posted only now", "calls=%r" % s.calls[-5:])
check([t for t, _ in EMITS if t in ("RESOLVED", "RETRY")] == ["RESOLVED", "RETRY"], "RESOLVED is logged once, the retry is logged as RETRY", "tags=%r" % [t for t, _ in EMITS if t in ("RESOLVED", "RETRY")])
sess = {"original_bead_id": "wa-x", "crews": ["mila-wa", "oracle-wa", "digo-wa"], "convened_at": 2000000000.0 - 60, "decided": False}
state = {"active_quorums": {"q-2": sess}}; s = Store(STORY + ["quorum:convening"], drop_add={"story:approved"}); EMITS.clear()
for n in (1, 2, 3):
    cycle(s, state)
    check(("q-2" in state["active_quorums"]) == (n < 3), "attempt %d/3: quorum %s" % (n, "open" if n < 3 else "closed (gave up)"), "attempt %d: state=%r" % (n, state))
check(any(t == "ERROR" for t, _ in EMITS), "giving up is logged as an ERROR", "emits=%r" % EMITS[-3:])
check(set(s.labels) == set(STORY + ["quorum:convening"]) and s.assignee == "oracle-wa", "after giving up the bead is still exactly as it was", "labels=%r assignee=%r" % (s.labels, s.assignee))

print("Scenario 10: the fake never met an argv it does not model")
check(not UNMODELLED, "every bd call the watchdog made is one the fake models", "unmodelled argv: %r" % UNMODELLED[:3])
print("")
print("Results: %d passed, %d failed" % (PASS, FAIL))
if FAIL == 0 and PASS > 0:
    print("SELFTEST PASS"); sys.exit(0)
print("SELFTEST FAIL"); sys.exit(1)
PY
