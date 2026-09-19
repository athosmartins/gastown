#!/usr/bin/env bash
# story-delivery-halt-fingerprint-dedup.test.sh — regression test for wa-xokje
# (extracts the real Step 5b block from story-delivery.sh, no duplication —
# same technique as the other story-delivery-*.test.sh files).
#
# THE BUG: a HALT can be numerically IDENTICAL cycle to cycle — same verdict,
# same GUARDED set, same FRESH_FAIL set — and story-delivery.sh re-posted the
# full "Delivery HALTED" comment and re-nudged the author + Mayor every single
# 5-minute sweep regardless. Confirmed live (wa-bpbgp, 2026-09-16/17): the
# exact same output ("affected=92, restarted=6, guarded~54") repeated for
# 2h07 straight, one comment + two nudges per cycle, with two separate workers
# burning a full investigation turn each before the third one (wa-xokje)
# traced it to this exact loop. Retrying achieves nothing for a story whose
# own contribution to the verdict has not changed — no amount of re-running
# the same check can make it succeed sooner, and re-announcing the identical
# finding every cycle is pure noise for the author, the Mayor, and whichever
# worker next inherits the bead.
#
# THE FIX: fingerprint each HALT as verdict|guarded|freshfail and persist it
# per STORY_ID (.gc/runtime/daemon-refresh-baseline/halt-fingerprint/<id>.txt,
# same directory family as the existing per-rig baseline marker). Post the
# comment + nudges only when the fingerprint is new or has changed since the
# last report. The retry/label mechanics are completely untouched: labels are
# still (re)applied every cycle, the story is still retried every sweep, and
# a real transition (verdict or affected-daemon-set change) still announces
# immediately.
#
# T1: first HALT for a story → comment posted, author + Mayor nudged, halt
#     fingerprint written.
# T2: SECOND HALT for the SAME story, IDENTICAL verdict/guarded/freshfail
#     (a plain retry — nothing changed) → comment/nudge suppressed. Labels
#     are still (re)applied and the block still halts via `continue` —
#     retry mechanics are unaffected, only the announcement is.
# T3: THIRD HALT for the same story, but the GUARDED set actually changed (a
#     real transition, e.g. an unrelated earlier commit's staleness grew or
#     shrank) → comment/nudge fire again despite the fingerprint file
#     existing — dedup must not become a permanent mute switch.
# T4: a DIFFERENT story's FIRST HALT in the SAME city (sharing the same
#     halt-fingerprint directory) → not suppressed by story 1's fingerprint —
#     the dedup key is per-STORY_ID, never global.
#
# ga-vv5ngy: T1-T4 above prove wa-xokje's dedup itself, but confirmed LIVE
# (wa-bpbgp, 2026-09-17, ~1h after wa-xokje merged) that an unresolved HALT
# whose fingerprint keeps matching stays suppressed FOREVER — indistinguishable,
# to the author/Mayor/next worker, from the story having quietly gone away.
# T5/T6 cover the fix: a per-story "last announced" timestamp alongside the
# fingerprint, with a spaced reminder once HALT_FP_REMINDER_INTERVAL_S has
# elapsed since that timestamp, even though the fingerprint never changed.
#
# T5: same story, same fingerprint as its last report, but that report is now
#     older than HALT_FP_REMINDER_INTERVAL_S → a SHORT reminder comment fires
#     (author + Mayor nudged again) — invariant (c): it must NOT repeat the
#     full daemon list ("Refresh detail:"/$REFRESH_OUT), only point back at
#     the original. The stored timestamp is refreshed to now.
# T6: immediately after T5 (no time elapsed since T5's just-refreshed
#     timestamp), same fingerprint again → back to fully silent — the
#     reminder is spaced, not "announce from now on".
#
# ga-q29hsf: this test used to cross the interval with a REAL sleep against a
# 2s interval, assuming every back-to-back run took "well under 1s". The script
# measures with `date +%s` (whole seconds), so the effective silent window was
# only 1-2s wide: on a loaded machine (load average 60-80) one run outlasted
# it, the reminder fired "early", and the "should be suppressed" asserts (T2/T6)
# failed with no relation to the diff under test. Now no assertion depends on
# how fast a run is. The interval is far longer than any run could take (so
# "suppressed" cannot be crossed by load), and T5 gets its "the last report is
# older than the interval" precondition by rewinding the persisted epoch (line 2
# of the story's fingerprint file — the script's own state, read by the same
# code path as in production) instead of sleeping.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"
# Deliberately HUGE relative to any run (an hour): "suppressed" (T2/T6) must
# hold however slow the machine is, so nothing here may depend on a run
# finishing inside a short window (ga-q29hsf). T5 reaches the "interval
# elapsed" side by backdating the stored epoch (backdate_halt_fp below),
# never by waiting.
export HALT_FP_REMINDER_INTERVAL_S=3600

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the Step 5b block (from its header up to, but excluding, Step 6) —
# identical technique to the other story-delivery-*.test.sh files.
BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
GC_CITY="$T/city"
mkdir -p "$GC_CITY/packs/town-deltas/assets"

