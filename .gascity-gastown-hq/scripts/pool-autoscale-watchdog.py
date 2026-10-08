#!/usr/bin/env python3
"""Pool auto-scale watchdog.

Keeps the gastown.dog pool (and any other configured pools) scaled to match
unassigned routed-demand. The engine's own auto-scaler does not reliably wake
idle pool members when demand queues up; this watchdog compensates with
conservative pin-based waking.

Poll loop (~60s). Silence = healthy (only emits on actions).
  [POOL-AUTOSCALE] [SCALED-UP]       woke+pinned an idle member
  [POOL-AUTOSCALE] [SCALE-UP-FAILED] wake or pin command failed
  [POOL-AUTOSCALE] [SCALED-DOWN]     unpinned a watchdog-pinned member (demand gone)
  [POOL-AUTOSCALE] [STUCK]           demand queued but no capacity to wake
  [POOL-AUTOSCALE] [STARTUP]         initial state report
  [POOL-AUTOSCALE] [PROBE-DISAGREE]  watchdog counted claimable beads but the pool's own
                                     probe says the queue is empty (probe wins)
  [POOL-AUTOSCALE] [PROBE-UNAVAILABLE] the pool's own probe could not be asked, so the
                                     count stands uncross-checked
  [POOL-AUTOSCALE] [PROBE-WINDOW-FULL] the probe's 20-bead window holds nothing claimable;
                                     work behind it is invisible to it (and to this count)
  [POOL-AUTOSCALE] [CAP-FALLBACK]    `gc config show` gave no max_active_sessions for a pool;
                                     the last good number (else a hardcoded one) stands in
  [POOL-AUTOSCALE] [CAP-RECOVERED]   `gc config show` answers again after a CAP-FALLBACK
  [POOL-AUTOSCALE] [CAP-CHANGED]     the configured max_active_sessions changed
  [POOL-AUTOSCALE] [WORK-ORDER-LIB-BROKEN]    work-order.sh is missing, unreadable or answers
                                     in a way the engine's wo_pick would not trust, so the pool
                                     probe is on the PREVIOUS order (push; once per episode)
  [POOL-AUTOSCALE] [WORK-ORDER-LIB-RECOVERED] the lib answers again after a BROKEN
  [POOL-AUTOSCALE] [WORK-ORDER-LIB-UNCHECKED] the lib could not be checked (log only; says
                                     nothing about the lib, and does not end a BROKEN)

Demand (ga-uv4on5) is the beads a pool worker's own probe would hand out, not
every ready bead routed to the pool: held, vetoed, parked, epic and in-flight
beads are not demand, because a dog woken for them finds nothing and exits.
See "Demand predicate" below.

The ceiling (ga-d1q1kn) is re-read from `gc config show` before every cycle, and
a read that gives no number is never turned into one in silence. See
load_pool_max_active().

Safety invariants:
  - ONLY manages templates listed in MANAGED_POOLS.
  - ONLY unpins sessions this watchdog pinned (tracked in state file).
  - One wake+pin per cycle per pool (gentle ramp).
  - Fails safe on bad/missing/unparseable data (noop, never crash loop).
  - Does NOT modify Dolt.
  - Never pins beyond max_active_sessions.
  - Stuck states (reset-pending etc.) are skipped — not woken.
"""
import json
import os
import re
import subprocess
import time
import sys as _sys
_sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from gc_ledger import gc_ledger_append as _paw_ledger
import datetime as _paw_datetime

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MANAGED_POOLS = ["gastown.dog"]   # session template names, NOT config short names

POLL_SEC = 120
SCALE_UP_AFTER = 180    # demand must persist >= 3min before waking a member
SCALE_DOWN_AFTER = 300  # demand must be 0 for >= 5min before unpinning

STATE_FILE = ".gc/state/pool-autoscale-watchdog.json"
STUCK_REALERT_SEC = 900  # re-emit STUCK alert every 15min (avoid ntfy spam)

# Session states considered healthy/active
ACTIVE_STATES = {"active", "awake"}
# Session states considered cleanly asleep (available to wake)
ASLEEP_STATES = {"asleep", "idle"}


# ---------------------------------------------------------------------------
# Demand predicate: what counts as work a pool worker can claim (ga-uv4on5)
# ---------------------------------------------------------------------------
# A bead is pool DEMAND only if a pool worker's own Step-1c probe would hand it
# out. That probe is the agent's work_query, rendered by the engine (the
# bd-ready flags plus its poolDemandLabelFilterJQ filter; see ga-avvu2), so it
# cannot be imported here; the constants and probe_would_serve() below mirror
# it. Two guards keep the mirror honest:
#   - test_pool_autoscale_watchdog.py (`-k engine_probe`) renders the engine's
#     probe with `gc prime gastown.dog` and checks the vocabulary and the
#     predicate against it;
#   - get_pool_demand() puts a non-empty count to the pool's own probe
#     (`gc hook`) before it can wake anyone, and logs [PROBE-DISAGREE] when the
#     probe says the queue is empty, or [PROBE-UNAVAILABLE] when it cannot be
#     asked (the count then stands, uncross-checked).

# Exact labels the probe excludes. Passed to `bd ready` as --exclude-label, which
# bd applies BEFORE --limit, so held beads do not use up the candidate window.
PROBE_EXCLUDE_LABELS = (
    "story:needs-human", "needs-human", "ctx:thin", "story:needs-approval",
    "story:epic", "needs:engine-window", "pilot:no-auto-dispatch",
    "story:blocked", "delivery:partial", "scope:needs-review", "exec:manual",
    "needs-human-decision", "auto-refino:refining", "auto-refino:escalated",
    "refino:info-gap", "refino:policy-gap", "story:unrefined",
    "story:refinement-in-progress", "story:refino-review",
    "story:refino-escalado", "story:needs-device", "on-device", "phone-proxy",
    "gate:queued", "gate:reviewing",
)

