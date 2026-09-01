#!/usr/bin/env bash
# gate-deploy-retry.selftest.sh — ga-d5rrr DEFEITO 1 mutation test.
#
# CASO (Mayor, 2026-09-01, one day of manual gate-hold triage): the ga-l7n3v
# daemon-liveness deploy step (quality-gate-dispatcher.sh) ran `git -C <rig>
# pull --ff-only` exactly ONCE and declared DEPLOY_FAILED — holding the bead,
# mailing the Mayor, costing a manual investigation cycle — on the FIRST
# non-zero exit code. In 3 of 3 DEPLOY_FAILED holds that day (wa-hyvuw,
# wa-96eth, wa-shfen), running the EXACT SAME command again moments later
# succeeded ("Already up to date") — the failure had already self-healed
# before any human read the alert. Probable cause: disk/load contention (the
# city spent that day between 1-6GB free disk, pushes failing and passing on
# retry — wa-gbam4).
#
# FIX: retry the deploy_cmd with doubling backoff (GATE_DEPLOY_RETRY_MAX
# attempts, base GATE_DEPLOY_RETRY_BACKOFF_SECS) before declaring
# DEPLOY_FAILED, mirroring the SHAPE (not the transient-classifier — a failed
# `git pull` has no reliable transient/permanent text signature the way a
# reviewer-spawn connection error does) of the existing ga-2u38b
# spawn-retry-loop. The attempt count now flows into DAEMON_HOLD_REASON so the
# alert distinguishes "failed once" from "failed after N attempts".
#
# ACEITE (from the bug): DEPLOY_FAILED is only emitted after N attempts with
# backoff, and the alert says how many.
#
# This harness extracts the deploy-retry-loop block verbatim (genuine live
# extraction, same technique as gate-spawn-transient-retry.selftest.sh) and
# drives it with a mocked deploy command, proving the in-process retry
# actually recovers from a one-shot blip and gives up correctly, bounded, when
# the failure persists. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

echo "== gate-deploy-retry.selftest (ga-d5rrr DEFEITO 1) =="

GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

# ── 1. deploy-retry-loop — genuine live extraction ────────────────────────
echo "── 1. deploy-retry-loop (live extraction, mocked eval target + sleep) ──"
RETRY_BLOCK="$(sed -n '/# SELFTEST-EXTRACT deploy-retry-loop: BEGIN/,/# SELFTEST-EXTRACT deploy-retry-loop: END/p' "$DISPATCHER")"
if [ -z "$RETRY_BLOCK" ]; then
  echo "FATAL: could not locate 'deploy-retry-loop' sentinel block in $DISPATCHER"
  exit 1
fi
ok "located live deploy-retry-loop block via sentinel extraction"

# (a) deploy fails on attempt 1, succeeds on attempt 2 — recovers without
# exhausting the retry budget; CALL_LOG proves exactly 2 attempts ran. Counted
# via a FILE (append + wc -l), not a shell-variable increment — the loop body
# runs inside this same process here (no subshell), but matching the proven
# survives-any-execution-context convention from gate-spawn-transient-retry.
DEPLOY_RECOVER_SCRIPT='
CALL_LOG=$(mktemp)
__deploy() {
  echo x >> "$CALL_LOG"
  n=$(wc -l < "$CALL_LOG" | tr -d "[:space:]")
  if [ "$n" -ge 2 ]; then
    echo "Already up to date."
    return 0
  else
    echo "fatal: unable to access rig: transient error" >&2
    return 1
  fi
}
DR_DEPLOY_CMD="__deploy"
warn() { :; }
sleep() { :; }
GATE_DEPLOY_RETRY_MAX=3; GATE_DEPLOY_RETRY_BACKOFF_SECS=0
RIG="testrig"
'"$RETRY_BLOCK"'
CALLS=$(wc -l < "$CALL_LOG" | tr -d "[:space:]")
rm -f "$CALL_LOG"
printf "RC=%s ATTEMPT=%s CALLS=%s\n" "$DR_DEPLOY_RC" "$DR_DEPLOY_ATTEMPT" "$CALLS"
'
OUT=$(bash -c "$DEPLOY_RECOVER_SCRIPT" 2>/dev/null)
case "$OUT" in
  "RC=0 ATTEMPT=2 CALLS=2") ok "(a) transient deploy failure recovers on 2nd attempt (rc=0, attempt=2, 2 calls made)" ;;
  *) bad "(a) expected RC=0 ATTEMPT=2 CALLS=2, got: $OUT" ;;
