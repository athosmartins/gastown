#!/usr/bin/env bash
# dolt-pid-lib.sh (ga-0bjqix) — canonical Dolt server PID resolution.
#
# WHY: `pgrep -f 'dolt sql-server' | head -1` picks whichever matching
# process happens to sort first — not necessarily the real server. Two
# false-positive sources, both observed live in this city:
#   1. Any short-lived process whose argv momentarily contains the search
#      string (measured 2026-09-15 08:39Z: pid 5546, etime 1s, 0.1% CPU,
#      no --config in argv, no listener — while the real server, pid
#      30796, was untouched).
#   2. Any `claude` agent session whose injected system prompt embeds this
#      exact doctrine text (which names "dolt sql-server" verbatim), so a
#      multi-thousand-token command line matches too (memory:
#      pgrep-f-matches-other-agents-embedded-prompt).
# `head -1` cannot tell either apart from the real server — and this PID
# feeds destructive decisions (dolt-hang-watchdog.sh's CPU veto and its
# kill -QUIT target), so a wrong pick is not just cosmetic.
#
# WHAT: dolt_server_pid() resolves the PID with a fallback chain, and every
# candidate is verified twice — executable basename "dolt" AND a live TCP
# LISTEN socket — never picked by sort order alone:
#   1. The PID recorded in dolt.pid, if it passes both checks.
#   2. Else, among `pgrep -f 'dolt sql-server'` candidates (in the order
#      pgrep returns them), the first that passes both checks.
#   3. Else empty ("" = UNKNOWN). Callers must treat empty as "no live
#      server identified" and must NOT fall back to head -1 or otherwise
#      guess — see callers' own DRY_RUN/veto handling for what "unknown"
#      should do on their destructive paths.
#
# Sourced by sibling scripts in this same directory (dolt-hang-watchdog.sh,
# dolt-gc-maintenance.sh, dolt-latency-alarm.sh, gc-dolt-probe.sh,
# gate-pilot-soak-monitor.sh, soak-spd2n-monitor.sh) via a path relative to
# their own location, and by packs/town-deltas/assets/quality-gate-dispatcher.sh
# via ${GC_CITY}/scripts/dolt-pid-lib.sh (its existing sibling-lib convention).
set -uo pipefail

# internal: does PID $1 look like the real dolt sql-server -- alive, "dolt"
# executable, AND holding a TCP LISTEN socket? All three, never sort order.
_dolt_pid_is_server() {
  local _p="$1"
  [ -n "$_p" ] || return 1
  kill -0 "$_p" 2>/dev/null || return 1
  local _comm
  _comm="$(ps -o comm= -p "$_p" 2>/dev/null)"
  case "${_comm##*/}" in
    dolt) ;;
    *) return 1 ;;
  esac
  lsof -nP -a -p "$_p" -iTCP -sTCP:LISTEN >/dev/null 2>&1
}

dolt_server_pid() {
  # Evaluated fresh on every call (not cached at source time) so a
  # per-invocation GC_CITY override -- as the selftest and any future
  # caller-side test isolation rely on -- actually takes effect.
  local _city="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
  local _pidfile="$_city/.gc/runtime/packs/dolt/dolt.pid"
  if [ -r "$_pidfile" ]; then
    local _cand
    _cand="$(cat "$_pidfile" 2>/dev/null)"
    if _dolt_pid_is_server "$_cand"; then
      printf '%s' "$_cand"
      return 0
    fi
  fi

  local _p
  while IFS= read -r _p; do
    [ -z "$_p" ] && continue
    if _dolt_pid_is_server "$_p"; then
      printf '%s' "$_p"
      return 0
    fi
  done < <(pgrep -f 'dolt sql-server' 2>/dev/null)

  printf ''
  return 1
}
