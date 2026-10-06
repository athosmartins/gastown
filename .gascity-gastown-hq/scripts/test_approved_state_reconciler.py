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
import os
import re
import subprocess
from pathlib import Path

import pytest

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

# GATE-FIX 1 (attempt 1 FAIL) — the THREE consecutive REAL sweeps of 2026-09-19 that the
# gate reviewer replayed, verbatim from .gc/logs/pilot-dispatcher.log (only the lines that
# matter; nothing edited):
#   A 16:37:45  dispatched=0, both lanes with a slot: a FULL WALK; wa-c8s2w capped 4>=4.
#   B 16:52:20  dispatched=1 — "Lane small: dispatched 1 (cap=1, slots_left=0)": the small
#               lane stopped after ga-owlmfj, so wa-c8s2w (and 25 more beads capped in A
#               AND C) was never walked and got NO line; the big lane still had a slot and
#               logged its two.
#   C 17:07:44  dispatched=0, full walk; wa-c8s2w capped again, now 2>=2 (the cap moved).
_REAL_SWEEP_A = [
    "[2026-09-19 16:36:28] [pilot-dispatcher] ga-in9ebr: wa-c8s2w QUEUED — routed to wa-worker, pool at session cap (4 active/creating >= 4 max); not claimed, no writes this sweep (the ga-93yxc pool top-up opens a session once a slot frees).",
    "[2026-09-19 16:37:45] [pilot-dispatcher] Lane small: dispatched 0 this sweep (cap=1, slots_left=1).",
    "[2026-09-19 16:37:45] [pilot-dispatcher] Lane big: dispatched 0 this sweep (cap=1, slots_left=1).",
    "[2026-09-19 16:37:45] [pilot-dispatcher] === Pilot sweep complete: dispatched=0 (small_slots=1 big_slots=1 dolt_saturated_at_start=0) ===",
]
_REAL_SWEEP_B = [
    "[2026-09-19 16:52:15] [pilot-dispatcher] Lane small: dispatched 1 this sweep (cap=1, slots_left=0).",
    "[2026-09-19 16:52:20] [pilot-dispatcher] ga-in9ebr: wa-jjztr QUEUED — routed to wa-worker, pool at session cap (3 active/creating >= 2 max); not claimed, no writes this sweep (the ga-93yxc pool top-up opens a session once a slot frees).",
    "[2026-09-19 16:52:20] [pilot-dispatcher] ga-in9ebr: wa-0r2bt QUEUED — routed to wa-worker, pool at session cap (3 active/creating >= 2 max); not claimed, no writes this sweep (the ga-93yxc pool top-up opens a session once a slot frees).",
    "[2026-09-19 16:52:20] [pilot-dispatcher] Lane big: dispatched 0 this sweep (cap=1, slots_left=1).",
    "[2026-09-19 16:52:20] [pilot-dispatcher] === Pilot sweep complete: dispatched=1 (small_slots=1 big_slots=1 dolt_saturated_at_start=0) ===",
]
_REAL_SWEEP_C = [
    "[2026-09-19 17:06:03] [pilot-dispatcher] ga-in9ebr: wa-c8s2w QUEUED — routed to wa-worker, pool at session cap (2 active/creating >= 2 max); not claimed, no writes this sweep (the ga-93yxc pool top-up opens a session once a slot frees).",
    "[2026-09-19 17:07:44] [pilot-dispatcher] Lane small: dispatched 0 this sweep (cap=1, slots_left=1).",
    "[2026-09-19 17:07:44] [pilot-dispatcher] Lane big: dispatched 0 this sweep (cap=1, slots_left=1).",
    "[2026-09-19 17:07:44] [pilot-dispatcher] === Pilot sweep complete: dispatched=0 (small_slots=1 big_slots=1 dolt_saturated_at_start=0) ===",
]
# The one REAL "a lane loop was cut short with dispatched=0" line (2026-09-15 09:29:52).
_REAL_LOOP_CUT = (
    "[2026-09-15 09:29:52] [pilot-dispatcher] WARN: Dolt health UNREADABLE mid-sweep "
    "(cpu=% lat=?ms — probe returned no signal, NOT a measured value) — stopping small "
    "loop after 0 dispatch(es), same fail-safe as genuine saturation (ga-hzt7; ga-rk5va "
    "backoff).")

_NOW = 1_750_000_000.0


def _ts(t):
    return asr.time.strftime("[%Y-%m-%d %H:%M:%S]", asr.time.localtime(t))


def _cap_line(t, bead, live=2, cap=2):
    return (_REAL_CAP_PICK.replace("[2026-09-20 01:24:13]", _ts(t)).replace("wa-ho1ol", bead)
            .replace("(2 active/creating >= 2 max)",
                     "(%d active/creating >= %d max)" % (live, cap)))


def _complete(t, dispatched=0, small=3, big=1):
    """A normal sweep-complete line in the REAL shape. Default: a FULL WALK."""
    return (_ts(t) + " [pilot-dispatcher] === Pilot sweep complete: dispatched=%d "
            "(small_slots=%d big_slots=%d dolt_saturated_at_start=0) ===" % (
                dispatched, small, big))


