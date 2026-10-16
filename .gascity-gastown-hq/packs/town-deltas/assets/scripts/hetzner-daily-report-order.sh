#!/bin/bash
# hetzner-daily-report-order.sh (ga-zri39b) — what the `hetzner-daily-report` order runs once a day.
#
# WHY: the Hetzner test node is a one-week trial (Athos 13/10) and the Mayor asked for a daily mail with performance and cost. This wrapper only decides WHETHER
# to send: the report (scripts/hetzner-daily-report.sh --mail) goes out while the node is switched on ($CITY/.gc/hetzner-node.on exists) or while the log still shows
# batteries that ran on it in the last 24 h (so the day it is switched off still gets its last report). Off and idle = silent success, so the order stops mailing
# by itself once the trial ends — without anyone having to remember to remove it.
#
# A missing report script is a FAILED run (exit 1, stderr), never a quiet success: a report that cannot be built must not look like a report with nothing to say.
# The "was it used in the last 24 h" read has three states and the inert one is "send": if the log cannot be read, the report goes out and says so itself. That includes a log that
# reads but has lines the report cannot classify ("N linha(s) ilegível(is)": a truncated line, a row without mode...) — such a line may have been a battery on the node, so "0 runs"
# is not an answer. Known cost: a truncated line carries no timestamp, so it counts for as long as it stays in the file and the mail keeps coming (each one says why) until the
# line is removed from .gc/logs/mbp-run.jsonl.
# NOT checked: whether the server still exists. Off and idle stops the mail, not the billing (about €1.9/day for the cax41) — deleting the server stays the Mayor's job.
#
# TEST: bash scripts/hetzner-daily-report.selftest.sh (covers this wrapper too)
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
REPORT="${HETZNER_REPORT_SCRIPT:-$CITY/scripts/hetzner-daily-report.sh}"
FLAG="$CITY/.gc/hetzner-node.on"

if [ ! -f "$REPORT" ]; then
  echo "hetzner-daily-report: report script not found at $REPORT — no report was sent" >&2
  exit 1
fi

send=0
if [ -f "$FLAG" ]; then send=1
else
  # flag off: report only if the node did work in the last 24 h. Zero → silent; unreadable (no/garbled report, log not an object, any unclassifiable line, n not a number) → send:
  # the report states the problem itself. `// "unreadable"` alone would read an n of 0 beside bad lines as idle.
  n=$(HETZNER_REPORT_CITY="$CITY" bash "$REPORT" --no-cost --json 2>/dev/null | jq -r '
    if (.runs | type) != "object" then "unreadable"
    elif (.runs.bad | type) != "number" or .runs.bad > 0 then "unreadable"
    else (.runs.hetzner.n | if type == "number" then . else "unreadable" end) end' 2>/dev/null)
  case "$n" in
    0) send=0 ;;
    ''|*[!0-9]*) send=1 ;;
    *) send=1 ;;
  esac
fi

if [ "$send" -eq 0 ]; then
  echo "hetzner-daily-report: node off and idle for 24 h — nothing to report"
  exit 0
fi
exec env HETZNER_REPORT_CITY="$CITY" bash "$REPORT" --mail
