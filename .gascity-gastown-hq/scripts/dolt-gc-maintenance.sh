#!/bin/bash
# dolt-gc-maintenance.sh — keeps the city's hq beads store lean automatically.
#
# THREE independently-gated layers of upkeep. Mostly SILENT on success (Athos
# preference) — FAILURE always notifies, and (ga-azzfw) a sustained headroom-skip
# streak or a no-effect gc run also notify. Run by launchd every 2h.
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
#      ga-sfj3i.4: the size-gated dolt_gc() call is now ALSO gated on disk headroom
#      (GC_MIN_FREE_PCT, 200-280% of hq's own on-disk size depending on
#      PRUNE_ENABLED — see GC_MIN_FREE_PCT_BASE/_WITH_PRUNE and
#      _gc_headroom_ok/_gc_floor_ok below for the measured basis; ga-3euoj
#      re-calibrated the flat 250% default after hq's growth made it permanently
#      unreachable). Before this fix it had ZERO disk-space
#      awareness and ran unconditionally every 2h whenever hq>=THRESHOLD_G (i.e.
#      continuously, since hq is essentially always over that floor) — a
#      disk-exhausted dolt_gc mid-store-rewrite can panic the WHOLE Dolt server
#      (all databases, not just hq), see ga-vs55. This step also has NO awareness
#      of hq's own compact-quarantine marker (a separate, narrower concern about
#      post-FLATTEN integrity verification that a bare dolt_gc() — no flatten
#      involved — does not share; deliberately left alone here, out of scope for
#      this fix).
#
#      ga-azzfw: the headroom skip above is now ALSO tracked as a consecutive-cycle
#      streak (GC_SKIP_STREAK_STATE) — 3 in a row (~6h @ 2h cadence) notifies + mails
#      the Mayor ONCE per streak, so a stuck skip can't go unnoticed for days the way
#      it did in ga-3euoj (found only by manual investigation, after disk had already
#      touched Dolt's CRITICAL floor twice). The streak clears the moment dolt_gc() is
#      next ATTEMPTED (success or failure — a SQL failure is a separate, already-
#      alerted condition). A dolt_gc() that runs to completion but reclaims no space
#      (post>=pre) is also flagged, once per occurrence — see _handle_gc_skip_streak
#      and _gc_no_effect below.
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
# ga-3euoj: GC_MIN_FREE_PCT's default depends on PRUNE_ENABLED — resolved in main()
# via _resolve_gc_min_free_pct, once PRUNE_ENABLED/the conf file below are final. An
# explicit pin here (env or the operator conf file) still wins outright either way.
GC_MIN_FREE_PCT_BASE="${GC_MIN_FREE_PCT_BASE:-200}"  # ga-3euoj: measured — of 665 real
                           # online dolt_gc() runs on hq with no prune batch in the same
                           # cycle (2026-06-08..09-05, hq 483MB..10GB, under normal
                           # concurrent city write load), the worst post/pre ratio EVER
                           # observed was exactly 1.000 (store never grew) — matching
                           # _gc_headroom_ok's documented 2x/"nothing collected"
                           # worst-case bound with zero real violations.
GC_MIN_FREE_PCT_WITH_PRUNE="${GC_MIN_FREE_PCT_WITH_PRUNE:-280}"  # ga-3euoj: of 235 runs
                           # where a prune BATCH ran in the same invocation right before
                           # dolt_gc() (deletes are new commits; nothing collects their
                           # garbage yet), the store grew PAST its pre-gc size twice —
                           # worst ratio 1.7358 (2026-07-25, 2026-08-16) = 273.6%
                           # implied peak, breaking the "post<=pre" assumption the base
                           # bound above relies on. 280 covers that with a small margin;
                           # applies only while PRUNE_ENABLED=1 can produce that burst.
