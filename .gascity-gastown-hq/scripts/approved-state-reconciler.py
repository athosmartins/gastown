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
  • needs-human: label gate:needs-human* (prefix) or story:needs-human ONLY.
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

# ── paths ─────────────────────────────────────────────────────────────────────
CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
PILOT_LOG = os.path.join(CITY, ".gc/logs/pilot-dispatcher.log")
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
# FLOW_GRACE_MIN: recently-dispatched beads are assumed to be flowing.
FLOW_GRACE_MIN = int(os.environ.get("FLOW_GRACE_MIN", "10"))
# Per-bead cooldowns to prevent churn/spam on repeated runs.
ROUTE_COOLDOWN_SEC = int(os.environ.get("ARC_ROUTE_COOLDOWN_SEC", "1800"))   # 30min
ALARM_COOLDOWN_SEC = int(os.environ.get("ARC_ALARM_COOLDOWN_SEC", "1800"))   # 30min
BD_TIMEOUT = int(os.environ.get("ARC_BD_TIMEOUT", "25"))
# Pilot alive window: if no Pilot sweep-complete within this many minutes → pilot dead.
PILOT_ALIVE_WINDOW_MIN = int(os.environ.get("ARC_PILOT_ALIVE_WINDOW_MIN", "20"))
LOG_TAIL = int(os.environ.get("ARC_LOG_TAIL", "2000"))
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
                return d
    except Exception:
        pass
    return {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {},
            "reclaim_exhausted": {}}


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
    for key in ("routed", "alarmed", "first_seen_approved", "flagged", "reclaim_exhausted"):
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

    # 3. needs-human: gate:needs-human* (prefix) OR story:needs-human LABEL ONLY.
    if park_labels.NEEDS_HUMAN_LABEL in labels:
        return "needs-human", "label %s" % park_labels.NEEDS_HUMAN_LABEL
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


