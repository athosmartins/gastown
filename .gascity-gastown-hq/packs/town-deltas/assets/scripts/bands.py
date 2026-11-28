#!/usr/bin/env python3
"""bands.py — statistical alarm bands for the city's watchers (ga-4mzkfj9): the pure core (slice 1, ga-qhs5frj) and the engine around it (slice 2a, ga-wagjc6w).

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
Core: the statistics, as pure functions (no clock, no file, no mail, no action). Engine (2a): the strict reader of bands.yaml (an invalid
file is INERT and says so, never half-read), the episode state machine, state and ledger on disk, the 22-07 h silence, and `tick`, which
measures the metrics that measure themselves (free disk, in SHADOW: it counts what a live run would have sent and sends nothing).
Not here, in the next slices: the delivery of each band (diagnosis read-only, mail, bead for the gate: 2b) and the watchers' wiring (3).
"""
import argparse
import bisect
import copy
import datetime
import fcntl
import json
import math
import os
import re
import shutil
import sys
import time
import traceback

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


BRT = datetime.timezone(datetime.timedelta(hours=-3))   # the city's clock: Brazil has no DST since 2019, so a fixed offset needs no tz database
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG = os.path.join(HERE, "bands.yaml")


# --- The YAML subset. PyYAML is not on the mini's /usr/bin/python3, so a strict reader: nested maps (2 spaces), scalars and inline lists
# --- of scalars. Everything else is REFUSED with its line, never half-read (the config is then inert and says so).
_KEY_LINE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):(?:[ ]+(.*))?$")
_INT = re.compile(r"^[+-]?\d+$")
_FLOAT = re.compile(r"^[+-]?\d+\.\d+$")


def _value_text(rest, ln):
    """`rest` without its trailing comment: a quoted value runs to its closing quote, a bare one to the first ' #'."""
    if rest[:1] in ("'", '"'):
        end = rest.find(rest[0], 1)
        if end < 0 or rest[end + 1:].strip()[:1] not in ("", "#"):
            raise ConfigError("linha %d: aspas não fechadas, ou texto depois delas" % ln)
        return rest[:end + 1]
    return re.split(r"(?:^|\s)#", rest, maxsplit=1)[0].strip()


def _scalar(tok, ln, in_list=False):
    tok = tok.strip()
    if not tok:
        raise ConfigError("linha %d: valor vazio" % ln)
    first = tok[0]
    if first in "\"'":
        if len(tok) < 2 or tok[-1] != first:
            raise ConfigError("linha %d: aspas não fechadas" % ln)
        inner = tok[1:-1]
        if first in inner or "\\" in inner:
            raise ConfigError("linha %d: aspas ou barra invertida dentro do texto (escape não suportado)" % ln)
        return inner
    if first == "[":
        if in_list or tok[-1] != "]":
            raise ConfigError("linha %d: lista aninhada ou não fechada" % ln)
        return [_scalar(p, ln, in_list=True) for p in tok[1:-1].split(",")] if tok[1:-1].strip() else []   # split on ',': a quoted item with a comma in it leaves unclosed quotes, which are refused
    if first in "{&*!|>%@`" or tok == "-" or tok.startswith("- "):
        raise ConfigError("linha %d: sintaxe YAML não suportada (%s)" % (ln, first))
    if tok in ("true", "false"):
        return tok == "true"
    if tok == "null":
        return None
    if _INT.match(tok):
        return int(tok)
    if _FLOAT.match(tok):
        return float(tok)
    if tok.endswith(":") or ": " in tok:
        raise ConfigError("linha %d: texto com ':' precisa de aspas" % ln)
    return tok


