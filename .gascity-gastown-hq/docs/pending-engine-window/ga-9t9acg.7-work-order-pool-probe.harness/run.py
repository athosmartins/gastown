#!/usr/bin/env python3
"""ga-9t9acg.7 no-compile harness: run the generated work-query shell (old baseline vs patched) through a
fake `bd` on fixtures, with the real work-order.sh, a missing lib and erroring / noisy / wrong-answer libs.

usage: run.py PROMPT_TXT CONFIG_GO CITY_PATH SHELL        (SHELL = sh | /bin/dash | ...)
"""
import json, os, shutil, stat, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(__file__))
import gen

PROMPT, GO, CITY, SH = sys.argv[1:5]
base, WO_DEF, TAIL, LRU, SRC = gen.load(PROMPT, GO)
TRUST = gen.go_const(SRC, "workOrderPickTrustsLib")
SCRIPTS = {k: gen.patch_script(k, v[2], TAIL, LRU) for k, v in base.items()}
OLD = {k: v[2] for k, v in base.items()}


def strip_end(s):
    assert s.endswith('printf "[]"')
    return s[: -len('printf "[]"')]


# the full default work_query = assigned in-progress + assigned ready + (origin gate .. probe .. printf "[]")
FULL_OLD = strip_end(OLD["inprogress"]) + strip_end(OLD["ready"]) + OLD["routed"]
FULL_NEW = WO_DEF + strip_end(SCRIPTS["inprogress"]) + strip_end(SCRIPTS["ready"]) + SCRIPTS["routed"]
CMD_OLD = {"inprogress": OLD["inprogress"], "ready": OLD["ready"], "routed": OLD["routed"], "full": FULL_OLD}
CMD_NEW = {k: WO_DEF + v for k, v in SCRIPTS.items()}
CMD_NEW["full"] = FULL_NEW

MUTATE = os.environ.get("MUTATE", "")
if MUTATE:
    def _mut(old, new):
        global CMD_NEW
        n = sum(v.count(old) for v in CMD_NEW.values())
        assert n > 0, "mutation %s hit nothing (%r)" % (MUTATE, old)
        CMD_NEW = {k: v.replace(old, new) for k, v in CMD_NEW.items()}
    if MUTATE == "age-created":
        _mut("work_order_sort --age reclaim", "work_order_sort --age created")
    elif MUTATE == "window-20":
        _mut(" --limit 0", " --limit=20")
    elif MUTATE == "no-sort":
        _mut("work_order_sort --age reclaim", "cat")
    elif MUTATE == "dot-in-sh":   # the idiom the bead text suggested: source into the sh that runs the query
        i0 = WO_DEF.index('if [ -r "$wo_lib" ]; then')
        i1 = WO_DEF.index('printf "%s" "$wo_in" | jq -c "${1:-.}"')
        _mut(WO_DEF[i0:i1], 'wo_out=""; . "$wo_lib" 2>/dev/null && wo_out=$(printf "%s" "$wo_in" | work_order_sort --age reclaim); [ -n "$wo_out" ] && { printf "%s" "$wo_out"; return 0; }; ')
    elif MUTATE == "no-fallback":
        _mut('printf "%s" "$wo_in" | jq -c "${1:-.}" 2>/dev/null; ', ':; ')
    elif MUTATE == "swallow-warn":  # the city's habit: 2>/dev/null on the lib call
        _mut("work_order_sort --age reclaim' wo \"$wo_lib\")", "work_order_sort --age reclaim' wo \"$wo_lib\" 2>/dev/null)")
    elif MUTATE == "trust-nonempty":  # the check this fix replaced: any non-empty stdout is "the answer"
        _mut(TRUST, '[ -n "$wo_out" ]')
    elif MUTATE == "ignore-exit-status":  # the array check without the exit status
        _mut('[ "$wo_rc" -eq 0 ] && ', '')
    elif MUTATE == "ignore-length":  # exit 0 + one array, but not as long as the input (a lib that drops beads)
        _mut(' and length == $n)', ')')
    else:
        raise SystemExit("unknown mutation " + MUTATE)

