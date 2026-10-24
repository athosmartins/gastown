#!/usr/bin/env bash
# mbp-node-dispatch.sh — manda UMA bead WA que roda no MBP ao wa-worker-remote-mbp, ou a solta depois da entrega (ga-w7qwl1.2.1).
#
# Contents
#   Uso · O que é · O que esta casca garante · Saída
#
# USO:  mbp-node-dispatch.sh check   <bead>                          classifica (nada é escrito)
#       mbp-node-dispatch.sh apply   <bead> [--basis label|any] [--dry-run]
#       mbp-node-dispatch.sh release <bead>                          depois da entrega: solta o dono e a marca
#       --store DIR  pasta do store da bead (default: o que routes.jsonl diz para o prefixo `wa`)
# O QUE É: o MESMO despachante do WA (scripts/wa-node-dispatch.sh: comparação atômica, slots, três estados, desfazer com releitura) apontado para o MBP por variável de ambiente, como o ps-node-dispatch.sh o aponta para o PS: não há
#   segunda cópia da lógica de escrita. Sempre no modo pilot (dono + marca pilot.wa_node_alias, SEM gc.routed_to): nenhuma bead é roteada ao pool do MBP, que pede ZERO sessões por construção. Nada o chama ainda (gancho do Pilot = corte 2) e,
#   sem o host `mbp` na config, o oráculo devolve `unknown` e esta casca sai 11 sem escrever. Cadeia e decisões: docs/runbooks/mbp-wa-node.md.
# O QUE ESTA CASCA GARANTE (e o selftest cobra):
#   1. alias `wa-worker-remote-mbp-1..2`, template, classificador, log (.gc/mbp-node-route.jsonl), modo pilot, slots e, acima de tudo, O ORÁCULO (mbp-node-capacity.py: Athos fora e MBP saudável) são FIXADOS aqui e vencem qualquer
#      WA_NODE_* do ambiente: um WA_NODE_CAPACITY herdado do Hetzner deixaria um "node" dele autorizar sessão no MBP, e um WA_NODE_ALIAS herdado mandaria a bead ao nó errado;
#   2. só bead `wa-*`: id de outro prefixo sai 11 sem rodar nada;
#   3. nada a decidir sozinha: o código do despachante real chega ao chamador; ausente ou não executável = 11. Em dúvida o código é 10-13, nunca 0;
#   4. slots: 2 (o teto do agente); MBP_NODE_SLOTS=1 baixa para 1 (canário); qualquer outro valor definido (vazio, 0, 3, texto) vale 1: erro de digitação nunca vira mais sessões.
# SAÍDA: a do wa-node-dispatch.sh (0 feito · 10 fica no mini · 11 não consegui decidir · 12 não elegível/sem vaga · 13 escrita não confirmada · 2 uso). Env de teste: MBP_NODE_{BD,GC,PY,TIMEOUT,SESSION_TIMEOUT} (repassados como WA_NODE_*),
#   MBP_NODE_{CAPACITY,CLASSIFY,LOG,DISPATCH,SLOTS}.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CITY="${GC_CITY:-$(cd "$HERE/.." && pwd)}"
REAL="${MBP_NODE_DISPATCH:-$HERE/wa-node-dispatch.sh}"

say() { echo "mbp-node-dispatch: $*" >&2; }

# a bead é o 2º argumento (check|apply|release <bead>); sem ele o despachante real devolve o uso (2)
if [ $# -ge 2 ]; then
  case "$2" in wa-*) ;; *) say "$2 não é uma bead do WA (prefixo wa-): não decido — fica onde está"; exit 11 ;; esac
fi
[ -x "$REAL" ] || { say "despachante $REAL ausente ou não executável — fica no mini"; exit 11; }

# repasse dos nomes de teste (MBP_NODE_X -> WA_NODE_X) só quando definidos; os de identidade abaixo NÃO passam por aqui
[ -z "${MBP_NODE_BD:-}" ] || export WA_NODE_BD="$MBP_NODE_BD"
[ -z "${MBP_NODE_GC:-}" ] || export WA_NODE_GC="$MBP_NODE_GC"
[ -z "${MBP_NODE_PY:-}" ] || export WA_NODE_PY="$MBP_NODE_PY"
[ -z "${MBP_NODE_TIMEOUT:-}" ] || export WA_NODE_TIMEOUT="$MBP_NODE_TIMEOUT"
[ -z "${MBP_NODE_SESSION_TIMEOUT:-}" ] || export WA_NODE_SESSION_TIMEOUT="$MBP_NODE_SESSION_TIMEOUT"

# slots: nada definido -> 2 (o teto do agente); definido -> só "1" ou "2" valem; o resto é 1 (vazio, 0, 3+, texto: o inerte)
SLOTS=2
if [ "${MBP_NODE_SLOTS+set}" = set ]; then
  case "$MBP_NODE_SLOTS" in 1|2) SLOTS="$MBP_NODE_SLOTS" ;; *) SLOTS=1; say "MBP_NODE_SLOTS='$MBP_NODE_SLOTS' não é 1 nem 2 — uso 1 slot" ;; esac
fi

export GC_CITY="$CITY"
unset WA_NODE_ALIAS   # alias único herdado ganharia de SLOTS e do prefixo: um alias do Hetzner mandaria a bead para o nó errado
export WA_NODE_ALIAS_PREFIX="wa-worker-remote-mbp-"
export WA_NODE_ROUTE_TEMPLATE="wa-worker-remote-mbp"
export WA_NODE_CLASSIFY="${MBP_NODE_CLASSIFY:-$HERE/wa-node-classify.py}"
export WA_NODE_LOG="${MBP_NODE_LOG:-$CITY/.gc/mbp-node-route.jsonl}"
export WA_NODE_CAPACITY="${MBP_NODE_CAPACITY:-$HERE/mbp-node-capacity.py}"
# modo pilot (a sessão do alias é aberta pelo Pilot, só com o veredito do oráculo) e 1..2 slots
export WA_NODE_SPAWN="pilot"
export WA_NODE_SLOTS="$SLOTS"
# só o TEXTO das mensagens e dos comentários da bead (o despachante do WA os lê desde o ga-2hd02v.3)
export WA_NODE_SELF="mbp-node-dispatch.sh" WA_NODE_STORY="ga-w7qwl1.2.1"
exec "$REAL" "$@"
