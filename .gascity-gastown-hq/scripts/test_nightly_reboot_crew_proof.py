#!/usr/bin/env python3
"""test_nightly_reboot_crew_proof.py (ga-esorlre.15): hermetic suite for scripts/nightly-reboot-crew-proof.py (layer 3 of ga-esorlre.12: at 00:10 every named crew that had a bead in_progress at the boot must show a
commit or a comment of its own, else a push). FakeIO answers sysctl/bd/git/notify from tables over a REAL temp tree (a call nobody planned fails the test); `Real` uses real git and real processes.
`python3 -I scripts/test_nightly_reboot_crew_proof.py` (3.9+); NRCP_UNDER_TEST=<copy> runs it against a mutant."""
import calendar, contextlib, importlib.util, io as _io, json, os, re, shutil, subprocess, sys, tempfile, time, unittest  # noqa: E401

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SUT = os.environ.get("NRCP_UNDER_TEST") or os.path.join(HERE, "nightly-reboot-crew-proof.py")
_spec = importlib.util.spec_from_file_location("nrcp", SUT)
P = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(P)
_TZ0 = os.environ.get("TZ")


def setUpModule():
    os.environ["TZ"] = "UTC"
    time.tzset()


def tearDownModule():
    os.environ.pop("TZ", None) if _TZ0 is None else os.environ.update(TZ=_TZ0)
    time.tzset()


def ts(s): return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
def iso(t): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
def hm(t): return time.strftime("%H:%M", time.gmtime(t))
def comment(author, t): return {"id": "c%d" % t, "author": author, "created_at": iso(t), "text": "x"}


BOOT, DEADLINE, NOW, WA = ts("2026-11-25T23:42:00Z"), ts("2026-11-26T00:10:00Z"), ts("2026-11-26T00:10:40Z"), "whatsapp_automation"


def bead(bid, who, started=BOOT - 3600, status="in_progress"):
    return dict({"id": bid, "assignee": who, "status": status}, **({"started_at": iso(started)} if started is not None else {}))


def git(cwd, *args, when=None):
    env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null", GIT_AUTHOR_NAME="X", GIT_AUTHOR_EMAIL="x@x", GIT_COMMITTER_NAME="X", GIT_COMMITTER_EMAIL="x@x")
    env.update(GIT_COMMITTER_DATE=iso(when), GIT_AUTHOR_DATE=iso(when)) if when is not None else None
    subprocess.run(["git", "-C", cwd] + list(args), check=True, capture_output=True, env=env)


class World:
    """agents/<name>/agent.toml, city.toml with [[rigs]] (marketing suspended; every rig also has a nested table with `suspended = true`, which is not the rig's) and .gc/logs"""

    def __init__(self, tmp):
        self.root, self.wd = os.path.join(tmp, "gt"), {}
        self.city = os.path.join(self.root, ".gascity-gastown-hq")
        os.makedirs(os.path.join(self.city, "agents"))
        os.makedirs(os.path.join(self.city, ".gc", "logs"))
        rigs = "".join('[[rigs]]\nname = "%s"\n%s[rigs.imports.gastown]\nsuspended = true\n\n' % (n, "suspended = true  # on purpose\n" if s else "") for n, s in ((WA, 0), ("property_scrapers", 0), ("marketing", 1)))
        with open(os.path.join(self.city, "city.toml"), "w") as fh:
            fh.write(rigs + '[[patches.agent]]\nname = "gastown.boot"\nsuspended = true\n')

    def rig(self, n): return os.path.join(self.root, n)

    def crew(self, name, rig=WA, slug=None, extra="", max_active=1, quoted='"%s"'):
        wd = self.wd[name] = os.path.join(self.rig(rig), "crew", slug or name.split("-")[0])
        os.makedirs(os.path.join(self.city, "agents", name), exist_ok=True)
        with open(os.path.join(self.city, "agents", name, "agent.toml"), "w") as fh:
            fh.write("max_active_sessions = %d\nwork_dir = %s\n%s" % (max_active, quoted % wd, extra))
        return wd

    def env(self, **kw): return dict({"NRCP_CITY": self.city, "NRCP_RETRY_S": "7", "NRCP_TRIES": "3"}, **kw)

    def log(self):
        p = os.path.join(self.city, ".gc", "logs", "nightly-reboot.log")
        if not os.path.exists(p):
            return ""
        with open(p, encoding="utf-8") as fh:
            return fh.read()


