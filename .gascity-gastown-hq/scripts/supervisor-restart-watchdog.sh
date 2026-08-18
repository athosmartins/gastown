#!/bin/bash
# supervisor-restart-watchdog.sh (ga-b0gltl) — detection-only durable restart
# counter for com.gascity.supervisor.
#
# The supervisor dies periodically (OS_REASON_CODESIGNING historically
# suspected, but exit-code evidence at write time did not confirm it as the
# live cause) and launchd's KeepAlive silently respawns it — so the crash
# never surfaces as a visible failure, only as a dispatch gap nobody can see.
# Today there is no durable answer to "how many times did it die, and why."
#
# This script takes ONE sample per invocation (`launchctl print`), diffs the
# `runs` counter against the previous sample, and appends one JSONL record to
# .gc/logs/supervisor-restart-watchdog.jsonl. It never restarts, reconfigures,
# or otherwise touches the supervisor — see ga-b0gltl for why that is
# explicitly out of scope until this counter tells us the real frequency.
#
# Answering "how many restarts in the last 24h and why" is then a jq query
# against the ledger, e.g.:
#   jq -s --arg since "$(date -u -v-1d +%Y-%m-%dT%H:%M:%SZ)" \
#     '[.[] | select(.ts >= $since)] | {restarts: (map(.delta_since_last) | add), samples: length}' \
#     .gc/logs/supervisor-restart-watchdog.jsonl
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
STATE_DIR="$CITY/.gc/state"
STATE_FILE="$STATE_DIR/supervisor-restart-watchdog.json"
LEDGER_DIR="$CITY/.gc/logs"
LEDGER_FILE="$LEDGER_DIR/supervisor-restart-watchdog.jsonl"
SUPERVISOR_LOG="${GC_SUPERVISOR_LOG:-/Users/athos/.gc/supervisor.log}"
SUPERVISOR_LABEL="com.gascity.supervisor"
UID_NUM="$(id -u)"

mkdir -p "$STATE_DIR" "$LEDGER_DIR"

log() { printf '[supervisor-restart-watchdog] %s\n' "$*"; }

# ---- single-instance lock ----
# Ported (liveness-only reclaim logic kept verbatim in spirit) from
# pilot-missing-route-watchdog.sh's _acquire_pmrw_lock, written for ga-y0g5x:
# 4 simultaneous instances of an earlier watchdog (StartInterval shorter than
# its own run duration, no lock) stacked concurrent Dolt queries and threw
# `bd` i/o-timeouts city-wide. The fix there — and the rule copied here — is
# that a live holder is NEVER reclaimed regardless of heartbeat age (an
# age-OR-dead check previously let a live-but-slow holder's lock get stolen);
# only a holder whose PID is provably dead is reclaimed, via a single-winner
# atomic sentinel so no two backed-off runs can both "win" the reclaim.
SRW_LOCK_ENABLED="${SRW_LOCK_ENABLED:-1}"
SRW_LOCK_DIR="${TMPDIR:-/tmp}/supervisor-restart-watchdog.lock.d"
SRW_LOCK_HB="$SRW_LOCK_DIR/heartbeat"
SRW_LOCK_REAP_TTL="${SRW_LOCK_REAP_TTL:-10}"
SRW_LOCK_TOKEN="${SRW_LOCK_TOKEN:-$$:${RANDOM}${RANDOM}}"

_srw_lock_path_age() {
  local _p="$1" _mt _now
  _now=$(date +%s)
  _mt=$(stat -f %m "$_p" 2>/dev/null || stat -c %Y "$_p" 2>/dev/null || echo "")
  [ -z "$_mt" ] && { echo 999999999; return; }
  echo $(( _now - _mt ))
}

# Empty/non-numeric token → treat as ALIVE (never fast-reclaim); PID reuse
# only falls back to the (still-bounded) mtime/reaping path below, never a
# wrong reclaim of a genuinely live holder.
_srw_lock_holder_dead() {
  local _pid
  _pid=$(head -n1 "$SRW_LOCK_HB" 2>/dev/null | cut -d: -f1 || true)
  case "$_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$_pid" 2>/dev/null && return 1
  return 0
}

_srw_lock_write_hb() { printf '%s\n' "$SRW_LOCK_TOKEN" > "$SRW_LOCK_HB" 2>/dev/null || true; }

# Remove the lock dir only if WE still own it (token match) — never clobber a
# peer that recovered our lock after we were (wrongly) judged stale.
_release_srw_lock() {
  local _own
  _own=$(head -n1 "$SRW_LOCK_HB" 2>/dev/null || true)
  [ "$_own" = "$SRW_LOCK_TOKEN" ] && rm -rf "$SRW_LOCK_DIR" 2>/dev/null
  return 0
}

