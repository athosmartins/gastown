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
load fn gate_fail_pool_read_facts
load fn gate_fail_pool_veto_reasons
load fn gate_fail_redispatch_verified
load fn gate_fail_settle_deferred_mayor_wake
# The veto lists live in a sibling lib the dispatcher sources (gate round 3, blocking 2). Run the LIVE load
# block, pointed at the lib next to the dispatcher under test — the same `[ -r ]`-guarded source, not a copy.
_GATE_VETO_LIB_DIR="${GATE_VETO_LIB_DIR_UNDER_TEST:-$(dirname "$DISPATCHER")/scripts}"
POOL_VETO_LOAD_BODY="$(extract_block "$DISPATCHER" pool-veto-lib-load)"
[ -n "$POOL_VETO_LOAD_BODY" ] || { echo "FATAL: could not extract pool-veto-lib-load from $DISPATCHER" >&2; exit 2; }
eval "$POOL_VETO_LOAD_BODY"
for f in nudge_author_with_fallback gate_fail_author_is_ephemeral gate_fail_pool_read_facts gate_fail_pool_veto_reasons gate_fail_redispatch_verified gate_fail_settle_deferred_mayor_wake pool_veto_cfg; do
  declare -F "$f" >/dev/null 2>&1 || { echo "FATAL: $f not defined after extraction" >&2; exit 2; }
done

# ── stubs ────────────────────────────────────────────────────────────────────
# The stubs are STORE-AWARE on purpose (ga-aijm2v.5 gate round 1, blocking 1): a stub that discards
# `bd -C <store>` cannot tell the HQ store from the bead's own store, which is exactly how a
# `bd -C <HQ> comment wa-x1` — a no-op in production, "no issue found" — sat behind a green
# selftest. Here a comment LANDS only when <store> owns the bead, and `bd show` answers "no
# issue found" from any other store, mirroring what the real bd does. Beads named ga-* live in
# the HQ store ($GC_CITY); everything else (wa-*, ps-*, lx-*) lives in its rig store.
GC_CITY="test-city"
GATE_FAIL_NOW=1790400000   # pinned clock for pilot:held-until (expired / future)
WA_STORE="/rig/whatsapp_automation"
bead_home() { case "$1" in ga-*) printf '%s' "$GC_CITY" ;; *) printf '%s' "$WA_STORE" ;; esac; }
FAIL_RECIPIENTS=""; NUDGE_LOG=""; MAIL_LOG=""; MAIL_SUBJECTS=""; MAIL_BODIES=""; BD_COMMENTS=""; BD_LOST=""; LOG_LINES=""; WARN_LINES=""
BD_SHOW_JSON=""; BD_SHOW_RC=0
_should_fail() { case " $FAIL_RECIPIENTS " in *" $1 "*) return 0 ;; esac; return 1; }
gc() {
  # gc --city X session nudge <recipient> <msg> [--delivery ..]   |   gc --city X mail send <recipient> -s <subj> -m <body>
  [ "${1:-}" = "--city" ] && shift 2
  case "$1 $2" in
    "session nudge") NUDGE_LOG="$NUDGE_LOG $3"; _should_fail "$3" && return 1; return 0 ;;
    "mail send")     MAIL_LOG="$MAIL_LOG $3"; MAIL_SUBJECTS="$MAIL_SUBJECTS|$5"; MAIL_BODIES="$MAIL_BODIES|${7:-}"; _should_fail "mail:$3" && return 1; return 0 ;;
  esac
  return 0
}
bd() {
  local _store=""
  if [ "${1:-}" = "-C" ]; then _store="${2:-}"; shift 2; fi
  case "${1:-}" in
    comment)
      # BD_COMMENTS = comments that reached the bead ("<bead>:<text>"); BD_LOST = ones sent to a
      # store that cannot see it ("<bead>@<store>") — production swallows those (2>/dev/null || true).
      if [ "$_store" = "$(bead_home "${2:-}")" ]; then BD_COMMENTS="$BD_COMMENTS|$2:$3"; else BD_LOST="$BD_LOST|$2@$_store"; fi
      return 0 ;;
    show)
      # Runs inside $(...) in the code under test, so it must not rely on setting variables.
      if [ "$_store" = "$(bead_home "${2:-}")" ] && [ "${BD_SHOW_RC:-0}" = "0" ]; then printf '%s' "$BD_SHOW_JSON"; return 0; fi
      printf '{"error":"no issue found matching %s"}' "${2:-}"; return 1 ;;
  esac
  return 0
}
warn() { WARN_LINES="$WARN_LINES|$*"; }
log()  { LOG_LINES="$LOG_LINES|$*"; }
reset() {
  FAIL_RECIPIENTS=""; NUDGE_LOG=""; MAIL_LOG=""; MAIL_SUBJECTS=""; MAIL_BODIES=""; BD_COMMENTS=""; BD_LOST=""; LOG_LINES=""; WARN_LINES=""
  GATE_FAIL_DEFER_MAYOR=0; GATE_FAIL_MAYOR_DEFERRED=0; GATE_FAIL_REDISPATCH_VERIFIED=0; GATE_FAIL_CAP_ESCALATED=0
  GATE_FAIL_MAYOR_DEFER_CTX=""; GATE_FAIL_MAYOR_DEFER_CANDIDATES=""; BEAD_ID="wa-x1"; BEAD_CITY="$WA_STORE"
  GATE_FAIL_NO_EVAL_RUN=0; BD_SHOW_JSON=""; BD_SHOW_RC=0; GATE_FAIL_POOL_VETO_REASONS=""
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
case "$BD_COMMENTS" in *"wa-x1:"*"NOT paged"*) ok "the bead gets a comment saying the Mayor was NOT paged (not-notified never reads as notified)" ;; *) bad "no truthful bead comment reached wa-x1 (lost: [$BD_LOST]; landed: [$BD_COMMENTS])" ;; esac
eq "that comment went to the bead's OWN store, none to a store that cannot see wa-x1 (blocking 1)" "$BD_LOST" ""
case "$GATE_FAIL_MAYOR_DEFER_CTX" in *wa-x1*) ok "context kept for the later page" ;; *) bad "context lost: [$GATE_FAIL_MAYOR_DEFER_CTX]" ;; esac

