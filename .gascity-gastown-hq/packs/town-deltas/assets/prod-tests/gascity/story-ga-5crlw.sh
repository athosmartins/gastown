#!/usr/bin/env bash
# prod-tests/gascity/story-ga-5crlw.sh — prod test for ga-5crlw: derive() swap
# fatia 5/6 (_session_is_live_builder's 2 call sites + the liveness sub-check
# inside _beadid_live_crew_owner, now bridged to bead_state.is_live_builder /
# holder_is_alive — docs/pilot-dispatcher-derive-swap-decisions.md, Decision 1).
#
# Verifies the DEPLOYED packs/town-deltas/assets/pilot-dispatcher.sh (not this
# worktree's copy) genuinely bridges both call sites, and that the bridge
# preserves the exact "-adhoc- + asleep = dead" semantics (ga-mrfb) while
# keeping a NAMED/non-adhoc crew's asleep-but-still-owner semantics intact
# (the opposite rule from is_active_owner, on purpose — Decision 1). A pure
# verdict-matching test can't discriminate old vs. new — the bridge is
# DESIGNED to agree with the pre-slice bash check on well-formed input — so
# the first checks are structural: grep for each bridge's own import line,
# which the pre-slice deployed file cannot contain at all.
#
# ga-9e8ks gate-fix attempt 1 (this slice's own predecessor) shipped a prod
# test whose eval-based extraction silently exercised the pre-existing
# fallback instead of the real bridge (BASH_SOURCE[0] resolved to this
# script's own path, one directory level deeper than pilot-dispatcher.sh,
# breaking the bridge's default relative-path resolution) — proven live by
# an unmodified-test / bead_state.py-deleted control that produced identical
# PASS output either way. This test avoids that class of bug the same way
# attempt 2 fixed it: export PILOT_BEAD_STATE_PY_OVERRIDE explicitly before
# eval'ing the extracted snippet, so the bridge never needs BASH_SOURCE-based
# resolution inside this script at all.
#
# Called by run.sh after deploy (STORY_ID=ga-5crlw). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SRC="$CITY/packs/town-deltas/assets/pilot-dispatcher.sh"

log()  { echo "[prod-test:gascity ga-5crlw] $*"; }
fail() { echo "[prod-test:gascity ga-5crlw] FAIL: $*" >&2; exit 1; }

# ── 1. Deployed file exists ─────────────────────────────────────────────────
[[ -f "$SRC" ]] || fail "deployed pilot-dispatcher.sh missing: $SRC"
log "Deployed pilot-dispatcher.sh found: $SRC"

# ── 2. Structural: both bridges' own imports must be present ───────────────
# Pre-slice-5, neither line exists anywhere in the file — mere presence is
# proof both swaps deployed, before any behavioral check runs.
grep -q "from bead_state import is_live_builder" "$SRC" \
  || fail "deployed _session_is_live_builder has no bead_state.is_live_builder bridge — fatia 5/6 (call sites) not deployed"
log "is_live_builder bridge import present in deployed file"

grep -q "from bead_state import holder_is_alive" "$SRC" \
  || fail "deployed _beadid_live_crew_owner has no bead_state.holder_is_alive bridge — fatia 5/6 (sub-check) not deployed"
log "holder_is_alive bridge import present in deployed file (_beadid_live_crew_owner sub-check)"

# ── Extract the real helper defs (same range the session-liveness selftest
#    extracts) ───────────────────────────────────────────────────────────────
SNIP="$(awk '/^_LIVE_SESSION_IDS=\$\(echo "\$_SESSIONS_JSON" \\/{f=1}
             f{print}
             /^_session_is_live_builder\(\)/{g=1}
             g&&/^}/{exit}' "$SRC")"
case "$SNIP" in
  *_session_is_live_builder*) : ;;
  *) fail "could not extract liveness helpers from deployed file — did they move/rename?" ;;
esac
case "$SNIP" in
  *is_live_builder*) : ;;
  *) fail "extracted snippet lost the is_live_builder bridge call — awk markers drifted or the swap regressed" ;;
esac

# ga-9e8ks gate-fix attempt 2's fix, applied proactively here from the start
# (see file header) — never rely on BASH_SOURCE-based resolution inside an
# eval'd extraction.
export PILOT_BEAD_STATE_PY_OVERRIDE="$CITY/scripts/bead_state.py"
[[ -f "$PILOT_BEAD_STATE_PY_OVERRIDE" ]] \
  || fail "PILOT_BEAD_STATE_PY_OVERRIDE target missing: $PILOT_BEAD_STATE_PY_OVERRIDE — cannot verify the real bridge"

# ── 3. Behavioral: _session_is_live_builder, real bead_state.py ────────────
export _SESSIONS_JSON='{"sessions":[
  {"session_name":"prodtest-named-active","state":"active","closed":false},
  {"session_name":"prodtest-named-asleep","state":"asleep","closed":false},
  {"session_name":"prodtest-adhoc-awake","state":"active","closed":false},
  {"session_name":"prodtest-adhoc-asleep","state":"asleep","closed":false}
]}'
eval "$SNIP"

_session_is_live_builder "prodtest-named-active" \
  || fail "awake named crew read as dead builder (bridge broke the CONTROL case)"
_session_is_live_builder "prodtest-named-asleep" \
  || fail "ASLEEP named crew read as dead builder — Decision 1's asleep-named-crew-still-owns-it rule lost (would wrongly release a bead a REUSE-woken crew still owns)"
_session_is_live_builder "prodtest-adhoc-awake" \
  || fail "awake adhoc worker read as dead builder (bridge broke the CONTROL case for pool workers)"
_session_is_live_builder "prodtest-adhoc-asleep" \
  && fail "ASLEEP adhoc worker read as live builder (bridge lost the ga-mrfb '-adhoc-+asleep=dead' check — the exact bug this predicate exists to fix)"

log "behavioral checks OK: named-active/named-asleep/adhoc-awake/adhoc-asleep all resolve correctly through the real bead_state.py bridge"
log "PASS — derive() swap fatia 5/6 (_session_is_live_builder + _beadid_live_crew_owner sub-check) deployed and behaviorally correct"
exit 0
