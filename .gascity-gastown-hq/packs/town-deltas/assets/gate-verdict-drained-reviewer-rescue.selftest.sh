#!/usr/bin/env bash
# gate-verdict-drained-reviewer-rescue.selftest.sh (ga-7lz1)
#
# Proves: gate_collect_verdicts() rescues a verdict bead that is still OPEN
# but already carries an explicit verdict:PASS/verdict:FAIL label, PROVIDED
# its reviewer session is CONFIRMED drained (gc session peek reports
# "session not found"). Before this fix, the closed-only check counted such
# a bead as "still pending" forever, so Phase C never finalized the run —
# it waited the full VERDICT_TIMEOUT_MINUTES, then the dead-reviewer requeue
# path threw away the genuinely completed review for a from-scratch re-run.
#
# ROOT CAUSE it guards (ga-7lz1, live 2026-07-15 on wa-frhi5): a reviewer
# completed its review, added label verdict:FAIL and wrote the verdict
# comment (real, complete work), but DRAINED before its own final `bd
# close`. gate_collect_verdicts()'s closed-only check then read the bead as
# 0/1 delivered every sweep; Phase C sat "still in flight" for 17min heading
# to the 30min timeout. Mayor unblocked it by hand-closing the bead.
#
# Distinct from 19447308 (bd list must pass --all so a CLOSED verdict bead
# is rehydrated at all) — this bug is about a bead that never GETS closed in
# the first place.
#
# Guard requirement (the bug's own fail-safe): the rescue must NEVER fire
# for a reviewer that might still be mid-write — it must gate on CONFIRMED
# death via `gc session peek` (ga-h9o17/gt-bewtm discriminator), not on
# `gc session list` presence (a drained session stays listed with
# closed!=true, so a list-only check would read it ALIVE and never rescue —
# see gt-bewtm's headroom janitor in this same dispatcher file for the same
# distinction) and never on the label alone.
#
# Strategy: extract the live "gate-collect-verdicts-fn" and
# "session-peek-reports-dead-fn" blocks VERBATIM (real production code, not
# a hand-maintained duplicate) and run them under real `set -euo pipefail`,
# stubbing only the I/O boundary (`bd`, `gc`, `log`, `warn`). A single
# gate_collect_verdicts() call is fed FIVE verdict beads covering every
# relevant combination (rescue-PASS, rescue-FAIL, still-alive-reviewer,
# no-label-yet, already-closed) so the test also proves the rescue of one
# reviewer's bead does not disturb correct handling of the others in the
# same run. A MUTATION TEST disables just the rescue condition in a scratch
# copy and proves the same fixture set then reverts to the pre-fix behavior
# (rescue beads no longer counted, no close calls) — proof this suite is not
# vacuous.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-verdict-drained-reviewer-rescue.selftest =="

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

