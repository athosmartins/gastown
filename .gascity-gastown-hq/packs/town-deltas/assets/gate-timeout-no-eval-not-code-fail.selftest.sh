#!/usr/bin/env bash
# gate-timeout-no-eval-not-code-fail.selftest.sh (ga-mcapdq)
#
# BUG (ga-mcapdq, found via ga-oc6knj, 2026-09-17): Phase C's genuine-timeout
# path — at least one pending reviewer is confirmed LIVE (not dead) but never
# submitted a verdict before the run's own timeout — sets OVERALL_VERDICT=
# "FAIL" and calls gate_finalize_run(). That function's fail-class reset
# assumed every pre-set FAIL entering it came from "the reviewer/content
# verdict computed earlier" (true for the fast path and for a genuine
# reviewer rejection) and defaulted GATE_SHA_FAIL_CLASS to "code" — so a
# timeout where NOBODY evaluated the code got stamped gate-sha-failed:
# <sha>:CODE (permanently blocking that exact commit, ga-nooaw fail-closed-
# by-SHA) and bumped gate:fix-attempt:N (burning one of the author's 3
# auto-retries) exactly like a real rejection would. Live incident:
# gate_run ga-ys0umy (branch fix/ga-oc6knj-routed-pool-starvation, tip
# ef1108e42) timed out with reason "TIMEOUT: reviewers did not submit
# verdicts within 33 minutes" — no reviewer ever objected — yet the bead
# still received gate-sha-failed:ef1108e42...:CODE and gate:fix-attempt:1.
# Same family as ga-39l9z2 (post-PASS merge conflict counted as an attempt)
# and ga-l7mvtw (a stale-SHA run counted as an attempt): the counter and
# stamp must register an actual code rejection, never administrative/infra
# noise dressed up as one.
#
# FIX: a new plain script-global, GATE_FAIL_NO_EVAL (same relay idiom this
# file already uses for QUOTA_REQUEUE/REQUEUE_REASON), is set to 1 by
# the genuine-timeout branch (never by the sibling dead-reviewer branch,
# which requeues instead of failing; ga-w7pm55 later added a second producer,
# gate_collect_verdicts, for a verdict bead closed with no verdict — covered
# by gate-no-verdict-infra-not-code-fail.selftest.sh) immediately before calling
# gate_finalize_run(). That function reads it once at the top (into a
# function-local so a stale value can never leak into a LATER bead
# finalized later in the same sweep), classing the stamp "hold" instead of
# "code" when set, and the Step-10 FAIL path's attempt-counter bump is
# skipped for the same signal — the counter is left exactly as it was.
#
# Invariants under test (this bead's own acceptance criteria):
#   a) A genuine reviewer timeout never stamps gate-sha-failed:<sha>:code —
#      at most :hold.
#   b) A genuine reviewer timeout never increments gate:fix-attempt.
#   c) A REAL content FAIL (an actual reviewer rejection) is UNAFFECTED —
#      still stamps :code and still bumps the counter (non-regression of
#      ga-nooaw/ga-4cy2t).
#   d) The signal cannot leak: a "no-eval" FAIL for one bead must not
#      silently downgrade a later, unrelated bead's genuine FAIL in the
#      same sweep (mirrors the file's own QUOTA_REQUEUE/REQUEUE_REASON
#      staleness concern).
#
# Strategy: extract each touched block VERBATIM via SELFTEST-EXTRACT
# markers (real production code, not a hand-maintained duplicate) — same
# harness shape as gate-verdict-status-unreadable.selftest.sh /
# gate-sha-fail-lock.selftest.sh. Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-timeout-no-eval-not-code-fail.selftest (ga-mcapdq) =="

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

FN_SIGNAL="$(extract_block "$DISPATCHER" "phase-c-genuine-timeout-no-eval")"
FN_RESET="$(extract_block "$DISPATCHER" "finalize-failclass-reset")"
FN_BUMP="$(extract_block "$DISPATCHER" "finalize-fixattempt-bump")"

if [ -z "$FN_SIGNAL" ] || [ -z "$FN_RESET" ] || [ -z "$FN_BUMP" ]; then
  bad "could not extract one or more of phase-c-genuine-timeout-no-eval / finalize-failclass-reset / finalize-fixattempt-bump — aborting"
  echo "PASS=$PASS  FAIL=$FAIL"; exit 1
