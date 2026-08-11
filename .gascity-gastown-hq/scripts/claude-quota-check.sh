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
# ─────────────────────────────────────────────────────────────────────────────
# ga-ot735: WEEKLY vs SESSION scope — STOP THE FALSE PAUSE
# ─────────────────────────────────────────────────────────────────────────────
# PROBLEM observed (false-pause, twice in one day): when the Max plan's WEEKLY
# limit fires, Anthropic writes ONE "You've hit your weekly limit · resets Jun
# 18 at 1pm" event. That event stays in the FUTURE for up to ~7 days, so EVERY
# subsequent run read limited=true for DAYS — exit 2 → the gate/pilot fully
# self-paused → the Mayor had to keep hand-adding GATE_QUOTA_OVERRIDE /
# PILOT_QUOTA_OVERRIDE (a recurring band-aid flip-flop).
#
# WHY THE OLD BEHAVIOR WAS WRONG: the two scopes are NOT equivalent.
#   • SESSION (5h rolling window): short, self-clearing in ≤5h, RELIABLE. When
#     it fires, a NEW reviewer/builder session WILL immediately re-hit it and
#     burn for nothing → pausing is correct.
#   • WEEKLY: a multi-DAY ceiling. It is the LEAST reliable thing to pause on,
#     because (a) it lingers for days, (b) on Max20 the 5h window almost always
#     still has headroom underneath it, and (c) the weekly cap is the one Athos
#     explicitly wants to keep working through (hence the manual overrides).
#
# RESEARCH FINDING (honest): there is NO reliable, documented, stable
# programmatic source for a claude.ai SUBSCRIPTION account's REAL remaining
# rolling-window quota. `claude` has no `usage`/`limits` subcommand; `claude
# auth status` shows only login state; the Admin Usage/Cost/Rate-Limit APIs are
# API-KEY-org only and do NOT cover subscription rolling windows; the real
# five_hour/seven_day utilization numbers exist ONLY in-process and are handed
# to a statusLine command's stdin during an INTERACTIVE session — they are not
# persisted to any file an external daemon can poll, and are not written into
# transcripts. So the ground-truth exhaustion EVENT remains the only reliable
# signal we have. The fix is therefore NOT "read the real account" (impossible)
# but "stop over-reacting to the unreliable WEEKLY event".
#
# THE FIX: the exit-2 / limited binary is now SCOPED.
#   • An active SESSION (5h) exhaustion event  → limited=true, exit 2 (pause).
#   • An active WEEKLY exhaustion event, with NO active session event, is
#     ADVISORY by default: reported (weekly.active=true) but exit 0 — the gate
#     keeps running on the still-available 5h window. Set
#     CLAUDE_QUOTA_WEEKLY_HARD=1 to restore the old "weekly also pauses" behavior.
#   • If BOTH are active, session wins (still exit 2).
# This removes the days-long false pause and the manual-override flip-flop while
# keeping the reliable, short, self-clearing 5h pause fully intact.
# ─────────────────────────────────────────────────────────────────────────────
#
# USAGE
#   claude-quota-check.sh            # human-readable report; exit 2 if limited
#   claude-quota-check.sh --json     # machine-readable JSON
#   claude-quota-check.sh --line     # one compact line (for embedding in alerts)
#   claude-quota-check.sh --quiet    # no output; exit code only
# EXIT CODES
#   0 = NOT limited (incl. weekly-only, advisory)   2 = hard-limited (active 5h
#       session exhaustion, or weekly when CLAUDE_QUOTA_WEEKLY_HARD=1)   1 = error
#
# ENV OVERRIDES (also used by the selftest for determinism)
#   CLAUDE_PROJECTS_DIR        transcript root (default ~/.claude/projects)
#   CLAUDE_QUOTA_NOW           epoch seconds to treat as "now" (default: real now)
#   CLAUDE_QUOTA_TZ            tz for parsing reset clock times (default America/Sao_Paulo)
#   CLAUDE_QUOTA_SCAN_ALL      1 = scan every transcript (no mtime prefilter; tests)
#   CLAUDE_QUOTA_WEEKLY_HARD   1 = a weekly-only limit ALSO trips exit 2 (legacy
#                              behavior). Default 0 = weekly is advisory, only the
#                              5h session limit hard-pauses (ga-ot735).
#   CLAUDE_QUOTA_BUDGET_BILLABLE  if set (>0), report billable-token % of this budget
#                                 Calibrate once: note the billable number printed at
#                                 the moment a real exhaustion event fires; set that.
#   CLAUDE_QUOTA_FRESHNESS_SECS  ga-z0n9f: freshness guard threshold in seconds.
#                                 If the most-recent session-limit event is older than
#                                 this AND the stated reset is still in the future, the
#                                 latch is cleared (defer-without-spawn starves re-log).
#                                 Default 1200 (20 min). Set to 0 to disable.
#   CLAUDE_QUOTA_BURST_MIN_COUNT  ga-burst: minimum number of session-limit 429 events
#                                 required within CLAUDE_QUOTA_BURST_WINDOW_SECS to declare
#                                 SESSION LIMITED. A single/sporadic 429 does NOT pause.
#                                 Default 2. Set to 1 to restore the old single-event latch.
#   CLAUDE_QUOTA_BURST_WINDOW_SECS  ga-burst: the recent window (in seconds) in which
#                                 BURST_MIN_COUNT events must appear to declare LIMITED.
#                                 Default 300 (5 min).
#   CLAUDE_QUOTA_WEEKLY_FRESHNESS_SECS  ga-sdkqs: same freshness-guard idea as
#                                 CLAUDE_QUOTA_FRESHNESS_SECS above (ga-z0n9f), applied to
#                                 the WEEKLY track. An active weekly exhaustion is
#                                 continuously re-logged as long as the gate/pilot
#                                 dispatchers keep trying to spawn sessions (~every 2min)
#                                 and keep re-hitting the same cap. If the STATED reset
#                                 (days out) hasn't arrived yet but no fresh weekly-
#                                 exhaustion line has appeared in this many seconds, that
#                                 silence — despite continued spawn attempts — is strong
#                                 evidence capacity came back early (e.g. a manual /login
#                                 before the natural reset), not that the limit is still
#                                 blocking. Without this guard, weekly.active would stay
#                                 true for up to the 6h transcript-scan window after real
#                                 recovery — a consumer that suppresses on weekly.active
#                                 (e.g. gate-throughput-stall-watchdog.sh) would go blind
#                                 to real stalls for that whole window. Default 1800 (30
#                                 min) — longer than the SESSION default (20 min) because
#                                 wrongly clearing WEEKLY early is the worse failure here:
#                                 a consumer that kickstarts on a false "not limited" burns
#                                 the very quota that is scarce, whereas staying suppressed
#                                 a little longer just delays a real-stall alert. Set to 0
#                                 to disable (legacy: weekly.active never self-clears).
#   CLAUDE_QUOTA_SKIP_WINDOW   1 = skip the token-window scan (window_5h.*) even in
#                                 --json/--human mode, forcing WANT_WINDOW=0. The window
#                                 scan is the slow part (reads every transcript touched in
#                                 the last 5h); callers that only need the fast ground-
#                                 truth exhaustion verdict (.limited, .weekly.*) — e.g. an
#                                 alerting daemon's sweep — can request --json without
#                                 paying that cost. Default 0 (unchanged existing behavior).
#
# Dependencies: bash, jq, find, grep, date (BSD/macOS date semantics).

