#!/usr/bin/env python3
"""Selftest for cdp-tab-guard.py (ga-w7rcut).

WHY THIS GUARD EXISTS: on 2026-09-19 four renderers of the shared automation Chrome
(:9222) reached 3.0/2.8/2.6/2.4 GB of FOOTPRINT (almost all compressed) after an agent's
puppeteer debug scripts did newPage()+goto(heavy map)+disconnect() without page.close().
The only existing safety net (chrome_cdp_watchdog.sh) caps `ps rss`, which does not count
compressed memory, so it read "1433MB < cap" while the real footprint was ~10.8 GB.

Two layers:
  * pure-logic tests on hand-derived literal fixtures (no Chrome, milliseconds);
  * end-to-end tests against a REAL throwaway headless Chrome on a private port
    (CDP_TAB_GUARD_SELFTEST_PORT, default 9333) with a private --user-data-dir. The
    production Chrome on :9222 is never contacted: every guard invocation is pinned to
    the test port, and the fixture refuses to run against 9222.

Every test states the production break it catches ("Catches:"). Expectations are literals,
never computed by the code under test.

Run:  python3 cdp-tab-guard.selftest.py        (or the .selftest.sh wrapper)
Exit: 0 = all pass, non-zero = any failure.
"""
import fcntl
import importlib.util
import json
import os
import pathlib
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
import urllib.request
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
GUARD = pathlib.Path(os.environ.get("CDP_TAB_GUARD_UNDER_TEST") or (HERE / "cdp-tab-guard.py"))
CHROME_BIN = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TEST_PORT = int(os.environ.get("CDP_TAB_GUARD_SELFTEST_PORT", "9333"))

G = None        # the guard module, loaded in setUpModule
FX = None       # the throwaway Chrome fixture, started in setUpModule


def _load_guard():
    spec = importlib.util.spec_from_file_location("cdp_tab_guard", str(GUARD))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def env_cfg(**kv):
    """Build a Config through the SAME env path production uses."""
    return G.Config.from_env({"CDP_TAB_GUARD_" + k.upper(): str(v) for k, v in kv.items()})


# ─────────────────────────────── pure logic ────────────────────────────────


def _ps_line(pid, ppid, cmd):
    return "%7d %7d %s" % (pid, ppid, cmd)


_APP = "/Applications/Google Chrome.app/Contents"
_MAIN = _APP + "/MacOS/Google Chrome"
_HELP = _APP + "/Frameworks/Google Chrome Framework.framework/Versions/153.0.8010.52/Helpers/"
_RENDERER = _HELP + "Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
_GPU = _HELP + "Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)"

PS_FIXTURE = "\n".join([
    # decoy: a launcher script that carries the flag but is not a Chrome binary
    _ps_line(99, 1, "/usr/local/bin/node /tmp/launch.js --remote-debugging-port=9222 --headless"),
    _ps_line(100, 1, _MAIN + " --remote-debugging-port=9222 --user-data-dir=/Users/x/.chrome-cdp --no-first-run about:blank"),
    _ps_line(101, 100, _RENDERER + " --type=renderer --lang=en-US"),
    _ps_line(102, 100, _GPU + " --type=gpu-process"),
    _ps_line(200, 1, _MAIN + " --remote-debugging-port=9333 --user-data-dir=/tmp/other about:blank"),
    _ps_line(201, 200, _RENDERER + " --type=renderer"),
    # decoy: mentions the flag but is not a Chrome process
    _ps_line(300, 999, "/bin/zsh -c ps -axo pid,command | grep remote-debugging-port=9222"),
    _ps_line(301, 100, _RENDERER + " --type=renderer --renderer-client-id=9"),
    # a longer port number that merely starts with the same digits
    _ps_line(400, 1, _MAIN + " --remote-debugging-port=92220 --user-data-dir=/tmp/x about:blank"),
    _ps_line(401, 400, _RENDERER + " --type=renderer"),
])


class ParseFamilyTests(unittest.TestCase):
    def test_selects_only_the_requested_port_family(self):
        """Catches: matching every Chrome on the box (would probe/close another family's
        tabs), taking a grep or launcher-script decoy as the browser, or counting a GPU helper
        as a renderer."""
        main, rends = G.parse_family(PS_FIXTURE, 9222)
        self.assertEqual(main, 100)
        self.assertEqual(sorted(rends), [101, 301])

    def test_other_port_and_absent_port(self):
        """Catches: prefix-matching ports (9222 vs 92220) and inventing a family."""
        self.assertEqual(G.parse_family(PS_FIXTURE, 9333), (200, [201]))
        self.assertEqual(G.parse_family(PS_FIXTURE, 92220), (400, [401]))
        self.assertEqual(G.parse_family(PS_FIXTURE, 9444), (None, []))
        only_92220 = "\n".join(l for l in PS_FIXTURE.splitlines() if "92220" in l or " 401 " in l or " 400 " in l)
        self.assertEqual(G.parse_family(only_92220, 9222), (None, []))   # 9222 is not 92220


class IdleTrackerTests(unittest.TestCase):
    def setUp(self):
        self.cfg = env_cfg(active_cpu_ms_per_min=150, max_gap_sec=300)

    @staticmethod
    def _s(start, cpu_ms):
        return {"start": start, "cpu_ms": cpu_ms, "footprint_mb": 1.0}

    def test_idle_time_accumulates_only_while_cpu_is_quiet(self):
        """Catches: crediting idle time across a CPU burst (an in-use tab would look idle),
        crediting a >max-gap hole in observation, and crediting a recycled pid with the
        previous process's quiet history."""
        seq = [  # (now, start_abstime, cpu_ms, expected idle_for_s)
            (1000, 111, 5000.0, 0),    # first sight: no history, never idle
            (1060, 111, 5010.0, 60),   # 10 ms in 60 s: quiet
            (1120, 111, 5020.0, 120),  # still quiet
            (1180, 111, 5400.0, 0),    # 380 ms in 60 s >= 150 ms/min: activity resets
            (1240, 111, 5405.0, 60),   # quiet again, counted from the burst
            (1640, 111, 5406.0, 0),    # 400 s gap > 300 s: history unreliable -> reset
            (1700, 222, 5406.0, 0),    # same pid, different start time: recycled pid
            (1760, 222, 5407.0, 60),
        ]
        entry = None
        for now, start, cpu, want in seq:
            entry, idle_for = G.step_idle(entry, self._s(start, cpu), now, self.cfg)
            self.assertEqual(idle_for, want, "t=%s" % now)

    def test_activity_threshold_scales_with_the_sampling_interval(self):
        """Catches: comparing raw CPU deltas to a per-minute threshold (a 6 s window with
        20 ms of CPU is 200 ms/min = active, with 10 ms is 100 ms/min = quiet)."""
        entry, _ = G.step_idle(None, self._s(1, 1000.0), 1000, self.cfg)
        _, idle_quiet = G.step_idle(entry, self._s(1, 1010.0), 1006, self.cfg)
        self.assertEqual(idle_quiet, 6)
        entry, _ = G.step_idle(None, self._s(1, 1000.0), 1000, self.cfg)
        _, idle_busy = G.step_idle(entry, self._s(1, 1020.0), 1006, self.cfg)
        self.assertEqual(idle_busy, 0)

    def test_backwards_clock_or_cpu_counter_is_not_idle_time(self):
        """Catches: negative gaps / decreasing CPU counters producing negative or inflated
        idle time (three-state rule: cannot tell -> treat as unknown, not as quiet)."""
        entry, _ = G.step_idle(None, self._s(1, 500.0), 1000, self.cfg)
        entry, idle = G.step_idle(entry, self._s(1, 505.0), 990, self.cfg)   # clock went back
        self.assertEqual(idle, 0)
        entry, _ = G.step_idle(None, self._s(1, 500.0), 1000, self.cfg)
        entry, idle = G.step_idle(entry, self._s(1, 100.0), 1060, self.cfg)  # counter went back
        self.assertEqual(idle, 0)

    def test_the_guards_own_probe_cpu_is_not_activity(self):
        """Catches: the guard's own probing (it burns CPU inside the renderer it inspects) being read
        as tab activity at the next sample, so a heavy idle tab that keeps getting probed would look
        busy for ever and never be closed."""
        e1, _ = G.step_idle(None, self._s(1, 5000.0), 1000, self.cfg)
        control = dict(e1)                                        # untouched copy (credit works in place)
        entries = {"7": e1}
        G.credit_own_cpu(entries, {7: 200.0})                     # the guard burned 200 ms inside pid 7
        self.assertEqual(entries["7"]["last_cpu_ms"], 5200.0)
        _, idle = G.step_idle(entries["7"], self._s(1, 5205.0), 1060, self.cfg)   # 200 ours + 5 real
        self.assertEqual(idle, 60)
        _, idle_uncredited = G.step_idle(control, self._s(1, 5205.0), 1060, self.cfg)  # control: 205 ms/min
        self.assertEqual(idle_uncredited, 0)
        G.credit_own_cpu({}, {9: 5.0})                            # a renderer we do not track: ignored

    def test_malformed_history_is_first_sight_not_a_crash(self):
        """Catches: a history entry of the wrong shape (hand-edited or half-written state) raising on
        every run, which would leave the guard permanently silent."""
        bad = [{"start": 111},
               {"start": 111, "idle_since": "x", "last_ts": 990, "last_cpu_ms": 1.0},
               {"start": 111, "idle_since": 1000, "last_ts": None, "last_cpu_ms": 1.0},
               "garbage", []]
        for entry in bad:
            new, idle = G.step_idle(entry, self._s(111, 5.0), 1000, self.cfg)
            self.assertEqual(idle, 0, repr(entry))
            self.assertEqual(new["start"], 111, repr(entry))


class ClassifyTests(unittest.TestCase):
    def setUp(self):
        self.cfg = env_cfg(ceiling_mb=150, idle_sec=600, idle_sec_pressure=180)

    def test_table(self):
        """Catches: wrong comparison direction/boundary on the footprint ceiling or on the
        idle requirement, and the pressure tier not shortening the idle requirement."""
        cases = [  # fp_mb, idle_for_s, pressure, want
            (100.0, 9999, False, "OK"),              # light renderer is never heavy, however idle
            (149.9, 9999, False, "OK"),
            (150.0, 9999, False, "HEAVY_IDLE"),      # boundary: >= ceiling is heavy
            (300.0, 599, False, "HEAVY_NOT_IDLE"),
            (300.0, 600, False, "HEAVY_IDLE"),       # boundary: >= required idle
            (300.0, 200, True, "HEAVY_IDLE"),        # pressure: 180 s is enough
            (300.0, 179, True, "HEAVY_NOT_IDLE"),
            (300.0, 0, False, "HEAVY_NOT_IDLE"),
            (300.0, 0, True, "HEAVY_NOT_IDLE"),
        ]
        for fp, idle, pressure, want in cases:
            self.assertEqual(G.classify(fp, idle, pressure, self.cfg), want,
                             "fp=%s idle=%s pressure=%s" % (fp, idle, pressure))

    def test_a_first_sight_is_never_idle_even_with_zero_requirement(self):
        """Catches: idle_for=0 satisfying a required idle of 0 (unknown history read as
        'proven idle')."""
        cfg = env_cfg(ceiling_mb=150, idle_sec=0, idle_sec_pressure=0)
        self.assertEqual(G.classify(300.0, 0, False, cfg), "HEAVY_NOT_IDLE")

    def test_nonsense_ceiling_config_cannot_make_everything_heavy(self):
        """Catches: a ceiling of 0 / garbage parsing to 0 and flagging every renderer
        (mass tab closure from a typo in the plist)."""
        for bad in ("0", "-5", "abc", ""):
            cfg = env_cfg(ceiling_mb=bad, idle_sec=1, idle_sec_pressure=1)
            self.assertEqual(G.classify(30.0, 9999, False, cfg), "OK", "ceiling=%r" % bad)


