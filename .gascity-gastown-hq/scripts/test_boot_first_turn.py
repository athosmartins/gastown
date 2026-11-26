#!/usr/bin/env python3
"""test_boot_first_turn.py (ga-esorlre.13): hermetic suite for scripts/boot-first-turn.py. FakeIO emulates ps/tmux/bd over REAL files in a temp tree (registry, transcripts, agents, .gc);
one test drives a REAL tmux server on a private socket. `python3 -I test_boot_first_turn.py` on 3.9 and 3.12; BFT_UNDER_TEST=<copy> runs it against a mutant."""
import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SUT = os.environ.get("BFT_UNDER_TEST") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "boot-first-turn.py")
_spec = importlib.util.spec_from_file_location("bft", SUT)
B = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(B)

RULE = "─" * 80
FOOT = "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent"


def real_pane(footer=FOOT, prompt="❯ ", above="✻ Cooked for 3m 1s · done 8:55 PM\n"):
    """The chrome of claude 2.1.310 on the mini in the shape captured from live panes (test_nightly_session_compact.real_pane, test_claude_crew_account.REAL_BOX): two status lines between the prompt box and the
    footer, and `← 1 agent` on every pane captured there."""
    return "%s\n%s\n%s\n%s\n  👥 0 workers · 🚦 running 2/3 6c179cf040677bf559f74e\n  [Opus 5.5] ctx: 38.0%% (380k/1000k)\n%s\n" % (above, RULE, prompt, RULE, footer)


REAL_IDLE = real_pane()
# ASSUMPTION, not a capture from the mini: a conversation with no turn yet shows a dim `Try "…"` suggestion after the prompt mark, which `tmux capture-pane -p` prints as plain text
FRESH_PLACEHOLDER = real_pane(prompt='❯ Try "how does <filepath> work?"', above="")


class PaneReading(unittest.TestCase):
    def test_a_real_idle_prompt_is_idle_and_the_agent_hint_is_not_work(self):
        self.assertEqual(B.read_pane(REAL_IDLE), ("idle", ""))

    def test_every_state_that_must_not_be_typed_into(self):
        for why, pane, state, frag in (
                ("spinner with timer", "* Infusing… (7m 18s · ↓ 5k tokens)\n❯ \n", "working", "a turn is running"),
                ("esc to interrupt", real_pane(above="✻ Working…\n").replace("(shift+tab to cycle)", "(esc to interrupt)"), "working", "a turn is running"),
                ("permission dialog", "Do you want to proceed?\n❯ 1. Yes\n  2. No\n", "dialog", "a dialog waits for a key"),
                ("selection menu", "Enter to select · ↑/↓ to navigate · Esc to cancel\n❯ 1. Yes\n", "dialog", "a dialog waits for a key"),
                ("numbered menu without hint", "How do you want to resume?\n❯ 1. Resume from summary\n  2. Resume full session\n", "dialog", "numbered menu"),
                ("a draft being typed", real_pane(prompt="❯ half a message"), "busy", "half a message"),
                ("a shell in the footer", real_pane(footer="  ⏵⏵ bypass permissions on · 1 shell · (shift+tab to cycle)"), "busy", "background work in the footer"),
                ("a monitor in the footer", real_pane(footer="  ⏵⏵ bypass permissions on · 2 monitors"), "busy", "background work in the footer"),
                ("no claude prompt (a shell)", "$ ls\nfoo\n", "unknown", "no Claude Code prompt"),
                ("empty pane", "", "unknown", "no Claude Code prompt"),
                ("spinner whose timer cannot be read", "✻ Pondering…\n" + REAL_IDLE.split("\n", 1)[1], "unknown", "spinner")):
            got = B.read_pane(pane)
            self.assertEqual(got[0], state, why)
            self.assertIn(frag, got[1], why)

    def test_the_fresh_conversation_suggestion_is_not_a_draft(self):
        # a session with no turn yet is exactly the one this job exists for: its `Try "…"` suggestion must not read as somebody typing
        self.assertEqual(B.read_pane(FRESH_PLACEHOLDER), ("idle", ""))
        self.assertEqual(B.read_pane(real_pane(prompt='❯ Try "run the tests" and then fix'))[0], "busy")  # looks like text typed by someone, not the whole-line suggestion

    def test_draft_of_returns_what_sits_after_the_prompt_mark(self):
        self.assertEqual(B.draft_of(REAL_IDLE), "")
        self.assertEqual(B.draft_of(real_pane(prompt="❯ " + B.TAG + " hello")), B.TAG + " hello")
        self.assertIsNone(B.draft_of("$ ls\n"))


class Text(unittest.TestCase):
    def test_it_names_the_beads_and_keeps_the_mayors_wording(self):
        t = B.compose(["wa-axkxf5.34", "wa-b"])
        self.assertTrue(t.startswith(B.TAG))
        self.assertIn("retome a bead em andamento wa-axkxf5.34, wa-b e o último handoff; se não houver, pegue a próxima por prioridade", t)

    def test_without_ids_it_never_claims_there_is_nothing_in_progress(self):
        # an empty list means "none found OR could not read": the text is the same and tells the session to look for itself
        t = B.compose([])
        self.assertIn("a bead que estiver em andamento com você (confira com bd list --status in_progress)", t)
        self.assertIn("e o último handoff; se não houver, pegue a próxima por prioridade", t)
        for claim in ("nenhuma", "não há bead", "sem bead", "não tem bead"):
            self.assertNotIn(claim, t)
        self.assertEqual(B.compose(None), t)

    def test_one_line_no_slash_command_token_and_only_safe_ids_in_it(self):
        t = B.compose(["wa-1", "a b", "x\ny", "$(rm -rf)", "", "ok.2", "\x1b[31m", "wa-3", "wa-4", "wa-5", "wa-6", "wa-7"])
        self.assertNotIn("\n", t)
        self.assertNotIn("\r", t)
        self.assertNotIn("\x1b", t)
        self.assertIsNone(re.search(r"(^|\s)/[A-Za-z]", t), "a slash token that names a skill would be attached as a skill mention (ga-7nxfa1)")
        self.assertIn("wa-1, ok.2, wa-3, wa-4, wa-5 e o último", t)  # unsafe ones dropped, at most five kept
        self.assertNotIn("wa-6", t)
        self.assertLess(len(B.compose(["wa-1"])), 600)

    def test_the_tag_is_what_the_proof_looks_for(self):
        self.assertIn("ga-esorlre.13", B.TAG)
        self.assertEqual(B.compose(["a"]).count(B.TAG), 1)


class SmallParsers(unittest.TestCase):
    def test_etime(self):
        for raw, want in (("05:12", 312), ("1:05:12", 3912), ("2-01:02:03", 176523), ("00:59", 59), ("garbage", None), ("", None), ("5", None), ("1-2", None), ("ab:cd", None)):
            self.assertEqual(B.parse_etime(raw), want, raw)

    def test_rig_of_a_crew_work_dir(self):
        self.assertEqual(B.rig_of("/Users/athos/gt/whatsapp_automation/crew/peter"), "/Users/athos/gt/whatsapp_automation")
        self.assertEqual(B.rig_of("/Users/athos/gt/property_scrapers/crew/batista"), "/Users/athos/gt/property_scrapers")
        for none in ("/Users/athos/gt/.gascity-gastown-hq", "", None, "/x/crew", "/x/crew/"):
            self.assertIsNone(B.rig_of(none), none)


T0 = 1800000000.0  # the virtual "now"
TS_FMT = "%Y-%m-%dT%H:%M:%S"


def iso(t):
    return time.strftime(TS_FMT, time.gmtime(t)) + ".000Z"


def put(path, text, mode="w"):
    with open(path, mode) as fh:
        fh.write(text)


def jload(path):
    with open(path) as fh:
        return json.load(fh)


def etime(sec):
    sec = int(sec)
    d, r = divmod(sec, 86400)
    h, r = divmod(r, 3600)
    m, s = divmod(r, 60)
    return ("%d-" % d if d else "") + ("%02d:" % h if (d or h) else "") + "%02d:%02d" % (m, s)


def user_rec(text, t):
    return {"type": "user", "timestamp": iso(t), "message": {"role": "user", "content": text}}


def asst_rec(t, text="ok"):
    return {"type": "assistant", "timestamp": iso(t), "message": {"role": "assistant", "model": "m", "stop_reason": "end_turn", "content": [{"type": "text", "text": text}]}}