# Returns 0 if we own the lock, 1 if a LIVE run holds it (caller backs off).
_acquire_srw_lock() {
  if mkdir "$SRW_LOCK_DIR" 2>/dev/null; then
    _srw_lock_write_hb
    if [ ! -s "$SRW_LOCK_HB" ]; then
      rm -rf "$SRW_LOCK_DIR" 2>/dev/null || true
      return 1
    fi
    return 0
  fi
  # Liveness ALONE gates reclaim — age is never a gating input (ga-y0g5x
  # GATE-FEEDBACK correction: age-OR-dead let an old-but-alive holder get its
  # lock stolen).
  if ! _srw_lock_holder_dead; then
    return 1
  fi
  # An absent/empty heartbeat on an existing dir is a holder caught in the µs
  # window between its mkdir and its hb write — treat as LIVE and back off.
  if [ ! -s "$SRW_LOCK_HB" ]; then
    return 1
  fi
  # Single-winner stale reclaim: gate the recovery on ONE atomic sentinel at a
  # FIXED path, and take the stale dir over IN PLACE (heartbeat overwritten,
  # dir never removed) so no entry-mkdir gap is ever exposed to a racing
  # acquirer.
  local _reaping="${SRW_LOCK_DIR}.reaping"
  if ! mkdir "$_reaping" 2>/dev/null; then
    if [ "$(_srw_lock_path_age "$_reaping")" -ge "$SRW_LOCK_REAP_TTL" ]; then
      local _dead="${_reaping}.dead.${SRW_LOCK_TOKEN}"
      if mv "$_reaping" "$_dead" 2>/dev/null; then
        rm -rf "$_dead" 2>/dev/null || true
      fi
    fi
    if ! mkdir "$_reaping" 2>/dev/null; then
      return 1
    fi
  fi
  if ! _srw_lock_holder_dead; then
    rmdir "$_reaping" 2>/dev/null || true
    return 1
  fi
  _srw_lock_write_hb
  if [ ! -s "$SRW_LOCK_HB" ]; then
    rmdir "$_reaping" 2>/dev/null || true
    return 1
  fi
  rmdir "$_reaping" 2>/dev/null || true
  log "Recovered STALE/DEAD lock — taking over (ga-y0g5x pattern)."
  return 0
}

if [ "$SRW_LOCK_ENABLED" = "1" ]; then
  if _acquire_srw_lock; then
    trap '_release_srw_lock' EXIT
  else
    log "Another instance holds the lock — backing off (single-instance guard, ga-y0g5x)."
    exit 0
  fi
fi

# ---- sample ----
SAMPLE_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PRINT_OUT="$(timeout 10 launchctl print "gui/${UID_NUM}/${SUPERVISOR_LABEL}" 2>/dev/null)"
if [ -z "$PRINT_OUT" ]; then
  log "launchctl print returned nothing for ${SUPERVISOR_LABEL} (not loaded, or timed out) — skipping sample."
  exit 0
fi

RUNS="$(printf '%s\n' "$PRINT_OUT" | grep -E '^[[:space:]]*runs = ' | head -1 | grep -oE '[0-9]+')"
EXIT_CODE="$(printf '%s\n' "$PRINT_OUT" | grep -E '^[[:space:]]*last exit code = ' | head -1 | grep -oE -- '-?[0-9]+')"

if [ -z "$RUNS" ]; then
  log "could not parse 'runs =' from launchctl print output — skipping sample."
  exit 0
fi
EXIT_CODE_JSON="${EXIT_CODE:-null}"

# ---- previous state ----
# HAVE_PREV_LOG_OFFSET is tracked separately from PREV_LOG_OFFSET's value —
# "no state file yet" and "prior offset was legitimately 0 (log started
# empty)" must not collapse onto the same "0", the same way PREV_RUNS above
# uses an empty-string sentinel rather than defaulting to "0" for a fresh
# counter. Collapsing them would silently skip reason-matching on the second
# sample of the watchdog's life whenever the log happened to start empty.
PREV_RUNS=""
PREV_LOG_OFFSET=0
HAVE_PREV_LOG_OFFSET=false
if [ -f "$STATE_FILE" ]; then
  PREV_RUNS="$(jq -r '.runs // empty' "$STATE_FILE" 2>/dev/null)"
  _raw_prev_offset="$(jq -r '.log_offset // empty' "$STATE_FILE" 2>/dev/null)"
  case "$_raw_prev_offset" in
    ''|*[!0-9]*) ;;
    *) PREV_LOG_OFFSET="$_raw_prev_offset"; HAVE_PREV_LOG_OFFSET=true ;;
  esac
