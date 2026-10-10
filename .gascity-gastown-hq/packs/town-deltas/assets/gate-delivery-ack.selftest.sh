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
# ga-g3m45n: the three delivery sites (initial spawn, ACK re-queue, re-convene) all go through ONE
# function, gate_deliver_review_task, which builds the payload (pointer, or the full task when the durable
# channel is not proven) and does the delivery. What this section guards is the DELIVERY MODE, now in that function.
has    "$GATE" 'gate_nudge "\$_sid" "\$_msg" --delivery queue' "reviewer task delivered via --delivery queue (inside gate_deliver_review_task)"
hasnot "$GATE" 'nudge "\$_sid" "\$_msg" --delivery immediate' "no --delivery immediate on the reviewer task"
hasnot "$GATE" 'nudge "\$SESSION_ID" "\$REVIEW_TASK" --delivery' "no site hands the raw REVIEW_TASK to the nudge queue any more (ga-g3m45n: pointer-or-task goes through gate_deliver_review_task)"
has    "$GATE" 'gate_deliver_review_task "\$\(\(i-1\)\)" "\$SESSION_ID" "\$REVIEW_TASK" "\$i" "\$VERDICT_BEAD_ID" send' "initial spawn delivers through gate_deliver_review_task (send)"
has    "$GATE" 'gate_deliver_review_task "\$_idx" "\$_new_sid" "\$\{REVIEW_TASKS\[\$_idx\]\}" "\$_rev" "\$\{VERDICT_BEAD_IDS\[\$_idx\]\}" send' "re-convene delivers through gate_deliver_review_task (send)"
hasnot "$GATE" '^[[:space:]]*sleep 3[[:space:]]*$'                       "magic 'sleep 3' before reviewer nudge removed"
hasnot "$GATE" 'Review task delivered to session'                       "unconditional 'delivered' log removed"

echo "── 3. DISPATCHER: Step 7b ACK verification + bounded re-queue ──"
has "$GATE" 'ACK_MAX_RETRIES'                          "ACK retry budget present"
has "$GATE" 'REVIEWER_ACKED'                           "per-reviewer ACK state tracked"
has "$GATE" 'REVIEWER_PEEK_BASELINE'                   "pre-delivery peek baseline captured"
has "$GATE" 'verdict:pending'                          "strong ACK keys off verdict:pending progression"
has "$GATE" 'session peek .* --lines'                  "soft ACK samples session output"
has "$GATE" 'gate_deliver_review_task "\$k" "\$_sid" "\$\{REVIEW_TASKS\[\$k\]\}" "\$\(\(k\+1\)\)" "\$_vb" retry' "idle session re-queued through gate_deliver_review_task in retry mode (its task: pointer or full, ga-g3m45n)"
# set -euo pipefail discipline: the re-queue must be guarded so a failed re-queue can't kill the ACK loop
# under set -e, AND its failure must not be swallowed. ga-vne2 (2026-08-08) moved the guard from a bare
# `|| true` to `|| warn "..."` on purpose: swallowing the failure alongside the diagnostic hid WHY a
# re-queue didn't land (dead session vs a real nudge failure). ga-g3m45n moved the call into
# gate_deliver_review_task, whose return code (0 queued / 10 already queued / 1 not delivered) the call site
# reads with `|| _rq_rc=$?` and a `case` — same guarantee, so the checks below pin the new shape: the call is
# guarded by `|| _rq_rc=$?` (set -e safe), the not-delivered arm still warns, and nothing swallows with `|| true`.
GATE_JOINED=$(awk '{ if (sub(/\\$/, "")) { printf "%s ", $0; next } else { print } }' "$GATE")
if echo "$GATE_JOINED" | grep -E 'gate_deliver_review_task "\$k" .* retry \|\| _rq_rc=\$\?' >/dev/null; then
  ok "re-queue call is guarded with || _rq_rc=\$? (set -e safe) (ga-g3m45n)"
else
  bad "re-queue call is guarded with || _rq_rc=\$? (set -e safe) — pattern not found"
fi
if awk '/_rq_rc=0/ {f=1} f && /\*\) warn "  Re-fila para \$_sid N/ {print "yes"; exit}' "$GATE" | grep -q yes; then
  ok "re-queue not-delivered arm is diagnosed via warn, not silently swallowed (ga-vne2)"
else
  bad "re-queue not-delivered arm is diagnosed via warn (ga-vne2) — not found"
fi
if echo "$GATE_JOINED" | grep -E 'gate_deliver_review_task "\$k" .* retry \|\| true([[:space:]]|$)' >/dev/null; then
  bad "re-queue does not silently swallow failure — forbidden pattern present: || true"
else
  ok "re-queue does not silently swallow failure with a bare || true"
fi

echo "── 4. MONITOR: idle-reviewer watchdog closes the :dispatching blind spot ──"
has "$MON" 'VERDICT_STALL_SEC'        "verdict-stall threshold defined"
has "$MON" 'def pending_verdicts_by_run' "per-run pending-verdict grouping present"
has "$MON" 'def dolt_responsive'      "Dolt-responsiveness probe present"
has "$MON" 'IDLE-REVIEWER'            "[IDLE-REVIEWER] alert emitted"
has "$MON" 'if not dolt_responsive\(\)'  "alert suppressed when Dolt is slow/unreachable"

echo
echo "── RESULT: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