def parse_yaml_subset(text):
    """The mapping the text holds. Raises ConfigError (with the line) for anything outside the subset."""
    rows = []
    for ln, raw in enumerate(text.splitlines(), 1):
        body = raw.strip()
        if not body or body.startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if raw[indent:indent + 1] == "\t" or indent % 2:
            raise ConfigError("linha %d: indentação com tabulação ou ímpar (use 2 espaços por nível)" % ln)
        m = _KEY_LINE.match(body)
        if not m:
            raise ConfigError("linha %d: esperava 'chave: valor' (chave só com letras, números e _; lista em bloco não existe), achei '%s'" % (ln, body[:40]))
        rows.append((ln, indent, m.group(1), _value_text((m.group(2) or "").strip(), ln)))

    def block(i, indent):
        out = {}
        while i < len(rows):
            ln, ind, key, rest = rows[i]
            if ind < indent:
                break
            if ind > indent:
                raise ConfigError("linha %d: indentação inesperada" % ln)
            if key in out:
                raise ConfigError("linha %d: chave duplicada '%s'" % (ln, key))
            if rest == "":
                if i + 1 >= len(rows) or rows[i + 1][1] != indent + 2:
                    raise ConfigError("linha %d: '%s:' sem valor e sem filhos 2 espaços adiante" % (ln, key))
                out[key], i = block(i + 1, indent + 2)
            else:
                out[key] = _scalar(rest, ln)
                i += 1
        return out, i

    tree, end = block(0, 0)
    if end != len(rows):
        raise ConfigError("linha %d: indentação inesperada" % rows[end][0])
    return tree


# --- The config: what each key may hold. A key that is not here is an ERROR (a typo must not turn a band off in silence).
MODES = ("live", "shadow")
DRIVERS = ("meter", "tick")
COLLECTORS = ("", "disk_free_delta")
BAND_ACTIONS = {"band1": ("log",), "band2": ("log", "diagnose", "mail"), "band3": ("log", "diagnose", "mail", "bead")}
NAME = re.compile(r"^[a-z][a-z0-9_]*$")
BUILTIN_METRIC = {   # a metric starts in SHADOW: it counts what it would send and sends nothing, until a person says live
    "description": "", "mode": "shadow", "driver": "meter", "direction": "low", "transform": "none", "unit": "",
    "baseline_days": 14, "min_baseline_points": 20, "test_points": 8, "min_sigma": 0.0,
    "fresh_for_h": 4.0, "recover_after_h": 6.0, "evaluate_in_silence": False,
    "actions": {"band1": ["log"], "band2": ["diagnose", "mail"], "band3": ["diagnose", "mail", "bead"]},
    "collector": "", "path": "",
}
# key -> (kind, range or choices); the knobs the statistics read are the core's own (KNOBS), so the two cannot drift apart
METRIC_SCHEMA = dict(KNOBS, description=("str", None), mode=("enum", MODES), driver=("enum", DRIVERS), unit=("str", None),
                     fresh_for_h=("num", (0.1, 168)), recover_after_h=("num", (0, 168)), evaluate_in_silence=("bool", None),
                     collector=("enum", COLLECTORS), path=("str", None))


def _typed(value, kind, rng, where):
    """The value if it is of the kind and in range, else ConfigError naming where."""
    if kind == "bool" and isinstance(value, bool):
        return value
    if kind == "str" and isinstance(value, str):
        return value
    if kind in ("int", "num") and isinstance(value, (int, float)) and not isinstance(value, bool) and (kind == "num" or isinstance(value, int)):
        if rng[0] <= value <= rng[1]:
            return float(value) if kind == "num" else value
        raise ConfigError("%s: %s fora de %s..%s" % (where, value, rng[0], rng[1]))
    if kind == "enum":
        if value in rng:
            return value
        raise ConfigError("%s: '%s' não é um de %s" % (where, value, "/".join(rng)))
    raise ConfigError("%s: esperava %s, achei %r" % (where, kind, value))


def _checked_block(raw, schema, where):
    """Every key of `raw` is in `schema` and of the right kind; returns {key: normalized value}."""
    if not isinstance(raw, dict):
        raise ConfigError("%s: esperava um bloco de chaves" % where)
    out = {}
    for key, value in raw.items():
        if key not in schema:
            raise ConfigError("%s: chave desconhecida '%s' (typo? chaves válidas: %s)" % (where, key, ", ".join(sorted(schema))))
        out[key] = _typed(value, schema[key][0], schema[key][1], "%s.%s" % (where, key))
    return out


