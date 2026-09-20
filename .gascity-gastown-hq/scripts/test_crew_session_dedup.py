#!/usr/bin/env python3
"""Tests for crew-session-dedup.py's singleton-template read (ga-878qeq).

THE BUG. load_singleton_templates() built the set of singleton templates
(max_active_sessions == 1) by parsing `gc config show` into two independent
lists -- every `name = "..."` line, every `max_active_sessions = N` line --
and pairing them by list position (zip). An [[agent]] block with no cap of
its own (gemini-worker, codex-test, and others have none) shifts every
following block's name onto an earlier block's cap. Measured live
(2026-09-20, dog gastown.dog-1): 68 name lines, 41 cap lines, 62 real
[[agent]] blocks -- the mismatch alone proves the shift -- and 12 agents
misclassified, including mayor (a real singleton, read as not one) and
polecat (a 5-session pool, read as a singleton).

Read once, at startup, into the bargain: a `gc config show` that failed on
the first read (common right after a boot) locked the daemon onto the
hardcoded 2026-06-06 fallback set for its entire run, with no way to heal
short of a restart -- the same class of bug as ga-d1q1kn's pool ceiling.

Only the process boundary (subprocess, the session-list shim) is faked here;
the parsing and fallback logic under test is the real code.
"""
import importlib.util
import json
import os
import subprocess
import time

import pytest

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
MOD_PATH = os.path.join(SCRIPTS, "crew-session-dedup.py")


def _done(argv, rc, out="", err=""):
    return subprocess.CompletedProcess(args=argv, returncode=rc, stdout=out, stderr=err)


def config_show(**agents):
    """Text shaped like `gc config show`: one [[agent]] block per agent, in
    the order given, with a max_active_sessions line only where the agent
    has one (real agents like gemini-worker and codex-test have none) plus
    the min_active_sessions line that follows it in the real output -- the
    cap parse must not mistake it for the cap."""
    blocks = []
    for name, cap in agents.items():
        lines = ["[[agent]]", 'name = "%s"' % name, 'scope = "city"',
                 'provider = "claude-headless"']
        if cap is not None:
            lines.append("max_active_sessions = %d" % cap)
        lines.append("min_active_sessions = 0")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks) + "\n"


class FakeCLI:
    """Stands in for subprocess.run. Records every call; refuses unknown ones."""

    def __init__(self):
        self.config = (0, config_show(mayor=1, dog=6, witness=1), "")
        self.config_script = []   # one-off answers consumed in order, one per call
        self.sessions = []
        self.calls = []

    def __call__(self, argv, **kwargs):
        self.calls.append(list(argv))
        if argv[:3] == ["gc", "config", "show"]:
            answer = self.config_script.pop(0) if self.config_script else self.config
            if isinstance(answer, BaseException):
                raise answer
            return _done(argv, *answer)
        if argv[0] == "bash" and argv[1].endswith("gc-session-list-cached.sh"):
            return _done(argv, 0, json.dumps({"sessions": self.sessions}))
        if argv[:3] == ["gc", "session", "close"]:
            return _done(argv, 0)
        if argv[0].endswith("/notify"):
            return _done(argv, 0)          # never send a real push from a test
        raise AssertionError("unexpected subprocess call: %r" % (argv,))


