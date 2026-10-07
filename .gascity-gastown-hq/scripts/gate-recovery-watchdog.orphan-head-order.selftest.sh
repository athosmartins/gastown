#!/usr/bin/env bash
# gate-recovery-watchdog.orphan-head-order.selftest.sh (ga-9t9acg.13, programa ga-9t9acg "ordem unica")
#
# The watchdog's "head of the gate queue" (_orphan_head) was the OLDEST queued marker: pure FIFO by created_at.
# Since ga-q8tj7p the gate serves its queue by priority > feature > age, and the Athos rule (2026-10-06) says ONE
# ordering rule for every stage of the board — the library work-order.sh, reached from Python through
# scripts/work_order.py. This file pins that the watchdog's head is the library's first, fed with the SAME fields
# the gate uses:
#   * priority and type come from the marker's SOURCE bead (`bd show`), never from the marker: a live marker is
#     always P2 / chore whatever it carries (measured 2026-10-07, 26 of 26), so ordering by the marker's own
#     fields would leave the watchdog on FIFO while claiming to follow the gate;
#   * age = the marker's created_at (the age of the SUBMISSION to the gate, `--age field`), exactly the gate's.
#
# Groups
#   A. the head AGREES with the dispatcher's own marker-select block (extracted by its sentinels, run under bash —
#      the oracle is the real block, never a copy) over a matrix of queues. The fixture of the bead is case A1:
#      a NEW P0 feature and an OLD P1 bug -> the head is the P0 feature (FIFO says the P1 bug).
#   B. the three states of the library, never collapsed: a source class that could not be read keeps the marker at
#      the END of the order and is NOTED; a library that cannot tell makes the head UNKNOWN (inert + noted), never a
#      silent fall back to FIFO; priority 0 is a priority, not "absent".
#   C. the source-class reader (_marker_source_classes): which store it asks, in which order, what a partial miss, a
#      total miss and a failed read each become.
#   D. end to end through orphaned_queued_marker() against the legacy (overdue-tier) fixture: the marker flagged is
#      the library's head, not the FIFO-oldest.
#   E. the registry: the consumer row of this slice is gone, no FIFO idiom is left in the watchdog, the lint is clean.
#
# Mutation control — WD_OVERRIDE=<a copy of the watchdog with ONE line changed> bash ... (measured when this was
# written; the copies are not kept):
#   head sorted FIFO again ................. fails A1 A2 A4 A5 A6 B1 B2 B3 B4 B6 D1 D2   (15 checks)
#   reader returns {} (head degrades to age) fails C1 C2 C5 C7 D1
#   priority 0 read as absent (`or 2`) ...... fails C2 C5 D1
#   the marker's own P2/chore used ........... fails A1 A2 A4 A6 B3 B6 D1
#   library "cannot tell" falls back to FIFO . fails B4
# Against the watchdog as it was before this slice (WD_OVERRIDE=<that file from git>): PASS=12 FAIL=20 — among them D1,
# where the P3 chore (the FIFO-oldest) is flagged instead of the P0 feature.
#
# Run: bash scripts/gate-recovery-watchdog.orphan-head-order.selftest.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="${WD_OVERRIDE:-$SCRIPT_DIR/gate-recovery-watchdog.py}"
DISPATCHER="${DISPATCHER_OVERRIDE:-$SCRIPT_DIR/../packs/town-deltas/assets/quality-gate-dispatcher.sh}"
[ -f "$WD" ] || { echo "FATAL: gate-recovery-watchdog.py not found at $WD"; exit 2; }
[ -f "$DISPATCHER" ] || { echo "FATAL: quality-gate-dispatcher.sh not found at $DISPATCHER"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is not on PATH (the ordering library needs it)"; exit 2; }

/usr/bin/python3 - "$WD" "$DISPATCHER" "$SCRIPT_DIR" <<'PY'
import contextlib, importlib.util, io, json, os, subprocess, sys, tempfile, time, shutil, atexit

wd_path, dispatcher, scripts_dir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, scripts_dir)
for k in list(os.environ):                      # hermetic: a stray override must not move what is under test
    if k.startswith("GRW_") or k.startswith("GATE_") or k == "WORK_ORDER_LIB":
        del os.environ[k]

