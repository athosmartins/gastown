#!/usr/bin/env bash
# pilot-dispatcher.selftest.sh — smoke tests for pilot-dispatcher.sh
#
# Tests use DRY_RUN=1 + PILOT_CITY_OVERRIDE into a temp fixture dir.
# bd commands fail gracefully (|| echo "[]") when the fixture has no Dolt DB,
# so the dispatcher reaches "No dispatchable candidates" and exits 0.
# Structural tests grep the script for design-invariant properties.
#
# Function body extraction uses grep -A <N> on the function signature line to
# avoid fragile awk range patterns that break when comments or brace-terminated
# constructs are renamed or added inside the function body.
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
trap 'rm -rf "$TMP"' EXIT
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
trap - EXIT

# ── Test 2: SELF_BEAD_ID not a hardcoded bead literal ─────────────────────────
grep -qE '^SELF_BEAD_ID="[a-z]+-[0-9a-z]+"' "$PILOT" \
  && _fail "SELF_BEAD_ID: hardcoded bead ID literal detected" \
  || _pass "SELF_BEAD_ID: not a hardcoded bead ID literal"

# ── Test 3: SELF_BEAD_ID resolved via pilot:self label ────────────────────────
grep -q 'pilot:self' "$PILOT" \
  && _pass "SELF_BEAD_ID: pilot:self label query present" \
  || _fail "SELF_BEAD_ID: no pilot:self reference found"

# ── Test 4: TTL recovery has no story:approved filter ─────────────────────────
# Use grep -A to avoid awk anchor fragility on comment text / STALE_COUNT name.
if grep -A 30 'Step 0.*TTL recovery' "$PILOT" | grep -q '"story:approved"'; then
  _fail "TTL recovery: story:approved filter still present (Tier 1 claims never recovered)"
else
  _pass "TTL recovery: no story:approved filter"
fi

# ── Test 5: COMMON_EXCLUDES array defined ─────────────────────────────────────
grep -q 'COMMON_EXCLUDES=(' "$PILOT" \
  && _pass "COMMON_EXCLUDES: array defined" \
  || _fail "COMMON_EXCLUDES: array not defined"

# ── Test 6: story:in-flight added before pilot:dispatching removed ─────────────
# Extract _transition_bead body with grep -A 50 (avoids awk /^}/ early-termination
# on any brace-terminated construct that might be added inside the function).
_fn_body=$(grep -A 50 '^_transition_bead()' "$PILOT" | head -50 || true)
_inflight=$(printf '%s\n' "$_fn_body" | grep -n 'label add.*story:in-flight' | head -1 | cut -d: -f1 || echo "")
_rm_dispatch=$(printf '%s\n' "$_fn_body" | grep -n 'label remove.*pilot:dispatching' | head -1 | cut -d: -f1 || echo "")
if [ -n "$_inflight" ] && [ -n "$_rm_dispatch" ] && [ "$_inflight" -lt "$_rm_dispatch" ]; then
  _pass "transition_bead: story:in-flight set before pilot:dispatching removed"
else
  _fail "transition_bead: wrong order or missing labels (inflight=$_inflight rm_dispatch=$_rm_dispatch)"
fi

# ── Test 7: story:in-flight failure leaves pilot:dispatching for TTL recovery ──
# _transition_bead must NOT use || true on the story:in-flight add.
if grep -A 50 '^_transition_bead()' "$PILOT" | head -50 \
    | grep 'label add.*story:in-flight' | grep -q '|| true'; then
  _fail "transition_bead: story:in-flight add is || true (silent race condition)"
else
  _pass "transition_bead: story:in-flight add is NOT silently guarded"
fi

# ── Test 8: Task prompt uses BEAD_DB not GC_CITY in bd -C show ────────────────
# Extract _build_task_prompt body with grep -A 100 to cover the full single-heredoc body.
if grep -A 100 '^_build_task_prompt()' "$PILOT" | head -100 \
    | grep 'bd -C.*show.*STORY_ID' | grep -q 'GC_CITY'; then
  _fail "Task prompt: step-1 bd show uses GC_CITY instead of BEAD_DB for rig-sourced beads"
else
  _pass "Task prompt: step-1 bd show uses BEAD_DB"
fi

