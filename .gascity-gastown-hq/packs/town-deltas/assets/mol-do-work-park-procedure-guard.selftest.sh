#!/usr/bin/env bash
# mol-do-work-park-procedure-guard.selftest.sh (ga-rswuxy)
#
# Proves mol-do-work.toml's PARK PROCEDURE (the "blocked on infra, not code"
# branch added by ga-rswuxy) aborts immediately when any of its 5 mutating
# `bd` calls fails, instead of continuing to run the remaining calls
# unconditionally.
#
# gate-review history: fix-attempt 1 (branch fix/ga-rswuxy-park-sling-close,
# commit 7ce4f57aa) FAILED review (gate_run=ga-778ta2) with one blocking
# issue: the procedure chained 5 mutating bd calls -- dep --blocks, label
# remove, label add, comment, update --status=closed -- with ZERO error
# checking between them (no &&, no set -e, no exit-code check). If the FIRST
# call (recording the blocker dependency edge) silently failed, steps 2-5
# still ran unconditionally: labels got stripped, a park comment got posted,
# and the sling got closed with gc.outcome=parked -- an audit trail
# indistinguishable from a real success, while {{issue}} was left permanently
# un-dispatchable with no edge to ever re-arm it (third-state collapse: a
# real failure produces the same visible outcome as a real success).
#
# This test extracts the REAL park-procedure block from the deployed formula
# (between sentinel markers) and executes it with a mocked `bd` that can be
# told to fail at any one of its 5 calls, so the assertions cannot silently
# drift from the deployed behavior the way a hand-copied replica could.
#
# Covers:
#   (P1) step 1 (bd dep --blocks) failing aborts before any other call runs
#   (P2) step 2 (bd label remove) failing aborts before steps 3-5 run
#   (P3) step 3 (bd label add) failing aborts before steps 4-5 run
#   (P4) step 4 (bd comment) failing aborts before step 5 runs
#   (P5) step 5 (bd update --status=closed) failing is itself reported
#        (not swallowed) even though steps 1-4 already succeeded
#   (N)  the happy path (no failures) still runs all 5 calls, in order, and
#        completes without aborting -- the fix must not break normal parking
#   (S)  when GC_BEAD_ID equals the issue (or is unset), step 5 is correctly
#        SKIPPED (pre-existing guard, must survive this edit) -- only 4 calls
#   (F)  source drift-guards: deployed formula still guards all 5 calls
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORMULA="$SELF_DIR/../../../formulas/mol-do-work.toml"
[ -f "$FORMULA" ] || FORMULA="$SELF_DIR/../../../.beads/formulas/mol-do-work.toml"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "mol-do-work-park-procedure-guard.selftest.sh (ga-rswuxy)"
echo "  source: $FORMULA"
echo

if [ ! -f "$FORMULA" ]; then
  bad "formula file not found at $FORMULA"
  echo; echo "  PASS=$PASS  FAIL=$FAIL"; exit 1
fi

# ── Extract the REAL park procedure block from the deployed formula ─────────
RAW_PARK_SRC=$(sed -n '/=== MOL-DO-WORK PARK PROCEDURE BEGIN/,/=== MOL-DO-WORK PARK PROCEDURE END/p' "$FORMULA")

if [ -z "$RAW_PARK_SRC" ]; then
  bad "(F0) park procedure sentinels not found in $FORMULA — fix not deployed, or markers renamed"
  echo; echo "  PASS=$PASS  FAIL=$FAIL"; exit 1
fi
ok "(F0) park procedure block found in deployed formula"

# {{issue}} is a mustache placeholder the FORMULA ENGINE substitutes before a
# real agent's shell ever sees this text — replicate that substitution here
# so the extracted text is valid, evaluable bash. <blocking-bead-id> and
# <why it blocks...> are separate, manual-fill placeholders a human/agent
# replaces by hand (not templated, no engine substitution) — left unfilled,
# bash parses the bare angle brackets as I/O redirection (`<blocking-bead-id`
# = read stdin from a file by that literal name) and every call fails for a
# shell-parsing reason unrelated to the mock, which would make every
# assertion below pass or fail for the WRONG reason. Fill them with safe
# literal text first, exactly as real usage requires.
TEST_ISSUE="test-issue-1"
PARK_SRC=$(printf '%s' "$RAW_PARK_SRC" \
  | sed "s/{{issue}}/$TEST_ISSUE/g" \
  | sed 's/<blocking-bead-id>/test-blocker-1/g' \
  | sed 's/<why it blocks, and why this is infra not code>/test park reason/g')

