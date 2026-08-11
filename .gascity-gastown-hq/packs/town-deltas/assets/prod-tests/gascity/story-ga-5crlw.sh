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

# ── 3. Direct bridge-function verification (gate-fix attempt 1, gate_run=
#    ga-zefzz) — exit code checked explicitly, nothing swallowed ──────────────
# The behavioral checks in section 4 go through _session_is_live_builder's own
# bash wrapper, which — by design (fail-open resilience, the same pattern
# slice 4 shipped) — swallows python3's stderr (`2>/dev/null`) and has no
# wildcard case arm, so it falls through to an identical-answer bash fallback
# on ANY unexpected python3 output, including a silently-broken bridge
# (ImportError, AttributeError, a future rename of is_live_builder). Because
# this slice is a byte-faithful port, that fallback produces the SAME
# verdicts the real bridge would for well-formed input — so section 4's
# checks alone cannot prove the bridge ran at all, only that SOMETHING
# (bridge or fallback) produced the right answer. Reviewer proved this live:
# renaming is_live_builder in a sandbox copy left section 4's checks (as
# originally written, unchanged) reporting PASS.
#
# Call both new bridge functions DIRECTLY here, exactly as pilot-dispatcher.sh
# itself calls them (same PYTHONPATH, same import, same argument shapes each
# bridge actually passes — is_live_builder gets the rich {state} dict form,
# holder_is_alive gets the plain list form _beadid_live_crew_owner builds),
# capturing python3's exit code explicitly. This is what section 4 cannot do:
# an ImportError/AttributeError/rename here surfaces as a NONZERO exit and an
# explicit FAIL, not a swallowed exception masked by a correctly-answering
# fallback. Also covers holder_is_alive, which section 4 never behaviorally
# exercised at all (only grep-checked for the import string) — the
# reviewer's second, non-blocking observation.
_verify_direct() {
  local desc="$1" pyexpr="$2" expect="$3" out rc
  out=$(PYTHONPATH="$CITY/scripts" python3 -c "$pyexpr" 2>&1)
  rc=$?
  [[ $rc -eq 0 ]] \
    || fail "$desc: python3 exited $rc — bridge function is broken/unimportable (not silently swallowed here). Output: $out"
  [[ "$out" == "$expect" ]] \
    || fail "$desc: python3 exited 0 but printed '$out', want '$expect' — bridge callable but wrong output"
  log "$desc: OK (direct call, exit 0, output '$out')"
}

_verify_direct "is_live_builder importable+correct (adhoc+asleep -> False)" \
  'from bead_state import is_live_builder; print(is_live_builder("x-adhoc-1", {"x-adhoc-1": {"state": "asleep"}}))' \
  "False"
_verify_direct "is_live_builder importable+correct (named+asleep -> True, opposite rule)" \
  'from bead_state import is_live_builder; print(is_live_builder("named-crew", {"named-crew": {"state": "asleep"}}))' \
  "True"
_verify_direct "holder_is_alive importable+correct (plain-list form, as _beadid_live_crew_owner passes it)" \
  'from bead_state import holder_is_alive; print(holder_is_alive("named-crew", ["named-crew"]))' \
  "True"

# ── 4. Behavioral: _session_is_live_builder end-to-end (bash wrapper + real
#    bead_state.py) — the full integration section 3 alone doesn't cover ──
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

log "end-to-end behavioral checks OK: named-active/named-asleep/adhoc-awake/adhoc-asleep all resolve correctly through _session_is_live_builder's bash wrapper"

# ── 5. Mutation-test the SOURCE fix itself (gate-fix attempt 1, gate_run=
#    ga-zefzz): sections 3+4 above prove the bridge FUNCTIONS are correct,
#    but neither exercises the bash WRAPPER's own error handling — the
#    actual thing the reviewer's blocking issue was about. Simulate exactly
#    the failure class named in the FAIL (a future rename of is_live_builder
#    causing ImportError) by pointing PILOT_BEAD_STATE_PY_OVERRIDE at a
#    deliberately-broken copy of bead_state.py, then assert BOTH: (a) the
#    fix's new stderr warning actually fires, and (b) the fallback VERDICT
#    is byte-identical to before this fix — this attempt only adds
#    observability, it must never change the fail-open fallback behavior
#    itself (that would be a functional regression, not a fix).
_MUT_DIR="$(mktemp -d)"
_MUT_BROKEN_PY="$_MUT_DIR/bead_state.py"
sed 's/^def is_live_builder/def is_live_builder_RENAMED_FOR_MUTATION_TEST/' \
  "$CITY/scripts/bead_state.py" > "$_MUT_BROKEN_PY"
grep -q "^def is_live_builder_RENAMED_FOR_MUTATION_TEST" "$_MUT_BROKEN_PY" \
  || fail "mutation setup failed — sed did not rename is_live_builder in the broken copy"
grep -q "^def is_live_builder(" "$_MUT_BROKEN_PY" \
  && fail "mutation setup failed — original is_live_builder still present, mutation didn't take"

# _session_is_live_builder's new warn() call (gate-fix attempt 1) is a REAL
# pilot-dispatcher.sh function defined outside the SNIP range above (near the
# top of the file, alongside log()/err()) — extract its exact real definition
# too, rather than stubbing a look-alike, so this test exercises the actual
# deployed warn() output, not an approximation of it.
_WARN_DEF="$(grep '^warn() {' "$SRC")"
case "$_WARN_DEF" in
  warn\(\)*) : ;;
  *) fail "could not extract warn() from deployed file — did its definition move/change shape?" ;;
esac
eval "$_WARN_DEF"

_MUT_STDERR="$(mktemp)"
PILOT_BEAD_STATE_PY_OVERRIDE="$_MUT_BROKEN_PY" \
  _session_is_live_builder "prodtest-named-active" 2>"$_MUT_STDERR"
_MUT_RC=$?
rm -rf "$_MUT_DIR"

[[ $_MUT_RC -eq 0 ]] \
  || { rm -f "$_MUT_STDERR"; fail "broken-bridge fallback changed behavior: expected rc=0 (named+active -> live builder via bash fallback, same as before this fix), got $_MUT_RC — a fix for observability must never change the fail-open fallback verdict"; }

grep -q "bridge is_live_builder() quebrado" "$_MUT_STDERR" \
  || { _mut_captured="$(cat "$_MUT_STDERR")"; rm -f "$_MUT_STDERR"; fail "gate-fix attempt 1 regression: broken bridge (renamed is_live_builder, ImportError) produced NO visible warning on stderr — this is the exact reviewer FAIL (gate_run=ga-zefzz) this attempt exists to fix. stderr captured: '$_mut_captured'"; }
rm -f "$_MUT_STDERR"

log "mutation-test OK: broken bridge (renamed is_live_builder, simulates ImportError) now produces a visible stderr warning AND the fallback verdict is unchanged (rc=0, same as a working bridge would give for this input)"

log "PASS — derive() swap fatia 5/6 deployed: both bridge functions directly verified importable+correct (section 3, exit-code checked), _session_is_live_builder's full bash-to-python integration verified behaviorally correct (section 4), and gate-fix attempt 1's stderr-visibility-on-broken-bridge fix mutation-verified against the actual deployed wrapper (section 5)"
exit 0
