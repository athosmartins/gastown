#!/usr/bin/env bash
# gate-pilot-crossstore-close.selftest.sh (ga-qw7y6)
#
# Proves the cross-store close fix + Pilot phantom-re-dispatch defense.
#
# ROOT BUG: an HQ-resident `ga-` source bead whose work is built on a RIG branch
# (e.g. an HQ painel story built on whatsapp_automation's crew branch) gets
# MERGED + marker PASSED, but the gate's close targets the RIG store
# (BEAD_CITY="${RIG_PATH:-$GC_CITY}") — the HQ bead is not there, so the close
# silently no-ops, the source bead stays OPEN, and Pilot phantom-re-dispatches
# already-merged work (ga-8tv0s re-dispatched 3×: a direct slot/cycle leak).
#
# Covers:
#   A. resolve_bead_city (quality-gate-dispatcher.sh) — probes the store that
#      ACTUALLY owns the bead, with a bead-id prefix fallback:
#        (1) HQ ga- bead in rig=wa context           → HQ store   (THE FIX)
#        (2) rig-native wa- bead (wa-re77 preserved)  → rig store
#        (3) empty bead-id                            → HQ store
#        (4) unknown ga- bead (neither store resolves) → HQ via prefix fallback
#        (5) unknown wa- bead (neither store resolves) → rig via prefix fallback
#   B. _filter_gated / _build_gated_set (pilot-dispatcher.sh) — defense-in-depth:
#        (6) a candidate with a terminal-success gate marker is DROPPED
#        (7) a candidate without one is KEPT
#        (8) empty gated-set → input returned unchanged (fail-open)
#   C. Drift-guards: the live sources still carry the fix (cannot silently revert).
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_SRC="$SELF_DIR/quality-gate-dispatcher.sh"
# HQ assets → .../packs/town-deltas/assets ; pilot lives in the TOWN-ROOT packs.
# SELF_DIR = <root>/.gascity-gastown-hq/packs/town-deltas/assets → up 4 = <root>.
PILOT_SRC="$SELF_DIR/../../../../packs/town-deltas/assets/pilot-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

# ── Replicated resolver (mirrors quality-gate-dispatcher.sh resolve_bead_city) ──
# Stubbed `bd`: HQ store owns ga-qw7y6; rig store owns wa-7nq. A not-found probe
# returns the real bd shape ({"error":...} → no .status) so the guard skips it.
GC_CITY="/fake/hq"
RIG_PATH="/fake/rig/wa"
bd() {
  # parse: bd -C <store> show <bead> --json
  local store="" bead=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) store="$2"; shift 2 ;;
      show) bead="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$store/$bead" in
    "$GC_CITY/ga-qw7y6")  echo '{"id":"ga-qw7y6","status":"in_progress"}' ;;
    "$RIG_PATH/wa-7nq")   echo '{"id":"wa-7nq","status":"open"}' ;;
    *) echo '{"error":"no issues found matching the provided IDs","schema_version":1}' ;;
  esac
}
log() { :; }

resolve_bead_city() {
  local bead="$1" store st
  [ -z "$bead" ] && { echo "$GC_CITY"; return 0; }
  for store in "${RIG_PATH:-}" "$GC_CITY"; do
    [ -z "$store" ] && continue
    st=$(bd -C "$store" show "$bead" --json 2>/dev/null \
      | jq -r 'if type=="array" then (.[0] // {}) else . end | .status // empty' 2>/dev/null)
    if [ -n "$st" ]; then echo "$store"; return 0; fi
  done
  case "$bead" in
    ga-*) echo "$GC_CITY" ;;
    *)    echo "${RIG_PATH:-$GC_CITY}" ;;
  esac
}

echo "A. resolve_bead_city (cross-store close):"
r=$(resolve_bead_city "ga-qw7y6")
[ "$r" = "$GC_CITY" ] && ok "HQ ga- bead in rig context → HQ store (THE FIX)" \
  || bad "HQ ga- bead → expected $GC_CITY, got $r"
r=$(resolve_bead_city "wa-7nq")
[ "$r" = "$RIG_PATH" ] && ok "rig-native wa- bead → rig store (wa-re77 preserved)" \
  || bad "rig-native bead → expected $RIG_PATH, got $r"
r=$(resolve_bead_city "")
[ "$r" = "$GC_CITY" ] && ok "empty bead-id → HQ store" \
  || bad "empty bead-id → expected $GC_CITY, got $r"
