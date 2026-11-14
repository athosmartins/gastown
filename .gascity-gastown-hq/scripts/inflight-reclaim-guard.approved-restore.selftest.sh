#!/usr/bin/env bash
# inflight-reclaim-guard.approved-restore.selftest.sh — ga-w6a9xps: do_reclaim() strips story:in-flight to send a bead "back to the pool". The builder's own claim had already dropped
# story:approved, so a STORY (feature/story) came out with NO story:* label at all — and auto-refino's RAW sweep reads exactly that as a fresh idea and sends it back to Athos for a second
# approval (wa-tvrs41.5, approved 13/11, re-asked, restored by hand 14/11). do_reclaim now gives story:approved back FIRST, confirmed by a read-back, and aborts the whole reclaim
# (nothing else touched, retried next sweep) if it cannot confirm.
#
# The fake `bd` is a small STATEFUL store (labels/assignee/status), so the invariant is checked after EVERY call, not just at the end: a story must never sit in the store with zero
# story:* labels.
#
# Scenarios:
#   1. _approved_verdict table (restore / has-approved / not-in-flight / other-story-state / not-story / None=cannot know)
#   2. _restore_approved_verified: restore + read-back; retry through a stale read-back; bd that accepts-and-drops the label; unreadable pre-read; non-story types never write
#   3. do_reclaim end to end on a story: approved goes back BEFORE in-flight comes off; invariant holds at every call; final labels = story:approved, no in-flight, no pilot:dispatched
#   4. do_reclaim, bd drops the label: returns False and touches NOTHING (no remove, no assign, no status update)
#   5. do_reclaim on a bug: no story:approved is ever added; reclaim completes as before
#   6. do_reclaim, unreadable bead: returns False, nothing written
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="${GUARD_UNDER_TEST:-$SCRIPT_DIR/inflight-reclaim-guard.py}"

/usr/bin/python3 - "$WD" <<'PY'
import sys, importlib.util, json

wd_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("inflight_reclaim_guard", wd_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

PASS = 0
FAIL = 0

def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)

def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)

def check(cond, msg_ok, msg_bad):
    ok(msg_ok) if cond else bad(msg_bad)

m.time.sleep = lambda *_a, **_k: None   # selftest must not actually sleep
m.preserve_unpushed_branch = lambda *_a, **_k: []

class R:
    def __init__(self, rc=0, out="", err=""):
        self.returncode, self.stdout, self.stderr = rc, out, err

have_verdict = hasattr(m, "_approved_verdict") and hasattr(m, "_restore_approved_verified")

# ── Scenario 1: the verdict table ────────────────────────────────────────────
print("Scenario 1: _approved_verdict")
if not have_verdict:
    bad("_approved_verdict/_restore_approved_verified do not exist in the guard (the fix is absent)")
