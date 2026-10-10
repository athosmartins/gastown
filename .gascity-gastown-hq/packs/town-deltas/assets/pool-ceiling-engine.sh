#!/usr/bin/env bash
# pool-ceiling-engine.sh (ga-m9x0lb.2) — makes the CONTROLLER's pool ceiling (agents/<pool>/agent.toml:
# max_active_sessions) follow the Athos rule, WITHOUT rewriting any tracked file.
#
# WHY. pool-ceiling.sh (ga-uywvsc) only brakes inside the engine's cap. The case that started it all —
# wa-worker pinned at 2 with 69 beads ready — needs the cap itself to move, and the controller enforces
# agent.toml on its own (ga-o3o09z). Rewriting agent.toml / city.toml is the wrong tool (ga-m9x0lb): the
# town-root-reconciler treats a dirty tracked file as a conflict, and `gc agent suspend/resume` re-encodes
# the whole file (ga-gdjav). Mayor's decision 09/10 (ga-m9x0lb): ONE generated, UNTRACKED fragment under .gc/
# with [[patches.agent]] blocks, included once by city.toml.
#
# THE FRAGMENT: $GC_CITY/.gc/pool-ceiling-engine.toml. This script is its ONLY writer.
#   - written atomically (tmp + mv), only [[patches.agent]] dir/name/max_active_sessions, only allowlisted pools;
#   - it must ALWAYS EXIST once city.toml includes it: an absent fragment is a config LOAD ERROR (ga-m9x0lb.1,
#     measured: gc config show exit 1). So the kill switch EMPTIES it (comment-only = no override, measured
#     exit 0, config identical to baseline) and nothing here ever deletes it;
#   - the "fixed" value of every pool is `git show HEAD:agents/<pool>/agent.toml`, never the working tree and never
#     a dispatcher's state: deleting the entries restores the committed behaviour completely.
#
# THE RULE (Athos 03/10, relayed by the Mayor 09/10 in ga-m9x0lb):
#   wa-worker  3 by default; 2 when swap used > 6 GB OR free disk < 6 GB; back to 3 only after 2 SWEEPS with
#              swap used <= 6 GB AND free disk >= 9 GB (hysteresis band 6..9 GB: hold).
#   the others (ps-worker, gate-reviewer) only go DOWN from the committed value, on the same pressure, and come back
#              on the same 2-sweep condition. They never go above what is committed.
#   Lowering is immediate (one step per run); raising is 1 step, after 2 counted sweeps, and at most 1 write per
#   10 min per pool. A raise never makes the sum of the ceilings exceed GC_VARIABLE_SESSION_MAX (the dispatchers apply
#   that bound to LIVE sessions only; the controller never does).
#
# THREE STATES, everywhere (not-found != found-and-zero != could-not-find-out): a swap/disk reading that cannot be
# taken NEVER reads as "clear"; a committed value that cannot be read drops that pool's entry; a config that cannot be
# read back after a write is a failed write. Under doubt the state is the INERT one: the fragment empty.
#
# SAFETY NETS (each one proven by a mutant in pool-ceiling-engine.selftest.sh):
#   read-back   after EVERY write: gc config show --json, each entry must resolve to the intended value. A typo'd key is
#               only a WARNING in gc (exit 0, the ceiling silently does not move) — only the read-back catches it.
#               Mismatch/unreadable => the fragment is emptied at once and the engine trips.
#   breaker     at most POOL_CEILING_ENGINE_DAILY_MAX (10) writes per local day; the next non-empty write instead
#               empties the fragment and trips until tomorrow. A read-back MISMATCH trips until a human runs `reset`.
#   lock        one instance at a time (mkdir + heartbeat + TTL); a second run exits silently.
#   include     read from city.toml's PARSED include array (1/0/?). With .on but not a definite 1 nothing is written (it could not
#               apply). With the include 1 or ? and the fragment ABSENT (clean clone / DR) the engine re-creates it EMPTY, even when disabled: that is the
#               one state that would break the next reload, and empty is config-identical to "no engine".
#
# SWITCHES (files under $GC_CITY/.gc, all instant, none needs a plist edit):
#   pool-ceiling-engine.on    the engine acts ONLY with this file. Without it: silent, nothing read, nothing written.
#   pool-ceiling-engine.off   KILL SWITCH: empties the fragment, resets the per-pool state, wins over .on.
#   pool-ceiling-engine.sh plan     evaluate one sweep and PRINT it (no write of any kind; works without .on)
#   pool-ceiling-engine.sh status   switches, include, fragment levels, per-pool state, breaker, budget, signals now
#   pool-ceiling-engine.sh reset    clear a trip + the daily counter (does not touch the fragment)
#   pool-ceiling-engine.sh check    read-only: include present => fragment must exist and be well-formed (exit 1 if not)
#
# NOT here (slice 3, Mayor, supervised): the one-line `include` in city.toml, installing the launchd job, the first .on
# and the kill-switch drill. This file only DECIDES and WRITES the fragment; the drift watcher (compute_hash now covers
# the fragment) applies it with `gc reload --soft`. gastown.dog stays out: eval-window-concurrency-guard owns its
# max_active_sessions in city.toml and the fragment would override it (ga-m9x0lb.1). refino-gate-reviewer and
# auto-refiner stay out while their agents are suspended.
#
# Sourceable (functions only, no side effects, never `exit`s). Executable for the subcommands above (no arg = run).
# bash 3.2 compatible (macOS /bin/bash): no associative arrays, no ${x,,}, no mapfile.

PCE_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

_pce_int() { case "${1:-}" in ''|*[!0-9]*|0?*) return 1 ;; esac; return 0; }   # canonical decimal: "09" is no TOML integer and a bad octal in $(( ))

# _pce_knob <ENV_NAME> <default> [min] — the env value if it is an integer >= min, else the default.
# An unparseable knob falls back to its default instead of silently reading as "not squeezed" (same rule as pool-ceiling.sh).
_pce_knob() {
  local v="${!1:-}" min="${3:-0}"
  if _pce_int "$v" && [ "$v" -ge "$min" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

# map helpers: a map is a space-separated list of key=value (pool names have no spaces).
_pce_map_get() { local e; for e in $1; do case "$e" in "$2="*) printf '%s' "${e#*=}"; return 0 ;; esac; done; return 0; }
_pce_map_set() {
  local e out="" seen=0
  for e in $1; do
    case "$e" in "$2="*) out="$out $2=$3"; seen=1 ;; *) out="$out $e" ;; esac
  done
  [ "$seen" = "1" ] || out="$out $2=$3"
  printf '%s' "${out# }"
}

PCE_HEADER='# GENERATED by packs/town-deltas/assets/pool-ceiling-engine.sh (ga-m9x0lb.2) - do not edit by hand.
# Included by city.toml (include = [".gc/pool-ceiling-engine.toml"]). While that include exists this file MUST exist:
# an absent fragment is a config LOAD ERROR. Kill switch = EMPTY it (touch .gc/pool-ceiling-engine.off), never delete it.
# Empty or comment-only = no override: every pool keeps the max_active_sessions committed in agents/<pool>/agent.toml.'