fi

# ── Part 1: phase-c-genuine-timeout-no-eval — the branch sets the signal ────
# NOTE: the marked block is deliberately narrow — it decides the signal (and,
# since ga-h8vc8y, whether the collected reviewer reasons are kept). It raises
# GATE_FAIL_NO_EVAL only when NO reviewer judged the code; this harness leaves
# GATE_COLLECT_JUDGED_FAILS unset (reads as 0 = nobody judged), so it exercises
# exactly that no-evaluation branch. The judged-FAIL branch is covered by
# gate-timeout-keeps-judged-fail.selftest.sh. OVERALL_VERDICT/FAIL_REASONS are
# set by lines outside this block in production, so the harness pre-seeds them
# to reproduce that established context, then checks only what this block owns.
echo "── 1. phase-c-genuine-timeout-no-eval: genuine timeout raises GATE_FAIL_NO_EVAL ──"
OUT1="$(bash -c '
  set -euo pipefail
  OVERALL_VERDICT="FAIL"   # set by the unmarked line immediately above this block in production
  FAIL_REASONS="TIMEOUT: reviewers did not submit verdicts within 33 minutes."
  GATE_FAIL_NO_EVAL=0
  warn() { :; }
  '"$FN_SIGNAL"'
  printf "OVERALL_VERDICT=%s|GATE_FAIL_NO_EVAL=%s|FAIL_REASONS=%s\n" "$OVERALL_VERDICT" "$GATE_FAIL_NO_EVAL" "$FAIL_REASONS"
' 2>&1)"
if printf '%s' "$OUT1" | grep '^OVERALL_VERDICT=FAIL|GATE_FAIL_NO_EVAL=1|' >/dev/null; then
  ok "genuine timeout block raises GATE_FAIL_NO_EVAL=1 without disturbing OVERALL_VERDICT=FAIL — got: $OUT1"
else
  bad "genuine timeout branch did not raise the no-eval signal correctly — got: $OUT1"
fi
if printf '%s' "$OUT1" | grep 'FAIL_REASONS=TIMEOUT:' >/dev/null; then
  ok "FAIL_REASONS still records the TIMEOUT reason (block does not disturb it)"
else
  bad "FAIL_REASONS lost its TIMEOUT reason — got: $OUT1"
fi

# ── Part 1b: DRIFT GUARD — the sibling dead-reviewer branch must NEVER set ──
# the signal (it requeues instead of failing; conflating the two would
# silently disable the ga-eqjo infra-requeue path this bead must not touch).
echo "── 1b. drift guard: dead-reviewer branch (sibling, requeues) never sets GATE_FAIL_NO_EVAL ──"
DR_START=$(grep -n 'REQUEUE_REASON="dead-reviewer"' "$DISPATCHER" | head -1 | cut -d: -f1)
DR_END=$(tail -n "+$((DR_START + 1))" "$DISPATCHER" | grep -n 'gate_finalize_run' | head -1 | cut -d: -f1)
if [ -n "$DR_START" ] && [ -n "$DR_END" ]; then
  DR_ABS_END=$((DR_START + DR_END))
  DR_WINDOW=$(sed -n "${DR_START},${DR_ABS_END}p" "$DISPATCHER")
  if [[ "$DR_WINDOW" == *"GATE_FAIL_NO_EVAL=1"* ]]; then
    bad "dead-reviewer branch (lines $DR_START-$DR_ABS_END) unexpectedly sets GATE_FAIL_NO_EVAL=1 — would misclassify infra deaths too, harmless-but-wrong, or worse mask a real conflation"
  else
    ok "dead-reviewer branch (lines $DR_START-$DR_ABS_END) does not set GATE_FAIL_NO_EVAL — the requeue path never raises the no-eval FAIL signal"
  fi
else
  bad "could not bound the dead-reviewer branch to check for signal leakage (DR_START=$DR_START DR_END=$DR_END)"
fi