# One shared git fixture and ONE shared GC_CITY for every run_block call in
# this file — deliberately, unlike the other story-delivery-*.test.sh files
# (each of which gets a fresh city per case): the whole point here is that
# the halt-fingerprint file living under GC_CITY persists ACROSS calls, the
# same way it persists across real 5-minute story-delivery.sh sweeps.
REPO="$T/runtime"
git init -q "$REPO"
git -C "$REPO" config user.email t@t.local
git -C "$REPO" config user.name t
mkdir -p "$REPO/lib"
echo base > "$REPO/base.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C0
SHA_C0="$(git -C "$REPO" rev-parse HEAD)"
echo prod > "$REPO/lib/foo.py"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C1
SHA_C1="$(git -C "$REPO" rev-parse HEAD)"

# write_stub <guarded-labels> — (re)writes the fake daemon-refresh.sh to
# always return NEEDS_GUARDED_RESTART for the given (space-joined) GUARDED
# set. Called between run_block invocations to simulate a verdict that
# either stays identical (dedup should suppress) or genuinely changes
# (dedup must not suppress).
write_stub() {
  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<EOF
echo "VERDICT=NEEDS_GUARDED_RESTART"
echo "AFFECTED=$1"
echo "AFFECTED_NOT_RUNNING="
echo "RESTARTED="
echo "FRESH_FAIL="
echo "GUARDED=$1"
echo "REASON=sensitive hot-path daemon needs a guarded restart"
exit 1
EOF
}

# run_block <story_id> — runs the real Step 5b block once against the SHARED
# GC_CITY/REPO above (own delta = C0..C1, a real production file — not
# tests/docs/md — so THIS_PULL_STRUCTURALLY_INERT=0 and the block reaches the
# HALT branch deterministically every call). Sets globals: RUN_RC, LOG_OUT,
# BD_CALLS, GC_CALLS, REACHED — freshly captured each call (only GC_CITY/REPO
# persist between calls, never the log/bd/gc capture files).
run_block() {
  local story_id="$1"
  local tag="${story_id}.$$.${RANDOM}"
  LOG_FILE="$T/log.$tag.log"; BD_LOG="$T/bd.$tag.log"; GC_LOG="$T/gc.$tag.log"
  : > "$LOG_FILE"; : > "$BD_LOG"; : > "$GC_LOG"
  bd()   { echo "bd $*" >> "$BD_LOG"; }
  gc()   { echo "gc $*" >> "$GC_LOG"; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }
  export -f bd gc log warn err 2>/dev/null || true

  local RIG="whatsapp_automation"
  local RUNTIME_DIR="$REPO"
  local PRE_DEPLOY_SHA="$SHA_C0" POST_DEPLOY_SHA="$SHA_C1" DEPLOY_EPOCH=1
  local DRY_RUN=0
  local STORY_ID="$story_id"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
  local MERGE_SHA="" MERGE_PRE_MAIN=""
  get_runbook_field() { echo "central-sender"; }

  rm -f "$T/reached.marker"
  ( for _t in _once; do eval "$BLOCK"; touch "$T/reached.marker"; done ) >/dev/null 2>&1
  RUN_RC=$?
  LOG_OUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  BD_CALLS="$(cat "$BD_LOG" 2>/dev/null || true)"
  GC_CALLS="$(cat "$GC_LOG" 2>/dev/null || true)"
  [ -f "$T/reached.marker" ] && REACHED=1 || REACHED=0
}