def _restamp_one(line, t):
    return re.sub(r"^\[[^\]]+\]", _ts(t), line, count=1)


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
    evaluating sweep no longer lists as capped (a genuine failure would hide behind it).
    "Evaluating" means a FULL WALK here (dispatched=0, both lanes with a slot, nothing cut
    short): only that proves the Pilot looked at the bead. The dispatching-sweep tests below
    are the shape where it did not — there the same absence proves nothing."""
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
    ev = _evidence(monkeypatch, lines, now)
    assert ev == {}
    assert ev.walked_all is True     # measured: a missing bead is positively "not held"


def test_cap_evidence_error_and_empty_are_different_values(monkeypatch):
    """root-class:error-vs-empty — an unreadable log (None) must never look like a log
    that was read and shows nothing capped ({})."""
    assert _evidence(monkeypatch, [], 1_750_000_000.0) is None
    now = asr._ts_epoch(_REAL_SWEEP_NORMAL) + 60
    ev = _evidence(monkeypatch, [_REAL_SWEEP_NORMAL], now)
    assert ev == {}
    # ...and even a read log's "{}" is a THIRD value, not "measured: nothing capped": that
    # real sweep DISPATCHED (dispatched=1), so it did not walk every candidate and a bead
    # missing from the map is unmeasured. Only a full walk makes the same "{}" a measurement.
    assert ev.walked_all is False
    full = _evidence(monkeypatch, [_complete(now - 60)], now)
    assert full == {} and full.walked_all is True


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


# ── ga-9ekn2l GATE-FIX 1 (attempt 1 FAIL): a sweep that did not walk everyone must not erase ──
# The first version read EVERY completed sweep as a full walk: a bead absent from a later
# sweep's cap lines lost its evidence and the alarm claimed "the Pilot did NOT queue it".
# But the Pilot logs a cap line only for a candidate it WALKS, and a lane stops walking the
# moment its slots/cap are consumed — so a sweep that dispatched says nothing about the
# candidates behind the dispatch. These are the regression tests; the fixtures are REAL.


def test_real_replay_sweep_a_alone_is_a_measured_full_walk(monkeypatch):
    now = asr._ts_epoch(_REAL_SWEEP_A[-1]) + 30
    ev = _evidence(monkeypatch, _REAL_SWEEP_A, now)
    assert set(ev) == {"wa-c8s2w"} and ev["wa-c8s2w"]["max"] == 4
    assert ev.walked_all is True


def test_real_replay_the_dispatching_sweep_keeps_the_evidence_of_beads_it_never_walked(monkeypatch):
    """THE reviewer's finding, on the real 16:37/16:52 lines: at the cycle right after the
    dispatching 16:52:20 sweep, wa-c8s2w (front of its queue, capped at 16:36:28 and again
    at 17:06:03) has NO line in 16:52 only because its lane stopped at slots_left=0 — it
    must stay explained, and a bead missing from the map must read UNMEASURED."""
    now = asr._ts_epoch(_REAL_SWEEP_B[-1]) + 30
    ev = _evidence(monkeypatch, _REAL_SWEEP_A + _REAL_SWEEP_B, now)
    assert set(ev) == {"wa-c8s2w", "wa-jjztr", "wa-0r2bt"}
    assert ev["wa-c8s2w"]["max"] == 4 and ev["wa-jjztr"]["max"] == 2    # caps really do mix
    assert ev.walked_all is False
    assert "dispatched 1 bead" in ev.why


def test_real_replay_the_full_walk_after_it_refreshes_and_supersedes(monkeypatch):
    """17:07:44 walked everyone: wa-c8s2w is refreshed (now 2>=2); in this trimmed fixture
    it lists only that bead, so a full walk that omits the big-lane pair supersedes them."""
    now = asr._ts_epoch(_REAL_SWEEP_C[-1]) + 30
    ev = _evidence(monkeypatch, _REAL_SWEEP_A + _REAL_SWEEP_B + _REAL_SWEEP_C, now)
    assert set(ev) == {"wa-c8s2w"} and ev["wa-c8s2w"]["max"] == 2
    assert ev.walked_all is True


def _x_older_sweep():
    """wa-x is capped in an OLDER completed sweep, both lines inside the TTL."""
    return [_cap_line(_NOW - 1500, "wa-x"), _complete(_NOW - 1499, dispatched=1)]


@pytest.mark.parametrize("name,tail", [
    ("a dispatch", lambda: [_complete(_NOW - 100, dispatched=1)]),
    ("small lane has no slot", lambda: [_complete(_NOW - 100, small=0)]),
    ("big lane has no slot", lambda: [_complete(_NOW - 100, big=0)]),
    ("a lane loop cut short (the REAL 2026-09-15 line)",
     lambda: [_restamp_one(_REAL_LOOP_CUT, _NOW - 150), _complete(_NOW - 100)]),
    ("a complete line with no counters",
     lambda: [_ts(_NOW - 100) + " [pilot-dispatcher] === Pilot sweep complete: dispatched=0 ==="]),
    ("an undatable complete line",
     lambda: ["[pilot-dispatcher] === Pilot sweep complete: dispatched=0 (small_slots=3 "
              "big_slots=1 dolt_saturated_at_start=0) ==="]),
    ("a future-dated full-walk line (a stepped clock is not proof)",
     lambda: [_complete(_NOW + 3600)]),
])
def test_every_reason_a_sweep_may_not_have_walked_everyone_keeps_older_evidence(
        monkeypatch, name, tail):
    """The CLASS, not the one instance the reviewer cited: every way a completed sweep can
    fail to have walked all its candidates leaves older evidence in place and reads
    UNMEASURED — with a reason the alarm body can print."""
    ev = _evidence(monkeypatch, _x_older_sweep() + tail(), _NOW)
    assert ev is not None and "wa-x" in ev, name
    assert ev.walked_all is False and ev.why, name


def test_a_genuine_full_walk_is_the_control_it_supersedes_and_reads_measured(monkeypatch):
    ev = _evidence(monkeypatch, _x_older_sweep() + [_complete(_NOW - 100)], _NOW)
    assert ev is not None and "wa-x" not in ev and ev.walked_all is True


def test_the_cut_short_flag_belongs_to_one_sweep_only(monkeypatch):
    """A clean full walk right after a cut-short sweep is a full walk again — a flag that
    leaked across sweeps would keep old evidence (and the UNMEASURED reading) for good."""
    lines = _x_older_sweep() + [_restamp_one(_REAL_LOOP_CUT, _NOW - 800),
                                _complete(_NOW - 790),      # cut short: keeps wa-x
                                _complete(_NOW - 100)]      # clean: supersedes
    ev = _evidence(monkeypatch, lines, _NOW)
    assert "wa-x" not in ev and ev.walked_all is True


def _start(t):
    """The REAL sweep-start line shape ('=== Pilot sweep start (DRY_RUN=0) ===')."""
    return _ts(t) + " [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ==="


def test_an_aborted_sweep_does_not_leak_its_lines_into_the_next_full_walk(monkeypatch):
    """100 of 1059 real sweep starts never completed (one left cap lines behind). Such a sweep
    walked an unknown part of its pool; its stale lines must not be inherited as the NEXT
    sweep's own when that one is a genuine full walk that did not list them."""
    lines = _x_older_sweep() + [
        _start(_NOW - 1400), _cap_line(_NOW - 1300, "wa-aborted"),   # never completed
        _start(_NOW - 600), _complete(_NOW - 100)]                   # a genuine full walk
    ev = _evidence(monkeypatch, lines, _NOW)
    assert ev == {} and ev.walked_all is True


def test_an_aborted_sweeps_cap_lines_still_count_as_evidence_until_a_full_walk(monkeypatch):
    """...but folded in as a NON-exhaustive block they are still positive evidence: a later
    sweep that dispatched (so did not walk everyone) supersedes nothing."""
    lines = _x_older_sweep() + [
        _start(_NOW - 1400), _cap_line(_NOW - 1300, "wa-aborted"),
        _start(_NOW - 600), _complete(_NOW - 100, dispatched=1)]
    ev = _evidence(monkeypatch, lines, _NOW)
    assert set(ev) == {"wa-x", "wa-aborted"} and ev.walked_all is False


def test_cap_lines_of_a_running_sweep_with_no_completed_sweep_read_unmeasured(monkeypatch):
    """Absence from a sweep that has not finished disproves nothing: the map holds the
    running sweep's lines but must not license "the Pilot did not queue it"."""
    ev = _evidence(monkeypatch, [_cap_line(_NOW - 100, "wa-r")], _NOW)
    assert set(ev) == {"wa-r"} and ev.walked_all is False and "COMPLETED" in ev.why


def test_a_full_walk_older_than_the_ttl_no_longer_proves_absence(monkeypatch):
    ev = _evidence(monkeypatch, [_complete(_NOW - 2000), _cap_line(_NOW - 100, "wa-s")], _NOW)
    assert set(ev) == {"wa-s"} and ev.walked_all is False and "older than" in ev.why


def test_an_undatable_cap_line_is_never_evidence(monkeypatch):
    """A cap line with no parseable timestamp cannot be shown to be fresh: skipped, never
    trusted ("no evidence" is the alarm-preserving direction)."""
    undatable = ("[pilot-dispatcher] ga-in9ebr: wa-u QUEUED — routed to wa-worker, pool at "
                 "session cap (2 active/creating >= 2 max); not claimed, no writes this sweep")
    ev = _evidence(monkeypatch, [undatable, _complete(_NOW - 60)], _NOW)
    assert ev == {} and "wa-u" not in ev


def test_a_bare_map_defaults_to_unmeasured_never_to_a_measured_negative():
    """The class-level defaults are the SAFE ones: a caller that builds its own map, or
    hands over a plain dict, can never assert a negative nobody measured."""
    assert asr._CapEvidence().walked_all is False
    assert asr._CapEvidence().why
    assert getattr({}, "walked_all", False) is False


