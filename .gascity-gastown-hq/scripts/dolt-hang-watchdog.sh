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
# ga-153cq: LOG/STRIKES overridable so a dry run can use scratch state. They were
# hardcoded, which made even a DRY RUN unsafe: the strike counter is incremented
# BEFORE the restart decision, so exercising this script against the live counter
# would push it toward MAX_STRIKES and arm a genuine restart on the next real
# sweep. "You cannot test it without risking the outage it causes" is why 87
# restarts happened with no test ever written.
LOG="${DOLT_WATCHDOG_LOG:-$CITY/.gc/logs/dolt-hang-watchdog.log}"
STRIKES="${DOLT_WATCHDOG_STRIKES_FILE:-/tmp/dolt-hang-watchdog.strikes}"
MAX_STRIKES="${DOLT_WATCHDOG_MAX_STRIKES:-3}"
PROBE_TIMEOUT="${DOLT_WATCHDOG_PROBE_TIMEOUT:-12}"
ENABLED="${DOLT_WATCHDOG_ENABLED:-1}"
DOLT_PORT="${BEADS_DOLT_PORT:-52756}"            # live Dolt server port
# ga-153cq: 12 -> 25. This bound decides "alive but slow" vs "dead", so it has to
# sit ABOVE legitimate worst-case latency or it cannot separate them. Kept well
# under the 60s launchd StartInterval so runs never overlap. Not raised further:
# the 12s bound demonstrably DID serve SELECT 1 through 1,879 saturation events,
# up to 207% CPU — so this is headroom for the degraded regime, not a rewrite of
# a bound that was working.
SERVE_CONFIRM_TIMEOUT="${DOLT_WATCHDOG_SERVE_CONFIRM:-25}"

# ga-153cq: CPU veto on the destructive path (see the long note at the restart
# site). CPU_ALIVE_PCT is deliberately LOW: the claim being tested is only "is
# this process doing work at all", and a true deadlock/worker-stall sits at ~0%.
# 20% is far above idle noise and far below the 50-207% seen in real saturation.
CPU_ALIVE_PCT="${DOLT_WATCHDOG_CPU_ALIVE_PCT:-20}"
CPU_VETO_MAX="${DOLT_WATCHDOG_CPU_VETO_MAX:-5}"
CPU_VETO_FILE="${DOLT_WATCHDOG_CPU_VETO_FILE:-/tmp/dolt-hang-watchdog.cpuveto}"

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
  # ga-153cq: connect_timeout must track SERVE_CONFIRM_TIMEOUT, not sit below it.
  # It used to be a hardcoded 8 under a 12s outer `timeout`, which made the outer
  # bound decorative: the connect gave up at 8s and the extra 4s were never usable.
  # Two bounds on the same wait must not disagree, or raising the visible one
  # changes nothing — the invisible one still decides.
  local _ct=$(( SERVE_CONFIRM_TIMEOUT > 4 ? SERVE_CONFIRM_TIMEOUT - 4 : SERVE_CONFIRM_TIMEOUT ))
  timeout "$SERVE_CONFIRM_TIMEOUT" python3 - "$DOLT_PORT" "$_ct" <<'PY' 2>/dev/null
import sys
try:
    import pymysql
    c = pymysql.connect(host='127.0.0.1', port=int(sys.argv[1]), user='root',
                        connect_timeout=int(sys.argv[2]))
    cur = c.cursor(); cur.execute('SELECT 1'); cur.fetchone()
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
}

# ga-153cq: CPU of the live dolt sql-server, as a whole number ("" if unknown).
# This is the discriminator the comment above ALREADY names as what separates a
# true hang from saturation ("typically ~0% CPU") — but which the code only ever
# read on the branch where it had already decided NOT to restart. Reading it here
# lets the destructive branch use it too.
dolt_cpu_pct() {
  local _pid _cpu
  _pid=$(pgrep -f 'dolt sql-server' 2>/dev/null | head -1)
  [ -z "$_pid" ] && { printf ''; return; }
  _cpu=$(ps -p "$_pid" -o %cpu= 2>/dev/null | tr -d ' ')
  [ -z "$_cpu" ] && { printf ''; return; }
  printf '%s' "${_cpu%%.*}"
}

if probe_ok; then
  if [ -f "$STRIKES" ]; then log "Dolt healthy again — clearing $(cat "$STRIKES" 2>/dev/null) strike(s)."; rm -f "$STRIKES"; fi
  # ga-153cq: the veto counter must reset on recovery too. It counts CONSECUTIVE
  # vetoed confirmations; if it survived a healthy period it would carry stale
  # pressure into an unrelated future episode and exhaust the veto early —
  # turning a safety valve into a countdown to the very restart it prevents.
  rm -f "$CPU_VETO_FILE" 2>/dev/null || true
  exit 0
fi

# Saturation guard: probe failed, but is Dolt actually serving? If a raw SELECT 1
# succeeds, it's busy/slow (saturation), NOT hung — don't strike, don't restart.
if dolt_actually_serving; then
  _cpu=$(ps -p "$(pgrep -f 'dolt sql-server' | head -1)" -o %cpu= 2>/dev/null | tr -d ' ')
  log "Health-probe failed but Dolt SERVES a raw SELECT 1 (cpu=${_cpu:-?}%) — saturation, NOT a hang. Skipping strike/restart."
  [ -f "$STRIKES" ] && rm -f "$STRIKES"
  rm -f "$CPU_VETO_FILE" 2>/dev/null || true   # ga-153cq: proven serving = clean slate
  exit 0
fi

