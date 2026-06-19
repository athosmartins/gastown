#!/usr/bin/env bash
# config-drift-watcher.sh — Robust config-drift protection for Gas City crew sessions.
#
# STRATEGY (dual-mode protection):
#   1. FILE WATCHER  — polls skill/config files every 3s. On any change, immediately
#      runs "gc reload --soft" to accept drift before the reconciler drains sessions.
#
#   2. PERIODIC HEARTBEAT RELOAD — unconditionally fires "gc reload --soft --async"
#      every HEARTBEAT_INTERVAL seconds (default: 20s). This catches drift from ANY
#      source the file watcher doesn't cover:
#        - Controller's own watch reloads (agent.toml, rig config changes)
#        - Remote pack refresh events
#        - Any config path not tracked by this script's hash
#      Since the reconciler ticks ~every 30s and drain requires multiple ticks to
#      actually kill a session, a 20s heartbeat guarantees every drift is accepted
#      within one reconciler-tick window — no session can be drained.
#
# SAFETY NOTES:
#   - gc reload --soft (sync) takes ~43s — used for file-detected changes only
#   - gc reload --soft --async takes ~50ms — safe to fire unconditionally
#   - If reload is already in progress:
#       * heartbeat: skip (in-progress reload IS --soft, handles current drift)
#       * file-watcher sync: retry with backoff up to 3× (15s total), then fallback async
#   - The heartbeat fires every 20s, well within the ~30s reconciler tick, ensuring
#     every possible drift window is covered before drain decisions can execute.
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
# Deployed as launchd agent: com.gascity.config-drift-watcher (KeepAlive).
# Log: .gc/logs/config-drift-watcher.log

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
WA="/Users/athos/gt/whatsapp_automation"
LOG_DIR="$CITY/.gc/logs"
LOG="$LOG_DIR/config-drift-watcher.log"
GC="${GC:-gc}"
HOOKS_DIR="${CITY}/.beads/hooks"

# Skip log redirect in lib mode so the selftest can capture its own output.
if [ "${CONFIG_DRIFT_WATCHER_LIB:-0}" != "1" ]; then
    mkdir -p "$LOG_DIR"
    exec >> "$LOG" 2>&1
fi

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [drift-watcher] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [drift-watcher] ERROR: $*"; }

if [[ "${CONFIG_DRIFT_WATCHER_LIB:-0}" != "1" ]]; then
    log "=== config-drift-watcher started (PID $$) ==="

    # Startup marker for delivery freshness verification (ga-fbjg).
    # Prod-test reads this to confirm the live process was restarted, not merely
    # that the script file changed on disk.
    STATE_DIR="$CITY/.gc/state"
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
        # for all sessions; catching this here fires gc reload --soft before the
        # controller's own watcher can queue drains (immediate vs 20s heartbeat fallback).
        find "$CITY/agents" -type f 2>/dev/null
        # Daemon scripts (source only — .sh and .py; excludes __pycache__/.pyc which
        # are regenerated on every python invocation and would cause reload storms).
        find "$CITY/scripts" -type f \( -name "*.sh" -o -name "*.py" \) 2>/dev/null
    } | sort | while IFS= read -r f; do
        # Include file path + mtime + size (fast, no md5 overhead per file)
        stat -f '%N %m %z' "$f" 2>/dev/null || true
    done | md5 -q 2>/dev/null || echo "hash-error"
}

# ── Soft reload helpers ───────────────────────────────────────────────────────

# is_reload_in_progress — returns 0 if "already in progress" error
is_reload_in_progress() {
    local out="$1"
    echo "$out" | grep -q "already in progress"
}

# Synchronous soft reload — used when file watcher detects a change.
# Retries with backoff if another reload is in progress (up to SYNC_MAX_RETRIES).
# Falls back to --async on exhaustion (in-progress reload is soft and covers drift).
SYNC_RETRY_WAIT=5     # seconds between retries when "in progress"
SYNC_MAX_RETRIES=3    # max retries before async fallback

