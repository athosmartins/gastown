#!/usr/bin/env bash
# gate-peb71d-phase-c-primary-dead.selftest.sh (ga-peb71d)
#
# Proves two decisions of Phase C of quality-gate-dispatcher.sh, both approved by the
# Mayor on 02/10 (bead ga-peb71d):
#
#   ITEM 1  A PRIMARY reviewer slot whose session is CONFIRMED CLOSED (present with
#           .closed==true, or absent from the roster with its session bead closed)
#           re-queues the run on the first sweep, whatever its sibling slot is doing.
#           Run ga-jb52od (02/10, reboot 08:40): slot 1 (primary) confirmed dead, slot 2
#           (E5 extra) alive under a re-created session of the same name; the check wanted
#           EVERY pending slot closed, so the run waited the full 3000 s for nothing: a dead
#           primary never delivers, so the run can never reach REQUIRED_REVIEWERS, and if the
#           live sibling does deliver the run is re-queued dead-reviewer anyway.
#           The mirror image does NOT re-queue: an E5 extra that is dead is only RETIRED
#           (gate_e5_phase_c_hook), never a reason to throw the run away ("an extra never
#           makes the run worse than arm A"). So a dead extra, however the death shows, must
#           not trigger the re-queue, and must not hide a dead primary either.
#
#   ITEM 2  A pending reviewer that cannot be NAMED (verdict bead assignee and
#           metadata.gc.session_name both empty) is "do not know", not "dead". The timeout
#           classifier used to hand "" to reviewer_session_alive, which answers 0, so a
#           live reviewer with a lost identity was re-queued as dead-reviewer. It now falls
#           to TIMED OUT like the __UNKNOWN__ capture does (ga-i5s5).
#
# Strategy (this repo's SELFTEST-EXTRACT convention, see gate-s4potx-reviewer-closed-fast-
# requeue.selftest.sh): extract the live "phase-c-verdict-decision" block and the classify
# functions from the dispatcher, plus the real reviewer_session_alive from the guard, and
# run them verbatim under the host's /bin/bash with `set -euo pipefail` and bd/gc/warn/log/
# gate_finalize_run stubbed. The E5 hook half (retiring an extra that is ABSENT with a
# closed session bead) is proven in gate-e5-second-reviewer.selftest.sh.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
GUARD="$SELF_DIR/quality-gate-guard.sh"
REAL_BASH="/bin/bash"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-peb71d-phase-c-primary-dead.selftest =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -f "$GUARD" ] || { echo "FATAL: guard not found at $GUARD" >&2; exit 2; }
[ -x "$REAL_BASH" ] || { echo "FATAL: $REAL_BASH not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/peb71d-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

extract_block() {
  sed -n "/# SELFTEST-EXTRACT $2: BEGIN/,/# SELFTEST-EXTRACT $2: END/p" "$1" | sed '1d;$d'
}

FN_CLOSED="$(extract_block "$DISPATCHER" "reviewer-session-confirmed-closed-fn")"
FN_CLASSIFY="$(extract_block "$DISPATCHER" "phase-c-closed-reviewer-classify-fn")"
DECISION="$(extract_block "$DISPATCHER" "phase-c-verdict-decision")"
FN_ALIVE="$(extract_block "$GUARD" "reviewer-session-alive-fn")"
if [ -z "$FN_CLOSED" ] || [ -z "$FN_CLASSIFY" ] || [ -z "$DECISION" ] || [ -z "$FN_ALIVE" ]; then
  echo "FATAL: could not extract blocks (closed=${#FN_CLOSED} classify=${#FN_CLASSIFY} decision=${#DECISION} alive=${#FN_ALIVE}) — sentinel moved?" >&2
  exit 2
fi

# bd stub: `bd -C <city> show vb-N --json` -> {"status":"$VBN_STATUS","labels":$VBN_LABELS}
#          `bd -C <city> query --json "<expr>"` -> $CLOSED_OUT (status=closed) / $OPEN_OUT (status!=closed)
write_common() {  # write_common <file>
  cat > "$1" <<'COMMON'
set -euo pipefail
GC_CITY="/fake/city"; GATE_RUN_ID="test-run-1"; BRANCH="fake-branch"
PC_TIMEOUT_MIN=50
: "${LOG:?}"
bd() {
  case " $* " in
    *" query "*)
      local expr="" a
      for a in "$@"; do case "$a" in type=session*) expr="$a" ;; esac; done
      echo "bdquery:$expr" >> "$LOG"
      case "$expr" in
        *"status!=closed"*) printf '%s' "${OPEN_OUT-[]}"; return 0 ;;
        *"status=closed"*)  printf '%s' "${CLOSED_OUT-[]}"; return 0 ;;
      esac
      return 1 ;;
    *" show vb-1 "*) echo "{\"status\":\"${VB1_STATUS:-open}\",\"labels\":${VB1_LABELS:-[]}}"; return 0 ;;
    *" show vb-2 "*) echo "{\"status\":\"${VB2_STATUS:-open}\",\"labels\":${VB2_LABELS:-[]}}"; return 0 ;;
  esac
  echo "bd:$*" >> "$LOG"; return 0
}
gc_json_or_unknown() { printf '%s' "${SESS_JSON-}"; return 0; }
warn() { echo "warn:$*" >> "$LOG"; }
log()  { echo "log:$*" >> "$LOG"; }
gate_quota_limited() { echo 0; }
gate_quota_stop_verdict() { echo none; }
vb_status_action() { case "$1" in closed) echo skip ;; __UNKNOWN__) echo unknown ;; *) echo requeue ;; esac; }
close_gate_verdict() { return 0; }
gate_finalize_run() {
  echo "finalize_called:QUOTA_REQUEUE=${QUOTA_REQUEUE}:REQUEUE_REASON=${REQUEUE_REASON}:OVERALL_VERDICT=${OVERALL_VERDICT:-unset}" >> "$LOG"
}
QUOTA_REQUEUE=0; REQUEUE_REASON="quota"
COMMON
}

