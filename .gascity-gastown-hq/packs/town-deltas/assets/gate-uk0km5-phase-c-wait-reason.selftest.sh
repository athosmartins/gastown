#!/usr/bin/env bash
# gate-uk0km5-phase-c-wait-reason.selftest.sh (ga-uk0km5)
#
# Proves, with the REAL shape of the 2026-10-02 reboot incident (run ga-jb52od):
#   1. a pending verdict bead whose ASSIGNEE the engine cleared but whose
#      metadata.gc.session_name still names a reviewer that is ABSENT from the
#      roster with a CLOSED session bead is classified dead on the FIRST sweep
#      (capture -> predicate, the two blocks run together, verbatim);
#   2. a run whose OTHER slot's reviewer is listed in the roster -- here a
#      session the engine RE-CREATED under the same name -- keeps waiting, and
#      says WHICH slot and WHICH reviewer holds it (it used to wait in silence);
#   3. every other "keep waiting" path of gate_phase_c_all_pending_closed names
#      its cause too: roster unreadable, verdict bead unreadable, capture
#      unreadable (__UNKNOWN__), reviewer not nameable at all, session bead
#      open / not found, and NO pending verdict bead with fewer verdicts than
#      required;
#   4. a LISTED reviewer's line carries the roster's .state and never calls the
#      session "alive": a listed session can be drained / quarantined /
#      failed-create (dead states that only the run timeout classifies,
#      reviewer_session_alive), and this check reads .closed only.
#
# WHY THIS TEST EXISTS. ga-uk0km5 was filed reading that incident as "empty
# assignee -> `return 1` -> the dead reviewer is never classified". Run against
# the live artifacts, that is not what happened: slot 1 (ga-e7yxde) WAS
# classified closed (ga-8wec8c's capture fallback + ga-oj7bzs's session-bead
# lookup); the run was held by slot 2 (ga-5jn3qy, the E5 extra), whose name had
# been re-created by the engine and was alive in the roster. Both readings
# end in the same silent `return 1`, which is why the wrong one stood. Case 1
# is the regression guard for the half that already works (it FAILS if the
# capture falls back to nothing but .assignee -- see the mutation check in the
# commit message); cases 2-3 are what this bead adds.
#
# Behavior is unchanged: every case that waited still waits, every case that
# re-queued still re-queues. Only the log gains the reason.
#
# Strategy (this repo's SELFTEST-EXTRACT convention): extract the live blocks,
# run them verbatim under the host's /bin/bash (3.2) with `set -euo pipefail`,
# with bd/gc/log/warn/gate_collect_verdicts/gate_finalize_run stubbed.
#
# Exit 0 iff every assertion holds. DISPATCHER=<file> runs it against another
# copy of the dispatcher (used for the mutation checks).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${DISPATCHER:-$SELF_DIR/quality-gate-dispatcher.sh}"
REAL_BASH="/bin/bash"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-uk0km5-phase-c-wait-reason.selftest =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -x "$REAL_BASH" ] || { echo "FATAL: $REAL_BASH not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/uk0km5-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

extract_block() {
  sed -n "/# SELFTEST-EXTRACT $2: BEGIN/,/# SELFTEST-EXTRACT $2: END/p" "$1" | sed '1d;$d'
}

FN_CLOSED="$(extract_block "$DISPATCHER" "reviewer-session-confirmed-closed-fn")"
FN_CLASSIFY="$(extract_block "$DISPATCHER" "phase-c-closed-reviewer-classify-fn")"
REHYDRATE="$(extract_block "$DISPATCHER" "phase-c-verdict-rehydrate")"
DECISION="$(extract_block "$DISPATCHER" "phase-c-verdict-decision")"
if [ -z "$FN_CLOSED" ] || [ -z "$FN_CLASSIFY" ] || [ -z "$REHYDRATE" ] || [ -z "$DECISION" ]; then
  echo "FATAL: could not extract blocks (closed=${#FN_CLOSED} classify=${#FN_CLASSIFY} rehydrate=${#REHYDRATE} decision=${#DECISION}) — sentinel moved?" >&2
  exit 2
fi

# ── the incident, as the artifacts had it ───────────────────────────────────
N1="gate-reviewer-adhoc-18b226b636"   # slot 1: died in the reboot; absent from the roster; session bead closed
N2="gate-reviewer-adhoc-c877ccdadf"   # slot 2 (E5 extra): re-created by the engine under the same name; alive
VB1='{"id":"ga-e7yxde","status":"open","assignee":null,"labels":["gate-run:ga-jb52od","reviewer-index:1","type:quality-gate-verdict","verdict:pending"],"metadata":{"gc.session_name":"'"$N1"'"}}'
VB2='{"id":"ga-5jn3qy","status":"open","assignee":null,"labels":["e5-extra","gate-run:ga-jb52od","reviewer-index:2","type:quality-gate-verdict","verdict:pending"],"metadata":{"e5.session_id":"ga-wisp-keg2jr","e5.session_name":"'"$N2"'","gc.session_name":"'"$N2"'"}}'
VB1_EMPTY='{"id":"ga-e7yxde","status":"open","assignee":null,"labels":["gate-run:ga-jb52od","reviewer-index:1","type:quality-gate-verdict","verdict:pending"],"metadata":{"gc.work_dir":"/x"}}'
CLOSED_BEAD1='[{"id":"ga-wisp-2dhcni","status":"closed","metadata":{"session_name":"'"$N1"'","alias":"'"$N1"'","agent_name":"'"$N1"'"}}]'
OPEN_BEAD2='[{"id":"ga-99c4i4","status":"open","metadata":{"session_name":"'"$N2"'"}}]'
CLOSED_BEAD2='[{"id":"ga-wisp-keg2jr","status":"closed","metadata":{"session_name":"'"$N2"'"}}]'
ROSTER_BOTH_ALIVE_N2='{"sessions":[{"session_name":"'"$N2"'","id":"ga-99c4i4","state":"active","closed":false},{"session_name":"unrelated","closed":false}]}'
ROSTER_NEITHER='{"sessions":[{"session_name":"unrelated","closed":false}]}'

# run_case: run the live capture -> live predicate -> live decision, in that order.
#   env in:  VBS_JSON (array the list query answers), VB_SHOW_<n> (what `bd show` answers per id),
#            SHOW_FAIL_CAPTURE=1 (show fails while the capture runs, then recovers),
#            SHOW_FAIL_PREDICATE=1 (show works for the capture, then fails inside the predicate),
#            SESS_JSON (the roster; empty = unreadable), CLOSED_OUT/OPEN_OUT (session-bead queries),
#            REQUIRED_V (REQUIRED_REVIEWERS; default = the number of verdict beads)
#   out:     $WORK/case.log (log:/warn:/bdquery:/finalize_called: lines), $WORK/case.out (stdout+stderr)
run_case() {
  local f="$WORK/case.sh"
  cat > "$f" <<'COMMON'
set -euo pipefail
GC_CITY="/fake/city"; GATE_RUN_ID="ga-jb52od"; BRANCH="crew/wa-worker/wa-h3chme"
PC_TIMEOUT_MIN=50; PC_TIMEOUT_SECS=3000
GATE_E5_LIB_OK=0; GATE_E5_EXTRA_SEEN=0
: "${LOG:?}"
STATE_DIR="${STATE_DIR:?}"
bd() {
  case " $* " in
    *" query "*)
      local expr="" a
      for a in "$@"; do case "$a" in type=session*) expr="$a" ;; esac; done
      echo "bdquery:$expr" >> "$LOG"
      case "$expr" in
        *"status!=closed"*) printf '%s' "${OPEN_OUT-}"; return 0 ;;
        *"status=closed"*)  printf '%s' "${CLOSED_OUT-}"; return 0 ;;
      esac
      return 1 ;;
    *" list "*) printf '%s' "$VBS_JSON"; return 0 ;;
    *" show "*)
      local id="" a
      for a in "$@"; do case "$a" in ga-*) id="$a" ;; esac; done
      if [ -e "$STATE_DIR/capture_done" ]; then
        [ "${SHOW_FAIL_PREDICATE:-0}" = "1" ] && return 1
      else
        [ "${SHOW_FAIL_CAPTURE:-0}" = "1" ] && return 1
      fi
      case "$id" in
        ga-e7yxde) printf '[%s]' "$VB_SHOW_1" ;;
        ga-5jn3qy) printf '[%s]' "$VB_SHOW_2" ;;
        *) return 1 ;;
      esac
      return 0 ;;
  esac
  return 0
}
gc_json_or_unknown() { printf '%s' "${SESS_JSON-}"; return 0; }
log()  { echo "log:$*" >> "$LOG"; }
warn() { echo "warn:$*" >> "$LOG"; }
# gate_collect_verdicts is the last thing the capture block calls; the predicate runs after it.
gate_collect_verdicts() { : > "$STATE_DIR/capture_done"; }
gate_finalize_run() {
  echo "finalize_called:QUOTA_REQUEUE=${QUOTA_REQUEUE}:REQUEUE_REASON=${REQUEUE_REASON}" >> "$LOG"
}
_ts_to_epoch() { date +%s; }
QUOTA_REQUEUE=0; REQUEUE_REASON="quota"
COMMON
  {
    printf '%s\n' "$FN_CLOSED" "$FN_CLASSIFY"
    echo 'for _dummy in 1; do'
    # What Phase C has resolved before it rehydrates (the live block only reads them).
    echo 'GATE_RUN_ID="ga-jb52od"'
    printf '%s\n' "$REHYDRATE"
    echo 'done'
    echo 'REQUIRED_REVIEWERS=${REQUIRED_V:-${#VERDICT_BEAD_IDS[@]}}; VERDICTS_RECEIVED=0; ANY_FAIL=0; PC_ELAPSED=${PC_ELAPSED_V-2616}'
    echo 'for _dummy in 1; do'
    printf '%s\n' "$DECISION"
    echo 'done'
    echo 'echo "SESSION_IDS=${SESSION_IDS[*]}" >> "$LOG"'
    echo 'echo REACHED_END >> "$LOG"'
  } >> "$f"
  : > "$WORK/case.log"; rm -rf "$WORK/state"; mkdir -p "$WORK/state"
  LOG="$WORK/case.log" STATE_DIR="$WORK/state" "$REAL_BASH" "$f" >"$WORK/case.out" 2>&1
}