# run_park <fail_at> <gc_bead_id> — evals the extracted block in a SUBSHELL
# (so its `exit 1` on a guarded failure can't kill this test script) with a
# mocked `bd` function that fails on the Nth call (fail_at=0 never fails).
# Writes one line per bd invocation ("<n> <argv...>") to CALL_LOG so callers
# can assert both the call COUNT (did it stop early?) and the call ORDER.
run_park() {
  local fail_at="$1" gc_bead_id="$2" call_log="$3"
  : > "$call_log"
  (
    CALL_NUM=0
    bd() {
      CALL_NUM=$((CALL_NUM+1))
      printf '%s %s\n' "$CALL_NUM" "$*" >> "$call_log"
      if [ "$CALL_NUM" -eq "$fail_at" ]; then
        return 1
      fi
      return 0
    }
    GC_BEAD_ID="$gc_bead_id"
    eval "$PARK_SRC"
    echo "PARK_COMPLETED"
  )
}

count_calls() { wc -l < "$1" | tr -d ' '; }

# ── (P1)-(P4): each of steps 1-4 failing aborts before the next call ────────
declare -a STEP_NAMES=("" "bd dep (blocker edge)" "bd label remove" "bd label add" "bd comment")
for n in 1 2 3 4; do
  LOG="$(mktemp)"
  OUT=$(run_park "$n" "test-sling-1" "$LOG" 2>&1)
  RC=$?
  CALLS=$(count_calls "$LOG")
  [ "$RC" -ne 0 ] \
    && ok "(P$n) block aborts (nonzero) when ${STEP_NAMES[$n]} fails" \
    || bad "(P$n) block did NOT abort when ${STEP_NAMES[$n]} fails (rc=$RC)"
  [ "$CALLS" -eq "$n" ] \
    && ok "(P$n.count) exactly $n bd call(s) made before abort (got: $CALLS)" \
    || bad "(P$n.count) expected exactly $n bd call(s) before abort, got $CALLS. Calls:
$(cat "$LOG")"
  printf '%s\n' "$OUT" | grep -qi "FATAL" \
    && ok "(P$n.msg) failure is reported (FATAL) rather than swallowed" \
    || bad "(P$n.msg) no FATAL diagnostic printed on ${STEP_NAMES[$n]} failure. Output:
$OUT"
  printf '%s\n' "$OUT" | grep -q "PARK_COMPLETED" \
    && bad "(P$n.noskip) block reported PARK_COMPLETED despite ${STEP_NAMES[$n]} failing" \
    || ok "(P$n.noskip) block did not claim completion after ${STEP_NAMES[$n]} failed"
  rm -f "$LOG"
done

# ── (P5): step 5 (close own sling) failing is reported, not swallowed ───────
# This is the ORIGINAL bug this whole procedure exists to prevent (ga-mb253h)
# — if this exact failure goes silent, the sling churns back into the pool.
LOG5="$(mktemp)"
OUT5=$(run_park "5" "test-sling-1" "$LOG5" 2>&1)
RC5=$?
CALLS5=$(count_calls "$LOG5")
[ "$RC5" -ne 0 ] \
  && ok "(P5) block aborts (nonzero) when the sling-close call fails" \
  || bad "(P5) block did NOT abort when the sling-close call fails (rc=$RC5)"
[ "$CALLS5" -eq 5 ] \
  && ok "(P5.count) all 5 calls were attempted (steps 1-4 succeeded, step 5 failed) (got: $CALLS5)" \
  || bad "(P5.count) expected 5 bd calls, got $CALLS5. Calls:
$(cat "$LOG5")"
printf '%s\n' "$OUT5" | grep -qi "FATAL" \
  && ok "(P5.msg) sling-close failure is reported (FATAL) rather than swallowed" \
  || bad "(P5.msg) no FATAL diagnostic printed on sling-close failure. Output:
$OUT5"
printf '%s\n' "$OUT5" | grep -q "PARK_COMPLETED" \
  && bad "(P5.noskip) block reported PARK_COMPLETED despite the sling-close call failing" \
  || ok "(P5.noskip) block did not claim completion after the sling-close call failed"
rm -f "$LOG5"

# ── (N): happy path — no failures — still makes all 5 calls, in order ───────
LOGN="$(mktemp)"
OUTN=$(run_park "0" "test-sling-1" "$LOGN" 2>&1)
RCN=$?
CALLSN=$(count_calls "$LOGN")
[ "$RCN" -eq 0 ] \
  && ok "(N) block completes normally (rc=0) when every bd call succeeds" \
  || bad "(N) block unexpectedly aborted on the happy path (rc=$RCN). Output:
