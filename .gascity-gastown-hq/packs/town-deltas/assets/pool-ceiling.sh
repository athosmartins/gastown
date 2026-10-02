#!/usr/bin/env bash
# pool-ceiling.sh (ga-uywvsc) — DYNAMIC per-pool session ceiling.
#
# WHY. The session ceiling of each elastic pool was a number typed into a plist
# (PILOT_WA_WORKER_MAX=2, PILOT_PS_WORKER_MAX=1, GATE_MAX_REVIEWERS=6) and
# re-typed by hand after every incident. Measured 2026-10-01: wa-worker pinned at 2
# with 69 beads ready (the oldest ~3 days) while nothing said the machine could not
# take a third. Athos: "esse teto ser hardcoded em 2? ... calculado dinamicamente
# com base nos parametros que dizem se o sistema esta precisando / podendo ter mais
# ou menos workers? idem pra gate reviewers."
#
# WHAT. Each dispatcher sweep calls pool_ceiling_step once per pool. The ceiling
# moves AT MOST ONE step per call, inside [min, max] — where max is NEVER above the
# engine's own cap for the pool (agents/<pool>/agent.toml, see pool_ceiling_engine_cap):
#   up    1  when there is a queue, the pool is saturated at its ceiling (live >=
#            ceiling) and EVERY slack signal is "grow";
#   down  1  when any signal SQUEEZES (hard resource limit) — only the ceiling
#            drops: sessions already open are never killed, the pool just stops
#            OPENING new ones;
#   hold     otherwise — including when nothing is queued: a ceiling that decays on an
#            empty queue only costs throughput (the Pilot sweeps ~every 20 min, so regaining
#            a step takes a sweep) and, inside the engine cap, buys no burst protection.
# THREE STATES everywhere: found / not-found / could-not-find-out. An unreadable
# signal, queue or live count NEVER raises the ceiling (it is not "infinite
# slack"); an unreadable queue is not "queue 0" either (its own reason, never "idle").
# The Claude quota is a signal like the others: the dispatchers pass it as ok | limited |
# unknown (a checker that is absent, errored or timed out is "unknown", never "ok"), and
# only "ok" lets the ceiling grow. An unparseable threshold knob (env) falls back to its
# default instead of silently reading as "not squeezed".
#
# STATE. One file per pool, $GC_CITY/.gc/pool-ceiling/<pool>.state (ceiling=, at=),
# written atomically. A missing/corrupt file re-initialises at the FIXED ceiling the
# caller passes (clamped to the engine cap), so day one is today's behaviour.
# Every evaluated step is also appended to $GC_CITY/.gc/logs/pool-ceiling.log —
# the series for the 24h measurement (ceiling x load x swap x disk).
#
# OPT-IN + KILL SWITCH — all instant, none needs a plist edit or a launchd bootout:
#   enable   touch $GC_CITY/.gc/pool-ceiling.on        (or POOL_CEILING_DYNAMIC=1 in the plist)
#   disable  touch $GC_CITY/.gc/pool-ceiling.off       -> the fixed ceiling, nothing read/written
#   shadow   touch $GC_CITY/.gc/pool-ceiling.shadow    -> decide + persist (<pool>.shadow.state) + LOG
#            every step, but the caller keeps its FIXED ceiling (applied=0 in the TSV). Run it
#            first: the thresholds below are uncalibrated and the box is at load 70-88/10 cores.
#   (POOL_CEILING_DYNAMIC=0 is a hard off that even the .on file does not override)
# Inert until enabled: merged != live, and a ceiling that moves on a machine already at load
# 69/10 cores is switched on deliberately, not by a merge. While off the dispatchers see
# exactly their fixed caps and this lib is silent (no log line, no state).
#
# SIGNAL THRESHOLDS are first estimates (env-overridable) — the log above exists to
# calibrate them. What is NOT a guess: the disk floors are the dolt-disk-floor-guard's
# own (DOLT_DISK_FLOOR_WARN_GB=8 / _CRITICAL_GB=3), and "low swap only squeezes when
# swap cannot grow" is ga-q4fkxa (macOS creates swapfiles on demand).
#
# SCOPE — a BRAKE inside the engine's cap, not a raise above it. This moves the DISPATCHER-side
# caps (pilot-dispatcher.sh: wa-worker, ps-worker; quality-gate-dispatcher.sh: gate-reviewer's
# GATE_MAX_REVIEWERS). The CONTROLLER enforces agent.toml's max_active_sessions on its own
# (ga-o3o09z), so a dispatcher-side value above it would be a lie and is clamped away; making
# the engine's cap follow the dynamic ceiling is a separate mechanism (follow-up bead).
# The city-wide GC_VARIABLE_SESSION_MAX (Athos-decided, 9) stays a fixed outer bound over all
# three. NOT covered: gastown.dog and refino-gate-reviewer — they only have an engine cap and
# do not go through these two dispatchers; auto-refiner runs under a single-instance lock.
#
# Sourceable: defines functions only, no side effects, never `exit`s, every function
# returns 0 (the dispatchers may run under `set -e`). Executable: `pool-ceiling.sh
# status` prints each pool's state and the live signal classification.
# bash 3.2 compatible (macOS /bin/bash): no associative arrays, no ${x,,}.

