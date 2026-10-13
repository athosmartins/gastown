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
# .gc/logs/supervisor-restart-watchdog.jsonl. The COUNTER half never restarts,
# reconfigures, or otherwise touches the supervisor — see ga-b0gltl for why
# that was out of scope until the counter told us the real frequency.
#
# The ONE exception is the fd guard (ga-xuo89c): the engine's config watcher
# leaks its whole watch set on every reload (ga-0ox5tq, fsnotify v1.9.0), the
# supervisor hit the 61,440 per-process ceiling on 13/10 ~8.5h after boot and
# the city went ~1h30 without viable sessions. Until the engine window ships
# the real fix, every sample also counts the supervisor's open fds:
#   fds <= 30,000 .......... nothing (the number is only recorded)
#   30,000 < fds <= 40,000 . recorded + a log line, NO action
#   fds > 40,000 ........... `launchctl kickstart -k` on the supervisor, a
#                            `notify -p 4`, and no second restart within 30 min
# A count that could not be read (no pid, lsof failed/timed out/unparsable) is
# `fds:null` with the reason in `fds_state` and NEVER restarts anything — an
# unread number is not a big number. The 30-min cooldown lives in its own file
# (supervisor-fds-guard.json) because the sample state below is rewritten
# wholesale every cycle. Thresholds/timeouts are env-overridable (SRW_*) for
# the selftest only; launchd runs the defaults.
#
# Answering "how many times did it DIE in the last 24h and why" is then a jq
# query against the ledger (delta_guard_restart = restarts the fd guard itself
# caused, so they are not counted as deaths):
#   jq -s --arg since "$(date -u -v-1d +%Y-%m-%dT%H:%M:%SZ)" \
#     '[.[] | select(.ts >= $since)] | {deaths: (map(.delta_since_last - (.delta_guard_restart // 0)) | add), samples: length}' \
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

# ---- fd guard configuration (ga-xuo89c) ----
# A non-numeric override falls back to the default instead of becoming a
# threshold the arithmetic below would choke on (or, worse, read as 0).
_srw_num() { case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
FDS_WARN="$(_srw_num "${SRW_FDS_WARN:-}" 30000)"
FDS_RESTART="$(_srw_num "${SRW_FDS_RESTART:-}" 40000)"
FDS_COOLDOWN_SEC="$(_srw_num "${SRW_FDS_COOLDOWN_SEC:-}" 1800)"
# lsof on a leaking supervisor has to walk tens of thousands of fds, so the
# bound is generous; launchd never overlaps two runs of the same job and the
# instance lock below covers the manual case.
SRW_LSOF_TIMEOUT="$(_srw_num "${SRW_LSOF_TIMEOUT:-}" 120)"
SRW_RESTART_WAIT="$(_srw_num "${SRW_RESTART_WAIT:-}" 60)"
SRW_RESTART_POLL="${SRW_RESTART_POLL:-2}"
SRW_TMUX_SOCKET="${SRW_TMUX_SOCKET:-gascity}"
GUARD_STATE_FILE="$STATE_DIR/supervisor-fds-guard.json"

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

# The job's pid is the first top-level `pid = N` line. Absent while the job is
# between runs (just died, launchd has not respawned it yet) — the fd guard
# below reads that as "no pid", not as "0 fds".
SUP_PID="$(printf '%s\n' "$PRINT_OUT" | grep -E '^[[:space:]]*pid = [0-9]+[[:space:]]*$' | head -1 | grep -oE '[0-9]+')"
NOW_EPOCH="$(date +%s)"

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

# LOG_CHECKED distinguishes "grepped the log window, found 0 matches" from
# "never attempted the grep this sample" (log file missing/rotated, no valid
# prior offset yet, or no restart to explain) — both would otherwise report
# reason_log_matches=0, making "confirmed never codesign" indistinguishable
# from "we have no idea, the check never ran" over the 7-day observation
# window this bead's acceptance criteria depends on.
LOG_SIZE=0
CODESIGN_MATCHES=0
LOG_CHECKED=false
if [ -f "$SUPERVISOR_LOG" ]; then
  LOG_SIZE="$(stat -f %z "$SUPERVISOR_LOG" 2>/dev/null || stat -c %s "$SUPERVISOR_LOG" 2>/dev/null || echo 0)"
  if [ "$DELTA" -gt 0 ] && [ "$HAVE_PREV_LOG_OFFSET" = "true" ] && [ "$LOG_SIZE" -ge "$PREV_LOG_OFFSET" ]; then
    CODESIGN_MATCHES="$(tail -c "+$((PREV_LOG_OFFSET + 1))" "$SUPERVISOR_LOG" 2>/dev/null | grep -Eic 'OS_REASON|codesign' || true)"
    case "$CODESIGN_MATCHES" in ''|*[!0-9]*) CODESIGN_MATCHES=0 ;; esac
    LOG_CHECKED=true
  fi