def _starve(monkeypatch, cap_evidence):
    """Fire the real 'dispatch failing' alarm for one bead; return its mail body."""
    mails = []
    monkeypatch.setattr(asr, "DRY_RUN", False)
    monkeypatch.setattr(asr, "_read_pilot_log_lines", lambda: [])
    monkeypatch.setattr(asr, "_do_mail_mayor", lambda s, b: mails.append((s, b)) or True)
    monkeypatch.setattr(asr, "_do_notify", lambda m, p: None)
    monkeypatch.setattr(asr, "_arc_ledger", lambda *a, **k: None)
    monkeypatch.setattr(asr, "_write_flow_authority", lambda *a, **k: None)
    asr._alarm_starving("/x/whatsapp_automation",
                        {"id": "wa-x", "title": "t", "labels": ["story:approved"]},
                        600.0, _NOW, {}, cap_evidence=cap_evidence)
    assert len(mails) == 1
    assert "dispatch failing" in mails[0][0]
    return mails[0][1]


def test_alarm_body_asserts_the_negative_only_when_the_sweep_walked_everyone(monkeypatch):
    """GATE-FIX 1: 'the Pilot did NOT queue it at a cap' is a MEASURED claim. After a sweep
    that dispatched (or any non-walk) the body must say NÃO MEDIDO with the reason — the
    false sentence used to point the reader away from the very cap that held the bead."""
    measured = asr._CapEvidence()
    measured.walked_all = True
    body = _starve(monkeypatch, measured)
    assert "none for this bead" in body and "walked every candidate and did NOT queue it" in body
    assert "NÃO MEDIDO" not in body.split("Pool-cap evidence")[1].split("\n")[0]

    unmeasured = asr._CapEvidence()
    unmeasured.why = "the Pilot's newest completed sweep dispatched 1 bead(s), and a lane stops"
    for label, ev in (("unmeasured map", unmeasured), ("bare dict", {}), ("empty map", asr._CapEvidence())):
        line = [l for l in _starve(monkeypatch, ev).splitlines() if "Pool-cap evidence" in l]
        assert len(line) == 1, label
        assert "NÃO MEDIDO" in line[0], label
        assert "none for this bead" not in line[0] and "did NOT queue it" not in line[0], label
    assert "dispatched 1 bead" in _starve(monkeypatch, unmeasured)

    none_body = _starve(monkeypatch, None)      # the Pilot log itself was unreadable / stale
    assert "NÃO MEDIDO" in none_body and "holds no FRESH" in none_body


def test_capacity_wait_names_the_pools_newest_cap_whatever_the_iteration_order(monkeypatch):
    """Evidence kept across non-exhaustive sweeps can mix a pre-flip cap with a post-flip one
    (real: wa-c8s2w's kept line says 4>=4, the sweep after says 3>=2). The note and its
    fingerprint must come from the POOL's newest reading, or the fingerprint flips with
    iteration order and every flip re-fires a 'new incident' note at once."""
    def _forbidden(*_a, **_k):
        raise AssertionError("a capacity-wait note must not do this")
    monkeypatch.setattr(asr, "_write_flow_authority", _forbidden)
    monkeypatch.setattr(asr, "_arc_ledger", _forbidden)
    monkeypatch.setattr(asr, "_do_notify", _forbidden)
    monkeypatch.setattr(asr, "DRY_RUN", False)
    ev = {
        "wa-a": {"pool": "wa-worker", "live": 4, "max": 4, "epoch": _NOW - 900},   # pre-flip
        "wa-b": {"pool": "wa-worker", "live": 3, "max": 2, "epoch": _NOW - 60},    # post-flip
        "wa-c": {"pool": "wa-worker", "live": 4, "max": 4, "epoch": _NOW - 900},   # pre-flip
    }
    for order in (["wa-a", "wa-b", "wa-c"], ["wa-c", "wa-b", "wa-a"], ["wa-b", "wa-a", "wa-c"]):
        mails = []
        monkeypatch.setattr(asr, "_do_mail_mayor", lambda s, b: mails.append((s, b)) or True)
        state = {"first_seen_approved": {b: _NOW - 600 * 60 for b in ev}}
        for bid in order:
            asr._alarm_capacity_wait("/x/whatsapp_automation", {"id": bid, "title": "t"},
                                     600.0, ev[bid], ev, _NOW, state)
        assert len(mails) == 1, (order, [s for s, _ in mails])
        assert "teto 2" in mails[0][0] and "teto 4" not in mails[0][0], order
        assert "3 bead(s) na fila" in mails[0][0], order
        assert state["capacity_wait"]["wa-worker"]["fp"] == "wa-worker:2", order


# ═══════════════════════════════════════════════════════════════════════════════
# ga-3ebneo — the built-branch mirrors (_real_has_built_branch / _matched_built_branch_ref)
# read the Pilot's ONE branch list (delivery-branch-patterns.sh) instead of a copy.
#
# They mirror pilot-dispatcher.sh's _filter_built: the reconciler tells "the Pilot skips this bead
# because it is already built" from "the dispatch path is failing". The Pilot now counts
# feat/<id>, fix/<id> (no slug), refactor/ ... too; a mirror stuck on crew/*/<id> + fix/<id>-*
# would page the Mayor "dispatch failing" for each of those. REAL git against throwaway repos.
# ═══════════════════════════════════════════════════════════════════════════════

DELIVERY_LIB = Path(os.environ.get(
    "DELIVERY_LIB_UNDER_TEST",
    str(MOD_PATH.parent.parent / "packs" / "town-deltas" / "assets" / "delivery-branch-patterns.sh")))


def _bash_lib(snippet):
    return subprocess.run(["bash", "-c", '. "$1"; ' + snippet, "_", str(DELIVERY_LIB)],
                          capture_output=True, text=True, check=True).stdout


@pytest.fixture
def work_repo(tmp_path, monkeypatch):
    r = tmp_path / "work"
    r.mkdir()
    for args in (["init", "-q"], ["config", "user.email", "t@t.invalid"], ["config", "user.name", "t"],
                 ["commit", "-q", "--allow-empty", "-m", "init"]):
        subprocess.run(["git", "-C", str(r)] + args, check=True, capture_output=True)
    monkeypatch.setattr(asr, "_ownership_guard_repos", lambda: [str(r)])
    monkeypatch.setattr(asr, "_delivery_branch_lib_path", lambda: str(DELIVERY_LIB), raising=False)
    monkeypatch.setattr(asr, "_DELIVERY_PREFIXES", None, raising=False)
    monkeypatch.setattr(asr, "_bd_delivery_branch_prefixes", None, raising=False)
    return r


def _mkref(repo, ref):
    sha = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True,
                         check=True).stdout.strip()
    subprocess.run(["git", "-C", str(repo), "update-ref", ref, sha], check=True, capture_output=True)


def test_delivery_prefixes_and_globs_equal_the_bash_lib_exactly():
    """DRIFT GUARD: the Python parse of the lib and the globs it builds must equal what the lib itself
    prints, in the same priority order — the mirror is only a mirror while this holds."""
    asr._DELIVERY_PREFIXES = None
    asr._bd_delivery_branch_prefixes = None
    orig = asr._delivery_branch_lib_path
    asr._delivery_branch_lib_path = lambda: str(DELIVERY_LIB)
    try:
        assert asr._delivery_branch_prefixes() == _bash_lib('printf "%s" "$GC_DELIVERY_BRANCH_PREFIXES"').split()
        for bead in ("ga-abc", "ga-05604.2"):
            want = _bash_lib('gc_delivery_branch_globs "$2"'.replace("$2", bead)).split()
            assert asr._delivery_branch_globs(bead) == want, bead
    finally:
        asr._delivery_branch_lib_path = orig
        asr._DELIVERY_PREFIXES = None


