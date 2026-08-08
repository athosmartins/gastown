#!/usr/bin/env bash
# crew-session-reset-detector.sh (ga-pjrjo / closes the 24h watchdog's blind spot)
#
# WHY: the gastown.session-watchdog only checks that each crew TITLE has an active
# session — so a close+recreate (session-ID change) passes as "CLEAN". Crew sessions
# DO churn IDs (ga-b41wn: resume/wake/reconciler spawns a duplicate → dedup drains
# one → the agent comes back under a NEW id). Those resets were invisible. This
# detector snapshots each crew agent's live session id(s) and alerts when a
# previously-seen id disappears while the agent persists (= reset) or the agent
# vanishes entirely (= closed). Detection only — never closes/spawns sessions.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG="$CITY/.gc/logs/crew-session-reset-detector.log"
SNAP="/tmp/crew-session-reset-detector.snapshot"   # lines: "<agent>\t<id>"
NOTIFY="${CREW_RESET_NOTIFY:-1}"                    # 0 = log only, no ntfy

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null; }

# Current live crew sessions: agent (template ending -wa/-ps/-lx) in a live state.
CUR="$(cd "$CITY" && GC_CITY="$CITY" timeout 15 bash "$CITY/scripts/gc-session-list-cached.sh" 2>/dev/null \
  | jq -r '.sessions[]
      | select(.template | test("-(wa|ps|lx)$"))
      | select(.state=="active" or .state=="asleep" or .state=="start-pending")
      | "\(.template)\t\(.id)"' 2>/dev/null | sort -u)"

# Probe failure (Dolt down / gc hung) → skip silently, keep prior snapshot.
[ -z "$CUR" ] && { log "skip: no crew session data (gc/Dolt unavailable?)"; exit 0; }

# First run: just record.
[ -f "$SNAP" ] || { printf '%s\n' "$CUR" > "$SNAP"; log "baseline recorded ($(printf '%s\n' "$CUR" | wc -l | tr -d ' ') crew session(s))."; exit 0; }

PREV="$(cat "$SNAP" 2>/dev/null)"
cur_agents="$(printf '%s\n' "$CUR" | cut -f1 | sort -u)"

# For each (agent,id) in PREV that is no longer live: reset (agent still here) or closed.
alerts=0
while IFS=$'\t' read -r agent id; do
  [ -z "$agent" ] && continue
  if printf '%s\n' "$CUR" | grep -qF "$(printf '%s\t%s' "$agent" "$id")"; then
    continue   # same id still live → no change
  fi
  if printf '%s\n' "$cur_agents" | grep -qxF "$agent"; then
    newids="$(printf '%s\n' "$CUR" | awk -F'\t' -v a="$agent" '$1==a{print $2}' | paste -sd, -)"
    log "RESET: crew '$agent' session $id is gone; agent now on [$newids]"
    [ "$NOTIFY" = "1" ] && command -v notify >/dev/null 2>&1 && notify -p 3 -t 'crew-session-reset' "Crew $agent reset: $id → [$newids] (ga-b41wn churn)" >/dev/null 2>&1 || true
  else
    log "CLOSED: crew '$agent' session $id is gone and the agent has NO live session"
    [ "$NOTIFY" = "1" ] && command -v notify >/dev/null 2>&1 && notify -p 4 -t 'crew-session-CLOSED' "Crew $agent ($id) has NO live session — possible bad reap" >/dev/null 2>&1 || true
  fi
  alerts=$((alerts+1))
done <<< "$PREV"

printf '%s\n' "$CUR" > "$SNAP"
[ "$alerts" -eq 0 ] && log "clean: no crew session-id changes ($(printf '%s\n' "$cur_agents" | grep -c . ) agent(s))." || true
exit 0
