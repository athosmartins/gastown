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
# SAÍDA: 0 feito (check: "roda no nó") · 10 fica no mini · 11 não consegui ler/decidir · 12 não elegível agora (bead já tem dono/rota, INCLUSIVE a que já é do nó; slot do nó ocupado; corrida perdida) ·
#   13 escrita não confirmada: a conferência reprovou (a mensagem diz se a atribuição foi desfeita ou não) OU o bd update falhou (rc ≠ 0 e ≠ 13) e a releitura não achou nada nosso — mas uma escrita morta por prazo
#   ainda pode entrar, então nada está garantido e o Pilot segura a bead e relê na próxima varredura · 2 uso. Em dúvida o código é 10-13, nunca 0; a única exceção é a releitura PROVAR o estado (o bd update disse
#   que falhou e a releitura confere a bead inteira do nó = 0, anotado no log). O Pilot lê 10/11/12 como "fica no mini" só para a bead que ELE leu como não-do-nó; a que já é do nó ele segura (2) sem olhar o rc.
# O QUE FAZ (apply): relê a bead → exige aberta, sem dono e sem rota → classifica (scripts/wa-node-classify.py, na MESMA leitura; o exit code só vale se o JSON concorda — falha, saída ilegível ou código e veredito que discordam = 11, nunca 0) → exige o slot do nó livre (nenhuma bead em andamento do alias
#   e nenhuma sessão do template — no modo pilot, uma sessão viva OCIOSA e sem bead conta como vaga, ver N SLOTS) → UMA escrita com comparação atômica (bd update --if-assignee '' --if-status open: quem chegou antes vence, rc 13 do bd) que atribui ao alias, põe
#   em andamento e carimba gc.routed_to → relê e confere → comenta. Falha na conferência desfaz. A escrita que o bd diz ter falhado (rc ≠ 0 e ≠ 13) cai na MESMA releitura: o rc de um update que não respondeu não diz o estado.
#   `release` só mexe em bead que é do alias E da rota.
# O QUE NÃO FAZ: não cria sessão (quem abre a sessão do alias é o pool, em WA_NODE_SPAWN=pool, ou o Pilot, em =pilot: ver abaixo). `gc session new` à mão em template remoto ROTEADO gera duas sessões e o
#   crew-session-dedup derruba uma. Não mexe no city.toml, no config do host nem no Pilot. Não escreve dado da bead em lugar nenhum além do comentário curto (id, veredito, motivos).
# N SLOTS (ga-2hd02v.3): WA_NODE_SPAWN=pool (PADRÃO, o desenho da 1.10: 1 slot, alias wa-worker-remote-1, gc.routed_to=wa-worker-remote, o pool cria a sessão — NUNCA provado para bead da loja do WA) ou =pilot
#   (o Pilot abre `gc session new wa-worker-remote --alias <alias>` como faz com o dog-remote, receita PROVADA; a bead leva só o dono e a marca `pilot.wa_node_alias`, SEM gc.routed_to, senão o pool abriria
#   uma 2ª sessão). Só `pilot` tem mais de 1 slot: WA_NODE_SLOTS (1..9, padrão 1) aliases wa-worker-remote-1..N; em `pool` o N vale 1 (o alias da sessão do pool não é nomeável). Em `pilot` o apply escolhe a sessão OCIOSA (ver abaixo) ou, senão, o 1º alias
#   sem bead em andamento e sem sessão viva, e CONSULTA o oráculo de capacidade (hetzner-capacity.py verdict): só `node` com vaga livre (descontadas as beads já atribuídas cuja sessão ainda não subiu) deixa passar.
#   SESSÃO OCIOSA (ga-2hd02v.3.12): em `pilot`, uma sessão viva do template SEM bead em andamento no alias e quieta há >= WA_NODE_IDLE_SECS (padrão 300 s) é VAGA, não lugar tomado: o apply a PREFERE a abrir um alias
#   novo (nenhuma tmux a mais no nó) e a bead vai para o alias dela. Três estados: ociosa PROVADA = vaga · bead em andamento ou quieta há pouco = ocupada · não deu para saber (last_active ausente, ilegível ou no futuro,
#   estado que não é `active`, outro template, dois alias iguais) = OCUPADA, o inerte. Antes, toda sessão viva enchia um slot: 3 vivas (uma já sem bead) = 12 `sessao-viva` em toda varredura (27 em ~19 h).
# Env: WA_NODE_SPAWN (pool|pilot, padrão pool; outro valor = pool), WA_NODE_SLOTS (1..9, padrão 1; vazio ou ilegível = 1), WA_NODE_ALIAS_PREFIX (wa-worker-remote-), WA_NODE_CAPACITY (hetzner-capacity.py), WA_NODE_CAPACITY_TIMEOUT (45 s), WA_NODE_IDLE_SECS (300 s: quanto tempo uma sessão sem bead fica quieta antes de valer como vaga; só modo pilot).
# Env (identidade, para o wrapper de OUTRA loja — o ps-node-dispatch.sh da bead de PS): WA_NODE_SELF (nome que as mensagens e o comentário da bead usam, padrão wa-node-dispatch.sh), WA_NODE_STORY (bead que o comentário cita, padrão ga-2hd02v.1.10).
# Env (teste): GC_CITY, WA_NODE_BD (bd), WA_NODE_GC (gc), WA_NODE_CLASSIFY, WA_NODE_PY, WA_NODE_ALIAS (alias único: ganha de SLOTS e do prefixo; padrão <prefixo>1), WA_NODE_ROUTE_TEMPLATE (wa-worker-remote), WA_NODE_LOG, WA_NODE_TIMEOUT (20 s), WA_NODE_SESSION_TIMEOUT (60 s, só para `gc session list`).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CITY="${GC_CITY:-$(cd "$HERE/.." && pwd)}"
BD="${WA_NODE_BD:-bd}"; GC="${WA_NODE_GC:-gc}"; PY="${WA_NODE_PY:-python3}"
CLS="${WA_NODE_CLASSIFY:-$HERE/wa-node-classify.py}"
PREFIX="${WA_NODE_ALIAS_PREFIX:-wa-worker-remote-}"; ROUTE="${WA_NODE_ROUTE_TEMPLATE:-wa-worker-remote}"
# modo de abrir a sessão e número de slots (ga-2hd02v.3). vazio → pool e 1 slot (o desenho da 1.10); ilegível (valor desconhecido, não-número, 0, 10+) → o mesmo: NUNCA mais slots por engano.
# Em `pool` o alias da sessão não é nomeável (o pool dá o nome), então só há 1 slot, e é o que um alias único de teste (WA_NODE_ALIAS) também força.
SPAWN="${WA_NODE_SPAWN:-pool}"; case "$SPAWN" in pool|pilot) ;; *) SPAWN=pool ;; esac
SLOTS="${WA_NODE_SLOTS:-1}"; case "$SLOTS" in [1-9]) ;; *) SLOTS=1 ;; esac
[ "$SPAWN" = pilot ] || SLOTS=1
ALIASES=""; k=1
if [ -n "${WA_NODE_ALIAS:-}" ]; then ALIASES="$WA_NODE_ALIAS"; SLOTS=1; else while [ "$k" -le "$SLOTS" ]; do ALIASES="$ALIASES ${PREFIX}$k"; k=$((k+1)); done; ALIASES="${ALIASES# }"; fi
ALIAS="${ALIASES%% *}"   # o 1º: o único em pool, o de mensagem quando só há um
CAP="${WA_NODE_CAPACITY:-$HERE/hetzner-capacity.py}"
CTMO="${WA_NODE_CAPACITY_TIMEOUT:-45}"
case "$CTMO" in ''|*[!0-9]*) CTMO=45 ;; esac   # o oráculo mede o nó por ssh (o Pilot dá 40 s ao veredito inteiro); prazo ilegível volta ao padrão
LOG="${WA_NODE_LOG:-$CITY/.gc/wa-node-route.jsonl}"
TMO="${WA_NODE_TIMEOUT:-20}"
case "$TMO" in ''|*[!0-9]*) TMO=20 ;; esac     # prazo ilegível volta ao padrão
# `gc session list --json` levou 14–22 s na mini carregada (medido 19/10) — com o prazo de 20 s a leitura estourava e o despacho nunca passava; esta leitura tem prazo próprio
STMO="${WA_NODE_SESSION_TIMEOUT:-60}"
case "$STMO" in ''|*[!0-9]*) STMO=60 ;; esac
# ga-2hd02v.3.12: quietude mínima de uma sessão sem bead para valer como vaga (só modo pilot). vazio → 300 s; ilegível (letra, sinal, ponto, espaço, mais de 9 dígitos) → 300 s também: o erro cai no prazo mais LONGO,
# nunca no mais curto. 0 vale (qualquer sessão sem bead). Zero à esquerda é decimal (0300 = 300: o bash o leria como octal sem o 10#).
IDLE="${WA_NODE_IDLE_SECS:-300}"; case "$IDLE" in ''|*[!0-9]*) IDLE=300 ;; *) if [ "${#IDLE}" -le 9 ]; then IDLE=$((10#$IDLE)); else IDLE=300; fi ;; esac

# como o script se chama nas mensagens e qual bead o comentário cita (ga-2hd02v.3). Um wrapper de outra loja (PS) troca os dois sem copiar o script.
# vazio → o nome e a bead de sempre; ilegível (espaço, aspas, barra, $, `, ;, quebra de linha, acima de 64 caracteres) → o mesmo: o valor vai para a mensagem e para um comentário DA BEAD, então nunca entra solto.
SELF="${WA_NODE_SELF:-wa-node-dispatch.sh}"; case "$SELF" in *[!A-Za-z0-9._-]*) SELF=wa-node-dispatch.sh ;; esac; [ "${#SELF}" -le 64 ] || SELF=wa-node-dispatch.sh
STORY="${WA_NODE_STORY:-ga-2hd02v.1.10}"; case "$STORY" in *[!A-Za-z0-9._-]*) STORY=ga-2hd02v.1.10 ;; esac; [ "${#STORY}" -le 64 ] || STORY=ga-2hd02v.1.10
say() { echo "${SELF%.sh}: $*" >&2; }
die() { local rc="$1"; shift; say "$*"; exit "$rc"; }
T() { if command -v timeout >/dev/null 2>&1; then timeout "$TMO" "$@"; else "$@"; fi; }
TS() { if command -v timeout >/dev/null 2>&1; then timeout "$STMO" "$@"; else "$@"; fi; }
TC() { if command -v timeout >/dev/null 2>&1; then timeout "$CTMO" "$@"; else "$@"; fi; }
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

