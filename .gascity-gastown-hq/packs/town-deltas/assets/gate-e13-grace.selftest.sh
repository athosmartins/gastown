#!/usr/bin/env bash
# gate-e13-grace.selftest.sh — ga-ufskhy E13 (2026-10-07): a review that is still
# PROGRESSING is not killed at its verdict budget; Phase C waits a bounded grace.
#
# Measured before the change (quality-gate-dispatcher.log): 6/6 timeouts of 07/10
# fired while the pending reviewer was state=active (2–3 timeouts/day until 02/10,
# 5–12/day from 03/10); each one closed the verdict bead as TIMEOUT, re-queued the
# marker (no-eval) and the next run reviewed the same branch from zero with the same
# budget — wa-affr0 timed out 4 times in 5 days.
#
# Three pure functions (quality-gate-guard.sh) are tested in isolation, then the
# LIVE Phase C decision block is extracted VERBATIM (SELFTEST-EXTRACT markers, the
# convention of gate-uk0km5-phase-c-wait-reason.selftest.sh) and run under the
# host's /bin/bash with `set -euo pipefail` against stubbed bd/gc, so the thing
# proven is the dispatcher's own branch order, not a re-implementation.
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
REAL_BASH="${REAL_BASH:-/bin/bash}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got '$2', want '$3'"; fi; }
has() { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1 — '$3' not in $(basename "$2")"; fi; }
hasnt() { if grep -qF -- "$3" "$2"; then bad "$1 — '$3' IS in $(basename "$2")"; else ok "$1"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/e13.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

extract_block() {
  sed -n "/# SELFTEST-EXTRACT $2: BEGIN/,/# SELFTEST-EXTRACT $2: END/p" "$1" | sed '1d;$d'
}
FN_ISO="$(extract_block "$GUARD" "gate-iso-to-epoch-fn")"
FN_PROG="$(extract_block "$GUARD" "reviewer-session-busy-fn")"
FN_GRACE="$(extract_block "$GUARD" "gate-e13-grace-secs-fn")"
FN_ANCHOR="$(extract_block "$GUARD" "gate-phase-c-anchor-fn")"
FN_ALIVE="$(extract_block "$GUARD" "reviewer-session-alive-fn")"
FN_CLOSED="$(extract_block "$DISPATCHER" "reviewer-session-confirmed-closed-fn")"
FN_CLASSIFY="$(extract_block "$DISPATCHER" "phase-c-closed-reviewer-classify-fn")"
FN_VBSA="$(extract_block "$DISPATCHER" "vb-status-action-fn")"
FN_EVENT="$(extract_block "$DISPATCHER" "gate-e13-event-fn")"
REHYDRATE="$(extract_block "$DISPATCHER" "phase-c-verdict-rehydrate")"
DECISION="$(extract_block "$DISPATCHER" "phase-c-verdict-decision")"
for v in FN_ISO FN_PROG FN_GRACE FN_ANCHOR FN_ALIVE FN_CLOSED FN_CLASSIFY FN_VBSA FN_EVENT REHYDRATE DECISION; do
  if [ -z "${!v}" ]; then echo "FATAL: could not extract $v — sentinel moved/renamed?" >&2; exit 2; fi
done
if printf '%s' "$DECISION" | grep -q 'E13 GRACE'; then ok "the live decision block carries the E13 grace branch"; else bad "the live decision block has no E13 grace branch"; fi

NOW=$(date +%s)
iso_utc()   { date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }
iso_local() { date -r "$1" '+%Y-%m-%dT%H:%M:%S%z' | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/'; }

echo "— gate_iso_to_epoch —"
eval "$FN_ISO"
eq "UTC Z form round-trips" "$(gate_iso_to_epoch "$(iso_utc "$NOW")")" "$NOW"
eq "local ±HH:MM form (how the roster prints last_active) gives the SAME instant" "$(gate_iso_to_epoch "$(iso_local "$NOW")")" "$NOW"
eq "fractional seconds are tolerated" "$(gate_iso_to_epoch "$(iso_utc "$NOW" | sed 's/Z$/.123456Z/')")" "$NOW"
eq "Go zero time is NOT a moment → empty" "$(gate_iso_to_epoch "0001-01-01T00:00:00Z")" ""
eq "empty → empty" "$(gate_iso_to_epoch "")" ""
eq "garbage → empty, never 0 or now" "$(gate_iso_to_epoch "ontem")" ""

echo "— reviewer_session_busy (mid-turn vs idle/frozen) —"
eval "$FN_PROG"
N="gate-reviewer-adhoc-e13aaaa"
roster() { # <state> <last_active> [closed]
  printf '{"sessions":[{"session_name":"%s","name":"%s","id":"ga-s1","state":"%s","closed":%s,"last_active":"%s"},{"session_name":"other","state":"active","closed":false,"last_active":"%s"}]}' \
    "$N" "$N" "$1" "${3:-false}" "$2" "$(iso_utc "$NOW")"
}
eq "active + last_active 60s ago → 1" "$(reviewer_session_busy "$N" "$(roster active "$(iso_local $((NOW-60)))")" "$NOW" 900)" "1"
eq "active + last_active exactly at max_idle → 1 (inclusive)" "$(reviewer_session_busy "$N" "$(roster active "$(iso_utc $((NOW-900)))")" "$NOW" 900)" "1"
eq "active + last_active 901s ago → 0 (stale is not progressing)" "$(reviewer_session_busy "$N" "$(roster active "$(iso_utc $((NOW-901)))")" "$NOW" 900)" "0"
eq "asleep + fresh → 0" "$(reviewer_session_busy "$N" "$(roster asleep "$(iso_utc $((NOW-10)))")" "$NOW" 900)" "0"
eq "closed=true + active + fresh → 0" "$(reviewer_session_busy "$N" "$(roster active "$(iso_utc $((NOW-10)))" true)" "$NOW" 900)" "0"
eq "zero-value last_active (never reported) → 0" "$(reviewer_session_busy "$N" "$(roster active "0001-01-01T00:00:00Z")" "$NOW" 900)" "0"
eq "unparseable last_active → 0, not 1" "$(reviewer_session_busy "$N" "$(roster active "agora")" "$NOW" 900)" "0"
eq "absent from the roster → 0" "$(reviewer_session_busy "nobody" "$(roster active "$(iso_utc "$NOW")")" "$NOW" 900)" "0"
eq "unparseable roster → 0" "$(reviewer_session_busy "$N" "{not json" "$NOW" 900)" "0"
eq "empty roster string → 0" "$(reviewer_session_busy "$N" "" "$NOW" 900)" "0"
eq "empty assignee → 0" "$(reviewer_session_busy "" "$(roster active "$(iso_utc "$NOW")")" "$NOW" 900)" "0"
eq "matched by alias field too" "$(reviewer_session_busy "ali" '{"sessions":[{"alias":"ali","state":"active","closed":false,"last_active":"'"$(iso_utc "$NOW")"'"}]}' "$NOW" 900)" "1"
eq "bare array roster shape" "$(reviewer_session_busy "$N" '[{"name":"'"$N"'","state":"active","closed":false,"last_active":"'"$(iso_utc "$NOW")"'"}]' "$NOW" 900)" "1"
eq "junk max_idle falls back to the 900 default (800s old → 1)" "$(reviewer_session_busy "$N" "$(roster active "$(iso_utc $((NOW-800)))")" "$NOW" banana)" "1"
eq "junk now falls back to the clock (60s old → 1)" "$(reviewer_session_busy "$N" "$(roster active "$(iso_utc $((NOW-60)))")" "x" 900)" "1"

echo "— gate_e13_grace_secs —"
eval "$FN_GRACE"
export GC_CITY="$WORK/city"; mkdir -p "$GC_CITY/.gc"
unset GATE_E13_GRACE GATE_E13_GRACE_MAX_SECS GATE_E13_OFF_FILE
eq "budget 1560 → grace 1560 (grace = budget below the ceiling)" "$(gate_e13_grace_secs 1560)" "1560"
eq "budget 3000 → grace 1800 (ceiling)" "$(gate_e13_grace_secs 3000)" "1800"
eq "budget 1800 → 1800" "$(gate_e13_grace_secs 1800)" "1800"
eq "junk budget → 0" "$(gate_e13_grace_secs banana)" "0"
eq "GATE_E13_GRACE_MAX_SECS=600 caps" "$(GATE_E13_GRACE_MAX_SECS=600 gate_e13_grace_secs 3000)" "600"
eq "GATE_E13_GRACE=0 → 0" "$(GATE_E13_GRACE=0 gate_e13_grace_secs 3000)" "0"
eq "GATE_E13_GRACE=junk → still on (only a literal 0 is off)" "$(GATE_E13_GRACE=off gate_e13_grace_secs 3000)" "1800"
touch "$GC_CITY/.gc/gate-e13-grace.off"
eq "kill file \$GC_CITY/.gc/gate-e13-grace.off → 0" "$(gate_e13_grace_secs 3000)" "0"
rm -f "$GC_CITY/.gc/gate-e13-grace.off"
eq "kill file removed → back on" "$(gate_e13_grace_secs 3000)" "1800"
eq "ceiling: budget 3000 + grace never passes 4800 (room 1800)" "$(gate_e13_grace_secs 3000)" "1800"
eq "ceiling: budget 3600 → grace 1200 (room to 4800), not 1800" "$(gate_e13_grace_secs 3600)" "1200"
eq "ceiling: budget 4800 → 0 (already at the ceiling)" "$(gate_e13_grace_secs 4800)" "0"
eq "ceiling: budget 7200 (heavy-selftest floor) → 0, never negative" "$(gate_e13_grace_secs 7200)" "0"
eq "GATE_E13_CEILING_SECS=3600 clamps: budget 3000 → 600" "$(GATE_E13_CEILING_SECS=3600 gate_e13_grace_secs 3000)" "600"
eq "GATE_RUN_TTL_MINUTES=60 → ceiling (60-10)*60=3000 → budget 3000 gets 0" "$(GATE_RUN_TTL_MINUTES=60 gate_e13_grace_secs 3000)" "0"
eq "GATE_RUN_TTL_MINUTES=90 → ceiling 4800 (same as default)" "$(GATE_RUN_TTL_MINUTES=90 gate_e13_grace_secs 3000)" "1800"
eq "GATE_RUN_TTL_MINUTES=junk → ignored" "$(GATE_RUN_TTL_MINUTES=abc gate_e13_grace_secs 3000)" "1800"
eq "GATE_RUN_TTL_MINUTES=200 → the 4800 ceiling still binds" "$(GATE_RUN_TTL_MINUTES=200 gate_e13_grace_secs 3000)" "1800"
eq "spent-before offset 300 → room shrinks: budget 3000 → 1500" "$(gate_e13_grace_secs 3000 300)" "1500"
eq "spent-before offset eats all room: budget 3000, spent 1800 → 0" "$(gate_e13_grace_secs 3000 1800)" "0"
eq "spent-before junk → ignored" "$(gate_e13_grace_secs 3000 abc)" "1800"
eq "spent-before with a small budget: 1560 + 600 spent → min(1560, 4800-1560-600=2640) = 1560" "$(gate_e13_grace_secs 1560 600)" "1560"

echo "— gate_phase_c_anchor (where the budget clock starts) —"
eval "$FN_ANCHOR"
eq "task-sent between start and now → anchor=task-sent with the offset" "$(gate_phase_c_anchor 1000 1153 2000)" "1153 153 task-sent"
eq "task-sent missing → created, 0" "$(gate_phase_c_anchor 1000 "" 2000)" "1000 0 created"
eq "task-sent junk → created, 0" "$(gate_phase_c_anchor 1000 ontem 2000)" "1000 0 created"
eq "task-sent before start (clock skew / wrong label) → created, 0" "$(gate_phase_c_anchor 1000 900 2000)" "1000 0 created"
eq "task-sent in the future → created, 0" "$(gate_phase_c_anchor 1000 2500 2000)" "1000 0 created"
eq "task-sent == start → task-sent, 0" "$(gate_phase_c_anchor 1000 1000 2000)" "1000 0 task-sent"
eq "junk start → 0 start, created" "$(gate_phase_c_anchor x "" 2000)" "0 0 created"

echo "— the LIVE Phase C decision block —"
VB1='{"id":"ga-vb1","status":"open","assignee":"'"$N"'","labels":["gate-run:ga-run1","reviewer-index:1","type:quality-gate-verdict","verdict:pending"],"metadata":{"gc.session_name":"'"$N"'"}}'
N2="gate-reviewer-adhoc-e13bbbb"
VB2='{"id":"ga-vb2","status":"open","assignee":"'"$N2"'","labels":["gate-run:ga-run1","reviewer-index:2","type:quality-gate-verdict","verdict:pending"],"metadata":{"gc.session_name":"'"$N2"'"}}'
roster2() { # <state1> <last_active1> <state2> <last_active2>  (N first, N2 second)
  printf '{"sessions":[{"session_name":"%s","name":"%s","id":"ga-s1","state":"%s","closed":false,"last_active":"%s"},{"session_name":"%s","name":"%s","id":"ga-s2","state":"%s","closed":false,"last_active":"%s"}]}' \
    "$N" "$N" "$1" "$2" "$N2" "$N2" "$3" "$4"
}
# run_case <elapsed> <roster json or empty=unreadable>  → $WORK/case.log, $WORK/case.out ; env: GATE_E13_GRACE, GATE_E13_OFF_FILE, GATE_E13_MAX_IDLE_SECS pass through
run_case() {
  local f="$WORK/case.sh"
  cat > "$f" <<'COMMON'
set -euo pipefail
GATE_RUN_ID="ga-run1"; BRANCH="crew/wa-worker/wa-e13test"
PC_TIMEOUT_MIN=50; PC_TIMEOUT_SECS=3000
GATE_E5_LIB_OK=0; GATE_E5_EXTRA_SEEN=0
: "${LOG:?}"; : "${GC_CITY:?}"
bd() {
  case " $* " in
    *" list "*) printf '%s' "$VBS_JSON"; return 0 ;;
    *" show "*) case " $* " in *" ga-vb2 "*) printf '[%s]' "${VB_SHOW_2:-}" ;; *) printf '[%s]' "$VB_SHOW_1" ;; esac; return 0 ;;
    *" query "*) printf '[]'; return 0 ;;
    *) echo "bd:$*" >> "$LOG"; return 0 ;;
  esac
}
gc_json_or_unknown() { printf '%s' "${SESS_JSON-}"; return 0; }
log()  { echo "log:$*" >> "$LOG"; }
warn() { echo "warn:$*" >> "$LOG"; }
gate_collect_verdicts() { :; }
gate_finalize_run() { echo "finalize_called:QUOTA_REQUEUE=${QUOTA_REQUEUE}:REQUEUE_REASON=${REQUEUE_REASON}:OVERALL=${OVERALL_VERDICT:-unset}" >> "$LOG"; }
gate_quota_limited() { printf ''; }
gate_quota_stop_verdict() { printf 'proceed'; }
close_gate_verdict() { echo "close_gate_verdict:$1" >> "$LOG"; return 0; }
_ts_to_epoch() { date +%s; }
QUOTA_REQUEUE=0; REQUEUE_REASON="quota"; OVERALL_VERDICT=""; FAIL_REASONS=""; ANY_FAIL=0
GATE_COLLECT_JUDGED_FAILS="${JUDGED_FAILS_V:-0}"
COMMON
  {
    printf '%s\n' "$FN_ISO" "$FN_PROG" "$FN_GRACE" "$FN_ALIVE" "$FN_CLOSED" "$FN_CLASSIFY" "$FN_VBSA" "$FN_EVENT"
    echo 'for _dummy in 1; do'
    echo 'GATE_RUN_ID="ga-run1"'
    printf '%s\n' "$REHYDRATE"
    echo 'done'
    echo "REQUIRED_REVIEWERS=\${#VERDICT_BEAD_IDS[@]}; VERDICTS_RECEIVED=0; ANY_FAIL=0; PC_ELAPSED=$1"
    echo 'for _dummy in 1; do'
    printf '%s\n' "$DECISION"
    echo 'done'
    echo 'echo REACHED_END >> "$LOG"'
  } >> "$f"
  : > "$WORK/case.log"
  local vbs="[$VB1]"; [ "${3:-}" = "two" ] && vbs="[$VB1,$VB2]"
  VBS_JSON="$vbs" VB_SHOW_1="$VB1" VB_SHOW_2="$VB2" SESS_JSON="$2" LOG="$WORK/case.log" "$REAL_BASH" "$f" >"$WORK/case.out" 2>&1
  echo "rc=$?" >> "$WORK/case.log"
  if [ "${E13_DEBUG:-0}" = "1" ]; then { echo "---- case.log"; cat "$WORK/case.log"; echo "---- case.out (tail)"; tail -15 "$WORK/case.out"; } >&2; fi
}
show_out() { echo "    --- case.out (tail) ---"; tail -5 "$WORK/case.out" | sed 's/^/    /'; }