# ── Test 9: All dispatch sub-functions defined ────────────────────────────────
for _fn in _claim_bead _build_task_prompt _do_sling _transition_bead _notify_dispatch _ttl_recover_db; do
  grep -q "^${_fn}()" "$PILOT" \
    && _pass "sub-function defined: ${_fn}" \
    || _fail "sub-function MISSING: ${_fn}"
done

# ── Test 10: DRY_RUN notify is log-only (no real notify call) ─────────────────
_notify_body=$(grep -A 30 '^_notify_dispatch()' "$PILOT" | head -30)
if printf '%s\n' "$_notify_body" | grep -qE 'if.*DRY_RUN.*=.*1'; then
  if printf '%s\n' "$_notify_body" | sed -n '/if.*DRY_RUN/,/fi/p' | grep -qE '^\s*notify\b'; then
    _fail "_notify_dispatch: DRY_RUN branch still calls notify (real HTTP request)"
  else
    _pass "_notify_dispatch: DRY_RUN branch does not call notify"
  fi
else
  _fail "_notify_dispatch: no DRY_RUN guard found"
fi

# ── Test 11: _transition_bead failure captured (no unconditional in-flight log) ─
# Extract dispatch_one body with grep -A 200 to avoid anchor fragility on comment text.
if grep -A 200 '^dispatch_one()' "$PILOT" | head -200 | grep -q '_transition_ok'; then
  _pass "dispatch_one: _transition_bead return captured (no false in-flight log)"
else
  _fail "dispatch_one: _transition_bead result not captured (_transition_ok variable absent)"
fi

# ── Test 12: Untrusted fields sanitized before heredoc ────────────────────────
if grep -q 'sed.*s.*TASK.*\[TASK\]' "$PILOT"; then
  _pass "Heredoc delimiter sanitization present (TASK/FIXSEC lines replaced)"
else
  _fail "Heredoc delimiter sanitization MISSING — untrusted fields may truncate prompt"
fi

# ── Test 13: BEAD_ID_STALE guards against empty/null ─────────────────────────
# Use grep -A 5 on the assignment to avoid range-anchor fragility on UPDATED_AT name.
if grep -A 5 'BEAD_ID_STALE=' "$PILOT" | grep -q 'continue'; then
  _pass "BEAD_ID_STALE: empty guard with continue present"
else
  _fail "BEAD_ID_STALE: no guard against empty/null id from jq"
fi

# ── Test 14: TTL recovery scans rig DBs (not just HQ) ────────────────────────
# _ttl_recover_db must be called in a loop over rig paths (not only for GC_CITY).
if grep -A 30 'Step 0.*TTL recovery' "$PILOT" | grep -q '_ttl_rig'; then
  _pass "TTL recovery: rig DB scan loop present"
else
  _fail "TTL recovery: no rig DB scan — rig-sourced pilot:dispatching claims never recovered"
fi

# ── Test 15: rig_to_builder: whatsapp_automation mapping present ──────────────
grep -A 10 '^rig_to_builder()' "$PILOT" | grep -q "whatsapp_automation" \
  && _pass "rig_to_builder: whatsapp_automation mapping present" \
  || _fail "rig_to_builder: whatsapp_automation mapping missing"

# ── Test 16: rig_to_builder: default gastown.dog present ─────────────────────
grep -A 10 '^rig_to_builder()' "$PILOT" | grep -q "gastown.dog" \
  && _pass "rig_to_builder: default gastown.dog present" \
  || _fail "rig_to_builder: default gastown.dog missing"

# ── Test 17: classify_lane: lane:big label check present ─────────────────────
grep -A 20 '^classify_lane()' "$PILOT" | grep -q "lane:big" \
  && _pass "classify_lane: lane:big check present" \
  || _fail "classify_lane: lane:big check missing"

# ── Test 18: classify_lane: BIG_CRITERIA_THRESHOLD used ──────────────────────
grep -A 20 '^classify_lane()' "$PILOT" | grep -q "BIG_CRITERIA_THRESHOLD" \
  && _pass "classify_lane: BIG_CRITERIA_THRESHOLD used" \
  || _fail "classify_lane: BIG_CRITERIA_THRESHOLD missing"

# ── ga-mfeip tests: WA ctx:ready dispatch + 6 quality gates ──────────────────
#
# Tests 19-32 verify the ga-mfeip WA ctx:ready dispatch and all 6 quality gates.
# Gate filter function tests use _wa_ctx_ready_passes_gates directly by sourcing
# a minimal stub of the pilot. Structural tests grep the pilot script.

