#!/usr/bin/env bash
# crew-liveness-probe.sh — detect and heal wedged crews holding story:in-flight beads.
#
# imp21: A crew that is alive (Claude session running) but has made no git commits
# for PROBE_STALE_MIN minutes is wedged — it's consuming a slot without making
# progress. The reclaim-guard fires at 25min; this probe fires at PROBE_STALE_MIN
# (default 15min) to nudge the crew BEFORE reclaim-guard re-dispatches the bead
# to the same dead session (infinite loop).
#
# Detection: for each story:in-flight + pilot:dispatched bead across rig stores,
# check how long since the bead was last updated_at. If longer than PROBE_STALE_MIN
# AND the assignee session is still alive (gc session list), nudge on first sweep,
# and HEAL on second consecutive sweep confirming the crew is still stale.
#
# HEAL (CLP_HEAL_ENABLED=1, default 0):
#   1. Strip pilot:dispatched + story:in-flight labels from the bead → re-enters dispatch
#   2. Clear the bead's assignee → un-owned
#   3. Suspend the crew agent via `gc agent suspend` → Pilot skips it next dispatch cycle
#      (Pilot reads gc agent list | awk '$2=="suspended"' in _pilot_suspended_crews(),
#       checked at pick_pool_builder() lines 750+760 in pilot-dispatcher.sh)
#
# SAFETY (2-confirmation):
#   State files are written per-bead to CLP_STATE_DIR on first detection.
#   Heal fires ONLY if the bead is STILL stale+assigned on the NEXT sweep AND
#   a prior-sweep state file exists (≥ CLP_CONFIRM_MIN minutes old).
#   A slow-but-alive crew is NOT healed — it must appear stale across TWO sweeps.
#
# Knobs:
#   CLP_ENABLED=1              — enable detect+nudge (default 0)
#   CLP_HEAL_ENABLED=1         — enable heal actions (default 0; canary after review)
#   CLP_PROBE_STALE_MIN=15     — stale threshold in minutes (< reclaim 25min)
#   CLP_CONFIRM_MIN=8          — min minutes between first-nudge and heal (default 8)
#   CLP_STORES                 — space-separated rig store paths
#   CLP_DRY_RUN=1              — report only, no nudge/heal
#   CLP_BD=bd                  — bd binary override (test seam)
#   CLP_GC=gc                  — gc binary override (test seam)
#   CLP_STATE_DIR              — directory for per-bead confirmation state files
#
# Runs every 10 minutes (StartInterval 600). DPW_CRITICAL: add after verifying live.
set -uo pipefail

CLP_ENABLED="${CLP_ENABLED:-0}"
CLP_HEAL_ENABLED="${CLP_HEAL_ENABLED:-0}"
CLP_PROBE_STALE_MIN="${CLP_PROBE_STALE_MIN:-15}"
CLP_CONFIRM_MIN="${CLP_CONFIRM_MIN:-8}"
CLP_STORES="${CLP_STORES:-/Users/athos/gt/.gascity-gastown-hq /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers}"
CLP_DRY_RUN="${CLP_DRY_RUN:-0}"
BD="${CLP_BD:-bd}"
GC="${CLP_GC:-gc}"
LOG="${CLP_LOG:-/Users/athos/gt/.gascity-gastown-hq/.gc/logs/crew-liveness-probe.log}"
CLP_STATE_DIR="${CLP_STATE_DIR:-/Users/athos/gt/.gascity-gastown-hq/.gc/clp-state}"

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

_nudge() {  # crew-id bead-id
  [ "$CLP_DRY_RUN" = "1" ] && { log "  DRY: would nudge $1 about bead $2"; return 0; }
  "$GC" nudge "$1" "liveness probe: bead $2 has been in-flight for ${CLP_PROBE_STALE_MIN}+ min with no recent commit — please send a status note or commit progress" 2>/dev/null || true
}

