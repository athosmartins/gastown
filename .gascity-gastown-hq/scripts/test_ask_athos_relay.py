#!/usr/bin/env python3
"""test_ask_athos_relay.py (ga-ij162cl): hermetic suite for the three layers that carry a pool worker's question to the Athos through the Mayor.
L1 = ask-athos-relay.sh, the PreToolUse:AskUserQuestion hook, run for real (bash) and through the command of the real pool overlays. L2/L3 = ask-athos-relay.py, the sweep: FakeIO answers
gc/bd/notify from tables (a call nobody planned fails the test), the panes are fake sessions. `python3 -I scripts/test_ask_athos_relay.py` (3.9+);
ASK_ATHOS_UNDER_TEST=<copy.py> / ASK_ATHOS_HOOK_UNDER_TEST=<copy.sh> run it against a mutant."""
import contextlib, fcntl, importlib.util, io as _io, json, os, shutil, subprocess, sys, tempfile, unittest  # noqa: E401
from unittest import mock

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
OVERLAYS = os.path.join(os.path.dirname(HERE), "packs", "town-deltas", "assets", "claude-overlays")
ROLES = ("pool-dog", "pool-wa-worker", "pool-ps-worker", "pool-reviewer")
HOOK = os.environ.get("ASK_ATHOS_HOOK_UNDER_TEST") or os.path.join(HERE, "ask-athos-relay.sh")
_spec = importlib.util.spec_from_file_location("ask_athos_relay", os.environ.get("ASK_ATHOS_UNDER_TEST") or os.path.join(HERE, "ask-athos-relay.py"))
P = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(P)
PAYLOAD = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": {"questions": [{"question": "Qual direção?", "header": "D", "multiSelect": False, "options": [{"label": "A", "description": "x"}]}]}})
NEEDLES = ("aguarda:athos", "next-action:mayor", "bd comment", "bd label add", "gc session nudge mayor")
POOL = [{"GC_TEMPLATE": t} for t in ("gastown.dog", "wa-worker", "ps-worker", "gate-reviewer", "refino-gate-reviewer", "whatsapp_automation/claude-headless", "dog-remote", "wa-worker-remote", "kimi-worker-remote", "ps-worker-remote", "gate-reviewer-remote", "refino-gate-reviewer-2", "kimi-worker", "claude-headless-7")] + [{"GC_AGENT": "dog-remote-1"}, {"GC_ALIAS": "wa-worker-3"}]
HUMAN = [{"GC_TEMPLATE": t} for t in ("gastown.mayor", "mayor", "oracle-wa", "whatsapp_automation/batista-wa", "thies-ps")] + [{}, {"GC_AGENT": "peter-wa-gawisp1"}, {"GC_TEMPLATE": "gastown.mayor", "GC_AGENT": "dog-remote-1", "GC_ALIAS": "wa-worker-3"}, {"GC_AGENT": "mayor", "GC_ALIAS": "dog-1"}]  # an incoherent identity is not a pool session


def hook(env, stdin=PAYLOAD, script=HOOK, cmd=None):
    e = {k: v for k, v in os.environ.items() if not k.startswith(("GC_", "ASK_ATHOS"))}
    e.update(dict({"ASK_ATHOS_RELAY_LOG": os.path.join(tempfile.gettempdir(), "ask-athos-relay-test.log")}, **env))
    p = subprocess.run(cmd or ["bash", script], input=stdin, capture_output=True, text=True, env=e, timeout=30)
    return p.returncode, p.stderr


