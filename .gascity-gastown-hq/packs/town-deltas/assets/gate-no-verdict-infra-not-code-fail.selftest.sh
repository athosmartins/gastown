#!/usr/bin/env bash
# gate-no-verdict-infra-not-code-fail.selftest.sh (ga-w7pm55)
#
# BUG (ga-w7pm55, flagged by thies-wa in the Travadas triage 2026-09-25, wa-hnfue
# and wa-vrd4r): when a gate reviewer DIES before judging the code (reboot, a
# session with no login, a drain) and its verdict bead ends up CLOSED with
# verdict:pending / no verdict label / verdict:TIMEOUT / verdict:ABORTED and no
# reviewer text, gate_collect_verdicts() took its last branch ("Any other label
# -> FAIL"), set ANY_FAIL=1, and gate_finalize_run() — never told that nobody
# evaluated anything — left GATE_SHA_FAIL_CLASS at its "code" default. The
# commit was stamped gate-sha-failed:<sha>:code, so the resubmission of the SAME
# unchanged commit was skipped by the ga-l7mvtw stale-SHA guard ("already
# rejected") without any reviewer ever having rejected it.
#
# FIX: gate_collect_verdicts() now tells "a reviewer judged this" from "no
# verdict was delivered" and, when the run's FAILs are ALL of the second kind,
# raises the existing GATE_FAIL_NO_EVAL relay (ga-mcapdq) so gate_finalize_run
# classes the stamp "hold" and leaves gate:fix-attempt alone. A verdict:FAIL —
# or an anchored "VERDICT: FAIL" reviewer comment whose label add lost a race —
# is still a judgment and stays "code".
#
# Invariants under test:
#   a) closed verdict bead with pending / no label / TIMEOUT / ABORTED and no FAIL
#      text -> ANY_FAIL=1 (still not a PASS) AND stamp class "hold".
#   b) a real reviewer FAIL (label, empty-reason label, or comment-only) stays
#      class "code" — ga-nooaw fail-closed-by-SHA is not weakened.
#   c) mixed runs: any judged FAIL wins ("code"); PASS + no-verdict is "hold".
#   d) the relay is recomputed on every call, so a stale 1 from a prior bead
#      cannot survive into the next collect (same leak concern as ga-mcapdq).
#   e) the FAIL_REASONS text keeps "closed without explicit PASS" for the infra
#      case (the sweep that cleans old stamps greps it) and says it is infra.
#   f) three states, not two: when the reviewer's comments cannot be READ (bd or
#      jq failed) a FAIL text cannot be ruled out, so the run stays class "code"
#      (blocking) — the permissive "hold" needs a SUCCESSFUL read with no FAIL text.
#   g) MUTATION: each of the four moving parts, removed one at a time, turns a
#      specific case red — proof the suite is not vacuous.
#
# Strategy: extract the live "gate-collect-verdicts-fn", "gate-verdict-identity-
# link-fn", "session-peek-reports-dead-fn" and "finalize-failclass-reset" blocks
# VERBATIM (real production code, not a copy) and stub only the I/O boundary
# (bd, gc, log, warn). Fixtures live in files, so the harness stays bash-3.2 safe
# (no associative arrays). Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-no-verdict-infra-not-code-fail.selftest (ga-w7pm55) =="

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

# mk_vb <dir> <id> <status> <labels-csv> <comments-json>
mk_vb() {
  local dir="$1" id="$2" status="$3" labels="$4" comments="$5" arr="" l
  local IFS_SAVE="$IFS"; IFS=','
  for l in $labels; do arr="${arr:+$arr,}\"$l\""; done
  IFS="$IFS_SAVE"
  printf '{"status":"%s","labels":["type:quality-gate-verdict"%s],"assignee":"reviewer-%s"}\n' \
    "$status" "${arr:+,$arr}" "$id" > "$dir/$id.json"
  printf '%s\n' "$comments" > "$dir/$id.comments.json"
}