esac

# (b) deploy fails on EVERY attempt — loop stops at GATE_DEPLOY_RETRY_MAX,
# never spins forever, and the final rc/attempt remain visible to the caller
# (the caller decides DEPLOY_FAILED from these, not the loop itself).
DEPLOY_PERSIST_SCRIPT='
CALL_LOG=$(mktemp)
__deploy() { echo x >> "$CALL_LOG"; echo "fatal: repository not found" >&2; return 1; }
DR_DEPLOY_CMD="__deploy"
warn() { :; }
sleep() { :; }
GATE_DEPLOY_RETRY_MAX=3; GATE_DEPLOY_RETRY_BACKOFF_SECS=0
RIG="testrig"
'"$RETRY_BLOCK"'
CALLS=$(wc -l < "$CALL_LOG" | tr -d "[:space:]")
rm -f "$CALL_LOG"
printf "RC=%s ATTEMPT=%s CALLS=%s\n" "$DR_DEPLOY_RC" "$DR_DEPLOY_ATTEMPT" "$CALLS"
'
OUT=$(bash -c "$DEPLOY_PERSIST_SCRIPT" 2>/dev/null)
case "$OUT" in
  "RC=1 ATTEMPT=3 CALLS=3") ok "(b) persistent failure stops at GATE_DEPLOY_RETRY_MAX=3 (bounded, not infinite), rc/attempt surfaced for the caller" ;;
  *) bad "(b) expected RC=1 ATTEMPT=3 CALLS=3, got: $OUT" ;;
esac

# (c) success on the FIRST attempt — no retry overhead, exactly 1 call. Proves
# the fix does not slow down the (overwhelmingly common) already-working case.
DEPLOY_FIRST_TRY_SCRIPT='
CALL_LOG=$(mktemp)
__deploy() { echo x >> "$CALL_LOG"; echo "Already up to date."; return 0; }
DR_DEPLOY_CMD="__deploy"
warn() { :; }
sleep() { :; }
GATE_DEPLOY_RETRY_MAX=3; GATE_DEPLOY_RETRY_BACKOFF_SECS=0
RIG="testrig"
'"$RETRY_BLOCK"'
CALLS=$(wc -l < "$CALL_LOG" | tr -d "[:space:]")
rm -f "$CALL_LOG"
printf "RC=%s ATTEMPT=%s CALLS=%s\n" "$DR_DEPLOY_RC" "$DR_DEPLOY_ATTEMPT" "$CALLS"
'
OUT=$(bash -c "$DEPLOY_FIRST_TRY_SCRIPT" 2>/dev/null)
case "$OUT" in
  "RC=0 ATTEMPT=1 CALLS=1") ok "(c) success on first attempt costs exactly 1 call (no unnecessary retry)" ;;
  *) bad "(c) expected RC=0 ATTEMPT=1 CALLS=1, got: $OUT" ;;
esac

# (d) backoff GROWS per attempt (doubles from the base), same convention as
# the existing ga-2u38b spawn-retry-loop — capture the actual computed sleep
# durations via a sleep() mock that logs its argument to a file.
DEPLOY_BACKOFF_SCRIPT='
SLEEP_LOG=$(mktemp)
__deploy() { echo "fatal: transient" >&2; return 1; }
DR_DEPLOY_CMD="__deploy"
warn() { :; }
sleep() { printf "%s\n" "$1" >> "$SLEEP_LOG"; }
GATE_DEPLOY_RETRY_MAX=3; GATE_DEPLOY_RETRY_BACKOFF_SECS=3
RIG="testrig"
'"$RETRY_BLOCK"'
cat "$SLEEP_LOG"
rm -f "$SLEEP_LOG"
'
BACKOFFS=$(bash -c "$DEPLOY_BACKOFF_SCRIPT" 2>/dev/null | tr "\n" "," | sed "s/,$//")
if [ "$BACKOFFS" = "3,6" ]; then
  ok "(d) backoff doubles per attempt from the base (3,6 — 2 sleeps for 3 attempts, not a flat repeat): $BACKOFFS"