class Layer1(unittest.TestCase):
    def test_pool_is_blocked_with_the_instruction_and_the_rest_passes(self):
        for env in POOL:
            with self.subTest(pool=env):
                rc, err = hook(env)
                self.assertEqual(rc, 2)
                self.assertTrue(err.startswith("ask-athos-relay: BLOCKED"), err)
                self.assertTrue(all(n in err for n in NEEDLES), err)
        for env in HUMAN:
            with self.subTest(human=env):
                self.assertEqual(hook(env), (0, ""))

    def test_payload_is_ignored_and_the_switches_turn_it_off(self):
        self.assertEqual(hook(POOL[0], stdin="")[0], 2)
        self.assertEqual(hook(POOL[0], stdin="{not json")[0], 2)
        self.assertEqual(hook(dict(POOL[0], ASK_ATHOS_RELAY_HOOK="0")), (0, ""))
        with tempfile.TemporaryDirectory() as t:
            self.assertEqual(hook(dict(POOL[0], ASK_ATHOS_RELAY_LOG=os.path.join(t, "d", "x.log")))[0], 2)  # the log dir does not exist yet: made, and a failure to log would not change the verdict
            with open(os.path.join(t, "d", "x.log")) as fh:
                self.assertRegex(fh.read(), r"^\d{4}-\d\d-\d\dT[\d:]+Z\tBLOCKED\tdog\n$")
        with tempfile.TemporaryDirectory() as t:
            os.makedirs(os.path.join(t, ".gc"))
            with open(os.path.join(t, ".gc", "ask-athos-relay-hook.off"), "w"):
                pass
            self.assertEqual(hook(dict(POOL[0], GC_CITY_PATH=t)), (0, ""))

    def test_overlay_command_of_every_pool_role_blocks_pool_and_fails_open(self):
        for role in ROLES:
            with self.subTest(role=role), tempfile.TemporaryDirectory() as t:
                with open(os.path.join(OVERLAYS, role, ".claude", "settings.json"), encoding="utf-8") as fh:
                    groups = [g for g in json.load(fh)["hooks"]["PreToolUse"] if g["matcher"] == "^AskUserQuestion$"]
                self.assertEqual(len(groups), 1)
                self.assertEqual(len(groups[0]["hooks"]), 1)
                cmd = groups[0]["hooks"][0]["command"].replace("/Users/athos/gt", t)
                script = os.path.join(t, ".gascity-gastown-hq", "scripts", "ask-athos-relay.sh")
                os.makedirs(os.path.dirname(script))
                shutil.copy(HOOK, script)
                run = lambda env, **kw: hook(env, cmd=["/bin/bash", "-c", cmd], **kw)  # noqa: E731
                self.assertEqual(run(POOL[0])[0], 2)
                self.assertTrue(run(POOL[0])[1].startswith("ask-athos-relay: BLOCKED"))
                self.assertEqual(run(HUMAN[0]), (0, ""))
                for broken in ("exit 1\n", "if then\n", "printf 'x' >&2; exit 2\n"):  # crash, syntax error (bash itself exits 2), exit 2 without the marker
                    with open(script, "w") as fh:
                        fh.write(broken)
                    self.assertEqual(run(POOL[0])[0], 0, broken)
                os.remove(script)
                self.assertEqual(run(POOL[0])[0], 0)


NOW, RULE = 1_800_000_000, "─" * 120
# the REAL pane of an open AskUserQuestion menu (claude 2.1.302 in tmux 120x40 against a fake local API, `capture-pane -p`; the window height pads it with blank lines)
MENU = "\n".join(["❯ faca o mockup", RULE, " ☐ Direcao", "", "Qual direcao seguir para o mockup?", "", "❯ 1. A: densa", "     Ganha: tudo a vista. Perde: ruido.", "  2. B: limpa", "     Ganha: foco. Perde: mais cliques.",
                   "  3. Type something.", RULE, "  4. Chat about this", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]) + "\n" * 16
IDLE = "⏺ pronto\n\n❯ \n  ⏵⏵ bypass permissions on\n"
FAIL, GARBAGE, NORUN, FAILBODY, NOTOK, EMPTY, WRAP = "fail", "{not json", "norun", "failbody", "notok", "empty", "wrap"


def sess(name, state="active", **kw): return dict({"name": name, "template": "wa-worker", "state": state}, **kw)