finalized()    { grep -q "^finalize_called:" "$WORK/case.log"; }
requeued()     { grep -q "^finalize_called:QUOTA_REQUEUE=1:REQUEUE_REASON=dead-reviewer" "$WORK/case.log"; }
has_line()     { grep -q "$1" "$WORK/case.log"; }
dump()         { tr '\n' ';' < "$WORK/case.log"; echo -n " out=$(tr '\n' ';' < "$WORK/case.out")"; }

echo "── 1. slot 1 alone: assignee cleared by the engine, metadata names the dead reviewer -> re-queue on the FIRST sweep ──"
VBS_JSON="[$VB1]" VB_SHOW_1="$VB1" VB_SHOW_2="$VB2" SESS_JSON="$ROSTER_NEITHER" CLOSED_OUT="$CLOSED_BEAD1" OPEN_OUT='[]' run_case
has_line "REACHED_END" && ok "block ran to the end" || bad "block aborted: $(dump)"
has_line "^SESSION_IDS=$N1\$" && ok "capture fell back from the empty assignee to metadata.gc.session_name ($N1)" || bad "capture did not name the reviewer: $(dump)"
requeued && ok "re-queued as dead-reviewer on the first sweep (elapsed 2616s << 3000s)" || bad "NOT re-queued: the dead reviewer was not classified: $(dump)"