echo "  · C1: 3100s elapsed of a 3000s budget, reviewer active + progressed 60s ago → GRACE, nothing finalized"
run_case 3100 "$(roster active "$(iso_local $((NOW-60)))")"
has   "C1 logs the grace with the ceiling" "$WORK/case.log" "E13 GRACE: waiting up to 1700s more (ceiling 4800s)"
hasnt "C1 does not time the run out" "$WORK/case.log" "TIMED OUT after"
hasnt "C1 does not finalize (no FAIL, no requeue)" "$WORK/case.log" "finalize_called"
hasnt "C1 does not close the verdict bead" "$WORK/case.log" "close_gate_verdict"
has   "C1 block ran to its end" "$WORK/case.log" "REACHED_END"
grep -q "REACHED_END" "$WORK/case.log" || show_out

echo "  · C2: 4801s elapsed (past budget + grace ceiling), same progressing reviewer → TIMED OUT as before, the record says why"
run_case 4801 "$(roster active "$(iso_local $((NOW-60)))")"
has "C2 times out past the ceiling" "$WORK/case.log" "TIMED OUT after 4801s (limit=3000s, grace=1800s, busy=1, judged_fails=0, anchor=created)"
hasnt "C2 no grace line" "$WORK/case.log" "E13 GRACE"
has "C2 finalizes as FAIL (today's path, unchanged)" "$WORK/case.log" "finalize_called:QUOTA_REQUEUE=0:REQUEUE_REASON=quota:OVERALL=FAIL"
grep -q "finalize_called" "$WORK/case.log" || show_out