# run_collect_verdicts <dispatcher-file> <bd_log> <peek_log> -> stdout:
#   "RESULT|VERDICTS_RECEIVED=<n>|ANY_FAIL=<0|1>|FAIL_REASONS=<text>"
#
# Fixture (5 verdict beads fed to ONE gate_collect_verdicts() call, mirroring
# a real multi-reviewer run so the test proves beads don't cross-contaminate):
#   vb-rescue-pass     open   verdict:PASS  assignee=dead-r1   (drained)  -> rescue, count, no FAIL
#   vb-rescue-fail     open   verdict:FAIL  assignee=dead-r2   (drained)  -> rescue, count, ANY_FAIL=1
#   vb-alive-pending   open   verdict:FAIL  assignee=alive-r3  (ALIVE)    -> guard holds: NOT rescued/counted
#   vb-nolabel-pending open   (no verdict label)  assignee=dead-r4       -> NOT rescued/counted; peek never called
#   vb-closed-happy    closed verdict:PASS  assignee=whoever           -> pre-existing closed path, unaffected
run_collect_verdicts() {
  local file="$1" bd_log="$2" peek_log="$3"
  local fn_collect fn_peek_dead
  fn_collect="$(extract_block "$file" "gate-collect-verdicts-fn")"
  fn_peek_dead="$(extract_block "$file" "session-peek-reports-dead-fn")"
  if [ -z "$fn_collect" ] || [ -z "$fn_peek_dead" ]; then
    echo "COULD_NOT_EXTRACT_BLOCK" >&2
    return 99
  fi
  : > "$bd_log"; : > "$peek_log"
  bash -c '
    set -euo pipefail
    GC_CITY="/fake/city"
    BD_LOG="$1"; PEEK_LOG="$2"

    VB1='"'"'{"status":"open","labels":["type:quality-gate-verdict","reviewer-index:1","verdict:PASS"],"assignee":"dead-r1"}'"'"'
    VB2='"'"'{"status":"open","labels":["type:quality-gate-verdict","reviewer-index:2","verdict:FAIL"],"assignee":"dead-r2"}'"'"'
    VB3='"'"'{"status":"open","labels":["type:quality-gate-verdict","reviewer-index:3","verdict:FAIL"],"assignee":"alive-r3"}'"'"'
    VB4='"'"'{"status":"open","labels":["type:quality-gate-verdict","reviewer-index:4"],"assignee":"dead-r4"}'"'"'
    VB5='"'"'{"status":"closed","labels":["type:quality-gate-verdict","reviewer-index:5","verdict:PASS"],"assignee":"whoever"}'"'"'
    VB2_COMMENTS='"'"'[{"text":"VERDICT: FAIL — race condition in shared cache"}]'"'"'

    VERDICT_BEAD_IDS=(vb-rescue-pass vb-rescue-fail vb-alive-pending vb-nolabel-pending vb-closed-happy)

    bd() {
      case " $* " in
        *" show vb-rescue-pass "*)     echo "$VB1"; return 0 ;;
        *" show vb-rescue-fail "*)     echo "$VB2"; return 0 ;;
        *" show vb-alive-pending "*)   echo "$VB3"; return 0 ;;
        *" show vb-nolabel-pending "*) echo "$VB4"; return 0 ;;
        *" show vb-closed-happy "*)    echo "$VB5"; return 0 ;;
        *" comments vb-rescue-fail "*) echo "$VB2_COMMENTS"; return 0 ;;
        *" comments "*)                echo "[]"; return 0 ;;
        *" close "*)                   echo "$*" >> "$BD_LOG"; return 0 ;;
      esac
      echo "UNEXPECTED:$*" >> "$BD_LOG"
      return 0
    }
    # gc stub: only "session peek" is exercised by this block. Positional
    # parsing ($5 = the peeked id) is safe here because both the production
    # call site and this stub are pinned to the exact same shape:
    # `gc --city "$GC_CITY" session peek "$ID" --lines 1`.
    gc() {
      case " $* " in
        *" session peek "*)
          local pid="$5"
          echo "$pid" >> "$PEEK_LOG"
          case "$pid" in
            alive-r3) echo "fake scrollback (reviewer still working)"; return 0 ;;
            *)        echo "gc session peek: session not found: $pid" >&2; return 1 ;;
          esac
          ;;
      esac
      return 0
    }
    log()  { echo "LOG: $*" >&2; }
    warn() { echo "WARN: $*" >&2; }

    '"$fn_peek_dead"'
    '"$fn_collect"'

    gate_collect_verdicts
    printf "RESULT|VERDICTS_RECEIVED=%s|ANY_FAIL=%s|FAIL_REASONS=%s\n" \
      "$VERDICTS_RECEIVED" "$ANY_FAIL" "$FAIL_REASONS"
  ' _ "$bd_log" "$peek_log"
  return $?
}

BD_LOG="$(mktemp)"; PEEK_LOG="$(mktemp)"; STDERR_LOG="$(mktemp)"
OUT="$(run_collect_verdicts "$DISPATCHER" "$BD_LOG" "$PEEK_LOG" 2>"$STDERR_LOG")"
RC=$?
sed 's/^/    [main] /' "$STDERR_LOG"
rm -f "$STDERR_LOG"
RESULT_LINE="$(printf '%s\n' "$OUT" | grep '^RESULT|' || true)"

echo "── 1. Block executes cleanly ──"
if [ "$RC" -eq 0 ] && [ -n "$RESULT_LINE" ]; then
  ok "gate_collect_verdicts runs to completion (rc=0, result line present)"
else
  bad "gate_collect_verdicts did not complete cleanly (rc=$RC, out='$OUT', bd_log: $(tr '\n' ';' < "$BD_LOG")); aborting remaining assertions"
  echo "== gate-verdict-drained-reviewer-rescue: PASS=$PASS FAIL=$FAIL =="
  rm -f "$BD_LOG" "$PEEK_LOG"
  exit 1
fi

VR=$(printf '%s' "$RESULT_LINE" | sed -n 's/.*VERDICTS_RECEIVED=\([0-9]*\).*/\1/p')
AF=$(printf '%s' "$RESULT_LINE" | sed -n 's/.*ANY_FAIL=\([0-9]*\).*/\1/p')

echo "── 2. Rescued beads (drained reviewer, verdict label present) are counted ──"
[ "$VR" = "3" ] \
  && ok "VERDICTS_RECEIVED=3 (rescue-pass + rescue-fail + already-closed) — got $VR" \
  || bad "VERDICTS_RECEIVED expected 3, got '$VR' — result: $RESULT_LINE"
[ "$AF" = "1" ] \
  && ok "ANY_FAIL=1 (the rescued FAIL bead still blocks the merge) — got $AF" \
  || bad "ANY_FAIL expected 1, got '$AF' — result: $RESULT_LINE"
case "$RESULT_LINE" in
  *"race condition in shared cache"*) ok "rescued FAIL's real reviewer comment survives into FAIL_REASONS" ;;
  *) bad "rescued FAIL's comment did not make it into FAIL_REASONS — result: $RESULT_LINE" ;;
