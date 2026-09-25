#!/usr/bin/env bash
# gate-fail-ephemeral-mayor-defer.selftest.sh (ga-aijm2v.5, rule 3)
#
# A gate FAIL for a bead built by an EPHEMERAL pool session (wa-worker / ps-worker /
# dog) used to wake the Mayor "so a human gets a signal": the dispatcher rewrites such
# an author to "mayor" (routing sentinel), the FAIL nudge cascade then nudges the Mayor
# as its last candidate, and when nothing is reachable it mails the Mayor "Gate: author
# unreachable". But the source bead already comes back on its own (gate:needs-fix +
# gc.routed_to restored to its pool, re-dispatched up to fix-attempt 3), so those wakes
# asked the Mayor for nothing (~8 on 2026-09-25, 0 needing action) and each cost a turn
# re-reading ~440k tokens of context.
#
# Rule: do not wake the Mayor for an ephemeral-author FAIL while the re-dispatch is
# VERIFIED; wake it (as before) when the re-dispatch cannot be verified, and let the
# fix-attempt cap escalation keep paging it at exhaustion. The wake is DEFERRED to the
# end of the FAIL path rather than decided up front, because gc.routed_to is only
# restored (and read back) AFTER the author nudge — "the bead is routed" cannot be known
# at nudge time, and an unknown must not be read as "fine".
#
# Strategy (same as gate-dispatcher-author-nudge-fallback.selftest.sh): extract the LIVE
# function text from quality-gate-dispatcher.sh and eval it here with gc/bd/log/warn
# stubbed — never a hand-copied duplicate. The call sites live inside a 13k-line daemon
# and cannot be run here, so the wiring is pinned structurally (line order of anchors).
#
# GATE_DISPATCHER_UNDER_TEST=<file> points this at a mutated copy (mutation checks).
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${GATE_DISPATCHER_UNDER_TEST:-$SELF_DIR/quality-gate-dispatcher.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

echo "== gate-fail-ephemeral-mayor-defer.selftest =="
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract_block() {   # by SELFTEST-EXTRACT sentinel
  sed -n "/# SELFTEST-EXTRACT $2: BEGIN/,/# SELFTEST-EXTRACT $2: END/p" "$1" | sed '1d;$d'
}
extract_fn() {      # by top-level function name: `name() {` .. first column-0 `}`
  awk -v n="$2" '$0 ~ "^"n"\\(\\) \\{" {f=1} f {print} f && /^\}/ {exit}' "$1"
}

load() {  # load <kind> <name>
  local body
  if [ "$1" = "block" ]; then body="$(extract_block "$DISPATCHER" "$2")"; else body="$(extract_fn "$DISPATCHER" "$2")"; fi
  if [ -z "$body" ]; then echo "FATAL: could not extract $2 from $DISPATCHER" >&2; exit 2; fi
  eval "$body"
}
load block nudge-author-with-fallback
load fn gate_fail_assignee_action
load fn gate_fail_author_is_ephemeral
load fn gate_fail_redispatch_verified
load fn gate_fail_settle_deferred_mayor_wake
for f in nudge_author_with_fallback gate_fail_author_is_ephemeral gate_fail_redispatch_verified gate_fail_settle_deferred_mayor_wake; do
  declare -F "$f" >/dev/null 2>&1 || { echo "FATAL: $f not defined after extraction" >&2; exit 2; }
done

# ── stubs ────────────────────────────────────────────────────────────────────
GC_CITY="test-city"
FAIL_RECIPIENTS=""; NUDGE_LOG=""; MAIL_LOG=""; MAIL_SUBJECTS=""; BD_COMMENTS=""; LOG_LINES=""; WARN_LINES=""
_should_fail() { case " $FAIL_RECIPIENTS " in *" $1 "*) return 0 ;; esac; return 1; }
gc() {
  # gc --city X session nudge <recipient> <msg> [--delivery ..]   |   gc --city X mail send <recipient> -s <subj> -m <body>
  [ "${1:-}" = "--city" ] && shift 2
  case "$1 $2" in
    "session nudge") NUDGE_LOG="$NUDGE_LOG $3"; _should_fail "$3" && return 1; return 0 ;;
    "mail send")     MAIL_LOG="$MAIL_LOG $3"; MAIL_SUBJECTS="$MAIL_SUBJECTS|$5"; _should_fail "mail:$3" && return 1; return 0 ;;
  esac
  return 0
}
bd() { [ "${1:-}" = "-C" ] && shift 2; [ "$1" = "comment" ] && BD_COMMENTS="$BD_COMMENTS|$2:$3"; return 0; }
warn() { WARN_LINES="$WARN_LINES|$*"; }
log()  { LOG_LINES="$LOG_LINES|$*"; }
reset() {
  FAIL_RECIPIENTS=""; NUDGE_LOG=""; MAIL_LOG=""; MAIL_SUBJECTS=""; BD_COMMENTS=""; LOG_LINES=""; WARN_LINES=""
  GATE_FAIL_DEFER_MAYOR=0; GATE_FAIL_MAYOR_DEFERRED=0; GATE_FAIL_REDISPATCH_VERIFIED=0; GATE_FAIL_CAP_ESCALATED=0
  GATE_FAIL_MAYOR_DEFER_CTX=""; GATE_FAIL_MAYOR_DEFER_CANDIDATES=""; BEAD_ID="wa-x1"
}
trim() { echo "$*" | sed 's/^ *//; s/ *$//'; }
CTX="Gate FAIL nudge for wa-x1 (branch crew/wa-worker/wa-x1)"

