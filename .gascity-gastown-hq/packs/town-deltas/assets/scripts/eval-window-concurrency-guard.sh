#!/usr/bin/env bash
# eval-window-concurrency-guard.sh — cap dog-pool / crew min_active / Dolt poll
# frequency during the 3 heaviest weekly routines, restore automatically after
# (ga-sb11i.2, slice 2/4 of epic ga-sb11i — machine resource pressure, no HW
# upgrade). Sibling ga-7xne1 owns rescheduling/staggering those same routines;
# this guard only caps concurrency during their (unmoved) fixed schedules.
#
# ── THE 3 NAMED WINDOWS ────────────────────────────────────────────────────────
#   com.lexbh.v_pipeline.weekly       Fridays  05:07 local, ~14min observed
#   com.whatsapp.eval-sampler-weekly  Mondays  09:17 local, a few seconds
#   com.gascity.quality-gate-eval     ~7d StartInterval (drifts), ~1s, advisory-
#                                     only (does NOT alter config/redispatch work
#                                     per its own script header) — included for
#                                     acceptance-criteria completeness, but its
#                                     own load contribution is negligible; its
#                                     window is predicted from its own log
#                                     mtime + 7d since it has no fixed clock time.
# The first two get generous, hand-picked calendar windows (pre-roll to be
# throttled BEFORE the job starts, post-roll well past its observed duration).
# See in_lexbh_window/in_whatsapp_window/in_qge_window below for exact bounds.
#
# ── WHAT GETS CAPPED (3 levers, 5 concrete values — see PROFILE VALUES) ────────
#   dog-pool      gastown.dog max_active_sessions   3 -> 1   (city.toml patch)
#   crew min_active  oracle-wa min_active_sessions  1 -> 0   (city.toml patch)
#     (oracle-wa is the ONLY agent in this city with min_active_sessions>0 as
#     of this writing — confirmed live via `gc config explain`; every other
#     crew/pool agent is already min=0, on-demand, nothing to reduce further)
#   Dolt poll     3 town-deltas order intervals widened ~2.5x (see orders/*.toml)
# Deliberately OUT OF SCOPE (do not extend this script to cover these):
#   - job scheduling/stagger (ga-7xne1's territory)
#   - the CachingStore adaptive reconcile cadence (30/60/120s) — confirmed via
#     source read: no config/env knob exists for it; changing it needs an
#     engine code change, which a dog does not do (pool:refused:engine-rebuild-
#     required territory) — this guard does not touch it.
#   - nudge_dispatcher (unrelated live tuning, out of this story's scope)
#   - force-killing already-running sessions — this only adjusts caps/floors
#     and widens poll intervals; existing in-flight work finishes naturally.
#
# ── MECHANISM ──────────────────────────────────────────────────────────────────
# Each pass (StartInterval, see .plist) computes the desired profile (normal vs
# throttled) from wall-clock time, compares to what's currently on disk, and if
# they differ, rewrites the 5 target value-lines in place (city.toml's managed
# [[patches.agent]] block + the 3 order files' `interval = `), then runs
# `gc reload --soft` exactly once. `--soft` is required — a bare `gc reload`
# triggers session drains on any config drift it detects on unrelated sessions
# (see the no-live-config-edit-without-soft-reload precedent); `--soft`
# rebaselines instead. Idempotent: re-running with no state change is a no-op
# (no reload call), so the 5-minute polling cadence never spam-reloads.
#
# ── SAFETY VALVES ─────────────────────────────────────────────────────────────
#   - Caps/floors only — never kills a live session, never touches job schedules.
#   - Every 5-target rewrite is a narrow, anchor-scoped in-place substitution
#     (perl -0777/-p), never a whole-file overwrite — safe even if unrelated
#     content is added to these files later by someone else.
#   - DRY_RUN=1: compute + log the decision, write NOTHING, call no reload
#     (used by the selftest and the supervised first run below).
#   - Kill-switch: .gc/state/eval-window-concurrency-guard.disabled present ->
#     no-op.
#   - Every `gc` call is bounded with `timeout` so the guard can't itself hang.
#   - QGE window prediction fails safe: if its log is unreadable/missing, that
#     window is simply never considered active (never throttles on a guess).
#
# Deployed as launchd agent com.gascity.eval-window-concurrency-guard
# (StartInterval 300). Log: .gc/logs/eval-window-concurrency-guard.log
#
# Supervised first-run procedure (DO NOT load unsupervised on first deploy):
#   1. DRY_RUN=1 bash eval-window-concurrency-guard.sh   # verify decision only
#   2. bash eval-window-concurrency-guard.sh             # single supervised pass
#   3. launchctl bootstrap gui/$(id -u) \
#        ~/Library/LaunchAgents/com.gascity.eval-window-concurrency-guard.plist
#
# Known limitation (honest, not hidden): this session can implement and
# selftest the window-detection + toggle mechanism, but cannot observe a REAL
# Friday-05:07/Monday-09:17 occurrence within its own lifetime. Acceptance
# criterion 3 (a real eval window running without a disk/CPU crisis) can only
# be confirmed after the next real occurrence of one of these 3 jobs.

