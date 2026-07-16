#!/usr/bin/env python3
"""auto-rehome-janitor.py — move HQ beads tagged needs:rehome-<rig> into their target rig store.

WHY THIS EXISTS (2026-06-28): beads approved in HQ that belong to a non-HQ rig are tagged
needs:rehome-<rig> (e.g. needs:rehome-property) by the Pilot when it cannot dispatch them.
These beads sit in HQ forever because the rig's builder pool only dispatches from its own
store. Confirmed stuck: ga-3v288, ga-fhir7, ga-s97zl (all story:approved + needs:rehome-property
in HQ, never dispatched). This daemon detects them, creates an equivalent bead in the target
rig store, and closes the HQ original — preserving full refino lineage (story.* metadata).

SAFETY PROTOCOL (Bead Preservation):
  A re-home that drops refino lineage (story.criterios, story.o_que_e, story.resumo, etc.)
  causes the reconciler to re-pull the bead back into the refino funnel (observed failure mode).
  MUST preserve: title, description, acceptance_criteria, ALL story.* metadata, story:approved,
  lane:*, gate:* labels. DROP: needs:rehome-* (satisfied) + pilot:held-until:* (HQ-scheduler
  cruft that does not apply in the target rig).

ATOMICITY / NO DATA LOSS:
  1. Create bead in rig store (bd create).
  2. Verify new id exists in rig store (bd show) BEFORE touching HQ.
  3. Mark HQ bead with gc.rehomed_to=<new_id> metadata (idempotency + audit).
  4. Comment both beads with cross-link ids.
  5. Close HQ original (bd close).
  Any failure in steps 1-2 leaves HQ bead completely untouched.
  Failure in steps 3-5 leaves new bead open in rig + HQ bead alive (no data loss).

IDEMPOTENCY:
  • gc.rehomed_to metadata on HQ bead → skip (already re-homed).
  • State file check (secondary guard, survives process restarts).

REVERSE DIRECTION (ga-0ou0, 2026-07-16): blocked:wrong-store-needs-rehome-hq previously had
no consumer — a bead mis-routed HQ→rig, later flagged by a human/agent as actually HQ-owned,
sat stuck forever (2 confirmed: wa-hshxt, wa-tj0vn, 7+ days each, only recovered by the Mayor
re-homing them BY HAND). Each sweep ALSO scans every non-HQ rig for beads carrying this label
and re-homes them BACK to HQ, using the same atomic create-verify-mark-close order (source and
destination swapped). Shares the same MAX_PER_SWEEP budget as the forward direction.

MISSING-FILE GUARD SCOPE (ga-0ou0 addendum to ga-xzfl): "does this cited path exist in HQ" now
ALSO checks the git superproject root (CITY's parent) — HQ's own canonical shared assets (e.g.
docs/design/*.md) can live one level above CITY (.gascity-gastown-hq/), which is a subtree of
the same repo, not a separate checkout (confirmed: docs/design/mail-protocol.md — the wa-tj0vn
case — lives at the superproject root and was invisible to a CITY-only existence check). A
cited path is excluded from that superproject-root check if its leading segment names another
known non-HQ rig, so a rig's own file is never mistaken for an HQ file just because both share
the same git repo.

CADENCE: MAX_PER_SWEEP=1 by default — one re-home per 10-min launchd cycle for safe pace.

LAUNCHD: StartInterval=600, one-shot (no KeepAlive). See com.gascity.auto-rehome-janitor.plist.
KILL-SWITCH: REHOME_JANITOR_ENABLED=0 → safe no-op.
DRY_RUN: REHOME_JANITOR_DRY_RUN=1 → logs intended actions, mutates nothing.
LOGS: .gc/logs/auto-rehome-janitor.{out,err}
"""
import datetime
import json
import os
import re
import subprocess
import sys
import time

# ── paths ─────────────────────────────────────────────────────────────────────
CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
NOTIFY_BIN = os.environ.get("NOTIFY_BIN", "/Users/athos/.local/bin/notify")
GC_BIN = os.environ.get("GC_BIN", "gc")
BD_BIN = os.environ.get("BD_BIN", "bd")
STATE_FILE = os.environ.get(
    "REHOME_STATE_FILE",
    os.path.join(CITY, ".gc/auto-rehome-janitor-state.json"))

# ── knobs (all env-overridable) ───────────────────────────────────────────────
ENABLED = os.environ.get("REHOME_JANITOR_ENABLED", "1") == "1"
DRY_RUN = os.environ.get("REHOME_JANITOR_DRY_RUN", "0") == "1"
# MAX_PER_SWEEP: re-home at most N beads per cycle. Default 1 = conservative pace.
MAX_PER_SWEEP = int(os.environ.get("REHOME_MAX_PER_SWEEP", "1"))
BD_TIMEOUT = int(os.environ.get("REHOME_BD_TIMEOUT", "30"))
# SKIP_SUSPENDED: when True, skip rigs that are suspended (running=false).
# Default False: re-home even to suspended rigs (bead will wait there for rig restart).
SKIP_SUSPENDED = os.environ.get("REHOME_SKIP_SUSPENDED", "0") == "1"
# MISSING_FILE_GUARD (ga-xzfl): before re-homing a bead to rig R, if the bead cites
# concrete file paths and NONE exist in R's repo, R is the WRONG rig — keep the bead in
# HQ (do NOT create+close). This mirrors the Pilot dispatcher's PILOT_MISSING_FILE_GUARD
# and reads the SAME env var, so one kill-switch disables both sites. Default on.
# FAIL-OPEN: no cited paths / unknown-or-off-disk rig root / probe error → re-home as today.
MISSING_FILE_GUARD = os.environ.get("PILOT_MISSING_FILE_GUARD", "1") == "1"

# ── test seams (monkeypatched in --selftest) ───────────────────────────────────
_gc_rig_list_fn = None   # () -> list[dict]
_bd_list_fn = None       # (rig_root, label) -> list[dict]|None
_bd_show_fn = None       # (rig_root, bead_id) -> dict|None
_bd_create_fn = None     # (rig_path, bead) -> str|None  (returns new bead id)
_bd_update_fn = None     # (rig_root, bead_id, metadata_dict) -> bool
_bd_comment_fn = None    # (rig_root, bead_id, text) -> bool
_bd_close_fn = None      # (rig_root, bead_id, reason) -> bool
_bd_label_list_fn = None # (rig_root) -> list[str]|None  (all labels in store)
_do_notify_fn = None     # (msg, prio) -> None
_file_exists_fn = None   # (rig_root, rel_path) -> bool  (ga-xzfl missing-file guard seam)


# ── subprocess helper ─────────────────────────────────────────────────────────
def _sh(args, timeout=20):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def _log(msg):
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    print("[rehome] %s %s" % (ts, msg), flush=True)


# ── state persistence ─────────────────────────────────────────────────────────
def _load_state():
    try:
        with open(STATE_FILE) as f:
            d = json.load(f)
            if isinstance(d, dict):
                d.setdefault("rehomed", {})
                return d
    except Exception:
        pass
    return {"rehomed": {}}


def _save_state(state):
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w") as f:
            json.dump(state, f, indent=2)
    except Exception as e:
        _log("WARN: failed to save state: %r" % e)


# ── label helpers ─────────────────────────────────────────────────────────────
# Matches both forms: needs:rehome-<suffix>  and  needs:rehome:<suffix>
_REHOME_RE = re.compile(r'^needs:rehome[-:](.+)$')
_HELD_UNTIL_RE = re.compile(r'^pilot:held-until:')

# ga-0ou0: label a human/agent applies when a bead landed in the wrong (non-HQ)
# store and should come back to HQ. Previously had no consumer — see REVERSE
# DIRECTION in the module docstring.
WRONG_STORE_LABEL = "blocked:wrong-store-needs-rehome-hq"


def _parse_rehome_label(label):
    """Extract rig suffix from needs:rehome-<suffix> or needs:rehome:<suffix>. Returns suffix or None."""
    m = _REHOME_RE.match(label)
    return m.group(1) if m else None