echo "== 1. today's behaviour is unchanged when the deferral flag is OFF (the defect being fixed)"
reset; FAIL_RECIPIENTS="wa-worker wa-worker-wa"
nudge_author_with_fallback wa-x1 wa-worker mayor "msg" "$CTX"; rc=$?
eq "with the flag off the cascade still ends at the Mayor" "$(trim "$NUDGE_LOG")" "wa-worker wa-worker-wa mayor"
eq "and that nudge counts as delivered" "$rc" "0"

echo "== 2. ephemeral author, flag ON: the Mayor is not a candidate and is not mailed"
reset; GATE_FAIL_DEFER_MAYOR=1; FAIL_RECIPIENTS="wa-worker wa-worker-wa"
nudge_author_with_fallback wa-x1 wa-worker mayor "msg" "$CTX"; rc=$?
eq "only the ephemeral candidates are tried" "$(trim "$NUDGE_LOG")" "wa-worker wa-worker-wa"
eq "no mail to the Mayor" "$(trim "$MAIL_LOG")" ""
eq "returns 1 (not delivered) so the caller can tell" "$rc" "1"
eq "the deferral is recorded for the end of the FAIL path" "$GATE_FAIL_MAYOR_DEFERRED" "1"
case "$BD_COMMENTS" in *"wa-x1:"*"NOT paged"*) ok "the bead gets a comment saying the Mayor was NOT paged (not-notified never reads as notified)" ;; *) bad "no truthful bead comment: [$BD_COMMENTS]" ;; esac
case "$GATE_FAIL_MAYOR_DEFER_CTX" in *wa-x1*) ok "context kept for the later page" ;; *) bad "context lost: [$GATE_FAIL_MAYOR_DEFER_CTX]" ;; esac

echo "== 3. flag ON but a real candidate answers: delivered, nothing deferred"
reset; GATE_FAIL_DEFER_MAYOR=1; FAIL_RECIPIENTS="wa-worker"
nudge_author_with_fallback wa-x1 wa-worker mayor "msg" "$CTX"; rc=$?
eq "rig-qualified candidate reached" "$(trim "$NUDGE_LOG")" "wa-worker wa-worker-wa"
eq "delivered" "$rc" "0"
eq "nothing deferred" "$GATE_FAIL_MAYOR_DEFERRED" "0"