echo "== 3. flag ON but a real candidate answers: delivered, nothing deferred"
reset; GATE_FAIL_DEFER_MAYOR=1; FAIL_RECIPIENTS="wa-worker"
nudge_author_with_fallback wa-x1 wa-worker mayor "msg" "$CTX"; rc=$?
eq "rig-qualified candidate reached" "$(trim "$NUDGE_LOG")" "wa-worker wa-worker-wa"
eq "delivered" "$rc" "0"
eq "nothing deferred" "$GATE_FAIL_MAYOR_DEFERRED" "0"

echo "== 4. flag ON, non-Mayor ephemeral author (a dog session): its own session stays a candidate"
reset; BEAD_CITY="$GC_CITY"; GATE_FAIL_DEFER_MAYOR=1; FAIL_RECIPIENTS="dog-gaabc"
nudge_author_with_fallback ga-x2 dog-gaabc dog-gaabc "msg" "Gate FAIL nudge for ga-x2"; rc=$?
eq "the dog session is nudged, the Mayor is not" "$(trim "$NUDGE_LOG")" "dog-gaabc"
eq "unreachable dog => deferred, no mail" "$GATE_FAIL_MAYOR_DEFERRED:$(trim "$MAIL_LOG")" "1:"
case "$BD_COMMENTS" in *"ga-x2:"*"NOT paged"*) ok "an HQ (ga-) bead's trace lands in the HQ store" ;; *) bad "ga-x2 trace lost: [$BD_LOST]" ;; esac

echo "== 4d. BEAD_CITY not resolved yet (a caller before resolution): falls back to HQ, never trips set -u"
reset; unset BEAD_CITY; GATE_FAIL_DEFER_MAYOR=1; FAIL_RECIPIENTS="dog-gaabc"
nudge_author_with_fallback ga-x7 dog-gaabc dog-gaabc "msg" "Gate FAIL nudge for ga-x7" >/dev/null
case "$BD_COMMENTS" in *"ga-x7:"*"NOT paged"*) ok "unset BEAD_CITY => the comment goes to the HQ store" ;; *) bad "ga-x7 trace lost with BEAD_CITY unset: [$BD_LOST]" ;; esac

echo "== 4b. the Mayor sentinel is the FIRST candidate when the branch is not crew/<name>/* (NOTIFY_AUTHOR falls back to AUTHOR)"
reset; GATE_FAIL_DEFER_MAYOR=1
nudge_author_with_fallback ga-x4 mayor mayor "msg" "Gate FAIL nudge for ga-x4"; rc=$?
eq "the Mayor is not nudged even as the first candidate" "$(trim "$NUDGE_LOG")" ""
eq "deferred, nothing mailed, reported undelivered" "$GATE_FAIL_MAYOR_DEFERRED:$(trim "$MAIL_LOG"):$rc" "1::1"
reset
nudge_author_with_fallback ga-x4 mayor mayor "msg" "Gate FAIL nudge for ga-x4" >/dev/null
eq "flag OFF: a real Mayor author is still nudged as before" "$(trim "$NUDGE_LOG")" "mayor"

echo "== 4e. when the sentinel filter EMPTIES the candidate list nothing was attempted — and the record must not claim a failure (gate round 3, low)"
reset; BEAD_CITY="$GC_CITY"; GATE_FAIL_DEFER_MAYOR=1
nudge_author_with_fallback ga-x8 mayor mayor "msg" "Gate FAIL nudge for ga-x8" >/dev/null
case "$BD_COMMENTS" in
  *"ga-x8:"*"No author candidate was nudged"*"nothing was attempted"*"Mayor was NOT paged"*) ok "an emptied list is recorded as 'nothing was attempted' (and the Mayor was NOT paged)" ;;
  *) bad "comment for an empty candidate list does not say nothing was attempted: [$BD_COMMENTS] (lost: [$BD_LOST])" ;;
esac
case "$BD_COMMENTS" in *"for every candidate ()"*) bad "the comment claims a FAILURE for '()' — nothing was tried" ;; *) ok "and it does not claim 'FAILED for every candidate ()'" ;; esac
case "$WARN_LINES" in *"author candidate (none)"*) ok "the warn line says (none), not ()" ;; *) bad "warn line still prints an empty list: [$WARN_LINES]" ;; esac
reset; BEAD_CITY="$GC_CITY"; GATE_FAIL_DEFER_MAYOR=1; FAIL_RECIPIENTS="dog-gaabc"
nudge_author_with_fallback ga-x9 dog-gaabc dog-gaabc "msg" "Gate FAIL nudge for ga-x9" >/dev/null
case "$BD_COMMENTS" in *"ga-x9:"*"Author-nudge FAILED for every candidate (dog-gaabc)"*) ok "a REAL failed attempt keeps the 'FAILED for every candidate (<list>)' wording" ;; *) bad "real failure lost its wording: [$BD_COMMENTS]" ;; esac