# Source a minimal environment to call _wa_ctx_ready_passes_gates:
_GATE_TMP=$(mktemp -d)
trap 'rm -rf "$_GATE_TMP"' EXIT
mkdir -p "$_GATE_TMP/.gc/logs"
# Extract and eval just the function + minimal deps (log/warn no-op stubs)
eval "$(grep -A 140 '^_wa_ctx_ready_passes_gates()' "$PILOT" | head -140)" 2>/dev/null || true
eval 'log() { true; }; warn() { true; }' 2>/dev/null || true
WA_RIG_PATH="$_GATE_TMP"  # dummy — not used by the gate function

# Helper: build a minimal bead JSON for gate tests
_mk_bead() {
  # _mk_bead <id> <status> <labels_csv> <ac> <body> <blocked_by_count>
  local id="$1" status="$2" labels="$3" ac="$4" body="$5" blocked="${6:-0}"
  local labels_json
  labels_json=$(printf '%s' "$labels" | tr ',' '\n' \
    | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo "[]")
  jq -c -n \
    --arg id "$id" --arg status "$status" --arg ac "$ac" \
    --arg body "$body" --argjson labels "$labels_json" \
    --argjson blocked_by_count "$blocked" \
    '{id: $id, status: $status, labels: $labels, acceptance_criteria: $ac,
      description: $body, notes: "", blocked_by_count: $blocked_by_count,
      assignee: null, priority: 1, created_at: "2026-01-01T00:00:00Z"}' 2>/dev/null
}

# ── Test 19: Gate 1 — blocked status is skipped ───────────────────────────────
_bead=$(_mk_bead "wa-test1" "blocked" "ctx:ready,exec:auto" "Do X" "Body" 0)
_wa_ctx_ready_passes_gates "$_bead" "" 2>/dev/null \
  && _fail "Gate1: blocked bead should be SKIPPED (returned 0 = passes)" \
  || _pass "Gate1: blocked bead correctly SKIPPED"

# ── Test 20: Gate 1 — needs-human label is skipped ───────────────────────────
_bead=$(_mk_bead "wa-test2" "open" "ctx:ready,exec:auto,needs-human" "Do X" "Body" 0)
_wa_ctx_ready_passes_gates "$_bead" "" 2>/dev/null \
  && _fail "Gate1: needs-human bead should be SKIPPED" \
  || _pass "Gate1: needs-human bead correctly SKIPPED"

# ── Test 21: Gate 2 — empty acceptance criteria is skipped ───────────────────
_bead=$(_mk_bead "wa-test3" "open" "ctx:ready,exec:auto" "" "Body" 0)
_wa_ctx_ready_passes_gates "$_bead" "" 2>/dev/null \
  && _fail "Gate2: empty-AC bead should be SKIPPED" \
  || _pass "Gate2: empty-AC bead correctly SKIPPED"

# ── Test 22: Gate 3 — cost-risk body keyword is skipped ──────────────────────
_bead=$(_mk_bead "wa-test4" "open" "ctx:ready,exec:auto" "Do X" "bloqueado em decisão de custo do Athos" 0)
_wa_ctx_ready_passes_gates "$_bead" "" 2>/dev/null \
  && _fail "Gate3: cost-risk body bead should be SKIPPED" \
  || _pass "Gate3: cost-risk body bead correctly SKIPPED"

# ── Test 23: Gate 3 — ban-risk body keyword is skipped ───────────────────────
_bead=$(_mk_bead "wa-test5" "open" "ctx:ready,exec:auto" "Do X" "never logout primary, never send, abort on anything unexpected" 0)
_wa_ctx_ready_passes_gates "$_bead" "" 2>/dev/null \
  && _fail "Gate3: ban-risk body bead should be SKIPPED" \
  || _pass "Gate3: ban-risk body bead correctly SKIPPED"

# ── Test 24: Gate 4 — unmet dep (blocked_by_count>0) is skipped ──────────────
_bead=$(_mk_bead "wa-test6" "open" "ctx:ready,exec:auto" "Do X" "Body" 1)
_wa_ctx_ready_passes_gates "$_bead" "" 2>/dev/null \
  && _fail "Gate4: unmet-dep bead should be SKIPPED" \
  || _pass "Gate4: unmet-dep bead correctly SKIPPED"