echo "  · C3: 3100s, reviewer active but silent for 2000s → no grace (alive is not progressing)"
run_case 3100 "$(roster active "$(iso_utc $((NOW-2000)))")"
has "C3 times out with progressing=0" "$WORK/case.log" "TIMED OUT after 3100s (limit=3000s, grace=1800s, busy=0, judged_fails=0, anchor=created)"
hasnt "C3 no grace" "$WORK/case.log" "E13 GRACE"

echo "  · C4: 3100s, reviewer asleep + fresh last_active → no grace"
run_case 3100 "$(roster asleep "$(iso_utc $((NOW-10)))")"
has "C4 times out, progressing=0" "$WORK/case.log" "busy=0, judged_fails=0, anchor=created) with 0/1 verdicts. Treating as FAIL."

echo "  · C5: 3100s, progressing, but the kill file exists → grace=0, times out"
touch "$GC_CITY/.gc/gate-e13-grace.off"
run_case 3100 "$(roster active "$(iso_utc $((NOW-60)))")"
rm -f "$GC_CITY/.gc/gate-e13-grace.off"
has "C5 kill file: grace=0 in the record" "$WORK/case.log" "TIMED OUT after 3100s (limit=3000s, grace=off, busy=1, judged_fails=0, anchor=created)"
hasnt "C5 no grace line" "$WORK/case.log" "E13 GRACE"

