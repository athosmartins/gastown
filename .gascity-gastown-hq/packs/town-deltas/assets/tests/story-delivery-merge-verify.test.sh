#!/usr/bin/env bash
# story-delivery-merge-verify.test.sh — regression test for the pre-deploy
# merge-verification gate (Step 3.6, ga-mmdm2) in story-delivery.sh.
#
# Extracts the REAL Step 3.6 block from story-delivery.sh (no duplication) and
# drives it with stubbed extract_gate_merge_info/rig_gitdir/story_merge_verdict
# (the wiring under test) plus stubbed git/bd/gc/timeout/log, to prove:
#   S1 ANCESTOR      — the story's gate-merged sha IS an ancestor of the rig's
#                       main → delivery PROCEEDS (falls through to Step 4, no
#                       delivery:failed, no story:done withheld here).
#   S2 NOT_ANCESTOR   — the sha exists but is NOT an ancestor (ga-sb11i.2 shape:
#                       gate:passed but the commit never left its feature
#                       branch) → HALT: delivery:failed added, delivery:running
#                       removed, story:done NOT set, author + mayor nudged.
#   S3 NO_COMMENT     — no gate merge-comment with a sha found at all → HALT
#                       the SAME way as S2 (fail-closed; ga-mmdm2 control #2:
#                       "could not verify" must not default to "proceed").
#
# This is the ga-mmdm2 acceptance test: FIXTURE (sha not ancestor) blocks,
# CONTROLE (sha is ancestor) delivers normally, CONTROLE 2 (sha undeterminable)
# blocks the same as CONTROLE — never the same result as a verified pass.
#
# gate-fix-attempt-2 (ga-mmdm2): must run with -e, matching story-delivery.sh's
# own `set -euo pipefail` — a prior version of this harness used `-uo` (no -e)
# and silently passed 13/13 while the real Step 3.6 block crashed under its
# own script's errexit on a bare, unguarded `VAR=$(fn_that_can_return_1)`
# assignment (story_merge_verdict returns rc1 on 2 of its 3 outcomes). Keeping
# -e here is what makes S2/S3 below an honest proof instead of a false green.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the Step 3.6 block (from its header up to, but excluding, Step 4).
BLOCK="$(sed -n '/Step 3.6: Pre-deploy merge verification/,/# ── Step 4: Deploy/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 3.6 block"; exit 1; }

# run_block <scenario>
#   scenario ∈ {ANCESTOR, NOT_ANCESTOR, NO_COMMENT}; controls the stubbed
#   verdict functions. Wiring-only test: the real content-check logic for
#   extract_gate_merge_info/story_merge_verdict is proven separately (with
#   real git fixtures) in story-delivery.selftest.sh sections 5-6; this test
#   proves Step 3.6 reacts correctly to each verdict.
run_block() {
  SCENARIO="$1"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"; mkdir -p "$GC_CITY"
  BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"; GIT_LOG="$T/git.log"

  extract_gate_merge_info() {
    echo "extract_gate_merge_info $*" >> "$GIT_LOG"
    case "$SCENARIO" in
      NO_COMMENT) return 1 ;;
      *) printf 'gascity/main\tabc1234deadbeefabc1234deadbeefabc1234de'; return 0 ;;
    esac
  }
  rig_gitdir() { printf '%s\t0' "$1"; }
  story_merge_verdict() {
    echo "story_merge_verdict $*" >> "$GIT_LOG"
    case "$SCENARIO" in
      ANCESTOR)     echo "verified";     return 0 ;;
      NOT_ANCESTOR) echo "not-ancestor"; return 1 ;;
      *)            echo "unresolvable"; return 1 ;;
    esac
  }
  # git stub — only the pre-check (is-inside-work-tree) and fetch are called
  # directly by Step 3.6 itself; the verdict computation is stubbed above.
  git() {
    echo "git $*" >> "$GIT_LOG"
    if [ "${1:-}" = "-C" ]; then shift 2; fi
    local sub="${1:-}"; shift || true
    case "$sub" in
      rev-parse) case "${1:-}" in --is-inside-work-tree) return 0 ;; *) return 0 ;; esac ;;
      fetch) return 0 ;;
      *) return 0 ;;
    esac
  }
  timeout() { shift; "$@"; }
  bd()  { echo "bd $*"  >> "$BD_LOG"; }
  gc()  { echo "gc $*"  >> "$GC_LOG"; }
  log() { :; }; warn() { :; }; err() { :; }

  local RIG="gascity"
  local RUNTIME_DIR="/tmp/fake-runtime"
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY_STORE="$GC_CITY"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'

  # Wrap in a for-loop so the block's `continue` (loop-based halt) is valid.
  ( for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1
  RUN_RC=$?
  LAST_BD="$(cat "$BD_LOG"  2>/dev/null || true)"
  LAST_GC="$(cat "$GC_LOG"  2>/dev/null || true)"
  LAST_GIT="$(cat "$GIT_LOG" 2>/dev/null || true)"
  unset -f extract_gate_merge_info rig_gitdir story_merge_verdict git timeout bd gc log warn err
  rm -rf "$T"
}

