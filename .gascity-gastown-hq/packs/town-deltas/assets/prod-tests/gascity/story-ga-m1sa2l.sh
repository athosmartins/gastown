#!/usr/bin/env bash
# prod-tests/gascity/story-ga-m1sa2l.sh — prod test for ga-m1sa2l: the recall
# index is published as ONE atomic unit and an inconsistent index heals instead
# of crashing every call.
#
# Root cause (measured 18/10): the index is four files (corpus.json,
# chunk_vecs.npy, chunk_bead_idx.json, index_meta.json) that were replaced one
# by one in a shared dir. A writer that stopped between two replaces, or two
# writers interleaving, left files of different generations side by side (live:
# 98401 vector rows vs 97765 bead_idx entries, corpus 6479 beads vs meta 6453)
# and load_index() never compared them, so every `recall` died with an
# IndexError in prune_and_reindex. Fix: a save writes a whole new generation dir
# and publishes it with one atomic rename of the CURRENT pointer; load_index()
# and update_index_if_stale() refuse an index whose parts disagree and rebuild
# (through scripts/heavy-guard.sh, the disk-floor guard).
#
# Called by run.sh after deploy (STORY_ID=ga-m1sa2l). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
VENV_PY="$CITY/.gc/recall-venv/bin/python3"
RECALL_LIB="$CITY/scripts/recall_lib.py"

log()  { echo "[prod-test:gascity ga-m1sa2l] $*"; }
fail() { echo "[prod-test:gascity ga-m1sa2l] FAIL: $*" >&2; exit 1; }

[[ -x "$VENV_PY" ]] || fail "recall venv python not found: $VENV_PY"
[[ -f "$RECALL_LIB" ]] || fail "deployed recall_lib.py missing: $RECALL_LIB"
log "Deployed recall_lib.py found: $RECALL_LIB"

# ── 1. Structural: the fix is actually in the deployed file ────────────────
for sym in "^def index_inconsistency(" "^def save_index_meta(" "^def _prune_generations(" \
           "^def _require_heavy_step_allowed(" "^class RecallIndexRebuildDeferred(" \
           "^CURRENT_POINTER = "; do
    grep -q "$sym" "$RECALL_LIB" || fail "'$sym' missing from deployed recall_lib.py -- ga-m1sa2l fix not deployed"
done
grep -q "^def _atomic_write(" "$RECALL_LIB" \
  || fail "_atomic_write() missing from deployed recall_lib.py -- ga-zy725 fix regressed"
log "generation-atomic persistence + consistency check + disk guard present in deployed recall_lib.py ✓"

