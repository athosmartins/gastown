#!/usr/bin/env bash
# gate-author-priority.selftest.sh (ga-*, 2026-07-15)
#
# Proves the AUTHOR-PRIORITY tier in the live marker-selection block
# (quality-gate-dispatcher.sh, SELFTEST-EXTRACT sentinel "marker-select"):
# markers whose `author:` (parsed from the marker DESCRIPTION) is in
# GATE_PRIORITY_AUTHORS — or which carry the gate:priority label — drain BEFORE
# every non-priority healthy marker, WITHOUT losing any prior invariant:
#   • aged-promotion + newest-first tiebreak still hold WITHIN each priority class
#   • rebase-fail markers stay at the BACK even when their author is prioritized
#     (a broken branch must never jump the queue and re-break it — ga-q3ig2)
#   • GATE_PRIORITY_AUTHORS="" collapses to the exact prior ordering
#   • a description-less marker is STILL selectable (regression guard: the author
#     parse must always yield one value — an empty stream from `capture` silently
#     dropped such markers from every tier → the whole sweep selected null).
#
# Strategy mirrors gate-marker-age-promote.selftest.sh: extract the LIVE block via
# its sentinels (never a hand-copied jq) and run it under the host bash with
# MARKERS_JSON + the NOW/AGE/PRIORITY_AUTHORS test seams set.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-author-priority.selftest =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

SELECT_BLOCK="$(sed -n '/# SELFTEST-EXTRACT marker-select: BEGIN/,/# SELFTEST-EXTRACT marker-select: END/p' "$DISPATCHER")"
if [ -z "$SELECT_BLOCK" ]; then
  echo "FATAL: could not extract marker-select block (sentinels missing?)" >&2
  exit 2
fi
ok "located live marker-select block via sentinel extraction"

# mk <id> <created_at_iso> <author> [labels-csv]
# Builds a marker with an `author:` line in its description (the field the tier
# keys on). Empty <author> → NO author line at all (description-less-ish case).
mk() {
  local id="$1" ts="$2" author="$3" labels="${4:-}"
  local labarr='["gate-status:queued"]'
  [ -n "$labels" ] && labarr="$(printf '%s' "$labels" | jq -R 'split(",")')"
  local desc="branch: crew/${author:-unknown}/${id}"
  [ -n "$author" ] && desc="$desc
author: $author"
  jq -cn --arg id "$id" --arg ts "$ts" --arg desc "$desc" --argjson labels "$labarr" \
    '{id:$id, created_at:$ts, description:$desc, labels:$labels}'
}

select_marker() {
  # args: $1=MARKERS_JSON  $2=now_epoch  $3=age_threshold  $4=priority_authors
  local markers_json="$1" now_epoch="$2" age_threshold="${3:-1800}" prio="${4-oracle}"
  MARKERS_JSON="$markers_json" \
  GATE_MARKER_NOW_OVERRIDE_EPOCH="$now_epoch" \
  GATE_MARKER_AGE_PROMOTE_SECONDS="$age_threshold" \
  GATE_PRIORITY_AUTHORS="$prio" \
  bash -c "$SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null
}

NOW_EPOCH=1782863814
THRESH=1800
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
ago() { iso "$((NOW_EPOCH - $1))"; }

echo "── (1) oracle marker wins over a NEWER non-oracle healthy marker ──"
FIX=$(printf '[%s,%s]' \
  "$(mk orc "$(ago 600)" oracle)" \
  "$(mk oth "$(ago 60)"  mila)")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH" "oracle")
[ "$SEL" = "orc" ] && ok "oracle (10m old) beats newer non-oracle oth (1m old) — priority tier active" \
  || bad "expected orc, got '$SEL' — author-priority tier not applied"

echo "── (2) oracle beats an AGED non-oracle marker (priority outranks age-promotion) ──"
FIX=$(printf '[%s,%s]' \
  "$(mk orc "$(ago 60)"   oracle)" \
  "$(mk oth "$(ago 3600)" thies)")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH" "oracle")
[ "$SEL" = "orc" ] && ok "fresh oracle beats aged non-oracle (priority tier sits above the age tier)" \
  || bad "expected orc, got '$SEL' — priority did not outrank a starved non-oracle marker"

echo "── (3) within oracle's own markers, aged-promotion still holds (oldest aged wins) ──"
FIX=$(printf '[%s,%s]' \
  "$(mk orcaged "$(ago 2400)" oracle)" \
  "$(mk orcnew  "$(ago 60)"   oracle)")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH" "oracle")
[ "$SEL" = "orcaged" ] && ok "aged oracle (2400s) promoted ahead of fresh oracle — age bound preserved in-tier" \
  || bad "expected orcaged, got '$SEL' — aging broken inside the priority tier"

echo "── (4) oracle REBASE-FAIL marker must NOT jump a healthy non-oracle marker (ga-q3ig2) ──"
FIX=$(printf '[%s,%s]' \
  "$(mk orcbroken "$(ago 3600)" oracle "gate-status:queued,gate:rebase-attempt:2")" \
  "$(mk othok     "$(ago 60)"   mila)")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH" "oracle")
[ "$SEL" = "othok" ] && ok "oracle's rebase-fail marker sinks to the back; healthy non-oracle wins (broken branch can't travar the queue)" \
  || bad "expected othok, got '$SEL' — a conflicted priority marker jumped the queue (ga-q3ig2 regression)"

echo "── (5) gate:priority LABEL overrides author (non-oracle marker with the label wins) ──"
FIX=$(printf '[%s,%s]' \
  "$(mk labeled "$(ago 600)" wa-worker "gate-status:queued,gate:priority")" \
  "$(mk plain   "$(ago 60)"  mila)")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH" "oracle")
[ "$SEL" = "labeled" ] && ok "gate:priority label promotes a non-oracle marker over a newer plain one" \
  || bad "expected labeled, got '$SEL' — the manual label override does not work"

echo "── (6) GATE_PRIORITY_AUTHORS=\"\" disables the author tier (old ordering returns) ──"
FIX=$(printf '[%s,%s]' \
  "$(mk orc "$(ago 600)" oracle)" \
  "$(mk oth "$(ago 60)"  mila)")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH" "")
[ "$SEL" = "oth" ] && ok "disabled: newest-first tiebreak returns (oth wins) — reversible, no author tier" \
  || bad "expected oth, got '$SEL' — disabling GATE_PRIORITY_AUTHORS did not restore prior behaviour"

echo "── (7) regression: a DESCRIPTION-LESS marker is still selectable (scan must yield '' not empty) ──"
NODESC='[{"id":"nd1","created_at":"'"$(ago 600)"'","labels":["gate-status:queued"]},{"id":"nd2","created_at":"'"$(ago 60)"'","labels":["gate-status:queued"]}]'
SEL=$(select_marker "$NODESC" "$NOW_EPOCH" "$THRESH" "oracle")
[ "$SEL" = "nd2" ] && ok "description-less markers still select (nd2 newest) — author parse yields '' not an empty stream" \
  || bad "expected nd2, got '$SEL' — description-less marker vanished (the capture-empty-stream bug)"

echo ""
echo "== gate-author-priority: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