# ── S1 (CONTROLE): ANCESTOR → proceeds, no delivery:failed ────────────────────
run_block ANCESTOR
! echo "$LAST_BD" | grep -q "delivery:failed" && ok "S1 ANCESTOR: no delivery:failed label (proceeds to Step 4)" || nok "S1 failed-label" "$LAST_BD"
! echo "$LAST_BD" | grep -q "label add ga-test story:done" && ok "S1 ANCESTOR: story:done not set HERE (Step 4/8's job, not 3.6's)" || nok "S1 story-done" "$LAST_BD"
echo "$LAST_GIT" | grep -q "story_merge_verdict" && ok "S1 ANCESTOR: verdict function was actually consulted" || nok "S1 verdict-called" "$LAST_GIT"

# ── S2 (FIXTURE): NOT_ANCESTOR → HALT, delivery:failed naming sha+rig ────────
run_block NOT_ANCESTOR
echo "$LAST_BD" | grep -q "label add ga-test delivery:failed" && ok "S2 NOT_ANCESTOR: delivery:failed added" || nok "S2 failed-label" "$LAST_BD"
echo "$LAST_BD" | grep -q "label remove ga-test delivery:running" && ok "S2 NOT_ANCESTOR: delivery:running removed" || nok "S2 running-removed" "$LAST_BD"
! echo "$LAST_BD" | grep -q "label add ga-test story:done" && ok "S2 NOT_ANCESTOR: story:done NOT set" || nok "S2 story-done" "$LAST_BD"
echo "$LAST_BD" | grep -q "comment ga-test" && echo "$LAST_BD" | grep -qi "gascity" && ok "S2 NOT_ANCESTOR: comment names the rig" || nok "S2 comment-rig" "$LAST_BD"
echo "$LAST_BD" | grep -q "abc1234deadbeefabc1234deadbeefabc1234de" && ok "S2 NOT_ANCESTOR: comment names the sha (bug's literal ask: 'nomeando o sha e o rig')" || nok "S2 comment-sha" "$LAST_BD"
echo "$LAST_GC" | grep -q "session nudge mayor" && ok "S2 NOT_ANCESTOR: mayor nudged" || nok "S2 mayor-nudge" "$LAST_GC"
echo "$LAST_GC" | grep -q "session nudge crew/tester" && ok "S2 NOT_ANCESTOR: author nudged" || nok "S2 author-nudge" "$LAST_GC"

# ── S3 (CONTROLE 2): NO_COMMENT → HALT the same way, fail-closed ─────────────
run_block NO_COMMENT
echo "$LAST_BD" | grep -q "label add ga-test delivery:failed" && ok "S3 NO_COMMENT: delivery:failed added (unverified blocks same as not-ancestor)" || nok "S3 failed-label" "$LAST_BD"
! echo "$LAST_BD" | grep -q "label add ga-test story:done" && ok "S3 NO_COMMENT: story:done NOT set (no default-permissive)" || nok "S3 story-done" "$LAST_BD"
! echo "$LAST_GIT" | grep -q "story_merge_verdict" && ok "S3 NO_COMMENT: story_merge_verdict never called (no sha to check)" || nok "S3 verdict-not-called" "$LAST_GIT"

echo ""
echo "story-delivery merge-verify tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