# run_decision <sid-of-slot-1> [<sid-of-slot-2>] -> runs the live decision block over 1 or 2 slots.
# Env (pass inline): SESS_JSON CLOSED_OUT OPEN_OUT VB1_STATUS VB2_STATUS VB1_LABELS VB2_LABELS
#                    PC_ELAPSED_V (default 60) REQ_V VR_V
run_decision() {
  local f="$WORK/dec.sh" n=0 s vbs="" sidlines=""
  for s in "$@"; do n=$((n+1)); vbs="$vbs vb-$n"; sidlines="${sidlines}SESSION_IDS+=('$s')"$'\n'; done
  write_common "$f"
  {
    echo "REQUIRED_REVIEWERS=\${REQ_V:-$n}; PC_TIMEOUT_SECS=3000; VERDICTS_RECEIVED=\${VR_V:-0}; ANY_FAIL=0"
    echo "PC_ELAPSED=\"\${PC_ELAPSED_V-60}\""
    echo "VERDICT_BEAD_IDS=($vbs); SESSION_IDS=()"
    printf '%s' "$sidlines"
    printf '%s\n' "$FN_CLOSED" "$FN_CLASSIFY" "$FN_ALIVE"
    echo 'for _dummy in 1; do'
    printf '%s\n' "$DECISION"
    echo 'done'
    echo 'echo REACHED_END >> "$LOG"'
  } >> "$f"
  : > "$WORK/dec.log"
  LOG="$WORK/dec.log" "$REAL_BASH" "$f" >"$WORK/dec.out" 2>&1
  return $?
}

requeued()  { grep -q "^finalize_called:QUOTA_REQUEUE=1:REQUEUE_REASON=dead-reviewer" "$WORK/dec.log"; }
finalized() { grep -q "^finalize_called:" "$WORK/dec.log"; }
dump()      { tr '\n' ';' < "$WORK/dec.log"; }
reached()   { grep -q '^REACHED_END' "$WORK/dec.log"; }

