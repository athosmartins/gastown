#!/bin/bash
# Selftest for claude-quota-check.sh (ga-wjlv9).
# Builds synthetic transcript fixtures and asserts the verdict on the paths
# that live data cannot exercise (we are usually NOT limited): active session
# limit, active weekly limit, already-reset (expired) limit, and the real
# token-window sum + budget %.
#
# Deterministic: pins "now" and the transcript dir via env, and scans all
# fixture files (CLAUDE_QUOTA_SCAN_ALL=1) so mtimes don't matter.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${QUOTA_SUT:-/tmp/claude-quota-check-v2.sh}"
TZ_RESET="America/Sao_Paulo"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n     %s\n' "$1" "$2"; }

# Pinned "now" = 2026-06-11 12:00:00 in America/Sao_Paulo (UTC-3, no DST).
NOW=$(TZ="$TZ_RESET" date -j -f "%Y-%m-%d %H:%M:%S" "2026-06-11 12:00:00" +%s 2>/dev/null)
if [ -z "$NOW" ]; then echo "FATAL: cannot compute pinned NOW (date semantics?)"; exit 1; fi

# UTC ISO timestamp for (NOW + offset_seconds).
iso() { date -u -r "$((NOW + $1))" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null; }

FIX="$(mktemp -d /tmp/quota-selftest.XXXXXX)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/proj-a" "$FIX/proj-b"

usage_line() { # ts_offset input output cache_create cache_read
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-opus-4-8","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
    "$(iso "$1")" "$2" "$3" "$4" "$5"
}
exhaust_line() { # ts_offset  full_text
  printf '{"type":"assistant","isApiErrorMessage":true,"timestamp":"%s","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' \
    "$(iso "$1")" "$2"
}

run() { # extra-env... -- args : sets global OUT, RC
  OUT=$(env CLAUDE_PROJECTS_DIR="$FIX" CLAUDE_QUOTA_NOW="$NOW" CLAUDE_QUOTA_TZ="$TZ_RESET" \
            CLAUDE_QUOTA_SCAN_ALL=1 "$@" 2>/dev/null)
  RC=$?
}

echo "claude-quota-check selftest (pinned now=$NOW / 2026-06-11 12:00 $TZ_RESET)"

# ---------------------------------------------------------------------------
# CASE 1: clean transcripts, no exhaustion → NOT limited (exit 0)
# ---------------------------------------------------------------------------
: > "$FIX/proj-a/clean.jsonl"
usage_line -3600 10 100 5 1000 >> "$FIX/proj-a/clean.jsonl"   # in 5h window
usage_line -600  20 200 0  500  >> "$FIX/proj-a/clean.jsonl"   # in window
run bash "$SUT" --json
if [ "$RC" = "0" ] && [ "$(printf '%s' "$OUT" | jq -r '.limited')" = "false" ]; then
  ok "clean transcripts → not limited (exit 0)"
else
  bad "clean transcripts → not limited" "rc=$RC limited=$(printf '%s' "$OUT" | jq -r '.limited' 2>/dev/null)"
fi

# token-window sum: billable = input+output+cache_creation = (10+100+5)+(20+200+0)=335
BILL=$(printf '%s' "$OUT" | jq -r '.window_5h.billable_tokens')
if [ "$BILL" = "335" ]; then ok "billable token sum = 335"; else bad "billable token sum" "got $BILL want 335"; fi
CR=$(printf '%s' "$OUT" | jq -r '.window_5h.cache_read_tokens')
if [ "$CR" = "1500" ]; then ok "cache_read summed separately = 1500 (excluded from billable)"; else bad "cache_read sum" "got $CR want 1500"; fi

# ---------------------------------------------------------------------------
# CASE 2: token outside the 5h window is excluded
# ---------------------------------------------------------------------------
: > "$FIX/proj-b/old.jsonl"
usage_line -21600 9999 9999 9999 9999 >> "$FIX/proj-b/old.jsonl"  # 6h ago, outside window
run bash "$SUT" --json
BILL2=$(printf '%s' "$OUT" | jq -r '.window_5h.billable_tokens')
if [ "$BILL2" = "335" ]; then ok "out-of-window tokens excluded (still 335)"; else bad "out-of-window exclusion" "got $BILL2 want 335"; fi
rm -f "$FIX/proj-b/old.jsonl"

