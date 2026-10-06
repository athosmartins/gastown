#!/usr/bin/env bash
# config-drift-watcher.sh — Robust config-drift protection for Gas City crew sessions.
#
# STRATEGY (dual-mode protection):
#   1. FILE WATCHER  — polls skill/config files every 3s. On a change it requests
#      "gc reload --soft" as soon as the controller's reload slot is free, so drift is
#      accepted before the reconciler drains sessions. A change is NEVER dropped because
#      the slot was busy: it stays pending and is retried until a reload is accepted.
#
#   2. BACKSTOP HEARTBEAT — a periodic "gc reload --soft" that catches drift from ANY
#      source the file watcher doesn't cover:
#        - Controller's own watch reloads (agent.toml, rig config changes)
#        - Remote pack refresh events
#        - Any config path not tracked by this script's hash
#      It is DUTY-CAPPED (ga-mc42px), see below. It used to fire unconditionally every 20s.
#
# WHY THE HEARTBEAT IS DUTY-CAPPED (ga-mc42px — measured 2026-10-05, load 60-80):
#   The controller has ONE reload slot. An accepted reload holds it until the reconciler
#   tick that processes the reload FINISHES (engine: cmd/gc/city_runtime.go — the reload
#   is completed by completeManualReload() at the END of the tick; reloadActiveTTL = 10m
#   force-clears a wedged slot). "--async" only returns when the request is ACCEPTED
#   (~50ms) — it does not shorten how long the slot stays occupied. Under load a tick takes
#   8-10 min, and a watcher that re-requests as soon as the slot frees keeps it occupied
#   ~100% of the time: 05/10 12:00-21:40 the log shows 5-9 accepted heartbeat reloads per
#   hour at ~600s gaps and ~110 "already in progress" refusals per hour. Everyone else who
#   needs a reload — "gc agent resume" in the peter-wa evening job (120 tries over 1805s,
#   aborted), the Mayor (~6 min wait) — queued behind the watcher.
#
#   Now: the heartbeat reload runs in the background as a SYNCHRONOUS "gc reload --soft",
#   so its wall time is the real time it held the slot (D). After it finishes the heartbeat
#   stays off the slot for  D * (100 - P) / P  seconds (P = HEARTBEAT_MAX_SLOT_DUTY_PCT,
#   default 10, so 9*D), never less than HEARTBEAT_INTERVAL. The watcher therefore occupies
#   the slot at most ~P% of the time whatever the load, and leaves a free window of 9*D
#   after every reload for callers that need one. When reloads are fast (D <= ~2s) the
#   cadence stays at the old 20s. Raise CONFIG_DRIFT_HEARTBEAT_DUTY_PCT to trade slot
#   availability for a tighter backstop. File-change reloads use a looser cap
#   (FILE_MAX_SLOT_DUTY_PCT, default 50) so an editing burst cannot monopolise the slot
#   either, while drift from a known change is still accepted promptly.
#
# SAFETY NOTES:
#   - At most ONE reload of this watcher is in flight at any time; the watcher never
#     probes the slot with a second request (a probe that is accepted just becomes
#     another reload holding the slot).
#   - If another caller's reload holds the slot, the heartbeat treats it as covering the
#     current drift (it is --soft for every caller in this city) and waits one cooldown.
#     A pending FILE change instead keeps retrying every FILE_RETRY_WAIT seconds.
#   - Do NOT run bulk symlink migrations on live crew; do it in a maintenance window.
#
# Watched paths (for file-change detection):
#   - HQ skill sinks (source + vendor):
#       .gascity-gastown-hq/skills/
#       .gascity-gastown-hq/.claude/skills/
#   - Crew skill copies (per-member):
#       whatsapp_automation/crew/*/.claude/skills/
#       whatsapp_automation/city-local/skills/
#   - City config files:
#       .gascity-gastown-hq/city.toml
#       .gascity-gastown-hq/pack.toml
#   - Agent templates (structural config — triggers session churn if missed):
#       .gascity-gastown-hq/agents/**  (agent.toml + prompt.template.md)
#   - Daemon scripts (source — *.sh and *.py only; __pycache__/.pyc excluded):
#       .gascity-gastown-hq/scripts/*.sh
#       .gascity-gastown-hq/scripts/*.py
#
# Deployed as launchd agent: com.gascity.config-drift-watcher (KeepAlive, /bin/bash 3.2 —
# keep this file bash-3.2 clean: no associative arrays, no ${x^^}, no wait -n).
# Log: .gc/logs/config-drift-watcher.log
# Selftests: hooks-lock-guard.selftest.sh, config-drift-watcher-reload-policy.selftest.sh

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
WA="${CONFIG_DRIFT_WATCHER_WA:-/Users/athos/gt/whatsapp_automation}"   # override: selftest only
LOG_DIR="$CITY/.gc/logs"
LOG="$LOG_DIR/config-drift-watcher.log"
GC="${GC:-gc}"
HOOKS_DIR="${CITY}/.beads/hooks"
STATE_DIR="$CITY/.gc/state"
RELOAD_RESULT_FILE="$STATE_DIR/config-drift-watcher.reload-result"
RELOAD_STATS_FILE="$STATE_DIR/config-drift-watcher.reload-stats"

