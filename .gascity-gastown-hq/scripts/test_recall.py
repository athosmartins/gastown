#!/usr/bin/env python3
"""test_recall.py — unit + regression tests for recall_lib.py (ga-ps28g).

Hermetic: no live `bd`/Dolt/network calls. The retrieval-quality regression
test uses a frozen 80-bead fixture (20 real targets from the ga-ps28g
experiment's queries.json + 60 real decoys, testdata/recall_fixture.json)
and embeds it fresh with the local model — no network access needed since
the HF model weights are already cached locally by the time this runs.

Run under the recall-venv (needs sentence-transformers/tiktoken/numpy):
    $GC_CITY_PATH/.gc/recall-venv/bin/python3 -m unittest test_recall -v
or via scripts/recall.selftest.sh.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import recall_lib as rl  # noqa: E402

TESTDATA = Path(__file__).resolve().parent / "testdata"


# ---------------------------------------------------------------------------
# Telemetry filter
# ---------------------------------------------------------------------------
class TestTelemetryFilter(unittest.TestCase):
    def test_wisp_id_pattern_filtered(self):
        self.assertTrue(rl.is_telemetry({"id": "ga-wisp-abc123", "title": "anything", "issue_type": "task"}))

    def test_infra_types_filtered(self):
        for t in ("session", "convoy", "step", "molecule", "event"):
            self.assertTrue(rl.is_telemetry({"id": "ga-x", "title": "whatever", "issue_type": t}), t)

    def test_title_prefix_patterns_filtered(self):
        for prefix in ("order:", "nudge:", "gate-run:", "sling-", "mol-dog", "reviewer-verdict:",
                       "gate:", "auto-refino-task:", "State change:", "Close drain step"):
            title = prefix + " something happened"
            self.assertTrue(rl.is_telemetry({"id": "ga-x", "title": title, "issue_type": "task"}), title)

    def test_digest_step_titles_filtered(self):
        self.assertTrue(rl.is_telemetry({"id": "ga-x", "title": "Finalize workflow", "issue_type": "task"}))

    def test_branch_step_pattern_filtered(self):
        self.assertTrue(rl.is_telemetry({"id": "ga-x", "title": "gastown.dog-42", "issue_type": "task"}))

    def test_nudge_metadata_filtered(self):
        self.assertTrue(rl.is_telemetry({"id": "ga-x", "title": "plain title", "issue_type": "task",
                                          "metadata": {"nudge_id": "abc"}}))

    def test_real_bug_not_filtered(self):
        self.assertFalse(rl.is_telemetry({
            "id": "ga-lxz5w", "issue_type": "bug",
            "title": "Gate auto-merges first of two branches on same bead without checking sibling/late hold",
            "metadata": {},
        }))

    def test_real_feature_not_filtered(self):
        self.assertFalse(rl.is_telemetry({"id": "wa-abc12", "issue_type": "feature",
                                           "title": "Unified phone-number resolver for inbound_capture/inbound_sweep"}))

    def test_missing_metadata_does_not_crash(self):
        self.assertFalse(rl.is_telemetry({"id": "ga-x", "issue_type": "chore", "title": "clean something up"}))


# ---------------------------------------------------------------------------
# Keyword extraction + chunking
# ---------------------------------------------------------------------------
class TestKeywordsAndChunking(unittest.TestCase):
    def test_keywords_strips_stopwords_and_short_tokens(self):
        kw = rl.keywords("Was there a bug where the gate did not fix it?")
        self.assertIn("gate", kw)
        self.assertIn("where", kw)
        self.assertNotIn("the", kw)
        self.assertNotIn("was", kw)  # in stopword list
        self.assertNotIn("bug", kw)  # 3 chars, below the >=4 length floor
        self.assertNotIn("fix", kw)  # 3 chars, below the >=4 length floor

    def test_keywords_pt_stopwords(self):
        kw = rl.keywords("Foi corrigido o bug do gate em que duas branches faziam merge")
        self.assertIn("gate", kw)
        self.assertIn("branches", kw)
        self.assertIn("corrigido", kw)
        self.assertNotIn("que", kw)
        self.assertNotIn("foi", kw)
        self.assertNotIn("bug", kw)  # 3 chars, below the >=4 length floor

    def test_chunk_words_empty(self):
        self.assertEqual(rl.chunk_words(""), [])
        self.assertEqual(rl.chunk_words(None), [])

    def test_chunk_words_short_text_single_chunk(self):
        text = " ".join(f"w{i}" for i in range(50))
        chunks = rl.chunk_words(text)
        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0], text)

    def test_chunk_words_long_text_overlaps(self):
        text = " ".join(f"w{i}" for i in range(300))
        chunks = rl.chunk_words(text, size=120, overlap=20)
        self.assertGreater(len(chunks), 1)
        # consecutive chunks share the overlap region
        first_words = chunks[0].split()
        second_words = chunks[1].split()
        self.assertEqual(first_words[-20:], second_words[:20])

    def test_full_text_joins_title_desc_comments(self):
        bead = {"title": "T", "description": "D", "comments": [{"text": "C1"}, {"text": "C2"}, {"text": ""}]}
        ft = rl.full_text(bead)
        self.assertEqual(ft, "T\n\nD\n\nC1\n\nC2")

    def test_full_text_skips_empty_fields(self):
        bead = {"title": "T", "description": "", "comments": []}
        self.assertEqual(rl.full_text(bead), "T")


# ---------------------------------------------------------------------------
# load_model() bootstrap/self-heal contract (wa-h9dc1) — mocked
# SentenceTransformer and subprocess.run, no real network or model weights
# needed (see TestHFHubOfflineFlagIsFrozenAtImportTime below for the one
# unmocked test that pins the underlying huggingface_hub behavior). Real-
# model loading is already exercised by TestHybridRetrievalQuality.setUpClass;
# these tests isolate rl._MODEL and the HF env vars per-test so they run
# safely regardless of test execution order relative to that class.
# ---------------------------------------------------------------------------
class TestLoadModelBootstrap(unittest.TestCase):
    def setUp(self):
        self._saved_model = rl._MODEL
        self._saved_env = {k: os.environ.get(k) for k in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE")}
        os.environ.pop("HF_HUB_OFFLINE", None)
        os.environ.pop("TRANSFORMERS_OFFLINE", None)
        rl._MODEL = None

    def tearDown(self):
        rl._MODEL = self._saved_model
        for k, v in self._saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_offline_success_never_goes_online(self):
        with mock.patch("sentence_transformers.SentenceTransformer", return_value="fake-model") as st, \
             mock.patch("recall_lib.subprocess.run") as run:
            model = rl.load_model()
        self.assertEqual(model, "fake-model")
        st.assert_called_once_with(rl.MODEL_NAME)
        self.assertEqual(os.environ.get("HF_HUB_OFFLINE"), "1")
        run.assert_not_called()  # cache hit — no bootstrap subprocess needed

    def test_cache_miss_self_heals_via_subprocess_bootstrap(self):
        """Regression for ga-444oq (the gate-rejected first attempt at this
        fix): that version retried SentenceTransformer() a SECOND TIME IN
        THIS PROCESS after flipping os.environ. That retry is a no-op —
        huggingface_hub freezes HF_HUB_OFFLINE into a module-level constant
        at import time and never re-reads os.environ afterward (pinned
        directly, without mocks, by
        TestHFHubOfflineFlagIsFrozenAtImportTime below) — so it fails
        identically both times and never touches subprocess.run at all.
        Against that version this test fails outright on
        `run.assert_called_once()` (0 calls) before the other assertions
        are even reached."""
        calls = []

        def fake_ctor(name):
            calls.append(os.environ.get("HF_HUB_OFFLINE"))
            if len(calls) == 1:
                raise OSError("cache miss under offline")
            return "fake-model-after-bootstrap"

        fake_proc = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch("sentence_transformers.SentenceTransformer", side_effect=fake_ctor), \
             mock.patch("recall_lib.subprocess.run", return_value=fake_proc) as run:
            model = rl.load_model()

        self.assertEqual(model, "fake-model-after-bootstrap")
        # BOTH in-process SentenceTransformer calls see the same, original
        # offline flag — the fix never mutates this process's env, so there
        # is nothing here for an in-process retry to exploit even in theory.
        self.assertEqual(calls, ["1", "1"])
        run.assert_called_once()
        bootstrap_env = run.call_args.kwargs["env"]
        self.assertEqual(bootstrap_env["HF_HUB_OFFLINE"], "0")
        self.assertEqual(bootstrap_env["TRANSFORMERS_OFFLINE"], "0")
        self.assertEqual(os.environ.get("HF_HUB_OFFLINE"), "1")
        self.assertEqual(os.environ.get("TRANSFORMERS_OFFLINE"), "1")

    def test_no_network_raises_clear_error_not_raw_traceback(self):
        fake_proc = mock.Mock(returncode=1, stdout="", stderr="ConnectionError: no route to host")
        with mock.patch("sentence_transformers.SentenceTransformer",
                         side_effect=OSError("cache miss under offline")), \
             mock.patch("recall_lib.subprocess.run", return_value=fake_proc):
            with self.assertRaises(rl.RecallModelUnavailableError) as ctx:
                rl.load_model()
        self.assertIn(rl.MODEL_NAME, str(ctx.exception))
        self.assertIn("no route to host", str(ctx.exception))  # real cause surfaces, not swallowed
        self.assertIsNone(rl._MODEL)  # failed load must not poison the cache
        self.assertEqual(os.environ.get("HF_HUB_OFFLINE"), "1")

    def test_bootstrap_subprocess_timeout_raises_clear_error(self):
        with mock.patch("sentence_transformers.SentenceTransformer",
                         side_effect=OSError("cache miss under offline")), \
             mock.patch("recall_lib.subprocess.run",
                         side_effect=subprocess.TimeoutExpired(cmd="python3", timeout=rl.MODEL_FETCH_TIMEOUT_S)):
            with self.assertRaises(rl.RecallModelUnavailableError) as ctx:
                rl.load_model()
        self.assertIn("timed out", str(ctx.exception))
        self.assertIsNone(rl._MODEL)


class TestHFHubOfflineFlagIsFrozenAtImportTime(unittest.TestCase):
    """Pins the actual huggingface_hub behavior that load_model()'s
    subprocess-based bootstrap depends on (wa-h9dc1 / ga-444oq): the
    library reads HF_HUB_OFFLINE into a module-level constant ONCE, at
    import time, and never re-reads os.environ afterward — so flipping
    the env var and retrying in the SAME process (the first, gate-rejected
    version of this fix) cannot work; it silently stays offline and fails
    identically every time. Runs in an isolated subprocess so the result
    doesn't depend on whether some earlier test in this file already
    imported huggingface_hub with a different starting value. If a future
    huggingface_hub release makes the flag dynamic, this is the test that
    catches it — at which point the subprocess bootstrap in load_model()
    may be simplifiable back to an in-process retry."""

    def test_flipping_env_after_import_does_not_change_offline_mode(self):
        probe = (
            "import os; os.environ['HF_HUB_OFFLINE'] = '1'\n"
            "import huggingface_hub.constants as c\n"
            "assert c.HF_HUB_OFFLINE is True, 'expected frozen True right after import'\n"
            "os.environ['HF_HUB_OFFLINE'] = '0'\n"
            "assert c.HF_HUB_OFFLINE is True, ("
            "'huggingface_hub now re-reads os.environ live -- the subprocess '"
            "'bootstrap in load_model() may no longer be necessary')\n"
            "print('OK')\n"
        )
        proc = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("OK", proc.stdout)


# ---------------------------------------------------------------------------
# bd JSON envelope parsing
# ---------------------------------------------------------------------------
class TestParseBdJson(unittest.TestCase):
    def test_bare_array(self):
        self.assertEqual(rl._parse_bd_json('[{"id": "a"}]'), [{"id": "a"}])

    def test_issues_wrapped(self):
        self.assertEqual(rl._parse_bd_json('{"issues": [{"id": "a"}]}'), [{"id": "a"}])

    def test_empty_string(self):
        self.assertEqual(rl._parse_bd_json(""), [])

    def test_unexpected_shape_returns_empty(self):
        self.assertEqual(rl._parse_bd_json('{"other": 1}'), [])


# ---------------------------------------------------------------------------
# Index persistence -- atomic writes + corruption self-heal (ga-zy725).
#
# Root cause reproduced live before this fix: a disk-full mid-write left
# chunk_vecs.npy truncated (640 of 12,647,040 elements missing). Every
# subsequent `recall` call crashed with a raw numpy ValueError -- including
# `recall --rebuild`, because load_index() ran (and raised) before the
# rebuild flag was ever consulted, so the documented recovery path didn't
# recover anything. Two independent halves, both covered here: save_index()
# must never let a killed write reach the real path (tmp+rename), and
# load_index() must treat an already-corrupted file as a cache miss rather
# than propagate the raw exception.
# ---------------------------------------------------------------------------
class TestIndexPersistenceAtomicity(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self._index_dir = Path(self._tmpdir.name) / "recall-index"
        self._patcher = mock.patch.object(rl, "INDEX_DIR", self._index_dir)
        self._patcher.start()

    def tearDown(self):
        self._patcher.stop()
        self._tmpdir.cleanup()

    def _sample_index(self):
        import numpy as np
        corpus = [{"id": "ga-1", "store": "HQ", "title": "x", "description": "", "comments": [],
                   "close_reason": "", "closed_at": "2026-08-01T00:00:00Z", "issue_type": "bug",
                   "priority": 2, "_ntok_full": 5}]
        vecs = np.ones((3, 384), dtype=np.float32)
        bead_idx = np.array([0, 0, 0], dtype=np.int64)
        meta = {"schema_version": rl.SCHEMA_VERSION, "n_beads": 1, "n_chunks": 3}
        return rl.RecallIndex(corpus, vecs, bead_idx, meta)

    def test_round_trip_save_then_load(self):
        idx = self._sample_index()
        rl.save_index(idx)
        loaded = rl.load_index()
        self.assertIsNotNone(loaded)
        self.assertEqual(loaded.corpus, idx.corpus)
        self.assertEqual(loaded.chunk_vecs.tolist(), idx.chunk_vecs.tolist())
        self.assertEqual(loaded.chunk_bead_idx.tolist(), idx.chunk_bead_idx.tolist())
        self.assertEqual(loaded.meta, idx.meta)

    def test_save_index_never_leaves_tmp_files_behind(self):
        rl.save_index(self._sample_index())
        leftovers = list(self._index_dir.glob("*.tmp"))
        self.assertEqual(leftovers, [], f"tmp files left behind: {leftovers}")

    def test_load_index_self_heals_on_truncated_npy(self):
        """Direct regression for the observed failure: a truncated
        chunk_vecs.npy (the exact disk-full mid-write shape -- tail bytes
        missing) must make load_index() return None, not raise."""
        rl.save_index(self._sample_index())
        vecs_path = rl._paths()["vecs"]
        vecs_path.write_bytes(vecs_path.read_bytes()[:-8])  # truncate the tail, like a killed write

        # Pre-fix, this line raised ValueError("... file seems not fully
        # written?") straight out of np.load -- reproduced live against the
        # real corrupted index before writing this fix.
        idx = rl.load_index()
        self.assertIsNone(idx)

    def test_load_index_self_heals_on_truncated_npy_reports_via_progress(self):
        rl.save_index(self._sample_index())
        vecs_path = rl._paths()["vecs"]
        vecs_path.write_bytes(vecs_path.read_bytes()[:-8])

        messages = []
        idx = rl.load_index(progress=messages.append)
        self.assertIsNone(idx)
        self.assertTrue(any("corrupt" in m.lower() for m in messages), messages)

    def test_load_index_self_heals_on_truncated_json(self):
        rl.save_index(self._sample_index())
        corpus_path = rl._paths()["corpus"]
        corpus_path.write_text(corpus_path.read_text()[:-5])  # truncate valid JSON -> parse error

        idx = rl.load_index()
        self.assertIsNone(idx)

    def test_save_index_atomic_write_failure_leaves_original_file_untouched(self):
        """If the write_fn itself fails partway (simulating ENOSPC mid-write
        to the tmp file), the file at the target path must be exactly what
        it was before the attempt, and the dead tmp file must be cleaned up
        -- proves the failure mode is 'old good copy survives, no debris',
        never 'a truncated file lands at the real path'."""
        rl.save_index(self._sample_index())  # establish a good baseline on disk
        vecs_path = rl._paths()["vecs"]
        original_bytes = vecs_path.read_bytes()

        def boom(f):
            f.write(b"\x00" * 10)
            raise OSError("ENOSPC: disk full (simulated)")

        with self.assertRaises(OSError):
            rl._atomic_write(vecs_path, boom)

        self.assertEqual(vecs_path.read_bytes(), original_bytes, "original file must survive a failed write")
        self.assertFalse(vecs_path.with_name(vecs_path.name + ".tmp").exists(),
                          "failed tmp file must not be left behind")

    def test_missing_index_files_return_none_not_corruption_path(self):
        """Baseline: a directory that simply has no index yet (first run)
        must still take the pre-existing None-and-no-progress-message path,
        not the new corruption-detection path."""
        messages = []
        idx = rl.load_index(progress=messages.append)
        self.assertIsNone(idx)
        self.assertEqual(messages, [])


# ---------------------------------------------------------------------------
# Index consistency + generation-atomic persistence (ga-m1sa2l).
#
# Live shape that made `recall` crash on every call (18/10): chunk_vecs.npy had
# 98401 rows, chunk_bead_idx.json 97765 entries, corpus.json 6479 beads while
# index_meta.json said 6453 -- four files from different generations, because
# save_index() replaced them one by one (each replace atomic, the SET not) and
# load_index() never compared them. The failure surfaced in prune_and_reindex
# (IndexError) -- but hybrid_retrieve would have broken on the same index in
# the throttled path that never reaches prune.
# ---------------------------------------------------------------------------
def _make_index(n_beads: int, chunks_per_bead: int, fill: float):
    """Small consistent index. `fill` is the value of every vector, so a test
    can tell which generation a loaded index came from."""
    import numpy as np
    corpus = [{"id": f"ga-{fill:g}-{i}", "store": "HQ", "title": "t", "description": "", "comments": [],
               "close_reason": "", "closed_at": "2026-08-01T00:00:00Z", "issue_type": "bug",
               "priority": 2, "_ntok_full": 1} for i in range(n_beads)]
    bead_idx = np.repeat(np.arange(n_beads, dtype=np.int64), chunks_per_bead)
    vecs = np.full((len(bead_idx), 4), fill, dtype=np.float32)
    meta = {"schema_version": rl.SCHEMA_VERSION, "n_beads": n_beads, "n_chunks": len(bead_idx),
            "last_build_at": 1000.0, "last_staleness_check_at": 1000.0,
            "hwm_closed_at": {"HQ": "2026-08-01T00:00:00Z"}, "list_render_tokens": 10}
    return rl.RecallIndex(corpus, vecs, bead_idx, meta)


class TestIndexInconsistency(unittest.TestCase):
    def _parts(self, idx):
        return idx.corpus, idx.chunk_vecs, idx.chunk_bead_idx, idx.meta

    def test_consistent_index_reports_nothing(self):
        self.assertIsNone(rl.index_inconsistency(*self._parts(_make_index(3, 2, 1.0))))

    def test_vecs_rows_vs_bead_idx_length_is_reported_with_both_numbers(self):
        """The exact live failure: 98401 vector rows against 97765 bead_idx."""
        import numpy as np
        idx = _make_index(3, 2, 1.0)
        idx.chunk_vecs = np.vstack([idx.chunk_vecs, np.ones((2, 4), dtype=np.float32)])  # 8 rows vs 6
        why = rl.index_inconsistency(*self._parts(idx))
        self.assertIsNotNone(why)
        self.assertIn("8", why)
        self.assertIn("6", why)

    def test_bead_idx_pointing_past_the_corpus_is_reported(self):
        idx = _make_index(3, 2, 1.0)
        idx.corpus = idx.corpus[:2]  # bead_idx still references bead 2
        self.assertIsNotNone(rl.index_inconsistency(*self._parts(idx)))

    def test_negative_bead_idx_is_reported(self):
        idx = _make_index(3, 2, 1.0)
        idx.chunk_bead_idx[0] = -1  # numpy would silently wrap this to the last bead
        self.assertIsNotNone(rl.index_inconsistency(*self._parts(idx)))

    def test_meta_counts_disagreeing_with_the_arrays_are_reported(self):
        """Live: corpus.json had 6479 beads while index_meta.json said 6453."""
        idx = _make_index(3, 2, 1.0)
        idx.meta["n_beads"] = 2
        self.assertIn("n_beads", rl.index_inconsistency(*self._parts(idx)))
        idx = _make_index(3, 2, 1.0)
        idx.meta["n_chunks"] = 99
        self.assertIn("n_chunks", rl.index_inconsistency(*self._parts(idx)))

    def test_meta_without_counts_is_not_held_against_the_index(self):
        idx = _make_index(3, 2, 1.0)
        del idx.meta["n_beads"], idx.meta["n_chunks"]
        self.assertIsNone(rl.index_inconsistency(*self._parts(idx)))

    def test_vecs_that_are_not_a_matrix_are_reported(self):
        import numpy as np
        idx = _make_index(3, 2, 1.0)
        idx.chunk_vecs = np.ones(6, dtype=np.float32)
        self.assertIsNotNone(rl.index_inconsistency(*self._parts(idx)))

    def test_empty_index_is_consistent(self):
        self.assertIsNone(rl.index_inconsistency(*self._parts(_make_index(0, 1, 1.0))))


class _IndexDirCase(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.index_dir = Path(self._tmpdir.name) / "recall-index"
        self.event_log = Path(self._tmpdir.name) / "logs" / "recall-index-events.jsonl"
        self._patchers = [mock.patch.object(rl, "INDEX_DIR", self.index_dir),
                          mock.patch.object(rl, "INDEX_EVENT_LOG", self.event_log)]
        for p in self._patchers:
            p.start()

    def tearDown(self):
        for p in self._patchers:
            p.stop()
        self._tmpdir.cleanup()

    def events(self):
        if not self.event_log.exists():
            return []
        return [json.loads(line) for line in self.event_log.read_text().splitlines() if line.strip()]

    def assertSameIndex(self, a, b):
        self.assertIsNotNone(a)
        self.assertEqual(a.corpus, b.corpus)
        self.assertEqual(a.chunk_vecs.tolist(), b.chunk_vecs.tolist())
        self.assertEqual(a.chunk_bead_idx.tolist(), b.chunk_bead_idx.tolist())
        self.assertEqual(a.meta, b.meta)


class TestLoadIndexRejectsInconsistentFiles(_IndexDirCase):
    def _write_flat_mixed_layout(self):
        """Hand-built copy of the live failure, in the pre-generation flat
        layout: new vectors and corpus next to an old bead_idx and meta."""
        import numpy as np
        old, new = _make_index(3, 2, 1.0), _make_index(4, 2, 2.0)
        self.index_dir.mkdir(parents=True)
        (self.index_dir / "corpus.json").write_text(json.dumps(new.corpus))
        np.save(self.index_dir / "chunk_vecs.npy", new.chunk_vecs)
        (self.index_dir / "chunk_bead_idx.json").write_text(json.dumps(old.chunk_bead_idx.tolist()))
        (self.index_dir / "index_meta.json").write_text(json.dumps(old.meta))

    def test_mixed_generations_load_as_none_with_a_reason(self):
        self._write_flat_mixed_layout()
        messages = []
        idx = rl.load_index(progress=messages.append)
        self.assertIsNone(idx)  # pre-fix: returned the mixed index and the next call crashed in prune
        self.assertTrue(any("inconsistent" in m.lower() for m in messages), messages)

    def test_the_rejection_leaves_a_line_in_the_event_log(self):
        self._write_flat_mixed_layout()
        rl.load_index()
        events = self.events()
        self.assertEqual(len(events), 1, events)
        self.assertEqual(events[0]["event"], "inconsistent_index_on_load")
        self.assertIn("detail", events[0])

    def test_a_valid_legacy_flat_layout_still_loads(self):
        """Indexes written before generations existed must keep working."""
        import numpy as np
        idx = _make_index(3, 2, 1.0)
        self.index_dir.mkdir(parents=True)
        (self.index_dir / "corpus.json").write_text(json.dumps(idx.corpus))
        np.save(self.index_dir / "chunk_vecs.npy", idx.chunk_vecs)
        (self.index_dir / "chunk_bead_idx.json").write_text(json.dumps(idx.chunk_bead_idx.tolist()))
        (self.index_dir / "index_meta.json").write_text(json.dumps(idx.meta))
        self.assertSameIndex(rl.load_index(), idx)

    def test_a_pointer_to_a_missing_generation_is_corruption_not_first_run(self):
        self.index_dir.mkdir(parents=True)
        (self.index_dir / "CURRENT").write_text("gen-does-not-exist")
        messages = []
        self.assertIsNone(rl.load_index(progress=messages.append))
        self.assertTrue(messages, "a published pointer that leads nowhere must be reported, not treated as first run")

    def test_a_pointer_with_a_hostile_name_is_never_followed(self):
        self.index_dir.mkdir(parents=True)
        (self.index_dir / "CURRENT").write_text("../../etc")
        messages = []
        self.assertIsNone(rl.load_index(progress=messages.append))
        self.assertTrue(messages)


class TestUpdateIndexIfStaleSelfHeals(_IndexDirCase):
    def _mixed_idx(self, last_check_at):
        """In-memory copy of the live shape: 8 vector rows for 6 bead_idx."""
        import numpy as np
        idx = _make_index(3, 2, 1.0)
        idx.chunk_vecs = np.vstack([idx.chunk_vecs, np.ones((2, 4), dtype=np.float32)])
        idx.meta["last_staleness_check_at"] = last_check_at
        return idx

    def test_inconsistent_index_is_rebuilt_not_pruned_into_an_indexerror(self):
        fresh = _make_index(2, 2, 7.0)
        with mock.patch.object(rl, "build_full_index", return_value=fresh) as m_build, \
             mock.patch.object(rl, "save_index") as m_save, \
             mock.patch.object(rl, "fetch_closed_meta", side_effect=AssertionError("must rebuild, not poll")):
            new_idx, changed = rl.update_index_if_stale(self._mixed_idx(last_check_at=0), force=True)
        m_build.assert_called_once()
        m_save.assert_called_once_with(fresh)
        self.assertIs(new_idx, fresh)
        self.assertTrue(changed)

    def test_inconsistent_index_is_rebuilt_even_inside_the_throttle_window(self):
        """The throttled early-return used to hand the broken index straight to
        hybrid_retrieve, which indexes sims (vector rows) by bead_idx."""
        import time
        fresh = _make_index(2, 2, 7.0)
        with mock.patch.object(rl, "build_full_index", return_value=fresh) as m_build, \
             mock.patch.object(rl, "save_index"):
            new_idx, changed = rl.update_index_if_stale(self._mixed_idx(last_check_at=time.time()), force=False)
        m_build.assert_called_once()
        self.assertIs(new_idx, fresh)
        self.assertTrue(changed)

    def test_rebuild_reason_is_logged(self):
        fresh = _make_index(2, 2, 7.0)
        messages = []
        with mock.patch.object(rl, "build_full_index", return_value=fresh), mock.patch.object(rl, "save_index"):
            rl.update_index_if_stale(self._mixed_idx(last_check_at=0), force=True, progress=messages.append)
        self.assertTrue(any("inconsistent" in m.lower() for m in messages), messages)
        events = self.events()
        self.assertEqual([e["event"] for e in events], ["rebuild_inconsistent_index"], events)

    def test_a_deferred_rebuild_propagates_instead_of_being_swallowed(self):
        """If the disk guard defers the rebuild, the caller must hear it (exit
        3, 'could not search'), never get the broken index back."""
        with mock.patch.object(rl, "build_full_index", side_effect=rl.RecallIndexRebuildDeferred("disk low")), \
             mock.patch.object(rl, "save_index"):
            with self.assertRaises(rl.RecallIndexRebuildDeferred):
                rl.update_index_if_stale(self._mixed_idx(last_check_at=0), force=True)


class TestIndexGenerations(_IndexDirCase):
    def _flaky_atomic_write(self, fail_at, on_call=None):
        real = rl._atomic_write
        state = {"n": 0}

        def flaky(path, write_fn):
            state["n"] += 1
            if on_call:
                on_call(state["n"])
            if state["n"] == fail_at:
                raise OSError("process killed mid-save (simulated)")
            return real(path, write_fn)
        return flaky

    def test_round_trip(self):
        idx = _make_index(3, 2, 1.0)
        rl.save_index(idx)
        self.assertSameIndex(rl.load_index(), idx)

    def test_a_save_that_dies_at_any_file_leaves_the_previous_index_whole(self):
        """The class behind the bug. Pre-fix, dying after the 2nd of the 4
        replaces left new corpus+vecs next to the old bead_idx+meta."""
        first = _make_index(3, 2, 1.0)
        rl.save_index(first)
        second = _make_index(5, 3, 2.0)  # different sizes, so any mixing is visible
        for fail_at in (1, 2, 3, 4, 5):  # 4 data files + the CURRENT pointer
            with mock.patch.object(rl, "_atomic_write", side_effect=self._flaky_atomic_write(fail_at)):
                with self.assertRaises(OSError):
                    rl.save_index(second)
            self.assertSameIndex(rl.load_index(), first)
            # A dead save must not leave an unpublished generation or tmp files behind.
            gens = [p.name for p in self.index_dir.iterdir() if p.name.startswith("gen-")]
            self.assertLessEqual(len(gens), 1, f"fail_at={fail_at}: orphan generation left behind: {gens}")
            self.assertEqual(list(self.index_dir.rglob("*.tmp")), [], f"fail_at={fail_at}: tmp debris")

    def test_a_reader_that_runs_in_the_middle_of_a_save_sees_a_whole_index(self):
        """Concurrent reader/writer: whichever instant the reader picks, it
        must get the old index or the new one, never a blend."""
        first, second = _make_index(3, 2, 1.0), _make_index(5, 3, 2.0)
        rl.save_index(first)
        seen = []
        flaky = self._flaky_atomic_write(fail_at=0, on_call=lambda n: seen.append(rl.load_index()))
        with mock.patch.object(rl, "_atomic_write", side_effect=flaky):
            rl.save_index(second)
        self.assertGreaterEqual(len(seen), 4)
        for mid in seen:
            self.assertIsNotNone(mid, "a reader mid-save must not see corruption")
            self.assertTrue(mid.corpus == first.corpus or mid.corpus == second.corpus)
            self.assertSameIndex(mid, first if mid.corpus == first.corpus else second)
        self.assertSameIndex(rl.load_index(), second)

    def test_two_writers_never_share_a_directory(self):
        a, b = _make_index(3, 2, 1.0), _make_index(4, 2, 2.0)
        with mock.patch.object(rl, "GEN_PRUNE_GRACE_SECONDS", 10 ** 9):
            rl.save_index(a)
            gen_a = a.gen_dir
            rl.save_index(b)
        self.assertNotEqual(gen_a, b.gen_dir)
        self.assertSameIndex(rl.load_index(), b)

    def test_save_refuses_to_persist_an_inconsistent_index(self):
        import numpy as np
        good = _make_index(3, 2, 1.0)
        rl.save_index(good)
        bad = _make_index(3, 2, 2.0)
        bad.chunk_vecs = np.vstack([bad.chunk_vecs, np.ones((2, 4), dtype=np.float32)])
        with self.assertRaises(ValueError):
            rl.save_index(bad)
        self.assertSameIndex(rl.load_index(), good)

    def test_old_generations_are_pruned_after_the_grace_period(self):
        with mock.patch.object(rl, "GEN_PRUNE_GRACE_SECONDS", 0):
            rl.save_index(_make_index(3, 2, 1.0))
            rl.save_index(_make_index(4, 2, 2.0))
            rl.save_index(_make_index(5, 2, 3.0))
        gens = [p for p in self.index_dir.iterdir() if p.name.startswith("gen-")]
        self.assertEqual(len(gens), 1, gens)

    def test_the_previous_generation_survives_the_grace_period_for_slow_readers(self):
        with mock.patch.object(rl, "GEN_PRUNE_GRACE_SECONDS", 3600):
            rl.save_index(_make_index(3, 2, 1.0))
            rl.save_index(_make_index(4, 2, 2.0))
        gens = [p for p in self.index_dir.iterdir() if p.name.startswith("gen-")]
        self.assertEqual(len(gens), 2, gens)

    def test_first_save_after_the_flat_layout_migrates_and_removes_the_flat_files(self):
        import numpy as np
        old = _make_index(3, 2, 1.0)
        self.index_dir.mkdir(parents=True)
        (self.index_dir / "corpus.json").write_text(json.dumps(old.corpus))
        np.save(self.index_dir / "chunk_vecs.npy", old.chunk_vecs)
        (self.index_dir / "chunk_bead_idx.json").write_text(json.dumps(old.chunk_bead_idx.tolist()))
        (self.index_dir / "index_meta.json").write_text(json.dumps(old.meta))
        rl.save_index(_make_index(4, 2, 2.0))
        flat = [n for n in ("corpus.json", "chunk_vecs.npy", "chunk_bead_idx.json", "index_meta.json")
                if (self.index_dir / n).exists()]
        self.assertEqual(flat, [])
        self.assertEqual(len(rl.load_index().corpus), 4)

    def test_pruning_never_touches_anything_outside_the_index_naming_scheme(self):
        self.index_dir.mkdir(parents=True)
        keepsake = self.index_dir / "keep-me.txt"
        keepsake.write_text("not ours")
        other_dir = self.index_dir / "notes"
        other_dir.mkdir()
        with mock.patch.object(rl, "GEN_PRUNE_GRACE_SECONDS", 0):
            rl.save_index(_make_index(3, 2, 1.0))
            rl.save_index(_make_index(4, 2, 2.0))
        self.assertTrue(keepsake.exists())
        self.assertTrue(other_dir.exists())

    def test_pruning_never_removes_the_generation_current_names_even_if_it_is_not_ours(self):
        """Two writers: the other one published after us and its generation is
        old by mtime. Our prune must still leave whatever CURRENT names."""
        import time
        idx = _make_index(3, 2, 1.0)
        rl.save_index(idx)
        ancient = time.time() - 10 ** 6
        os.utime(idx.gen_dir, (ancient, ancient))
        with mock.patch.object(rl, "GEN_PRUNE_GRACE_SECONDS", 0):
            rl._prune_generations(keep=self.index_dir / "gen-written-by-someone-else")
        self.assertTrue(idx.gen_dir.is_dir())
        self.assertSameIndex(rl.load_index(), idx)

    def test_grace_period_runs_from_the_moment_of_supersession_not_from_the_last_write(self):
        """A reader may have resolved CURRENT just before the swap. The old
        generation's own mtime says nothing about that (it may be days old)."""
        import time
        a = _make_index(3, 2, 1.0)
        rl.save_index(a)
        ancient = time.time() - 10 ** 6
        os.utime(a.gen_dir, (ancient, ancient))
        rl.save_index(_make_index(4, 2, 2.0))  # default grace period
        self.assertTrue(a.gen_dir.is_dir(), "superseded generation removed while a slow reader may still be loading it")

    def test_no_tmp_debris_anywhere_in_the_tree(self):
        rl.save_index(_make_index(3, 2, 1.0))
        self.assertEqual(list(self.index_dir.rglob("*.tmp")), [])


