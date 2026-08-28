#!/usr/bin/env bash
# gate-priority-starvation-ceiling.selftest.sh (ga-ddm76, 2026-08-28)
#
# Proves the HARD-CEILING anti-starvation backstop in the live marker-selection
# block (quality-gate-dispatcher.sh, SELFTEST-EXTRACT sentinel "marker-select"):
# a non-priority marker that has waited past GATE_MARKER_HARD_AGE_SECONDS wins
# selection REGARDLESS of a fresher (or even merely-aged) priority-tier marker
# sitting in the same queue.
#
# Background (see ga-ddm76): gate-author-priority.selftest.sh case 2 already
# proves — correctly, and by design — that a FRESH priority marker beats an
# AGED non-priority one. That is Athos's intentional 2026-07-15 policy and
# this fix does NOT reverse it (case (2) below re-proves it still holds).
# The gap this fix closes is narrower: under SUSTAINED priority submission,
# a non-priority marker had no actual ceiling at all, only a soft one that
# held only as long as the priority author's burst was short. Live-measured:
# ga-wisp-am67hm (non-oracle) queued 21:59:55 2026-08-27, three fresh
# crew/oracle/* markers each drained ahead of it although it was already
# long past GATE_MARKER_AGE_PROMOTE_SECONDS, and it did not close until
# 23:11:43 — 71min, not the promised 30min.
#
# Strategy mirrors the sibling gate-*.selftest.sh files exactly: extract the
# LIVE block via its sentinels (never a hand-copied jq) and run it under the
# host bash with MARKERS_JSON + the NOW/AGE/HARD_AGE/PRIORITY_AUTHORS test
# seams set.
#
# This file does NOT self-certify "fails pre-fix, passes post-fix" in-process.
# An earlier revision tried that via `git show HEAD:<path>`, which is only
# ever true in the author's uncommitted sandbox: at ANY committed state of
# this branch — including the exact commit under review — HEAD already IS
# the fix, so the comparison is vacuous by construction and cannot pass in a
# form any reviewer or rerun can ever observe. That proof is instead done
# externally and safely by quality-gate-guard.sh's Step 5b-pre2 base-test
# harness, which materializes this file onto a genuine throwaway base-commit
# worktree and confirms at least one case fails there (see the marker's
# `gate-ab-basetest:*` label).
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-priority-starvation-ceiling.selftest (ga-ddm76) =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract_block() {
  sed -n '/# SELFTEST-EXTRACT marker-select: BEGIN/,/# SELFTEST-EXTRACT marker-select: END/p' "$1"
}

SELECT_BLOCK="$(extract_block "$DISPATCHER")"
if [ -z "$SELECT_BLOCK" ]; then
  echo "FATAL: could not extract marker-select block (sentinels missing?)" >&2
  exit 2
fi
ok "located live marker-select block via sentinel extraction"

# mk <id> <created_at_iso> [author] [extra-labels-csv]
# Mirrors gate-author-priority.selftest.sh's builder: embeds a `branch:
# crew/<author>/<id>` line in the description (the field is_priority's
# crew_of parses), plus always gate-status:queued unless extra labels
# override the label set entirely.
mk() {
  local id="$1" ts="$2" author="${3:-}" labels="${4:-}"
  local labarr='["gate-status:queued"]'
  [ -n "$labels" ] && labarr="$(printf '%s' "$labels" | jq -R 'split(",")')"
  local desc="branch: crew/${author:-unknown}/${id}"
  jq -cn --arg id "$id" --arg ts "$ts" --arg desc "$desc" --argjson labels "$labarr" \
    '{id:$id, created_at:$ts, description:$desc, labels:$labels}'
}

