#!/usr/bin/env bash
# story-delivery-daemon-refresh-perdaemon-baseline.test.sh — regression test
# for ga-0fawwr (extracts the real Step 5b block from story-delivery.sh, no
# duplication — same technique as story-delivery-step5b.test.sh).
#
# THE BUG (see daemon-refresh.sh's own big comment on DAEMON_BASELINE_OVERRIDES,
# at its point of use, for the full incident): the rig-wide baseline marker
# ($RIG.sha) only advances when the WHOLE rig comes back OK|SKIPPED in one
# cycle. A single persistently-guarded daemon freezes it for every OTHER
# daemon on the same rig too, so a large-closure daemon gets falsely
# re-flagged AFFECTED on nearly every cycle even when nothing in ITS OWN
# closure has changed since it was last individually clean (measured live:
# 115 of 194 cycles NEEDS_GUARDED_RESTART over 5 days, rig-wide marker
# advancing only twice).
#
# THE FIX: story-delivery.sh now ALSO persists a per-daemon baseline file
# ($RIG.perdaemon, one "<label> <sha>" pair per line), advancing each label
# independently of the overall verdict: any label examined this cycle
# (daemon-refresh.sh's new ALL_LABELS field) and NOT left in GUARDED or
# FRESH_FAIL gets its own entry advanced to POST_DEPLOY_SHA, regardless of
# what any other label on the same rig did. This file is later read back and
# fed to daemon-refresh.sh as DAEMON_BASELINE_OVERRIDES — see
# tests/daemon-refresh.test.sh's T51/T52 for the closure-narrowing half of
# this fix.
#
# T1: two labels examined, one guarded, one clean, no pre-existing file →
#     only the clean label's entry is written; the guarded one is not.
# T2: a pre-existing entry for a label NOT examined this cycle (e.g. hidden
#     from discovery by a plist parse error) is carried forward untouched.
# T3: overall REFRESH_VERDICT is NEEDS_GUARDED_RESTART (non-OK) — the
#     per-daemon write still happens for the clean label (independent of the
#     rig-wide gate), while the rig-wide $RIG.sha marker is confirmed NOT
#     advanced (ga-gokm6 behavior, unchanged).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the Step 5b block (from its header up to, but excluding, Step 6) —
# identical technique to story-delivery-step5b.test.sh.
BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }

RIG_MARKER_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.sha"
PERDAEMON_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.perdaemon"

# run_block <stub-verdict> <all-labels> <guarded> <freshfail> [<seed-perdaemon-line>]
# Builds a 2-commit git fixture (C0 -> C1), a stub daemon-refresh.sh that
# emits the given fields, optionally seeds the perdaemon file with one line,
# then runs the real Step 5b block with PRE_DEPLOY_SHA=C0 POST_DEPLOY_SHA=C1.
# Sets globals: RUN_RC, PERDAEMON_AFTER, RIGMARKER_AFTER, EXPECT_C0, EXPECT_C1.
run_block() {
  local stub_verdict="$1" all_labels="$2" guarded="$3" freshfail="$4" seed="${5:-}"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"
  mkdir -p "$GC_CITY/packs/town-deltas/assets"

  local REPO="$T/runtime"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t.local
  git -C "$REPO" config user.name t
  echo base > "$REPO/f.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C0
  local SHA_C0; SHA_C0="$(git -C "$REPO" rev-parse HEAD)"
  echo tip  > "$REPO/f.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C1
  local SHA_C1; SHA_C1="$(git -C "$REPO" rev-parse HEAD)"

  if [ -n "$seed" ]; then
    mkdir -p "$GC_CITY/$(dirname "$PERDAEMON_REL")"
    printf '%s\n' "$seed" > "$GC_CITY/$PERDAEMON_REL"
  fi

  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<EOF
echo "VERDICT=$stub_verdict"
echo "ALL_LABELS=$all_labels"
echo "RESTARTED="
echo "GUARDED=$guarded"
echo "FRESH_FAIL=$freshfail"
echo "REASON=stub"
exit 0
EOF

  LOG_FILE="$T/log.log"
  bd()   { :; }
  gc()   { :; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }
  export -f bd gc log warn err 2>/dev/null || true

  local RIG="whatsapp_automation"
  local RUNTIME_DIR="$REPO"
  local PRE_DEPLOY_SHA="$SHA_C0" POST_DEPLOY_SHA="$SHA_C1" DEPLOY_EPOCH=1
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
  # declared (not left unset) because the block runs under `set -u` here —
  # same reasoning as story-delivery-daemon-refresh-baseline.test.sh.
  local MERGE_SHA=""
  local MERGE_PRE_MAIN=""
  get_runbook_field() { echo "central-sender"; }

  ( for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1
  RUN_RC=$?
  PERDAEMON_AFTER="$(cat "$GC_CITY/$PERDAEMON_REL" 2>/dev/null || true)"
  RIGMARKER_AFTER="$(cat "$GC_CITY/$RIG_MARKER_REL" 2>/dev/null || true)"
  EXPECT_C0="$SHA_C0"
  EXPECT_C1="$SHA_C1"
  rm -rf "$T"
}

# ── T1: two labels, one guarded one clean, no pre-existing file ──────────────
run_block "NEEDS_GUARDED_RESTART" "com.test.a com.test.b" "com.test.a" "" ""
echo "$PERDAEMON_AFTER" | grep -qx "com.test.b $EXPECT_C1" \
  && ok "T1 clean label (com.test.b) gets its own baseline advanced to POST_DEPLOY_SHA" \
  || nok "T1 clean label advanced" "perdaemon=[$PERDAEMON_AFTER]"
echo "$PERDAEMON_AFTER" | grep -q "^com.test.a " \
  && nok "T1 guarded label (com.test.a) must NOT have its baseline advanced" "perdaemon=[$PERDAEMON_AFTER]" \
  || ok "T1 guarded label correctly left out of the per-daemon file"

# ── T2: a pre-existing entry for a label NOT examined this cycle is kept ─────
run_block "NEEDS_GUARDED_RESTART" "com.test.b" "" "" "com.test.c deadbeef0000000000000000000000000000000"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.c deadbeef0000000000000000000000000000000" \
  && ok "T2 pre-existing entry for a label outside this cycle's ALL_LABELS is carried forward untouched" \
  || nok "T2 carry-forward" "perdaemon=[$PERDAEMON_AFTER]"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.b $EXPECT_C1" \
  && ok "T2 this cycle's clean label is still advanced alongside the carried-forward entry" \
  || nok "T2 clean label advanced" "perdaemon=[$PERDAEMON_AFTER]"

# ── T3: per-daemon write is independent of the rig-wide OK|SKIPPED gate ──────
run_block "NEEDS_GUARDED_RESTART" "com.test.b" "" "" ""
[ -z "$RIGMARKER_AFTER" ] \
  && ok "T3 rig-wide marker NOT advanced on a non-OK verdict (ga-gokm6 behavior, unchanged)" \
  || nok "T3 rig marker" "got '$RIGMARKER_AFTER', want empty"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.b $EXPECT_C1" \
  && ok "T3 per-daemon marker STILL advances for the clean label despite the non-OK rig-wide verdict — the actual fix" \
  || nok "T3 perdaemon advanced despite non-OK verdict" "perdaemon=[$PERDAEMON_AFTER]"

echo ""
echo "story-delivery per-daemon baseline tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