# ---------------------------------------------------------------------------
# CASE 3 (ga-burst): SINGLE recent session-limit event → NOT limited (sporadic).
#   A borderline account fires occasional 429s (~6/hour) but the account is NOT
#   hard-exhausted. One event must NOT latch LIMITED for 20 minutes.
#   Expected: exit 0, limited=false, session_burst.sporadic=true.
# ---------------------------------------------------------------------------
: > "$FIX/proj-b/session-active.jsonl"
exhaust_line -600 "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-active.jsonl"
run bash "$SUT" --json
if [ "$RC" = "0" ] && [ "$(printf '%s' "$OUT" | jq -r '.limited')" = "false" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.session_burst.sporadic')" = "true" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.session_burst.count')" = "0" ]; then
  ok "single recent 429 → NOT limited (sporadic, exit 0, burst.count=0 < threshold 2) (ga-burst)"
else
  bad "single recent 429 should be sporadic" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,scope,session_burst}' 2>/dev/null)"
fi
# CASE 3b (ga-burst): BURST of ≥2 session-limit events in 5-min window → LIMITED (exit 2)
#   Two 429 events BOTH within 300s = real sustained exhaustion.
#   (The existing -600 event is outside the 300s window; add two fresh ones.)
exhaust_line -240 "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-active.jsonl"
exhaust_line -60  "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-active.jsonl"
run bash "$SUT" --json
if [ "$RC" = "2" ] && [ "$(printf '%s' "$OUT" | jq -r '.limited')" = "true" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.scope')" = "session" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.session_burst.count')" = "2" ]; then
  ok "burst of 2 recent 429s (both in 300s window) → LIMITED (exit 2, scope=session, burst.count=2) (ga-burst)"
else
  bad "burst of 2 events should be limited" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,scope,session_burst}' 2>/dev/null)"
fi
# CASE 3c (ga-burst): BURST_MIN_COUNT=1 restores old single-event latch (escape hatch)
OUT=$(env CLAUDE_PROJECTS_DIR="$FIX" CLAUDE_QUOTA_NOW="$NOW" CLAUDE_QUOTA_TZ="$TZ_RESET" \
          CLAUDE_QUOTA_SCAN_ALL=1 CLAUDE_QUOTA_BURST_MIN_COUNT=1 \
          bash "$SUT" --json 2>/dev/null); RC=$?
if [ "$RC" = "2" ] && [ "$(printf '%s' "$OUT" | jq -r '.limited')" = "true" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.scope')" = "session" ]; then
  ok "CLAUDE_QUOTA_BURST_MIN_COUNT=1 → single-event latch restored (exit 2) (ga-burst)"
else
  bad "BURST_MIN_COUNT=1 should restore single-event latch" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,scope}' 2>/dev/null)"
fi
rm -f "$FIX/proj-b/session-active.jsonl"

# ---------------------------------------------------------------------------
# CASE 4: EXPIRED session limit (reset 11:30am < now 12:00) → NOT limited
#         (the window already reset — the broken time-fiction would still
#          report "limited"; ground truth correctly clears it.)
# ---------------------------------------------------------------------------
: > "$FIX/proj-b/session-expired.jsonl"
exhaust_line -3600 "You've hit your session limit · resets 11:30am (America/Sao_Paulo)" >> "$FIX/proj-b/session-expired.jsonl"
run bash "$SUT" --json
if [ "$RC" = "0" ] && [ "$(printf '%s' "$OUT" | jq -r '.limited')" = "false" ]; then
  ok "expired session limit (past reset) → not limited (exit 0)"
else
  bad "expired session limit" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,scope,reset_time_text}' 2>/dev/null)"
fi
rm -f "$FIX/proj-b/session-expired.jsonl"

# ---------------------------------------------------------------------------
# CASE 5 (ga-ot735, REVISED): ACTIVE weekly limit, NO active session →
#   ADVISORY by default: NOT hard-limited (exit 0) but weekly.active=true.
#   This is the exact false-pause the fix kills: the old contract was exit 2.
# ---------------------------------------------------------------------------
: > "$FIX/proj-b/weekly-active.jsonl"
exhaust_line -3600 "You've hit your weekly limit · resets Jun 12 at 8pm (America/Sao_Paulo)" >> "$FIX/proj-b/weekly-active.jsonl"
run bash "$SUT" --json
if [ "$RC" = "0" ] && [ "$(printf '%s' "$OUT" | jq -r '.limited')" = "false" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.weekly.active')" = "true" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.weekly.advisory')" = "true" ]; then
  ok "weekly-only limit → ADVISORY: not hard-limited (exit 0), weekly.active+advisory=true (ga-ot735)"
