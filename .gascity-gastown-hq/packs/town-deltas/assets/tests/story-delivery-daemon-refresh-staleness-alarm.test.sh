#!/usr/bin/env bash
# story-delivery-daemon-refresh-staleness-alarm.test.sh — regression test for
# ga-gjum0y invariant (c) (extracts the real Step 0a block from
# story-delivery.sh, no duplication — same technique as
# story-delivery-daemon-refresh-perdaemon-baseline.test.sh).
#
# THE BUG (see ga-gjum0y): whatsapp_automation's daemon-refresh-baseline/
# whatsapp_automation.sha sat frozen for 5 days (a scheduled-job installation
# gap kept forcing VERDICT=JOB_NOT_INSTALLED on every deploy, so the rig-wide
# marker never advanced) with zero alarm — the only place that would have
# noticed, story-delivery.sh's own Step 5b, only runs when a story happens to
# be queued for delivery for that specific rig, and none was in the relevant
# window. A human found it by hand.
#
# THE FIX: a new Step 0a runs once per sweep, unconditionally (not gated on
# any story being queued), scans every *.sha this mechanism has ever written,
# and nudges the Mayor the first time one is found stuck past
# DAEMON_REFRESH_STALE_DAYS (default 2) — deduped by the SHA VALUE it is
# stuck at (a marker file, "<rig>.staleness-alarmed"), so a permanently-stuck
# baseline alarms once, not every 5 minutes forever, but a baseline that
# later gets stuck on a DIFFERENT sha is a new episode and alarms again.
#
# T1: baseline fresh (age < threshold) → no alarm, no marker written.
# T2: baseline stale, no pre-existing alarm marker → alarm fires once, marker
#     records the stuck sha.
# T3: baseline stale, already alarmed for this EXACT sha → no duplicate alarm.
# T4: baseline stale, previously alarmed for a DIFFERENT (older) sha → new
#     episode, alarms again, marker updated.
# T5: DRY_RUN=1, baseline stale → no gc nudge call, no marker written
#     (dry run must be side-effect-free).
# T6: no *.sha file exists yet at all (fresh city, the write-back side of this
#     mechanism has never run for any rig) → the glob matches nothing; must be
#     a clean no-op (no crash under this script's set -euo pipefail, no false
#     alarm) — the realistic day-to-day shape the [ -f ] guard exists for.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the Step 0a block (from its header up to, but excluding, Step 0) —
# identical technique to story-delivery-daemon-refresh-perdaemon-baseline.test.sh.
BLOCK="$(sed -n '/Step 0a: daemon-refresh baseline staleness alarm/,/# ── Step 0: Read runbook file/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 0a block"; exit 1; }

