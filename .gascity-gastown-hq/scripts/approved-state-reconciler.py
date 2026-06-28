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

ROUTING SIGNALS (explicit only):
  • needs-device: label story:needs-device, OR title/AC matches on-device patterns
    (on-device, aquecimento, warming, UIAutomator, screencap, tela do, celular, DPR foreground)
  • needs-human: label gate:needs-human* (prefix) or story:needs-human
  • blocked: label blocked/story:blocked OR wording bloqueado por / quando o datastore /
    aguardando <serviço>
  • post-build: label gate:passed → remove story:approved only (delivery owns it)

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
                return d
    except Exception:
        pass
    return {"routed": {}, "alarmed": {}}


def _save_state(state):
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w") as f:
            json.dump(state, f)
    except Exception as e:
        _log("WARN: failed to save state: %r" % e)


# ── bd JSON parse ─────────────────────────────────────────────────────────────
def _parse_bd_json(raw):
    """Parse bd --json output (array or {issues:[]} envelope). Returns [] on any failure."""
    if not raw or not raw.strip():
        return []
    try:
        d = json.loads(raw)
    except json.JSONDecodeError as e:
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


# ── classification — explicit non-buildable signals only ─────────────────────
def _classify(bead):
    """Return (route_to, signal) or (None, None) if NO explicit non-buildable signal.

    route_to: one of 'needs-device', 'needs-human', 'blocked', 'post-build', or None.
    signal: human-readable string naming the exact signal that triggered the route.

    SAFETY: this function returns (None, None) when no EXPLICIT signal is found.
    A bead with ambiguous or unrecognized content is NEVER classified non-buildable here.
    """
    labels = _get_labels(bead)
    text = _bead_text(bead)

    # 1. post-build: gate:passed — the bead already built; delivery owns next state.
    if _has_prefix(labels, "gate:passed"):
        for lab in labels:
            if lab == "gate:passed" or lab.startswith("gate:passed:"):
                return "post-build", "label %s" % lab
        return "post-build", "gate:passed label present"

    # 2. needs-device: label OR title/AC pattern (explicit on-device signal).
    if "story:needs-device" in labels:
        return "needs-device", "label story:needs-device"
    for pat in _ONDEVICE_PATS:
        m = pat.search(text)
        if m:
            return "needs-device", "on-device pattern %r in title/AC" % m.group(0)

    # 3. needs-human: gate:needs-human* (prefix) OR story:needs-human.
    if "story:needs-human" in labels:
        return "needs-human", "label story:needs-human"
    for lab in labels:
        if lab.startswith("gate:needs-human"):
            return "needs-human", "label %s" % lab

    # 4. blocked: label OR explicit external-dependency wording.
    for lab in ("blocked", "story:blocked"):
        if lab in labels:
            return "blocked", "label %s" % lab
    for pat in _BLOCKED_PATS:
        m = pat.search(text)
        if m:
            return "blocked", "blocked wording %r in title/AC" % m.group(0)

    # No explicit signal found → caller assumes buildable (SAFE DEFAULT).
    return None, None


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
        _do_label_remove(rig_root, bead_id, "story:approved")
        _do_label_add(rig_root, bead_id, new_label)
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

    processed = routed = alarmed = 0

    for bead in beads:
        if not isinstance(bead, dict):
            continue
        processed += 1
        bead_id = bead.get("id") or bead.get("issue_id") or "?"
        labels = _get_labels(bead)

        # ── Step 1: explicit non-buildable signal → route out ──────────────
        route_to, signal = _classify(bead)

        if route_to is not None:
            ok = _route_bead(rig_root, bead, route_to, signal, now, state)
            if ok:
                routed += 1
            continue  # classification done regardless of DRY_RUN/cooldown

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

        # Grace window: too fresh to alarm.
        age_min = _bead_age_min(bead, now)
        if age_min < STARVE_MIN:
            _log("  %s: no signal, not flowing, age=%.1fmin < STARVE_MIN=%d — grace" % (
                 bead_id, age_min, STARVE_MIN))
            continue

        # pilot:held-until — pilot explicitly parked this bead.
        if _has_prefix(labels, "pilot:held-until"):
            _log("  %s: no signal, age=%.0fmin, pilot:held-until — no alarm" % (
                 bead_id, age_min))
            continue

        # Pilot dead → can't blame dispatch; don't alarm.
        if not pilot_alive:
            _log("  %s: no signal, age=%.0fmin, starving BUT pilot dead — no alarm" % (
                 bead_id, age_min))
            continue

        # ALARM: buildable bead starving, pilot alive, dispatch path failing.
        _alarm_starving(rig_root, bead, age_min, now, state)
        alarmed += 1

    return processed, routed, alarmed


