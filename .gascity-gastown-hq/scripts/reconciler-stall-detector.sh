#!/bin/bash
# reconciler-stall-detector.sh (ga-srp8hk) — detection-only alert for
# com.gascity.supervisor being ALIVE but its session-reconciler loop not
# advancing.
#
# Measured 2026-09-18 (Mayor): the reconciler stopped landing new trace
# records 3 times in one hour (up to 19min each) while the supervisor
# process itself never died. No session came up, gate reviewers sat
# start-pending with wake_attempts=0, and the gate went ~1h without
# evaluating anything before Athos noticed by hand. supervisor-restart-
# watchdog.sh (ga-b0gltl) only counts launchd `runs` deltas — a supervisor
# that is up but stuck is invisible to it by design. This script is that
# gap's complement: it reads the session-reconciler-trace's own append-only
# log of its ticks (.gc/runtime/session-reconciler-trace/segments/YYYY/MM/DD/
# segment-*.jsonl, one JSON record per line, `ts` field) and asks a single
# question every invocation: how long since the last record landed?
#
# Three states, in priority order:
#   UNKNOWN  — supervisor confirmed NOT running (out of scope: that's
#              ga-b0gltl's job, not duplicated here), OR the trace dir/file
#              is missing, OR the tail of the latest segment has no
#              parseable `ts` in its last few lines. An unreadable state is
#              never silently promoted to OK — see AC1 in ga-srp8hk.
#   STALLED  — supervisor alive, trace readable, but the last record is
#              older than the threshold (default 300s). Only this state
#              pages (mail to Mayor + notify), with a cooldown so one long
#              episode doesn't spam.
#   OK       — supervisor alive, last record inside the threshold.
#
# Deliberately a raw launchd StartInterval plist (reconciler-stall-
# detector.plist), NOT a `gc order` (cooldown-trigger exec order): `gc
# order` triggers are evaluated from INSIDE com.gascity.supervisor's own
# tick loop (confirmed live via `gc: order dispatch: checking open work
# for ...` in ~/.gc/supervisor.log) — the exact loop this script exists to
# catch when it wedges. A gc-order-scheduled guard would likely stop firing
# together with the thing it watches, which is self-defeating. launchd
# itself is external to the supervisor and keeps firing regardless — same
# reasoning supervisor-restart-watchdog.sh (the one other guard watching
# this exact process) already used for the same choice.
#
# NEVER restarts, reconfigures, kicks, or otherwise touches the supervisor
# or anything it manages. Detection + alert only — a stuck supervisor is a
# far higher blast radius than a leaf daemon and needs a deliberate
# human/Mayor call (same scoping as ga-b0gltl).
#
# TEST: bash reconciler-stall-detector.selftest.sh
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
TRACE_ROOT="${SESSION_RECONCILER_TRACE_ROOT:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/session-reconciler-trace}"
SEGMENTS_DIR="$TRACE_ROOT/segments"
STALL_THRESHOLD_SEC="${RSD_STALL_THRESHOLD_SEC:-300}"
STATE_DIR="${RSD_STATE_DIR:-$CITY/.gc/state}"
COOLDOWN_FILE="${RSD_COOLDOWN_FILE:-$STATE_DIR/reconciler-stall-detector-last-alert}"
ALERT_COOLDOWN_SEC="${RSD_ALERT_COOLDOWN_SEC:-900}"
LOG="${RSD_LOG:-$CITY/.gc/logs/reconciler-stall-detector.log}"
SUPERVISOR_LABEL="${RSD_SUPERVISOR_LABEL:-com.gascity.supervisor}"
SUPERVISOR_LOG="${GC_SUPERVISOR_LOG:-/Users/athos/.gc/supervisor.log}"
UID_NUM="$(id -u)"
NOTIFY_BIN="${NOTIFY_BIN:-notify}"
GC_BIN="${GC_BIN:-gc}"
BD_LIST_CACHED="${RSD_BD_LIST_CACHED:-$CITY/scripts/bd-list-cached.sh}"
MAYOR_ADDR="${RSD_MAYOR_ADDR:-mayor}"
MAYOR_ADDR_FALLBACK="${RSD_MAYOR_ADDR_FALLBACK:-gastown.mayor}"
# Test-only seam: freeze "now" for deterministic selftest/replay. Empty in
# production, where real wall-clock time is always used.
NOW_EPOCH_OVERRIDE="${RSD_NOW_EPOCH:-}"

mkdir -p "$STATE_DIR" "$(dirname "$LOG")" 2>/dev/null || true
log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [reconciler-stall-detector] $*" >> "$LOG" 2>/dev/null || true; }

