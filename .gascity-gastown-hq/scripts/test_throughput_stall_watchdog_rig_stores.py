#!/usr/bin/env python3
"""test_throughput_stall_watchdog_rig_stores.py — regression tests for
throughput-stall-watchdog.py's ga-vjybz8 migration off a hardcoded HQ/WA/PS
RIG_ROOTS default onto the live `gc rig list` (via lib/rig_stores.py), plus the
_rig_name() exact-path fix that migration exposed (ga-wz03iq slice 2).

Hermetic: every scenario points GC_BIN at a fake local script (no real `gc`, no
network, no production paths touched). Loads a FRESH copy of the module per
test via importlib (module name deliberately NOT "__main__", so the file's own
`if __name__ == "__main__":` dispatch at the bottom never fires — main()/
_selftest() are never auto-invoked just by loading the file for introspection,
mirroring test_production_stall_watchdog.py's own loading pattern for its
hyphenated sibling).

Run: python3 -m unittest test_throughput_stall_watchdog_rig_stores -v
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

MOD_PATH = Path(__file__).resolve().parent / "throughput-stall-watchdog.py"

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
    # Hyphenated filename -> not a valid module name for `import`; load by path,
    # same technique test_production_stall_watchdog.py uses for its sibling.
    # Module name deliberately not "__main__" so the bottom `if __name__ ==
    # "__main__":` dispatch (which would call main()/_selftest()) never fires.
    spec = importlib.util.spec_from_file_location("tsw_test_copy", MOD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestDynamicRigRoots(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory(prefix="tsw-rig-stores-test-")
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

        # Defend against cross-test env leakage: no test in this file should
        # observe a real operator override unless it explicitly sets one.
        self._saved_env = os.environ.pop("TSW_RIG_ROOTS", None)

        # test_gc_failure_keeps_static_default_and_logs_degraded drives
        # _resolve_dynamic_rig_roots() down its failure branch, which shells
        # out to the real NOTIFY_BIN unconditionally (_sh([NOTIFY_BIN, ...])
        # — no injectable seam here, unlike gate-marker-rehome-janitor.py/
        # sling-task-janitor.py's _do_notify_fn). notify's own guard
        # (PYTEST_CURRENT_TEST/NOTIFY_DISABLE, see ~/.local/bin/notify) is
        # what actually suppresses the push; set it for every test in this
        # class so a real ntfy.sh notification never fires from this suite.
        self._saved_notify_disable = os.environ.get("NOTIFY_DISABLE")
        os.environ["NOTIFY_DISABLE"] = "1"

    def tearDown(self):
        self._tmpdir.cleanup()
        if self._saved_env is not None:
            os.environ["TSW_RIG_ROOTS"] = self._saved_env
        else:
            os.environ.pop("TSW_RIG_ROOTS", None)
        if self._saved_notify_disable is not None:
            os.environ["NOTIFY_DISABLE"] = self._saved_notify_disable
        else:
            os.environ.pop("NOTIFY_DISABLE", None)

    def test_import_alone_never_calls_gc(self):
        """Loading the module for introspection (no _resolve_dynamic_rig_roots()
        call) must never touch a live `gc rig list` — mirrors why
        test_production_stall_watchdog.py's identical loading pattern for its
        sibling file must stay safe to call from any test environment."""
        mod = _load_fresh()
        static_default = (
            "/Users/athos/gt/.gascity-gastown-hq:/Users/athos/gt/whatsapp_automation:"
            "/Users/athos/gt/property_scrapers"
        ).split(":")
        self.assertEqual(mod.RIG_ROOTS, static_default)
        self.assertIsNone(mod._TSW_LIVE_RIGS)

    def test_dynamic_success_includes_rig_outside_old_static_three(self):
        mod = _load_fresh()
        mod.GC_BIN = str(self.gc_multirig)
        mod._resolve_dynamic_rig_roots()
        self.assertIn("/fixture/lexbh", mod.RIG_ROOTS)
        self.assertEqual(len(mod.RIG_ROOTS), 7, "expected all 7 live rigs: %r" % mod.RIG_ROOTS)
        self.assertIsNotNone(mod._TSW_LIVE_RIGS)

    def test_rig_name_resolves_new_rig_by_exact_path_not_gascity_fallback(self):
        """The bug the bead flags explicitly: _rig_name's substring heuristic
        only recognizes whatsapp/property_scrapers/gascity, so lexbh/marketing/
        gastown/deacon would be miscounted under 'gascity' once RIG_ROOTS
        started including them. After dynamic resolution, exact-path lookup
        must take priority over the old heuristic."""
        mod = _load_fresh()
        mod.GC_BIN = str(self.gc_multirig)
        mod._resolve_dynamic_rig_roots()
        self.assertEqual(mod._rig_name("/fixture/lexbh"), "lexbh")
        self.assertEqual(mod._rig_name("/fixture/marketing"), "marketing")
        self.assertEqual(mod._rig_name("/fixture/gastown"), "gastown")
        self.assertEqual(mod._rig_name("/fixture/deacon"), "deacon")

    def test_rig_name_still_falls_back_to_heuristic_when_live_rigs_unavailable(self):
        """Zero behavior change for callers that never invoke
        _resolve_dynamic_rig_roots() (e.g. --selftest) — preserves every
        existing selftest assertion about _rig_name()."""
        mod = _load_fresh()
        self.assertIsNone(mod._TSW_LIVE_RIGS)
        self.assertEqual(mod._rig_name("/Users/athos/gt/whatsapp_automation"), "whatsapp_automation")
        self.assertEqual(mod._rig_name("/Users/athos/gt/property_scrapers"), "property_scrapers")
        self.assertEqual(mod._rig_name("/Users/athos/gt/.gascity-gastown-hq"), "gascity")
        self.assertEqual(mod._rig_name("/totally/unrecognized/path"), "gascity")

    def test_gc_failure_keeps_static_default_and_logs_degraded(self):
        mod = _load_fresh()
        mod.GC_BIN = str(self.gc_broken)
        static_default = list(mod.RIG_ROOTS)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            mod._resolve_dynamic_rig_roots()
        self.assertEqual(mod.RIG_ROOTS, static_default, "must never end up with fewer/no stores")
        self.assertIsNone(mod._TSW_LIVE_RIGS)
        self.assertIn("DEGRADED", buf.getvalue())

    def test_explicit_env_override_skips_derivation_entirely(self):
        """An operator-set TSW_RIG_ROOTS must win outright — the lib must never
        even be invoked, proven via a sentinel file a working fixture would
        otherwise create."""
        os.environ["TSW_RIG_ROOTS"] = "/explicit/a:/explicit/b"
        try:
            mod = _load_fresh()
            mod.GC_BIN = str(self.gc_sentinel)
            self.assertEqual(mod.RIG_ROOTS, ["/explicit/a", "/explicit/b"])
            mod._resolve_dynamic_rig_roots()
            self.assertEqual(mod.RIG_ROOTS, ["/explicit/a", "/explicit/b"])
            self.assertFalse(self.sentinel.exists(),
                              "gc rig list must never be invoked when TSW_RIG_ROOTS is set")
        finally:
            os.environ.pop("TSW_RIG_ROOTS", None)


if __name__ == "__main__":
    unittest.main()