echo "== 4c. the WHOLE Mayor-sentinel family: for a non-ga bead the cascade also builds mayor-<prefix> (e.g. mayor-wa)"
reset; GATE_FAIL_DEFER_MAYOR=1
nudge_author_with_fallback wa-x6 mayor mayor "msg" "Gate FAIL nudge for wa-x6"; rc=$?
eq "neither mayor nor the rig-qualified mayor-wa is nudged" "$(trim "$NUDGE_LOG")" ""
eq "deferred, nothing mailed, reported undelivered" "$GATE_FAIL_MAYOR_DEFERRED:$(trim "$MAIL_LOG"):$rc" "1::1"
reset; FAIL_RECIPIENTS="mayor"
nudge_author_with_fallback wa-x6 mayor mayor "msg" "Gate FAIL nudge for wa-x6" >/dev/null
eq "flag OFF: both sentinel forms are still tried, as before" "$(trim "$NUDGE_LOG")" "mayor mayor-wa"

echo "== 5. a NAMED crew that is unreachable still escalates to the Mayor immediately (flag never set for it)"
reset; FAIL_RECIPIENTS="thies thies-wa"
nudge_author_with_fallback wa-x3 thies thies-wa "msg" "Gate FAIL nudge for wa-x3" >/dev/null
case "$(trim "$MAIL_LOG")" in *mayor*) ok "named-crew total failure still mails the Mayor" ;; *) bad "named-crew failure did not escalate: [$MAIL_LOG]" ;; esac
case "$BD_COMMENTS" in *"wa-x3:"*"escalated to mayor by mail"*) ok "and its 'escalated to mayor' trace lands in the bead's OWN store (pre-existing twin of blocking 1)" ;; *) bad "escalation trace for wa-x3 lost (lost: [$BD_LOST]; landed: [$BD_COMMENTS])" ;; esac

echo "== 6. gate_fail_author_is_ephemeral reuses the canonical pool deny-list"
for a in mayor gastown.mayor gastown__mayor dog-gaabc gastown.dog gastown.dog-2 wa-worker wa-worker-adhoc-1 ps-worker ps-worker-3; do
  gate_fail_author_is_ephemeral "$a" && ok "$a is ephemeral" || bad "$a should be ephemeral"
done
for a in thies-wa batista-wa oracle-wa peter-wa mila-wa digo-wa ""; do
  gate_fail_author_is_ephemeral "$a" && bad "[$a] must NOT be ephemeral" || ok "[$a] is not ephemeral"
done

echo "== 7. the predicate reads a bd show taken AFTER the writes and needs ALL FIVE pool-probe facts (blocking 2a)"
# The pool probe needs: routed to the pool, unassigned, status open, no gate:queued, no gate:reviewing.
# Round 1 checked only the first two — from a read taken BEFORE --status open / label remove gate:queued —
# so one swallowed write left the bead invisible to the pool AND kept the Mayor silent.
bj() {   # bj <route> <assignee|""> <status> <labels-json-array> -> a `bd show --json` array holding one bead
  jq -cn --arg r "$1" --arg a "$2" --arg s "$3" --argjson l "$4" \
    '[{id:"wa-x1", status:$s, assignee:(if $a=="" then null else $a end), labels:$l, metadata:{"gc.routed_to":$r}}]'
}
F() { gate_fail_pool_read_facts "$@"; }
V() { gate_fail_redispatch_verified "$@"; }
CLEAN="$(bj wa-worker "" open '["gate:needs-fix","ctx:ready"]')"
eq "facts: everything holds"                                   "$(F "$CLEAN" wa-worker)" "ok"
eq "facts: object form (not wrapped in an array) reads the same" "$(F "$(printf '%s' "$CLEAN" | jq -c '.[0]')" wa-worker)" "ok"
eq "facts: labels null is fine"                                "$(F "$(printf '%s' "$CLEAN" | jq -c '.[0].labels=null')" wa-worker)" "ok"
eq "facts: status still in_progress (the --status open write was swallowed)" "$(F "$(bj wa-worker "" in_progress '["gate:needs-fix"]')" wa-worker)" "status"
eq "facts: gate:queued still on it (the label-remove write was swallowed)"   "$(F "$(bj wa-worker "" open '["gate:queued"]')" wa-worker)" "queued"
eq "facts: gate:reviewing still on it"                         "$(F "$(bj wa-worker "" open '["gate:reviewing"]')" wa-worker)" "reviewing"
eq "facts: assignee re-claimed"                                "$(F "$(bj wa-worker "dog-gaabc" open '[]')" wa-worker)" "assignee"
eq "facts: route not restored / different route"               "$(F "$(bj "" "" open '[]')" wa-worker):$(F "$(bj gastown.dog "" open '[]')" wa-worker)" "route:route"
eq "facts: several wrong at once are all named, in a stable order" "$(F "$(bj wa-worker "" in_progress '["gate:queued","gate:reviewing"]')" wa-worker)" "status queued reviewing"
for bad_read in "" "not json" '{"error":"no issue found matching wa-x1"}' "[]" "null" '"a string"' "42"; do
  eq "facts: unreadable [${bad_read:-empty}] is 'unread', never 'ok'" "$(F "$bad_read" wa-worker)" "unread"