# pce_init — resolve every path and knob from the environment. Called by each entry point, so merely sourcing this file
# reads no environment and has no side effect. Every knob has a test seam of the same name.
pce_init() {
  PCE_CITY="${POOL_CEILING_ENGINE_CITY:-${GC_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}}"
  GC_CITY="$PCE_CITY"; export GC_CITY   # pool-ceiling.sh's readers resolve the disk path from it
  PCE_FRAGMENT="${POOL_CEILING_ENGINE_FRAGMENT:-$PCE_CITY/.gc/pool-ceiling-engine.toml}"
  PCE_ON_FILE="${POOL_CEILING_ENGINE_ON_FILE:-$PCE_CITY/.gc/pool-ceiling-engine.on}"
  PCE_OFF_FILE="${POOL_CEILING_ENGINE_OFF_FILE:-$PCE_CITY/.gc/pool-ceiling-engine.off}"
  PCE_STATE="${POOL_CEILING_ENGINE_STATE_DIR:-$PCE_CITY/.gc/pool-ceiling-engine}"
  PCE_LOG="${POOL_CEILING_ENGINE_LOG:-$PCE_CITY/.gc/logs/pool-ceiling-engine.log}"
  PCE_CITY_TOML="${POOL_CEILING_ENGINE_CITY_TOML:-$PCE_CITY/city.toml}"
  PCE_LIB="${POOL_CEILING_ENGINE_LIB:-$PCE_SELF_DIR/pool-ceiling.sh}"
  PCE_GC="${POOL_CEILING_ENGINE_GC:-gc}"
  PCE_PY="${POOL_CEILING_ENGINE_PYTHON:-python3}"
  PCE_NOTIFY="${POOL_CEILING_ENGINE_NOTIFY:-notify}"
  PCE_PILOT_PLIST="${POOL_CEILING_ENGINE_PILOT_PLIST:-$HOME/Library/LaunchAgents/com.gascity.pilot.plist}"
  PCE_POOLS="${POOL_CEILING_ENGINE_POOLS:-wa-worker ps-worker gate-reviewer}"
  PCE_SWAP_HIGH_MB=$(_pce_knob POOL_CEILING_ENGINE_SWAP_HIGH_MB 6144 1)
  PCE_DISK_LOW_MB=$(_pce_knob POOL_CEILING_ENGINE_DISK_LOW_MB 6144 1)
  PCE_DISK_CLEAR_MB=$(_pce_knob POOL_CEILING_ENGINE_DISK_CLEAR_MB 9216 1)
  [ "$PCE_DISK_CLEAR_MB" -ge "$PCE_DISK_LOW_MB" ] || PCE_DISK_CLEAR_MB="$PCE_DISK_LOW_MB"
  PCE_CLEAR_SWEEPS=$(_pce_knob POOL_CEILING_ENGINE_CLEAR_SWEEPS 2 1)
  PCE_SWEEP_GAP_SECS=$(_pce_knob POOL_CEILING_ENGINE_SWEEP_GAP_SECS 240 0)
  PCE_RATE_SECS=$(_pce_knob POOL_CEILING_ENGINE_RATE_SECS 600 0)
  PCE_DAILY_MAX=$(_pce_knob POOL_CEILING_ENGINE_DAILY_MAX 10 1)
  PCE_UNKNOWN_RESTORE=$(_pce_knob POOL_CEILING_ENGINE_UNKNOWN_RESTORE_SWEEPS 3 1)
  PCE_LOCK_TTL=$(_pce_knob POOL_CEILING_ENGINE_LOCK_TTL 300 1)
  PCE_READBACK_SECS=$(_pce_knob POOL_CEILING_ENGINE_READBACK_SECS 60 1)
  PCE_BUDGET_FALLBACK=$(_pce_knob POOL_CEILING_ENGINE_BUDGET_FALLBACK 6 1)   # the dispatchers' own default for GC_VARIABLE_SESSION_MAX
  PCE_HARD_MAX=$(_pce_knob POOL_CEILING_ENGINE_HARD_MAX 8 1)                  # no entry above this, whatever a knob says
  PCE_DRY="${POOL_CEILING_ENGINE_DRY:-0}"
  PCE_NOW=""
  PCE_LOCK_DIR="$PCE_STATE/lock.d"; PCE_LOCK_HB="$PCE_LOCK_DIR/heartbeat"
  PCE_LOCK_TOKEN="$$:${RANDOM}${RANDOM}"
  return 0
}

# ── pure decision ─────────────────────────────────────────────────────────────

# pce_pressure <swap_used_mb> <disk_free_mb> — high | clear | band | unknown.
# high    swap used > 6 GB OR free disk < 6 GB. ONE positive reading is enough (an unreadable other signal cannot undo it).
# clear   BOTH readable, swap <= 6 GB and disk >= 9 GB.
# band    both readable, swap fine, disk in [6, 9) GB: the hysteresis band — neither lowers nor raises.
# unknown otherwise: a reading that could not be taken is not "clear".
pce_pressure() {
  local s="${1:-}" d="${2:-}" s_ok=0 d_ok=0
  _pce_int "$s" && s_ok=1
  _pce_int "$d" && d_ok=1
  if [ "$s_ok" = "1" ] && [ "$s" -gt "$PCE_SWAP_HIGH_MB" ]; then echo high; return 0; fi
  if [ "$d_ok" = "1" ] && [ "$d" -lt "$PCE_DISK_LOW_MB" ]; then echo high; return 0; fi
  if [ "$s_ok" = "0" ] || [ "$d_ok" = "0" ]; then echo unknown; return 0; fi
  if [ "$d" -ge "$PCE_DISK_CLEAR_MB" ]; then echo clear; return 0; fi
  echo band
  return 0
}

# pce_decide <committed> <cur> <floor> <ceil> <pressure> <clear_streak> <unknown_streak> <rate_ok 1|0>
# prints "<new>|<action:reason>". Pure; no I/O. One step per call.
pce_decide() {
  local C="$1" L="$2" floor="$3" ceil="$4" p="$5" cs="$6" us="$7" rate_ok="$8"
  case "$p" in
    high)
      if [ "$L" -gt "$floor" ]; then echo "$((L - 1))|lower:pressure"; else echo "$L|hold:at-floor"; fi ;;
    unknown)
      # blind for too long while ABOVE the committed value: go back to it (a raised ceiling needs eyes on the machine)
      if [ "$L" -gt "$C" ] && [ "$us" -ge "$PCE_UNKNOWN_RESTORE" ]; then echo "$C|restore:unreadable-${us}-sweeps"
      else echo "$L|hold:unreadable"; fi ;;
    band) echo "$L|hold:band" ;;
    clear)
      if [ "$L" -ge "$ceil" ]; then echo "$L|hold:at-ceiling"
      elif [ "$cs" -lt "$PCE_CLEAR_SWEEPS" ]; then echo "$L|hold:clear-streak-$cs/$PCE_CLEAR_SWEEPS"
      elif [ "$rate_ok" != "1" ]; then echo "$L|hold:rate-limited"
      else echo "$((L + 1))|raise:clear-${cs}-sweeps"; fi ;;
    *) echo "$L|hold:unknown-pressure" ;;
  esac
  return 0
}

