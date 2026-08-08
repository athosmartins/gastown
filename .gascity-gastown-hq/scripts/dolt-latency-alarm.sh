#!/usr/bin/env bash
# dolt-latency-alarm.sh (ga-7j5vf) — pre-collapse Dolt latency/concurrency alarm.
#
# WHY: dolt-hang-watchdog.sh already catches TRUE Dolt unresponsiveness (death or
# hang) via strikes+restart. It is blind to DEGRADATION — a probe that succeeds in
# 3-8s reads identical to one that succeeds in 150ms, and availability alone is the
# wrong signal for this: peter-wa + mayor measured (2026-08-07, ga-7j5vf) a real
# incident where 17/17 raw SELECT-1 probes were GREEN while `gc mail inbox` timed
# out on the SAME Dolt. Their curve found a knee between 9 and 15 concurrent bd
# processes: healthy (145-346ms) below it, degrading fast (265-3296ms, intermittent
# failures) above it, collapsed (30-74s, failures) further above that. This script
# is the alarm ga-7j5vf's own "O QUE FAZER COM ISTO" section asked for: notify
# (never restart — that's dolt-hang-watchdog.sh's job) when a MEDIAN of recent
# latency and/or connection-count readings crosses that knee, so a human or another
# daemon can act BEFORE the collapse, not 17 minutes after (the June-14 hang
# dolt-hang-watchdog.sh's own header cites).
#
# WHY MEDIAN, NOT SINGLE-SAMPLE: the mayor's own addendum on ga-7j5vf documents
# nearly publishing a false theory from 3 samples that happened to land in a valley
# ("quem amostra uma vez ve recuperacao que nao existe") — the signal genuinely
# oscillates. A median over the last LATENCY_ALARM_WINDOW ticks (default 5 = 5min
# at this script's 60s cadence) won't trip on one blip (needs a majority of the
# window elevated) but still catches a sustained excursion well inside the
# collapse's own multi-minute timescale. COLD-START CORNER CASE: a median of a
# 1-reading window is just that reading — no protection at all — so evaluation
# is additionally gated on LATENCY_ALARM_MIN_SAMPLES (default 3): right after
# the daemon (re)starts or a state file is cleared, the first couple of ticks
# only log, never alarm. Same failure class as ga-ouqtg/ga-br5sw in
# mol-dog-doctor.sh (threshold compared against a lone noisy sample), just at
# the window's edge instead of every tick — closed the same way: don't compare
# against a single sample, ever, not even implicitly via NR=1.
#
# WHY A NEW SCRIPT, NOT A dolt-hang-watchdog.sh EXTENSION: considered piggybacking
# on that script's existing 60s probe (zero extra Dolt query) but its strike
# counter is tuned for one binary outcome (confirmed-hang -> restart); bolting a
# second, independent degradation-only alarm with its own window/threshold onto
# the same file conflates two different failure classes in one mental model.
# Trade-off accepted: one more trivial `gc dolt health` call per minute (bounded,
# same call dolt-hang-watchdog.sh already makes) — negligible next to the
# 9-15-concurrent-HELD-connection knee this alarm exists to catch.
#
# THRESHOLDS ARE NOT PERMANENT: 500ms / 12 connections are ga-7j5vf's own proposed
# knee for THIS machine, in THIS Dolt state (14G data), with gc running degraded
# under ga-9ae7o's still-open native_store_unavailable (extra bd-process-per-gc-call
# base load). Re-measure and recalibrate DOLT_LATENCY_ALARM_MS / DOLT_CONN_ALARM_COUNT
# once ga-9ae7o lands — don't treat these as gospel.
#
# Kill switch: DOLT_LATENCY_ALARM_ENABLED=0 -> probe + log only, never notify.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG="$CITY/.gc/logs/dolt-latency-alarm.log"
DOLT_PORT_DEFAULT="${BEADS_DOLT_PORT:-52756}"

