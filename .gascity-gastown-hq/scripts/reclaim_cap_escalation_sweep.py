#!/usr/bin/env python3
"""reclaim_cap_escalation_sweep.py — ga-yfpab defense-in-depth detector.

PROBLEM (ga-yfpab): inflight-reclaim-guard.py's reclaim_decision() checks
reclaim_count >= MAX_RECLAIMS using the PRE-increment count, so the reclaim
call that bumps a bead's count TO the cap is always dispatched as "reclaim",
never "escalate" — do_escalate() (which applies gate:needs-human) was
designed to fire on a LATER pass once the count is already at cap, but
do_reclaim() strips story:in-flight/pilot:dispatched and flips status to open
as part of every reclaim, which removes the bead from every candidate query
run_cycle() uses to find beads to re-evaluate. That later pass could
structurally never happen. gt-7bt1l and gt-5tr74 both reached
pilot:reclaim-count:3 + status=open + pilot:held with gate:needs-human never
applied — gt-7bt1l needed a manual Mayor re-admit 33h+ later.

PRIMARY FIX: do_reclaim() (in inflight-reclaim-guard.py) now escalates inline,
in the same call that crosses the cap, for the common (non-refusal) case.

THIS SCRIPT is the defense-in-depth backstop: it scans HQ + every rig store
for ANY bead that ends up with pilot:reclaim-count >= MAX_RECLAIMS but no
gate:needs-human (or :suffix variant), regardless of HOW it got that way —
the primary fix's own has_explicit_refusal carve-out, a future code path,
manual label editing via `bd label` directly, or a bug not yet discovered —
and escalates it. Per this codebase's own design law ("para auditar um
consumidor, EXECUTE o consumidor, nunca reimplementa" — see
inflight_reclaim_divergence.py's docstring), this imports and calls the REAL
do_escalate() from inflight-reclaim-guard.py rather than reimplementing its
label mutations.

Idempotent: do_escalate() adds gate:needs-human, which removes the bead from
this script's own candidate query on the next sweep — running this
repeatedly on an already-escalated bead is a safe no-op.

ga-wpdlg: a capped bead can carry a LIVE owner — e.g. wa-k9czz (P0,
reclaim_count=3) was in_progress with assignee digo-wa, a live pinned
session actively working the fix, when this sweep's dry-run would have
marked it WOULD-ESCALATE. Applying gate:needs-human mid-fix-loop can hold
up the owner's own resubmission. Before escalating, this script now skips
any candidate whose assignee resolves to a live/active session — the SAME
liveness notion inflight-reclaim-guard.py's run_cycle() uses to avoid
reclaiming a live owner's bead, reached the same way this script already
reaches do_escalate(): by calling the REAL functions (session_is_live /
pool_has_live_worker / concrete_adhoc_session_is_live), never
reimplementing the liveness check. A skipped bead is simply re-evaluated
on the next sweep — if the owner is gone by then, it escalates normally.

USO: python3 reclaim_cap_escalation_sweep.py [--dry-run]
     python3 reclaim_cap_escalation_sweep.py --selftest
"""
import importlib.util as _ilu
import json
import os
import subprocess
import sys
import time

_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))

_spec = _ilu.spec_from_file_location(
    "irg", os.path.join(_SCRIPTS_DIR, "inflight-reclaim-guard.py"))
if _spec is None or _spec.loader is None:  # pragma: no cover - defensive
    raise ImportError(f"cannot load guard module from {_SCRIPTS_DIR!r}")
irg = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(irg)


def _bead_has_live_owner(bead, sessions, now):
    """Return True if `bead`'s assignee resolves to a live/active session.

    ga-wpdlg: mirrors the exact routing inflight-reclaim-guard.py's
    run_cycle() uses (bare pool template -> pool_has_live_worker; concrete
    adhoc pool session -> concrete_adhoc_session_is_live; anything else ->
    session_is_live) — calling those REAL functions rather than
    reimplementing liveness, same design law this script already follows
    for do_escalate().

    sessions=None means `gc session list` failed this sweep — liveness is
    UNKNOWN, not "no one's home". Fail-safe: treat as live so this sweep
    never escalates over an owner it couldn't verify. A transient failure
    just defers to the next sweep, same as any other skipped candidate.
    """
    if sessions is None:
        return True
    assignee = bead.get("assignee") or ""
    if not assignee:
        return False
    if assignee in irg.EPHEMERAL_POOL_ASSIGNEES:
        return irg.pool_has_live_worker(assignee, sessions, now)
    if irg._is_ephemeral_pool_assignee(assignee):
        return irg.concrete_adhoc_session_is_live(assignee, sessions, now)
    return irg.session_is_live(assignee, sessions, now)