echo "── 2. THE INCIDENT: slot 1 dead + slot 2's name re-created and alive -> wait, and say which slot holds the run ──"
VBS_JSON="[$VB1,$VB2]" VB_SHOW_1="$VB1" VB_SHOW_2="$VB2" SESS_JSON="$ROSTER_BOTH_ALIVE_N2" CLOSED_OUT="$CLOSED_BEAD1" OPEN_OUT="$OPEN_BEAD2" run_case
has_line "REACHED_END" && ok "block ran to the end" || bad "block aborted: $(dump)"
has_line "^SESSION_IDS=$N1 $N2\$" && ok "capture named both reviewers from metadata ($N1 $N2)" || bad "capture wrong: $(dump)"
finalized && bad "finalized a run with a live reviewer in the roster: $(dump)" || ok "left in flight (the live reviewer is not confirmed dead)"
has_line "^log:.*ga-5jn3qy's reviewer $N2 is in 'gc session list' with state 'active'.*ga-uk0km5" && ok "the wait names the holding slot (ga-5jn3qy), its reviewer ($N2) and the roster state ('active')" || bad "no reason naming the slot that holds the run: $(dump)"
has_line "ga-e7yxde.*ga-uk0km5" && bad "slot 1 (classified dead) was blamed for the wait: $(dump)" || ok "slot 1, already classified dead, is not blamed"
has_line "^bdquery:.*status=closed" && ok "the absent slot 1 was looked up through its session bead (ga-oj7bzs)" || bad "no session-bead lookup for the absent reviewer: $(dump)"