done
eq "facts: no route to judge against is 'unread'"              "$(F "$CLEAN" "")" "unread"
eq "verified: clean re-read, resolved route, evaluated fail"   "$(V "$CLEAN" wa-worker 0 0)" "1"
eq "verified: status still in_progress => 0"                   "$(V "$(bj wa-worker "" in_progress '[]')" wa-worker 0 0)" "0"
eq "verified: gate:queued still present => 0"                  "$(V "$(bj wa-worker "" open '["gate:queued"]')" wa-worker 0 0)" "0"
eq "verified: gate:reviewing still present => 0"               "$(V "$(bj wa-worker "" open '["gate:reviewing"]')" wa-worker 0 0)" "0"
eq "verified: assignee held => 0"                              "$(V "$(bj wa-worker "dog-gaabc" open '[]')" wa-worker 0 0)" "0"
eq "verified: read failed / unparseable => 0"                  "$(V "" wa-worker 0 0):$(V '{"error":"no issue found"}' wa-worker 0 0)" "0:0"
eq "verified: route was a GUESS (home store not resolved) => 0" "$(V "$(bj gastown.dog "" open '[]')" gastown.dog 1 0)" "0"
eq "verified: reviewer-TIMEOUT run (no evaluation) => 0 even on a clean read (blocking 2c)" "$(V "$CLEAN" wa-worker 0 1)" "0"
eq "verified: no_eval argument omitted => 0 (an unknown never reads as 'evaluated')" "$(V "$CLEAN" wa-worker 0)" "0"
eq "verified: route_unknown omitted => 0"                      "$(V "$CLEAN" wa-worker)" "0"
# no_eval is given explicitly (0) below so ITS default cannot mask a wrong route_unknown default:
eq "verified: route_unknown EMPTY with an evaluated fail => 0 (the default means 'route was guessed')" "$(V "$CLEAN" wa-worker "" 0)" "0"
eq "verified: no_eval EMPTY with a resolved route => 0 (the default means 'no evaluation')"          "$(V "$CLEAN" wa-worker 0 "")" "0"
eq "verified: empty arguments never verify"                    "$(V '' '' '' '')" "0"

echo "== 7b. the OTHER things the pool probe refuses: a 'vetoed' fact (gate round 3, blocking 2)"
# Round 2 decided "returns to the pool by itself" from five facts, but the probe refuses many more: a bead
# labelled pilot:no-auto-dispatch / needs-human / pool:refused:* passed as VERIFIED and the Mayor stayed
# asleep about a bead that neither the pool probe nor the Pilot can ever pick up — a silent strand.
# Fixture = the state a gate-FAILED source bead is really in (this very bead's labels), plus ONE veto.
REALL='["ctx:ready","exec:auto","framework","gate-sha-failed:2ba4a0deb:code","gate:failed","gate:fix-attempt:2","gate:needs-fix","lane:small"]'
REAL="$(bj wa-worker "" open "$REALL")"
eq "a real gate-FAILED bead (gate:needs-fix, gate:failed, gate-sha-failed:*, gate:fix-attempt:*) is NOT vetoed" "$(F "$REAL" wa-worker)" "ok"
eq "  ...and is VERIFIED" "$(V "$REAL" wa-worker 0 0)" "1"
veto_case() {   # veto_case <label> [route]  -> facts and verified for the real bead + that one extra label
  local lab="$1" rt="${2:-wa-worker}" j
  j="$(bj "$rt" "" open "$(printf '%s' "$REALL" | jq -c --arg l "$lab" '. + [$l]')")"
  eq "facts: +$lab => vetoed"  "$(F "$j" "$rt")" "vetoed"
  eq "verified: +$lab => 0 (the Mayor is paged, not left asleep)" "$(V "$j" "$rt" 0 0)" "0"
}
veto_case pilot:no-auto-dispatch
veto_case needs-human
veto_case story:needs-approval
veto_case exec:manual
veto_case ctx:thin
veto_case story:blocked
veto_case needs:engine-window
veto_case pool:refused:engine-rebuild-required
veto_case pilot:refused-reason:scope
veto_case pilot:text-veto:engine-rebuild
veto_case gate:needs-human:technical
veto_case blocked:dependency
veto_case blocked-reason:decision
veto_case delivery:partial                 # only the DOG probe refuses it
veto_case delivery:pending-restart         # only the wa/ps probes refuse it
veto_case next-action:mayor
veto_case pilot:held
veto_case "pilot:held-until:$((GATE_FAIL_NOW + 600))"
veto_case pilot:no-auto-dispatch gastown.dog
veto_case needs-human ps-worker
eq "an EXPIRED pilot:held-until released the hold => still verified" "$(V "$(bj wa-worker "" open "$(printf '%s' "$REALL" | jq -c --arg l "pilot:held-until:$((GATE_FAIL_NOW - 600))" '. + [$l]')")" wa-worker 0 0)" "1"
eq "refino's ROUTING suffix (next-action:<crew>-constroi) is not a veto => still verified" "$(V "$(bj wa-worker "" open "$(printf '%s' "$REALL" | jq -c '. + ["next-action:batista-constroi"]')")" wa-worker 0 0)" "1"
eq "an EPIC-typed bead is vetoed" "$(F "$(printf '%s' "$REAL" | jq -c '.[0].issue_type="epic"')" wa-worker)" "vetoed"
eq "an EPIC:-titled bead is vetoed" "$(F "$(printf '%s' "$REAL" | jq -c '.[0].title="EPIC: migrar tudo"')" wa-worker)" "vetoed"
eq "several things wrong at once: all named, vetoed last (stable order)" "$(F "$(bj wa-worker "" in_progress '["gate:queued","needs-human"]')" wa-worker)" "status queued vetoed"
eq "gate:queued / gate:reviewing are reported ONCE (as queued / reviewing), not again as vetoed" "$(F "$(bj wa-worker "" open '["gate:queued","gate:reviewing"]')" wa-worker)" "queued reviewing"
eq "a wrong route AND a veto are both named" "$(F "$(bj gastown.dog "" open '["pilot:no-auto-dispatch"]')" wa-worker)" "route vetoed"
R="$(gate_fail_pool_veto_reasons "$(bj wa-worker "" open '["gate:needs-fix","pilot:no-auto-dispatch","pool:refused:x"]')")"
eq "veto reasons (wording only) name the labels" "$R" "label:pilot:no-auto-dispatch,prefix:pool:refused:x"
eq "veto reasons: nothing for a clean bead / unreadable input (empty, never a claim)" "$(gate_fail_pool_veto_reasons "$REAL")|$(gate_fail_pool_veto_reasons '')|$(gate_fail_pool_veto_reasons 'not json')" "||"

