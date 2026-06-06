#!/usr/bin/env bash
# guardian-dispatch.sh — Gate+Pilot guardian: detect real breaks, auto-heal,
# escalate to Mayor only if machine cannot self-fix.
#
# Story ga-0wxg: "Zero intervenções humanas/Mayor para manter gate+pilot rodando"
#
# Runs every 300s via launchd (com.gascity.guardian.plist).
#
# PRINCIPLE: silence = healthy. Acts ONLY on confirmed, sustained problems.
# Saturated/busy ≠ broken. Never acts on false positives.
#
# For each confirmed break:
#   1. Open an incident bead (durable, audit trail)
#   2. Dispatch a repair worker (gastown.dog) OR attempt direct launchctl fix
#   3. On next cycles: verify recovery
#   4. After FIX_CAP (3) failed fix cycles: escalate to Mayor, stop auto-retry
#
# "O VIGIA É VIGIADO": writes .gc/guardian.heartbeat on every run.
# gate-health-monitor.py emits [GUARDIAN-STALL] if that file goes stale.
#
# DRAIN-SAFE: only touches scripts/ and this plist. No city.toml/pack.toml.
#
# Problem classes detected:
#   engine-stall-gate   — quality-gate-dispatcher / guard log stale > 15min
#   engine-stall-pilot  — pilot-dispatcher log stale > 15min
#   real-jam:<id>       — gate marker gate-status:queued stuck > 25min
#   delivery-fail:<id>  — story-delivery.jsonl new FAIL/HALT event

set -euo pipefail

GC_CITY="${GUARDIAN_CITY_OVERRIDE:-/Users/athos/gt/.gascity-gastown-hq}"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/guardian-dispatch.log"
GUARDIAN_LOG="$GC_CITY/.gc/guardian.jsonl"
HEARTBEAT="$GC_CITY/.gc/guardian.heartbeat"
STATE_FILE="$GC_CITY/.gc/guardian-state.json"
QG_LOG="$GC_CITY/.gc/quality-gate.jsonl"
SD_LOG="$GC_CITY/.gc/story-delivery.jsonl"

GATE_DISP_LOG="$LOG_DIR/quality-gate-dispatcher.log"
GATE_GUARD_LOG="$LOG_DIR/quality-gate-guard.log"
PILOT_LOG="$LOG_DIR/pilot-dispatcher.log"

# Thresholds
ENGINE_STALL_SEC=900        # 15min — log silent = engine stall
REAL_JAM_SEC=1500           # 25min — marker queued without completion
FIX_CAP=3                   # max auto-fix attempts before escalation
REALERT_SEC=900             # re-alert same incident class every 15min

# ── Bootstrap ─────────────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }
warn() { log "WARN: $*"; }

# Append a JSON record to guardian.jsonl
log_json() {
  mkdir -p "$(dirname "$GUARDIAN_LOG")"
  printf '%s\n' "$1" >> "$GUARDIAN_LOG" 2>/dev/null || true
}

# Write heartbeat for "the watcher is watched" (gate-health-monitor.py checks this)
heartbeat() { date -u +%Y-%m-%dT%H:%M:%SZ > "$HEARTBEAT"; }

# file_age_sec <path> — seconds since last modification; 999999 if missing
file_age_sec() {
  local f="$1"
  [ -f "$f" ] || { echo "999999"; return; }
  echo $(( $(date +%s) - $(stat -f %m "$f" 2>/dev/null || echo "0") ))
}

# launchd_pid <label> — PID of running service; empty if not running
launchd_pid() {
  launchctl list "$1" 2>/dev/null | grep '"PID"' | grep -o '[0-9]*' | head -1 || true
}

# launchd_exit <label> — LastExitStatus; empty if unknown
launchd_exit() {
  launchctl list "$1" 2>/dev/null | grep '"LastExitStatus"' | grep -o '[0-9]*' | head -1 || true
}

# ── State management ──────────────────────────────────────────────────────────
# State JSON: { "seen_qg": N, "seen_sd": N, "incidents": { "<key>": {...} } }