echo "── 3. reviewer not nameable: assignee AND metadata.gc.session_name empty (bead read fine) -> wait, and say it is not 'unreadable' ──"
VBS_JSON="[$VB1_EMPTY]" VB_SHOW_1="$VB1_EMPTY" VB_SHOW_2="$VB2" SESS_JSON="$ROSTER_NEITHER" CLOSED_OUT="$CLOSED_BEAD1" OPEN_OUT='[]' run_case
finalized && bad "finalized a run whose reviewer cannot be named: $(dump)" || ok "left in flight"
has_line "^warn:.*ga-e7yxde.*neither its assignee nor metadata.gc.session_name names a reviewer.*re-queued.*ga-uk0km5" && ok "warn names the bead, says the reviewer cannot be named, and says what the timeout concludes (re-queue)" || bad "silent / wrong reason for an unnameable reviewer: $(dump)"

echo "── 4. roster unreadable -> wait, and say so ──"
VBS_JSON="[$VB1]" VB_SHOW_1="$VB1" VB_SHOW_2="$VB2" SESS_JSON="" CLOSED_OUT="$CLOSED_BEAD1" OPEN_OUT='[]' run_case
finalized && bad "finalized on an unreadable roster: $(dump)" || ok "left in flight"
has_line "^warn:.*'gc session list' unreadable this sweep.*ga-uk0km5" && ok "warn says the roster was unreadable" || bad "unreadable roster was silent: $(dump)"

echo "── 5. verdict bead unreadable inside the predicate (capture was fine) -> wait, and say so ──"
VBS_JSON="[$VB1]" VB_SHOW_1="$VB1" VB_SHOW_2="$VB2" SHOW_FAIL_PREDICATE=1 SESS_JSON="$ROSTER_NEITHER" CLOSED_OUT="$CLOSED_BEAD1" OPEN_OUT='[]' run_case
finalized && bad "finalized on an unreadable verdict bead: $(dump)" || ok "left in flight"
has_line "^warn:.*verdict bead ga-e7yxde unreadable this sweep.*ga-uk0km5" && ok "warn names the unreadable verdict bead" || bad "unreadable verdict bead was silent: $(dump)"

echo "── 6. capture unreadable (bd show failed while the capture ran -> __UNKNOWN__) -> wait, and say so ──"
VBS_JSON="[$VB1]" VB_SHOW_1="$VB1" VB_SHOW_2="$VB2" SHOW_FAIL_CAPTURE=1 SESS_JSON="$ROSTER_NEITHER" CLOSED_OUT="$CLOSED_BEAD1" OPEN_OUT='[]' run_case
finalized && bad "finalized on an unreadable capture: $(dump)" || ok "left in flight"
has_line "^SESSION_IDS=__UNKNOWN__\$" && ok "capture recorded the __UNKNOWN__ sentinel" || bad "capture did not record __UNKNOWN__: $(dump)"
has_line "^warn:.*ga-e7yxde could not be read at the start of this sweep.*ga-uk0km5" && ok "warn names the unreadable capture" || bad "unreadable capture was silent: $(dump)"

echo "── 7. absent from the roster, session bead OPEN (new incarnation booting) / NOT FOUND (not created yet) -> wait, and say which ──"
VBS_JSON="[$VB1]" VB_SHOW_1="$VB1" VB_SHOW_2="$VB2" SESS_JSON="$ROSTER_NEITHER" CLOSED_OUT='[]' OPEN_OUT='[{"id":"ga-new1","status":"open","metadata":{"session_name":"'"$N1"'"}}]' run_case
finalized && bad "finalized while a live incarnation of the name exists: $(dump)" || ok "open bead: left in flight"
has_line "^log:.*ga-e7yxde's reviewer $N1 is absent.*session bead is 'open'.*ga-uk0km5" && ok "open bead: reason says the bead is 'open'" || bad "open bead: silent: $(dump)"
VBS_JSON="[$VB1]" VB_SHOW_1="$VB1" VB_SHOW_2="$VB2" SESS_JSON="$ROSTER_NEITHER" CLOSED_OUT='[]' OPEN_OUT='[]' run_case
finalized && bad "finalized a run whose reviewer has no session bead yet: $(dump)" || ok "notfound: left in flight"
has_line "^log:.*ga-e7yxde's reviewer $N1 is absent.*session bead is 'notfound'.*ga-uk0km5" && ok "notfound: reason says the bead is 'notfound'" || bad "notfound: silent: $(dump)"

