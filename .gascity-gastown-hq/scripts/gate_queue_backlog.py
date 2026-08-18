#!/usr/bin/env python3
"""gate_queue_backlog.py — shared gate-review-queue backlog helpers.

WHY THIS EXISTS (ga-ahn3v, 2026-08-03): approved-state-reconciler.py's starving-bead
alarm (ga-dbfm9) and throughput-stall-watchdog.py's delivery-stall alarm (ga-u2u8z)
each independently hit the same false-positive class — an alarm firing purely because
a bead "hasn't moved", with no signal for *why*. All the false positives traced back to
the SAME resource: the gate REVIEW queue (quality-gate-dispatcher.sh's Step 0b backlog)
sitting 30-43 markers deep at ~5 verdicts/hour — a multi-hour backlog that fully
explains a bead's wait without any dispatch failure. ga-dbfm9 implemented
depth+throughput+suppress-when-justified for the starving alarm first, deliberately
NOT extracting a shared helper from a single example ("abstração tirada de UM exemplo
costuma sair errada" — an abstraction drawn from ONE example usually comes out wrong).
ga-u2u8z applied the identical mechanism to the delivery-stall alarm second, and
confirmed explicitly (on its own bead) that the two are the SAME mechanism, not a
coincidental resemblance. This module is the deferred extraction ga-dbfm9 promised.

Only the 4 functions below are identical between the two alarms — their CALLERS
differ and are NOT forced to match: approved-state-reconciler.py applies the aggregate
depth/throughput to a bead that has NOT yet been dispatched into the gate queue at all
(no marker exists yet); throughput-stall-watchdog.py applies the same aggregate to a
bead that already HAS its own queued marker — upgrading an unconditional "found marker
=> explained" (ga-g0v96) into a quantitative check. Neither computes an exact per-bead
queue POSITION: quality-gate-dispatcher.sh's Step 0b selection is a multi-tier
priority/aging sort (see quality-gate-dispatcher.sh's MARKER=... jq sort_by chain,
~line 4655), not a plain FIFO a position index could represent — both callers
deliberately use the coarser, honest aggregate-depth proxy instead of fabricating a
wrong-but-confident position.

root-class:error-vs-empty applies throughout (the most frequent gate-finding root cause
in this city): a query/parse failure must never collapse to the same value as a
confirmed-empty result. Every function below returns None to mean "could not measure",
distinct from a measured 0, and callers must never license a suppression on None.

Deliberately NOT shared with callers: the generic _sh/_parse_bd_json/_tail/_ts_epoch
plumbing below is a second (well, third) small copy of primitives each caller already
has its own version of for unrelated purposes — extracting THOSE too is out of scope
for ga-ahn3v (only the 4 gate-queue-domain functions were the confirmed duplication)
and would turn a lane:small dedup into a much larger, riskier shared-utils refactor.
"""
import json
import os
import re
import subprocess
import time

# ── paths / knobs ─────────────────────────────────────────────────────────────
CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
GATE_DISPATCHER_LOG = os.path.join(CITY, ".gc/logs/quality-gate-dispatcher.log")
BD_LIST_CACHED = os.path.join(CITY, "scripts/bd-list-cached.sh")  # ga-xwza2: read-cache shim
BD_TIMEOUT = int(os.environ.get("GATE_QUEUE_BD_TIMEOUT", "25"))
# GATE_QUEUE_LOG_TAIL (ga-dbfm9): quality-gate-dispatcher.log is far chattier than a
# typical daemon log (measured 2026-08-02: ~507 lines for a real trailing hour on a busy
# day) — sized with ~8x margin so _gate_queue_throughput()'s "did the tail reach back a
# full GATE_QUEUE_WINDOW_MIN" completeness check (see that function) very rarely trips
# during a genuine traffic burst, not just on the median day.
GATE_QUEUE_LOG_TAIL = int(os.environ.get("GATE_QUEUE_LOG_TAIL", "4000"))
GATE_QUEUE_WINDOW_MIN = int(os.environ.get("GATE_QUEUE_WINDOW_MIN", "60"))

_TS_RE = re.compile(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]")