state_get() {
  [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo '{"seen_qg":0,"seen_sd":0,"incidents":{}}'
}

state_save() { printf '%s' "$1" > "$STATE_FILE"; }

state_get_seen() {
  local field="$1"
  state_get | jq -r ".${field} // 0"
}

state_get_incident() {
  local key="$1"
  state_get | jq -c ".incidents[\"$key\"] // null"
}

state_set_incident() {
  local key="$1" val="$2"
  local st; st=$(state_get)
  state_save "$(printf '%s' "$st" | jq -c ".incidents[\"$key\"] = $val")"
}

state_clear_incident() {
  local key="$1"
  local st; st=$(state_get)
  state_save "$(printf '%s' "$st" | jq -c "del(.incidents[\"$key\"])")"
}

state_update_seen() {
  local field="$1" val="$2"
  local st; st=$(state_get)
  state_save "$(printf '%s' "$st" | jq -c ".${field} = $val")"
}

# ── Incident lifecycle ────────────────────────────────────────────────────────

# open_incident <key> <title> <description> <repair_prompt>
# Creates a bead + dispatches a repair worker; returns bead ID.
open_incident() {
  local key="$1" title="$2" desc="$3" repair_prompt="$4"

  # Create incident bead in HQ DB
  local bead_id
  bead_id=$(bd -C "$GC_CITY" create "$title" \
    --description "$desc" \
    --type task \
    --priority 1 \
    --labels "guardian:incident,guardian:class:${key%%:*}" \
    --silent 2>/dev/null) || {
    warn "Could not create incident bead for $key"
    return 1
  }
  log "Opened incident bead $bead_id for $key"

  # Append repair prompt as a comment on the bead (worker instructions)
  bd -C "$GC_CITY" comment "$bead_id" "$repair_prompt" 2>/dev/null || true

  # Dispatch repair worker
  if gc --city "$GC_CITY" sling gastown.dog "$bead_id" --nudge 2>/dev/null; then
    log "Dispatched gastown.dog → $bead_id"
  else
    warn "sling failed for $bead_id — bead is open for manual pickup"
  fi

  log_json "$(printf '{"ts":"%s","event":"incident_opened","key":"%s","bead":"%s","attempt":1}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$key" "$bead_id")"
  echo "$bead_id"
}

# is_incident_resolved <bead_id> — true if bead is closed
is_incident_resolved() {
  local bead_id="$1"
  local status
  status=$(bd -C "$GC_CITY" show "$bead_id" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | .status // "open"' 2>/dev/null || echo "open")
  [ "$status" = "closed" ]
}

# escalate_to_mayor <key> <bead_id> <reason>
escalate_to_mayor() {
  local key="$1" bead_id="$2" reason="$3"
  log "ESCALATING to Mayor: $key ($bead_id) — $reason"

  gc --city "$GC_CITY" mail send mayor \
    -s "Guardian: escalation — $key could not auto-heal" \
    -m "$(printf 'Guardian (guardian-dispatch.sh) exhausted %d auto-fix attempts for:\n\nKey: %s\nIncident bead: %s\nReason: %s\n\nThe machine cannot self-heal this. Mayor or human must intervene.' \
      "$FIX_CAP" "$key" "$bead_id" "$reason")" \
    2>/dev/null || warn "Could not mail Mayor for $key"

  notify -t "Guardian escalation" -p 4 \
    "🚨 $key could not auto-heal after $FIX_CAP attempts. Mayor escalated." \
    2>/dev/null || true

  log_json "$(printf '{"ts":"%s","event":"escalated","key":"%s","bead":"%s","reason":"%s"}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$key" "$bead_id" \
    "$(printf '%s' "$reason" | head -c 200 | tr '"\\' "' ")")"
}

# handle_incident <key> <problem_detected: 0|1> <title> <description> <repair_prompt> [extra_reason]
# Core lifecycle: open/track/verify/escalate.
handle_incident() {
  local key="$1" detected="$2" title="$3" desc="$4" repair_prompt="$5"
  local reason="${6:-}"
  local now; now=$(date +%s)

  local inc; inc=$(state_get_incident "$key")

  if [ "$detected" = "0" ]; then
    # Problem gone — if we had an open incident, close it
    if [ "$inc" != "null" ]; then
      local bead_id; bead_id=$(printf '%s' "$inc" | jq -r '.bead // ""')
      if [ -n "$bead_id" ] && ! is_incident_resolved "$bead_id"; then
        bd -C "$GC_CITY" close "$bead_id" --reason "Guardian: problem resolved on its own — auto-closing incident." \
          2>/dev/null || true
        log "Incident $key cleared (problem resolved, bead $bead_id auto-closed)"
      fi
      state_clear_incident "$key"
      log_json "$(printf '{"ts":"%s","event":"incident_resolved","key":"%s","bead":"%s"}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$key" "$bead_id")"
    fi
    return 0
  fi

  # Problem detected — check if we have an existing open incident
  if [ "$inc" = "null" ]; then
    # No prior incident — open one
    local bead_id; bead_id=$(open_incident "$key" "$title" "$desc" "$repair_prompt") || return 1
    state_set_incident "$key" "$(printf '{"bead":"%s","attempt":1,"opened_at":%d,"last_checked":%d,"escalated":false}' \
      "$bead_id" "$now" "$now")"
    return 0
  fi

  # Existing incident — check for recovery or bump attempt
  local bead_id; bead_id=$(printf '%s' "$inc" | jq -r '.bead // ""')
  local attempt; attempt=$(printf '%s' "$inc" | jq -r '.attempt // 1')
  local last_checked; last_checked=$(printf '%s' "$inc" | jq -r '.last_checked // 0')
  local escalated; escalated=$(printf '%s' "$inc" | jq -r '.escalated // false')

  # Don't re-check too frequently
  local check_age=$(( now - last_checked ))
  if [ "$check_age" -lt "$REALERT_SEC" ]; then
    return 0
  fi

  # Is the bead resolved?
  if [ -n "$bead_id" ] && is_incident_resolved "$bead_id"; then
    log "Incident $key resolved (bead $bead_id closed)"
    state_clear_incident "$key"
    log_json "$(printf '{"ts":"%s","event":"incident_resolved","key":"%s","bead":"%s","attempts":%s}' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$key" "$bead_id" "$attempt")"
    return 0
  fi

  # Already escalated — don't spam
  if [ "$escalated" = "true" ]; then
    state_set_incident "$key" "$(printf '%s' "$inc" | jq -c ".last_checked = $now")"
    return 0
  fi

  # Bump attempt counter
  attempt=$(( attempt + 1 ))
  state_set_incident "$key" "$(printf '%s' "$inc" \
    | jq -c ".attempt = $attempt | .last_checked = $now")"

  log "Incident $key — attempt $attempt/$FIX_CAP (bead $bead_id still open, problem persists)"

  if [ "$attempt" -gt "$FIX_CAP" ]; then
    # Cap reached — escalate
    bd -C "$GC_CITY" label add "$bead_id" "guardian:needs-human" -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$bead_id" \
      "Guardian auto-fix cap ($FIX_CAP attempts) exhausted. Escalated to Mayor. No further auto-retry." \
      2>/dev/null || true
    escalate_to_mayor "$key" "$bead_id" "${reason:-problem persists after $FIX_CAP fix cycles}"
    state_set_incident "$key" "$(printf '%s' "$inc" \
      | jq -c ".attempt = $attempt | .last_checked = $now | .escalated = true")"
  else
    # Re-dispatch repair worker (new nudge on the same bead)
    log "Re-dispatching repair worker for $key (attempt $attempt)"
    gc --city "$GC_CITY" sling gastown.dog "$bead_id" --nudge 2>/dev/null || \
      warn "re-sling failed for $bead_id"
    log_json "$(printf '{"ts":"%s","event":"incident_redispatch","key":"%s","bead":"%s","attempt":%d}' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$key" "$bead_id" "$attempt")"
  fi
}

