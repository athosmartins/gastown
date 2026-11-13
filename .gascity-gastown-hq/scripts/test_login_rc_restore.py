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
base = "builtin:claude"
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
STUCK = "some output\n\n  What do you want to do?\n  ❯ 1. Stop and wait for limit to reset\n    2. Upgrade\n Enter to confirm · Esc to cancel\n"
CLEAR = "● done\n────────────────\n❯ \n────────────────\n  opus · ctx 12%\n"


class FakeIO:
    def __init__(self):
        self.t, self.calls, self.fail = NOW, [], {}
        self.roster, self.panes, self.procs, self.screens, self.kills, self.notes = [], {}, {}, {}, [], []
        self.notify_rc = 0

    def now(self):
        return self.t

    def run(self, argv, timeout, env=None):
        self.calls.append(list(argv))
        tool = os.path.basename(argv[0])
        verb = "kill" if "kill" in argv else "capture-pane" if "capture-pane" in argv else ""
        f = self.fail.get(tool + ":" + verb, self.fail.get(tool, False))
        if f is not False:
            return f
        if tool == "gc" and verb == "kill":
            self.kills.append(argv[-1])
            return 0, "", ""
        if tool == "gc":
            return 0, json.dumps({"sessions": self.roster}), ""
        if tool == "ps":
            return 0, "".join("%d %d %02d:%02d:%02d %s\n" % (p, pp, (self.t - st) // 3600, (self.t - st) % 3600 // 60, (self.t - st) % 60, args)
                              for p, (pp, st, args) in sorted(self.procs.items())), ""
        if tool == "tmux" and verb == "capture-pane":
            pane = argv[argv.index("-t") + 1]
            return 0, self.screens.get(pane, CLEAR), ""
        if tool == "tmux":
            name = next(a for a in argv if a.startswith("="))[1:-1]
            return (0, "%s %d\n" % self.panes[name], "") if name in self.panes else (1, "", "can't find session: %s\n" % name)
        if tool == "notify":
            self.notes.append((argv, env))
            return self.notify_rc, "", ""
        raise AssertionError("unexpected call %r" % (argv,))


class World:
    def __init__(self, tc):
        self.d = tempfile.mkdtemp(prefix="lrr-t-")
        tc.addCleanup(shutil.rmtree, self.d, True)
        self.city, self.home, self.io = os.path.join(self.d, "city"), os.path.join(self.d, "home"), FakeIO()
        for p in ("city/.gc/logs", "city/agents", "home/.claude/sessions", "home/.claude/projects"):
            os.makedirs(os.path.join(self.d, p))
        with open(self.p("city.toml"), "w") as fh:
            fh.write(CITY_TOML)
        self.env = {"GC_CITY_PATH": self.city, "LRR_HOME": self.home, "LRR_ENABLED": "1"}
        self.sess = {}

    def p(self, *a):
        return os.path.join(self.city, *a)

    def agent(self, name, provider, crew=True, mx=1):
        os.makedirs(self.p("agents", name), exist_ok=True)
        with open(self.p("agents", name, "agent.toml"), "w") as fh:
            fh.write('max_active_sessions = %d\nwork_dir = "/x/rig/%s/%s"\nprovider = "%s"\n' % (mx, "crew" if crew else "pool", name.split("-")[0], provider))

    def session(self, tmpl, bead, base, sid, rcname, status="idle", bridge="session_b", cwd=None, state="active", age=5000):
        tname = "%s-%s" % (tmpl.replace(".", "_"), bead)
        self.io.roster.append({"id": bead, "template": tmpl, "session_name": tname, "alias": tmpl, "state": state})
        self.io.panes[tname] = ("%%%d" % base, base)
        cpid = base + 20
        self.io.procs[base] = (1, self.io.t - age, "/bin/sh")
        self.io.procs[cpid] = (base, self.io.t - age + 1, "claude --remote-control %s --model opus --session-id %s" % (rcname, sid) if rcname else "claude --remote-control --model opus")
        cwd = cwd or "/x/rig/crew/%s" % bead
        self.sess[bead] = {"pid": cpid, "sid": sid, "cwd": cwd, "tname": tname}
        self.reg(bead, status=status, bridge=bridge)
        tdir = os.path.join(self.home, ".claude", "projects", cwd.replace("/", "-").replace(".", "-").replace("_", "-"))
        os.makedirs(tdir, exist_ok=True)
        self.sess[bead]["tr"] = os.path.join(tdir, sid + ".jsonl")
        with open(self.sess[bead]["tr"], "a") as fh:
            fh.write(json.dumps({"type": "user", "message": {"content": "hi"}}) + "\n")
        return cpid

    def reg(self, bead, status="idle", bridge="session_b", raw=None):
        s = self.sess[bead]
        e = {"pid": s["pid"], "sessionId": s["sid"], "kind": "interactive", "cwd": s["cwd"], "tmux": "%s:@1.%%1" % s["tname"], "status": status,
             "startedAt": int(self.io.procs[s["pid"]][1] * 1000)}
        if bridge:
            e["bridgeSessionId"] = bridge
        path = os.path.join(self.home, ".claude", "sessions", "%d.json" % s["pid"])
        with open(path, "w") as fh:
            fh.write(raw if raw is not None else json.dumps(e))
        t = self.io.procs[s["pid"]][1] + 2
        os.utime(path, (t, t))

    def restart(self, bead, base_shift=1000, status="idle"):
        """the reconciler respawned it: a new claude (new pid, started now) with its launch flag"""
        s = self.sess[bead]
        old = self.io.procs.pop(s["pid"])
        s["pid"] = s["pid"] + base_shift
        self.io.procs[s["pid"]] = (old[0], self.io.t, old[2])
        self.reg(bead, status=status)

    def say(self, bead, *entries, at=None):
        ts = datetime.datetime.utcfromtimestamp(self.io.t if at is None else at).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        with open(self.sess[bead]["tr"], "a") as fh:
            for e in entries:
                fh.write(json.dumps(dict(e, timestamp=ts)) + "\n")

    def crew(self, tmpl="thies-wa", bead="ga-thies", base=100, sid="00000001-0000-4000-8000-000000000001", provider="claude-rc-thies", name="Thies", **kw):
        self.agent(tmpl, provider)
        return self.session(tmpl, bead, base, sid, name, **kw)

    def mayor(self, bead="gh-mayor", base=200, sid="00000002-0000-4000-8000-000000000002", **kw):
        return self.session("gastown.mayor", bead, base, sid, "Mayor", cwd="/x/.gascity-gastown-hq/.gc/agents/mayor", **kw)

    def go(self, dry=False, adv=60, **env):
        self.io.t += adv
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            rc = L.main(["--dry-run"] if dry else [], dict(self.env, **env), self.io)
        return rc, out.getvalue()

    def log(self):
        try:
            with open(self.p(".gc", "logs", "login-rc-restore.log")) as fh:
                return fh.read()
        except FileNotFoundError:
            return ""

    def gate(self, on=True):
        path = self.p(".gc", "login-rc-restore.mayor-on")
        if on:
            open(path, "w").close()
        elif os.path.exists(path):
            os.remove(path)


class Events(unittest.TestCase):
    def setUp(self):
        self.w = World(self)
        self.w.crew()
        self.w.go()  # first sight: offsets at the end of every transcript

    def test_login_stdout_is_an_event_and_kills_the_idle_session_once(self):
        self.w.say("ga-thies", LOGIN_CMD, LOGIN_OUT)
        rc, out = self.w.go()
        self.assertEqual(rc, 0)
        self.assertEqual(self.w.io.kills, ["ga-thies"])
        self.assertIn("EVENT login thies-wa", self.w.log())
        self.assertIn("reiniciou=1", out)
        self.w.go()
        self.w.go()
        self.assertEqual(self.w.io.kills, ["ga-thies"], "once per event, even while the reconciler has not respawned it yet")

    def test_unnamed_remote_control_is_an_event_named_one_is_not(self):
        self.w.say("ga-thies", RC_NAMED)
        self.w.go()
        self.assertEqual(self.w.io.kills, [])
        self.w.say("ga-thies", RC_BARE)
        self.w.go()
        self.assertEqual(self.w.io.kills, ["ga-thies"])
        self.assertIn("EVENT rc-unnamed", self.w.log())

    def test_quoted_phrases_in_tool_use_tool_result_and_blobs_never_trigger(self):
        q = LOGIN_OUT["message"]["content"] + " " + RC_BARE["content"]
        self.w.say("ga-thies",
                   {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": "grep '%s' x" % q}}]}},
                   {"type": "user", "message": {"content": [{"type": "tool_result", "content": q}]}},
                   {"type": "api-request-blob", "messages": [{"content": q}]},
                   {"type": "user", "message": {"content": "o Athos colou: " + q}},
                   {"type": "assistant", "message": {"content": q}})
        self.w.go()
        self.assertEqual(self.w.io.kills, [])
        self.assertNotIn("EVENT", self.w.log())

    def test_history_before_first_sight_never_triggers(self):
        w = World(self)
        w.crew()
        w.say("ga-thies", LOGIN_CMD, LOGIN_OUT, RC_BARE)
        w.go()
        w.go()
        self.assertEqual(w.io.kills, [])
        self.assertNotIn("EVENT", w.log())

    def test_new_conversation_born_after_last_pass_is_read_from_its_start(self):
        w = self.w
        w.io.t += 30
        w.mayor(age=10)  # started 10 s ago, 20 s after the last pass
        w.say("gh-mayor", LOGIN_OUT)
        w.gate()
        w.go(adv=1)
        self.assertEqual(w.io.kills, ["gh-mayor"])

    def test_new_conversation_with_copied_history_older_than_its_process_does_not_trigger(self):
        w = self.w
        w.io.t += 30
        w.mayor(age=10)
        w.say("gh-mayor", LOGIN_OUT, at=w.io.t - 3600)  # e.g. a resume that copies the old turns into a new file
        w.gate()
        w.go(adv=1)
        self.assertEqual(w.io.kills, [])


class Kills(unittest.TestCase):
    def setUp(self):
        self.w = World(self)
        self.w.mayor()
        self.w.crew()
        self.w.crew("digo-wa", "ga-digo", 300, "00000003-0000-4000-8000-000000000003", "claude-rc-digo", "Digo")
        self.w.go()

    def test_busy_is_never_killed_then_killed_when_idle(self):
        w = self.w
        w.reg("ga-thies", status="busy")
        w.say("ga-thies", LOGIN_OUT)
        w.io.screens["%120"] = STUCK
        for _ in range(3):
            w.go()
        self.assertEqual(w.io.kills, [])
        w.reg("ga-thies", status="idle")
        w.go()
        self.assertEqual(w.io.kills, ["ga-thies"])

    def test_stuck_crew_killed_at_once_in_window_not_outside(self):
        w = self.w
        w.gate()
        w.say("gh-mayor", LOGIN_OUT)
        w.reg("gh-mayor", status="busy")
        w.reg("ga-digo", status="waiting")
        w.go()
        self.assertEqual(w.io.kills, [])
        w.io.screens["%300"] = STUCK
        w.go()
        self.assertEqual(w.io.kills, ["ga-digo"], "login/limit screen + not busy = kill now")
        w2 = World(self)
        w2.mayor()
        w2.crew("digo-wa", "ga-digo", 300, "00000003-0000-4000-8000-000000000003", "claude-rc-digo", "Digo", status="waiting")
        w2.go()
        w2.say("gh-mayor", LOGIN_OUT)
        w2.reg("gh-mayor", status="busy")
        w2.go()
        w2.io.screens["%300"] = STUCK
        w2.go(adv=1801)
        self.assertEqual(w2.io.kills, [], "outside the 30-min window a stuck screen is not this job's")

    def test_crew_without_bridge_killed_when_idle_in_window(self):
        w = self.w
        w.reg("gh-mayor", status="busy")
        w.say("gh-mayor", LOGIN_OUT)
        w.reg("ga-thies", status="busy", bridge=None)
        w.go()
        self.assertEqual(w.io.kills, [])
        w.reg("ga-thies", status="idle", bridge=None)
        w.go()
        self.assertEqual(w.io.kills, ["ga-thies"])
        w.restart("ga-thies")
        w.reg("ga-thies", status="idle", bridge=None)
        w.go()
        self.assertEqual(w.io.kills, ["ga-thies"], "a process born after the event is never killed for it")

    def test_pool_worker_is_out_of_scope(self):
        w = World(self)
        w.agent("wa-worker", "claude-headless", crew=False, mx=4)
        w.session("wa-worker", "ga-wisp-pool", 400, "00000004-0000-4000-8000-000000000004", None, bridge=None)
        w.go()
        w.say("ga-wisp-pool", LOGIN_OUT)
        rc, out = w.go()
        self.assertEqual(w.io.kills, [])
        self.assertIn("alvos=0", out)

    def test_mayor_gate_off_logs_would_and_gate_on_kills(self):
        w = self.w
        w.say("gh-mayor", LOGIN_OUT)
        rc, out = w.go()
        self.assertEqual(w.io.kills, [])
        self.assertIn("WOULD restart mayor (gate off)", w.log())
        self.assertIn("mayor-gate-off=1", out)
        w.go()
        self.assertEqual(w.log().count("WOULD restart mayor"), 1, "logged once per event")
        w.gate()
        w.go()
        self.assertEqual(w.io.kills, ["gh-mayor"])

    def test_unknown_reads_never_kill(self):
        w = self.w
        w.gate()
        w.say("gh-mayor", LOGIN_OUT)
        w.reg("gh-mayor", status="busy")
        w.reg("ga-thies", bridge=None)
        w.go()  # the event is recorded; ga-thies (idle, no bridge) would be killed...
        self.assertEqual(w.io.kills, ["ga-thies"])
        w.io.kills.clear()
        w.reg("ga-digo", bridge=None)
        w.io.screens["%300"] = STUCK
        for fail in ({"tmux": (None, "", "")}, {"ps": (None, "", "")}, {"tmux": (1, "", "no server running on /tmp/x")}, {"gc": (None, "", "")}):
            w.io.fail = fail
            w.go()
        w.io.fail = {}
        w.reg("ga-digo", raw="{not json")
        w.go()
        self.assertEqual(w.io.kills, [], "tmux/ps/gc failures and an unreadable registry are unknown: no kill")
        self.assertIn("UNKNOWN", w.log())

    def test_capture_pane_failure_is_not_a_stuck_screen(self):
        w = self.w
        w.reg("gh-mayor", status="busy")
        w.say("gh-mayor", LOGIN_OUT)
        w.reg("ga-digo", status="waiting")
        w.io.fail = {"tmux:capture-pane": (None, "", "")}
        w.go()
        self.assertEqual(w.io.kills, [])

    def test_screen_text_quoting_the_message_mid_sentence_is_not_stuck(self):
        w = self.w
        w.reg("gh-mayor", status="busy")
        w.say("gh-mayor", LOGIN_OUT)
        w.reg("ga-digo", status="waiting")
        w.io.screens["%300"] = "● the crew said it saw Please run /login on screen\n────\n❯ \n────\n"
        w.go()
        self.assertEqual(w.io.kills, [])


class Alarm(unittest.TestCase):
    def setUp(self):
        self.w = World(self)
        self.w.mayor()
        self.w.crew()
        self.w.go()

    def test_alarm_once_at_20_min_lists_what_is_still_wrong(self):
        w = self.w
        w.say("gh-mayor", LOGIN_OUT)  # gate off: the Mayor stays the process that had the event
        w.go()
        for _ in range(18):
            w.go()
        self.assertEqual(w.io.notes, [])
        w.go(adv=120)
        self.assertEqual(len(w.io.notes), 1)
        argv, env = w.io.notes[0]
        self.assertEqual(argv[1:3], ["-p", "4"])
        self.assertIn("mayor", argv[-1])
        self.assertIn("gate do Mayor desligado", argv[-1])
        self.assertNotIn("thies-wa", argv[-1])
        self.assertEqual(env.get("NOTIFY_STRICT_EXIT"), "1")
        for _ in range(5):
            w.go()
        self.assertEqual(len(w.io.notes), 1, "one alarm per event")

    def test_silence_when_healthy(self):
        w = self.w
        w.gate()
        w.say("gh-mayor", LOGIN_OUT)
        w.go()
        self.assertEqual(w.io.kills, ["gh-mayor"])
        w.restart("gh-mayor")
        for _ in range(25):
            w.go()
        self.assertEqual(w.io.notes, [])
        self.assertIn("ALL OK", w.log())

    def test_wrong_name_and_missing_claude_are_reported(self):
        w = self.w
        w.gate()
        w.say("gh-mayor", LOGIN_OUT)
        w.go()
        w.restart("gh-mayor")
        w.io.procs[w.sess["gh-mayor"]["pid"]] = (200, w.io.t, "claude --remote-control --model opus")
        del w.io.panes[w.sess["ga-thies"]["tname"]]
        w.go(adv=1300)
        msg = w.io.notes[0][0][-1]
        self.assertIn("nome do RC não é Mayor", msg)
        self.assertIn("thies-wa: sem claude vivo", msg)

    def test_unreadable_tmux_defers_the_alarm_instead_of_reporting_absent(self):
        w = self.w
        w.gate()
        w.say("gh-mayor", LOGIN_OUT)
        w.go()
        w.restart("gh-mayor")
        w.io.fail = {"tmux": (1, "", "no server running on /private/tmp/tmux-501/gascity")}
        w.go(adv=1300)
        self.assertEqual(w.io.notes, [])
        self.assertIn("ALARM deferred", w.log())
        w.io.fail = {}
        w.go()
        self.assertEqual(w.io.notes, [])
        self.assertIn("ALL OK", w.log())

    def test_undelivered_alarm_is_retried_not_marked(self):
        w = self.w
        w.say("gh-mayor", LOGIN_OUT)
        w.go()
        w.io.notify_rc = 12
        w.go(adv=1300)
        w.go()
        self.assertEqual(len(w.io.notes), 1, "retry waits 10 min")
        w.io.notify_rc = 0
        w.go(adv=600)
        self.assertEqual(len(w.io.notes), 2)
        w.go(adv=600)
        self.assertEqual(len(w.io.notes), 2)


class Switches(unittest.TestCase):
    def setUp(self):
        self.w = World(self)
        self.w.crew()
        self.w.go()

    def test_kill_switch_does_nothing(self):
        w = self.w
        open(w.p(".gc", "login-rc-restore.off"), "w").close()
        w.say("ga-thies", LOGIN_OUT)
        n = len(w.io.calls)
        rc, out = w.go()
        self.assertEqual((rc, w.io.kills, len(w.io.calls)), (0, [], n), "switched off: not even gc is asked")
        self.assertIn("desligado", out)
        os.remove(w.p(".gc", "login-rc-restore.off"))
        w.go(LRR_ENABLED="0")
        self.assertEqual(len(w.io.calls), n)

    def test_dry_run_kills_nothing_writes_nothing(self):
        w = World(self)
        w.crew()
        w.go(dry=True)
        self.assertEqual(sorted(os.listdir(w.p(".gc"))), ["logs"])
        self.assertEqual(os.listdir(w.p(".gc", "logs")), [])
        w.go()
        w.say("ga-thies", LOGIN_OUT)
        with open(w.p(".gc", "login-rc-restore.state.json")) as fh:
            before = fh.read()
        rc, out = w.go(dry=True)
        self.assertEqual(w.io.kills, [])
        self.assertIn("WOULD kill thies-wa", out)
        self.assertIn("(dry-run)", out)
        with open(w.p(".gc", "login-rc-restore.state.json")) as fh:
            self.assertEqual(fh.read(), before)

    def test_usage(self):
        out = io.StringIO()
        with contextlib.redirect_stderr(out):
            self.assertEqual(L.main(["--bogus"], self.w.env, self.w.io), 2)


if __name__ == "__main__":
    unittest.main()