# ── test seams (monkeypatched by callers' --selftest) ──────────────────────────
# Both consumer scripts monkeypatch these two module-level attributes directly
# (e.g. `gate_queue_backlog._bd_gate_queue_markers = lambda: [...]`) from their own
# hermetic selftests — see approved-state-reconciler.py's _selftest() for the pattern.
# `global` inside THIS module's functions is not needed for that: the callers assign
# the attribute on the imported module object, which is exactly what the lookups
# below resolve against.
_bd_gate_queue_markers = None  # () -> list[dict]|None; OPEN gate-status:queued markers (HQ store)
_read_gate_log_lines = None    # () -> list[str]; tail of quality-gate-dispatcher.log


def _log(msg):
    print("[gate_queue_backlog] %s" % msg, flush=True)


# ── local plumbing (deliberately NOT shared with callers — see module docstring) ──
def _sh(args, timeout=20):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def _parse_bd_json(raw, strict=False):
    """Parse bd --json output (array or {issues:[]} envelope). Returns [] on any failure.

    With strict=True, returns None instead of [] specifically when the payload could
    not be parsed as JSON at all (both the initial parse and the truncate-and-retry
    recovery failed) — callers that must not conflate "confirmed empty" with
    "unreadable" (root-class:error-vs-empty) should pass strict=True and treat a None
    return as unknown, not zero rows. strict=True does NOT change the empty-input or
    wrong-shape cases: empty/whitespace stdout and syntactically-valid-but-unexpected
    JSON (e.g. a bare number) both remain [] even in strict mode, since those ARE the
    command legitimately saying "nothing here" rather than a parse failure.
    """
    if not raw or not raw.strip():
        return []
    try:
        d = json.loads(raw)
    except json.JSONDecodeError as e:
        _log("WARN: _parse_bd_json: partial JSON at pos=%d — truncating; "
             "dropped rows stay unmeasured (safe) but investigate bd output" % e.pos)
        try:
            d = json.loads(raw[:e.pos])
        except Exception:
            return None if strict else []
    except Exception:
        return None if strict else []
    if isinstance(d, list):
        return d
    if isinstance(d, dict):
        return d.get("issues") or d.get("beads") or d.get("items") or []
    return []


def _ts_epoch(line):
    """Parse a [YYYY-MM-DD HH:MM:SS] timestamp from a log line; returns epoch or None."""
    m = _TS_RE.search(line)
    if not m:
        return None
    try:
        return time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
    except Exception:
        return None


def _tail(path, n):
    try:
        with open(path, errors="replace") as f:
            return f.readlines()[-n:]
    except Exception:
        return []


# ── gate-queue backlog (ga-dbfm9 / ga-u2u8z / ga-ahn3v) ────────────────────────
def _gate_queue_depth():
    """Count of OPEN quality-gate-marker rows currently gate-status:queued in the
    HQ store — the exact backlog quality-gate-dispatcher.sh's own "Step 0b: Find a
    queued marker" scan (packs/town-deltas/assets/quality-gate-dispatcher.sh,
    ~line 4269) works through before it reaches any given marker. Paired with
    _gate_queue_throughput() by _gate_queue_suppress_reason() — see that
    function's docstring for the false-positive history this addresses.

    Markers are ALWAYS in the HQ store regardless of which rig the source bead
    belongs to — query CITY, never a rig root.

    Returns None on query/parse error — same fail-toward-'cannot confirm
    suppression' convention as every other None-on-error helper here: an
    unreadable queue depth says nothing about whether a wait is justified, so it
    must not silently license a suppression (root-class:error-vs-empty).
    """
    if _bd_gate_queue_markers is not None:
        rows = _bd_gate_queue_markers()   # test seam
    else:
        # --include-infra (ga-vm20x, Mayor 07/08): markers are born
        # --ephemeral (INFRA), hidden from `bd list` by default under bd
        # 1.1.0. Without this flag a genuinely nonzero queue depth reads as
        # 0, which (per the docstring above) risks silently licensing a
        # suppression that isn't actually justified.
        # --limit 0 (ga-t02io, found during throughput-stall-watchdog.py's
        # migration onto this shared function): `bd list --json` silently
        # truncates at 50 rows with no signal in the JSON itself when the
        # flag is omitted. throughput-stall-watchdog.py's own pre-migration
        # copy of this query already carried --limit 0; this module's copy
        # did not, so approved-state-reconciler.py's ga-dbfm9 adoption has
        # been running with a latent undercount risk (docstring already
        # cites 30-43 markers as a real historical depth, below 50 today but
        # not guaranteed to stay there) since it shipped. An undercounted
        # depth understates the projected drain time, which makes
        # _gate_queue_suppress_reason() LESS eager to suppress — fails
        # toward a spurious alarm rather than a hidden one, but it is still
        # a wrong number, not the honest "≥50" this flag makes unnecessary.
        r = _sh(["bash", BD_LIST_CACHED, "-C", CITY, "list", "--json", "--limit", "0",
                 "--include-infra",
                 "-l", "type:quality-gate-marker", "-l", "gate-status:queued"],
                timeout=BD_TIMEOUT)
        if r is None or r.returncode != 0:
            return None
        rows = _parse_bd_json(r.stdout, strict=True)
    if rows is None:
        return None
    return len(rows)