LATENCY_ALARM_MS="${DOLT_LATENCY_ALARM_MS:-500}"
CONN_ALARM_COUNT="${DOLT_CONN_ALARM_COUNT:-12}"
LATENCY_ALARM_WINDOW="${DOLT_LATENCY_ALARM_WINDOW:-5}"
# ga-7j5vf review: a bare median_of() on a fresh window is a NOOP protection at
# NR=1 (median of one reading is that reading) — the exact single-sample noise
# trap this whole design exists to avoid (mayor's own remeasurement saw
# 784-1013ms on 1 idle bd process). Only evaluate once the window has at least
# this many ticks; below that, log the raw reading but never alarm on it. Only
# matters right after the daemon (re)starts or a state file is cleared — it
# self-heals within MIN_SAMPLES ticks either way.
LATENCY_ALARM_MIN_SAMPLES="${DOLT_LATENCY_ALARM_MIN_SAMPLES:-3}"
LATENCY_ALARM_ENABLED="${DOLT_LATENCY_ALARM_ENABLED:-1}"
SERVE_CONFIRM_TIMEOUT="${DOLT_LATENCY_ALARM_SERVE_CONFIRM:-12}"

# Hardcoded default, NOT ${TMPDIR:-/tmp}: verified live (ga-7j5vf smoke test) that
# this session's $TMPDIR (/var/folders/.../T/) differs from a launchd LaunchAgent's
# — an ambient-env-dependent path would silently split the window state across
# whichever context happens to invoke this tick, breaking the median's persistence
# without any error. dolt-hang-watchdog.sh's own STRIKES file hardcodes /tmp for
# the same reason; matching that convention here. Still overridable via the
# script's OWN dedicated var (not ambient $TMPDIR) so a selftest can point state
# at an isolated scratch dir instead of colliding with a real deployed instance.
STATE_DIR="${DOLT_LATENCY_ALARM_STATE_DIR:-/tmp}"
LATENCY_WINDOW_FILE="$STATE_DIR/dolt-latency-alarm.latency-window"
CONN_WINDOW_FILE="$STATE_DIR/dolt-latency-alarm.conn-window"
ALARM_ACTIVE_FILE="$STATE_DIR/dolt-latency-alarm.active"
LOCK_DIR="$STATE_DIR/dolt-latency-alarm.lock.d"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# ── single-instance lock (mkdir is atomic; reclaim only a DEAD holder's lock —
# doctrine: liveness, not age, gates reclaim, so a slow-but-alive run is never
# preempted). Bounded work below (12s probe timeout + a couple lsof calls) stays
# well under the 60s StartInterval, so this is defense-in-depth, not the primary
# guard against stacking. Defined here (pure) but only INVOKED down in the
# SOURCE_ONLY-guarded execution block at the bottom, alongside everything else
# that touches real state/locks/Dolt/notify. ──
_lock_holder_dead() {
  local holder_pid
  holder_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null) || return 1
  [ -n "$holder_pid" ] || return 1
  kill -0 "$holder_pid" 2>/dev/null && return 1   # still alive -> not reclaimable
  return 0                                         # dead -> reclaimable
}

# optional shared Dolt-health probe (reuse gc-dolt-probe.sh for the primary
# latency+reachability reading; fail open if missing — this script's own
# fallback probe below still works standalone)
_PROBE="$CITY/scripts/gc-dolt-probe.sh"
# shellcheck disable=SC1090
[ -f "$_PROBE" ] && . "$_PROBE" 2>/dev/null || true

# ── live Dolt port (never trust a config default alone — a stale port would make
# conn_count silently read 0, i.e. "empty" masquerading as "healthy", exactly the
# failure class this bead's own doctrine warns about). Falls back to the
# configured default only if no live `dolt sql-server` process is found. ──
live_dolt_port() {
  local pid port
  pid=$(pgrep -f 'dolt sql-server' 2>/dev/null | head -1)
  if [ -n "$pid" ]; then
    port=$(lsof -nP -p "$pid" 2>/dev/null | grep LISTEN | grep -oE ':[0-9]+ \(LISTEN\)' | head -1 | grep -oE '[0-9]+')
  fi
  [ -n "$port" ] && echo "$port" || echo "$DOLT_PORT_DEFAULT"
}

