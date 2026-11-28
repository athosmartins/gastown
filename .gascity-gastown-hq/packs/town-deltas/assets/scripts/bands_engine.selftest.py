#!/usr/bin/env python3
"""bands_engine.selftest.py — hermetic tests of the engine around the bands core (ga-4mzkfj9, slice 2a: ga-wagjc6w).

## Contents
- What it covers
- How to run

## What it covers
The strict reader of bands.yaml (an invalid file is inert, never half-read), the 22-07 h silence, the episode state machine, state and
ledger on disk (absent / corrupt / unreadable are three answers), `process` in shadow (counts what a live run would send, sends nothing)
and the disk collector behind `tick`. Each test works in its own temporary directory: nothing touches the city, the clock, the network.

## How to run
  python3 -I bands_engine.selftest.py        (exit 0 = every case passed; the last line counts them)
"""
import datetime
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("bands", os.path.join(HERE, "bands.py"))
bands = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bands)

H = 3600.0
CFG = """version: 1
silence: "22-07"
metrics:
  gate:
    direction: low
    min_sigma: 1
    fresh_for_h: 2.5
    recover_after_h: 3
%s"""


def at(h, m=30, day=28):
    """Epoch of 2026-11-<day> <h>:<m> BRT (UTC-3)."""
    return datetime.datetime(2026, 11, day, h, m, tzinfo=bands.BRT).timestamp()


def config(extra=""):
    return bands.parse_config_text(CFG % extra)


def steady(now, last=None):
    """Hourly points for 15 days that end at the whole hour before `now`: ~100, the last one `last` if given."""
    end = now - now % H
    pts = [(end - (359 - i) * H, 100.0 + (i % 5) - 2) for i in range(360)]
    return pts[:-1] + [(end, last)] if last is not None else pts


def ledger(city):
    with open(bands.ledger_path(city), encoding="utf-8") as fh:
        return [json.loads(x) for x in fh]


class Reader(unittest.TestCase):
    def test_comments_end_a_bare_value_but_not_a_quoted_one(self):
        t = bands.parse_yaml_subset('# top\n\na: x # c\nb: "p # q"  # c\nc: [1, "z"]   # c\nd:   # c\n  e: 2.5\nf: a#b\n')
        self.assertEqual(t, {"a": "x", "b": "p # q", "c": [1, "z"], "d": {"e": 2.5}, "f": "a#b"})

    def test_what_is_outside_the_subset_is_refused_with_its_line(self):
        bad = ["a: 1\na: 2\n", "a:\n\tb: 1\n", "a:\n   b: 1\n", "a:\n  - b\n", "a: \"x\n", 'a: "x" y\n', "a: {b: 1}\n", "a: [1, , 2]\n", "a: [[1]]\n",
               "a:\nb: 1\n", "a: x: y\n", "a: &anchor\n", "Bad key: 1\n"]
        for text in bad:
            with self.subTest(text), self.assertRaises(bands.ConfigError):
                bands.parse_yaml_subset(text)

    def test_a_config_that_cannot_be_trusted_raises_instead_of_loading_empty(self):
        bad = {"typo in a metric": CFG % "    directon: low\n", "knob out of range": CFG % "    test_points: 3\n",
               "live before the delivery exists": CFG % "    mode: live\n", "tick without a collector": CFG % "    driver: tick\n",
               "a collector without a path": CFG % "    driver: tick\n    collector: disk_free_delta\n", "unknown band action": CFG % "    actions:\n      band1: [mail]\n",
               "unknown top key": "version: 1\nsilnce: off\nmetrics:\n  a:\n    unit: x\n", "wrong version": "version: 2\nmetrics:\n  a:\n    unit: x\n",
               "no metrics": "version: 1\n", "empty silence window": (CFG % "").replace('"22-07"', '"07-07"'), "metric name": (CFG % "").replace("gate:", "Gate:")}
        for why, text in bad.items():
            with self.subTest(why), self.assertRaises(bands.ConfigError):
                bands.parse_config_text(text)

    def test_a_good_file_loads_one_that_is_absent_or_not_a_file_is_an_error_and_the_cli_says_inert(self):
        with tempfile.TemporaryDirectory() as d:
            ok = os.path.join(d, "ok.yaml")
            with open(ok, "w", encoding="utf-8") as fh:
                fh.write(CFG % "")
            self.assertEqual(bands.load_config(ok), config(), "the file that was asked for is the one read, not the default beside the script")
            for path in (os.path.join(d, "nope.yaml"), d):
                with self.subTest(path == d), self.assertRaises(bands.ConfigError):
                    bands.load_config(path)
            out = io.StringIO()
            with redirect_stdout(out), redirect_stderr(io.StringIO()):
                rc, usage = bands.main(["check", "--config", os.path.join(d, "nope.yaml"), "--city", d]), bands.main(["nonsense"])
            self.assertEqual((rc, usage), (2, 64))
            self.assertIn("inertes", out.getvalue())

    def test_the_silence_window_wraps_midnight_and_off_means_never(self):
        w = bands.parse_config_text(CFG % "")["silence"]
        self.assertEqual([bands.in_silence(at(h), w) for h in (21, 22, 23, 3, 6, 7, 12)], [False, True, True, True, True, False, False])
        self.assertFalse(bands.in_silence(at(23), None))
        self.assertEqual([bands.in_silence(at(h), (9, 17)) for h in (8, 9, 16, 17)], [False, True, True, False])


