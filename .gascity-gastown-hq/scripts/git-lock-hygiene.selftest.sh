#!/usr/bin/env bash
# git-lock-hygiene.selftest.sh — standalone regression harness for imp18
# Delegates to the --selftest flag built into git-lock-hygiene.sh.
# Exit 0 = pass.
#
# ga-d8zeli: also proves that selftest is HERMETIC with respect to the city log.
# The script's own --selftest fires real removed/would_remove events through
# _log_json, which appends to $LOG — by default the LIVE sweeps log,
# $GC_CITY_PATH/.gc/logs/git-lock-hygiene.jsonl. Measured 2026-09-20: 746 of the
# 36791 lines in that live log were selftest fixtures (paths under
# git-lock-hygiene-selftest.*). So run it inside a throwaway city and fail if it
# wrote anything there. GIT_LOCK_LOG is unset for the child on purpose: the
# default log path is the one under test, and an inherited override would hide
# a leak.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

SBX_CITY="$(mktemp -d "${TMPDIR:-/tmp}/git-lock-hygiene-selftest-city.XXXXXX")"
trap 'rm -rf "$SBX_CITY"' EXIT
mkdir -p "$SBX_CITY/.gc/logs"   # _log_json's append fails silently when this is missing

rc=0
env -u GIT_LOCK_LOG GC_CITY_PATH="$SBX_CITY" bash "$SCRIPT_DIR/git-lock-hygiene.sh" --selftest "$@" || rc=$?

city_log="$SBX_CITY/.gc/logs/git-lock-hygiene.jsonl"
if [ -s "$city_log" ]; then
  echo "FAIL hermetic: --selftest appended $(wc -l < "$city_log" | tr -d ' ') line(s) to the city log (\$LOG default) — against the live city that is the production log:" >&2
  head -2 "$city_log" | cut -c1-200 >&2
  rc=1
else
  echo "  ok  hermetic: --selftest wrote nothing to the city log"
fi
exit "$rc"
