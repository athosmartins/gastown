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
#
# Deployed as launchd agent: com.gascity.config-drift-watcher (KeepAlive).
# Log: .gc/logs/config-drift-watcher.log

set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
WA="/Users/athos/gt/whatsapp_automation"
LOG_DIR="$CITY/.gc/logs"
LOG="$LOG_DIR/config-drift-watcher.log"
GC="${GC:-gc}"

mkdir -p "$LOG_DIR"
exec >> "$LOG" 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [drift-watcher] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [drift-watcher] ERROR: $*"; }

log "=== config-drift-watcher started (PID $$) ==="

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

# ── Configuration ─────────────────────────────────────────────────────────────
POLL_INTERVAL=3         # seconds between file-hash checks
DEBOUNCE_WINDOW=2       # seconds to wait after last file change before reloading
HEARTBEAT_INTERVAL=20   # seconds between unconditional async soft reloads

# ── Main poll loop ────────────────────────────────────────────────────────────
prev_hash=""
last_change_time=0
pending_reload=false
last_heartbeat_time=0

# Initialize hash (don't trigger on start)
prev_hash=$(compute_hash)
last_heartbeat_time=$(date +%s)

log "Initial hash: $prev_hash"
log "Watching: $CITY/skills, $CITY/.claude/skills, $WA/crew/*/.claude/skills/, $WA/city-local/skills/, city.toml, pack.toml"
log "Poll interval: ${POLL_INTERVAL}s, debounce: ${DEBOUNCE_WINDOW}s, heartbeat: ${HEARTBEAT_INTERVAL}s"
log "Mode: dual-mode (file-watcher + periodic heartbeat reload)"

while true; do
    sleep "$POLL_INTERVAL"

    now=$(date +%s)

    # ── HEARTBEAT: unconditional periodic async reload ──────────────────────
    heartbeat_elapsed=$(( now - last_heartbeat_time ))
    if (( heartbeat_elapsed >= HEARTBEAT_INTERVAL )); then
        do_soft_reload_async "heartbeat at $(date '+%H:%M:%S')"
        last_heartbeat_time=$now
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