# Labels the probe's jq stage drops when they START with one of these.
PROBE_EXCLUDE_LABEL_PREFIXES = (
    "pool:refused", "blocked:", "blocked-reason:", "gate:needs-human",
    "pilot:refused-reason:", "pilot:text-veto",
)

# Pilot holds. A bare `pilot:held` blocks until it is removed. A
# `pilot:held-until:<epoch>` blocks until that time passes; once every expiry
# has passed the bead is released even if a bare `pilot:held` is still on it.
PROBE_HELD_LABEL = "pilot:held"
PROBE_HELD_UNTIL_PREFIX = "pilot:held-until:"

# Epic beads are containers, not buildable work.
PROBE_EPIC_TITLE_RE = re.compile(r"^(EPIC|ÉPICO)[:\s]", re.IGNORECASE)

# The probe asks bd for the 20 oldest candidates; the watchdog looks at the same window.
PROBE_CANDIDATE_LIMIT = 20

# In the watchdog but NOT in the probe (ga-ms1jm / ga-lx7om): a source bead that
# is already slung or being built is not unmet demand. Counting it would spawn a
# surplus dog that re-claims the in-flight bead (double dispatch).
WATCHDOG_EXCLUDE_LABELS = ("story:in-flight", "pilot:dispatched")

# A hold expiry is epoch seconds; anything else is unreadable, and unreadable reads as held.
_HOLD_EXPIRY_RE = re.compile(r"\d+(?:\.\d+)?")

# `gc hook` also answers for the session identity in its environment (work assigned
# to the caller). A pool-wide question must not inherit one.
_SESSION_IDENTITY_ENV = ("GC_SESSION_ID", "GC_SESSION_NAME", "GC_ALIAS",
                         "GC_SESSION_ORIGIN", "GC_AGENT", "GC_TEMPLATE")

# (kind, pool) conditions already reported; see _report_once().
_reported = set()


# ---------------------------------------------------------------------------
# Notify helper (matches gate-health-monitor.py / crew-session-dedup.py)
# ---------------------------------------------------------------------------

def emit(msg):
    """Print alert line and fire notify CLI (best-effort, never crash)."""
    print(msg, flush=True)
    try:
        subprocess.run(
            ["/Users/athos/.local/bin/notify", "-t", "Pool autoscale", "-p", "4", msg],
            timeout=10, capture_output=True)
    except Exception:
        pass


def _gate_focus_active(now=None):
    """ga-kqa08j: True only when gate-focus-mode.sh recorded active=1 recently.

    In focus mode the dog cap is LOWERED on purpose (eval-window-concurrency-guard.sh)
    while routed demand stays high, so "demand > cap" is the intended state, not a
    stuck pool. Missing/corrupt/stale state -> False (alerts behave as before).
    """
    city = os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or "/Users/athos/gt/.gascity-gastown-hq"
    path = os.environ.get("GATE_FOCUS_STATE_FILE") or os.path.join(city, ".gc", "gate-focus.state")
    stale = int(os.environ.get("GATE_FOCUS_STALE_S", "7200") or 7200)
    try:
        fields = dict(line.strip().split("=", 1) for line in open(path) if "=" in line)
        at = int(fields.get("at", ""))
    except Exception:
        return False
    now = now if now is not None else time.time()
    return fields.get("active") == "1" and 0 <= now - at <= stale


# ---------------------------------------------------------------------------
# Config: pool max_active_sessions
# ---------------------------------------------------------------------------

# The ceiling a pool is held to until `gc config show` has answered for it once
# (ga-d1q1kn): a guess, and never a silent one. See load_pool_max_active().
FALLBACK_CAPS = {"gastown.dog": 3}

# The last number `gc config show` itself gave for each pool: what a failed read
# keeps acting on. Never holds a FALLBACK_CAPS value.
_last_good_caps = {}

# pool -> (cap, source) that load_pool_max_active() settled on last time, source
# being "config", "last-good" (a failed read kept the last good number) or
# "fallback" (the config has never answered). It lets a transition be reported
# once instead of on every read.
_cap_in_use = {}

_CAP_SOURCE_WORDS = {"last-good": "the last value it gave",
                     "fallback": "the hardcoded fallback"}


def _read_config_caps(pool_templates):
    """One read of `gc config show` -> (caps, reasons).

    `caps` has an entry only for a pool the config gave a number for; `reasons`
    says, for every other pool, why it did not. A command that fails or times out
    is a reason, not an exception; load_pool_max_active() guards the rest. Pool
    templates like "gastown.dog" map to config agent name "dog" (the last
    component).
    """
    try:
        result = subprocess.run(
            ["gc", "config", "show"],
            capture_output=True, text=True, timeout=20)
    except Exception as exc:
        why = f"gc config show failed: {type(exc).__name__}: {exc}"[:200]
        return {}, {pt: why for pt in pool_templates}
    if result.returncode != 0:
        # A failed command's stdout is not an answer, even when it parses.
        error_lines = [l.strip() for l in (result.stderr or "").splitlines()
                       if l.strip() and not l.startswith("warning:")]
        why = (f"gc config show exit {result.returncode}, "
               + (error_lines[-1][:160] if error_lines else "no error text"))
        return {}, {pt: why for pt in pool_templates}

    text = result.stdout or ""
    caps, agents_seen, blocks = {}, set(), 0
    # Split on [[agent]] blocks to avoid cross-block contamination.
    # gc config show emits [[agent]] sections for each resolved agent.
    agent_block_re = re.compile(r'\[\[agent\]\](.*?)(?=\[\[agent\]\]|\Z)', re.DOTALL)
    for block in agent_block_re.findall(text):
        blocks += 1
        name_m = re.search(r'^name\s*=\s*"([^"]+)"', block, re.MULTILINE)
        cap_m = re.search(r'^max_active_sessions\s*=\s*(\d+)', block, re.MULTILINE)
        if not name_m:
            continue
        short_name = name_m.group(1)
        agents_seen.add(short_name)
        if not cap_m:
            continue
        cap = int(cap_m.group(1))
        for pt in pool_templates:
            # Match "gastown.dog" -> "dog" (last component)
            if pt.split(".")[-1] == short_name:
                caps[pt] = cap

    reasons = {}
    for pt in pool_templates:
        if pt in caps:
            continue
        short_name = pt.split(".")[-1]
        reasons[pt] = (
            f"agent {short_name!r} has no max_active_sessions"
            if short_name in agents_seen else
            f"no agent named {short_name!r} in the output "
            f"({blocks} agent blocks, {len(text)} bytes)")
    return caps, reasons


