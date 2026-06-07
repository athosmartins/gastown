#!/usr/bin/env python3
"""Pilot in-flight bead zombie reclaim guard (ga-se62o, ga-7m191).

Detects beads stranded in story:in-flight whose builder DIED / never engaged /
got churned by a controller restart, and reclaims them so the Pilot can
re-dispatch. This is the Pilot-side analog of quality-gate-guard.sh Vector A.

ga-7m191 (board-honesty): the guard now keys on story:in-flight ALONE and
treats a bead parked under an always-on COORDINATOR session (mayor/deacon) as
NOT having a live owning builder. Previously two failure modes left phantom
in-flight beads permanently un-reclaimable: (1) the query required BOTH
story:in-flight AND pilot:dispatched, so a bead that lost pilot:dispatched was
invisible; (2) a bead reassigned to / parked under the always-live Mayor looked
'owned by a healthy session' forever. Either lied about throughput on the
Kanban.

Poll loop (~5min). Silence = healthy. Emits on action only:
  [INFLIGHT-RECLAIM] [RECLAIMED]   stripped story:in-flight + pilot:dispatched from <id>
  [INFLIGHT-RECLAIM] [RECLAIM-FAILED] label ops failed; bead may need manual cleanup
  [INFLIGHT-RECLAIM] [ESCALATED]   reclaim cap hit — needs human/Mayor review
  [INFLIGHT-RECLAIM] [STARTUP]     initial state snapshot

Safety invariants (CRITICAL — actuates on real work beads):
  - Operates on beads carrying story:in-flight (pilot:dispatched NOT required;
    it can be lost or stripped by a partial prior reclaim). Epics excluded.
  - A bead assigned to an always-on coordinator (mayor/deacon) is treated as
    PARKED, not owned by a live builder — reclaimable on the usual rails.
  - Hysteresis: bead must be CONTINUOUSLY stranded >= RECLAIM_TTL (25min)
    before any action is taken (transient blips ignored).
  - NEVER reclaims gate:needs-human beads (parked deliberately by a human/gate).
  - NEVER reclaims beads with a live owning session (assignee matches active session).
    Checks session.id, .name, .session_name, .alias, .agent_name because bd typically
    assigns session_name (e.g. 'dog-gawispy8c0mr') not session.name ('gastown.dog-3').
  - NEVER reclaims beads with recent branch progress (commit within RECLAIM_TTL).
    Checks fix/<bead-id>* and feature/<bead-id>* in both HQ and WA repos.
  - NEVER reclaims beads with a gate-status:dispatching|queued|claimed marker
    (bead is actively being processed by the gate pipeline).
  - Thrash cap: after MAX_RECLAIMS (3) reclaims, escalates instead of looping.
  - Fails safe on bad/empty/unparseable data — skips the entire cycle.
  - Only modifies pilot/lifecycle labels + assignee. Never deletes beads,
    never touches gate markers or verdicts.
"""
import json
import os
import subprocess
import time

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

RECLAIM_TTL = 1500       # 25min: branch "recent" threshold AND hysteresis window
MAX_RECLAIMS = 3         # escalate instead of looping after this many reclaims
POLL_SEC = 300           # 5min poll interval
REALERT_SEC = 900        # 15min re-alert cadence for escalated beads

STATE_FILE = ".gc/state/inflight-reclaim-guard.json"
GC_CITY = "/Users/athos/gt/.gascity-gastown-hq"

# Repos to search for builder branches
REPOS = [
    "/Users/athos/gt",
    "/Users/athos/gt/whatsapp_automation",
]

# Session states that indicate a live active builder
LIVE_STATES = {"active", "awake"}

# Always-on COORDINATOR roles (ga-7m191). A story bead whose assignee names one
# of these is PARKED, not being actively built — these sessions never die, so
# without this exclusion a dead-builder bead parked under the Mayor would look
# 'owned by a healthy session' forever and never get reclaimed. Substring,
# case-insensitive match against assignee/session identifiers.
COORDINATOR_MARKERS = ("mayor", "deacon")