# Skip log redirect in lib mode so the selftest can capture its own output.
if [ "${CONFIG_DRIFT_WATCHER_LIB:-0}" != "1" ]; then
    mkdir -p "$LOG_DIR"
    exec >> "$LOG" 2>&1
fi

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [drift-watcher] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [drift-watcher] ERROR: $*"; }

# Wall clock in epoch seconds. A function so the selftest can drive a fake clock.
epoch_now() { date +%s; }

if [[ "${CONFIG_DRIFT_WATCHER_LIB:-0}" != "1" ]]; then
    log "=== config-drift-watcher started (PID $$) ==="

    # Startup marker for delivery freshness verification (ga-fbjg).
    # Prod-test reads this to confirm the live process was restarted, not merely
    # that the script file changed on disk.
    mkdir -p "$STATE_DIR"
    printf '%s %s\n' "$$" "$(date +%s)" > "$STATE_DIR/config-drift-watcher.startup"
fi

# ── Build list of watched paths ───────────────────────────────────────────────
# Returns hash of all relevant files. Using find+stat over the watched dirs.
compute_hash() {
    {
        # HQ skill sinks
        find "$CITY/skills" -type f 2>/dev/null
        find "$CITY/.claude/skills" -type f 2>/dev/null
        # Crew skill copies (follow symlinks to detect changes in targets too)
        find "$WA/crew" -path "*/.claude/skills/*" -type f 2>/dev/null
        find "$WA/city-local/skills" -type f 2>/dev/null
        # City config files
        [[ -f "$CITY/city.toml" ]] && echo "$CITY/city.toml"
        [[ -f "$CITY/pack.toml" ]] && echo "$CITY/pack.toml"
        # Agent templates — adding/editing a template changes the effective config hash
        # for all sessions; catching this here requests gc reload --soft before the
        # controller's own watcher can queue drains (immediate vs heartbeat fallback).
        find "$CITY/agents" -type f 2>/dev/null
        # Daemon scripts (source only — .sh and .py; excludes __pycache__/.pyc which
        # are regenerated on every python invocation and would cause reload storms).
        find "$CITY/scripts" -type f \( -name "*.sh" -o -name "*.py" \) 2>/dev/null
    } | sort | while IFS= read -r f; do
        # Include file path + mtime + size (fast, no md5 overhead per file)
        stat -f '%N %m %z' "$f" 2>/dev/null || true
    done | md5 -q 2>/dev/null || echo "hash-error"
}

# ── Hooks lock-guard (ga-tctky) ───────────────────────────────────────────────
# Asserts $CITY/.beads/hooks is empty AND uchg-locked. bd 1.0.5 auto-installs
# legacy hooks that gc's native store rejects (ga-rfq1j outage). The permanent
# fix keeps the dir empty+locked; a future gc op / gc doctor --fix could silently
# unlock it. This guard re-asserts the lock on every HOOKS_CHECK_INTERVAL and
# remediates + notifies on drift so the gate outage cannot silently recur.

