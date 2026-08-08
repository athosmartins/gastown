#!/usr/bin/env bash
# prod-tests/gascity/story-ga-ehbw5.sh — prod test for ga-ehbw5: /gate-done
# Step 3 re-reads the ready-for-gate marker right after creating it and
# self-heals gate-status:ready if the readback doesn't show it, instead of
# relying solely on gate-marker-missing-status-watchdog.sh (ga-5jyo8) to
# catch a labelless marker on its next sweep.
#
# Verifies the fix landed on the DEPLOYED commands/gate-done.md: the readback
# block is present, uses comma-boundary matching (not a bare substring grep),
# self-heals via `bd label add`, and the go:embed twin
# (internal/templates/commands/bodies/gate-done.md) stayed in sync. Reuses
# the feature's own selftest (16 assertions, covers detection + self-heal +
# fail-open + drift-guards end-to-end) rather than re-asserting the same
# checks here.
#
# Called by run.sh after deploy (STORY_ID=ga-ehbw5). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
GATE_DONE="$CITY/commands/gate-done.md"
SELFTEST="$CITY/packs/town-deltas/assets/gate-done-marker-readback-selfheal.selftest.sh"

log()  { echo "[prod-test:gascity ga-ehbw5] $*"; }
fail() { echo "[prod-test:gascity ga-ehbw5] FAIL: $*" >&2; exit 1; }

[[ -f "$GATE_DONE" ]] || fail "gate-done.md missing: $GATE_DONE"
[[ -x "$SELFTEST" ]] || fail "selftest missing or not executable: $SELFTEST"

log "Checking the marker readback+self-heal block is present in Step 3..."
grep -qF '_MARKER_LABELS=$(bd -C "$GC_CITY_PATH" show "$MARKER_ID"' "$GATE_DONE" \
  || fail "marker readback not found in deployed gate-done.md — the fix did not deploy"
log "  readback present ✓"

log "Checking the self-heal call is present..."
grep -qF 'bd -C "$GC_CITY_PATH" label add "$MARKER_ID" "gate-status:ready"' "$GATE_DONE" \
  || fail "self-heal bd label add not found in deployed gate-done.md"
log "  self-heal present ✓"

log "Checking the go:embed twin stayed in sync (ga-54iu invariant)..."
EMBEDDED="$(cd "$CITY/.." && pwd)/internal/templates/commands/bodies/gate-done.md"
if [[ -f "$EMBEDDED" ]]; then
    cmp -s "$GATE_DONE" "$EMBEDDED" || fail "canonical and go:embed twin have drifted: $EMBEDDED"
    log "  embed twin in sync ✓"
else
    log "  embed twin not found at $EMBEDDED — skipping (non-gascity-source deploy context)"
fi

log "Running the feature's own selftest (16 assertions, covers self-heal + fail-open + drift-guards end-to-end)..."
if ! "$SELFTEST" >/tmp/.story-ga-ehbw5-selftest.$$ 2>&1; then
    tail -20 "/tmp/.story-ga-ehbw5-selftest.$$" >&2
    rm -f "/tmp/.story-ga-ehbw5-selftest.$$"
    fail "selftest did not pass on the deployed artifact"
fi
rm -f "/tmp/.story-ga-ehbw5-selftest.$$"
log "  selftest PASS ✓"

log "PASS — marker readback + self-heal deployed, go:embed twin in sync"
exit 0