P="gate-reviewer-adhoc-p1"; X="gate-reviewer-adhoc-x2"
EXTRA='["e5-extra"]'
R_P_CLOSED_X_ALIVE='{"sessions":[{"session_name":"'$P'","closed":true,"state":"asleep"},{"session_name":"'$X'","closed":false,"state":"active"}]}'
R_P_ABSENT_X_ALIVE='{"sessions":[{"session_name":"'$X'","closed":false,"state":"active"}]}'
R_P_ALIVE_X_CLOSED='{"sessions":[{"session_name":"'$P'","closed":false,"state":"active"},{"session_name":"'$X'","closed":true,"state":"asleep"}]}'
R_P_ALIVE_X_ABSENT='{"sessions":[{"session_name":"'$P'","closed":false,"state":"active"}]}'
R_X_CLOSED_ONLY='{"sessions":[{"session_name":"'$X'","closed":true,"state":"asleep"}]}'
R_NONE='{"sessions":[]}'
BEAD_P_CLOSED='[{"id":"ga-wisp-p","status":"closed","metadata":{"session_name":"'$P'"}}]'
BEAD_X_CLOSED='[{"id":"ga-wisp-x","status":"closed","metadata":{"session_name":"'$X'"}}]'

echo "── 1. ITEM 1, THE BUG: primary CONFIRMED CLOSED (present, closed=true) + extra alive -> re-queue on the 1st sweep ──"
SESS_JSON="$R_P_CLOSED_X_ALIVE" VB2_LABELS="$EXTRA" run_decision "$P" "$X"
RC=$?
[ "$RC" -eq 0 ] && reached && ok "block runs to the end (rc 0)" || bad "block rc=$RC: $(tr '\n' ';' < "$WORK/dec.out") $(dump)"
requeued && ok "re-queued dead-reviewer with the extra still alive (elapsed 60s << 3000s) — THIS IS THE FIX" \
         || bad "run left waiting for the live extra although its primary is confirmed closed: $(dump)"

echo "── 2. ITEM 1, the 02/10 incident shape: primary ABSENT from the roster, session bead closed, extra alive -> re-queue ──"
SESS_JSON="$R_P_ABSENT_X_ALIVE" CLOSED_OUT="$BEAD_P_CLOSED" OPEN_OUT='[]' VB2_LABELS="$EXTRA" run_decision "$P" "$X"
requeued && ok "re-queued (absent + bead closed counts as confirmed closed for a primary)" \
         || bad "incident shape left waiting: $(dump)"

echo "── 3. two PRIMARY slots (no extra label at all), one confirmed closed, the other alive -> re-queue ──"
SESS_JSON="$R_P_CLOSED_X_ALIVE" run_decision "$P" "$X"
requeued && ok "re-queued: a dead primary dooms the run whatever the sibling is (the run can never reach REQUIRED)" \
         || bad "a normal 2-reviewer run waited with one primary confirmed closed: $(dump)"

echo "── 4. MIRROR IMAGE: primary alive, extra confirmed closed -> NO re-queue (a dead extra is only retired) ──"
SESS_JSON="$R_P_ALIVE_X_CLOSED" VB2_LABELS="$EXTRA" run_decision "$P" "$X"
finalized && bad "re-queued the run because of a dead extra: $(dump)" || ok "left in flight, no finalize"

echo "── 5. MIRROR IMAGE: primary alive, extra ABSENT with its session bead closed -> NO re-queue ──"
SESS_JSON="$R_P_ALIVE_X_ABSENT" CLOSED_OUT="$BEAD_X_CLOSED" OPEN_OUT='[]' VB2_LABELS="$EXTRA" run_decision "$P" "$X"
finalized && bad "re-queued the run because of an absent+closed extra: $(dump)" || ok "left in flight, no finalize"

echo "── 6. primary already DELIVERED (bead closed), only the extra pending and ABSENT+closed -> NO re-queue ──"
# Before the fix this re-queued: with the delivered primary skipped, the extra was the only pending slot and
# "all pending closed" was true. The extra's retirement (E5 hook) is what ends this run, never a re-queue.
SESS_JSON="$R_NONE" CLOSED_OUT="$BEAD_X_CLOSED" OPEN_OUT='[]' VB1_STATUS=closed VB2_LABELS="$EXTRA" REQ_V=2 VR_V=1 run_decision "$P" "$X"
finalized && bad "re-queued a run whose primary delivered, because its extra is dead: $(dump)" || ok "left in flight, no finalize"

