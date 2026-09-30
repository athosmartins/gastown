#!/usr/bin/env bash
# gate-e5-switch.sh — a chave do E5 (ga-syxaki): 2º revisor independente no gate.
#
#   gate-e5-switch.sh status
#   gate-e5-switch.sh on "<quem autorizou, CITÁVEL: bead+comentário ou mensagem, com carimbo de tempo>"
#   gate-e5-switch.sh off
#
# A chave é um ARQUIVO ($GC_CITY/.gc/gate-e5-second-reviewer.on): o dispatcher o lê a cada varredura
# (~1 min), sem reinício e sem mexer em plist. Desligada (arquivo ausente) = o gate roda byte a byte
# como antes — nenhum revisor extra, nenhum texto novo no prompt.
#
#   on   — liga. Exige a autorização citável (Regra Nº 4: gasta dinheiro; "o Athos autorizou" sem
#          citação não vale) e grava-a dentro do arquivo. Recusa ligar antes de 01/10/2026 21:00 -03
#          (o E2 — crews em effort high — termina ali; ligar antes confunde os dois efeitos),
#          a menos que GATE_E5_FORCE_EARLY=1 (e a autorização diga por quê).
#   off  — desliga. Revisores extras já em voo terminam normalmente; nada novo nasce.
#   status — estado da chave, do teto de gasto do dia e de quantos extras já foram pagos hoje.
set -euo pipefail

CITY="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
FLAG="${GATE_E5_FLAG_FILE:-$CITY/.gc/gate-e5-second-reviewer.on}"
# 2026-10-02T00:00:00Z == 01/10/2026 21:00 -03 (fim do E2). Sobrescrevível só para teste.
NOT_BEFORE="${GATE_E5_NOT_BEFORE_EPOCH:-1790899200}"
CAP_USD="${GATE_E5_DAILY_CAP_USD:-30}"
EST_USD="${GATE_E5_EST_COST_USD:-0.60}"

status() {
  if [ -r "$FLAG" ]; then
    echo "E5 (2º revisor): LIGADO — $(head -n1 "$FLAG" 2>/dev/null || echo '?')"
  else
    echo "E5 (2º revisor): DESLIGADO (arquivo $FLAG ausente) — o gate roda como antes."
  fi
  if [ -n "${GATE_E5_ENABLED:-}" ]; then
    echo "  ⚠ GATE_E5_ENABLED=${GATE_E5_ENABLED} neste ambiente SOBREPÕE o arquivo (o dispatcher do launchd não o tem)."
  fi
  local counter="$CITY/.gc/gate-e5-spend-$(date +%Y-%m-%d).count" n=0
  [ -r "$counter" ] && n="$(cat "$counter" 2>/dev/null || echo 0)"
  # an unreadable counter is UNKNOWN spend, not "US$ 0.00 of the cap": say so instead of multiplying garbage by the unit cost
  local est
  case "$n" in
    ''|*[!0-9]*) n="ilegível"; est="desconhecida (contador ilegível)" ;;
    *) est="US\$ $(awk -v n="$n" -v u="$EST_USD" 'BEGIN{printf "%.2f", n*u}')" ;;
  esac
  echo "  extras pagos hoje: $n · estimativa $est de US\$ $CAP_USD (teto; estimativa = contagem × US\$ $EST_USD)"
  [ -e "$counter.alerted" ] && echo "  ⚠ o teto do dia JÁ foi atingido — nenhum extra novo até amanhã."
  return 0
}

case "${1:-status}" in
  status) status ;;
  on)
    auth="${2:-}"
    if [ -z "$auth" ]; then
      echo "RECUSADO: 'on' exige a autorização CITÁVEL como 2º argumento (ex.: \"Mayor, bead ga-syxaki #<comentário>, 2026-10-01T21:05-03\")." >&2
      exit 2
    fi
    now="$(date -u +%s)"
    if [ "$now" -lt "$NOT_BEFORE" ] && [ "${GATE_E5_FORCE_EARLY:-0}" != "1" ]; then
      echo "RECUSADO: só a partir de 01/10/2026 21:00 -03 (fim do E2; ligar antes confunde os efeitos). Para antecipar: GATE_E5_FORCE_EARLY=1 e diga o porquê na autorização." >&2
      exit 3
    fi
    mkdir -p "$(dirname "$FLAG")"
    printf 'ligado em %s — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$auth" > "$FLAG"
    status
    echo "  (vale a partir da próxima varredura do dispatcher, ~1 min. Apuração: scripts/gate-e5-apuracao.py)"
    ;;
  off)
    rm -f "$FLAG"
    status
    echo "  (revisores extras já em voo terminam; nada novo nasce a partir da próxima varredura.)"
    ;;
  *)
    echo "uso: $0 status | on \"<autorização citável>\" | off" >&2
    exit 2
    ;;
esac