class ConfigTests(unittest.TestCase):
    def test_only_an_explicit_1_arms_the_guard(self):
        """Catches: a typo in the kill switch (ACTION=off / yes / empty) falling back to the LIVE
        default, so an operator who tried to disarm the guard leaves it closing tabs."""
        self.assertEqual(G.Config.from_env({}).action, 1)        # absent: the documented default
        for raw, want in (("1", 1), (" 1 ", 1), ("0", 0), ("off", 0), ("yes", 0), ("true", 0),
                          ("", 0), ("2", 0), ("-1", 0)):
            self.assertEqual(G.Config.from_env({"CDP_TAB_GUARD_ACTION": raw}).action, want, repr(raw))

    def test_ping_timeouts_default_and_never_shrink_under_pressure(self):
        """Catches: a garbage or zero PING_S making every page read as dead at once (nothing could ever
        be mapped or closed), and the pressure ping ending up SHORTER than the normal one (the box is
        slowest exactly when the longer ping is needed)."""
        c = env_cfg()
        self.assertEqual((c.ping_s, c.ping_s_pressure), (5.0, 20.0))
        for raw in ("0", "-3", "abc", "", "nan", "inf"):
            self.assertEqual(env_cfg(ping_s=raw).ping_s, 5.0, repr(raw))
            self.assertEqual(env_cfg(ping_s_pressure=raw).ping_s_pressure, 20.0, repr(raw))
        self.assertEqual(env_cfg(ping_s=9).ping_s, 9.0)
        self.assertEqual(env_cfg(ping_s=30, ping_s_pressure=10).ping_s_pressure, 30.0)


class PingTimeoutTests(unittest.TestCase):
    """The liveness ping is what separates a crashed tab (dead: never blocks a close) from a slow one."""

    class FakeClient:
        def __init__(self, ping_times_out):
            self.ping_times_out = ping_times_out
            self.calls = []

        def call(self, method, params=None, session_id=None, timeout=None):
            self.calls.append((method, (params or {}).get("expression"), timeout))
            if method == "Target.getTargets":
                return {"targetInfos": []}
            if method == "Target.attachToTarget":
                return {"sessionId": "s1"}
            if method == "Runtime.evaluate" and (params or {}).get("expression") == "1" and self.ping_times_out:
                raise G.CDPTimeout("timed out waiting for the browser")
            return {}

        def close(self):
            pass

    def test_the_ping_uses_the_configured_timeout(self):
        """Catches: the timeout staying hard-wired at 5 s while the knob and the pressure value are
        decoration."""
        client = self.FakeClient(ping_times_out=False)
        G.Prober(client, [], 40, ping_s=7.5).probe("t1")
        ping = [c for c in client.calls if c[0] == "Runtime.evaluate" and c[1] == "1"]
        self.assertEqual([c[2] for c in ping], [7.5])

    def test_a_ping_timeout_is_a_dead_page_and_says_how_long_it_waited(self):
        """Catches: a page that misses the ping being filed as anything but dead (blocking every close
        forever), a log that hides how long the guard waited, and a crashed tab being handed the long
        work evaluate anyway (it would cost the whole 30 s work timeout on every run: the reason the
        ping exists)."""
        client = self.FakeClient(ping_times_out=True)
        with self.assertRaises(G.PageDead) as cm:
            G.Prober(client, [], 40, ping_s=7.5).probe("t1")
        self.assertIn("7.5", str(cm.exception))
        work = [c for c in client.calls if c[0] == "Runtime.evaluate" and c[1] != "1"]
        self.assertEqual(work, [], "a page that missed the ping must not be given the long work evaluate")

    def test_memory_pressure_selects_the_longer_ping(self):
        """Catches: the pressure ping being computed by Config but never handed to the prober."""
        seen = []

        class Recording(G.Prober):
            def __init__(self, *a, **k):
                super().__init__(*a, **k)
                seen.append(self.ping_s)

        cfg = env_cfg(ping_s=6, ping_s_pressure=17)
        for pressure in (False, True):
            with mock.patch.object(G, "Prober", Recording), \
                    mock.patch.object(G.CDPClient, "connect", return_value=self.FakeClient(False)), \
                    mock.patch.object(G, "wait_for_quiet", return_value=[]):
                G.act(cfg, {}, [], [], time.time(), False, lambda msg: True, pressure)
        self.assertEqual(seen, [6.0, 17.0])


class LoadStateTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="cdp-tab-guard-loadstate-")
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.cfg = env_cfg(state_dir=self.dir)
        self.logged = []

    def _load(self, text=None):
        if text is not None:
            pathlib.Path(self.cfg.state_path).write_text(text)
        return G.load_state(self.cfg, self.logged.append)

    def test_missing_file_is_an_empty_normalized_state(self):
        self.assertEqual(self._load(), {"pids": {}, "closes": [], "last_heartbeat": 0, "ext": {}, "ext_recycles": []})

    def test_wrong_shapes_are_replaced_not_propagated(self):
        """Catches: valid JSON of the wrong shape raising in every run. The crash comes before the
        state is rewritten, so it would never heal."""
        st = self._load('{"pids": [], "closes": "x", "last_heartbeat": "y"}')
        self.assertEqual(st, {"pids": {}, "closes": [], "last_heartbeat": 0, "ext": {}, "ext_recycles": []})
        self.assertTrue(any("STATE" in line for line in self.logged), "repair must be visible: %r" % self.logged)

    def test_well_typed_parts_survive_and_junk_parts_are_dropped(self):
        """Catches: throwing away good history because one entry is junk (the guard would forget
        how long every tab has been idle)."""
        st = self._load('{"pids": {"5": {"start": 1}, "6": "junk"}, "closes": [1.5, "x", true, 2],'
                        ' "last_heartbeat": 7}')
        self.assertEqual(st, {"pids": {"5": {"start": 1}}, "closes": [1.5, 2], "last_heartbeat": 7,
                              "ext": {}, "ext_recycles": []})

    def test_extension_history_survives_a_round_trip_and_junk_in_it_is_dropped(self):
        """Catches: load_state forgetting the extension-renderer history on every run (the guard would see
        every heavy extension renderer as 'first sight' forever and never reach the grace), or trusting
        a hand-edited entry of the wrong type."""
        st = self._load('{"pids": {}, "closes": [], "last_heartbeat": 0, "ext": {"7": {"start": 3, "over_since": 9},'
                        ' "8": "junk"}, "ext_recycles": [5, "x", true, 6.5]}')
        self.assertEqual(st["ext"], {"7": {"start": 3, "over_since": 9}})
        self.assertEqual(st["ext_recycles"], [5, 6.5])

    def test_a_state_written_before_the_extension_keys_existed_is_not_reported_as_damage(self):
        """Catches: a STATE-had-an-unexpected-shape warning on every first run after the deploy, which
        would teach the reader to ignore that line."""
        st = self._load('{"pids": {"5": {"start": 1}}, "closes": [1.5], "last_heartbeat": 7}')
        self.assertEqual(st["ext"], {})
        self.assertEqual(st["ext_recycles"], [])
        self.assertEqual(self.logged, [])


class BusyRenderersTests(unittest.TestCase):
    def test_a_process_that_exited_is_not_busy(self):
        """Catches: normal renderer churn (one exiting during the check) deferring every run."""
        self.assertEqual(G.busy_renderers([4194301], window_s=0.05), [])

    def test_a_one_hertz_bursty_neighbour_is_caught_by_the_default_window(self):
        """Catches: a check window shorter than the period of a throttled background timer (1 Hz).
        The burst then falls outside the window about half the time and the guard places tabs while
        a neighbour is about to burn CPU.
        A synthetic clock and CPU counter drive this, on purpose: an earlier version spawned a real
        child that burns 40 ms a second, and on a starved box (this suite runs reniced to the floor at
        load 50+) the child simply did not get the CPU, so the test measured the machine, not the code."""
        clock = [1000.0]
        burst_ms, burst_s = 40.0, 0.04          # a 1 Hz timer burns 40 ms at the start of every second

        def cpu_ms(t):
            whole, frac = divmod(t, 1.0)
            return whole * burst_ms + min(frac, burst_s) / burst_s * burst_ms

        def fake_read_proc(_pid):
            return {"cpu_ms": cpu_ms(clock[0]), "footprint_mb": 0.0, "start": 1}

        def fake_sleep(seconds):
            clock[0] += seconds

        with mock.patch.object(G, "read_proc", fake_read_proc), mock.patch.object(G.time, "sleep", fake_sleep):
            for i in range(8):                  # eight phases of the 1 s cycle: a 0.5 s window misses the burst on 4 of them
                clock[0] = 1000.0 + i * 0.125
                self.assertEqual(G.busy_renderers([7]), [7], "phase %.3f s" % (i * 0.125))

    def test_an_alive_but_unreadable_process_counts_as_busy(self):
        """Catches: 'cannot read its CPU' being treated as 'quiet'. An unreadable renderer could be
        the one burning CPU and drowning the probe. (pid 1 is alive but unreadable to this user.)"""
        self.assertEqual(G.busy_renderers([1], window_s=0.05), [1])


class WaitForQuietTests(unittest.TestCase):
    @staticmethod
    def _scripted(answers):
        seq, calls = iter(answers), []

        def check(pids):
            calls.append(list(pids))
            return next(seq)
        return check, calls

    def test_sporadic_noise_does_not_defer(self):
        """Catches: hard-deferring on a single noisy look. On the production Chrome some extension
        renderer burst over 15 ms in 22% of 1.2 s windows (measured), so a one-look rule would leave
        the guard blind about one run in five."""
        check, calls = self._scripted([[7], [7], []])
        self.assertEqual(G.wait_for_quiet([7], attempts=3, pause_s=0, check=check), [])
        self.assertEqual(len(calls), 3)

    def test_persistent_noise_still_defers_with_the_last_look(self):
        """Catches: giving up on noise too early (the neighbour that is still busy on the last look
        must be reported so the guard does not place tabs while it burns CPU)."""
        check, calls = self._scripted([[7], [7, 9], [9]])
        self.assertEqual(G.wait_for_quiet([7, 9], attempts=3, pause_s=0, check=check), [9])
        self.assertEqual(len(calls), 3)

    def test_a_quiet_first_look_returns_at_once(self):
        """Catches: always spending every attempt (each look costs more than a second)."""
        check, calls = self._scripted([[]])
        self.assertEqual(G.wait_for_quiet([7], attempts=3, pause_s=0, check=check), [])
        self.assertEqual(len(calls), 1)


