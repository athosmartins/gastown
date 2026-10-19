#!/usr/bin/env bash
# wa-node-dispatch.sh — manda UMA bead WA que roda no nó ao wa-worker-remote, ou a solta depois da entrega (ga-2hd02v.1.10).
#
# Contents
#   Uso · Códigos de saída · O que faz · O que NÃO faz
#
# USO:  wa-node-dispatch.sh check   <bead>                          classifica (nada é escrito)
#       wa-node-dispatch.sh apply   <bead> [--basis label|any] [--dry-run]
#       wa-node-dispatch.sh release <bead>                          depois da entrega: solta o dono e a rota
#       --store DIR  pasta do store da bead (default: o que routes.jsonl diz para o prefixo do id)
# SAÍDA: 0 feito (check: "roda no nó") · 10 fica no mini · 11 não consegui ler/decidir · 12 não elegível agora (bead já tem dono/rota, slot do nó ocupado) · 13 escrita não confirmada
#   (desfeita) · 2 uso. Em dúvida o código é 10-13, nunca 0: o chamador que não entende um código trata como "fica no mini".
# O QUE FAZ (apply): relê a bead → exige aberta, sem dono e sem rota → classifica (scripts/wa-node-classify.py, na MESMA leitura) → exige o slot do nó livre (nenhuma bead em andamento do alias
#   e nenhuma sessão do template) → UMA escrita com comparação atômica (bd update --if-assignee '' --if-status open: quem chegou antes vence, rc 13 do bd) que atribui ao alias, põe
#   em andamento e carimba gc.routed_to → relê e confere → comenta. Falha na conferência desfaz. `release` só mexe em bead que é do alias E da rota.
# O QUE NÃO FAZ: não cria sessão. A receita provada na ga-2hd02v.1.6 (dog-remote) é "atribuir e deixar o pool criar"; `gc session new` à mão em template remoto roteado gera duas sessões e o
#   crew-session-dedup derruba uma. Não mexe no city.toml, no config do host nem no Pilot. Não escreve dado da bead em lugar nenhum além do comentário curto (id, veredito, motivos).
# Env (teste): GC_CITY, WA_NODE_BD (bd), WA_NODE_GC (gc), WA_NODE_CLASSIFY, WA_NODE_PY, WA_NODE_ALIAS (wa-worker-remote-1), WA_NODE_ROUTE_TEMPLATE (wa-worker-remote), WA_NODE_LOG, WA_NODE_TIMEOUT (20 s), WA_NODE_SESSION_TIMEOUT (60 s, só para `gc session list`).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CITY="${GC_CITY:-$(cd "$HERE/.." && pwd)}"
BD="${WA_NODE_BD:-bd}"; GC="${WA_NODE_GC:-gc}"; PY="${WA_NODE_PY:-python3}"
CLS="${WA_NODE_CLASSIFY:-$HERE/wa-node-classify.py}"
ALIAS="${WA_NODE_ALIAS:-wa-worker-remote-1}"; ROUTE="${WA_NODE_ROUTE_TEMPLATE:-wa-worker-remote}"
LOG="${WA_NODE_LOG:-$CITY/.gc/wa-node-route.jsonl}"
TMO="${WA_NODE_TIMEOUT:-20}"
case "$TMO" in ''|*[!0-9]*) TMO=20 ;; esac     # prazo ilegível volta ao padrão
# `gc session list --json` levou 14–22 s na mini carregada (medido 19/10) — com o prazo de 20 s a leitura estourava e o despacho nunca passava; esta leitura tem prazo próprio
STMO="${WA_NODE_SESSION_TIMEOUT:-60}"
case "$STMO" in ''|*[!0-9]*) STMO=60 ;; esac

