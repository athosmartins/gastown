#!/usr/bin/env bash
# gate-stale-sha-fix-attempt.selftest.sh — ga-l7mvtw
#
# Covers Aceite 2 of ga-l7mvtw: "dois markers para o mesmo branch, o velho em
# andamento e tip novo -> o velho nao conta tentativa; o novo e avaliado
# contra o tip novo."
#
# Two mechanisms together satisfy this:
#   (b) live_sibling_run_for_branch's new SHA_STALE output — a live sibling
#       reviewing a commit that is NOT the branch's current tip is superseded
#       regardless of age, so a NEW marker proceeds against the new tip
#       instead of yielding to it (Section 2 below).
#   (c) gate_sha_stale_action — the pure decision that gates whether the
#       finalize fix-attempt-bump block charges an attempt for a FAIL whose
#       reviewed sha no longer matches the branch's current tip (Section 1
#       below), plus drift guards (Section 3) proving gate_finalize_run()'s
#       fix-attempt block actually branches on it BEFORE the cap-check.
#
# Both gate_sha_stale_action and the SHA_STALE extension to
# live_sibling_run_for_branch are defined BEFORE the GATE_DISPATCHER_LIB_ONLY
# early-return, so both are directly callable via lib-only sourcing — no
# SELFTEST-EXTRACT sandbox needed for this file.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type gate_sha_stale_action        >/dev/null 2>&1 || { echo "FATAL: gate_sha_stale_action not defined by dispatcher"; exit 1; }
type live_sibling_run_for_branch  >/dev/null 2>&1 || { echo "FATAL: live_sibling_run_for_branch not defined by dispatcher"; exit 1; }
type classify_sibling_run         >/dev/null 2>&1 || { echo "FATAL: classify_sibling_run not defined by dispatcher"; exit 1; }

# Quiet logging from the sourced helpers during the test.
log()  { :; }
warn() { :; }
err()  { :; }

echo "── Section 1: gate_sha_stale_action (pure) ──"

eq "(1a) reviewed == current → current"       "$(gate_sha_stale_action "abc123" "abc123")" "current"
eq "(1b) reviewed != current → stale"         "$(gate_sha_stale_action "abc123" "def456")" "stale"
eq "(1c) reviewed empty → unknown"            "$(gate_sha_stale_action "" "def456")"       "unknown"
eq "(1d) current empty → unknown"             "$(gate_sha_stale_action "abc123" "")"       "unknown"
eq "(1e) both empty → unknown"                "$(gate_sha_stale_action "" "")"             "unknown"
eq "(1f) case-sensitive sha compare"          "$(gate_sha_stale_action "ABC123" "abc123")" "stale"

echo ""
echo "── Section 2: live_sibling_run_for_branch SHA_STALE extension (bd-mocked) ──"

GC_CITY="/tmp/l7mvtw-stale-test-city"
SIBLING_RUN_STALE_MINUTES=90
TS_5M_AGO=$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
TS_200M_AGO=$(date -u -v-200M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '200 minutes ago' +%Y-%m-%dT%H:%M:%SZ)

MOCK_RUNS='[]'
bd() {
  case " $* " in
    *" list "*) printf '%s\n' "$MOCK_RUNS" ;;
    *) : ;;
  esac
  return 0
}

