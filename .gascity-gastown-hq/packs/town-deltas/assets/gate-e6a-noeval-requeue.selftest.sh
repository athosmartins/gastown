#!/usr/bin/env bash
# gate-e6a-noeval-requeue.selftest.sh (ga-5w2gpw item a, 2026-09-30)
#
# CLASS: a gate run in which NOBODY JUDGED THE CODE — a live-but-slow reviewer that
# timed out (Phase C genuine timeout), or a reviewer whose verdict bead closed with
# no verdict (ga-w7pm55) — used to end as a FAIL. ga-mcapdq/ga-w7pm55 already kept it
# out of gate:fix-attempt and classed the SHA stamp "hold", but the run still went
# down the FAIL path: a "GATE-FEEDBACK … Fix THESE specific blocking issues" comment
# on the source bead, gate:needs-fix, and the bead handed back to the pool to "fix"
# a thing nobody found wrong. E4 (docs/reports/gate-e4-historico.md §1) counted 110
# of the 207 no-review FAILs as exactly this; the dispatcher log shows it still
# happening (16 on 26/09, 8 on 29/09, 5 on 30/09).
#
# FIX under test: a no-eval FAIL is RE-QUEUED instead (the marker goes back to
# gate-status:queued, a fresh run mints fresh reviewers), BOUNDED — a counter label on
# the marker (gate:noeval-requeue:N, cap GATE_NOEVAL_REQUEUE_CAP, default 2). Past the
# cap, or when the counter cannot be read or recorded, the run takes the legacy FAIL
# path unchanged: an unbounded requeue would loop forever on a reviewer that is
# wedged on every attempt.
#
# Three states, never two (error != empty): the counter is READ (a number, maybe 0),
# or UNREADABLE (bd failed, non-JSON, an error envelope without this marker's id) —
# and an unreadable counter is never read as 0, because that would let a run that
# cannot be bounded requeue forever.
#
# Strategy (this repo's SELFTEST-EXTRACT convention): the decision function is sourced
# from the dispatcher in lib-only mode; the glue block and the requeue block are
# extracted from the LIVE dispatcher by sentinel and run in-process against a
# stateful marker stub — never a hand-copied duplicate. Only bd/notify/log/warn/
# set_gate_status are stubbed. Every case runs under `set -e` like the dispatcher.
#
# Exit 0 iff every assertion holds. Runs under /bin/bash 3.2 (launchd's bash).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
# has <haystack> <needle> — a `case` match, NOT `printf | grep -q`: under `pipefail`, grep -q exits on
# the first match, printf can then take a SIGPIPE, and a TRUE match reads as a failure (flaky on large
# strings — observed once in this very file).
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

echo "== gate-e6a-noeval-requeue.selftest =="
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

# /bin/bash -n, never bare `bash -n` (Homebrew bash 5.3 accepts what 3.2 rejects).
if /bin/bash -n "$DISPATCHER" 2>/dev/null; then
  ok "dispatcher parses under /bin/bash (3.2) — the interpreter launchd actually runs"
else
  bad "dispatcher does NOT parse under /bin/bash 3.2"
fi

GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode" >&2; exit 2; }
set +e

extract_block() {
  sed -n "/# SELFTEST-EXTRACT ${2}: BEGIN/,/# SELFTEST-EXTRACT ${2}: END/p" "$1" | sed '1d;$d'
}

MARKER_ID="m-e6a"; BEAD_ID="bead-e6a"; BEAD_CITY="test-city"; GC_CITY="test-city"
GATE_RUN_ID="gr-e6a"; BRANCH="fix/ga-fixture"

