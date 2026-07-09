#!/usr/bin/env python3
"""
sling-task-janitor.py — close orphaned dispatch sling-task stubs and orphaned
mol-do-work molecules.

A "sling task" is a ctx:thin type:task bead the Pilot mints at dispatch time, titled
"build story <id>" / "fix bug <id>", to hand a unit of work to a builder. When the
dispatch fails, reclaims, or the parent parks/closes, the stub lingers OPEN forever
with no lifecycle label — polluting the Triagem column (which holds no-lifecycle-label
work). 42 such orphans accumulated by 2026-06-29 (parents blocked/deferred/done).

This janitor closes a sling stub when ALL hold (conservative, fail-toward-KEEP):
  - it is type==task AND its title matches the sling pattern (parent id extracted)
  - it is NOT itself story:in-flight / story:approved / story:done (not tracked work)
  - it has NO live assignee (a live builder session means an active build → KEEP)
  - its parent is NOT story:in-flight (a story:in-flight parent = active build → KEEP;
    a closed / deferred / blocked / parked / missing parent = no active build → orphan)
  - it is older than MIN_AGE_MIN (default 60) — NEVER race a just-minted dispatch stub

A "molecule" (e.g. mol-do-work) is a standing pool-demand order: while it is open, the
supervisor keeps >=1 worker alive to execute its metadata["gc.var.issue"] target. If that
target is already closed/deferred/gone, the molecule is a dead order — a worker boots,
finds nothing to do, drains, and ~90s later min-fill boots another (measured: 1 respawn
per ~86s; 95 orphans silently accumulated over 5 weeks — ga-fckx). This janitor closes
such a molecule when ALL hold (conservative, fail-toward-KEEP — see _should_close_molecule):
  - it is type==molecule AND carries metadata["gc.var.issue"] (a target-tracking molecule;
    other molecule kinds, e.g. wisp-tracking, have no such key and are left untouched)
  - the target's fix is NOT in flight at the gate (open marker referencing the target)
  - it has NO live assignee (a live session means active execution → KEEP)
  - it is older than MIN_AGE_MIN — never race a just-minted molecule
  - the target's status is exactly closed/deferred/confirmed-missing — NOT open/
    in_progress/blocked/hooked/pinned/unresolved. Those three are the only statuses that
    mean "no active build possible"; everything else (including a status this janitor
    doesn't recognize) defaults to KEEP.

CADENCE: MAX_PER_SWEEP=10 by default (orphans are inert; a higher cap clears backlog fast),
shared across both sling-stub and molecule cleanup within one sweep.
LAUNCHD: StartInterval=900, one-shot (no KeepAlive). See com.gascity.sling-task-janitor.plist.
KILL-SWITCH: SLING_JANITOR_ENABLED=0 → safe no-op.
DRY_RUN: SLING_JANITOR_DRY_RUN=1 → logs intended actions, mutates nothing.
"""
import json
import os
import re
import subprocess
import sys
import datetime

CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
NOTIFY_BIN = os.environ.get("NOTIFY_BIN", "/Users/athos/.local/bin/notify")
GC_BIN = os.environ.get("GC_BIN", "gc")
BD_BIN = os.environ.get("BD_BIN", "bd")

ENABLED = os.environ.get("SLING_JANITOR_ENABLED", "1") == "1"
DRY_RUN = os.environ.get("SLING_JANITOR_DRY_RUN", "0") == "1"
MAX_PER_SWEEP = int(os.environ.get("SLING_MAX_PER_SWEEP", "10"))
BD_TIMEOUT = int(os.environ.get("SLING_BD_TIMEOUT", "30"))
MIN_AGE_MIN = int(os.environ.get("SLING_MIN_AGE_MIN", "60"))

# A sling stub title: "build story <id>", "fix bug <id>", "build <id>", "implement <id>".
SLING_RE = re.compile(r"\b(?:build story|fix bug|build|fix|implement)\s+([a-z]{2,3}-[a-z0-9]+)", re.I)
# A bead carrying any of these is TRACKED work, not an inert orphan stub — never touch.
_ACTIVE_LABELS = {"story:in-flight", "story:approved", "story:done", "story:needs-approval"}

# Molecule target-status orphan detection. Sentinel for "bd confirmed no such bead exists"
# (distinct from None/absent, which means the lookup was inconclusive — always KEEP on that).
# Built-in bd statuses are open/in_progress/blocked/hooked (all real demand), deferred/pinned
# (frozen), closed (done) — see `bd statuses`. Only closed/deferred/missing mean "no active
# build possible"; hooked (attached to an agent right now) and pinned (permanent reference,
# stays open indefinitely by design) must NEVER be treated as orphan-eligible.
_TARGET_MISSING = "__missing__"
_ORPHAN_TARGET_STATUSES = {"closed", "deferred", _TARGET_MISSING}