fi

DELTA=0
COUNTER_RESET=false
if [ -n "$PREV_RUNS" ]; then
  if [ "$RUNS" -ge "$PREV_RUNS" ]; then
    DELTA=$(( RUNS - PREV_RUNS ))
  else
    # `runs` went backwards: the job was unloaded/reloaded (or the machine
    # rebooted) since the last sample, resetting launchd's own counter. Not a
    # restart count we can attribute — record it, don't fabricate a delta.
    COUNTER_RESET=true
  fi
fi

# ---- reason detection (only meaningful when DELTA>0) ----
# Exit code is read straight off this sample. For a textual reason, grep only
# the supervisor.log bytes appended SINCE the previous sample's byte offset —
# bounded, not a rescan of a 100MB+ file — for the OS_REASON_*/codesign
# signature this bug was originally filed against. Store a match COUNT, not
# the raw matched lines: keeps the ledger schema simple and avoids needing to
# JSON-escape arbitrary log content.
REASON_EXIT_NONZERO=false
if [ "$EXIT_CODE_JSON" != "null" ] && [ "$EXIT_CODE_JSON" != "0" ]; then
  REASON_EXIT_NONZERO=true
fi

LOG_SIZE=0
CODESIGN_MATCHES=0
if [ -f "$SUPERVISOR_LOG" ]; then
  LOG_SIZE="$(stat -f %z "$SUPERVISOR_LOG" 2>/dev/null || stat -c %s "$SUPERVISOR_LOG" 2>/dev/null || echo 0)"
  if [ "$DELTA" -gt 0 ] && [ "$HAVE_PREV_LOG_OFFSET" = "true" ] && [ "$LOG_SIZE" -ge "$PREV_LOG_OFFSET" ]; then
    CODESIGN_MATCHES="$(tail -c "+$((PREV_LOG_OFFSET + 1))" "$SUPERVISOR_LOG" 2>/dev/null | grep -Eic 'OS_REASON|codesign' || true)"
    case "$CODESIGN_MATCHES" in ''|*[!0-9]*) CODESIGN_MATCHES=0 ;; esac
  fi
fi

# ---- append ledger record ----
# Pure-bash printf, not a piped jq: a single printf-to-an-append-fd is one
# write() syscall, atomic for payloads under PIPE_BUF (64KiB) per POSIX — the
# same guarantee gc_ledger.py's O_APPEND writer relies on. Every field here is
# either an integer, a bash-literal true/false, or a timestamp WE generated —
# none can contain a quote/backslash/newline, so no escaping is needed and no
# external process sits on the write's atomicity.
RECORD=$(printf '{"ts":"%s","runs":%s,"last_exit_code":%s,"delta_since_last":%s,"counter_reset":%s,"reason_exit_nonzero":%s,"reason_log_matches":%s,"log_offset":%s}' \
  "$SAMPLE_TS" "$RUNS" "$EXIT_CODE_JSON" "$DELTA" "$COUNTER_RESET" "$REASON_EXIT_NONZERO" "$CODESIGN_MATCHES" "$LOG_SIZE")
printf '%s\n' "$RECORD" >> "$LEDGER_FILE"

# ---- persist state (atomic replace via temp+mv; jq is fine here since the
# atomicity comes from mv, not from jq's own write) ----
TMP_STATE="$(mktemp "${STATE_FILE}.XXXXXX")"
jq -n --argjson runs "$RUNS" --argjson last_exit_code "$EXIT_CODE_JSON" \
  --argjson log_offset "$LOG_SIZE" --arg sample_ts "$SAMPLE_TS" \
  '{runs:$runs, last_exit_code:$last_exit_code, log_offset:$log_offset, sample_ts:$sample_ts}' \
  > "$TMP_STATE" 2>/dev/null
mv "$TMP_STATE" "$STATE_FILE"

if [ "$DELTA" -gt 0 ]; then
  log "runs=${RUNS} (+${DELTA} since last sample) last_exit_code=${EXIT_CODE_JSON} log_matches=${CODESIGN_MATCHES}"
elif [ "$COUNTER_RESET" = "true" ]; then
  log "runs=${RUNS} — counter went backwards vs prev=${PREV_RUNS} (job reload/reboot), not counted as restarts"
fi
exit 0
