#!/usr/bin/env bash
# pilot-dispatcher.count-unreadable-halt.selftest.sh — ga-5je3zv
#
# Incident (2026-09-30 18:44→20:14): ONE `gc session list --json` read timed out (30s budget, disk/swap spike at
# 18:55). _PLSC_UNREADABLE is sticky for the sweep, so from then on every gate that needs the session count
# failed — correctly, fail-CLOSED (ga-oa004t). But the lane loop kept going: for each of the approved beads it
# claimed atomically, chose a builder, assembled the prompt (~1 min), hit the count gate, failed instantly and
# released the claim. 85 times in 79 min, zero spawns, the whole time holding the launchd StartInterval (19
# approved beads parked, last merge 80 min old). `session list` took 3-6 s again by the time anyone looked.
# The same shape cost a 1h02 sweep on 2026-09-26 (71 "cannot read" lines). The fail-closed gate is RIGHT; the
# defect is what the sweep does AFTER it.
#
# Fix under test (pilot-dispatcher.sh): an unreadable count HALTS the dispatch phase of that sweep — one log
# line, the lane loops break, the rig fallback is skipped, the `pilot_sweep` event carries `halted` — and the
# dispatch phase has a wall-clock budget (PILOT_DISPATCH_MAX_SECS) so the NEXT slow per-candidate path cannot
# hold the StartInterval for hours either.
#
# Every behavioural assertion below is written to FAIL against the pre-fix dispatcher (run with
# PILOT_DISPATCHER_PATH pointing at a pre-fix copy to see it RED: dispatch_one() is reached once per candidate
# there). The controls (T3, T4c/e) only guard against OVER-blocking: a full pool, a guard refusal or a cap-off
# knob must keep behaving exactly as before.
#
# Real dispatch_lane() + the real probe chain (_pilot_pool_cap_full_for → _pilot_pool_live_count →
# _pilot_live_session_count → gc_json_or_unknown) are extracted verbatim from the dispatcher (awk) and run under
# the dispatcher's own `set -euo pipefail` against a fake `gc` that is a REAL executable on PATH (`timeout`
# exec()s its argument, so a shell function named gc would be invisible to it). dispatch_one() is stubbed: what
# is under test is the LOOP'S decision to call it, and what it does when the count is unreadable. The full-script
# path (real dispatch_one, rig fallback, sweep event) is proven in pilot-dispatcher.selftest.sh, scenario SWEEP-E.
#
# Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
# ga-ck3sz7: the scenarios run on a PATH with NO real gc/bd (selftest-sandbox-path.lib.sh); the fake `gc` in
# $WORK/bin is the only one they can find, so a vanished $WORK can never become a real `gc` call.
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

# fn_src <name> — the function's source verbatim, or nothing if the file does not define it.
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }

FUNCS=""
for _f in gc_json_or_unknown _pilot_live_session_count _pilot_pool_live_count _pilot_pool_cap_full_for \
          _pilot_note_pool_cap_queued _pilot_sweep_note _pilot_dispatch_halt _pilot_dispatch_should_stop dispatch_lane; do
  FUNCS="$FUNCS
$(fn_src "$_f")"
done
[ -n "$(fn_src dispatch_lane)" ]             || { echo "FATAL: dispatch_lane() not found in $DISPATCHER" >&2; exit 2; }
[ -n "$(fn_src _pilot_pool_cap_full_for)" ]  || { echo "FATAL: _pilot_pool_cap_full_for() not found in $DISPATCHER" >&2; exit 2; }
[ -n "$(fn_src _pilot_live_session_count)" ] || { echo "FATAL: _pilot_live_session_count() not found in $DISPATCHER" >&2; exit 2; }
EMIT_FN="$(fn_src _pilot_sweep_emit)"
[ -n "$EMIT_FN" ] || { echo "FATAL: _pilot_sweep_emit() not found in $DISPATCHER" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-counthalt-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Fake gc — `session list` behaviour steered by files in $SELFTEST_WORK; every call is counted.
cat > "$WORK/bin/gc" <<'GCEOF'
#!/usr/bin/env bash
W="${SELFTEST_WORK:?}"
case "$*" in
  *"session list"*)
    echo x >> "$W/list.calls"
    if [ -f "$W/sl.fail" ]; then echo "boom" >&2; exit 1; fi
    if [ -f "$W/sl.envelope" ]; then printf '{"ok":false,"error":{"code":"native_store_unavailable"}}'; exit 0; fi
    cat "$W/sl.json"; exit 0 ;;
