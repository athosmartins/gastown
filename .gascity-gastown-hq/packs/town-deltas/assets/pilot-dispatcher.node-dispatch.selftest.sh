#!/usr/bin/env bash
# pilot-dispatcher.node-dispatch.selftest.sh — ga-2hd02v.1.14 (PILOT_NODE_FIRST=on: o Pilot leva a bead de dog ao nó Hetzner)
#
# Com o veredito `node` (pilot-dispatcher.node-first.selftest.sh prova de onde ele vem), o Pilot escolhe um alias livre dog-remote-<n> (n <= effective), atribui a bead a ele,
# abre/acorda a sessão e avisa. Este arquivo é a MATRIZ DE DECISÃO de `_pilot_node_pick_alias` e `_pilot_node_first_dispatch` + `_pilot_node_first_rollback`, e a prova de que
# NENHUMA falha deixa a bead presa no nó.
#
# Contents
#   O que prova · Como roda · Controle negativo
#
# O QUE PROVA: o alias é sempre dog-remote-<n> com n entre 1 e effective, o 1º livre; sessão ocupada (active/creating/start-pending/draining/qualquer estado que não conheço) nunca é reusada,
#   a dormindo (asleep) é ACORDADA em vez de criar outra; vagas já tomadas por sessões do pool sem alias contam; effective que não é inteiro > 0 e lista de sessões ilegível (rc≠0, vazia, não
#   JSON, sem o array) viram "mini" SEM tocar na bead · a ordem é atribuir → abrir a sessão → avisar · QUALQUER falha (atribuição, sessão, prazo da sessão, aviso) desfaz a atribuição (com
#   --if-assignee: nunca pisa em quem pegou a bead depois), fecha a sessão que chegou a abrir e devolve a bead ao mini com o estado de antes (sem dono, aberta) · desfazer que não se
#   confirma NÃO manda a bead ao mini (podia ser construída duas vezes): vira "stuck" e o claim fica para o TTL · uma sessão lenta (>= PILOT_SLOW_SPAWN_SECS ou prazo) gasta o orçamento do
#   sweep · a função devolve 0 e não aborta sob `set -euo pipefail` · no dispatch_one o desvio ao nó só existe com PILOT_NODE_FIRST=on, veredito node e fora do DRY_RUN.
# COMO RODA: as funções são extraídas VERBATIM do dispatcher (awk) e rodam num shell filho sob o `set -euo pipefail` dele, com `gc` e `bd` FALSOS num PATH sem os reais (selftest-sandbox-path.lib.sh):
#   o `bd` falso é um repositório de uma bead (assignee/status em arquivo), então "o estado voltou" é lido do estado, não deduzido das chamadas. Contra um dispatcher sem as funções o
#   arquivo se recusa a começar — o vermelho honesto.
# CONTROLE NEGATIVO: falha que vira node · claim que não é solto · alias acima de effective · lista ilegível lida como vazia · aviso que falha sem desfazer · desfazer não confirmado dado
#   como limpo · sessão aberta que não é fechada no desfazer · cada um aplicado numa cópia do dispatcher.
# Variáveis: PILOT_DISPATCHER_PATH · ND_NO_MUTANTS=1
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ -n "${ND_MUTANT:-}" ] || echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; [ -z "${ND_MUTANT:-}" ] || { echo "RESULT $FAIL/$((PASS+FAIL))"; exit 1; }; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
FUNCS=""
for f in gc_json_or_unknown _pilot_slow_spawn_budget_spent _pilot_note_spawn_timing _pilot_node_pick_alias _pilot_node_first_rollback _pilot_node_first_dispatch; do
  src="$(fn_src "$f")"
  [ -n "$src" ] || { echo "FATAL: $f() not found in $DISPATCHER (ga-2hd02v.1.14 not applied)" >&2; exit 2; }
  FUNCS="$FUNCS
$src"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-nodedispatch-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/city"
# gc FALSO: `gc --city C session <sub> ...`. Registra a chamada; o rc de cada subcomando vem de $WORK/gc.<sub>.rc (padrão 0); `list` imprime $WORK/sessions.json.
cat > "$WORK/bin/gc" <<'EOF'
#!/bin/sh
W="${SELFTEST_WORK:?}"
echo "gc $*" >> "$W/calls.log"
[ "$1" = "--city" ] && [ "$3" = "session" ] || exit 99
rc() { if [ -f "$W/gc.$1.rc" ]; then cat "$W/gc.$1.rc"; else echo 0; fi; }
case "$4" in
  list) r=$(rc list); [ "$r" = 0 ] || exit "$r"; [ -f "$W/sessions.json" ] && cat "$W/sessions.json"; exit 0 ;;
  new|wake|nudge|close) exit "$(rc "$4")" ;;