def _checked_actions(raw, where):
    if not isinstance(raw, dict):
        raise ConfigError("%s: esperava band1/band2/band3" % where)
    out = {}
    for band, acts in raw.items():
        if band not in BAND_ACTIONS:
            raise ConfigError("%s: '%s' não é band1, band2 ou band3" % (where, band))
        if not isinstance(acts, list) or not all(isinstance(a, str) for a in acts):
            raise ConfigError("%s.%s: esperava uma lista como [diagnose, mail]" % (where, band))
        for a in acts:
            if a not in BAND_ACTIONS[band]:
                raise ConfigError("%s.%s: '%s' não vale nessa faixa (vale: %s)" % (where, band, a, ", ".join(BAND_ACTIONS[band])))
        if len(set(acts)) != len(acts):
            raise ConfigError("%s.%s: ação repetida" % (where, band))
        out[band] = list(acts)
    return out


def _parse_silence(raw):
    if raw == "off":
        return None
    m = re.match(r"^(\d{1,2})-(\d{1,2})$", raw) if isinstance(raw, str) else None
    if not m or not (0 <= int(m.group(1)) <= 23 and 0 <= int(m.group(2)) <= 23) or m.group(1) == m.group(2):
        raise ConfigError("silence: esperava \"HH-HH\" (ex.: \"22-07\", horas diferentes) ou \"off\", achei %r" % (raw,))
    return int(m.group(1)), int(m.group(2))


def _merged_metric(raw, where):
    """The metric: built-in <- the metric's own, key by key (`actions` band by band)."""
    out = {k: (copy.deepcopy(v) if isinstance(v, (dict, list)) else v) for k, v in BUILTIN_METRIC.items()}
    block = dict(raw) if isinstance(raw, dict) else raw
    acts = block.pop("actions", None) if isinstance(block, dict) else None
    out.update(_checked_block(block, METRIC_SCHEMA, where))
    if acts is not None:
        out["actions"].update(_checked_actions(acts, where + ".actions"))
    if out["mode"] == "live":   # the delivery of the bands is slice 2b: a "live" that delivers nothing would read as "all quiet"
        raise ConfigError("%s.mode: 'live' ainda não existe (a entrega das faixas chega na fatia 2b, ga-wagjc6w); use shadow" % where)
    if (out["driver"] == "tick") != bool(out["collector"]):
        raise ConfigError("%s: driver tick e collector andam juntos (quem mede sozinho precisa dizer COMO; quem é medido por um vigia não tem collector)" % where)
    if out["collector"] == "disk_free_delta" and not out["path"]:
        raise ConfigError("%s: o collector disk_free_delta pede o path do volume que ele mede" % where)
    return out


def parse_config_text(text):
    """The validated config for `text`: defaults merged into every metric. Raises ConfigError."""
    tree = parse_yaml_subset(text)
    for key in tree:
        if key not in ("version", "silence", "metrics"):
            raise ConfigError("chave de topo desconhecida '%s' (válidas: version, silence, metrics)" % key)
    if tree.get("version") != 1:
        raise ConfigError("version: esperava 1, achei %r" % (tree.get("version"),))
    metrics = tree.get("metrics")
    if not isinstance(metrics, dict) or not metrics:
        raise ConfigError("metrics: faltam as métricas (um bloco com pelo menos uma)")
    out = {"version": 1, "silence": _parse_silence(tree["silence"]) if "silence" in tree else (22, 7), "metrics": {}}
    for name, raw in metrics.items():
        if not NAME.match(name):
            raise ConfigError("metrics.%s: nome só com minúsculas, números e _" % name)
        out["metrics"][name] = _merged_metric(raw, "metrics.%s" % name)
    return out


def load_config(path=None):
    """The validated config in `path` (default: bands.yaml beside this file). Raises ConfigError, 'ilegível' when it cannot be read."""
    # vazio → ConfigError from parse_config_text (a file with no version/metrics is refused, never "no metrics, all quiet");
    # falhou/ilegível (absent, directory, not UTF-8) → ConfigError "ilegível", never an empty config
    try:
        with open(path or DEFAULT_CONFIG, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError) as e:
        raise ConfigError("bands.yaml ilegível (%s): %s" % (path or DEFAULT_CONFIG, e.__class__.__name__))
    return parse_config_text(text)