def _filter_labels(labels):
    """Labels to carry to the destination bead: DROP whatever this re-home (in
    either direction) satisfies, plus HQ-scheduler cruft.

    DROP (satisfied / HQ-scheduler cruft):
      needs:rehome-*                      — satisfied by a forward (HQ→rig) re-home
      pilot:held-until:*                  — HQ pilot scheduling artifact; irrelevant elsewhere
      blocked:wrong-store-needs-rehome-hq — satisfied by a reverse (rig→HQ) re-home (ga-0ou0)

    PRESERVE (all others):
      story:approved     — required for rig Pilot to dispatch
      lane:small etc.    — dispatch routing
      gate:needs-human:* — routing signals
      Any other label    — carry over conservatively
    """
    kept = []
    for label in (labels or []):
        if _REHOME_RE.match(label):
            continue
        if _HELD_UNTIL_RE.match(label):
            continue
        if label == WRONG_STORE_LABEL:
            continue
        kept.append(label)
    return kept


# ── rig discovery ─────────────────────────────────────────────────────────────
def _get_rigs():
    """Return all rigs from gc rig list --json (includes HQ and non-HQ)."""
    if _gc_rig_list_fn is not None:
        return _gc_rig_list_fn()
    r = _sh([GC_BIN, "--city", CITY, "rig", "list", "--json"], timeout=15)
    if r is None or r.returncode != 0:
        _log("WARN: gc rig list failed (rc=%s)" % (r.returncode if r else "err"))
        return []
    try:
        d = json.loads(r.stdout)
        return d.get("rigs") or []
    except Exception as e:
        _log("WARN: gc rig list parse error: %r" % e)
        return []


def _resolve_rig(suffix, rigs):
    """Find the non-HQ rig whose name best matches label suffix.

    Match order (most → least specific):
    1. Exact match:  rig.name == suffix
    2. Prefix match: rig.name starts with suffix  (e.g. 'property' → 'property_scrapers')
    3. Suffix is a prefix of rig name using the _ split (e.g. 'property' matches 'property_scrapers')

    Returns a rig dict or None.
    """
    candidates = [r for r in rigs if not r.get("hq", False)]

    # 1. Exact match
    for rig in candidates:
        if rig["name"] == suffix:
            return rig

    # 2. rig name starts with suffix (property → property_scrapers)
    for rig in candidates:
        if rig["name"].startswith(suffix) and (
            len(rig["name"]) == len(suffix) or rig["name"][len(suffix)] in ("_", "-", ".")
        ):
            return rig

    # 3. More relaxed: suffix is a leading segment of the rig name
    for rig in candidates:
        if rig["name"].startswith(suffix):
            return rig

    return None


# ── bd I/O helpers ────────────────────────────────────────────────────────────
def _parse_bd_json(raw):
    if not raw or not raw.strip():
        return []
    try:
        d = json.loads(raw)
    except Exception:
        return []
    if isinstance(d, list):
        return d
    if isinstance(d, dict):
        return d.get("issues") or d.get("beads") or d.get("items") or []
    return []


def _bd_list_with_label(hq_path, label):
    """Query HQ for beads with the given label (any status). Returns list[dict] or None on error."""
    if _bd_list_fn is not None:
        return _bd_list_fn(hq_path, label)
    r = _sh([BD_BIN, "-C", hq_path, "list", "--json", "-l", label, "-n", "100"],
            timeout=BD_TIMEOUT)
    if r is None or r.returncode != 0:
        _log("WARN: bd list -l %r failed (rc=%s)" % (label, r.returncode if r else "err"))
        return None
    return _parse_bd_json(r.stdout)


def _bd_show(rig_root, bead_id):
    """Fetch a specific bead as dict. Returns dict or None."""
    if _bd_show_fn is not None:
        return _bd_show_fn(rig_root, bead_id)
    r = _sh([BD_BIN, "-C", rig_root, "show", "--json", bead_id], timeout=BD_TIMEOUT)
    if r is None or r.returncode != 0:
        return None
    beads = _parse_bd_json(r.stdout)
    return beads[0] if beads else None


def _bd_label_list_all(rig_root):
    """List all unique labels in rig_root store. Returns list[str] or None on error."""
    if _bd_label_list_fn is not None:
        return _bd_label_list_fn(rig_root)
    r = _sh([BD_BIN, "-C", rig_root, "label", "list-all"], timeout=BD_TIMEOUT)
    if r is None or r.returncode != 0:
        return None
    labels = []
    for line in r.stdout.splitlines():
        m = re.match(r'\s+([\S]+)', line)
        if m:
            labels.append(m.group(1))
    return labels


def _bd_create_in_rig(rig_path, hq_bead):
    """Create a re-homed bead in the rig store. Returns new bead id or None on failure.

    Preserved fields: title, description, acceptance_criteria, issue_type, priority,
    clean labels (minus needs:rehome-* and pilot:held-until:*), all story.* metadata,
    plus gc.rehomed_from = hq_bead_id provenance marker.

    NOT carried over: defer_until, assignee, status, pilot:held-until:* labels,
    needs:rehome-* labels, any HQ-specific scheduling metadata.
    """
    title = hq_bead.get("title") or ""
    description = hq_bead.get("description") or ""
    acceptance = hq_bead.get("acceptance_criteria") or ""
    issue_type = hq_bead.get("issue_type") or "feature"
    priority = str(hq_bead.get("priority") if hq_bead.get("priority") is not None else 2)
    raw_labels = hq_bead.get("labels") or []
    clean_labels = _filter_labels(raw_labels)
    hq_id = hq_bead.get("id") or ""

    # Build metadata: all story.* from HQ + provenance marker.
    existing_meta = hq_bead.get("metadata") or {}
    new_meta = {k: v for k, v in existing_meta.items() if k.startswith("story.")}
    new_meta["gc.rehomed_from"] = hq_id

    if DRY_RUN:
        _log("DRY_RUN: would create bead in %s:" % rig_path)
        _log("DRY_RUN:   title        = %r" % title[:80])
        _log("DRY_RUN:   issue_type   = %s  priority=%s" % (issue_type, priority))
        _log("DRY_RUN:   labels kept  = %s" % clean_labels)
        _log("DRY_RUN:   labels drop  = %s" % [l for l in raw_labels if l not in clean_labels])
        _log("DRY_RUN:   meta keys    = %s" % sorted(new_meta.keys()))
        _log("DRY_RUN:   acceptance   = %s..." % (acceptance[:60] if acceptance else "(none)"))
        return "DRY_RUN_ID"

    if _bd_create_fn is not None:
        return _bd_create_fn(rig_path, hq_bead)

    cmd = [
        BD_BIN, "-C", rig_path, "create",
        "--title", title,
        "--type", issue_type,
        "--priority", priority,
        "--silent",
        "--actor", "auto-rehome-janitor",
    ]
    if description:
        cmd += ["--description", description]
    if acceptance:
        cmd += ["--acceptance", acceptance]
    if clean_labels:
        cmd += ["--labels", ",".join(clean_labels)]
    if new_meta:
        cmd += ["--metadata", json.dumps(new_meta)]

    r = _sh(cmd, timeout=BD_TIMEOUT)
    if r is None or r.returncode != 0:
        stderr = (r.stderr or "")[:300] if r else ""
        _log("ERROR: bd create in %s failed (rc=%s): %s" % (
            rig_path, r.returncode if r else "err", stderr))
        return None

    new_id = r.stdout.strip()
    if not new_id:
        _log("ERROR: bd create returned empty id (stdout=%r stderr=%r)" % (
            r.stdout[:80], (r.stderr or "")[:80]))
        return None
    return new_id


def _bd_update_metadata(rig_root, bead_id, merged_metadata):
    """Set (merge) metadata on an existing bead. Returns bool."""
    if DRY_RUN:
        _log("DRY_RUN: would update metadata on %s: %s" % (bead_id, list(merged_metadata.keys())))
        return True
    if _bd_update_fn is not None:
        return _bd_update_fn(rig_root, bead_id, merged_metadata)
    r = _sh([BD_BIN, "-C", rig_root, "update", bead_id,
             "--metadata", json.dumps(merged_metadata),
             "--actor", "auto-rehome-janitor"],
            timeout=BD_TIMEOUT)
    return bool(r and r.returncode == 0)


