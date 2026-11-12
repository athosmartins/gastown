#!/usr/bin/env python3
"""Selftest of nightly-session-compact.py (ga-esorlre.4): `python3 -I test_nightly_session_compact.py`. Stdlib only; python 3.9 is the mini's."""
import calendar
import contextlib
import fcntl
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
from unittest import mock

os.environ["TZ"] = "UTC"
time.tzset()
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "nightly-session-compact.py")
spec = importlib.util.spec_from_file_location("nsc", SCRIPT)
nsc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nsc)
T0 = calendar.timegm((2026, 11, 12, 23, 0, 0))  # 23:00 local (TZ=UTC here)
IDLE = "✻ Cooked for 3m 1s · done 8:55 PM\n──────\n❯ \n──────\n  ⏵⏵ bypass permissions on (shift+tab to cycle)\n"
TS = "2026-11-12T22:00:00Z"
TMUX = ["tmux", "-L", "gascity", "send-keys", "-t", "=c1:"]


def asst(tokens=300000, stop="end_turn", **kw):
    return dict({"type": "assistant", "message": {"model": "m", "stop_reason": stop, "usage": {"input_tokens": 3, "cache_creation_input_tokens": 7, "cache_read_input_tokens": tokens - 10}}}, **kw)


def sysr(sub, **kw):
    return dict({"type": "system", "subtype": sub}, **kw)


def tool_result(text, ts=TS):
    return {"type": "user", "timestamp": ts, "message": {"content": [{"type": "tool_result", "content": text}]}}


def notif(tid, status, ts=TS):
    return {"type": "attachment", "timestamp": ts, "attachment": {"type": "queued_command", "prompt": "<task-notification>\n<task-id>%s</task-id>\n<status>%s</status>\n</task-notification>" % (tid, status)}}


def put(path, text, mode="w"):
    with open(path, mode) as fh:
        fh.write(text)


def jload(path):
    with open(path) as fh:
        return json.load(fh)