def _alarm_starving(rig_root, bead, age_min, now, state):
    """Fire a starve alarm for a buildable bead that has not been dispatched.

    This is case 3 of the core guarantee: the bead matched NONE of this
    reconciler's known non-buildable signals, is not flowing, and has been
    approved longer than STARVE_MIN with the Pilot alive — meaning the dispatch
    path is failing (or a signal this reconciler doesn't recognize yet — the
    mail body says so explicitly, see AC2). The operator MUST investigate.

    Never fires in DRY_RUN mode. See _alarm_backoff_sec()/_ALARM_ESCALATION_TIERS_SEC
    for the per-bead backoff/dedup policy (AC3) — this is no longer a flat cooldown.
    """
    bead_id = bead.get("id") or bead.get("issue_id") or ""
    if not bead_id:
        return

    labels_fp = ",".join(sorted(_get_labels(bead)))
    last_alarmed, count, prev_fp = _alarm_record(state, bead_id)
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

    # AC4: repeats are a known-issue heartbeat, not a fresh incident — tag the
    # subject distinctly (filterable/collapsible) and demote notify priority so
    # they don't bury a genuinely different alert class (disk-floor, circuit-
    # break, lca) landing in the same inbox window.
    if alarm_ordinal == 1:
        subject = ("Reconciler: buildable bead %s starving %dmin — dispatch failing"
                   % (bead_id, int(age_min)))
        notify_prio = 4
    else:
        subject = ("Reconciler: buildable bead %s STILL starving %dmin (repeat #%d) "
                   "— dispatch failing" % (bead_id, int(age_min), alarm_ordinal))
        notify_prio = 2

    # AC2: the old body asserted "This bead has NO explicit non-buildable signal"
    # as an absolute fact — false whenever the checked-signal list was
    # incomplete (exactly this bug: blocked-on:/waiting-on:/etc. WERE explicit
    # signals the reconciler simply didn't know). Say what was actually
    # checked, and hedge honestly that the list can itself go stale again.
    body = (
        "APPROVED-STATE-RECONCILER: buildable bead starving — dispatch path failing\n\n"
        "Bead: %s — %s\n"
        "Status: story:approved, age: %dmin, not dispatched, pilot alive, "
        "alarm #%d for this incident\n\n"
        "This bead matched NONE of this reconciler's known non-buildable signals\n"
        "(blocked-on:*, waiting-on:*, depends-on:*, next-action:*, pool:refused:*,\n"
        "gate:{needs-fix,failed,queued,reviewing,needs-human}, exec:manual,\n"
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
    ) % (bead_id, title, int(age_min), alarm_ordinal, STARVE_MIN, rig_root, bead_id)

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
        "last": now, "count": alarm_ordinal, "fp": labels_fp,
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
        r = _sh(["bash", BD_LIST_CACHED, "-C", CITY, "list", "-l", "type:quality-gate-marker",
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


# ── process one store ─────────────────────────────────────────────────────────
def _process_store(rig_root, now, state, pilot_alive, built_ids, blocked_ids):
    """Scan story:approved open beads in rig_root; classify and act on each one.

    built_ids: set of bead ids with a live BUILT marker (from _gate_marker_source_beads(),
    computed ONCE per cycle in run_cycle() — markers live only in HQ, not per-rig), or None
    if that query failed (fail-safe: caller must not alarm when built-state is unknown).

    blocked_ids: set of bead ids in THIS rig_root blocked by an open formal dependency
    (from _blocked_bead_ids(rig_root), computed once per rig_root — dependencies are
    rig-scoped, unlike built_ids), or None if that query failed (same fail-safe: caller
    must not alarm when dependency-block state is unknown, ga-yavyq AC2).

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

        # pilot:held-until — pilot explicitly parked this bead.
        if _has_prefix(labels, park_labels.PILOT_HELD_LABEL + "-until"):
            _log("  %s: no signal, daemon-age=%.0fmin, pilot:held-until — no alarm" % (
                 bead_id, starve_age_min))
            continue

        # pilot:held (bare, no -until suffix) — a DISTINCT label family from
        # pilot:held-until:<epoch> above (no expiry to parse); pilot deliberately
        # parked this bead (ga-an81u AC1).
        if park_labels.PILOT_HELD_LABEL in labels:
            _log("  %s: no signal, daemon-age=%.0fmin, pilot:held — no alarm" % (
                 bead_id, starve_age_min))
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

        # ALARM: buildable bead starving, pilot alive, pool has capacity, dispatch failing.
        _alarm_starving(rig_root, bead, starve_age_min, now, state)
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
            p, r, a = _process_store(rig_root, now, state, pilot_alive, built_ids, blocked_ids)
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
    """
    global _bd_approved, _bd_label_add, _bd_label_remove, _bd_comment
    global _do_notify, _do_mail_mayor, _read_pilot_log_lines, _bd_gate_markers, _sh
    global _bd_blocked
    global DRY_RUN, STARVE_MIN, FLOW_GRACE_MIN, ROUTE_COOLDOWN_SEC, ALARM_COOLDOWN_SEC

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
        seam is unstubbed (_pool_has_capacity's `gc session list`, and
        _gate_marker_source_beads' `bd ... type:quality-gate-marker` fallback)
        need DIFFERENT-looking failure handling: an rc!=0 here would make the
        marker query return None (query error) instead of an empty set, which
        flips built_ids-is-None → "unknown, fail-safe, no alarm" for every
        scenario that doesn't explicitly stub _bd_gate_markers — silently
        suppressing the very alarms scenarios (g)/(o)/(dd)/etc. exist to check
        for. "[]" satisfies both: the marker query parses it as zero open
        markers (correct, harmless); gc-session-list's dict .get() raises on a
        bare list, caught by that call site's own try/except → "capacity
        unknown, alarm conservatively" — the same fail-open outcome, just via
        the exception path instead of the empty-stdout path. Every OTHER real
        _sh call site (label add/remove/comment, notify, mail send, the main
        story:approved query) is only reached when its own dedicated seam
        (_bd_label_add etc.) is None, and every scenario in this suite always
        stubs those directly — this generic fallback never reaches them.
        """
        return subprocess.CompletedProcess(args=args, returncode=0, stdout="[]", stderr="")

    _bd_label_add = _stub_label_add
    _bd_label_remove = _stub_label_remove
    _bd_comment = _stub_comment
    _do_mail_mayor = _stub_mail
    _do_notify = _stub_notify
    _sh = _stub_sh_fast

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

    # ── result ────────────────────────────────────────────────────────────────
    print("\n[reconciler selftest] %d passed, %d failed" % (ok_count[0], fail_count[0]))
    if fail_count[0]:
        sys.exit(1)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        main()