else
  bad "(d) expected doubling backoff '3,6', got: '$BACKOFFS'"
fi

# ── 2. attempt count flows into the alert text (ACEITE: 'o alerta diz quantas') ─
echo "── 2. attempt count reaches DAEMON_HOLD_REASON ──"
if grep -qF 'DAEMON_HOLD_REASON="rig $RIG deploy_cmd failed after ${DR_DEPLOY_ATTEMPT:-1}/$GATE_DEPLOY_RETRY_MAX attempts' "$DISPATCHER"; then
  ok "DAEMON_HOLD_REASON names the attempt count, not just rc (ga-d5rrr ACEITE #1)"
else
  bad "DAEMON_HOLD_REASON no longer names the attempt count — did the ga-d5rrr fix get reverted/refactored?"
fi

# ── 3. drift-guards ────────────────────────────────────────────────────────
echo "── 3. drift-guards ──"
if grep -qF 'GATE_DEPLOY_RETRY_MAX="${GATE_DEPLOY_RETRY_MAX:-3}"' "$DISPATCHER"; then
  ok "retry count is a configurable GATE_* tunable, default 3"
else
  bad "GATE_DEPLOY_RETRY_MAX default assignment not found"
fi
if grep -qF 'GATE_DEPLOY_RETRY_BACKOFF_SECS="${GATE_DEPLOY_RETRY_BACKOFF_SECS:-3}"' "$DISPATCHER"; then
  ok "backoff base is a configurable GATE_* tunable, default 3"
else
  bad "GATE_DEPLOY_RETRY_BACKOFF_SECS default assignment not found"
fi
if grep -qF 'DR_DEPLOY_BACKOFF_SECS=$((GATE_DEPLOY_RETRY_BACKOFF_SECS * (1 << (DR_DEPLOY_ATTEMPT - 1))))' "$DISPATCHER"; then
  ok "backoff doubles per attempt (not a flat repeat)"
else
  bad "doubling backoff formula not found — did the retry loop get refactored?"
fi
if grep -qF '# SELFTEST-EXTRACT deploy-retry-loop: BEGIN' "$DISPATCHER"; then
  ok "deploy-retry-loop extraction sentinel present"
else
  bad "deploy-retry-loop extraction sentinel missing"
fi

CUTOFF_LN=$(grep -n 'if \[ -n "\${GATE_DISPATCHER_LIB_ONLY:-}" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
DEF_LN=$(grep -n '^GATE_DEPLOY_RETRY_MAX=' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$DEF_LN" ] && [ -n "$CUTOFF_LN" ] && [ "$DEF_LN" -lt "$CUTOFF_LN" ]; then
  ok "GATE_DEPLOY_RETRY_MAX default (line $DEF_LN) resolves before the lib-only cutoff (line $CUTOFF_LN)"
else
  bad "GATE_DEPLOY_RETRY_MAX must be defined before the GATE_DISPATCHER_LIB_ONLY cutoff (def=$DEF_LN cutoff=$CUTOFF_LN)"
fi

# GATE_DEPLOY_RETRY_MAX must ALSO already hold its default immediately after
# lib-only sourcing (ga-2u38b regression class: a future edit moving the
# default assignment back below the cutoff crashes every LIB_ONLY/selftest
# invocation that reaches the deploy block with "unbound variable").
if [ "${GATE_DEPLOY_RETRY_MAX:-}" = "3" ]; then
  ok "GATE_DEPLOY_RETRY_MAX resolves to its default under lib-only sourcing (not unbound)"
else
  bad "GATE_DEPLOY_RETRY_MAX did not resolve to default 3 under lib-only sourcing (got: ${GATE_DEPLOY_RETRY_MAX:-<unset>})"
fi

# ── 4. syntax ──────────────────────────────────────────────────────────────
echo "── 4. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
