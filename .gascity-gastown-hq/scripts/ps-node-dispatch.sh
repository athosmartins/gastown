#!/usr/bin/env bash
# ps-node-dispatch.sh — manda UMA bead do PS (property_scrapers) que roda no nó ao ps-worker-remote, ou a solta depois da entrega (ga-2hd02v.4).
#
# Contents
#   Uso · O que é · O que esta casca garante · Códigos de saída
#
# USO:  ps-node-dispatch.sh check   <bead>                          classifica (nada é escrito)
#       ps-node-dispatch.sh apply   <bead> [--basis label|any] [--dry-run]
#       ps-node-dispatch.sh release <bead>                          depois da entrega: solta o dono e a rota
#       --store DIR  pasta do store da bead (default: o que routes.jsonl diz para o prefixo `ps`)
# O QUE É: o MESMO despachante do WA (scripts/wa-node-dispatch.sh: comparação atômica, slot do nó, três estados, desfazer com releitura), apontado para o rig PS por variável de ambiente. Não há segunda cópia
#   da lógica de escrita: um defeito do despachante se conserta num lugar só. Aqui só mudam QUEM: alias `ps-worker-remote-1`, rota `ps-worker-remote`, classificador scripts/ps-node-classify.py e o log
#   $GC_CITY/.gc/ps-node-route.jsonl (o do WA é wa-node-route.jsonl: as duas medições não se misturam) — e COMO a sessão nasce: sempre no modo pilot (WA_NODE_SPAWN=pilot, ga-2hd02v.3). A bead do PS mora na loja do rig e
#   o pool de um template sem `dir` só lê a cidade: o pool nunca a veria. Então o apply escreve só o dono e a marca pilot.wa_node_alias (SEM gc.routed_to) e o Pilot abre a sessão (_pilot_ps_node_open).
# O QUE ESTA CASCA GARANTE (e o selftest cobra):
#   1. as variáveis de identidade (alias, rota, classificador, log) e o modo de abrir a sessão (pilot) são FIXADOS aqui, sobrescrevendo qualquer WA_NODE_* que já estivesse no ambiente: um ambiente com o alias do WA
#      nunca faz uma bead de PS ser carimbada com a rota do WA, nem o contrário, e um WA_NODE_SPAWN=pool herdado nunca devolve a bead do PS ao pool que não a enxerga. 1 slot (o alias único ps-worker-remote-1): o agente
#      ps-worker-remote tem max 1 sessão; mais slots é mudar o agente e esta casca juntos;
#   2. só bead `ps-*`: id de outro prefixo sai 11 sem rodar nada ("não sei decidir", fica onde está), porque o classificador, o filtro e o alias aqui são do PS;
#   3. não há nada a decidir sozinha: qualquer falha do despachante real chega ao chamador com o código dele (0/10/11/12/13/2, ver wa-node-dispatch.sh); despachante ausente ou não executável = 11.
# SAÍDA: a do wa-node-dispatch.sh. Em dúvida o código é 10-13, nunca 0. O apply no modo pilot também consulta o oráculo de capacidade do nó (hetzner-capacity.py), o mesmo do WA: sem vaga → 12, a bead fica no mini.
# Env (teste): PS_NODE_BD, PS_NODE_GC, PS_NODE_PY, PS_NODE_TIMEOUT, PS_NODE_SESSION_TIMEOUT, PS_NODE_CAPACITY (o oráculo; repassados como WA_NODE_*), PS_NODE_CLASSIFY, PS_NODE_ALIAS, PS_NODE_ROUTE_TEMPLATE, PS_NODE_LOG, PS_NODE_DISPATCH (o despachante real).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CITY="${GC_CITY:-$(cd "$HERE/.." && pwd)}"
REAL="${PS_NODE_DISPATCH:-$HERE/wa-node-dispatch.sh}"

say() { echo "ps-node-dispatch: $*" >&2; }

# a bead é o 2º argumento (check|apply|release <bead>); sem ele o despachante real devolve o uso (2)
if [ $# -ge 2 ]; then
  case "$2" in ps-*) ;; *) say "$2 não é uma bead do PS (prefixo ps-): não decido — fica onde está"; exit 11 ;; esac
fi
[ -x "$REAL" ] || { say "despachante $REAL ausente ou não executável — fica no mini"; exit 11; }

# repasse dos nomes de teste (PS_NODE_X -> WA_NODE_X) só quando definidos; as quatro de identidade abaixo NÃO passam por aqui
[ -z "${PS_NODE_BD:-}" ] || export WA_NODE_BD="$PS_NODE_BD"
[ -z "${PS_NODE_GC:-}" ] || export WA_NODE_GC="$PS_NODE_GC"
[ -z "${PS_NODE_PY:-}" ] || export WA_NODE_PY="$PS_NODE_PY"
[ -z "${PS_NODE_TIMEOUT:-}" ] || export WA_NODE_TIMEOUT="$PS_NODE_TIMEOUT"
[ -z "${PS_NODE_SESSION_TIMEOUT:-}" ] || export WA_NODE_SESSION_TIMEOUT="$PS_NODE_SESSION_TIMEOUT"
[ -z "${PS_NODE_CAPACITY:-}" ] || export WA_NODE_CAPACITY="$PS_NODE_CAPACITY"

export GC_CITY="$CITY"
export WA_NODE_ALIAS="${PS_NODE_ALIAS:-ps-worker-remote-1}"
export WA_NODE_ROUTE_TEMPLATE="${PS_NODE_ROUTE_TEMPLATE:-ps-worker-remote}"
export WA_NODE_CLASSIFY="${PS_NODE_CLASSIFY:-$HERE/ps-node-classify.py}"
export WA_NODE_LOG="${PS_NODE_LOG:-$CITY/.gc/ps-node-route.jsonl}"
# modo pilot (a sessão do alias é aberta pelo Pilot); o alias único acima já faz o nó de PS ter 1 slot, com o prefixo e o N de slots do ambiente fora da conta
export WA_NODE_SPAWN="pilot"
# só o TEXTO das mensagens e dos comentários da bead (o despachante do WA os lê desde o ga-2hd02v.3)
export WA_NODE_SELF="ps-node-dispatch.sh" WA_NODE_STORY="ga-2hd02v.4"
exec "$REAL" "$@"
