#!/usr/bin/env bash
# prod-tests/gascity/story-ga-qubtx.sh — prod test for ga-qubtx: derive() swap
# fatia 6/6 (dispatch_one's inline liveness reimplementation).
#
# INVESTIGATION FINDING (full evidence in
# docs/pilot-dispatcher-derive-swap-decisions.md's slice-6 addendum): after
# slices 1-5 shipped, dispatch_one's 1823-line body contains NO inline/direct
# reimplementation of the "alive is None never becomes dead" principle. Every
# liveness-consulting call site delegates to a named function —
# _beadid_live_crew_owner (2 sites) or _session_is_active_owner (1 site) —
# both already bridged to bead_state.py by slice 5 (ga-5crlw) and slice 4
# (ga-9e8ks) respectively, via their "rewrite the target function's
# internals, not its external callers" strategy. That strategy transparently
# propagated the bridge to dispatch_one's existing call sites with no diff
# required in dispatch_one's own body. _sling_is_live's 1 call site is
# correctly excluded per Decision 3's boundary note (not a session
# predicate).
#
# ZERO changes to dispatch_one's own logic ship with this bead — this
# prod-test is therefore a REGRESSION GUARD, not a bridge-behavior test (that
# behavior is already proven live by ga-5crlw's and ga-9e8ks's own
# prod-tests). It fails if dispatch_one ever (a) stops delegating to the
# bridged functions, or (b) grows a fresh inline reimplementation using the
# raw session-roster globals directly — silently reintroducing the exact
# duplication class ga-4oc2k catalogued and this whole swap initiative exists
# to remove.
#
# Called by run.sh after deploy (STORY_ID=ga-qubtx). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SRC="$CITY/packs/town-deltas/assets/pilot-dispatcher.sh"

log()  { echo "[prod-test:gascity ga-qubtx] $*"; }
fail() { echo "[prod-test:gascity ga-qubtx] FAIL: $*" >&2; exit 1; }

# ── 0. Deployed file exists ─────────────────────────────────────────────────
[[ -f "$SRC" ]] || fail "deployed pilot-dispatcher.sh missing: $SRC"
log "Deployed pilot-dispatcher.sh found: $SRC"

# ── 1. Extract dispatch_one's body (structural check only, no eval — the
#    function is ~1800 lines and this test doesn't need to RUN it, only read
#    it) ──────────────────────────────────────────────────────────────────
# NOTE: every check below reads $DISPATCH_ONE_BODY via a here-string (<<<),
# never `printf ... | grep/wc`. Under `set -o pipefail`, `grep -q` exits the
# instant it finds a match, which can SIGPIPE the upstream `printf` before it
# finishes writing — printf's own non-zero (128+SIGPIPE) exit then becomes the
# PIPELINE's exit status (pipefail takes the last non-zero, not "did grep
# match"), so `if producer | grep -q pat; then` silently reads as false EVEN
# WHEN grep matched. Caught live while writing this test: an injected-match
# mutation control in section 3 below produced a false PASS with the pipe
# form. A here-string has no second process and no SIGPIPE path.
DISPATCH_ONE_BODY="$(awk '/^dispatch_one\(\) \{/{f=1} f{print; if (/^\}/) exit}' "$SRC")"
[[ -n "$DISPATCH_ONE_BODY" ]] \
  || fail "could not extract dispatch_one — did it move/rename? (awk found nothing)"
DISPATCH_ONE_LINES=$(wc -l <<<"$DISPATCH_ONE_BODY" | tr -d ' ')
[[ "$DISPATCH_ONE_LINES" -gt 1000 ]] \
  || fail "extracted dispatch_one is only $DISPATCH_ONE_LINES lines — extraction likely broke (expected 1800+)"
log "dispatch_one extracted: $DISPATCH_ONE_LINES lines"

# ── 2. Positive: still delegates to the two already-bridged functions ──────
_BLC_CALLS=$(grep -c '_beadid_live_crew_owner "' <<<"$DISPATCH_ONE_BODY" || true)
[[ "$_BLC_CALLS" -ge 2 ]] \
  || fail "_beadid_live_crew_owner called only $_BLC_CALLS time(s) inside dispatch_one, want >=2 — a call site was removed or dispatch_one stopped delegating (ga-lfvs6/ga-jazy9 owner-honoring paths)"
log "_beadid_live_crew_owner delegation intact: $_BLC_CALLS call sites"

_SAO_CALLS=$(grep -c '_session_is_active_owner "' <<<"$DISPATCH_ONE_BODY" || true)
[[ "$_SAO_CALLS" -ge 1 ]] \
  || fail "_session_is_active_owner called $_SAO_CALLS time(s) inside dispatch_one, want >=1 — the ga-jzye0 gate-f delegation was removed"
log "_session_is_active_owner delegation intact: $_SAO_CALLS call site(s)"

# ── 3. Negative: no fresh inline reimplementation using the raw roster
#    globals directly (the exact regression this test guards against) ──────
for _raw_signal in '_LIVE_SESSION_IDS' '_ASLEEP_SESSION_IDS' '_SESSIONS_JSON' \
                    '_SESSIONS_IDLE_JSON' '_SESSION_META_JSON' '_ACTIVE_OWNER_IDS'; do
  if grep -q "$_raw_signal" <<<"$DISPATCH_ONE_BODY"; then
    fail "dispatch_one now references \$$_raw_signal directly — a NEW inline liveness reimplementation was likely added, bypassing the bridged functions (the exact duplication class this slice verified was absent)"
  fi
done
log "no direct raw session-roster reference inside dispatch_one (no regression toward re-inlining)"

# ── 4. Chain integrity: the functions dispatch_one delegates TO must
#    themselves still carry their bead_state.py bridge (proven behaviorally
#    by ga-5crlw's/ga-9e8ks's own prod-tests; here just a structural
#    presence check tying the chain together end to end) ───────────────────
# $-anchored: "holder_is_alive" is also a prefix of "holder_is_alive_RENAMED"
# (or any future rename), which an unanchored grep would still match.
grep -q "^from bead_state import holder_is_alive\$" "$SRC" \
  || fail "_beadid_live_crew_owner's holder_is_alive bridge import missing from deployed file — ga-5crlw regressed"
grep -q "^from bead_state import is_active_owner\$" "$SRC" \
  || fail "_session_is_active_owner's is_active_owner bridge import missing from deployed file — ga-9e8ks regressed"
log "upstream bridges (ga-5crlw, ga-9e8ks) still present — delegation chain intact end to end"

log "PASS — derive() swap fatia 6/6 verified as a no-op-by-design: dispatch_one has no inline liveness reimplementation, delegates entirely to already-bridged _beadid_live_crew_owner/_session_is_active_owner, and this regression guard confirms neither the delegation nor the upstream bridges have drifted"
exit 0
