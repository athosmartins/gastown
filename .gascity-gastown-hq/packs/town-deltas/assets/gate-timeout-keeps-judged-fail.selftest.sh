#!/usr/bin/env bash
# gate-timeout-keeps-judged-fail.selftest.sh (ga-h8vc8y)
#
# BUG (ga-h8vc8y, side finding of ga-w7pm55, 2026-09-25): Phase C's genuine-
# timeout branch ("one reviewer is alive but slow") ran AFTER
# gate_collect_verdicts() and, without looking at what the collect found, did
#     FAIL_REASONS="TIMEOUT: ..."          (REPLACING the collected reasons)
#     GATE_FAIL_NO_EVAL=1                  (== "nobody judged the code")
# With required_reviewers >= 2 that is wrong whenever one reviewer had ALREADY
# delivered a real verdict:FAIL and the other one merely timed out: the
# rejecting reviewer's text was thrown away (the builder saw only "TIMEOUT"),
# the SHA was stamped gate-sha-failed:<sha>:HOLD instead of :CODE — so the SAME
# rejected commit could earn a PASS on a re-review, the exact hazard ga-nooaw
# exists to stop — and gate:fix-attempt was not counted.
#
# FIX: gate_collect_verdicts() now also exposes its judged-FAIL count as the
# per-call global GATE_COLLECT_JUDGED_FAILS. The timeout branch keeps the
# collect's FAIL_REASONS (timeout note appended) and does NOT raise
# GATE_FAIL_NO_EVAL when that count is > 0. With no judged FAIL anywhere it is
# unchanged: reason "TIMEOUT: ...", no-eval signal raised (class hold, counter
# untouched).
#
# Invariants under test:
#   a) judged FAIL + slow reviewer  -> class code, counter bumps, the rejecting
#      reviewer's own text reaches FAIL_REASONS, ahead of the timeout note.
#      (verdict:FAIL label, empty-reason label, comment-only FAIL, and the
#      fail-safe "comments unreadable" state all count as judged.)
#   b) NON-REGRESSION: no judged FAIL (PASS + slow, no-verdict + slow, nobody
#      delivered) -> exactly the pre-existing ga-mcapdq outcome: class hold,
#      counter untouched, reason is the bare TIMEOUT line.
#   c) the count is recomputed on every collect (a stale value cannot leak).
#   d) an UNSET count (collect did not run) reads as 0 under `set -u` and keeps
#      the old no-evaluation behavior — other harnesses run this block bare.
#   e) MUTATION: each moving part removed alone turns a specific case red.
#
# Strategy: extract the live "gate-collect-verdicts-fn", "phase-c-timeout-
# classify", "finalize-failclass-reset" and "finalize-fixattempt-bump" blocks
# VERBATIM (real production code) and chain them in the order production runs
# them; stub only the I/O boundary (bd, gc, log, warn). Inner shell is
# /bin/bash (3.2 on macOS — the shell the gate really runs under), fixtures live
# in files (no associative arrays). Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
REAL_BASH="${REAL_BASH:-/bin/bash}"
[ -x "$REAL_BASH" ] || REAL_BASH="bash"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-timeout-keeps-judged-fail.selftest (ga-h8vc8y) =="

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

