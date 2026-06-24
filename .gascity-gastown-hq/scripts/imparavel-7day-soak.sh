#!/usr/bin/env bash
# imparavel-7day-soak.sh — the 7-day soak that measures the 99%-imparável KPI.
#
# Athos's acceptance criterion (EPIC ga-zph55): "depois de implementar o sistema
# inteiro, tem que ser implementada uma tarefa que vai ficar sete dias monitorando
# se tudo está acontecendo como a gente tinha planejado."
#
# Day 0 = first run (writes a start marker). Each day: compute the KPI from the
# flow-episode ledger via soak-metric.sh + notify progress. Day >= SOAK_DAYS:
# emit the FINAL report and self-disable (bootout) so it stops cleanly.
#
# The KPI (soak-metric.sh / imp25):
#   99% = auto_resolved / (auto_resolved + agent_healed + human_technical + still_open)
# human_product is excluded (product decisions are expected human-touch).
#
# Read-only except: the start marker + the log + the daily notify. Never mutates beads.
set -uo pipefail

HQ="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
MARK="${SOAK_MARK:-$HQ/.gc/imparavel-soak-start}"        # epoch of day 0
LOG="${SOAK_LOG:-$HQ/.gc/logs/imparavel-7day-soak.log}"
SOAK_DAYS="${IMPARAVEL_SOAK_DAYS:-7}"
NOTIFY="${SOAK_NOTIFY:-notify}"
METRIC="${SOAK_METRIC:-$HQ/scripts/soak-metric.sh}"
LABEL="com.gascity.imparavel-7day-soak"

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

run_soak() {
  # Day 0: arm the window (idempotent — only writes the marker once).
  [ -f "$MARK" ] || { date +%s > "$MARK"; log "soak START (day 0) — 99%-imparável 7-day window armed"; }

  local start now day kpi kpi_line stalls mins
  start=$(cat "$MARK" 2>/dev/null || date +%s)
  now=$(date +%s)
  day=$(( (now - start) / 86400 ))

  kpi=$(timeout 90 bash "$METRIC" 2>/dev/null || echo "")
  kpi_line=$(echo "$kpi" | grep -E 'KPI:' | head -1 | sed 's/^[[:space:]]*//')
  stalls=$(echo "$kpi"   | grep -E 'stalls-undetected' | head -1 | sed 's/^[[:space:]]*//')
  mins=$(echo "$kpi"     | grep -E 'minutos-parado'    | head -1 | sed 's/^[[:space:]]*//')

  if [ "$day" -ge "$SOAK_DAYS" ]; then
    "$NOTIFY" -t "🏁 SOAK imparável COMPLETO (${day}d)" -p 4 \
      "FINAL day ${day}/${SOAK_DAYS} — ${kpi_line:-KPI N/A} | ${stalls} | ${mins}" 2>/dev/null || true
    log "soak COMPLETE day $day/$SOAK_DAYS: ${kpi_line:-N/A} | ${stalls} | ${mins}"
    # self-disable at end of window (one-shot; ||true so a manual/selftest run is harmless)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  else
    "$NOTIFY" -t "📊 SOAK imparável ${day}/${SOAK_DAYS}d" -p 2 \
      "${kpi_line:-KPI N/A (baseline / no technical episodes yet)} | ${stalls}" 2>/dev/null || true
    log "soak day $day/$SOAK_DAYS: ${kpi_line:-N/A} | ${stalls}"
  fi
}

# ── selftest ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ✗ $1"; }
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  printf '#!/bin/bash\necho "KPI: 95.0%% (baseline)"; echo "  stalls-undetected: 1"; echo "  minutos-parado   : 12.0 min"\n' > "$T/metric"
  chmod +x "$T/metric"
  printf '#!/bin/bash\necho "$*" >> "%s/notifs"\n' "$T" > "$T/notify"; chmod +x "$T/notify"
  export SOAK_MARK="$T/mark" SOAK_LOG="$T/log" SOAK_METRIC="$T/metric" SOAK_NOTIFY="$T/notify" IMPARAVEL_SOAK_DAYS=7
  MARK="$T/mark"; LOG="$T/log"; METRIC="$T/metric"; NOTIFY="$T/notify"; SOAK_DAYS=7

  run_soak
  [ -f "$MARK" ] && ok "day0: start marker created" || bad "day0: no marker"
  grep -q '0/7' "$T/notifs" && ok "day0: notified day 0/7" || bad "day0: expected 0/7"
  grep -q '95.0%' "$T/notifs" && ok "day0: KPI carried into notif" || bad "day0: KPI missing"

  : > "$T/notifs"; echo $(( $(date +%s) - 3*86400 )) > "$MARK"; run_soak
  grep -q '3/7' "$T/notifs" && ok "day3: notified day 3/7" || bad "day3: expected 3/7"

  : > "$T/notifs"; echo $(( $(date +%s) - 7*86400 )) > "$MARK"; run_soak
  grep -qE 'COMPLETO|FINAL' "$T/notifs" && ok "day7: final report emitted" || bad "day7: expected final"

  : > "$T/notifs"; echo $(( $(date +%s) - 9*86400 )) > "$MARK"; run_soak
  grep -qE 'COMPLETO|FINAL' "$T/notifs" && ok "day9 (past end): still final, no crash" || bad "day9: expected final"

  echo "imparavel-7day-soak selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_soak
