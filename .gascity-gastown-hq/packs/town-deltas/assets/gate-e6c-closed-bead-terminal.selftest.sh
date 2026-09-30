#!/usr/bin/env bash
# gate-e6c-closed-bead-terminal.selftest.sh (ga-5w2gpw item c, 2026-09-30)
#
# CLASS: a review-approved PASS whose SOURCE BEAD was closed while the run was in flight
# (another branch or a human resolved it: ga-lxz5w's "sequential 2-branch race") used to be
# downgraded to a FAIL — then down the whole FAIL path: a "GATE-FEEDBACK … Fix THESE specific
# blocking issues" comment on a CLOSED bead, a gate:failed label, a hold-class SHA stamp, a
# fix-attempt accounting decision, an author nudge. There is nothing to fix: the reviewers
# approved this code and the bead it answered is already done. E4 counted 17 of the 207
# no-review FAILs as exactly this ("bead já fechada").
#
# FIX under test: a bead that is already CLOSED — seen by the early live re-check (Step 10) or by
# the authoritative one right before the push (do_merge_ff, ga-360a7l) — ends the run as a TERMINAL
# SKIP, not a FAIL. Nothing is merged (that part of ga-lxz5w stands: never merge onto a terminal
# bead). The run says so honestly: one audit comment on the source bead that is NOT a verdict
# (it must not start with GATE-FEEDBACK — E4 and the Pilot read that prefix as a verdict), the marker
# is closed as SUPERSEDED with a reason that says the branch was NOT merged, the gate-run is
# superseded and closed, gate:reviewing is cleared, and the run is logged as
# dispatcher_complete result=SKIPPED_BEAD_CLOSED (gate-health-monitor counts it as progress, and it
# is neither a PASS nor a FAIL).
#
# What must NOT change: a park:* label (needs-approval / withdraw / needs-human) is a human HOLD, not a
# terminal bead — it still downgrades to FAIL exactly as before; an UNREADABLE bead (bd show failed) is
# a third state and never reads as closed; and a late "closed" flag left over from another run must not
# hijack an unrelated merge failure.
#
# Strategy (this repo's SELFTEST-EXTRACT convention): the early re-check block is extracted from the LIVE
# dispatcher between its two stable comment anchors, and the late block by sentinel, then run in-process
# against stubs (bd/notify/log/warn/set_gate_status/gate_bead_live_merge_block). The helper function is
# sourced lib-only. Every case runs under `set -e` like the dispatcher. bash 3.2 compatible.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
# has <haystack> <needle>: a `case` match, not `printf | grep -q` (SIGPIPE under pipefail made that flaky).
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

echo "== gate-e6c-closed-bead-terminal.selftest =="
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
if /bin/bash -n "$DISPATCHER" 2>/dev/null; then ok "dispatcher parses under /bin/bash (3.2)"; else bad "dispatcher does NOT parse under /bin/bash 3.2"; fi

GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode" >&2; exit 2; }
set +e

MARKER_ID="m-e6c"; BEAD_ID="bead-e6c"; BEAD_CITY="bead-city"; GC_CITY="gc-city"
GATE_RUN_ID="gr-e6c"; BRANCH="crew/x/bead-e6c"; BRANCH_SHA="0123456789abcdef0123456789abcdef01234567"
RIG="whatsapp_automation"; ELAPSED_S=42; DRY_RUN=0

new_case() {
  BD_LOG=""; WARN_LOG=""; LOG_LOG=""; STATUS_LOG=""; NOTIFY_LOG=""; COMMENT_LOG=""; CLOSE_LOG=""
  LABEL_LOG=""; MARKER_SET_RC=0; CLOSE_RC=0
  QG_LOG="$(mktemp "${TMPDIR:-/tmp}/e6c-qg.XXXXXX")"
}
bd() {
  BD_LOG="$BD_LOG|$*"
  case "${3:-}" in
    comment) COMMENT_LOG="$COMMENT_LOG|${2:-}@${4:-}: ${5:-}"; return 0 ;;
    close)   CLOSE_LOG="$CLOSE_LOG|${2:-}@${4:-}: ${6:-}"; return "$CLOSE_RC" ;;
    label)   LABEL_LOG="$LABEL_LOG|${2:-}@${4:-} ${5:-} ${6:-}"; return 0 ;;
  esac
  return 0
}
set_gate_status() {
  STATUS_LOG="$STATUS_LOG|$1:$2"
  [ "$1" = "$MARKER_ID" ] && [ "$MARKER_SET_RC" != "0" ] && return "$MARKER_SET_RC"
  return 0
}
warn()   { WARN_LOG="$WARN_LOG|$*"; return 0; }
log()    { LOG_LOG="$LOG_LOG|$*"; return 0; }
err()    { WARN_LOG="$WARN_LOG|ERR:$*"; return 0; }
notify() { NOTIFY_LOG="$NOTIFY_LOG|$*"; return 0; }
dump_state() {
  echo "STATUS=$STATUS_LOG"; echo "COMMENTS=$COMMENT_LOG"; echo "CLOSES=$CLOSE_LOG"; echo "LABELS=$LABEL_LOG"
  echo "NOTIFY=$NOTIFY_LOG"; echo "WARN=$WARN_LOG"; echo "LOG=$LOG_LOG"; echo "BD=$BD_LOG"
  echo "QGLINE=$(tail -1 "$QG_LOG" 2>/dev/null)"
}
getl() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }
cmt()  { getl COMMENTS | tr '|' '\n' | grep -F -- "@$1: " ; }   # cmt <bead-id>