@pytest.mark.parametrize("ref,bead", [
    ("refs/heads/feat/ga-feat", "ga-feat"),                    # NEW: feat/<id>
    ("refs/heads/fix/ga-bare", "ga-bare"),                     # NEW: fix/<id> with no slug
    ("refs/heads/crew/alice/ga-crewslug-wip", "ga-crewslug"),  # NEW: crew/<owner>/<id>-<slug>
    ("refs/remotes/origin/refactor/ga-trk-x", "ga-trk"),       # NEW: fetched origin ref, refactor/
    ("refs/heads/fix/ga-slug-fixture", "ga-slug"),             # old shape
    ("refs/heads/crew/alice/ga-crew", "ga-crew"),              # old shape
])
def test_a_delivery_branch_on_any_shared_shape_is_seen_and_named(work_repo, ref, bead):
    _mkref(work_repo, ref)
    assert asr._real_has_built_branch(bead) is True
    assert asr._matched_built_branch_ref(bead) == (str(work_repo), ref)


@pytest.mark.parametrize("refs,bead", [
    ([], "ga-none"),                                                    # nothing at all
    (["refs/heads/feat/ga-longer", "refs/heads/fix/ga-long2-x"], "ga-long"),  # LONGER ids sharing the prefix
    (["refs/heads/chore/ga-ovr/child"], "ga-ovr"),                      # path-prefix decoy only
    (["refs/tags/feat/ga-tag", "refs/remotes/upstream/feat/ga-tag"], "ga-tag"),  # not branches of ours
])
def test_no_delivery_branch_means_not_built(work_repo, refs, bead):
    for r in refs:
        _mkref(work_repo, r)
    assert asr._real_has_built_branch(bead) is False
    assert asr._matched_built_branch_ref(bead) is None


def test_a_decoy_that_sorts_first_does_not_hide_the_real_branch(work_repo):
    _mkref(work_repo, "refs/heads/chore/ga-nest/child")   # for-each-ref matches it as a path prefix of chore/ga-nest
    _mkref(work_repo, "refs/heads/feat/ga-nest")
    assert asr._matched_built_branch_ref("ga-nest") == (str(work_repo), "refs/heads/feat/ga-nest")


def test_priority_fix_beats_feat_whichever_sorts_first(work_repo):
    _mkref(work_repo, "refs/heads/feat/ga-prio")
    _mkref(work_repo, "refs/heads/fix/ga-prio-b")
    assert asr._matched_built_branch_ref("ga-prio") == (str(work_repo), "refs/heads/fix/ga-prio-b")


def test_could_not_tell_is_never_a_delivery_and_never_the_same_value_as_none(work_repo, monkeypatch):
    _mkref(work_repo, "refs/heads/feat/ga-feat")
    # (a) the shared list cannot be read → "could not tell" (None), which ends as NOT built — it must
    # not fall back to a private list, and must not read as "looked and found none" ("").
    monkeypatch.setattr(asr, "_delivery_branch_lib_path", lambda: str(work_repo / "does-not-exist.sh"))
    assert asr._delivery_branch_prefixes() is None
    assert asr._delivery_branch_in_repo(str(work_repo), "ga-feat") is None
    assert asr._real_has_built_branch("ga-feat") is False
    assert asr._matched_built_branch_ref("ga-feat") is None
    # (b) lib present again → the failure above was not memoized.
    monkeypatch.setattr(asr, "_delivery_branch_lib_path", lambda: str(DELIVERY_LIB))
    assert asr._delivery_branch_in_repo(str(work_repo), "ga-feat") == "refs/heads/feat/ga-feat"
    assert asr._delivery_branch_in_repo(str(work_repo), "ga-nothing") == ""
    # (c) git fails → None (could not tell), not "".
    monkeypatch.setattr(asr, "_sh", lambda args, timeout=20: subprocess.CompletedProcess(args, 128, "", "fatal"))
    assert asr._delivery_branch_in_repo(str(work_repo), "ga-feat") is None
    assert asr._real_has_built_branch("ga-feat") is False
    monkeypatch.setattr(asr, "_sh", lambda args, timeout=20: None)   # _sh's own timeout/exception shape
    assert asr._delivery_branch_in_repo(str(work_repo), "ga-feat") is None


@pytest.mark.parametrize("body", [
    "",                                              # empty file
    "GC_DELIVERY_BRANCH_PREFIXES=\"\"\n",             # empty list must not read as "no prefix counts"
    "GC_DELIVERY_BRANCH_PREFIXES=\"fix Feat/x\"\n",   # corrupt token
    "# GC_DELIVERY_BRANCH_PREFIXES=\"fix\"\n",        # only a comment
])
def test_a_corrupt_or_empty_lib_is_could_not_tell(tmp_path, monkeypatch, body):
    lib = tmp_path / "delivery-branch-patterns.sh"
    lib.write_text(body)
    monkeypatch.setattr(asr, "_delivery_branch_lib_path", lambda: str(lib))
    monkeypatch.setattr(asr, "_DELIVERY_PREFIXES", None, raising=False)
    monkeypatch.setattr(asr, "_bd_delivery_branch_prefixes", None, raising=False)
    assert asr._delivery_branch_prefixes() is None
    assert asr._delivery_branch_globs("ga-x") is None


@pytest.mark.parametrize("body", [
    None,                                            # the file is not there at all
    "",                                              # empty file
    "GC_DELIVERY_BRANCH_PREFIXES=\"\"\n",             # empty list
    "GC_DELIVERY_BRANCH_PREFIXES=\"fix Feat/x\"\n",   # corrupt token
])
def test_an_unusable_lib_is_logged_once_and_still_could_not_tell(tmp_path, monkeypatch, capsys, body):
    """Fail-open is allowed to be an answer, not to be silent: an unusable list makes every built
    bead read NOT built here, which the reconciler then reports as a failing dispatch. One line,
    naming the file, once per process — and the answer itself stays None (never [] / a fallback)."""
    lib = tmp_path / "delivery-branch-patterns.sh"
    if body is not None:
        lib.write_text(body)
    monkeypatch.setattr(asr, "_delivery_branch_lib_path", lambda: str(lib))
    monkeypatch.setattr(asr, "_DELIVERY_PREFIXES", None, raising=False)
    monkeypatch.setattr(asr, "_bd_delivery_branch_prefixes", None, raising=False)
    monkeypatch.setattr(asr, "_DELIVERY_LIB_WARNED", False)
    assert asr._delivery_branch_prefixes() is None
    assert asr._delivery_branch_prefixes() is None
    assert asr._delivery_branch_globs("ga-x") is None
    out = capsys.readouterr().out
    assert out.count("WARN ga-3ebneo") == 1, out
    assert str(lib) in out, out


def test_a_missing_lib_warns_once_across_many_probes(work_repo, monkeypatch, capsys):
    monkeypatch.setattr(asr, "_DELIVERY_LIB_WARNED", False)
    monkeypatch.setattr(asr, "_delivery_branch_lib_path", lambda: str(work_repo / "gone.sh"))
    for bead in ("ga-a", "ga-b", "ga-c"):
        assert asr._real_has_built_branch(bead) is False
        assert asr._matched_built_branch_ref(bead) is None
    out = capsys.readouterr().out
    assert out.count("WARN ga-3ebneo") == 1, out


def test_a_usable_lib_logs_nothing(work_repo, monkeypatch, capsys):
    monkeypatch.setattr(asr, "_DELIVERY_LIB_WARNED", False)
    assert asr._delivery_branch_prefixes()
    assert asr._delivery_branch_in_repo(str(work_repo), "ga-nothing") == ""
    assert "WARN ga-3ebneo" not in capsys.readouterr().out