GC_MIN_FREE_ABS_MB="${GC_MIN_FREE_ABS_MB:-3072}"  # ga-3euoj: absolute floor alongside
                           # the percentage gate — never let dolt_gc()'s worst-case
                           # extra disk use (up to size_mb) push avail below Dolt's
                           # CRITICAL level (3GB: a disk-exhausted GC mid-rewrite can
                           # panic the WHOLE server, not just hq — ga-vs55). The
                           # percentage alone only guarantees this by coincidence while
                           # hq is big; see _gc_floor_ok below.
GC_SKIP_ALERT_THRESHOLD="${GC_SKIP_ALERT_THRESHOLD:-3}"  # ga-azzfw: consecutive
                           # headroom-skip CYCLES (2h launchd cadence, so 3 = ~6h)
                           # before alerting the Mayor. The ga-3euoj incident skipped
                           # silently for DAYS because the skip line only reaches a log
                           # nobody reads — this makes that "if it skips again, reopen"
                           # criterion automatic instead of depending on a human read.
                           # One alert per STREAK, not one per cycle past the
                           # threshold — see _skip_streak_next.
GC_SKIP_STREAK_STATE="${GC_SKIP_STREAK_STATE:-$CITY/.gc/runtime/packs/maintenance/dolt-gc-skip-streak.state}"
LOG="${DOLT_GC_MAINT_LOG:-$CITY/.gc/logs/dolt-gc-maintenance.log}"
NOTIFY="/Users/athos/.local/bin/notify"
DOLTDIR="$CITY/.beads/dolt/$DB"
BD="$(command -v bd 2>/dev/null || echo /Users/athos/.local/bin/bd)"
GC="${GC_BIN:-gc}"  # ga-azzfw: mirrors dolt-disk-floor-guard.sh / dolt-compact-routine.sh —
                    # used only for `gc mail send mayor` (skip-streak + no-effect alerts
                    # below); this script had no mail dependency before.

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

# _avail_mb [path] — free space in MB, empty (not 0) on failure. Same idiom as
# dolt-compact-routine.sh's own _avail_mb (`df -k` + one division; macOS/BSD df
# has no -g) — matched deliberately for consistency across this codebase's two
# dolt-gc-adjacent scripts. Empty, not 0: a failed read must never read the
# same as "plenty of room" (error and empty must not produce the same value).
_avail_mb() {
  local path="${1:-$DOLTDIR}" kb
  kb="$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
  case "$kb" in ''|*[!0-9]*) echo ""; return ;; esac
  echo $(( kb / 1024 ))
}

# _gc_headroom_ok <avail_mb> <db_size_mb> <pct> → 0 = enough room to run
# dolt_gc(), 1 = not enough (or unmeasurable — fail-closed). Pure arithmetic,
# same shape as dolt-compact-routine.sh's _headroom_ok.
#
# ga-sfj3i.4: measured 2026-08-26 (isolated copy of gastown, flattened then
# `dolt gc --full`, disk usage polled every ~0.1s during the call): peak
# disk usage during gc tracked pre-gc-size + the size of the live data being
# rewritten into the new generation (peak=38376KB, pre-gc=35228KB,
# live-after-gc=3180KB; 35228+3180=38408, matches within sampling noise).
# Live data can never exceed the pre-gc size, so that additive relationship
# bounds the worst case (a db with nothing to collect as garbage) at 2x
# pre-gc size. ga-3euoj: GC_MIN_FREE_PCT is no longer a flat 250 — see
# GC_MIN_FREE_PCT_BASE / _WITH_PRUNE above and _resolve_gc_min_free_pct below
# for the measured, prune-conditional replacement.
_gc_headroom_ok() {
  local avail="$1" size="$2" pct="$3"
  case "$avail" in ''|*[!0-9]*) return 1 ;; esac
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  case "$pct" in ''|*[!0-9]*) return 1 ;; esac
  [ "$avail" -ge $(( size * pct / 100 )) ]
}

