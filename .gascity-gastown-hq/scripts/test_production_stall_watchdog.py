#!/usr/bin/env python3
"""test_production_stall_watchdog.py — regression tests for deploy_block()'s
shallow-clone handling (ga-1tj73).

Hermetic: builds real temporary git repos under a tempdir (no network, no
production paths touched). Uses `file://` clone URLs deliberately — git
silently IGNORES --depth for plain local-path clones (verified empirically
while writing this test), so a `file://` URL is required to actually produce
a shallow checkout to test against.

Run: python3 -m unittest test_production_stall_watchdog -v
"""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

MOD_PATH = Path(__file__).resolve().parent / "production-stall-watchdog.py"


def _load_psw():
    # production-stall-watchdog.py has hyphens, so it isn't a valid module
    # name for a plain `import` — load it by file path instead.
    spec = importlib.util.spec_from_file_location("production_stall_watchdog", MOD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _run(*args, cwd=None):
    r = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("%s failed: %s" % (args, r.stderr))
    return r.stdout


class TestDeployBlockShallow(unittest.TestCase):
    """Covers ga-1tj73: a shallow git checkout was misreported as
    'DIVERGIDO ahead=N — precisa rebase deliberado' (a real production
    incident: ahead=4869 behind=6), inviting a dangerous manual rebase for
    something `git fetch --unshallow` fixes safely."""

    @classmethod
    def setUpClass(cls):
        cls.psw = _load_psw()

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory(prefix="psw-shallow-test-")
        self.tmp = Path(self._tmpdir.name)
        self.bare = self.tmp / "origin.git"
        _run("git", "init", "--bare", "-q", str(self.bare))

        seed = self.tmp / "seed"
        _run("git", "clone", "-q", "file://%s" % self.bare, str(seed))
        _run("git", "-C", str(seed), "config", "user.email", "t@t.com")
        _run("git", "-C", str(seed), "config", "user.name", "t")
        for i in range(5):
            (seed / ("f%d.txt" % i)).write_text(str(i))
            _run("git", "-C", str(seed), "add", ".")
            _run("git", "-C", str(seed), "commit", "-q", "-m", "c%d" % i)
        _run("git", "-C", str(seed), "branch", "-M", "main")
        _run("git", "-C", str(seed), "push", "-q", "origin", "HEAD:main")
        _run("git", "-C", str(self.bare), "symbolic-ref", "HEAD", "refs/heads/main")

        # Isolate from the real environment: point RIG_ROOTS/REMOTE/BRANCH at
        # our sandbox on every test, never the real city/rig paths.
        self.psw.REMOTE = "origin"
        self.psw.BRANCH = "main"
        self.psw.DEPLOY_BLOCK_MIN_AHEAD = 1

    def tearDown(self):
        self._tmpdir.cleanup()

    def _clone(self, name, depth=None):
        dest = self.tmp / name
        args = ["git", "clone", "-q"]
        if depth:
            args += ["--depth", str(depth)]
        args += ["file://%s" % self.bare, str(dest)]
        _run(*args)
        return dest

    def test_healthy_full_clone_not_blocked(self):
        healthy = self._clone("healthy")
        self.psw.RIG_ROOTS = [str(healthy)]
        self.assertIsNone(self.psw.deploy_block())

    def test_shallow_clone_reports_shallow_not_divergido(self):
        shallow = self._clone("shallow", depth=1)
        self.assertEqual(_run("git", "-C", str(shallow), "rev-parse",
                               "--is-shallow-repository").strip(), "true")
        self.psw.RIG_ROOTS = [str(shallow)]
        result = self.psw.deploy_block()
        self.assertIsNotNone(result)
        self.assertIn("SHALLOW", result)
        self.assertIn("--unshallow", result)
        self.assertNotIn("DIVERGIDO", result)

    def test_shallow_clone_recovers_after_unshallow(self):
        shallow = self._clone("shallow", depth=1)
        self.psw.RIG_ROOTS = [str(shallow)]
        self.assertIsNotNone(self.psw.deploy_block())  # confirm flagged first

        _run("git", "-C", str(shallow), "fetch", "origin", "--unshallow", "-q")
        self.assertIsNone(self.psw.deploy_block())

    def test_real_divergence_still_detected(self):
        """Regression guard: the shallow check must not swallow genuine
        unpushed-commit detection — that's the dimension this watchdog
        exists for (the 2026-06-18 2h stall)."""
        diverged = self._clone("diverged")
        _run("git", "-C", str(diverged), "config", "user.email", "t@t.com")
        _run("git", "-C", str(diverged), "config", "user.name", "t")
        (diverged / "local.txt").write_text("local change")
        _run("git", "-C", str(diverged), "add", ".")
        _run("git", "-C", str(diverged), "commit", "-q", "-m", "local unpushed commit")

        self.psw.RIG_ROOTS = [str(diverged)]
        result = self.psw.deploy_block()
        self.assertIsNotNone(result)
        self.assertIn("AHEAD", result)
        self.assertNotIn("SHALLOW", result)


class TestStuckExecutionWho(unittest.TestCase):
    """Covers ga-5r96t: stuck_execution() must name the ASSIGNEE — whoever is
    actually holding the stuck in_progress slot, the thing `gc session
    peek/kill` can act on — as the stuck party. The owner is just who created
    the bead (often a human with no session to peek/kill); a real incident
    had the watchdog telling an operator to kill the bead creator's
    nonexistent session while the actual stuck session (a gate-reviewer) went
    unnamed."""

    @classmethod
    def setUpClass(cls):
        cls.psw = _load_psw()

    def setUp(self):
        self._orig_sh = self.psw.sh
        self._orig_stuck_sec = self.psw.STUCK_EXEC_SEC
        self.psw.STUCK_EXEC_SEC = 60  # deterministic 1min threshold for the test

    def tearDown(self):
        self.psw.sh = self._orig_sh
        self.psw.STUCK_EXEC_SEC = self._orig_stuck_sec

    def _stub_bd_list(self, bead):
        payload = json.dumps([bead])

        def _fake_sh(args, timeout=20):
            return subprocess.CompletedProcess(args=args, returncode=0, stdout=payload, stderr="")

        self.psw.sh = _fake_sh

    def test_assignee_and_owner_diverge_reports_assignee(self):
        """AC1: bead com assignee=<sessão> e owner=<humano> reporta a SESSÃO
        como travada (o flagrante real: ga-vvmc4, owner=athosmartins@gmail.com,
        assignee=gate-reviewer-adhoc-a38fd89154)."""
        self._stub_bd_list({
            "id": "ga-vvmc4",
            "owner": "athosmartins@gmail.com",
            "assignee": "gate-reviewer-adhoc-a38fd89154",
            "updated_at": "1970-01-01T00:00:00Z",
        })
        result = self.psw.stuck_execution(now=100000.0)
        self.assertIsNotNone(result)
        self.assertIn(
            "ga-vvmc4 (assignee=gate-reviewer-adhoc-a38fd89154 "
            "(owner=athosmartins@gmail.com)) parado há", result)

    def test_no_assignee_falls_back_to_owner(self):
        """AC2: bead sem assignee cai no owner — comportamento atual
        preservado para o caso em que não há sessão nenhuma segurando o slot."""
        self._stub_bd_list({
            "id": "ga-orphan",
            "owner": "athosmartins@gmail.com",
            "assignee": None,
            "updated_at": "1970-01-01T00:00:00Z",
        })
        result = self.psw.stuck_execution(now=100000.0)
        self.assertIsNotNone(result)
        self.assertIn("ga-orphan (owner=athosmartins@gmail.com) parado há", result)

    def test_both_empty_reports_unknown(self):
        """AC3: owner e assignee ambos ausentes → '?', nunca uma string vazia
        ou um valor que pareça um dado real."""
        self._stub_bd_list({
            "id": "ga-noone",
            "owner": "",
            "assignee": "",
            "updated_at": "1970-01-01T00:00:00Z",
        })
        result = self.psw.stuck_execution(now=100000.0)
        self.assertIsNotNone(result)
        self.assertIn("ga-noone (?) parado há", result)


class TestStuckExecutionCanonicalPark(unittest.TestCase):
    """Covers ga-qhca1: STUCK_EXEC_EXCLUDE_LABELS was a private 2-label park
    vocabulary that went stale hours after ga-e5tn8 patched it — it alarmed
    'STALL CONFIRMADO' on ga-w4k2z, which carries needs:engine-window,
    no-auto-dispatch (no 'pilot:' prefix) and pool:refused:engine-rebuild-
    required, none of which were in the list. scripts/bead_state.py is the
    city's single canonical park vocabulary; this dimension must defer to it
    instead of maintaining its own copy."""

    @classmethod
    def setUpClass(cls):
        cls.psw = _load_psw()

    def setUp(self):
        self._orig_sh = self.psw.sh
        self._orig_stuck_sec = self.psw.STUCK_EXEC_SEC
        self.psw.STUCK_EXEC_SEC = 60  # deterministic 1min threshold for the test

    def tearDown(self):
        self.psw.sh = self._orig_sh
        self.psw.STUCK_EXEC_SEC = self._orig_stuck_sec

    def _stub_bd_list(self, bead):
        payload = json.dumps([bead])

        def _fake_sh(args, timeout=20):
            return subprocess.CompletedProcess(args=args, returncode=0, stdout=payload, stderr="")

        self.psw.sh = _fake_sh

    def test_ga_w4k2z_labels_excluded_via_canonical_model(self):
        """The exact real-world miss: none of these 3 labels are in the old
        hardcoded STUCK_EXEC_EXCLUDE_LABELS set, but all resolve to
        state=='parked' under bead_state.derive() (needs:engine-window and
        pool:refused are PARK_PREFIXES; no-auto-dispatch is PARK_EXACT)."""
        self._stub_bd_list({
            "id": "ga-w4k2z",
            "assignee": "some-crew",
            "labels": ["needs:engine-window", "no-auto-dispatch",
                       "pool:refused:engine-rebuild-required"],
            "updated_at": "1970-01-01T00:00:00Z",
        })
        result = self.psw.stuck_execution(now=100000.0)
        self.assertIsNone(result)

    def test_old_exclude_labels_still_excluded(self):
        """Regression guard: the pre-existing vocabulary (pilot:no-auto-dispatch,
        story:awaiting-external-merge — ga-e5tn8) must keep working after the
        swap to the canonical model."""
        self._stub_bd_list({
            "id": "ga-old1",
            "assignee": "some-crew",
            "labels": ["story:awaiting-external-merge"],
            "updated_at": "1970-01-01T00:00:00Z",
        })
        self.assertIsNone(self.psw.stuck_execution(now=100000.0))

    def test_genuinely_stuck_bead_still_flagged(self):
        """Regression guard: a bead with no park label at all must still
        flag — the canonical swap must not become a blanket suppressor."""
        self._stub_bd_list({
            "id": "ga-reallystuck",
            "assignee": "some-crew",
            "labels": [],
            "updated_at": "1970-01-01T00:00:00Z",
        })
        result = self.psw.stuck_execution(now=100000.0)
        self.assertIsNotNone(result)
        self.assertIn("ga-reallystuck", result)


class TestMergeStallQuietHours(unittest.TestCase):
    """Covers ga-lda92s: merge_stall() didn't know about quiet hours (00h-08h
    local, ga-dxyvxr) — the deliberate overnight admission pause read as
    "no merge for MERGE_STALL_SEC" and fired a false stall. The fix discounts
    quiet-hours time from the elapsed-since-last-merge clock rather than
    blanket-silencing the whole window (which would trade this false-positive
    for a false-negative: a real stall starting 00h30 would go unseen for
    7h30 — see quiet_hours.elapsed_adjustment's own docstring)."""

    @classmethod
    def setUpClass(cls):
        cls.psw = _load_psw()

    def setUp(self):
        self._orig_file_fresh = self.psw.file_fresh
        self._orig_tail_lines = self.psw.tail_lines
        self._orig_sh = self.psw.sh
        self._orig_merge_stall_sec = self.psw.MERGE_STALL_SEC
        self.psw.file_fresh = lambda path, max_age, now: True
        self.psw.sh = lambda args, timeout=20: subprocess.CompletedProcess(
            args=args, returncode=0, stdout="[]", stderr="")
        self.psw.MERGE_STALL_SEC = 10800  # 3h, matches the real PROD_STALL_MERGE_SEC default
        self._today = time.strftime("%Y-%m-%d")

    def tearDown(self):
        self.psw.file_fresh = self._orig_file_fresh
        self.psw.tail_lines = self._orig_tail_lines
        self.psw.sh = self._orig_sh
        self.psw.MERGE_STALL_SEC = self._orig_merge_stall_sec
        import os as _os
        _os.environ.pop("QUIET_HOURS_OVERRIDE", None)

    def _at(self, hms):
        return time.mktime(time.strptime("%s %s" % (self._today, hms), "%Y-%m-%d %H:%M:%S"))

    def _stub_log(self, merge_ts_epoch):
        merge_line = "[%s] [quality-gate-dispatcher] Gate PASSED: branch=crew/x tier=CODE\n" % \
            time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(merge_ts_epoch))
        queued_line = "[%s] [quality-gate-dispatcher] Found 2 queued marker(s)\n" % \
            time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(merge_ts_epoch))
        self.psw.tail_lines = lambda path, n: [merge_line, queued_line]

    def test_quiet_hours_explains_stale_merge_not_a_stall(self):
        """Raw gap 00:30 -> 08:05 = 455min > 180min (MERGE_STALL_SEC=3h), but
        quiet hours (00h-08h) explains ~450 of those minutes — effective gap
        ~5min → NOT a stall (None)."""
        self._stub_log(self._at("00:30:00"))
        result = self.psw.merge_stall(now=self._at("08:05:00"))
        self.assertIsNone(result, "quiet-hours-explained gap must not report a stall, got: %r" % (result,))

    def test_override_open_forces_real_stall(self):
        """Same-night construction, but the live signal reads OPEN (override)
        while 'now' is still inside tonight's window → the override-safety
        check must NOT trust today's portion → stall still fires. Literal
        bug-AC bidirectional pair with the QUIET case above."""
        import os as _os
        _os.environ["QUIET_HOURS_OVERRIDE"] = "OPEN"
        yesterday_2300 = self._at("00:00:00") - 3600  # yesterday 23:00
        self._stub_log(yesterday_2300)
        result = self.psw.merge_stall(now=self._at("03:00:00"))
        self.assertIsNotNone(result, "OPEN-override gap must still report a stall (fix must not be a blanket mute)")

    def test_daytime_gap_unaffected(self):
        """Gap entirely during the day (no quiet-window overlap at all) →
        adjustment is a no-op, stall fires exactly as before this fix."""
        self._stub_log(self._at("09:00:00"))
        result = self.psw.merge_stall(now=self._at("14:00:00"))
        self.assertIsNotNone(result, "ordinary daytime gap has nothing to discount, must still report a stall")


if __name__ == "__main__":
    unittest.main()