esac
exit 98
EOF
# bd FALSO: um repositório de UMA bead (assignee em $WORK/bead.assignee, status em $WORK/bead.status). Honra --if-assignee (exit 13 se o dono não é o esperado).
#   bd.assign.rc = rc de `update --assignee <alias>`; bd.unassign.rc = rc de `update --assignee ""` (a soltura); bd.assign.partial = a escrita FOI aplicada mesmo com rc≠0 (o prazo estourou depois do commit);
#   bd.keepstatus = a soltura limpa o dono mas o status não volta a open; bd.show.rc.
cat > "$WORK/bin/bd" <<'EOF'
#!/bin/sh
W="${SELFTEST_WORK:?}"
echo "bd $*" >> "$W/calls.log"
[ "$1" = "-C" ] || exit 99
rc() { if [ -f "$W/bd.$1.rc" ]; then cat "$W/bd.$1.rc"; else echo 0; fi; }
cur() { if [ -f "$W/bead.assignee" ]; then cat "$W/bead.assignee"; fi; }
case "$3" in
  update)
    shift 4; have_a=0; a_new=""; st=""; have_ifa=0; ifa=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --assignee) have_a=1; a_new="$2"; shift 2 ;;
        --status) st="$2"; shift 2 ;;
        --if-assignee) have_ifa=1; ifa="$2"; shift 2 ;;
        --set-metadata|--unset-metadata) shift 2 ;;
        *) shift ;;
      esac
    done
    if [ "$have_ifa" = 1 ] && [ "$(cur)" != "$ifa" ]; then exit 13; fi
    if [ "$have_a" = 1 ]; then
      if [ -z "$a_new" ]; then r=$(rc unassign); else r=$(rc assign); fi
      if [ "$r" = 0 ] || [ -f "$W/bd.assign.partial" ]; then printf '%s' "$a_new" > "$W/bead.assignee"; if [ -n "$st" ] && { [ -n "$a_new" ] || [ ! -f "$W/bd.keepstatus" ]; }; then printf '%s' "$st" > "$W/bead.status"; fi; fi
      exit "$r"
    fi
    exit 0 ;;
  show) r=$(rc show); [ "$r" = 0 ] || exit "$r"
        s=open; [ ! -f "$W/bead.status" ] || s=$(cat "$W/bead.status")
        printf '[{"id":"%s","assignee":"%s","status":"%s"}]\n' "$4" "$(cur)" "$s"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/gc" "$WORK/bin/bd"
sandbox_path_init "$WORK" jq date timeout mkdir dirname cat sleep || exit 2

CALLS="$WORK/calls.log"; LINES="$WORK/lines.txt"
reset() { rm -f "$WORK"/gc.*.rc "$WORK"/bd.*.rc "$WORK"/bd.assign.partial "$WORK"/bd.keepstatus "$WORK"/sessions.json "$WORK"/bead.assignee "$WORK"/bead.status "$WORK"/slow.flag "$CALLS" "$LINES"; echo open > "$WORK/bead.status"; : > "$CALLS"; }
sess() { # sess alias:state[:template] ... → sessions.json (alias vazio = sessão do pool sem alias, só com name)
  local a j='[]' al st tp
  for a in "$@"; do
    IFS=: read -r al st tp <<<"$a"
    j=$(jq -c --arg al "$al" --arg st "$st" --arg tp "${tp:-dog-remote}" '. + [{id:("ga-" + (if $al == "" then "pool" else $al end)), name:(if $al == "" then "dog-remote-gawisp" else $al end), alias:$al, template:$tp, state:$st, closed:false}]' <<<"$j")
  done
  printf '{"sessions":%s}\n' "$j" > "$WORK/sessions.json"
}
setrc() { echo "$2" > "$WORK/$1"; }           # setrc gc.new.rc 1
assignee() { cat "$WORK/bead.assignee" 2>/dev/null; }
bstatus() { cat "$WORK/bead.status" 2>/dev/null; }
nline() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }          # nº da 1ª chamada que casa (vazio se nenhuma)
ncalls() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
writes() { grep -v 'session list' "$CALLS" | grep -vc '^bd .* show ' || true; }   # chamadas que MUDAM algo (nem lista de sessões nem leitura da bead)

# run_nd — uma chamada de _pilot_node_first_dispatch num filho sob `set -euo pipefail`; imprime "res=<node|mini|stuck> alias=<..>". Env: ND_EFF (padrão 3) ND_SLOW (1 = orçamento de spawn já gasto)
run_nd() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    log()  { echo "LOG $*" >> "$LINES"; }
    warn() { echo "WARN $*" >> "$LINES"; }
    GC_CITY="$WORK/city"; PILOT_SPAWN_TIMEOUT_SECS=20
    _PILOT_SLOW_SPAWN_SEEN="${ND_SLOW:-0}"
    eval "$FUNCS"
    # BARE: a função devolve 0 sempre; um comando que aborta sob errexit derruba este filho e o teste vê a saída sem "res=".
    _pilot_node_first_dispatch "story-1" "$WORK/city" "Título da bead" "${ND_EFF-3}"
    echo "res=${_PNF_RESULT-?} alias=${_PNF_ALIAS-?} slow=${_PILOT_SLOW_SPAWN_SEEN}"
  ) 2>&1 | tail -1
}