def load():
    spec = importlib.util.spec_from_file_location("grw_orderhead", wd_path)
    mod = importlib.util.module_from_spec(spec)
    saved = sys.argv
    sys.argv = ["grw"]                          # __name__ != "__main__" -> main() never runs
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.argv = saved
    return mod
m = load()

TMP = tempfile.mkdtemp(prefix="grw-orderhead-")
atexit.register(shutil.rmtree, TMP, ignore_errors=True)

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)
def check(cond, msg):
    (ok if cond else bad)(msg)

NOW = time.time()
MIN_AGE = getattr(m, "ORPHAN_MIN_AGE_SEC", 1800)
def iso(t): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
def fmt(t): return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))
def dl(t, body): return "[%s] [quality-gate-dispatcher] %s" % (fmt(t), body)

HAVE_API = hasattr(m, "_marker_source_classes")
def head_of(markers, src_class, now=NOW, sweeps=None):
    """_orphan_head with the source classes handed in; (id, None) or ('API', why) when the watchdog has no such parameter."""
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            h = m._orphan_head(markers, [NOW - 60] if sweeps is None else sweeps, now, MIN_AGE, src_class=src_class)
    except TypeError as e:
        return ("API", repr(e)), buf.getvalue()
    return (h[0] if h else None), buf.getvalue()

def reset_notes():
    for c in (getattr(m, "_ORPHAN_NOTED", None), getattr(m, "_ORPHAN_EVIDENCE", None), getattr(m, "_MARKER_CREATED_CACHE", None)):
        if c is not None:
            c.clear()
    for c in (getattr(m, "_HARD_AGE_CACHE", None), getattr(m, "_ORDER_PREMISE_CACHE", None)):
        if c is not None:
            c.update({"at": 0.0, "value": None})
    if hasattr(m, "_RIG_PATHS"):                # the file's own rig registry cache (10 min): each World brings its own rigs
        m._RIG_PATHS.update({"ts": 0.0, "map": {}, "by_prefix": {}})

# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# A. The head agrees with the dispatcher's own marker-select block
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
print("Group A: the head is the one the dispatcher's real marker-select block picks (oracle = the block itself, run under bash)")
block = subprocess.run(["sed", "-n", "/# SELFTEST-EXTRACT marker-select: BEGIN/,/# SELFTEST-EXTRACT marker-select: END/p", dispatcher],
                       capture_output=True, text=True).stdout
check(bool(block.strip()), "located the live marker-select block via its sentinels")

def real_select(rows):
    """rows: [(id, created_epoch, priority|None, type|None)] -> the id the dispatcher claims first. priority None = unreadable."""
    mk = []
    for mid, created, prio, typ in rows:
        sc = {"state": "ok", "priority": prio, "type": typ, "dano": "no"} if prio is not None else {"state": "unreadable", "why": "not-read"}
        mk.append({"id": mid, "created_at": iso(created), "description": "branch: crew/x/%s" % mid, "labels": ["gate-status:queued"], "src_class": sc})
    e = {k: v for k, v in os.environ.items() if not k.startswith("GATE_")}
    e.update({"MARKERS_JSON": json.dumps(mk), "GATE_MARKER_NOW_OVERRIDE_EPOCH": str(int(NOW))})
    r = subprocess.run(["bash", "-c", block + '\necho "$MARKER_ID"'], env=e, capture_output=True, text=True)
    return r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""

def watchdog_head(rows):
    markers = [(mid, "crew/x/%s" % mid, created, ("gate-status:queued",)) for mid, created, _p, _t in rows]
    src = dict((mid, {"priority": p, "type": t}) for mid, _c, p, t in rows if p is not None)
    return head_of(markers, src)[0]

def fifo_head(rows):
    return sorted(rows, key=lambda r: r[1])[0][0]