check_hooks_guard() {
    local needs_fix=0 reason_parts=""

    if [ ! -d "$HOOKS_DIR" ]; then
        needs_fix=1
        reason_parts="hooks dir missing"
    else
        local count
        count=$(find "$HOOKS_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
        if [ "${count:-0}" -gt 0 ]; then
            needs_fix=1
            reason_parts="${reason_parts:+$reason_parts, }non-empty ($count files)"
        fi
        local flags
        flags=$(stat -f '%Sf' "$HOOKS_DIR" 2>/dev/null || echo "-")
        if [[ "$flags" != *uchg* ]]; then
            needs_fix=1
            reason_parts="${reason_parts:+$reason_parts, }uchg missing (flags: $flags)"
        fi
    fi

    [ "$needs_fix" -eq 0 ] && return 0

    log "HOOKS-GUARD: drift detected ($reason_parts) — re-asserting empty+locked"

    # Unlock → remove files → re-lock
    chflags -R nouchg "$HOOKS_DIR" 2>/dev/null || true
    if [ -d "$HOOKS_DIR" ]; then
        find "$HOOKS_DIR" -mindepth 1 -delete 2>/dev/null || true
    else
        mkdir -p "$HOOKS_DIR" || { err "HOOKS-GUARD: cannot mkdir $HOOKS_DIR"; return 1; }
    fi
    chflags uchg "$HOOKS_DIR" || { err "HOOKS-GUARD: chflags uchg failed on $HOOKS_DIR"; return 1; }

    local new_count new_flags
    new_count=$(find "$HOOKS_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
    new_flags=$(stat -f '%Sf' "$HOOKS_DIR" 2>/dev/null || echo "-")

    if [ "${new_count:-1}" -eq 0 ] && [[ "$new_flags" == *uchg* ]]; then
        log "HOOKS-GUARD: remediated OK (empty+uchg-locked) — was: $reason_parts"
        notify -t "Gas City: hooks-guard" -p 3 ".beads/hooks drift remediated: $reason_parts" 2>/dev/null || true
    else
        err "HOOKS-GUARD: remediation FAILED (count=${new_count:-?} flags=${new_flags:-?}) — native store at risk"
        notify -t "Gas City: hooks-guard FAIL" -p 5 ".beads/hooks still drifted after fix attempt ($reason_parts)" 2>/dev/null || true
    fi
}

# ── Configuration ─────────────────────────────────────────────────────────────
POLL_INTERVAL=3         # seconds between file-hash checks
DEBOUNCE_WINDOW=2       # seconds to wait after last file change before reloading
HEARTBEAT_INTERVAL=20   # floor (s) between backstop reloads; also the hooks-guard beat
HOOKS_CHECK_INTERVAL=60 # seconds between hooks-lock-guard sweeps (ga-tctky)

# Reload-slot duty caps (ga-mc42px): the share of wall-clock time this watcher's reloads
# may keep the controller's single reload slot occupied. See the header.
HEARTBEAT_MAX_SLOT_DUTY_PCT="${CONFIG_DRIFT_HEARTBEAT_DUTY_PCT:-10}"
FILE_MAX_SLOT_DUTY_PCT="${CONFIG_DRIFT_FILE_DUTY_PCT:-50}"
HEARTBEAT_MAX_INTERVAL=7200   # sanity ceiling (s) on any cooldown; a reload is bounded by the
                              # controller's 10 min TTL, so 9*D <= 5400 and this never bites
RELOAD_CLIENT_TIMEOUT=900     # gc reload --timeout (s): above the controller's 10 min TTL so a
                              # force-cleared reload is REPORTED instead of timing out locally
RELOAD_WATCHDOG_GRACE=120     # s past the client timeout before a stuck gc client is killed
FILE_RETRY_WAIT=15            # s between retries of a pending file-change reload
FILE_MAX_FAIL_RETRIES=3       # non-"busy" failures before a file change is left to the heartbeat

# ── Reload scheduling state ───────────────────────────────────────────────────
prev_hash=""
last_change_time=0
pending_reload=false
last_beat_time=0          # hooks-guard beat (every HEARTBEAT_INTERVAL, as the old heartbeat did)
last_hooks_check=0
RELOAD_PID=""             # background "gc reload --soft" of THIS watcher; "" = none in flight
RELOAD_TRIGGER=""         # heartbeat | file-change
RELOAD_STARTED=0
hb_next_allowed=0         # earliest epoch the next heartbeat reload may start
file_next_allowed=0       # earliest epoch the next file-change reload may start
file_fail_count=0
file_busy_streak=0
last_reload_secs=0        # D: how long the last reload of ours held the slot
reload_held_total=0       # sum of D since start (for the duty line in the log)
reload_count=0
watcher_started_at=0

# slot_cooldown_secs <held_secs> <duty_pct> <floor_secs> — how long to stay off the reload
# slot after a reload that held it <held_secs>, so the slot is occupied at most <duty_pct>%
# of the time: held * (100 - duty) / duty, clamped to [floor, HEARTBEAT_MAX_INTERVAL].
# Garbage input degrades to "no history" (held=0 → floor), never to a division by zero.
slot_cooldown_secs() {
    local held="${1:-0}" duty="${2:-10}" floor="${3:-0}" cd
    case "$held"  in ''|*[!0-9]*) held=0 ;; esac
    case "$duty"  in ''|*[!0-9]*) duty=10 ;; esac
    case "$floor" in ''|*[!0-9]*) floor=0 ;; esac
    if (( duty < 1 )); then duty=1; fi
    if (( duty > 100 )); then duty=100; fi
    cd=$(( held * (100 - duty) / duty ))
    if (( cd < floor )); then cd=$floor; fi
    if (( cd > HEARTBEAT_MAX_INTERVAL )); then cd=$HEARTBEAT_MAX_INTERVAL; fi
    echo "$cd"
}

