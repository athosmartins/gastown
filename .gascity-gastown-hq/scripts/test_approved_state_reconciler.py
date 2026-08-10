#!/usr/bin/env python3
"""test_approved_state_reconciler.py — regression tests for
_extra_alarm_suppress_reason()'s pilot:text-veto:* recognition (ga-qt0mj).

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
