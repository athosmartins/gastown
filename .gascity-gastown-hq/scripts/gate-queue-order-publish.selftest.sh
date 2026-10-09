#!/usr/bin/env bash
# gate-queue-order-publish.selftest.sh (ga-dtecvq.1)
#
# WHAT THIS PINS. The dispatcher PUBLISHES, every sweep, the queue order it computed — the markers it ordered (with the
# class that placed each) and the ones it set aside for a retry cooldown — to .gc/runtime/gate-queue-order.json.
# gate-recovery-watchdog.py will prove "a queued marker is invisible to the dispatcher" from it (ga-dtecvq.2): a marker
# that is in NEITHER list, sweep after sweep, was never SEEN — a fact about the dispatcher's input, true whatever the
# order is (the retired proof inferred it from the claim order, which stopped proving anything when ga-q8tj7p made the
# order priority > feature > age). This slice is the writing half; nothing reads the file yet, so it changes no
# behavior beyond writing a small JSON file. The end-to-end cases (dispatcher block -> file -> watchdog reader) live in
# gate-recovery-watchdog.orphan-proof-order.selftest.sh and arrive with the reader.
#
# Groups, over the REAL library and the dispatcher's REAL marker-select block (extracted by its sentinels, never a hand copy):
#   A. the publisher: format, history trim, restart over a corrupt history, clock stepped back, atomic write, every
#      failure returns non-zero and never aborts the sweep, the default path comes from GC_CITY
#   B. the dispatcher publishes: every sweep, in order, INCLUDING the sweep that ends in the all-in-cooldown exit 0;
#      a failed publication or a missing library costs the proof, never the claim
#   D. drift pins: the call sits inside the extract block, after the order is computed and BEFORE any early exit; the
#      lib is loaded fail-soft before the block; the lib is bash 3.2 clean
#
# This file does not self-certify "fails before the fix": run it against the base with DISPATCHER_OVERRIDE / LIB_OVERRIDE
# (or quality-gate-guard.sh's base-test harness, which does so on a throwaway worktree).
#
# Run: bash scripts/gate-queue-order-publish.selftest.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${DISPATCHER_OVERRIDE:-$SCRIPT_DIR/../packs/town-deltas/assets/quality-gate-dispatcher.sh}"
LIB="${LIB_OVERRIDE:-$SCRIPT_DIR/../packs/town-deltas/assets/gate-queue-order-publish.lib.sh}"
[ -f "$DISPATCHER" ] || { echo "FATAL: quality-gate-dispatcher.sh not found at $DISPATCHER"; exit 2; }
# A missing lib is NOT fatal: it is what the base looks like, and the groups must say which cases fail for it.

python3 - "$DISPATCHER" "$LIB" <<'PY'
import atexit, json, os, re, shutil, subprocess, sys, tempfile, time

dispatcher, lib_path = sys.argv[1:3]
for k in list(os.environ):                       # hermetic: a stray override must not move the thresholds under test
    if k.startswith(("GRW_", "GATE_", "GC_")):
        del os.environ[k]

TMP = tempfile.mkdtemp(prefix="gqo-publish-")
atexit.register(shutil.rmtree, TMP, ignore_errors=True)

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)
def check(cond, msg):
    (ok if cond else bad)(msg)

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

