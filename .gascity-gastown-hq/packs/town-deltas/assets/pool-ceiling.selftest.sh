#!/usr/bin/env bash
# pool-ceiling.selftest.sh (ga-uywvsc)
#
# Proves the DYNAMIC per-pool session ceiling (Athos, 2026-10-01: "esse teto ser
# hardcoded em 2? ... calculado dinamicamente com base nos parametros que dizem se
# o sistema esta precisando / podendo ter mais ou menos workers? idem pra gate
# reviewers"). The ceiling of each elastic pool is recomputed on every dispatcher
# sweep from DEMAND (ready queue) and machine SLACK (load, memory pressure, swap,
# disk, Dolt, quota), between a per-pool min and max:
#   up 1 per step while there is a queue AND slack AND the pool is saturated;
#   down 1 per step when a hard resource signal squeezes (never kills a session —
#   it only stops OPENING new ones) or when nothing is queued (so the next burst
#   ramps from low again, one session per sweep, never all at once);
#   an unreadable signal NEVER raises (third state: not-found != found-and-zero);
#   POOL_CEILING_DYNAMIC=0 or the kill file restores the fixed ceiling.
#
# Run against the pre-patch tree to confirm RED (lib absent, wiring absent) or the
# patched tree (GREEN). Override: POOL_CEILING_LIB / PILOT_DISPATCHER_PATH /
# GATE_DISPATCHER_PATH.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${POOL_CEILING_LIB:-$SELF_DIR/pool-ceiling.sh}"
PILOT="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
GATE="${GATE_DISPATCHER_PATH:-$SELF_DIR/quality-gate-dispatcher.sh}"

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$1" = "$2" ]; then ok "$3 (got: $1)"; else bad "$3 (expected: $2, got: $1)"; fi; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing '$2' in: $1)" ;; esac; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
# Never let a LIVE .gc/pool-ceiling.on/.off of the real city leak into this hermetic test.
export POOL_CEILING_ON_FILE="$TMPROOT/on.flag" POOL_CEILING_KILL_FILE="$TMPROOT/kill.off" POOL_CEILING_SHADOW_FILE="$TMPROOT/shadow.flag"
unset POOL_CEILING_SHADOW
# ...and never let it WRITE the real city's calibration log either: when POOL_CEILING_LOG is unset the lib falls back to
# $GC_CITY/.gc/logs/pool-ceiling.log, and every agent/gate session has GC_CITY exported. Section 2c used to call
# pool_ceiling_step before section 4 exported a log of its own: 57 runs left 114 fake rows (ts=100/200) in the real 24h series.
export POOL_CEILING_LOG="$TMPROOT/pool-ceiling.default.log"
# The production paths the lib would fall back to, snapshotted now and compared at the very end (section 11): a section that
# forgets to isolate itself is a RED test, not silent pollution of the series the doc tells the operator to calibrate from.
PROD_LOG="${GC_CITY:+$GC_CITY/.gc/logs/pool-ceiling.log}"; PROD_STATE="${GC_CITY:+$GC_CITY/.gc/pool-ceiling}"
prod_snapshot() { # → "log=<bytes|absent> state=<entries|absent>", or "no-GC_CITY" when there is no fallback to pollute
  [ -n "$PROD_LOG" ] || { printf 'no-GC_CITY'; return 0; }
  printf 'log=%s state=%s' "$([ -e "$PROD_LOG" ] && wc -c < "$PROD_LOG" | tr -d ' ' || echo absent)" "$([ -e "$PROD_STATE" ] && ls -A "$PROD_STATE" 2>/dev/null | wc -l | tr -d ' ' || echo absent)"
}
PROD_BEFORE="$(prod_snapshot)"
# Engine caps (agents/<pool>/agent.toml): the controller obeys THESE on its own (ga-o3o09z, 25/09:
# agent.toml=4 vs Pilot plist=2 -> 4 workers active), so the dynamic ceiling may never exceed them.
AG="$TMPROOT/agents"; mkdir -p "$AG/wa-worker" "$AG/ps-worker" "$AG/gate-reviewer"
printf 'work_dir = "/x"\nmax_active_sessions = 4\n' > "$AG/wa-worker/agent.toml"
printf 'max_active_sessions = 2   # comment\n'      > "$AG/ps-worker/agent.toml"
printf '# max_active_sessions = 9\nmax_active_sessions = 6\n' > "$AG/gate-reviewer/agent.toml"
export POOL_CEILING_AGENTS_DIR="$AG"

echo "== 0. library present and sourceable without side effects"
if [ ! -r "$LIB" ]; then
  bad "pool-ceiling.sh not found at $LIB (RED: the dynamic ceiling does not exist yet)"
  echo; echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi
# shellcheck disable=SC1090
. "$LIB"
for fn in pool_ceiling_decide pool_ceiling_step pool_ceiling_class_load pool_ceiling_class_mem \
          pool_ceiling_class_swap pool_ceiling_class_disk pool_ceiling_class_dolt \
          pool_ceiling_class_quota pool_ceiling_queue_from_dispatchable pool_ceiling_dolt_class pool_ceiling_bounds pool_ceiling_engine_cap pool_ceiling_shadow; do
  if declare -F "$fn" >/dev/null; then ok "defines $fn"; else bad "missing function $fn"; fi
done

echo "== 1. pure decision: pool_ceiling_decide <cur> <min> <max> <live> <queue> name=class..."
d() { pool_ceiling_decide "$@"; }
eq "$(d 2 1 4 2 63 load=grow mem=grow swap=grow disk=grow dolt=grow quota=grow)" "3|up|queue+slack" \
   "queue + slack + saturated -> up 1 (the bead's headline case: wa-worker 2, queue 63)"
eq "$(d 3 1 4 3 63 load=grow mem=grow swap=squeeze disk=grow dolt=grow quota=grow)" "2|down|squeeze:swap" \
   "swap squeezed -> down 1 even with a queue (slack gone)"
eq "$(d 3 1 4 3 63 load=squeeze mem=squeeze disk=grow)" "2|down|squeeze:load,mem" \
   "two squeezes -> still ONE step down, both named in the reason"
eq "$(d 1 1 4 1 63 load=squeeze)" "1|hold|squeeze:load(at-min)" \
   "squeeze at the minimum -> never below min"
eq "$(d 2 1 4 2 63 load=grow mem=unknown swap=grow disk=grow)" "2|hold|unreadable:mem" \
   "unreadable signal with a queue -> does NOT raise (third state, never 'slack infinite')"
eq "$(d 2 1 4 2 63 load=grow mem=grow swap=grow disk=hold)" "2|hold|soft:disk" \
   "soft signal (hold zone) blocks the raise but does not shrink"
eq "$(d 2 1 4 1 63 load=grow mem=grow swap=grow disk=grow)" "2|hold|not-saturated" \
   "pool not yet at its ceiling (live 1 < 2) -> no raise: free slots already exist"
eq "$(d 4 1 4 4 63 load=grow mem=grow swap=grow disk=grow)" "4|hold|at-max" \
   "at max -> stays at max"
eq "$(d 3 1 4 1 0 load=grow mem=grow swap=grow disk=grow)" "3|hold|idle" \
   "empty queue -> HOLD (no decay: the Pilot sweeps ~every 20 min, so a decayed ceiling costs a sweep to regain and buys no burst protection inside the engine cap)"
eq "$(d 1 1 4 0 0 load=grow)" "1|hold|idle" \
   "empty queue at min -> stays at min"
eq "$(d 3 1 4 1 0 load=unknown mem=unknown)" "3|hold|idle" \
   "empty queue + unreadable signals -> hold"
eq "$(d 3 1 4 1 0 load=squeeze)" "2|down|squeeze:load" \
   "empty queue does NOT mask a squeeze: the brake still brakes"
eq "$(d 3 1 4 3 '' load=grow mem=grow)" "3|hold|unreadable:queue" \
   "queue unreadable is NOT queue=0: it is its own reason (unreadable:queue), never reported as idle"
eq "$(d 3 1 4 '' 63 load=grow mem=grow)" "3|hold|unreadable:live" \
   "live count unreadable -> no raise"
eq "$(d 9 1 4 4 63 load=grow)" "4|hold|at-max" \
   "stored ceiling above a lowered max is clamped to max"
eq "$(d 0 2 4 2 63 load=grow mem=grow swap=grow disk=grow)" "3|up|queue+slack" \
   "stored ceiling below a raised min is clamped to min, then steps"
eq "$(d x 1 4 0 63 load=grow)" "1|hold|not-saturated" \
   "garbage current -> treated as min (inert), never an arithmetic crash"
eq "$(d 2 5 3 3 63 load=grow)" "3|hold|at-max" \
   "min > max (bad config) -> collapses to max, never a negative window"