class W:
    """A throwaway city + HOME and the fake IO the script talks to (clock, ps, tmux, bd, gc, notify). Typing into a pane has the effect a live claude would have (a turn starts: registry busy, a user record in the
    transcript, a working pane) unless a test switches it off with `lost_keys` (the keys go nowhere) or `drop_enters` = N (the next N Enters are swallowed: the text stays in the input box)."""
    def __init__(self, **env):
        self.root = tempfile.mkdtemp(prefix="bft-test-")
        self.home, self.city = os.path.join(self.root, "home"), os.path.join(self.root, "city")
        for d in ("home/.claude/sessions", "home/.claude/projects/p", "city/agents", "city/.gc/logs"):
            os.makedirs(os.path.join(self.root, d))
        self.t, self.calls, self.roster, self.panes, self.procs, self.pids, self.sid, self.path = T0, [], [], {}, {}, {}, {}, {}
        self.inprog, self.events, self.typed, self.enters, self.notes, self.note_env, self.forced = {}, [], [], [], [], [], {}
        self.lost_keys, self.drop_enters, self.box, self.on_bd_list, self.keys, self.fail_enter = False, 0, {}, None, [], False
        self.notify_rc = 0
        self.next_pid = 41000
        self.env = dict({"GC_CITY_PATH": self.city, "BFT_HOME": self.home, "BFT_GC": "gc", "BFT_BD": "bd", "BFT_TMUX": "tmux", "BFT_NOTIFY": "notify", "BFT_BUDGET_S": "100"}, **env)
        self.cfg = B.Cfg(self.env)

    # ---- building the world
    def add(self, name, template="thies-wa", age=600, idle=300, status="idle", pane=REAL_IDLE, crew=True, state="active", recs=None, tidle=None, tmux=True, rig="whatsapp_automation", **reg):
        wd = "/Users/athos/gt/%s/crew/%s" % (rig, template)
        if crew and template != "gastown.mayor":
            os.makedirs(os.path.join(self.city, "agents", template), exist_ok=True)
            put(os.path.join(self.city, "agents", template, "agent.toml"), 'work_dir = "%s"\nmax_active_sessions = 1\n' % wd)
        pid = self.next_pid
        self.next_pid += 1
        sid = "%08d-0000-4000-8000-%012d" % (pid, pid)
        self.pids[name], self.sid[name], self.path[name] = pid, sid, os.path.join(self.home, ".claude/projects/p", sid + ".jsonl")
        self.procs[pid] = (self.t - age, "/opt/claude --remote-control X")
        if recs is not False:
            put(self.path[name], "".join(json.dumps(r) + "\n" for r in (recs if recs is not None else [user_rec("[gascity] boot prime", self.t - age + 5), asst_rec(self.t - age + 30)])))
            q = self.t - (idle if tidle is None else tidle)
            os.utime(self.path[name], (q, q))
        self.write_reg(name, **dict({"pid": pid, "sessionId": sid, "kind": "interactive", "cwd": wd, "startedAt": int((self.t - age) * 1000), "status": status, "statusUpdatedAt": int((self.t - idle) * 1000)},
                                    **({"tmux": name + ":@1.%1"} if tmux else {}), **reg))
        self.roster.append({"id": "ga-s-" + name, "metadata": {"template": template, "session_name": name, "state": state}})
        self.panes[name] = pane
        return pid

    def write_reg(self, name, **kw):
        f = os.path.join(self.home, ".claude/sessions", "%d.json" % self.pids[name])
        e = dict(jload(f), **kw) if os.path.exists(f) else dict(kw)
        put(f, json.dumps({k: v for k, v in e.items() if v is not None}))
        os.utime(f, (self.t, self.t))

    def reg(self, name):
        return jload(os.path.join(self.home, ".claude/sessions", "%d.json" % self.pids[name]))

    def append(self, name, *recs):
        put(self.path[name], "".join(json.dumps(r) + "\n" for r in recs), "a")

    # ---- the clock and the effects that happen in it
    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s
        for ev in [e for e in self.events if e[0] <= self.t]:
            self.events.remove(ev)
            ev[1]()

    def turn_starts(self, name, text):
        self.write_reg(name, status="busy", statusUpdatedAt=int(self.t * 1000))
        self.append(name, user_rec(text, self.t))
        self.panes[name] = "* Pondering… (3s · ↓ 1k tokens)\n" + REAL_IDLE

    # ---- the fake tools
    def run(self, argv, timeout, env=None):
        self.calls.append(list(argv))
        for k in (" ".join(argv[:4]), " ".join(argv[:3])):  # a forced answer is keyed by the first three words, or four when it must tell `bd list` from `bd query`
            if k in self.forced:
                return self.forced[k]
        tool = os.path.basename(argv[0])
        if tool == "ps":
            pid = int(argv[-1])
            return (0, "  %s %s\n" % (etime(self.t - self.procs[pid][0]), self.procs[pid][1]), "") if pid in self.procs else (1, "", "")
        if tool == "bd":
            if "query" in argv:
                return 0, json.dumps(self.roster), ""
            if "list" in argv:
                store = argv[argv.index("-C") + 1]
                got = self.inprog.get(store, [])
                if self.on_bd_list:
                    self.on_bd_list()
                return (0, json.dumps(got), "") if got is not None else (1, "", "boom")
        if tool == "gc" and argv[3:5] == ["session", "list"]:
            return 0, json.dumps({"sessions": [dict(r["metadata"], id=r["id"]) for r in self.roster]}), ""
        if tool == "tmux":
            sub = argv[argv.index("-L") + 2] if "-L" in argv else argv[1]
            name = argv[argv.index("-t") + 1].strip("=:") if "-t" in argv else None
            if sub == "capture-pane":
                return (0, self.panes[name], "") if self.panes.get(name) is not None else (1, "", "can't find session: %s" % name)
            if sub == "send-keys":
                self.keys.append(list(argv))
                if argv[-1] == "Enter" and self.fail_enter:
                    return 1, "", "enter broke"
                if self.lost_keys:
                    return 0, "", ""
                if argv[-2:-1] == ["-l"]:
                    self.typed.append((name, argv[-1]))
                    self.box[name] = self.box.get(name, "") + argv[-1]
                    self.panes[name] = real_pane(prompt="❯ " + self.box[name])
                elif argv[-1] == "Enter":
                    self.enters.append(name)
                    if self.drop_enters:
                        self.drop_enters -= 1
                    elif self.box.get(name):
                        self.turn_starts(name, self.box.pop(name))
                return 0, "", ""
        if tool == "notify":
            self.notes.append(list(argv))
            self.note_env.append(env)
            return self.notify_rc, "", ""
        return 0, "", ""

    # ---- driving it
    def go(self, **kw):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            code, counts = B.run_pass(self.cfg, self, **kw)
        self.out, self.counts = out.getvalue(), counts
        return code

    def later(self, sec=60, **kw):
        self.t += sec
        return self.go(**kw)

    def state(self):
        p = os.path.join(self.city, ".gc/boot-first-turn.state.json")
        return jload(p)["targets"] if os.path.exists(p) else None

    def tmux_calls(self, sub=None):
        return [c for c in self.calls if os.path.basename(c[0]) == "tmux" and (sub is None or c[3] == sub)]

    def results(self):
        p = os.path.join(self.city, ".gc/logs/boot-first-turn.jsonl")
        if not os.path.exists(p):
            return []
        with open(p) as fh:
            return [json.loads(x) for x in fh.read().splitlines()]

    def log(self):
        p = os.path.join(self.city, ".gc/logs/boot-first-turn.log")
        if not os.path.exists(p):
            return ""
        with open(p) as fh:
            return fh.read()


class Base(unittest.TestCase):
    def w(self, **env):
        w = W(**env)
        self.addCleanup(shutil.rmtree, w.root, True)
        return w


class Targets(Base):
    def test_only_the_mayor_and_active_named_crews_are_targets(self):
        crews = {"thies-wa": "/x/crew/thies-wa", "peter-wa": "/x/crew/peter-wa"}
        roster = [{"id": "b1", "template": "gastown.mayor", "session_name": "mayor-1", "state": "active"},
                  {"id": "b2", "template": "thies-wa", "session_name": "thies-wa-gawispaaa", "state": "active"},
                  {"id": "b3", "template": "whatsapp_automation/peter-wa", "session_name": "peter-wa-gawispbbb", "state": "active"},
                  {"id": "b4", "template": "gastown.dog", "session_name": "dog-1", "state": "active"},
                  {"id": "b5", "template": "wa-worker", "session_name": "wa-worker-1", "state": "active"},
                  {"id": "b6", "template": "thies-wa", "session_name": "thies-wa-old", "state": "asleep"},
                  {"id": "b7", "template": "mayor", "session_name": "mayor-2", "state": "active"},
                  {"id": "b8", "template": "thies-wa", "session_name": "", "state": "active"}, {"id": None, "template": "thies-wa", "session_name": "x", "state": "active"},
                  "junk", None]
        got = B.pick_targets(roster, crews)
        self.assertEqual([(t["name"], t["bead"], t["template"], t["work_dir"]) for t in got],
                         [("mayor-1", "b1", "gastown.mayor", None), ("mayor-2", "b7", "mayor", None), ("peter-wa-gawispbbb", "b3", "peter-wa", "/x/crew/peter-wa"),
                          ("thies-wa-gawispaaa", "b2", "thies-wa", "/x/crew/thies-wa")])


class CorePath(Base):
    def test_an_idle_crew_that_came_up_minutes_ago_gets_the_first_turn_typed_in_its_pane(self):
        w = self.w()
        w.add("thies-wa-gawispaaa")
        self.assertEqual(w.go(), 0)
        tm = ["tmux", "-L", "gascity"]
        cap = tm + ["capture-pane", "-p", "-t", "=thies-wa-gawispaaa:", "-S", "-40"]
        self.assertEqual(w.tmux_calls(), [cap, cap,  # the pane is read to judge, and again right before typing (the bead lookups in between take seconds)
                                          tm + ["send-keys", "-t", "=thies-wa-gawispaaa:", "-l", w.typed[0][1]],
                                          tm + ["send-keys", "-t", "=thies-wa-gawispaaa:", "Enter"]])
        text = w.typed[0][1]
        self.assertEqual(text, B.compose([]))  # exactly the composed line: no newline, no extra key typed along with it
        self.assertTrue(text.startswith(B.TAG))
        self.assertIn("e o último handoff; se não houver, pegue a próxima por prioridade", text)
        self.assertEqual((w.counts["targets"], w.counts["typed"]), (1, 1))

    def test_the_mayor_gets_it_too(self):
        w = self.w()
        w.add("mayor-1", template="gastown.mayor", crew=False)
        w.go()
        self.assertEqual([n for n, _ in w.typed], ["mayor-1"])

    def test_pool_sessions_and_sleeping_crews_never_get_the_text(self):
        w = self.w()
        w.add("dog-1", template="gastown.dog", crew=False)
        w.add("wa-worker-1", template="wa-worker", crew=False)
        w.add("digo-wa-1", template="digo-wa", state="asleep")
        self.assertEqual(w.go(), 0)
        self.assertEqual((w.typed, w.tmux_calls(), w.counts["targets"]), ([], [], 0))