echo "── a escolha do alias: dog-remote-<n>, n <= effective, o 1º livre"
reset; sess; r=$(run_nd)
[ "$r" = "res=node alias=dog-remote-1 slow=0" ] && ok "nenhuma sessão: dog-remote-1" || bad "sem sessões escolheu '$r'"
reset; sess dog-remote-1:active; r=$(run_nd)
[ "$r" = "res=node alias=dog-remote-2 slow=0" ] && ok "dog-remote-1 ocupado: dog-remote-2" || bad "com o 1 ocupado escolheu '$r'"
reset; sess dog-remote-1:active dog-remote-3:active; r=$(ND_EFF=3 run_nd)
[ "$r" = "res=node alias=dog-remote-2 slow=0" ] && ok "o 1º livre, não o último: 1 e 3 ocupados → 2" || bad "1 e 3 ocupados escolheu '$r'"
reset; sess; r=$(ND_EFF=1 run_nd)
[ "$r" = "res=node alias=dog-remote-1 slow=0" ] && ok "effective=1: dog-remote-1 (nunca -2)" || bad "effective=1 escolheu '$r'"
reset; sess dog-remote-1:active; r=$(ND_EFF=1 run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ "$(writes)" = 0 ] && ok "effective=1 com o 1 ocupado: não há alias dentro do teto → mini, sem tocar na bead nem abrir sessão" || bad "teto cheio: '$r' writes=$(writes)"
reset; sess dog-remote-1:active dog-remote-2:active; r=$(ND_EFF=2 run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ "$(writes)" = 0 ] && [ -z "$(assignee)" ] && ok "effective=2 com 1 e 2 ocupados: nunca vai ao -3 → mini" || bad "teto 2 cheio: '$r' writes=$(writes)"
for st in creating start-pending draining estado-novo-que-nao-conheco; do
  reset; sess "dog-remote-1:$st"; r=$(ND_EFF=1 run_nd)
  [ "$r" = "res=mini alias= slow=0" ] && [ "$(writes)" = 0 ] && ok "sessão em '$st' é ocupada: não reusa, não cria por cima" || bad "sessão em '$st' foi tratada como livre: '$r'"
done
reset; sess dog-remote-1:asleep; r=$(ND_EFF=2 run_nd)
[ "$r" = "res=node alias=dog-remote-1 slow=0" ] && [ "$(ncalls 'session wake dog-remote-1')" = 1 ] && [ "$(ncalls 'session new')" = 0 ] && ok "alias dormindo: ACORDA (gc session wake), não cria outra sessão" || bad "alias dormindo: '$r' wake=$(ncalls 'session wake') new=$(ncalls 'session new')"
reset; sess dog-remote-1:active ":active"; r=$(ND_EFF=3 run_nd)
[ "$r" = "res=node alias=dog-remote-2 slow=0" ] && ok "dog-remote-1 e uma sessão sem alias ocupam 2 vagas de 3: ainda há uma, e o alias livre é o -2" || bad "pool sem alias + 1: '$r'"
reset; sess ":active"; r=$(ND_EFF=1 run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ "$(writes)" = 0 ] && ok "sessão do pool SEM alias ocupando a vaga única (effective=1): mini (as vagas contam por template, não só por alias)" || bad "pool sem alias não contou como vaga: '$r'"
reset; sess ":active" ":active"; r=$(ND_EFF=2 run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ "$(writes)" = 0 ] && ok "duas sessões sem alias com effective=2: teto cheio → mini (o alias dog-remote-1 está 'livre' mas não há vaga)" || bad "teto por template não respeitado: '$r'"
reset; sess "dog-remote-1:asleep" ":asleep"; r=$(ND_EFF=1 run_nd)
[ "$r" = "res=node alias=dog-remote-1 slow=0" ] && ok "sessão dormindo não gasta vaga" || bad "dormindo gastou vaga: '$r'"
reset; sess "dog-local-1:active:gastown.dog"; r=$(ND_EFF=1 run_nd)
[ "$r" = "res=node alias=dog-remote-1 slow=0" ] && ok "sessão de OUTRO template (gastown.dog, alias próprio) não conta nas vagas do nó" || bad "outro template contou: '$r'"
reset; sess "dog-remote-1:active:gastown.dog"; r=$(ND_EFF=2 run_nd)
[ "$r" = "res=node alias=dog-remote-2 slow=0" ] && ok "alias dog-remote-1 preso por sessão de OUTRO template: nunca é escolhido (a bead iria a quem não é o dog do nó) → -2" || bad "alias de outro template foi escolhido: '$r'"
reset; sess "dog-remote-1:asleep:gastown.dog"; r=$(ND_EFF=1 run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ "$(writes)" = 0 ] && ok "alias dormindo mas de OUTRO template: não acorda (wake seria acordar o agente errado) → mini" || bad "alias dormindo de outro template: '$r'"
reset; jq -cn '{sessions:[{id:"ga-x",name:"dog-remote-1",alias:"dog-remote-1",template:"dog-remote",state:"active",closed:true}]}' > "$WORK/sessions.json"; r=$(ND_EFF=1 run_nd)
[ "$r" = "res=node alias=dog-remote-1 slow=0" ] && ok "sessão fechada (closed=true) não ocupa o alias" || bad "sessão fechada ocupou o alias: '$r'"