class FakeIO:
    """sysctl/bd/git/notify answered from tables ("FAIL" = rc 1, "TIMEOUT" = no rc, a str = raw stdout, else JSON); a call nobody planned for fails the test"""

    def __init__(self):
        self.t, self.boot, self.sysctl, self.real_git, self.notify_rc = float(NOW), BOOT, None, False, [0]
        self.calls, self.sleeps, self.notifies, self.t_at, self.lists, self.comments, self.reflogs, self.flaky = [], [], [], [], {}, {}, {}, {}

    def now(self): return self.t

    def sleep(self, s):
        self.sleeps.append(s)
        self.t += s

    def n(self, tool, verb=None): return sum(1 for c in self.calls if os.path.basename(c[0]) == tool and (verb is None or verb in c))

    def flake(self, key):
        self.flaky[key] = self.flaky.get(key, 0) - 1
        return self.flaky[key] >= 0

    @staticmethod
    def table(v): return (1, "", "boom") if v == "FAIL" else (None, "", "") if v == "TIMEOUT" else (0, v if isinstance(v, str) else json.dumps(v), "")

    def run(self, argv, timeout, env=None):
        self.calls.append(list(argv))
        self.t += 0.1
        tool = os.path.basename(argv[0])
        self.t_at += [self.t] if tool in ("bd", "git") else []
        if tool == "sysctl":
            return (self.sysctl[0], self.sysctl[1], "") if self.sysctl else (0, "{ sec = %d, usec = 958892 } Wed" % self.boot, "")
        if tool == "bd":
            store, verb = argv[argv.index("-C") + 1], "comments" if "comments" in argv else "list"
            if verb == "list":
                assert "in_progress" in argv and argv[argv.index("--limit") + 1] == "0" and store in self.lists, "bd list on %s: %s" % (store, argv)
                return (None, "", "") if self.flake(("bd-list", store)) else self.table(self.lists[store])
            key = (store, argv[argv.index("comments") + 1])
            assert key in self.comments and "--json" in argv, "unplanned bd comments %s" % (key,)
            return (1, "", "boom") if self.flake(("bd-comments",) + key) else self.table(self.comments[key])
        if tool == "git":
            wd = argv[argv.index("-C") + 1]
            if self.real_git:
                p = subprocess.run(argv, capture_output=True, text=True, env=dict(os.environ, **(env or {})))
                return p.returncode, p.stdout, p.stderr
            assert "reflog" in argv and "--all" in argv and "--date=unix" in argv and (env or {}).get("GIT_OPTIONAL_LOCKS") == "0" and wd in self.reflogs, "git on %s: %s" % (wd, argv)
            v = self.reflogs[wd]
            return (128, "", "fatal") if self.flake(("git", wd)) else self.table(v if isinstance(v, str) else "".join("%s@{%d}\t%s\n" % x for x in v))
        assert tool == "notify", "unplanned call: %r" % (argv,)
        self.notifies.append({"argv": list(argv), "env": dict(env or {})})
        return (self.notify_rc.pop(0) if len(self.notify_rc) > 1 else self.notify_rc[0]), "", ""


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="nrcp-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.w, self.io = World(self.tmp), FakeIO()
        self.wa = self.w.rig(WA)

    def go(self, *args):
        out, err = _io.StringIO(), _io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = P.main(list(args), self.w.env(), self.io)
        self.out, self.err = out.getvalue(), err.getvalue()
        return rc

    def two(self):
        """peter-wa and oracle-wa, one bead in progress each since before the boot, no evidence yet"""
        self.p, self.o = self.w.crew("peter-wa"), self.w.crew("oracle-wa")
        self.io.lists.update({self.wa: [bead("wa-aaa", "peter-wa"), bead("wa-bbb", "oracle-wa-gawispgux5v0")], self.w.city: []})
        self.io.reflogs.update({self.p: [], self.o: []})
        self.io.comments.update({(self.wa, "wa-aaa"): [], (self.wa, "wa-bbb"): []})

    def fresh(self, proven=""):
        self.setUp()
        self.two()
        for who in proven:
            self.proven(who)

    def proven(self, who="o"): self.io.reflogs[getattr(self, who)] = [("HEAD", BOOT + 60, "commit: ok")]

    def pushes(self, prio): return [x for x in self.io.notifies if x["argv"][x["argv"].index("-p") + 1] == prio]

    def alert(self):
        self.assertEqual(len(self.pushes("4")), 1, self.io.notifies)
        return " ".join(self.pushes("4")[0]["argv"])


