#!/usr/bin/env bash
# gate-y5c29l-retry-dead-clean-bypass.selftest.sh (ga-y5c29l, 2026-09-15)
#
# Proves the retry_dead circuit-break call site actually uses the
# merge-tree-proven-clean signal it was supposed to use all along.
#
# gate_circuit_break_check()'s "retry_dead" condition already has a
# merge_clean exemption (ga-agtqm, 7th arg): "retries exhausted + dead
# author" should never circuit-break a branch that merge-tree already
# proved merges into main with ZERO conflicts — repeated failures there are
# evidence of a transient/environment problem (disk, worktree, push race),
# never of an unmergeable branch. That exemption is independently tested and
# correct in isolation (quality-gate-circuit-break.selftest.sh, section 3b).
#
# The bug: the retry_dead CALL SITE fed it "$REBASE_AHEAD_CAP_ONLY" instead
# — a flag (ga-agtqm) scoped to a narrow, DIFFERENT condition (branch out of
# envelope SOLELY due to the ahead-commit-count cap) that is almost always 0
# by the time this transient-operational-failure path is reached. So the
# exemption silently never applied to the actual common case it was needed
# for. Measured incident: wa-llq1a / wa-4zmm1 (2026-09-11) — both branches
# were provably clean (merge-tree confirmed), yet auto-rebase kept failing
# for operational reasons (disk pressure that day), retries exhausted, and
# the marker was terminally circuit-broken/escalated anyway. The Mayor had
# to manually clear gate:rebase-fail-count, gate:exiled-tier5, and
# gate:exiled-since by hand to give the branch a fresh attempt.
#
# Fix: introduce REBASE_MERGE_TREE_PROVEN_CLEAN, set from THIS sweep's own
# MT_VERDICT (the merge-tree pre-check that already gates entry to the whole
# auto-rebase block), wire it into the retry_dead call site instead of
# REBASE_AHEAD_CAP_ONLY, and — since gate_circuit_break_check()'s "ok" used
# to mean only "GATE_AUTO_CIRCUIT_BREAK=0, fall through to legacy
# needs-rebase escalation" — add a caller-side branch so a provably-clean,
# exhausted-retry marker stays in the retriable queue (already sunk to
# tier5) instead of also terminally escalating. gate_exile_watchdog_sweep
# (ga-faw5o) remains the appropriate backstop on an hours-long timescale if
# it genuinely never recovers.
#
# Strategy mirrors gate-exile-watchdog.selftest.sh: extract the LIVE
# decision block via its SELFTEST-EXTRACT sentinel (never a hand-copied
# duplicate), wrap it as a function, and stub only the side-effecting
# commands (bd/gc/warn/err/set_gate_status/gate_apply_needs_human/
# gate_needs_human_clause) — gate_circuit_break_check itself is the REAL,
# already-independently-tested pure function (loaded via
# GATE_DISPATCHER_LIB_ONLY), never re-mocked here.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-y5c29l-retry-dead-clean-bypass.selftest =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

# ── 1. Wiring drift-guard: the call site must use the CORRECT variable ───────
# This is the literal bug — fails against the pre-fix file (which passes
# "$REBASE_AHEAD_CAP_ONLY" here instead) and passes post-fix.
echo "── 1. retry_dead call site wiring ──"
if grep -qF 'gate_circuit_break_check "retry_dead" "" "$REBASE_AUTHOR_ALIVE" "$NEXT_ATTEMPT" "$MAX_REBASE_ATTEMPTS" "$GATE_REBASE_AHEAD_MAX" "$REBASE_MERGE_TREE_PROVEN_CLEAN"' "$DISPATCHER"; then
  ok "retry_dead call site passes \$REBASE_MERGE_TREE_PROVEN_CLEAN as the merge_clean arg (ga-y5c29l)"
else
  bad "retry_dead call site does NOT pass \$REBASE_MERGE_TREE_PROVEN_CLEAN — still wired to the wrong (or another wrong) variable"
fi
if grep -qF 'gate_circuit_break_check "retry_dead" "" "$REBASE_AUTHOR_ALIVE" "$NEXT_ATTEMPT" "$MAX_REBASE_ATTEMPTS" "$GATE_REBASE_AHEAD_MAX" "$REBASE_AHEAD_CAP_ONLY"' "$DISPATCHER"; then
  bad "retry_dead call site STILL passes \$REBASE_AHEAD_CAP_ONLY (the pre-fix bug) — should have been replaced, not duplicated"