def bead(bid, sess_name="wa-worker-adhoc-1", status="in_progress"): return {"id": bid, "title": "t", "status": status, "assignee": "wa-worker-1", "labels": ["aguarda:athos"], "metadata": {"gc.session_name": sess_name}}


class World:
    def __init__(self, tmp):
        self.city, self.t, self.calls = os.path.join(tmp, "city"), NOW, []
        os.makedirs(os.path.join(self.city, ".gc"))
        for name, toml in (("oracle-wa", 'max_active_sessions = 1\nwork_dir = "/g/wa/crew/oracle"\n'), ("single", "work_dir = '/g/wa/crew/single/'\n"), ("pool", 'work_dir = "/g/wa/crew/worker"\n'), ("multi", 'max_active_sessions = 2\nwork_dir = "/g/wa/crew/multi"\n')):
            os.makedirs(os.path.join(self.city, "agents", name))
            with open(os.path.join(self.city, "agents", name, "agent.toml"), "w") as fh:
                fh.write(toml)
        os.makedirs(os.path.join(self.city, "agents", "no-toml"))
        self.rigs, self.beads, self.sessions, self.panes, self.nudge, self.push = {"rigs": [{"name": "wa", "path": "/g/wa"}, {"name": "hq", "path": self.city + "/", "hq": True}, {"path": "/g/ps"}]}, {self.city: [], "/g/wa": [], "/g/ps": []}, [sess("mayor", template="gastown.mayor")], {}, "delivered", 0

    def env(self, **kw): return dict({"GC_CITY_PATH": self.city, "ASK_ATHOS_REPEAT_S": "1800"}, **kw)
    def now(self): return self.t

    @staticmethod
    def out(v):  # a command that failed may still print a good body; gc/bd may print a WARN before the JSON and a summary after it
        if isinstance(v, tuple): return 0, "WARN: lento\n" + json.dumps(v[1]) + "\n1 issue"
        return None if v == NORUN else (1, "") if v == FAIL else (1, "[]") if v == FAILBODY else (0, v if v == GARBAGE else json.dumps(v))

    def run(self, argv, timeout):
        self.calls.append(argv)
        if argv[:2] == ["gc", "rig"]: return self.out(self.rigs)
        if argv[:2] == ["gc", "session"] and argv[2] == "list": return self.out(self.sessions)
        if argv[:4] == ["bd", "-C", argv[2], "list"] and argv[4:] == ["--label", "aguarda:athos", "--limit", "0", "--json"]: return self.out(self.beads[argv[2]])
        if argv[:3] == ["gc", "session", "peek"] and argv[4:] == ["--lines", "40"]:
            p = self.panes[argv[3]]
            return (1, "") if p == FAIL else (1, MENU) if p == FAILBODY else None if p == NORUN else (0, "" if p == EMPTY else p)
        if argv[:4] == ["gc", "session", "nudge", "mayor"] and argv[5:] == ["--delivery", "wait-idle", "--json"]:
            return None if self.nudge == NORUN else (1, "") if self.nudge == FAIL else (0, json.dumps({"ok": self.nudge != NOTOK, "outcome": "delivered" if self.nudge == NOTOK else self.nudge}))
        if argv[0] == "notify":
            self.push += 1
            return 0, ""
        raise AssertionError("unplanned call %r" % (argv,))

    def sweep(self, *args, **kw):
        buf = _io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = P.main(list(args), self.env(**kw), self)
        return rc, buf.getvalue()

    def nudges(self): return [c[4] for c in self.calls if c[:4] == ["gc", "session", "nudge", "mayor"]]
    def peeks(self): return [c[3] for c in self.calls if c[:3] == ["gc", "session", "peek"]]
    def state(self):
        with open(os.path.join(self.city, ".gc", "state", "ask-athos-relay.json")) as fh:
            return json.load(fh)