# ── connection count: TCP ESTABLISHED on the live Dolt port via lsof. Zero Dolt
# query cost (same technique dolt-load-attributor.py already uses for its own
# connection-attribution sampling) — this signal works even when Dolt itself is
# too wedged to answer a query. ──
conn_count() {
  local port; port=$(live_dolt_port)
  lsof -nP -iTCP:"$port" -sTCP:ESTABLISHED 2>/dev/null | tail -n +2 | wc -l | tr -d ' '
}

# ── fallback timed probe: only used when gc_dolt_probe_json (or its absence)
# didn't yield a latency number — same raw-SELECT-1 discriminator dolt-hang-watchdog.sh
# and gc-dolt-probe.sh's _gc_dolt_serve_confirm both use, but this one self-times
# so a "succeeded, just slow" probe still feeds the median instead of being
# silently discarded (the exact gap ga-7j5vf is about: a probe that succeeds in
# 8s today reads as "healthy" to every existing check in this codebase). Prints
# elapsed ms to stdout on success; prints nothing and returns 1 on failure. ──
timed_serve_confirm() {
  local port; port=$(live_dolt_port)
  timeout "$SERVE_CONFIRM_TIMEOUT" python3 - "$port" <<'PY' 2>/dev/null
import sys, time
t0 = time.time()
try:
    import pymysql
    c = pymysql.connect(host='127.0.0.1', port=int(sys.argv[1]), user='root', connect_timeout=8)
    cur = c.cursor(); cur.execute('SELECT 1'); cur.fetchone()
    c.close()
    print(int((time.time() - t0) * 1000))
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
}

# ── median of N most-recent numeric readings in a file (one per line). Empty
# string (not 0, not skip) when the file has no readings yet — the third state,
# not collapsed into either "healthy" or "alarm". ──
median_of() {
  [ -s "$1" ] || { echo ""; return; }
  sort -n "$1" | awk '{a[NR]=$1} END{if(NR%2==1) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}'
}

# ── sample count in a window file — 0 for a missing/empty file. ──
sample_count() {
  [ -s "$1" ] || { echo 0; return; }
  wc -l < "$1" | tr -d ' '
}

record_reading() {
  echo "$2" >> "$1"
  tail -n "$LATENCY_ALARM_WINDOW" "$1" > "${1}.tmp" 2>/dev/null && mv "${1}.tmp" "$1"
}

gt_threshold() {  # exit 0 if $1 > $2 (awk handles the decimal medians an even-count window produces)
  awk -v m="$1" -v t="$2" 'BEGIN{exit !(m>t)}'
}

# ── get ONE latency reading for this tick, from whichever probe actually
# answers. Prefers gc_dolt_probe_json (already-built three-state parse); falls
# back to the self-timed raw SELECT 1 above ONLY when that didn't yield a
# healthy latency_ms — covers exactly the case existing infra drops today
# (health-wrapper times out, but Dolt still serves a raw query, just slowly). ──
get_latency_ms() {
  local lat=""
  if declare -f gc_dolt_probe_json >/dev/null 2>&1; then
    local j; j=$(gc_dolt_probe_json 2>/dev/null)
    lat=$(printf '%s' "$j" | jq -r 'if .reachable == true then .latency_ms else empty end' 2>/dev/null)
  fi
  if [ -z "$lat" ]; then
    lat=$(timed_serve_confirm)
  fi
  printf '%s' "$lat"
}