# ── Engine stall detection ────────────────────────────────────────────────────

check_engine_stall() {
  local class="$1"       # engine-stall-gate | engine-stall-pilot
  local label="$2"       # human-readable label for logs/beads
  local log_file="$3"    # the log file whose mtime we check
  local launchd_labels="$4"  # space-sep list of launchd service labels to restart

  local age; age=$(file_age_sec "$log_file")

  if [ "$age" -lt "$ENGINE_STALL_SEC" ]; then
    handle_incident "$class" "0" "" "" ""
    return 0
  fi

  log "Engine stall detected: $class — $label log stale ${age}s (> ${ENGINE_STALL_SEC}s threshold)"

  # Attempt to restart stalled services inline (attempt 1 recovery)
  local inc; inc=$(state_get_incident "$class")
  if [ "$inc" = "null" ]; then
    # First detection — try launchctl restart before opening a bead
    log "Attempting launchctl restart for $class"
    local restarted=0
    for svc in $launchd_labels; do
      local pid; pid=$(launchd_pid "$svc")
      if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
        # Service is running (possibly hung) — force restart
        log "kickstart -k $svc (PID=$pid, log stale)"
        launchctl kickstart -k "gui/$(id -u)/$svc" 2>/dev/null && restarted=1 || \
          launchctl kickstart -k "$svc" 2>/dev/null && restarted=1 || true
      else
        # Service not running — start it
        log "start $svc (not running, log stale)"
        launchctl start "$svc" 2>/dev/null && restarted=1 || true
      fi
    done
    if [ "$restarted" = "1" ]; then
      log "Issued launchctl restart for $class — will verify on next cycle"
      log_json "$(printf '{"ts":"%s","event":"engine_restart_attempted","class":"%s","services":"%s"}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$class" "$launchd_labels")"
      notify -t "Guardian" "Engine stall: attempted restart of $label — verifying next cycle" \
        2>/dev/null || true
      # Open a "monitoring" incident so we track recovery
      local bead_id
      bead_id=$(open_incident "$class" \
        "Guardian: $label engine stall (auto-restart attempted)" \
        "$(printf 'Guardian detected %s log stale %ds (>%ds threshold).\n\nServices: %s\n\nAuto-restart was attempted via launchctl. Verifying recovery on next guardian cycle (~5min).\n\nIf the engine is still stale on the next cycle, this incident will trigger a repair worker dispatch.' \
          "$label" "$age" "$ENGINE_STALL_SEC" "$launchd_labels")" \
        "$(printf 'GUARDIAN ENGINE-STALL REPAIR\n\nEngine: %s\nLog file: %s\nStale: %ds\n\n1. Check: launchctl list %s\n2. If log still stale: launchctl kickstart -k each service\n3. Check logs: tail -50 %s\n4. Once log updates within 5 min, close this bead.\n5. If engine does not recover: escalate via mail to mayor.' \
          "$label" "$log_file" "$age" "$launchd_labels" "$log_file")") || return 0
      local now; now=$(date +%s)
      state_set_incident "$class" "$(printf '{"bead":"%s","attempt":1,"opened_at":%d,"last_checked":%d,"escalated":false}' \
        "$bead_id" "$now" "$now")"
      return 0
    fi
  fi

  # No inline fix possible or prior incident open — use handle_incident lifecycle
  handle_incident "$class" "1" \
    "Guardian: $label engine stall" \
    "$(printf 'Guardian detected %s log stale %ds (>%ds threshold).\n\nServices: %s\n\nThe engine is not sweeping. Gate/pilot work may be stalled.' \
      "$label" "$age" "$ENGINE_STALL_SEC" "$launchd_labels")" \
    "$(printf 'GUARDIAN ENGINE-STALL REPAIR\n\nEngine: %s\nLog: %s (stale %ds)\nServices: %s\n\n1. launchctl list each service above\n2. launchctl kickstart -k <hung service> OR launchctl start <stopped service>\n3. Monitor: watch log mtime for 5min\n4. Close bead when engine is sweeping again (log updated within last 3min).' \
      "$label" "$log_file" "$age" "$launchd_labels")" \
    "$label log stale ${age}s"
}