say() { echo "wa-node-dispatch: $*" >&2; }
die() { local rc="$1"; shift; say "$*"; exit "$rc"; }
T() { if command -v timeout >/dev/null 2>&1; then timeout "$TMO" "$@"; else "$@"; fi; }
TS() { if command -v timeout >/dev/null 2>&1; then timeout "$STMO" "$@"; else "$@"; fi; }
jlog() { # jlog <evento> <bead> <rc> <detalhe> — uma linha por decisão; falha ao gravar o log nunca muda o resultado
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || return 0
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ev "$1" --arg b "$2" --argjson rc "$3" --arg d "$4" '{ts:$ts,event:$ev,bead:$b,rc:$rc,detail:$d}' >> "$LOG" 2>/dev/null || true
}
# store do id: vazio → não sei onde a bead mora (11); routes.jsonl ilegível → o mesmo
store_of() {
  local id="$1" pfx rel dir
  pfx="${id%%-*}"; [ -n "$id" ] && [ "$pfx" != "$id" ] || return 1
  rel=$(jq -rn --arg p "$pfx" 'first(inputs | select(.prefix == $p) | .path) // empty' "$CITY/.beads/routes.jsonl" 2>/dev/null) || return 1
  [ -n "$rel" ] || return 1
  case "$rel" in /*) dir="$rel" ;; *) dir="$CITY/$rel" ;; esac
  [ -d "$dir" ] || return 1
  (cd -P "$dir" 2>/dev/null && pwd -P)
}
# bead_json <store> <id> — o objeto da bead; vazio/ilegível/sem o id pedido → falha (nunca "bead vazia")
bead_json() {
  local out
  out=$(T "$BD" -C "$1" show "$2" --json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -ce --arg id "$2" 'if type=="array" then .[0] else . end | select(type=="object" and .id == $id)' 2>/dev/null
}

cmd="${1:-}"; id="${2:-}"; [ $# -ge 2 ] || die 2 "uso: wa-node-dispatch.sh check|apply|release <bead> [--store DIR] [--basis label|any] [--dry-run]"
shift 2
store=""; basis="any"; dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --store) [ $# -ge 2 ] || die 2 "--store pede uma pasta"; store="$2"; shift 2 ;;
    --basis) [ $# -ge 2 ] && { [ "$2" = label ] || [ "$2" = any ]; } || die 2 "--basis é label ou any"; basis="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) die 2 "argumento desconhecido: $1" ;;
  esac
done
case "$id" in *[!A-Za-z0-9._-]*|'') die 2 "id de bead fora do formato" ;; esac
[ -n "$store" ] || store=$(store_of "$id") || die 11 "não sei em que store $id mora (routes.jsonl sem o prefixo, ilegível ou pasta ausente) — fica no mini"
[ -d "$store" ] || die 11 "store $store não existe"

B=$(bead_json "$store" "$id") || { jlog read "$id" 11 "bead-ilegivel"; die 11 "não consegui ler $id em $store — fica no mini"; }
classify() { printf '%s' "$B" | "$PY" -I "$CLS"; }
# classify_checked — deixa em $out e $rc um par COERENTE (terceiro estado, ga-9636op): 0 só com um JSON cujo veredito é node, 10 só com mini, 11 só com unknown. Classificador que caiu, foi morto, não
# imprimiu, imprimiu o que não se lê, saiu com código fora de 0/10/11 ou cujo exit code e veredito discordam vira 11 ("não consegui decidir"), NUNCA 0. O código cru também não vaza: o chamador lê 2 como
# "uso", 12 como "não elegível" e 13/124/137 como "a escrita pode ter acontecido", e aqui nada foi escrito ainda.
classify_checked() {
  local v
  out=$(classify); rc=$?
  v=$(printf '%s' "$out" | jq -r '.verdict // ""' 2>/dev/null) || v=""
  case "$rc:$v" in 0:node|10:mini|11:unknown) return 0 ;; esac
  jlog classify "$id" 11 "classificador-incoerente rc=$rc verdict=${v:-?}"
  out='{"verdict":"unknown","basis":"","reasons":["classificador-incoerente"],"paths":[],"tests":[],"info":[]}'; rc=11
}

case "$cmd" in
check)
  classify_checked
  printf '%s\n' "$out"; exit "$rc" ;;

apply)
  st=$(printf '%s' "$B" | jq -r '.status // ""'); as=$(printf '%s' "$B" | jq -r '.assignee // ""'); rt=$(printf '%s' "$B" | jq -r '.metadata["gc.routed_to"] // ""')
  [ "$st" = open ] && [ -z "$as" ] && [ -z "$rt" ] || { jlog apply "$id" 12 "nao-elegivel status=$st assignee=$as rota=$rt"; die 12 "$id não está livre (status=$st assignee=${as:-—} rota=${rt:-—}) — não mexo"; }
  classify_checked
  if [ "$rc" != 0 ]; then jlog apply "$id" "$rc" "classificador:$(printf '%s' "$out" | jq -r '(.verdict // "?") + " " + ((.reasons // []) | join(","))' 2>/dev/null)"; say "veredito não é 'roda no nó' (rc=$rc): $out"; exit "$rc"; fi
  b=$(printf '%s' "$out" | jq -r '.basis // ""')
  if [ "$basis" = label ] && [ "$b" != label ]; then jlog apply "$id" 10 "base=$b, modo exige etiqueta"; die 10 "veredito node por '$b', e este modo só aceita a etiqueta node:ok — fica no mini"; fi
  # slot do nó (1 sessão): vazio → livre; falhou/ilegível → não sei, então ocupado (nunca livre por engano)
  mine=$(T "$BD" -C "$store" list --status in_progress --assignee "$ALIAS" --json --limit 5 2>/dev/null) || { jlog apply "$id" 11 "slot-ilegivel"; die 11 "não consegui ler o slot do nó (bd list) — fica no mini"; }
  n=$(printf '%s' "$mine" | jq -r 'if type=="array" then length else "x" end' 2>/dev/null)
  case "$n" in 0) ;; ''|x|*[!0-9]*) jlog apply "$id" 11 "slot-ilegivel"; die 11 "leitura do slot do nó não é uma lista — fica no mini" ;; *) jlog apply "$id" 12 "slot-ocupado bead(s)=$n"; die 12 "slot do nó ocupado ($n bead(s) em andamento de $ALIAS)" ;; esac
  # gc session list --json devolve {"sessions":[…]} (medido 19/10), nunca o array solto: vazio → 0; falhou/ilegível/outro formato → "x" (11, fica no mini); sessão com closed=true ou estado final não conta
  sess=$(TS "$GC" session list --json 2>/dev/null) || { jlog apply "$id" 11 "sessoes-ilegiveis"; die 11 "não consegui listar as sessões — fica no mini"; }
  live=$(printf '%s' "$sess" | jq -r --arg t "$ROUTE" --arg a "$ALIAS" 'if type=="object" and (.sessions|type)=="array" then [.sessions[] | select(((.template // .Template // "") == $t) or ((.alias // .Alias // "") == $a)) | select(.closed != true) | select((.state // .State // "") | test("closed|stopped|archived|drained") | not)] | length else "x" end' 2>/dev/null)
  case "$live" in 0) ;; ''|x|*[!0-9]*) jlog apply "$id" 11 "sessoes-ilegiveis"; die 11 "lista de sessões ilegível — fica no mini" ;; *) jlog apply "$id" 12 "sessao-viva n=$live"; die 12 "já há $live sessão(ões) de $ROUTE/$ALIAS — slot do nó ocupado" ;; esac
  if [ "$dry" = 1 ]; then jlog apply "$id" 0 "dry-run: iria para $ALIAS ($b)"; say "dry-run: $id iria para $ALIAS (base=$b); nada foi escrito"; printf '%s\n' "$out"; exit 0; fi
  T "$BD" -C "$store" update "$id" --if-assignee "" --if-status open --assignee "$ALIAS" --status in_progress --set-metadata "gc.routed_to=$ROUTE" -q >/dev/null 2>&1; w=$?
  if [ "$w" = 13 ]; then jlog apply "$id" 12 "perdeu-a-corrida"; die 12 "$id mudou entre a leitura e a escrita (bd rc 13) — não mexo"; fi
  [ "$w" = 0 ] || { jlog apply "$id" 13 "escrita-falhou rc=$w"; die 13 "bd update falhou (rc=$w) — nada garantido; confira $id"; }
  A=$(bead_json "$store" "$id") || A=""
  if [ "$(printf '%s' "$A" | jq -r '.assignee // ""' 2>/dev/null)" != "$ALIAS" ] || [ "$(printf '%s' "$A" | jq -r '.metadata["gc.routed_to"] // ""' 2>/dev/null)" != "$ROUTE" ] || [ "$(printf '%s' "$A" | jq -r '.status // ""' 2>/dev/null)" != in_progress ]; then
    # o desfazer também é uma escrita que pode falhar, e o rc dele não diz o estado (a comparação atômica reprova, de propósito, quando a escrita nem pegou e a bead nunca foi nossa): relê, e o log e a
    # mensagem só dizem "desfeita" se nada nosso sobrou (nem dono nem rota). Bead que não se consegue reler, ou que ainda é nossa, fica NAO-desfeito: a bead atribuída ao nó não pode parecer solta.
    T "$BD" -C "$store" update "$id" --if-assignee "$ALIAS" --assignee "" --status open --unset-metadata gc.routed_to -q >/dev/null 2>&1
    A=$(bead_json "$store" "$id") || A=""
    u=NAO-desfeito
    if [ -n "$A" ] && [ "$(printf '%s' "$A" | jq -r '.assignee // ""' 2>/dev/null)" != "$ALIAS" ] && [ "$(printf '%s' "$A" | jq -r '.metadata["gc.routed_to"] // ""' 2>/dev/null)" != "$ROUTE" ]; then u=desfeito; else say "ATENÇÃO: não consegui desfazer a atribuição de $id — confira à mão"; fi
    jlog apply "$id" 13 "conferencia-falhou-$u"; [ "$u" = desfeito ] && die 13 "não consegui confirmar a atribuição de $id — desfeita"; die 13 "não consegui confirmar a atribuição de $id — NÃO desfeita: confira à mão"
  fi
  T "$BD" -C "$store" comment "$id" "nó (ga-2hd02v.1.10): atribuída a $ALIAS, rota $ROUTE — veredito node (base $b: $(printf '%s' "$out" | jq -r '(.reasons // []) | join(", ")')). O pool cria a sessão; sem gc session new à mão (a duplicata é derrubada pelo dedup). Ao fim da entrega: wa-node-dispatch.sh release $id." >/dev/null 2>&1 || say "aviso: comentário em $id não gravado"
  jlog apply "$id" 0 "despachada para $ALIAS ($b)"; say "$id → $ALIAS ($ROUTE), base=$b"; printf '%s\n' "$out"; exit 0 ;;

release)
  as=$(printf '%s' "$B" | jq -r '.assignee // ""'); rt=$(printf '%s' "$B" | jq -r '.metadata["gc.routed_to"] // ""')
  [ "$as" = "$ALIAS" ] && [ "$rt" = "$ROUTE" ] || { jlog release "$id" 12 "nao-e-do-no assignee=$as rota=$rt"; die 12 "$id não é do $ALIAS com a rota $ROUTE (assignee=${as:-—} rota=${rt:-—}) — não solto"; }
  T "$BD" -C "$store" update "$id" --if-assignee "$ALIAS" --assignee "" --unset-metadata gc.routed_to -q >/dev/null 2>&1 || { jlog release "$id" 13 "escrita-falhou"; die 13 "bd update falhou ao soltar $id"; }
  A=$(bead_json "$store" "$id") || A=""
  { [ -n "$A" ] && [ -z "$(printf '%s' "$A" | jq -r '.assignee // ""')" ] && [ -z "$(printf '%s' "$A" | jq -r '.metadata["gc.routed_to"] // ""')" ]; } || { jlog release "$id" 13 "conferencia-falhou"; die 13 "não consegui confirmar que $id foi solta — confira à mão"; }
  T "$BD" -C "$store" comment "$id" "nó (ga-2hd02v.1.10): dono $ALIAS e rota $ROUTE soltos após a entrega (evita sessão nova a cada 15 min até o merge)." >/dev/null 2>&1 || true
  jlog release "$id" 0 "solta"; say "$id solta"; exit 0 ;;

*) die 2 "comando desconhecido: $cmd (check|apply|release)" ;;
esac