esac
exit 0
GCEOF
chmod +x "$WORK/bin/gc"
# `timeout` shim: drop the duration and exec (deterministic; nothing here is about the probe's own budget).
cat > "$WORK/bin/timeout" <<'TOEOF'
#!/usr/bin/env bash
shift
exec "$@"
TOEOF
chmod +x "$WORK/bin/timeout"
sandbox_path_init "$WORK" jq || exit 2   # jq: the session-list parsing; gc and timeout are the shims above

reset() { rm -f "$WORK"/list.calls "$WORK"/sl.* "$WORK"/attempts "$WORK"/log.txt "$WORK"/state.txt "$WORK"/pilot.jsonl; }
sessions_json() { # <template:state>... -> {"sessions":[…]}
  local _first=1 _s _i=0
  printf '{"sessions":['
  for _s in "$@"; do
    [ "$_first" = 1 ] || printf ','
    _first=0; _i=$((_i+1))
    printf '{"id":"s%d","template":"%s","state":"%s"}' "$_i" "${_s%%:*}" "${_s##*:}"
  done
  printf ']}'
}
# cand <id> [routed_to] — one candidate bead, as dispatch_lane()/_pilot_pool_cap_full_for() read it.
cand() {
  local _md='{}'
  [ -z "${2:-}" ] || _md='{"gc.routed_to":"'"$2"'"}'
  printf '{"id":"%s","priority":2,"issue_type":"feature","labels":["story:approved"],"metadata":%s}' "$1" "$_md"
}
pool_of() { local _o="" _c; for _c in "$@"; do _o="$_o${_o:+,}$_c"; done; printf '[%s]' "$_o"; }
attempts() { [ -f "$WORK/attempts" ] && wc -l < "$WORK/attempts" | tr -d ' ' || echo 0; }
list_calls() { [ -f "$WORK/list.calls" ] && wc -l < "$WORK/list.calls" | tr -d ' ' || echo 0; }
state_get() { sed -n "s/^$1=//p" "$WORK/state.txt" 2>/dev/null | head -1; }
log_count() { local _c; _c=$(grep -cF -- "$1" "$WORK/log.txt" 2>/dev/null) || _c=0; printf '%s' "${_c:-0}"; }

