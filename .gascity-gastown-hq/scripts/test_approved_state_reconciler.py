#!/usr/bin/env python3
"""test_approved_state_reconciler.py — regression tests for
_extra_alarm_suppress_reason()'s pilot:text-veto:* recognition (ga-qt0mj) and for
the pool-cap containment evidence the reconciler reads from the Pilot's own log
(ga-9ekn2l — _pilot_cap_evidence / _alarm_capacity_wait).

Hermetic: pure-function tests only, no Dolt/bd/network access.

Run: python3 -m pytest scripts/test_approved_state_reconciler.py -q
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

MOD_PATH = Path(__file__).resolve().parent / "approved-state-reconciler.py"


def _load_asr():
    # approved-state-reconciler.py has hyphens, so it isn't a valid module
    # name for a plain `import` — load it by file path instead (same idiom
    # as test_production_stall_watchdog.py's _load_psw()).
    spec = importlib.util.spec_from_file_location("approved_state_reconciler", MOD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


asr = _load_asr()


def test_pilot_text_veto_label_suppresses_alarm():
    """ga-qt0mj core fix: before this, a bead vetoed purely by TEXT (no label at
    all) was reported as matching NONE of this reconciler's known signals — the
    reconciler alarmed blind while the real reason lived only in the Pilot's log.
    Once pilot-dispatcher.sh stamps pilot:text-veto:<pattern>, this must suppress."""
    reason = asr._extra_alarm_suppress_reason(["pilot:text-veto:compliance-marker-text-pattern"])
    assert reason is not None
    assert "pilot:text-veto" in reason


def test_pilot_text_veto_covers_all_four_pattern_suffixes():
    """One shared _has_prefix("pilot:text-veto") entry must cover every slug
    pilot-dispatcher.sh's _reconcile_text_veto_labels can stamp — a per-suffix
    allowlist here would silently miss a new veto added there later."""
    for suffix in (
        "engine-rebuild-text-pattern",
        "decisao-title-text-pattern",
        "athos-decide-phrase-text-pattern",
        "compliance-marker-text-pattern",
    ):
        label = "pilot:text-veto:" + suffix
        assert asr._extra_alarm_suppress_reason([label]) is not None, label


def test_no_text_veto_label_still_alarms():
    """Baseline (must NOT regress): a bead with no known non-buildable signal at
    all still returns None — this reconciler's whole point is to alarm on that."""
    assert asr._extra_alarm_suppress_reason(["ctx:ready", "exec:auto"]) is None


def test_pilot_text_veto_does_not_match_unrelated_pilot_prefix():
    """_has_prefix requires an exact ':' boundary — pilot:text-vetoed (no colon
    before 'ed') or an unrelated pilot:* label must NOT false-positive."""
    assert asr._extra_alarm_suppress_reason(["pilot:dispatched"]) is None
    assert asr._extra_alarm_suppress_reason(["pilot:text-vetoed-typo"]) is None


# ── ga-9ekn2l: pool-cap containment evidence ───────────────────────────────────
# These four strings are REAL pilot-dispatcher.log lines, verbatim (copied
# 2026-09-20). Not a paraphrase: ga-5d5se shipped a regex validated only
# against a paraphrased fixture and it matched zero real lines. "—" is the
# em dash the Pilot writes.
_REAL_CAP_PICK = (
    "[2026-09-20 01:24:13] [pilot-dispatcher] ga-in9ebr: wa-ho1ol QUEUED — routed to "
    "wa-worker, pool at session cap (2 active/creating >= 2 max); not claimed, no writes "
    "this sweep (the ga-93yxc pool top-up opens a session once a slot frees).")
_REAL_CAP_DISPATCH = (
    "[2026-09-19 16:05:16] [pilot-dispatcher]   ga-in9ebr: wa-worker pool at session cap "
    "(4 active/creating >= 4 max) — QUEUED wa-zdzc8: claim released, story:approved + "
    "gc.routed_to=wa-worker kept, NOT marked in-flight/dispatched (ga-93yxc pool top-up "
    "opens a session once a slot frees).")
