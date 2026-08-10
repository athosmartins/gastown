#!/usr/bin/env bash
# prod-tests/gascity/story-ga-9e8ks.sh — prod test for ga-9e8ks: derive() swap
# fatia 4/6 (_session_is_active_owner's 2 call sites, L4357/L6846 per the
# story, now bridged to bead_state.is_active_owner — docs/pilot-dispatcher-
# derive-swap-decisions.md, Decisions 1+2).
#
# Verifies the DEPLOYED packs/town-deltas/assets/pilot-dispatcher.sh (not this
# worktree's copy) genuinely bridges _session_is_active_owner to
# bead_state.is_active_owner(), and that the bridge preserves the exact
# ga-46wq5 semantics (active / idle-beyond-threshold / asleep). A pure
# verdict-matching test can't discriminate old vs. new — the bridge is
# DESIGNED to agree with the pre-slice jq check on well-formed input — so the
# first check is structural: grep for the bridge's own import line, which the
# pre-slice deployed file cannot contain at all. Extracts the real helper defs
# (same awk technique pilot-dispatcher.assignee-liveness.selftest.sh already
# uses) so this exercises shipped code, never a copy.
#
# Called by run.sh after deploy (STORY_ID=ga-9e8ks). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SRC="$CITY/packs/town-deltas/assets/pilot-dispatcher.sh"

log()  { echo "[prod-test:gascity ga-9e8ks] $*"; }
fail() { echo "[prod-test:gascity ga-9e8ks] FAIL: $*" >&2; exit 1; }

# ── 1. Deployed file exists ─────────────────────────────────────────────────
[[ -f "$SRC" ]] || fail "deployed pilot-dispatcher.sh missing: $SRC"
log "Deployed pilot-dispatcher.sh found: $SRC"

# ── 2. Structural: the bridge's own import must be present ─────────────────
# The pre-slice-4 file has NO reference to bead_state.is_active_owner at all
# (_session_is_active_owner was pure jq/grep) — this line's mere presence is
# proof the swap deployed, before any behavioral check runs.
grep -q "from bead_state import is_active_owner" "$SRC" \
  || fail "deployed _session_is_active_owner has no bead_state.is_active_owner bridge — fatia 4/6 not deployed"
log "bridge import present in deployed file"

# ── Extract the real helper defs (same range the selftest extracts) ────────
SNIP="$(awk '/^_LIVE_SESSION_IDS=\$\(echo "\$_SESSIONS_JSON" \\/{f=1}
             f{print}
             /^_session_is_active_owner\(\)/{g=1}
             g&&/^}/{exit}' "$SRC")"
case "$SNIP" in
  *_session_is_active_owner*) : ;;
  *) fail "could not extract liveness helpers from deployed file — did they move/rename?" ;;
esac
case "$SNIP" in
  *_SESSION_META_JSON*) : ;;
  *) fail "extracted snippet lost _SESSION_META_JSON — awk markers drifted or the swap regressed" ;;
esac

# ── 3. Behavioral: exact ga-46wq5 fixture shapes, real bead_state.py ───────
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OVER_ISO="$(date -u -v-200M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$NOW_ISO")"

# ga-9e8ks gate-fix (attempt 2): _session_is_active_owner locates bead_state.py
# via a BASH_SOURCE[0]-relative "../../../scripts" walk from wherever it is
# DEFINED. eval'd here, BASH_SOURCE[0] resolves to THIS script's own path
# (prod-tests/gascity/story-ga-9e8ks.sh — one directory level deeper than
# pilot-dispatcher.sh), so the walk lands one level short and the bridge
# silently falls through to the pre-existing $_ACTIVE_OWNER_IDS grep fallback
# — the exact "test passes without exercising the path it claims to test"
# the gate FAIL caught (proved live: identical PASS output even with
# bead_state.py deleted entirely from a scratch tree). Set the bridge's own
# documented escape hatch so it never needs BASH_SOURCE-based resolution
# inside this eval — same variable the shipped code already checks first.
export PILOT_BEAD_STATE_PY_OVERRIDE="$CITY/scripts/bead_state.py"
[[ -f "$PILOT_BEAD_STATE_PY_OVERRIDE" ]] \
  || fail "PILOT_BEAD_STATE_PY_OVERRIDE target missing: $PILOT_BEAD_STATE_PY_OVERRIDE — cannot verify the real bridge"

export _SESSIONS_JSON='{"sessions":[
  {"session_name":"prodtest-active","state":"active","closed":false,"last_active":"'"$NOW_ISO"'"},
  {"session_name":"prodtest-idle","state":"active","closed":false,"last_active":"'"$OVER_ISO"'"},
  {"session_name":"prodtest-asleep","state":"asleep","closed":false,"last_active":"0001-01-01T00:00:00Z"}
]}'
eval "$SNIP"

_session_is_active_owner "prodtest-active" \
  || fail "recently-active session read as not-active (bridge broke the CONTROL case)"
_session_is_active_owner "prodtest-idle" \
  && fail "idle-beyond-threshold (200min > default 180min) session read as active (bridge lost the idle check)"
_session_is_active_owner "prodtest-asleep" \
  && fail "asleep session (zero-sentinel last_active) read as active (bridge lost the ga-46wq5 asleep check — the exact bug this predicate exists to fix)"

log "behavioral checks OK: active/idle/asleep all resolve correctly through the real bead_state.py bridge"
log "PASS — derive() swap fatia 4/6 (_session_is_active_owner -> is_active_owner) deployed and behaviorally correct"
exit 0