fi

# ---- fd guard (ga-xuo89c) ----
# Three states for the fd count, never two: a number (ok), "could not read it"
# (no_pid / lsof_timeout / lsof_failed / lsof_unparsable — FDS stays empty), and
# nothing in between. Only a number above the threshold can restart anything.

# Counts the supervisor's open FILE DESCRIPTORS (lsof rows whose FD column is
# a number plus an optional access-mode/lock suffix: 12r, 7u, 7uW, 255 — not
# cwd/txt/mem, which never touch the descriptor table the 61,440 ceiling is
# about). Sets M_FDS (integer or "") and M_STATE.
_srw_measure_fds() {
  local _pid="$1" _tmp _rc _n
  M_FDS=""
  # vazio → no pid means "no_pid", fds stays empty; falhou/ilegível → same (never a 0)
  case "$_pid" in ''|*[!0-9]*) M_STATE="no_pid"; return 0 ;; esac
  _tmp="$(mktemp "${TMPDIR:-/tmp}/srw-lsof.XXXXXX" 2>/dev/null)" || { M_STATE="lsof_failed"; return 0; }
  # -n -P: no DNS / service-name lookups — with tens of thousands of sockets they are what makes lsof slow.
  # The output goes to a file and lsof's status is read on its own: a run that
  # timed out (124) leaves a PARTIAL table, and a partial table must never be counted.
  # vazio → no header / no numeric rows = "lsof_unparsable"; falhou/ilegível → timeout = "lsof_timeout", other rc = "lsof_failed"
  timeout "$SRW_LSOF_TIMEOUT" lsof -n -P -p "$_pid" > "$_tmp" 2>/dev/null
  _rc=$?
  case "$_rc" in
    124|137) M_STATE="lsof_timeout" ;;
    0|1)
      # rc 1 is lsof's "some warning"; the rows are still usable if the header and at least one fd are there.
      _n="$(awk 'NR == 1 { hdr = ($1 == "COMMAND"); next } $4 ~ /^[0-9]+[a-zA-Z]*$/ { n++ } END { if (hdr && n > 0) print n; else print "bad" }' "$_tmp" 2>/dev/null)"
      case "$_n" in
        ''|*[!0-9]*) M_STATE="lsof_unparsable" ;;
        *) M_FDS="$_n"; M_STATE="ok" ;;
      esac ;;
    *) M_STATE="lsof_failed" ;;
  esac
  rm -f "$_tmp" 2>/dev/null
  return 0
}

# Prints the number of tmux sessions on the city's socket, or "null" when tmux
# did not answer. Evidence only — no decision depends on it.
_srw_count_sessions() {
  local _out
  # vazio → rc 0 with no lines is 0 sessions; falhou/ilegível → non-zero rc (no server, timeout) is "null" (unknown, not 0)
  _out="$(timeout 10 tmux -L "$SRW_TMUX_SOCKET" list-sessions -F x 2>/dev/null)" || { printf 'null'; return 0; }
  printf '%s' "$(printf '%s\n' "$_out" | grep -c .)"
}

