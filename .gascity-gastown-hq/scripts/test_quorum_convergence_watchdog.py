#!/usr/bin/env python3
"""test_quorum_convergence_watchdog.py — regression test for ga-c9gwhu.

_convene_quorum() called `bd update --metadata <json>` with a dict containing
ONLY the two quorum.* keys it was writing. Since --metadata REPLACES the
bead's entire metadata object server-side (rather than merging), this
silently wipes every other key already on the blocked bead (gc.routed_to,
gc.session_name, pilot.*, ...) the first time this path ever executes.
Confirmed dormant in production (zero quorums convened in 6+ weeks as of
2026-08-08) but real — this test proves the fix (--set-metadata, additive
per key) leaves pre-existing metadata intact.

Run: python3 -m unittest test_quorum_convergence_watchdog -v
"""
from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path

MOD_PATH = Path(__file__).resolve().parent / "quorum-convergence-watchdog.py"


def _load_qcw():
    # quorum-convergence-watchdog.py has hyphens, so it isn't a valid module
    # name for a plain `import` — load it by file path instead (same pattern
    # as test_production_stall_watchdog.py's _load_psw()).
    spec = importlib.util.spec_from_file_location("quorum_convergence_watchdog", MOD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestConveneQuorumPreservesMetadata(unittest.TestCase):
    """ga-c9gwhu: the bd update that stamps quorum.session_id on the blocked
    bead must not wipe metadata it didn't write."""

    @classmethod
    def setUpClass(cls):
        cls.qcw = _load_qcw()

    def setUp(self):
        # Bead already carries routing/session metadata BEFORE the quorum
        # path ever touches it — this is what a real blocked bead looks like.
        self.store = {
            "ga-blocked": {
                "gc.routed_to": "gastown.dog",
                "gc.session_name": "keepme",
            }
        }

        def fake_run(cmd, timeout=None):
            if len(cmd) >= 2 and cmd[1] == "create":
                new_id = "quorum-test-1"
                self.store[new_id] = {}
                return new_id
            if len(cmd) >= 2 and cmd[1] == "label":
                return "ok"
            if len(cmd) >= 3 and cmd[1] == "update":
                bead_id = cmd[2]
                bead = self.store.setdefault(bead_id, {})
                i = 3
                while i < len(cmd):
                    if cmd[i] == "--metadata":
                        bead.clear()
                        bead.update(json.loads(cmd[i + 1]))
                        i += 2
                    elif cmd[i] == "--set-metadata":
                        k, _, v = cmd[i + 1].partition("=")
                        bead[k] = v
                        i += 2
                    else:
                        i += 1
                return "ok"
            if len(cmd) >= 3 and cmd[1] == "session" and cmd[2] == "nudge":
                return "ok"
            return "ok"

        self._orig_run = self.qcw._run
        self.qcw._run = fake_run

    def tearDown(self):
        self.qcw._run = self._orig_run

    def test_convene_quorum_preserves_preexisting_metadata(self):
        bead = {"id": "ga-blocked", "title": "bloqueado ha 35min"}
        quorum_id = self.qcw._convene_quorum(bead, ["crewA", "crewB"], now=1_000_000.0)

        self.assertIsNotNone(quorum_id)
        marked = self.store["ga-blocked"]
        # Pre-existing keys must SURVIVE — this is exactly what a whole-object
        # --metadata replace would wipe.
        self.assertEqual(marked.get("gc.routed_to"), "gastown.dog")
        self.assertEqual(marked.get("gc.session_name"), "keepme")
        # New keys must have landed too.
        self.assertIn("quorum.session_id", marked)
        self.assertIn("quorum.convened_at", marked)


if __name__ == "__main__":
    unittest.main()
