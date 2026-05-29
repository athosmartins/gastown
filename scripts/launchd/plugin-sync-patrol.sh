#!/bin/bash
# plugin-sync-patrol.sh - Periodic `gt plugin sync` to keep town-level plugins
# in sync with the gastown source clone.
#
# Background: `gt plugin sync` is the canonical fix when `gt doctor` reports
# "patrol-plugin-drift". Today the check fired with 5 plugins out of sync —
# none of which had auto-recovery. This wires the canonical fix into a cadence.
#
# Source: gastown/refinery/rig/plugins (role clone, stable after my reset).
# Target: ~/gt/plugins (town-level, what all rigs read from).
#
# Scheduled by ~/Library/LaunchAgents/com.gastown.plugin-sync-patrol.plist
# (runs every 3600s)

set -euo pipefail

LOGFILE="$HOME/.gastown/logs/plugin-sync-patrol.log"
NTFY_TOPIC="https://ntfy.sh/athos-claude-code-x7k9m2p4"
SOURCE_DIR="$HOME/gt/gastown/refinery/rig/plugins"

mkdir -p "$(dirname "$LOGFILE")"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

cd "$HOME/gt"

# Skip if source isn't there (e.g., during a clone outage).
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "[$(ts)] source missing: $SOURCE_DIR" >> "$LOGFILE"
    exit 0
fi

# Dry-run first to see if anything would change.
DRY_OUTPUT=$(gt plugin sync --source "$SOURCE_DIR" --dry-run 2>&1 || true)

# "All plugins up to date" → log heartbeat and exit.
if echo "$DRY_OUTPUT" | grep -q "All plugins up to date"; then
    echo "[$(ts)] all plugins current" >> "$LOGFILE"
    exit 0
fi

# Drift detected — apply.
APPLY_OUTPUT=$(gt plugin sync --source "$SOURCE_DIR" 2>&1 || true)
SYNCED=$( { echo "$APPLY_OUTPUT" | grep -cE "^\s*↑\s+"; } || echo 0 )
CURRENT=$( { echo "$APPLY_OUTPUT" | grep -oE "[0-9]+ checked" | head -1 | grep -oE "[0-9]+"; } || echo "?" )

# If apply reported "already up to date", treat as no-op too.
if echo "$APPLY_OUTPUT" | grep -q "already up to date"; then
    SYNCED=0
fi

if (( SYNCED == 0 )); then
    echo "[$(ts)] all plugins current (post-apply)" >> "$LOGFILE"
    exit 0
fi

echo "[$(ts)] synced $SYNCED plugin(s) (out of $CURRENT total)" >> "$LOGFILE"
echo "$APPLY_OUTPUT" >> "$LOGFILE"

# Notify on actual drift fix (P2 = low priority informational).
curl -s -H "Title: Gas Town: plugin drift auto-fixed" \
     -H "Priority: 2" \
     -H "Tags: gastown,plugin-sync" \
     -d "Synced $SYNCED plugin(s):
$(echo "$APPLY_OUTPUT" | grep -E "^\s*↑")" \
     "$NTFY_TOPIC" >/dev/null 2>&1 || true

# Trim log
if [[ -f "$LOGFILE" ]] && [[ $(wc -l < "$LOGFILE") -gt 500 ]]; then
    tail -250 "$LOGFILE" > "$LOGFILE.tmp" && mv "$LOGFILE.tmp" "$LOGFILE"
fi