# ── test seams (monkeypatched in --selftest) ───────────────────────────────────
_bd_list_open_fn = None   # (store) -> list[dict]
_bd_close_fn = None       # (store, bead_id, reason) -> bool
_gated_fn = None          # () -> set[str]  (bead-ids with an open gate marker)
_sessions_fn = None       # () -> set[str] of live session identifiers
_rigs_fn = None           # () -> list[str] store paths
_do_notify_fn = None      # (msg, prio) -> None
_target_status_fn = None  # (targets_by_store: dict[store, set[id]]) -> dict[id, status]
_rig_name_map_fn = None   # () -> dict[rig_name, store_path]


def _sh(args, timeout=20):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        _log("WARN: subprocess failed: %r (%r)" % (args[:3], e))
        return None


def _log(msg):
    print("[sling-janitor] %s" % msg, flush=True)


def _notify(msg, prio=2):
    if _do_notify_fn is not None:
        _do_notify_fn(msg, prio)
        return
    if DRY_RUN:
        _log("DRY_RUN: would notify: %s" % msg)
        return
    _sh([NOTIFY_BIN, "-t", "Sling janitor", "-p", str(prio), msg], timeout=10)


def _parse_bd_json(raw):
    if not raw:
        return []
    try:
        d = json.loads(raw)
        return d if isinstance(d, list) else []
    except Exception:
        # tolerate trailing control-char garbage: truncate to the last ']'
        try:
            i = raw.rstrip().rfind("]")
            return json.loads(raw[: i + 1]) if i > 0 else []
        except Exception as e:
            _log("WARN: _parse_bd_json failed: %r" % e)
            return []


def _stores():
    """All bead stores: HQ + every rig path (gc rig list)."""
    if _rigs_fn is not None:
        return _rigs_fn()
    out = [CITY]
    r = _sh([GC_BIN, "--city", CITY, "rig", "list", "--json"], timeout=BD_TIMEOUT)
    if r and r.returncode == 0:
        try:
            for rig in (json.loads(r.stdout).get("rigs") or []):
                p = rig.get("path")
                if p and p not in out and os.path.isdir(p):
                    out.append(p)
        except Exception as e:
            _log("WARN: gc rig list parse: %r" % e)
    return out


def _rig_name_map():
    """rig name -> store path. A molecule's metadata["gc.var.rig_name"] records which rig
    its gc.var.issue target actually lives in — not necessarily the molecule's own store
    (an HQ-minted molecule can target a rig bead). Resolve via this map. Callers use the
    molecule's own store ONLY when rig_name is ABSENT (an own-store target). When rig_name
    is PRESENT but unresolved here (map miss / flaky `gc rig list`), callers MUST defer —
    leave the target unresolved so it is KEPT — and never fall back to the own store: a
    cross-store `bd show` miss is indistinguishable from a deleted bead and would
    false-close live demand (ga-fckx gate-FAIL follow-up)."""
    if _rig_name_map_fn is not None:
        return _rig_name_map_fn()
    out = {}
    r = _sh([GC_BIN, "--city", CITY, "rig", "list", "--json"], timeout=BD_TIMEOUT)
    if r and r.returncode == 0:
        try:
            for rig in (json.loads(r.stdout).get("rigs") or []):
                n, p = rig.get("name"), rig.get("path")
                if n and p:
                    out[n] = p
        except Exception as e:
            _log("WARN: rig name map parse: %r" % e)
    return out


def _target_statuses(targets_by_store):
    """Resolve {target_id: status} in one batched `bd show <id...>` call per store (bd
    happily returns the found subset and reports the rest as errors — no need for N
    single-id lookups). A confirmed-missing id (bd: 'no issue found matching') maps to
    _TARGET_MISSING. An id that is neither found nor confirmed-missing (timeout, transient
    dolt error, unexpected output) is left OUT of the returned dict entirely — callers must
    treat absent-from-dict as unresolved/ambiguous and always KEEP, never treat it as
    confirmed-missing."""
    if _target_status_fn is not None:
        return _target_status_fn(targets_by_store)
    out = {}
    for store, ids in targets_by_store.items():
        ids = sorted(ids)
        if not ids:
            continue
        r = _sh([BD_BIN, "-C", store, "show"] + ids + ["--json"], timeout=BD_TIMEOUT)
        if r is None:
            continue
        found = set()
        if r.stdout:
            try:
                data = json.loads(r.stdout)
                items = data if isinstance(data, list) else [data]
                for item in items:
                    if isinstance(item, dict) and item.get("id"):
                        out[item["id"]] = item.get("status") or ""
                        found.add(item["id"])
            except Exception as e:
                _log("WARN: target status parse in %s: %r" % (os.path.basename(store), e))
        stderr = r.stderr or ""
        for i in ids:
            if i in found:
                continue
            if ('no issue found matching "%s"' % i) in stderr:
                out[i] = _TARGET_MISSING
            # else: leave unresolved (absent from out) — ambiguous, never orphan-eligible
    return out


