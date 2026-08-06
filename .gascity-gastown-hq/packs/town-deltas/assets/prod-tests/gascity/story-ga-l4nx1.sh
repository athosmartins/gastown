#!/usr/bin/env bash
# prod-tests/gascity/story-ga-l4nx1.sh — prod test for ga-l4nx1:
# error-empty-conflation-scan.sh's QUERY_TOOL_RE was missing gc, the tool at
# the center of the bug class this scanner exists to catch (ga-p5q3/ga-07509).
#
# Verifies the fix landed on the DEPLOYED scanner: gc is in QUERY_TOOL_RE, the
# {} literal is in the C2 list, and — the regression this fix could easily
# introduce — ga-07509's own gc_json_or_unknown() fix is NOT newly flagged.
# Reuses the scanner's own selftest (already covers all of the above plus
# every pre-existing category) rather than re-asserting the same checks here.
#
# Called by run.sh after deploy (STORY_ID=ga-l4nx1). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SCANNER="$CITY/packs/town-deltas/assets/error-empty-conflation-scan.sh"
SELFTEST="$CITY/packs/town-deltas/assets/error-empty-conflation-scan.selftest.sh"

log()  { echo "[prod-test:gascity ga-l4nx1] $*"; }
fail() { echo "[prod-test:gascity ga-l4nx1] FAIL: $*" >&2; exit 1; }

[[ -f "$SCANNER" ]] || fail "scanner missing: $SCANNER"
[[ -x "$SELFTEST" ]] || fail "selftest missing or not executable: $SELFTEST"

log "Checking gc is in QUERY_TOOL_RE..."
grep -q "QUERY_TOOL_RE='.*|gc|.*'" "$SCANNER" || fail "gc not found in QUERY_TOOL_RE — the fix did not deploy"
log "  gc present ✓"

log "Checking {} is in the C2 literal list..."
grep -q '|| echo "{}"' "$SCANNER" || fail '|| echo "{}" not found in C2 literal list — the fix did not deploy'
log "  {} literal present ✓"

log "Checking the gc_json_or_unknown() exemption is present (regression guard)..."
grep -q "gc_json_or_unknown" "$SCANNER" || fail "gc_json_or_unknown exemption missing — adding gc would flag ga-07509's own fix"
log "  exemption present ✓"

log "Running the scanner's own selftest (38 assertions, covers detection + falsification end-to-end)..."
if ! "$SELFTEST" >/tmp/.story-ga-l4nx1-selftest.$$ 2>&1; then
    tail -20 "/tmp/.story-ga-l4nx1-selftest.$$" >&2
    rm -f "/tmp/.story-ga-l4nx1-selftest.$$"
    fail "scanner selftest did not pass on the deployed artifact"
fi
rm -f "/tmp/.story-ga-l4nx1-selftest.$$"
log "  selftest PASS ✓"

log "PASS — gc + {} detection deployed, gc_json_or_unknown() correctly exempted"
exit 0