# --- The episode state machine. Pure: (state, decision, now) -> (new state, events for the ledger, bands still OWED). A band is owed until
# --- its delivery is stamped (mark_done): a failed delivery is retried by the next run, a delivered one never repeats.
STATE_VERSION = 1
HISTORY_KEEP = 20


def new_state():
    return {"v": STATE_VERSION, "episode": None, "excluded": [], "dismissals": [], "history": [], "accepted_until": None}


def _episode_id(name, now, taken):
    base = "%s-%s" % (name, datetime.datetime.fromtimestamp(now, BRT).strftime("%Y%m%d-%H%M"))
    eid, k = base, 2
    while eid in taken:
        eid = "%s-%d" % (base, k)
        k += 1
    return eid


def mark_done(state, band, now, how):
    """The state with `band` of the open episode stamped as done (how: delivered / log / superseded). A new object."""
    st = copy.deepcopy(state)
    if st["episode"] is not None:
        st["episode"]["done"][str(band)] = {"at": now, "how": how}
    return st


def _settle(st, m, now):
    """Stamps the bands that owe nothing (log only) or are superseded by a worse one, and returns the band still owed ([] or [b])."""
    ep = st["episode"]
    if ep is None:
        return []
    owed = []
    for b in range(1, ep["band_max"] + 1):
        if str(b) in ep["done"]:
            continue
        if any(a != "log" for a in m["actions"]["band%d" % b]):
            owed.append(b)
        else:
            ep["done"][str(b)] = {"at": now, "how": "log"}
    for b in owed[:-1]:
        ep["done"][str(b)] = {"at": now, "how": "superseded"}
    return owed[-1:]


def step(state, dec, now, m, name):
    """One evaluation of the episode machine. Never mutates `state`. Returns (state, events, owed_bands)."""
    st = copy.deepcopy(state)
    events = []
    ep, band = st["episode"], dec["band"]
    if band > 0:
        if ep is None:
            taken = {h["id"] for h in st["history"]} | {r[2] for r in st["excluded"]}
            ep = st["episode"] = {"id": _episode_id(name, now, taken), "opened": now, "band_max": band, "rules": list(dec["rules"]),
                                  "ok_since": None, "done": {}, "mailed": {}, "diagnosis": None, "bead": None, "bead_why": None, "attempts": {}, "suppressed": 0}
            st["excluded"].append([dec["window_start"], None, ep["id"]])
            events.append({"ev": "open", "episode": ep["id"], "band": band, "rules": list(dec["rules"])})
        else:
            ep["ok_since"] = None
            if band > ep["band_max"]:
                ep["band_max"] = band
                ep["rules"] = sorted(set(ep["rules"]) | set(dec["rules"]))
                events.append({"ev": "escalate", "episode": ep["id"], "band": band, "rules": list(dec["rules"])})
            else:
                ep["suppressed"] += 1   # a repeat that raised nothing: counted, never delivered
    elif ep is not None:
        if ep["ok_since"] is None:
            ep["ok_since"] = now
        if now - ep["ok_since"] >= m["recover_after_h"] * 3600.0:
            for r in st["excluded"]:
                if r[2] == ep["id"] and r[1] is None:
                    r[1] = ep["ok_since"]
            st["history"].append({"id": ep["id"], "opened": ep["opened"], "closed": now, "band_max": ep["band_max"], "rules": ep["rules"],
                                  "bead": ep["bead"], "dismissed": False})
            st["history"] = st["history"][-HISTORY_KEEP:]
            st["episode"] = None
            events.append({"ev": "recover", "episode": ep["id"], "band_max": ep["band_max"]})
    horizon = now - m["baseline_days"] * 86400.0
    st["excluded"] = [r for r in st["excluded"] if r[1] is None or r[1] >= horizon]
    return st, events, _settle(st, m, now)


# --- Silence, state and ledger on disk. Every read says which of the three it is: has / has not (a first run) / could not tell.
def in_silence(now, window):
    """True when `now` falls inside the local (BRT) silence window (start_hour, end_hour); window None = never silent."""
    if window is None:
        return False
    start, end = window
    hour = datetime.datetime.fromtimestamp(now, BRT).hour
    return (hour >= start or hour < end) if start > end else (start <= hour < end)


