#!/bin/bash
# dolt-gc-maintenance.sh — keeps the city's hq beads store lean automatically.
#
# THREE independently-gated layers of upkeep. All SILENT on success (Athos
# preference — only FAILURE notifies). Run by launchd every 2h.
#
#   1. EPHEMERAL PURGE  (ALWAYS ON)  — `bd purge` removes CLOSED *ephemeral* beads
#      (ephemeral=1: gate-reviewer sessions, terminal gate markers). Cheap. The >2h
#      cutoff guarantees we never touch a bead from a live gate run (runs finish <45m).
#
#   2. NON-EPHEMERAL PRUNE  (OPT-IN: PRUNE_ENABLED=1)  — `bd prune` removes CLOSED
#      *non-ephemeral* beads (ephemeral=0 tasks/chores/sessions) older than
#      PRUNE_KEEP_DAYS. These live in BOTH the `issues` and the `wisps` tables and are
#      caught by NEITHER the ephemeral purge (skips ephemeral=0) NOR the online gc.
#      ── THIS is the fix for the 2026-07-02 gate stall ──
#      hq.wisps bloated to 37,810 rows (97.8% closed ephemeral=0 task beads: 31,685).
#      Concurrent full-table reconcile scans over that bloat drove Dolt CPU to ~194%
#      sustained → the gate stopped producing verdicts for 20+ min. A manual
#      `bd prune --older-than 3d --force` (~22,900 rows) dropped CPU to ~43%. The
#      pipeline churns ~20k task beads/week, so the table re-bloats to 37k in ~10 days
#      without a routine. Prune stops the ROW-COUNT growth that drives the scans.
#      Bounded (PRUNE_MAX_PER_RUN — never a catastrophic single delete), backup-gated,
#      skip-when-hot, oldest-first. Because this job runs every 2h, steady state prunes
#      only the thin slice that just crossed the retention boundary (~hundreds/run),
#      never a big batch. Prune archives every deleted bead to
#      .gc/runtime/packs/maintenance/jsonl-archive/<store>/ (recoverable). DEFAULT OFF.
#
#   3. ONLINE GC + weekly FLATTEN  — `dolt_gc()` (size-triggered, ALWAYS ON) reclaims
#      unreferenced commit history (~1.4G/10h git-like bloat; the 2026-06-07 outage
#      root cause). `bd flatten` (OPT-IN: FLATTEN_ENABLED=1, weekly, off-peak) collapses
#      history so chunks freed by prune can GC off DISK. Flatten is HEAVY and
#      IRREVERSIBLE (destroys all Dolt commit history / time-travel) — DEFAULT OFF,
#      backup-gated, at most once per ISO-week inside a quiet local-hour window.
#
# Size-triggered gc (not pure time) self-adjusts to the bloat rate and never gc's a
# store that's already small. See memory: gate-reviewer-spawn-failure-playbook,
# post-outage-remaining-tech-debt, dolt-cpu-root-is-poll-frequency-not-query-ftmci.
#
# ── ENABLE (Mayor reviews the dry-run, then turns it on) ────────────────────────
# The prune/flatten schedule is STAGED OFF. Enable with a LOCAL (gitignored) toggle —
# takes effect on the next 2h cycle, NO launchd reload, NO code change:
#
#   mkdir -p /Users/athos/gt/.gascity-gastown-hq/.gc/config
#   printf 'PRUNE_ENABLED=1\n' \
#     > /Users/athos/gt/.gascity-gastown-hq/.gc/config/dolt-maintenance.env
#
# Optional deep on-disk reclaim (irreversible history loss): also add FLATTEN_ENABLED=1.
# Tune with PRUNE_KEEP_DAYS / PRUNE_MAX_PER_RUN in that same file.
# Disable: delete the file (or set PRUNE_ENABLED=0). Precedence: file > env > default.
#
# ── TEST (no Dolt, no deletions) ────────────────────────────────────────────────
#   bash scripts/dolt-gc-maintenance.selftest.sh   # unit-tests the decision logic
# Library mode: `DOLT_GC_MAINT_LIB=1 source dolt-gc-maintenance.sh` defines the pure
# decision functions WITHOUT running the maintenance flow.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
DB="hq"
PORT="52756"
THRESHOLD_G="1"            # online gc when hq store >= 1 GB (ga-ftmci: re-bloats fast;
                           # a bigger store slows the per-rig reconcile full-table scan).