echo "== 2. signal classifiers (thresholds are the documented defaults)"
c() { local fn="$1"; shift; "$fn" "$@"; }
eq "$(c pool_ceiling_class_load 30 10)"   "grow"    "load5 30 on 10 cores (3.0/core) -> grow"
eq "$(c pool_ceiling_class_load 69.3 10)" "hold"    "load5 69.3 on 10 cores (6.9/core, measured 01/10) -> hold"
eq "$(c pool_ceiling_class_load 79.9 10)" "hold"    "just under the squeeze line -> hold"
eq "$(c pool_ceiling_class_load 80 10)"   "squeeze" "8.0/core -> squeeze"
eq "$(c pool_ceiling_class_load '' 10)"   "unknown" "unreadable load -> unknown"
eq "$(c pool_ceiling_class_load 30 0)"    "unknown" "zero cores -> unknown, no division by zero"
eq "$(c pool_ceiling_class_mem 1)" "grow"    "kernel pressure 1 (normal) -> grow"
eq "$(c pool_ceiling_class_mem 2)" "hold"    "kernel pressure 2 (warn) -> hold (it was the state of the 25/09 incident, not a stop)"
eq "$(c pool_ceiling_class_mem 4)" "squeeze" "kernel pressure 4 (critical) -> squeeze"
eq "$(c pool_ceiling_class_mem '')" "unknown" "unreadable pressure -> unknown"
eq "$(c pool_ceiling_class_swap 5000 400 20000)" "grow"    "swap barely used -> grow"
eq "$(c pool_ceiling_class_swap 1300 4800 20000)" "hold"   "swap used above the grow limit -> hold"
eq "$(c pool_ceiling_class_swap 300 5800 20000)" "hold"    "swap low but disk can grow it -> hold, NOT squeeze (ga-q4fkxa: macOS creates swapfiles on demand)"
eq "$(c pool_ceiling_class_swap 300 5800 3000)"  "squeeze" "swap low AND disk cannot grow it -> squeeze"
eq "$(c pool_ceiling_class_swap 300 5800 '')"    "unknown" "swap low and disk unreadable -> unknown (cannot tell if it can grow)"
eq "$(c pool_ceiling_class_swap '' 400 20000)"   "unknown" "swap unreadable -> unknown"
eq "$(c pool_ceiling_class_disk 14336)" "grow"    "14 GB free -> grow"
eq "$(c pool_ceiling_class_disk 7885)"  "hold"    "7.7 GB free (measured 01/10; below the guard's WARN 8) -> hold"
eq "$(c pool_ceiling_class_disk 3072)"  "hold"    "exactly the guard's CRITICAL (3 GB) -> hold, not yet squeeze"
eq "$(c pool_ceiling_class_disk 3071)"  "squeeze" "one MB below the guard's CRITICAL (3 GB) -> squeeze"
eq "$(c pool_ceiling_class_disk '')"    "unknown" "unreadable disk -> unknown"
eq "$(c pool_ceiling_class_dolt ok)"      "grow"    "dolt ok -> grow"
eq "$(c pool_ceiling_class_dolt hot)"     "hold"    "dolt hot -> hold (both dispatchers already have their own Dolt brake)"
eq "$(c pool_ceiling_class_dolt unknown)" "unknown" "dolt unreadable -> unknown"
eq "$(c pool_ceiling_class_quota ok)"      "grow" "quota ok -> grow"
eq "$(c pool_ceiling_class_quota limited)" "hold" "quota limited -> hold (window resets; shrinking would slow the recovery)"
eq "$(c pool_ceiling_class_quota unknown)" "unknown" "quota unreadable -> unknown"
v="$(POOL_CEILING_LOAD_GROW_PER_CORE=2 POOL_CEILING_LOAD_SQUEEZE_PER_CORE=3 pool_ceiling_class_load 25 10)"
eq "$v" "hold" "thresholds are env-overridable (2.5/core is hold under grow<=2 squeeze>=3)"

echo "== 2b. dolt class from a dispatcher's own readings; per-pool bounds"
eq "$(pool_ceiling_dolt_class 95 300 180 2500)"  "ok"      "calm Dolt (cpu 95, 300ms) -> ok"
eq "$(pool_ceiling_dolt_class 200 '' 180 2500)"  "hot"     "cpu over the hot line -> hot"
eq "$(pool_ceiling_dolt_class '' 3000 180 2500)" "hot"     "latency over the hot line -> hot"
eq "$(pool_ceiling_dolt_class '' '' 180 2500)"   "unknown" "no reading at all -> unknown, NOT ok"
eq "$(pool_ceiling_dolt_class abc 100 180 2500)" "ok"      "garbage cpu is dropped, the readable latency still counts"
pool_ceiling_bounds wa-worker;     eq "$POOL_CEILING_MIN..$POOL_CEILING_MAX" "1..4" "wa-worker bounds (max 4 = Athos' 19/09 'WA 4')"
pool_ceiling_bounds ps-worker;     eq "$POOL_CEILING_MIN..$POOL_CEILING_MAX" "1..2" "ps-worker bounds"
pool_ceiling_bounds gate-reviewer; eq "$POOL_CEILING_MIN..$POOL_CEILING_MAX" "2..6" "gate-reviewer bounds"
pool_ceiling_bounds gate-reviewer 3; eq "$POOL_CEILING_MIN..$POOL_CEILING_MAX" "3..6" "gate floor raises the min (one run of 3 must fit)"
pool_ceiling_bounds gate-reviewer 8; eq "$POOL_CEILING_MIN..$POOL_CEILING_MAX" "8..8" "gate floor above max drags the max up, never a negative window"
pool_ceiling_bounds outro;         eq "$POOL_CEILING_MIN..$POOL_CEILING_MAX" "1..1" "an unknown pool is pinned (min=max=1): no dynamic movement by accident"
POOL_CEILING_WA_WORKER_MAX=3 pool_ceiling_bounds wa-worker; eq "$POOL_CEILING_MIN..$POOL_CEILING_MAX" "1..3" "bounds are env-overridable per pool"
POOL_CEILING_WA_WORKER_MAX=abc pool_ceiling_bounds wa-worker; eq "$POOL_CEILING_MIN..$POOL_CEILING_MAX" "1..4" "a garbage override falls back to the default"

echo "== 2c. the engine cap is a hard upper bound (the controller obeys agent.toml, not the dispatcher)"
eq "$(pool_ceiling_engine_cap wa-worker)"      "4" "reads max_active_sessions from agents/<pool>/agent.toml"
eq "$(pool_ceiling_engine_cap ps-worker)"      "2" "a trailing comment is ignored"
eq "$(pool_ceiling_engine_cap gate-reviewer)"  "6" "a commented-out line is ignored; the live one counts"
eq "$(pool_ceiling_engine_cap nao-existe)"     ""  "missing agent.toml -> unreadable (empty), not 0"
printf 'max_active_sessions = banana\n' > "$AG/ps-worker/agent.toml.bad"; mkdir -p "$AG/bad"; cp "$AG/ps-worker/agent.toml.bad" "$AG/bad/agent.toml"
eq "$(pool_ceiling_engine_cap bad)"            ""  "garbage value -> unreadable"
SDE="$TMPROOT/state-eng"; mkdir -p "$SDE"
# deterministic slack for this block (the live box is at load5 ~88/10c right now and would squeeze)
export POOL_CEILING_T_LOAD5=31 POOL_CEILING_T_NCPU=10 POOL_CEILING_T_MEM=1 POOL_CEILING_T_SWAP_FREE_MB=5700 POOL_CEILING_T_SWAP_USED_MB=412 POOL_CEILING_T_DISK_FREE_MB=14336
printf 'max_active_sessions = 2\n' > "$AG/wa-worker/agent.toml"
POOL_CEILING_DYNAMIC=1 POOL_CEILING_STATE_DIR="$SDE" POOL_CEILING_NOW=100 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok
eq "$POOL_CEILING_RESULT" "2" "engine cap 2: with queue + slack the ceiling does NOT climb to the dispatcher max 4 (it would exceed what the controller allows)"
has "$POOL_CEILING_LOGLINE" "at-max" "and the reason is at-max"
has "$POOL_CEILING_LOGLINE" "motor 2" "the log line shows the engine cap it was bounded by"
rm -f "$AG/wa-worker/agent.toml"
POOL_CEILING_DYNAMIC=1 POOL_CEILING_STATE_DIR="$SDE" POOL_CEILING_NOW=200 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok
eq "$POOL_CEILING_RESULT" "2" "engine cap UNREADABLE: never above the known-good fixed value (not-found != no limit)"
has "$POOL_CEILING_LOGLINE" "motor ?" "and the log line says the engine cap could not be read"
printf 'work_dir = "/x"\nmax_active_sessions = 4\n' > "$AG/wa-worker/agent.toml"
printf 'max_active_sessions = 2   # comment\n' > "$AG/ps-worker/agent.toml"

echo "== 3. queue from the Pilot's dispatchable emit (per rig store, stale/corrupt -> unreadable)"
DF="$TMPROOT/dispatchable.json"
NOW=1790892193
GEN="$(date -u -r "$NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)"
printf '{"generated_at":"%s","ttl_seconds":1800,"count":5,"items":[{"id":"a","store":"whatsapp_automation"},{"id":"b","store":"whatsapp_automation"},{"id":"c","store":"whatsapp_automation"},{"id":"d","store":"property_scrapers"},{"id":"e","store":"hq"}]}' "$GEN" > "$DF"
eq "$(pool_ceiling_queue_from_dispatchable "$DF" whatsapp_automation "$NOW")" "3" "counts only the pool's own rig store (wa)"
eq "$(pool_ceiling_queue_from_dispatchable "$DF" property_scrapers "$NOW")"   "1" "counts only the pool's own rig store (ps)"
eq "$(pool_ceiling_queue_from_dispatchable "$DF" nenhum "$NOW")"              "0" "a store with no items is a KNOWN zero (file readable and fresh)"
eq "$(pool_ceiling_queue_from_dispatchable "$DF" whatsapp_automation $((NOW + 1801)))" "" "older than its own ttl -> unreadable (empty), NOT zero"
eq "$(pool_ceiling_queue_from_dispatchable "$TMPROOT/nao-existe.json" whatsapp_automation "$NOW")" "" "missing file -> unreadable"
printf 'not json' > "$TMPROOT/corrupt.json"
eq "$(pool_ceiling_queue_from_dispatchable "$TMPROOT/corrupt.json" whatsapp_automation "$NOW")" "" "corrupt file -> unreadable"