grep -qE '^_GATE_VETO_LIB_DIR="\$\(cd .*\)/scripts" \|\| true$' "$DISPATCHER" \
  && ok "the lib-dir assignment cannot errexit the daemon (|| true; the [ -r ] guard then reads it as 'no lib')" \
  || bad "the _GATE_VETO_LIB_DIR assignment is not guarded with || true — a failed cd would kill the set -e dispatcher"
echo "== 7c. the veto lib cannot be loaded => 'unread' (=> the Mayor is paged), never 'no vetoes' (ga-q4sadt: a bare source of a missing file kills the daemon)"
NOLIB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gate-defer-nolib.XXXXXX")"
OUT="$(bash -c 'set -euo pipefail; _GATE_VETO_LIB_DIR="$1"; eval "$2"; echo REACHED' _ "$NOLIB_DIR" "$POOL_VETO_LOAD_BODY" 2>&1)"
eq "the live load block, with the lib ABSENT, survives set -euo pipefail (no bare source)" "$OUT" "REACHED"
OUT="$(bash -c 'set -euo pipefail; _GATE_VETO_LIB_DIR="$1"; eval "$2"; echo REACHED' _ "$(dirname "$DISPATCHER")/scripts" "$POOL_VETO_LOAD_BODY" 2>&1)"
eq "the live load block, with the lib PRESENT, survives set -euo pipefail and prints nothing else" "$OUT" "REACHED"
# run the real predicate in a shell where the lib was never loaded
FACTS_BODY="$(extract_fn "$DISPATCHER" gate_fail_pool_read_facts)"; VER_BODY="$(extract_fn "$DISPATCHER" gate_fail_redispatch_verified)"
OUT="$(bash -c 'eval "$1"; eval "$2"; printf "%s|%s" "$(gate_fail_pool_read_facts "$3" wa-worker)" "$(gate_fail_redispatch_verified "$3" wa-worker 0 0)"' _ "$FACTS_BODY" "$VER_BODY" "$REAL" 2>&1)"
eq "lib absent: even a perfectly clean bead is 'unread' and NOT verified" "$OUT" "unread|0"
rmdir "$NOLIB_DIR" 2>/dev/null || true

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
case "$BD_COMMENTS" in *"wa-x1:"*"Mayor PAGED"*) ok "and the bead records that the Mayor was paged" ;; *) bad "no bd comment reached wa-x1 (lost: [$BD_LOST]; landed: [$BD_COMMENTS])" ;; esac
eq "the paging comment went to the bead's OWN store, none lost to HQ (blocking 1)" "$BD_LOST" ""
eq "settle is one-shot (flag cleared)" "$GATE_FAIL_MAYOR_DEFERRED" "0"
MAIL_LOG=""; gate_fail_settle_deferred_mayor_wake
eq "a second settle pages nobody" "$(trim "$MAIL_LOG")" ""
reset; gate_fail_settle_deferred_mayor_wake
eq "nothing deferred => settle is a no-op" "$(trim "$MAIL_LOG")|$BD_COMMENTS|$LOG_LINES" "||"
reset; BEAD_ID=""; GATE_FAIL_MAYOR_DEFERRED=1; GATE_FAIL_MAYOR_DEFER_CTX="$CTX"
gate_fail_settle_deferred_mayor_wake
eq "no bead id (nothing re-dispatchable) => the Mayor is paged" "$(trim "$MAIL_LOG")" "mayor"
# the page's mail can itself fail — the bead comment must say so instead of claiming a page (2b's twin)
reset; FAIL_RECIPIENTS="mail:mayor"; GATE_FAIL_MAYOR_DEFERRED=1; GATE_FAIL_MAYOR_DEFER_CTX="$CTX"
gate_fail_settle_deferred_mayor_wake
case "$BD_COMMENTS" in *"wa-x1:"*"Mayor page FAILED"*"nobody was woken"*) ok "mail to the Mayor failed => the comment says NOBODY was woken" ;; *) bad "comment does not admit the failed page: [$BD_COMMENTS]" ;; esac
case "$BD_COMMENTS" in *"Mayor PAGED"*) bad "comment claims a page that never went out: [$BD_COMMENTS]" ;; *) ok "and it does NOT claim 'Mayor PAGED'" ;; esac
case "$WARN_LINES" in *"Could not mail Mayor"*) ok "and the failure is warned in the log" ;; *) bad "no warn line: [$WARN_LINES]" ;; esac
# a veto the pool probe applies: the page names it (and the bead comment does too)
reset; GATE_FAIL_MAYOR_DEFERRED=1; GATE_FAIL_MAYOR_DEFER_CTX="$CTX"; GATE_FAIL_POOL_VETO_REASONS="label:pilot:no-auto-dispatch"
gate_fail_settle_deferred_mayor_wake
eq "a vetoed source bead => the Mayor is paged" "$(trim "$MAIL_LOG")" "mayor"
case "$MAIL_BODIES" in *"pool probe REFUSES"*"label:pilot:no-auto-dispatch"*"will pick it up by itself"*) ok "the mail body names the veto and why nothing will pick the bead up" ;; *) bad "body does not name the veto: [$MAIL_BODIES]" ;; esac
case "$BD_COMMENTS" in *"wa-x1:"*"Mayor PAGED"*"label:pilot:no-auto-dispatch"*) ok "and so does the bead comment" ;; *) bad "comment does not name the veto: [$BD_COMMENTS]" ;; esac
# reviewer-timeout (no-eval) FAIL: the cap never bounds that loop, so the page says so
reset; GATE_FAIL_NO_EVAL_RUN=1; GATE_FAIL_MAYOR_DEFERRED=1; GATE_FAIL_MAYOR_DEFER_CTX="$CTX"
gate_fail_settle_deferred_mayor_wake
eq "reviewer-timeout run (not verified) => the Mayor is paged as before" "$(trim "$MAIL_LOG")" "mayor"
case "$MAIL_BODIES" in *"reviewer TIMEOUT"*"does not advance"*) ok "the mail body names the real reason (timeout, counter does not advance)" ;; *) bad "body does not name the timeout reason: [$MAIL_BODIES]" ;; esac
case "$BD_COMMENTS" in *"wa-x1:"*"Mayor PAGED"*"reviewer TIMEOUT"*) ok "and so does the bead comment" ;; *) bad "comment does not name the timeout reason: [$BD_COMMENTS]" ;; esac
reset; GATE_FAIL_MAYOR_DEFERRED=1; GATE_FAIL_MAYOR_DEFER_CTX="$CTX"
gate_fail_settle_deferred_mayor_wake
case "$MAIL_BODIES" in *"reviewer TIMEOUT"*) bad "an evaluated FAIL must not be described as a timeout: [$MAIL_BODIES]" ;; *) ok "an evaluated FAIL is not described as a timeout" ;; esac

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
for v in GATE_FAIL_DEFER_MAYOR GATE_FAIL_MAYOR_DEFERRED GATE_FAIL_REDISPATCH_VERIFIED GATE_FAIL_CAP_ESCALATED GATE_FAIL_MAYOR_DEFER_CTX GATE_FAIL_MAYOR_DEFER_CANDIDATES GATE_FAIL_POOL_VETO_REASONS; do
  in_range "$L_RESET" "$L_ON" "^  ${v}=" && ok "FAIL-path entry resets $v (no leak between runs of one sweep)" || bad "FAIL-path entry does not reset $v"
