#!/usr/bin/env python3
"""bands.selftest.py — hermetic tests of bands.py, the pure core of the statistical alarm bands (ga-4mzkfj9, slice 1: ga-qhs5frj).

## Contents
- What it covers
- How to run

## What it covers
The baseline (what is held out, what is dropped, the σ floors), the four Western Electric rules and the three-state verdict of
`judge`: a series that cannot be judged (too short, constant, corrupt, out of order) never reads as band 0, and an input the
statistics cannot use (a knob, the clock, the widening, a range or an acceptance read from a state file) raises instead of
answering. Pure functions only: nothing here touches a file, the clock, the city, a mail or a token.

## How to run
  python3 -I bands.selftest.py        (exit 0 = every case passed; the last line counts them)
"""
import importlib.util
import os
import statistics
import sys
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("bands", os.path.join(HERE, "bands.py"))
bands = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bands)

T0 = 1_700_000_000.0   # an arbitrary epoch; the stats never look at the calendar
H3 = 3 * 3600.0
NAN = float("nan")


def metric(**over):
    """A metric with a default for each knob the statistics read, `over` on top (the code under test checks the result)."""
    return dict({"direction": "low", "transform": "none", "baseline_days": 14, "min_baseline_points": 20, "test_points": 8, "min_sigma": 0.0}, **over)


def series(values, step=H3, start=T0):
    """[(ts_end, value)] one point every `step` seconds, oldest first."""
    return [(start + i * step, float(v)) for i, v in enumerate(values)]


class Transform(unittest.TestCase):
    def test_sqrt_count_is_the_anscombe_scale_and_none_is_the_value(self):
        self.assertAlmostEqual(bands.to_y(9.0, "sqrt_count"), 9.375 ** 0.5)
        self.assertAlmostEqual(bands.to_y(0, "sqrt_count"), 0.375 ** 0.5)
        self.assertEqual(bands.to_y(5, "none"), 5.0)
        self.assertEqual(bands.to_y(-1.0, "none"), -1.0, "only a COUNT cannot be negative")

    def test_what_is_not_a_finite_number_is_an_error_never_a_zero(self):
        for bad in (NAN, float("inf"), "3", None, True, [1], 10 ** 400):
            with self.subTest(repr(bad)[:20]):
                with self.assertRaises(bands.SeriesError):
                    bands.to_y(bad, "none")
        with self.assertRaises(bands.SeriesError):
            bands.to_y(-1.0, "sqrt_count")


class MetricKnobs(unittest.TestCase):
    def test_the_defaults_pass_and_come_back_as_they_are(self):
        m = metric()
        self.assertIs(bands.check_metric(m), m)

    def test_a_missing_knob_is_an_error_never_a_default(self):
        for key in bands.KNOBS:
            with self.subTest(key):
                m = metric()
                del m[key]
                with self.assertRaises(bands.ConfigError):
                    bands.check_metric(m)

    def test_wrong_kind_enum_and_range_are_errors(self):
        bad = (("direction", "lows"), ("direction", None), ("transform", "sqroot"), ("baseline_days", 0), ("baseline_days", 366), ("baseline_days", 1.5),
               ("baseline_days", True), ("min_baseline_points", 4), ("test_points", 7), ("test_points", 49), ("min_sigma", -0.1), ("min_sigma", NAN),
               ("min_sigma", "1"))
        for key, value in bad:
            with self.subTest((key, value)):
                with self.assertRaises(bands.ConfigError):
                    bands.check_metric(metric(**{key: value}))
        with self.assertRaises(bands.ConfigError):
            bands.check_metric(None)

    def test_the_building_blocks_check_the_knobs_too(self):
        pts = series([10, 12] * 15)
        for name, call in (("compute_baseline", lambda: bands.compute_baseline(pts, pts[-1][0], metric(direction="lows"), [], 0.0)),
                           ("classify", lambda: bands.classify(pts, base_of(), metric(test_points=3)))):
            with self.subTest(name):
                with self.assertRaises(bands.ConfigError):
                    call()

    def test_the_edges_of_every_range_pass(self):
        for key, value in (("baseline_days", 1), ("baseline_days", 365), ("min_baseline_points", 5), ("test_points", 8), ("test_points", 48), ("min_sigma", 0), ("min_sigma", 2.5)):
            with self.subTest((key, value)):
                bands.check_metric(metric(**{key: value}))