echo "== 4. stateful step: ramp 1 per step, rate limit, persistence, log line"
SD="$TMPROOT/state"; mkdir -p "$SD"
export POOL_CEILING_STATE_DIR="$SD"
export POOL_CEILING_LOG="$TMPROOT/pool-ceiling.log"
setsig() { # load5 ncpu mem swap_free swap_used disk_free_mb
  export POOL_CEILING_T_LOAD5="$1" POOL_CEILING_T_NCPU="$2" POOL_CEILING_T_MEM="$3" \
         POOL_CEILING_T_SWAP_FREE_MB="$4" POOL_CEILING_T_SWAP_USED_MB="$5" POOL_CEILING_T_DISK_FREE_MB="$6"
}
setsig 31 10 1 5700 412 14336
export POOL_CEILING_DYNAMIC=1 POOL_CEILING_STEP_SECS=60
POOL_CEILING_NOW=1000 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok
eq "$POOL_CEILING_RESULT" "3" "first step from the fixed value 2 with queue + slack -> 3"
has "$POOL_CEILING_LOGLINE" "wa-worker 2→3" "log line carries the transition"
has "$POOL_CEILING_LOGLINE" "fila 63"        "log line carries the queue"
has "$POOL_CEILING_LOGLINE" "load5 31"       "log line carries the load"
has "$POOL_CEILING_LOGLINE" "disco 14"       "log line carries the disk"
POOL_CEILING_NOW=1030 pool_ceiling_step wa-worker 2 1 4 3 63 ok ok
eq "$POOL_CEILING_RESULT" "3" "second call 30s later is rate-limited -> stored ceiling, no step (multi-admit re-exec safe)"
has "$POOL_CEILING_LOGLINE" "ritmo" "rate-limited line says so"
POOL_CEILING_NOW=1100 pool_ceiling_step wa-worker 2 1 4 3 63 ok ok
eq "$POOL_CEILING_RESULT" "4" "after the step interval -> 4"
POOL_CEILING_NOW=1200 pool_ceiling_step wa-worker 2 1 4 4 63 ok ok
eq "$POOL_CEILING_RESULT" "4" "at max -> stays 4"
setsig 31 10 4 300 5800 2900   # mem critical, swap low, disk below critical
POOL_CEILING_NOW=1300 pool_ceiling_step wa-worker 2 1 4 4 63 ok ok
eq "$POOL_CEILING_RESULT" "3" "squeezed -> down 1 (sessions already open are left alone: only the ceiling drops)"
has "$POOL_CEILING_LOGLINE" "wa-worker 4→3" "down line carries the transition"
setsig 31 10 1 5700 412 14336
POOL_CEILING_NOW=1400 pool_ceiling_step wa-worker 2 1 4 3 0 ok ok
eq "$POOL_CEILING_RESULT" "3" "queue empty -> holds (no decay)"
POOL_CEILING_NOW=1500 pool_ceiling_step wa-worker 2 1 4 2 "" ok ok
eq "$POOL_CEILING_RESULT" "3" "queue unreadable -> holds (no raise)"
POOL_CEILING_NOW=1600 pool_ceiling_step ps-worker 1 1 2 1 4 ok ok
eq "$POOL_CEILING_RESULT" "2" "pools keep independent state (ps-worker 1->2 does not touch wa-worker)"
POOL_CEILING_NOW=1700 pool_ceiling_step wa-worker 2 1 4 2 "" ok ok
eq "$POOL_CEILING_RESULT" "3" "wa-worker state intact after the ps-worker step (still the 3 it held)"
[ -s "$POOL_CEILING_LOG" ] && ok "append-only log written for the 24h measurement" || bad "no pool-ceiling.log written"
has "$(cat "$POOL_CEILING_LOG" 2>/dev/null)" "wa-worker" "log file names the pool"

echo "== 5. fail-safe: opt-in, kill file, corrupt state, unwritable state, DRY run"
SD2="$TMPROOT/state2"; mkdir -p "$SD2"; export POOL_CEILING_STATE_DIR="$SD2"
( unset POOL_CEILING_DYNAMIC; POOL_CEILING_NOW=2000 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok
  [ "$POOL_CEILING_RESULT" = "2" ] && [ -z "$POOL_CEILING_LOGLINE" ] && [ ! -e "$SD2/wa-worker.state" ] ) \
  && ok "NOT enabled (POOL_CEILING_DYNAMIC unset): fixed ceiling, silent, writes nothing — merging this changes nothing" \
  || bad "unset POOL_CEILING_DYNAMIC is not inert"
POOL_CEILING_DYNAMIC=0 POOL_CEILING_NOW=2000 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok
eq "$POOL_CEILING_RESULT" "2" "POOL_CEILING_DYNAMIC=0 -> the fixed ceiling, untouched"
[ ! -e "$SD2/wa-worker.state" ] && ok "disabled writes no state" || bad "disabled still wrote state"
touch "$POOL_CEILING_ON_FILE"
( unset POOL_CEILING_DYNAMIC; POOL_CEILING_NOW=2000 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok; [ "$POOL_CEILING_RESULT" = "3" ] ) \
  && ok "the .on FILE enables it with no env (instant, no plist edit/bootout)" || bad "the .on file does not enable the dynamic ceiling"
rm -f "$SD2/wa-worker.state"
POOL_CEILING_DYNAMIC=0 POOL_CEILING_NOW=2000 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok
eq "$POOL_CEILING_RESULT" "2" "POOL_CEILING_DYNAMIC=0 is a HARD off: even the .on file does not override it"
[ ! -e "$SD2/wa-worker.state" ] && ok "hard off wrote no state" || bad "hard off wrote state"
rm -f "$POOL_CEILING_ON_FILE"
touch "$POOL_CEILING_KILL_FILE"
POOL_CEILING_NOW=2000 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok
eq "$POOL_CEILING_RESULT" "2" "kill FILE -> the fixed ceiling too (instant, no plist edit/bootout)"
has "$POOL_CEILING_LOGLINE" "kill file" "kill file is said out loud"
[ ! -e "$SD2/wa-worker.state" ] && ok "kill file writes no state" || bad "kill file still wrote state"
rm -f "$POOL_CEILING_KILL_FILE"
printf 'ceiling=banana\nat=oops\n' > "$SD2/wa-worker.state"
POOL_CEILING_NOW=2100 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok
eq "$POOL_CEILING_RESULT" "3" "corrupt state -> re-initialised at the FIXED value (today's behaviour), then steps"
has "$POOL_CEILING_LOGLINE" "corrompido" "a corrupt state file is said out loud in the line, not silently reset"
printf 'ceiling=3\nat=%s\n' "$(( 2100 ))" > "$SD2/wa-worker.state"
POOL_CEILING_NOW=2110 pool_ceiling_step wa-worker 2 1 4 3 63 ok ok
case "$POOL_CEILING_LOGLINE" in *corrompido*) bad "a VALID state file must not claim to be corrupt" ;; *) ok "a valid state file does not claim to be corrupt" ;; esac
rm -f "$SD2/wa-worker.state"
printf 'ceiling=banana\nat=oops\n' > "$SD2/wa-worker.state"
printf 'ceiling=3\nat=%s\n' "9999999999" > "$SD2/wa-worker.state"
POOL_CEILING_NOW=2200 pool_ceiling_step wa-worker 2 1 4 3 63 ok ok
eq "$POOL_CEILING_RESULT" "4" "state stamped in the FUTURE (clock jump) is not a permanent rate-limit"
POOL_CEILING_STATE_DIR="/proc/definitely/not/writable" POOL_CEILING_NOW=2300 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok
eq "$POOL_CEILING_RESULT" "2" "state dir unwritable -> the FIXED ceiling (cannot persist a ramp -> inert)"
has "$POOL_CEILING_LOGLINE" "estado" "unwritable state is said out loud, not silent"
SD3="$TMPROOT/state3"; mkdir -p "$SD3"
POOL_CEILING_STATE_DIR="$SD3" POOL_CEILING_DRY=1 POOL_CEILING_NOW=2400 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok
eq "$POOL_CEILING_RESULT" "3" "DRY run computes the decision"
[ ! -e "$SD3/wa-worker.state" ] && ok "DRY run persists nothing (Pilot DRY_RUN=1 makes zero state changes)" || bad "DRY run wrote state"
setsig "" "" "" "" "" ""
POOL_CEILING_STATE_DIR="$SD3" POOL_CEILING_NOW=2500 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok
eq "$POOL_CEILING_RESULT" "2" "every machine signal unreadable + queue -> holds at the current value, never raises"
has "$POOL_CEILING_LOGLINE" "unreadable" "and says which signals were unreadable"

