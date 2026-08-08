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
BD_LIST_CACHED = os.path.join(CITY, "scripts/bd-list-cached.sh")  # ga-xwza2: read-cache shim (ga-48xcv)

ENABLED = os.environ.get("SLING_JANITOR_ENABLED", "1") == "1"
DRY_RUN = os.environ.get("SLING_JANITOR_DRY_RUN", "0") == "1"
MAX_PER_SWEEP = int(os.environ.get("SLING_MAX_PER_SWEEP", "10"))
BD_TIMEOUT = int(os.environ.get("SLING_BD_TIMEOUT", "30"))
MIN_AGE_MIN = int(os.environ.get("SLING_MIN_AGE_MIN", "60"))

# A sling stub title: "build story <id>", "fix bug <id>", "build <id>", "implement <id>".
SLING_RE = re.compile(r"\b(?:build story|fix bug|build|fix|implement)\s+([a-z]{2,3}-[a-z0-9]+)", re.I)
# A bead carrying any of these is TRACKED work, not an inert orphan stub — never touch.
_ACTIVE_LABELS = {"story:in-flight", "story:approved", "story:done", "story:needs-approval"}
# ga-0jcit: a stub the assignee explicitly refused (`pool:refused:<reason>`, per the dog
# refuse protocol) is a terminal decision, not active work — even though dog-pool sessions
# are long-lived and stay "live" indefinitely after refusing. Prefix match (labels carry a
# reason suffix, e.g. pool:refused:needs-human-investigation).
_POOL_REFUSED_PREFIX = "pool:refused:"

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
        # ga-xwza2 gate feedback (attempt 1 FAIL): NOT routed through the read-cache
        # shim. bd-list-cached.sh's _live() helper unconditionally does `2>/dev/null`
        # on every code path (cache-miss live refresh AND the lock-contention live
        # fallback), so the wrapped bd's stderr never survives — and this call's
        # _TARGET_MISSING detection below depends entirely on stderr text ('no issue
        # found matching'). A fixed _live() alone wouldn't be enough either: a cache
        # HIT replays only the stored stdout JSON (the cache file format never
        # captured stderr to begin with), so the signal would still be lost on any
        # call served from cache. Same shape as gate-marker-rehome-janitor.py's
        # _verify_hq() in this same rollout — skip the shim entirely for this site.
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
    # ga-xwza2: routed through the read-cache shim — informational open/in_progress
    # membership scan, not a read-after-write.
    r = _sh(["bash", BD_LIST_CACHED, "-C", store, "list", "--json", "--status", "open,in_progress", "-n", "0"],
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
    # ga-xwza2: routed through the read-cache shim — informational marker scan
    # (which beads are tracked at the gate), not a read-after-write.
    r = _sh(["bash", BD_LIST_CACHED, "-C", CITY, "list", "--all", "-l", "type:quality-gate-marker",
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


def _is_refused(labels):
    """True if any label on the stub itself carries the pool:refused: prefix — an explicit,
    terminal refuse by its assignee (see _POOL_REFUSED_PREFIX)."""
    return any(str(l).startswith(_POOL_REFUSED_PREFIX) for l in labels)


def _is_orphan_molecule(bead):
    """Return the gc.var.issue target id if this is a target-tracking molecule (e.g.
    mol-do-work), else None. Molecules without this metadata key (e.g. wisp-tracking
    molecules seen in the HQ store) are a different concern and never touched here."""
    t = (bead.get("issue_type") or bead.get("type") or "").lower()
    if t != "molecule":
        return None
    target = (bead.get("metadata") or {}).get("gc.var.issue")
    return target or None


def _should_close(bead, parent_inflight_ids, live, now, gated=frozenset(), parent_status_by_id=None):
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
    refused = _is_refused(labels)
    # ga-mf0gb: symmetric to the refused override — a dog-pool session staying live after
    # the PARENT bug already closed (verified merge, one way or another) is equally terminal
    # as an explicit refuse. Only an exact resolved "closed" status counts; None (unresolved
    # lookup) or any other status (open/deferred/blocked/missing/...) must NOT trigger this —
    # fail-toward-KEEP.
    parent_closed = (parent_status_by_id or {}).get(parent) == "closed"
    if asg and asg in live and not refused and not parent_closed:
        return False, "stub assignee '%s' is a LIVE session (active build)" % asg
    if parent in parent_inflight_ids:
        return False, "parent %s is story:in-flight (active build)" % parent
    age = _age_min(bead, now)
    if age < MIN_AGE_MIN:
        return False, "too fresh (age=%.0fmin < %d) — never race a just-minted dispatch" % (age, MIN_AGE_MIN)
    if refused and asg and asg in live:
        return True, ("orphan: stub explicitly refused (pool:refused:*) — assignee '%s' is still "
                       "live, but dog-pool sessions are long-lived and the refuse is a terminal "
                       "decision, age=%.0fmin" % (asg, age))
    if parent_closed and asg and asg in live:
        return True, ("orphan: parent %s is CONFIRMED CLOSED — assignee '%s' is still live, but a "
                       "dog-pool session remaining live after finishing this task is not evidence "
                       "the stub itself is still active work, age=%.0fmin" % (parent, asg, age))
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


def _deps(bead, kind):
    """Ids this bead DEPENDS ON via `kind` edges.

    ga-mpnhh: `bd list --json` spells the edge kind `type` and the target
    `depends_on_id`; `bd show --json` spells them `dependency_type` and `id`.
    Reading only one spelling yields an EMPTY set for half the call sites — and
    empty is the KEEP/no-parent answer here, so the bug would hide as inaction
    instead of surfacing as an error. Both spellings, always.
    """
    out = set()
    for dep in (bead.get("dependencies") or []):
        if not isinstance(dep, dict):
            continue
        if (dep.get("dependency_type") or dep.get("type") or "").lower() != kind:
            continue
        target = dep.get("depends_on_id") or dep.get("id")
        if target:
            out.add(str(target))
    return out


def _step_parent(bead):
    """Parent molecule id of a STEP bead, or None (None ⇒ never orphan-eligible).

    Auto-auditoria do próprio diff: a primeira versão fazia `sorted(parents)[0]`,
    escolhendo UM pai arbitrário quando havia mais de um. Isso é o mesmo colapso
    de terceiro estado que esta função existe pra evitar, só que introduzido por
    mim: com dois pais, um FECHADO e outro ABERTO, o step viraria "órfão" por
    sorteio alfabético e o trabalho vivo do outro pai seria fechado junto.
    Mais de um pai é estrutura que eu não sei ler ⇒ None ⇒ KEEP.
    """
    if (bead.get("issue_type") or bead.get("type") or "").lower() != "step":
        return None
    parents = _deps(bead, "parent-child")
    return next(iter(parents)) if len(parents) == 1 else None


def _should_close_step(bead, parent_status, live, gated=frozenset()):
    """Is this step bead an orphan left behind by a CLOSED molecule? -> (bool, why)

    ga-mpnhh. When a molecule closes, its still-open steps are not closed with it.
    They survive as type=step / status=open / no assignee — indistinguishable from
    available work, and their BODY is executable instruction ("read bead X, branch,
    implement, gate-done"). A worker that claims one re-implements finished work and
    submits a DUPLICATE gate marker. Measured 2026-08-07: 13 such steps from 7 closed
    molecules were 100% of the WA rig's apparently-free pool.

    The orphan condition is structural, not temporal: a legitimately in-flight step
    has an OPEN parent molecule. No age heuristic is needed or wanted.

    Deliberately NARROWER than the molecule rule (_ORPHAN_TARGET_STATUSES, which also
    treats deferred/missing as orphan-eligible): for a STEP only `closed` qualifies.
    A DEFERRED molecule is frozen, not finished — closing its steps would destroy a
    molecule that is meant to resume, which is the ga-yg585 failure (repairing without
    distinguishing 'lost' from 'legitimately in transition' breaks working things).
    An UNRESOLVED parent is the third state and always KEEPs.
    """
    bid = bead.get("id") or ""
    if (bead.get("status") or "").lower() != "open":
        return False, "não está open (in_progress é trabalho de alguém, não armadilha)"
    asg = bead.get("assignee") or ""
    if asg:
        return False, "tem assignee (%s)%s" % (asg, " — sessão viva" if asg in live else "")
    if bid in gated:
        return False, "referenciado por um quality-gate-marker aberto"
    if _ACTIVE_LABELS & set(bead.get("labels") or []):
        return False, "carrega label de trabalho rastreado"
    if parent_status is None or parent_status == _TARGET_MISSING:
        # O terceiro estado: "não consegui saber" NUNCA pode produzir o mesmo
        # resultado que "sei que a mãe fechou". Sob dúvida, inerte.
        return False, "status da molecule-pai indeterminado — KEEP (inerte sob dúvida)"
    if parent_status == "closed":
        return True, "molecule-pai CLOSED"
    return False, "molecule-pai ainda %s — step in-flight legítimo" % parent_status


def _order_step_orphans(orphans):
    """Blockers first. -> (ordered, unresolvable)

    `bd close` REFUSES a step still blocked by a sibling (do-work blocks drain), and
    that refusal is CORRECT — it is exactly the guard that stops a step whose
    dependency is genuinely alive from being closed. So this orders around the guard
    instead of pushing --force through it, which would also trample the real case.

    `orphans` is [(store, bead)]. Emits layers whose blocking deps within THIS sweep
    are already emitted. Anything still unemitted when a layer comes up empty (a
    cycle) is returned as `unresolvable` and left alone — never forced.
    """
    by_id = {b.get("id"): (store, b) for store, b in orphans if b.get("id")}
    pending = set(by_id)
    ordered, emitted = [], set()
    while pending:
        layer = sorted(
            bid for bid in pending
            if not ((_deps(by_id[bid][1], "blocks") & set(by_id)) - emitted)
        )
        if not layer:
            break
        ordered.extend(by_id[bid] for bid in layer)
        emitted.update(layer)
        pending -= set(layer)
    return ordered, [by_id[bid] for bid in sorted(pending)]


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

    # Collect sling-stub parent references (pure, no I/O) so their statuses can be
    # resolved in one batched call per store, mirroring the molecule-target resolution
    # below. ga-mf0gb: a stub's parent is assumed to live in the SAME store as the stub
    # itself — sling stubs carry no rig_name-equivalent metadata, so there's no cross-store
    # signal to resolve against (unlike molecules' gc.var.rig_name); skip the round trip
    # entirely when this sweep has no sling stubs at all.
    sling_parent_refs = []  # (store, parent_id)
    for store, beads in store_beads.items():
        for b in beads:
            if not isinstance(b, dict):
                continue
            parent = _is_sling(b)
            if parent:
                sling_parent_refs.append((store, parent))

    parent_statuses = {}
    if sling_parent_refs:
        parent_targets_by_store = {}
        for store, parent in sling_parent_refs:
            parent_targets_by_store.setdefault(store, set()).add(parent)
        parent_statuses = _target_statuses(parent_targets_by_store)

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

    # ── ga-mpnhh: steps órfãos de molecule FECHADA ────────────────────────────
    # Este janitor é quem fecha as molecules órfãs — e até aqui deixava os steps
    # delas para trás, abertos e sem assignee, isto é, indistinguíveis de trabalho
    # disponível. Limpar atrás de si é a outra ponta do mesmo ciclo, e sai de graça
    # aqui: o sweep já enumerou todo store e todo bead aberto. Um poller NOVO teria
    # custo de poll próprio, e foi exatamente isso que já derrubou o `bd` da cidade
    # (ga-y0g5x, 4 instâncias empilhadas).
    #
    # O pai de um step vive SEMPRE no mesmo store que o step (engine cria os dois
    # juntos) — diferente do alvo de uma molecule, que carrega gc.var.rig_name
    # justamente por poder ser cross-store. Logo não há resolução de rig aqui.
    #
    # LIMITE CONHECIDO (não é descuido, é escolha): os status dos pais são lidos no
    # INÍCIO do sweep. Uma molecule que ESTE mesmo sweep fechar mais abaixo ainda
    # aparece como aberta aqui, então os steps dela só são varridos no sweep
    # SEGUINTE. Converge sozinho, e a janela passa a ser um intervalo de sweep
    # contra os 12–24 dias medidos. Re-resolver depois do laço principal daria
    # limpeza no mesmo sweep ao custo de mais uma rodada de bd show por ciclo —
    # trocar isso é uma mudança consciente, não um bug a "consertar" por reflexo.
    step_refs = []  # (store, bead, parent_id)
    for store, beads in store_beads.items():
        for b in beads:
            if not isinstance(b, dict):
                continue
            pid = _step_parent(b)
            if pid:
                step_refs.append((store, b, pid))

    step_parent_statuses = {}
    if step_refs:
        by_store = {}
        for store, _b, pid in step_refs:
            by_store.setdefault(store, set()).add(pid)
        step_parent_statuses = _target_statuses(by_store)

    closed = 0
    step_orphans = []
    for store, b, pid in step_refs:
        do_close, why = _should_close_step(b, step_parent_statuses.get(pid), live, gated)
        if do_close:
            step_orphans.append((store, b))
        else:
            _log("  KEEP %s/%s (step): %s" % (os.path.basename(store), b.get("id", "?"), why))

    if step_orphans:
        ordered, unresolvable = _order_step_orphans(step_orphans)
        for store, b in unresolvable:
            _log("  KEEP %s/%s (step): ciclo de dependência entre órfãos — não forçado"
                 % (os.path.basename(store), b.get("id", "?")))
        for store, b in ordered:
            reason = (
                "Orphan step cleanup (sling-task-janitor, ga-mpnhh): a molecule-pai deste "
                "step está CLOSED, e o step ficou aberto e sem assignee — indistinguível de "
                "trabalho disponível no pool. O corpo de um step é instrução executável, "
                "então quem o claimasse re-implementaria trabalho já pronto e submeteria um "
                "gate marker DUPLICADO. Fechado na ordem de dependência (bloqueadores "
                "primeiro), sem --force: o guard que recusa fechar step bloqueado está certo "
                "e é preservado."
            )
            closed, hit_cap = _try_close(store, b.get("id", "?"), "molecule-pai CLOSED", reason, closed)
            if hit_cap:
                return closed


    for store, beads in store_beads.items():
        for b in beads:
            if not isinstance(b, dict):
                continue
            bid = b.get("id", "?")

            parent = _is_sling(b)
            if parent:
                do_close, why = _should_close(b, inflight, live, now, gated, parent_statuses)
                if not do_close:
                    _log("  KEEP %s/%s: %s" % (os.path.basename(store), bid, why))
                    continue
                labels_b = set(b.get("labels") or [])
                asg_b = b.get("assignee") or ""
                if _is_refused(labels_b):
                    reason = ("Orphan sling-task cleanup (sling-task-janitor, ga-0jcit): stub for "
                              "'%s' carries an explicit pool:refused:* label — a terminal decision "
                              "by its assignee. Dog-pool sessions are long-lived, so the assignee "
                              "remaining live is not evidence this stub is still active work. "
                              "Closed; the parent's own state drives any future dispatch." % parent)
                elif parent_statuses.get(parent) == "closed" and asg_b and asg_b in live:
                    reason = ("Orphan sling-task cleanup (sling-task-janitor, ga-mf0gb): stub for "
                              "'%s' is CONFIRMED CLOSED at the parent — assignee '%s' is still live, "
                              "but a dog-pool session remaining live after finishing this task is not "
                              "evidence the stub itself is still active work. Closed; the parent's own "
                              "state drives any future dispatch." % (parent, asg_b))
                else:
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
    global _target_status_fn, _rig_name_map_fn, BD_BIN
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

    print("Scenario C2: pool:refused:* stub with a LIVE assignee → CLOSE (ga-0jcit: refuse is a "
          "terminal decision; dog-pool sessions are long-lived, so liveness alone must not override "
          "an explicit refuse)")
    c, why = _should_close(mk("t3b", "fix bug ga-y", labels=["pool:refused:needs-human-investigation"],
                              assignee="dog-galnfou"), set(), {"dog-galnfou"}, NOW)
    _ok("C2: closes a refused stub even though its assignee is still live") if c else _bad("C2: did not close refused stub", why)

    print("Scenario C3: pool:refused:* stub but parent IS story:in-flight → still KEEP (refuse "
          "does not override an active parent build)")
    c, why = _should_close(mk("t3c", "fix bug ga-z", labels=["pool:refused:needs-human-investigation"],
                              assignee="dog-galnfou"), {"ga-z"}, {"dog-galnfou"}, NOW)
    _bad("C3: wrongly closed while parent is in-flight", why) if c else _ok("C3: keeps refused stub whose parent is actively being built elsewhere")

    print("Scenario C4: pool:refused:* stub but too fresh → still KEEP (refuse does not override "
          "the anti-race age guard)")
    c, why = _should_close(mk("t3d", "fix bug ga-w", labels=["pool:refused:needs-human-investigation"],
                              assignee="dog-galnfou", updated=FRESH), set(), {"dog-galnfou"}, NOW)
    _bad("C4: wrongly closed a fresh refused stub", why) if c else _ok("C4: keeps fresh refused stub (age guard still applies)")

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

    print("Scenario V: _target_statuses() REAL subprocess path parses stderr for confirmed-missing ids (ga-xwza2 gate-attempt-1 regression guard — Scenarios L/M only exercise _should_close_molecule() via the _target_status_fn seam, which bypasses this exact subprocess/stderr code; this is the scenario that would have caught bd-list-cached.sh swallowing stderr)")
    import tempfile
    stub_dir = tempfile.mkdtemp()
    stub_bd = os.path.join(stub_dir, "fake-bd")
    stub_src = r'''#!/usr/bin/env python3
import sys, json
args = sys.argv[1:]
i = 0
if args and args[i] == "-C":
    i += 2
assert args[i] == "show"
i += 1
ids = []
while i < len(args) and args[i] != "--json":
    ids.append(args[i])
    i += 1
found = []
for id_ in ids:
    if id_ == "ga-real1":
        found.append({"id": id_, "status": "open"})
    else:
        sys.stderr.write('Error fetching %s: no issue found matching "%s"\n' % (id_, id_))
print(json.dumps(found))
'''
    with open(stub_bd, "w") as f:
        f.write(stub_src)
    os.chmod(stub_bd, 0o755)
    _target_status_fn = None
    saved_bd_bin = BD_BIN
    BD_BIN = stub_bd
    try:
        resultV = _target_statuses({"FAKESTORE": {"ga-real1", "ga-ghost1"}})
    finally:
        BD_BIN = saved_bd_bin
        import shutil
        shutil.rmtree(stub_dir, ignore_errors=True)
    if resultV.get("ga-real1") == "open" and resultV.get("ga-ghost1") == _TARGET_MISSING:
        _ok("V: real _target_statuses() resolves found status AND confirmed-missing via stderr, unshimmed")
    else:
        _bad("V: _target_statuses() real subprocess path broken", "result=%s" % resultV)

    print("Scenario W: parent CONFIRMED CLOSED, non-refused stub with a LIVE assignee → CLOSE "
          "(ga-mf0gb: parent-closed is equally terminal as an explicit refuse — a dog-pool "
          "session remaining live after finishing this task is not evidence the stub itself "
          "is still active work)")
    c, why = _should_close(mk("t3e", "fix bug ga-done", assignee="dog-galnfou"), set(), {"dog-galnfou"}, NOW,
                            parent_status_by_id={"ga-done": "closed"})
    _ok("W: closes a non-refused, live-assignee stub once its parent is confirmed closed") if c else _bad("W: did not close parent-closed stub", why)

    print("Scenario X: parent status resolved but explicitly OPEN, live assignee → KEEP "
          "(unchanged — an explicit non-closed status, not just absence of info, must not "
          "trigger the override)")
    c, why = _should_close(mk("t3f", "fix bug ga-active", assignee="dog-galnfou"), set(), {"dog-galnfou"}, NOW,
                            parent_status_by_id={"ga-active": "open"})
    _bad("X: wrongly closed while parent is confirmed open", why) if c else _ok("X: keeps live-assignee stub whose parent is confirmed open")

    print("Scenario Y: parent status UNRESOLVED (lookup failed/ambiguous, absent from the "
          "resolved map), live assignee → KEEP (fail-toward-KEEP: absence of a resolved "
          "status is not proof of closure)")
    c, why = _should_close(mk("t3g", "fix bug ga-unknown", assignee="dog-galnfou"), set(), {"dog-galnfou"}, NOW,
                            parent_status_by_id={})
    _bad("Y: wrongly closed on an unresolved parent status", why) if c else _ok("Y: keeps live-assignee stub whose parent status could not be resolved")

    print("Scenario Z: run_cycle end-to-end closes a live-assignee sling stub once its parent "
          "resolves as CONFIRMED CLOSED (ga-mf0gb: the actual reported shape — a dog-pool "
          "session stays live after finishing the parent bug, e.g. ga-mx837/dog-gaagsrv/"
          "ga-lfj05 — the stub must still self-close)")
    MAX_PER_SWEEP = 10
    live_stub = mk("mx1", "fix bug ga-parentdone", assignee="dog-poolworker-LIVE")
    closed_idsZ = []
    _rigs_fn = lambda: ["HQ"]
    _bd_list_open_fn = lambda store: [live_stub]   # closed parent is NOT part of the open listing
    _sessions_fn = lambda: {"dog-poolworker-LIVE"}
    _bd_close_fn = lambda store, bid, reason: (closed_idsZ.append(bid) or True)
    _do_notify_fn = lambda m, p: None
    _target_status_fn = lambda targets_by_store: {"ga-parentdone": "closed"}
    n = run_cycle(NOW)
    if closed_idsZ == ["mx1"]:
        _ok("Z: closed the live-assignee stub end-to-end once its parent resolved as confirmed-closed")
    else:
        _bad("Z: run_cycle did not close the parent-closed live-assignee stub", "closed=%s" % closed_idsZ)
    _target_status_fn = None

    # ── ga-mpnhh: steps órfãos de molecule fechada ────────────────────────────
    def mkstep(bid, parent, assignee="", status="open", blocks=(), show_spelling=False):
        """Step bead. `show_spelling` usa as chaves do `bd show` (dependency_type/id);
        o default usa as do `bd list` (type/depends_on_id) — as DUAS existem no ar."""
        def edge(target, kind):
            if show_spelling:
                return {"id": target, "dependency_type": kind}
            return {"issue_id": bid, "depends_on_id": target, "type": kind}
        deps = [edge(parent, "parent-child")] + [edge(b, "blocks") for b in blocks]
        return {"id": bid, "title": "do-work", "issue_type": "step", "labels": [],
                "assignee": assignee, "status": status, "updated_at": OLD,
                "metadata": {"gc.step_ref": "mol-do-work.do-work"}, "dependencies": deps}

    print("Scenario AA: step aberto e sem assignee cuja molecule-pai está CLOSED → CLOSE "
          "(ga-mpnhh: 13 desses eram 100% do pool 'disponível' do rig WA)")
    c, why = _should_close_step(mkstep("s1", "mol1"), "closed", set())
    _ok("AA: fecha o step órfão") if c else _bad("AA: não fechou o órfão", why)

    print("Scenario AB: molecule-pai ABERTA → KEEP (step in-flight legítimo)")
    c, why = _should_close_step(mkstep("s2", "mol2"), "open", set())
    _bad("AB: fechou step de molecule viva", why) if c else _ok("AB: mantém step de molecule aberta")

    print("Scenario AC: status da molecule-pai NÃO RESOLVIDO → KEEP (terceiro estado: "
          "'não consegui saber' não pode produzir o mesmo resultado que 'sei que fechou')")
    for unknown in (None, _TARGET_MISSING):
        c, why = _should_close_step(mkstep("s3", "mol3"), unknown, set())
        _bad("AC: fechou com pai indeterminado (%r)" % unknown, why) if c else \
            _ok("AC: mantém step com pai indeterminado (%r)" % unknown)

    print("Scenario AD: molecule-pai DEFERRED → KEEP. Deliberadamente MAIS ESTRITO que a regra "
          "de molecule (_ORPHAN_TARGET_STATUSES aceita deferred/missing): molecule congelada não "
          "é molecule terminada, e fechar os steps dela destrói uma molecule feita pra retomar "
          "(família ga-yg585)")
    c, why = _should_close_step(mkstep("s4", "mol4"), "deferred", set())
    _bad("AD: fechou steps de uma molecule só congelada", why) if c else _ok("AD: mantém step de molecule deferred")

    print("Scenario AE: step COM assignee → KEEP (trabalho de alguém, não armadilha)")
    c, why = _should_close_step(mkstep("s5", "mol5", assignee="dog-live"), "closed", {"dog-live"})
    _bad("AE: fechou step assignado", why) if c else _ok("AE: mantém step com assignee")

    print("Scenario AE2: step in_progress sem assignee → KEEP (só 'open' é a superfície claimável)")
    c, why = _should_close_step(mkstep("s5b", "mol5b", status="in_progress"), "closed", set())
    _bad("AE2: fechou step in_progress", why) if c else _ok("AE2: mantém step in_progress")

    print("Scenario AF: as DUAS grafias de aresta são lidas (bd list usa type/depends_on_id; "
          "bd show usa dependency_type/id) — ler só uma devolve 'sem pai', que é a resposta KEEP, "
          "então o bug se esconderia como inação")
    for spell in (False, True):
        p = _step_parent(mkstep("s6", "molX", show_spelling=spell))
        _ok("AF: acha o pai na grafia %s" % ("show" if spell else "list")) if p == "molX" else \
            _bad("AF: não achou o pai na grafia %s" % ("show" if spell else "list"), repr(p))

    print("Scenario AF2: DOIS pais → KEEP. Achado auditando o próprio diff: a 1ª versão fazia "
          "sorted(parents)[0] e escolhia um pai por sorteio alfabético — com um pai fechado e "
          "outro aberto, o step viraria órfão por acaso e trabalho vivo seria fechado junto")
    two = mkstep("s7", "molA")
    two["dependencies"].append({"issue_id": "s7", "depends_on_id": "molB", "type": "parent-child"})
    p = _step_parent(two)
    _ok("AF2: pai ambíguo devolve None (KEEP)") if p is None else \
        _bad("AF2: escolheu um pai arbitrário", repr(p))

    print("Scenario AG: ordem de dependência — drain é bloqueado por do-work, então do-work fecha "
          "PRIMEIRO. `bd close` recusa step bloqueado, e essa recusa está CERTA: ordenar em volta "
          "dela, nunca --force (que atropelaria também o caso real)")
    dowork = mkstep("sd1", "mol6")
    drain = mkstep("sd2", "mol6", blocks=("sd1",))
    ordered, unresolvable = _order_step_orphans([("HQ", drain), ("HQ", dowork)])
    seq = [b.get("id") for _s, b in ordered]
    _ok("AG: fecha do-work antes do drain (%s)" % seq) if seq == ["sd1", "sd2"] and not unresolvable else \
        _bad("AG: ordem errada", "seq=%s unresolvable=%s" % (seq, [b.get('id') for _s, b in unresolvable]))

    print("Scenario AH: ciclo entre órfãos → nenhum é forçado (devolvidos como unresolvable)")
    c1 = mkstep("sc1", "mol7", blocks=("sc2",))
    c2 = mkstep("sc2", "mol7", blocks=("sc1",))
    ordered, unresolvable = _order_step_orphans([("HQ", c1), ("HQ", c2)])
    _ok("AH: ciclo não é forçado") if not ordered and len(unresolvable) == 2 else \
        _bad("AH: ciclo não tratado", "ordered=%s" % [b.get('id') for _s, b in ordered])

    print("Scenario AI: run_cycle END-TO-END fecha os dois steps órfãos na ordem certa. É o cenário "
          "que reprova contra o HEAD anterior — lá o run_cycle não fechava step nenhum")
    closed_idsAI = []
    _rigs_fn = lambda: ["HQ"]
    _bd_list_open_fn = lambda store: [drain, dowork]   # molecule fechada NÃO aparece no listing de abertos
    _sessions_fn = lambda: set()
    _bd_close_fn = lambda store, bid, reason: (closed_idsAI.append(bid) or True)
    _do_notify_fn = lambda m, p: None
    _target_status_fn = lambda targets_by_store: {"mol6": "closed"}
    run_cycle(NOW)
    if closed_idsAI == ["sd1", "sd2"]:
        _ok("AI: run_cycle fechou do-work e depois drain")
    else:
        _bad("AI: run_cycle não limpou os steps órfãos", "closed=%s" % closed_idsAI)
    _target_status_fn = None

    print("Scenario AJ: run_cycle NÃO toca step cuja molecule-pai segue ABERTA (guarda contra "
          "reintroduzir a falha oposta, ga-yg585: reparar sem distinguir 'perdido' de 'em "
          "transição legítima' quebra coisa boa)")
    closed_idsAJ = []
    live_step = mkstep("sl1", "mol8")
    _bd_list_open_fn = lambda store: [live_step]
    _bd_close_fn = lambda store, bid, reason: (closed_idsAJ.append(bid) or True)
    _target_status_fn = lambda targets_by_store: {"mol8": "open"}
    run_cycle(NOW)
    _ok("AJ: não tocou step de molecule aberta") if closed_idsAJ == [] else \
        _bad("AJ: fechou trabalho vivo", "closed=%s" % closed_idsAJ)
    _target_status_fn = None

    print("\n[sling-janitor selftest] %d passed, %d failed" % (ok[0], bad[0]))
    sys.exit(1 if bad[0] else 0)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        main()