_pc_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
_pc_num() { case "${1:-}" in ''|.|*[!0-9.]*|*.*.*) return 1 ;; esac; return 0; }

# pool_ceiling_enabled — success iff the dynamic ceiling is switched on. The ONE predicate
# the step and both dispatchers use, so they can never disagree. (A predicate: it returns
# non-zero for "off" by design — call it in an `if`/`||` context, like `[`.)
pool_ceiling_enabled() {
  case "${POOL_CEILING_DYNAMIC:-}" in 0) return 1 ;; 1) return 0 ;; esac
  [ -e "${POOL_CEILING_ON_FILE:-${GC_CITY:-/nonexistent}/.gc/pool-ceiling.on}" ]
}

# pool_ceiling_shadow — success iff SHADOW mode is on (env POOL_CEILING_SHADOW=1 or the file
# $GC_CITY/.gc/pool-ceiling.shadow). Shadow decides, persists (in its own <pool>.shadow.state,
# never the real one) and LOGS every step, but the caller keeps its FIXED ceiling: the calibration
# series with zero behavioural risk. Leaving shadow starts from the fixed ceiling again.
# Limit, by construction: the simulation only sees real sessions, so it can show one step above
# the fixed ceiling ("would raise") but not climb past what `live` lets it. Predicate, like `[`.
pool_ceiling_shadow() {
  [ "${POOL_CEILING_SHADOW:-0}" = "1" ] && return 0
  [ -e "${POOL_CEILING_SHADOW_FILE:-${GC_CITY:-/nonexistent}/.gc/pool-ceiling.shadow}" ]
}

# ── pure decision ─────────────────────────────────────────────────────────────
# pool_ceiling_decide <cur> <min> <max> <live> <queue> [name=class ...]
#   class: grow | hold | squeeze | unknown (anything else counts as unknown)
# prints "<new>|<up|down|hold>|<reason>". Pure; no I/O.
pool_ceiling_decide() {
  local cur="${1:-}" min="${2:-}" max="${3:-}" live="${4:-}" queue="${5:-}"
  [ "$#" -ge 5 ] && shift 5 || shift "$#"
  _pc_int "$min" || min=1
  _pc_int "$max" || max="$min"
  [ "$min" -le "$max" ] || min="$max"
  _pc_int "$cur" || cur="$min"
  [ "$cur" -le "$max" ] || cur="$max"
  [ "$cur" -ge "$min" ] || cur="$min"

  local sq="" unk="" soft="" a nm cl
  for a in "$@"; do
    nm="${a%%=*}"; cl="${a#*=}"
    case "$cl" in
      grow) ;;
      hold) soft="${soft:+$soft,}$nm" ;;
      squeeze) sq="${sq:+$sq,}$nm" ;;
      *) unk="${unk:+$unk,}$nm" ;;
    esac
  done

  if [ -n "$sq" ]; then
    if [ "$cur" -gt "$min" ]; then echo "$((cur - 1))|down|squeeze:$sq"; else echo "$cur|hold|squeeze:$sq(at-min)"; fi
    return 0
  fi
  if ! _pc_int "$queue"; then echo "$cur|hold|unreadable:queue"; return 0; fi
  if [ "$queue" -eq 0 ]; then
    echo "$cur|hold|idle"
    return 0
  fi
  if ! _pc_int "$live"; then echo "$cur|hold|unreadable:live"; return 0; fi
  if [ -n "$unk" ]; then echo "$cur|hold|unreadable:$unk"; return 0; fi
  if [ -n "$soft" ]; then echo "$cur|hold|soft:$soft"; return 0; fi
  if [ "$live" -lt "$cur" ]; then echo "$cur|hold|not-saturated"; return 0; fi
  if [ "$cur" -ge "$max" ]; then echo "$cur|hold|at-max"; return 0; fi
  echo "$((cur + 1))|up|queue+slack"
  return 0
}