LOG="${DOLT_GC_MAINT_LOG:-$CITY/.gc/logs/dolt-gc-maintenance.log}"
NOTIFY="/Users/athos/.local/bin/notify"
DOLTDIR="$CITY/.beads/dolt/$DB"
BD="$(command -v bd 2>/dev/null || echo /Users/athos/.local/bin/bd)"

# ── non-ephemeral PRUNE knobs (all default-safe; operator file overrides below) ──
PRUNE_ENABLED="${PRUNE_ENABLED:-0}"                 # 0 = STAGED OFF (the Mayor enables)
PRUNE_KEEP_DAYS="${PRUNE_KEEP_DAYS:-3}"             # keep closed non-ephemeral beads this long
PRUNE_MAX_PER_RUN="${PRUNE_MAX_PER_RUN:-3000}"      # per-run deletion CEILING (CPU-spike guard)
PRUNE_STORES="${PRUNE_STORES:-$CITY:hq}"            # space-sep "bd_dir:db" pairs; default hq only.
                                                    # db names the backup-staging + jsonl-archive
                                                    # subdir (hq's bd dir basename != its db name).
                                                    # Add rigs e.g. "/path/to/rig:property_scrapers".
PRUNE_SKIP_CPU_PCT="${PRUNE_SKIP_CPU_PCT:-150}"     # skip prune if dolt %cpu above this
PRUNE_REQUIRE_BACKUP="${PRUNE_REQUIRE_BACKUP:-1}"   # 1 = require a same-day backup first
PRUNE_BACKUP_MAX_AGE_H="${PRUNE_BACKUP_MAX_AGE_H:-26}"
BACKUP_STAGING="${BACKUP_STAGING:-$CITY/.dolt-backup}"

# ── weekly FLATTEN knobs (deep on-disk reclaim; IRREVERSIBLE history loss) ───────
FLATTEN_ENABLED="${FLATTEN_ENABLED:-0}"
FLATTEN_STORES="${FLATTEN_STORES:-$CITY:hq}"        # "bd_dir:db" pairs (see PRUNE_STORES)
FLATTEN_QUIET_START="${FLATTEN_QUIET_START:-3}"     # local-hour window start (inclusive)
FLATTEN_QUIET_END="${FLATTEN_QUIET_END:-7}"         # local-hour window end   (exclusive)
FLATTEN_WEEK_SENTINEL="${FLATTEN_WEEK_SENTINEL:-$CITY/.gc/logs/.dolt-flatten.week}"

# ── operator override file (LOCAL, gitignored) — THE enable point (file wins) ───
DOLT_MAINT_CONF="${DOLT_MAINT_CONF:-$CITY/.gc/config/dolt-maintenance.env}"
# shellcheck disable=SC1090
[ -f "$DOLT_MAINT_CONF" ] && . "$DOLT_MAINT_CONF"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# optional shared Dolt-health probe (reuse gc-dolt-probe.sh; fall back to ps)
_PROBE="$CITY/scripts/gc-dolt-probe.sh"
# shellcheck disable=SC1090
[ -f "$_PROBE" ] && . "$_PROBE" 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTIONS — unit-tested by dolt-gc-maintenance.selftest.sh.
# No side effects; the read-only counter is injectable (stubbed in the selftest).
# ════════════════════════════════════════════════════════════════════════════════

# _dolt_cpu_pct → integer dolt %cpu, or "" if unknown. Never hangs (ps is local).
_dolt_cpu_pct() {
  local c
  if declare -f _gc_dolt_cpu_pct >/dev/null 2>&1; then
    c="$(_gc_dolt_cpu_pct)"
  else
    local pid; pid="$(pgrep -f 'dolt sql-server' 2>/dev/null | head -1 || true)"
    [ -z "$pid" ] && { echo ""; return; }
    c="$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')"
  fi
  # strip the fractional part — ps renders it with a LOCALE decimal separator
  # ('.' OR ',', e.g. "62,4" under pt_BR). Both must reduce to a bare integer, else
  # the numeric guard in _should_skip_hot rejects "62,4" and fails open → the hot-check
  # would never fire (it wouldn't skip even at 194%). Handle both separators.
  case "$c" in ''|'?') echo ""; return ;; esac
  c="${c%%.*}"; c="${c%%,*}"; echo "$c"
}

