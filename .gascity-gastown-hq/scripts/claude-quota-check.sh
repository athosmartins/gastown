#!/bin/bash
# claude-quota-check.sh — programmatic Claude quota status (ga-wjlv9)
#
# WHY THIS EXISTS
# ----------------
# On 2026-06-10 the Mayor spent a whole night diagnosing a gate stall as
# "Claude quota exhausted" WITHOUT being able to verify it — and was wrong
# (Athos confirmed only 22% of the window used). The pre-existing
# ~/.claude/scripts/check-credit-usage.sh was useless: it estimated the
# "window used %" purely from WALL-CLOCK time since a `current-session-start`
# file, with zero connection to real token consumption. A stale start file
# produced nonsense like "percent_remaining: -11300%". That fiction is exactly
# what made quota un-verifiable.
#
# THIS CHECK READS GROUND TRUTH INSTEAD.
# Claude Code records an ACTUAL quota-exhaustion event in the session
# transcript as an assistant message with `isApiErrorMessage: true` whose text
# is literally:
#     "You've hit your session limit · resets 6:50pm (America/Sao_Paulo)"
#     "You've hit your weekly limit · resets Jun 10 at 8pm (America/Sao_Paulo)"
# When Anthropic limits you, IT TELLS YOU, and Claude Code writes it to disk.
#
# Two signals:
#   A) GROUND TRUTH (high confidence): scan recent transcripts for an
#      exhaustion event whose reset time is still in the FUTURE. Present =>
#      genuinely limited (session or weekly). ABSENT => genuinely NOT limited.
#      This is the reliable binary the Mayor was missing.
#   B) TOKEN WINDOW (context): sum the REAL token usage recorded in transcripts
#      over the rolling 5h window (input + output + cache_creation; cache_read
#      excluded — it is the cheap/discounted part). This is real measured data,
#      not a time fiction. Reported as absolute numbers + an optional % against
#      a tunable budget.
#
# GUIDING STAR: next time, instead of "acho que é cota", the system says
# "no active exhaustion event + only N output tokens in last 5h → NOT quota,
# investigate the infra" — eliminating the false trail.
#
# USAGE
#   claude-quota-check.sh            # human-readable report; exit 2 if limited
#   claude-quota-check.sh --json     # machine-readable JSON
#   claude-quota-check.sh --line     # one compact line (for embedding in alerts)
#   claude-quota-check.sh --quiet    # no output; exit code only
# EXIT CODES
#   0 = NOT limited   2 = limited (active exhaustion event)   1 = internal error
#
# ENV OVERRIDES (also used by the selftest for determinism)
#   CLAUDE_PROJECTS_DIR        transcript root (default ~/.claude/projects)
#   CLAUDE_QUOTA_NOW           epoch seconds to treat as "now" (default: real now)
#   CLAUDE_QUOTA_TZ            tz for parsing reset clock times (default America/Sao_Paulo)
#   CLAUDE_QUOTA_SCAN_ALL      1 = scan every transcript (no mtime prefilter; tests)
#   CLAUDE_QUOTA_BUDGET_BILLABLE  if set (>0), report billable-token % of this budget
#                                 Calibrate once: note the billable number printed at
#                                 the moment a real exhaustion event fires; set that.
#
# Dependencies: bash, jq, find, grep, date (BSD/macOS date semantics).

set -uo pipefail

PROJ="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
TZ_RESET="${CLAUDE_QUOTA_TZ:-America/Sao_Paulo}"
NOW="${CLAUDE_QUOTA_NOW:-$(date +%s)}"
BUDGET="${CLAUDE_QUOTA_BUDGET_BILLABLE:-0}"
WINDOW_SEC=18000   # 5h rolling session window

MODE="human"
for arg in "$@"; do
  case "$arg" in
    --json)  MODE="json" ;;
    --line)  MODE="line" ;;
    --quiet) MODE="quiet" ;;
    --human) MODE="human" ;;
    --deep)  export CLAUDE_QUOTA_DEEP=1 ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    "") : ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "claude-quota-check: jq not found" >&2; exit 1; }

# epoch -> "next occurrence at/after a reference epoch" for a clock time today,
# respecting the reset timezone. Args: ref_epoch, clocktext (e.g. "6:50pm" / "8pm").
clock_to_epoch() {
  local ref="$1" clock="$2" day e
  day=$(TZ="$TZ_RESET" date -r "$ref" +%Y-%m-%d 2>/dev/null) || return 1
  # try "%I:%M%p" then "%I%p"
  e=$(TZ="$TZ_RESET" date -j -f "%Y-%m-%d %I:%M%p" "$day $clock" +%s 2>/dev/null) \
    || e=$(TZ="$TZ_RESET" date -j -f "%Y-%m-%d %I%p" "$day $clock" +%s 2>/dev/null) \
    || return 1
  # if that clock time already passed at the reference instant, it's the next day
  if [ "$e" -lt "$ref" ]; then e=$((e + 86400)); fi
  printf '%s' "$e"
}