echo "== 4. flag ON, non-Mayor ephemeral author (a dog session): its own session stays a candidate"
reset; GATE_FAIL_DEFER_MAYOR=1; FAIL_RECIPIENTS="dog-gaabc"
nudge_author_with_fallback ga-x2 dog-gaabc dog-gaabc "msg" "Gate FAIL nudge for ga-x2"; rc=$?
eq "the dog session is nudged, the Mayor is not" "$(trim "$NUDGE_LOG")" "dog-gaabc"
eq "unreachable dog => deferred, no mail" "$GATE_FAIL_MAYOR_DEFERRED:$(trim "$MAIL_LOG")" "1:"

echo "== 4b. the Mayor sentinel is the FIRST candidate when the branch is not crew/<name>/* (NOTIFY_AUTHOR falls back to AUTHOR)"
reset; GATE_FAIL_DEFER_MAYOR=1
nudge_author_with_fallback ga-x4 mayor mayor "msg" "Gate FAIL nudge for ga-x4"; rc=$?
eq "the Mayor is not nudged even as the first candidate" "$(trim "$NUDGE_LOG")" ""
eq "deferred, nothing mailed, reported undelivered" "$GATE_FAIL_MAYOR_DEFERRED:$(trim "$MAIL_LOG"):$rc" "1::1"
reset
nudge_author_with_fallback ga-x4 mayor mayor "msg" "Gate FAIL nudge for ga-x4" >/dev/null
eq "flag OFF: a real Mayor author is still nudged as before" "$(trim "$NUDGE_LOG")" "mayor"

echo "== 5. a NAMED crew that is unreachable still escalates to the Mayor immediately (flag never set for it)"
reset; FAIL_RECIPIENTS="thies thies-wa"
nudge_author_with_fallback wa-x3 thies thies-wa "msg" "Gate FAIL nudge for wa-x3" >/dev/null
case "$(trim "$MAIL_LOG")" in *mayor*) ok "named-crew total failure still mails the Mayor" ;; *) bad "named-crew failure did not escalate: [$MAIL_LOG]" ;; esac

echo "== 6. gate_fail_author_is_ephemeral reuses the canonical pool deny-list"
for a in mayor gastown.mayor gastown__mayor dog-gaabc gastown.dog gastown.dog-2 wa-worker wa-worker-adhoc-1 ps-worker ps-worker-3; do
  gate_fail_author_is_ephemeral "$a" && ok "$a is ephemeral" || bad "$a should be ephemeral"
done
for a in thies-wa batista-wa oracle-wa peter-wa mila-wa digo-wa ""; do
  gate_fail_author_is_ephemeral "$a" && bad "[$a] must NOT be ephemeral" || ok "[$a] is not ephemeral"
done

echo "== 7. gate_fail_redispatch_verified: only a read-back that shows route restored AND assignee cleared counts"
V() { gate_fail_redispatch_verified "$@"; }
eq "restored + cleared"                 "$(V 'gc.routed_to=wa-worker (restored)' wa-worker 'assignee=cleared' 0)" "1"
eq "post-write read failed (UNVERIFIED)" "$(V 'gc.routed_to=UNVERIFIED (post-write read failed — state unknown, NOT a claim the restore failed)' wa-worker 'assignee=UNVERIFIED (post-write read failed)' 0)" "0"
eq "restore did not stick"              "$(V "gc.routed_to='' NOT wa-worker — restore did not stick, needs investigation" wa-worker 'assignee=cleared' 0)" "0"
eq "assignee not cleared"               "$(V 'gc.routed_to=wa-worker (restored)' wa-worker "assignee='x' NOT cleared" 0)" "0"
eq "route was a guess (UNKNOWN store)"  "$(V 'gc.routed_to=gastown.dog (restored)' gastown.dog 'assignee=cleared' 1)" "0"
eq "empty arguments never verify"       "$(V '' '' '' '')" "0"

