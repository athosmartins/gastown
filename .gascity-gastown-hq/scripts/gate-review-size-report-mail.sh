#!/usr/bin/env bash
# gate-review-size-report-mail.sh — roda o relatório de tamanho x veredito e MANDA pro
# Mayor decidir (ga-ub8yq). Disparado pelo order `gate-review-size-report` (semanal).
#
# POR QUE MAIL E NÃO ALARME: o relatório é INSUMO DE DECISÃO, não detecção de falha. Esta
# cidade já sofre de vigilância que alarma por congestão (ga-ysc82: 7+ escalações falsas em
# 12h). Um alarme a mais competiria com os que importam. Mail entra na fila de trabalho do
# Mayor, que é onde uma decisão deve ser tomada.
#
# POR QUE SEMANAL: a correlação precisa de volume. Com ~700 runs/dia mas só uma fatia
# pareável, uma semana dá massa suficiente pra faixa de 800+ linhas ter n>30. Rodar diário
# produziria conclusão sobre n pequeno — pior que não rodar.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
SCRIPT="$CITY/scripts/gate-review-size-report.py"

if [ ! -x "$SCRIPT" ] && [ ! -f "$SCRIPT" ]; then
  # Falhar em SILÊNCIO aqui reproduziria exatamente a classe de bug que este trabalho
  # todo perseguiu: ausência de relatório lida como "nada a reportar".
  gc mail send mayor \
    -s "gate-review-size-report: script AUSENTE — o relatório semanal NÃO rodou" \
    -m "Esperado em $SCRIPT e não encontrado. Isto não é 'sem achados' — é 'não mediu'. Ver ga-ub8yq." 2>/dev/null || true
  exit 1
fi

OUT=$(timeout 120 python3 "$SCRIPT" 2>&1)
RC=$?

if [ $RC -ne 0 ]; then
  gc mail send mayor \
    -s "gate-review-size-report FALHOU (rc=$RC) — não confunda com 'sem achados'" \
    -m "$(printf 'O relatório semanal de tamanho x veredito falhou.\n\nrc=%s\n\nSaída:\n%s\n\nBead: ga-ub8yq' "$RC" "$OUT")" 2>/dev/null || true
  exit "$RC"
fi

gc mail send mayor \
  -s "Relatório semanal: tamanho do diff x veredito do gate (decidir passo 2 do ga-ub8yq)" \
  -m "$(printf '%s\n\n─────────────────────────────────────────────\nCONTEXTO PRA QUEM LER (ga-ub8yq, P0):\n\nEste relatório existe pra decidir UMA coisa: se o gate deve barrar/fatiar diffs\ngrandes em vez de revisá-los com mais afinco.\n\nA literatura (Cisco/SmartBear, 2.500 revisões) diz que acima de ~400 linhas a\ndetecção de defeitos despenca. Medimos que 33%% das nossas revisões estão acima\ndisso. Mas o dado que DECIDE é a correlação acima — se a taxa de reprovação CAI\nnos diffs grandes, o revisor está degradando e o gate de tamanho se justifica com\nDADO NOSSO, não por analogia.\n\nAÇÃO ESPERADA DO MAYOR:\n 1. registrar a leitura como comentário em ga-ub8yq;\n 2. decidir o passo (2): implementar gate de tamanho, ajustar o limiar, ou\n    DESCARTAR o passo se a correlação não sustentar;\n 3. se ainda faltar volume numa faixa, dizer isso no bead e deixar rodar mais uma\n    semana — NÃO concluir sobre n pequeno.\n\n⚠️ Se a seção de correlação vier vazia, isso significa SEM MEDIÇÃO, não sem\nproblema. Nesse caso o conserto é do script/parser, não do gate.\n' "$OUT")" 2>/dev/null || true