echo "── 7. same, the extra PRESENT with closed=true (the case the hook retires) -> NO re-queue from this check either ──"
SESS_JSON="$R_X_CLOSED_ONLY" VB1_STATUS=closed VB2_LABELS="$EXTRA" REQ_V=2 VR_V=1 run_decision "$P" "$X"
finalized && bad "re-queued a run whose primary delivered, because its extra's session is closed: $(dump)" || ok "left in flight, no finalize"

echo "── 8. primary AND extra both confirmed closed -> re-queue (the primary decides) ──"
SESS_JSON='{"sessions":[{"session_name":"'$P'","closed":true},{"session_name":"'$X'","closed":true}]}' VB2_LABELS="$EXTRA" run_decision "$P" "$X"
requeued && ok "re-queued" || bad "both dead but not re-queued: $(dump)"

echo "── 9. NON-REGRESSION: both alive -> wait; the roster unreadable -> wait ──"
SESS_JSON='{"sessions":[{"session_name":"'$P'","closed":false,"state":"active"},{"session_name":"'$X'","closed":false,"state":"active"}]}' VB2_LABELS="$EXTRA" run_decision "$P" "$X"
finalized && bad "re-queued two live reviewers: $(dump)" || ok "both alive: left in flight"
SESS_JSON='' VB2_LABELS="$EXTRA" run_decision "$P" "$X"
finalized && bad "acted on an unreadable roster: $(dump)" || ok "roster unreadable: left in flight (error is not 'dead')"

echo "── 10. NON-REGRESSION: a primary absent with NO session bead found (still start-pending) + extra alive -> wait ──"
SESS_JSON="$R_P_ABSENT_X_ALIVE" CLOSED_OUT='[]' OPEN_OUT='[]' VB2_LABELS="$EXTRA" run_decision "$P" "$X"
finalized && bad "re-queued a primary that merely has not been created yet (ga-wcd86): $(dump)" || ok "left in flight"

echo "── 11. ITEM 2: reviewer that cannot be NAMED (empty assignee and gc.session_name), run PAST its timeout -> TIMED OUT, never dead-reviewer ──"
SESS_JSON="$R_NONE" PC_ELAPSED_V=3100 run_decision ""
RC=$?
[ "$RC" -eq 0 ] && reached && ok "block runs to the end (rc 0)" || bad "block rc=$RC: $(tr '\n' ';' < "$WORK/dec.out") $(dump)"
if requeued; then
  bad "an unnameable reviewer was read as DEAD and the run re-queued dead-reviewer: $(dump)"
else
  ok "not re-queued as dead-reviewer"
fi
grep -q "TIMED OUT" "$WORK/dec.log" && grep -q "^finalize_called:QUOTA_REQUEUE=0:.*OVERALL_VERDICT=FAIL" "$WORK/dec.log" \
  && ok "falls to TIMED OUT (QUOTA_REQUEUE=0, OVERALL_VERDICT=FAIL), like an __UNKNOWN__ capture" \
  || bad "did not fall to TIMED OUT: $(dump)"

echo "── 12. ITEM 2, the reference: an __UNKNOWN__ capture at the timeout also ends TIMED OUT (the behaviour the empty name must match) ──"
SESS_JSON="$R_NONE" PC_ELAPSED_V=3100 run_decision "__UNKNOWN__"
requeued && bad "an __UNKNOWN__ reviewer was re-queued as dead: $(dump)" || ok "TIMED OUT, not re-queued"

echo "── 13. NON-REGRESSION: a nameable reviewer that is really gone, run past its timeout -> re-queue dead-reviewer (ga-eqjo) ──"
SESS_JSON="$R_NONE" PC_ELAPSED_V=3100 CLOSED_OUT='[]' OPEN_OUT='[]' run_decision "$P"
requeued && ok "re-queued: nameable + absent from the roster = dead at the timeout, as before" || bad "the ga-eqjo timeout re-queue is gone: $(dump)"

echo "── 14. NON-REGRESSION: the empty-name reviewer in a young run just waits ──"
SESS_JSON="$R_NONE" PC_ELAPSED_V=60 run_decision ""
finalized && bad "acted on an unnameable reviewer in a young run: $(dump)" || ok "left in flight"

echo ""
echo "== gate-peb71d-phase-c-primary-dead: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