# run_lanes <lane-spec>... — one sweep's dispatch phase in ONE shell (the halt flag, the sticky unreadable flag and
# the counters live across lanes exactly as in the real sweep). Each lane-spec is "<lane>|<slots>|<pool-json>".
# Knobs (env, read here): ONE_MODE (what the stubbed dispatch_one() does), MAXSECS (PILOT_DISPATCH_MAX_SECS,
# unset if empty), T0 (_PILOT_DISPATCH_T0), SECONDS_AT_START, SPAWN_WA (PILOT_SPAWN_WA_WORKER), SLOW_STEP.
run_lanes() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"
    SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    GC_CITY="test-city"; DRY_RUN=0
    DISPATCH_TO_CAPACITY=1; PILOT_DOLT_SATURATED_AT_START=0
    PILOT_SPAWN_WA_WORKER="${SPAWN_WA:-1}"; PILOT_SPAWN_PS_WORKER=1
    PILOT_WA_WORKER_MAX=4; PILOT_PS_WORKER_MAX=2
    unset GC_VARIABLE_SESSION_COUNT_OVERRIDE PILOT_TEST_WA_WORKER_LIVE_COUNT PILOT_TEST_PS_WORKER_LIVE_COUNT
    if [ -n "${MAXSECS:-}" ]; then PILOT_DISPATCH_MAX_SECS="$MAXSECS"; else unset PILOT_DISPATCH_MAX_SECS; fi
    [ -z "${SECONDS_AT_START:-}" ] || SECONDS="$SECONDS_AT_START"
    _PILOT_DISPATCH_T0="${T0-}"
    _PILOT_HALT=""; _PLSC_N=""; _PLSC_UNREADABLE=""
    _PCAP_LIVE_WA=""; _PCAP_LIVE_PS=""; _PCAP_N=""; _PCAP_POOL=""; _PCAP_LIVE=""; _PCAP_MAX=""
    _PCAP_COUNT_UNREADABLE=""; _PCAP_CALL_QUEUED=0; _PCAP_WARNED_WA=""; _PCAP_WARNED_PS=""
    POOL_CAP_QUEUED=0; POOL_CAP_QUEUED_IDS=""; NONQUEUE_FAILS=0; DISPATCHED=0; SWEEP_OUTCOMES=""; DISPATCH_RESULT=""
    log()  { printf 'log\t%s\n'  "$*" >> "$WORK/log.txt"; }
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/log.txt"; }
    # Stubs for what dispatch_lane() calls but this test is not about.
    _top_candidate() { printf '%s' "$1" | jq -c '.[0]'; }
    _bead_tier() { echo tier1; }
    _pilot_slow_spawn_deferred_for() { return 1; }
    _dolt_saturated() { return 1; }
    dispatch_one() {
      DISPATCH_RESULT=""
      printf '%s' "$1" | jq -r '.id' >> "$WORK/attempts"
      case "${ONE_MODE:-unreadable}" in
        unreadable) DISPATCH_RESULT="rig_native_pool_count_unreadable"; return 1 ;;   # dispatch_one()'s own count gate
        refuse)     DISPATCH_RESULT="pool_ownership_refuse"; return 1 ;;              # a deliberate guard refusal
        slow)       SECONDS=$(( SECONDS + ${SLOW_STEP:-400} )); DISPATCH_RESULT="pool_ownership_refuse"; return 1 ;;
        ok)         DISPATCH_RESULT="rig_native_ok"; return 0 ;;
      esac
    }
    eval "$FUNCS"
    local _spec _lane _rest _slots _pool
    for _spec in "$@"; do
      _lane="${_spec%%|*}"; _rest="${_spec#*|}"; _slots="${_rest%%|*}"; _pool="${_rest#*|}"
      dispatch_lane "$_lane" "$_pool" "$_slots"
    done
    {
      echo "HALT=${_PILOT_HALT:-}"
      echo "NQ=$NONQUEUE_FAILS"
      echo "DISP=$DISPATCHED"
      echo "CAPQ=$POOL_CAP_QUEUED"
      printf 'OUTCOMES=%s\n' "$(printf '%s' "$SWEEP_OUTCOMES" | tr '\n\t' ';,')"
    } > "$WORK/state.txt"
  ) || echo "  (run_lanes subshell exited non-zero — the loop aborted under set -e?)" >&2
}

echo "pilot-dispatcher.count-unreadable-halt.selftest — an unreadable session count halts the dispatch phase; the phase has a time budget (ga-5je3zv)"

# ── T1: PRE-CLAIM — pool-committed candidates, `session list` dead ──────────────────────────────────────────
echo "T1: 3 beads already routed to wa-worker, 'gc session list' fails — no claim for ANY of them, one halt line (was: claim + release for each)"
reset; : > "$WORK/sl.fail"
ONE_MODE=unreadable MAXSECS="" T0="" run_lanes "small|5|$(pool_of "$(cand wa-a wa-worker)" "$(cand wa-b wa-worker)" "$(cand wa-c wa-worker)")"
[ "$(attempts)" = "0" ] \
  && ok "T1: dispatch_one() never reached — no claim → assemble → release churn" \
  || bad "T1: dispatch_one() reached $(attempts) time(s) on an unreadable count — the sweep pays the full per-candidate price for each (the 85-claim incident)"