def _report_cap_transition(pool, cap, source, why):
    """Say so when the ceiling a pool is acted on changes, or stops coming from
    the config -- once per episode, not once per read."""
    before = _cap_in_use.get(pool)
    if before == (cap, source):
        return
    if source != "config":
        print(f"[POOL-AUTOSCALE] [CAP-FALLBACK] pool={pool} cannot read "
              f"max_active_sessions ({why}); acting on "
              f"{_CAP_SOURCE_WORDS[source]} max={cap} until it can", flush=True)
    elif before is not None and before[1] != "config":
        print(f"[POOL-AUTOSCALE] [CAP-RECOVERED] pool={pool} the config answers "
              f"again: max_active_sessions={cap} (was {before[0]}, "
              f"{_CAP_SOURCE_WORDS[before[1]]})", flush=True)
    elif before is not None:
        print(f"[POOL-AUTOSCALE] [CAP-CHANGED] pool={pool} max_active_sessions "
              f"{before[0]}->{cap} (the config changed)", flush=True)


def _cap_note(pool):
    """Text for an alert line saying its cap is a stand-in, not a number the config
    just gave: "" when it is a reading, so a healthy alert reads as it always did.
    An alert that prints `active=4/3` must not let the 3 pass for the config's.
    A pool load_pool_max_active() never resolved (a caller that brings its own
    caps, as the tests do; main() resolves every managed pool first) gets no note:
    this module has made no stand-in for it."""
    source = _cap_in_use.get(pool, (None, "config"))[1]
    if source == "config":
        return ""
    return f" (cap: {_CAP_SOURCE_WORDS[source]}, the config gave no number)"


def load_pool_max_active(pool_templates):
    """Return {template: max_active}, read from `gc config show` on every call.

    Per pool there are three answers, never conflated (ga-d1q1kn): the config
    says N; the config says nothing about this pool (its output has no such agent,
    or the agent has no max_active_sessions); the config could not be read at all.
    Only the first is a number. For the other two the pool keeps the last N the
    config gave, and falls back to FALLBACK_CAPS (1 for a pool not listed there)
    only when it never gave one -- and says so, once per episode:

      [CAP-FALLBACK]   no number: what stands in for it, and why there is none
      [CAP-RECOVERED]  the config answers again: what was in use until now
      [CAP-CHANGED]    the config now says a different number

    Remembers across calls (_last_good_caps, _cap_in_use), like _report_once().
    Never raises: main() calls it outside the per-cycle try, so a bug in the read
    would end the daemon and launchd would restart it into the same failure.
    """
    try:
        caps, reasons = _read_config_caps(pool_templates)
    except Exception as exc:
        caps = {}
        reasons = {pt: f"cap read raised {type(exc).__name__}: {exc}"[:200]
                   for pt in pool_templates}
    resolved = {}
    for pt in pool_templates:
        if pt in caps:
            cap, source = caps[pt], "config"
            _last_good_caps[pt] = cap
        elif pt in _last_good_caps:
            cap, source = _last_good_caps[pt], "last-good"
        else:
            cap, source = FALLBACK_CAPS.get(pt, 1), "fallback"
        _report_cap_transition(pt, cap, source, reasons.get(pt, ""))
        _cap_in_use[pt] = (cap, source)
        resolved[pt] = cap
    return resolved


# ---------------------------------------------------------------------------
# State persistence
# ---------------------------------------------------------------------------

def load_state():
    """Load state file; return empty state on error."""
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(state):
    """Save state to file. Best-effort; never crash."""
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w") as f:
            json.dump(state, f, indent=2)
    except Exception as exc:
        print(f"[POOL-AUTOSCALE] state save failed: {exc}", flush=True)


# ---------------------------------------------------------------------------
# Live data queries
# ---------------------------------------------------------------------------

