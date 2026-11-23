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

# dolt_server_port (ga-3v2zt00) -- the TCP port the live Dolt server answers on, NEVER a number
# written in a plist, a script default or a session env.
#
# WHY: the port changes on every Dolt start (52756 -> 52757 at the 22/11 reboot, back to 52756 at the
# 23/11 09:52 hang-watchdog restart). Every place that wrote the number down went blind on the next
# flip: the gate saw its own queue as "raced away" for 80 min, the Pilot refused to dispatch, the
# sentinel and the disk-floor guard raised "Dolt unreachable" on a server that never went down, and
# the hang watchdog's raw SELECT 1 aimed at a dead port reads as "not serving" -- the input to a restart.
#
# Order (first answer wins):
#   1. GC_DOLT_PORT_OVERRIDE -- explicit seam for selftests/operators, numeric only.
#   2. The LISTEN socket of the verified live server (dolt_server_pid): the only source that cannot be stale.
#   3. $GC_CITY/.beads/dolt-server.port -- the file bd itself reads (numeric only). Stale when the server
#      is down, which is fine: a refused connection there is the right "down" answer.
#   4. BEADS_DOLT_PORT, last resort only. It is the legacy pin: it must never outrank a live process.
# Prints the port and returns 0; prints nothing and returns 1 when NONE of the four answers = UNKNOWN.
# Callers MUST treat empty as "could not tell" -- inert (no restart, no alarm "down", no write) -- and never
# as "Dolt is down" nor as a default port.
_dolt_port_valid() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
dolt_server_port() {
  local _city="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}" _pid _port=""
  if _dolt_port_valid "${GC_DOLT_PORT_OVERRIDE:-}"; then
    printf '%s' "$GC_DOLT_PORT_OVERRIDE"; return 0
  fi
  _pid="$(dolt_server_pid || true)"
  if [ -n "$_pid" ]; then
    # vazio (no LISTEN line) / falhou (lsof error): fall through to the port file -- never to a default
    _port="$(lsof -nP -a -p "$_pid" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n.*:\([0-9][0-9]*\)$/\1/p' | head -1)"
    if _dolt_port_valid "$_port"; then printf '%s' "$_port"; return 0; fi
  fi
  if [ -r "$_city/.beads/dolt-server.port" ]; then
    _port="$(head -1 "$_city/.beads/dolt-server.port" 2>/dev/null | tr -d '[:space:]')"
    if _dolt_port_valid "$_port"; then printf '%s' "$_port"; return 0; fi
  fi
  if _dolt_port_valid "${BEADS_DOLT_PORT:-}"; then
    printf '%s' "$BEADS_DOLT_PORT"; return 0
  fi
  printf ''
  return 1
}
