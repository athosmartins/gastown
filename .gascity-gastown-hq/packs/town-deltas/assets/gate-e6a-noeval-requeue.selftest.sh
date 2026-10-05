#!/usr/bin/env bash
# gate-e6a-noeval-requeue.selftest.sh (ga-5w2gpw item a, 2026-09-30)
#
# CLASS: a gate run in which NOBODY JUDGED THE CODE — a live-but-slow reviewer that timed out (Phase C genuine timeout), or a
# reviewer whose verdict bead closed with no verdict (ga-w7pm55) — used to end as a FAIL. ga-mcapdq/ga-w7pm55 kept it out of
# gate:fix-attempt and classed the SHA stamp "hold", but the run still went down the FAIL path: a "GATE-FEEDBACK … Fix THESE specific
# blocking issues" comment on the source bead, gate:needs-fix, the bead handed back to the pool to "fix" a thing nobody found wrong.
# E4 (docs/reports/gate-e4-historico.md §1): 110 of the 207 no-review FAILs; the log shows 16 on 26/09, 8 on 29/09, 5 on 30/09.
#
# FIX under test: a no-eval FAIL is RE-QUEUED instead (marker back to gate-status:queued, fresh reviewers next sweep), BOUNDED by a
# counter label on the marker (gate:noeval-requeue:N, cap GATE_NOEVAL_REQUEUE_CAP, default 2). Past the cap, or when the counter
# cannot be read or recorded, the run takes the legacy FAIL path unchanged: an unbounded requeue would loop on a wedged reviewer.
# Three states, never two: the counter is READ (a number, maybe 0) or UNREADABLE — and unreadable is never 0, or a run that cannot
# be bounded would requeue forever.
#
# Strategy (SELFTEST-EXTRACT convention): the decision function is sourced from the dispatcher in lib-only mode; the glue and
# requeue blocks are extracted from the LIVE dispatcher by sentinel and run against a stateful marker stub. Only bd / notify / log /
# warn / set_gate_status are stubbed; every case runs under `set -e`. Exit 0 iff every assertion holds. /bin/bash 3.2 (launchd's).
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
/bin/bash -n "$DISPATCHER" 2>/dev/null \
  && ok "dispatcher parses under /bin/bash (3.2) — the interpreter launchd actually runs" \
  || bad "dispatcher does NOT parse under /bin/bash 3.2"

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
      # The REAL bd prints a confirmation on STDOUT for label add/remove and `-q` does not silence it (measured on the live
      # binary, ga-6d9ytc: "✓ Added label 'X' to ID" / "✓ Removed label 'X' from ID"). A stub that stays quiet here is what hid
      # the E6 defect: the code under test is captured with $(...) and its stdout is PARSED, so one stray line is the whole bug.
      case "${4:-}" in
        add)    printf "✓ Added label '%s' to %s\n" "${6:-}" "${5:-}" ;;
        remove) printf "✓ Removed label '%s' from %s\n" "${6:-}" "${5:-}" ;;
      esac
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
  [ "$DECISION" = "requeue:1" ] && has_label "gate:noeval-requeue:1" \
    && ok "first no-eval run → requeue:1, and the counter label gate:noeval-requeue:1 is on the marker (recorded BEFORE the requeue, so a later failure cannot leave the loop unbounded)" \
    || bad "first no-eval run must requeue and record 1: decision=[$DECISION] labels=[$MARK_LABELS]"

  new_case "type:quality-gate-marker gate-status:dispatching gate:noeval-requeue:1"
  decide "$MARKER_ID"
  [ "$DECISION" = "requeue:2" ] && has_label "gate:noeval-requeue:2" && ! has_label "gate:noeval-requeue:1" \
    && ok "second no-eval run → requeue:2; the stale counter is replaced, not stacked" \
    || bad "second run must requeue:2 and replace the counter: decision=[$DECISION] labels=[$MARK_LABELS]"

  new_case "type:quality-gate-marker gate-status:dispatching gate:noeval-requeue:2"
  decide "$MARKER_ID"
  [ "$DECISION" = "fail:cap" ] && has_label "gate:noeval-requeue:2" && [ -z "$(printf '%s' "$BD_LOG" | grep -F 'label add')" ] \
    && ok "at the cap (2 requeues already spent) → fail:cap, and NOTHING is written — the legacy FAIL path takes over, so a reviewer wedged on every attempt cannot loop forever" \
    || bad "at the cap the decision must be fail:cap with no writes: decision=[$DECISION] labels=[$MARK_LABELS] bd=[$BD_LOG]"

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
    [ "$DECISION" = "fail:unreadable" ] && [ -z "$(printf '%s' "$BD_LOG" | grep -F 'label add')" ] \
      && ok "unreadable marker [$variant] → fail:unreadable, nothing written (an unreadable counter is not a counter of 0)" \
      || bad "unreadable marker [$variant] must be fail:unreadable with no writes: decision=[$DECISION] bd=[$BD_LOG]"
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
  [ "$(getl QR)" = "1" ] && [ "$(getl REASON)" = "no-eval" ] && [ "$(getl NOEVAL)" = "0" ] \
    && ok "no-eval FAIL + decision requeue → QUOTA_REQUEUE=1, REQUEUE_REASON=no-eval, and the no-eval flag is CONSUMED (cannot leak into the next run)" \
    || bad "no-eval FAIL must become a no-eval requeue: $(printf '%s' "$OUT" | tr '\n' ' ')"
  run_glue 1 FAIL 0 "fail:cap"
  [ "$(getl QR)" = "0" ] && [ "$(getl NOEVAL)" = "1" ] && [ "$(getl REASON)" = "quota" ] \
    && ok "decision fail:cap → nothing changes: the no-eval flag stays 1 and the run takes the legacy FAIL path (hold class, fix-attempt untouched)" \
    || bad "a refused requeue must leave the legacy path intact: $(printf '%s' "$OUT" | tr '\n' ' ')"
  for shape in "unreadable counter:fail:unreadable" "counter not recorded:fail:not-recorded" "garbage decision:banana" "empty decision:"; do
    desc="${shape%%:*}"; dec="${shape#*:}"
    run_glue 1 FAIL 0 "$dec"
    [ "$(getl QR)" = "0" ] && [ "$(getl NOEVAL)" = "1" ] \
      && ok "$desc ([$dec]) → inert: no requeue, legacy FAIL path (only the literal requeue:<n> earns a requeue)" \
      || bad "$desc ([$dec]) must not requeue: $(printf '%s' "$OUT" | tr '\n' ' ')"
  done
  run_glue 0 FAIL 0 "requeue:1"
  [ "$(getl QR)" = "0" ] && [ "$(getl CALLS)" = "0" ] \
    && ok "a JUDGED FAIL (no-eval=0) is never requeued, and the decision is not even consulted — a real rejection stays a FAIL" \
    || bad "a judged FAIL must not reach the requeue decision: $(printf '%s' "$OUT" | tr '\n' ' ')"
  run_glue 1 PASS 0 "requeue:1"
  [ "$(getl QR)" = "0" ] && [ "$(getl CALLS)" = "0" ] \
    && ok "a PASS is never touched, even with a stale no-eval flag" \
    || bad "a PASS must not reach the requeue decision: $(printf '%s' "$OUT" | tr '\n' ' ')"
  run_glue 1 FAIL 1 "requeue:1"
  [ "$(getl QR)" = "1" ] && [ "$(getl CALLS)" = "0" ] && [ "$(getl REASON)" = "quota" ] \
    && ok "an infra requeue already decided (dead reviewer / quota-stop) is left alone — not overwritten, no second counter bump" \
    || bad "an already-requeued run must be left as is: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# ── 2b. END TO END, in the production call shape (ga-6d9ytc) ───────────────