# _gc_floor_ok <avail_mb> <size_mb> <abs_floor_mb> → 0 = the CRITICAL floor (ga-vs55:
# a disk-exhausted dolt_gc() mid-rewrite can panic the WHOLE Dolt server) survives even
# in _gc_headroom_ok's own worst case (post_gc_size == size_mb, i.e. nothing collected).
# ga-3euoj: makes that floor an explicit, always-enforced invariant instead of an
# accident of hq's current (large) size — GC_MIN_FREE_PCT_BASE alone only guarantees it
# while size_mb is already well above abs_floor_mb (true today at ~6-7GB vs 3GB, false
# once hq is small, e.g. right after a real GC succeeds). ANDed with _gc_headroom_ok in
# main() — neither check alone is sufficient.
_gc_floor_ok() {
  local avail="$1" size="$2" floor="$3"
  case "$avail" in ''|*[!0-9]*) return 1 ;; esac
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  case "$floor" in ''|*[!0-9]*) return 1 ;; esac
  [ "$avail" -ge $(( size + floor )) ]
}

# _resolve_gc_min_free_pct <pinned> <prune_enabled> <base> <with_prune> → echoes the
# GC_MIN_FREE_PCT to use. <pinned> is whatever GC_MIN_FREE_PCT held BEFORE this
# resolution runs (env var or the operator conf file — either wins outright, matching
# this script's documented "file > env > default" precedence); empty means neither set
# it. ga-3euoj: kept separate from _gc_headroom_ok's own worst-case-bound rationale
# because the two measured defaults (base/with_prune, declared near GC_MIN_FREE_PCT
# above) come from DIFFERENT empirical cohorts — a prune batch running in the same
# maintenance-cycle invocation is what actually broke the "post<=pre" assumption in
# real logs, not hq's size or age.
_resolve_gc_min_free_pct() {
  local pinned="$1" prune_enabled="$2" base="$3" with_prune="$4"
  if [ -n "$pinned" ]; then echo "$pinned"; return; fi
  if [ "$prune_enabled" = "1" ]; then echo "$with_prune"; else echo "$base"; fi
}

# _skip_streak_parse <line> → echoes "COUNT ALERTED", defaulting to "0 0" for a missing
# or corrupt state line. Fail-SAFE, not fail-closed like _avail_mb/_gc_headroom_ok:
# this counter only ever drives a notify, never a destructive action, so misreading
# corrupt state as "no streak yet" costs one delayed alert at worst — never data loss.
_skip_streak_parse() {
  local line="${1:-}" count alerted
  count="${line%% *}"
  alerted="${line##* }"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$alerted" in 0|1) ;; *) alerted=0 ;; esac
  echo "$count $alerted"
}

# _skip_streak_next <prev_count> <prev_alerted> <threshold> → echoes "NEW_COUNT
# NEW_ALERTED SHOULD_ALERT" for one more consecutive headroom-skip cycle. SHOULD_ALERT
# is 1 only the FIRST cycle the streak reaches <threshold> (prev_alerted still 0) —
# never again while the SAME streak continues, so a stuck skip doesn't re-notify every
# 2h (ga-azzfw: "um alerta por sequência, sem repetir a cada ciclo").
_skip_streak_next() {
  local prev_count="$1" prev_alerted="$2" thr="$3" new_count should new_alerted
  case "$prev_count" in ''|*[!0-9]*) prev_count=0 ;; esac
  new_count=$(( prev_count + 1 ))
  should=0
  new_alerted="$prev_alerted"
  if [ "$new_count" -ge "$thr" ] && [ "$prev_alerted" != "1" ]; then
    should=1
    new_alerted=1
  fi
  echo "$new_count $new_alerted $should"
}

# _gc_no_effect <pre_mb> <post_mb> → 0 (true) when a dolt_gc() call that ran to
# completion reclaimed NO space (post >= pre) — ga-azzfw requirement 4 ("GC roda mas o
# hq não encolhe"). Fail-OPEN (never flag) on unmeasurable input: this is a notify-only
# signal, not a safety gate, and a `du` misread shouldn't cry wolf.
_gc_no_effect() {
  local pre="$1" post="$2"
  case "$pre" in ''|*[!0-9]*) return 1 ;; esac
  case "$post" in ''|*[!0-9]*) return 1 ;; esac
  [ "$post" -ge "$pre" ]
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