# ── 2. Behavioral, against the REAL deployed module but an isolated temp index
#    dir -- never touches the live production index ─────────────────────────
RESULT=$(PYTHONPATH="$(dirname "$RECALL_LIB")" "$VENV_PY" - <<'PYEOF' 2>&1
import json
import tempfile
from pathlib import Path
from unittest import mock

import numpy as np
import recall_lib as rl


def make(n_beads, per, fill):
    corpus = [{"id": "x%d" % i, "store": "HQ", "title": "t", "description": "", "comments": [],
               "close_reason": "", "closed_at": "2026-01-01T00:00:00Z", "issue_type": "task",
               "priority": 2, "_ntok_full": 1} for i in range(n_beads)]
    bead = np.repeat(np.arange(n_beads, dtype=np.int64), per)
    vecs = np.full((len(bead), 4), fill, dtype=np.float32)
    meta = {"schema_version": rl.SCHEMA_VERSION, "n_beads": n_beads, "n_chunks": len(bead)}
    return rl.RecallIndex(corpus, vecs, bead, meta)


def same(a, b):
    return (a is not None and a.corpus == b.corpus and a.chunk_vecs.tolist() == b.chunk_vecs.tolist()
            and a.chunk_bead_idx.tolist() == b.chunk_bead_idx.tolist() and a.meta == b.meta)


checks = []
with tempfile.TemporaryDirectory() as td:
    td = Path(td)
    with mock.patch.object(rl, "INDEX_DIR", td / "idx"), mock.patch.object(rl, "INDEX_EVENT_LOG", td / "ev.jsonl"):
        first = make(3, 2, 1.0)
        rl.save_index(first)
        checks.append(("round_trip_loads", same(rl.load_index(), first)))

        real = rl._atomic_write
        calls = {"n": 0}

        def killed_third_file(path, fn):
            calls["n"] += 1
            if calls["n"] == 3:
                raise OSError("process killed mid-save (simulated)")
            return real(path, fn)

        with mock.patch.object(rl, "_atomic_write", side_effect=killed_third_file):
            try:
                rl.save_index(make(5, 3, 2.0))
                died = False
            except OSError:
                died = True
        checks.append(("killed_save_raised", died))
        checks.append(("killed_save_keeps_previous_index_whole", same(rl.load_index(), first)))
        checks.append(("no_tmp_debris", list((td / "idx").rglob("*.tmp")) == []))

    # the live failure, rebuilt by hand in the pre-generation flat layout:
    # new vectors + corpus next to an old bead_idx + meta
    mixed = td / "mixed"
    with mock.patch.object(rl, "INDEX_DIR", mixed), mock.patch.object(rl, "INDEX_EVENT_LOG", td / "ev2.jsonl"):
        old, new = make(3, 2, 1.0), make(4, 2, 2.0)
        mixed.mkdir()
        (mixed / "corpus.json").write_text(json.dumps(new.corpus))
        np.save(mixed / "chunk_vecs.npy", new.chunk_vecs)
        (mixed / "chunk_bead_idx.json").write_text(json.dumps(old.chunk_bead_idx.tolist()))
        (mixed / "index_meta.json").write_text(json.dumps(old.meta))
        checks.append(("mixed_generations_load_as_none_not_a_later_crash", rl.load_index() is None))

failed = [name for name, ok in checks if not ok]
print("CHECKS_FAILED:" + ",".join(failed) if failed else "ALL_OK")
PYEOF
)

if [[ "$RESULT" != "ALL_OK" ]]; then
    fail "behavioral check failed against the deployed module: $RESULT"
fi
log "killed save keeps the previous index whole; a mixed-generation index loads as None; no tmp debris ✓"

# ── 3. The LIVE index: usable, and the live CLI answers ────────────────────
# Read-only probe first. If the live index does not load, say so and stop: a
# prod test must not start the multi-minute from-scratch rebuild (that goes
# through the disk guard and belongs to a normal `recall` call, once the disk
# has room).
LIVE_STATE=$(PYTHONPATH="$(dirname "$RECALL_LIB")" "$VENV_PY" -c '
import recall_lib as rl
msgs = []
idx = rl.load_index(progress=msgs.append)
print("LOADS" if idx is not None else "UNUSABLE: " + " | ".join(msgs))
' 2>&1)
case "$LIVE_STATE" in
    LOADS) log "live index loads and its parts agree ✓" ;;
    UNUSABLE*) fail "live index is unusable and needs a from-scratch rebuild ($LIVE_STATE) -- run 'recall \"x\"' once the disk is above the heavy-guard floor (scripts/heavy-guard.sh --check); recall exits 3 while the guard defers it" ;;
    *) fail "could not probe the live index: $LIVE_STATE" ;;
esac

log "Running live 'recall' against the real production index ..."
LIVE_OUT="$("$VENV_PY" "$CITY/scripts/recall.py" -q "teste prod-test ga-m1sa2l recall funcionando" 2>&1)"
LIVE_RC=$?
[[ $LIVE_RC -eq 0 ]] \
  || fail "live recall CLI exited $LIVE_RC (expected 0; 3 = could not search) -- output: $LIVE_OUT"
log "  live recall CLI exited 0 ✓"

log "PASS — recall index is published atomically as a whole generation, an inconsistent index no longer loads, and the live recall CLI works"
exit 0