# (2a) THE wa-54f62 shape: a young (5m) sibling reviewing an ABANDONED commit
# (sib_sha != current_sha) → SHA_STALE, not LIVE. This is the case that let
# ga-jjnnno wait 13 minutes behind ga-i6pcpc in the incident.
MOCK_RUNS=$(printf '[{"id":"ga-run-old","status":"open","description":"Autonomous gate run for crew/thies/wa-54f62.\\nrig: gascity\\nbranch_sha: 4e30a7cbc\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(2a) young sibling reviewing abandoned sha → SHA_STALE" \
  "$(live_sibling_run_for_branch 'crew/thies/wa-54f62' 'gascity' '3c40bc245')" "SHA_STALE ga-run-old"

# (2b) young sibling reviewing the SAME sha as the caller's current tip →
# unchanged baseline: LIVE (the SHA check must not fire on a match).
MOCK_RUNS=$(printf '[{"id":"ga-run-same","status":"open","description":"Autonomous gate run for crew/thies/wa-54f62.\\nrig: gascity\\nbranch_sha: 3c40bc245\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(2b) young sibling reviewing the current tip → LIVE (unchanged)" \
  "$(live_sibling_run_for_branch 'crew/thies/wa-54f62' 'gascity' '3c40bc245')" "LIVE ga-run-same"

# (2c) sibling bead predates this field (no branch_sha: line at all) → falls
# through to pure age-based classification, unaffected (backward compat).
MOCK_RUNS=$(printf '[{"id":"ga-run-nofield","status":"open","description":"Autonomous gate run for crew/thies/wa-54f62.\\nrig: gascity\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(2c) sibling with no branch_sha field → LIVE (age-only fallback)" \
  "$(live_sibling_run_for_branch 'crew/thies/wa-54f62' 'gascity' '3c40bc245')" "LIVE ga-run-nofield"

# (2d) caller does not know its own current sha (3rd arg empty/omitted) →
# comparison never runs, falls through to age-based classification —
# existing 2-arg callers (if any remained) are unaffected.
MOCK_RUNS=$(printf '[{"id":"ga-run-noargsha","status":"open","description":"Autonomous gate run for crew/thies/wa-54f62.\\nrig: gascity\\nbranch_sha: 4e30a7cbc\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(2d) caller sha unknown (2-arg call) → LIVE (age-only fallback)" \
  "$(live_sibling_run_for_branch 'crew/thies/wa-54f62' 'gascity')" "LIVE ga-run-noargsha"

# (2e) OLD sibling (200m) with a MATCHING sha → still classified STALE by age,
# not SHA_STALE — proves the pre-existing time-based path is untouched.
MOCK_RUNS=$(printf '[{"id":"ga-run-timeold","status":"open","description":"Autonomous gate run for crew/thies/wa-54f62.\\nrig: gascity\\nbranch_sha: 3c40bc245\\nstarted_at: %s"}]' "$TS_200M_AGO")
eq "(2e) old sibling, matching sha → STALE (age path unchanged)" \
  "$(live_sibling_run_for_branch 'crew/thies/wa-54f62' 'gascity' '3c40bc245')" "STALE ga-run-timeold"

echo ""
echo "── Section 3: drift guards (structural wiring) ──"

has "$DISPATCHER" 'live_sibling_run_for_branch "\$BRANCH" "\$RIG" "\$BRANCH_SHA"' \
  "both sibling-guard call sites pass \$BRANCH_SHA as the 3rd arg"
SITE_CALL_COUNT=$(grep -c 'live_sibling_run_for_branch "\$BRANCH" "\$RIG" "\$BRANCH_SHA"' "$DISPATCHER" || true)
eq "exactly 2 call sites pass the 3rd arg (Step 4b-1 + Step 5b)" "$SITE_CALL_COUNT" "2"

SHA_STALE_CASE_COUNT=$(grep -c '"SHA_STALE "\*)' "$DISPATCHER" || true)
eq "exactly 2 SHA_STALE case branches exist (one per call site)" "$SHA_STALE_CASE_COUNT" "2"

# The claim-time guard (ga-l7mvtw, Step 4b) must appear BEFORE Step 4b-1's
# sibling guard — otherwise a stale-sha marker could still reach the sibling
# check and spawn machinery before being caught.
CLAIM_GUARD_LINE=$(grep -n '# SELFTEST-EXTRACT stale-sha-claim-guard: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
SIBLING_GUARD_LINE=$(grep -n '# ── Step 4b-1 (ga-991au round 2): live-sibling-run guard, HOISTED before any' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$CLAIM_GUARD_LINE" ] && [ -n "$SIBLING_GUARD_LINE" ] && [ "$CLAIM_GUARD_LINE" -lt "$SIBLING_GUARD_LINE" ]; then
  ok "claim-time stale-sha guard (line $CLAIM_GUARD_LINE) precedes Step 4b-1 sibling guard (line $SIBLING_GUARD_LINE)"
else
  bad "claim-time stale-sha guard ordering wrong or not found (claim=$CLAIM_GUARD_LINE sibling=$SIBLING_GUARD_LINE)"
fi

# Inside gate_finalize_run()'s fix-attempt block: the GATE_SHA_STALE_ACTION
# computation, its "stale" branch, and the pre-existing cap-check must all
# exist in that order — the stale branch must be checked BEFORE the cap.
GFR_START=$(grep -n '^gate_finalize_run() {' "$DISPATCHER" | head -1 | cut -d: -f1)
GFR_COMPUTE_LINE=$(tail -n "+$GFR_START" "$DISPATCHER" | grep -n 'GATE_SHA_STALE_ACTION=\$(gate_sha_stale_action' | head -1 | cut -d: -f1)
GFR_STALE_BRANCH_LINE=$(tail -n "+$GFR_START" "$DISPATCHER" | grep -n 'if \[ "\$GATE_SHA_STALE_ACTION" = "stale" \]; then' | head -1 | cut -d: -f1)
GFR_CAP_BRANCH_LINE=$(tail -n "+$GFR_START" "$DISPATCHER" | grep -n 'elif \[ "\$PREV_ATTEMPT" -ge "\$GATE_FIX_CAP" \]; then' | head -1 | cut -d: -f1)

if [ -n "$GFR_COMPUTE_LINE" ] && [ -n "$GFR_STALE_BRANCH_LINE" ] && [ -n "$GFR_CAP_BRANCH_LINE" ] \
   && [ "$GFR_COMPUTE_LINE" -lt "$GFR_STALE_BRANCH_LINE" ] && [ "$GFR_STALE_BRANCH_LINE" -lt "$GFR_CAP_BRANCH_LINE" ]; then
  ok "GATE_SHA_STALE_ACTION computed, then checked, BEFORE the fix-attempt cap-check (relative lines $GFR_COMPUTE_LINE < $GFR_STALE_BRANCH_LINE < $GFR_CAP_BRANCH_LINE within gate_finalize_run)"
else
  bad "fix-attempt stale-check ordering wrong or not found (compute=$GFR_COMPUTE_LINE stale_if=$GFR_STALE_BRANCH_LINE cap_elif=$GFR_CAP_BRANCH_LINE)"
fi

# The stale branch must NOT bump gate:fix-attempt — i.e. no
# "gate:fix-attempt:" label-add text between the stale-branch line and the
# next branch (elif cap-check) in the function body.
if [ -n "$GFR_STALE_BRANCH_LINE" ] && [ -n "$GFR_CAP_BRANCH_LINE" ]; then
  # ga-l7mvtw selftest note: sed -n 'A,Bp' (not `tail | head`) — a tail
  # stream of thousands of lines piped into a small `head -n` closes early
  # and SIGPIPEs tail (rc=141), which set -o pipefail then propagates and
  # set -e aborts the whole script on. sed reads the bounded range directly.
  GFR_STALE_ABS=$((GFR_START + GFR_STALE_BRANCH_LINE - 1))
  GFR_CAP_ABS=$((GFR_START + GFR_CAP_BRANCH_LINE - 1))
  STALE_BODY=$(sed -n "${GFR_STALE_ABS},$((GFR_CAP_ABS - 1))p" "$DISPATCHER")
  if printf '%s' "$STALE_BODY" | grep 'gate:fix-attempt:' >/dev/null; then
    bad "stale branch unexpectedly writes a gate:fix-attempt: label — should be a no-op on the counter"
  else
    ok "stale branch never writes gate:fix-attempt: (counter genuinely untouched)"
  fi
fi

has "$DISPATCHER" 'git_rig fetch origin "\$BRANCH" --quiet' \
  "finalize stale-check does a FRESH scoped fetch before resolving the current tip (not a possibly-stale claim-time ref)"

echo ""
echo "── Section 4: syntax ──"
if bash -n "$DISPATCHER" 2>/tmp/l7mvtw-syntax-err.$$; then
  ok "dispatcher parses cleanly (bash -n)"
else
  bad "dispatcher FAILED bash -n: $(cat /tmp/l7mvtw-syntax-err.$$)"
fi
rm -f /tmp/l7mvtw-syntax-err.$$

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
