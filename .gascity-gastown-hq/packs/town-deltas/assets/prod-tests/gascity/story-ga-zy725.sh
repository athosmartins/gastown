#!/usr/bin/env bash
# prod-tests/gascity/story-ga-zy725.sh — prod test for ga-zy725: recall index
# atomic writes (tmp+rename) + corruption self-heal.
#
# Root cause (found 25/08 by 2 research agents, reproduced live before this
# fix): a disk-full mid-write left .gc/recall-index/chunk_vecs.npy truncated
# (640 of 12,647,040 elements missing). Every `recall` call crashed with a
# raw numpy ValueError ("file seems not fully written?") -- including
# `recall --rebuild`, because load_index() ran (and raised) before the
# rebuild flag was ever consulted, so the documented recovery path couldn't
# recover anything either. Fix ships two independent halves: save_index()
# writes via tmp+os.replace so a killed write can never again leave a
# truncated file at the real path, and load_index() treats an
# already-corrupted file as a cache miss (returns None -> caller rebuilds)
# instead of propagating the raw exception.
#
# Called by run.sh after deploy (STORY_ID=ga-zy725). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
VENV_PY="$CITY/.gc/recall-venv/bin/python3"
RECALL_LIB="$CITY/scripts/recall_lib.py"

log()  { echo "[prod-test:gascity ga-zy725] $*"; }
fail() { echo "[prod-test:gascity ga-zy725] FAIL: $*" >&2; exit 1; }

[[ -x "$VENV_PY" ]] || fail "recall venv python not found: $VENV_PY"
[[ -f "$RECALL_LIB" ]] || fail "deployed recall_lib.py missing: $RECALL_LIB"
log "Deployed recall_lib.py found: $RECALL_LIB"

# ── 1. Structural: atomic-write + self-heal code is actually present ───────
grep -q "^def _atomic_write(" "$RECALL_LIB" \
  || fail "_atomic_write() missing from deployed recall_lib.py -- atomic-write fix not deployed"
grep -q "os.replace(tmp, path)" "$RECALL_LIB" \
  || fail "os.replace(tmp, path) missing from deployed recall_lib.py -- atomic rename not deployed"
grep -q "except (OSError, ValueError, EOFError, json.JSONDecodeError)" "$RECALL_LIB" \
  || fail "corruption-catching except clause missing from deployed load_index() -- self-heal not deployed"
log "atomic-write + self-heal code present in deployed recall_lib.py ✓"

# ── 2. Behavioral, against the REAL deployed module (not this worktree's
#    copy) but an isolated temp index dir -- never touches the live
#    production index ───────────────────────────────────────────────────────
RESULT=$(PYTHONPATH="$(dirname "$RECALL_LIB")" "$VENV_PY" -c '
import tempfile
from pathlib import Path
from unittest import mock
import recall_lib as rl
import numpy as np

checks = []
with tempfile.TemporaryDirectory() as td:
    with mock.patch.object(rl, "INDEX_DIR", Path(td) / "recall-index"):
        idx = rl.RecallIndex(
            corpus=[{"id": "x", "store": "HQ", "title": "t", "description": "",
                     "comments": [], "close_reason": "", "closed_at": "2026-01-01T00:00:00Z",
                     "issue_type": "task", "priority": 2, "_ntok_full": 1}],
            chunk_vecs=np.ones((2, 384), dtype=np.float32),
            chunk_bead_idx=np.array([0, 0], dtype=np.int64),
            meta={"schema_version": rl.SCHEMA_VERSION},
        )
        rl.save_index(idx)
        checks.append(("round_trip_loads", rl.load_index() is not None))

        vecs_path = rl._paths()["vecs"]
        vecs_path.write_bytes(vecs_path.read_bytes()[:-8])
        checks.append(("truncated_npy_self_heals_to_none", rl.load_index() is None))

        leftovers = list((Path(td) / "recall-index").glob("*.tmp"))
        checks.append(("no_tmp_debris_after_save", leftovers == []))

failed = [name for name, ok in checks if not ok]
print("CHECKS_FAILED:" + ",".join(failed) if failed else "ALL_OK")
' 2>&1)

if [[ "$RESULT" != "ALL_OK" ]]; then
    fail "behavioral self-heal check failed: $RESULT"
fi
log "self-heal verified against deployed module (isolated tmp index dir): round-trip ok, truncated .npy -> None (not raise), no tmp debris ✓"

# ── 3. Functional: the LIVE recall CLI actually runs end to end ────────────
log "Running live 'recall' against the real production index ..."
LIVE_OUT="$("$VENV_PY" "$CITY/scripts/recall.py" -q "teste prod-test ga-zy725 recall funcionando" 2>&1)"
LIVE_RC=$?
[[ $LIVE_RC -eq 0 ]] \
  || fail "live recall CLI exited $LIVE_RC (expected 0) -- production index still broken? output: $LIVE_OUT"
log "  live recall CLI exited 0 ✓"

log "PASS — recall_lib.py atomic writes + corruption self-heal deployed and behaviorally correct; live recall CLI functional against production index"
exit 0