def _gate_queue_throughput(now):
    """Verdicts/hour observed in quality-gate-dispatcher.log over the last
    GATE_QUEUE_WINDOW_MIN minutes, or None if unmeasurable.

    Paired with _gate_queue_depth() by _gate_queue_suppress_reason() to tell an
    expected gate-review-backlog pacing delay from a genuine dispatch failure —
    see that function's docstring for the false-positive history (ga-dbfm9).

    Returns None (unmeasurable — caller must NOT default to 0, root-class:
    error-vs-empty) when:
      - the log can't be read (_tail() swallows the error and returns [] —
        indistinguishable at that layer from "empty file", so treat any
        empty/unreadable tail as failure here, never as "0 runs happened")
      - the fetched tail (GATE_QUEUE_LOG_TAIL lines) doesn't itself reach back a
        full GATE_QUEUE_WINDOW_MIN minutes (checked via the oldest timestamp
        seen) — an UNDERcounted numerator would understate throughput, which
        makes _gate_queue_suppress_reason MORE eager to suppress (the wrong
        direction). Better to say "couldn't measure" than silently under-
        report — this also naturally covers log rotation/startup, where there
        genuinely isn't a full hour of history yet.
    """
    if _read_gate_log_lines is not None:
        lines = _read_gate_log_lines()   # test seam
    else:
        lines = _tail(GATE_DISPATCHER_LOG, GATE_QUEUE_LOG_TAIL)

    if not lines:
        return None

    cutoff = now - GATE_QUEUE_WINDOW_MIN * 60
    count = 0
    oldest_epoch = None
    for line in lines:
        epoch = _ts_epoch(line)
        if epoch is None:
            continue
        if oldest_epoch is None or epoch < oldest_epoch:
            oldest_epoch = epoch
        if epoch >= cutoff and "Gate run complete" in line and "verdict=" in line:
            count += 1

    if oldest_epoch is None or oldest_epoch > cutoff:
        return None  # tail didn't reach back a full window — can't confirm the count

    return count / (GATE_QUEUE_WINDOW_MIN / 60.0)