done
in_range "$L_ON" "$L_CALL1" '^  if gate_fail_author_is_ephemeral "\$AUTHOR"; then GATE_FAIL_DEFER_MAYOR=1; fi' \
  && ok "defer switch is turned on only for an ephemeral author" || bad "defer-on line missing or not guarded by gate_fail_author_is_ephemeral"
in_range "$L_OFF" "$((${L_OFF:-0} + 3))" '^  GATE_FAIL_DEFER_MAYOR=0' \
  && ok "the defer switch is switched OFF right after the first nudge call" || bad "GATE_FAIL_DEFER_MAYOR is not reset right after the first nudge call"
# cap flag (blocking 2b): behaviour is proven on the extracted block in section 10; here only pin that
# NOTHING sets GATE_FAIL_CAP_ESCALATED=1 between its anchor comment and the escalation mail's `if`.
L_MAILIF="$(awk -v a="${L_CAP:-0}" 'NR>a && /if gc --city "\$GC_CITY" mail send mayor/ {print NR; exit}' "$DISPATCHER")"
L_CAPSET="$(awk -v a="${L_CAP:-0}" 'NR>a && /^ *GATE_FAIL_CAP_ESCALATED=1/ {print NR; exit}' "$DISPATCHER")"
{ [ -n "$L_MAILIF" ] && [ -n "$L_CAPSET" ] && [ "$L_MAILIF" -lt "$L_CAPSET" ]; } \
  && ok "the cap branch sets GATE_FAIL_CAP_ESCALATED only AFTER the escalation mail's own if (mail line $L_MAILIF < flag line $L_CAPSET)" \
  || bad "GATE_FAIL_CAP_ESCALATED=1 is set before the Mayor mail is attempted (mail if=$L_MAILIF, first flag=$L_CAPSET)"
# re-read (blocking 2a): the re-read must come AFTER both writes it has to see (--status open, gate:queued removal).
L_FR="$(lineof 'SELFTEST-EXTRACT gate-fail-final-reread: BEGIN')"
L_FRE="$(lineof 'SELFTEST-EXTRACT gate-fail-final-reread: END')"
L_RTE="$(awk 'NR>1 && /^ *_GFAIL_ROUTE=\$\(gate_fail_restore_route/ {print NR; exit}' "$DISPATCHER")"
L_STW="$(awk -v a="${L_RTE:-0}" -v b="${L_FR:-0}" 'NR>a && NR<b && /update +"\$BEAD_ID" --status open/ {n=NR} END {print n}' "$DISPATCHER")"
L_QRW="$(awk -v a="${L_RTE:-0}" -v b="${L_FR:-0}" 'NR>a && NR<b && /label remove +"\$BEAD_ID" "gate:queued"/ {n=NR} END {print n}' "$DISPATCHER")"
{ [ -n "$L_RTE" ] && [ -n "$L_STW" ] && [ -n "$L_QRW" ] && [ -n "$L_FR" ] && [ "$L_RTE" -lt "$L_STW" ] && [ "$L_RTE" -lt "$L_QRW" ] && [ "$L_STW" -lt "$L_FR" ] && [ "$L_QRW" -lt "$L_FR" ]; } \
  && ok "the post-write re-read (line $L_FR) comes after --status open (line $L_STW) and the gate:queued removal (line $L_QRW)" \
  || bad "the re-read is not after both writes (route=$L_RTE status-write=$L_STW queued-write=$L_QRW re-read=$L_FR)"
