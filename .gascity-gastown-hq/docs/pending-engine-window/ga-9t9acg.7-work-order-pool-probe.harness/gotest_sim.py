#!/usr/bin/env python3
"""ga-9t9acg.7: run work_order_pick_test.go's SHELL logic without compiling Go.

The fake bd, the stand-in lib and the bead JSON format string are extracted from the Go test file itself (never
retyped); the commands are the old baseline (live gc 0919) and the patched one (gen.py mirror of the Go diff). The
site/scenario tables are mirrored by hand below, with the expectations of the Go test. Output: old vs new heads.

usage: gotest_sim.py PROMPT_TXT CONFIG_GO TEST_GO SHELL
"""
import ast, json, os, re, shutil, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(__file__))
import gen

PROMPT, GO, TESTGO, SH = sys.argv[1:5]
base, WO_DEF, TAIL, LRU, _ = gen.load(PROMPT, GO)
SCRIPTS = {k: gen.patch_script(k, v[2], TAIL, LRU) for k, v in base.items()}
OLD = {k: v[2] for k, v in base.items()}
T = open(TESTGO).read()


def go_raw(name):
    m = re.search(r"const " + name + r" = `([^`]*)`", T)
    assert m, name
    return m.group(1)


def go_str(name):
    m = re.search(r"\b" + name + r"\s*= (\"(?:[^\"\\]|\\.)*\")", T)
    assert m, name
    return ast.literal_eval(m.group(1))


STUB, FAKE_BD = go_raw("woStubLib"), go_raw("woFakeBd")
ERRING, BROKEN, EXITING = go_str("woErroringLib"), go_str("woSyntaxBrokenLib"), go_str("woExitingLib")
BEAD_FMT = re.search(r"fmt\.Sprintf\(`(\{\"id\".*?)`,\n", T).group(1)


def bead(id_, prio, typ, created, updated, labels, assignee, meta):
    # render the Go format string: %q -> JSON string, %d, %s in argument order
    args = [id_, prio, typ, created, updated, labels, assignee, meta]
    out, i = "", 0
    for tok in re.split(r"(%q|%d|%s)", BEAD_FMT):
        if tok == "%q":
            out += json.dumps(args[i]); i += 1
        elif tok in ("%d", "%s"):
            out += str(args[i]); i += 1
        else:
            out += tok
    assert i == len(args), (i, len(args))
    json.loads(out)  # the format string must yield valid JSON
    return out


def strip_end(s):
    assert s.endswith('printf "[]"')
    return s[: -len('printf "[]"')]


FULL_OLD = strip_end(OLD["inprogress"]) + strip_end(OLD["ready"]) + OLD["routed"]
FULL_NEW = WO_DEF + strip_end(SCRIPTS["inprogress"]) + strip_end(SCRIPTS["ready"]) + SCRIPTS["routed"]
CMDS = {
    "old": {"inprogress": OLD["inprogress"], "ready": OLD["ready"], "routed": OLD["routed"], "full": FULL_OLD},
    "new": {"inprogress": WO_DEF + SCRIPTS["inprogress"], "ready": WO_DEF + SCRIPTS["ready"],
            "routed": WO_DEF + SCRIPTS["routed"], "full": FULL_NEW},
}
TARGET = "hello-world/worker"
ROUTED = '{"gc.routed_to":"%s"}' % TARGET
MIGR = '{"gc.kind":"workflow","gc.run_target":"%s","gc.routed_to":""}' % TARGET
W1 = {"GC_SESSION_ORIGIN": "ephemeral", "GC_SESSION_ID": "worker-bead"}
# (name, command key, fixture, assignee, meta)
SITES = [
    ("pool tier 1 (work query)", "full", "routed", "", ROUTED),
    ("pool tier 1 (routed pool query)", "routed", "routed", "", ROUTED),
    ("pool tier 2 (run_target migration)", "full", "migration", "", MIGR),
    ("pool tier 3 (ephemeral wisps)", "full", "eph_unassigned", "", ROUTED),
    ("assigned in-progress", "inprogress", "inprogress", "worker-bead", "{}"),
    ("assigned ready", "ready", "ready", "worker-bead", "{}"),
    ("work query -> assigned in-progress", "full", "inprogress", "worker-bead", "{}"),
    ("work query -> assigned ready", "full", "ready", "worker-bead", "{}"),
    ("ephemeral assigned in-progress", "inprogress", "eph_inprogress", "worker-bead", "{}"),
    ("ephemeral assigned ready", "ready", "eph_open", "worker-bead", "{}"),
]
SITE = {s[0]: s for s in SITES}


def mk(site, id_, prio, typ, created, updated=None, labels=""):
    return bead(id_, prio, typ, created, updated or created, labels, site[3], site[4])