do_soft_reload_sync() {
    local trigger="$1"
    log "File change detected ($trigger) — running gc reload --soft (sync)..."

    local attempt=0
    local out
    while (( attempt <= SYNC_MAX_RETRIES )); do
        out=$("$GC" reload --soft --city "$CITY" 2>&1) && {
            log "gc reload --soft OK (attempt $((attempt+1))): $(echo "$out" | grep -E 'accepted|session' | head -3 | tr '\n' ' ')"
            return 0
        }
        if is_reload_in_progress "$out"; then
            if (( attempt < SYNC_MAX_RETRIES )); then
                log "gc reload --soft in-progress (attempt $((attempt+1))/$((SYNC_MAX_RETRIES+1))) — retrying in ${SYNC_RETRY_WAIT}s..."
                sleep "$SYNC_RETRY_WAIT"
            fi
            (( attempt++ ))
        else
            err "gc reload --soft FAILED (attempt $((attempt+1))): $out"
            (( attempt++ ))
        fi
    done

    # All retries exhausted — fall back to async (in-progress reload is soft, will accept drift)
    err "gc reload --soft sync exhausted retries — falling back to --async (in-progress reload covers drift)"
    out=$("$GC" reload --soft --async --city "$CITY" 2>&1) && {
        log "gc reload --soft --async fallback queued ($trigger)"
        return 0
    }
    if is_reload_in_progress "$out"; then
        log "gc reload --soft --async fallback: reload still in progress (drift will be accepted by it)"
    else
        err "gc reload --soft --async fallback FAILED: $out"
    fi
}

# Async soft reload — used for periodic heartbeat.
# Returns in ~50ms. The controller processes it asynchronously.
# If already in progress, gracefully skips (in-progress reload handles current drift).
do_soft_reload_async() {
    local trigger="$1"
    local out
    if out=$("$GC" reload --soft --async --city "$CITY" 2>&1); then
        log "gc reload --soft --async queued ($trigger)"
    else
        if is_reload_in_progress "$out"; then
            log "gc reload --soft --async skipped ($trigger): reload already in progress"
        else
            err "gc reload --soft --async FAILED ($trigger): $out"
        fi
    fi
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
HEARTBEAT_INTERVAL=20   # seconds between unconditional async soft reloads
HOOKS_CHECK_INTERVAL=60 # seconds between hooks-lock-guard sweeps (ga-tctky)

# ── Main poll loop ────────────────────────────────────────────────────────────
prev_hash=""
last_change_time=0
pending_reload=false
last_heartbeat_time=0
last_hooks_check=0

# Library-source guard — selftest sources with CONFIG_DRIFT_WATCHER_LIB=1 to
# exercise check_hooks_guard without starting the daemon loop.
if [ "${CONFIG_DRIFT_WATCHER_LIB:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# Initialize hash (don't trigger on start)
prev_hash=$(compute_hash)
last_heartbeat_time=$(date +%s)

# Assert hooks-lock invariant at startup before first heartbeat.
check_hooks_guard

log "Initial hash: $prev_hash"
log "Watching: $CITY/skills, $CITY/.claude/skills, $WA/crew/*/.claude/skills/, $WA/city-local/skills/, city.toml, pack.toml, agents/, scripts/*.{sh,py}"
log "Poll interval: ${POLL_INTERVAL}s, debounce: ${DEBOUNCE_WINDOW}s, heartbeat: ${HEARTBEAT_INTERVAL}s"
log "Mode: dual-mode (file-watcher + periodic heartbeat reload)"

while true; do
    sleep "$POLL_INTERVAL"

    now=$(date +%s)

    # ── HEARTBEAT: unconditional periodic async reload ──────────────────────
    heartbeat_elapsed=$(( now - last_heartbeat_time ))
    if (( heartbeat_elapsed >= HEARTBEAT_INTERVAL )); then
        do_soft_reload_async "heartbeat at $(date '+%H:%M:%S')"
        check_hooks_guard
        last_heartbeat_time=$now
    fi

    # ── HOOKS LOCK-GUARD: periodic assertion (ga-tctky) ─────────────────────
    hooks_elapsed=$(( now - last_hooks_check ))
    if (( hooks_elapsed >= HOOKS_CHECK_INTERVAL )); then
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

    if [[ "$pending_reload" == "true" ]]; then
        elapsed=$(( now - last_change_time ))
        if (( elapsed >= DEBOUNCE_WINDOW )); then
            # Sync reload: confirms acceptance and logs it clearly.
            # Will retry if a heartbeat reload is in progress.
            do_soft_reload_sync "hash-change at $(date '+%H:%M:%S')"
            pending_reload=false
            # Reset heartbeat timer after a sync reload (it already covers drift)
            last_heartbeat_time=$(date +%s)
        fi
    fi
done