# ── ga-2kaan2: delivery:pending-vm is a delivery retry in flight ──────────────
# story-delivery holds a story whose merge touches the voicebot while the dialer VM
# still runs old code: label delivery:pending-vm, story:approved + gate:passed LEFT
# ON, re-asked every cycle. Step 1 of story-delivery selects story:approved AND
# gate:passed together, so a reconciler that strips story:approved off a
# gate:passed bead (the "post-build" route) ends the re-asking for good — the hold
# would never be released and the story would sit there forever. delivery:failed
# already gets this carve-out (ga-kyvpk); pending-vm needs the same.
_HELD = ["story:approved", "gate:passed", "ctx:ready"]


@pytest.mark.parametrize("hold", ["delivery:failed", "delivery:pending-vm"])
def test_a_delivery_hold_is_left_alone_so_step1_keeps_re_asking(hold):
    assert asr._classify({"id": "ga-x", "labels": _HELD + [hold]}) == (None, None)


def test_without_a_hold_label_a_gate_passed_bead_still_routes_post_build():
    route, _signal = asr._classify({"id": "ga-x", "labels": _HELD})
    assert route == "post-build"


@pytest.mark.parametrize("hold", ["delivery:failed", "delivery:pending-vm"])
@pytest.mark.parametrize("parked", ["story:needs-human", "story:blocked", "story:done"])
def test_a_hold_does_not_override_a_bead_something_else_already_parked(hold, parked):
    """The carve-out must never become a way to keep a parked/finished bead 'in
    retry': once something else parked it, the normal post-build handling applies."""
    route, _signal = asr._classify({"id": "ga-x", "labels": _HELD + [hold, parked]})
    assert route == "post-build"


# ── ga-gm5rv5: whose queue does a needs-human route land in? ──────────────────
# The reconciler wrote story:needs-human for EVERY gate:needs-human* variant. Only
# :product is Athos's (bead_state.ATHOS_GATE_HUMAN_SUFFIXES — "rodar o máximo sem
# mim", ga-aprov); :technical/bare/routing/on-device are the Mayor's or the crew's.
# A technical park therefore carried a marker that reads as "waiting on a human"
# but named nobody, and wa-2362s2.2/.5 read as the Athos's on a card (06/10).
# Decision of the Mayor (06/10): story:needs-human ONLY for :product; a technical
# park gets next-action:mayor + a "Pergunta:" comment (the convention
# next-action-coordinator-alert.sh keys on), and the assignee is never touched.
import bead_state  # noqa: E402  (scripts/ is on sys.path via the module under test)


class _Writes:
    """What _route_bead did to the bead, observed through the module's own bd seams."""

    def __init__(self):
        self.adds, self.removes, self.comments, self.ledger = [], [], [], []
        self.notes = []
        self.fail_adds = set()
        self.fail_comment_prefixes = ()


@pytest.fixture
def writes(monkeypatch):
    w = _Writes()

    def _add(_root, bead_id, label):
        w.adds.append((bead_id, label))
        return label not in w.fail_adds

    monkeypatch.setattr(asr, "DRY_RUN", False)
    monkeypatch.setattr(asr, "_bd_label_add", _add)
    monkeypatch.setattr(asr, "_bd_label_remove",
                        lambda _r, b, label: w.removes.append((b, label)) or True)
    def _comment(_root, bead_id, text):
        if text.startswith(w.fail_comment_prefixes):
            return False
        w.comments.append((bead_id, text))
        return True

    monkeypatch.setattr(asr, "_bd_comment", _comment)
    monkeypatch.setattr(asr, "_do_notify", lambda msg, _prio: w.notes.append(msg))
    # hermetic: never append fixture rows to the production ledgers
    monkeypatch.setattr(asr, "_arc_ledger",
                        lambda name, data, **_kw: w.ledger.append((name, data)))
    return w


def _route(bead, writes):
    """classify + route exactly the way run_cycle does; returns (route_to, state)."""
    route_to, signal = asr._classify(bead)
    assert route_to == "needs-human", (route_to, signal)
    state = {}
    assert asr._route_bead("/rig", bead, route_to, signal, 1_000_000.0, state) is True
    return route_to, state


def _labels_after(bead, writes):
    labels = set(bead["labels"]) - {l for _b, l in writes.removes}
    return labels | {l for _b, l in writes.adds}


_TECH = ["story:approved", "gate:needs-human", "gate:needs-human:technical", "lane:small"]


def test_technical_park_is_never_stamped_story_needs_human(writes):
    _route({"id": "wa-2362s2.2", "assignee": None, "labels": list(_TECH)}, writes)
    assert ("wa-2362s2.2", "story:needs-human") not in writes.adds, writes.adds


def test_technical_park_names_the_mayor_with_next_action_and_a_pergunta(writes):
    _route({"id": "wa-2362s2.2", "assignee": None, "labels": list(_TECH)}, writes)
    assert ("wa-2362s2.2", "next-action:mayor") in writes.adds, writes.adds
    texts = [t for b, t in writes.comments if b == "wa-2362s2.2"]
    # next-action-coordinator-alert.sh picks the question by comment text startswith
    # "Pergunta:" — a Pergunta buried inside the audit comment is invisible to it.
    assert any(t.startswith("Pergunta:") for t in texts), texts


def test_technical_park_still_leaves_story_approved_and_keeps_the_gate_label(writes):
    """The vetoes of the Pilot / pool probes key on gate:needs-human* — the route must
    take story:approved off the bead and leave the gate label exactly where it is."""
    bead = {"id": "wa-2362s2.5", "assignee": None, "labels": list(_TECH)}
    _route(bead, writes)
    assert ("wa-2362s2.5", "story:approved") in writes.removes
    assert not [r for r in writes.removes if r[1].startswith("gate:needs-human")], writes.removes


def test_the_operator_notification_names_the_label_that_was_actually_written(writes):
    """The notify is the operator's only live view of a route: for a technical park it
    must not claim story:needs-human (the Athos's marker) when next-action:mayor is
    what landed on the bead."""
    _route({"id": "wa-2362s2.2", "assignee": None, "labels": list(_TECH)}, writes)
    assert len(writes.notes) == 1, writes.notes
    assert "next-action:mayor" in writes.notes[0], writes.notes
    assert "story:needs-human" not in writes.notes[0], writes.notes


def test_a_product_park_notification_still_names_story_needs_human(writes):
    bead = {"id": "wa-9", "assignee": None,
            "labels": ["story:approved", "gate:needs-human", "gate:needs-human:product"]}
    _route(bead, writes)
    assert len(writes.notes) == 1 and "story:needs-human" in writes.notes[0], writes.notes


def test_technical_park_is_never_the_athos_turn_by_any_label_it_writes(writes):
    bead = {"id": "wa-2362s2.2", "assignee": None, "labels": list(_TECH)}
    _route(bead, writes)
    after = _labels_after(bead, writes)
    assert "next-action:athos" not in after and not any(
        l.startswith("next-action:athos") for l in after), after
    derived = bead_state.derive({"id": bead["id"], "status": "open", "assignee": None,
                                 "labels": sorted(after)})
    assert derived["turn"] == "mayor", derived
    assert derived["state"] == "parked", derived


def test_a_live_crew_assignee_is_neither_cleared_nor_replaced(writes, monkeypatch):
    """Whoever already holds the bead keeps it: the route never clears or replaces an
    assignee (ga-gm5rv5), and — since ga-pa3c6h gave the reconciler a liveness probe for the
    UNASSIGNED case — a bead that already has an assignee needs no probe at all, so no
    subprocess of any kind runs for it."""
    calls = []
    monkeypatch.setattr(asr, "_sh", lambda cmd, **_kw: calls.append(cmd))
    _route({"id": "wa-2362s2.2", "assignee": "wa/crew/digo", "labels": list(_TECH)}, writes)
    assert ("wa-2362s2.2", "next-action:mayor") in writes.adds
    assert calls == [], calls