echo "── o que não dá para ler ou não é número → mini, sem tocar em nada"
for eff in '' 0 abc -1 2.5 '3 4'; do
  reset; sess; r=$(ND_EFF="$eff" run_nd)
  [ "$r" = "res=mini alias= slow=0" ] && [ "$(writes)" = 0 ] && [ -z "$(assignee)" ] && ok "effective '${eff:-vazio}' não é inteiro > 0 → mini, nada escrito" || bad "effective '$eff' deu '$r' writes=$(writes)"
done
reset; setrc gc.list.rc 1; r=$(run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ "$(writes)" = 0 ] && ok "gc session list falha (rc 1) → mini (lista ilegível NÃO é 'sem sessões')" || bad "lista com rc 1 deu '$r'"
reset; r=$(run_nd)   # sem sessions.json: rc 0 e saída vazia
[ "$r" = "res=mini alias= slow=0" ] && [ "$(writes)" = 0 ] && ok "gc session list sem saída → mini" || bad "lista vazia de bytes deu '$r'"
reset; echo 'isto nao e json' > "$WORK/sessions.json"; r=$(run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ "$(writes)" = 0 ] && ok "gc session list que não é JSON → mini" || bad "lista não-JSON deu '$r'"
reset; echo '{"sessions":"x"}' > "$WORK/sessions.json"; r=$(run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ "$(writes)" = 0 ] && ok "JSON sem o array .sessions → mini" || bad "lista sem array deu '$r'"
reset; jq -cn '{sessions:{a:{id:"ga-x",name:"dog-remote-1",alias:"dog-remote-1",template:"dog-remote",state:"active"}}}' > "$WORK/sessions.json"; r=$(run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ "$(writes)" = 0 ] && ok ".sessions que é OBJETO (não array) → mini: o jq iteraria os valores e leria uma lista que ninguém prometeu" || bad ".sessions objeto deu '$r'"
reset; echo '{"ok":false,"sessions":[]}' > "$WORK/sessions.json"; r=$(run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ "$(writes)" = 0 ] && ok "envelope ok:false → mini" || bad "envelope ok:false deu '$r'"
reset; sess; r=$(ND_SLOW=1 run_nd)
[ "$r" = "res=mini alias= slow=1" ] && [ "$(writes)" = 0 ] && ok "orçamento de spawn lento do sweep já gasto → mini sem tentar (uma sessão lenta por sweep)" || bad "orçamento gasto deu '$r' writes=$(writes)"

echo "── o caminho feliz: atribuir → abrir a sessão → avisar"
reset; sess; r=$(run_nd)
la=$(nline 'bd -C .* update story-1 --assignee dog-remote-1 --status in_progress'); ln=$(nline 'gc --city .* session new dog-remote --alias dog-remote-1 --no-attach'); lw=$(nline 'gc --city .* session nudge dog-remote-1')
[ "$r" = "res=node alias=dog-remote-1 slow=0" ] && [ "$(assignee)" = dog-remote-1 ] && [ "$(bstatus)" = in_progress ] && ok "bead fica atribuída ao alias e em in_progress" || bad "estado final errado: '$r' assignee=$(assignee) status=$(bstatus)"
[ -n "$la" ] && [ -n "$ln" ] && [ -n "$lw" ] && [ "$la" -lt "$ln" ] && [ "$ln" -lt "$lw" ] && ok "ordem: atribuir (l.$la) → sessão (l.$ln) → aviso (l.$lw): a sessão já nasce com a bead atribuída" || bad "ordem errada ou passo ausente (assign=$la new=$ln nudge=$lw)"
grep -q "gc --city $WORK/city session new dog-remote .*--title-hint build story-1: Título da bead" "$CALLS" && ok "a sessão leva o título da bead (title-hint)" || bad "title-hint ausente: $(grep 'session new' "$CALLS")"
grep -q "gc --city .* session nudge dog-remote-1 .*story-1" "$CALLS" && grep -q 'GC_ALIAS' "$CALLS" && ok "o aviso nomeia a bead e diz como achá-la pelo GC_ALIAS (o atalho recusa bd update --claim)" || bad "aviso sem a bead ou sem o GC_ALIAS"
[ "$(ncalls 'session close')" = 0 ] && ok "no caminho feliz nada é fechado nem desfeito" || bad "caminho feliz fechou sessão"
grep -q "LOG.*dog-remote-1" "$LINES" && ok "o log diz o alias" || bad "log sem o alias"

echo "── falha em qualquer passo: desfaz, fecha o que abriu e a bead segue no mini"
reset; sess; setrc bd.assign.rc 1; r=$(run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ -z "$(assignee)" ] && [ "$(bstatus)" = open ] && [ "$(ncalls 'session new')" = 0 ] && [ "$(ncalls 'session nudge')" = 0 ] \
  && ok "atribuição falha: nenhuma sessão aberta, nenhum aviso, bead sem dono e aberta → mini" || bad "atribuição falhando: '$r' assignee=$(assignee) status=$(bstatus)"