echo "== 5b. shadow mode: decide, persist and LOG, apply nothing (calibration without risk)"
SDS="$TMPROOT/state-shadow"; mkdir -p "$SDS"; LS="$TMPROOT/shadow.log"
export POOL_CEILING_DYNAMIC=1 POOL_CEILING_STATE_DIR="$SDS" POOL_CEILING_LOG="$LS" POOL_CEILING_SHADOW=1
export POOL_CEILING_T_LOAD5=31 POOL_CEILING_T_NCPU=10 POOL_CEILING_T_MEM=1 POOL_CEILING_T_SWAP_FREE_MB=5700 POOL_CEILING_T_SWAP_USED_MB=412 POOL_CEILING_T_DISK_FREE_MB=14336
POOL_CEILING_NOW=3000 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok
eq "$POOL_CEILING_RESULT" "2" "shadow: the decision is 'up' but the caller keeps the FIXED ceiling"
has "$POOL_CEILING_LOGLINE" "sombra" "shadow: the line says it was NOT applied"
has "$POOL_CEILING_LOGLINE" "wa-worker 2→3" "shadow: and still shows what would have happened"
eq "$(sed -n 's/^ceiling=//p' "$SDS/wa-worker.shadow.state")" "3" "shadow: the simulated ceiling is persisted in its OWN file (the series evolves)"
[ ! -e "$SDS/wa-worker.state" ] && ok "shadow never touches the REAL state file" || bad "shadow wrote the real state file"
POOL_CEILING_NOW=3100 pool_ceiling_step wa-worker 2 1 4 3 63 ok ok
eq "$POOL_CEILING_RESULT" "2" "shadow: still the fixed value on the next step"
has "$POOL_CEILING_LOGLINE" "wa-worker 3→4" "shadow: the simulation keeps climbing"
export POOL_CEILING_T_MEM=4
POOL_CEILING_NOW=3200 pool_ceiling_step wa-worker 2 1 4 3 63 ok ok
eq "$POOL_CEILING_RESULT" "2" "shadow: a squeeze does NOT lower the real ceiling either"
has "$POOL_CEILING_LOGLINE" "wa-worker 4→3" "shadow: the simulated brake is still logged"
POOL_CEILING_NOW=3250 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok
eq "$POOL_CEILING_RESULT" "2" "shadow + rate-limited call: still the fixed value"
has "$(cat "$LS")" "applied=0" "shadow: the calibration log marks every row applied=0"
unset POOL_CEILING_SHADOW; export POOL_CEILING_T_MEM=1
POOL_CEILING_NOW=3400 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok
eq "$POOL_CEILING_RESULT" "3" "leaving shadow: starts from the FIXED 2 (never from the simulation) and takes its first real step"
has "$POOL_CEILING_LOGLINE" "wa-worker 2→3" "leaving shadow: the first applied line starts at the fixed value"
has "$(tail -1 "$LS")" "applied=1" "and the log marks the row applied=1"
touch "$POOL_CEILING_SHADOW_FILE"
POOL_CEILING_NOW=3500 pool_ceiling_step wa-worker 2 1 4 2 63 ok ok
eq "$POOL_CEILING_RESULT" "2" "the shadow FILE also puts it in shadow (instant, no plist edit)"
rm -f "$POOL_CEILING_SHADOW_FILE"
export POOL_CEILING_STATE_DIR="$SD2" POOL_CEILING_LOG="$TMPROOT/pool-ceiling.log"; unset POOL_CEILING_DYNAMIC

echo "== 5c. an unreadable CLOCK is not epoch 0 (the rate limit must not silently vanish)"
out="$(PATH=/nonexistent /bin/bash -c '. "$1"; export POOL_CEILING_DYNAMIC=1 POOL_CEILING_STATE_DIR="$2" POOL_CEILING_T_LOAD5=31 POOL_CEILING_T_NCPU=10 POOL_CEILING_T_MEM=1 POOL_CEILING_T_SWAP_FREE_MB=5700 POOL_CEILING_T_SWAP_USED_MB=412 POOL_CEILING_T_DISK_FREE_MB=14336; unset POOL_CEILING_NOW; pool_ceiling_step wa-worker 2 1 4 2 63 ok ok; echo "R=$POOL_CEILING_RESULT L=$POOL_CEILING_LOGLINE"' _ "$LIB" "$TMPROOT/clk" 2>/dev/null)"
has "$out" "R=2 " "no clock (no \`date\` on PATH): the FIXED ceiling, no step"
has "$out" "relogio" "and the line says the clock was unreadable"
[ ! -e "$TMPROOT/clk/wa-worker.state" ] && ok "and nothing was written under a clock it could not read" || bad "state written without a readable clock"

echo "== 6. real readers return an integer or empty, never garbage (smoke, live machine)"
unset POOL_CEILING_T_LOAD5 POOL_CEILING_T_NCPU POOL_CEILING_T_MEM POOL_CEILING_T_SWAP_FREE_MB POOL_CEILING_T_SWAP_USED_MB POOL_CEILING_T_DISK_FREE_MB
for rd in pool_ceiling_read_ncpu pool_ceiling_read_mem_pressure pool_ceiling_read_swap_free_mb \
          pool_ceiling_read_swap_used_mb pool_ceiling_read_disk_free_mb; do
  v="$($rd 2>/dev/null || true)"
  case "$v" in ''|*[!0-9]*) [ -z "$v" ] && ok "$rd -> empty (unreadable here)" || bad "$rd returned garbage: '$v'" ;; *) ok "$rd -> $v" ;; esac
done
v="$(pool_ceiling_read_load5 2>/dev/null || true)"
case "$v" in ''|*[!0-9.]*) [ -z "$v" ] && ok "pool_ceiling_read_load5 -> empty" || bad "load5 garbage: '$v'" ;; *) ok "pool_ceiling_read_load5 -> $v" ;; esac

echo "== 6b. strict-mode safe: the dispatchers may run under set -euo pipefail; the lib must never abort them"
out="$(bash -c 'set -euo pipefail; . "$1"; export POOL_CEILING_DYNAMIC=1 POOL_CEILING_STATE_DIR="$2" POOL_CEILING_NOW=5000 POOL_CEILING_T_LOAD5=30 POOL_CEILING_T_NCPU=10 POOL_CEILING_T_MEM=1 POOL_CEILING_T_SWAP_FREE_MB=5000 POOL_CEILING_T_SWAP_USED_MB=100 POOL_CEILING_T_DISK_FREE_MB=20000; pool_ceiling_step wa-worker 2 1 4 2 5 ok ok; pool_ceiling_step ps-worker 1 1 2 "" "" unknown unknown; pool_ceiling_decide x y z "" "" bogus; echo SURVIVED=$POOL_CEILING_RESULT' _ "$LIB" "$TMPROOT/strict" 2>&1)"
has "$out" "SURVIVED=" "step + decide with garbage/empty args survive set -euo pipefail"

echo "== 8. the Pilot's REAL glue function, extracted from pilot-dispatcher.sh and run against fixtures"
EXTRACT="$(sed -n '/SELFTEST-EXTRACT pilot-apply-dynamic-pool-ceilings: BEGIN/,/SELFTEST-EXTRACT pilot-apply-dynamic-pool-ceilings: END/p' "$PILOT" 2>/dev/null)"
PNOTE_X="$(sed -n '/SELFTEST-EXTRACT pool-ceiling-note: BEGIN/,/SELFTEST-EXTRACT pool-ceiling-note: END/p' "$PILOT" 2>/dev/null)"
GNOTE_X="$(sed -n '/SELFTEST-EXTRACT pool-ceiling-note: BEGIN/,/SELFTEST-EXTRACT pool-ceiling-note: END/p' "$GATE" 2>/dev/null)"
if [ -z "$EXTRACT" ]; then
  bad "no SELFTEST-EXTRACT pilot-apply-dynamic-pool-ceilings block in $PILOT"