in_range "$L_FR" "$L_FRE" 'GATE_FAIL_REDISPATCH_VERIFIED=\$\(gate_fail_redispatch_verified "\$_GFAIL_FINAL_JSON" "\$_GFAIL_ROUTE" "\$_GFAIL_ROUTE_UNKNOWN" "\$\{GATE_FAIL_NO_EVAL_RUN:-1\}"\)' \
  && ok "VERIFIED is derived from the post-write re-read + route_unknown + no_eval (conservative default 1)" || bad "VERIFIED is not derived from the post-write re-read"
in_range "$L_FR" "$L_FRE" 'GATE_FAIL_POOL_VETO_REASONS=\$\(gate_fail_pool_veto_reasons "\$_GFAIL_FINAL_JSON"\)' \
  && ok "the veto reasons are read from the same post-write re-read as the facts" || bad "veto reasons are not derived from the post-write re-read"
in_range "$L_FR" "$((${L_FRE:-0} + 4))" '\$_GFAIL_VETO_NOTE"' \
  && ok "the FAIL comment on the bead carries the veto note" || bad "the FAIL comment does not carry \$_GFAIL_VETO_NOTE"
in_range "$L_SET" "$L_TERM" '^  gate_fail_settle_deferred_mayor_wake( \|\| true)?$' \
  && ok "the settle CALL is present and runs before the terminal FAIL notification" || bad "settle call missing between its anchor and the terminal FAIL block"
# the settle must stay INSIDE the FAIL path: it must come after the return-to-pool arm's comment
[ -n "$L_VER" ] && [ -n "$L_SET" ] && [ "$L_VER" -lt "$L_SET" ] && ok "settle comes after the re-dispatch verification" || bad "settle is not after the verification"

echo "== 10. cap escalation (blocking 2b): the settle is told 'already paged' only if the Mayor really was (LIVE extracted block)"
CAP_BODY="$(extract_block "$DISPATCHER" cap-escalation-mail)"
[ -n "$CAP_BODY" ] || { echo "FATAL: could not extract cap-escalation-mail from $DISPATCHER" >&2; exit 2; }
gate_needs_human_clause() { echo "clause($1)"; }
notify() { return 0; }
NAF_CALLS=0; notify_author_with_fallback() { NAF_CALLS=$((NAF_CALLS+1)); return 0; }
CAP_ERR="$(mktemp "${TMPDIR:-/tmp}/gate-defer-cap-err.XXXXXX")"; trap 'rm -f "$CAP_ERR"' EXIT
run_cap() {  # run_cap <SRC_LABELS as read when the FAIL began>; shell errors from the live block land in $CAP_ERR
  SRC_LABELS="$1"; _NH_STATUS="armed"; GATE_FIX_CAP=3; BRANCH="story/x"; RIG="gascity"; GATE_RUN_ID="ga-run"
  FAIL_REASONS="reason"; NOTIFY_AUTHOR="wa-worker"; AUTHOR="mayor"; NAF_CALLS=0
  eval "$CAP_BODY" 2>"$CAP_ERR"
}
reset; run_cap "gate:fix-attempt:3 gate:needs-fix"
eq "no needs-human yet, mail sent => flag set, one Mayor mail, author notified" "$GATE_FAIL_CAP_ESCALATED:$(trim "$MAIL_LOG"):$NAF_CALLS" "1:mayor:1"
# A variable typo inside the mail's $(printf ...) is swallowed by the command substitution: the mail still goes
# out, with an EMPTY or wrong body, and the flag/`sent` assertions above stay green. So read the body itself, and
# fail on any shell error the live block printed (an unbound variable under set -u lands here).
case "$MAIL_BODIES" in *"failed the quality gate 4 times"*) ok "the escalation body carries the real attempt count (GATE_FIX_CAP+1 = 4)" ;; *) bad "escalation body is empty/wrong: [$MAIL_BODIES]" ;; esac
eq "the live cap block printed no shell error (e.g. an unbound variable)" "$(cat "$CAP_ERR")" ""
reset; FAIL_RECIPIENTS="mail:mayor"; run_cap "gate:fix-attempt:3 gate:needs-fix"
eq "no needs-human yet, mail FAILED => flag NOT set (nobody was paged)" "$GATE_FAIL_CAP_ESCALATED" "0"
case "$WARN_LINES" in *"Could not mail Mayor escalation"*"NOT suppressed"*) ok "and the failure is warned, saying the deferred page is not suppressed" ;; *) bad "no warn line: [$WARN_LINES]" ;; esac
eq "the author notification is still attempted (behaviour unchanged)" "$NAF_CALLS" "1"
GATE_FAIL_MAYOR_DEFERRED=1; GATE_FAIL_MAYOR_DEFER_CTX="$CTX"; FAIL_RECIPIENTS=""; MAIL_LOG=""
gate_fail_settle_deferred_mayor_wake
eq "end to end: the cap mail failed, so the deferred page is NOT suppressed — the settle pages the Mayor" "$(trim "$MAIL_LOG")" "mayor"
reset; run_cap "gate:needs-fix gate:needs-human:technical"
eq "gate:needs-human already on the bead => no second cap mail, no second author mail (exactly-once, unchanged), flag NOT set: a label is not a page" "$GATE_FAIL_CAP_ESCALATED:$(trim "$MAIL_LOG"):$NAF_CALLS" "0::0"
eq "the live cap block printed no shell error in the else arm either" "$(cat "$CAP_ERR")" ""
GATE_FAIL_MAYOR_DEFERRED=1; GATE_FAIL_MAYOR_DEFER_CTX="$CTX"
gate_fail_settle_deferred_mayor_wake
eq "end to end: nothing proved a page, so the deferred page is NOT suppressed — the settle pages the Mayor (at worst twice, never zero)" "$(trim "$MAIL_LOG")" "mayor"
# and the verified-re-dispatch test cannot silence it either: gate:needs-human* is a pool-probe veto
reset; GATE_FAIL_MAYOR_DEFERRED=1; GATE_FAIL_MAYOR_DEFER_CTX="$CTX"
GATE_FAIL_REDISPATCH_VERIFIED="$(V "$(bj wa-worker "" open '["gate:needs-fix","gate:needs-human:technical"]')" wa-worker 0 0)"
gate_fail_settle_deferred_mayor_wake
eq "a bead left at gate:needs-human is never 'verified' back in the pool => the Mayor is paged" "$GATE_FAIL_REDISPATCH_VERIFIED:$(trim "$MAIL_LOG")" "0:mayor"