class Layers23(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory()
        self.addCleanup(self._t.cleanup)
        self.w = World(self._t.name)

    def test_defaults_and_the_crews_are_told_from_agent_toml(self):
        c = P.Cfg({})
        self.assertEqual((c.repeat_s, c.unread_after, c.call_t, c.peek_t, c.max_peek, c.mayor, c.gc, c.bd, c.notify), (1800, 2, 40, 15, 60, "mayor", "gc", "bd", "notify"))
        self.assertEqual((P.num("0", 7), P.num("x", 7), P.num(" 5 ", 7)), (7, 7, 5))
        cfg = P.Cfg(self.w.env())
        self.assertEqual(P.load_crews(cfg), frozenset({"oracle-wa", "single"}))  # not `pool` (work_dir .../crew/worker) nor `multi` (2 sessions); `no-toml` is no agent
        with open(os.path.join(self.w.city, "agents", "multi", "agent.toml"), "wb") as fh:
            fh.write(b"\xff\xfe")
        self.assertIsNone(P.load_crews(cfg))  # one agent.toml that cannot be read: nobody can be told apart from a pool session
        os.makedirs(os.path.join(self._t.name, "empty", "agents"))
        self.assertIsNone(P.load_crews(P.Cfg({"ASK_ATHOS_CITY": os.path.join(self._t.name, "empty")})))  # agents/ without a single crew

    def test_menu_detection_reads_the_tail_of_the_pane_and_needs_both_markers(self):
        long_ago = MENU + "\n".join("linha %d" % i for i in range(30)) + "\n"
        for name, text, want in (("menu", MENU, True), ("multi-question footer (from the binary, not captured)", MENU.replace("↑/↓", "Tab/Arrow keys"), True), ("idle", IDLE, False), ("old menu far above", long_ago, False),
                                 ("permission dialog", "Do you want to proceed?\n❯ 1. Yes\n  3. No\nEsc to cancel\n", False), ("footer only", "x\nEnter to select · Esc to cancel\n", False), ("options only", "  4. Chat about this\n", False), ("empty", "", False)):
            self.assertEqual(P.pane_has_menu(text), want, name)

    def test_a_labelled_bead_goes_to_the_mayor_once_then_after_the_repeat_and_stops_when_the_label_goes(self):
        w = self.w
        w.sessions, w.rigs = {"sessions": w.sessions}, w.rigs["rigs"]  # the roster may come wrapped, the rig list bare
        w.beads["/g/wa"] = [bead("wa-1"), bead("wa-9", status="closed"), dict(bead("wa-2"), metadata=None), dict(bead("wa-3"), labels=["other"]), {"id": "wa-4", "labels": ["aguarda:athos"]}]
        w.beads["/g/ps"] = ("wrap", [bead("ps-1")])
        rc, log = w.sweep()
        self.assertEqual(rc, 0)
        self.assertIn("lidos=3 esperando=4 (beads=4 panes=0) nao_lidos=0 avisar=4", log)
        n = w.nudges()
        self.assertEqual(len(n), 1)
        self.assertTrue(all(x in n[0] for x in ("wa/wa-1 (sessão wa-worker-adhoc-1)", "wa/wa-2 (sessão wa-worker-1)", "wa/wa-4 (sessão ?)", "ps/ps-1", "aguarda:athos", "next-action:mayor", "AskUserQuestion")) and not any(x in n[0] for x in ("wa-9", "wa-3", "\n")), n)
        w.t += 600
        w.sweep()
        self.assertEqual(len(w.nudges()), 1)
        w.t += 1200  # exactly the repeat
        w.sweep()
        self.assertEqual(len(w.nudges()), 2)
        w.beads["/g/wa"], w.beads["/g/ps"] = [], []
        w.t += 10
        w.sweep()
        self.assertEqual((len(w.nudges()), w.state()["sent"]), (2, {}))
        w.beads["/g/wa"] = [bead("wa-1")]
        w.t += 10
        w.sweep()
        self.assertEqual(len(w.nudges()), 3)

    def test_a_long_list_is_clipped_and_beads_panes_and_unread_share_one_nudge(self):
        w = self.w
        w.beads["/g/wa"] = [bead("wa-%d" % i) for i in range(8)]
        w.sessions, w.panes = [sess("mayor", template="gastown.mayor"), sess("wa-worker-1"), sess("wa-worker-2")], {"wa-worker-1": MENU, "wa-worker-2": FAIL}
        w.sweep()
        self.assertEqual(w.push, 1)  # the pane only: a bead is not a leak
        n = w.nudges()[0]
        self.assertTrue(" +2." in n and "wa/wa-5" in n and "wa/wa-6" not in n and "pane de: wa-worker-1." in n and "NÃO CONFERI" not in n, n)
        w.t += 1900
        w.sweep()
        self.assertTrue(len(w.nudges()) == 2 and "NÃO CONFERI" in w.nudges()[1] and "pane:wa-worker-2" in w.nudges()[1], w.nudges())

    def test_a_store_that_cannot_be_read_is_counted_and_never_read_as_nothing_waiting(self):
        w = self.w
        for bad in (FAIL, FAILBODY, GARBAGE, NORUN, "plain text", {"not": "a list"}, ["x"], [{"id": 5}], [{"id": "x", "labels": "aguarda:athos"}]):
            with self.subTest(bad=bad):
                w.beads[w.city], w.beads["/g/wa"], w.calls = bad, [bead("wa-1")], []
                rc, log = w.sweep()
                self.assertEqual((rc, len(w.nudges())), (1, 1))
                self.assertIn("NAO-CONFERIDO: loja:hq", log)
                self.assertIn("wa/wa-1", w.nudges()[0])
                os.remove(os.path.join(w.city, ".gc", "state", "ask-athos-relay.json"))
        w.beads[w.city] = []
        self.assertEqual(w.sweep()[0], 0)

    def test_a_rig_list_that_fails_falls_back_to_the_hq_store_and_says_so(self):
        w = self.w
        w.beads = {w.city: [bead("ga-5")]}
        for bad in (FAIL, FAILBODY, GARBAGE, NORUN, {"rigs": "x"}):
            w.rigs, w.calls = bad, []
            rc, log = w.sweep()
            self.assertTrue(rc == 1 and "hq/ga-5" in w.nudges()[0] and "NAO-CONFERIDO: rigs" in log, (bad, log))
            os.remove(os.path.join(w.city, ".gc", "state", "ask-athos-relay.json"))

    def test_an_open_menu_in_a_pool_pane_is_relayed_and_pushed_but_human_facing_and_idle_sessions_are_not_even_read(self):
        w = self.w
        w.sessions = ["junk", sess("mayor", template="gastown.mayor"), sess("oracle-wa-gawispzz", template="t"), sess("rig/oracle-wa"), sess("single-gawisp1"), sess("x1", template="t", alias="mayor"), sess("x2", template="t", agent_name="oracle-wa"),
                      {"session_name": "mayor", "state": "active", "template": "t"}, sess("x4", template="oracle-wa"), sess("x5", template="gastown.mayor"), {"session_name": "wa-worker-sn", "state": "active", "template": "wa-worker"}, sess("oracle-wax"), sess("multi-1"), sess("wa-worker-adhoc-1"), sess("dog-2", template="gastown.dog"), sess("wa-worker-awake", state="awake"),
                      sess("wa-worker-9", state="asleep"), sess("wa-worker-7", attached=True), sess("wa-worker-8", closed=True)]
        w.panes = {"wa-worker-adhoc-1": MENU, "dog-2": IDLE, "wa-worker-awake": MENU, "oracle-wax": IDLE, "multi-1": IDLE, "wa-worker-sn": IDLE}
        rc, log = w.sweep()
        self.assertEqual(rc, 0)
        self.assertEqual(sorted(w.peeks()), ["dog-2", "multi-1", "oracle-wax", "wa-worker-adhoc-1", "wa-worker-awake", "wa-worker-sn"])
        n = w.nudges()
        self.assertTrue(len(n) == 1 and "wa-worker-adhoc-1, wa-worker-awake" in n[0] and "dog-2" not in n[0] and "gc session peek" in n[0] and "Chat about" not in n[0], n)
        pushes = [c for c in w.calls if c[0] == "notify"]
        self.assertTrue(len(pushes) == 2 and pushes[0][1] == "-t" and pushes[0][3:5] == ["-p", "4"] and "wa-worker-adhoc-1" in pushes[0][5] and "wa-worker-awake" in pushes[1][5], pushes)
        self.assertIn("push wa-worker-awake: ok", log)
        w.t += 60
        w.sweep()
        self.assertEqual((len(w.nudges()), w.push), (1, 2))

    def test_unread_panes_and_rosters_escalate_after_the_streak_and_the_exit_code_never_says_all_clear(self):
        w = self.w
        w.sessions = [sess("mayor", template="gastown.mayor")] + [sess("wa-worker-%d" % i) for i in (1, 2, 3, 4)] + [{"template": "wa-worker", "state": "active"}]
        w.panes = {"wa-worker-1": FAIL, "wa-worker-2": NORUN, "wa-worker-3": EMPTY, "wa-worker-4": FAILBODY}
        self.assertEqual(w.sweep()[0], 1)
        self.assertEqual(w.nudges(), [])
        w.t += 180
        self.assertEqual(w.sweep()[0], 1)
        n = w.nudges()
        self.assertTrue(len(n) == 1 and all(x in n[0] for x in ("NÃO CONFERI", "pane:wa-worker-1", "pane:wa-worker-2", "pane:wa-worker-3", "pane:wa-worker-4", "sessão sem nome", "ninguém esperando")), n)
        w.t += 180
        w.sweep()
        self.assertEqual(len(w.nudges()), 1)  # the unread notice waits 4 repeats
        w.t += 3600
        w.sweep()
        self.assertEqual(len(w.nudges()), 1)
        w.t += 3700
        w.sweep()
        self.assertEqual(len(w.nudges()), 2)
        w.t += 180
        w.panes, w.sessions = dict.fromkeys(w.panes, IDLE), w.sessions[:5]
        self.assertEqual((w.sweep()[0], w.state()["streak"]), (0, {}))
        for bad in (FAIL, FAILBODY, GARBAGE, NORUN, [], {"sessions": "x"}):
            with self.subTest(roster=bad):
                w.sessions, w.calls = bad, []
                os.remove(os.path.join(w.city, ".gc", "state", "ask-athos-relay.json"))
                self.assertEqual(w.sweep()[0], 1)
                w.t += 180
                w.sweep()
                self.assertTrue(len(w.nudges()) == 1 and "sessões" in w.nudges()[0], w.nudges())
        w.sessions, w.calls, w.t = [sess("wa-worker-1"), sess("wa-worker-2")], [], w.t + 10_000
        self.assertEqual((w.sweep(ASK_ATHOS_MAX_PEEK="1")[0], len(w.peeks())), (1, 1))  # the second one is over the ceiling: counted, not skipped in silence
        self.assertIn("pane:wa-worker-2", w.state()["streak"])
        shutil.rmtree(os.path.join(w.city, "agents"))  # the crews cannot be told apart from pool sessions: nothing is peeked
        w.calls, w.t = [], w.t + 10_000
        rc, log = w.sweep()
        self.assertEqual((rc, w.peeks(), "NAO-CONFERIDO: crews" in log), (1, [], True))

    def test_a_nudge_that_did_not_arrive_is_retried_and_one_that_was_queued_is_recorded(self):
        w = self.w
        w.beads["/g/wa"] = [bead("wa-1")]
        for bad in (FAIL, NORUN, "unreadable", NOTOK):
            w.nudge, w.calls = bad, []
            self.assertEqual(w.sweep()[0], 1, bad)
            self.assertEqual(len(w.nudges()), 1)
            self.assertEqual(w.state()["sent"], {})
        w.nudge, w.calls = "queued", []
        self.assertEqual(w.sweep()[0], 0)
        self.assertEqual(list(w.state()["sent"]), ["bead:wa/wa-1"])

    def test_state_that_cannot_be_trusted_sends_nothing_and_a_missing_one_is_a_first_run(self):
        w = self.w
        w.beads["/g/wa"] = [bead("wa-1")]
        os.makedirs(os.path.join(w.city, ".gc", "state"))
        path = os.path.join(w.city, ".gc", "state", "ask-athos-relay.json")
        for junk in ("garbage", "[]", '{"sent": {"k": "x"}, "streak": {}}', '{"sent": {"k": true}, "streak": {}}', '{"sent": {}, "streak": {"k": -1}}', '{"sent": {}, "streak": {"k": 1.5}}', '{"sent": {}, "streak": {"k": true}}', '{"sent": {}}'):
            with self.subTest(junk=junk):
                with open(path, "w") as fh:
                    fh.write(junk)
                rc, log = w.sweep()
                self.assertEqual((rc, w.nudges(), "STATE-ERROR" in log), (1, [], True))
        os.remove(path)
        self.assertEqual((w.sweep()[0], len(w.nudges())), (0, 1))

    def test_a_state_that_cannot_be_written_or_read_back_sends_nothing(self):
        w = self.w
        w.beads["/g/wa"] = [bead("wa-1")]
        for what, patch in (("replace fails", mock.patch.object(P.os, "replace", side_effect=OSError("x"))), ("readback differs", mock.patch.object(P.json, "dump", lambda st, fh, **kw: fh.write("{}")))):
            with self.subTest(what), patch:
                w.calls = []
                rc, log = w.sweep()
                self.assertEqual((rc, w.nudges(), "STATE-ERROR" in log), (1, [], True))

    def test_off_switch_lock_dry_run_usage_and_a_crash_are_all_loud_or_quiet_on_purpose(self):
        w = self.w
        w.beads["/g/wa"] = [bead("wa-1")]
        rc, log = w.sweep("--dry-run")
        self.assertEqual((rc, w.nudges(), w.push, "DRY-RUN" in log and "wa/wa-1" in log), (0, [], 0, True))
        w.beads["/g/wa"] = []
        self.assertEqual(w.sweep("--dry-run")[0], 0)
        self.assertFalse(os.path.exists(os.path.join(w.city, ".gc", "state", "ask-athos-relay.json")))
        w.beads["/g/wa"] = [bead("wa-1")]
        self.assertEqual(w.sweep("--bogus")[0], 2)
        off, lock = os.path.join(w.city, ".gc", "ask-athos-relay.off"), os.path.join(w.city, ".gc", "ask-athos-relay.lock")
        with open(off, "w"):
            pass
        self.assertEqual((w.sweep()[0], w.nudges()), (0, []))
        os.remove(off)
        with open(lock, "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            self.assertEqual((w.sweep()[0], w.nudges()), (0, []))
        os.remove(lock)
        os.makedirs(lock)  # a lock path that cannot be opened
        rc, log = w.sweep()
        self.assertEqual((rc, "LOCK-ERROR" in log, w.nudges()), (1, True, []))
        os.rmdir(lock)
        w.run = lambda argv, timeout: 1 / 0
        rc, log = w.sweep()
        self.assertEqual((rc, "CRASH" in log), (1, True))

    def test_real_io_never_returns_an_empty_answer_for_a_command_that_did_not_run(self):
        io = P.RealIO()
        self.assertIsNone(io.run(["/nonexistent/x"], 5))
        self.assertIsNone(io.run(["sleep", "5"], 0.2))
        self.assertEqual(io.run(["sh", "-c", "echo oi; exit 3"], 5), (3, "oi\n"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