def _bd_add_comment(rig_root, bead_id, text):
    """Add a comment to a bead. Returns bool."""
    if DRY_RUN:
        _log("DRY_RUN: would comment on %s: %s" % (bead_id, text[:80]))
        return True
    if _bd_comment_fn is not None:
        return _bd_comment_fn(rig_root, bead_id, text)
    r = _sh([BD_BIN, "-C", rig_root, "comment", bead_id, text,
             "--actor", "auto-rehome-janitor"],
            timeout=BD_TIMEOUT)
    return bool(r and r.returncode == 0)


def _bd_close_bead(rig_root, bead_id, reason):
    """Close a bead with the given reason. Returns bool."""
    if DRY_RUN:
        _log("DRY_RUN: would close %s (reason: %s)" % (bead_id, reason))
        return True
    if _bd_close_fn is not None:
        return _bd_close_fn(rig_root, bead_id, reason)
    r = _sh([BD_BIN, "-C", rig_root, "close", bead_id,
             "--reason", reason,
             "--actor", "auto-rehome-janitor"],
            timeout=BD_TIMEOUT)
    return bool(r and r.returncode == 0)


# ── ga-xzfl: missing-file guard (mirror of the Pilot dispatcher's bead_cited_paths /
#    _rig_has_any_path — a bead re-homed to a rig lacking its files NEVERSTARTS there) ─
_PATH_TOKEN_RE = re.compile(r'\.?[A-Za-z0-9_-]+(?:/[A-Za-z0-9_.-]+)+')
_PATH_EXT_RE = re.compile(
    r'\.(?:py|sh|js|ts|tsx|jsx|toml|md|json|ya?ml|sql|txt|cfg|ini|go|rb|html|css|plist|conf)$',
    re.IGNORECASE)
_URL_STRIP_RE = re.compile(r'https?://\S+')


def _paths_from_bead(bead):
    """Extract concrete file paths a bead names — slash-joined tokens ending in a known
    code/config extension — deduped, order-preserving. URLs are stripped first so a
    hostname (painel.urblink.com.br/…) is never mistaken for a repo path. Scans
    title + description + acceptance_criteria + every story.* metadata string."""
    parts = [bead.get("title") or "", bead.get("description") or "",
             bead.get("acceptance_criteria") or ""]
    meta = bead.get("metadata") or {}
    if isinstance(meta, dict):
        for k, v in meta.items():
            if isinstance(k, str) and k.startswith("story.") and isinstance(v, str):
                parts.append(v)
    hay = _URL_STRIP_RE.sub(" ", "  ".join(parts))
    out, seen = [], set()
    for tok in _PATH_TOKEN_RE.findall(hay):
        if _PATH_EXT_RE.search(tok) and tok not in seen:
            seen.add(tok)
            out.append(tok)
    return out


def _file_exists_in_rig(rig_path, rel):
    """True iff <rel> is a tracked file in the rig's git repo OR exists on disk under
    rig_path. Uses the _file_exists_fn seam when set (selftest).
    FINDING 4: NEVER conflate a probe FAILURE with 'file absent'. git ls-files
    --error-unmatch exits 0=tracked, 1=cleanly-not-tracked; a None result (timeout / spawn
    error) or ANY other returncode (124 timeout, 128 not-a-repo, …) is a PROBE FAILURE ⇒
    fail-OPEN (return True), so a probe hiccup under disk pressure never triggers a
    destructive false refuse."""
    if _file_exists_fn is not None:
        return _file_exists_fn(rig_path, rel)
    r = _sh(["git", "-C", rig_path, "ls-files", "--error-unmatch", "--", rel], timeout=5)
    if r is None:
        return True                       # probe failed (timeout / spawn error) → fail-open
    if r.returncode == 0:
        return True                       # tracked
    if r.returncode == 1:                 # cleanly not tracked → the disk is the tie-breaker
        try:
            return os.path.exists(os.path.join(rig_path, rel))
        except Exception:
            return True
    return True                           # any other rc (124/128/…) → probe failure → fail-open


def _rig_has_any_cited_file(bead, rig_path):
    """Return True when the bead cites NO concrete paths, when the rig root is
    unknown/off-disk (and no test seam is active), or when at least ONE cited path exists
    in rig_path. Return False ONLY when the bead cites paths AND none exist in a known
    rig root — a confident 'this rig is missing every file the bead names'. FAIL-OPEN."""
    paths = _paths_from_bead(bead)
    if not paths:
        return True
    if _file_exists_fn is None and (not rig_path or not os.path.isdir(rig_path)):
        return True  # unknown / off-disk rig root → cannot judge → fail-open
    for p in paths:
        if _file_exists_in_rig(rig_path, p):
            return True
    return False


def _hq_has_any_cited_file(bead, non_hq_rig_names):
    """ga-0ou0: like _rig_has_any_cited_file(bead, CITY), but ALSO checks the git
    superproject root (CITY's parent) — HQ's own canonical shared assets (e.g.
    docs/design/*.md) can live one level above CITY, in the same git repo, not a
    separate checkout (docs/design/mail-protocol.md, the wa-tj0vn case, is exactly
    this: invisible to a CITY-only existence check). A cited path whose leading
    segment names another known non-HQ rig is excluded from the superroot check,
    so a rig's own file is never mistaken for an HQ file just because both share
    the same git repo. FAIL-OPEN throughout (mirrors _rig_has_any_cited_file)."""
    if _rig_has_any_cited_file(bead, CITY):
        return True
    superroot = os.path.dirname(CITY.rstrip("/")) or CITY
    if _file_exists_fn is None and not os.path.isdir(superroot):
        return True  # unknown / off-disk superroot → cannot judge → fail-open
    non_hq_rig_names = non_hq_rig_names or set()
    for p in _paths_from_bead(bead):
        first_seg = p.split("/", 1)[0]
        if first_seg in non_hq_rig_names:
            continue
        if _file_exists_in_rig(superroot, p):
            return True
    return False