class TestThrottleTimestampPersistence(_IndexDirCase):
    def test_a_no_change_check_rewrites_only_the_meta_not_the_whole_index(self):
        """Pre-fix the 'nothing new' branch re-saved ~240 MB (and re-stamped a
        broken index as fresh) just to move one timestamp."""
        import time
        idx = _make_index(3, 2, 1.0)
        rl.save_index(idx)
        loaded = rl.load_index()
        gens_before = sorted(p.name for p in self.index_dir.iterdir() if p.name.startswith("gen-"))
        vecs_path = rl._paths()["vecs"]
        vecs_before = (vecs_path.read_bytes(), vecs_path.stat().st_mtime_ns)
        loaded.meta["last_staleness_check_at"] = 0
        loaded.meta["last_build_at"] = time.time()  # young index: the age trigger must not fire
        with mock.patch.object(rl, "fetch_closed_meta", return_value=[]):
            _, changed = rl.update_index_if_stale(loaded, force=False)
        self.assertFalse(changed)
        gens_after = sorted(p.name for p in self.index_dir.iterdir() if p.name.startswith("gen-"))
        self.assertEqual(gens_after, gens_before, "a no-op check must not publish a new generation")
        self.assertEqual((vecs_path.read_bytes(), vecs_path.stat().st_mtime_ns), vecs_before)
        reloaded = rl.load_index()
        self.assertGreater(reloaded.meta["last_staleness_check_at"], time.time() - 60)
        self.assertEqual(reloaded.corpus, idx.corpus)

    def test_an_index_that_was_never_loaded_from_disk_falls_back_to_a_full_save(self):
        idx = _make_index(3, 2, 1.0)
        self.assertIsNone(idx.gen_dir)
        rl.save_index_meta(idx)
        self.assertSameIndex(rl.load_index(), idx)

    def test_meta_write_to_a_generation_that_was_pruned_meanwhile_is_a_silent_noop(self):
        idx = _make_index(3, 2, 1.0)
        rl.save_index(idx)
        loaded = rl.load_index()
        with mock.patch.object(rl, "GEN_PRUNE_GRACE_SECONDS", 0):
            rl.save_index(_make_index(4, 2, 2.0))
            rl.save_index(_make_index(5, 2, 3.0))  # prunes the generation `loaded` came from
        rl.save_index_meta(loaded)  # must not raise, must not resurrect the old generation
        self.assertEqual(len(rl.load_index().corpus), 5)
        self.assertEqual(len([p for p in self.index_dir.iterdir() if p.name.startswith("gen-")]), 1)