class NotYet(Base):
    def test_every_reason_not_to_type_now(self):
        busy = real_pane(above="✻ Working…\n").replace("(shift+tab to cycle)", "(esc to interrupt)")
        for why, kw, frag in (
                ("registry busy", dict(status="busy"), "registry status=busy"),
                ("registry waiting for an answer", dict(status="waiting"), "registry status=waiting"),
                ("idle for only 60 s", dict(idle=60), "idle for only"),
                ("up for only 100 s (no status change since it started)", dict(age=100, idle=100), "idle for only"),
                ("no status field and a transcript quiet for less than twice the minimum", dict(status=None, statusUpdatedAt=None, age=500, tidle=200), "idle for only"),
                ("the pane shows a turn", dict(pane=busy), "pane: a turn is running"),
                ("a dialog", dict(pane="Do you want to proceed?\n❯ 1. Yes\n"), "pane: a dialog"),
                ("a draft", dict(pane=real_pane(prompt="❯ half a message")), "the input box holds text"),
                ("background work", dict(pane=real_pane(footer="  ⏵⏵ bypass permissions on · 1 shell · (shift+tab to cycle)")), "background work in the footer")):
            w = self.w()
            w.add("c1", **kw)
            self.assertEqual(w.go(), 0, why)
            self.assertEqual(w.typed, [], why)
            self.assertIn(frag, w.log() + w.out, why)
            self.assertEqual(w.counts["wait"], 1, why)

    def test_a_process_older_than_the_window_is_left_to_the_watchdog(self):
        w = self.w()
        w.add("c1", age=1201)
        w.go()
        self.assertEqual((w.typed, w.counts["late"], w.counts["wait"]), ([], 1, 0))
        w = self.w()
        w.add("c1", age=1199)
        w.go()
        self.assertEqual(len(w.typed), 1)

    def test_a_pane_that_cannot_be_read_or_is_not_claude_types_nothing(self):
        for why, pane, frag in (("no tmux session", None, "can't find session"), ("a shell", "$ ls\n", "no Claude Code prompt"), ("empty", "", "no Claude Code prompt")):
            w = self.w()
            w.add("c1", pane=pane)
            self.assertEqual(w.go(), 0, why)
            self.assertEqual(w.typed, [], why)
            self.assertIn(frag, w.log() + w.out, why)
            self.assertEqual(w.counts["unknown"], 1, why)

    def test_the_tmux_binary_failing_to_run_is_unknown_not_empty(self):
        w = self.w()
        w.add("c1")
        w.forced["tmux -L gascity"] = (None, "", "")
        w.go()
        self.assertEqual((w.typed, w.counts["unknown"]), ([], 1))


class Matching(Base):
    def test_a_registry_file_older_than_its_pid_is_a_leftover_of_an_earlier_holder(self):
        w = self.w()
        pid = w.add("c1")
        f = os.path.join(w.home, ".claude/sessions/%d.json" % pid)
        os.utime(f, (T0 - 5000, T0 - 5000))  # the process is 600 s old; this file was written 5000 s ago: another claude held this pid before
        w.go()
        self.assertEqual((w.typed, w.counts["absent"]), ([], 1))

    def test_a_dead_pid_or_a_pid_that_is_not_claude_is_not_the_session(self):
        w = self.w()
        pid = w.add("c1")
        del w.procs[pid]
        w.go()
        self.assertEqual((w.typed, w.counts["absent"]), ([], 1))
        w = self.w()
        pid = w.add("c1")
        w.procs[pid] = (T0 - 600, "/usr/bin/python3 something.py")
        w.go()
        self.assertEqual((w.typed, w.counts["absent"]), ([], 1))

    def test_ps_that_fails_is_unknown_not_dead(self):
        w = self.w()
        w.add("c1")
        w.forced["ps -o etime=,command="] = (None, "", "")
        w.go()
        self.assertEqual((w.typed, w.counts["unknown"], w.counts["absent"]), ([], 1, 0))

    def test_two_live_claudes_in_one_pane_is_unknown(self):
        w = self.w()
        w.add("c1")
        pid2 = 77001
        w.procs[pid2] = (T0 - 60, "/opt/claude -p helper")
        put(os.path.join(w.home, ".claude/sessions/%d.json" % pid2), json.dumps({"pid": pid2, "sessionId": "%08d-0000-4000-8000-%012d" % (pid2, pid2), "kind": "interactive", "cwd": "/x", "startedAt": int((T0 - 60) * 1000), "tmux": "c1:@1.%1"}))
        os.utime(os.path.join(w.home, ".claude/sessions/%d.json" % pid2), (T0, T0))
        w.go()
        self.assertEqual((w.typed, w.counts["unknown"]), ([], 1))
        self.assertIn("2 live claude processes", w.log() + w.out)

    def test_without_a_tmux_field_the_crew_work_dir_finds_the_process(self):
        w = self.w()
        w.add("c1", tmux=False)
        w.go()
        self.assertEqual(len(w.typed), 1)

    def test_a_non_interactive_claude_never_matches(self):
        w = self.w()
        w.add("c1", kind="sdk-cli")
        w.add("c2", template="peter-wa")  # a fresh interactive session wakes the pass: c1 is evaluated and its only claude is a helper
        w.go()
        self.assertEqual(([n for n, _ in w.typed], w.counts["absent"]), (["c2"], 1))

    def test_a_registry_that_cannot_be_read_types_nothing_and_says_so(self):
        w = self.w()
        w.add("c1")
        shutil.rmtree(os.path.join(w.home, ".claude/sessions"))
        self.assertEqual(w.go(), 3)
        self.assertEqual(w.typed, [])


class OncePerStart(Base):
    def test_the_same_start_is_never_typed_twice_even_when_the_pane_is_idle_and_empty_again(self):
        w = self.w()
        w.add("c1")
        w.go()
        self.assertEqual(len(w.typed), 1)
        w.panes["c1"] = REAL_IDLE  # the turn is over and the pane is as idle as before: typing again would be the loop this job must never become
        w.write_reg("c1", status="idle", statusUpdatedAt=int((w.t + 30) * 1000))
        for _ in range(4):
            w.later(120)
        self.assertEqual(len(w.typed), 1)
        self.assertEqual(w.state()["c1"]["phase"], "confirmed")

    def test_a_new_start_of_the_same_session_is_typed_again(self):
        w = self.w()
        pid = w.add("c1")
        w.go()
        w.later(60)
        self.assertEqual(w.state()["c1"]["phase"], "confirmed")
        # the session is restarted: a NEW claude process (new pid, new start) behind the same tmux session name
        w.procs[pid] = (w.t - 1, "/opt/claude")  # (kept for the old registry file, which must not match: it is older than its process now)
        pid2 = w.next_pid
        w.next_pid += 1
        sid2 = "%08d-0000-4000-8000-%012d" % (pid2, pid2)
        w.procs[pid2] = (w.t - 400, "/opt/claude")
        w.pids["c1"], w.sid["c1"], w.path["c1"] = pid2, sid2, os.path.join(w.home, ".claude/projects/p", sid2 + ".jsonl")
        put(w.path["c1"], json.dumps(user_rec("[gascity] boot prime", w.t - 395)) + "\n")
        w.write_reg("c1", pid=pid2, sessionId=sid2, kind="interactive", cwd="/x", startedAt=int((w.t - 400) * 1000), status="idle", statusUpdatedAt=int((w.t - 300) * 1000), tmux="c1:@1.%1")
        w.panes["c1"] = REAL_IDLE
        os.remove(os.path.join(w.home, ".claude/sessions/%d.json" % pid))
        w.later(60)
        self.assertEqual(len(w.typed), 2)

    def test_a_recycled_pid_after_a_reboot_does_not_inherit_the_old_start_record(self):
        w = self.w()
        pid = w.add("c1")
        w.go()
        w.later(60)
        self.assertEqual(w.state()["c1"]["phase"], "confirmed")
        # a day later, after a reboot, the new claude happens to get the SAME pid: only its start time tells the two apart
        w.t += 86400
        w.procs[pid] = (w.t - 400, "/opt/claude")
        w.write_reg("c1", startedAt=int((w.t - 400) * 1000), status="idle", statusUpdatedAt=int((w.t - 300) * 1000))
        w.panes["c1"] = REAL_IDLE
        w.go()
        self.assertEqual(len(w.typed), 2)

    def test_a_lost_state_file_is_harmless_and_is_written_again(self):
        for junk in ("{not json", "[]", '{"v": 1, "beads": 3}', ""):
            w = self.w()
            w.add("c1")
            put(os.path.join(w.city, ".gc/boot-first-turn.state.json"), junk)
            self.assertEqual(w.go(), 0, junk)
            self.assertEqual(len(w.typed), 1, junk)
            self.assertEqual(w.state()["c1"]["phase"], "sent", junk)

    def test_the_record_is_saved_before_the_pass_ends_and_forgets_sessions_that_left_the_roster(self):
        w = self.w()
        w.add("c1")
        put(os.path.join(w.city, ".gc/boot-first-turn.state.json"), json.dumps({"v": 1, "targets": {"gone-1": {"pid": 1, "start": 1.0, "phase": "confirmed"}}}))
        w.go()
        self.assertEqual(sorted(w.state()), ["c1"])


