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
#   H5 (ga-y108i) REFRESH_PROOF=asset_served_per_request → same happy path as
#      H1/H2: a rig-declared no_restart_paths glob structurally proved the
#      change needs no restart (daemon-refresh.sh header point 8), so this
#      must be treated as confirmed, not as an unverified daemon — NO
#      delivery:daemon-unverified label, "tested in prod" wording unchanged.
#   H6 (ga-j3lh6p) REFRESH_PROOF=symbol_unreachable_locked → Step 5b released the
#      story because every still-stale daemon is notify_only_locked AND has no
#      call-graph path to a symbol the merge changed. A THIRD answer: not
#      "verified" (nothing was restarted) and not "not_verified" (it WAS checked).
#      Own label (delivery:daemon-stale-locked), NO delivery:daemon-unverified, and
#      wording that says a locked daemon is still on old code — never "may still
#      be dormant", never "verified in prod".

# No `pipefail` at file level (ga-uel7sb, on top of ga-j3lh6p's here-string
# fix below): removing it here closes any OTHER pipe site the here-string
# swap didn't touch, not just the grep -q ones. The block under test still
# runs WITH pipefail (see run_block), as in production.
set -u

# ga-j3lh6p (flake fix): every assertion below used to be `echo "$LAST_BD" | grep
# -q pat`. Under `set -o pipefail` that is a SIGPIPE race: macOS BUFSIZ is 1024,
# so echoing anything larger goes out in chunks, grep -q exits on the first match,
# the next chunk kills echo (141), and the pipeline reads as a FAILED match even
# though the text is there. Measured on an UNTOUCHED origin/main: 2 of 14 runs
# failed (a different `tested-label` / `story-done` assertion each time). A
# here-string has no writer process to kill, so it cannot race.

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

  ( set -o pipefail; for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1
  RUN_RC=$?
  LAST_BD="$(cat "$BD_LOG" 2>/dev/null || true)"
  rm -rf "$T"
}

# H1: REFRESH_PROOF=verified → happy path, unchanged wording
run_block verified
grep -q "label add ga-test delivery:tested" <<<"$LAST_BD" && ok "H1 delivery:tested added" || nok "H1 tested-label" "$LAST_BD"
! grep -q "delivery:daemon-unverified" <<<"$LAST_BD" && ok "H1 NO delivery:daemon-unverified label" || nok "H1 daemon-unverified" "$LAST_BD"
grep -q "close ga-test -r.*tested in prod" <<<"$LAST_BD" && ok "H1 close_reason says tested in prod" || nok "H1 close-reason" "$LAST_BD"

# H2: REFRESH_PROOF=not_applicable → same happy-path wording (nothing false to claim)
run_block not_applicable
grep -q "label add ga-test delivery:tested" <<<"$LAST_BD" && ok "H2 delivery:tested added" || nok "H2 tested-label" "$LAST_BD"
! grep -q "delivery:daemon-unverified" <<<"$LAST_BD" && ok "H2 NO delivery:daemon-unverified label" || nok "H2 daemon-unverified" "$LAST_BD"

# H3 (THE BUG'S OWN SCENARIO): REFRESH_PROOF=not_verified, baseline-only test
# (STORY_TEST_MISSING=1) — exactly wa-3dfnw's shape: prod-test harness passed,
# daemon-refresh never confirmed the live process picked up the code.
run_block not_verified 1
grep -q "label add ga-test delivery:daemon-unverified" <<<"$LAST_BD" && ok "H3 delivery:daemon-unverified label IS added" || nok "H3 daemon-unverified" "$LAST_BD"
grep -qi "NOT VERIFIED" <<<"$LAST_BD" && ok "H3 close_reason says daemon liveness NOT verified" || nok "H3 not-verified-text" "$LAST_BD"
! grep -q "verified in prod" <<<"$LAST_BD" && ok "H3 close_reason does NOT claim 'verified in prod'" || nok "H3 false-verified-claim" "$LAST_BD"
# story:done is still set — a genuinely-untestable daemon claim halts nothing on
# its own (that's Step 5b's VERIFY_FAILED/NEEDS_GUARDED_RESTART job, already
# covered by story-delivery-step5b.test.sh); this step's job is honest labeling.
grep -q "label add ga-test story:done" <<<"$LAST_BD" && ok "H3 story:done still set (labeling honesty, not a new halt)" || nok "H3 story-done" "$LAST_BD"

# H4: the literal false claim can never resurface, in any scenario this file drives.
for p in verified not_applicable not_verified asset_served_per_request symbol_unreachable_locked symbol_unreachable_nodrain; do
  run_block "$p"
  ! grep -q "verified in prod" <<<"$LAST_BD" && ok "H4 [$p] 'verified in prod' never appears" || nok "H4 [$p]" "$LAST_BD"
done

# H5 (ga-y108i): REFRESH_PROOF=asset_served_per_request → same happy path as
# H1/H2 — a no_restart_paths-proven change is confirmed, not unverified.
run_block asset_served_per_request
grep -q "label add ga-test delivery:tested" <<<"$LAST_BD" && ok "H5 delivery:tested added" || nok "H5 tested-label" "$LAST_BD"
! grep -q "delivery:daemon-unverified" <<<"$LAST_BD" && ok "H5 NO delivery:daemon-unverified label" || nok "H5 daemon-unverified" "$LAST_BD"
grep -q "close ga-test -r.*tested in prod" <<<"$LAST_BD" && ok "H5 close_reason says tested in prod" || nok "H5 close-reason" "$LAST_BD"