else:
    def v(labels, typ="feature", wrap=True):
        b = {"id": "wa-x", "labels": labels}
        if typ is not None:
            b["issue_type"] = typ
        return m._approved_verdict([b] if wrap else b)
    table = [
        ("feature, in-flight, no other story:*",        v(["story:in-flight", "pilot:dispatched"]),                 "restore"),
        ("story type, in-flight + dispatch label",      v(["story:in-flight", "pilot:dispatched"], typ="story"),    "restore"),
        ("bare object (not wrapped in a list)",         v(["story:in-flight", "pilot:dispatched"], wrap=False),     "restore"),
        ("proof = pilot.dispatched_at stamp",           m._approved_verdict([{"labels": ["story:in-flight"], "issue_type": "feature", "metadata": {"pilot.dispatched_at": "1790000000"}}]), "restore"),
        ("proof = story.aprovado_por stamp",            m._approved_verdict([{"labels": ["story:in-flight"], "issue_type": "feature", "metadata": {"story.aprovado_por": "athos"}}]), "restore"),
        ("NO trace at all (maybe parked by hand)",      v(["story:in-flight"]),                                     "no-proof"),
        ("story type, no trace",                        v(["story:in-flight"], typ="story"),                        "no-proof"),
        ("stamps present but empty",                    m._approved_verdict([{"labels": ["story:in-flight"], "issue_type": "feature", "metadata": {"pilot.dispatched_at": "", "story.aprovado_por": ""}}]), "no-proof"),
        ("metadata not a dict (never proof)",           m._approved_verdict([{"labels": ["story:in-flight"], "issue_type": "feature", "metadata": "oops"}]), "no-proof"),
        ("already has story:approved",                  v(["story:in-flight", "story:approved"]),                   "has-approved"),
        ("no story:in-flight",                          v(["lane:small"]),                                          "not-in-flight"),
        ("in-flight + story:done (never overwrite)",    v(["story:in-flight", "story:done"]),                       "other-story-state"),
        ("in-flight + story:triage",                    v(["story:in-flight", "story:triage"]),                     "other-story-state"),
        ("bug",                                         v(["story:in-flight"], typ="bug"),                          "not-story"),
        ("task",                                        v(["story:in-flight"], typ="task"),                         "not-story"),
        ("chore",                                       v(["story:in-flight"], typ="chore"),                        "not-story"),
        ("type missing",                                v(["story:in-flight"], typ=None),                           "not-story"),
        ("None (nothing read)",                         m._approved_verdict(None),                                  None),
        ("empty list",                                  m._approved_verdict([]),                                    None),
        ("error envelope (no labels key)",              m._approved_verdict([{"error": "not found"}]),              None),
        ("labels is not a list",                        m._approved_verdict([{"labels": "story:in-flight"}]),       None),
        ("a string",                                    m._approved_verdict("nope"),                                None),
    ]
    for name, got, want in table:
        check(got == want, "%s -> %r" % (name, want), "%s: expected %r, got %r" % (name, want, got))

# ── A stateful fake bd ───────────────────────────────────────────────────────
class Store:
    """labels / assignee / status of ONE bead + the trace of every bd call. drop_approved=True: `label add story:approved` exits 0 but never lands.
    stale_show: the first N `show` calls AFTER an add still read the pre-add state."""
    def __init__(self, labels, typ="feature", drop_approved=False, show_rc=0, show_out=None, stale_after_add=0):
        self.labels = list(labels); self.typ = typ
        self.assignee = "wa-builder-1"; self.status = "in_progress"
        self.drop_approved = drop_approved
        self.show_rc, self.show_out = show_rc, show_out
        self.stale_after_add = stale_after_add; self._stale_left = 0; self._pre_add = None
        self.calls = []; self.story_labels_trace = []
        self.had_story_label_at_start = any(x.startswith("story:") for x in labels)

    def story_labels(self):
        return [x for x in self.labels if x.startswith("story:")]

    def run(self, cmd, capture_output=True, text=True, timeout=15, **_kw):
        cmd = list(cmd)
        self.calls.append(cmd)
        i = cmd.index("bd") + 1 if "bd" in cmd else 0
        rest = cmd[i:]
        if rest[:2] == ["-C", rest[1]] and len(rest) > 1:
            rest = rest[2:]
        verb = rest[0] if rest else ""
        out = R()
        if verb == "show":
            if self.show_rc != 0:
                return R(self.show_rc, "", "bd: boom")
            if self.show_out is not None:
                return R(0, self.show_out)
            labels = self.labels
            if self._stale_left > 0 and self._pre_add is not None:
                labels = self._pre_add; self._stale_left -= 1
            return R(0, json.dumps([{"id": "wa-x", "issue_type": self.typ, "status": self.status,
                                     "assignee": self.assignee, "labels": list(labels)}]))
        if verb == "label" and len(rest) >= 4:
            op, lbl = rest[1], rest[3]
            if op == "add":
                if lbl == "story:approved" and self.drop_approved:
                    pass
                elif lbl not in self.labels:
                    self._pre_add = list(self.labels); self._stale_left = self.stale_after_add
                    self.labels.append(lbl)
            elif op == "remove":
                self.labels = [x for x in self.labels if x != lbl]
        elif verb == "assign":
            self.assignee = rest[2] if len(rest) > 2 else ""
        elif verb == "update" and "--status" in rest:
            self.status = rest[rest.index("--status") + 1]
        # the invariant: a story that entered with a story:* label must never sit with zero of them
        if self.had_story_label_at_start:
            self.story_labels_trace.append((verb, tuple(rest[:4]), list(self.story_labels())))
        return out

    def zero_story_label_moments(self):
        return [t for t in self.story_labels_trace if not t[2]]

    def writes(self):
        w = []
        for c in self.calls:
            r = c[c.index("bd") + 1:] if "bd" in c else c
            if r[:2] == ["-C", r[1]] and len(r) > 1: r = r[2:]
            if r and r[0] in ("label", "assign", "update", "comment", "close"):
                w.append(r)
        return w