# Sections 1 and 2 above test the decision and the glue SEPARATELY — the decision in-process with its stdout sent to a file, the
# glue against a stubbed decision. Neither runs what production runs: the REAL glue calling the REAL decision through
# `_NOEVAL_DECISION=$(gate_noeval_requeue_decision ...)` and `case`-matching `requeue:[0-9]*` on the CAPTURED text. That is the one
# place where a stray stdout line from a `bd` call inside the function (the real bd prints "✓ Added label …" and `-q` does not
# silence it) turns "requeue:1" into "✓ Added label …\nrequeue:1", the `case` never matches, and every no-eval run goes down the
# FAIL path — 20 runs between 01/10 and 05/10 (ga-6d9ytc). The stub below is file-backed because the command substitution runs the
# function in a subshell, where the variable-backed stub of sections 1-3 would lose its writes.
echo "── 2b. real glue + real decision through \$(...): a chatty bd must not corrupt the decision ──"
if [ -n "$GLUE_SRC" ] && declare -F gate_noeval_requeue_decision >/dev/null 2>&1; then
  E2E_LABELS="$(mktemp "${TMPDIR:-/tmp}/e6a-e2e-labels.XXXXXX")"
  trap 'rm -f "${DEC_OUT:-}" "$E2E_LABELS" "$E2E_LABELS.tmp"' EXIT
  # bd twin: same argv contract as the stub above, labels in a file, and the REAL bd's chatty stdout on every label write.
  e2e_bd() {
    case "${3:-}" in
      show)
        if [ "${4:-}" = "$MARKER_ID" ]; then
          local l first=1 labs=""
          while IFS= read -r l; do
            [ -z "$l" ] && continue
            [ "$first" = 1 ] || labs="$labs,"; first=0; labs="$labs\"$l\""
          done < "$E2E_LABELS"
          printf '[{"id":"%s","status":"open","labels":[%s]}]' "$MARKER_ID" "$labs"
          return 0
        fi
        printf '[{"id":"%s","status":"open","labels":[]}]' "${4:-}"; return 0 ;;
      label)
        case "${4:-}" in
          add)    printf '%s\n' "${6:-}" >> "$E2E_LABELS"; printf "✓ Added label '%s' to %s\n" "${6:-}" "${5:-}" ;;
          remove) grep -vxF -- "${6:-}" "$E2E_LABELS" > "$E2E_LABELS.tmp" || true; mv "$E2E_LABELS.tmp" "$E2E_LABELS"
                  printf "✓ Removed label '%s' from %s\n" "${6:-}" "${5:-}" ;;
        esac
        return 0 ;;
    esac
    return 0
  }
  # run_e2e <label>... — runs the real glue (no decision stub) and prints the glue's verdict variables.
  run_e2e() {
    : > "$E2E_LABELS"
    local l; for l in "$@"; do printf '%s\n' "$l" >> "$E2E_LABELS"; done
    OUT=$( set -e
           bd() { e2e_bd "$@"; }
           GATE_FAIL_NO_EVAL=1; OVERALL_VERDICT=FAIL; QUOTA_REQUEUE=0; REQUEUE_REASON="quota"
           run_glue_block
           echo "NOEVAL=$GATE_FAIL_NO_EVAL"; echo "QR=$QUOTA_REQUEUE"; echo "REASON=$REQUEUE_REASON"; echo "N=${GATE_NOEVAL_REQUEUE_N:-}"
           echo "WARN=$WARN_LOG" ) 2>&1
  }

  WARN_LOG=""
  run_e2e "type:quality-gate-marker" "gate-status:dispatching"
  [ "$(getl QR)" = "1" ] && [ "$(getl REASON)" = "no-eval" ] && [ "$(getl NOEVAL)" = "0" ] && [ "$(getl N)" = "1" ] \
    && ok "first no-eval run, chatty bd, production call shape → REQUEUED (QUOTA_REQUEUE=1, reason no-eval, n=1). Before ga-6d9ytc the captured decision was \"✓ Added label …\\nrequeue:1\" and this fell to the FAIL path" \
    || bad "a no-eval run must be re-queued even though bd prints a confirmation on stdout: $(printf '%s' "$OUT" | tr '\n' ' ')"

  WARN_LOG=""
  run_e2e "type:quality-gate-marker" "gate-status:dispatching" "gate:noeval-requeue:1"
  [ "$(getl QR)" = "1" ] && [ "$(getl N)" = "2" ] && grep -qx 'gate:noeval-requeue:2' "$E2E_LABELS" && ! grep -qx 'gate:noeval-requeue:1' "$E2E_LABELS" \
    && ok "second run: the counter label is advanced to 2 and the old one removed, through the chatty remove path as well, and the run is still re-queued" \
    || bad "second no-eval run must requeue with counter 2 (remove path is chatty too): $(printf '%s' "$OUT" | tr '\n' ' ') labels=[$(tr '\n' ' ' < "$E2E_LABELS")]"

  WARN_LOG=""
  run_e2e "type:quality-gate-marker" "gate-status:dispatching" "gate:noeval-requeue:2"
  [ "$(getl QR)" = "0" ] && [ "$(getl NOEVAL)" = "1" ] && ! grep -q 'Added label' <<<"$(getl WARN)" \
    && ok "at the cap: still NOT re-queued (the legacy FAIL path), and the reason in the warning is the decision, not a leaked bd line" \
    || bad "at the cap the run must stay on the legacy path with a clean reason: $(printf '%s' "$OUT" | tr '\n' ' ')"
