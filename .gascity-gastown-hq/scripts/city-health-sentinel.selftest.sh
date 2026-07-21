#!/usr/bin/env bash
# city-health-sentinel.selftest.sh — hermetic tests for city-health-sentinel.sh.
#
# Sources the script as a LIBRARY (CITY_HEALTH_SENTINEL_LIB=1) so main() never
# auto-runs, then overrides the COLLECT / HAIKU / EXECUTE functions by name
# (bash lets a later `funcname() { ... }` definition replace an earlier one —
# same technique as dolt-disk-floor-guard.selftest.sh and
# gate-throughput-stall-watchdog.sh's GTSW_TEST_KICKSTARTS/GTSW_TEST_MAILED
# redirection). Hermetic: NEVER calls the real `claude` CLI (no network, no
# cost), `launchctl kickstart`, `gc session nudge`, or `gc dolt health` — every
# side-effecting call is replaced with a recording stub. Nothing on this machine
# is restarted, nudged, or queried.
#
# IMPORTANT (lesson carried over from dolt-disk-floor-guard.selftest.sh): several
# of main()'s calls into the mocked functions go through `$(...)` command
# substitution, which forks a SUBSHELL — a plain shell-variable counter mutated
# inside such a mock would silently discard itself on subshell exit. Where a
# mock needs to record that it was called (specifically _invoke_haiku, which
# main() calls as `decision_json="$(_invoke_haiku ...)"`), this file uses a
# FILE-BACKED counter, never an in-memory variable, so the recording survives
# the subshell. The EXECUTE-side mocks (_do_kickstart/_do_nudge) are called
# directly by _execute_action (no command substitution), so plain in-memory
# arrays are safe for those and are used for simplicity.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/city-health-sentinel.sh"

TMP_ROOT="$(mktemp -d)"
export CITY_HEALTH_SENTINEL_LIB=1
export CHS_LOG="$TMP_ROOT/sentinel.log"
export CHS_STATE_DIR="$TMP_ROOT/state"
mkdir -p "$CHS_STATE_DIR"
# shellcheck disable=SC1090
. "$SCRIPT"