else
  NOWISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  OLDISO="$(date -u -r $(( $(date +%s) - 7200 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
  mkq() { # <generated_at> <wa-items> <ps-items> → file path
    local f="$TMPROOT/q.$RANDOM.json" items="" i
    i=0; while [ "$i" -lt "$2" ]; do i=$((i+1)); items="$items{\"id\":\"w$i\",\"store\":\"whatsapp_automation\"},"; done   # not `seq 1 0`: BSD seq counts DOWN
    i=0; while [ "$i" -lt "$3" ]; do i=$((i+1)); items="$items{\"id\":\"p$i\",\"store\":\"property_scrapers\"},"; done
    printf '{"generated_at":"%s","ttl_seconds":1800,"items":[%s]}' "$1" "${items%,}" > "$f"; echo "$f"
  }
  SESS2='{"sessions":[{"template":"wa-worker","state":"active"},{"template":"wa-worker","state":"creating"},{"template":"wa-worker","state":"asleep"},{"template":"gate-reviewer","state":"active"},{"template":"ps-worker","state":"asleep"}]}'
  glue() { # args: state-dir ; env from caller. Prints LOG lines then "WA=<n> PS=<n>".
    bash -c '
      set -uo pipefail
      . "$1"
      log() { echo "LOG:$*"; }
      warn() { echo "WARN:$*"; }
      eval "$2"; eval "$3"
      PILOT_WA_WORKER_MAX=2; PILOT_PS_WORKER_MAX=1
      _pilot_apply_dynamic_pool_ceilings
      echo "WA=$PILOT_WA_WORKER_MAX PS=$PILOT_PS_WORKER_MAX"
    ' _ "$LIB" "$EXTRACT" "$PNOTE_X" 2>&1
  }
  gsig() { export POOL_CEILING_T_LOAD5=31 POOL_CEILING_T_NCPU=10 POOL_CEILING_T_MEM=1 POOL_CEILING_T_SWAP_FREE_MB=5700 POOL_CEILING_T_SWAP_USED_MB=412 POOL_CEILING_T_DISK_FREE_MB=14336; }
  Q="$(mkq "$NOWISO" 3 0)"
  # _PILOT_QUOTA_STATE is the sweep's own quota probe (ok | limited | unknown); the glue must not assume "ok".
  base() { export _POOL_CEILING_OK=1 POOL_CEILING_DYNAMIC=1 PILOT_DISPATCHABLE_FILE="$Q" _SESSIONS_JSON="$SESS2" PILOT_DOLT_SATURATED_AT_START=0 DOLT_SAT_REASON="" DRY_RUN=0 _PILOT_QUOTA_STATE=ok POOL_CEILING_STATE_DIR="$TMPROOT/g.$RANDOM" POOL_CEILING_LOG="$TMPROOT/g.log"; unset POOL_CEILING_NOW; gsig; }
  base; out="$(glue)"
  has "$out" "WA=3 PS=1" "queue 3 + 2 live (active+creating, asleep NOT counted) + slack -> wa-worker 2->3; ps-worker (queue 0, at min) untouched"
  has "$out" "LOG:  pool-ceiling: wa-worker 2→3" "the sweep log shows the transition"
  base; PILOT_DOLT_SATURATED_AT_START=1 DOLT_SAT_REASON=unreadable out="$(glue)"
  has "$out" "WA=2 PS=1" "Dolt probe UNREADABLE -> unknown -> the ceiling does not rise"
  base; PILOT_DOLT_SATURATED_AT_START=1 DOLT_SAT_REASON=latency out="$(glue)"
  has "$out" "WA=2 PS=1" "Dolt measured hot -> hold (no growth into a hot data plane)"
  # Same class as the quota (gate-fix 1): the Dolt default must not be "ok" either. Only a probe that RAN (flag 0) says ok.
  base; unset PILOT_DOLT_SATURATED_AT_START; out="$(glue)"
  has "$out" "WA=2 PS=1" "Dolt probe flag never set (glue called without the sweep's probe) -> unknown, NOT ok -> no raise"
  base; PILOT_DOLT_SATURATED_AT_START=banana out="$(glue)"
  has "$out" "WA=2 PS=1" "a garbage Dolt flag is unknown, not ok"
  base; PILOT_DOLT_SATURATED_AT_START=0 out="$(glue)"
  has "$out" "WA=3 PS=1" "control: a probe that RAN and read calm (flag 0) still raises"
  # ga-uywvsc gate-fix 1: the quota is a THREE-state signal. A checker that is absent / errored / timed out
  # is "unknown", and unknown must hold the ceiling exactly like an unreadable roster or Dolt probe does.
  base; _PILOT_QUOTA_STATE=unknown out="$(glue)"
  has "$out" "WA=2 PS=1" "quota UNKNOWN (checker could not be read) + queue + slack -> the ceiling does not rise"
  has "$out" "unreadable:quota" "and the reason says the quota was unreadable, not 'idle' or 'ok'"
  has "$out" "cota unknown [unknown]" "and the log line prints 'cota unknown', never 'cota ok [grow]'"
  base; unset _PILOT_QUOTA_STATE; out="$(glue)"
  has "$out" "WA=2 PS=1" "quota state never set (glue called without the sweep's probe) -> unknown, NOT ok"
  base; _PILOT_QUOTA_STATE=limited out="$(glue)"
  has "$out" "WA=2 PS=1" "quota limited -> hold (the window resets; shrinking would only slow the recovery)"
  base; _PILOT_QUOTA_STATE=banana out="$(glue)"
  has "$out" "WA=2 PS=1" "a garbage quota state is unknown, not ok"
  base; _PILOT_QUOTA_STATE=ok out="$(glue)"
  has "$out" "WA=3 PS=1" "control: the SAME fixtures with quota ok DO raise (the cases above differ only in the quota)"
  base; _SESSIONS_JSON="" out="$(glue)"
  has "$out" "WA=2 PS=1" "roster unreadable -> live unknown -> no raise"
  base; PILOT_DISPATCHABLE_FILE="$(mkq "$OLDISO" 3 0)" out="$(glue)"
  has "$out" "WA=2 PS=1" "dispatchable emit older than its ttl -> queue unreadable -> no raise"
  base; PILOT_DISPATCHABLE_FILE="$(mkq "$NOWISO" 0 4)" _SESSIONS_JSON='{"sessions":[{"template":"ps-worker","state":"active"}]}' out="$(glue)"
  has "$out" "WA=2 PS=2" "wa queue empty -> holds at 2 (no decay); ps queue 4, saturated at 1 -> 1->2"
  base; unset POOL_CEILING_DYNAMIC; out="$(glue)"
  has "$out" "WA=2 PS=1" "POOL_CEILING_DYNAMIC unset -> fixed caps"
  case "$out" in *LOG:*) bad "an inert sweep must not log" ;; *) ok "an inert sweep logs nothing" ;; esac
  base; _POOL_CEILING_OK=0 out="$(glue)"
  has "$out" "WA=2 PS=1" "lib not loaded (_POOL_CEILING_OK=0) -> fixed caps even with DYNAMIC=1"
  has "$out" "WARN:pool-ceiling: LIGADO" "...and the sweep SAYS the ceiling is on but the lib is not loaded (it used to look exactly like 'off')"
  base; _POOL_CEILING_OK=0; unset POOL_CEILING_DYNAMIC; out="$(glue)"
  has "$out" "WA=2 PS=1" "lib not loaded and not switched on -> fixed caps"
  case "$out" in *WARN:*|*LOG:*) bad "lib not loaded but the ceiling is OFF: must stay silent (nothing was asked for)" ;; *) ok "lib not loaded but the ceiling is OFF -> silent" ;; esac
  base; _POOL_CEILING_OK=0 POOL_CEILING_DYNAMIC=0 out="$(glue)"
  case "$out" in *WARN:*) bad "POOL_CEILING_DYNAMIC=0 is a hard off: no warning" ;; *) ok "POOL_CEILING_DYNAMIC=0 + lib not loaded -> silent" ;; esac
  base; DRY_RUN=1; SDRY="$POOL_CEILING_STATE_DIR"; out="$(glue)"
  has "$out" "WA=3 PS=1" "DRY_RUN=1 still computes the decision"
  [ -z "$(ls "$SDRY" 2>/dev/null)" ] && ok "DRY_RUN=1 persisted nothing" || bad "DRY_RUN=1 wrote state"
  base; export POOL_CEILING_SHADOW=1; out="$(glue)"; unset POOL_CEILING_SHADOW   # exported on purpose: the glue runs in a child bash
  has "$out" "WA=2 PS=1" "shadow: the Pilot's caps stay the fixed ones"
  has "$out" "sombra" "shadow: and the sweep log says what it would have done"
  base; unset POOL_CEILING_DYNAMIC DRY_RUN
fi

echo "== 7. wiring drift-guards (the lib is only useful if the dispatchers actually call it)"
if [ -r "$PILOT" ]; then
  grep -q 'pool_ceiling_step' "$PILOT" && ok "pilot-dispatcher.sh calls pool_ceiling_step" || bad "pilot-dispatcher.sh never calls pool_ceiling_step"
  grep -q 'PILOT_WA_WORKER_MAX="\$POOL_CEILING_RESULT"\|PILOT_WA_WORKER_MAX=\$POOL_CEILING_RESULT' "$PILOT" \
    && ok "pilot reassigns PILOT_WA_WORKER_MAX from the dynamic result" || bad "pilot never reassigns PILOT_WA_WORKER_MAX"
  grep -q 'PILOT_PS_WORKER_MAX="\$POOL_CEILING_RESULT"\|PILOT_PS_WORKER_MAX=\$POOL_CEILING_RESULT' "$PILOT" \
    && ok "pilot reassigns PILOT_PS_WORKER_MAX from the dynamic result" || bad "pilot never reassigns PILOT_PS_WORKER_MAX"
  l_step=$(grep -n 'pool_ceiling_step wa-worker' "$PILOT" | head -1 | cut -d: -f1)
  l_pause=$(grep -n '_pilot_write_sweep_pause_state 0 "" ""' "$PILOT" | head -1 | cut -d: -f1)
  l_topup=$(grep -n '^_pilot_pool_topup "wa-worker"' "$PILOT" | head -1 | cut -d: -f1)
  if [ -n "$l_step" ] && [ -n "$l_pause" ] && [ -n "$l_topup" ] && [ "$l_step" -gt "$l_pause" ] && [ "$l_step" -lt "$l_topup" ]; then
    ok "pilot decides AFTER the whole-sweep pauses (quota/RAM/quiet-hours exit first) and BEFORE the first cap use (top-up)"
  else
    bad "pilot ordering wrong: step@${l_step:-none} pause@${l_pause:-none} topup@${l_topup:-none}"
  fi
  grep -q 'DRY_RUN' <(grep -n -B6 -A6 'pool_ceiling_step wa-worker' "$PILOT") \
    && ok "pilot passes DRY_RUN through (DRY run persists nothing)" || bad "pilot does not honour DRY_RUN around the step"
  # The lib must be optional: a missing/unreadable lib must leave the fixed caps in force, not kill the Pilot.
  grep -q '_POOL_CEILING_OK' "$PILOT" && ok "pilot guards on the lib being loadable (fail-safe to the fixed caps)" || bad "pilot has no lib-missing guard"
  grep -q 'pool_ceiling_enabled || return 0' "$PILOT" && ok "pilot gates the whole block on the shared pool_ceiling_enabled predicate" || bad "pilot does not use pool_ceiling_enabled"
else
  bad "pilot-dispatcher.sh not readable at $PILOT"
