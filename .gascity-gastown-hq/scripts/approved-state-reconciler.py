#!/usr/bin/env python3
"""approved-state-reconciler.py — ensure every story:approved bead is flowing, routed, or alarmed.

WHY THIS EXISTS (2026-06-28): on 2026-06-27/28 the pipeline sat idle all night with 18
story:approved beads, of which 0 were actually buildable by a headless code worker. 10
needed a physical phone (on-device WA warming), 4 needed human judgment, 1 was externally
blocked, 3 were post-build. The painel counted all 18 as "approved" — the operator saw a
contradiction ("approved + nothing building") and correctly diagnosed a system failure. It
WAS: the approval gate approves work the code-pipeline cannot execute, and nothing ejects it.

THE GUARANTEE (spec §4, v1 forcing-function):
  For every story:approved open bead, within a bounded time, exactly one of these is true:
  1. it is in-flight or dispatched (the machine is building it), OR
  2. it has been routed out of story:approved into its true state
     (story:needs-device / story:needs-human / story:blocked) and operator notified, OR
  3. it is assumed-buildable but NOT flowing → ALARM (buildable work is starving; a real
     dispatch failure to investigate). "Approved + 0 execution, silently" is IMPOSSIBLE.

SAFE DEFAULT (cardinal rule): a bead is assumed buildable unless it has an EXPLICIT
non-buildable signal. Ambiguous content → stays approved + ALARMS if starving.
NEVER route out a bead lacking an explicit signal — hiding real work is the one outcome
worse than the status quo.

ROUTING SIGNALS (explicit LABELS only — keywords NEVER trigger routing):
  • needs-device: label story:needs-device ONLY.
  • needs-human: label gate:needs-human* (prefix), story:needs-human, or bare
    needs-human ONLY (ga-m0ksy: bare added — ~half the city's actual usage
    of this signal, not an edge case; see _classify()'s own comment).
  • blocked: label blocked/story:blocked ONLY.
  • post-build: label gate:passed → remove story:approved only (delivery owns it).
  Keywords (warming, aquecimento, celular, etc.) trigger a LOW-PRIORITY FLAG only
  (ledger note + comment); the bead stays story:approved until a human/refino adds the
  explicit label. This prevents buildable beads like "Consolidar painel warming
  (/aquecimento)" — a frontend dashboard — from being hidden (wa-yez60 regression).

SAFETY:
  • DRY_RUN (APPROVED_RECONCILER_DRY_RUN=1): log intended actions, mutate nothing.
  • Kill-switch (APPROVED_RECONCILER_ENABLED, default 1).
  • Multi-store fail-open: per-store query error skips that store, never crashes cycle.
  • Idempotent: already-routed bead (no story:approved) never returned by query.
  • Per-bead cooldowns on both route and alarm (~30 min) to prevent churn/spam.
  • Fail-open on pilot liveness error: assume pilot dead → no alarm.

LAUNCHD: one-shot, StartInterval=600 — launchd controls cadence, not internal sleep.
DPW: add com.gascity.approved-state-reconciler to DPW_CRITICAL after Mayor deploys.
"""
import datetime
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from gc_ledger import gc_ledger_append as _arc_ledger
except ImportError:
    def _arc_ledger(name, data, *, fail_open=False):  # type: ignore
        pass
import park_labels
import gate_queue_backlog
from gate_queue_backlog import (
    _gate_queue_depth, _gate_queue_throughput, _gate_queue_suppress_reason,
    _gate_queue_body_line, GATE_QUEUE_WINDOW_MIN,
)

# ── paths ─────────────────────────────────────────────────────────────────────
CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
PILOT_LOG = os.path.join(CITY, ".gc/logs/pilot-dispatcher.log")
GATE_DISPATCHER_LOG = os.path.join(CITY, ".gc/logs/quality-gate-dispatcher.log")
# PILOT_DISPATCHABLE_FILE (ga-tky97): the Pilot's own fully-filtered, dispatch-
# ordered candidate queue, emitted fresh every sweep (ttl_seconds=600) by
# _pilot_emit_dispatchable() in pilot-dispatcher.sh. Same env var name as that
# script so both can be overridden together; same default path.
PILOT_DISPATCHABLE_FILE = os.environ.get(
    "PILOT_DISPATCHABLE_FILE",
    os.path.join(os.environ.get("HOME", os.path.expanduser("~")), ".gc/pilot-dispatchable.json"))
# PILOT_SWEEP_PAUSE_STATE_FILE (ga-nq0jo): whether the Pilot's LAST sweep
# exited with dispatched=0 for a whole-sweep pause (quota-limited ga-x3nmz,
# cross-stage yield ga-d0hz3), written by _pilot_write_sweep_pause_state() in
# pilot-dispatcher.sh. Deliberately a SEPARATE file from
# PILOT_DISPATCHABLE_FILE above, not a new field on it — that contract
# already has other consumers (the painel) depending on its current shape.
PILOT_SWEEP_PAUSE_STATE_FILE = os.environ.get(
    "PILOT_SWEEP_PAUSE_STATE_FILE",
    os.path.join(os.environ.get("HOME", os.path.expanduser("~")), ".gc/pilot-sweep-pause-state.json"))
# QPOS_ABSENT/QPOS_UNREADABLE (ga-tky97 GATE-FEEDBACK fix): a bead's queue
# position can fail to resolve to an int for two causally different reasons —
# the dispatch queue snapshot itself was unreadable this cycle (unmeasured),
# or the snapshot was read fine and the bead simply wasn't in it (measured,
# confirmed absent). Both used to collapse to bare `None`, so a later delta
# comparison could assert "unchanged" across a cycle where one side was never
# actually measured. These sentinels (JSON-serializable strings, distinct from
# any int position) keep the two apart through state persistence and re-read.
QPOS_ABSENT = "absent"
QPOS_UNREADABLE = "unreadable"
NOTIFY_BIN = os.environ.get("NOTIFY_BIN", "/Users/athos/.local/bin/notify")
GC_BIN = os.environ.get("GC_BIN", "gc")
BD_BIN = os.environ.get("BD_BIN", "bd")
BD_LIST_CACHED = os.path.join(CITY, "scripts/bd-list-cached.sh")  # ga-xwza2: read-cache shim (ga-48xcv) — drop-in ["bash", BD_LIST_CACHED] prefix replaces BD_BIN at read-only (list/show/query) call sites; only-list/show/query safety boundary lives in the shim itself, so a write accidentally routed through it still passes straight to the real bd, unaffected
FLOW_AUTHORITY_FILE = os.environ.get(
    "ARC_FLOW_AUTHORITY_FILE",
    os.path.join(CITY, ".gc/runtime/flow-authority.json"))
STATE_FILE = os.environ.get(
    "ARC_STATE_FILE",
    os.path.join(CITY, ".gc/approved-state-reconciler-state.json"))

# IMPORTANT: each root must be the BEAD STORE path (bd -C <root>), NOT the git repo root.
# For HQ the bead store is .gascity-gastown-hq (== CITY), NOT /Users/athos/gt — those are
# different paths. Using the bare git root causes bd -C to fail silently (rc=1, fail-open).
RIG_ROOTS = os.environ.get(
    "ARC_RIG_ROOTS",
    "/Users/athos/gt/.gascity-gastown-hq:"
    "/Users/athos/gt/whatsapp_automation:"
    "/Users/athos/gt/property_scrapers",
).split(":")

MAYOR_ADDR = os.environ.get("ARC_MAYOR_ADDR", "mayor")

# ── knobs (all env-overridable) ───────────────────────────────────────────────
ENABLED = os.environ.get("APPROVED_RECONCILER_ENABLED", "1") == "1"
DRY_RUN = os.environ.get("APPROVED_RECONCILER_DRY_RUN", "0") == "1"
# STARVE_MIN: a buildable bead should dispatch within ~2 pilot sweeps (5min each) + margin.
STARVE_MIN = int(os.environ.get("STARVE_MIN", "20"))
# STARVE_MIN_PRI2/PRI3: lower-priority beads legitimately queue longer behind higher-
# priority work under a fixed-size pool (e.g. a priority-3 "não-urgente" bead behind a
# handful of priority-1/2 bugs) — that's fair-share ordering, not a dispatch failure.
# Scale the grace window by priority so low-priority beads don't alarm on the same SLA
# as urgent ones. Priority 0/1 keep the base STARVE_MIN (most conservative).
STARVE_MIN_PRI2 = int(os.environ.get("STARVE_MIN_PRI2", str(STARVE_MIN * 2)))
STARVE_MIN_PRI3 = int(os.environ.get("STARVE_MIN_PRI3", str(STARVE_MIN * 6)))
# RECLAIM_CAP: mirrors MAX_RECLAIMS in inflight-reclaim-guard.py (scripts/
# inflight-reclaim-guard.py:106) and _FILTER_RECLAIM_CAP in pilot-dispatcher.sh:1111.
# No single source of truth yet (same duplication pattern as POOL_BY_RIG_BASENAME
# below) — keep in sync by hand.
RECLAIM_CAP = int(os.environ.get("ARC_RECLAIM_CAP", "3"))
# BRANCH_STRANDED_STALE_HOURS (ga-32u6s): a crew/fix branch's last commit older than
# this, still unmerged into origin/main, with the bead itself unassigned (guaranteed
# by the time _branch_stranded_reason() is consulted — see its call site) is treated
# as an abandoned build rather than active work. Same default/semantics as
# PILOT_ORPHAN_BRANCH_STALE_HOURS in pilot-dispatcher.sh's ga-8jxe1 classifier
# (packs/town-deltas/assets/pilot-dispatcher.sh:353) — reusing an already-vetted
# number instead of inventing a new one, independently override-able via its own env var.
BRANCH_STRANDED_STALE_HOURS = int(os.environ.get("ARC_BRANCH_STRANDED_STALE_HOURS", "48"))
# FLOW_GRACE_MIN: recently-dispatched beads are assumed to be flowing.
FLOW_GRACE_MIN = int(os.environ.get("FLOW_GRACE_MIN", "10"))
# Per-bead cooldowns to prevent churn/spam on repeated runs.
ROUTE_COOLDOWN_SEC = int(os.environ.get("ARC_ROUTE_COOLDOWN_SEC", "1800"))   # 30min
ALARM_COOLDOWN_SEC = int(os.environ.get("ARC_ALARM_COOLDOWN_SEC", "1800"))   # 30min
BD_TIMEOUT = int(os.environ.get("ARC_BD_TIMEOUT", "25"))
# Pilot alive window: if no Pilot sweep-complete within this many minutes → pilot dead.
PILOT_ALIVE_WINDOW_MIN = int(os.environ.get("ARC_PILOT_ALIVE_WINDOW_MIN", "20"))
LOG_TAIL = int(os.environ.get("ARC_LOG_TAIL", "2000"))
# GATE_LOG_TAIL/GATE_QUEUE_WINDOW_MIN moved to gate_queue_backlog.py (ga-ahn3v) —
# imported above alongside the 4 gate-queue-backlog functions.
# PILOT_SWEEP_HISTORY_* (ga-tma6wc): a separate, much larger tail budget + lookback
# cap for _pilot_sweep_pause_history() — that function answers "how many of the
# Pilot's sweeps across THIS BEAD'S WHOLE WAIT were a deliberate whole-sweep pause",
# which can span many hours (a starving bead's age_min), unlike LOG_TAIL's 2000-line
# budget sized only for PILOT_ALIVE_WINDOW_MIN's ~20min liveness check above.
# Measured live 2026-08-22 against the real pilot-dispatcher.log: ~150-170 lines
# between consecutive "Pilot sweep complete" markers under normal load, with one
# observed burst to ~2427 during a heavy dispatch-decision sweep; 20000 gives
# multi-day margin under typical load and comfortable same-day margin even across a
# couple of bursts. Capped separately at 24h of wall-clock lookback so a bead that
# has been starving for days (e.g. ga-il5hs, 49h) doesn't force an ever-growing read
# — matches the daily granularity the Mayor's own manual measurement used (ga-tma6wc:
# "91 sweeps completos" counted over one day). Both are fail-safe in the UNDER
# direction only: _pilot_sweep_pause_history() returns unmeasurable (None, None)
# rather than a falsely-low count whenever the read tail doesn't reach back the full
# window — see that function's own docstring.
PILOT_SWEEP_HISTORY_TAIL = int(os.environ.get("ARC_PILOT_SWEEP_HISTORY_TAIL", "20000"))
PILOT_SWEEP_HISTORY_MAX_WINDOW_MIN = int(
    os.environ.get("ARC_PILOT_SWEEP_HISTORY_MAX_WINDOW_MIN", "1440"))
FLOW_AUTHORITY_TTL_SEC = int(os.environ.get("ARC_FLOW_AUTHORITY_TTL_SEC", "3600"))
# Marker label stamped on a bead after its first Step 1b keyword-flag comment. Idempotency
# gate (ga-1iz2e/AC1): a bead that already carries this label is skipped — comment once,
# then wait for a human/refino to add the real routing label. No reset path needed: once
# the real label lands, _classify() routes the bead away before Step 1b is reached again.
FLAG_REVIEW_LABEL = os.environ.get("ARC_FLAG_REVIEW_LABEL", "needs-label-review")

# ── on-device detection patterns ──────────────────────────────────────────────
# Each matches an EXPLICIT on-device signal in bead title/body/AC.
# "aquecimento" and "warming" match chip-warming on a live phone; the context of
# the bead (WA automation) makes these unambiguous on-device signals in this codebase.
_ONDEVICE_PATS = [
    re.compile(r'\bon-device\b', re.I),
    re.compile(r'\baquecimento\b', re.I),
    re.compile(r'\bwarming\b', re.I),
    re.compile(r'\bUIAutomator\b', re.I),
    re.compile(r'\bscreencap\b', re.I),
    re.compile(r'\btela do\b', re.I),
    re.compile(r'\bcelular\b', re.I),
    re.compile(r'DPR\s+foreground', re.I),
]

# ── blocked-wording detection patterns ────────────────────────────────────────
_BLOCKED_PATS = [
    re.compile(r'bloqueado por', re.I),
    re.compile(r'quando o datastore', re.I),
    re.compile(r'aguardando\s+\S', re.I),   # "aguardando <serviço>"
]

# ── log timestamp pattern ─────────────────────────────────────────────────────
_TS_RE = re.compile(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]")
_PILOT_SWEEP_RE = re.compile(r"Pilot sweep complete:")
# _PILOT_SWEEP_PAUSED_RE (ga-tma6wc): matches the exact 4 whole-sweep pause/yield
# reasons pilot-dispatcher.sh logs right where it also calls
# _pilot_write_sweep_pause_state(1, ...) — quota-limited/ram-pressure/quiet-hours
# ("... dispatched=0 (paused: ...)") and cross-stage-yield ("... dispatched=0
# (deferred: ...)"). Deliberately the SAME 4 reasons _pilot_sweep_pause_suppress_
# reason() already treats as suppression-worthy (ga-nq0jo) — this regex counts
# HISTORY across many sweeps, that function checks only the latest one.
_PILOT_SWEEP_PAUSED_RE = re.compile(
    r"Pilot sweep complete: dispatched=0 \((?:paused|deferred):")

# ── test seams (monkeypatched in --selftest) ───────────────────────────────────
# These module-level callables let selftests redirect I/O without spawning subprocesses.
# None = use the real implementation; any callable = use that callable instead.
_bd_approved = None         # (rig_root) -> list[dict]|None; None return = query error
_bd_label_add = None        # (rig_root, bead_id, label) -> bool
_bd_label_remove = None     # (rig_root, bead_id, label) -> bool
_bd_comment = None          # (rig_root, bead_id, text) -> bool
_do_notify = None           # (msg, prio) -> None
_do_mail_mayor = None       # (subject, body) -> bool
_read_pilot_log_lines = None  # () -> list[str]
_bd_gate_markers = None     # () -> list[dict]|None; OPEN quality-gate-markers in the HQ store
_bd_blocked = None          # (rig_root) -> list[dict]|None; None return = query error
_bd_has_built_branch = None  # (bead_id) -> bool; True iff a crew/*/<id> or fix/<id>-*
                              # branch exists (local or origin remote-tracking) anywhere
_bd_branch_stranded = None  # (bead_id) -> (repo, ref, age_days)|None; ga-32u6s orphan-branch probe
# _bd_gate_queue_markers/_read_gate_log_lines moved to gate_queue_backlog.py (ga-ahn3v) —
# selftest scenarios below stub them as gate_queue_backlog.<name>, not a local global.
_read_pilot_dispatchable_file = None  # () -> dict|None; parsed+freshness-checked
                                        # pilot-dispatchable.json (ga-tky97 test seam)
_pilot_dispatchable_reason_file = None  # () -> "absent"|"malformed"|"stale"|None
                                          # (ga-abfcdz test seam for the companion
                                          # classifier below, independent of the
                                          # _read_pilot_dispatchable_file seam above)
_read_pilot_sweep_pause_state_file = None  # () -> dict|None; parsed+freshness-checked
                                             # pilot-sweep-pause-state.json (ga-nq0jo test seam)


# ── guarded subprocess ────────────────────────────────────────────────────────
def _sh(args, timeout=20):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def _log(msg):
    print("[arc] %s" % msg, flush=True)


# ── state persistence ─────────────────────────────────────────────────────────
def _load_state():
    try:
        with open(STATE_FILE) as f:
            d = json.load(f)
            if isinstance(d, dict):
                d.setdefault("routed", {})
                d.setdefault("alarmed", {})
                d.setdefault("first_seen_approved", {})
                d.setdefault("flagged", {})
                d.setdefault("reclaim_exhausted", {})
                d.setdefault("branch_stranded", {})
                return d
    except Exception:
        pass
    return {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {},
            "reclaim_exhausted": {}, "branch_stranded": {}}


def _save_state(state):
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w") as f:
            json.dump(state, f)
    except Exception as e:
        _log("WARN: failed to save state: %r" % e)


def _prune_state(state, now):
    """Prune state entries older than 7 days to prevent unbounded growth.

    Pruning is conservative: a stale entry that survives at worst suppresses one
    cooldown re-trigger — not a safety issue. Better than unbounded memory growth.

    NOTE: "alarmed" entries are either a bare epoch float (legacy, pre-AC3) or a
    {"last": epoch, "count": N, "fp": ...} dict (AC3 escalating backoff) — pull
    the timestamp out of either shape rather than assuming a bare number.
    """
    cutoff = now - 7 * 24 * 3600
    for key in ("routed", "alarmed", "first_seen_approved", "flagged", "reclaim_exhausted",
                "branch_stranded"):
        bucket = state.get(key, {})
        stale = []
        for bid, v in bucket.items():
            ts = v.get("last", 0.0) if isinstance(v, dict) else v
            if ts < cutoff:
                stale.append(bid)
        for bid in stale:
            del bucket[bid]
        if stale:
            _log("  pruned %d stale %s entries" % (len(stale), key))


# ── bd JSON parse ─────────────────────────────────────────────────────────────
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
             "dropped beads stay story:approved (safe) but investigate bd output" % e.pos)
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


# ── bead field helpers ────────────────────────────────────────────────────────
def _get_labels(bead):
    """Normalize bead label field to a frozenset of strings."""
    raw = bead.get("labels") or bead.get("label") or []
    if isinstance(raw, list):
        return frozenset(str(l).strip() for l in raw if l)
    if isinstance(raw, str):
        return frozenset(x.strip() for x in raw.split(",") if x.strip())
    return frozenset()


def _has_prefix(labels, prefix):
    """True if any label equals prefix or starts with prefix + ':'."""
    for lab in labels:
        if lab == prefix or lab.startswith(prefix + ":"):
            return True
    return False


def _parse_reclaim_count(labels):
    """Extract pilot:reclaim-count:N from labels. Returns 0 if absent or invalid.

    Mirrors parse_reclaim_count() in inflight-reclaim-guard.py (that daemon owns
    stamping this label; no shared constants module exists between the two — see
    RECLAIM_CAP comment above).
    """
    for lab in labels:
        if lab.startswith("pilot:reclaim-count:"):
            try:
                return int(lab[len("pilot:reclaim-count:"):])
            except ValueError:
                pass
    return 0


# ── extra explicit non-buildable label prefixes (ga-an81u AC1) ───────────────
# Beyond the routing labels in _classify() and the flowing/gate/pilot checks in
# _process_store(), these prefixes are OTHER explicit non-buildable signals a
# human or another daemon wrote onto the bead — dependency blocks, delegation
# to a named crew, or a pool worker that already declined it. None of these
# ROUTE the bead (the safe-default/never-route rule in _classify() still
# holds) — they only suppress the STARVE ALARM, because they mean "the Pilot's
# generic dispatch path isn't the mechanism in play right now," which is
# exactly the condition the alarm exists to detect the absence of.
#
# Before this fix, NONE of these were recognized: a bead like wa-4e2m8 carrying
# blocked-on:wa-qfp58 + waiting-on:wa-qfp58 (an explicit, human-written
# dependency block) got mailed "This bead has NO explicit non-buildable
# signal" — false, 44 times, ~every 30min, burying real alerts (disk-floor
# CRITICAL) in the same inbox. next-action:<crew>-constroi means "ready, but
# THIS named crew builds it, not the generic pool" (see memory
# pilot-next-action-label-vetoes-own-dispatch) — the opposite of blocked, but
# still not something the Pilot's dispatch path should be blamed for.
#
# "blocked" (ga-yavyq AC1): a bare-prefix sibling of blocked-on: — a human writes
# blocked:<reason> (e.g. blocked:needs-pregao-deployed) to mean "explicitly
# blocked, here's why" without naming a specific bead id (the blocked-on:<id>
# shape doesn't fit when there's no single blocking bead). _has_prefix("blocked-on")
# does NOT match "blocked:needs-pregao-deployed" — different prefix string — so it
# fell through every check and alarmed falsely (wa-4uh2w, twice). Bare "blocked"/
# "story:blocked" (no colon-suffix) are unaffected: _classify() already intercepts
# those upstream as a ROUTE (story:approved -> story:blocked), so this prefix only
# ever matches the colon-namespaced form in practice.
_EXTRA_ALARM_SUPPRESS_PREFIXES = (
    ("blocked-on", "blocked-on:* (dependency block)"),
    ("blocked", "blocked:* (explicit block, reason given, no single blocking bead)"),
    ("waiting-on", "waiting-on:* (dependency block)"),
    ("depends-on", "depends-on:* (dependency block)"),
    ("next-action", "next-action:* (delegated to a named crew, not the generic pool)"),
    ("pool:refused", "pool:refused:* (a pool worker already declined this)"),
    # ga-6om6a: mirrors _filter_candidates' startswith("pilot:refused-reason:") —
    # inflight-reclaim-guard.py's _promote_refusal_labels() promotes pool:refused[:reason]
    # INTO this PERMANENT audit label once a bead survives past its first reclaim cycle
    # (ga-uvfs6), consuming the ephemeral pool:refused one. Without this clause such a
    # bead re-enters candidacy here exactly like a never-refused bead.
    ("pilot:refused-reason", "pilot:refused-reason:* (permanent refusal audit label, ga-uvfs6)"),
    # ga-eu2x (2026-07-30): an ENGINE-WINDOW bead is buildable in principle but by
    # DOCTRINE no pool worker may build it — the fix is a go:embed'd source edit +
    # `go build` + swap of the shared /opt/homebrew/bin/gc binary + town bounce,
    # which is Mayor/operator-coordinated (see the pool:refused:engine-rebuild-required
    # convention in the town-deltas doctrine fragment). The Mayor parks such a bead by
    # adding needs:engine-window + no-auto-dispatch and stripping ctx:ready/exec:auto.
    # Neither park label was in this table, so the parked bead kept matching "NONE of
    # this reconciler's known non-buildable signals" and alarmed as "dispatch path
    # failing" — blaming the Pilot for correctly declining to dispatch it. Same class
    # as the blocked:* miss above: a deliberate park read as a broken dispatch path.
    # This affects the whole engine-window class (ga-yxuab, ga-s2eri, ga-hssb1, …),
    # not just the bead that surfaced it, and would repeat every STARVE_MIN forever.
    ("needs:engine-window", "needs:engine-window (Mayor/operator-coordinated gc engine rebuild — no pool worker may build it)"),
    ("no-auto-dispatch", "no-auto-dispatch (explicitly parked out of automatic dispatch)"),
    # ga-qt0mj: pilot-dispatcher.sh's _filter_candidates has 4 TEXT-based vetoes
    # (engine-rebuild / DECISAO-title / "só o Athos decide" / 🚨 compliance-marker)
    # that scan title+description directly and never touch a label — deliberately,
    # because the equivalent label can be destroyed by the auto-refino --description
    # rewrite before this filter ever runs (see the veto's own comment, ga-fnnyy).
    # Before this entry, a bead vetoed purely by TEXT was invisible here too: this
    # reconciler alarmed "matched NONE of this reconciler's known non-buildable
    # signals" while blind to the real cause, which existed only in the Pilot's log
    # (ga-4oc2k, 70min/14 occurrences). pilot-dispatcher.sh now reconciles
    # pilot:text-veto:<pattern> onto the bead itself every sweep — added while the
    # text matches, REMOVED the moment it stops matching (see
    # _reconcile_text_veto_labels there) — so, unlike pilot:refused-reason above,
    # this signal tracks the CURRENT text, not a permanent audit trail. _has_prefix
    # matches the whole pilot:text-veto:* family from this one entry.
    ("pilot:text-veto", "pilot:text-veto:* (Pilot's prose-only dispatch veto currently matches this bead's title/description — see the label suffix for which pattern, ga-qt0mj)"),
)


def _extra_alarm_suppress_reason(labels):
    """Return a human-readable reason if `labels` carries any of the explicit
    non-buildable prefixes in _EXTRA_ALARM_SUPPRESS_PREFIXES, else None."""
    for prefix, reason in _EXTRA_ALARM_SUPPRESS_PREFIXES:
        if _has_prefix(labels, prefix):
            return reason
    return None


def _bead_text(bead):
    """Combined searchable text from title + body/AC."""
    title = bead.get("title") or bead.get("name") or ""
    body = (bead.get("body") or bead.get("description") or
            bead.get("ac") or bead.get("acceptance_criteria") or "")
    return title + " " + body


def _bead_age_min(bead, now):
    """Minutes since the bead was last updated (proxy for story:approved age)."""
    raw = (bead.get("updated_at") or bead.get("updated") or
           bead.get("created_at") or bead.get("created") or "")
    if not raw:
        return 0.0
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            epoch = time.mktime(time.strptime(raw[:19], fmt))
            return max(0.0, (now - epoch) / 60.0)
        except Exception:
            pass
    return 0.0


# ── classification — explicit LABELS only, no keyword routing ────────────────
def _classify(bead):
    """Return (route_to, signal) or (None, None) if NO explicit label-based signal.

    route_to: one of 'needs-device', 'needs-human', 'blocked', 'post-build', or None.
    signal: human-readable string naming the exact signal that triggered the route.

    §4 HARD RAIL: ONLY explicit LABELS trigger routing. Keywords in title/body are NOT
    sufficient — they appear in buildable code beads (e.g., "Consolidar painel warming
    (/aquecimento)" is a frontend dashboard, not an on-device bead — wa-yez60 regression).
    Keyword detection is handled separately by _keyword_flags() for FLAG EMISSION ONLY.
    """
    labels = _get_labels(bead)

    # ga-hzt8s: label spellings below are sourced from park_labels.py (shared
    # with imparavel-check.py + throughput-stall-watchdog.py) so this routing
    # table can't drift from the other two park-label consumers. The BUCKET
    # SHAPE (routing to a target state) stays local — painel's _travada_reason
    # and imparavel's classify_bead each have their own, not unified here.

    # 1. post-build: gate:passed — the bead already built; delivery owns next state.
    if _has_prefix(labels, park_labels.GATE_PASSED_LABEL):
        for lab in labels:
            if lab == park_labels.GATE_PASSED_LABEL or lab.startswith(park_labels.GATE_PASSED_LABEL + ":"):
                return "post-build", "label %s" % lab
        return "post-build", "gate:passed label present"

    # 2. needs-device: LABEL ONLY.
    if park_labels.NEEDS_DEVICE_LABEL in labels:
        return "needs-device", "label %s" % park_labels.NEEDS_DEVICE_LABEL

    # 3. needs-human: gate:needs-human* (prefix), story:needs-human, or the
    # BARE "needs-human" LABEL — ga-m0ksy: bare was missing here despite
    # being an established, near-equally-common spelling (measured across
    # 3 stores: 10 gate:needs-human, 9 bare needs-human, 6/5 gate:needs-
    # human:technical/:refused, 4 story:needs-human — bare is roughly half
    # the city's actual usage of this signal, not an outlier). A bead
    # correctly parked on human decision with the bare spelling (e.g.
    # wa-41fry, a P0 waiting on an owner-key-exposure decision) was
    # therefore treated as unrouted-and-starving and alarmed every cycle
    # indefinitely. Fixing the reader's incomplete label set, not the 9
    # writers using an already-legitimate spelling (see park_labels.py's
    # NEEDS_HUMAN_BARE_LABEL docstring for why that's the right direction).
    if park_labels.NEEDS_HUMAN_LABEL in labels:
        return "needs-human", "label %s" % park_labels.NEEDS_HUMAN_LABEL
    if park_labels.NEEDS_HUMAN_BARE_LABEL in labels:
        return "needs-human", "label %s" % park_labels.NEEDS_HUMAN_BARE_LABEL
    for lab in labels:
        if lab.startswith(park_labels.GATE_NEEDS_HUMAN_PREFIX):
            return "needs-human", "label %s" % lab

    # 4. blocked: LABEL ONLY (blocked or story:blocked).
    for lab in park_labels.BLOCKED_LABELS:
        if lab in labels:
            return "blocked", "label %s" % lab

    # No explicit label signal → caller assumes buildable (SAFE DEFAULT).
    # Keywords are checked by _keyword_flags() for low-priority flag emission only.
    return None, None


def _keyword_flags(bead):
    """Detect on-device/blocked KEYWORDS in bead text — for FLAG EMISSION ONLY.

    Returns list of (category, keyword_match) tuples.
    NEVER used for routing. Used to emit a low-priority human-review flag when a bead
    has keyword signals but no explicit routing label, so a human/refino can confirm
    and add the real label before the reconciler acts.
    """
    text = _bead_text(bead)
    flags = []
    for pat in _ONDEVICE_PATS:
        m = pat.search(text)
        if m:
            flags.append(("on-device", m.group(0)))
            break  # one flag per category is sufficient
    for pat in _BLOCKED_PATS:
        m = pat.search(text)
        if m:
            flags.append(("blocked", m.group(0)))
            break
    return flags


# ── pilot liveness ────────────────────────────────────────────────────────────
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


def _is_pilot_alive(now):
    """True iff the Pilot logged a sweep-complete within PILOT_ALIVE_WINDOW_MIN.

    Fail-open: if the log is unreadable, returns False (assume pilot dead → no alarm).
    This is the SAFE direction: we never false-alarm when the pilot is merely unreachable.
    Test seam: _read_pilot_log_lines() substitutes the real tail.
    """
    if _read_pilot_log_lines is not None:
        lines = _read_pilot_log_lines()
    else:
        lines = _tail(PILOT_LOG, LOG_TAIL)

    if not lines:
        return False   # fail-open: can't read log → assume dead → no alarm

    window_sec = PILOT_ALIVE_WINDOW_MIN * 60
    for line in reversed(lines):
        if _PILOT_SWEEP_RE.search(line):
            epoch = _ts_epoch(line)
            if epoch is not None and (now - epoch) <= window_sec:
                return True
    return False