@pytest.mark.parametrize("variant", [
    "gate:needs-human:routing", "gate:needs-human:mayor-fixing",
    "gate:needs-human:on-device", "gate:needs-human:refused",
    "gate:needs-human:partial-delivery",
])
def test_every_non_product_gate_variant_is_the_mayors_not_the_athos(writes, variant):
    """bead_state decides who owns a variant; the reconciler must not keep its own
    shorter list of what is the Athos's."""
    assert variant.rsplit(":", 1)[1] not in bead_state.ATHOS_GATE_HUMAN_SUFFIXES
    _route({"id": "ga-v1", "labels": ["story:approved", "gate:needs-human", variant]}, writes)
    assert ("ga-v1", "story:needs-human") not in writes.adds, writes.adds
    assert ("ga-v1", "next-action:mayor") in writes.adds, writes.adds


def test_bare_gate_needs_human_is_not_a_product_decision(writes):
    _route({"id": "ga-v2", "labels": ["story:approved", "gate:needs-human"]}, writes)
    assert ("ga-v2", "story:needs-human") not in writes.adds
    assert ("ga-v2", "next-action:mayor") in writes.adds


def test_a_product_decision_still_reaches_the_athos_queue(writes):
    bead = {"id": "ga-p1", "labels": ["story:approved", "gate:needs-human:product"]}
    _route(bead, writes)
    assert ("ga-p1", "story:needs-human") in writes.adds, writes.adds
    assert ("ga-p1", "next-action:mayor") not in writes.adds, writes.adds
    assert ("ga-p1", "story:approved") in writes.removes


def test_product_plus_technical_is_still_a_product_decision(writes):
    """A product call must never be hidden from the Athos by a technical label that
    happens to sit beside it — the conservative reading wins."""
    _route({"id": "ga-p2", "labels": ["story:approved", "gate:needs-human",
                                      "gate:needs-human:technical",
                                      "gate:needs-human:product"]}, writes)
    assert ("ga-p2", "story:needs-human") in writes.adds
    assert ("ga-p2", "next-action:mayor") not in writes.adds


@pytest.mark.parametrize("labels", [["story:approved", "needs-human"],
                                    ["story:approved", "story:needs-human"]])
def test_a_marker_with_no_gate_variant_keeps_todays_route(writes, labels):
    """Nothing says whose it is → no new claim either way (can't-know is not 'mayor'):
    the legacy stamp stays exactly as before (scenarios c2/c3 of the selftest)."""
    _route({"id": "ga-u1", "labels": list(labels)}, writes)
    assert ("ga-u1", "story:needs-human") in writes.adds
    assert ("ga-u1", "next-action:mayor") not in writes.adds


def test_the_mayor_label_is_added_before_story_approved_is_removed(writes):
    """add-before-remove (IMPORTANT 3): a failed write must not leave the bead with no
    lifecycle label and no owner — and must not start the cooldown."""
    writes.fail_adds.add("next-action:mayor")
    bead = {"id": "wa-2362s2.2", "assignee": None, "labels": list(_TECH)}
    route_to, signal = asr._classify(bead)
    state = {}
    assert asr._route_bead("/rig", bead, route_to, signal, 1_000_000.0, state) is False
    assert ("wa-2362s2.2", "story:approved") not in writes.removes
    assert "wa-2362s2.2" not in state.get("routed", {})


def test_a_failed_pergunta_write_is_visible_in_the_notification_not_swallowed(writes):
    """The route itself landed (label added, story:approved removed, cooldown set) but
    the Mayor's question did not: the bead sits on next-action:mayor with no 'Pergunta:'.
    The reconciler cannot retry it (cooldown), so the failure has to be said out loud
    — a notify that reads like a clean route would hide a half-written one."""
    writes.fail_comment_prefixes = ("Pergunta:",)
    _route({"id": "wa-2362s2.2", "assignee": None, "labels": list(_TECH)}, writes)
    assert ("wa-2362s2.2", "next-action:mayor") in writes.adds
    assert not any(t.startswith("Pergunta:") for _b, t in writes.comments)
    assert len(writes.notes) == 1, writes.notes
    assert "Pergunta" in writes.notes[0] and "FAILED" in writes.notes[0], writes.notes


def test_a_written_pergunta_leaves_the_notification_clean(writes):
    _route({"id": "wa-2362s2.2", "assignee": None, "labels": list(_TECH)}, writes)
    assert any(t.startswith("Pergunta:") for _b, t in writes.comments)
    assert "FAILED" not in writes.notes[0], writes.notes


# ── ga-pa3c6h: who holds a technical park? ────────────────────────────────────
# The Mayor's rule (ga-gm5rv5): next-action:mayor, and the AUTHOR keeps (or gets back) the
# bead when the author is a live crew. wa-2362s2.2 sat 12.5h with no assignee until the Mayor
# restored digo-wa by hand. The reconciler had no way to ask "is the author alive?"; the
# question has three answers and only "alive" may write — "could not find out" is not "alive".
_DIGO = "digo-wa-gawispvrmmmf"          # the real created_by of wa-2362s2.1..5 (06/10)


class _Holder:
    """The holder step observed through the module's own seams: what `gc session list` says,
    what `bd assign` was asked, what the bead reads back, and the order things happened."""

    def __init__(self):
        self.live = frozenset()        # None = `gc session list` could not be asked
        self.probes = 0
        self.assigns = []
        self.assign_ok = True
        self.readback = "echo"         # AFTER an assign: "echo" = what was written; None = unreadable
        self.before = ""               # the fresh read BEFORE writing: "" = nobody, None = unreadable
        self.events = []


@pytest.fixture
def holder(writes, monkeypatch):
    h = _Holder()
    orig_add = asr._bd_label_add

    def _add(root, bead_id, label):
        h.events.append(("label+", label))
        return orig_add(root, bead_id, label)

    def _live():
        h.probes += 1
        return h.live

    def _assign(_root, bead_id, who):
        h.events.append(("assign", who))
        h.assigns.append((bead_id, who))
        return h.assign_ok

    def _read(_root, _bead_id):
        h.events.append(("read", None))
        if not h.assigns:
            return h.before
        if h.readback == "echo":
            return h.assigns[-1][1]
        return h.readback

    monkeypatch.setattr(asr, "_bd_label_add", _add)
    monkeypatch.setattr(asr, "_gc_live_sessions", _live)
    monkeypatch.setattr(asr, "_bd_assign", _assign)
    monkeypatch.setattr(asr, "_bd_read_assignee", _read)
    return h


def _park(created_by=_DIGO, assignee=None, labels=None, bead_id="wa-2362s2.2"):
    bead = {"id": bead_id, "assignee": assignee, "created_by": created_by,
            "labels": list(labels if labels is not None else _TECH)}
    return bead


def _pergunta(writes, bead_id="wa-2362s2.2"):
    texts = [t for b, t in writes.comments if b == bead_id and t.startswith("Pergunta:")]
    assert len(texts) == 1, texts
    return texts[0]


def test_a_live_author_gets_back_the_unassigned_technical_park(writes, holder):
    """The incident: wa-2362s2.2, created_by digo-wa-gawispvrmmmf (live), assignee null."""
    holder.live = frozenset({_DIGO, "digo-wa", "ga-wisp-vrmmmf"})
    _route(_park(), writes)
    assert holder.assigns == [("wa-2362s2.2", _DIGO)], holder.assigns
    assert ("wa-2362s2.2", "next-action:mayor") in writes.adds
    assert "crew viva" in _pergunta(writes) and _DIGO in _pergunta(writes)
    assert "NOT confirmed" not in writes.notes[0], writes.notes


