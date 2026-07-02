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


# ---------------------------------------------------------------------------
# Config: pool max_active_sessions
# ---------------------------------------------------------------------------

def load_pool_max_active(pool_templates):
    """Parse gc config show to find max_active_sessions for each pool template.

    Pool templates like "gastown.dog" map to config agent name "dog"
    (the last component). Returns {template: max_active}; falls back to
    hardcoded values on parse failure.
    """
    FALLBACK = {"gastown.dog": 3}
    try:
        result = subprocess.run(
            ["gc", "config", "show"],
            capture_output=True, text=True, timeout=20)
        text = result.stdout
    except Exception:
        return FALLBACK

    caps = {}
    # Split on [[agent]] blocks to avoid cross-block contamination.
    # gc config show emits [[agent]] sections for each resolved agent.
    agent_block_re = re.compile(r'\[\[agent\]\](.*?)(?=\[\[agent\]\]|\Z)', re.DOTALL)
    for block in agent_block_re.findall(text):
        name_m = re.search(r'^name\s*=\s*"([^"]+)"', block, re.MULTILINE)
        cap_m = re.search(r'^max_active_sessions\s*=\s*(\d+)', block, re.MULTILINE)
        if not name_m or not cap_m:
            continue
        short_name = name_m.group(1)
        cap = int(cap_m.group(1))
        for pt in pool_templates:
            # Match "gastown.dog" -> "dog" (last component)
            if pt.split(".")[-1] == short_name:
                caps[pt] = cap

    return {pt: caps.get(pt, FALLBACK.get(pt, 1)) for pt in pool_templates}


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

def get_pool_demand(pool_template):
    """Count unassigned tasks routed to this pool. Returns -1 on any error.

    Excludes story:in-flight / pilot:dispatched labels: a source bead that is
    already being worked (or already slung) is NOT unmet demand, even if it
    still carries gc.routed_to. Counting it would inflate demand, spawn a
    surplus dog, and let that dog re-claim the in-flight bead (double-dispatch,
    ga-ms1jm / ga-lx7om). bd ready already drops in_progress/hooked *statuses*;
    these are *labels* on still-open source beads, so they need explicit
    exclusion. Mirrors the Pilot's own --exclude-label pilot:dispatched guard.
    """
    try:
        result = subprocess.run(
            ["bd", "ready",
             "--metadata-field", f"gc.routed_to={pool_template}",
             "--unassigned", "--exclude-type=epic",
             "--exclude-label", "story:in-flight",
             "--exclude-label", "pilot:dispatched",
             "--json"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return -1
        data = json.loads(result.stdout)
        if not isinstance(data, list):
            return -1
        return len(data)
    except Exception:
        return -1


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
                f"{active_count + (1 if ok else 0)}/{max_active} "
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
            if now - last_stuck >= STUCK_REALERT_SEC:
                emit(
                    f"[POOL-AUTOSCALE] [STUCK] pool={pool} "
                    f"demand={demand} active={active_count}/{max_active} "
                    f"asleep={asleep_count} stuck_sessions={stuck_count} "
                    f"reason: {reason}"
                )
                _paw_ledger("human-touch", {"ts": _paw_datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "source_daemon": "pool-autoscale-watchdog", "stage": "crew-liveness", "kind": "technical", "bead_id": "", "reason": reason}, fail_open=True)
                stuck_alerted[pool] = now

        # action == "noop" → silence


def main():
    pool_caps = load_pool_max_active(MANAGED_POOLS)
    print(
        f"[POOL-AUTOSCALE] [STARTUP] managed_pools={MANAGED_POOLS} "
        f"caps={pool_caps} scale_up_after={SCALE_UP_AFTER}s "
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
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    main()
