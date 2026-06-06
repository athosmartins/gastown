#!/usr/bin/env python3
"""Crew session deduplication guard.

Enforces the invariant: a singleton-crew agent must never have more than one
active session on the same rig.  Runs every ~45s; silence = healthy.

CONSERVATIVE v1 logic:
  - A duplicate group triggers an AUTO-DRAIN only when:
      * exactly ONE session is in a clean active state (state="active",
        no bad-state markers), AND
      * the other session(s) carry at least one bad-state marker (see
        BAD_STATE_SIGNALS).
    In that case the clean session is the KEEPER and the bad-state ones
    are drained via `gc session close <id>` (graceful — NOT gc session kill).
  - AMBIGUOUS groups (2+ sessions all in clean-looking state, or all in bad
    state, or any other uncertain configuration) → ALERT ONLY, no auto-kill.
    Killing a possibly-working session risks losing uncommitted work.

Alert format (also sent via notify CLI):
  [DEDUP-DRAIN]  rig=<rig> agent=<template> kept=<id> drained=<id>
                 origin=<session_origin> resume=<resume_flag> state=<state>
  [DEDUP-AMBIG]  rig=<rig> agent=<template> sessions=<ids> reason=<why>

Re-act cadence:
  - Track drained session-ids to avoid re-draining.
  - Track alerted-ambig keys to avoid spam (re-alert every REALERT_SEC if
    still ambiguous with a new set of session ids).
  - If a NEW duplicate appears for a previously-clean agent, act on it.
"""
import json
import subprocess
import time

POLL_SEC = 45
REALERT_SEC = 900   # 15min re-alert cadence for stuck ambiguous groups

# States / reason substrings that identify a session as a bad-state LOSER.
# Any session whose state is in BAD_STATES or whose state OR name contains
# any substring in BAD_STATE_SIGNALS is classified as a loser candidate.
BAD_STATES = {"asleep", "creating", "drained", "draining"}
BAD_STATE_SIGNALS = [
    "reset-pending",
    "continuation_reset_pending",
    "runtime-missing",
    "pending_create",
    "creating",
    "asleep",
    "drained",
    "draining",
]


# ---------------------------------------------------------------------------
# Config: singleton templates (max_active_sessions=1).
# Read once at startup from `gc config show`; falls back to known-good set.
# ---------------------------------------------------------------------------

KNOWN_NON_SINGLETONS = {"dog", "gate-reviewer"}  # empirically confirmed >1

def load_singleton_templates():
    """Parse `gc config show` output to build the set of singleton templates."""
    try:
        result = subprocess.run(
            ["gc", "config", "show"],
            capture_output=True, text=True, timeout=20)
        text = result.stdout + result.stderr
    except Exception:
        text = ""

    import re
    # Match [[agent]] blocks: name = "X" ... max_active_sessions = N
    # The config output is TOML-like; grab pairs in order.
    names = re.findall(r'^name\s*=\s*"([^"]+)"', text, re.MULTILINE)
    caps  = re.findall(r'^max_active_sessions\s*=\s*(\d+)', text, re.MULTILINE)

    singletons = set()
    for name, cap in zip(names, caps):
        if cap == "1":
            # Strip rig-prefix if present (e.g. "property_scrapers/claude" -> just track full name)
            singletons.add(name)

    # Belt-and-suspenders: always exclude known pools
    singletons -= KNOWN_NON_SINGLETONS

    if not singletons:
        # Fallback: hard-coded from empirical run on 2026-06-06
        singletons = {
            "boot", "deacon", "mayor",
            "batista-lx", "batista-ps", "batista-wa",
            "digo-wa", "mila-wa", "oracle-wa", "peter-wa", "thies-wa",
            "claude", "control-dispatcher",
        }

    return singletons


# ---------------------------------------------------------------------------
# Session inspection helpers
# ---------------------------------------------------------------------------

def is_bad_state(session):
    """Return True if this session has bad-state signals (loser candidate)."""
    state = session.get("state", "").lower()
    if state in BAD_STATES:
        return True
    # Check state and name for signal substrings
    haystack = " ".join([
        state,
        session.get("title", ""),
        session.get("session_name", ""),
        session.get("name", ""),
    ]).lower()
    for sig in BAD_STATE_SIGNALS:
        if sig in haystack:
            return True
    return False


def rig_from_session(session):
    """Derive a rig identifier from work_dir.

    Examples:
      /Users/athos/gt/whatsapp_automation/crew/digo  -> whatsapp_automation
      /Users/athos/gt/.gascity-gastown-hq/.gc/...    -> .gascity-gastown-hq
      /Users/athos/gt/property_scrapers/crew/batista -> property_scrapers
      /Users/athos/gt/lexbh/crew/batista             -> lexbh
    """
    explicit_rig = session.get("rig", "")
    if explicit_rig:
        return explicit_rig

    work_dir = session.get("work_dir", "")
    # Strip the gt root prefix
    gt_root = "/Users/athos/gt/"
    if work_dir.startswith(gt_root):
        rest = work_dir[len(gt_root):]
        return rest.split("/")[0]
    return work_dir  # fallback: use full path as key


