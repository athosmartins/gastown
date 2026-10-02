#!/usr/bin/env bash
# gate-oj7bzs-absent-reviewer-bead-closed.selftest.sh (ga-oj7bzs)
#
# Proves: when a pending verdict slot's reviewer session is ABSENT from
# `gc session list --json` but its SESSION BEAD is status=closed, Phase C's
# debounce-free check (gate_phase_c_all_pending_closed, ga-s4potx) classifies
# it dead on the FIRST sweep instead of waiting out the outer timeout.
#
# INCIDENT (2026-10-01 23:16-23:28, run ga-rj1icm / ps-3fgt): the reviewer
# session ga-wisp-ruzed4 (name gate-reviewer-adhoc-82f80c491a) died in the
# 23:18 reboot. Its session bead was status=closed, but `gc session list` no
# longer returned it AT ALL (a closed session drops out of the list; it does
# not show up as closed=true). reviewer_session_confirmed_closed() only
# answers 1 for a session that is PRESENT with .closed==true, so "absent" read
# as "not confirmed" and the run waited the full 3000s ("still in flight
# (0/1 verdicts, 823s/3000s)") — up to 50 min of gate stalled per in-flight
# run, every reboot.
#
# FIX: for a slot whose session is absent from the list, consult the session
# bead (reviewer_session_bead_state). Three states plus "no bead":
#   closed    -> >=1 matching session bead is closed AND none is still open
#                (a closed session bead never reopens: definitive)
#   open      -> some matching bead is not closed (a live / booting incarnation
#                of the name exists) -> wait
#   notfound  -> no bead for the name in the window -> not yet created -> wait
#   unknown   -> the lookup failed / returned a non-list -> wait (and say so)
# Only `closed` counts as dead. Everything else keeps waiting.
#
# NOTE ON THE LOOKUP: the reviewer's assignee is its session NAME
# (gate-reviewer-adhoc-<hash>), NOT the session bead id (ga-wisp-xxxx), so
# `bd show <assignee>` finds nothing ("no issue found"). The bead has to be
# found by the metadata.session_name it carries, via a time-windowed
# `bd query` (bd list/query cannot filter on metadata; scanning all ~5400
# session beads per sweep is far too heavy).
#
# Strategy (this repo's SELFTEST-EXTRACT convention): extract the live blocks,
# run them verbatim under the host's /bin/bash (3.2) with `set -euo pipefail`,
# with bd/gc/warn/log/gate_finalize_run stubbed.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
REAL_BASH="/bin/bash"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-oj7bzs-absent-reviewer-bead-closed.selftest =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -x "$REAL_BASH" ] || { echo "FATAL: $REAL_BASH not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/oj7bzs-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

extract_block() {
  sed -n "/# SELFTEST-EXTRACT $2: BEGIN/,/# SELFTEST-EXTRACT $2: END/p" "$1" | sed '1d;$d'
}

FN_CLOSED="$(extract_block "$DISPATCHER" "reviewer-session-confirmed-closed-fn")"
FN_CLASSIFY="$(extract_block "$DISPATCHER" "phase-c-closed-reviewer-classify-fn")"
DECISION="$(extract_block "$DISPATCHER" "phase-c-verdict-decision")"
if [ -z "$FN_CLOSED" ] || [ -z "$FN_CLASSIFY" ] || [ -z "$DECISION" ]; then
  echo "FATAL: could not extract blocks (closed=${#FN_CLOSED} classify=${#FN_CLASSIFY} decision=${#DECISION}) — sentinel moved?" >&2
  exit 2
fi

# ── harness ─────────────────────────────────────────────────────────────────
# bd stub: `bd -C <city> query --json "<expr>" --limit=0`
#   expr containing "status=closed"   -> $CLOSED_OUT / $CLOSED_RC
#   expr containing "status!=closed"  -> $OPEN_OUT   / $OPEN_RC
# `bd -C <city> show vb-N --json`     -> {"status":"$VB<N>_STATUS"}
# every query is appended to $LOG as "bdquery:<expr>".
write_common() {  # write_common <file>
  cat > "$1" <<'COMMON'
set -euo pipefail
GC_CITY="/fake/city"; GATE_RUN_ID="test-run-1"; BRANCH="fake-branch"
PC_TIMEOUT_MIN=15
: "${LOG:?}"
bd() {
  case " $* " in
    *" query "*)
      local expr="" a
      for a in "$@"; do case "$a" in type=session*) expr="$a" ;; esac; done
      echo "bdquery:$expr" >> "$LOG"
      case "$expr" in
        *"status!=closed"*) printf '%s' "${OPEN_OUT-}"; return "${OPEN_RC:-0}" ;;
        *"status=closed"*)  printf '%s' "${CLOSED_OUT-}"; return "${CLOSED_RC:-0}" ;;
      esac
      return 1 ;;
    *" show vb-1 "*) echo "{\"status\":\"${VB1_STATUS:-open}\"}"; return 0 ;;
    *" show vb-2 "*) echo "{\"status\":\"${VB2_STATUS:-open}\"}"; return 0 ;;
  esac
  echo "bd:$*" >> "$LOG"; return 0
}
gc_json_or_unknown() { printf '%s' "${SESS_JSON-}"; return 0; }
warn() { echo "warn:$*" >> "$LOG"; }
log()  { echo "log:$*" >> "$LOG"; }
gate_finalize_run() {
  echo "finalize_called:QUOTA_REQUEUE=${QUOTA_REQUEUE}:REQUEUE_REASON=${REQUEUE_REASON}:OVERALL_VERDICT=${OVERALL_VERDICT:-unset}" >> "$LOG"
}
QUOTA_REQUEUE=0; REQUEUE_REASON="quota"
COMMON
}

