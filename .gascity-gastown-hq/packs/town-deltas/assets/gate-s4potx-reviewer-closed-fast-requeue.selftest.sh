#!/usr/bin/env bash
# gate-s4potx-reviewer-closed-fast-requeue.selftest.sh (ga-s4potx)
#
# Proves: when EVERY still-pending verdict slot of an in-flight gate-run has
# its reviewer session bead CONFIRMED CLOSED (status=closed — a terminal,
# no-debounce signal), Phase C re-queues the run on the VERY NEXT sweep
# instead of waiting out the full VERDICT_TIMEOUT_MINUTES (15-50m).
#
# INCIDENT (Mayor, 2026-09-18, quality-gate-dispatcher.log): while the
# session supervisor was stalled (20:37-21:31, Dolt i/o timeout under swap —
# see wa-9c620), three gate-runs' requested reviewers never started
# (start-pending, wake_attempts=0). gate-reviewer-orphan-clear closed one
# session as dead at 21:21:23, but the run wasn't re-queued until its outer
# timeout fired at 21:37:25 — 16 minutes AFTER the session's death was
# already confirmed, 26-43 minutes total per run, ~1h with nothing evaluated.
#
# ROOT CAUSE: ga-eqjo (the non-blocking dispatcher rewrite) deliberately
# dropped the old poll loop's mid-collection dead-reviewer reconvene — its
# debounce state (SLOT_DEAD_STREAK) lived in process-local bash arrays that
# don't survive a sweep starting a fresh process. The dispatcher's own
# comment (~L7987, ga-eqjo) accepted this as "a rare failure mode is just
# detected slower" — true for AMBIGUOUS deadness (absent-from-list, wedged,
# slow), which genuinely needs a debounce/grace window to avoid false
# positives (ga-wcd86: a session can sit minutes in start-pending and still
# come up alive). But an EXPLICIT session-bead close is not ambiguous — it
# cannot revert — so it needs no debounce at all, and Phase C had no path to
# act on it before the outer timeout.
#
# FIX: quality-gate-dispatcher.sh gains two new pieces —
#   1. reviewer_session_confirmed_closed() — pure predicate: 1 iff the
#      assignee is PRESENT in `gc session list --json` with .closed==true.
#      0 for every other case, INCLUDING absent-from-the-list-entirely (the
#      ga-wcd86 false-positive class this deliberately does NOT trigger on).
#   2. gate_phase_c_all_pending_closed() — classifies whether ALL of a run's
#      still-pending verdict slots satisfy (1) above, fail-closed (returns
#      false) on any unreadable state (root-class:error-vs-empty).
# A new `elif gate_phase_c_all_pending_closed` branch sits between the
# "verdicts complete" and "timed out" branches in Phase C's per-run decision,
# reusing the EXACT SAME QUOTA_REQUEUE=1/REQUEUE_REASON=dead-reviewer/
# gate_finalize_run contract the timeout branch's own dead-reviewer case
# already uses — so this is a NEW TRIGGER for existing, already-proven
# requeue machinery, not new requeue behavior.
#
# Strategy (follows this repo's established SELFTEST-EXTRACT convention —
# see gate-phase-c-empty-verdict-unbound.selftest.sh): extract the live
# "phase-c-verdict-decision" block (the whole per-run if/elif/elif/else) plus
# its two new dependency functions, run them verbatim under a real
# `set -euo pipefail` on this host's actual /bin/bash, with bd/gc/warn/log/
# gate_finalize_run stubbed. Three scenarios map 1:1 to the bead's own
# acceptance criteria:
#   1. THE BUG: only reviewer's session bead CLOSED, verdict still pending,
#      elapsed well under timeout -> must re-queue NOW (fails on pre-fix
#      code: nothing acts before the timeout branch, which isn't reached).
#   2. NON-REGRESSION: session absent from the roster (start-pending, not
#      yet created) -> must keep waiting, exactly as before this fix
#      (ga-wcd86 — absence is NOT confirmed-closed).
#   3. NON-REGRESSION: verdict already recorded (bead closed) even though
#      that reviewer's session later closed too -> must finalize by the
#      VERDICT, never by the requeue path.
# A dedicated section 0 unit-tests reviewer_session_confirmed_closed() in
# isolation first, since every other assertion depends on its correctness.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
REAL_BASH="/bin/bash"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-s4potx-reviewer-closed-fast-requeue.selftest =="

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi
if [ ! -x "$REAL_BASH" ]; then
  echo "FATAL: $REAL_BASH not found — cannot test against the host's actual bash" >&2
  exit 2
fi

# extract_block <file> <sentinel-name> -> prints the block between BEGIN/END,
# stripped of the sentinel comment lines themselves.
extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