# Gate pipeline states that mean a bead is actively being processed
# (includes queued + claimed as belt-and-suspenders beyond what the spec names)
GATE_ACTIVE_LABELS = {
    "gate-status:dispatching",
    "gate-status:queued",
    "gate-status:claimed",
}


# ---------------------------------------------------------------------------
# Notify helper (matches gate-health-monitor.py / crew-session-dedup.py exactly)
# ---------------------------------------------------------------------------

def emit(msg):
    """Print alert line and fire notify CLI (best-effort, never crash on failure)."""
    print(msg, flush=True)
    try:
        subprocess.run(
            ["/Users/athos/.local/bin/notify", "-t", "Inflight reclaim", "-p", "4", msg],
            timeout=10, capture_output=True)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Pure decision function (unit-testable, zero side effects)
# ---------------------------------------------------------------------------

def reclaim_decision(has_live_session, has_recent_branch, seconds_stranded,
                     reclaim_count, has_needs_human, has_dispatching_marker):
    """Compute the reclaim action for one stranded in-flight bead.

    Args:
        has_live_session:        True if assignee matches an active/awake session
        has_recent_branch:       True if any origin branch for bead has commit within TTL
        seconds_stranded:        seconds since first seen as stranded (0.0 if not tracked yet)
        reclaim_count:           current pilot:reclaim-count:N from bead labels (int)
        has_needs_human:         True if bead carries gate:needs-human label
        has_dispatching_marker:  True if quality-gate-marker with active gate state exists

    Returns:
        action in {"reclaim", "escalate", "noop"}
    """
    # Safety guards: never touch deliberately-parked or in-progress beads
    if has_needs_human:
        return "noop"
    if has_dispatching_marker:
        return "noop"
    if has_live_session:
        return "noop"
    if has_recent_branch:
        return "noop"
    # Bead is stranded — enforce hysteresis (wait for continuous stranding)
    if seconds_stranded < RECLAIM_TTL:
        return "noop"
    # Stranded past TTL — check thrash cap
    if reclaim_count >= MAX_RECLAIMS:
        return "escalate"
    return "reclaim"


# ---------------------------------------------------------------------------
# State persistence
# ---------------------------------------------------------------------------

def load_state():
    """Load guard state from file. Returns empty dict on any error."""
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(state):
    """Persist guard state. Best-effort; never crashes the loop."""
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w") as f:
            json.dump(state, f, indent=2)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] state save failed: {exc}", flush=True)


# ---------------------------------------------------------------------------
# Data queries (all fail-safe: return None on error → caller skips cycle)
# ---------------------------------------------------------------------------