else
  bad "weekly-only advisory" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,scope,weekly}' 2>/dev/null)"
fi

# CASE 5b: same fixture, CLAUDE_QUOTA_WEEKLY_HARD=1 → LEGACY hard pause (exit 2)
OUT=$(env CLAUDE_PROJECTS_DIR="$FIX" CLAUDE_QUOTA_NOW="$NOW" CLAUDE_QUOTA_TZ="$TZ_RESET" \
          CLAUDE_QUOTA_SCAN_ALL=1 CLAUDE_QUOTA_WEEKLY_HARD=1 \
          bash "$SUT" --json 2>/dev/null); RC=$?
if [ "$RC" = "2" ] && [ "$(printf '%s' "$OUT" | jq -r '.scope')" = "weekly" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.weekly.hard')" = "true" ]; then
  ok "weekly + CLAUDE_QUOTA_WEEKLY_HARD=1 → legacy hard pause (exit 2, scope=weekly)"
else
  bad "weekly hard-mode opt-in" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,scope,weekly}' 2>/dev/null)"
fi
rm -f "$FIX/proj-b/weekly-active.jsonl"

# ---------------------------------------------------------------------------
# CASE 5c (ga-ot735 + ga-burst): SESSION burst AND weekly active → SESSION WINS.
#   Burst (≥2 events in 5-min window) + weekly → hard pause on session scope.
#   SESSION reset is the headline (not the days-out weekly one); weekly.active
#   still reported.
# ---------------------------------------------------------------------------
: > "$FIX/proj-b/both-active.jsonl"
exhaust_line -240  "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)"        >> "$FIX/proj-b/both-active.jsonl"
exhaust_line -60   "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)"        >> "$FIX/proj-b/both-active.jsonl"
exhaust_line -3000 "You've hit your weekly limit · resets Jun 12 at 8pm (America/Sao_Paulo)"  >> "$FIX/proj-b/both-active.jsonl"
run bash "$SUT" --json
if [ "$RC" = "2" ] && [ "$(printf '%s' "$OUT" | jq -r '.scope')" = "session" ] \
   && printf '%s' "$OUT" | jq -e '.reset_time_text | test("1:00pm")' >/dev/null 2>&1 \
   && [ "$(printf '%s' "$OUT" | jq -r '.weekly.active')" = "true" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.session_burst.count')" = "2" ]; then
  ok "session-burst(2)+weekly both active → session wins (exit 2, scope=session, session reset headline, burst.count=2) (ga-burst+ga-ot735)"
else
  bad "session burst beats weekly" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,scope,reset_time_text,weekly,session_burst}' 2>/dev/null)"
fi
rm -f "$FIX/proj-b/both-active.jsonl"

# ---------------------------------------------------------------------------
# CASE 9 (ga-z0n9f): STALE session latch — freshness guard clears it (exit 0)
#   Session limit event 25 min ago, stated reset still 60 min out (future), but
#   no fresh re-log in 25 min > 20 min threshold → defer-without-spawn scenario.
#   Expected: exit 0, limited=false, session_stale=true.
# ---------------------------------------------------------------------------
: > "$FIX/proj-b/session-stale.jsonl"
exhaust_line -1500 "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-stale.jsonl"
run bash "$SUT" --json
if [ "$RC" = "0" ] && [ "$(printf '%s' "$OUT" | jq -r '.limited')" = "false" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.session_stale')" = "true" ]; then
  ok "stale session latch (25 min old > 20 min threshold) → freshness guard clears latch (exit 0, session_stale=true) (ga-z0n9f)"
else
  bad "stale session latch freshness guard" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,session_stale,session_last_event_secs_ago}' 2>/dev/null)"
fi
rm -f "$FIX/proj-b/session-stale.jsonl"

# CASE 9b (ga-z0n9f + ga-burst): FRESH session latch (5 min old < 20 min threshold).
#   With ga-burst: a single fresh event is SPORADIC → NOT limited (burst.count=0 < 2).
#   A sustained burst (2 events in 5min) IS limited even when fresh.
: > "$FIX/proj-b/session-fresh.jsonl"
exhaust_line -300 "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-fresh.jsonl"
run bash "$SUT" --json
if [ "$RC" = "0" ] && [ "$(printf '%s' "$OUT" | jq -r '.limited')" = "false" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.session_stale')" = "false" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.session_burst.sporadic')" = "true" ]; then
  ok "single fresh event (5 min, < burst threshold 2) → sporadic, NOT limited (exit 0) (ga-burst supersedes ga-z0n9f single-event)"