# run_timeout_case <dispatcher-file> <fixture-dir> <prev_attempt> <id>...
#   -> RESULT|OVERALL=<v>|NO_EVAL=<0|1>|CLASS=<code|hold>|NEW_ATTEMPT=<n>|FAIL_REASONS=<text>
# Order = production's: collect -> (timeout, no live-reviewer death) classify ->
# finalize's fail-class reset -> finalize's fix-attempt bump. NO_EVAL is read
# right after the timeout block, before finalize consumes (and zeroes) it.
run_timeout_case() {
  local file="$1" fix="$2" prev="$3"; shift 3
  local fn_collect fn_peek fn_link fn_classify fn_reset fn_bump
  fn_collect="$(extract_block "$file" "gate-collect-verdicts-fn")"
  fn_peek="$(extract_block "$file" "session-peek-reports-dead-fn")"
  fn_link="$(extract_block "$file" "gate-verdict-identity-link-fn")"
  fn_classify="$(extract_block "$file" "phase-c-timeout-classify")"
  fn_reset="$(extract_block "$file" "finalize-failclass-reset")"
  fn_bump="$(extract_block "$file" "finalize-fixattempt-bump")"
  if [ -z "$fn_collect" ] || [ -z "$fn_peek" ] || [ -z "$fn_link" ] || [ -z "$fn_classify" ] \
     || [ -z "$fn_reset" ] || [ -z "$fn_bump" ]; then
    echo "COULD_NOT_EXTRACT_BLOCK collect=${#fn_collect} peek=${#fn_peek} link=${#fn_link} classify=${#fn_classify} reset=${#fn_reset} bump=${#fn_bump}"
    return 99
  fi
  "$REAL_BASH" -c '
    set -euo pipefail
    GC_CITY="/fake/city"
    FIX="$1"; PREV="$2"; shift 2
    VERDICT_BEAD_IDS=("$@")
    PC_TIMEOUT_MIN=15
    bd() {
      case " $* " in
        *" label "*) echo "$*" >> "$FIX/bd.label.log"; return 0 ;;
      esac
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
    finalize_chain() {
      '"$fn_reset"'
      '"$fn_bump"'
    }
    : > "$FIX/bd.label.log"
    gate_collect_verdicts
    '"$fn_classify"'
    NO_EVAL_AT_TIMEOUT="${GATE_FAIL_NO_EVAL:-0}"
    GATE_SHA_FAIL_CLASS="code"
    PREV_ATTEMPT="$PREV"; BEAD_ID="bead-1"; BEAD_CITY="/fake/city"; GATE_FIX_CAP=3
    SRC_LABELS="gate:fix-attempt:$PREV area:gate"
    finalize_chain
    printf "RESULT|OVERALL=%s|NO_EVAL=%s|CLASS=%s|NEW_ATTEMPT=%s|FAIL_REASONS=%s\n" \
      "$OVERALL_VERDICT" "$NO_EVAL_AT_TIMEOUT" "$GATE_SHA_FAIL_CLASS" "$NEW_ATTEMPT" "$FAIL_REASONS"
  ' _ "$fix" "$prev" "$@" 2>&1
}

# expect <label> <result-line> <no_eval> <class> <new_attempt>
expect() {
  local label="$1" line="$2" ne="$3" cl="$4" na="$5"
  case "$line" in
    *"|OVERALL=FAIL|NO_EVAL=$ne|CLASS=$cl|NEW_ATTEMPT=$na|"*) ok "$label -> NO_EVAL=$ne CLASS=$cl NEW_ATTEMPT=$na" ;;
    *) bad "$label — expected NO_EVAL=$ne CLASS=$cl NEW_ATTEMPT=$na, got: $line" ;;
  esac
}

FIX="$(mktemp -d "${TMPDIR:-/tmp}/gate-timeout-judged-XXXXXX")"
MUT="$(mktemp "${TMPDIR:-/tmp}/gate-timeout-judged-mutant-XXXXXX")"
trap 'rm -rf "$FIX" "$MUT"' EXIT
NOEXT="[]"
TMO="TIMEOUT: reviewers did not submit verdicts within 15 minutes."

# reviewer 1 delivered; reviewer 2 (r-slow) is alive but has not closed its bead.
mk_vb "$FIX" r-slow open "" "$NOEXT"
mk_vb "$FIX" r-fail closed "verdict:FAIL" '[{"text":"VERDICT: FAIL — race condition in shared cache"}]'
mk_vb "$FIX" r-fail-empty closed "verdict:FAIL" "$NOEXT"
mk_vb "$FIX" r-fail-comment closed "" '[{"text":"VERDICT: FAIL — off-by-one in the retry cap"}]'
mk_vb "$FIX" r-pass closed "verdict:PASS" "$NOEXT"
mk_vb "$FIX" r-nov closed "verdict:pending" "$NOEXT"
mk_vb "$FIX" r-bdfail closed "verdict:pending" "$NOEXT"
: > "$FIX/r-bdfail.comments.fail"

echo "── 1. THE BUG: one reviewer already rejected, the other timed out -> the rejection stands ──"
L="$(run_timeout_case "$DISPATCHER" "$FIX" 1 r-fail r-slow)"
expect "verdict:FAIL (with text) + slow reviewer" "$L" 0 code 2
case "$L" in *"race condition in shared cache"*) ok "the rejecting reviewer's own text reaches FAIL_REASONS (builder sees WHY)" ;;
  *) bad "rejecting reviewer's text was lost — the builder would see only TIMEOUT: $L" ;; esac
case "$L" in *"$TMO"*) ok "the timeout note is still recorded" ;; *) bad "timeout note missing: $L" ;; esac
case "$L" in *"race condition in shared cache"*"TIMEOUT: reviewers did not submit"*) ok "reviewer text comes BEFORE the timeout note" ;;
  *) bad "order wrong (timeout note must follow the reviewer's reasons): $L" ;; esac