echo "── 0. Unit tests: reviewer_session_confirmed_closed() pure predicate ──"
FN_CLOSED="$(extract_block "$DISPATCHER" "reviewer-session-confirmed-closed-fn")"
if [ -z "$FN_CLOSED" ]; then
  bad "could not extract reviewer-session-confirmed-closed-fn block — has the sentinel moved/renamed?"
else
  run_predicate() {
    # run_predicate <assignee> <sessions_json>
    "$REAL_BASH" -c '
      set -euo pipefail
      '"$FN_CLOSED"'
      reviewer_session_confirmed_closed "$1" "$2"
    ' _ "$1" "$2"
  }
  R="$(run_predicate "gate-reviewer-adhoc-1" '{"sessions":[{"session_name":"gate-reviewer-adhoc-1","closed":true,"state":"asleep"}]}' 2>&1)"
  [ "$R" = "1" ] && ok "present + closed=true -> 1" || bad "present + closed=true -> got '$R', expected 1"

  R="$(run_predicate "gate-reviewer-adhoc-1" '{"sessions":[{"session_name":"gate-reviewer-adhoc-1","closed":false,"state":"creating"}]}' 2>&1)"
  [ "$R" = "0" ] && ok "present + closed=false (booting) -> 0 (ga-wcd86 must not fire here)" || bad "present + closed=false -> got '$R', expected 0"

  R="$(run_predicate "gate-reviewer-adhoc-1" '{"sessions":[]}' 2>&1)"
  [ "$R" = "0" ] && ok "absent from the list entirely -> 0 (NOT treated as confirmed-closed)" || bad "absent -> got '$R', expected 0"

  R="$(run_predicate "" '{"sessions":[{"session_name":"x","closed":true}]}' 2>&1)"
  [ "$R" = "0" ] && ok "empty assignee -> 0" || bad "empty assignee -> got '$R', expected 0"

  R="$(run_predicate "gate-reviewer-adhoc-1" 'not-json{{{' 2>&1)"
  [ "$R" = "0" ] && ok "unparseable sessions_json -> 0 (fail-safe, never crashes)" || bad "malformed JSON -> got '$R', expected 0"
fi

# run_decision <required> <elapsed> <timeout_secs> <received> <any_fail> <vb_status> <sess_json> <log-file>
# Extracts the live "phase-c-verdict-decision" block plus its two dependency
# functions from $DISPATCHER and runs them under a real `set -euo pipefail`,
# with bd/gc_json_or_unknown/warn/log/gate_finalize_run stubbed. Single
# verdict slot (VERDICT_BEAD_IDS=(vb-1), SESSION_IDS=(fake-session-1)) covers
# every scenario this test needs; the pre-existing
# gate-phase-c-dead-reviewer-classify-fn suite already exercises the
# multi-reviewer/partial-pending shape for the sibling timeout-gated check.
run_decision() {
  local required="$1" elapsed="$2" timeout_secs="$3" received="$4" any_fail="$5" \
        vb_status="$6" sess_json="$7" log="$8"
  local fn_closed fn_classify decision
  fn_closed="$(extract_block "$DISPATCHER" "reviewer-session-confirmed-closed-fn")"
  fn_classify="$(extract_block "$DISPATCHER" "phase-c-closed-reviewer-classify-fn")"
  decision="$(extract_block "$DISPATCHER" "phase-c-verdict-decision")"
  if [ -z "$fn_closed" ] || [ -z "$fn_classify" ] || [ -z "$decision" ]; then
    echo "COULD_NOT_EXTRACT_BLOCK fn_closed=${#fn_closed} fn_classify=${#fn_classify} decision=${#decision}" >&2
    return 99
  fi
  : > "$log"
  "$REAL_BASH" -c '
    set -euo pipefail
    GC_CITY="/fake/city"; GATE_RUN_ID="test-run-1"; BRANCH="fake-branch"
    REQUIRED_REVIEWERS="$1"; PC_ELAPSED="$2"; PC_TIMEOUT_SECS="$3"
    VERDICTS_RECEIVED="$4"; ANY_FAIL="$5"; PC_TIMEOUT_MIN=15
    VB_STATUS_STUB="$6"; SESS_JSON_STUB="$7"; LOG="$8"
    VERDICT_BEAD_IDS=(vb-1); SESSION_IDS=(fake-session-1)
    QUOTA_REQUEUE=0; REQUEUE_REASON="quota"

    bd() {
      case " $* " in
        *" show vb-1 "*) echo "{\"status\":\"$VB_STATUS_STUB\"}"; return 0 ;;
      esac
      echo "bd:$*" >> "$LOG"; return 0
    }
    gc_json_or_unknown() { printf "%s" "$SESS_JSON_STUB"; return 0; }
    warn() { echo "warn:$*" >> "$LOG"; }
    log()  { echo "log:$*" >> "$LOG"; }
    gate_finalize_run() {
      echo "finalize_called:QUOTA_REQUEUE=${QUOTA_REQUEUE}:REQUEUE_REASON=${REQUEUE_REASON}:OVERALL_VERDICT=${OVERALL_VERDICT:-unset}" >> "$LOG"
    }

    '"$fn_closed"'
    '"$fn_classify"'

    for _dummy in 1; do
      '"$decision"'
    done
    echo "REACHED_END" >> "$LOG"
  ' _ "$required" "$elapsed" "$timeout_secs" "$received" "$any_fail" "$vb_status" "$sess_json" "$log"
  return $?
}