fi
if [ -r "$GATE" ]; then
  grep -q 'pool_ceiling_step gate-reviewer' "$GATE" && ok "quality-gate-dispatcher.sh calls pool_ceiling_step gate-reviewer" || bad "gate never calls pool_ceiling_step"
  grep -q 'GATE_MAX_REVIEWERS="\$POOL_CEILING_RESULT"\|GATE_MAX_REVIEWERS=\$POOL_CEILING_RESULT' "$GATE" \
    && ok "gate reassigns GATE_MAX_REVIEWERS from the dynamic result" || bad "gate never reassigns GATE_MAX_REVIEWERS"
  g_step=$(grep -n 'pool_ceiling_step gate-reviewer' "$GATE" | head -1 | cut -d: -f1)
  g_dec=$(grep -n 'HR_DECISION=\$(gate_headroom_decision' "$GATE" | head -1 | cut -d: -f1)
  if [ -n "$g_step" ] && [ -n "$g_dec" ] && [ "$g_step" -lt "$g_dec" ]; then
    ok "gate decides BEFORE gate_headroom_decision consumes GATE_MAX_REVIEWERS"
  else
    bad "gate ordering wrong: step@${g_step:-none} decision@${g_dec:-none}"
  fi
  grep -q '_POOL_CEILING_OK' "$GATE" && ok "gate guards on the lib being loadable" || bad "gate has no lib-missing guard"
  grep -q '_POOL_CEILING_OK:-0}" = "1" \] && pool_ceiling_enabled' "$GATE" && ok "gate gates the block on the shared pool_ceiling_enabled predicate" || bad "gate does not use pool_ceiling_enabled"
else
  bad "quality-gate-dispatcher.sh not readable at $GATE"
fi

echo "== 9. the quota is a THREE-state signal end to end (gate-fix 1: an unreadable checker was fed to the ceiling as 'ok')"
# 9a. step level: only quota=ok lets the ceiling grow. Same slack, same queue; the cases differ ONLY in the quota.
export POOL_CEILING_T_LOAD5=31 POOL_CEILING_T_NCPU=10 POOL_CEILING_T_MEM=1 POOL_CEILING_T_SWAP_FREE_MB=5700 POOL_CEILING_T_SWAP_USED_MB=412 POOL_CEILING_T_DISK_FREE_MB=14336
printf 'work_dir = "/x"\nmax_active_sessions = 4\n' > "$AG/wa-worker/agent.toml"
qstep() { # <quota-arg|OMIT> → "<result>|<logline>"
  local sd="$TMPROOT/qs.$RANDOM"; mkdir -p "$sd"
  if [ "$1" = OMIT ]; then
    POOL_CEILING_DYNAMIC=1 POOL_CEILING_STATE_DIR="$sd" POOL_CEILING_LOG="$TMPROOT/qs.log" POOL_CEILING_NOW=1000 bash -c '. "$1"; pool_ceiling_step wa-worker 2 1 4 2 63 ok; echo "$POOL_CEILING_RESULT|$POOL_CEILING_LOGLINE"' _ "$LIB"
  else
    POOL_CEILING_DYNAMIC=1 POOL_CEILING_STATE_DIR="$sd" POOL_CEILING_LOG="$TMPROOT/qs.log" POOL_CEILING_NOW=1000 bash -c '. "$1"; pool_ceiling_step wa-worker 2 1 4 2 63 ok "$2"; echo "$POOL_CEILING_RESULT|$POOL_CEILING_LOGLINE"' _ "$LIB" "$1"
  fi
}
r="$(qstep ok)";        eq "${r%%|*}" "3" "control: queue 63 + slack + quota ok -> 2->3"
r="$(qstep unknown)";   eq "${r%%|*}" "2" "quota unknown + queue + slack -> HOLD (does not raise)"
has "$r" "unreadable:quota" "  reason is unreadable:quota"
has "$r" "cota unknown [unknown]" "  and the log says 'cota unknown', not 'cota ok [grow]'"
r="$(qstep limited)";   eq "${r%%|*}" "2" "quota limited + queue + slack -> hold"
has "$r" "soft:quota" "  reason is soft:quota"
r="$(qstep '')";        eq "${r%%|*}" "2" "quota passed as an EMPTY string -> unknown -> hold"
r="$(qstep OMIT)";      eq "${r%%|*}" "2" "quota argument OMITTED -> unknown -> hold (the default is the safe state)"
eq "$(pool_ceiling_decide 2 1 4 2 63 load=grow mem=grow swap=grow disk=grow dolt=grow quota=unknown)" "2|hold|unreadable:quota" "decide: quota=unknown -> hold, named"

# 9b. the producers, EXECUTED (not grepped) against a fake checker. Both dispatchers' own functions are
# extracted from the file between SELFTEST-EXTRACT markers. rc 0 -> ok, rc 2 -> limited, EVERYTHING else
# (checker's own error 1, timeout 124, no `timeout` 127, killed by a signal, absent, not executable) -> unknown.
PQ_EXTRACT="$(sed -n '/SELFTEST-EXTRACT pilot-quota-state: BEGIN/,/SELFTEST-EXTRACT pilot-quota-state: END/p' "$PILOT" 2>/dev/null)"
GQ_EXTRACT="$(sed -n '/SELFTEST-EXTRACT gate-quota-state: BEGIN/,/SELFTEST-EXTRACT gate-quota-state: END/p' "$GATE" 2>/dev/null)"
mkqc() { # <name> <exit-code|ABSENT|NOEXEC|SIGKILL> → a GC_CITY dir whose scripts/claude-quota-check.sh behaves so
  local d="$TMPROOT/qc.$1" f; mkdir -p "$d/scripts"; f="$d/scripts/claude-quota-check.sh"
  case "$2" in
    ABSENT) ;;
    NOEXEC) printf '#!/bin/bash\nexit 0\n' > "$f"; chmod -x "$f" ;;
    SIGKILL) printf '#!/bin/bash\nkill -9 $$\n' > "$f"; chmod +x "$f" ;;
    *) printf '#!/bin/bash\nexit %s\n' "$2" > "$f"; chmod +x "$f" ;;
  esac
  echo "$d"
}
if [ -z "$PQ_EXTRACT" ] || [ -z "$GQ_EXTRACT" ]; then
  bad "missing SELFTEST-EXTRACT pilot-quota-state / gate-quota-state block (pilot: ${#PQ_EXTRACT} bytes, gate: ${#GQ_EXTRACT} bytes)"
else
  # prints "<state> <limited-flag>" from the dispatcher's real functions, under set -euo pipefail
  pq() { # <GC_CITY> [override] [PATH]
    PATH="${3:-$PATH}" bash -c 'set -euo pipefail; PILOT_QUOTA_OVERRIDE="${3:-}"; GC_CITY="$2"; eval "$1"; printf "%s %s" "$(_pilot_quota_state)" "$(_pilot_quota_limited)"' _ "$PQ_EXTRACT" "$1" "${2:-}" 2>&1
  }
  gq() {
    PATH="${3:-$PATH}" bash -c 'set -euo pipefail; GC_CITY="$2"; if [ -n "${3:-}" ]; then GATE_QUOTA_OVERRIDE="$3"; fi; eval "$1"; printf "%s %s" "$(gate_quota_state)" "$(gate_quota_limited)"' _ "$GQ_EXTRACT" "$1" "${2:-}" 2>&1
  }
  for who in pq gq; do
    nm="pilot"; [ "$who" = gq ] && nm="gate"
    eq "$($who "$(mkqc c0 0)")"         "ok 0"        "$nm: checker exit 0 -> ok (limited flag 0)"
    eq "$($who "$(mkqc c2 2)")"         "limited 1"   "$nm: checker exit 2 -> limited (flag 1)"
    eq "$($who "$(mkqc c1 1)")"         "unknown 0"   "$nm: checker's own error (exit 1) -> UNKNOWN; the legacy 0/1 flag stays fail-open (0)"
    eq "$($who "$(mkqc c124 124)")"     "unknown 0"   "$nm: checker timed out (exit 124) -> unknown"
    eq "$($who "$(mkqc c3 3)")"         "unknown 0"   "$nm: any other exit code -> unknown"
    eq "$($who "$(mkqc ck SIGKILL)")"   "unknown 0"   "$nm: checker killed by a signal -> unknown"
    eq "$($who "$(mkqc cn NOEXEC)")"    "unknown 0"   "$nm: checker not executable -> unknown"
    eq "$($who "$(mkqc ca ABSENT)")"    "unknown 0"   "$nm: checker absent -> unknown (this was 'ok' before)"
    eq "$($who "$(mkqc c1b 1)" 2)"      "limited 1"   "$nm: operator override '2' -> limited, whatever the checker says"
    eq "$($who "$(mkqc c1c 1)" 0)"      "ok 0"        "$nm: operator override (not 2) -> ok: a stated fact, not a failed read"
  done
  if ! PATH=/usr/bin:/bin command -v timeout >/dev/null 2>&1; then
    eq "$(pq "$(mkqc c0t 0)" "" /usr/bin:/bin)" "unknown 0" "pilot: no \`timeout\` binary at all (exit 127) -> unknown, not ok"
    eq "$(gq "$(mkqc c0u 0)" "" /usr/bin:/bin)" "unknown 0" "gate: no \`timeout\` binary at all (exit 127) -> unknown, not ok"
  fi
fi