# ── Real-jam detection ────────────────────────────────────────────────────────

check_real_jams() {
  local now; now=$(date +%s)
  local lines
  lines=$(cat "$QG_LOG" 2>/dev/null) || return 0

  # Find the most recent event per marker bead
  declare -A last_event
  declare -A last_ts
  while IFS= read -r line; do
    local b ts ev
    b=$(printf '%s' "$line" | jq -r '.marker // .bead // ""' 2>/dev/null || true)
    ts=$(printf '%s' "$line" | jq -r '.ts // ""' 2>/dev/null || true)
    ev=$(printf '%s' "$line" | jq -r '.event // ""' 2>/dev/null || true)
    [ -z "$b" ] && continue
    last_event["$b"]="$ev"
    last_ts["$b"]="$ts"
  done <<< "$lines"

  for marker in "${!last_event[@]}"; do
    local ev="${last_event[$marker]}" ts="${last_ts[$marker]}"
    [ "$ev" != "guard_queued" ] && continue

    # Compute age
    local ts_epoch
    ts_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${ts%%Z*}" "+%s" 2>/dev/null || echo "0")
    local age=$(( now - ts_epoch ))
    [ "$age" -lt "$REAL_JAM_SEC" ] && continue

    # Verify the marker is still actually queued (not already resolved)
    local still_queued
    still_queued=$(bd -C "$GC_CITY" show "$marker" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | .labels // [] | map(select(. == "gate-status:queued")) | length > 0' \
      2>/dev/null || echo "false")
    if [ "$still_queued" != "true" ]; then
      handle_incident "real-jam:$marker" "0" "" "" ""
      continue
    fi

    local key="real-jam:$marker"
    log "Real jam: marker $marker queued ${age}s (> ${REAL_JAM_SEC}s)"

    handle_incident "$key" "1" \
      "Guardian: gate marker $marker stuck (real jam, ${age}s queued)" \
      "$(printf 'Gate marker %s has been in gate-status:queued for %ds (>%ds threshold).\nQueued at: %s\n\nThis is a TRUE gate jam — the guard has not picked up this marker.\nThe gate reconciler (ga-tmug fix) should handle TTL recovery, but it has not acted yet.' \
        "$marker" "$age" "$REAL_JAM_SEC" "$ts")" \
      "$(printf 'GUARDIAN REAL-JAM REPAIR\n\nMarker: %s (gate-status:queued for %ds)\n\n1. Check: bd -C $GC_CITY show %s\n2. Check guard log: tail -100 %s\n3. If guard is running but skipping this marker: investigate why (TTL, locked, etc.)\n4. If guard is stalled: see engine-stall incident\n5. Manually re-queue if stuck: bd -C $GC_CITY label set %s gate-status:ready\n6. Close this bead when the gate run completes (PASS or FAIL).' \
        "$marker" "$age" "$marker" "$GATE_GUARD_LOG" "$marker")"
  done
}