class PressureTests(unittest.TestCase):
    def test_table(self):
        """Catches: treating an unmeasured value as pressure or as a reading of zero, and
        wrong boundaries on either signal."""
        cfg = env_cfg(pressure_total_mb=6000, pressure_swap_mb=8000)
        cases = [  # total_mb, swap_mb, want
            (5999, 7999, False),
            (6000, 0, True),
            (100, 8000, True),
            (100, None, False),    # swap unmeasured: judge on the total alone
            (None, 9000, True),    # total unmeasured but swap high: still pressure
            (None, None, False),   # nothing measured: not asserting pressure
        ]
        for total, swap, want in cases:
            self.assertEqual(G.is_pressure(total, swap, cfg), want, "total=%s swap=%s" % (total, swap))


class PickProbePidTests(unittest.TestCase):
    def test_table(self):
        """Catches: mapping a tab to the wrong renderer (=> closing the wrong tab): picking
        the argmax with no confidence floor, or when two processes both burned CPU."""
        cases = [  # cpu-ms deltas per pid during a 150 ms busy loop, want pid
            ({101: 148.0, 102: 3.0}, 101),
            ({101: 60.0, 102: 1.0}, 101),          # boundary: 40% of the probe is enough
            ({101: 59.9, 102: 1.0}, None),         # too little burn: cannot trust
            ({101: 150.0, 102: 80.0}, None),       # runner-up burned >= 50% of the top: ambiguous
            ({101: 150.0, 102: 74.0}, 101),        # runner-up < 50% of the top
            ({}, None),
        ]
        for deltas, want in cases:
            self.assertEqual(G.pick_probe_pid(deltas, 150), want, str(deltas))


def _t(tid, typ="page", url="https://example.test/", parent=None):
    d = {"targetId": tid, "type": typ, "url": url, "title": "t", "attached": False}
    if parent:
        d["parentFrameId"] = parent
    return d


def _targets(*ts):
    return {t["targetId"]: t for t in ts}


ALL_TARGETS = _targets(
    _t("P1", url="http://127.0.0.1:8299/"), _t("P2", url="about:blank"),
    _t("P3", url="https://a.test/"), _t("P4", url="https://b.test/"),
    _t("X1", url="chrome://settings/"),
    _t("E1", typ="service_worker", url="chrome-extension://abc/sw.js"),
)


class AttributeProbeBurnTests(unittest.TestCase):
    def test_table(self):
        """Catches: a probe's CPU going uncredited because the attempt was below the placement
        confidence floor (the work calibration warming up, or a retry): that burn then reads as tab
        activity at the next sample. Also: crediting an ambiguous attempt (activity would be hidden),
        and crediting without a cap (real activity could be absorbed)."""
        cases = [  # deltas, probe_ms, want
            ({101: 48.0, 102: 2.0}, 150, (101, 48.0)),       # under-powered (below the 60 ms floor) but clear
            ({101: 148.0, 102: 3.0}, 150, (101, 148.0)),
            ({101: 300.0, 102: 1.0}, 50, (101, 200.0)),      # capped at 4x the probe
            ({101: 60.0, 102: 40.0}, 50, None),              # two renderers burned: cannot say which is ours
            ({101: 0.0, 102: 0.0}, 50, None),                # nothing burned
            ({}, 50, None),
        ]
        for deltas, probe_ms, want in cases:
            self.assertEqual(G.attribute_probe_burn(deltas, probe_ms), want, str(deltas))


class DecideTests(unittest.TestCase):
    def setUp(self):
        self.cfg = env_cfg(max_close_run=2, max_close_hour=8, min_pages_keep=1)

    @staticmethod
    def _c(pid, fp):
        return {"pid": pid, "fp_mb": fp, "idle_for_s": 700}

    def _decide(self, cands, mapping, targets=None, closes_last_hour=0):
        return G.decide(cands, mapping, targets if targets is not None else ALL_TARGETS,
                        self.cfg, closes_last_hour)

    def _one(self, out):
        self.assertEqual(len(out), 1, out)
        return out[0]

    def test_closes_the_single_page_mapped_to_a_heavy_idle_renderer(self):
        """Catches: never emitting a close (the whole point of the guard)."""
        d = self._one(self._decide([self._c(10, 3000.0)], {10: ["P1"]}))
        self.assertEqual((d["action"], d["target"]), ("CLOSE", "P1"))

    def test_unmapped_renderer_is_skipped_never_guessed(self):
        """Catches: closing some tab when the renderer->tab mapping is unknown (third state
        collapsed into 'safe to close')."""
        for mapping in ({}, {10: []}, {10: ["ZZ"]}):     # ZZ vanished from the target list
            d = self._one(self._decide([self._c(10, 3000.0)], mapping))
            self.assertEqual((d["action"], d["reason"]), ("SKIP", "UNMAPPED"), str(mapping))

    def test_two_pages_sharing_a_renderer_are_skipped(self):
        """Catches: closing one tab of a shared renderer (frees nothing, may kill a tab in use)."""
        d = self._one(self._decide([self._c(10, 3000.0)], {10: ["P1", "P3"]}))
        self.assertEqual((d["action"], d["reason"]), ("SKIP", "SHARED"))

    def test_internal_and_non_page_targets_are_never_closed(self):
        """Catches: closing chrome:// UI pages or extension/service-worker targets."""
        d = self._one(self._decide([self._c(10, 3000.0)], {10: ["X1"]}))
        self.assertEqual((d["action"], d["reason"]), ("SKIP", "PROTECTED_URL"))
        d = self._one(self._decide([self._c(10, 3000.0)], {10: ["E1"]}))
        self.assertEqual((d["action"], d["reason"]), ("SKIP", "NOT_A_PAGE"))

    def test_the_last_page_is_never_closed(self):
        """Catches: leaving Chrome with zero pages (playwright connectOverCDP then fails with
        'Browser context management is not supported' for every agent)."""
        only_p1 = _targets(_t("P1", url="http://127.0.0.1:8299/"))
        d = self._one(self._decide([self._c(10, 3000.0)], {10: ["P1"]}, only_p1))
        self.assertEqual((d["action"], d["reason"]), ("SKIP", "KEEP_LAST_PAGE"))

    def test_two_heavy_pages_and_nothing_else_closes_only_the_heaviest(self):
        """Catches: evaluating each page against the ORIGINAL page count, closing both."""
        two = _targets(_t("P1"), _t("P3"))
        out = self._decide([self._c(11, 2000.0), self._c(10, 3000.0)], {10: ["P1"], 11: ["P3"]}, two)
        got = [(d["target"], d["action"], d.get("reason")) for d in out]
        self.assertEqual(got, [("P1", "CLOSE", "HEAVY_IDLE"), ("P3", "SKIP", "KEEP_LAST_PAGE")])

    def test_per_run_cap_skips_the_lightest_first(self):
        """Catches: an unbounded number of closes per run (a bad mapping could empty the
        browser), and closing the light one instead of the heavy one."""
        out = self._decide([self._c(12, 1000.0), self._c(10, 3000.0), self._c(11, 2000.0)],
                           {10: ["P1"], 11: ["P3"], 12: ["P4"]})
        got = [(d["target"], d["action"], d.get("reason")) for d in out]
        self.assertEqual(got, [("P1", "CLOSE", "HEAVY_IDLE"), ("P3", "CLOSE", "HEAVY_IDLE"),
                               ("P4", "SKIP", "CAP_RUN")])

    def test_per_hour_cap_counts_closes_already_done(self):
        """Catches: forgetting closes from earlier runs (a flapping tab could be closed
        every minute forever)."""
        out = self._decide([self._c(10, 3000.0), self._c(11, 2000.0)], {10: ["P1"], 11: ["P3"]},
                           closes_last_hour=7)
        got = [(d["target"], d["action"], d.get("reason")) for d in out]
        self.assertEqual(got, [("P1", "CLOSE", "HEAVY_IDLE"), ("P3", "SKIP", "CAP_HOUR")])


# ─────────────── extension-renderer recycle (ga-1wvxej0) ───────────────

PS_EXT_FIXTURE = "\n".join([
    _ps_line(100, 1, _MAIN + " --remote-debugging-port=9222 --user-data-dir=/Users/x/.chrome-cdp --no-first-run about:blank"),
    _ps_line(101, 100, _RENDERER + " --type=renderer --extension-process --renderer-client-id=5"),
    _ps_line(102, 100, _RENDERER + " --type=renderer --renderer-client-id=6"),                       # a tab's renderer
    _ps_line(103, 100, _GPU + " --type=gpu-process"),
    _ps_line(104, 100, _RENDERER + " --type=renderer --extension-process-foo"),                      # near-miss token
    _ps_line(105, 100, _GPU + " --type=utility --extension-process"),                                # not a renderer
    _ps_line(106, 101, _RENDERER + " --type=renderer --extension-process"),                          # grandchild
    _ps_line(200, 1, _MAIN + " --remote-debugging-port=9333 --user-data-dir=/tmp/other about:blank"),
    _ps_line(201, 200, _RENDERER + " --type=renderer --extension-process"),                          # other family
    _ps_line(107, 100, _RENDERER + " --type=renderer --lang=en --extension-process --foo=bar"),      # flag not first
])


class ParseExtensionRenderersTests(unittest.TestCase):
    def test_only_direct_renderer_children_with_the_exact_flag(self):
        """Catches: signalling a tab's renderer (loses a logged-in session), a GPU/utility helper, another
        Chrome's renderer, a grandchild, or a flag that merely starts with --extension-process."""
        self.assertEqual(sorted(G.parse_extension_renderers(PS_EXT_FIXTURE, 100)), [101, 107])
        self.assertEqual(G.parse_extension_renderers(PS_EXT_FIXTURE, 200), [201])
        self.assertEqual(G.parse_extension_renderers(PS_EXT_FIXTURE, 999), [])
        self.assertEqual(G.parse_extension_renderers("", 100), [])

    def test_user_data_dir_of_the_main_process(self):
        self.assertEqual(G.main_user_data_dir(PS_EXT_FIXTURE, 100), "/Users/x/.chrome-cdp")
        self.assertIsNone(G.main_user_data_dir(PS_EXT_FIXTURE, 101))      # a renderer has none
        self.assertIsNone(G.main_user_data_dir(PS_EXT_FIXTURE, 999))