# _heal crew-id bead-id store-path
# Strips in-flight labels, clears assignee, suspends the crew agent.
# Called ONLY after 2-confirmation; SAFETY-critical.
_heal() {
  local crew="$1" bead="$2" store="$3"
  log "  HEAL: releasing bead $bead from crew $crew (store=$store)"

  if [ "$CLP_DRY_RUN" = "1" ]; then
    log "  DRY: would strip labels pilot:dispatched+story:in-flight, clear assignee, suspend $crew"
    return 0
  fi

  # Strip dispatch labels so bead re-enters the dispatch pool
  "$BD" -C "$store" label remove "$bead" pilot:dispatched 2>/dev/null \
    && log "  HEAL: stripped pilot:dispatched from $bead" \
    || log "  HEAL WARN: failed to strip pilot:dispatched from $bead (may already be gone)"
  "$BD" -C "$store" label remove "$bead" story:in-flight 2>/dev/null \
    && log "  HEAL: stripped story:in-flight from $bead" \
    || log "  HEAL WARN: failed to strip story:in-flight from $bead"

  # Clear assignee — bead now unowned for Pilot to re-assign
  "$BD" -C "$store" assign "$bead" "" 2>/dev/null \
    && log "  HEAL: cleared assignee on $bead" \
    || log "  HEAL WARN: failed to clear assignee on $bead"

  # Suspend the crew agent so Pilot does NOT re-dispatch to the same dead session.
  # Pilot honors this via _crew_is_suspended() → gc agent list | awk '$2=="suspended"'
  # checked at pick_pool_builder() (pilot-dispatcher.sh lines 750, 760).
  #
  # RISK: if the crew is still alive and working on ANOTHER bead, suspending it
  # prevents new dispatches to it. Mitigation: we only reach here after 2-sweep
  # confirmation that THIS bead is still stale on this crew, which strongly implies
  # the crew is wedged. The crew can be resumed manually via `gc agent resume <name>`.
  "$GC" -C /Users/athos/gt/.gascity-gastown-hq agent suspend "$crew" 2>/dev/null \
    && log "  HEAL: suspended crew agent $crew" \
    || log "  HEAL WARN: failed to suspend crew agent $crew (may not be a city agent)"
}

_live_sessions() {
  "$GC" session list --json 2>/dev/null | jq -r '.[].name' 2>/dev/null || true
}

# _state_file bead-id crew-id — returns path to confirmation state file
_state_file() {
  mkdir -p "$CLP_STATE_DIR" 2>/dev/null || true
  echo "${CLP_STATE_DIR}/${1}__${2}.nudged"
}

# _record_nudge bead-id crew-id — write state file with current epoch
_record_nudge() {
  local sf; sf=$(_state_file "$1" "$2")
  date +%s > "$sf" 2>/dev/null || true
}

# _is_confirmed bead-id crew-id — returns 0 if state file exists AND is ≥ CLP_CONFIRM_MIN old
_is_confirmed() {
  local sf; sf=$(_state_file "$1" "$2")
  [ -f "$sf" ] || return 1
  local file_ts; file_ts=$(cat "$sf" 2>/dev/null) || return 1
  [ -n "$file_ts" ] || return 1
  local now; now=$(date +%s)
  local age=$(( now - file_ts ))
  local threshold=$(( CLP_CONFIRM_MIN * 60 ))
  [ "$age" -ge "$threshold" ] && return 0 || return 1
}

# _clear_state bead-id crew-id — remove state file after heal
_clear_state() {
  local sf; sf=$(_state_file "$1" "$2")
  rm -f "$sf" 2>/dev/null || true
}