# ── stateful stubs: one marker whose labels the code under test reads AND writes ──
new_case() { # <marker-labels> [status] [raw-show-output | __FAIL__]
  BD_LOG=""; WARN_LOG=""; STATUS_LOG=""; NOTIFY_LOG=""; COMMENT_LOG=""; CLOSE_LOG=""
  MARK_LABELS="$1"; MARK_STATUS="${2:-open}"; SHOW_RAW="${3:-}"
  LABEL_ADD_STICKS=1   # a case that wants the counter write to be LOST sets this to 0 after new_case
  MARKER_SET_RC=0
}
marker_json() {
  local l first=1 labs=""
  for l in $MARK_LABELS; do
    [ "$first" = 1 ] || labs="$labs,"; first=0; labs="$labs\"$l\""
  done
  printf '[{"id":"%s","status":"%s","labels":[%s]}]' "$MARKER_ID" "$MARK_STATUS" "$labs"
}
strip_gate_status() {
  local out="" l
  for l in $MARK_LABELS; do case "$l" in gate-status:*) ;; *) out="$out $l" ;; esac; done
  MARK_LABELS="${out# }"
  return 0
}
final_gs() { local out="" l; for l in $MARK_LABELS; do case "$l" in gate-status:*) out="$out $l" ;; esac; done; printf '%s' "${out# }"; }
has_label() { local l; for l in $MARK_LABELS; do [ "$l" = "$1" ] && return 0; done; return 1; }
bd() {
  BD_LOG="$BD_LOG|$*"
  case "${3:-}" in
    show)
      if [ "${4:-}" = "$MARKER_ID" ]; then
        [ "$SHOW_RAW" = "__FAIL__" ] && return 1
        if [ -n "$SHOW_RAW" ]; then printf '%s' "$SHOW_RAW"; return 0; fi
        marker_json; return 0
      fi
      printf '[{"id":"%s","status":"open","labels":[]}]' "${4:-}"; return 0 ;;
    label)
      if [ "${5:-}" = "$MARKER_ID" ]; then
        case "${4:-}" in
          add) [ "$LABEL_ADD_STICKS" = "1" ] && MARK_LABELS="$MARK_LABELS ${6:-}" ;;
          remove) local out="" l
                  for l in $MARK_LABELS; do [ "$l" = "${6:-}" ] || out="$out $l"; done
                  MARK_LABELS="${out# }" ;;
        esac
      fi
      return 0 ;;
    comment) COMMENT_LOG="$COMMENT_LOG|${4:-}: ${5:-}"; return 0 ;;
    close)   CLOSE_LOG="$CLOSE_LOG|${4:-}: ${6:-}"; return 0 ;;
  esac
  return 0
}
set_gate_status() {
  STATUS_LOG="$STATUS_LOG|$1:$2"
  if [ "$1" = "$MARKER_ID" ]; then
    [ "$MARKER_SET_RC" = "0" ] || return "$MARKER_SET_RC"
    strip_gate_status; MARK_LABELS="$MARK_LABELS gate-status:$2"
  fi
  return 0
}
warn()   { WARN_LOG="$WARN_LOG|$*"; return 0; }
log()    { return 0; }
err()    { WARN_LOG="$WARN_LOG|ERR:$*"; return 0; }
notify() { NOTIFY_LOG="$NOTIFY_LOG|$*"; return 0; }
quota_reset_eta() { printf 'reset em 2h'; }
declare -F vb_status_action >/dev/null 2>&1 || vb_status_action() { printf 'requeue'; }
dump_state() {
  echo "GS=$(final_gs)"
  echo "LABELS=$MARK_LABELS"
  echo "STATUS=$STATUS_LOG"
  echo "COMMENTS=$COMMENT_LOG"
  echo "CLOSES=$CLOSE_LOG"
  echo "NOTIFY=$NOTIFY_LOG"
  echo "WARN=$WARN_LOG"
  echo "BD=$BD_LOG"
}
getl() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }
cmt()  { getl COMMENTS | tr '|' '\n' | grep -F -- "$1: "; }

# ── 1. the decision: bounded, three-state ───────────────────────────────────
echo "── 1. gate_noeval_requeue_decision: bounded requeue, unreadable counter never reads as 0 ──"
if ! declare -F gate_noeval_requeue_decision >/dev/null 2>&1; then
  bad "gate_noeval_requeue_decision is not defined by the dispatcher (lib-only) — item (a) not implemented"
