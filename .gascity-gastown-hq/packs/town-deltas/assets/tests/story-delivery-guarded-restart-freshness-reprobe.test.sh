#!/usr/bin/env bash
# story-delivery-guarded-restart-freshness-reprobe.test.sh — regression test
# for ga-g63ejg (extracts the real Step 5b block from story-delivery.sh, no
# duplication — same technique as story-delivery-guarded-restart-attribution
# .test.sh and story-delivery-guarded-restart-closure-only-attribution.test.sh).
#
# THE BUG: wa-xn0w0 was closed story:done with its own feature DORMANT.
# ga-49fwiw/ga-87solq's NEEDS_GUARDED_RESTART_UNATTRIBUTED check exonerates a
# story the instant its own affected daemon(s) (MERGE_OWN_AFFECTED) don't
# intersect the WIDE sweep's currently-guarded-own set (REFRESH_GUARDED_OWN)
# — treating "absent from the wide list" as proof of "fresh". It isn't: the
# wide sweep's own [PRE,POST] window can advance past this story's merge
# (e.g. an earlier story's own unattributed branch moves the rig-wide marker
# straight to ITS OWN POST_DEPLOY_SHA) without the daemon this story touches
# ever being independently re-examined or restarted. Live: com.whatsapp.
# map-viewer was still serving the pre-merge JS bundle 7 minutes after this
# exact branch logged "not holding this delivery for it" and exonerated.
#
# THE FIX: before trusting an empty REFRESH_GUARDED_OWN intersection, re-probe
# this story's own AFFECTED set directly — force every label in it through
# daemon-refresh.sh's SENSITIVE already_fresh() check (pid-start-epoch vs.
# this story's own commit, $MERGE_SHA) via a second DRY_RUN=1 call with
# SENSITIVE_DAEMONS overridden to include them. Only a re-probe that BOTH
# parses AND reports the daemon clear (GUARDED empty) exonerates; an
# unparseable re-probe or one that still names the daemon in GUARDED holds
# the delivery — never confuse "off the wide sweep's radar" with "confirmed
# fresh".
#
# T1 (the repro + fix proof): narrow probe reaches new-daemon, which is NOT
#     in the wide GUARDED_OWN set (only unrelated old-daemon is stuck) — the
#     exact shape ga-49fwiw's own T1 already proves must normally exonerate.
#     Here the freshness re-probe confirms new-daemon is STILL STALE
#     (GUARDED=new-daemon on re-probe). Delivery MUST be held, and the
#     rig-wide baseline marker must NOT advance.
# T2 (control — re-probe confirms fresh): same setup, but the re-probe comes
#     back with new-daemon cleared (GUARDED empty, already_fresh) — a
#     restart via some other path already landed. Delivery must NOT be held,
#     exactly like ga-49fwiw's own T1, and the baseline marker must advance.
# T3 (control — re-probe unparseable, third state): the re-probe call itself
#     produces no parseable VERDICT= line at all (crash/timeout stand-in).
#     Must NOT be treated as fresh — delivery held, marker unchanged — same
#     fail-closed default this file uses everywhere else for "can't tell".

# No `pipefail` at file level (ga-uel7sb): assertions below are `X | grep ...`
# -style pipes, and under pipefail an early-exiting reader can SIGPIPE the
# writer mid-write, turning a PASSING assertion into a false FAIL under load
# (measured: 1.9% per assertion at load 45; see ga-uel7sb). The block under
# test still runs WITH pipefail (see run_block), as in production.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the Step 5b block (from its header up to, but excluding, Step 6) —
# identical technique to the other story-delivery-*.test.sh files.
BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }

MARKER_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.sha"