class Proof(Base):
    """what proves peter-wa (oracle-wa is proven by a commit)"""

    def rc(self, reflog=(), comments=(), now=NOW):
        self.io.notifies.clear()
        self.two()
        self.proven()
        self.io.t = now
        self.io.reflogs[self.p], self.io.comments[(self.wa, "wa-aaa")] = list(reflog), list(comments)
        return self.go()

    def test_only_a_commit_of_its_own_inside_the_window_proves_it(self):
        c = lambda t, s="commit: x": [("HEAD", t, s)]
        rows = [("commit", c(BOOT + 60), 0), ("amend", c(BOOT + 60, "commit (amend): x"), 0), ("merge", c(BOOT + 60, "commit (merge): x"), 0), ("at the boot second", c(BOOT), 0), ("at the deadline second", c(DEADLINE), 0),
                ("before the boot", c(BOOT - 1), 1), ("after the deadline", c(DEADLINE + 1), 1), ("from the future", c(NOW + 3600), 1)]
        rows += [(s, c(BOOT + 9, s), 1) for s in ("pull: Fast-forward", "initial pull", "fetch origin: ff", "checkout: moving from a to b", "rebase (finish): x", "reset: moving to HEAD~1", "recommit: x")]
        for what, reflog, rc in rows:
            with self.subTest(what):
                self.assertEqual(self.rc(reflog), rc)
        self.io.calls.clear()
        self.assertEqual((self.rc([("main", BOOT + 60, "commit: x")]), self.io.n("bd", "comments")), (0, 0), "a commit that proves makes the comment reads unnecessary")

    def test_only_a_comment_authored_by_the_crew_proves_it_and_the_window_is_inclusive(self):
        for author, rc in (("peter-wa", 0), ("peter-wa-gawisp123abc", 0), ("peter-wax", 1), ("peter-w", 1), ("peter-ma", 1), ("xpeter-wa", 1), ("Peter-wa", 1), ("automation", 1), ("order:next-action-coordinator-alert", 1), ("Test", 1), ("gastown.mayor", 1)):
            with self.subTest(author):
                self.assertEqual(self.rc(comments=[comment(author, BOOT + 300)]), rc)
        for t, rc in ((BOOT, 0), (DEADLINE, 0), (BOOT - 1, 1), (DEADLINE + 1, 1)):
            with self.subTest(hm(t)):
                self.assertEqual(self.rc(comments=[comment("peter-wa", t)]), rc)

    def test_a_good_night_sends_only_the_routine_digest_and_names_who_was_not_covered(self):
        self.two()
        self.w.crew("digo-wa")
        self.proven("p")
        self.io.comments[(self.wa, "wa-bbb")] = [comment("oracle-wa-gawispgux5v0", BOOT + 21 * 60)]
        self.assertEqual(self.go(), 0)
        d = self.pushes("3")
        self.assertEqual((len(d), self.pushes("4"), d[0]["env"]), (1, [], {}), "the routine line is plain notify: no force, no strict exit")
        t = " ".join(d[0]["argv"])
        for s in ("retomaram", "peter-wa (commit", "oracle-wa (comentário", "Sem bead em andamento no boot (não cobradas): digo-wa."):
            self.assertIn(s, t)
        self.assertNotIn(self.w.wd["digo-wa"], " ".join(" ".join(c) for c in self.io.calls), "no bead, no reads")
        self.io.lists[self.wa] = []  # nothing in progress anywhere: said, not silent
        self.io.notifies.clear()
        self.assertEqual(self.go(), 0)
        self.assertIn("nenhuma crew tinha bead", " ".join(self.pushes("3")[0]["argv"]))
        self.assertIn("crew-proof:", self.w.log())

class Asked(Base):
    def test_who_is_and_is_not_asked_for_proof(self):
        row = lambda who="xcrew-wa", **kw: bead("wa-xxx", who, **kw)
        for what, kw, rows, asked in (
                ("an active crew with a bead", {}, [row()], True), ("its session name as the assignee", {}, [row("xcrew-wa-gawisp1")], True), ("a lookalike assignee", {}, [row("xcrew-wax"), row("xcrew-ma")], False),
                ("suspended in agent.toml", {"extra": "suspended = true  # Athos\n"}, [row()], False), ("a commented-out suspended line", {"extra": "# suspended = true\n  # suspended = true\nsuspended = false\n"}, [row()], True),
                ("a worker", {"slug": "worker"}, [row()], False), ("a pool", {"max_active": 3}, [row()], False), ("work_dir in single quotes", {"quoted": "'%s'"}, [row()], True),
                ("work_dir with a trailing slash", {"quoted": '"%s/"'}, [row()], True), ("a rig city.toml does not list", {"rig": "newrig"}, [row()], True), ("a suspended rig", {"rig": "marketing"}, [row()], False),
                ("a rig with a nested suspended key", {"rig": "property_scrapers"}, [row()], True), ("no bead", {}, [], False), ("a bead not in progress", {}, [row(status="closed")], False),
                ("a bead started at the boot second", {}, [row(started=BOOT)], False), ("a bead started a second before", {}, [row(started=BOOT - 1)], True),
                ("a bead whose start cannot be read", {}, [dict(row(), started_at="last tuesday")], True), ("a bead with no start", {}, [row(started=None)], True)):
            with self.subTest(what):
                self.fresh("po")
                rig, wd = kw.get("rig", WA), self.w.crew("xcrew-wa", **kw)
                if rig != "marketing":  # a suspended rig's store is never read: planting it would hide a read
                    self.io.lists[self.w.rig(rig)] = self.io.lists.get(self.w.rig(rig), []) + rows
                self.io.reflogs[wd], self.io.comments[(self.w.rig(rig), "wa-xxx")] = [], []
                self.assertEqual(self.go(), 1 if asked else 0)
                self.assertTrue(not asked or "xcrew-wa" in self.alert())