cmd="${1:-}"; id="${2:-}"; [ $# -ge 2 ] || die 2 "uso: $SELF check|apply|release <bead> [--store DIR] [--basis label|any] [--dry-run]"
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
  # slots do nó: por alias candidato, as beads em andamento dele. vazio → alias sem bead (livre); falhou/ilegível → não sei: o conjunto todo vira 11, NUNCA livre por engano; com bead → ocupado
  free_a=""; busy_a=""; busy_n=0
  for A in $ALIASES; do
    mine=$(T "$BD" -C "$store" list --status in_progress --assignee "$A" --json --limit 5 2>/dev/null) || { jlog apply "$id" 11 "slot-ilegivel"; die 11 "não consegui ler o slot do nó (bd list) — fica no mini"; }
    n=$(printf '%s' "$mine" | jq -r 'if type=="array" then length else "x" end' 2>/dev/null)
    case "$n" in 0) free_a="$free_a $A" ;; ''|x|*[!0-9]*) jlog apply "$id" 11 "slot-ilegivel"; die 11 "leitura do slot do nó não é uma lista — fica no mini" ;; *) busy_a="$busy_a $A"; busy_n=$((busy_n+n)) ;; esac
  done
  if [ -z "$free_a" ]; then
    [ "$SLOTS" = 1 ] && { jlog apply "$id" 12 "slot-ocupado bead(s)=$busy_n"; die 12 "slot do nó ocupado ($busy_n bead(s) em andamento de $ALIAS)"; }
    jlog apply "$id" 12 "slot-ocupado bead(s)=$busy_n aliases=${busy_a# }"; die 12 "os $SLOTS slots do nó estão ocupados ($busy_n bead(s) em andamento de${busy_a})"
  fi
  # gc session list --json devolve {"sessions":[…]} (medido 19/10), nunca o array solto: vazio → lista [] (0 vivas); falhou/ilegível/outro formato → "x" (11, fica no mini); sessão com closed=true ou estado final não conta.
  # Conta as vivas do template OU com alias candidato e guarda o alias de cada uma (sessão do pool sem alias entra na conta com alias vazio).
  sess=$(TS "$GC" session list --json 2>/dev/null) || { jlog apply "$id" 11 "sessoes-ilegiveis"; die 11 "não consegui listar as sessões — fica no mini"; }
  al_json=$(printf '%s\n' $ALIASES | jq -R . 2>/dev/null | jq -sc . 2>/dev/null) || al_json=""   # vazio/ilegível → "" e o jq abaixo falha: "x" (11)
  # ga-2hd02v.3: no modo pilot a sessão DORMINDO (state asleep) do template do nó não conta como viva e o alias dela pode ser escolhido: o idle_timeout (15 min) a põe para dormir SEM soltar o alias, e sem isto todo slot
  # queimava na 1ª ociosidade e o nó ficava cheio de sessões que não gastam nada. O Pilot a ACORDA (session wake), como faz com o dog-remote. Sessão dormindo de OUTRO template, ou em estado que não conheço, segue viva.
  # No modo pool nada muda (uma sessão dormindo ainda segura o slot: o pool é quem a trata).
  live_json=$(printf '%s' "$sess" | jq -c --arg t "$ROUTE" --arg sp "$SPAWN" --argjson al "$al_json" 'if type=="object" and (.sessions|type)=="array" then [.sessions[] | select(((.template // .Template // "") == $t) or ((.alias // .Alias // "") as $x | $al | any(. == $x))) | select(.closed != true) | select((.state // .State // "") | test("closed|stopped|archived|drained") | not) | select(($sp == "pilot" and ((.state // .State // "") == "asleep") and ((.template // .Template // "") == $t)) | not) | (.alias // .Alias // "")] else "x" end' 2>/dev/null)
  live=$(printf '%s' "$live_json" | jq -r 'if type=="array" then length else "x" end' 2>/dev/null)
  case "$live" in ''|x|*[!0-9]*) jlog apply "$id" 11 "sessoes-ilegiveis"; die 11 "lista de sessões ilegível — fica no mini" ;; esac
  live_al=$(printf '%s' "$live_json" | jq -r '.[]' 2>/dev/null) || live_al=""   # lista vazia lida → nenhum alias vivo; o formato já foi provado acima
  # ga-2hd02v.3.12: sessão viva OCIOSA é vaga, não lugar tomado (só modo pilot). Provada = do template do nó, `active`, alias candidato, last_active lido como texto ISO com Z e velho (>= IDLE s, nunca no futuro), SEM bead
  # em andamento no alias (free_a) e a ÚNICA viva com aquele alias. vazio (nenhuma assim) → reuse_a vazio e toda sessão viva segue contando, como antes; falhou/ilegível (last_active ausente, nulo, número, sem Z, fração
  # lida mas data inválida, no futuro; estado ≠ active; outro template; alias repetido) → essa sessão NÃO é vaga: segue ocupada, o inerte. Só o jq que não roda (idle_json não é lista) vira 11: não sei avaliar, fica no mini.
  reuse_a=""; n_reuse=0
  if [ "$SPAWN" = pilot ]; then
    idle_json=$(printf '%s' "$sess" | jq -c --arg t "$ROUTE" --argjson al "$al_json" --argjson now "$(date +%s)" --argjson idle "$IDLE" 'if type=="object" and (.sessions|type)=="array" then [.sessions[] | select(type=="object") | select(((.template // .Template // "") == $t) and .closed != true and ((.state // .State // "") == "active")) | select((.alias // .Alias // "") as $x | $x != "" and ($al | any(. == $x))) | select((.last_active | type) == "string") | select(((.last_active | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) as $ts | (($ts | type) == "number") and (($now - $ts) >= $idle))) | (.alias // .Alias)] else "x" end' 2>/dev/null) || idle_json="x"
    case "$(printf '%s' "$idle_json" | jq -r 'if type=="array" then "ok" else "x" end' 2>/dev/null)" in ok) ;; *) jlog apply "$id" 11 "ociosidade-ilegivel"; die 11 "não consegui avaliar quais sessões estão ociosas — fica no mini" ;; esac
    idle_al=$(printf '%s' "$idle_json" | jq -r '.[]' 2>/dev/null) || idle_al=""   # lista vazia lida → nenhuma ociosa provada; o formato já foi provado acima
    for A in $free_a; do
      [ "$(printf '%s\n' "$live_al" | grep -cxF -- "$A")" = 1 ] || continue   # exatamente UMA sessão viva com o alias; duas = não há uma só para reaproveitar
      printf '%s\n' "$idle_al" | grep -qxF -- "$A" || continue                # e é a ociosa provada
      reuse_a="$reuse_a $A"; n_reuse=$((n_reuse+1))
    done
  fi
  # as ociosas provadas saem da conta: a sessão já existe, reaproveitá-la não ocupa slot novo (o `n=` do log segue sendo o das vivas, o que o wa-node-report.py lê como sessao-viva)
  if [ $((live - n_reuse)) -ge "$SLOTS" ]; then jlog apply "$id" 12 "sessao-viva n=$live"; die 12 "já há $live sessão(ões) de $ROUTE/${ALIASES// /,} — slot do nó ocupado"; fi
  # a sessão ociosa PROVADA primeiro (nenhuma tmux a mais no nó, responde na hora); senão o 1º alias sem bead que também não tem sessão viva. Sessão viva sem prova de ociosidade (ativa ou subindo) NÃO é reaproveitada:
  # o alias dela ainda não está livre. No modo pilot a que dorme é reaproveitada (o Pilot a acorda, ver acima).
  PICK=""; REUSED=0
  for A in $reuse_a; do PICK="$A"; REUSED=1; break; done
  if [ -z "$PICK" ]; then
    for A in $free_a; do printf '%s\n' "$live_al" | grep -qxF -- "$A" || { PICK="$A"; break; }; done
  fi
  [ -n "$PICK" ] || { jlog apply "$id" 12 "slot-sem-alias-livre"; die 12 "todo alias sem bead em andamento ($free_a ) ainda tem sessão viva — sem slot livre agora"; }
  if [ "$SPAWN" = pilot ]; then
    # teto do nó (ga-2hd02v.3): o oráculo diz se cabe mais uma sessão (degrau × cap do provider × CPU/RAM medidos). Beads já atribuídas cuja sessão ainda não subiu o oráculo não vê: descontam da vaga dele.
    # vazio (sem saída) / falhou / ilegível (arquivo ausente, rc fora de 0/1, prazo, JSON ruim, rc e veredito que discordam, `free` que não é inteiro ≥ 1 num `node`) → 11, NUNCA node por engano; local (rc 1) → 12.
    pend=0; for A in $busy_a; do printf '%s\n' "$live_al" | grep -qxF -- "$A" || pend=$((pend+1)); done
    [ -f "$CAP" ] || { jlog apply "$id" 11 "oraculo-ausente"; die 11 "o oráculo de capacidade $CAP não existe — fica no mini"; }
    cout=$(TC "$PY" -I "$CAP" --json verdict 2>/dev/null </dev/null); crc=$?
    cv=$(printf '%s' "$cout" | jq -r '.verdict // ""' 2>/dev/null) || cv=""
    case "$crc:$cv" in
      0:node) ;;
      1:local) cwhy=$(printf '%s' "$cout" | jq -r '.reason // ""' 2>/dev/null) || cwhy=""; jlog apply "$id" 12 "oraculo-local:$cwhy"; die 12 "o oráculo de capacidade diz que o nó não recebe agora (${cwhy:-sem motivo}) — fica no mini" ;;
      *) jlog apply "$id" 11 "oraculo-ilegivel rc=$crc verdict=${cv:-?}"; die 11 "o oráculo de capacidade não respondeu de forma coerente (rc=$crc, veredito=${cv:-?}) — fica no mini" ;;
    esac
    cfree=$(printf '%s' "$cout" | jq -r '(.free | select(type=="number")) // empty' 2>/dev/null) || cfree=""   # só número vale: texto ("2"), nulo ou ausente → vazio → 11
    case "$cfree" in ''|*[!0-9]*|0) jlog apply "$id" 11 "oraculo-sem-free"; die 11 "o oráculo disse node sem um número de vagas livres (>= 1) — fica no mini" ;; esac
    if [ $((cfree - pend)) -lt 1 ]; then jlog apply "$id" 12 "oraculo-sem-vaga free=$cfree pendentes=$pend"; die 12 "o oráculo vê $cfree vaga(s) livre(s) e $pend bead(s) já atribuída(s) esperam a sessão subir — sem vaga agora"; fi
  fi
  rn=""; [ "$REUSED" = 1 ] && rn=" [sessão ociosa reaproveitada]"   # só o log e a mensagem: a sessão do alias já está viva, ninguém abre outra
  if [ "$dry" = 1 ]; then jlog apply "$id" 0 "dry-run: iria para $PICK ($b)$rn"; say "dry-run: $id iria para $PICK (base=$b)$rn; nada foi escrito"; printf '%s\n' "$out"; exit 0; fi
  # o que a escrita carimba: pool → a rota (o pool cria a sessão); pilot → só a marca (o Pilot abre a sessão do alias; a rota abriria uma 2ª)
  if [ "$SPAWN" = pilot ]; then wmeta="pilot.wa_node_alias=$PICK"; umeta="pilot.wa_node_alias"; else wmeta="gc.routed_to=$ROUTE"; umeta="gc.routed_to"; fi
  # a bead é "nossa" se o dono é o alias e o carimbo do modo está lá; pool: dono OU rota; pilot: dono OU marca. (a conferência abaixo usa o conjunto, o desfazer usa o "nada nosso")
  mine_ok() { # mine_ok <json da bead> — 0 se dono=PICK, status in_progress e o carimbo do modo bate
    local j="$1" m
    [ "$(printf '%s' "$j" | jq -r '.assignee // ""' 2>/dev/null)" = "$PICK" ] || return 1
    [ "$(printf '%s' "$j" | jq -r '.status // ""' 2>/dev/null)" = in_progress ] || return 1
    if [ "$SPAWN" = pilot ]; then m=$(printf '%s' "$j" | jq -r '.metadata["pilot.wa_node_alias"] // ""' 2>/dev/null); [ "$m" = "$PICK" ]; else m=$(printf '%s' "$j" | jq -r '.metadata["gc.routed_to"] // ""' 2>/dev/null); [ "$m" = "$ROUTE" ]; fi
  }
  nada_nosso() { # nada_nosso <json da bead> — 0 se não sobrou dono nem carimbo do modo
    local j="$1" m
    [ -n "$j" ] || return 1
    [ "$(printf '%s' "$j" | jq -r '.assignee // ""' 2>/dev/null)" != "$PICK" ] || return 1
    if [ "$SPAWN" = pilot ]; then m=$(printf '%s' "$j" | jq -r '.metadata["pilot.wa_node_alias"] // ""' 2>/dev/null); [ "$m" != "$PICK" ]; else m=$(printf '%s' "$j" | jq -r '.metadata["gc.routed_to"] // ""' 2>/dev/null); [ "$m" != "$ROUTE" ]; fi
  }
  T "$BD" -C "$store" update "$id" --if-assignee "" --if-status open --assignee "$PICK" --status in_progress --set-metadata "$wmeta" -q >/dev/null 2>&1; w=$?
  if [ "$w" = 13 ]; then jlog apply "$id" 12 "perdeu-a-corrida"; die 12 "$id mudou entre a leitura e a escrita (bd rc 13) — não mexo"; fi
  # w ≠ 0 e ≠ 13 (prazo estourado, processo morto, bd fora): o rc de um update que não respondeu NÃO diz o estado, o servidor pode ter gravado (ga-9636op, gate-fix 1). Quem diz é a releitura, a MESMA conferência de
  # baixo: confere = a escrita pegou e só a resposta se perdeu (segue como sucesso); algo nosso = desfaz; nada nosso = 13 "nada garantido", porque uma escrita morta por prazo ainda pode entrar e só uma releitura posterior resolve.
  A=$(bead_json "$store" "$id") || A=""
  if ! mine_ok "$A"; then
    # o desfazer também é uma escrita que pode falhar, e o rc dele não diz o estado (a comparação atômica reprova, de propósito, quando a escrita nem pegou e a bead nunca foi nossa): relê, e o log e a
    # mensagem só dizem "desfeita" se nada nosso sobrou (nem dono nem rota). Bead que não se consegue reler, ou que ainda é nossa, fica NAO-desfeito: a bead atribuída ao nó não pode parecer solta.
    T "$BD" -C "$store" update "$id" --if-assignee "$PICK" --assignee "" --status open --unset-metadata "$umeta" -q >/dev/null 2>&1
    A=$(bead_json "$store" "$id") || A=""
    u=NAO-desfeito
    if nada_nosso "$A"; then u=desfeito; else say "ATENÇÃO: não consegui desfazer a atribuição de $id — confira à mão"; fi
    if [ "$w" != 0 ]; then   # o bd disse que a escrita falhou: "nada nosso" na releitura não prova que ela não vai entrar, então a mensagem e o log NÃO dizem "desfeita"
      [ "$u" = desfeito ] && { jlog apply "$id" 13 "escrita-falhou-sem-nada-nosso rc=$w"; die 13 "bd update falhou (rc=$w) e a releitura não mostra nada nosso em $id — uma escrita que estourou o prazo pode ainda entrar: nada garantido (o Pilot segura a bead e relê)"; }
      jlog apply "$id" 13 "escrita-falhou-NAO-desfeito rc=$w"; die 13 "bd update falhou (rc=$w) e não consegui confirmar nem desfazer a atribuição de $id — NÃO desfeita: confira à mão"
    fi
    jlog apply "$id" 13 "conferencia-falhou-$u"; [ "$u" = desfeito ] && die 13 "não consegui confirmar a atribuição de $id — desfeita"; die 13 "não consegui confirmar a atribuição de $id — NÃO desfeita: confira à mão"
  fi
  if [ "$SPAWN" = pilot ]; then who="atribuída a $PICK (marca pilot.wa_node_alias, sem rota) — veredito node (base $b: $(printf '%s' "$out" | jq -r '(.reasons // []) | join(", ")')). O Pilot abre a sessão do alias; sem gc session new à mão."
  else who="atribuída a $PICK, rota $ROUTE — veredito node (base $b: $(printf '%s' "$out" | jq -r '(.reasons // []) | join(", ")')). O pool cria a sessão; sem gc session new à mão (a duplicata é derrubada pelo dedup)."; fi
  [ "$REUSED" = 1 ] && who="$who A sessão do alias já está viva e ociosa (reaproveitada): o Pilot só a avisa."
  T "$BD" -C "$store" comment "$id" "nó ($STORY): $who Ao fim da entrega: $SELF release $id." >/dev/null 2>&1 || say "aviso: comentário em $id não gravado"
  wn=""; [ "$w" = 0 ] || wn=" [bd update rc=$w, a releitura confere]"   # o rc do bd mentiu (resposta perdida): fica no log
  jlog apply "$id" 0 "despachada para $PICK ($b)$wn$rn"; say "$id → $PICK ($([ "$SPAWN" = pilot ] && echo sessão-do-pilot || echo "$ROUTE")), base=$b$wn$rn"; printf '%s\n' "$out"; exit 0 ;;