def _gate_queue_suppress_reason(gate_depth, gate_throughput, age_min):
    """Suppress reason if the gate-review backlog alone explains a starving/stalled
    bead's wait, else None (ga-dbfm9).

    ROOT CAUSE (3 false positives observed 2026-08-01: wa-skhsx, wa-n2anz,
    wa-4s4cc): an alarm fired purely on "not dispatched"/"not updated", with no
    signal for *why*. All three incidents shared one explanation the caller
    couldn't see: the gate REVIEW queue (a separate resource from the builder
    pool) was 30-43 markers deep at ~5 verdicts/hour — a multi-hour backlog. A
    bead waiting less than that projected backlog is waiting on system load, not
    a broken dispatch/delivery path.

    Pure function over already-measured (once per cycle) inputs — no I/O.

    Returns None (do NOT suppress — fall through to alarm) when:
      - either measurement is None (an unmeasured queue must never license a
        suppression — root-class:error-vs-empty)
      - gate_depth == 0 — a confirmed EMPTY queue never explains a wait (this
        check may only EXPLAIN a wait, never blanket-silence the alarm — a
        genuinely stalled/non-dispatched bead with an empty queue must still
        alarm)
      - gate_throughput <= 0 — measured, but zero verdicts in the window; the
        projected drain time is undefined/infinite. A stalled gate is a
        DIFFERENT problem (surfaced by other watchdogs) and must not become an
        unbounded free pass for an unrelated failure here
      - the projected drain time (gate_depth/gate_throughput, in minutes) does
        not exceed this bead's own age_min — the queue hasn't actually held it
        up that long

    A reason string (suppress) only when depth>0, throughput>0, and the
    projected drain time exceeds age_min — a positively-measured explanation,
    never a default.
    """
    if gate_depth is None or gate_throughput is None:
        return None
    if gate_depth == 0:
        return None
    if gate_throughput <= 0:
        return None
    projected_wait_min = (gate_depth / gate_throughput) * 60.0
    if projected_wait_min > age_min:
        return ("gate queue backlog explains wait (depth=%d queued, "
                 "throughput=%.1f verdict/h, projected=%.0fmin > age=%.0fmin)"
                 % (gate_depth, gate_throughput, projected_wait_min, age_min))
    return None


def _gate_queue_body_line(gate_depth, gate_throughput, age_min):
    """Format a gate-queue context line for an alarm's mail body — depth +
    throughput + this bead's standing relative to the projected drain time, or
    an explicit measurement-failure note. NEVER silent, NEVER fabricates a 0 for
    a value that could not be measured (see _gate_queue_depth()/
    _gate_queue_throughput()'s own docstrings).

    ga-u2u8z: the closing verdict text is derived from the ACTUAL projected-vs-
    age comparison, not hardcoded — a prior version of this function (found
    live, ga-u2u8z verification against production) hardcoded "does NOT
    explain the wait" on this branch, which was silently wrong whenever a
    caller invokes this for an explained/suppressed case too (approved-state-
    reconciler.py happens to only call it on the not-suppressed path, so it
    never observed this; throughput-stall-watchdog.py calls it for both
    explained and unexplained beads, which is what surfaced it)."""
    if gate_depth is None or gate_throughput is None:
        depth_txt = ("%d marker(s)" % gate_depth) if gate_depth is not None else "COULD NOT MEASURE"
        tp_txt = ("%.1f verdict(s)/h" % gate_throughput) if gate_throughput is not None else "COULD NOT MEASURE"
        return ("Gate queue: %s gate-status:queued | throughput (last %dmin): %s "
                 "| queue-based suppression NOT applied — measurement incomplete, "
                 "alarm kept (safe default)." % (depth_txt, GATE_QUEUE_WINDOW_MIN, tp_txt))
    if gate_depth == 0:
        return ("Gate queue: 0 marker(s) gate-status:queued (empty) | throughput "
                 "(last %dmin): %.1f verdict(s)/h | empty queue never explains a "
                 "wait." % (GATE_QUEUE_WINDOW_MIN, gate_throughput))
    if gate_throughput <= 0:
        return ("Gate queue: %d marker(s) gate-status:queued | throughput (last "
                 "%dmin): 0 verdict(s)/h (gate idle or stalled) | projected drain "
                 "undefined — queue-based suppression NOT applied." % (
                 gate_depth, GATE_QUEUE_WINDOW_MIN))
    projected_wait_min = (gate_depth / gate_throughput) * 60.0
    verdict_txt = ("queue explains the wait" if projected_wait_min > age_min
                   else "queue does NOT explain the wait")
    return ("Gate queue: %d marker(s) gate-status:queued | throughput (last "
             "%dmin): %.1f verdict(s)/h | projected drain: ~%.0fmin vs this "
             "bead's wait: %.0fmin — %s." % (
             gate_depth, GATE_QUEUE_WINDOW_MIN, gate_throughput,
             projected_wait_min, age_min, verdict_txt))