class NotSei(Base):
    """a read that fails is NAO-SEI: it alerts, and it is never 'none' (FALTA) and never 'ok'"""

    def test_every_read_that_fails_is_not_sei(self):
        lists = lambda v: lambda s: s.io.lists.__setitem__(s.wa, v)
        comments = lambda v: lambda s: s.io.comments.__setitem__((s.wa, "wa-aaa"), v)
        reflog = lambda v: lambda s: s.io.reflogs.__setitem__(s.p, v)
        extra = lambda row: lambda s: s.io.lists[s.wa].append(row)
        plants = [("comments rc", comments("FAIL")), ("comments timeout", comments("TIMEOUT")), ("comments html", comments("<html>")), ("comments object", comments('{"c": []}')), ("comments null", comments("null")),
                  ("comment without author", comments([{"created_at": iso(BOOT + 60)}])), ("author null", comments([{"author": None, "created_at": iso(BOOT + 60)}])), ("author empty", comments([{"author": "", "created_at": iso(BOOT + 60)}])),
                  ("comment time unreadable", comments([{"author": "peter-wa", "created_at": "yesterday"}])), ("comment not an object", comments(["just a string"])),
                  ("reflog rc", reflog("FAIL")), ("reflog timeout", reflog("TIMEOUT")), ("reflog junk", reflog("not a reflog line\n")),
                  ("rig list rc", lists("FAIL")), ("rig list timeout", lists("TIMEOUT")), ("rig list text", lists("not json")), ("rig list object", lists('{"issues": []}')), ("rig list null", lists("null")), ("rig list empty", lists("")),
                  ("rig list with a non-object row", lists([bead("wa-aaa", "peter-wa"), "oops"])), ("hq list rc", lambda s: s.io.lists.__setitem__(s.w.city, "FAIL")),
                  ("row without id", extra({"assignee": "peter-wa", "status": "in_progress"})), ("row with empty id", extra({"id": "", "assignee": "peter-wa"})), ("row with numeric id", extra({"id": 123, "assignee": "peter-wa"}))]
        for what, plant in plants:
            with self.subTest(what):
                self.fresh("o")
                plant(self)
                self.assertEqual(self.go(), 1)
                t = self.alert()
                self.assertTrue("NÃO CONFERIDA" in t and "peter-wa" in t and "SEM retomar" not in t and self.pushes("3") == [], t)

    def test_one_readable_proof_wins_over_unreadable_sources_and_none_and_unknown_share_one_push(self):
        self.two()
        self.proven()
        self.io.reflogs[self.p], self.io.lists[self.w.city] = "FAIL", "FAIL"
        self.io.comments[(self.wa, "wa-aaa")] = [comment("peter-wa", BOOT + 60)]
        self.assertEqual(self.go(), 0)
        self.io.lists[self.w.city], self.io.reflogs[self.p], self.io.reflogs[self.o] = [], "", "FAIL"  # an empty reflog is none, a failing one is unknown
        self.io.comments[(self.wa, "wa-aaa")], self.io.comments[(self.wa, "wa-bbb")] = [], "FAIL"
        self.assertEqual(self.go(), 1)
        t = self.alert()
        self.assertEqual((t.count("SEM retomar"), "não consegui" in t, "peter-wa" in t, "oracle-wa" in t), (1, True, True, True))

    def test_what_cannot_be_read_at_the_run_level_is_unknown_and_reads_nothing_else(self):
        def broken_toml(s): os.makedirs(os.path.join(s.w.city, "agents", "broken", "agent.toml"))  # opening a directory raises
        plants = [("agents dir missing", lambda s: shutil.rmtree(os.path.join(s.w.city, "agents")), "agents"), ("agent.toml unreadable", broken_toml, "agent.toml"), ("city.toml missing", lambda s: os.remove(os.path.join(s.w.city, "city.toml")), "city.toml"),
                  ("boot in the future", lambda s: setattr(s.io, "boot", NOW + 3600), "depois de agora")]
        plants += [("sysctl %r" % (v,), lambda s, v=v: setattr(s.io, "sysctl", v), "kern.boottime") for v in ((1, ""), (None, ""), (0, ""), (0, "garbage"), (0, "{ usec = 5 }"))]
        for what, plant, word in plants:
            with self.subTest(what):
                self.fresh()
                plant(self)
                self.assertEqual(self.go(), 1)
                t = self.alert()
                self.assertTrue("NÃO CONFERIDA" in t and word in t and "26/11" in t and self.io.n("bd") == 0, t)
        self.fresh()
        shutil.rmtree(os.path.join(self.w.city, "agents"))
        os.makedirs(os.path.join(self.w.city, "agents"))
        self.assertEqual((self.go(), self.io.n("bd")), (0, 0), "no agents at all: nothing to prove (and nothing to read), and that is not an unreadable directory")

    def test_a_failing_read_is_retried_and_then_gives_up(self):
        self.two()
        self.proven()
        self.io.flaky.update({("bd-list", self.wa): 2, ("bd-comments", self.wa, "wa-aaa"): 1, ("git", self.p): 1})
        self.io.comments[(self.wa, "wa-aaa")] = [comment("peter-wa", BOOT + 60)]
        self.assertEqual(self.go(), 0)
        self.assertGreaterEqual(self.io.sleeps.count(7), 3, "the pause between tries is NRCP_RETRY_S")
        self.io.calls.clear()
        self.io.flaky[("bd-list", self.wa)] = 99
        self.assertEqual(self.go(), 1)
        self.assertEqual(self.io.n("bd", "list") - 1, 3, "3 tries on the rig store, one on HQ")