echo "  · C6: 3100s, progressing, GATE_E13_GRACE=0 → times out"
GATE_E13_GRACE=0 run_case 3100 "$(roster active "$(iso_utc $((NOW-60)))")"
has "C6 env off: grace=0" "$WORK/case.log" "grace=off, busy=1"

echo "  · C7: 3100s, roster unreadable → unknown is not progressing → times out (today's path), with the existing warning"
run_case 3100 ""
has "C7 the existing unreadable-roster warning fires" "$WORK/case.log" "gc session list unreadable this sweep"
has "C7 times out, busy=unknown (the check could not run — never printed as 0)" "$WORK/case.log" "grace=1800s, busy=unknown:roster-unreadable"
hasnt "C7 no grace on unknown" "$WORK/case.log" "E13 GRACE"

echo "  · C8: 3100s, reviewer absent from a readable roster → dead-reviewer requeue, exactly as before"
run_case 3100 '{"sessions":[{"session_name":"other","state":"active","closed":false,"last_active":"'"$(iso_utc "$NOW")"'"}]}'
has "C8 infra requeue path untouched" "$WORK/case.log" "finalize_called:QUOTA_REQUEUE=1:REQUEUE_REASON=dead-reviewer"
hasnt "C8 no grace for a dead reviewer" "$WORK/case.log" "E13 GRACE"