# slot_duty_line <now> — "own slot duty since start: X% (N reloads, Ts held / Us up)".
# The proof, in the log, that this watcher leaves the slot free.
slot_duty_line() {
    local now="$1" up pct
    up=$(( now - watcher_started_at ))
    if (( up < 1 )); then up=1; fi
    pct=$(( reload_held_total * 100 / up ))
    echo "own slot duty since start: ${pct}% (${reload_count} reloads, ${reload_held_total}s held / ${up}s up)"
}

save_reload_stats() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    printf '%s %s\n' "$last_reload_secs" "$hb_next_allowed" > "$RELOAD_STATS_FILE.tmp" 2>/dev/null \
        && mv "$RELOAD_STATS_FILE.tmp" "$RELOAD_STATS_FILE" 2>/dev/null || true
}

# load_reload_stats <now> — carry D and the heartbeat embargo across restarts: every delivery
# restarts this daemon, and a fresh process must not forget the slot was just held for minutes.
load_reload_stats() {
    local now="$1" line a b
    [ -r "$RELOAD_STATS_FILE" ] || return 0
    line=$(head -1 "$RELOAD_STATS_FILE" 2>/dev/null) || return 0
    a=""; b=""
    read -r a b <<< "$line"
    case "$a" in ''|*[!0-9]*) return 0 ;; esac
    case "$b" in ''|*[!0-9]*) return 0 ;; esac
    last_reload_secs=$a
    if (( b > hb_next_allowed && b <= now + HEARTBEAT_MAX_INTERVAL )); then
        hb_next_allowed=$b
    fi
}

# start_reload <trigger> <now> — fire "gc reload --soft" in the background. It is the
# SYNCHRONOUS form on purpose: its wall time is how long this reload held the controller's
# slot (D), which is the number the heartbeat cadence is derived from. The result is handed
# back through $RELOAD_RESULT_FILE ("<ok|busy|fail> <secs> <rc>" + one message line), written
# atomically as the very last step so its existence means "finished".
start_reload() {
    local trigger="$1" now="$2"
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    rm -f "$RELOAD_RESULT_FILE" "$RELOAD_RESULT_FILE.tmp" 2>/dev/null || true
    RELOAD_TRIGGER="$trigger"
    RELOAD_STARTED=$now
    log "reload[$trigger] requested — gc reload --soft (sync, in background, timeout ${RELOAD_CLIENT_TIMEOUT}s)"
    (
        t0=$(date +%s)
        out=$("$GC" reload --soft --timeout "${RELOAD_CLIENT_TIMEOUT}s" --city "$CITY" 2>&1)
        rc=$?
        t1=$(date +%s)
        if [ "$rc" -eq 0 ]; then
            outcome=ok
        elif printf '%s\n' "$out" | grep "already in progress" >/dev/null; then
            outcome=busy
        else
            outcome=fail
        fi
        {
            printf '%s %s %s\n' "$outcome" "$(( t1 - t0 ))" "$rc"
            printf '%s\n' "$out" | tr '\n' ' ' | cut -c1-300
            echo
        } > "$RELOAD_RESULT_FILE.tmp" && mv "$RELOAD_RESULT_FILE.tmp" "$RELOAD_RESULT_FILE"
    ) &
    RELOAD_PID=$!
}

