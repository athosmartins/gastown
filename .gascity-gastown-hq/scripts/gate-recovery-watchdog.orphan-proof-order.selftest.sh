#!/usr/bin/env bash
# gate-recovery-watchdog.orphan-proof-order.selftest.sh (ga-dtecvq.2)
#
# WHAT BROKE. gate-recovery-watchdog.py proved "a queued marker is invisible to the dispatcher" from the
# dispatcher's CLAIM ORDER: "a newer marker was claimed while this older one was overdue". That was only a proof
# while an overdue tier made the order priority-blind. ga-q8tj7p made the order priority > feature > age, so a newer
# P0 legitimately beats an older P3 for as long as P0s keep arriving — the proof was retired (and, with it, the
# detector went permanently silent: 'cannot prove', never 'orphan').
#
# WHAT REPLACES IT. The dispatcher PUBLISHES what it computed each sweep (the markers it ordered, with the class that
# placed each, and the ones it set aside for a retry cooldown) to .gc/runtime/gate-queue-order.json. A queued marker
# that is in NEITHER list, sweep after sweep, was never SEEN — a fact about the dispatcher's input, true whatever the
# order is. That is the only thing the watchdog proves now.
#
# THIS FILE is the reading half and the end to end. The writing half (the publisher library, every way it can fail,
# the dispatcher's call site) is gate-queue-order-publish.selftest.sh (ga-dtecvq.1), which merges first. Here: the REAL
# publisher library, the dispatcher's REAL marker-select block (extracted by its sentinels, never a hand copy) and the
# watchdog's REAL reader, wired through a real file. The verdict-level cases (every boundary of the proof) live in
# gate-recovery-watchdog.selftest.sh; here is what only the wiring can break:
#   A. writer and reader agree on the default path, and the reader reads what the library wrote
#   B. acceptance, through the real chain:
#        (a) an old P3 head waiting behind a stream of P0s            -> silence
#        (b) a head absent from the published order K sweeps in a row -> flagged, with the evidence
#        (c) published order unreadable/absent/short/stale            -> 'cannot prove', never 'orphan'
#   C. drift pins: the legacy claim-order machinery is gone from the watchdog; the new proof reads only the published file
#   D. the pins ga-9t9acg.13 left behind, kept: the watchdog picks no head by its own FIFO key, no registry consumer row
#      is left for that slice, and the work-order registry lint is clean over the real tree
#
# This file does not self-certify "fails before the fix": run it against the base with WD_OVERRIDE / DISPATCHER_OVERRIDE
# / LIB_OVERRIDE (or quality-gate-guard.sh's base-test harness, which does so on a throwaway worktree).
#
# Run: bash scripts/gate-recovery-watchdog.orphan-proof-order.selftest.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="${WD_OVERRIDE:-$SCRIPT_DIR/gate-recovery-watchdog.py}"
DISPATCHER="${DISPATCHER_OVERRIDE:-$SCRIPT_DIR/../packs/town-deltas/assets/quality-gate-dispatcher.sh}"
LIB="${LIB_OVERRIDE:-$SCRIPT_DIR/../packs/town-deltas/assets/gate-queue-order-publish.lib.sh}"
[ -f "$WD" ] || { echo "FATAL: gate-recovery-watchdog.py not found at $WD"; exit 2; }
[ -f "$DISPATCHER" ] || { echo "FATAL: quality-gate-dispatcher.sh not found at $DISPATCHER"; exit 2; }
# A missing lib is NOT fatal: it is what the base looks like, and the groups must say which cases fail for it.

python3 - "$WD" "$DISPATCHER" "$LIB" "$SCRIPT_DIR" <<'PY'
import atexit, contextlib, importlib.util, inspect, io, json, os, re, shutil, subprocess, sys, tempfile, time

wd_path, dispatcher, lib_path, scripts_dir = sys.argv[1:5]
sys.path.insert(0, scripts_dir)
for k in list(os.environ):                       # hermetic: a stray override must not move the thresholds under test
    if k.startswith(("GRW_", "GATE_", "GC_")):
        del os.environ[k]