def list_inflight_beads():
    """List open beads carrying story:in-flight.

    ga-7m191: keys on story:in-flight ALONE (NOT story:in-flight AND
    pilot:dispatched). pilot:dispatched can be absent — never set, or stripped
    by a partial prior reclaim — leaving a phantom in-flight bead the old
    both-labels query could never see. The reclaim rails (no live builder + no
    recent branch + stranded past TTL) are what gate actuation, not the
    pilot:dispatched label.
    Returns list of bead dicts, or None on any error (fail-safe).
    """
    try:
        result = subprocess.run(
            ["bd", "list",
             "--label", "story:in-flight",
             "--json"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return None
        data = json.loads(result.stdout)
        if not isinstance(data, list):
            return None
        return data
    except Exception:
        return None


def list_active_sessions():
    """Return all non-closed sessions from gc session list.
    Returns list of session dicts, or None on any error (fail-safe).
    """
    try:
        result = subprocess.run(
            ["gc", "session", "list", "--json"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return None
        stdout = result.stdout.strip()
        # gc can emit WARN lines before the JSON object — find the first '{'
        idx = stdout.find("{")
        if idx < 0:
            return None
        if idx > 0:
            stdout = stdout[idx:]
        data = json.loads(stdout)
        sessions = data.get("sessions", [])
        return [s for s in sessions if not s.get("closed", False)]
    except Exception:
        return None


def list_gate_active_source_beads():
    """Return set of source-bead IDs that currently have an active gate marker
    (gate-status:dispatching, queued, or claimed).

    Returns a frozenset, or None on error (fail-safe: caller treats None as unknown
    and skips the cycle rather than risking a false reclaim).
    """
    active_source_beads = set()
    for gate_lbl in ("gate-status:dispatching", "gate-status:queued", "gate-status:claimed"):
        try:
            result = subprocess.run(
                ["bd", "list",
                 "--label", "type:quality-gate-marker",
                 "--label", gate_lbl,
                 "--json"],
                capture_output=True, text=True, timeout=20)
            if result.returncode != 0:
                # No beads matching this label combo is not an error
                continue
            if not result.stdout.strip():
                continue
            data = json.loads(result.stdout)
            if not isinstance(data, list):
                return None  # Unparseable → fail-safe
            for m in data:
                for lbl in m.get("labels", []):
                    if lbl.startswith("source-bead:"):
                        active_source_beads.add(lbl[len("source-bead:"):])
        except Exception:
            return None  # Any exception → fail-safe
    return frozenset(active_source_beads)


# ---------------------------------------------------------------------------
# Liveness helpers
# ---------------------------------------------------------------------------

def is_coordinator(identity):
    """Return True if an assignee/session identity names an always-on
    coordinator (mayor/deacon) rather than a builder. Substring, case-insensitive.

    ga-7m191: a story bead parked under a coordinator is NOT being actively
    built — those sessions never die, so they must never count as a live owner.
    """
    ident = (identity or "").lower()
    return any(marker in ident for marker in COORDINATOR_MARKERS)


def session_is_live(assignee, sessions):
    """Return True if assignee matches a live (active/awake) BUILDER session.

    Checks session.id, .name, .session_name, .alias, .agent_name because
    bd typically sets the assignee to session_name (e.g. 'dog-gawispy8c0mr')
    not to the human-readable session.name ('gastown.dog-3'). Checking only
    id + name (as quality-gate-guard.sh does) would miss this case and produce
    a false-positive stranded detection on a live dog/builder session.

    ga-7m191: an assignee naming an always-on COORDINATOR (mayor/deacon), or a
    match against a coordinator session, is a PARKED bead — NOT a live builder.
    Returning True there left dead-builder beads parked under the Mayor
    permanently un-reclaimable. Such matches now return False so the bead is
    reclaimable on the usual rails (no recent branch + stranded past TTL).

    CORRECTNESS-CRITICAL: this is the primary guard against reclaiming
    a bead that a live builder actually owns.
    """
    if not assignee or assignee == "null":
        return False
    # An assignee naming a coordinator role is parked, never a live builder.
    if is_coordinator(assignee):
        return False
    for s in sessions:
        state = s.get("state", "").lower()
        if state not in LIVE_STATES:
            continue
        identifiers = {
            s.get("id", ""),
            s.get("name", ""),
            s.get("session_name", ""),
            s.get("alias", ""),
            s.get("agent_name", ""),
        }
        identifiers.discard("")
        if assignee in identifiers:
            # Matched a live session — but a coordinator session is never an
            # owning builder, even if the assignee string itself is opaque.
            if any(is_coordinator(idv) for idv in identifiers):
                return False
            return True
    return False


def get_branch_recent(bead_id):
    """Return True if any fix/<bead-id>* or feature/<bead-id>* branch on origin
    has a commit within RECLAIM_TTL seconds of now.

    Fetches both HQ and WA repos (fail-safe: repo error → skip that repo).
    Returns False if no matching branch, or all branches are stale / all fetches fail.

    CORRECTNESS-CRITICAL: this is the secondary guard against reclaiming beads
    where a builder is actively pushing but their session has a different name
    than the bead's assignee field.
    """
    now = time.time()
    for repo in REPOS:
        # Fetch to update remote-tracking refs (fail-safe: skip repo on failure)
        try:
            subprocess.run(
                ["git", "-C", repo, "fetch", "origin", "--prune", "--quiet"],
                capture_output=True, timeout=30)
        except Exception:
            continue  # skip this repo on fetch failure

        for prefix in ("fix", "feature"):
            pat = f"refs/remotes/origin/{prefix}/{bead_id}*"
            try:
                r = subprocess.run(
                    ["git", "-C", repo, "for-each-ref",
                     "--sort=-committerdate",
                     "--format=%(committerdate:unix)",
                     pat],
                    capture_output=True, text=True, timeout=10)
                if r.returncode != 0 or not r.stdout.strip():
                    continue
                for line in r.stdout.strip().splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        ts = float(line)
                        if now - ts < RECLAIM_TTL:
                            return True
                    except ValueError:
                        continue
            except Exception:
                continue
    return False


def parse_reclaim_count(labels):
    """Extract pilot:reclaim-count:N from labels. Returns int (0 if absent or invalid)."""
    for lbl in labels:
        if lbl.startswith("pilot:reclaim-count:"):
            try:
                return int(lbl[len("pilot:reclaim-count:"):])
            except ValueError:
                pass
    return 0


# ---------------------------------------------------------------------------
# Actuation helpers (label + assignee ops on real beads — CONSERVATIVE)
# ---------------------------------------------------------------------------

def do_reclaim(bead_id, bead_title, reclaim_count, idle_min, labels):
    """Strip story:in-flight (+pilot:dispatched if present), clear assignee,
    bump reclaim label.
    Returns True if all bd ops succeeded, False if any failed (still best-effort).
    """
    new_count = reclaim_count + 1
    ok = True

    # 1. Remove lifecycle labels that are actually present. ga-7m191:
    #    pilot:dispatched may be absent (stripped by a partial prior reclaim);
    #    skipping it avoids a spurious RECLAIM-FAILED on a successful reclaim.
    for lbl in ("story:in-flight", "pilot:dispatched"):
        if lbl not in labels:
            continue
        try:
            r = subprocess.run(
                ["bd", "label", "remove", bead_id, lbl, "-q"],
                capture_output=True, text=True, timeout=15)
            if r.returncode != 0:
                print(f"[INFLIGHT-RECLAIM] warn: remove {lbl} from {bead_id} rc={r.returncode}",
                      flush=True)
                ok = False
        except Exception as exc:
            print(f"[INFLIGHT-RECLAIM] warn: remove {lbl} from {bead_id}: {exc}", flush=True)
            ok = False

    # 2. Clear assignee so Pilot can claim it fresh
    try:
        subprocess.run(
            ["bd", "assign", bead_id, ""],
            capture_output=True, text=True, timeout=15)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: clear assignee {bead_id}: {exc}", flush=True)
        # Non-fatal: Pilot can still re-dispatch without assignee being empty

    # 3. Bump reclaim count label (remove old, add new)
    if reclaim_count > 0:
        try:
            subprocess.run(
                ["bd", "label", "remove", bead_id, f"pilot:reclaim-count:{reclaim_count}", "-q"],
                capture_output=True, text=True, timeout=15)
        except Exception:
            pass  # old label may already be missing; ignore
    try:
        subprocess.run(
            ["bd", "label", "add", bead_id, f"pilot:reclaim-count:{new_count}", "-q"],
            capture_output=True, text=True, timeout=15)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: set reclaim-count label {bead_id}: {exc}", flush=True)

    # 4. Audit comment
    cleared = " + ".join(l for l in ("story:in-flight", "pilot:dispatched")
                         if l in labels) or "story:in-flight"
    try:
        subprocess.run(
            ["bd", "comment", bead_id,
             f"inflight-reclaim-guard (ga-se62o): reclaimed — no live builder and "
             f"no recent branch progress for {idle_min:.0f}min "
             f"(> {RECLAIM_TTL//60}min TTL). {cleared} "
             f"cleared; assignee unset. Pilot will re-dispatch. "
             f"(reclaim {new_count}/{MAX_RECLAIMS})"],
            capture_output=True, text=True, timeout=15)
    except Exception:
        pass  # comment failure is non-fatal

    return ok


def do_escalate(bead_id, bead_title, reclaim_count, idle_min, labels):
    """Strip in-flight labels and emit loud ntfy — thrash cap exhausted.
    Called only on first escalation (labels stripped → bead leaves query results).
    """
    # Strip present labels so bead leaves the in-flight query and we don't loop
    for lbl in ("story:in-flight", "pilot:dispatched"):
        if lbl not in labels:
            continue
        try:
            subprocess.run(
                ["bd", "label", "remove", bead_id, lbl, "-q"],
                capture_output=True, text=True, timeout=15)
        except Exception:
            pass

    try:
        subprocess.run(
            ["bd", "assign", bead_id, ""],
            capture_output=True, text=True, timeout=15)
    except Exception:
        pass

    try:
        subprocess.run(
            ["bd", "comment", bead_id,
             f"inflight-reclaim-guard (ga-se62o): ESCALATED — reclaim cap "
             f"({MAX_RECLAIMS}) exhausted. Bead has been stranded for "
             f"{idle_min:.0f}min with no live builder or branch progress. "
             f"story:in-flight + pilot:dispatched cleared. "
             f"Human/Mayor intervention required to investigate and re-queue."],
            capture_output=True, text=True, timeout=15)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Main poll cycle
# ---------------------------------------------------------------------------

def run_cycle(state, escalated_alerted):
    """Single poll cycle. Mutates state and escalated_alerted in place.
    Returns (inflight_count, stranded_count) for diagnostics.
    """
    now = time.time()

    # --- Query in-flight beads (fail-safe: skip cycle on error) ---
    beads = list_inflight_beads()
    if beads is None:
        print("[INFLIGHT-RECLAIM] bd list failed — skipping cycle", flush=True)
        return 0, 0

    # --- Query live sessions (fail-safe: skip cycle on error) ---
    sessions = list_active_sessions()
    if sessions is None:
        print("[INFLIGHT-RECLAIM] session list failed — skipping cycle", flush=True)
        return len(beads), 0

    # --- Query gate active markers (fail-safe: None → skip cycle entirely) ---
    gate_active_beads = list_gate_active_source_beads()
    if gate_active_beads is None:
        print("[INFLIGHT-RECLAIM] gate-marker query failed — skipping cycle (safe)", flush=True)
        return len(beads), 0

    stranded_count = 0
    active_bead_ids = set()

    for bead in beads:
        bead_id = bead.get("id", "")
        if not bead_id:
            continue
        # Never actuate on epics — they are containers, never dispatched builds.
        if (bead.get("issue_type") or bead.get("type") or "") == "epic":
            continue
        active_bead_ids.add(bead_id)

        labels = bead.get("labels", [])
        assignee = bead.get("assignee") or ""
        title = bead.get("title", "")[:60]

        # --- Safety flags ---
        has_needs_human      = "gate:needs-human" in labels
        has_dispatching_marker = bead_id in gate_active_beads
        has_live_session     = session_is_live(assignee, sessions)

        # Branch check is potentially slow (git fetch); only run when needed
        has_recent_branch = False
        if not has_live_session and not has_needs_human and not has_dispatching_marker:
            has_recent_branch = get_branch_recent(bead_id)

        # --- Update stranded timestamp in state ---
        bead_state = state.setdefault(bead_id, {})
        is_currently_stranded = (
            not has_live_session and
            not has_recent_branch and
            not has_needs_human and
            not has_dispatching_marker
        )

        if is_currently_stranded:
            if "first_seen_stranded" not in bead_state:
                bead_state["first_seen_stranded"] = now
                print(f"[INFLIGHT-RECLAIM] started stranded clock: bead={bead_id} "
                      f"assignee={assignee!r}", flush=True)
            seconds_stranded = now - bead_state["first_seen_stranded"]
            stranded_count += 1
        else:
            # Live builder or recent progress → reset stranded clock
            if "first_seen_stranded" in bead_state:
                bead_state.pop("first_seen_stranded", None)
                print(f"[INFLIGHT-RECLAIM] reset stranded clock: bead={bead_id} "
                      f"live_session={has_live_session} recent_branch={has_recent_branch}",
                      flush=True)
            seconds_stranded = 0.0

        reclaim_count = parse_reclaim_count(labels)

        # --- Pure decision ---
        action = reclaim_decision(
            has_live_session=has_live_session,
            has_recent_branch=has_recent_branch,
            seconds_stranded=seconds_stranded,
            reclaim_count=reclaim_count,
            has_needs_human=has_needs_human,
            has_dispatching_marker=has_dispatching_marker,
        )

        idle_min = seconds_stranded / 60.0

        if action == "reclaim":
            ok = do_reclaim(bead_id, title, reclaim_count, idle_min, labels)
            status = "RECLAIMED" if ok else "RECLAIM-FAILED"
            emit(
                f"[INFLIGHT-RECLAIM] [{status}] bead={bead_id} "
                f"idle={idle_min:.0f}min no_live_session no_recent_branch "
                f"reclaim={reclaim_count + 1}/{MAX_RECLAIMS} title={title!r}"
            )
            # Reset state clock — bead left in-flight (or will be re-tracked if partially failed)
            state.pop(bead_id, None)

        elif action == "escalate":
            # Rate-limit to avoid repeat ntfy on the same bead within REALERT_SEC
            last_alert = escalated_alerted.get(bead_id, 0)
            if now - last_alert > REALERT_SEC:
                do_escalate(bead_id, title, reclaim_count, idle_min, labels)
                emit(
                    f"[INFLIGHT-RECLAIM] [ESCALATED] bead={bead_id} "
                    f"reclaimed {reclaim_count}x idle={idle_min:.0f}min — "
                    f"needs human/Mayor intervention title={title!r}"
                )
                escalated_alerted[bead_id] = now
            # Labels stripped → bead will leave query; remove state
            state.pop(bead_id, None)

        # action == "noop" → silence

    # Prune state entries for beads no longer in the in-flight+dispatched query
    gone = set(state.keys()) - active_bead_ids
    for bid in gone:
        state.pop(bid, None)
        escalated_alerted.pop(bid, None)

    return len(beads), stranded_count


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    emit(
        f"[INFLIGHT-RECLAIM] [STARTUP] reclaim_ttl={RECLAIM_TTL}s ({RECLAIM_TTL // 60}min) "
        f"max_reclaims={MAX_RECLAIMS} poll={POLL_SEC}s"
    )

    state = load_state()
    escalated_alerted = {}  # bead_id -> last escalation alert timestamp

    # Initial snapshot for diagnostics
    beads   = list_inflight_beads()
    sessions = list_active_sessions()
    bead_count    = len(beads)    if beads    is not None else -1
    session_count = len(sessions) if sessions is not None else -1
    print(
        f"[INFLIGHT-RECLAIM] [STARTUP] inflight={bead_count} "
        f"live_sessions={session_count} state_entries={len(state)}",
        flush=True)

    while True:
        try:
            inflight_count, stranded_count = run_cycle(state, escalated_alerted)
            save_state(state)
            # Per-cycle summary (goes to launchd .out log — low noise, high observability)
            print(
                f"[INFLIGHT-RECLAIM] cycle: inflight={inflight_count} "
                f"stranded={stranded_count}",
                flush=True)
        except Exception as exc:
            # Never crash the guard loop
            print(f"[INFLIGHT-RECLAIM] cycle exception: {exc}", flush=True)
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    main()