# run_unit <script-body> -> runs body after the live function blocks
run_unit() {
  local f="$WORK/unit.sh"
  write_common "$f"
  { printf '%s\n' "$FN_CLOSED" "$FN_CLASSIFY"; printf '%s\n' "$1"; } >> "$f"
  : > "$WORK/unit.log"
  LOG="$WORK/unit.log" "$REAL_BASH" "$f" 2>&1
}

# run_decision <slots: "s1" or "s1 s2"> -> runs the live decision block.
# Env (pass inline): SESS_JSON CLOSED_OUT OPEN_OUT CLOSED_RC OPEN_RC
#                    VB1_STATUS VB2_STATUS PC_ELAPSED_V
run_decision() {
  local slots="$1" f="$WORK/dec.sh" n=0 s vbs="" sids=""
  for s in $slots; do n=$((n+1)); vbs="$vbs vb-$n"; sids="$sids $s"; done
  write_common "$f"
  {
    echo "REQUIRED_REVIEWERS=$n; PC_TIMEOUT_SECS=3000; VERDICTS_RECEIVED=0; ANY_FAIL=0"
    echo "PC_ELAPSED=\"\${PC_ELAPSED_V-60}\""
    echo "VERDICT_BEAD_IDS=($vbs); SESSION_IDS=($sids)"
    printf '%s\n' "$FN_CLOSED" "$FN_CLASSIFY"
    echo 'for _dummy in 1; do'
    printf '%s\n' "$DECISION"
    echo 'done'
    echo 'echo REACHED_END >> "$LOG"'
  } >> "$f"
  : > "$WORK/dec.log"
  LOG="$WORK/dec.log" "$REAL_BASH" "$f" >"$WORK/dec.out" 2>&1
  return $?
}

NAME="gate-reviewer-adhoc-82f80c491a"
CLOSED_BEAD='[{"id":"ga-wisp-ruzed4","status":"closed","metadata":{"session_name":"'"$NAME"'","alias":"'"$NAME"'","agent_name":"'"$NAME"'"}}]'
OPEN_BEAD='[{"id":"ga-wisp-new001","status":"open","metadata":{"session_name":"'"$NAME"'"}}]'
OTHER_CLOSED='[{"id":"ga-wisp-other","status":"closed","metadata":{"session_name":"gate-reviewer-adhoc-ffffffffff"}}]'