# run_block <mode>
#   "stale"       (T1): re-probe (forced-sensitive) reports new-daemon still
#                 in GUARDED — confirmed stale right now.
#   "fresh"       (T2): re-probe reports new-daemon cleared (GUARDED empty).
#   "unparseable" (T3): re-probe produces no output at all.
run_block() {
  local mode="$1"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"
  mkdir -p "$GC_CITY/packs/town-deltas/assets"

  local REPO="$T/runtime"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t.local
  git -C "$REPO" config user.name t
  echo base > "$REPO/base.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C0
  local SHA_C0; SHA_C0="$(git -C "$REPO" rev-parse HEAD)"
  echo mid > "$REPO/mid.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C1
  local SHA_C1; SHA_C1="$(git -C "$REPO" rev-parse HEAD)"
  echo new > "$REPO/new.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
  local SHA_C2; SHA_C2="$(git -C "$REPO" rev-parse HEAD)"

  # Wide-window baseline starts at C0 (spans an earlier, unrelated merge C1).
  mkdir -p "$GC_CITY/$(dirname "$MARKER_REL")"
  printf '%s\n' "$SHA_C0" > "$GC_CITY/$MARKER_REL"
  BASELINE_FILE_ABS="$GC_CITY/$MARKER_REL"

  local reprobe_body=""
  case "$mode" in
    stale)
      reprobe_body='echo "VERDICT=NEEDS_GUARDED_RESTART"
  echo "AFFECTED=com.test.new-daemon"
  echo "AFFECTED_NOT_RUNNING="
  echo "RESTARTED="
  echo "FRESH_FAIL="
  echo "GUARDED=com.test.new-daemon"
  echo "GUARDED_OWN=com.test.new-daemon"
  echo "REASON=freshness re-probe: still stale"
  echo "ALL_LABELS="
  exit 1'
      ;;
    fresh)
      reprobe_body='echo "VERDICT=OK"
  echo "AFFECTED=com.test.new-daemon"
  echo "AFFECTED_NOT_RUNNING="
  echo "RESTARTED="
  echo "FRESH_FAIL="
  echo "GUARDED="
  echo "REASON=freshness re-probe: already fresh"
  echo "ALL_LABELS="
  exit 0'
      ;;
    unparseable)
      reprobe_body='exit 1'
      ;;
    *) echo "run_block: unknown mode '$mode'" >&2; exit 1 ;;
  esac

  # Fake daemon-refresh.sh: three call shapes share this one script.
  #   1. DRY_RUN=1, SENSITIVE_DAEMONS does NOT mention new-daemon: the
  #      ORIGINAL narrow per-bead reachability probe (Path B) — unchanged,
  #      always reports the plain reachability result.
  #   2. DRY_RUN=1, SENSITIVE_DAEMONS DOES mention new-daemon: the NEW
  #      freshness re-probe this fix adds — behavior set by $mode above.
  #   3. DRY_RUN!=1: the WIDE/real sweep call — GUARDED is old-daemon ONLY,
  #      new-daemon is off its radar entirely (the bug's own precondition).
  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<EOF
if [ "\$DRY_RUN" = "1" ]; then
  case " \$SENSITIVE_DAEMONS " in
    *" com.test.new-daemon "*)
      $reprobe_body
      ;;
    *)
      echo "VERDICT=OK"
      echo "AFFECTED=com.test.new-daemon"
      echo "AFFECTED_NOT_RUNNING="
      echo "RESTARTED="
      echo "FRESH_FAIL="
      echo "GUARDED="
      echo "REASON=dry-run per-bead probe"
      echo "ALL_LABELS="
      exit 0
      ;;
  esac
else
  echo "VERDICT=NEEDS_GUARDED_RESTART"
  echo "AFFECTED=com.test.old-daemon"
  echo "RESTARTED="
  echo "FRESH_FAIL="
  echo "GUARDED=com.test.old-daemon"
  echo "GUARDED_OWN=com.test.old-daemon"
  echo "REASON=sensitive hot-path daemon(s) need a guarded restart"
  echo "ALL_LABELS=com.test.old-daemon"
  exit 1
fi
EOF

  # Not `local` — assertions after run_block returns need these.
  EXPECT_C0="$SHA_C0"; EXPECT_C2="$SHA_C2"

  LOG_FILE="$T/log.log"; BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"
  bd()   { echo "bd $*" >> "$BD_LOG"; }
  gc()   { echo "gc $*" >> "$GC_LOG"; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }
  export -f bd gc log warn err 2>/dev/null || true

  local RIG="whatsapp_automation"
  local RUNTIME_DIR="$REPO"
  local DEPLOY_EPOCH=1
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
  # True no-op pull: something else already advanced HEAD to this story's
  # own tip before PRE_DEPLOY_SHA was captured (ga-gokm6) — the narrow
  # per-bead fallback probe fires (Path B), same setup ga-49fwiw/ga-87solq
  # use for their own repro cases.
  local PRE_DEPLOY_SHA="$SHA_C2" POST_DEPLOY_SHA="$SHA_C2"
  local MERGE_SHA="$SHA_C2" MERGE_REF="origin/main" MERGE_PRE_MAIN="$SHA_C1"
  get_runbook_field() { echo ""; }

  ( set -o pipefail; for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1
  RUN_RC=$?
  LOG_OUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  BD_CALLS="$(cat "$BD_LOG" 2>/dev/null || true)"
  GC_CALLS="$(cat "$GC_LOG" 2>/dev/null || true)"
  BASELINE_AFTER="$(cat "$BASELINE_FILE_ABS" 2>/dev/null || echo "<missing>")"
  rm -rf "$T"
}