else
  # Called in-process with stdout captured through a file: a command substitution
  # forks a subshell, and the stateful stub's label writes would be lost with it.
  DEC_OUT="$(mktemp "${TMPDIR:-/tmp}/e6a-dec.XXXXXX")"; trap 'rm -f "$DEC_OUT"' EXIT
  decide() { # decide <marker-id> ; result in $DECISION
    gate_noeval_requeue_decision "$1" > "$DEC_OUT" 2>/dev/null; DECISION="$(cat "$DEC_OUT")"
  }

  new_case "type:quality-gate-marker gate-status:dispatching"
  decide "$MARKER_ID"
  if [ "$DECISION" = "requeue:1" ] && has_label "gate:noeval-requeue:1"; then
    ok "first no-eval run → requeue:1, and the counter label gate:noeval-requeue:1 is on the marker (recorded BEFORE the requeue, so a later failure cannot leave the loop unbounded)"
  else
    bad "first no-eval run must requeue and record 1: decision=[$DECISION] labels=[$MARK_LABELS]"
  fi

  new_case "type:quality-gate-marker gate-status:dispatching gate:noeval-requeue:1"
  decide "$MARKER_ID"
  if [ "$DECISION" = "requeue:2" ] && has_label "gate:noeval-requeue:2" && ! has_label "gate:noeval-requeue:1"; then
    ok "second no-eval run → requeue:2; the stale counter is replaced, not stacked"
  else
    bad "second run must requeue:2 and replace the counter: decision=[$DECISION] labels=[$MARK_LABELS]"
  fi

  new_case "type:quality-gate-marker gate-status:dispatching gate:noeval-requeue:2"
  decide "$MARKER_ID"
  if [ "$DECISION" = "fail:cap" ] && has_label "gate:noeval-requeue:2" && [ -z "$(printf '%s' "$BD_LOG" | grep -F 'label add')" ]; then
    ok "at the cap (2 requeues already spent) → fail:cap, and NOTHING is written — the legacy FAIL path takes over, so a reviewer wedged on every attempt cannot loop forever"
  else
    bad "at the cap the decision must be fail:cap with no writes: decision=[$DECISION] labels=[$MARK_LABELS] bd=[$BD_LOG]"
  fi

  new_case "type:quality-gate-marker gate-status:dispatching gate:noeval-requeue:1 gate:noeval-requeue:2"
  decide "$MARKER_ID"
  [ "$DECISION" = "fail:cap" ] \
    && ok "coexisting counters (a lost remove left {1,2}) take the MAX, so the residue advances toward the cap instead of stalling below it" \
    || bad "coexisting counters {1,2} must read as 2 → fail:cap, got [$DECISION]"

  new_case "type:quality-gate-marker gate-status:dispatching"
  ( GATE_NOEVAL_REQUEUE_CAP=0; decide() { gate_noeval_requeue_decision "$1" 2>/dev/null; }; decide "$MARKER_ID" ) > "$DEC_OUT"
  [ "$(cat "$DEC_OUT")" = "fail:cap" ] \
    && ok "GATE_NOEVAL_REQUEUE_CAP=0 turns the requeue off (kill switch) → fail:cap" \
    || bad "cap 0 must disable the requeue: got [$(cat "$DEC_OUT")]"

  new_case "type:quality-gate-marker gate-status:dispatching"
  ( GATE_NOEVAL_REQUEUE_CAP=banana; gate_noeval_requeue_decision "$MARKER_ID" 2>/dev/null ) > "$DEC_OUT"
  [ "$(cat "$DEC_OUT")" = "requeue:1" ] \
    && ok "a non-numeric cap falls back to the default (2) instead of disabling or unbounding the loop" \
    || bad "non-numeric cap must fall back to the default: got [$(cat "$DEC_OUT")]"

  # UNREADABLE counter: never the same value as "counter is 0"
  for variant in __FAIL__ "this is not json" '{"error":"database is locked"}' '[{"id":"someone-else","status":"open","labels":[]}]'; do
    new_case "type:quality-gate-marker gate-status:dispatching" open "$variant"
    decide "$MARKER_ID"
    if [ "$DECISION" = "fail:unreadable" ] && [ -z "$(printf '%s' "$BD_LOG" | grep -F 'label add')" ]; then
      ok "unreadable marker [$variant] → fail:unreadable, nothing written (an unreadable counter is not a counter of 0)"
    else
      bad "unreadable marker [$variant] must be fail:unreadable with no writes: decision=[$DECISION] bd=[$BD_LOG]"
    fi
  done

  new_case "type:quality-gate-marker gate-status:dispatching"
  LABEL_ADD_STICKS=0
  decide "$MARKER_ID"
  [ "$DECISION" = "fail:not-recorded" ] \
    && ok "a counter write that does not stick → fail:not-recorded (verified by READING IT BACK, not by the write's exit code) — an unrecorded count cannot bound the loop" \
    || bad "a lost counter write must be fail:not-recorded: decision=[$DECISION]"

  new_case "type:quality-gate-marker gate-status:dispatching"
  decide ""
  [ "$DECISION" = "fail:no-marker" ] \
    && ok "an empty marker id → fail:no-marker (no bead to requeue)" \
    || bad "empty marker id must be fail:no-marker: [$DECISION]"
