#!/usr/bin/env python3
"""bands.py — statistical alarm bands for the city's watchers (ga-4mzkfj9). This file is its pure core: slice 1 of 3 (ga-qhs5frj).

## Contents
- Why
- The model
- Three states
- What is here and what is not

## Why
Watchers with a fixed limit repeat for days ("gate under 8,0/h" every 6 h since 26/11): the limit says where the product wants
to be, not whether something CHANGED, so a stable shortfall mails forever and the inbox of the Mayor and of the agents fills
with the same line. Here each metric is judged against its own recent behaviour; the product target stays a reference, never
the trigger of a repeat.

## The model
Detection is deterministic, no model: a series of points (one per fixed time bucket) → a baseline (mean and σ of the last
`baseline_days`, holding out the `test_points` latest points and the points of open alarm episodes, so a failure never becomes
the new normal) → the four Western Electric rules on the latest points → a band: 3 = a point beyond 3σ; 2 = two of three beyond
2σ, same side; 1 = four of five beyond 1σ, or eight in a row on one side of the centre. Count metrics are judged in √(x+3/8)
(Anscombe), where a low-mean Poisson count has a usable lower limit. A human dismissing an alarm puts its points back in the
baseline and widens σ for a while: `accepted_until` and `widen` are inputs here, kept by a later slice.

## Three states
`judge` answers "judged" (a band, 0 included, against a baseline), "learning" (no baseline yet: too few points in the window, or a
series so constant that σ is 0) or "bad-series" (a value or a time that is not a finite number, or points out of order). The last
two carry no band at all: a series that cannot be judged is never "all in band". A metric config the statistics cannot use is no
answer about the series either: ConfigError.

## What is here and what is not
Here: the statistics, as pure functions (no clock, no file, no mail, no action). Not here, in the next slices: bands.yaml and its
reader, the episode state machine and what each band does (log, diagnose read-only, mail, bead for the gate), the watchers' wiring.
"""
import math
import sys

sys.dont_write_bytecode = True  # imported by the watchers from a tracked directory: no __pycache__ there

DIRECTIONS = ("low", "high", "both")
TRANSFORMS = ("none", "sqrt_count")
SQRT_OFFSET = 0.375          # Anscombe: sqrt(x + 3/8) has an almost constant variance (~1/4) for a Poisson count
SQRT_SIGMA_FLOOR = 0.5       # ... i.e. a count is never more regular than sigma 0.5 in that scale (a constant series is not infinitely sure)
RULE_BAND = {"WE1": 3, "WE2": 2, "WE3": 1, "WE4": 1}
# What the statistics read of a metric's config: key -> (kind, range or choices). test_points must cover the longest Western Electric
# window (8 points), or the points held out would not span the pattern that raised the alarm; min_sigma is in the scale the
# statistics run in (√ for sqrt_count).
KNOBS = {
    "direction": ("enum", DIRECTIONS), "transform": ("enum", TRANSFORMS),
    "baseline_days": ("int", (1, 365)), "min_baseline_points": ("int", (5, 100000)), "test_points": ("int", (8, 48)),
    "min_sigma": ("num", (0, 1e12)),
}


class ConfigError(Exception):
    """What the statistics were given to work with (a metric's knobs, the clock, the σ widening, the excluded ranges, the acceptance) cannot be used; the message says which and why."""


class SeriesError(ValueError):
    """A point of the series is not usable (NaN, infinite, not a number, a negative count, out of time order): the series is CORRUPT, never 'quiet'."""


