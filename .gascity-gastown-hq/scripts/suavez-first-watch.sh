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
# ga-qb6yg self-review before resubmission: --all only lifts the closed-status
# filter, it does NOT lift the separate 50-row --limit default (confirmed via
# `bd list --help`) — without --limit 0 this silently truncates at 50 (the
# ga-21kmp gotcha), same fix already applied to the sibling query in
# routed-to-eraser-capture.sh in this same diff.
cur_raw=$(bd -C "$CITY" list --all --limit 0 --json 2>/dev/null)
BD_RC=$?
cur=$(printf '%s' "$cur_raw" | jq -r '.[] | select((.labels//[])|any(.=="story:needs-approval")) | select(.status=="open") | .id' 2>/dev/null | sort -u)

# ga-sdkrl gate-feedback: baseline must exist (created at setup); if missing, seed it
# and wait (don't fire on existing) — but ONLY from a query that actually succeeded.
# The whole point of the baseline is to exclude the pre-existing ga-fhhsh test-seed
# bead from ever triggering the "first real arrival" notification; if the seeding
# run coincided with a query failure, `cur` would be empty/wrong and get written
# verbatim as an incomplete baseline. The NEXT successful poll would then read the
# still-open ga-fhhsh seed as "new" (not in that bad baseline), fire an incorrect
# notification pointing at the test seed instead of a real arrival, and self-unload
# (launchctl bootout below) — permanently disabling itself before the genuine first
# arrival could ever be notified. On failure, skip this cycle without writing
# anything; the next scheduled run (every 3min) tries again.
if [ ! -f "$BASELINE" ]; then
  if [ "$BD_RC" -ne 0 ]; then
    echo "[$(ts)] WARN: bd list failed (rc=$BD_RC) during baseline seed — NOT writing baseline, will retry next cycle" >> "$LOG"
    exit 0
  fi
  printf '%s\n' "$cur" > "$BASELINE"; echo "[$(ts)] seeded baseline" >> "$LOG"; exit 0
fi
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