# ── signal classifiers (pure) ─────────────────────────────────────────────────
# load5 per core: grow <= GROW, squeeze >= SQUEEZE, hold between. Measured 01/10:
# 6.9/core with the machine saturated but working; 19/09 notes: 5.6-6.4/core.
pool_ceiling_class_load() {
  local l="${1:-}" n="${2:-}" g="${POOL_CEILING_LOAD_GROW_PER_CORE:-5.0}" s="${POOL_CEILING_LOAD_SQUEEZE_PER_CORE:-8.0}"
  if ! _pc_num "$l" || ! _pc_int "$n" || [ "$n" -le 0 ]; then echo unknown; return 0; fi
  _pc_num "$g" || g=5.0   # a non-numeric -v is a STRING to awk, so "r <= g" turns lexical ("6.2" <= "banana" is true -> grow)
  _pc_num "$s" || s=8.0
  awk -v l="$l" -v n="$n" -v g="$g" -v s="$s" \
    'BEGIN { r = l / n; if (r >= s) print "squeeze"; else if (r <= g) print "grow"; else print "hold" }'
  return 0
}

# kernel memory-pressure level (kern.memorystatus_vm_pressure_level): 1 normal,
# 2 warn, 4 critical. 2 only holds: it was the state DURING the 25/09 incident that
# cleared on its own (ga-q4fkxa); only 4 is the kernel saying "critical".
pool_ceiling_class_mem() {
  case "${1:-}" in 1) echo grow ;; 2) echo hold ;; 4) echo squeeze ;; *) echo unknown ;; esac
  return 0
}

# swap: <swap_free_mb> <swap_used_mb> <disk_free_mb>. Low free swap squeezes ONLY
# when swap cannot grow (disk under SWAP_GROW_DISK_MIN) — ga-q4fkxa: macOS creates
# the next swapfile on demand, so a low reading is normal right before it grows.
pool_ceiling_class_swap() {
  local f="${1:-}" u="${2:-}" d="${3:-}"
  local floor="${POOL_CEILING_SWAP_FREE_FLOOR_MB:-512}" dmin="${POOL_CEILING_SWAP_GROW_DISK_MIN_MB:-4096}" umax="${POOL_CEILING_SWAP_GROW_MAX_USED_MB:-4096}"
  _pc_int "$floor" || floor=512   # a garbage knob must not turn "[ -lt ]" into an error that reads as "not low"
  _pc_int "$dmin" || dmin=4096
  _pc_int "$umax" || umax=4096
  if ! _pc_int "$f" || ! _pc_int "$u"; then echo unknown; return 0; fi
  if [ "$f" -lt "$floor" ]; then
    if ! _pc_int "$d"; then echo unknown; return 0; fi
    if [ "$d" -lt "$dmin" ]; then echo squeeze; return 0; fi
    echo hold; return 0
  fi
  if [ "$u" -gt "$umax" ]; then echo hold; return 0; fi
  echo grow
  return 0
}

# disk free MB on the city volume, against the dolt-disk-floor-guard's own floors:
# squeeze below CRITICAL (3 GB), hold below WARN (8 GB) + a margin (4 GB), else grow.
pool_ceiling_class_disk() {
  local d="${1:-}" crit warn margin
  if ! _pc_int "$d"; then echo unknown; return 0; fi
  crit="${DOLT_DISK_FLOOR_CRITICAL_GB:-3}"; warn="${DOLT_DISK_FLOOR_WARN_GB:-8}"; margin="${POOL_CEILING_DISK_GROW_MARGIN_GB:-4}"
  _pc_int "$crit" || crit=3; _pc_int "$warn" || warn=8; _pc_int "$margin" || margin=4
  if [ "$d" -lt $((crit * 1024)) ]; then echo squeeze; return 0; fi
  if [ "$d" -lt $(((warn + margin) * 1024)) ]; then echo hold; return 0; fi
  echo grow
  return 0
}