# per-pool bounds around the committed value C. wa-worker may go ABOVE C (the Athos default 3); every other pool's ceiling
# is C itself (they only go down). Floors: wa-worker 2, ps-worker 1, gate-reviewer 2 (one gate run needs 2 reviewers).
# POOL_CEILING_ENGINE_<POOL>_FLOOR / _CEIL override; a floor is never above C, a ceiling never below C, nothing below 1.
_pce_pool_default() { # <pool> <floor|ceil> <C>
  case "$1:$2" in
    wa-worker:ceil) echo 3 ;;
    wa-worker:floor) echo 2 ;;
    ps-worker:floor) echo 1 ;;
    gate-reviewer:floor) echo 2 ;;
    *:floor) echo "$3" ;;
    *:ceil) echo "$3" ;;
  esac
}
pce_floor() {
  local up v; up=$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  v=$(_pce_knob "POOL_CEILING_ENGINE_${up}_FLOOR" "$(_pce_pool_default "$1" floor "$2")" 1)
  [ "$v" -le "$2" ] || v="$2"
  echo "$v"
}
pce_ceil() {
  local up v; up=$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  v=$(_pce_knob "POOL_CEILING_ENGINE_${up}_CEIL" "$(_pce_pool_default "$1" ceil "$2")" 1)
  [ "$v" -ge "$2" ] || v="$2"
  [ "$v" -le "$PCE_HARD_MAX" ] || v="$PCE_HARD_MAX"
  [ "$v" -ge "$2" ] || v="$2"   # a committed value above the hard max stays: the engine never lowers by clamping
  echo "$v"
}

# ── the fragment: render / parse ──────────────────────────────────────────────

# pce_fragment_render <entries "pool=level ..."> — the full file body on stdout, or rc 1 + nothing on stdout when any
# entry is not safe to emit: a pool outside the allowlist (gc turns an unknown agent into a LOAD ERROR), a level that is
# not an integer in [1, hard max] (the engine accepts 0 and -1 = UNLIMITED), or a duplicate pool. The last line of defence.
pce_fragment_render() {
  local e p v seen=" " body=""
  for e in $1; do
    p="${e%%=*}"; v="${e#*=}"
    case " $PCE_POOLS " in *" $p "*) ;; *) return 1 ;; esac
    case "$p" in ''|*[!a-z0-9._-]*) return 1 ;; esac
    _pce_int "$v" && [ "$v" -ge 1 ] && [ "$v" -le "$PCE_HARD_MAX" ] || return 1
    case "$seen" in *" $p "*) return 1 ;; esac
    seen="$seen$p "
    body="$body
[[patches.agent]]
dir = \"\"
name = \"$p\"
max_active_sessions = $v
"
  done
  printf '%s\n%s' "$PCE_HEADER" "$body"
  return 0
}

# pce_fragment_parse [file] — prints "pool=level" per entry. rc 0 = exactly what pce_fragment_render emits (comments,
# blanks, well-formed blocks); rc 1 = FOREIGN content (anything else: a hand edit, an old version, a duplicate pool) — the
# generated file is rewritten from the model, never trusted; rc 2 = absent or unreadable.
pce_fragment_parse() {
  local f="${1:-$PCE_FRAGMENT}"
  [ -r "$f" ] || return 2
  awk '
    function fin() { if (inblk && !(hd && hn && hm)) bad = 1 }
    BEGIN { inblk = 0; bad = 0 }
    /^[[:space:]]*(#.*)?$/ { next }
    /^\[\[patches\.agent\]\][[:space:]]*$/ { fin(); inblk = 1; hd = 0; hn = 0; hm = 0; nm = ""; lv = ""; next }
    /^dir[[:space:]]*=[[:space:]]*""[[:space:]]*$/ { if (!inblk || hd) bad = 1; hd = 1; next }
    /^name[[:space:]]*=[[:space:]]*"[a-z0-9._-]+"[[:space:]]*$/ {
      if (!inblk || hn) bad = 1
      hn = 1; s = $0; sub(/^name[[:space:]]*=[[:space:]]*"/, "", s); sub(/"[[:space:]]*$/, "", s); nm = s
      if (nm in seen) bad = 1
      seen[nm] = 1; next }
    /^max_active_sessions[[:space:]]*=[[:space:]]*[1-9][0-9]*[[:space:]]*$/ {   # 0 and 03 match nothing => FOREIGN (not TOML integers: a load error)
      if (!inblk || hm || !hn) bad = 1
      hm = 1; s = $0; sub(/^max_active_sessions[[:space:]]*=[[:space:]]*/, "", s); sub(/[[:space:]]*$/, "", s); lv = s + 0
      out[++n] = nm "=" lv; next }
    { bad = 1 }
    END { fin(); if (bad) exit 1; for (i = 1; i <= n; i++) print out[i]; exit 0 }
  ' "$f"
}

# ── environment readers ───────────────────────────────────────────────────────

_pce_bounded() { # <secs> cmd... — runs under timeout/gtimeout; rc 127 when neither exists (callers treat that as unreadable)
  local s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
  else return 127; fi
}

_pce_load_lib() { # the signal readers of pool-ceiling.sh; absent/broken lib => every reading is "unreadable"
  type pool_ceiling_read_swap_used_mb >/dev/null 2>&1 && return 0
  [ -r "$PCE_LIB" ] || return 1
  # shellcheck disable=SC1090
  . "$PCE_LIB" 2>/dev/null || return 1
  type pool_ceiling_read_swap_used_mb >/dev/null 2>&1
}
pce_read_swap_used_mb() { _pce_load_lib || return 0; pool_ceiling_read_swap_used_mb; return 0; }
pce_read_disk_free_mb() { _pce_load_lib || return 0; pool_ceiling_read_disk_free_mb; return 0; }

# pce_committed <pool> — the max_active_sessions COMMITTED at HEAD (integer >= 1), or nothing. Never the working tree:
# a dirty agent.toml is somebody's experiment, not the baseline the engine restores to. 0 (the operator's pause) and
# unreadable both read as "nothing" => that pool is not touched.
pce_committed() {
  local pool="$1" txt v
  txt=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$PCE_CITY" show "HEAD:./agents/$pool/agent.toml" 2>/dev/null) || return 0
  v=$(printf '%s\n' "$txt" | sed -n 's/^max_active_sessions[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\(#.*\)\{0,1\}$/\1/p' | head -1)
  if _pce_int "$v" && [ "$v" -ge 1 ]; then printf '%s' "$v"; fi
  return 0
}

# pce_worktree_cap <pool> — what agents/<pool>/agent.toml says on disk now (informational: logged next to the committed one).
pce_worktree_cap() {
  local f="$PCE_CITY/agents/$1/agent.toml" v
  [ -r "$f" ] || return 0
  v=$(sed -n 's/^max_active_sessions[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\(#.*\)\{0,1\}$/\1/p' "$f" 2>/dev/null | head -1)
  if _pce_int "$v"; then printf '%s' "$v"; fi
  return 0
}

# pce_budget — GC_VARIABLE_SESSION_MAX as the LIVE enforcer sees it: the smaller of the env value and the Pilot plist's
# (both readable => min; one => that one; none => the dispatchers' own default 6, i.e. the inert direction).
pce_budget() {
  local a="" b="" v
  v="${GC_VARIABLE_SESSION_MAX:-}"; if _pce_int "$v" && [ "$v" -ge 1 ]; then a="$v"; fi
  if [ -r "$PCE_PILOT_PLIST" ] && [ -x /usr/libexec/PlistBuddy ]; then
    v=$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:GC_VARIABLE_SESSION_MAX" "$PCE_PILOT_PLIST" 2>/dev/null) || v=""
    if _pce_int "$v" && [ "$v" -ge 1 ]; then b="$v"; fi
  fi
  if [ -n "$a" ] && [ -n "$b" ]; then if [ "$a" -le "$b" ]; then echo "$a"; else echo "$b"; fi
  elif [ -n "$a" ]; then echo "$a"
  elif [ -n "$b" ]; then echo "$b"
  else echo "$PCE_BUDGET_FALLBACK"; fi
  return 0
}

# pce_include_state — 1 | 0 | ?  from the PARSED `include` array of city.toml, each entry resolved against its directory and compared with
# the fragment's real path. A text match read a trailing comment, a .bak or the same name elsewhere as "included". ? = cannot tell
# (unreadable, unparseable, odd shape, python3 without tomllib, a crash): only a printed 0/1 from a CLEAN exit counts.
pce_include_state() {
  local v; [ -r "$PCE_CITY_TOML" ] || { echo '?'; return 0; }
  v=$("$PCE_PY" -c 'import os,sys,tomllib
i=tomllib.load(open(sys.argv[1],"rb")).get("include",[])
d=os.path.dirname(os.path.abspath(sys.argv[1]))
print("?" if not isinstance(i,list) or not all(isinstance(e,str) for e in i) else int(any(os.path.realpath(os.path.join(d,e))==os.path.realpath(sys.argv[2]) for e in i)))' "$PCE_CITY_TOML" "$PCE_FRAGMENT" 2>/dev/null) || v=""
  case "$v" in 0|1) echo "$v" ;; *) echo '?' ;; esac
}