set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
GC="${GC:-gc}"
LOG_DIR="$CITY/.gc/logs"
LOG="$LOG_DIR/eval-window-concurrency-guard.log"
STATE_DIR="$CITY/.gc/state"

CITY_TOML="$CITY/city.toml"
BEADS_HEALTH_TOML="$CITY/packs/town-deltas/orders/beads-health.toml"
GATE_SWEEP_TOML="$CITY/packs/town-deltas/orders/gate-sweep.toml"
ORDER_TRACKING_TOML="$CITY/packs/town-deltas/orders/order-tracking-sweep.toml"

DRY_RUN="${DRY_RUN:-0}"

# ── Window bounds (local time; matches the launchd plists' own frame) ─────────
LEXBH_DOW=5              # Friday (date +%u: 1=Mon..7=Sun)
LEXBH_START_MIN=$((5*60))     # 05:00 (7min pre-roll before the 05:07 fire)
LEXBH_END_MIN=$((5*60+30))    # 05:30 (23min post-roll past the ~14min observed run)

WHATSAPP_DOW=1           # Monday
WHATSAPP_START_MIN=$((9*60+10))  # 09:10 (7min pre-roll before the 09:17 fire)
WHATSAPP_END_MIN=$((9*60+25))    # 09:25 (8min post-roll past the few-seconds run)

QGE_LOG="$CITY/.gc/logs/quality-gate-eval.log"
QGE_PERIOD_SEC=604800    # 7 days, matches its launchd StartInterval
QGE_BUFFER_SEC=1200      # ±20min around the predicted fire (drift + advisory-only impact)

# ── PROFILE VALUES ──────────────────────────────────────────────────────────────
DOG_MAX_NORMAL=3;      DOG_MAX_THROTTLED=1
ORACLE_MIN_NORMAL=1;   ORACLE_MIN_THROTTLED=0
BEADS_HEALTH_NORMAL="120s";     BEADS_HEALTH_THROTTLED="300s"
GATE_SWEEP_NORMAL="60s";        GATE_SWEEP_THROTTLED="150s"
ORDER_TRACKING_NORMAL="5m";     ORDER_TRACKING_THROTTLED="12m"

mkdir -p "$LOG_DIR" "$STATE_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [eval-window-guard] $*"; }

# ── Pure, testable helpers (sourced directly by the selftest) ──────────────────

_dow() { date -r "$1" "+%u"; }  # 1=Mon .. 7=Sun, local time

