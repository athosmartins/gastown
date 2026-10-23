#!/usr/bin/env bash
# ps-node-route-report.sh — o que o shadow do PS gravou em ps-node-route.jsonl e quantas linhas NÃO gravou (ga-2hd02v.4.13). SÓ LEITURA.
#
# Contents
#   Para quê · Uso · O que diz · O que não diz · Códigos de saída
#
# PARA QUÊ: o passo 9 do runbook (docs/runbooks/hetzner-ps-node.md) só liga PILOT_PS_NODE_ROUTE=auto com a taxa de acerto "medida no shadow", e o jsonl é a ÚNICA saída do gancho em shadow. Uma linha que o gancho não
#   conseguiu gravar (disco cheio, pasta sem permissão) deixa a amostra subcontada sem que o jsonl mostre: este relatório lê o jsonl E o rastro das perdas, e não deixa a amostra parecer completa quando não é.
# USO:   ps-node-route-report.sh [--city DIR]      DIR = a cidade (padrão GC_CITY, senão a pasta acima de scripts/)
# O QUE DIZ: (1) as linhas gravadas em <cidade>/.gc/ps-node-route.jsonl: por modo, por veredito do classificador (rc 0 = node, 10 = mini, 11 = não sei, outro = erro do despachante), por base do veredito node, beads
#   distintas, primeira e última. Linhas que não leem como JSON (uma gravação cortada) e linhas de outro evento (o despachante também grava aqui) são contadas à parte, nunca somadas às decisões.
#   (2) as linhas NÃO gravadas: o contador <cidade>/.gc/ps-node-route.lost (uma linha por perda) E os avisos "NÃO gravada em ps-node-route.jsonl" do log do Pilot (<cidade>/.gc/logs/pilot-dispatcher.log). Os dois
#   existem porque o contador mora na MESMA pasta que falhou: com o disco cheio só o aviso sobra, e ele também é contado. Vale o MAIOR dos dois números. Um log do Pilot que girou perde os avisos antigos; o contador não.
# O QUE NÃO DIZ: a taxa de acerto. Acerto é "a bead que o shadow mandaria ao nó voltou sem athos.node_recusa", e isso só existe depois da entrega. Aqui se vê o que o shadow gravou e quanto NÃO gravou.
# CÓDIGOS: 0 há decisões gravadas e NENHUMA perda registrada nem linha ilegível (só vê o que deixou rastro: perda que não deixou nem o contador nem o aviso, de um disco cheio, não aparece aqui) · 2 uso · 3 nada a medir
#   (nenhuma decisão gravada e nenhuma perda registrada: o shadow não rodou ainda) · 4 amostra SUBCONTADA ou duvidosa (perdas > 0, linha ilegível, ou um arquivo que existe e não leu): a contagem acima é um PISO, não a
#   medida — não ligue o auto com ela.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CITY="${GC_CITY:-$(cd "$HERE/.." && pwd)}"
say() { echo "ps-node-route-report: $*" >&2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --city) [ $# -ge 2 ] || { say "--city pede uma pasta"; exit 2; }; CITY="$2"; shift 2 ;;
    -h|--help) echo "uso: ps-node-route-report.sh [--city DIR]   (0 completa · 3 nada a medir · 4 subcontada ou duvidosa)"; exit 0 ;;
    *) say "argumento desconhecido: $1 (uso: ps-node-route-report.sh [--city DIR])"; exit 2 ;;
  esac
done
LOG="$CITY/.gc/ps-node-route.jsonl"; LOST="$CITY/.gc/ps-node-route.lost"; PLOG="$CITY/.gc/logs/pilot-dispatcher.log"
WARN_TXT='NÃO gravada em ps-node-route.jsonl'