echo "── 0a. reviewer_session_listed(): present in the roster, whatever .closed says ──"
OUT="$(run_unit '
type reviewer_session_listed >/dev/null 2>&1 || { echo "MISSING_FN"; exit 0; }
J="{\"sessions\":[{\"session_name\":\"a\",\"closed\":false},{\"session_name\":\"b\",\"closed\":true},{\"alias\":\"c\"}]}"
echo "a=$(reviewer_session_listed a "$J") b=$(reviewer_session_listed b "$J") c=$(reviewer_session_listed c "$J") zz=$(reviewer_session_listed zz "$J") empty=$(reviewer_session_listed "" "$J") bad=$(reviewer_session_listed a "not-json{{")"
')"
if [ "$OUT" = "a=1 b=1 c=1 zz=0 empty=0 bad=0" ]; then
  ok "listed: present open/closed/alias -> 1; absent, empty id, malformed JSON -> 0"
else
  bad "reviewer_session_listed wrong or missing: [$OUT]"
fi

echo "── 0b. reviewer_session_bead_state(): closed / open / notfound / unknown ──"
state() {  # state <closed_out> <closed_rc> <open_out> <open_rc> [name] [hours]
  CLOSED_OUT="$1" CLOSED_RC="$2" OPEN_OUT="$3" OPEN_RC="$4" run_unit '
type reviewer_session_bead_state >/dev/null 2>&1 || { echo "MISSING_FN"; exit 0; }
reviewer_session_bead_state "'"${5-$NAME}"'" "'"${6-3}"'"
'
}
R="$(state "$CLOSED_BEAD" 0 '[]' 0)"
[ "$R" = "closed" ]   && ok "closed bead matched by session_name, no open bead -> closed" || bad "closed case -> [$R]"
R="$(state "$CLOSED_BEAD" 0 "$OPEN_BEAD" 0)"
[ "$R" = "open" ]     && ok "closed bead AND an open bead of the same name (reused name) -> open (wait)" || bad "reused-name case -> [$R]"
R="$(state '[]' 0 '[]' 0)"
[ "$R" = "notfound" ] && ok "no bead in window (session not created yet) -> notfound (wait)" || bad "notfound case -> [$R]"
R="$(state "$OTHER_CLOSED" 0 '[]' 0)"
[ "$R" = "notfound" ] && ok "a closed bead of a DIFFERENT name does not match -> notfound" || bad "other-name case -> [$R]"
R="$(state '' 1 '[]' 0)"
[ "$R" = "unknown" ]  && ok "closed-query fails (rc!=0) -> unknown, never 'closed'" || bad "closed-query failure -> [$R]"
R="$(state "$CLOSED_BEAD" 0 '' 1)"
[ "$R" = "unknown" ]  && ok "open-query fails -> unknown even though a closed bead matched (cannot rule out a live incarnation)" || bad "open-query failure -> [$R]"
R="$(state '{"error":"boom","schema_version":1}' 0 '[]' 0)"
[ "$R" = "unknown" ]  && ok "rc=0 but an error envelope (object, not list) -> unknown" || bad "error-envelope -> [$R]"
R="$(state '' 0 '[]' 0)"
[ "$R" = "unknown" ]  && ok "rc=0 but EMPTY output -> unknown (empty is not an empty list)" || bad "empty-output -> [$R]"
R="$(state "$CLOSED_BEAD" 0 '[]' 0 "")"
[ "$R" = "unknown" ]  && ok "empty name -> unknown" || bad "empty-name -> [$R]"
ALIAS_ONLY='[{"id":"ga-x1","status":"closed","metadata":{"alias":"nm-alias"}}]'
R="$(state "$ALIAS_ONLY" 0 '[]' 0 nm-alias)"
[ "$R" = "closed" ]   && ok "matches on metadata.alias too (same fields the session roster is matched on)" || bad "alias match -> [$R]"
BYID='[{"id":"ga-wisp-byid","status":"closed","metadata":null}]'
R="$(state "$BYID" 0 '[]' 0 ga-wisp-byid)"
[ "$R" = "closed" ]   && ok "assignee that is the bead id itself matches (and a null .metadata does not crash jq)" || bad "id match -> [$R]"

echo "── 1. THE BUG: reviewer ABSENT from the roster, session bead CLOSED -> re-queue NOW ──"
SESS_ABSENT='{"sessions":[{"session_name":"some-other-session","closed":false}]}'
SESS_JSON="$SESS_ABSENT" CLOSED_OUT="$CLOSED_BEAD" OPEN_OUT='[]' run_decision "$NAME"
RC=$?; L="$WORK/dec.log"
[ "$RC" -eq 0 ] && ok "block exits 0" || bad "block exited $RC: $(tr '\n' ';' < "$WORK/dec.out")"
if grep -q "^finalize_called:QUOTA_REQUEUE=1:REQUEUE_REASON=dead-reviewer" "$L"; then
  ok "re-queued via dead-reviewer on the first sweep (elapsed=60s << 3000s) — THIS IS THE FIX"
else
  bad "NOT re-queued while the reviewer's session bead is closed — log: $(tr '\n' ';' < "$L")"
fi

echo "── 2. wait: absent, and NO session bead found (start-pending / not created yet; ga-wcd86) ──"
SESS_JSON="$SESS_ABSENT" CLOSED_OUT='[]' OPEN_OUT='[]' run_decision "$NAME"
if grep -q "^finalize_called:" "$WORK/dec.log"; then bad "finalized a run whose reviewer has no session bead — false positive: $(tr '\n' ';' < "$WORK/dec.log")"; else ok "left in flight (no requeue)"; fi
grep -q "still in flight" "$WORK/dec.log" && ok "normal 'still in flight' line" || bad "no 'still in flight' line"

echo "── 3. wait: absent, bead lookup FAILS (unreadable != closed) ──"
SESS_JSON="$SESS_ABSENT" CLOSED_OUT='' CLOSED_RC=1 OPEN_OUT='[]' run_decision "$NAME"
if grep -q "^finalize_called:" "$WORK/dec.log"; then bad "requeued on an unreadable lookup: $(tr '\n' ';' < "$WORK/dec.log")"; else ok "left in flight (no requeue)"; fi
grep -q "^warn:.*oj7bzs" "$WORK/dec.log" && ok "the unreadable lookup is VISIBLE (warn names ga-oj7bzs), not silent" || bad "unreadable lookup left no warn: $(tr '\n' ';' < "$WORK/dec.log")"

echo "── 4. wait: reviewer PRESENT and alive -> must not even query beads ──"
SESS_ALIVE='{"sessions":[{"session_name":"'"$NAME"'","closed":false,"state":"active"}]}'
SESS_JSON="$SESS_ALIVE" CLOSED_OUT="$CLOSED_BEAD" OPEN_OUT='[]' run_decision "$NAME"
if grep -q "^finalize_called:" "$WORK/dec.log"; then bad "requeued a run whose reviewer is alive: $(tr '\n' ';' < "$WORK/dec.log")"; else ok "left in flight"; fi
grep -q "^bdquery:" "$WORK/dec.log" && bad "queried session beads for a reviewer that is present in the roster (needless per-sweep cost)" || ok "no session-bead query for a present reviewer"

echo "── 5. wait: absent + closed bead, but a same-name OPEN bead exists (reused name) ──"
SESS_JSON="$SESS_ABSENT" CLOSED_OUT="$CLOSED_BEAD" OPEN_OUT="$OPEN_BEAD" run_decision "$NAME"
if grep -q "^finalize_called:" "$WORK/dec.log"; then bad "requeued although a live incarnation of the name exists: $(tr '\n' ';' < "$WORK/dec.log")"; else ok "left in flight"; fi

echo "── 6. two slots: one absent+closed, the other alive -> wait (ALL pending must be dead) ──"
SESS_MIX='{"sessions":[{"session_name":"live-one","closed":false}]}'
SESS_JSON="$SESS_MIX" CLOSED_OUT="$CLOSED_BEAD" OPEN_OUT='[]' run_decision "$NAME live-one"
if grep -q "^finalize_called:" "$WORK/dec.log"; then bad "requeued with one reviewer still alive: $(tr '\n' ';' < "$WORK/dec.log")"; else ok "left in flight"; fi

echo "── 7. two slots, both dead (one absent+closed bead, one present closed=true) -> requeue ──"
SESS_BOTH='{"sessions":[{"session_name":"gone-closed","closed":true}]}'
SESS_JSON="$SESS_BOTH" CLOSED_OUT="$CLOSED_BEAD" OPEN_OUT='[]' run_decision "$NAME gone-closed"
grep -q "^finalize_called:QUOTA_REQUEUE=1:REQUEUE_REASON=dead-reviewer" "$WORK/dec.log" && ok "re-queued: every pending slot confirmed dead" || bad "mixed dead slots not requeued: $(tr '\n' ';' < "$WORK/dec.log")"

echo "── 8. query window follows the run's age (not the whole ~5400-bead history) ──"
q_hours() { grep -o 'created>[0-9]*h' "$WORK/dec.log" | head -1; }
SESS_JSON="$SESS_ABSENT" CLOSED_OUT="$CLOSED_BEAD" OPEN_OUT='[]' PC_ELAPSED_V=60 run_decision "$NAME";    W1="$(q_hours)"
SESS_JSON="$SESS_ABSENT" CLOSED_OUT="$CLOSED_BEAD" OPEN_OUT='[]' PC_ELAPSED_V=7300 run_decision "$NAME";  W2="$(q_hours)"
SESS_JSON="$SESS_ABSENT" CLOSED_OUT="$CLOSED_BEAD" OPEN_OUT='[]' PC_ELAPSED_V=abc run_decision "$NAME";   W3="$(q_hours)"
[ "$W1" = "created>3h" ]  && ok "60s old run -> created>3h (age + 3h margin)"        || bad "60s run window [$W1]"
[ "$W2" = "created>5h" ]  && ok "7300s old run -> created>5h (2h + 3h margin)"        || bad "7300s run window [$W2]"
[ "$W3" = "created>24h" ] && ok "non-numeric elapsed -> safe 24h default (not 0h / not unbounded)" || bad "bad-elapsed window [$W3]"

echo "── 9. NON-REGRESSION: verdict already recorded -> finalize by VERDICT, never requeue ──"
SESS_JSON="$SESS_ABSENT" CLOSED_OUT="$CLOSED_BEAD" OPEN_OUT='[]' VB1_STATUS=closed run_decision "$NAME"
# the decision block takes the verdict path only when VERDICTS_RECEIVED==REQUIRED; with the
# bead closed but the counter at 0 (collect_verdicts is not part of the extract) the run has
# NO pending slot -> gate_phase_c_all_pending_closed must say false (nothing to requeue).
grep -q "REQUEUE_REASON=dead-reviewer" "$WORK/dec.log" && bad "treated an already-delivered slot as pending-dead" || ok "no pending slot -> no dead-reviewer requeue"

echo ""
echo "== gate-oj7bzs-absent-reviewer-bead-closed: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