else
  bad "2b: glue block or decision function missing — cannot run the end-to-end case"
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
[ "$(getl GS)" = "gate-status:queued" ] && has "$OUT" "RC=0" && ! has "$OUT" "unbound variable" \
  && ok "no-eval: the marker ends exactly at gate-status:queued and the block returns 0 under set -e" \
  || bad "no-eval must requeue the marker: GS='$(getl GS)' out=[$OUT]"
! has "$ALLC" "QUOTA" && ! has "$ALLC" "quota" && ! has "$ALLC" "died" \
  && ok "no-eval: no message blames the 5h quota or claims a reviewer died (it did neither — it delivered no verdict)" \
  || bad "no-eval messages must not say quota/died: [$ALLC]"
has "$(cmt "$MARKER_ID")" "ga-5w2gpw" && has "$(cmt "$MARKER_ID")" "no verdict" && has "$(cmt "$MARKER_ID")" "NOT a code FAIL" \
   && has "$(cmt "$GATE_RUN_ID")" "No verdict recorded" && has "$(getl CLOSES)" "no-eval re-queue (ga-5w2gpw)" \
  && ok "no-eval: marker comment, gate-run comment and close reason name ga-5w2gpw, say no verdict was delivered, and say NOT a code FAIL" \
  || bad "no-eval wording missing: marker=[$(cmt "$MARKER_ID")] run=[$(cmt "$GATE_RUN_ID")] closes=[$(getl CLOSES)]"