class Window(Base):
    def test_a_boot_before_the_window_means_no_reboot_tonight_the_first_second_of_it_counts_and_sec_is_not_usec(self):
        self.two()
        self.io.boot = ts("2026-11-25T22:59:59Z")
        self.assertEqual((self.go(), self.io.notifies, self.io.n("bd")), (0, [], 0))
        self.assertIn("sem reboot", self.w.log())
        self.io.boot = ts("2026-11-25T23:00:00Z")
        self.assertEqual(self.go(), 1)
        self.io.boot, self.io.sysctl = BOOT, (0, "{ usec = 958892, sec = %d } Wed" % BOOT)
        self.proven("p")
        self.proven("o")
        self.assertEqual(self.go(), 0)

    def test_the_deadline_is_0010_or_boot_plus_20_minutes_and_the_run_waits_for_it(self):
        self.two()
        self.io.t = DEADLINE + 5
        self.go()
        self.assertEqual(self.io.sleeps, [], "a normal boot: nothing to wait for")
        self.io.t = ts("2026-11-26T00:00:00Z")  # an early run waits for 00:10
        self.go()
        self.assertGreaterEqual(sum(self.io.sleeps), 600)
        late = ts("2026-11-25T23:58:00Z")  # the safety guards held the reboot until ~23:55: deadline 00:18, and a commit at 00:17 still counts
        self.io.boot, self.io.t, self.io.sleeps, self.io.calls, self.io.t_at = late, NOW, [], [], []
        self.io.reflogs[self.o] = self.io.reflogs[self.p] = [("HEAD", late + 1140, "commit: ok")]
        self.assertEqual(self.go(), 0)
        self.assertGreaterEqual(sum(self.io.sleeps), late + 1200 - NOW)
        self.assertGreaterEqual(min(self.io.t_at), late + 1200, "nothing is judged before the deadline")

    def test_the_clock_is_the_local_one(self):
        os.environ["TZ"] = "BRT3"  # the mini runs at -03:00: this night is 3 h later in UTC
        time.tzset()
        self.addCleanup(lambda: (os.environ.update(TZ="UTC"), time.tzset()))
        self.two()
        boot, deadline = ts("2026-11-26T02:42:00Z"), ts("2026-11-26T03:10:00Z")  # 23:42 and 00:10 local
        self.io.boot, self.io.t = boot, deadline + 40
        self.io.reflogs[self.p] = [("HEAD", deadline - 30, "commit: 00:09:30 local")]
        self.io.reflogs[self.o] = [("HEAD", deadline + 30, "commit: 00:10:30 local, late")]
        self.assertEqual(self.go(), 1)
        t = self.alert()
        self.assertTrue("oracle-wa" in t and "peter-wa" not in t and "25/11 23:42" in t and "26/11 00:10" in t, t)
        self.io.notifies.clear()
        self.io.reflogs[self.p] = self.io.reflogs[self.o] = [("HEAD", deadline - 60, "commit: 00:09 local")]
        self.assertEqual(self.go(), 0)
        self.assertIn("retomaram até 00:10: oracle-wa (commit 00:09), peter-wa (commit 00:09)", " ".join(self.pushes("3")[0]["argv"]), "the digest speaks local time too")
        self.io.boot, self.io.notifies = ts("2026-11-26T00:20:00Z"), []  # 21:20 local: before the 23:00 window
        self.assertEqual((self.go(), self.io.notifies), (0, []))