H = 3600
CASES = [
    # (label, rows [(id, created, priority, type)], what the rule says)
    ("A1 a NEW P0 feature and an OLD P1 bug (the bead's fixture)",
     [("p1bug-old", NOW - 20 * H, 1, "bug"), ("p0feat-new", NOW - 3 * H, 0, "feature")], "p0feat-new"),
    ("A2 inside P0, a NEW feature beats an OLD bug",
     [("p0bug-old", NOW - 20 * H, 0, "bug"), ("p0feat-new", NOW - 3 * H, 0, "feature")], "p0feat-new"),
    ("A3 same class: the OLDER one",
     [("p1feat-new", NOW - 3 * H, 1, "feature"), ("p1feat-old", NOW - 9 * H, 1, "feature")], "p1feat-old"),
    ("A4 priority beats type: a P1 chore before a P2 feature",
     [("p2feat-old", NOW - 20 * H, 2, "feature"), ("p1chore-new", NOW - 3 * H, 1, "chore")], "p1chore-new"),
    ("A5 an UNREADABLE source class goes after every readable one, even a P4 chore",
     [("unread-old", NOW - 20 * H, None, None), ("p4chore-new", NOW - 3 * H, 4, "chore")], "p4chore-new"),
    ("A6 three priorities, the P0 wins whatever the ages",
     [("p3", NOW - 30 * H, 3, "feature"), ("p0", NOW - 2 * H, 0, "task"), ("p1", NOW - 9 * H, 1, "feature")], "p0"),
]
if block.strip():
    for label, rows, want in CASES:
        oracle = real_select(rows)
        got = watchdog_head(rows)
        check(oracle == want, "%s: the dispatcher's own block picks %r (got %r) — the fixture says what the rule says" % (label, want, oracle))
        check(got == oracle, "%s: the watchdog's head is %r, the dispatcher's pick is %r%s"
              % (label, got, oracle, "  <- FIFO says %r" % fifo_head(rows) if fifo_head(rows) != oracle else ""))
    # the fixtures must DISCRIMINATE: on A1/A2/A4/A5 the old FIFO answer differs from the rule, or these checks would pass on the old code
    check(all(fifo_head(rows) != want for (l, rows, want) in CASES if l.split()[0] in ("A1", "A2", "A4", "A5")),
          "A1/A2/A4/A5 are queues where FIFO and the rule disagree (so they fail on the old code)")

# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# B. The three states of the library
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
print("Group B: unreadable class stays at the end and is NOTED; a library that cannot tell makes the head UNKNOWN; priority 0 is a priority")
def mq(mid, age_h):
    return (mid, "crew/x/%s" % mid, NOW - age_h * H, ("gate-status:queued",))

reset_notes()
h, out = head_of([mq("a-old", 20), mq("b-new", 3)], {"b-new": {"priority": 0, "type": "feature"}})
check(h == "b-new", "B1 only the NEW marker has a readable class -> it leads (got %r)" % (h,))
check("a-old" in out and "prio?" in out, "B1 ...and the unreadable one is NAMED in a visible note, never silently ordered (out=%r)" % out.strip()[:200])

reset_notes()
h, out = head_of([mq("a-old", 20), mq("b-new", 3)], {})
check(h == "a-old", "B2 nothing readable -> the library keeps them in age order, oldest first (got %r) — the gate does the same" % (h,))
check("prio?" in out, "B2 ...and says so (out=%r)" % out.strip()[:160])

reset_notes()
h, out = head_of([mq("p1-old", 20), mq("p0-new", 3)], {"p1-old": {"priority": 1, "type": "bug"}, "p0-new": {"priority": 0, "type": "bug"}})
check(h == "p0-new", "B3 priority 0 is a priority, not 'absent': P0 bug beats P1 bug (got %r)" % (h,))

reset_notes()
os.environ["WORK_ORDER_LIB"] = os.path.join(TMP, "no-such-work-order.sh")
try:
    h, out = head_of([mq("a-old", 20), mq("b-new", 3)], {"b-new": {"priority": 0, "type": "feature"}})
finally:
    del os.environ["WORK_ORDER_LIB"]
check(h is None, "B4 the library CANNOT TELL -> the head is UNKNOWN (None), never the FIFO-oldest marker (got %r)" % (h,))
check("work-order" in out and "cannot tell" in out, "B4 ...and the note carries the library's own reason (out=%r)" % out.strip()[:200])
h2, out2 = head_of([mq("a-old", 20), mq("b-new", 3)], {"b-new": {"priority": 0, "type": "feature"}})
check(h2 == "b-new", "B4 once the library works again the head comes back by itself (got %r)" % (h2,))