def sc_pair(s):
    return [mk(s, "p0-bug-older", 0, "bug", "2026-09-01T12:00:00Z"), mk(s, "p0-feature-newer", 0, "feature", "2026-09-30T12:00:00Z")]


def sc_25(s):
    b = [mk(s, "p2-bug-%02d" % i, 2, "bug", "2026-09-%02dT10:00:00Z" % (i + 1)) for i in range(24)]
    return b + [mk(s, "p0-feature-newest-of-25", 0, "feature", "2026-09-30T10:00:00Z")]


def sc_reclaimed(s):
    return [mk(s, "p1-bug-reclaimed", 1, "bug", "2026-09-01T12:00:00Z", "2026-10-05T12:00:00Z", '"pilot:reclaim-count:2"'),
            mk(s, "p1-bug-untouched", 1, "bug", "2026-09-20T12:00:00Z")]


def sc_touched(s):
    return [mk(s, "p1-bug-commented", 1, "bug", "2026-09-01T12:00:00Z", "2026-10-05T12:00:00Z"),
            mk(s, "p1-bug-newer", 1, "bug", "2026-09-20T12:00:00Z")]


def sc_veto(s):
    return [mk(s, "plain-p2-bug", 2, "bug", "2026-09-01T12:00:00Z"),
            mk(s, "refused-p0-feature", 0, "feature", "2026-09-30T12:00:00Z", labels='"pool:refused:engine-rebuild-required"')]


SCEN = [("P0 feature newer than P0 bug", sc_pair, "p0-feature-newer"),
        ("25 beads, P0 feature last by age", sc_25, "p0-feature-newest-of-25"),
        ("reclaimed twice goes behind its untouched peer", sc_reclaimed, "p1-bug-untouched"),
        ("touched but never reclaimed keeps its place", sc_touched, "p1-bug-commented"),
        ("refused P0 feature stays vetoed", sc_veto, "plain-p2-bug")]


def run(which, site, beads, lib, mutate=None, env_extra=None):
    """lib: path | None (no WORK_ORDER_LIB) -- same hermetic env as the Go helper."""
    tmp = tempfile.mkdtemp(prefix="wo-sim-")
    try:
        bindir, fxd = os.path.join(tmp, "bin"), os.path.join(tmp, "fx")
        os.makedirs(bindir); os.makedirs(fxd)
        open(os.path.join(bindir, "bd"), "w").write(FAKE_BD)
        os.chmod(os.path.join(bindir, "bd"), 0o755)
        os.symlink("/bin/bash", os.path.join(bindir, "bash"))
        open(os.path.join(fxd, site[2] + ".json"), "w").write("[" + ",".join(beads) + "]")
        env = {"PATH": bindir + ":/opt/homebrew/bin:/usr/bin:/bin", "FX_DIR": fxd}
        env.update(W1)
        if lib:
            env["WORK_ORDER_LIB"] = lib
        env.update(env_extra or {})
        cmd = CMDS[which][site[1]]
        if mutate:
            cmd = mutate(cmd)
        argv = [SH, "-c", cmd] + (["--", TARGET] if site[1] in ("routed", "full") else [])
        r = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=120)
        calls = open(os.path.join(fxd, "calls.log")).read() if os.path.exists(os.path.join(fxd, "calls.log")) else ""
        try:
            ids = [b["id"] for b in json.loads(r.stdout)]
        except Exception:
            ids = None
        return ids, r.stdout, r.stderr, calls, cmd
    finally:
        shutil.rmtree(tmp)


def lib_file(tmp, body):
    p = os.path.join(tmp, "work-order.sh")
    open(p, "w").write(body)
    return p


FAIL = {"old": 0, "new": 0}
TOTAL = {"old": 0, "new": 0}
LOG = []


def check(which, name, ok, detail=""):
    TOTAL[which] += 1
    if not ok:
        FAIL[which] += 1
    LOG.append((which, ok, name, detail))


work = tempfile.mkdtemp(prefix="wo-sim-libs-")
stub = os.environ.get("GC_WORK_ORDER_LIB_REAL") or lib_file(work, STUB)  # real lib: same scenarios, same expectations
missing = os.path.join(work, "no-such-dir", "work-order.sh")
erring = {}
for nm, body in (("exit 2", ERRING), ("syntax error", BROKEN), ("exit on source", EXITING)):
    d = os.path.join(work, nm.replace(" ", "_")); os.makedirs(d)
    erring[nm] = lib_file(d, body)