# "Jun 10 at 8pm" (weekly) -> epoch in the current year, rolling forward if the
# parsed date landed before the event (year boundary). Args: ref_epoch, datetext.
date_to_epoch() {
  local ref="$1" dt="$2" year mon day clock e
  year=$(TZ="$TZ_RESET" date -r "$ref" +%Y 2>/dev/null) || return 1
  mon=$(printf '%s' "$dt" | awk '{print $1}')
  day=$(printf '%s' "$dt" | awk '{print $2}')
  clock=$(printf '%s' "$dt" | sed -E 's/.* at +//')
  e=$(TZ="$TZ_RESET" date -j -f "%Y %b %d %I:%M%p" "$year $mon $day $clock" +%s 2>/dev/null) \
    || e=$(TZ="$TZ_RESET" date -j -f "%Y %b %d %I%p" "$year $mon $day $clock" +%s 2>/dev/null) \
    || return 1
  # year-boundary guard: a Dec event referencing a Jan reset
  if [ "$e" -lt "$((ref - 86400))" ]; then
    e=$(TZ="$TZ_RESET" date -j -f "%Y %b %d %I:%M%p" "$((year + 1)) $mon $day $clock" +%s 2>/dev/null) \
      || e=$(TZ="$TZ_RESET" date -j -f "%Y %b %d %I%p" "$((year + 1)) $mon $day $clock" +%s 2>/dev/null) \
      || true
  fi
  printf '%s' "$e"
}

# ----- collect candidate transcript files -----
# Exhaustion-event scan: by default look back only 6h. This is sufficient to
# detect any CURRENTLY-ACTIVE limit because an active limit is continuously
# re-logged: the gate/pilot dispatchers spawn fresh sessions every ~2min and
# each one immediately re-hits the limit and writes a new "hit your … limit"
# line into its own fresh transcript. So an active session OR weekly limit
# always has a sub-6h event. The 8-day deep scan (--deep / CLAUDE_QUOTA_DEEP=1)
# is only for forensic "did we hit weekly earlier today" questions and is much
# slower (≈1GB of transcripts). --line/--quiet daemons use the fast default.
exhaust_files() {
  if [ "${CLAUDE_QUOTA_SCAN_ALL:-0}" = "1" ]; then
    find "$PROJ" -type f -name '*.jsonl' 2>/dev/null
  elif [ "${CLAUDE_QUOTA_DEEP:-0}" = "1" ]; then
    find "$PROJ" -type f -name '*.jsonl' -mtime -8 2>/dev/null
  else
    find "$PROJ" -type f -name '*.jsonl' -mmin -360 2>/dev/null
  fi
}
window_files() {
  if [ "${CLAUDE_QUOTA_SCAN_ALL:-0}" = "1" ]; then
    find "$PROJ" -type f -name '*.jsonl' 2>/dev/null
  else
    # mmin in minutes; window is 5h = 300min, +20min slack for clock skew
    find "$PROJ" -type f -name '*.jsonl' -mmin -320 2>/dev/null
  fi
}

# ----- Signal A: ground-truth exhaustion events -----
# Emit "scope<TAB>reset_text<TAB>event_iso" for each quota-hit line.
LIMITED=0
LIMIT_SCOPE="none"
LIMIT_RESET_TEXT=""
LIMIT_RESET_EPOCH=0
WEEKLY_ACTIVE=0
WEEKLY_RESET_TEXT=""