echo "── 8. the dead slot's name re-used by a LIVE session must not be re-queued as dead (slot 1 itself listed) ──"
VBS_JSON="[$VB1]" VB_SHOW_1="$VB1" VB_SHOW_2="$VB2" SESS_JSON='{"sessions":[{"session_name":"'"$N1"'","id":"ga-new1","state":"active","closed":false}]}' CLOSED_OUT="$CLOSED_BEAD1" OPEN_OUT='[{"id":"ga-new1","status":"open","metadata":{"session_name":"'"$N1"'"}}]' run_case
finalized && bad "re-queued a run whose slot name is alive in the roster: $(dump)" || ok "left in flight"
has_line "^bdquery:" && bad "queried session beads for a reviewer that is present in the roster (needless per-sweep cost)" || ok "no session-bead query for a listed reviewer"

echo "── 9. listed but in a DEAD state (drained) / with no state field: the line says the state, never 'alive' ──"
for ST in drained quarantined failed-create; do
  VBS_JSON="[$VB1]" VB_SHOW_1="$VB1" VB_SHOW_2="$VB2" SESS_JSON='{"sessions":[{"session_name":"'"$N1"'","id":"ga-x9","state":"'"$ST"'","closed":false}]}' CLOSED_OUT="$CLOSED_BEAD1" OPEN_OUT='[]' run_case
  finalized && bad "$ST: finalized (this check reads .closed only; the timeout classifies a $ST session): $(dump)" || ok "$ST: left in flight (unchanged decision)"
  has_line "^log:.*ga-e7yxde's reviewer $N1 is in 'gc session list' with state '$ST'.*ga-uk0km5" && ok "$ST: the line carries state '$ST'" || bad "$ST: state missing from the line: $(dump)"
  grep -i "^log:.*ga-uk0km5" "$WORK/case.log" | grep -qi "alive" && bad "$ST: the line calls a $ST session alive: $(dump)" || ok "$ST: the line does not call it alive"
done
VBS_JSON="[$VB1]" VB_SHOW_1="$VB1" VB_SHOW_2="$VB2" SESS_JSON='{"sessions":[{"session_name":"'"$N1"'","id":"ga-x9","closed":false}]}' CLOSED_OUT="$CLOSED_BEAD1" OPEN_OUT='[]' run_case
has_line "^log:.*is in 'gc session list' with state 'none'" && ok "a roster row without .state reads 'none', not an empty gloss" || bad "no-state row: $(dump)"

echo "── 10. nothing pending but fewer verdicts than required -> wait, and say it with the counts (not silent, not 'all delivered') ──"
VB1_CLOSED='{"id":"ga-e7yxde","status":"closed","assignee":null,"labels":["gate-run:ga-jb52od","reviewer-index:1","type:quality-gate-verdict","verdict:pass"],"metadata":{"gc.session_name":"'"$N1"'"}}'
VBS_JSON="[$VB1_CLOSED]" VB_SHOW_1="$VB1_CLOSED" VB_SHOW_2="$VB2" REQUIRED_V=2 SESS_JSON="$ROSTER_NEITHER" CLOSED_OUT='[]' OPEN_OUT='[]' run_case
has_line "REACHED_END" && ok "block ran to the end" || bad "block aborted: $(dump)"
finalized && bad "finalized a run with no pending bead and 0 of 2 verdicts counted: $(dump)" || ok "left in flight"
has_line "^warn:.*no pending verdict bead among 1 read, but verdicts received 0 of 2 required.*ga-uk0km5" && ok "warn gives the counts (1 bead read, 0 of 2 verdicts)" || bad "zero-pending path was silent: $(dump)"
has_line "^bdquery:" && bad "queried session beads with nothing pending" || ok "no session-bead query with nothing pending"

echo ""
echo "== gate-uk0km5-phase-c-wait-reason: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
