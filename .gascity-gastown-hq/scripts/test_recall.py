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
        return rl.RecallIndex(
            corpus=[{"id": "ga-1", "store": "HQ", "closed_at": "2026-07-01T00:00:00Z", "title": "x",
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