def list_active_sessions():
    """Call `gc session list --json` and return parsed session list."""
    try:
        result = subprocess.run(
            ["gc", "session", "list", "--json"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return []
        data = json.loads(result.stdout)
        return data.get("sessions", [])
    except Exception:
        return []


def drain_session(session_id):
    """Graceful close — NOT gc session kill (kill triggers reconciler restart)."""
    try:
        result = subprocess.run(
            ["gc", "session", "close", session_id],
            capture_output=True, text=True, timeout=20)
        return result.returncode == 0
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Notify helper
# ---------------------------------------------------------------------------

def emit(msg):
    """Print alert line and fire notify CLI (best-effort, never crash)."""
    print(msg, flush=True)
    try:
        subprocess.run(
            ["/Users/athos/.local/bin/notify", "-t", "Crew dedup", "-p", "4", msg],
            timeout=10, capture_output=True)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Main guard loop
# ---------------------------------------------------------------------------

def run_cycle(singleton_templates, drained_ids, ambig_alerted):
    """Single poll cycle. Mutates drained_ids and ambig_alerted in place."""
    sessions = list_active_sessions()
    if not sessions:
        return

    # Build groups: (rig, template) -> [session, ...]
    # Only consider sessions that:
    #   1. Have a template in singleton_templates
    #   2. Are NOT closed
    #   3. State is not "drained"/"draining" already (engine handling it)
    groups = {}
    for s in sessions:
        template = s.get("template", "")
        if template not in singleton_templates:
            continue
        if s.get("closed", False):
            continue
        state = s.get("state", "").lower()
        if state in ("drained", "draining"):
            continue
        # Exclude cap-exempt adhoc workers (e.g. property_scrapers/claude-adhoc-*,
        # gate-reviewer-adhoc-*, dog-adhoc-*): they are spawned in PARALLEL by
        # design and are never singleton-crew duplicates. Draining one would kill
        # legitimate concurrent work. The "-adhoc-" infix is the engine's marker
        # for cap-exempt sessions.
        names = " ".join([
            s.get("session_name", ""), s.get("name", ""), str(s.get("id", "")),
        ]).lower()
        if "-adhoc-" in names:
            continue
        rig = rig_from_session(s)
        key = (rig, template)
        groups.setdefault(key, []).append(s)

    for (rig, template), group in groups.items():
        if len(group) <= 1:
            # Healthy singleton — clean up any stale ambig tracking
            ambig_key = (rig, template)
            ambig_alerted.pop(ambig_key, None)
            continue

        # --- VIOLATION: >1 session for a singleton (rig, template) ---
        session_ids = frozenset(s["id"] for s in group)
        ambig_key = (rig, template)

        # Classify each session
        bad  = [s for s in group if is_bad_state(s)]
        good = [s for s in group if not is_bad_state(s)]

        if len(good) == 1 and len(bad) >= 1:
            # CONSERVATIVE AUTO-DRAIN: exactly one clean keeper, rest are losers
            keeper = good[0]
            losers = bad

            for loser in losers:
                loser_id = loser["id"]
                if loser_id in drained_ids:
                    continue  # already handled this session

                # Build rich diagnostic for the alert
                loser_origin  = loser.get("session_origin", loser.get("resume_style", "?"))
                loser_resume  = loser.get("resume_flag", "?")
                loser_state   = loser.get("state", "?")
                loser_name    = loser.get("name", loser_id)
                keeper_id     = keeper["id"]
                keeper_name   = keeper.get("name", keeper_id)

                ok = drain_session(loser_id)
                status = "drained" if ok else "drain-FAILED"

                emit(
                    f"[DEDUP-{status.upper()}] rig={rig} agent={template} "
                    f"kept={keeper_id}({keeper_name}) "
                    f"drained={loser_id}({loser_name}) "
                    f"origin={loser_origin} resume={loser_resume} state={loser_state}"
                )
                drained_ids.add(loser_id)

            # Clear any ambig tracking for this key (it's resolved now)
            ambig_alerted.pop(ambig_key, None)

        else:
            # AMBIGUOUS — do not auto-kill, alert only
            # Re-alert if session composition changed OR REALERT_SEC elapsed
            last_alert_time, last_ids = ambig_alerted.get(ambig_key, (0, frozenset()))
            now = time.time()
            if session_ids != last_ids or (now - last_alert_time) > REALERT_SEC:
                ids_str = " ".join(sorted(s["id"] for s in group))
                states_str = " ".join(
                    f"{s['id']}={s.get('state','?')}" for s in group)
                if len(good) == 0:
                    reason = "all sessions in bad/transitional state — reconciler may handle"
                elif len(good) >= 2:
                    reason = "multiple sessions appear clean — cannot safely auto-drain"
                else:
                    reason = f"good={len(good)} bad={len(bad)} unclear split"

                emit(
                    f"[DEDUP-AMBIG] rig={rig} agent={template} "
                    f"sessions=[{ids_str}] states=({states_str}) "
                    f"reason={reason} — HUMAN REVIEW REQUIRED"
                )
                ambig_alerted[ambig_key] = (now, session_ids)


def main():
    singleton_templates = load_singleton_templates()

    drained_ids   = set()   # session IDs we have already drained (avoid re-drain)
    ambig_alerted = {}      # (rig, template) -> (last_alert_time, frozenset(ids))

    while True:
        try:
            run_cycle(singleton_templates, drained_ids, ambig_alerted)
        except Exception as exc:
            # Never crash the guard loop — log and continue
            print(f"[DEDUP-ERROR] cycle exception: {exc}", flush=True)
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    main()