# ── 1. the early re-check block (Step 10): a CLOSED bead is a terminal skip, not a FAIL ──────────────
echo "── 1. early live re-check: bead closed → terminal skip, never FAIL ──"
EARLY_SRC="$(sed -n '/ga-lxz5w (b): LIVE re-check/,/ga-lxz5w (a): SIBLING-BRANCH-FOR-SAME-BEAD/p' "$DISPATCHER")"
[ -n "$EARLY_SRC" ] || { echo "FATAL: early live re-check block anchors not found (moved/renamed?)" >&2; exit 2; }
# The block is spliced into a wrapper function; the REACHED_AFTER line is INSIDE the wrapper, after the
# block, so a `return` in the block (the real function's way of ending the run) skips it — a marker
# printed by the caller would print either way and prove nothing.
eval "run_early_block() {
$EARLY_SRC
echo REACHED_AFTER=1; echo \"VERDICT=\$OVERALL_VERDICT\"; echo \"CLASS=\$GATE_SHA_FAIL_CLASS\"; echo \"REASONS=\$FAIL_REASONS\"
}"
# run_early <live-result> [status] — stubs gate_bead_live_merge_block the way the real one reports.
run_early() {
  OUT=$( set -e
         LIVE="$1"; OVERALL_VERDICT="PASS"; FAIL_REASONS=""; GATE_SHA_FAIL_CLASS="code"
         gate_bead_live_merge_block() { GATE_LXZ5W_LIVE_RESULT="$LIVE"; GATE_LXZ5W_LIVE_STATUS="${2:-open}"; GATE_LXZ5W_LIVE_LABELS="story:approved"; printf '%s' "$LIVE"; return 0; }
         run_early_block
         echo "WRAPPER_RC=$?"
         dump_state )
  RC=$?
}

new_case
run_early closed closed
if [ "$(getl REACHED_AFTER)" != "1" ] && [ "$RC" = "0" ]; then
  ok "closed bead: the block ENDS the run (returns 0) instead of falling through to the FAIL path — the run never reaches the merge/FAIL code"
else
  bad "closed bead must terminate the run; it fell through (REACHED_AFTER=$(getl REACHED_AFTER) rc=$RC verdict=$(getl VERDICT) reasons=[$(getl REASONS)])"
fi
if [ "$(getl VERDICT)" != "FAIL" ]; then
  ok "closed bead: OVERALL_VERDICT is never flipped to FAIL"
else
  bad "closed bead still downgrades the run to FAIL (verdict=FAIL, reasons=[$(getl REASONS)])"
fi
SRC_C="$(cmt "$BEAD_ID")"
if has "$SRC_C" "ga-5w2gpw" && has "$SRC_C" "already closed" && has "$SRC_C" "NOT merged" && has "$SRC_C" "$BRANCH" && has "$SRC_C" "$BRANCH_SHA" \
   && has "$SRC_C" "$GATE_RUN_ID"; then
  ok "closed bead: ONE audit comment on the source bead names the branch, the exact sha, the gate-run, says it was NOT merged and why"
else
  bad "closed bead: the audit comment on the source bead is missing or incomplete: [$SRC_C]"
fi
case "$SRC_C" in *"@$BEAD_ID: GATE-FEEDBACK"*) bad "the audit comment starts with GATE-FEEDBACK — E4 and the Pilot would read it as a verdict" ;; *) ok "the audit comment does NOT start with GATE-FEEDBACK (it is not a verdict)" ;; esac
if has "$(getl CLOSES)" "@$MARKER_ID: " && has "$(getl CLOSES)" "SUPERSEDED" && has "$(getl CLOSES)" "NOT merged" && has "$(getl STATUS)" "$MARKER_ID:superseded"; then
  ok "closed bead: the marker is set superseded and CLOSED with a reason that says the branch was NOT merged"
else
  bad "closed bead: marker not terminally closed honestly: status=[$(getl STATUS)] closes=[$(getl CLOSES)]"