class Modes(Base):
    def test_dry_run_judges_as_of_now_and_sends_and_writes_nothing(self):
        self.two()
        self.assertEqual((self.go("--dry-run"), self.io.notifies, self.w.log()), (1, [], ""))
        self.assertTrue("peter-wa" in self.out and "FALTA" in self.out)
        self.proven("p")
        self.proven("o")
        self.io.t = ts("2026-11-25T23:50:00Z")
        self.assertEqual((self.go("--dry-run"), self.io.sleeps, self.io.notifies, self.w.log()), (0, [], [], ""))
        self.assertIn("23:50", self.out, "the deadline shown is now, not 00:10")

    def test_usage_and_kill_switch(self):
        for args in (["--nope"], ["--dry-run", "extra"], ["now"]):
            self.assertEqual((self.go(*args), self.io.calls), (2, []))
            self.assertIn("usage", self.err)
        self.two()
        off = os.path.join(self.w.city, ".gc", "nightly-reboot-crew-proof.off")
        open(off, "w").close()
        self.assertEqual((self.go(), self.io.calls), (0, []))
        self.assertIn("desligad", self.w.log())
        os.remove(off)
        self.assertEqual(self.go(), 1)

    def test_the_log_is_the_postchecks_in_its_format_and_its_directory_is_created(self):
        self.two()
        shutil.rmtree(os.path.join(self.w.city, ".gc", "logs"))
        self.go()
        lines = self.w.log().splitlines()
        self.assertTrue(lines and all(re.match(r"^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\] crew-proof: ", l) for l in lines))

    def test_a_crash_is_the_same_alarm_as_could_not_look_and_a_dry_run_just_raises(self):
        class Boom(FakeIO):
            def run(self, argv, timeout, env=None):
                if os.path.basename(argv[0]) == "bd":
                    raise RuntimeError("kaboom")
                return super().run(argv, timeout, env)

        self.two()
        self.io = Boom()
        self.assertRaises(RuntimeError, self.go, "--dry-run")
        self.assertEqual((self.io.notifies, self.w.log()), ([], ""), "a human testing at 3 pm must not get the 00:10 alarm")
        self.assertEqual(self.go(), 1)
        t = self.alert()
        self.assertTrue("NÃO CONFERIDA" in t and "RuntimeError: kaboom" in t and "quebrou" in self.w.log(), t)


class Delivery(Base):
    def test_the_alarm_is_forced_strict_dated_and_names_only_the_crews_without_proof(self):
        self.two()
        self.proven()
        self.assertEqual(self.go(), 1)
        t, first = self.alert(), self.pushes("4")[0]["argv"][-1]
        self.assertEqual(self.pushes("4")[0]["env"], {"NOTIFY_STRICT_EXIT": "1", "NOTIFY_FORCE_PUSH": "1"}, "-p 4 alone lands on the silent digest; without strict exit rc 0 proves nothing")
        self.assertTrue(all(x in t for x in ("SEM retomar", "peter-wa", "wa-aaa", "25/11 23:42", "26/11 00:10")) and "oracle-wa" not in t and "FALTA" in self.w.log(), t)
        self.io.notifies.clear()
        self.io.boot, self.io.t = BOOT + 86400, NOW + 86400  # the same crew silent the next night: notify drops a repeated text
        self.go()
        self.assertNotEqual(self.pushes("4")[0]["argv"][-1], first)

    def test_only_the_strict_exit_codes_that_mean_the_phone_was_reached_count_as_delivered(self):
        for rc, delivered in ((0, True), (11, True), (10, False), (12, False), (13, False), (14, False), (1, False), (124, False), (None, False)):  # 10 = held until 07:00, 12 = digest/cap
            with self.subTest(rc=rc):
                self.fresh()
                self.io.notify_rc = [rc]
                self.assertEqual(self.go(), 1)
                self.assertEqual((len(self.pushes("4")), "NÃO ENTREGUE" in self.err, "NÃO ENTREGUE" in self.w.log(), self.io.sleeps.count(15)), (1, False, False, 0) if delivered else (2, True, True, 1))
        self.fresh()
        self.io.notify_rc = [1, 0]
        self.go()
        self.assertEqual((len(self.pushes("4")), "NÃO ENTREGUE" in self.err), (2, False), "delivered on the retry")

    def test_a_routine_digest_that_fails_is_only_logged(self):
        for rc in (1, 11, 124, None):  # plain notify: only 0 is success
            with self.subTest(rc=rc):
                self.fresh("po")
                self.io.notify_rc = [rc]
                self.assertEqual((self.go(), len(self.io.notifies)), (0, 1))
                self.assertTrue("WARN: notify digest p3 falhou" in self.w.log() and "o aviso de rotina (digest) não saiu" in self.w.log())

    def test_a_very_long_list_is_cut_to_fit_a_phone_notification(self):
        self.two()
        for i in range(40):
            self.io.reflogs[self.w.crew("crew%02d-wa" % i, slug="c%02d" % i)] = []
            self.io.comments[(self.wa, "wa-x%02d" % i)] = []
            self.io.lists[self.wa].append(bead("wa-x%02d" % i, "crew%02d-wa" % i))
        self.assertEqual(self.go(), 1)
        body = self.pushes("4")[0]["argv"][-1]
        self.assertTrue(len(body) <= 900 and "crew00-wa" in body and re.search(r"\+\d+", body), body)