# finish_reload <trigger> <ok|busy|fail> <held_secs> <rc> <message> <now> — account for a
# finished reload and schedule what may run next. Pure state update (no process handling),
# so the selftest can replay an incident timeline through it.
finish_reload() {
    local trigger="$1" outcome="$2" held="$3" rc="$4" msg="$5" now="$6" hb_cd file_cd retry
    case "$held" in ''|*[!0-9]*) held=0 ;; esac
    case "$outcome" in
        ok|fail)
            last_reload_secs=$held
            reload_held_total=$(( reload_held_total + held ))
            reload_count=$(( reload_count + 1 ))
            hb_cd=$(slot_cooldown_secs "$held" "$HEARTBEAT_MAX_SLOT_DUTY_PCT" "$HEARTBEAT_INTERVAL")
            file_cd=$(slot_cooldown_secs "$held" "$FILE_MAX_SLOT_DUTY_PCT" "$DEBOUNCE_WINDOW")
            hb_next_allowed=$(( now + hb_cd ))
            file_next_allowed=$(( now + file_cd ))
            file_busy_streak=0
            save_reload_stats
            if [ "$outcome" = "ok" ]; then
                file_fail_count=0
                log "reload[$trigger] OK after ${held}s (held the reload slot ${held}s): ${msg:-no output}"
            else
                err "reload[$trigger] FAILED rc=$rc after ${held}s: ${msg:-no output}"
                if [ "$trigger" = "file-change" ]; then
                    if (( file_fail_count < FILE_MAX_FAIL_RETRIES )); then
                        file_fail_count=$(( file_fail_count + 1 ))
                        pending_reload=true
                        retry=$file_cd
                        if (( retry < FILE_RETRY_WAIT )); then retry=$FILE_RETRY_WAIT; fi
                        file_next_allowed=$(( now + retry ))
                        err "file-change reload will be retried in ${retry}s (failure $file_fail_count/$FILE_MAX_FAIL_RETRIES)"
                    else
                        err "file-change reload gave up after $FILE_MAX_FAIL_RETRIES failures — the backstop heartbeat will cover it"
                        file_fail_count=0
                    fi
                fi
            fi
            log "next heartbeat reload not before +${hb_cd}s, next file-change reload not before +${file_cd}s; $(slot_duty_line "$now")"
            ;;
        busy)
            # Someone else's reload holds the slot; we did not take it, so there is no D to learn.
            if [ "$trigger" = "file-change" ]; then
                pending_reload=true
                file_next_allowed=$(( now + FILE_RETRY_WAIT ))
                file_busy_streak=$(( file_busy_streak + 1 ))
                if (( file_busy_streak == 1 || file_busy_streak % 20 == 0 )); then
                    log "reload[file-change] busy (another reload holds the slot, streak $file_busy_streak) — the file change stays pending, retry every ${FILE_RETRY_WAIT}s"
                fi
            else
                hb_cd=$(slot_cooldown_secs "$last_reload_secs" "$HEARTBEAT_MAX_SLOT_DUTY_PCT" "$HEARTBEAT_INTERVAL")
                hb_next_allowed=$(( now + hb_cd ))
                log "reload[heartbeat] busy (another reload holds the slot; it covers current drift) — next heartbeat not before +${hb_cd}s"
            fi
            ;;
    esac
}

# poll_reload_result <now> — reap the background reload, if it has finished.
poll_reload_result() {
    local now="$1" outcome held rc msg
    [ -n "$RELOAD_PID" ] || return 0
    if [ -f "$RELOAD_RESULT_FILE" ]; then
        outcome=""; held=""; rc=""; msg=""
        { read -r outcome held rc; read -r msg; } < "$RELOAD_RESULT_FILE" || true
        rm -f "$RELOAD_RESULT_FILE" 2>/dev/null || true
        case "$outcome" in ok|busy|fail) ;; *) outcome=fail; msg="unreadable reload result" ;; esac
        wait "$RELOAD_PID" 2>/dev/null || true   # the result is the runner's last act; reap it
        RELOAD_PID=""
        finish_reload "$RELOAD_TRIGGER" "$outcome" "$held" "${rc:-?}" "$msg" "$now"
        return 0
    fi
    if ! kill -0 "$RELOAD_PID" 2>/dev/null; then
        # The runner is gone and left no result (killed from outside). Count it as a failure
        # that held the slot for as long as it ran — the conservative reading.
        RELOAD_PID=""
        finish_reload "$RELOAD_TRIGGER" fail "$(( now - RELOAD_STARTED ))" "?" "reload runner exited without a result" "$now"
        return 0
    fi
    if (( now - RELOAD_STARTED > RELOAD_CLIENT_TIMEOUT + RELOAD_WATCHDOG_GRACE )); then
        kill "$RELOAD_PID" 2>/dev/null || true
        RELOAD_PID=""
        finish_reload "$RELOAD_TRIGGER" fail "$(( now - RELOAD_STARTED ))" "?" "reload client exceeded ${RELOAD_CLIENT_TIMEOUT}s + ${RELOAD_WATCHDOG_GRACE}s grace — killed" "$now"
    fi
}