def check_metric(m):
    """`m` itself when every knob the statistics read is there, of its kind and in range; else ConfigError naming the first that is not."""
    # vazio → ConfigError (a missing knob is an error, never a default: the metric would be judged by rules nobody wrote);
    # falhou/ilegível → ConfigError (wrong kind, out of range, NaN)
    if not isinstance(m, dict):
        raise ConfigError("métrica: esperava um bloco de chaves, achei %s" % type(m).__name__)
    for key, (kind, rng) in KNOBS.items():
        if key not in m:
            raise ConfigError("métrica: falta '%s'" % key)
        v = m[key]
        if kind == "enum":
            ok = v in rng
        else:
            ok = isinstance(v, (int, float)) and not isinstance(v, bool) and (kind == "num" or isinstance(v, int)) and rng[0] <= v <= rng[1]
        if not ok:
            raise ConfigError("métrica.%s: %r não vale (esperava %s)" % (key, v, "/".join(rng) if kind == "enum" else "%s %s..%s" % (kind, rng[0], rng[1])))
    return m


def _finite(x):
    """True for an int or float that is a finite number; a bool, a string, None, NaN, an infinity and an int too big for a float are not."""
    if isinstance(x, bool) or not isinstance(x, (int, float)):
        return False
    try:
        return math.isfinite(float(x))
    except OverflowError:   # an int beyond what a float holds
        return False


def to_y(x, transform):
    """The value in the scale the statistics run in. Raises SeriesError for what is not a finite number (or a negative count), and
    ConfigError for a transform that is not one of TRANSFORMS (never read as "none")."""
    if transform not in TRANSFORMS:
        raise ConfigError("transform %.40r não é um de %s" % (transform, "/".join(TRANSFORMS)))
    # vazio → n/a (pure arithmetic); falhou/ilegível → SeriesError, never a skipped point or a zero: a corrupt series must not read as in band
    if not _finite(x):
        raise SeriesError("valor %.40r não é um número finito" % (x,))
    if transform == "sqrt_count":
        if x < 0:
            raise SeriesError("contagem negativa %r" % (x,))
        return math.sqrt(x + SQRT_OFFSET)
    return float(x)


def _series(points, transform):
    """[(ts, y, value)] for `points`: (ts_end, value) pairs in strict time order, oldest first. SeriesError for anything else."""
    # vazio → [] (what an empty series means is for the caller); falhou/ilegível → SeriesError (not a pair, a time or a value that is not a
    # finite number, two points at one instant, points out of order): never a skipped point and never a series quietly put back in order
    out = []
    for i, p in enumerate(points):
        if not isinstance(p, (tuple, list)) or len(p) != 2:
            raise SeriesError("ponto %d não é um par (tempo, valor): %.60r" % (i, p))
        ts, v = p
        if not _finite(ts):
            raise SeriesError("ponto %d: o tempo %.40r não é um número finito" % (i, ts))
        if out and ts <= out[-1][0]:
            raise SeriesError("ponto %d: o tempo %.40r não vem depois do anterior (a série tem de estar em ordem, sem dois pontos no mesmo instante)" % (i, ts))
        out.append((ts, to_y(v, transform), v))
    return out


def _in_ranges(ts, ranges):
    return any(r[0] <= ts and (r[1] is None or ts <= r[1]) for r in ranges)


def _check_context(now, excluded, widen, accepted_until):
    """ConfigError unless the clock, the σ widening, the excluded ranges and the acceptance are usable numbers, in their order. None of
    these would fail by itself: a NaN makes every comparison false, so `accepted_until` NaN reads as "everything was accepted" and ends in
    band 0; so does an `accepted_until` ahead of the clock (a dismissal is never in the future: a time in ms instead of s would put every
    point "already accepted" for good); and a range that ends before it starts drops no point, so the failure it was made for stays in the baseline."""
    # vazio → fine: no excluded range is "no open episode", no accepted_until is "nothing accepted"; falhou/ilegível → ConfigError, never the empty reading
    if not (_finite(now) and _finite(widen) and widen >= 0):
        raise ConfigError("agora %r ou widen %r não servem (esperava números finitos, widen 0 ou mais: um σ negativo inverteria o lado do alarme)" % (now, widen))
    if accepted_until is not None and not (_finite(accepted_until) and accepted_until <= now):
        raise ConfigError("accepted_until %r não serve (esperava um tempo que já passou, até agora, ou nada: uma dispensa não fica à frente do relógio)" % (accepted_until,))
    for r in excluded:
        if not (isinstance(r, (tuple, list)) and len(r) >= 2 and _finite(r[0]) and (r[1] is None or (_finite(r[1]) and r[1] >= r[0]))):
            raise ConfigError("faixa excluída %.60r não serve (esperava [início, fim ou None, id], com o fim no início ou depois dele)" % (r,))


