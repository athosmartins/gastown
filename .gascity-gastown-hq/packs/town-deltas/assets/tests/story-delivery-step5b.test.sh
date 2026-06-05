#!/usr/bin/env bash
# story-delivery-step5b.test.sh — integration test for the daemon-refresh WIRING
# in story-delivery.sh (ga-iwv0). Extracts the real Step 5b block from
# story-delivery.sh (no duplication) and drives it with stubbed bd/gc and a fake
# daemon-refresh helper, proving:
#   - a passing refresh (VERDICT=OK) lets delivery proceed (no delivery:failed);
#   - a NEEDS_GUARDED_RESTART halts delivery: delivery:failed added,
#     delivery:running removed, author+mayor nudged, exit non-zero, NO story:done.
#
# This covers the bead-mutation / escalation wiring that the daemon-refresh unit
# tests deliberately do not touch.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the Step 5b block (from its header up to, but excluding, Step 6).
BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }

run_block() {  # run_block <fake-verdict>   → echoes nothing; sets globals via files
  local verdict="$1"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"
  mkdir -p "$GC_CITY/packs/town-deltas/assets"
  # fake daemon-refresh helper emitting the requested verdict
  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<EOF
echo "VERDICT=$verdict"
echo "AFFECTED=com.test.central-sender"
echo "RESTARTED="
echo "FRESH_FAIL="
echo "GUARDED=com.test.central-sender"
echo "REASON=test reason for $verdict"
exit \$([ "$verdict" = OK ] && echo 0 || echo 1)
EOF
  # bd / gc stubs record their invocations
  BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"
  bd() { echo "bd $*" >> "$BD_LOG"; }
  gc() { echo "gc $*" >> "$GC_LOG"; }
  log() { :; }; warn() { :; }; err() { :; }
  export -f bd gc 2>/dev/null || true
  # variables the block reads
  local RIG="whatsapp_automation"
  local RUNTIME_DIR="/tmp/some-rig-runtime"   # non-empty, != GC_CITY
  local PRE_DEPLOY_SHA="aaa" POST_DEPLOY_SHA="bbb" DEPLOY_EPOCH=1
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  get_runbook_field() { echo "central-sender"; }

  # Run the real block in a subshell; capture its exit code.
  ( eval "$BLOCK" ) >/dev/null 2>&1
  RUN_RC=$?
  LAST_BD="$(cat "$BD_LOG" 2>/dev/null || true)"
  LAST_GC="$(cat "$GC_LOG" 2>/dev/null || true)"
  rm -rf "$T"
}

# C1: VERDICT=OK → proceed, no delivery:failed, exit 0
run_block OK
[ "$RUN_RC" -eq 0 ] && ok "C1 OK verdict → block exits 0 (proceeds)" || nok "C1 exit" "rc=$RUN_RC"
! echo "$LAST_BD" | grep -q "delivery:failed" && ok "C1 no delivery:failed label" || nok "C1 failed-label" "$LAST_BD"

# C2: NEEDS_GUARDED_RESTART → halt
run_block NEEDS_GUARDED_RESTART
[ "$RUN_RC" -ne 0 ] && ok "C2 guarded verdict → block exits non-zero (halts)" || nok "C2 exit" "rc=$RUN_RC"
echo "$LAST_BD" | grep -q "label add ga-test delivery:failed" && ok "C2 delivery:failed added" || nok "C2 failed-label" "$LAST_BD"
echo "$LAST_BD" | grep -q "label remove ga-test delivery:running" && ok "C2 delivery:running removed" || nok "C2 running-removed" "$LAST_BD"
! echo "$LAST_BD" | grep -q "label add ga-test story:done" && ok "C2 story:done label NOT set" || nok "C2 story-done" "$LAST_BD"
echo "$LAST_GC" | grep -q "session nudge mayor" && ok "C2 mayor nudged" || nok "C2 mayor-nudge" "$LAST_GC"
echo "$LAST_GC" | grep -q "session nudge crew/tester" && ok "C2 author nudged" || nok "C2 author-nudge" "$LAST_GC"

echo ""
echo "story-delivery step5b wiring tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