def test_the_assignee_is_written_only_after_the_route_label_landed(writes, holder):
    """add-before-write: assigning first and then failing the label would leave a bead with
    an owner and no turn marker — the exact limbo the add-before-remove rule exists for."""
    holder.live = frozenset({_DIGO})
    _route(_park(), writes)
    kinds = [e[0] for e in holder.events]
    assert kinds.index("label+") < kinds.index("assign"), holder.events


def test_a_route_whose_label_failed_assigns_nothing(writes, holder):
    holder.live = frozenset({_DIGO})
    writes.fail_adds.add("next-action:mayor")
    bead = _park()
    route_to, signal = asr._classify(bead)
    assert asr._route_bead("/rig", bead, route_to, signal, 1_000_000.0, {}) is False
    assert holder.assigns == [] and holder.probes == 0


def test_an_author_who_is_not_live_gets_nothing_and_the_mayor_is_told_so(writes, holder):
    holder.live = frozenset({"peter-wa-gawispafn2dc", "gastown__mayor"})
    _route(_park(), writes)
    assert holder.assigns == []
    assert "não é uma crew viva" in _pergunta(writes), _pergunta(writes)
    assert ("wa-2362s2.2", "next-action:mayor") in writes.adds


def test_liveness_that_could_not_be_established_assigns_nothing_and_says_it_could_not(
        writes, holder):
    """Three answers, not two: 'could not ask' must not read as 'alive' (would assign on a
    guess) and must not read as 'dead' either (would tell the Mayor a live crew is gone)."""
    holder.live = None
    _route(_park(), writes)
    assert holder.assigns == []
    q = _pergunta(writes)
    assert "não consegui verificar" in q and "não é uma crew viva" not in q, q


def test_a_recycled_author_session_is_not_replaced_by_a_guessed_successor(writes, holder):
    """The author's own session is gone; another session of the same crew is up. The gate
    resolves the successor from what it RECORDED at submit time — a source bead records
    nothing, and a name-prefix match is how mila-wa-extra would become mila-wa."""
    holder.live = frozenset({"digo-wa", "digo-wa-gawispNEW123", "ga-wisp-new123"})
    _route(_park(created_by="digo-wa-gawispOLD999"), writes)
    assert holder.assigns == []
    assert "não adivinha sucessor" in _pergunta(writes), _pergunta(writes)


@pytest.mark.parametrize("author", [
    "gastown.dog-1", "dog-gawispx1", "gastown.dog", "wa-worker-gawispab", "wa-worker",
    "ps-worker-gawispcd", "digo-adhoc-e2510107f6", "claude-headless-1",
    "mayor", "gastown__mayor", "gastown.mayor", "deacon",
])
def test_a_pool_slot_or_a_coordinator_is_never_handed_a_park_and_is_not_probed(
        writes, holder, author):
    holder.live = frozenset({author})          # even when it IS live
    _route(_park(created_by=author), writes)
    assert holder.assigns == [], author
    assert holder.probes == 0, "no point asking gc about an identity that can never qualify"


@pytest.mark.parametrize("created_by", [None, "", "   ", "null", "None"])
def test_a_bead_that_records_no_author_is_left_alone(writes, holder, created_by):
    holder.live = frozenset({_DIGO})
    _route(_park(created_by=created_by), writes)
    assert holder.assigns == [] and holder.probes == 0
    assert "não registra autor" in _pergunta(writes)


def test_an_existing_assignee_is_kept_without_asking_anyone(writes, holder):
    holder.live = frozenset({_DIGO})
    _route(_park(assignee="peter-wa-gawispafn2dc"), writes)
    assert holder.assigns == [] and holder.probes == 0
    assert "mantido" in _pergunta(writes)


def test_a_product_park_is_never_assigned_to_anyone(writes, holder):
    """A product decision is the Athos's: it is routed to story:needs-human and the
    assignee is not this step's business."""
    holder.live = frozenset({_DIGO})
    _route(_park(labels=["story:approved", "gate:needs-human", "gate:needs-human:product"],
                 bead_id="ga-p1"), writes)
    assert holder.assigns == [] and holder.probes == 0
    assert ("ga-p1", "story:needs-human") in writes.adds


@pytest.mark.parametrize("labels", [["story:approved", "needs-human"],
                                    ["story:approved", "story:needs-human"]])
def test_a_marker_with_no_gate_variant_is_not_assigned_either(writes, holder, labels):
    holder.live = frozenset({_DIGO})
    _route(_park(labels=labels, bead_id="ga-u1"), writes)
    assert holder.assigns == [] and holder.probes == 0


def test_a_failed_assign_is_reported_not_swallowed_and_the_route_still_completes(
        writes, holder):
    holder.live = frozenset({_DIGO})
    holder.assign_ok = False
    _route(_park(), writes)
    assert ("wa-2362s2.2", "next-action:mayor") in writes.adds
    assert ("wa-2362s2.2", "story:approved") in writes.removes
    assert "o bd falhou" in _pergunta(writes), _pergunta(writes)
    assert len(writes.notes) == 1 and "NOT confirmed" in writes.notes[0], writes.notes


@pytest.mark.parametrize("readback, needle", [
    (None, "não consegui reler"),          # the read failed: say so, do not claim a failed write
    ("", "o bd mostra assignee ''"),        # the write did not stick
    ("someone-else", "o bd mostra assignee 'someone-else'"),
])
def test_an_assign_that_cannot_be_confirmed_on_re_read_is_flagged(writes, holder,
                                                                  readback, needle):
    holder.live = frozenset({_DIGO})
    holder.readback = readback
    _route(_park(), writes)
    assert needle in _pergunta(writes), _pergunta(writes)
    assert "NOT confirmed" in writes.notes[0], writes.notes


def test_a_holder_step_that_raises_costs_the_route_nothing(writes, holder, monkeypatch):
    def _boom(_bead):
        raise RuntimeError("probe exploded")

    monkeypatch.setattr(asr, "_park_holder", _boom)
    _route(_park(), writes)
    assert ("wa-2362s2.2", "next-action:mayor") in writes.adds
    assert holder.assigns == []
    assert "erro interno" in _pergunta(writes)
    assert "NOT confirmed" in writes.notes[0]


def test_an_assign_that_raises_costs_the_route_nothing_and_is_flagged(writes, holder,
                                                                      monkeypatch):
    holder.live = frozenset({_DIGO})

    def _boom(_root, _bead_id, _who):
        raise OSError("bd vanished")

    monkeypatch.setattr(asr, "_bd_assign", _boom)
    _route(_park(), writes)
    assert ("wa-2362s2.2", "next-action:mayor") in writes.adds
    assert ("wa-2362s2.2", "story:approved") in writes.removes
    assert "desconhecido" in _pergunta(writes)
    assert "NOT confirmed" in writes.notes[0]


def test_somebody_who_took_the_bead_since_the_sweep_is_not_overwritten(writes, holder):
    """The bead dict is minutes old. `bd assign` would silently replace whoever holds it
    now (the Mayor restoring the crew by hand is the very incident) - so the assignee is
    read fresh right before the write."""
    holder.live = frozenset({_DIGO})
    holder.before = "peter-wa-gawispafn2dc"
    _route(_park(), writes)
    assert holder.assigns == [], holder.assigns
    assert "peter-wa-gawispafn2dc" in _pergunta(writes) and "mantido" in _pergunta(writes)
    assert "NOT confirmed" not in writes.notes[0], writes.notes


def test_an_assignee_that_cannot_be_read_before_writing_is_never_overwritten(writes, holder):
    """Could not look != nobody is there: the write is skipped, and the Pergunta says why."""
    holder.live = frozenset({_DIGO})
    holder.before = None
    _route(_park(), writes)
    assert holder.assigns == [], holder.assigns
    assert "antes de gravar" in _pergunta(writes), _pergunta(writes)
    assert ("wa-2362s2.2", "next-action:mayor") in writes.adds