_REAL_SWEEP_NORMAL = (
    "[2026-09-20 01:24:14] [pilot-dispatcher] === Pilot sweep complete: dispatched=1 "
    "(small_slots=3 big_slots=1 dolt_saturated_at_start=0) ===")
_REAL_SWEEP_DEFERRED = (
    "[2026-09-20 01:35:11] [pilot-dispatcher] === Pilot sweep complete: dispatched=0 "
    "(deferred: cross-stage gate-congested + resource-contended, ga-d0hz3) ===")


def _evidence(monkeypatch, lines, now):
    monkeypatch.setattr(asr, "_read_pilot_log_lines", lambda: lines)
    return asr._pilot_cap_evidence(now)


def test_cap_evidence_parses_both_real_line_shapes(monkeypatch):
    """The reconciler alarmed 'dispatch failing' on wa-ho1ol for 1774min while the Pilot
    was logging, every sweep, that it QUEUED the bead at the pool session cap. Both
    emission shapes must yield per-bead evidence carrying the cap the Pilot enforced."""
    ev = _evidence(monkeypatch, [_REAL_CAP_PICK, _REAL_SWEEP_NORMAL],
                   asr._ts_epoch(_REAL_SWEEP_NORMAL) + 60)
    assert ev["wa-ho1ol"]["pool"] == "wa-worker"
    assert (ev["wa-ho1ol"]["live"], ev["wa-ho1ol"]["max"]) == (2, 2)
    ev2 = _evidence(monkeypatch, [_REAL_CAP_DISPATCH], asr._ts_epoch(_REAL_CAP_DISPATCH) + 60)
    assert (ev2["wa-zdzc8"]["live"], ev2["wa-zdzc8"]["max"]) == (4, 4)


def test_cap_evidence_survives_a_real_whole_sweep_deferral_but_not_the_ttl(monkeypatch):
    """The 01:35 sweep evaluated nothing (deferred), so it must not erase the 01:24
    evidence — but evidence older than the TTL must stop counting."""
    lines = [_REAL_CAP_PICK, _REAL_SWEEP_NORMAL, _REAL_SWEEP_DEFERRED]
    t = asr._ts_epoch(_REAL_CAP_PICK)
    assert "wa-ho1ol" in _evidence(monkeypatch, lines, t + 22 * 60)
    # Older than the TTL the Pilot's CURRENT decision is unknown: None ("don't know"),
    # never {} ("measured: nothing is capped").
    assert _evidence(monkeypatch, lines, t + asr.PILOT_CAP_EVIDENCE_TTL_SEC + 60) is None


def test_cap_evidence_is_dropped_once_a_later_evaluating_sweep_omits_the_bead(monkeypatch):
    """A cap line from an older sweep must not keep explaining a bead the Pilot's LATEST
    evaluating sweep no longer lists as capped (a genuine failure would hide behind it)."""
    def ts(t):
        return asr.time.strftime("[%Y-%m-%d %H:%M:%S]", asr.time.localtime(t))
    now = 1_750_000_000.0
    lines = [
        _REAL_CAP_PICK.replace("[2026-09-20 01:24:13]", ts(now - 1500)),
        ts(now - 1499) + " [pilot-dispatcher] === Pilot sweep complete: dispatched=0 "
                         "(small_slots=3 big_slots=1 dolt_saturated_at_start=0) ===",
        ts(now - 40) + " [pilot-dispatcher] === Pilot sweep complete: dispatched=0 "
                       "(small_slots=3 big_slots=1 dolt_saturated_at_start=0) ===",
    ]
    assert _evidence(monkeypatch, lines, now) == {}


def test_cap_evidence_error_and_empty_are_different_values(monkeypatch):
    """root-class:error-vs-empty — an unreadable log (None) must never look like a log
    that was read and shows nothing capped ({})."""
    assert _evidence(monkeypatch, [], 1_750_000_000.0) is None
    now = asr._ts_epoch(_REAL_SWEEP_NORMAL) + 60
    assert _evidence(monkeypatch, [_REAL_SWEEP_NORMAL], now) == {}