# _should_skip_hot <cpu_pct> <threshold> → 0 = skip (hot), 1 = proceed.
# Empty/unknown cpu → proceed (fail-open; the health probe is the harder gate).
_should_skip_hot() {
  local cpu="$1" thr="$2"
  case "$cpu" in ''|*[!0-9]*) return 1 ;; esac
  [ "$cpu" -gt "$thr" ]
}

# _backup_fresh <staging_dir> <db> <max_age_h> → 0 if <staging_dir>/<db> was written
# within max_age_h. Belt: a bad prune is recoverable from this S3-staged backup (plus
# the jsonl-archive prune writes on every delete).
_backup_fresh() {
  local dir="$1/$2" max_h="$3"
  [ -d "$dir" ] || return 1
  [ -n "$(find "$dir" -maxdepth 0 -mmin -"$(( max_h * 60 ))" 2>/dev/null)" ]
}

# _prune_dryrun_count <dir> <age_days> → candidate count (0 if none). READ-ONLY
# (`bd prune --dry-run` makes no changes). Overridden with a stub in the selftest.
_prune_dryrun_count() {
  local dir="$1" age="$2" out n
  out="$(timeout 120 "$BD" -C "$dir" prune --older-than "${age}d" --dry-run 2>/dev/null)"
  n="$(printf '%s' "$out" | grep -oE 'Would prune [0-9]+' | awk '{print $3}' | head -1)"
  case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

# _prune_plan <dir> <keep_days> <cap> → echoes "VERB AGE COUNT":
#   NOOP 0 0          nothing closed older than keep_days
#   PRUNE <keep> <n>  n<=cap → prune the full keep-window in one bounded pass (steady state)
#   BATCH <age> <n>   backlog>cap → prune the OLDEST slice that fits under cap; the
#                     remainder drains over subsequent 2h cycles (oldest-first)
#   OVERCAP 0 <n>     even the oldest slice exceeds cap → SKIP + escalate (never run a
#                     catastrophic single delete transaction)
_prune_plan() {
  local dir="$1" keep="$2" cap="$3" c f age cc
  c="$(_prune_dryrun_count "$dir" "$keep")"
  [ "$c" -eq 0 ] && { echo "NOOP 0 0"; return; }
  if [ "$c" -le "$cap" ]; then echo "PRUNE $keep $c"; return; fi
  # backlog > cap: walk ages upward (fewer beads as the window narrows to the oldest);
  # the first slice at/under cap wins → prune oldest-first, bounded.
  for f in 2 3 4 6 8 12; do
    age=$(( keep * f )); cc="$(_prune_dryrun_count "$dir" "$age")"
    if [ "$cc" -gt 0 ] && [ "$cc" -le "$cap" ]; then echo "BATCH $age $cc"; return; fi
  done
  echo "OVERCAP 0 $c"
}

# _flatten_due <sentinel> <enabled> <qstart> <qend> <now_hour> <now_week> → 0 if due.
# At most once per ISO-week, only inside the quiet local-hour window. The sentinel
# stores the last week flatten ran.
_flatten_due() {
  local sentinel="$1" enabled="$2" qs="$3" qe="$4" hr="$5" wk="$6" last=""
  [ "$enabled" = "1" ] || return 1
  { [ "$hr" -ge "$qs" ] && [ "$hr" -lt "$qe" ]; } || return 1
  [ -f "$sentinel" ] && last="$(cat "$sentinel" 2>/dev/null)"
  [ "$last" != "$wk" ]
}

# ════════════════════════════════════════════════════════════════════════════════
# EXECUTION (side-effecting; NOT exercised by the selftest)
# ════════════════════════════════════════════════════════════════════════════════

# _parse_pair <dir:db> → sets globals _PAIR_DIR, _PAIR_DB. A bare "dir" (no colon)
# falls back to db=basename(dir) — correct for rigs, but hq MUST use "$CITY:hq".
_parse_pair() {
  local p="$1"; _PAIR_DIR="${p%%:*}"; _PAIR_DB="${p#*:}"
  [ "$_PAIR_DB" = "$p" ] && _PAIR_DB="$(basename "${_PAIR_DIR%/}")"
}

_run_prune() {
  # skip-when-hot: never pile a delete onto an already-stressed Dolt.
  local cpu; cpu="$(_dolt_cpu_pct)"
  if _should_skip_hot "$cpu" "$PRUNE_SKIP_CPU_PCT"; then
    log "prune SKIP — dolt cpu=${cpu}% > ${PRUNE_SKIP_CPU_PCT}% (retry next 2h cycle)"; return 0
  fi
  # skip-unless-healthy: prune is a WRITE; only run when Dolt is confirmed healthy.
  if declare -f gc_dolt_probe >/dev/null 2>&1; then
    if ! gc_dolt_probe; then log "prune SKIP — dolt not confirmed-healthy (retry next 2h cycle)"; return 0; fi
  fi
  local pair dir store plan verb age cnt
  for pair in $PRUNE_STORES; do
    _parse_pair "$pair"; dir="$_PAIR_DIR"; store="$_PAIR_DB"
    if [ "$PRUNE_REQUIRE_BACKUP" = "1" ] && ! _backup_fresh "$BACKUP_STAGING" "$store" "$PRUNE_BACKUP_MAX_AGE_H"; then
      log "prune SKIP ${store} — no backup within ${PRUNE_BACKUP_MAX_AGE_H}h (waiting for daily backup; jsonl-archive belt still applies)"; continue
    fi
    plan="$(_prune_plan "$dir" "$PRUNE_KEEP_DAYS" "$PRUNE_MAX_PER_RUN")"
    verb="${plan%% *}"; age="$(echo "$plan" | awk '{print $2}')"; cnt="$(echo "$plan" | awk '{print $3}')"
    case "$verb" in
      NOOP)
        log "prune ${store}: 0 closed non-ephemeral beads >${PRUNE_KEEP_DAYS}d — nothing to do" ;;
      PRUNE|BATCH)
        log "prune ${store}: ${verb} ${cnt} closed non-ephemeral bead(s) >${age}d (cap=${PRUNE_MAX_PER_RUN}) …"
        if "$BD" -C "$dir" prune --older-than "${age}d" --force >> "$LOG" 2>&1; then
          log "prune ${store}: OK (${cnt} pruned >${age}d; archived to jsonl-archive/${store})"
        else
          log "prune ${store}: FAILED"
          "$NOTIFY" -t "Dolt prune" -p 4 "🚨 bd prune FALHOU em ${store} — verificar" 2>/dev/null || true
        fi
        [ "$verb" = "BATCH" ] && log "prune ${store}: backlog batch — remainder drains next 2h cycle" ;;
      OVERCAP)
        log "prune ${store}: OVERCAP — ${cnt} closed beads exceed cap ${PRUNE_MAX_PER_RUN} at every age slice; SKIP + escalate"
        "$NOTIFY" -t "Dolt prune" -p 4 "⚠️ prune backlog em ${store}: ${cnt} > cap ${PRUNE_MAX_PER_RUN} em todas as fatias — revisar manualmente" 2>/dev/null || true ;;
    esac
  done
}