has "$(cmt vb-e6a)" "VERDICT: REQUEUED (ga-5w2gpw)" \
  && ok "no-eval: the verdict bead is parked REQUEUED with the no-eval tag" \
  || bad "no-eval verdict-bead comment missing: [$(cmt vb-e6a)]"
has "$(getl BD)" "label remove $BEAD_ID gate:reviewing" \
  && ok "no-eval: gate:reviewing is cleared on the source bead (same head-of-line guard as the other requeues, ga-n2cpe)" \
  || bad "no-eval must clear gate:reviewing: bd=[$(getl BD)]"
! has "$(getl BD)" "GATE-FEEDBACK" && ! has "$(getl BD)" "gate:needs-fix" && ! has "$(getl BD)" "gate:failed" && ! has "$(getl BD)" "gate:fix-attempt" && ! has "$(getl BD)" "gate-sha-failed" \
  && ok "no-eval: NOTHING FAIL-shaped is written — no GATE-FEEDBACK, no gate:failed / needs-fix / fix-attempt, no gate-sha-failed stamp" \
  || bad "no-eval wrote FAIL-shaped state: bd=[$(getl BD)]"
has "$(getl NOTIFY)" "re-enfileirado" \
  && ok "no-eval: the push notice says the gate was re-queued" \
  || bad "no-eval push notice missing: [$(getl NOTIFY)]"

new_case "type:quality-gate-marker gate-status:dispatching gate-status:needs-rebase"
run_infra no-eval
MKC="$(cmt "$MARKER_ID")"; GRC="$(cmt "$GATE_RUN_ID")"
[ "$(getl GS)" = "gate-status:needs-rebase" ] && ! has "$(getl STATUS)" "$MARKER_ID:queued" && has "$OUT" "RC=0" \
   && has "$MKC" "NOT applied" && ! has "$MKC" "Marker re-queued" && has "$GRC" "NOT re-queued" && [ -z "$(getl NOTIFY)" ] \
  && ok "no-eval: an external needs-rebase present at the closing write survives, and no message claims a requeue that did not happen (ga-dl3x9s contract)" \
  || bad "no-eval must respect an external transition honestly: GS='$(getl GS)' marker=[$MKC] run=[$GRC] notify=[$(getl NOTIFY)]"

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
[ -n "$GFR_START" ] && [ -n "$GLUE_LINE" ] && [ -n "$INFRA_LINE" ] && [ "$GFR_START" -lt "$GLUE_LINE" ] && [ "$GLUE_LINE" -lt "$INFRA_LINE" ] \
  && ok "the no-eval glue is inside gate_finalize_run and runs BEFORE the infra-requeue block it feeds (order matters: after it the flag would be consumed too late)" \
  || bad "wiring order wrong or glue missing: gate_finalize_run=$GFR_START glue=$GLUE_LINE infra=$INFRA_LINE"

echo "gate-e6a-noeval-requeue selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