# ---- single-instance lock ----
# Copied (liveness-only reclaim kept verbatim in spirit) from
# supervisor-restart-watchdog.sh's own port of pilot-missing-route-
# watchdog.sh's lock (ga-y0g5x: concurrent instances of a lock-less watchdog
# stacked Dolt queries and threw i/o-timeouts city-wide) — this script does
# its own Dolt read (bd list, for the start-pending count) on the alert
# path, so it is exposed to exactly that failure mode too. A live holder is
# NEVER reclaimed regardless of heartbeat age; only a provably-dead PID is
# reclaimed, via a single-winner atomic sentinel.
RSD_LOCK_ENABLED="${RSD_LOCK_ENABLED:-1}"
RSD_LOCK_DIR="${TMPDIR:-/tmp}/reconciler-stall-detector.lock.d"
RSD_LOCK_HB="$RSD_LOCK_DIR/heartbeat"
RSD_LOCK_REAP_TTL="${RSD_LOCK_REAP_TTL:-10}"
RSD_LOCK_TOKEN="${RSD_LOCK_TOKEN:-$$:${RANDOM}${RANDOM}}"

_rsd_lock_path_age() {
  local _p="$1" _mt _now
  _now=$(date +%s)
  _mt=$(stat -f %m "$_p" 2>/dev/null || stat -c %Y "$_p" 2>/dev/null || echo "")
  [ -z "$_mt" ] && { echo 999999999; return; }
  echo $(( _now - _mt ))
}

_rsd_lock_holder_dead() {
  local _pid
  _pid=$(head -n1 "$RSD_LOCK_HB" 2>/dev/null | cut -d: -f1 || true)
  case "$_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$_pid" 2>/dev/null && return 1
  return 0
}

_rsd_lock_write_hb() { printf '%s\n' "$RSD_LOCK_TOKEN" > "$RSD_LOCK_HB" 2>/dev/null || true; }

_release_rsd_lock() {
  local _own
  _own=$(head -n1 "$RSD_LOCK_HB" 2>/dev/null || true)
  [ "$_own" = "$RSD_LOCK_TOKEN" ] && rm -rf "$RSD_LOCK_DIR" 2>/dev/null
  return 0
}

_acquire_rsd_lock() {
  if mkdir "$RSD_LOCK_DIR" 2>/dev/null; then
    _rsd_lock_write_hb
    if [ ! -s "$RSD_LOCK_HB" ]; then
      rm -rf "$RSD_LOCK_DIR" 2>/dev/null || true
      return 1
    fi
    return 0
  fi
  if ! _rsd_lock_holder_dead; then
    return 1
  fi
  if [ ! -s "$RSD_LOCK_HB" ]; then
    return 1
  fi
  local _reaping="${RSD_LOCK_DIR}.reaping"
  if ! mkdir "$_reaping" 2>/dev/null; then
    if [ "$(_rsd_lock_path_age "$_reaping")" -ge "$RSD_LOCK_REAP_TTL" ]; then
      local _dead="${_reaping}.dead.${RSD_LOCK_TOKEN}"
      if mv "$_reaping" "$_dead" 2>/dev/null; then
        rm -rf "$_dead" 2>/dev/null || true
      fi
    fi
    if ! mkdir "$_reaping" 2>/dev/null; then
      return 1
    fi
  fi
  if ! _rsd_lock_holder_dead; then
    rmdir "$_reaping" 2>/dev/null || true
    return 1
  fi
  _rsd_lock_write_hb
  if [ ! -s "$RSD_LOCK_HB" ]; then
    rmdir "$_reaping" 2>/dev/null || true
    return 1
  fi
  rmdir "$_reaping" 2>/dev/null || true
  log "Recovered STALE/DEAD lock — taking over (ga-y0g5x pattern)."
  return 0
}

if [ "$RSD_LOCK_ENABLED" = "1" ]; then
  if _acquire_rsd_lock; then
    trap '_release_rsd_lock' EXIT
  else
    log "Another instance holds the lock — backing off (single-instance guard, ga-y0g5x pattern)."
    echo "reconciler-stall-detector: another instance holds the lock — backing off"
    exit 0
  fi
fi

# ---- helpers ----

now_epoch() {
  if [ -n "$NOW_EPOCH_OVERRIDE" ]; then
    printf '%s\n' "$NOW_EPOCH_OVERRIDE"
  else
    date -u +%s
  fi
}

# find_latest_segment: newest-mtime segment-*.jsonl anywhere under
# segments/. Retention keeps only a few days (session-reconciler-trace-
# prune.sh caps at 3d by default), so this is always a handful of files —
# no need to assume "today's" UTC day-dir holds the newest file (it does
# not, right after a UTC-midnight rollover).
find_latest_segment() {
  find "$SEGMENTS_DIR" -type f -name 'segment-*.jsonl' -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1
}