fi
if has "$(getl STATUS)" "$GATE_RUN_ID:superseded" && has "$(getl CLOSES)" "@$GATE_RUN_ID: "; then
  ok "closed bead: the gate-run bead is superseded and closed too (Phase C must not re-select it)"
else
  bad "closed bead: gate-run not retired: status=[$(getl STATUS)] closes=[$(getl CLOSES)]"
fi
if has "$(getl LABELS)" "$BEAD_CITY@label remove bead-e6c gate:reviewing" 2>/dev/null || has "$(getl BD)" "label remove $BEAD_ID gate:reviewing"; then
  ok "closed bead: gate:reviewing is cleared on the source bead (same head-of-line guard as the other terminal paths)"
else
  bad "closed bead: gate:reviewing not cleared: bd=[$(getl BD)]"
fi
BDW="$(getl BD)"
if ! has "$BDW" "gate:failed" && ! has "$BDW" "gate:needs-fix" && ! has "$BDW" "gate:fix-attempt" && ! has "$BDW" "gate-sha-failed" && ! has "$BDW" "GATE-FEEDBACK"; then
  ok "closed bead: NOTHING FAIL-shaped is written (no gate:failed / needs-fix / fix-attempt / gate-sha-failed, no GATE-FEEDBACK)"
else
  bad "closed bead wrote FAIL-shaped state: bd=[$BDW]"
fi
QGL="$(getl QGLINE)"
if has "$QGL" '"event":"dispatcher_complete"' && has "$QGL" '"result":"SKIPPED_BEAD_CLOSED"' && has "$QGL" "\"gate_run\":\"$GATE_RUN_ID\""; then
  ok "closed bead: logged as dispatcher_complete result=SKIPPED_BEAD_CLOSED (progress for gate-health-monitor, neither PASS nor FAIL)"
else
  bad "closed bead: jsonl event missing or wrong: [$QGL]"
fi
has "$(getl LOG)" "verdict=SKIPPED_BEAD_CLOSED" \
  && ok "closed bead: the 'Gate run complete' line says verdict=SKIPPED_BEAD_CLOSED" \
  || bad "closed bead: 'Gate run complete' line missing or still says PASS/FAIL: [$(getl LOG)]"

# park:* is a human HOLD, not a terminal bead: unchanged — still a FAIL downgrade that falls through
for park in park:needs-approval park:withdraw park:needs-human; do
  new_case
  run_early "$park" open
  if [ "$(getl REACHED_AFTER)" = "1" ] && [ "$(getl VERDICT)" = "FAIL" ] && [ -z "$(getl COMMENTS)" ] && [ -z "$(getl CLOSES)" ]; then
    ok "$park: unchanged — still downgrades to FAIL and falls through, and writes nothing (a hold is not a terminal bead)"
  else
    bad "$park must behave exactly as before: reached=$(getl REACHED_AFTER) verdict=$(getl VERDICT) comments=[$(getl COMMENTS)] closes=[$(getl CLOSES)]"
  fi
done
# unknown: a failed read is the third state — never "closed"
new_case
run_early unknown open
if [ "$(getl REACHED_AFTER)" = "1" ] && [ "$(getl VERDICT)" = "PASS" ] && [ -z "$(getl CLOSES)" ]; then
  ok "unknown (bd show failed): not closed, not failed — proceeds toward the authoritative late re-check exactly as before (ga-360a7l)"
else
  bad "unknown must not terminate or fail the run: reached=$(getl REACHED_AFTER) verdict=$(getl VERDICT) closes=[$(getl CLOSES)]"
fi
new_case
run_early ok open
if [ "$(getl REACHED_AFTER)" = "1" ] && [ "$(getl VERDICT)" = "PASS" ] && [ -z "$(getl CLOSES)" ]; then
  ok "ok (open, no hold): untouched — proceeds to merge"
else
  bad "an open bead must proceed: reached=$(getl REACHED_AFTER) verdict=$(getl VERDICT)"
fi

# honest about a FAILED write: the marker write that does not land is never narrated as done
new_case; MARKER_SET_RC=3
run_early closed closed
if has "$(getl WARN)" "$MARKER_ID" && has "$(getl WARN)" "FAILED"; then
  ok "a marker write that fails is reported (warn), not swallowed — and the run still ends (the stale-claim recovery requeues a stuck marker)"
else
  bad "a failed marker write must be warned about: warn=[$(getl WARN)]"
fi
new_case
GATE_RUN_ID_SAVE="$GATE_RUN_ID"; GATE_RUN_ID="unknown"
run_early closed closed
if ! has "$(getl STATUS)" "unknown:" && ! has "$(getl CLOSES)" "@unknown: "; then
  ok "GATE_RUN_ID=unknown (the gate-run bead was never created): no writes against a bead called 'unknown'"
