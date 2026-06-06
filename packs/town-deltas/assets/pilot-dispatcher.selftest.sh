#!/usr/bin/env bash
# pilot-dispatcher.selftest.sh — smoke tests for pilot-dispatcher.sh
#
# Tests use DRY_RUN=1 + PILOT_CITY_OVERRIDE into a temp fixture dir.
# bd commands fail gracefully (|| echo "[]") when the fixture has no Dolt DB,
# so the dispatcher reaches "No dispatchable candidates" and exits 0.
# Structural tests grep the script for design-invariant properties.
#
# Run: bash pilot-dispatcher.selftest.sh
# Exit: 0 = all pass, 1 = any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PILOT="$SCRIPT_DIR/pilot-dispatcher.sh"

PASS=0; FAIL=0; TOTAL=0

_pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); printf "[PASS] %s\n" "$1"; }
_fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); printf "[FAIL] %s\n" "$1"; }

# ── Test 1: DRY_RUN exits 0 with empty fixture ─────────────────────────────────
TMP=$(mktemp -d)
mkdir -p "$TMP/.gc/logs"
_rc=0
PILOT_CITY_OVERRIDE="$TMP" DRY_RUN=1 bash "$PILOT" >/dev/null 2>&1 || _rc=$?
[ "$_rc" -eq 0 ] \
  && _pass "DRY_RUN with empty fixture exits 0" \
  || _fail "DRY_RUN with empty fixture exits $_rc (expected 0)"
[ -f "$TMP/.gc/logs/pilot-dispatcher.log" ] \
  && _pass "Log file created" \
  || _fail "Log file not found at $TMP/.gc/logs/pilot-dispatcher.log"
rm -rf "$TMP"

# ── Test 2: SELF_BEAD_ID not a hardcoded bead literal ─────────────────────────
grep -qE '^SELF_BEAD_ID="[a-z]+-[0-9a-z]+"' "$PILOT" \
  && _fail "SELF_BEAD_ID: hardcoded bead ID literal detected" \
  || _pass "SELF_BEAD_ID: not a hardcoded bead ID literal"

# ── Test 3: SELF_BEAD_ID resolved via pilot:self label ────────────────────────
grep -q 'pilot:self' "$PILOT" \
  && _pass "SELF_BEAD_ID: pilot:self label query present" \
  || _fail "SELF_BEAD_ID: no pilot:self reference found"

# ── Test 4: TTL recovery has no story:approved filter ─────────────────────────
# Extract lines from the STALE_JSON block and check for absence of story:approved.
if awk '/Step 0.*TTL recovery/,/STALE_COUNT/' "$PILOT" | grep -q '"story:approved"'; then
  _fail "TTL recovery: story:approved filter still present (Tier 1 claims never recovered)"
else
  _pass "TTL recovery: no story:approved filter"
fi

# ── Test 5: COMMON_EXCLUDES array defined ─────────────────────────────────────
grep -q 'COMMON_EXCLUDES=(' "$PILOT" \
  && _pass "COMMON_EXCLUDES: array defined" \
  || _fail "COMMON_EXCLUDES: array not defined"

# ── Test 6: story:in-flight added before pilot:dispatching removed ─────────────
# Within _transition_bead, in-flight must precede the dispatching remove.
_inflight=$(awk '/_transition_bead\(\)/,/^}/' "$PILOT" \
  | grep -n 'label add.*story:in-flight' | head -1 | cut -d: -f1 || echo "")
_rm_dispatch=$(awk '/_transition_bead\(\)/,/^}/' "$PILOT" \
  | grep -n 'label remove.*pilot:dispatching' | head -1 | cut -d: -f1 || echo "")
if [ -n "$_inflight" ] && [ -n "$_rm_dispatch" ] && [ "$_inflight" -lt "$_rm_dispatch" ]; then
  _pass "transition_bead: story:in-flight set before pilot:dispatching removed"
else
  _fail "transition_bead: wrong order or missing labels (inflight=$_inflight rm_dispatch=$_rm_dispatch)"
fi

# ── Test 7: story:in-flight failure leaves pilot:dispatching for TTL recovery ──
# _transition_bead must NOT use || true on the story:in-flight add.
if awk '/_transition_bead\(\)/,/^}/' "$PILOT" \
    | grep 'label add.*story:in-flight' | grep -q '|| true'; then
  _fail "transition_bead: story:in-flight add is || true (silent race condition)"
else
  _pass "transition_bead: story:in-flight add is NOT silently guarded"
fi

# ── Test 8: Task prompt uses BEAD_DB not GC_CITY in bd -C show ────────────────
# Inside _build_task_prompt, the step-1 read command must reference BEAD_DB.
if awk '/_build_task_prompt\(\)/,/^}/' "$PILOT" \
    | grep 'bd -C.*show.*STORY_ID' | grep -q 'GC_CITY'; then
  _fail "Task prompt: step-1 bd show uses GC_CITY instead of BEAD_DB for rig-sourced beads"
else
  _pass "Task prompt: step-1 bd show uses BEAD_DB"
fi

# ── Test 9: All 5 dispatch sub-functions defined ──────────────────────────────
for _fn in _claim_bead _build_task_prompt _do_sling _transition_bead _notify_dispatch; do
  grep -q "^${_fn}()" "$PILOT" \
    && _pass "sub-function defined: ${_fn}" \
    || _fail "sub-function MISSING: ${_fn}"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
printf "── Results: %d/%d passed ──\n" "$PASS" "$TOTAL"
[ "$FAIL" -eq 0 ]