def _pilot_sweep_pause_history(now, age_min):
    """Count how many of the Pilot's logged sweep-completions, within this bead's
    own wait window (min(age_min, PILOT_SWEEP_HISTORY_MAX_WINDOW_MIN) minutes back
    from `now`), were a deliberate whole-sweep pause/yield (quota-limited/ram-
    pressure/quiet-hours/cross-stage-yield — the same 4 reasons
    _pilot_sweep_pause_suppress_reason() already treats as suppression-worthy for
    the LATEST sweep, ga-nq0jo; see _PILOT_SWEEP_PAUSED_RE).

    Returns (paused_n, total_m), or (None, None) if unmeasurable — log missing/
    unreadable, OR the read tail doesn't itself reach back the full window
    (mirrors _gate_queue_throughput()'s oldest-timestamp completeness check: an
    undercounted read must never silently report a falsely-low paused fraction —
    root-class:error-vs-empty, same discipline as every sibling measurement in
    this file).

    ga-tma6wc: this is a HISTORY/CONTEXT signal, not a suppression — unlike
    _pilot_sweep_pause_suppress_reason() (latest sweep only, can fully suppress
    the alarm before it ever fires), this looks back across the bead's WHOLE wait
    and is only ever used to ANNOTATE an alarm that is firing anyway. Two real
    alarms (wa-1ccdz age=301min, ga-il5hs age=2954min, both 2026-08-21) each fired
    for a legitimate CURRENT reason — by the time they fired, the suppress-reason
    check had already correctly stopped applying (the pause had cleared, the
    queue-position explanation was exhausted too — verified in
    .gc/logs/approved-state-reconciler.out: both beads logged correct sweep-pause
    "no alarm" suppressions for over an hour earlier in the same wait) — but a
    human reading either alarm in isolation had no way to see that a large chunk
    of that SAME elapsed age was, in fact, RAM-pressure pause time already caught
    correctly by earlier cycles. Reading "dispatch path failing" against the
    bead's full age as if it were 100% unexplained overstates the problem.
    """
    window_min = min(age_min, PILOT_SWEEP_HISTORY_MAX_WINDOW_MIN)
    if _read_pilot_log_lines is not None:
        lines = _read_pilot_log_lines()   # test seam (shared with _is_pilot_alive)
    else:
        lines = _tail(PILOT_LOG, PILOT_SWEEP_HISTORY_TAIL)
    if not lines:
        return None, None

    cutoff = now - window_min * 60
    total = 0
    paused = 0
    oldest_epoch = None
    for line in lines:
        epoch = _ts_epoch(line)
        if epoch is None:
            continue
        if oldest_epoch is None or epoch < oldest_epoch:
            oldest_epoch = epoch
        if epoch < cutoff:
            continue
        if not _PILOT_SWEEP_RE.search(line):
            continue
        total += 1
        if _PILOT_SWEEP_PAUSED_RE.search(line):
            paused += 1

    if oldest_epoch is None or oldest_epoch > cutoff:
        return None, None  # tail doesn't reach back the full window — unmeasurable
    if total == 0:
        return None, None
    return paused, total


def _pilot_sweep_pause_body_line(paused, total):
    """Format a 'Pilot pausado em N dos últimos M sweeps' context line for the
    starving alarm's body (ga-tma6wc) — mirrors _gate_queue_body_line()'s
    convention (gate_queue_backlog.py) of ALWAYS rendering something, NEVER
    silently omitting a dimension the alarm checked, even when the measurement
    itself failed or came back a clean zero."""
    if paused is None or total is None:
        return ("Pilot sweep-pause history: NÃO MEDIDO (pilot-dispatcher.log "
                "indisponível, ou o tail lido não cobre toda a janela de espera "
                "deste bead) — não é possível dizer quanto do atraso acima é "
                "pausa deliberada do Pilot.")
    if paused == 0:
        return ("Pilot sweep-pause history: 0 dos últimos %d sweeps logados "
                "durante a espera deste bead foram pausados deliberadamente — o "
                "atraso acima não é explicado por pausa do Pilot." % total)
    return ("Pilot sweep-pause history: %d dos últimos %d sweeps logados durante "
            "a espera deste bead foram pausados deliberadamente (RAM pressure, "
            "cota 5h, quiet-hours ou cross-stage-yield — ver pilot-dispatcher.log) "
            "— parte do atraso acima é despacho pausado de propósito, não "
            "necessariamente falha de despacho." % (paused, total))


def _pilot_still_held_reason(labels, now):
    """Suppress reason if pilot-dispatcher.sh's _filter_candidates would currently
    treat this bead as held, else None.

    ga-6om6a ROOT CAUSE: this reconciler re-derives "is this buildable" from its
    own hand-maintained label list, which DRIFTS from what the Pilot actually
    decided — two separate implementations of the same judgment. Gate-fix
    attempt 1 (df5279eae) tried to close the gap by tailing the Pilot's own log
    for a recent per-bead refusal line — REJECTED at gate review AND by author
    RE-FIX GUIDANCE: log-scraping is fragile (an id cited inside a DIFFERENT
    bead's refusal/hold line false-matched via unanchored substring search,
    silently swallowing a genuinely-stuck dependency's alarm) and can drift from
    the Pilot's actual label semantics just as easily as the original hand-
    maintained list did.

    CORRECT APPROACH (mayor RE-FIX GUIDANCE, 2026-07-25): evaluate the bead's
    OWN current labels with the SAME rule _filter_candidates applies — do not
    parse anything else's log or text. Mirrors pilot-dispatcher.sh
    _filter_candidates EXACTLY: held iff "pilot:held" is present AND (no
    held-until label exists at all, OR the LATEST/MAX held-until epoch has not
    yet passed). held-until labels ACCUMULATE without pruning (ga-4aree) — an
    older expired stamp must never mask a newer still-valid one, so this takes
    the max of every held-until epoch found, never just the first.

    This does not re-close the exact ga-t1ub9 timing gap (the brief window
    where the label is fully ABSENT between one hold's expiry and the next
    cycle's re-hold — a purely label-based check has no signal to read at that
    instant, by construction) — the mayor's guidance judged that residual, rare
    race window preferable to log-scraping's worse failure mode of silently
    suppressing real alarms on unrelated beads.
    """
    if park_labels.PILOT_HELD_LABEL not in labels:
        return None
    prefix = park_labels.PILOT_HELD_LABEL + "-until:"
    epochs = []
    for lab in labels:
        if lab.startswith(prefix):
            try:
                epochs.append(int(lab[len(prefix):]))
            except ValueError:
                pass
    if not epochs:
        return "pilot:held (no held-until epoch — indefinite hold)"
    latest = max(epochs)
    if latest >= now:
        return "pilot:held-until:%d (not yet expired)" % latest
    return None


# ── flowing check ─────────────────────────────────────────────────────────────
def _is_flowing(bead):
    """True iff the bead shows signs of active dispatch or in-flight execution.

    Checks (in order):
    1. story:in-flight label — definitively being built.
    2. pilot:dispatched label — dispatched by the Pilot (assumed within FLOW_GRACE_MIN
       since the lifecycle-coherence-janitor clears stale pilot:dispatched labels via R4).
    3. gate:reviewing / gate:queued label — the gate is actively working this bead (quality-
       gate-guard.sh:1524-1526 stamps gate:reviewing on the SOURCE bead itself as belt-and-
       suspenders, independent of the marker lookup in built_ids below). A bead in the gate
       is flowing by definition — this reconciler's scope is DISPATCH failures, and a bead
       already past dispatch and into review cannot also be a dispatch failure (ga-6927).
    4. Non-empty assignee that is not 'mayor' — some builder holds it.

    Note: FLOW_GRACE_MIN (default 10min) is the env knob for operators to tune
    how long a dispatched bead is considered "freshly flowing" before alarming.
    """
    labels = _get_labels(bead)
    if "story:in-flight" in labels:
        return True
    if "pilot:dispatched" in labels:
        return True
    if "gate:reviewing" in labels or "gate:queued" in labels:
        return True
    assignee = bead.get("assignee") or ""
    if assignee and assignee not in ("mayor", ""):
        return True
    return False


# ── bd mutation helpers ───────────────────────────────────────────────────────
def _do_label_add(rig_root, bead_id, label):
    if DRY_RUN:
        _log("DRY_RUN: would add label %s to %s" % (label, bead_id))
        return True
    if _bd_label_add is not None:
        return _bd_label_add(rig_root, bead_id, label)
    r = _sh([BD_BIN, "-C", rig_root, "label", "add", bead_id, label, "-q"],
            timeout=BD_TIMEOUT)
    return bool(r and r.returncode == 0)


def _do_label_remove(rig_root, bead_id, label):
    if DRY_RUN:
        _log("DRY_RUN: would remove label %s from %s" % (label, bead_id))
        return True
    if _bd_label_remove is not None:
        return _bd_label_remove(rig_root, bead_id, label)
    r = _sh([BD_BIN, "-C", rig_root, "label", "remove", bead_id, label, "-q"],
            timeout=BD_TIMEOUT)
    return bool(r and r.returncode == 0)


def _do_comment_add(rig_root, bead_id, text):
    if DRY_RUN:
        _log("DRY_RUN: would comment on %s: %s" % (bead_id, text[:60]))
        return True
    if _bd_comment is not None:
        return _bd_comment(rig_root, bead_id, text)
    r = _sh([BD_BIN, "-C", rig_root, "comment", bead_id, text], timeout=BD_TIMEOUT)
    return bool(r and r.returncode == 0)


# ── flow-authority marker ─────────────────────────────────────────────────────
def _write_flow_authority(now, dimension):
    """Write flow-authority.json so other daemons (TSW/PSW/PTH) can defer Mayor mail."""
    try:
        runtime_dir = os.path.dirname(FLOW_AUTHORITY_FILE)
        os.makedirs(runtime_dir, exist_ok=True)
        with open(FLOW_AUTHORITY_FILE, "w") as f:
            json.dump({
                "escalated_at": now,
                "dimension": dimension,
                "authority": "approved-state-reconciler",
                "expires_at": now + FLOW_AUTHORITY_TTL_SEC,
            }, f)
    except Exception as e:
        _log("WARN: failed to write flow-authority marker: %s" % e)


# ── pool capacity check ───────────────────────────────────────────────────────
# rig_root basename -> (session template, max concurrent active/creating sessions).
# Mirrors PILOT_WA_WORKER_MAX / PILOT_PS_WORKER_MAX in pilot-dispatcher.sh (packs/
# town-deltas/assets/pilot-dispatcher.sh:104,109) and agents/{wa,ps}-worker/agent.toml
# max_active_sessions. No single source of truth yet, so keep these in sync by hand.
POOL_BY_RIG_BASENAME = {
    "whatsapp_automation": ("wa-worker", 4),
    "property_scrapers": ("ps-worker", 2),
}


def _pool_has_capacity(rig_root, now):
    """Check if the target builder pool for rig_root has at least one free slot.

    Returns (has_capacity, note):
    - (True, note): pool has capacity OR capacity cannot be determined (conservative alarm).
    - (False, note): pool definitively saturated; bead legitimately queued (no alarm).

    Per spec §4: unknown capacity → alarm conservatively (True return), logging the gap.
    Silently swallowing a starve alarm is worse than a checkable false-positive alarm.

    Mirrors Pilot's own saturation check (pilot-dispatcher.sh ~4163-4171): count sessions
    whose template matches the rig's builder pool and whose state is active or creating,
    compare against that pool's configured max.
    """
    pool = POOL_BY_RIG_BASENAME.get(os.path.basename(rig_root.rstrip("/")))
    if pool is None:
        return True, "capacity unknown — no pool mapping for %s (conservative alarm)" % rig_root
    template, max_active = pool

    proc = _sh([GC_BIN, "session", "list", "--json"], timeout=15)
    if proc is None or proc.returncode != 0 or not (proc.stdout or "").strip():
        return True, "capacity unknown — gc session list failed (conservative alarm)"
    try:
        sessions = json.loads(proc.stdout).get("sessions") or []
    except Exception:
        return True, "capacity unknown — gc session list unparseable (conservative alarm)"

    active = sum(
        1 for s in sessions
        if s.get("template") == template and s.get("state") in ("active", "creating")
    )
    if active >= max_active:
        return False, "%s pool saturated (%d/%d active/creating)" % (template, active, max_active)
    return True, "%s pool has capacity (%d/%d active/creating)" % (template, active, max_active)


# ── route a bead out of story:approved ───────────────────────────────────────
def _route_bead(rig_root, bead, route_to, signal, now, state):
    """Route bead out of story:approved into its true state.

    Removes story:approved, adds the true-state label (except for post-build),
    adds an audit comment. Writes ledger + notify.

    Returns True if the route was logged/executed; False on cooldown or missing id.
    Never mutates anything when DRY_RUN=True.
    """
    bead_id = bead.get("id") or bead.get("issue_id") or ""
    if not bead_id:
        _log("WARN: bead missing id, skipping route")
        return False

    # Per-bead route cooldown — avoid re-routing repeatedly on bd errors.
    last_routed = state.get("routed", {}).get(bead_id, 0.0)
    if now - last_routed < ROUTE_COOLDOWN_SEC:
        _log("  route cooldown active for %s (%.0fmin ago) — skipping" % (
             bead_id, (now - last_routed) / 60.0))
        return False

    title = (bead.get("title") or bead.get("name") or "?")[:80]
    _log("ROUTE %s → %s | signal: %s | %s" % (bead_id, route_to, signal, title))

    if DRY_RUN:
        _log("DRY_RUN: would route %s → story:%s (signal: %s)" % (bead_id, route_to, signal))
        return True  # no state update, no mutations

    if route_to == "post-build":
        # Remove story:approved only; delivery daemon owns the post-build transition.
        comment = ("approved-state-reconciler: removing story:approved — "
                   "gate:passed detected (%s); delivery daemon owns post-build lifecycle." % signal)
        _do_label_remove(rig_root, bead_id, "story:approved")
        _do_comment_add(rig_root, bead_id, comment)
    else:
        new_label = "story:" + route_to
        comment = ("approved-state-reconciler: routed story:approved → %s "
                   "— explicit signal: %s" % (new_label, signal))
        # IMPORTANT 3 (add-before-remove): add new label FIRST; only if that succeeds,
        # remove story:approved. Prevents orphan-limbo (bead with no lifecycle label)
        # if bd fails mid-sequence. If add fails: log, skip remove, skip cooldown → retry.
        add_ok = _do_label_add(rig_root, bead_id, new_label)
        if not add_ok:
            _log("  WARN: label add %s on %s FAILED — NOT removing story:approved; "
                 "skipping cooldown so next cycle retries" % (new_label, bead_id))
            return False  # not counted as routed; no cooldown set
        _do_label_remove(rig_root, bead_id, "story:approved")
        _do_comment_add(rig_root, bead_id, comment)

    # Emit human-touch ledger entry.
    _arc_ledger("human-touch", {
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_daemon": "approved-state-reconciler",
        "stage": "route",
        "bead_id": bead_id,
        "route_to": route_to,
        "signal": signal,
        "rig_root": rig_root,
    }, fail_open=True)

    msg = ("reconciler: %s → story:%s (%s)" % (bead_id, route_to, signal)
           if route_to != "post-build" else
           "reconciler: %s story:approved removed (gate:passed — post-build)" % bead_id)
    if _do_notify is not None:
        _do_notify(msg, 2)
    else:
        _sh([NOTIFY_BIN, "-t", "Reconciler route", "-p", "2", msg], timeout=10)

    state.setdefault("routed", {})[bead_id] = now
    # Clear daemon starve-age so it resets if bead ever returns to story:approved.
    state.setdefault("first_seen_approved", {}).pop(bead_id, None)
    return True


# ── starve alarm ──────────────────────────────────────────────────────────────
# AC3 (ga-an81u): a flat ALARM_COOLDOWN_SEC (30min) re-fired the IDENTICAL
# "dispatch failing" mail for as long as a bead sat starving — one bead
# (wa-4e2m8) hit 44 repeats, burying unrelated real alerts (disk-floor
# CRITICAL) in the same inbox. Escalate instead: the 1st repeat requires 1h
# since the last alarm, the 2nd requires 4h, the 3rd+ requires 12h (a cap, not
# a silence — a persistently-starving bead still gets a heartbeat, just never
# more often than every 12h). A label-set change since the last alarm counts
# as a new incident and resets the escalation immediately — see the AC3
# acceptance text ("escalada exponencial ... ou mudança de estado").
#
# Tiers beyond the baseline are fixed; the baseline itself (count=0, i.e. the
# very first alarm for an incident) deliberately reads the ALARM_COOLDOWN_SEC
# *global* at call time rather than a value captured once at import — that
# global is env-overridable in production and reassigned via globals() in
# _selftest(), and a module-level list literal here would silently freeze the
# import-time value, making a selftest override of ALARM_COOLDOWN_SEC a no-op.
_ALARM_ESCALATION_TIERS_SEC = [3600, 14400, 43200]  # 1h, 4h, 12h(cap) — for count>=1


def _alarm_backoff_sec(count):
    """Required gap since the last alarm before firing the (count+1)th, given
    `count` alarms already fired for the CURRENT incident (0 = never fired —
    the caller's own now-last_alarmed check handles that case regardless of
    what this returns, since last_alarmed=0.0 always exceeds any backoff)."""
    if count <= 0:
        return ALARM_COOLDOWN_SEC
    idx = min(count - 1, len(_ALARM_ESCALATION_TIERS_SEC) - 1)
    return _ALARM_ESCALATION_TIERS_SEC[idx]


def _alarm_record(state, bead_id):
    """Return (last_alarmed_epoch, count, labels_fp) for bead_id.

    Transparently migrates the pre-AC3 state format, where state['alarmed'][id]
    was a bare epoch float (implicitly: exactly one alarm already fired, unknown
    label fingerprint). A None fingerprint is treated as NOT a state-change on
    the next check (see _alarm_starving) so upgrading never causes a surprise
    immediate re-fire for a bead already mid-cooldown at deploy time.
    """
    raw = state.get("alarmed", {}).get(bead_id)
    if raw is None:
        return 0.0, 0, None
    if isinstance(raw, dict):
        return float(raw.get("last", 0.0)), int(raw.get("count", 0)), raw.get("fp")
    try:
        return float(raw), 1, None   # legacy float-only format
    except (TypeError, ValueError):
        return 0.0, 0, None


def _alarm_starving(rig_root, bead, age_min, now, state, gate_depth=None, gate_throughput=None,
                     dispatchable=None):
    """Fire a starve alarm for a buildable bead that has not been dispatched.

    This is case 3 of the core guarantee: the bead matched NONE of this
    reconciler's known non-buildable signals, is not flowing, and has been
    approved longer than STARVE_MIN with the Pilot alive — meaning the dispatch
    path is failing (or a signal this reconciler doesn't recognize yet — the
    mail body says so explicitly, see AC2). The operator MUST investigate.

    Never fires in DRY_RUN mode. See _alarm_backoff_sec()/_ALARM_ESCALATION_TIERS_SEC
    for the per-bead backoff/dedup policy (AC3) — this is no longer a flat cooldown.

    gate_depth/gate_throughput (ga-dbfm9): the once-per-cycle gate-queue backlog
    reading from run_cycle() (None if unmeasurable) — this function only renders
    them into the body via _gate_queue_body_line(); by the time this is called,
    _process_store() has already consulted _gate_queue_suppress_reason() and
    decided the backlog does NOT explain the wait (or couldn't be measured), so
    every alarm that actually fires still needs the context spelled out for the
    operator (AC1).

    dispatchable (ga-tky97): the once-per-cycle Pilot dispatch-queue snapshot
    from run_cycle() (None if unmeasurable) — by the time this is called,
    _process_store() has already consulted _pilot_queue_suppress_reason() and
    decided the bead's queue position does NOT explain the wait, so this only
    renders context via _pilot_queue_body_line() (AC1-AC3) plus a delta against
    the PREVIOUS alarm's recorded position, if any (AC4).
    """
    bead_id = bead.get("id") or bead.get("issue_id") or ""
    if not bead_id:
        return

    labels_fp = ",".join(sorted(_get_labels(bead)))
    last_alarmed, count, prev_fp = _alarm_record(state, bead_id)
    prev_alarm_raw = state.get("alarmed", {}).get(bead_id)
    prev_qpos_known = isinstance(prev_alarm_raw, dict) and "qpos" in prev_alarm_raw
    prev_qpos = prev_alarm_raw.get("qpos") if prev_qpos_known else None
    if prev_qpos_known and prev_qpos is None:
        # Legacy record from before this fix: bare None was written for BOTH
        # ABSENT and UNREADABLE, so which one it was is unrecoverable. Treat
        # it as the conservative side — UNREADABLE — so the delta below never
        # asserts a continuity claim it can't actually back up.
        prev_qpos = QPOS_UNREADABLE
    state_changed = prev_fp is not None and prev_fp != labels_fp
    if state_changed:
        count = 0   # new incident — restart escalation

    if not state_changed and (now - last_alarmed) < _alarm_backoff_sec(count):
        _log("  alarm backoff active for %s (count=%d, last %.0fmin ago, "
             "next in >=%.0fmin) — skipping" % (
             bead_id, count, (now - last_alarmed) / 60.0,
             (_alarm_backoff_sec(count) - (now - last_alarmed)) / 60.0))
        return

    alarm_ordinal = count + 1   # 1 = first alarm for this incident, 2 = first repeat, ...
    title = (bead.get("title") or bead.get("name") or "?")[:80]
    _log("ALARM starving: %s | age=%.0fmin | ordinal=%d%s | %s" % (
         bead_id, age_min, alarm_ordinal,
         " (state changed → escalation reset)" if state_changed else "", title))

    if DRY_RUN:
        _log("DRY_RUN: would alarm starving bead %s (age=%.0fmin, ordinal=%d)" % (
             bead_id, age_min, alarm_ordinal))
        return  # no state update, no mutations

    # PILOT SWEEP-PAUSE HISTORY (ga-tma6wc): measured ONCE here (not inside a
    # _body_line-style pure formatter, matching gate_depth/gate_throughput's own
    # measure-once-in-the-caller convention) so both the subject suffix and the
    # body line below come from the exact same read — see
    # _pilot_sweep_pause_history()'s docstring for why this is a HISTORY signal,
    # distinct from the sweep_pause_reason suppression already checked upstream
    # in _process_store() before this function is ever called.
    pause_n, pause_m = _pilot_sweep_pause_history(now, age_min)
    pause_line = _pilot_sweep_pause_body_line(pause_n, pause_m)
    # Subject stays terse (a notification/inbox-preview surface) — only add the
    # suffix when there's an actual nonzero count to report; "0/M" or "NÃO
    # MEDIDO" in a one-line subject would be noise, unlike in the always-explicit
    # body line above.
    pause_subject_suffix = (" (Pilot pausado %d/%d sweeps recentes)" % (pause_n, pause_m)
                             if pause_n else "")

    # AC4: repeats are a known-issue heartbeat, not a fresh incident — tag the
    # subject distinctly (filterable/collapsible) and demote notify priority so
    # they don't bury a genuinely different alert class (disk-floor, circuit-
    # break, lca) landing in the same inbox window.
    if alarm_ordinal == 1:
        subject = ("Reconciler: buildable bead %s starving %dmin — dispatch failing%s"
                   % (bead_id, int(age_min), pause_subject_suffix))
        notify_prio = 4
    else:
        subject = ("Reconciler: buildable bead %s STILL starving %dmin (repeat #%d) "
                   "— dispatch failing%s" % (bead_id, int(age_min), alarm_ordinal,
                                              pause_subject_suffix))
        notify_prio = 2

    # AC2: the old body asserted "This bead has NO explicit non-buildable signal"
    # as an absolute fact — false whenever the checked-signal list was
    # incomplete (exactly this bug: blocked-on:/waiting-on:/etc. WERE explicit
    # signals the reconciler simply didn't know). Say what was actually
    # checked, and hedge honestly that the list can itself go stale again.
    gate_line = _gate_queue_body_line(gate_depth, gate_throughput, age_min)

    # ga-tky97 AC4: a repeat alarm should say what changed since the last one
    # (position improved/worsened/unchanged), not just repeat the same claim —
    # only meaningful when a PRIOR alarm actually recorded a qpos (a bead's
    # first-ever alarm, or one alarmed before this feature shipped, has none).
    #
    # cur_qpos is one of: an int (0-based queue position, measured), QPOS_ABSENT
    # (queue read fine, bead confirmed not in it), or QPOS_UNREADABLE (the
    # snapshot itself couldn't be read this cycle — unmeasured). GATE-FEEDBACK
    # (attempt 1): collapsing ABSENT and UNREADABLE into bare None let the delta
    # below assert "unchanged" across a comparison where one side was never
    # measured — e.g. the mail body saying both "COULD NOT READ ... UNCERTAIN"
    # and "Since last alarm: unchanged" in the same message. The discriminated
    # values below make an unmeasured operand impossible to compare silently.
    if dispatchable is None:
        cur_qpos = QPOS_UNREADABLE
    else:
        cur_qpos_pos = _pilot_queue_position(bead_id, dispatchable)
        cur_qpos = cur_qpos_pos[0] if cur_qpos_pos is not None else QPOS_ABSENT
    queue_line = _pilot_queue_body_line(bead_id, dispatchable, now)
    if alarm_ordinal > 1 and prev_qpos_known:
        def _qpos_desc(q):
            if q == QPOS_UNREADABLE:
                return "queue unreadable"
            if q == QPOS_ABSENT:
                return "not found in queue"
            return "front of queue (position 1)" if q == 0 else "position %d" % (q + 1)
        if cur_qpos == QPOS_UNREADABLE or prev_qpos == QPOS_UNREADABLE:
            # At least one side was never measured — "unchanged"/"changed" would
            # be a continuity claim neither side can support. Say so explicitly
            # instead (this is the exact contradiction the gate reviewer
            # reproduced: "COULD NOT READ ... UNCERTAIN" next to "unchanged").
            if prev_qpos == QPOS_UNREADABLE and cur_qpos == QPOS_UNREADABLE:
                where = "in the previous cycle and this cycle"
            elif prev_qpos == QPOS_UNREADABLE:
                where = "in the previous cycle"
            else:
                where = "in this cycle"
            queue_line += (" Since last alarm: not comparable — the Pilot "
                            "dispatch queue could not be read %s." % where)
        elif prev_qpos == cur_qpos:
            queue_line += " Since last alarm: unchanged (%s)." % _qpos_desc(cur_qpos)
        else:
            queue_line += " Since last alarm: changed from %s to %s." % (
                _qpos_desc(prev_qpos), _qpos_desc(cur_qpos))

    body = (
        "APPROVED-STATE-RECONCILER: buildable bead starving — dispatch path failing\n\n"
        "Bead: %s — %s\n"
        "Status: story:approved, age: %dmin, not dispatched, pilot alive, "
        "alarm #%d for this incident\n"
        "%s\n"
        "%s\n"
        "%s\n\n"
        "This bead matched NONE of this reconciler's known non-buildable signals\n"
        "(blocked-on:*, waiting-on:*, depends-on:*, next-action:*, pool:refused:*,\n"
        "gate:{needs-fix,failed,queued,reviewing,needs-human}, exec:manual, ctx:thin,\n"
        "pilot:held(-until:*), pilot:reclaim-count:N). It should have been\n"
        "dispatched within %dmin.\n\n"
        "INVESTIGAR:\n"
        "1. tail -40 .gc/logs/pilot-dispatcher.log — o Pilot está varrendo?\n"
        "2. bd -C %s show %s — labels corretos?\n"
        "3. gc rig list — algum rig suspenso?\n"
        "4. Se o Pilot varre e ignora este bead → bug de query ou filtro no pilot-dispatcher.sh.\n"
        "5. Se o bead É legitimamente non-buildable, ele pode precisar de um sinal que\n"
        "   este reconciler ainda não reconhece — ver _process_store()/\n"
        "   _extra_alarm_suppress_reason() em scripts/approved-state-reconciler.py antes\n"
        "   de re-despachar manualmente ou adicionar story:approved de volta.\n"
    ) % (bead_id, title, int(age_min), alarm_ordinal, gate_line, queue_line, pause_line,
         STARVE_MIN, rig_root, bead_id)

    notify_msg = ("STARVE ALARM%s: bead %s story:approved há %dmin, pilot alive, "
                  "não despachado — dispatch path failing" % (
                  "" if alarm_ordinal == 1 else " (repeat #%d)" % alarm_ordinal,
                  bead_id, int(age_min)))

    _arc_ledger("human-touch", {
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_daemon": "approved-state-reconciler",
        "stage": "starve-alarm",
        "bead_id": bead_id,
        "age_min": int(age_min),
        "alarm_ordinal": alarm_ordinal,
        "rig_root": rig_root,
    }, fail_open=True)

    # Dolt-independent: notify fires FIRST and unconditionally.
    if _do_notify is not None:
        _do_notify(notify_msg, notify_prio)
    else:
        _sh([NOTIFY_BIN, "-t", "Starve ALARM", "-p", str(notify_prio), notify_msg], timeout=10)

    if _do_mail_mayor is not None:
        _do_mail_mayor(subject, body)
    else:
        _sh([GC_BIN, "mail", "send", MAYOR_ADDR, "-s", subject, "-m", body, "--notify"],
            timeout=45)

    _write_flow_authority(now, "approved-starve:%s" % bead_id)
    state.setdefault("alarmed", {})[bead_id] = {
        "last": now, "count": alarm_ordinal, "fp": labels_fp, "qpos": cur_qpos,
    }


# ── reclaim-exhausted note (ga-ag16) ──────────────────────────────────────────
def _alarm_reclaim_exhausted(rig_root, bead, reclaim_count, now, state):
    """Emit a ONE-TIME 'reclaim-exhausted' note for a bead at/above RECLAIM_CAP.

    Distinct from _alarm_starving: this is explicitly NOT "dispatch path failing" —
    the pilot correctly backed off after RECLAIM_CAP failed reclaim attempts.
    inflight-reclaim-guard already escalates (gate:needs-human + a "[POOL-ZOMBIE-
    ESCALATED]" mail) the moment reclaim-count crosses the cap — see do_escalate()
    in inflight-reclaim-guard.py. This function does NOT re-mail; it leaves a
    comment + ledger entry for reconciler-side audit trail, and — unlike
    _alarm_starving's ALARM_COOLDOWN_SEC re-fire — never repeats for the same
    bead_id (no cooldown expiry; only pruned after 7 days like other state).
    """
    bead_id = bead.get("id") or bead.get("issue_id") or ""
    if not bead_id:
        return

    if bead_id in state.get("reclaim_exhausted", {}):
        return  # already noted once — never repeat (this is not a recurring alarm)

    title = (bead.get("title") or bead.get("name") or "?")[:80]
    _log("RECLAIM-EXHAUSTED (not dispatch-failing): %s | reclaim=%d/%d | %s" % (
         bead_id, reclaim_count, RECLAIM_CAP, title))

    if DRY_RUN:
        _log("DRY_RUN: would note reclaim-exhausted %s (reclaim=%d)" % (bead_id, reclaim_count))
        return  # no state update, no mutations

    note = (
        "approved-state-reconciler: reclaim-exhausted (%d/%d) — the pilot correctly "
        "backed off after repeated failed reclaims; this is NOT a dispatch failure. "
        "inflight-reclaim-guard should already have escalated this bead "
        "(gate:needs-human). Needs re-route/human triage, not a re-dispatch retry."
    ) % (reclaim_count, RECLAIM_CAP)
    _do_comment_add(rig_root, bead_id, note)

    _arc_ledger("human-touch", {
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_daemon": "approved-state-reconciler",
        "stage": "reclaim-exhausted",
        "bead_id": bead_id,
        "reclaim_count": reclaim_count,
        "rig_root": rig_root,
    }, fail_open=True)

    notify_msg = ("RECLAIM-EXHAUSTED (not dispatch-failing): bead %s reclaimed %d/%d "
                  "times, pilot backed off — needs re-route/human, not re-dispatch" % (
                  bead_id, reclaim_count, RECLAIM_CAP))
    if _do_notify is not None:
        _do_notify(notify_msg, 2)
    else:
        _sh([NOTIFY_BIN, "-t", "Reclaim exhausted", "-p", "2", notify_msg], timeout=10)

    state.setdefault("reclaim_exhausted", {})[bead_id] = now