# ── skip-streak state I/O + alert helpers (ga-azzfw) ────────────────────────────────
_read_skip_streak() {
  local f="$1" line=""
  [ -f "$f" ] && line="$(cat "$f" 2>/dev/null)"
  _skip_streak_parse "$line"
}

_write_skip_streak() {
  local f="$1" count="$2" alerted="$3"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  # Third-state note: a write failure here (disk full, permissions) is
  # swallowed, same as every other external write in this file (log(),
  # notify, mail — all `2>/dev/null || true`). Worst case it silently stalls
  # THIS counter at its last-written value, so it never reaches the alert
  # threshold — but it is not this feature's only safety net: the underlying
  # disk condition is independently covered by dolt-disk-floor-guard.sh's own
  # CRITICAL-floor alerting, which does not depend on this state file at all.
  printf '%s %s\n' "$count" "$alerted" > "$f" 2>/dev/null || true
}

# _dolt_gc_notify <title> <priority> <message> — thin $NOTIFY wrapper so the selftest
# can redefine it instead of a real push firing (same idiom this file already uses for
# _prune_dryrun_count; see memory mutation-check-notify-code-neutralize).
_dolt_gc_notify() {
  "$NOTIFY" -t "$1" -p "$2" "$3" 2>/dev/null || true
}

# _dolt_gc_mail_mayor <subject> <body> — thin `gc mail send mayor` wrapper, same
# redefine-in-selftest idiom as _dolt_gc_notify.
_dolt_gc_mail_mayor() {
  ( cd "$CITY" && GC_CITY="$CITY" "$GC" mail send mayor -s "$1" -m "$2" >/dev/null 2>&1 ) || true
}

# _clear_skip_streak <state_file> <log_context> — resets the skip-streak counter to
# "0 0", logging only when it actually had something to clear (silent on the common
# already-zero path). Called from every NON-headroom-skip exit of the size-gc flow so a
# stale streak from days ago can't resurface after an unrelated cycle in between
# (ga-azzfw requirement 3, read as "whenever this cycle is not itself a headroom skip").
_clear_skip_streak() {
  local f="$1" ctx="$2" prev prev_count
  prev="$(_read_skip_streak "$f")"
  prev_count="${prev%% *}"
  [ "$prev_count" != "0" ] && log "dolt_gc skip streak cleared (was ${prev_count}) — ${ctx}"
  _write_skip_streak "$f" 0 0
}

# _handle_gc_skip_streak <size_mb> <avail_mb> <required_mb> — increments the persisted
# consecutive-headroom-skip counter, alerts (notify + mail mayor) the FIRST cycle it
# reaches GC_SKIP_ALERT_THRESHOLD, and always logs the running count. Called only from
# the headroom-skip branch of main() (ga-azzfw requirements 1+2).
_handle_gc_skip_streak() {
  local size_mb="$1" avail_mb="$2" required_mb="$3"
  local prev prev_count prev_alerted
  prev="$(_read_skip_streak "$GC_SKIP_STREAK_STATE")"
  prev_count="${prev%% *}"
  prev_alerted="$(echo "$prev" | awk '{print $2}')"
  local next new_count new_alerted should_alert
  next="$(_skip_streak_next "$prev_count" "$prev_alerted" "$GC_SKIP_ALERT_THRESHOLD")"
  new_count="${next%% *}"
  new_alerted="$(echo "$next" | awk '{print $2}')"
  should_alert="$(echo "$next" | awk '{print $3}')"
  _write_skip_streak "$GC_SKIP_STREAK_STATE" "$new_count" "$new_alerted"
  local hrs=$(( new_count * 2 ))
  log "dolt_gc skip streak: ${new_count} consecutive headroom-skip cycle(s) (~${hrs}h @ 2h cadence)"
  [ "$should_alert" != "1" ] && return 0
  local mail_body="dolt-gc-maintenance: hq's online dolt_gc() has been skipped for insufficient headroom ${new_count} consecutive cycles in a row (~${hrs}h at the 2h launchd cadence).

Latest reading: size=${size_mb:-<unmeasured>}MB avail=${avail_mb:-<unmeasured>}MB required=${required_mb:-<unmeasured>}MB.

This is the exact silent-stall shape behind ga-3euoj: the skip line only reached the
log file, which nobody reads, and the gate stayed unreachable for days while disk
approached Dolt's CRITICAL floor (ga-vs55) twice. One alert per streak — this will not
repeat until the streak clears (an attempted dolt_gc) and later re-crosses the threshold."
  _dolt_gc_notify "Dolt GC" 4 "🚨 dolt_gc pulando por falta de espaço há ${new_count} ciclos seguidos (~${hrs}h) — hq=${size_mb:-?}MB avail=${avail_mb:-?}MB required=${required_mb:-?}MB"
  _dolt_gc_mail_mayor "Dolt GC: ${new_count} skips consecutivos por headroom" "$mail_body"
  log "ALERT: dolt_gc skip streak reached ${GC_SKIP_ALERT_THRESHOLD}+ — notified mayor (notify + mail)"
}