# ── Part 2: finalize-failclass-reset — classification + non-regression + ───
# anti-leak across sequential calls in the same sweep.
echo "── 2. finalize-failclass-reset: hold when signaled, code otherwise, never leaks ──"
run_reset() {
  local hint="$1"
  bash -c '
    set -euo pipefail
    run_reset_inner() {
      '"$FN_RESET"'
    }
    GATE_SHA_FAIL_CLASS="code"   # the unconditional default set immediately above this block in production
    GATE_FAIL_NO_EVAL="$1"
    run_reset_inner
    printf "CLASS=%s|NO_EVAL_AFTER=%s\n" "$GATE_SHA_FAIL_CLASS" "$GATE_FAIL_NO_EVAL"
  ' _ "$hint"
}

OUT2A="$(run_reset 1)"
if printf '%s' "$OUT2A" | grep '^CLASS=hold|NO_EVAL_AFTER=0$' >/dev/null; then
  ok "GATE_FAIL_NO_EVAL=1 classifies this run's stamp as hold, and clears the signal after consuming it — got: $OUT2A"
else
  bad "signaled no-eval FAIL did not classify as hold (or failed to clear) — got: $OUT2A"
fi

OUT2B="$(run_reset 0)"
if printf '%s' "$OUT2B" | grep '^CLASS=code|NO_EVAL_AFTER=0$' >/dev/null; then
  ok "no signal (ordinary real-content FAIL) still classifies as code — ga-nooaw non-regression — got: $OUT2B"
else
  bad "unsignaled FAIL regressed away from the code default — got: $OUT2B"
fi

# Anti-leak: call the reset TWICE in the SAME shell — once signaled, once not
# — proving a "hold" set while finalizing a PRIOR bead cannot survive into a
# later, unrelated bead's own finalize call this same sweep.
OUT2C="$(bash -c '
  set -euo pipefail
  run_reset_inner() {
    '"$FN_RESET"'
  }
  GATE_SHA_FAIL_CLASS="code"; GATE_FAIL_NO_EVAL=1
  run_reset_inner
  FIRST="$GATE_SHA_FAIL_CLASS"
  GATE_SHA_FAIL_CLASS="code"   # the unconditional default re-runs for a SECOND, unrelated bead this same sweep (GATE_FAIL_NO_EVAL was already zeroed by call #1, NOT re-set here)
  run_reset_inner
  SECOND="$GATE_SHA_FAIL_CLASS"
  printf "FIRST=%s|SECOND=%s\n" "$FIRST" "$SECOND"
' 2>&1)"
if printf '%s' "$OUT2C" | grep '^FIRST=hold|SECOND=code$' >/dev/null; then
  ok "a hold classified for bead #1 does not leak into bead #2's finalize call this same sweep — got: $OUT2C"
else
  bad "anti-leak broken: a prior bead's no-eval hold leaked into the next bead's classification — got: $OUT2C"
fi

# ── 2b. MUTATION TEST: dropping the classification guard must revert to the ─
# pre-fix bug (always "code", even on a signaled no-eval timeout) — proves
# Part 2 is not vacuous.
echo "── 2b. MUTATION TEST: unconditional \"code\" (pre-fix) must stamp code even when signaled ──"
FN_RESET_MUTANT="$(printf '%s\n' "$FN_RESET" | sed '/^if \[ "\$GATE_FAIL_NO_EVAL_RUN" = "1" \]; then$/,/^fi$/d')"
OUT2M="$(bash -c '
  set -euo pipefail
  run_reset_inner() {
    '"$FN_RESET_MUTANT"'
  }
  GATE_SHA_FAIL_CLASS="code"; GATE_FAIL_NO_EVAL=1
  run_reset_inner
  printf "CLASS=%s\n" "$GATE_SHA_FAIL_CLASS"
' 2>&1)"
if printf '%s' "$OUT2M" | grep '^CLASS=code$' >/dev/null; then
  ok "mutant (guard removed) DOES stamp code on a signaled no-eval timeout — reproduces the pre-fix ga-mcapdq bug, proving Part 2 is not vacuous"
else
  bad "mutant should have reproduced the pre-fix always-code bug but didn't — mutation harness itself is broken: $OUT2M"
fi