reset_notes()
h, out = head_of([mq("a-old", 20), mq("b-new", 3)], {"a-old": {"priority": 2, "type": "chore"}, "b-new": {"priority": 2, "type": "chore"}})
check(h == "a-old" and out.strip() == "", "B5 equal classes -> oldest, and a clean queue prints nothing (got %r, out=%r)" % (h, out.strip()[:80]))

reset_notes()
h, out = head_of([mq("young-p0", 0.2), mq("old-p3", 20)], {"young-p0": {"priority": 0, "type": "feature"}, "old-p3": {"priority": 3, "type": "chore"}})
check(h is None, "B6 the head is the library's first even when it is YOUNG: younger than min_age -> no candidate (got %r); an old P3 behind it is not promoted" % (h,))

# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# C. The source-class reader
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
print("Group C: _marker_source_classes — which store, in which order, and what a miss becomes")
CP = subprocess.CompletedProcess
CITY = m.CITY
WA_PATH, GA_PATH = "/fake/rigs/whatsapp_automation", "/fake/rigs/gascity"
RIGS = [{"name": "whatsapp_automation", "prefix": "wa", "path": WA_PATH}, {"name": "gascity", "prefix": "ga", "path": GA_PATH}]

class World(object):
    """A fake bd / gc / launchctl. `stores` maps a store path to {bead id: record}; a store that is absent is DOWN."""
    def __init__(self, queue=(), stores=None, rigs=RIGS, launchd="\tenvironment = {\n\t\tGATE_CODE_REVIEWERS => 1\n\t}\n"):
        self.queue, self.stores, self.rigs, self.launchd = list(queue), stores if stores is not None else {}, rigs, launchd
        self.show_calls, self.list_calls, self.rig_calls = [], 0, 0
    def sh(self, args, timeout=20, stdin=None):
        if args and args[0] == "launchctl":
            return CP(args, 0, self.launchd, "") if self.launchd is not None else CP(args, 113, "", "Could not find service")
        if args and args[0] == "gc" and "rig" in args:
            self.rig_calls += 1
            return CP(args, 0, json.dumps({"rigs": self.rigs}), "") if self.rigs is not None else CP(args, 1, "", "gc: unavailable")
        if len(args) > 4 and args[0] == "bash" and args[2] == "-C":
            store, sub = args[3], args[4]
            if sub == "list":
                self.list_calls += 1
                return CP(args, 0, json.dumps(self.queue), "")
            if sub == "show":
                ids = [a for a in args[5:] if not a.startswith("--")]
                self.show_calls.append((store, tuple(ids)))
                recs = self.stores.get(store)
                if recs is None:
                    return CP(args, 1, "", "store down")
                found = [recs[i] for i in ids if i in recs]
                if not found:
                    return CP(args, 1, json.dumps({"error": "no issues found matching the provided IDs"}), "")
                return CP(args, 0, json.dumps(found), "")
        return None

def with_world(world, fn):
    saved = m.sh
    m.sh = world.sh
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            res = fn()
    finally:
        m.sh = saved
    return res, buf.getvalue()

def rec(bid, prio, typ):
    return {"id": bid, "priority": prio, "issue_type": typ, "status": "open", "created_at": iso(NOW - 99 * H)}

# a queued marker row as `bd list --json` gives it: the source bead is named in the description, else in a label
def qrow(mid, created, src=None, rig=None, via="description", extra_labels=()):
    labels = ["type:quality-gate-marker", "gate-status:queued", "branch:crew/x/%s" % mid] + list(extra_labels)
    desc = "branch: crew/x/%s\nauthor: x\n" % mid
    if src and via == "description":
        desc += "bead_id: %s\nbead_rig: %s\n" % (src, rig or "unknown")
    elif src:
        labels.append("source-bead:%s" % src)
        if rig:
            labels.append("bead-rig:%s" % rig)
    return {"id": mid, "status": "open", "created_at": iso(created), "labels": labels, "description": desc, "priority": 2, "issue_type": "chore"}

def read_queue(world):
    res, _o = with_world(world, m._queued_markers_read)
    return res

