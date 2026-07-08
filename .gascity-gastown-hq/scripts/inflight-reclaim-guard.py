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
    This also protects the ORIGINAL bug/story of a sling-dispatched fix whose live
    builder session is assigned to the SLING bead, not the original's — the
    original's own assignee is legitimately empty the whole time it's being built.
    list_live_sling_source_beads() resolves that back-reference from the sling's
    own title (ga-qfo3; same pattern as the gate-marker back-reference below).
  - NEVER reclaims beads with recent branch progress (commit within RECLAIM_TTL).
    Checks any remote branch whose final segment matches <bead-id> (incl.
    crew/<pool>/<bead-id>, feat/<id>*, fix/<id>*, feature/<id>*, polecat/<id>*)
    in both HQ and WA repos. Fails safe on git error (→ branch-might-exist).
  - NEVER reclaims beads with a gate-status:ready|dispatching|queued|claimed
    marker (bead is actively being processed by the gate pipeline; "ready" is
    the fresh-marker state /gate-done writes before a separate sweep promotes
    it to queued, so it must count as active too — ga-cxzby). This also
    protects the ORIGINAL bug/story of a sling-dispatched fix whose marker is
    keyed on the SLING bead's id, not the original's — list_gate_active_
    source_beads() resolves that back-reference from the sling's own title
    (ga-lrglm).
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
import re
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

# Pool-dead alert configuration (ga-dbibq)
# Emit a [POOL-DEAD] Mayor mail when >= POOL_DEAD_MIN beads from the SAME pool
# are zombie (no branch + dead session + stranded > TTL) for 2 consecutive cycles.
POOL_DEAD_MIN      = int(os.environ.get("IRG_POOL_DEAD_MIN", "3"))
POOL_DEAD_COOLDOWN = int(os.environ.get("IRG_POOL_DEAD_COOLDOWN_SEC", "1800"))

# ga-hkpwv: bare pool-template assignee names (NOT concrete session names like
# 'wa-worker-adhoc-<hash>'). A bead in_progress with one of these assignees is
# a Pilot pool dispatch that never engaged — no Pilot markers (pilot:dispatched /
# story:in-flight) are required to qualify for the in_progress sweep.
EPHEMERAL_POOL_ASSIGNEES = frozenset({"wa-worker"})
# gastown.dog deliberately excluded: dogs are min_active pools assigned a
# concrete session name at dispatch time (not a bare template name), so the
# bare-template zombie detection path does not apply to them.  If future
# dog-pool dispatch changes to use bare template assignees, add "gastown.dog"
# here and verify that dog branches follow crew/gastown.dog/<id> convention.

# ga-hkpwv: minimum stranding window for bare-template pool zombies.
# Longer than RECLAIM_TTL (25min): no Pilot marker is a weaker signal, and a
# genuine build (even slow) won't go branchless for 2h.
POOL_ZOMBIE_TTL = 7200  # 2 hours

# ga-hkpwv: session states that definitively prove a non-working session.
# Used in pool_has_live_worker() to distinguish dead vs unknown states.
# archived/quarantined/failed-create: exotic terminal states that also cannot
# be doing any work; without them a lingering un-closed dead worker in one of
# these states would permanently block reclaim for all beads in that pool.
_POOL_DEAD_STATES = frozenset({
    "asleep", "drained", "closed",
    "archived", "quarantined", "failed-create",
})

STATE_FILE = ".gc/state/inflight-reclaim-guard.json"
GC_CITY = "/Users/athos/gt/.gascity-gastown-hq"


def _list_rig_stores():
    """Return list of (name, path) for non-HQ rig stores. Fail-open: [] on error.

    ga-mfeip: used by list_inflight_beads / list_stranded_inprogress_beads to
    fan-out queries across every Dolt store so rig-native in-flight beads
    (wa-*/ps-*/lx-*/ma-* prefixes, living in rig-own stores) are visible to
    the cross-store reclaim sweep. HQ-native beads are unaffected.
    """
    try:
        result = subprocess.run(
            ["gc", "--city", GC_CITY, "rig", "list", "--json"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return []
        data = json.loads(result.stdout)
        rigs = data.get("rigs", [])
        return [
            (r.get("name", ""), r["path"])
            for r in rigs
            if not r.get("hq", False)
            and r.get("path")
            and os.path.isdir(r.get("path", ""))
        ]
    except Exception:
        return []

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


def _has_needs_human_label(labels):
    """True if labels contain gate:needs-human (exact) OR any gate:needs-human:* variant.

    ga-hkpwv / bead-spec: the Mayor's circuit-breaker uses sub-labels like
    gate:needs-human:on-device, :routing, :technical. An exact-match check misses
    these, allowing pool-zombie sweep to re-reclaim a deliberately-parked bead —
    a safety-critical false reclaim. Prefix check closes the gap.
    """
    return any(
        lbl == "gate:needs-human" or lbl.startswith("gate:needs-human:")
        for lbl in labels
    )


def _is_ephemeral_pool_assignee(assignee):
    """True if assignee is an ephemeral-pool bead assignee (bare template OR concrete adhoc form).

    Covers:
    - Bare template in EPHEMERAL_POOL_ASSIGNEES (e.g. 'wa-worker')
    - Concrete adhoc form: '<template>-adhoc-<hex>' (e.g. 'wa-worker-adhoc-faac43db2d')

    ga-hkpwv gap fix: the Pilot pool dispatcher assigns concrete adhoc session names
    like 'wa-worker-adhoc-<hash>' to beads rather than the bare template 'wa-worker'.
    Both forms must qualify as ephemeral pool dispatches so that the pool-zombie reclaim
    path (POOL_ZOMBIE_TTL + per-session liveness) handles them correctly.
    """
    if not assignee:
        return False
    if assignee in EPHEMERAL_POOL_ASSIGNEES:
        return True
    al = assignee.lower()
    for template in EPHEMERAL_POOL_ASSIGNEES:
        if al.startswith(template + "-adhoc-"):
            return True
    return False


# ---------------------------------------------------------------------------
# Pure decision function (unit-testable, zero side effects)
# ---------------------------------------------------------------------------

def reclaim_decision(has_live_session, has_recent_branch, seconds_stranded,
                     reclaim_count, has_needs_human, has_dispatching_marker,
                     min_stranding_secs=None):
    """Compute the reclaim action for one stranded in-flight bead.

    Args:
        has_live_session:        True if assignee matches an active/awake session
        has_recent_branch:       True if any origin branch for bead has commit within TTL
        seconds_stranded:        seconds since first seen as stranded (0.0 if not tracked yet)
        reclaim_count:           current pilot:reclaim-count:N from bead labels (int)
        has_needs_human:         True if bead carries gate:needs-human (or :* variant)
        has_dispatching_marker:  True if quality-gate-marker with active gate state exists
        min_stranding_secs:      minimum continuous stranding before action; defaults to
                                 RECLAIM_TTL (25min). Pass POOL_ZOMBIE_TTL (2h) for
                                 bare-template pool-zombie beads (ga-hkpwv).

    Returns:
        action in {"reclaim", "escalate", "noop"}
    """
    if min_stranding_secs is None:
        min_stranding_secs = RECLAIM_TTL
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
    if seconds_stranded < min_stranding_secs:
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
# Pool-dead detection state (ga-dbibq)
# Per-pool state file: ${STATE_FILE}.pool-dead/<safe_pool_name>
# Stores {"pool": "<name>", "consecutive_cycles": N, "last_alert_epoch": T}
# ---------------------------------------------------------------------------

def _pool_dead_state_path(pool):
    """Path to per-pool dead-detection state file (alongside the main state file)."""
    safe = pool.replace("/", "_").replace(".", "_")
    return os.path.join(STATE_FILE + ".pool-dead", safe)


def _load_pool_dead_state(pool):
    """Load pool-dead state. Returns default dict on any error."""
    try:
        with open(_pool_dead_state_path(pool)) as f:
            return json.load(f)
    except Exception:
        return {"consecutive_cycles": 0, "last_alert_epoch": 0}


def _save_pool_dead_state(pool, ps):
    """Save pool-dead state. Best-effort; never crashes."""
    try:
        path = _pool_dead_state_path(pool)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump(ps, f)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] pool-dead state save failed (pool={pool}): {exc}",
              flush=True)


def _check_pool_dead(pool_zombies, now):
    """Emit a [POOL-DEAD] Mayor alert when a whole worker pool produces nothing.

    Called in run_cycle BEFORE per-bead actuation, with the set of beads already
    classified as zombie this cycle (no live session + no recent branch + stranded
    > TTL, regardless of whether they'll be reclaimed or escalated).

    pool_zombies: dict mapping pool-name → list[bead_id] for THIS cycle.

    Hysteresis: pool must have >= POOL_DEAD_MIN zombie beads for 2 consecutive
    cycles before an alert is emitted. Cooldown: at most one alert per pool per
    POOL_DEAD_COOLDOWN seconds. Fail-open: any error (including mail failure) is
    logged and the cycle continues — never crashes.
    """
    pool_dead_dir = STATE_FILE + ".pool-dead"
    seen_pools = set(pool_zombies.keys())

    # Reset consecutive_cycles for pools that had state but are NOT zombie this cycle
    # (recovery: the pool started building again — don't alert after a 1-cycle blip).
    try:
        if os.path.isdir(pool_dead_dir):
            for fname in os.listdir(pool_dead_dir):
                fpath = os.path.join(pool_dead_dir, fname)
                try:
                    with open(fpath) as fh:
                        ps = json.load(fh)
                    pool_name = ps.get("pool", "")
                    if pool_name and pool_name not in seen_pools and ps.get("consecutive_cycles", 0) > 0:
                        ps["consecutive_cycles"] = 0
                        with open(fpath, "w") as fh:
                            json.dump(ps, fh)
                except Exception:
                    pass
    except Exception:
        pass

    for pool, bead_ids in pool_zombies.items():
        n = len(bead_ids)
        ps = _load_pool_dead_state(pool)
        ps["pool"] = pool  # stored for recovery-reset lookups above

        if n >= POOL_DEAD_MIN:
            ps["consecutive_cycles"] = ps.get("consecutive_cycles", 0) + 1
        else:
            # Below threshold — reset; might be a transient single-bead stale.
            ps["consecutive_cycles"] = 0
            _save_pool_dead_state(pool, ps)
            continue

        if (ps["consecutive_cycles"] >= 2
                and now - ps.get("last_alert_epoch", 0) > POOL_DEAD_COOLDOWN):
            ids_str = " ".join(bead_ids)
            emit(f"[INFLIGHT-RECLAIM] [POOL-DEAD] pool={pool} zombies={n} "
                 f"(no branch + dead session, stranded > TTL)")
            # Fail-open: mail failure is logged, never crashes the cycle.
            try:
                result = subprocess.run(
                    ["gc", "mail", "send", "mayor",
                     "-s", f"[POOL-DEAD] {pool} producing nothing",
                     "-m", (f"{n} beads dispatched to {pool} are in_progress with no branch "
                            f"and no live worker for >TTL: {ids_str}. The pool is not building. "
                            f"Existing healers notified via flow-authority.")],
                    timeout=20, capture_output=True)
                if result.returncode != 0:
                    print(f"[INFLIGHT-RECLAIM] [POOL-DEAD] mail non-zero exit (pool={pool} rc={result.returncode}): "
                          f"{result.stderr.decode(errors='replace').strip()}", flush=True)
            except Exception as exc:
                print(f"[INFLIGHT-RECLAIM] [POOL-DEAD] mail failed (pool={pool}): {exc}",
                      flush=True)
            ps["last_alert_epoch"] = now

        _save_pool_dead_state(pool, ps)