def state_dir(city):
    return os.path.join(city, ".gc", "state", "bands")


def state_path(city, name):
    return os.path.join(state_dir(city), name + ".json")


def ledger_path(city):
    return os.path.join(state_dir(city), "ledger.jsonl")


def _valid_state(d):
    if not isinstance(d, dict) or d.get("v") != STATE_VERSION:
        return False
    if not all(isinstance(d.get(k), list) for k in ("excluded", "dismissals", "history")):
        return False
    if not all(isinstance(r, list) and len(r) == 3 for r in d["excluded"]):
        return False
    ep = d.get("episode")
    return ep is None or (isinstance(ep, dict) and all(k in ep for k in ("id", "opened", "band_max", "rules", "ok_since", "done", "diagnosis", "bead", "attempts", "suppressed")))


def read_state(path):
    """(state, status): ok | absent (a first run: a fresh state) | corrupt (a fresh state; the caller keeps the evidence) | unreadable (None)."""
    # vazio → (new_state(), "absent") ONLY for a file that does not exist; falhou/ilegível → "corrupt" for JSON that is not a state of ours,
    # "unreadable" (state None, and the caller decides NOTHING) for a read error: a state that could not be read is never an empty one
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except FileNotFoundError:
        return new_state(), "absent"
    except ValueError:   # JSONDecodeError and UnicodeDecodeError
        return new_state(), "corrupt"
    except OSError:
        return None, "unreadable"
    return (d, "ok") if _valid_state(d) else (new_state(), "corrupt")


