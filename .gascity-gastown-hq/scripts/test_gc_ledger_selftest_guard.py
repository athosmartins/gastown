#!/usr/bin/env python3
"""test_gc_ledger_selftest_guard.py — regression tests for ga-9d7it9.

BUG (class, not instance): every daemon selftest that reached the REAL
gc_ledger_append wrote fixture ("phantom") rows into the LIVE production
ledgers (.gc/logs/human-touch.jsonl, flow-ledger.jsonl) AND overwrote the live
.gc/runtime/flow-authority.json with a fixture marker (escalated_at=1750000000,
i.e. June 2025). Measured 2026-09-20 on human-touch.jsonl (fixture = digits-only
hq-/wa-NNN bead id, or a same-second burst of >=20 rows from one daemon): 87% of
the approved-state-reconciler's rows and 45% of the throughput-stall watchdog's.
Fixing one selftest at a time (ga-9ekn2l stubs the reconciler's) leaves every
OTHER selftest — and every future one — defaulting to "write to production".

FIX under test: (1) the shared writer itself refuses to reach the live ledger dir
when the process is POSITIVELY a test run, and redirects to a throwaway dir;
(2) the two flow-authority.json writers consult the same predicate.

Three-state discipline (the ruler the gate applies): the guard only ever acts
on a POSITIVE test signal. "Can't tell" == production behaviour (write live).
Under a positive signal it never falls back to live — it fails inert.

Hermetic by construction: these tests never touch the real live ledger dir or the
real marker — they repoint LIVE_LEDGER_DIR / LEDGER_DIR / LIVE_FLOW_AUTHORITY_FILE /
each daemon's FLOW_AUTHORITY_FILE at a tmp_path.

Run: python3 -m pytest scripts/test_gc_ledger_selftest_guard.py -q
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import threading
import time
import types
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parent
MOD_PATH = SCRIPTS_DIR / "gc_ledger.py"
REAL_LIVE = "/Users/athos/gt/.gascity-gastown-hq/.gc/logs"
REAL_LIVE_FLOW_AUTHORITY = "/Users/athos/gt/.gascity-gastown-hq/.gc/runtime/flow-authority.json"


def _fresh_gc_ledger():
    """A private module instance per test: the guard keeps per-process state
    (scratch dir, 'noticed once' flag) that must not bleed between tests."""
    spec = importlib.util.spec_from_file_location("gc_ledger_under_test", MOD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture()
def gl(tmp_path, monkeypatch):
    """gc_ledger pointed at a FAKE live dir inside tmp_path (never the real one)."""
    monkeypatch.delenv("GC_LEDGER_DIR", raising=False)
    monkeypatch.delenv("GC_SELFTEST", raising=False)
    mod = _fresh_gc_ledger()
    fake_live = str(tmp_path / "fake-live-logs")
    mod.LIVE_LEDGER_DIR = fake_live
    mod.LEDGER_DIR = fake_live          # env unset => LEDGER_DIR is the live default
    mod._fake_live = fake_live
    yield mod
    # scratch dirs the guard created are its own responsibility; tolerate absence
    try:
        mod._cleanup_scratch()
    except Exception:
        pass


def _production_env(monkeypatch):
    """Make this process look like a production daemon: no pytest env, argv without --selftest."""
    monkeypatch.delenv("PYTEST_CURRENT_TEST", raising=False)
    monkeypatch.delenv("GC_SELFTEST", raising=False)
    monkeypatch.setattr(sys, "argv", ["some-daemon.py"])


def _lines(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(x) for x in f.read().splitlines() if x.strip()]


# ── the bug: a test run must NOT reach the live ledger dir ────────────────────
def test_pytest_run_never_writes_live_dir(gl):
    """PYTEST_CURRENT_TEST is set by pytest itself for the duration of this test.
    The default LEDGER_DIR is the (fake) live dir => the append must be diverted."""
    assert os.environ.get("PYTEST_CURRENT_TEST"), "premise: pytest sets this"
    gl.gc_ledger_append("human-touch", {"ts": "2026-09-20T00:00:00Z", "bead_id": "zz-9d7it9-probe-a"})
    assert not Path(gl._fake_live).exists(), (
        "live ledger dir was created/touched by a test run — the phantom-row bug")


def test_redirect_is_readable_through_ledger_path(gl):
    """The diverted write must still be observable in-process, so a selftest that
    asserts 'the daemon appended X' keeps working — ledger_path() follows it."""
    gl.gc_ledger_append("flow-ledger", {"ts": "t", "n": 1})
    gl.gc_ledger_append("flow-ledger", {"ts": "t", "n": 2})
    p = gl.ledger_path("flow-ledger")
    assert not p.startswith(gl._fake_live), "ledger_path() must report the diverted path"
    assert [r["n"] for r in _lines(p)] == [1, 2]


def test_argv_selftest_signal_diverts(gl, monkeypatch):
    """Embedded selftests run as `daemon.py --selftest` — no pytest env there."""
    monkeypatch.delenv("PYTEST_CURRENT_TEST", raising=False)
    monkeypatch.setattr(sys, "argv", ["approved-state-reconciler.py", "--selftest"])
    gl.gc_ledger_append("human-touch", {"ts": "t", "bead_id": "zz-9d7it9-probe-b"})
    assert not Path(gl._fake_live).exists()


def test_argv_self_test_spelling_diverts(gl, monkeypatch):
    monkeypatch.delenv("PYTEST_CURRENT_TEST", raising=False)
    monkeypatch.setattr(sys, "argv", ["x.py", "--self-test"])
    gl.gc_ledger_append("human-touch", {"ts": "t"})
    assert not Path(gl._fake_live).exists()


def test_explicit_env_switch_diverts(gl, monkeypatch):
    """GC_SELFTEST=1 is the explicit switch bash selftests can export."""
    monkeypatch.delenv("PYTEST_CURRENT_TEST", raising=False)
    monkeypatch.setattr(sys, "argv", ["x.py"])
    monkeypatch.setenv("GC_SELFTEST", "1")
    gl.gc_ledger_append("human-touch", {"ts": "t"})
    assert not Path(gl._fake_live).exists()


def _as_main(monkeypatch, spec_name):
    """Make sys.modules['__main__'] look like a process launched with `-m <spec_name>`
    (spec_name None = a plain script run, whose __main__.__spec__ is None)."""
    fake_main = types.ModuleType("__main__")
    fake_main.__spec__ = None if spec_name is None else types.SimpleNamespace(name=spec_name)
    monkeypatch.setitem(sys.modules, "__main__", fake_main)


def test_python_dash_m_unittest_diverts(gl, monkeypatch):
    """`python3 -m unittest` sets neither PYTEST_CURRENT_TEST nor a --selftest flag, and
    it is the documented runner of test_quorum_convergence_watchdog.py — whose _emit()
    calls the real gc_ledger_append. The runner module is __main__."""
    monkeypatch.delenv("PYTEST_CURRENT_TEST", raising=False)
    monkeypatch.setattr(sys, "argv", ["/py/lib/unittest/__main__.py", "test_quorum_convergence_watchdog"])
    _as_main(monkeypatch, "unittest.__main__")
    assert gl.selftest_signal() == "python -m unittest"
    gl.gc_ledger_append("human-touch", {"ts": "t"})
    assert not Path(gl._fake_live).exists()


@pytest.mark.parametrize("spec_name", [None, "some_daemon", "unittesting.tools", "pkg.unittest_helpers", ""])
def test_unittest_lookalikes_are_not_a_signal(gl, monkeypatch, spec_name):
    """A plain script (__spec__ None) or a package that merely CONTAINS the word must
    not be diverted: the top-level package name has to be exactly `unittest`."""
    _production_env(monkeypatch)
    _as_main(monkeypatch, spec_name)
    assert gl.selftest_signal() is None
    gl.gc_ledger_append("human-touch", {"ts": "t"})
    assert (Path(gl._fake_live) / "human-touch.jsonl").exists()


# ── the guard must not change production behaviour ────────────────────────────
def test_production_process_still_writes_live(gl, monkeypatch):
    """No positive signal => byte-for-byte the old behaviour: write to the live dir.
    (A guard that also swallowed real rows would lose production events silently.)"""
    _production_env(monkeypatch)
    gl.gc_ledger_append("human-touch", {"ts": "2026-09-20T00:00:00Z", "bead_id": "ga-real1"})
    live_file = Path(gl._fake_live) / "human-touch.jsonl"
    assert live_file.exists()
    assert _lines(live_file)[0]["bead_id"] == "ga-real1"
    assert gl.ledger_path("human-touch") == str(live_file)


def test_argv_lookalikes_are_not_a_signal(gl, monkeypatch):
    """Only the exact flags count. A prod daemon whose argv merely *contains* the
    word (a bead title, a path) must not be diverted into scratch."""
    _production_env(monkeypatch)
    monkeypatch.setattr(sys, "argv", ["daemon.py", "--label", "selftest-report", "/x/selftest.log"])
    gl.gc_ledger_append("human-touch", {"ts": "t"})
    assert (Path(gl._fake_live) / "human-touch.jsonl").exists()


def test_empty_selftest_env_is_not_a_signal(gl, monkeypatch):
    """GC_SELFTEST='' / '0' must read as OFF — an exported-but-falsy variable is the
    classic way a guard turns on by accident and eats production rows."""
    _production_env(monkeypatch)
    for off in ("", "0", "false"):
        monkeypatch.setenv("GC_SELFTEST", off)
        gl.gc_ledger_append("human-touch", {"ts": "t", "off": off})
    assert len(_lines(Path(gl._fake_live) / "human-touch.jsonl")) == 3


# ── already-hermetic selftests keep working untouched ─────────────────────────
def test_explicit_ledger_dir_is_honoured_even_under_test(gl, tmp_path, monkeypatch):
    """A selftest that already points GC_LEDGER_DIR at its own tmp dir is NOT the
    live dir: it must write exactly there (the redirect is only for live)."""
    own = str(tmp_path / "own-ledgers")
    gl.LEDGER_DIR = own
    gl.gc_ledger_append("human-touch", {"ts": "t", "who": "hermetic-selftest"})
    assert _lines(Path(own) / "human-touch.jsonl")[0]["who"] == "hermetic-selftest"
    assert not Path(gl._fake_live).exists()


def test_symlink_to_live_dir_is_still_live(gl, tmp_path):
    """Comparing raw strings would let `ln -s <live> /tmp/x; GC_LEDGER_DIR=/tmp/x`
    bypass the guard — compare resolved paths."""
    Path(gl._fake_live).mkdir(parents=True)
    link = tmp_path / "alias-of-live"
    link.symlink_to(gl._fake_live)
    gl.LEDGER_DIR = str(link)
    gl.gc_ledger_append("human-touch", {"ts": "t"})
    assert not (Path(gl._fake_live) / "human-touch.jsonl").exists()


# ── fail-inert: under a positive signal, an unusable scratch never falls back to live
def test_scratch_failure_never_falls_back_to_live(gl, monkeypatch):
    def boom(*a, **k):
        raise OSError("disk full")
    monkeypatch.setattr(gl.tempfile, "mkdtemp", boom)
    with pytest.raises(gl.LedgerError):
        gl.gc_ledger_append("human-touch", {"ts": "t"})
    assert not Path(gl._fake_live).exists()


def test_scratch_failure_fail_open_is_swallowed_and_still_not_live(gl, monkeypatch):
    def boom(*a, **k):
        raise OSError("disk full")
    monkeypatch.setattr(gl.tempfile, "mkdtemp", boom)
    gl.gc_ledger_append("human-touch", {"ts": "t"}, fail_open=True)   # must not raise
    assert not Path(gl._fake_live).exists()


# ── visibility: a silent redirect would hide a non-hermetic selftest forever ───
def test_redirect_announces_itself_once(gl, capsys):
    gl.gc_ledger_append("human-touch", {"ts": "t", "n": 1})
    gl.gc_ledger_append("human-touch", {"ts": "t", "n": 2})
    err = capsys.readouterr().err
    assert err.count("redirecting") == 1, err
    assert "LIVE" in err


# ── the public predicate other live-state writers (flow-authority) will share ───
def test_selftest_blocks_live_write_predicate(gl, tmp_path, monkeypatch):
    live_state = str(tmp_path / "runtime" / "flow-authority.json")
    other = str(tmp_path / "scratch" / "flow-authority.json")
    # positive signal + target IS the live artifact => blocked, with a reason
    reason = gl.selftest_blocks_live_write(live_state, live_state)
    assert reason and "PYTEST_CURRENT_TEST" in reason
    # positive signal + target is somewhere else (hermetic override) => allowed
    assert gl.selftest_blocks_live_write(other, live_state) is None
    # production => allowed
    _production_env(monkeypatch)
    assert gl.selftest_blocks_live_write(live_state, live_state) is None


# ── the shipped default really is the production path (guards the guard) ──────
def test_shipped_live_constant_is_the_canonical_ledger_dir(monkeypatch):
    """If someone edits LIVE_LEDGER_DIR the guard silently stops protecting the
    real dir. Pin it against the value every daemon relies on."""
    monkeypatch.delenv("GC_LEDGER_DIR", raising=False)
    mod = _fresh_gc_ledger()
    assert mod.LIVE_LEDGER_DIR == REAL_LIVE
    assert mod.LEDGER_DIR == REAL_LIVE


# ── concurrency: the scratch dir is minted once per process ───────────────────
def test_scratch_dir_is_created_once_under_concurrent_first_appends(gl, monkeypatch):
    """Two threads whose FIRST append lands together must not each mint a scratch dir
    (the loser's would leak past atexit). The mkdtemp stub sleeps so every thread is
    inside the 'is it created yet?' window at once — without the lock this is >1."""
    real_mkdtemp = gl.tempfile.mkdtemp
    calls = []

    def slow_mkdtemp(*a, **k):
        calls.append(1)
        time.sleep(0.05)
        return real_mkdtemp(*a, **k)

    monkeypatch.setattr(gl.tempfile, "mkdtemp", slow_mkdtemp)
    barrier = threading.Barrier(8)

    def worker(i):
        barrier.wait()
        gl.gc_ledger_append("human-touch", {"ts": "t", "i": i})

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(calls) == 1, f"scratch dir minted {len(calls)} times"
    assert len(_lines(gl.ledger_path("human-touch"))) == 8


# ── flow-authority.json: the OTHER live artifact a selftest used to clobber ────
# The readers (pipeline-throughput-heartbeat, production-stall-watchdog,
# funnel-flow-healer) DEFER their Mayor mail while an unexpired marker exists, so a
# fixture marker either mutes them or erases a real one — behaviour, not just noise.
_MARKER_WRITERS = [
    # (file, the `authority` value that daemon stamps into the marker)
    ("approved-state-reconciler.py", "approved-state-reconciler"),
    ("throughput-stall-watchdog.py", "throughput-stall-watchdog"),
]


def _daemon(filename, monkeypatch):
    """A fresh copy of a hyphenated daemon, loaded by path (never as __main__, so its
    own dispatch never fires). Returns (daemon_module, the gc_ledger module it imported)."""
    monkeypatch.syspath_prepend(str(SCRIPTS_DIR))
    spec = importlib.util.spec_from_file_location("fa_under_test_" + filename[:3], SCRIPTS_DIR / filename)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod, sys.modules["gc_ledger"]


def test_flow_authority_write_blocked_predicate(gl, tmp_path, monkeypatch):
    live = str(tmp_path / "runtime" / "flow-authority.json")
    gl.LIVE_FLOW_AUTHORITY_FILE = live
    reason = gl.flow_authority_write_blocked(live)
    assert reason and "PYTEST_CURRENT_TEST" in reason          # test run + live marker => blocked
    assert gl.flow_authority_write_blocked(str(tmp_path / "scratch.json")) is None   # hermetic override
    _production_env(monkeypatch)
    assert gl.flow_authority_write_blocked(live) is None       # production => never blocked


@pytest.mark.parametrize("filename,authority", _MARKER_WRITERS)
def test_daemon_default_marker_path_is_the_guarded_live_path(filename, authority, monkeypatch):
    """The guard protects gc_ledger.LIVE_FLOW_AUTHORITY_FILE; the daemon writes its OWN
    default. Two independent definitions of one path: if either is edited they drift
    apart and the guard silently stops protecting the real marker."""
    for env in ("GC_CITY_PATH", "ARC_FLOW_AUTHORITY_FILE", "TSW_FLOW_AUTHORITY_FILE"):
        monkeypatch.delenv(env, raising=False)
    daemon, gc_ledger = _daemon(filename, monkeypatch)
    assert daemon.FLOW_AUTHORITY_FILE == gc_ledger.LIVE_FLOW_AUTHORITY_FILE == REAL_LIVE_FLOW_AUTHORITY


@pytest.mark.parametrize("filename,authority", _MARKER_WRITERS)
def test_test_run_never_writes_the_live_marker(filename, authority, tmp_path, monkeypatch):
    """The bug: a selftest reached _write_flow_authority with the default path and
    overwrote the live marker (a 2025-timestamp fixture). Under pytest it must not."""
    daemon, gc_ledger = _daemon(filename, monkeypatch)
    live = tmp_path / "runtime" / "flow-authority.json"
    monkeypatch.setattr(gc_ledger, "LIVE_FLOW_AUTHORITY_FILE", str(live), raising=False)
    monkeypatch.setattr(daemon, "FLOW_AUTHORITY_FILE", str(live))
    daemon._write_flow_authority(1_750_000_000.0, "approved-starve:fixture")
    assert not live.exists(), "a test run overwrote the LIVE flow-authority marker"
    assert not live.parent.exists(), "a test run must not even create the live runtime dir"


@pytest.mark.parametrize("filename,authority", _MARKER_WRITERS)
def test_hermetic_marker_override_is_still_written(filename, authority, tmp_path, monkeypatch):
    """A selftest that points the marker at its own scratch path is NOT the live file and
    must keep working (scenarios that assert the marker's content stay valid)."""
    daemon, gc_ledger = _daemon(filename, monkeypatch)
    monkeypatch.setattr(gc_ledger, "LIVE_FLOW_AUTHORITY_FILE",
                        str(tmp_path / "live" / "flow-authority.json"), raising=False)
    own = tmp_path / "own" / "flow-authority.json"
    monkeypatch.setattr(daemon, "FLOW_AUTHORITY_FILE", str(own))
    daemon._write_flow_authority(1_750_000_000.0, "dim-x")
    marker = json.loads(own.read_text())
    assert marker["authority"] == authority and marker["dimension"] == "dim-x"


@pytest.mark.parametrize("filename,authority", _MARKER_WRITERS)
def test_production_marker_write_still_happens(filename, authority, tmp_path, monkeypatch):
    """No positive signal => the daemon writes the live marker exactly as before. A guard
    that also ate real escalation markers would un-defer every watchdog silently."""
    daemon, gc_ledger = _daemon(filename, monkeypatch)
    live = tmp_path / "runtime" / "flow-authority.json"
    monkeypatch.setattr(gc_ledger, "LIVE_FLOW_AUTHORITY_FILE", str(live), raising=False)
    monkeypatch.setattr(daemon, "FLOW_AUTHORITY_FILE", str(live))
    _production_env(monkeypatch)
    daemon._write_flow_authority(1_750_000_000.0, "real-escalation")
    assert json.loads(live.read_text())["authority"] == authority


def test_every_flow_authority_writer_calls_the_guard():
    """Class tripwire: a NEW daemon that opens a flow-authority file for writing without
    consulting the guard reintroduces the bug. Fixed-name detection can't see every
    spelling, so the two known writers must be FOUND (a regex that silently matches
    nothing would make this pass vacuously)."""
    writes = re.compile(r"""open\(\s*_?[A-Za-z_]*FLOW_AUTHORITY[A-Za-z_]*\s*,\s*["']w""")
    found = {}
    for p in sorted(SCRIPTS_DIR.glob("*.py")):
        if p.name.startswith("test_"):
            continue
        text = p.read_text(encoding="utf-8", errors="replace")
        if writes.search(text):
            found[p.name] = "flow_authority_write_blocked" in text
    assert {"approved-state-reconciler.py", "throughput-stall-watchdog.py"} <= set(found), found
    unguarded = sorted(n for n, guarded in found.items() if not guarded)
    assert not unguarded, f"writes flow-authority without flow_authority_write_blocked(): {unguarded}"
