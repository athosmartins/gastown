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
import re
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
