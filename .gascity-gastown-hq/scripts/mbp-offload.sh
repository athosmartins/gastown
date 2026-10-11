#!/usr/bin/env bash
# mbp-offload.sh — chave de ligar/desligar o uso do MacBook Pro como nó de capacidade (Athos 11/10).
#
# Contents
#   Uso · O que é a chave · Saída JSON
#
# USO
#   mbp-offload.sh on        liga (cria $CITY/.gc/mbp-offload.on)
#   mbp-offload.sh off       desliga (remove o arquivo; mbp-run.sh passa a sair 99 e todo mundo roda local)
#   mbp-offload.sh status    estado + saúde do MBP (RAM livre, swap, tomada/bateria, load) + últimas 5 execuções
#   mbp-offload.sh status --json   o mesmo em JSON (insumo do botão do painel)
#
# A CHAVE é só o arquivo-bandeira: sem daemon, sem launchd, sem estado escondido. O botão do painel (bead própria,
# mockup antes) apenas chama este script.
set -o pipefail
CITY=${MBP_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}
FLAG="$CITY/.gc/mbp-offload.on"
LOG="$CITY/.gc/logs/mbp-run.jsonl"
RUN="$(cd "$(dirname "$0")" && pwd)/mbp-run.sh"

cmd=${1:-status}
case "$cmd" in
  on)  mkdir -p "$(dirname "$FLAG")" && date -u +%Y-%m-%dT%H:%M:%SZ > "$FLAG" && echo "MBP offload: LIGADO" ;;
  off) rm -f "$FLAG"; echo "MBP offload: DESLIGADO (tudo roda local)" ;;
  status)
    state=off; [ -f "$FLAG" ] && state=on
    health=$(MBP_CITY="$CITY" "$RUN" --check 2>/dev/null); hrc=$?
    recent=$(tail -n 5 "$LOG" 2>/dev/null)
    if [ "${2:-}" = "--json" ]; then
      hj=$(printf '%s\n' "$health" | awk -F= 'NF==2 && $1!="" {printf "%s\"%s\":\"%s\"", (n++?",":""), $1, $2}')
      rj=$(printf '%s\n' "$recent" | awk 'NF {printf "%s%s", (n++?",":""), $0}')
      printf '{"offload":"%s","healthy":%s,"health":{%s},"recent":[%s]}\n' "$state" "$([ $hrc -eq 0 ] && echo true || echo false)" "$hj" "$rj"
    else
      echo "MBP offload: $(echo $state | tr a-z A-Z)  (since: $( [ -f "$FLAG" ] && cat "$FLAG" || echo - ))"
      if [ $hrc -eq 0 ]; then echo "MBP saudável:"; else echo "MBP SEM SAÚDE (rc=$hrc) — execuções caem para local:"; fi
      printf '%s\n' "$health" | sed 's/^/  /'
      echo "últimas execuções ($LOG):"
      if [ -n "$recent" ]; then printf '%s\n' "$recent" | jq -r '"  \(.ts) \(.repo)/\(.mode) slot=\(.slot) rc=\(.rc) \(.secs)s"' 2>/dev/null || printf '%s\n' "$recent"
      else echo "  (nenhuma)"; fi
    fi ;;
  -h|--help|help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "uso: $0 on|off|status [--json]" >&2; exit 2 ;;
esac