class StepExtTests(unittest.TestCase):
    def setUp(self):
        self.cfg = env_cfg(ext_ceiling_mb=1000, ext_grace_sec=120, max_gap_sec=300)

    @staticmethod
    def _s(fp, start=11):
        return {"footprint_mb": fp, "cpu_ms": 0.0, "start": start}

    def test_under_the_ceiling_is_never_over(self):
        e, over = G.step_ext(None, self._s(999.0), 1000.0, self.cfg)
        self.assertEqual(over, 0)
        self.assertIsNone(e["over_since"])

    def test_first_sight_over_the_ceiling_is_not_recyclable(self):
        """Catches: recycling on the first reading (a transient spike would cost the extension a restart)."""
        e, over = G.step_ext(None, self._s(1200.0), 1000.0, self.cfg)
        self.assertEqual(over, 0)
        self.assertEqual(e["over_since"], 1000.0)

    def test_time_over_accumulates_across_runs(self):
        e, _ = G.step_ext(None, self._s(1200.0), 1000.0, self.cfg)
        e, over = G.step_ext(e, self._s(1300.0), 1060.0, self.cfg)
        self.assertEqual(over, 60)
        e, over = G.step_ext(e, self._s(1400.0), 1125.0, self.cfg)
        self.assertEqual(over, 125)

    def test_dropping_under_the_ceiling_restarts_the_clock(self):
        """Catches: a renderer that came back down still carrying its old 'over since'."""
        e, _ = G.step_ext(None, self._s(1200.0), 1000.0, self.cfg)
        e, over = G.step_ext(e, self._s(300.0), 1060.0, self.cfg)
        self.assertEqual(over, 0)
        e, over = G.step_ext(e, self._s(1200.0), 1120.0, self.cfg)
        self.assertEqual(over, 0)                   # restarted, not 120
        self.assertEqual(e["over_since"], 1120.0)

    def test_history_that_cannot_be_trusted_counts_as_first_sight(self):
        """Catches: a recycled pid number, a long unobserved gap, a clock that went backwards, or a
        malformed entry being read as time spent over the ceiling."""
        good = {"start": 11, "over_since": 1000.0, "last_ts": 1060.0}
        cases = {
            "other process behind the pid": (dict(good, start=12), 1120.0),
            "gap longer than max_gap_sec": (good, 1060.0 + 301.0),
            "clock went backwards": (good, 1050.0),
            "over_since in the future": (dict(good, over_since=5000.0), 1120.0),
            "over_since not a number": (dict(good, over_since="x"), 1120.0),
            "last_ts missing": ({"start": 11, "over_since": 1000.0}, 1120.0),
            "bool timestamps": (dict(good, over_since=True, last_ts=True), 1120.0),
            "not a dict": ("junk", 1120.0),
            "none": (None, 1120.0),
        }
        for name, (entry, now) in cases.items():
            with self.subTest(name):
                e, over = G.step_ext(entry, self._s(1200.0), now, self.cfg)
                self.assertEqual(over, 0)
                self.assertEqual(e["over_since"], now)
        e, over = G.step_ext(good, self._s(1200.0), 1120.0, self.cfg)         # positive control
        self.assertEqual(over, 120)


class ExtDecideTests(unittest.TestCase):
    def test_table(self):
        """Catches: recycling before the grace, no cap on a renderer that re-bloats after every recycle,
        and the cap hiding a renderer that has not yet earned a recycle."""
        cfg = env_cfg(ext_grace_sec=120, ext_max_recycle_hour=2)
        table = [(0, 0, "WAIT"), (-5, 0, "WAIT"), (119, 0, "WAIT"), (120, 0, "RECYCLE"), (500, 1, "RECYCLE"),
                 (500, 2, "CAPPED"), (120, 3, "CAPPED"), (119, 5, "WAIT")]
        for over, recent, want in table:
            with self.subTest(over=over, recent=recent):
                self.assertEqual(G.ext_decide(over, recent, cfg), want)


class ExtConfigTests(unittest.TestCase):
    def test_defaults(self):
        c = env_cfg()
        self.assertEqual((c.ext_ceiling_mb, c.ext_grace_sec, c.ext_max_recycle_hour, c.ext_recycle),
                         (1536.0, 120, 2, 1))

    def test_garbage_falls_back_to_the_default_and_never_to_zero(self):
        """Catches: a typo lowering the ceiling or the grace to 0 (recycle everything at once)."""
        for k, bad in (("ext_ceiling_mb", "abc"), ("ext_ceiling_mb", "0"), ("ext_ceiling_mb", "-5"),
                       ("ext_ceiling_mb", "nan"), ("ext_grace_sec", "0"), ("ext_grace_sec", "x"),
                       ("ext_grace_sec", "-1"), ("ext_max_recycle_hour", "-1"), ("ext_max_recycle_hour", "x")):
            with self.subTest(k=k, bad=bad):
                c = env_cfg(**{k: bad})
                self.assertEqual((c.ext_ceiling_mb, c.ext_grace_sec, c.ext_max_recycle_hour), (1536.0, 120, 2))

    def test_only_an_explicit_1_arms_the_recycle(self):
        """Catches: 'off'/'yes'/'' leaving a disarm attempt live (same rule as ACTION)."""
        self.assertEqual(env_cfg(ext_recycle=1).ext_recycle, 1)
        self.assertEqual(env_cfg(ext_recycle=" 1 ").ext_recycle, 1)
        for v in ("0", "off", "yes", "", "true", "2"):
            with self.subTest(v=v):
                self.assertEqual(env_cfg(ext_recycle=v).ext_recycle, 0)


class RecycleExtensionRendererTests(unittest.TestCase):
    """recycle_extension_renderer with the process table, the clock and the signals faked."""

    PID, START = 501, 77

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="cdp-tab-guard-extrecycle-")
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.cfg = env_cfg(state_dir=self.dir, ext_ceiling_mb=1000)
        self.cand = {"pid": self.PID, "fp_mb": 1800.0, "over_for_s": 130, "start": self.START}
        self.state = {"ext_recycles": []}
        self.lines, self.signals = [], []
        self.alive = True
        self.identity = [True]          # popped per call; the last value repeats
        self.start_now = self.START

    def _log(self, msg):
        self.lines.append(msg)
        return True

    def _ident(self, pid, main_pid):
        return self.identity.pop(0) if len(self.identity) > 1 else self.identity[0]

    def _sig(self, pid, sig):
        self.signals.append((pid, sig))
        if sig == signal.SIGTERM and self.dies_on_term:
            self.alive = False
        if sig == signal.SIGKILL:
            self.alive = False

    dies_on_term = True

    def run_recycle(self, live=True, heap=None, log=None, now=5000.0, term_wait=0.5, kill_wait=0.5):
        heap = heap if heap is not None else [("a" * 32, "Claude", 900.0, 2)]
        proc = (lambda pid: {"footprint_mb": 1800.0, "cpu_ms": 0.0, "start": self.start_now}) \
            if self.start_now is not None else (lambda pid: None)
        heap_fn = heap if callable(heap) else (lambda port, udd: heap)
        with mock.patch.object(G, "_ext_identity", side_effect=self._ident), \
                mock.patch.object(G, "read_proc", side_effect=proc), \
                mock.patch.object(G, "_send_signal", side_effect=self._sig), \
                mock.patch.object(G, "_pid_alive", side_effect=lambda pid: self.alive), \
                mock.patch.object(G, "ext_heap_by_extension", side_effect=heap_fn), \
                mock.patch.object(G, "EXT_TERM_WAIT_S", term_wait), \
                mock.patch.object(G, "EXT_KILL_WAIT_S", kill_wait):
            return G.recycle_extension_renderer(self.cfg, self.state, self.cand, 100, "/Users/x/.chrome-cdp",
                                                now, live, log or self._log)

    def text(self):
        return "\n".join(self.lines)

    def test_positive_control_one_sigterm_logged_before_and_counted(self):
        """Catches: no signal at all, SIGKILL as the first move, a signal without the durable RECYCLING_EXT
        line before it, and an attempt that is not counted (the hourly cap would never see it)."""
        self.assertTrue(self.run_recycle())
        self.assertEqual(self.signals, [(self.PID, signal.SIGTERM)])
        t = self.text()
        self.assertLess(t.index("EXT_ATTRIB"), t.index("RECYCLING_EXT"))
        self.assertLess(t.index("RECYCLING_EXT"), t.index("RECYCLED_EXT"))
        self.assertIn("sigkill=False", t)
        self.assertEqual(self.state["ext_recycles"], [5000.0])
        on_disk = json.loads(pathlib.Path(self.cfg.state_path).read_text())
        self.assertEqual(on_disk["ext_recycles"], [5000.0], "the attempt must be on disk before the wait")

    def test_attribution_names_the_extension_and_its_heap(self):
        self.run_recycle(heap=[("b" * 32, "Loom", None, 1), ("a" * 32, "Claude", 900.0, 2)])
        self.assertIn("%s (Claude) heap=900MB targets=2" % ("a" * 32), self.text())
        self.assertIn("%s (Loom) heap=? targets=1" % ("b" * 32), self.text())

    def test_dry_run_signals_nothing_but_still_leaves_the_evidence(self):
        """Catches: WOULD_RECYCLE_EXT that signals anyway, and a dry run that throws the attribution away."""
        self.assertFalse(self.run_recycle(live=False))
        self.assertEqual(self.signals, [])
        self.assertIn("WOULD_RECYCLE_EXT", self.text())
        self.assertIn("EXT_ATTRIB", self.text())
        self.assertNotIn("RECYCLING_EXT", self.text())
        self.assertEqual(self.state["ext_recycles"], [])

    def test_something_else_behind_the_pid_is_never_signalled(self):
        """Catches: pid reuse (a tab's renderer or any process now owns the number), a ps that failed
        (None), and a process that cannot be read: unknown is never a reason to signal."""
        for name, ident, start in (("other start time", [True], 78), ("not an extension renderer", [False], 77),
                                   ("ps could not tell", [None], 77), ("unreadable", [True], None)):
            with self.subTest(name):
                self.lines.clear(), self.signals.clear()
                self.identity, self.start_now = list(ident), start
                self.assertFalse(self.run_recycle())
                self.assertEqual(self.signals, [])
                self.assertIn("SKIP EXT_CHANGED", self.text())

    def test_a_change_during_the_evidence_pass_is_caught_by_the_second_check(self):
        """Catches: checking identity once, then spending up to EXT_ATTRIB_BUDGET_S reading CDP before
        the signal (the pid can be reused in that window)."""
        self.identity = [True, False]
        self.assertFalse(self.run_recycle())
        self.assertEqual(self.signals, [])
        self.assertIn("RECYCLING_EXT", self.text())          # it got as far as the durable line
        self.assertIn("SKIP EXT_CHANGED", self.text())
        self.assertEqual(self.state["ext_recycles"], [])

    def test_a_log_that_cannot_be_written_means_no_signal(self):
        """Catches: signalling with no durable record of why."""
        def log(msg):
            self.lines.append(msg)
            return not msg.startswith("RECYCLING_EXT")
        self.assertFalse(self.run_recycle(log=log))
        self.assertEqual(self.signals, [])

    def test_attribution_that_fails_does_not_block_the_recycle(self):
        """Catches: evidence gathering (CDP down, a wedged extension target) becoming a precondition."""
        def boom(port, udd):
            raise OSError("cdp down")
        self.assertTrue(self.run_recycle(heap=boom))
        self.assertEqual(self.signals, [(self.PID, signal.SIGTERM)])
        self.assertIn("EXT_ATTRIB unavailable", self.text())

    def test_sigkill_only_when_sigterm_did_not_work(self):
        """Catches: SIGKILL sent regardless, and SIGTERM-ignoring renderers staying up."""
        self.dies_on_term = False
        self.assertTrue(self.run_recycle())
        self.assertEqual(self.signals, [(self.PID, signal.SIGTERM), (self.PID, signal.SIGKILL)])
        self.assertIn("RECYCLED_EXT", self.text())
        self.assertIn("sigkill=True", self.text())

    def test_a_renderer_that_survives_both_signals_is_reported_as_ineffective(self):
        """Catches: reporting success for a process that is still there."""
        def stubborn(pid, sig):
            self.signals.append((pid, sig))
        with mock.patch.object(G, "_ext_identity", return_value=True), \
                mock.patch.object(G, "read_proc", return_value={"footprint_mb": 1800.0, "cpu_ms": 0.0, "start": self.START}), \
                mock.patch.object(G, "_send_signal", side_effect=stubborn), \
                mock.patch.object(G, "_pid_alive", return_value=True), \
                mock.patch.object(G, "ext_heap_by_extension", return_value=[]), \
                mock.patch.object(G, "EXT_TERM_WAIT_S", 0.5), mock.patch.object(G, "EXT_KILL_WAIT_S", 0.5):
            self.assertTrue(G.recycle_extension_renderer(self.cfg, self.state, self.cand, 100, None, 5000.0,
                                                         True, self._log))
        self.assertEqual([s for _, s in self.signals], [signal.SIGTERM, signal.SIGKILL])
        self.assertIn("RECYCLE_EXT_INEFFECTIVE", self.text())
        self.assertNotIn("RECYCLED_EXT ", self.text())

    def test_a_renderer_that_vanished_before_the_signal_is_not_counted(self):
        """Catches: a recycle that never happened eating the hourly budget."""
        def gone(pid, sig):
            raise ProcessLookupError()
        with mock.patch.object(G, "_ext_identity", return_value=True), \
                mock.patch.object(G, "read_proc", return_value={"footprint_mb": 1800.0, "cpu_ms": 0.0, "start": self.START}), \
                mock.patch.object(G, "_send_signal", side_effect=gone), \
                mock.patch.object(G, "ext_heap_by_extension", return_value=[]):
            self.assertFalse(G.recycle_extension_renderer(self.cfg, self.state, self.cand, 100, None, 5000.0,
                                                          True, self._log))
        self.assertIn("EXT_ALREADY_GONE", self.text())
        self.assertEqual(self.state["ext_recycles"], [])