# ── Test 25: Gate 5 — exec:manual is skipped ─────────────────────────────────
_bead=$(_mk_bead "wa-test7" "open" "ctx:ready,exec:manual" "Do X" "Body" 0)
_wa_ctx_ready_passes_gates "$_bead" "" 2>/dev/null \
  && _fail "Gate5: exec:manual bead should be SKIPPED" \
  || _pass "Gate5: exec:manual bead correctly SKIPPED"

# ── Test 26: Gate 5 — no exec:auto label is skipped ─────────────────────────
_bead=$(_mk_bead "wa-test8" "open" "ctx:ready" "Do X" "Body" 0)
_wa_ctx_ready_passes_gates "$_bead" "" 2>/dev/null \
  && _fail "Gate5: no exec:auto bead should be SKIPPED" \
  || _pass "Gate5: no exec:auto bead correctly SKIPPED"

# ── Test 27: Gate 6 — already-assigned bead is skipped ───────────────────────
_bead=$(jq -c '. + {assignee: "thies-wa"}' \
  <<< "$(_mk_bead "wa-test9" "open" "ctx:ready,exec:auto" "Do X" "Body" 0)" 2>/dev/null)
_wa_ctx_ready_passes_gates "$_bead" "" 2>/dev/null \
  && _fail "Gate6: assigned bead should be SKIPPED" \
  || _pass "Gate6: assigned bead correctly SKIPPED"

# ── Test 28: Gate 6 — within-sweep dedup: same bead ID dispatched twice ───────
_bead=$(_mk_bead "wa-test10" "open" "ctx:ready,exec:auto" "Do X" "Body" 0)
_wa_ctx_ready_passes_gates "$_bead" "wa-test10" 2>/dev/null \
  && _fail "Gate6: sweep-dedup bead should be SKIPPED" \
  || _pass "Gate6: sweep-dedup bead correctly SKIPPED"

# ── Test 29: Positive — clean exec:auto bead passes all gates ─────────────────
_bead=$(_mk_bead "wa-testP" "open" "ctx:ready,exec:auto" "Ship feature X" "Normal description" 0)
_wa_ctx_ready_passes_gates "$_bead" "" 2>/dev/null \
  && _pass "Positive: clean exec:auto bead passes all gates" \
  || _fail "Positive: clean exec:auto bead was SKIPPED (should PASS)"

# ── Test 30: WA crew pool excludes digo-wa and oracle-wa ─────────────────────
if grep -q 'WA_CTX_CREWS=' "$PILOT"; then
  _crew_line=$(grep 'WA_CTX_CREWS=' "$PILOT" | head -1)
  if printf '%s' "$_crew_line" | grep -q 'digo-wa'; then
    _fail "WA_CTX_CREWS: digo-wa (suspended) is in the pool"
  else
    _pass "WA_CTX_CREWS: digo-wa not in pool"
  fi
  if printf '%s' "$_crew_line" | grep -q 'oracle-wa'; then
    _fail "WA_CTX_CREWS: oracle-wa (human-operated) is in the pool"
  else
    _pass "WA_CTX_CREWS: oracle-wa not in pool"
  fi
else
  _fail "WA_CTX_CREWS: array not defined in pilot script"
  _fail "WA_CTX_CREWS: (second check skipped)"
fi

# ── Test 31: HQ-lanes-full does NOT exit early — WA ctx:ready still runs ─────
# The "Both HQ lanes full … Pilot backing off" block must NOT contain "exit 0".
if grep -A 3 'Both HQ lanes full' "$PILOT" | grep -q 'exit 0'; then
  _fail "HQ-lanes-full: still contains 'exit 0' — WA ctx:ready blocked when HQ full"
else
  _pass "HQ-lanes-full: no exit 0 — WA ctx:ready runs even when HQ lanes full"
fi

# ── Test 32: WA dispatch functions defined ────────────────────────────────────
for _fn in _wa_ctx_ready_passes_gates _wa_crew_capacity _dispatch_wa_ctx_ready; do
  grep -q "^${_fn}()" "$PILOT" \
    && _pass "WA sub-function defined: ${_fn}" \
    || _fail "WA sub-function MISSING: ${_fn}"
done

rm -rf "$_GATE_TMP"
trap - EXIT

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
printf "── Results: %d/%d passed ──\n" "$PASS" "$TOTAL"
[ "$FAIL" -eq 0 ]