class W:
    """A throwaway city + HOME and the fake IO the script talks to (clock, gc, ps, tmux)."""
    def __init__(self, **env):
        self.root = tempfile.mkdtemp(prefix="nsc-test-")
        self.home, self.city = os.path.join(self.root, "home"), os.path.join(self.root, "city")
        for d in ("home/.claude/sessions", "home/.claude/projects/p", "city/agents", "city/.gc/logs"):
            os.makedirs(os.path.join(self.root, d))
        self.t, self.calls, self.sessions, self.panes, self.events, self.forced, self.path = T0, [], [], {}, [], {}, {}
        self.nudge_out, self.on_nudge, self.on_tmux = '{"ok":true,"outcome":"delivered"}', lambda n: self.boundary(n), lambda a: None
        self.env = dict({"GC_CITY_PATH": self.city, "NSC_HOME": self.home, "NSC_GC": "gc", "NSC_GC_CITY": "0", "NSC_POLL_S": "5", "NSC_PASS_INTERVAL_S": "60"}, **env)
        self.cfg = nsc.Cfg(self.env)
    def add(self, name, tokens=300000, status="idle", idle=900, template="thies-wa", recs=None, pane=IDLE, crew=True, tidle=None, **reg):
        wd = "/x/crew/" + template
        if crew and template != "gastown.mayor":
            os.makedirs(os.path.join(self.city, "agents", template), exist_ok=True)
            put(os.path.join(self.city, "agents", template, "agent.toml"), 'work_dir = "%s"\nmax_active_sessions = 1\n' % wd)
        sid = "sid-" + name.replace(".", "-") + "-0000"
        self.path[name] = os.path.join(self.home, ".claude/projects/p", sid + ".jsonl")
        put(self.path[name], "".join(json.dumps(r) + "\n" for r in (recs if recs is not None else [asst(tokens), sysr("turn_duration")])))
        os.utime(self.path[name], (T0 - (idle if tidle is None else tidle),) * 2)
        self.edit(name, **dict({"pid": os.getpid(), "sessionId": sid, "kind": "interactive", "cwd": wd, "startedAt": (T0 - 86400) * 1000, "tmux": name + ":@1.%1",
                                "status": status, "statusUpdatedAt": (T0 - idle) * 1000}, **reg))
        self.sessions.append({"name": name, "session_name": name, "template": template, "state": "active"})
        self.panes[name] = pane
    def edit(self, name, **kw):
        f = os.path.join(self.home, ".claude/sessions", name + ".json")
        e = dict(jload(f), **kw) if os.path.exists(f) else dict(kw)
        put(f, json.dumps({k: v for k, v in e.items() if v is not None}))
    def append(self, name, *recs):
        put(self.path[name], "".join(json.dumps(r) + "\n" for r in recs), "a")
    def boundary(self, name, delay=20, rec=None):
        r = rec or sysr("compact_boundary", compactMetadata={"trigger": "manual", "preTokens": 300000, "postTokens": 15000, "durationMs": delay * 1000})
        self.events.append((self.t + delay, lambda: self.append(name, r)))
    def now(self):
        return self.t
    def sleep(self, s):
        self.t += s
        for ev in [e for e in self.events if e[0] <= self.t]:
            self.events.remove(ev)
            ev[1]()
    def run(self, argv, timeout):
        self.calls.append(list(argv))
        k = " ".join(argv[:3])
        if k in self.forced:
            return self.forced[k]
        if argv[0] == "ps":
            return (0, "claude --x") if int(argv[-1]) == os.getpid() else (1, "")
        if k == "gc session list":
            return 0, json.dumps({"ok": True, "sessions": self.sessions})
        if k == "gc session peek":
            return (0, self.panes[argv[3]]) if argv[3] in self.panes else (1, "")
        if k == "gc session nudge":
            self.on_nudge(argv[3])
            return 0, self.nudge_out
        if argv[0] == "tmux":
            self.on_tmux(argv)
        return 0, ""
    def go(self, **kw):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            rc = nsc.run(self.cfg, self, nsc.Log(self.cfg), **kw)
        self.out = out.getvalue()
        return rc
    def res(self):
        p = os.path.join(self.city, ".gc/logs/nightly-session-compact.jsonl")
        if not os.path.exists(p):
            return {}
        with open(p) as fh:
            return {r["target"]: r for r in map(json.loads, fh.read().splitlines())}
    def nudges(self):
        return [c for c in self.calls if c[1:3] == ["session", "nudge"]]
    def tmux(self):
        return [c for c in self.calls if c[0] == "tmux"]