def _list_open(store):
    if _bd_list_open_fn is not None:
        return _bd_list_open_fn(store)
    r = _sh([BD_BIN, "-C", store, "list", "--json", "--status", "open,in_progress", "-n", "0"],
            timeout=BD_TIMEOUT)
    if r is None or r.returncode != 0:
        _log("WARN: bd list failed in %s (rc=%s)" % (os.path.basename(store), r.returncode if r else "err"))
        return None
    return _parse_bd_json(r.stdout)


_BEADID_RE = re.compile(r"\b([a-z]{2,3}-[a-z0-9]{4,})\b")


def _gated_bead_ids():
    """Set of bead-ids whose fix is IN FLIGHT at the gate — referenced by an OPEN
    quality-gate-marker (its source-bead: label, or a bead-id embedded in its branch:).
    A sling-task whose fix sits queued/reviewing at the gate is TRACKED work, NOT an
    inert orphan: closing it made the orphaned-marker reaper false-close the marker as
    'merged' and STRAND a complete fix (ga-w5agg/ga-d2jil, 2026-07-02). Markers live in
    HQ (CITY). Empty set on query failure → the caller's other KEEP guards still apply."""
    if _gated_fn is not None:
        return _gated_fn()
    ids = set()
    r = _sh([BD_BIN, "-C", CITY, "list", "--all", "-l", "type:quality-gate-marker",
             "--status", "open", "--json", "-n", "0"], timeout=BD_TIMEOUT)
    if not r or r.returncode != 0:
        return ids
    for m in (_parse_bd_json(r.stdout) or []):
        if not isinstance(m, dict):
            continue
        for lb in (m.get("labels") or []):
            s = str(lb)
            if s.startswith("source-bead:"):
                ids.add(s.split(":", 1)[1].strip())
            elif s.startswith("branch:"):
                ids.update(_BEADID_RE.findall(s))
    return ids


def _live_sessions():
    if _sessions_fn is not None:
        return _sessions_fn()
    r = _sh(["bash", "/Users/athos/gt/.gascity-gastown-hq/scripts/gc-session-list-cached.sh"], timeout=BD_TIMEOUT)  # Option C shim (pins --city internally)
    live = set()
    if r and r.returncode == 0:
        try:
            for s in (json.loads(r.stdout).get("sessions") or []):
                if s.get("closed") is True:
                    continue
                for k in ("session_name", "name", "alias", "id", "agent_name"):
                    v = s.get(k)
                    if v:
                        live.add(v)
        except Exception as e:
            _log("WARN: session list parse: %r" % e)
    return live


def _close(store, bead_id, reason):
    if _bd_close_fn is not None:
        return _bd_close_fn(store, bead_id, reason)
    if DRY_RUN:
        _log("DRY_RUN: would close %s in %s" % (bead_id, os.path.basename(store)))
        return True
    r = _sh([BD_BIN, "-C", store, "close", bead_id, "-r", reason], timeout=BD_TIMEOUT)
    return bool(r and r.returncode == 0)


def _age_min(bead, now):
    """Minutes since updated_at (fallback created_at). Unparseable → 0 (treated as fresh → KEEP)."""
    ts = bead.get("updated_at") or bead.get("created_at") or ""
    if not ts:
        return 0.0
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            dt = datetime.datetime.strptime(ts[:19], fmt).replace(tzinfo=datetime.timezone.utc)
            return (now - dt.timestamp()) / 60.0
        except Exception:
            continue
    return 0.0


def _is_sling(bead):
    t = (bead.get("issue_type") or bead.get("type") or "").lower()
    if t != "task":
        return None
    m = SLING_RE.search(bead.get("title") or "")
    return m.group(1) if m else None


def _is_orphan_molecule(bead):
    """Return the gc.var.issue target id if this is a target-tracking molecule (e.g.
    mol-do-work), else None. Molecules without this metadata key (e.g. wisp-tracking
    molecules seen in the HQ store) are a different concern and never touched here."""
    t = (bead.get("issue_type") or bead.get("type") or "").lower()
    if t != "molecule":
        return None
    target = (bead.get("metadata") or {}).get("gc.var.issue")
    return target or None