# Dolt: the dispatchers already throttle on it with their own ladders, so it only
# HOLDS here (no growth into a hot data plane), it does not shrink the pool.
pool_ceiling_class_dolt() {
  case "${1:-}" in ok) echo grow ;; hot) echo hold ;; *) echo unknown ;; esac
  return 0
}

# pool_ceiling_dolt_class <cpu%> <latency_ms> <cpu_hot> <lat_hot_ms> — ok | hot | unknown,
# for a dispatcher that already took its own Dolt readings (no second probe). Only a
# POSITIVELY measured reading over its ceiling is "hot"; both readings empty is "unknown",
# never "ok" (not-found != found-and-fine).
pool_ceiling_dolt_class() {
  local cpu="${1:-}" lat="${2:-}" cpu_hot="${3:-}" lat_hot="${4:-}"
  _pc_int "$cpu_hot" || cpu_hot=180
  _pc_int "$lat_hot" || lat_hot=2500
  _pc_int "$cpu" || cpu=""
  _pc_int "$lat" || lat=""
  if [ -z "$cpu" ] && [ -z "$lat" ]; then echo unknown; return 0; fi
  if { [ -n "$cpu" ] && [ "$cpu" -gt "$cpu_hot" ]; } || { [ -n "$lat" ] && [ "$lat" -gt "$lat_hot" ]; }; then echo hot; return 0; fi
  echo ok
  return 0
}

# Quota: limited holds (the window resets; shrinking would only slow the recovery).
pool_ceiling_class_quota() {
  case "${1:-}" in ok) echo grow ;; limited) echo hold ;; *) echo unknown ;; esac
  return 0
}

# ── readers: an integer/decimal, or EMPTY when it could not be read ───────────
# Test seam: POOL_CEILING_T_<SIGNAL> set (even to empty) replaces the live read.
pool_ceiling_read_load5() {
  if [ -n "${POOL_CEILING_T_LOAD5+x}" ]; then printf '%s' "$POOL_CEILING_T_LOAD5"; return 0; fi
  local v
  v=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $3}') || v=""
  _pc_num "$v" && printf '%s' "$v"
  return 0
}
pool_ceiling_read_ncpu() {
  if [ -n "${POOL_CEILING_T_NCPU+x}" ]; then printf '%s' "$POOL_CEILING_T_NCPU"; return 0; fi
  local v
  v=$(sysctl -n hw.ncpu 2>/dev/null) || v=""
  _pc_int "$v" && printf '%s' "$v"
  return 0
}
pool_ceiling_read_mem_pressure() {
  if [ -n "${POOL_CEILING_T_MEM+x}" ]; then printf '%s' "$POOL_CEILING_T_MEM"; return 0; fi
  local v
  v=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null) || v=""
  _pc_int "$v" && printf '%s' "$v"
  return 0
}
_pc_swap_field() { # <free|used> → integer MB from `vm.swapusage`, empty if unparseable
  local v
  v=$(sysctl -n vm.swapusage 2>/dev/null | sed -n "s/.*$1 *= *\\([0-9.]*\\)M.*/\\1/p") || v=""
  [ -n "$v" ] || return 0
  awk -v v="$v" 'BEGIN { printf "%d", v }' 2>/dev/null
  return 0
}
pool_ceiling_read_swap_free_mb() {
  if [ -n "${POOL_CEILING_T_SWAP_FREE_MB+x}" ]; then printf '%s' "$POOL_CEILING_T_SWAP_FREE_MB"; return 0; fi
  _pc_swap_field free
  return 0
}
pool_ceiling_read_swap_used_mb() {
  if [ -n "${POOL_CEILING_T_SWAP_USED_MB+x}" ]; then printf '%s' "$POOL_CEILING_T_SWAP_USED_MB"; return 0; fi
  _pc_swap_field used
  return 0
}
pool_ceiling_read_disk_free_mb() {
  if [ -n "${POOL_CEILING_T_DISK_FREE_MB+x}" ]; then printf '%s' "$POOL_CEILING_T_DISK_FREE_MB"; return 0; fi
  local kb
  kb=$(df -k "${POOL_CEILING_DISK_PATH:-${GC_CITY:-/}}" 2>/dev/null | awk 'NR==2 {print $4}') || kb=""
  _pc_int "$kb" || return 0
  printf '%d' $((kb / 1024))
  return 0
}