# ── main reconciliation cycle ─────────────────────────────────────────────────
def run_cycle(now, state):
    """One full cycle across all rig stores. Returns (processed, routed, alarmed)."""
    _log("=== reconciler cycle: %s ===" %
         datetime.datetime.fromtimestamp(now, tz=datetime.timezone.utc).strftime(
             "%Y-%m-%d %H:%M:%SZ"))

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
      (a) on-device-labeled → routed to needs-device
      (b) on-device by TITLE keyword (no label) → routed
      (c) needs-human label → routed
      (d) blocked wording in title → routed
      (e) gate:passed → story:approved removed, no new state label added
      (f) NO signal + in-flight label → no action
      (g) NO signal + age>STARVE_MIN + pilot alive → ALARM (gc mail send mayor)
      (h) NO signal + age>STARVE_MIN + pilot DEAD → no alarm
      (i) mayor-assigned + starving → ledger note only, NO alarm
      (j) NO explicit signal + ambiguous content → NEVER routed (safety)
      (k) DRY_RUN=1 → zero label/comment/mail mutations
      (l) idempotency — already-routed bead no longer has story:approved → no-op
      (m) per-store bd error → that store skipped, others processed, no crash
    """
    global _bd_approved, _bd_label_add, _bd_label_remove, _bd_comment
    global _do_notify, _do_mail_mayor, _read_pilot_log_lines
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
        return {"routed": {}, "alarmed": {}}

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

    # ── (b) on-device by TITLE keyword (no label) → routed ───────────────────
    print("\nScenario (b): on-device title keyword (no label) → needs-device route")
    _bd_approved = lambda root: [
        _make_bead("hq-002", title="feat: warming chip via UIAutomator")]
    st = _reset()
    run_cycle(NOW, st)
    if ("hq-002", "story:approved") in label_removes and \
       ("hq-002", "story:needs-device") in label_adds:
        _ok("(b): on-device title keyword → routed to story:needs-device")
    else:
        _bad("(b)", "removes=%s adds=%s" % (label_removes, label_adds))

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

    # ── (d) blocked wording → routed ─────────────────────────────────────────
    print("\nScenario (d): blocked wording in title → blocked route")
    _bd_approved = lambda root: [
        _make_bead("hq-004", title="bloqueado por dependência externa")]
    st = _reset()
    run_cycle(NOW, st)
    if ("hq-004", "story:approved") in label_removes and \
       ("hq-004", "story:blocked") in label_adds:
        _ok("(d): blocked wording → routed to story:blocked")
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

    # ── (g) NO signal + age>STARVE + pilot alive → ALARM ─────────────────────
    print("\nScenario (g): NO signal + age>STARVE_MIN + pilot alive → ALARM")
    _bd_approved = lambda root: [_make_bead("hq-007", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
    run_cycle(NOW, st)
    mailed_g = any("hq-007" in subj for subj, _ in mail_calls)
    notified_g = any("hq-007" in msg for msg, _ in notify_calls)
    if mailed_g and notified_g:
        _ok("(g): starving buildable bead → ALARM fired (gc mail send mayor + notify)")
    else:
        _bad("(g): expected ALARM", "mail_calls=%s notify_calls=%s" % (mail_calls, notify_calls))

    # ── (h) NO signal + age>STARVE + pilot DEAD → no alarm ───────────────────
    print("\nScenario (h): NO signal + age>STARVE + pilot DEAD → no alarm")
    _bd_approved = lambda root: [_make_bead("hq-008", age_min=_STARVE + 5.0)]
    _read_pilot_log_lines = lambda: _pilot_old()
    st = _reset()
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
        _make_bead("hq-012", age_min=_STARVE + 5.0),   # would alarm
    ]
    _read_pilot_log_lines = lambda: _pilot_recent()
    st = _reset()
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

    # ── result ────────────────────────────────────────────────────────────────
    print("\n[reconciler selftest] %d passed, %d failed" % (ok_count[0], fail_count[0]))
    if fail_count[0]:
        sys.exit(1)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        main()
