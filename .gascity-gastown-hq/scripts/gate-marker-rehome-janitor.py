#!/usr/bin/env python3
"""
gate-marker-rehome-janitor.py — re-home orphaned quality-gate markers rig → HQ.

ROOT (ga-pnugy): the quality-gate dispatcher + guard scan ONLY the HQ store
(bd -C "$GC_CITY") for type:quality-gate-marker beads. But /gate-done creates the
marker with `bd -C "$GC_CITY_PATH"`, and for a SELF-REPO rig (whatsapp_automation,
marketing, gastown) the worker's session GC_CITY_PATH is the RIG, not HQ — so the
marker lands in the rig store where the gate NEVER sees it. The built branch is
ready-for-gate but is never reviewed/merged → silent stall. (Container rigs like
property_scrapers were unaffected: their workers' GC_CITY_PATH is HQ.)

Fixing /gate-done is a deployment nightmare (~10 .claude/commands/gate-done.md copies
across crew worktrees). This janitor is the robust, isolated, low-risk fix: it catches
an orphaned marker WHEREVER it lands and re-homes it to HQ, so the gate sees it. It
does NOT touch the fragile gate/guard processing loop.

OPERATION per sweep (MAX_PER_SWEEP cap): scan every NON-HQ rig store for an OPEN
type:quality-gate-marker with gate-status:ready|queued that is NOT already re-homed.
Recreate it in HQ (verbatim title/description + labels, gate-status:ready so the guard
re-validates from scratch), VERIFY the HQ copy exists, stamp the rig original
gc.rehomed_to=<hq-id> (idempotency anchor), then CLOSE the rig original. The source
STORY bead stays in the rig — the dispatcher already resolves it cross-store (BEAD_CITY
probe), exactly as it does for container-rig markers.

SAFETY: the rig marker is closed ONLY after the HQ copy is created AND verified. Any
failure leaves the rig marker untouched. gc.rehomed_to prevents double-recreation.
KILL-SWITCH: GATE_MARKER_REHOME_ENABLED=0 → no-op. DRY_RUN: GATE_MARKER_REHOME_DRY_RUN=1.
"""
import json
import os
import subprocess
import sys

CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
NOTIFY_BIN = os.environ.get("NOTIFY_BIN", "/Users/athos/.local/bin/notify")
GC_BIN = os.environ.get("GC_BIN", "gc")
BD_BIN = os.environ.get("BD_BIN", "bd")

ENABLED = os.environ.get("GATE_MARKER_REHOME_ENABLED", "1") == "1"
DRY_RUN = os.environ.get("GATE_MARKER_REHOME_DRY_RUN", "0") == "1"
MAX_PER_SWEEP = int(os.environ.get("GATE_MARKER_REHOME_MAX_PER_SWEEP", "5"))
BD_TIMEOUT = int(os.environ.get("GATE_MARKER_REHOME_BD_TIMEOUT", "30"))

_MARKER_TYPE_LABEL = "type:quality-gate-marker"
# Only re-home markers the gate would ACT on. error/needs-rebase/needs-human are parked
# (a human/author must move them) — re-homing wouldn't unblock them, so leave them be.
_ACTIONABLE_STATUSES = ("gate-status:ready", "gate-status:queued")

# ── test seams (monkeypatched in --selftest) ───────────────────────────────────
_rig_stores_fn = None    # () -> list[(name, path)] non-HQ stores
_list_markers_fn = None   # (store) -> list[dict]
_create_hq_fn = None      # (title, desc, labels) -> new_id|None
_verify_hq_fn = None      # (new_id) -> bool
_stamp_fn = None          # (store, mid, key, val) -> bool
_close_fn = None          # (store, mid, reason) -> bool
_do_notify_fn = None      # (msg, prio) -> None


def _sh(args, timeout=20):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        _log("WARN: subprocess failed: %r (%r)" % (args[:3], e))
        return None


def _log(msg):
    print("[gate-marker-rehome] %s" % msg, flush=True)


def _notify(msg, prio=2):
    if _do_notify_fn is not None:
        _do_notify_fn(msg, prio); return
    if DRY_RUN:
        _log("DRY_RUN: would notify: %s" % msg); return
    _sh([NOTIFY_BIN, "-t", "Gate marker re-home", "-p", str(prio), msg], timeout=10)


def _parse_json(raw):
    if not raw:
        return []
    try:
        d = json.loads(raw)
        return d if isinstance(d, list) else []
    except Exception:
        try:
            i = raw.rstrip().rfind("]")
            return json.loads(raw[: i + 1]) if i > 0 else []
        except Exception:
            return []


def _rig_stores():
    """Non-HQ rig store paths (name, path). The gate's HQ store is excluded — a marker
    already in HQ is found by the gate, not orphaned."""
    if _rig_stores_fn is not None:
        return _rig_stores_fn()
    r = _sh([GC_BIN, "--city", CITY, "rig", "list", "--json"], timeout=BD_TIMEOUT)
    out = []
    if r and r.returncode == 0:
        try:
            for rig in (json.loads(r.stdout).get("rigs") or []):
                if rig.get("hq") is True:
                    continue
                p = rig.get("path")
                if p and p != CITY and os.path.isdir(p):
                    out.append((rig.get("name") or os.path.basename(p), p))
        except Exception as e:
            _log("WARN: gc rig list parse: %r" % e)
    return out