def install(store):
    orig = m.subprocess.run
    m.subprocess.run = store.run
    return orig

def uninstall(orig):
    m.subprocess.run = orig

# ── Scenario 2: _restore_approved_verified ───────────────────────────────────
print("Scenario 2: _restore_approved_verified")
if have_verdict:
    s = Store(["story:in-flight", "pilot:dispatched"])
    o = install(s)
    try:
        res = m._restore_approved_verified(["bd"], "wa-x")
    finally:
        uninstall(o)
    check(res is True and "story:approved" in s.labels, "story: restored and read back -> True", "story: res=%r labels=%r" % (res, s.labels))
    first_show = next((i for i, c in enumerate(s.calls) if "show" in c), -1)
    first_add = next((i for i, c in enumerate(s.calls) if "add" in c), -1)
    check(0 <= first_show < first_add, "the bead is READ before anything is written", "order: show=%d add=%d" % (first_show, first_add))

    s = Store(["story:in-flight", "pilot:dispatched"], stale_after_add=1)
    o = install(s)
    try:
        res = m._restore_approved_verified(["bd"], "wa-x")
    finally:
        uninstall(o)
    adds = [c for c in s.calls if "add" in c]
    check(res is True and len(adds) >= 1, "a stale read-back right after the add is retried -> True", "res=%r adds=%d labels=%r" % (res, len(adds), s.labels))

    s = Store(["story:in-flight", "pilot:dispatched"], drop_approved=True)
    o = install(s)
    try:
        res = m._restore_approved_verified(["bd"], "wa-x", attempts=3)
    finally:
        uninstall(o)
    check(res is False, "bd that accepts-and-drops the label -> False (the exit code of the write is not proof)", "res=%r" % (res,))

    for why, st in (("bd show fails", Store(["story:in-flight"], show_rc=1)),
                    ("bd show prints nothing", Store(["story:in-flight"], show_out="")),
                    ("bd show prints garbage", Store(["story:in-flight"], show_out="not json {{{")),
                    ("bd show prints an error envelope", Store(["story:in-flight"], show_out='[{"error":"not found"}]'))):
        o = install(st)
        try:
            res = m._restore_approved_verified(["bd"], "wa-x")
        finally:
            uninstall(o)
        check(res is False and not st.writes(), "%s -> False and NOTHING written" % why, "%s: res=%r writes=%r" % (why, res, st.writes()))

    for typ in ("bug", "task", "chore"):
        st = Store(["story:in-flight"], typ=typ)
        o = install(st)
        try:
            res = m._restore_approved_verified(["bd"], "wa-x")
        finally:
            uninstall(o)
        check(res is True and not st.writes(), "%s: nothing to restore -> True, no write" % typ, "%s: res=%r writes=%r" % (typ, res, st.writes()))

    # a feature in flight with NO trace of dispatch/approval: released as before, story:approved is never written (only Athos approves)
    st = Store(["story:in-flight"])
    o = install(st)
    try:
        res = m._restore_approved_verified(["bd"], "wa-x")
    finally:
        uninstall(o)
    check(res is True and not st.writes() and "story:approved" not in st.labels, "feature with no trace: True, story:approved NOT written", "res=%r writes=%r labels=%r" % (res, st.writes(), st.labels))

# ── Scenario 3: do_reclaim end to end on a story ─────────────────────────────
print("Scenario 3 (ga-w6a9xps): do_reclaim on an approved story whose builder died")
s = Store(["story:in-flight", "pilot:dispatched", "lane:small"])
o = install(s)
try:
    res = m.do_reclaim("wa-x", "some title", 0, 30.0, ["story:in-flight", "pilot:dispatched", "lane:small"])