# ---------------------------------------------------------------------------
# Data queries (all fail-safe: return None on error → caller skips cycle)
# ---------------------------------------------------------------------------

def list_inflight_beads():
    """List open beads carrying story:in-flight from HQ + all rig stores.

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

    ga-mfeip (cross-store): also queries non-HQ rig stores so rig-native in-flight
    beads (wa-*/ps-*/lx-*/ma-* prefixes, living in rig-own Dolt stores) are
    visible. Attaches rig_root to each bead dict for store-aware bd routing in
    do_reclaim(). Fail-open per rig store: a rig query error skips that store but
    never aborts the cycle. HQ failure still returns None per existing contract.
    Returns list of bead dicts (each with a rig_root key), or None on HQ error.
    """
    # HQ query — fail-safe: return None on error per existing contract.
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
    except Exception:
        return None

    # Tag HQ beads: rig_root=None (HQ-native, bd mutations need no -C override)
    merged = {}
    for b in data:
        bid = b.get("id", "")
        if bid:
            b.setdefault("rig_root", None)
            merged[bid] = b

    # Rig stores — fail-open per store (a rig error must not skip HQ results)
    for _rig_name, rig_path in _list_rig_stores():
        try:
            r = subprocess.run(
                ["bd", "-C", rig_path,
                 "list",
                 "--label", "story:in-flight",
                 "--status", "open,in_progress",
                 "--json"],
                capture_output=True, text=True, timeout=20)
            if r.returncode != 0 or not r.stdout.strip():
                continue
            rig_data = json.loads(r.stdout)
            if not isinstance(rig_data, list):
                continue
            for b in rig_data:
                bid = b.get("id", "")
                if bid and bid not in merged:
                    b["rig_root"] = rig_path
                    merged[bid] = b
        except Exception:
            continue   # fail-open: skip this rig

    return list(merged.values())


