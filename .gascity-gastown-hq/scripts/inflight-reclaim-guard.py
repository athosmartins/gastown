#!/usr/bin/env python3
"""Pilot in-flight bead zombie reclaim guard (ga-se62o, ga-7m191, ga-vw26y, ga-64usm).

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

ga-vw26y (status blind spot): `bd list` defaults to OPEN-only status. That hid
a whole stranding class — a story stuck in status:in_progress that lost its
story:in-flight label. It was invisible to BOTH this guard's label query AND to
the Pilot's open-only re-dispatch query, so it stranded forever (3 stories sat
16-19h post-outage). Two changes close it: (1) the queries now explicitly
include in_progress, and a scoped in_progress sweep (list_stranded_inprogress_
beads) catches Pilot stories that lost story:in-flight but kept a durable Pilot
marker (pilot:dispatched / pilot:reclaim-count); (2) do_reclaim now RESETS
status to open, so a reclaimed bead is actually re-dispatchable (clearing the
labels/assignee alone left it in_progress → still invisible to the Pilot).

ga-64usm (alive != working): the guard used "is the assignee's session alive?"
as a proxy for "is a builder still working it?" — but a credit-limited or hung
session stays state=active in `gc session list` while producing zero output, so
session_is_live() returned True forever and the bead was NEVER reclaimable (one
sat story:in-flight for 3h46 on 2026-06-09). The fix: a matched live session is
treated as a HEALTHY owner only if it shows a fresh progress signal — its
last_active is within STALE_ACTIVITY_TTL (30min), OR the bead itself had a bd
update within that window (workers should bd-update during long work). A live
session that is stale on BOTH is a frozen zombie and falls through to the normal
reclaim rails (no recent branch + continuous stranding past RECLAIM_TTL). The
check is conservative: a missing/unparseable last_active keeps the pre-fix
"treat as live" behavior — we never reclaim on the strength of an absent field.

Poll loop (~5min). Silence = healthy. Emits on action only:
  [INFLIGHT-RECLAIM] [RECLAIMED]   cleared in-flight labels + reset <id> to open
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
  - ga-vw26y: the in_progress sweep is SCOPED to Pilot stories — a bead must
    carry a durable Pilot marker (pilot:dispatched or pilot:reclaim-count) and
    NO terminal/parked label (story:done, gate:passed, …) to qualify. Crew,
    gate, and dog task beads carry no Pilot marker → never touched.
  - Thrash cap: after MAX_RECLAIMS (3) reclaims, escalation marks the bead
    gate:needs-human and RETAINS story:in-flight (ga-6ow4v) — it does NOT
    re-clear, which would loop the bead through dispatch↔reclaim forever. The
    has_needs_human rail then parks it quietly until a human re-queues it.
  - Fails safe on bad/empty/unparseable data — skips the entire cycle.
  - Only modifies pilot/lifecycle labels (+ gate:needs-human on escalation) and
    assignee. Never deletes beads, never touches gate markers or verdicts.
"""
import json
import os
import subprocess
import time
import sys as _sys
_sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from gc_ledger import gc_ledger_append as _irg_ledger
import datetime as _irg_datetime

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

RECLAIM_TTL = 1500       # 25min: branch "recent" threshold AND hysteresis window
STALE_ACTIVITY_TTL = 1800  # 30min (ga-64usm): a matched live session whose
                         # last_active is older than this — AND with no bd update
                         # on the bead within the same window — is a frozen /
                         # credit-limited zombie, NOT a live owner. alive != working.
MAX_RECLAIMS = 3         # escalate instead of looping after this many reclaims
POLL_SEC = int(os.environ.get("RECLAIM_POLL_SEC", "600"))  # default 10min; was 5min
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

# ga-vw26y: durable Pilot-story markers. The in_progress sweep keeps ONLY beads
# carrying one of these (or a pilot:reclaim-count:N label — see
# is_reclaimable_inprogress_story) so it can never touch a crew/gate/dog task
# bead that merely happens to be in_progress. pilot:dispatched survives the
# documented failure mode where story:in-flight is stripped (crash/race); the
# Pilot stamps both on every dispatch.
PILOT_STORY_MARKERS = ("pilot:dispatched", "story:in-flight")

