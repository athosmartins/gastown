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

Singleton templates (max_active_sessions == 1) are read fresh from `gc config
show` every cycle (ga-878qeq): parsed one [[agent]] block at a time, so a
block with no cap of its own (e.g. gemini-worker) can never shift a later
block's name onto an earlier block's cap. A read that gives nothing usable
keeps the last good set rather than guessing a fixed one in silence -- see
load_singleton_templates().
"""
import json
import re
import subprocess
import time

POLL_SEC = 90
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
# Read fresh from `gc config show` every cycle; a read that gives nothing
# usable keeps the last good set, falling back to a hardcoded one only if
# the config has never answered.
# ---------------------------------------------------------------------------

KNOWN_NON_SINGLETONS = {"dog", "gate-reviewer"}  # empirically confirmed >1

# What to act on until `gc config show` has ever answered (empirical run on
# 2026-06-06). Never re-entered once a real read has succeeded even once --
# see load_singleton_templates().
FALLBACK_SINGLETONS = frozenset({
    "boot", "deacon", "mayor",
    "batista-lx", "batista-ps", "batista-wa",
    "digo-wa", "mila-wa", "oracle-wa", "peter-wa", "thies-wa",
    "claude", "control-dispatcher",
})

# The last known-good singleton set `gc config show` gave us. Never holds
# FALLBACK_SINGLETONS -- only ever a set an actual parse produced.
_last_good_singletons = None

# (frozenset, source) load_singleton_templates() last acted on, source being
# "config", "last-good" (a failed read kept the last good set) or "fallback"
# (the config has never answered). Lets a transition be reported once instead
# of on every read.
_singleton_state = None

_SINGLETON_SOURCE_WORDS = {"last-good": "the last value it gave",
                           "fallback": "the hardcoded fallback"}


def _read_config_singletons():
    """One read of `gc config show` -> (singletons, why).

    `singletons` is a frozenset of agent names whose max_active_sessions == 1,
    parsed one [[agent]] block at a time (never None on a good read -- an
    output with zero singleton blocks is a legitimate, if unlikely, answer).
    `why` is empty on a good read, else the reason no set could be produced at
    all: the command failed, timed out, or its output had no [[agent]] blocks.

    Blocks, not position: the previous version paired every `name = "..."`
    line with every `max_active_sessions = N` line by list position (zip). An
    agent block with no cap of its own (gemini-worker, codex-test, ... have
    none) shifted every following block's name onto an earlier block's cap --
    ga-878qeq measured 12 agents misclassified this way, mayor among them.
    """
    try:
        result = subprocess.run(
            ["gc", "config", "show"],
            capture_output=True, text=True, timeout=20)
    except Exception as exc:
        return None, f"gc config show failed: {type(exc).__name__}: {exc}"[:200]
    if result.returncode != 0:
        error_lines = [l.strip() for l in (result.stderr or "").splitlines()
                       if l.strip() and not l.startswith("warning:")]
        why = (f"gc config show exit {result.returncode}, "
               + (error_lines[-1][:160] if error_lines else "no error text"))
        return None, why

    text = result.stdout or ""
    singletons, blocks = set(), 0
    agent_block_re = re.compile(r'\[\[agent\]\](.*?)(?=\[\[agent\]\]|\Z)', re.DOTALL)
    for block in agent_block_re.findall(text):
        blocks += 1
        name_m = re.search(r'^name\s*=\s*"([^"]+)"', block, re.MULTILINE)
        cap_m = re.search(r'^max_active_sessions\s*=\s*(\d+)', block, re.MULTILINE)
        if not name_m or not cap_m:
            continue
        if cap_m.group(1) == "1":
            singletons.add(name_m.group(1))

    if blocks == 0:
        return None, f"no [[agent]] blocks in output ({len(text)} bytes)"

    # Belt-and-suspenders: always exclude known pools, even if misconfigured
    # with max_active_sessions=1.
    return frozenset(singletons - KNOWN_NON_SINGLETONS), ""


def _report_singleton_transition(singletons, source, why):
    """Say so when the singleton set acted on changes, or stops coming from
    the config -- once per episode, not once per read."""
    global _singleton_state
    if _singleton_state == (singletons, source):
        return
    before = _singleton_state
    if source != "config":
        print(f"[DEDUP-CAP-FALLBACK] cannot read singleton templates from "
              f"`gc config show` ({why}); acting on "
              f"{_SINGLETON_SOURCE_WORDS[source]} ({len(singletons)} templates) "
              f"until it can", flush=True)
    elif before is not None and before[1] != "config":
        print(f"[DEDUP-CAP-RECOVERED] the config answers again: "
              f"{len(singletons)} singleton templates (was {len(before[0])}, "
              f"{_SINGLETON_SOURCE_WORDS[before[1]]})", flush=True)
    elif before is not None and before[0] != singletons:
        added, removed = sorted(singletons - before[0]), sorted(before[0] - singletons)
        print(f"[DEDUP-CAP-CHANGED] singleton templates changed: "
              f"+{added} -{removed}", flush=True)
    _singleton_state = (singletons, source)


def load_singleton_templates():
    """Return the set of singleton templates (max_active_sessions == 1),
    read fresh from `gc config show` on every call.

    Three answers, never conflated (same class as ga-d1q1kn): the config
    gives a set (possibly empty); the config could not be read at all (bad
    exit, timeout, exception, or no parseable [[agent]] blocks). Only the
    first is a reading. For the second, the set in use stays whatever the
    config last actually gave, and only falls back to the 2026-06-06
    hardcoded set if the config has NEVER answered -- and says so, once per
    episode, via _report_singleton_transition().
    """
    global _last_good_singletons
    try:
        singletons, why = _read_config_singletons()
    except Exception as exc:
        singletons, why = None, f"parse raised {type(exc).__name__}: {exc}"[:200]

    if singletons is not None:
        result, source = singletons, "config"
        _last_good_singletons = singletons
    elif _last_good_singletons is not None:
        result, source = _last_good_singletons, "last-good"
    else:
        result, source = FALLBACK_SINGLETONS, "fallback"

    _report_singleton_transition(result, source, why)
    return set(result)


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
        # Option C: cached session-list shim (8s TTL, fail-open) — this 90s poller
        # shares one Dolt read with other pollers instead of issuing its own.
        result = subprocess.run(
            ["bash", "/Users/athos/gt/.gascity-gastown-hq/scripts/gc-session-list-cached.sh"],
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
    drained_ids   = set()   # session IDs we have already drained (avoid re-drain)
    ambig_alerted = {}      # (rig, template) -> (last_alert_time, frozenset(ids))

    while True:
        # Read fresh every cycle (ga-878qeq): a boot-time miss or a config
        # change must heal on the next cycle, not wait for a daemon restart.
        singleton_templates = load_singleton_templates()
        try:
            run_cycle(singleton_templates, drained_ids, ambig_alerted)
        except Exception as exc:
            # Never crash the guard loop — log and continue
            print(f"[DEDUP-ERROR] cycle exception: {exc}", flush=True)
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    main()