set -uo pipefail

PROJ="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
TZ_RESET="${CLAUDE_QUOTA_TZ:-America/Sao_Paulo}"
NOW="${CLAUDE_QUOTA_NOW:-$(date +%s)}"
BUDGET="${CLAUDE_QUOTA_BUDGET_BILLABLE:-0}"
WEEKLY_HARD="${CLAUDE_QUOTA_WEEKLY_HARD:-0}"   # ga-ot735: 1 = weekly also hard-pauses
FRESHNESS_MAX_SECS="${CLAUDE_QUOTA_FRESHNESS_SECS:-1200}"  # ga-z0n9f: 20 min default; 0=disable
WEEKLY_FRESHNESS_MAX_SECS="${CLAUDE_QUOTA_WEEKLY_FRESHNESS_SECS:-1800}"  # ga-sdkqs: 30 min default; 0=disable
BURST_MIN_COUNT="${CLAUDE_QUOTA_BURST_MIN_COUNT:-2}"       # ga-burst: min events in window to be LIMITED
BURST_WINDOW_SECS="${CLAUDE_QUOTA_BURST_WINDOW_SECS:-300}" # ga-burst: 5 min recent window for burst test
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
  # Normalize an hour-only clock ("3pm" -> "3:00pm"). CRITICAL: BSD `date -j -f`
  # fills any field absent from the format from the CURRENT wall clock — so
  # parsing "3pm" with "%I%p" yields 3:<current-minute>:<current-second>, not
  # 3:00:00. That caused a false-pause: "resets 3pm" read at 3:32pm became
  # 15:32 (≈now → "resets in 0 min"), and once the clock passed that inherited
  # minute the next-day rollforward below fired → the limit looked active until
  # tomorrow 3pm even though the real 5h window had already reset at 3:00pm.
  case "$clock" in
    *:*) : ;;                                                   # already has minutes
    *[0-9]am|*[0-9]pm) clock=$(printf '%s' "$clock" | sed -E 's/^([0-9]+)(am|pm)$/\1:00\2/') ;;
  esac
  e=$(TZ="$TZ_RESET" date -j -f "%Y-%m-%d %I:%M%p" "$day $clock" +%s 2>/dev/null) \
    || e=$(TZ="$TZ_RESET" date -j -f "%Y-%m-%d %I%p" "$day $clock" +%s 2>/dev/null) \
    || return 1
  # floor to the minute: drop any seconds still inherited from the current clock
  # (the %M format above pins minutes, but seconds remain wall-clock-derived).
  e=$(( e - (e % 60) ))
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
# ga-ot735: track the two scopes INDEPENDENTLY. The final hard verdict
# (LIMITED / LIMIT_SCOPE / headline) is derived AFTER the scan in
# resolve_verdict(), so a days-out weekly event can no longer mask or override
# the short, reliable 5h session signal.
LIMITED=0
LIMIT_SCOPE="none"
LIMIT_RESET_TEXT=""
LIMIT_RESET_EPOCH=0
SESSION_ACTIVE=0
SESSION_RESET_TEXT=""
SESSION_RESET_EPOCH=0
SESSION_LAST_EVENT_EPOCH=0   # ga-z0n9f: most-recent session exhaustion event time
SESSION_STALE=0              # ga-z0n9f: 1 = freshness guard cleared the latch
SESSION_BURST_COUNT=0        # ga-burst: # of session-limit events within BURST_WINDOW_SECS
WEEKLY_ACTIVE=0
WEEKLY_RESET_TEXT=""
WEEKLY_RESET_EPOCH=0
WEEKLY_LAST_EVENT_EPOCH=0   # ga-z0n9f: most-recent weekly exhaustion event time
WEEKLY_STALE=0              # ga-sdkqs: 1 = freshness guard cleared the weekly latch

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
      # ga-z0n9f: track most-recent event epoch per scope for the freshness guard.
      # Updated for ALL events (not just active) so the guard can detect when the
      # re-log signal has gone quiet (no sessions hitting the limit = limit cleared).
      if [ "$scope" = "session" ]; then
        [ "$ev_epoch" -gt "$SESSION_LAST_EVENT_EPOCH" ] 2>/dev/null \
          && SESSION_LAST_EVENT_EPOCH="$ev_epoch"
        # ga-burst: count events within the burst window for the burst-rate test.
        if [ "$((NOW - ev_epoch))" -le "$BURST_WINDOW_SECS" ] 2>/dev/null; then
          SESSION_BURST_COUNT=$((SESSION_BURST_COUNT + 1))
        fi
      else
        [ "$ev_epoch" -gt "$WEEKLY_LAST_EVENT_EPOCH" ] 2>/dev/null \
          && WEEKLY_LAST_EVENT_EPOCH="$ev_epoch"
      fi
      reset=$(printf '%s' "$text" | sed -E 's/.*resets +//; s/ *\(.*\)$//')
      if [ "$scope" = "session" ]; then
        reset_epoch=$(clock_to_epoch "$ev_epoch" "$reset" 2>/dev/null) || reset_epoch=""
      else
        reset_epoch=$(date_to_epoch "$ev_epoch" "$reset" 2>/dev/null) || reset_epoch=""
      fi
      [ -n "$reset_epoch" ] || continue
      # active iff reset is still in the future relative to NOW. Record the
      # latest-resetting active event PER SCOPE (independent tracks).
      if [ "$reset_epoch" -gt "$NOW" ]; then
        if [ "$scope" = "weekly" ]; then
          WEEKLY_ACTIVE=1
          if [ "$reset_epoch" -gt "$WEEKLY_RESET_EPOCH" ]; then
            WEEKLY_RESET_TEXT="$reset"
            WEEKLY_RESET_EPOCH="$reset_epoch"
          fi
        else
          SESSION_ACTIVE=1
          if [ "$reset_epoch" -gt "$SESSION_RESET_EPOCH" ]; then
            SESSION_RESET_TEXT="$reset"
            SESSION_RESET_EPOCH="$reset_epoch"
          fi
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