r=$(resolve_bead_city "ga-unknown999")
[ "$r" = "$GC_CITY" ] && ok "unknown ga- bead → HQ via prefix fallback" \
  || bad "unknown ga- → expected $GC_CITY, got $r"
r=$(resolve_bead_city "wa-unknown999")
[ "$r" = "$RIG_PATH" ] && ok "unknown wa- bead → rig via prefix fallback" \
  || bad "unknown wa- → expected $RIG_PATH, got $r"

# ── Replicated Pilot filter (mirrors pilot-dispatcher.sh _filter_gated) ─────────
warn() { :; }
GATED_BEADS=""
_filter_gated() {
  local arr; arr=$(cat)
  [ -z "$GATED_BEADS" ] && { printf '%s' "$arr"; return 0; }
  local gated_json before after filtered
  gated_json=$(printf '%s\n' "$GATED_BEADS" \
    | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo "[]")
  before=$(printf '%s' "$arr" | jq 'length' 2>/dev/null || echo 0)
  filtered=$(printf '%s' "$arr" | jq --argjson g "$gated_json" \
    '[.[] | select((.id as $i | $g | index($i)) | not)]' 2>/dev/null) \
    || { printf '%s' "$arr"; return 0; }
  [ -z "$filtered" ] && { printf '%s' "$arr"; return 0; }
  after=$(printf '%s' "$filtered" | jq 'length' 2>/dev/null || echo 0)
  printf '%s' "$filtered"
}

echo "B. _filter_gated (phantom re-dispatch defense):"
GATED_BEADS=$(printf 'ga-8tv0s\nga-7s0or\n')
out=$(echo '[{"id":"ga-8tv0s"},{"id":"ga-FRESH1"}]' | _filter_gated | jq -c '[.[].id]' 2>/dev/null)
[ "$out" = '["ga-FRESH1"]' ] && ok "gated bead dropped, fresh bead kept ($out)" \
  || bad "filter result wrong: got $out (expected [\"ga-FRESH1\"])"
out=$(echo '[{"id":"ga-FRESH1"},{"id":"ga-FRESH2"}]' | _filter_gated | jq -c '[.[].id]' 2>/dev/null)
[ "$out" = '["ga-FRESH1","ga-FRESH2"]' ] && ok "no gated beads → all kept" \
  || bad "non-gated filter dropped something: $out"
GATED_BEADS=""
out=$(echo '[{"id":"ga-8tv0s"}]' | _filter_gated | jq -c '[.[].id]' 2>/dev/null)
[ "$out" = '["ga-8tv0s"]' ] && ok "empty gated-set → input unchanged (fail-open)" \
  || bad "fail-open broken: $out"

# ── C. Drift-guards on the live sources ────────────────────────────────────────
echo "C. Drift-guards (live source still carries the fix):"
if [ -f "$GATE_SRC" ]; then
  grep -q 'resolve_bead_city()' "$GATE_SRC" \
    && ok "gate: resolve_bead_city() defined" \
    || bad "gate: resolve_bead_city() MISSING"
  grep -q 'BEAD_CITY="\$(resolve_bead_city "\$BEAD_ID")"' "$GATE_SRC" \
    && ok "gate: BEAD_CITY assigned via resolver (not bare RIG_PATH)" \
    || bad "gate: BEAD_CITY no longer assigned via resolve_bead_city — REVERTED?"
else
  bad "gate source not found at $GATE_SRC"
fi
if [ -f "$PILOT_SRC" ]; then
  grep -q '_build_gated_set()' "$PILOT_SRC" \
    && ok "pilot: _build_gated_set() defined" || bad "pilot: _build_gated_set() MISSING"
  grep -q '_filter_gated()' "$PILOT_SRC" \
    && ok "pilot: _filter_gated() defined" || bad "pilot: _filter_gated() MISSING"
  grep -q '^_build_gated_set$' "$PILOT_SRC" \
    && ok "pilot: _build_gated_set invoked once per sweep" \
    || bad "pilot: _build_gated_set never invoked"
  # At least the Tier-1 bug pipeline must chain the filter.
  grep -q '_filter_candidates | _filter_gated' "$PILOT_SRC" \
    && ok "pilot: _filter_gated chained in candidate pipeline" \
    || bad "pilot: _filter_gated NOT chained — defense inactive"
else
  bad "pilot source not found at $PILOT_SRC"
fi

echo ""
echo "── ga-qw7y6 selftest: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