class Series(unittest.TestCase):
    def test_points_out_of_order_or_two_at_one_instant_are_an_error(self):
        pts = series([10] * 25)
        for name, bad in (("moved ahead of its time", pts[:10] + [pts[12]] + pts[10:12] + pts[13:]), ("the same instant twice", pts[:10] + [pts[9]] + pts[10:])):
            with self.subTest(name):
                with self.assertRaises(bands.SeriesError):
                    bands.compute_baseline(bad, pts[-1][0], metric(), [], 0.0)

    def test_a_point_that_is_not_a_pair_or_has_no_usable_time_is_an_error(self):
        good = series([10] * 25)
        for bad in ((NAN, 1.0), (None, 1.0), (True, 1.0), "xy", (T0 + 99 * H3,), (T0 + 99 * H3, 1.0, 2.0), None):
            with self.subTest(repr(bad)):
                with self.assertRaises(bands.SeriesError):
                    bands.classify(good + [bad], base_of(), metric())

    def test_an_empty_series_is_an_error_for_classify_not_band_0(self):
        with self.assertRaises(bands.SeriesError):
            bands.classify([], base_of(), metric())


class Baseline(unittest.TestCase):
    def setUp(self):
        self.m = metric(min_baseline_points=5, baseline_days=14)

    def test_the_points_under_test_are_held_out(self):
        pts = series([10, 12, 11, 13, 9, 10, 12, 11, 10, 11, 12, 10, 11, 9, 10, 12, 11, 10, 100, 100, 100, 100, 100, 100, 100, 100])
        base, why = bands.compute_baseline(pts, pts[-1][0], self.m, [], 0.0)
        self.assertIsNone(why)
        self.assertEqual(base["n"], len(pts) - 8)
        self.assertLess(base["mean"], 13, "the eight 100s are the test window: they must not be in the baseline")

    def test_points_older_than_baseline_days_are_dropped(self):
        m = metric(min_baseline_points=5, baseline_days=1)
        pts = series([10 + (i % 2) for i in range(40)], step=3600.0)   # hourly; the 32 held-in points are indexes 0..31
        base, _ = bands.compute_baseline(pts, pts[-1][0], m, [], 0.0)
        # now = index 39; one day back is index 15, so indexes 15..31 (17 points) are inside baseline_days=1
        self.assertEqual(base["n"], 17)
        closed, _ = bands.compute_baseline(pts, pts[-1][0], m, [[pts[4][0], pts[9][0], "e1"]], 0.0)
        self.assertEqual(closed["n"], 17, "a CLOSED episode does not freeze the window, only an open one does")

    def test_excluded_ranges_closed_and_open_drop_their_points(self):
        pts = series([10 + (i % 3) for i in range(40)])
        now = pts[-1][0]
        full, _ = bands.compute_baseline(pts, now, self.m, [], 0.0)
        closed, _ = bands.compute_baseline(pts, now, self.m, [[pts[4][0], pts[9][0], "e1"]], 0.0)
        opened, _ = bands.compute_baseline(pts, now, self.m, [[pts[20][0], None, "e2"]], 0.0)
        self.assertEqual(full["n"] - closed["n"], 6)
        self.assertEqual(full["n"] - opened["n"], len(pts) - 8 - 20, "an open-ended range excludes everything from its start on")

    def test_an_open_episode_freezes_the_baseline_window_at_its_start(self):
        # 25 days of normal points (10/11), then 15 days of a failure (1) with the episode open since the first bad point:
        # the rolling window would hold nothing but the failure, so the baseline must keep looking at the 14 days BEFORE it.
        pts = series([10 + (i % 2) for i in range(200)] + [1 + (i % 2) for i in range(120)])
        start, now = pts[200][0], pts[-1][0]
        base, why = bands.compute_baseline(pts, now, self.m, [[start, None, "e1"]], 0.0)
        self.assertIsNone(why)
        self.assertEqual(base["n"], 112)
        self.assertAlmostEqual(base["raw_mean"], 10.5)
        rolling, _ = bands.compute_baseline(pts, now, self.m, [], 0.0)
        self.assertLess(rolling["raw_mean"], 5, "control: without the open episode the failure IS the new normal, which is what the freeze prevents")

    def test_points_up_to_accepted_until_are_baseline_and_only_the_later_ones_are_held_out(self):
        pts = series([10 + (i % 3) for i in range(40)])
        for k, held in ((39, 0), (38, 1), (31, 8)):
            with self.subTest(k):
                base, _ = bands.compute_baseline(pts, pts[-1][0], self.m, [], 0.0, accepted_until=pts[k][0])
                self.assertEqual(base["n"], 40 - held)

    def test_sigma_is_the_sample_deviation_of_the_baseline(self):
        base, _ = bands.compute_baseline(series([10, 12] * 15), T0 + 30 * H3, self.m, [], 0.0)
        self.assertAlmostEqual(base["sd"], statistics.stdev([10.0, 12.0] * 11))
        self.assertAlmostEqual(base["sigma"], base["sd"])

    def test_exactly_min_baseline_points_is_a_baseline_and_one_less_is_not(self):
        enough, _ = bands.compute_baseline(series([10, 12] * 7)[:13], T0 + 13 * H3, self.m, [], 0.0)   # 13 points, 8 held out: 5 kept
        self.assertEqual(enough["n"], 5)
        short, why = bands.compute_baseline(series([10, 12] * 7)[:12], T0 + 12 * H3, self.m, [], 0.0)
        self.assertIsNone(short)
        self.assertIn("4 pontos", why)

    def test_too_few_points_is_learning_not_a_baseline(self):
        base, why = bands.compute_baseline(series([10] * 12), T0 + 12 * H3, metric(min_baseline_points=20), [], 0.0)
        self.assertIsNone(base)
        self.assertIn("pontos", why)

    def test_count_metric_has_a_poisson_sigma_floor_a_constant_series_is_not_infinitely_sure(self):
        m = metric(transform="sqrt_count", min_baseline_points=5)
        base, why = bands.compute_baseline(series([9] * 30), T0 + 30 * H3, m, [], 0.0)
        self.assertIsNone(why)
        self.assertAlmostEqual(base["sigma"], 0.5)
        self.assertAlmostEqual(base["mean"], 9.375 ** 0.5)
        self.assertAlmostEqual(base["raw_mean"], 9.0, msg="what a mail quotes is in the metric's own units, not in √")

    def test_constant_series_without_a_floor_cannot_be_judged(self):
        base, why = bands.compute_baseline(series([9] * 30), T0 + 30 * H3, self.m, [], 0.0)
        self.assertIsNone(base)
        self.assertIn("σ", why)

    def test_min_sigma_floor_applies(self):
        m = metric(min_baseline_points=5, min_sigma=4.0)
        base, _ = bands.compute_baseline(series([10, 10.1] * 15), T0 + 30 * H3, m, [], 0.0)
        self.assertEqual(base["sigma"], 4.0)

    def test_widen_scales_sigma(self):
        pts = series([10, 12] * 15)
        a, _ = bands.compute_baseline(pts, pts[-1][0], self.m, [], 0.0)
        b, _ = bands.compute_baseline(pts, pts[-1][0], self.m, [], 0.5)
        self.assertAlmostEqual(b["sigma"], a["sigma"] * 1.5)
        self.assertAlmostEqual(b["mean"], a["mean"])

    def test_a_corrupt_point_is_an_error_not_a_skipped_point(self):
        pts = series([10] * 20) + [(T0 + 99 * H3, NAN)]
        with self.assertRaises(bands.SeriesError):
            bands.compute_baseline(pts, pts[-1][0], self.m, [], 0.0)

    def test_a_sum_that_overflows_is_an_error_not_a_nan_sigma(self):
        # NaN is beyond nothing: with a NaN σ every z is NaN and every rule reads "in band"
        for name, values in (("the mean", [1e308] * 30), ("the deviation", [1e308, -1e308] * 15)):
            with self.subTest(name):
                with self.assertRaises(bands.SeriesError):
                    bands.compute_baseline(series(values), T0 + 30 * H3, self.m, [], 0.0)

    def test_inputs_the_statistics_cannot_use_raise(self):
        pts = series([10, 12] * 15)
        now = pts[-1][0]
        bad = (dict(now=NAN), dict(now=None), dict(widen=-0.5), dict(widen=NAN), dict(widen=True), dict(accepted_until=NAN), dict(accepted_until="x"),
               dict(excluded=[[NAN, None, "e"]]), dict(excluded=[["a", None, "e"]]), dict(excluded=[[T0, "b", "e"]]), dict(excluded=["e"]), dict(excluded=[[T0]]))
        for over in bad:
            with self.subTest(over):
                args = dict(now=now, excluded=[], widen=0.0, accepted_until=None)
                args.update(over)
                with self.assertRaises(bands.ConfigError):
                    bands.compute_baseline(pts, args["now"], self.m, args["excluded"], args["widen"], args["accepted_until"])