BD = r'''#!/usr/bin/env python3
import sys, os, json
fx = os.environ["FX"]
args = sys.argv[1:]
open(os.path.join(fx, "calls.log"), "a").write(" ".join(args) + "\n")
j = " ".join(args)
def lim():
    for i, a in enumerate(args):
        if a == "--limit" and i + 1 < len(args): return int(args[i + 1])
        if a.startswith("--limit="): return int(a.split("=", 1)[1])
    return 0
key = None
if args[0] == "ready":
    if any(a.startswith("--assignee=") for a in args): key = "ready_assigned"
    elif "gc.routed_to=" in j: key = "routed"
    elif "gc.run_target=" in j: key = "migration"
elif args[0] == "list":
    if "--parent" in j: print("[]"); sys.exit(0)
    if "in_progress" in j: key = "inprogress"
elif args[0] == "query":
    key = "eph_open" if "status=open" in j else "eph_inprogress"
p = os.path.join(fx, key + ".json") if key else None
if p and os.path.exists(p) and os.path.getsize(p) and open(p).read(1) != "!":
    data = json.load(open(p))
elif p and os.path.exists(p):
    sys.stdout.write("this is not json"); sys.exit(0)
else:
    data = []
l = lim()
if l > 0: data = data[:l]
sys.stdout.write(json.dumps(data))
'''


def bead(i, prio, typ, created, updated=None, labels=None, **kw):
    b = {"id": i, "priority": prio, "issue_type": typ, "created_at": created, "updated_at": updated or created,
         "labels": labels or [], "metadata": {"gc.routed_to": "gastown.dog"}}
    b.update(kw)
    return b


def run(cmd_key, which, fx, env_extra, lib_mode, argv_tail=("--", "gastown.dog"), shell=SH):
    tmp = tempfile.mkdtemp(prefix="wo-h-")
    bindir = os.path.join(tmp, "bin")
    os.makedirs(bindir)
    open(os.path.join(bindir, "bd"), "w").write(BD)
    os.chmod(os.path.join(bindir, "bd"), 0o755)
    os.symlink("/bin/bash", os.path.join(bindir, "bash"))  # macOS bash 3.2, the one the lib promises to support
    fxd = os.path.join(tmp, "fx")
    os.makedirs(fxd)
    for k, v in fx.items():
        open(os.path.join(fxd, k + ".json"), "w").write(v if isinstance(v, str) else json.dumps(v))
    env = {"PATH": bindir + ":/opt/homebrew/bin:/usr/bin:/bin", "FX": fxd, "GC_SESSION_ORIGIN": "ephemeral", "HOME": tmp}
    if lib_mode == "real":
        env["GC_CITY_PATH"] = CITY
    elif lib_mode == "real-city-only":
        env["GC_CITY"] = CITY
    elif lib_mode == "none":
        pass
    else:  # a path
        env["WORK_ORDER_LIB"] = lib_mode
    env.update(env_extra)
    cmd = (CMD_OLD if which == "old" else CMD_NEW)[cmd_key]
    argv = [shell, "-c", cmd] + (list(argv_tail) if cmd_key in ("routed", "full") else [])
    r = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=120)
    calls = open(os.path.join(fxd, "calls.log")).read().splitlines() if os.path.exists(os.path.join(fxd, "calls.log")) else []
    shutil.rmtree(tmp)
    return r, calls


def ids(out):
    try:
        return [b["id"] for b in json.loads(out)]
    except Exception:
        return out.strip()[:80] or "<empty>"


FAILS = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (("  " + detail) if detail else ""))
    if not cond:
        FAILS.append(name)


def show(label, r):
    err = [l for l in r.stderr.splitlines() if l.strip()]
    print("     %-4s rc=%d head=%s stderr=%s" % (label, r.returncode, ids(r.stdout), (err[0][:110] + (" (+%d)" % (len(err) - 1) if len(err) > 1 else "")) if err else "-"))


# ---- fixtures -------------------------------------------------------------------------------------------------
BUG0 = bead("bug-p0-older", 0, "bug", "2026-10-01T10:00:00Z")
FEAT0 = bead("feature-p0-newer", 0, "feature", "2026-10-05T10:00:00Z")
many = [bead("bug-p2-%02d" % i, 2, "bug", "2026-09-%02dT10:00:00Z" % (i + 1)) for i in range(24)]
many.append(bead("feature-p0-25th", 0, "feature", "2026-10-06T10:00:00Z"))  # newest => the 25th in `--sort oldest`

print("== shell under test: %s ; lib: %s/packs/town-deltas/assets/scripts/work-order.sh" % (SH, CITY))

