#!/usr/bin/env bash
# story-delivery-daemon-proof-honesty.test.sh — regression test for ga-vmq1i:
# story-delivery marked a story "delivery:tested" / closed it with "deployed +
# verified in prod" WITHOUT ever confirming a live daemon picked up the merged
# code — measured live on wa-3dfnw (fix merged 18:20, daemon serving that route
# still running the 17:15 process two hours later, closer said "verified in
# prod" regardless).
#
# Extracts the REAL Step 8 block from story-delivery.sh (no duplication) and
# drives it with a stubbed bd/gc/notify, varying only REFRESH_PROOF (the field
# daemon-refresh.sh now emits — see daemon-refresh.test.sh), to prove:
#   H1 REFRESH_PROOF=verified       → delivery:tested added, NO
#                                      delivery:daemon-unverified, close_reason
#                                      says "tested in prod" (unchanged happy path).
#   H2 REFRESH_PROOF=not_applicable → same as H1 (nothing live to falsely claim).
#   H3 REFRESH_PROOF=not_verified   → delivery:daemon-unverified label IS added,
#                                      close_reason does NOT claim "verified in
#                                      prod" and DOES say daemon liveness was not
#                                      verified. This is the exact wa-3dfnw shape:
#                                      prod-test harness passed (STORY_TEST_MISSING=1,
#                                      baseline only) but daemon-refresh could not
#                                      confirm the live process picked up the code.
#   H4 Sanity: the literal phrase "verified in prod" never appears in ANY
#      close_reason this script can produce, regardless of REFRESH_PROOF — the
#      bug was a hardcoded, unconditional claim; this asserts it is gone for good,
#      not just correctly conditioned in the cases tested above.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the Step 8 block (from its header up to, but excluding, Step 9).
BLOCK="$(sed -n '/# ── Step 8: Mark story:done/,/# ── Step 9: Log to story-delivery.jsonl/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 8 block"; exit 1; }

# run_block <refresh_proof> [<story_test_missing>]
run_block() {
  local proof="$1" test_missing="${2:-1}"
  local T; T="$(mktemp -d)"
  BD_LOG="$T/bd.log"
  bd() {
    # bd -C <store> show <id> --json  → minimal well-formed bead for the
    # PILOT_ORIGIN re-check and the CLOSE_STATUS_NOW probe.
    if [ "$3" = "show" ]; then
      echo '{"labels":[],"status":"open"}'
      return 0
    fi
    echo "bd $*" >> "$BD_LOG"
    # `bd close` succeeds; everything else no-ops (matches production's `|| true` guards).
    return 0
  }
  notify() { :; }
  log() { :; }; warn() { :; }; err() { :; }
  refino_criteria_status_line() { echo "criteria: n/a"; }
  export -f bd notify refino_criteria_status_line 2>/dev/null || true

  local DELIVERY_START=1
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY_STORE="/tmp/ga-test-store"
  local STORY_LABELS=""
  local STORY_TITLE="Test story"
  local RIG="whatsapp_automation"
  local DEPLOY_CMD="git pull"
  local MISSING_META=""
  local NO_HARNESS="0"
  local STORY_TEST_MISSING="$test_missing"
  local PROD_TEST_SCRIPT="/tmp/fake-prod-test.sh"
  local REFRESH_PROOF="$proof"

  ( for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1
  RUN_RC=$?
  LAST_BD="$(cat "$BD_LOG" 2>/dev/null || true)"
  rm -rf "$T"
}

# H1: REFRESH_PROOF=verified → happy path, unchanged wording
run_block verified
echo "$LAST_BD" | grep -q "label add ga-test delivery:tested" && ok "H1 delivery:tested added" || nok "H1 tested-label" "$LAST_BD"
! echo "$LAST_BD" | grep -q "delivery:daemon-unverified" && ok "H1 NO delivery:daemon-unverified label" || nok "H1 daemon-unverified" "$LAST_BD"
echo "$LAST_BD" | grep -q "close ga-test -r.*tested in prod" && ok "H1 close_reason says tested in prod" || nok "H1 close-reason" "$LAST_BD"

# H2: REFRESH_PROOF=not_applicable → same happy-path wording (nothing false to claim)
run_block not_applicable
echo "$LAST_BD" | grep -q "label add ga-test delivery:tested" && ok "H2 delivery:tested added" || nok "H2 tested-label" "$LAST_BD"
! echo "$LAST_BD" | grep -q "delivery:daemon-unverified" && ok "H2 NO delivery:daemon-unverified label" || nok "H2 daemon-unverified" "$LAST_BD"

# H3 (THE BUG'S OWN SCENARIO): REFRESH_PROOF=not_verified, baseline-only test
# (STORY_TEST_MISSING=1) — exactly wa-3dfnw's shape: prod-test harness passed,
# daemon-refresh never confirmed the live process picked up the code.
run_block not_verified 1
echo "$LAST_BD" | grep -q "label add ga-test delivery:daemon-unverified" && ok "H3 delivery:daemon-unverified label IS added" || nok "H3 daemon-unverified" "$LAST_BD"
echo "$LAST_BD" | grep -qi "NOT VERIFIED" && ok "H3 close_reason says daemon liveness NOT verified" || nok "H3 not-verified-text" "$LAST_BD"
! echo "$LAST_BD" | grep -q "verified in prod" && ok "H3 close_reason does NOT claim 'verified in prod'" || nok "H3 false-verified-claim" "$LAST_BD"
# story:done is still set — a genuinely-untestable daemon claim halts nothing on
# its own (that's Step 5b's VERIFY_FAILED/NEEDS_GUARDED_RESTART job, already
# covered by story-delivery-step5b.test.sh); this step's job is honest labeling.
echo "$LAST_BD" | grep -q "label add ga-test story:done" && ok "H3 story:done still set (labeling honesty, not a new halt)" || nok "H3 story-done" "$LAST_BD"

# H4: the literal false claim can never resurface, in any scenario this file drives.
for p in verified not_applicable not_verified; do
  run_block "$p"
  ! echo "$LAST_BD" | grep -q "verified in prod" && ok "H4 [$p] 'verified in prod' never appears" || nok "H4 [$p]" "$LAST_BD"
done

echo ""
echo "story-delivery daemon-proof-honesty tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