finally:
    uninstall(o)
check(res is True, "do_reclaim returned True", "do_reclaim returned %r" % (res,))
check("story:approved" in s.labels, "the story comes out WITH story:approved", "final labels=%r (no story:* label = auto-refino RAW takes it for a new idea)" % s.labels)
check("story:in-flight" not in s.labels and "pilot:dispatched" not in s.labels, "story:in-flight and pilot:dispatched are gone", "final labels=%r" % s.labels)
check(s.assignee == "" and s.status == "open", "assignee cleared, status open (the reclaim itself is unchanged)", "assignee=%r status=%r" % (s.assignee, s.status))
check(not s.zero_story_label_moments(), "the story never sat with zero story:* labels, at ANY call", "zero-story-label moments: %r" % s.zero_story_label_moments()[:3])
add_i = next((i for i, c in enumerate(s.calls) if "add" in c and "story:approved" in c), -1)
rm_i = next((i for i, c in enumerate(s.calls) if "remove" in c and "story:in-flight" in c), -1)
check(0 <= add_i < rm_i, "story:approved goes back BEFORE story:in-flight comes off (call %d < %d)" % (add_i, rm_i), "order: add=%d remove=%d" % (add_i, rm_i))

# ── Scenario 4: bd drops the label -> nothing else is touched ────────────────
print("Scenario 4: story:approved cannot be confirmed -> abort, bead untouched")
s = Store(["story:in-flight", "pilot:dispatched"], drop_approved=True)
o = install(s)
try:
    res = m.do_reclaim("wa-x", "some title", 0, 30.0, ["story:in-flight", "pilot:dispatched"])
finally:
    uninstall(o)
check(res is False, "do_reclaim returned False", "do_reclaim returned %r" % (res,))
check(set(s.labels) == {"story:in-flight", "pilot:dispatched"}, "labels exactly as they were", "labels=%r" % s.labels)
check(s.assignee == "wa-builder-1" and s.status == "in_progress", "assignee and status untouched", "assignee=%r status=%r" % (s.assignee, s.status))
other_writes = [w for w in s.writes() if not (w[0] == "label" and "story:approved" in w)]
check(not other_writes, "no write other than the story:approved attempts", "other writes: %r" % other_writes[:4])
check(not s.zero_story_label_moments(), "never zero story:* labels", "zero-story-label moments: %r" % s.zero_story_label_moments()[:3])

# ── Scenario 5: a bug never had story:approved ───────────────────────────────
print("Scenario 5: a bug is reclaimed as before, with no story:approved added")
s = Store(["story:in-flight", "pilot:dispatched"], typ="bug")
o = install(s)
try:
    res = m.do_reclaim("wa-x", "some title", 0, 30.0, ["story:in-flight", "pilot:dispatched"])
finally:
    uninstall(o)
check(res is True, "do_reclaim returned True", "do_reclaim returned %r" % (res,))
check("story:approved" not in s.labels and not any("story:approved" in c for c in s.calls), "no story:approved added to a bug", "labels=%r" % s.labels)
check("story:in-flight" not in s.labels and s.assignee == "" and s.status == "open", "released as before", "labels=%r assignee=%r status=%r" % (s.labels, s.assignee, s.status))

# ── Scenario 6: unreadable bead -> nothing written ───────────────────────────
print("Scenario 6: the bead cannot be read -> abort, nothing written")
s = Store(["story:in-flight", "pilot:dispatched"], show_rc=1)
o = install(s)
try:
    res = m.do_reclaim("wa-x", "some title", 0, 30.0, ["story:in-flight", "pilot:dispatched"])
finally:
    uninstall(o)
check(res is False, "do_reclaim returned False", "do_reclaim returned %r" % (res,))
check(not s.writes(), "no write at all", "writes: %r" % s.writes()[:4])

print("")
print("Results: %d passed, %d failed" % (PASS, FAIL))
if FAIL == 0:
    print("SELFTEST PASS"); sys.exit(0)
print("SELFTEST FAIL"); sys.exit(1)
PY
