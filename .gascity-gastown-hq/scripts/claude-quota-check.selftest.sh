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
SUT="$HERE/claude-quota-check.sh"
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
# CASE 3: ACTIVE session limit (reset 1:00pm > now 12:00) → LIMITED (exit 2)
# ---------------------------------------------------------------------------
: > "$FIX/proj-b/session-active.jsonl"
exhaust_line -600 "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-active.jsonl"
run bash "$SUT" --json
if [ "$RC" = "2" ] && [ "$(printf '%s' "$OUT" | jq -r '.limited')" = "true" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.scope')" = "session" ]; then
  ok "active session limit → limited (exit 2, scope=session)"
else
  bad "active session limit" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,scope}' 2>/dev/null)"
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
# CASE 5: ACTIVE weekly limit (reset Jun 12 8pm) → LIMITED + weekly.active
# ---------------------------------------------------------------------------
: > "$FIX/proj-b/weekly-active.jsonl"
exhaust_line -3600 "You've hit your weekly limit · resets Jun 12 at 8pm (America/Sao_Paulo)" >> "$FIX/proj-b/weekly-active.jsonl"
run bash "$SUT" --json
if [ "$RC" = "2" ] && [ "$(printf '%s' "$OUT" | jq -r '.scope')" = "weekly" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.weekly.active')" = "true" ]; then
  ok "active weekly limit → limited (exit 2, scope=weekly, weekly.active=true)"
else
  bad "active weekly limit" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,scope,weekly}' 2>/dev/null)"
fi
rm -f "$FIX/proj-b/weekly-active.jsonl"

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
# CASE 7: --line mode emits a single QUOTA: line and is exit-coded
# ---------------------------------------------------------------------------
: > "$FIX/proj-b/session-active2.jsonl"
exhaust_line -600 "You've hit your session limit · resets 1:00pm (America/Sao_Paulo)" >> "$FIX/proj-b/session-active2.jsonl"
run bash "$SUT" --line
if [ "$RC" = "2" ] && printf '%s' "$OUT" | grep -q '^QUOTA: LIMITED (session)'; then
  ok "--line limited → 'QUOTA: LIMITED (session)…' (exit 2)"
else
  bad "--line limited" "rc=$RC out=$OUT"
fi
rm -f "$FIX/proj-b/session-active2.jsonl"

# ---------------------------------------------------------------------------
# CASE 8: mixed — expired session but ACTIVE weekly → limited via weekly
# ---------------------------------------------------------------------------
: > "$FIX/proj-b/mixed.jsonl"
exhaust_line -3600 "You've hit your session limit · resets 11:30am (America/Sao_Paulo)" >> "$FIX/proj-b/mixed.jsonl"
exhaust_line -3000 "You've hit your weekly limit · resets Jun 12 at 8pm (America/Sao_Paulo)" >> "$FIX/proj-b/mixed.jsonl"
run bash "$SUT" --json
if [ "$RC" = "2" ] && [ "$(printf '%s' "$OUT" | jq -r '.scope')" = "weekly" ]; then
  ok "expired-session + active-weekly → limited via weekly"
else
  bad "mixed expired-session/active-weekly" "rc=$RC out=$(printf '%s' "$OUT" | jq -c '{limited,scope,weekly}' 2>/dev/null)"
fi
rm -f "$FIX/proj-b/mixed.jsonl"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