def base_of(mean=0.0, sigma=1.0):
    return {"mean": mean, "sigma": sigma, "sd": sigma, "n": 50, "raw_mean": mean, "widen": 0.0}


def decide(zs, direction="low", **over):
    """classify() over points whose z-scores are `zs` against a standard-normal baseline (transform none)."""
    return bands.classify(series(zs), base_of(), metric(direction=direction, **over))


class WesternElectric(unittest.TestCase):
    def test_rule1_one_point_beyond_3_sigma(self):
        d = decide([0, 0, -3.1])
        self.assertEqual((d["band"], d["rules"]), (3, ["WE1"]))
        self.assertEqual(decide([0, 0, -3.0])["band"], 0, "exactly 3σ is not beyond it")
        self.assertEqual(decide([-3.5, 0, 0])["band"], 0, "an old point beyond 3σ is not an alarm now")

    def test_direction_decides_which_side_alarms(self):
        self.assertEqual(decide([0, 0, 4.0], "low")["band"], 0)
        self.assertEqual(decide([0, 0, 4.0], "high")["band"], 3)
        self.assertEqual(decide([0, 0, 4.0], "both")["band"], 3)
        self.assertEqual(decide([0, 0, -4.0], "high")["band"], 0)
        self.assertEqual(decide([0, 0, -4.0], "both")["band"], 3)

    def test_rule2_two_of_three_beyond_2_sigma_same_side_ending_at_the_latest_point(self):
        d = decide([0, -2.5, -2.2])
        self.assertEqual((d["band"], d["rules"]), (2, ["WE2"]))
        self.assertEqual(decide([-2.5, 0, -2.2])["band"], 2)
        self.assertEqual(decide([-2.5, -2.2, 0])["band"], 0, "the pattern must end at the latest point: an old violation is not an alarm")
        self.assertEqual(decide([2.5, -2.5], "both")["band"], 0, "opposite sides do not add up")
        self.assertEqual(decide([-2.5])["band"], 0)
        self.assertEqual(decide([0, 0, -2.5])["band"], 0, "one of three is not two")

    def test_rule3_four_of_five_beyond_1_sigma_ending_at_the_latest_point(self):
        d = decide([-1.1, -1.2, -0.5, -1.3, -1.4])
        self.assertEqual((d["band"], d["rules"]), (1, ["WE3"]))
        self.assertEqual(decide([-1.1, -1.2, -0.5, -1.3, 0.2])["band"], 0)
        self.assertEqual(decide([-1.1, -0.5, -0.5, -1.3, -1.4])["band"], 0, "three of five are not four")
        self.assertEqual(decide([-1.1, -1.2, -1.3, -1.4, 0.2])["band"], 0, "four of five that do not end at the latest point are an old pattern")
        self.assertEqual(decide([-1.1, -1.2, -1.3, -1.4])["band"], 1, "four points are enough to hold 4 of 5")

    def test_rule4_eight_in_a_row_on_one_side_of_the_centre(self):
        d = decide([-0.2] * 8)
        self.assertEqual((d["band"], d["rules"]), (1, ["WE4"]))
        self.assertEqual(decide([-0.2] * 7)["band"], 0, "seven are not eight")
        self.assertEqual(decide([0.3] + [-0.2] * 7)["band"], 0)
        self.assertEqual(decide([-0.2] * 8, "high")["band"], 0)

    def test_the_band_is_the_worst_rule_and_all_rules_are_named(self):
        d = decide([-1.5, -1.6, -2.4, -2.5, -3.5])
        self.assertEqual(d["band"], 3)
        self.assertEqual(d["rules"], ["WE1", "WE2", "WE3"])

    def test_a_series_that_is_normal_raises_nothing(self):
        self.assertEqual(decide([0.1, -0.4, 0.8, -1.2, 0.3, 0.5, -0.7, 0.2, -0.1, 0.9])["band"], 0)

    def test_the_decision_carries_what_a_mail_needs(self):
        m = metric(transform="sqrt_count")
        base = {"mean": 3.0, "sigma": 0.5, "sd": 0.4, "n": 50, "raw_mean": 9.0, "widen": 0.0}
        d = bands.classify(series([9, 9, 0]), base, m)
        self.assertEqual(d["band"], 3)
        self.assertEqual((d["side"], d["last"]["value"]), ("low", 0.0))
        self.assertLess(d["last"]["z"], -4)
        self.assertEqual(bands.classify(series([9, 9, 9]), base, m)["band"], 0)
        self.assertEqual(d["window_start"], series([9, 9, 0])[0][0], "the exclusion range of an episode starts at the oldest point under test")
        self.assertEqual(bands.classify(series([9, 2.5, 2.5]), base, m)["band"], 2, "2.5 is 2.6σ below in √ but only 1σ in the raw scale")

    def test_the_exclusion_range_starts_at_the_oldest_point_under_test(self):
        pts = series([0] * 20)
        self.assertEqual(bands.classify(pts, base_of(), metric(test_points=12))["window_start"], pts[8][0])

    def test_a_baseline_without_a_usable_sigma_is_an_error_not_band_0(self):
        for name, bad in (("σ 0", base_of(sigma=0.0)), ("σ NaN", base_of(sigma=NAN)), ("σ negative", base_of(sigma=-1.0)), ("σ None", base_of(sigma=None)),
                          ("mean NaN", base_of(mean=NAN)), ("no mean", {"sigma": 1.0})):
            with self.subTest(name):
                with self.assertRaises(bands.ConfigError):
                    bands.classify(series([0, 0, -4.0]), bad, metric())