# run_block <age_days> <pre_existing_marker_sha_or_empty> <dry_run> [<no_sha_file:1>]
# Seeds one rig's *.sha at the given age, optionally pre-seeds its
# .staleness-alarmed marker, runs the real Step 0a block, and captures what it
# did. Sets globals: GC_CALLS (each `gc ...` invocation, one per line),
# MARKER_AFTER (alarm marker content after running), LOG_CONTENT (log/warn
# lines), SHA_VALUE (the rig's seeded sha, for assertions).
run_block() {
  local age_days="$1" pre_marker="${2:-}" dry_run="${3:-0}" no_sha_file="${4:-0}"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"
  local BASE_DIR="$GC_CITY/.gc/runtime/daemon-refresh-baseline"
  mkdir -p "$BASE_DIR"

  SHA_VALUE="deadbeef$(date +%s)0000000000000000000000000"
  SHA_VALUE="${SHA_VALUE:0:40}"
  if [ "$no_sha_file" = "1" ]; then
    : # deliberately leave $BASE_DIR with zero *.sha files — the T6 shape.
  else
    printf '%s' "$SHA_VALUE" > "$BASE_DIR/whatsapp_automation.sha"
    # Backdate the file's mtime by age_days (BSD `touch -v`, matches the
    # `stat -f` idiom the real block itself uses on this platform).
    local PAST; PAST="$(date -v-"${age_days}"d +%Y%m%d%H%M.%S)"
    touch -t "$PAST" "$BASE_DIR/whatsapp_automation.sha"
  fi
  if [ -n "$pre_marker" ]; then
    printf '%s' "$pre_marker" > "$BASE_DIR/whatsapp_automation.staleness-alarmed"
  fi

  LOG_FILE="$T/log.log"
  GC_CALLS_FILE="$T/gc-calls.log"
  gc()   { echo "$*" >> "$GC_CALLS_FILE"; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }
  export -f gc log warn err 2>/dev/null || true

  local DRY_RUN="$dry_run"

  ( for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1

  GC_CALLS="$(cat "$GC_CALLS_FILE" 2>/dev/null || true)"
  LOG_CONTENT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  MARKER_AFTER="$(cat "$BASE_DIR/whatsapp_automation.staleness-alarmed" 2>/dev/null || true)"
  rm -rf "$T"
}

# ── T1: fresh baseline (age 0 days) → no alarm, no marker ────────────────────
run_block 0 "" 0
[ -z "$GC_CALLS" ] \
  && ok "T1 fresh baseline: no gc nudge call" \
  || nok "T1 fresh baseline nudge" "GC_CALLS=[$GC_CALLS]"
[ -z "$MARKER_AFTER" ] \
  && ok "T1 fresh baseline: no alarm marker written" \
  || nok "T1 fresh baseline marker" "MARKER_AFTER=[$MARKER_AFTER]"

# ── T2: stale baseline (age 5 days ≥ default threshold 2), no prior marker ───
run_block 5 "" 0
echo "$GC_CALLS" | grep -q "session nudge mayor" \
  && ok "T2 stale baseline (5d): Mayor nudged" \
  || nok "T2 stale baseline nudge" "GC_CALLS=[$GC_CALLS]"
echo "$GC_CALLS" | grep -q "$SHA_VALUE" \
  && ok "T2 nudge names the stuck sha" \
  || nok "T2 nudge content" "GC_CALLS=[$GC_CALLS]"
[ "$MARKER_AFTER" = "$SHA_VALUE" ] \
  && ok "T2 alarm marker records the stuck sha" \
  || nok "T2 marker" "got '$MARKER_AFTER' want '$SHA_VALUE'"

# ── T3: stale baseline, already alarmed for this EXACT sha → no duplicate ────
# run_block computes a fresh SHA_VALUE seeded into the file; capture it first,
# then re-run with that same value pre-seeded as the marker.
run_block 5 "" 0
FIRST_SHA="$SHA_VALUE"
T="$(mktemp -d)"
GC_CITY="$T/city"
BASE_DIR="$GC_CITY/.gc/runtime/daemon-refresh-baseline"
mkdir -p "$BASE_DIR"
printf '%s' "$FIRST_SHA" > "$BASE_DIR/whatsapp_automation.sha"
PAST="$(date -v-5d +%Y%m%d%H%M.%S)"
touch -t "$PAST" "$BASE_DIR/whatsapp_automation.sha"
printf '%s' "$FIRST_SHA" > "$BASE_DIR/whatsapp_automation.staleness-alarmed"
LOG_FILE="$T/log.log"; GC_CALLS_FILE="$T/gc-calls.log"
gc()   { echo "$*" >> "$GC_CALLS_FILE"; }
log()  { echo "$*" >> "$LOG_FILE"; }
warn() { echo "WARN: $*" >> "$LOG_FILE"; }
err()  { echo "ERR: $*" >> "$LOG_FILE"; }
export -f gc log warn err 2>/dev/null || true
DRY_RUN=0
( for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1
GC_CALLS="$(cat "$GC_CALLS_FILE" 2>/dev/null || true)"
rm -rf "$T"
[ -z "$GC_CALLS" ] \
  && ok "T3 already-alarmed-for-this-sha: no duplicate nudge" \
  || nok "T3 dedup" "GC_CALLS=[$GC_CALLS]"

# ── T4: stale baseline, previously alarmed for a DIFFERENT sha → re-alarms ───
run_block 5 "some-older-already-resolved-sha-0000000" 0
echo "$GC_CALLS" | grep -q "session nudge mayor" \
  && ok "T4 new stuck sha (different from the old marker): alarms again" \
  || nok "T4 new episode" "GC_CALLS=[$GC_CALLS]"
[ "$MARKER_AFTER" = "$SHA_VALUE" ] \
  && ok "T4 marker updated to the new stuck sha" \
  || nok "T4 marker updated" "got '$MARKER_AFTER' want '$SHA_VALUE'"

# ── T5: DRY_RUN=1, stale baseline → side-effect-free ─────────────────────────
run_block 5 "" 1
[ -z "$GC_CALLS" ] \
  && ok "T5 DRY_RUN=1: no gc nudge call" \
  || nok "T5 dry-run nudge" "GC_CALLS=[$GC_CALLS]"
[ -z "$MARKER_AFTER" ] \
  && ok "T5 DRY_RUN=1: no alarm marker written" \
  || nok "T5 dry-run marker" "MARKER_AFTER=[$MARKER_AFTER]"
echo "$LOG_CONTENT" | grep -qi "has not advanced" \
  && ok "T5 DRY_RUN=1 still WARNs (visible, just no side effect)" \
  || nok "T5 dry-run warn" "LOG_CONTENT=[$LOG_CONTENT]"

# ── T6: no *.sha file exists yet (empty glob) → clean no-op, no crash ────────
run_block 5 "" 0 1
[ -z "$GC_CALLS" ] \
  && ok "T6 no baseline files yet: no false alarm claimed" \
  || nok "T6 empty-glob no-alarm" "GC_CALLS=[$GC_CALLS]"
[ -z "$MARKER_AFTER" ] \
  && ok "T6 no baseline files yet: no marker written" \
  || nok "T6 empty-glob marker" "MARKER_AFTER=[$MARKER_AFTER]"

echo ""
echo "story-delivery baseline staleness alarm tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