else
  bad "single fresh event should be sporadic not limited" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,session_stale,session_burst}' 2>/dev/null)"
fi
# 9b-burst: two fresh events within 300s → LIMITED despite freshness
exhaust_line -60 "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-fresh.jsonl"
run bash "$SUT" --json
if [ "$RC" = "2" ] && [ "$(printf '%s' "$OUT" | jq -r '.limited')" = "true" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.session_burst.count')" = "2" ]; then
  ok "2 fresh events in burst window → LIMITED (exit 2, burst.count=2) (ga-burst)"
else
  bad "2 fresh events should be limited" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,session_burst}' 2>/dev/null)"
fi
rm -f "$FIX/proj-b/session-fresh.jsonl"

# CASE 9c (ga-z0n9f + ga-burst): FRESHNESS_SECS=0 disables freshness guard.
#   With ga-burst: a SINGLE stale event + freshness disabled → still sporadic (NOT limited).
#   To be limited, must cross burst threshold regardless of freshness setting.
: > "$FIX/proj-b/session-stale2.jsonl"
exhaust_line -1500 "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-stale2.jsonl"
OUT=$(env CLAUDE_PROJECTS_DIR="$FIX" CLAUDE_QUOTA_NOW="$NOW" CLAUDE_QUOTA_TZ="$TZ_RESET" \
          CLAUDE_QUOTA_SCAN_ALL=1 CLAUDE_QUOTA_FRESHNESS_SECS=0 \
          bash "$SUT" --json 2>/dev/null); RC=$?
if [ "$RC" = "0" ] && [ "$(printf '%s' "$OUT" | jq -r '.limited')" = "false" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.session_stale')" = "false" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.session_burst.sporadic')" = "true" ]; then
  ok "single stale event + FRESHNESS_SECS=0: burst gate still applies → sporadic (exit 0) (ga-burst+ga-z0n9f)"
else
  bad "single stale event freshness-disabled should be sporadic" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,session_stale,session_burst}' 2>/dev/null)"
fi
# 9c-burst: burst (2 events stale) + freshness disabled → LIMITED (burst wins)
exhaust_line -1400 "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-stale2.jsonl"
OUT=$(env CLAUDE_PROJECTS_DIR="$FIX" CLAUDE_QUOTA_NOW="$NOW" CLAUDE_QUOTA_TZ="$TZ_RESET" \
          CLAUDE_QUOTA_SCAN_ALL=1 CLAUDE_QUOTA_FRESHNESS_SECS=0 \
          bash "$SUT" --json 2>/dev/null); RC=$?
# Note: both events are outside the 300s burst window (1500s and 1400s ago), so
# SESSION_BURST_COUNT=0 → sporadic. Freshness check: last event=1400s ago < 1200s threshold
# BUT freshness is disabled. Burst gate applies: burst_count=0 < 2 → sporadic.
if [ "$RC" = "0" ] && [ "$(printf '%s' "$OUT" | jq -r '.limited')" = "false" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.session_burst.sporadic')" = "true" ]; then
  ok "2 stale events outside burst window + freshness disabled → sporadic (exit 0, burst.count=0) (ga-burst)"
else
  bad "2 stale-old events should be sporadic (outside burst window)" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,session_burst}' 2>/dev/null)"
fi
rm -f "$FIX/proj-b/session-stale2.jsonl"

# CASE 9d (ga-z0n9f + ga-burst): mixed stale+fresh events.
#   One stale event (25 min, outside 300s burst window) + one fresh event (5 min, inside window).
#   Burst window count = 1 (only the fresh one is within 300s) < threshold 2 → sporadic.
#   Freshness guard: last event = 300s ago < 1200s threshold → guard does not fire.
#   Combined result: sporadic (NOT limited).
: > "$FIX/proj-b/session-mixed-age.jsonl"
exhaust_line -1500 "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-mixed-age.jsonl"
exhaust_line -300  "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-mixed-age.jsonl"
run bash "$SUT" --json
if [ "$RC" = "0" ] && [ "$(printf '%s' "$OUT" | jq -r '.limited')" = "false" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.session_stale')" = "false" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.session_burst.sporadic')" = "true" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.session_burst.count')" = "1" ]; then
  ok "stale+single-fresh events: burst.count=1 < 2 → sporadic (exit 0, not stale, not limited) (ga-burst+ga-z0n9f)"
