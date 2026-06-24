#!/usr/bin/env bash
# crew-liveness-probe.sh — detect wedged crews holding story:in-flight beads.
#
# imp21: A crew that is alive (Claude session running) but has made no git commits
# for PROBE_STALE_MIN minutes is wedged — it's consuming a slot without making
# progress. The reclaim-guard fires at 25min; this probe fires at PROBE_STALE_MIN
# (default 15min) to nudge the crew BEFORE reclaim-guard re-dispatches the bead
# to the same dead session (infinite loop).
#
# Detection: for each story:in-flight + pilot:dispatched bead across rig stores,
# check how long since the bead was last updated_at. If longer than PROBE_STALE_MIN
# AND the assignee session is still alive (gc session list), send a gc nudge.
#
# Knobs:
#   CLP_ENABLED=1              — enable (default 0; enable after verifying in prod)
#   CLP_PROBE_STALE_MIN=15     — stale threshold in minutes (< reclaim 25min)
#   CLP_STORES                 — space-separated rig store paths
#   CLP_DRY_RUN=1              — report only, no nudge
#   CLP_BD=bd                  — bd binary override (test seam)
#   CLP_GC=gc                  — gc binary override (test seam)
#
# Runs every 5-10 minutes. DPW_CRITICAL: add after verifying live.
set -uo pipefail

CLP_ENABLED="${CLP_ENABLED:-0}"
CLP_PROBE_STALE_MIN="${CLP_PROBE_STALE_MIN:-15}"
CLP_STORES="${CLP_STORES:-/Users/athos/gt/.gascity-gastown-hq /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers}"
CLP_DRY_RUN="${CLP_DRY_RUN:-0}"
BD="${CLP_BD:-bd}"
GC="${CLP_GC:-gc}"
LOG="${CLP_LOG:-/Users/athos/gt/.gascity-gastown-hq/.gc/logs/crew-liveness-probe.log}"

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

_nudge() {  # crew-id bead-id
  [ "$CLP_DRY_RUN" = "1" ] && { log "  DRY: would nudge $1 about bead $2"; return 0; }
  "$GC" nudge "$1" "liveness probe: bead $2 has been in-flight for ${CLP_PROBE_STALE_MIN}+ min with no recent commit — please send a status note or commit progress" 2>/dev/null || true
}

_live_sessions() {
  "$GC" session list --json 2>/dev/null | jq -r '.[].name' 2>/dev/null || true
}

run_probe() {
  if [ "$CLP_ENABLED" != "1" ]; then log "disabled (CLP_ENABLED!=1)"; return 0; fi
  local store id assignee updated_at stale_sec probed=0 live_sessions
  local now; now=$(date +%s)
  local stale_threshold=$(( CLP_PROBE_STALE_MIN * 60 ))

  # Cache live sessions once per probe run (gc session list is expensive)
  live_sessions=$(_live_sessions)

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

      # Check if assignee is a live session
      if ! echo "$live_sessions" | grep -qF "$assignee" 2>/dev/null; then
        log "probe skip: $id assignee=$assignee — NOT a live session (may already be dead/reclaimed)"
        continue
      fi

      # Crew is alive but bead is stale → probe
      log "probe: $id assignee=$assignee stale=${stale_sec}s (>${CLP_PROBE_STALE_MIN}min) — nudging"
      _nudge "$assignee" "$id"
      probed=$(( probed + 1 ))
    done < <("$BD" -C "$store" list -l story:in-flight -l pilot:dispatched --json -n 0 2>/dev/null \
              | jq -c '.[] | select((.assignee // "") != "")' 2>/dev/null)
  done
  log "probe complete: nudged $probed crew(s)$([ "$CLP_DRY_RUN" = "1" ] && echo ' (DRY)')"
}

# ── selftest ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ✗ $1"; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  NOW_ST=$(date +%s)
  NUDGE_LOG="$TMP/nudges"
  : > "$NUDGE_LOG"
  SESS_LOG="$TMP/sessions"

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
  *) echo '[]' ;;
esac
BDSHIM
  chmod +x "$TMP/bd"

  # gc session list returns mila-wa as live (dead-crew NOT in list)
  # Note: $NUDGE_LOG is embedded directly (not via shell variable in subprocess)
  cat > "$TMP/gc" <<GCSHIM
#!/usr/bin/env bash
case "\$*" in
  *"session list --json"*) echo '[{"name":"mila-wa"}]' ;;
  *"nudge"*) echo "\$*" >> "${NUDGE_LOG}" ;;
  *) true ;;
esac
GCSHIM
  chmod +x "$TMP/gc"

  BD="$TMP/bd"; GC="$TMP/gc"; CLP_STORES="$TMP"; LOG="$TMP/log"
  CLP_ENABLED=1; CLP_PROBE_STALE_MIN=15; CLP_DRY_RUN=0
  run_probe

  echo "Scenario: crew-liveness-probe detects stale live crew, skips fresh and dead"
  grep -q 'wa-stale' "$NUDGE_LOG" && ok "probed stale in-flight bead with live crew" || bad "should have nudged wa-stale"
  grep -q 'wa-fresh' "$NUDGE_LOG" && bad "NUDGED a fresh bead (< stale threshold)" || ok "skipped fresh bead wa-fresh (not stale yet)"
  grep -q 'dead-crew' "$NUDGE_LOG" && bad "NUDGED a dead crew (should skip non-live sessions)" || ok "skipped dead-crew (not in live session list)"

  # DRY_RUN: no actual nudges
  : > "$NUDGE_LOG"; CLP_DRY_RUN=1; run_probe
  [ ! -s "$NUDGE_LOG" ] && ok "DRY_RUN: no nudges sent" || bad "DRY_RUN mutated (sent nudges)"

  # Disabled: no-op
  : > "$NUDGE_LOG"; CLP_DRY_RUN=0; CLP_ENABLED=0; run_probe
  [ ! -s "$NUDGE_LOG" ] && ok "CLP_ENABLED=0: no-op" || bad "CLP_ENABLED=0 still probed"

  echo ""; echo "crew-liveness-probe selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_probe