# ════════════════════════════════════════════════════════════════════════════
# Everything below actually TOUCHES the world (lock, live Dolt probes, state
# files, notify) — guarded so a selftest can
# `DOLT_LATENCY_ALARM_SOURCE_ONLY=1 source` this file to reach the pure
# functions above (median_of, sample_count, gt_threshold, live_dolt_port,
# get_latency_ms, ...) without acquiring the lock, probing live Dolt, or
# sending a real notification. Mirrors the DOLT_WATCHDOG_SOURCE_ONLY convention
# dolt-hang-watchdog.sh's own harness already uses for the same reason. Falling
# through this whole block (source case) must NOT reach `exit` — exit in a
# sourced file would kill the CALLER's shell, not just this file — so the lone
# `exit 0` at the very end lives inside the guard too.
if [ "${DOLT_LATENCY_ALARM_SOURCE_ONLY:-0}" != "1" ]; then

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if _lock_holder_dead; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    mkdir "$LOCK_DIR" 2>/dev/null || { log "Lock busy after reclaim attempt — skipping this tick."; exit 0; }
  else
    log "Lock held by live PID $(cat "$LOCK_DIR/pid" 2>/dev/null) — another run in flight, skipping this tick."
    exit 0
  fi
fi
echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT

_lat="$(get_latency_ms)"
_conns="$(conn_count)"

[ -n "$_lat" ] && record_reading "$LATENCY_WINDOW_FILE" "$_lat"
record_reading "$CONN_WINDOW_FILE" "$_conns"

_med_lat="$(median_of "$LATENCY_WINDOW_FILE")"
_med_conn="$(median_of "$CONN_WINDOW_FILE")"
_n_lat="$(sample_count "$LATENCY_WINDOW_FILE")"
_n_conn="$(sample_count "$CONN_WINDOW_FILE")"

_degraded=0
_reason=""
if [ -n "$_med_lat" ] && [ "$_n_lat" -ge "$LATENCY_ALARM_MIN_SAMPLES" ] \
    && gt_threshold "$_med_lat" "$LATENCY_ALARM_MS"; then
  _degraded=1
  _reason="median latency ${_med_lat}ms > ${LATENCY_ALARM_MS}ms (n=${_n_lat})"
fi
if [ -n "$_med_conn" ] && [ "$_n_conn" -ge "$LATENCY_ALARM_MIN_SAMPLES" ] \
    && gt_threshold "$_med_conn" "$CONN_ALARM_COUNT"; then
  _degraded=1
  _reason="${_reason:+$_reason; }median conns ${_med_conn} > ${CONN_ALARM_COUNT} (n=${_n_conn})"
fi

if [ "$_degraded" = "1" ]; then
  if [ ! -f "$ALARM_ACTIVE_FILE" ]; then
    log "ALARM (pre-collapse, ga-7j5vf knee=9-15 bd-concurrent): ${_reason} — this tick lat=${_lat:-?}ms conns=${_conns}"
    if [ "$LATENCY_ALARM_ENABLED" = "1" ]; then
      command -v notify >/dev/null 2>&1 && \
        notify -p 3 -t 'Dolt degradando' "${_reason} (agora: lat=${_lat:-?}ms conns=${_conns}) — pre-colapso, so aviso, dolt-hang-watchdog cuida de hang confirmado" >/dev/null 2>&1 || true
    fi
    touch "$ALARM_ACTIVE_FILE" 2>/dev/null || true
  fi
else
  if [ -f "$ALARM_ACTIVE_FILE" ]; then
    log "Alarm CLEARED — median lat=${_med_lat:-?}ms conns=${_med_conn:-?}"
    if [ "$LATENCY_ALARM_ENABLED" = "1" ]; then
      command -v notify >/dev/null 2>&1 && \
        notify -p 2 -t 'Dolt normalizou' "latencia/conexoes voltaram abaixo do limiar (lat=${_med_lat:-?}ms conns=${_med_conn:-?})" >/dev/null 2>&1 || true
    fi
    rm -f "$ALARM_ACTIVE_FILE" 2>/dev/null || true
  fi
fi

exit 0

fi  # DOLT_LATENCY_ALARM_SOURCE_ONLY guard