class Episode(unittest.TestCase):
    m = config()["metrics"]["gate"]

    def dec(self, band, rules=("WE1",)):
        return {"band": band, "rules": list(rules), "window_start": 5.0}

    def test_band_1_is_only_logged_2_and_3_are_owed_the_worst_supersedes_a_repeat_is_counted_and_the_input_is_never_edited(self):
        s0 = bands.new_state()
        st, ev, owed = bands.step(s0, self.dec(1, ("WE3",)), 1000.0, self.m, "g")
        self.assertEqual(st["episode"]["done"]["1"]["how"], "log")
        self.assertEqual(s0, bands.new_state(), "step returns a new state: process compares it with the old one to know what to write")
        st, ev, owed = bands.step(st, self.dec(2), 1100.0, self.m, "g")
        self.assertEqual(owed, [2])
        st, ev, owed = bands.step(st, self.dec(3), 1200.0, self.m, "g")
        self.assertEqual((owed, st["episode"]["done"]["2"]["how"], [e["ev"] for e in ev]), ([3], "superseded", ["escalate"]))
        st, ev, owed = bands.step(bands.mark_done(st, 3, 1250.0, "delivered"), self.dec(3), 1300.0, self.m, "g")
        self.assertEqual((owed, ev, st["episode"]["suppressed"]), ([], [], 1))

    def test_the_episode_closes_only_after_recover_after_h_in_band_and_frees_its_points(self):
        st, _, _ = bands.step(bands.new_state(), self.dec(3), 1000.0, self.m, "g")
        st, _, _ = bands.step(st, self.dec(0), 2000.0, self.m, "g")
        self.assertIsNotNone(st["episode"])
        st, ev, _ = bands.step(st, self.dec(3), 3000.0, self.m, "g")   # relapse: the clock of the recovery restarts
        st, _, _ = bands.step(st, self.dec(0), 4000.0, self.m, "g")
        st, ev, _ = bands.step(st, self.dec(0), 4000.0 + 3 * H, self.m, "g")
        self.assertEqual(([e["ev"] for e in ev], st["episode"], len(st["history"])), (["recover"], None, 1))
        self.assertEqual(st["excluded"][0][1], 4000.0, "the excluded range ends where the recovery began")