_pce_now() {
  local n="${POOL_CEILING_ENGINE_NOW:-}"
  _pce_int "$n" || n=$(date +%s 2>/dev/null) || n=""
  if _pce_int "$n" && [ "$n" -gt 0 ]; then printf '%s' "$n"; fi
  return 0
}
_pce_date_of() { date -r "$1" +%Y-%m-%d 2>/dev/null || date -d "@$1" +%Y-%m-%d 2>/dev/null; }

# ── log / notify ──────────────────────────────────────────────────────────────

# pce_log <k=v ...> — one TSV line. Dry run: printed, never appended. Rotated at ~5 MB (one generation), best-effort.
pce_log() {
  local line="ts=${PCE_NOW:-?}" a
  for a in "$@"; do line="$line	$a"; done
  if [ "$PCE_DRY" = "1" ]; then printf '%s\n' "$line"; return 0; fi
  mkdir -p "$(dirname "$PCE_LOG")" 2>/dev/null || return 0
  if [ -f "$PCE_LOG" ] && [ "$(wc -c < "$PCE_LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then mv -f "$PCE_LOG" "$PCE_LOG.1" 2>/dev/null || true; fi
  printf '%s\n' "$line" >> "$PCE_LOG" 2>/dev/null || true
  return 0
}
# pce_log_change <key> <k=v ...> — a steady-state condition (no include, tripped...) is logged when it APPEARS, not every sweep.
pce_log_change() {
  local key="$1"; shift
  if [ "$PCE_DRY" = "1" ]; then pce_log "$@"; return 0; fi
  [ "$(cat "$PCE_STATE/last-condition" 2>/dev/null)" = "$key" ] && return 0
  pce_log "$@"
  printf '%s\n' "$key" > "$PCE_STATE/last-condition.tmp.$$" 2>/dev/null && mv -f "$PCE_STATE/last-condition.tmp.$$" "$PCE_STATE/last-condition" 2>/dev/null
  return 0
}
pce_clear_condition() { [ "$PCE_DRY" = "1" ] || rm -f "$PCE_STATE/last-condition" 2>/dev/null; return 0; }

# pce_notify <msg> — abnormal events only (a trip, a repair, a kill-switch restore); routine raise/lower stays in the log.
pce_notify() {
  [ "$PCE_DRY" = "1" ] && return 0
  command -v "$PCE_NOTIFY" >/dev/null 2>&1 || [ -x "$PCE_NOTIFY" ] || return 0
  if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    _pce_bounded 20 "$PCE_NOTIFY" -t 'pool-ceiling-engine' -p 4 "$1" >/dev/null 2>&1 || true
  else
    "$PCE_NOTIFY" -t 'pool-ceiling-engine' -p 4 "$1" >/dev/null 2>&1 || true
  fi
  return 0
}

# ── lock: mkdir-atomic + heartbeat mtime + PID:RANDOM token + single-winner stale reclaim ──
# Same shape as quality-gate-dispatcher.sh's GATE_LOCK (ga-y0g5x: "the same pattern, do not invent another"), except that
# the lock dir is emptied with rm -f + rmdir, never rm -rf: it only ever holds the heartbeat file.
_pce_lock_age() { local mt; mt=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo ""); [ -n "$mt" ] || { pce_log "event=lock-age-unreadable" "path=$1" "effect=read as fresh: the lock is respected"; echo 0; return 0; }; echo $(( $(date +%s) - mt )); }
_pce_lock_dead() { local pid; pid=$(head -n1 "$PCE_LOCK_HB" 2>/dev/null | cut -d: -f1 || true); case "$pid" in ''|*[!0-9]*) return 1 ;; esac; kill -0 "$pid" 2>/dev/null && return 1; return 0; }
_pce_lock_hb() { printf '%s\n' "$PCE_LOCK_TOKEN" > "$PCE_LOCK_HB" 2>/dev/null || true; }
pce_lock_release() {
  [ "$(head -n1 "$PCE_LOCK_HB" 2>/dev/null || true)" = "$PCE_LOCK_TOKEN" ] || return 0
  rm -f "$PCE_LOCK_HB" 2>/dev/null; rmdir "$PCE_LOCK_DIR" 2>/dev/null
  return 0
}
pce_lock_acquire() { # 0 = ours; 1 = a LIVE run holds it (back off, silently)
  if mkdir "$PCE_LOCK_DIR" 2>/dev/null; then
    _pce_lock_hb
    [ -s "$PCE_LOCK_HB" ] || { rm -f "$PCE_LOCK_HB" 2>/dev/null; rmdir "$PCE_LOCK_DIR" 2>/dev/null; return 1; }
    return 0
  fi
  # The holder's age is its heartbeat's; a dir with NO heartbeat (a crash between mkdir and the first write) ages by the dir
  # itself — otherwise it would read as "mid-race, live" for ever and the engine would stay stuck at whatever it last wrote.
  local age
  if [ -e "$PCE_LOCK_HB" ]; then age=$(_pce_lock_age "$PCE_LOCK_HB"); else age=$(_pce_lock_age "$PCE_LOCK_DIR"); fi
  if [ "$age" -lt "$PCE_LOCK_TTL" ] && ! _pce_lock_dead; then return 1; fi
  local reaping="$PCE_LOCK_DIR.reaping"
  if ! mkdir "$reaping" 2>/dev/null; then
    if [ "$(_pce_lock_age "$reaping")" -ge 10 ]; then rmdir "$reaping" 2>/dev/null || true; fi
    mkdir "$reaping" 2>/dev/null || return 1
  fi
  # single winner: re-check under the reaping marker
  if [ -e "$PCE_LOCK_HB" ] && [ "$(_pce_lock_age "$PCE_LOCK_HB")" -lt "$PCE_LOCK_TTL" ] && ! _pce_lock_dead; then rmdir "$reaping" 2>/dev/null || true; return 1; fi
  _pce_lock_hb
  rmdir "$reaping" 2>/dev/null || true
  [ -s "$PCE_LOCK_HB" ] || return 1
  pce_log "event=lock-reclaimed" "holder_age_s=$age" "ttl_s=$PCE_LOCK_TTL"
  return 0
}