class ExtDisplayNameTests(unittest.TestCase):
    def setUp(self):
        self.udd = tempfile.mkdtemp(prefix="cdp-tab-guard-udd-")
        self.addCleanup(shutil.rmtree, self.udd, ignore_errors=True)

    def _ext(self, ext_id, manifest, messages=None, ver="1.0_0"):
        d = pathlib.Path(self.udd, "Default", "Extensions", ext_id, ver)
        d.mkdir(parents=True)
        (d / "manifest.json").write_text(json.dumps(manifest))
        if messages is not None:
            (d / "_locales" / manifest.get("default_locale", "en")).mkdir(parents=True)
            (d / "_locales" / manifest.get("default_locale", "en") / "messages.json").write_text(json.dumps(messages))

    def test_plain_localised_and_unreadable_names(self):
        """Catches: a name lookup that can fail the recycle, or that prints garbage for __MSG_x__."""
        a, b, c = "a" * 32, "b" * 32, "c" * 32
        self._ext(a, {"name": "Claude"})
        self._ext(b, {"name": "__MSG_extName__", "default_locale": "en"}, {"extname": {"message": "Bitwarden"}})
        self._ext(c, {"name": "__MSG_gone__", "default_locale": "en"}, {})
        self.assertEqual(G.ext_display_name(self.udd, a), "Claude")
        self.assertEqual(G.ext_display_name(self.udd, b), "Bitwarden")
        self.assertEqual(G.ext_display_name(self.udd, c), c)                  # unresolvable -> the id
        self.assertEqual(G.ext_display_name(self.udd, "d" * 32), "d" * 32)   # not installed -> the id
        self.assertEqual(G.ext_display_name(None, a), a)                      # profile unknown -> the id


class ExtRunOnceTests(unittest.TestCase):
    """run_once end to end against a REAL throwaway process that looks like an extension renderer. Only the
    `ps -axo` table is faked (a Chrome main with this test as the parent); the footprint read, the identity
    re-check, the signal and the process exit are all real. No Chrome is started and :9222 is never touched."""

    GRACE = 1

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="cdp-tab-guard-extrun-")
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.children = []
        self.addCleanup(self._reap)
        self.real_run = subprocess.run

    def _reap(self):
        for c in self.children:
            if c.poll() is None:
                c.kill()
            c.wait()

    def spawn(self, *flags):
        c = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)", *flags],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children.append(c)
        # Wait until `ps` can see its argv AND the footprint is a real number: a process that has just exec'd
        # reads ~0 MB for a moment, which the guard would (correctly) treat as under any ceiling.
        deadline = time.time() + 15
        while time.time() < deadline:
            out = self.real_run(["ps", "-o", "command=", "-p", str(c.pid)], capture_output=True, text=True).stdout
            got = G.read_proc(c.pid)
            if "time.sleep" in out and got is not None and got["footprint_mb"] >= 2.0:
                return c
            time.sleep(0.05)
        self.fail("throwaway renderer never reached a readable footprint")

    def cfg(self, **kv):
        base = {"state_dir": self.dir, "log": os.path.join(self.dir, "g.log"), "lock": os.path.join(self.dir, "g.lock"),
                "port": 9, "ceiling_mb": 10 ** 9, "ext_ceiling_mb": 1, "ext_grace_sec": self.GRACE,
                "pressure_total_mb": 10 ** 9, "pressure_swap_mb": 10 ** 9, "max_gap_sec": 120}
        base.update(kv)
        return env_cfg(**base)

    def run_guard(self, cfg, child_line_flags, child, main_pid=None):
        main_pid = os.getpid() if main_pid is None else main_pid
        table = "\n".join([
            _ps_line(main_pid, 1, _MAIN + " --remote-debugging-port=%d --user-data-dir=%s" % (cfg.port, self.dir)),
            _ps_line(child.pid, os.getpid(), _RENDERER + " --type=renderer " + child_line_flags),
        ])

        def fake_run(args, *a, **kw):
            if list(args)[:2] == ["ps", "-axo"]:
                return subprocess.CompletedProcess(args, 0, stdout=table, stderr="")
            return self.real_run(args, *a, **kw)
        with mock.patch.object(G.subprocess, "run", side_effect=fake_run):
            return G.run_once(cfg)

    def log_text(self, cfg):
        try:
            return pathlib.Path(cfg.log_path).read_text()
        except FileNotFoundError:
            return ""

    def two_runs(self, cfg, child, flags="--extension-process", **kw):
        self.assertEqual(self.run_guard(cfg, flags, child, **kw), 0)
        time.sleep(self.GRACE + 0.3)
        self.assertEqual(self.run_guard(cfg, flags, child, **kw), 0)

    def test_a_heavy_extension_renderer_is_recycled_after_the_grace_and_only_then(self):
        """Catches: no recycle at all; a recycle on the first reading; the wrong process dying; the cap not
        being recorded; and a status.json that does not say it happened."""
        child = self.spawn("--type=renderer", "--extension-process")
        cfg = self.cfg()
        self.assertEqual(self.run_guard(cfg, "--extension-process", child), 0)
        self.assertIsNone(child.poll(), "first sight must not recycle")
        self.assertIn("EXT_HEAVY pid=%d" % child.pid, self.log_text(cfg))
        time.sleep(self.GRACE + 0.3)
        self.assertEqual(self.run_guard(cfg, "--extension-process", child), 0)
        self.assertEqual(child.wait(timeout=15), -signal.SIGTERM)
        t = self.log_text(cfg)
        self.assertIn("RECYCLING_EXT pid=%d" % child.pid, t)
        self.assertIn("RECYCLED_EXT pid=%d" % child.pid, t)
        self.assertIn("EXT_ATTRIB", t)                       # CDP is unreachable here: the line says so, the recycle went on
        st = json.loads(pathlib.Path(cfg.status_path).read_text())
        self.assertEqual((st["ext_heavy"], st["ext_recycled_this_run"], st["ext_recycles_last_hour"]), (1, 1, 1))
        self.assertEqual(len(json.loads(pathlib.Path(cfg.state_path).read_text())["ext_recycles"]), 1)

    def test_a_tab_renderer_with_the_same_footprint_is_never_touched(self):
        """Catches: the extension path catching ordinary tab renderers (their pages are other agents' work)."""
        child = self.spawn("--type=renderer")
        cfg = self.cfg()
        self.two_runs(cfg, child, flags="--renderer-client-id=3")
        self.assertIsNone(child.poll())
        self.assertNotIn("EXT_HEAVY", self.log_text(cfg))

    def test_disarmed_by_env_is_a_dry_run(self):
        child = self.spawn("--type=renderer", "--extension-process")
        cfg = self.cfg(ext_recycle=0)
        self.two_runs(cfg, child)
        self.assertIsNone(child.poll())
        self.assertIn("WOULD_RECYCLE_EXT", self.log_text(cfg))

    def test_action_not_1_is_a_dry_run(self):
        child = self.spawn("--type=renderer", "--extension-process")
        cfg = self.cfg(action=0)
        self.two_runs(cfg, child)
        self.assertIsNone(child.poll())
        self.assertIn("WOULD_RECYCLE_EXT", self.log_text(cfg))

    def test_kill_switch_file_is_a_dry_run(self):
        """Catches: the DISABLED file stopping tab closes but not this."""
        child = self.spawn("--type=renderer", "--extension-process")
        cfg = self.cfg()
        pathlib.Path(cfg.disabled_path).write_text("")
        self.two_runs(cfg, child)
        self.assertIsNone(child.poll())
        t = self.log_text(cfg)
        self.assertIn("WOULD_RECYCLE_EXT", t)
        self.assertIn("kill switch present", t)

    def test_hourly_cap_leaves_the_renderer_alone_and_says_so(self):
        """Catches: a renderer that re-bloats after every recycle being recycled forever."""
        child = self.spawn("--type=renderer", "--extension-process")
        cfg = self.cfg(ext_max_recycle_hour=2)
        now = time.time()
        pathlib.Path(cfg.state_path).write_text(json.dumps(
            {"pids": {}, "closes": [], "last_heartbeat": 0, "ext": {}, "ext_recycles": [now - 30, now - 90]}))
        self.two_runs(cfg, child)
        self.assertIsNone(child.poll())
        self.assertIn("EXT_RECYCLE_CAPPED pid=%d" % child.pid, self.log_text(cfg))

    def test_a_recycle_older_than_an_hour_no_longer_counts(self):
        child = self.spawn("--type=renderer", "--extension-process")
        cfg = self.cfg(ext_max_recycle_hour=1)
        now = time.time()
        pathlib.Path(cfg.state_path).write_text(json.dumps(
            {"pids": {}, "closes": [], "last_heartbeat": 0, "ext": {}, "ext_recycles": [now - 3700]}))
        self.two_runs(cfg, child)
        self.assertEqual(child.wait(timeout=15), -signal.SIGTERM)

    def test_a_renderer_under_the_ceiling_is_left_alone(self):
        child = self.spawn("--type=renderer", "--extension-process")
        cfg = self.cfg(ext_ceiling_mb=10 ** 6)
        self.two_runs(cfg, child)
        self.assertIsNone(child.poll())
        self.assertNotIn("EXT_HEAVY", self.log_text(cfg))

    def test_a_pid_that_changed_hands_between_runs_starts_its_clock_again(self):
        """Catches: carrying 'over since' from one process to the next one that gets the same pid."""
        child = self.spawn("--type=renderer", "--extension-process")
        cfg = self.cfg()
        self.assertEqual(self.run_guard(cfg, "--extension-process", child), 0)
        state = json.loads(pathlib.Path(cfg.state_path).read_text())
        state["ext"][str(child.pid)]["start"] += 1            # as if another process now answered to this pid
        pathlib.Path(cfg.state_path).write_text(json.dumps(state))
        time.sleep(self.GRACE + 0.3)
        self.assertEqual(self.run_guard(cfg, "--extension-process", child), 0)
        self.assertIsNone(child.poll(), "history of another process must not count")

    def test_only_the_heaviest_candidate_is_recycled_per_run(self):
        """Catches: several extension renderers signalled in one run (their respawns would share one grace and
        the hourly cap would be spent in a single tick), and the lighter one being picked."""
        cfg = self.cfg()
        table = "\n".join([_ps_line(os.getpid(), 1, _MAIN + " --remote-debugging-port=%d --user-data-dir=%s" % (cfg.port, self.dir)),
                           _ps_line(901, os.getpid(), _RENDERER + " --type=renderer --extension-process"),
                           _ps_line(902, os.getpid(), _RENDERER + " --type=renderer --extension-process")])
        fp = {901: 2000.0, 902: 3000.0}

        def fake_run(args, *a, **kw):
            if list(args)[:2] == ["ps", "-axo"]:
                return subprocess.CompletedProcess(args, 0, stdout=table, stderr="")
            return self.real_run(args, *a, **kw)
        picked = []
        with mock.patch.object(G.subprocess, "run", side_effect=fake_run), \
                mock.patch.object(G, "read_proc", side_effect=lambda pid: {"footprint_mb": fp[pid], "cpu_ms": 0.0, "start": pid}
                                  if pid in fp else None), \
                mock.patch.object(G, "recycle_extension_renderer", side_effect=lambda c, st, cand, *a: picked.append(cand["pid"]) or True):
            self.assertEqual(G.run_once(cfg), 0)
            self.assertEqual(picked, [])                     # first sight
            time.sleep(self.GRACE + 0.3)
            self.assertEqual(G.run_once(cfg), 0)
        self.assertEqual(picked, [902])

    def test_unreadable_state_recycles_nothing(self):
        """Catches: a corrupt state file reading as 'over the ceiling for a long time'."""
        child = self.spawn("--type=renderer", "--extension-process")
        cfg = self.cfg()
        pathlib.Path(cfg.state_path).write_text("{not json")
        self.assertEqual(self.run_guard(cfg, "--extension-process", child), 0)
        self.assertIsNone(child.poll())