# Best effort: a notify that fails or hangs must not change what the guard did.
_srw_notify() {
  command -v notify >/dev/null 2>&1 || return 0
  timeout 20 notify -t "Supervisor fd guard" -p 4 "$1" >/dev/null 2>&1 || log "WARN: notify failed or timed out"
  return 0
}

# ---- cooldown state: its own file, not the sample state ----
# The sample state is rewritten wholesale (4 fields) at the end of every run;
# a cooldown kept there would be wiped one cycle after the restart.
GS_STATE_KIND="absent"      # absent | ok | unreadable
GS_LAST_EPOCH=""
GS_RUNS_AT_RESTART=""

_srw_guard_state_read() {
  local _e _r
  GS_LAST_EPOCH=""; GS_RUNS_AT_RESTART=""
  # vazio → no file = never restarted, the guard may act; falhou/ilegível → "unreadable", the guard does NOT act on it
  [ -e "$GUARD_STATE_FILE" ] || { GS_STATE_KIND="absent"; return 0; }
  _e="$(jq -r '.last_restart_epoch // empty' "$GUARD_STATE_FILE" 2>/dev/null)"
  case "$_e" in ''|*[!0-9]*) GS_STATE_KIND="unreadable"; return 0 ;; esac
  # A stamp further ahead than one cooldown window cannot be a real past restart
  # (clock stepped back, or a garbage value) — unreadable, so it is quarantined
  # and re-stamped instead of blocking the guard for the rest of that future.
  if [ "$_e" -gt $(( NOW_EPOCH + FDS_COOLDOWN_SEC )) ]; then GS_STATE_KIND="unreadable"; return 0; fi
  _r="$(jq -r '.runs_at_restart // empty' "$GUARD_STATE_FILE" 2>/dev/null)"
  case "$_r" in *[!0-9]*) _r="" ;; esac
  GS_LAST_EPOCH="$_e"; GS_RUNS_AT_RESTART="$_r"; GS_STATE_KIND="ok"
}

# _srw_guard_state_write <runs_at_restart|null> <pid|null> <fds|null> <inferred:true|false>
# Stamps NOW as the last restart. temp+mv: a reader sees the old file or the
# new one, never half of one. rc != 0 means the stamp did NOT land.
_srw_guard_state_write() {
  local _tmp
  _tmp="$(mktemp "${GUARD_STATE_FILE}.XXXXXX" 2>/dev/null)" || return 1
  if jq -n --argjson e "$NOW_EPOCH" --arg ts "$SAMPLE_TS" --argjson r "$1" --argjson p "$2" --argjson f "$3" --argjson i "$4" \
       '{last_restart_epoch:$e, last_restart_ts:$ts, runs_at_restart:$r, pid_before:$p, fds_before:$f, inferred:$i}' > "$_tmp" 2>/dev/null \
     && [ -s "$_tmp" ] && mv "$_tmp" "$GUARD_STATE_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$_tmp" 2>/dev/null
  return 1
}

# Everything the ledger/notify say about the guard. Strings are from a fixed
# vocabulary and numbers are integers or the literal null — nothing needs
# JSON-escaping (same invariant as the record below).
FDS="";            FDS_STATE="no_pid"
GUARD_ACTION="none"
RESTART_NEW_PID="null"; FDS_AFTER="null"
SESSIONS_BEFORE="null"; SESSIONS_AFTER="null"
COOLDOWN_REMAINING="null"

_srw_guard_state_read