[ "$(state_get HALT)" = "session-count-unreadable" ] \
  && ok "T1: the dispatch phase is marked HALTED (session-count-unreadable)" \
  || bad "T1: no halt recorded (HALT='$(state_get HALT)') — the next lane / the rig fallback would walk the same dead probe"
[ "$(log_count 'dispatch phase HALTED')" = "1" ] \
  && ok "T1: the halt is logged exactly ONCE (not once per candidate left un-attempted)" \
  || bad "T1: halt logged $(log_count 'dispatch phase HALTED') time(s) — expected exactly 1"
[ "$(list_calls)" = "1" ] \
  && ok "T1: the dead probe was paid for ONCE this sweep (sticky flag, control)" \
  || bad "T1: 'session list' called $(list_calls) times — the sticky unreadable flag stopped holding"
case "$(state_get OUTCOMES)" in
  wa-a,1,rig_native_pool_count_unreadable\;) ok "T1: the candidate that hit the dead probe is ACCOUNTED under rig_native_pool_count_unreadable (the sweep event still closes, as failed_other — a fault, not saturation)" ;;
  *) bad "T1: outcomes='$(state_get OUTCOMES)' — expected exactly 'wa-a,1,rig_native_pool_count_unreadable;'" ;;
esac
[ "$(state_get NQ)" -ge 1 ] 2>/dev/null \
  && ok "T1: counted in NONQUEUE_FAILS — the Step 5 stall streak still sees a sweep that dispatched nothing (NQ=$(state_get NQ))" \
  || bad "T1: NONQUEUE_FAILS='$(state_get NQ)' — a halted sweep would read as clean saturation and hide the stall"

# ── T2: IN-ARM — first-sight candidates (no gc.routed_to yet); dispatch_one() itself reports the dead count ─
echo "T2: 3 first-sight beads, dispatch_one() reports the unreadable count on the FIRST — the lane stops there, and so does the next lane"
reset; : > "$WORK/sl.fail"
ONE_MODE=unreadable MAXSECS="" T0="" run_lanes \
  "small|5|$(pool_of "$(cand fs-a)" "$(cand fs-b)" "$(cand fs-c)")" \
  "big|2|$(pool_of "$(cand fs-d)" "$(cand fs-e)")"
[ "$(attempts)" = "1" ] \
  && ok "T2: exactly ONE dispatch_one() attempt across both lanes" \
  || bad "T2: $(attempts) dispatch_one() attempts across both lanes — expected 1 (every later candidate repeats claim → assemble → release for nothing)"
[ "$(state_get HALT)" = "session-count-unreadable" ] \
  && ok "T2: halted (session-count-unreadable)" \
  || bad "T2: no halt recorded (HALT='$(state_get HALT)')"
[ "$(log_count 'dispatch phase HALTED')" = "1" ] \
  && ok "T2: logged exactly once for the whole sweep (the second lane adds no line)" \
  || bad "T2: halt logged $(log_count 'dispatch phase HALTED') time(s) — expected 1"

# ── T3: CONTROLS — nothing here may halt ────────────────────────────────────────────────────────────────────
echo "T3a: a guard REFUSAL (readable count) — every candidate is still attempted; a refusal is not an unreadable count"
reset; sessions_json wa-worker:active > "$WORK/sl.json"
ONE_MODE=refuse MAXSECS="" T0="" run_lanes "small|5|$(pool_of "$(cand c-a wa-worker)" "$(cand c-b wa-worker)" "$(cand c-c wa-worker)")"
[ "$(attempts)" = "3" ] && [ -z "$(state_get HALT)" ] \
  && ok "T3a: 3 attempts, no halt" \
  || bad "T3a: attempts=$(attempts) HALT='$(state_get HALT)' — the halt over-fires on an ordinary refusal"