class Proof(Base):
    def typed_but_nothing_visible(self):
        w = self.w()
        w.add("c1")
        w.lost_keys = True  # the keys go nowhere, so only what a test does by hand can prove life
        w.go()
        self.assertEqual(len(w.typed), 0)  # (lost_keys swallows them before the fake records a typing)
        return w

    def test_a_turn_that_started_is_proven_by_the_transcript_the_registry_and_the_pane(self):
        for how, effect in (
                ("transcript", lambda w, text: w.append("c1", user_rec(text, w.t + 5))),
                ("registry", lambda w, text: w.write_reg("c1", status="busy", statusUpdatedAt=int((w.t + 5) * 1000))),
                ("registry", lambda w, text: w.write_reg("c1", status="idle", statusUpdatedAt=int((w.t + 5) * 1000))),  # a quick turn: over again before the next pass
                ("pane", lambda w, text: w.panes.__setitem__("c1", "* Pondering… (3s · ↓ 1k tokens)\n" + REAL_IDLE)),
                ("conversation", lambda w, text: w.write_reg("c1", sessionId="%08d-0000-4000-8000-%012d" % (9, 9)))):
            w = self.w()
            w.add("c1")
            w.lost_keys = False
            sent = []
            real_run = w.run

            def run(argv, timeout, env=None, w=w, real_run=real_run, sent=sent):
                out = real_run(argv, timeout, env)
                if argv[-2:-1] == ["-l"]:
                    sent.append(argv[-1])
                return out
            w.run = run
            w.drop_enters = 1  # the Enter is swallowed, so nothing started by itself: the effect under test is the only sign of life
            w.go()
            effect(w, sent[0])
            w.later(60)
            st = w.state()["c1"]
            self.assertEqual(st["phase"], "confirmed", how)
            self.assertEqual(st["how"], how, how)
            rec = w.results()[-1]
            self.assertEqual((rec["result"], rec["how"], rec["target"]), ("confirmed", how, "c1"))
            self.assertEqual(len(w.typed), 1, how)  # proven: no retry


class Retry(Base):
    def test_a_typed_line_that_shows_no_life_is_typed_again_once_when_the_pane_is_idle_and_empty(self):
        w = self.w()
        w.add("c1")
        w.lost_keys = True
        w.go()
        w.lost_keys = False
        w.later(60)  # not yet: the retry waits BFT_RETRY_S (90) after the typing
        self.assertEqual((len(w.typed), len(w.enters)), (0, 0))
        w.later(60)
        self.assertEqual(len(w.typed), 1)
        self.assertEqual(w.counts["pending"], 1)  # the pass that retries is a pending pass too
        w.later(60)
        self.assertEqual(w.state()["c1"]["phase"], "confirmed")
        self.assertEqual(w.state()["c1"]["how"] in ("transcript", "registry", "pane"), True)
        self.assertEqual(w.results()[-1]["via"], "tmux+retry")

    def test_text_left_in_the_input_box_gets_only_the_enter(self):
        w = self.w()
        w.add("c1")
        w.drop_enters = 1
        w.go()
        self.assertEqual((len(w.typed), len(w.enters)), (1, 1))
        w.later(60)
        self.assertEqual((len(w.typed), len(w.enters)), (1, 1))
        w.later(60)  # 120 s after the typing: the pane shows OUR text still in the box
        self.assertEqual((len(w.typed), len(w.enters)), (1, 2))
        w.later(60)
        self.assertEqual(w.state()["c1"]["phase"], "confirmed")
        self.assertEqual(w.results()[-1]["via"], "tmux+enter")

    def test_somebody_elses_draft_is_never_submitted_by_the_retry(self):
        w = self.w()
        w.add("c1")
        w.lost_keys = True
        w.go()
        w.panes["c1"] = real_pane(prompt="❯ half a message from a person")
        w.later(120)
        self.assertEqual(len(w.keys), 2)  # the first typing (text + Enter) and NOTHING after it: no retyping, no Enter into somebody else's draft
        self.assertIn("RETRY-SKIPPED", w.log())

    def test_a_retry_into_a_dialog_or_an_unreadable_pane_types_nothing(self):
        for pane in ("Do you want to proceed?\n❯ 1. Yes\n", "$ ls\n"):
            w = self.w()
            w.add("c1")
            w.lost_keys = True
            w.go()
            w.panes["c1"] = pane
            w.later(120)
            self.assertEqual(len(w.keys), 2, pane)
            self.assertIn("RETRY-SKIPPED", w.log(), pane)


class GiveUp(Base):
    def silent_session(self):
        w = self.w()
        w.add("c1")
        w.lost_keys = True
        return w

    def test_no_proof_after_the_retry_is_loud_in_the_log_the_jsonl_and_the_phone_once(self):
        w = self.silent_session()
        w.go()
        first_note_at = None
        for _ in range(12):
            w.later(60)
            if w.notes and first_note_at is None:
                first_note_at = w.t
        self.assertEqual(len(w.notes), 1)
        argv = w.notes[0]
        self.assertEqual(argv[:4], ["notify", "-p", "4", "-t"])
        self.assertIn("c1", argv[5])
        self.assertIn("tmux -L gascity attach -t c1", argv[5])
        self.assertLess(len(argv[5]), 200)
        self.assertEqual(w.note_env[0], {"NOTIFY_STRICT_EXIT": "1", "NOTIFY_FORCE_PUSH": "1"})
        recs = w.results()
        self.assertEqual([r["result"] for r in recs], ["unconfirmed"])
        self.assertEqual(recs[0]["target"], "c1")
        self.assertIn("ERROR", w.log())
        self.assertEqual(w.state()["c1"]["phase"], "gave-up")
        self.assertGreaterEqual(first_note_at - (T0 + 120), 240)  # 240 s after the retry, not before
        for _ in range(3):
            w.later(60)
        self.assertEqual((len(w.notes), len(w.results())), (1, 1))  # terminal: no more passes of it

    def test_a_notify_that_fails_is_retried_on_the_next_passes_at_most_three_times(self):
        w = self.silent_session()
        w.notify_rc = 1
        w.go()
        for _ in range(20):
            w.later(60)
        self.assertEqual(len(w.notes), 3)
        self.assertIn("NOTIFY-FAILED", w.log())
        w2 = self.silent_session()
        w2.notify_rc = 10  # notify's own "delivered by the fallback" codes count as delivered
        w2.go()
        for _ in range(20):
            w2.later(60)
        self.assertEqual(len(w2.notes), 1)

    def test_a_session_that_restarted_before_the_proof_is_forgotten_not_alarmed(self):
        w = self.silent_session()
        w.go()
        w.later(60)
        pid = w.pids["c1"]
        del w.procs[pid]  # the claude died: nobody to wake, and the next one is a new start that gets its own turn
        for _ in range(8):
            w.later(60)
        self.assertEqual(w.notes, [])


class StateFreeDedup(Base):
    def test_a_transcript_that_already_shows_our_line_since_this_start_is_not_typed_into_again(self):
        w = self.w()
        w.add("c1", recs=[user_rec("[gascity] boot prime", T0 - 590), user_rec(B.compose([]), T0 - 200), asst_rec(T0 - 190)])
        w.go()
        self.assertEqual(w.typed, [])
        self.assertEqual(w.state()["c1"]["phase"], "confirmed")
        self.assertEqual(w.state()["c1"]["how"], "transcript (found without a record)")

    def test_our_line_from_an_earlier_boot_of_a_resumed_conversation_does_not_count(self):
        # the resumed conversation carries the line the previous boot typed; this process started later and must get its own
        w = self.w()
        w.add("c1", recs=[user_rec(B.compose([]), T0 - 86400), asst_rec(T0 - 86300), user_rec("[gascity] boot prime", T0 - 590)])
        w.go()
        self.assertEqual(len(w.typed), 1)


class DryRun(Base):
    def test_dry_run_reads_everything_and_changes_nothing(self):
        w = self.w()
        w.add("c1")
        self.assertEqual(w.go(dry=True), 0)
        self.assertEqual((w.typed, w.enters, w.notes, w.state(), w.results(), w.log()), ([], [], [], None, [], ""))
        self.assertIn("WOULD type", w.out)
        self.assertEqual(w.counts["typed"], 1)


class SteadyState(Base):
    def test_a_machine_where_nothing_started_lately_costs_no_bd_gc_ps_or_tmux_call(self):
        w = self.w()
        w.add("mayor-1", template="gastown.mayor", crew=False, age=3 * 86400)
        w.add("thies-wa-gawispaaa", age=10800)
        self.assertEqual(w.go(), 0)
        self.assertEqual(w.calls, [])
        self.assertEqual((w.counts["targets"], w.typed), (0, []))
        self.assertEqual(w.log(), "")

    def test_a_registry_entry_with_no_readable_start_does_not_hide_a_fresh_session(self):
        w = self.w()
        w.add("c1", startedAt=None)
        w.go()
        self.assertEqual(len(w.typed), 1)
        w = self.w()
        w.add("c1", startedAt="yesterday")
        w.go()
        self.assertEqual(len(w.typed), 1)

    def test_one_fresh_session_wakes_the_pass_and_the_old_ones_are_told_once_and_quietly(self):
        w = self.w()
        w.add("thies-wa-gawispaaa", age=10800)
        w.add("peter-wa-gawispbbb", template="peter-wa", age=400)
        w.go()
        self.assertEqual([n for n, _ in w.typed], ["peter-wa-gawispbbb"])
        self.assertEqual(w.counts["late"], 1)
        first = w.log().count("LATE")
        self.assertEqual(first, 1)
        w.later(60)
        self.assertEqual(w.log().count("LATE"), 1)  # the same reading is not told again every minute
        self.assertNotIn("10800", w.log())  # and the line carries nothing that changes by itself

    def test_a_pending_proof_keeps_the_pass_alive_after_the_window_closes(self):
        w = self.w(BFT_WINDOW_S="400")
        w.add("c1", age=390)
        w.go()
        self.assertEqual(len(w.typed), 1)
        w.later(60)  # the process is 450 s old now: past the window, but its line has not been proven yet
        self.assertEqual(w.state()["c1"]["phase"], "confirmed")
        w = self.w(BFT_WINDOW_S="400")
        w.add("c1", age=390)
        w.lost_keys = True
        w.go()
        for _ in range(8):
            w.later(60)
        self.assertEqual(w.state()["c1"]["phase"], "gave-up")  # the follow-up ran well past the window
        self.assertEqual(len(w.notes), 1)

    def test_a_gave_up_session_whose_alarm_failed_is_still_retried_after_the_window(self):
        w = self.w(BFT_WINDOW_S="400")
        w.add("c1", age=390)
        w.lost_keys = True
        w.notify_rc = 1
        w.go()
        for _ in range(40):
            w.later(60)
        self.assertEqual(len(w.notes), 3)

    def test_unconfirmed_is_a_gauge_of_the_sessions_still_without_proof(self):
        w = self.w()
        w.add("c1")
        w.lost_keys = True
        w.go()
        for _ in range(8):
            w.later(60)
        self.assertEqual(w.counts["unconfirmed"], 1)