# 9c. the gate's REAL ceiling block (extracted from quality-gate-dispatcher.sh), executed under set -euo pipefail,
# twice — the second pass emulates the ga-309v3 multi-admit re-exec, which must still see the ORIGINAL fixed value.
GE_EXTRACT="$(sed -n '/SELFTEST-EXTRACT gate-apply-dynamic-ceiling: BEGIN/,/SELFTEST-EXTRACT gate-apply-dynamic-ceiling: END/p' "$GATE" 2>/dev/null)"
if [ -z "$GE_EXTRACT" ]; then
  bad "no SELFTEST-EXTRACT gate-apply-dynamic-ceiling block in $GATE"
else
  printf 'max_active_sessions = 6\n' > "$AG/gate-reviewer/agent.toml"
  gglue() { # env from caller: HR_QSTATE LIVE_REVIEWERS COUNT ... ; prints LOG lines then "MAX=<n> FIXED=<n>" per pass
    bash -c '
      set -euo pipefail
      . "$1"
      log() { echo "LOG:$*"; }
      GATE_MAX_REVIEWERS="${GATE_MAX_REVIEWERS:-4}"; GATE_REVIEWERS_PER_RUN="${GATE_REVIEWERS_PER_RUN:-3}"
      GATE_DOLT_CPU_HOT=180; GATE_DOLT_LATENCY_HOT_MS=2500
      GATE_SWAP_FREE_FLOOR_MB="${GATE_SWAP_FREE_FLOOR_MB:-512}"; GATE_SWAP_GROW_DISK_MIN_MB="${GATE_SWAP_GROW_DISK_MIN_MB:-4096}"
      HR_CPU=95; HR_LAT=300
      eval "$3"
      # what the gate sets just before this block (HR_QLIM = the fail-open 0/1 the headroom decision eats): a block that
      # collapses the quota back to ok/limited from HR_QLIM must FAIL here on its behaviour (MAX=5 on an unknown quota),
      # not crash on an unbound variable and fail for the wrong reason
      if [ "${HR_QSTATE:-}" = "limited" ]; then HR_QLIM=1; else HR_QLIM=0; fi
      unset GATE_MAX_REVIEWERS_FIXED || true
      eval "$2"; echo "PASS1 MAX=$GATE_MAX_REVIEWERS FIXED=${GATE_MAX_REVIEWERS_FIXED:-none}"
      # pass 2 = the ga-309v3 multi-admit re-exec: GATE_MAX_REVIEWERS still carries pass 1'"'"'s dynamic value, and
      # only the exported GATE_MAX_REVIEWERS_FIXED can tell the block what the real fixed ceiling is
      export POOL_CEILING_NOW=$((POOL_CEILING_NOW + 120))
      eval "$2"; echo "PASS2 MAX=$GATE_MAX_REVIEWERS FIXED=${GATE_MAX_REVIEWERS_FIXED:-none}"
    ' _ "$LIB" "$GE_EXTRACT" "$GNOTE_X" 2>&1
  }
  gbase() { export _POOL_CEILING_OK=1 POOL_CEILING_DYNAMIC=1 HR_QSTATE=ok LIVE_REVIEWERS=4 COUNT=5 DRY_RUN=0 POOL_CEILING_NOW=2000 \
                   POOL_CEILING_STATE_DIR="$TMPROOT/ge.$RANDOM" POOL_CEILING_LOG="$TMPROOT/ge.log" \
                   POOL_CEILING_T_LOAD5=31 POOL_CEILING_T_NCPU=10 POOL_CEILING_T_MEM=1 POOL_CEILING_T_SWAP_FREE_MB=5700 POOL_CEILING_T_SWAP_USED_MB=412 POOL_CEILING_T_DISK_FREE_MB=14336
            unset POOL_CEILING_SWAP_FREE_FLOOR_MB POOL_CEILING_SWAP_GROW_DISK_MIN_MB GATE_SWAP_FREE_FLOOR_MB GATE_SWAP_GROW_DISK_MIN_MB; }
  gbase; out="$(gglue)"
  has "$out" "PASS1 MAX=5 FIXED=4" "gate, quota ok + queue 5 + 4 live (saturated at 4) + slack -> GATE_MAX_REVIEWERS 4->5, fixed value remembered"
  has "$out" "PASS2 MAX=" "the block survives set -euo pipefail and a second pass"
  has "${out#*PASS1}" "(fixo 4," "the second pass (multi-admit re-exec; GATE_MAX_REVIEWERS already 5) still passes the ORIGINAL fixed value 4"
  case "${out#*PASS1}" in *"(fixo 5,"*) bad "the second pass took the previous round's dynamic value 5 as the fixed one" ;; *) ok "and never 5 as the fixed value" ;; esac
  gbase; HR_QSTATE=unknown out="$(gglue)"
  has "$out" "PASS1 MAX=4 FIXED=4" "gate, quota UNKNOWN + queue + slack -> the ceiling does not rise"
  has "$out" "cota unknown [unknown]" "and the gate's log line says the quota was unknown"
  gbase; HR_QSTATE=limited out="$(gglue)"
  has "$out" "PASS1 MAX=4 FIXED=4" "gate, quota limited -> hold"
  gbase; HR_QSTATE="" out="$(gglue)"
  has "$out" "PASS1 MAX=4 FIXED=4" "gate, quota state EMPTY -> unknown -> the ceiling does not rise"
  gbase; unset HR_QSTATE; out="$(gglue)"
  has "$out" "PASS1 MAX=4 FIXED=4" "gate, quota state UNSET -> unknown -> the ceiling does not rise, and the gate (set -u) does not abort"
  gbase; export GATE_SWAP_FREE_FLOOR_MB=9000 GATE_SWAP_GROW_DISK_MIN_MB=20000; out="$(gglue)"
  has "$out" "PASS1 MAX=3" "the gate's ceiling follows the GATE_SWAP_* knobs (free 5700MB < floor 9000 + disk 14GB < 20GB -> swap cannot grow -> squeeze 4->3)"
  gbase; export GATE_SWAP_FREE_FLOOR_MB=9000 GATE_SWAP_GROW_DISK_MIN_MB=20000 POOL_CEILING_SWAP_FREE_FLOOR_MB=100; out="$(gglue)"
  has "$out" "PASS1 MAX=5" "but an explicit POOL_CEILING_SWAP_FREE_FLOOR_MB wins over the gate's knob (and the ceiling climbs again)"
  gbase   # also clears the exported GATE_SWAP_* / POOL_CEILING_SWAP_* knobs so nothing leaks into the sections below
  gbase; _POOL_CEILING_OK=0 out="$(gglue)"
  has "$out" "PASS1 MAX=4 FIXED=none" "lib not loaded -> the fixed ceiling, nothing exported"
  has "$out" "LOG:pool-ceiling: LIGADO" "...and the gate SAYS the ceiling is on but the lib is not loaded (it used to look exactly like 'off')"
  gbase; _POOL_CEILING_OK=0; unset POOL_CEILING_DYNAMIC; out="$(gglue)"
  has "$out" "PASS1 MAX=4 FIXED=none" "lib not loaded and not switched on -> fixed ceiling"
  case "$out" in *LOG:*) bad "lib not loaded but the ceiling is OFF: the gate must stay silent" ;; *) ok "lib not loaded but the ceiling is OFF -> silent" ;; esac
  gbase; unset POOL_CEILING_DYNAMIC; out="$(gglue)"
  has "$out" "PASS1 MAX=4 FIXED=none" "not switched on -> inert: fixed ceiling, no log line"
  case "$out" in *LOG:*) bad "an inert gate sweep must not log" ;; *) ok "an inert gate sweep logs nothing" ;; esac
  unset HR_QSTATE LIVE_REVIEWERS COUNT DRY_RUN POOL_CEILING_NOW POOL_CEILING_DYNAMIC _POOL_CEILING_OK
  printf 'max_active_sessions = 6\n' > "$AG/gate-reviewer/agent.toml"
fi

# 9d. an unparseable threshold knob falls back to its default instead of silently reading as 'not squeezed'
eq "$(POOL_CEILING_SWAP_FREE_FLOOR_MB=banana pool_ceiling_class_swap 100 100 2000)" "squeeze" "garbage swap floor knob -> default 512 (free 100 + disk 2 GB: swap cannot grow -> squeeze), not 'not low'"
eq "$(POOL_CEILING_SWAP_GROW_DISK_MIN_MB=banana pool_ceiling_class_swap 100 100 2000)" "squeeze" "garbage swap-disk knob -> default 4096"
eq "$(POOL_CEILING_SWAP_GROW_MAX_USED_MB=banana pool_ceiling_class_swap 5000 5000 20000)" "hold" "garbage swap-used knob -> default 4096 (5000 MB used -> hold)"
eq "$(POOL_CEILING_LOAD_GROW_PER_CORE=banana pool_ceiling_class_load 62 10)"    "hold" "garbage load-grow knob -> default 5.0 (6.2/core -> hold; a string compare would have said grow)"
eq "$(POOL_CEILING_LOAD_SQUEEZE_PER_CORE=banana pool_ceiling_class_load 90 10)" "squeeze" "garbage load-squeeze knob -> default 8.0 (9/core -> squeeze)"