# ── per-pool state, daily counter, trip ───────────────────────────────────────

_pce_kv() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
_pce_atomic_put() { # <file> <content> — tmp + mv; rc 1 if it did not land
  local tmp="$1.tmp.$$"
  printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null; return 1
}
# pce_state_ok <pool> — a state file that EXISTS must carry its four integers. Absent is a legitimate first run; present but
# unreadable is NOT "never written" (that reading would skip the 10-minute rate limit), and the caller treats it as just written.
pce_state_ok() {
  local f="$PCE_STATE/$1.state" k
  [ -e "$f" ] || return 0
  for k in clear_streak unknown_streak last_sweep_at last_write_at; do _pce_int "$(_pce_kv "$f" "$k")" || return 1; done
  return 0
}
pce_state_get() { local v; v=$(_pce_kv "$PCE_STATE/$1.state" "$2"); _pce_int "$v" && printf '%s' "$v" || printf '0'; }
pce_state_put() { # <pool> <clear_streak> <unknown_streak> <last_sweep_at> <last_write_at>
  [ "$PCE_DRY" = "1" ] && return 0
  _pce_atomic_put "$PCE_STATE/$1.state" "clear_streak=$2
unknown_streak=$3
last_sweep_at=$4
last_write_at=$5" || pce_log "event=state-write-failed" "what=$1.state" "effect=the streaks and the rate limit of $1 restart as if its file were absent"
}
pce_daily_writes() { # writes counted today: 0 on a new day or when there is no file YET; the LIMIT when the file exists but cannot be read
  local d w
  [ -e "$PCE_STATE/daily" ] || { printf '0'; return 0; }
  d=$(_pce_kv "$PCE_STATE/daily" date); w=$(_pce_kv "$PCE_STATE/daily" writes)
  # A counter we cannot read is not a counter at zero: it would switch the breaker off for good. Inert reading = at the limit.
  if [ -z "$d" ] || ! _pce_int "$w"; then printf '%s' "$PCE_DAILY_MAX"; return 0; fi
  if [ "$d" = "$(_pce_date_of "$PCE_NOW")" ]; then printf '%s' "$w"; else printf '0'; fi
}
pce_daily_bump() {
  [ "$PCE_DRY" = "1" ] && return 0
  local w; w=$(pce_daily_writes)
  _pce_atomic_put "$PCE_STATE/daily" "date=$(_pce_date_of "$PCE_NOW")
writes=$((w + 1))" || pce_log "event=state-write-failed" "what=daily-counter" "effect=the breaker may undercount today's writes"
}
pce_trip() { # <daily|manual> <reason>
  [ "$PCE_DRY" = "1" ] && return 0
  _pce_atomic_put "$PCE_STATE/tripped" "kind=$1
date=$(_pce_date_of "$PCE_NOW")
reason=$2" || pce_log "event=state-write-failed" "what=trip" "effect=the trip may not hold; the callers empty the fragment regardless"
}

# ── writing the fragment ──────────────────────────────────────────────────────

pce_fragment_is() { printf '%s\n' "$1" | cmp -s - "$PCE_FRAGMENT" 2>/dev/null; }   # file == content, byte for byte (absent => no)
# pce_fragment_is_empty — well-formed and with NO entries (zero bytes, comment-only, our own header all count). Absent or foreign: no.
pce_fragment_is_empty() { local o; o=$(pce_fragment_parse 2>/dev/null) || return 1; [ -z "$o" ]; }
pce_write_fragment() { # <content> — atomic: tmp in the same dir + mv. rc 0 only if the bytes landed.
  local tmp="$PCE_FRAGMENT.tmp.$$"
  mkdir -p "$(dirname "$PCE_FRAGMENT")" 2>/dev/null
  printf '%s\n' "$1" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$PCE_FRAGMENT" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  pce_fragment_is "$1"
}

