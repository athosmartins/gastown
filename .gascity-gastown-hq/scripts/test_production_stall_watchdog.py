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
import subprocess
import sys
import tempfile
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


if __name__ == "__main__":
    unittest.main()