echo "── 1. THE BUG: reviewer session bead CLOSED, verdict pending, elapsed << timeout -> must re-queue NOW ──"
LOG1="$(mktemp)"
SESS_CLOSED='{"sessions":[{"session_name":"fake-session-1","closed":true,"state":"asleep"}]}'
OUT1="$(run_decision 1 60 900 0 0 open "$SESS_CLOSED" "$LOG1" 2>&1)"
RC1=$?
echo "$OUT1" | sed 's/^/    [closed-session] /'
if [ "$RC1" -eq 0 ]; then
  ok "block exits 0"
else
  bad "block exited $RC1 (expected 0) — log: $(tr '\n' ';' < "$LOG1")"
fi
if grep -q "^finalize_called:QUOTA_REQUEUE=1:REQUEUE_REASON=dead-reviewer" "$LOG1"; then
  ok "re-queued via dead-reviewer path WITHOUT waiting for the timeout (elapsed=60s, timeout=900s) — THIS IS THE FIX"
else
  bad "did NOT re-queue before timeout — log: $(tr '\n' ';' < "$LOG1") (on pre-fix HEAD this is the expected/documented failure — see bead ga-s4potx acceptance criterion 1)"
fi
rm -f "$LOG1"

echo "── 2. NON-REGRESSION: session absent (start-pending, not yet created) -> must keep waiting ──"
LOG2="$(mktemp)"
SESS_ABSENT='{"sessions":[]}'
OUT2="$(run_decision 1 60 900 0 0 open "$SESS_ABSENT" "$LOG2" 2>&1)"
RC2=$?
echo "$OUT2" | sed 's/^/    [start-pending] /'
if [ "$RC2" -eq 0 ]; then
  ok "block exits 0"
else
  bad "block exited $RC2 (expected 0) — log: $(tr '\n' ';' < "$LOG2")"
fi
if grep -q "^finalize_called:" "$LOG2"; then
  bad "re-queued/finalized a run whose reviewer session is merely absent (still start-pending, ga-wcd86) — false positive: $(tr '\n' ';' < "$LOG2")"
else
  ok "did NOT re-queue — correctly left in flight (log: $(tr '\n' ';' < "$LOG2"))"
fi
if grep -q "still in flight" "$LOG2"; then
  ok "logged the normal 'still in flight' message, unchanged from before this fix"
else
  bad "expected 'still in flight' log line not found — log: $(tr '\n' ';' < "$LOG2")"
fi
rm -f "$LOG2"

echo "── 3. NON-REGRESSION: verdict already recorded, reviewer's session later closed -> finalize by VERDICT, never requeue ──"
LOG3="$(mktemp)"
OUT3="$(run_decision 1 60 900 1 0 closed "$SESS_CLOSED" "$LOG3" 2>&1)"
RC3=$?
echo "$OUT3" | sed 's/^/    [verdict-recorded] /'
if [ "$RC3" -eq 0 ]; then
  ok "block exits 0"
else
  bad "block exited $RC3 (expected 0) — log: $(tr '\n' ';' < "$LOG3")"
fi
if grep -q "^finalize_called:QUOTA_REQUEUE=0:REQUEUE_REASON=quota:OVERALL_VERDICT=PASS" "$LOG3"; then
  ok "finalized via the VERDICT path (OVERALL_VERDICT=PASS, requeue fields untouched) — never mistaken for a dead-reviewer requeue"
else
  bad "did not finalize via the verdict path as expected — log: $(tr '\n' ';' < "$LOG3")"
fi
if grep -q "REQUEUE_REASON=dead-reviewer" "$LOG3"; then
  bad "incorrectly took the dead-reviewer requeue path for a run whose verdict was already delivered"
else
  ok "REQUEUE_REASON never became dead-reviewer for an already-delivered verdict"
fi
rm -f "$LOG3"

echo ""
echo "== gate-s4potx-reviewer-closed-fast-requeue: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