class Real(Base):
    """real processes (the real IO, `python3 -I script`, stub sysctl/bd/notify), real git (a real local commit in the reflog) and the real clock"""

    def prog(self, name, body):
        p = os.path.join(self.tmp, name)
        with open(p, "w") as fh:
            fh.write("#!/bin/sh\n" + body)
        os.chmod(p, 0o755)
        return p

    def fx(self, name, data):
        with open(os.path.join(self.tmp, name), "w") as fh:
            json.dump(data, fh)

    def commit(self, wd, name, when):
        with open(os.path.join(wd, name), "w") as fh:
            fh.write("1\n")
        git(wd, "add", name)
        git(wd, "commit", "-q", "-m", name, when=when)

    def test_end_to_end_through_real_processes(self):
        now = int(time.time())
        boot, log = now - 7000, os.path.join(self.tmp, "notify.log")
        env = {k: v for k, v in os.environ.items() if not k.startswith(("NRCP_", "NOTIFY_"))}
        env.update(self.w.env(
            NRCP_SYSCTL=self.prog("sysctl", 'echo "{ sec = %d, usec = 7 }"\n' % boot),
            NRCP_BD=self.prog("bd", 'case "$3" in list) cat "%s/list-$(basename "$2").json" ;; comments) cat "%s/comments-$4.json" ;; *) exit 9 ;; esac\n' % (self.tmp, self.tmp)),
            NRCP_NOTIFY=self.prog("notify", 'printf "FORCE=%%s STRICT=%%s ARGS=%%s\\n" "${NOTIFY_FORCE_PUSH:-}" "${NOTIFY_STRICT_EXIT:-}" "$(printf %%s "$*" | tr "\\n" "|")" >> "%s"\n' % log),
            NRCP_WINDOW_FROM_HHMM=time.strftime("%H:%M", time.localtime(now - 3 * 3600)), NRCP_DEADLINE_HHMM=time.strftime("%H:%M", time.localtime(now - 3600)), NRCP_MIN_GRACE_S="60", NRCP_TRIES="1", NRCP_RETRY_S="1"))
        for n in ("peter-wa", "oracle-wa"):
            os.makedirs(self.w.crew(n))
            git(self.w.wd[n], "init", "-q")
        self.commit(self.w.wd["oracle-wa"], "f", boot + 120)
        self.fx("list-whatsapp_automation.json", [bead("wa-aaa", "peter-wa-gawisp5kf1go", started=boot - 3600), bead("wa-bbb", "oracle-wa", started=boot - 3600)])
        self.fx("list-.gascity-gastown-hq.json", [])
        self.fx("comments-wa-aaa.json", [comment("automation", boot + 200), comment("gastown.mayor", boot + 210)])

        def run(*args):
            r = subprocess.run([sys.executable, "-I", SUT] + list(args), capture_output=True, text=True, env=env, timeout=120)
            if not os.path.exists(log):
                return r, []
            with open(log) as fh:
                return r, fh.read().splitlines()

        r, lines = run()
        self.assertEqual((r.returncode, len(lines)), (1, 1), r.stderr)
        self.assertTrue(lines[0].startswith("FORCE=1 STRICT=1 ARGS=-t Reboot noturno: crew SEM retomar -p 4 ") and "peter-wa: wa-aaa" in lines[0] and "oracle-wa" not in lines[0], lines[0])
        self.assertIn("oracle-wa OK: commit", self.w.log())
        env.update(NRCP_SYSCTL=os.path.join(self.tmp, "none"), NRCP_NOTIFY=os.path.join(self.tmp, "none"), NRCP_NOTIFY_RETRY_S="1")  # no tools at all: never silent
        r, _ = run()
        self.assertTrue(r.returncode == 1 and "NÃO ENTREGUE" in r.stderr and "NAO-SEI" in self.w.log(), r.stderr)