# backdate_halt_fp <story_id> — rewinds the persisted "last announced" epoch
# (line 2 of the story's halt-fingerprint file, see story-delivery.sh) to TWICE
# HALT_FP_REMINDER_INTERVAL_S in the past, leaving line 1 (the dedup key)
# untouched. Stands in for "that much real time has passed" without a sleep:
# the block still reads the file, subtracts, and compares exactly as in
# production. Records a FAIL itself and returns 1 if there is no fingerprint to
# rewind or the rewrite did not take, so a vacuous T5 setup cannot pass silently.
backdate_halt_fp() {
  local f="$GC_CITY/.gc/runtime/daemon-refresh-baseline/halt-fingerprint/$1.txt"
  local key ts
  key="$(sed -n '1p' "$f" 2>/dev/null || true)"
  if [ -z "$key" ]; then
    nok "backdate_halt_fp: no fingerprint recorded for $1" "$f"
    return 1
  fi
  ts=$(( $(date +%s) - 2 * HALT_FP_REMINDER_INTERVAL_S ))
  printf '%s\n%s\n' "$key" "$ts" > "$f"
  if [ "$(sed -n '1p' "$f")" != "$key" ] || [ "$(sed -n '2p' "$f")" != "$ts" ]; then
    nok "backdate_halt_fp: rewrite of $1 fingerprint did not take" "$(cat "$f" 2>/dev/null)"
    return 1
  fi
}

# ── T1: first HALT for ga-test1 → announced ──────────────────────────────
write_stub "com.test.central-sender"
run_block ga-test1
[ "$RUN_RC" -eq 0 ] && ok "T1 block runs clean (rc=0; continue-based halt, BD state is the signal)" \
  || nok "T1 rc" "rc=$RUN_RC"
[ "$REACHED" -eq 0 ] && ok "T1 block halts via continue" || nok "T1 halted" "REACHED=$REACHED"
echo "$BD_CALLS" | grep -q "label add ga-test1 delivery:failed" \
  && ok "T1 delivery:failed added" || nok "T1 failed-label" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "comment ga-test1" \
  && ok "T1 first HALT: comment posted" || nok "T1 comment" "$BD_CALLS"
echo "$GC_CALLS" | grep -q "session nudge crew/tester" \
  && ok "T1 first HALT: author nudged" || nok "T1 author nudge" "$GC_CALLS"
echo "$GC_CALLS" | grep -q "session nudge mayor" \
  && ok "T1 first HALT: Mayor nudged" || nok "T1 mayor nudge" "$GC_CALLS"

# ── T2: second HALT for ga-test1, IDENTICAL verdict/guarded (a plain retry,
#        stub unchanged) → labels still applied, comment/nudge suppressed ──
run_block ga-test1
[ "$RUN_RC" -eq 0 ] && ok "T2 block runs clean (rc=0)" || nok "T2 rc" "rc=$RUN_RC"
[ "$REACHED" -eq 0 ] && ok "T2 block still halts via continue — retry mechanics unaffected" \
  || nok "T2 halted" "REACHED=$REACHED"
echo "$BD_CALLS" | grep -q "label add ga-test1 delivery:failed" \
  && ok "T2 delivery:failed still (re)applied every cycle" || nok "T2 failed-label" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "label add ga-test1 delivery:deploy-pending" \
  && ok "T2 delivery:deploy-pending still (re)applied every cycle" || nok "T2 deploy-pending" "$BD_CALLS"
! echo "$BD_CALLS" | grep -q "comment ga-test1" \
  && ok "T2 identical repeat HALT: comment suppressed (THE FIX)" \
  || nok "T2 comment should be suppressed" "$BD_CALLS"
! echo "$GC_CALLS" | grep -q "session nudge crew/tester" \
  && ok "T2 identical repeat HALT: author nudge suppressed" \
  || nok "T2 author nudge should be suppressed" "$GC_CALLS"
! echo "$GC_CALLS" | grep -q "session nudge mayor" \
  && ok "T2 identical repeat HALT: Mayor nudge suppressed" \
  || nok "T2 mayor nudge should be suppressed" "$GC_CALLS"