fi

# ── 2. the glue: which runs are eligible ────────────────────────────────────
echo "── 2. glue: only a no-eval FAIL is converted to a requeue ──"
GLUE_SRC="$(extract_block "$DISPATCHER" noeval-requeue-gate)"
if [ -z "$GLUE_SRC" ]; then
  bad "the noeval-requeue-gate sentinel block is not in the dispatcher — item (a) not wired into gate_finalize_run"
else
  eval "run_glue_block() {
$GLUE_SRC
}"
  # run_glue <no_eval> <verdict> <quota_requeue> <decision-line>
  run_glue() {
    OUT=$( set -e
           GATE_FAIL_NO_EVAL="$1"; OVERALL_VERDICT="$2"; QUOTA_REQUEUE="$3"; REQUEUE_REASON="quota"
           STUB_DECISION="$4"; CALLS_FILE="$(mktemp "${TMPDIR:-/tmp}/e6a-calls.XXXXXX")"
           # the real call site runs in a command substitution, so the stub counts its calls in a file
           gate_noeval_requeue_decision() { echo x >> "$CALLS_FILE"; printf '%s\n' "$STUB_DECISION"; return 0; }
           run_glue_block
           echo "NOEVAL=$GATE_FAIL_NO_EVAL"; echo "QR=$QUOTA_REQUEUE"; echo "REASON=$REQUEUE_REASON"; echo "CALLS=$(wc -l < "$CALLS_FILE" | tr -d ' ')"
           rm -f "$CALLS_FILE"
           dump_state )
  }
  new_case "type:quality-gate-marker gate-status:dispatching"
  run_glue 1 FAIL 0 "requeue:1"
  if [ "$(getl QR)" = "1" ] && [ "$(getl REASON)" = "no-eval" ] && [ "$(getl NOEVAL)" = "0" ]; then
    ok "no-eval FAIL + decision requeue → QUOTA_REQUEUE=1, REQUEUE_REASON=no-eval, and the no-eval flag is CONSUMED (cannot leak into the next run)"
  else
    bad "no-eval FAIL must become a no-eval requeue: $(printf '%s' "$OUT" | tr '\n' ' ')"
  fi
  run_glue 1 FAIL 0 "fail:cap"
  if [ "$(getl QR)" = "0" ] && [ "$(getl NOEVAL)" = "1" ] && [ "$(getl REASON)" = "quota" ]; then
    ok "decision fail:cap → nothing changes: the no-eval flag stays 1 and the run takes the legacy FAIL path (hold class, fix-attempt untouched)"
  else
    bad "a refused requeue must leave the legacy path intact: $(printf '%s' "$OUT" | tr '\n' ' ')"
  fi
  for shape in "unreadable counter:fail:unreadable" "counter not recorded:fail:not-recorded" "garbage decision:banana" "empty decision:"; do
    desc="${shape%%:*}"; dec="${shape#*:}"
    run_glue 1 FAIL 0 "$dec"
    if [ "$(getl QR)" = "0" ] && [ "$(getl NOEVAL)" = "1" ]; then
      ok "$desc ([$dec]) → inert: no requeue, legacy FAIL path (only the literal requeue:<n> earns a requeue)"
    else
      bad "$desc ([$dec]) must not requeue: $(printf '%s' "$OUT" | tr '\n' ' ')"
    fi
  done
  run_glue 0 FAIL 0 "requeue:1"
  if [ "$(getl QR)" = "0" ] && [ "$(getl CALLS)" = "0" ]; then
    ok "a JUDGED FAIL (no-eval=0) is never requeued, and the decision is not even consulted — a real rejection stays a FAIL"
  else
    bad "a judged FAIL must not reach the requeue decision: $(printf '%s' "$OUT" | tr '\n' ' ')"
  fi
  run_glue 1 PASS 0 "requeue:1"
  if [ "$(getl QR)" = "0" ] && [ "$(getl CALLS)" = "0" ]; then
    ok "a PASS is never touched, even with a stale no-eval flag"
  else
    bad "a PASS must not reach the requeue decision: $(printf '%s' "$OUT" | tr '\n' ' ')"
  fi
  run_glue 1 FAIL 1 "requeue:1"
  if [ "$(getl QR)" = "1" ] && [ "$(getl CALLS)" = "0" ] && [ "$(getl REASON)" = "quota" ]; then
    ok "an infra requeue already decided (dead reviewer / quota-stop) is left alone — not overwritten, no second counter bump"
  else
    bad "an already-requeued run must be left as is: $(printf '%s' "$OUT" | tr '\n' ' ')"
  fi