# 1. P0 feature newer vs P0 bug older
r_old, _ = run("routed", "old", {"routed": [BUG0, FEAT0]}, {}, "real")
r_new, calls = run("routed", "new", {"routed": [BUG0, FEAT0]}, {}, "real")
print("-- 1. routed tier: P0 feature (newer) vs P0 bug (older)")
show("old", r_old); show("new", r_new)
check("1 old head is the older bug (priority/type blind LRU)", ids(r_old.stdout) == ["bug-p0-older"])
check("1 new head is the P0 feature", ids(r_new.stdout) == ["feature-p0-newer"])
check("1 new fetched with --limit 0 and no --limit=N", any("gc.routed_to" in c and c.endswith("--limit 0") for c in calls) and not any("--limit=" in c and "--limit=0" not in c for c in calls), "calls: " + "; ".join(c[-40:] for c in calls))

# 2. 25 beads: the 25th (newest) is the only P0 feature
r_old, _ = run("routed", "old", {"routed": many}, {}, "real")
r_new, calls = run("routed", "new", {"routed": many}, {}, "real")
print("-- 2. routed tier: 25 beads, the 25th is the only P0 feature (a window of 20 cannot see it)")
show("old", r_old); show("new", r_new)
check("2 old (limit=20 window) cannot reach the 25th", ids(r_old.stdout) != ["feature-p0-25th"])
check("2 new reaches the 25th and puts it first", ids(r_new.stdout) == ["feature-p0-25th"])

# 3. reclaimed x2
A = bead("feature-p0-reclaimed-x2", 0, "feature", "2026-09-20T10:00:00Z", "2026-10-06T22:00:00Z", ["pilot:reclaim-count:2"])
B = bead("feature-p0-untouched", 0, "feature", "2026-10-02T10:00:00Z")
r_new, _ = run("routed", "new", {"routed": [A, B]}, {}, "real")
A1 = dict(A); A1["labels"] = []
r_ctl, _ = run("routed", "new", {"routed": [A1, B]}, {}, "real")
print("-- 3. routed tier: a P0 feature reclaimed twice (older, updated again) vs an untouched younger P0 feature")
show("new", r_new); show("ctl", r_ctl)
check("3 reclaimed x2 yields the head to the untouched one (anti-starvation kept)", ids(r_new.stdout) == ["feature-p0-untouched"])
check("3 control: same bead WITHOUT the reclaim label keeps its place by created_at", ids(r_ctl.stdout) == ["feature-p0-reclaimed-x2"])

# 4. lib absent -> old behaviour + WARN, never empty
FIX1 = {"routed": [BUG0, FEAT0]}
r_old, _ = run("routed", "old", FIX1, {}, "none")
r_abs, _ = run("routed", "new", FIX1, {}, "none")
r_abs2, _ = run("routed", "new", FIX1, {}, "/nonexistent/work-order.sh")
print("-- 4. lib absent (no GC_CITY_PATH/GC_CITY; and WORK_ORDER_LIB pointing nowhere)")
show("old", r_old); show("new", r_abs); show("new2", r_abs2)
check("4 absent lib: same head as the old command, rc 0", ids(r_abs.stdout) == ids(r_old.stdout) and r_abs.returncode == 0)
check("4 absent lib: one WARN on stderr", "work-order WARN" in r_abs.stderr and "work-order WARN" in r_abs2.stderr)
check("4 absent lib via WORK_ORDER_LIB: same head, rc 0", ids(r_abs2.stdout) == ids(r_old.stdout) and r_abs2.returncode == 0)

