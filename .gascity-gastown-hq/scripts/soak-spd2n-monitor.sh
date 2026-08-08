#!/usr/bin/env bash
# soak-spd2n-monitor.sh — 24h "imparável" soak for ga-spd2n.
# Runs every 30min via launchd (com.gascity.soak-spd2n). Pure shell, no LLM.
# Samples gate/pilot/Dolt/funnel health, appends a checkpoint, notifies on a
# SUSTAINED wedge (the soak tests self-healing: transient wedge that recovers = OK;
# no progress for >WEDGE_FAIL_MIN across consecutive checks = FAIL). At >=24h it
# writes a final PASS/FAIL verdict, notifies, and unloads itself.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG="$CITY/.gc/logs/soak-spd2n.jsonl"
START_F="$CITY/.gc/soak-spd2n.start"           # epoch of soak start
STRIKES_F="/tmp/soak-spd2n.strikes"            # consecutive wedge checks
DOLT_PORT=52756
SOAK_HOURS="${SOAK_HOURS:-24}"
WEDGE_FAIL_STRIKES="${WEDGE_FAIL_STRIKES:-3}"  # 3 consecutive 30min checks = 90min sustained
GATE_LOG="$CITY/.gc/logs/quality-gate-dispatcher.log"
PILOT_LOG=$(ls -t "$CITY"/.gc/logs/*pilot-dispatcher*.log 2>/dev/null | head -1)
PLIST_LABEL="com.gascity.soak-spd2n"

now=$(date +%s)
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
[ -f "$START_F" ] || echo "$now" > "$START_F"
start=$(cat "$START_F" 2>/dev/null || echo "$now")
elapsed_h=$(( (now - start) / 3600 ))

# --- health probes (each: 1=healthy 0=problem) ---
# sweep freshness: a dispatcher that swept within 15min is alive (sweeps ~60s)
fresh() { local f="$1"; [ -f "$f" ] || { echo 0; return; }; local m=$(( (now - $(stat -f %m "$f" 2>/dev/null || echo 0)) / 60 )); [ "$m" -le 15 ] && echo 1 || echo 0; }
gate_alive=$(fresh "$GATE_LOG")
pilot_alive=$(fresh "$PILOT_LOG")
dolt_ok=$(timeout 8 python3 -c "import pymysql;pymysql.connect(host='127.0.0.1',port=$DOLT_PORT,user='root',connect_timeout=6).cursor().execute('SELECT 1');print(1)" 2>/dev/null || echo 0)
dolt_cpu=$(ps -p "$(pgrep -f 'dolt sql-server' | head -1)" -o %cpu= 2>/dev/null | tr -d ' ' || echo "?")
refino_ok=$(launchctl list 2>/dev/null | grep -qE 'com.gascity.(auto-refino|refino-gate)-dispatcher' && echo 1 || echo 0)
# progress: merges in the whole soak window (monotonic non-decreasing health signal)
merges=$(grep -c "verdict=PASS\|merge_sha" "$GATE_LOG" 2>/dev/null || echo 0)

wedged=0
[ "$gate_alive" = "0" ] && wedged=1
[ "$pilot_alive" = "0" ] && wedged=1
[ "$dolt_ok" = "0" ] && wedged=1

# strike accounting (sustained wedge detection)
strikes=$(cat "$STRIKES_F" 2>/dev/null || echo 0)
if [ "$wedged" = "1" ]; then strikes=$((strikes+1)); else strikes=0; fi
echo "$strikes" > "$STRIKES_F"

printf '{"ts":"%s","elapsed_h":%s,"gate_alive":%s,"pilot_alive":%s,"dolt_ok":%s,"dolt_cpu":"%s","refino_ok":%s,"merges":%s,"wedged":%s,"strikes":%s}\n' \
  "$ts" "$elapsed_h" "$gate_alive" "$pilot_alive" "$dolt_ok" "$dolt_cpu" "$refino_ok" "$merges" "$wedged" "$strikes" >> "$LOG" 2>/dev/null

# sustained wedge → FAIL notification (self-healing window exceeded)
if [ "$strikes" -ge "$WEDGE_FAIL_STRIKES" ]; then
  command -v notify >/dev/null 2>&1 && notify -p 5 -t 'Soak ga-spd2n WEDGE' "Sustained wedge ${strikes} checks (~$((strikes*30))min): gate=$gate_alive pilot=$pilot_alive dolt=$dolt_ok — NOT self-healing. Needs human." >/dev/null 2>&1 || true
fi

# 24h reached → final verdict + self-unload
if [ "$elapsed_h" -ge "$SOAK_HOURS" ]; then
  fails=$(grep -c '"wedged":1' "$LOG" 2>/dev/null || echo 0)
  total=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
  maxstrike=$(grep -oE '"strikes":[0-9]+' "$LOG" 2>/dev/null | grep -oE '[0-9]+' | sort -rn | head -1)
  verdict="PASS"; [ "${maxstrike:-0}" -ge "$WEDGE_FAIL_STRIKES" ] && verdict="FAIL"
  printf '{"ts":"%s","event":"FINAL","verdict":"%s","elapsed_h":%s,"checks":%s,"wedged_checks":%s,"max_consecutive_wedge":%s}\n' \
    "$ts" "$verdict" "$elapsed_h" "$total" "$fails" "${maxstrike:-0}" >> "$LOG" 2>/dev/null
  command -v notify >/dev/null 2>&1 && notify -p 4 -t "Soak ga-spd2n $verdict" "24h soak done: $verdict ($total checks, $fails wedged, max-consecutive=${maxstrike:-0}). Gate+Pilot imparáveis = $([ "$verdict" = PASS ] && echo SIM || echo NÃO)." >/dev/null 2>&1 || true
  # Durable handoff: mail the mayor so the NEXT mayor session reviews the verdict
  # even if no session was alive at conclusion (survives session death — the exact
  # use case for mail over nudge). The next mayor reads this in its inbox.
  ( cd "$CITY" && GC_CITY="$CITY" gc mail send mayor \
      -s "Soak ga-spd2n CONCLUDED: $verdict" \
      -m "24h imparável soak done. Verdict=$verdict. $total checks, $fails wedged, max-consecutive-wedge=${maxstrike:-0}. Log: .gc/logs/soak-spd2n.jsonl (event:FINAL). If PASS → declare refine→review→approve funnel + gate/pilot PRODUCTION-READY, close ga-spd2n, update memory. If FAIL → diagnose the wedged checkpoints + fix root. Also verify ga-fhhsh reached 'Sua vez' and wa-jjea merged via union-aware gate. (auto-sent by soak-spd2n-monitor at 24h)." >/dev/null 2>&1 ) || true
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
fi
exit 0