echo "== 8. settle: the Mayor is paged at the END of the FAIL path unless the re-dispatch is verified"
reset; GATE_FAIL_MAYOR_DEFERRED=1; GATE_FAIL_MAYOR_DEFER_CTX="$CTX"; GATE_FAIL_MAYOR_DEFER_CANDIDATES="wa-worker wa-worker-wa"; GATE_FAIL_REDISPATCH_VERIFIED=1
gate_fail_settle_deferred_mayor_wake
eq "verified re-dispatch => Mayor NOT paged" "$(trim "$MAIL_LOG")" ""
case "$LOG_LINES" in *"NOT paged"*) ok "and the log says why" ;; *) bad "no log line: [$LOG_LINES]" ;; esac
reset; GATE_FAIL_MAYOR_DEFERRED=1; GATE_FAIL_MAYOR_DEFER_CTX="$CTX"; GATE_FAIL_MAYOR_DEFER_CANDIDATES="wa-worker wa-worker-wa"; GATE_FAIL_CAP_ESCALATED=1
gate_fail_settle_deferred_mayor_wake
eq "cap escalation already paged the Mayor => no second page" "$(trim "$MAIL_LOG")" ""
reset; GATE_FAIL_MAYOR_DEFERRED=1; GATE_FAIL_MAYOR_DEFER_CTX="$CTX"; GATE_FAIL_MAYOR_DEFER_CANDIDATES="wa-worker wa-worker-wa"
gate_fail_settle_deferred_mayor_wake
eq "re-dispatch NOT verified => the Mayor is paged" "$(trim "$MAIL_LOG")" "mayor"
case "$MAIL_SUBJECTS" in *"Gate: author unreachable for wa-x1"*) ok "same subject the Mayor's filters already know" ;; *) bad "subject changed: [$MAIL_SUBJECTS]" ;; esac
case "$BD_COMMENTS" in *"wa-x1:"*"PAGED"*) ok "and the bead records that the Mayor was paged" ;; *) bad "no bd comment: [$BD_COMMENTS]" ;; esac
eq "settle is one-shot (flag cleared)" "$GATE_FAIL_MAYOR_DEFERRED" "0"
MAIL_LOG=""; gate_fail_settle_deferred_mayor_wake
eq "a second settle pages nobody" "$(trim "$MAIL_LOG")" ""
reset; gate_fail_settle_deferred_mayor_wake
eq "nothing deferred => settle is a no-op" "$(trim "$MAIL_LOG")|$BD_COMMENTS|$LOG_LINES" "||"
reset; BEAD_ID=""; GATE_FAIL_MAYOR_DEFERRED=1; GATE_FAIL_MAYOR_DEFER_CTX="$CTX"
gate_fail_settle_deferred_mayor_wake
eq "no bead id (nothing re-dispatchable) => the Mayor is paged" "$(trim "$MAIL_LOG")" "mayor"

echo "== 9. wiring inside the FAIL path (structural: the daemon itself cannot run here)"
lineof() { grep -n "$1" "$DISPATCHER" | head -1 | cut -d: -f1; }
L_RESET="$(lineof 'ga-aijm2v.5 wiring\[reset\]')"
L_ON="$(lineof 'ga-aijm2v.5 wiring\[defer-on\]')"
L_CALL1="$(lineof 'SELFTEST-EXTRACT nudge-call-site-1: BEGIN')"
L_OFF="$(lineof 'ga-aijm2v.5 wiring\[defer-off\]')"
L_CAP="$(lineof 'ga-aijm2v.5 wiring\[cap-covered\]')"
L_VER="$(lineof 'ga-aijm2v.5 wiring\[verified\]')"
L_SET="$(lineof 'ga-aijm2v.5 wiring\[settle\]')"
L_TERM="$(lineof 'wa-uthi: TERMINAL FAIL (review rejected')"
for n in RESET ON CALL1 OFF CAP VER SET TERM; do
  v="$(eval echo \$L_$n)"; [ -n "$v" ] && ok "anchor $n present (line $v)" || bad "anchor $n missing"