echo "T3b: readable count, dispatch_one() succeeds — slots fill normally"
reset; sessions_json wa-worker:active > "$WORK/sl.json"
ONE_MODE=ok MAXSECS="" T0="" run_lanes "small|2|$(pool_of "$(cand d-a wa-worker)" "$(cand d-b wa-worker)" "$(cand d-c wa-worker)")"
[ "$(state_get DISP)" = "2" ] && [ "$(attempts)" = "2" ] && [ -z "$(state_get HALT)" ] \
  && ok "T3b: dispatched=2 of 2 slots, no halt" \
  || bad "T3b: dispatched=$(state_get DISP) attempts=$(attempts) HALT='$(state_get HALT)'"

echo "T3c: pool AT CAP (readable) — queued pre-claim, NOT a halt (a full pool is backpressure, not an unreadable count)"
reset; sessions_json wa-worker:active wa-worker:active wa-worker:active wa-worker:active > "$WORK/sl.json"
ONE_MODE=unreadable MAXSECS="" T0="" run_lanes "small|5|$(pool_of "$(cand q-a wa-worker)" "$(cand q-b wa-worker)" "$(cand q-c wa-worker)")"
[ "$(attempts)" = "0" ] && [ "$(state_get CAPQ)" = "3" ] && [ -z "$(state_get HALT)" ] \
  && ok "T3c: 3 queued behind the cap, 0 attempts, no halt" \
  || bad "T3c: attempts=$(attempts) queued=$(state_get CAPQ) HALT='$(state_get HALT)' — a full pool is being confused with a dead probe"

echo "T3d: PILOT_SPAWN_WA_WORKER=0 (nudge-only debug mode) with a dead probe — dispatch_one() never reads the count in that mode, so nothing halts"
reset; : > "$WORK/sl.fail"
SPAWN_WA=0 ONE_MODE=refuse MAXSECS="" T0="" run_lanes "small|5|$(pool_of "$(cand n-a wa-worker)" "$(cand n-b wa-worker)")"
[ "$(attempts)" = "2" ] && [ -z "$(state_get HALT)" ] \
  && ok "T3d: both attempted, no halt (the pre-claim probe is OFF in that mode, exactly as before)" \
  || bad "T3d: attempts=$(attempts) HALT='$(state_get HALT)' — the halt fires for a mode that never needed the count"

# ── T4: the dispatch phase's TIME BUDGET ────────────────────────────────────────────────────────────────────
echo "T4a: the budget is already spent when the loop starts (900s cap, 5000s in) — no candidate is started"
reset; sessions_json > "$WORK/sl.json"
ONE_MODE=refuse MAXSECS=900 T0=0 SECONDS_AT_START=5000 run_lanes "small|5|$(pool_of "$(cand b-a)" "$(cand b-b)" "$(cand b-c)")"
[ "$(attempts)" = "0" ] && [ "$(state_get HALT)" = "time-budget" ] \
  && ok "T4a: 0 attempts, halted (time-budget)" \
  || bad "T4a: attempts=$(attempts) HALT='$(state_get HALT)' — nothing bounds how long the dispatch phase can hold the StartInterval"
[ "$(log_count 'PILOT_DISPATCH_MAX_SECS=900s')" = "1" ] \
  && ok "T4a: the cap is named in the ONE log line (an operator can see which knob to turn)" \
  || bad "T4a: the halt line does not name PILOT_DISPATCH_MAX_SECS=900s"