if HAVE_API:
    reset_notes()
    q = [qrow("m-wa", NOW - 9 * H, "wa-s1", "whatsapp_automation"),             # source named by the description, in its rig's store
         qrow("m-ga", NOW - 8 * H, "ga-s2", "gascity", via="label"),            # ...by labels
         qrow("m-zero", NOW - 7 * H, "ga-s3", "gascity"),                       # priority 0
         qrow("m-evil", NOW - 6 * H, "--all", "gascity"),                       # not a bead id: never put on a command line
         qrow("m-none", NOW - 5 * H)]                                           # names no source bead
    w = World(q, {WA_PATH: {"wa-s1": rec("wa-s1", 1, "bug")},
                  GA_PATH: {"ga-s2": rec("ga-s2", 3, "feature"), "ga-s3": rec("ga-s3", 0, "bug")}})
    markers = read_queue(w)
    check(markers is not None and len(markers) == 5 and all(len(t) >= 5 for t in markers),
          "C0 the queue read carries each marker's source reference as a fifth element (rows=%r)" % (len(markers or []),))
    sc, out = with_world(w, lambda: m._marker_source_classes(markers))
    check(isinstance(sc, dict), "C1 the reader returns a dict marker-id -> class (got %r)" % (type(sc).__name__,))
    sc = sc if isinstance(sc, dict) else {}
    check(sc.get("m-wa") == {"priority": 1, "type": "bug"}, "C1 a source named by the description is read in ITS RIG's store (got %r)" % (sc.get("m-wa"),))
    check(sc.get("m-ga") == {"priority": 3, "type": "feature"}, "C1 a source named by labels is read too (got %r)" % (sc.get("m-ga"),))
    check(sc.get("m-zero") == {"priority": 0, "type": "bug"}, "C2 priority 0 is kept as 0, not read as absent (got %r)" % (sc.get("m-zero"),))
    check("m-evil" not in sc and "m-none" not in sc, "C3 a marker with no valid source bead has NO class (unreadable), never a guessed one (got %r)" % (sorted(sc),))
    asked = [i for (_s, ids) in w.show_calls for i in ids]
    check("--all" not in asked, "C3 an id that is not a plain bead id never reaches a command line (asked %r)" % (asked,))
    check(len(w.show_calls) <= 3, "C4 one `bd show` per store, not one per marker (calls=%r)" % (w.show_calls,))

    # a partial miss in the first store: the rest is asked of the NEXT candidate store (rig -> id prefix's rig -> city)
    reset_notes()
    q = [qrow("m-a", NOW - 9 * H, "wa-s1", "whatsapp_automation"), qrow("m-b", NOW - 8 * H, "wa-s9", "whatsapp_automation")]
    w = World(q, {WA_PATH: {"wa-s1": rec("wa-s1", 2, "task")}, CITY: {"wa-s9": rec("wa-s9", 0, "feature")}})
    sc, _o = with_world(w, lambda: m._marker_source_classes(read_queue(w)))
    check((sc or {}).get("m-a") == {"priority": 2, "type": "task"} and (sc or {}).get("m-b") == {"priority": 0, "type": "feature"},
          "C5 a bead missing from its rig's store is found in the city store (got %r; calls=%r)" % (sc, w.show_calls))

    # a store that is DOWN, and a bead found nowhere: unreadable, and the watchdog still answers
    reset_notes()
    q = [qrow("m-a", NOW - 9 * H, "wa-s1", "whatsapp_automation")]
    w = World(q, {})            # every store down
    sc, _o = with_world(w, lambda: m._marker_source_classes(read_queue(w)))
    check(sc == {}, "C6 every store down -> no class for anyone (unreadable), an empty dict that is NOT 'nobody has a priority' (got %r)" % (sc,))

    # the rig registry unreadable: the stores that need no registry (the city) are still asked
    reset_notes()
    q = [qrow("m-a", NOW - 9 * H, "ga-s2", "gascity")]
    w = World(q, {CITY: {"ga-s2": rec("ga-s2", 1, "bug")}}, rigs=None)
    sc, _o = with_world(w, lambda: m._marker_source_classes(read_queue(w)))
    check((sc or {}).get("m-a") == {"priority": 1, "type": "bug"}, "C7 `gc rig list` failing still lets the city store be read (got %r)" % (sc,))

    # which source a marker names: the description first, a label second; 'unknown' is no rig; junk never raises (the
    # same queue read serves the live head-of-line check, so a row it cannot read must be 'no source', not a crash)
    def src_ref(row):
        try:
            return m._marker_src_ref(row)
        except Exception as e:
            return "RAISED %r" % (e,)
    check(src_ref({"description": "bead_id:   ga-ok  \nbead_rig: unknown", "labels": ["bead-rig:gascity", "source-bead:ga-other"]}) == ("ga-ok", "gascity"),
          "C9 the description names the bead (trimmed) and wins over the label; rig 'unknown' falls back to the bead-rig: label")
    check(src_ref({"description": "", "labels": ["source-bead:ga-lbl", "bead-rig:whatsapp_automation"]}) == ("ga-lbl", "whatsapp_automation"),
          "C9 no description line -> the source-bead: label")
    check(src_ref({"description": "bead_id: ga-x y", "labels": []}) is None and src_ref({"description": "bead_id: --all"}) is None,
          "C9 an id with a space, or one that starts with '-', is not a bead id")
    check(src_ref(None) is None and src_ref({"labels": "source-bead:ga-x", "description": 5}) is None
          and src_ref({"labels": [1, None, {"a": 1}], "description": None}) is None,
          "C9 junk (not a dict, labels that are a string / hold non-strings, a numeric description) is 'no source', never an exception (got %r)"
          % ([src_ref(None), src_ref({"labels": "source-bead:ga-x", "description": 5})],))

    # a record that is not a record (junk in the list) is not a class
    reset_notes()
    q = [qrow("m-a", NOW - 9 * H, "ga-s2", "gascity")]
    w = World(q, {GA_PATH: {"ga-s2": "not-a-record"}})
    sc, _o = with_world(w, lambda: m._marker_source_classes(read_queue(w)))
    check((sc or {}).get("m-a") is None, "C8 a junk answer is unreadable, not a class (got %r)" % (sc,))