esac

echo "── 3. Rescued beads are actually closed by the dispatcher ──"
grep -q "close vb-rescue-pass" "$BD_LOG" \
  && ok "vb-rescue-pass (drained, PASS) was closed" \
  || bad "vb-rescue-pass was NOT closed — bd_log: $(tr '\n' ';' < "$BD_LOG")"
grep -q "close vb-rescue-fail" "$BD_LOG" \
  && ok "vb-rescue-fail (drained, FAIL) was closed" \
  || bad "vb-rescue-fail was NOT closed — bd_log: $(tr '\n' ';' < "$BD_LOG")"

echo "── 4. Guard holds: a STILL-ALIVE reviewer's labeled-but-open bead is left alone ──"
if grep -q "close vb-alive-pending" "$BD_LOG"; then
  bad "vb-alive-pending was closed even though its reviewer is still ALIVE — the mid-write guard is broken"
else
  ok "vb-alive-pending was NOT closed (reviewer still alive — could still be mid-write)"
fi

echo "── 5. Scope holds: a bead with no verdict label yet is never even peeked ──"
if grep -q "^dead-r4$" "$PEEK_LOG"; then
  bad "vb-nolabel-pending's reviewer (dead-r4) was peeked even with no verdict label — wasted gc call / over-broad guard"
else
  ok "vb-nolabel-pending's reviewer was never peeked (no verdict label -> nothing to rescue)"
fi
if grep -q "close vb-nolabel-pending" "$BD_LOG"; then
  bad "vb-nolabel-pending was closed — should stay pending, no verdict was ever delivered"
else
  ok "vb-nolabel-pending was NOT closed (correctly still pending)"
fi

echo "── 6. Regression guard: an already-closed bead takes the pre-existing path untouched ──"
if grep -q "close vb-closed-happy" "$BD_LOG"; then
  bad "vb-closed-happy: dispatcher redundantly re-closed an already-closed bead"
else
  ok "vb-closed-happy: no redundant close call (happy path unaffected by this fix)"
fi

rm -f "$BD_LOG" "$PEEK_LOG"

echo "── 7. MUTATION TEST: disabling the rescue condition must revert to the pre-fix bug ──"
MUT="$(mktemp "${TMPDIR:-/tmp}/gate-verdict-rescue-mutant-XXXXXX.sh" 2>/dev/null || echo "/tmp/gate-verdict-rescue-mutant-$$.sh")"
trap 'rm -f "$MUT"' EXIT
cp "$DISPATCHER" "$MUT"
MUTATE_OK=0
python3 - "$MUT" <<'PYEOF' && MUTATE_OK=1
import sys
path = sys.argv[1]
with open(path) as f:
    c = f.read()
anchor = '    if [ "$VB_STATUS" != "closed" ] && echo "$VB_LABELS" | grep -qE "verdict:(PASS|FAIL)"; then'
n = c.count(anchor)
if n != 1:
    print("ANCHOR_NOT_UNIQUE count=%d" % n, file=sys.stderr)
    sys.exit(1)
mutant = '    if false; then  # MUTATED (ga-7lz1 selftest): rescue disabled'
c2 = c.replace(anchor, mutant, 1)
if c2 == c:
    print("SWAP_NO_OP", file=sys.stderr)
    sys.exit(1)
with open(path, "w") as f:
    f.write(c2)
PYEOF
if [ "$MUTATE_OK" != "1" ]; then
  bad "mutation-test: could not construct the mutant (anchor not found exactly once — source shape changed?) — INCONCLUSIVE, treat as FAIL"
else
  BD_LOG_MUT="$(mktemp)"; PEEK_LOG_MUT="$(mktemp)"
  OUT_MUT="$(run_collect_verdicts "$MUT" "$BD_LOG_MUT" "$PEEK_LOG_MUT" 2>&1)"
  VR_MUT=$(printf '%s' "$OUT_MUT" | grep '^RESULT|' | sed -n 's/.*VERDICTS_RECEIVED=\([0-9]*\).*/\1/p')
  if [ "$VR_MUT" = "1" ] && ! grep -q "close vb-rescue-pass\|close vb-rescue-fail" "$BD_LOG_MUT"; then
    ok "mutant (rescue disabled): VERDICTS_RECEIVED drops to 1 (only the already-closed bead), no rescue closes fire — proves the rescue is what fixes ga-7lz1"
  else
    bad "mutant (rescue disabled) did NOT reproduce the pre-fix bug — test may be vacuous. VERDICTS_RECEIVED=$VR_MUT, bd_log: $(tr '\n' ';' < "$BD_LOG_MUT")"
  fi
  rm -f "$BD_LOG_MUT" "$PEEK_LOG_MUT"
fi
rm -f "$MUT"

echo ""
echo "== gate-verdict-drained-reviewer-rescue: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