# pool_ceiling_queue_from_dispatchable <file> <store> [now_epoch]
# The Pilot already emits its full eligible queue every sweep (PILOT_DISPATCHABLE_FILE,
# wa-u5r1): count the items of the pool's rig store. Prints the count, or NOTHING when
# the file is missing / corrupt / older than its own ttl_seconds — an unreadable queue
# must never read as an empty one. What this reader CANNOT see is a store the emit itself
# failed to read: the emit writes a fresh file with 0 items for it (its `|| echo "[]"`), which
# reads here as a real "queue 0" (reason `idle`: holds, never raises — inert, but not labelled
# "unreadable"). docs/pool-ceiling-dynamic.md, "Fonte da fila", states the same limit.
pool_ceiling_queue_from_dispatchable() {
  local f="${1:-}" store="${2:-}" now="${3:-}" out=""
  [ -r "$f" ] || return 0
  _pc_int "$now" || now=$(date +%s 2>/dev/null) || now=""
  _pc_int "$now" || return 0
  out=$(jq -r --arg s "$store" --argjson now "$now" '
      if ((.generated_at | type) == "string") and ((.items | type) == "array") then
        ((.ttl_seconds // 1800) as $ttl | (.generated_at | fromdateiso8601) as $g
         | if ($now - $g) > $ttl or ($now - $g) < -60 then empty   # too old, or stamped in the FUTURE (clock skew): cannot be trusted as fresh
           else ([.items[] | select(.store == $s)] | length) end)
      else empty end' "$f" 2>/dev/null) || out=""
  _pc_int "$out" && printf '%s' "$out"
  return 0
}

# pool_ceiling_engine_cap <pool> — max_active_sessions from agents/<pool>/agent.toml, or
# NOTHING when unreadable. This is the cap the CONTROLLER itself enforces: on 2026-09-25 it
# spawned wa-workers up to agent.toml's 4 while the Pilot's own cap said 2 (ga-o3o09z; the Mayor
# then made agent.toml the single source of truth). A dispatcher-side ceiling above it is a
# lie, so the step clamps its max to this value.
pool_ceiling_engine_cap() {
  local pool="${1:-}" dir f v
  dir="${POOL_CEILING_AGENTS_DIR:-${GC_CITY:+$GC_CITY/agents}}"
  [ -n "$dir" ] && [ -n "$pool" ] || return 0
  f="$dir/$pool/agent.toml"
  [ -r "$f" ] || return 0
  v=$(sed -n 's/^max_active_sessions[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\(#.*\)\{0,1\}$/\1/p' "$f" 2>/dev/null | head -1) || v=""
  _pc_int "$v" && printf '%s' "$v"
  return 0
}

# pool_ceiling_bounds <pool> [min_floor] — sets POOL_CEILING_MIN / POOL_CEILING_MAX for the pool
# (env: POOL_CEILING_<POOL>_MIN / _MAX, pool upper-cased, '-' -> '_'). Defaults:
# wa-worker 1..4 (4 = Athos' 19/09 decision "WA 4"), ps-worker 1..2, gate-reviewer 2..6
# [min_floor] raises the min (and the max with it, if needed): the gate passes its
# reviewers-per-run so that one run always fits under the ceiling.
pool_ceiling_bounds() {
  local pool="${1:-}" floor="${2:-}" up dmin dmax vmin vmax
  up=$(printf '%s' "$pool" | tr 'a-z-' 'A-Z_')
  case "$pool" in
    wa-worker) dmin=1; dmax=4 ;;
    ps-worker) dmin=1; dmax=2 ;;
    gate-reviewer) dmin=2; dmax=6 ;;
    *) dmin=1; dmax=1 ;;
  esac
  vmin="POOL_CEILING_${up}_MIN"; vmax="POOL_CEILING_${up}_MAX"
  POOL_CEILING_MIN="${!vmin:-$dmin}"; POOL_CEILING_MAX="${!vmax:-$dmax}"
  _pc_int "$POOL_CEILING_MIN" || POOL_CEILING_MIN="$dmin"
  _pc_int "$POOL_CEILING_MAX" || POOL_CEILING_MAX="$dmax"
  if _pc_int "$floor" && [ "$POOL_CEILING_MIN" -lt "$floor" ]; then POOL_CEILING_MIN="$floor"; fi
  [ "$POOL_CEILING_MAX" -ge "$POOL_CEILING_MIN" ] || POOL_CEILING_MAX="$POOL_CEILING_MIN"
  return 0
}