reset; sess; setrc bd.assign.rc 1; touch "$WORK/bd.assign.partial"; r=$(run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ -z "$(assignee)" ] && [ "$(bstatus)" = open ] && [ "$(ncalls 'session new')" = 0 ] && ok "atribuição que estourou o prazo DEPOIS de gravar (rc≠0 mas aplicada): é desfeita → mini" || bad "atribuição parcial ficou: '$r' assignee=$(assignee) status=$(bstatus)"
reset; sess; setrc gc.new.rc 1; r=$(run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ -z "$(assignee)" ] && [ "$(bstatus)" = open ] && [ "$(ncalls 'session nudge')" = 0 ] && [ "$(ncalls 'session close dog-remote-1')" = 1 ] \
  && ok "sessão não abre: bead devolvida (sem dono, aberta), sessão fechada por precaução, sem aviso → mini" || bad "falha ao abrir: '$r' assignee=$(assignee) status=$(bstatus) close=$(ncalls 'session close')"
reset; sess; setrc gc.new.rc 124; r=$(run_nd)
[ "$r" = "res=mini alias= slow=1" ] && [ -z "$(assignee)" ] && [ "$(ncalls 'session close dog-remote-1')" = 1 ] && ok "sessão estoura o prazo (rc 124): a sessão PODE ter nascido → é fechada, a bead volta, e o sweep gasta o orçamento de spawn lento" || bad "prazo da sessão: '$r' assignee=$(assignee) close=$(ncalls 'session close')"
reset; sess dog-remote-1:asleep; setrc gc.wake.rc 1; r=$(ND_EFF=1 run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ -z "$(assignee)" ] && [ "$(bstatus)" = open ] && ok "o wake falha: mesmo desfazer → mini" || bad "wake falhando: '$r' assignee=$(assignee) status=$(bstatus)"
reset; sess; setrc gc.nudge.rc 1; r=$(run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ -z "$(assignee)" ] && [ "$(bstatus)" = open ] && [ "$(ncalls 'session close dog-remote-1')" = 1 ] \
  && ok "o aviso falha: a sessão já existe — é FECHADA antes de soltar a bead (senão ela a acharia e o mini a construiria também) → mini" || bad "aviso falhando: '$r' assignee=$(assignee) status=$(bstatus) close=$(ncalls 'session close')"
reset; sess; setrc gc.nudge.rc 1; l=$(nline 'x'); r=$(run_nd)
lc=$(nline 'gc --city .* session close dog-remote-1'); lu=$(nline 'bd -C .* update story-1 --if-assignee dog-remote-1')
[ -n "$lc" ] && [ -n "$lu" ] && [ "$lc" -lt "$lu" ] && ok "o desfazer fecha a sessão ANTES de tirar a atribuição (l.$lc < l.$lu)" || bad "ordem do desfazer errada (close=$lc unassign=$lu)"
reset; sess; setrc gc.nudge.rc 1; setrc gc.close.rc 1; r=$(run_nd)
[ "$r" = "res=mini alias= slow=0" ] && [ -z "$(assignee)" ] && grep -q "WARN.*não consegui fechar a sessão dog-remote-1" "$LINES" && ok "o close falha: avisa alto e ainda assim solta a bead (a bead nunca fica presa no nó)" || bad "close falhando: '$r' assignee=$(assignee) avisos=$(grep WARN "$LINES" | tr '\n' '|')"
reset; sess; setrc gc.new.rc 1; r=$(run_nd); [ "$(ncalls 'update story-1 --if-assignee dog-remote-1')" -ge 1 ] && ok "o desfazer usa --if-assignee: só solta se o dono ainda é o alias" || bad "desfazer sem --if-assignee"
reset; sess; setrc gc.new.rc 1; printf 'outro-dog' > "$WORK/bead.assignee"; setrc bd.assign.rc 1   # a atribuição não pegou e OUTRO ator já é o dono
r=$(run_nd); [ "$r" = "res=stuck alias=dog-remote-1 slow=0" ] && [ "$(assignee)" = outro-dog ] && ok "bead que já é de outro: o desfazer NÃO a pisa (--if-assignee) e a função diz stuck — não manda ao mini" || bad "dono alheio: '$r' assignee=$(assignee)"