# 9e. wiring drift-guards for the quota (the executed cases above are the proof; these catch a regression of the call sites)
if [ -r "$PILOT" ]; then
  l_qs=$(grep -n '^_PILOT_QUOTA_STATE="\$(_pilot_quota_state)"' "$PILOT" | head -1 | cut -d: -f1)
  l_ap=$(grep -n '^_pilot_apply_dynamic_pool_ceilings$' "$PILOT" | head -1 | cut -d: -f1)
  if [ -n "$l_qs" ] && [ -n "$l_ap" ] && [ "$l_qs" -lt "$l_ap" ]; then ok "pilot takes the sweep's quota probe (_PILOT_QUOTA_STATE) BEFORE applying the ceilings"; else bad "pilot quota-state ordering wrong: probe@${l_qs:-none} apply@${l_ap:-none}"; fi
  if grep -E 'pool_ceiling_step (wa|ps)-worker .* ok$' "$PILOT" >/dev/null; then bad "pilot still passes the literal 'ok' as the quota"; else ok "pilot passes no literal 'ok' as the quota"; fi
  [ "$(grep -c 'pool_ceiling_step [wp][as]-worker .*"${_PILOT_QUOTA_STATE:-unknown}"$' "$PILOT")" = "2" ] && ok "both pilot pools pass \${_PILOT_QUOTA_STATE:-unknown}" || bad "pilot pools do not both pass \${_PILOT_QUOTA_STATE:-unknown}"
fi
if [ -r "$GATE" ]; then
  grep -q '^  HR_QSTATE=\$(gate_quota_state)$' "$GATE" && ok "gate probes the quota once, as three states (gate_quota_state)" || bad "gate does not probe gate_quota_state"
  grep -q '_pc_quota="\${HR_QSTATE:-unknown}"' "$GATE" && ok "gate feeds the ceiling the three-state HR_QSTATE (unset -> unknown)" || bad "gate does not feed the ceiling HR_QSTATE (with an unknown default)"
  if grep -qE '_pc_quota=ok|_pc_quota=limited' "$GATE"; then bad "gate re-collapses the quota to ok/limited before the ceiling"; else ok "gate never collapses the quota to ok/limited before the ceiling"; fi
fi

echo "== 10. a lib that FAILS TO LOAD is not 'off' (pre-gate review: switched on + unloadable was silent)"
# The dispatchers' REAL loader (what makes _POOL_CEILING_OK) and REAL note function, extracted from each file and run under
# set -euo pipefail — the strict mode both dispatchers run in — against a good lib, a corrupt one, a missing one and one that
# loads but defines nothing. stderr goes to a file on purpose: a corrupt sibling is a deploy fault and must be LOUD.
printf 'if [ 1 = 1 ]; then\n  echo unterminated\n' > "$TMPROOT/lib.corrupt.sh"
printf ': # loads fine, defines nothing\n' > "$TMPROOT/lib.empty.sh"
: > "$TMPROOT/on.present"
loadcase() { # <loader-extract> <note-extract> <lib-path> <DYNAMIC: 0|1|UNSET> <ON-file: path|NONE> -> OK=.. / SURVIVED / NOTE=.. on stdout; stderr -> $TMPROOT/load.err
  bash -c '
    set -euo pipefail
    [ "$4" = UNSET ] && unset POOL_CEILING_DYNAMIC || export POOL_CEILING_DYNAMIC="$4"
    export POOL_CEILING_LIB="$3" POOL_CEILING_ON_FILE="$5"
    unset GC_CITY
    eval "$1"; eval "$2"
    echo "OK=$_POOL_CEILING_OK"
    echo "SURVIVED"
    echo "NOTE=$(_pool_ceiling_lib_failed_note)"
  ' _ "$1" "$2" "$3" "$4" "$5" 2>"$TMPROOT/load.err"
}
for who in PILOT GATE; do
  if [ "$who" = PILOT ]; then F="$PILOT"; else F="$GATE"; fi
  LX="$(sed -n '/SELFTEST-EXTRACT pool-ceiling-loader: BEGIN/,/SELFTEST-EXTRACT pool-ceiling-loader: END/p' "$F" 2>/dev/null)"
  NX="$(sed -n '/SELFTEST-EXTRACT pool-ceiling-note: BEGIN/,/SELFTEST-EXTRACT pool-ceiling-note: END/p' "$F" 2>/dev/null)"
  nm="$(printf '%s' "$who" | tr 'A-Z' 'a-z')"
  if [ -z "$LX" ] || [ -z "$NX" ]; then bad "$nm: missing SELFTEST-EXTRACT pool-ceiling-loader / pool-ceiling-note (loader ${#LX}B, note ${#NX}B)"; continue; fi
  out="$(loadcase "$LX" "$NX" "$LIB" 1 NONE)"
  has "$out" "OK=1" "$nm: a good lib loads (_POOL_CEILING_OK=1)"
  eq "${out##*NOTE=}" "" "$nm: ...and says nothing"
  out="$(loadcase "$LX" "$NX" "$TMPROOT/lib.corrupt.sh" 1 NONE)"
  has "$out" "SURVIVED" "$nm: a CORRUPT lib does not kill the dispatcher under set -euo pipefail"
  has "$out" "OK=0" "$nm: a corrupt lib -> _POOL_CEILING_OK=0 (fixed caps)"
  has "$out" "NOTE=pool-ceiling: LIGADO" "$nm: switched ON + corrupt lib -> the note says so (was silent)"
  has "$out" "teto FIXO" "$nm: ...and that the fixed ceiling is what applies"
  has "$out" "nao carregou" "$nm: ...and why (the lib did not load, as opposed to missing)"
  if [ -s "$TMPROOT/load.err" ]; then ok "$nm: the syntax error is on stderr, not suppressed ($(head -c 70 "$TMPROOT/load.err" | tr '\n' ' '))"; else bad "$nm: a corrupt lib printed nothing on stderr (the load error is being swallowed)"; fi
  out="$(loadcase "$LX" "$NX" "$TMPROOT/does-not-exist.sh" 1 NONE)"
  has "$out" "SURVIVED" "$nm: a MISSING lib does not kill the dispatcher either"
  has "$out" "ausente ou ilegivel" "$nm: switched ON + missing lib -> the note says it is missing/unreadable"
  out="$(loadcase "$LX" "$NX" "$TMPROOT/lib.empty.sh" 1 NONE)"
  has "$out" "OK=0" "$nm: a lib that loads but defines no pool_ceiling_step is NOT 'ok'"
  has "$out" "NOTE=pool-ceiling: LIGADO" "$nm: ...and is reported"
  out="$(loadcase "$LX" "$NX" "$TMPROOT/lib.corrupt.sh" UNSET NONE)"
  eq "${out##*NOTE=}" "" "$nm: corrupt lib but the ceiling is NOT switched on -> silent (nothing was asked for)"
  out="$(loadcase "$LX" "$NX" "$TMPROOT/lib.corrupt.sh" UNSET "$TMPROOT/on.present")"
  has "$out" "NOTE=pool-ceiling: LIGADO" "$nm: switched on by the .on file (not the env) + corrupt lib -> reported"
  out="$(loadcase "$LX" "$NX" "$TMPROOT/lib.corrupt.sh" 0 "$TMPROOT/on.present")"
  eq "${out##*NOTE=}" "" "$nm: POOL_CEILING_DYNAMIC=0 is a hard off even with the .on file -> silent"
  # the default lib path must survive a failing cd (set -e): empty dirname -> a path that does not exist, never an abort
  out="$(bash -c 'set -euo pipefail; unset POOL_CEILING_LIB GC_CITY; export POOL_CEILING_DYNAMIC=1; cd() { return 1; }; eval "$1"; eval "$2"; echo "OK=$_POOL_CEILING_OK SURVIVED"; echo "NOTE=$(_pool_ceiling_lib_failed_note)"' _ "$LX" "$NX" 2>/dev/null)"
  has "$out" "SURVIVED" "$nm: even a failing cd while locating the lib does not abort the dispatcher (set -e)"
done

echo "== 10b. a queue file stamped in the FUTURE is unreadable, not 'fresh' (clock skew must not be trusted)"
iso_at() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
mkqf() { printf '{"generated_at":"%s","ttl_seconds":1800,"items":[{"id":"w1","store":"whatsapp_automation"},{"id":"w2","store":"whatsapp_automation"}]}' "$1" > "$TMPROOT/qf.json"; echo "$TMPROOT/qf.json"; }
NOWE="$(date +%s)"
eq "$(pool_ceiling_queue_from_dispatchable "$(mkqf "$(iso_at $((NOWE + 3600)))")" whatsapp_automation)" "" "an emit stamped an hour in the future -> unreadable (empty)"
eq "$(pool_ceiling_queue_from_dispatchable "$(mkqf "$(iso_at $((NOWE + 20)))")" whatsapp_automation)" "2" "20s of skew is tolerated (the emit and this read are on the same host)"
eq "$(pool_ceiling_queue_from_dispatchable "$(mkqf "$(iso_at $((NOWE - 60)))")" whatsapp_automation)" "2" "control: a normal recent emit still counts"

echo "== 10c. 'status' says whether the ceiling is APPLYING or only in shadow"
st="$(POOL_CEILING_STATE_DIR="$TMPROOT/st.status" POOL_CEILING_SHADOW=1 pool_ceiling_status 2>&1 | head -1)"
has "$st" "modo: SOMBRA" "shadow on -> 'modo: SOMBRA (decide e loga, NAO aplica)'"
st="$(POOL_CEILING_STATE_DIR="$TMPROOT/st.status" POOL_CEILING_SHADOW=0 pool_ceiling_status 2>&1 | head -1)"
has "$st" "modo: APLICANDO" "shadow off -> 'modo: APLICANDO'"

echo "== 11. hermetic: this run did not touch the real city's calibration log or state dir"
eq "$(prod_snapshot)" "$PROD_BEFORE" "production pool-ceiling.log / pool-ceiling/ unchanged by the whole run (before: $PROD_BEFORE)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