class T(unittest.TestCase):
    def w(self, **env):
        w = W(**env)
        self.addCleanup(shutil.rmtree, w.root, True)
        return w

    def test_idle_big_crew_is_compacted_and_recorded(self):
        w = self.w()
        w.add("thies-1")
        self.assertEqual(w.go(), 0)
        self.assertEqual(w.nudges(), [["gc", "session", "nudge", "thies-1", "/compact", "--delivery", "immediate", "--json"]])
        r = w.res()["thies-1"]
        self.assertEqual((r["result"], r["tokens_before"], r["tokens_after"], r["via"]), ("compacted", 300000, 15000, "nudge"))
        self.assertEqual(w.tmux(), [])
        w = self.w()
        w.add("thies-1", tmux=None)  # no tmux key in the registry: the crew's work_dir finds the process
        w.go()
        self.assertEqual(w.res()["thies-1"]["result"], "compacted")

    def test_targets_are_named_crews_and_the_mayor_only(self):
        w = self.w()
        w.add("mayor-1", template="gastown.mayor")
        w.add("dog-1", template="gastown.dog", crew=False)
        w.add("closed-1", template="digo-wa")
        w.sessions[-1]["state"] = "asleep"
        w.add("wa-1", template="wa-worker", crew=False)
        self.assertEqual(w.go(), 0)
        self.assertEqual([c[3] for c in w.nudges()], ["mayor-1"])

    def test_size_threshold_and_already_compacted(self):
        for name, recs, want, nudged in (("a", [asst(100000), sysr("turn_duration")], "small", 0), ("b", [asst(), sysr("compact_boundary", compactMetadata={"postTokens": 20000})], "small", 0),
                                         ("c", [asst(), sysr("compact_boundary")], "compacted", 0), ("d", [asst(249999), sysr("turn_duration")], "small", 0), ("e", [asst(250000), sysr("turn_duration")], "compacted", 1)):
            w = self.w()
            w.add(name, recs=recs)
            w.go()
            self.assertEqual((len(w.nudges()), w.res()[name]["result"]), (nudged, want), name)
    def test_every_busy_signal_blocks(self):
        bg = [asst(300000, "tool_use"), tool_result("Command running in background with ID: b1abc. Output is being written"), asst(), sysr("turn_duration")]
        for why, kw, msg in (("registry busy", dict(status="busy"), "registry status=busy"), ("idle 60s", dict(idle=60), "registry idle for only"),
                             ("registry recent, transcript old", dict(statusUpdatedAt=(T0 - 60) * 1000), "registry idle for only"), ("transcript recent", dict(tidle=60), "transcript written"),
                             ("no status field, transcript 400s quiet", dict(status=None, idle=400), "transcript written"), ("tool_use", dict(recs=[asst(300000, "tool_use")]), "stop_reason=tool_use"),
                             ("user prompt last", dict(recs=[asst(), sysr("turn_duration"), {"type": "user", "message": {"content": "do X"}}]), "waits for the model"),
                             ("no turn_duration", dict(recs=[asst()], idle=400), "not turn_duration"), ("bg task open", dict(recs=bg), "background task(s) open: b1abc"),
                             ("dialog", dict(pane="Do you want to proceed?\n❯ 1. Yes\n"), "pane: a dialog"), ("working", dict(pane="* Infusing… (7m 18s · ↓ 5k tokens)\n❯ \n"), "pane: a turn is running"),
                             ("draft", dict(pane=IDLE.replace("❯ ", "❯ half a message")), "the input box holds text"),
                             ("footer shell", dict(pane=IDLE.replace("on (shift", "on · 1 shell · (shift")), "background work in the footer"),
                             ("no prompt", dict(pane="$ ls\n"), "no Claude Code prompt"), ("empty pane", dict(pane=" \n"), "the pane could not be read")):
            w = self.w(NSC_WINDOW_END="23:01")
            w.add("c1", **kw)
            w.go()
            self.assertEqual((w.nudges(), w.res()["c1"]["result"]), ([], "skipped"), why)
            self.assertIn(msg, w.res()["c1"]["reason"], why)
            self.assertLessEqual(len([c for c in w.calls if c[1:3] == ["session", "peek"]]), 2, why)
    def test_a_busy_crew_is_retried_on_the_next_pass_and_compacted_once_idle(self):
        w = self.w()
        w.add("c1", idle=240)
        w.go()
        self.assertEqual((len(w.nudges()), w.res()["c1"]["result"]), (1, "compacted"))
        self.assertGreaterEqual(w.t, T0 + 60)

    def test_a_local_command_or_a_subagent_after_the_finished_turn_is_not_busy(self):
        w = self.w()
        w.add("c1", recs=[asst(), sysr("turn_duration"), {"type": "user", "message": {"content": "<command-name>/context</command-name>"}}, sysr("local_command"),
                          {"type": "user", "isSidechain": True, "message": {"content": "sub"}}, {"type": "user", "isMeta": True, "message": {"content": "caveat"}}])
        w.go()
        self.assertEqual(w.res()["c1"]["result"], "compacted")

    def test_the_newest_transcript_of_a_resumed_session_wins(self):
        w = self.w()
        w.add("c1")
        old = os.path.join(w.home, ".claude/projects/old")
        os.makedirs(old)
        put(os.path.join(old, os.path.basename(w.path["c1"])), json.dumps(asst(1000)) + "\n")
        os.utime(os.path.join(old, os.path.basename(w.path["c1"])), (T0 - 5000, T0 - 5000))
        w.go()
        self.assertEqual(w.res()["c1"]["result"], "compacted")
    def test_background_pairing(self):
        st, end = (lambda i: tool_result("Command running in background with ID: %s. Output" % i)), [asst(), sysr("turn_duration")]
        for name, recs, blocked in (("done", [st("b1"), notif("b1", "completed")] + end, False), ("progress", [st("b1"), notif("b1", "")] + end, True),
                                    ("monitor", [tool_result("Monitor started (task m9x, expires in 10m")] + end, True),
                                    ("before start", [tool_result("Command running in background with ID: old1. x", "2026-11-10T01:00:00Z")] + end, False),
                                    ("quoted in a Read", [tool_result("     1\tCommand running in background with ID: zz9")] + end, False)):
            f = os.path.join(self.w().root, "t.jsonl")
            put(f, "".join(json.dumps(r) + "\n" for r in recs))
            self.assertEqual(nsc.open_background(f, (T0 - 86400) * 1000) != [], blocked, name)

    def test_unreadable_or_ambiguous_inputs_compact_nothing(self):
        roster = lambda rc, out: (lambda w: w.forced.update({"gc session list": (rc, out)}))
        cases = (("registry file corrupt", lambda w: put(os.path.join(w.home, ".claude/sessions/c1.json"), "{not json"), "1 unreadable file(s) ignored"),
                 ("ps cannot run", lambda w: w.forced.update({"ps -o command=": (None, "")}), "cannot tell whether pid"),
                 ("pid is another program", lambda w: w.forced.update({"ps -o command=": (0, "/usr/bin/vim notes.txt")}), "0 live claude processes"),
                 ("transcript missing", lambda w: os.unlink(w.path["c1"]), "no single transcript"), ("transcript corrupt", lambda w: put(w.path["c1"], "garbage\n{not json\n"), "no assistant usage"),
                 ("session id with a glob", lambda w: w.edit("c1", sessionId="*"), "no single transcript"), ("pid dead", lambda w: w.edit("c1", pid=2147483647), "0 live claude processes"),
                 ("two live processes", lambda w: w.edit("c2", **jload(os.path.join(w.home, ".claude/sessions/c1.json"))), "2 live claude processes"),
                 ("other cwd", lambda w: w.edit("c1", cwd="/somewhere/else"), "is not the crew's work_dir"), ("same cwd, other tmux session", lambda w: w.edit("c1", tmux="other:@1.%1"), "0 live claude processes"),
                 ("not interactive", lambda w: w.edit("c1", kind="headless"), "0 live claude processes"), ("idle without date", lambda w: w.edit("c1", statusUpdatedAt=None), "without statusUpdatedAt"),
                 ("no registry dir", lambda w: os.rename(os.path.join(w.home, ".claude/sessions"), os.path.join(w.home, "gone")), "unreadable: no target can be proven idle"),
                 ("peek fails", lambda w: w.forced.update({"gc session peek": (1, "")}), "the pane could not be read"), ("roster rc", roster(1, ""), "unreadable this pass"),
                 ("roster rc with a good body", roster(1, '{"sessions": [{"name": "c1", "template": "thies-wa", "state": "active"}]}'), "unreadable this pass"),
                 ("roster timeout", roster(None, ""), "unreadable this pass"), ("roster garbage", roster(0, "<html>"), "unreadable this pass"),
                 ("roster not a list", roster(0, '{"sessions": {"a": 1}}'), "unreadable this pass"))
        for why, f, msg in cases:
            w = self.w(NSC_WINDOW_END="23:05")
            w.add("c1")
            f(w)
            rc = w.go()
            self.assertEqual((w.nudges(), rc), ([], 3 if why.startswith("roster") else 0), why)
            self.assertIn(msg, w.out, why)
            if why == "no registry dir":
                self.assertIn("registry is unreadable", w.res()["c1"]["reason"])
    def test_window_switches_dry_run_and_single_instance(self):
        late = T0 + 2 * 3600
        for name, env, clock in (("outside", {}, late), ("23:26 is late", {}, T0 + 26 * 60), ("off env", {"NSC_ENABLED": "0"}, T0), ("dry", {"NSC_DRY_RUN": "1"}, T0)):
            w = self.w(**env)
            w.add("c1")
            w.t = clock
            w.go()
            self.assertEqual(w.nudges(), [], name)
        self.assertEqual(w.res()["c1"]["result"], "dry-run")
        w = self.w()
        w.add("c1")
        off = os.path.join(w.city, ".gc/nightly-session-compact.off")
        put(off, "")
        w.go()
        self.assertEqual(w.nudges(), [])
        os.unlink(off)
        w.t = late
        w.go(force=True)
        self.assertEqual(len(w.nudges()), 1)
        w = self.w()
        w.add("c1")
        os.makedirs(os.path.join(w.city, ".gc/state"))
        fd = os.open(os.path.join(w.city, ".gc/state/nightly-session-compact.lock"), os.O_CREAT | os.O_RDWR)
        fcntl.flock(fd, fcntl.LOCK_EX)
        self.assertEqual(w.go(), 0)
        self.assertEqual((w.nudges(), "in flight" in w.out), ([], True))
        os.close(fd)

    def test_nudge_that_did_not_type_gets_one_tmux_retry(self):
        for out, forced, note in (('{"ok":true,"outcome":"queued"}', None, "nudge queued"), ("not json", None, "nudge unreadable"), ('{"ok":false}', None, "nudge unreadable"),
                                  ('{"ok":false,"outcome":"delivered"}', None, "nudge unreadable"), ("", (1, ""), "nudge failed rc 1"), ("", (None, ""), "nudge failed rc None")):
            w = self.w()
            w.add("c1")
            w.on_nudge, w.forced["gc session nudge"], typed = lambda n: None, forced or (0, out), []
            w.on_tmux = lambda a, w=w: (typed.append(w.t), w.boundary("c1")) if a[-1] == "Enter" else None
            w.go()
            self.assertEqual(w.tmux(), [TMUX + ["-l", "/compact"], TMUX + ["Enter"]], out)
            self.assertEqual((w.res()["c1"]["result"], w.res()["c1"]["via"], w.res()["c1"]["notes"][0].startswith(note), T0 + 20 <= typed[0] < T0 + 60), ("compacted", "nudge+tmux", True, True), out)
        w = self.w()
        w.add("c1")
        w.on_nudge, w.forced["gc session nudge"], w.forced["tmux -L gascity"] = lambda n: None, (None, ""), (1, "")
        w.go()
        self.assertEqual((len(w.tmux()), w.res()["c1"]["result"]), (1, "unconfirmed"))

    def test_delivered_but_silent_waits_90s_before_the_tmux_retry_and_metadata_is_no_sign_of_life(self):
        w = self.w()
        w.add("c1")
        typed = []
        w.on_nudge = lambda n: w.boundary(n, 10, {"type": "last-prompt"})
        w.on_tmux = lambda a: (typed.append(w.t), w.boundary("c1")) if a[-1] == "Enter" else None
        w.go()
        self.assertEqual((len(w.tmux()), T0 + 90 <= typed[0] < T0 + 120, w.res()["c1"]["via"]), (2, True, "nudge+tmux"))
    def test_no_tmux_retry_when_there_is_a_sign_of_life_or_the_pane_is_not_idle(self):
        for name, setup, result, msg in (("registry went busy", lambda w: (w.edit("c1", status="busy"), w.boundary("c1", 150)), "compacted", ""),
                                         ("pane shows work", lambda w: w.panes.update(c1="✻ Compacting… (5s · esc to interrupt)\n❯ \n"), "unconfirmed", "activity seen"),
                                         ("draft stranded", lambda w: w.panes.update(c1=IDLE.replace("❯ ", "❯ /compact")), "unconfirmed", "tmux retry skipped")):
            w = self.w()
            w.add("c1")
            w.on_nudge = lambda n: None
            w.events.append((T0 + 40, lambda w=w, setup=setup: setup(w)))
            w.go()
            self.assertEqual((w.tmux(), w.res()["c1"]["result"]), ([], result), name)
            self.assertIn(msg, w.res()["c1"].get("reason", ""), name)
    def test_compaction_error_is_failed_and_never_retried(self):
        w = self.w()
        w.add("c1")
        w.on_nudge = lambda n: w.boundary(n, 5, sysr("local_command", content="<local-command-stderr>Error during compaction: You've hit your weekly limit</local-command-stderr>"))
        w.go()
        self.assertEqual((w.res()["c1"]["result"], len(w.nudges())), ("failed", 1))
        self.assertIn("weekly limit", w.res()["c1"]["reason"])

    def test_activity_without_a_boundary_is_unconfirmed_at_the_deadline_or_the_hard_end(self):
        for env, msg in (({"NSC_CONFIRM_TIMEOUT_S": "300"}, "before the deadline"), ({"NSC_WINDOW_END": "23:01", "NSC_GRACE_S": "60"}, "before the deadline")):
            w = self.w(**env)
            w.add("c1")
            w.on_nudge = lambda n: w.boundary(n, 10, {"type": "user", "message": {"content": "/compact"}})
            w.go()
            self.assertEqual(w.res()["c1"]["result"], "unconfirmed")
            self.assertIn("activity seen", w.res()["c1"]["reason"])
            self.assertIn(msg, w.res()["c1"]["reason"])
            self.assertLess(w.t, T0 + 400)
    def test_parallel_limit_biggest_first_and_all_compacted(self):
        w = self.w(NSC_MAX_PARALLEL="2", NSC_PASS_INTERVAL_S="600")
        live, peak = set(), [0]
        for i, tokens in enumerate((300000, 500000, 400000, 350000, 450000)):
            w.add("c%d" % i, tokens=tokens, template="t%d" % i)

        def on_nudge(n):
            live.add(n)
            peak[0] = max(peak[0], len(live))
            w.boundary(n, 100)
            w.events.append((w.t + 100, lambda: live.discard(n)))
        w.on_nudge = on_nudge
        w.go()
        self.assertEqual((peak[0], sorted(r["result"] for r in w.res().values())), (2, ["compacted"] * 5))
        self.assertEqual([c[3] for c in w.nudges()], ["c1", "c4", "c2", "c3", "c0"])
        self.assertLessEqual(len([c for c in w.calls if c[1:4] == ["session", "peek", "c0"]]), 5)
        self.assertLess(w.t, T0 + 600)

    def test_a_ready_crew_that_never_got_a_slot_is_recorded_as_skipped(self):
        w = self.w(NSC_MAX_PARALLEL="1", NSC_WINDOW_END="23:05")
        w.add("c0", tokens=400000, template="t0")
        w.add("c1", template="t1")
        w.on_nudge = lambda n: w.boundary(n, 10, {"type": "user", "message": {"content": "/compact"}})
        w.go()
        self.assertEqual((w.res()["c0"]["result"], w.res()["c1"]["result"]), ("unconfirmed", "skipped"))
        self.assertIn("waited for a free slot", w.res()["c1"]["reason"])

    def test_pure_readers(self):
        recs = [asst(), {"type": "assistant", "message": {"model": "<synthetic>", "usage": {"input_tokens": 9000000}}}, asst(500000, isSidechain=True)]
        self.assertEqual(nsc.context_state(recs), ("tokens", 300000))
        self.assertEqual(nsc.context_state(recs + [sysr("compact_boundary", compactMetadata={"postTokens": 1234})]), ("boundary", 1234))
        self.assertIsNone(nsc.context_state([{"type": "user"}]))
        f = os.path.join(self.w().root, "t.jsonl")
        put(f, "".join(json.dumps({"type": "user", "n": i}) + "\n" for i in range(40)) + "{broken\n")
        recs, size, _ = nsc.read_tail(f, 200)
        self.assertTrue(recs and all(r["type"] == "user" for r in recs) and size == os.path.getsize(f))
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
            nsc.Log(nsc.Cfg({"GC_CITY_PATH": "/nonexistent/city"}))("x")
        self.assertIn("cannot append", err.getvalue())
        self.assertIsNone(nsc.read_tail("/nonexistent/t.jsonl", 100))
        self.assertIsNone(nsc.open_background("/nonexistent/t.jsonl", 0))
        self.assertEqual(nsc.load_registry("/nonexistent/home"), (None, 0))
        self.assertIsNone(nsc.find_transcript("/nonexistent/home", "sid-abcdefgh"))
        g = {"path": f + ".part", "offset": 0}
        self.assertEqual(nsc.read_new(g), [])
        put(g["path"], '{"a": 1}\n{"b"')
        self.assertEqual(nsc.read_new(g), [{"a": 1}])
        put(g["path"], ': 2}\n', "a")
        self.assertEqual(nsc.read_new(g), [{"b": 2}])
        for text, want in ((IDLE, "idle"), ("", "unknown"), ("Do you want to proceed?\n", "dialog"), ("✻ Pondering…\n❯ \n", "unknown"), ("* Infusing… (7m 18s · ↓ 5k tokens)\n❯ \n", "working")):
            self.assertEqual(nsc.read_pane(text)[0], want, text)
        self.assertEqual((nsc.num("x", 5), nsc.num("0", 5), nsc.num(" 7 ", 5), nsc.hhmm("25:00", (1, 2)), nsc.hhmm("9:05", (1, 2))), (5, 5, 7, (1, 2), (9, 5)))
        d = self.w().root
        for n, body in (("thies-wa", 'work_dir = "/a/crew/thies"\n'), ("wa-worker", 'work_dir = "/a/crew/worker"\n'), ("big", 'work_dir = "/a/crew/b"\nmax_active_sessions = 2\n'), ("none", "x = 1\n")):
            os.makedirs(os.path.join(d, "ag", n))
            put(os.path.join(d, "ag", n, "agent.toml"), body)
        os.makedirs(os.path.join(d, "ag", "nofile"))
        self.assertEqual(nsc.crew_templates(os.path.join(d, "ag")), {"thies-wa": "/a/crew/thies"})
        self.assertIsNone(nsc.crew_templates("/nonexistent/agents"))

    def test_real_io_reports_a_command_that_cannot_run_or_times_out_as_none(self):
        run = nsc.RealIO().run
        self.assertEqual(run(["/nonexistent/gc", "x"], 5), (None, ""))
        with mock.patch("subprocess.run", side_effect=subprocess.TimeoutExpired("gc", 1)):
            self.assertEqual(run(["gc"], 1), (None, ""))
        self.assertEqual(run([sys.executable, "-c", "print('hi'); raise SystemExit(3)"], 20), (3, "hi\n"))

    def test_order_file_fires_at_23h_local_in_utc(self):
        with open(os.path.join(HERE, "..", "..", "orders", "nightly-session-compact.toml")) as fh:
            txt = fh.read()
        self.assertEqual(re.search(r'^schedule\s*=\s*"([^"]+)"', txt, re.M).group(1), "0 2 * * *")
        self.assertIn('trigger = "cron"', txt)
        self.assertGreaterEqual(int(re.search(r'^timeout\s*=\s*"(\d+)s"', txt, re.M).group(1)), 2400)
        self.assertTrue(os.path.exists(os.path.join(HERE, re.search(r"assets/scripts/(\S+?\.py)", txt).group(1))))

    def test_cli_dry_run_end_to_end_on_the_real_clock(self):
        w = self.w()
        w.add("thies-1")
        now = time.time()
        os.utime(w.path["thies-1"], (now - 900, now - 900))
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", "claude"])
        self.addCleanup(child.wait)
        self.addCleanup(child.kill)
        w.edit("thies-1", pid=child.pid, statusUpdatedAt=(now - 900) * 1000, startedAt=(now - 86400) * 1000)
        fake = os.path.join(w.root, "gc")
        put(fake, "#!%s\nimport json,sys\na=sys.argv[1:]\nif a[:2]==['session','list']:\n print(json.dumps({'ok':True,'sessions':%r}))\nelse:\n print(%r)\n" % (sys.executable, w.sessions, IDLE))
        os.chmod(fake, 0o755)
        env = dict(os.environ, **dict(w.env, NSC_GC=fake))
        for args, rc in ((["--dry-run"], 0), (["--bogus"], 2)):
            p = subprocess.run([sys.executable, "-I", SCRIPT, "--force"] + args, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(p.returncode, rc, p.stdout + p.stderr)
        self.assertEqual((w.res()["thies-1"]["result"], w.res()["thies-1"]["tokens_before"]), ("dry-run", 300000))

if __name__ == "__main__":
    unittest.main(verbosity=1)