# heartbeat_due <now> — may the backstop heartbeat start a reload right now? Never while one of
# ours is in flight, never while a file change is waiting its turn (that reload will cover it),
# and never inside the cooldown that keeps the slot duty at or below the cap.
heartbeat_due() {
    [ -z "$RELOAD_PID" ] && [ "$pending_reload" != "true" ] && (( $1 >= hb_next_allowed ))
}

# file_reload_due <now> — may a pending, debounced file change start its reload right now?
file_reload_due() {
    [ -z "$RELOAD_PID" ] && [ "$pending_reload" = "true" ] \
        && (( $1 - last_change_time >= DEBOUNCE_WINDOW )) && (( $1 >= file_next_allowed ))
}

# watcher_tick — one pass of the main loop (everything except the sleep), so the selftest can
# drive it with a fake clock.
watcher_tick() {
    local now current_hash
    now=$(epoch_now)

    poll_reload_result "$now"

    # ── HOOKS GUARD: every HEARTBEAT_INTERVAL (what the old heartbeat block did) ──
    if (( now - last_beat_time >= HEARTBEAT_INTERVAL )); then
        check_hooks_guard
        last_beat_time=$now
    fi

    # ── HOOKS LOCK-GUARD: periodic assertion (ga-tctky) ─────────────────────
    if (( now - last_hooks_check >= HOOKS_CHECK_INTERVAL )); then
        check_hooks_guard
        last_hooks_check=$now
    fi

    # ── FILE WATCHER: detect and debounce file changes ──────────────────────
    current_hash=$(compute_hash)

    if [[ "$current_hash" != "$prev_hash" ]]; then
        # Hash changed — note the time, mark pending
        last_change_time=$now
        pending_reload=true
        prev_hash="$current_hash"
        log "Hash changed (new: $current_hash) — debouncing..."
    fi

    # ── RELOAD SCHEDULING: a file change outranks the heartbeat ─────────────
    if file_reload_due "$now"; then
        log "File change detected (hash-change) — requesting gc reload --soft"
        pending_reload=false
        start_reload file-change "$now"
    elif heartbeat_due "$now"; then
        start_reload heartbeat "$now"
    fi
}

# Library-source guard — selftests source this file with CONFIG_DRIFT_WATCHER_LIB=1 to
# exercise check_hooks_guard and the reload scheduling without starting the daemon loop.
if [ "${CONFIG_DRIFT_WATCHER_LIB:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# Initialize hash (don't trigger on start)
now=$(epoch_now)
watcher_started_at=$now
prev_hash=$(compute_hash)
last_beat_time=$now
hb_next_allowed=$(( now + HEARTBEAT_INTERVAL ))
load_reload_stats "$now"

# Assert hooks-lock invariant at startup before first heartbeat.
check_hooks_guard

log "Initial hash: $prev_hash"
log "Watching: $CITY/skills, $CITY/.claude/skills, $WA/crew/*/.claude/skills/, $WA/city-local/skills/, city.toml, pack.toml, agents/, scripts/*.{sh,py}"
log "Poll interval: ${POLL_INTERVAL}s, debounce: ${DEBOUNCE_WINDOW}s, heartbeat floor: ${HEARTBEAT_INTERVAL}s"
log "Mode: file-watcher (immediate, retried until accepted) + duty-capped backstop heartbeat (slot duty <= ${HEARTBEAT_MAX_SLOT_DUTY_PCT}%, file-change reloads <= ${FILE_MAX_SLOT_DUTY_PCT}%)"
log "Carried over from the previous run: last reload held the slot ${last_reload_secs}s, next heartbeat not before epoch ${hb_next_allowed}"

while true; do
    sleep "$POLL_INTERVAL"
    watcher_tick
done