echo "── desfazer que não se confirma: stuck (nunca mini)"
reset; sess; setrc gc.new.rc 1; setrc bd.unassign.rc 1; r=$(run_nd)
[ "$r" = "res=stuck alias=dog-remote-1 slow=0" ] && [ "$(assignee)" = dog-remote-1 ] && ok "não consegui tirar a atribuição: stuck — mandar ao mini agora deixaria o alias e o mini com a mesma bead" || bad "desfazer falho virou '$r'"
reset; sess; setrc gc.new.rc 1; setrc bd.show.rc 1; r=$(run_nd)
[ "$r" = "res=stuck alias=dog-remote-1 slow=0" ] && ok "não consegui reler a bead para confirmar o desfazer: stuck (falhou/ilegível ≠ confirmado)" || bad "releitura falha virou '$r'"
reset; sess; setrc gc.new.rc 1; touch "$WORK/bd.keepstatus"; r=$(run_nd)
[ "$r" = "res=stuck alias=dog-remote-1 slow=0" ] && [ -z "$(assignee)" ] && [ "$(bstatus)" = in_progress ] && ok "o dono saiu mas a bead continua em_progress na releitura: o estado de antes é open+sem dono, então stuck (a confirmação lê o estado inteiro)" || bad "status que não volta virou '$r' status=$(bstatus)"
grep -q "WARN.*desfazer.*dog-remote-1" "$LINES" && ok "stuck vem com aviso que nomeia a bead e o alias" || bad "stuck sem aviso"

echo "── a chamada no dispatch_one"
l_shadow=$(grep -n '^  _pilot_node_first_shadow "\$STORY_ID"' "$DISPATCHER" | head -1 | cut -d: -f1)
ncall=$(grep -c '_pilot_node_first_dispatch "\$STORY_ID" "\$STORY_BEAD_CITY" "\$STORY_TITLE" "\${_PNF_EFFECTIVE:-}"' "$DISPATCHER")
l_call=$(grep -n '_pilot_node_first_dispatch "\$STORY_ID" "\$STORY_BEAD_CITY" "\$STORY_TITLE" "\${_PNF_EFFECTIVE:-}"' "$DISPATCHER" | head -1 | cut -d: -f1)
l_gate=$(awk -v c="${l_call:-0}" 'NR<c && /^  if \[ "\$DRY_RUN" != "1" \] && \[ "\$PILOT_NODE_FIRST" = "on" \] && \[ "\${_PNF_VERDICT:-}" = "node" \]; then$/ {n=NR} END{print n}' "$DISPATCHER")
l_dry=$(awk -v c="${l_call:-0}" 'NR>c && /^  if \[ "\$DRY_RUN" = "1" \]; then$/ {print NR; exit}' "$DISPATCHER")
[ "$ncall" = 1 ] && ok "o desvio ao nó é chamado UMA vez no dispatch_one" || bad "chamadas a _pilot_node_first_dispatch com os argumentos esperados: $ncall"
[ -n "$l_gate" ] && [ -n "$l_call" ] && [ -n "$l_shadow" ] && [ "$l_gate" -lt "$l_call" ] && [ "$l_call" -gt "$l_shadow" ] && ok "e só sob 'DRY_RUN != 1 && PILOT_NODE_FIRST = on && veredito = node' (l.$l_gate), depois da consulta (l.$l_shadow)" || bad "a guarda tripla do desvio não existe ou está fora de ordem (gate=$l_gate call=$l_call shadow=$l_shadow)"
[ -n "$l_dry" ] && ok "e antes do bloco de despacho (DRY_RUN/sling em l.$l_dry)" || bad "não achei o bloco de despacho depois do desvio"
grep -q '^  elif \[ "\${_PNF_RESULT:-}" = "node" \]; then$' "$DISPATCHER" && ok "a cadeia de despacho tem o ramo do nó (elif _PNF_RESULT = node), antes do rig-native" || bad "o ramo do nó não existe na cadeia"
l_elif=$(grep -n '^  elif \[ "\${_PNF_RESULT:-}" = "node" \]; then$' "$DISPATCHER" | head -1 | cut -d: -f1)
l_rig=$(grep -n '^  elif \[ "\$_IS_RIG_NATIVE" = "1" \]; then$' "$DISPATCHER" | head -1 | cut -d: -f1)
[ -n "$l_elif" ] && [ -n "$l_rig" ] && [ "$l_elif" -lt "$l_rig" ] && ok "o ramo do nó vem antes do ramo rig-native (l.$l_elif < l.$l_rig)" || bad "ordem dos ramos errada ($l_elif / $l_rig)"
awk -v c="${l_call:-0}" 'NR>c && NR<c+14' "$DISPATCHER" | grep -q '^    if \[ "\$_PNF_RESULT" = "stuck" \]; then$' && awk -v c="${l_call:-0}" 'NR>c && NR<c+14' "$DISPATCHER" | grep -q 'DISPATCH_RESULT="node_rollback_unconfirmed"' && awk -v c="${l_call:-0}" 'NR>c && NR<c+14' "$DISPATCHER" | grep -q 'return 1' \
  && ok "stuck: o dispatch_one aborta com node_rollback_unconfirmed e NÃO segue para o mini" || bad "o tratamento do stuck no dispatch_one não existe"
grep -q 'DISPATCH_RESULT="node_ok"' "$DISPATCHER" && ok "o resultado do despacho ao nó é node_ok" || bad "DISPATCH_RESULT=node_ok ausente"