# ── Part 3: finalize-fixattempt-bump — counter untouched when no-eval, ─────
# unchanged normal bump otherwise (non-regression).
echo "── 3. finalize-fixattempt-bump: counter frozen on no-eval, normal bump otherwise ──"
run_bump() {
  local no_eval_run="$1" prev_attempt="$2" bd_log="$3"
  : > "$bd_log"
  bash -c '
    set -euo pipefail
    BD_LOG="$1"
    GATE_FAIL_NO_EVAL_RUN="$2"
    PREV_ATTEMPT="$3"
    BEAD_ID="bead-1"; BEAD_CITY="/fake/city"; GATE_FIX_CAP=3
    SRC_LABELS="gate:fix-attempt:$PREV_ATTEMPT area:gate"
    bd() {
      case " $* " in
        *" label "*) echo "$*" >> "$BD_LOG"; return 0 ;;
      esac
      return 0
    }
    log() { :; }
    '"$FN_BUMP"'
    printf "NEW_ATTEMPT=%s\n" "$NEW_ATTEMPT"
  ' _ "$bd_log" "$no_eval_run" "$prev_attempt"
}

BD_LOG3A="$(mktemp)"
OUT3A="$(run_bump 1 2 "$BD_LOG3A")"
if printf '%s' "$OUT3A" | grep '^NEW_ATTEMPT=2$' >/dev/null; then
  ok "no-eval timeout: NEW_ATTEMPT stays at PREV_ATTEMPT (2) — counter not advanced"
else
  bad "no-eval timeout: NEW_ATTEMPT should stay 2 — got: $OUT3A"
fi
if [ ! -s "$BD_LOG3A" ]; then
  ok "no-eval timeout: zero bd label add/remove calls touched gate:fix-attempt:*"
else
  bad "no-eval timeout: unexpected bd label call(s) fired — $(cat "$BD_LOG3A")"
fi

BD_LOG3B="$(mktemp)"
OUT3B="$(run_bump 0 2 "$BD_LOG3B")"
if printf '%s' "$OUT3B" | grep '^NEW_ATTEMPT=3$' >/dev/null; then
  ok "real FAIL: NEW_ATTEMPT bumps from 2 to 3 (unaffected by this fix)"
else
  bad "real FAIL: NEW_ATTEMPT should bump to 3 — got: $OUT3B"
fi
if grep -q 'gate:fix-attempt:2' "$BD_LOG3B" && grep -q 'gate:fix-attempt:3' "$BD_LOG3B"; then
  ok "real FAIL: stale gate:fix-attempt:2 removed and gate:fix-attempt:3 added — happy path unaffected by this fix"
else
  bad "real FAIL: expected both a remove(2) and an add(3) bd label call — $(cat "$BD_LOG3B")"
fi

# ── 3b. MUTATION TEST: removing the no-eval guard must revert to the ───────
# pre-fix bug (unconditional bump even on a genuine timeout) — proves this
# part of the suite is not vacuous.
echo "── 3b. MUTATION TEST: unconditional bump (pre-fix) must bump even when no-eval ──"
FN_BUMP_MUTANT="$(printf '%s\n' "$FN_BUMP" | sed '/^      if \[ "\$GATE_FAIL_NO_EVAL_RUN" = "1" \]; then$/,/^      else$/d; /^      fi$/d')"
BD_LOG3M="$(mktemp)"
OUT3M="$(bash -c '
  set -euo pipefail
  BD_LOG="$1"; GATE_FAIL_NO_EVAL_RUN="1"; PREV_ATTEMPT=2
  BEAD_ID="bead-1"; BEAD_CITY="/fake/city"; GATE_FIX_CAP=3
  SRC_LABELS="gate:fix-attempt:2 area:gate"
  bd() { case " $* " in *" label "*) echo "$*" >> "$BD_LOG"; return 0 ;; esac; return 0; }
  log() { :; }
  '"$FN_BUMP_MUTANT"'
  printf "NEW_ATTEMPT=%s\n" "$NEW_ATTEMPT"
' _ "$BD_LOG3M" 2>&1)"
if printf '%s' "$OUT3M" | grep '^NEW_ATTEMPT=3$' >/dev/null && grep -q 'gate:fix-attempt:3' "$BD_LOG3M"; then
  ok "mutant (guard removed) DOES bump to 3 on a no-eval timeout — reproduces the pre-fix ga-mcapdq bug, proving Part 3 is not vacuous"
else
  bad "mutant should have reproduced the pre-fix unconditional-bump bug but didn't — mutation harness itself is broken: $OUT3M"
fi

# ── 4. syntax ────────────────────────────────────────────────────────────
echo "── 4. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