echo "  · C9: GATE_E13_GRACE=junk → warned, treated as ON"
GATE_E13_GRACE=maybe run_case 3100 "$(roster active "$(iso_utc $((NOW-60)))")"
has "C9 junk is named" "$WORK/case.log" "GATE_E13_GRACE='maybe' is not 0/1 — treated as ON"
has "C9 grace still applies" "$WORK/case.log" "E13 GRACE"

echo "  · C10: GATE_E13_MAX_IDLE_SECS=30 with a reviewer 60s silent → not progressing under the operator's stricter bar"
GATE_E13_MAX_IDLE_SECS=30 run_case 3100 "$(roster active "$(iso_utc $((NOW-60)))")"
has "C10 the stricter idle bar is honored" "$WORK/case.log" "busy=0, judged_fails=0, anchor=created) with 0/1 verdicts"

echo "  · C11: within budget (2900s) nothing changes — the still-in-flight line, no grace line"
run_case 2900 "$(roster active "$(iso_utc $((NOW-60)))")"
has "C11 still in flight" "$WORK/case.log" "still in flight (0/1 verdicts, 2900s/3000s, anchor=created)"
hasnt "C11 no grace line inside the budget" "$WORK/case.log" "E13 GRACE"

echo "  · C12: two reviewers, the FIRST alive-but-idle (2000s silent), the SECOND busy → grace (the scan does not stop at the first live one)"
run_case 3100 "$(roster2 active "$(iso_utc $((NOW-2000)))" active "$(iso_utc $((NOW-30)))")" two
has "C12 grace granted on the second reviewer" "$WORK/case.log" "reviewer $N2 is busy (mid-turn"
has "C12 grace line" "$WORK/case.log" "E13 GRACE"
hasnt "C12 no timeout" "$WORK/case.log" "TIMED OUT after"