echo "── o alias remoto conta como construtor vivo (guarda de reclaim, dono ativo)"
# Sem código novo de vivacidade: o alias dog-remote-<n> já casa com id/name/session_name/alias/agent_name. Aqui só se trava isso, para uma mudança futura nos preditos não soltar a bead de um nó vivo.
# Só caminhos sem I/O (sem peek de painel): sessão ativa com last_active fresco, e dormindo.
cat > "$WORK/liveness.py" <<'LIVEPY'
import sys, time, importlib.util
from datetime import datetime, timezone
sys.path.insert(0, sys.argv[1])
import bead_state as bs
spec = importlib.util.spec_from_file_location("inflight_reclaim_guard", sys.argv[1] + "/inflight-reclaim-guard.py")
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
now = time.time()
fresh = datetime.fromtimestamp(now - 30, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
act = {"id": "ga-xyz", "alias": "dog-remote-2", "template": "dog-remote", "state": "active", "last_active": fresh}
slp = dict(act, state="asleep")
print("guard_live=%s" % g.session_is_live("dog-remote-2", [act], now=now))
print("guard_other=%s" % g.session_is_live("dog-remote-3", [act], now=now))
print("guard_asleep=%s" % g.session_is_live("dog-remote-2", [slp], now=now))
print("owner_active=%s" % bs.is_active_owner("dog-remote-2", {"dog-remote-2": {"state": "active", "idle_minutes": 1}}))
print("owner_asleep=%s" % bs.is_active_owner("dog-remote-2", {"dog-remote-2": {"state": "asleep", "idle_minutes": None}}))
print("holder_10_not_1=%s" % bs.holder_is_alive("dog-remote-1", {"dog-remote-10": {"state": "active", "idle_minutes": 1}}))
LIVEPY
lv=$(python3 -I "$WORK/liveness.py" "$SELF_DIR/../../../scripts" 2>&1) || lv="${lv:-python falhou}"
for kv in guard_live=True guard_other=False guard_asleep=False owner_active=True owner_asleep=False holder_10_not_1=False; do
  if printf '%s\n' "$lv" | grep -qx "$kv"; then ok "liveness: $kv"; else bad "liveness: esperava $kv, saída: $(printf '%s' "$lv" | tr '\n' ' ')"; fi
done

if [ -n "${ND_MUTANT:-}" ]; then echo "RESULT $FAIL/$((PASS+FAIL))"; [ "$FAIL" = 0 ]; exit $?; fi
if [ -z "${ND_NO_MUTANTS:-}" ]; then
  echo "── controle negativo: cada mutante tem que reprovar a bateria"
  nm=0
  # 4º argumento (opcional): a função onde a âncora vale. O _pilot_node_remote_rollback (ga-2hd02v.3.3) é quase cópia do _pilot_node_first_rollback; sem o escopo a âncora casa 2x e o mutante some sem testar nada.
  # Função ausente ou repetida (exit 4), ou âncora que não casa exatamente 1 vez DENTRO dela (exit 3) → o mutante reprova a bateria; nunca um mutante que não mudou nada passa por "pego".
  mutant() {  # mutant DESCRIÇÃO ANTES DEPOIS [FUNÇÃO]
    nm=$((nm+1)); local m="$WORK/disp.mut$nm.sh"
    python3 -I -c 'import sys
s=open(sys.argv[1],encoding="utf-8").read()
a,b=0,len(s)
if sys.argv[5]:
    d=sys.argv[5]+"() {\n"
    if s.count(d)!=1: sys.exit(4)
    a=s.index(d); b=s.find("\n}\n",a)
    if b<0: sys.exit(4)
    b+=3
r=s[a:b]
if r.count(sys.argv[2])!=1: sys.exit(3)
open(sys.argv[4],"w",encoding="utf-8").write(s[:a]+r.replace(sys.argv[2],sys.argv[3])+s[b:])' "$DISPATCHER" "$2" "$3" "$m" "${4:-}" 2>/dev/null \
      || { bad "mutante '$1': a âncora não casa exatamente 1 vez${4:+ em $4}"; return; }
    local r; r=$(ND_MUTANT=1 PILOT_DISPATCHER_PATH="$m" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) bad "mutante '$1' NÃO foi pego ($r)" ;; "RESULT "*) ok "mutante '$1' pego ($r)" ;; *) bad "mutante '$1': sem resultado ($r)" ;; esac
  }
  export PATH_ORIG="$PATH"
  # a falha vira nó: o desfazer deu certo mas o resultado diz node (a bead ficaria presa num nó que não abriu)
  mutant "falha vira node" $'      _PNF_RESULT="mini"; _PNF_ALIAS=""\n    else' $'      _PNF_RESULT="node"; _PNF_ALIAS="$_nd_alias"\n    else'
  # o claim não é solto no erro: a escrita guardada de soltura some
  mutant "claim não solto no erro" 'timeout 15 bd -C "$_rb_city" update "$_rb_id" --if-assignee "$_rb_alias" --assignee "" --status open -q >/dev/null 2>&1 || true' 'true'
  # a soltura perde a guarda --if-assignee (pisaria em quem pegou a bead depois)
  mutant "soltura sem --if-assignee" '--if-assignee "$_rb_alias" --assignee "" --status open' '--assignee "" --status open' _pilot_node_first_rollback
  # alias acima de effective
  mutant "alias > effective" 'range(1; $eff + 1)' 'range(1; $eff + 2)'
  # lista de sessões ilegível lida como vazia (escolheria dog-remote-1 às cegas)
  mutant "lista ilegível = vazia" 'session list --json) || return 1' 'session list --json) || _pk_json='"'"'{"sessions":[]}'"'"
  # JSON sem o array .sessions lido como "zero sessões"
  mutant "sem .sessions = vazio" $'  printf \'%s\' "$_pk_json" | jq -e \'.sessions | type == "array"\' >/dev/null 2>&1 || return 1\n' ''
  # as vagas deixam de contar por template
  mutant "vagas não contadas" '[$live[] | select(.template == "dog-remote" and .state != "asleep")] | length) as $occ' '[$live[] | select(false)] | length) as $occ'
  # alias preso por sessão de outro template é escolhido se ela dorme
  mutant "alias de outro template" '($h | all(.template == "dog-remote" and .state == "asleep"))' '($h | all(.state == "asleep"))'
  # alias dormindo: cria outra sessão em vez de acordar
  mutant "asleep não acorda" 'if [ "$_nd_state" = "asleep" ]; then' 'if false; then'
  # a atribuição que falha segue adiante
  mutant "atribuição falha e segue" '[ "$_nd_rc" -eq 0 ] || _nd_step="a atribuição falhou (rc=$_nd_rc)"' ':'
  # a bead não vai a in_progress
  mutant "atribui sem in_progress" 'update "$_nd_id" --assignee "$_nd_alias" --status in_progress -q' 'update "$_nd_id" --assignee "$_nd_alias" -q'
  # a sessão que não abre segue adiante
  mutant "sessão não abre e segue" '    if [ "$_nd_rc" -ne 0 ]; then
      _nd_step="a sessão ($_nd_state) não abriu (rc=$_nd_rc)"' '    if false; then
      _nd_step="a sessão ($_nd_state) não abriu (rc=$_nd_rc)"'
  # o aviso que falha não desfaz
  mutant "aviso falha sem desfazer" '[ "$_nd_rc" -eq 0 ] || _nd_step="o aviso falhou (rc=$_nd_rc)"' ':'
  # o desfazer não fecha a sessão
  mutant "sessão não fechada no desfazer" $'    timeout 20 gc --city "$GC_CITY" session close "$_rb_alias" >/dev/null 2>&1 \\\n' $'    true \\\n' _pilot_node_first_rollback
  # desfazer não confirmado (bead ilegível) devolvido como limpo
  mutant "ilegível = confirmado" $'NÃO mando a bead ao mini; o claim fica para o TTL"\n    return 1' $'NÃO mando a bead ao mini; o claim fica para o TTL"\n    return 0' _pilot_node_first_rollback
  # desfazer não confirmado (bead com outro dono) devolvido como limpo
  mutant "outro dono = confirmado" $'o claim fica para o TTL"\n  return 1\n}' $'o claim fica para o TTL"\n  return 0\n}' _pilot_node_first_rollback
  # status que não volta a open aceito como confirmado
  mutant "status não volta = confirmado" 'if [ -z "$_rb_asg" ] && [ "$_rb_st" = "open" ]; then return 0; fi' 'if [ -z "$_rb_asg" ]; then return 0; fi'
  # o orçamento de spawn do sweep é ignorado
  mutant "orçamento de spawn ignorado" '  if _pilot_slow_spawn_budget_spent; then
    log "  node-first (on): $_nd_id fica no mini' '  if false; then
    log "  node-first (on): $_nd_id fica no mini'
  # o stuck deixa de abortar o dispatch_one (seguiria para o mini)
  mutant "stuck segue para o mini" 'if [ "$_PNF_RESULT" = "stuck" ]; then' 'if false; then'
  # o desvio ao nó sem a guarda de DRY_RUN
  mutant "desvio sem guarda DRY_RUN" 'if [ "$DRY_RUN" != "1" ] && [ "$PILOT_NODE_FIRST" = "on" ] && [ "${_PNF_VERDICT:-}" = "node" ]; then' 'if [ "$PILOT_NODE_FIRST" = "on" ] && [ "${_PNF_VERDICT:-}" = "node" ]; then'
  # o desvio ao nó dispara também em shadow
  mutant "desvio em shadow" 'if [ "$DRY_RUN" != "1" ] && [ "$PILOT_NODE_FIRST" = "on" ] && [ "${_PNF_VERDICT:-}" = "node" ]; then' 'if [ "$DRY_RUN" != "1" ] && [ "$PILOT_NODE_FIRST" != "off" ] && [ "${_PNF_VERDICT:-}" = "node" ]; then'
fi
echo "── $PASS ok, $FAIL falhas"
[ "$FAIL" = 0 ]