# Default stub for the reviewer-active guard's collector (ga-r5sn8 fix 2) so
# every test below — including the ones that predate this fix and know
# nothing about it — stays hermetic (never shells out to the real
# gc-session-list-cached.sh) and keeps its original expected behavior: "no
# gate-reviewer session at all" -> not active. Scenarios that specifically
# exercise the guard override this again, locally, right before calling main.
_collect_session_list_json() { echo '{"sessions":[]}'; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== city-health-sentinel.selftest.sh ==="

# ─────────────────────────────────────────────────────────────────────────────
# Pure decision functions
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- pure functions: _is_int / _lt / _gt / _ge --"
_is_int "5" && ok "_is_int(5) true" || bad "_is_int(5) should be true"
_is_int "" && bad "_is_int('') should be false" || ok "_is_int('') false (empty never reads as a number)"
_is_int "-3" && bad "_is_int(-3) should be false (no negatives)" || ok "_is_int(-3) false"
_lt "5" "8" && ok "_lt(5,8) true" || bad "_lt(5,8) should be true"
_lt "" "8" && bad "_lt('',8) should be false" || ok "_lt('',8) false (fail-closed on unknown)"
_gt "10" "8" && ok "_gt(10,8) true" || bad "_gt(10,8) should be true"

echo ""
echo "-- pure functions: _fastpath_ok (gate<8 && pilot<20 && dolt healthy && dolt_ms<3000 && disk>5) --"
_fastpath_ok "3" "5" "true" "40" "100" && ok "all-green -> fastpath ok" || bad "all-green should be fastpath ok"
_fastpath_ok "9" "5" "true" "40" "100" && bad "gate_gap=9 (>=8) should fail fastpath" || ok "gate_gap=9 -> fastpath fails"
_fastpath_ok "3" "25" "true" "40" "100" && bad "pilot_gap=25 (>=20) should fail fastpath" || ok "pilot_gap=25 -> fastpath fails"
_fastpath_ok "3" "5" "false" "40" "100" && bad "dolt down should fail fastpath" || ok "dolt down -> fastpath fails"
_fastpath_ok "3" "5" "true" "3200" "100" && bad "dolt_ms=3200 (>=3000) should fail fastpath" || ok "dolt_ms=3200 -> fastpath fails"
_fastpath_ok "3" "5" "true" "40" "4" && bad "disk=4 (<=5) should fail fastpath" || ok "disk=4 -> fastpath fails"
_fastpath_ok "" "5" "true" "40" "100" && bad "unknown gate_gap should fail fastpath" || ok "unknown gate_gap -> fastpath fails (never fast-paths on missing data)"
_fastpath_ok "3" "5" "true" "-1" "100" && bad "negative dolt_ms (unknown sentinel) should fail fastpath" || ok "dolt_ms=-1 -> fastpath fails (never reads the unknown sentinel as fast)"

echo ""
echo "-- pure functions: _deterministic_fallback_action (used ONLY when Haiku itself fails) --"
[ "$(_deterministic_fallback_action 20 true)" = "kickstart_gate" ] && ok "gate_gap=20 dolt=true -> kickstart_gate" || bad "expected kickstart_gate"
[ "$(_deterministic_fallback_action 5 true)" = "none" ] && ok "gate_gap=5 dolt=true -> none" || bad "expected none"
[ "$(_deterministic_fallback_action 20 false)" = "nudge_mayor" ] && ok "gate_gap=20 dolt=false -> nudge_mayor (dolt priority wins over gate)" || bad "expected nudge_mayor"
[ "$(_deterministic_fallback_action "" true)" = "none" ] && ok "unknown gate_gap dolt=true -> none (never acts on missing data)" || bad "expected none"

echo ""
echo "-- pure functions: _compute_topic (deterministic nudge rate-limit bucket) --"
[ "$(_compute_topic 5 5 false 100)" = "dolt" ] && ok "topic: dolt down -> dolt" || bad "expected dolt"
[ "$(_compute_topic 5 5 true 2)" = "disk" ] && ok "topic: disk low -> disk" || bad "expected disk"
[ "$(_compute_topic 15 5 true 100)" = "gate" ] && ok "topic: gate elevated -> gate" || bad "expected gate"
[ "$(_compute_topic 3 25 true 100)" = "pilot" ] && ok "topic: pilot elevated -> pilot" || bad "expected pilot"
[ "$(_compute_topic 3 5 true 100)" = "general" ] && ok "topic: nothing elevated -> general" || bad "expected general"

echo ""
echo "-- pure functions: _valid_action (the ONLY allowlist enforcement point) --"
for a in kickstart_gate kickstart_pilot nudge_mayor none; do
  _valid_action "$a" && ok "_valid_action($a) accepted" || bad "_valid_action($a) should be accepted"
done
_valid_action "restart_dolt" && bad "_valid_action(restart_dolt) should be REJECTED" || ok "_valid_action(restart_dolt) rejected"
_valid_action "" && bad "_valid_action('') should be REJECTED" || ok "_valid_action('') rejected"

echo ""
echo "-- pure functions: _cooldown_elapsed --"
NOW_T=1000000
echo $((NOW_T - 100)) > "$TMP_ROOT/cd1"
_cooldown_elapsed "$TMP_ROOT/cd1" 180 "$NOW_T" && bad "100s < 180s cooldown should NOT be elapsed" || ok "cooldown: 100s ago, 180s window -> still cooling"
echo $((NOW_T - 200)) > "$TMP_ROOT/cd2"
_cooldown_elapsed "$TMP_ROOT/cd2" 180 "$NOW_T" && ok "cooldown: 200s ago, 180s window -> elapsed" || bad "200s >= 180s should be elapsed"
_cooldown_elapsed "$TMP_ROOT/cd-missing" 180 "$NOW_T" && ok "cooldown: no prior state file -> elapsed (fail-open)" || bad "missing state file should fail-open to elapsed"

echo ""
echo "-- pure functions: _mark_now honors DRY_RUN (ga-r5sn8 fix 3 — dry-run must NOT arm the real cooldown) --"
# A dry-run performs no real action, so it must not write the cooldown marker; else
# a manual diagnostic dry-run silently suppresses a genuine launchd remediation.
DRY_RUN_SAVE="$DRY_RUN"
MARKF="$TMP_ROOT/mark-dryrun"
rm -f "$MARKF"
DRY_RUN=1; _mark_now "$MARKF" "$NOW_T"
[ ! -f "$MARKF" ] && ok "DRY_RUN=1: _mark_now writes NO cooldown marker (a diagnostic dry-run never suppresses a real remediation)" || bad "DRY_RUN=1 must not arm the real cooldown, but the marker was written"
DRY_RUN=0; _mark_now "$MARKF" "$NOW_T"
[ -f "$MARKF" ] && ok "DRY_RUN=0: _mark_now writes the cooldown marker (a real action arms the rate-limit)" || bad "DRY_RUN=0 should write the marker"
rm -f "$MARKF"; DRY_RUN="$DRY_RUN_SAVE"

echo ""
echo "-- pure functions: _reviewer_active_id (ga-r5sn8 fix 2 — reviewer-active guard) --"
RID="$(_reviewer_active_id '{"sessions":[{"id":"rev-1","template":"gate-reviewer","state":"creating"}]}')"
[ $? -eq 0 ] && [ "$RID" = "rev-1" ] && ok "gate-reviewer state=creating -> active, id=rev-1" || bad "expected active with id=rev-1, got rc=$? id=$RID"
RID="$(_reviewer_active_id '{"sessions":[{"id":"rev-2","template":"gate-reviewer","state":"active"}]}')"
[ $? -eq 0 ] && [ "$RID" = "rev-2" ] && ok "gate-reviewer state=active -> active, id=rev-2" || bad "expected active with id=rev-2"
RID="$(_reviewer_active_id '{"sessions":[{"id":"rev-3","template":"refino-gate-reviewer","state":"active"}]}')"
[ $? -eq 0 ] && [ "$RID" = "rev-3" ] && ok "refino-gate-reviewer template also counts (contains gate-reviewer)" || bad "expected refino-gate-reviewer to match"
RID="$(_reviewer_active_id '{"sessions":[{"id":"rev-sp","template":"gate-reviewer","state":"start-pending","closed":false}]}')"
[ $? -eq 0 ] && [ "$RID" = "rev-sp" ] && ok "gate-reviewer state=start-pending -> active (live-verified 2026-07-20 boot state; blocklist catches it, an allowlist of creating/active/booting alone would not)" || bad "expected start-pending to count as active (blocklist design)"
_reviewer_active_id '{"sessions":[{"id":"rev-4","template":"gate-reviewer","state":"asleep"}]}' >/dev/null
[ $? -ne 0 ] && ok "gate-reviewer state=asleep -> NOT active (known at-rest-between-turns state)" || bad "asleep should not count as active"
_reviewer_active_id '{"sessions":[{"id":"rev-5","template":"gate-reviewer","state":"drained"}]}' >/dev/null
[ $? -ne 0 ] && ok "gate-reviewer state=drained -> NOT active" || bad "drained should not count as active"
_reviewer_active_id '{"sessions":[{"id":"rev-6","template":"gate-reviewer","state":"active","closed":true}]}' >/dev/null
[ $? -ne 0 ] && ok "closed=true overrides a stale state=active -> NOT active" || bad "closed=true should never count as active regardless of the state string"
RID="$(_reviewer_active_id '{"sessions":[{"id":"rev-7","template":"gate-reviewer","state":"some-future-state-nobody-documented-yet"}]}')"
[ $? -eq 0 ] && [ "$RID" = "rev-7" ] && ok "unrecognized/future state name -> counts as active (blocklist fails closed on anything not explicitly known-safe)" || bad "expected an unknown state name to fail closed as active"
_reviewer_active_id '{"sessions":[{"id":"ccr-1","template":"context-check-reviewer","state":"active"}]}' >/dev/null
[ $? -ne 0 ] && ok "context-check-reviewer excluded even though it contains \"reviewer\"" || bad "context-check-reviewer must never count as a gate-reviewer"
_reviewer_active_id '{"sessions":[]}' >/dev/null
[ $? -ne 0 ] && ok "empty sessions list -> NOT active" || bad "empty sessions list should not count as active"
RID="$(_reviewer_active_id '')"
[ $? -eq 0 ] && [ -z "$RID" ] && ok "empty/unreadable JSON fails CLOSED (treated as active, id unknown) — never license to kickstart blind" || bad "expected fail-closed (rc=0, empty id) on empty input"
RID="$(_reviewer_active_id 'not json at all')"
[ $? -eq 0 ] && ok "unparseable JSON fails CLOSED (treated as active) rather than silently reading as inactive" || bad "expected fail-closed on unparseable JSON"

echo ""
echo "-- pure functions: _build_state_json null-encoding --"
J="$(_build_state_json "" "5" "false" "-1" "unknown" "" "0")"
echo "$J" | jq -e '.gate_sweep_gap_min == null' >/dev/null 2>&1 && ok "unknown gate_gap encodes as JSON null (not 0)" || bad "unknown gate_gap should encode as null"
echo "$J" | jq -e '.disk_gb == null' >/dev/null 2>&1 && ok "unknown disk_gb encodes as JSON null" || bad "unknown disk_gb should encode as null"
echo "$J" | jq -e '.dolt_responds == false' >/dev/null 2>&1 && ok "dolt_responds encodes as JSON boolean false" || bad "dolt_responds should be JSON false"
# ga-r5sn8 (error-vs-empty): an INCONCLUSIVE probe must reach Haiku as null, never
# collapsed into false — false is a CONFIRMED outage, null is "could not confirm".
J_UNK="$(_build_state_json "" "5" "unknown" "-1" "unknown" "" "0")"
echo "$J_UNK" | jq -e '.dolt_responds == null' >/dev/null 2>&1 && ok "dolt_responds=unknown encodes as JSON null (inconclusive != confirmed false)" || bad "dolt_responds=unknown should encode as JSON null, got: $(echo "$J_UNK" | jq -c .dolt_responds 2>/dev/null)"
J2="$(_build_state_json "3" "5" "true" "42" "healthy" "100" "2")"
echo "$J2" | jq -e '.open_markers_count == 2' >/dev/null 2>&1 && ok "open_markers_count encodes as a number" || bad "open_markers_count should be 2"

echo ""
echo "-- static content sanity: playbook + schema --"
PB="$(_haiku_playbook)"
[ -n "$PB" ] && echo "$PB" | grep -q 'dolt_responds=false' && ok "playbook is non-empty and covers the dolt-down rule" || bad "playbook missing or doesn't mention dolt_responds=false"
printf '%s' "$HAIKU_JSON_SCHEMA" | jq -e '.required == ["assessment","action","mayor_message"]' >/dev/null 2>&1 \
  && ok "HAIKU_JSON_SCHEMA is valid JSON with the 3 required fields" || bad "HAIKU_JSON_SCHEMA malformed or missing required fields"

echo ""
echo "-- static content sanity: _do_kickstart never SIGKILLs a running job (ga-r5sn8 fix 1) --"
if grep -q -- 'kickstart -k "' "$SCRIPT"; then
  bad "found the dangerous 'kickstart -k \"...' invocation in $SCRIPT — SIGKILL risk reintroduced (ga-r5sn8: -k kills an in-flight reviewer spawn mid-boot, producing a zero-verdict dead gate-run)"
else
  ok "no 'launchctl kickstart -k' invocation anywhere in $SCRIPT — kickstart is a safe no-op when the job is already running, never a force-kill"
fi

# ─────────────────────────────────────────────────────────────────────────────
# main() integration scenarios — collectors + Haiku + execute all mocked.
# ─────────────────────────────────────────────────────────────────────────────

HAIKU_CALL_LOG="$TMP_ROOT/haiku-calls.log"
KICKSTART_CALLS=()
NUDGE_CALLS=()

_do_kickstart() { KICKSTART_CALLS+=("$1"); }
_do_nudge() { NUDGE_CALLS+=("$1"); }

reset_capture() {
  KICKSTART_CALLS=()
  NUDGE_CALLS=()
  rm -f "$HAIKU_CALL_LOG"
  : > "$CHS_LOG"
  STATE_DIR="$(mktemp -d)"   # fresh rate-limit slate for scenarios that don't test cooldowns
}

echo ""
echo "=== main(): all-ok -> fast-path, Haiku NOT invoked ==="
reset_capture
_collect_gate_gap() { echo "3"; }
_collect_pilot_gap() { echo "5"; }
_collect_open_markers() { echo "0"; }
_collect_disk_gb() { echo "100"; }
_collect_dolt_json() { echo '{"reachable":true,"latency_ms":40,"state":"healthy"}'; }
_invoke_haiku() { echo "called" >> "$HAIKU_CALL_LOG"; echo '{"assessment":"x","action":"none","mayor_message":""}'; return 0; }
main
if [ ! -f "$HAIKU_CALL_LOG" ] && [ "${#KICKSTART_CALLS[@]}" -eq 0 ] && [ "${#NUDGE_CALLS[@]}" -eq 0 ] && grep -q 'FAST-PATH ok' "$CHS_LOG"; then
  ok "all-ok: fast-path taken, Haiku never invoked, no actions taken"
else
  bad "all-ok: expected fast-path with zero Haiku calls and zero actions (haiku_called=$([ -f "$HAIKU_CALL_LOG" ] && echo yes || echo no) kickstarts=${#KICKSTART_CALLS[@]} nudges=${#NUDGE_CALLS[@]})"
fi

echo ""
echo "=== main(): known false-positive — gate gap elevated but 0 markers (idle-correct) -> none ==="
reset_capture
_collect_gate_gap() { echo "15"; }   # elevated enough to bypass fast-path
_collect_pilot_gap() { echo "5"; }
_collect_open_markers() { echo "0"; }
_collect_disk_gb() { echo "100"; }
_collect_dolt_json() { echo '{"reachable":true,"latency_ms":40,"state":"healthy"}'; }
_invoke_haiku() {
  echo "$1" >> "$HAIKU_CALL_LOG"          # record the exact state JSON Haiku received
  echo '{"assessment":"idle gate, 0 markers queued","action":"none","mayor_message":""}'
  return 0
}
main
if [ -f "$HAIKU_CALL_LOG" ] && [ "${#KICKSTART_CALLS[@]}" -eq 0 ] && [ "${#NUDGE_CALLS[@]}" -eq 0 ] && grep -q 'decision=none' "$CHS_LOG"; then
  ok "false-positive: ambiguous path taken (Haiku invoked), decision=none, no actions"
else
  bad "false-positive: expected Haiku invoked with action=none and zero side effects"
fi
if grep -q '"open_markers_count":0' "$HAIKU_CALL_LOG" 2>/dev/null || grep -q '"open_markers_count": 0' "$HAIKU_CALL_LOG" 2>/dev/null; then
  ok "false-positive: the state JSON handed to Haiku correctly carried open_markers_count=0"
else
  bad "false-positive: state JSON did not carry open_markers_count=0 — got: $(cat "$HAIKU_CALL_LOG" 2>/dev/null)"
fi

echo ""
echo "=== main(): gate genuinely stalled (backlog + extreme gap) -> kickstart_gate ==="
reset_capture
_collect_gate_gap() { echo "30"; }
_collect_pilot_gap() { echo "5"; }
_collect_open_markers() { echo "5"; }
_collect_disk_gb() { echo "100"; }
_collect_dolt_json() { echo '{"reachable":true,"latency_ms":40,"state":"healthy"}'; }
_invoke_haiku() { echo "called" >> "$HAIKU_CALL_LOG"; echo '{"assessment":"gate backlogged, dolt fine","action":"kickstart_gate","mayor_message":"restarting the gate"}'; return 0; }
main
if [ "${#KICKSTART_CALLS[@]}" -eq 2 ] \
   && [ "${KICKSTART_CALLS[0]}" = "com.gascity.quality-gate-guard" ] \
   && [ "${KICKSTART_CALLS[1]}" = "com.gascity.quality-gate-dispatcher" ] \
   && [ "${#NUDGE_CALLS[@]}" -eq 0 ]; then
  ok "gate-stalled: kickstart_gate restarted BOTH quality-gate-guard and quality-gate-dispatcher, no nudge"
else
  bad "gate-stalled: expected exactly 2 kickstarts (guard+dispatcher), got: ${KICKSTART_CALLS[*]:-<none>}"
fi
[ -f "$STATE_DIR/.city-health-sentinel.last-kickstart.gate" ] && ok "gate-stalled: kickstart rate-limit state file written" || bad "expected rate-limit state file for gate kickstart"

echo ""
echo "=== main(): dolt unreachable -> nudge_mayor ONLY, even if Haiku (adversarially) says otherwise ==="
reset_capture
_collect_gate_gap() { echo "3"; }
_collect_pilot_gap() { echo "5"; }
_collect_open_markers() { echo "0"; }
_collect_disk_gb() { echo "100"; }
_collect_dolt_json() { echo '{"reachable":false,"latency_ms":-1,"state":"unhealthy"}'; }
# Adversarial stub: simulates Haiku getting it WRONG. The shell-side guardrail
# must override this regardless — this is the load-bearing assertion in this
# whole file, since it proves the safety net does not depend on Haiku behaving.
_invoke_haiku() { echo "called" >> "$HAIKU_CALL_LOG"; echo '{"assessment":"gate looks slow too","action":"kickstart_gate","mayor_message":"restarting"}'; return 0; }
main
# ga-r5sn8 gate fix: assert the nudge CONTENT, not just the call counts. The
# guardrail forced nudge_mayor and discarded Haiku's kickstart_gate — so the
# message the Mayor receives must describe the ACTUAL outcome (Dolt unreachable),
# NOT Haiku's now-discarded "restarting" text. Counts alone passed while the
# stale message leaked (the variable DECIDED on != the variable ACTED on).
if [ "${#KICKSTART_CALLS[@]}" -eq 0 ] && [ "${#NUDGE_CALLS[@]}" -eq 1 ] && grep -q 'GUARDRAIL OVERRIDE' "$CHS_LOG" \
   && [[ "${NUDGE_CALLS[0]}" != *restarting* ]] && [[ "${NUDGE_CALLS[0]}" == *"Dolt is unreachable"* ]]; then
  ok "dolt-hung: guardrail overrode Haiku's kickstart_gate -> nudge_mayor only, zero kickstarts, and the nudge TEXT matches the actual action (no stale 'restarting')"
else
  bad "dolt-hung: expected guardrail to force nudge_mayor, block kickstarts, AND send a message matching what actually happened — not Haiku's discarded action (kickstarts=${#KICKSTART_CALLS[@]} nudges=${#NUDGE_CALLS[@]} msg='${NUDGE_CALLS[0]:-<none>}')"
fi

echo ""
echo "=== main(): dolt INCONCLUSIVE (reachable=null) -> 'could not confirm', NOT a confirmed outage; Haiku fed null not false (ga-r5sn8 error-vs-empty) ==="
reset_capture
_collect_gate_gap() { echo "3"; }
_collect_pilot_gap() { echo "5"; }
_collect_open_markers() { echo "0"; }
_collect_disk_gb() { echo "100"; }
# The probe's real third state: gc_dolt_probe_json returns reachable=null/state=unknown
# on a transient hiccup, a below-rc=124 timeout, or unparseable output. It is NOT an outage.
_collect_dolt_json() { echo '{"reachable":null,"latency_ms":-1,"state":"unknown"}'; }
# Adversarial: Haiku, if it had been fed a collapsed dolt_responds=false, would claim a
# hard outage and pick a Dolt-touching action. The guardrail must block the kickstart AND
# the rewritten nudge must NOT assert an outage the probe never confirmed — and Haiku must
# have been fed dolt_responds=null, not false, so its own judgment isn't built on a lie.
_invoke_haiku() {
  echo "$1" >> "$HAIKU_CALL_LOG"
  echo '{"assessment":"dolt down","action":"kickstart_gate","mayor_message":"restarting the gate"}'
  return 0
}
main
if [ "${#KICKSTART_CALLS[@]}" -eq 0 ] && [ "${#NUDGE_CALLS[@]}" -eq 1 ] \
   && [[ "${NUDGE_CALLS[0]}" == *"could NOT be confirmed"* ]] \
   && [[ "${NUDGE_CALLS[0]}" != *unreachable* ]] \
   && [ -f "$HAIKU_CALL_LOG" ] && jq -e '.dolt_responds == null' "$HAIKU_CALL_LOG" >/dev/null 2>&1; then
  ok "dolt-inconclusive: guardrail blocked the kickstart, the nudge says 'could not be confirmed' (no false outage), and Haiku was fed dolt_responds=null (not false)"
else
  bad "dolt-inconclusive: expected a non-asserting nudge + null fed to Haiku (kickstarts=${#KICKSTART_CALLS[@]} nudges=${#NUDGE_CALLS[@]} msg='${NUDGE_CALLS[0]:-<none>}' haiku_dolt=$(jq -c '.dolt_responds' "$HAIKU_CALL_LOG" 2>/dev/null))"
fi

echo ""
echo "=== main(): Haiku call fails/times out -> deterministic fallback (gate critical) ==="
reset_capture
_collect_gate_gap() { echo "20"; }   # > GATE_GAP_CRITICAL_MIN(12)
_collect_pilot_gap() { echo "5"; }
_collect_open_markers() { echo "1"; }
_collect_disk_gb() { echo "100"; }
_collect_dolt_json() { echo '{"reachable":true,"latency_ms":40,"state":"healthy"}'; }
_invoke_haiku() { echo "called" >> "$HAIKU_CALL_LOG"; return 1; }   # simulate failure/timeout
main
if [ "${#KICKSTART_CALLS[@]}" -eq 2 ] && grep -qi 'Haiku unavailable' "$CHS_LOG"; then
  ok "haiku-fails + gate_gap>12: deterministic fallback fired kickstart_gate, logged as degraded"
else
  bad "expected deterministic fallback to kickstart_gate on Haiku failure with gate_gap=20"
fi

echo ""
echo "=== main(): Haiku call fails -> deterministic fallback (dolt down takes priority over gate) ==="
reset_capture
_collect_gate_gap() { echo "3"; }
_collect_pilot_gap() { echo "5"; }
_collect_open_markers() { echo "0"; }
_collect_disk_gb() { echo "100"; }
_collect_dolt_json() { echo '{"reachable":false,"latency_ms":-1,"state":"unhealthy"}'; }
_invoke_haiku() { return 1; }
main
if [ "${#KICKSTART_CALLS[@]}" -eq 0 ] && [ "${#NUDGE_CALLS[@]}" -eq 1 ]; then
  ok "haiku-fails + dolt down: deterministic fallback chose nudge_mayor, never kickstart"
else
  bad "expected deterministic fallback to nudge_mayor when dolt is down (kickstarts=${#KICKSTART_CALLS[@]} nudges=${#NUDGE_CALLS[@]})"
fi

echo ""
echo "=== main(): Haiku fails, nothing actually critical (pilot-only ambiguity) -> fallback is 'none' ==="
reset_capture
_collect_gate_gap() { echo "3"; }
_collect_pilot_gap() { echo "25"; }   # ambiguous (bypasses fast-path) but not covered by the 2-condition fallback rule
_collect_open_markers() { echo "0"; }
_collect_disk_gb() { echo "100"; }
_collect_dolt_json() { echo '{"reachable":true,"latency_ms":40,"state":"healthy"}'; }
_invoke_haiku() { return 1; }
main
if [ "${#KICKSTART_CALLS[@]}" -eq 0 ] && [ "${#NUDGE_CALLS[@]}" -eq 0 ] && grep -q 'decision=none' "$CHS_LOG"; then
  ok "haiku-fails + pilot-only ambiguity: fallback correctly stays 'none' (fallback rule is gate/dolt only, never invents a pilot rule)"
else
  bad "expected the 2-condition fallback to land on none for a pilot-only ambiguity"
fi

echo ""
echo "=== main(): Haiku returns an action outside the allowlist -> treated as none ==="
reset_capture
_collect_gate_gap() { echo "15"; }
_collect_pilot_gap() { echo "5"; }
_collect_open_markers() { echo "0"; }
_collect_disk_gb() { echo "100"; }
_collect_dolt_json() { echo '{"reachable":true,"latency_ms":40,"state":"healthy"}'; }
_invoke_haiku() { echo '{"assessment":"x","action":"restart_dolt_directly","mayor_message":"y"}'; return 0; }
main
if [ "${#KICKSTART_CALLS[@]}" -eq 0 ] && [ "${#NUDGE_CALLS[@]}" -eq 0 ] && grep -q 'not in the allowlist' "$CHS_LOG"; then
  ok "hallucinated action rejected by the allowlist, fell back to none, logged"
else
  bad "expected an out-of-allowlist action to be rejected and treated as none"
fi

echo ""
echo "=== main(): kickstart rate-limit — second stall within cooldown is suppressed ==="
reset_capture
_collect_gate_gap() { echo "30"; }
_collect_pilot_gap() { echo "5"; }
_collect_open_markers() { echo "5"; }
_collect_disk_gb() { echo "100"; }
_collect_dolt_json() { echo '{"reachable":true,"latency_ms":40,"state":"healthy"}'; }
_invoke_haiku() { echo '{"assessment":"x","action":"kickstart_gate","mayor_message":"y"}'; return 0; }
main   # first firing — should execute
FIRST_COUNT="${#KICKSTART_CALLS[@]}"
main   # immediately again, same STATE_DIR — should be suppressed
SECOND_COUNT="${#KICKSTART_CALLS[@]}"
if [ "$FIRST_COUNT" -eq 2 ] && [ "$SECOND_COUNT" -eq 2 ] && grep -q 'SUPPRESSED kickstart_gate' "$CHS_LOG"; then
  ok "kickstart rate-limit: second stall inside the 3min cooldown window did not fire again"
else
  bad "expected the second kickstart_gate within cooldown to be suppressed (first=$FIRST_COUNT second=$SECOND_COUNT)"
fi

echo ""
echo "=== main(): nudge rate-limit is per-topic — dolt-topic cooldown does not block a later disk-topic nudge ==="
reset_capture
_collect_gate_gap() { echo "3"; }
_collect_pilot_gap() { echo "5"; }
_collect_open_markers() { echo "0"; }
_collect_dolt_json() { echo '{"reachable":false,"latency_ms":-1,"state":"unhealthy"}'; }
_invoke_haiku() { echo '{"assessment":"x","action":"nudge_mayor","mayor_message":"dolt down"}'; return 0; }
_collect_disk_gb() { echo "100"; }
main   # topic=dolt, fires
DOLT_NUDGES="${#NUDGE_CALLS[@]}"
_collect_dolt_json() { echo '{"reachable":false,"latency_ms":-1,"state":"unhealthy"}'; }
main   # same topic=dolt, immediately again -> suppressed
DOLT_NUDGES_2="${#NUDGE_CALLS[@]}"
# now a DIFFERENT topic (disk) — must fire despite the dolt topic still cooling down
_collect_dolt_json() { echo '{"reachable":true,"latency_ms":40,"state":"healthy"}'; }
_collect_disk_gb() { echo "2"; }
_invoke_haiku() { echo '{"assessment":"x","action":"nudge_mayor","mayor_message":"disk low"}'; return 0; }
main
DISK_NUDGES="${#NUDGE_CALLS[@]}"
if [ "$DOLT_NUDGES" -eq 1 ] && [ "$DOLT_NUDGES_2" -eq 1 ] && [ "$DISK_NUDGES" -eq 2 ]; then
  ok "nudge rate-limit: dolt-topic suppressed its own repeat, but a distinct disk-topic nudge still fired"
else
  bad "expected per-topic isolation (dolt_first=$DOLT_NUDGES dolt_second=$DOLT_NUDGES_2 disk=$DISK_NUDGES)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# ga-r5sn8 fix 2: reviewer-active guard — main() integration scenarios.
# These override _collect_session_list_json (mocking "gc session list"), so
# they MUST run last: unlike the other _collect_* mocks, nothing later in this
# file re-establishes the "no active reviewer" default once these override it.
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== main(): gate genuinely stalled (backlog + extreme gap) BUT a gate-reviewer is actively booting -> SKIPPED, no kickstart ==="
reset_capture
_collect_gate_gap() { echo "30"; }
_collect_pilot_gap() { echo "5"; }
_collect_open_markers() { echo "5"; }
_collect_disk_gb() { echo "100"; }
_collect_dolt_json() { echo '{"reachable":true,"latency_ms":40,"state":"healthy"}'; }
_invoke_haiku() { echo '{"assessment":"gate backlogged, dolt fine","action":"kickstart_gate","mayor_message":"restarting the gate"}'; return 0; }
# state=start-pending is the REAL value observed live on 2026-07-20 for a
# gate-reviewer moments into its boot (not "creating" — see _reviewer_active_id).
_collect_session_list_json() { echo '{"sessions":[{"id":"rev-abc123","template":"gate-reviewer","state":"start-pending","closed":false}]}'; }
main
if [ "${#KICKSTART_CALLS[@]}" -eq 0 ] && [ "${#NUDGE_CALLS[@]}" -eq 0 ] && grep -q 'SKIPPED kickstart_gate' "$CHS_LOG" && grep -q 'rev-abc123' "$CHS_LOG"; then
  ok "reviewer-active guard: an active/booting gate-reviewer (state=start-pending, the live-verified real value) blocked the kickstart, logged with its id"
else
  bad "expected kickstart_gate to be SKIPPED while a gate-reviewer is start-pending/booting (kickstarts=${#KICKSTART_CALLS[@]} nudges=${#NUDGE_CALLS[@]})"
fi

echo ""
echo "=== main(): gate genuinely stalled, no reviewer active (context-check-reviewer + an asleep gate-reviewer don't count) -> kickstart proceeds ==="
reset_capture
_collect_gate_gap() { echo "30"; }
_collect_pilot_gap() { echo "5"; }
_collect_open_markers() { echo "5"; }
_collect_disk_gb() { echo "100"; }
_collect_dolt_json() { echo '{"reachable":true,"latency_ms":40,"state":"healthy"}'; }
_invoke_haiku() { echo '{"assessment":"gate backlogged, dolt fine","action":"kickstart_gate","mayor_message":"restarting the gate"}'; return 0; }
_collect_session_list_json() { echo '{"sessions":[{"id":"ccr-1","template":"context-check-reviewer","state":"active"},{"id":"rev-old","template":"gate-reviewer","state":"asleep"}]}'; }
main
if [ "${#KICKSTART_CALLS[@]}" -eq 2 ] && [ "${#NUDGE_CALLS[@]}" -eq 0 ] && grep -q 'EXECUTED kickstart_gate' "$CHS_LOG"; then
  ok "reviewer-active guard: no genuinely active/booting gate-reviewer present -> kickstart proceeded normally"
else
  bad "expected kickstart_gate to proceed when no gate-reviewer is active/booting (kickstarts=${#KICKSTART_CALLS[@]})"
fi

echo ""
echo "=== main(): Haiku fails + gate critical + reviewer active -> the DETERMINISTIC FALLBACK itself declines kickstart_gate ==="
reset_capture
_collect_gate_gap() { echo "20"; }   # > GATE_GAP_CRITICAL_MIN(12)
_collect_pilot_gap() { echo "5"; }
_collect_open_markers() { echo "1"; }
_collect_disk_gb() { echo "100"; }
_collect_dolt_json() { echo '{"reachable":true,"latency_ms":40,"state":"healthy"}'; }
_invoke_haiku() { return 1; }   # force the deterministic fallback path
_collect_session_list_json() { echo '{"sessions":[{"id":"rev-mid-boot","template":"refino-gate-reviewer","state":"active"}]}'; }
main
if [ "${#KICKSTART_CALLS[@]}" -eq 0 ] && [ "${#NUDGE_CALLS[@]}" -eq 0 ] \
   && grep -q 'SKIPPED kickstart_gate (deterministic fallback)' "$CHS_LOG" && grep -q 'rev-mid-boot' "$CHS_LOG" \
   && grep -q 'decision=none' "$CHS_LOG"; then
  ok "fallback path: gate_gap>12 would normally fall back to kickstart_gate, but an active refino-gate-reviewer made the FALLBACK ITSELF choose none (not just the execute-layer guard)"
else
  bad "expected the deterministic fallback to decline kickstart_gate while a reviewer is active (kickstarts=${#KICKSTART_CALLS[@]})"
fi

rm -rf "$TMP_ROOT" 2>/dev/null || true

echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