# ----- ga-ot735: scope-aware hard verdict -----
# resolve_verdict — collapse the two independent scope tracks (SESSION_*,
# WEEKLY_*) into the single hard LIMITED binary the gate/pilot consume via exit
# code. PURE: reads only the module-level scan results + WEEKLY_HARD; no IO.
#
# Precedence (the whole point of the fix):
#   1. SESSION (5h) active AND burst ≥ BURST_MIN_COUNT in BURST_WINDOW_SECS →
#      LIMITED=1, scope=session. Requires a SUSTAINED BURST, not a single 429.
#      Sporadic/borderline 429s (every ~10min) do NOT cross the burst threshold
#      and therefore do NOT pause (ga-burst).
#   2. else WEEKLY active + WEEKLY_HARD=1 → LIMITED=1, scope=weekly (legacy opt-in).
#   3. else WEEKLY active (default)   → LIMITED=0 (ADVISORY). weekly.active is
#      still reported, but we do NOT pause the gate for days on the multi-day
#      ceiling while the 5h window underneath it still has headroom. This is the
#      single change that ends the recurring GATE_QUOTA_OVERRIDE flip-flop.
#   4. else                          → LIMITED=0, scope=none.
# When session wins it ALSO wins the headline reset fields, so the ETA the gate
# logs is the relevant (sooner) 5h reset, not the days-out weekly one.
resolve_verdict() {
  SESSION_STALE=0
  SESSION_BURST_LIMITED=0   # 1 = burst threshold met; 0 = sporadic (not a hard limit)

  # ga-sdkqs: WEEKLY freshness guard, mirroring the SESSION one below (ga-z0n9f).
  # Evaluated BEFORE the session/weekly branch so a stale WEEKLY_ACTIVE never reaches
  # it — see CLAUDE_QUOTA_WEEKLY_FRESHNESS_SECS above for the full rationale.
  WEEKLY_STALE=0
  if [ "$WEEKLY_ACTIVE" = "1" ] \
     && [ "$WEEKLY_FRESHNESS_MAX_SECS" -gt 0 ] \
     && [ "$WEEKLY_LAST_EVENT_EPOCH" -gt 0 ] \
     && [ $(( NOW - WEEKLY_LAST_EVENT_EPOCH )) -gt "$WEEKLY_FRESHNESS_MAX_SECS" ]; then
    WEEKLY_STALE=1
    WEEKLY_ACTIVE=0
  fi

  if [ "$SESSION_ACTIVE" = "1" ]; then
    # ga-burst: require ≥ BURST_MIN_COUNT session-limit events within BURST_WINDOW_SECS.
    # A single or sporadic 429 (e.g. one every ~10 min on a borderline account)
    # must NOT hold LIMITED. Only a sustained burst (near-every request failing)
    # signals a real hard exhaustion and warrants pausing the gate.
    # BURST_MIN_COUNT=1 restores the old single-event latch (escape hatch).
    if [ "$SESSION_BURST_COUNT" -ge "$BURST_MIN_COUNT" ] 2>/dev/null; then
      SESSION_BURST_LIMITED=1
    fi
    # ga-z0n9f freshness guard: when the gate defers (quota=LIMITED) it stops
    # spawning sessions, so no fresh "hit your limit" events appear in transcripts.
    # The latch then holds until the STATED reset time even when the real server
    # limit cleared earlier. If no session-limit event in FRESHNESS_MAX_SECS (and
    # the guard is enabled via FRESHNESS_MAX_SECS > 0), clear the stale latch.
    if [ "$FRESHNESS_MAX_SECS" -gt 0 ] \
       && [ "$SESSION_LAST_EVENT_EPOCH" -gt 0 ] \
       && [ $(( NOW - SESSION_LAST_EVENT_EPOCH )) -gt "$FRESHNESS_MAX_SECS" ]; then
      SESSION_STALE=1
      SESSION_ACTIVE=0
      SESSION_BURST_LIMITED=0
      LIMITED=0; LIMIT_SCOPE="none"; LIMIT_RESET_TEXT=""; LIMIT_RESET_EPOCH=0
    elif [ "$SESSION_BURST_LIMITED" = "1" ]; then
      LIMITED=1
      LIMIT_SCOPE="session"
      LIMIT_RESET_TEXT="$SESSION_RESET_TEXT"
      LIMIT_RESET_EPOCH="$SESSION_RESET_EPOCH"
    else
      # Sporadic 429(s) but not a sustained burst — treat as not limited.
      LIMITED=0; LIMIT_SCOPE="none"; LIMIT_RESET_TEXT=""; LIMIT_RESET_EPOCH=0
    fi
  elif [ "$WEEKLY_ACTIVE" = "1" ] && [ "$WEEKLY_HARD" = "1" ]; then
    LIMITED=1
    LIMIT_SCOPE="weekly"
    LIMIT_RESET_TEXT="$WEEKLY_RESET_TEXT"
    LIMIT_RESET_EPOCH="$WEEKLY_RESET_EPOCH"
  else
    LIMITED=0
    LIMIT_SCOPE="none"
    LIMIT_RESET_TEXT=""
    LIMIT_RESET_EPOCH=0
  fi
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
# ga-sdkqs: explicit opt-out for callers (e.g. an alerting daemon's --json probe)
# that want the fast ground-truth exhaustion verdict without paying for the
# slower token-window scan. Checked last so it wins over FORCE_WINDOW.
[ "${CLAUDE_QUOTA_SKIP_WINDOW:-0}" = "1" ] && WANT_WINDOW=0

scan_exhaustion
resolve_verdict          # ga-ot735: scope the hard verdict (session pauses, weekly advisory)
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

# headline verdict string. ga-ot735: an advisory weekly limit (active weekly, no
# active session, default soft mode) is NOT a hard pause — say so explicitly so
# the log makes clear why the gate keeps running.
WEEKLY_ADVISORY=0
[ "$LIMITED" = "0" ] && [ "$WEEKLY_ACTIVE" = "1" ] && WEEKLY_ADVISORY=1
# ga-burst: sporadic = session_active but burst threshold NOT met (not hard limited)
SESSION_SPORADIC=0
[ "$SESSION_ACTIVE" = "1" ] && [ "$SESSION_BURST_LIMITED" = "0" ] && [ "$SESSION_STALE" = "0" ] && SESSION_SPORADIC=1
if [ "$LIMITED" = "1" ]; then
  VERDICT="LIMITED (${LIMIT_SCOPE}) — resets ${LIMIT_RESET_TEXT} (in ${RESET_IN_MIN}min). THIS IS QUOTA."
elif [ "$SESSION_STALE" = "1" ]; then
  _stale_age=$(( (NOW - SESSION_LAST_EVENT_EPOCH) / 60 ))
  VERDICT="not limited — session-limit stale (last event ${_stale_age}min ago > threshold ${FRESHNESS_MAX_SECS}s; freshness guard cleared latch, ga-z0n9f). NOT quota."
elif [ "$SESSION_SPORADIC" = "1" ]; then
  VERDICT="not limited — sporadic 429(s) (burst_count=${SESSION_BURST_COUNT} < threshold ${BURST_MIN_COUNT} in ${BURST_WINDOW_SECS}s window; not a sustained exhaustion, ga-burst). NOT quota."
elif [ "$WEEKLY_ADVISORY" = "1" ]; then
  VERDICT="not hard-limited — weekly limit active (advisory, resets ${WEEKLY_RESET_TEXT}) but 5h session window OK; gate keeps running. NOT a pause."
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
    --argjson session_stale "$([ "$SESSION_STALE" = 1 ] && echo true || echo false)" \
    --argjson session_last_event_secs_ago "$([ "$SESSION_LAST_EVENT_EPOCH" -gt 0 ] 2>/dev/null && echo $(( NOW - SESSION_LAST_EVENT_EPOCH )) || echo 0)" \
    --argjson freshness_threshold_secs "$FRESHNESS_MAX_SECS" \
    --argjson session_burst_count "$SESSION_BURST_COUNT" \
    --argjson session_burst_min "$BURST_MIN_COUNT" \
    --argjson session_burst_window_secs "$BURST_WINDOW_SECS" \
    --argjson session_sporadic "$([ "$SESSION_SPORADIC" = 1 ] && echo true || echo false)" \
    --argjson weekly_active "$([ "$WEEKLY_ACTIVE" = 1 ] && echo true || echo false)" \
    --arg weekly_reset "$WEEKLY_RESET_TEXT" \
    --argjson weekly_hard "$([ "$WEEKLY_HARD" = 1 ] && echo true || echo false)" \
    --argjson weekly_advisory "$([ "$WEEKLY_ADVISORY" = 1 ] && echo true || echo false)" \
    --argjson weekly_stale "$([ "$WEEKLY_STALE" = 1 ] && echo true || echo false)" \
    --argjson weekly_freshness_threshold_secs "$WEEKLY_FRESHNESS_MAX_SECS" \
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
       session_stale: $session_stale,
       session_last_event_secs_ago: $session_last_event_secs_ago,
       freshness_threshold_secs: $freshness_threshold_secs,
       session_burst: {
         count: $session_burst_count,
         min_required: $session_burst_min,
         window_secs: $session_burst_window_secs,
         sporadic: $session_sporadic
       },
       weekly: { active: $weekly_active, reset_time_text: $weekly_reset,
                 hard: $weekly_hard, advisory: $weekly_advisory,
                 stale: $weekly_stale, freshness_threshold_secs: $weekly_freshness_threshold_secs },
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
      # weekly underneath an active session limit: note it, but it's not the headline.
      [ "$LIMIT_SCOPE" = "session" ] && [ "$WEEKLY_ACTIVE" = "1" ] \
        && echo "    ⚠ weekly limit ALSO active — resets ${WEEKLY_RESET_TEXT}"
    elif [ "$SESSION_STALE" = "1" ]; then
      echo " 🟢 NOT limited — session-limit STALE (freshness guard, ga-z0n9f)"
      echo "    Last session-limit event: $(( (NOW - SESSION_LAST_EVENT_EPOCH) / 60 )) min ago (threshold: ${FRESHNESS_MAX_SECS}s)"
      echo "    → Defer-without-spawn starved the re-log signal; latch cleared."
      echo "    → Set CLAUDE_QUOTA_FRESHNESS_SECS=0 to disable this guard."
    elif [ "$SESSION_SPORADIC" = "1" ]; then
      echo " 🟢 NOT limited — sporadic 429(s), NOT a sustained burst (ga-burst)"
      echo "    Burst count: ${SESSION_BURST_COUNT} in last ${BURST_WINDOW_SECS}s (threshold: ${BURST_MIN_COUNT} required)"
      echo "    → Borderline account: occasional 429s but not exhausted; gate keeps running."
      echo "    → Set CLAUDE_QUOTA_BURST_MIN_COUNT=1 to restore single-event latch."
    elif [ "$WEEKLY_ADVISORY" = "1" ]; then
      echo " 🟡 WEEKLY limit active (ADVISORY) — resets ${WEEKLY_RESET_TEXT}"
      echo "    No active 5h session limit → the gate/pilot KEEP RUNNING (ga-ot735)."
      echo "    → Not a hard pause. Set CLAUDE_QUOTA_WEEKLY_HARD=1 to pause on weekly too."
    else
      echo " 🟢 NOT limited — no active exhaustion event in transcripts."
      echo "    → If something is stalled, it is NOT quota. Investigate infra."
    fi
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