# ── branch-stranded alert (ga-32u6s) ────────────────────────────────────────────
def _alarm_branch_stranded(rig_root, bead, repo, ref, age_days, now, state):
    """ONE-TIME mail + pilot:orphan-branch label for a bead whose crew/fix branch
    is a stranded orphan: built, unmerged into origin/main, idle past
    BRANCH_STRANDED_STALE_HOURS, unassigned.

    WHY THIS EXISTS (ga-32u6s / wa-juety: 6 days, 83h starving): _filter_built
    (packs/town-deltas/assets/pilot-dispatcher.sh:2148-2175) drops a candidate
    from the dispatch pool FOREVER the moment a matching crew/fix branch merely
    EXISTS — no merge check, no age check, no live-owner check. Pilot's own
    smarter classifier for exactly this situation (_beadid_branch_signal's
    'orphan' verdict, ga-8jxe1, pilot-dispatcher.sh:3065) only ever runs inside
    dispatch_one(), on a candidate that already SURVIVED _filter_built — so for
    the precise case ga-8jxe1 was built to fix, its own classifier is
    unreachable, and the bead never gets pilot:orphan-branch or any other
    signal. This reconciler-side check is an independent backstop that does
    not depend on ever reaching dispatch_one: it reuses the SAME branch-probe
    shape (_real_has_built_branch/_ownership_guard_repos, ga-tkcam) already
    proven correct here, adds the merge-ancestry + age checks ga-8jxe1 already
    validated as the right judgment call, and — critically — actually fires an
    alert instead of silently relying on a label nobody applied.

    Distinct from _alarm_starving: NOT "dispatch path failing". The branch is
    real, finished (or at least real) work sitting unmerged; the correct next
    step is a human triage call (re-anchor vs rebuild vs abandon per the bead's
    own text), not a re-dispatch retry. Like _alarm_reclaim_exhausted, this
    mails/labels ONCE per bead rather than repeating on ALARM_COOLDOWN_SEC —
    the diagnosis doesn't change cycle to cycle until a human acts on it, and
    pilot:orphan-branch (shared vocabulary with ga-8jxe1's own labeling) keeps
    the state durably queryable (`bd list -l pilot:orphan-branch`) without a
    repeat alarm. Never touches the branch itself — deleting it would destroy
    real unmerged work; that decision is explicitly out of scope here.
    """
    bead_id = bead.get("id") or bead.get("issue_id") or ""
    if not bead_id:
        return
    if bead_id in state.get("branch_stranded", {}):
        return  # already alerted once — never repeat

    title = (bead.get("title") or bead.get("name") or "?")[:80]
    repo_name = os.path.basename(repo.rstrip("/")) or repo
    _log("BRANCH-STRANDED (not dispatch-failing): %s | ref=%s | repo=%s | age=%.1fd | %s" % (
         bead_id, ref, repo_name, age_days, title))

    if DRY_RUN:
        _log("DRY_RUN: would alert branch-stranded %s (ref=%s, age=%.1fd)" % (
             bead_id, ref, age_days))
        return  # no state update, no mutations

    subject = ("Reconciler: bead %s has an UNMERGED BUILD BRANCH stranded %dd "
               "— needs re-anchor decision" % (bead_id, int(age_days)))
    body = (
        "APPROVED-STATE-RECONCILER: branch stranded, not a dispatch failure\n\n"
        "Bead: %s — %s\n"
        "Branch: %s (repo %s), last commit ~%.1f days ago, NOT merged into origin/main\n"
        "Bead is unassigned, not flowing, no open gate marker, no formal block "
        "(see approved-state-reconciler's earlier checks this cycle).\n\n"
        "DIAGNOSTICO: trabalho pronto e nao mergeado em %s; decida re-anchor vs "
        "rebuild vs abandon.\n\n"
        "Este NAO e um caso de \"dispatch path failing\": _filter_built "
        "(pilot-dispatcher.sh) veta a candidatura deste bead permanentemente so por "
        "a branch existir, sem checar merge/idade/dono — entao o classificador "
        "inteligente que o Pilot ja tem para essa situacao (ga-8jxe1, "
        "_beadid_branch_signal em dispatch_one()) nunca chega a rodar nele.\n\n"
        "Nao feche nem apague a branch automaticamente — ela pode conter o "
        "entregavel inteiro. Rotulo pilot:orphan-branch aplicado neste bead; "
        "consultavel via `bd list -l pilot:orphan-branch`.\n"
    ) % (bead_id, title, ref, repo_name, age_days, ref)

    notify_msg = ("BRANCH STRANDED: bead %s tem branch %s pronta, nao mergeada ha "
                  "~%.0fd, sem dono — decisao de re-anchor/rebuild/abandon precisa "
                  "de humano" % (bead_id, ref, age_days))

    _arc_ledger("human-touch", {
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_daemon": "approved-state-reconciler",
        "stage": "branch-stranded",
        "bead_id": bead_id,
        "branch": ref,
        "repo": repo_name,
        "age_days": round(age_days, 1),
        "rig_root": rig_root,
    }, fail_open=True)

    if _do_notify is not None:
        _do_notify(notify_msg, 3)
    else:
        _sh([NOTIFY_BIN, "-t", "Branch stranded", "-p", "3", notify_msg], timeout=10)

    if _do_mail_mayor is not None:
        _do_mail_mayor(subject, body)
    else:
        _sh([GC_BIN, "mail", "send", MAYOR_ADDR, "-s", subject, "-m", body, "--notify"],
            timeout=45)

    _do_label_add(rig_root, bead_id, "pilot:orphan-branch")

    state.setdefault("branch_stranded", {})[bead_id] = now


# ── built-bead index ──────────────────────────────────────────────────────────
def _gate_marker_source_beads():
    """Set of bead ids that an OPEN quality-gate-marker points at (label source-bead:<id>).
    Such a bead is BUILT and awaiting the gate — PAST the dispatch stage — so the starve
    alarm must skip it: a built-but-still-story:approved bead is NOT a dispatch failure.
    (A marker can even be orphaned by the HQ-only gate scan — ga-pnugy — leaving the bead
    story:approved forever; that is a GATE bug, not a dispatch failure.)

    Markers are ALWAYS created in the HQ store (CITY), never in a rig's own store —
    quality-gate-guard.sh:1517 always runs `bd -C "$GC_CITY" label add "$MARKER_ID"
    "source-bead:$BEAD_ID"` regardless of which rig the source bead lives in. Query CITY
    once per cycle — NOT rig_root: the original implementation queried rig_root and so
    could never find a marker for any non-HQ rig bead (a rig store never holds a
    quality-gate-marker row), making built_ids silently always-empty for every
    whatsapp_automation/property_scrapers bead since this check was introduced — its own
    motivating example (wa-huo0d) would never have matched (ga-6927).

    Returns None on query/parse error — the caller MUST treat None as "unknown, not
    confirmed empty" and fail toward NOT alarming, mirroring the existing _bd_approved
    convention (None = query error, distinct from a genuinely empty result) rather than
    the old "empty set on error" behavior. Collapsing "query failed" into "empty set" is
    exactly the error-vs-empty conflation this bug is about: an unreadable marker query
    says nothing about whether a bead is built, so it must not silently license the starve
    alarm (root-class:error-vs-empty)."""
    if _bd_gate_markers is not None:
        rows = _bd_gate_markers()          # test seam
    else:
        # ga-xwza2: routed through the read-cache shim — informational membership
        # check (which beads have a BUILT marker), computed once per 30min cycle;
        # nothing in this cycle writes then re-reads this exact query.
        # --include-infra (ga-vm20x, Mayor 07/08): markers are born --ephemeral
        # (INFRA), hidden from `bd list` by default under bd 1.1.0 — without
        # this flag a genuinely-built bead reads as having no marker, which
        # (per the docstring above) risks licensing a false starve alarm.
        r = _sh(["bash", BD_LIST_CACHED, "-C", CITY, "list", "--include-infra",
                 "-l", "type:quality-gate-marker",
                 "--json", "-n", "200"], timeout=BD_TIMEOUT)
        if r is None or r.returncode != 0:
            return None
        rows = _parse_bd_json(r.stdout, strict=True)
    if rows is None:
        return None
    out = set()
    for m in (rows or []):
        if not isinstance(m, dict):
            continue
        if (m.get("status") or "open") == "closed":
            continue
        for lab in _get_labels(m):
            if lab.startswith("source-bead:"):
                out.add(lab[len("source-bead:"):])
    return out


# ── gate-queue backlog (ga-dbfm9) ──────────────────────────────────────────────
# _gate_queue_depth/_gate_queue_throughput/_gate_queue_suppress_reason/
# _gate_queue_body_line extracted to gate_queue_backlog.py (ga-ahn3v) — the same
# mechanism also confirmed and adopted by throughput-stall-watchdog.py (ga-u2u8z).
# Imported above; call sites below are unchanged.


# ── pilot dispatch-queue position (ga-tky97) ──────────────────────────────────
def _read_pilot_dispatchable(now):
    """Return the parsed pilot-dispatchable.json contract dict, or None if the
    file is missing, unreadable, malformed, or past its own ttl_seconds.

    Contract (packs/town-deltas/assets/pilot-dispatcher.sh, _pilot_emit_dispatchable):
      {"generated_at": "<ISO8601 UTC>", "ttl_seconds": <int>, "count": <int>,
       "items": [ {"id","title","type","rig","priority","created_at","assignee",
                   "store"}, … ]}
    `items` is pre-sorted in the SAME dispatch order (priority, created_at, id)
    the Pilot's real sweep uses, across every store — this reads that queue, it
    does not re-derive or guess at ordering.

    A stale/missing/malformed file means "cannot confirm queue position", NEVER
    "queue is empty" (root-class:error-vs-empty, same convention as every other
    None-on-error helper in this file) — callers must treat None as unmeasured,
    never as "bead not queued".
    """
    if _read_pilot_dispatchable_file is not None:
        return _read_pilot_dispatchable_file()   # test seam
    try:
        with open(PILOT_DISPATCHABLE_FILE) as f:
            data = json.load(f)
    except Exception:
        return None
    if not isinstance(data, dict) or not isinstance(data.get("items"), list):
        return None
    gen = data.get("generated_at") or ""
    ttl = data.get("ttl_seconds")
    if not gen or not isinstance(ttl, (int, float)):
        return None
    try:
        gen_epoch = datetime.datetime.strptime(
            gen[:19], "%Y-%m-%dT%H:%M:%S").replace(
            tzinfo=datetime.timezone.utc).timestamp()
    except Exception:
        return None
    if (now - gen_epoch) > ttl:
        return None
    return data


def _pilot_dispatchable_unreadable_reason(now):
    """Classify WHY _read_pilot_dispatchable(now) returned None this cycle
    (ga-abfcdz) — mirrors pilot-dispatcher.sh's _pilot_ram_pressure_unreadable()
    convention: a companion classifier, duplicated rather than shared, kept
    pure so a caller can log/render WHICH failure mode occurred without
    changing _read_pilot_dispatchable's existing dict-or-None contract
    (already relied on by every other caller and by the embedded selftest's
    _read_pilot_dispatchable_file seam).

    Returns one of "absent" (file does not exist), "malformed" (exists but
    fails a shape/field/timestamp check), "stale" (parses fine but
    now - generated_at > ttl_seconds), or None (file reads fresh and valid —
    a caller that already knows _read_pilot_dispatchable(now) returned None
    this same cycle should never see this, but None is returned rather than
    guessing if called out of that context).

    WHY the distinction matters (root-class:error-vs-empty): "absent" means
    the Pilot's own emit never ran at all — a real anomaly. "stale" is, as of
    ga-abfcdz, the COMMON, non-anomalous state (the write-side TTL was
    raised to 1800s specifically because real emission intervals run
    673-1394s — even after that fix, an occasional abnormally slow sweep can
    still legitimately go stale). Collapsing both into one "missing/stale/
    unreadable" phrase told the same false story either way: it could not
    say whether the writer is broken or just running a bit slow this cycle.

    ga-abfcdz gate-fix 1 (found live, in this function's OWN selftest run):
    when _read_pilot_dispatchable_file is stubbed (the OLD, still-common
    seam style — a scenario simulating dict-or-None abstractly, with no
    fixture file on disk at all) but no reason-seam was set for that same
    scenario, falling through to a REAL open() here read whatever this
    process's PILOT_DISPATCHABLE_FILE actually resolves to — on a live Gas
    Town machine, that can be the ACTUAL production file, making this
    "classifier" itself a source of non-hermetic, environment-dependent test
    results (the exact silent-guess shape this function exists to prevent,
    reproduced in its own harness). Treat "main seam stubbed, no reason-seam"
    as reason genuinely UNKNOWN (None) rather than guessing via uncontrolled
    I/O — callers already fall back to the old generic phrasing when this
    returns None, so every pre-existing scenario keeps its exact prior
    behavior untouched.
    """
    if _pilot_dispatchable_reason_file is not None:
        return _pilot_dispatchable_reason_file()   # test seam
    if _read_pilot_dispatchable_file is not None:
        return None   # main reader stubbed abstractly; no real file to classify
    try:
        with open(PILOT_DISPATCHABLE_FILE) as f:
            data = json.load(f)
    except FileNotFoundError:
        return "absent"
    except Exception:
        return "malformed"
    if not isinstance(data, dict) or not isinstance(data.get("items"), list):
        return "malformed"
    gen = data.get("generated_at") or ""
    ttl = data.get("ttl_seconds")
    if not gen or not isinstance(ttl, (int, float)):
        return "malformed"
    try:
        gen_epoch = datetime.datetime.strptime(
            gen[:19], "%Y-%m-%dT%H:%M:%S").replace(
            tzinfo=datetime.timezone.utc).timestamp()
    except Exception:
        return "malformed"
    if (now - gen_epoch) > ttl:
        return "stale"
    return None


_PILOT_DISPATCHABLE_REASON_TEXT = {
    "absent": "MISSING (file does not exist — the Pilot's own emit may not be running)",
    "malformed": "MALFORMED (exists but failed a shape/field/timestamp check — possible corruption)",
    "stale": "STALE (past its own ttl_seconds — the Pilot may simply be mid-sweep; see PILOT_DISPATCHABLE_TTL in pilot-dispatcher.sh)",
}


# ga-ndh7jm: MEASURED (15/15 consecutive real sweep-to-sweep intervals, read
# from pilot-dispatcher.log's per-sweep "Dolt health OK/SATURATED/UNREADABLE"
# marker — logged moments before this file's own write on every sweep, so
# consecutive marker timestamps are a direct proxy for this file's real
# write-to-write cadence): 731 713 759 736 706 641 644 640 648 641 755 729
# 702 711 737 seconds — every single one exceeds the old 600s default, same
# bug class ga-abfcdz just fixed for PILOT_DISPATCHABLE_TTL (this file is
# written a few cheap checks after that one, within the same sweep, so the
# two share essentially the same cadence). Raised to 1800s to match
# PILOT_DISPATCHABLE_TTL exactly — same convention (600s == one nominal
# StartInterval, still a fixed Python-side constant rather than a field in
# the JSON, since this state is a single flag, not a queue the writer might
# reasonably want to tune per-call), same margin reasoning (~2.5x the
# measured median, comfortably above the measured max, while still going
# stale if a sweep is genuinely abnormal).
PILOT_SWEEP_PAUSE_TTL_SEC = 1800


def _read_pilot_sweep_pause_state(now):
    """Return the parsed pilot-sweep-pause-state.json dict, or None if the
    file is missing, unreadable, malformed, or older than
    PILOT_SWEEP_PAUSE_TTL_SEC.

    Contract (packs/town-deltas/assets/pilot-dispatcher.sh,
    _pilot_write_sweep_pause_state): {"active": bool, "reason": str,
    "detail": str, "at": "<ISO8601 UTC>"}. Written on EVERY sweep that
    reaches the quota/cross-stage checks — active=true at the two whole-
    sweep-pause exit points (ga-x3nmz, ga-d0hz3), active=false once a sweep
    proceeds past both without pausing — so a stale file (past the TTL)
    means the Pilot hasn't run a sweep recently at all, not "confirmed not
    paused right now".

    A stale/missing/malformed file means "cannot confirm sweep-pause state",
    NEVER "confirmed not paused" (root-class:error-vs-empty, same convention
    as _read_pilot_dispatchable) — callers must treat None as unmeasured.
    """
    if _read_pilot_sweep_pause_state_file is not None:
        return _read_pilot_sweep_pause_state_file()   # test seam
    try:
        with open(PILOT_SWEEP_PAUSE_STATE_FILE) as f:
            data = json.load(f)
    except Exception:
        return None
    if not isinstance(data, dict) or "active" not in data:
        return None
    at = data.get("at") or ""
    if not at:
        return None
    try:
        at_epoch = datetime.datetime.strptime(
            at[:19], "%Y-%m-%dT%H:%M:%S").replace(
            tzinfo=datetime.timezone.utc).timestamp()
    except Exception:
        return None
    if (now - at_epoch) > PILOT_SWEEP_PAUSE_TTL_SEC:
        return None
    return data


def _pilot_sweep_pause_suppress_reason(sweep_pause_state):
    """Suppress reason if the Pilot's LAST sweep (within TTL) deliberately
    paused the WHOLE sweep — quota-limited (ga-x3nmz) or cross-stage yield
    to a congested Gate (ga-d0hz3) — else None (ga-nq0jo).

    ROOT CAUSE (ga-sb11i.4, 2026-08-14 10:37-10:42): _alarm_starving had no
    signal for "did the Pilot even attempt to dispatch this cycle at all."
    A perfectly healthy, front-of-queue bead alarmed "dispatch path failing"
    while the Pilot was deliberately yielding to a congested Gate — dispatch
    was working exactly as designed (backpressure, ga-d0hz3), same failure
    shape as ga-tky97's queue-position false positive, one level up: this
    checks whether the Pilot ran AT ALL, not where in its queue a bead sits.
    Checked FIRST among the measurement-based suppressions in
    _process_store() — cheaper than the per-bead queue-position/gate-depth
    checks, and if the whole sweep paused, it explains EVERY starving bead
    identically, so there's nothing more specific to learn by checking the
    others first.

    Returns None (do NOT suppress — fall through to the other checks, and
    possibly the alarm) when:
      - sweep_pause_state is None (file missing/stale/unreadable — an
        unmeasured pause state must never license a suppression,
        root-class:error-vs-empty, same discipline as every sibling
        suppress-reason function in this file)
      - sweep_pause_state["active"] is not True (the Pilot's last sweep
        within the TTL window ran normally — confirmed NOT paused, so this
        check has nothing to explain the wait with)

    A reason string (suppress) only when the state was measured, fresh, and
    positively says the Pilot paused — never a default.
    """
    if sweep_pause_state is None:
        return None
    if sweep_pause_state.get("active") is not True:
        return None
    reason = sweep_pause_state.get("reason") or "unspecified"
    detail = sweep_pause_state.get("detail") or ""
    at = sweep_pause_state.get("at") or "?"
    return ("Pilot's último sweep (%s) pausou o sweep inteiro deliberadamente "
            "(%s%s) — despacho saudável, não é falha" % (
            at, reason, (": " + detail) if detail else ""))


def _pilot_queue_position(bead_id, dispatchable):
    """Return (index, total, ahead_by_priority) for bead_id within an already-
    read `dispatchable` dict (see _read_pilot_dispatchable), or None if
    `dispatchable` is None or bead_id isn't present in its items.

    `index` is the bead's 0-based position in the Pilot's own dispatch-ordered
    queue (0 = next to be dispatched); `ahead_by_priority` is a {priority: count}
    breakdown of the `index` items strictly ahead of it, used to render "atrás
    de N itens de prioridade maior (P0=a, P1=b)" in the suppression log line.
    """
    if dispatchable is None:
        return None
    items = dispatchable.get("items") or []
    for i, item in enumerate(items):
        if item.get("id") == bead_id:
            ahead = {}
            for prior in items[:i]:
                p = prior.get("priority")
                ahead[p] = ahead.get(p, 0) + 1
            return i, len(items), ahead
    return None


def _pilot_queue_suppress_reason(bead_id, dispatchable):
    """Suppress reason if the Pilot's OWN dispatch-ordered queue snapshot shows
    `bead_id` legitimately queued behind other work, else None (ga-tky97).

    ROOT CAUSE (mail ga-wisp-6ab3m74, alarm #3 for ga-m3n1x, 2026-08-02):
    _alarm_starving had no signal for WHERE in the Pilot's actual dispatch
    order a starving bead sits. ga-m3n1x — a correctly-P2 feature queued behind
    a P0 task and two P1 bugs in a saturated 5-slot "small" lane — alarmed 3x as
    "dispatch path failing" while dispatch was working exactly as designed
    (bugs/tech-debt before features). The queue-position data already exists —
    the Pilot emits its fully-filtered, dispatch-ordered candidate queue every
    sweep (pilot-dispatchable.json, ttl=600s) — this reads it rather than
    re-deriving or guessing at order.

    Returns None (do NOT suppress — fall through to the alarm) when:
      - dispatchable is None (file missing/stale/unreadable — an unmeasured
        queue must never license a suppression, root-class:error-vs-empty;
        _pilot_queue_body_line() still marks the resulting alarm UNCERTAIN)
      - bead_id is not present in the queue (AC2: a bead genuinely invisible to
        the Pilot's own dispatch queue must keep alarming — this fix must not
        turn a false positive into a false negative)
      - bead_id IS present but at index 0 (nothing ahead of it) — an unexplained
        wait at the front of the queue is still a real dispatch-failure
        candidate; this signal has nothing to explain it with

    A reason string (suppress) only when the bead is found with >=1 item ahead
    of it in the Pilot's own dispatch order — a positively-measured explanation,
    never a default.
    """
    pos = _pilot_queue_position(bead_id, dispatchable)
    if pos is None:
        return None
    index, total, ahead = pos
    if index == 0:
        return None
    ahead_desc = ", ".join(
        "P%s=%d" % (p, n)
        for p, n in sorted(ahead.items(), key=lambda kv: (kv[0] is None, kv[0])))
    return ("enfileirado atrás de %d item(ns) no dispatch queue do Pilot "
             "(%s) — posição %d/%d, despacho saudável"
             % (index, ahead_desc, index + 1, total))


def _pilot_queue_body_line(bead_id, dispatchable, now):
    """Format the Pilot dispatch-queue context line for _alarm_starving's mail
    body (ga-tky97 AC1-AC3) — NEVER silent, NEVER fabricates a position for a
    queue that could not be read (mirrors _gate_queue_body_line's convention).

    Only reached for a bead _pilot_queue_suppress_reason() did NOT suppress, so
    in practice this only ever describes 'unreadable', 'not found', or 'first'
    — the index>0 branch below is kept for defensive completeness only.

    `now` (ga-abfcdz): only consulted when dispatchable is None, to classify
    WHY via _pilot_dispatchable_unreadable_reason() — absent/malformed/stale
    must not share the same phrase (root-class:error-vs-empty); see that
    function's docstring. Keeps "COULD NOT READ"/"UNCERTAIN" as stable
    substrings other callers and the embedded selftest already key off of.
    """
    if dispatchable is None:
        _reason = _pilot_dispatchable_unreadable_reason(now)
        _reason_text = _PILOT_DISPATCHABLE_REASON_TEXT.get(
            _reason, "missing/stale/unreadable")
        return ("Pilot dispatch queue (pilot-dispatchable.json): COULD NOT READ "
                 "— %s — position-based suppression NOT "
                 "applied; alarm kept but UNCERTAIN: cannot confirm this is a "
                 "genuine dispatch failure vs. an unread queue position."
                 % _reason_text)
    pos = _pilot_queue_position(bead_id, dispatchable)
    total = len(dispatchable.get("items") or [])
    if pos is None:
        return ("Pilot dispatch queue (pilot-dispatchable.json): bead NOT found "
                 "among %d dispatchable item(s) — position-based suppression NOT "
                 "applied; this may indicate a real filter/query bug." % total)
    index, total, ahead = pos
    if index == 0:
        return ("Pilot dispatch queue (pilot-dispatchable.json): bead is FIRST "
                 "(position 1/%d, nothing ahead of it) — position-based "
                 "suppression NOT applied; an unexplained wait at the front of "
                 "the queue is a real dispatch-failure candidate." % total)
    ahead_desc = ", ".join(
        "P%s=%d" % (p, n)
        for p, n in sorted(ahead.items(), key=lambda kv: (kv[0] is None, kv[0])))
    return ("Pilot dispatch queue (pilot-dispatchable.json): bead at position "
             "%d/%d, %d item(s) ahead (%s) — this should already have been "
             "suppressed; treat as a _pilot_queue_suppress_reason() bug if seen "
             "live." % (index + 1, total, index, ahead_desc))


def _blocked_bead_ids(rig_root):
    """Set of bead ids in `rig_root` currently blocked by an open formal dependency
    (ga-yavyq AC2), per bd's own blocker-aware `bd blocked` computation.

    Unlike built_ids (HQ-only, computed once per cycle), dependencies are rig-scoped —
    this must be called once PER rig_root, same as the story:approved query itself.

    Why `bd blocked` and not the `dependencies` field already in the story:approved
    list result: the list-mode `dependencies` entries only carry {depends_on_id, type}
    — no status for the target bead — so "is this dep still open" cannot be answered
    from that array without an extra per-bead lookup. `bd blocked` is a single call
    that reuses bd's own already-correct, already-shipped blocker computation (the
    same one pilot-dispatcher.sh's _filter_unblocked has gated dispatch on since
    ga-5ew) instead of re-deriving dependency-closed-ness here.

    Returns None on query/parse error — same fail-toward-NOT-alarming convention as
    _gate_marker_source_beads()/built_ids: an unreadable blocked-set says nothing
    about whether a bead is genuinely blocked, so it must not silently license the
    starve alarm (root-class:error-vs-empty, ga-05604)."""
    if _bd_blocked is not None:
        rows = _bd_blocked(rig_root)       # test seam
    else:
        r = _sh([BD_BIN, "-C", rig_root, "blocked", "--json"], timeout=BD_TIMEOUT)
        if r is None or r.returncode != 0:
            return None
        rows = _parse_bd_json(r.stdout, strict=True)
    if rows is None:
        return None
    out = set()
    for b in (rows or []):
        if not isinstance(b, dict):
            continue
        bid = b.get("id") or b.get("issue_id") or ""
        if bid:
            out.add(bid)
    return out


# ── built-branch check (ga-tkcam, ga-lzxhi) ───────────────────────────────────
# _built_branch_reason() is called per-bead from _process_store(), and only for
# a bead that has already survived every cheaper suppression this cycle (see
# call site) — the rare near-alarm case, not the whole story:approved scan. It
# needs a git branch probe per bead, so it stays last in the chain.
_OWNERSHIP_REPOS = None  # memoized for this process (script runs one-shot per launchd tick)


def _ownership_guard_repos():
    """Every repo a crew/fix branch could live in: the monorepo town root
    (dirname(CITY)) plus each registered rig's own path, de-duped. Mirrors
    pilot-dispatcher.sh's _ownership_guard_repos() (packs/town-deltas/assets/
    pilot-dispatcher.sh:2638). Fail-open: a `gc rig list` error yields just the
    town root — the branch probe below then simply finds no branch, never a
    false suppression."""
    global _OWNERSHIP_REPOS
    if _OWNERSHIP_REPOS is not None:
        return _OWNERSHIP_REPOS
    repos = [os.path.dirname(CITY.rstrip("/"))]
    r = _sh([GC_BIN, "--city", CITY, "rig", "list", "--json"], timeout=20)
    if r is not None and r.returncode == 0 and (r.stdout or "").strip():
        try:
            for rig in (json.loads(r.stdout).get("rigs") or []):
                p = rig.get("path")
                if p:
                    repos.append(p)
        except Exception:
            pass
    seen = set()
    out = []
    for p in repos:
        if p and p not in seen:
            seen.add(p)
            out.append(p)
    _OWNERSHIP_REPOS = out
    return out


def _real_has_built_branch(bead_id):
    """True iff a crew/<owner>/<id> or fix/<id>-<slug> branch (local or origin
    remote-tracking) exists in any known repo. Mirrors the branch consultation
    in pilot-dispatcher.sh's _filter_built (packs/town-deltas/assets/
    pilot-dispatcher.sh:1900-1902) — same ref patterns, same fail-open-to-False
    direction (no git / no repos / probe error → NOT built; never invent a
    false suppression signal)."""
    if not bead_id:
        return False
    for repo in _ownership_guard_repos():
        if not repo or not os.path.isdir(repo):
            continue
        r = _sh(["git", "-C", repo, "for-each-ref", "--format=%(refname)",
                  "refs/remotes/origin/crew/*/%s" % bead_id,
                  "refs/heads/crew/*/%s" % bead_id,
                  "refs/remotes/origin/fix/%s-*" % bead_id,
                  "refs/heads/fix/%s-*" % bead_id],
                 timeout=10)
        if r is not None and r.returncode == 0 and (r.stdout or "").strip():
            return True
    return False


def _has_built_branch(bead_id):
    if _bd_has_built_branch is not None:
        return _bd_has_built_branch(bead_id)
    return _real_has_built_branch(bead_id)


def _built_branch_reason(bead_id):
    """Suppress reason if a matching crew/fix branch exists for this bead, else None.

    Mirrors pilot-dispatcher.sh's _filter_built EXACTLY (ga-lzxhi): _filter_built's
    branch probe (packs/town-deltas/assets/pilot-dispatcher.sh:2164-2166) is keyed
    on bead_id alone — it never consults pilot.dispatched_at or pilot.sling_bead.

    The prior version of this check (ga-tkcam) additionally required
    pilot.dispatched_at metadata to be set on THIS bead before probing for a
    branch. That extra condition under-suppressed: a branch built by a live crew
    agent commonly carries commits for SEVERAL beads in one push (e.g. a single
    crew/digo/* branch covering wa-miai9/wa-n2anz/wa-4s4cc/wa-2lt43), and only the
    bead that triggered the ORIGINAL dispatch gets pilot.dispatched_at stamped —
    sibling beads riding the same branch never do, even though _filter_built
    already excludes all of them by branch alone. Live repro (ga-lzxhi): wa-4s4cc
    paged the Mayor twice ("dispatch failing") while digo-wa was actively
    committing to crew/digo/wa-4s4cc, because pilot.dispatched_at was never set
    on wa-4s4cc specifically.

    Checked LAST in _process_store: needs a git branch probe, so it only runs
    for a bead that survived every cheaper suppression above. Fail-open (see
    _real_has_built_branch): a git/repo probe error returns NOT built, so an
    unreadable probe can never invent a false suppression.
    """
    if _has_built_branch(bead_id):
        return "built branch exists (mirrors pilot-dispatcher _filter_built)"
    return None


def _matched_built_branch_ref(bead_id):
    """Like _real_has_built_branch but also returns WHICH (repo, ref) matched —
    needed to name the specific stranded branch in an alert. Same ref shapes,
    same repos, same fail-open (no match) direction; deliberately a separate
    probe rather than a refactor of _real_has_built_branch, matching this
    file's established pattern of several independently-testable branch-probe
    functions (mirrors pilot-dispatcher.sh's _beadid_has_crew_branch vs.
    _beadid_matched_crew_branch_ref split, ga-8jxe1 AC2)."""
    if not bead_id:
        return None
    for repo in _ownership_guard_repos():
        if not repo or not os.path.isdir(repo):
            continue
        r = _sh(["git", "-C", repo, "for-each-ref", "--format=%(refname)",
                  "refs/remotes/origin/crew/*/%s" % bead_id,
                  "refs/heads/crew/*/%s" % bead_id,
                  "refs/remotes/origin/fix/%s-*" % bead_id,
                  "refs/heads/fix/%s-*" % bead_id],
                 timeout=10)
        if r is not None and r.returncode == 0 and (r.stdout or "").strip():
            ref = (r.stdout or "").strip().splitlines()[0].strip()
            if ref:
                return (repo, ref)
    return None


def _real_branch_stranded_reason(bead_id):
    """Real-git implementation behind _branch_stranded_reason() — see that
    function's docstring for the full judgment call. FAIL-OPEN throughout:
    no branch / no git / unresolvable merge-base / unresolvable commit date
    all return None (never invent a stranded-branch alert on unprobable
    data — the opposite direction from _filter_built's own fail-open, which
    is deliberate: a missed alert just means silence continues one more
    cycle, but a FALSE alert wastes a human triage cycle on nothing)."""
    matched = _matched_built_branch_ref(bead_id)
    if matched is None:
        return None
    repo, ref = matched

    r = _sh(["git", "-C", repo, "merge-base", "--is-ancestor", ref, "origin/main"], timeout=10)
    if r is None or r.returncode not in (0, 1):
        return None  # no git / unresolvable merge-base (e.g. origin/main missing, timeout) — fail open
    if r.returncode == 0:
        return None  # merged — landed, not stranded (a DIFFERENT bug: bead should have closed)
    # r.returncode == 1 here: confirmed NOT an ancestor of origin/main — proceed to staleness check

    r2 = _sh(["git", "-C", repo, "log", "-1", "--format=%ct", ref], timeout=10)
    if r2 is None or r2.returncode != 0:
        return None
    raw = (r2.stdout or "").strip()
    if not raw:
        return None
    try:
        commit_epoch = int(raw.splitlines()[0].strip())
    except (ValueError, IndexError):
        return None

    age_sec = time.time() - commit_epoch
    if age_sec <= BRANCH_STRANDED_STALE_HOURS * 3600:
        return None  # fresh — could be legitimately in-progress work, not abandoned

    return (repo, ref, age_sec / 86400.0)