class Judge(unittest.TestCase):
    def setUp(self):
        self.m = metric(min_baseline_points=5, baseline_days=14)

    def judge(self, pts, **kw):
        return bands.judge(pts, pts[-1][0], self.m, **kw)

    def steady(self, n=40, last=None):
        """n points alternating 10 / 12 (mean 11), the final one replaced by `last` when given."""
        values = [10 + 2 * (i % 2) for i in range(n)]
        if last is not None:
            values[-1] = last
        return series(values)

    def test_a_normal_series_is_judged_band_0_with_its_baseline(self):
        v = self.judge(self.steady())
        self.assertEqual((v["status"], v["decision"]["band"], v["decision"]["rules"], v["why"]), ("judged", 0, [], ""))
        self.assertAlmostEqual(v["baseline"]["mean"], 11.0)

    def test_a_failure_at_the_latest_point_is_band_3_and_names_its_rule(self):
        v = self.judge(self.steady(last=0))
        self.assertEqual((v["status"], v["decision"]["band"], v["decision"]["rules"]), ("judged", 3, ["WE1"]))

    def test_no_base_is_never_band_0(self):
        cases = (("too short", self.judge(series([10, 12] * 5))), ("empty", bands.judge([], T0, self.m)), ("constant", self.judge(series([9] * 40))))
        for name, v in cases:
            with self.subTest(name):
                self.assertEqual(v["status"], "learning")
                self.assertIsNone(v["decision"], "a series with no baseline carries no band at all, and 0 is a band")
                self.assertIsNone(v["baseline"])
        self.assertIn("pontos", cases[0][1]["why"])
        self.assertIn("σ", cases[2][1]["why"])

    def test_a_corrupt_series_is_bad_series_never_a_shorter_one(self):
        def with_point(i, point):
            pts = self.steady()
            pts[i] = point
            return pts
        swapped = self.steady()
        swapped[10], swapped[11] = swapped[11], swapped[10]
        cases = (("NaN in the baseline", with_point(10, (T0 + 10 * H3, NAN))), ("NaN as the latest point", with_point(-1, (T0 + 39 * H3, NAN))),
                 ("a string", with_point(5, (T0 + 5 * H3, "12"))), ("a time that is None", with_point(7, (None, 11.0))), ("out of order", swapped))
        for name, pts in cases:
            with self.subTest(name):
                v = self.judge(pts)
                self.assertEqual(v["status"], "bad-series")
                self.assertIsNone(v["decision"])
                self.assertTrue(v["why"])

    def test_what_the_statistics_cannot_use_raises_instead_of_judging(self):
        pts = self.steady()
        now = pts[-1][0]
        for name, call in (("a knob out of range", lambda: bands.judge(pts, now, metric(test_points=3))),
                           ("a missing knob", lambda: bands.judge(pts, now, {"direction": "low"})),
                           ("a negative widening", lambda: bands.judge(pts, now, self.m, widen=-0.5)),
                           ("a NaN acceptance", lambda: bands.judge(pts, now, self.m, accepted_until=NAN)),
                           ("a malformed range", lambda: bands.judge(pts, now, self.m, excluded=[["a", None, "e"]]))):
            with self.subTest(name):
                with self.assertRaises(bands.ConfigError):
                    call()

    def test_an_open_episode_keeps_the_failure_from_becoming_the_normal(self):
        pts = series([10 + (i % 2) for i in range(200)] + [1 + (i % 2) for i in range(120)])
        episode = [[pts[200][0], None, "e1"]]
        kept = self.judge(pts, excluded=episode)
        self.assertEqual((kept["status"], kept["decision"]["band"]), ("judged", 3))
        self.assertEqual(self.judge(pts)["decision"]["band"], 0, "control: with no episode open the failure is the baseline and nothing alarms")

    def test_a_dismissed_alarm_is_not_under_test_again_but_a_new_point_is(self):
        pts = self.steady(last=-1e6)
        self.assertEqual(self.judge(pts)["decision"]["band"], 3)
        accepted = pts[-1][0]   # the point AT the dismissal was accepted too: judged against a baseline that holds it, it would still alarm
        v = self.judge(pts, accepted_until=accepted)
        self.assertEqual((v["status"], v["decision"]["band"], v["decision"]["rules"], v["decision"]["side"]), ("judged", 0, [], None))
        self.assertLess(v["baseline"]["mean"], -1000, "the accepted point IS the baseline now")
        later = pts + [(accepted + H3, -1e12)]
        w = bands.judge(later, later[-1][0], self.m, accepted_until=accepted)
        self.assertEqual((w["status"], w["decision"]["band"]), ("judged", 3))

    def test_a_count_metric_is_judged_in_the_sqrt_scale(self):
        values = [6, 12] * 20 + [0]       # a mean-9 count that alternates 6 / 12: raw σ is 3.05, so a 0 is only 2.95σ below
        pts = series(values)
        self.assertEqual(bands.judge(pts, pts[-1][0], metric(min_baseline_points=5))["decision"]["band"], 0)
        v = bands.judge(pts, pts[-1][0], metric(min_baseline_points=5, transform="sqrt_count"))
        self.assertEqual((v["decision"]["band"], v["decision"]["rules"]), (3, ["WE1"]))

    def test_an_iterator_is_read_once_and_still_judged(self):
        pts = self.steady(last=0)
        v = bands.judge(iter(pts), pts[-1][0], self.m)
        self.assertEqual((v["status"], v["decision"]["band"]), ("judged", 3))


def run():
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    res = unittest.TextTestRunner(verbosity=0, stream=sys.stderr).run(suite)
    bad = len(res.failures) + len(res.errors)
    print("bands.selftest: %d ok, %d failed%s" % (res.testsRun - bad - len(res.skipped), bad, (", %d skipped" % len(res.skipped)) if res.skipped else ""))
    return 0 if res.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(run())
