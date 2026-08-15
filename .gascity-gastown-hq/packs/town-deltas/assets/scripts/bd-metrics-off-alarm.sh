#!/bin/bash
# bd-metrics-off-alarm.sh — ga-8g9ki5: alert if bd's anonymous telemetry ever
# gets re-enabled. This is the exact condition that filled ~/.beads/eventsData
# to 16GB and hit the filesystem's 65535-hardlink ceiling, hanging every
# spawned `bd send-metrics` child in kernel-level uninterruptible wait forever
# (ga-cpqxf3) — a state no application-level timeout can interrupt, since
# RunSendMetrics already has a 30s context timeout that does nothing against a
# true kernel wait. Prevention (never let metrics turn back on) is the only
# real fix; this script is the tripwire for that prevention failing.
#
# Checks bd's reported STATE only — never enumerates ~/.beads/eventsData
# itself. Any enumeration (ls/find/du/lsof +D) hangs the same way the flusher
# does once the directory is past the hardlink ceiling; ga-cpqxf3 confirmed
# this live 3x, including a dog's own lsof getting stuck the same way.
#
# Edge-triggered: alerts once on the OFF->ON transition (state recorded in
# STATE_FILE), not on every run while it stays ON, so the alert doesn't get
# buried under repeats if nobody acts on the first one immediately.
set -euo pipefail

STATE_FILE="${BD_METRICS_ALARM_STATE_FILE:-$HOME/.gastown/state/bd-metrics-alarm-last.txt}"
mkdir -p "$(dirname "$STATE_FILE")"

status_line=$(bd metrics 2>&1 | head -1)
case "$status_line" in
  *": ON"*)  current=on ;;
  *": OFF"*) current=off ;;
  *)
    printf 'bd-metrics-off-alarm: unexpected bd metrics output, cannot determine state: %s\n' "$status_line" >&2
    exit 1
    ;;
esac

previous=""
[ -f "$STATE_FILE" ] && previous=$(cat "$STATE_FILE")

printf '%s\n' "$current" > "$STATE_FILE"

if [ "$current" = "on" ] && [ "$previous" != "on" ]; then
  prev_label="${previous:-desconhecido (primeira checagem)}"
  notify -t 'bd telemetry re-ativada' -p 4 \
    "bd metrics = ON (estava: $prev_label). Mesmo gatilho que encheu eventsData a 16GB e travou o teto de hardlinks antes (ga-cpqxf3). Rode: bd metrics off"

  gc mail send mayor -s "bd metrics voltou a ON — ga-8g9ki5" -m "$(cat <<EOF
bd-metrics-off-alarm detectou bd metrics = ON em $(date -u +%Y-%m-%dT%H:%M:%SZ).
Estado anterior registrado: $prev_label.

Isto e a mesma condicao de origem que encheu ~/.beads/eventsData ate 16GB e
bateu o teto de 65535 hardlinks do filesystem, travando bd send-metrics em
kernel-level uninterruptible wait a cada invocacao de bd (ga-cpqxf3) --
estado que nenhum timeout de aplicacao consegue interromper.

Acao: bd metrics off

Contexto completo: ga-8g9ki5
EOF
)" 2>&1 || printf 'bd-metrics-off-alarm: gc mail send failed, notify already sent\n' >&2
fi