echo "$LOG_OUT" | grep -q "suppressing duplicate comment/nudge" \
  && ok "T2 log records the suppression (visible to whoever reads story-delivery.log)" \
  || nok "T2 suppression log line" "$LOG_OUT"

# ── T3: third HALT for ga-test1 — GUARDED set genuinely changed → announced
#        again despite the fingerprint file already existing ──────────────
write_stub "com.test.central-sender com.test.other-daemon"
run_block ga-test1
[ "$RUN_RC" -eq 0 ] && ok "T3 block runs clean (rc=0)" || nok "T3 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep -q "comment ga-test1" \
  && ok "T3 real transition (GUARDED set changed): comment posted again" \
  || nok "T3 comment" "$BD_CALLS"
echo "$GC_CALLS" | grep -q "session nudge mayor" \
  && ok "T3 real transition: Mayor nudged again" || nok "T3 mayor nudge" "$GC_CALLS"

# ── T4: a DIFFERENT story's first HALT in the SAME city → not suppressed by
#        ga-test1's fingerprint (per-bead dedup key, not global) ───────────
run_block ga-test2
[ "$RUN_RC" -eq 0 ] && ok "T4 block runs clean (rc=0)" || nok "T4 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep -q "comment ga-test2" \
  && ok "T4 different story's first HALT: comment posted (per-bead dedup, not global)" \
  || nok "T4 comment" "$BD_CALLS"
echo "$GC_CALLS" | grep -q "session nudge mayor" \
  && ok "T4 different story's first HALT: Mayor nudged" || nok "T4 mayor nudge" "$GC_CALLS"

# ── T5: ga-vv5ngy spaced reminder — same story (fresh id), first HALT
#        announces as usual, then the SAME fingerprint again after
#        HALT_FP_REMINDER_INTERVAL_S has elapsed → reminder fires ─────────
write_stub "com.test.central-sender"
run_block ga-test3
[ "$RUN_RC" -eq 0 ] && ok "T5 setup: first HALT for ga-test3 runs clean" \
  || nok "T5 setup rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep -q "comment ga-test3" \
  && ok "T5 setup: first HALT announced" || nok "T5 setup comment" "$BD_CALLS"
# ga-q29hsf: the "last report is older than the interval" precondition is SET,
# not waited for — a sleep here raced a loaded machine and slowed every gate run.
backdate_halt_fp ga-test3 \
  && ok "T5 setup: ga-test3's last report backdated past the reminder interval"
run_block ga-test3
[ "$RUN_RC" -eq 0 ] && ok "T5 block runs clean (rc=0)" || nok "T5 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep -q "comment ga-test3" \
  && ok "T5 same fingerprint, reminder interval elapsed: comment fires" \
  || nok "T5 comment" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "STILL unresolved" \
  && ok "T5 reminder comment is marked as a reminder, not a fresh HALT" \
  || nok "T5 reminder wording" "$BD_CALLS"
! echo "$BD_CALLS" | grep -q "Refresh detail:" \
  && ok "T5 invariant (c): reminder does NOT repeat the full daemon list" \
  || nok "T5 should not include Refresh detail:" "$BD_CALLS"
echo "$GC_CALLS" | grep -q "session nudge crew/tester" \
  && ok "T5 reminder: author nudged again" || nok "T5 author nudge" "$GC_CALLS"
echo "$GC_CALLS" | grep -q "session nudge mayor" \
  && ok "T5 reminder: Mayor nudged again" || nok "T5 mayor nudge" "$GC_CALLS"

# ── T6: immediately after T5 (timestamp just refreshed), same fingerprint
#        again → back to silent — the reminder is SPACED, not sticky ──────
run_block ga-test3
[ "$RUN_RC" -eq 0 ] && ok "T6 block runs clean (rc=0)" || nok "T6 rc" "rc=$RUN_RC"
! echo "$BD_CALLS" | grep -q "comment ga-test3" \
  && ok "T6 right after a reminder, unchanged: comment suppressed again" \
  || nok "T6 comment should be suppressed" "$BD_CALLS"
! echo "$GC_CALLS" | grep -q "session nudge mayor" \
  && ok "T6 right after a reminder, unchanged: Mayor nudge suppressed again" \
  || nok "T6 mayor nudge should be suppressed" "$GC_CALLS"

echo ""
echo "story-delivery halt-fingerprint dedup tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