run_probe() {
  if [ "$CLP_ENABLED" != "1" ]; then log "disabled (CLP_ENABLED!=1)"; return 0; fi
  local store id assignee updated_at stale_sec probed=0 healed=0 live_sessions
  local now; now=$(date +%s)
  local stale_threshold=$(( CLP_PROBE_STALE_MIN * 60 ))

  # Cache live sessions once per probe run (gc session list is expensive)
  live_sessions=$(_live_sessions)

  # Clean up state files for beads that have cleared (stale/expired files ≥ 2h old)
  if [ -d "$CLP_STATE_DIR" ]; then
    find "$CLP_STATE_DIR" -name "*.nudged" -mmin +120 -delete 2>/dev/null || true
  fi

  for store in $CLP_STORES; do
    [ -d "$store" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      id=$(echo "$line" | jq -r '.id' 2>/dev/null)
      assignee=$(echo "$line" | jq -r '(.assignee // "")' 2>/dev/null)
      updated_at=$(echo "$line" | jq -r '(.updated_at // "")' 2>/dev/null)
      [ -n "$id" ] && [ -n "$assignee" ] && [ -n "$updated_at" ] || continue

      # Parse updated_at (UTC ISO8601) to epoch.
      # TZ=UTC0 forces BSD date to treat the parsed time as UTC, not local time.
      local updated_epoch
      updated_epoch=$(TZ=UTC0 date -jf "%Y-%m-%dT%H:%M:%S" "${updated_at%%Z}" +%s 2>/dev/null) \
        || updated_epoch=$(TZ=UTC date -d "$updated_at" +%s 2>/dev/null) || continue
      local stale_sec=$(( now - updated_epoch ))
      [ "$stale_sec" -ge "$stale_threshold" ] || continue

      # Check if assignee is a live session.
      # If NOT live: a dead session means the reclaim-guard will handle it; skip.
      # We only act on sessions still alive (wedged, not dead).
      if ! echo "$live_sessions" | grep -qF "$assignee" 2>/dev/null; then
        log "probe skip: $id assignee=$assignee — NOT a live session (may already be dead/reclaimed)"
        _clear_state "$id" "$assignee"
        continue
      fi

      # === 2-CONFIRMATION SAFETY ===
      # First sweep: nudge + record state. Do NOT heal yet.
      # Second sweep (state file ≥ CLP_CONFIRM_MIN old): confirmed wedged → maybe heal.
      if _is_confirmed "$id" "$assignee"; then
        # CONFIRMED: crew was nudged ≥ CLP_CONFIRM_MIN ago and is STILL stale+alive
        log "probe CONFIRMED-WEDGED: $id assignee=$assignee stale=${stale_sec}s — crew is confirmed wedged (2-sweep)"
        if [ "$CLP_HEAL_ENABLED" = "1" ]; then
          _heal "$assignee" "$id" "$store"
          _clear_state "$id" "$assignee"
          healed=$(( healed + 1 ))
        else
          log "  HEAL skipped (CLP_HEAL_ENABLED!=1) — crew $assignee still wedged on $id"
          # Re-nudge since we skipped heal, so crew gets another poke
          _nudge "$assignee" "$id"
          probed=$(( probed + 1 ))
        fi
      else
        # FIRST SWEEP: nudge + record state file for 2-confirmation
        log "probe FIRST-SWEEP: $id assignee=$assignee stale=${stale_sec}s (>${CLP_PROBE_STALE_MIN}min) — nudging, recording state"
        _nudge "$assignee" "$id"
        _record_nudge "$id" "$assignee"
        probed=$(( probed + 1 ))
      fi
    done < <("$BD" -C "$store" list -l story:in-flight -l pilot:dispatched --json -n 0 2>/dev/null \
              | jq -c '.[] | select((.assignee // "") != "")' 2>/dev/null)
  done
  log "probe complete: nudged $probed crew(s), healed $healed$([ "$CLP_DRY_RUN" = "1" ] && echo ' (DRY)')"
}

# ── selftest ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ✗ $1"; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  NOW_ST=$(date +%s)
  NUDGE_LOG="$TMP/nudges"
  HEAL_LOG="$TMP/heals"
  SUSPEND_LOG="$TMP/suspends"
  : > "$NUDGE_LOG"; : > "$HEAL_LOG"; : > "$SUSPEND_LOG"

  # Stale bead (updated 20 min ago), live crew
  STALE_TS=$(date -u -r $(( NOW_ST - 1200 )) "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
             || date -u -d "@$(( NOW_ST - 1200 ))" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
  # Fresh bead (updated 5 min ago), live crew
  FRESH_TS=$(date -u -r $(( NOW_ST - 300 )) "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
             || date -u -d "@$(( NOW_ST - 300 ))" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

  cat > "$TMP/bd" <<BDSHIM
#!/usr/bin/env bash
case "\$*" in
  *"list -l story:in-flight -l pilot:dispatched"*)
    echo '[{"id":"wa-stale","assignee":"mila-wa","updated_at":"'"$STALE_TS"'"},{"id":"wa-fresh","assignee":"mila-wa","updated_at":"'"$FRESH_TS"'"},{"id":"wa-dead","assignee":"dead-crew","updated_at":"'"$STALE_TS"'"}]' ;;
  *"label remove"*) echo "\$*" >> "${HEAL_LOG}" ;;
  *"assign"*) echo "\$*" >> "${HEAL_LOG}" ;;
  *) echo '[]' ;;