# ga-vw26y: terminal / deliberately-parked states. A bead carrying ANY of these
# is NOT a reclaimable stranded story — it is done, merged, human-parked,
# engine-queued, or has a claim already in progress. Mirrors the pilot-dispatcher's
# own exclude set so the guard never resurrects completed or intentionally-held work.
TERMINAL_PARKED_LABELS = frozenset({
    "story:done",
    "gate:passed",
    "gate:superseded",
    "gate:needs-human",
    "needs:engine-window",
    "pilot:dispatching",
})


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

    ga-vw26y: the status filter is EXPLICIT (open,in_progress). `bd list`
    defaults to open-only, so without this an in_progress story:in-flight bead
    (dispatched, builder set in_progress, then died) was invisible to the guard
    that is supposed to reclaim it.
    Returns list of bead dicts, or None on any error (fail-safe).
    """
    try:
        result = subprocess.run(
            ["bd", "list",
             "--label", "story:in-flight",
             "--status", "open,in_progress",
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


def is_reclaimable_inprogress_story(labels):
    """Pure predicate: True if an in_progress bead is a Pilot story stranded
    WITHOUT its story:in-flight label (the ga-vw26y blind spot), and is thus a
    candidate for the in_progress sweep.

    Requires a durable Pilot marker — pilot:dispatched, story:in-flight, or any
    pilot:reclaim-count:N (the last proves the guard itself already touched this
    bead, so it is unambiguously a Pilot story whose in-flight label was since
    stripped). Rejects any bead carrying a terminal/parked label so completed or
    intentionally-held work is never resurrected.

    SCOPE-CRITICAL: this is the only thing standing between the in_progress
    sweep and arbitrary in_progress work (crew, gate, dog task beads). Those
    carry NO Pilot marker → this returns False → they are never actuated on.
    """
    has_marker = (
        any(lbl in PILOT_STORY_MARKERS for lbl in labels)
        or any(lbl.startswith("pilot:reclaim-count:") for lbl in labels)
    )
    if not has_marker:
        return False
    if any(lbl in TERMINAL_PARKED_LABELS for lbl in labels):
        return False
    return True


def list_stranded_inprogress_beads():
    """List in_progress Pilot stories stranded WITHOUT a story:in-flight label.

    ga-vw26y: `bd list` defaults to open-only, so a story stuck in
    status:in_progress that lost story:in-flight is invisible to BOTH
    list_inflight_beads() AND the Pilot's open-only re-dispatch query — it
    strands forever (3 stories sat 16-19h post-outage). This sweep scans
    in_progress explicitly and keeps only Pilot-marked beads
    (is_reclaimable_inprogress_story), so it never touches crew, gate, or dog
    task beads. The reclaim rails (no live builder + no recent branch + stranded
    past TTL) still gate every actuation.
    Returns list of bead dicts, or None on any error (fail-safe).
    """
    try:
        result = subprocess.run(
            ["bd", "list",
             "--status", "in_progress",
             "--json"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return None
        data = json.loads(result.stdout)
        if not isinstance(data, list):
            return None
        return [b for b in data
                if is_reclaimable_inprogress_story(b.get("labels", []))]
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


def list_suspended_agents():
    """Return the set of agent NAMES that are deliberately SUSPENDED
    (gc agent list --json → agents[].suspended == true).

    A suspended crew's in-flight beads must NOT be reclaimed. Suspension is a
    DELIBERATE stop (the human paused the crew), not a crash — the work should WAIT
    for the crew to resume, not re-pool into the Pilot's ctx:ready queue where another
    crew picks it up and (correctly) declines it. That re-pool churn is the wa-wbub /
    digo-wa bug: digo-wa was suspended, its in-flight beads lost their owner and got
    re-dispatched repeatedly.

    The set includes BOTH the full agent name ("digo-wa") and its short form with the
    trailing -<rig> suffix stripped ("digo"), because beads are assigned by either
    form. Returns an EMPTY set on any error (fail-open: a failed probe must never
    cause a bead to be held — that would re-introduce the un-reclaimable-zombie class
    this guard exists to kill).
    """
    try:
        result = subprocess.run(
            ["gc", "agent", "list", "--json"],
            capture_output=True, text=True, timeout=20)
        out = (result.stdout or "").strip()
        idx = out.find("{")
        if result.returncode != 0 or idx < 0:
            return set()
        data = json.loads(out[idx:])
        names = {
            a.get("name") for a in data.get("agents", [])
            if isinstance(a, dict) and a.get("suspended") and a.get("name")
        }
        expanded = set(names)
        for nm in names:
            # short form: drop a single trailing -<rig> suffix (digo-wa -> digo).
            if "-" in nm:
                expanded.add(nm.rsplit("-", 1)[0])
        return expanded
    except Exception:
        return set()


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


def parse_iso_epoch(ts):
    """Parse an ISO-8601 timestamp to epoch seconds. Returns None on any failure.

    Handles both timestamp dialects this guard sees: `gc session list` emits a
    local offset form ('2026-06-10T11:33:28-03:00') and `bd` emits a bare-Z UTC
    form ('2026-06-10T14:33:28Z'). Python 3.9's datetime.fromisoformat() accepts
    the offset form but REJECTS a trailing 'Z', so normalize it to '+00:00'.
    """
    if not ts or not isinstance(ts, str):
        return None
    s = ts.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        from datetime import datetime
        return datetime.fromisoformat(s).timestamp()
    except Exception:
        return None


def session_activity_age(session, now):
    """Seconds since a session's last_active timestamp. None if missing/unparseable.

    A None return means "unknown" — callers must treat it conservatively (do not
    infer staleness from a missing timestamp).
    """
    age = parse_iso_epoch(session.get("last_active", ""))
    if age is None:
        return None
    return max(0.0, now - age)


def session_owner_is_healthy(matched_live, activity_age, bead_update_age):
    """Pure predicate (ga-64usm): given that the bead's assignee matched a
    live-state (active/awake) BUILDER session, decide whether that constitutes a
    HEALTHY live owner (block reclaim) or a frozen/credit-limited zombie
    (allow reclaim).

    Args:
        matched_live:     True if assignee matched a session in LIVE_STATES
        activity_age:     seconds since session.last_active, or None if unknown
        bead_update_age:  seconds since the bead's own updated_at, or None if unknown

    A matched live session is a healthy owner UNLESS it is *provably* frozen:
    its terminal activity is older than STALE_ACTIVITY_TTL AND the bead itself
    has had no bd update within STALE_ACTIVITY_TTL. Either fresh signal — recent
    terminal output OR recent bead progress — keeps it classified healthy.

    Conservative by construction: when the activity timestamp is unknown we
    CANNOT prove staleness, so we keep the pre-fix behavior (treat as live) and
    never reclaim on the strength of a missing field. The bug this fixes is
    UNDER-reclaiming (a frozen session was live forever); we must not over-
    correct into reclaiming a builder that is merely quiet.
    """
    if not matched_live:
        return False
    # Can't prove staleness without an activity timestamp → stay conservative.
    if activity_age is None:
        return True
    # Recent terminal activity → genuinely working builder.
    if activity_age <= STALE_ACTIVITY_TTL:
        return True
    # Activity is stale. A recent bd update on the bead is the secondary progress
    # signal (workers should bd-update during long work — ga-64usm secondary).
    if bead_update_age is not None and bead_update_age <= STALE_ACTIVITY_TTL:
        return True
    # Frozen: stale terminal activity AND no recent bead progress → zombie.
    return False


def session_is_live(assignee, sessions, now=None, bead_update_age=None):
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

    ga-64usm: alive != working. A credit-limited / hung builder keeps
    state=active but produces no output → its last_active goes stale. A matched
    live session therefore counts as a live owner only if session_owner_is_healthy
    confirms a fresh progress signal (recent last_active, OR a recent bd update
    on the bead — passed via bead_update_age). `now` defaults to time.time();
    callers in tests inject a fixed reference.

    CORRECTNESS-CRITICAL: this is the primary guard against reclaiming
    a bead that a live builder actually owns.
    """
    if not assignee or assignee == "null":
        return False
    # An assignee naming a coordinator role is parked, never a live builder.
    if is_coordinator(assignee):
        return False
    if now is None:
        now = time.time()
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
            # ga-64usm: a matched live-state session is only a HEALTHY owner if
            # it isn't a frozen/credit-limited zombie. Gate on activity freshness
            # (+ recent bead progress as a secondary signal).
            activity_age = session_activity_age(s, now)
            return session_owner_is_healthy(True, activity_age, bead_update_age)
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

    # 2b. Reset status to open so the Pilot can actually re-dispatch (ga-vw26y).
    #     bd list — and the Pilot's re-dispatch query — default to open-only. A
    #     bead reclaimed but left in_progress is invisible to re-dispatch and
    #     simply strands again (the exact loop this guard exists to break).
    #     Idempotent: a harmless no-op on an already-open bead. Non-fatal: if it
    #     fails, the labels/assignee are already cleared and the next cycle
    #     re-finds the bead (still in_progress + pilot:reclaim-count) and retries.
    try:
        subprocess.run(
            ["bd", "update", bead_id, "--status", "open"],
            capture_output=True, text=True, timeout=15)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: reset status open {bead_id}: {exc}", flush=True)

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

    # 3b. ga-l5ud0 FIX #2: re-loop cooldown — stamp pilot:held + pilot:held-until:<now+1h>
    #     on the 2nd+ reclaim (reclaim_count >= 1) to prevent the Pilot from immediately
    #     re-dispatching to the same crew pool before the underlying routing issue is resolved.
    #     ROOT: a bead repeatedly dispatched→abandoned (no branch, crew declines or is off-domain)
    #     re-enters the open pool on reclaim and Pilot picks the same crew again on the next
    #     3-min sweep — the re-stamp loop. imp19's pilot:held mechanism exists in the Pilot's
    #     domain-route-guard (for the DEFER path), but is never stamped after a reclaim.
    #     Stamping it here closes the gap: the Pilot's _filter_candidates honors pilot:held,
    #     so the bead is invisible to auto-dispatch for 1h, giving a Mayor sweep time to
    #     triage and re-route or assign an explicit owner.
    #     THRESHOLD: only on reclaim_count >= 1 (2nd+ reclaim without progress). A first-time
    #     reclaim may be a transient crew churn (config drift, restart); we don't hold on that.
    #     FAIL-OPEN: if the bd calls fail, the hold is not stamped — identical to pre-fix
    #     behaviour (Pilot may re-dispatch, which is acceptable on a first-time transient).
    #     Env-gate: RECLAIM_RELOOP_HOLD_SECS (default 3600 = 1h). Set 0 to disable.
    _reloop_hold = int(os.environ.get("RECLAIM_RELOOP_HOLD_SECS", "3600"))
    if reclaim_count >= 1 and _reloop_hold > 0:
        _held_until = int(time.time()) + _reloop_hold
        try:
            subprocess.run(
                ["bd", "label", "add", bead_id, "pilot:held", "-q"],
                capture_output=True, text=True, timeout=15)
            subprocess.run(
                ["bd", "label", "add", bead_id, f"pilot:held-until:{_held_until}", "-q"],
                capture_output=True, text=True, timeout=15)
            print(f"[INFLIGHT-RECLAIM] ga-l5ud0: {bead_id} stamped pilot:held (reloop-cooldown, reclaim {new_count}, hold {_reloop_hold}s until {_held_until})",
                  flush=True)
        except Exception as _exc:
            print(f"[INFLIGHT-RECLAIM] warn: could not stamp pilot:held cooldown on {bead_id}: {_exc}",
                  flush=True)

    # 4. Audit comment
    cleared = " + ".join(l for l in ("story:in-flight", "pilot:dispatched")
                         if l in labels) or "(no in-flight label)"
    _hold_note = (f" pilot:held stamped for {_reloop_hold//60}min cooldown to prevent re-loop (reclaim {new_count-1}+)."
                  if reclaim_count >= 1 and _reloop_hold > 0 else "")
    try:
        subprocess.run(
            ["bd", "comment", bead_id,
             f"inflight-reclaim-guard (ga-se62o): reclaimed — no live builder and "
             f"no recent branch progress for {idle_min:.0f}min "
             f"(> {RECLAIM_TTL//60}min TTL). {cleared} "
             f"cleared; assignee unset; status reset to open (ga-vw26y)."
             f"{_hold_note} "
             f"Pilot will re-dispatch. (reclaim {new_count}/{MAX_RECLAIMS})"],
            capture_output=True, text=True, timeout=15)
    except Exception:
        pass  # comment failure is non-fatal

    return ok


