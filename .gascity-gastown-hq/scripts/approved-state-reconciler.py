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

# ── paths ─────────────────────────────────────────────────────────────────────
CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
PILOT_LOG = os.path.join(CITY, ".gc/logs/pilot-dispatcher.log")
NOTIFY_BIN = os.environ.get("NOTIFY_BIN", "/Users/athos/.local/bin/notify")
GC_BIN = os.environ.get("GC_BIN", "gc")
BD_BIN = os.environ.get("BD_BIN", "bd")
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
_bd_gate_markers = None     # (rig_root) -> list[dict]|None; OPEN quality-gate-markers in the store


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
                return d
    except Exception:
        pass
    return {"routed": {}, "alarmed": {}, "first_seen_approved": {}, "flagged": {}}


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
    """
    cutoff = now - 7 * 24 * 3600
    for key in ("routed", "alarmed", "first_seen_approved", "flagged"):
        bucket = state.get(key, {})
        stale = [bid for bid, ts in bucket.items() if ts < cutoff]
        for bid in stale:
            del bucket[bid]
        if stale:
            _log("  pruned %d stale %s entries" % (len(stale), key))


# ── bd JSON parse ─────────────────────────────────────────────────────────────
def _parse_bd_json(raw):
    """Parse bd --json output (array or {issues:[]} envelope). Returns [] on any failure."""
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
            return []
    except Exception:
        return []
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

    # 1. post-build: gate:passed — the bead already built; delivery owns next state.
    if _has_prefix(labels, "gate:passed"):
        for lab in labels:
            if lab == "gate:passed" or lab.startswith("gate:passed:"):
                return "post-build", "label %s" % lab
        return "post-build", "gate:passed label present"

    # 2. needs-device: LABEL ONLY.
    if "story:needs-device" in labels:
        return "needs-device", "label story:needs-device"

    # 3. needs-human: gate:needs-human* (prefix) OR story:needs-human LABEL ONLY.
    if "story:needs-human" in labels:
        return "needs-human", "label story:needs-human"
    for lab in labels:
        if lab.startswith("gate:needs-human"):
            return "needs-human", "label %s" % lab

    # 4. blocked: LABEL ONLY (blocked or story:blocked).
    for lab in ("blocked", "story:blocked"):
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
    3. Non-empty assignee that is not 'mayor' — some builder holds it.

    Note: FLOW_GRACE_MIN (default 10min) is the env knob for operators to tune
    how long a dispatched bead is considered "freshly flowing" before alarming.
    """
    labels = _get_labels(bead)
    if "story:in-flight" in labels:
        return True
    if "pilot:dispatched" in labels:
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
def _alarm_starving(rig_root, bead, age_min, now, state):
    """Fire a starve alarm for a buildable bead that has not been dispatched.

    This is case 3 of the core guarantee: the bead has NO explicit non-buildable
    signal, is not flowing, and has been approved longer than STARVE_MIN with the
    Pilot alive — meaning the dispatch path is failing. The operator MUST investigate.

    Never fires in DRY_RUN mode. Per-bead cooldown prevents spam.
    """
    bead_id = bead.get("id") or bead.get("issue_id") or ""
    if not bead_id:
        return

    last_alarmed = state.get("alarmed", {}).get(bead_id, 0.0)
    if now - last_alarmed < ALARM_COOLDOWN_SEC:
        _log("  alarm cooldown active for %s (%.0fmin ago) — skipping" % (
             bead_id, (now - last_alarmed) / 60.0))
        return

    title = (bead.get("title") or bead.get("name") or "?")[:80]
    _log("ALARM starving: %s | age=%.0fmin | %s" % (bead_id, age_min, title))

    if DRY_RUN:
        _log("DRY_RUN: would alarm starving bead %s (age=%.0fmin)" % (bead_id, age_min))
        return  # no state update, no mutations

    subject = ("Reconciler: buildable bead %s starving %dmin — dispatch failing"
               % (bead_id, int(age_min)))
    body = (
        "APPROVED-STATE-RECONCILER: buildable bead starving — dispatch path failing\n\n"
        "Bead: %s — %s\n"
        "Status: story:approved, age: %dmin, not dispatched, pilot alive\n\n"
        "This bead has NO explicit non-buildable signal. It should have been dispatched\n"
        "within %dmin. The dispatch path is failing.\n\n"
        "INVESTIGAR:\n"
        "1. tail -40 .gc/logs/pilot-dispatcher.log — o Pilot está varrendo?\n"
        "2. bd -C %s show %s — labels corretos?\n"
        "3. gc rig list — algum rig suspenso?\n"
        "4. Se o Pilot varre e ignora este bead → bug de query ou filtro no pilot-dispatcher.sh.\n"
        "5. Verifique se o bead precisa de um label explícito (story:needs-device, etc.)\n"
        "   antes de tentar re-despachar — NÃO adicione story:approved de volta sem investigar.\n"
    ) % (bead_id, title, int(age_min), STARVE_MIN, rig_root, bead_id)

    notify_msg = ("STARVE ALARM: bead %s story:approved há %dmin, pilot alive, "
                  "não despachado — dispatch path failing" % (bead_id, int(age_min)))

    _arc_ledger("human-touch", {
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_daemon": "approved-state-reconciler",
        "stage": "starve-alarm",
        "bead_id": bead_id,
        "age_min": int(age_min),
        "rig_root": rig_root,
    }, fail_open=True)

    # Dolt-independent: notify fires FIRST and unconditionally.
    if _do_notify is not None:
        _do_notify(notify_msg, 4)
    else:
        _sh([NOTIFY_BIN, "-t", "Starve ALARM", "-p", "4", notify_msg], timeout=10)

    if _do_mail_mayor is not None:
        _do_mail_mayor(subject, body)
    else:
        _sh([GC_BIN, "mail", "send", MAYOR_ADDR, "-s", subject, "-m", body, "--notify"],
            timeout=45)

    _write_flow_authority(now, "approved-starve:%s" % bead_id)
    state.setdefault("alarmed", {})[bead_id] = now


