#!/usr/bin/env bash
# prod-tests/gascity/story-ga-fbjg.sh — prod test for ga-fbjg: KeepAlive engine
# restart on gascity deploy (config-drift-watcher + town-root-reconciler).
#
# Verifies that the LIVE processes were actually restarted (not just that the
# script files changed on disk). Reads the startup marker each engine writes on
# start-up and asserts it is recent — proving the live process runs the new body.
#
# Called by story-delivery.sh after deploy (STORY_ID=ga-fbjg). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
STATE_DIR="$CITY/.gc/state"

log()  { echo "[prod-test:gascity ga-fbjg] $*"; }
fail() { echo "[prod-test:gascity ga-fbjg] FAIL: $*" >&2; exit 1; }

# How recently the engine must have started (seconds). The daemon_restarts
# kickstart in delivery Step 5 happens just before this prod test runs.
# 300s (5 min) covers launchd startup latency and any brief process spin-up.
FRESHNESS_WINDOW=300

check_engine() {
    local label="$1"    # e.g. "com.gascity.config-drift-watcher"
    local script="$2"   # short name for the marker file
    local marker="$STATE_DIR/${script}.startup"
    local max_wait=30   # seconds to wait for launchd to bring the process up

    log "Checking $label ..."

    # ── 1+2. Poll until launchd has a PID AND the startup marker exists ───────
    # Fix: `launchctl list <label>` on macOS returns a plist dict (first line `{`),
    # so use `launchctl list | awk '$3==label'` to get the real PID.  Also poll for
    # both the launchd PID and the marker file together so launchd startup latency
    # doesn't cause an immediate failure before the process has been assigned a PID.
    local pid launchd_pid waited=0
    while (( waited < max_wait )); do
        launchd_pid=$(launchctl list 2>/dev/null | awk -v lbl="$label" '$3==lbl{print $1}')
        if [[ -n "$launchd_pid" && "$launchd_pid" != "-" && -f "$marker" ]]; then
            break
        fi
        sleep 2
        (( waited += 2 ))
    done

    if [[ -z "$launchd_pid" || "$launchd_pid" == "-" ]]; then
        fail "$label: not running in launchd after ${max_wait}s (kickstart failed or label wrong)"
    fi
    [[ -f "$marker" ]] || fail "$label: startup marker missing after ${max_wait}s ($marker) — process did not write it; is it running the NEW code?"
    log "$label: launchd PID=$launchd_pid"

    # ── 3. Parse marker: "<pid> <epoch>" ─────────────────────────────────────
    read -r pid epoch < "$marker" 2>/dev/null \
        || fail "$label: could not read startup marker ($marker)"
    [[ -n "$pid" && -n "$epoch" ]] \
        || fail "$label: startup marker malformed (expected '<pid> <epoch>'): $(cat "$marker")"

    # ── 4. Marker PID must match live launchd PID ────────────────────────────
    if [[ "$pid" != "$launchd_pid" ]]; then
        fail "$label: marker PID=$pid != launchd PID=$launchd_pid — process wrote marker then was replaced; check for crash loop"
    fi

    # ── 5. Startup epoch must be recent ──────────────────────────────────────
    local now age
    now=$(date +%s)
    age=$(( now - epoch ))
    if (( age > FRESHNESS_WINDOW )); then
        fail "$label: startup marker is ${age}s old (> ${FRESHNESS_WINDOW}s window) — live process was NOT restarted by this deploy (old process body still running)"
    fi
    log "$label: fresh — started ${age}s ago (PID=$pid, within ${FRESHNESS_WINDOW}s window) ✓"
}

# ── Check both KeepAlive engines ──────────────────────────────────────────────
check_engine "com.gascity.config-drift-watcher"   "config-drift-watcher"
check_engine "com.gascity.town-root-reconciler"   "town-root-reconciler"

log "PASS — both KeepAlive engines restarted and running new code"
exit 0