def compute_baseline(points, now, m, excluded, widen, accepted_until=None):
    """(baseline, None) or (None, why). The baseline is the mean and sigma of the last baseline_days, WITHOUT the `test_points`
    latest points (the ones under test) and without the points inside `excluded` ranges ([start, end or None, id]: open alarm
    episodes), so a failure never becomes the new normal while it lasts. `widen` scales sigma (a human dismissed alarms of this
    metric); the points up to `accepted_until` (that human's dismissal) are not under test any more: they ARE the baseline now."""
    check_metric(m)
    # vazio → [] (no range: no open episode); falhou/ilegível → ConfigError when it is not iterable (an error the generator itself raises goes up as
    # it is), never the empty reading. Read ONCE, here: the check, the window anchor and the filter below each walk the ranges, and an iterator
    # already walked by the first would read as "no open episode" to the others
    try:
        excluded = list(excluded)
    except TypeError:
        raise ConfigError("faixas excluídas %.60r não servem (esperava uma lista de [início, fim ou None, id])" % (excluded,))
    _check_context(now, excluded, widen, accepted_until)
    # vazio → (None, why): too few points is LEARNING, not "in band"; falhou/ilegível → SeriesError from _series (a corrupt point), never a shorter baseline
    ys = _series(points, m["transform"])
    held = {p[0] for p in [q for q in ys if accepted_until is None or q[0] > accepted_until][-m["test_points"]:]}
    hist = [p for p in ys if p[0] not in held]
    # An open episode FREEZES the window at the instant it began: rolling on would leave the baseline with nothing but the
    # failure (or nothing at all, and a caller that keeps its old fixed rule while there is no baseline would repeat the alarm).
    anchor = min([now] + [r[0] for r in excluded if r[1] is None])
    horizon = anchor - m["baseline_days"] * 86400.0
    kept = [p for p in hist if p[0] >= horizon and not _in_ranges(p[0], excluded)]
    if len(kept) < m["min_baseline_points"]:
        return None, "%d pontos de base (mínimo %d)" % (len(kept), m["min_baseline_points"])
    n = len(kept)
    mean = sum(p[1] for p in kept) / n
    raw_mean = sum(p[2] for p in kept) / n   # in the metric's own units (what a mail quotes), not in √
    sd = math.sqrt(sum((p[1] - mean) * (p[1] - mean) for p in kept) / (n - 1))
    # a mean or a sum of squares that overflows leaves sd infinite or NaN: every z is then 0 or NaN, beyond nothing, band 0; a count's raw sum can overflow with its √ statistics finite
    if not (math.isfinite(sd) and math.isfinite(raw_mean)):
        raise SeriesError("valores grandes demais: a média ou o desvio estouram")
    sigma = max(sd, m["min_sigma"], SQRT_SIGMA_FLOOR if m["transform"] == "sqrt_count" else 0.0)
    if sigma <= 0:
        return None, "σ = 0: a série é constante, defina min_sigma"
    return {"mean": mean, "sigma": sigma * (1.0 + widen), "sd": sd, "n": n, "raw_mean": raw_mean, "widen": widen}, None