scan_exhaustion() {
  local f scope text reset ev_iso ev_epoch reset_epoch matches files
  files=$(exhaust_files)
  # guard: empty list would make `xargs grep` read stdin and hang interactively
  [ -n "$files" ] || return 0
  # single grep pass to find the (rare) files that contain an exhaustion line,
  # so jq is only invoked on those — not on every transcript.
  matches=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -l "hit your" 2>/dev/null)
  [ -n "$matches" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS=$'\t' read -r scope text ev_iso; do
      [ -n "$scope" ] || continue
      # event epoch from ISO timestamp (UTC). Strip fractional + Z.
      ev_epoch=$(iso_to_epoch "$ev_iso")
      [ -n "$ev_epoch" ] || ev_epoch="$NOW"
      reset=$(printf '%s' "$text" | sed -E 's/.*resets +//; s/ *\(.*\)$//')
      if [ "$scope" = "session" ]; then
        reset_epoch=$(clock_to_epoch "$ev_epoch" "$reset" 2>/dev/null) || reset_epoch=""
      else
        reset_epoch=$(date_to_epoch "$ev_epoch" "$reset" 2>/dev/null) || reset_epoch=""
      fi
      [ -n "$reset_epoch" ] || continue
      # active iff reset is still in the future relative to NOW
      if [ "$reset_epoch" -gt "$NOW" ]; then
        if [ "$scope" = "weekly" ]; then
          WEEKLY_ACTIVE=1
          WEEKLY_RESET_TEXT="$reset"
        fi
        # prefer the latest-resetting active event as the headline
        if [ "$reset_epoch" -gt "$LIMIT_RESET_EPOCH" ]; then
          LIMITED=1
          LIMIT_SCOPE="$scope"
          LIMIT_RESET_TEXT="$reset"
          LIMIT_RESET_EPOCH="$reset_epoch"
        fi
      fi
    done < <(grep -h "hit your" "$f" 2>/dev/null \
      | jq -r 'select(.isApiErrorMessage == true)
               | (.message.content[0].text // .message.content // "") as $t
               | select($t | type == "string")
               | select($t | test("hit your (session|weekly) limit"))
               | ((if ($t | test("weekly")) then "weekly" else "session" end))
                 + "\t" + $t + "\t" + (.timestamp // "")' 2>/dev/null)
  done < <(printf '%s\n' "$matches")
}

iso_to_epoch() {
  local iso="$1" clean
  [ -n "$iso" ] || { printf ''; return; }
  clean=$(printf '%s' "$iso" | sed -E 's/\.[0-9]+Z?$//; s/Z$//')
  # transcript timestamps are UTC
  TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null || printf ''
}

# ----- Signal B: real token usage over the rolling 5h window -----
TOK_INPUT=0; TOK_OUTPUT=0; TOK_CACHE_CREATE=0; TOK_CACHE_READ=0; TOK_MSGS=0; TOK_BILLABLE=0
scan_window() {
  local cutoff_iso json wfiles
  cutoff_iso=$(date -u -r "$((NOW - WINDOW_SEC))" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null)
  wfiles=$(window_files)
  [ -n "$wfiles" ] || { TOK_INPUT=0; TOK_OUTPUT=0; TOK_CACHE_CREATE=0; TOK_CACHE_READ=0; TOK_MSGS=0; TOK_BILLABLE=0; return 0; }
  json=$(printf '%s\n' "$wfiles" | tr '\n' '\0' \
    | xargs -0 grep -h '"usage"' 2>/dev/null \
    | jq -s --arg cutoff "$cutoff_iso" '
        [ .[]
          | select((.message.usage != null) and ((.timestamp // "") >= $cutoff))
          | .message.usage ]
        | { input:          (map(.input_tokens // 0)                | add // 0),
            output:         (map(.output_tokens // 0)               | add // 0),
            cache_creation: (map(.cache_creation_input_tokens // 0) | add // 0),
            cache_read:     (map(.cache_read_input_tokens // 0)     | add // 0),
            messages:       length }' 2>/dev/null)
  [ -n "$json" ] || json='{"input":0,"output":0,"cache_creation":0,"cache_read":0,"messages":0}'
  TOK_INPUT=$(printf '%s' "$json" | jq -r '.input')
  TOK_OUTPUT=$(printf '%s' "$json" | jq -r '.output')
  TOK_CACHE_CREATE=$(printf '%s' "$json" | jq -r '.cache_creation')
  TOK_CACHE_READ=$(printf '%s' "$json" | jq -r '.cache_read')
  TOK_MSGS=$(printf '%s' "$json" | jq -r '.messages')
  TOK_BILLABLE=$((TOK_INPUT + TOK_OUTPUT + TOK_CACHE_CREATE))
}

# Signal B (token window) is the slow part (scans every transcript touched in
# the last 5h). It is informational context, not the binary verdict, so only
# compute it for the verbose modes. --line/--quiet (used by alerting daemons on
# a tight timeout) rely on the fast ground-truth exhaustion scan alone.
WANT_WINDOW=0
case "$MODE" in human|json) WANT_WINDOW=1 ;; esac
[ "${CLAUDE_QUOTA_FORCE_WINDOW:-0}" = "1" ] && WANT_WINDOW=1

scan_exhaustion
[ "$WANT_WINDOW" = "1" ] && scan_window

# budget %
PCT_STR="n/a"
PCT_NUM="null"
if [ "$BUDGET" -gt 0 ] 2>/dev/null; then
  PCT_NUM=$(awk -v b="$TOK_BILLABLE" -v d="$BUDGET" 'BEGIN{ printf "%.1f", (d>0)?(100*b/d):0 }')
  PCT_STR="${PCT_NUM}%"
fi

RESET_IN_MIN="null"
RESET_ISO=""
if [ "$LIMITED" = "1" ]; then
  RESET_IN_MIN=$(( (LIMIT_RESET_EPOCH - NOW) / 60 ))
  RESET_ISO=$(date -r "$LIMIT_RESET_EPOCH" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null)
fi

# headline verdict string
if [ "$LIMITED" = "1" ]; then
  VERDICT="LIMITED (${LIMIT_SCOPE}) — resets ${LIMIT_RESET_TEXT} (in ${RESET_IN_MIN}min). THIS IS QUOTA."
elif [ "$WANT_WINDOW" = "1" ]; then
  VERDICT="not limited — no active exhaustion event (last 5h: ${TOK_OUTPUT} output / ${TOK_BILLABLE} billable tokens). NOT quota."
else
  VERDICT="not limited — no active exhaustion event in transcripts. NOT quota."
fi

emit_json() {
  jq -n \
    --argjson limited "$([ "$LIMITED" = 1 ] && echo true || echo false)" \
    --arg scope "$LIMIT_SCOPE" \
    --arg reset_text "$LIMIT_RESET_TEXT" \
    --arg reset_iso "$RESET_ISO" \
    --argjson reset_in_min "${RESET_IN_MIN}" \
    --argjson weekly_active "$([ "$WEEKLY_ACTIVE" = 1 ] && echo true || echo false)" \
    --arg weekly_reset "$WEEKLY_RESET_TEXT" \
    --argjson input "$TOK_INPUT" --argjson output "$TOK_OUTPUT" \
    --argjson cache_creation "$TOK_CACHE_CREATE" --argjson cache_read "$TOK_CACHE_READ" \
    --argjson billable "$TOK_BILLABLE" --argjson messages "$TOK_MSGS" \
    --argjson budget "$BUDGET" --argjson pct "$PCT_NUM" \
    --arg verdict "$VERDICT" \
    --argjson checked_at "$NOW" \
    '{
       limited: $limited,
       scope: $scope,
       confidence: ($limited | if . then "high" else "high" end),
       signal: ($limited | if . then "exhaustion-event" else "none" end),
       reset_time_text: $reset_text,
       reset_time_iso: $reset_iso,
       reset_in_minutes: $reset_in_min,
       weekly: { active: $weekly_active, reset_time_text: $weekly_reset },
       window_5h: {
         input_tokens: $input, output_tokens: $output,
         cache_creation_tokens: $cache_creation, cache_read_tokens: $cache_read,
         billable_tokens: $billable, messages: $messages,
         budget_billable: $budget, pct_of_budget: $pct
       },
       checked_at_epoch: $checked_at,
       verdict: $verdict
     }'
}

case "$MODE" in
  json) emit_json ;;
  line) printf 'QUOTA: %s\n' "$VERDICT" ;;
  quiet) : ;;
  human)
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " CLAUDE QUOTA CHECK  ($(date -r "$NOW" +%Y-%m-%d\ %H:%M:%S 2>/dev/null))"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$LIMITED" = "1" ]; then
      echo " 🔴 LIMITED — scope: ${LIMIT_SCOPE}"
      echo "    resets: ${LIMIT_RESET_TEXT}  (in ${RESET_IN_MIN} min)"
      echo "    → This IS quota. Wait for reset; do not chase infra."
    else
      echo " 🟢 NOT limited — no active exhaustion event in transcripts."
      echo "    → If something is stalled, it is NOT quota. Investigate infra."
    fi
    [ "$WEEKLY_ACTIVE" = "1" ] && echo "    ⚠ weekly limit ALSO active — resets ${WEEKLY_RESET_TEXT}"
    echo
    echo " Rolling 5h token usage (real, measured):"
    echo "    output:          ${TOK_OUTPUT}"
    echo "    input:           ${TOK_INPUT}"
    echo "    cache_creation:  ${TOK_CACHE_CREATE}"
    echo "    cache_read:      ${TOK_CACHE_READ}  (discounted, excluded from billable)"
    echo "    billable:        ${TOK_BILLABLE}   (input+output+cache_creation)"
    echo "    messages:        ${TOK_MSGS}"
    echo "    budget %:        ${PCT_STR}$([ "$BUDGET" -le 0 ] 2>/dev/null && echo '  (set CLAUDE_QUOTA_BUDGET_BILLABLE to enable)')"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ;;
esac

[ "$LIMITED" = "1" ] && exit 2
exit 0