# ── main flow ────────────────────────────────────────────────────────────────────
main() {
  # ga-3euoj: resolve GC_MIN_FREE_PCT now that PRUNE_ENABLED + any operator pin (env
  # or the conf file sourced above) are final. Kept inside main() (not top-level) so
  # the selftest — which sources this file as a library and never calls main() — can
  # exercise _resolve_gc_min_free_pct directly with whatever inputs each test wants,
  # rather than being stuck with one value baked in at source-time.
  GC_MIN_FREE_PCT="$(_resolve_gc_min_free_pct "${GC_MIN_FREE_PCT:-}" "$PRUNE_ENABLED" "$GC_MIN_FREE_PCT_BASE" "$GC_MIN_FREE_PCT_WITH_PRUNE")"

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
  if [ "$flattened" -eq 0 ]; then
    log "size-gc skipped — flatten already reclaimed this run"
    _clear_skip_streak "$GC_SKIP_STREAK_STATE" "flatten already reclaimed this run"
    return 0
  fi

  # 4) ONLINE size-gated dolt_gc (always). size_mb replaces the old bare
  # `du -sg` read (same truncated-whole-GB value via integer division, so
  # the THRESHOLD_G comparison below is unchanged) — MB precision is what
  # the new headroom check below needs; see _largest_db_mb's own comment in
  # dolt-compact-routine.sh for why whole-GB truncation is unsafe for a
  # multiplier computation.
  local size_mb; size_mb="$(du -sm "$DOLTDIR" 2>/dev/null | awk '{print $1}')"
  case "$size_mb" in ''|*[!0-9]*) size_mb="" ;; esac
  local size_g=$(( ${size_mb:-0} / 1024 ))
  if [ "$size_g" -lt "$THRESHOLD_G" ]; then
    log "hq=${size_g}G < ${THRESHOLD_G}G threshold — skip gc"
    _clear_skip_streak "$GC_SKIP_STREAK_STATE" "hq below ${THRESHOLD_G}G threshold"
    return 0
  fi

  # ga-sfj3i.4 / ga-3euoj: disk headroom gate — TWO independent checks, both must
  # pass: _gc_headroom_ok (percentage of size, prune-conditional — see
  # GC_MIN_FREE_PCT_BASE/_WITH_PRUNE above) and _gc_floor_ok (absolute Dolt-CRITICAL
  # floor — see GC_MIN_FREE_ABS_MB above). Always logs the numbers when size measures,
  # including on runs that proceed, so headroom stays visible in the log.
  local avail_mb; avail_mb="$(_avail_mb "$DOLTDIR")"
  local required_pct_mb="" required_floor_mb="" required_mb=""
  if [ -n "$size_mb" ]; then
    required_pct_mb=$(( size_mb * GC_MIN_FREE_PCT / 100 ))
    required_floor_mb=$(( size_mb + GC_MIN_FREE_ABS_MB ))
    required_mb=$required_pct_mb
    [ "$required_floor_mb" -gt "$required_mb" ] && required_mb=$required_floor_mb
  fi
  log "hq disk headroom check: size=${size_mb:-<unmeasured>}MB avail=${avail_mb:-<unmeasured>}MB required=${required_mb:-<unmeasured>}MB (max of ${GC_MIN_FREE_PCT}% size=${required_pct_mb:-<unmeasured>}MB, size+${GC_MIN_FREE_ABS_MB}MB floor=${required_floor_mb:-<unmeasured>}MB)"
  if ! _gc_headroom_ok "$avail_mb" "$size_mb" "$GC_MIN_FREE_PCT" || ! _gc_floor_ok "$avail_mb" "$size_mb" "$GC_MIN_FREE_ABS_MB"; then
    log "hq size=${size_mb:-<unmeasured>}MB avail=${avail_mb:-<unmeasured>}MB required=${required_mb:-<unmeasured>}MB — insufficient free space (or unmeasurable) for dolt_gc — skip this cycle, will retry in 2h"
    _handle_gc_skip_streak "$size_mb" "$avail_mb" "$required_mb"
    return 0
  fi

  local pre; pre="$(du -sh "$DOLTDIR" 2>/dev/null | awk '{print $1}')"
  log "hq=${pre} >= ${THRESHOLD_G}G, headroom ok — running online dolt_gc ..."
  # ga-azzfw requirement 3: the headroom problem this cycle is resolved the moment we
  # reach an actual attempt, independent of whether the SQL call below then succeeds —
  # a transient dolt_gc() failure is a DIFFERENT, already-alerted condition (below) and
  # must not keep the (unrelated) skip-streak counter artificially elevated.
  _clear_skip_streak "$GC_SKIP_STREAK_STATE" "dolt_gc attempted"
  if DOLT_CLI_PASSWORD='' timeout 300 dolt --host 127.0.0.1 --port "$PORT" --user root --no-tls \
       sql -q "USE \`$DB\`; CALL dolt_gc();" >> "$LOG" 2>&1; then
    local post post_mb; post="$(du -sh "$DOLTDIR" 2>/dev/null | awk '{print $1}')"
    post_mb="$(du -sm "$DOLTDIR" 2>/dev/null | awk '{print $1}')"
    case "$post_mb" in ''|*[!0-9]*) post_mb="" ;; esac
    log "dolt_gc OK — hq ${pre} -> ${post}"
    # ga-azzfw requirement 4: dolt_gc() succeeded (rc=0) but reclaimed nothing. size_mb
    # is reused as "pre" here — it's the exact same pre-gc measurement the headroom
    # decision above was based on, not a fresh re-read that could drift from it.
    if _gc_no_effect "$size_mb" "$post_mb"; then
      log "dolt_gc had NO EFFECT — hq ${size_mb:-<unmeasured>}MB -> ${post_mb:-<unmeasured>}MB (not smaller)"
      _dolt_gc_notify "Dolt GC" 4 "⚠️ dolt_gc rodou mas hq não encolheu — ${size_mb:-?}MB -> ${post_mb:-?}MB"
      _dolt_gc_mail_mayor "Dolt GC: rodou sem efeito (hq ${size_mb:-?}MB -> ${post_mb:-?}MB)" "dolt-gc-maintenance: dolt_gc() ran to completion (rc=0) but hq's on-disk size did not shrink — ${size_mb:-<unmeasured>}MB before, ${post_mb:-<unmeasured>}MB after (ga-azzfw requirement 4).

Either there was nothing eligible to collect this cycle, or something is preventing
reclaim. Not necessarily an emergency by itself — but worth a look if it keeps
recurring, since the headroom gate above assumes a normal dolt_gc() brings the store
back down toward its live-data floor."
    fi
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