else
  ok "retry_dead call site no longer passes the mis-scoped \$REBASE_AHEAD_CAP_ONLY"
fi

# ── 2. Structural drift-guard: REBASE_MERGE_TREE_PROVEN_CLEAN is wired to ────
#      the merge-tree pre-check (MT_VERDICT), not to something else.
echo "── 2. REBASE_MERGE_TREE_PROVEN_CLEAN is set from the MT_VERDICT clean branch ──"
_INIT_LN=$(grep -n 'REBASE_MERGE_TREE_PROVEN_CLEAN=0' "$DISPATCHER" | head -1 | cut -d: -f1)
_MT_IF_LN=$(grep -n 'if \[ "\$MT_VERDICT" = "err" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
_SET1_LN=$(grep -n 'REBASE_MERGE_TREE_PROVEN_CLEAN=1' "$DISPATCHER" | head -1 | cut -d: -f1)
_ENVELOPE_LN=$(grep -n 'imp22: Constrain auto-rebase to the FF-only' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$_INIT_LN" ] && [ -n "$_MT_IF_LN" ] && [ -n "$_SET1_LN" ] && [ -n "$_ENVELOPE_LN" ] \
   && [ "$_INIT_LN" -lt "$_MT_IF_LN" ] && [ "$_MT_IF_LN" -lt "$_SET1_LN" ] && [ "$_SET1_LN" -lt "$_ENVELOPE_LN" ]; then
  ok "REBASE_MERGE_TREE_PROVEN_CLEAN=0 init (line $_INIT_LN) precedes the MT_VERDICT if (line $_MT_IF_LN), whose else-branch sets =1 (line $_SET1_LN), all before the envelope block (line $_ENVELOPE_LN) — correctly scoped to THIS sweep's clean pre-check, not a stray later assignment"
else
  bad "REBASE_MERGE_TREE_PROVEN_CLEAN's init/set ordering relative to the MT_VERDICT check drifted (init=$_INIT_LN mt_if=$_MT_IF_LN set1=$_SET1_LN envelope=$_ENVELOPE_LN)"
fi

# ── 3. Behavioral: extract the REAL retry_dead decision block and run it ─────
extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

# Load the REAL gate_circuit_break_check (pure, already independently
# tested — never re-mocked here) plus its sibling helpers.
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 2; }
type gate_circuit_break_check >/dev/null 2>&1 \
  || { echo "FATAL: gate_circuit_break_check not defined by dispatcher"; exit 2; }

BLOCK="$(extract_block "$DISPATCHER" "ga-y5c29l-retry-dead-decision")"
if [ -z "$BLOCK" ]; then
  echo "FATAL: SELFTEST-EXTRACT ga-y5c29l-retry-dead-decision block not found in $DISPATCHER" >&2
  exit 2
fi
eval "retry_dead_decision() { $BLOCK
}"
if ! declare -F retry_dead_decision >/dev/null 2>&1; then
  echo "FATAL: extracted block did not define retry_dead_decision" >&2
  exit 2
fi

# ── stubs (side-effecting commands only) ──────────────────────────────────────
BD_LOG=""; GC_LOG=""; WARN_LOG=""; ERR_LOG=""; STATUS_LOG=""; NH_LOG=""

bd() {
  # -C <city> label add|remove <id> <label> [-q]  |  -C <city> comment <id> <text>  |  -C <city> assign <id> <val> [-q]
  BD_LOG="$BD_LOG|$*"
  return 0
}
gc() {
  # --city <city> mail send <recipient> -s ... -m ...
  if [ "$1" = "--city" ] && [ "$3" = "mail" ] && [ "$4" = "send" ]; then
    GC_LOG="$GC_LOG|$5"
  fi
  return 0
}
warn() { WARN_LOG="$WARN_LOG|$*"; }
err()  { ERR_LOG="$ERR_LOG|$*"; }
set_gate_status() { STATUS_LOG="$STATUS_LOG|$1:$2"; }
gate_apply_needs_human() { NH_LOG="$NH_LOG|$2:$3"; printf 'armed'; }
gate_needs_human_clause() { printf 'needs-human armed'; }

reset_stubs() { BD_LOG=""; GC_LOG=""; WARN_LOG=""; ERR_LOG=""; STATUS_LOG=""; NH_LOG=""; }