# ── re-home one bead ──────────────────────────────────────────────────────────
def _rehome_bead(hq_bead, rig, state, non_hq_rig_names=None):
    """Re-home a single HQ bead to its target rig store.

    Returns True if re-homed (or DRY_RUN intent logged), False on skip/failure.

    SAFETY ORDER:
      Step 1 — CREATE in rig store.
      Step 2 — VERIFY new id exists (abort if not).
      Step 3 — MARK HQ bead gc.rehomed_to (idempotency anchor).
      Step 4 — COMMENT both beads (cross-link).
      Step 5 — CLOSE HQ original.

    HQ bead is only closed AFTER steps 1+2 succeed (create + verify).
    Any error in steps 1-2 leaves HQ bead completely untouched.
    """
    hq_id = hq_bead.get("id") or ""
    rig_name = rig["name"]
    rig_path = rig["path"]
    title = (hq_bead.get("title") or "")[:80]

    _log("CANDIDATE %s → %s | %s" % (hq_id, rig_name, title))

    # ── Idempotency check ──────────────────────────────────────────────────────
    existing_meta = hq_bead.get("metadata") or {}
    if existing_meta.get("gc.rehomed_to"):
        _log("  SKIP %s: already has gc.rehomed_to=%s" % (hq_id, existing_meta["gc.rehomed_to"]))
        return False

    if hq_id in state.get("rehomed", {}):
        prior = state["rehomed"][hq_id]
        _log("  SKIP %s: state records as already re-homed → %s in %s (at %s)" % (
             hq_id, prior.get("new_id"), prior.get("rig"), prior.get("ts")))
        return False

    # ── ga-xzfl: missing-file guard ────────────────────────────────────────────
    # FINDING 2: only keep-in-HQ when the cited files are GENUINELY MISLOCATED — absent in
    # the target rig but PRESENT IN HQ (so this bead is really HQ work mis-tagged for rehome).
    # If HQ ALSO lacks them, it's a CREATE-FILE bead whose file doesn't exist anywhere yet;
    # the target rig is the CORRECT place to create it, so proceed (refusing would strand it
    # in HQ forever → NEVERSTART). Both probes are fail-open (see _file_exists_in_rig FINDING 4),
    # so a probe hiccup never manufactures a destructive false refuse.
    if (MISSING_FILE_GUARD
            and not _rig_has_any_cited_file(hq_bead, rig_path)
            and _hq_has_any_cited_file(hq_bead, non_hq_rig_names)):
        _log("  SKIP %s: cites file path(s) %s present in HQ but absent in target rig %s (%s) — "
             "MISLOCATED (not this rig's work); keeping HQ bead untouched (no create/close). "
             "Disable with PILOT_MISSING_FILE_GUARD=0." % (
                 hq_id, _paths_from_bead(hq_bead), rig_name, rig_path))
        return False

    # ── Step 1: Create in rig store ────────────────────────────────────────────
    _log("  Step 1: creating bead in %s ..." % rig_name)
    new_id = _bd_create_in_rig(rig_path, hq_bead)
    if not new_id:
        _log("  ABORT %s: create in rig %s failed — HQ bead untouched" % (hq_id, rig_name))
        return False

    if DRY_RUN:
        _log("  DRY_RUN: would verify → comment → mark → close; skipping mutations")
        return True  # counted as "would re-home"

    # ── Step 2: Verify new id exists ───────────────────────────────────────────
    _log("  Step 2: verifying %s in %s ..." % (new_id, rig_name))
    verified = _bd_show(rig_path, new_id)
    if not verified:
        _log("  ABORT %s: new bead %s NOT found in %s after create — "
             "HQ bead untouched (rig store may have dropped it; investigate)" % (
             hq_id, new_id, rig_name))
        return False
    _log("  VERIFIED: %s exists in %s (title=%r)" % (
         new_id, rig_name, (verified.get("title") or "")[:60]))

    # ── Step 3: Mark HQ bead as re-homed ──────────────────────────────────────
    _log("  Step 3: marking %s gc.rehomed_to=%s ..." % (hq_id, new_id))
    merged_meta = dict(existing_meta)
    merged_meta["gc.rehomed_to"] = new_id
    merged_meta["gc.rehomed_to_rig"] = rig_name
    mark_ok = _bd_update_metadata(CITY, hq_id, merged_meta)
    if not mark_ok:
        _log("  WARN: failed to set gc.rehomed_to on %s — "
             "continuing (new bead %s exists; HQ may need manual close)" % (hq_id, new_id))

    # ── Step 4: Comment both beads ─────────────────────────────────────────────
    _log("  Step 4: commenting both beads ...")
    hq_comment = (
        "auto-rehome-janitor: re-homed to %s in rig '%s'. "
        "Refino lineage (story.*) preserved. HQ original closing." % (new_id, rig_name)
    )
    rig_comment = (
        "auto-rehome-janitor: created from HQ original %s (re-home). "
        "Full refino lineage preserved. Ready for rig dispatch." % hq_id
    )
    _bd_add_comment(CITY, hq_id, hq_comment)
    _bd_add_comment(rig_path, new_id, rig_comment)

    # ── Step 5: Close HQ original ──────────────────────────────────────────────
    _log("  Step 5: closing HQ %s ..." % hq_id)
    close_reason = "re-homed to %s in rig '%s' by auto-rehome-janitor" % (new_id, rig_name)
    close_ok = _bd_close_bead(CITY, hq_id, close_reason)
    if not close_ok:
        _log("  WARN: close of HQ %s failed — new bead %s exists in %s. "
             "HQ bead is marked gc.rehomed_to; close manually: "
             "bd -C %s close %s" % (hq_id, new_id, rig_name, CITY, hq_id))
    else:
        _log("  Step 5: HQ %s closed OK" % hq_id)

    # ── Record in state + notify ───────────────────────────────────────────────
    state.setdefault("rehomed", {})[hq_id] = {
        "new_id": new_id,
        "rig": rig_name,
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "hq_closed": close_ok,
    }

    msg = "re-homed: %s → %s in %s | %s" % (hq_id, new_id, rig_name, title[:40])
    if _do_notify_fn is not None:
        _do_notify_fn(msg, 2)
    else:
        _sh([NOTIFY_BIN, "-t", "Auto-rehome", "-p", "2", msg], timeout=10)

    _log("  DONE: %s → %s in %s" % (hq_id, new_id, rig_name))
    return True


# ── re-home one bead BACK to HQ (ga-0ou0, reverse direction) ──────────────────
def _rehome_bead_reverse(rig, rig_bead, state):
    """Re-home a single rig bead BACK to HQ — the mirror image of _rehome_bead,
    for beads labeled blocked:wrong-store-needs-rehome-hq (a human/agent decided
    an earlier HQ→rig call, by this janitor or otherwise, was wrong). HQ is the
    fixed destination; `rig` is the (variable) source store. Same atomic
    create→verify→mark→close order and safety guarantees as the forward
    direction; no missing-file guard here — unlike needs:rehome-<rig> (an
    automatic Pilot heuristic that needs a safety net), this label is an
    explicit human/agent judgment call, trusted as-is.

    Returns True if re-homed (or DRY_RUN intent logged), False on skip/failure.
    """
    rig_id = rig_bead.get("id") or ""
    rig_name = rig["name"]
    rig_path = rig["path"]
    title = (rig_bead.get("title") or "")[:80]

    _log("REVERSE CANDIDATE %s (%s) → HQ | %s" % (rig_id, rig_name, title))

    # ── Idempotency check ──────────────────────────────────────────────────────
    existing_meta = rig_bead.get("metadata") or {}
    if existing_meta.get("gc.rehomed_to"):
        _log("  SKIP %s: already has gc.rehomed_to=%s" % (rig_id, existing_meta["gc.rehomed_to"]))
        return False

    state_key = "rev:%s" % rig_id
    if state_key in state.get("rehomed", {}):
        prior = state["rehomed"][state_key]
        _log("  SKIP %s: state records as already re-homed → %s (at %s)" % (
             rig_id, prior.get("new_id"), prior.get("ts")))
        return False

    # ── Step 1: Create in HQ ───────────────────────────────────────────────────
    _log("  Step 1: creating bead in HQ ...")
    new_id = _bd_create_in_rig(CITY, rig_bead)
    if not new_id:
        _log("  ABORT %s: create in HQ failed — %s bead untouched" % (rig_id, rig_name))
        return False

    if DRY_RUN:
        _log("  DRY_RUN: would verify → comment → mark → close; skipping mutations")
        return True  # counted as "would re-home"

    # ── Step 2: Verify new id exists ───────────────────────────────────────────
    _log("  Step 2: verifying %s in HQ ..." % new_id)
    verified = _bd_show(CITY, new_id)
    if not verified:
        _log("  ABORT %s: new bead %s NOT found in HQ after create — "
             "%s bead untouched (HQ store may have dropped it; investigate)" % (
             rig_id, new_id, rig_name))
        return False
    _log("  VERIFIED: %s exists in HQ (title=%r)" % (new_id, (verified.get("title") or "")[:60]))

    # ── Step 3: Mark rig bead as re-homed ──────────────────────────────────────
    _log("  Step 3: marking %s gc.rehomed_to=%s ..." % (rig_id, new_id))
    merged_meta = dict(existing_meta)
    merged_meta["gc.rehomed_to"] = new_id
    merged_meta["gc.rehomed_to_rig"] = "gascity"
    mark_ok = _bd_update_metadata(rig_path, rig_id, merged_meta)
    if not mark_ok:
        _log("  WARN: failed to set gc.rehomed_to on %s — "
             "continuing (new bead %s exists; HQ may need manual close)" % (rig_id, new_id))

    # ── Step 4: Comment both beads ─────────────────────────────────────────────
    _log("  Step 4: commenting both beads ...")
    rig_comment = (
        "auto-rehome-janitor: re-homed BACK to HQ as %s (honoring %s). "
        "%s original closing." % (new_id, WRONG_STORE_LABEL, rig_name)
    )
    hq_comment = (
        "auto-rehome-janitor: created from %s original %s (reverse re-home — wrong-store "
        "correction). Ready for HQ dispatch." % (rig_name, rig_id)
    )
    _bd_add_comment(rig_path, rig_id, rig_comment)
    _bd_add_comment(CITY, new_id, hq_comment)

    # ── Step 5: Close rig original ─────────────────────────────────────────────
    _log("  Step 5: closing %s %s ..." % (rig_name, rig_id))
    close_reason = "re-homed back to HQ as %s by auto-rehome-janitor (wrong-store correction)" % new_id
    close_ok = _bd_close_bead(rig_path, rig_id, close_reason)
    if not close_ok:
        _log("  WARN: close of %s %s failed — new bead %s exists in HQ. "
             "%s bead is marked gc.rehomed_to; close manually: "
             "bd -C %s close %s" % (rig_name, rig_id, new_id, rig_name, rig_path, rig_id))
    else:
        _log("  Step 5: %s %s closed OK" % (rig_name, rig_id))

    # ── Record in state + notify ───────────────────────────────────────────────
    state.setdefault("rehomed", {})[state_key] = {
        "new_id": new_id,
        "rig": "gascity",
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "hq_closed": close_ok,
    }

    msg = "re-homed BACK to HQ: %s (%s) → %s | %s" % (rig_id, rig_name, new_id, title[:40])
    if _do_notify_fn is not None:
        _do_notify_fn(msg, 2)
    else:
        _sh([NOTIFY_BIN, "-t", "Auto-rehome", "-p", "2", msg], timeout=10)

    _log("  DONE: %s (%s) → %s in HQ" % (rig_id, rig_name, new_id))
    return True