def probe_would_serve(bead, now_ts):
    """True iff the pool probe would hand this bead out and the watchdog does not
    exclude it itself. See "Demand predicate" above.

    Applies every exclusion in full: exact labels (which `bd ready` also drops
    server-side, so a bd that stops honouring the flag cannot bring the bug
    back), the jq-stage prefixes, epic titles and Pilot holds, plus
    WATCHDOG_EXCLUDE_LABELS.

    A missing or null `labels` key means no labels: bd omits the key for a bead
    nobody has labelled, and the probe's jq reads it the same way. Unreadable
    data (labels that are not a list of strings, a hold expiry that is not an
    epoch) reads as held: under doubt the answer is "no demand", never "wake a
    dog".
    """
    if not isinstance(bead, dict):
        return False
    labels = bead.get("labels") or []
    if not isinstance(labels, list) or not all(isinstance(l, str) for l in labels):
        return False
    if any(l in PROBE_EXCLUDE_LABELS or l in WATCHDOG_EXCLUDE_LABELS
           or l.startswith(PROBE_EXCLUDE_LABEL_PREFIXES) for l in labels):
        return False
    title = bead.get("title")
    if isinstance(title, str) and PROBE_EPIC_TITLE_RE.match(title):
        return False
    if any(l == PROBE_HELD_LABEL or l.startswith(PROBE_HELD_UNTIL_PREFIX) for l in labels):
        expiries = [l[len(PROBE_HELD_UNTIL_PREFIX):] for l in labels
                    if l.startswith(PROBE_HELD_UNTIL_PREFIX)]
        if not expiries or not all(_HOLD_EXPIRY_RE.fullmatch(e) for e in expiries):
            return False
        if max(float(e) for e in expiries) >= now_ts:
            return False
    return True


def _ready_candidates(pool_template):
    """Ready, unassigned beads routed to the pool: the probe's own bd query
    (same exclusions, ordering and 20-bead window) plus WATCHDOG_EXCLUDE_LABELS.

    Returns a list, or None when bd could not be read: "could not tell" must
    never look like "nothing there".
    """
    argv = ["bd", "ready",
            "--metadata-field", f"gc.routed_to={pool_template}",
            "--unassigned", "--exclude-type=epic"]
    for label in PROBE_EXCLUDE_LABELS + WATCHDOG_EXCLUDE_LABELS:
        argv += ["--exclude-label", label]
    argv += ["--json", "--sort", "oldest", f"--limit={PROBE_CANDIDATE_LIMIT}"]
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return None
        data = json.loads(result.stdout)
    except Exception:
        return None
    return data if isinstance(data, list) else None


def _pool_probe_verdict(pool_template):
    """Ask the pool's own work query (`gc hook <pool>`) whether a dog could claim
    anything. Returns (verdict, why):

      ("empty", "")     exit 1 and a bare "[]" on stdout: positively nothing to claim
      ("work", "")      exit 0 and a JSON list with at least one entry
      ("unknown", why)  anything else: a failure, a timeout, an answer that is no list

    `gc hook` exits 1 for errors too (unknown or suspended agent), with an empty
    stdout, so the exit code alone cannot tell "empty" from "broken"; only the
    positive signatures count. It runs without the caller's session identity,
    which `gc hook` would otherwise also answer for.
    """
    env = {k: v for k, v in os.environ.items() if k not in _SESSION_IDENTITY_ENV}
    try:
        result = subprocess.run(["gc", "hook", pool_template], capture_output=True,
                                text=True, timeout=30, env=env)
    except Exception as exc:
        return "unknown", f"{type(exc).__name__}: {exc}"
    out = result.stdout.strip()
    if result.returncode == 1 and out == "[]":
        return "empty", ""
    if result.returncode == 0:
        try:
            body = json.loads(out)
        except ValueError:
            body = None
        if isinstance(body, list) and body:
            return "work", ""
    error_lines = [l.strip() for l in (result.stderr or "").splitlines()
                   if l.strip() and not l.startswith("warning:")]
    return "unknown", (f"exit {result.returncode}, "
                       + (error_lines[-1][:160] if error_lines else "no error text"))


def _report_once(kind, pool_template, message):
    """Print `message` the first time a condition holds for a pool, and again only
    after it has stopped holding. A falsy message means "does not hold now"."""
    key = (kind, pool_template)
    if not message:
        _reported.discard(key)
    elif key not in _reported:
        _reported.add(key)
        print(message, flush=True)


def get_pool_demand(pool_template):
    """Count the beads a pool worker could claim right now. Returns -1 on any error.

    Three answers, never conflated: N >= 1 claimable beads, 0 nothing to claim,
    -1 could not tell (the caller skips the cycle).

    Demand is what the pool worker's own probe would hand out, not every ready
    bead routed to the pool (ga-uv4on5): held, vetoed, parked, epic and
    in-flight beads are not demand, because a dog woken for them finds an empty
    queue and exits. The count is bounded by the probe's candidate window and
    is a presence signal -- scale_decision() only asks whether it is > 0.

    A non-empty count is put to the pool's own probe before it can wake anyone:
    if the probe says the queue is empty, the probe wins. Where the watchdog
    cannot know it says so instead of guessing quietly, once per episode:
      PROBE-UNAVAILABLE  the probe could not be asked; the count stands
      PROBE-DISAGREE     the probe overruled the count
      PROBE-WINDOW-FULL  the probe's window holds nothing claimable, so work
                         behind it is invisible to every dog; still 0, because
                         no dog can claim what its probe cannot see
    """
    candidates = _ready_candidates(pool_template)
    if candidates is None:
        return -1
    if candidates and not any(isinstance(b, dict) for b in candidates):
        return -1   # a list came back but no beads are in it: the format changed
    now_ts = time.time()
    claimable = [b for b in candidates if probe_would_serve(b, now_ts)]

    # `condition and "message"`: a falsy value means the condition does not hold.
    _report_once("window-full", pool_template,
                 not claimable and len(candidates) >= PROBE_CANDIDATE_LIMIT and
                 f"[POOL-AUTOSCALE] [PROBE-WINDOW-FULL] pool={pool_template} the "
                 f"probe's {PROBE_CANDIDATE_LIMIT}-bead candidate window holds "
                 f"nothing claimable; work behind it is invisible to the pool's own "
                 f"probe, so no dog is woken for it")

    verdict, why = _pool_probe_verdict(pool_template) if claimable else ("none", "")
    _report_once("probe-unavailable", pool_template,
                 verdict == "unknown" and
                 f"[POOL-AUTOSCALE] [PROBE-UNAVAILABLE] pool={pool_template} cannot "
                 f"cross-check the count against the pool's own probe ({why}); the "
                 f"watchdog's own count stands ({len(claimable)} claimable)")
    _report_once("probe-disagree", pool_template,
                 verdict == "empty" and
                 f"[POOL-AUTOSCALE] [PROBE-DISAGREE] pool={pool_template} "
                 f"watchdog_claimable={len(claimable)} but the pool's own work query "
                 f"(gc hook) reports an empty queue; trusting the probe, no dog woken. "
                 f"Either the watchdog's copy of the probe is out of date (run "
                 f"test_pool_autoscale_watchdog.py -k engine_probe) or the probe's own "
                 f"bd read failed (it reports errors as empty)")
    return 0 if verdict == "empty" else len(claimable)