# pce_readback <entries> — after a write: does `gc config show --json` resolve every entry to the intended value?
# rc 0 ok | 1 MISMATCH (definitive: the config loads, the ceiling did not move as written — the typo'd-key class)
#        | 2 could not read (gc absent / timeout / not JSON / ok:false — possibly the fragment itself broke the load).
# stdout: the detail. With NO entries (an empty fragment) it asserts only that the config loads.
pce_readback() {
  local out rc e pool want got mism=0 detail=""
  out=$(_pce_bounded "$PCE_READBACK_SECS" "$PCE_GC" config show --city "$PCE_CITY" --json 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then echo "gc config show rc=$rc"; return 2; fi
  if ! printf '%s' "$out" | jq -e '.ok == true' >/dev/null 2>&1; then echo "gc config show: not JSON or ok != true"; return 2; fi
  for e in $1; do
    pool="${e%%=*}"; want="${e#*=}"
    got=$(printf '%s' "$out" | jq -r --arg n "$pool" '[.config.Agents[]? | select(.Name == $n and (.Dir // "") == "")] | if length == 1 then (.[0].MaxActiveSessions | tostring) else "absent" end' 2>/dev/null) || got="?"
    if [ "$got" != "$want" ]; then mism=1; detail="$detail $pool resolved=$got intended=$want;"; fi
  done
  if [ "$mism" = "1" ]; then echo "${detail# }"; return 1; fi
  return 0
}

# pce_preflight <entries> — BEFORE writing a non-empty fragment: does `gc config show --json` list every pool we are about to
# patch as exactly one agent? A patch for an agent that does not exist is a config LOAD ERROR (ga-m9x0lb.1), so a renamed or
# removed pool must be caught here, not by the read-back after the damage. rc 0 ok | 1 a pool is missing | 2 could not read.
pce_preflight() {
  local out rc e pool got miss=""
  out=$(_pce_bounded "$PCE_READBACK_SECS" "$PCE_GC" config show --city "$PCE_CITY" --json 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then echo "gc config show rc=$rc"; return 2; fi
  if ! printf '%s' "$out" | jq -e '.ok == true' >/dev/null 2>&1; then echo "gc config show: not JSON or ok != true"; return 2; fi
  for e in $1; do
    pool="${e%%=*}"
    got=$(printf '%s' "$out" | jq -r --arg n "$pool" '[.config.Agents[]? | select(.Name == $n and (.Dir // "") == "")] | length' 2>/dev/null) || got="?"
    [ "$got" = "1" ] || miss="$miss $pool"
  done
  if [ -n "$miss" ]; then echo "agent(s) not in the config:${miss}"; return 1; fi
  return 0
}

# pce_restore <reason> — the INERT state: the empty fragment. Always allowed (the breaker only blocks non-empty writes), counts
# as a write, resets the per-pool streaks. rc 0 = the file is now the empty body.
pce_restore() {
  local reason="$1" empty had=""
  empty=$(pce_fragment_render "") || return 1
  if pce_fragment_is_empty; then pce_log_change "restore-empty:$reason" "event=restore" "reason=$reason" "result=already-empty"; return 0; fi
  had=$(pce_fragment_parse 2>/dev/null | tr '\n' ' ')
  if [ "$PCE_DRY" = "1" ]; then pce_log "event=restore" "reason=$reason" "result=would-empty" "was=${had:-foreign-or-absent}"; return 0; fi
  if pce_write_fragment "$empty"; then
    pce_daily_bump
    pce_log "event=restore" "reason=$reason" "result=emptied" "was=${had:-foreign-or-absent}"
    local p; for p in $PCE_POOLS; do pce_state_put "$p" 0 0 "$(pce_state_get "$p" last_sweep_at)" "$PCE_NOW"; done
    return 0
  fi
  pce_log "event=restore" "reason=$reason" "result=WRITE-FAILED"
  pce_notify "pool-ceiling-engine: could NOT empty $PCE_FRAGMENT ($reason) - check the .gc directory"
  return 1
}

# ── the sweep ─────────────────────────────────────────────────────────────────

# pce_repair_missing_fragment — include present + fragment absent = the next reload fails to load. Create it EMPTY (noclobber:
# never replaces a file that appeared meanwhile). Safe by construction: empty is config-identical to "no engine".
pce_repair_missing_fragment() {
  [ -e "$PCE_FRAGMENT" ] && return 0
  local st empty; st=$(pce_include_state)
  [ "$st" != "0" ] || return 0   # only a definite "not included" skips; "?" repairs too (an EMPTY file is config-identical to no engine)
  empty=$(pce_fragment_render "") || return 0
  if [ "$PCE_DRY" = "1" ]; then pce_log "event=repair" "result=would-create-empty"; return 0; fi
  mkdir -p "$(dirname "$PCE_FRAGMENT")" 2>/dev/null
  if ( set -C; printf '%s\n' "$empty" > "$PCE_FRAGMENT" ) 2>/dev/null; then
    pce_log "event=repair" "result=created-empty" "include=$st" "why=the file was absent and city.toml includes the fragment (include=1) or may (include=?)"
    pce_notify "pool-ceiling-engine: $PCE_FRAGMENT was ABSENT while city.toml includes it (include=$st, ?=cannot tell; next reload would fail) - re-created EMPTY"
  fi
  return 0
}

pce_sweep() {
  local rc=0
  PCE_NOW=$(_pce_now)
  if [ -z "$PCE_NOW" ]; then PCE_NOW="?"; pce_log "event=skip" "reason=clock-unreadable"; return 0; fi

  local has_on=0 has_off=0 include
  [ -e "$PCE_ON_FILE" ] && has_on=1
  [ -e "$PCE_OFF_FILE" ] && has_off=1
  include=$(pce_include_state)

  # Disabled: silent and inert — except the one repair that cannot make anything worse.
  if [ "$has_on" = "0" ] && [ "$has_off" = "0" ] && [ "$PCE_DRY" != "1" ]; then
    pce_repair_missing_fragment
    return 0
  fi

  if [ "$PCE_DRY" = "1" ]; then _pce_sweep_locked "$include" "$has_off"; return $?; fi
  mkdir -p "$PCE_STATE" 2>/dev/null || { pce_log "event=skip" "reason=state-dir-unwritable"; return 0; }
  pce_lock_acquire || return 0
  _pce_sweep_locked "$include" "$has_off"; rc=$?
  pce_lock_release
  return "$rc"
}

# the body of a sweep; runs holding the lock (never from a dry run, which writes nothing)
_pce_sweep_locked() {
  local include="$1" has_off="$2"

  # 1. kill switch
  if [ "$has_off" = "1" ]; then
    local was_empty=0 p
    pce_fragment_is_empty && was_empty=1
    if pce_restore "kill-switch"; then
      # (no pce_clear_condition here: it would wipe the dedup key every sweep and log "already empty" every 5 minutes)
      [ "$was_empty" = "1" ] || pce_notify "pool-ceiling-engine: kill switch (.off) - fragment EMPTIED, every pool is back on its committed ceiling"
    fi
    for p in $PCE_POOLS; do pce_state_put "$p" 0 0 0 0; done
    return 0
  fi

  # 1b. the calendar date dates the daily counter and the trip: where it cannot be computed both would read as "a new day" (breaker off, trip expired)
  [ -n "$(_pce_date_of "$PCE_NOW")" ] || { pce_log_change "date-unreadable" "event=skip" "reason=cannot compute the calendar date of $PCE_NOW: the daily breaker and the trip cannot be dated - nothing written"; return 0; }

  # 2. tripped?
  if [ -e "$PCE_STATE/tripped" ]; then
    local tk td tr
    tk=$(_pce_kv "$PCE_STATE/tripped" kind); td=$(_pce_kv "$PCE_STATE/tripped" date); tr=$(_pce_kv "$PCE_STATE/tripped" reason)
    if [ "$tk" = "daily" ] && [ "$td" != "$(_pce_date_of "$PCE_NOW")" ]; then
      [ "$PCE_DRY" = "1" ] || rm -f "$PCE_STATE/tripped" 2>/dev/null
      pce_log "event=trip-expired" "was=$tr" "date=$td"
    else
      # restore only when there is something to restore: a no-op restore logs under its own dedup key, which would alternate
      # with the "tripped" key below and log both lines on every sweep
      pce_fragment_is_empty || pce_restore "tripped:$tr" >/dev/null
      pce_log_change "tripped:$tk:$td:$tr" "event=tripped" "kind=$tk" "date=$td" "reason=$tr" "action=stay-empty (reset: pool-ceiling-engine.sh reset)"
      return 0
    fi
  fi

  # 3. nothing to apply without the include; "cannot tell" is not "included" (a fragment the controller never loads is not in force)
  if [ "$include" != "1" ] && [ "$PCE_DRY" != "1" ]; then
    if [ ! -r "$PCE_CITY_TOML" ]; then
      pce_log_change "city-toml-unreadable" "event=skip" "reason=city.toml is UNREADABLE ($PCE_CITY_TOML): cannot tell whether it includes the fragment - nothing written"
    elif [ "$include" = "0" ]; then
      pce_log_change "no-include" "event=skip" "reason=city.toml does not include $(basename "$PCE_FRAGMENT") - nothing written"
    else
      pce_log_change "include-unknown" "event=skip" "reason=cannot tell whether city.toml's parsed include array names $(basename "$PCE_FRAGMENT") (unparseable, odd shape, or python3 without tomllib) - nothing written"
    fi
    return 0
  fi

  # 4. readings
  local swap disk pressure budget
  swap=$(pce_read_swap_used_mb); disk=$(pce_read_disk_free_mb)
  pressure=$(pce_pressure "$swap" "$disk")
  budget=$(pce_budget)

  # 5. the fragment as it is NOW (the file is the truth about the current levels, not our state files)
  local cur_txt cur_map="" prc
  cur_txt=$(pce_fragment_parse); prc=$?
  case "$prc" in
    0) cur_map=$(printf '%s' "$cur_txt" | tr '\n' ' '); cur_map="${cur_map% }" ;;
    1) pce_log "event=fragment-foreign" "action=rewrite-from-model" ;;
    *) [ "$include" = "1" ] && pce_log "event=fragment-absent" "action=write-from-model" ;;
  esac

  # 6. one decision per pool
  local pool C L floor ceil cs us lsw lw counted rate_ok d new reason wt
  local proposed="" dev="" cs_map="" us_map="" lw_map="" lsw_map="" reason_map="" c_map="" l_map="" sum=0 skipped=""
  for pool in $PCE_POOLS; do
    C=$(pce_committed "$pool")
    if ! _pce_int "$C"; then
      skipped="$skipped $pool"
      pce_log "event=skip" "pool=$pool" "reason=committed-unreadable-or-paused" "action=entry-dropped"
      continue
    fi
    L=$(_pce_map_get "$cur_map" "$pool"); _pce_int "$L" || L="$C"
    floor=$(pce_floor "$pool" "$C"); ceil=$(pce_ceil "$pool" "$C")
    [ "$L" -le "$ceil" ] || L="$ceil"     # clamp DOWN only: a clamp must never be a raise that skipped the sweeps
    cs=$(pce_state_get "$pool" clear_streak); us=$(pce_state_get "$pool" unknown_streak)
    lsw=$(pce_state_get "$pool" last_sweep_at); lw=$(pce_state_get "$pool" last_write_at)
    [ "$lsw" -le "$PCE_NOW" ] || lsw=0; [ "$lw" -le "$PCE_NOW" ] || lw=0      # a stamp in the future (clock jump) is not a permanent limit
    if ! pce_state_ok "$pool"; then
      pce_log_change "state-corrupt:$pool" "event=state-corrupt" "pool=$pool" "action=treated as just written: no raise for ${PCE_RATE_SECS}s, streaks restart (the file is rewritten this sweep)"
      cs=0; us=0; lw="$PCE_NOW"
    fi
    counted=0; if [ "$lsw" -eq 0 ] || [ $((PCE_NOW - lsw)) -ge "$PCE_SWEEP_GAP_SECS" ]; then counted=1; fi
    # streaks: any non-clear reading resets the clear streak at once; a clear one counts only on a COUNTED sweep
    case "$pressure" in
      clear) us=0; [ "$counted" = "1" ] && cs=$((cs + 1)) ;;
      unknown) cs=0; [ "$counted" = "1" ] && us=$((us + 1)) ;;
      *) cs=0; us=0 ;;
    esac
    rate_ok=0; if [ "$lw" -eq 0 ] || [ $((PCE_NOW - lw)) -ge "$PCE_RATE_SECS" ]; then rate_ok=1; fi
    d=$(pce_decide "$C" "$L" "$floor" "$ceil" "$pressure" "$cs" "$us" "$rate_ok")
    new="${d%%|*}"; reason="${d#*|}"
    _pce_int "$new" || { new="$L"; reason="hold:decision-unreadable"; }
    proposed=$(_pce_map_set "$proposed" "$pool" "$new")
    c_map=$(_pce_map_set "$c_map" "$pool" "$C"); l_map=$(_pce_map_set "$l_map" "$pool" "$L")
    cs_map=$(_pce_map_set "$cs_map" "$pool" "$cs"); us_map=$(_pce_map_set "$us_map" "$pool" "$us")
    lw_map=$(_pce_map_set "$lw_map" "$pool" "$lw")
    if [ "$counted" = "1" ]; then lsw_map=$(_pce_map_set "$lsw_map" "$pool" "$PCE_NOW"); else lsw_map=$(_pce_map_set "$lsw_map" "$pool" "$lsw"); fi
    reason_map=$(_pce_map_set "$reason_map" "$pool" "$reason")
    wt=$(pce_worktree_cap "$pool")
    sum=$((sum + new))
    pce_log "event=sweep" "pool=$pool" "committed=$C" "worktree_cap=${wt:-?}" "cur=$L" "new=$new" "reason=$reason" "pressure=$pressure" "swap_used_mb=${swap:-?}" "disk_free_mb=${disk:-?}" "clear_streak=$cs" "unknown_streak=$us" "counted=$counted"
  done

  # 7. budget: a RAISE may not push the sum of the ceilings past GC_VARIABLE_SESSION_MAX (cancel raises until it fits; the
  #    status quo is never lowered because of the budget)
  for pool in $PCE_POOLS; do
    new=$(_pce_map_get "$proposed" "$pool"); L=$(_pce_map_get "$l_map" "$pool")
    _pce_int "$new" || continue
    if [ "$new" -gt "$L" ] && [ "$sum" -gt "$budget" ]; then
      sum=$((sum - (new - L)))
      proposed=$(_pce_map_set "$proposed" "$pool" "$L")
      reason_map=$(_pce_map_set "$reason_map" "$pool" "hold:budget")
      pce_log "event=budget" "pool=$pool" "cancelled-raise=$L->$new" "budget=$budget" "sum_if_raised=$((sum + new - L))"
    fi
  done

  # 8. the model of the fragment: only DEVIATIONS from committed, in pool order
  for pool in $PCE_POOLS; do
    new=$(_pce_map_get "$proposed" "$pool"); C=$(_pce_map_get "$c_map" "$pool")
    _pce_int "$new" || continue
    [ "$new" -eq "$C" ] || dev=$(_pce_map_set "$dev" "$pool" "$new")
  done
  local content
  if ! content=$(pce_fragment_render "$dev"); then
    pce_log "event=render-refused" "entries=$dev"
    pce_notify "pool-ceiling-engine: refused to render entries '$dev' (pool outside the allowlist or level outside [1,$PCE_HARD_MAX]) - emptying the fragment"
    pce_trip daily "render-refused"
    pce_restore "render-refused"
    return 0
  fi

  # 9. persist the bookkeeping for pools whose level did not change; changed pools get last_write_at = now below
  local changed=""
  for pool in $PCE_POOLS; do
    new=$(_pce_map_get "$proposed" "$pool"); _pce_int "$new" || continue
    L=$(_pce_map_get "$l_map" "$pool")
    [ "$new" -ne "$L" ] && changed="$changed $pool"
  done

  # Nothing to do when the file already says the same thing (same entries; the comment header is irrelevant) and no pool moved.
  if [ "$prc" = "0" ] && [ "$cur_map" = "$dev" ] && [ -z "$changed" ]; then
    [ "$PCE_DRY" != "1" ] || pce_log "event=no-change" "levels=${dev:-<committed>}" "pressure=$pressure"
    for pool in $PCE_POOLS; do
      _pce_int "$(_pce_map_get "$proposed" "$pool")" || continue
      pce_state_put "$pool" "$(_pce_map_get "$cs_map" "$pool")" "$(_pce_map_get "$us_map" "$pool")" "$(_pce_map_get "$lsw_map" "$pool")" "$(_pce_map_get "$lw_map" "$pool")"
    done
    pce_clear_condition
    return 0
  fi

  # 10. a write is needed
  if [ -n "$dev" ] && [ "$(pce_daily_writes)" -ge "$PCE_DAILY_MAX" ]; then
    pce_log "event=breaker" "writes_today=$(pce_daily_writes)" "max=$PCE_DAILY_MAX" "wanted=$dev" "action=empty-and-trip-until-tomorrow"
    pce_notify "pool-ceiling-engine: daily write breaker ($PCE_DAILY_MAX writes) tripped - fragment emptied, engine inert until tomorrow"
    pce_trip daily "daily-breaker"
    pce_restore "daily-breaker"
    return 0
  fi
  if [ "$PCE_DRY" = "1" ]; then
    local why="levels-change"
    [ "$prc" = "1" ] && why="fragment-foreign(rewritten from the model)"
    [ "$prc" = "2" ] && why="fragment-absent(would be created, empty if no level changes)"
    pce_log "event=would-write" "from=${cur_map:-<committed>}" "to=${dev:-<committed>}" "changed=${changed# }" "why=$why"
    return 0
  fi
  if [ -n "$dev" ]; then
    local pf pfrc
    pf=$(pce_preflight "$dev"); pfrc=$?
    if [ "$pfrc" -ne 0 ]; then
      pce_log_change "preflight:$pfrc:$dev" "event=preflight-failed" "rc=$pfrc" "detail=$pf" "wanted=$dev" "action=nothing-written"
      [ "$pfrc" -ne 1 ] || pce_notify "pool-ceiling-engine: not writing '$dev' - $pf (a patch for a missing agent breaks the config load)"
      return 0
    fi
  fi
  if ! pce_write_fragment "$content"; then
    pce_log "event=write-failed" "to=${dev:-<committed>}"
    pce_notify "pool-ceiling-engine: could not write $PCE_FRAGMENT"
    return 0
  fi
  pce_daily_bump
  local rb rbrc
  rb=$(pce_readback "$dev"); rbrc=$?
  if [ "$rbrc" -ne 0 ]; then
    pce_log "event=readback-failed" "rc=$rbrc" "detail=$rb" "wrote=${dev:-<committed>}" "action=empty-and-trip"
    pce_notify "pool-ceiling-engine: read-back after writing '${dev:-<committed>}' FAILED ($rb) - fragment emptied, engine tripped"
    if [ "$rbrc" -eq 1 ]; then pce_trip manual "readback-mismatch: $rb"; else pce_trip daily "readback-unreadable: $rb"; fi
    pce_restore "readback-failed"
    rb=$(pce_readback ""); rbrc=$?
    if [ "$rbrc" -ne 0 ]; then
      pce_log "event=config-unloadable-even-empty" "detail=$rb"
      pce_notify "pool-ceiling-engine: the config does not load even with the EMPTY fragment ($rb) - not caused by the engine, needs a human"
    fi
    return 0
  fi
  for pool in $PCE_POOLS; do
    new=$(_pce_map_get "$proposed" "$pool"); _pce_int "$new" || continue
    L=$(_pce_map_get "$l_map" "$pool"); lw=$(_pce_map_get "$lw_map" "$pool"); cs=$(_pce_map_get "$cs_map" "$pool")
    if [ "$new" -ne "$L" ]; then lw="$PCE_NOW"; cs=0; fi
    pce_state_put "$pool" "$cs" "$(_pce_map_get "$us_map" "$pool")" "$(_pce_map_get "$lsw_map" "$pool")" "$lw"
  done
  pce_clear_condition
  pce_log "event=write" "from=${cur_map:-<committed>}" "to=${dev:-<committed>}" "changed=${changed# }" "budget=$budget" "sum=$sum" "readback=ok"
  return 0
}