fi

# ── 3. the requeue block: REQUEUE_REASON=no-eval ────────────────────────────
echo "── 3. requeue block, reason no-eval: requeued, honestly worded, nothing FAIL-shaped ──"
INFRA_SRC="$(extract_block "$DISPATCHER" infra-requeue-block)"
[ -n "$INFRA_SRC" ] || { echo "FATAL: infra-requeue-block sentinel block not found (moved/renamed?)" >&2; exit 2; }
eval "run_infra_block() {
$INFRA_SRC
}"
run_infra() { # run_infra <REQUEUE_REASON>
  OUT=$( set -e; QUOTA_REQUEUE=1; REQUEUE_REASON="$1"; VERDICT_BEAD_IDS=("vb-e6a")
         run_infra_block; echo "RC=$?"; dump_state ) 2>&1
}

new_case "type:quality-gate-marker gate-status:dispatching"
run_infra no-eval
ALLC="$(getl COMMENTS)$(getl CLOSES)$(getl NOTIFY)$(getl WARN)"
if [ "$(getl GS)" = "gate-status:queued" ] && has "$OUT" "RC=0" && ! has "$OUT" "unbound variable"; then
  ok "no-eval: the marker ends exactly at gate-status:queued and the block returns 0 under set -e"
else
  bad "no-eval must requeue the marker: GS='$(getl GS)' out=[$OUT]"
fi
if ! has "$ALLC" "QUOTA" && ! has "$ALLC" "quota" && ! has "$ALLC" "died"; then
  ok "no-eval: no message blames the 5h quota or claims a reviewer died (it did neither — it delivered no verdict)"
else
  bad "no-eval messages must not say quota/died: [$ALLC]"
fi
if has "$(cmt "$MARKER_ID")" "ga-5w2gpw" && has "$(cmt "$MARKER_ID")" "no verdict" && has "$(cmt "$MARKER_ID")" "NOT a code FAIL" \
   && has "$(cmt "$GATE_RUN_ID")" "No verdict recorded" && has "$(getl CLOSES)" "no-eval re-queue (ga-5w2gpw)"; then
  ok "no-eval: marker comment, gate-run comment and close reason name ga-5w2gpw, say no verdict was delivered, and say NOT a code FAIL"
else
  bad "no-eval wording missing: marker=[$(cmt "$MARKER_ID")] run=[$(cmt "$GATE_RUN_ID")] closes=[$(getl CLOSES)]"
fi
if has "$(cmt vb-e6a)" "VERDICT: REQUEUED (ga-5w2gpw)"; then
  ok "no-eval: the verdict bead is parked REQUEUED with the no-eval tag"
else
  bad "no-eval verdict-bead comment missing: [$(cmt vb-e6a)]"
