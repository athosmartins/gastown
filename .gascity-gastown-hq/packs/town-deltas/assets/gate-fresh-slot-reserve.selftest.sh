#!/usr/bin/env bash
# gate-fresh-slot-reserve.selftest.sh (ga-vm428, 2026-09-01)
#
# Proves the RESERVED FRESH SLOT anti-starvation fix in the live
# marker-selection block (quality-gate-dispatcher.sh, SELFTEST-EXTRACT
# sentinel "marker-select"): under a SUSTAINED backlog — every queued marker
# already past GATE_MARKER_AGE_PROMOTE_SECONDS — the fresh/newest-first tiers
# (tier3/tier5) are structurally empty (ga-tgo7q's aged tier always sorts
# BEFORE the not-yet-aged tier within a priority class), so the dispatcher
# degenerates into pure FIFO exactly when the two-speed "recent work gets
# fast feedback" design would matter most (ga-faw5o Defeito 2 / ga-vm428).
#
# Fix: reserve one admission slot every GATE_FRESH_SLOT_WINDOW_SWEEPS sweeps
# (default 10, persisted-across-sweeps counter, same convention as
# SPAWN_ABORT_COUNT_FILE/ga-piscg) for the single freshest HEALTHY
# (non-rebase-fail) marker, regardless of age rank or priority class. This is
# an ADDITIVE tier sitting between the overdue-emergency ceiling (tier1,
# ga-ddm76 — strictly stronger, must never be pre-empted by this softer
# periodic one) and the existing priority/aged cascade (tiers 2-6, unchanged
# when the reservation is not due).
#
# Strategy mirrors the sibling gate-*.selftest.sh files: Part A unit-tests the
# PURE sweep-counter decision in isolation (mirror of
# gate-spawn-abort-escalation.selftest.sh's spawn_abort_should_page pattern);
# Part B extracts the LIVE marker-select block via its sentinels (never a
# hand-copied jq) and runs it under the host bash with the MARKERS_JSON +
# NOW/AGE/HARD_AGE/PRIORITY_AUTHORS/FRESH_SLOT_DUE test seams set (mirror of
# gate-priority-starvation-ceiling.selftest.sh's select_marker pattern).
#
# This file does NOT self-certify "fails pre-fix, passes post-fix" in-process
# (see gate-priority-starvation-ceiling.selftest.sh's header for why that is a
# vacuous comparison at any committed state). That proof is done externally
# and safely by quality-gate-guard.sh's Step 5b-pre2 base-test harness, which
# materializes this file onto a genuine throwaway base-commit worktree and
# confirms at least one case fails there.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

echo "== gate-fresh-slot-reserve.selftest (ga-vm428) =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

# ═══════════════════════════════════════════════════════════════════════════
# Part A — the PURE sweep-counter decision, mirrored (no IO, set -e safe).
# echo "reserve" iff sweeps_since_last >= window-1 (i.e. this is at latest the
# Nth sweep of the window); else "hold". window<=0 (or malformed) disables the
# feature entirely (falls back to "hold" forever — today's behaviour).
# ═══════════════════════════════════════════════════════════════════════════
gate_fresh_slot_should_reserve() {
  local sweeps_since_last="$1" window="$2"
  case "$sweeps_since_last" in ''|*[!0-9]*) sweeps_since_last=0 ;; esac
  case "$window" in ''|*[!0-9]*) window=10 ;; esac
  [ "$window" -le 0 ] && { echo "hold"; return 0; }
  if [ "$sweeps_since_last" -ge "$((window - 1))" ]; then echo "reserve"; else echo "hold"; fi
}

echo "── A. pure reserve/hold decision (window=10 unless noted) ──"
eq "count=0 → hold"                 "$(gate_fresh_slot_should_reserve 0 10)"     "hold"
eq "count=8 → hold (below window-1)" "$(gate_fresh_slot_should_reserve 8 10)"    "hold"
eq "count=9 → reserve (== window-1)" "$(gate_fresh_slot_should_reserve 9 10)"    "reserve"
eq "count=20 → reserve (well past)"  "$(gate_fresh_slot_should_reserve 20 10)"   "reserve"
eq "junk count → treated as 0 → hold" "$(gate_fresh_slot_should_reserve x 10)"   "hold"
eq "junk window → defaults to 10, count=9 → reserve" "$(gate_fresh_slot_should_reserve 9 xyz)" "reserve"
eq "window=0 disables feature → hold even at count=999" "$(gate_fresh_slot_should_reserve 999 0)" "hold"
eq "negative/junk window → treated as default 10"        "$(gate_fresh_slot_should_reserve 9 -3)" "reserve"