# H6 (ga-j3lh6p): REFRESH_PROOF=symbol_unreachable_locked — Step 5b released this
# story because every still-stale daemon is notify_only_locked AND has no
# call-graph path to a symbol the merge changed. That is a THIRD answer, neither
# "verified" (nothing was restarted, the daemon really is still stale) nor
# "not_verified" (we DID check, and the analysis says it is not dormant). Folding
# it into delivery:daemon-unverified would put "could not check" and "checked,
# proven not needed" in one label, and the terminal push would tell Athos
# "merged code may still be dormant" for a case the system judged safe. So it
# gets its own label and its own wording — and the wording must not overclaim:
# it is evidence, not proof, and says a locked daemon is still on old code.
run_block symbol_unreachable_locked
[[ "$LAST_BD" == *"label add ga-test delivery:tested"* ]] && ok "H6 delivery:tested added (the rig harness passed)" || nok "H6 tested-label" "$LAST_BD"
[[ "$LAST_BD" != *"delivery:daemon-unverified"* ]] && ok "H6 NO delivery:daemon-unverified (that label means 'could not check', which is not what happened)" || nok "H6 daemon-unverified wrongly added" "$LAST_BD"
[[ "$LAST_BD" == *"label add ga-test delivery:daemon-stale-locked"* ]] && ok "H6 delivery:daemon-stale-locked IS added (queryable: a locked daemon was left on old code, on evidence)" || nok "H6 stale-locked label" "$LAST_BD"
[[ "$LAST_BD" == *"close ga-test -r"*"tested in prod"* ]] && ok "H6 close_reason says tested in prod" || nok "H6 close-reason" "$LAST_BD"
[[ "$LAST_BD" == *"notify_only_locked"* ]] && ok "H6 close_reason names the locked daemon caveat (does not overclaim)" || nok "H6 locked caveat missing from the close reason" "$LAST_BD"
[[ "$LAST_BD" != *"NOT VERIFIED"* && "$LAST_BD" != *"may still be dormant"* ]] && ok "H6 close_reason does NOT say liveness was unverified / may be dormant" || nok "H6 alarming wording for a proven-cosmetic case" "$LAST_BD"
[[ "$LAST_BD" == *"label add ga-test story:done"* ]] && ok "H6 story:done set" || nok "H6 story-done" "$LAST_BD"

# H7 (ga-xrn8ni, extends ga-j3lh6p): REFRESH_PROOF=symbol_unreachable_nodrain —
# Step 5b released this story because every still-stale daemon is SENSITIVE
# with no $DRAIN_CMD_<label> configured (never notify_only_locked) AND has no
# call-graph path to a symbol the merge changed. Same THIRD-answer shape as H6,
# with its OWN label (delivery:daemon-stale-nodrain, not -stale-locked — a
# reader must be able to tell "a human locked this" from "nobody wired a drain
# command yet" apart) and wording that never claims notify_only_locked for a
# daemon that isn't in restart_policy.yaml at all.
run_block symbol_unreachable_nodrain
[[ "$LAST_BD" == *"label add ga-test delivery:tested"* ]] && ok "H7 delivery:tested added (the rig harness passed)" || nok "H7 tested-label" "$LAST_BD"
[[ "$LAST_BD" != *"delivery:daemon-unverified"* ]] && ok "H7 NO delivery:daemon-unverified (that label means 'could not check', which is not what happened)" || nok "H7 daemon-unverified wrongly added" "$LAST_BD"
[[ "$LAST_BD" == *"label add ga-test delivery:daemon-stale-nodrain"* ]] && ok "H7 delivery:daemon-stale-nodrain IS added (queryable, and distinct from -stale-locked)" || nok "H7 stale-nodrain label" "$LAST_BD"
[[ "$LAST_BD" != *"delivery:daemon-stale-locked"* ]] && ok "H7 does NOT also add delivery:daemon-stale-locked (never claim a policy lock that isn't there)" || nok "H7 wrongly added the locked label too" "$LAST_BD"
[[ "$LAST_BD" == *"close ga-test -r"*"tested in prod"* ]] && ok "H7 close_reason says tested in prod" || nok "H7 close-reason" "$LAST_BD"
[[ "$LAST_BD" == *"drain"* ]] && ok "H7 close_reason names the no-drain-configured caveat" || nok "H7 no-drain caveat missing from the close reason" "$LAST_BD"
[[ "$LAST_BD" != *"notify_only_locked"* ]] && ok "H7 close_reason does NOT claim notify_only_locked (that file doesn't even list this daemon)" || nok "H7 wrongly claims notify_only_locked" "$LAST_BD"
[[ "$LAST_BD" != *"NOT VERIFIED"* && "$LAST_BD" != *"may still be dormant"* ]] && ok "H7 close_reason does NOT say liveness was unverified / may be dormant" || nok "H7 alarming wording for a proven-cosmetic case" "$LAST_BD"
[[ "$LAST_BD" == *"label add ga-test story:done"* ]] && ok "H7 story:done set" || nok "H7 story-done" "$LAST_BD"

echo ""
echo "story-delivery daemon-proof-honesty tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