def _list_orphan_markers(store):
    if _list_markers_fn is not None:
        return _list_markers_fn(store)
    r = _sh([BD_BIN, "-C", store, "list", "--json", "-l", _MARKER_TYPE_LABEL,
             "--status", "open,in_progress", "-n", "0"], timeout=BD_TIMEOUT)
    if r is None or r.returncode != 0:
        return None
    return _parse_json(r.stdout)


def _create_in_hq(title, desc, labels):
    if _create_hq_fn is not None:
        return _create_hq_fn(title, desc, labels)
    args = [BD_BIN, "-C", CITY, "create", title, "-t", "chore", "--ephemeral", "-d", desc]
    for l in labels:
        args += ["-l", l]
    args += ["--json"]
    r = _sh(args, timeout=BD_TIMEOUT)
    if r is None or r.returncode != 0:
        return None
    try:
        return (json.loads(r.stdout) or {}).get("id")
    except Exception:
        return None


def _verify_hq(new_id):
    if _verify_hq_fn is not None:
        return _verify_hq_fn(new_id)
    r = _sh([BD_BIN, "-C", CITY, "show", new_id, "--json"], timeout=BD_TIMEOUT)
    return bool(r and r.returncode == 0 and (new_id in (r.stdout or "")))


def _stamp(store, mid, key, val):
    if _stamp_fn is not None:
        return _stamp_fn(store, mid, key, val)
    r = _sh([BD_BIN, "-C", store, "update", mid, "--set-metadata", "%s=%s" % (key, val), "-q"],
            timeout=BD_TIMEOUT)
    return bool(r and r.returncode == 0)


def _close(store, mid, reason):
    if _close_fn is not None:
        return _close_fn(store, mid, reason)
    r = _sh([BD_BIN, "-C", store, "close", mid, "-r", reason], timeout=BD_TIMEOUT)
    return bool(r and r.returncode == 0)


def _labels_of(m):
    return [str(l) for l in (m.get("labels") or [])]


def _is_orphan(m):
    """A marker bead worth re-homing: open, actionable status, not already re-homed."""
    if (m.get("status") or "open") == "closed":
        return False
    md = m.get("metadata") or {}
    if md.get("gc.rehomed_to"):
        return False
    lbls = _labels_of(m)
    if _MARKER_TYPE_LABEL not in lbls:
        return False
    return any(s in lbls for s in _ACTIONABLE_STATUSES)


def _rehome_one(store, m):
    """Recreate the marker in HQ (gate-status:ready), verify, stamp + close the rig one.
    Returns True on success."""
    mid = m.get("id", "?")
    title = m.get("title") or ("ready-for-gate: %s" % mid)
    desc = m.get("description") or ""
    # Rebuild labels: keep type + branch/source-bead/bead-rig; force gate-status:ready
    # (drop the rig's queued/claimed/dispatching so the HQ guard re-validates cleanly).
    keep = [l for l in _labels_of(m)
            if l == _MARKER_TYPE_LABEL or l.startswith(("branch:", "source-bead:", "bead-rig:"))]
    labels = keep + ["gate-status:ready"]
    if DRY_RUN:
        _log("DRY_RUN: would recreate %s in HQ (labels=%s) + close rig copy in %s"
             % (mid, labels, os.path.basename(store)))
        return True
    new_id = _create_in_hq(title, desc, labels)
    if not new_id:
        _log("WARN: failed to create HQ copy of %s — leaving rig marker untouched" % mid)
        return False
    if not _verify_hq(new_id):
        _log("WARN: HQ copy %s of %s did not verify — leaving rig marker untouched" % (new_id, mid))
        return False
    _stamp(store, mid, "gc.rehomed_to", new_id)
    reason = ("ga-pnugy re-home: this quality-gate marker was created in the rig store "
              "(self-repo worker GC_CITY_PATH=rig), where the HQ-only gate scan never sees it. "
              "Re-homed to HQ as %s (gate-status:ready) so the gate processes it; source bead "
              "stays in the rig (dispatcher resolves it cross-store). Closing the orphan." % new_id)
    if not _close(store, mid, reason):
        _log("WARN: created HQ copy %s but failed to close rig %s (will retry; gc.rehomed_to "
             "stamp prevents double-recreate)" % (new_id, mid))
        return False
    _log("RE-HOMED %s (%s) → HQ %s; rig orphan closed" % (mid, os.path.basename(store), new_id))
    return True


def run_cycle():
    done = 0
    for name, store in _rig_stores():
        markers = _list_orphan_markers(store)
        if markers is None:
            _log("WARN: bd list markers failed in %s — skipping store" % name)
            continue
        for m in markers:
            if not isinstance(m, dict) or not _is_orphan(m):
                continue
            if done >= MAX_PER_SWEEP:
                _log("(MAX_PER_SWEEP=%d reached — deferring remaining orphans to next sweep)" % MAX_PER_SWEEP)
                return done
            if _rehome_one(store, m):
                done += 1
    return done


