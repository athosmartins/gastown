#!/usr/bin/env bash
# suavez-first-watch.sh — NTFY the moment the FIRST real bead lands in "Sua vez"
# (story:needs-approval), excluding any card already there at setup (the ga-fhhsh
# test seed). Runs every 3min via launchd (com.gascity.suavez-first-watch); on the
# first NEW needs-approval bead it notifies + self-unloads (one-shot).
set -uo pipefail
CITY="/Users/athos/gt/.gascity-gastown-hq"
BASELINE="$CITY/.gc/suavez-baseline.ids"     # IDs present at setup (excluded)
LOG="$CITY/.gc/logs/suavez-first-watch.log"
LABEL="com.gascity.suavez-first-watch"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# current open needs-approval bead ids (cross-store)
cur=$(bd -C "$CITY" list --all --json 2>/dev/null \
  | jq -r '.[] | select((.labels//[])|any(.=="story:needs-approval")) | select(.status=="open") | .id' 2>/dev/null | sort -u)

# baseline must exist (created at setup); if missing, seed it and wait (don't fire on existing)
if [ ! -f "$BASELINE" ]; then printf '%s\n' "$cur" > "$BASELINE"; echo "[$(ts)] seeded baseline" >> "$LOG"; exit 0; fi
base=$(cat "$BASELINE" 2>/dev/null)

# first id in cur that is NOT in baseline = first real arrival
new=""
while IFS= read -r id; do
  [ -z "$id" ] && continue
  if ! printf '%s\n' "$base" | grep -qxF "$id"; then new="$id"; break; fi
done <<< "$cur"

if [ -n "$new" ]; then
  title=$(bd -C "$CITY" show "$new" --json 2>/dev/null | jq -r 'if type=="array" then .[0] else . end | .title // "?"' 2>/dev/null)
  echo "[$(ts)] FIRST real Sua vez arrival: $new — $title" >> "$LOG"
  command -v notify >/dev/null 2>&1 && notify -p 4 -t '👤 SUA VEZ — primeira história' \
    "Primeira história REAL chegou na 'Sua vez' pra você aprovar: $new — $title. O funil ingeriu+refinou+revisou sozinho. (mais devem seguir, ~1 a cada 5min)" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
fi
exit 0
