#!/usr/bin/env python3
"""
sling-task-janitor.py — close orphaned dispatch sling-task stubs.

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

CADENCE: MAX_PER_SWEEP=10 by default (orphans are inert; a higher cap clears backlog fast).
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

# ── test seams (monkeypatched in --selftest) ───────────────────────────────────
_bd_list_open_fn = None   # (store) -> list[dict]
_bd_close_fn = None       # (store, bead_id, reason) -> bool
_sessions_fn = None       # () -> set[str] of live session identifiers
_rigs_fn = None           # () -> list[str] store paths
_do_notify_fn = None      # (msg, prio) -> None


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


def _list_open(store):
    if _bd_list_open_fn is not None:
        return _bd_list_open_fn(store)
    r = _sh([BD_BIN, "-C", store, "list", "--json", "--status", "open,in_progress", "-n", "0"],
            timeout=BD_TIMEOUT)
    if r is None or r.returncode != 0:
        _log("WARN: bd list failed in %s (rc=%s)" % (os.path.basename(store), r.returncode if r else "err"))
        return None
    return _parse_bd_json(r.stdout)


def _live_sessions():
    if _sessions_fn is not None:
        return _sessions_fn()
    r = _sh([GC_BIN, "--city", CITY, "session", "list", "--json"], timeout=BD_TIMEOUT)
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


def _should_close(bead, parent_inflight_ids, live, now):
    """Return (close: bool, reason_or_skip: str). Fail-toward-KEEP."""
    bid = bead.get("id", "?")
    parent = _is_sling(bead)
    if not parent:
        return False, "not-a-sling-task"
    labels = set(bead.get("labels") or [])
    if labels & _ACTIVE_LABELS:
        return False, "stub carries an active lifecycle label (tracked work)"
    asg = bead.get("assignee") or ""
    if asg and asg in live:
        return False, "stub assignee '%s' is a LIVE session (active build)" % asg
    if parent in parent_inflight_ids:
        return False, "parent %s is story:in-flight (active build)" % parent
    age = _age_min(bead, now)
    if age < MIN_AGE_MIN:
        return False, "too fresh (age=%.0fmin < %d) — never race a just-minted dispatch" % (age, MIN_AGE_MIN)
    return True, ("orphan: parent %s NOT in active build, no live assignee, age=%.0fmin" % (parent, age))


def run_cycle(now):
    """One sweep across all stores. Returns count closed."""
    stores = _stores()
    live = _live_sessions()
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

    closed = 0
    for store, beads in store_beads.items():
        for b in beads:
            if not isinstance(b, dict):
                continue
            do_close, why = _should_close(b, inflight, live, now)
            bid = b.get("id", "?")
            if not do_close:
                if _is_sling(b):
                    _log("  KEEP %s/%s: %s" % (os.path.basename(store), bid, why))
                continue
            if closed >= MAX_PER_SWEEP:
                _log("  (MAX_PER_SWEEP=%d reached — deferring remaining orphans to next sweep)" % MAX_PER_SWEEP)
                return closed
            parent = _is_sling(b)
            reason = ("Orphan sling-task cleanup (sling-task-janitor): ctx:thin dispatch stub for "
                      "'%s' whose parent is NOT in active build and which has no live assignee. "
                      "Stale orphan polluting Triagem — closed. The parent's own state drives any "
                      "future dispatch; this stub is not needed." % parent)
            if _close(store, bid, reason):
                closed += 1
                _log("  CLOSED %s/%s (%s)" % (os.path.basename(store), bid, why))
            else:
                _log("  WARN: failed to close %s/%s (non-fatal; retry next sweep)" % (os.path.basename(store), bid))
    return closed


def main():
    if not ENABLED:
        _log("SLING_JANITOR_ENABLED=0 → no-op")
        return
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    _log("=== sweep start (DRY_RUN=%s, MAX_PER_SWEEP=%d, MIN_AGE_MIN=%d) ===" % (DRY_RUN, MAX_PER_SWEEP, MIN_AGE_MIN))
    n = run_cycle(now)
    _log("=== sweep done: %d orphan sling-task(s) closed ===" % n)
    if n >= 5 and not DRY_RUN:
        _notify("Closed %d orphan dispatch sling-tasks (Triagem cleanup)" % n, prio=2)


# ── selftest ────────────────────────────────────────────────────────────────────
def _selftest():
    global _bd_list_open_fn, _bd_close_fn, _sessions_fn, _rigs_fn, _do_notify_fn, MAX_PER_SWEEP
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

    print("\n[sling-janitor selftest] %d passed, %d failed" % (ok[0], bad[0]))
    sys.exit(1 if bad[0] else 0)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        main()