# 5. lib erroring / noisy / answering something the next stage cannot act on -> the previous order, WARN, never empty.
#    The first five are the "cannot tell" family; the rest are the ones a non-empty-stdout check let through (gate
#    fix 2/3): a banner at source time, non-JSON before exit 2, a valid-JSON banner, two documents, an empty or a
#    shorter array for a non-empty input, a right-looking array with exit 1.
tmp = tempfile.mkdtemp(prefix="wo-libs-")
REV = "work_order_sort() { jq -c 'reverse'; }\n"  # the head differs from the fallback's: a trusted answer is visible
libs = {
    "cannot-tell": 'work_order_sort() { cat >/dev/null; echo "work-order ERROR: stub: cannot tell" >&2; return 2; }\n',
    "syntax-error": "work_order_sort() { if then fi\n",
    "exit-at-source": "exit 3\n",
    "empty-lib": "",
    "no-function": "x=1\n",
    "banner-at-source": 'echo "== work-order.sh v2 (local edit) =="\n' + REV,
    "nonjson-exit2": 'work_order_sort() { cat >/dev/null; echo "cannot sort: no such field"; return 2; }\n',
    "json-banner-then-array": "work_order_sort() { echo 42; jq -c 'reverse'; }\n",
    "two-arrays": "work_order_sort() { jq -c 'reverse'; jq -c 'reverse' <<<'[]'; }\n",
    "empty-array": "work_order_sort() { cat >/dev/null; echo '[]'; }\n",
    "shorter-array": "work_order_sort() { jq -c 'reverse | .[0:1]'; }\n",
    "right-array-exit1": "work_order_sort() { jq -c 'reverse'; return 1; }\n",
}
for name, body in libs.items():
    open(os.path.join(tmp, name + ".sh"), "w").write(body)
open(os.path.join(tmp, "unreadable.sh"), "w").write("true\n"); os.chmod(os.path.join(tmp, "unreadable.sh"), 0)
open(os.path.join(tmp, "good-reverse.sh"), "w").write(REV)
open(os.path.join(tmp, "bash-env-banner.sh"), "w").write('echo "banner from BASH_ENV"\n')
print("-- 5. lib erroring / noisy / answering with something that is not one array as long as the input -> old order, WARN, never empty")
r_old, _ = run("routed", "old", FIX1, {}, "none")
r_good, _ = run("routed", "new", FIX1, {}, os.path.join(tmp, "good-reverse.sh"))
show("good-ctl", r_good)
check("5 control: a well-behaved stand-in lib IS trusted (its head is not the fallback's)", ids(r_good.stdout) != ids(r_old.stdout) and "work-order WARN" not in r_good.stderr and r_good.returncode == 0)
for name in list(libs) + ["unreadable"]:
    r, _ = run("routed", "new", FIX1, {}, os.path.join(tmp, name + ".sh"))
    show(name[:12], r)
    check("5 %s: old head, rc 0, WARN, not empty" % name, ids(r.stdout) == ids(r_old.stdout) and r.returncode == 0 and "work-order WARN" in r.stderr and r.stdout.strip() != "")
os.chmod(os.path.join(tmp, "unreadable.sh"), 0o644)
# a BASH_ENV that echoes a banner pollutes the child bash's stdout whatever the lib is, even the real one
r, _ = run("routed", "new", FIX1, {"BASH_ENV": os.path.join(tmp, "bash-env-banner.sh")}, "real")
show("BASH_ENV", r)
check("5 BASH_ENV banner + the REAL lib: old head, rc 0, WARN, not empty", ids(r.stdout) == ids(r_old.stdout) and r.returncode == 0 and "work-order WARN: wo_pick" in r.stderr and r.stdout.strip() != "")
r, _ = run("routed", "new", FIX1, {}, "real")
check("5 control: the same call without BASH_ENV is ordered by the lib (P0 feature first)", ids(r.stdout) == ["feature-p0-newer"] and "work-order WARN" not in r.stderr)
# the same through the assigned tiers (those have no LRU fallback: the previous order is bd's own)
r, _ = run("ready", "new", {"ready_assigned": [bead("rdy-p2-bug", 2, "bug", "2026-10-01T10:00:00Z"), bead("rdy-p0-feature", 0, "feature", "2026-10-03T10:00:00Z")]}, {"GC_SESSION_ID": "worker-bead"}, os.path.join(tmp, "banner-at-source.sh"))
show("assigned", r)
check("5 banner-at-source on the assigned-ready tier: bd's order (rdy-p2-bug), not empty", ids(r.stdout) == ["rdy-p2-bug"] and "work-order WARN" in r.stderr)

# 6. empty population: the idle poll never touches the lib
marker = os.path.join(tmp, "lib-was-called")
open(os.path.join(tmp, "spy.sh"), "w").write('work_order_sort() { echo called >> "%s"; cat; }\n' % marker)
r, _ = run("routed", "new", {"routed": []}, {}, os.path.join(tmp, "spy.sh"))
print("-- 6. idle poll (nothing routed): no lib call, still `[]`")
show("new", r)
check("6 `[]` out, lib not invoked", r.stdout.strip() == "[]" and not os.path.exists(marker))