# Common fixture identity.
MARKER_ID="m-y5c29l"; BEAD_ID="bead-y5c29l"; BEAD_CITY="test-city"; GC_CITY="test-city"
BRANCH="crew/wa-worker/wa-fixture"; DEFAULT_BRANCH="main"; RIG="whatsapp_automation"
MAIN_HEAD_SHA="deadbeef"; CONFLICT_FILES="auto-rebase push failed (exit=128): fatal: unable to write new_index file: No space left on device"
REBASE_LIVENESS_TRACE="wa-worker-adhoc-77:dead"; AUTHOR=""
GATE_REBASE_AHEAD_MAX=10; MAX_REBASE_ATTEMPTS=3

echo "── 3a. NOT proven clean, retries exhausted, dead author → UNCHANGED harsh circuit-break ──"
reset_stubs
REBASE_AUTHOR_ALIVE=0; NEXT_ATTEMPT=3; REBASE_MERGE_TREE_PROVEN_CLEAN=0
unset REBASE_EVENT REBASE_VERDICT 2>/dev/null || true
retry_dead_decision
# Note: gate_apply_needs_human is invoked as `_NH_STATUS=$(gate_apply_needs_human ...)`
# — a command substitution — so a stub's own variable writes (NH_LOG) run in a
# subshell and never propagate back here; $_NH_STATUS (its captured stdout,
# leaked into this scope because the original code never declares it `local`)
# is the reliable signal instead.
if [ "${REBASE_EVENT:-}" = "dispatcher_circuit_break_retry_dead" ] \
   && [ "$STATUS_LOG" = "|$MARKER_ID:error" ] \
   && echo "$BD_LOG" | grep -q "assign $BEAD_ID" \
   && [ "${_NH_STATUS:-}" = "armed" ]; then
  ok "unproven-clean + exhausted + dead author still hard-circuit-breaks exactly as before (status=$STATUS_LOG event=$REBASE_EVENT, needs-human=$_NH_STATUS) — no regression"
else
  bad "expected unchanged harsh circuit-break, got event='${REBASE_EVENT:-}' status='$STATUS_LOG' nh_status='${_NH_STATUS:-}' bd='$BD_LOG'"
fi

echo "── 3b. ga-y5c29l FIX: proven clean, retries exhausted, dead author → stays queued, NOT circuit-broken ──"
reset_stubs
REBASE_AUTHOR_ALIVE=0; NEXT_ATTEMPT=5; REBASE_MERGE_TREE_PROVEN_CLEAN=1
unset REBASE_EVENT REBASE_VERDICT 2>/dev/null || true
retry_dead_decision
if [ "${REBASE_EVENT:-}" = "dispatcher_autorebase_retry_clean_exhausted" ] \
   && [ "$STATUS_LOG" = "|$MARKER_ID:queued" ] \
   && [ -z "$GC_LOG" ] \
   && ! echo "$BD_LOG" | grep -q "$BEAD_ID"; then
  ok "wa-llq1a/wa-4zmm1 shape (clean, exhausted, dead author) now stays gate-status:queued, posts no mail, and never touches the source bead (status=$STATUS_LOG event=$REBASE_EVENT)"
else
  bad "expected quiet queued retry with the bead left alone, got event='${REBASE_EVENT:-}' status='$STATUS_LOG' gc='$GC_LOG' bd='$BD_LOG'"
fi

echo "── 3c. legacy fail-open path (GATE_AUTO_CIRCUIT_BREAK=0, still NOT proven clean) → UNCHANGED needs-rebase escalation ──"
reset_stubs
REBASE_AUTHOR_ALIVE=0; NEXT_ATTEMPT=3; REBASE_MERGE_TREE_PROVEN_CLEAN=0
unset REBASE_EVENT REBASE_VERDICT 2>/dev/null || true
GATE_AUTO_CIRCUIT_BREAK=0 retry_dead_decision
if [ "${REBASE_EVENT:-}" = "dispatcher_needs_rebase_escalated" ] \
   && [ "$STATUS_LOG" = "|$MARKER_ID:needs-rebase" ] \
   && echo "$GC_LOG" | grep -q "mayor"; then
  ok "GATE_AUTO_CIRCUIT_BREAK=0 fail-open still takes the original legacy needs-rebase escalation when cleanliness was never proven (status=$STATUS_LOG event=$REBASE_EVENT) — the new bypass is gated on PROVEN clean, not a blanket skip of escalation"
else
  bad "expected unchanged legacy fail-open escalation, got event='${REBASE_EVENT:-}' status='$STATUS_LOG' gc='$GC_LOG'"
fi

echo ""; echo "gate-y5c29l-retry-dead-clean-bypass.selftest: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
