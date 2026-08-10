#!/usr/bin/env bash
# prod-tests/gascity/story-ga-rwgp8.sh — prod test for ga-rwgp8: derive() swap
# fatia 2/6 (bead_state.py ganha session record ciente de idle, decisões 1+2
# de docs/pilot-dispatcher-derive-swap-decisions.md).
#
# Verifies the DEPLOYED scripts/bead_state.py (not this worktree's copy) has
# is_active_owner() live, and that it resolves the exact ga-46wq5 regression
# correctly: an asleep session (Go zero-time sentinel -> idle_minutes=None)
# must NOT read as an active owner, while a live non-asleep session with
# idle_minutes=None (fresh -adhoc- worker, last_active never populated) MUST
# read as active. A check that only inspected idle_minutes (never state)
# would pass the second case and silently fail the first — that asymmetry is
# exactly what ga-46wq5 was.
#
# Called by run.sh after deploy (STORY_ID=ga-rwgp8). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
BSP="$CITY/scripts/bead_state.py"

log()  { echo "[prod-test:gascity ga-rwgp8] $*"; }
fail() { echo "[prod-test:gascity ga-rwgp8] FAIL: $*" >&2; exit 1; }

# ── 1. Deployed file exists and exposes is_active_owner ──────────────────────
[[ -f "$BSP" ]] || fail "deployed bead_state.py missing: $BSP"
log "Deployed bead_state.py found: $BSP"

RESULT=$(PYTHONPATH="$(dirname "$BSP")" python3 -c '
import sys
try:
    from bead_state import is_active_owner
except ImportError as e:
    print("IMPORT_FAIL:" + str(e))
    sys.exit(0)

checks = []

# ── ga-46wq5, metade 1: idle desconhecido numa sessão NAO-asleep -> ATIVO ────
live_unknown_idle = {"ps-adhoc-x1": {"state": "active", "idle_minutes": None}}
checks.append(("idle_none_not_asleep_is_active",
               is_active_owner("ps-adhoc-x1", live_unknown_idle) is True))

# ── ga-46wq5, metade 2 (o fixture original): sentinela zero do Go -> asleep,
# idle_minutes=None -> NAO ativo. Mesmo idle_minutes do caso acima; só o
# state distingue os dois — é o check que o bug ga-46wq5 pedia.
asleep_zero_sentinel = {"ps-adhoc-x1": {"state": "asleep", "idle_minutes": None}}
checks.append(("asleep_zero_sentinel_is_not_active",
               is_active_owner("ps-adhoc-x1", asleep_zero_sentinel) is False))

# ── nao consultei -> None, nunca False (mesmo contrato de holder_is_alive) ──
checks.append(("not_consulted_is_none", is_active_owner("mila-wa", None) is None))

# ── idle abaixo/acima do threshold ───────────────────────────────────────────
below = {"mila-wa-x1": {"state": "active", "idle_minutes": 10}}
above = {"mila-wa-x1": {"state": "active", "idle_minutes": 999}}
checks.append(("idle_below_threshold_is_active",
               is_active_owner("mila-wa", below, idle_threshold_min=180) is True))
checks.append(("idle_above_threshold_is_not_active",
               is_active_owner("mila-wa", above, idle_threshold_min=180) is False))

failed = [name for name, ok in checks if not ok]
if failed:
    print("CHECKS_FAILED:" + ",".join(failed))
else:
    print("ALL_OK")
' 2>&1)

if [[ "$RESULT" == IMPORT_FAIL:* ]]; then
    fail "is_active_owner not importable from deployed bead_state.py: ${RESULT#IMPORT_FAIL:}"
elif [[ "$RESULT" == CHECKS_FAILED:* ]]; then
    fail "behavioral checks failed: ${RESULT#CHECKS_FAILED:}"
elif [[ "$RESULT" != "ALL_OK" ]]; then
    fail "unexpected output from verification snippet: $RESULT"
fi
log "is_active_owner live and correct: idle-unknown/not-asleep -> active, asleep-zero-sentinel -> not active ✓"

log "PASS — derive() swap fatia 2/6 (is_active_owner, idle-aware session records) deployed and behaviorally correct"
exit 0