def _collect_reverse_candidates(non_hq_rigs):
    """Scan every non-HQ rig for beads labeled blocked:wrong-store-needs-rehome-hq
    (ga-0ou0 bug 2: this label previously had no consumer). Returns dict of
    rig_bead_id -> (bead, rig), deduplicated by id. Deliberately scans ALL
    non-HQ rigs regardless of SKIP_SUSPENDED — reading a rig's bd store and
    creating in HQ don't require the rig's own workers to be running."""
    candidates = {}
    for rig in non_hq_rigs:
        beads = _bd_list_with_label(rig["path"], WRONG_STORE_LABEL)
        if beads is None:
            _log("  WARN: bd list failed for %r in rig %r — skipping (fail-open)" % (
                 WRONG_STORE_LABEL, rig["name"]))
            continue
        if not beads:
            continue
        _log("  rig %r: %d bead(s) labeled %s" % (rig["name"], len(beads), WRONG_STORE_LABEL))
        for bead in beads:
            bid = bead.get("id") or ""
            if bid and bid not in candidates:
                candidates[bid] = (bead, rig)
    return candidates


# ── discover all rehome labels present in HQ ──────────────────────────────────
def _discover_rehome_labels(non_hq_rigs):
    """Build the set of needs:rehome-* labels to query for.

    Strategy:
    1. Generate canonical forms from known rig names.
    2. Scan HQ label list-all to catch any forms actually in use.
    """
    rehome_labels = set()

    for rig in non_hq_rigs:
        name = rig["name"]
        rehome_labels.add("needs:rehome-" + name)
        rehome_labels.add("needs:rehome:" + name)
        # Short prefix (e.g. 'property' for 'property_scrapers')
        prefix = name.split("_")[0]
        if prefix != name:
            rehome_labels.add("needs:rehome-" + prefix)
            rehome_labels.add("needs:rehome:" + prefix)

    # Also scan actual labels in HQ to catch unexpected variants
    all_labels = _bd_label_list_all(CITY)
    if all_labels:
        for lbl in all_labels:
            if _REHOME_RE.match(lbl.strip()):
                rehome_labels.add(lbl.strip())

    return rehome_labels


# ── main sweep ────────────────────────────────────────────────────────────────
def run_sweep(now, state):
    """Scan HQ for needs:rehome-* beads (forward) and every non-HQ rig for
    blocked:wrong-store-needs-rehome-hq beads (reverse, ga-0ou0), re-homing up
    to MAX_PER_SWEEP total per cycle across both directions combined.

    Returns count of beads actually re-homed.
    """
    _log("=== sweep: %s (DRY_RUN=%s MAX_PER_SWEEP=%d) ===" % (
         datetime.datetime.fromtimestamp(now, tz=datetime.timezone.utc).strftime(
             "%Y-%m-%d %H:%M:%SZ"),
         DRY_RUN, MAX_PER_SWEEP))

    all_rigs = _get_rigs()
    if not all_rigs:
        _log("WARN: no rigs found — nothing to do")
        return 0

    non_hq_rigs_all = [r for r in all_rigs if not r.get("hq", False)]
    _log("rigs: %s" % [r["name"] for r in non_hq_rigs_all])

    non_hq_rigs = non_hq_rigs_all
    if SKIP_SUSPENDED:
        non_hq_rigs = [r for r in non_hq_rigs if not r.get("suspended", False)]
        _log("after SKIP_SUSPENDED filter: %s" % [r["name"] for r in non_hq_rigs])

    non_hq_rig_names = {r["name"] for r in non_hq_rigs_all}
    rehomed = 0

    # ── Phase 1: reverse (rig → HQ) — honor blocked:wrong-store-needs-rehome-hq (ga-0ou0) ──
    reverse_candidates = _collect_reverse_candidates(non_hq_rigs_all)
    if reverse_candidates:
        _log("%d reverse candidate(s) (%s): %s" % (
             len(reverse_candidates), WRONG_STORE_LABEL, list(reverse_candidates.keys())))
        reverse_items = list(reverse_candidates.items())
        for i, (rig_id, (bead, rig)) in enumerate(reverse_items):
            if rehomed >= MAX_PER_SWEEP:
                remaining = [cid for cid, _ in reverse_items[i:]]
                _log("MAX_PER_SWEEP=%d reached — %d reverse bead(s) deferred to next sweep: %s" % (
                     MAX_PER_SWEEP, len(remaining), remaining))
                break
            try:
                ok = _rehome_bead_reverse(rig, bead, state)
                if ok:
                    rehomed += 1
            except Exception as e:
                _log("ERROR: unexpected error reverse-rehoming %s: %r — bead left untouched" % (
                     rig_id, e))

    # ── Phase 2: forward (HQ → rig) — needs:rehome-<rig> ─────────────────────────────────
    if not non_hq_rigs:
        _log("no eligible non-HQ rigs for forward re-home this sweep")
        _log("sweep done: %d re-homed (MAX_PER_SWEEP=%d)" % (rehomed, MAX_PER_SWEEP))
        return rehomed

    rehome_labels = _discover_rehome_labels(non_hq_rigs)
    _log("rehome labels to scan: %s" % sorted(rehome_labels))

    # Collect candidates: dict of hq_id -> (bead, target_rig), deduplicated by id
    candidates = {}

    for label in sorted(rehome_labels):
        suffix = _parse_rehome_label(label)
        if not suffix:
            continue

        target_rig = _resolve_rig(suffix, non_hq_rigs)
        if not target_rig:
            _log("  WARN: label %r — no rig matches suffix %r — skipping" % (label, suffix))
            continue

        beads = _bd_list_with_label(CITY, label)
        if beads is None:
            _log("  WARN: bd list failed for label %r — skipping (fail-open)" % label)
            continue
        if not beads:
            _log("  label %r: 0 beads" % label)
            continue

        _log("  label %r → rig %r: %d bead(s)" % (label, target_rig["name"], len(beads)))
        for bead in beads:
            bid = bead.get("id") or ""
            if bid and bid not in candidates:
                candidates[bid] = (bead, target_rig)

    if not candidates:
        _log("no beads need forward re-homing this sweep")
        _log("sweep done: %d re-homed (MAX_PER_SWEEP=%d)" % (rehomed, MAX_PER_SWEEP))
        return rehomed

    _log("%d forward candidate(s): %s" % (len(candidates), list(candidates.keys())))

    forward_items = list(candidates.items())
    for i, (hq_id, (bead, rig)) in enumerate(forward_items):
        if rehomed >= MAX_PER_SWEEP:
            remaining = [cid for cid, _ in forward_items[i:]]
            _log("MAX_PER_SWEEP=%d reached — %d bead(s) deferred to next sweep: %s" % (
                 MAX_PER_SWEEP, len(remaining), remaining))
            break
        try:
            ok = _rehome_bead(bead, rig, state, non_hq_rig_names=non_hq_rig_names)
            if ok:
                rehomed += 1
        except Exception as e:
            _log("ERROR: unexpected error re-homing %s: %r — bead left untouched" % (hq_id, e))

    _log("sweep done: %d re-homed (MAX_PER_SWEEP=%d)" % (rehomed, MAX_PER_SWEEP))
    return rehomed