def find_capped_beads_missing_needs_human():
    """Scan HQ + every rig store for beads carrying pilot:reclaim-count >=
    MAX_RECLAIMS without gate:needs-human (or any :suffix variant). Status
    open OR in_progress — the whole point of this scan is that these beads
    have already lost the labels/status the guard's own candidate queries
    require, so this deliberately does NOT filter on story:in-flight or
    pilot:dispatched.

    Returns (candidates, ok) — candidates is a list of bead dicts (each
    tagged with rig_root for store-aware bd routing). ok=False if ANY
    store's discovery query failed this sweep — fail-VISIBLE (the caller
    reports a non-zero exit / warning), never a silent partial scan
    misreported as complete.

    ga-wpdlg: a bead that otherwise qualifies is still excluded if its
    assignee resolves to a live/active session (see _bead_has_live_owner) —
    escalating gate:needs-human onto a bead its live owner is actively
    working can hold up that owner's own fix-and-resubmit loop.
    """
    candidates = []
    ok = True
    stores = [(None, None)]  # HQ first: rig_root=None routes bd with no -C override

    _rig_stores = irg._list_rig_stores()
    if _rig_stores is None:
        print("WARN: gc rig list failed — scanning HQ only this sweep", file=sys.stderr, flush=True)
        ok = False
    else:
        stores += list(_rig_stores)

    sessions = irg.list_active_sessions()
    if sessions is None:
        print("WARN: gc session list failed — cannot verify live ownership "
              "this sweep; skipping escalation for every candidate found "
              "(fail-safe: never escalate over an owner of unknown liveness)",
              file=sys.stderr, flush=True)
        ok = False
    now = time.time()

    for rig_name, rig_path in stores:
        cmd = ["bd"] + (["-C", rig_path] if rig_path else []) + [
            "list", "--status", "open,in_progress", "--json", "--limit", "0"]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        except Exception as exc:
            print(f"WARN: bd list failed for store {rig_name or 'hq'}: {exc}",
                  file=sys.stderr, flush=True)
            ok = False
            continue
        if r.returncode != 0 or not r.stdout.strip():
            print(f"WARN: bd list rc={r.returncode} for store {rig_name or 'hq'} — "
                  f"skipping this sweep (fail-open, never confirmed-empty)",
                  file=sys.stderr, flush=True)
            ok = False
            continue
        try:
            data = json.loads(r.stdout)
        except Exception as exc:
            print(f"WARN: bd list JSON parse failed for store {rig_name or 'hq'}: {exc}",
                  file=sys.stderr, flush=True)
            ok = False
            continue
        if not isinstance(data, list):
            print(f"WARN: bd list returned non-list JSON for store {rig_name or 'hq'} — "
                  f"treating as a failed query, not a confirmed-empty store",
                  file=sys.stderr, flush=True)
            ok = False
            continue
        for b in data:
            labels = b.get("labels", []) or []
            count = irg.parse_reclaim_count(labels)
            if count < irg.MAX_RECLAIMS:
                continue
            if irg._has_needs_human_label(labels):
                continue
            if _bead_has_live_owner(b, sessions, now):
                continue
            b = dict(b)
            b["rig_root"] = rig_path
            candidates.append(b)

    return candidates, ok


def main():
    dry_run = "--dry-run" in sys.argv or os.environ.get("RECLAIM_CAP_SWEEP_DRY_RUN") == "1"
    candidates, ok = find_capped_beads_missing_needs_human()
    print(f"reclaim-cap-escalation-sweep: {len(candidates)} capped bead(s) missing "
          f"gate:needs-human (store scan {'complete' if ok else 'PARTIAL — see warnings above'})",
          flush=True)
    for b in candidates:
        bead_id = b.get("id", "")
        title = b.get("title", "")
        labels = b.get("labels", []) or []
        count = irg.parse_reclaim_count(labels)
        rig_root = b.get("rig_root")
        if dry_run:
            print(f"WOULD-ESCALATE {bead_id} (reclaim_count={count}) title={title!r}", flush=True)
            continue
        print(f"ESCALATING {bead_id} (reclaim_count={count}) title={title!r}", flush=True)
        irg.do_escalate(bead_id, title, count, 0.0, labels, rig_root=rig_root)
    return 0 if ok else 1