_run_flatten() {
  local hr wk; hr="$(date '+%H')"; hr="$((10#$hr))"; wk="$(date '+%G-%V')"
  _flatten_due "$FLATTEN_WEEK_SENTINEL" "$FLATTEN_ENABLED" "$FLATTEN_QUIET_START" "$FLATTEN_QUIET_END" "$hr" "$wk" || return 1
  local pair dir store attempted=0 did=0
  for pair in $FLATTEN_STORES; do
    _parse_pair "$pair"; dir="$_PAIR_DIR"; store="$_PAIR_DB"
    # flatten is IRREVERSIBLE — a fresh backup is MANDATORY. If none, retry next cycle.
    if ! _backup_fresh "$BACKUP_STAGING" "$store" "$PRUNE_BACKUP_MAX_AGE_H"; then
      log "flatten SKIP ${store} — no backup within ${PRUNE_BACKUP_MAX_AGE_H}h (mandatory before irreversible flatten; retry next cycle)"; continue
    fi
    attempted=1
    log "flatten ${store}: weekly history-collapse (IRREVERSIBLE) …"
    if "$BD" -C "$dir" flatten --force >> "$LOG" 2>&1; then
      log "flatten ${store}: OK"; did=1
    else
      log "flatten ${store}: FAILED"
      "$NOTIFY" -t "Dolt flatten" -p 4 "🚨 bd flatten FALHOU em ${store}" 2>/dev/null || true
    fi
  done
  # Only mark the week done once we actually TRIED (avoids skipping the whole week when
  # the backup merely wasn't ready yet; avoids retry storms on repeated hard failure).
  [ "$attempted" = "1" ] && { echo "$wk" > "$FLATTEN_WEEK_SENTINEL" 2>/dev/null || true; }
  [ "$did" = "1" ]
}