for which in ("old", "new"):
    # 1. ordering at every site
    for site in SITES:
        for sname, fn, want in SCEN:
            ids, out, err, _, _ = run(which, site, fn(site), stub)
            check(which, "order/%s/%s" % (site[0], sname), ids == [want], "head=%s" % ids)
    # 2. whole population
    window = re.compile(r"--limit[= ][1-9]")
    for site in SITES:
        _, _, _, calls, _ = run(which, site, sc_25(site), stub)
        bad = [l for l in calls.splitlines() if l and not l.startswith("list --parent") and window.search(l)]
        ok = ("--limit 0" in calls or "--limit=0" in calls) and not bad
        check(which, "whole-population/%s" % site[0], ok, "windowed calls=%s" % bad[:2])
    # 3. lib absent -> previous order + WARN
    for site in SITES:
        ids, out, err, _, _ = run(which, site, sc_pair(site), missing)
        check(which, "absent/%s" % site[0],
              ids == ["p0-bug-older"] and "work-order WARN: wo_pick: work-order.sh not readable" in err,
              "head=%s warn=%s" % (ids, "WARN" in err))
    # 4. lib erroring
    for nm, path in erring.items():
        for site in SITES:
            ids, out, err, _, _ = run(which, site, sc_pair(site), path)
            check(which, "erroring[%s]/%s" % (nm, site[0]),
                  ids == ["p0-bug-older"] and "work-order WARN: wo_pick: work_order_sort could not tell" in err,
                  "head=%s warn=%s" % (ids, "could not tell" in err))
    # 5. lookup order (tier 1 site)
    s0 = SITES[0]
    city = os.path.join(work, "city", "packs", "town-deltas", "assets", "scripts"); os.makedirs(city, exist_ok=True)
    lib_file(city, STUB)
    cityroot = os.path.join(work, "city")
    for nm, extra, want, warn in (
        ("GC_CITY_PATH", {"GC_CITY_PATH": cityroot}, ["p0-feature-newer"], None),
        ("GC_CITY", {"GC_CITY": cityroot}, ["p0-feature-newer"], None),
        ("WORK_ORDER_LIB wins, no cascade", {"GC_CITY_PATH": cityroot}, ["p0-bug-older"], "could not tell"),
        ("nothing set", {}, ["p0-bug-older"], "work-order.sh not readable"),
    ):
        lib = erring["exit 2"] if nm.startswith("WORK_ORDER_LIB wins") else None
        ids, out, err, _, _ = run(which, s0, sc_pair(s0), lib, env_extra=extra)
        check(which, "lookup/" + nm, ids == want and (warn is None or warn in err), "head=%s err=%s" % (ids, err[:60]))
    # 6. mutation control (NEW only is meaningful; old has no wo_pick so mutants "change nothing")
    if which == "new":
        everywhere = ["pool tier 1 (work query)", "assigned in-progress", "ephemeral assigned ready"]
        windowed = ["pool tier 1 (work query)", "assigned in-progress"]
        MUT = [
            ("window of 20 before ordering", windowed, lambda c: c.replace("--limit 0", "--limit=20"), 1, "p0-feature-newest-of-25", stub),
            ("no ordering", everywhere, lambda c: c.replace("work_order_sort --age reclaim", "cat"), 0, "p0-feature-newer", stub),
            ("age = created_at only", everywhere, lambda c: c.replace("--age reclaim", "--age created"), 2, "p1-bug-untouched", stub),
            ("age = updated_at only", everywhere, lambda c: c.replace("--age reclaim", "--age field"), 3, "p1-bug-commented", stub),
            ("WARN swallowed", everywhere, lambda c: c.replace(">&2", ">/dev/null"), None, None, missing),
        ]
        for mname, sites, fn, scen, want, lib in MUT:
            for sn in sites:
                site = SITE[sn]
                beads = SCEN[scen][1](site) if scen is not None else sc_pair(site)

                def holds(mutate):
                    ids, out, err, _, cmd = run("new", site, beads, lib, mutate=mutate)
                    return (ids == [want]) if scen is not None else ("work-order WARN" in err), cmd
                ctl, c0 = holds(None)
                mut, c1 = holds(fn)
                check(which, "mutant/%s/%s" % (mname, sn), ctl and c1 != c0 and not mut,
                      "control=%s changed=%s mutantStillHolds=%s" % (ctl, c1 != c0, mut))

for which in ("old", "new"):
    print("=== %s: %d/%d checks pass" % (which.upper(), TOTAL[which] - FAIL[which], TOTAL[which]))
    if "-v" in sys.argv:
        for w, ok, name, detail in LOG:
            if w == which:
                print(("PASS " if ok else "FAIL ") + name + "  " + detail)
    else:
        for w, ok, name, detail in LOG:
            if w == which and not ok:
                print("FAIL " + name + "  " + detail)
shutil.rmtree(work)
sys.exit(1 if FAIL["new"] else 0)
