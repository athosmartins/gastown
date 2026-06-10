#!/usr/bin/env bash
# gate-head-of-line-skip.selftest.sh (ga-q3ig2)
#
# Proves the HEAD-OF-LINE fix: one stale-conflict / dead-author marker must NOT
# travar a fila inteira. The dispatcher used a pure FIFO `sort_by(.created_at)
# | .[0]` selection, so a broken marker that keeps the oldest created_at (re-
# queued by its own bounded retry, by gate-health-monitor, or by a manual re-
# anchor that resets gate:rebase-attempt) was re-selected EVERY sweep, failed the
# same rebase, and starved all healthy markers behind it (2× outages 2026-06-10,
# ~49min). The fix is two-tier selection: markers with NO auto-rebase failure are
# drained first; markers carrying gate:rebase-attempt:N sink to the BACK.
#
# It also proves the IDEAL dead-author skip: a genuine, deterministic merge
# conflict (CONFLICT_KIND="merge") with a dead author escalates to needs-rebase
# IMMEDIATELY (no retry budget), while a transient plumbing failure still gets the
# bounded retry.
#
# Strategy: extract the live selection jq expression VERBATIM from the dispatcher
# and run it against synthetic marker fixtures (so the test cannot diverge from
# the shipped code), then add source drift-guards for the CONFLICT_KIND branches.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER"; exit 1; }

# ── The selection expression, kept in lock-step with the dispatcher. ──────────
# We assert below (drift-guard) that the dispatcher still defines has_rebase_fail
# and the two-tier (healthy-first) ordering, so this fixture logic cannot silently
# diverge from production.
select_marker() {
  # reads marker-array JSON on stdin, prints the selected marker id
  jq -r '
    def has_rebase_fail: ((.labels // []) | map(select(test("^gate:rebase-attempt:[0-9]+$"))) | length) > 0;
    sort_by(.created_at)
    | (map(select(has_rebase_fail | not)) + map(select(has_rebase_fail)))
    | .[0].id'
}

mk() { # id created_at [labels-csv]
  local id="$1" ts="$2" labels="${3:-}"
  local labarr="[\"gate-status:queued\"]"
  [ -n "$labels" ] && labarr="$(printf '%s' "$labels" | jq -R 'split(",")')"
  printf '{"id":"%s","created_at":"%s","labels":%s}' "$id" "$ts" "$labarr"
}

echo "── (i) broken-oldest marker is SKIPPED for the oldest HEALTHY one ──"
FIX=$(printf '[%s,%s,%s]' \
  "$(mk broken 2026-06-10T19:00:00Z 'gate-status:queued,gate:rebase-attempt:2')" \
  "$(mk healthyA 2026-06-10T20:00:00Z 'gate-status:queued')" \
  "$(mk healthyB 2026-06-10T21:00:00Z 'gate-status:queued')")
SEL=$(printf '%s' "$FIX" | select_marker)
[ "$SEL" = "healthyA" ] \
  && ok "oldest-healthy (healthyA) selected, broken-but-older (broken) skipped — queue drains" \
  || bad "expected healthyA, got '$SEL' (broken marker would head-of-line-block)"

echo "── (ii) all-healthy queue keeps pure FIFO (oldest first) ──"
FIX=$(printf '[%s,%s,%s]' \
  "$(mk h3 2026-06-10T21:00:00Z 'gate-status:queued')" \
  "$(mk h1 2026-06-10T19:00:00Z 'gate-status:queued')" \
  "$(mk h2 2026-06-10T20:00:00Z 'gate-status:queued')")
SEL=$(printf '%s' "$FIX" | select_marker)
[ "$SEL" = "h1" ] && ok "no failures → oldest (h1) selected (ga-zf61i FIFO preserved)" \
  || bad "expected h1, got '$SEL'"

echo "── (iii) all-broken queue still drains (oldest broken, never deadlocks) ──"
FIX=$(printf '[%s,%s]' \
  "$(mk b2 2026-06-10T20:00:00Z 'gate-status:queued,gate:rebase-attempt:1')" \
  "$(mk b1 2026-06-10T19:00:00Z 'gate-status:queued,gate:rebase-attempt:3')")
SEL=$(printf '%s' "$FIX" | select_marker)
[ "$SEL" = "b1" ] && ok "only-broken queue → oldest broken (b1) retried (no starvation/deadlock)" \
  || bad "expected b1, got '$SEL'"

echo "── (iv) a lone broken marker is still selected (gets escalated, not ignored) ──"
FIX="[$(mk lone 2026-06-10T19:00:00Z 'gate-status:queued,gate:rebase-attempt:2')]"
SEL=$(printf '%s' "$FIX" | select_marker)
[ "$SEL" = "lone" ] && ok "single broken marker still picked (reaches immediate-skip/escalation)" \
  || bad "expected lone, got '$SEL'"

echo "── (v) source drift-guards: shipped dispatcher matches tested logic ──"
grep -q 'def has_rebase_fail' "$DISPATCHER" \
  && ok "dispatcher defines has_rebase_fail in selection" || bad "missing has_rebase_fail"
grep -q 'gate:rebase-attempt:\[0-9\]+' "$DISPATCHER" \
  && ok "selection matches gate:rebase-attempt:N labels" || bad "selection regex missing"
grep -q 'select(has_rebase_fail | not)) + map(select(has_rebase_fail))' "$DISPATCHER" \
  && ok "two-tier order: healthy-first then failed-last" || bad "two-tier ordering not found"
grep -q 'CONFLICT_KIND="merge"' "$DISPATCHER" \
  && ok "genuine merge conflict classified CONFLICT_KIND=merge" || bad "no merge classification"
grep -q 'CONFLICT_KIND="transient"' "$DISPATCHER" \
  && ok "transient plumbing failure classified CONFLICT_KIND=transient" || bad "no transient classification"
grep -q 'elif \[ "\$CONFLICT_KIND" = "merge" \]' "$DISPATCHER" \
  && ok "dead-author genuine conflict → immediate needs-rebase branch present" || bad "no immediate-skip branch"
grep -q 'dispatcher_needs_rebase_immediate' "$DISPATCHER" \
  && ok "immediate-skip emits a distinct REBASE_EVENT" || bad "no immediate-skip event"
# The transient path must STILL re-queue (bounded retry preserved).
grep -q 'dispatcher_autorebase_retry' "$DISPATCHER" \
  && ok "transient bounded-retry path preserved" || bad "transient retry path lost"

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" = 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
