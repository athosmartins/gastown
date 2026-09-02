#!/usr/bin/env bash
# story-delivery-no-deploy-cmd-retry.test.sh — regression test for the
# ga-aqqj0 "no deploy_cmd for rig" retry cap + escalate mechanism (Step 3),
# and its companion early-skip guard, in story-delivery.sh.
#
# Extracts the REAL blocks from story-delivery.sh (no duplication) and drives
# them with stubbed get_runbook_field/bd/gc/log/warn/err, to prove:
#   R1 FIRST_HALT — the FIRST "no deploy_cmd" halt for a story: bumps
#                   delivery:no-deploy-cmd-retry:1, comments once naming the
#                   attempt count, does NOT escalate (no -exhausted label,
#                   no Mayor mail).
#   R2 MID_RETRY  — a middle halt (already at retry:1, this is the 2nd):
#                   removes the stale delivery:no-deploy-cmd-retry:1 label,
#                   adds delivery:no-deploy-cmd-retry:2, still no escalation.
#   R3 CAP_TRIP   — the Nth halt (N = DELIVERY_NO_DEPLOY_CMD_MAX_RETRIES,
#                   i.e. already at retry:(N-1)): removes the stale
#                   retry-count label, adds delivery:no-deploy-cmd-exhausted
#                   + gate:needs-human, mails the Mayor, and does NOT add a
#                   fresh retry-count label (retrying stops here).
#   R4 HAPPY_PATH — DEPLOY_CMD resolves normally: none of the halt/retry
#                   machinery fires at all (no regression on the common,
#                   already-working case).
#   S1 SKIP_GUARD — a story already carrying delivery:no-deploy-cmd-exhausted
#                   is skipped by the early-skip guard (added right after the
#                   pre-existing "already in delivery" skip) — no bd/gc calls
#                   of any kind, the loop iteration just continues past it.
#
# This is the ga-aqqj0 acceptance-criterion-(b) test: "retentativa que falha
# pela MESMA razao N vezes para e escala em vez de comentar pra sempre."
# Before this fix, ga-dv2gk accumulated 18 identical "no deploy_cmd for rig
# 'origin'" comments in 1h (one per ~5min sweep, forever) — R1-R3 prove that
# specific shape can no longer happen, and S1 proves the escalated story goes
# quiet afterward instead of continuing to accumulate noise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# ── Extract the REAL Step 3 block (rig runbook load + no-deploy-cmd halt) ───
# Wiring-only test: extract_gate_merge_info/derive_rig_from_comments (Step 2,
# how RIG got its value) are proven separately, with real fixtures, in
# story-delivery.selftest.sh section 5/5b. This proves Step 3 reacts
# correctly to whatever RIG it was handed, including a bogus one.
STEP3_BLOCK="$(sed -n '/^# ── Step 3: Load runbook for this rig/,/^# ── Step 3.5:/p' "$DELIVERY" | sed '$d')"
[ -n "$STEP3_BLOCK" ] || { echo "FAIL: could not extract Step 3 block"; exit 1; }

# ── Extract the REAL early-skip guard (ga-aqqj0) ─────────────────────────────
SKIP_BLOCK="$(sed -n '/^# ga-aqqj0: skip if the no-deploy-cmd retry cap/,/^# ga-0m6tgc:/p' "$DELIVERY" | sed '$d')"
[ -n "$SKIP_BLOCK" ] || { echo "FAIL: could not extract early-skip guard block"; exit 1; }