def main():
    if not ENABLED:
        _log("GATE_MARKER_REHOME_ENABLED=0 → no-op")
        return
    _log("=== sweep start (DRY_RUN=%s, MAX_PER_SWEEP=%d) ===" % (DRY_RUN, MAX_PER_SWEEP))
    n = run_cycle()
    _log("=== sweep done: %d orphaned gate marker(s) re-homed to HQ ===" % n)
    if n >= 1 and not DRY_RUN:
        _notify("Re-homed %d orphaned gate marker(s) rig→HQ (ga-pnugy: gate can now see them)" % n, prio=2)


# ── selftest ────────────────────────────────────────────────────────────────────
def _selftest():
    global _rig_stores_fn, _list_markers_fn, _create_hq_fn, _verify_hq_fn, _stamp_fn, _close_fn, _do_notify_fn, MAX_PER_SWEEP
    ok = [0]; bad = [0]
    def _ok(m): ok[0] += 1; print("  ok   " + m)
    def _bad(m, d=""): bad[0] += 1; print("  BAD  " + m + ((" :: " + d) if d else ""))

    def mk(mid, status="gate-status:ready", typ=_MARKER_TYPE_LABEL, rehomed=None, closed=False):
        labels = [typ, status, "branch:crew/wa-worker/%s" % mid, "source-bead:%s" % mid, "bead-rig:whatsapp_automation"]
        md = {}
        if rehomed:
            md["gc.rehomed_to"] = rehomed
        return {"id": mid, "title": "ready-for-gate: crew/wa-worker/%s" % mid,
                "description": "branch: crew/wa-worker/%s\nbead_id: %s\nrig: whatsapp_automation" % (mid, mid),
                "labels": labels, "status": "closed" if closed else "open", "metadata": md}

    print("Scenario A: _is_orphan classification")
    _ok("A: ready marker is orphan") if _is_orphan(mk("m1")) else _bad("A1")
    _ok("A: queued marker is orphan") if _is_orphan(mk("m2", "gate-status:queued")) else _bad("A2")
    _bad("A3 (needs-rebase should NOT be re-homed)") if _is_orphan(mk("m3", "gate-status:needs-rebase")) else _ok("A: needs-rebase parked → not re-homed")
    _bad("A4 (error should NOT)") if _is_orphan(mk("m4", "gate-status:error")) else _ok("A: error parked → not re-homed")
    _bad("A5 (already-rehomed should NOT)") if _is_orphan(mk("m5", rehomed="ga-xyz")) else _ok("A: already re-homed → skipped")
    _bad("A6 (closed should NOT)") if _is_orphan(mk("m6", closed=True)) else _ok("A: closed → skipped")
    _bad("A7 (non-marker should NOT)") if _is_orphan(mk("m7", typ="lane:small")) else _ok("A: non-marker → skipped")

    print("Scenario B: end-to-end re-home (create HQ → verify → stamp → close rig)")
    created = []; stamped = []; closed = []
    _rig_stores_fn = lambda: [("whatsapp_automation", "/WA")]
    _list_markers_fn = lambda store: [mk("wa-huo0d"), mk("wa-s4x9"), mk("wa-park", "gate-status:needs-rebase")]
    _create_hq_fn = lambda t, d, l: (created.append((t, tuple(l))) or ("hq-%d" % len(created)))
    _verify_hq_fn = lambda nid: True
    _stamp_fn = lambda s, mid, k, v: (stamped.append((mid, k, v)) or True)
    _close_fn = lambda s, mid, r: (closed.append(mid) or True)
    _do_notify_fn = lambda m, p: None
    n = run_cycle()
    if n == 2 and set(closed) == {"wa-huo0d", "wa-s4x9"}:
        _ok("B: re-homed the 2 ready markers, left the needs-rebase one parked")
    else:
        _bad("B: wrong", "n=%d closed=%s" % (n, closed))
    # labels forced to gate-status:ready, type + branch/source-bead/bead-rig preserved
    if created and ("gate-status:ready" in created[0][1]) \
            and (_MARKER_TYPE_LABEL in created[0][1]) \
            and any(x.startswith("source-bead:") for x in created[0][1]) \
            and not any(x == "gate-status:queued" for x in created[0][1]):
        _ok("B: HQ copy labels correct (type+branch+source-bead+ready; no stale status)")
    else:
        _bad("B: HQ copy labels wrong", str(created[:1]))
    if all(k == "gc.rehomed_to" for _, k, _ in stamped) and len(stamped) == 2:
        _ok("B: rig originals stamped gc.rehomed_to before close (idempotency)")
    else:
        _bad("B: stamp wrong", str(stamped))

    print("Scenario C: MAX_PER_SWEEP cap")
    MAX_PER_SWEEP = 1
    closed.clear(); created.clear()
    n = run_cycle()
    _ok("C: cap honored (1 re-homed, rest deferred)") if n == 1 else _bad("C", "n=%d" % n)

    print("\n[gate-marker-rehome selftest] %d passed, %d failed" % (ok[0], bad[0]))
    sys.exit(1 if bad[0] else 0)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        main()