class Units(unittest.TestCase):
    def test_realio_reports_a_timeout_or_a_missing_program_as_no_rc(self):
        self.assertEqual((P.RealIO().run(["sleep", "5"], 0.3), P.RealIO().run(["/no/such/program"], 5)), ((None, "", ""), (None, "", "")))

    def test_parse_ts(self):
        t = ts("2026-11-26T00:05:30Z")
        for s in ("2026-11-26T00:05:30Z", "2026-11-26T00:05:30.123456Z", "2026-11-26T00:05:30+00:00", "2026-11-25T21:05:30-03:00", "2026-11-26T03:05:30+03:00", "2026-11-25T21:05:30-0300", "2026-11-26 00:05:30Z", "  2026-11-26T00:05:30Z  "):
            self.assertEqual(P.parse_ts(s), t, s)
        for s in (None, 5, [], "", "yesterday", "2026-11-26", "2026-11-26T00:05:30", "2026-11-26T00:05Z", "2026-13-26T00:05:30Z", "2026-11-31T00:05:30Z", "2026-11-26T25:05:30Z", "2026-11-26T00:61:30Z", "2026-11-26T00:05:30Zjunk", "x2026-11-26T00:05:30Z"):
            self.assertIsNone(P.parse_ts(s), repr(s))

    def test_local_time_helpers_and_knobs(self):
        n, t = ts("2026-11-26T23:00:00Z"), ts("2026-11-26T00:10:00Z")
        self.assertEqual((P.last_local(n, 23, 0), P.last_local(n - 1, 23, 0), P.last_local(n + 3600, 23, 0)), (n, n - 86400, n))
        self.assertEqual((P.first_local_after(t, 0, 10), P.first_local_after(t - 1, 0, 10)), (t + 86400, t))
        for v, want in (("00:10", (0, 10)), ("0:10", (0, 10)), ("23:59", (23, 59)), (" 07:05 ", (7, 5)), ("24:00", (9, 9)), ("12:60", (9, 9)), ("noon", (9, 9)), ("", (9, 9)), (None, (9, 9))):
            self.assertEqual(P.hhmm(v, (9, 9)), want, repr(v))
        for v, want in (("5", 5), (" 7 ", 7), ("0", 3), ("-2", 3), ("x", 3), ("", 3), (None, 3), ("1.5", 3)):
            self.assertEqual(P.num(v, 3), want, repr(v))

    def test_config_defaults_and_precedence(self):
        c = P.Cfg({})
        self.assertEqual((c.window_from, c.deadline_at, c.grace_s, c.tries, c.retry_s, c.call_t, c.notify_pause), ((23, 0), (0, 10), 1200, 3, 20, 90, 15))
        self.assertEqual((c.city, c.sysctl, c.bd, c.git, c.notify), ("/Users/athos/gt/.gascity-gastown-hq", "/usr/sbin/sysctl", "bd", "git", "notify"))
        self.assertTrue(c.log_path.endswith("/.gc/logs/nightly-reboot.log") and c.off_path.endswith("/.gc/nightly-reboot-crew-proof.off"))
        self.assertEqual([P.Cfg(e).city for e in ({"NRCP_CITY": "/a", "GC_CITY_PATH": "/b"}, {"GC_CITY_PATH": "/b"})] + [P.Cfg({"NRCP_BD": "x", "BD_BIN": "y"}).bd], ["/a", "/b", "x"])
        c = P.Cfg({"NRCP_WINDOW_FROM_HHMM": "22:30", "NRCP_DEADLINE_HHMM": "00:25", "NRCP_MIN_GRACE_S": "600", "NRCP_TRIES": "5", "NRCP_RETRY_S": "9", "NRCP_CALL_TIMEOUT_S": "33", "NRCP_NOTIFY_RETRY_S": "4"})
        self.assertEqual((c.window_from, c.deadline_at, c.grace_s, c.tries, c.retry_s, c.call_t, c.notify_pause), ((22, 30), (0, 25), 600, 5, 9, 33, 4))

    def test_the_plist_fires_at_0010_and_the_sources_parse_as_3_9(self):
        import ast
        import plistlib
        with open(os.path.join(HERE, "com.gascity.nightly-reboot-crew-proof.plist"), "rb") as fh:
            d = plistlib.load(fh)
        self.assertEqual((d["Label"], d["StartCalendarInterval"], d.get("RunAtLoad"), "KeepAlive" in d), ("com.gascity.nightly-reboot-crew-proof", {"Hour": 0, "Minute": 10}, False, False))
        a, e = d["ProgramArguments"], d["EnvironmentVariables"]
        self.assertTrue(a[0] == "/usr/bin/python3" and "-I" in a and a[-1].endswith("/scripts/nightly-reboot-crew-proof.py") and e["BEADS_DOLT_AUTO_START"] == "0" and "/Users/athos/.local/bin" in e["PATH"])
        for path in (SUT, os.path.abspath(__file__)):  # the mini's /usr/bin/python3 is 3.9
            with open(path, encoding="utf-8") as fh:
                ast.parse(fh.read(), filename=path, feature_version=(3, 9))


if __name__ == "__main__":
    unittest.main(verbosity=1)
