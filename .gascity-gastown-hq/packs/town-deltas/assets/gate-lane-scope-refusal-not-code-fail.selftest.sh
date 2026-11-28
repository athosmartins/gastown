#!/usr/bin/env bash
# gate-lane-scope-refusal-not-code-fail.selftest.sh (ga-wnaxl43) — REPRODUCTION of the bug, locked by repro-lock before the fix.
#
# BUG (seen on wa-4e3efc, 28/11): the task-rapida lane judges by PATH only (gate-task-rapida-risco.txt), so a diff that writes customer
# data under a neutral path (daemons/routes/cls_property.py: the classifications table + a CRM push) gets the lane. The lane's reviewer
# then runs its SCOPE CHECK by content and refuses (gate-review-task.lib.sh): ONE blocking issue "out of the task-rapida scope: <what it
# touches>", "add the label gate:normal-only and resubmit", nothing else reviewed. The dispatcher stamped that FAIL like any judged one,
# gate-sha-failed:<sha>:code, so the resubmission of the SAME commit with gate:normal-only was closed by the ga-l7mvtw STALE-SHA guard
# ("already rejected") with no reviewer at all: the advice the gate itself had given could not be followed. Nobody had judged the code.
#
# Strategy (same as gate-no-verdict-infra-not-code-fail.selftest.sh): the live "gate-collect-verdicts-fn" and "finalize-failclass-reset"
# blocks are extracted VERBATIM and chained, only the I/O boundary (bd, gc, log, warn) is stubbed; the stamp's class is then fed to the
# real STALE-SHA predicate (gate_labels_have_sha_fail, sourced lib-only). Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-lane-scope-refusal-not-code-fail.selftest (ga-wnaxl43) =="
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract_block() {
  sed -n "/# SELFTEST-EXTRACT ${2}: BEGIN/,/# SELFTEST-EXTRACT ${2}: END/p" "$1" | sed '1d;$d'
}

# run_case <lane> <verdict-bead-comments-json> -> RESULT|ANY_FAIL=<0|1>|CLASS=<code|hold>|FAIL_REASONS=<text>
run_case() {
  local lane="$1" comments="$2" fix fn_collect fn_peek fn_link fn_reset
  fn_collect="$(extract_block "$DISPATCHER" "gate-collect-verdicts-fn")"
  fn_peek="$(extract_block "$DISPATCHER" "session-peek-reports-dead-fn")"
  fn_link="$(extract_block "$DISPATCHER" "gate-verdict-identity-link-fn")"
  fn_reset="$(extract_block "$DISPATCHER" "finalize-failclass-reset")"
  if [ -z "$fn_collect" ] || [ -z "$fn_peek" ] || [ -z "$fn_link" ] || [ -z "$fn_reset" ]; then
    echo "COULD_NOT_EXTRACT_BLOCK"; return 99
  fi
  fix="$(mktemp -d "${TMPDIR:-/tmp}/gate-lanescope-XXXXXX")"
  printf '{"status":"closed","labels":["type:quality-gate-verdict","verdict:FAIL"],"assignee":"reviewer-r1"}\n' > "$fix/r1.json"
  printf '%s\n' "$comments" > "$fix/r1.comments.json"
  bash -c '
    set -euo pipefail
    GC_CITY="/fake/city"; GATE_LANE="$1"; FIX="$2"
    VERDICT_BEAD_IDS=("r1")
    bd() {
      local sub="" a
      for a in "$@"; do case "$a" in show|comments|close) sub="$a" ;; esac; done
      case "$sub" in show) cat "$FIX/r1.json" ;; comments) cat "$FIX/r1.comments.json" ;; esac
      return 0
    }
    gc()   { echo "gc session peek: session not found" >&2; return 1; }
    log()  { :; }
    warn() { :; }
    '"$fn_peek"'
    '"$fn_link"'
    '"$fn_collect"'
    finalize_reset() {
      '"$fn_reset"'
    }
    gate_collect_verdicts
    GATE_SHA_FAIL_CLASS="code"
    finalize_reset
    printf "RESULT|ANY_FAIL=%s|CLASS=%s|FAIL_REASONS=%s\n" "$ANY_FAIL" "$GATE_SHA_FAIL_CLASS" "$FAIL_REASONS"
  ' _ "$lane" "$fix" 2>&1
  rm -rf "$fix"
}

# stale_guard_says <labels> <sha> -> what the ga-l7mvtw STALE-SHA guard would answer for a bead carrying these labels: yes (skip the
# marker, no reviewer) | no | LIBFAIL (the dispatcher could not be sourced lib-only: never read as "no")
stale_guard_says() {
  bash -c 'GATE_DISPATCHER_LIB_ONLY=1 source "$1" >/dev/null 2>&1 || { echo LIBFAIL; exit 0; }
           gate_labels_have_sha_fail "$2" "$3"' _ "$DISPATCHER" "$1" "$2"
}

# the verdict the wa-4e3efc reviewer delivered (shape: gate-review-task.lib.sh SCOPE CHECK + the closed root-class set)
SCOPE_REFUSAL='[{"text":"VERDICT: FAIL\nBlocking issue 1: out of the task-rapida scope: daemons/routes/cls_property.py rewrites the writer of the classifications table (contacts, leads) and re-pushes deals to the CRM (Pipedrive); nothing else was reviewed. Builder: add the label gate:normal-only to the source bead (wa-4e3efc) and resubmit, so the normal gate reviews it. root-class:wrong-scope\nNon-blocking findings: none"}]'
SHA="4e8837512"

echo "── 1. a lane scope refusal is not a code rejection ──"
L="$(run_case task-rapida "$SCOPE_REFUSAL")"
case "$L" in
  *"|ANY_FAIL=1|CLASS=hold|"*) ok "task-rapida run, single scope refusal -> still a FAIL (ANY_FAIL=1), stamped class hold" ;;
  *) bad "task-rapida run, single scope refusal: expected ANY_FAIL=1 CLASS=hold, got: ${L%%|FAIL_REASONS=*}" ;;
esac
case "$L" in *"out of the task-rapida scope"*) ok "the reviewer's own words still reach FAIL_REASONS (the builder is told what to do)" ;;
  *) bad "the scope refusal text did not reach FAIL_REASONS: $L" ;; esac

echo "── 2. the symptom: the same commit, resubmitted with gate:normal-only, must not be closed by STALE-SHA ──"
CLS="${L#*|CLASS=}"; CLS="${CLS%%|*}"
S="$(stale_guard_says "gate:failed gate:needs-fix gate:fix-attempt:1 gate:normal-only gate-sha-failed:$SHA:$CLS" "$SHA")"
case "$S" in
  no)      ok "STALE-SHA guard lets the resubmission through (stamp class '$CLS'): a reviewer will see it" ;;
  LIBFAIL) bad "could not source the dispatcher lib-only to ask the STALE-SHA predicate" ;;
  *)       bad "the resubmission would be closed by STALE-SHA with no reviewer: guard says '$S' for stamp class '$CLS'" ;;
esac

echo ""
echo "== gate-lane-scope-refusal-not-code-fail: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