_mins_since_midnight() {
    local h m
    h="$(date -r "$1" "+%H")"
    m="$(date -r "$1" "+%M")"
    echo $((10#$h * 60 + 10#$m))
}

in_lexbh_window() { # epoch
    local dow mins
    dow="$(_dow "$1")"; mins="$(_mins_since_midnight "$1")"
    [ "$dow" -eq "$LEXBH_DOW" ] && [ "$mins" -ge "$LEXBH_START_MIN" ] && [ "$mins" -lt "$LEXBH_END_MIN" ]
}

in_whatsapp_window() { # epoch
    local dow mins
    dow="$(_dow "$1")"; mins="$(_mins_since_midnight "$1")"
    [ "$dow" -eq "$WHATSAPP_DOW" ] && [ "$mins" -ge "$WHATSAPP_START_MIN" ] && [ "$mins" -lt "$WHATSAPP_END_MIN" ]
}

# epoch mtime of the QGE log, or empty if unreadable/missing (fail-safe: caller
# treats empty as "never in window").
qge_log_mtime() {
    stat -f %m "$QGE_LOG" 2>/dev/null || true
}

in_qge_window() { # epoch, qge_mtime (may be empty)
    local now="$1" mtime="$2" predicted diff
    [ -z "$mtime" ] && return 1
    predicted=$((mtime + QGE_PERIOD_SEC))
    diff=$((now - predicted))
    [ "$diff" -lt 0 ] && diff=$((-diff))
    [ "$diff" -le "$QGE_BUFFER_SEC" ]
}

# "" | "lexbh" | "whatsapp" | "quality-gate-eval"
current_window_name() { # epoch, qge_mtime
    if in_lexbh_window "$1"; then echo "lexbh"; return; fi
    if in_whatsapp_window "$1"; then echo "whatsapp"; return; fi
    if in_qge_window "$1" "$2"; then echo "quality-gate-eval"; return; fi
    echo ""
}

# "throttled" | "normal"
desired_profile() { # window_name
    if [ -n "$1" ]; then echo "throttled"; else echo "normal"; fi
}

# ── Read current on-disk values ────────────────────────────────────────────────

get_dog_max() {
    perl -0777 -ne 'print $1 if /name = "gastown\.dog"\nmax_active_sessions = (\d+)/' "$CITY_TOML"
}
get_oracle_min() {
    perl -0777 -ne 'print $1 if /name = "oracle-wa"\nmin_active_sessions = (\d+)/' "$CITY_TOML"
}
get_order_interval() { # file
    perl -ne 'print $1 if /^interval = "(.*)"$/' "$1"
}

# ── Apply a profile (idempotent: only writes + reloads if something changed) ───

apply_profile() { # normal|throttled
    local profile="$1" changed=0
    local dog_target oracle_target bh_target gs_target ots_target
    if [ "$profile" = "throttled" ]; then
        dog_target="$DOG_MAX_THROTTLED"; oracle_target="$ORACLE_MIN_THROTTLED"
        bh_target="$BEADS_HEALTH_THROTTLED"; gs_target="$GATE_SWEEP_THROTTLED"; ots_target="$ORDER_TRACKING_THROTTLED"
    else
        dog_target="$DOG_MAX_NORMAL"; oracle_target="$ORACLE_MIN_NORMAL"
        bh_target="$BEADS_HEALTH_NORMAL"; gs_target="$GATE_SWEEP_NORMAL"; ots_target="$ORDER_TRACKING_NORMAL"
    fi

    local cur_dog cur_oracle cur_bh cur_gs cur_ots
    cur_dog="$(get_dog_max)"; cur_oracle="$(get_oracle_min)"
    cur_bh="$(get_order_interval "$BEADS_HEALTH_TOML")"
    cur_gs="$(get_order_interval "$GATE_SWEEP_TOML")"
    cur_ots="$(get_order_interval "$ORDER_TRACKING_TOML")"

    log "profile=$profile current(dog_max=$cur_dog oracle_min=$cur_oracle beads_health=$cur_bh gate_sweep=$cur_gs order_tracking=$cur_ots) target(dog_max=$dog_target oracle_min=$oracle_target beads_health=$bh_target gate_sweep=$gs_target order_tracking=$ots_target)"

    if [ "$cur_dog" != "$dog_target" ]; then
        changed=1
        log "gastown.dog max_active_sessions: $cur_dog -> $dog_target"
        [ "$DRY_RUN" = "1" ] || perl -0777 -pi -e 's/(name = "gastown\.dog"\nmax_active_sessions = )\d+/${1}'"$dog_target"'/' "$CITY_TOML"
    fi
    if [ "$cur_oracle" != "$oracle_target" ]; then
        changed=1
        log "oracle-wa min_active_sessions: $cur_oracle -> $oracle_target"
        [ "$DRY_RUN" = "1" ] || perl -0777 -pi -e 's/(name = "oracle-wa"\nmin_active_sessions = )\d+/${1}'"$oracle_target"'/' "$CITY_TOML"
    fi
    if [ "$cur_bh" != "$bh_target" ]; then
        changed=1
        log "beads-health interval: $cur_bh -> $bh_target"
        [ "$DRY_RUN" = "1" ] || perl -pi -e 's/^interval = ".*"$/interval = "'"$bh_target"'"/' "$BEADS_HEALTH_TOML"
    fi
    if [ "$cur_gs" != "$gs_target" ]; then
        changed=1
        log "gate-sweep interval: $cur_gs -> $gs_target"
        [ "$DRY_RUN" = "1" ] || perl -pi -e 's/^interval = ".*"$/interval = "'"$gs_target"'"/' "$GATE_SWEEP_TOML"
    fi
    if [ "$cur_ots" != "$ots_target" ]; then
        changed=1
        log "order-tracking-sweep interval: $cur_ots -> $ots_target"
        [ "$DRY_RUN" = "1" ] || perl -pi -e 's/^interval = ".*"$/interval = "'"$ots_target"'"/' "$ORDER_TRACKING_TOML"
    fi

    if [ "$changed" -eq 0 ]; then
        log "already at profile=$profile, no-op"
        return 0
    fi

    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY_RUN] would run: $GC reload --soft"
        return 0
    fi

    if timeout 30 "$GC" reload --soft >>"$LOG" 2>&1; then
        log "gc reload --soft OK — profile=$profile is now live"
    else
        log "ERROR: gc reload --soft failed — files were rewritten to profile=$profile but the running city may still be on the old values until the next successful reload (will retry next pass)"
    fi
}

main() {
    # In DRY_RUN keep output on the terminal (selftest/supervised); else append to log.
    if [ "$DRY_RUN" != "1" ]; then
        exec >>"$LOG" 2>&1
    fi

    # Startup marker for delivery freshness verification (mirrors crew-hang-detector).
    printf '%s %s\n' "$$" "$(date +%s)" > "$STATE_DIR/eval-window-concurrency-guard.startup"

    if [ -f "$STATE_DIR/eval-window-concurrency-guard.disabled" ]; then
        log "kill-switch present (eval-window-concurrency-guard.disabled) — no-op"
        exit 0
    fi

    local now qge_mtime window profile
    now="$(date +%s)"
    qge_mtime="$(qge_log_mtime)"
    window="$(current_window_name "$now" "$qge_mtime")"
    profile="$(desired_profile "$window")"

    log "=== pass start (PID $$, DRY_RUN=$DRY_RUN, window=${window:-none}, profile=$profile) ==="
    apply_profile "$profile"
    log "=== pass complete ==="
}

if [ "${EVAL_WINDOW_GUARD_LIB_ONLY:-0}" != "1" ]; then
    main "$@"
fi