doubt=""   # um motivo de dúvida por linha; qualquer um → 4
add_doubt() { doubt="${doubt}${doubt:+
}$1"; }
isnum() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# 1) o jsonl. vazio (arquivo ausente) → 0 linhas; falhou/ilegível (existe e o jq não leu: pasta, sem permissão) → dúvida, nunca "0 linhas"
SUM=""; rec_state=ausente
if [ -e "$LOG" ]; then
  if [ -f "$LOG" ] && [ -r "$LOG" ] && SUM=$(jq -R -s -c '
      split("\n") | map(select(length > 0)) | map(try fromjson catch null) as $o
      | ($o | map(select(type == "object" and .event == "pilot-node-route"))) as $g
      | def contagem(f): map(f) | group_by(.) | map({key: .[0], value: length}) | from_entries;
      { gravadas: ($g | length),
        ilegiveis: ($o | map(select(type != "object")) | length),
        outros: ($o | map(select(type == "object" and .event != "pilot-node-route")) | length),
        modos: ($g | contagem(.mode // "?")),
        rcs: ($g | contagem(.rc | tostring)),
        bases: ($g | map(select(.rc == 0)) | contagem((try (.out | fromjson | .basis) catch null) // "?")),
        beads: ($g | map(.bead) | unique | length),
        primeira: ($g | map(.ts // empty) | min),
        ultima: ($g | map(.ts // empty) | max) }' "$LOG" 2>/dev/null) && [ -n "$SUM" ]; then
    rec_state=lido
  else
    SUM=""; rec_state=ilegivel
    add_doubt "$LOG existe e não foi possível lê-lo: a contagem de linhas gravadas é desconhecida"
  fi
fi
g=0; ileg=0
if [ "$rec_state" = lido ]; then
  g=$(printf '%s' "$SUM" | jq -r '.gravadas'); ileg=$(printf '%s' "$SUM" | jq -r '.ilegiveis')
  if [ "$ileg" -gt 0 ]; then add_doubt "$ileg linha(s) do jsonl não leem como JSON (gravação cortada?): a decisão dessas linhas é desconhecida"; fi
fi

# 2a) o contador. vazio (ausente) → 0 perdas CONTADAS (e o contador ausente não prova que nada se perdeu, ver 2b); falhou/ilegível (existe e não leu) → dúvida
lost_n=0; lost_state=ausente
if [ -e "$LOST" ]; then
  if [ -f "$LOST" ] && [ -r "$LOST" ]; then
    lost_n=$(grep -c '[^[:space:]]' "$LOST" 2>/dev/null || true)
    if isnum "$lost_n"; then lost_state=lido; else lost_n=0; lost_state=ilegivel; fi
  else
    lost_state=ilegivel
  fi
  if [ "$lost_state" = ilegivel ]; then add_doubt "$LOST existe e não foi possível lê-lo: o número de linhas perdidas é desconhecido"; fi
fi
# 2b) os avisos no log do Pilot. vazio (log ausente) → não li (dúvida nenhuma por si: o log gira); falhou/ilegível (existe e não leu) → dúvida
warn_n=0; plog_state=ausente
if [ -e "$PLOG" ]; then
  if [ -f "$PLOG" ] && [ -r "$PLOG" ]; then
    warn_n=$(grep -cF -- "$WARN_TXT" "$PLOG" 2>/dev/null || true)
    if isnum "$warn_n"; then plog_state=lido; else warn_n=0; plog_state=ilegivel; fi
  else
    plog_state=ilegivel
  fi
  if [ "$plog_state" = ilegivel ]; then add_doubt "$PLOG existe e não foi possível lê-lo: os avisos de linha perdida não foram contados"; fi
fi
lost_max=$lost_n; [ "$warn_n" -le "$lost_max" ] || lost_max=$warn_n
if [ "$lost_max" -gt 0 ]; then add_doubt "$lost_max linha(s) NÃO gravada(s) pelo gancho: a amostra do shadow está subcontada"; fi

# saída
echo "ps-node-route — shadow do PS ($CITY)"
if [ "$rec_state" = lido ]; then
  printf '%s' "$SUM" | jq -r '
    "linhas gravadas (decisões): \(.gravadas)   beads distintas: \(.beads)   de \(.primeira // "—") a \(.ultima // "—")",
    "  por modo: " + (if (.modos | length) == 0 then "—" else (.modos | to_entries | map("\(.key)=\(.value)") | join(" ")) end),
    "  por veredito: node (rc 0)=\(.rcs["0"] // 0) · mini (rc 10)=\(.rcs["10"] // 0) · não sei (rc 11)=\(.rcs["11"] // 0) · outro rc=\([.rcs | to_entries[] | select(.key | IN("0", "10", "11") | not) | .value] | add // 0)",
    "  node por base: " + (if (.bases | length) == 0 then "—" else (.bases | to_entries | map("\(.key)=\(.value)") | join(" ")) end),
    "  linhas ilegíveis: \(.ilegiveis)   linhas de outro evento (não são decisões): \(.outros)"'
elif [ "$rec_state" = ausente ]; then
  echo "linhas gravadas (decisões): 0 — $LOG não existe"
else
  echo "linhas gravadas (decisões): DESCONHECIDO — $LOG existe e não leu"
fi
case "$lost_state" in
  lido) echo "linhas NÃO gravadas, contador (ps-node-route.lost): $lost_n" ;;
  ausente) echo "linhas NÃO gravadas, contador (ps-node-route.lost): 0 — arquivo ausente (não prova que nada se perdeu: com o disco cheio nem o contador grava)" ;;
  *) echo "linhas NÃO gravadas, contador (ps-node-route.lost): DESCONHECIDO — o arquivo existe e não leu" ;;
esac
case "$plog_state" in
  lido) echo "linhas NÃO gravadas, avisos no log do Pilot: $warn_n" ;;
  ausente) echo "linhas NÃO gravadas, avisos no log do Pilot: não li — $PLOG não existe" ;;
  *) echo "linhas NÃO gravadas, avisos no log do Pilot: DESCONHECIDO — o log existe e não leu" ;;
esac

if [ -n "$doubt" ]; then
  echo "AMOSTRA SUBCONTADA OU DUVIDOSA — a contagem acima é um PISO, não a medida; não ligue o auto com ela:"
  printf '%s\n' "$doubt" | sed 's/^/  - /'
  exit 4
fi
if [ "$g" -eq 0 ]; then
  echo "nada a medir: nenhuma decisão gravada e nenhuma perda registrada (o shadow não rodou ainda, ou não deixou rastro)"
  exit 3
fi
echo "nenhuma perda registrada (contador e avisos) e nenhuma linha ilegível — o relatório só vê o que deixou rastro"
exit 0