$OUTN"
[ "$CALLSN" -eq 5 ] \
  && ok "(N.count) all 5 bd calls made on the happy path (got: $CALLSN)" \
  || bad "(N.count) expected 5 bd calls on the happy path, got $CALLSN. Calls:
$(cat "$LOGN")"
ORDER=$(awk '{ $1=""; sub(/^ /,""); print }' "$LOGN" | awk '{print $1, $2}')
EXPECTED_ORDER="dep --blocks
label remove
label add
comment
update --set-metadata"
ACTUAL_ORDER=$(printf '%s\n' "$ORDER" | sed -n '1p;2p;3p;4p;5p' | awk '{print $1, $2}')
[ "$(printf '%s\n' "$ORDER" | sed -n '1p' | awk '{print $1}')" = "dep" ] \
  && [ "$(printf '%s\n' "$ORDER" | sed -n '2p' | awk '{print $1}')" = "label" ] \
  && [ "$(printf '%s\n' "$ORDER" | sed -n '3p' | awk '{print $1}')" = "label" ] \
  && [ "$(printf '%s\n' "$ORDER" | sed -n '4p' | awk '{print $1}')" = "comment" ] \
  && [ "$(printf '%s\n' "$ORDER" | sed -n '5p' | awk '{print $1}')" = "update" ] \
  && ok "(N.order) calls happened in the documented order: dep, label(x2), comment, update" \
  || bad "(N.order) call order does not match dep,label,label,comment,update. Calls:
$(cat "$LOGN")"
printf '%s\n' "$OUTN" | grep -q "PARK_COMPLETED" \
  && ok "(N.done) block reports completion on the happy path" \
  || bad "(N.done) block did not report completion on the happy path. Output:
$OUTN"
rm -f "$LOGN"

# ── (S): pre-existing guard survives — step 5 skipped when there's no ───────
# distinct sling bead (GC_BEAD_ID unset, or equal to the issue itself) — must
# still be true after adding error-checking around it.
LOGS="$(mktemp)"
OUTS=$(run_park "0" "" "$LOGS" 2>&1)
CALLSS=$(count_calls "$LOGS")
[ "$CALLSS" -eq 4 ] \
  && ok "(S) step 5 correctly skipped when GC_BEAD_ID is unset (4 calls, not 5)" \
  || bad "(S) expected 4 calls with GC_BEAD_ID unset, got $CALLSS. Calls:
$(cat "$LOGS")"
printf '%s\n' "$OUTS" | grep -q "PARK_COMPLETED" \
  && ok "(S.done) block still completes normally when step 5 is skipped" \
  || bad "(S.done) block did not report completion when step 5 is skipped. Output:
$OUTS"
rm -f "$LOGS"

LOGS2="$(mktemp)"
run_park "0" "$TEST_ISSUE" "$LOGS2" >/dev/null 2>&1
CALLSS2=$(count_calls "$LOGS2")
[ "$CALLSS2" -eq 4 ] \
  && ok "(S2) step 5 correctly skipped when GC_BEAD_ID equals the issue itself (4 calls, not 5)" \
  || bad "(S2) expected 4 calls with GC_BEAD_ID==issue, got $CALLSS2. Calls:
$(cat "$LOGS2")"
rm -f "$LOGS2"

# ── (F): source drift-guards ──────────────────────────────────────────────────
GUARD_COUNT=$(printf '%s' "$RAW_PARK_SRC" | grep -c 'FATAL:.*exit 1')
[ "$GUARD_COUNT" -eq 5 ] \
  && ok "(F1) all 5 mutating calls in the deployed block are guarded with a FATAL/exit-1 handler (got: $GUARD_COUNT)" \
  || bad "(F1) expected 5 guarded calls in the deployed block, found $GUARD_COUNT"
printf '%s' "$RAW_PARK_SRC" | grep -q 'bd dep .*--blocks {{issue}} \\' \
  && ok "(F2) step 1 (dep --blocks) still uses the line-continuation guard style" \
  || bad "(F2) step 1 no longer matches the expected 'bd dep ... --blocks {{issue}} \\' guard shape"
printf '%s' "$RAW_PARK_SRC" | grep -q 'gc.outcome=parked --status=closed' \
  && ok "(F3) step 5 still records gc.outcome=parked on the sling (unchanged by this edit)" \
  || bad "(F3) step 5's gc.outcome=parked write is missing or reworded"

echo
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL ASSERTIONS PASSED"