def _should_close(bead, parent_inflight_ids, live, now, gated=frozenset()):
    """Return (close: bool, reason_or_skip: str). Fail-toward-KEEP."""
    bid = bead.get("id", "?")
    parent = _is_sling(bead)
    if not parent:
        return False, "not-a-sling-task"
    labels = set(bead.get("labels") or [])
    if labels & _ACTIVE_LABELS:
        return False, "stub carries an active lifecycle label (tracked work)"
    # A fix whose branch sits at the gate (open marker) is TRACKED work — closing it
    # made the orphaned-marker reaper false-close the marker as 'merged' and STRAND a
    # complete fix (ga-w5agg/ga-d2jil). Never orphan a bead with a live gate marker.
    if bid in gated or parent in gated:
        return False, "fix is IN FLIGHT at the gate (open marker refs %s) — tracked work" % (bid if bid in gated else parent)
    asg = bead.get("assignee") or ""
    if asg and asg in live:
        return False, "stub assignee '%s' is a LIVE session (active build)" % asg
    if parent in parent_inflight_ids:
        return False, "parent %s is story:in-flight (active build)" % parent
    age = _age_min(bead, now)
    if age < MIN_AGE_MIN:
        return False, "too fresh (age=%.0fmin < %d) — never race a just-minted dispatch" % (age, MIN_AGE_MIN)
    return True, ("orphan: parent %s NOT in active build, no live assignee, age=%.0fmin" % (parent, age))


def _should_close_molecule(bead, target_status, live, now, gated=frozenset()):
    """Return (close: bool, reason_or_skip: str). Fail-toward-KEEP, mirrors _should_close.
    target_status is the pre-resolved status of bead's gc.var.issue target: a real bd status
    string, _TARGET_MISSING (bd confirmed no such bead), or None (unresolved/ambiguous)."""
    bid = bead.get("id", "?")
    target = _is_orphan_molecule(bead)
    if not target:
        return False, "not-a-tracked-molecule"
    if bid in gated or target in gated:
        return False, "target's fix is IN FLIGHT at the gate (open marker) — tracked work"
    asg = bead.get("assignee") or ""
    if asg and asg in live:
        return False, "molecule assignee '%s' is a LIVE session (active execution)" % asg
    age = _age_min(bead, now)
    if age < MIN_AGE_MIN:
        return False, "too fresh (age=%.0fmin < %d) — never race a just-minted molecule" % (age, MIN_AGE_MIN)
    if target_status not in _ORPHAN_TARGET_STATUSES:
        disp = target_status if target_status is not None else "unresolved"
        return False, "target %s status is '%s' (not a known orphan state) — keep" % (target, disp)
    disp = "missing" if target_status == _TARGET_MISSING else target_status
    return True, ("orphan: target %s is %s (no active build possible), age=%.0fmin" % (target, disp, age))


def _try_close(store, bid, why, reason, closed):
    """Shared cap-check + close + log for both the sling-stub and molecule paths in
    run_cycle. Only call once do_close is already True. Returns (new_closed_count,
    hit_cap) — hit_cap=True means MAX_PER_SWEEP was reached; the caller must return
    immediately so the cap is honored jointly across both orphan kinds."""
    if closed >= MAX_PER_SWEEP:
        _log("  (MAX_PER_SWEEP=%d reached — deferring remaining orphans to next sweep)" % MAX_PER_SWEEP)
        return closed, True
    if _close(store, bid, reason):
        closed += 1
        _log("  CLOSED %s/%s (%s)" % (os.path.basename(store), bid, why))
    else:
        _log("  WARN: failed to close %s/%s (non-fatal; retry next sweep)" % (os.path.basename(store), bid))
    return closed, False