class Disk(unittest.TestCase):
    def test_state_absent_corrupt_and_unreadable_are_three_different_answers(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "s.json")
            self.assertEqual(bands.read_state(p), (bands.new_state(), "absent"))
            self.assertEqual((bands.write_state(p, bands.new_state()), bands.read_state(p)[1]), (True, "ok"))
            for junk in ("{not json", '{"v": 9}', "[]"):
                with open(p, "w", encoding="utf-8") as fh:
                    fh.write(junk)
                self.assertEqual(bands.read_state(p)[1], "corrupt", junk)
            self.assertEqual(bands.read_state(d), (None, "unreadable"))
            self.assertFalse(bands.write_state(os.path.join(p, "x", "s.json"), bands.new_state()), "a parent that is a file")

    def test_a_missing_reading_is_no_point_and_a_torn_line_is_not_a_zero(self):
        with tempfile.TemporaryDirectory() as d:
            m, now = config("    driver: tick\n    collector: disk_free_delta\n    path: /x\n")["metrics"]["gate"], 40 * 86400.0
            os.makedirs(os.path.dirname(bands.series_path(d, "g")))
            with open(bands.series_path(d, "g"), "w", encoding="utf-8") as fh:
                for h, late in ((1, 0), (2, 0), (3, 1200), (4, 0), (5, 60), (6, 0)):   # the reading of hour 3 is 20 min old at its boundary: too old
                    fh.write(json.dumps({"ts": now - 10 * H + h * H - late, "v": 1000.0 - 10 * h}) + "\n")
                t3 = now - 7 * H   # the boundary of hour 3: a line that is torn, lacks its value or has a null there is NOT a reading of zero
                fh.write('{"ts": 1, "v"\n{"ts": "x", "v": 1}\n{"ts": %d}\n{"ts": %d, "v": null}\n' % (t3, t3))
            pts, why = bands.disk_points(d, "g", m, now)
            hrs = [round((t - (now - 10 * H)) / H) for t, _ in pts]
            self.assertEqual((why, hrs), (None, [2, 5, 6]), "hours 3 and 4 lack a usable reading an hour apart")
            self.assertEqual({v for _, v in pts}, {-10.0})
            os.remove(bands.series_path(d, "g"))
            os.makedirs(bands.series_path(d, "g"))
            self.assertIsNone(bands.disk_points(d, "g", m, now)[0], "an unreadable series is not an empty one")


class Process(unittest.TestCase):
    def run_at(self, d, cfg, now, last=-300.0, **kw):
        return bands.process(d, "gate", cfg, steady(now, last), now, **kw)

    def test_a_drop_in_shadow_opens_one_episode_and_counts_one_delivery_that_was_not_sent(self):
        cfg, now = config(), at(8)
        with tempfile.TemporaryDirectory() as d:
            res = self.run_at(d, cfg, now)
            self.assertEqual((res["status"], res["decision"]["band"], res["owed"], res["rc"]), ("ok", 3, [], 0), res["lines"])
            self.run_at(d, cfg, now + 600)
            evs = [(r["ev"], r.get("band")) for r in ledger(d)]
            self.assertEqual(evs, [("open", 3), ("would_deliver", 3)], "one episode, one counted delivery, however many runs")
            self.assertEqual(bands.read_state(bands.state_path(d, "gate"))[0]["episode"]["done"]["3"]["how"], "shadow")

    def test_in_silence_nothing_is_judged_or_unless_the_metric_says_so_nothing_is_counted_until_morning(self):
        with tempfile.TemporaryDirectory() as d:
            res = self.run_at(d, config(), at(23))
            self.assertEqual(res["status"], "silent")
            self.assertFalse(os.path.exists(bands.state_dir(d)), "a silent run leaves no trace")
        cfg = config("    evaluate_in_silence: true\n")
        with tempfile.TemporaryDirectory() as d:
            res = self.run_at(d, cfg, at(23))
            self.assertEqual((res["status"], res["owed"]), ("ok", [3]), "judged, and still owed: the delivery waits for the morning")
            self.assertEqual([r["ev"] for r in ledger(d)], ["open"])
            self.run_at(d, cfg, at(7, 5, 29))
            self.assertEqual([r["ev"] for r in ledger(d)], ["open", "would_deliver"])

    def test_a_series_that_cannot_be_judged_is_never_band_0(self):
        cfg, now = config(), at(8)
        with tempfile.TemporaryDirectory() as d:
            cases = {"no-data": [], "stale": steady(now - 5 * H), "learning": steady(now)[-10:], "bad-series": steady(now)[:-1] + [(now, float("nan"))]}
            for want, pts in cases.items():
                res = bands.process(d, "gate", cfg, pts, now)
                self.assertEqual((res["status"], res["decision"], res["rc"]), (want, None, 1 if want == "bad-series" else 0), want)
            self.assertFalse(os.path.exists(bands.state_path(d, "gate")), "nothing judged, nothing remembered")

    def test_a_corrupt_state_is_kept_as_evidence_and_an_unstorable_one_does_nothing(self):
        cfg, now = config(), at(8)
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(bands.state_dir(d))
            with open(bands.state_path(d, "gate"), "w", encoding="utf-8") as fh:
                fh.write("{torn")
            res = self.run_at(d, cfg, now)
            self.assertEqual(res["status"], "ok")
            self.assertIn("corrompido", str(res["lines"]))
            self.assertTrue(any(".corrupt-" in n for n in os.listdir(bands.state_dir(d))))
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, ".gc", "state"))
            with open(bands.state_dir(d), "w", encoding="utf-8") as fh:   # the state directory is a file: nothing can be remembered
                fh.write("x")
            res = self.run_at(d, cfg, now)
            self.assertEqual((res["status"], res["rc"], res["owed"]), ("unstorable", 1, []))

    def test_a_second_run_at_the_same_time_does_nothing(self):
        cfg, now = config(), at(8)
        with tempfile.TemporaryDirectory() as d:
            fd, _ = bands._take_lock(d, "gate")
            try:
                res = self.run_at(d, cfg, now)
            finally:
                os.close(fd)
            self.assertEqual((res["status"], res["rc"]), ("busy", 0))
            self.assertFalse(os.path.exists(bands.state_path(d, "gate")))