# ── stateful step ─────────────────────────────────────────────────────────────
# pool_ceiling_step <pool> <fixed> <min> <max> <live> <queue> [dolt: ok|hot|unknown] [quota: ok|limited|unknown]
# Sets POOL_CEILING_RESULT (the ceiling the caller must use; an integer, or empty only
# when <fixed> itself was garbage — the caller then keeps its own value) and
# POOL_CEILING_LOGLINE (one human line). Out-params, NEVER call via $(...): the
# dispatchers read the globals in their own shell. Never fails, never exits.
# shellcheck disable=SC2034  # POOL_CEILING_RESULT / POOL_CEILING_LOGLINE are out-params read by the callers
pool_ceiling_step() {
  local pool="${1:-}" fixed="${2:-}" min="${3:-}" max="${4:-}" live="${5:-}" queue="${6:-}" dolt="${7:-unknown}" quota="${8:-unknown}"
  POOL_CEILING_RESULT=""; POOL_CEILING_LOGLINE=""
  _pc_int "$fixed" && POOL_CEILING_RESULT="$fixed"

  # Not enabled: silent, the dispatcher keeps its fixed cap untouched.
  pool_ceiling_enabled || return 0
  if [ -e "${POOL_CEILING_KILL_FILE:-${GC_CITY:-/nonexistent}/.gc/pool-ceiling.off}" ]; then
    POOL_CEILING_LOGLINE="pool-ceiling: $pool kill file presente (pool-ceiling.off) — teto fixo ${fixed:-?} (ga-uywvsc)"
    return 0
  fi
  if ! _pc_int "$fixed"; then
    POOL_CEILING_LOGLINE="pool-ceiling: $pool teto fixo ilegivel ('${fixed}') — nada alterado (ga-uywvsc)"
    return 0
  fi
  _pc_int "$min" || min=1
  _pc_int "$max" || max="$min"
  [ "$min" -le "$max" ] || min="$max"
  # Never above what the controller itself will admit. Engine cap unreadable -> never above
  # the known-good fixed value (not-found is not "no limit").
  local ec
  ec=$(pool_ceiling_engine_cap "$pool")
  if _pc_int "$ec"; then [ "$max" -le "$ec" ] || max="$ec"; else [ "$max" -le "$fixed" ] || max="$fixed"; fi
  [ "$min" -le "$max" ] || min="$max"

  local now sd sf dry="${POOL_CEILING_DRY:-0}"
  now="${POOL_CEILING_NOW:-}"; _pc_int "$now" || now=$(date +%s 2>/dev/null) || now=""
  # No readable clock = no way to rate-limit or to stamp a step. "Unknown" must not become epoch 0
  # (which would silently drop the rate limit): do nothing, and say so.
  if ! _pc_int "$now" || [ "$now" -le 0 ]; then
    POOL_CEILING_LOGLINE="pool-ceiling: $pool relogio ilegivel — sem como limitar o ritmo, teto fixo $fixed (ga-uywvsc)"
    return 0
  fi
  sd="${POOL_CEILING_STATE_DIR:-${GC_CITY:+$GC_CITY/.gc/pool-ceiling}}"
  if [ -z "$sd" ]; then
    POOL_CEILING_LOGLINE="pool-ceiling: $pool sem diretorio de estado (GC_CITY vazio) — teto fixo $fixed (ga-uywvsc)"
    return 0
  fi
  local shadow=0
  pool_ceiling_shadow && shadow=1
  sf="$sd/$pool.state"
  [ "$shadow" = "1" ] && sf="$sd/$pool.shadow.state"
  if [ "$dry" != "1" ] && { ! mkdir -p "$sd" 2>/dev/null || [ ! -w "$sd" ]; }; then
    POOL_CEILING_LOGLINE="pool-ceiling: $pool estado nao gravavel em $sd — sem como persistir a rampa, teto fixo $fixed (ga-uywvsc)"
    return 0
  fi

  local cur="" at="" c a snote=""
  if [ -e "$sf" ]; then
    if [ -r "$sf" ]; then
      c=$(sed -n 's/^ceiling=//p' "$sf" 2>/dev/null | head -1) || c=""
      a=$(sed -n 's/^at=//p' "$sf" 2>/dev/null | head -1) || a=""
      if _pc_int "$c" && _pc_int "$a"; then cur="$c"; at="$a"; fi
    fi
    # present but unusable (corrupt, or unreadable): restarting at the fixed value is the safe
    # direction, but it must be VISIBLE, never a silent reset.
    [ -n "$cur" ] || snote=" [estado corrompido ou ilegivel em $sf: reiniciado no teto fixo $fixed]"
  fi
  [ -n "$cur" ] || { cur="$fixed"; at=0; }
  [ "$cur" -le "$max" ] || cur="$max"
  [ "$cur" -ge "$min" ] || cur="$min"
  # a stamp in the FUTURE (clock jump) must not become a permanent rate limit
  [ "$at" -le "$now" ] || at=0

  local step="${POOL_CEILING_STEP_SECS:-60}"; _pc_int "$step" || step=60
  if [ "$at" -gt 0 ] && [ $((now - at)) -lt "$step" ]; then
    POOL_CEILING_RESULT="$cur"
    [ "$shadow" != "1" ] || POOL_CEILING_RESULT="$fixed"
    POOL_CEILING_LOGLINE="pool-ceiling: $pool teto $cur mantido (ritmo: ultimo passo ha $((now - at))s < ${step}s; fila ${queue:-?}, vivos ${live:-?}) (ga-uywvsc)"
    # in shadow $cur is the SIMULATED ceiling and what applies is the fixed one: label it like every other shadow line,
    # or a reader calibrating from the log (a gate multi-admit re-exec lands here within 60s) takes the simulation for real
    [ "$shadow" != "1" ] || POOL_CEILING_LOGLINE="pool-ceiling [sombra: NAO aplicado, fica o fixo $fixed]${POOL_CEILING_LOGLINE#pool-ceiling:}"
    return 0
  fi

  local load5 ncpu mem sfree sused dfree
  load5=$(pool_ceiling_read_load5); ncpu=$(pool_ceiling_read_ncpu); mem=$(pool_ceiling_read_mem_pressure)
  sfree=$(pool_ceiling_read_swap_free_mb); sused=$(pool_ceiling_read_swap_used_mb); dfree=$(pool_ceiling_read_disk_free_mb)
  local c_load c_mem c_swap c_disk c_dolt c_quota
  c_load=$(pool_ceiling_class_load "$load5" "$ncpu"); c_mem=$(pool_ceiling_class_mem "$mem")
  c_swap=$(pool_ceiling_class_swap "$sfree" "$sused" "$dfree"); c_disk=$(pool_ceiling_class_disk "$dfree")
  c_dolt=$(pool_ceiling_class_dolt "$dolt"); c_quota=$(pool_ceiling_class_quota "$quota")

  local d new action reason
  d=$(pool_ceiling_decide "$cur" "$min" "$max" "$live" "$queue" \
        load="$c_load" mem="$c_mem" swap="$c_swap" disk="$c_disk" dolt="$c_dolt" quota="$c_quota")
  new="${d%%|*}"; d="${d#*|}"; action="${d%%|*}"; reason="${d#*|}"
  _pc_int "$new" || { new="$cur"; action=hold; reason="decisao-ilegivel"; }

  local gb="?"
  _pc_int "$dfree" && gb=$(awk -v m="$dfree" 'BEGIN { printf "%.1f", m / 1024 }')
  local trans="$pool $new ($action, $reason)"
  [ "$new" != "$cur" ] && trans="$pool $cur→$new ($action, $reason)"
  local line="pool-ceiling: $trans: fila ${queue:-?}, vivos ${live:-?}/$cur, load5 ${load5:-?}/${ncpu:-?}c [$c_load], mem ${mem:-?} [$c_mem], swap usado ${sused:-?}MB livre ${sfree:-?}MB [$c_swap], disco ${gb}GB [$c_disk], dolt $dolt [$c_dolt], cota $quota [$c_quota] (fixo $fixed, faixa $min..$max, motor ${ec:-?})${snote} (ga-uywvsc)"

  if [ "$dry" != "1" ]; then
    local tmp="$sf.tmp.$$"
    if printf 'ceiling=%s\nat=%s\n' "$new" "$now" > "$tmp" 2>/dev/null && mv -f "$tmp" "$sf" 2>/dev/null; then
      _pc_log_append "$now" "$pool" "$fixed" "$cur" "$new" "$action" "$reason" "$queue" "$live" "$load5" "$ncpu" "$mem" "$sused" "$sfree" "$dfree" "$dolt" "$quota" "$([ "$shadow" = "1" ] && echo 0 || echo 1)"
    else
      rm -f "$tmp" 2>/dev/null
      POOL_CEILING_LOGLINE="pool-ceiling: $pool estado nao persistiu em $sf — teto fixo $fixed (ga-uywvsc)"
      return 0
    fi
  fi
  POOL_CEILING_RESULT="$new"
  POOL_CEILING_LOGLINE="$line"
  if [ "$shadow" = "1" ]; then
    POOL_CEILING_RESULT="$fixed"
    POOL_CEILING_LOGLINE="pool-ceiling [sombra: NAO aplicado, fica o fixo $fixed]${line#pool-ceiling:}"
  fi
  return 0
}