# last_valid_ts <file>: the `ts` field of the last COMPLETE, parseable JSON
# line in the tail of the file. Reads only the last 64KiB (segments run
# multiple MB — CLAUDE.md's own Dolt-log guidance already names this
# pattern: "ler so o fim do arquivo"), then walks the last 5 lines
# newest-first so a partial trailing write (the segment is actively being
# appended to) doesn't produce a false UNKNOWN when the second-to-last line
# is perfectly good.
last_valid_ts() {
  local f="$1"
  tail -c 65536 "$f" 2>/dev/null | tail -n 5 | python3 -c '
import json, sys
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
for line in reversed(lines):
    try:
        rec = json.loads(line)
    except Exception:
        continue
    t = rec.get("ts")
    if t:
        print(t)
        break
'
}

# age_sec_since <ts>: seconds between <ts> (ISO8601, Z suffix) and "now"
# (real wall clock, or RSD_NOW_EPOCH override for tests/replay). Empty
# stdout + exit 1 on any parse failure — never a fabricated number.
age_sec_since() {
  local ts="$1" now_ep
  now_ep=$(now_epoch)
  python3 -c '
import datetime, sys
ts, now_ep = sys.argv[1], int(sys.argv[2])
try:
    t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
except Exception:
    sys.exit(1)
now = datetime.datetime.fromtimestamp(now_ep, tz=datetime.timezone.utc)
print(int((now - t).total_seconds()))
' "$ts" "$now_ep"
}

# supervisor_alive: 0 if com.gascity.supervisor is loaded AND launchctl
# reports a live pid, 1 otherwise. Uses `launchctl print`, never
# pgrep/`ps aux | grep` by keyword — a broad keyword match in this city
# routinely false-positives on unrelated agent sessions whose injected
# system prompt happens to contain the keyword (ga-0bjqix class of bug).
# Same idiom as supervisor-restart-watchdog.sh's own PID discovery.
supervisor_alive() {
  local print_out pid
  print_out="$(timeout 10 launchctl print "gui/${UID_NUM}/${SUPERVISOR_LABEL}" 2>/dev/null)"
  [ -z "$print_out" ] && return 1
  pid="$(printf '%s\n' "$print_out" | grep -E '^[[:space:]]*pid = ' | head -1 | grep -oE '[0-9]+')"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# ---- state determination ----
STATE="UNKNOWN"
REASON=""
AGE_SEC=""
LAST_TS=""
SEG_FILE=""

if ! supervisor_alive; then
  REASON="supervisor_not_running (launchctl print gui/${UID_NUM}/${SUPERVISOR_LABEL} empty or no pid — out of scope, see ga-b0gltl)"
elif [ ! -d "$SEGMENTS_DIR" ]; then
  REASON="no_segments_dir ($SEGMENTS_DIR)"
else
  SEG_FILE="$(find_latest_segment)"
  if [ -z "$SEG_FILE" ] || [ ! -f "$SEG_FILE" ]; then
    REASON="no_segment_file_found under $SEGMENTS_DIR"
  else
    LAST_TS="$(last_valid_ts "$SEG_FILE")"
    if [ -z "$LAST_TS" ]; then
      REASON="unparseable_tail (no valid ts in last 5 lines of $SEG_FILE)"
    else
      AGE_SEC="$(age_sec_since "$LAST_TS")"
      if [ -z "$AGE_SEC" ]; then
        REASON="bad_ts_format ($LAST_TS)"
      elif [ "$AGE_SEC" -gt "$STALL_THRESHOLD_SEC" ]; then
        STATE="STALLED"
      else
        STATE="OK"
      fi
    fi
  fi
fi

log "state=$STATE age_sec=${AGE_SEC:-} last_ts=${LAST_TS:-} seg=${SEG_FILE:-} reason=${REASON:-}"

case "$STATE" in
  OK)
    # Clear any stale cooldown so a FUTURE, distinct stall episode alerts
    # immediately rather than silently inheriting this episode's window.
    rm -f "$COOLDOWN_FILE" 2>/dev/null || true
    echo "reconciler-stall-detector: OK age_sec=$AGE_SEC"
    exit 0
    ;;
  UNKNOWN)
    # Reported, never silently promoted to OK -- but not itself paged: an
    # unreadable trace is genuinely inconclusive, and "supervisor not
    # running" is ga-b0gltl's alert to send, not duplicated here.
    echo "reconciler-stall-detector: UNKNOWN ($REASON)"
    exit 0
    ;;
esac