echo "== 11. return-to-pool arm (blocking 2a): the observations come from a re-read AFTER the writes (LIVE extracted block)"
FR_BODY="$(extract_block "$DISPATCHER" gate-fail-final-reread)"
[ -n "$FR_BODY" ] || { echo "FATAL: could not extract gate-fail-final-reread from $DISPATCHER" >&2; exit 2; }
run_fr() {  # run_fr <bd show json> <show rc> [assignee_obs] [no_eval] [bead_city]
  BD_SHOW_JSON="$1"; BD_SHOW_RC="$2"
  _GFAIL_ROUTE="wa-worker"; _GFAIL_ROUTE_UNKNOWN=0
  _GFAIL_ASSIGNEE_OBS="${3:-assignee=cleared}"
  if [ "$_GFAIL_ASSIGNEE_OBS" = "assignee=cleared" ]; then   # the arm that issued the reopen + gate:queued removal
    _GFAIL_STATUS_OBS="status=open"; _GFAIL_QUEUED_OBS="gate:queued=removed"                  # what it used to ASSERT
  else
    _GFAIL_STATUS_OBS="status=left untouched (x)"; _GFAIL_QUEUED_OBS="gate:queued=left untouched (x)"
  fi
  GATE_FAIL_NO_EVAL_RUN="${4:-0}"; BEAD_CITY="${5:-$WA_STORE}"; BEAD_ID="wa-x1"
  eval "$FR_BODY" 2>"$CAP_ERR"
}
reset; run_fr "$CLEAN" 0
eq "clean re-read => VERIFIED" "$GATE_FAIL_REDISPATCH_VERIFIED" "1"
eq "the live re-read block printed no shell error" "$(cat "$CAP_ERR")" ""
eq "clean re-read => the two observations are now READ, and say what was asserted before" "$_GFAIL_STATUS_OBS|$_GFAIL_QUEUED_OBS" "status=open|gate:queued=removed"
reset; run_fr "$(bj wa-worker "" in_progress '["gate:needs-fix","gate:queued"]')" 0
eq "both writes swallowed (re-read: in_progress + gate:queued) => NOT verified, the Mayor stays awake" "$GATE_FAIL_REDISPATCH_VERIFIED" "0"
case "$_GFAIL_STATUS_OBS" in *"NOT open"*"needs investigation"*) ok "status observation admits the reopen did not stick (was asserted 'status=open')" ;; *) bad "status observation still asserts: [$_GFAIL_STATUS_OBS]" ;; esac
case "$_GFAIL_QUEUED_OBS" in *"STILL PRESENT"*"needs investigation"*) ok "gate:queued observation admits the removal did not stick (was asserted 'removed')" ;; *) bad "queued observation still asserts: [$_GFAIL_QUEUED_OBS]" ;; esac
reset; run_fr "$(bj wa-worker "" in_progress '[]')" 0
eq "only the reopen swallowed => the queued observation stays truthful ('removed')" "$GATE_FAIL_REDISPATCH_VERIFIED:$_GFAIL_QUEUED_OBS" "0:gate:queued=removed"
reset; run_fr "$(bj wa-worker "" open '["gate:reviewing"]')" 0
eq "gate:reviewing left on => NOT verified (the probe excludes it), the two asserted observations untouched" "$GATE_FAIL_REDISPATCH_VERIFIED:$_GFAIL_STATUS_OBS|$_GFAIL_QUEUED_OBS" "0:status=open|gate:queued=removed"
reset; run_fr "" 1
eq "re-read FAILS => NOT verified" "$GATE_FAIL_REDISPATCH_VERIFIED" "0"
case "$_GFAIL_STATUS_OBS|$_GFAIL_QUEUED_OBS" in *"status=UNVERIFIED"*"gate:queued=UNVERIFIED"*) ok "and both observations say UNVERIFIED instead of asserting" ;; *) bad "unread state still asserted: [$_GFAIL_STATUS_OBS|$_GFAIL_QUEUED_OBS]" ;; esac
reset; run_fr "$CLEAN" 0 "assignee=cleared" 1
eq "reviewer-TIMEOUT run (no_eval=1) => NOT verified even on a clean re-read (blocking 2c)" "$GATE_FAIL_REDISPATCH_VERIFIED" "0"
reset; run_fr "$CLEAN" 0 "assignee=cleared" 0 "$GC_CITY"
eq "asking the WRONG store (HQ, for a wa- bead) => 'no issue found' => NOT verified" "$GATE_FAIL_REDISPATCH_VERIFIED" "0"
reset; run_fr "$(bj wa-worker "" in_progress '[]')" 0 "assignee='dog-x' NOT cleared — a different actor claimed it before the clear could apply"
eq "first read said 'not cleared' (writes never issued) + re-read still wrong => NOT verified, observations left as the arm set them" "$GATE_FAIL_REDISPATCH_VERIFIED:$_GFAIL_STATUS_OBS" "0:status=left untouched (x)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