def run_cycle(now):
    """One sweep across all stores. Returns count closed."""
    stores = _stores()
    live = _live_sessions()
    gated = _gated_bead_ids()  # bead-ids whose fix is in flight at the gate — never orphan
    # Build the set of bead ids that are story:in-flight across ALL stores (parents).
    store_beads = {}
    inflight = set()
    for store in stores:
        beads = _list_open(store)
        if beads is None:
            continue
        store_beads[store] = beads
        for b in beads:
            if isinstance(b, dict) and "story:in-flight" in set(b.get("labels") or []):
                inflight.add(b.get("id"))

    # Collect molecule targets (pure, no I/O) so their statuses can be resolved in one
    # batched call per store — skip the rig-name-map/bd-show round trips entirely when
    # this sweep has no target-tracking molecules at all.
    molecule_refs = []  # (store, target, rig_name)
    for store, beads in store_beads.items():
        for b in beads:
            if not isinstance(b, dict):
                continue
            target = _is_orphan_molecule(b)
            if target:
                rig_name = (b.get("metadata") or {}).get("gc.var.rig_name")
                molecule_refs.append((store, target, rig_name))

    target_statuses = {}
    if molecule_refs:
        rig_map = _rig_name_map()
        targets_by_store = {}
        for store, target, rig_name in molecule_refs:
            if rig_name:
                target_store = rig_map.get(rig_name)
                if target_store is None:
                    # ga-fckx gate-FAIL follow-up: rig_name is PRESENT but UNRESOLVED in the
                    # rig map — `gc rig list` was flaky/errored (empty/partial map) or the
                    # rig_name is unknown/renamed. We do NOT know which store the target lives
                    # in. Falling back to the molecule's OWN store (the old
                    # `rig_map.get(rig_name, store)`) is UNSAFE: a per-store `bd show` there
                    # answers 'no issue found' for a target whose id lives in ANOTHER store —
                    # structurally indistinguishable from a genuinely-deleted bead — so it maps
                    # to _TARGET_MISSING and the molecule gets false-closed as dead demand even
                    # though its target may be wide open in its real rig (the exact INVERSE of
                    # the bug this janitor exists to fix). Leave the target OUT of the lookup →
                    # its status stays unresolved → _should_close_molecule KEEPs it (ambiguous
                    # is never orphan-eligible). A later sweep, once the rig map resolves,
                    # re-evaluates it correctly.
                    _log("  KEEP (deferred): molecule target %s — rig_name=%r unresolved in rig "
                         "map (gc rig list flaky or unknown rig); not risking a cross-store "
                         "false-missing" % (target, rig_name))
                    continue
            else:
                target_store = store  # no rig_name → target lives in the molecule's own store
            targets_by_store.setdefault(target_store, set()).add(target)
        target_statuses = _target_statuses(targets_by_store)

    closed = 0
    for store, beads in store_beads.items():
        for b in beads:
            if not isinstance(b, dict):
                continue
            bid = b.get("id", "?")

            parent = _is_sling(b)
            if parent:
                do_close, why = _should_close(b, inflight, live, now, gated)
                if not do_close:
                    _log("  KEEP %s/%s: %s" % (os.path.basename(store), bid, why))
                    continue
                reason = ("Orphan sling-task cleanup (sling-task-janitor): ctx:thin dispatch stub for "
                          "'%s' whose parent is NOT in active build and which has no live assignee. "
                          "Stale orphan polluting Triagem — closed. The parent's own state drives any "
                          "future dispatch; this stub is not needed." % parent)
                closed, hit_cap = _try_close(store, bid, why, reason, closed)
                if hit_cap:
                    return closed
                continue

            target = _is_orphan_molecule(b)
            if target:
                do_close, why = _should_close_molecule(b, target_statuses.get(target), live, now, gated)
                if not do_close:
                    _log("  KEEP %s/%s: %s" % (os.path.basename(store), bid, why))
                    continue
                tstatus = target_statuses.get(target)
                disp = "missing" if tstatus == _TARGET_MISSING else tstatus
                reason = ("Orphan molecule cleanup (sling-task-janitor, ga-fckx): this mol-do-work "
                          "molecule's target %s is %s (no active build possible) and the molecule has "
                          "no live assignee. Left open, it is a standing pool-demand order — the "
                          "supervisor keeps booting a worker to execute it, finding nothing, draining, "
                          "and respawning. Closed as dead demand." % (target, disp))
                closed, hit_cap = _try_close(store, bid, why, reason, closed)
                if hit_cap:
                    return closed
    return closed


def main():
    if not ENABLED:
        _log("SLING_JANITOR_ENABLED=0 → no-op")
        return
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    _log("=== sweep start (DRY_RUN=%s, MAX_PER_SWEEP=%d, MIN_AGE_MIN=%d) ===" % (DRY_RUN, MAX_PER_SWEEP, MIN_AGE_MIN))
    n = run_cycle(now)
    _log("=== sweep done: %d orphan(s) closed (sling-task stubs + dead molecules) ===" % n)
    if n >= 5 and not DRY_RUN:
        _notify("Closed %d orphan(s): dispatch sling-tasks + dead pool-demand molecules" % n, prio=2)


