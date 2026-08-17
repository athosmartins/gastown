#!/usr/bin/env python3
"""quiet_hours.py — Python mirror of packs/town-deltas/assets/quiet-hours-check.sh
(ga-lda92s).

The bash helper is sourced by the 4 launchd dispatchers (pilot, quality-gate,
auto-refino, refino-gate); Python watchdogs can't source a bash file, so this
module re-implements the SAME read semantics (same env var names/defaults,
same 2-line level-file format, same staleness/override rules) so both sides
of the city agree on one definition of "quiet" instead of drifting.

WHY THIS EXISTS (ga-lda92s): the quiet-hours feature (ga-dxyvxr) pauses new-
work admission 00h-08h local. Stall watchdogs that don't know about it read
"0 dispatches, 0 merges" during that window and cry wolf — 7 false alarms on
the feature's first night. Blindly silencing a watchdog for the whole window
would trade that false-positive for a false-negative (a real stall starting
00h30 would go unseen for 7h30) — the actual fix is to discount ONLY the
quiet portion of an elapsed/lookback calculation, never the whole verdict.
See quiet-hours-check.sh's own header for the full write-side rationale.
"""
import os
import time

QUIET_HOURS_LEVEL_FILE = os.environ.get(
    "QUIET_HOURS_LEVEL_FILE",
    os.path.join(os.path.expanduser("~"), ".gastown", "run", "city-quiet-hours.level"))
# city-night-window.sh runs every 10min; 1800s (30min = 3 missed cycles) gives
# real slack for a single missed/delayed run without the signal going stale
# under normal jitter, while still catching a genuinely dead writer well
# inside one quiet-hours window.
QUIET_HOURS_MAX_AGE_SECS = int(os.environ.get("QUIET_HOURS_MAX_AGE_SECS", "1800"))
# Mirrors city-night-window.sh's own NIGHT_START_HOUR/NIGHT_END_HOUR defaults
# (00h-08h local, end exclusive).
NIGHT_START_HOUR = int(os.environ.get("NIGHT_START_HOUR", "0"))
NIGHT_END_HOUR = int(os.environ.get("NIGHT_END_HOUR", "8"))


def _read_level_file():
    """(state, ts) from the 2-line level file, or (None, None) if missing/
    corrupt. Re-reads the env var each call (test seams reassign it)."""
    path = os.environ.get("QUIET_HOURS_LEVEL_FILE", QUIET_HOURS_LEVEL_FILE)
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError:
        return None, None
    state = lines[0].strip() if len(lines) >= 1 else ""
    ts_str = lines[1].strip() if len(lines) >= 2 else ""
    try:
        ts = int(ts_str)
    except ValueError:
        return None, None
    return (state or None), ts


def blocks(now=None):
    """True iff the city is currently in a confirmed, fresh QUIET state —
    the admission-gate question. Covers OPEN, missing, stale, and corrupt —
    all fail open (False) the same way. QUIET_HOURS_OVERRIDE (test seam,
    mirrors the bash side) short-circuits: "QUIET" forces True, anything
    else forces False."""
    override = os.environ.get("QUIET_HOURS_OVERRIDE")
    if override:
        return override == "QUIET"
    state, ts = _read_level_file()
    if state is None:
        return False
    now = now if now is not None else time.time()
    max_age = int(os.environ.get("QUIET_HOURS_MAX_AGE_SECS", QUIET_HOURS_MAX_AGE_SECS))
    if now - ts > max_age:
        return False
    return state == "QUIET"


def unreadable(now=None):
    """True iff the signal is missing/stale/corrupt (the fail-open path —
    callers proceed either way), False iff a genuine QUIET/OPEN reading was
    read (confirmed, not assumed)."""
    if os.environ.get("QUIET_HOURS_OVERRIDE"):
        return False
    state, ts = _read_level_file()
    if state is None:
        return True
    now = now if now is not None else time.time()
    max_age = int(os.environ.get("QUIET_HOURS_MAX_AGE_SECS", QUIET_HOURS_MAX_AGE_SECS))
    return (now - ts) > max_age


def _local_midnight(ts):
    """Epoch of local 00:00:00 on the calendar day containing ts."""
    lt = time.localtime(ts)
    return time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))


def window_overlap_seconds(start_ts, end_ts):
    """PURE calendar math: total seconds of [start_ts, end_ts) that fall
    within local [NIGHT_START_HOUR:00, NIGHT_END_HOUR:00) on any day. No
    file I/O, no live state — deterministic and safe to unit-test directly
    with constructed timestamps. Does NOT know about a live override; see
    elapsed_adjustment() below for the safety wrapper that does."""
    if not start_ts or not end_ts or end_ts <= start_ts:
        return 0
    nsh = int(os.environ.get("NIGHT_START_HOUR", NIGHT_START_HOUR))
    neh = int(os.environ.get("NIGHT_END_HOUR", NIGHT_END_HOUR))

    total = 0
    day = _local_midnight(start_ts)
    iterations = 0
    # Bounded to 32 days (real callers span at most a few hours) — defensive,
    # never meant to trip, just a hard stop against a date-arithmetic bug
    # turning into an infinite loop.
    while day < end_ts and iterations < 32:
        win_start = day + nsh * 3600
        win_end = day + neh * 3600
        ov_start = max(start_ts, win_start)
        ov_end = min(end_ts, win_end)
        if ov_end > ov_start:
            total += ov_end - ov_start
        day += 86400
        iterations += 1
    return total


def elapsed_adjustment(start_ts, end_ts, now=None):
    """Seconds to SUBTRACT from a raw (end_ts - start_ts) elapsed duration to
    discount legitimate quiet-hours pause. Composes window_overlap_seconds
    above with a live-signal safety check: if end_ts's own calendar day says
    "still in tonight's window" but the LIVE signal disagrees (a human
    override is active, or the writer is stale/down), we cannot confirm
    TODAY's portion was actually enforced, so we don't discount it — only
    prior days (if the range spans more than one night) stay discounted.
    Errs toward NOT discounting — never toward silence."""
    raw = window_overlap_seconds(start_ts, end_ts)
    if raw <= 0:
        return 0

    nsh = int(os.environ.get("NIGHT_START_HOUR", NIGHT_START_HOUR))
    neh = int(os.environ.get("NIGHT_END_HOUR", NIGHT_END_HOUR))
    end_midnight = _local_midnight(end_ts)
    win_start = end_midnight + nsh * 3600
    win_end = end_midnight + neh * 3600

    if win_start <= end_ts < win_end and not blocks(now):
        if win_start > start_ts:
            return window_overlap_seconds(start_ts, win_start)
        return 0
    return raw
