#!/usr/bin/env bash
# gate-delivery-ack.selftest.sh — Drift-guard the ga-noxbv gate review-task
# delivery-race fix, with NO live Dolt/gc/launchd/notify.
#
# Bug ga-noxbv: a gate hung 38min at 1/3 verdicts. quality-gate-dispatcher.sh
# delivered each reviewer's task with `--delivery immediate` after a fixed
# `sleep 3`. `immediate` types the task into the freshly-spawned headless reviewer
# NOW — even if it is not yet input-ready → keystrokes dropped → reviewer idle
# forever. The dispatcher then logged "Review task delivered" UNCONDITIONALLY
# (lied on failure), and gate-health-monitor.py only keyed off gate-status:queued
# so the 38min stall (marker in :dispatching) was invisible.
#
# The fix:
#   1. reviewer task delivered via `--delivery queue` (runtime delivers when
#      input-ready), NOT `immediate` and NOT `wait-idle` (would stall sequential
#      spawning of reviewers 2&3).
#   2. the magic `sleep 3` removed.
#   3. "delivered" no longer logged unconditionally — a Step 7b ACK pass confirms
#      a real ACK (verdict bead past verdict:pending OR session producing output)
#      and re-queues idle sessions up to ACK_MAX_RETRIES.
#   4. gate-health-monitor.py gains an [IDLE-REVIEWER] watchdog that alerts when a
#      gate-run's pending verdicts make no progress for VERDICT_STALL_SEC, gated
#      on a Dolt-responsiveness probe (slow write != dead reviewer).
#
# This harness DRIFT-GUARDS the real scripts so a future refactor that drops any
# part of the fix fails loudly, and compile-guards both files. Exit 0 iff every
# assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"
# Monitor lives in <hq>/scripts; assets dir is <hq>/packs/town-deltas/assets.
MON="$SELF_DIR/../../../scripts/gate-health-monitor.py"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
has()    { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }
hasnot() { if grep -qE "$2" "$1"; then bad "$3 — forbidden pattern present: $2"; else ok "$3"; fi; }

echo "── 1. COMPILE-GUARD: both scripts parse cleanly ──"
if bash -n "$GATE" 2>/dev/null; then ok "dispatcher: bash -n clean"; else bad "dispatcher: bash -n FAILED"; fi
if /usr/bin/python3 -m py_compile "$MON" 2>/dev/null; then ok "monitor: py_compile clean"; else bad "monitor: py_compile FAILED"; fi

echo "── 2. DISPATCHER: queue delivery replaces the immediate-keystroke race ──"
has    "$GATE" 'nudge "\$SESSION_ID" "\$REVIEW_TASK" --delivery queue' "reviewer task delivered via --delivery queue"
hasnot "$GATE" 'nudge "\$SESSION_ID" "\$REVIEW_TASK" --delivery immediate' "no --delivery immediate on the reviewer task"
hasnot "$GATE" '^[[:space:]]*sleep 3[[:space:]]*$'                       "magic 'sleep 3' before reviewer nudge removed"
hasnot "$GATE" 'Review task delivered to session'                       "unconditional 'delivered' log removed"

echo "── 3. DISPATCHER: Step 7b ACK verification + bounded re-queue ──"
has "$GATE" 'ACK_MAX_RETRIES'                          "ACK retry budget present"
has "$GATE" 'REVIEWER_ACKED'                           "per-reviewer ACK state tracked"
has "$GATE" 'REVIEWER_PEEK_BASELINE'                   "pre-delivery peek baseline captured"
has "$GATE" 'verdict:pending'                          "strong ACK keys off verdict:pending progression"
has "$GATE" 'session peek .* --lines'                  "soft ACK samples session output"
has "$GATE" 'nudge "\$_sid" "\$\{REVIEW_TASKS\[\$k\]\}" --delivery queue' "idle session re-queued with its exact task"
# set -euo pipefail discipline: the re-queue nudge must be || true-guarded.
has "$GATE" 'nudge "\$_sid" "\$\{REVIEW_TASKS\[\$k\]\}" --delivery queue 2>/dev/null \|\| true' "re-queue nudge is || true-guarded (set -e safe)"

echo "── 4. MONITOR: idle-reviewer watchdog closes the :dispatching blind spot ──"
has "$MON" 'VERDICT_STALL_SEC'        "verdict-stall threshold defined"
has "$MON" 'def pending_verdicts_by_run' "per-run pending-verdict grouping present"
has "$MON" 'def dolt_responsive'      "Dolt-responsiveness probe present"
has "$MON" 'IDLE-REVIEWER'            "[IDLE-REVIEWER] alert emitted"
has "$MON" 'if not dolt_responsive\(\)'  "alert suppressed when Dolt is slow/unreachable"

echo
echo "── RESULT: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