echo "T4b: the budget runs out MID-lane — each attempt costs 400s against a 900s cap, 5 candidates: attempts 1-3 run, 4 and 5 do not"
reset; sessions_json > "$WORK/sl.json"
ONE_MODE=slow SLOW_STEP=400 MAXSECS=900 T0=0 SECONDS_AT_START=0 run_lanes "small|10|$(pool_of "$(cand m-a)" "$(cand m-b)" "$(cand m-c)" "$(cand m-d)" "$(cand m-e)")"
[ "$(attempts)" = "3" ] && [ "$(state_get HALT)" = "time-budget" ] \
  && ok "T4b: 3 attempts, then halted — a dispatch already in flight is never cut, the NEXT one is not started" \
  || bad "T4b: attempts=$(attempts) HALT='$(state_get HALT)' — expected 3 and time-budget"
[ "$(state_get NQ)" -ge 4 ] 2>/dev/null \
  && ok "T4b: the cut-short loop is counted in NONQUEUE_FAILS (3 failed attempts + the un-attempted remainder; NQ=$(state_get NQ))" \
  || bad "T4b: NONQUEUE_FAILS='$(state_get NQ)' — a budget-halted sweep would not show to the Step 5 stall streak"

echo "T4c: PILOT_DISPATCH_MAX_SECS=0 lifts the cap (control)"
reset; sessions_json > "$WORK/sl.json"
ONE_MODE=refuse MAXSECS=0 T0=0 SECONDS_AT_START=5000 run_lanes "small|5|$(pool_of "$(cand z-a)" "$(cand z-b)" "$(cand z-c)")"
[ "$(attempts)" = "3" ] && [ -z "$(state_get HALT)" ] \
  && ok "T4c: 3 attempts, no halt with the cap off" \
  || bad "T4c: attempts=$(attempts) HALT='$(state_get HALT)' — MAX_SECS=0 must mean 'no cap'"

echo "T4d: a garbage PILOT_DISPATCH_MAX_SECS does NOT silently disable the cap — it falls back to the 900s default"
reset; sessions_json > "$WORK/sl.json"
ONE_MODE=refuse MAXSECS=abc T0=0 SECONDS_AT_START=5000 run_lanes "small|5|$(pool_of "$(cand g-a)" "$(cand g-b)")"
[ "$(attempts)" = "0" ] && [ "$(state_get HALT)" = "time-budget" ] \
  && ok "T4d: garbage value → default cap still enforced" \
  || bad "T4d: attempts=$(attempts) HALT='$(state_get HALT)' — a typo in the knob turned the safety cap off"

echo "T4e: the phase has not started (no T0) — there is no budget to spend (control: the helper is inert outside the dispatch phase)"
reset; sessions_json > "$WORK/sl.json"
ONE_MODE=refuse MAXSECS=900 T0="" SECONDS_AT_START=5000 run_lanes "small|5|$(pool_of "$(cand e-a)" "$(cand e-b)")"
[ "$(attempts)" = "2" ] && [ -z "$(state_get HALT)" ] \
  && ok "T4e: 2 attempts, no halt" \
  || bad "T4e: attempts=$(attempts) HALT='$(state_get HALT)'"

# ── T5: the pilot_sweep event carries the halt ──────────────────────────────────────────────────────────────
echo "T5: the per-sweep pilot_sweep event says WHY it was cut short (halted), and stays null for a sweep that ran to the end"
emit_and_read() { # <halt reason or ""> <jq expr over the line>
  reset
  (
    PATH="$SANDBOX_PATH"
    PILOT_LOG="$WORK/pilot.jsonl"; DRY_RUN=0; _pool_saturated_sweep=0; SMALL_SLOTS=5; BIG_SLOTS=2
    _PILOT_HALT="$1"
    warn() { :; }
    eval "$EMIT_FN"
    SWEEP_OUTCOMES=$'wa-a\t1\trig_native_pool_count_unreadable\n'
    _pilot_sweep_emit
  )
  jq -c "$2" "$WORK/pilot.jsonl" 2>/dev/null
}
_g="$(emit_and_read session-count-unreadable '.halted')"
[ "$_g" = '"session-count-unreadable"' ] \
  && ok "T5: halted=\"session-count-unreadable\" on a halted sweep" \
  || bad "T5: .halted = ${_g:-<no output>} on a halted sweep — the painel/consumers cannot tell a cut-short sweep from a finished one"