def bead(i, who, status="in_progress"):
    return {"id": i, "assignee": who, "status": status}


class Ids(Base):
    RIG = "/Users/athos/gt/whatsapp_automation"

    def lists(self, w):
        return [c for c in w.calls if c[0] == "bd" and "list" in c]

    def test_the_line_names_the_in_progress_beads_of_this_session_and_only_those(self):
        w = self.w()
        w.add("thies-wa-gawispaaa")
        w.inprog = {w.city: [bead("ga-1", "thies-wa")],
                    self.RIG: [bead("wa-9", "thies-wa-gawispaaa"), bead("wa-10", "thies-wa-gawisp0old"),  # its own session name, and an earlier incarnation of the crew
                               bead("wa-11", "peter-wa"), bead("wa-12", "thies-wa-gate-reviewer"), bead("wa-13", "thies-wa-gawisp"), bead("wa-14", "xthies-wa")]}  # not its: another crew, a different role, no tail, a longer name
        w.go()
        self.assertIn("retome a bead em andamento ga-1, wa-10, wa-9 e o último handoff", w.typed[0][1])
        self.assertEqual(w.state()["thies-wa-gawispaaa"]["ids"], ["ga-1", "wa-10", "wa-9"])
        self.assertEqual([c[:4] for c in self.lists(w)], [["bd", "-C", w.city, "list"], ["bd", "-C", self.RIG, "list"]])
        self.assertEqual(self.lists(w)[0][4:], ["--status", "in_progress", "--json", "--limit", "0"])

    def test_the_mayor_reads_only_the_city_store_and_answers_to_its_names(self):
        w = self.w()
        w.add("mayor-1", template="gastown.mayor", crew=False)
        w.inprog = {w.city: [bead("ga-5", "mayor"), bead("ga-6", "gastown.mayor"), bead("ga-7", "mayor/"), bead("ga-8", "mayor-1"), bead("ga-9", "thies-wa")]}
        w.go()
        self.assertEqual(len(self.lists(w)), 1)
        self.assertIn("retome a bead em andamento ga-5, ga-6, ga-7, ga-8 e", w.typed[0][1])

    def test_a_store_that_cannot_be_read_names_nothing_from_it_but_never_blocks_or_claims_none(self):
        w = self.w()
        w.add("thies-wa-gawispaaa")
        w.inprog = {w.city: [bead("ga-1", "thies-wa")], self.RIG: None}
        w.go()
        self.assertEqual(len(w.typed), 1)
        self.assertIn("retome a bead em andamento ga-1 e", w.typed[0][1])
        w = self.w()
        w.add("thies-wa-gawispaaa")
        w.inprog = {w.city: None, self.RIG: None}
        w.go()
        self.assertEqual(len(w.typed), 1)
        self.assertIn("a bead que estiver em andamento com você (confira com bd list --status in_progress)", w.typed[0][1])
        self.assertEqual(w.state()["thies-wa-gawispaaa"]["ids"], [])

    def test_garbage_from_bd_is_unreadable_not_empty(self):
        for junk in ("not json", "{}", '"x"', "[1, {\"id\": 2}, null, {\"id\": \"ok-1\", \"assignee\": \"thies-wa\"}]"):
            w = self.w()
            w.add("thies-wa-gawispaaa")
            w.forced["bd -C %s list" % w.city] = (0, junk, "")
            w.go()
            self.assertEqual(len(w.typed), 1, junk)
        self.assertIn("ok-1", w.typed[0][1])  # a malformed row is skipped, the good one in the same list still counts

    def test_each_store_is_read_once_per_pass_even_for_several_crews(self):
        w = self.w()
        w.add("thies-wa-gawispaaa")
        w.add("peter-wa-gawispbbb", template="peter-wa")
        w.inprog = {self.RIG: [bead("wa-1", "peter-wa"), bead("wa-2", "thies-wa")]}
        w.go()
        self.assertEqual(len(self.lists(w)), 2)  # the city store and the rig store, each once
        by = dict(w.typed)
        self.assertIn("andamento wa-2 e", by["thies-wa-gawispaaa"])
        self.assertIn("andamento wa-1 e", by["peter-wa-gawispbbb"])

    def test_the_retry_types_the_very_same_line(self):
        w = self.w()
        w.add("thies-wa-gawispaaa")
        w.inprog = {self.RIG: [bead("wa-2", "thies-wa")]}
        w.lost_keys = True
        w.go()
        w.lost_keys = False
        w.inprog = {self.RIG: []}  # the beads changed meanwhile: the retry must not invent another text
        w.later(60)
        w.later(60)
        self.assertEqual(len(w.typed), 1)
        self.assertIn("andamento wa-2 e", w.typed[0][1])