# ── T1 (mode=stale): the fix's core repro — new-daemon is off the wide
#    sweep's radar, but the freshness re-probe confirms it is STILL STALE ──
run_block stale
[ "$RUN_RC" -eq 0 ] && ok "T1 block runs clean (rc=0; continue-based halt, BD state is the signal)" \
  || nok "T1 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep "delivery:failed" >/dev/null \
  && ok "T1 delivery IS held (delivery:failed set) — confirmed-stale daemon correctly blocks (the bug this fix closes)" \
  || nok "T1 delivery was wrongly NOT held for a confirmed-stale daemon" "$BD_CALLS"
echo "$BD_CALLS" | grep "Delivery HALTED" >/dev/null \
  && ok "T1 HALT comment posted" \
  || nok "T1 missing HALT comment" "$BD_CALLS"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] \
  && ok "T1 rig-wide baseline marker did NOT advance — new branch correctly did not exonerate" \
  || nok "T1 baseline marker unexpectedly changed" "want(unchanged)=$EXPECT_C0 got=$BASELINE_AFTER"
echo "$LOG_OUT" | grep "freshness re-probe" >/dev/null \
  && ok "T1 log shows the freshness re-probe ran" \
  || nok "T1 log does not mention the freshness re-probe" "$LOG_OUT"

# ── T2 (mode=fresh): control — re-probe confirms new-daemon is ALREADY
#    fresh (restarted via some other path) → must exonerate, like before ──
run_block fresh
[ "$RUN_RC" -eq 0 ] && ok "T2 block runs clean (rc=0)" || nok "T2 rc" "rc=$RUN_RC log=[$LOG_OUT]"
echo "$BD_CALLS" | grep "delivery:failed" >/dev/null \
  && nok "T2 delivery WAS held even though the re-probe confirmed it fresh" "$BD_CALLS" \
  || ok "T2 delivery is NOT held (re-probe positively confirmed fresh)"
echo "$BD_CALLS" | grep "Delivery HALTED" >/dev/null \
  && nok "T2 a HALT comment was wrongly posted" "$BD_CALLS" \
  || ok "T2 no HALT comment posted"
echo "$GC_CALLS" | grep "session nudge mayor" >/dev/null \
  && ok "T2 mayor is still nudged — invariant (b): the gap stays visible/charged" \
  || nok "T2 missing mayor nudge" "$GC_CALLS"
[ "$BASELINE_AFTER" = "$EXPECT_C2" ] \
  && ok "T2 rig-wide baseline marker ADVANCED to POST_DEPLOY_SHA" \
  || nok "T2 baseline marker did not advance" "want=$EXPECT_C2 got=$BASELINE_AFTER"

# ── T3 (mode=unparseable): control — the re-probe itself produced nothing
#    parseable (crash/timeout stand-in) → third state, must NOT be treated
#    as fresh ──────────────────────────────────────────────────────────────
run_block unparseable
[ "$RUN_RC" -eq 0 ] && ok "T3 block runs clean (rc=0; continue-based halt, BD state is the signal)" \
  || nok "T3 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep "delivery:failed" >/dev/null \
  && ok "T3 delivery IS held (unparseable re-probe correctly defaults to NOT fresh)" \
  || nok "T3 delivery was wrongly NOT held on an unparseable re-probe" "$BD_CALLS"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] \
  && ok "T3 rig-wide baseline marker did NOT advance" \
  || nok "T3 baseline marker unexpectedly changed" "want(unchanged)=$EXPECT_C0 got=$BASELINE_AFTER"

echo ""
echo "story-delivery guarded-restart freshness re-probe tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
