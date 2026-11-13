#!/usr/bin/env python3
"""test_login_rc_restore.py (ga-bw9hmzg): hermetic suite for scripts/login-rc-restore.py. FakeIO emulates gc/ps/tmux/notify over REAL files (registry, transcripts, city.toml,
agent.toml) in a temp tree; nothing real is killed or notified. Stdlib unittest (runs under `/usr/bin/python3 -m unittest` and under pytest); LRR_UNDER_TEST=<copy> runs it against a mutant."""
import contextlib
import datetime
import importlib.util
import io
import json
import os
import shutil
import tempfile
import unittest

SUT = os.environ.get("LRR_UNDER_TEST") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "login-rc-restore.py")
_spec = importlib.util.spec_from_file_location("lrr", SUT)
L = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(L)

NOW = 1800000000.0
CITY_TOML = """
[[patches.agent]]
dir = ""
name = "gastown.mayor"
provider = "claude-rc"

[providers.claude-rc]
args_append = ["--remote-control", "Mayor", "--model", "opus"]
[providers.claude-rc-crew]
args_append = ["--remote-control", "--model", "opus"]
[providers.claude-rc-thies]
args_append = ["--remote-control", "Thies", "--model", "opus"]
[providers.claude-rc-digo]
args_append = ["--remote-control", "Digo", "--model", "opus"]
"""
LOGIN_CMD = {"type": "user", "message": {"role": "user", "content": "<command-name>/login</command-name>\n            <command-message>login</command-message>\n            <command-args></command-args>"}}
LOGIN_OUT = {"type": "user", "message": {"role": "user", "content": "<local-command-stdout>Login successful. Remote Control disconnected.</local-command-stdout>"}}
RC_BARE = {"type": "system", "subtype": "local_command", "content": "<command-name>/remote-control</command-name>\n            <command-message>remote-control</command-message>\n            <command-args></command-args>"}
RC_NAMED = dict(RC_BARE, content="<command-name>/remote-control</command-name>\n <command-message>remote-control</command-message>\n <command-args>Mayor</command-args>")
Q = LOGIN_OUT["message"]["content"] + " " + RC_BARE["content"]
QUOTED = ({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": "grep '%s' x" % Q}}]}},
          {"type": "user", "message": {"content": [{"type": "tool_result", "content": Q}]}}, {"type": "api-request-blob", "messages": [{"content": Q}]},
          {"type": "user", "message": {"content": "o Athos colou: " + Q}}, {"type": "assistant", "message": {"content": Q}})
STUCK = "some output\n\n  What do you want to do?\n  ❯ 1. Stop and wait for limit to reset\n    2. Upgrade\n Enter to confirm · Esc to cancel\n"
CLEAR = "● done\n────────────────\n❯ \n────────────────\n  opus · ctx 12%\n"
CREWS = {"thies": ("thies-wa", "ga-thies", 100, "Thies"), "digo": ("digo-wa", "ga-digo", 300, "Digo")}
M, T, D = "gh-mayor", "ga-thies", "ga-digo"

class FakeIO:
    def __init__(self):
        self.t, self.calls, self.fail, self.notify_rc = NOW, [], {}, 0
        self.roster, self.panes, self.procs, self.screens, self.kills, self.wakes, self.notes = [], {}, {}, {}, [], [], []
        self.engine = lambda verb, bead: None  # World installs what the real engine does with a kill / a wake

    def now(self):
        return self.t

    def run(self, argv, timeout, env=None):
        self.calls.append(list(argv))
        tool = os.path.basename(argv[0])
        verb = next((v for v in ("kill", "wake", "capture-pane") if v in argv), "")
        f = self.fail.get(tool + ":" + verb, self.fail.get(tool, False))
        if f is not False:
            return f
        if tool == "gc":
            if verb:
                (self.kills if verb == "kill" else self.wakes).append(argv[-1])
                self.engine(verb, argv[-1])
                return 0, "", ""
            return 0, json.dumps({"sessions": self.roster}), ""
        if tool == "ps":
            return 0, "".join("%d %d %02d:%02d:%02d %s\n" % (p, pp, (self.t - st) // 3600, (self.t - st) % 3600 // 60, (self.t - st) % 60, args)
                              for p, (pp, st, args) in sorted(self.procs.items())), ""
        if tool == "tmux" and verb:
            return 0, self.screens.get(argv[argv.index("-t") + 1], CLEAR), ""
        if tool == "tmux":
            name = next(a for a in argv if a.startswith("="))[1:-1]
            return (0, "%s %d\n" % self.panes[name], "") if name in self.panes else (1, "", "can't find session: %s\n" % name)
        if tool == "notify":
            self.notes.append((argv, env))
            return self.notify_rc, "", ""
        raise AssertionError("unexpected call %r" % (argv,))

class World:
    """the Mayor + thies-wa + digo-wa (all idle, with a bridge, clear screen) and a first pass done (offsets at the end of every transcript)"""
    def __init__(self, tc, crews=("thies", "digo"), mayor=True, first=True):
        self.d = tempfile.mkdtemp(prefix="lrr-t-")
        tc.addCleanup(shutil.rmtree, self.d, True)
        self.city, self.home, self.io, self.sess = os.path.join(self.d, "city"), os.path.join(self.d, "home"), FakeIO(), {}
        self.io.engine, self.wake_works = self.engine, True
        for p in ("city/.gc/logs", "city/agents", "home/.claude/sessions", "home/.claude/projects"):
            os.makedirs(os.path.join(self.d, p))
        with open(self.p("city.toml"), "w") as fh:
            fh.write(CITY_TOML)
        self.env = {"GC_CITY_PATH": self.city, "LRR_HOME": self.home, "LRR_ENABLED": "1"}
        if mayor:
            self.mayor()
        for c in crews:
            tmpl, bead, base, name = CREWS[c]
            self.agent(tmpl, "claude-rc-" + c)
            self.session(tmpl, bead, base, name)
        if first:
            self.go()

    def p(self, *a):
        return os.path.join(self.city, *a)

    def agent(self, name, provider, crew=True, mx=1):
        os.makedirs(self.p("agents", name), exist_ok=True)
        with open(self.p("agents", name, "agent.toml"), "w") as fh:
            fh.write('max_active_sessions = %d\nwork_dir = "/x/rig/%s/%s"\nprovider = "%s"\n' % (mx, "crew" if crew else "pool", name.split("-")[0], provider))

    def session(self, tmpl, bead, base, rcname, bridge="session_b", cwd=None, age=5000):
        tname, sid, cpid = "%s-%s" % (tmpl.replace(".", "_"), bead), "%08d-0000-4000-8000-%012d" % (base, base), base + 20
        self.io.roster.append({"id": bead, "template": tmpl, "session_name": tname, "alias": tmpl, "state": "active"})
        self.io.panes[tname] = ("%%%d" % base, base)
        self.io.procs[base] = (1, self.io.t - age, "/bin/sh")
        self.io.procs[cpid] = (base, self.io.t - age + 1, "claude --remote-control %s --model opus --session-id %s" % (rcname, sid) if rcname else "claude --remote-control --model opus")
        cwd = cwd or "/x/rig/crew/%s" % bead
        tdir = os.path.join(self.home, ".claude", "projects", cwd.replace("/", "-").replace(".", "-").replace("_", "-"))
        os.makedirs(tdir, exist_ok=True)
        self.sess[bead] = {"pid": cpid, "base": base, "sid": sid, "cwd": cwd, "tname": tname, "tr": os.path.join(tdir, sid + ".jsonl")}
        self.reg(bead, bridge=bridge)
        self.say(bead, {"type": "user", "message": {"content": "hi"}})

    def row(self, bead):
        return next(r for r in self.io.roster if r["id"] == bead)

    def die(self, bead):
        """what a kill does (measured 13/11, five crews): tmux session and processes gone, the roster says asleep, and nothing brings it back by itself"""
        s = self.sess[bead]
        self.io.panes.pop(s["tname"], None)
        s["dead"] = self.io.procs.pop(s["pid"])
        self.io.procs.pop(s["base"], None)
        self.row(bead)["state"] = "asleep"

    def engine(self, verb, bead):
        if verb == "kill":
            self.die(bead)
        elif self.wake_works:  # `gc session wake` is what brought them back (13/11), as a NEW conversation: the registry names another sessionId
            self.restart(bead)
            self.sess[bead]["sid"] = "f" + self.sess[bead]["sid"][1:]
            self.reg(bead)

    def mayor(self, age=5000):
        self.session("gastown.mayor", M, 200, "Mayor", cwd="/x/.gascity-gastown-hq/.gc/agents/mayor", age=age)

    def reg(self, bead, status="idle", bridge="session_b", raw=None):
        s = self.sess[bead]
        e = {"pid": s["pid"], "sessionId": s["sid"], "kind": "interactive", "cwd": s["cwd"], "tmux": "%s:@1.%%1" % s["tname"], "status": status,
             "startedAt": int(self.io.procs[s["pid"]][1] * 1000)}
        if bridge:
            e["bridgeSessionId"] = bridge
        path = os.path.join(self.home, ".claude", "sessions", "%d.json" % s["pid"])
        with open(path, "w") as fh:
            fh.write(raw if raw is not None else json.dumps(e))
        os.utime(path, (self.io.procs[s["pid"]][1] + 2,) * 2)

    def restart(self, bead, args=None, **kw):
        """the reconciler (or a wake) respawned it: a new claude (new pid, started now) with its launch flag; a dead session gets its tmux session back"""
        s = self.sess[bead]
        old = s.pop("dead", None) or self.io.procs.pop(s["pid"])
        self.io.panes[s["tname"]], self.io.procs[s["base"]] = ("%%%d" % s["base"], s["base"]), (1, self.io.t, "/bin/sh")
        self.row(bead)["state"] = "active"
        s["pid"] += 1000
        self.io.procs[s["pid"]] = (old[0], self.io.t, args or old[2])
        self.reg(bead, **kw)

    def say(self, bead, *entries, at=None):
        ts = datetime.datetime.utcfromtimestamp(self.io.t if at is None else at).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        with open(self.sess[bead]["tr"], "a") as fh:
            fh.write("".join(json.dumps(dict(e, timestamp=ts)) + "\n" for e in entries))

    def go(self, n=1, dry=False, adv=60, **env):
        for _ in range(n):
            self.io.t += adv
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                rc = L.main(["--dry-run"] if dry else [], dict(self.env, **env), self.io)
        return rc, out.getvalue()

    def log(self):
        return self.read(".gc", "logs", "login-rc-restore.log") if os.path.exists(self.p(".gc", "logs", "login-rc-restore.log")) else ""

    def gate(self):
        open(self.p(".gc", "login-rc-restore.mayor-on"), "w").close()

    def login_in_busy_mayor(self):
        """the /login happened in the Mayor, still busy: what follows is the crews' window"""
        self.reg(M, status="busy")
        self.say(M, LOGIN_OUT)

    def read(self, *a):
        with open(self.p(*a)) as fh:
            return fh.read()

    def healed_mayor(self, **kw):
        """/login in the Mayor with the gate on: killed, respawned by the reconciler, and seen back by the next pass"""
        self.gate()
        self.say(M, LOGIN_OUT)
        self.go()
        self.restart(M, **kw)
        self.go()

class Events(unittest.TestCase):
    def test_only_the_structural_shapes_are_events(self):
        for entries, kills, logged in (((LOGIN_CMD, LOGIN_OUT), [T], "EVENT login thies-wa"), ((RC_BARE,), [], "NOTE rc-unnamed thies-wa"),
                                       ((RC_NAMED,), [], None), (QUOTED, [], None)):
            with self.subTest(entries=entries[0]):
                w = World(self)
                w.say(T, *entries)
                rc, out = w.go()
                self.assertEqual((rc, w.io.kills), (0, kills))
                self.assertIn(logged, w.log()) if logged else self.assertNotRegex(w.log(), "EVENT|NOTE")
                if kills:
                    self.assertIn("reiniciou=1", out)
                    w.go(3)
                    self.assertEqual(w.io.kills, kills, "once per event: the wake that brings it back is not a second kill")

    def test_history_before_first_sight_never_triggers(self):
        w = World(self, first=False)
        w.say(T, LOGIN_CMD, LOGIN_OUT, RC_BARE)
        w.go(2)
        self.assertEqual(w.io.kills, [])
        self.assertNotRegex(w.log(), "EVENT|NOTE")

    def test_new_conversation_born_after_last_pass_is_read_from_its_start_but_not_its_copied_history(self):
        for back, kills in ((0, [M]), (3600, [])):  # 3600: a resume that copied old turns into a new file
            with self.subTest(back=back):
                w = World(self, mayor=False)
                w.io.t += 30
                w.mayor(age=10)  # started 20 s after the last pass
                w.say(M, LOGIN_OUT, at=w.io.t - back)
                w.gate()
                w.go(adv=1)
                self.assertEqual(w.io.kills, kills)

class Kills(unittest.TestCase):
    def setUp(self):
        self.w = World(self)

    def test_busy_is_never_killed_then_killed_when_idle(self):
        w = self.w
        w.reg(T, status="busy")
        w.say(T, LOGIN_OUT)
        w.io.screens["%100"] = STUCK
        w.go(3)
        self.assertEqual(w.io.kills, [])
        w.reg(T, status="idle")
        w.go()
        self.assertEqual(w.io.kills, [T])

    def test_stuck_crew_killed_at_once_in_window_not_outside(self):
        for adv, kills in ((60, [D]), (1801, [])):
            with self.subTest(adv=adv):
                w = World(self)
                w.login_in_busy_mayor()
                w.reg(D, status="waiting")
                w.go()
                self.assertEqual(w.io.kills, [])
                w.io.screens["%300"] = STUCK
                w.go(adv=adv)
                self.assertEqual(w.io.kills, kills, "login/limit screen + not busy = kill now, only within the 30-min window")

    def test_crew_without_bridge_killed_when_idle_in_window_never_its_new_process(self):
        w = self.w
        w.login_in_busy_mayor()
        w.reg(T, status="busy", bridge=None)
        w.go()
        self.assertEqual(w.io.kills, [])
        w.reg(T, bridge=None)
        w.go()
        self.assertEqual(w.io.kills, [T])
        w.restart(T, bridge=None)
        w.go()
        self.assertEqual(w.io.kills, [T], "a process born after the event is never killed for it")

    def test_pool_worker_is_out_of_scope(self):
        w = World(self, crews=(), mayor=False, first=False)
        w.agent("wa-worker", "claude-headless", crew=False, mx=4)
        w.session("wa-worker", "ga-wisp-pool", 400, None, bridge=None)
        w.go()
        w.say("ga-wisp-pool", LOGIN_OUT)
        rc, out = w.go()
        self.assertEqual((w.io.kills, "alvos=0" in out), ([], True))

    def test_bare_remote_control_opens_no_window_for_the_other_crews_and_rings_nothing(self):
        w = World(self)
        w.reg(D, bridge=None)  # idle, no bridge: inside an open window it would be restarted
        w.say(T, RC_BARE)
        w.go(3)
        self.assertEqual((w.io.kills, w.io.wakes), ([], []))
        w.go(adv=1300)
        self.assertEqual(w.io.notes, [], "the name of the Remote Control is cosmetic: not even an alarm 20 min later")

    def test_mayor_gate_off_logs_would_and_gate_on_kills(self):
        w = self.w
        w.say(M, LOGIN_OUT)
        rc, out = w.go()
        self.assertEqual((w.io.kills, "WOULD restart mayor (gate off)" in w.log(), "mayor-gate-off=1" in out), ([], True, True))
        w.go()
        self.assertEqual(w.log().count("WOULD restart mayor"), 1, "logged once per event")
        w.gate()
        w.go()
        self.assertEqual(w.io.kills, [M])

    def test_unknown_reads_never_kill(self):
        w = self.w
        w.gate()
        w.login_in_busy_mayor()
        w.reg(T, bridge=None)
        w.go(3)  # the event is recorded, thies (idle, no bridge) killed, woken and seen back: the window is open and nothing is in flight
        self.assertEqual((w.io.kills, w.io.wakes), ([T], [T]))
        w.io.kills.clear()
        w.reg(D, bridge=None)
        w.io.screens["%300"] = STUCK
        for fail in ({"tmux": (None, "", "")}, {"ps": (None, "", "")}, {"tmux": (1, "", "no server running on /tmp/x")}, {"gc": (None, "", "")}):
            w.io.fail = fail
            w.go()
        w.io.fail = {}
        w.reg(D, raw="{not json")
        w.go()
        self.assertEqual(w.io.kills, [], "tmux/ps/gc failures and an unreadable registry are unknown: no kill")
        self.assertIn("UNKNOWN", w.log())

    def test_unreadable_or_quoting_screen_is_not_stuck(self):
        for fail, screen in (({"tmux:capture-pane": (None, "", "")}, CLEAR), ({}, "● the crew said it saw Please run /login on screen\n────\n❯ \n────\n")):
            with self.subTest(screen=screen, fail=fail):
                w = World(self)
                w.login_in_busy_mayor()
                w.reg(D, status="waiting")
                w.io.fail, w.io.screens["%300"] = fail, screen
                w.go()
                self.assertEqual(w.io.kills, [])

class Alarm(unittest.TestCase):
    def setUp(self):
        self.w = World(self, crews=("thies",))

    def test_alarm_once_at_20_min_lists_what_is_still_wrong(self):
        w = self.w
        w.say(M, LOGIN_OUT)  # gate off: the Mayor stays the process that had the event
        w.go(19)
        self.assertEqual(w.io.notes, [])
        w.go(adv=120)
        self.assertEqual(len(w.io.notes), 1)
        argv, env = w.io.notes[0]
        self.assertEqual((argv[1:3], env), (["-p", "4"], {"NOTIFY_STRICT_EXIT": "1", "NOTIFY_FORCE_PUSH": "1"}))
        self.assertIn("mayor: não reiniciou depois do /login (gate do Mayor desligado)", argv[-1])
        self.assertNotIn("thies-wa", argv[-1])
        w.go(5)
        self.assertEqual(len(w.io.notes), 1, "one alarm per event")

    def test_silence_when_healthy(self):
        w = self.w
        w.healed_mayor()
        self.assertEqual(w.io.kills, [M])
        w.go(25)
        self.assertEqual((w.io.notes, "ALL OK" in w.log()), ([], True))

    def test_wrong_name_and_missing_claude_are_reported(self):
        w = self.w
        w.healed_mayor(args="claude --remote-control --model opus")
        del w.io.panes[w.sess[T]["tname"]]
        w.go(adv=1300)
        self.assertIn("mayor: nome do RC não é Mayor; thies-wa: sem claude vivo", w.io.notes[0][0][-1])

    def test_unreadable_tmux_defers_the_alarm_instead_of_reporting_absent(self):
        w = self.w
        w.healed_mayor()
        w.io.fail = {"tmux": (1, "", "no server running on /private/tmp/tmux-501/gascity")}
        w.go(adv=1300)
        self.assertEqual((w.io.notes, "ALARM deferred" in w.log(), "ALL OK" in w.log()), ([], True, False))
        w.io.fail = {}
        w.go()
        self.assertEqual((w.io.notes, "ALL OK" in w.log()), ([], True))

    def test_undelivered_alarm_is_retried_not_marked(self):
        w = self.w
        w.say(M, LOGIN_OUT)
        w.go()
        w.io.notify_rc = 12
        w.go(adv=1300)
        w.go()
        self.assertEqual(len(w.io.notes), 1, "retry waits 10 min")
        w.io.notify_rc = 0
        w.go(adv=600)
        w.go(adv=600)
        self.assertEqual(len(w.io.notes), 2)

class Restore(unittest.TestCase):
    """a kill is not trusted to be undone: the engine leaves a killed session asleep and nobody wakes it (13/11: five crews, runtime-missing)"""
    def test_a_killed_session_left_asleep_is_woken_then_confirmed_back(self):
        w = World(self)
        w.say(T, LOGIN_OUT)
        w.go()
        self.assertEqual((w.io.kills, w.io.wakes, w.row(T)["state"]), ([T], [], "asleep"))
        rc, out = w.go()
        self.assertEqual(([c for c in w.io.calls if "wake" in c], "acordou=1 pendentes=1" in out), ([["gc", "--city", w.city, "session", "wake", T]], True))
        rc, out = w.go()
        self.assertIn("RESTORED thies-wa (ga-thies) 120 s after the kill, conversation 00000100 -> f0000100", w.log())
        self.assertEqual((w.row(T)["state"], "acordou=0 pendentes=0" in out), ("active", True))
        w.go(30)
        self.assertEqual((w.io.kills, w.io.wakes, w.io.notes), ([T], [T], []))

    def test_one_restart_in_flight_at_a_time_the_next_waits_until_it_is_back(self):
        w = World(self)
        w.login_in_busy_mayor()
        w.reg(T, bridge=None)
        w.reg(D, bridge=None)
        w.go()
        self.assertEqual(w.io.kills, [D], "digo-wa sorts first: killing both at once is what stranded five crews")
        self.assertIn("HOLD kill thies-wa (ga-thies)", w.log())
        self.assertIn("the restart of digo-wa (0 s ago) is not confirmed back yet", w.log())
        w.go()
        self.assertEqual((w.io.kills, w.io.wakes), ([D], [D]))
        w.go()
        self.assertEqual((w.io.kills, w.io.wakes), ([D, T], [D]))
        self.assertEqual(w.log().count("HOLD kill thies-wa"), 1, "said once, not on every pass")

    def test_a_restart_that_never_comes_back_rings_once_holds_the_rest_and_is_never_all_ok(self):
        w = World(self)
        w.wake_works = False
        w.login_in_busy_mayor()
        w.reg(T, bridge=None)
        w.reg(D, bridge=None)
        w.go(10)  # the kill at pass 1; wake requests 60, 240 and 420 s later; the 600 s deadline is not reached yet
        self.assertEqual((w.io.kills, w.io.wakes, w.io.notes), ([D], [D, D, D], []))
        w.go()  # 600 s after the kill
        self.assertEqual((len(w.io.wakes), len(w.io.notes)), (4, 1))
        for said in ("digo-wa", "NÃO voltou", "dormindo (asleep)", "gc session wake ga-digo"):
            self.assertIn(said, w.io.notes[0][0][-1])
        w.go(9)
        self.assertEqual((w.io.kills, len(w.io.wakes), len(w.io.notes), w.log().count("HOLD kill thies-wa")), ([D], 4, 1, 1))
        w.go(2)  # 20 min after the event: the report lists the dead one instead of saying everything is fine
        self.assertIn("digo-wa: reiniciada e ainda não voltou", w.io.notes[1][0][-1])
        self.assertNotIn("ALL OK", w.log())

    def test_a_wake_that_fails_is_retried_later_and_never_more_than_four_times(self):
        w = World(self, crews=("thies",))
        w.io.fail = {"gc:wake": (1, "", "boom")}
        w.say(T, LOGIN_OUT)
        w.go(31)
        self.assertEqual([c for c in w.io.calls if "wake" in c], [["gc", "--city", w.city, "session", "wake", T]] * 4)
        self.assertIn("FAILED wake thies-wa", w.log())

    def test_a_kill_that_gave_no_answer_may_have_happened_so_it_is_followed_up_like_one(self):
        w = World(self, crews=("thies",))
        w.io.fail = {"gc:kill": (None, "", "")}  # `gc session kill` timed out under load...
        w.say(T, LOGIN_OUT)
        w.go()
        self.assertIn("FAILED kill thies-wa", w.log())
        w.io.fail = {}
        w.die(T)  # ...and the supervisor did it anyway
        w.go()
        self.assertEqual(w.io.wakes, [T])

    def test_a_respawn_that_beat_a_slow_kill_back_to_its_caller_is_still_a_restored_session(self):
        w = World(self, crews=("thies",))

        def slow(verb, bead):  # the kill takes 30 s to return and the engine started the session again 10 s in
            w.die(bead)
            w.io.t += 10
            w.restart(bead)
            w.io.t += 20
        w.io.engine = slow
        w.say(T, LOGIN_OUT)
        w.go(2)
        self.assertIn("RESTORED thies-wa", w.log())
        w.go(adv=700)
        self.assertEqual(w.io.notes, [], "no false alarm that the old process lives on")

    def test_a_kill_that_failed_outright_is_not_a_restart_in_flight_and_is_retried(self):
        w = World(self, crews=("thies",))
        w.io.fail = {"gc:kill": (1, "", "no such session")}
        w.say(T, LOGIN_OUT)
        w.go()
        w.io.fail = {}
        w.go()
        self.assertEqual((w.io.kills, w.io.wakes), ([T], []))

    def test_unreadable_roster_wakes_nothing_but_the_deadline_alarm_still_rings(self):
        w = World(self, crews=("thies",))
        w.say(T, LOGIN_OUT)
        w.go()
        w.io.fail = {"gc": (None, "", "")}
        rc, out = w.go(adv=700)
        self.assertEqual((rc, w.io.wakes, len(w.io.notes)), (3, [], 1))
        self.assertIn("lista de sessões", w.io.notes[0][0][-1])
        w.go()
        self.assertEqual(len(w.io.notes), 1, "rang once: the mark is kept even when the pass could not evaluate")
        w.io.fail = {}
        w.go()
        self.assertEqual(w.io.wakes, [T])

    def test_the_alarm_says_where_the_restart_is_stuck(self):
        quiet = lambda w: setattr(w.io, "engine", lambda verb, bead: None)  # the kill changed nothing: the old claude lives on
        for pre, post, said in ((None, None, "dormindo (asleep)"), (None, lambda w: w.row(T).update(state="creating"), "ainda subindo (creating)"),
                                (None, lambda w: w.io.roster.remove(w.row(T)), "fora da lista de sessões"), (None, lambda w: w.row(T).update(state="drained"), "estado drained"),
                                (None, lambda w: w.row(T).update(state="active"), "ativa na lista mas sem claude vivo"), (None, lambda w: w.row(T).update(state="active", template="wa-worker"), "ativa na lista mas fora dos alvos"),
                                (quiet, None, "o processo antigo segue vivo"),
                                (quiet, lambda w: setattr(w.io, "fail", {"tmux": (None, "", "")}), "não consegui ler (tmux did not answer)"),
                                (None, lambda w: setattr(w.io, "fail", {"gc": (None, "", "")}), "lista de sessões")):
            with self.subTest(said=said):
                w = World(self, crews=("thies",))
                w.wake_works = False
                (pre or (lambda w: None))(w)
                w.say(T, LOGIN_OUT)
                w.go()
                (post or (lambda w: None))(w)
                w.go(adv=700)
                self.assertEqual(len(w.io.notes), 1)
                self.assertIn(said, w.io.notes[0][0][-1])
                self.assertNotIn("RESTORED thies-wa", w.log())
                self.assertEqual(bool(w.io.wakes), said == "dormindo (asleep)", "only a session the roster calls asleep is asked to wake")

    def test_undelivered_restart_alarm_is_retried_after_ten_minutes_not_marked(self):
        w = World(self, crews=("thies",))
        w.env.update(LRR_RESTORE_S="120", LRR_ALARM_S="99999")  # the 20-min report of the event is out of this picture
        w.wake_works = False
        w.say(T, LOGIN_OUT)
        w.go()
        w.io.notify_rc = 12
        w.go(adv=120)
        w.go()
        self.assertEqual(len(w.io.notes), 1, "retry waits 10 min")
        self.assertIn("NOT delivered (notify rc=12), retried in 10 min", w.log())
        w.io.notify_rc = 0
        w.go(adv=600)
        self.assertEqual(len(w.io.notes), 2)
        w.go(adv=700)
        self.assertEqual(len(w.io.notes), 2, "once delivered, it does not ring again")

    def test_an_unconfirmed_restart_holds_the_next_kill_for_an_hour_then_is_forgotten(self):
        w = World(self)
        w.wake_works = False
        w.say(T, LOGIN_OUT)
        w.go()
        w.say(D, LOGIN_OUT)  # a second event while thies-wa is still unconfirmed
        w.go(adv=3000)
        self.assertEqual(w.io.kills, [T])
        self.assertNotIn("GAVE UP", w.log())
        w.go(adv=700)  # 3700 s after the kill
        self.assertIn("GAVE UP thies-wa", w.log())
        self.assertEqual(w.io.kills, [T, D])

    def test_a_restart_record_that_is_not_what_this_job_wrote_is_dropped_not_trusted(self):
        w = World(self, crews=("thies",))
        state = json.loads(w.read(".gc", "login-rc-restore.state.json"))
        state["pending"] = {T: {"ts": "yesterday", "wakes": 0, "wake_at": 0}, "ga-digo": {"alias": "digo-wa", "wakes": 0, "wake_at": 0}, "ga-x": "{not json"}
        with open(w.p(".gc", "login-rc-restore.state.json"), "w") as fh:
            json.dump(state, fh)
        w.say(T, LOGIN_OUT)
        rc, out = w.go()
        self.assertEqual((rc, w.io.kills, "pendentes=1" in out), (0, [T], True))

    def test_a_kill_that_changed_nothing_is_not_repeated_for_the_same_event_when_the_hold_ends(self):
        w = World(self, crews=("thies",))
        w.io.engine = lambda verb, bead: None  # the old claude lives on: idle, and still the process that had the event
        w.say(T, LOGIN_OUT)
        w.go()
        w.go(adv=3700)
        self.assertIn("GAVE UP thies-wa", w.log())
        self.assertEqual(w.io.kills, [T], "once per event")

    def test_a_pass_that_could_not_evaluate_leaves_a_state_file_with_nothing_in_flight_alone(self):
        w = World(self, crews=("thies",))
        state = json.loads(w.read(".gc", "login-rc-restore.state.json"))
        state.pop("pending", None)  # as the version before this one wrote it
        with open(w.p(".gc", "login-rc-restore.state.json"), "w") as fh:
            json.dump(state, fh, sort_keys=True)
        before = w.read(".gc", "login-rc-restore.state.json")
        w.io.fail = {"gc": (None, "", "")}
        rc, out = w.go()
        self.assertEqual((rc, w.read(".gc", "login-rc-restore.state.json")), (3, before))

    def test_dry_run_rings_nothing_for_a_restart_past_its_deadline(self):
        w = World(self, crews=("thies",))
        w.wake_works = False
        w.say(T, LOGIN_OUT)
        w.go()
        rc, out = w.go(adv=700, dry=True)
        self.assertEqual((w.io.notes, "WOULD notify: thies-wa foi reiniciada" in out), ([], True))

    def test_a_stored_rc_unnamed_event_of_the_old_version_restarts_nothing(self):
        w = World(self, crews=("thies",))
        state, pid = json.loads(w.read(".gc", "login-rc-restore.state.json")), w.sess[T]["pid"]
        state["events"] = [{"id": "old:1", "bead": T, "alias": "thies-wa", "kind": "rc-unnamed", "ts": w.io.t, "pid": pid, "start": w.io.procs[pid][1]}]
        with open(w.p(".gc", "login-rc-restore.state.json"), "w") as fh:
            json.dump(state, fh)
        w.go(3)
        self.assertEqual(w.io.kills, [])

    def test_dry_run_holds_the_second_target_like_a_real_run(self):
        w = World(self)
        w.login_in_busy_mayor()
        w.reg(T, bridge=None)
        w.reg(D, bridge=None)
        rc, out = w.go(dry=True)
        self.assertEqual(("WOULD kill digo-wa" in out, "HOLD kill thies-wa" in out, "WOULD kill thies-wa" in out), (True, True, False))

    def test_dry_run_with_a_restart_pending_asks_for_no_wake_and_writes_nothing(self):
        w = World(self, crews=("thies",))
        w.say(T, LOGIN_OUT)
        w.go()
        before = w.read(".gc", "login-rc-restore.state.json")
        rc, out = w.go(dry=True)
        self.assertEqual((w.io.wakes, "WOULD wake thies-wa" in out, w.read(".gc", "login-rc-restore.state.json")), ([], True, before))

class Switches(unittest.TestCase):
    def test_kill_switch_does_nothing(self):
        w = World(self, crews=("thies",))
        open(w.p(".gc", "login-rc-restore.off"), "w").close()
        w.say(T, LOGIN_OUT)
        n = len(w.io.calls)
        rc, out = w.go()
        self.assertEqual((rc, w.io.kills, len(w.io.calls)), (0, [], n), "switched off: not even gc is asked")
        self.assertIn("desligado", out)
        os.remove(w.p(".gc", "login-rc-restore.off"))
        w.go(LRR_ENABLED="0")
        self.assertEqual(len(w.io.calls), n)

    def test_dry_run_kills_nothing_writes_nothing(self):
        w = World(self, crews=("thies",), first=False)
        w.go(dry=True)
        self.assertEqual((sorted(os.listdir(w.p(".gc"))), os.listdir(w.p(".gc", "logs"))), (["logs"], []))
        w.go()
        w.say(T, LOGIN_OUT)
        before = w.read(".gc", "login-rc-restore.state.json")
        rc, out = w.go(dry=True)
        self.assertEqual((w.io.kills, "WOULD kill thies-wa" in out, "(dry-run)" in out), ([], True, True))
        self.assertEqual(w.read(".gc", "login-rc-restore.state.json"), before)

    def test_usage(self):
        w = World(self, crews=(), mayor=False, first=False)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(L.main(["--bogus"], w.env, w.io), 2)

if __name__ == "__main__":
    unittest.main()