def _selftest():
    """Hermetic selftest — stubs subprocess.run, no live bd/gc calls."""
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

    _escalate_calls = []

    def _stub_do_escalate(bead_id, bead_title, reclaim_count, idle_min, labels, rig_root=None):
        _escalate_calls.append((bead_id, reclaim_count, rig_root))
        return []

    _orig_do_escalate = irg.do_escalate
    _orig_find = find_capped_beads_missing_needs_human
    _orig_list_rig_stores = irg._list_rig_stores
    _orig_list_active_sessions = irg.list_active_sessions

    _MAX = irg.MAX_RECLAIMS

    def _bead(id_, labels, rig_root=None):
        return {"id": id_, "title": f"title for {id_}", "labels": labels, "rig_root": rig_root}

    # CAND-1: capped, no gate:needs-human -> candidate, gets escalated.
    _b1 = _bead("ga-cap1", [f"pilot:reclaim-count:{_MAX}"])
    # CAND-2: capped, ALREADY gate:needs-human -> excluded (already handled).
    _b2 = _bead("ga-cap2", [f"pilot:reclaim-count:{_MAX}", "gate:needs-human"])
    # CAND-3: capped, gate:needs-human:technical variant -> excluded (prefix match).
    _b3 = _bead("ga-cap3", [f"pilot:reclaim-count:{_MAX}", "gate:needs-human:technical"])
    # CAND-4: below cap -> excluded regardless of needs-human.
    _b4 = _bead("ga-cap4", [f"pilot:reclaim-count:{_MAX - 1}"])
    # CAND-5: no reclaim-count label at all -> excluded (parse_reclaim_count -> 0).
    _b5 = _bead("ga-cap5", ["story:in-flight"])
    # CAND-6: capped in a non-HQ rig store -> candidate, rig_root propagated.
    _b6 = _bead("wa-cap6", [f"pilot:reclaim-count:{_MAX}"], rig_root="/fake/rig/whatsapp_automation")

    irg._list_rig_stores = lambda: [("whatsapp_automation", "/fake/rig/whatsapp_automation")]
    # No live owners in play for SWEEP-1..7/CAND-1..6 — none of those fixtures
    # carry an assignee, but stub this to a confirmed-empty (not None) session
    # list anyway so this block never depends on the "sessions fetch failed"
    # fail-safe path, which is tested explicitly further below (LIVE-4).
    irg.list_active_sessions = lambda: []

    def _stub_run(cmd, **kw):
        class _R:
            def __init__(self, rc=0, out="[]"):
                self.returncode = rc
                self.stdout = out
                self.stderr = ""
        if isinstance(cmd, (list, tuple)) and cmd[:2] == ["bd", "list"]:
            return _R(0, json.dumps([_b1, _b2, _b3, _b4, _b5]))
        if isinstance(cmd, (list, tuple)) and cmd[:2] == ["bd", "-C"] and cmd[3:5] == ["list", "--status"]:
            return _R(0, json.dumps([{k: v for k, v in _b6.items() if k != "rig_root"}]))
        return _R(0, "[]")

    _orig_subprocess_run = subprocess.run
    subprocess.run = _stub_run
    try:
        candidates, ok = find_capped_beads_missing_needs_human()
        cand_ids = sorted(c.get("id", "") for c in candidates)
        check("SWEEP-1: capped bead missing gate:needs-human IS a candidate",
              "ga-cap1" in cand_ids, f"cand_ids={cand_ids!r}")
        check("SWEEP-2: capped bead that already has gate:needs-human is excluded",
              "ga-cap2" not in cand_ids, f"cand_ids={cand_ids!r}")
        check("SWEEP-3: capped bead with gate:needs-human:technical (suffix variant) is excluded",
              "ga-cap3" not in cand_ids, f"cand_ids={cand_ids!r}")
        check("SWEEP-4: below-cap bead is excluded even without gate:needs-human",
              "ga-cap4" not in cand_ids, f"cand_ids={cand_ids!r}")
        check("SWEEP-5: bead with no reclaim-count label at all is excluded",
              "ga-cap5" not in cand_ids, f"cand_ids={cand_ids!r}")
        check("SWEEP-6: capped bead in a NON-HQ rig store is also found (cross-store coverage)",
              "wa-cap6" in cand_ids, f"cand_ids={cand_ids!r}")
        check("SWEEP-7: store scan reports ok=True when every query succeeds",
              ok is True, f"ok={ok!r}")
    finally:
        subprocess.run = _orig_subprocess_run
        irg._list_rig_stores = _orig_list_rig_stores
        irg.list_active_sessions = _orig_list_active_sessions

    # SWEEP-8 (self-audit finding): `bd list` can exit 0 with valid-but-wrong-
    # shaped JSON (e.g. an object instead of an array) on a malformed/changed
    # response. list_inflight_beads() elsewhere in this same file treats that
    # as a FAILURE (returns None), not a confirmed-empty result — this sweep
    # must agree, or a genuinely broken query silently reports "scan clean,
    # zero candidates" instead of "scan degraded, unknown".
    irg._list_rig_stores = lambda: []

    def _stub_run_badshape(cmd, **kw):
        class _R:
            returncode = 0
            stdout = '{"not": "a list"}'
            stderr = ""
        return _R()

    subprocess.run = _stub_run_badshape
    try:
        _candidates, _ok = find_capped_beads_missing_needs_human()
        check("SWEEP-8 (self-audit): non-list JSON from bd list is treated as a FAILED "
              "query (ok=False), never conflated with a confirmed-empty store",
              _ok is False, f"ok={_ok!r} candidates={_candidates!r}")
    finally:
        subprocess.run = _orig_subprocess_run
        irg._list_rig_stores = _orig_list_rig_stores
        irg.list_active_sessions = _orig_list_active_sessions

    # --- LIVE: ga-wpdlg — a capped bead with a LIVE owner must NOT escalate ---
    # Reproduces the measured incident shape: wa-k9czz (P0, reclaim_count=3,
    # status=in_progress, assignee=digo-wa) had a live, pinned session
    # actively fixing it when the pre-fix sweep's dry-run marked it
    # WOULD-ESCALATE. These tests fail on pre-ga-wpdlg code (no liveness
    # check existed at all — every capped/unlabeled bead was a candidate
    # regardless of assignee) and pass after it.
    import datetime as _dt
    _now_live = time.time()
    _fresh_ts = _dt.datetime.fromtimestamp(
        _now_live - 60, tz=_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def _run_live_case(bead, sessions):
        """Run find_capped_beads_missing_needs_human() against exactly one
        HQ candidate bead and a given (possibly None) session list."""
        def _stub(cmd, **kw):
            class _R:
                def __init__(self, rc=0, out="[]"):
                    self.returncode = rc
                    self.stdout = out
                    self.stderr = ""
            if isinstance(cmd, (list, tuple)) and cmd[:2] == ["bd", "list"]:
                return _R(0, json.dumps([bead]))
            return _R(0, "[]")
        irg._list_rig_stores = lambda: []
        irg.list_active_sessions = lambda: sessions
        subprocess.run = _stub
        try:
            candidates, ok = find_capped_beads_missing_needs_human()
            return sorted(c.get("id", "") for c in candidates), ok
        finally:
            subprocess.run = _orig_subprocess_run
            irg._list_rig_stores = _orig_list_rig_stores
            irg.list_active_sessions = _orig_list_active_sessions

    # LIVE-1: assignee is a concrete named session that IS live
    # (state=active, fresh last_active) -> excluded.
    _b7 = _bead("wa-live7", [f"pilot:reclaim-count:{_MAX}"])
    _b7["assignee"] = "digo-wa"
    _live_session_digo = [
        {"id": "sess-digo-1", "name": "digo-wa", "session_name": "digo-wa",
         "alias": "", "agent_name": "digo-wa", "state": "active",
         "last_active": _fresh_ts},
    ]
    _cand_ids, _ok = _run_live_case(_b7, _live_session_digo)
    check("LIVE-1: capped bead whose assignee resolves to a LIVE session is excluded",
          "wa-live7" not in _cand_ids, f"cand_ids={_cand_ids!r}")

    # LIVE-2: same assignee string, but no session in the list matches it
    # (dead/absent owner) -> still a candidate, escalates normally.
    _b8 = _bead("wa-live8", [f"pilot:reclaim-count:{_MAX}"])
    _b8["assignee"] = "digo-wa"
    _cand_ids, _ok = _run_live_case(_b8, [])
    check("LIVE-2: capped bead whose assignee matches NO live session still escalates",
          "wa-live8" in _cand_ids, f"cand_ids={_cand_ids!r}")

    # LIVE-3: bare EPHEMERAL_POOL_ASSIGNEES template assignee (e.g.
    # 'gastown.dog') with a live pool worker of that template -> excluded via
    # pool_has_live_worker, NOT session_is_live (which would never match a
    # bare template string against a concrete session identifier, and so
    # would wrongly fail to protect it without the dedicated pool routing).
    _pool_template = sorted(irg.EPHEMERAL_POOL_ASSIGNEES)[0]
    _b9 = _bead("ga-live9", [f"pilot:reclaim-count:{_MAX}"])
    _b9["assignee"] = _pool_template
    _live_pool_session = [
        {"template": _pool_template, "session_name": "dog-livehash",
         "agent_name": "dog-livehash", "state": "active",
         "id": "sid-pool1", "name": "gastown.dog-9", "alias": "",
         "last_active": _fresh_ts},
    ]
    _cand_ids, _ok = _run_live_case(_b9, _live_pool_session)
    check("LIVE-3: bare pool-template assignee with a live pool worker is excluded "
          "(routed through pool_has_live_worker, not session_is_live)",
          "ga-live9" not in _cand_ids, f"cand_ids={_cand_ids!r}")

    # LIVE-4/5: `gc session list` itself fails (list_active_sessions() ->
    # None) -> liveness is UNKNOWN, not "dead" -> fail-safe: nothing
    # escalates this sweep, even an otherwise-clean candidate, and ok=False
    # (visible, not silently reported as a clean empty scan).
    _cand_ids, _ok = _run_live_case(_b1, None)
    check("LIVE-4: gc session list failure -> nothing escalates (unknown liveness, fail-safe)",
          _cand_ids == [], f"cand_ids={_cand_ids!r}")
    check("LIVE-5: gc session list failure -> ok=False (visible, not silently clean)",
          _ok is False, f"ok={_ok!r}")

    # ESCALATE-1: main() calls the REAL do_escalate() (not a reimplementation)
    # for each candidate, passing through reclaim_count and rig_root.
    irg.do_escalate = _stub_do_escalate
    _orig_argv = sys.argv
    try:
        globals()["find_capped_beads_missing_needs_human"] = lambda: ([_b1, _b6], True)
        sys.argv = ["reclaim_cap_escalation_sweep.py"]
        rc = main()
        check("ESCALATE-1: main() escalates every candidate via the REAL do_escalate()",
              sorted(c[0] for c in _escalate_calls) == ["ga-cap1", "wa-cap6"],
              f"escalate_calls={_escalate_calls!r}")
        check("ESCALATE-2: main() passes each candidate's own rig_root through unchanged",
              ("wa-cap6", _MAX, "/fake/rig/whatsapp_automation") in _escalate_calls,
              f"escalate_calls={_escalate_calls!r}")
        check("ESCALATE-3: main() returns 0 when the store scan was complete",
              rc == 0, f"rc={rc!r}")
    finally:
        globals()["find_capped_beads_missing_needs_human"] = _orig_find
        sys.argv = _orig_argv
        irg.do_escalate = _orig_do_escalate

    # DRYRUN-1: --dry-run never calls do_escalate.
    irg.do_escalate = _stub_do_escalate
    _escalate_calls.clear()
    try:
        globals()["find_capped_beads_missing_needs_human"] = lambda: ([_b1], True)
        sys.argv = ["reclaim_cap_escalation_sweep.py", "--dry-run"]
        main()
        check("DRYRUN-1: --dry-run reports the candidate but never calls do_escalate",
              _escalate_calls == [], f"escalate_calls={_escalate_calls!r}")
    finally:
        globals()["find_capped_beads_missing_needs_human"] = _orig_find
        sys.argv = _orig_argv
        irg.do_escalate = _orig_do_escalate

    print(f"\nResults: {PASS} passed, {FAIL} failed")
    return FAIL == 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(0 if _selftest() else 1)
    raise SystemExit(main())