else
  bad "wrote against the 'unknown' gate-run sentinel: status=[$(getl STATUS)] closes=[$(getl CLOSES)]"
fi
GATE_RUN_ID="$GATE_RUN_ID_SAVE"

# ── 2. the late block (do_merge_ff's authoritative re-check right before the push) ───────────────────
echo "── 2. late live re-check: closed between review and push → same terminal skip ──"
LATE_SRC="$(sed -n '/# SELFTEST-EXTRACT bead-closed-late: BEGIN/,/# SELFTEST-EXTRACT bead-closed-late: END/p' "$DISPATCHER" | sed '1d;$d')"
if [ -z "$LATE_SRC" ]; then
  bad "the bead-closed-late sentinel block is not in the dispatcher — the late (pre-push) closed-bead case is not wired"
else
  eval "run_late_block() {
$LATE_SRC
echo REACHED_AFTER=1; echo \"VERDICT=\$OVERALL_VERDICT\"
}"
  run_late() { # run_late <MERGE_RESULT> <GATE_BEAD_CLOSED_LATE>
    OUT=$( set -e
           MERGE_RESULT="$1"; GATE_BEAD_CLOSED_LATE="$2"; OVERALL_VERDICT="PASS"; FAIL_REASONS=""
           run_late_block
           echo "WRAPPER_RC=$?"
           dump_state )
    RC=$?
  }
  new_case
  run_late failed_bead_blocked_late 1
  if [ "$(getl REACHED_AFTER)" != "1" ] && [ "$RC" = "0" ] && has "$(getl CLOSES)" "@$MARKER_ID: " && has "$(getl STATUS)" "$MARKER_ID:superseded" \
     && has "$(cmt "$BEAD_ID")" "already closed" && has "$(getl QGLINE)" "SKIPPED_BEAD_CLOSED"; then
    ok "late: MERGE_RESULT=failed_bead_blocked_late AND the closed flag → terminal skip (marker + gate-run closed, audit comment, SKIPPED_BEAD_CLOSED)"
  else
    bad "late closed bead must terminate as a skip: reached=$(getl REACHED_AFTER) rc=$RC status=[$(getl STATUS)] closes=[$(getl CLOSES)]"
  fi
  new_case
  run_late failed_bead_blocked_late 0
  if [ "$(getl REACHED_AFTER)" = "1" ] && [ -z "$(getl CLOSES)" ]; then
    ok "late: a park:* block (closed flag 0) is NOT hijacked — falls through to the FAIL handling as before"
  else
    bad "late park must fall through untouched: reached=$(getl REACHED_AFTER) closes=[$(getl CLOSES)]"
  fi
  new_case
  run_late failed_push_race 1
  if [ "$(getl REACHED_AFTER)" = "1" ] && [ -z "$(getl CLOSES)" ]; then
    ok "late: a STALE closed flag left by another run does not hijack an unrelated merge failure (both conditions are required)"
  else
    bad "a stale closed flag hijacked failed_push_race: reached=$(getl REACHED_AFTER) closes=[$(getl CLOSES)]"
  fi
  new_case
  run_late direct_ff 1
  [ "$(getl REACHED_AFTER)" = "1" ] && [ -z "$(getl CLOSES)" ] \
    && ok "late: a SUCCESSFUL merge is never turned into a skip by a stale flag" \
    || bad "a stale closed flag hijacked a successful merge"
fi

# ── 3. wiring ────────────────────────────────────────────────────────────────────────────────────────
echo "── 3. wiring ──"
declare -F gate_finish_bead_already_closed >/dev/null 2>&1 \
  && ok "gate_finish_bead_already_closed is defined (lib-only sourceable)" \
  || bad "gate_finish_bead_already_closed is not defined by the dispatcher"
GFR_START="$(grep -n '^gate_finalize_run() {' "$DISPATCHER" | head -1 | cut -d: -f1)"
LATE_LINE="$(grep -n 'SELFTEST-EXTRACT bead-closed-late: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)"
FAILBLK="$(grep -n 'Merge failed despite all-PASS verdict — degrade to FAIL' "$DISPATCHER" | head -1 | cut -d: -f1)"
if [ -n "$GFR_START" ] && [ -n "$LATE_LINE" ] && [ -n "$FAILBLK" ] && [ "$GFR_START" -lt "$LATE_LINE" ] && [ "$LATE_LINE" -lt "$FAILBLK" ]; then
  ok "the late skip sits inside gate_finalize_run and BEFORE the generic 'merge failed → degrade to FAIL' block that would otherwise swallow it"
else
  bad "late skip wiring order wrong: gate_finalize_run=$GFR_START late=$LATE_LINE fail-block=$FAILBLK"
fi

echo "gate-e6c-closed-bead-terminal selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
