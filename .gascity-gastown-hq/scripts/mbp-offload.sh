#!/usr/bin/env bash
# mbp-offload.sh — chave de ligar/desligar o uso do MacBook Pro como nó de capacidade (Athos 11/10).
#
# Contents
#   Uso · O que é a chave · Saída JSON
#
# USO
#   mbp-offload.sh on        liga (cria $CITY/.gc/mbp-offload.on)
#   mbp-offload.sh off       desliga (remove o arquivo; mbp-run.sh passa a sair 99 e todo mundo roda local)
#   mbp-offload.sh status    estado + saúde do MBP (RAM livre, pressão de memória, swap e seu crescimento, tomada/bateria,
#                            load) + últimas 5 linhas do log (execuções e recusas do preflight, com o motivo) + a contagem
#                            de recusas por motivo nas últimas 72 h (é por ela que se mede "recusa indevida", ga-9e2rjh)
#   mbp-offload.sh status --json   o mesmo em JSON (insumo do botão do painel)
#
# A CHAVE é só o arquivo-bandeira: sem daemon, sem launchd, sem estado escondido. O botão do painel (bead própria,
# mockup antes) apenas chama este script.
set -o pipefail
CITY=${MBP_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}
FLAG="$CITY/.gc/mbp-offload.on"
LOG="$CITY/.gc/logs/mbp-run.jsonl"
RUN="$(cd "$(dirname "$0")" && pwd)/mbp-run.sh"

# Contagem das últimas 72 h: "<N> execuções; recusas: <motivo>=<n> ..." ou "...; recusas: nenhuma".
# Três estados que NUNCA se confundem: log ausente → "sem log ainda"; jq falhou/não existe/log ilegível → "ilegível" (nunca
# "nenhuma"); lido e sem recusa → "nenhuma". Linha do log que não é JSON é ignorada (fromjson?), não derruba a leitura.
recent_counts() {
  [ -f "$LOG" ] || { echo "sem log ainda"; return; }
  jq -Rrs --argjson since "$(( $(date +%s) - 259200 ))" '
    [split("\n")[] | fromjson? | select(type == "object") | select((try (.ts | fromdateiso8601) catch 0) >= $since)] as $l
    | ([$l[] | select(.mode != "preflight")] | length) as $runs
    | [$l[] | select(.mode == "preflight" and (.reason | type) == "string")] as $ref
    | "\($runs) execuções; recusas: " + (if ($ref | length) == 0 then "nenhuma" else ($ref | group_by(.reason) | map("\(.[0].reason)=\(length)") | join(" ")) end)
  ' "$LOG" 2>/dev/null || echo "ilegível"
}

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
      if [ -n "$recent" ]; then printf '%s\n' "$recent" | jq -r '"  \(.ts) \(.repo)/\(.mode) slot=\(.slot) rc=\(.rc) \(.secs)s" + (if .reason then " motivo=\(.reason)" else "" end)' 2>/dev/null || printf '%s\n' "$recent"
      else echo "  (nenhuma)"; fi
      echo "últimas 72 h: $(recent_counts)"
    fi ;;
  -h|--help|help) sed -n '2,/^[^#]/{/^#/p;}' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "uso: $0 on|off|status [--json]" >&2; exit 2 ;;
esac