if grep -q 'gate:fix-attempt:2' "$FIX/bd.label.log" && grep -q 'gate:fix-attempt:1' "$FIX/bd.label.log"; then
  ok "fix-attempt counted: stale :1 removed, :2 added"
else
  bad "fix-attempt not bumped for a judged FAIL — labels: $(tr '\n' ';' < "$FIX/bd.label.log")"
fi

expect "slow reviewer listed FIRST (order independent)" "$(run_timeout_case "$DISPATCHER" "$FIX" 1 r-slow r-fail)" 0 code 2
expect "verdict:FAIL label with an EMPTY reason (still a judgment)" "$(run_timeout_case "$DISPATCHER" "$FIX" 1 r-fail-empty r-slow)" 0 code 2
L="$(run_timeout_case "$DISPATCHER" "$FIX" 1 r-fail-comment r-slow)"
expect "comment-only anchored 'VERDICT: FAIL' (label lost the race)" "$L" 0 code 2
case "$L" in *"off-by-one in the retry cap"*) ok "comment-only FAIL: reviewer's reason reaches FAIL_REASONS" ;; *) bad "comment-only FAIL lost its reason: $L" ;; esac
expect "no-verdict bead whose comments are UNREADABLE + slow (fail-safe stays code, ga-w7pm55 3rd state)" \
  "$(run_timeout_case "$DISPATCHER" "$FIX" 1 r-bdfail r-slow)" 0 code 2
expect "judged FAIL + a no-verdict reviewer + a slow reviewer (3 slots)" "$(run_timeout_case "$DISPATCHER" "$FIX" 1 r-fail r-nov r-slow)" 0 code 2

echo "── 2. NON-REGRESSION: nobody judged the code -> unchanged ga-mcapdq outcome (hold, counter frozen) ──"
L="$(run_timeout_case "$DISPATCHER" "$FIX" 1 r-pass r-slow)"
expect "PASS + slow reviewer" "$L" 1 hold 1
case "$L" in *"|FAIL_REASONS=$TMO") ok "reason is the bare TIMEOUT line, exactly as before" ;; *) bad "reason changed for a no-judgment timeout: $L" ;; esac
if [ ! -s "$FIX/bd.label.log" ] || ! grep -q 'gate:fix-attempt' "$FIX/bd.label.log"; then ok "counter untouched (no gate:fix-attempt label call)"; else bad "counter touched: $(tr '\n' ';' < "$FIX/bd.label.log")"; fi
expect "no-verdict (reviewer died) + slow reviewer" "$(run_timeout_case "$DISPATCHER" "$FIX" 1 r-nov r-slow)" 1 hold 1
expect "nobody delivered anything (two slow reviewers)" "$(run_timeout_case "$DISPATCHER" "$FIX" 1 r-slow r-slow)" 1 hold 1