echo "  · C13: busy reviewer but a judged FAIL is already in → no grace (waiting cannot change the outcome)"
JUDGED_FAILS_V=1 run_case 3100 "$(roster active "$(iso_utc $((NOW-60)))")"
has "C13 times out at the budget with the reason in the record" "$WORK/case.log" "TIMED OUT after 3100s (limit=3000s, grace=1800s, busy=1, judged_fails=1, anchor=created)"
hasnt "C13 no grace" "$WORK/case.log" "E13 GRACE"
has "C13 the wait text is the plain budget (no grace was granted)" "$WORK/case.log" "did not complete within 50 minutes"

echo "  · C14: exactly at the ceiling (4800s) → still grace (inclusive), 0s more"
run_case 4800 "$(roster active "$(iso_utc $((NOW-60)))")"
has "C14 inclusive ceiling" "$WORK/case.log" "E13 GRACE: waiting up to 0s more (ceiling 4800s)"

echo "  · C15: GATE_RUN_TTL_MINUTES=60 → the guard would abort the run at 60 min → grace 0 at a 3000s budget"
GATE_RUN_TTL_MINUTES=60 run_case 3100 "$(roster active "$(iso_utc $((NOW-60)))")"
has "C15 clamped grace is 0s and named as such (not 'off')" "$WORK/case.log" "grace=0s, busy=1, judged_fails=0"
hasnt "C15 no grace" "$WORK/case.log" "E13 GRACE"

echo "  · C16: the E13 ledger — grace and exhausted outcome are written to \$GC_CITY/.gc/gate-e13.jsonl"
rm -f "$GC_CITY/.gc/gate-e13.jsonl"
run_case 3100 "$(roster active "$(iso_utc $((NOW-60)))")"
eq "C16 one e13_grace row for the run" "$(grep -c '"event":"e13_grace","outcome":"","run":"ga-run1"' "$GC_CITY/.gc/gate-e13.jsonl" 2>/dev/null)" "1"
run_case 4801 "$(roster active "$(iso_utc $((NOW-60)))")"
eq "C16 one grace-exhausted outcome row" "$(grep -c '"event":"e13_outcome","outcome":"grace-exhausted","run":"ga-run1"' "$GC_CITY/.gc/gate-e13.jsonl" 2>/dev/null)" "1"
has "C16 the exhausted wait text names budget + grace" "$WORK/case.log" "did not complete within 50 minutes + 30 min E13 grace"
if jq -e . "$GC_CITY/.gc/gate-e13.jsonl" >/dev/null 2>&1; then ok "C16 every ledger row is valid JSON"; else bad "C16 ledger has an invalid JSON row"; fi

echo
echo "== gate-e13-grace.selftest: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