def write_state(path, st):
    """True when the state is on disk (atomic: temp file + rename). False, with nothing changed, otherwise."""
    tmp = path + ".tmp.%d" % os.getpid()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(st, fh, sort_keys=True)
        os.replace(tmp, path)
        return True
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def ledger_append(city, rec):
    """True when the line is in the ledger. The ledger is the audit trail and the source of the counts, never a condition for acting on an alarm."""
    try:
        os.makedirs(state_dir(city), exist_ok=True)
        line = (json.dumps(rec, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
        fd = os.open(ledger_path(city), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, line)
        finally:
            os.close(fd)
        return True
    except OSError:
        return False


# --- One evaluation of one metric: read the state, judge the series, step the episode, record, and (shadow) count what is owed.
def fmt_num(x):
    return ("%.1f" % x).replace(".", ",")


def fmt_value(x):
    """A point's value: a whole number prints whole (a count of 0 is '0'), anything else keeps one decimal."""
    return "%d" % x if float(x).is_integer() else fmt_num(x)


def _when(ts):
    return datetime.datetime.fromtimestamp(ts, BRT).strftime("%d/%m %H:%M")


def _log_line(decision, base, owed, m):
    last = decision["last"]
    unit = (" " + m["unit"]) if m["unit"] else ""
    core = "último %s%s (z %s), típico %s%s" % (fmt_value(last["value"]), unit, fmt_num(last["z"]), fmt_num(base["raw_mean"]), unit)
    if decision["band"] == 0:
        return "FAIXA ok: %s" % core
    note = "entrega devida: faixa %d" % owed[0] if owed else "nada novo a entregar (um aviso por faixa)"
    return "FAIXA %dσ [%s]: %s | %s" % (decision["band"], "+".join(decision["rules"]), core, note)


def _take_lock(city, name):
    """(fd, None) with the per-metric lock held; (None, "busy") when another run holds it; (None, why) when it cannot be taken."""
    # falhou → only BlockingIOError (EWOULDBLOCK) means "someone else holds it"; any other error is "could not tell" and never reads as busy
    fd = None
    try:
        os.makedirs(state_dir(city), exist_ok=True)
        fd = os.open(os.path.join(state_dir(city), name + ".lock"), os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd, None
    except BlockingIOError:
        os.close(fd)
        return None, "busy"
    except OSError as e:
        if fd is not None:
            os.close(fd)
        return None, "lock das faixas não abre ou não toma (%s)" % e.__class__.__name__


def _new_result():
    return {"status": None, "rc": 0, "decision": None, "baseline": None, "owed": [], "lines": [], "why": "", "state": None}


def process(city, name, cfg, points, now, dry=False):
    """Judges `points` for metric `name`, steps its episode and, in shadow, counts what is owed. Returns a dict:
    status (silent | busy | no-data | stale | learning | bad-series | unreadable | unstorable | ok), rc (1 = a problem the caller must not
    paper over), decision, baseline, owed, lines (for the caller's log), why, state. One run at a time per metric (a lock), so a
    read-modify-write of the state never interleaves with another."""
    m = cfg["metrics"][name]
    silent = in_silence(now, cfg["silence"])
    res = _new_result()
    if silent and not m["evaluate_in_silence"]:
        res.update(status="silent")
        res["lines"].append("SILÊNCIO %02d-%02d h: faixa de %s não avaliada (nada interrompe agora; o 1º ponto novo depois do silêncio é julgado)" % (cfg["silence"] + (name,)))
        return res
    lock = None
    if not dry:
        lock, why = _take_lock(city, name)
        if lock is None:
            if why == "busy":
                res.update(status="busy", why=why)
                res["lines"].append("FAIXA ocupada: outra rodada de %s está em andamento — esta rodada não faz nada" % name)
            else:
                res.update(status="unstorable", rc=1, why=why)
                res["lines"].append("WARN: %s — nenhuma ação (não saberia lembrar que agiu)" % why)
            return res
    try:
        return _process_locked(city, name, m, silent, points, now, dry, res)
    finally:
        if lock is not None:
            os.close(lock)


def _process_locked(city, name, m, silent, points, now, dry, res):
    def finish(status, rc=0, why="", line=None):
        res.update(status=status, rc=rc, why=why)
        if line:
            res["lines"].append(line)
        return res

    path = state_path(city, name)
    state, sstat = read_state(path)
    if sstat == "unreadable":
        return finish("unreadable", 1, line="WARN: estado das faixas ilegível (%s) — nenhuma decisão e nenhuma ação" % path)
    if sstat == "corrupt":
        kept = "sem guardar o arquivo (modo ensaio)"
        if not dry:   # the evidence is kept beside it, never overwritten by the fresh state
            kept = "o arquivo estragado ficou em %s.corrupt-%d" % (os.path.basename(path), int(now))
            try:
                os.replace(path, "%s.corrupt-%d" % (path, int(now)))
            except OSError:
                kept = "não consegui guardar o arquivo estragado"
        res["lines"].append("WARN: estado das faixas corrompido (%s) — %s; recomecei do zero" % (path, kept))
    if not points:
        return finish("no-data", line="FAIXA sem série: nenhum ponto para julgar %s" % name)
    if now - points[-1][0] > m["fresh_for_h"] * 3600.0:
        return finish("stale", line="FAIXA sem ponto novo: o último de %s termina em %s (mais de %sh)" % (name, _when(points[-1][0]), fmt_num(m["fresh_for_h"])))
    try:
        v = judge(points, now, m, state["excluded"], 0.0, state.get("accepted_until"))   # no dismissal exists yet (2b): nothing widens σ or is accepted
    except ConfigError as e:   # the config was validated at load, so this is what the STATE holds (a range or a date that cannot be used)
        return finish("unreadable", 1, why=str(e), line="WARN: estado das faixas de %s inutilizável (%s) — nenhuma decisão" % (name, e))
    if v["status"] == "learning":
        return finish("learning", why=v["why"], line="FAIXA aprendendo: %s" % v["why"])
    if v["status"] == "bad-series":
        return finish("bad-series", 1, why=v["why"], line="WARN: série de %s corrompida (%s) — nenhuma decisão" % (name, v["why"]))
    decision, base = v["decision"], v["baseline"]
    st2, events, owed = step(state, decision, now, m, name)
    res.update(decision=decision, baseline=base, owed=list(owed), state=st2)
    res["lines"].append(_log_line(decision, base, owed, m))
    if dry:
        return finish("ok")
    if st2 != state and not write_state(path, st2):
        res.update(state=state, owed=[])
        return finish("unstorable", 1, line="WARN: estado das faixas não gravável (%s) — nenhuma ação (não saberia lembrar que agiu)" % path)
    for ev in events:
        if not ledger_append(city, dict(ev, ts=now, metric=name, shadow=m["mode"] == "shadow")):
            res["lines"].append("WARN: ledger das faixas não gravável (%s) — a contagem do evento '%s' se perde" % (ledger_path(city), ev["ev"]))
    if owed and not silent:   # a metric is always shadow here (the config refuses live): count what a live run would have sent, send nothing
        _shadow_stamp(city, name, m, st2, owed, now, res)
    return finish("ok")


def _shadow_stamp(city, name, m, st, owed, now, res):
    """Shadow mode: what a live run WOULD have done is counted once and stamped, so the counts mean what a live run would have sent."""
    for band in owed:
        st = mark_done(st, band, now, "shadow")
        if not write_state(state_path(city, name), st):
            res["lines"].append("WARN: estado não gravou o carimbo da sombra — a faixa pode ser contada de novo")
        rec = {"ts": now, "metric": name, "ev": "would_deliver", "episode": st["episode"]["id"], "band": band, "shadow": True,
               "actions": [a for a in m["actions"]["band%d" % band] if a != "log"]}
        if not ledger_append(city, rec):
            res["lines"].append("WARN: ledger das faixas não gravável — a entrega da sombra não foi contada")
    res["state"] = st
    res["owed"] = []


# --- The metrics that measure themselves (driver tick): a collector samples, `tick` judges. Today one: the free space of the volume that
# --- holds the Dolt data and the swap, judged by its change per hour, in SHADOW (the fixed floors that act stay as they are).
SAMPLE_MAX_AGE_S = 900.0   # a reading stands for the whole-hour boundary after it only if it is at most this old


def series_path(city, name):
    return os.path.join(state_dir(city), "series", name + ".jsonl")


def disk_free_mib(path):
    """Free MiB of the volume `path` lives on. Raises OSError when it cannot be read: there is NO fallback to another volume (on macOS
    `/` is the sealed system volume and tells another story, 71% when the data volume was at 98%)."""
    return shutil.disk_usage(path).free / 1048576.0


def _usable(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


def _read_samples(city, name):
    """([(ts, value)] oldest first, None), or (None, why). A torn line is left out, never read as a zero."""
    # vazio → ([], None) for a series never written; falhou/ilegível → (None, why): the metric is then "não medido", never "no change"
    try:
        with open(series_path(city, name), encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        return [], None
    except OSError as e:
        return None, "série de %s ilegível (%s)" % (name, e.__class__.__name__)
    out = []
    for line in lines:
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if isinstance(d, dict) and _usable(d.get("ts")) and _usable(d.get("v")):
            out.append((float(d["ts"]), float(d["v"])))
    out.sort()
    return out, None


def disk_points(city, name, m, now):
    """([(hour_end, change_in_MiB)], None) or (None, why): for each whole hour of the last baseline_days+2, the free space at its end minus
    the free space an hour before, each from the last reading at or before that instant AND at most SAMPLE_MAX_AGE_S old. An hour
    with no such reading, and the hour after it, give NO point: a missing reading is not a change of zero."""
    samples, why = _read_samples(city, name)
    if samples is None:
        return None, why
    times = [t for t, _ in samples]

    def at(h):
        i = bisect.bisect_right(times, h) - 1
        return samples[i][1] if i >= 0 and h - times[i] <= SAMPLE_MAX_AGE_S else None
    last = now - now % 3600.0
    out, h = [], last - (m["baseline_days"] + 2) * 86400.0
    while h <= last:
        cur, prev = at(h), at(h - 3600.0)
        if cur is not None and prev is not None:
            out.append((h, cur - prev))
        h += 3600.0
    return out, None


def _take_sample(city, name, m, now, free_fn):
    """(True, None) when this run's reading is in the series, else (False, why). Old readings are forgotten (baseline_days+3 are kept)."""
    try:
        value = free_fn(m["path"])
    except OSError as e:
        return False, "leitura do espaço livre de %s falhou (%s)" % (m["path"], e)
    if not _usable(value) or value < 0:
        return False, "a leitura do espaço livre de %s não é um número utilizável (%r)" % (m["path"], value)
    path = series_path(city, name)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": now, "v": float(value)}) + "\n")
    except OSError as e:
        return False, "a série de %s não grava (%s)" % (name, e.__class__.__name__)
    samples, _why = _read_samples(city, name)
    horizon = now - (m["baseline_days"] + 3) * 86400.0
    if samples and samples[0][0] < horizon:
        tmp = path + ".tmp.%d" % os.getpid()
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.writelines(json.dumps({"ts": t, "v": v}) + "\n" for t, v in samples if t >= horizon)
            os.replace(tmp, path)
        except OSError:
            pass   # the old readings stay one more run: harmless, and the next run tries again
    return True, None




def tick(city, cfg, now, free_fn=None, dry=False, only=None):
    """One round for every metric that measures itself: sample (not in dry mode), build the points, judge. {name: result}."""
    free_fn = free_fn or disk_free_mib
    out = {}
    for name, m in sorted(cfg["metrics"].items()):
        if m["driver"] != "tick" or (only and name != only):
            continue
        lines, rc, sampled = [], 0, False
        if not dry:
            sampled, why = _take_sample(city, name, m, now, free_fn)
            if why:
                lines.append("WARN: %s" % why)
                rc = 1
        points, why = disk_points(city, name, m, now)
        if points is None:
            res = dict(_new_result(), status="unreadable", rc=1, why=why)
            lines.append("WARN: %s — nenhuma decisão" % why)
        else:
            res = process(city, name, cfg, points, now, dry=dry)
        res["lines"] = lines + res["lines"]
        res["rc"] = max(rc, res["rc"])
        res["sampled"] = sampled
        out[name] = res
    return out


# --- The command line. Exit: 0 done · 2 NÃO SEI (a config that is invalid or unreadable: never "all quiet") · 64 usage · 70 a bug of
# --- this script (the traceback goes to stderr).
class UsageError(Exception):
    pass


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def _default_city():
    return os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or "/Users/athos/gt/.gascity-gastown-hq"


def _build_parser():
    ap = _Parser(prog="bands.py", description="faixas estatísticas dos vigias (ga-4mzkfj9): check · tick")
    sub = ap.add_subparsers(dest="cmd", required=True, parser_class=_Parser)
    for cmd, helptext in (("check", "valida o bands.yaml"), ("tick", "mede e julga as métricas que se medem sozinhas (driver tick): uma rodada")):
        p = sub.add_parser(cmd, help=helptext)
        p.add_argument("--config", default=DEFAULT_CONFIG, help="bands.yaml (default: o que mora ao lado do script)")
        p.add_argument("--city", default=_default_city())
        p.add_argument("--now", type=float, default=None, help="epoch (testes)")
        if cmd == "tick":
            p.add_argument("--metric", default=None, help="só esta métrica (default: todas as de driver tick)")
            p.add_argument("--dry-run", action="store_true", help="julga o que já foi medido; não mede, não grava")
    return ap


def main(argv=None):
    try:
        args = _build_parser().parse_args(argv)
    except UsageError as e:
        print("uso: %s" % e, file=sys.stderr)
        return 64
    except SystemExit as e:   # --help
        return e.code if isinstance(e.code, int) else 0
    try:
        try:
            cfg = load_config(args.config)
        except ConfigError as e:   # INERT: nothing is measured, judged or delivered from a file nobody can vouch for, and this line says so
            print("bands.yaml inválido — as faixas ficam inertes: %s" % e)
            return 2
        now = args.now or time.time()
        if args.cmd == "check":
            print("bands.yaml ok: %s" % ", ".join("%s (modo %s)" % (n, m["mode"]) for n, m in sorted(cfg["metrics"].items())))
            return 0
        results = tick(args.city, cfg, now, dry=args.dry_run, only=args.metric)
        for name, res in sorted(results.items()):
            for line in res["lines"]:
                print("%s: %s" % (name, line))
        return max([r["rc"] for r in results.values()] or [0])
    except Exception:   # a bug of this script: the traceback is the evidence
        traceback.print_exc()
        return 70


if __name__ == "__main__":
    sys.exit(main())