# run_step3 <scenario> <existing_retry_label_or_empty>
#   scenario ∈ {FIRST_HALT, MID_RETRY, CAP_TRIP, HAPPY_PATH}
run_step3() {
  SCENARIO="$1"
  local EXISTING_LABEL="${2:-}"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"; mkdir -p "$GC_CITY"
  BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"

  get_runbook_field() {
    local _rig="$1" field="$2"
    case "$SCENARIO:$field" in
      HAPPY_PATH:deploy_cmd) echo "true" ;;
      *:deploy_cmd)          echo "" ;;
      *:prod_test_script)    echo "" ;;
      *:runtime_dir)         echo "/tmp/fake-runtime" ;;
      *)                     echo "" ;;
    esac
  }
  bd()  { echo "bd $*"  >> "$BD_LOG"; }
  gc()  { echo "gc $*"  >> "$GC_LOG"; }
  log() { :; }; warn() { :; }; err() { :; }

  local RIG="origin"
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY_STORE="$GC_CITY"
  local DELIVERY_NO_DEPLOY_CMD_MAX_RETRIES=3
  if [ -n "$EXISTING_LABEL" ]; then
    local STORY="{\"labels\":[\"$EXISTING_LABEL\"]}"
  else
    local STORY='{"labels":[]}'
  fi

  # Wrap in a for-loop so the block's `continue` (loop-based halt) is valid.
  ( for _t in _once; do eval "$STEP3_BLOCK"; done ) >/dev/null 2>&1
  LAST_BD="$(cat "$BD_LOG" 2>/dev/null || true)"
  LAST_GC="$(cat "$GC_LOG" 2>/dev/null || true)"
  unset -f get_runbook_field bd gc log warn err
  rm -rf "$T"
}

# ── R1 (FIXTURE): FIRST_HALT — no pre-existing retry label ──────────────────
run_step3 FIRST_HALT ""
echo "$LAST_BD" | grep -q 'label add ga-test "\?delivery:no-deploy-cmd-retry:1"\?' \
  && ok "R1 FIRST_HALT: retry-count bumped to delivery:no-deploy-cmd-retry:1" || nok "R1 retry-count not bumped" "$LAST_BD"
echo "$LAST_BD" | grep -q "attempt 1/3" \
  && ok "R1 FIRST_HALT: comment names the attempt count (1/3)" || nok "R1 comment attempt count" "$LAST_BD"
! echo "$LAST_BD" | grep -q "no-deploy-cmd-exhausted" \
  && ok "R1 FIRST_HALT: does NOT escalate yet" || nok "R1 escalated too early" "$LAST_BD"
[ -z "$LAST_GC" ] && ok "R1 FIRST_HALT: Mayor NOT mailed yet" || nok "R1 unexpected mayor mail" "$LAST_GC"
echo "$LAST_BD" | grep -q "label add ga-test delivery:failed" \
  && ok "R1 FIRST_HALT: delivery:failed added (existing behavior preserved)" || nok "R1 delivery:failed missing" "$LAST_BD"

# ── R2 (FIXTURE): MID_RETRY — already at retry:1, this is the 2nd halt ──────
run_step3 MID_RETRY "delivery:no-deploy-cmd-retry:1"
echo "$LAST_BD" | grep -q 'label remove ga-test "\?delivery:no-deploy-cmd-retry:1"\?' \
  && ok "R2 MID_RETRY: stale delivery:no-deploy-cmd-retry:1 removed" || nok "R2 stale label not removed" "$LAST_BD"
echo "$LAST_BD" | grep -q 'label add ga-test "\?delivery:no-deploy-cmd-retry:2"\?' \
  && ok "R2 MID_RETRY: retry-count bumped to delivery:no-deploy-cmd-retry:2" || nok "R2 retry-count not bumped" "$LAST_BD"
! echo "$LAST_BD" | grep -q "no-deploy-cmd-exhausted" \
  && ok "R2 MID_RETRY: does NOT escalate yet (2 of 3)" || nok "R2 escalated too early" "$LAST_BD"
[ -z "$LAST_GC" ] && ok "R2 MID_RETRY: Mayor NOT mailed yet" || nok "R2 unexpected mayor mail" "$LAST_GC"

# ── R3 (FIXTURE): CAP_TRIP — already at retry:2, this is the 3rd (=MAX) halt ─
run_step3 CAP_TRIP "delivery:no-deploy-cmd-retry:2"
echo "$LAST_BD" | grep -q 'label remove ga-test "\?delivery:no-deploy-cmd-retry:2"\?' \
  && ok "R3 CAP_TRIP: stale delivery:no-deploy-cmd-retry:2 removed" || nok "R3 stale label not removed" "$LAST_BD"
echo "$LAST_BD" | grep -q "no-deploy-cmd-exhausted" \
  && ok "R3 CAP_TRIP: CAP REACHED -> delivery:no-deploy-cmd-exhausted added" || nok "R3 exhausted label not added" "$LAST_BD"
echo "$LAST_BD" | grep -q "gate:needs-human" \
  && ok "R3 CAP_TRIP: gate:needs-human added (surfaces to a human queue)" || nok "R3 gate:needs-human missing" "$LAST_BD"