# ── selftest ────────────────────────────────────────────────────────────────────
def _selftest():
    global _bd_list_open_fn, _bd_close_fn, _sessions_fn, _rigs_fn, _do_notify_fn, MAX_PER_SWEEP
    global _target_status_fn, _rig_name_map_fn
    ok = [0]
    bad = [0]
    def _ok(m): ok[0] += 1; print("  ok  " + m)
    def _bad(m, d=""): bad[0] += 1; print("  BAD " + m + ((" :: " + d) if d else ""))

    NOW = datetime.datetime(2026, 6, 29, 12, 0, 0, tzinfo=datetime.timezone.utc).timestamp()
    OLD = "2026-06-23T00:00:00Z"   # 6 days old → past MIN_AGE
    FRESH = "2026-06-29T11:45:00Z"  # 15 min old → under MIN_AGE
    def mk(bid, title, labels=None, assignee="", updated=OLD, itype="task"):
        return {"id": bid, "title": title, "issue_type": itype, "labels": labels or [],
                "assignee": assignee, "updated_at": updated}
    def mkmol(bid, target, assignee="", updated=OLD, rig_name=None):
        md = {"gc.var.issue": target}
        if rig_name:
            md["gc.var.rig_name"] = rig_name
        return {"id": bid, "title": "do work", "issue_type": "molecule", "labels": [],
                "assignee": assignee, "updated_at": updated, "metadata": md}

    print("Scenario A: orphan stub (parent not in-flight, no assignee, old) → CLOSE")
    c, why = _should_close(mk("t1", "build story ga-parked"), set(), set(), NOW)
    _ok("A: closes the orphan") if c else _bad("A: did not close orphan", why)

    print("Scenario B: parent IS story:in-flight → KEEP (active build)")
    c, why = _should_close(mk("t2", "build story ga-live"), {"ga-live"}, set(), NOW)
    _bad("B: wrongly closed an active-parent stub", why) if c else _ok("B: keeps active-parent stub")

    print("Scenario C: stub has a LIVE assignee → KEEP")
    c, why = _should_close(mk("t3", "build story ga-x", assignee="wa-worker-adhoc-LIVE"), set(), {"wa-worker-adhoc-LIVE"}, NOW)
    _bad("C: wrongly closed a live-assignee stub", why) if c else _ok("C: keeps live-assignee stub")

    print("Scenario D: too-fresh stub → KEEP (never race a just-minted dispatch)")
    c, why = _should_close(mk("t4", "build story ga-fresh", updated=FRESH), set(), set(), NOW)
    _bad("D: wrongly closed a fresh stub", why) if c else _ok("D: keeps fresh stub")

    print("Scenario E: stub itself story:in-flight → KEEP (tracked work)")
    c, why = _should_close(mk("t5", "build story ga-x", labels=["story:in-flight"]), set(), set(), NOW)
    _bad("E: wrongly closed an in-flight stub", why) if c else _ok("E: keeps in-flight stub")

    print("Scenario F: not a sling task (no pattern) → ignore")
    c, why = _should_close(mk("t6", "Refatorar o dashboard de clientes"), set(), set(), NOW)
    _bad("F: matched a non-sling title", why) if c else _ok("F: ignores non-sling task")

    print("Scenario G: parent MISSING (closed/deferred → not in inflight set) → CLOSE")
    c, why = _should_close(mk("t7", "fix bug ga-gone"), set(), set(), NOW)
    _ok("G: closes a stub whose parent is gone/closed") if c else _bad("G: did not close", why)

    print("Scenario G2: fix IN FLIGHT at the gate (open marker) → KEEP (the ga-w5agg/ga-d2jil bug)")
    c, why = _should_close(mk("ga-tkvsa", "fix bug ga-w5agg"), set(), set(), NOW, gated={"ga-tkvsa"})
    _bad("G2: false-closed a gated fix (would strand it)", why) if c else _ok("G2: keeps a sling-task whose OWN fix has an open gate marker")
    c, why = _should_close(mk("t8", "fix bug ga-w5agg"), set(), set(), NOW, gated={"ga-w5agg"})
    _bad("G2b: false-closed (parent gated)", why) if c else _ok("G2b: keeps when the PARENT bead has an open gate marker")

    print("Scenario H: run_cycle end-to-end via seams (MAX_PER_SWEEP honored)")
    MAX_PER_SWEEP = 2
    fake = [
        mk("o1", "build story ga-p1"), mk("o2", "build story ga-p2"),
        mk("o3", "build story ga-p3"),                      # 3rd orphan — should defer (cap=2)
        mk("keep1", "build story ga-act", ),                # parent in-flight
        mk("act", "the parent", labels=["story:in-flight"], itype="feature"),
    ]
    # make 'keep1' point at the in-flight parent 'ga-act'
    fake[3]["title"] = "build story ga-act"
    closed_ids = []
    _rigs_fn = lambda: ["S"]
    _bd_list_open_fn = lambda store: fake
    _sessions_fn = lambda: set()
    _bd_close_fn = lambda store, bid, reason: (closed_ids.append(bid) or True)
    _do_notify_fn = lambda m, p: None
    # parent ga-act must be in-flight; but it's referenced as 'ga-act' while the bead id is 'act'.
    # Fix: the in-flight parent bead's id must equal the referenced id.
    fake[4]["id"] = "ga-act"
    n = run_cycle(NOW)
    if n == 2 and set(closed_ids) == {"o1", "o2"}:
        _ok("H: closed exactly MAX_PER_SWEEP orphans (o1,o2), deferred o3, kept active-parent stub")
    else:
        _bad("H: run_cycle wrong", "n=%d closed=%s" % (n, closed_ids))

    print("Scenario I: orphan molecule (target closed, old, no assignee) → CLOSE (the ga-fckx bug)")
    c, why = _should_close_molecule(mkmol("m1", "ga-gone"), "closed", set(), NOW)
    _ok("I: closes the dead-demand molecule") if c else _bad("I: did not close orphan molecule", why)

    print("Scenario J: molecule target still OPEN → KEEP (real demand)")
    c, why = _should_close_molecule(mkmol("m2", "ga-live"), "open", set(), NOW)
    _bad("J: wrongly closed a molecule with real open demand", why) if c else _ok("J: keeps molecule whose target is open")

    print("Scenario K: molecule target IN_PROGRESS → KEEP (active build)")
    c, why = _should_close_molecule(mkmol("m3", "ga-building"), "in_progress", set(), NOW)
    _bad("K: wrongly closed a molecule mid-build", why) if c else _ok("K: keeps molecule whose target is in_progress")

    print("Scenario L: molecule target CONFIRMED MISSING (bd: no such bead) → CLOSE")
    c, why = _should_close_molecule(mkmol("m4", "ga-ghost"), _TARGET_MISSING, set(), NOW)
    _ok("L: closes molecule whose target bead no longer exists") if c else _bad("L: did not close", why)

    print("Scenario M: molecule target status UNRESOLVED (lookup failed/ambiguous) → KEEP")
    c, why = _should_close_molecule(mkmol("m5", "ga-unknown"), None, set(), NOW)
    _bad("M: wrongly closed on an unresolved target status", why) if c else _ok("M: keeps molecule when target status could not be resolved")

    print("Scenario N: molecule has a LIVE assignee → KEEP even though target is closed")
    c, why = _should_close_molecule(mkmol("m6", "ga-gone", assignee="wa-worker-LIVE"), "closed", {"wa-worker-LIVE"}, NOW)
    _bad("N: wrongly closed a live-assignee molecule", why) if c else _ok("N: keeps live-assignee molecule")

    print("Scenario O: too-fresh molecule → KEEP even though target is closed (never race a just-minted molecule)")
    c, why = _should_close_molecule(mkmol("m7", "ga-gone", updated=FRESH), "closed", set(), NOW)
    _bad("O: wrongly closed a fresh molecule", why) if c else _ok("O: keeps fresh molecule")

    print("Scenario P: molecule's TARGET is gated (fix in flight at the gate) → KEEP (mirrors G2 for molecules)")
    c, why = _should_close_molecule(mkmol("m8", "ga-gated"), "closed", set(), NOW, gated={"ga-gated"})
    _bad("P: false-closed a molecule whose target has an open gate marker", why) if c else _ok("P: keeps molecule whose target is gated")

    print("Scenario Q: non-target-tracking molecule (no gc.var.issue, e.g. wisp-tracking) → ignore")
    wisp_mol = {"id": "m9", "title": "track wisp", "issue_type": "molecule", "labels": [],
                "assignee": "", "updated_at": OLD, "metadata": {}}
    c, why = _should_close_molecule(wisp_mol, "closed", set(), NOW)
    _bad("Q: touched a non-target-tracking molecule", why) if c else _ok("Q: ignores molecule with no gc.var.issue")

    print("Scenario R: molecule target status is hooked/pinned (real demand states, not in orphan set) → KEEP")
    c, why = _should_close_molecule(mkmol("m10", "ga-hooked"), "hooked", set(), NOW)
    _bad("R: wrongly closed a molecule whose target is hooked", why) if c else _ok("R: keeps molecule whose target is hooked")
    c, why = _should_close_molecule(mkmol("m11", "ga-pinned"), "pinned", set(), NOW)
    _bad("R2: wrongly closed a molecule whose target is pinned", why) if c else _ok("R2: keeps molecule whose target is pinned")

    print("Scenario S: run_cycle closes an orphan molecule end-to-end (cross-store target resolution via gc.var.rig_name)")
    MAX_PER_SWEEP = 10
    mol_orphan = mkmol("mo1", "wa-done", rig_name="whatsapp_automation")
    mol_live_target = mkmol("mo2", "wa-active", rig_name="whatsapp_automation")
    closed_ids2 = []
    captured_targets_by_store = [None]
    _rigs_fn = lambda: ["HQ"]
    _bd_list_open_fn = lambda store: [mol_orphan, mol_live_target]
    _sessions_fn = lambda: set()
    _bd_close_fn = lambda store, bid, reason: (closed_ids2.append(bid) or True)
    _do_notify_fn = lambda m, p: None
    _rig_name_map_fn = lambda: {"whatsapp_automation": "WA_STORE"}
    def _fake_target_status_fn(targets_by_store):
        captured_targets_by_store[0] = targets_by_store
        return {"wa-done": "closed", "wa-active": "open"}
    _target_status_fn = _fake_target_status_fn
    n = run_cycle(NOW)
    if closed_ids2 == ["mo1"] and captured_targets_by_store[0] == {"WA_STORE": {"wa-done", "wa-active"}}:
        _ok("S: closed the cross-store-resolved orphan molecule, kept the live-target one, routed lookup via gc.var.rig_name")
    else:
        _bad("S: run_cycle molecule path wrong", "closed=%s targets_by_store=%s" % (closed_ids2, captured_targets_by_store[0]))
    _rig_name_map_fn = None
    _target_status_fn = None

    print("Scenario T: MAX_PER_SWEEP is SHARED across sling-stub and molecule closes within one sweep")
    MAX_PER_SWEEP = 1
    sling_orphan = mk("s1", "build story ga-parked2")
    mol_orphan2 = mkmol("mo3", "ga-gone2")
    closed_ids3 = []
    _rigs_fn = lambda: ["HQ"]
    _bd_list_open_fn = lambda store: [sling_orphan, mol_orphan2]
    _sessions_fn = lambda: set()
    _bd_close_fn = lambda store, bid, reason: (closed_ids3.append(bid) or True)
    _do_notify_fn = lambda m, p: None
    _rig_name_map_fn = lambda: {}
    _target_status_fn = lambda targets_by_store: {"ga-gone2": "closed"}
    n = run_cycle(NOW)
    if n == 1 and closed_ids3 == ["s1"]:
        _ok("T: cap=1 stopped after the first close (sling stub) and deferred the molecule to next sweep")
    else:
        _bad("T: shared cap not honored", "n=%d closed=%s" % (n, closed_ids3))
    _rig_name_map_fn = None
    _target_status_fn = None

    print("Scenario U: molecule rig_name PRESENT but UNRESOLVED in rig map (flaky gc rig list / unknown rig) → KEEP; MUST NOT look the target up against a fallback store (ga-fckx gate-FAIL follow-up: unsafe cross-store fallback false-closes live demand)")
    MAX_PER_SWEEP = 10
    mol_unresolved = mkmol("mu1", "wa-livetarget", rig_name="whatsapp_automation")
    closed_idsU = []
    capturedU = [None]
    _rigs_fn = lambda: ["HQ"]
    _bd_list_open_fn = lambda store: [mol_unresolved]
    _sessions_fn = lambda: set()
    _bd_close_fn = lambda store, bid, reason: (closed_idsU.append(bid) or True)
    _do_notify_fn = lambda m, p: None
    _rig_name_map_fn = lambda: {}   # rig_name unresolved: gc rig list flaky / rig unknown
    def _fake_status_U(targets_by_store):
        capturedU[0] = targets_by_store
        # Simulate what a real bd would answer if the buggy fallback queried the target
        # against the WRONG (molecule's own) store: 'no issue found' → _TARGET_MISSING.
        # With the fix in place this fn should never even see wa-livetarget.
        return {tid: _TARGET_MISSING for ids in targets_by_store.values() for tid in ids}
    _target_status_fn = _fake_status_U
    n = run_cycle(NOW)
    _queriedU = [tid for ids in (capturedU[0] or {}).values() for tid in ids]
    if closed_idsU == [] and "wa-livetarget" not in _queriedU:
        _ok("U: kept the unresolved-rig molecule and never looked its target up against a fallback store")
    else:
        _bad("U: unsafe cross-store fallback still present (false-close risk)",
             "closed=%s targets_by_store=%s" % (closed_idsU, capturedU[0]))
    _rig_name_map_fn = None
    _target_status_fn = None

    print("\n[sling-janitor selftest] %d passed, %d failed" % (ok[0], bad[0]))
    sys.exit(1 if bad[0] else 0)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        main()