class Tick(unittest.TestCase):
    cfg = bands.parse_config_text((CFG % "    driver: tick\n    collector: disk_free_delta\n    path: /x\n    mode: shadow\n").replace("gate", "disk"))

    def test_a_reading_that_failed_is_not_recorded_and_says_so(self):
        now = at(8)
        def boom(_p):
            raise OSError("no volume")
        with tempfile.TemporaryDirectory() as d:
            for bad in (boom, lambda _p: float("nan"), lambda _p: -5.0):
                out = bands.tick(d, self.cfg, now, free_fn=bad)["disk"]
                self.assertEqual(out["rc"], 1)
                self.assertIn("WARN", str(out["lines"]))
                self.assertFalse(os.path.exists(bands.series_path(d, "disk")), "never a zero in the series")
            out = bands.tick(d, self.cfg, now, free_fn=lambda _p: 5000.0)["disk"]
            self.assertEqual((out["sampled"], out["rc"], out["status"]), (True, 0, "no-data"))

    def test_dry_run_neither_measures_nor_writes(self):
        with tempfile.TemporaryDirectory() as d:
            out = bands.tick(d, self.cfg, at(8), free_fn=lambda _p: 1 / 0, dry=True)["disk"]
            self.assertEqual((out["rc"], out["sampled"]), (0, False))
            self.assertFalse(os.path.exists(bands.state_dir(d)))

    def test_old_readings_are_forgotten_and_only_metrics_that_measure_themselves_tick(self):
        now = at(8, day=28)
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.dirname(bands.series_path(d, "disk")))
            with open(bands.series_path(d, "disk"), "w", encoding="utf-8") as fh:
                fh.write(json.dumps({"ts": now - 40 * 86400.0, "v": 1.0}) + "\n" + json.dumps({"ts": now - 3600.0, "v": 2.0}) + "\n")
            bands.tick(d, self.cfg, now, free_fn=lambda _p: 3.0)
            self.assertEqual([v for _, v in bands._read_samples(d, "disk")[0]], [2.0, 3.0])
        meter = config()   # a metric of driver meter belongs to its watcher: tick leaves it alone
        self.assertEqual(bands.tick("/nonexistent", meter, now, free_fn=lambda _p: 1.0), {})


def run():
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    res = unittest.TextTestRunner(verbosity=0, stream=sys.stderr).run(suite)
    bad = len(res.failures) + len(res.errors)
    print("bands_engine.selftest: %d ok, %d failed" % (res.testsRun - bad, bad))
    return 0 if res.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(run())