echo "── 3. the judged-FAIL count is recomputed on EVERY collect (no stale leak) ──"
LEAK="$("$REAL_BASH" -c '
  set -euo pipefail
  GC_CITY="/fake/city"; FIX="$1"
  bd() { local sub="" id="" a; for a in "$@"; do case "$a" in show|comments|close) sub="$a" ;; -*|/*) : ;; *) [ -n "$sub" ] && [ -z "$id" ] && id="$a" ;; esac; done
         case "$sub" in show) cat "$FIX/$id.json" ;; comments) cat "$FIX/$id.comments.json" ;; esac; return 0; }
  gc() { return 1; }; log() { :; }; warn() { :; }
  '"$(extract_block "$DISPATCHER" "session-peek-reports-dead-fn")"'
  '"$(extract_block "$DISPATCHER" "gate-verdict-identity-link-fn")"'
  '"$(extract_block "$DISPATCHER" "gate-collect-verdicts-fn")"'
  VERDICT_BEAD_IDS=(r-fail r-slow); gate_collect_verdicts; A="$GATE_COLLECT_JUDGED_FAILS"
  VERDICT_BEAD_IDS=(r-pass r-slow); gate_collect_verdicts; B="$GATE_COLLECT_JUDGED_FAILS"
  printf "FIRST=%s|SECOND=%s\n" "$A" "$B"
' _ "$FIX" 2>&1)"
case "$LEAK" in *"FIRST=1|SECOND=0"*) ok "count is 1 for a judged FAIL, then back to 0 for the next collect — got: $LEAK" ;;
  *) bad "count leaked between collects — got: $LEAK" ;; esac

echo "── 4. set -u safety: the block run bare (count unset, FAIL_REASONS unset) keeps the old behavior ──"
BARE="$("$REAL_BASH" -c '
  set -euo pipefail
  PC_TIMEOUT_MIN=15; GATE_FAIL_NO_EVAL=0
  '"$(extract_block "$DISPATCHER" "phase-c-timeout-classify")"'
  printf "OVERALL=%s|NO_EVAL=%s|FAIL_REASONS=%s\n" "$OVERALL_VERDICT" "$GATE_FAIL_NO_EVAL" "$FAIL_REASONS"
' 2>&1)"
case "$BARE" in "OVERALL=FAIL|NO_EVAL=1|FAIL_REASONS=$TMO") ok "bare run under set -euo pipefail: FAIL, no-eval raised, bare TIMEOUT reason (other harnesses, e.g. s4potx, run the block this way)" ;;
  *) bad "bare run changed behavior or aborted under set -u — got: $BARE" ;; esac

echo "── 5. MUTATION TESTS: each moving part removed alone must turn a case red ──"
# mutate <anchor> <replacement> <outfile> — anchor must be unique in the dispatcher.
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

# M1: the timeout branch ignores the count -> the pre-fix bug (hold, reasons replaced).
if mutate 'if [ "${GATE_COLLECT_JUDGED_FAILS:-0}" -gt 0 ]; then' 'if false; then' "$MUT"; then
  L="$(run_timeout_case "$MUT" "$FIX" 1 r-fail r-slow)"
  case "$L" in *"|NO_EVAL=1|CLASS=hold|NEW_ATTEMPT=1|"*) ok "M1 (branch ignores the count): a judged FAIL is downgraded to hold, counter frozen — reproduces ga-h8vc8y" ;;
    *) bad "M1 did not reproduce the bug — suite may be vacuous: $L" ;; esac
  case "$L" in *"race condition"*) bad "M1: reviewer text survived — the FAIL_REASONS assertions are vacuous: $L" ;; *) ok "M1: the rejecting reviewer's text is lost too (the second half of the bug)" ;; esac
else bad "M1: could not build mutant (anchor not unique — source shape changed?)"; fi

# M2: the collect never exposes its count -> the branch always sees 0.
if mutate 'GATE_COLLECT_JUDGED_FAILS="$_judged_fails"  # ga-h8vc8y: read by Phase C'"'"'s timeout branch' ':' "$MUT"; then
  L="$(run_timeout_case "$MUT" "$FIX" 1 r-fail r-slow)"
  case "$L" in *"|NO_EVAL=1|CLASS=hold|"*) ok "M2 (count never exported): judged FAIL becomes hold again — the export is load-bearing" ;;
    *) bad "M2 did not misclassify — suite may be vacuous: $L" ;; esac
else bad "M2: could not build mutant (anchor not unique — source shape changed?)"; fi

# M3: the collected reasons are not saved before the TIMEOUT line -> class is right, text is lost.
if mutate 'PC_COLLECTED_REASONS="${FAIL_REASONS:-}"' 'PC_COLLECTED_REASONS=""' "$MUT"; then
  L="$(run_timeout_case "$MUT" "$FIX" 1 r-fail r-slow)"
  case "$L" in *"|CLASS=code|"*) ok "M3 (reasons not saved): class stays code (that part is independent)" ;; *) bad "M3: class unexpectedly changed: $L" ;; esac
  case "$L" in *"race condition"*) bad "M3: reviewer text survived without the save — the text assertion is vacuous: $L" ;;
    *) ok "M3 (reasons not saved): the rejecting reviewer's text is lost — the save is load-bearing" ;; esac
else bad "M3: could not build mutant (anchor not unique — source shape changed?)"; fi

# M4: the no-evaluation signal is raised even when a reviewer judged (class hold, counter frozen)
#     while the reasons ARE kept — isolates the signal from the text.
if mutate '            GATE_FAIL_NO_EVAL=0
          else' '            GATE_FAIL_NO_EVAL=1
          else' "$MUT"; then
  L="$(run_timeout_case "$MUT" "$FIX" 1 r-fail r-slow)"
  case "$L" in *"|NO_EVAL=1|CLASS=hold|NEW_ATTEMPT=1|"*"race condition"*) ok "M4 (signal raised despite a judged FAIL): hold + frozen counter while the text is kept — the judged arm must not raise the no-eval signal" ;;
    *) bad "M4 did not isolate the signal — suite may be vacuous: $L" ;; esac
else bad "M4: could not build mutant (anchor not unique — source shape changed?)"; fi

echo ""
echo "== gate-timeout-keeps-judged-fail: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