# 7. upstream garbage: same as the old command (nothing, falls through to `[]`)
r_old, _ = run("routed", "old", {"routed": "!garbage"}, {}, "real")
r_new, _ = run("routed", "new", {"routed": "!garbage"}, {}, "real")
print("-- 7. bd prints garbage")
show("old", r_old); show("new", r_new)
check("7 garbage in: same answer as before", r_old.stdout == r_new.stdout and r_new.returncode == r_old.returncode)

# 8. tiers 2 and 3
MIG = [dict(bead("mig-p1-bug-older", 1, "bug", "2026-10-01T10:00:00Z"), metadata={"gc.run_target": "gastown.dog", "gc.kind": "workflow"}),
       dict(bead("mig-p0-feature-newer", 0, "feature", "2026-10-04T10:00:00Z"), metadata={"gc.run_target": "gastown.dog", "gc.kind": "workflow"})]
r_old, _ = run("routed", "old", {"migration": MIG}, {}, "real")
r_new, calls = run("routed", "new", {"migration": MIG}, {}, "real")
print("-- 8a. tier 2 (gc.run_target migration): P1 bug older vs P0 feature newer")
show("old", r_old); show("new", r_new)
check("8a old head = P1 bug, new head = P0 feature", ids(r_old.stdout) == ["mig-p1-bug-older"] and ids(r_new.stdout) == ["mig-p0-feature-newer"])
EPH = [bead("eph-p2-bug-older", 2, "bug", "2026-10-01T10:00:00Z"), bead("eph-p0-feature-newer", 0, "feature", "2026-10-04T10:00:00Z")]
r_old, _ = run("routed", "old", {"eph_open": EPH}, {}, "real")
r_new, _ = run("routed", "new", {"eph_open": EPH}, {}, "real")
print("-- 8b. tier 3 (ephemeral wisps): P2 bug older vs P0 feature newer")
show("old", r_old); show("new", r_new)
check("8b old head = P2 bug, new head = P0 feature", ids(r_old.stdout) == ["eph-p2-bug-older"] and ids(r_new.stdout) == ["eph-p0-feature-newer"])
EPH25 = [bead("eph-p2-%02d" % i, 2, "bug", "2026-09-%02dT10:00:00Z" % (i + 1)) for i in range(24)] + [bead("eph-p0-25th", 0, "feature", "2026-10-06T10:00:00Z")]
r_old, _ = run("routed", "old", {"eph_open": EPH25}, {}, "real")
r_new, _ = run("routed", "new", {"eph_open": EPH25}, {}, "real")
print("-- 8c. tier 3: 25 wisps, the 25th is the only P0 feature (old sliced .[:20] before ordering)")
show("old", r_old); show("new", r_new)
check("8c new reaches the 25th", ids(r_new.stdout) == ["eph-p0-25th"] and ids(r_old.stdout) != ["eph-p0-25th"])

# 9. assigned work (the session's own beads)
IP = [bead("own-p1-feature", 1, "feature", "2026-10-01T10:00:00Z", status="in_progress"), bead("own-p0-bug", 0, "bug", "2026-10-03T10:00:00Z", status="in_progress")]
env = {"GC_SESSION_ID": "worker-bead"}
r_old, _ = run("inprogress", "old", {"inprogress": IP}, env, "real")
r_new, calls = run("inprogress", "new", {"inprogress": IP}, env, "real")
print("-- 9a. assigned in-progress: P1 feature first in bd's order, P0 bug behind it")
show("old", r_old); show("new", r_new)
check("9a old head = bd order (P1), new head = P0 bug", ids(r_old.stdout) == ["own-p1-feature"] and ids(r_new.stdout) == ["own-p0-bug"])
check("9a new asked bd for the whole population", any(c.startswith("list --status in_progress") and c.endswith("--limit 0") for c in calls), "; ".join(calls[:1])[-60:])
RD = [bead("rdy-p2-bug", 2, "bug", "2026-10-01T10:00:00Z"), bead("rdy-p0-feature", 0, "feature", "2026-10-03T10:00:00Z")]
r_old, _ = run("ready", "old", {"ready_assigned": RD}, env, "real")
r_new, calls = run("ready", "new", {"ready_assigned": RD}, env, "real")
print("-- 9b. assigned ready")
show("old", r_old); show("new", r_new)
check("9b old head = P2, new head = P0 feature", ids(r_old.stdout) == ["rdy-p2-bug"] and ids(r_new.stdout) == ["rdy-p0-feature"])
RD25 = [bead("own-p2-%02d" % i, 2, "bug", "2026-09-%02dT10:00:00Z" % (i + 1)) for i in range(24)] + [bead("own-p0-25th", 0, "feature", "2026-10-06T10:00:00Z")]
r_old, _ = run("ready", "old", {"ready_assigned": RD25}, env, "real")
r_new, _ = run("ready", "new", {"ready_assigned": RD25}, env, "real")
print("-- 9c. assigned ready, 25 beads (old window of 20)")
show("old", r_old); show("new", r_new)
check("9c new reaches the 25th", ids(r_new.stdout) == ["own-p0-25th"] and ids(r_old.stdout) != ["own-p0-25th"])