select_marker() {
  # args: $1=block  $2=MARKERS_JSON  $3=now_epoch  $4=age_threshold  $5=hard_threshold  $6=priority_authors
  local block="$1" markers_json="$2" now_epoch="$3" age_threshold="${4:-1800}" \
        hard_threshold="${5:-5400}" prio="${6-oracle}"
  MARKERS_JSON="$markers_json" \
  GATE_MARKER_NOW_OVERRIDE_EPOCH="$now_epoch" \
  GATE_MARKER_AGE_PROMOTE_SECONDS="$age_threshold" \
  GATE_MARKER_HARD_AGE_SECONDS="$hard_threshold" \
  GATE_PRIORITY_AUTHORS="$prio" \
  bash -c "$block"$'\necho "$MARKER_ID"' 2>/dev/null
}

NOW_EPOCH=1782863814
THRESH=1800   # 30min, matches GATE_MARKER_AGE_PROMOTE_SECONDS default
HARD=5400     # 90min, matches GATE_MARKER_HARD_AGE_SECONDS default (3x THRESH)
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
ago() { iso "$((NOW_EPOCH - $1))"; }

echo "── (1) THE BUG, reproduced: overdue non-priority marker now beats a fresh priority one ──"
FIX=$(printf '[%s,%s]' \
  "$(mk starved "$(ago 5500)" mila)" \
  "$(mk orcnew  "$(ago 60)"   oracle)")