def test_the_fresh_read_happens_between_the_label_and_the_write(writes, holder):
    holder.live = frozenset({_DIGO})
    _route(_park(), writes)
    kinds = [e[0] for e in holder.events]
    assert kinds.index("label+") < kinds.index("read") < kinds.index("assign"), holder.events


def test_dry_run_assigns_nothing_and_asks_nobody(writes, holder, monkeypatch):
    holder.live = frozenset({_DIGO})
    monkeypatch.setattr(asr, "DRY_RUN", True)
    bead = _park()
    route_to, signal = asr._classify(bead)
    assert asr._route_bead("/rig", bead, route_to, signal, 1_000_000.0, {}) is True
    assert holder.assigns == [] and holder.probes == 0 and writes.adds == []


def test_the_parked_bead_with_its_author_back_is_still_the_mayors_turn(writes, holder):
    """Giving the bead back to its author must not turn it into 'the crew is executing':
    next-action:mayor outranks the assignee in bead_state.derive, and nothing here may
    reach the Athos's queue."""
    holder.live = frozenset({_DIGO})
    bead = _park()
    _route(bead, writes)
    after = _labels_after(bead, writes)
    derived = bead_state.derive({"id": bead["id"], "status": "open", "assignee": _DIGO,
                                 "labels": sorted(after)})
    assert derived["state"] == "parked" and derived["turn"] == "mayor", derived
    assert not any(l.startswith("next-action:athos") for l in after) and \
        "story:needs-human" not in after, after


# ── the two real subprocess paths (the seams above bypass them) ───────────────
class _Proc:
    def __init__(self, stdout="", returncode=0):
        self.stdout, self.returncode = stdout, returncode


def _sessions_json(*rows, prefix=""):
    import json as _json
    return prefix + _json.dumps({"sessions": list(rows)})


def test_live_identifiers_come_from_all_five_fields_and_drop_dead_sessions():
    out = _sessions_json(
        {"id": "ga-wisp-vrmmmf", "name": "digo-wa", "session_name": _DIGO, "alias": "digo-wa",
         "agent_name": "digo-wa", "state": "active", "closed": False},
        {"id": "x1", "name": "mila-wa", "session_name": "mila-wa-gawisp1", "state": "asleep"},
        {"id": "x2", "name": "gone-wa", "session_name": "gone-wa-gawisp2", "closed": True},
        {"id": "x3", "name": "drained-wa", "session_name": "drained-wa-g3", "state": "Drained"},
        {"id": "x4", "name": "nostate-wa", "session_name": "nostate-wa-g4"},
    )
    ids = asr._parse_live_session_identifiers(out)
    assert {_DIGO, "digo-wa", "ga-wisp-vrmmmf", "nostate-wa", "nostate-wa-g4"} <= ids
    assert not ({"mila-wa", "mila-wa-gawisp1", "gone-wa", "drained-wa"} & ids), ids


def test_a_missing_state_reads_as_alive_like_the_gates_own_predicate():
    ids = asr._parse_live_session_identifiers(_sessions_json({"session_name": "peter-wa-g1"}))
    assert ids == frozenset({"peter-wa-g1"})


def test_gc_warning_lines_before_the_json_are_tolerated():
    out = _sessions_json({"session_name": "peter-wa-g1", "state": "active"},
                         prefix="warning: builtin pack differs from the embedded copy\n")
    assert asr._parse_live_session_identifiers(out) == frozenset({"peter-wa-g1"})


def test_nobody_up_is_an_answer_but_garbage_is_not():
    assert asr._parse_live_session_identifiers('{"sessions": []}') == frozenset()
    for bad in ("", "   ", "not json", '{"error": "boom"}', '{"ok": false}',
                '{"sessions": null}', '{"sessions": "x"}', "[]",
                '{"sessions": [1, 2]}',                       # junk entries ≠ "nobody is up"
                '{"sessions": [{"session_name": "a-b"}, "x"]}',
                '{"sessions": []} trailing'):
        assert asr._parse_live_session_identifiers(bad) is None, bad


def test_a_failed_gc_call_is_unknown_never_an_empty_set(monkeypatch):
    monkeypatch.setattr(asr, "_gc_live_sessions", None)
    for proc in (None, _Proc("", 1), _Proc(_sessions_json({"session_name": "a-b"}), 1),
                 _Proc('{"error": "x"}', 0)):
        monkeypatch.setattr(asr, "_sh", lambda *_a, _p=proc, **_k: _p)
        assert asr._live_session_identifiers() is None, proc


def test_the_real_session_probe_asks_gc_for_json(monkeypatch):
    seen = []
    monkeypatch.setattr(asr, "_gc_live_sessions", None)
    monkeypatch.setattr(asr, "_sh", lambda args, **_k: seen.append(args) or _Proc(
        _sessions_json({"session_name": _DIGO, "state": "active"})))
    assert asr._live_session_identifiers() == frozenset({_DIGO})
    assert seen and seen[0][1:4] == ["session", "list", "--json"], seen


def test_the_real_assign_is_a_plain_bd_assign_never_forced_never_a_claim(monkeypatch):
    seen = []
    monkeypatch.setattr(asr, "DRY_RUN", False)
    monkeypatch.setattr(asr, "_bd_assign", None)
    monkeypatch.setattr(asr, "_sh", lambda args, **_k: seen.append(list(args)) or _Proc())
    assert asr._do_assign("/rig", "wa-1", _DIGO) is True
    assert seen == [[asr.BD_BIN, "-C", "/rig", "assign", "wa-1", _DIGO]], seen
    assert "--force" not in seen[0] and "--claim" not in seen[0]
    monkeypatch.setattr(asr, "_sh", lambda args, **_k: _Proc("", 1))
    assert asr._do_assign("/rig", "wa-1", _DIGO) is False
    monkeypatch.setattr(asr, "_sh", lambda args, **_k: None)
    assert asr._do_assign("/rig", "wa-1", _DIGO) is False


@pytest.mark.parametrize("stdout, rc, want", [
    ('[{"id": "wa-1", "assignee": "digo-wa-g1"}]', 0, "digo-wa-g1"),
    ('{"id": "wa-1", "assignee": "digo-wa-g1"}', 0, "digo-wa-g1"),
    ('[{"id": "wa-1", "assignee": null}]', 0, ""),            # a real, empty assignee
    ('[{"id": "wa-1"}]', 0, ""),
    ('warning: x\n[{"id": "wa-1", "assignee": "a-b"}]', 0, "a-b"),
    # a failed READ must never come back as "nobody":
    ('{"error": "no such issue"}', 0, None),                   # envelope: rc 0, no .id
    ('[{"id": "wa-OTHER", "assignee": "a-b"}]', 0, None),      # not this bead
    ('[]', 0, None), ('', 0, None), ('garbage', 0, None),
    ('[{"id": "wa-1", "assignee": "a-b"}]', 1, None),
])
def test_the_assignee_read_back_never_turns_a_failed_read_into_nobody(
        monkeypatch, stdout, rc, want):
    monkeypatch.setattr(asr, "_bd_read_assignee", None)
    monkeypatch.setattr(asr, "_sh", lambda args, **_k: _Proc(stdout, rc))
    assert asr._read_assignee("/rig", "wa-1") == want


def test_the_read_back_survives_a_bd_that_could_not_even_start(monkeypatch):
    monkeypatch.setattr(asr, "_bd_read_assignee", None)
    monkeypatch.setattr(asr, "_sh", lambda args, **_k: None)
    assert asr._read_assignee("/rig", "wa-1") is None