# Restarts the guard itself caused are in `runs` too (kickstart -k = +1), so
# they would be counted as deaths. The window (PREV_RUNS, RUNS] holds the
# guard's restart iff the runs value it stamped at kick time (the value BEFORE
# the +1) lies in [PREV_RUNS, RUNS). Stateless: nothing to clear afterwards.
DELTA_GUARD=0
if [ "$GS_STATE_KIND" = "ok" ] && [ -n "$GS_RUNS_AT_RESTART" ] && [ -n "$PREV_RUNS" ] \
   && [ "$COUNTER_RESET" = "false" ] && [ "$DELTA" -gt 0 ] \
   && [ "$GS_RUNS_AT_RESTART" -ge "$PREV_RUNS" ] && [ "$GS_RUNS_AT_RESTART" -lt "$RUNS" ]; then
  DELTA_GUARD=1
fi

# Sets GUARD_ACTION (+ the evidence variables) for a count above FDS_RESTART.
_srw_fds_guard_restart() {
  local _age _rc _deadline _p
  case "$GS_STATE_KIND" in
    unreadable)
      # Keep the bad file for whoever looks, then re-stamp "restarted just now"
      # (inferred): the inert direction — no restart for one window — and it
      # heals itself instead of staying unreadable forever.
      cp "$GUARD_STATE_FILE" "${GUARD_STATE_FILE}.unreadable.${NOW_EPOCH}" 2>/dev/null
      if _srw_guard_state_write null null null true; then
        GUARD_ACTION="cooldown_state_unreadable"
      else
        GUARD_ACTION="state_unwritable"
      fi
      return 0 ;;
    ok)
      _age=$(( NOW_EPOCH - GS_LAST_EPOCH ))
      if [ "$_age" -lt "$FDS_COOLDOWN_SEC" ]; then
        GUARD_ACTION="cooldown"
        COOLDOWN_REMAINING=$(( FDS_COOLDOWN_SEC - _age ))
        return 0
      fi ;;
  esac
  # Stamp the cooldown BEFORE the kick: if this run dies or hangs after
  # kickstart, the next cycle must already see the restart. And if the stamp
  # cannot be written, no restart — a restart that can't be rate-limited
  # could loop every 15 min.
  if ! _srw_guard_state_write "$RUNS" "${SUP_PID:-null}" "$FDS" false; then
    GUARD_ACTION="state_unwritable"
    return 0
  fi
  SESSIONS_BEFORE="$(_srw_count_sessions)"
  log "fds=${FDS} > ${FDS_RESTART} on pid ${SUP_PID} — kickstart -k ${SUPERVISOR_LABEL} (cooldown ${FDS_COOLDOWN_SEC}s stamped)"
  timeout 30 launchctl kickstart -k "gui/${UID_NUM}/${SUPERVISOR_LABEL}" >/dev/null 2>&1
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    GUARD_ACTION="restart_failed"
    return 0
  fi
  GUARD_ACTION="restart_unconfirmed"
  _deadline=$(( SECONDS + SRW_RESTART_WAIT ))
  while [ "$SECONDS" -lt "$_deadline" ]; do
    # vazio → no pid line yet = not respawned, keep waiting; falhou/ilegível → same, bounded by the deadline
    _p="$(timeout 10 launchctl print "gui/${UID_NUM}/${SUPERVISOR_LABEL}" 2>/dev/null \
          | grep -E '^[[:space:]]*pid = [0-9]+[[:space:]]*$' | head -1 | grep -oE '[0-9]+')"
    if [ -n "$_p" ] && [ "$_p" != "$SUP_PID" ]; then
      RESTART_NEW_PID="$_p"
      GUARD_ACTION="restart_ok"
      break
    fi
    sleep "$SRW_RESTART_POLL"
  done
  # The city's tmux server is not in the supervisor's process group (observed
  # 2026-10-13: ppid 1, own pgid), so launchd's group kill should not reach it;
  # the before/after counts are the evidence that the sessions really survived (AC 3 of ga-xuo89c).
  SESSIONS_AFTER="$(_srw_count_sessions)"
  if [ "$GUARD_ACTION" = "restart_ok" ]; then
    _srw_measure_fds "$RESTART_NEW_PID"
    [ "$M_STATE" = "ok" ] && FDS_AFTER="$M_FDS"
  fi
  return 0
}