SEL=$(select_marker "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "oracle")
[ "$SEL" = "starved" ] && ok "overdue non-oracle (5500s > ${HARD}s hard ceiling) wins over fresh oracle — ceiling closes the gap" \
  || bad "expected starved, got '$SEL' — hard ceiling did not override priority"

echo "── (2) NOT reversed: merely-aged (not yet overdue) non-priority STILL loses to fresh priority ──"
# Exact numbers from gate-author-priority.selftest.sh case (2) — re-proves
# Athos's 2026-07-15 policy is untouched by this fix.
FIX=$(printf '[%s,%s]' \
  "$(mk orc "$(ago 60)"   oracle)" \
  "$(mk oth "$(ago 3600)" thies)")
SEL=$(select_marker "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "oracle")
[ "$SEL" = "orc" ] && ok "fresh oracle (60s) still beats aged-but-not-overdue non-oracle (3600s < ${HARD}s) — policy intact" \
  || bad "expected orc, got '$SEL' — this fix over-applied and reversed the intentional priority policy"

echo "── (3) overdue tier is priority-BLIND FIFO: oldest overdue wins even over an overdue PRIORITY marker ──"
FIX=$(printf '[%s,%s]' \
  "$(mk orcoverdue "$(ago 5500)" oracle)" \
  "$(mk othoverdue "$(ago 7200)" mila)")
SEL=$(select_marker "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "oracle")
[ "$SEL" = "othoverdue" ] && ok "oldest-of-overdue (othoverdue, 7200s) wins over a newer overdue oracle marker — ceiling ignores priority entirely" \
  || bad "expected othoverdue, got '$SEL' — overdue tier is not priority-blind/FIFO"

echo "── (4) ga-q3ig2 guarantee holds even at the ceiling: an overdue REBASE-FAIL marker never jumps ──"
FIX=$(printf '[%s,%s]' \
  "$(mk broken "$(ago 10000)" oracle 'gate-status:queued,gate:exiled-tier5:2')" \
  "$(mk fresh  "$(ago 60)"    mila)")
SEL=$(select_marker "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "oracle")
[ "$SEL" = "fresh" ] && ok "overdue-and-broken marker still sinks behind a fresh healthy one — ceiling is healthy-tier-only" \
  || bad "expected fresh, got '$SEL' — a conflicted marker jumped the queue via the new ceiling (ga-q3ig2 regression)"

echo "── (5) boundary: exactly at the hard threshold is NOT yet overdue (strict >, no flakiness) ──"
FIX=$(printf '[%s,%s]' \
  "$(mk atboundary "$(ago "$HARD")" mila)" \
  "$(mk orcnewer   "$(ago 60)"      oracle)")
SEL=$(select_marker "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "oracle")
[ "$SEL" = "orcnewer" ] && ok "marker at exactly the hard threshold age is NOT overdue yet (strict >) — falls through to priority tier as before" \
  || bad "expected orcnewer, got '$SEL' (off-by-one on the overdue boundary)"

echo "── (6) default multiplier: GATE_MARKER_HARD_AGE_SECONDS unset resolves to 3x the promote threshold ──"
FIX=$(printf '[%s,%s]' \
  "$(mk overdefault "$(ago $((THRESH * 3 + 1)))" mila)" \
  "$(mk orcnewer2   "$(ago 60)"                  oracle)")
SEL=$(MARKERS_JSON="$FIX" GATE_MARKER_NOW_OVERRIDE_EPOCH="$NOW_EPOCH" \
  GATE_MARKER_AGE_PROMOTE_SECONDS="$THRESH" GATE_PRIORITY_AUTHORS="oracle" \
  bash -c "$SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null)
[ "$SEL" = "overdefault" ] && ok "leaving GATE_MARKER_HARD_AGE_SECONDS unset defaults to 3x GATE_MARKER_AGE_PROMOTE_SECONDS (${THRESH}s -> $((THRESH*3))s)" \
  || bad "expected overdefault, got '$SEL' — default multiplier not wired (or wrong factor)"

echo "── (7) gate-feedback-style regression: malformed GATE_MARKER_HARD_AGE_SECONDS must not crash the sweep ──"
FIX2=$(printf '[%s,%s]' "$(mk h1 "$(ago 600)" mila)" "$(mk h2 "$(ago 60)" mila)")
SEL=$(MARKERS_JSON="$FIX2" GATE_MARKER_NOW_OVERRIDE_EPOCH="$NOW_EPOCH" \
  GATE_MARKER_AGE_PROMOTE_SECONDS="$THRESH" GATE_MARKER_HARD_AGE_SECONDS="not-a-number" \
  GATE_PRIORITY_AUTHORS="oracle" \
  bash -c "set -euo pipefail; $SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null)
STATUS=$?
if [ "$STATUS" = "0" ] && [ "$SEL" = "h2" ]; then
  ok "malformed GATE_MARKER_HARD_AGE_SECONDS falls back to the 3x default instead of crashing the sweep (exit=$STATUS, selected=$SEL)"
else
  bad "malformed GATE_MARKER_HARD_AGE_SECONDS broke selection (exit=$STATUS, selected='$SEL') — needs the same case-guard as sibling GATE_* tunables"
fi

echo "── (8) drift-guards: shipped dispatcher matches tested logic ──"
grep -q 'def is_overdue' "$DISPATCHER" \
  && ok "is_overdue predicate present" || bad "is_overdue predicate missing"
grep -q 'GATE_MARKER_HARD_AGE_SECONDS' "$DISPATCHER" \
  && ok "hard-age ceiling is a configurable GATE_* tunable (matches house convention)" || bad "hard-age threshold not configurable"
OVERDUE_LINE=$(grep -n 'map(select(is_overdue' "$DISPATCHER" | head -1 | cut -d: -f1)
PRIO_AGED_LINE=$(grep -n 'is_aged))' "$DISPATCHER" | grep -v 'is_aged | not' | head -1 | cut -d: -f1)
BROKEN_LINE=$(grep -n 'map(select(has_rebase_fail))' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$OVERDUE_LINE" ] && [ -n "$PRIO_AGED_LINE" ] && [ -n "$BROKEN_LINE" ] \
   && [ "$OVERDUE_LINE" -lt "$PRIO_AGED_LINE" ] && [ "$PRIO_AGED_LINE" -lt "$BROKEN_LINE" ]; then
  ok "tier order fixed: overdue-ceiling, then priority-aged/other tiers, then rebase-fail"
else
  bad "tier order drifted (overdue=$OVERDUE_LINE prio-aged=$PRIO_AGED_LINE broken=$BROKEN_LINE) — re-check concat order"
fi

echo ""
echo "== gate-priority-starvation-ceiling: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