done
order_ok() { [ -n "$L_RESET" ] && [ -n "$L_ON" ] && [ -n "$L_CALL1" ] && [ -n "$L_OFF" ] && [ -n "$L_CAP" ] && [ -n "$L_VER" ] && [ -n "$L_SET" ] \
  && [ "$L_RESET" -lt "$L_ON" ] && [ "$L_ON" -lt "$L_CALL1" ] && [ "$L_CALL1" -lt "$L_OFF" ] && [ "$L_OFF" -lt "$L_CAP" ] \
  && [ "$L_CAP" -lt "$L_VER" ] && [ "$L_VER" -lt "$L_SET" ]; }
order_ok && ok "order: reset < defer-on < nudge call < defer-off < cap-covered < verified < settle" || bad "wiring anchors are out of order (reset=$L_RESET on=$L_ON call1=$L_CALL1 off=$L_OFF cap=$L_CAP ver=$L_VER settle=$L_SET)"
[ -n "$L_SET" ] && [ -n "$L_TERM" ] && [ "$L_SET" -lt "$L_TERM" ] && ok "settle runs before the terminal FAIL notification" || bad "settle is not before the terminal FAIL block"
# An anchor COMMENT proves nothing by itself (deleting the code under it must not pass), so
# each anchor is paired with the code line(s) it announces, searched inside its own line range.
in_range() { [ -n "$1" ] && [ -n "$2" ] && sed -n "${1},${2}p" "$DISPATCHER" | grep -qE -- "$3"; }
for v in GATE_FAIL_DEFER_MAYOR GATE_FAIL_MAYOR_DEFERRED GATE_FAIL_REDISPATCH_VERIFIED GATE_FAIL_CAP_ESCALATED GATE_FAIL_MAYOR_DEFER_CTX GATE_FAIL_MAYOR_DEFER_CANDIDATES; do
  in_range "$L_RESET" "$L_ON" "^  ${v}=" && ok "FAIL-path entry resets $v (no leak between runs of one sweep)" || bad "FAIL-path entry does not reset $v"
done
in_range "$L_ON" "$L_CALL1" '^  if gate_fail_author_is_ephemeral "\$AUTHOR"; then GATE_FAIL_DEFER_MAYOR=1; fi' \
  && ok "defer switch is turned on only for an ephemeral author" || bad "defer-on line missing or not guarded by gate_fail_author_is_ephemeral"
in_range "$L_OFF" "$((${L_OFF:-0} + 3))" '^  GATE_FAIL_DEFER_MAYOR=0' \
  && ok "the defer switch is switched OFF right after the first nudge call" || bad "GATE_FAIL_DEFER_MAYOR is not reset right after the first nudge call"
in_range "$L_CAP" "$((${L_CAP:-0} + 6))" '^      GATE_FAIL_CAP_ESCALATED=1' \
  && ok "the cap branch marks the Mayor as already paged" || bad "cap branch does not set GATE_FAIL_CAP_ESCALATED"
in_range "$L_VER" "$((${L_VER:-0} + 6))" 'GATE_FAIL_REDISPATCH_VERIFIED=\$\(gate_fail_redispatch_verified "\$\{_GFAIL_ROUTE_OBS:-\}" "\$_GFAIL_ROUTE" "\$\{_GFAIL_ASSIGNEE_OBS:-\}" "\$_GFAIL_ROUTE_UNKNOWN"\)' \
  && ok "return-to-pool arm derives VERIFIED from the read-back observations (all four inputs)" || bad "VERIFIED is not derived from the four read-back observations"
in_range "$L_SET" "$L_TERM" '^  gate_fail_settle_deferred_mayor_wake( \|\| true)?$' \
  && ok "the settle CALL is present and runs before the terminal FAIL notification" || bad "settle call missing between its anchor and the terminal FAIL block"
# the settle must stay INSIDE the FAIL path: it must come after the return-to-pool arm's comment
[ -n "$L_VER" ] && [ -n "$L_SET" ] && [ "$L_VER" -lt "$L_SET" ] && ok "settle comes after the re-dispatch verification" || bad "settle is not after the verification"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