else:
    bad("C the watchdog has no _marker_source_classes: it cannot read the priority and type of a marker's source bead")

# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# D. End to end through orphaned_queued_marker(), legacy (overdue-tier) fixture
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
print("Group D: end to end — the marker flagged is the library's head, not the FIFO-oldest (legacy fixture: the dormant proof, ready if an overdue tier returns)")
LEGACY_SRC = r'''#!/usr/bin/env bash
# legacy fixture (ga-yprwyk-era marker-select), see gate-recovery-watchdog.orphan-proof-tiered.selftest.sh
# SELFTEST-EXTRACT marker-select: BEGIN
GATE_MARKER_AGE_PROMOTE_SECONDS="${GATE_MARKER_AGE_PROMOTE_SECONDS:-1800}"
case "$GATE_MARKER_AGE_PROMOTE_SECONDS" in ''|*[!0-9]*) GATE_MARKER_AGE_PROMOTE_SECONDS=1800 ;; esac
GATE_MARKER_HARD_AGE_SECONDS="${GATE_MARKER_HARD_AGE_SECONDS:-$((GATE_MARKER_AGE_PROMOTE_SECONDS * 3))}"
case "$GATE_MARKER_HARD_AGE_SECONDS" in ''|*[!0-9]*) GATE_MARKER_HARD_AGE_SECONDS=$((GATE_MARKER_AGE_PROMOTE_SECONDS * 3)) ;; esac
MARKER=$(printf '%s\n' "$MARKERS_JSON" | jq --argjson hard_threshold "$GATE_MARKER_HARD_AGE_SECONDS" '
  def is_overdue: try (($now - (.created_at | fromdateiso8601)) > $hard_threshold) catch false;
  (map(select(is_overdue)) | sort_by(.created_at)) | .[0]')
# SELFTEST-EXTRACT marker-select: END
log "Attempting to claim marker $MARKER_ID ..."
'''
LEGACY_PATH = os.path.join(TMP, "legacy-quality-gate-dispatcher.sh")
with open(LEGACY_PATH, "w", encoding="utf-8") as _f:
    _f.write(LEGACY_SRC)

def write_log(name, lines):
    p = os.path.join(TMP, name)
    with open(p, "wb") as f:
        f.write(("\n".join(lines) + "\n").encode("utf-8"))
    return p

def poll(world, log_path, src_path=LEGACY_PATH):
    reset_notes()
    saved = (m.sh, m.DISPATCH_LOG, m.DISPATCHER_SRC)
    m.sh, m.DISPATCH_LOG, m.DISPATCHER_SRC = world.sh, log_path, src_path
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            res = m.orphaned_queued_marker()
    except Exception as e:
        res = ("EXC", repr(e), 0)
    finally:
        m.sh, m.DISPATCH_LOG, m.DISPATCHER_SRC = saved
    return res, buf.getvalue()