echo "── A2. full sweep lifecycle: counter climbs, reserves at window, resets ──"
c=0; reserved_at=0; sweep=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sweep=$((sweep+1))
  if [ "$(gate_fresh_slot_should_reserve "$c" 10)" = "reserve" ]; then
    reserved_at=$sweep
    c=0
    break
  fi
  c=$((c+1))
done
eq "reservation fires on sweep 10 of a 10-window (first cold-start cycle)" "$reserved_at" "10"
eq "counter resets to 0 after the reservation fires" "$c" "0"

# ═══════════════════════════════════════════════════════════════════════════
# Part B — end-to-end: extract the LIVE marker-select block, prove selection.
# ═══════════════════════════════════════════════════════════════════════════
extract_block() {
  sed -n '/# SELFTEST-EXTRACT marker-select: BEGIN/,/# SELFTEST-EXTRACT marker-select: END/p' "$1"
}

SELECT_BLOCK="$(extract_block "$DISPATCHER")"
if [ -z "$SELECT_BLOCK" ]; then
  echo "FATAL: could not extract marker-select block (sentinels missing?)" >&2
  exit 2
fi
ok "located live marker-select block via sentinel extraction"

# mk <id> <created_at_iso> [author] [extra-labels-csv] — identical builder to
# gate-priority-starvation-ceiling.selftest.sh / gate-author-priority.selftest.sh.
mk() {
  local id="$1" ts="$2" author="${3:-}" labels="${4:-}"
  local labarr='["gate-status:queued"]'
  [ -n "$labels" ] && labarr="$(printf '%s' "$labels" | jq -R 'split(",")')"
  local desc="branch: crew/${author:-unknown}/${id}"
  jq -cn --arg id "$id" --arg ts "$ts" --arg desc "$desc" --argjson labels "$labarr" \
    '{id:$id, created_at:$ts, description:$desc, labels:$labels}'
}

# select_marker: args $1=block $2=MARKERS_JSON $3=now_epoch $4=age_threshold
# $5=hard_threshold $6=priority_authors $7=fresh_slot_due (true/false/unset)
select_marker() {
  local block="$1" markers_json="$2" now_epoch="$3" age_threshold="${4:-1800}" \
        hard_threshold="${5:-5400}" prio="${6-oracle}" fresh_due="${7:-false}"
  MARKERS_JSON="$markers_json" \
  GATE_MARKER_NOW_OVERRIDE_EPOCH="$now_epoch" \
  GATE_MARKER_AGE_PROMOTE_SECONDS="$age_threshold" \
  GATE_MARKER_HARD_AGE_SECONDS="$hard_threshold" \
  GATE_PRIORITY_AUTHORS="$prio" \
  GATE_FRESH_SLOT_DUE="$fresh_due" \
  bash -c "$block"$'\necho "$MARKER_ID"' 2>/dev/null
}

NOW_EPOCH=1782863814
THRESH=1800   # 30min, matches GATE_MARKER_AGE_PROMOTE_SECONDS default
HARD=5400     # 90min, matches GATE_MARKER_HARD_AGE_SECONDS default (3x THRESH)
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
ago() { iso "$((NOW_EPOCH - $1))"; }

echo "── B1. THE BUG, reproduced: sustained backlog (every marker aged) — not due → pure FIFO (oldest wins) ──"
FIX=$(printf '[%s,%s,%s]' \
  "$(mk oldest   "$(ago 5000)" mila)" \
  "$(mk mid      "$(ago 2500)" mila)" \
  "$(mk freshest "$(ago 1850)" mila)")