class Main(Base):
    def main(self, w, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = B.main(list(argv), w.env, w)
        return code, out.getvalue(), err.getvalue()

    def test_one_summary_line_and_exit_zero(self):
        w = self.w()
        w.add("thies-wa-gawispaaa")
        w.add("peter-wa-gawispbbb", template="peter-wa", age=5000)
        code, out, _ = self.main(w)
        self.assertEqual(code, 0)
        self.assertEqual(out, "boot-first-turn: alvos=2 digitou=1 confirmou=0 pendente=0 sem-prova=0 espera=0 tarde=1 nao-sei=0 ausente=0\n")
        self.assertEqual(len(w.typed), 1)

    def test_a_steady_machine_still_prints_its_one_line(self):
        w = self.w()
        w.add("c1", age=86400)
        code, out, _ = self.main(w)
        self.assertEqual((code, out), (0, "boot-first-turn: alvos=0 digitou=0 confirmou=0 pendente=0 sem-prova=0 espera=0 tarde=0 nao-sei=0 ausente=0\n"))

    def test_dry_run_and_usage(self):
        w = self.w()
        w.add("c1")
        code, out, _ = self.main(w, "--dry-run")
        self.assertEqual((code, w.typed, w.state()), (0, [], None))
        self.assertIn("WOULD type", out)
        self.assertIn("(dry-run)", out)
        for bad in (["--final"], ["--dry-run", "--dry-run"], ["x"], ["--dry-run", "x"]):
            code, out, err = self.main(self.w(), *bad)
            self.assertEqual((code, out), (2, ""), bad)
            self.assertIn("usage: boot-first-turn.py [--dry-run]", err)

    def test_the_kill_switches_are_checked_before_anything_is_read_or_typed(self):
        w = self.w(BFT_ENABLED="0")
        w.add("c1")
        code, out, _ = self.main(w)
        self.assertEqual((code, w.calls, w.typed), (0, [], []))
        self.assertIn("desligado", out)
        w = self.w()
        w.add("c1")
        put(os.path.join(w.city, ".gc/boot-first-turn.off"), "")
        code, out, _ = self.main(w)
        self.assertEqual((code, w.calls, w.typed), (0, [], []))
        self.assertIn("desligado", out)

    def test_a_kill_switch_that_cannot_be_read_means_off_not_on(self):
        w = self.w()
        w.add("c1")
        off = os.path.join(w.city, ".gc/boot-first-turn.off")
        os.symlink(off, off)  # a symlink loop: stat fails with ELOOP, which is not "no such file"
        code, out, _ = self.main(w)
        self.assertEqual((code, w.typed), (0, []))
        self.assertIn("desligado", out)

    def test_a_second_instance_leaves_at_once_with_4(self):
        import fcntl
        w = self.w()
        w.add("c1")
        with open(os.path.join(w.city, ".gc/boot-first-turn.lock"), "a") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            code, out, _ = self.main(w)
        self.assertEqual((code, w.typed, w.calls), (4, [], []))
        self.assertIn("outra instância em curso", out)

    def test_a_lock_that_cannot_be_opened_is_3_and_types_nothing(self):
        w = self.w()
        w.add("c1")
        os.mkdir(os.path.join(w.city, ".gc/boot-first-turn.lock"))
        code, out, _ = self.main(w)
        self.assertEqual((code, w.typed), (3, []))
        self.assertIn("NÃO consegui abrir a trava", out)

    def test_a_pass_that_cannot_evaluate_exits_3_and_says_where_to_look(self):
        w = self.w()
        w.add("c1")
        w.forced["bd -C %s query" % w.city] = (1, "", "dolt down")
        w.forced["gc --city %s" % w.city] = (None, "", "")
        code, out, _ = self.main(w)
        self.assertEqual((code, w.typed), (3, []))
        self.assertIn("NÃO consegui avaliar (ver %s)" % w.cfg.log, out)
        self.assertIn("ERROR", w.log())

    def test_the_roster_falls_back_to_gc_when_the_beads_cannot_be_queried(self):
        w = self.w()
        w.add("c1")
        w.forced["bd -C %s query" % w.city] = (1, "", "dolt down")
        code, _, _ = self.main(w)
        self.assertEqual((code, len(w.typed)), (0, 1))
        self.assertTrue(any(c[:5] == ["gc", "--city", w.city, "session", "list"] for c in w.calls))


class Defaults(unittest.TestCase):
    def test_the_defaults_and_what_a_bad_value_falls_back_to(self):
        c = B.Cfg({})
        self.assertEqual((c.window_s, c.idle_s, c.retry_s, c.give_up_s, c.budget_s), (1200, 120, 90, 240, 100))
        self.assertEqual(c.tmux, ["tmux", "-L", "gascity"])  # the city's tmux server, the one live-conversation-capture and nightly-session-compact already talk to
        self.assertEqual((c.city, c.notify, c.enabled), ("/Users/athos/gt/.gascity-gastown-hq", "notify", True))
        c = B.Cfg({"BFT_WINDOW_S": "600", "BFT_IDLE_S": "0", "BFT_RETRY_S": "-5", "BFT_GIVE_UP_S": "abc", "BFT_TMUX_SOCKET": "other", "BFT_ENABLED": "0"})
        self.assertEqual((c.window_s, c.idle_s, c.retry_s, c.give_up_s, c.tmux[-1], c.enabled), (600, 120, 90, 240, "other", False))

    def test_the_pass_budget_is_not_longer_than_a_few_launchd_intervals_and_the_retry_comes_first(self):
        c = B.Cfg({})
        self.assertLess(c.retry_s, c.retry_s + c.give_up_s)
        self.assertLessEqual(c.budget_s, 120)


class RealTmux(unittest.TestCase):
    """The typing sequence against a REAL tmux server on a private socket, started with an EMPTY environment (no locale), as a server spawned by launchd is: the accented line has to arrive whole and Enter has to submit it."""
    def test_the_line_arrives_whole_and_enter_submits_it(self):
        tmux = shutil.which("tmux")
        if not tmux:
            self.skipTest("tmux is not installed")
        d = tempfile.mkdtemp(prefix="bft-tmux-")
        self.addCleanup(shutil.rmtree, d, True)
        script = os.path.join(d, "echo_lines.py")
        put(script, 'import sys\nprint("READY", flush=True)\nfor line in sys.stdin:\n    print("GOT<%s>" % line.rstrip("\\n"), flush=True)\n')
        sock = "bft-%d-%d" % (os.getpid(), int(time.time() * 1000) % 100000)
        env = {"PATH": "/usr/bin:/bin:" + os.path.dirname(tmux)}
        subprocess.run([tmux, "-L", sock, "new-session", "-d", "-s", "c1", "-x", "200", "-y", "50", "%s -I %s" % (sys.executable, script)], env=env, check=True)
        sock_path = subprocess.run([tmux, "-L", sock, "display-message", "-p", "-t", "c1", "#{socket_path}"], capture_output=True, text=True, env=env).stdout.strip()
        self.addCleanup(lambda: os.path.exists(sock_path) and os.unlink(sock_path))  # runs last: tmux leaves its socket file behind after kill-server
        self.addCleanup(lambda: subprocess.run([tmux, "-L", sock, "kill-server"], capture_output=True, env=env))
        cfg, real = B.Cfg({"GC_CITY_PATH": d, "BFT_TMUX": tmux, "BFT_TMUX_SOCKET": sock}), B.RealIO()

        def wait_for(needle):
            end = time.time() + 15
            while time.time() < end:
                st, why, text = B.peek(real, cfg, "c1", 5)
                if needle in text:
                    return text
                time.sleep(0.1)
            self.fail("%r never showed in the pane" % needle)
        wait_for("READY")
        line = B.compose(["wa-1", "wa-2"])
        self.assertEqual(B.type_line(real, cfg, "c1", line, 5), ("done", ""))
        self.assertIn("GOT<%s>" % line, wait_for("GOT<").replace("\n", ""))  # whole, accents and all, and submitted: the program got a finished line
        st, why, _ = B.peek(real, cfg, "nope", 5)
        self.assertEqual(st, "unknown")
        self.assertIn("can't find session", why)
        self.assertEqual(B.type_line(real, cfg, "nope", "x", 5)[0], "text-failed")


HQ = os.path.dirname(os.path.dirname(os.path.abspath(SUT)))  # <repo>/.gascity-gastown-hq when the suite runs from the repo (a mutant copy elsewhere skips the delivery checks)


@unittest.skipUnless(os.path.exists(os.path.join(HQ, "packs/town-deltas/assets/boot-first-turn.plist")) or not os.environ.get("BFT_UNDER_TEST"), "delivery files are checked against the repo copy")
class Delivery(unittest.TestCase):
    def test_the_plist_runs_this_script_every_minute_and_once_at_load(self):
        import plistlib
        with open(os.path.join(HQ, "packs/town-deltas/assets/boot-first-turn.plist"), "rb") as fh:
            pl = plistlib.load(fh)
        self.assertEqual(pl["Label"], "com.gascity.boot-first-turn")
        self.assertEqual(pl["ProgramArguments"], ["/usr/bin/python3", "/Users/athos/gt/.gascity-gastown-hq/scripts/boot-first-turn.py"])
        self.assertEqual((pl["StartInterval"], pl["RunAtLoad"]), (60, True))
        self.assertNotIn("KeepAlive", pl)
        env = pl["EnvironmentVariables"]
        self.assertEqual((env["HOME"], env["GC_CITY_PATH"], env["BEADS_DOLT_AUTO_START"]), ("/Users/athos", "/Users/athos/gt/.gascity-gastown-hq", "0"))
        for need in ("/opt/homebrew/bin", "/Users/athos/.local/bin", "/usr/bin"):  # tmux, notify and ps are found from launchd's thin PATH
            self.assertIn(need, env["PATH"].split(":"))
        self.assertTrue(pl["StandardOutPath"].startswith("/Users/athos/gt/.gascity-gastown-hq/.gc/logs/boot-first-turn"))
        self.assertTrue(pl["StandardErrorPath"].startswith("/Users/athos/gt/.gascity-gastown-hq/.gc/logs/boot-first-turn"))

    def test_the_mini64_table_gives_the_job_its_own_line_in_layer_1(self):
        # scripts/mini64/mini64.selftest.sh S6: every plist of the repo needs a line of its own, or the 64 GB migration refuses the table
        with open(os.path.join(HQ, "scripts/mini64/camadas.tsv"), encoding="utf-8") as fh:
            rows = [ln.rstrip("\n").split("\t") for ln in fh if ln.startswith("com.gascity.boot-first-turn")]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][:2], ["com.gascity.boot-first-turn", "1"])
        self.assertTrue(rows[0][2].strip())

    def test_the_runbook_exists_and_starts_with_its_contents(self):
        with open(os.path.join(HQ, "docs/runbooks/boot-primeiro-turno.md"), encoding="utf-8") as fh:
            text = fh.read()
        self.assertTrue(text.startswith("## Contents"))  # Athos 11/10: every document over 300 characters opens with its index
        for need in ("boot-first-turn.off", "--dry-run", "launchctl", "tmux -L gascity", "ga-esorlre.14", "ga-esorlre.15", "NÃO provado ao vivo"):
            self.assertIn(need, text)

    def test_the_script_header_documents_the_contract(self):
        with open(SUT, encoding="utf-8") as fh:
            head = fh.read(9000)
        for need in ("WHY", "THREE STATES", "KNOBS", "EXIT", "ga-esorlre.13"):
            self.assertIn(need, head)