fi
has "$(getl BD)" "label remove $BEAD_ID gate:reviewing" \
  && ok "no-eval: gate:reviewing is cleared on the source bead (same head-of-line guard as the other requeues, ga-n2cpe)" \
  || bad "no-eval must clear gate:reviewing: bd=[$(getl BD)]"
if ! has "$(getl BD)" "GATE-FEEDBACK" && ! has "$(getl BD)" "gate:needs-fix" && ! has "$(getl BD)" "gate:failed" && ! has "$(getl BD)" "gate:fix-attempt" && ! has "$(getl BD)" "gate-sha-failed"; then
  ok "no-eval: NOTHING FAIL-shaped is written — no GATE-FEEDBACK, no gate:failed / needs-fix / fix-attempt, no gate-sha-failed stamp"
else
  bad "no-eval wrote FAIL-shaped state: bd=[$(getl BD)]"
fi
if has "$(getl NOTIFY)" "re-enfileirado"; then
  ok "no-eval: the push notice says the gate was re-queued"
else
  bad "no-eval push notice missing: [$(getl NOTIFY)]"
fi

new_case "type:quality-gate-marker gate-status:dispatching gate-status:needs-rebase"
run_infra no-eval
MKC="$(cmt "$MARKER_ID")"; GRC="$(cmt "$GATE_RUN_ID")"
if [ "$(getl GS)" = "gate-status:needs-rebase" ] && ! has "$(getl STATUS)" "$MARKER_ID:queued" && has "$OUT" "RC=0" \
   && has "$MKC" "NOT applied" && ! has "$MKC" "Marker re-queued" && has "$GRC" "NOT re-queued" && [ -z "$(getl NOTIFY)" ]; then
  ok "no-eval: an external needs-rebase present at the closing write survives, and no message claims a requeue that did not happen (ga-dl3x9s contract)"
else
  bad "no-eval must respect an external transition honestly: GS='$(getl GS)' marker=[$MKC] run=[$GRC] notify=[$(getl NOTIFY)]"
fi

# the two existing reasons keep their own wording (the parametrisation must not leak)
for REASON in dead-reviewer quota; do
  new_case "type:quality-gate-marker gate-status:dispatching"
  run_infra "$REASON"
  ALLC="$(getl COMMENTS)$(getl CLOSES)$(getl NOTIFY)"
  if has "$ALLC" "ga-eqjo" && [ "$REASON" = "dead-reviewer" ] && ! has "$ALLC" "ga-5w2gpw"; then
    ok "dead-reviewer keeps its ga-eqjo wording, no ga-5w2gpw leakage"
  elif [ "$REASON" = "quota" ] && has "$ALLC" "ga-x3nmz" && ! has "$ALLC" "ga-5w2gpw"; then
    ok "quota-stop keeps its ga-x3nmz wording, no ga-5w2gpw leakage"
  else
    bad "$REASON wording changed or leaked: [$ALLC]"
  fi
done

# ── 4. wiring: the glue sits INSIDE gate_finalize_run, BEFORE the requeue block ─
echo "── 4. wiring drift-guards ──"
GFR_START="$(grep -n '^gate_finalize_run() {' "$DISPATCHER" | head -1 | cut -d: -f1)"
GLUE_LINE="$(grep -n 'SELFTEST-EXTRACT noeval-requeue-gate: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)"
INFRA_LINE="$(grep -n 'SELFTEST-EXTRACT infra-requeue-block: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)"
if [ -n "$GFR_START" ] && [ -n "$GLUE_LINE" ] && [ -n "$INFRA_LINE" ] && [ "$GFR_START" -lt "$GLUE_LINE" ] && [ "$GLUE_LINE" -lt "$INFRA_LINE" ]; then
  ok "the no-eval glue is inside gate_finalize_run and runs BEFORE the infra-requeue block it feeds (order matters: after it the flag would be consumed too late)"
else
  bad "wiring order wrong or glue missing: gate_finalize_run=$GFR_START glue=$GLUE_LINE infra=$INFRA_LINE"
fi

echo "gate-e6a-noeval-requeue selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
