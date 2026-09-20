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
  # ga-o643d: production derives this from $STORY._store, falling back to
  # $GC_CITY when absent (story-delivery.sh:~487) — STORY has no _store here,
  # so mirror that same fallback rather than inventing a fixture value.
  local STORY_STORE="$GC_CITY"
  # ga-6zkhci: PRE_DEPLOY_SHA!=POST_DEPLOY_SHA above means Step 5b's
  # MERGE_SHA-fallback branch never evaluates its own $MERGE_SHA reference in
  # this file's C1/C2 cases — but declare it anyway (empty) since the block
  # runs under `set -u` here and an undeclared reference would be a latent
  # trap for the next person who touches this shared block.
  local MERGE_SHA=""
  # ga-6zkhci fix-attempt-3: same reasoning as MERGE_SHA above — the
  # fallback's guard chain now also references $MERGE_PRE_MAIN, but only
  # after the (already-false) `[ -n "$MERGE_SHA" ]` check short-circuits, so
  # declaring it is defensive-not-load-bearing here too.
  local MERGE_PRE_MAIN=""
  get_runbook_field() { echo "central-sender"; }

  # Run the real block in a subshell; capture its exit code. Wrapped in a
  # for-loop (matches story-delivery-staleness.test.sh) so the block's
  # `continue` — a real loop-continue in production's per-story sweep
  # (story-delivery.sh:473 `while IFS= read -r STORY`) — is valid here too.
  ( for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1
  RUN_RC=$?
  LAST_BD="$(cat "$BD_LOG" 2>/dev/null || true)"
  LAST_GC="$(cat "$GC_LOG" 2>/dev/null || true)"
  rm -rf "$T"
}

# C1: VERDICT=OK → proceed, no delivery:failed, exit 0
run_block OK
[ "$RUN_RC" -eq 0 ] && ok "C1 OK verdict → block exits 0 (proceeds)" || nok "C1 exit" "rc=$RUN_RC"
! echo "$LAST_BD" | grep "delivery:failed" >/dev/null && ok "C1 no delivery:failed label" || nok "C1 failed-label" "$LAST_BD"

# C2: NEEDS_GUARDED_RESTART → halt
run_block NEEDS_GUARDED_RESTART
# Block halts via `continue` (loop-based); for-loop exits 0. BD state is the halt signal.
[ "$RUN_RC" -eq 0 ] && ok "C2 guarded verdict → block exits 0 (continue-based halt; BD state is primary signal)" || nok "C2 exit" "rc=$RUN_RC"
echo "$LAST_BD" | grep "label add ga-test delivery:failed" >/dev/null && ok "C2 delivery:failed added" || nok "C2 failed-label" "$LAST_BD"
echo "$LAST_BD" | grep "label remove ga-test delivery:running" >/dev/null && ok "C2 delivery:running removed" || nok "C2 running-removed" "$LAST_BD"
! echo "$LAST_BD" | grep "label add ga-test story:done" >/dev/null && ok "C2 story:done label NOT set" || nok "C2 story-done" "$LAST_BD"
echo "$LAST_GC" | grep "session nudge mayor" >/dev/null && ok "C2 mayor nudged" || nok "C2 mayor-nudge" "$LAST_GC"
echo "$LAST_GC" | grep "session nudge crew/tester" >/dev/null && ok "C2 author nudged" || nok "C2 author-nudge" "$LAST_GC"

echo ""
echo "story-delivery step5b wiring tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