def test_cap_evidence_per_line_ttl_drops_a_stale_line_riding_beside_fresh_evidence(monkeypatch):
    """The newest proof is fresh, yet an old completed sweep's cap line is 50 minutes old:
    the per-line TTL is the only thing that stops it riding along as evidence."""
    def ts(t):
        return asr.time.strftime("[%Y-%m-%d %H:%M:%S]", asr.time.localtime(t))

    def cap(t, bead):
        return _REAL_CAP_PICK.replace("[2026-09-20 01:24:13]", ts(t)).replace("wa-ho1ol", bead)
    now = 1_750_000_000.0
    lines = [
        cap(now - 3000, "wa-old"),
        ts(now - 2999) + " [pilot-dispatcher] === Pilot sweep complete: dispatched=0 "
                         "(small_slots=3 big_slots=1 dolt_saturated_at_start=0) ===",
        ts(now - 100) + " [pilot-dispatcher] === Pilot sweep complete: dispatched=0 "
                        "(deferred: cross-stage gate-congested + resource-contended, ga-d0hz3) ===",
        cap(now - 30, "wa-new"),
    ]
    assert set(_evidence(monkeypatch, lines, now)) == {"wa-new"}


def test_cap_evidence_is_unmeasured_when_the_log_holds_no_evaluating_sweep(monkeypatch):
    """A readable log made only of whole-sweep deferrals says nothing about what the
    Pilot's last dispatch decision was — 'don't know' (None), not 'nothing is capped' ({})."""
    now = asr._ts_epoch(_REAL_SWEEP_DEFERRED) + 60
    assert _evidence(monkeypatch, [_REAL_SWEEP_DEFERRED], now) is None


def test_cap_evidence_drops_lines_dated_in_the_future(monkeypatch):
    """A stepped clock must not make old evidence look fresh forever: a cap line dated
    beyond the skew allowance is dropped, one inside it is kept."""
    t = asr._ts_epoch(_REAL_CAP_PICK)
    lines = [_REAL_CAP_PICK, _REAL_SWEEP_NORMAL]
    # A line 1h ahead of `now` is not proof of anything: with nothing else to go on the
    # answer is unmeasured (None), not "measured: nothing capped" ({}).
    assert _evidence(monkeypatch, lines, t - 3600) is None
    assert "wa-ho1ol" in _evidence(monkeypatch, lines, t - 60)         # inside the allowance


def test_capacity_wait_is_a_distinct_alarm_that_claims_nothing_and_is_rate_limited(monkeypatch):
    """The reclassified note: not 'dispatch failing', no flow-authority claim (that would
    mute the stall watchdogs), no human-touch row, no phone push — and ONE per pool, not
    one per bead."""
    mails = []
    monkeypatch.setattr(asr, "_do_mail_mayor", lambda s, b: mails.append((s, b)) or True)

    def _forbidden(*_a, **_k):
        raise AssertionError("a capacity-wait note must not do this")
    monkeypatch.setattr(asr, "_write_flow_authority", _forbidden)
    monkeypatch.setattr(asr, "_arc_ledger", _forbidden)
    monkeypatch.setattr(asr, "_do_notify", _forbidden)
    monkeypatch.setattr(asr, "DRY_RUN", False)

    now = 1_750_000_000.0
    ev = {"wa-ho1ol": {"pool": "wa-worker", "live": 2, "max": 2, "epoch": now - 300},
          "wa-other": {"pool": "wa-worker", "live": 2, "max": 2, "epoch": now - 300}}
    state = {"first_seen_approved": {"wa-ho1ol": now - 1774 * 60, "wa-other": now - 600 * 60}}
    asr._alarm_capacity_wait("/x/whatsapp_automation", {"id": "wa-ho1ol", "title": "t"},
                             1774.0, ev["wa-ho1ol"], ev, now, state)
    asr._alarm_capacity_wait("/x/whatsapp_automation", {"id": "wa-other", "title": "t"},
                             600.0, ev["wa-other"], ev, now, state)
    assert len(mails) == 1                      # second bead, same pool: inside the backoff
    subject, body = mails[0]
    assert "dispatch failing" not in subject and "dispatch path failing" not in body
    assert "aguardando capacidade" in subject
    assert "teto 2" in subject and "wa-ho1ol" in subject and "1774min" in subject
    assert "PILOT_WA_WORKER_MAX" in body
    assert state["capacity_wait"]["wa-worker"]["count"] == 1
