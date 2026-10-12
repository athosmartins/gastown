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
#   mbp-offload.sh counts    só a linha da contagem das últimas 72 h (sem falar com o MBP): "<N> execuções; recusas: <motivo>=<n>"
#                            ou "sem log ainda" ou "ilegível"; linhas do log que não deu para ler vêm avisadas, nunca omitidas
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
# "nenhuma"); lido e sem recusa → "nenhuma". Linha que não dá para ler (não é JSON objeto, ts que não vira data, ou recusa
# sem motivo em texto) NÃO derruba a leitura e NÃO some em silêncio: vira "; N linha(s) ilegível(is) no log (não contadas)".
# Sem isso, uma linha de recusa truncada deixava "recusas: nenhuma" mentir justo na medição de "recusa indevida". Linha
# ilegível não tem ts confiável, então conta mesmo fora da janela de 72 h (melhor avisar a mais do que esconder).
recent_counts() {
  local out
  [ -f "$LOG" ] || { echo "sem log ainda"; return; }
  # jq que não consegue abrir o arquivo ainda imprime a conta de uma entrada vazia ("0 execuções; recusas: nenhuma") ANTES de sair
  # com erro: por isso a saída só vale se o rc for 0 (falhou → só "ilegível", nunca o veredito de uma leitura que não houve)
  out=$(jq -Rrs --argjson since "$(( $(date +%s) - 259200 ))" '
    [split("\n")[] | select(length > 0)
      | (try fromjson catch null)
      | if type == "object" and ((try (.ts | fromdateiso8601) catch null) | type) == "number"
        then {l: ., t: (.ts | fromdateiso8601)} else {bad: 1} end] as $e
    | [$e[] | select(.l and .t >= $since) | .l] as $w
    | ([$e[] | select(.bad)] | length) + ([$w[] | select(.mode == "preflight" and (.reason | type) != "string")] | length) as $bad
    | ([$w[] | select(.mode != "preflight")] | length) as $runs
    | [$w[] | select(.mode == "preflight" and (.reason | type) == "string")] as $ref
    | "\($runs) execuções; recusas: " + (if ($ref | length) == 0 then "nenhuma" else ($ref | group_by(.reason) | map("\(.[0].reason)=\(length)") | join(" ")) end)
      + (if $bad > 0 then "; \($bad) linha(s) ilegível(is) no log (não contadas)" else "" end)
  ' "$LOG" 2>/dev/null) || { echo "ilegível"; return; }
  [ -n "$out" ] || { echo "ilegível"; return; }
  printf '%s\n' "$out"
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
  counts) recent_counts ;;
  -h|--help|help) sed -n '2,/^[^#]/{/^#/p;}' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "uso: $0 on|off|status [--json]|counts" >&2; exit 2 ;;
esac