@pytest.fixture()
def csd():
    spec = importlib.util.spec_from_file_location("crew_session_dedup", MOD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture()
def fake(csd, monkeypatch):
    cli = FakeCLI()
    monkeypatch.setattr(csd.subprocess, "run", cli)
    monkeypatch.setattr(csd.time, "sleep", lambda s: None)
    return cli


# ---------------------------------------------------------------------------
# The reported bug: pairing by position shifts names onto the wrong cap
# ---------------------------------------------------------------------------

def test_a_capless_block_no_longer_shifts_later_names_onto_the_wrong_cap(csd, fake):
    """Break caught: the bead's own repro shape -- a capless agent block sits
    between two capped ones. The old zip(names, caps) pairing shifted mayor's
    name onto polecat's cap (5, not a singleton) and polecat's name onto
    control-dispatcher's cap (1, wrongly a singleton), and dropped
    control-dispatcher off the end entirely once the two lists it zipped
    went out of sync."""
    fake.config = (0, config_show(**{
        "gemini-worker": None,      # no cap: this is what shifts everything after it
        "mayor": 1,
        "polecat": 5,
        "codex-test": None,
        "control-dispatcher": 1,
    }), "")
    singletons = csd.load_singleton_templates()
    assert "mayor" in singletons
    assert "control-dispatcher" in singletons
    assert "polecat" not in singletons
    assert "gemini-worker" not in singletons
    assert "codex-test" not in singletons


def test_known_pools_are_excluded_even_if_misconfigured_as_singletons(csd, fake):
    fake.config = (0, config_show(**{"dog": 1, "gate-reviewer": 1, "mayor": 1}), "")
    singletons = csd.load_singleton_templates()
    assert "dog" not in singletons
    assert "gate-reviewer" not in singletons
    assert "mayor" in singletons


def test_min_active_sessions_line_is_never_mistaken_for_the_cap(csd, fake):
    """Break caught: a naive regex could grab the wrong `= N` line. Every real
    block in config_show() carries min_active_sessions = 0 right after the cap."""
    fake.config = (0, config_show(mayor=1), "")
    assert csd.load_singleton_templates() == {"mayor"}


# ---------------------------------------------------------------------------
# A failed read is not a fixed set in silence (same class as ga-d1q1kn)
# ---------------------------------------------------------------------------

FALLBACK = {"boot", "deacon", "mayor", "batista-lx", "batista-ps", "batista-wa",
            "digo-wa", "mila-wa", "oracle-wa", "peter-wa", "thies-wa",
            "claude", "control-dispatcher"}

# (id, what `gc config show` does, the reason the log line must give).
NO_ANSWER = [
    ("timeout", subprocess.TimeoutExpired(["gc", "config", "show"], 20), "TimeoutExpired"),
    ("gc-missing", FileNotFoundError("gc"), "FileNotFoundError"),
    ("exit-1-with-an-error", (1, "", "Error: city not ready"), "exit 1, Error: city not ready"),
    # a failed command's stdout is not an answer, even when it looks like one
    ("exit-1-with-a-config-on-stdout", (1, config_show(mayor=1), ""), "exit 1"),
    ("exit-0-empty", (0, "", ""), "no [[agent]] blocks"),
    ("exit-0-not-a-config", (0, "not toml at all\n", ""), "no [[agent]] blocks"),
]
NO_ANSWER_PARAMS = [pytest.param(answer, reason, id=name) for name, answer, reason in NO_ANSWER]


def _cap_lines(capsys):
    """The [DEDUP-CAP-*] lines printed since the last call."""
    return [l for l in capsys.readouterr().out.splitlines() if "[DEDUP-CAP-" in l]


def test_a_healthy_read_gives_the_configured_singletons_and_says_nothing(csd, fake, capsys):
    """Break caught: the fix must not make a healthy daemon noisy (silence = healthy)."""
    fake.config = (0, config_show(mayor=1, dog=6, witness=1), "")
    assert csd.load_singleton_templates() == {"mayor", "witness"}
    assert csd.load_singleton_templates() == {"mayor", "witness"}
    assert _cap_lines(capsys) == []


@pytest.mark.parametrize("answer,reason", NO_ANSWER_PARAMS)
def test_a_read_that_gives_no_answer_is_said_not_swallowed(csd, fake, capsys, answer, reason):
    """Break caught: a read that fails must not look identical to a read that
    found zero singletons -- both used to silently become the same fixed set."""
    fake.config = answer
    assert csd.load_singleton_templates() == FALLBACK
    lines = _cap_lines(capsys)
    assert len(lines) == 1, lines
    assert "[DEDUP-CAP-FALLBACK]" in lines[0]
    assert "hardcoded fallback" in lines[0] and reason in lines[0]


@pytest.mark.parametrize("answer,reason", NO_ANSWER_PARAMS)
def test_a_failed_read_keeps_the_last_good_set_not_the_hardcoded_one(csd, fake, capsys, answer, reason):
    """Break caught: a config that answered once, then hiccups, must not drop
    every agent it had confirmed back to the 2026-06-06 hardcoded guess."""
    fake.config = (0, config_show(mayor=1, dog=6, witness=1), "")
    assert csd.load_singleton_templates() == {"mayor", "witness"}
    fake.config = answer
    assert csd.load_singleton_templates() == {"mayor", "witness"}
    lines = _cap_lines(capsys)
    assert len(lines) == 1, lines
    assert "[DEDUP-CAP-FALLBACK]" in lines[0] and "last value it gave" in lines[0]
    assert reason in lines[0]


def test_the_fallback_is_said_once_per_episode_and_so_is_the_recovery(csd, fake, capsys):
    """Break caught: logging every failed read would put a line in the log
    every cycle for as long as the config stays unreadable."""
    down, up = (1, "", "Error: city not ready"), (0, config_show(mayor=1), "")
    fake.config_script = [down, down, down, up, down, up]
    results = [csd.load_singleton_templates() for _ in range(6)]
    assert results == [FALLBACK, FALLBACK, FALLBACK, {"mayor"}, {"mayor"}, {"mayor"}]
    out = capsys.readouterr().out
    assert out.count("[DEDUP-CAP-FALLBACK]") == 2     # never read; then the last good kept
    assert out.count("[DEDUP-CAP-RECOVERED]") == 2


def test_a_bug_in_the_read_cannot_end_the_daemon(csd, fake, monkeypatch, capsys):
    """Break caught: load_singleton_templates() is called every cycle from
    main()'s own loop, outside any try/except of its own. An exception
    escaping it would end the daemon and launchd would restart it into the
    same failure."""
    fake.config = (0, config_show(mayor=1, dog=6, witness=1), "")
    assert csd.load_singleton_templates() == {"mayor", "witness"}

    def broken():
        raise RuntimeError("parser broke")
    monkeypatch.setattr(csd, "_read_config_singletons", broken)
    assert csd.load_singleton_templates() == {"mayor", "witness"}   # last good kept
    lines = _cap_lines(capsys)
    assert len(lines) == 1, lines
    assert "RuntimeError" in lines[0] and "last value it gave" in lines[0]


# ---------------------------------------------------------------------------
# main() re-reads every cycle (ga-878qeq): a boot-time miss must heal itself
# ---------------------------------------------------------------------------

class _StopLoop(BaseException):
    """Raised from the patched time.sleep to end main()'s endless loop. A
    BaseException so main()'s `except Exception` around a cycle cannot
    swallow it."""


def _run_main_for(csd, monkeypatch, cycles):
    loop_sleeps = []

    def sleep(seconds):
        loop_sleeps.append(seconds)
        if len(loop_sleeps) >= cycles:
            raise _StopLoop
    monkeypatch.setattr(csd.time, "sleep", sleep)
    with pytest.raises(_StopLoop):
        csd.main()


def test_main_rereads_singletons_every_cycle_so_a_boot_time_miss_heals(csd, fake, monkeypatch):
    """Break caught: the daemon used to call load_singleton_templates() once,
    before the loop. A `gc config show` that fails on that very first call
    (plausible right after a boot) locked it onto the hardcoded fallback set
    for the rest of its run -- healing only on a restart. Now every cycle
    re-reads, so the very next cycle heals on its own."""
    fake.config_script = [(1, "", "Error: city not ready")]   # only the first read fails
    fake.config = (0, config_show(mayor=1), "")                # every later read sees this
    _run_main_for(csd, monkeypatch, cycles=3)
    assert sum(1 for c in fake.calls if c[:3] == ["gc", "config", "show"]) == 3