# ── main entry point ──────────────────────────────────────────────────────────
def main():
    if not ENABLED:
        _log("disabled via REHOME_JANITOR_ENABLED=0 — no-op")
        return

    _log("auto-rehome-janitor starting")
    state = _load_state()
    try:
        run_sweep(time.time(), state)
        _save_state(state)
    except Exception as e:
        _log("sweep error: %r" % e)
        raise


# ── selftest ──────────────────────────────────────────────────────────────────
def _selftest():
    """Hermetic selftest — stubs all I/O. sys.exit(1) on any failure.

    Scenarios:
      (a) needs:rehome-property → resolves to property_scrapers, creates + marks + closes HQ
      (b) already gc.rehomed_to in metadata → skipped (idempotent)
      (c) already in state file → skipped (idempotent)
      (d) create fails → HQ bead untouched, no comment/close
      (e) verify fails after create → HQ bead untouched, no close
      (f) needs:rehome:rig (colon form) → resolves correctly
      (g) DRY_RUN → zero mutations, returns True (intent logged)
      (h) MAX_PER_SWEEP=1, 3 candidates → only 1 re-homed
      (i) unknown label suffix → SKIP (no rig match), no crash
      (j) needs:rehome-property_scrapers (full name) → resolves to property_scrapers
      (k) missing-file guard: cited file present in HQ, absent in target rig → refuse (mislocated)
      (k2) control: cited path present in target rig → re-home proceeds (no over-fire)
      (k3) PILOT_MISSING_FILE_GUARD=0 → re-home despite mislocation (kill-switch)
      (k4) FINDING 2: create-file bead (cited file in NO rig incl HQ) → re-home, NOT refuse
      (k5) FINDING 4: git-probe timeout/None → fail-open present (never conflate with absent)
      (l) ga-0ou0 reverse: blocked:wrong-store-needs-rehome-hq → creates in HQ, marks +
          closes rig bead
      (m) ga-0ou0 reverse: already gc.rehomed_to → skip (idempotent)
      (n) ga-0ou0 reverse: already in state file (rev: key) → skip (idempotent)
      (o) ga-0ou0 reverse + forward candidates in the same sweep → MAX_PER_SWEEP shared
          budget respected
      (p) ga-0ou0 missing-file guard gap: cited path absent in rig+CITY but present at the
          git superproject root → refuse (was NOT caught before this fix)
      (q) ga-0ou0 control: cited path prefixed with a sibling rig's name at the superroot →
          excluded from the HQ match, no false refuse
    """
    global _gc_rig_list_fn, _bd_list_fn, _bd_show_fn, _bd_create_fn
    global _bd_update_fn, _bd_comment_fn, _bd_close_fn, _bd_label_list_fn
    global _do_notify_fn, DRY_RUN, MAX_PER_SWEEP, CITY

    ok_count = [0]
    fail_count = [0]

    def _ok(label):
        ok_count[0] += 1
        print("  ok  %s" % label)

    def _bad(label, detail=""):
        fail_count[0] += 1
        print("  FAIL %s%s" % (label, ": " + detail if detail else ""))

    # ── fixture rigs ─────────────────────────────────────────────────────────
    RIGS = [
        {"name": "gascity", "path": "/hq", "hq": True, "suspended": False},
        {"name": "property_scrapers", "path": "/ps", "hq": False, "suspended": False},
        {"name": "marketing", "path": "/mkt", "hq": False, "suspended": True},
    ]
    globals()["CITY"] = "/hq"
    _gc_rig_list_fn = lambda: RIGS
    _bd_label_list_fn = lambda root: ["needs:rehome-property", "story:approved"]
    _do_notify_fn = lambda msg, p: None

    def _make_hq_bead(bid, labels=None, meta=None):
        return {
            "id": bid,
            "title": "Test Story: %s" % bid,
            "description": "desc",
            "acceptance_criteria": "ac",
            "issue_type": "feature",
            "priority": 3,
            "labels": labels if labels is not None else ["needs:rehome-property", "story:approved"],
            "metadata": meta if meta is not None else {
                "story.resumo": "resumo de %s" % bid,
                "story.criterios": "criterios",
                "story.o_que_e": "o_que_e",
            },
        }

    created = []
    updated = []
    comments = []
    closed = []

    def _reset():
        created.clear(); updated.clear(); comments.clear(); closed.clear()

    def _make_stubs(create_returns="ps-new001", verify_returns=True):
        def _create(path, bead):
            created.append((path, bead.get("id")))
            return create_returns
        def _show(path, bid):
            if not verify_returns:
                return None
            return {"id": bid, "title": "ok"}
        def _update(path, bid, meta):
            updated.append((bid, meta))
            return True
        def _comment(path, bid, text):
            comments.append((bid, text))
            return True
        def _close(path, bid, reason):
            closed.append((bid, reason))
            return True
        globals()["_bd_create_fn"] = _create
        globals()["_bd_show_fn"] = _show
        globals()["_bd_update_fn"] = _update
        globals()["_bd_comment_fn"] = _comment
        globals()["_bd_close_fn"] = _close

    globals()["DRY_RUN"] = False
    globals()["MAX_PER_SWEEP"] = 99

    print("\n[rehome selftest] running...\n")

    # ── (a) basic re-home: needs:rehome-property → property_scrapers ──────────
    print("Scenario (a): needs:rehome-property → creates + marks + closes HQ")
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ga-abc")] if label == "needs:rehome-property" else [])
    _make_stubs()
    st = _load_state.__wrapped__() if hasattr(_load_state, "__wrapped__") else {"rehomed": {}}
    _reset()
    run_sweep(0, st)
    created_in_ps = any(p == "/ps" for p, _ in created)
    hq_id_in_meta = any("gc.rehomed_to" in meta for _, meta in updated)
    hq_closed = any(bid == "ga-abc" for bid, _ in closed)
    if created_in_ps and hq_id_in_meta and hq_closed:
        _ok("(a): created in ps, marked gc.rehomed_to, closed HQ")
    else:
        _bad("(a)", "created=%s meta=%s closed=%s" % (created, updated, closed))

    # ── (b) already gc.rehomed_to → skip ─────────────────────────────────────
    print("\nScenario (b): gc.rehomed_to set → skip (idempotent)")
    _bd_list_fn = lambda path, label: ([
        _make_hq_bead("ga-already", meta={"gc.rehomed_to": "ps-exists", "story.resumo": "r"})
    ] if label == "needs:rehome-property" else [])
    _make_stubs()
    st = {"rehomed": {}}
    _reset()
    run_sweep(0, st)
    if not created and not closed:
        _ok("(b): gc.rehomed_to → skipped (no create, no close)")
    else:
        _bad("(b)", "created=%s closed=%s" % (created, closed))

    # ── (c) in state file → skip ──────────────────────────────────────────────
    print("\nScenario (c): bead in state file → skip")
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ga-instate")] if label == "needs:rehome-property" else [])
    _make_stubs()
    st = {"rehomed": {"ga-instate": {"new_id": "ps-xxx", "rig": "property_scrapers", "ts": "t"}}}
    _reset()
    run_sweep(0, st)
    if not created and not closed:
        _ok("(c): state file entry → skipped")
    else:
        _bad("(c)", "created=%s closed=%s" % (created, closed))

    # ── (d) create fails → HQ untouched ──────────────────────────────────────
    print("\nScenario (d): create fails → HQ bead untouched")
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ga-failcreate")] if label == "needs:rehome-property" else [])
    _make_stubs(create_returns=None)  # create_returns=None → bd create failure
    st = {"rehomed": {}}
    _reset()
    run_sweep(0, st)
    if not updated and not closed:
        _ok("(d): create failed → HQ bead untouched (no update, no close)")
    else:
        _bad("(d)", "updated=%s closed=%s" % (updated, closed))

    # ── (e) verify fails after create → HQ untouched ─────────────────────────
    print("\nScenario (e): create succeeds but verify fails → HQ untouched")
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ga-failverify")] if label == "needs:rehome-property" else [])
    _make_stubs(create_returns="ps-ghost", verify_returns=False)
    st = {"rehomed": {}}
    _reset()
    run_sweep(0, st)
    if not closed and not updated:
        _ok("(e): verify failed → HQ not closed, not marked (no data loss)")
    else:
        _bad("(e)", "closed=%s updated=%s" % (closed, updated))

    # ── (f) colon form needs:rehome:property → resolves ──────────────────────
    print("\nScenario (f): needs:rehome:property (colon form) → resolves to property_scrapers")
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ga-colon", labels=["needs:rehome:property", "story:approved"])]
        if label == "needs:rehome:property" else [])
    _bd_label_list_fn = lambda root: ["needs:rehome:property"]
    _make_stubs()
    st = {"rehomed": {}}
    _reset()
    run_sweep(0, st)
    if any(p == "/ps" for p, _ in created):
        _ok("(f): colon form resolves to property_scrapers and creates there")
    else:
        _bad("(f)", "created=%s" % created)
    _bd_label_list_fn = lambda root: ["needs:rehome-property", "story:approved"]  # restore

    # ── (g) DRY_RUN → zero mutations ─────────────────────────────────────────
    print("\nScenario (g): DRY_RUN → zero mutations")
    globals()["DRY_RUN"] = True
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ga-dryrun")] if label == "needs:rehome-property" else [])
    _make_stubs()
    st = {"rehomed": {}}
    _reset()
    result = run_sweep(0, st)
    if not created and not updated and not closed and not comments:
        _ok("(g): DRY_RUN → zero mutations (only logs)")
    else:
        _bad("(g)", "created=%s updated=%s closed=%s" % (created, updated, closed))
    # DRY_RUN returns 1 (intent logged counts as would-rehome)
    if result == 1:
        _ok("(g2): DRY_RUN returns 1 (intent counted)")
    else:
        _bad("(g2): DRY_RUN returned %s, expected 1" % result)
    globals()["DRY_RUN"] = False

    # ── (h) MAX_PER_SWEEP=1 → only 1 re-homed ───────────────────────────────
    print("\nScenario (h): MAX_PER_SWEEP=1, 3 candidates → only 1 re-homed")
    globals()["MAX_PER_SWEEP"] = 1
    beads_h = [_make_hq_bead("ga-h1"), _make_hq_bead("ga-h2"), _make_hq_bead("ga-h3")]
    _bd_list_fn = lambda path, label: beads_h if label == "needs:rehome-property" else []
    _make_stubs()
    st = {"rehomed": {}}
    _reset()
    count = run_sweep(0, st)
    if count == 1 and len(created) == 1 and len(closed) == 1:
        _ok("(h): MAX_PER_SWEEP=1 → only 1 bead re-homed per sweep")
    else:
        _bad("(h)", "count=%s created=%d closed=%d" % (count, len(created), len(closed)))
    globals()["MAX_PER_SWEEP"] = 99

    # ── (i) unknown suffix → no crash ────────────────────────────────────────
    print("\nScenario (i): needs:rehome-unknownrig → no rig match, no crash")
    _bd_label_list_fn = lambda root: ["needs:rehome-unknownrig"]
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ga-unknown", labels=["needs:rehome-unknownrig", "story:approved"])]
        if label == "needs:rehome-unknownrig" else [])
    _make_stubs()
    st = {"rehomed": {}}
    _reset()
    try:
        run_sweep(0, st)
        if not created and not closed:
            _ok("(i): unknown rig suffix → no crash, no action")
        else:
            _bad("(i): should not have created/closed", "created=%s" % created)
    except Exception as e:
        _bad("(i): raised exception: %r" % e)
    _bd_label_list_fn = lambda root: ["needs:rehome-property"]

    # ── (j) full name needs:rehome-property_scrapers → resolves ──────────────
    print("\nScenario (j): needs:rehome-property_scrapers (full rig name) → resolves")
    _bd_label_list_fn = lambda root: ["needs:rehome-property_scrapers"]
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ga-full", labels=["needs:rehome-property_scrapers", "story:approved"])]
        if label == "needs:rehome-property_scrapers" else [])
    _make_stubs()
    st = {"rehomed": {}}
    _reset()
    run_sweep(0, st)
    if any(p == "/ps" for p, _ in created):
        _ok("(j): full rig name resolves to property_scrapers")
    else:
        _bad("(j)", "created=%s" % created)

    # ── (k) ga-xzfl missing-file guard: file MISLOCATED (present in HQ, absent in R) → refuse ─
    # FINDING 2: only refuse when the cited file is GENUINELY MISLOCATED — present in HQ but
    # absent in the target rig (this bead is really HQ work mis-tagged for rehome). Stub: file
    # present in HQ (root==CITY), absent in property_scrapers (root=="/ps").
    print("\nScenario (k): cited file present in HQ, absent in target rig → refuse (no create/close/mark)")
    globals()["_file_exists_fn"] = lambda root, rel: (root == CITY)  # in HQ only, not in PS
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ga-missing", meta={"story.o_que_e": "fix scripts/only_in_hq.py routing", "story.resumo": "r"})]
        if label == "needs:rehome-property" else [])
    _make_stubs()
    st = {"rehomed": {}}
    _reset()
    run_sweep(0, st)
    if not created and not closed and not updated:
        _ok("(k): file present in HQ, absent in rig → mislocated → HQ bead untouched (no create/close/mark)")
    else:
        _bad("(k)", "created=%s closed=%s updated=%s" % (created, closed, updated))

    # ── (k2) control: cited path PRESENT in target rig → re-home proceeds ────────
    print("\nScenario (k2): cited path present in target rig → re-home proceeds (no false refuse)")
    globals()["_file_exists_fn"] = lambda root, rel: True  # cited path "present" in rig
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ga-present", meta={"story.o_que_e": "fix scrapers/rehome_thing.py", "story.resumo": "r"})]
        if label == "needs:rehome-property" else [])
    _make_stubs()
    st = {"rehomed": {}}
    _reset()
    run_sweep(0, st)
    if any(p == "/ps" for p, _ in created) and any(bid == "ga-present" for bid, _ in closed):
        _ok("(k2): cited path present → re-homed normally (guard did not over-fire)")
    else:
        _bad("(k2)", "created=%s closed=%s" % (created, closed))

    # ── (k3) knob: PILOT_MISSING_FILE_GUARD=0 → re-home despite mislocation ─────
    print("\nScenario (k3): MISSING_FILE_GUARD off → re-home despite mislocation (kill-switch works)")
    globals()["_file_exists_fn"] = lambda root, rel: (root == CITY)  # mislocated (guard ON would refuse)
    globals()["MISSING_FILE_GUARD"] = False
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ga-offguard", meta={"story.o_que_e": "fix scripts/only_in_hq.py", "story.resumo": "r"})]
        if label == "needs:rehome-property" else [])
    _make_stubs()
    st = {"rehomed": {}}
    _reset()
    run_sweep(0, st)
    if any(p == "/ps" for p, _ in created):
        _ok("(k3): guard OFF → re-home proceeds despite mislocation (knob is a real kill-switch)")
    else:
        _bad("(k3)", "created=%s" % created)
    globals()["MISSING_FILE_GUARD"] = True   # restore
    globals()["_file_exists_fn"] = None      # restore

    # ── (k4) FINDING 2: CREATE-FILE bead — cited file in NO rig (incl HQ) → re-home, NOT refuse ─
    # The file doesn't exist anywhere yet; the target rig is the correct place to create it.
    # Refusing would strand it in HQ forever (HQ can't build a PS scraper) → NEVERSTART.
    print("\nScenario (k4): create-file bead (cited file in NO rig, incl HQ) → re-home proceeds")
    globals()["_file_exists_fn"] = lambda root, rel: False  # absent EVERYWHERE (create-file)
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ga-newfile", meta={"story.o_que_e": "create scrapers/foo_novo.py — brand new file", "story.resumo": "r"})]
        if label == "needs:rehome-property" else [])
    _make_stubs()
    st = {"rehomed": {}}
    _reset()
    run_sweep(0, st)
    if any(p == "/ps" for p, _ in created) and any(bid == "ga-newfile" for bid, _ in closed):
        _ok("(k4): create-file bead re-homed to PS (correct rig to create it), NOT stranded in HQ")
    else:
        _bad("(k4)", "created=%s closed=%s (create-file bead was wrongly refused → NEVERSTART)" % (created, closed))

    # ── (k5) FINDING 4: git-probe FAILURE must fail-open (present), never conflate with absent ──
    print("\nScenario (k5): _file_exists_in_rig — git-probe timeout/None → fail-open present (not absent)")
    globals()["_file_exists_fn"] = None
    _sh_orig = globals()["_sh"]
    class _RC124:
        returncode = 124
        stdout = ""
        stderr = ""
    globals()["_sh"] = lambda args, timeout=20: _RC124()       # git ls-files "times out" (rc=124)
    r124 = _file_exists_in_rig(os.getcwd(), "does/not/exist_xyz.py")
    globals()["_sh"] = lambda args, timeout=20: None            # subprocess raised (timeout) → None
    rnone = _file_exists_in_rig(os.getcwd(), "does/not/exist_xyz.py")
    globals()["_sh"] = _sh_orig                                 # restore
    if r124 is True and rnone is True:
        _ok("(k5): git-probe rc=124 AND _sh None → fail-open present (probe failure ≠ file absent)")
    else:
        _bad("(k5)", "rc124=%s none=%s (probe failure conflated with absent → destructive false refuse)" % (r124, rnone))

    # ── (l) ga-0ou0 reverse: wrong-store label → creates in HQ, marks+closes rig bead ────
    print("\nScenario (l): reverse re-home — rig bead labeled wrong-store → creates in HQ, marks+closes rig")
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ps-wrong1", labels=[WRONG_STORE_LABEL, "story:done"])]
        if (path == "/ps" and label == WRONG_STORE_LABEL) else [])
    _make_stubs(create_returns="ga-new001")
    st = {"rehomed": {}}
    _reset()
    run_sweep(0, st)
    created_in_hq = any(p == "/hq" for p, _ in created)
    rig_marked = any(bid == "ps-wrong1" and "gc.rehomed_to" in meta for bid, meta in updated)
    rig_closed = any(bid == "ps-wrong1" for bid, _ in closed)
    if created_in_hq and rig_marked and rig_closed:
        _ok("(l): reverse re-home created in HQ, marked rig bead, closed rig bead")
    else:
        _bad("(l)", "created=%s updated=%s closed=%s" % (created, updated, closed))

    # ── (m) ga-0ou0 reverse: gc.rehomed_to already set → skip (idempotent) ───────────────
    print("\nScenario (m): reverse — gc.rehomed_to set on rig bead → skip (idempotent)")
    _bd_list_fn = lambda path, label: ([
        _make_hq_bead("ps-already", labels=[WRONG_STORE_LABEL],
                       meta={"gc.rehomed_to": "ga-exists", "story.resumo": "r"})
    ] if (path == "/ps" and label == WRONG_STORE_LABEL) else [])
    _make_stubs()
    st = {"rehomed": {}}
    _reset()
    run_sweep(0, st)
    if not created and not closed:
        _ok("(m): reverse gc.rehomed_to → skipped (no create, no close)")
    else:
        _bad("(m)", "created=%s closed=%s" % (created, closed))

    # ── (n) ga-0ou0 reverse: already in state file (rev: key) → skip ────────────────────
    print("\nScenario (n): reverse — bead in state file (rev: key) → skip")
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ps-instate", labels=[WRONG_STORE_LABEL])]
        if (path == "/ps" and label == WRONG_STORE_LABEL) else [])
    _make_stubs()
    st = {"rehomed": {"rev:ps-instate": {"new_id": "ga-xxx", "rig": "gascity", "ts": "t"}}}
    _reset()
    run_sweep(0, st)
    if not created and not closed:
        _ok("(n): reverse state file entry → skipped")
    else:
        _bad("(n)", "created=%s closed=%s" % (created, closed))

    # ── (o) ga-0ou0 reverse + forward same sweep → shared MAX_PER_SWEEP budget ──────────
    print("\nScenario (o): reverse + forward candidates same sweep → shared MAX_PER_SWEEP budget (reverse runs first)")
    globals()["MAX_PER_SWEEP"] = 1
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ps-rev-o", labels=[WRONG_STORE_LABEL])] if (path == "/ps" and label == WRONG_STORE_LABEL) else
        [_make_hq_bead("ga-fwd-o")] if (path == "/hq" and label == "needs:rehome-property") else [])
    _make_stubs()
    st = {"rehomed": {}}
    _reset()
    count = run_sweep(0, st)
    reverse_done = any(bid == "ps-rev-o" for bid, _ in closed)
    forward_done = any(bid == "ga-fwd-o" for bid, _ in closed)
    if count == 1 and reverse_done and not forward_done:
        _ok("(o): shared MAX_PER_SWEEP budget → reverse candidate processed, forward deferred")
    else:
        _bad("(o)", "count=%s closed=%s" % (count, closed))
    globals()["MAX_PER_SWEEP"] = 99

    # ── (p) ga-0ou0 gap: cited path absent in rig+CITY, present at git superroot → refuse ─
    print("\nScenario (p): ga-0ou0 gap — cited path absent in rig+CITY, present at git superroot → refuse")
    globals()["_file_exists_fn"] = lambda root, rel: (root == "/")  # only "present" at superroot (parent of CITY="/hq")
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ga-superroot",
                        meta={"story.o_que_e": "add docs/design/mail-protocol.md section", "story.resumo": "r"})]
        if (path == "/hq" and label == "needs:rehome-property") else [])
    _make_stubs()
    st = {"rehomed": {}}
    _reset()
    run_sweep(0, st)
    if not created and not closed and not updated:
        _ok("(p): cited path present only at gt-superroot (outside CITY) → HQ bead untouched (ga-0ou0 fix)")
    else:
        _bad("(p)", "created=%s closed=%s updated=%s" % (created, closed, updated))
    globals()["_file_exists_fn"] = None

    # ── (q) ga-0ou0 control: sibling-rig-prefixed path excluded from superroot match ─────
    print("\nScenario (q): ga-0ou0 control — cited path prefixed with sibling rig name at superroot → excluded, no false refuse")
    globals()["_file_exists_fn"] = lambda root, rel: (root == "/")  # "present" at superroot for ANY rel (stub)
    _bd_list_fn = lambda path, label: (
        [_make_hq_bead("ga-siblingpath", meta={"story.o_que_e": "fix marketing/lib/thing.py", "story.resumo": "r"})]
        if (path == "/hq" and label == "needs:rehome-property") else [])
    _make_stubs()
    st = {"rehomed": {}}
    _reset()
    run_sweep(0, st)
    if any(p == "/ps" for p, _ in created) and any(bid == "ga-siblingpath" for bid, _ in closed):
        _ok("(q): sibling-rig-prefixed path excluded from HQ superroot match → re-home proceeds normally")
    else:
        _bad("(q)", "created=%s closed=%s" % (created, closed))
    globals()["_file_exists_fn"] = None

    # ── result ────────────────────────────────────────────────────────────────
    print("\n[rehome selftest] %d passed, %d failed" % (ok_count[0], fail_count[0]))
    if fail_count[0]:
        sys.exit(1)


# Add a simple wrapper for _load_state to work in selftest without file I/O
_load_state._orig = _load_state


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        # Patch _load_state to not read from disk in selftests
        _load_state.__wrapped__ = lambda: {"rehomed": {}}
        _selftest()
    else:
        main()