def do_escalate(bead_id, bead_title, reclaim_count, idle_min, labels):
    """Mark a permanently-failing bead gate:needs-human — do NOT re-clear it.

    ga-6ow4v: the reclaim cap is exhausted (MAX_RECLAIMS reclaims of the SAME
    bead all failed to produce a healthy builder). Per spec we must NOT clear
    story:in-flight again: clearing lets the Pilot re-dispatch the bead, and
    because the pilot:reclaim-count label persists at the cap, the guard would
    re-escalate on the very next cycle — an endless dispatch↔reclaim loop that
    fires a ntfy every REALERT_SEC and never converges.

    Instead we ADD gate:needs-human and leave story:in-flight + assignee intact.
    This (a) hands the bead to a human/Mayor with an unambiguous flag, and (b)
    trips the guard's OWN has_needs_human safety rail next cycle (reclaim_decision
    returns "noop" for needs-human beads), so the bead parks quietly: no loop,
    no repeat ntfy. One held lane slot is the deliberate tradeoff for a story
    that has proven un-buildable; a human investigates and re-queues it.
    """
    try:
        subprocess.run(
            ["bd", "label", "add", bead_id, "gate:needs-human", "-q"],
            capture_output=True, text=True, timeout=15)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: add gate:needs-human {bead_id}: {exc}",
              flush=True)
    # imp13: sub-label classifies this as a TECHNICAL circuit-breaker park (not a product decision).
    try:
        subprocess.run(
            ["bd", "label", "add", bead_id, "gate:needs-human:technical", "-q"],
            capture_output=True, text=True, timeout=15)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: add gate:needs-human:technical {bead_id}: {exc}",
              flush=True)

    try:
        subprocess.run(
            ["bd", "comment", bead_id,
             f"inflight-reclaim-guard (ga-6ow4v): ESCALATED — reclaim cap "
             f"({MAX_RECLAIMS}) exhausted. Bead stranded {idle_min:.0f}min with no "
             f"live builder or branch progress across {reclaim_count} reclaims. "
             f"Marked gate:needs-human; story:in-flight RETAINED (not re-cleared) "
             f"to avoid a dispatch↔reclaim loop. Human/Mayor must investigate "
             f"and re-queue."],
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

    # --- ga-vw26y: also sweep in_progress Pilot stories that lost story:in-flight
    #     (invisible to the label query above AND to the Pilot's open-only
    #     re-dispatch query). Fail-safe: None → skip cycle. ---
    inprogress = list_stranded_inprogress_beads()
    if inprogress is None:
        print("[INFLIGHT-RECLAIM] in_progress sweep failed — skipping cycle (safe)", flush=True)
        return len(beads), 0

    # Merge + dedup by id (a bead can match both queries).
    merged = {}
    for b in beads + inprogress:
        bid = b.get("id", "")
        if bid:
            merged[bid] = b
    beads = list(merged.values())

    # --- Query live sessions (fail-safe: skip cycle on error) ---
    sessions = list_active_sessions()
    if sessions is None:
        print("[INFLIGHT-RECLAIM] session list failed — skipping cycle", flush=True)
        return len(beads), 0

    # Deliberately-suspended crews: their in-flight beads HOLD (wait for resume), never
    # re-pool. Fail-open: empty set on probe error (current reclaim behavior preserved).
    suspended_agents = list_suspended_agents()

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
        # Owner deliberately SUSPENDED → the bead is parked, not stranded. Holds (waits
        # for the crew to resume) instead of re-pooling — the wa-wbub / digo-wa churn.
        has_suspended_owner  = bool(assignee) and assignee in suspended_agents
        # ga-64usm: the bead's own last-update age is the secondary progress
        # signal that rescues a stale-activity session whose builder is still
        # touching the bead (workers should bd-update during long work).
        bead_update_epoch = parse_iso_epoch(bead.get("updated_at", ""))
        bead_update_age = (now - bead_update_epoch) if bead_update_epoch is not None else None
        has_live_session     = session_is_live(assignee, sessions, now, bead_update_age)

        # Branch check is potentially slow (git fetch); only run when needed
        has_recent_branch = False
        if (not has_live_session and not has_needs_human
                and not has_dispatching_marker and not has_suspended_owner):
            has_recent_branch = get_branch_recent(bead_id)

        # --- Update stranded timestamp in state ---
        bead_state = state.setdefault(bead_id, {})
        is_currently_stranded = (
            not has_live_session and
            not has_recent_branch and
            not has_needs_human and
            not has_dispatching_marker and
            not has_suspended_owner
        )
        if has_suspended_owner:
            if not bead_state.get("suspended_hold_logged"):
                print(f"[INFLIGHT-RECLAIM] HOLD (suspended owner): bead={bead_id} "
                      f"assignee={assignee!r} — not re-pooling; waits for crew resume "
                      f"or human reassign", flush=True)
                bead_state["suspended_hold_logged"] = True
        else:
            bead_state.pop("suspended_hold_logged", None)

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
                _irg_ledger("human-touch", {"ts": _irg_datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "source_daemon": "inflight-reclaim-guard", "stage": "executa", "kind": "technical", "bead_id": bead_id, "reason": f"Reclaim cap exhausted ({reclaim_count}x) — needs human intervention"}, fail_open=True)
                escalated_alerted[bead_id] = now
            # Bead now carries gate:needs-human → next cycle's has_needs_human
            # rail returns "noop". It stays in the in-flight query but parks
            # quietly (no further actuation). Drop its stranded-clock state.
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