_g="$(emit_and_read "" '.halted')"
[ "$_g" = "null" ] && ok "T5: halted=null on a sweep that ran to the end (additive field: nothing that ignores it changes)" \
                   || bad "T5: .halted = ${_g:-<no output>} on a normal sweep — expected null"
_g="$(emit_and_read session-count-unreadable '[.candidates, .failed_other, .queued_pool_cap, .pool_saturated]')"
[ "$_g" = "[1,1,0,0]" ] \
  && ok "T5: the dead-probe candidate lands in failed_other (a fault), NOT queued_pool_cap, and the sweep is NOT pool_saturated — Step 5 keeps seeing it" \
  || bad "T5: [candidates,failed_other,queued_pool_cap,pool_saturated] = ${_g:-<none>} — expected [1,1,0,0]"

# ── T6: top-level wiring (the script-level statements no function extraction can reach) ─────────────────────
echo "T6: top-level wiring — the phase clock starts before the first lane loop, and the rig fallback honours the halt"
l_t0="$(grep -nE '^_PILOT_DISPATCH_T0=\$SECONDS' "$DISPATCHER" | head -1 | cut -d: -f1)"
l_first_lane="$(grep -nE '^  dispatch_lane "small"|^dispatch_lane "small"' "$DISPATCHER" | head -1 | cut -d: -f1)"
if [ -n "$l_t0" ] && [ -n "$l_first_lane" ] && [ "$l_t0" -lt "$l_first_lane" ]; then
  ok "T6: _PILOT_DISPATCH_T0=\$SECONDS is set (L$l_t0) before the first dispatch_lane call (L$l_first_lane)"
else
  bad "T6: the dispatch-phase clock is not started before the first lane loop (t0 L${l_t0:-?}, first lane L${l_first_lane:-?}) — the time budget would never bind"
fi
# ga-9t9acg.2: Step 4b (the post-lane rig fallback this assertion used to pin) is gone — the rig DBs JOIN the HQ pool
# in Step 2c, BEFORE the lanes. The protection is the same one, moved with the scan: no rig scan to JOIN the pool on a
# sweep that already found the count unreadable or halted. Pinned the way it always was (structurally — these are
# script-level statements): the halt flag is computed from BOTH signals, the join condition reads it, and both come
# before the scan call. The empty-HQ scan stays ungated, as it was.
l_halt="$(grep -nE '^if \[ -n "\$\{_PILOT_HALT:-\}" \] \|\| \[ -n "\$\{_PLSC_UNREADABLE:-\}" \]; then _RIG_JOIN_HALTED=1' "$DISPATCHER" | head -1 | cut -d: -f1)"
l_join="$(grep -nE '^if \[ -z "\$ALL_CANDIDATES_TIER" \] \|\| \{ \[ -z "\$_RIG_JOIN_HALTED" \]' "$DISPATCHER" | head -1 | cut -d: -f1)"
l_scan="$(grep -nE '^  _scan_rig_fallback_pool$' "$DISPATCHER" | head -1 | cut -d: -f1)"
if [ -n "$l_halt" ] && [ -n "$l_join" ] && [ -n "$l_scan" ] && [ "$l_halt" -lt "$l_join" ] && [ "$l_join" -lt "$l_scan" ]; then
  ok "T6: the Step 2c rig JOIN is gated on the halt / the unreadable count (L$l_halt flag, L$l_join condition, L$l_scan scan) — no rig scan for lanes that would stop at their first iteration"
else
  bad "T6: the rig join is not gated on _PILOT_HALT / _PLSC_UNREADABLE (flag L${l_halt:-?}, condition L${l_join:-?}, scan L${l_scan:-?}) — a halted sweep still pays a rig-DB scan on the box that just could not answer 'session list'"
fi

echo
echo "pilot-dispatcher.count-unreadable-halt.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