def classify(points, base, m):
    """The decision for the latest points against `base`: the Western Electric rules, each only if the LATEST point is part of
    the pattern (an old violation is not an alarm). WE1 one point beyond 3σ -> band 3; WE2 two of three beyond 2σ -> band 2;
    WE3 four of five beyond 1σ and WE4 eight in a row on one side of the centre -> band 1. Only the sides `direction` names."""
    check_metric(m)
    # vazio → SeriesError (nothing to judge is the caller's "no-data", never band 0); falhou/ilegível → SeriesError from _series
    ys = _series(points, m["transform"])
    if not ys:
        raise SeriesError("série vazia")
    if not (_finite(base.get("mean")) and _finite(base.get("sigma")) and base["sigma"] > 0):   # a σ that is NaN, null or not positive gives a z of NaN or of the wrong side
        raise ConfigError("baseline sem média finita ou sem σ positivo (média %r, σ %r)" % (base.get("mean"), base.get("sigma")))
    zs = [(p[1] - base["mean"]) / base["sigma"] for p in ys]
    last8 = zs[-8:]
    hits = {}
    for side in {"low": ("low",), "high": ("high",), "both": ("low", "high")}[m["direction"]]:
        beyond = (lambda z, k: z < -k) if side == "low" else (lambda z, k: z > k)
        centre = (lambda z: z < 0) if side == "low" else (lambda z: z > 0)
        w3, w5 = last8[-3:], last8[-5:]
        if beyond(last8[-1], 3):
            hits.setdefault("WE1", side)
        if len(w3) >= 2 and beyond(w3[-1], 2) and sum(1 for z in w3 if beyond(z, 2)) >= 2:
            hits.setdefault("WE2", side)
        if len(w5) >= 4 and beyond(w5[-1], 1) and sum(1 for z in w5 if beyond(z, 1)) >= 4:
            hits.setdefault("WE3", side)
        if len(last8) >= 8 and all(centre(z) for z in last8):
            hits.setdefault("WE4", side)
    worst = max(hits, key=lambda r: (RULE_BAND[r], r), default=None)
    last_ts, last_y, last_v = ys[-1]
    return {"band": RULE_BAND[worst] if worst else 0, "rules": sorted(hits), "side": hits.get(worst) if worst else None, "zs": last8,
            "last": {"ts": last_ts, "value": last_v, "y": last_y, "z": zs[-1]},
            "window_start": ys[-m["test_points"]:][0][0], "mean": base["mean"], "sigma": base["sigma"]}


def judge(points, now, m, excluded=(), widen=0.0, accepted_until=None):
    """The verdict on a series, as {"status", "decision", "baseline", "why"}; `points` are (ts_end, value) pairs, oldest first.
      judged      the latest points were judged against a baseline: `decision` (band 0-3, rules, the latest point...) and `baseline` are set.
                  Band 0 is a verdict (in band, or everything there is was accepted by a human); only this status carries a band
      learning    no baseline yet (too few points in the window, or σ = 0: a constant series needs a min_sigma); `decision` is None
      bad-series  a point is unusable (SeriesError: a value or a time that is not a finite number, points out of order); `decision` is None
    ConfigError is raised, never returned: the metric's knobs, `now`, `excluded`, `widen` or `accepted_until` cannot be used, which
    says nothing about the series. How old the latest point is, is the caller's to check: a series whose latest point is days older
    than `now` is still judged, against its old points (until they fall out of baseline_days: then learning), so compare
    decision["last"]["ts"] with the clock, or a dead collector reads as in band."""
    # vazio → learning (an empty series has no baseline), never band 0; falhou/ilegível → bad-series, never a shorter series
    points = list(points)   # read more than once below: an iterator would be empty the second time
    try:
        base, why = compute_baseline(points, now, m, excluded, widen, accepted_until)
        if base is None:
            return {"status": "learning", "decision": None, "baseline": None, "why": why}
        judged = [p for p in points if accepted_until is None or p[0] > accepted_until]
        if judged:
            decision = classify(judged, base, m)
        else:   # a human accepted everything that exists: nothing is under test until a NEW point arrives
            decision = dict(classify(points, base, m), band=0, rules=[], side=None)
    except SeriesError as e:
        return {"status": "bad-series", "decision": None, "baseline": None, "why": str(e)}
    return {"status": "judged", "decision": decision, "baseline": base, "why": ""}