! echo "$LAST_BD" | grep -qE 'label add ga-test "?delivery:no-deploy-cmd-retry:3"?' \
  && ok "R3 CAP_TRIP: no fresh retry label added (retrying stops)" || nok "R3 kept retrying past the cap" "$LAST_BD"
echo "$LAST_GC" | grep -q "mail send mayor" \
  && ok "R3 CAP_TRIP: Mayor mailed" || nok "R3 mayor not mailed" "$LAST_GC"
echo "$LAST_GC" | grep -q "'origin'" \
  && ok "R3 CAP_TRIP: mayor mail names the offending rig value" || nok "R3 mayor mail missing rig name" "$LAST_GC"
echo "$LAST_BD" | grep -q "3/3" \
  && ok "R3 CAP_TRIP: comment names the final attempt count (3/3)" || nok "R3 comment attempt count" "$LAST_BD"

# ── R4 (CONTROLE): HAPPY_PATH — deploy_cmd resolves normally ────────────────
run_step3 HAPPY_PATH ""
! echo "$LAST_BD" | grep -q "delivery:failed" \
  && ok "R4 HAPPY_PATH: no delivery:failed (no regression on the working case)" || nok "R4 unexpected delivery:failed" "$LAST_BD"
[ -z "$LAST_BD" ] && ok "R4 HAPPY_PATH: no bd calls at all (falls through cleanly)" || nok "R4 unexpected bd calls" "$LAST_BD"
[ -z "$LAST_GC" ] && ok "R4 HAPPY_PATH: no mayor mail" || nok "R4 unexpected mayor mail" "$LAST_GC"

# ── S1/S2: early-skip guard ──────────────────────────────────────────────────
# `continue` runs inside a subshell (needed so the block's own `continue` is
# legal), and subshells never propagate variable assignments back to the
# parent — a plain "set a flag, check it after" would pass ACCIDENTALLY
# whether or not `continue` actually fired. Use a marker FILE instead: file
# I/O from inside the subshell IS visible after it exits (the same reason
# BD_LOG/GC_LOG work above), so the marker's presence is real evidence of
# reaching the line after the guard, not a tautology.
# run_skip_guard <story_labels>
run_skip_guard() {
  local LABELS="$1"
  local T; T="$(mktemp -d)"
  BD_LOG="$T/bd.log"; REACHED_MARKER="$T/reached-after-guard"
  bd() { echo "bd $*" >> "$BD_LOG"; }
  log() { :; }
  local STORY_ID="ga-test"
  local STORY_LABELS="$LABELS"
  ( for _t in _once; do eval "$SKIP_BLOCK"; touch "$REACHED_MARKER"; done ) >/dev/null 2>&1
  LAST_BD="$(cat "$BD_LOG" 2>/dev/null || true)"
  REACHED_AFTER=0
  [ -f "$REACHED_MARKER" ] && REACHED_AFTER=1
  unset -f bd log
  rm -rf "$T"
}

# S1 (FIXTURE): a story already carrying delivery:no-deploy-cmd-exhausted —
# the guard's `continue` must fire, so the line after it never runs.
run_skip_guard "area:infra,delivery:no-deploy-cmd-exhausted,gate:needs-human"
[ "$REACHED_AFTER" = "0" ] \
  && ok "S1 SKIP_GUARD: continue fires — code after the guard never runs" || nok "S1 guard did not skip" "REACHED_AFTER=$REACHED_AFTER"
[ -z "$LAST_BD" ] \
  && ok "S1 SKIP_GUARD: no bd calls at all while skipping (silent, per ga-aqqj0)" || nok "S1 unexpected bd calls while skipping" "$LAST_BD"

# S2 (CONTROLE): a story WITHOUT the exhausted label must fall through
# normally — proves the guard doesn't over-trigger on ordinary labels
# (including the live, non-exhausted delivery:no-deploy-cmd-retry:N shape).
run_skip_guard "area:infra,delivery:no-deploy-cmd-retry:1,delivery:failed"
[ "$REACHED_AFTER" = "1" ] \
  && ok "S2 SKIP_GUARD control: no exhausted label -> falls through, does not skip" || nok "S2 guard over-triggered" "REACHED_AFTER=$REACHED_AFTER"

echo ""
echo "story-delivery no-deploy-cmd-retry tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