# 10. the whole default work_query: tier order is preserved (assigned beats routed), lib via GC_CITY only
r, _ = run("full", "new", {"routed": [BUG0, FEAT0], "ready_assigned": RD}, env, "real")
print("-- 10. full default work_query: assigned work still beats the pool, and the pool is ordered")
show("new", r)
check("10a assigned-ready beats routed, ordered by the rule", ids(r.stdout) == ["rdy-p0-feature"])
r, _ = run("full", "new", {"routed": [BUG0, FEAT0]}, {}, "real-city-only")
show("new", r)
check("10b nothing assigned: routed head is the P0 feature (lib found through GC_CITY)", ids(r.stdout) == ["feature-p0-newer"])
r, _ = run("full", "new", {"routed": [BUG0, FEAT0]}, {"GC_SESSION_ORIGIN": "named"}, "real")
check("10c origin gate untouched: a non-ephemeral origin still prints `[]`/exits 0 without probing the pool", r.returncode == 0 and r.stdout.strip() in ("", "[]"), "stdout=%r" % r.stdout[:30])

# 11. vetoes still run BEFORE the order: a P0 feature carrying pool:refused must lose to a P1 bug
REF = [dict(bead("p0-feature-refused", 0, "feature", "2026-10-05T10:00:00Z"), labels=["pool:refused:engine-rebuild-required"]), bead("p1-bug-clean", 1, "bug", "2026-10-01T10:00:00Z")]
r, _ = run("routed", "new", {"routed": REF}, {}, "real")
print("-- 11. vetoes unchanged: P0 feature refused (pool:refused:*) vs clean P1 bug")
show("new", r)
check("11 refused bead never offered; the clean one is", ids(r.stdout) == ["p1-bug-clean"])


# 12. state 2 of the lib: a bead with an unreadable field stays (end of class); the lib's WARN reaches stderr, stdout stays clean JSON
NOPRIO = dict(bead("no-prio", 0, "feature", "2026-10-01T10:00:00Z")); del NOPRIO["priority"]
r, _ = run("routed", "new", {"routed": [NOPRIO, BUG0, FEAT0]}, {}, "real")
print("-- 12. one bead has no priority: kept at the end, lib WARN on stderr, stdout is still one clean JSON array")
show("new", r)
check("12 head is the P0 feature, not the unreadable bead", ids(r.stdout) == ["feature-p0-newer"])
check("12 the lib's own WARN line reached stderr (not swallowed)", "work-order WARN: no-prio" in r.stderr, r.stderr.strip()[:90])
check("12 stdout is exactly one JSON array", r.stdout.strip().startswith("[") and r.stdout.count("\n") == 0)
r2, _ = run("routed", "new", {"routed": [NOPRIO]}, {}, "real")
check("12b a lone unreadable bead is still served (never dropped, never empty)", ids(r2.stdout) == ["no-prio"])

# 13. cost (indicative only: the machine is loaded)
import time
def timeit(which):
    t = time.time()
    for _ in range(10):
        run("routed", which, {"routed": many}, {}, "real")
    return (time.time() - t) * 100  # ms per run
if not os.environ.get("MUTATE"):
    print("-- 13. wall time per routed-tier run on 25 beads (10 runs each, loaded machine, includes harness setup): old %.0f ms, new %.0f ms" % (timeit("old"), timeit("new")))

shutil.rmtree(tmp)
print()
print("RESULT under %s: %s" % (SH, "ALL PASS" if not FAILS else "FAILED: " + ", ".join(FAILS)))
sys.exit(1 if FAILS else 0)
