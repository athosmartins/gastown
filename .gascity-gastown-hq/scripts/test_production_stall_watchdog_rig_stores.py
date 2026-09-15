#!/usr/bin/env python3
"""test_production_stall_watchdog_rig_stores.py — regression tests for
production-stall-watchdog.py's ga-vjybz8 migration off a hardcoded
HQ/WA/PS RIG_ROOTS default onto the live `gc rig list` (via lib/rig_stores.py),
the Python half of ga-wz03iq's shell-family fix.

Hermetic: every scenario points GC at a fake local script (no real `gc`, no
network, no production paths touched). Loads a FRESH copy of the module per
test via importlib (module name deliberately NOT "__main__", matching
test_production_stall_watchdog.py's own loading pattern for this same file —
so the bottom `if __name__ == "__main__":` dispatch never fires just from
loading it for introspection).

Run: python3 -m unittest test_production_stall_watchdog_rig_stores -v
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import stat
import tempfile
import unittest
from pathlib import Path

MOD_PATH = Path(__file__).resolve().parent / "production-stall-watchdog.py"

_MULTIRIG_JSON = """{"rigs":[
  {"name":"gascity","path":"/fixture/gascity","prefix":"ga"},
  {"name":"whatsapp_automation","path":"/fixture/wa","prefix":"wa"},
  {"name":"property_scrapers","path":"/fixture/ps","prefix":"ps"},
  {"name":"lexbh","path":"/fixture/lexbh","prefix":"lx"},
  {"name":"marketing","path":"/fixture/marketing","prefix":"ma"},
  {"name":"gastown","path":"/fixture/gastown","prefix":"gt"},
  {"name":"deacon","path":"/fixture/deacon","prefix":"dc"}
]}"""


def _write_shim(path: Path, body: str):
    path.write_text("#!/usr/bin/env bash\n" + body + "\n")
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def _load_fresh():
    spec = importlib.util.spec_from_file_location("psw_test_copy", MOD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestDynamicRigRoots(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory(prefix="psw-rig-stores-test-")
        self.tmp = Path(self._tmpdir.name)

        self.gc_multirig = self.tmp / "gc-multirig"
        _write_shim(self.gc_multirig, 'case "$*" in\n'
                    '  *"rig list --json"*) cat <<\'JSON\'\n%s\nJSON\n    ;;\n'
                    '  *) echo \'{}\' ;;\nesac' % _MULTIRIG_JSON)

        self.gc_broken = self.tmp / "gc-broken"
        _write_shim(self.gc_broken, "exit 1")

        self.sentinel = self.tmp / "sentinel"
        self.gc_sentinel = self.tmp / "gc-sentinel"
        _write_shim(self.gc_sentinel, 'touch "%s"\ncat <<\'JSON\'\n%s\nJSON' % (
                    self.sentinel, _MULTIRIG_JSON))

        self._saved_env = os.environ.pop("PROD_STALL_RIG_ROOTS", None)

        # test_gc_failure_keeps_static_default_and_logs_degraded drives
        # _resolve_dynamic_rig_roots() down its failure branch, which shells
        # out to the real NOTIFY binary unconditionally (sh([NOTIFY, ...]) —
        # no injectable seam here, unlike gate-marker-rehome-janitor.py/
        # sling-task-janitor.py's _do_notify_fn). notify's own guard
        # (PYTEST_CURRENT_TEST/NOTIFY_DISABLE, see ~/.local/bin/notify) is
        # what actually suppresses the push; set it for every test in this
        # class so a real ntfy.sh notification never fires from this suite.
        self._saved_notify_disable = os.environ.get("NOTIFY_DISABLE")
        os.environ["NOTIFY_DISABLE"] = "1"

    def tearDown(self):
        self._tmpdir.cleanup()
        if self._saved_env is not None:
            os.environ["PROD_STALL_RIG_ROOTS"] = self._saved_env
        else:
            os.environ.pop("PROD_STALL_RIG_ROOTS", None)
        if self._saved_notify_disable is not None:
            os.environ["NOTIFY_DISABLE"] = self._saved_notify_disable
        else:
            os.environ.pop("NOTIFY_DISABLE", None)

    def test_import_alone_never_calls_gc(self):
        """Loading the module for introspection alone (as
        test_production_stall_watchdog.py's _load_psw() already does, many
        times over, without ever setting PROD_STALL_RIG_ROOTS) must never
        touch a live `gc rig list` — that existing suite must stay fast and
        hermetic after this migration."""
        mod = _load_fresh()
        static_default = (
            "/Users/athos/gt:/Users/athos/gt/whatsapp_automation:"
            "/Users/athos/gt/property_scrapers"
        ).split(":")
        self.assertEqual(mod.RIG_ROOTS, static_default)

    def test_dynamic_success_includes_rig_outside_old_static_three(self):
        mod = _load_fresh()
        mod.GC = str(self.gc_multirig)
        mod._resolve_dynamic_rig_roots()
        self.assertIn("/fixture/lexbh", mod.RIG_ROOTS)
        self.assertEqual(len(mod.RIG_ROOTS), 7, "expected all 7 live rigs: %r" % mod.RIG_ROOTS)

    def test_gc_failure_keeps_static_default_and_logs_degraded(self):
        mod = _load_fresh()
        mod.GC = str(self.gc_broken)
        static_default = list(mod.RIG_ROOTS)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            mod._resolve_dynamic_rig_roots()
        self.assertEqual(mod.RIG_ROOTS, static_default, "must never end up with fewer/no roots")
        self.assertIn("DEGRADED", buf.getvalue())

    def test_explicit_env_override_skips_derivation_entirely(self):
        os.environ["PROD_STALL_RIG_ROOTS"] = "/explicit/a:/explicit/b"
        try:
            mod = _load_fresh()
            mod.GC = str(self.gc_sentinel)
            self.assertEqual(mod.RIG_ROOTS, ["/explicit/a", "/explicit/b"])
            mod._resolve_dynamic_rig_roots()
            self.assertEqual(mod.RIG_ROOTS, ["/explicit/a", "/explicit/b"])
            self.assertFalse(self.sentinel.exists(),
                              "gc rig list must never be invoked when PROD_STALL_RIG_ROOTS is set")
        finally:
            os.environ.pop("PROD_STALL_RIG_ROOTS", None)

    def test_existing_suite_pattern_still_overrides_after_resolution(self):
        """Confirms the existing test file's own idiom (`self.psw.RIG_ROOTS =
        [str(fixture_repo)]`, set AFTER loading, never calling
        _resolve_dynamic_rig_roots()) continues to be the effective value —
        i.e. this migration is additive and never fights that override."""
        mod = _load_fresh()
        mod.RIG_ROOTS = ["/some/test/fixture/repo"]
        self.assertEqual(mod.RIG_ROOTS, ["/some/test/fixture/repo"])


if __name__ == "__main__":
    unittest.main()