# ── subcommands ───────────────────────────────────────────────────────────────

pce_check() {
  case "$(pce_include_state)" in 1) ;; 0) echo "ok: city.toml does not include the fragment (nothing to check)"; return 0 ;; *) echo "UNKNOWN: cannot tell whether city.toml includes the fragment (unreadable, unparseable, or python3 without tomllib) - not verified"; return 2 ;; esac
  if [ ! -e "$PCE_FRAGMENT" ]; then echo "VIOLATION: city.toml includes $(basename "$PCE_FRAGMENT") but the file is ABSENT - the next reload fails to load"; return 1; fi
  pce_fragment_parse >/dev/null; case $? in 0) echo "ok: include present, fragment present and well-formed"; return 0 ;; 1) echo "VIOLATION: fragment has FOREIGN content (hand edit / old version)"; return 1 ;; *) echo "VIOLATION: fragment unreadable"; return 1 ;; esac
}

pce_status() {
  PCE_NOW=$(_pce_now); PCE_NOW="${PCE_NOW:-?}"
  echo "ligado: $([ -e "$PCE_ON_FILE" ] && echo SIM || echo nao)  kill-switch: $([ -e "$PCE_OFF_FILE" ] && echo PRESENTE || echo ausente)  include no city.toml: $(case "$(pce_include_state)" in 1) echo sim ;; 0) echo NAO ;; *) echo DESCONHECIDO ;; esac)"
  echo "fragmento: $PCE_FRAGMENT  ($(pce_check | head -1))"
  local lv rc; lv=$(pce_fragment_parse); rc=$?
  if [ "$rc" -eq 2 ]; then echo "  niveis no fragmento: (arquivo AUSENTE ou ilegivel)"
  elif [ "$rc" -ne 0 ]; then echo "  niveis no fragmento: (conteudo ESTRANHO: nao e o que o motor escreve; sera reescrito)"
  elif [ -z "$lv" ]; then echo "  niveis no fragmento: (vazio: tudo no commitado)"
  else echo "  niveis no fragmento: $(printf '%s' "$lv" | tr '\n' ' ')"; fi
  [ -e "$PCE_STATE/tripped" ] && echo "DISJUNTOR ARMADO: $(tr '\n' ' ' < "$PCE_STATE/tripped")  (reset: pool-ceiling-engine.sh reset)"
  echo "escritas hoje: $([ -n "$(_pce_date_of "$PCE_NOW")" ] && pce_daily_writes || echo '?')/$PCE_DAILY_MAX  orcamento (GC_VARIABLE_SESSION_MAX): $(pce_budget)"
  local pool C
  for pool in $PCE_POOLS; do
    C=$(pce_committed "$pool")
    echo "  $pool: commitado=${C:-?} piso=$(_pce_int "$C" && pce_floor "$pool" "$C" || echo ?) teto=$(_pce_int "$C" && pce_ceil "$pool" "$C" || echo ?) streak-clear=$(pce_state_get "$pool" clear_streak) streak-ilegivel=$(pce_state_get "$pool" unknown_streak) ultima-escrita=$(pce_state_get "$pool" last_write_at)"
  done
  local s d; s=$(pce_read_swap_used_mb); d=$(pce_read_disk_free_mb)
  echo "sinais agora: swap usado=${s:-?}MB disco livre=${d:-?}MB -> pressao: $(pce_pressure "$s" "$d")"
}

pce_reset() {
  mkdir -p "$PCE_STATE" 2>/dev/null
  rm -f "$PCE_STATE/tripped" "$PCE_STATE/daily" "$PCE_STATE/last-condition" 2>/dev/null
  local p; for p in $PCE_POOLS; do rm -f "$PCE_STATE/$p.state" 2>/dev/null; done
  PCE_NOW=$(_pce_now); pce_log "event=reset" "by=manual"
  echo "reset: disjuntor, contador diario e estado por pool zerados (o fragmento nao foi tocado)"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  pce_init
  case "${1:-run}" in
    run) pce_sweep ;;
    plan) PCE_DRY=1; pce_sweep ;;
    status) pce_status ;;
    reset) pce_reset ;;
    check) pce_check; exit $? ;;
    *) echo "uso: pool-ceiling-engine.sh [run|plan|status|reset|check]" >&2; exit 2 ;;
  esac
fi