# One TSV line per evaluated step, for the 24h calibration series. Capped at ~5 MB (one
# rotated generation). Best-effort: a failed append never changes the decision.
_pc_log_append() {
  local lf="${POOL_CEILING_LOG:-${GC_CITY:+$GC_CITY/.gc/logs/pool-ceiling.log}}"
  [ -n "$lf" ] || return 0
  mkdir -p "$(dirname "$lf")" 2>/dev/null || return 0
  if [ -f "$lf" ] && [ "$(wc -c < "$lf" 2>/dev/null || echo 0)" -gt 5242880 ]; then mv -f "$lf" "$lf.1" 2>/dev/null || true; fi
  {
    printf 'ts=%s' "$1"; shift
    printf '\tpool=%s\tfixed=%s\tcur=%s\tnew=%s\taction=%s\treason=%s\tqueue=%s\tlive=%s\tload5=%s\tncpu=%s\tmem=%s\tswap_used_mb=%s\tswap_free_mb=%s\tdisk_free_mb=%s\tdolt=%s\tquota=%s\tapplied=%s\n' "$@"
  } >> "$lf" 2>/dev/null || true
  return 0
}

pool_ceiling_status() {
  local sd="${POOL_CEILING_STATE_DIR:-${GC_CITY:+$GC_CITY/.gc/pool-ceiling}}" f n c a
  echo "ligado: $(pool_ceiling_enabled && echo SIM || echo nao)  kill-file: $([ -e "${POOL_CEILING_KILL_FILE:-${GC_CITY:-/nonexistent}/.gc/pool-ceiling.off}" ] && echo PRESENTE || echo ausente)  modo: $(pool_ceiling_shadow && echo 'SOMBRA (decide e loga, NAO aplica)' || echo 'APLICANDO')"
  for f in "$sd"/*.state; do
    [ -r "$f" ] || continue
    n=$(basename "$f" .state); c=$(sed -n 's/^ceiling=//p' "$f"); a=$(sed -n 's/^at=//p' "$f")
    echo "  $n: teto=$c (ultimo passo ha $(( $(date +%s) - ${a:-0} ))s)"
  done
  local l5 nc mm sf su df
  l5=$(pool_ceiling_read_load5); nc=$(pool_ceiling_read_ncpu); mm=$(pool_ceiling_read_mem_pressure)
  sf=$(pool_ceiling_read_swap_free_mb); su=$(pool_ceiling_read_swap_used_mb); df=$(pool_ceiling_read_disk_free_mb)
  echo "sinais agora: load5=${l5:-?}/${nc:-?}c [$(pool_ceiling_class_load "$l5" "$nc")] mem=${mm:-?} [$(pool_ceiling_class_mem "$mm")] swap usado=${su:-?}MB livre=${sf:-?}MB [$(pool_ceiling_class_swap "$sf" "$su" "$df")] disco livre=${df:-?}MB [$(pool_ceiling_class_disk "$df")]"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  GC_CITY="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
  case "${1:-status}" in
    status) pool_ceiling_status ;;
    *) echo "uso: pool-ceiling.sh status" >&2 ;;
  esac
fi
