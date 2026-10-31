#!/usr/bin/env python3
"""Failure-injection tests for the FIX 8 mother shield of gate-recovery-watchdog.py (ga-vdac4cj.1).

`_bead_children_state(store, bid, referenced)` reads the children of a bead with ONE fresh
`bd list --parent <bid> --json --limit 0` and answers 'held' | 'none' | 'unknown'. The answer decides
whether FIX 8 strips a `gate:queued` label, so the read has three outcomes and only one of them may
lead to a write:

    has children in the gate -> 'held'     (label stays)
    has none                 -> 'none'     (the plain phantom: FIX 8 clears it, as before)
    could not tell           -> 'unknown'  (label stays, inert; the caller logs it)

Every shape below is a read that FAILS or answers something that is not a list of children; each must
land on 'unknown', never on 'none'. The watchdog's own `--selftest` also covers the end-to-end sweep;
these cases live in a file of their own so the failure injection is visible to the third-state reads check.

    python3 -m pytest scripts/test_grw_fix8_mother_children.py -q
"""
import importlib.util
import json
import os
import subprocess

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REFERENCED = {"ga-mom.1", "ga-mom.2"}


def _load_watchdog():
    spec = importlib.util.spec_from_file_location("gate_recovery_watchdog_under_test",
                                                  os.path.join(HERE, "gate-recovery-watchdog.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture()
def grw():
    return _load_watchdog()


def _answer(grw, monkeypatch, stdout="", rc=0, returns_none=False):
    """Make the watchdog's `sh` answer one canned thing; return (state, the args it was called with)."""
    seen = []

    def fake_sh(args, timeout=20, stdin=None):
        seen.append(list(args))
        if returns_none:
            return None  # sh() answers None when the command cannot run or times out
        return subprocess.CompletedProcess(args=args, returncode=rc, stdout=stdout)

    monkeypatch.setattr(grw, "sh", fake_sh)
    return grw._bead_children_state("/some/store", "ga-mom", REFERENCED), seen


def test_reads_children_fresh_and_unbounded(grw, monkeypatch):
    state, seen = _answer(grw, monkeypatch, stdout="[]")
    assert state == "none"
    assert seen == [["bd", "-C", "/some/store", "list", "--parent", "ga-mom", "--json", "--limit", "0"]]


def test_child_in_the_gate_is_held(grw, monkeypatch):
    rows = [{"id": "ga-mom.1", "status": "open"}]
    state, _ = _answer(grw, monkeypatch, stdout=json.dumps(rows))
    assert state == "held"


def test_empty_array_is_none_not_unknown(grw, monkeypatch):
    """A parent with no children answers `[]` with rc 0: that is a real 'none', the plain phantom."""
    state, _ = _answer(grw, monkeypatch, stdout="[]")
    assert state == "none"


def test_command_exits_nonzero_is_unknown(grw, monkeypatch):
    state, _ = _answer(grw, monkeypatch, stdout="[]", rc=1)
    assert state == "unknown"


def test_nonzero_exit_wins_over_a_plausible_body(grw, monkeypatch):
    rows = [{"id": "ga-other.1", "status": "open"}]
    state, _ = _answer(grw, monkeypatch, stdout=json.dumps(rows), rc=2)
    assert state == "unknown"


def test_command_cannot_run_or_times_out_is_unknown(grw, monkeypatch):
    state, _ = _answer(grw, monkeypatch, returns_none=True)
    assert state == "unknown"


def test_blank_output_with_rc_zero_is_unknown_not_none(grw, monkeypatch):
    for blank in ("", "   ", "\n"):
        state, _ = _answer(grw, monkeypatch, stdout=blank)
        assert state == "unknown", repr(blank)


def test_corrupt_json_is_unknown(grw, monkeypatch):
    for garbage in ("not json at all", "[{\"id\": \"ga-mom.1\"", "<html>502</html>", "null"):
        state, _ = _answer(grw, monkeypatch, stdout=garbage)
        assert state == "unknown", repr(garbage)


def test_error_envelope_instead_of_a_list_is_unknown(grw, monkeypatch):
    state, _ = _answer(grw, monkeypatch, stdout=json.dumps({"error": "database is locked"}))
    assert state == "unknown"


def test_a_row_that_is_not_an_object_poisons_the_whole_read(grw, monkeypatch):
    rows = [{"id": "ga-mom.1", "status": "open"}, "junk"]
    state, _ = _answer(grw, monkeypatch, stdout=json.dumps(rows))
    assert state == "unknown"
