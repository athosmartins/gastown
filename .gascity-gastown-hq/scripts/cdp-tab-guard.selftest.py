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
HEAVY_BUSY_HTML = (HEAVY_HTML +
                   "<script>setInterval(()=>{const t=performance.now();"
                   "while(performance.now()-t<40){}},60);</script>")
LIGHT_HTML = "<p>light</p>"
BUSY_HTML = ("<script>setInterval(()=>{const t=performance.now();"
             "while(performance.now()-t<40){}},60);</script><p>busy</p>")


def _http(port, path, method="GET", timeout=5):
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

    def new_resident_page(self, name, floor_mb=200.0):
        tid = self.new_page(name)
        wait_for(lambda: self.max_renderer_mb() >= floor_mb, 30, "%s to become resident" % name)
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

    def probe_phase_seconds(self):
        """Seconds between the HEAVY_IDLE evaluation and the PROBE summary in the guard log."""
        import re
        stamps = {}
        for line in self.log_text().splitlines():
            for key in ("HEAVY_IDLE", "PROBE"):
                if "] " + key + " " in line and key not in stamps:
                    stamps[key] = time.mktime(time.strptime(line[1:20], "%Y-%m-%d %H:%M:%S"))
        self.assertEqual(sorted(stamps), ["HEAVY_IDLE", "PROBE"], self.log_text())
        return stamps["PROBE"] - stamps["HEAVY_IDLE"]

    def two_runs(self, **cfg):
        """First sight, let the idle requirement elapse, then the decisive run."""
        time.sleep(1.5)                       # let post-load GC/finalizers settle
        r1 = self.run_guard(**cfg)
        time.sleep(3.5)
        r2 = self.run_guard(**cfg)
        self.assertEqual((r1.returncode, r2.returncode), (0, 0), (r1.stderr, r2.stderr))
        return r2

    # ---- the core contract -------------------------------------------------

    def test_closes_heavy_idle_page_and_frees_its_memory_but_keeps_the_rest(self):
        """Catches: the guard never closing anything; closing a light page (ceiling ignored)
        or the wrong tab (bad renderer->tab mapping); and a close that does not actually
        release the renderer."""
        heavy = FX.new_resident_page("heavy.html")
        light = FX.new_page("light.html")
        self.two_runs()
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
        busy = FX.new_resident_page("heavy-busy.html")
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
        self.assertEqual(self.run_guard().returncode, 0)
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

    def test_an_attached_cdp_client_does_not_protect_a_heavy_idle_page(self):
        """Catches: 'attached' being used as an in-use signal. Under playwright-mcp EVERY tab
        is attached for as long as any agent session is connected, so protecting attached tabs
        would make the guard toothless in exactly the incident it was written for."""
        heavy = FX.new_resident_page("heavy.html")
        FX.new_page("light.html")
        client = G.CDPClient.connect(TEST_PORT, timeout=10)
        self.addCleanup(client.close)
        client.call("Target.attachToTarget", {"targetId": heavy, "flatten": True})
        self.two_runs()
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
        pid = G.pick_probe_pid(G.Prober(client, rends, 40).probe(crashed), 40)
        self.assertIsNotNone(pid, "could not place the tab that is about to be crashed")
        os.kill(pid, signal.SIGKILL)
        time.sleep(1.5)
        t0 = time.time()
        self.two_runs()
        self.assertLess(time.time() - t0, 100, "runs took too long: " + self.log_text())
        ids = {t["id"] for t in FX.pages()}
        self.assertNotIn(heavy, ids, self.log_text())
        self.assertIn(crashed, ids, "the guard must not touch a tab it was not asked about")
        self.assertIn("dead=1", self.log_text())
        # Without the 5 s liveness ping the dead tab costs the whole 30 s work timeout.
        self.assertLess(self.probe_phase_seconds(), 25, self.log_text())

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
        self.assertEqual(self.run_guard().returncode, 0)
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

    def _act(self, prober_cls):
        """Run the guard's real act() against the real Chrome with `prober_cls` as the placement
        mechanism. Returns (closes made, the log lines it wrote)."""
        rends, cand = self._heavy_candidate()
        cfg = env_cfg(port=TEST_PORT, probe_ms=40, state_dir=self.state)
        lines = []
        with mock.patch.object(G, "Prober", prober_cls):
            made = G.act(cfg, {}, [cand], rends, time.time(), True, lines.append)
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

    def test_status_file_is_a_heartbeat_for_watchers(self):
        """Catches: a guard that runs but leaves no proof of life for the watchdogs."""
        FX.new_page("light.html")
        time.sleep(1.0)
        self.assertEqual(self.run_guard().returncode, 0)
        st = json.loads(pathlib.Path(self.state, "status.json").read_text())
        self.assertLess(abs(time.time() - st["ts"]), 60)
        self.assertGreaterEqual(st["renderers"], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