class Robustness(Base):
    def test_a_start_record_survives_the_session_leaving_the_roster_for_one_pass(self):
        w = self.w()
        w.add("c1")
        w.lost_keys = True
        w.go()
        row = w.roster[0]
        w.roster[0] = dict(row, metadata=dict(row["metadata"], state="asleep"))  # the session bead flickers out of "active" for a pass
        w.later(60)
        self.assertIn("c1", w.state())
        w.roster[0] = row
        w.lost_keys = False
        w.later(30)  # 90 s after the typing: the record goes on to its retry; a forgotten record would type a brand new first turn instead
        self.assertEqual((len(w.typed), w.state()["c1"]["via"], w.state()["c1"]["retried"]), (1, "tmux+retry", True))

    def test_old_records_are_forgotten_by_age_not_by_roster(self):
        w = self.w()
        w.add("c1", age=400)
        old = {"pid": 1, "start": T0 - 9 * 86400, "phase": "confirmed", "sid": "s", "sent_at": T0 - 9 * 86400}
        fresh = {"pid": 2, "start": T0 - 86400, "phase": "confirmed", "sid": "s", "sent_at": T0 - 86400}
        put(os.path.join(w.city, ".gc/boot-first-turn.state.json"), json.dumps({"v": 1, "targets": {"old-1": old, "fresh-1": fresh}}))
        w.go()
        self.assertEqual(sorted(w.state()), ["c1", "fresh-1"])

    def test_malformed_records_in_the_state_file_are_dropped_not_a_crash(self):
        for bad in ({"pid": 41000, "start": T0 - 600, "phase": "sent"},  # no sid, no sent_at
                    {"pid": "x", "start": T0 - 600, "phase": "sent", "sid": "s", "sent_at": T0},
                    {"pid": 41000, "start": T0 - 600, "phase": "weird", "sid": "s", "sent_at": T0},
                    {"pid": 41000, "start": "soon", "phase": "sent", "sid": "s", "sent_at": T0},
                    {"pid": 41000, "start": T0 - 600, "phase": "sent", "sid": "s", "sent_at": None}):
            w = self.w()
            w.add("c1")
            put(os.path.join(w.city, ".gc/boot-first-turn.state.json"), json.dumps({"v": 1, "targets": {"c1": bad}}))
            self.assertEqual(w.go(), 0, bad)
            self.assertEqual(len(w.typed), 1, bad)  # an unreadable record is no record: the start gets its line

    def test_a_surprise_in_one_target_does_not_blind_the_others(self):
        w = self.w()
        w.add("c1")
        w.add("c2", template="peter-wa")
        real_run = w.run

        def run(argv, timeout, env=None):
            if "capture-pane" in argv and "=c1:" in argv:
                raise RuntimeError("boom")
            return real_run(argv, timeout, env)
        w.run = run
        self.assertEqual(w.go(), 0)
        self.assertEqual([n for n, _ in w.typed], ["c2"])
        self.assertEqual(w.counts["unknown"], 1)
        self.assertIn("unexpected RuntimeError", w.log())

    def test_a_stale_pending_record_does_not_keep_the_pass_awake_forever(self):
        for rec in ({"pid": 1, "start": T0 - 8000, "phase": "sent", "sid": "s", "sent_at": T0 - 7200},
                    {"pid": 1, "start": T0 - 8000, "phase": "gave-up", "sid": "s", "sent_at": T0 - 7500, "gave_up_at": T0 - 7200, "notified": False, "notify_tries": 1}):
            w = self.w()
            w.add("c1", age=86400)
            put(os.path.join(w.city, ".gc/boot-first-turn.state.json"), json.dumps({"v": 1, "targets": {"gone-1": rec}}))
            w.go()
            self.assertEqual(w.calls, [], rec["phase"])

    def test_the_pane_is_read_again_right_before_typing_and_a_change_cancels_it(self):
        w = self.w()
        w.add("c1")
        w.on_bd_list = lambda: w.panes.__setitem__("c1", real_pane(prompt="❯ half a message"))  # a person starts typing while the bead lookups run
        w.go()
        self.assertEqual((w.typed, w.counts["wait"], w.counts["typed"]), ([], 1, 0))
        self.assertIn("the input box holds text", w.log())
        self.assertNotIn("c1", w.state() or {})  # nothing was typed, so there is no record: the next pass judges it afresh

    def test_a_crew_whose_agent_toml_cannot_be_read_is_told_and_the_others_still_get_their_line(self):
        if os.geteuid() == 0:
            self.skipTest("root reads anything")
        w = self.w()
        w.add("c1")
        w.add("c2", template="peter-wa")
        toml = os.path.join(w.city, "agents", "thies-wa", "agent.toml")
        os.chmod(toml, 0)
        self.addCleanup(os.chmod, toml, 0o644)
        w.go()
        self.assertEqual([n for n, _ in w.typed], ["c2"])
        self.assertIn("thies-wa", w.log())
        self.assertIn("agent.toml", w.log())
        self.assertIn("not a target", w.log())


class MoreGaps(Base):
    """each test here exists because a one-line mutant of the script survived without it."""
    def test_the_give_up_clock_starts_at_the_retry_even_when_the_retry_was_skipped(self):
        w = self.w()
        w.add("c1")
        w.lost_keys = True
        w.go()
        w.panes["c1"] = "Do you want to proceed?\n❯ 1. Yes\n"  # a dialog: the retry has nothing safe to do
        w.later(120)  # the retry moment: skipped
        self.assertIn("RETRY-SKIPPED", w.log())
        for _ in range(3):  # +180, +240, +300: more than give_up_s after the FIRST typing, less than give_up_s after the skipped retry
            w.later(60)
            self.assertEqual((w.state()["c1"]["phase"], w.notes), ("sent", []))
        w.later(60)  # +360: give_up_s (240) after the skipped retry
        w.later(60)
        self.assertEqual(w.state()["c1"]["phase"], "gave-up")
        self.assertEqual(len(w.notes), 1)

    def test_a_fresh_helper_that_is_not_interactive_does_not_wake_the_pass(self):
        w = self.w()
        w.add("thies-wa-gawispaaa", age=10800)
        w.add("helper", kind="sdk-cli", age=60, template="peter-wa")
        w.go()
        self.assertEqual(w.calls, [])

    def test_a_text_that_could_not_be_typed_leaves_no_record_and_no_enter(self):
        w = self.w()
        w.add("c1")
        w.forced["tmux -L gascity send-keys"] = (1, "", "no space")
        self.assertEqual(w.go(), 0)
        self.assertEqual((len(w.tmux_calls("send-keys")), w.counts["unknown"], w.counts["typed"]), (1, 1, 0))  # the text failed: no Enter after it
        self.assertIn("TYPE-FAILED", w.log())
        self.assertNotIn("c1", w.state() or {})
        del w.forced["tmux -L gascity send-keys"]
        w.later(60)
        self.assertEqual(len(w.typed), 1)  # the next pass simply tries again

    def test_an_enter_that_failed_leaves_our_line_in_the_box_and_the_retry_finishes_it(self):
        w = self.w()
        w.add("c1")
        w.fail_enter = True
        w.go()
        self.assertEqual((len(w.typed), w.state()["c1"]["phase"]), (1, "sent"))
        self.assertIn("the line waits in the input box", w.log())
        w.fail_enter = False
        w.later(120)
        self.assertEqual(len(w.typed), 1)  # not typed a second time: only the Enter
        w.later(60)
        self.assertEqual((w.state()["c1"]["phase"], w.results()[-1]["via"]), ("confirmed", "tmux+enter"))

    def test_a_restart_within_seconds_is_still_a_new_start(self):
        w = self.w()
        pid = w.add("c1")
        w.go()
        w.later(60)
        self.assertEqual(w.state()["c1"]["phase"], "confirmed")
        old_start = w.procs[pid][0]
        del w.procs[pid]
        os.remove(os.path.join(w.home, ".claude/sessions/%d.json" % pid))
        pid2 = w.next_pid
        w.next_pid += 1
        sid2 = "%08d-0000-4000-8000-%012d" % (pid2, pid2)
        w.procs[pid2] = (old_start + 10, "/opt/claude")  # another claude, born ten seconds after the first one
        w.pids["c1"], w.sid["c1"], w.path["c1"] = pid2, sid2, os.path.join(w.home, ".claude/projects/p", sid2 + ".jsonl")
        put(w.path["c1"], json.dumps(user_rec("[gascity] boot prime", old_start + 15)) + "\n")
        w.write_reg("c1", pid=pid2, sessionId=sid2, kind="interactive", cwd="/x", startedAt=int((old_start + 10) * 1000), status="idle", statusUpdatedAt=int((w.t - 300) * 1000), tmux="c1:@1.%1")
        w.panes["c1"] = REAL_IDLE
        w.later(60)
        self.assertEqual(len(w.typed), 2)

    def test_what_does_not_prove_that_this_start_got_its_line(self):
        for why, recs in (("a user record with a time that cannot be read", [dict(user_rec(B.compose([]), 0), timestamp="garbage")]),
                          ("a user record with no time at all", [{"type": "user", "message": {"role": "user", "content": B.compose([])}}]),
                          ("the assistant quoting the line", [asst_rec(T0 - 300, B.TAG + " quoted")]),
                          ("a tool result that quotes the line", [{"type": "user", "timestamp": iso(T0 - 300), "message": {"content": [{"type": "tool_result", "content": B.TAG}]}}])):
            w = self.w()
            w.add("c1", recs=[user_rec("[gascity] boot prime", T0 - 590)] + recs)
            w.go()
            self.assertEqual(len(w.typed), 1, why)

    def test_a_proof_needs_the_registry_status_alone_and_nothing_older_than_the_typing(self):
        for status in ("busy", "waiting"):
            w = self.w()
            w.add("c1")
            w.lost_keys = True
            w.go()
            w.write_reg("c1", status=status)  # the status word says it; the stamp is the old one
            w.later(60)
            self.assertEqual((w.state()["c1"]["phase"], w.state()["c1"]["how"]), ("confirmed", "registry"), status)
        w = self.w()
        w.add("c1", recs=[user_rec(B.compose([]), T0 - 86400), asst_rec(T0 - 86300), user_rec("[gascity] boot prime", T0 - 590)])  # our line of an earlier boot is in the resumed conversation
        w.lost_keys = True
        w.go()
        w.later(60)
        self.assertEqual(w.state()["c1"]["phase"], "sent")  # it sits before the offset taken at the typing: no proof
        w = self.w()
        w.add("c1")
        w.lost_keys = True
        w.go()
        w.append("c1", asst_rec(w.t + 5, B.TAG + " quoted by the crew"))
        w.later(60)
        self.assertEqual(w.state()["c1"]["phase"], "sent")  # an assistant record is no proof either

    def test_the_retry_comes_before_the_give_up_whatever_the_knobs_say(self):
        w = self.w(BFT_RETRY_S="300", BFT_GIVE_UP_S="100")
        w.add("c1")
        w.lost_keys = True
        w.go()
        w.later(120)
        self.assertEqual((w.state()["c1"]["phase"], w.state()["c1"]["retried"]), ("sent", False))
        self.assertEqual(w.notes, [])

    def test_a_bead_lookup_that_could_not_be_read_is_said_in_the_log_and_an_empty_one_is_not(self):
        rig = "/Users/athos/gt/whatsapp_automation"
        w = self.w()
        w.add("c1")
        w.inprog = {w.city: [], rig: []}
        w.go()
        self.assertIn("beads in progress: none found", w.log())
        self.assertNotIn("could not read", w.log())
        for bad in (None, "garbage"):
            w = self.w()
            w.add("c1")
            if bad is None:
                w.inprog = {w.city: [], rig: None}
            else:
                w.forced["bd -C %s list" % rig] = (0, bad, "")
            w.go()
            self.assertIn("could not read: %s" % rig, w.log(), bad)
            self.assertEqual(len(w.typed), 1, bad)

    def test_dry_run_never_notifies_even_with_a_gave_up_record(self):
        w = self.w()
        pid = w.add("c1")
        rec = {"pid": pid, "start": T0 - 600, "phase": "gave-up", "sid": w.sid["c1"], "sent_at": T0 - 500, "typed_at": T0 - 400, "gave_up_at": T0 - 100, "notified": False, "notify_tries": 0, "retried": True}
        put(os.path.join(w.city, ".gc/boot-first-turn.state.json"), json.dumps({"v": 1, "targets": {"c1": rec}}))
        w.go(dry=True)
        self.assertEqual((w.notes, w.typed, w.keys), ([], [], []))
        self.assertIn("says gave-up", w.out)