# ---- STALLED: cooldown check before doing any paging work ----
NOW_EP="$(now_epoch)"
if [ -f "$COOLDOWN_FILE" ]; then
  LAST_ALERT_EP="$(cat "$COOLDOWN_FILE" 2>/dev/null)" || LAST_ALERT_EP=0
  case "$LAST_ALERT_EP" in ''|*[!0-9]*) LAST_ALERT_EP=0 ;; esac
  if [ "$LAST_ALERT_EP" -gt 0 ]; then
    ELAPSED=$(( NOW_EP - LAST_ALERT_EP ))
    if [ "$ELAPSED" -lt "$ALERT_COOLDOWN_SEC" ]; then
      log "STALLED persists (age_sec=$AGE_SEC) -- cooldown active (${ELAPSED}s/${ALERT_COOLDOWN_SEC}s) -- suppressing dup alert"
      echo "reconciler-stall-detector: STALLED age_sec=$AGE_SEC (alert suppressed, cooldown ${ELAPSED}s/${ALERT_COOLDOWN_SEC}s)"
      exit 0
    fi
  fi
fi

# ---- gather alert diagnostics (only reached when actually about to page) ----
AGE_MIN=$(( AGE_SEC / 60 ))
SWAP_LINE="$(sysctl vm.swapusage 2>/dev/null)"
# supervisor.log routinely mis-classifies as binary to plain `grep` (BSD
# grep on this file's very-long-line UTF-8 text) and silently returns
# nothing -- always `grep -a` here.
IOTIMEOUT_LINES="$(tail -c 200000 "$SUPERVISOR_LOG" 2>/dev/null | grep -a 'i/o timeout' | tail -5)"
START_PENDING_COUNT="unknown"
if [ -x "$BD_LIST_CACHED" ]; then
  SP="$(timeout 20 bash "$BD_LIST_CACHED" -C "$CITY" list -l gc:session --json --include-infra --limit 0 2>/dev/null \
    | jq '[.[] | select(.metadata.state=="start-pending" and .metadata.wake_attempts=="0")] | length' 2>/dev/null)"
  case "$SP" in ''|*[!0-9]*) ;; *) START_PENDING_COUNT="$SP" ;; esac
fi

TITLE="Reconciler stalled ${AGE_MIN}min (gc.session reconciler)"
BODY="$(cat <<EOF
Session reconciler trace has not advanced in ${AGE_MIN} min (age_sec=${AGE_SEC}, threshold=${STALL_THRESHOLD_SEC}s).
Supervisor process: alive (launchctl gui/${UID_NUM}/${SUPERVISOR_LABEL} has a pid) -- so this is "stuck", not "dead" (ga-b0gltl covers dead).
Last trace record: ${LAST_TS}
Segment file: ${SEG_FILE}
Sessions start-pending w/ wake_attempts=0: ${START_PENDING_COUNT}
${SWAP_LINE}
Recent supervisor.log i/o timeout lines (last 5 in tail):
${IOTIMEOUT_LINES:-(none found in the checked tail)}

Detection-only guard (ga-srp8hk) -- nothing was restarted or touched.
EOF
)"

# ---- alert: notify first (Dolt-independent -- reaches Athos even if bd/gc
# mail are themselves wedged by the same Dolt i/o-timeout condition), mail
# second with a concrete-name fallback (the alias form "mayor/" does an
# extra live-session-listing bd read before it can send -- observed failing
# 3/3 under real Dolt flakiness, exactly the condition this alert fires
# under -- so the bare alias is used first, and on failure the concrete
# session name is tried once rather than retrying the same failure mode) ----
if command -v "$NOTIFY_BIN" >/dev/null 2>&1; then
  "$NOTIFY_BIN" -t "$TITLE" -p 4 "$BODY" >/dev/null 2>&1 || log "notify call failed (non-fatal)"
else
  log "notify binary not found on PATH ($NOTIFY_BIN) -- skipped"
fi

MAIL_OK=0
if command -v "$GC_BIN" >/dev/null 2>&1; then
  if timeout 45 "$GC_BIN" mail send "$MAYOR_ADDR" -s "$TITLE" -m "$BODY" --notify >/dev/null 2>&1; then
    MAIL_OK=1
  else
    log "gc mail send $MAYOR_ADDR failed, retrying once with concrete session name $MAYOR_ADDR_FALLBACK"
    if timeout 45 "$GC_BIN" mail send "$MAYOR_ADDR_FALLBACK" -s "$TITLE" -m "$BODY" --notify >/dev/null 2>&1; then
      MAIL_OK=1
    else
      log "gc mail send ALSO failed against $MAYOR_ADDR_FALLBACK -- alert delivered via notify only"
    fi
  fi
else
  log "gc binary not found on PATH ($GC_BIN) -- mail skipped, notify-only alert"
fi

echo "$NOW_EP" > "$COOLDOWN_FILE" 2>/dev/null || true
log "ALERTED state=STALLED age_sec=$AGE_SEC age_min=$AGE_MIN mail_ok=$MAIL_OK"
echo "reconciler-stall-detector: STALLED age_sec=$AGE_SEC (alerted, mail_ok=$MAIL_OK)"
exit 0