class ReadProcTests(unittest.TestCase):
    def test_own_process_footprint_and_cpu_units(self):
        """Catches: wrong units. A bytes-vs-MB slip inflates the footprint 10^6x; forgetting
        the mach timebase skews CPU deltas ~40x, which makes activity detection meaningless."""
        a = G.read_proc(os.getpid())
        self.assertIsNotNone(a)
        blob = bytearray(b"\x01") * (200 * 1024 * 1024)      # exactly 200 MB, every page touched
        grew = G.read_proc(os.getpid())["footprint_mb"] - a["footprint_mb"]
        self.assertTrue(170.0 <= grew <= 240.0, "allocated 200 MB, footprint grew %.1f MB" % grew)
        del blob
        # Burn 300 ms of CPU by the OS's OWN CPU clock, not wall time: on this box the load
        # average sits at 40+ on 10 cores, where 300 ms of CPU can take several seconds of wall.
        p0 = time.process_time()
        while time.process_time() - p0 < 0.30:
            pass
        os_ms = (time.process_time() - p0) * 1000.0
        b = G.read_proc(os.getpid())
        burned = b["cpu_ms"] - a["cpu_ms"]
        self.assertTrue(0.9 * os_ms <= burned <= 1.2 * os_ms + 20.0,
                        "read_proc saw %.1f ms, the OS clock saw %.1f ms" % (burned, os_ms))
        self.assertEqual(a["start"], b["start"])

    def test_unreadable_pid_is_none_not_zero(self):
        """Catches: an unreadable process being reported as a 0 MB (perfectly light) renderer."""
        self.assertIsNone(G.read_proc(4194301))


class CdpClientTimeoutTests(unittest.TestCase):
    def test_a_silent_server_cannot_hang_the_guard(self):
        """Catches: a CDP endpoint that accepts and never answers blocking the run forever
        (a stuck guard is a silent guard)."""
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        self.addCleanup(srv.close)
        t0 = time.time()
        with self.assertRaises(Exception):
            G.CDPClient.connect(srv.getsockname()[1], timeout=0.5)
        self.assertLess(time.time() - t0, 4.0)


# ───────────────────── end-to-end against a real Chrome ─────────────────────

HEAVY_HTML = ("<script>const a=new Uint8Array(260*1024*1024);"
              "for(let i=0;i<a.length;i+=4096)a[i]=1;window.__a=a;</script><p>heavy</p>")
# The busy fixtures burn a fixed amount of WORK (not wall time: a wall-clock loop gets only a fraction of a CPU on
# a loaded box). V8 compiles the loop to ~0.9 ns/iteration (measured 2026-09-19: 20e6 iterations = ~18 ms of CPU),
# so the sizes below are in ms of CPU at that rate.
HEAVY_BUSY_HTML = (HEAVY_HTML +      # ~14 ms of CPU every 60 ms: far above the idle line at any load
                   "<script>setInterval(()=>{let x=0;for(let i=0;i<15e6;i++)x+=Math.sqrt(i);window.__x=x;},60);</script>")
LIGHT_HTML = "<p>light</p>"
# A 1 Hz burst is what background-tab throttling leaves. It must clear the guard's "busy" line (15 ms per 1.2 s
# window) by a wide margin: the 20e6-iteration version (~18 ms) sat 3 ms above it, so any window that clipped the
# burst read as quiet, the guard (correctly) went on to close the heavy tab, and this suite flaked under load.
# 100e6 iterations = ~90 ms of CPU per burst. The 1 Hz window-length rule itself is pinned deterministically by
# BusyRenderersTests.test_a_one_hertz_bursty_neighbour_is_caught_by_the_default_window.
BUSY_HTML = ("<script>setInterval(()=>{let x=0;for(let i=0;i<100e6;i++)x+=Math.sqrt(i);window.__x=x;},1000);"
             "</script><p>busy</p>")


def _http(port, path, method="GET", timeout=30):
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read().decode()
    s = body.strip()
    return json.loads(body) if s[:1] in "[{" else body


def wait_for(pred, timeout, what):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            v = pred()
            if v:
                return v
        except Exception:
            pass
        time.sleep(0.25)
    raise AssertionError("timed out waiting for: " + what)


class TestChrome:
    """A private headless Chrome. Test utility only: production code never owns this."""

    def __init__(self, port):
        if port == 9222:
            raise RuntimeError("refusing to run the selftest against the production Chrome (:9222)")
        self.port = port
        self.dir = tempfile.mkdtemp(prefix="cdp-tab-guard-selftest-")
        for name, body in (("light.html", LIGHT_HTML), ("heavy.html", HEAVY_HTML),
                           ("heavy-busy.html", HEAVY_BUSY_HTML),
                           ("busy.html", BUSY_HTML)):
            pathlib.Path(self.dir, name).write_text(body)
        self.proc = subprocess.Popen(
            [CHROME_BIN, "--headless=new", "--remote-debugging-port=%d" % port,
             "--user-data-dir=%s/profile" % self.dir, "--no-first-run",
             "--no-default-browser-check", "--disable-gpu", "about:blank"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(lambda: _http(port, "/json/version", timeout=1), 60, "test Chrome to start")

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(10)
        except Exception:
            self.proc.kill()
        shutil.rmtree(self.dir, ignore_errors=True)

    def pages(self):
        return [t for t in _http(self.port, "/json/list") if t["type"] == "page"]

    def page_urls(self):
        return sorted(t["url"] for t in self.pages())

    def new_page(self, name):
        return _http(self.port, "/json/new?file://%s/%s" % (self.dir, name), method="PUT")["id"]

    def close_page(self, tid):
        _http(self.port, "/json/close/" + tid)

    def reset_pages(self):
        """Leave exactly one about:blank page."""
        for t in self.pages():
            self.close_page(t["id"])
        _http(self.port, "/json/new?about:blank", method="PUT")
        wait_for(lambda: len(self.pages()) == 1, 10, "single blank page")

    def max_renderer_mb(self):
        ps = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True)
        _, rends = G.parse_family(ps, self.port)
        fps = [(G.read_proc(p) or {}).get("footprint_mb", 0.0) for p in rends]
        return max(fps) if fps else 0.0

    def wait_quiet(self, timeout=90.0):
        """Until NO renderer has burned 8 ms or more of CPU over a 2 s window (the post-load GC tail of a
        260 MB page, or a fresh renderer's start-up, is what this waits out)."""
        def quiet():
            ps = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True)
            _, rends = G.parse_family(ps, self.port)
            a = {p: (G.read_proc(p) or {}).get("cpu_ms") for p in rends}
            time.sleep(2.0)
            b = {p: (G.read_proc(p) or {}).get("cpu_ms") for p in rends}
            return all(a[p] is None or b[p] is None or b[p] - a[p] < 8.0 for p in rends)
        wait_for(quiet, timeout, "every renderer to go quiet")

    def new_resident_page(self, name, floor_mb=200.0, quiet=True):
        tid = self.new_page(name)
        wait_for(lambda: self.max_renderer_mb() >= floor_mb, 30, "%s to become resident" % name)
        if quiet:
            self.wait_quiet()
        return tid


def setUpModule():
    global G
    G = _load_guard()