def load():
    spec = importlib.util.spec_from_file_location("grw_order", wd_path)
    mod = importlib.util.module_from_spec(spec)
    saved = sys.argv
    sys.argv = ["grw"]                           # __name__ != "__main__" -> main() never runs
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.argv = saved
    return mod
m = load()

TMP = tempfile.mkdtemp(prefix="grw-order-")
atexit.register(shutil.rmtree, TMP, ignore_errors=True)

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)
def check(cond, msg):
    (ok if cond else bad)(msg)

class Patch(object):
    def __init__(self, **kw): self.kw = kw
    def __enter__(self):
        self.old = dict((k, getattr(m, k, None)) for k in self.kw)
        for k, v in self.kw.items(): setattr(m, k, v)
    def __exit__(self, *a):
        for k, v in self.old.items(): setattr(m, k, v)

NOW = time.time()
def iso(t): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))

BASH = "/bin/bash" if os.path.exists("/bin/bash") else "bash"     # launchd's bash (3.2 on macOS): what the dispatcher really runs under

def bash(script, env=None):
    e = {k: v for k, v in os.environ.items() if not k.startswith(("GATE_", "GRW_", "GC_"))}
    e["LIB"] = lib_path
    e.update(env or {})
    return subprocess.run([BASH, "-c", script], env=e, capture_output=True, text=True, timeout=120)