release)
  as=$(printf '%s' "$B" | jq -r '.assignee // ""'); rt=$(printf '%s' "$B" | jq -r '.metadata["gc.routed_to"] // ""'); mk=$(printf '%s' "$B" | jq -r '.metadata["pilot.wa_node_alias"] // ""')
  # só solta bead que é de um alias do nó (o do teste, ou <prefixo>1..9 — vale também para o alias de um N maior que o de hoje, a bead não fica presa se o N baixar) E do carimbo do modo em que foi atribuída:
  # pool → a rota; pilot → a marca com o próprio alias e sem rota. Dono de outra pessoa, rota de outro pool ou marca de outro alias → 12, sem escrita.
  case "$as" in "$ALIAS"|"$PREFIX"[1-9]) mine_alias=1 ;; *) mine_alias=0 ;; esac
  shape=""
  if [ "$mine_alias" = 1 ] && [ "$rt" = "$ROUTE" ] && [ -z "$mk" ]; then shape=pool; elif [ "$mine_alias" = 1 ] && [ -z "$rt" ] && [ "$mk" = "$as" ]; then shape=pilot; fi
  [ -n "$shape" ] || { jlog release "$id" 12 "nao-e-do-no assignee=$as rota=$rt marca=$mk"; die 12 "$id não é de um alias do nó ($PREFIX*) com a rota $ROUTE ou a marca do Pilot (assignee=${as:-—} rota=${rt:-—} marca=${mk:-—}) — não solto"; }
  if [ "$shape" = pilot ]; then ukey="pilot.wa_node_alias"; else ukey="gc.routed_to"; fi
  T "$BD" -C "$store" update "$id" --if-assignee "$as" --assignee "" --unset-metadata "$ukey" -q >/dev/null 2>&1 || { jlog release "$id" 13 "escrita-falhou"; die 13 "bd update falhou ao soltar $id — nada garantido (um update morto por prazo pode ter gravado); confira"; }
  A=$(bead_json "$store" "$id") || A=""
  { [ -n "$A" ] && [ -z "$(printf '%s' "$A" | jq -r '.assignee // ""')" ] && [ -z "$(printf '%s' "$A" | jq -r '.metadata["gc.routed_to"] // ""')" ] && [ -z "$(printf '%s' "$A" | jq -r '.metadata["pilot.wa_node_alias"] // ""')" ]; } || { jlog release "$id" 13 "conferencia-falhou"; die 13 "não consegui confirmar que $id foi solta — confira à mão"; }
  T "$BD" -C "$store" comment "$id" "nó ($STORY): dono $as e $([ "$shape" = pilot ] && echo "marca $ukey" || echo "rota $ROUTE") soltos após a entrega (evita sessão nova a cada 15 min até o merge)." >/dev/null 2>&1 || true
  jlog release "$id" 0 "solta"; say "$id solta"; exit 0 ;;

*) die 2 "comando desconhecido: $cmd (check|apply|release)" ;;
esac