_srw_measure_fds "$SUP_PID"
FDS="$M_FDS"; FDS_STATE="$M_STATE"
if [ "$FDS_STATE" != "ok" ]; then
  GUARD_ACTION="unreadable"
  log "fds not readable (${FDS_STATE}) — no action taken"
elif [ "$FDS" -gt "$FDS_RESTART" ]; then
  _srw_fds_guard_restart
elif [ "$FDS" -gt "$FDS_WARN" ]; then
  GUARD_ACTION="warn"
  log "fds=${FDS} > ${FDS_WARN} (restart above ${FDS_RESTART}) — recorded only"
fi

case "$GUARD_ACTION" in
  restart_ok)
    _srw_notify "supervisor had ${FDS} fds (> ${FDS_RESTART}): restarted. pid ${SUP_PID} -> ${RESTART_NEW_PID}; fds after: ${FDS_AFTER}; tmux sessions ${SESSIONS_BEFORE} -> ${SESSIONS_AFTER}." ;;
  restart_unconfirmed)
    _srw_notify "supervisor had ${FDS} fds (> ${FDS_RESTART}): kickstart sent but no new pid within ${SRW_RESTART_WAIT}s. tmux sessions ${SESSIONS_BEFORE} -> ${SESSIONS_AFTER}. Check the supervisor." ;;
  restart_failed)
    _srw_notify "supervisor has ${FDS} fds (> ${FDS_RESTART}) and kickstart FAILED. Next try after the ${FDS_COOLDOWN_SEC}s cooldown." ;;
  cooldown)
    _srw_notify "supervisor has ${FDS} fds (> ${FDS_RESTART}) again inside the ${FDS_COOLDOWN_SEC}s cooldown — NOT restarting (${COOLDOWN_REMAINING}s left). A fresh process should not leak this fast." ;;
  cooldown_state_unreadable|state_unwritable)
    _srw_notify "supervisor has ${FDS} fds (> ${FDS_RESTART}) but the guard state (${GUARD_STATE_FILE}) is ${GUARD_ACTION} — NOT restarting." ;;
esac

# ---- append ledger record ----
# Pure-bash printf, not a piped jq: a single printf-to-an-append-fd is one
# write() syscall, atomic for payloads under PIPE_BUF (64KiB) per POSIX — the
# same guarantee gc_ledger.py's O_APPEND writer relies on. Every field here is
# either an integer, the literal null, a bash-literal true/false, a string from
# the fixed vocabulary above, or a timestamp WE generated — none can contain a
# quote/backslash/newline, so no escaping is needed and no external process
# sits on the write's atomicity.
RECORD=$(printf '{"ts":"%s","runs":%s,"last_exit_code":%s,"delta_since_last":%s,"counter_reset":%s,"reason_exit_nonzero":%s,"reason_log_matches":%s,"log_checked":%s,"log_offset":%s,"pid":%s,"fds":%s,"fds_state":"%s","guard_action":"%s","delta_guard_restart":%s,"restart_new_pid":%s,"fds_after":%s,"sessions_before":%s,"sessions_after":%s,"cooldown_remaining_s":%s}' \
  "$SAMPLE_TS" "$RUNS" "$EXIT_CODE_JSON" "$DELTA" "$COUNTER_RESET" "$REASON_EXIT_NONZERO" "$CODESIGN_MATCHES" "$LOG_CHECKED" "$LOG_SIZE" \
  "${SUP_PID:-null}" "${FDS:-null}" "$FDS_STATE" "$GUARD_ACTION" "$DELTA_GUARD" "$RESTART_NEW_PID" "$FDS_AFTER" "$SESSIONS_BEFORE" "$SESSIONS_AFTER" "$COOLDOWN_REMAINING")
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