def doc_of(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None

def pubs_of(path):
    """The publications on file, [] when there is no readable document (a failing assertion must not crash the run)."""
    d = doc_of(path)
    return [p for p in d["pubs"] if isinstance(p, dict)] if isinstance(d, dict) and isinstance(d.get("pubs"), list) else []


# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# A. Writer and reader agree
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
print("Group A: writer and reader agree — the real publisher library and the watchdog's real reader, under %s" % BASH)
check(os.path.isfile(lib_path), "the publisher library exists at %s" % lib_path)

def publish(path, markers, order, now, env=None, warn=True):
    script = ('source "$LIB" 2>/dev/null\n' + ('warn() { echo "WARN: $*" >&2; }\n' if warn else "") +
              'gate_publish_queue_order "$MARKERS" "$ORDER" "$NOW"\necho "rc=$?"')
    e = {"MARKERS": json.dumps(markers) if not isinstance(markers, str) else markers,
         "ORDER": json.dumps(order) if not isinstance(order, str) else order, "NOW": str(now)}
    if path is not None:
        e["GATE_QUEUE_ORDER_FILE"] = path
    e.update(env or {})
    r = bash(script, e)
    rc = [l for l in r.stdout.splitlines() if l.startswith("rc=")]
    return (int(rc[-1][3:]) if rc else None), r.stderr

T0 = 1790000000
mkm = lambda ids: [{"id": i, "labels": []} for i in ids]
ORDER = [{"id": "m2", "gate_order_class": "P0/feature"}, {"id": "m1", "gate_order_class": "P2/other"}]

# writer and reader must agree on the default path: the dispatcher knows GC_CITY, the watchdog knows GC_CITY_PATH
city = os.path.join(TMP, "city")
rc, err = publish(None, mkm(["m1"]), ORDER, T0, env={"GC_CITY": city})
written = os.path.join(city, ".gc", "runtime", "gate-queue-order.json")
check(rc == 0 and os.path.isfile(written), "GC_CITY alone: published to $GC_CITY/.gc/runtime/gate-queue-order.json, directories created (rc=%r)" % (rc,))
os.environ["GC_CITY_PATH"] = city
try:
    m_city = load()
finally:
    del os.environ["GC_CITY_PATH"]
check(getattr(m_city, "ORPHAN_ORDER_FILE", None) == written,
      "the watchdog's default order file is that same path (got %r) — writer and reader cannot drift apart" % (getattr(m_city, "ORPHAN_ORDER_FILE", None),))
if hasattr(m_city, "_read_published_orders"):
    pubs_c, why_c = m_city._read_published_orders()
    check(pubs_c is not None and len(pubs_c) == 1 and pubs_c[0]["ids"] == frozenset(["m1", "m2"]),
          "...and it reads what the library wrote: both the ordered and the set-aside ids count as seen (got %r, %r)" % (pubs_c, why_c))
else:
    bad("watchdog has no _read_published_orders")

# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# The dispatcher's REAL marker-select block, extracted by its sentinels (its publishing is pinned in gate-queue-order-publish.selftest.sh)
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
block = subprocess.run(["sed", "-n", "/# SELFTEST-EXTRACT marker-select: BEGIN/,/# SELFTEST-EXTRACT marker-select: END/p", dispatcher],
                       capture_output=True, text=True).stdout
check(bool(block.strip()), "located the live marker-select block via its sentinels")

def qm(mid, created, prio=2, typ="task", labels=()):
    return {"id": mid, "created_at": iso(created), "description": "branch: crew/wa-worker/%s" % mid,
            "labels": ["gate-status:queued"] + list(labels), "src_class": {"state": "ok", "priority": prio, "type": typ}}

def run_select(markers, now, order_file, with_lib=True):
    """The block under the dispatcher's own `set -euo pipefail`, with the lib loaded the way the dispatcher loads it."""
    script = ("set -euo pipefail\n"
              'log() { echo "LOG: $*" >&2; }\nwarn() { echo "WARN: $*" >&2; }\nCOUNT=%d\n' % len(markers) +
              ('[ -r "$LIB" ] && { source "$LIB" 2>/dev/null; } || true\n' if with_lib else "") +
              block + '\necho "SELECTED=${MARKER_ID:-}"')
    r = bash(script, {"MARKERS_JSON": json.dumps(markers), "GATE_MARKER_NOW_OVERRIDE_EPOCH": str(int(now)), "GATE_QUEUE_ORDER_FILE": order_file})
    sel = [l for l in r.stdout.splitlines() if l.startswith("SELECTED=")]
    return r.returncode, (sel[-1][len("SELECTED="):] if sel else None), r.stderr

HEAD, HEAD_BR = "ga-oldp3", "crew/wa-worker/ga-oldp3"
OLD = NOW - 7200

# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# B. Acceptance, through the real chain: dispatcher block -> file -> watchdog reader -> orphaned_queued_marker()
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
print("Group B: the acceptance cases, end to end")

def chain(name, queues, step=120, newest_ago=60):
    """Run the dispatcher's real block once per queue (oldest sweep first, the newest `newest_ago`s ago); return the file."""
    path = os.path.join(TMP, "chain-%s.json" % name)
    n = len(queues)
    for i, q in enumerate(queues):
        run_select(q, int(NOW) - newest_ago - step * (n - 1 - i), path)
    return path

def head_row(updated=None):
    return (HEAD, HEAD_BR, OLD, ("gate-status:queued",), OLD if updated is None else updated)

def p0(i):
    return qm("ga-p0-%d" % i, NOW - 90 - 10 * i, prio=0, typ="feature")

def verdict(path, rows):
    m._ORPHAN_NOTED.clear(); m._ORPHAN_EVIDENCE.clear()
    buf = io.StringIO()
    try:
        with Patch(ORPHAN_ORDER_FILE=path, _queued_markers_read=lambda: rows), contextlib.redirect_stdout(buf):
            res = m.orphaned_queued_marker()
    except Exception as e:                    # an older watchdog copy (WD_OVERRIDE) has a different shape: report, don't crash
        res = ("EXC", repr(e), 0)
    return res, buf.getvalue()

QUIET = (None, None, 0)

# (a) an OLD P3 head waiting behind a stream of fresh P0s — the exact shape the retired proof called an orphan
pa = chain("a", [[qm(HEAD, OLD, prio=3), p0(i)] for i in range(5)])
da = doc_of(pa)
check(da and len(da["pubs"]) == 5 and all([e["id"] for e in p["order"]][-1] == HEAD and p["order"][-1]["class"] == "P3/other" for p in da["pubs"]),
      "precondition: in every one of 5 real sweeps the dispatcher ordered the P3 head LAST, behind the P0 that arrived that sweep")
res, out = verdict(pa, [head_row(), (p0(4)["id"], "crew/wa-worker/x", NOW - 130, ("gate-status:queued",), NOW - 130)])
check(res == QUIET and out == "",
      "(a) the old P3 head behind P0s -> silence: no orphan and no 'cannot prove' note either (got %r, output %r)" % (res, out))

# (b) a head the dispatcher never saw
pb = chain("b", [[p0(i)] for i in range(5)])
res, out = verdict(pb, [head_row()])
ev = m._ORPHAN_EVIDENCE.get(HEAD, "") if hasattr(m, "_ORPHAN_EVIDENCE") else ""
check(res[0] == HEAD and res[1] == HEAD_BR and abs(res[2] - 7200) < 300,          # NOW was read when the file started; the chains above take a while
      "(b) a head absent from the published order in the last 3 consecutive sweeps -> flagged (got %r)" % (res,))
check("absent from the dispatcher's published queue order" in ev and "last 3 sweeps" in ev and "never saw it" in ev,
      "(b) ...and the evidence says what was proven, over how many sweeps (%r)" % (ev,))
check(out == "", "(b) ...with no 'cannot prove' note: the proof was available (output %r)" % (out,))

pb1 = chain("b-newest-only", [[p0(i)] for i in range(4)] + [[qm(HEAD, OLD, prio=3), p0(4)]])
res, out = verdict(pb1, [head_row()])
check(res == QUIET, "(b) seen in the NEWEST sweep only -> silence: the dispatcher sees it now, whatever it missed before (got %r)" % (res,))
pb2 = chain("b-oldest-only", [[p0(0)], [qm(HEAD, OLD, prio=3), p0(1)], [p0(2)], [p0(3)], [p0(4)]])      # 5 sweeps: the window is #3..#5
res, out = verdict(pb2, [head_row()])
check(res[0] == HEAD, "(b) seen only in a sweep OUTSIDE the last 3 (the window is K consecutive sweeps) -> flagged (got %r)" % (res,))
pb3 = chain("b-mid", [[p0(0)], [p0(1)], [p0(2)], [qm(HEAD, OLD, prio=3), p0(3)], [p0(4)]])
res, out = verdict(pb3, [head_row()])
check(res == QUIET, "(b) seen in ONE of the last 3 sweeps (the middle one) -> silence (got %r)" % (res,))

res, out = verdict(pb, [head_row(updated=NOW - 300)])
check(res == QUIET and out == "",
      "(b) the marker was re-queued INSIDE the window (updated_at after the oldest of the 3 sweeps) -> silence: it was never in a position to be seen (got %r)" % (res,))

pcd = chain("cooldown", [[qm(HEAD, OLD, prio=3, labels=["gate:retry-cooldown-until:%d" % (int(NOW) + 3600)])]] * 5)
res, out = verdict(pcd, [head_row()])
check(res == QUIET and out == "" and all(p["set_aside"] == [HEAD] for p in pubs_of(pcd)),
      "(b) a marker in its retry cooldown through all-in-cooldown sweeps (each ended in `exit 0`) is SET ASIDE in each -> silence (got %r)" % (res,))

# (c) the order cannot be read / cannot be trusted -> "cannot prove", never "orphan" (same head as (b): it IS flagged when the file is good)
def unavailable(label, path, reason):
    res, out = verdict(path, [head_row()])
    check(res == QUIET and ("orphan-proof unavailable (%s)" % reason) in out,
          "(c) %s -> 'cannot prove' (%s), never 'orphan' (got %r, output %r)" % (label, reason, res, out.strip()))

unavailable("no queue-order file", os.path.join(TMP, "never-written.json"), "order-unreadable")
junk = os.path.join(TMP, "junk.json")
with open(junk, "w") as fh:
    fh.write("{garbage")
unavailable("a file that is not JSON", junk, "order-unreadable")
v2 = os.path.join(TMP, "v2.json")
with open(v2, "w") as fh:
    json.dump({"v": 2, "pubs": pubs_of(pb)}, fh)
unavailable("a version the reader does not know", v2, "order-unreadable")
unavailable("a single published sweep", chain("short", [[p0(0)]]), "short-history")
unavailable("a dispatcher that stopped publishing 90min ago", chain("stale", [[p0(i)] for i in range(5)], newest_ago=5400), "stale")
res, out = verdict(pb, None)
check(res == QUIET and "orphan-proof unavailable (queue-unreadable)" in out,
      "(c) the queued-marker list itself unreadable (bd failed) -> 'cannot prove' (queue-unreadable), never 'no orphan' (got %r, output %r)" % (res, out.strip()))
# the note is rate-limited, not repeated each 2-minute poll
m._ORPHAN_NOTED.clear()
buf = io.StringIO()
with Patch(ORPHAN_ORDER_FILE=os.path.join(TMP, "never-written.json"), _queued_markers_read=lambda: [head_row()]), contextlib.redirect_stdout(buf):
    for _ in range(5):
        m.orphaned_queued_marker()
check(buf.getvalue().count("orphan-proof unavailable") == 1,
      "(c) five polls against the same unreadable file print the note ONCE, not five times (got %d)" % buf.getvalue().count("orphan-proof unavailable"))
res, out = verdict(os.path.join(TMP, "never-written.json"), [(HEAD, HEAD_BR, NOW - 600, ("gate-status:queued",), NOW - 600)])
check(res == QUIET and out == "", "(c) ...and a marker too young to need a proof does not even read the file or print a note (got %r, output %r)" % (res, out))

# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# C. Drift pins
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
print("Group C: what is gone from the watchdog, what the new proof may read")
LEGACY = ["_dispatcher_claims", "_dispatcher_hard_age", "_dispatcher_hard_age_from", "_dispatcher_has_overdue_tier", "_dispatcher_has_overdue_tier_from",
          "_dispatcher_log_state", "_marker_created_epoch", "_orphan_head", "_cooldown_covers", "_detect_orphan_markers", "_log_first_epoch",
          "_queued_markers", "ORPHAN_PROOF_MARGIN_SEC", "ORPHAN_LOG_FRESH_SEC", "ORPHAN_CLAIM_TAIL_LINES", "ORPHAN_WITNESS_LOOKUPS",
          "ORPHAN_TUNABLES_TTL_SEC", "DISPATCHER_SRC", "DISPATCHER_LAUNCHD_LABEL", "DISPATCH_CLAIM_RE"]
left = [n for n in LEGACY if hasattr(m, n)]
check(not left, "the claim-order machinery is gone from the watchdog (still defined: %r)" % (left,))
parts = {}
for n in ("_orphan_candidates", "_orphan_verdict", "_read_published_orders", "_published_sweep", "orphaned_queued_marker"):
    fn = getattr(m, n, None)
    parts[n] = inspect.getsource(fn) if fn is not None else ""
check(all(parts.values()), "the new proof's functions exist: %s" % ", ".join(sorted(parts)))
body = "\n".join("\n".join(l for l in s.splitlines() if not l.lstrip().startswith("#")) for s in parts.values())
check(bool(body) and not re.search(r"DISPATCH_LOG|_read_log_last_lines|Attempting to claim|\bsh\(", body),
      "the proof reads only the published file and the queued-marker list: no dispatcher log, no claim lines, no bd call of its own")

print("Group D: the head-picking this proof replaced is not back, and the shared-order registry is clean (ga-9t9acg.13 pins, kept)")
city = os.path.normpath(os.path.join(scripts_dir, os.pardir))
src_text = open(wd_path, encoding="utf-8", errors="replace").read()
check("valid.sort(key=lambda x: x[2])" not in src_text,
      "D1 the watchdog does not pick a head by its own FIFO key (the order is the dispatcher's, published — never re-derived here)")
reg = open(os.path.join(city, "packs/town-deltas/assets/scripts/work-order.registry.tsv"), encoding="utf-8").read().splitlines()
check(not any(ln.startswith("consumer\t") and "\tga-9t9acg.13\t" in ln for ln in reg),
      "D2 no consumer row is left for ga-9t9acg.13 in work-order.registry.tsv (the consumer is gone with the claim-order proof)")
lint = subprocess.run([sys.executable, "-I", os.path.join(scripts_dir, "work_order.py"), "lint", "--root", city], capture_output=True, text=True)
lint_out = (lint.stdout + lint.stderr).strip()
check(lint.returncode == 0, "D3 the registry lint is clean over the real tree (rc=%d: %s)" % (lint.returncode, lint_out.splitlines()[-1][:200] if lint_out else ""))

print("\nPASS=%d FAIL=%d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