def get_pool_sessions(pool_template):
    """Query gc session list --json and classify sessions for this pool.

    Returns dict:
      active: [{id, name}]  — state in ACTIVE_STATES
      asleep: [{id, name}]  — state in ASLEEP_STATES, available to wake
      stuck:  [{id, name, state}]  — transitional / bad-state, do NOT touch
    Returns None on any error (caller should skip cycle).
    """
    try:
        # Option C: cached session-list shim (8s TTL, fail-open) — this 120s poller
        # shares one Dolt read with other pollers instead of issuing its own.
        result = subprocess.run(
            ["bash", "/Users/athos/gt/.gascity-gastown-hq/scripts/gc-session-list-cached.sh"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return None
        data = json.loads(result.stdout)
        sessions = data.get("sessions", [])
    except Exception:
        return None

    active, asleep, stuck = [], [], []
    for s in sessions:
        if s.get("template", "") != pool_template:
            continue
        if s.get("closed", False):
            continue
        sid = s.get("id", "")
        sname = s.get("name", sid)
        state = s.get("state", "").lower()
        if state in ACTIVE_STATES:
            active.append({"id": sid, "name": sname})
        elif state in ASLEEP_STATES:
            asleep.append({"id": sid, "name": sname})
        else:
            # Any other state (reset-pending, creating, draining, drained, etc.)
            # is considered stuck/transitional — do not attempt to wake.
            stuck.append({"id": sid, "name": sname, "state": state})

    return {"active": active, "asleep": asleep, "stuck": stuck}


# ---------------------------------------------------------------------------
# Pure scale-decision function (unit-testable, no side effects)
# ---------------------------------------------------------------------------

def scale_decision(demand, active, max_active, asleep_available, stuck_count,
                   secs_demand_present, secs_demand_absent, watchdog_pins_count):
    """Compute the scaling action for one pool.

    Args:
        demand:              count of unassigned routed tasks (>= 0, or -1 = error)
        active:              count of active pool members
        max_active:          pool capacity ceiling
        asleep_available:    count of cleanly-asleep members (safe to wake)
        stuck_count:         count of stuck/transitional members (skipped)
        secs_demand_present: seconds since demand first appeared (0 if no demand)
        secs_demand_absent:  seconds since demand last went to 0 (0 if demand present)
        watchdog_pins_count: count of watchdog-created pins in state file

    Returns:
        (action, reason)
        action in {"wake_and_pin", "unpin", "stuck_alert", "noop"}
    """
    # Fail safe: bad/invalid data → noop
    if demand < 0 or active < 0 or max_active <= 0:
        return "noop", "bad_data"

    if demand > 0:
        # Scale-up path: hysteresis guard first
        if secs_demand_present < SCALE_UP_AFTER:
            return "noop", (
                f"demand={demand} hysteresis_not_met "
                f"{secs_demand_present:.0f}s/{SCALE_UP_AFTER}s"
            )
        # Hysteresis met — decide scale action
        if active + watchdog_pins_count >= max_active:
            # Pool saturated: active sessions + pending watchdog pins reach cap
            return "stuck_alert", (
                f"demand={demand} queued but pool at max capacity "
                f"(active={active} pins={watchdog_pins_count} max={max_active})"
            )
        if asleep_available > 0:
            # Capacity available and a clean asleep member exists → wake it
            return "wake_and_pin", (
                f"demand={demand} active={active}/{max_active} "
                f"asleep_available={asleep_available}"
            )
        # active < max but no clean asleep member (all stuck/transitional)
        return "stuck_alert", (
            f"demand={demand} active={active}/{max_active} "
            f"no_clean_asleep_members stuck={stuck_count}"
        )

    else:
        # Scale-down path: demand is 0
        if watchdog_pins_count > 0 and secs_demand_absent >= SCALE_DOWN_AFTER:
            return "unpin", (
                f"demand=0 for {secs_demand_absent:.0f}s "
                f"(>= {SCALE_DOWN_AFTER}s) releasing {watchdog_pins_count} watchdog pins"
            )
        return "noop", (
            f"demand=0 pins={watchdog_pins_count} "
            f"idle={secs_demand_absent:.0f}s/{SCALE_DOWN_AFTER}s"
        )


# ---------------------------------------------------------------------------
# Actuation helpers
# ---------------------------------------------------------------------------

def do_wake_and_pin(session_id, session_name):
    """Wake then pin one session. Returns True on full success."""
    try:
        r = subprocess.run(
            ["gc", "session", "wake", session_id],
            capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            print(f"[POOL-AUTOSCALE] wake {session_id}({session_name}) failed: "
                  f"{r.stderr.strip()}", flush=True)
            return False
    except Exception as exc:
        print(f"[POOL-AUTOSCALE] wake exception {session_id}: {exc}", flush=True)
        return False

    time.sleep(1)  # brief pause before pin to let wake settle

    try:
        r = subprocess.run(
            ["gc", "session", "pin", session_id],
            capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            print(f"[POOL-AUTOSCALE] pin {session_id}({session_name}) failed: "
                  f"{r.stderr.strip()}", flush=True)
            return False
    except Exception as exc:
        print(f"[POOL-AUTOSCALE] pin exception {session_id}: {exc}", flush=True)
        return False

    return True


def do_unpin(session_id):
    """Remove watchdog pin from session. Returns True on success."""
    try:
        r = subprocess.run(
            ["gc", "session", "unpin", session_id],
            capture_output=True, text=True, timeout=20)
        return r.returncode == 0
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Work-order lib: does the Ordem unica still reach the pool? (ga-9t9acg.15)
# ---------------------------------------------------------------------------
# Once engine patch ga-9t9acg.7 is swapped in, the pool probe orders what it hands out
# through work-order.sh (`wo_pick`). When the lib is absent, unreadable or "cannot tell"
# it serves the PREVIOUS order instead, which is safe for the content and wrong for the
# rule -- and the only trace is a WARN on stderr that the engine's hook runner keeps
# in a buffer and shows only when the command fails. A deleted file, a wrong path or a
# broken edit on the shared tree therefore switches the rule off with no sign. Until the
# swap this is a pre-flight: it says whether the lib is fit to be relied on.
#
# This asks the question wo_pick asks, the way it asks it: the same lookup
# (work_order_lib_path), the same child bash, and the same test before the answer is
# trusted -- exit 0 AND stdout exactly one JSON array as long as the input. It does NOT
# check the order itself: that is work-order.selftest.sh's job, and a copy of the rule
# here would raise a false alarm the day the rule changes.
#
# Three answers, never conflated:
#   ok       the engine would trust the lib's answer
#   broken   it would not, so it would fall back: said once per episode (push + log)
#   unknown  the question could not be asked (bash would not start, no answer in time):
#            says nothing about the lib; said once in the log, no push, and it does not
#            end a broken episode

# The city the lib is looked up in when neither GC_CITY_PATH nor GC_CITY is set. The
# engine would find nothing then; this daemon keeps checking the real city, and says so.
DEFAULT_CITY_PATH = "/Users/athos/gt/.gascity-gastown-hq"
WORK_ORDER_LIB_REL = os.path.join("packs", "town-deltas", "assets", "scripts", "work-order.sh")

# What wo_pick runs: the lib is sourced in a child bash, never in the query's sh.
WORK_ORDER_CHILD = ["bash", "-c", '. "$1" && work_order_sort --age reclaim', "wo"]
WORK_ORDER_CHECK_TIMEOUT = 30   # a sample of three beads: seconds even on a loaded machine
WORK_ORDER_REASON_MAX = 160     # one short line in the log and in the push

# Input for the check, shaped like `bd ready --json`: a bead that the `reclaim` age
# reads (pilot:reclaim-count -> updated_at), one that bd emits without a `labels` key,
# and distinct priorities and types. Clean on purpose: the lib has nothing to WARN about,
# so a lib that cannot read an ordinary bead cannot pass through its tolerant path.
WORK_ORDER_SAMPLE = [
    {"id": "wo-sample-1", "priority": 2, "issue_type": "task",
     "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z",
     "labels": []},
    {"id": "wo-sample-2", "priority": 0, "issue_type": "feature",
     "created_at": "2026-01-02T00:00:00Z", "updated_at": "2026-01-03T00:00:00Z",
     "labels": ["pilot:reclaim-count:1"]},
    {"id": "wo-sample-3", "priority": 0, "issue_type": "bug",
     "created_at": "2026-01-04T00:00:00Z", "updated_at": "2026-01-04T00:00:00Z"},
]

# Reason the open BROKEN episode was raised with, None while there is none. It is only
# ever cleared by an "ok" reading: an "unknown" one proves nothing. Held in memory like
# _reported: a restart in the middle of an episode says it once more, which is the
# reminder a restart should give.
_wo_lib_state = {"broken_why": None}


def _one_line(text, limit=WORK_ORDER_REASON_MAX):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[:limit - 3] + "..."


def work_order_lib_path(environ=None):
    """Where the engine's wo_pick looks for the lib, as (path, source): $WORK_ORDER_LIB,
    else $GC_CITY_PATH, else $GC_CITY (+ packs/town-deltas/assets/scripts/work-order.sh).
    The first one that is set and non-empty is THE lib; an unusable one does not cascade
    to the next. With none set the default city stands in, and `source` says so."""
    env = os.environ if environ is None else environ
    own = env.get("WORK_ORDER_LIB") or ""
    if own:
        return own, "WORK_ORDER_LIB"
    for name in ("GC_CITY_PATH", "GC_CITY"):
        root = env.get(name) or ""
        if root:
            return os.path.join(root, WORK_ORDER_LIB_REL), name
    return (os.path.join(DEFAULT_CITY_PATH, WORK_ORDER_LIB_REL),
            "default city: GC_CITY_PATH and GC_CITY unset")


def check_work_order_lib():
    """Ask the lib what wo_pick asks it. Returns (verdict, why, lib) with verdict
    "ok" | "broken" | "unknown" (see the section comment); `lib` is the path and where it
    came from, for the log. What it cannot run is "unknown", not an exception; a bug in
    here is still caught one level up, by watch_work_order_lib()."""
    path, source = work_order_lib_path()
    lib = "%s (%s)" % (path, source)
    if not os.access(path, os.R_OK):
        return "broken", "not readable (missing, or no permission)", lib
    try:
        run = subprocess.run(WORK_ORDER_CHILD + [path], input=json.dumps(WORK_ORDER_SAMPLE),
                             capture_output=True, text=True, timeout=WORK_ORDER_CHECK_TIMEOUT)
    except subprocess.TimeoutExpired:
        return "unknown", "no answer in %ds" % WORK_ORDER_CHECK_TIMEOUT, lib
    except Exception as exc:
        return "unknown", _one_line("%s: %s" % (type(exc).__name__, exc)), lib
    if run.returncode != 0:
        errors = [l.strip() for l in (run.stderr or "").splitlines() if l.strip()]
        return ("broken", "work_order_sort exit %d" % run.returncode
                + (": " + _one_line(errors[-1]) if errors else ""), lib)
    try:
        body = json.loads(run.stdout)
    except ValueError:
        body = None
    if not (isinstance(body, list) and len(body) == len(WORK_ORDER_SAMPLE)):
        return ("broken", "work_order_sort exit 0 but its stdout is not one JSON array of %d "
                "beads (got %r)" % (len(WORK_ORDER_SAMPLE), _one_line(run.stdout, 60)), lib)
    return "ok", "", lib


def watch_work_order_lib():
    """One reading of the lib, and a line only when the answer CHANGES the story:
    BROKEN (push + log) when an episode opens, RECOVERED when an "ok" closes it,
    UNCHECKED (log only) when the question could not be asked. A fault that persists is
    not repeated every cycle. Returns the verdict. Does not raise."""
    try:
        verdict, why, lib = check_work_order_lib()
    except Exception as exc:
        verdict, lib = "unknown", "?"
        why = _one_line("the check itself raised %s: %s" % (type(exc).__name__, exc))
    if verdict == "unknown":
        _report_once("wo-lib-unchecked", "city",
                     "[POOL-AUTOSCALE] [WORK-ORDER-LIB-UNCHECKED] lib=%s could not be "
                     "checked (%s); whether the Ordem unica reaches the pool is not known "
                     "until it can" % (lib, why))
        return verdict
    _report_once("wo-lib-unchecked", "city", "")      # a reading was made: that episode is over
    was = _wo_lib_state["broken_why"]
    if verdict == "broken" and was is None:
        _wo_lib_state["broken_why"] = why
        emit("[POOL-AUTOSCALE] [WORK-ORDER-LIB-BROKEN] lib=%s: %s. Whatever falls back when "
             "this lib fails (the pool probe's wo_pick, ga-9t9acg.7) serves the PREVIOUS "
             "order and says so only on a stderr the hook runner drops: the Ordem unica does "
             "not get through. Restore or fix the file, then run "
             "packs/town-deltas/assets/scripts/work-order.selftest.sh" % (lib, why))
    elif verdict == "ok" and was is not None:
        _wo_lib_state["broken_why"] = None
        print("[POOL-AUTOSCALE] [WORK-ORDER-LIB-RECOVERED] lib=%s answers again "
              "(was: %s)" % (lib, was), flush=True)
    return verdict


# ---------------------------------------------------------------------------
# Main poll cycle
# ---------------------------------------------------------------------------

def run_cycle(pool_caps, state, stuck_alerted):
    """Single poll cycle. Mutates state and stuck_alerted in place."""
    now = time.time()

    for pool in MANAGED_POOLS:
        max_active = pool_caps.get(pool, 1)

        # Initialise per-pool state if new
        pool_state = state.setdefault(pool, {
            "pinned_ids": [],
            "demand_first_seen_ts": 0.0,
            "idle_first_seen_ts": 0.0,
        })

        # --- Demand query (fail-safe: skip on error) ---
        demand = get_pool_demand(pool)
        if demand < 0:
            print(f"[POOL-AUTOSCALE] {pool}: demand query failed — skipping cycle",
                  flush=True)
            continue

        # --- Session state query (fail-safe: skip on error) ---
        sessions = get_pool_sessions(pool)
        if sessions is None:
            print(f"[POOL-AUTOSCALE] {pool}: session list failed — skipping cycle",
                  flush=True)
            continue

        active_sessions = sessions["active"]
        asleep_sessions = sessions["asleep"]
        stuck_sessions  = sessions["stuck"]
        active_count = len(active_sessions)
        asleep_count = len(asleep_sessions)
        stuck_count  = len(stuck_sessions)

        # --- Update demand timestamps ---
        if demand > 0:
            if pool_state["demand_first_seen_ts"] == 0.0:
                pool_state["demand_first_seen_ts"] = now
            pool_state["idle_first_seen_ts"] = 0.0
            secs_demand_present = now - pool_state["demand_first_seen_ts"]
            secs_demand_absent  = 0.0
        else:
            pool_state["demand_first_seen_ts"] = 0.0
            if pool_state["idle_first_seen_ts"] == 0.0:
                pool_state["idle_first_seen_ts"] = now
            secs_demand_present = 0.0
            secs_demand_absent  = now - pool_state["idle_first_seen_ts"]

        # --- Prune pinned_ids for sessions that no longer exist in the pool ---
        current_ids = set(
            s["id"] for s in active_sessions + asleep_sessions + stuck_sessions
        )
        pinned_ids = [pid for pid in pool_state.get("pinned_ids", [])
                      if pid in current_ids]
        pool_state["pinned_ids"] = pinned_ids

        # --- Compute decision ---
        action, reason = scale_decision(
            demand=demand,
            active=active_count,
            max_active=max_active,
            asleep_available=asleep_count,
            stuck_count=stuck_count,
            secs_demand_present=secs_demand_present,
            secs_demand_absent=secs_demand_absent,
            watchdog_pins_count=len(pinned_ids),
        )

        # --- Actuate ---
        if action == "wake_and_pin":
            # Pick one clean asleep session: prefer un-pinned candidates first
            candidates = [s for s in asleep_sessions if s["id"] not in pinned_ids]
            if not candidates:
                candidates = asleep_sessions
            target = candidates[0]

            ok = do_wake_and_pin(target["id"], target["name"])
            status = "SCALED-UP" if ok else "SCALE-UP-FAILED"
            emit(
                f"[POOL-AUTOSCALE] [{status}] pool={pool} "
                f"woke+pinned={target['id']}({target['name']}) "
                f"demand={demand} active={active_count}→"
                f"{active_count + (1 if ok else 0)}/{max_active}{_cap_note(pool)} "
                f"reason: {reason}"
            )
            if ok:
                pool_state["pinned_ids"] = list(set(pinned_ids + [target["id"]]))
            # Clear stuck alert cadence on successful scale-up
            stuck_alerted.pop(pool, None)

        elif action == "unpin":
            # Unpin all watchdog-pinned sessions (demand is gone)
            remaining = []
            for pid in pinned_ids:
                ok = do_unpin(pid)
                status = "SCALED-DOWN" if ok else "SCALE-DOWN-UNPIN-FAILED"
                emit(
                    f"[POOL-AUTOSCALE] [{status}] pool={pool} "
                    f"unpinned={pid} demand=0 reason: {reason}"
                )
                if not ok:
                    remaining.append(pid)
            pool_state["pinned_ids"] = remaining
            if not remaining:
                pool_state["idle_first_seen_ts"] = 0.0  # reset after full scale-down
            stuck_alerted.pop(pool, None)

        elif action == "stuck_alert":
            # Rate-limit STUCK alerts to avoid ntfy spam
            last_stuck = stuck_alerted.get(pool, 0)
            if now - last_stuck >= STUCK_REALERT_SEC and active_count >= max_active and _gate_focus_active(now):
                # ga-kqa08j: the cap is low on purpose while the gate drains — log, no push.
                print(f"[POOL-AUTOSCALE] [CAPPED-BY-GATE-FOCUS] pool={pool} demand={demand} "
                      f"active={active_count}/{max_active} — gate focus mode holds the dog cap low on purpose; "
                      f"no alert", flush=True)
                stuck_alerted[pool] = now
            elif now - last_stuck >= STUCK_REALERT_SEC:
                emit(
                    f"[POOL-AUTOSCALE] [STUCK] pool={pool} "
                    f"demand={demand} active={active_count}/{max_active}{_cap_note(pool)} "
                    f"asleep={asleep_count} stuck_sessions={stuck_count} "
                    f"reason: {reason}"
                )
                _paw_ledger("human-touch", {"ts": _paw_datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "source_daemon": "pool-autoscale-watchdog", "stage": "crew-liveness", "kind": "technical", "bead_id": "", "reason": reason}, fail_open=True)
                stuck_alerted[pool] = now

        # action == "noop" → silence


def main():
    pool_caps = load_pool_max_active(MANAGED_POOLS)
    # `caps=` alone reads the same whether the config said 3 or nothing could be
    # read; cap_source says which (config | last-good | fallback).
    cap_source = {pt: _cap_in_use[pt][1] for pt in pool_caps}
    # ga-9t9acg.15: the first reading of the work-order lib; `work_order_lib=` says what
    # it found (ok | broken | unknown), so a restart proves the new code by this line.
    work_order_lib = watch_work_order_lib()
    print(
        f"[POOL-AUTOSCALE] [STARTUP] managed_pools={MANAGED_POOLS} "
        f"caps={pool_caps} cap_source={cap_source} work_order_lib={work_order_lib} "
        f"scale_up_after={SCALE_UP_AFTER}s "
        f"scale_down_after={SCALE_DOWN_AFTER}s poll={POLL_SEC}s",
        flush=True
    )

    state = load_state()
    stuck_alerted = {}  # pool -> last STUCK alert timestamp

    # Emit initial state snapshot for diagnostics
    for pool in MANAGED_POOLS:
        demand = get_pool_demand(pool)
        sessions = get_pool_sessions(pool)
        if sessions is not None and demand >= 0:
            print(
                f"[POOL-AUTOSCALE] [STARTUP] {pool}: "
                f"demand={demand} active={len(sessions['active'])} "
                f"asleep={len(sessions['asleep'])} stuck={len(sessions['stuck'])} "
                f"max={pool_caps.get(pool, '?')} "
                f"watchdog_pins={len(state.get(pool, {}).get('pinned_ids', []))}",
                flush=True
            )

    while True:
        try:
            run_cycle(pool_caps, state, stuck_alerted)
            save_state(state)
        except Exception as exc:
            print(f"[POOL-AUTOSCALE] cycle exception: {exc}", flush=True)
        # Its own step, outside the scaling try: a lib that is down must not cost the pool
        # its dogs, and a bug in the scaling must not hide a lib that is down.
        try:
            watch_work_order_lib()
        except Exception as exc:
            print(f"[POOL-AUTOSCALE] work-order lib check exception: {exc}", flush=True)
        time.sleep(POLL_SEC)
        # Read the ceilings again for the next cycle (ga-d1q1kn): the config can
        # change, and the start-up read can miss -- right after a boot the first
        # cycle's own gc/bd calls fail too. A read that fails keeps the last good
        # value, and load_pool_max_active() says so.
        pool_caps = load_pool_max_active(MANAGED_POOLS)


if __name__ == "__main__":
    main()