esac
BDSHIM
  chmod +x "$TMP/bd"

  cat > "$TMP/gc" <<GCSHIM
#!/usr/bin/env bash
case "\$*" in
  *"session list --json"*) echo '[{"name":"mila-wa"}]' ;;
  *"nudge"*) echo "\$*" >> "${NUDGE_LOG}" ;;
  *"agent suspend"*) echo "\$*" >> "${SUSPEND_LOG}" ;;
  *) true ;;
esac
GCSHIM
  chmod +x "$TMP/gc"

  BD="$TMP/bd"; GC="$TMP/gc"
  CLP_STORES="$TMP"
  LOG="$TMP/log"
  CLP_STATE_DIR="$TMP/state"
  CLP_ENABLED=1; CLP_PROBE_STALE_MIN=15; CLP_DRY_RUN=0
  CLP_HEAL_ENABLED=0; CLP_CONFIRM_MIN=8

  echo "=== Scenario 1: First sweep — nudge only, no heal ==="
  run_probe

  grep -q 'wa-stale' "$NUDGE_LOG" && ok "1: nudged stale in-flight bead with live crew" || bad "1: should have nudged wa-stale"
  grep -q 'wa-fresh' "$NUDGE_LOG" && bad "1: NUDGED a fresh bead (< stale threshold)" || ok "1: skipped fresh bead wa-fresh (not stale yet)"
  grep -q 'dead-crew' "$NUDGE_LOG" && bad "1: NUDGED a dead crew (not a live session)" || ok "1: skipped dead-crew (not in live session list)"
  [ -s "$HEAL_LOG" ] && bad "1: heal actions ran on first sweep" || ok "1: no heal on first sweep"
  [ -s "$SUSPEND_LOG" ] && bad "1: suspend ran on first sweep" || ok "1: no suspend on first sweep"
  [ -f "$TMP/state/wa-stale__mila-wa.nudged" ] && ok "1: state file recorded for wa-stale" || bad "1: state file not written for wa-stale"

  echo ""
  echo "=== Scenario 2: Second sweep immediately — NOT confirmed yet (CLP_CONFIRM_MIN=8) ==="
  : > "$NUDGE_LOG"; : > "$HEAL_LOG"; : > "$SUSPEND_LOG"
  CLP_HEAL_ENABLED=1  # enable heal so we can confirm gate stops it
  run_probe

  [ -s "$HEAL_LOG" ] && bad "2: heal ran before CLP_CONFIRM_MIN elapsed" || ok "2: no heal when state file is too fresh"
  # Should re-nudge since HEAL_ENABLED=1 but confirmation not met — actually first-sweep path
  # re-records nudge; the state file IS there but too young, so we re-nudge (first-sweep branch)
  grep -q 'wa-stale' "$NUDGE_LOG" && ok "2: re-nudged on second immediate sweep (not confirmed yet)" || bad "2: expected re-nudge on second sweep"
  [ -s "$SUSPEND_LOG" ] && bad "2: suspend ran before confirmation" || ok "2: no suspend before confirmation"

  echo ""
  echo "=== Scenario 3: Confirmed sweep (backdate state file by CLP_CONFIRM_MIN+1 min) ==="
  : > "$NUDGE_LOG"; : > "$HEAL_LOG"; : > "$SUSPEND_LOG"
  # Backdate the state file so it appears old enough for confirmation
  STATE_FILE="$TMP/state/wa-stale__mila-wa.nudged"
  echo $(( NOW_ST - (8 * 60 + 60) )) > "$STATE_FILE"  # 9 min ago → confirmed
  CLP_HEAL_ENABLED=1
  run_probe

  grep -q 'label remove.*wa-stale.*pilot:dispatched' "$HEAL_LOG" && ok "3: stripped pilot:dispatched from wa-stale" || bad "3: expected pilot:dispatched removal"
  grep -q 'label remove.*wa-stale.*story:in-flight' "$HEAL_LOG" && ok "3: stripped story:in-flight from wa-stale" || bad "3: expected story:in-flight removal"
  grep -q 'assign.*wa-stale' "$HEAL_LOG" && ok "3: cleared assignee on wa-stale" || bad "3: expected assignee clear"
  grep -q 'agent suspend.*mila-wa' "$SUSPEND_LOG" && ok "3: suspended crew agent mila-wa" || bad "3: expected gc agent suspend mila-wa"
  [ -f "$STATE_FILE" ] && bad "3: state file NOT cleared after heal" || ok "3: state file cleared after heal"
  grep -q 'wa-stale' "$NUDGE_LOG" && bad "3: nudged wa-stale on confirmed heal sweep (should heal, not nudge)" || ok "3: no nudge on confirmed-heal sweep"

  echo ""
  echo "=== Scenario 4: Slow crew (alive, NOT stale) — no action ==="
  : > "$NUDGE_LOG"; : > "$HEAL_LOG"; : > "$SUSPEND_LOG"
  CLP_HEAL_ENABLED=1; CLP_PROBE_STALE_MIN=25  # raise threshold so STALE_TS bead is NOT stale
  run_probe
  [ -s "$NUDGE_LOG" ] && bad "4: nudged a slow-but-not-stale crew" || ok "4: no action for slow crew below stale threshold"

  echo ""
  echo "=== Scenario 5: DRY_RUN with confirmed state — no actual heal ==="
  : > "$NUDGE_LOG"; : > "$HEAL_LOG"; : > "$SUSPEND_LOG"
  CLP_PROBE_STALE_MIN=15; CLP_HEAL_ENABLED=1; CLP_DRY_RUN=1
  echo $(( NOW_ST - (8 * 60 + 60) )) > "$TMP/state/wa-stale__mila-wa.nudged"
  run_probe
  [ -s "$HEAL_LOG" ] && bad "5: DRY_RUN: heal actions ran" || ok "5: DRY_RUN: no heal actions"
  [ -s "$SUSPEND_LOG" ] && bad "5: DRY_RUN: suspend ran" || ok "5: DRY_RUN: no suspend"

  echo ""
  echo "=== Scenario 6: CLP_ENABLED=0 — disabled, no-op ==="
  : > "$NUDGE_LOG"; : > "$HEAL_LOG"; : > "$SUSPEND_LOG"
  CLP_DRY_RUN=0; CLP_ENABLED=0; run_probe
  [ ! -s "$NUDGE_LOG" ] && [ ! -s "$HEAL_LOG" ] && ok "6: CLP_ENABLED=0: complete no-op" || bad "6: CLP_ENABLED=0 still acted"

  echo ""
  echo "=== Scenario 7: HEAL_ENABLED=0 with confirmed bead — re-nudge but no heal ==="
  : > "$NUDGE_LOG"; : > "$HEAL_LOG"; : > "$SUSPEND_LOG"
  CLP_ENABLED=1; CLP_HEAL_ENABLED=0; CLP_PROBE_STALE_MIN=15
  echo $(( NOW_ST - (8 * 60 + 60) )) > "$TMP/state/wa-stale__mila-wa.nudged"
  run_probe
  [ -s "$HEAL_LOG" ] && bad "7: HEAL_ENABLED=0: heal actions ran" || ok "7: HEAL_ENABLED=0: no heal"
  [ -s "$SUSPEND_LOG" ] && bad "7: HEAL_ENABLED=0: suspend ran" || ok "7: HEAL_ENABLED=0: no suspend"
  grep -q 'wa-stale' "$NUDGE_LOG" && ok "7: HEAL_ENABLED=0: re-nudged confirmed-wedged crew" || bad "7: HEAL_ENABLED=0: expected re-nudge"

  echo ""
  echo "crew-liveness-probe selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_probe