# ---------------------------------------------------------------------------
# A from-scratch rebuild is a heavy step (embeds every chunk, writes the whole
# index): it goes through scripts/heavy-guard.sh (ga-vln2py). Without this the
# self-heal above would be an automatic route around the disk floor.
# ---------------------------------------------------------------------------
class _PastTheGuard(Exception):
    pass


class TestRebuildRespectsDiskGuard(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.city = Path(self._tmpdir.name)
        (self.city / "scripts").mkdir()
        self._p = mock.patch.object(rl, "GC_CITY_PATH", str(self.city))
        self._p.start()
        # build_full_index() asks the guard first; whatever is past it must be
        # unreachable in the refusal tests and is replaced by a sentinel here.
        self._model = mock.patch.object(rl, "load_model", side_effect=_PastTheGuard())
        self.m_model = self._model.start()

    def tearDown(self):
        self._model.stop()
        self._p.stop()
        self._tmpdir.cleanup()

    def _install_guard(self):
        (self.city / "scripts" / "heavy-guard.sh").write_text("#!/bin/sh\nexit 0\n")

    def _guard_says(self, rc, out=""):
        return mock.patch.object(rl.subprocess, "run",
                                 return_value=subprocess.CompletedProcess([], rc, stdout=out, stderr=""))

    def test_a_refusal_defers_the_rebuild_before_any_work(self):
        self._install_guard()
        with self._guard_says(75, "heavy-guard: REFUSED ... 5461 MB free < 6144 MB floor"):
            with self.assertRaises(rl.RecallIndexRebuildDeferred) as cm:
                rl.build_full_index()
        self.assertIn("5461", str(cm.exception))
        self.m_model.assert_not_called()

    def test_not_being_able_to_read_the_disk_is_also_a_refusal(self):
        self._install_guard()
        with self._guard_says(76, "heavy-guard: cannot read disk"):
            with self.assertRaises(rl.RecallIndexRebuildDeferred):
                rl.build_full_index()

    def test_an_unexpected_exit_code_is_a_refusal_not_a_green_light(self):
        self._install_guard()
        with self._guard_says(127):
            with self.assertRaises(rl.RecallIndexRebuildDeferred):
                rl.build_full_index()

    def test_a_guard_that_cannot_be_run_is_a_refusal(self):
        self._install_guard()
        for exc in (OSError("exec format error"), subprocess.TimeoutExpired("heavy-guard.sh", 30)):
            with mock.patch.object(rl.subprocess, "run", side_effect=exc):
                with self.assertRaises(rl.RecallIndexRebuildDeferred):
                    rl.build_full_index()
        self.m_model.assert_not_called()

    def test_a_green_light_lets_the_rebuild_proceed(self):
        self._install_guard()
        with self._guard_says(0):
            with self.assertRaises(_PastTheGuard):
                rl.build_full_index()

    def test_a_checkout_without_the_guard_script_is_not_blocked(self):
        with self.assertRaises(_PastTheGuard):
            rl.build_full_index()

    def test_the_cli_reports_a_deferred_rebuild_as_could_not_search(self):
        import io
        import recall
        err = io.StringIO()
        with mock.patch.object(recall, "ensure_index", side_effect=rl.RecallIndexRebuildDeferred("disk low")), \
             mock.patch.object(sys, "stderr", err):
            rc = recall.main(["anything"])
        self.assertEqual(rc, 3)
        self.assertIn("disk low", err.getvalue())


# ---------------------------------------------------------------------------
# Staleness decision (pure logic)
# ---------------------------------------------------------------------------
class TestShouldRebuild(unittest.TestCase):
    def test_fresh_index_no_new_beads_no_rebuild(self):
        meta = {"last_build_at": 1000.0}
        self.assertFalse(rl.should_rebuild(meta, new_real_count=0, now=1000.0 + 60))

    def test_age_trigger(self):
        meta = {"last_build_at": 1000.0}
        now = 1000.0 + rl.STALE_AFTER_SECONDS + 1
        self.assertTrue(rl.should_rebuild(meta, new_real_count=0, now=now))

    def test_count_trigger(self):
        meta = {"last_build_at": 1000.0}
        self.assertTrue(rl.should_rebuild(meta, new_real_count=rl.STALE_NEW_BEAD_THRESHOLD, now=1000.0 + 60))

    def test_just_under_count_threshold_no_rebuild(self):
        meta = {"last_build_at": 1000.0}
        self.assertFalse(rl.should_rebuild(meta, new_real_count=rl.STALE_NEW_BEAD_THRESHOLD - 1, now=1000.0 + 60))


# ---------------------------------------------------------------------------
# Prune + reindex (pure numpy logic, no model)
# ---------------------------------------------------------------------------
class TestPruneAndReindex(unittest.TestCase):
    def _synthetic(self):
        import numpy as np
        corpus = [
            {"id": "old-1", "closed_at": "2026-01-01T00:00:00Z"},
            {"id": "keep-1", "closed_at": "2026-07-01T00:00:00Z"},
            {"id": "old-2", "closed_at": "2026-01-02T00:00:00Z"},
            {"id": "keep-2", "closed_at": "2026-07-10T00:00:00Z"},
        ]
        # 2 chunks each, bead order: old-1,old-1,keep-1,old-2,keep-2,keep-2,keep-2
        chunk_bead_idx = np.array([0, 0, 1, 2, 3, 3, 3], dtype=np.int64)
        chunk_vecs = np.arange(7 * 4, dtype=np.float32).reshape(7, 4)
        return corpus, chunk_vecs, chunk_bead_idx

    def test_prunes_old_beads_and_their_chunks(self):
        corpus, vecs, bead_idx = self._synthetic()
        new_corpus, new_vecs, new_idx = rl.prune_and_reindex(corpus, vecs, bead_idx, cutoff_iso="2026-03-01T00:00:00Z")
        self.assertEqual([b["id"] for b in new_corpus], ["keep-1", "keep-2"])
        # 1 chunk for keep-1 (old index 1) + 3 chunks for keep-2 (old index 3) = 4
        self.assertEqual(len(new_vecs), 4)
        self.assertEqual(len(new_idx), 4)
        # remapped indices only reference the 2 surviving beads (0, 1)
        self.assertTrue(set(new_idx.tolist()) <= {0, 1})
        # keep-1's single chunk maps to new bead index 0
        self.assertEqual(new_idx.tolist()[0], 0)
        # keep-2's three chunks map to new bead index 1
        self.assertEqual(new_idx.tolist()[1:], [1, 1, 1])

    def test_prune_keeps_everything_when_cutoff_is_old(self):
        corpus, vecs, bead_idx = self._synthetic()
        new_corpus, new_vecs, new_idx = rl.prune_and_reindex(corpus, vecs, bead_idx, cutoff_iso="2000-01-01T00:00:00Z")
        self.assertEqual(len(new_corpus), 4)
        self.assertEqual(len(new_vecs), 7)

    def test_prune_empty_corpus(self):
        import numpy as np
        new_corpus, new_vecs, new_idx = rl.prune_and_reindex([], np.zeros((0, 4), dtype=np.float32),
                                                               np.array([], dtype=np.int64), "2026-01-01T00:00:00Z")
        self.assertEqual(new_corpus, [])
        self.assertEqual(len(new_vecs), 0)


# ---------------------------------------------------------------------------
# Instrumentation
# ---------------------------------------------------------------------------
class TestInstrumentation(unittest.TestCase):
    def test_log_usage_writes_valid_jsonl_with_expected_keys(self):
        idx = rl.RecallIndex(corpus=[], chunk_vecs=None, chunk_bead_idx=None,
                              meta={"list_render_tokens": 59003})
        results = [
            {"bead": {"id": "ga-abc12", "_ntok_full": 500}},
            {"bead": {"id": "wa-def34", "_ntok_full": 700}},
        ]
        with tempfile.TemporaryDirectory() as td:
            log_path = Path(td) / "recall-usage.jsonl"
            rec = rl.log_usage("did we fix X", results, idx, elapsed_s=0.42, log_path=log_path)
            # append a second call to confirm JSONL (append, one object per line)
            rl.log_usage("another query", results[:1], idx, elapsed_s=0.10, log_path=log_path)

            lines = log_path.read_text().splitlines()
            self.assertEqual(len(lines), 2)
            parsed = [json.loads(line) for line in lines]

        self.assertEqual(parsed[0]["query"], "did we fix X")
        self.assertEqual(parsed[0]["bead_ids"], ["ga-abc12", "wa-def34"])
        self.assertEqual(parsed[0]["returned_tokens"], 1200)
        self.assertEqual(parsed[0]["baseline_estimate_tokens"], 59003 + 1200)
        self.assertAlmostEqual(parsed[0]["savings_ratio"], (59003 + 1200) / 1200)
        self.assertIn("ts", parsed[0])
        self.assertIn("elapsed_s", parsed[0])
        self.assertEqual(rec, parsed[0])

    def test_log_usage_zero_results_no_crash(self):
        idx = rl.RecallIndex(corpus=[], chunk_vecs=None, chunk_bead_idx=None, meta={"list_render_tokens": 100})
        with tempfile.TemporaryDirectory() as td:
            log_path = Path(td) / "recall-usage.jsonl"
            rec = rl.log_usage("nothing matches", [], idx, elapsed_s=0.05, log_path=log_path)
        self.assertEqual(rec["returned_tokens"], 0)
        self.assertIsNone(rec["savings_ratio"])


# ---------------------------------------------------------------------------
# update_index_if_stale — throttle + trigger behavior, bd calls mocked out
# ---------------------------------------------------------------------------
class TestUpdateIndexIfStaleThrottle(unittest.TestCase):
    def _idx(self, last_build_at, last_check_at):
        # Relative to now, not a calendar date: prune_and_reindex() drops beads
        # older than MAX_AGE_DAYS, so a hard-coded 2026-07-01 stopped surviving
        # the refresh on 2026-09-29 and three tests below went red with no code
        # change (the fixture bead was pruned, not the behavior under test).
        recent = (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        return rl.RecallIndex(
            corpus=[{"id": "ga-1", "store": "HQ", "closed_at": recent, "title": "x",
                     "description": "", "comments": [], "close_reason": "", "issue_type": "bug",
                     "priority": 2, "_ntok_full": 10}],
            chunk_vecs=__import__("numpy").zeros((1, 384), dtype="float32"),
            chunk_bead_idx=__import__("numpy").array([0]),
            meta={"last_build_at": last_build_at, "last_staleness_check_at": last_check_at,
                  "hwm_closed_at": {"HQ": "2026-07-01T00:00:00Z", "WA": "2026-07-01T00:00:00Z"},
                  "list_render_tokens": 100},
        )

    def test_within_throttle_window_skips_bd_entirely(self):
        import time
        idx = self._idx(last_build_at=time.time(), last_check_at=time.time())
        with mock.patch.object(rl, "fetch_closed_meta") as m_fetch:
            new_idx, changed = rl.update_index_if_stale(idx, force=False)
        m_fetch.assert_not_called()
        self.assertFalse(changed)

    def test_past_throttle_but_nothing_new_no_rebuild(self):
        import time
        idx = self._idx(last_build_at=time.time(), last_check_at=time.time() - rl.STALENESS_CHECK_MIN_INTERVAL_SECONDS - 5)
        with mock.patch.object(rl, "fetch_closed_meta", return_value=[]) as m_fetch, \
             mock.patch.object(rl, "save_index") as m_save:
            new_idx, changed = rl.update_index_if_stale(idx, force=False)
        self.assertEqual(m_fetch.call_count, 2)  # HQ + WA
        self.assertFalse(changed)
        m_save.assert_called_once()  # throttle timestamp still persisted

    def test_count_trigger_causes_rebuild_and_fetches_full(self):
        import time
        idx = self._idx(last_build_at=time.time(), last_check_at=0)
        new_real = [{"id": f"ga-new{i}", "title": f"new real bug {i}", "issue_type": "bug",
                     "closed_at": "2026-07-20T00:00:00Z"} for i in range(rl.STALE_NEW_BEAD_THRESHOLD)]

        def fake_fetch_closed_meta(store_path, closed_after=None):
            return new_real if "gascity" in store_path else []

        def fake_fetch_full(store_path, ids, batch=40):
            return [{"id": i, "title": "new real bug", "issue_type": "bug",
                      "closed_at": "2026-07-20T00:00:00Z", "description": "", "comments": []} for i in ids]

        with mock.patch.object(rl, "fetch_closed_meta", side_effect=fake_fetch_closed_meta), \
             mock.patch.object(rl, "fetch_full", side_effect=fake_fetch_full) as m_full, \
             mock.patch.object(rl, "save_index"):
            new_idx, changed = rl.update_index_if_stale(idx, force=False)

        self.assertTrue(changed)
        m_full.assert_called()
        self.assertEqual(new_idx.meta["n_beads"], 1 + rl.STALE_NEW_BEAD_THRESHOLD)
        ids = {b["id"] for b in new_idx.corpus}
        self.assertIn("ga-1", ids)
        self.assertIn("ga-new0", ids)

    def test_telemetry_only_round_advances_hwm(self):
        """ga-wisp-uxqk2w gate finding: a poll round where every
        new-since-last-check bead is telemetry (wisp/order/nudge — filtered
        out of the corpus) must still advance hwm_closed_at. Before the fix,
        the whole per-store update block (including the hwm bump) lived
        behind `if not real: continue`, so a telemetry-only round left the
        mark untouched and the tool re-polled the exact same window forever
        (recall_lib.py:528-541)."""
        idx = self._idx(last_build_at=0, last_check_at=0)
        telemetry_only = [
            {"id": "ga-wisp-a1", "title": "order: dispatch something", "issue_type": "task",
             "closed_at": "2026-07-20T10:00:00Z"},
            {"id": "ga-wisp-a2", "title": "nudge: fyi", "issue_type": "task",
             "closed_at": "2026-07-20T11:00:00Z"},
        ]

        def fake_fetch_closed_meta(store_path, closed_after=None):
            return telemetry_only if "gascity" in store_path else []

        with mock.patch.object(rl, "fetch_closed_meta", side_effect=fake_fetch_closed_meta), \
             mock.patch.object(rl, "fetch_full",
                                side_effect=AssertionError("fetch_full must not run: nothing survived the telemetry filter")), \
             mock.patch.object(rl, "save_index"):
            new_idx, changed = rl.update_index_if_stale(idx, force=True)

        self.assertTrue(changed)
        # Nothing indexable -> corpus is unchanged...
        self.assertEqual([b["id"] for b in new_idx.corpus], ["ga-1"])
        # ...but the mark must move past the telemetry-only window, not freeze.
        self.assertEqual(new_idx.meta["hwm_closed_at"]["HQ"], "2026-07-20T11:00:00Z")

    def test_genuinely_empty_round_leaves_hwm_unchanged(self):
        """The flip side of the telemetry-only case: when a store's poll
        returns NOTHING at all since the last check (not even telemetry),
        `dates` is empty and the mark must legitimately stay put — the fix
        must not advance the hwm on every call regardless of content."""
        idx = self._idx(last_build_at=0, last_check_at=0)
        original_hwm = dict(idx.meta["hwm_closed_at"])

        with mock.patch.object(rl, "fetch_closed_meta", return_value=[]), \
             mock.patch.object(rl, "fetch_full",
                                side_effect=AssertionError("fetch_full must not run: nothing fetched")), \
             mock.patch.object(rl, "save_index"):
            new_idx, changed = rl.update_index_if_stale(idx, force=True)

        self.assertTrue(changed)
        self.assertEqual(new_idx.meta["hwm_closed_at"], original_hwm)
        self.assertEqual([b["id"] for b in new_idx.corpus], ["ga-1"])

    def test_hwm_advances_independently_per_store(self):
        """Reproduces the reviewer's exact framing ('freezes per-store'): one
        store's telemetry-only round must advance while a sibling store's
        genuinely-empty round in the SAME call leaves its own mark alone —
        proves the two stores' marks aren't coupled to a single decision."""
        idx = self._idx(last_build_at=0, last_check_at=0)
        telemetry_only = [
            {"id": "wa-wisp-b1", "title": "gate-run: reviewer prompt", "issue_type": "task",
             "closed_at": "2026-07-20T09:30:00Z"},
        ]

        def fake_fetch_closed_meta(store_path, closed_after=None):
            # HQ (gascity path) sees a telemetry-only round; WA sees nothing.
            return [] if "gascity" in store_path else telemetry_only

        with mock.patch.object(rl, "fetch_closed_meta", side_effect=fake_fetch_closed_meta), \
             mock.patch.object(rl, "fetch_full",
                                side_effect=AssertionError("fetch_full must not run: nothing survived the telemetry filter")), \
             mock.patch.object(rl, "save_index"):
            new_idx, changed = rl.update_index_if_stale(idx, force=True)

        self.assertTrue(changed)
        self.assertEqual(new_idx.meta["hwm_closed_at"]["HQ"], "2026-07-01T00:00:00Z")  # untouched: genuinely empty
        self.assertEqual(new_idx.meta["hwm_closed_at"]["WA"], "2026-07-20T09:30:00Z")  # advanced: telemetry-only


# ---------------------------------------------------------------------------
# Hybrid retrieval quality regression (needs the real model — the ONE slow
# test class; model load is cached process-wide via recall_lib._MODEL so
# this only pays the cost once regardless of test order/count).
# ---------------------------------------------------------------------------
class TestHybridRetrievalQuality(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = json.loads((TESTDATA / "recall_fixture.json").read_text())
        cls.queries = json.loads((TESTDATA / "recall_queries.json").read_text())
        cls.model = rl.load_model()

        import numpy as np
        corpus = []
        for b in cls.fixture:
            fb = dict(b)
            fb["_ntok_full"] = rl.ntok(rl.full_text(fb))
            corpus.append(fb)
        chunk_texts, chunk_idx = rl._chunks_for_corpus(corpus)
        vecs = rl.embed(cls.model, chunk_texts)
        cls.idx = rl.RecallIndex(corpus, vecs, np.array(chunk_idx, dtype=np.int64),
                                  {"list_render_tokens": rl.list_render_tokens_for(corpus)})

    def test_hybrid_recall_at_union_stays_high(self):
        # Measured on this fixture at ship time: 19/20 = 0.950, matching the
        # full 1441-bead / 20-query experiment corpus exactly. Threshold set
        # a little below that to absorb minor embedding-library version
        # drift without masking a real regression.
        hits = 0
        for q in self.queries:
            results = rl.hybrid_retrieve(q["query"], self.idx, model=self.model, k=3)
            ids = [r["bead"]["id"] for r in results]
            hits += q["target"] in ids
        recall = hits / len(self.queries)
        self.assertGreaterEqual(recall, 0.85, f"hybrid recall@union dropped to {recall:.2f} (expected ~0.95)")

    def test_hybrid_beats_or_matches_pure_semantic_and_keyword_arm_contributes(self):
        import numpy as np
        hybrid_hits = 0
        semantic_only_hits = 0
        keyword_rescued_a_query = False
        for q in self.queries:
            results = rl.hybrid_retrieve(q["query"], self.idx, model=self.model, k=3)
            ids = [r["bead"]["id"] for r in results]
            hybrid_hits += q["target"] in ids

            q_vec = rl.embed(self.model, [q["query"]])[0]
            sims = self.idx.chunk_vecs @ q_vec
            bead_max = np.full(len(self.idx.corpus), -1.0, dtype=np.float32)
            np.maximum.at(bead_max, self.idx.chunk_bead_idx, sims)
            sem_top3_ids = [self.idx.corpus[i]["id"] for i in np.argsort(-bead_max)[:3]]
            sem_hit = q["target"] in sem_top3_ids
            semantic_only_hits += sem_hit
            if q["target"] in ids and not sem_hit:
                keyword_rescued_a_query = True

        # Do NOT ship pure-semantic alone: hybrid must not be worse than it,
        # and the keyword arm must demonstrably rescue at least one query
        # the semantic arm alone would have missed (proves the union is
        # doing real work, not silently degenerating to semantic-only).
        self.assertGreaterEqual(hybrid_hits, semantic_only_hits)
        self.assertTrue(keyword_rescued_a_query, "keyword arm never rescued a query — hybrid may have degenerated to pure-semantic")

    def test_top_comments_picks_the_relevant_one(self):
        bead = {
            "comments": [
                {"text": "Deployed the new pricing dashboard to production, looks good."},
                {"text": "Root cause: the gate race condition merges branch A before branch B's hold label lands."},
                {"text": "Updated the README with install instructions."},
            ]
        }
        top = rl.top_comments(bead, "what was the root cause of the gate race condition bug", model=self.model, n=1)
        self.assertEqual(len(top), 1)
        self.assertIn("race condition", top[0])


if __name__ == "__main__":
    unittest.main()
