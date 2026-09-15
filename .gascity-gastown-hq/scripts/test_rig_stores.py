#!/usr/bin/env python3
"""test_rig_stores.py — regression tests for lib/rig_stores.py (ga-vjybz8).

Hermetic: every scenario points `gc_bin` at a fake local script (no real `gc`,
no network, no production paths touched) — mirrors the shape of
lib/rig-stores.sh --selftest, including a 7-rig fixture (matching the real
`gc rig list --json` shape confirmed live 2026-09-15) with 4 rigs outside the
old static HQ/WA/PS default (lexbh, marketing, gastown, deacon) — the exact gap
ga-3xfndz/ga-wz03iq exists to close.

Run: python3 -m unittest test_rig_stores -v
"""
from __future__ import annotations

import os
import stat
import tempfile
import unittest
from pathlib import Path

from lib import rig_stores as rs

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


class TestRigStores(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory(prefix="rig-stores-test-")
        self.tmp = Path(self._tmpdir.name)

        self.gc_multirig = self.tmp / "gc-multirig"
        _write_shim(self.gc_multirig, 'case "$*" in\n'
                    '  *"rig list --json"*) cat <<\'JSON\'\n%s\nJSON\n    ;;\n'
                    '  *) echo \'{}\' ;;\nesac' % _MULTIRIG_JSON)

        self.gc_broken = self.tmp / "gc-broken"
        _write_shim(self.gc_broken, "exit 1")

        self.gc_hang = self.tmp / "gc-hang"
        _write_shim(self.gc_hang, "sleep 30")

        self.gc_bad_json = self.tmp / "gc-bad-json"
        _write_shim(self.gc_bad_json, "echo 'not json'")

        self.gc_bare_list = self.tmp / "gc-bare-list"
        _write_shim(self.gc_bare_list, 'echo \'[{"name":"gascity","path":"/fixture/gascity","prefix":"ga"}]\'')

        self.gc_empty_rigs = self.tmp / "gc-empty-rigs"
        _write_shim(self.gc_empty_rigs, "echo '{\"rigs\":[]}'")

        self.gc_dup_path = self.tmp / "gc-dup-path"
        _write_shim(self.gc_dup_path, 'echo \'{"rigs":[{"name":"a","path":"/fixture/x","prefix":"a"},'
                    '{"name":"b","path":"/fixture/x","prefix":"b"}]}\'')

    def tearDown(self):
        self._tmpdir.cleanup()

    # ── rig_stores() ─────────────────────────────────────────────────────────
    def test_success_includes_rig_outside_old_static_three(self):
        rigs = rs.rig_stores(str(self.gc_multirig))
        self.assertIsNotNone(rigs)
        paths = {r["path"] for r in rigs}
        self.assertIn("/fixture/lexbh", paths)
        self.assertEqual(len(rigs), 7, "expected all 7 live rigs, none dropped: %r" % rigs)

    def test_success_shape_has_prefix_path_name(self):
        rigs = rs.rig_stores(str(self.gc_multirig))
        lx = next(r for r in rigs if r["path"] == "/fixture/lexbh")
        self.assertEqual(lx, {"prefix": "lx", "path": "/fixture/lexbh", "name": "lexbh"})

    def test_dedup_by_path(self):
        rigs = rs.rig_stores(str(self.gc_dup_path))
        self.assertEqual(len(rigs), 1, "two entries sharing a path must collapse to one: %r" % rigs)

    def test_gc_failure_returns_none_never_partial(self):
        self.assertIsNone(rs.rig_stores(str(self.gc_broken)))

    def test_bad_json_returns_none(self):
        self.assertIsNone(rs.rig_stores(str(self.gc_bad_json)))

    def test_bare_list_envelope_tolerated(self):
        rigs = rs.rig_stores(str(self.gc_bare_list))
        self.assertEqual(rigs, [{"prefix": "ga", "path": "/fixture/gascity", "name": "gascity"}])

    def test_zero_rigs_is_failure_not_empty_success(self):
        # Contract: empty list is NEVER a "successful" return — always None.
        self.assertIsNone(rs.rig_stores(str(self.gc_empty_rigs)))

    def test_timeout_bounded(self):
        import time
        t0 = time.time()
        result = rs.rig_stores(str(self.gc_hang), timeout=2)
        elapsed = time.time() - t0
        self.assertIsNone(result)
        self.assertLess(elapsed, 10, "a hanging gc must be bounded by the timeout")

    def test_missing_binary_returns_none(self):
        self.assertIsNone(rs.rig_stores(str(self.tmp / "does-not-exist")))

    # ── rig_store_paths() ────────────────────────────────────────────────────
    def test_paths_wrapper_success(self):
        paths = rs.rig_store_paths(str(self.gc_multirig))
        self.assertIn("/fixture/lexbh", paths)
        self.assertEqual(len(paths), 7)

    def test_paths_wrapper_failure(self):
        self.assertIsNone(rs.rig_store_paths(str(self.gc_broken)))

    # ── rig_store_for_prefix() ───────────────────────────────────────────────
    def test_store_for_prefix_hit(self):
        rigs = rs.rig_stores(str(self.gc_multirig))
        self.assertEqual(rs.rig_store_for_prefix("lx", rigs), "/fixture/lexbh")

    def test_store_for_prefix_miss(self):
        rigs = rs.rig_stores(str(self.gc_multirig))
        self.assertIsNone(rs.rig_store_for_prefix("zz", rigs))

    def test_store_for_prefix_none_rigs(self):
        self.assertIsNone(rs.rig_store_for_prefix("lx", None))

    # ── rig_name_for_path() ──────────────────────────────────────────────────
    def test_name_for_path_hit(self):
        rigs = rs.rig_stores(str(self.gc_multirig))
        self.assertEqual(rs.rig_name_for_path("/fixture/gastown", rigs), "gastown")

    def test_name_for_path_miss(self):
        rigs = rs.rig_stores(str(self.gc_multirig))
        self.assertIsNone(rs.rig_name_for_path("/fixture/unknown", rigs))

    def test_name_for_path_none_rigs(self):
        self.assertIsNone(rs.rig_name_for_path("/fixture/gastown", None))


if __name__ == "__main__":
    unittest.main()