def slurp(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None

def ats(path):
    d = doc_of(path)
    if not (isinstance(d, dict) and isinstance(d.get("pubs"), list) and all(isinstance(p, dict) and "at" in p for p in d["pubs"])):
        return None
    return [p["at"] for p in d["pubs"]]

# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# A. The publisher library
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
print("Group A: gate_publish_queue_order — the real library, under %s" % BASH)
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

A = os.path.join(TMP, "a"); os.makedirs(A)
T0 = 1790000000
mkm = lambda ids: [{"id": i, "labels": []} for i in ids]
ORDER = [{"id": "m2", "gate_order_class": "P0/feature"}, {"id": "m1", "gate_order_class": "P2/other"}]

f = os.path.join(A, "order.json")
rc, err = publish(f, mkm(["m1", "m2", "m3", "m1", "m0"]), ORDER, T0)
check(rc == 0 and doc_of(f) == {"v": 1, "pubs": [{"at": T0, "order": [{"id": "m2", "class": "P0/feature"}, {"id": "m1", "class": "P2/other"}],
                                                  "set_aside": ["m0", "m3"]}]},
      "one sweep: {v:1, pubs:[{at, order:[{id,class}] in the dispatcher's order, set_aside: queued ids it did not order, unique}]} (rc=%r, doc=%r)" % (rc, doc_of(f)))
rc, err = publish(os.path.join(A, "empty-order.json"), mkm(["m1", "m2"]), [], T0)
check(rc == 0 and doc_of(os.path.join(A, "empty-order.json"))["pubs"][0]["order"] == []
      and doc_of(os.path.join(A, "empty-order.json"))["pubs"][0]["set_aside"] == ["m1", "m2"],
      "an order that came back EMPTY (every marker in cooldown) is published as an empty order with everything set aside — a sweep that saw the queue")

for i in range(1, 9):
    publish(f, mkm(["m1", "m2"]), ORDER, T0 + 120 * i)
check(ats(f) == [T0 + 120 * i for i in range(3, 9)],
      "the history is trimmed to the last 6 sweeps, oldest first (got %r)" % (ats(f),))
for keep, want in (("3", 3), ("junk", 6), ("0", 6), ("", 6)):
    fk = os.path.join(A, "keep-%s.json" % (keep or "empty"))
    for i in range(8):
        publish(fk, mkm(["m1"]), ORDER, T0 + 120 * i, env={"GATE_QUEUE_ORDER_KEEP": keep})
    check(len(ats(fk) or []) == want, "GATE_QUEUE_ORDER_KEEP=%r keeps %d sweeps (got %r)" % (keep, want, len(ats(fk) or [])))

for label, content in (("empty file", ""), ("not JSON", "garbage{"), ("other version", '{"v":2,"pubs":[{"at":1,"order":[],"set_aside":[]}]}'),
                       ("pubs not a list", '{"v":1,"pubs":"x"}'), ("a JSON array", "[]"), ("JSON null", "null"),
                       ("a publication that is a number", '{"v":1,"pubs":[1]}'), ("a publication without a time", '{"v":1,"pubs":[{"at":"x"}]}')):
    fc = os.path.join(A, "corrupt.json")
    with open(fc, "w") as fh:
        fh.write(content)
    rc, err = publish(fc, mkm(["m1"]), ORDER, T0)
    check(rc == 0 and ats(fc) == [T0],
          "a history that cannot be read back (%s) is DROPPED: restart from this sweep alone — a short history makes the reader abstain, a merged-over-garbage one could make it assert (rc=%r, got %r)" % (label, rc, ats(fc)))

fcl = os.path.join(A, "clock.json")
for t in (T0, T0 + 100, T0 + 200):
    publish(fcl, mkm(["m1"]), ORDER, t)
publish(fcl, mkm(["m1"]), ORDER, T0 + 150)
check(ats(fcl) == [T0, T0 + 100, T0 + 150], "clock stepped BACK: publications from the future are dropped, so the history stays strictly increasing (got %r)" % (ats(fcl),))
publish(fcl, mkm(["m1"]), ORDER, T0 + 150)
check(ats(fcl) == [T0, T0 + 100, T0 + 150], "the same second twice replaces, never duplicates (got %r)" % (ats(fcl),))

leftovers = [n for n in os.listdir(A) if ".tmp." in n]
check(not leftovers, "the write is a rename: no .tmp.* file is left behind (found %r)" % (leftovers,))

blocker = os.path.join(A, "blocker")
with open(blocker, "w") as fh:
    fh.write("x")
rc, err = publish(os.path.join(blocker, "sub", "order.json"), mkm(["m1"]), ORDER, T0)
check(rc == 1 and "nothing published" in err, "a path whose parent cannot be created -> rc=1 and a warning, nothing aborted (rc=%r, stderr=%r)" % (rc, err.strip()))
dirfile = os.path.join(A, "dirfile"); os.makedirs(dirfile)
rc, err = publish(dirfile, mkm(["m1"]), ORDER, T0)
check(rc == 1 and os.listdir(dirfile) == [] and "directory" in err,
      "a directory at the output path -> rc=1, and nothing was moved INTO it (mv -f would have succeeded) (rc=%r, entries=%r)" % (rc, os.listdir(dirfile)))
if os.geteuid() != 0:
    ro = os.path.join(A, "ro"); os.makedirs(ro)
    fr = os.path.join(ro, "order.json")
    publish(fr, mkm(["m1"]), ORDER, T0)
    before = slurp(fr)
    os.chmod(ro, 0o555)
    try:
        rc, err = publish(fr, mkm(["m1"]), ORDER, T0 + 120)
    finally:
        os.chmod(ro, 0o755)
    check(rc == 1 and slurp(fr) == before and not [n for n in os.listdir(ro) if ".tmp." in n] and "WARN" in err,
          "an unwritable directory -> rc=1 + warning; the previous publication is intact and no tmp file is left (rc=%r)" % (rc,))
else:
    print("  (skipped: running as root, a read-only directory is writable)")

fb = os.path.join(A, "bad-input.json")
for label, kw in (("empty clock", dict(now="")), ("non-numeric clock", dict(now="abc")), ("fractional clock", dict(now="12.5")), ("negative clock", dict(now="-3"))):
    rc, err = publish(fb, mkm(["m1"]), ORDER, kw["now"])
    check(rc == 1 and not os.path.exists(fb), "%s -> rc=1 and no file written (rc=%r)" % (label, rc))
publish(fb, mkm(["m1"]), ORDER, T0)
before = slurp(fb)
rc, err = publish(fb, mkm(["m1"]), "this is not json", T0 + 120)
check(rc == 1 and slurp(fb) == before and "nothing published" in err,
      "an order that is not JSON -> rc=1 and the previous publication untouched (rc=%r)" % (rc,))
rc, err = publish(None, mkm(["m1"]), ORDER, T0)
check(rc == 1 and "GC_CITY" in err, "no file path at all (GC_CITY unset, no override) -> rc=1 and the warning names GC_CITY (rc=%r, stderr=%r)" % (rc, err.strip()))

# the default path: the dispatcher knows GC_CITY. The reader (ga-dtecvq.2) pins the same path on its side.
city = os.path.join(TMP, "city")
rc, err = publish(None, mkm(["m1"]), ORDER, T0, env={"GC_CITY": city})
written = os.path.join(city, ".gc", "runtime", "gate-queue-order.json")
check(rc == 0 and os.path.isfile(written), "GC_CITY alone: published to $GC_CITY/.gc/runtime/gate-queue-order.json, directories created (rc=%r)" % (rc,))

# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# B. The dispatcher's REAL marker-select block publishes
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
print("Group B: the dispatcher's own marker-select block (sentinel-extracted) publishes the order it computed")
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

fb1 = os.path.join(TMP, "b1.json")
rc, sel, err = run_select([qm(HEAD, OLD, prio=3), qm("ga-p0-b", NOW - 100, prio=0), qm("ga-p0-a", NOW - 200, prio=0, typ="feature")], T0, fb1)
d = doc_of(fb1)
pubs = d["pubs"] if isinstance(d, dict) else []
check(rc == 0 and sel == "ga-p0-a" and len(pubs) == 1 and [e["id"] for e in pubs[0]["order"]] == ["ga-p0-a", "ga-p0-b", HEAD]
      and [e["class"] for e in pubs[0]["order"]] == ["P0/feature", "P0/other", "P3/other"] and pubs[0]["at"] == T0 and pubs[0]["set_aside"] == [],
      "the sweep publishes the order the dispatcher claimed from, with the class that placed each marker (rc=%r, selected=%r, doc=%r)" % (rc, sel, d))

fb2 = os.path.join(TMP, "b2.json")
cool = qm("ga-cool", NOW - 5000, prio=0, labels=["gate:retry-cooldown-until:%d" % (T0 + 3600)])
rc, sel, err = run_select([qm("ga-p2", NOW - 300), cool], T0, fb2)
d = doc_of(fb2)
check(rc == 0 and sel == "ga-p2" and len(pubs_of(fb2)) == 1 and [e["id"] for e in pubs_of(fb2)[0]["order"]] == ["ga-p2"] and pubs_of(fb2)[0]["set_aside"] == ["ga-cool"],
      "a marker inside its retry cooldown is SET ASIDE, not absent: the dispatcher saw it (doc=%r)" % (d,))

fb3 = os.path.join(TMP, "b3.json")
for i in range(4):
    rc, sel, err = run_select([cool], T0 + 120 * i, fb3)
check(rc == 0 and sel is None and ats(fb3) == [T0 + 120 * i for i in range(4)]
      and all(p["order"] == [] and p["set_aside"] == ["ga-cool"] for p in pubs_of(fb3)),
      "the all-in-cooldown sweep ends in `exit 0` — and STILL published (order [], set_aside [it]): the call sits before the exit (rc=%r, selected=%r, ats=%r)" % (rc, sel, ats(fb3)))

fb4 = os.path.join(blocker, "sub", "order.json")                      # parent is a regular file: the publication CANNOT succeed
rc, sel, err = run_select([qm("ga-p2", NOW - 300)], T0, fb4)
check(rc == 0 and sel == "ga-p2" and "nothing published" in err,
      "a publication that FAILS does not abort the sweep under `set -euo pipefail`: the marker is still claimed, and the warning is printed (rc=%r, selected=%r)" % (rc, sel))

fb5 = os.path.join(TMP, "b5.json")
rc, sel, err = run_select([qm("ga-p2", NOW - 300)], T0, fb5, with_lib=False)
check(rc == 0 and sel == "ga-p2" and not os.path.exists(fb5),
      "a MISSING library (function undefined) costs the proof, never the sweep: the marker is still claimed, nothing is written (rc=%r, selected=%r)" % (rc, sel))

# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# D. Drift pins
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
print("Group D: where the call sits, what the library may use")
code = "\n".join(l for l in block.splitlines() if not l.lstrip().startswith("#"))
CALL = 'gate_publish_queue_order "$MARKERS_JSON" "$MARKER_ORDER_JSON" "$GATE_MARKER_NOW_EPOCH"'
i_order, i_sum, i_call, i_exit = (code.find("MARKER_ORDER_JSON=$("), code.find("MARKER_ORDER_SUMMARY="), code.find(CALL), code.find("exit 0"))
check(0 <= i_order < i_sum < i_call < i_exit,
      "the publish call is inside the extract block, after the order is computed and BEFORE the all-in-cooldown `exit 0` (offsets order=%d summary=%d call=%d exit=%d)" % (i_order, i_sum, i_call, i_exit))
line = next((l for l in code.splitlines() if CALL in l), "")
guard = code[max(0, i_call - 120):i_call] if i_call >= 0 else ""
check("type gate_publish_queue_order >/dev/null 2>&1" in guard and line.rstrip().endswith("|| true"),
      "the call is guarded by `type` (a missing library is not a failed sweep) and ends in `|| true` (a failed publication is not either)")
dsrc = open(dispatcher, encoding="utf-8").read()
i_src = dsrc.find("gate-queue-order-publish.lib.sh")
i_blk = dsrc.find("# SELFTEST-EXTRACT marker-select: BEGIN")
src_line = dsrc[dsrc.rfind("\n", 0, dsrc.find('source "$_GQOP_SCRIPT"')) + 1:dsrc.find("\n", dsrc.find('source "$_GQOP_SCRIPT"'))] if 'source "$_GQOP_SCRIPT"' in dsrc else ""
check(0 <= i_src < i_blk and '[ -r "$_GQOP_SCRIPT" ]' in src_line,
      "the dispatcher loads the library BEFORE the block, with the same fail-soft `[ -r ]` convention as its other libs (a bare `source` of a missing file would kill the sweep under set -e)")
r = subprocess.run([BASH, "-n", lib_path], capture_output=True, text=True) if os.path.isfile(lib_path) else None
check(r is not None and r.returncode == 0, "the library parses under %s (bash -n)" % BASH)
lib_code = "\n".join(l for l in (open(lib_path, encoding="utf-8").read().splitlines() if os.path.isfile(lib_path) else []) if not l.lstrip().startswith("#"))
check(bool(lib_code) and not re.search(r"declare\s+-A|local\s+-A|\bmapfile\b|\breadarray\b|\$\{[A-Za-z_]+(,,|\^\^)", lib_code),
      "the library uses no bash 4 feature (associative arrays, mapfile/readarray, ${var,,}/${var^^}) — launchd runs the dispatcher under bash 3.2")

print("\nPASS=%d FAIL=%d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
