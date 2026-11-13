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
        self.roster, self.panes, self.procs, self.screens, self.kills, self.notes = [], {}, {}, {}, [], []

    def now(self):
        return self.t

    def run(self, argv, timeout, env=None):
        self.calls.append(list(argv))
        tool = os.path.basename(argv[0])
        verb = "kill" if "kill" in argv else "capture-pane" if "capture-pane" in argv else ""
        f = self.fail.get(tool + ":" + verb, self.fail.get(tool, False))
        if f is not False:
            return f
        if tool == "gc":
            return (self.kills.append(argv[-1]) or (0, "", "")) if verb else (0, json.dumps({"sessions": self.roster}), "")
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
        self.sess[bead] = {"pid": cpid, "sid": sid, "cwd": cwd, "tname": tname, "tr": os.path.join(tdir, sid + ".jsonl")}
        self.reg(bead, bridge=bridge)
        self.say(bead, {"type": "user", "message": {"content": "hi"}})

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
        """the reconciler respawned it: a new claude (new pid, started now) with its launch flag"""
        s = self.sess[bead]
        old = self.io.procs.pop(s["pid"])
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
        """/login in the Mayor with the gate on: killed, then respawned by the reconciler"""
        self.gate()
        self.say(M, LOGIN_OUT)
        self.go()
        self.restart(M, **kw)

class Events(unittest.TestCase):
    def test_only_the_structural_shapes_are_events(self):
        for entries, kills, logged in (((LOGIN_CMD, LOGIN_OUT), [T], "EVENT login thies-wa"), ((RC_BARE,), [T], "EVENT rc-unnamed thies-wa"),
                                       ((RC_NAMED,), [], None), (QUOTED, [], None)):
            with self.subTest(entries=entries[0]):
                w = World(self)
                w.say(T, *entries)
                rc, out = w.go()
                self.assertEqual((rc, w.io.kills), (0, kills))
                self.assertIn(logged, w.log()) if logged else self.assertNotIn("EVENT", w.log())
                if kills:
                    self.assertIn("reiniciou=1", out)
                    w.go(2)
                    self.assertEqual(w.io.kills, kills, "once per event, even while the reconciler has not respawned it yet")

    def test_history_before_first_sight_never_triggers(self):
        w = World(self, first=False)
        w.say(T, LOGIN_CMD, LOGIN_OUT, RC_BARE)
        w.go(2)
        self.assertEqual(w.io.kills, [])
        self.assertNotIn("EVENT", w.log())

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
        w.go()  # the event is recorded and thies (idle, no bridge) killed: the window is open
        self.assertEqual(w.io.kills, [T])
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
        self.assertEqual((argv[1:3], env.get("NOTIFY_STRICT_EXIT")), (["-p", "4"], "1"))
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