class E2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        global FX
        if not os.path.exists(CHROME_BIN):
            raise RuntimeError("Chrome not found at " + CHROME_BIN)
        FX = TestChrome(TEST_PORT)

    @classmethod
    def tearDownClass(cls):
        global FX
        if FX is not None:
            FX.stop()
            FX = None

    def setUp(self):
        FX.reset_pages()
        self.state = tempfile.mkdtemp(prefix="cdp-tab-guard-state-")
        self.addCleanup(shutil.rmtree, self.state, ignore_errors=True)
        self.log = os.path.join(self.state, "guard.log")
        if os.environ.get("CDP_TAB_GUARD_SELFTEST_SHOW_LOG"):
            self.addCleanup(lambda: print("\n--- guard log (%s) ---\n%s" % (self.id().split(".")[-1], self.log_text())))

    def run_guard(self, port=None, **cfg):
        env = os.environ.copy()
        base = {
            "port": port or TEST_PORT, "state_dir": self.state, "log": self.log,
            "lock": os.path.join(self.state, "guard.lock"),
            "ceiling_mb": 150, "idle_sec": 3, "idle_sec_pressure": 3,
            "pressure_total_mb": 10 ** 9, "pressure_swap_mb": 10 ** 9,   # tier off in tests
            "active_cpu_ms_per_min": 600, "max_gap_sec": 120, "probe_ms": 40, "action": 1,
            # Generous liveness ping: this suite runs reniced to the floor on a loaded box, where a healthy
            # heavy page can miss the production 5 s ping (PROBE dead=1 -> SKIP UNMAPPED, seen three times on
            # 2026-09-19 at load 55+). The tests about dead pages set their own short ping.
            "ping_s": 30, "ping_s_pressure": 30,
        }
        base.update(cfg)
        env.update({"CDP_TAB_GUARD_" + k.upper(): str(v) for k, v in base.items()})
        return subprocess.run([sys.executable, str(GUARD)], env=env, capture_output=True,
                              text=True, timeout=120)

    def log_text(self):
        try:
            return pathlib.Path(self.log).read_text()
        except FileNotFoundError:
            return ""

    def decisive_run(self, page_id, attempts=5, **cfg):
        """Run the guard until `page_id` is gone (at most `attempts` runs, 2 s apart). A run may legitimately
        skip on renderer noise (DEFER_NOISY / UNCONFIRMED) — in production launchd simply runs it again a
        minute later; the test does the same a few seconds later. On a starved box (load 50+, about a million
        page compressions a minute, measured 2026-09-19) healthy pages can also miss the guard's 5 s liveness
        ping for tens of seconds (PROBE dead=N -> SKIP UNMAPPED: inert, by design), so this keeps trying for
        longer than a quiet machine would need; a guard that never closes still fails after `attempts` runs.
        Returns the last CompletedProcess."""
        r = None
        for _ in range(attempts):
            r = self.run_guard(**cfg)
            self.assertEqual(r.returncode, 0, r.stderr)
            if page_id not in {t["id"] for t in FX.pages()}:
                break
            time.sleep(2.0)
        return r

    def two_runs(self, closes=None, **cfg):
        """First sight, let the idle requirement elapse, then the decisive run. With `closes=<page id>` the
        decisive run is retried (see decisive_run) when that page is still open afterwards."""
        time.sleep(1.5)                       # let post-load GC/finalizers settle
        r1 = self.run_guard(**cfg)
        time.sleep(3.5)
        r2 = self.run_guard(**cfg)
        self.assertEqual((r1.returncode, r2.returncode), (0, 0), (r1.stderr, r2.stderr))
        if closes is not None and closes in {t["id"] for t in FX.pages()}:
            time.sleep(2.0)
            r2 = self.decisive_run(closes, attempts=2, **cfg)
        return r2

    # ---- the core contract -------------------------------------------------

    def test_closes_heavy_idle_page_and_frees_its_memory_but_keeps_the_rest(self):
        """Catches: the guard never closing anything; closing a light page (ceiling ignored)
        or the wrong tab (bad renderer->tab mapping); and a close that does not actually
        release the renderer."""
        heavy = FX.new_resident_page("heavy.html")
        light = FX.new_page("light.html")
        self.two_runs(closes=heavy)
        ids = {t["id"] for t in FX.pages()}
        self.assertNotIn(heavy, ids, "heavy idle page must be closed\n" + self.log_text())
        self.assertIn(light, ids, "light page must survive")
        self.assertEqual(len(ids), 2, "light + the blank page remain")
        wait_for(lambda: FX.max_renderer_mb() < 150.0, 15, "heavy renderer memory to be released")
        text = self.log_text()
        self.assertIn("CLOSED", text)
        self.assertIn("heavy.html", text)      # the evaluation log names what it closed

    def test_heavy_but_busy_page_survives(self):
        """Catches: BOTH layers protecting an in-use tab failing at once (the idle tracker resetting
        on CPU activity, and the pre-probe deferral while any renderer burns CPU). Either layer alone
        keeps this tab open, so this proves the system; the idle tracker's own rule is pinned by
        IdleTrackerTests and the deferral by test_a_noisy_neighbour_defers_placement..."""
        busy = FX.new_resident_page("heavy-busy.html", quiet=False)
        self.two_runs()
        self.assertIn(busy, {t["id"] for t in FX.pages()}, self.log_text())
        self.assertIn("HEAVY_NOT_IDLE", self.log_text())

    def test_a_single_run_never_closes_anything(self):
        """Catches: treating a renderer seen for the first time as already idle."""
        heavy = FX.new_resident_page("heavy.html")
        time.sleep(1.5)
        r = self.run_guard(idle_sec=0, idle_sec_pressure=0)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(heavy, {t["id"] for t in FX.pages()})

    def test_never_closes_the_last_remaining_page(self):
        """Catches: closing the only page (every playwright connectOverCDP then breaks)."""
        heavy = FX.new_resident_page("heavy.html")
        for t in FX.pages():
            if t["id"] != heavy:
                FX.close_page(t["id"])
        wait_for(lambda: len(FX.pages()) == 1, 10, "only the heavy page left")
        self.two_runs()
        self.assertEqual([t["id"] for t in FX.pages()], [heavy])
        self.assertIn("KEEP_LAST_PAGE", self.log_text())

    # ---- safety valves -------------------------------------------------------

    def test_dry_run_reports_would_close_and_changes_nothing(self):
        """Catches: the ACTION=0 switch being ignored."""
        heavy = FX.new_resident_page("heavy.html")
        FX.new_page("light.html")
        self.two_runs(action=0)
        self.assertIn(heavy, {t["id"] for t in FX.pages()})
        self.assertIn("WOULD_CLOSE", self.log_text())
        self.assertNotIn("CLOSED", self.log_text())

    def test_kill_switch_file_downgrades_to_dry_run(self):
        """Catches: the on-disk kill switch (touch DISABLED) not stopping the action - it is
        the only way to stop a live guard without unloading the launchd job."""
        heavy = FX.new_resident_page("heavy.html")
        FX.new_page("light.html")
        pathlib.Path(self.state, "DISABLED").write_text("")
        self.two_runs()
        self.assertIn(heavy, {t["id"] for t in FX.pages()})
        self.assertIn("WOULD_CLOSE", self.log_text())

    def test_per_run_cap_limits_closes(self):
        """Catches: no per-run cap (two heavy pages both closed in one run)."""
        FX.new_resident_page("heavy.html")
        FX.new_resident_page("heavy.html")
        FX.new_page("light.html")
        self.two_runs(max_close_run=1)
        for _ in range(2):        # a noisy run may close nothing; production simply runs again a minute later
            if len([t for t in FX.pages() if t["url"].endswith("heavy.html")]) < 2:
                break
            time.sleep(2.0)
            self.run_guard(max_close_run=1)
        heavy_left = [t for t in FX.pages() if t["url"].endswith("heavy.html")]
        self.assertEqual(len(heavy_left), 1, self.log_text())
        self.assertIn("CAP_RUN", self.log_text())

    def test_lock_blocks_a_concurrent_run(self):
        """Catches: two overlapping runs (launchd stacking) - the lock is what makes a
        slow run harmless. While the lock is held nothing is closed; once released the very
        next run acts, proving the lock was the only thing in the way."""
        heavy = FX.new_resident_page("heavy.html")
        FX.new_page("light.html")
        time.sleep(1.5)
        self.assertEqual(self.run_guard().returncode, 0)            # first sight
        time.sleep(3.5)
        held = open(os.path.join(self.state, "guard.lock"), "w")
        self.addCleanup(held.close)
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        r = self.run_guard()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(heavy, {t["id"] for t in FX.pages()})
        self.assertIn("SKIP locked", self.log_text())
        fcntl.flock(held, fcntl.LOCK_UN)
        self.decisive_run(heavy)
        self.assertNotIn(heavy, {t["id"] for t in FX.pages()}, self.log_text())

    # ---- three-state discipline ----------------------------------------------

    def test_corrupt_state_file_is_survivable_and_closes_nothing(self):
        """Catches: a crash on a garbled state file, or garbled state read as 'idle for ever'."""
        heavy = FX.new_resident_page("heavy.html")
        FX.new_page("light.html")
        pathlib.Path(self.state, "state.json").write_text("{not json")
        time.sleep(1.5)
        r = self.run_guard()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(heavy, {t["id"] for t in FX.pages()})
        json.loads(pathlib.Path(self.state, "state.json").read_text())   # healed: valid JSON again

    def test_unmeasurable_port_is_reported_as_unmeasured_not_healthy(self):
        """Catches: 'no Chrome found' being logged/returned like 'all renderers are light'."""
        r = self.run_guard(port=9999)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("UNMEASURED", self.log_text())
        st = json.loads(pathlib.Path(self.state, "status.json").read_text())   # alive but blind, said so
        self.assertIs(st["measured"], False)

    def test_an_attached_cdp_client_does_not_protect_a_heavy_idle_page(self):
        """Catches: 'attached' being used as an in-use signal. Under playwright-mcp EVERY tab
        is attached for as long as any agent session is connected, so protecting attached tabs
        would make the guard toothless in exactly the incident it was written for."""
        heavy = FX.new_resident_page("heavy.html")
        FX.new_page("light.html")
        client = G.CDPClient.connect(TEST_PORT, timeout=10)
        self.addCleanup(client.close)
        client.call("Target.attachToTarget", {"targetId": heavy, "flatten": True})
        self.two_runs(closes=heavy)
        self.assertNotIn(heavy, {t["id"] for t in FX.pages()}, self.log_text())

    # ---- placement hazards ------------------------------------------------------

    def test_a_crashed_tab_neither_hangs_nor_blocks_the_guard(self):
        """Catches: a probe waiting out its whole timeout on a crashed tab (the run would die on
        the hard alarm every minute for as long as that tab exists), or a dead page blocking every
        close (crashed tabs are routine on this Chrome, so the guard would be toothless)."""
        heavy = FX.new_resident_page("heavy.html")
        FX.new_page("light.html")
        crashed = FX.new_page("light.html")
        time.sleep(1.5)
        client = G.CDPClient.connect(TEST_PORT, timeout=20)
        self.addCleanup(client.close)
        ps = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True)
        _, rends = G.parse_family(ps, TEST_PORT)
        prober, pid = G.Prober(client, rends, 40, ping_s=30.0), None
        for _ in range(8):                  # a loaded box can make one probe ambiguous
            pid = G.pick_probe_pid(prober.probe(crashed), 40)
            if pid is not None:
                break
            time.sleep(1.0)
        self.assertIsNotNone(pid, "could not place the tab that is about to be crashed")
        os.kill(pid, signal.SIGKILL)
        time.sleep(1.5)
        t0 = time.time()
        # A short ping keeps the crashed tab cheap; the harness's generous default would make it cost 30 s.
        self.two_runs(closes=heavy, ping_s=8, ping_s_pressure=8)
        self.assertLess(time.time() - t0, 100, "runs took too long: " + self.log_text())
        ids = {t["id"] for t in FX.pages()}
        self.assertNotIn(heavy, ids, self.log_text())
        self.assertIn(crashed, ids, "the guard must not touch a tab it was not asked about")
        self.assertRegex(self.log_text(), r"dead=[1-9]")     # the crashed tab was read as dead (a starved box may add more)
        # That a dead tab is never handed the 30 s work evaluate is pinned deterministically by
        # PingTimeoutTests. A wall-clock bound on the probe phase would only measure how starved the box
        # is (41 s on 2026-09-19 at load 50, for a run that closed the right tab).

    def test_a_noisy_neighbour_defers_placement_instead_of_guessing(self):
        """Catches: placing tabs by CPU while another tab burns CPU (the neighbour drowns the probe
        and a tab can be mis-placed, so the wrong one could be closed). The guard must wait for a
        quiet moment and then act."""
        heavy = FX.new_resident_page("heavy.html")
        FX.new_page("light.html")
        busy = FX.new_page("busy.html")
        self.two_runs()
        self.assertIn(heavy, {t["id"] for t in FX.pages()}, self.log_text())
        self.assertIn("DEFER_NOISY", self.log_text())
        FX.close_page(busy)
        time.sleep(1.5)
        self.decisive_run(heavy)
        self.assertNotIn(heavy, {t["id"] for t in FX.pages()}, self.log_text())

    def test_two_tabs_in_one_renderer_are_never_closed(self):
        """Catches: closing one tab of a renderer that hosts several (it frees nothing, and the tab
        that goes may be the one in use)."""
        heavy = FX.new_resident_page("heavy.html")
        client = G.CDPClient.connect(TEST_PORT, timeout=20)
        self.addCleanup(client.close)
        sid = client.call("Target.attachToTarget", {"targetId": heavy, "flatten": True})["sessionId"]
        client.call("Runtime.evaluate", {"expression": "window.open('file://%s/light.html'); 1" % FX.dir,
                                         "userGesture": True}, session_id=sid)
        wait_for(lambda: len(FX.pages()) == 3, 10, "the popup that shares the renderer")
        client.call("Target.detachFromTarget", {"sessionId": sid})
        before = {t["id"] for t in FX.pages()}
        self.two_runs()
        self.assertEqual({t["id"] for t in FX.pages()}, before, self.log_text())
        self.assertIn("SHARED", self.log_text())

    # ---- placement safety valves (fault injected at the Prober boundary only) --------

    def _heavy_candidate(self):
        ps = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True)
        _, rends = G.parse_family(ps, TEST_PORT)
        best = max(rends, key=lambda p: (G.read_proc(p) or {"footprint_mb": 0.0})["footprint_mb"])
        return rends, {"pid": best, "fp_mb": G.read_proc(best)["footprint_mb"], "idle_for_s": 999}

    def _act(self, prober_cls, state=None):
        """Run the guard's real act() against the real Chrome with `prober_cls` as the placement
        mechanism. Returns (closes made, the log lines it wrote)."""
        rends, cand = self._heavy_candidate()
        cfg = env_cfg(port=TEST_PORT, probe_ms=40, state_dir=self.state, ping_s=30, ping_s_pressure=30)
        lines = []

        def log(msg):                       # like the real logger: True means "durably written"
            lines.append(msg)
            return True

        with mock.patch.object(G, "Prober", prober_cls):
            made = G.act(cfg, state if state is not None else {}, [cand], rends, time.time(), True, log)
        return made, "\n".join(lines)

    def test_act_closes_with_the_real_prober_positive_control(self):
        """Catches: a harness that cannot close anything (which would let the two tests below pass
        for the wrong reason)."""
        heavy = FX.new_resident_page("heavy.html")
        FX.new_page("light.html")
        time.sleep(1.5)
        made, log = self._act(G.Prober)
        self.assertEqual(made, 1, log)
        self.assertNotIn(heavy, {t["id"] for t in FX.pages()})

    def test_a_page_that_answered_but_could_not_be_placed_blocks_the_close(self):
        """Catches: closing while some page could not be placed. That page might share the heavy
        renderer, so 'this tab owns the memory' is unproven and the tab that goes may be an
        innocent or in-use one."""
        heavy = FX.new_resident_page("heavy.html")
        FX.new_page("light.html")
        time.sleep(1.5)

        class Ambiguous(G.Prober):
            def map_pages(self, page_ids, budget_s=45.0):
                mapping, _unresolved, dead = super().map_pages(page_ids, budget_s)
                return mapping, [page_ids[0]], dead      # one page answered but cannot be placed

        made, log = self._act(Ambiguous)
        self.assertEqual(made, 0, log)
        self.assertIn(heavy, {t["id"] for t in FX.pages()})
        self.assertIn("PARTIAL_PROBE", log)

    def test_a_placement_that_does_not_reproduce_right_before_closing_is_not_acted_on(self):
        """Catches: closing on a stale placement. Activity that starts after the mapping phase
        (an agent picks the tab up, a neighbour starts burning CPU) moves the CPU signal, and the
        tab that goes would be the wrong one."""
        heavy = FX.new_resident_page("heavy.html")
        FX.new_page("light.html")
        time.sleep(1.5)

        class Drifting(G.Prober):
            confirming = False

            def map_pages(self, page_ids, budget_s=45.0):
                out = super().map_pages(page_ids, budget_s)
                self.confirming = True                   # every probe from here on is the confirmation
                return out

            def probe(self, tid):
                deltas = super().probe(tid)
                if self.confirming and len(deltas) > 1:
                    top = max(deltas, key=deltas.get)
                    wrong = next(p for p in deltas if p != top)
                    return {wrong: 999.0, top: 1.0}      # the signal now lands on another renderer
                return deltas

        made, log = self._act(Drifting)
        self.assertEqual(made, 0, log)
        self.assertIn(heavy, {t["id"] for t in FX.pages()})
        self.assertIn("UNCONFIRMED", log)

    def test_a_guard_that_cannot_log_does_not_close_anything(self):
        """Catches: closing tabs with no durable record. When the log cannot be written (a full disk
        is the very incident this guard exists for) an unrecorded close is worse than none: nobody
        can tell what disappeared or why. With the log fixed, the same state closes the tab."""
        heavy = FX.new_resident_page("heavy.html")
        FX.new_page("light.html")
        time.sleep(1.5)
        self.assertEqual(self.run_guard().returncode, 0)                   # first sight, normal log
        time.sleep(3.5)
        blocker = os.path.join(self.state, "not-a-directory")
        pathlib.Path(blocker).write_text("")
        r = self.run_guard(log=os.path.join(blocker, "guard.log"))         # log path under a regular file
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(heavy, {t["id"] for t in FX.pages()})
        self.assertIn("LOG UNWRITABLE", r.stderr)                            # loud, not silent
        self.decisive_run(heavy)                                           # log fixed: now it acts
        self.assertNotIn(heavy, {t["id"] for t in FX.pages()}, self.log_text())

    def test_a_page_that_fails_for_an_unknown_reason_blocks_the_close(self):
        """Catches: every probe failure being filed as 'dead'. Only 'cannot run JS at all' and 'gone'
        provably cannot share the heavy renderer; a page that errored for any other reason (context
        destroyed by a navigation, a protocol hiccup) is alive and may share it."""
        heavy = FX.new_resident_page("heavy.html")
        light = FX.new_page("light.html")
        time.sleep(1.5)

        class Failing(G.Prober):
            def probe(self, tid):
                if tid == light:
                    raise G.CDPError("Runtime.evaluate: {'code': -32000, 'message': 'Cannot find context'}")
                return super().probe(tid)

        made, log = self._act(Failing)
        self.assertEqual(made, 0, log)
        self.assertIn(heavy, {t["id"] for t in FX.pages()})
        self.assertIn("PARTIAL_PROBE", log)

    def test_a_page_that_vanished_is_dead_not_unresolved(self):
        """Catches: a tab an agent closed a moment ago ('No target with given id') being treated as
        an unplaceable page that blocks every close. It is gone, so it cannot share anything. Uses the
        REAL prober against a really closed target, so it pins Chrome's actual error behaviour."""
        gone = FX.new_page("light.html")
        FX.new_page("light.html")
        time.sleep(1.0)
        FX.close_page(gone)
        time.sleep(0.5)
        client = G.CDPClient.connect(TEST_PORT, timeout=10)
        self.addCleanup(client.close)
        ps = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True)
        _, rends = G.parse_family(ps, TEST_PORT)
        mapping, unresolved, dead = G.Prober(client, rends, 40).map_pages([gone])
        self.assertEqual((mapping, unresolved, dead), ({}, [], [gone]))

    def test_the_guards_probe_cpu_is_recorded_against_the_renderer_it_burned_in(self):
        """Catches: probe CPU never being credited (0) or credited in the wrong units (x1000). With
        probe_ms=40 the mapping probe and the confirmation probe burn roughly 80 ms in the heavy
        renderer; the state hands that number to run_once so it can be excluded from 'activity'."""
        FX.new_resident_page("heavy.html")
        FX.new_page("light.html")
        FX.wait_quiet()
        state = {}
        made, log = self._act(G.Prober, state)
        self.assertEqual(made, 1, log)
        burned = state["own_cpu_ms"]
        self.assertTrue(burned, "nothing recorded: " + log)
        top = max(burned.values())
        self.assertTrue(30.0 <= top <= 400.0, "recorded %r" % burned)

    def test_the_guards_own_probing_does_not_reset_a_tabs_idle_clock(self):
        """Catches: the guard's own probe CPU being read as tab activity end-to-end. A heavy idle tab
        that was probed but not closed (dry run, a cap, a deferral) would look busy at the next run,
        so a tab the guard keeps looking at could never be closed. An idle heavy renderer measures
        ~0.03 ms/s; one 150 ms probe over the ~10-35 s between two runs is 4-15 ms/s, above the 4 ms/s
        threshold used here, so without the credit run 3 sees activity and the tab is never closed."""
        heavy = FX.new_resident_page("heavy.html")           # heavy tab + the blank page, nothing else
        tight = dict(active_cpu_ms_per_min=240, probe_ms=150)   # 4 ms/s; a fresh page's idle-GC bursts are <= ~20 ms
        self.assertEqual(self.run_guard(**tight).returncode, 0)            # first sight
        time.sleep(12)                                                      # dilutes those bursts below the threshold
        r2 = self.run_guard(action=0, **tight)                              # probes the heavy tab, closes nothing
        self.assertEqual(r2.returncode, 0, r2.stderr)
        self.assertIn("WOULD_CLOSE", self.log_text(), "run 2 never reached the probe")
        time.sleep(1.0)
        self.decisive_run(heavy, **tight)                                  # live: the idle clock must have survived
        self.assertNotIn(heavy, {t["id"] for t in FX.pages()}, self.log_text())

    def test_one_ambiguous_confirmation_look_is_not_a_verdict(self):
        """Catches: skipping a close because the confirmation probe was inconclusive ONCE. On a noisy
        machine that is routine (the mapping phase already allows three looks), and the tab would stay
        open until the next run for no reason. A confirmation that keeps failing is still UNCONFIRMED
        (see test_a_placement_that_does_not_reproduce_right_before_closing_is_not_acted_on)."""
        heavy = FX.new_resident_page("heavy.html")
        FX.new_page("light.html")
        FX.wait_quiet()

        class FirstConfirmInconclusive(G.Prober):
            confirming = False
            spent = False

            def map_pages(self, page_ids, budget_s=45.0):
                out = super().map_pages(page_ids, budget_s)
                self.confirming = True
                return out

            def probe(self, tid):
                if self.confirming and not self.spent:
                    self.spent = True
                    return {}                            # one look with nothing conclusive in it
                return super().probe(tid)

        made, log = self._act(FirstConfirmInconclusive)
        self.assertEqual(made, 1, log)
        self.assertNotIn(heavy, {t["id"] for t in FX.pages()})

    def test_status_file_is_a_heartbeat_for_watchers(self):
        """Catches: a guard that runs but leaves no proof of life for the watchdogs."""
        FX.new_page("light.html")
        time.sleep(1.0)
        self.assertEqual(self.run_guard().returncode, 0)
        st = json.loads(pathlib.Path(self.state, "status.json").read_text())
        self.assertLess(abs(time.time() - st["ts"]), 60)
        self.assertIs(st["measured"], True)
        self.assertGreaterEqual(st["renderers"], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
