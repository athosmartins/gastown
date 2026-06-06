#!/usr/bin/env bash
# story-delivery-task-reconciler.test.sh — regression test for the gate:passed
# task/bug reconciler (Step 1b, ga-tjqe) in story-delivery.sh.
#
# Extracts the real Step 1b block from story-delivery.sh (no duplication) and
# drives it with stubbed bd/log/warn to prove:
#   T1 TASK_WITH_GATE_PASSED  — open/in_progress task bead with gate:passed and
#                               no story:approved → bd close called, TASK_COUNT=1.
#   T2 STORY_EXCLUDED         — bead with gate:passed AND story:approved (a story
#                               awaiting delivery) → NOT closed, TASK_COUNT=0.
#   T3 DONE_EXCLUDED          — bead with gate:passed AND story:done but no
#                               story:approved → NOT closed, TASK_COUNT=0.
#   T4 NO_TASK_BEADS          — bd list returns [] → TASK_COUNT=0, no bd close.
#   T5 DRY_RUN_SKIPS_CLOSE    — DRY_RUN=1 with a task bead → bd close NOT called.
#   T6 FORCE_ID_SKIPS_BLOCK   — FORCE_STORY_ID set → reconciler skips entirely.
#
# This is the ga-tjqe acceptance test: "a regression test simulates a gate:passed
# task/bug bead and asserts delivery closes it in the same sweep".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the Step 1b block (from its header to the end-marker comment).
BLOCK="$(sed -n '/# ── Step 1b: Task\/bug reconciler/,/# ── End Step 1b/p' "$DELIVERY")"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 1b block"; exit 1; }

# ── Helper: run the block with a bd list stub that returns given JSON ──────────
# run_block <bd_list_json> [dry_run] [force_story_id]
#   bd_list_json: JSON array the bd-list stub will return.
#   dry_run: 0 or 1 (default 0).
#   force_story_id: non-empty to simulate FORCE_STORY_ID (default empty).
# Sets globals: RUN_TASK_COUNT, LAST_BD
run_block() {
  local bd_list_json="$1"
  local dry_run="${2:-0}"
  local force_id="${3:-}"
  local T; T="$(mktemp -d)"
  local BD_LOG="$T/bd.log"

  bd() {
    echo "bd $*" >> "$BD_LOG"
    # Intercept: bd ... list ... → return stubbed JSON
    local args_str="$*"
    case "$args_str" in
      *list*--json*)
        printf '%s' "$bd_list_json"
        ;;
    esac
  }
  log()  { :; }
  warn() { :; }
  err()  { :; }
  jq() {
    # Pass through to real jq — only stub what bd calls
    command jq "$@"
  }

  local GC_CITY="$T/city"
  local DELIVERY_LOG="$T/delivery.jsonl"
  local FORCE_STORY_ID="$force_id"
  local DRY_RUN="$dry_run"

  # Run block; capture TASK_COUNT (set inside block)
  local TASK_COUNT=0
  ( eval "$BLOCK"; echo "TASK_COUNT=$TASK_COUNT" ) > "$T/out.txt" 2>&1
  RUN_TASK_COUNT=$(grep '^TASK_COUNT=' "$T/out.txt" 2>/dev/null | tail -1 | sed 's/TASK_COUNT=//' || echo "0")
  LAST_BD="$(cat "$BD_LOG" 2>/dev/null || echo "")"

  unset -f bd log warn err jq
  rm -rf "$T"
}

# ── Stub JSON helpers ──────────────────────────────────────────────────────────
TASK_BEAD_JSON='[{"id":"ga-test-task","title":"fix cloudflared DNS reconciler","status":"in_progress","issue_type":"task","labels":["gate:passed","lane:small"]}]'
STORY_WITH_GATE_JSON='[{"id":"ga-test-story","title":"Add feature X","status":"open","issue_type":null,"labels":["gate:passed","story:approved"]}]'
DONE_WITH_GATE_JSON='[{"id":"ga-test-done","title":"Old fix","status":"in_progress","issue_type":"task","labels":["gate:passed","story:done"]}]'
EMPTY_JSON='[]'

# ── T1: Task bead with gate:passed → close called ─────────────────────────────
run_block "$TASK_BEAD_JSON" 0 ""
echo "$LAST_BD" | grep -q "close ga-test-task" && ok "T1 TASK_WITH_GATE_PASSED → bd close called" || nok "T1 bd-close missing" "$LAST_BD"
echo "$LAST_BD" | grep -q "comment ga-test-task" && ok "T1 comment added to task bead" || nok "T1 comment missing" "$LAST_BD"
# TASK_COUNT should be 1 (reconciler ran)
[ "${RUN_TASK_COUNT:-0}" = "1" ] && ok "T1 TASK_COUNT=1" || nok "T1 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

# ── T2: Story bead excluded (has story:approved) ──────────────────────────────
run_block "$STORY_WITH_GATE_JSON" 0 ""
! echo "$LAST_BD" | grep -q "close ga-test-story" && ok "T2 STORY_EXCLUDED → bd close NOT called" || nok "T2 story-closed" "$LAST_BD"
[ "${RUN_TASK_COUNT:-0}" = "0" ] && ok "T2 TASK_COUNT=0 (story filtered out)" || nok "T2 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

# ── T3: Bead with story:done excluded ─────────────────────────────────────────
run_block "$DONE_WITH_GATE_JSON" 0 ""
! echo "$LAST_BD" | grep -q "close ga-test-done" && ok "T3 DONE_EXCLUDED → bd close NOT called" || nok "T3 done-closed" "$LAST_BD"
[ "${RUN_TASK_COUNT:-0}" = "0" ] && ok "T3 TASK_COUNT=0 (story:done filtered out)" || nok "T3 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

# ── T4: No gate:passed task beads ─────────────────────────────────────────────
run_block "$EMPTY_JSON" 0 ""
! echo "$LAST_BD" | grep -q "close" && ok "T4 NO_TASK_BEADS → no bd close" || nok "T4 spurious-close" "$LAST_BD"
[ "${RUN_TASK_COUNT:-0}" = "0" ] && ok "T4 TASK_COUNT=0 (empty list)" || nok "T4 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

# ── T5: DRY_RUN=1 → bd close NOT called ──────────────────────────────────────
run_block "$TASK_BEAD_JSON" 1 ""
! echo "$LAST_BD" | grep -q "close ga-test-task" && ok "T5 DRY_RUN_SKIPS_CLOSE → bd close NOT called" || nok "T5 dry-run-closed" "$LAST_BD"
# TASK_COUNT should still be 1 (reconciler ran, found bead, but skipped close)
[ "${RUN_TASK_COUNT:-0}" = "1" ] && ok "T5 TASK_COUNT=1 (found bead in dry-run)" || nok "T5 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

# ── T6: FORCE_STORY_ID set → reconciler skipped entirely ─────────────────────
run_block "$TASK_BEAD_JSON" 0 "ga-some-story"
! echo "$LAST_BD" | grep -q "close" && ok "T6 FORCE_ID_SKIPS_BLOCK → no bd close (reconciler skipped)" || nok "T6 force-id-closed" "$LAST_BD"
[ "${RUN_TASK_COUNT:-0}" = "0" ] && ok "T6 TASK_COUNT=0 (FORCE_STORY_ID skips block)" || nok "T6 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

echo ""
echo "story-delivery task-reconciler tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