def _branch_stranded_reason(bead_id):
    """Returns (repo, ref, age_days) iff bead_id has a matched crew/fix branch
    that is unmerged into origin/main and idle past BRANCH_STRANDED_STALE_HOURS.
    None if no branch, branch is merged, or branch is fresh.

    Caller (_process_store) reaches this check only after the bead has already
    passed every earlier suppression in the gauntlet — in particular
    _is_flowing() already guarantees the bead is unassigned (or assignee ==
    'mayor', itself continue'd earlier) and not gate:reviewing/queued, and the
    built_ids/blocked_ids/_dispatched_and_built_reason checks above already
    guarantee no open gate marker and no formal dependency block — so unlike
    pilot-dispatcher.sh's ga-8jxe1 _beadid_branch_signal (which re-checks the
    bead's own assignee snapshot itself, since dispatch_one() has no equivalent
    upstream gauntlet), this function only needs to answer the branch-state
    question: does a stale, unmerged, matching branch exist."""
    if _bd_branch_stranded is not None:
        return _bd_branch_stranded(bead_id)
    return _real_branch_stranded_reason(bead_id)


# ── process one store ─────────────────────────────────────────────────────────
def _process_store(rig_root, now, state, pilot_alive, built_ids, blocked_ids,
                    gate_depth=None, gate_throughput=None, dispatchable=None,
                    sweep_pause_state=None):
    """Scan story:approved open beads in rig_root; classify and act on each one.

    built_ids: set of bead ids with a live BUILT marker (from _gate_marker_source_beads(),
    computed ONCE per cycle in run_cycle() — markers live only in HQ, not per-rig), or None
    if that query failed (fail-safe: caller must not alarm when built-state is unknown).

    blocked_ids: set of bead ids in THIS rig_root blocked by an open formal dependency
    (from _blocked_bead_ids(rig_root), computed once per rig_root — dependencies are
    rig-scoped, unlike built_ids), or None if that query failed (same fail-safe: caller
    must not alarm when dependency-block state is unknown, ga-yavyq AC2).

    gate_depth/gate_throughput (ga-dbfm9): gate-review backlog reading from
    _gate_queue_depth()/_gate_queue_throughput(), computed ONCE per cycle in
    run_cycle() (HQ-global, same reasoning as built_ids) — None if unmeasurable.
    Consulted by _gate_queue_suppress_reason() immediately before the starve
    alarm fires, and rendered into that alarm's body regardless.

    dispatchable (ga-tky97): the Pilot's own fully-filtered, dispatch-ordered
    candidate queue from _read_pilot_dispatchable(), computed ONCE per cycle in
    run_cycle() (HQ-independent — the Pilot emits one cross-store file), or
    None if missing/stale/unreadable. Consulted by _pilot_queue_suppress_reason()
    immediately before the starve alarm fires, and rendered into that alarm's
    body regardless (same pattern as gate_depth/gate_throughput above).

    Returns (processed, routed, alarmed) int counts.
    On query error: logs + returns (0, 0, 0) — fail-open; other stores are unaffected.
    """
    # Query story:approved open beads.
    #
    # IMPORTANT: story:approved is NOT a pipeline stage — it is a durable ELIGIBILITY
    # marker. It is set once (Mayor approval) and stays on the bead across build, gate
    # review, and merge; the only removals in the whole framework are post-merge
    # (story-delivery.sh, merged-bead-janitor.sh) or the post-build path in _route_bead()
    # above. So this query's result set routinely contains beads that are already
    # in-flight, in the gate, or fully built and awaiting the gate — membership here means
    # "approved", not "waiting to be dispatched". Every consumer below (built_ids,
    # _is_flowing, the label-based suppressions) exists BECAUSE reading this query alone as
    # "not yet dispatched" is exactly the mistake that caused ga-6927.
    if _bd_approved is not None:
        # Test seam: stub provided.
        beads = _bd_approved(rig_root)
        if beads is None:
            _log("  [%s] bd query error (stub returned None) — skipping store (fail-open)"
                 % os.path.basename(rig_root))
            return 0, 0, 0
    else:
        # ga-xwza2: routed through the read-cache shim — this is the "reconciler"
        # named in the bug (30min poll), a pure eligibility-membership scan, not a
        # read-after-write (this cycle never writes story:approved then re-reads it).
        #
        # ga-hzt8s (2026-07-20, deliverable 1): widened from "open" only to also
        # include in_progress/deferred (mirrors painel_visibilidade.py's kanban
        # query, ~line 2154) — a bead that flipped to in_progress/deferred (e.g.
        # gate-failed, still carrying story:approved) was previously INVISIBLE to
        # this reconciler entirely, so it could never be seen, classified, flowing-
        # checked, or alarmed on. _classify() and _is_flowing() below (unchanged
        # order — see the comment at the _is_flowing() call site) are what keep
        # this widening safe now that non-open statuses are in scope.
        r = _sh(["bash", BD_LIST_CACHED, "-C", rig_root, "list", "-l", "story:approved",
                 "--status", "open,in_progress,deferred", "--json", "-n", "200"],
                timeout=BD_TIMEOUT)
        if r is None or r.returncode != 0:
            _log("  [%s] bd list story:approved failed (rc=%s) — skipping store (fail-open)"
                 % (os.path.basename(rig_root), r.returncode if r else "err"))
            return 0, 0, 0
        beads = _parse_bd_json(r.stdout)

    if not beads:
        _log("  [%s] 0 story:approved bead(s) (open/in_progress/deferred)" % os.path.basename(rig_root))
        return 0, 0, 0

    _log("  [%s] %d story:approved bead(s) to evaluate (open/in_progress/deferred)" % (
         os.path.basename(rig_root), len(beads)))

    processed = routed = alarmed = 0

    for bead in beads:
        if not isinstance(bead, dict):
            continue
        processed += 1
        bead_id = bead.get("id") or bead.get("issue_id") or "?"
        labels = _get_labels(bead)

        # ── Step 1: explicit label-based signal → route out ────────────────
        route_to, signal = _classify(bead)

        if route_to is not None:
            ok = _route_bead(rig_root, bead, route_to, signal, now, state)
            if ok:
                routed += 1
            continue  # classification done regardless of DRY_RUN/cooldown

        # ── Step 1b: keyword flag (no routing label) — flag only, NEVER route ─
        # §4 HARD RAIL: if _classify returned (None,None) but keywords match,
        # emit a low-priority flag so a human/refino can add the real label.
        # The bead STAYS story:approved. This is the wa-yez60 regression fix.
        #
        # Idempotency (ga-1iz2e/AC1): gate on FLAG_REVIEW_LABEL presence, not a time
        # cooldown — the old ALARM_COOLDOWN_SEC gate re-fired forever (nothing in this
        # loop ever applied the label it asked a human for), producing +60 identical
        # comments in 4h across 5 beads before this fix.
        #
        # ga-zcb20: the bd label-add below can itself fail (timeout, Dolt pressure,
        # etc.) without raising — when it does, FLAG_REVIEW_LABEL never actually lands
        # in `labels`, so the check above stays true forever and this branch re-fires
        # every cycle. Live repro: wa-ielq6 got 50+ byte-identical flag comments over
        # ~2 days at ~30min cadence. `flagged_ids` is a local, durable backstop
        # (persisted in STATE_FILE like routed/alarmed/reclaim_exhausted) that records
        # the flag the moment it's emitted, independent of whether the bd write itself
        # succeeded — the bd label stays the human-visible signal, this is what
        # actually guarantees "comment once."
        kw_flags = _keyword_flags(bead)
        flagged_ids = state.setdefault("flagged", {})
        if kw_flags and FLAG_REVIEW_LABEL not in labels and bead_id not in flagged_ids:
            for cat, kw in kw_flags:
                _log("  %s: keyword flag [%s] %r — no routing label; "
                     "bead stays approved, flag emitted for human review" % (
                     bead_id, cat, kw))
            if not DRY_RUN:
                flag_note = (
                    "approved-state-reconciler: bead parece %s (keyword %r) mas sem "
                    "label explícito. Um humano/refino deve confirmar e adicionar o label "
                    "correto. Bead permanece story:approved." % (
                    kw_flags[0][0], kw_flags[0][1]))
                _do_comment_add(rig_root, bead_id, flag_note)
                _do_label_add(rig_root, bead_id, FLAG_REVIEW_LABEL)
                flagged_ids[bead_id] = now
                _arc_ledger("flow-ledger", {
                    "ts": datetime.datetime.now(
                        datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "source_daemon": "approved-state-reconciler",
                    "stage": "keyword-flag",
                    "bead_id": bead_id,
                    "flags": [{"cat": c, "kw": k} for c, k in kw_flags],
                    "note": "keyword match without routing label — flag emitted, "
                            "bead stays approved",
                }, fail_open=True)

        # ── Step 2: no explicit signal → assumed buildable ─────────────────
        # Safety: we NEVER route here. Only flow-or-alarm.

        # mayor-assigned approved: reserved category — ledger note, no alarm.
        assignee = bead.get("assignee") or ""
        if assignee == "mayor":
            _log("  %s: mayor-assigned approved → low-priority ledger note (no alarm)" % bead_id)
            if not DRY_RUN:
                _arc_ledger("flow-ledger", {
                    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "source_daemon": "approved-state-reconciler",
                    "stage": "mayor-approved",
                    "bead_id": bead_id,
                    "note": "mayor-assigned approved — reserved category, no alarm",
                }, fail_open=True)
            continue

        # If the bead is in-flight or dispatched → already flowing, no action.
        #
        # ga-hzt8s (2026-07-20): deliberately NOT checked before Step 1's _classify()
        # call — an earlier draft of this fix moved it there, reasoning that routing
        # strips story:approved just as destructively as a false starve-alarm. Live
        # data proved that wrong: wa-srgv and wa-6cx36 (both in_progress, both newly
        # in scope via the widened --status filter above) carry a STALE flowing
        # signal (pilot:dispatched left over from a prior dispatch/escalation cycle)
        # ALONGSIDE an accurate, current gate:needs-human* label — gating classify()
        # on _is_flowing() would have left story:approved stuck on them forever,
        # reproducing the exact bug this fix targets. _classify()'s routing labels
        # (gate:passed/needs-device/needs-human/blocked) already take precedence over
        # flowing/assignee signals for OPEN beads in the pre-existing code — that
        # precedence is unchanged here, just now also reached by in_progress/deferred
        # beads. See selftest scenario (pp) for the regression guard.
        if _is_flowing(bead):
            _log("  %s: flowing (story:in-flight / pilot:dispatched / assignee) — OK" % bead_id)
            continue

        # IMPORTANT 2: track approved-age in daemon state, not updated_at.
        # updated_at resets on any label-touch or comment, which would suppress the starve
        # alarm for beads that have been quietly stuck for hours. We track the FIRST cycle
        # the daemon sees the bead as story:approved-and-not-flowing, and compute starve-age
        # from that. The entry is cleared when the bead is successfully routed.
        fsa = state.setdefault("first_seen_approved", {})
        if bead_id not in fsa:
            fsa[bead_id] = now
        starve_age_min = (now - fsa[bead_id]) / 60.0

        # Grace window: too fresh (daemon-side) to alarm. Priority-scaled: lower-priority
        # beads get more slack (see STARVE_MIN_PRI2/PRI3 above).
        priority = bead.get("priority")
        effective_starve_min = (
            STARVE_MIN_PRI3 if priority == 3 else
            STARVE_MIN_PRI2 if priority == 2 else
            STARVE_MIN
        )
        if starve_age_min < effective_starve_min:
            _log("  %s: no signal, not flowing, first-seen-approved=%.1fmin "
                 "< STARVE_MIN=%d (priority=%s) — grace" % (
                 bead_id, starve_age_min, effective_starve_min, priority))
            continue

        # pilot:held / pilot:held-until:<epoch> — mirrors pilot-dispatcher.sh's
        # _filter_candidates EXACTLY (ga-6om6a RE-FIX): held iff pilot:held is
        # present AND the latest/max held-until epoch (if any) has not yet
        # passed. See _pilot_still_held_reason() docstring for why this replaced
        # gate-fix attempt 1's log-scraping approach (ga-an81u AC1 for the
        # original bare pilot:held signal this supersedes).
        pilot_held_reason = _pilot_still_held_reason(labels, now)
        if pilot_held_reason is not None:
            _log("  %s: no signal, daemon-age=%.0fmin, %s — no alarm" % (
                 bead_id, starve_age_min, pilot_held_reason))
            continue

        # blocked-on:*/waiting-on:*/depends-on:*/next-action:*/pool:refused:* —
        # see _EXTRA_ALARM_SUPPRESS_PREFIXES docstring above (ga-an81u AC1).
        extra_reason = _extra_alarm_suppress_reason(labels)
        if extra_reason is not None:
            _log("  %s: no signal, daemon-age=%.0fmin, %s — no alarm" % (
                 bead_id, starve_age_min, extra_reason))
            continue

        # pilot:reclaim-count:N (ga-ag16) — bead drained at least once (worker spawned but
        # made no branch progress) and inflight-reclaim-guard reset it to open for re-dispatch.
        # This is NOT a dispatch failure: the reclaim-guard loop owns re-dispatch retries, and
        # its own cap (N >= RECLAIM_CAP → gate:needs-human, escalated by the guard itself) is
        # the real backstop — same structure as the gate:needs-fix suppression below. Below cap
        # the pilot is actively retrying (drain-cycling, not starving); at/above cap the guard
        # has already escalated (or will next cycle), so emit our own ONE-TIME "reclaim-exhausted"
        # note instead of repeating "dispatch failing" every ALARM_COOLDOWN_SEC.
        reclaim_count = _parse_reclaim_count(labels)
        if reclaim_count >= RECLAIM_CAP:
            _alarm_reclaim_exhausted(rig_root, bead, reclaim_count, now, state)
            continue
        if reclaim_count >= 1:
            _log("  %s: no signal, daemon-age=%.0fmin, pilot:reclaim-count:%d (reclaim-guard "
                 "owns re-dispatch; cap→escalate is the backstop) — no alarm" % (
                 bead_id, starve_age_min, reclaim_count))
            continue

        # gate:needs-fix — bead is in the autonomous gate-fix loop, NOT starving.
        # When a build FAILs the gate, the gate clears story:in-flight + assignee and
        # labels the bead gate:needs-fix (+ gate:fix-attempt:N); the Pilot then re-dispatches
        # a fixer with the reviewer feedback on its OWN cadence. Between a gate FAIL and the
        # next re-dispatch the bead is briefly story:approved + unassigned — which looks
        # identical to a starving approved bead (and starve-age counts from first-seen-approved,
        # so a bead cycling the loop for >STARVE_MIN trips this every gap). It is NOT a dispatch
        # failure: the gate-fix loop owns re-dispatch, and its own fix-cap (gate:fix-attempt:N →
        # gate:needs-human at cap, escalated by the gate itself) is the real backstop — and
        # gate:needs-human is already excluded as a non-buildable signal above. Suppress here.
        if park_labels.GATE_NEEDS_FIX_LABEL in labels:
            _log("  %s: no signal, daemon-age=%.0fmin, gate:needs-fix (gate-fix loop owns "
                 "re-dispatch; cap→needs-human is the backstop) — no alarm" % (
                 bead_id, starve_age_min))
            continue

        # gate:failed — same lifecycle moment as gate:needs-fix (a build just FAILed
        # the gate); depending on exactly when this reconciler runs relative to the
        # gate daemon, a bead can be observed carrying gate:failed before/without
        # gate:needs-fix yet being stamped (ga-an81u AC1: wa-pltmi carried both
        # gate:failed and gate:needs-fix while still getting falsely alarmed).
        # Same suppression rationale as gate:needs-fix above.
        if park_labels.GATE_FAILED_LABEL in labels:
            _log("  %s: no signal, daemon-age=%.0fmin, gate:failed (gate-fix loop owns "
                 "re-dispatch) — no alarm" % (bead_id, starve_age_min))
            continue

        # exec:manual — bead requires human/supervised execution; the headless pool never
        # dispatches it by design (ga-u4sd: 3 beads Mayor approved stayed story:approved +
        # exec:manual and alarmed "starving 90min" every cycle forever, since nothing else
        # here suppresses them). Not a dispatch failure — it's a legitimate final state
        # awaiting a human to run it. Same shape as gate:needs-fix above: suppress the alarm,
        # do NOT reclassify (no target state exists; the bead correctly stays story:approved).
        # Exact-match only (not a prefix check) — exec:auto must keep alarming if it starves.
        if park_labels.EXEC_MANUAL_LABEL in labels:
            _log("  %s: no signal, daemon-age=%.0fmin, exec:manual (awaiting human execution, "
                 "not a dispatch failure) — no alarm" % (bead_id, starve_age_min))
            continue

        # ga-it3e8: ctx:thin — bead has too little context to build; it needs
        # refino, not a builder, and the Pilot is correctly declining to
        # dispatch it. This reconciler had NO concept of ctx:thin at all
        # (grep -c 'ctx:thin' on this file was 0) despite it already being a
        # NAMED member of park_labels.NOT_READY_LABELS — the other two
        # park_labels consumers (imparavel-check.py, throughput-stall-
        # watchdog.py) already recognize it; this reconciler's bespoke
        # starve-alarm check is the one that had fallen out of sync (same
        # class of gap ga-hzt8s/ga-m0ksy already fixed here for other
        # labels). wa-b3eae (story:approved + ctx:thin + refino:creator-
        # swept, no ctx:ready/exec:auto) alarmed "dispatch path failing"
        # every cycle indefinitely, blaming the Pilot for a bead it was
        # correctly leaving alone. Same shape as exec:manual above: suppress
        # the alarm, do NOT reclassify — refino (not this reconciler) owns
        # what happens to a ctx:thin bead next. Exact-match only — ctx:ready
        # must keep alarming if it starves.
        if park_labels.CTX_THIN_LABEL in labels:
            _log("  %s: no signal, daemon-age=%.0fmin, ctx:thin (awaiting refino, "
                 "not a dispatch failure) — no alarm" % (bead_id, starve_age_min))
            continue

        # Pilot dead → can't blame dispatch; don't alarm.
        if not pilot_alive:
            _log("  %s: no signal, daemon-age=%.0fmin, starving BUT pilot dead — no alarm" % (
                 bead_id, starve_age_min))
            continue

        # IMPORTANT 1: capacity check — only alarm if builder pool has free slots.
        # A saturated pool means the bead is legitimately queued behind active work.
        has_cap, cap_note = _pool_has_capacity(rig_root, now)
        if not has_cap:
            _log("  %s: starving but pool SATURATED — skip alarm "
                 "(bead legitimately queued; %s)" % (bead_id, cap_note))
            continue
        if "unknown" in cap_note:
            _log("  %s: pool capacity unknown — alarming conservatively (%s)" % (
                 bead_id, cap_note))

        # BUILT (open gate marker references it) → past dispatch, awaiting the gate. NOT a
        # dispatch failure — the reconciler's scope is dispatch. (If the gate never reviews it,
        # that's a GATE bug — ga-pnugy — surfaced elsewhere, not as a false "dispatch failing".)
        # built_ids is None when the HQ marker query itself failed — treat that as UNKNOWN,
        # never as "confirmed not built": firing a dispatch-failing alarm on unreadable data is
        # the same error-vs-empty mistake that made this check a no-op for rig beads for weeks
        # (ga-6927).
        if built_ids is None:
            _log("  %s: no signal, daemon-age=%.0fmin, gate-marker query failed (built-state "
                 "unknown) — fail-safe, no alarm" % (bead_id, starve_age_min))
            continue
        if bead_id in built_ids:
            _log("  %s: no signal, daemon-age=%.0fmin, BUILT (open gate marker) — awaiting "
                 "gate, not a dispatch failure — no alarm" % (bead_id, starve_age_min))
            continue

        # BLOCKED by an open formal dependency (ga-yavyq AC2) — independent of any label.
        # wa-4uh2w carried a real `blocks` dependency on wa-89enh (in_progress) and still
        # alarmed, because until this fix nothing here ever consulted bd's own dependency
        # graph — only labels. blocked_ids is None when the `bd blocked` query itself
        # failed — same fail-safe direction as built_ids is None above: an unreadable
        # dependency-block query must not license the alarm either.
        if blocked_ids is None:
            _log("  %s: no signal, daemon-age=%.0fmin, bd-blocked query failed (dependency-"
                 "block state unknown) — fail-safe, no alarm" % (bead_id, starve_age_min))
            continue
        if bead_id in blocked_ids:
            _log("  %s: no signal, daemon-age=%.0fmin, BLOCKED (open formal dependency, "
                 "`bd blocked`) — no alarm" % (bead_id, starve_age_min))
            continue

        # BUILT BRANCH (ga-tkcam, ga-lzxhi): mirrors pilot-dispatcher.sh's
        # _filter_built — a matching crew/fix branch exists for this bead, so
        # it is past dispatch and awaiting merge/gate, not starving.
        # Branch-existence ALONE is the real _filter_built condition — it
        # never consults pilot.dispatched_at (see _built_branch_reason
        # docstring). Checked LAST: needs a git branch probe, so it only runs
        # for a bead that survived every cheaper suppression above.
        built_reason = _built_branch_reason(bead_id)
        if built_reason is not None:
            _log("  %s: no signal, daemon-age=%.0fmin, %s — no alarm" % (
                 bead_id, starve_age_min, built_reason))
            continue

        # BRANCH STRANDED (ga-32u6s): already flagged by this check (a prior cycle)
        # OR by pilot-dispatcher.sh's own ga-8jxe1 classifier (shared label
        # vocabulary) → already surfaced to a human, don't re-alert. Checked before
        # the git probe below so an already-labeled bead skips it entirely.
        if "pilot:orphan-branch" in labels:
            _log("  %s: no signal, daemon-age=%.0fmin, pilot:orphan-branch already "
                 "flagged — no alarm" % (bead_id, starve_age_min))
            continue

        # BRANCH STRANDED (ga-32u6s): a matching crew/fix branch exists, is unmerged,
        # and has sat idle past BRANCH_STRANDED_STALE_HOURS — built work abandoned
        # mid-flight, not a dispatch failure. See _alarm_branch_stranded()'s docstring
        # for why this is checked here rather than relying on pilot-dispatcher.sh's own
        # ga-8jxe1 classifier (unreachable for exactly this case — _filter_built drops
        # the candidate before dispatch_one ever sees it).
        stranded = _branch_stranded_reason(bead_id)
        if stranded is not None:
            s_repo, s_ref, s_age_days = stranded
            _alarm_branch_stranded(rig_root, bead, s_repo, s_ref, s_age_days, now, state)
            alarmed += 1
            continue

        # PILOT WHOLE-SWEEP PAUSE (ga-nq0jo): checked before the per-bead
        # queue-position/gate-depth suppressions below — cheapest of the
        # measurement-based checks (no per-bead lookup at all) and, if the
        # Pilot's last sweep paused entirely, it explains EVERY starving bead
        # in this cycle identically, so there is nothing more specific to
        # learn from the others first. See _pilot_sweep_pause_suppress_
        # reason()'s docstring for the ga-sb11i.4 false-positive this closes.
        sweep_pause_reason = _pilot_sweep_pause_suppress_reason(sweep_pause_state)
        if sweep_pause_reason is not None:
            _log("  %s: no signal, daemon-age=%.0fmin, %s — no alarm" % (
                 bead_id, starve_age_min, sweep_pause_reason))
            continue

        # PILOT DISPATCH-QUEUE POSITION (ga-tky97): the Pilot's own fully-
        # filtered, dispatch-ordered candidate queue (pilot-dispatchable.json)
        # is a more direct, per-bead signal than any label or backlog estimate
        # — if it shows this bead legitimately queued behind other work, the
        # wait is healthy dispatch pacing, not a broken dispatch path (3x false
        # alarm on ga-m3n1x: a correctly-P2 feature behind a P0 and two P1s in
        # a saturated lane — mail ga-wisp-6ab3m74). See
        # _pilot_queue_suppress_reason()'s docstring for the false-positive
        # history and the AC2 false-negative guard (a bead absent from the
        # Pilot's own queue must still alarm). Checked before the gate-queue
        # backlog check below — both are "last, measurement-based"
        # suppressions; this one is the more precise, per-bead signal.
        pilot_queue_suppress_reason = _pilot_queue_suppress_reason(bead_id, dispatchable)
        if pilot_queue_suppress_reason is not None:
            _log("  %s: no signal, daemon-age=%.0fmin, %s — no alarm" % (
                 bead_id, starve_age_min, pilot_queue_suppress_reason))
            continue

        # GATE QUEUE BACKLOG (ga-dbfm9): the gate-review queue is a separate resource
        # from the builder pool _pool_has_capacity already checked above; a deep
        # backlog there paces down how fast the Pilot effectively gets to new
        # dispatches even with a free pool slot (3 false positives 2026-08-01:
        # wa-skhsx, wa-n2anz, wa-4s4cc — see _gate_queue_suppress_reason()'s
        # docstring for the full incident analysis). Checked LAST, right before the
        # alarm itself — every other, cheaper/more-specific suppression above still
        # wins first.
        gate_suppress_reason = _gate_queue_suppress_reason(
            gate_depth, gate_throughput, starve_age_min)
        if gate_suppress_reason is not None:
            _log("  %s: no signal, daemon-age=%.0fmin, %s — no alarm" % (
                 bead_id, starve_age_min, gate_suppress_reason))
            continue

        # ALARM: buildable bead starving, pilot alive, pool has capacity, dispatch failing.
        _alarm_starving(rig_root, bead, starve_age_min, now, state, gate_depth, gate_throughput,
                         dispatchable)
        alarmed += 1

    return processed, routed, alarmed


# ── main reconciliation cycle ─────────────────────────────────────────────────
def run_cycle(now, state):
    """One full cycle across all rig stores. Returns (processed, routed, alarmed)."""
    _log("=== reconciler cycle: %s ===" %
         datetime.datetime.fromtimestamp(now, tz=datetime.timezone.utc).strftime(
             "%Y-%m-%d %H:%M:%SZ"))

    _prune_state(state, now)
    pilot_alive = _is_pilot_alive(now)
    _log("pilot alive: %s (window=%dmin)" % (pilot_alive, PILOT_ALIVE_WINDOW_MIN))

    # Gate markers live ONLY in the HQ store, never per-rig — index once per cycle
    # (ga-6927), not once per rig_root (the old per-store call was 3x redundant AND
    # queried the wrong store for non-HQ rigs). None = query failed; _process_store
    # treats that as fail-safe (unknown built-state → no alarm), not as "nothing built".
    built_ids = _gate_marker_source_beads()
    if built_ids is None:
        _log("  gate-marker query FAILED — built-bead check degrades fail-safe "
             "(no starve alarms this cycle on the BUILT check; see ga-6927)")

    # Gate-review backlog (ga-dbfm9): also HQ-global — same once-per-cycle
    # reasoning as built_ids above, not once-per-bead (would re-run the same bd
    # query and re-scan the same log tail once per starving bead in this cycle).
    # None = unmeasurable; _gate_queue_suppress_reason() treats that as "cannot
    # confirm suppression" (fail toward alarming), never as an empty/zero queue.
    gate_depth = _gate_queue_depth()
    if gate_depth is None:
        _log("  gate-queue depth query FAILED — starve-alarm queue-backlog "
             "suppression degrades to 'unmeasured' this cycle (see ga-dbfm9)")
    gate_throughput = _gate_queue_throughput(now)
    if gate_throughput is None:
        _log("  gate-queue throughput unmeasurable (log unreadable or tail didn't "
             "reach back %dmin) — starve-alarm queue-backlog suppression degrades "
             "to 'unmeasured' this cycle (see ga-dbfm9)" % GATE_QUEUE_WINDOW_MIN)

    # Pilot dispatch-queue snapshot (ga-tky97): also HQ-independent (the Pilot
    # emits ONE cross-store file) — read once per cycle, not once per bead.
    # None = missing/stale/unreadable; _pilot_queue_suppress_reason() treats
    # that as "cannot confirm queue position" (fail toward alarming, AC3),
    # never as "bead not queued".
    dispatchable = _read_pilot_dispatchable(now)
    if dispatchable is None:
        # ga-abfcdz: absent/malformed/stale must not share one log phrase —
        # see _pilot_dispatchable_unreadable_reason()'s docstring.
        _dispatchable_reason = _pilot_dispatchable_unreadable_reason(now)
        _dispatchable_reason_text = _PILOT_DISPATCHABLE_REASON_TEXT.get(
            _dispatchable_reason, "missing/stale/unreadable")
        _log("  pilot-dispatchable.json %s — starve-alarm "
             "queue-position suppression degrades to 'unmeasured' this cycle "
             "(see ga-tky97, ga-abfcdz)" % _dispatchable_reason_text)

    # Pilot whole-sweep pause state (ga-nq0jo): also HQ-independent, read once
    # per cycle. None = missing/stale/unreadable; _pilot_sweep_pause_suppress_
    # reason() treats that as "cannot confirm pause state" (fail toward
    # alarming), never as "confirmed not paused".
    sweep_pause_state = _read_pilot_sweep_pause_state(now)
    if sweep_pause_state is None:
        _log("  pilot-sweep-pause-state.json missing/stale/unreadable — "
             "starve-alarm sweep-pause suppression degrades to 'unmeasured' "
             "this cycle (see ga-nq0jo)")

    total_p = total_r = total_a = 0

    for rig_root in RIG_ROOTS:
        rig_root = rig_root.strip()
        if not rig_root:
            continue
        # In production, skip non-existent directories.
        # When _bd_approved is stubbed (selftest), skip the isdir check — trust the stub.
        if _bd_approved is None and not os.path.isdir(rig_root):
            _log("  [%s] directory not found — skipping" % rig_root)
            continue
        # Dependencies are rig-scoped (unlike built_ids, HQ-global) — query per rig_root,
        # same cadence as the story:approved query itself (ga-yavyq AC2).
        blocked_ids = _blocked_bead_ids(rig_root)
        if blocked_ids is None:
            _log("  [%s] bd-blocked query FAILED — dependency-block check degrades "
                 "fail-safe (no starve alarms this cycle for this rig on the BLOCKED "
                 "check; see ga-yavyq)" % rig_root)
        try:
            p, r, a = _process_store(rig_root, now, state, pilot_alive, built_ids,
                                      blocked_ids, gate_depth, gate_throughput,
                                      dispatchable, sweep_pause_state)
            total_p += p
            total_r += r
            total_a += a
        except Exception as e:
            _log("  [%s] UNEXPECTED ERROR (fail-open): %r" % (rig_root, e))

    _log("cycle done: %d processed, %d routed, %d alarmed" % (total_p, total_r, total_a))
    return total_p, total_r, total_a


# ── main entry point (one-shot — launchd controls cadence via StartInterval) ──
def main():
    if not ENABLED:
        _log("disabled via APPROVED_RECONCILER_ENABLED=0 — no-op")
        return

    _log("approved-state-reconciler starting "
         "(STARVE_MIN=%d FLOW_GRACE_MIN=%d DRY_RUN=%s)" % (
          STARVE_MIN, FLOW_GRACE_MIN, DRY_RUN))

    state = _load_state()
    try:
        run_cycle(time.time(), state)
        _save_state(state)
    except Exception as e:
        _log("cycle error: %r" % e)
        raise


# ── selftest ──────────────────────────────────────────────────────────────────
def _selftest():
    """Hermetic selftest — stubs all I/O via module globals. sys.exit(1) if any fail.

    Scenarios:
      (a)       on-device-labeled → routed to needs-device
      (b)       on-device by TITLE keyword (no label) → NOT routed + flag emitted [INVERTED]
      (wa-yez60) buildable bead "Consolidar painel warming (/aquecimento)" → NEVER routed
      (c)       needs-human label → routed
      (d)       story:blocked label → routed (label-based, not keyword)
      (e)       gate:passed → story:approved removed, no new state label added
      (f)       NO signal + in-flight label → no action
      (g)       NO signal + daemon-age>STARVE_MIN + pilot alive → ALARM
      (h)       NO signal + daemon-age>STARVE_MIN + pilot DEAD → no alarm
      (i)       mayor-assigned + starving → ledger note only, NO alarm
      (j)       NO explicit signal + ambiguous content → NEVER routed (safety)
      (k)       DRY_RUN=1 → zero label/comment/mail mutations
      (l)       idempotency — already-routed bead no longer has story:approved → no-op
      (m)       per-store bd error → that store skipped, others processed, no crash
      (n)       add-before-remove: label add fails → story:approved NOT removed
      (o)       first_seen_approved: starve alarm fires despite fresh updated_at
      (p)       gate:needs-fix bead in gate-fix loop → no starve alarm
      (q)       BUILT bead (open gate marker) → no starve alarm
      (r)       pilot:reclaim-count:1 (below RECLAIM_CAP) → no starve alarm (ga-ag16)
      (s)       pilot:reclaim-count:RECLAIM_CAP → no starve alarm; ONE reclaim-exhausted
                note (comment + ledger + low-prio notify), NOT a mayor mail (ga-ag16)
      (t)       reclaim-exhausted note does not repeat across cycles (ga-ag16)
      (u)       exec:manual bead → no starve alarm (awaiting human execution) (ga-u4sd)
      (v)       exec:auto bead (not exec:manual) → STILL alarms — regression guard, exact-
                label match must not swallow other exec:* variants (ga-u4sd)
      (w)       BUILT bead in a NON-HQ rig, no flowing label → no starve alarm — isolates
                the built_ids store-scope fix (queries HQ, not rig_root) (ga-6927)
      (x)       gate:reviewing label, no marker anywhere → no starve alarm — isolates the
                _is_flowing fix (ga-6927)
      (y)       no marker, no gate:*, not flowing → STILL alarms — regression guard, the
                ga-6927 fix must not become over-permissive
      (z)       HQ gate-marker query FAILS (built_ids=None) → no starve alarm — fail-safe,
                error must not collapse into "nothing built" (ga-6927)
      (aa)      HQ gate-marker query returns UNPARSEABLE JSON (rc=0) via the REAL _sh +
                _parse_bd_json path, not the _bd_gate_markers test seam — closes the gap
                where gate attempt 1 left the actual parse-failure branch uncovered (z
                only exercises the seam) (ga-6927 gate attempt 1 FAIL)
      (bb)      AC1 (ga-an81u): each extra-suppress label (blocked-on:*, waiting-on:*,
                depends-on:*, next-action:*, pool:refused:*, gate:failed, bare pilot:held)
                individually blocks the starve alarm
      (cc)      AC2 (ga-an81u): alarm body no longer asserts the false absolute claim
                "NO explicit non-buildable signal" — says what was actually checked
      (dd)      AC3 (ga-an81u): escalating backoff — +40min repeat suppressed (the OLD
                flat 30min cooldown would have refired), +61min fires as repeat #2 with
                notify priority demoted to 2 (AC4)
      (ee)      AC3 (ga-an81u): escalation continues to the 4h tier — +3h after the 2nd
                alarm suppressed, +4h1min fires as repeat #3
      (ff)      AC3 (ga-an81u): escalation caps at 12h — +11h after the 3rd alarm
                suppressed, +12h1min fires repeat #4, another +12h1min fires repeat #5
                (cap holds, never grows further, never fully silences)
      (gg)      AC3 (ga-an81u): a label-set change resets the escalation and fires
                immediately even well inside the current backoff window
      (hh)      AC3 (ga-an81u): legacy float-only 'alarmed' state (pre-AC3 format)
                migrates cleanly — treated as count=1, no crash in _prune_state
      (ii)      AC1 (ga-1iz2e): keyword flag with no marker label yet → comments
                ONCE and stamps FLAG_REVIEW_LABEL; bead still NOT routed, still
                story:approved (Step 1b safety rail unchanged)
      (jj)      AC1/AC3 (ga-1iz2e): keyword flag with FLAG_REVIEW_LABEL already
                present (as bd would report it after (ii)'s label-add landed) →
                ZERO additional comments — the old flat 30min cooldown would have
                refired here; this is the +60-comments-in-4h regression guard
      (kk)      AC1 (ga-yavyq): bare "blocked:<reason>" label suppresses the alarm
                same as blocked-on:/waiting-on:/etc — namespace unification
      (ll)      AC2 (ga-yavyq): bead with an OPEN formal 'blocks' dependency
                (present in `bd blocked`) suppresses the alarm, independent of
                any label
      (mm)      AC3 (ga-yavyq) falsification: dep CLOSED (not in `bd blocked`)
                + no blocking label → STILL alarms (AC2 fix isn't over-permissive)
      (nn)      AC3 (ga-yavyq) fail-safe: `bd blocked` query FAILS (blocked_ids=
                None) → no starve alarm, same direction as built_ids=None (z)
      (oo)      ga-hzt8s deliverable 1: the real bd-list query's --status arg is
                'open,in_progress,deferred', not just 'open'
      (pp)      ga-hzt8s regression guard: a bead with a stale flowing signal
                (pilot:dispatched) PLUS an explicit routing label (gate:needs-
                human) still gets routed — classify() takes precedence over a
                stale flowing/assignee signal, matching pre-existing open-bead
                behavior (live repro: wa-srgv, wa-6cx36)
      (rr)      ga-tkcam: built branch exists → no starve alarm (mirrors
                pilot-dispatcher _filter_built)
      (ss)      ga-lzxhi: built branch exists but this bead was never
                individually dispatched (multi-bead branch shape — a sibling
                bead triggered the original dispatch) → STILL no starve
                alarm; _filter_built keys off the branch alone, never
                pilot.dispatched_at, so this check can't either (live repro:
                wa-4s4cc paged the Mayor 2x while digo-wa built it on
                crew/digo/wa-4s4cc)
      (tt)      falsification: NO built branch → STILL alarms (fix isn't
                over-permissive)
      (uu)      ga-6om6a RE-FIX (gate-fix attempt 2, replaces log-scraping attempt
                1): pilot:held + pilot:held-until:<PAST epoch> (expired hold) +
                no other signal → STILL alarms — mirrors _filter_candidates
                treating an expired hold as NOT held, exactly (falsification:
                a bare presence check would wrongly suppress here forever)
      (vv)      ga-6om6a RE-FIX falsification: pilot:held + pilot:held-until:
                <FUTURE epoch> (not yet expired) → no alarm
      (ww)      ga-6om6a RE-FIX (ga-4aree accumulation shape): MULTIPLE
                pilot:held-until labels on the same bead (they accumulate,
                never get pruned) — an older EXPIRED stamp plus a newer
                still-valid one → must take the MAX/latest, not the first →
                no alarm
      (xx)      ga-6om6a RE-FIX: pilot:refused-reason:<slug> label (the
                PERMANENT audit label inflight-reclaim-guard.py promotes
                pool:refused[:reason] into, ga-uvfs6) → no alarm
      (ga-32u6s-a) stranded unmerged crew/fix branch, idle past
                BRANCH_STRANDED_STALE_HOURS, unassigned → branch-stranded
                alert fires (NOT the generic "dispatch failing" alarm) —
                wa-juety repro (6 days / 83min-scale starvation with the
                wrong diagnosis, root cause: _filter_built vetoes dispatch
                candidacy on branch-existence alone, so ga-8jxe1's own
                smarter classifier — which lives inside dispatch_one() —
                never gets a chance to run on this exact case)
      (ga-32u6s-b) falsification: no branch signal at all → STILL alarms via
                the generic starve path (fix isn't over-permissive)
      (ga-32u6s-c) bead already carries pilot:orphan-branch (this check's own
                prior cycle, OR pilot-dispatcher.sh's ga-8jxe1 classifier —
                shared label vocabulary) → skip re-alert entirely, even
                though the branch probe would still report stranded
      (ga-32u6s-d) branch-stranded alert does not repeat across cycles for
                the same bead — local state backstop, mirrors
                _alarm_reclaim_exhausted's one-time-only shape (scenario (t))
      (ga-dbfm9-a) gate queue backlog (depth=30, throughput=5/h) projects a
                wait longer than this bead's age → starve alarm SUPPRESSED
                (the wa-skhsx/wa-n2anz/wa-4s4cc false-positive shape)
      (ga-dbfm9-b) falsification: small backlog (projected drain < bead age)
                → STILL alarms; body carries the measured depth+throughput+
                projected drain (AC1)
      (ga-dbfm9-c) both queue measurements fail (depth query errors, log
                unreadable) → STILL alarms (never silently suppressed on
                unmeasurable data) with body saying "COULD NOT MEASURE",
                never a fabricated 0 (root-class:error-vs-empty, AC4)
      (ga-dbfm9-d) depth=0 (confirmed EMPTY queue) → STILL alarms regardless
                of throughput — explicit non-suppression floor ("não
                desligue a checagem... fila VAZIA continua alarmando")
      (ga-dbfm9-e) throughput=0 measured (e.g. stalled gate) with depth>0 →
                STILL alarms, no division-by-zero crash
      (ga-tky97-a) AC1: bead found in the Pilot's own dispatch queue with 3
                higher-precedence items ahead of it → starve alarm SUPPRESSED
                — the ga-m3n1x 3x false-positive shape (P2 feature correctly
                behind a P0 task + two P1 bugs in a saturated lane)
      (ga-tky97-b) AC2 falsification: bead NOT present in a FRESH dispatch
                queue → STILL alarms — a bead genuinely invisible to the
                Pilot's own queue must keep alarming; this fix must not turn
                a false positive into a false negative
      (ga-tky97-c) falsification: bead is FIRST in the queue (index 0,
                nothing ahead of it) → STILL alarms — this signal has
                nothing to explain an unexplained front-of-queue wait with
      (ga-tky97-d) AC3: pilot-dispatchable.json missing/stale/unreadable →
                STILL alarms, body says "COULD NOT READ" / UNCERTAIN — never
                silently trusts an unmeasured queue (root-class:error-vs-empty)
      (ga-tky97-e) AC4: a second, still-unsuppressed repeat alarm reports the
                queue-position delta since the previous alarm ("changed from
                not found in queue to front of queue"), not just a bare
                repeat count
      (ga-tky97-f) hermetic-selftest-blind-to-bootstrap guard: with the test
                seam OFF, the REAL _read_pilot_dispatchable() (actual file
                I/O + UTC-epoch math, never exercised by a-e above) parses a
                genuinely fresh file, rejects a stale one (past ttl_seconds),
                and returns None for a missing file
      (ga-tky97-g..i) GATE-FEEDBACK fix (attempt 1 FAIL): qpos=None used to
                mean both ABSENT (queue read fine, bead not in it) and
                UNREADABLE (snapshot itself failed this cycle) — a delta
                comparing two such Nones could assert "unchanged" across an
                unmeasured cycle. g/h/i cover the three UNREADABLE-involved
                transitions (prev-unreadable→cur-absent, prev-absent→
                cur-unreadable — the exact reviewer repro — and both-
                unreadable): none may claim unchanged/changed, and h/i assert
                the literal symptom never recurs (same body never pairs
                "COULD NOT READ" with a continuity claim)
      (ga-tky97-j) GATE-FEEDBACK fix overcorrection guard: prev=ABSENT and
                cur=ABSENT are BOTH measured (queue read fine both times, bead
                genuinely not in it) — delta must still say "unchanged"; the
                fix must not blanket every non-int qpos as incomparable
      (ga-32u6s-e) gate-fix-1 regression guard: _real_branch_stranded_reason's
                merge-base ancestry check must fail OPEN (None) when
                `git merge-base --is-ancestor` is unresolvable — both
                r is None (subprocess exception/timeout) and a non-{0,1}
                returncode (e.g. 128, no origin/main ref) — instead of
                silently falling through toward "confirmed unmerged", which
                would misreport an unrelated git failure as a stranded
                branch. Exercises the REAL function (not the
                _bd_branch_stranded stub scenarios a-d use), matching how
                the gate reviewer who caught this actually reproduced it.
    """
    global _bd_approved, _bd_label_add, _bd_label_remove, _bd_comment
    global _do_notify, _do_mail_mayor, _read_pilot_log_lines, _bd_gate_markers, _sh
    global _bd_blocked, _bd_show_full, _bd_has_built_branch, _bd_branch_stranded
    global _read_pilot_dispatchable_file, _read_pilot_sweep_pause_state_file
    global _pilot_dispatchable_reason_file
    global DRY_RUN, STARVE_MIN, FLOW_GRACE_MIN, ROUTE_COOLDOWN_SEC, ALARM_COOLDOWN_SEC
    global _OWNERSHIP_REPOS

    ok_count = [0]
    fail_count = [0]

    def _ok(label):
        ok_count[0] += 1
        print("  ok  %s" % label)

    def _bad(label, detail=""):
        fail_count[0] += 1
        print("  FAIL %s%s" % (label, ": " + detail if detail else ""))

    # ── fixed epoch and knobs for reproducibility ─────────────────────────────
    NOW = 1_750_000_000.0
    _STARVE = 20
    globals()["STARVE_MIN"] = _STARVE
    globals()["FLOW_GRACE_MIN"] = 10
    globals()["ROUTE_COOLDOWN_SEC"] = 1800
    globals()["ALARM_COOLDOWN_SEC"] = 1800

    # ── capture lists ─────────────────────────────────────────────────────────
    label_adds = []
    label_removes = []
    comments = []
    mail_calls = []
    notify_calls = []

    def _stub_label_add(root, bid, label):
        label_adds.append((bid, label))
        return True

    def _stub_label_remove(root, bid, label):
        label_removes.append((bid, label))
        return True

    def _stub_comment(root, bid, text):
        comments.append((bid, text))
        return True

    def _stub_mail(subject, body):
        mail_calls.append((subject, body))
        return True

    def _stub_notify(msg, prio):
        notify_calls.append((msg, prio))

    def _stub_sh_fast(args, timeout=20):
        """Fast stand-in for the real _sh() — avoids real subprocess calls (e.g.
        `gc session list --json`, invoked by _pool_has_capacity for every bead
        that reaches the alarm path) so the selftest stays hermetic per its own
        docstring, instead of ballooning in wall-clock as scenario count grows.

        Returns a generic "successful, empty" response (rc=0, stdout="[]") rather
        than a failure — the two real call sites this can reach when their own
        seam is unstubbed (_pool_has_capacity's `gc session list` and
        _gate_marker_source_beads' `bd ... type:quality-gate-marker` fallback)
        need DIFFERENT-looking failure handling: an rc!=0 here would make the
        marker query return None (query error) instead of an empty set, which
        flips built_ids-is-None → "unknown, fail-safe, no alarm" for every
        scenario that doesn't explicitly stub _bd_gate_markers — silently
        suppressing the very alarms scenarios (g)/(o)/(dd)/etc. exist to check
        for. "[]" satisfies both: the marker query parses it as zero rows
        (correct, harmless); gc-session-list's dict .get() raises on a bare
        list, caught by that call site's own try/except → "capacity unknown,
        alarm conservatively" — the same fail-open outcome, just via the
        exception path instead of the empty-stdout path. Every OTHER real _sh
        call site (label add/remove/comment, notify, mail send, the main
        story:approved query) is only reached when its own dedicated seam
        (_bd_label_add etc.) is None, and every scenario in this suite always
        stubs those directly — this generic fallback never reaches them.

        ga-ahn3v: `_gate_queue_depth`'s `bd ... gate-status:queued` fallback
        used to be a third call site this stub covered, back when
        _gate_queue_depth lived inside this file and its bare `_sh(...)` call
        resolved to this same global. The ga-ahn3v extraction moved it (plus
        the other 3 gate-queue-backlog functions) into gate_queue_backlog.py,
        which keeps its own separate `_sh` — rebinding THIS `_sh` no longer
        reaches it. See the `gate_queue_backlog._bd_gate_queue_markers`
        blanket default set right after this stub is installed below.

        ga-lzxhi: `git for-each-ref` (_real_has_built_branch, reached whenever a
        scenario doesn't stub _bd_has_built_branch) is NOT a JSON caller — it
        checks raw stdout non-emptiness for a matched ref. The literal text
        "[]" is non-empty, so the JSON-shaped default used to read as "a ref
        was found", falsely suppressing the alarm on EVERY scenario that
        reaches the built-branch check without an explicit
        _bd_has_built_branch stub (12 scenarios broke this way when the
        pilot.dispatched_at gate was dropped and this became reachable from
        the main alarm path, not just rr/ss/tt). Real `git for-each-ref` with
        no matches prints nothing, so mirror that here. Every OTHER real _sh
        call site (label add/remove/comment, notify, mail send, the main
        story:approved query) is only reached when its own dedicated seam
        (_bd_label_add etc.) is None, and every scenario in this suite always
        stubs those directly — this generic fallback never reaches them.
        """
        if args and args[0] == "git":
            return subprocess.CompletedProcess(args=args, returncode=0, stdout="", stderr="")
        return subprocess.CompletedProcess(args=args, returncode=0, stdout="[]", stderr="")

    _bd_label_add = _stub_label_add
    _bd_label_remove = _stub_label_remove
    _bd_comment = _stub_comment
    _do_mail_mayor = _stub_mail
    _do_notify = _stub_notify
    _sh = _stub_sh_fast
    # Hermetic defaults for the gate-queue-backlog module (ga-dbfm9/ga-ahn3v):
    # gate_queue_backlog.py keeps its own separate _sh (deliberately not shared
    # with callers — see that module's docstring), so rebinding _sh above does
    # NOT cover it — neither _gate_queue_depth() nor _gate_queue_throughput()
    # route through this file's _sh/_stub_sh_fast. Both need their OWN blanket
    # default here, or every scenario below that doesn't explicitly test the
    # gate-queue feature would shell out for real / read the REAL
    # quality-gate-dispatcher.log on disk, violating this suite's own "stubs
    # all I/O" docstring — and could non-deterministically suppress an
    # unrelated alarm depending on the live gate queue's actual depth/
    # throughput at the moment the suite happens to run (GATE-FEEDBACK,
    # ga-ahn3v attempt 1: this was caught as a hermetic-selftest regression
    # introduced by extracting these functions out of this file).
    #   depth: confirmed-empty (`[]`) is the same neutral default _stub_sh_fast
    #   used to produce for this call before the extraction — a query/parse
    #   error would be `None` instead, but that's what the (dd)-lettered
    #   scenario explicitly stubs when it wants to test that path.
    #   _gate_queue_suppress_reason() never suppresses on a confirmed-empty
    #   queue, so scenarios that don't care about the gate-queue feature are
    #   unaffected.
    #   throughput: empty tail → unmeasurable (None) → same never-suppress
    #   outcome.
    # Scenarios below that DO test the feature override these directly, same
    # convention as _read_pilot_log_lines.
    gate_queue_backlog._bd_gate_queue_markers = lambda: []
    gate_queue_backlog._read_gate_log_lines = lambda: []
    # Hermetic default for the Pilot dispatch-queue read (ga-tky97): unlike the
    # bd-query seams above, _read_pilot_dispatchable() does its own file I/O
    # (json.load) when _read_pilot_dispatchable_file is unstubbed — it never
    # routes through _sh/_stub_sh_fast, so without this it would read the REAL
    # pilot-dispatchable.json on disk during every scenario below. None
    # (missing/unreadable) → _pilot_queue_suppress_reason() never suppresses —
    # the same neutral, alarm-preserving default any scenario not explicitly
    # testing the queue-position feature relies on. Scenarios below that DO
    # test it override this directly, same convention as _read_gate_log_lines.
    _read_pilot_dispatchable_file = lambda: None

    # ── helpers ───────────────────────────────────────────────────────────────
    def _make_bead(bid, labels=None, title="Test story", assignee="",
                   age_min=5.0, body=""):
        """Create a minimal bead dict; age_min=minutes since last updated."""
        epoch = NOW - age_min * 60.0
        return {
            "id": bid,
            "title": title,
            "body": body,
            "labels": labels if labels is not None else ["story:approved"],
            "assignee": assignee,
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(epoch)),
        }

    def _pilot_recent(n=1):
        """n pilot sweep-complete lines within PILOT_ALIVE_WINDOW_MIN of NOW."""
        lines = []
        for i in range(n):
            e = NOW - 60 * i
            ts = time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(e))
            lines.append("%s [pilot-dispatcher] === Pilot sweep complete: "
                         "dispatched=0 ===" % ts)
        return lines

    def _pilot_old():
        """Pilot sweep-complete line OUTSIDE the alive window."""
        e = NOW - (PILOT_ALIVE_WINDOW_MIN + 5) * 60
        ts = time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(e))
        return ["%s [pilot-dispatcher] === Pilot sweep complete: dispatched=0 ===" % ts]

    def _pilot_recent_at(t):
        """Pilot sweep-complete line within PILOT_ALIVE_WINDOW_MIN of `t` (NOT the
        fixed module NOW). Multi-cycle scenarios that advance `now` by hours across
        several run_cycle() calls must re-derive this per call — _pilot_recent()
        freezes its line at NOW, so a cycle run hours later would see a stale line,
        read the pilot as dead, and mask whatever the scenario is actually testing."""
        ts = time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(t))
        return ["%s [pilot-dispatcher] === Pilot sweep complete: dispatched=0 ===" % ts]

    def _reset():
        label_adds.clear()
        label_removes.clear()
        comments.clear()
        mail_calls.clear()
        notify_calls.clear()
        return {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}

    def _reset_captures():
        """Clear capture lists only — preserves state dict (for multi-cycle tests)."""
        label_adds.clear()
        label_removes.clear()
        comments.clear()
        mail_calls.clear()
        notify_calls.clear()

    globals()["DRY_RUN"] = False

    print("\n[reconciler selftest] running scenarios...\n")

    # ── (a) on-device label → routed to story:needs-device ───────────────────
    print("Scenario (a): on-device label → needs-device route")
    _bd_approved = lambda root: [
        _make_bead("hq-001", labels=["story:approved", "story:needs-device"])]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    run_cycle(NOW, st)
    removed_approved = ("hq-001", "story:approved") in label_removes
    added_needs_device = ("hq-001", "story:needs-device") in label_adds
    if removed_approved and added_needs_device:
        _ok("(a): story:needs-device label → routed; story:approved removed, story:needs-device added")
    else:
        _bad("(a)", "removes=%s adds=%s" % (label_removes, label_adds))

    # ── (b) on-device title keyword + NO label → NOT routed + flag emitted ──────
    # §4 HARD RAIL: keywords alone must NEVER route (INVERTED from original scenario).
    print("\nScenario (b): on-device title keyword (no label) → NOT routed + flag emitted")
    _bd_approved = lambda root: [
        _make_bead("hq-002", title="feat: warming chip via UIAutomator")]
    st = _reset()
    run_cycle(NOW, st)
    not_removed_b = ("hq-002", "story:approved") not in label_removes
    not_added_device_b = ("hq-002", "story:needs-device") not in label_adds
    flag_comment_b = any(bid == "hq-002" for bid, _ in comments)
    if not_removed_b and not_added_device_b and flag_comment_b:
        _ok("(b): keyword-in-title + no label → NOT routed; story:approved kept; flag emitted")
    else:
        _bad("(b): SAFETY VIOLATION — keyword alone should not route bead",
             "not_removed=%s not_added=%s flag_comment=%s removes=%s adds=%s" % (
             not_removed_b, not_added_device_b, flag_comment_b,
             label_removes, label_adds))

    # ── (wa-yez60 regression) buildable bead with keywords → NEVER routed ──────
    print("\nScenario (wa-yez60): 'Consolidar painel warming (/aquecimento)' + no label → NOT routed")
    _bd_approved = lambda root: [
        _make_bead("wa-yez60", title="Consolidar painel warming (/aquecimento)",
                   labels=["story:approved"])]
    st = _reset()
    run_cycle(NOW, st)
    not_removed_waz = ("wa-yez60", "story:approved") not in label_removes
    not_added_waz = ("wa-yez60", "story:needs-device") not in label_adds
    if not_removed_waz and not_added_waz:
        _ok("(wa-yez60): keyword-in-title buildable bead → NOT routed (regression guard)")
    else:
        _bad("(wa-yez60): REGRESSION — wa-yez60 bead was hidden by keyword route!",
             "removes=%s adds=%s" % (label_removes, label_adds))

    # ── (c) needs-human label → routed ───────────────────────────────────────
    print("\nScenario (c): gate:needs-human:product label → needs-human route")
    _bd_approved = lambda root: [
        _make_bead("hq-003", labels=["story:approved", "gate:needs-human:product"])]
    st = _reset()
    run_cycle(NOW, st)
    if ("hq-003", "story:approved") in label_removes and \
       ("hq-003", "story:needs-human") in label_adds:
        _ok("(c): gate:needs-human:product → routed to story:needs-human")
    else:
        _bad("(c)", "removes=%s adds=%s" % (label_removes, label_adds))

    # ── (c2) ga-m0ksy: BARE needs-human label → routed (THE FIX) ────────────
    # wa-41fry's actual shape (P0, owner-key-exposure, correctly parked awaiting
    # Athos's decision) — was alarmed every cycle indefinitely before this fix
    # because bare "needs-human" matched neither of the two forms _classify()
    # previously checked.
    print("\nScenario (c2): bare 'needs-human' label → needs-human route (ga-m0ksy fix)")
    _bd_approved = lambda root: [
        _make_bead("wa-41fry", labels=["story:approved", "needs-human"])]
    st = _reset()
    run_cycle(NOW, st)
    if ("wa-41fry", "story:approved") in label_removes and \
       ("wa-41fry", "story:needs-human") in label_adds:
        _ok("(c2): bare needs-human → routed to story:needs-human (ga-m0ksy)")
    else:
        _bad("(c2): ga-m0ksy REGRESSION — bare needs-human NOT routed, would alarm forever "
             "on a bead correctly parked awaiting human decision",
             "removes=%s adds=%s" % (label_removes, label_adds))

    # ── (c3) ga-m0ksy: story:needs-human label (exact INPUT form) → routed ──
    # Pre-existing path, unmodified by this fix — asserted here per the bead's
    # own acceptance criteria ("teste cobre as 3 grafias") so all three
    # spellings have an explicit, individually-checkable regression case in
    # one place, not just the prefix form (c) already covered.
    print("\nScenario (c3): story:needs-human label (exact) → needs-human route")
    _bd_approved = lambda root: [
        _make_bead("wa-6xn82", labels=["story:approved", "story:needs-human"])]
    st = _reset()
    run_cycle(NOW, st)
    if ("wa-6xn82", "story:approved") in label_removes and \
       ("wa-6xn82", "story:needs-human") in label_adds:
        _ok("(c3): story:needs-human (exact) → routed to story:needs-human")
    else:
        _bad("(c3)", "removes=%s adds=%s" % (label_removes, label_adds))

    # ── (c4) ga-m0ksy: story:approved with NO park signal at all → STILL alarms ──
    # The acceptance criterion the fix must NOT break: this is the reconciler's
    # actual job (§4 case 3, buildable-but-not-flowing → ALARM). Without this
    # assertion surviving, "recognize bare needs-human" could silently regress
    # into "stop alarming altogether" and nobody would notice until real
    # dispatch failures went quiet.
    print("\nScenario (c4): story:approved, zero park signals, starving → STILL alarms "
          "(ga-m0ksy: the fix must not swallow real dispatch failures)")
    _bd_approved = lambda root: [_make_bead(
        "hq-c4", labels=["story:approved"], age_min=0.1)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_c4 = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_c4["first_seen_approved"]["hq-c4"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_c4)
    alarmed_c4 = any("hq-c4" in subj for subj, _ in mail_calls)
    if alarmed_c4:
        _ok("(c4): no park signal + starving → still alarms (ga-m0ksy did not over-suppress)")
    else:
        _bad("(c4): ga-m0ksy REGRESSION — genuinely starving bead with NO park signal "
             "failed to alarm; the bare-needs-human fix over-reached",
             "mail_calls=%s" % mail_calls)

    # ── (d) story:blocked label → routed ─────────────────────────────────────
    # Keywords alone no longer route; test label-based blocked routing instead.
    print("\nScenario (d): story:blocked label → blocked route (label-based only)")
    _bd_approved = lambda root: [
        _make_bead("hq-004", labels=["story:approved", "story:blocked"])]
    st = _reset()
    run_cycle(NOW, st)
    if ("hq-004", "story:approved") in label_removes and \
       ("hq-004", "story:blocked") in label_adds:
        _ok("(d): story:blocked label → routed to story:blocked")
    else:
        _bad("(d)", "removes=%s adds=%s" % (label_removes, label_adds))

    # ── (e) gate:passed → story:approved removed, no new state label ─────────
    print("\nScenario (e): gate:passed → story:approved removed, no new state added")
    _bd_approved = lambda root: [
        _make_bead("hq-005", labels=["story:approved", "gate:passed"])]
    st = _reset()
    run_cycle(NOW, st)
    removed_approved_e = ("hq-005", "story:approved") in label_removes
    # No new lifecycle label should be added (post-build → delivery owns it)
    added_lifecycle = any(
        bid == "hq-005" and lab.startswith("story:")
        for bid, lab in label_adds)
    if removed_approved_e and not added_lifecycle:
        _ok("(e): gate:passed → story:approved removed, no new story:* label")
    else:
        _bad("(e)", "removed=%s added_lifecycle=%s adds=%s" % (
             removed_approved_e, added_lifecycle, label_adds))

    # ── (f) NO signal + in-flight → no action ────────────────────────────────
    print("\nScenario (f): NO signal + story:in-flight → no action (flowing)")
    _bd_approved = lambda root: [
        _make_bead("hq-006",
                   labels=["story:approved", "story:in-flight"],
                   age_min=_STARVE + 10.0)]
    st = _reset()
    run_cycle(NOW, st)
    if not label_removes and not label_adds and not mail_calls:
        _ok("(f): in-flight → no routing, no alarm (flowing)")
    else:
        _bad("(f)", "removes=%s adds=%s mails=%d" % (label_removes, label_adds, len(mail_calls)))

    # ── (g) NO signal + daemon-age>STARVE + pilot alive → ALARM ──────────────
    # Pre-seed first_seen_approved: daemon has tracked this bead as approved for STARVE+5 min.
    print("\nScenario (g): NO signal + daemon-age>STARVE_MIN + pilot alive → ALARM")
    _bd_approved = lambda root: [_make_bead("hq-007", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["hq-007"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)
    mailed_g = any("hq-007" in subj for subj, _ in mail_calls)
    notified_g = any("hq-007" in msg for msg, _ in notify_calls)
    if mailed_g and notified_g:
        _ok("(g): starving buildable bead → ALARM fired (gc mail send mayor + notify)")
    else:
        _bad("(g): expected ALARM", "mail_calls=%s notify_calls=%s" % (mail_calls, notify_calls))

    # ── (h) NO signal + daemon-age>STARVE + pilot DEAD → no alarm ────────────
    print("\nScenario (h): NO signal + daemon-age>STARVE + pilot DEAD → no alarm")
    _bd_approved = lambda root: [_make_bead("hq-008", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_old()
    st = _reset()
    st["first_seen_approved"]["hq-008"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)
    if not mail_calls and not notify_calls:
        _ok("(h): pilot dead → no alarm (can't blame dispatch path when pilot is down)")
    else:
        _bad("(h)", "mail_calls=%d notify_calls=%d" % (len(mail_calls), len(notify_calls)))

    # ── (i) mayor-assigned + starving → ledger note only, no alarm ───────────
    print("\nScenario (i): mayor-assigned approved + starving → ledger note, NO alarm")
    _bd_approved = lambda root: [
        _make_bead("hq-009", assignee="mayor", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    run_cycle(NOW, st)
    if not mail_calls and not label_removes and not label_adds:
        _ok("(i): mayor-assigned → no alarm, no routing (reserved category)")
    else:
        _bad("(i)", "mail_calls=%d removes=%s adds=%s" % (
             len(mail_calls), label_removes, label_adds))

    # ── (j) NO explicit signal → NEVER routed out (safety) ───────────────────
    print("\nScenario (j): no explicit signal, fresh bead → NOT routed (safe default)")
    _bd_approved = lambda root: [
        _make_bead("hq-010", title="feat: generic feature with no device/human/block signal",
                   age_min=3.0)]
    st = _reset()
    run_cycle(NOW, st)
    if not label_removes and not label_adds and not mail_calls:
        _ok("(j): no explicit signal → bead NOT routed out; no alarm (within grace)")
    else:
        _bad("(j): SAFETY VIOLATION — bead was routed without explicit signal!",
             "removes=%s adds=%s mails=%d" % (label_removes, label_adds, len(mail_calls)))

    # ── (k) DRY_RUN → zero mutations ─────────────────────────────────────────
    print("\nScenario (k): DRY_RUN=1 → zero label/comment/mail mutations")
    globals()["DRY_RUN"] = True
    _bd_approved = lambda root: [
        _make_bead("hq-011", labels=["story:approved", "story:needs-device"]),
        _make_bead("hq-012", age_min=_STARVE + 5.0),   # would alarm if not DRY_RUN
    ]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["hq-012"] = NOW - (_STARVE + 5) * 60  # would trigger alarm
    run_cycle(NOW, st)
    if not label_removes and not label_adds and not comments and not mail_calls:
        _ok("(k): DRY_RUN=1 → zero label/comment/mail mutations (logs only)")
    else:
        _bad("(k)", "removes=%s adds=%s comments=%s mails=%d" % (
             label_removes, label_adds, comments, len(mail_calls)))
    globals()["DRY_RUN"] = False

    # ── (l) idempotency — already-routed bead is no-op ───────────────────────
    print("\nScenario (l): idempotency — already-routed bead has no story:approved → no-op")
    # A routed bead no longer has story:approved; bd query returns it as empty.
    _bd_approved = lambda root: []
    st = _reset()
    run_cycle(NOW, st)
    if not label_removes and not label_adds and not mail_calls:
        _ok("(l): no story:approved beads returned → zero mutations (idempotent)")
    else:
        _bad("(l)", "removes=%s adds=%s mails=%d" % (label_removes, label_adds, len(mail_calls)))

    # ── (m) per-store bd error → store skipped, others processed, no crash ───
    print("\nScenario (m): HQ bd error → HQ skipped (fail-open), WA processed, no crash")
    call_count = [0]

    def _bd_approved_m(root):
        call_count[0] += 1
        if "gascity-gastown-hq" in root:
            return None   # query error for HQ
        return [_make_bead("wa-001", labels=["story:approved", "story:needs-device"])]

    _bd_approved = _bd_approved_m
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    try:
        run_cycle(NOW, st)
        wa_removed = ("wa-001", "story:approved") in label_removes
        wa_added = ("wa-001", "story:needs-device") in label_adds
        if wa_removed and wa_added:
            _ok("(m): HQ bd error skipped (fail-open); WA store processed correctly; no crash")
        else:
            _bad("(m)", "WA not processed. removes=%s adds=%s calls=%d" % (
                 label_removes, label_adds, call_count[0]))
    except Exception as exc:
        _bad("(m): raised unexpected exception: %r" % exc)

    # ── (n) add-before-remove: label add fails → story:approved NOT removed ─────
    print("\nScenario (n): label add fails → story:approved NOT removed (orphan-limbo prevention)")

    def _stub_add_always_fail_for_014(root, bid, label):
        if bid == "hq-014":
            return False  # always fail for this bead (across all stores)
        label_adds.append((bid, label))
        return True

    _bd_label_add = _stub_add_always_fail_for_014
    _bd_approved = lambda root: [
        _make_bead("hq-014", labels=["story:approved", "story:needs-device"])]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    run_cycle(NOW, st)
    not_removed_n = ("hq-014", "story:approved") not in label_removes
    if not_removed_n:
        _ok("(n): add-before-remove — add failed → story:approved NOT removed; no orphan-limbo")
    else:
        _bad("(n): SAFETY VIOLATION — story:approved removed despite add failure!",
             "removes=%s adds=%s" % (label_removes, label_adds))
    _bd_label_add = _stub_label_add  # restore

    # ── (o) first_seen_approved: starve alarm fires despite fresh updated_at ───
    print("\nScenario (o): first_seen_approved — starve age not reset by updated_at touch")
    # Bead has very fresh updated_at (age_min=0.1) but daemon has tracked it approved
    # for STARVE_MIN+5 minutes → alarm should fire (daemon-side age, not updated_at).
    _bd_approved = lambda root: [_make_bead("hq-015", age_min=0.1)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_o = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_o["first_seen_approved"]["hq-015"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_o)
    alarmed_o = any("hq-015" in subj for subj, _ in mail_calls)
    if alarmed_o:
        _ok("(o): first_seen_approved — alarm fires despite fresh updated_at (daemon-side age)")
    else:
        _bad("(o): first_seen_approved not working — alarm not fired despite daemon age > STARVE_MIN",
             "mail_calls=%s" % mail_calls)

    print("\nScenario (p): gate:needs-fix bead in gate-fix loop → no starve alarm")
    # A bead cycling the autonomous gate-fix loop sits story:approved + unassigned between a
    # gate FAIL and the Pilot's re-dispatch. Its daemon-age exceeds STARVE_MIN (it has been
    # looping for a while), so without the exclusion it would FALSELY alarm "dispatch failing".
    # gate:needs-fix means the gate-fix loop owns re-dispatch (cap → gate:needs-human is the
    # real backstop) — it must NOT trip the starve alarm. (Regression guard for the false
    # ps-2w5d "starving 90min" reconciler mail.)
    _bd_approved = lambda root: [_make_bead(
        "hq-016", labels=["story:approved", "gate:needs-fix", "gate:fix-attempt:2"], age_min=0.1)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_p = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_p["first_seen_approved"]["hq-016"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_p)
    alarmed_p = any("hq-016" in subj for subj, _ in mail_calls)
    if not alarmed_p:
        _ok("(p): gate:needs-fix bead — no starve alarm (gate-fix loop owns re-dispatch)")
    else:
        _bad("(p): gate:needs-fix bead FALSELY alarmed as starving (false dispatch-failure mail)",
             "mail_calls=%s" % mail_calls)

    print("\nScenario (q): BUILT bead (open gate marker) → no starve alarm (not a dispatch failure)")
    # A bead an OPEN quality-gate-marker points at is built + awaiting the gate; it may sit
    # story:approved (e.g. wa-huo0d, whose marker the HQ-only gate scan never picks up — ga-pnugy)
    # yet is NOT a dispatch failure. The reconciler must not false-alarm "dispatch failing" on it.
    _bd_approved = lambda root: [_make_bead("hq-017", labels=["story:approved"], age_min=0.1)]
    _bd_gate_markers = lambda: [
        {"id": "wisp-q", "status": "open",
         "labels": ["type:quality-gate-marker", "source-bead:hq-017", "gate-status:ready"]}]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_q = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_q["first_seen_approved"]["hq-017"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_q)
    alarmed_q = any("hq-017" in subj for subj, _ in mail_calls)
    _bd_gate_markers = None
    if not alarmed_q:
        _ok("(q): built bead (open gate marker) — no starve alarm (real issue is the gate, ga-pnugy)")
    else:
        _bad("(q): built bead FALSELY alarmed as starving/dispatch-failing", "mail_calls=%s" % mail_calls)

    print("\nScenario (r): pilot:reclaim-count:1 (below RECLAIM_CAP) → no starve alarm (ga-ag16)")
    # A bead that drained once and was reclaimed by inflight-reclaim-guard sits
    # story:approved + unassigned with pilot:reclaim-count:1 — no pilot:held is stamped
    # until the 2nd+ reclaim (do_reclaim only holds on reclaim_count>=1 PRIOR to bump), so
    # without this exclusion it would FALSELY alarm "dispatch failing" during that gap.
    _bd_approved = lambda root: [_make_bead(
        "hq-018", labels=["story:approved", "pilot:reclaim-count:1"], age_min=0.1)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_r = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {},
            "reclaim_exhausted": {}}
    st_r["first_seen_approved"]["hq-018"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_r)
    alarmed_r = any("hq-018" in subj for subj, _ in mail_calls)
    if not alarmed_r:
        _ok("(r): pilot:reclaim-count:1 (below cap) — no starve alarm (reclaim-guard owns re-dispatch)")
    else:
        _bad("(r): drain-cycling bead FALSELY alarmed as dispatch-failing", "mail_calls=%s" % mail_calls)

    print("\nScenario (s): pilot:reclaim-count:RECLAIM_CAP → no dispatch-failing mail; "
          "ONE reclaim-exhausted note instead (ga-ag16)")
    # Reclaim cap exhausted: the pilot correctly backed off (inflight-reclaim-guard already
    # escalated with its own mail — see do_escalate()). The reconciler must NOT send its own
    # "dispatch path failing" mail; at most a distinct one-time comment/ledger/notify.
    _bd_approved = lambda root: [_make_bead(
        "hq-019", labels=["story:approved", "pilot:reclaim-count:%d" % RECLAIM_CAP], age_min=0.1)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_s = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {},
            "reclaim_exhausted": {}}
    st_s["first_seen_approved"]["hq-019"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_s)
    starve_mailed_s = any("hq-019" in subj for subj, _ in mail_calls)
    noted_s = any(bid == "hq-019" for bid, _ in comments)
    notified_s = any("hq-019" in msg for msg, _ in notify_calls)
    state_set_s = "hq-019" in st_s.get("reclaim_exhausted", {})
    if not starve_mailed_s and noted_s and notified_s and state_set_s:
        _ok("(s): reclaim-cap-exhausted bead — no dispatch-failing mail; one reclaim-exhausted "
            "comment+notify fired instead")
    else:
        _bad("(s)", "starve_mailed=%s noted=%s notified=%s state_set=%s mail_calls=%s comments=%s" % (
             starve_mailed_s, noted_s, notified_s, state_set_s, mail_calls, comments))

    print("\nScenario (t): reclaim-exhausted note does not repeat across cycles (ga-ag16)")
    # Re-run the same reclaim-capped bead against the SAME state dict (simulating the next
    # launchd cycle, 10min later) — the one-time note must not fire again.
    _reset_captures()
    run_cycle(NOW, st_s)
    if not comments and not notify_calls and not mail_calls:
        _ok("(t): reclaim-exhausted note fired exactly once — no repeat on next cycle")
    else:
        _bad("(t): reclaim-exhausted note REPEATED on second cycle",
             "comments=%s notify_calls=%s mail_calls=%s" % (comments, notify_calls, mail_calls))

    print("\nScenario (u): exec:manual bead → no starve alarm (awaiting human execution)")
    # A story:approved bead labeled exec:manual requires human/supervised execution — the
    # headless pool never dispatches it by design. Without this exclusion an approved
    # exec:manual bead alarms "starving" every cycle forever (ga-u4sd: 3 beads Mayor approved
    # fired "buildable bead starving 90min — dispatch failing" repeatedly).
    _bd_approved = lambda root: [_make_bead(
        "hq-020", labels=["story:approved", "exec:manual"], age_min=0.1)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_u = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_u["first_seen_approved"]["hq-020"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_u)
    alarmed_u = any("hq-020" in subj for subj, _ in mail_calls)
    if not alarmed_u:
        _ok("(u): exec:manual bead — no starve alarm (awaiting human execution, ga-u4sd)")
    else:
        _bad("(u): exec:manual bead FALSELY alarmed as starving (false dispatch-failure mail)",
             "mail_calls=%s" % mail_calls)

    print("\nScenario (v): exec:auto bead (not exec:manual) → STILL alarms (regression)")
    # Guard against a future refactor loosening the exec:manual check to a prefix/substring
    # match — exec:auto means the pool SHOULD pick this up, so a starving exec:auto bead is a
    # real dispatch failure and must keep alarming.
    _bd_approved = lambda root: [_make_bead(
        "hq-021", labels=["story:approved", "exec:auto"], age_min=0.1)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_v = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_v["first_seen_approved"]["hq-021"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_v)
    alarmed_v = any("hq-021" in subj for subj, _ in mail_calls)
    if alarmed_v:
        _ok("(v): exec:auto bead — still alarms (exact-match guard, not swallowed by the "
            "exec:manual fix)")
    else:
        _bad("(v): exec:auto bead FAILED to alarm — exec:manual fix regressed exec:auto "
             "dispatch-failure detection", "mail_calls=%s" % mail_calls)

    print("\nScenario (ga-it3e8-a): ctx:thin bead → no starve alarm (awaiting refino, ga-it3e8)")
    # Reproduces wa-b3eae's exact real-world label shape: story:approved + ctx:thin +
    # refino:creator-swept, NO ctx:ready/exec:auto. ctx:thin means "too little context to
    # build" — the bead needs refino, not a builder, and the Pilot is correctly declining to
    # dispatch it. Before this fix the reconciler had NO concept of ctx:thin at all (grep -c
    # 'ctx:thin' on this file was 0) despite it already being a named member of
    # park_labels.NOT_READY_LABELS — the alarm fired "dispatch path failing" every cycle,
    # blaming the Pilot for a bead it was correctly leaving alone.
    _bd_approved = lambda root: [_make_bead(
        "wa-it3e8a", labels=["story:approved", "ctx:thin", "refino:creator-swept"], age_min=0.1)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_it3e8a = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_it3e8a["first_seen_approved"]["wa-it3e8a"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_it3e8a)
    alarmed_it3e8a = any("wa-it3e8a" in subj for subj, _ in mail_calls)
    if not alarmed_it3e8a:
        _ok("(ga-it3e8-a): ctx:thin bead — no starve alarm (awaiting refino, ga-it3e8)")
    else:
        _bad("(ga-it3e8-a): ctx:thin bead FALSELY alarmed as starving (false dispatch-failure mail)",
             "mail_calls=%s" % mail_calls)

    print("\nScenario (ga-it3e8-b): ctx:ready bead (not ctx:thin) → STILL alarms (regression guard)")
    # Guard against a future refactor loosening the ctx:thin check to a prefix/substring match
    # (or otherwise widening it) — ctx:ready means the bead HAS enough context and the Pilot
    # should dispatch it, so a starving ctx:ready bead is a real dispatch failure and must keep
    # alarming. Mirrors scenario (v)'s role for exec:manual/exec:auto — the test has to fail on
    # the PRIOR HEAD's fix-less code too, but that code never suppressed ctx:ready either, so
    # this scenario's real job is catching a FUTURE overcorrection, not this bead's own bug.
    _bd_approved = lambda root: [_make_bead(
        "wa-it3e8b", labels=["story:approved", "ctx:ready"], age_min=0.1)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_it3e8b = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_it3e8b["first_seen_approved"]["wa-it3e8b"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_it3e8b)
    alarmed_it3e8b = any("wa-it3e8b" in subj for subj, _ in mail_calls)
    if alarmed_it3e8b:
        _ok("(ga-it3e8-b): ctx:ready bead — still alarms (exact-match guard, not swallowed by "
            "the ctx:thin fix)")
    else:
        _bad("(ga-it3e8-b): ctx:ready bead FAILED to alarm — ctx:thin fix regressed ctx:ready "
             "dispatch-failure detection", "mail_calls=%s" % mail_calls)

    print("\nScenario (w): BUILT bead (marker lives in HQ), NOT flowing → no starve alarm "
          "— isolates the built_ids store-scope fix (ga-6927)")
    # Reproduces the ORIGINAL bug precisely: the bead has NO story:in-flight/pilot:dispatched/
    # gate:reviewing/gate:queued label and no assignee (_is_flowing is False — CAUSA 2 does
    # NOT explain the suppression here), yet a live quality-gate-marker in the HQ store
    # references it. Pre-fix, built_ids was computed via `bd -C rig_root list -l
    # type:quality-gate-marker` — a rig store (whatsapp_automation, property_scrapers) NEVER
    # holds a quality-gate-marker row (markers only ever live in HQ) — so built_ids was
    # silently always-empty and this bead would have FALSELY alarmed.
    _bd_approved = lambda root: [_make_bead("wa-025", labels=["story:approved"], age_min=0.1)]
    _bd_gate_markers = lambda: [
        {"id": "wisp-w", "status": "open",
         "labels": ["type:quality-gate-marker", "source-bead:wa-025", "gate-status:reviewing"]}]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_w = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_w["first_seen_approved"]["wa-025"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_w)
    _bd_gate_markers = None
    alarmed_w = any("wa-025" in subj for subj, _ in mail_calls)
    if not alarmed_w:
        _ok("(w): BUILT bead, not flowing — no starve alarm (built_ids store-scope fix, ga-6927)")
    else:
        _bad("(w): FALSE ALARM on a built bead — built_ids store-scope fix regressed",
             "mail_calls=%s" % mail_calls)

    print("\nScenario (x): gate:reviewing label, NO marker anywhere → no starve alarm — "
          "isolates the _is_flowing fix (ga-6927)")
    # built_ids has no entry at all here (marker orphaned/never created/already closed — e.g.
    # the ga-pnugy HQ-only-scan gap) — CAUSA 1's fix does NOT explain the suppression. Only
    # the gate:reviewing → _is_flowing addition can suppress this alarm.
    _bd_approved = lambda root: [_make_bead(
        "hq-026", labels=["story:approved", "gate:reviewing"], age_min=0.1)]
    _bd_gate_markers = lambda: []   # query succeeds, genuinely no open markers
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_x = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_x["first_seen_approved"]["hq-026"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_x)
    _bd_gate_markers = None
    alarmed_x = any("hq-026" in subj for subj, _ in mail_calls)
    if not alarmed_x:
        _ok("(x): gate:reviewing, no marker — no starve alarm (_is_flowing fix, ga-6927)")
    else:
        _bad("(x): FALSE ALARM on a gate:reviewing bead — _is_flowing fix regressed",
             "mail_calls=%s" % mail_calls)

    print("\nScenario (y): no marker, no gate:*, not flowing → STILL alarms (regression guard)")
    # Guards against the ga-6927 fix becoming so permissive it swallows real dispatch
    # failures — a genuinely stalled bead (no marker, no flowing/suppression label) must
    # keep alarming exactly as before.
    _bd_approved = lambda root: [_make_bead("hq-027", age_min=0.1)]
    _bd_gate_markers = lambda: []   # query succeeds, genuinely no open markers
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_y = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_y["first_seen_approved"]["hq-027"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_y)
    _bd_gate_markers = None
    alarmed_y = any("hq-027" in subj for subj, _ in mail_calls)
    if alarmed_y:
        _ok("(y): genuinely stalled bead — still alarms (ga-6927 fix isn't over-permissive)")
    else:
        _bad("(y): genuinely stalled bead FAILED to alarm — ga-6927 fix became over-permissive",
             "mail_calls=%s" % mail_calls)

    print("\nScenario (z): HQ gate-marker query FAILS (built_ids=None) → no starve alarm "
          "— fail-safe, error != empty (ga-6927)")
    # The core error-vs-empty fix: a failed marker query must not collapse into "nothing
    # built" and license the starve alarm. built_ids=None (query error) must suppress the
    # alarm — the SAME fail-toward-no-alarm direction as _is_pilot_alive's own fail-open,
    # not the old "empty set on error, still evaluate the alarm" bias (that bias only made
    # sense if the query normally worked, which — per scenario (w) — it never did for rig
    # beads).
    _bd_approved = lambda root: [_make_bead("hq-028", age_min=0.1)]
    _bd_gate_markers = lambda: None   # simulated query error
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_z = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_z["first_seen_approved"]["hq-028"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_z)
    _bd_gate_markers = None
    alarmed_z = any("hq-028" in subj for subj, _ in mail_calls)
    if not alarmed_z:
        _ok("(z): HQ gate-marker query failure → fail-safe, no alarm (error-vs-empty fix)")
    else:
        _bad("(z): SAFETY VIOLATION — alarmed despite unreadable marker query "
             "(error-vs-empty conflation)", "mail_calls=%s" % mail_calls)

    print("\nScenario (aa): HQ gate-marker query returns UNPARSEABLE JSON (rc=0) via the "
          "REAL _sh + _parse_bd_json path → no starve alarm — closes the gate-attempt-1 "
          "coverage gap (ga-6927)")
    # (z) stubs _bd_gate_markers directly, which short-circuits _gate_marker_source_beads()
    # before it ever calls _sh()/_parse_bd_json() — the real production code path where the
    # gate-attempt-1 bug lived (_parse_bd_json's truncate-and-retry ALSO failing) had zero
    # coverage. Here we clear the _bd_gate_markers seam so the real branch runs, and stub
    # _sh() itself to simulate `bd ... --json` exiting 0 with a body that is not valid JSON
    # at all (not merely truncated-but-recoverable) — the exact shape _parse_bd_json's
    # docstring says collapses to [] "on any failure". If _gate_marker_source_beads() calls
    # _parse_bd_json without strict=True (or strict mode doesn't propagate None through the
    # truncate-retry-also-fails path), this bead falsely alarms.
    _bd_approved = lambda root: [_make_bead("hq-029", age_min=0.1)]
    _bd_gate_markers = None   # force the real _sh + _parse_bd_json branch, not the seam
    _real_sh = _sh
    _sh = lambda *a, **kw: subprocess.CompletedProcess(
        args=[], returncode=0, stdout="not valid json at all {{{")
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_aa = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_aa["first_seen_approved"]["hq-029"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_aa)
    _sh = _real_sh
    alarmed_aa = any("hq-029" in subj for subj, _ in mail_calls)
    if not alarmed_aa:
        _ok("(aa): unparseable HQ gate-marker JSON via the real _sh/_parse_bd_json path — "
            "fail-safe, no alarm")
    else:
        _bad("(aa): SAFETY VIOLATION — alarmed on unparseable gate-marker JSON via the real "
             "_sh/_parse_bd_json path (error-vs-empty conflation the seam-only tests in "
             "gate attempt 1 could not catch)", "mail_calls=%s" % mail_calls)

    print("\nScenario (bb): AC1 — each extra-suppress label individually blocks the alarm")
    # ga-an81u AC1: blocked-on:*, waiting-on:*, depends-on:*, next-action:*, pool:refused:*,
    # bare pilot:held, and gate:failed are all explicit non-buildable signals this
    # reconciler did NOT recognize before this fix — each, alone, must suppress the alarm.
    bb_cases = [
        ("hq-030", ["story:approved", "blocked-on:hq-999"], "blocked-on:*"),
        ("hq-031", ["story:approved", "waiting-on:hq-999"], "waiting-on:*"),
        ("hq-032", ["story:approved", "depends-on:hq-999"], "depends-on:*"),
        ("hq-033", ["story:approved", "next-action:wa-worker-constroi"], "next-action:*"),
        ("hq-034", ["story:approved", "pool:refused:engine-rebuild-required"], "pool:refused:*"),
        ("hq-035", ["story:approved", "gate:failed"], "gate:failed"),
        ("hq-036", ["story:approved", "pilot:held"], "bare pilot:held"),
    ]
    _read_pilot_log_lines = lambda: _pilot_recent()
    bb_failures = []
    for bid, labs, desc in bb_cases:
        _bd_approved = lambda root, labs=labs, bid=bid: [_make_bead(bid, labels=labs, age_min=0.1)]
        st_bb = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
        st_bb["first_seen_approved"][bid] = NOW - (_STARVE + 5) * 60
        _reset_captures()
        run_cycle(NOW, st_bb)
        if any(bid in subj for subj, _ in mail_calls):
            bb_failures.append("%s (%s) FALSELY alarmed" % (bid, desc))
    if not bb_failures:
        _ok("(bb): all 7 AC1 extra-suppress labels individually block the starve alarm")
    else:
        _bad("(bb)", "; ".join(bb_failures))

    print("\nScenario (cc): AC2 — alarm body no longer asserts the false absolute claim")
    _bd_approved = lambda root: [_make_bead("hq-037", age_min=0.1)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_cc = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_cc["first_seen_approved"]["hq-037"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_cc)
    cc_body = next((b for s, b in mail_calls if "hq-037" in s), None)
    old_false_claim = cc_body is not None and "NO explicit non-buildable signal" in cc_body
    new_honest_claim = cc_body is not None and "matched NONE of this reconciler's known" in cc_body
    if cc_body is not None and not old_false_claim and new_honest_claim:
        _ok("(cc): alarm body says 'matched NONE of KNOWN signals' — no longer an absolute claim")
    else:
        _bad("(cc)", "body=%r" % (cc_body,))

    print("\nScenario (dd): AC3 escalating backoff — +40min repeat suppressed (old flat "
          "30min cooldown would have refired), +61min fires as repeat #2 with notify "
          "priority demoted to 2 (AC4)")
    T0 = NOW
    _bd_approved = lambda root: [_make_bead("hq-038", age_min=0.1)]
    _read_pilot_log_lines = lambda: _pilot_recent_at(T0)
    st_dd = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_dd["first_seen_approved"]["hq-038"] = T0 - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(T0, st_dd)
    first_subj = next((s for s, _ in mail_calls if "hq-038" in s), None)
    first_prio = next((p for m, p in notify_calls if "hq-038" in m), None)

    _reset_captures()
    _read_pilot_log_lines = lambda: _pilot_recent_at(T0 + 40 * 60)
    run_cycle(T0 + 40 * 60, st_dd)   # +40min — inside the 1h tier, must NOT refire
    suppressed_40min = not any("hq-038" in s for s, _ in mail_calls)

    _reset_captures()
    _read_pilot_log_lines = lambda: _pilot_recent_at(T0 + 61 * 60)
    run_cycle(T0 + 61 * 60, st_dd)   # +61min — past the 1h tier, must refire as repeat #2
    second_subj = next((s for s, _ in mail_calls if "hq-038" in s), None)
    second_prio = next((p for m, p in notify_calls if "hq-038" in m), None)

    if (first_subj and "repeat" not in first_subj and first_prio == 4
            and suppressed_40min
            and second_subj and "repeat #2" in second_subj and second_prio == 2):
        _ok("(dd): 1st alarm (prio 4) fires; +40min suppressed; +61min fires as "
            "repeat #2 (prio 2 — AC4 demotion)")
    else:
        _bad("(dd)", "first_subj=%r first_prio=%s suppressed_40min=%s second_subj=%r "
             "second_prio=%s" % (first_subj, first_prio, suppressed_40min,
             second_subj, second_prio))

    print("\nScenario (ee): AC3 escalation continues — 4h tier")
    _reset_captures()
    _read_pilot_log_lines = lambda: _pilot_recent_at(T0 + 61 * 60 + 3 * 3600)
    run_cycle(T0 + 61 * 60 + 3 * 3600, st_dd)   # +3h after 2nd alarm — inside 4h tier
    suppressed_3h = not any("hq-038" in s for s, _ in mail_calls)

    _reset_captures()
    _read_pilot_log_lines = lambda: _pilot_recent_at(T0 + 61 * 60 + 4 * 3600 + 60)
    run_cycle(T0 + 61 * 60 + 4 * 3600 + 60, st_dd)   # +4h1min after 2nd — past 4h tier
    third_subj = next((s for s, _ in mail_calls if "hq-038" in s), None)
    if suppressed_3h and third_subj and "repeat #3" in third_subj:
        _ok("(ee): +3h after 2nd alarm suppressed (4h tier); +4h1min fires as repeat #3")
    else:
        _bad("(ee)", "suppressed_3h=%s third_subj=%r" % (suppressed_3h, third_subj))

    print("\nScenario (ff): AC3 escalation caps at 12h (holds, never grows further, "
          "never fully silences)")
    base = T0 + 61 * 60 + 4 * 3600 + 60   # timestamp of the 3rd alarm
    _reset_captures()
    _read_pilot_log_lines = lambda: _pilot_recent_at(base + 11 * 3600)
    run_cycle(base + 11 * 3600, st_dd)   # +11h after 3rd alarm — inside the 12h cap tier
    suppressed_11h = not any("hq-038" in s for s, _ in mail_calls)

    _reset_captures()
    _read_pilot_log_lines = lambda: _pilot_recent_at(base + 12 * 3600 + 60)
    run_cycle(base + 12 * 3600 + 60, st_dd)   # +12h1min — past the cap, fires repeat #4
    fourth_subj = next((s for s, _ in mail_calls if "hq-038" in s), None)

    _reset_captures()
    _read_pilot_log_lines = lambda: _pilot_recent_at(base + 12 * 3600 + 60 + 12 * 3600 + 60)
    run_cycle(base + 12 * 3600 + 60 + 12 * 3600 + 60, st_dd)   # another +12h1min — fires #5
    fifth_subj = next((s for s, _ in mail_calls if "hq-038" in s), None)

    if (suppressed_11h and fourth_subj and "repeat #4" in fourth_subj
            and fifth_subj and "repeat #5" in fifth_subj):
        _ok("(ff): 12h cap holds — suppressed at +11h, fires #4 at +12h1min, "
            "fires #5 another +12h1min later (cap doesn't keep growing)")
    else:
        _bad("(ff)", "suppressed_11h=%s fourth_subj=%r fifth_subj=%r" % (
             suppressed_11h, fourth_subj, fifth_subj))

    print("\nScenario (gg): AC3 — a label-set change resets escalation and fires "
          "immediately despite being well inside the backoff window")
    _bd_approved = lambda root: [_make_bead(
        "hq-039", labels=["story:approved", "priority:x"], age_min=0.1)]
    _read_pilot_log_lines = lambda: _pilot_recent_at(NOW)
    st_gg = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_gg["first_seen_approved"]["hq-039"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_gg)   # 1st alarm — count 0→1, fp captured
    first_gg = any("hq-039" in s for s, _ in mail_calls)

    _reset_captures()
    _read_pilot_log_lines = lambda: _pilot_recent_at(NOW + 10 * 60)
    run_cycle(NOW + 10 * 60, st_gg)   # +10min, SAME labels — well inside 1h tier, suppressed
    suppressed_unchanged = not any("hq-039" in s for s, _ in mail_calls)

    _bd_approved = lambda root: [_make_bead(   # labels CHANGED (simulates real churn)
        "hq-039", labels=["story:approved", "priority:x", "priority:y"], age_min=0.1)]
    _reset_captures()
    _read_pilot_log_lines = lambda: _pilot_recent_at(NOW + 20 * 60)
    run_cycle(NOW + 20 * 60, st_gg)   # +20min total — still well inside 1h, but labels differ
    changed_subj = next((s for s, _ in mail_calls if "hq-039" in s), None)
    fired_on_change = changed_subj is not None and "repeat" not in changed_subj

    if first_gg and suppressed_unchanged and fired_on_change:
        _ok("(gg): unchanged labels stay suppressed inside the 1h tier; a label-set "
            "change fires immediately (new incident) despite being well inside it")
    else:
        _bad("(gg)", "first=%s suppressed_unchanged=%s changed_subj=%r" % (
             first_gg, suppressed_unchanged, changed_subj))

    print("\nScenario (hh): legacy float-only 'alarmed' state (pre-AC3 format) "
          "migrates cleanly, no crash in _prune_state")
    LEGACY_TS = NOW - 100   # "already alarmed 100s ago" under the OLD pre-AC3 format
    st_hh = {"routed": {}, "alarmed": {"hq-040": LEGACY_TS}, "first_seen_approved": {},
             "flagged": {}}
    st_hh["first_seen_approved"]["hq-040"] = NOW - (_STARVE + 5) * 60
    _bd_approved = lambda root: [_make_bead("hq-040", age_min=0.1)]
    _read_pilot_log_lines = lambda: _pilot_recent_at(NOW)

    _reset_captures()
    try:
        run_cycle(NOW, st_hh)   # 100s after the legacy timestamp — well inside 1h, suppressed
        no_crash = True
    except Exception as exc:
        no_crash = False
        _bad("(hh): run_cycle raised on legacy float state", "%r" % exc)
    suppressed_legacy = no_crash and not any("hq-040" in s for s, _ in mail_calls)

    if no_crash:
        _reset_captures()
        _read_pilot_log_lines = lambda: _pilot_recent_at(NOW + 61 * 60)
        run_cycle(NOW + 61 * 60, st_hh)   # +61min from LEGACY_TS — past 1h, fires repeat #2
        legacy_repeat_subj = next((s for s, _ in mail_calls if "hq-040" in s), None)
    else:
        legacy_repeat_subj = None

    if no_crash and suppressed_legacy and legacy_repeat_subj and "repeat #2" in legacy_repeat_subj:
        _ok("(hh): legacy float 'alarmed' entry migrates cleanly — treated as count=1, "
            "1h tier applies, no crash in _prune_state")
    else:
        _bad("(hh)", "no_crash=%s suppressed_legacy=%s legacy_repeat_subj=%r" % (
             no_crash, suppressed_legacy, legacy_repeat_subj))

    # ── (ii) AC1 (ga-1iz2e): keyword flag, no marker label yet → comment once, ──
    #        stamp FLAG_REVIEW_LABEL; bead still not routed, still story:approved
    print("\nScenario (ii): keyword flag, no marker label → comments once, stamps "
          "FLAG_REVIEW_LABEL")
    _bd_approved = lambda root: [
        _make_bead("hq-041", title="feat: warming chip via UIAutomator")]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_ii = _reset()
    run_cycle(NOW, st_ii)
    # NOTE: the stub ignores `root`, so run_cycle's 3-rig loop sees the same fake bead
    # 3x in one call — like every other first-occurrence scenario in this suite (e.g.
    # (s)'s `noted_s = any(...)`), assert PRESENCE, not exact count.
    commented_ii = any(bid == "hq-041" for bid, _ in comments)
    labeled_ii = ("hq-041", FLAG_REVIEW_LABEL) in label_adds
    not_removed_ii = ("hq-041", "story:approved") not in label_removes
    if commented_ii and labeled_ii and not_removed_ii:
        _ok("(ii): first sighting → flag comment emitted, FLAG_REVIEW_LABEL stamped, "
            "story:approved kept")
    else:
        _bad("(ii)", "commented=%s labeled=%s not_removed=%s" % (
             commented_ii, labeled_ii, not_removed_ii))

    # ── (jj) AC1/AC3 (ga-1iz2e): marker label already present, PAST the old ──
    #        30min cooldown window → zero repeat comments. The offset matters: at
    #        only +60s even the OLD buggy cooldown-based gate would stay quiet, so
    #        this must cross ALARM_COOLDOWN_SEC to actually distinguish old from
    #        new behavior (verified: this scenario FAILS against the pre-fix
    #        cooldown-based gate when run at this offset, passes at +60s either
    #        way — the +60s case alone would be a vacuous regression guard).
    #        story:in-flight neutralizes the unrelated Step 2 starve-alarm path
    #        (crossing STARVE_MIN=20min too) so only Step 1b's behavior is under
    #        test here.
    print("\nScenario (jj): keyword flag, FLAG_REVIEW_LABEL already present, "
          "past old 30min cooldown → zero repeat comments")
    _bd_approved = lambda root: [
        _make_bead("hq-041", title="feat: warming chip via UIAutomator",
                   labels=["story:approved", "story:in-flight", FLAG_REVIEW_LABEL])]
    _reset_captures()
    run_cycle(NOW + ALARM_COOLDOWN_SEC + 100, st_ii)   # same state dict — next cycle
    comments_jj = [text for bid, text in comments if bid == "hq-041"]
    labeled_jj = ("hq-041", FLAG_REVIEW_LABEL) in label_adds
    if len(comments_jj) == 0 and not labeled_jj:
        _ok("(jj): marker label present → zero additional comments, zero "
            "additional label-adds even past the old 30min cooldown (converges — "
            "was: repeats every 30min forever)")
    else:
        _bad("(jj)", "comments=%s labeled=%s" % (comments_jj, labeled_jj))

    print("\nScenario (kk): AC1 (ga-yavyq) — bare 'blocked:<reason>' label blocks the "
          "alarm same as blocked-on:/waiting-on:/etc (namespace unification)")
    # ga-yavyq: mila labeled wa-4uh2w 'blocked:needs-pregao-deployed' (colon-namespaced,
    # like blocked-on:/pool:refused:) expecting it to read as an explicit block — but
    # _has_prefix(labels, "blocked-on") does NOT match "blocked:needs-pregao-deployed"
    # (different prefix string), so it fell through every suppression check and the
    # bead alarmed "starving" twice despite being genuinely, explicitly blocked.
    _bd_approved = lambda root: [
        _make_bead("wa-042", labels=["story:approved", "blocked:needs-pregao-deployed"],
                   age_min=0.1)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_kk = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_kk["first_seen_approved"]["wa-042"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_kk)
    if not any("wa-042" in subj for subj, _ in mail_calls):
        _ok("(kk): bare blocked:<reason> label suppresses the starve alarm (AC1)")
    else:
        _bad("(kk)", "FALSELY alarmed despite blocked:needs-pregao-deployed label; "
             "mail_calls=%s" % mail_calls)

    print("\nScenario (ll): AC2 (ga-yavyq) — bead with an OPEN formal 'blocks' "
          "dependency (present in `bd blocked`) suppresses the alarm, independent "
          "of any label")
    # ga-yavyq CAUSA (b): wa-4uh2w had a REAL, FORMAL bd dependency (blocks) on
    # wa-89enh (in_progress, not closed) — and the reconciler alarmed anyway,
    # because it only ever looked at LABELS, never at bd's own dependency graph.
    # `bd blocked` is the authoritative, already-proven source (pilot-dispatcher.sh's
    # _filter_unblocked, ga-5ew, has gated dispatch on it for a while) — port the
    # same check into the reconciler's starve-alarm path instead of re-deriving
    # dependency-closed-ness from the (differently-shaped, status-less) list-mode
    # `dependencies` field.
    _bd_approved = lambda root: [_make_bead("wa-043", age_min=0.1)]   # zero extra labels
    _bd_blocked = lambda root: [{"id": "wa-043"}]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_ll = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_ll["first_seen_approved"]["wa-043"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_ll)
    _bd_blocked = None
    if not any("wa-043" in subj for subj, _ in mail_calls):
        _ok("(ll): open formal 'blocks' dependency suppresses the alarm, no label needed (AC2)")
    else:
        _bad("(ll)", "FALSELY alarmed despite open formal dependency (bd blocked); "
             "mail_calls=%s" % mail_calls)

    print("\nScenario (mm): AC3 falsification — dep CLOSED (bead not in `bd blocked`) "
          "and no blocking label → STILL alarms (don't over-suppress)")
    _bd_approved = lambda root: [_make_bead("wa-044", age_min=0.1)]
    _bd_blocked = lambda root: []   # query succeeds, genuinely nothing blocked
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_mm = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_mm["first_seen_approved"]["wa-044"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_mm)
    _bd_blocked = None
    if any("wa-044" in subj for subj, _ in mail_calls):
        _ok("(mm): no open dependency, no blocking label — still alarms "
            "(AC2 fix isn't over-permissive)")
    else:
        _bad("(mm)", "FAILED to alarm on a genuinely buildable, starving bead — AC2 fix "
             "became over-permissive; mail_calls=%s" % mail_calls)

    print("\nScenario (nn): `bd blocked` query FAILS (blocked_ids=None) → no starve "
          "alarm — fail-safe, error != empty (same direction as built_ids=None, "
          "scenario z)")
    _bd_approved = lambda root: [_make_bead("wa-045", age_min=0.1)]
    _bd_blocked = lambda root: None   # simulates a query/parse error
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_nn = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_nn["first_seen_approved"]["wa-045"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_nn)
    _bd_blocked = None
    if not any("wa-045" in subj for subj, _ in mail_calls):
        _ok("(nn): bd-blocked query failure fails SAFE — no alarm on unknown dep-state")
    else:
        _bad("(nn)", "FALSELY alarmed when bd-blocked query failed (dep-state unknown); "
             "mail_calls=%s" % mail_calls)

    print("\nScenario (oo): ga-hzt8s deliverable 1 — the real bd-list query's --status "
          "arg is widened to 'open,in_progress,deferred' (not just 'open')")
    _captured_argv_oo = []

    def _fake_sh_capture_oo(args, timeout=20):
        _captured_argv_oo.append(args)
        class _R:
            returncode = 0
            stdout = "[]"
        return _R()

    _bd_approved = None                # force the REAL query-building code path
    _sh = _fake_sh_capture_oo
    _process_store(RIG_ROOTS[0], NOW, {"first_seen_approved": {}}, True, set(), set())
    _sh = _stub_sh_fast
    _status_arg_oo = None
    for _argv in _captured_argv_oo:
        if "story:approved" in _argv and "--status" in _argv:
            _status_arg_oo = _argv[_argv.index("--status") + 1]
            break
    if _status_arg_oo == "open,in_progress,deferred":
        _ok("(oo): story:approved query --status widened to 'open,in_progress,deferred'")
    else:
        _bad("(oo)", "expected --status 'open,in_progress,deferred', got %r (captured=%r)" % (
             _status_arg_oo, _captured_argv_oo))

    print("\nScenario (pp): ga-hzt8s regression guard — a bead carrying BOTH a stale "
          "flowing signal (pilot:dispatched) AND an explicit routing label "
          "(gate:needs-human) IS ROUTED (classify wins over flowing/assignee, matching "
          "pre-existing behavior for open beads). Live repro: wa-srgv and wa-6cx36 "
          "(whatsapp_automation) are in_progress with a stale pilot:dispatched left over "
          "from a prior dispatch/escalation cycle, plus a current gate:needs-human* label "
          "— an earlier draft of this fix checked _is_flowing() before _classify() and "
          "left story:approved stuck on both forever; this guards against reintroducing "
          "that regression.")
    _bd_approved = lambda root: [_make_bead(
        "wa-046", labels=["story:approved", "pilot:dispatched", "gate:needs-human"])]
    st_pp = _reset()
    run_cycle(NOW, st_pp)
    routed_pp = ("wa-046", "story:approved") in label_removes and \
                ("wa-046", "story:needs-human") in label_adds
    if routed_pp:
        _ok("(pp): stale-flowing + gate:needs-human → routed to story:needs-human "
            "(story:approved finally stripped, matching the wa-srgv/wa-6cx36 fix)")
    else:
        _bad("(pp)", "expected routing to story:needs-human despite pilot:dispatched — "
             "removes=%s adds=%s" % (label_removes, label_adds))

    # ── (qq) ga-zcb20: FLAG_REVIEW_LABEL bd write fails every cycle → local ──
    #        `flagged` state still suppresses every repeat after the first. Live
    #        repro: wa-ielq6 got 50+ byte-identical flag comments over ~2 days
    #        (07-16→18) at ~30min cadence — the bd label add was never
    #        succeeding, and the old gate (FLAG_REVIEW_LABEL not in labels) had
    #        no fallback, so it re-matched forever.
    print("\nScenario (qq): ga-zcb20 — FLAG_REVIEW_LABEL bd write fails every cycle → "
          "local state backstop still stops the repeat (was: reposted forever)")

    def _stub_label_add_always_fails(root, bid, label):
        return False  # simulate the bd write never landing, every single cycle

    _bd_label_add = _stub_label_add_always_fails
    _bd_approved = lambda root: [
        _make_bead("wa-ielq6", title="feat: warming chip via UIAutomator",
                   labels=["story:approved"])]
    st_qq = _reset()
    _read_pilot_log_lines = lambda: _pilot_recent_at(NOW)
    run_cycle(NOW, st_qq)
    first_count_qq = len([b for b, _ in comments if b == "wa-ielq6"])
    _reset_captures()
    # Same state dict across 3 more cycles spanning +90min; the bead's bd labels
    # never change (the label-add never actually took) — exactly the live
    # failure mode, not a one-off repeat.
    for _dt_min in (30, 60, 90):
        _read_pilot_log_lines = lambda dt=_dt_min: _pilot_recent_at(NOW + dt * 60)
        run_cycle(NOW + _dt_min * 60, st_qq)
    repeat_comments_qq = [b for b, _ in comments if b == "wa-ielq6"]
    _bd_label_add = _stub_label_add  # restore
    if first_count_qq >= 1 and len(repeat_comments_qq) == 0:
        _ok("(qq): label-add failure doesn't reopen the repost loop — local "
            "'flagged' state holds even with the bd label permanently missing")
    else:
        _bad("(qq)", "first_count=%d repeat_comments=%s" % (
             first_count_qq, repeat_comments_qq))

    print("\nScenario (rr): ga-tkcam — built branch exists → no starve alarm "
          "(mirrors pilot-dispatcher _filter_built)")
    _bd_approved = lambda root: [_make_bead("ga-rr1", age_min=0.1)]
    _bd_has_built_branch = lambda bid: bid == "ga-rr1"
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_rr = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_rr["first_seen_approved"]["ga-rr1"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_rr)
    _bd_has_built_branch = None
    if not any("ga-rr1" in subj for subj, _ in mail_calls):
        _ok("(rr): built branch exists → no alarm")
    else:
        _bad("(rr)", "FALSELY alarmed on a built bead; mail_calls=%s" % mail_calls)

    print("\nScenario (ss): ga-lzxhi — built branch exists but this bead was "
          "NEVER individually dispatched (multi-bead branch shape: a sibling "
          "bead triggered the original dispatch, e.g. crew/digo/wa-4s4cc "
          "carrying commits for wa-miai9/wa-n2anz/wa-4s4cc/wa-2lt43 at once) "
          "→ STILL no starve alarm — _filter_built doesn't consult "
          "pilot.dispatched_at, so neither does this check (live repro: "
          "wa-4s4cc paged the Mayor 2x while digo-wa built it)")
    _bd_approved = lambda root: [_make_bead("ga-ss1", age_min=0.1)]
    _bd_has_built_branch = lambda bid: bid == "ga-ss1"
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_ss = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_ss["first_seen_approved"]["ga-ss1"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_ss)
    _bd_has_built_branch = None
    if not any("ga-ss1" in subj for subj, _ in mail_calls):
        _ok("(ss): built branch, never individually dispatched → no alarm "
            "(ga-lzxhi fix)")
    else:
        _bad("(ss)", "FALSELY alarmed on a built-but-never-individually-"
             "dispatched bead — ga-lzxhi regressed; mail_calls=%s" % mail_calls)

    print("\nScenario (tt): falsification — NO built branch → STILL alarms "
          "(fix isn't over-permissive)")
    _bd_approved = lambda root: [_make_bead("ga-tt1", age_min=0.1)]
    _bd_has_built_branch = lambda bid: False
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_tt = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_tt["first_seen_approved"]["ga-tt1"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_tt)
    _bd_has_built_branch = None
    if any("ga-tt1" in subj for subj, _ in mail_calls):
        _ok("(tt): no built branch → still alarms (fix isn't over-permissive)")
    else:
        _bad("(tt)", "FAILED to alarm on a genuinely starving, not-built "
             "bead — fix became over-permissive; mail_calls=%s" % mail_calls)

    print("\nScenario (uu): ga-6om6a RE-FIX — pilot:held + pilot:held-until:<PAST "
          "epoch> (expired) + no other signal → STILL alarms (mirrors "
          "_filter_candidates: an expired hold is NOT held)")
    _bd_approved = lambda root: [_make_bead(
        "ga-uu1", age_min=0.1,
        labels=["story:approved", "pilot:held",
                "pilot:held-until:%d" % int(NOW - 3600)])]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_uu = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_uu["first_seen_approved"]["ga-uu1"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_uu)
    if any("ga-uu1" in subj for subj, _ in mail_calls):
        _ok("(uu): pilot:held + EXPIRED held-until → still alarms "
            "(not permanently suppressed by bare label presence)")
    else:
        _bad("(uu)", "FAILED to alarm despite an expired hold; "
             "mail_calls=%s" % mail_calls)

    print("\nScenario (vv): ga-6om6a RE-FIX falsification — pilot:held + "
          "pilot:held-until:<FUTURE epoch> (not yet expired) → no alarm")
    _bd_approved = lambda root: [_make_bead(
        "ga-vv1", age_min=0.1,
        labels=["story:approved", "pilot:held",
                "pilot:held-until:%d" % int(NOW + 3600)])]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_vv = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_vv["first_seen_approved"]["ga-vv1"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_vv)
    if not any("ga-vv1" in subj for subj, _ in mail_calls):
        _ok("(vv): pilot:held + not-yet-expired held-until → no alarm")
    else:
        _bad("(vv)", "FALSELY alarmed despite an active, not-yet-expired hold; "
             "mail_calls=%s" % mail_calls)

    print("\nScenario (ww): ga-6om6a RE-FIX (ga-4aree accumulation shape) — "
          "MULTIPLE pilot:held-until labels, an older EXPIRED stamp listed "
          "BEFORE a newer still-valid one → must take the MAX/latest, not "
          "the first, → no alarm")
    _bd_approved = lambda root: [_make_bead(
        "ga-ww1", age_min=0.1,
        labels=["story:approved", "pilot:held",
                "pilot:held-until:%d" % int(NOW - 3600),
                "pilot:held-until:%d" % int(NOW + 3600)])]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_ww = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_ww["first_seen_approved"]["ga-ww1"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_ww)
    if not any("ga-ww1" in subj for subj, _ in mail_calls):
        _ok("(ww): stale+fresh held-until labels together → takes the MAX, "
            "no alarm (ga-4aree regression guard)")
    else:
        _bad("(ww)", "FALSELY alarmed — took the FIRST held-until label "
             "instead of the MAX/latest; mail_calls=%s" % mail_calls)

    print("\nScenario (xx): ga-6om6a — pilot:refused-reason:<slug> (the "
          "PERMANENT audit label inflight-reclaim-guard.py promotes "
          "pool:refused[:reason] into, ga-uvfs6) → no alarm")
    _bd_approved = lambda root: [_make_bead(
        "ga-xx1", age_min=0.1,
        labels=["story:approved", "pilot:refused-reason:oracle-named-executor"])]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_xx = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_xx["first_seen_approved"]["ga-xx1"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_xx)
    if not any("ga-xx1" in subj for subj, _ in mail_calls):
        _ok("(xx): pilot:refused-reason:* → no alarm")
    else:
        _bad("(xx)", "FALSELY alarmed despite pilot:refused-reason:*; "
             "mail_calls=%s" % mail_calls)

    print("\nScenario (ga-32u6s-a): stranded unmerged crew/fix branch, idle past "
          "BRANCH_STRANDED_STALE_HOURS, unassigned → branch-stranded alert fires "
          "(NOT the generic 'dispatch failing' alarm) — wa-juety repro")
    _bd_approved = lambda root: [_make_bead("ga-bsa1", age_min=0.1)]
    _bd_branch_stranded = lambda bid: (
        ("/Users/athos/gt/whatsapp_automation", "refs/remotes/origin/crew/wa-worker/ga-bsa1", 6.2)
        if bid == "ga-bsa1" else None)
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_bsa = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_bsa["first_seen_approved"]["ga-bsa1"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_bsa)
    _bd_branch_stranded = None
    bsa_mail = [(subj, body) for subj, body in mail_calls if "ga-bsa1" in subj]
    bsa_stranded_subject = any("UNMERGED BUILD BRANCH" in subj for subj, _ in bsa_mail)
    bsa_generic_subject = any("dispatch failing" in subj for subj, _ in bsa_mail)
    bsa_labeled = ("ga-bsa1", "pilot:orphan-branch") in label_adds
    bsa_state_recorded = "ga-bsa1" in st_bsa.get("branch_stranded", {})
    if bsa_stranded_subject and not bsa_generic_subject and bsa_labeled and bsa_state_recorded:
        _ok("(ga-32u6s-a): stranded branch → branch-stranded alert (not generic starve), "
            "pilot:orphan-branch labeled, state recorded")
    else:
        _bad("(ga-32u6s-a)", "stranded_subject=%s generic_subject=%s labeled=%s "
             "state_recorded=%s mail_calls=%s label_adds=%s" % (
             bsa_stranded_subject, bsa_generic_subject, bsa_labeled, bsa_state_recorded,
             bsa_mail, label_adds))

    print("\nScenario (ga-32u6s-b) falsification: no branch signal at all "
          "(_branch_stranded_reason → None) → STILL alarms via the generic starve "
          "path — the new check must not swallow a genuine dispatch-failing case")
    _bd_approved = lambda root: [_make_bead("ga-bsb1", age_min=0.1)]
    _bd_branch_stranded = lambda bid: None
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_bsb = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_bsb["first_seen_approved"]["ga-bsb1"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_bsb)
    _bd_branch_stranded = None
    if any("ga-bsb1" in subj and "dispatch failing" in subj for subj, _ in mail_calls):
        _ok("(ga-32u6s-b): no branch signal → still alarms via the generic path "
            "(fix isn't over-permissive)")
    else:
        _bad("(ga-32u6s-b)", "FAILED to alarm a genuinely starving bead with no branch "
             "signal; mail_calls=%s" % mail_calls)

    print("\nScenario (ga-32u6s-c): bead ALREADY carries pilot:orphan-branch (applied "
          "by this check on a prior cycle, OR by pilot-dispatcher.sh's own ga-8jxe1 "
          "classifier — shared label vocabulary) → skip re-alert entirely, even "
          "though the branch probe would still report stranded if consulted")
    _bd_approved = lambda root: [_make_bead(
        "ga-bsc1", age_min=0.1, labels=["story:approved", "pilot:orphan-branch"])]
    _bd_branch_stranded = lambda bid: (
        ("/Users/athos/gt/whatsapp_automation", "refs/heads/fix/ga-bsc1-slug", 10.0)
        if bid == "ga-bsc1" else None)
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_bsc = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_bsc["first_seen_approved"]["ga-bsc1"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_bsc)
    _bd_branch_stranded = None
    if not any("ga-bsc1" in subj for subj, _ in mail_calls):
        _ok("(ga-32u6s-c): pilot:orphan-branch already present → no re-alert "
            "(idempotent vs. ga-8jxe1's shared label vocabulary)")
    else:
        _bad("(ga-32u6s-c)", "FALSELY re-alerted on an already-flagged bead; "
             "mail_calls=%s" % mail_calls)

    print("\nScenario (ga-32u6s-d): branch-stranded alert does not repeat across "
          "cycles for the same bead — local state backstop, mirrors "
          "_alarm_reclaim_exhausted's one-time-only shape (scenario (t))")
    _bd_approved = lambda root: [_make_bead("ga-bsd1", age_min=0.1)]
    _bd_branch_stranded = lambda bid: (
        ("/Users/athos/gt/whatsapp_automation", "refs/remotes/origin/crew/wa-worker/ga-bsd1", 6.2)
        if bid == "ga-bsd1" else None)
    _read_pilot_log_lines = lambda: _pilot_recent()
    st_bsd = {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}
    st_bsd["first_seen_approved"]["ga-bsd1"] = NOW - (_STARVE + 5) * 60
    _reset_captures()
    run_cycle(NOW, st_bsd)
    first_cycle_count = len([s for s, _ in mail_calls if "ga-bsd1" in s])
    _reset_captures()
    # +1h, same state dict, branch still stranded. Re-derive the pilot-alive log line
    # at the NEW now (_pilot_recent_at, not _pilot_recent) — see that helper's docstring:
    # a frozen-at-NOW line would read as pilot-dead an hour later and suppress the alarm
    # for the WRONG reason, making this assertion pass even with a broken idempotency guard.
    _read_pilot_log_lines = lambda: _pilot_recent_at(NOW + 3600)
    run_cycle(NOW + 3600, st_bsd)
    _bd_branch_stranded = None
    second_cycle_count = len([s for s, _ in mail_calls if "ga-bsd1" in s])
    if first_cycle_count == 1 and second_cycle_count == 0:
        _ok("(ga-32u6s-d): branch-stranded alert fires once, never repeats for the "
            "same bead across later cycles")
    else:
        _bad("(ga-32u6s-d)", "first_cycle_count=%d second_cycle_count=%d" % (
             first_cycle_count, second_cycle_count))

    # ── gate-queue backlog suppression (ga-dbfm9) ─────────────────────────────
    def _gate_log_fixture(verdict_epochs, filler_before=True):
        """Fake quality-gate-dispatcher.log lines: one 'Gate run complete ...
        verdict=' line per epoch in verdict_epochs, plus (if filler_before) one
        OLD non-matching line at NOW-2h so _gate_queue_throughput's reach-back
        completeness check is satisfied without the fixture needing to straddle
        the exact 1h window boundary itself."""
        lines = []
        if filler_before:
            old_ts = time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(NOW - 2 * 3600))
            lines.append("%s [quality-gate-dispatcher] unrelated log line" % old_ts)
        for e in verdict_epochs:
            ts = time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(e))
            lines.append("%s [quality-gate-dispatcher] === Gate run complete: "
                          "gate_run=ga-wisp-x branch=crew/x verdict=PASS elapsed=1s ==="
                          % ts)
        return lines

    print("\nScenario (ga-dbfm9-a): gate queue backlog (depth=30, throughput=5/h) "
          "projects a wait > bead age → starve alarm SUPPRESSED")
    gate_queue_backlog._bd_gate_queue_markers = lambda: [{"id": "ga-wisp-%d" % i} for i in range(30)]
    gate_queue_backlog._read_gate_log_lines = lambda: _gate_log_fixture([NOW - i * 600 for i in range(5)])
    _bd_approved = lambda root: [_make_bead("hq-042", age_min=_STARVE + 5.0)]  # 25min old
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["hq-042"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)
    if not mail_calls and not notify_calls:
        _ok("(ga-dbfm9-a): depth=30/throughput=5.0/h projects ~360min wait > "
            "bead age 25min → starve alarm suppressed")
    else:
        _bad("(ga-dbfm9-a)", "mail_calls=%s notify_calls=%s" % (mail_calls, notify_calls))

    print("\nScenario (ga-dbfm9-b): falsification — small backlog (depth=1, "
          "throughput=5/h) does NOT explain the wait → STILL alarms; body carries "
          "measured depth+throughput+projected drain (AC1)")
    gate_queue_backlog._bd_gate_queue_markers = lambda: [{"id": "ga-wisp-only"}]
    gate_queue_backlog._read_gate_log_lines = lambda: _gate_log_fixture([NOW - i * 600 for i in range(5)])
    _bd_approved = lambda root: [_make_bead("hq-043", age_min=_STARVE + 5.0)]  # 25min old
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["hq-043"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)
    body_b = next((b for s, b in mail_calls if "hq-043" in s), None)
    has_depth_b = body_b is not None and "1 marker(s)" in body_b
    has_tp_b = body_b is not None and "5.0 verdict(s)/h" in body_b
    has_drain_b = body_b is not None and "projected drain" in body_b
    if body_b is not None and has_depth_b and has_tp_b and has_drain_b:
        _ok("(ga-dbfm9-b): depth=1/throughput=5.0/h projects ~12min wait <= bead "
            "age 25min → alarm fires; body shows depth+throughput+projected drain")
    else:
        _bad("(ga-dbfm9-b)", "body=%r" % (body_b,))

    print("\nScenario (ga-dbfm9-c): both queue measurements fail (depth query "
          "errors, log unreadable) → STILL alarms, body says COULD NOT MEASURE "
          "(never silent, never a fabricated 0 — root-class:error-vs-empty, AC4)")
    gate_queue_backlog._bd_gate_queue_markers = lambda: None   # simulated query error
    gate_queue_backlog._read_gate_log_lines = lambda: []       # simulated unreadable/empty log
    _bd_approved = lambda root: [_make_bead("hq-044", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["hq-044"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)
    body_c = next((b for s, b in mail_calls if "hq-044" in s), None)
    if body_c is not None and "COULD NOT MEASURE" in body_c and "0 marker" not in body_c:
        _ok("(ga-dbfm9-c): unmeasurable queue → alarm STILL fires (not silenced) "
            "with an honest 'COULD NOT MEASURE' note, not a fabricated 0")
    else:
        _bad("(ga-dbfm9-c)", "body=%r" % (body_c,))

    print("\nScenario (ga-dbfm9-d): confirmed EMPTY gate queue (depth=0) → STILL "
          "alarms regardless of throughput (empty queue never explains a wait)")
    gate_queue_backlog._bd_gate_queue_markers = lambda: []     # confirmed empty, not an error
    gate_queue_backlog._read_gate_log_lines = lambda: _gate_log_fixture([NOW - i * 150 for i in range(20)])
    _bd_approved = lambda root: [_make_bead("hq-045", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["hq-045"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)
    if any("hq-045" in subj for subj, _ in mail_calls):
        _ok("(ga-dbfm9-d): depth=0 (confirmed empty) → alarm still fires, high "
            "throughput does not create a false suppression")
    else:
        _bad("(ga-dbfm9-d)", "mail_calls=%s" % (mail_calls,))

    print("\nScenario (ga-dbfm9-e): throughput=0 measured (stalled gate) + depth=10 "
          "→ STILL alarms, no division-by-zero crash")
    gate_queue_backlog._bd_gate_queue_markers = lambda: [{"id": "ga-wisp-%d" % i} for i in range(10)]
    gate_queue_backlog._read_gate_log_lines = lambda: _gate_log_fixture([])  # filler only, zero verdicts
    _bd_approved = lambda root: [_make_bead("hq-046", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["hq-046"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)
    body_e = next((b for s, b in mail_calls if "hq-046" in s), None)
    if body_e is not None and "0 verdict(s)/h" in body_e:
        _ok("(ga-dbfm9-e): throughput=0.0/h (measured, stalled gate) + depth=10 → "
            "alarm still fires (undefined projection ≠ suppression), no crash")
    else:
        _bad("(ga-dbfm9-e)", "mail_calls=%s body=%r" % (mail_calls, body_e))

    # Restore the neutral hermetic defaults so later scenarios (which don't
    # exercise the gate-queue feature) are unaffected by the last fixture
    # above. `None` would silently un-stub the seam and fall through to
    # gate_queue_backlog's own real _sh (GATE-FEEDBACK, ga-ahn3v attempt 1) —
    # restore to the same `lambda: []` neutral default set at selftest setup,
    # not to `None`.
    gate_queue_backlog._bd_gate_queue_markers = lambda: []
    gate_queue_backlog._read_gate_log_lines = lambda: []

    # ── pilot dispatch-queue position suppression (ga-tky97) ─────────────────
    print("\nScenario (ga-tky97-a): bead queued behind 3 higher-precedence "
          "items in the Pilot's own dispatch queue → starve alarm SUPPRESSED "
          "(the ga-m3n1x 3x false-positive shape, AC1)")
    _read_pilot_dispatchable_file = lambda: {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW)),
        "ttl_seconds": 600,
        "count": 4,
        "items": [
            {"id": "ga-ub8yq", "priority": 0},
            {"id": "wa-q6rbe", "priority": 1},
            {"id": "ga-zkxdw", "priority": 1},
            {"id": "hq-070", "priority": 2},
        ],
    }
    _bd_approved = lambda root: [_make_bead("hq-070", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["hq-070"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)
    if not mail_calls and not notify_calls:
        _ok("(ga-tky97-a): bead at position 4/4 (3 higher-precedence items "
            "ahead) in the Pilot's own queue → starve alarm suppressed")
    else:
        _bad("(ga-tky97-a)", "mail_calls=%s notify_calls=%s" % (mail_calls, notify_calls))

    print("\nScenario (ga-tky97-b): falsification (AC2) — bead absent from a "
          "FRESH dispatch queue → STILL alarms (must not become a false negative)")
    _read_pilot_dispatchable_file = lambda: {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW)),
        "ttl_seconds": 600,
        "count": 1,
        "items": [{"id": "ga-someone-else", "priority": 1}],
    }
    _bd_approved = lambda root: [_make_bead("hq-071", age_min=_STARVE + 5.0)]
    st = _reset()
    st["first_seen_approved"]["hq-071"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)
    body_tky_b = next((b for s, b in mail_calls if "hq-071" in s), None)
    if body_tky_b is not None and "NOT found among 1 dispatchable" in body_tky_b:
        _ok("(ga-tky97-b): bead absent from a fresh queue → alarm STILL fires; "
            "body notes it wasn't found (possible real filter/query bug)")
    else:
        _bad("(ga-tky97-b)", "mail_calls=%s body=%r" % (mail_calls, body_tky_b))

    print("\nScenario (ga-tky97-c): falsification — bead is FIRST in the "
          "queue (index 0, nothing ahead) → STILL alarms")
    _read_pilot_dispatchable_file = lambda: {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW)),
        "ttl_seconds": 600,
        "count": 1,
        "items": [{"id": "hq-072", "priority": 1}],
    }
    _bd_approved = lambda root: [_make_bead("hq-072", age_min=_STARVE + 5.0)]
    st = _reset()
    st["first_seen_approved"]["hq-072"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)
    body_tky_c = next((b for s, b in mail_calls if "hq-072" in s), None)
    if body_tky_c is not None and "bead is FIRST" in body_tky_c:
        _ok("(ga-tky97-c): bead first in queue, nothing ahead → alarm STILL "
            "fires (this signal has nothing to explain the wait with)")
    else:
        _bad("(ga-tky97-c)", "mail_calls=%s body=%r" % (mail_calls, body_tky_c))

    print("\nScenario (ga-tky97-d): AC3 — pilot-dispatchable.json missing/"
          "stale/unreadable → STILL alarms, body says COULD NOT READ / "
          "UNCERTAIN (never trusts an unmeasured queue, root-class:error-vs-empty)")
    _read_pilot_dispatchable_file = lambda: None   # simulated missing/stale/unreadable
    _bd_approved = lambda root: [_make_bead("hq-073", age_min=_STARVE + 5.0)]
    st = _reset()
    st["first_seen_approved"]["hq-073"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)
    body_tky_d = next((b for s, b in mail_calls if "hq-073" in s), None)
    if body_tky_d is not None and "COULD NOT READ" in body_tky_d and "UNCERTAIN" in body_tky_d:
        _ok("(ga-tky97-d): unreadable dispatch queue → alarm STILL fires, "
            "body honestly says COULD NOT READ / UNCERTAIN, never fabricates "
            "a position")
    else:
        _bad("(ga-tky97-d)", "mail_calls=%s body=%r" % (mail_calls, body_tky_d))

    print("\nScenario (ga-tky97-e): AC4 — a second, still-unsuppressed repeat "
          "alarm reports the queue-position delta since the previous alarm, "
          "not just a bare repeat count")
    _read_pilot_dispatchable_file = lambda: {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW)),
        "ttl_seconds": 600,
        "count": 1,
        "items": [{"id": "ga-someone-else", "priority": 1}],   # hq-074 absent
    }
    _bd_approved = lambda root: [_make_bead("hq-074", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["hq-074"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)   # alarm #1 — bead absent from queue, qpos=QPOS_ABSENT recorded
    first_body_e = next((b for s, b in mail_calls if "hq-074" in s), None)
    # Second cycle >1h later (past the AC3 1h escalation tier): hq-074 now
    # appears at the FRONT of a fresh queue — still not suppressed (index 0),
    # so alarm #2 fires; its body should say what changed since alarm #1.
    _read_pilot_dispatchable_file = lambda: {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW + 3700)),
        "ttl_seconds": 600,
        "count": 1,
        "items": [{"id": "hq-074", "priority": 1}],
    }
    _read_pilot_log_lines = lambda: _pilot_recent_at(NOW + 3700)
    _reset_captures()
    run_cycle(NOW + 3700, st)
    second_body_e = next((b for s, b in mail_calls if "hq-074" in s), None)
    if (first_body_e is not None and "NOT found among 1 dispatchable" in first_body_e
            and second_body_e is not None
            and "changed from not found in queue to front of queue" in second_body_e):
        _ok("(ga-tky97-e): repeat alarm #2 reports the queue-status delta "
            "('not found' → 'front of queue') since alarm #1, not just a "
            "bare repeat count")
    else:
        _bad("(ga-tky97-e)", "first_body=%r second_body=%r" % (first_body_e, second_body_e))

    # (ga-tky97-f) hermetic-selftest-cannot-test-the-bootstrap-it-stubs class:
    # every scenario above bypasses _read_pilot_dispatchable()'s ACTUAL file
    # I/O + UTC-epoch math via the _read_pilot_dispatchable_file seam — a bug
    # in that real parsing logic (e.g. a local-time-vs-UTC mistake) would ship
    # with every scenario above still green. Un-stub the seam and exercise the
    # real function against a genuine file on disk.
    print("\nScenario (ga-tky97-f): REAL _read_pilot_dispatchable() (seam OFF) "
          "— a genuinely fresh file parses correctly, a stale one (past its "
          "own ttl_seconds) returns None, a missing file returns None")
    _read_pilot_dispatchable_file = None   # un-stub — force the real function body
    _tmp_pd_path = "/tmp/arc-selftest-pilot-dispatchable-%d.json" % os.getpid()
    _real_pd_const = PILOT_DISPATCHABLE_FILE
    globals()["PILOT_DISPATCHABLE_FILE"] = _tmp_pd_path
    _fresh_gen = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW - 60))    # 1min old
    _stale_gen = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW - 700))   # 11.67min old
    with open(_tmp_pd_path, "w") as _f:
        json.dump({"generated_at": _fresh_gen, "ttl_seconds": 600, "count": 1,
                    "items": [{"id": "hq-099", "priority": 1}]}, _f)
    fresh_result = _read_pilot_dispatchable(NOW)
    with open(_tmp_pd_path, "w") as _f:
        json.dump({"generated_at": _stale_gen, "ttl_seconds": 600, "count": 1,
                    "items": [{"id": "hq-099", "priority": 1}]}, _f)
    stale_result = _read_pilot_dispatchable(NOW)
    os.remove(_tmp_pd_path)
    missing_result = _read_pilot_dispatchable(NOW)
    globals()["PILOT_DISPATCHABLE_FILE"] = _real_pd_const
    fresh_ok = (fresh_result is not None
                and fresh_result.get("items") == [{"id": "hq-099", "priority": 1}])
    stale_ok = stale_result is None
    missing_ok = missing_result is None
    if fresh_ok and stale_ok and missing_ok:
        _ok("(ga-tky97-f): REAL file I/O — fresh file (1min old, ttl=600s) "
            "parses correctly; stale file (11.67min old, ttl=600s) → None; "
            "missing file → None (never silently trusts unmeasured data)")
    else:
        _bad("(ga-tky97-f)", "fresh_result=%r stale_result=%r missing_result=%r" % (
             fresh_result, stale_result, missing_result))

    # (ga-abfcdz-a) the reader's bare None collapses absent/malformed/stale —
    # this proves the COMPANION classifier tells them apart via REAL file I/O
    # (both seams off, mirroring ga-tky97-f's own methodology exactly), not
    # just via a mocked seam.
    print("\nScenario (ga-abfcdz-a): REAL _pilot_dispatchable_unreadable_reason() "
          "(both seams OFF) — absent/malformed/stale classified DISTINCTLY, "
          "never collapsed to one value")
    _read_pilot_dispatchable_file = None      # un-stub (mirrors ga-tky97-f)
    _pilot_dispatchable_reason_file = None    # un-stub — force the real function body
    _tmp_pdr_path = "/tmp/arc-selftest-pilot-dispatchable-reason-%d.json" % os.getpid()
    _real_pdr_const = PILOT_DISPATCHABLE_FILE
    globals()["PILOT_DISPATCHABLE_FILE"] = _tmp_pdr_path
    if os.path.exists(_tmp_pdr_path):
        os.remove(_tmp_pdr_path)
    absent_reason = _pilot_dispatchable_unreadable_reason(NOW)
    with open(_tmp_pdr_path, "w") as _f:
        _f.write("{not valid json at all")
    malformed_reason = _pilot_dispatchable_unreadable_reason(NOW)
    with open(_tmp_pdr_path, "w") as _f:
        json.dump({"generated_at": _stale_gen, "ttl_seconds": 600, "count": 0,
                    "items": []}, _f)
    stale_reason = _pilot_dispatchable_unreadable_reason(NOW)
    os.remove(_tmp_pdr_path)
    globals()["PILOT_DISPATCHABLE_FILE"] = _real_pdr_const
    if absent_reason == "absent" and malformed_reason == "malformed" and stale_reason == "stale":
        _ok("(ga-abfcdz-a): REAL file I/O correctly classifies all 3 distinctly "
            "— absent=%r malformed=%r stale=%r (never the same value)" % (
            absent_reason, malformed_reason, stale_reason))
    else:
        _bad("(ga-abfcdz-a)", "absent_reason=%r malformed_reason=%r stale_reason=%r "
             "(want 'absent'/'malformed'/'stale')" % (
             absent_reason, malformed_reason, stale_reason))

    # (ga-abfcdz-b) the actual human-facing text must differ too, not just the
    # internal reason value — this is what a reviewer/Mayor reading the mail
    # body or the cycle log actually sees.
    print("\nScenario (ga-abfcdz-b): _pilot_queue_body_line renders DISTINCT "
          "text for absent vs stale — no longer the same 'missing/stale/"
          "unreadable' phrase for both (ga-abfcdz)")
    _pilot_dispatchable_reason_file = lambda: "absent"
    absent_body = _pilot_queue_body_line("some-bead", None, NOW)
    _pilot_dispatchable_reason_file = lambda: "stale"
    stale_body = _pilot_queue_body_line("some-bead", None, NOW)
    _pilot_dispatchable_reason_file = None
    if (absent_body != stale_body
            and "MISSING" in absent_body and "STALE" in stale_body
            and "COULD NOT READ" in absent_body and "COULD NOT READ" in stale_body
            and "UNCERTAIN" in absent_body and "UNCERTAIN" in stale_body):
        _ok("(ga-abfcdz-b): absent and stale render DISTINCT body text (absent "
            "says MISSING, stale says STALE) while both keep the stable "
            "'COULD NOT READ'/'UNCERTAIN' substrings older callers key off of")
    else:
        _bad("(ga-abfcdz-b)", "absent_body=%r stale_body=%r" % (absent_body, stale_body))

    # (ga-tky97-g..j) GATE-FEEDBACK fix (attempt 1 FAIL): qpos=None used to mean
    # both ABSENT (queue read fine, bead not in it) and UNREADABLE (queue snapshot
    # itself failed this cycle) — a delta comparing two such Nones could assert
    # "unchanged" across a cycle that was never actually measured. These four
    # scenarios are the falsifiable AC from the Mayor's fix spec: the three
    # UNREADABLE-involved transitions must never claim unchanged/changed, and the
    # one all-measured transition (ABSENT -> ABSENT) still must.
    print("\nScenario (ga-tky97-g): GATE-FEEDBACK fix — previous cycle's queue was "
          "UNREADABLE, current cycle confirms the bead absent from a fresh read → "
          "delta must NOT claim unchanged/changed (previous side was never measured)")
    _read_pilot_dispatchable_file = lambda: None   # cycle 1: unreadable
    _bd_approved = lambda root: [_make_bead("hq-075", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["hq-075"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)   # alarm #1 — dispatchable unreadable, qpos=QPOS_UNREADABLE recorded
    first_body_g = next((b for s, b in mail_calls if "hq-075" in s), None)
    _read_pilot_dispatchable_file = lambda: {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW + 3700)),
        "ttl_seconds": 600,
        "count": 1,
        "items": [{"id": "ga-someone-else", "priority": 1}],   # hq-075 confirmed absent
    }
    _read_pilot_log_lines = lambda: _pilot_recent_at(NOW + 3700)
    _reset_captures()
    run_cycle(NOW + 3700, st)   # alarm #2 — queue now readable, bead confirmed absent
    second_body_g = next((b for s, b in mail_calls if "hq-075" in s), None)
    if (first_body_g is not None and "COULD NOT READ" in first_body_g
            and second_body_g is not None
            and "not comparable" in second_body_g
            and "previous cycle" in second_body_g
            and "unchanged" not in second_body_g and "changed from" not in second_body_g):
        _ok("(ga-tky97-g): prev cycle unreadable, current confirmed-absent → "
            "delta says not-comparable instead of fabricating unchanged/changed")
    else:
        _bad("(ga-tky97-g)", "first_body=%r second_body=%r" % (first_body_g, second_body_g))

    print("\nScenario (ga-tky97-h): GATE-FEEDBACK fix — THE EXACT REVIEWER REPRO: "
          "previous cycle confirmed the bead absent from a readable queue, current "
          "cycle's queue is UNREADABLE → the same mail body must not say both "
          "'COULD NOT READ ... UNCERTAIN' and 'Since last alarm: unchanged'")
    _read_pilot_dispatchable_file = lambda: {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW)),
        "ttl_seconds": 600,
        "count": 1,
        "items": [{"id": "ga-someone-else", "priority": 1}],   # hq-076 confirmed absent
    }
    _bd_approved = lambda root: [_make_bead("hq-076", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["hq-076"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)   # alarm #1 — confirmed absent, qpos=QPOS_ABSENT recorded
    first_body_h = next((b for s, b in mail_calls if "hq-076" in s), None)
    _read_pilot_dispatchable_file = lambda: None   # cycle 2: unreadable
    _read_pilot_log_lines = lambda: _pilot_recent_at(NOW + 3700)
    _reset_captures()
    run_cycle(NOW + 3700, st)   # alarm #2 — dispatchable unreadable this cycle
    second_body_h = next((b for s, b in mail_calls if "hq-076" in s), None)
    if (first_body_h is not None and "NOT found among 1 dispatchable" in first_body_h
            and second_body_h is not None
            and "COULD NOT READ" in second_body_h
            and "not comparable" in second_body_h
            and "this cycle" in second_body_h
            and "unchanged" not in second_body_h and "changed from" not in second_body_h):
        _ok("(ga-tky97-h): prev confirmed-absent, current unreadable → same "
            "message never pairs COULD NOT READ with a continuity claim")
    else:
        _bad("(ga-tky97-h)", "first_body=%r second_body=%r" % (first_body_h, second_body_h))

    print("\nScenario (ga-tky97-i): GATE-FEEDBACK fix — BOTH the previous and "
          "current cycle's queue were UNREADABLE → delta must NOT claim "
          "unchanged/changed (neither side was ever measured)")
    _read_pilot_dispatchable_file = lambda: None
    _bd_approved = lambda root: [_make_bead("hq-077", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["hq-077"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)   # alarm #1 — unreadable
    first_body_i = next((b for s, b in mail_calls if "hq-077" in s), None)
    _read_pilot_log_lines = lambda: _pilot_recent_at(NOW + 3700)
    _reset_captures()
    run_cycle(NOW + 3700, st)   # alarm #2 — still unreadable
    second_body_i = next((b for s, b in mail_calls if "hq-077" in s), None)
    if (first_body_i is not None and "COULD NOT READ" in first_body_i
            and second_body_i is not None
            and "COULD NOT READ" in second_body_i
            and "not comparable" in second_body_i
            and "previous cycle and this cycle" in second_body_i
            and "unchanged" not in second_body_i and "changed from" not in second_body_i):
        _ok("(ga-tky97-i): both cycles unreadable → delta names both sides as "
            "not comparable, never fabricates continuity")
    else:
        _bad("(ga-tky97-i)", "first_body=%r second_body=%r" % (first_body_i, second_body_i))

    print("\nScenario (ga-tky97-j): GATE-FEEDBACK fix guard — both the previous "
          "AND current cycle confirm the bead absent from a freshly-read queue → "
          "delta MUST still say 'unchanged' (both sides were actually measured; "
          "the fix must not overcorrect into treating every non-int qpos as "
          "incomparable)")
    _read_pilot_dispatchable_file = lambda: {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW)),
        "ttl_seconds": 600,
        "count": 1,
        "items": [{"id": "ga-someone-else", "priority": 1}],   # hq-078 confirmed absent
    }
    _bd_approved = lambda root: [_make_bead("hq-078", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["hq-078"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)   # alarm #1 — confirmed absent
    first_body_j = next((b for s, b in mail_calls if "hq-078" in s), None)
    _read_pilot_dispatchable_file = lambda: {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW + 3700)),
        "ttl_seconds": 600,
        "count": 1,
        "items": [{"id": "ga-someone-else", "priority": 1}],   # still absent
    }
    _read_pilot_log_lines = lambda: _pilot_recent_at(NOW + 3700)
    _reset_captures()
    run_cycle(NOW + 3700, st)   # alarm #2 — still confirmed absent
    second_body_j = next((b for s, b in mail_calls if "hq-078" in s), None)
    if (first_body_j is not None and "NOT found among 1 dispatchable" in first_body_j
            and second_body_j is not None
            and "unchanged (not found in queue)" in second_body_j):
        _ok("(ga-tky97-j): both cycles confirm absence (measured, not unreadable) "
            "→ delta correctly says 'unchanged' — fix doesn't overcorrect into "
            "blanket uncertainty")
    else:
        _bad("(ga-tky97-j)", "first_body=%r second_body=%r" % (first_body_j, second_body_j))

    # Restore the neutral hermetic default so later scenarios (which don't
    # exercise the pilot-queue-position feature) are unaffected.
    _read_pilot_dispatchable_file = lambda: None

    print("\nScenario (ga-32u6s-e) gate-fix-1 regression guard: unresolvable "
          "`git merge-base --is-ancestor` (r is None, or returncode not in (0,1) e.g. "
          "128 for a missing origin/main ref) must fail OPEN — calls the REAL "
          "_real_branch_stranded_reason() directly (bypassing the _bd_branch_stranded "
          "stub scenarios a-d rely on), the exact path the gate reviewer's own repro "
          "exercised")
    _real_sh = _sh
    _real_ownership_repos = _OWNERSHIP_REPOS
    _OWNERSHIP_REPOS = ["/tmp"]  # any real dir — _sh is faked below, no real git runs
    OLD_EPOCH_E = int(NOW) - 30 * 86400  # 30d old — well past BRANCH_STRANDED_STALE_HOURS,
                                          # so a code path that WRONGLY proceeds past the
                                          # merge-base check reaches a "stranded" verdict
                                          # instead of silently no-oping into the same None

    def _fake_sh_e_none(args, timeout=20):
        if "for-each-ref" in args:
            return subprocess.CompletedProcess(
                args=args, returncode=0, stdout="refs/heads/fix/ga-eee1-slug\n")
        if "merge-base" in args:
            return None  # _sh's own except-Exception shape (subprocess timeout/error)
        if "log" in args:
            return subprocess.CompletedProcess(
                args=args, returncode=0, stdout="%d\n" % OLD_EPOCH_E)
        return subprocess.CompletedProcess(args=args, returncode=0, stdout="")

    _sh = _fake_sh_e_none
    res_e_none = _real_branch_stranded_reason("ga-eee1")

    def _fake_sh_e_128(args, timeout=20):
        if "for-each-ref" in args:
            return subprocess.CompletedProcess(
                args=args, returncode=0, stdout="refs/heads/fix/ga-eee2-slug\n")
        if "merge-base" in args:
            return subprocess.CompletedProcess(
                args=args, returncode=128, stdout="", stderr="fatal: no such ref 'origin/main'")
        if "log" in args:
            return subprocess.CompletedProcess(
                args=args, returncode=0, stdout="%d\n" % OLD_EPOCH_E)
        return subprocess.CompletedProcess(args=args, returncode=0, stdout="")

    _sh = _fake_sh_e_128
    res_e_128 = _real_branch_stranded_reason("ga-eee2")

    _sh = _real_sh
    _OWNERSHIP_REPOS = _real_ownership_repos
    if res_e_none is None and res_e_128 is None:
        _ok("(ga-32u6s-e): unresolvable merge-base (r=None / returncode=128) fails "
            "OPEN — returns None instead of misreporting stranded")
    else:
        _bad("(ga-32u6s-e)", "SAFETY VIOLATION — unresolvable merge-base treated as "
             "confirmed-unmerged, would fire a FALSE stranded-branch alert to the "
             "Mayor; res_e_none=%r res_e_128=%r" % (res_e_none, res_e_128))

    # ── ga-nq0jo: Pilot whole-sweep pause suppression ───────────────────────────
    print("\nScenario (ga-nq0jo-a): THE EXACT ga-sb11i.4 REPRO — healthy front-of-"
          "queue starving bead, Pilot's last sweep paused for cross-stage yield "
          "→ starve alarm SUPPRESSED")
    _read_pilot_sweep_pause_state_file = lambda: {
        "active": True, "reason": "cross-stage-yield",
        "detail": "gate_congested=1 quota_limited=0 dolt_hot=1",
        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW)),
    }
    _read_pilot_dispatchable_file = lambda: None   # no queue-position excuse either — front of queue
    _bd_approved = lambda root: [_make_bead("ga-sb11i4", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["ga-sb11i4"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)
    if not mail_calls and not notify_calls:
        _ok("(ga-nq0jo-a): sweep-pause active+fresh suppresses the alarm — "
            "healthy backpressure, not dispatch failure")
    else:
        _bad("(ga-nq0jo-a)", "mail_calls=%s notify_calls=%s" % (mail_calls, notify_calls))

    print("\nScenario (ga-nq0jo-b): falsification — sweep-pause CONFIRMED "
          "inactive (Pilot's last sweep ran normally) → bead STILL alarms "
          "(must not become a false negative)")
    _read_pilot_sweep_pause_state_file = lambda: {
        "active": False, "reason": "", "detail": "",
        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW)),
    }
    _read_pilot_dispatchable_file = lambda: None
    _bd_approved = lambda root: [_make_bead("ga-sb11i4b", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["ga-sb11i4b"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)
    if mail_calls or notify_calls:
        _ok("(ga-nq0jo-b): confirmed-inactive sweep-pause does NOT suppress — "
            "alarm still fires (no false negative introduced)")
    else:
        _bad("(ga-nq0jo-b)", "SAFETY VIOLATION — a confirmed-healthy sweep "
             "(active=False) suppressed a real starving bead; "
             "mail_calls=%s notify_calls=%s" % (mail_calls, notify_calls))

    print("\nScenario (ga-nq0jo-c): falsification (root-class:error-vs-empty) — "
          "sweep-pause-state file missing/unreadable (seam returns None) → "
          "bead STILL alarms (unmeasured must never license a suppression)")
    _read_pilot_sweep_pause_state_file = lambda: None
    _read_pilot_dispatchable_file = lambda: None
    _bd_approved = lambda root: [_make_bead("ga-sb11i4c", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    st["first_seen_approved"]["ga-sb11i4c"] = NOW - (_STARVE + 5) * 60
    run_cycle(NOW, st)
    if mail_calls or notify_calls:
        _ok("(ga-nq0jo-c): unmeasurable sweep-pause state does NOT suppress — "
            "'don't know' never collapses into 'confirmed paused'")
    else:
        _bad("(ga-nq0jo-c)", "SAFETY VIOLATION — an UNREADABLE sweep-pause file "
             "suppressed a real starving bead (root-class:error-vs-empty); "
             "mail_calls=%s notify_calls=%s" % (mail_calls, notify_calls))

    print("\nScenario (ga-nq0jo-d): REAL _read_pilot_sweep_pause_state() (seam "
          "OFF) — a genuinely fresh file parses correctly, a stale one (past "
          "PILOT_SWEEP_PAUSE_TTL_SEC) returns None, a missing file returns "
          "None. Mirrors ga-tky97-f's real-file-I/O methodology.")
    _read_pilot_sweep_pause_state_file = None   # un-stub — force the real function body
    _tmp_ps_path = "/tmp/arc-selftest-pilot-sweep-pause-%d.json" % os.getpid()
    _real_ps_const = PILOT_SWEEP_PAUSE_STATE_FILE
    globals()["PILOT_SWEEP_PAUSE_STATE_FILE"] = _tmp_ps_path
    _fresh_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW - 60))   # 1min old
    _stale_at = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                               time.gmtime(NOW - PILOT_SWEEP_PAUSE_TTL_SEC - 120))  # past TTL
    with open(_tmp_ps_path, "w") as _f:
        json.dump({"active": True, "reason": "cross-stage-yield",
                    "detail": "gate_congested=1", "at": _fresh_at}, _f)
    fresh_result = _read_pilot_sweep_pause_state(NOW)
    with open(_tmp_ps_path, "w") as _f:
        json.dump({"active": True, "reason": "cross-stage-yield",
                    "detail": "stale entry", "at": _stale_at}, _f)
    stale_result = _read_pilot_sweep_pause_state(NOW)
    os.remove(_tmp_ps_path)
    missing_result = _read_pilot_sweep_pause_state(NOW)
    globals()["PILOT_SWEEP_PAUSE_STATE_FILE"] = _real_ps_const
    fresh_ok = (fresh_result is not None and fresh_result.get("active") is True)
    stale_ok = stale_result is None
    missing_ok = missing_result is None
    if fresh_ok and stale_ok and missing_ok:
        _ok("(ga-nq0jo-d): REAL file I/O — fresh file (1min old, ttl=%ds) "
            "parses correctly; stale file (past ttl) → None; missing file → "
            "None (never silently trusts unmeasured/stale data)" % PILOT_SWEEP_PAUSE_TTL_SEC)
    else:
        _bad("(ga-nq0jo-d)", "fresh_result=%r stale_result=%r missing_result=%r" % (
             fresh_result, stale_result, missing_result))

    _read_pilot_sweep_pause_state_file = None   # leave the seam clean for any test after this one

    print("\nScenario (ga-ndh7jm): the SHIPPED DEFAULT PILOT_SWEEP_PAUSE_TTL_SEC "
          "must comfortably exceed the measured real sweep-to-sweep intervals, "
          "not just equal the nominal StartInterval (same bug class as ga-abfcdz)")
    # 15 real consecutive intervals measured from pilot-dispatcher.log's per-sweep
    # "Dolt health OK/SATURATED/UNREADABLE" marker (logged moments before this
    # file's own write on every sweep — see this constant's own comment above):
    # 731 713 759 736 706 641 644 640 648 641 755 729 702 711 737. The OLD
    # default (600s = StartInterval) was LESS than every single one — proven RED
    # against the pre-fix 600 default (600 < 759, the measured max) and GREEN
    # against this fix's 1800.
    _MAX_MEASURED_SWEEP_PAUSE = 759
    if PILOT_SWEEP_PAUSE_TTL_SEC > _MAX_MEASURED_SWEEP_PAUSE:
        _ok("(ga-ndh7jm): shipped PILOT_SWEEP_PAUSE_TTL_SEC default (%d) exceeds "
            "the measured max real interval (%ds) — a fresh write is reachable, "
            "not permanently stale" % (
                PILOT_SWEEP_PAUSE_TTL_SEC, _MAX_MEASURED_SWEEP_PAUSE))
    else:
        _bad("(ga-ndh7jm)", "REGRESSION: shipped PILOT_SWEEP_PAUSE_TTL_SEC "
             "default (%d) does NOT exceed the measured max real interval "
             "(%ds) — consumers can never confirm a fresh read" % (
                 PILOT_SWEEP_PAUSE_TTL_SEC, _MAX_MEASURED_SWEEP_PAUSE))
    # Upper sanity bound (ga-00qma2's own lesson, applied here too — same as
    # ga-abfcdz's sibling scenario): a TTL so generous that staleness becomes
    # structurally unreachable is the same bug in the other direction.
    if PILOT_SWEEP_PAUSE_TTL_SEC < 7200:
        _ok("(ga-ndh7jm): shipped PILOT_SWEEP_PAUSE_TTL_SEC default (%d) is not "
            "so generous that staleness becomes unreachable (< 7200s ceiling, "
            "ga-00qma2 lesson)" % PILOT_SWEEP_PAUSE_TTL_SEC)
    else:
        _bad("(ga-ndh7jm)", "shipped PILOT_SWEEP_PAUSE_TTL_SEC default (%d) is "
             ">= 7200s — staleness may be structurally unreachable again, same "
             "class as ga-00qma2" % PILOT_SWEEP_PAUSE_TTL_SEC)

    # ── ga-tma6wc: sweep-pause HISTORY context on the starving alarm ───────────
    def _sweep_log_line(epoch, paused_reason=None):
        ts = time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(epoch))
        if paused_reason:
            return ("%s [pilot-dispatcher] === Pilot sweep complete: dispatched=0 "
                     "(paused: %s) ===" % (ts, paused_reason))
        return ("%s [pilot-dispatcher] === Pilot sweep complete: dispatched=3 "
                 "(small_slots=2 big_slots=1) ===" % ts)

    print("\nScenario (ga-tma6wc-a): _pilot_sweep_pause_history() counts paused "
          "vs total sweeps WITHIN the bead's wait window, correctly EXCLUDING an "
          "older paused sweep that falls outside it (boundary correctness)")
    _read_pilot_log_lines = lambda: [
        _sweep_log_line(NOW - 4000, "ram-pressure"),   # OUTSIDE 60min window — must be excluded
        _sweep_log_line(NOW - 600),                     # in-window, normal
        _sweep_log_line(NOW - 500),                     # in-window, normal
        _sweep_log_line(NOW - 400, "ram-pressure"),      # in-window, paused
        _sweep_log_line(NOW - 300, "quota-limited"),     # in-window, paused
        _sweep_log_line(NOW - 200, "quiet-hours"),       # in-window, paused
        _sweep_log_line(NOW - 100, "ram-pressure"),      # in-window, paused
    ]
    paused_a, total_a = _pilot_sweep_pause_history(NOW, 60.0)
    if (paused_a, total_a) == (4, 6):
        _ok("(ga-tma6wc-a): 4 paused / 6 total within the 60min window — the "
            "older paused sweep outside the window was correctly excluded from "
            "both counts, not just from 'paused'")
    else:
        _bad("(ga-tma6wc-a)", "got (paused, total)=(%r, %r), want (4, 6)" % (paused_a, total_a))

    print("\nScenario (ga-tma6wc-b): falsification (root-class:error-vs-empty) — "
          "tail doesn't reach back the full window → UNMEASURABLE (None, None), "
          "never a falsely-low count; body line says NÃO MEDIDO, never fabricates 0")
    _read_pilot_log_lines = lambda: [
        _sweep_log_line(NOW - 600),
        _sweep_log_line(NOW - 500),
        _sweep_log_line(NOW - 400, "ram-pressure"),
    ]   # oldest line is only 600s back — does NOT reach the 3600s (60min) cutoff
    paused_b, total_b = _pilot_sweep_pause_history(NOW, 60.0)
    body_b = _pilot_sweep_pause_body_line(paused_b, total_b)
    if paused_b is None and total_b is None and "NÃO MEDIDO" in body_b:
        _ok("(ga-tma6wc-b): incomplete tail → (None, None), body line says NÃO "
            "MEDIDO — never silently reports a falsely-low paused count")
    else:
        _bad("(ga-tma6wc-b)", "got (paused, total)=(%r, %r) body=%r" % (
             paused_b, total_b, body_b))

    print("\nScenario (ga-tma6wc-c): END-TO-END, mirrors the real wa-1ccdz/"
          "ga-il5hs repro — a starving bead that is NOT currently suppressed "
          "(sweep-pause confirmed inactive, no queue-position excuse) still "
          "alarms (correctly — something IS currently unexplained), but the "
          "fired alarm's subject+body now NAME the sweep-pause history instead "
          "of leaving the reader to think the full age is 100% unexplained "
          "dispatch failure")
    _read_pilot_sweep_pause_state_file = lambda: {
        "active": False, "reason": "", "detail": "",
        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW)),
    }
    _read_pilot_dispatchable_file = lambda: None
    _bd_approved = lambda root: [_make_bead("ga-tma6wc-c", age_min=70.0)]
    _read_pilot_log_lines = lambda: [
        _sweep_log_line(NOW - 4300, "ram-pressure"),   # OUTSIDE 70min window — excluded
        _sweep_log_line(NOW - 3000, "ram-pressure"),    # in-window, paused
        _sweep_log_line(NOW - 2000, "ram-pressure"),    # in-window, paused
        _sweep_log_line(NOW - 1000),                    # in-window, normal
        _sweep_log_line(NOW - 500),                     # in-window, normal
        _sweep_log_line(NOW - 100),                     # in-window, normal (also satisfies pilot-alive)
    ]
    st = _reset()
    st["first_seen_approved"]["ga-tma6wc-c"] = NOW - 70.0 * 60
    run_cycle(NOW, st)
    fired = [c for c in mail_calls if "ga-tma6wc-c" in c[0]]
    if fired:
        subject, body = fired[0]
        subject_ok = "Pilot pausado 2/5 sweeps recentes" in subject
        body_ok = "2 dos últimos 5 sweeps" in body and "dispatch failing" in subject
        if subject_ok and body_ok:
            _ok("(ga-tma6wc-c): alarm still fires (genuinely unexplained by any "
                "current suppression) AND subject/body now name the sweep-pause "
                "history (2/5) instead of presenting the full age as unexplained")
        else:
            _bad("(ga-tma6wc-c)", "subject=%r body=%r" % (subject, body))
    else:
        _bad("(ga-tma6wc-c)", "expected an alarm (nothing currently suppresses "
             "this bead) but none fired — mail_calls=%s" % (mail_calls,))

    print("\nScenario (ga-tma6wc-d): falsification — zero paused sweeps measured "
          "in the window → subject gets NO suffix (no noise on the common case), "
          "body still explicitly says '0 dos últimos M sweeps' (never silent)")
    _read_pilot_dispatchable_file = lambda: None
    _bd_approved = lambda root: [_make_bead("ga-tma6wc-d", age_min=70.0)]
    _read_pilot_log_lines = lambda: [
        _sweep_log_line(NOW - 4300),   # OUTSIDE window, satisfies completeness
        _sweep_log_line(NOW - 3000),
        _sweep_log_line(NOW - 1000),
        _sweep_log_line(NOW - 100),
    ]
    st = _reset()
    st["first_seen_approved"]["ga-tma6wc-d"] = NOW - 70.0 * 60
    run_cycle(NOW, st)
    fired_d = [c for c in mail_calls if "ga-tma6wc-d" in c[0]]
    if fired_d:
        subject_d, body_d = fired_d[0]
        if ("Pilot pausado" not in subject_d
                and "0 dos últimos 3 sweeps" in body_d):
            _ok("(ga-tma6wc-d): zero-paused case adds no subject noise, "
                "body still explicit ('0 dos últimos 3 sweeps')")
        else:
            _bad("(ga-tma6wc-d)", "subject=%r body=%r" % (subject_d, body_d))
    else:
        _bad("(ga-tma6wc-d)", "expected an alarm but none fired — "
             "mail_calls=%s" % (mail_calls,))

    # ── result ────────────────────────────────────────────────────────────────
    print("\n[reconciler selftest] %d passed, %d failed" % (ok_count[0], fail_count[0]))
    if fail_count[0]:
        sys.exit(1)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        main()