# run_case <dispatcher-file> <fixture-dir> <preset_no_eval> <id>... -> stdout:
#   RESULT|VR=<n>|ANY_FAIL=<0|1>|NO_EVAL=<0|1>|CLASS=<code|hold>|FAIL_REASONS=<text>
# The gate_collect_verdicts block is chained straight into the real
# finalize-failclass-reset block, so CLASS is the outcome the stamp would get.
run_case() {
  local file="$1" fix="$2" preset="$3"; shift 3
  local fn_collect fn_peek fn_link fn_reset
  fn_collect="$(extract_block "$file" "gate-collect-verdicts-fn")"
  fn_peek="$(extract_block "$file" "session-peek-reports-dead-fn")"
  fn_link="$(extract_block "$file" "gate-verdict-identity-link-fn")"
  fn_reset="$(extract_block "$file" "finalize-failclass-reset")"
  if [ -z "$fn_collect" ] || [ -z "$fn_peek" ] || [ -z "$fn_link" ] || [ -z "$fn_reset" ]; then
    echo "COULD_NOT_EXTRACT_BLOCK"; return 99
  fi
  bash -c '
    set -euo pipefail
    GC_CITY="/fake/city"
    FIX="$1"; PRESET="$2"; shift 2
    VERDICT_BEAD_IDS=("$@")
    bd() {
      local sub="" id="" a
      for a in "$@"; do
        case "$a" in
          show|comments|close) sub="$a" ;;
          -*|/*) : ;;
          *) [ -n "$sub" ] && [ -z "$id" ] && id="$a" ;;
        esac
      done
      case "$sub" in
        show)     cat "$FIX/$id.json" ;;
        comments) [ -f "$FIX/$id.comments.fail" ] && return 1
                  cat "$FIX/$id.comments.json" ;;
        *)        : ;;
      esac
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
    GATE_FAIL_NO_EVAL="$PRESET"
    gate_collect_verdicts
    NO_EVAL_AFTER_COLLECT="${GATE_FAIL_NO_EVAL:-0}"
    GATE_SHA_FAIL_CLASS="code"
    finalize_reset
    printf "RESULT|VR=%s|ANY_FAIL=%s|NO_EVAL=%s|CLASS=%s|FAIL_REASONS=%s\n" \
      "$VERDICTS_RECEIVED" "$ANY_FAIL" "$NO_EVAL_AFTER_COLLECT" "$GATE_SHA_FAIL_CLASS" "$FAIL_REASONS"
  ' _ "$fix" "$preset" "$@" 2>&1
}

# expect <label> <result-line> <any_fail> <no_eval> <class>
expect() {
  local label="$1" line="$2" af="$3" ne="$4" cl="$5"
  case "$line" in
    *"|ANY_FAIL=$af|NO_EVAL=$ne|CLASS=$cl|"*) ok "$label -> ANY_FAIL=$af NO_EVAL=$ne CLASS=$cl" ;;
    *) bad "$label — expected ANY_FAIL=$af NO_EVAL=$ne CLASS=$cl, got: $line" ;;
  esac
}

FIX="$(mktemp -d "${TMPDIR:-/tmp}/gate-noverdict-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT
NOEXT="[]"

echo "── 1. no verdict delivered (reviewer died) -> INFRA / hold, still not a PASS ──"
mk_vb "$FIX" r-pending closed "verdict:pending" "$NOEXT"
L="$(run_case "$DISPATCHER" "$FIX" 0 r-pending)"
expect "closed with verdict:pending, no comments" "$L" 1 1 hold
case "$L" in *"closed without explicit PASS"*) ok "FAIL_REASONS keeps the 'closed without explicit PASS' text (sweep greps it)" ;;
  *) bad "FAIL_REASONS lost 'closed without explicit PASS' — $L" ;; esac
case "$L" in *"ga-w7pm55"*) ok "FAIL_REASONS tells the builder it is infra, not a code rejection (cites ga-w7pm55)" ;;
  *) bad "FAIL_REASONS does not say this is infra — the builder is told to 'fix' code nobody judged: $L" ;; esac

mk_vb "$FIX" r-nolabel closed "" "$NOEXT"
expect "closed, no verdict label at all" "$(run_case "$DISPATCHER" "$FIX" 0 r-nolabel)" 1 1 hold

mk_vb "$FIX" r-timeout closed "verdict:TIMEOUT" '[{"text":"VERDICT: TIMEOUT — reviewer session did not complete within 30m"}]'
expect "closed, verdict:TIMEOUT + timeout comment" "$(run_case "$DISPATCHER" "$FIX" 0 r-timeout)" 1 1 hold

mk_vb "$FIX" r-aborted closed "verdict:ABORTED" '[{"text":"VERDICT: ABORTED"}]'
expect "closed, verdict:ABORTED without FAIL text" "$(run_case "$DISPATCHER" "$FIX" 0 r-aborted)" 1 1 hold

mk_vb "$FIX" r-quote closed "verdict:pending" '[{"text":"NOTE: session drained; an earlier run said VERDICT: FAIL on another commit"}]'
expect "closed, comment merely QUOTES 'VERDICT: FAIL' mid-text (unanchored)" "$(run_case "$DISPATCHER" "$FIX" 0 r-quote)" 1 1 hold

echo "── 2. a reviewer that JUDGED still yields class code (ga-nooaw not weakened) ──"
mk_vb "$FIX" r-fail closed "verdict:FAIL" '[{"text":"VERDICT: FAIL — race condition in shared cache"}]'
L="$(run_case "$DISPATCHER" "$FIX" 0 r-fail)"
expect "closed verdict:FAIL with reviewer text" "$L" 1 0 code
case "$L" in *"race condition in shared cache"*) ok "the reviewer's own reason still reaches FAIL_REASONS" ;;
  *) bad "reviewer FAIL text lost — $L" ;; esac

mk_vb "$FIX" r-fail-empty closed "verdict:FAIL" "$NOEXT"
expect "closed verdict:FAIL with NO parseable reason (INCONCLUSIVE, fail-safe)" "$(run_case "$DISPATCHER" "$FIX" 0 r-fail-empty)" 1 0 code

mk_vb "$FIX" r-fail-comment closed "" '[{"text":"VERDICT: FAIL — off-by-one in the retry cap"}]'
L="$(run_case "$DISPATCHER" "$FIX" 0 r-fail-comment)"
expect "closed, label add lost the race but anchored 'VERDICT: FAIL' comment landed" "$L" 1 0 code
case "$L" in *"off-by-one in the retry cap"*) ok "comment-only FAIL: reviewer's reason reaches FAIL_REASONS" ;;
  *) bad "comment-only FAIL lost its reason — $L" ;; esac

echo "── 2b. THREE states: 'could not read the comments' must never relax to hold ──"
# error-vs-empty: an empty FAIL_COMMENT means "no FAIL text" only if the read
# SUCCEEDED. If bd or jq failed we cannot rule out a real reviewer FAIL, and the
# permissive classification (hold = same SHA re-reviewable) would let a rejected
# commit re-earn a PASS — the ga-nooaw hazard. Unreadable stays class code.
mk_vb "$FIX" r-bdfail closed "verdict:pending" "$NOEXT"
: > "$FIX/r-bdfail.comments.fail"
L="$(run_case "$DISPATCHER" "$FIX" 0 r-bdfail)"
expect "no-verdict bead whose 'bd comments' read FAILED" "$L" 1 0 code
case "$L" in *"could not be read"*) ok "FAIL_REASONS says the comments were unreadable (not 'infra')" ;;
  *) bad "unreadable-comments FAIL_REASONS is not explicit — $L" ;; esac
mk_vb "$FIX" r-garbage closed "verdict:pending" "this-is-not{json"
expect "no-verdict bead whose comments are unparseable (jq fails)" "$(run_case "$DISPATCHER" "$FIX" 0 r-garbage)" 1 0 code
expect "PASS + unreadable-comments no-verdict bead -> code, not hold" "$(run_case "$DISPATCHER" "$FIX" 0 r-pass r-bdfail)" 1 0 code

echo "── 3. PASS paths are untouched ──"
mk_vb "$FIX" r-pass closed "verdict:PASS" "$NOEXT"
expect "closed verdict:PASS" "$(run_case "$DISPATCHER" "$FIX" 0 r-pass)" 0 0 code
mk_vb "$FIX" r-pass-comment closed "" '[{"text":"VERDICT: PASS — clean"}]'
expect "closed, no label but anchored PASS comment (ga-86l90a8 rescue)" "$(run_case "$DISPATCHER" "$FIX" 0 r-pass-comment)" 0 0 code
mk_vb "$FIX" r-open open "" "$NOEXT"
L="$(run_case "$DISPATCHER" "$FIX" 0 r-open)"
expect "still-open bead (reviewer may be mid-work) is not a FAIL" "$L" 0 0 code
case "$L" in *"|VR=0|"*) ok "still-open bead is not counted as delivered" ;; *) bad "open bead counted: $L" ;; esac

echo "── 4. mixed runs: any judged FAIL wins; PASS + no-verdict is infra ──"
expect "reviewer 1 judged FAIL + reviewer 2 no-verdict" "$(run_case "$DISPATCHER" "$FIX" 0 r-fail r-pending)" 1 0 code
expect "reviewer 1 no-verdict + reviewer 2 judged FAIL (order independent)" "$(run_case "$DISPATCHER" "$FIX" 0 r-pending r-fail)" 1 0 code
expect "reviewer 1 PASS + reviewer 2 no-verdict" "$(run_case "$DISPATCHER" "$FIX" 0 r-pass r-pending)" 1 1 hold
expect "reviewer 1 no-verdict + reviewer 2 no-verdict" "$(run_case "$DISPATCHER" "$FIX" 0 r-pending r-timeout)" 1 1 hold
expect "all PASS" "$(run_case "$DISPATCHER" "$FIX" 0 r-pass r-pass-comment)" 0 0 code

echo "── 5. anti-leak: the relay is recomputed each call ──"
expect "stale GATE_FAIL_NO_EVAL=1 + an all-PASS collect must NOT stay 1" "$(run_case "$DISPATCHER" "$FIX" 1 r-pass)" 0 0 code
expect "stale GATE_FAIL_NO_EVAL=1 + a judged FAIL must NOT stay 1 (else code -> hold)" "$(run_case "$DISPATCHER" "$FIX" 1 r-fail)" 1 0 code

echo "── 6. MUTATION TESTS: each moving part removed alone must turn a case red ──"
# mutate <anchor-line-fragment> <replacement> <outfile> — anchor must be unique.
mutate() {
  python3 - "$DISPATCHER" "$1" "$2" "$3" <<'PYEOF'
import sys
src, anchor, repl, out = sys.argv[1:5]
c = open(src).read()
n = c.count(anchor)
if n != 1:
    print("ANCHOR_COUNT=%d anchor=%r" % (n, anchor), file=sys.stderr); sys.exit(1)
open(out, "w").write(c.replace(anchor, repl, 1))
PYEOF
}

MUT="$(mktemp "${TMPDIR:-/tmp}/gate-noverdict-mutant-XXXXXX")"
trap 'rm -rf "$FIX" "$MUT"' EXIT

# M1: the relay never fires -> the no-verdict run goes back to class code (the bug).
if mutate 'if [ "$ANY_FAIL" = "1" ] && [ "$_judged_fails" -eq 0 ] && [ "$_noverdict_fails" -gt 0 ]; then' 'if false; then' "$MUT"; then
  L="$(run_case "$MUT" "$FIX" 0 r-pending)"
  case "$L" in *"|CLASS=code|"*) ok "M1 (relay disabled): no-verdict run is class code again — reproduces ga-w7pm55" ;;
    *) bad "M1 (relay disabled) did not reproduce the bug — suite may be vacuous: $L" ;; esac
else bad "M1: could not build mutant (anchor not unique — source shape changed?)"; fi

# M2: the comment-FAIL rescue is off -> a comment-only reviewer FAIL is misread as infra (hold).
if mutate 'if [ -n "$FAIL_COMMENT" ]; then' 'if false; then' "$MUT"; then
  L="$(run_case "$MUT" "$FIX" 0 r-fail-comment)"
  case "$L" in *"|CLASS=hold|"*) ok "M2 (comment-FAIL rescue disabled): a real reviewer FAIL is downgraded to hold — the rescue is load-bearing" ;;
    *) bad "M2 (comment-FAIL rescue disabled) did not misclassify — suite may be vacuous: $L" ;; esac
else bad "M2: could not build mutant (anchor not unique — source shape changed?)"; fi

# M3: the per-call reset is gone -> a stale 1 leaks into an unrelated collect.
if mutate '  GATE_FAIL_NO_EVAL=0
  local _judged_fails=0 _noverdict_fails=0' '  local _judged_fails=0 _noverdict_fails=0' "$MUT"; then
  L="$(run_case "$MUT" "$FIX" 1 r-fail)"
  case "$L" in *"|NO_EVAL=1|CLASS=hold|"*) ok "M3 (reset removed): a stale relay turns a judged FAIL into hold — the per-call reset is load-bearing" ;;
    *) bad "M3 (reset removed) did not leak — suite may be vacuous: $L" ;; esac
else bad "M3: could not build mutant (anchor not unique — source shape changed?)"; fi

# M4: the unreadable-comments fail-safe is off -> a failed comments read is misread as
# "no FAIL text" and a possibly-real reviewer FAIL is relaxed to hold.
if mutate 'elif [ "$FAIL_COMMENT_UNREADABLE" = "1" ]; then' 'elif false; then' "$MUT"; then
  L="$(run_case "$MUT" "$FIX" 0 r-bdfail)"
  case "$L" in *"|CLASS=hold|"*) ok "M4 (unreadable fail-safe disabled): a failed comments read is relaxed to hold — the third state is load-bearing" ;;
    *) bad "M4 (unreadable fail-safe disabled) did not misclassify — suite may be vacuous: $L" ;; esac
else bad "M4: could not build mutant (anchor not unique — source shape changed?)"; fi

echo ""
echo "== gate-no-verdict-infra-not-code-fail: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