# ── Delivery-fail detection ───────────────────────────────────────────────────

check_delivery_fails() {
  local seen; seen=$(state_get_seen "seen_sd")
  local total; total=$(wc -l < "$SD_LOG" 2>/dev/null || echo "0")
  total=$(( total + 0 ))

  if [ "$total" -le "$seen" ]; then
    return 0
  fi

  # Read new lines
  local new_lines
  new_lines=$(tail -n "+$((seen + 1))" "$SD_LOG" 2>/dev/null) || { state_update_seen "seen_sd" "$total"; return 0; }
  state_update_seen "seen_sd" "$total"

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local result story_id rig
    result=$(printf '%s' "$line" | jq -r '.result // ""' 2>/dev/null || true)
    story_id=$(printf '%s' "$line" | jq -r '.story_id // .story // ""' 2>/dev/null || true)
    rig=$(printf '%s' "$line" | jq -r '.rig // ""' 2>/dev/null || true)

    # Only act on FAIL or HALT
    case "$result" in
      *FAIL*|*HALT*) ;;
      *) continue ;;
    esac

    [ -z "$story_id" ] && continue

    local key="delivery-fail:$story_id"
    log "Delivery fail detected: story=$story_id rig=$rig result=$result"

    handle_incident "$key" "1" \
      "Guardian: delivery failed — $story_id ($rig)" \
      "$(printf 'Story delivery FAILED for %s (rig: %s, result: %s).\n\nDelivery log line:\n%s\n\nThis story was merged but delivery/prod-test did not complete successfully.' \
        "$story_id" "$rig" "$result" "$line")" \
      "$(printf 'GUARDIAN DELIVERY-FAIL REPAIR\n\nStory: %s\nRig: %s\nResult: %s\n\n1. Check delivery log: grep %s %s\n2. Check story bead: bd -C $GC_CITY show %s\n3. Check prod-test output for the rig\n4. Identify root cause (deploy conflict, prod-test failure, daemon issue)\n5. Fix root cause, re-run delivery manually or via gate if code change needed\n6. Close this bead when delivery PASS confirmed.' \
        "$story_id" "$rig" "$result" "$story_id" "$SD_LOG" "$story_id")"
  done <<< "$new_lines"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  log "Guardian sweep starting $ts"

  # 1. Engine stalls
  check_engine_stall "engine-stall-gate" \
    "quality-gate-dispatcher" \
    "$GATE_DISP_LOG" \
    "com.gascity.quality-gate-dispatcher com.gascity.quality-gate-guard"

  check_engine_stall "engine-stall-pilot" \
    "pilot-dispatcher" \
    "$PILOT_LOG" \
    "com.gascity.pilot"

  # 2. Real jams (stuck gate markers)
  check_real_jams

  # 3. Delivery failures
  check_delivery_fails

  # Write liveness heartbeat last (proof this sweep completed)
  heartbeat

  log "Guardian sweep complete $ts"
  log_json "$(printf '{"ts":"%s","event":"guardian_sweep","result":"ok"}' "$ts")"
}

# ── Guard against concurrent runs ─────────────────────────────────────────────
LOCK="$GC_CITY/.gc/guardian.lock"
if [ -e "$LOCK" ]; then
  LOCK_PID=$(cat "$LOCK" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "Another guardian instance is running (PID $LOCK_PID) — exiting"
    exit 0
  fi
  rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

main