# ── main flow ────────────────────────────────────────────────────────────────────
main() {
  # 1) EPHEMERAL PURGE (always) — unchanged behavior.
  if [ -x "$BD" ]; then
    local purged
    purged="$("$BD" -C "$CITY" purge --older-than 2h --force 2>/dev/null | grep -oE 'Purged [0-9]+' | awk '{print $2}')"
    [ -n "${purged:-}" ] && [ "$purged" != "0" ] && log "purged ${purged} closed ephemeral bead(s) (>2h)"
  else
    log "WARN: bd not found — skipped ephemeral purge"
  fi

  # 2) NON-EPHEMERAL PRUNE (opt-in) — the row-count fix for the 2026-07-02 gate stall.
  if [ "$PRUNE_ENABLED" = "1" ]; then
    if [ -x "$BD" ]; then _run_prune; else log "WARN: bd not found — skipped prune"; fi
  fi

  # 3) weekly FLATTEN (opt-in, deep reclaim) — does its own gc; skip the size-gc if it ran.
  local flattened=1
  if [ "$FLATTEN_ENABLED" = "1" ] && [ -x "$BD" ]; then _run_flatten; flattened=$?; fi
  if [ "$flattened" -eq 0 ]; then log "size-gc skipped — flatten already reclaimed this run"; return 0; fi

  # 4) ONLINE size-gated dolt_gc (always) — unchanged behavior.
  local size_g; size_g="$(du -sg "$DOLTDIR" 2>/dev/null | awk '{print $1}')"
  case "$size_g" in ''|*[!0-9]*) size_g=0 ;; esac
  if [ "$size_g" -lt "$THRESHOLD_G" ]; then
    log "hq=${size_g}G < ${THRESHOLD_G}G threshold — skip gc"; return 0
  fi
  local pre; pre="$(du -sh "$DOLTDIR" 2>/dev/null | awk '{print $1}')"
  log "hq=${pre} >= ${THRESHOLD_G}G — running online dolt_gc ..."
  if DOLT_CLI_PASSWORD='' timeout 300 dolt --host 127.0.0.1 --port "$PORT" --user root --no-tls \
       sql -q "USE \`$DB\`; CALL dolt_gc();" >> "$LOG" 2>&1; then
    local post; post="$(du -sh "$DOLTDIR" 2>/dev/null | awk '{print $1}')"
    log "dolt_gc OK — hq ${pre} -> ${post}"
  else
    local rc=$?
    log "dolt_gc FAILED (rc=$rc)"
    "$NOTIFY" -t "Dolt gc" -p 4 "🚨 Manutenção dolt gc FALHOU (rc=$rc) — store em ${pre}, verificar antes de re-inchar" 2>/dev/null || true
  fi
  return 0
}

# ── run unless sourced as a library (selftest sources with DOLT_GC_MAINT_LIB=1) ──
if [ "${DOLT_GC_MAINT_LIB:-0}" != "1" ]; then
  main
  exit 0
fi
