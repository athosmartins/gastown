#!/usr/bin/env python3
"""test_live_conversation_capture.py (ga-esorlre.2): hermetic suite for scripts/live-conversation-capture.py. FakeIO emulates gc/bd/tmux/ps over REAL files in a temp tree; one test
drives a REAL tmux server (private socket) and the real ps. `python3 -I` on 3.9 and 3.12; LCC_UNDER_TEST=<copy> runs it against a mutant."""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SUT = os.environ.get("LCC_UNDER_TEST") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "live-conversation-capture.py")
_spec = importlib.util.spec_from_file_location("lcc", SUT)
L = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(L)

U1, U2, U3 = ("%08d-0000-4000-8000-%012d" % (i, i) for i in (1, 2, 3))
NOW = 1800000000.0
K_ID, K_AT = "session.live_conversation_id", "session.live_conversation_at"


def rd(path):
    with open(path) as fh:
        return fh.read()


class FakeIO:
    def __init__(self):
        self.t, self.calls, self.tmo, self.fail, self.on_sleep = NOW, [], [], {}, None
        self.roster, self.panes, self.procs, self.meta = [], {}, {}, {}

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s
        if self.on_sleep:
            self.on_sleep()

    def n(self, tool, verb=None):
        return sum(1 for c in self.calls if os.path.basename(c[0]) == tool and (verb is None or verb in c))

    def run(self, argv, timeout):
        self.calls.append(list(argv))
        self.tmo.append(timeout)
        self.t += 0.05
        tool = os.path.basename(argv[0])
        verb = next((v for v in ("update", "show") if v in argv), "")
        f = self.fail.get(tool + ":" + verb, self.fail.get(tool, False))
        if f is not False:
            return f
        if tool == "gc":
            return 0, json.dumps({"ok": True, "schema_version": "1", "sessions": self.roster}), ""
        if tool == "ps":  # procs: pid -> (ppid, start epoch); the age is what ps would say NOW, so every clock move keeps the world consistent
            return 0, "".join("%d %d %02d:%02d:%02d\n" % (p, pp, (self.t - st) // 3600, (self.t - st) % 3600 // 60, (self.t - st) % 60) for p, (pp, st) in sorted(self.procs.items())), ""
        if tool == "tmux":
            name = next(a for a in argv if a.startswith("="))[1:-1]
            return (0, "".join("%d\n" % p for p in self.panes[name]), "") if name in self.panes else (1, "", "can't find session: %s\n" % name)
        if tool == "bd" and verb == "update":
            sets = [a for i, a in enumerate(argv) if i and argv[i - 1] == "--set-metadata"]
            self.meta.setdefault(argv[argv.index("update") + 1], {}).update(dict(a.split("=", 1) for a in sets))
            return 0, "", ""
        if tool == "bd" and verb == "show":
            b = argv[argv.index("show") + 1]
            return 0, json.dumps([{"id": b, "metadata": self.meta.get(b, {})}]), ""
        raise AssertionError("unexpected call %r" % (argv,))


class World:
    def __init__(self, tc):
        self.d = tempfile.mkdtemp(prefix="lcc-t-")
        tc.addCleanup(shutil.rmtree, self.d, True)
        self.city, self.home, self.io = os.path.join(self.d, "city"), os.path.join(self.d, "home"), FakeIO()
        for p in ("city/.gc/logs", "city/agents", "home/.claude/sessions", "home/.claude/projects/-p"):
            os.makedirs(os.path.join(self.d, p))
        self.env = {"GC_CITY_PATH": self.city, "LCC_HOME": self.home, "LCC_TMUX_SOCKET": "gascity", "LCC_ENABLED": "1"}

    def p(self, *a):
        return os.path.join(self.city, *a)

    def agent(self, name, toml):
        os.makedirs(self.p("agents", name), exist_ok=True)
        with open(self.p("agents", name, "agent.toml"), "w") as fh:
            fh.write(toml)

    def reg(self, pid, sid, tname, kind="interactive", off=1.0, raw=None, tmux="auto"):
        e = {"pid": pid, "sessionId": sid, "kind": kind, "tmux": "%s:@1.%%1" % tname if tmux == "auto" else tmux, "cwd": "/x"}
        path = "%s/.claude/sessions/%d.json" % (self.home, pid)
        with open(path, "w") as fh:
            fh.write(raw if raw is not None else json.dumps(e))
        t = self.io.procs[pid][1] + off  # off seconds after the process started (negative = a file older than its process)
        os.utime(path, (t, t))

    def transcript(self, sid):
        with open("%s/.claude/projects/-p/%s.jsonl" % (self.home, sid), "w") as fh:
            fh.write("{}\n")

    def session(self, tmpl, bead, tname, base, sid, state="active", wd="/x/rig/crew/x"):
        """roster entry + tmux pane + the REAL shape of the tree (pane sh -> sh -c -> claude) + registry + transcript; returns the claude pid"""
        self.io.roster.append({"id": bead, "name": tmpl, "session_name": tname, "template": tmpl, "state": state, "work_dir": wd})
        self.io.panes[tname] = [base]
        for pid, pp, age in ((base, 1, 5000), (base + 10, base, 4990), (base + 20, base + 10, 4980)):
            self.io.procs[pid] = (pp, NOW - age)
        self.reg(base + 20, sid, tname)
        self.transcript(sid)
        return base + 20

    def crew(self, tmpl="thies-wa", bead="ga-wisp-aaa", base=100, sid=U1, **kw):
        self.agent(tmpl, 'max_active_sessions = 1\nwork_dir = "/x/rig/crew/%s"\n' % tmpl)
        return self.session(tmpl, bead, "%s-gawisp%s" % (tmpl, bead[-3:]), base, sid, **kw)

    def mayor(self, bead="ga-wisp-mmm", base=200, sid=U2):
        return self.session("gastown.mayor", bead, "gastown__mayor", base, sid)

    def go(self, final=False, dry=False, **env):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return L.run_pass(L.Cfg(dict(self.env, **env)), self.io, final, dry)

    def main(self, *args, **env):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            rc = L.main(list(args), dict(self.env, **env), self.io)
        return rc, out.getvalue()

    def stored(self, bead="ga-wisp-aaa"):
        return self.io.meta.get(bead, {}).get(K_ID)


class Resolve(unittest.TestCase):
    def setUp(self):
        self.w = World(self)

    def test_golden_path_through_the_real_wrapper_shape_writes_and_reads_back(self):
        self.w.crew()
        self.w.io.panes["thies-wa-gawispaaa"].append(4242)  # a pane pid that already exited: not in ps, must not break the pass
        code, c = self.w.go()
        self.assertEqual((code, c["wrote"], self.w.stored()), (0, 1, U1))
        upd = next(x for x in self.w.io.calls if x[0] == "bd" and "update" in x)
        self.assertEqual(upd[:5], ["bd", "-C", self.w.city, "update", "ga-wisp-aaa"])
        sets = [a for i, a in enumerate(upd) if i and upd[i - 1] == "--set-metadata"]  # ONE bd call carries both keys: one commit, never half a capture
        self.assertEqual(sorted(sets), sorted([K_ID + "=" + U1, K_AT + "=%d" % NOW]))
        self.assertEqual(self.w.io.n("bd", "show"), 1)  # and it was read back

    def test_only_active_mayor_and_named_crews_are_targets(self):
        w = self.w
        w.crew("thies-wa", "ga-wisp-aaa", 100, U1)
        w.crew("digo-wa", "ga-wisp-bbb", 300, U3, state="asleep")
        w.mayor()
        w.agent("wa-worker", 'max_active_sessions = 4\nwork_dir = "/x/rig/crew/worker"\n')
        w.agent("peter-wa", 'max_active_sessions = 1\nwork_dir = "/x/rig/crew/peter"\n')
        w.agent("broken", "")
        w.agent("gate-reviewer", "max_active_sessions = 6\n")
        for t, b, base in (("wa-worker", "ga-wisp-www", 500), ("gastown.dog", "ga-wisp-ddd", 600), ("whatsapp_automation/peter-wa", "ga-wisp-ppp", 700), ("gastown.deacon", "ga-wisp-eee", 800)):
            w.session(t, b, b + "-s", base, U3)
        w.session("mayor", "ga-wisp-yyy", "mayor", 900, U3)  # the other spelling of the Mayor's template seen in the repo's fixtures
        mm = {"template": "gastown.mayor", "state": "active"}  # malformed rows (not a dict / bad template / bad session_name / bad id) are skipped and never stop the others
        w.io.roster += ["not a dict", {"id": "b1", "template": 7, "state": "active", "session_name": "s"}, dict(mm, id="b2", session_name=["x"]), dict(mm, id=None, session_name="z")]
        code, c = w.go()
        self.assertEqual(sorted(w.io.meta), ["ga-wisp-aaa", "ga-wisp-mmm", "ga-wisp-ppp", "ga-wisp-yyy"])
        self.assertEqual((code, c["targets"], c["wrote"]), (0, 4, 4))

    def test_the_conversation_is_the_one_in_the_registry_of_the_process_under_this_pane_not_a_neighbour(self):
        w = self.w
        w.crew("thies-wa", "ga-wisp-aaa", 100, U1)
        w.io.procs[999] = (1, NOW - 4000)
        w.reg(999, U3, "thies-wa-gawispaaa")  # fresh file of a process outside the pane: a neighbour
        w.transcript(U3)
        w.go()
        self.assertEqual(w.stored(), U1)

    def test_registry_file_older_than_its_process_is_a_stale_pid_reuse_and_is_ignored(self):
        pid = self.w.crew()
        self.w.reg(pid, U3, "thies-wa-gawispaaa", off=-7200)  # written 2 h BEFORE this process started
        self.w.transcript(U3)
        code, c = self.w.go()
        self.assertEqual((c["absent"], c["wrote"], self.w.io.n("bd")), (1, 0, 0))

    def test_time_passing_between_the_ps_sample_and_the_registry_read_does_not_age_the_file(self):
        w = self.w
        w.crew()
        real = w.io.run

        def slow(argv, timeout):  # tmux answers 20 s late (load): the age ps gave is 20 s old when the file is read
            w.io.t += 20 if os.path.basename(argv[0]) == "tmux" else 0
            return real(argv, timeout)
        w.io.run = slow
        self.assertEqual(w.go()[1]["wrote"], 1)

    def test_two_conversations_in_one_pane_are_unknown_never_a_guess_but_the_same_one_twice_is_one(self):
        for sid, want in ((U2, "unknown"), (U1, "wrote")):
            w = World(self)
            w.crew()
            w.io.procs[121] = (110, NOW - 4970)
            w.reg(121, sid, "thies-wa-gawispaaa")
            w.transcript(sid)
            self.assertEqual((w.go()[1][want], w.io.n("bd", "update")), (1, 1 if want == "wrote" else 0))

    def test_claude_as_the_pane_process_itself_and_claude_deep_below_the_pane(self):
        w = self.w  # `exec claude` in the pane script (no wrapper at all) ...
        w.crew()
        w.io.panes["thies-wa-gawispaaa"] = [120]
        del w.io.procs[100], w.io.procs[110]
        w.io.procs[120] = (1, NOW - 4980)
        self.assertEqual(w.go()[1]["wrote"], 1)
        w = World(self)  # ... and a claude 6 levels below the pane's sh instead of 2
        w.crew()
        del w.io.procs[120]
        os.remove("%s/.claude/sessions/120.json" % w.home)
        for pid in range(111, 116):
            w.io.procs[pid] = (max(110, pid - 1), NOW - 4970)
        w.reg(115, U1, "thies-wa-gawispaaa")
        self.assertEqual(w.go()[1]["wrote"], 1)

    def test_helper_kinds_and_the_registry_tmux_field(self):
        for label, kw, want in (("sdk helper only", dict(kind="sdk"), "absent"), ("kind null/missing is accepted", dict(kind=None), "wrote"),
                                ("tmux field of ANOTHER session", dict(tmux="other-session:@1.%1"), "unknown"), ("tmux field null is accepted", dict(tmux=None), "wrote")):
            with self.subTest(label):
                w = World(self)
                pid = w.crew()
                w.reg(pid, U1, "thies-wa-gawispaaa", **kw)
                self.assertEqual(w.go()[1][want], 1)
                self.assertEqual(w.io.n("bd", "update"), 1 if want == "wrote" else 0)

    def test_no_claude_in_the_pane_or_no_transcript_never_touches_the_bead(self):
        w = self.w
        pid = w.crew()
        os.remove("%s/.claude/projects/-p/%s.jsonl" % (w.home, U1))
        self.assertEqual(w.go()[1]["absent"], 1)  # live process, but no resumable transcript
        os.remove("%s/.claude/sessions/%d.json" % (w.home, pid))
        self.assertEqual(w.go()[1]["absent"], 1)  # no registry entry under the pane at all
        self.assertEqual(w.io.n("bd"), 0)

    def test_unreadable_registry_is_unknown_not_absent(self):
        for label, raw in (("corrupt", "{not json"), ("not a uuid", json.dumps({"pid": 120, "sessionId": "garbage"})), ("empty object", "{}"), ("a list", "[]"),
                           ("pid field of another process", json.dumps({"pid": 999, "sessionId": U1}))):
            with self.subTest(label):
                w = World(self)
                w.crew()
                w.reg(120, U1, "t", raw=raw)
                code, c = w.go()
                self.assertEqual((c["unknown"], w.io.n("bd")), (1, 0))

    @unittest.skipIf(os.geteuid() == 0, "SKIP (root reads everything): chmod 0 cannot make the registry unreadable")
    def test_permission_denied_on_the_registry_file_or_its_directory_is_unknown(self):
        for what in ("120.json", ""):
            with self.subTest(what or "sessions dir"):
                w = World(self)
                w.crew()
                target = "%s/.claude/sessions/%s" % (w.home, what)
                os.chmod(target, 0)
                self.addCleanup(os.chmod, target, 0o700)
                self.assertEqual((w.go()[1]["unknown"], w.io.n("bd")), (1, 0))

    def test_tmux_failures(self):
        for label, f, want in (("session missing (rc 1)", (1, "", "can't find session: x"), "absent"), ("timeout / no binary", (None, "", ""), "unknown"),
                               ("rc 0 but no pane pid", (0, "garbage\n", ""), "unknown")):
            with self.subTest(label):
                w = World(self)
                w.crew()
                w.io.fail["tmux"] = f
                self.assertEqual((w.go()[1][want], w.io.n("bd")), (1, 0))

    def test_ps_failures_make_every_target_unknown(self):
        good = "100 1 83:20\n110 100 83:10\n120 110 83:00\n200 1 83:20\n210 200 83:10\n220 210 83:00\n"
        for label, f in (("rc != 0", (1, "", "ps: boom")), ("rc != 0 with a good-looking table", (1, good, "ps: boom")), ("timeout", (None, "", "")),
                         ("garbage output", (0, "garbage\nnot a table\n", ""))):
            with self.subTest(label):
                w = World(self)
                w.crew()
                w.mayor()
                w.io.fail["ps"] = f
                code, c = w.go()
                self.assertEqual((c["unknown"], c["wrote"], w.io.n("bd")), (2, 0, 0))


class Pass(unittest.TestCase):
    def setUp(self):
        self.w = World(self)
        self.w.crew()

    def test_roster_failures_are_exit_3_and_write_nothing(self):
        for label, f in (("rc != 0", (1, "", "boom")), ("rc != 0 with a good body", (1, '{"sessions": []}', "boom")), ("timeout", (None, "", "")), ("garbage", (0, "{not json", "")),
                         ("no sessions key", (0, "{}", "")), ("sessions not a list", (0, '{"sessions": 7}', ""))):
            with self.subTest(label):
                self.w.io.fail["gc"] = f
                self.assertEqual((self.w.go()[0], self.w.io.n("bd")), (3, 0))

        self.w.io.fail.clear()  # and the list of crews: no agents/ (or no city) = cannot tell who the crews are
        self.assertEqual(self.w.go(GC_CITY_PATH="/nonexistent/city")[0], 3)
        shutil.rmtree(self.w.p("agents"))
        self.assertEqual((self.w.go()[0], self.w.io.n("bd")), (3, 0))

    def test_crew_rule_layer1_reads_agent_toml(self):
        w = World(self)
        w.agent("a", 'max_active_sessions = 1\nwork_dir = "/x/crew/a"\n')
        w.agent("b", 'work_dir = "/x/crew/b"\n')
        w.agent("c", 'max_active_sessions = 2\nwork_dir = "/x/crew/c"\n')
        w.agent("d", 'max_active_sessions = 1\nwork_dir = "/x/crew/worker"\n')
        w.agent("e", 'max_active_sessions = 1\nwork_dir = "/x/other/e"\n')
        w.agent("f", "")
        os.makedirs(w.p("agents", "g"))
        self.assertEqual(sorted(L.crew_names(w.p("agents"))), ["a", "b"])
        self.assertIsNone(L.crew_names("/nonexistent/agents"))
        if os.geteuid() != 0:  # an agent.toml that cannot be read is "cannot tell who the crews are", never "not a crew"
            os.chmod(w.p("agents", "a", "agent.toml"), 0)
            self.assertIsNone(L.crew_names(w.p("agents")))

    def test_kill_switch_env_and_file(self):
        self.assertEqual((self.w.main(LCC_ENABLED="0")[0], self.w.io.n("gc")), (0, 0))
        open(self.w.p(".gc", "live-conversation-capture.off"), "w").close()
        self.assertEqual((self.w.main()[0], self.w.io.n("gc"), self.w.io.n("bd")), (0, 0, 0))

    def test_unchanged_is_not_rewritten_until_refresh_is_due(self):
        w = self.w
        w.go()
        w.io.t += 120
        self.assertEqual((w.go()[1]["same"], w.io.n("bd", "update")), (1, 1))
        w.io.t += 1800
        self.assertEqual((w.go()[1]["wrote"], w.io.n("bd", "update")), (1, 2))
        w.io.t += 100
        self.assertEqual(w.go(LCC_REFRESH_S="60")[1]["wrote"], 1)

    def test_a_changed_conversation_is_written_on_the_next_pass_and_logged_with_both_ids(self):
        w = self.w
        w.go()
        w.io.t += 120
        w.reg(120, U3, "thies-wa-gawispaaa")
        w.transcript(U3)
        self.assertEqual((w.go()[1]["wrote"], w.stored()), (1, U3))
        log = rd(w.p(".gc", "logs", "live-conversation-capture.log"))
        self.assertTrue(U1 in log and U3 in log and "ga-wisp-aaa" in log)

    def test_final_forces_the_write_even_when_unchanged(self):
        w = self.w
        w.go()
        w.io.t += 5
        self.assertEqual((w.go(final=True)[1]["wrote"], w.io.n("bd", "update")), (1, 2))

    def test_update_failure_is_failed_and_retried_never_recorded_as_done(self):
        for label, f in (("rc 1", (1, "", "dolt down")), ("timeout", (None, "", ""))):
            with self.subTest(label):
                w = World(self)
                w.crew()
                w.io.fail["bd:update"] = f
                self.assertEqual((w.go()[1]["failed"], w.stored()), (1, None))
                del w.io.fail["bd:update"]
                w.io.t += 120
                self.assertEqual((w.go()[1]["wrote"], w.stored()), (1, U1))

    def test_a_failed_update_is_failed_even_when_an_older_value_reads_back(self):
        w = self.w
        w.go()
        w.io.t += 1900  # refresh due; the update fails while `bd show` still returns the earlier, matching value
        w.io.fail["bd:update"] = (1, "", "dolt down")
        self.assertEqual((w.go()[1]["failed"], w.io.n("bd", "update")), (1, 2))

    def test_a_write_that_cannot_be_read_back_is_failed(self):
        for label, f in (("show rc 1", (1, "", "x")), ("show garbage", (0, "{not json", "")), ("show without the value", (0, '[{"metadata": {}}]', "")),
                         ("show empty list", (0, "[]", "")), ("show timeout", (None, "", ""))):
            with self.subTest(label):
                w = World(self)
                w.crew()
                w.io.fail["bd:show"] = f
                self.assertEqual(w.go()[1]["failed"], 1)
                del w.io.fail["bd:show"]
                w.io.t += 120
                self.assertEqual(w.go()[1]["wrote"], 1)  # not recorded as done: the next pass writes again

    def test_dry_run_writes_nothing_and_remembers_nothing(self):
        w = self.w
        code, c = w.go(dry=True)
        self.assertEqual((c["wrote"], w.io.n("bd"), os.path.exists(w.p(".gc", "live-conversation-capture.state.json"))), (1, 0, False))
        self.assertEqual(w.go()[1]["wrote"], 1)

    def test_state_file_garbage_or_unreadable_only_means_one_more_write(self):
        w = self.w
        w.go()
        for bad in ("{not json", "[]", '{"v":1,"beads":7}', '{"beads": {"ga-wisp-aaa": {"cid": "%s", "at": "garbage"}}}' % U1):
            with self.subTest(bad):
                with open(w.p(".gc", "live-conversation-capture.state.json"), "w") as fh:
                    fh.write(bad)
                w.io.t += 5
                self.assertEqual(w.go()[1]["wrote"], 1)
        self.assertEqual(L.load_state("/nonexistent/state.json"), {})

    def test_vanished_beads_are_pruned_the_last_good_value_stays_and_a_note_is_logged_once(self):
        w = self.w
        w.go()
        sp = w.p(".gc", "live-conversation-capture.state.json")
        L.save_state(sp, dict(L.load_state(sp), **{"ga-wisp-old": {"cid": U3, "at": 1}}))  # a bead that left the roster
        w.io.roster[0]["state"] = "closed"  # no longer a target: its last good value must NOT be erased by absence
        w.io.roster.append(dict(w.io.roster[0], id="ga-wisp-zzz", state="active", session_name="gone"))  # active, but no tmux session: absent
        w.go()
        w.go()
        st = json.loads(rd(sp))["beads"]
        self.assertEqual((sorted(st), st["ga-wisp-aaa"]["cid"]), (["ga-wisp-aaa", "ga-wisp-zzz"], U1))
        self.assertEqual(rd(w.p(".gc", "logs", "live-conversation-capture.log")).count("ga-wisp-zzz"), 1)

    def test_summary_is_one_exact_stdout_line_and_the_exit_is_0(self):
        rc, out = self.w.main()
        self.assertEqual((rc, out), (0, "live-conversation-capture: alvos=1 gravou=1 igual=0 ausente=0 nao-sei=0 falhou=0\n"))
        self.w.io.fail["ps"] = (None, "", "")
        dry = self.w.main("--dry-run")[1].splitlines()  # a dry run is a diagnostic: the events come first on stdout, the summary is the LAST line
        self.assertEqual((len(dry), dry[-1]), (2, "live-conversation-capture: alvos=1 gravou=0 igual=0 ausente=0 nao-sei=1 falhou=0 (dry-run)"))
        self.assertIn("UNKNOWN ga-wisp-aaa", dry[0])
        self.w.io.fail.clear()
        os.remove("%s/.claude/projects/-p/%s.jsonl" % (self.w.home, U1))
        self.assertEqual(self.w.main("--final")[1], "live-conversation-capture[final]: alvos=1 gravou=0 igual=0 ausente=1 nao-sei=0 falhou=0\n")

    def test_exit_2_for_usage_and_3_for_a_lock_that_cannot_be_taken_which_is_not_busy(self):
        with mock.patch("fcntl.flock", side_effect=OSError(37, "no locks available")):
            self.assertEqual((self.w.main()[0], self.w.io.n("gc")), (3, 0))
        self.assertEqual(self.w.main(GC_CITY_PATH="/nonexistent/city")[0], 3)  # the lock file cannot even be opened
        self.assertEqual(self.w.main("--bogus")[0], 2)

    def test_lock_busy_is_exit_4_and_final_waits_for_it(self):
        import fcntl
        fh = open(self.w.p(".gc", "live-conversation-capture.lock"), "w")
        self.addCleanup(fh.close)
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertEqual((self.w.main()[0], self.w.io.n("gc")), (4, 0))
        t0 = self.w.io.t
        self.assertEqual(self.w.main("--final", LCC_LOCK_WAIT_S="7")[0], 4)
        self.assertTrue(7 <= self.w.io.t - t0 < 9)
        self.w.io.on_sleep = lambda: fcntl.flock(fh, fcntl.LOCK_UN)
        self.assertEqual((self.w.main("--final")[0], self.w.stored()), (0, U1))
        fh.close()

    def test_the_budget_clamps_every_call_and_leaves_the_targets_it_cannot_reach_unknown(self):
        w = self.w
        w.go(LCC_BUDGET_S="30")
        self.assertEqual((w.io.tmo[0], max(w.io.tmo)), (30, 30))  # gc would have 45 s of its own, the pass has 30
        w.io.tmo.clear()
        w.go(final=True, LCC_FINAL_BUDGET_S="7")  # --final runs on its own, shorter budget
        self.assertEqual(w.io.tmo[0], 7)
        w.mayor()
        real = w.io.run

        def slow(argv, timeout):
            w.io.t += 40 if os.path.basename(argv[0]) == "tmux" else 0
            return real(argv, timeout)
        w.io.run = slow
        code, c = w.go(LCC_BUDGET_S="30")
        self.assertEqual((code, c["wrote"], c["unknown"]), (0, 1, 1))  # the first target ate the budget: the second is unknown, never run past it

    def test_etime_formats_of_ps(self):
        for s, want in (("05:10", 310), ("1:02:03", 3723), ("2-03:04:05", 183845), ("12", None), ("x-1:00", None)):
            self.assertEqual(L.parse_etime(s), want, s)


class Real(unittest.TestCase):
    def test_realio_run_never_turns_a_failure_into_an_empty_answer(self):
        r = L.RealIO()
        self.assertIsNone(r.run(["/nonexistent/lcc-bin"], 5)[0])
        with mock.patch("subprocess.run", side_effect=subprocess.TimeoutExpired("gc", 1)):
            self.assertIsNone(r.run(["gc"], 1)[0])
        rc, out, err = r.run([sys.executable, "-I", "-c", "import sys; print('x'); sys.stderr.write('e'); sys.exit(3)"], 30)
        self.assertEqual((rc, out.strip(), err.strip()), (3, "x", "e"))

    @unittest.skipUnless(shutil.which("tmux"), "SKIP (loud): tmux not installed, the real-process proof did not run")
    def test_real_tmux_and_real_ps_find_the_process_under_a_wrapper(self):
        d = tempfile.mkdtemp(prefix="lcc-real-")
        self.addCleanup(shutil.rmtree, d, True)
        sock = "lcct%d" % os.getpid()
        self.addCleanup(lambda: subprocess.run(["tmux", "-L", sock, "kill-server"], capture_output=True))
        home = d + "/home"
        for p in ("home/.claude/sessions", "home/.claude/projects/-p", "city/.gc/logs", "city/agents"):
            os.makedirs(os.path.join(d, p))
        subprocess.run(["tmux", "-L", sock, "new-session", "-d", "-s", "lcct", "sh -c 'sleep 300; true'"], check=True)
        pane = int(subprocess.run(["tmux", "-L", sock, "list-panes", "-s", "-t", "=lcct:", "-F", "#{pane_pid}"], capture_output=True, text=True).stdout.split()[0])
        kid = None
        for _ in range(50):
            rows = [ln.split() for ln in subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True).stdout.splitlines()]
            kid = next((int(a) for a, b in rows if int(b) == pane), None)
            if kid:
                break
            time.sleep(0.1)
        self.assertIsNotNone(kid, "the stand-in for claude never appeared under the pane")
        with open("%s/.claude/sessions/%d.json" % (home, kid), "w") as fh:
            json.dump({"pid": kid, "sessionId": U1, "kind": "interactive", "tmux": "lcct:@0.%0"}, fh)
        open("%s/.claude/projects/-p/%s.jsonl" % (home, U1), "w").close()
        gc, bd, log = d + "/gc", d + "/bd", d + "/bd.calls"
        with open(gc, "w") as fh:
            fh.write("#!/bin/sh\ncat <<'EOF'\n%s\nEOF\n" % json.dumps({"sessions": [{"id": "ga-wisp-real", "session_name": "lcct", "template": "gastown.mayor", "state": "active"}]}))
        with open(bd, "w") as fh:
            fh.write("#!/bin/sh\necho \"$@\" >> %s\ncase \"$*\" in *show*) echo '[{\"metadata\": {\"%s\": \"%s\"}}]';; esac\n" % (log, K_ID, U1))
        for f in (gc, bd):
            os.chmod(f, 0o755)
        env = {"GC_CITY_PATH": d + "/city", "LCC_HOME": home, "LCC_TMUX_SOCKET": sock, "LCC_GC": gc, "LCC_BD": bd}
        with contextlib.redirect_stdout(io.StringIO()):
            rc = L.main([], env)
        self.assertEqual(rc, 0)
        self.assertIn(K_ID + "=" + U1, rd(log))


if __name__ == "__main__":
    unittest.main(verbosity=1)