# Three overdue markers. FIFO-oldest is a P3 chore; the library's first is the NEWEST of them, a P0 feature. The
# dispatcher then claims a marker created AFTER the P0 feature while the P0 feature sat queued and overdue: the skip.
T_CHORE, T_BUG, T_FEAT, T_WIT = NOW - 30000, NOW - 20000, NOW - 9000, NOW - 8000
queue = [qrow("ga-m-p3chore", T_CHORE, "ga-s1", "gascity"),
         qrow("ga-m-p1bug", T_BUG, "wa-s2", "whatsapp_automation"),
         qrow("ga-m-p0feat", T_FEAT, "ga-s3", "gascity", via="label")]
stores = {GA_PATH: {"ga-s1": rec("ga-s1", 3, "chore"), "ga-s3": rec("ga-s3", 0, "feature")},
          WA_PATH: {"wa-s2": rec("wa-s2", 1, "bug")},
          CITY: {"ga-m-witness": {"id": "ga-m-witness", "status": "closed", "created_at": iso(T_WIT), "labels": ["type:quality-gate-marker"]}}}
log_lines = [dl(NOW - 31000, "Found 5 queued marker(s)"),
             dl(NOW - 400, "Attempting to claim marker ga-m-witness ..."),
             dl(NOW - 60, "=== Dispatcher sweep complete: branch=crew/x/last verdict=PASSED ===")]
log_path = write_log("d1.log", log_lines)
w = World(queue, stores)
res, out = poll(w, log_path)
check(res[0] == "ga-m-p0feat",
      "D1 the marker flagged is the P0 FEATURE, the library's head (got %r)%s" % (res, "  <- the FIFO-oldest is ga-m-p3chore: the old rule" if res[0] == "ga-m-p3chore" else ""))
check(res[0] != "EXC", "D1 no exception (got %r)" % (res,))

# the same queue with every source store down: the order degrades to age (FIFO) and the watchdog SAYS the classes were unreadable
w = World(queue, {CITY: stores[CITY]})
res, out = poll(w, write_log("d2.log", log_lines))
check(res[0] == "ga-m-p3chore" and "prio?" in out,
      "D2 no source readable -> order by age, as the gate does, and the unreadable classes are NOTED (got %r, out=%r)" % (res, out.strip()[:160]))

# a fresh queue reads the classes once per poll: a quiet queue (no marker old enough to be a head) spends no source read
young_q = [qrow("ga-m-y1", NOW - 600, "ga-s1", "gascity"), qrow("ga-m-y2", NOW - 300, "ga-s3", "gascity")]
w = World(young_q, stores)
res, out = poll(w, write_log("d3.log", log_lines))
check(res == (None, None, 0) and not w.show_calls,
      "D3 a queue with no marker past the age floor reads NO source bead (got %r, show calls=%r)" % (res, w.show_calls))

# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# E. The registry and the code
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
print("Group E: the consumer row of this slice is gone and the lint is clean")
city = os.path.normpath(os.path.join(scripts_dir, os.pardir))
src_text = open(wd_path, encoding="utf-8", errors="replace").read()
check("valid.sort(key=lambda x: x[2])" not in src_text, "E1 the watchdog no longer sorts the queue head by its own FIFO key")
reg = open(os.path.join(city, "packs/town-deltas/assets/scripts/work-order.registry.tsv"), encoding="utf-8").read().splitlines()
check(not any(ln.startswith("consumer\t") and "\tga-9t9acg.13\t" in ln for ln in reg), "E2 no consumer row is left for ga-9t9acg.13 in work-order.registry.tsv")
lint = subprocess.run([sys.executable, "-I", os.path.join(scripts_dir, "work_order.py"), "lint", "--root", city], capture_output=True, text=True)
check(lint.returncode == 0, "E3 the registry lint is clean over the real tree (rc=%d: %s)" % (lint.returncode, (lint.stdout + lint.stderr).strip().splitlines()[-1][:200] if (lint.stdout + lint.stderr).strip() else ""))

print("\nPASS=%d FAIL=%d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