SEL=$(select_marker "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "oracle" "false")
[ "$SEL" = "oldest" ] && ok "not due: oldest-of-the-aged wins (FIFO), freshest (1850s) gets zero fast-lane benefit — the bug" \
  || bad "expected oldest, got '$SEL'"

echo "── B2. THE FIX: same sustained-backlog shape, reservation due → freshest wins regardless of age rank ──"
SEL=$(select_marker "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "oracle" "true")
[ "$SEL" = "freshest" ] && ok "due=true: freshest (1850s, still 'aged' by the flat threshold) wins the reserved slot" \
  || bad "expected freshest, got '$SEL' — reserved fresh slot did not fire"

echo "── B3. reserve tier is PRIORITY-BLIND: freshest non-priority beats an aged priority marker when due ──"
FIX3=$(printf '[%s,%s]' \
  "$(mk prio_aged     "$(ago 4000)" oracle)" \
  "$(mk fresh_nonprio "$(ago 1850)" mila)")
SEL=$(select_marker "$SELECT_BLOCK" "$FIX3" "$NOW_EPOCH" "$THRESH" "$HARD" "oracle" "false")
[ "$SEL" = "prio_aged" ] && ok "not due: priority-aged tier wins as before (unaffected baseline)" \
  || bad "expected prio_aged, got '$SEL'"
SEL=$(select_marker "$SELECT_BLOCK" "$FIX3" "$NOW_EPOCH" "$THRESH" "$HARD" "oracle" "true")
[ "$SEL" = "fresh_nonprio" ] && ok "due=true: globally-freshest non-priority marker wins over an aged priority one — reserve tier ignores priority class" \
  || bad "expected fresh_nonprio, got '$SEL' — reserve tier is not priority-blind"

echo "── B4. ga-q3ig2 guarantee holds for the NEW tier too: reserve never rescues a rebase-fail marker ──"
FIX4=$(printf '[%s,%s,%s]' \
  "$(mk broken       "$(ago 50)"   mila 'gate-status:queued,gate:exiled-tier5:2')" \
  "$(mk oldest_ok     "$(ago 5000)" mila)" \
  "$(mk newest_ok     "$(ago 1850)" mila)")
SEL=$(select_marker "$SELECT_BLOCK" "$FIX4" "$NOW_EPOCH" "$THRESH" "$HARD" "oracle" "false")
[ "$SEL" = "oldest_ok" ] && ok "not due: broken marker sinks to the back as always; oldest healthy wins FIFO" \
  || bad "expected oldest_ok, got '$SEL'"
SEL=$(select_marker "$SELECT_BLOCK" "$FIX4" "$NOW_EPOCH" "$THRESH" "$HARD" "oracle" "true")
[ "$SEL" = "newest_ok" ] && ok "due=true: freshest HEALTHY marker wins even though 'broken' is objectively the most recently created — rebase-fail correctly excluded" \
  || bad "expected newest_ok, got '$SEL' — reserve tier rescued a rebase-fail marker (ga-q3ig2 regression)"

echo "── B5. overdue-emergency ceiling still wins even when the reservation is due — never pre-empted ──"
FIX5=$(printf '[%s,%s]' \
  "$(mk overdue "$(ago 5500)" mila)" \
  "$(mk fresh   "$(ago 60)"   mila)")
SEL=$(select_marker "$SELECT_BLOCK" "$FIX5" "$NOW_EPOCH" "$THRESH" "$HARD" "oracle" "true")
[ "$SEL" = "overdue" ] && ok "due=true: overdue (5500s > ${HARD}s hard ceiling) still wins over fresh — tier1 outranks the reserve tier" \
  || bad "expected overdue, got '$SEL' — reserved fresh slot pre-empted the stronger hard-ceiling guarantee"

echo "── B6. NOT reversed: gate-author-priority case 2 (fresh priority beats aged non-priority) — both due states ──"
FIX6=$(printf '[%s,%s]' \
  "$(mk orc "$(ago 60)"   oracle)" \
  "$(mk oth "$(ago 3600)" thies)")
SEL=$(select_marker "$SELECT_BLOCK" "$FIX6" "$NOW_EPOCH" "$THRESH" "$HARD" "oracle" "false")
[ "$SEL" = "orc" ] && ok "not due: fresh oracle still beats aged non-oracle — policy intact" \
  || bad "expected orc, got '$SEL'"
SEL=$(select_marker "$SELECT_BLOCK" "$FIX6" "$NOW_EPOCH" "$THRESH" "$HARD" "oracle" "true")
[ "$SEL" = "orc" ] && ok "due=true: same winner (orc is already the global-freshest) — reserve tier agrees with the natural winner" \
  || bad "expected orc, got '$SEL'"

echo "── B7. strict-mode safety: unset/malformed GATE_FRESH_SLOT_DUE must not crash the sweep ──"
FIX7=$(printf '[%s,%s]' "$(mk h1 "$(ago 600)" mila)" "$(mk h2 "$(ago 60)" mila)")
SEL=$(MARKERS_JSON="$FIX7" GATE_MARKER_NOW_OVERRIDE_EPOCH="$NOW_EPOCH" \
  GATE_MARKER_AGE_PROMOTE_SECONDS="$THRESH" GATE_MARKER_HARD_AGE_SECONDS="$HARD" \
  GATE_PRIORITY_AUTHORS="oracle" \
  bash -c "set -euo pipefail; $SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null)
STATUS=$?
if [ "$STATUS" = "0" ] && [ "$SEL" = "h2" ]; then
  ok "GATE_FRESH_SLOT_DUE entirely unset defaults to false-equivalent, no crash (exit=$STATUS, selected=$SEL)"
else
  bad "unset GATE_FRESH_SLOT_DUE broke selection (exit=$STATUS, selected='$SEL')"
fi
SEL=$(select_marker "$SELECT_BLOCK" "$FIX7" "$NOW_EPOCH" "$THRESH" "$HARD" "oracle" "not-a-bool")
STATUS=$?
if [ "$STATUS" = "0" ] && [ "$SEL" = "h2" ]; then
  ok "malformed GATE_FRESH_SLOT_DUE falls back to false instead of crashing jq's --argjson (exit=$STATUS, selected=$SEL)"
else
  bad "malformed GATE_FRESH_SLOT_DUE broke selection (exit=$STATUS, selected='$SEL') — needs the same case-guard as sibling GATE_* tunables"
fi

echo "── B8. drift-guards: shipped dispatcher matches tested logic ──"
has "$DISPATCHER" 'gate_fresh_slot_should_reserve'   "pure reserve/hold decision present"
has "$DISPATCHER" 'GATE_FRESH_SLOT_WINDOW_SWEEPS'    "bounded-window tunable configured"
has "$DISPATCHER" 'GATE_FRESH_SLOT_COUNT_FILE'       "persistent sweep counter wired"
has "$DISPATCHER" 'reserve_fresh'                    "reserve_fresh seam threaded into the jq selection"
OVERDUE_LINE=$(grep -n 'map(select(is_overdue' "$DISPATCHER" | head -1 | cut -d: -f1)
RESERVE_LINE=$(grep -n 'reserve_fresh then' "$DISPATCHER" | head -1 | cut -d: -f1)
PRIO_AGED_LINE=$(grep -n 'is_aged))' "$DISPATCHER" | grep -v 'is_aged | not' | head -1 | cut -d: -f1)
BROKEN_LINE=$(grep -n 'map(select(has_rebase_fail))' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$OVERDUE_LINE" ] && [ -n "$RESERVE_LINE" ] && [ -n "$PRIO_AGED_LINE" ] && [ -n "$BROKEN_LINE" ] \
   && [ "$OVERDUE_LINE" -lt "$RESERVE_LINE" ] && [ "$RESERVE_LINE" -lt "$PRIO_AGED_LINE" ] && [ "$PRIO_AGED_LINE" -lt "$BROKEN_LINE" ]; then
  ok "tier order fixed: overdue-ceiling, then reserve-fresh-slot, then priority/aged cascade, then rebase-fail"
else
  bad "tier order drifted (overdue=$OVERDUE_LINE reserve=$RESERVE_LINE prio-aged=$PRIO_AGED_LINE broken=$BROKEN_LINE) — re-check concat order"
fi

echo ""
echo "== gate-fresh-slot-reserve: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
