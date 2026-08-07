#!/usr/bin/env bash
# dolt-hang-watchdog.sh (ga-pjrjo) — detect a HUNG Dolt server and restart it.
#
# WHY: the process keeper only catches Dolt *death*. A HANG (process alive + port
# listening, but workers stuck mid-query → accept-loop stalls → back_log fills →
# "max waiting connections reached, client rejected" → every query dropped) is
# invisible to a death-based keeper. On 2026-06-14 such a hang took down the whole
# data plane (painel/gc/bd/gate) and sat ~17 min until a human noticed.
# (See memory: dolt-hang-worker-stall-backlog-exhaustion-incident.)
#
# WHAT: probe real serve-ability via `gc dolt health` (bounded by timeout). A hung
# server makes that hang (→ timeout) or report unreachable. Restart ONLY after
# MAX_STRIKES consecutive failing probes (avoids false-positive restart storms on a
# transient blip), capturing a goroutine dump first for diagnosis.
#
# Kill switch: DOLT_WATCHDOG_ENABLED=0 → probe + log only, never restart.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG="$CITY/.gc/logs/dolt-hang-watchdog.log"
STRIKES="/tmp/dolt-hang-watchdog.strikes"
MAX_STRIKES="${DOLT_WATCHDOG_MAX_STRIKES:-3}"
PROBE_TIMEOUT="${DOLT_WATCHDOG_PROBE_TIMEOUT:-12}"
ENABLED="${DOLT_WATCHDOG_ENABLED:-1}"
DOLT_PORT="${BEADS_DOLT_PORT:-52756}"            # live Dolt server port
SERVE_CONFIRM_TIMEOUT="${DOLT_WATCHDOG_SERVE_CONFIRM:-12}"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null; }

# Healthy iff `gc dolt health --json` returns within PROBE_TIMEOUT, parses, and
# reports .server.reachable == true. timeout rc!=0 (hang) or reachable!=true → fail.
probe_ok() {
  local out rc
  out=$(cd "$CITY" && GC_CITY="$CITY" timeout "$PROBE_TIMEOUT" gc dolt health --json 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] && return 1
  printf '%s' "$out" | jq -e '.server.reachable == true' >/dev/null 2>&1 || return 1
  return 0
}

# A failed health-probe under heavy CPU load is usually SATURATION (Dolt busy/slow),
# NOT a hang — and restarting a busy-but-serving Dolt is disruptive + futile (the
# load returns immediately). Confirm with a direct raw `SELECT 1`: if Dolt actually
# serves it, the server is ALIVE (the health probe just timed out under load) → not
# a hang, don't strike/restart. A TRUE hang (deadlock / worker-stall, typically ~0%
# CPU) fails this too → we proceed to restart. (Mayor 2026-06-15: stop false-restarts
# on Dolt-CPU spikes — the ga-8smq3 saturation that recurs all day.)
dolt_actually_serving() {
  timeout "$SERVE_CONFIRM_TIMEOUT" python3 - "$DOLT_PORT" <<'PY' 2>/dev/null
import sys
try:
    import pymysql
    c = pymysql.connect(host='127.0.0.1', port=int(sys.argv[1]), user='root', connect_timeout=8)
    cur = c.cursor(); cur.execute('SELECT 1'); cur.fetchone()
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
}

if probe_ok; then
  if [ -f "$STRIKES" ]; then log "Dolt healthy again — clearing $(cat "$STRIKES" 2>/dev/null) strike(s)."; rm -f "$STRIKES"; fi
  exit 0
fi

# Saturation guard: probe failed, but is Dolt actually serving? If a raw SELECT 1
# succeeds, it's busy/slow (saturation), NOT hung — don't strike, don't restart.
if dolt_actually_serving; then
  _cpu=$(ps -p "$(pgrep -f 'dolt sql-server' | head -1)" -o %cpu= 2>/dev/null | tr -d ' ')
  log "Health-probe failed but Dolt SERVES a raw SELECT 1 (cpu=${_cpu:-?}%) — saturation, NOT a hang. Skipping strike/restart."
  [ -f "$STRIKES" ] && rm -f "$STRIKES"
  exit 0
fi

n=$(( $(cat "$STRIKES" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STRIKES"
log "Dolt probe FAILED + raw query also failed (true unresponsiveness, strike ${n}/${MAX_STRIKES})."
[ "$n" -lt "$MAX_STRIKES" ] && exit 0

if [ "$ENABLED" != "1" ]; then
  log "CONFIRMED hang (${n} strikes) but DOLT_WATCHDOG_ENABLED=0 — probe-only, NOT restarting."
  exit 0
fi

log "CONFIRMED Dolt hang (${n} consecutive strikes) — capturing goroutine dump + restarting."
PID="$(pgrep -f 'dolt sql-server' 2>/dev/null | head -1 || true)"
if [ -n "$PID" ]; then
  kill -QUIT "$PID" 2>/dev/null || true   # dumps goroutines to dolt.log (also exits Dolt; restart below recovers)
  sleep 3
fi
( cd "$CITY" && GC_CITY="$CITY" gc dolt restart >> "$LOG" 2>&1 ) || log "WARN: gc dolt restart returned nonzero"
sleep 5
if probe_ok; then
  log "Restart OK — Dolt serving again."
  command -v notify >/dev/null 2>&1 && notify -p 4 -t 'Dolt hang-watchdog' "Restarted HUNG Dolt after ${n} strikes — now healthy" >/dev/null 2>&1 || true
else
  log "WARN: Dolt STILL unhealthy after restart — escalating."
  command -v notify >/dev/null 2>&1 && notify -p 5 -t 'Dolt hang-watchdog' "Restart attempted but Dolt STILL unhealthy after ${n} strikes — NEEDS HUMAN" >/dev/null 2>&1 || true
fi
rm -f "$STRIKES"
exit 0