# ── built-bead index ──────────────────────────────────────────────────────────
def _gate_marker_source_beads(rig_root):
    """Set of bead ids that an OPEN quality-gate-marker in this store points at (label
    source-bead:<id>). Such a bead is BUILT and awaiting the gate — PAST the dispatch
    stage — so the starve alarm must skip it: a built-but-still-story:approved bead is NOT
    a dispatch failure. (A marker can even be orphaned by the HQ-only gate scan — ga-pnugy
    — leaving the bead story:approved forever; that is a GATE bug, not a dispatch failure.)
    FAIL-SAFE: any query/parse error → empty set (never SUPPRESS a real dispatch alarm on an
    unreadable marker query — the same fail-toward-alarming bias as the rest of the daemon)."""
    if _bd_gate_markers is not None:
        rows = _bd_gate_markers(rig_root)          # test seam
    else:
        r = _sh([BD_BIN, "-C", rig_root, "list", "-l", "type:quality-gate-marker",
                 "--json", "-n", "200"], timeout=BD_TIMEOUT)
        if r is None or r.returncode != 0:
            return set()
        rows = _parse_bd_json(r.stdout)
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


# ── process one store ─────────────────────────────────────────────────────────
def _process_store(rig_root, now, state, pilot_alive):
    """Scan story:approved open beads in rig_root; classify and act on each one.

    Returns (processed, routed, alarmed) int counts.
    On query error: logs + returns (0, 0, 0) — fail-open; other stores are unaffected.
    """
    # Query story:approved open beads.
    if _bd_approved is not None:
        # Test seam: stub provided.
        beads = _bd_approved(rig_root)
        if beads is None:
            _log("  [%s] bd query error (stub returned None) — skipping store (fail-open)"
                 % os.path.basename(rig_root))
            return 0, 0, 0
    else:
        r = _sh([BD_BIN, "-C", rig_root, "list", "-l", "story:approved",
                 "--status", "open", "--json", "-n", "200"],
                timeout=BD_TIMEOUT)
        if r is None or r.returncode != 0:
            _log("  [%s] bd list story:approved failed (rc=%s) — skipping store (fail-open)"
                 % (os.path.basename(rig_root), r.returncode if r else "err"))
            return 0, 0, 0
        beads = _parse_bd_json(r.stdout)

    if not beads:
        _log("  [%s] 0 story:approved open beads" % os.path.basename(rig_root))
        return 0, 0, 0

    _log("  [%s] %d story:approved open bead(s) to evaluate" % (
         os.path.basename(rig_root), len(beads)))

    # Beads an OPEN gate marker points at are BUILT + awaiting the gate (past dispatch) →
    # the starve alarm skips them below (a built bead is not a dispatch failure).
    built_ids = _gate_marker_source_beads(rig_root)

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
        kw_flags = _keyword_flags(bead)
        if kw_flags:
            last_flagged = state.get("flagged", {}).get(bead_id, 0.0)
            if now - last_flagged >= ALARM_COOLDOWN_SEC:
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
                    state.setdefault("flagged", {})[bead_id] = now

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

        # Grace window: too fresh (daemon-side) to alarm.
        if starve_age_min < STARVE_MIN:
            _log("  %s: no signal, not flowing, first-seen-approved=%.1fmin "
                 "< STARVE_MIN=%d — grace" % (bead_id, starve_age_min, STARVE_MIN))
            continue

        # pilot:held-until — pilot explicitly parked this bead.
        if _has_prefix(labels, "pilot:held-until"):
            _log("  %s: no signal, daemon-age=%.0fmin, pilot:held-until — no alarm" % (
                 bead_id, starve_age_min))
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
        if "gate:needs-fix" in labels:
            _log("  %s: no signal, daemon-age=%.0fmin, gate:needs-fix (gate-fix loop owns "
                 "re-dispatch; cap→needs-human is the backstop) — no alarm" % (
                 bead_id, starve_age_min))
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
        if bead_id in built_ids:
            _log("  %s: no signal, daemon-age=%.0fmin, BUILT (open gate marker) — awaiting "
                 "gate, not a dispatch failure — no alarm" % (bead_id, starve_age_min))
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
        try:
            p, r, a = _process_store(rig_root, now, state, pilot_alive)
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
    """
    global _bd_approved, _bd_label_add, _bd_label_remove, _bd_comment
    global _do_notify, _do_mail_mayor, _read_pilot_log_lines, _bd_gate_markers
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

    _bd_label_add = _stub_label_add
    _bd_label_remove = _stub_label_remove
    _bd_comment = _stub_comment
    _do_mail_mayor = _stub_mail
    _do_notify = _stub_notify

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
    _bd_gate_markers = lambda root: [
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

    # ── result ────────────────────────────────────────────────────────────────
    print("\n[reconciler selftest] %d passed, %d failed" % (ok_count[0], fail_count[0]))
    if fail_count[0]:
        sys.exit(1)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        main()