else
  bad "stale+single-fresh: should be sporadic (burst.count=1)" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,session_stale,session_burst}' 2>/dev/null)"
fi
# 9d-burst: add a SECOND fresh event → burst.count=2 → LIMITED
exhaust_line -60   "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-mixed-age.jsonl"
run bash "$SUT" --json
if [ "$RC" = "2" ] && [ "$(printf '%s' "$OUT" | jq -r '.limited')" = "true" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.session_burst.count')" = "2" ]; then
  ok "stale+2-fresh events: burst.count=2 → LIMITED (exit 2) — genuine sustained exhaustion (ga-burst)"
else
  bad "stale+2-fresh should be limited (burst.count=2)" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,session_burst}' 2>/dev/null)"
fi
rm -f "$FIX/proj-b/session-mixed-age.jsonl"

# ---------------------------------------------------------------------------
# CASE 6: budget % computed when CLAUDE_QUOTA_BUDGET_BILLABLE set
#         billable=335, budget=1000 → 33.5%
# ---------------------------------------------------------------------------
OUT=$(env CLAUDE_PROJECTS_DIR="$FIX" CLAUDE_QUOTA_NOW="$NOW" CLAUDE_QUOTA_TZ="$TZ_RESET" \
          CLAUDE_QUOTA_SCAN_ALL=1 CLAUDE_QUOTA_BUDGET_BILLABLE=1000 \
          bash "$SUT" --json 2>/dev/null)
PCT=$(printf '%s' "$OUT" | jq -r '.window_5h.pct_of_budget')
if [ "$PCT" = "33.5" ]; then ok "budget % computed (335/1000 = 33.5%)"; else bad "budget %" "got $PCT want 33.5"; fi

# ---------------------------------------------------------------------------
# CASE 7: --line mode emits a single QUOTA: line and is exit-coded.
#   ga-burst: single event is sporadic → exit 0, line says "sporadic".
#   burst of 2 events → LIMITED (exit 2), line says "LIMITED (session)".
# ---------------------------------------------------------------------------
: > "$FIX/proj-b/session-active2.jsonl"
exhaust_line -600 "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-active2.jsonl"
run bash "$SUT" --line
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q '^QUOTA: not limited — sporadic'; then
  ok "--line single sporadic → 'QUOTA: not limited — sporadic…' (exit 0) (ga-burst)"
else
  bad "--line single sporadic" "rc=$RC out=$OUT"
fi
# add TWO events within burst window to cross threshold (the existing -600 is outside 300s)
exhaust_line -240 "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-active2.jsonl"
exhaust_line -60  "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-active2.jsonl"
run bash "$SUT" --line
if [ "$RC" = "2" ] && printf '%s' "$OUT" | grep -q '^QUOTA: LIMITED (session)'; then
  ok "--line burst(2) → 'QUOTA: LIMITED (session)…' (exit 2) (ga-burst)"
else
  bad "--line burst limited" "rc=$RC out=$OUT"
fi
rm -f "$FIX/proj-b/session-active2.jsonl"

# ---------------------------------------------------------------------------
# CASE 8 (ga-ot735, REVISED): EXPIRED session + ACTIVE weekly → ADVISORY.
#   The session limit already reset; only the multi-day weekly remains → with
#   the default soft policy this is NOT a hard pause (exit 0), weekly advisory.
#   (Old contract: limited via weekly, exit 2 — the exact days-long false pause.)
# ---------------------------------------------------------------------------
: > "$FIX/proj-b/mixed.jsonl"
exhaust_line -3600 "You've hit your session limit · resets 11:30am (America/Sao_Paulo)" >> "$FIX/proj-b/mixed.jsonl"
exhaust_line -3000 "You've hit your weekly limit · resets Jun 12 at 8pm (America/Sao_Paulo)" >> "$FIX/proj-b/mixed.jsonl"
run bash "$SUT" --json
if [ "$RC" = "0" ] && [ "$(printf '%s' "$OUT" | jq -r '.limited')" = "false" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.weekly.advisory')" = "true" ]; then
  ok "expired-session + active-weekly → advisory (exit 0, not paused) (ga-ot735)"
else
  bad "mixed expired-session/active-weekly" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,scope,weekly}' 2>/dev/null)"
fi
rm -f "$FIX/proj-b/mixed.jsonl"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
