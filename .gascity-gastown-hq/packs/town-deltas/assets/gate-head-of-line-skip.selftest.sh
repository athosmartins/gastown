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
# Strategy: extract the live selection block VERBATIM from the dispatcher
# (between sentinel comments) and execute it against synthetic marker fixtures
# (so the test cannot diverge from the shipped code), then add source
# drift-guards for the CONFLICT_KIND branches.
#
# POSTMORTEM (ga-tgo7q, 2026-07-02): this file used to hand-copy the jq filter
# into select_marker() instead of genuinely extracting it. 4cae0a2c49
# (2026-06-24) added a newest-first tiebreak (`| reverse`) to the shipped
# selection, but the hand-copied test filter was never updated — so this file
# kept asserting oldest-first ("ga-zf61i FIFO preserved") and PASSING for over
# a week while production actually shipped newest-first. The "drift-guard"
# section didn't catch it either: it only grep'd for the tier-split substring,
# which is present in both the old and new code, so it never checked sort
# direction. Fixed by switching to genuine sentinel-delimited extraction (same
# mechanism as gate-marker-age-promote.selftest.sh) so this class of silent
# drift can't recur. Aging (ga-tgo7q's own fix) is a SEPARATE concern with its
# own dedicated coverage there — this file pins GATE_MARKER_AGE_PROMOTE_SECONDS
# absurdly high so aging never interferes with what it's testing here.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER"; exit 1; }

# ── Genuine live extraction (not a hand-copied jq string — see postmortem above) ──
SELECT_BLOCK="$(sed -n '/# SELFTEST-EXTRACT marker-select: BEGIN/,/# SELFTEST-EXTRACT marker-select: END/p' "$DISPATCHER")"
[ -n "$SELECT_BLOCK" ] || { echo "FATAL: could not locate marker-select sentinel block in $DISPATCHER"; exit 1; }

select_marker() {
  # reads marker-array JSON on stdin, prints the selected marker id.
  # Age threshold pinned huge: this file is scoped to the ga-q3ig2 two-tier +
  # newest-first tiebreak, not aging (see gate-marker-age-promote.selftest.sh).
  local markers_json; markers_json="$(cat)"
  MARKERS_JSON="$markers_json" \
  GATE_MARKER_AGE_PROMOTE_SECONDS=999999999 \
  bash -c "$SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null
}

mk() { # id created_at [labels-csv]
  local id="$1" ts="$2" labels="${3:-}"
  local labarr="[\"gate-status:queued\"]"
  [ -n "$labels" ] && labarr="$(printf '%s' "$labels" | jq -R 'split(",")')"
  printf '{"id":"%s","created_at":"%s","labels":%s}' "$id" "$ts" "$labarr"
}

echo "── (i) broken-oldest marker is SKIPPED for the NEWEST healthy one ──"
FIX=$(printf '[%s,%s,%s]' \
  "$(mk broken 2026-06-10T19:00:00Z 'gate-status:queued,gate:exiled-tier5:2')" \
  "$(mk healthyA 2026-06-10T20:00:00Z 'gate-status:queued')" \
  "$(mk healthyB 2026-06-10T21:00:00Z 'gate-status:queued')")
SEL=$(printf '%s' "$FIX" | select_marker)
[ "$SEL" = "healthyB" ] \
  && ok "newest-healthy (healthyB) selected, broken (older, rebase-fail) skipped — queue drains" \
  || bad "expected healthyB, got '$SEL' (broken marker would head-of-line-block, or tiebreak regressed)"

echo "── (ii) all-healthy queue prefers newest (Athos's 6/24 tiebreak, 4cae0a2c49) ──"
FIX=$(printf '[%s,%s,%s]' \
  "$(mk h3 2026-06-10T21:00:00Z 'gate-status:queued')" \
  "$(mk h1 2026-06-10T19:00:00Z 'gate-status:queued')" \
  "$(mk h2 2026-06-10T20:00:00Z 'gate-status:queued')")
SEL=$(printf '%s' "$FIX" | select_marker)
[ "$SEL" = "h3" ] && ok "no failures → newest (h3) selected (4cae0a2c49 tiebreak; ga-zf61i's oldest-first was deliberately superseded)" \
  || bad "expected h3, got '$SEL'"

echo "── (iii) all-broken queue still drains (newest broken retried, never deadlocks) ──"
# ga-gpcx: b2 carries the current label name, b1 the legacy pre-2026-07-17 name
# (gate:rebase-attempt:N) — proves both names sink to this tier AND interoperate
# correctly under the newest-first tiebreak during a mixed-fleet rename rollout.
FIX=$(printf '[%s,%s]' \
  "$(mk b2 2026-06-10T20:00:00Z 'gate-status:queued,gate:exiled-tier5:1')" \
  "$(mk b1 2026-06-10T19:00:00Z 'gate-status:queued,gate:rebase-attempt:3')")
SEL=$(printf '%s' "$FIX" | select_marker)
[ "$SEL" = "b2" ] && ok "only-broken queue (mixed current+legacy label names) → newest broken (b2) retried (no starvation/deadlock)" \
  || bad "expected b2, got '$SEL'"

echo "── (iv) a lone broken marker is still selected (gets escalated, not ignored) ──"
FIX="[$(mk lone 2026-06-10T19:00:00Z 'gate-status:queued,gate:exiled-tier5:2')]"
SEL=$(printf '%s' "$FIX" | select_marker)
[ "$SEL" = "lone" ] && ok "single broken marker still picked (reaches immediate-skip/escalation)" \
  || bad "expected lone, got '$SEL'"

echo "── (v) source drift-guards: shipped dispatcher matches tested logic ──"
grep -q 'def has_rebase_fail' "$DISPATCHER" \
  && ok "dispatcher defines has_rebase_fail in selection" || bad "missing has_rebase_fail"
grep -q 'gate:(rebase-attempt|exiled-tier5):\[0-9\]+' "$DISPATCHER" \
  && ok "selection matches gate:exiled-tier5:N labels (and the pre-ga-gpcx legacy name)" || bad "selection regex missing"
grep -q 'map(select(has_rebase_fail))' "$DISPATCHER" \
  && ok "rebase-fail tier still isolated (sinks to the back)" || bad "rebase-fail tier not found — head-of-line fix may have regressed"
grep -q '| reverse' "$DISPATCHER" \
  && ok "newest-first tiebreak (4cae0a2c49) present — the exact thing that silently drifted from this test before" \
  || bad "'| reverse' missing — either the 6/24 tiebreak policy was reverted, or this guard needs updating to match"
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
