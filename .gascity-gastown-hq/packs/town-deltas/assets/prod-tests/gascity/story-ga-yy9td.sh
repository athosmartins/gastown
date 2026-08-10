#!/usr/bin/env bash
# prod-tests/gascity/story-ga-yy9td.sh — prod test for ga-yy9td: derive() swap
# fatia 3/6 (bead_state.py ganha has_active_branch, decisão 3 de
# docs/pilot-dispatcher-derive-swap-decisions.md).
#
# Verifies the DEPLOYED scripts/bead_state.py (not this worktree's copy) has
# has_active_branch wired into rule 7: a bead with alive=False (detentor
# provado morto) but has_active_branch=True resolves 'executing', never
# 'stranded' — porting the branch-existence shortcut _sling_is_live already
# uses in bash. has_active_branch=False (or omitted) must NOT protect —
# regression proving only `is True` engages it, never truthiness (Decisão 4,
# item 2).
#
# Called by run.sh after deploy (STORY_ID=ga-yy9td). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
BSP="$CITY/scripts/bead_state.py"

log()  { echo "[prod-test:gascity ga-yy9td] $*"; }
fail() { echo "[prod-test:gascity ga-yy9td] FAIL: $*" >&2; exit 1; }

# ── 1. Deployed file exists ───────────────────────────────────────────────────
[[ -f "$BSP" ]] || fail "deployed bead_state.py missing: $BSP"
log "Deployed bead_state.py found: $BSP"

RESULT=$(PYTHONPATH="$(dirname "$BSP")" python3 -c '
import sys
try:
    from bead_state import derive
except ImportError as e:
    print("IMPORT_FAIL:" + str(e))
    sys.exit(0)


def bead(**kw):
    d = {"status": "in_progress", "labels": [], "assignee": "mila-wa", "metadata": {}}
    d.update(kw)
    return d


# frozenset() (not None) = "consultei sessoes vivas, ninguem bate" -> alive=False
DEAD = frozenset()

# ── has_active_branch precisa existir como kwarg (regressao pre-slice seria
# TypeError aqui) ─────────────────────────────────────────────────────────────
try:
    st_true = derive(bead(), DEAD, frozenset(), has_active_branch=True)
except TypeError as e:
    print("KWARG_MISSING:" + str(e))
    sys.exit(0)

checks = []

# ── Decisao 3: alive=False + branch ativo -> executing, nunca stranded ──────
checks.append(("branch_true_protects_from_stranded",
               st_true["state"] == "executing" and "liberar_para_pool" not in st_true["actions"]))

# ── Regressao: has_active_branch=False NAO protege (so True explicito) ──────
st_false = derive(bead(), DEAD, frozenset(), has_active_branch=False)
checks.append(("branch_false_still_stranded", st_false["state"] == "stranded"))

# ── Regressao: omitido == comportamento pre-slice (stranded) ────────────────
st_omitted = derive(bead(), DEAD, frozenset())
checks.append(("omitted_still_stranded", st_omitted["state"] == "stranded"))

failed = [name for name, ok in checks if not ok]
if failed:
    print("CHECKS_FAILED:" + ",".join(failed))
else:
    print("ALL_OK")
' 2>&1)

if [[ "$RESULT" == IMPORT_FAIL:* ]]; then
    fail "derive not importable from deployed bead_state.py: ${RESULT#IMPORT_FAIL:}"
elif [[ "$RESULT" == KWARG_MISSING:* ]]; then
    fail "deployed derive() does not accept has_active_branch: ${RESULT#KWARG_MISSING:}"
elif [[ "$RESULT" == CHECKS_FAILED:* ]]; then
    fail "behavioral checks failed: ${RESULT#CHECKS_FAILED:}"
elif [[ "$RESULT" != "ALL_OK" ]]; then
    fail "unexpected output from verification snippet: $RESULT"
fi
log "has_active_branch live and correct: True protects a proven-dead bead from stranded, False/omitted preserve prior behavior ✓"

log "PASS — derive() swap fatia 3/6 (has_active_branch, Decisão 3) deployed and behaviorally correct"
exit 0