FAKE_CLAUDE = '\nimport json, os, sys, time, uuid\nhome, sess, cwd = os.environ["FAKE_HOME"], os.environ["FAKE_TMUX_SESSION"], os.environ["FAKE_CWD"]\npid, sid, started = os.getpid(), str(uuid.uuid4()), int(time.time() * 1000)\nreg = os.path.join(home, ".claude", "sessions", "%d.json" % pid)\ntdir = os.path.join(home, ".claude", "projects", "p")\nos.makedirs(os.path.dirname(reg), exist_ok=True)\nos.makedirs(tdir, exist_ok=True)\ntranscript = os.path.join(tdir, sid + ".jsonl")\nRULE = "-" * 60\n\n\ndef write_reg(status):\n    d = {"pid": pid, "sessionId": sid, "kind": "interactive", "cwd": cwd, "startedAt": started, "tmux": sess + ":@1.%1", "status": status, "statusUpdatedAt": int(time.time() * 1000)}\n    with open(reg + ".tmp", "w") as fh:\n        fh.write(json.dumps(d))\n    os.replace(reg + ".tmp", reg)\n\n\ndef screen(top):\n    sys.stdout.write("\\x1b[2J\\x1b[H" + top + "\\n\\n" + RULE + "\\n❯ \\n" + RULE + "\\n  [Opus 5.5] ctx: 38.0% (380k/1000k)\\n  bypass permissions on (shift+tab to cycle) · ← 1 agent\\n")\n    sys.stdout.write("\\x1b[4A\\x1b[3G")  # back up to the prompt row, right after the prompt mark: what the terminal echoes lands there, as a draft\n    sys.stdout.flush()\n\n\nwrite_reg("idle")\nscreen("Cooked for 3m 1s")\nfor line in sys.stdin:\n    write_reg("busy")\n    with open(transcript, "a") as fh:\n        fh.write(json.dumps({"type": "user", "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + ".000Z", "message": {"role": "user", "content": line.rstrip("\\n")}}) + "\\n")\n    screen("✻ Pondering… (3s · ↓ 1k tokens)")\n    time.sleep(3)\n    write_reg("idle")\n    screen("Cooked for 3s")\n'
FAKE_TOOL = '#!%s\nimport json, sys\na = sys.argv[1:]\nif "query" in a:\n    print(json.dumps([{"id": "ga-s-c1", "metadata": {"template": "thies-wa", "session_name": "c1", "state": "active"}}]))\nelif "list" in a:\n    print(json.dumps([{"id": "wa-9", "assignee": "thies-wa", "status": "in_progress"}] if a[a.index("-C") + 1].endswith("whatsapp_automation") else []))\n'


class EndToEnd(unittest.TestCase):
    """The CLI as a real subprocess (RealIO, the real ps, the lock, the state on disk) against a REAL tmux server whose pane runs a stand-in for claude: it keeps a registry file and a transcript, draws a prompt box and starts a turn
    when a line arrives. Only the claude and bd/gc are fakes; what is NOT covered is the real claude's own screen and registry semantics (see the runbook)."""
    def test_the_first_turn_is_typed_proven_and_never_typed_twice(self):
        tmux = shutil.which("tmux")
        if not tmux:
            self.skipTest("tmux is not installed")
        d = tempfile.mkdtemp(prefix="bft-e2e-")
        self.addCleanup(shutil.rmtree, d, True)
        home, city, bindir = (os.path.join(d, x) for x in ("home", "city", "bin"))
        for x in (home, os.path.join(city, ".gc/logs"), os.path.join(city, "agents/thies-wa"), bindir):
            os.makedirs(x)
        put(os.path.join(city, "agents/thies-wa/agent.toml"), 'work_dir = "/Users/athos/gt/whatsapp_automation/crew/thies-wa"\nmax_active_sessions = 1\n')
        claude = os.path.join(d, "claude")
        put(claude, FAKE_CLAUDE)
        for tool in ("bd", "gc"):
            put(os.path.join(bindir, tool), FAKE_TOOL % sys.executable)
            os.chmod(os.path.join(bindir, tool), 0o755)
        sock = "bft-e2e-%d-%d" % (os.getpid(), int(time.time() * 1000) % 100000)
        base = {"PATH": "/usr/bin:/bin:" + os.path.dirname(tmux)}
        pane_env = dict(base, FAKE_HOME=home, FAKE_TMUX_SESSION="c1", FAKE_CWD="/Users/athos/gt/whatsapp_automation/crew/thies-wa")
        subprocess.run([tmux, "-L", sock, "new-session", "-d", "-s", "c1", "-x", "120", "-y", "40", "%s -X utf8 %s" % (sys.executable, claude)], env=pane_env, check=True)
        sock_path = subprocess.run([tmux, "-L", sock, "display-message", "-p", "-t", "c1", "#{socket_path}"], capture_output=True, text=True, env=base).stdout.strip()
        self.addCleanup(lambda: os.path.exists(sock_path) and os.unlink(sock_path))
        self.addCleanup(lambda: subprocess.run([tmux, "-L", sock, "kill-server"], capture_output=True, env=base))
        env = dict(base, GC_CITY_PATH=city, BFT_HOME=home, BFT_BD=os.path.join(bindir, "bd"), BFT_GC=os.path.join(bindir, "gc"), BFT_TMUX=tmux, BFT_TMUX_SOCKET=sock, BFT_IDLE_S="1", BFT_NOTIFY="/bin/false")

        def run_pass():
            r = subprocess.run([sys.executable, "-I", SUT], env=env, capture_output=True, text=True, timeout=60)
            return r.returncode, r.stdout
        sessions = os.path.join(home, ".claude/sessions")
        end = time.time() + 15
        while time.time() < end and not (os.path.isdir(sessions) and any(f.endswith(".json") for f in os.listdir(sessions))):
            time.sleep(0.1)
        self.assertTrue(os.path.isdir(sessions) and os.listdir(sessions), "the stand-in claude never registered")
        time.sleep(2.2)  # idle for at least BFT_IDLE_S (1 s)
        code, out = run_pass()
        self.assertEqual(code, 0, out)
        self.assertIn("digitou=1", out)
        transcripts = [os.path.join(home, ".claude/projects/p", f) for f in os.listdir(os.path.join(home, ".claude/projects/p"))]
        self.assertEqual(len(transcripts), 1)
        with open(transcripts[0]) as fh:
            users = [json.loads(x) for x in fh if x.strip()]
        self.assertEqual(len(users), 1)
        line = users[0]["message"]["content"]
        self.assertTrue(line.startswith(B.TAG))
        self.assertIn("retome a bead em andamento wa-9 e o último handoff", line)  # the rig store answered through the fake bd, and the accents came through a real tmux
        code, out = run_pass()  # a pass later the registry says busy: proven
        self.assertEqual(code, 0, out)
        self.assertIn("confirmou=1", out)
        self.assertNotIn("digitou=1", out)
        time.sleep(3.5)  # the turn is over: the pane is idle and empty again, and the line must NOT be typed a second time
        for _ in range(2):
            code, out = run_pass()
            self.assertEqual((code, "digitou=0" in out), (0, True), out)
        with open(transcripts[0]) as fh:
            self.assertEqual(sum(1 for x in fh if B.TAG in x), 1)
        with open(os.path.join(city, ".gc/logs/boot-first-turn.jsonl")) as fh:
            recs = [json.loads(x) for x in fh if x.strip()]
        self.assertEqual([(r["target"], r["result"], r["how"]) for r in recs], [("c1", "confirmed", "registry")])


class Warnings(Base):
    def test_a_registry_file_that_cannot_be_read_is_told_so_a_crew_that_looks_absent_has_a_reason(self):
        w = self.w()
        w.add("c1")
        w.add("c2", template="peter-wa")
        put(os.path.join(w.home, ".claude/sessions/99999.json"), "{not json")
        put(os.path.join(w.home, ".claude/sessions/88888.json"), json.dumps({"pid": 88888}))  # JSON, but not a session entry
        w.go()
        self.assertEqual(sorted(n for n, _ in w.typed), ["c1", "c2"])  # the readable ones are not blinded by the bad ones
        self.assertIn("2 file(s) in ~/.claude/sessions could not be read or are not a session entry", w.log())
        w.later(60)
        self.assertEqual(w.log().count("could not be read or are not a session entry"), 1)  # told once, not every minute

    def test_a_clean_registry_says_nothing(self):
        w = self.w()
        w.add("c1")
        w.go()
        self.assertNotIn("could not be read", w.log())

    def test_an_agents_dir_that_cannot_be_read_leaves_only_the_mayor_and_says_so(self):
        if os.geteuid() == 0:
            self.skipTest("root reads anything")
        w = self.w()
        w.add("mayor-1", template="gastown.mayor", crew=False)
        w.add("c1")
        agents = os.path.join(w.city, "agents")
        os.chmod(agents, 0)
        self.addCleanup(os.chmod, agents, 0o755)
        w.go()
        self.assertEqual([n for n, _ in w.typed], ["mayor-1"])
        self.assertIn("agents/ unreadable: only the Mayor is a target", w.log())


if __name__ == "__main__":
    unittest.main()