n=$(( $(cat "$STRIKES" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STRIKES"
_strike_cpu="$(dolt_cpu_pct)"
# ga-153cq: record CPU on the STRIKE path too, not only on the saturation path.
# Until now CPU was logged only where we decided NOT to restart, so after 87 real
# restarts there is no way to tell, retroactively, how many killed a server that
# was merely busy. A number you only record when it doesn't matter is not evidence.
log "Dolt probe FAILED + raw query also failed (true unresponsiveness, strike ${n}/${MAX_STRIKES}, cpu=${_strike_cpu:-?}%)."
[ "$n" -lt "$MAX_STRIKES" ] && exit 0

if [ "$ENABLED" != "1" ]; then
  log "CONFIRMED hang (${n} strikes) but DOLT_WATCHDOG_ENABLED=0 — probe-only, NOT restarting."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# ga-153cq — CPU VETO on the destructive step.
#
# Doctrine (CLAUDE.md) says NEVER kill -QUIT the Dolt PID: sent to a live server
# it vanished on the spot and took the city down. That NEVER was written about a
# different call site — an ad-hoc "diagnostic" against a server just confirmed
# HEALTHY, under the false premise that SIGQUIT was non-fatal. Here it is the
# only automated recovery for a true hang, behind 3 confirmed strikes, and the
# author knew it exits Dolt. So the answer is not to delete the recovery path.
#
# But "confirmed" has to mean confirmed. Measured on the live log before this
# change: 1,879 saturation events (health probe failed, raw SELECT 1 still
# served — at up to 207% CPU) vs 319 strikes and 87 actual restarts. The health
# probe failing is ROUTINE; the single thing standing between routine saturation
# and an automatic SIGQUIT of the city's data plane is one bounded SELECT 1.
# When Dolt degrades hard (measured this same night: bd latency 30-74s before
# the ga-9ae7o vendor fix, 150-257ms after), that SELECT 1 can miss its bound
# while the server is alive and working — and the old code then killed it.
#
# So apply the discriminator this file ALREADY documents at dolt_actually_serving
# ("a TRUE hang — deadlock/worker-stall — is typically ~0% CPU"). It was never
# actually consulted here. A process burning real CPU is doing work; killing it
# is the futile-and-disruptive restart the saturation guard exists to prevent.
#
# ⚠️ This VETO is deliberately not permanent: a spin-deadlock can burn CPU, so a
# veto that never yields would trade "kills a healthy server" for "never recovers
# a real hang" — the worse failure, and the one the bead's author warned about.
# After CPU_VETO_MAX consecutive vetoed confirmations we stop vetoing and let the
# restart proceed, escalating loudly first. Visible and counted, never silent.
_cpu_now="$(dolt_cpu_pct)"
_vetoes=$(cat "$CPU_VETO_FILE" 2>/dev/null || echo 0)
if [ -n "$_cpu_now" ] && [ "$_cpu_now" -ge "$CPU_ALIVE_PCT" ] && [ "$_vetoes" -lt "$CPU_VETO_MAX" ]; then
  _vetoes=$(( _vetoes + 1 ))
  echo "$_vetoes" > "$CPU_VETO_FILE"
  log "CONFIRMED-by-strikes but Dolt is burning ${_cpu_now}% CPU (>=${CPU_ALIVE_PCT}%) — WORKING, not hung. Restart VETOED (${_vetoes}/${CPU_VETO_MAX}). Not clearing strikes."
  command -v notify >/dev/null 2>&1 && notify -p 4 -t 'Dolt hang-watchdog' \
    "Hang confirmed by probes but Dolt at ${_cpu_now}% CPU — restart vetoed (${_vetoes}/${CPU_VETO_MAX}). Saturation, not a hang." >/dev/null 2>&1 || true
  exit 0
fi
if [ "$_vetoes" -ge "$CPU_VETO_MAX" ]; then
  log "CPU veto EXHAUSTED (${_vetoes}/${CPU_VETO_MAX}) at cpu=${_cpu_now:-?}% — a spin-deadlock also burns CPU, so proceeding with restart rather than never recovering."
  command -v notify >/dev/null 2>&1 && notify -p 5 -t 'Dolt hang-watchdog' \
    "CPU veto exhausted (${_vetoes}x) — restarting Dolt anyway at ${_cpu_now:-?}% CPU. Investigate: possible spin-deadlock." >/dev/null 2>&1 || true
fi
rm -f "$CPU_VETO_FILE" 2>/dev/null || true

log "CONFIRMED Dolt hang (${n} consecutive strikes, cpu=${_cpu_now:-?}%) — capturing goroutine dump + restarting."
PID="$(pgrep -f 'dolt sql-server' 2>/dev/null | head -1 || true)"

# ga-153cq: DOLT_WATCHDOG_DRY_RUN=1 walks the whole decision path and reports what
# it WOULD do, without signalling or restarting anything. Added because there was
# previously no way to exercise this branch at all: the only way to see it run was
# for it to actually SIGQUIT the city's data plane, so in practice it was never
# tested, only observed after the fact — 87 times. An unrunnable safety path is an
# unverified one. Note this exits BEFORE the restart, so a dry run never clears
# $STRIKES either: the real episode is left exactly as it was found.
if [ "${DOLT_WATCHDOG_DRY_RUN:-0}" = "1" ]; then
  log "DRY-RUN: would kill -QUIT pid=${PID:-<none>} and run 'gc dolt restart' (strikes=${n}, cpu=${_cpu_now:-?}%). Nothing was signalled; strikes left intact."
  exit 0
fi

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