def is_reclaimable_inprogress_story(labels, assignee=None):
    """Pure predicate: True if an in_progress bead is a Pilot story stranded
    WITHOUT its story:in-flight label (the ga-vw26y blind spot), and is thus a
    candidate for the in_progress sweep.

    Requires a durable Pilot marker — pilot:dispatched, story:in-flight, or any
    pilot:reclaim-count:N (the last proves the guard itself already touched this
    bead, so it is unambiguously a Pilot story whose in-flight label was since
    stripped). Rejects any bead carrying a terminal/parked label so completed or
    intentionally-held work is never resurrected.

    ga-hkpwv (pool-zombie path): also qualifies when assignee is a bare pool
    template in EPHEMERAL_POOL_ASSIGNEES (e.g. 'wa-worker') OR a concrete adhoc
    session name of that pool (e.g. 'wa-worker-adhoc-faac43db2d'). The Pilot's pool
    dispatch stamps assignee=<session-name> but NO pilot:dispatched / story:in-flight —
    these beads are unambiguously pool dispatches, so requiring a Pilot marker
    would leave them permanently invisible. The reclaim rails (pool_has_live_worker
    / concrete_adhoc_session_is_live + POOL_ZOMBIE_TTL + branch check) gate
    actuation conservatively.

    SCOPE-CRITICAL: this is the only thing standing between the in_progress
    sweep and arbitrary in_progress work (crew, gate, dog task beads). Those
    carry NO Pilot marker AND have no EPHEMERAL_POOL_ASSIGNEES assignee →
    this returns False → they are never actuated on.

    ga-hkpwv / prefix fix: gate:needs-human:* variants (e.g. :on-device, :routing)
    are treated identically to the bare gate:needs-human — deliberately parked.
    """
    is_pool_zombie_candidate = (
        assignee is not None and _is_ephemeral_pool_assignee(assignee)
    )
    has_marker = (
        is_pool_zombie_candidate
        or any(lbl in PILOT_STORY_MARKERS for lbl in labels)
        or any(lbl.startswith("pilot:reclaim-count:") for lbl in labels)
    )
    if not has_marker:
        return False
    # Reject any terminal/parked label (exact OR gate:needs-human:* prefix)
    if any(
        lbl in TERMINAL_PARKED_LABELS or lbl.startswith("gate:needs-human:")
        for lbl in labels
    ):
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

    ga-mfeip (cross-store): also queries non-HQ rig stores for the same reason
    as list_inflight_beads(). Attaches rig_root to each qualifying bead.
    Fail-open per rig store. HQ failure returns None per existing contract.
    Returns list of bead dicts (each with a rig_root key), or None on HQ error.
    """
    # HQ query — fail-safe: return None on error per existing contract.
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
    except Exception:
        return None

    # Tag HQ beads: rig_root=None; filter to Pilot stories
    merged = {}
    for b in data:
        if not is_reclaimable_inprogress_story(b.get("labels", []), b.get("assignee")):
            continue
        bid = b.get("id", "")
        if bid:
            b.setdefault("rig_root", None)
            merged[bid] = b

    # Rig stores — fail-open per store
    for _rig_name, rig_path in _list_rig_stores():
        try:
            r = subprocess.run(
                ["bd", "-C", rig_path,
                 "list",
                 "--status", "in_progress",
                 "--json"],
                capture_output=True, text=True, timeout=20)
            if r.returncode != 0 or not r.stdout.strip():
                continue
            rig_data = json.loads(r.stdout)
            if not isinstance(rig_data, list):
                continue
            for b in rig_data:
                if not is_reclaimable_inprogress_story(b.get("labels", []), b.get("assignee")):
                    continue
                bid = b.get("id", "")
                if bid and bid not in merged:
                    b["rig_root"] = rig_path
                    merged[bid] = b
        except Exception:
            continue   # fail-open: skip this rig

    return list(merged.values())


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


# ga-lrglm: matches the Pilot dispatch-title convention set in pilot-dispatcher.sh's
# SLING_TITLE ("fix bug <ID>: ..." for bug/tech-debt, "build story <ID>: ..." for
# feature/story), so a sling bead's own title can be resolved back to the ORIGINAL
# bug/story it was dispatched to fix. See list_gate_active_source_beads() below.
_SLING_TITLE_RE = re.compile(r'^(?:fix bug|build story)\s+(\S+):')


def list_gate_active_source_beads():
    """Return set of source-bead IDs that currently have an active gate marker
    (gate-status:ready, dispatching, queued, or claimed).

    "ready" is included because /gate-done writes a fresh marker in that state;
    promotion to "queued" happens later via a separate sweep, so omitting
    "ready" opens a race window where a just-submitted fix's marker is
    invisible to this check (ga-cxzby).

    ga-lrglm: a bug/story dispatched through the standard sling-task wrapper
    ("fix bug <ID>: ..." / "build story <ID>: ...") gets its gate marker keyed
    on the SLING bead's id (source-bead:<sling-id>), never the ORIGINAL bug's
    id — so a plain `bead_id in <result>` membership check can never protect
    the original bead while its sling sits queued/dispatching/claimed at the
    gate, and this guard reclaims (re-dispatches) it out from under a fix
    that's already built and sitting healthy at the gate. For each directly-
    active source-bead this resolves ITS OWN title and parses the dispatch-
    title convention back out; the referenced original bead is added to the
    returned set alongside the sling bead itself. Resolving from the ACTIVE
    MARKER side — not the bug's own pilot.sling_bead metadata, which is
    single-valued and gets overwritten on every redispatch — keeps this
    correct across multiple historical re-dispatches of the same bug:
    whichever historical sling currently owns the live marker, its own title
    alone resolves the original, no dispatch-history metadata required.
    Title resolution is best-effort / fail-OPEN per lookup (a bd error or
    unparseable title just skips that one back-reference); it never widens
    the fail-safe contract below.

    Returns a frozenset, or None on error (fail-safe: caller treats None as unknown
    and skips the cycle rather than risking a false reclaim).
    """
    active_source_beads = set()
    for gate_lbl in ("gate-status:ready", "gate-status:dispatching", "gate-status:queued", "gate-status:claimed"):
        try:
            result = subprocess.run(
                ["bd", "list",
                 "--label", "type:quality-gate-marker",
                 "--label", gate_lbl,
                 "--json"],
                capture_output=True, text=True, timeout=20)
            if result.returncode != 0:
                # A sub-query FAILURE (e.g. transient Dolt contention) is not the
                # same as "no beads matched" — conflating them silently drops that
                # gate_lbl's markers from the active set without tripping the
                # fail-safe (ga-ap7od). Match the documented contract: any error
                # fails the whole function safe, not just this one label.
                return None
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

    # ga-lrglm: resolve sling → original-bug back-references. Best-effort/fail-open —
    # a lookup failure here must never turn into a whole-cycle fail-safe skip; it just
    # means this cycle stays as protective as it was before this back-reference existed.
    if active_source_beads:
        try:
            result = subprocess.run(
                ["bd", "show", *sorted(active_source_beads), "--json"],
                capture_output=True, text=True, timeout=20)
            if result.returncode == 0 and result.stdout.strip():
                data = json.loads(result.stdout)
                if isinstance(data, list):
                    for b in data:
                        title = b.get("title") or ""
                        match = _SLING_TITLE_RE.match(title)
                        if match:
                            active_source_beads.add(match.group(1))
        except Exception:
            pass  # best-effort: keep the directly-active set as-is

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


def pool_has_live_worker(pool_template, sessions, now=None, bead_update_age=None):
    """Return True if any session from pool_template is live and working.

    ga-hkpwv: for bare pool-template assignees (e.g. 'wa-worker'), bead.assignee
    equals the template name, NOT a concrete session name like 'wa-worker-adhoc-<hash>'.
    The existing session_is_live() matches assignee against session identifiers
    (id, name, session_name, alias, agent_name) — none of which equals the bare
    template — so it always returns False for bare-template beads even when the
    pool is actively building. This function uses session.template to detect live
    pool workers instead.

    Conservative (aligns with ga-64usm):
    - Missing/unparseable last_active → treated alive (session_owner_is_healthy).
    - Unknown/unrecognized state (not in _POOL_DEAD_STATES, not in LIVE_STATES) →
      treated alive (return True immediately). Never reclaim on unclear state.
    - Only _POOL_DEAD_STATES = {asleep, drained, closed} are definitively dead.

    CORRECTNESS-CRITICAL: overly conservative — ANY active session from the pool
    (even if building a different bead) blocks ALL bare-template reclaims from
    that pool. Belt-and-suspenders: POOL_ZOMBIE_TTL (2h) ensures no live build
    is false-reclaimed even if the pool-worker→bead mapping is imperfect.
    """
    if now is None:
        now = time.time()
    for s in sessions:
        if s.get("template", "") != pool_template:
            continue
        state = s.get("state", "").lower()
        if state in _POOL_DEAD_STATES:
            continue  # definitively dead/sleeping — skip
        if state in LIVE_STATES:
            # Active/awake — apply ga-64usm staleness check
            activity_age = session_activity_age(s, now)
            if session_owner_is_healthy(True, activity_age, bead_update_age):
                return True
            continue  # stale active (frozen zombie) — check remaining sessions
        # Unknown/unrecognized/missing state — conservative: treat pool as alive
        return True
    return False


def concrete_adhoc_session_is_live(assignee, sessions, now=None, bead_update_age=None):
    """Per-session liveness for concrete ephemeral-adhoc workers (e.g. 'wa-worker-adhoc-<hex>').

    Unlike pool_has_live_worker() (pool-wide: any live pool worker blocks ALL reclaims),
    this checks ONLY the session named exactly by assignee — more precise because the
    specific session identity is known at dispatch time.

    Conservative (ga-64usm / ga-hkpwv gap fix):
    - Session found, state in _POOL_DEAD_STATES → keep scanning (a live successor wins)
    - Session found, state in LIVE_STATES → apply session_owner_is_healthy() staleness check
    - Session found, state unknown (not in either set) → True (ambiguous → NOOP)
    - Session not found (gone / never started / purged) → False (dead → eligible)
    - Missing/unparseable last_active on a LIVE session → True (conservative;
      can't prove staleness per ga-64usm: NEVER reclaim on absent field)
    - Duplicate identifier: dead first, live later → live wins (scan-all hardening)

    Coordinator exclusion (ga-7m191): assignee naming mayor/deacon → False.

    CORRECTNESS-CRITICAL: this is the primary guard against false-reclaiming a bead
    whose concrete adhoc builder session is still alive.
    """
    if not assignee or is_coordinator(assignee):
        return False
    if now is None:
        now = time.time()

    found_dead = False
    for s in sessions:
        identifiers = {
            s.get("id", ""),
            s.get("name", ""),
            s.get("session_name", ""),
            s.get("alias", ""),
            s.get("agent_name", ""),
        }
        identifiers.discard("")
        if assignee not in identifiers:
            continue
        # Found the matching session — skip coordinator identities.
        if any(is_coordinator(idv) for idv in identifiers):
            return False

        state = s.get("state", "").lower()
        if state in _POOL_DEAD_STATES:
            found_dead = True
            continue  # Keep scanning — a live successor with the same identifier must win
        if state in LIVE_STATES:
            # Apply ga-64usm staleness check: alive != working
            activity_age = session_activity_age(s, now)
            return session_owner_is_healthy(True, activity_age, bead_update_age)
        # Unknown/unrecognized state — conservative: treat as alive (NOOP).
        # NEVER reclaim on ambiguous session state.
        return True

    # No live session found. Whether session was dead (found_dead) or gone
    # (no match at all) → eligible for reclaim. Mirrors pool_has_live_worker.
    return False


def list_live_sling_source_beads(sessions, now):
    """Return set of ORIGINAL bug/story bead IDs whose SLING/task bead is
    in_progress and assigned to a live builder session (ga-qfo3).

    Pilot's dispatch flow marks the ORIGINAL bug/story bead story:in-flight,
    but assigns the actual build work — and thus the live builder's session —
    to a separate SLING bead (title "fix bug <id>: ..." / "build story <id>:
    ..."). The original bead's own `assignee` is therefore legitimately empty
    while a live session is actively building it, so
    session_is_live(original_bead_assignee, ...) checks the wrong bead's
    field and can never see the real owner.

    Root-caused from the ga-qfo3 incident's launchd log: the guard's own
    "started stranded clock" line showed assignee='' for the ORIGINAL bug
    (ga-z6uo) throughout, while its sling bead (ga-vw39) carried the live dog
    session's assignee the whole time — ga-vw39 never even appeared in the
    guard's query results. The bead was reclaimed at 31min idle with a fully
    live, actively-committing builder.

    Mirrors list_gate_active_source_beads()'s sling→original title
    back-reference resolution (_SLING_TITLE_RE), but protects the
    LIVE-SESSION rail instead of the gate-marker rail. Simpler than that
    function: a sling bead's liveness is resolved directly off the same
    in_progress query result (no separate marker-bead indirection to
    bootstrap from), so multi-redispatch is handled for free — only a
    CURRENTLY in_progress sling can ever contribute a protected id; closed/
    superseded historical slings are absent from the query and contribute
    nothing.

    Fail-safe: returns None on HQ query error (caller skips the cycle,
    matching the existing contract for the other list_* functions in this
    file). Rig-store fan-out is fail-open per store (ga-mfeip pattern).
    """
    try:
        result = subprocess.run(
            ["bd", "list", "--status", "in_progress", "--json"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return None
        data = json.loads(result.stdout)
        if not isinstance(data, list):
            return None
    except Exception:
        return None

    def _collect(candidate_beads, into):
        for b in candidate_beads:
            title = b.get("title") or ""
            match = _SLING_TITLE_RE.match(title)
            if not match:
                continue
            assignee = b.get("assignee") or ""
            if not assignee:
                continue
            bead_update_epoch = parse_iso_epoch(b.get("updated_at", ""))
            bead_update_age = (
                (now - bead_update_epoch) if bead_update_epoch is not None else None
            )
            if session_is_live(assignee, sessions, now, bead_update_age):
                into.add(match.group(1))

    protected = set()
    _collect(data, protected)

    # Rig stores — fail-open per store (ga-mfeip cross-store consistency)
    for _rig_name, rig_path in _list_rig_stores():
        try:
            r = subprocess.run(
                ["bd", "-C", rig_path, "list", "--status", "in_progress", "--json"],
                capture_output=True, text=True, timeout=20)
            if r.returncode != 0 or not r.stdout.strip():
                continue
            rig_data = json.loads(r.stdout)
            if not isinstance(rig_data, list):
                continue
            _collect(rig_data, protected)
        except Exception:
            continue  # fail-open: skip this rig

    return frozenset(protected)


def get_branch_recent(bead_id):
    """Return True if any remote branch whose final path segment equals <bead-id>
    (or starts with <bead-id> followed by '-'/'_'/'.') has a commit within
    RECLAIM_TTL seconds of now.

    Matches ALL branch naming conventions regardless of prefix:
      crew/<pool>/<bead-id>     (dominant: 416 branches, e.g. crew/wa-worker/wa-quoy)
      feat/<bead-id>*           (30 branches)
      fix/<bead-id>*
      feature/<bead-id>*
      polecat/<bead-id>*
    Prefix-collision guard: segment must equal bead_id EXACTLY or be followed by
    a separator char ('-', '_', '.') — so bead 'wa-oly' does NOT match 'wa-oly1'.

    Fetches both HQ and WA repos. Fail-safe: ANY git error (fetch or list)
    → return True (branch-might-exist, do NOT reclaim). Logs on error.

    CORRECTNESS-CRITICAL: this is the secondary guard against reclaiming beads
    where a builder is actively pushing but their session has a different name
    than the bead's assignee field.
    """
    now = time.time()
    for repo in REPOS:
        # Fetch to update remote-tracking refs.
        # Fail-safe: fetch error → branch might exist → do NOT reclaim.
        try:
            subprocess.run(
                ["git", "-C", repo, "fetch", "origin", "--prune", "--quiet"],
                capture_output=True, timeout=30)
        except Exception as _fe:
            print(
                f"[INFLIGHT-RECLAIM] branch-rail: fetch failed for {repo}: {_fe}"
                " — treating as branch-might-exist (fail-safe)",
                flush=True)
            return True

        # List all remote refs with timestamps in a single pass.
        # Fail-safe: ref-list error → branch might exist → do NOT reclaim.
        try:
            r = subprocess.run(
                ["git", "-C", repo, "for-each-ref",
                 "--sort=-committerdate",
                 "--format=%(refname) %(committerdate:unix)",
                 "refs/remotes/origin/"],
                capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                print(
                    f"[INFLIGHT-RECLAIM] branch-rail: for-each-ref failed"
                    f" (rc={r.returncode}) for {repo}"
                    " — treating as branch-might-exist (fail-safe)",
                    flush=True)
                return True
            for line in r.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                parts = line.rsplit(None, 1)
                if len(parts) != 2:
                    continue
                refname, ts_str = parts
                # Final path segment of the ref (e.g. 'wa-quoy' from
                # refs/remotes/origin/crew/wa-worker/wa-quoy).
                segment = refname.rsplit("/", 1)[-1]
                # Match: exact OR bead_id + separator (prefix-collision guard).
                if not (segment == bead_id
                        or segment.startswith(bead_id + "-")
                        or segment.startswith(bead_id + "_")
                        or segment.startswith(bead_id + ".")):
                    continue
                try:
                    ts = float(ts_str)
                    if now - ts < RECLAIM_TTL:
                        return True
                except ValueError:
                    continue
        except Exception as _re:
            print(
                f"[INFLIGHT-RECLAIM] branch-rail: ref-list failed for {repo}: {_re}"
                " — treating as branch-might-exist (fail-safe)",
                flush=True)
            return True
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


def _pool_of(assignee):
    """Normalize a bead assignee to its worker-pool name for pool-dead tracking (ga-dbibq).

    wa-worker / wa-worker-* → 'wa-worker'
    gastown.dog / dog-*     → 'gastown.dog'
    anything else           → the assignee as-is (crew name)
    empty / None            → '' (callers skip empty pool)
    """
    if not assignee:
        return ""
    a = str(assignee)
    al = a.lower()
    if al == "wa-worker" or al.startswith("wa-worker-"):
        return "wa-worker"
    if al == "gastown.dog" or al.startswith("dog-"):
        return "gastown.dog"
    return a


# ---------------------------------------------------------------------------
# Actuation helpers (label + assignee ops on real beads — CONSERVATIVE)
# ---------------------------------------------------------------------------

def do_reclaim(bead_id, bead_title, reclaim_count, idle_min, labels, rig_root=None):
    """Strip story:in-flight (+pilot:dispatched if present), clear assignee,
    bump reclaim label.

    ga-mfeip (cross-store): rig_root, when set, routes every bd mutation to the
    bead's own rig store (bd -C rig_root) instead of defaulting to HQ. HQ-native
    beads pass rig_root=None and use plain bd (existing behavior unchanged).

    Returns True if all bd ops succeeded, False if any failed (still best-effort).
    """
    new_count = reclaim_count + 1
    ok = True

    # Build the bd prefix: rig-native beads route to their own store.
    _bd = ["bd", "-C", rig_root] if rig_root else ["bd"]

    # 1. Remove lifecycle labels that are actually present. ga-7m191:
    #    pilot:dispatched may be absent (stripped by a partial prior reclaim);
    #    skipping it avoids a spurious RECLAIM-FAILED on a successful reclaim.
    for lbl in ("story:in-flight", "pilot:dispatched"):
        if lbl not in labels:
            continue
        try:
            r = subprocess.run(
                _bd + ["label", "remove", bead_id, lbl, "-q"],
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
            _bd + ["assign", bead_id, ""],
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
            _bd + ["update", bead_id, "--status", "open"],
            capture_output=True, text=True, timeout=15)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: reset status open {bead_id}: {exc}", flush=True)

    # 3. Bump reclaim count label (remove old, add new)
    if reclaim_count > 0:
        try:
            subprocess.run(
                _bd + ["label", "remove", bead_id, f"pilot:reclaim-count:{reclaim_count}", "-q"],
                capture_output=True, text=True, timeout=15)
        except Exception:
            pass  # old label may already be missing; ignore
    try:
        subprocess.run(
            _bd + ["label", "add", bead_id, f"pilot:reclaim-count:{new_count}", "-q"],
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
                _bd + ["label", "add", bead_id, "pilot:held", "-q"],
                capture_output=True, text=True, timeout=15)
            subprocess.run(
                _bd + ["label", "add", bead_id, f"pilot:held-until:{_held_until}", "-q"],
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
            _bd + ["comment", bead_id,
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


def do_escalate(bead_id, bead_title, reclaim_count, idle_min, labels, rig_root=None):
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

    ga-mfeip (cross-store): rig_root routes bd mutations to the bead's own rig
    store when set. HQ-native beads pass rig_root=None (existing behavior).
    """
    # Build the bd prefix: rig-native beads route to their own store.
    _bd = ["bd", "-C", rig_root] if rig_root else ["bd"]

    try:
        subprocess.run(
            _bd + ["label", "add", bead_id, "gate:needs-human", "-q"],
            capture_output=True, text=True, timeout=15)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: add gate:needs-human {bead_id}: {exc}",
              flush=True)
    # imp13: sub-label classifies this as a TECHNICAL circuit-breaker park (not a product decision).
    try:
        subprocess.run(
            _bd + ["label", "add", bead_id, "gate:needs-human:technical", "-q"],
            capture_output=True, text=True, timeout=15)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: add gate:needs-human:technical {bead_id}: {exc}",
              flush=True)

    try:
        subprocess.run(
            _bd + ["comment", bead_id,
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

    # --- Query live sling-owner source beads (ga-qfo3, fail-safe: None → skip
    #     cycle entirely — same contract as the gate-marker query above) ---
    live_sling_owner_beads = list_live_sling_source_beads(sessions, now)
    if live_sling_owner_beads is None:
        print("[INFLIGHT-RECLAIM] sling-owner query failed — skipping cycle (safe)", flush=True)
        return len(beads), 0

    stranded_count = 0
    active_bead_ids = set()
    # ga-dbibq: two-pass structure so pool-dead alert fires BEFORE per-bead actuation.
    classified = []    # (bead_id, title, labels, action, idle_min, reclaim_count, assignee)
    pool_zombies = {}  # pool -> [bead_id] for beads classified zombie this cycle

    # --- Pass 1: classify all beads (no actuation yet) ---
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
        rig_root = bead.get("rig_root")  # ga-mfeip: None=HQ-native, path=rig store

        # --- Safety flags ---
        # ga-hkpwv: catch gate:needs-human:* prefix variants (e.g. :on-device, :routing)
        # in addition to the bare gate:needs-human — all are deliberately-parked beads.
        has_needs_human      = _has_needs_human_label(labels)
        has_dispatching_marker = bead_id in gate_active_beads
        # Owner deliberately SUSPENDED → the bead is parked, not stranded. Holds (waits
        # for the crew to resume) instead of re-pooling — the wa-wbub / digo-wa churn.
        has_suspended_owner  = bool(assignee) and assignee in suspended_agents
        # ga-64usm: the bead's own last-update age is the secondary progress
        # signal that rescues a stale-activity session whose builder is still
        # touching the bead (workers should bd-update during long work).
        bead_update_epoch = parse_iso_epoch(bead.get("updated_at", ""))
        bead_update_age = (now - bead_update_epoch) if bead_update_epoch is not None else None
        # ga-hkpwv: ephemeral pool assignees come in two forms:
        #   - Bare template (e.g. 'wa-worker'): no concrete session matches this name.
        #     Use pool_has_live_worker() — pool-wide: ANY live wa-worker session
        #     blocks ALL bare-template reclaims (conservative/coarse-grained).
        #   - Concrete adhoc (e.g. 'wa-worker-adhoc-faac43db2d'): a specific session
        #     was named at dispatch time. Use concrete_adhoc_session_is_live() for a
        #     per-session check — more precise; only THAT session's liveness matters.
        is_bare_pool_zombie = assignee in EPHEMERAL_POOL_ASSIGNEES
        is_adhoc_pool_zombie = (
            not is_bare_pool_zombie
            and _is_ephemeral_pool_assignee(assignee)
        )
        is_pool_zombie_bead = is_bare_pool_zombie or is_adhoc_pool_zombie
        if is_bare_pool_zombie:
            has_live_session = pool_has_live_worker(assignee, sessions, now, bead_update_age)
        elif is_adhoc_pool_zombie:
            has_live_session = concrete_adhoc_session_is_live(
                assignee, sessions, now, bead_update_age)
        else:
            has_live_session = session_is_live(assignee, sessions, now, bead_update_age)

        # ga-qfo3: this bead's OWN assignee may be empty because Pilot assigned
        # the live builder session to its SLING wrapper bead instead (see
        # list_live_sling_source_beads' docstring). Treat it as owned when the
        # sling bead's session is live — closes the false-reclaim gap that let
        # ga-z6uo get reclaimed out from under a fully live, actively-building
        # dog session.
        if not has_live_session and bead_id in live_sling_owner_beads:
            has_live_session = True

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

        # ga-hkpwv: pool-zombie beads (bare template AND concrete adhoc forms) use
        # POOL_ZOMBIE_TTL (2h) instead of the standard RECLAIM_TTL (25min) — a longer
        # window compensates for the weaker signal (no Pilot marker) and prevents
        # false reclaims on slow-starting builds.
        min_stranding_secs = POOL_ZOMBIE_TTL if is_pool_zombie_bead else RECLAIM_TTL

        # --- Pure decision ---
        action = reclaim_decision(
            has_live_session=has_live_session,
            has_recent_branch=has_recent_branch,
            seconds_stranded=seconds_stranded,
            reclaim_count=reclaim_count,
            has_needs_human=has_needs_human,
            has_dispatching_marker=has_dispatching_marker,
            min_stranding_secs=min_stranding_secs,
        )

        idle_min = seconds_stranded / 60.0

        # Bucket zombie beads by pool for pool-dead detection (ga-dbibq).
        # "Zombie" = would-reclaim or would-escalate: no live session, no recent
        # branch, stranded past TTL. Per-bead actuation follows in Pass 2.
        # ga-hkpwv: pool-zombie beads feed into this bucket automatically since
        # _pool_of("wa-worker") == "wa-worker".
        if action in ("reclaim", "escalate"):
            pool = _pool_of(assignee)
            if pool:
                pool_zombies.setdefault(pool, []).append(bead_id)

        # Include assignee + rig_root in classified tuple for Pass 2 (ga-hkpwv, ga-mfeip)
        classified.append((bead_id, title, labels, assignee, action, idle_min, reclaim_count, rig_root))

    # --- Pool-dead alert (BEFORE per-bead actuation, ga-dbibq) ---
    # Emits [POOL-DEAD] Mayor mail when >= POOL_DEAD_MIN beads from the same pool
    # are zombie for 2 consecutive cycles. Fail-open; never crashes the cycle.
    _check_pool_dead(pool_zombies, now)

    # --- Pass 2: per-bead actuation (logic unchanged from prior single-pass) ---
    for bead_id, title, labels, assignee, action, idle_min, reclaim_count, rig_root in classified:
        if action == "reclaim":
            ok = do_reclaim(bead_id, title, reclaim_count, idle_min, labels, rig_root=rig_root)
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
                do_escalate(bead_id, title, reclaim_count, idle_min, labels, rig_root=rig_root)
                emit(
                    f"[INFLIGHT-RECLAIM] [ESCALATED] bead={bead_id} "
                    f"reclaimed {reclaim_count}x idle={idle_min:.0f}min — "
                    f"needs human/Mayor intervention title={title!r}"
                )
                _irg_ledger("human-touch", {"ts": _irg_datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "source_daemon": "inflight-reclaim-guard", "stage": "executa", "kind": "technical", "bead_id": bead_id, "reason": f"Reclaim cap exhausted ({reclaim_count}x) — needs human intervention"}, fail_open=True)
                # ga-hkpwv: pool-zombie escalation also mails Mayor directly
                # (POOL-DEAD handles pool-level alerts; this covers single-bead cap exhaustion)
                if _is_ephemeral_pool_assignee(assignee):
                    try:
                        subprocess.run(
                            ["gc", "mail", "send", "mayor",
                             "-s", f"[POOL-ZOMBIE-ESCALATED] {assignee}: bead {bead_id} reclaimed {reclaim_count}x",
                             "-m", (f"Pool-zombie bead {bead_id!r} ({title!r}) exhausted reclaim cap "
                                    f"({reclaim_count}/{MAX_RECLAIMS}) with assignee={assignee!r}, "
                                    f"no branch, no active pool session. Marked gate:needs-human. "
                                    f"Needs human investigation + re-queue.")],
                            timeout=20, capture_output=True)
                    except Exception as _exc:
                        print(f"[INFLIGHT-RECLAIM] warn: pool-zombie escalation mail ({bead_id}): {_exc}",
                              flush=True)
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
# Hermetic selftest (ga-dbibq) — python3 inflight-reclaim-guard.py --selftest
# Tests _pool_of() and _check_pool_dead() cycle behavior.
# Does NOT call bd, gc, git, or notify live.
# ---------------------------------------------------------------------------

def _selftest():
    """Run hermetic POOL-DEAD selftest. Returns True if all checks pass."""
    import tempfile as _tempfile
    import shutil as _shutil

    PASS = 0
    FAIL = 0

    def check(name, cond, detail=""):
        nonlocal PASS, FAIL
        if cond:
            print(f"PASS: {name}")
            PASS += 1
        else:
            print(f"FAIL: {name}" + (f" — {detail}" if detail else ""))
            FAIL += 1

    # -----------------------------------------------------------------------
    # Section 1: _pool_of() pure function
    # -----------------------------------------------------------------------
    check("_pool_of: wa-worker exact",         _pool_of("wa-worker")             == "wa-worker")
    check("_pool_of: wa-worker-adhoc",         _pool_of("wa-worker-adhoc-x")     == "wa-worker")
    check("_pool_of: wa-worker-adhoc-long",    _pool_of("wa-worker-adhoc-123abc")== "wa-worker")
    check("_pool_of: gastown.dog exact",       _pool_of("gastown.dog")           == "gastown.dog")
    check("_pool_of: dog- prefix",             _pool_of("dog-gawispy8c0mr")      == "gastown.dog")
    check("_pool_of: dog-short",               _pool_of("dog-3")                 == "gastown.dog")
    check("_pool_of: crew name passthrough",   _pool_of("oracle-wa")             == "oracle-wa")
    check("_pool_of: mila-wa passthrough",     _pool_of("mila-wa")               == "mila-wa")
    check("_pool_of: batista-ps passthrough",  _pool_of("batista-ps")            == "batista-ps")
    check("_pool_of: empty string",            _pool_of("") == "")

    # -----------------------------------------------------------------------
    # Section 2: _check_pool_dead() cycle behavior with temp state dir
    # -----------------------------------------------------------------------
    _tmpdir = _tempfile.mkdtemp(prefix="irg-selftest-")
    try:
        global STATE_FILE
        _orig_state = STATE_FILE
        STATE_FILE = os.path.join(_tmpdir, "state.json")

        _mail_log = []
        _orig_run = subprocess.run

        def _stub_run(cmd, **kw):
            """Capture gc mail calls; silently swallow everything else (notify, etc.)."""
            if isinstance(cmd, (list, tuple)) and len(cmd) >= 2 and cmd[0] == "gc" and cmd[1] == "mail":
                assert len(cmd) >= 3 and cmd[2] == "send", f"gc mail missing 'send' subcommand: {cmd}"
                _mail_log.append(list(cmd))
            class _R:
                returncode = 0
            return _R()

        subprocess.run = _stub_run
        try:
            T = 1_782_400_000.0  # fixed epoch for determinism

            # --- Scenario POOL-DEAD-1: 1 cycle with 3 wa-worker zombies → NO alert ---
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]}, T)
            check("POOL-DEAD-1: 1 cycle → no alert (2-cycle hysteresis required)",
                  len(_mail_log) == 0, f"mail_log={_mail_log}")

            # --- Scenario POOL-DEAD-2: 2nd cycle → [POOL-DEAD] alert fires ---
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]}, T + 10)
            check("POOL-DEAD-2: 2 cycles → [POOL-DEAD] mail emitted",
                  len(_mail_log) == 1,
                  f"mail_log={_mail_log}")
            check("POOL-DEAD-2: mail subject contains [POOL-DEAD]",
                  len(_mail_log) == 1 and "[POOL-DEAD]" in " ".join(_mail_log[0]),
                  f"mail_log={_mail_log}")
            check("POOL-DEAD-2: mail subject names wa-worker",
                  len(_mail_log) == 1 and "wa-worker" in " ".join(_mail_log[0]),
                  f"mail_log={_mail_log}")

            # --- Scenario POOL-DEAD-3: 3rd cycle within cooldown → NO repeat alert ---
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]}, T + 20)
            check("POOL-DEAD-3: within cooldown → no repeat alert",
                  len(_mail_log) == 1, f"mail_log={_mail_log}")

            # --- Scenario POOL-DEAD-4: after cooldown expires → alert fires again ---
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]},
                             T + POOL_DEAD_COOLDOWN + 30)
            check("POOL-DEAD-4: after cooldown → second alert fires",
                  len(_mail_log) == 2, f"mail_log={_mail_log}")

            # Reset state for remaining scenarios
            _shutil.rmtree(STATE_FILE + ".pool-dead", ignore_errors=True)
            _mail_log.clear()

            # --- Scenario POOL-DEAD-5: <POOL_DEAD_MIN zombies → no alert even after 2 cycles ---
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2"]}, T)        # 2 < POOL_DEAD_MIN=3
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2"]}, T + 10)
            check("POOL-DEAD-5: below threshold (<3 zombies) → no alert",
                  len(_mail_log) == 0, f"mail_log={_mail_log}")

            # --- Scenario POOL-DEAD-6: pool recovers between cycles → counter resets ---
            _shutil.rmtree(STATE_FILE + ".pool-dead", ignore_errors=True)
            _mail_log.clear()
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]}, T)        # cycle 1: zombie
            _check_pool_dead({}, T + 10)                                             # cycle 2: recovered (0 zombies)
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]}, T + 20)  # cycle 3: zombie again
            check("POOL-DEAD-6: recovery resets counter → no premature alert",
                  len(_mail_log) == 0, f"mail_log={_mail_log}")

            # --- Scenario POOL-DEAD-7: gastown.dog pool also triggers correctly ---
            _shutil.rmtree(STATE_FILE + ".pool-dead", ignore_errors=True)
            _mail_log.clear()
            _check_pool_dead({"gastown.dog": ["d1", "d2", "d3", "d4"]}, T)
            _check_pool_dead({"gastown.dog": ["d1", "d2", "d3", "d4"]}, T + 10)
            check("POOL-DEAD-7: gastown.dog pool fires after 2 cycles",
                  len(_mail_log) == 1 and "gastown.dog" in " ".join(_mail_log[0]),
                  f"mail_log={_mail_log}")

            # --- Scenario POOL-DEAD-8: live session bead excluded (not in zombie list) ---
            # Simulate: pool has 2 real zombies + 1 live-session bead (not passed in)
            _shutil.rmtree(STATE_FILE + ".pool-dead", ignore_errors=True)
            _mail_log.clear()
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2"]}, T)        # 2 zombies (live bead excluded)
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2"]}, T + 10)
            check("POOL-DEAD-8: live-session bead excluded → stays below threshold",
                  len(_mail_log) == 0, f"mail_log={_mail_log}")

            # --- Scenario POOL-DEAD-9: mail non-zero exit → failure log is emitted ---
            import io as _io
            _shutil.rmtree(STATE_FILE + ".pool-dead", ignore_errors=True)
            _mail_log.clear()

            def _stub_run_fail(cmd, **kw):
                """Like _stub_run but gc mail returns rc=1 (simulate Dolt down / args rejected)."""
                if isinstance(cmd, (list, tuple)) and len(cmd) >= 2 and cmd[0] == "gc" and cmd[1] == "mail":
                    assert len(cmd) >= 3 and cmd[2] == "send", f"gc mail missing 'send' subcommand: {cmd}"
                    _mail_log.append(list(cmd))
                    class _RF:
                        returncode = 1
                        stderr = b"dolt: connection refused"
                    return _RF()
                class _R:
                    returncode = 0
                return _R()

            subprocess.run = _stub_run_fail
            _cap = _io.StringIO()
            _orig_stdout = _sys.stdout
            _sys.stdout = _cap
            try:
                _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]}, T)         # cycle 1
                _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]}, T + 10)    # cycle 2 → fires
            finally:
                _sys.stdout = _orig_stdout
                subprocess.run = _stub_run  # restore main test stub

            _out = _cap.getvalue()
            check("POOL-DEAD-9: mail non-zero exit → failure log emitted",
                  "[POOL-DEAD] mail non-zero exit" in _out,
                  f"captured={_out!r}")
            check("POOL-DEAD-9: failure log names the pool",
                  "wa-worker" in _out and "rc=1" in _out,
                  f"captured={_out!r}")

        finally:
            subprocess.run = _orig_run
            STATE_FILE = _orig_state
    finally:
        _shutil.rmtree(_tmpdir, ignore_errors=True)

    # -----------------------------------------------------------------------
    # Section 3: ga-hkpwv pool-zombie reclaim scenarios (pure-function tests)
    # Tests is_reclaimable_inprogress_story(), pool_has_live_worker(),
    # reclaim_decision(), and _has_needs_human_label(). No bd/gc/git calls.
    # -----------------------------------------------------------------------

    T_pz = 1_782_500_000.0  # fixed epoch for determinism

    # --- PZ-1: bare pool-template assignee qualifies WITHOUT Pilot markers ---
    check("PZ-1a: bare wa-worker assignee qualifies without Pilot markers",
          is_reclaimable_inprogress_story([], assignee="wa-worker"))
    check("PZ-1b: non-pool assignee without markers → False (scope unchanged)",
          not is_reclaimable_inprogress_story([], assignee="oracle-wa"))
    check("PZ-1c: no assignee, no markers → False",
          not is_reclaimable_inprogress_story([], assignee=None))

    # --- PZ-2: gate:needs-human / prefix variants block pool-zombie reclaim ---
    check("PZ-2a: wa-worker + gate:needs-human (exact) → False (parked)",
          not is_reclaimable_inprogress_story(["gate:needs-human"], assignee="wa-worker"))
    check("PZ-2b: wa-worker + gate:needs-human:on-device → False (prefix variant)",
          not is_reclaimable_inprogress_story(["gate:needs-human:on-device"], assignee="wa-worker"))
    check("PZ-2c: wa-worker + gate:needs-human:routing → False (prefix variant)",
          not is_reclaimable_inprogress_story(["gate:needs-human:routing"], assignee="wa-worker"))
    check("PZ-2d: _has_needs_human_label exact match",
          _has_needs_human_label(["gate:needs-human"]))
    check("PZ-2e: _has_needs_human_label prefix variant",
          _has_needs_human_label(["gate:needs-human:technical"]))
    check("PZ-2f: _has_needs_human_label absent → False",
          not _has_needs_human_label(["story:in-flight", "pilot:dispatched"]))

    # --- PZ-3: pool_has_live_worker — asleep/drained sessions → pool dead ---
    _asleep_sessions = [
        {"template": "wa-worker", "session_name": "wa-worker-adhoc-aaa",
         "agent_name": "wa-worker-adhoc-aaa", "state": "asleep",
         "id": "sid-s1", "name": "wa-worker-adhoc-1", "alias": "",
         "last_active": "0001-01-01T00:00:00Z"},
        {"template": "wa-worker", "session_name": "wa-worker-adhoc-bbb",
         "agent_name": "wa-worker-adhoc-bbb", "state": "drained",
         "id": "sid-s2", "name": "wa-worker-adhoc-2", "alias": "",
         "last_active": "0001-01-01T00:00:00Z"},
    ]
    check("PZ-3a: pool_has_live_worker: all asleep → False (reclaim eligible)",
          not pool_has_live_worker("wa-worker", _asleep_sessions, T_pz))
    check("PZ-3b: pool_has_live_worker: drained included → False",
          not pool_has_live_worker("wa-worker",
              [_asleep_sessions[1]], T_pz))

    # --- PZ-4: pool_has_live_worker — active session with recent last_active → True ---
    _active_fresh_ts = _irg_datetime.datetime.fromtimestamp(
        T_pz - 60, tz=_irg_datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _active_sessions = [
        {"template": "wa-worker", "session_name": "wa-worker-adhoc-ccc",
         "agent_name": "wa-worker-adhoc-ccc", "state": "active",
         "id": "sid-a1", "name": "wa-worker-adhoc-3", "alias": "",
         "last_active": _active_fresh_ts},
    ]
    check("PZ-4: pool_has_live_worker: active + fresh last_active → True (NOT reclaimed)",
          pool_has_live_worker("wa-worker", _active_sessions, T_pz))

    # --- PZ-5: pool_has_live_worker — unparseable last_active → conservative → True ---
    _active_bad_ts_sessions = [
        {"template": "wa-worker", "session_name": "wa-worker-adhoc-ddd",
         "agent_name": "wa-worker-adhoc-ddd", "state": "active",
         "id": "sid-b1", "name": "wa-worker-adhoc-4", "alias": "",
         "last_active": "not-a-timestamp"},
    ]
    check("PZ-5: pool_has_live_worker: active + unparseable last_active → True (conservative)",
          pool_has_live_worker("wa-worker", _active_bad_ts_sessions, T_pz))

    # --- PZ-5b: pool_has_live_worker — unknown session state → conservative → True ---
    _unknown_state_sessions = [
        {"template": "wa-worker", "session_name": "wa-worker-adhoc-eee",
         "agent_name": "wa-worker-adhoc-eee", "state": "unknown_state",
         "id": "sid-c1", "name": "wa-worker-adhoc-5", "alias": "",
         "last_active": "0001-01-01T00:00:00Z"},
    ]
    check("PZ-5b: pool_has_live_worker: unknown state → True (conservative, NOT reclaimed)",
          pool_has_live_worker("wa-worker", _unknown_state_sessions, T_pz))

    # --- PZ-6: reclaim_decision with POOL_ZOMBIE_TTL, stranded 2h+ → reclaim ---
    check("PZ-6a: reclaim_decision: pool zombie, stranded>POOL_ZOMBIE_TTL → reclaim",
          reclaim_decision(
              has_live_session=False, has_recent_branch=False,
              seconds_stranded=POOL_ZOMBIE_TTL + 1, reclaim_count=0,
              has_needs_human=False, has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "reclaim")
    check("PZ-6b: reclaim_decision: pool zombie, stranded<POOL_ZOMBIE_TTL → noop (still waiting)",
          reclaim_decision(
              has_live_session=False, has_recent_branch=False,
              seconds_stranded=POOL_ZOMBIE_TTL - 1, reclaim_count=0,
              has_needs_human=False, has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "noop")

    # --- PZ-7: has_recent_branch → noop (safety rail, even for pool zombies) ---
    check("PZ-7: reclaim_decision: branch exists → noop (branch safety rail holds)",
          reclaim_decision(
              has_live_session=False, has_recent_branch=True,
              seconds_stranded=POOL_ZOMBIE_TTL + 1, reclaim_count=0,
              has_needs_human=False, has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "noop")

    # --- PZ-8: has_live_session → noop (live pool worker blocks reclaim) ---
    check("PZ-8: reclaim_decision: live session → noop (live pool worker safety rail)",
          reclaim_decision(
              has_live_session=True, has_recent_branch=False,
              seconds_stranded=POOL_ZOMBIE_TTL + 1, reclaim_count=0,
              has_needs_human=False, has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "noop")

    # --- PZ-9: 3 thrashes → escalate (no 4th reclaim) ---
    check("PZ-9: reclaim_decision: reclaim_count=MAX_RECLAIMS(3) → escalate",
          reclaim_decision(
              has_live_session=False, has_recent_branch=False,
              seconds_stranded=POOL_ZOMBIE_TTL + 1, reclaim_count=MAX_RECLAIMS,
              has_needs_human=False, has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "escalate")
    check("PZ-9b: reclaim_decision: reclaim_count=2 (< MAX_RECLAIMS) → reclaim not yet escalate",
          reclaim_decision(
              has_live_session=False, has_recent_branch=False,
              seconds_stranded=POOL_ZOMBIE_TTL + 1, reclaim_count=MAX_RECLAIMS - 1,
              has_needs_human=False, has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "reclaim")

    # --- PZ-10: non-wa-worker pool not affected ---
    check("PZ-10: pool_has_live_worker: no matching template → False (empty pool)",
          not pool_has_live_worker("wa-worker",
              [{"template": "oracle-wa", "state": "active", "id": "x",
                "name": "x", "session_name": "x", "alias": "", "agent_name": "x",
                "last_active": _active_fresh_ts}],
              T_pz))

    # -----------------------------------------------------------------------
    # Section 4: get_branch_recent — segment-based matching (BR-*)
    # Verifies that crew/<pool>/<id> branches are correctly matched, that
    # prefix-collisions are rejected, and that git errors fail safe.
    # Uses monkeypatched subprocess.run — no real git calls.
    # -----------------------------------------------------------------------
    T_br = 1_782_500_000.0  # fixed epoch for determinism

    _orig_run_br = subprocess.run
    _orig_time_fn = time.time

    def _make_git_stub(refs_lines, fetch_ok=True):
        """Return a subprocess.run stub serving fake git ref output."""
        def _stub(cmd, **kw):
            class _R:
                returncode = 0
                stdout = ""
                stderr = b""
            if not isinstance(cmd, (list, tuple)):
                return _R()
            if "fetch" in cmd:
                if not fetch_ok:
                    raise OSError("simulated fetch failure")
                return _R()
            if "for-each-ref" in cmd:
                r = _R()
                r.stdout = ("\n".join(refs_lines) + "\n") if refs_lines else ""
                return r
            return _R()
        return _stub

    try:
        time.time = lambda: T_br  # freeze "now" so age comparisons are deterministic

        # BR-1: crew/wa-worker/<id> with recent commit → True (branch rail blocks reclaim).
        # This is the previously-broken false-reclaim scenario (ga-hkpwv):
        # before the fix, only fix/* / feature/* prefixes were checked, so this
        # branch was invisible and the bead would have been reclaimed (RED → GREEN).
        subprocess.run = _make_git_stub([
            f"refs/remotes/origin/crew/wa-worker/wa-quoy {int(T_br - 60)}"
        ])
        check("BR-1: crew/wa-worker/<id> recent branch → True (branch rail blocks reclaim; was RED before fix)",
              get_branch_recent("wa-quoy"))

        # BR-2: prefix-collision — bead wa-oly, branch crew/wa-worker/wa-oly1 → False.
        # wa-oly1 must NOT match wa-oly (no separator after the bead-id).
        subprocess.run = _make_git_stub([
            f"refs/remotes/origin/crew/wa-worker/wa-oly1 {int(T_br - 60)}"
        ])
        check("BR-2: prefix-collision wa-oly vs wa-oly1 → False (no false match, still reclaimable)",
              not get_branch_recent("wa-oly"))

        # BR-3: feat/<id> branch → True (new prefix, previously unchecked).
        subprocess.run = _make_git_stub([
            f"refs/remotes/origin/feat/wa-quoy {int(T_br - 60)}"
        ])
        check("BR-3: feat/<id> recent branch → True",
              get_branch_recent("wa-quoy"))

        # BR-4: fix/<id> branch → True (legacy pattern; preserved).
        subprocess.run = _make_git_stub([
            f"refs/remotes/origin/fix/wa-quoy {int(T_br - 60)}"
        ])
        check("BR-4: fix/<id> recent branch → True (legacy pattern preserved)",
              get_branch_recent("wa-quoy"))

        # BR-5: for-each-ref returns non-zero → True (fail-safe: do NOT reclaim).
        def _fail_on_for_each_ref(cmd, **kw):
            class _Err:
                returncode = 1
                stdout = ""
                stderr = b"error"
            class _OK:
                returncode = 0
                stdout = ""
                stderr = b""
            if isinstance(cmd, (list, tuple)) and "for-each-ref" in cmd:
                return _Err()
            return _OK()
        subprocess.run = _fail_on_for_each_ref
        check("BR-5: for-each-ref non-zero exit → True (fail-safe: do NOT reclaim)",
              get_branch_recent("wa-quoy"))

        # BR-6: fetch raises exception → True (fail-safe: do NOT reclaim).
        subprocess.run = _make_git_stub([], fetch_ok=False)
        check("BR-6: fetch exception → True (fail-safe: do NOT reclaim)",
              get_branch_recent("wa-quoy"))

        # BR-7: branch exists but commit is stale (> RECLAIM_TTL ago) → False.
        subprocess.run = _make_git_stub([
            f"refs/remotes/origin/crew/wa-worker/wa-quoy {int(T_br - RECLAIM_TTL - 100)}"
        ])
        check("BR-7: stale branch (>RECLAIM_TTL old) → False (reclaim allowed)",
              not get_branch_recent("wa-quoy"))

        # BR-8: no branch matching bead-id at all → False (reclaim allowed).
        subprocess.run = _make_git_stub([
            f"refs/remotes/origin/crew/wa-worker/other-bead {int(T_br - 60)}"
        ])
        check("BR-8: no matching branch → False (reclaim allowed)",
              not get_branch_recent("wa-quoy"))

    finally:
        time.time = _orig_time_fn
        subprocess.run = _orig_run_br

    # -----------------------------------------------------------------------
    # Section 5: ga-hkpwv gap fix — concrete wa-worker-adhoc-<hex> scenarios
    # Tests _is_ephemeral_pool_assignee(), concrete_adhoc_session_is_live(),
    # is_reclaimable_inprogress_story() for concrete adhoc, and the full
    # reclaim pipeline for concrete adhoc assignees. No bd/gc/git calls.
    # -----------------------------------------------------------------------

    T_az = 1_782_600_000.0  # fixed epoch for determinism

    # --- AZ-0: _is_ephemeral_pool_assignee() — covers bare template + concrete adhoc ---
    check("AZ-0a: _is_ephemeral_pool_assignee: bare wa-worker → True",
          _is_ephemeral_pool_assignee("wa-worker"))
    check("AZ-0b: _is_ephemeral_pool_assignee: wa-worker-adhoc-deadbeef → True",
          _is_ephemeral_pool_assignee("wa-worker-adhoc-deadbeef"))
    check("AZ-0c: _is_ephemeral_pool_assignee: gastown.dog → False (not in scope)",
          not _is_ephemeral_pool_assignee("gastown.dog"))
    check("AZ-0d: _is_ephemeral_pool_assignee: oracle-wa (crew) → False",
          not _is_ephemeral_pool_assignee("oracle-wa"))

    # --- AZ-1: concrete adhoc qualifies in is_reclaimable_inprogress_story without Pilot markers ---
    check("AZ-1a: is_reclaimable_inprogress_story: wa-worker-adhoc-deadbeef without markers → True",
          is_reclaimable_inprogress_story([], assignee="wa-worker-adhoc-deadbeef"))
    check("AZ-1b: _pool_of: wa-worker-adhoc-deadbeef → wa-worker (feeds POOL-DEAD bucket)",
          _pool_of("wa-worker-adhoc-deadbeef") == "wa-worker")

    # --- AZ-2: concrete_adhoc_session_is_live — asleep session → False (eligible for reclaim) ---
    _adhoc_dead_session = [
        {"id": "sid-x1", "name": "wa-worker-adhoc-1",
         "session_name": "wa-worker-adhoc-deadbeef",
         "alias": "", "agent_name": "wa-worker-adhoc-deadbeef",
         "state": "asleep", "last_active": "0001-01-01T00:00:00Z"},
    ]
    check("AZ-2: concrete_adhoc_session_is_live: session asleep → False (eligible for reclaim)",
          not concrete_adhoc_session_is_live(
              "wa-worker-adhoc-deadbeef", _adhoc_dead_session, T_az))

    # --- AZ-3: full pipeline — concrete adhoc + dead session + stranded 2h+ → reclaim ---
    check("AZ-3: reclaim_decision: adhoc+dead session, no branch, stranded>POOL_ZOMBIE_TTL → reclaim",
          reclaim_decision(
              has_live_session=concrete_adhoc_session_is_live(
                  "wa-worker-adhoc-deadbeef", _adhoc_dead_session, T_az),
              has_recent_branch=False,
              seconds_stranded=POOL_ZOMBIE_TTL + 1,
              reclaim_count=0,
              has_needs_human=False,
              has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "reclaim")

    # --- AZ-4: concrete_adhoc_session_is_live — ACTIVE + fresh last_active → True (no false reclaim) ---
    _adhoc_fresh_ts = _irg_datetime.datetime.fromtimestamp(
        T_az - 60, tz=_irg_datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _adhoc_live_session = [
        {"id": "sid-x2", "name": "wa-worker-adhoc-2",
         "session_name": "wa-worker-adhoc-deadbeef",
         "alias": "", "agent_name": "wa-worker-adhoc-deadbeef",
         "state": "active", "last_active": _adhoc_fresh_ts},
    ]
    check("AZ-4: concrete_adhoc_session_is_live: active + fresh last_active → True (NOOP; no false reclaim)",
          concrete_adhoc_session_is_live(
              "wa-worker-adhoc-deadbeef", _adhoc_live_session, T_az))

    # --- AZ-5: branch rail — concrete adhoc + branch exists → NOOP ---
    check("AZ-5: reclaim_decision: adhoc dead session BUT branch exists → noop (branch rail)",
          reclaim_decision(
              has_live_session=False,
              has_recent_branch=True,
              seconds_stranded=POOL_ZOMBIE_TTL + 1,
              reclaim_count=0,
              has_needs_human=False,
              has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "noop")

    # --- AZ-6: conservatism — unknown state → ALIVE → NOOP ---
    _adhoc_unknown_state_session = [
        {"id": "sid-x3", "name": "wa-worker-adhoc-3",
         "session_name": "wa-worker-adhoc-deadbeef",
         "alias": "", "agent_name": "wa-worker-adhoc-deadbeef",
         "state": "unknown_state", "last_active": "0001-01-01T00:00:00Z"},
    ]
    check("AZ-6: concrete_adhoc_session_is_live: unknown state → True (conservative; NOOP)",
          concrete_adhoc_session_is_live(
              "wa-worker-adhoc-deadbeef", _adhoc_unknown_state_session, T_az))

    # --- AZ-7: session gone (not in session list at all) → dead → eligible for reclaim ---
    check("AZ-7: concrete_adhoc_session_is_live: session gone (empty list) → False (eligible)",
          not concrete_adhoc_session_is_live("wa-worker-adhoc-deadbeef", [], T_az))

    # --- AZ-8: non-wa-worker assignees NOT swept (scope stays wa-worker family) ---
    check("AZ-8: _is_ephemeral_pool_assignee: dog-gawispy8c0mr → False (not in scope)",
          not _is_ephemeral_pool_assignee("dog-gawispy8c0mr"))
    check("AZ-8b: is_reclaimable_inprogress_story: dog-gawispy8c0mr without markers → False",
          not is_reclaimable_inprogress_story([], assignee="dog-gawispy8c0mr"))

    # --- AZ-9: bare wa-worker regression — existing pool-wide behavior unchanged ---
    check("AZ-9: _is_ephemeral_pool_assignee: bare wa-worker still detected (regression check)",
          _is_ephemeral_pool_assignee("wa-worker"))
    check("AZ-9b: is_reclaimable_inprogress_story: bare wa-worker still qualifies (regression check)",
          is_reclaimable_inprogress_story([], assignee="wa-worker"))

    # --- AZ-DUP: duplicate identifier — dead first, live second → live wins (scan-all hardening) ---
    # Scenario: two sessions share the same concrete adhoc identifier.
    # The FIRST is asleep/drained (dead). The SECOND is active with a fresh last_active.
    # Before the fix an early `return False` on the dead session would declare the bead
    # reclaimable even though a live successor exists → false reclaim that kills a live build.
    # After the fix: continue scanning; the live session wins → bead is NOT reclaimed.
    _fresh_az_dup = _irg_datetime.datetime.fromtimestamp(
        T_az - 60, tz=_irg_datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _adhoc_dup_sessions = [
        {"id": "sid-dup1", "name": "wa-worker-adhoc-dupbeef",
         "session_name": "wa-worker-adhoc-dupbeef",
         "alias": "", "agent_name": "wa-worker-adhoc-dupbeef",
         "state": "asleep",
         "last_active": "0001-01-01T00:00:00Z"},
        {"id": "sid-dup2", "name": "wa-worker-adhoc-dupbeef",
         "session_name": "wa-worker-adhoc-dupbeef",
         "alias": "", "agent_name": "wa-worker-adhoc-dupbeef",
         "state": "active",
         "last_active": _fresh_az_dup},
    ]
    check("AZ-DUP: concrete_adhoc_session_is_live: dead first + live second → True (live successor wins; no false reclaim)",
          concrete_adhoc_session_is_live(
              "wa-worker-adhoc-dupbeef", _adhoc_dup_sessions, T_az))

    # -----------------------------------------------------------------------
    # Section 6: ga-lrglm — list_gate_active_source_beads() sling
    # back-reference resolution (SB-*). Stubs subprocess.run to serve canned
    # `bd list --label type:quality-gate-marker ...` and `bd show <ids>`
    # responses; no real bd/network calls.
    # -----------------------------------------------------------------------

    _orig_run_sb = subprocess.run

    def _stub_bd(markers_by_gatelbl, titles_by_id, list_fails=False, show_fails=False):
        """Build a subprocess.run stub for list_gate_active_source_beads().

        markers_by_gatelbl: {gate_lbl: [[marker_labels...], ...]} — for each
          gate-status label queried, the marker beads (each a list of its own
          labels) to return.
        titles_by_id: {bead_id: title} — canned `bd show` response titles.
        """
        class _R:
            def __init__(self, rc, out):
                self.returncode = rc
                self.stdout = out
                self.stderr = ""

        def _run(cmd, **kw):
            if isinstance(cmd, (list, tuple)) and len(cmd) >= 2 and cmd[0] == "bd" and cmd[1] == "list":
                if list_fails:
                    # rc=0 + unparseable stdout simulates a parse failure (SB-7:
                    # fail-SAFE → None). A bare non-zero exit is a separate scenario,
                    # stubbed directly in SB-7b below — also fail-SAFE → None as of
                    # ga-ap7od (a non-zero exit means the query FAILED; real `bd list`
                    # returns rc=0 + "[]" for zero matches, verified live).
                    return _R(0, "{not valid json")
                # cmd shape: ["bd","list","--label","type:quality-gate-marker","--label",gate_lbl,"--json"]
                gate_lbl = cmd[5] if len(cmd) > 5 else ""
                markers = markers_by_gatelbl.get(gate_lbl, [])
                payload = [{"id": f"marker-{i}", "labels": lbls} for i, lbls in enumerate(markers)]
                return _R(0, json.dumps(payload))
            if isinstance(cmd, (list, tuple)) and len(cmd) >= 2 and cmd[0] == "bd" and cmd[1] == "show":
                if show_fails:
                    return _R(1, "")
                ids = [a for a in cmd[2:] if a != "--json"]
                payload = [{"id": i, "title": titles_by_id.get(i, "")} for i in ids]
                return _R(0, json.dumps(payload))
            return _R(0, "")
        return _run

    try:
        # --- SB-1: no active markers at all → empty set (and no back-ref lookup needed) ---
        subprocess.run = _stub_bd({}, {})
        _sb1 = list_gate_active_source_beads()
        check("SB-1: no active markers → empty frozenset",
              _sb1 == frozenset(), f"got={_sb1!r}")

        # --- SB-2: direct source-bead whose title does NOT follow the sling
        # convention (e.g. a rig-native bug bead) → only itself in the set ---
        subprocess.run = _stub_bd(
            {"gate-status:queued": [["source-bead:ga-native1", "type:quality-gate-marker"]]},
            {"ga-native1": "some rig-native title with no sling convention"},
        )
        _sb2 = list_gate_active_source_beads()
        check("SB-2: non-sling source-bead → set contains only itself (no spurious back-ref)",
              _sb2 == frozenset({"ga-native1"}), f"got={_sb2!r}")

        # --- SB-3: sling-dispatched fix ("fix bug X: ...") → set contains BOTH
        # the sling bead AND the original bug it names ---
        subprocess.run = _stub_bd(
            {"gate-status:queued": [["source-bead:ga-djjeq", "type:quality-gate-marker"]]},
            {"ga-djjeq": "fix bug ga-d2jil: Pilot NEVERSTARTED gate-marker guard checks..."},
        )
        _sb3 = list_gate_active_source_beads()
        check("SB-3: sling 'fix bug' title → set contains sling id AND original bug id",
              _sb3 == frozenset({"ga-djjeq", "ga-d2jil"}), f"got={_sb3!r}")

        # --- SB-4: 'build story' convention (feature/story tier) also resolves ---
        subprocess.run = _stub_bd(
            {"gate-status:ready": [["source-bead:ga-slingA", "type:quality-gate-marker"]]},
            {"ga-slingA": "build story ga-storyX: Add the frobnicator widget"},
        )
        _sb4 = list_gate_active_source_beads()
        check("SB-4: sling 'build story' title → set contains sling id AND original story id",
              _sb4 == frozenset({"ga-slingA", "ga-storyX"}), f"got={_sb4!r}")

        # --- SB-5: multi-redispatch robustness (ga-d2jil's real 4-dispatch chain).
        # Only the FIRST historical sling (ga-djjeq) still has an active marker;
        # the bug's OWN pilot.sling_bead metadata would by now point at a LATER
        # sling (ga-7q8x1) that has no marker at all. Resolution must succeed
        # from ga-djjeq's title alone — it never reads pilot.sling_bead. ---
        subprocess.run = _stub_bd(
            {"gate-status:queued": [["source-bead:ga-djjeq", "type:quality-gate-marker"]]},
            {"ga-djjeq": "fix bug ga-d2jil: Pilot NEVERSTARTED gate-marker guard..."},
            # Deliberately no entry for ga-7q8x1 — proves resolution doesn't need it.
        )
        _sb5 = list_gate_active_source_beads()
        check("SB-5: multi-redispatch — 1st-of-4 sling still resolves original bug (metadata-independent)",
              "ga-d2jil" in _sb5 and "ga-djjeq" in _sb5, f"got={_sb5!r}")

        # --- SB-6: bd-show (title-resolution) failure → fail-OPEN, keeps the
        # directly-active set, does NOT collapse the whole cycle to None ---
        subprocess.run = _stub_bd(
            {"gate-status:queued": [["source-bead:ga-djjeq", "type:quality-gate-marker"]]},
            {}, show_fails=True,
        )
        _sb6 = list_gate_active_source_beads()
        check("SB-6: bd-show failure during back-ref resolution → fail-OPEN (direct set preserved, not None)",
              _sb6 == frozenset({"ga-djjeq"}), f"got={_sb6!r}")

        # --- SB-7: bd-list returning unparseable JSON → fail-SAFE, whole cycle → None
        # (pre-existing contract; regression check — the back-ref addition must not
        # weaken it) ---
        subprocess.run = _stub_bd({}, {}, list_fails=True)
        _sb7 = list_gate_active_source_beads()
        check("SB-7: bd-list unparseable JSON → fail-SAFE None (pre-existing contract unchanged)",
              _sb7 is None, f"got={_sb7!r}")

        # --- SB-7b: bd-list non-zero exit → fail-SAFE None (ga-ap7od). Real `bd list`
        # returns rc=0 + "[]" for zero matches (verified live); a non-zero exit only
        # ever signals a query FAILURE (e.g. transient Dolt contention), so it must
        # trip the same fail-safe as SB-7 rather than being silently treated as "no
        # results". This inverts what this check locked in prior to ga-ap7od — that
        # old assumption was itself the bug: a real query failure on just one
        # gate_lbl silently dropped that label's active markers from the set. ---
        def _stub_bd_nonzero(cmd, **kw):
            class _RC:
                returncode = 1
                stdout = ""
                stderr = ""
            return _RC()
        subprocess.run = _stub_bd_nonzero
        _sb7b = list_gate_active_source_beads()
        check("SB-7b: bd-list non-zero exit → fail-SAFE None (ga-ap7od: was wrongly treated as empty)",
              _sb7b is None, f"got={_sb7b!r}")

        # --- SB-8: multiple active markers, only SOME are slings → mixed
        # resolution (direct ids + resolved back-refs, no cross-contamination) ---
        subprocess.run = _stub_bd(
            {
                "gate-status:queued": [
                    ["source-bead:ga-djjeq", "type:quality-gate-marker"],
                    ["source-bead:ga-native1", "type:quality-gate-marker"],
                ],
            },
            {
                "ga-djjeq": "fix bug ga-d2jil: ...",
                "ga-native1": "a directly-dispatched bead, no sling wrapper",
            },
        )
        _sb8 = list_gate_active_source_beads()
        check("SB-8: mixed direct + sling markers → union is correct, no cross-contamination",
              _sb8 == frozenset({"ga-djjeq", "ga-d2jil", "ga-native1"}), f"got={_sb8!r}")
    finally:
        subprocess.run = _orig_run_sb

    # --- SB-9: _SLING_TITLE_RE pure-regex edge cases (no subprocess involved) ---
    check("SB-9a: 'fix bug' matches and captures id up to colon",
          bool(_SLING_TITLE_RE.match("fix bug ga-abc12: some title")) and
          _SLING_TITLE_RE.match("fix bug ga-abc12: some title").group(1) == "ga-abc12")
    check("SB-9b: 'build story' matches and captures id up to colon",
          bool(_SLING_TITLE_RE.match("build story wa-xyz9: some title")) and
          _SLING_TITLE_RE.match("build story wa-xyz9: some title").group(1) == "wa-xyz9")
    check("SB-9c: unrelated title does not match",
          _SLING_TITLE_RE.match("investigate: something weird happened") is None)
    check("SB-9d: title missing the colon separator does not match",
          _SLING_TITLE_RE.match("fix bug ga-abc12 no colon here") is None)

    # -----------------------------------------------------------------------
    # Section 7: ga-qfo3 — list_live_sling_source_beads() sling→original
    # live-session resolution (SL-*). Stubs subprocess.run to serve canned
    # `bd list --status in_progress --json` responses; no real bd calls.
    #
    # Root cause (confirmed from the ga-qfo3 incident's launchd log): Pilot's
    # dispatch flow marks the ORIGINAL bug/story bead story:in-flight but
    # assigns the live builder session to a separate SLING bead instead
    # (title "fix bug <id>: ..." / "build story <id>: ..."). The guard's own
    # "started stranded clock" log line showed assignee='' for the ORIGINAL
    # bead (ga-z6uo) the whole time it was being live-built via its sling
    # (ga-vw39) — session_is_live() was checking the wrong bead's assignee
    # field, so a bead with a genuinely live builder got reclaimed at 31min
    # idle ("no_live_session no_recent_branch").
    # -----------------------------------------------------------------------

    _orig_run_sl = subprocess.run

    def _stub_inprogress(beads, list_fails=False, nonzero=False):
        """Build a subprocess.run stub for list_live_sling_source_beads()'s
        `bd list --status in_progress --json` query.

        beads: list of bead dicts (id/title/assignee/updated_at) to return.
        """
        class _R:
            def __init__(self, rc, out):
                self.returncode = rc
                self.stdout = out
                self.stderr = ""

        def _run(cmd, **kw):
            if (isinstance(cmd, (list, tuple)) and len(cmd) >= 2
                    and cmd[0] == "bd" and cmd[1] == "list"):
                if nonzero:
                    return _R(1, "")
                if list_fails:
                    return _R(0, "{not valid json")
                return _R(0, json.dumps(beads))
            return _R(0, "")
        return _run

    _sl_fresh_ts = _irg_datetime.datetime.fromtimestamp(
        T_pz - 30, tz=_irg_datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _sl_live_sessions = [
        {"id": "sid-sl1", "name": "gastown.dog-2", "session_name": "dog-ga5e06",
         "alias": "gastown.dog-2", "agent_name": "dog-ga5e06",
         "state": "active", "last_active": _sl_fresh_ts},
    ]

    try:
        # --- SL-1: sling bead in_progress + live-session assignee →
        # original id resolved into the protected set ---
        subprocess.run = _stub_inprogress([
            {"id": "ga-vw39", "title": "fix bug ga-z6uo: chronic Dolt handle bug",
             "assignee": "dog-ga5e06", "updated_at": ""},
        ])
        _sl1 = list_live_sling_source_beads(_sl_live_sessions, T_pz)
        check("SL-1: live sling assignee → original bug id resolved into protected set",
              _sl1 == frozenset({"ga-z6uo"}), f"got={_sl1!r}")

        # --- SL-2: sling bead in_progress but assignee's session is DEAD →
        # original NOT protected (correctly reclaimable) ---
        subprocess.run = _stub_inprogress([
            {"id": "ga-vw39", "title": "fix bug ga-z6uo: chronic Dolt handle bug",
             "assignee": "dog-ga5e06", "updated_at": ""},
        ])
        _sl2 = list_live_sling_source_beads([], T_pz)  # no live sessions at all
        check("SL-2: sling assignee's session is dead/gone → original NOT protected",
              _sl2 == frozenset(), f"got={_sl2!r}")

        # --- SL-3: in_progress bead whose title does NOT follow the sling
        # convention (e.g. a plain crew/dog task) → no spurious protection ---
        subprocess.run = _stub_inprogress([
            {"id": "ga-plain1", "title": "run the weekly Dolt backup",
             "assignee": "dog-ga5e06", "updated_at": ""},
        ])
        _sl3 = list_live_sling_source_beads(_sl_live_sessions, T_pz)
        check("SL-3: non-sling title → empty set (no spurious protection)",
              _sl3 == frozenset(), f"got={_sl3!r}")

        # --- SL-4: sling bead in_progress but UNCLAIMED (empty assignee) →
        # not protected (matches the pre-claim window; nothing to protect yet) ---
        subprocess.run = _stub_inprogress([
            {"id": "ga-vw39", "title": "fix bug ga-z6uo: chronic Dolt handle bug",
             "assignee": "", "updated_at": ""},
        ])
        _sl4 = list_live_sling_source_beads(_sl_live_sessions, T_pz)
        check("SL-4: unclaimed sling (empty assignee) → not protected",
              _sl4 == frozenset(), f"got={_sl4!r}")

        # --- SL-5: 'build story' convention also resolves (feature/story tier) ---
        subprocess.run = _stub_inprogress([
            {"id": "ga-slingB", "title": "build story ga-storyY: Add the frobnicator",
             "assignee": "dog-ga5e06", "updated_at": ""},
        ])
        _sl5 = list_live_sling_source_beads(_sl_live_sessions, T_pz)
        check("SL-5: sling 'build story' title → original story id resolved",
              _sl5 == frozenset({"ga-storyY"}), f"got={_sl5!r}")

        # --- SL-6: bd-list non-zero exit → fail-SAFE None (mirrors ga-ap7od) ---
        subprocess.run = _stub_inprogress([], nonzero=True)
        _sl6 = list_live_sling_source_beads(_sl_live_sessions, T_pz)
        check("SL-6: bd-list non-zero exit → fail-SAFE None",
              _sl6 is None, f"got={_sl6!r}")

        # --- SL-7: bd-list unparseable JSON → fail-SAFE None ---
        subprocess.run = _stub_inprogress([], list_fails=True)
        _sl7 = list_live_sling_source_beads(_sl_live_sessions, T_pz)
        check("SL-7: bd-list unparseable JSON → fail-SAFE None",
              _sl7 is None, f"got={_sl7!r}")

        # --- SL-8: END-TO-END regression for the actual ga-qfo3 incident shape.
        # The ORIGINAL bug bead (ga-z6uo) carries story:in-flight with its OWN
        # assignee empty (exactly as the launchd log showed); its live builder
        # is only visible via the sling bead's assignee. Verify the full
        # has_live_session computation — session_is_live() on the empty
        # assignee alone (the pre-fix behavior) plus the sling-owner set OR'd
        # in (the fix) — now correctly protects it, so reclaim_decision is
        # "noop" instead of the "reclaim" the incident actually produced. ---
        subprocess.run = _stub_inprogress([
            {"id": "ga-vw39", "title": "fix bug ga-z6uo: chronic Dolt handle bug",
             "assignee": "dog-ga5e06", "updated_at": ""},
        ])
        _sl8_live_sling_owners = list_live_sling_source_beads(_sl_live_sessions, T_pz)
        _sl8_own_assignee_live = session_is_live("", _sl_live_sessions, T_pz)
        check("SL-8a: pre-fix signal — original bead's OWN (empty) assignee never matches a live session",
              _sl8_own_assignee_live is False, f"got={_sl8_own_assignee_live!r}")
        _sl8_has_live_session = _sl8_own_assignee_live or ("ga-z6uo" in _sl8_live_sling_owners)
        check("SL-8b: fix — OR'ing in the sling-owner set makes has_live_session True for ga-z6uo",
              _sl8_has_live_session is True, f"got={_sl8_has_live_session!r}")
        _sl8_decision = reclaim_decision(
            has_live_session=_sl8_has_live_session,
            has_recent_branch=False,  # ga-vw39 had no branch yet either, per the incident report
            seconds_stranded=RECLAIM_TTL + 60,  # past the 25min TTL, like the real incident (31min)
            reclaim_count=0,
            has_needs_human=False,
            has_dispatching_marker=False,
        )
        check("SL-8c: reclaim_decision — noop instead of the false 'reclaim' seen in the incident",
              _sl8_decision == "noop", f"got={_sl8_decision!r}")
    finally:
        subprocess.run = _orig_run_sl

    print(f"\nResults: {PASS} passed, {FAIL} failed")
    return FAIL == 0


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
    if "--selftest" in _sys.argv:
        ok = _selftest()
        _sys.exit(0 if ok else 1)
    main()
