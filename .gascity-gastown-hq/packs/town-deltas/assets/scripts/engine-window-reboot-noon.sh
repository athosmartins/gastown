#!/bin/bash
# ga-3azujf: lembrete ONE-SHOT de meio-dia para o reboot que dispara a janela
# do engine (armada em 26/08 17:35; so roda num boot).
#
# Athos decidiu 27/08 08:4x: "Vamos agendar pra meio dia mas me confirma antes
# de fazer". Portanto este script NUNCA reinicia nada — ele so AVISA. O reboot
# e um ato humano, depois da confirmacao dele. Nao adicione 'reboot' aqui.
set -uo pipefail

MARKER="$HOME/.gastown/run/engine-window-reboot-noon.fired"
PLIST="$HOME/Library/LaunchAgents/com.gascity.engine-window-postboot.plist"
mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true

# One-shot: o trigger e cron diario, mas este lembrete e de UMA data so.
[ -f "$MARKER" ] && { echo "[reboot-noon] ja disparou em $(cat "$MARKER" 2>/dev/null) — nada a fazer."; exit 0; }

# Se a janela foi desarmada nesse meio tempo, o lembrete perdeu o sentido.
# (plist PRESENTE = armado; phase_arm nao faz bootstrap de proposito, entao
# 'launchctl list' NAO e o discriminador — ver ga-3azujf.)
if [ ! -f "$PLIST" ]; then
  echo "[reboot-noon] janela DESARMADA (plist ausente) — lembrete cancelado, nada enviado."
  date -u +%Y-%m-%dT%H:%M:%SZ > "$MARKER"
  exit 0
fi

PEND=$(ls -1 "$HOME/gt/docs/pending-engine-window/" 2>/dev/null | grep -c '\.patch$' || echo 0)
SESS=$(timeout 60 gc session list 2>/dev/null | awk 'NR>1 && $3=="active"' | wc -l | tr -d ' ')
MSG="Meio-dia: confirma o reboot? A janela do engine esta ARMADA e roda sozinha no boot (${PEND} patch pendente). Agora ha ${SESS} sessoes ativas que serao interrompidas (recuperavel: reclaim-guard preserva e o Pilot redespacha). Responda na sessao do Mayor — nada reinicia sem a sua confirmacao."

notify -t "Reboot do meio-dia (janela do engine)" -p 4 "$MSG" 2>/dev/null \
  || echo "[reboot-noon] AVISO: notify falhou"
timeout 60 gc mail send mayor -s "Reboot do meio-dia: aguardando confirmacao do Athos (ga-3azujf)" -m "$MSG" 2>/dev/null \
  || echo "[reboot-noon] AVISO: gc mail falhou"

date -u +%Y-%m-%dT%H:%M:%SZ > "$MARKER"
echo "[reboot-noon] lembrete enviado; marker gravado. NENHUM reboot foi executado (por desenho)."
