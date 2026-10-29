#!/usr/bin/env bash
# pilot-dispatcher.kimi-lane.selftest.sh — ga-do1ixn.3 (a faixa Kimi: bead lane:kimi vai SÓ ao kimi-worker-remote, e o kimi-worker-remote só recebe lane:kimi)
#
# Contents
#   O que prova · Como roda · Controle negativo
#
# O QUE PROVA: (passada) toda bead lane:kimi sai das duas pistas antes do laço normal, com a faixa aberta ou fechada — a pista normal nunca a vê; a que não tem o rótulo fica onde estava e a
#   passada nunca a entrega a dispatch_one; pista ilegível fica vazia; a bead do HQ ganha gc.routed_to=kimi-lane (só se ainda não o tem; nunca no DRY_RUN); sem a bandeira .gc/kimi-lane.on, ou
#   com o nó desligado, nada é despachado (fechada:off / fechada:node-off); aberta, UMA bead do HQ vai a dispatch_one com _PILOT_KIMI_PASS=1, a de outro rig espera; sem vaga a passada para.
#   (despacho) o alias é kimi-worker-remote-1; sessão do kimi ativa = sem vaga, sem escrita; sessões do dog-remote não ocupam a vaga do Kimi; dormindo = acorda; lista ilegível = sem vaga; sessão
#   que não abre ou aviso que falha desfazem a atribuição. (dispatch_one, leitura do código) na faixa o nó primeiro não é consultado; o bloco do Kimi vem depois do nó primeiro e antes do despacho
#   do mini, e o que não foi ao kimi-worker-remote sai com kimi_lane_wait — nunca segue para o mini. (gate) o FAIL devolve a bead lane:kimi para kimi-lane, não para gastown.dog.
#   (triagem, unidade) _pilot_kimi_screen: ok · veto:<rótulo> (node:never, needs:engine-window, exec:manual; token inteiro) · pii:<termo> para cada termo da lista do Mayor, sem caixa, sem acento (NFC e NFD)
#   e por palavra inteira ("leader", "chipset" não casam) · sem-texto · ilegivel. (triagem, passada) a bead do HQ com veto ou dado pessoal é REBAIXADA (tira lane:kimi; gc.routed_to kimi-lane → gastown.dog;
#   comentário com o NOME do termo, nunca o trecho) e não é despachada, com a faixa aberta ou fechada, e nada se escreve no DRY_RUN; a que não tem texto ou não se lê espera (carimbada, sem despachar);
#   rebaixamento que não grava deixa a bead esperando; a de outro rig não é triada.
# COMO RODA: as funções são extraídas VERBATIM dos dispatchers (awk) e rodam num shell filho sob `set -euo pipefail`, com `gc` e `bd` FALSOS num PATH sem os reais; dispatch_one é um falso que
#   registra o que recebeu. Contra um dispatcher sem as funções o arquivo se recusa a começar.
# CONTROLE NEGATIVO: cada mutante (pista que não separa as do Kimi, bandeira ignorada, bead de outro rig aceita, vaga que conta todo template, bloco do Kimi que cai no mini, gate que restaura dog,
#   veto ignorado, cada termo da lista ignorado, termo sem fronteira de palavra, sem-texto/ilegível que passa, rebaixamento que não tira o rótulo/a rota/escreve no DRY_RUN) é aplicado numa cópia e a
#   bateria tem de reprovar.
# Variáveis: PILOT_DISPATCHER_PATH · GATE_DISPATCHER_PATH · KL_NO_MUTANTS=1
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
GATE="${GATE_DISPATCHER_PATH:-$SELF_DIR/quality-gate-dispatcher.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ -n "${KL_MUTANT:-}" ] || echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; }
[ -f "$DISPATCHER" ] && [ -f "$GATE" ] || { echo "FATAL: dispatcher not found ($DISPATCHER / $GATE)" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source selftest-sandbox-path.lib.sh" >&2; exit 2; }

fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$2"; }
FUNCS=""
for f in gc_json_or_unknown _pilot_slow_spawn_budget_spent _pilot_note_spawn_timing _pilot_node_first_rollback _pilot_node_first_veto _pilot_kimi_lane_closed _pilot_kimi_pick_alias _pilot_kimi_dispatch _pilot_kimi_screen _pilot_kimi_demote _pilot_kimi_lane_pass; do
  src="$(fn_src "$f" "$DISPATCHER")"
  [ -n "$src" ] || { echo "FATAL: $f() not found in $DISPATCHER (ga-do1ixn.3 not applied)" >&2; exit 2; }
  FUNCS="$FUNCS
$src"
done
GFUNC="$(fn_src gate_kimi_lane_route "$GATE")"
[ -n "$GFUNC" ] || { echo "FATAL: gate_kimi_lane_route() not found in $GATE" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-kimilane-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/city/.gc"
# gc FALSO: `gc --city C session <sub>`. rc de cada subcomando em $WORK/gc.<sub>.rc (padrão 0); `list` imprime $WORK/sessions.json.
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
# bd FALSO: uma bead (assignee/status em arquivo; honra --if-assignee). Registra toda chamada.
cat > "$WORK/bin/bd" <<'EOF'
#!/bin/sh
W="${SELFTEST_WORK:?}"
echo "bd $*" >> "$W/calls.log"
[ "$1" = "-C" ] || exit 99
# $W/bd.fail.on: texto que, se aparece na linha de comando, faz a chamada falhar (rc 1)
if [ -f "$W/bd.fail.on" ]; then case " $* " in *"$(cat "$W/bd.fail.on")"*) exit 1 ;; esac; fi
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
    if [ "$have_a" = 1 ]; then printf '%s' "$a_new" > "$W/bead.assignee"; [ -z "$st" ] || printf '%s' "$st" > "$W/bead.status"; fi
    exit 0 ;;
  show) s=open; [ ! -f "$W/bead.status" ] || s=$(cat "$W/bead.status")
        printf '[{"id":"%s","assignee":"%s","status":"%s"}]\n' "$4" "$(cur)" "$s"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/gc" "$WORK/bin/bd"
sandbox_path_init "$WORK" jq date timeout mkdir dirname cat sleep head || exit 2

CALLS="$WORK/calls.log"; LINES="$WORK/lines.txt"; DCALLS="$WORK/dispatch.log"
reset() { rm -f "$WORK"/gc.*.rc "$WORK"/sessions.json "$WORK"/bead.assignee "$WORK"/bead.status "$WORK"/bd.fail.on "$CALLS" "$LINES" "$DCALLS" "$WORK"/city/.gc/*.on; echo open > "$WORK/bead.status"; }
sess() { # sess alias:state[:template] ... → sessions.json
  local a j='[]' al st tp
  for a in "$@"; do
    IFS=: read -r al st tp <<<"$a"
    j=$(jq -c --arg al "$al" --arg st "$st" --arg tp "${tp:-kimi-worker-remote}" '. + [{id:("ga-" + $al), name:$al, alias:$al, template:$tp, state:$st, closed:false}]' <<<"$j")
  done
  printf '{"sessions":%s}\n' "$j" > "$WORK/sessions.json"
}
on()  { : > "$WORK/city/.gc/kimi-lane.on"; : > "$WORK/city/.gc/hetzner-node.on"; }
writes() { grep -v 'session list' "$CALLS" 2>/dev/null | grep -vc '^bd .* show ' || true; }
b() { # b id labels_csv [route] [descrição] → um objeto de candidata (descrição limpa por padrão; "" = vazia)
  jq -cn --arg id "$1" --arg l "$2" --arg r "${3:-}" --arg d "${4-Mexe só no script do gate e no selftest.}" '{id:$id, title:("t " + $id), description:$d, priority:2, labels:($l | split(",") | map(select(length > 0))), metadata:(if $r == "" then {} else {"gc.routed_to":$r} end)}'
}

# run_pass SMALL_JSON BIG_JSON — a passada num filho; imprime "small=<ids> big=<ids> dispatched=<n>". KL_DRC = rc do dispatch_one falso; KL_DRES = o DISPATCH_RESULT dele.
run_pass() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    log()  { echo "LOG $*" >> "$LINES"; }
    warn() { echo "WARN $*" >> "$LINES"; }
    _top_candidate() { printf '%s' "$1" | jq -c '.[0] // empty'; }
    _bead_tier() { echo story; }
    _dolt_saturated() { return 1; }
    _pilot_sweep_note() { :; }
    dispatch_one() { echo "$(printf '%s' "$1" | jq -r .id) lane=$2 kimi=${_PILOT_KIMI_PASS:-0}" >> "$DCALLS"; DISPATCH_RESULT="${KL_DRES:-node_ok}"; return "${KL_DRC:-0}"; }
    GC_CITY="$WORK/city"; PILOT_KIMI_LANE_FLAG="$GC_CITY/.gc/kimi-lane.on"; PILOT_KIMI_NODE_FLAG="$GC_CITY/.gc/hetzner-node.on"
    PILOT_KIMI_TEMPLATE="kimi-worker-remote"; PILOT_KIMI_ROUTE="kimi-lane"; DRY_RUN="${KL_DRY:-0}"; DISPATCHED=0
    PILOT_NODE_FIRST_VETO_LABELS="node:never needs:engine-window exec:manual"
    SMALL_CANDIDATES="$1"; BIG_CANDIDATES="$2"; SMALL_COUNT=0; BIG_COUNT=0
    eval "$FUNCS"
    _pilot_kimi_lane_pass
    echo "small=$(printf '%s' "$SMALL_CANDIDATES" | jq -r '[.[].id] | join(",")' 2>/dev/null) big=$(printf '%s' "$BIG_CANDIDATES" | jq -r '[.[].id] | join(",")' 2>/dev/null) n=$SMALL_COUNT/$BIG_COUNT dispatched=$DISPATCHED"
  ) 2>&1 | tail -1
}
# run_kd — _pilot_kimi_dispatch num filho; imprime "res=<..> alias=<..>"
run_kd() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    log()  { echo "LOG $*" >> "$LINES"; }
    warn() { echo "WARN $*" >> "$LINES"; }
    GC_CITY="$WORK/city"; PILOT_SPAWN_TIMEOUT_SECS=20; PILOT_KIMI_TEMPLATE="kimi-worker-remote"; _PILOT_SLOW_SPAWN_SEEN=0
    eval "$FUNCS"
    _pilot_kimi_dispatch "ga-k1" "$WORK/city" "Título"
    echo "res=${_PNF_RESULT-?} alias=${_PNF_ALIAS-?}"
  ) 2>&1 | tail -1
}

K1=$(b ga-k1 "lane:kimi,story:approved"); K2=$(b ga-k2 "lane:kimi" kimi-lane); KW=$(b wa-k3 "lane:kimi" wa-worker); N1=$(b ga-n1 "story:approved"); N2=$(b ga-n2 "lane:kimi-not")
echo "── passada: as beads lane:kimi saem das pistas, abertas ou fechadas"
reset; r=$(run_pass "[$K1,$N1,$KW]" "[$N2,$K2]")
[ "$r" = "small=ga-n1 big=ga-n2 n=1/1 dispatched=0" ] && ok "faixa fechada: as 3 lane:kimi saem das pistas; ga-n1 e ga-n2 (lane:kimi-not) ficam; COUNT recontado ($r)" || bad "pistas depois da passada fechada: '$r'"
[ ! -s "$DCALLS" ] && grep -q 'fechada:off' "$LINES" && ok "sem .gc/kimi-lane.on: nenhuma vai a dispatch_one e o log diz fechada:off" || bad "faixa sem bandeira despachou ou não disse: $(cat "$DCALLS" 2>/dev/null) / $(grep -h 'faixa Kimi' "$LINES" 2>/dev/null)"
grep -q 'update ga-k1 --set-metadata gc.routed_to=kimi-lane' "$CALLS" && ok "a bead do HQ sem a rota de espera ganha gc.routed_to=kimi-lane" || bad "ga-k1 não foi carimbada: $(cat "$CALLS" 2>/dev/null)"
! grep -q 'update ga-k2 ' "$CALLS" && ! grep -q 'update wa-k3 ' "$CALLS" && ! grep -q 'update ga-n' "$CALLS" && ok "nada é escrito na que já tem kimi-lane, na de outro rig nem nas que não são lane:kimi" || bad "escritas indevidas: $(cat "$CALLS")"
reset; : > "$WORK/city/.gc/kimi-lane.on"; r=$(run_pass "[$K1]" "[]")
[ ! -s "$DCALLS" ] && grep -q 'fechada:node-off' "$LINES" && [ "$r" = "small= big= n=0/0 dispatched=0" ] && ok "bandeira ligada mas o nó desligado: espera (fechada:node-off), e a bead continua fora da pista" || bad "nó desligado: '$r' $(cat "$DCALLS" 2>/dev/null)"
echo "── passada aberta: uma bead do HQ, com a bandeira da faixa"
reset; on; r=$(run_pass "[$KW,$N1]" "[$K1,$K2]")
[ "$(cat "$DCALLS" 2>/dev/null)" = "ga-k1 lane=big kimi=1" ] && [ "$r" = "small=ga-n1 big= n=1/0 dispatched=1" ] && ok "aberta: só ga-k1 vai a dispatch_one, com _PILOT_KIMI_PASS=1; wa-k3 (outro rig) espera; ga-n1 fica na pista" || bad "aberta: '$r' / $(cat "$DCALLS" 2>/dev/null)"
grep -q 'wa-k3 espera' "$LINES" && ok "a bead de outro rig é registrada como em espera (semana 1: só HQ)" || bad "sem registro da espera de wa-k3"
reset; on; r=$(KL_DRC=1 KL_DRES=kimi_lane_wait run_pass "[$K1,$K2]" "[]")
[ "$(grep -c . "$DCALLS")" = 1 ] && [ "$r" = "small= big= n=0/0 dispatched=0" ] && ok "sem vaga (kimi_lane_wait): para na 1ª, não tenta a 2ª, e nenhuma volta à pista" || bad "sem vaga: '$r' / $(cat "$DCALLS" 2>/dev/null)"
reset; on; r=$(KL_DRY=1 run_pass "[$K1]" "[]")
[ ! -s "$DCALLS" ] && [ "$(writes)" = 0 ] && grep -q 'dry-run' "$LINES" && ok "DRY_RUN: nem carimbo nem despacho" || bad "DRY_RUN escreveu ou despachou: $(cat "$CALLS" "$DCALLS" 2>/dev/null)"
reset; on; r=$(run_pass 'isto-nao-e-json' "[$N1]")
[ "$r" = "small= big=ga-n1 n=0/1 dispatched=0" ] && grep -q 'WARN ga-do1ixn.3: a pista small' "$LINES" && ok "pista ilegível fica vazia nesta varredura (com aviso); a outra segue" || bad "pista ilegível: '$r'"
reset; on; r=$(run_pass "[$N1]" "[]")
[ "$r" = "small=ga-n1 big= n=1/0 dispatched=0" ] && [ ! -s "$DCALLS" ] && [ ! -s "$LINES" ] && ok "sem lane:kimi: a passada não muda nada nem fala" || bad "sem lane:kimi: '$r' / $(cat "$LINES" 2>/dev/null)"

echo "── despacho: kimi-worker-remote-1, ou espera"
reset; sess; r=$(run_kd)
[ "$r" = "res=node alias=kimi-worker-remote-1" ] && grep -q 'session new kimi-worker-remote --alias kimi-worker-remote-1 --no-attach' "$CALLS" && [ "$(cat "$WORK/bead.assignee")" = kimi-worker-remote-1 ] && ok "sem sessão: atribui a kimi-worker-remote-1 e abre o template do Kimi" || bad "sem sessão: '$r' $(cat "$CALLS")"
reset; sess dog-remote-1:active:dog-remote dog-remote-2:active:dog-remote; r=$(run_kd)
[ "$r" = "res=node alias=kimi-worker-remote-1" ] && ok "sessões do dog-remote não ocupam a vaga do Kimi" || bad "dog-remote ocupou a vaga: '$r'"
reset; sess kimi-worker-remote-1:active; r=$(run_kd)
[ "$r" = "res=mini alias=" ] && [ "$(writes)" = 0 ] && ok "kimi ativo: sem vaga, nada escrito" || bad "kimi ativo: '$r' writes=$(writes)"
reset; sess ":active"; r=$(run_kd)
[ "$r" = "res=mini alias=" ] && [ "$(writes)" = 0 ] && ok "sessão do template do Kimi sem alias também ocupa a vaga" || bad "sessão sem alias: '$r'"
reset; sess kimi-worker-remote-1:asleep; r=$(run_kd)
[ "$r" = "res=node alias=kimi-worker-remote-1" ] && grep -q 'session wake kimi-worker-remote-1' "$CALLS" && ! grep -q 'session new' "$CALLS" && ok "kimi dormindo: acorda em vez de abrir outra" || bad "dormindo: '$r'"
reset; echo 1 > "$WORK/gc.list.rc"; r=$(run_kd)
[ "$r" = "res=mini alias=" ] && [ "$(writes)" = 0 ] && ok "lista de sessões ilegível: sem vaga (nunca 'livre'), nada escrito" || bad "lista ilegível: '$r'"
reset; sess; echo 1 > "$WORK/gc.new.rc"; r=$(run_kd)
[ "$r" = "res=mini alias=" ] && [ -z "$(cat "$WORK/bead.assignee" 2>/dev/null)" ] && [ "$(cat "$WORK/bead.status")" = open ] && ok "sessão que não abre: a atribuição é desfeita (sem dono, open)" || bad "sessão falhou: '$r' assignee=$(cat "$WORK/bead.assignee" 2>/dev/null)"
reset; sess; echo 1 > "$WORK/gc.nudge.rc"; r=$(run_kd)
[ "$r" = "res=mini alias=" ] && grep -q 'session close kimi-worker-remote-1' "$CALLS" && [ -z "$(cat "$WORK/bead.assignee" 2>/dev/null)" ] && ok "aviso que falha: fecha a sessão aberta e desfaz a atribuição" || bad "aviso falhou: '$r'"

echo "── dispatch_one e a varredura (leitura do código)"
D1="$(awk '/^dispatch_one\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
lno() { printf '%s\n' "$D1" | grep -nF -- "$1" | head -1 | cut -d: -f1; }
SH="$(awk '/^_pilot_node_first_shadow\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
l_sh=$(printf '%s\n' "$SH" | grep -nF '[ "${_PILOT_KIMI_PASS:-0}" != "1" ] || return 0' | head -1 | cut -d: -f1); l_sc=$(printf '%s\n' "$SH" | grep -n 'timeout 40 python3 -I "\$PILOT_NODE_CAPACITY_BIN"' | head -1 | cut -d: -f1); l_nf=$(lno '_pilot_node_first_dispatch "$STORY_ID"'); l_kd=$(lno '_pilot_kimi_dispatch "$STORY_ID" "$STORY_BEAD_CITY" "$STORY_TITLE"')
l_wait=$(lno 'DISPATCH_RESULT="kimi_lane_wait"'); l_mini=$(lno '# ── Dispatch via gc sling (HQ beads) or bd assign (rig-native beads)'); l_node=$(lno 'elif [ "${_PNF_RESULT:-}" = "node" ]; then')
{ [ -n "$l_sh" ] && [ -n "$l_sc" ] && [ "$l_sh" -lt "$l_sc" ] && [ "$l_sh" -le 5 ]; } && ok "na faixa o nó primeiro não é consultado: a sombra volta logo no começo, antes de chamar o oráculo" || bad "o nó primeiro roda na faixa Kimi (volta=$l_sh oráculo=$l_sc)"
{ [ -n "$l_kd" ] && [ -n "$l_wait" ] && [ -n "$l_mini" ] && [ -n "$l_node" ] && [ "$l_nf" -lt "$l_kd" ] && [ "$l_kd" -lt "$l_wait" ] && [ "$l_wait" -lt "$l_mini" ] && [ "$l_mini" -lt "$l_node" ]; } \
  && ok "o bloco do Kimi vem depois do nó primeiro e ANTES do despacho do mini; o que não ficou no kimi-worker-remote sai com kimi_lane_wait" || bad "ordem do bloco do Kimi (nf=$l_nf kd=$l_kd wait=$l_wait mini=$l_mini node=$l_node)"
printf '%s\n' "$D1" | sed -n "${l_kd},${l_wait}p" | grep -qF 'if [ "$_PNF_RESULT" != "node" ]; then' && [ "$(printf '%s\n' "$D1" | sed -n "$((l_wait + 1))p")" = "      return 1" ] && ok "o ramo de espera devolve 1 (não segue para o mini)" || bad "o ramo de espera não devolve 1"
lp=$(grep -n '^_pilot_kimi_lane_pass || true$' "$DISPATCHER" | cut -d: -f1); lw=$(grep -n '^_pilot_wa_node_pass || true$' "$DISPATCHER" | cut -d: -f1); ll=$(grep -n '^  dispatch_lane "small"' "$DISPATCHER" | head -1 | cut -d: -f1)
{ [ -n "$lp" ] && [ -n "$lw" ] && [ -n "$ll" ] && [ "$lp" -lt "$lw" ] && [ "$lw" -lt "$ll" ]; } && ok "a passada da faixa roda antes da passada de WA e das pistas" || bad "ordem da varredura (kimi=$lp wa=$lw lane=$ll)"

echo "── gate: o FAIL devolve a bead lane:kimi para a faixa"
gk() { ( eval "$GFUNC"; gate_kimi_lane_route "$1" "$2" ); }
[ "$(gk 'story:approved lane:kimi gate:needs-fix' gastown.dog)" = kimi-lane ] && ok "lane:kimi → kimi-lane (não gastown.dog)" || bad "lane:kimi restaurou '$(gk 'story:approved lane:kimi' gastown.dog)'"
[ "$(gk 'story:approved lane:small' gastown.dog)" = gastown.dog ] && [ "$(gk '' wa-worker)" = wa-worker ] && [ "$(gk 'lane:kimi-not' gastown.dog)" = gastown.dog ] && ok "sem o rótulo exato (ou rótulos ilegíveis) a rota que veio fica" || bad "rota mudou sem lane:kimi"
lr=$(grep -n '_GFAIL_ROUTE=$(gate_kimi_lane_route "${SRC_LABELS:-}" "$_GFAIL_ROUTE")' "$GATE" | cut -d: -f1); lwr=$(grep -n 'update "$BEAD_ID" --set-metadata "gc.routed_to=$_GFAIL_ROUTE"' "$GATE" | head -1 | cut -d: -f1); l0=$(grep -n '_GFAIL_ROUTE=$(gate_fail_restore_route' "$GATE" | cut -d: -f1)
{ [ -n "$lr" ] && [ -n "$lwr" ] && [ -n "$l0" ] && [ "$l0" -lt "$lr" ] && [ "$lr" -lt "$lwr" ]; } && ok "o FAIL aplica a faixa Kimi depois de calcular a rota e antes de gravá-la" || bad "ordem no FAIL (rota=$l0 kimi=$lr escrita=$lwr)"

echo "── triagem (unidade): veto, dado pessoal, sem texto, ilegível"
run_screen() { ( set -euo pipefail; PATH="$SANDBOX_PATH"; PILOT_NODE_FIRST_VETO_LABELS="node:never needs:engine-window exec:manual"; eval "$FUNCS"; _pilot_kimi_screen "$1" ) 2>&1 | tail -1; }
sj() { jq -cn --arg l "$1" --arg t "$2" --arg d "$3" '{id:"ga-s", title:$t, description:$d, labels:($l | split(",") | map(select(length > 0)))}'; }
S() { run_screen "$(sj "$1" "$2" "$3")"; }
r=$(S "lane:kimi,story:approved" "Refatorar o gate" "Mexe só no script do gate e no selftest."); [ "$r" = ok ] && ok "bead limpa: ok" || bad "bead limpa: '$r'"
for v in node:never needs:engine-window exec:manual; do
  r=$(S "lane:kimi,story:approved,$v" "Refatorar o gate" "Texto limpo."); [ "$r" = "veto:$v" ] && ok "rótulo $v: veto:$v" || bad "rótulo $v: '$r'"
done
r=$(S "lane:kimi,node:never-ever" "Refatorar o gate" "Texto limpo."); [ "$r" = ok ] && ok "node:never-ever NÃO é node:never (token inteiro)" || bad "node:never-ever: '$r'"
r=$(S "lane:kimi,node:never" "Importa os leads" "tem CPF"); [ "$r" = "veto:node:never" ] && ok "veto vem antes do texto (a bead devolvida pelo worker é rebaixada pelo rótulo)" || bad "veto antes do texto: '$r'"
while IFS='|' read -r exp text; do
  [ -n "$exp" ] || continue
  r=$(S lane:kimi "Título limpo" "$text"); [ "$r" = "pii:$exp" ] && ok "pii:$exp ← '$text'" || bad "'$text': esperava pii:$exp, veio '$r'"
done <<'EOF'
cpf|o CPF do cliente
cpf|use 123.456.789-09 no teste
telefone|liga pro telefone
telefone|número do celular
telefone|manda no WhatsApp
telefone|usa o whapi
telefone|(11) 98765-4321
conversa|lê a conversa
conversa|histórico de conversas
lead|importa os leads
proprietario|PROPRIETÁRIO do lote
chip/frota|troca o chip
chip/frota|a frota de números
pipedrive|sincroniza com o Pipedrive
email|manda e-mail
email|fulano@exemplo.com.br
dado-pessoal|tem dados pessoais
shared/data|lê shared/data/x
shared/data|abre pessoas.db
EOF
r=$(S lane:kimi "T" "$(printf 'o proprieta\xcc\x81rio do lote')"); [ "$r" = "pii:proprietario" ] && ok "acento decomposto (NFD) também casa" || bad "NFD: '$r'"
r=$(S lane:kimi "Importar leads" "texto limpo"); [ "$r" = "pii:lead" ] && ok "o termo no TÍTULO basta" || bad "título: '$r'"
r=$(run_screen '{"id":"ga-s","title":"t","description":"limpo","notes":"fala do WhatsApp"}'); [ "$r" = "pii:telefone" ] && ok "o termo nas notas também barra" || bad "notas: '$r'"
r=$(S lane:kimi "T" "um leader, um chipset, leadership, conversão de cores, o log do gate"); [ "$r" = ok ] && ok "palavra inteira: leader/chipset/leadership/conversão não casam" || bad "palavra inteira: '$r'"
r=$(run_screen '{"id":"ga-s","title":"t","labels":[]}'); [ "$r" = "sem-texto" ] && ok "sem descrição: sem-texto" || bad "sem descrição: '$r'"
r=$(S lane:kimi "T" "   "); [ "$r" = "sem-texto" ] && ok "descrição só de espaço: sem-texto" || bad "descrição em branco: '$r'"
r=$(S lane:kimi "" "texto"); [ "$r" = "sem-texto" ] && ok "título vazio: sem-texto" || bad "título vazio: '$r'"
for bj in '{"id":"ga-s","title":"t","description":{"a":1}}' '{"id":"ga-s","title":5,"description":"x"}' '{"id":"ga-s","title":"t","description":"x","labels":"lane:kimi"}' '{"id":"ga-s","title":"t","description":"x","labels":[1]}' 'isto-nao-e-json' '[1]'; do
  r=$(run_screen "$bj"); [ "$r" = "ilegivel" ] && ok "ilegivel ← $bj" || bad "$bj: esperava ilegivel, veio '$r'"
done

echo "── triagem (passada): veto/dado pessoal rebaixam; sem texto espera; nada vai ao Kimi sem passar"
V1=$(b ga-v1 "lane:kimi,node:never" kimi-lane); V2=$(b ga-v2 "lane:kimi,exec:manual"); V3=$(b ga-v3 "lane:kimi,node:never-ever" kimi-lane)
P1=$(b ga-p1 "lane:kimi" kimi-lane "Importa os leads do Pipedrive"); P2=$(b ga-p2 "lane:kimi" "" "Troca o chip da frota")
E1=$(b ga-e1 "lane:kimi" kimi-lane ""); X1=$(jq -cn '{id:"ga-x1",title:"t",description:{"a":1},priority:2,labels:["lane:kimi"],metadata:{}}'); WP=$(b wa-p9 "lane:kimi" wa-worker "tem o CPF do cliente")
reset; on; r=$(run_pass "[$V1,$P1,$K1]" "[$V2,$P2]")
[ "$(cat "$DCALLS" 2>/dev/null)" = "ga-k1 lane=small kimi=1" ] && [ "$r" = "small= big= n=0/0 dispatched=1" ] && ok "aberta: das 5 só a limpa (ga-k1) vai a dispatch_one" || bad "aberta com 4 barradas: '$r' / $(cat "$DCALLS" 2>/dev/null)"
grep -q 'update ga-v1 --remove-label lane:kimi --set-metadata gc.routed_to=gastown.dog -q' "$CALLS" && ok "veto (node:never) já em kimi-lane: tira o rótulo E devolve a rota a gastown.dog, numa só chamada" || bad "rebaixamento de ga-v1: $(grep 'ga-v1' "$CALLS")"
grep -q 'update ga-p1 --remove-label lane:kimi --set-metadata gc.routed_to=gastown.dog -q' "$CALLS" && ok "dado pessoal já em kimi-lane: mesma coisa" || bad "rebaixamento de ga-p1: $(grep 'ga-p1' "$CALLS")"
grep -q 'update ga-v2 --remove-label lane:kimi -q' "$CALLS" && ! grep -q 'update ga-v2 .*set-metadata' "$CALLS" && grep -q 'update ga-p2 --remove-label lane:kimi -q' "$CALLS" && ! grep -q 'update ga-p2 .*set-metadata' "$CALLS" && ok "sem rota de espera gravada: só o rótulo sai, a rota não é tocada nem carimbada" || bad "rebaixamento sem rota: $(grep -E 'ga-(v2|p2)' "$CALLS")"
grep -q 'comment ga-v1 .*node:never' "$CALLS" && grep -q 'comment ga-p1 .*termo .lead.' "$CALLS" && ! grep -Eq 'comment ga-p1 .*(Importa os leads|Pipedrive)' "$CALLS" && ok "o comentário diz o motivo (rótulo / NOME do termo) e não copia o texto da bead" || bad "comentários: $(grep ' comment ' "$CALLS")"
grep -q 'update ga-k1 --set-metadata gc.routed_to=kimi-lane' "$CALLS" && ! grep -E 'update ga-(v1|v2|p1|p2) .*routed_to=kimi-lane' "$CALLS" >/dev/null && ok "só a que ficou na faixa é carimbada; as rebaixadas não" || bad "carimbos: $(grep set-metadata "$CALLS")"
grep -q 'rebaixadas=4 (falhas 0)' "$LINES" && ok "o log da passada conta as 4 rebaixadas" || bad "log da passada: $(grep -h 'faixa Kimi:' "$LINES" | tail -1)"
reset; r=$(run_pass "[$V1,$K1]" "[]")
grep -q 'update ga-v1 --remove-label lane:kimi --set-metadata gc.routed_to=gastown.dog' "$CALLS" && [ ! -s "$DCALLS" ] && grep -q 'fechada:off' "$LINES" && ok "faixa FECHADA: a devolvida pelo worker é rebaixada mesmo assim (não fica presa em kimi-lane) e nada é despachado" || bad "faixa fechada: $(cat "$CALLS" "$LINES" 2>/dev/null)"
reset; on; r=$(KL_DRY=1 run_pass "[$V1,$P1,$K1]" "[]")
[ ! -s "$DCALLS" ] && [ "$(writes)" = 0 ] && grep -q 'ga-v1 seria rebaixada (dry-run' "$LINES" && ok "DRY_RUN: diz o que rebaixaria, não escreve nada e não despacha" || bad "DRY_RUN: writes=$(writes) $(cat "$CALLS" "$DCALLS" 2>/dev/null)"
reset; on; printf '%s' '--remove-label' > "$WORK/bd.fail.on"; r=$(run_pass "[$V1,$K1]" "[$V2]")
[ "$(cat "$DCALLS" 2>/dev/null)" = "ga-k1 lane=small kimi=1" ] && grep -q 'não consegui rebaixar ga-v1' "$LINES" && grep -q 'rebaixadas=0 (falhas 2)' "$LINES" && ok "rebaixamento que não grava: a bead fica na faixa, sem despachar (só ga-k1 vai), e o aviso diz qual" || bad "rebaixamento que falha: '$r' / $(cat "$DCALLS" "$LINES" 2>/dev/null)"
grep -q 'update ga-v2 --set-metadata gc.routed_to=kimi-lane' "$CALLS" && ok "…e a que ficou sem rebaixar é carimbada (não cai numa pista Claude por falta de rota)" || bad "carimbo da que ficou: $(grep ga-v2 "$CALLS")"
reset; on; printf '%s' ' comment ' > "$WORK/bd.fail.on"; r=$(run_pass "[$V1]" "[]")
grep -q 'update ga-v1 --remove-label lane:kimi' "$CALLS" && grep -q 'rebaixadas=1 (falhas 0)' "$LINES" && grep -q 'o comentário com o motivo não gravou' "$LINES" && ok "comentário que não grava: a bead é rebaixada do mesmo jeito e o log guarda o motivo" || bad "comentário falhando: $(cat "$LINES" 2>/dev/null)"
reset; on; r=$(run_pass "[$E1,$X1,$K1]" "[]")
[ "$(cat "$DCALLS" 2>/dev/null)" = "ga-k1 lane=small kimi=1" ] && ! grep -q 'remove-label' "$CALLS" && grep -q 'esperando a triagem=2' "$LINES" && ok "sem descrição / campo que não se lê: espera — nada é rebaixado nem despachado, só ga-k1 vai" || bad "sem texto/ilegível: '$r' / $(cat "$DCALLS" "$CALLS" 2>/dev/null)"
grep -q 'update ga-x1 --set-metadata gc.routed_to=kimi-lane' "$CALLS" && ! grep -q 'update ga-e1 ' "$CALLS" && ok "…a que espera é carimbada se ainda não está em kimi-lane (ga-x1), e deixada quieta se já está (ga-e1)" || bad "carimbo das que esperam: $(grep set-metadata "$CALLS")"
reset; on; r=$(run_pass "[$V3]" "[]")
[ "$(cat "$DCALLS" 2>/dev/null)" = "ga-v3 lane=small kimi=1" ] && ! grep -q 'remove-label' "$CALLS" && ok "node:never-ever não é veto: a bead segue para o Kimi" || bad "node:never-ever: $(cat "$DCALLS" "$CALLS" 2>/dev/null)"
reset; on; r=$(run_pass "[$WP]" "[]")
[ ! -s "$DCALLS" ] && ! grep -q 'wa-p9' "$CALLS" && grep -q 'wa-p9 espera' "$LINES" && ok "bead de outro rig: não é triada nem escrita (semana 1: só HQ), apenas espera" || bad "outro rig: $(cat "$CALLS" "$LINES" 2>/dev/null)"
PASSFN="$(fn_src _pilot_kimi_lane_pass "$DISPATCHER")"
pl() { printf '%s\n' "$PASSFN" | grep -nF -- "$1" | head -1 | cut -d: -f1; }
l_sc=$(pl '_kl_verdict=$(_pilot_kimi_screen "$_kl_bead")'); l_st=$(pl '--set-metadata "gc.routed_to=$PILOT_KIMI_ROUTE"'); l_dr=$(pl 'if [ "${DRY_RUN:-0}" = "1" ]; then'); l_dm=$(pl 'elif _pilot_kimi_demote "$_kl_bead" "$_kl_why"; then'); l_dp=$(pl 'dispatch_one "$_kl_pick"')
{ [ -n "$l_sc" ] && [ -n "$l_st" ] && [ -n "$l_dp" ] && [ "$l_sc" -lt "$l_st" ] && [ "$l_st" -lt "$l_dp" ]; } && ok "a triagem roda antes do carimbo e do despacho" || bad "ordem da passada (triagem=$l_sc carimbo=$l_st despacho=$l_dp)"
{ [ -n "$l_dr" ] && [ -n "$l_dm" ] && [ "$l_dr" -lt "$l_dm" ]; } && ok "o teste do DRY_RUN vem antes do rebaixamento" || bad "DRY_RUN depois do rebaixamento (dry=$l_dr rebaixa=$l_dm)"

if [ -z "${KL_MUTANT:-}" ] && [ "${KL_NO_MUTANTS:-0}" != "1" ]; then
  echo "── controle negativo: cada mutante tem que reprovar a bateria"
  mutant() {  # mutant DESCRIÇÃO ARQUIVO(pilot|gate) ANTES DEPOIS
    local d="$WORK/mut.$RANDOM" src dst r
    mkdir -p "$d"; cp "$DISPATCHER" "$d/pilot-dispatcher.sh"; cp "$GATE" "$d/quality-gate-dispatcher.sh"
    case "$2" in pilot) dst="$d/pilot-dispatcher.sh" ;; gate) dst="$d/quality-gate-dispatcher.sh" ;; esac
    python3 - "$dst" "$3" "$4" <<'PY' || { bad "mutante '$1': a âncora não casa exatamente 1 vez"; return; }
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
if s.count(a) != 1: sys.exit(3)
open(p, 'w').write(s.replace(a, b))
PY
    r=$(KL_MUTANT=1 KL_NO_MUTANTS=1 PILOT_DISPATCHER_PATH="$d/pilot-dispatcher.sh" GATE_DISPATCHER_PATH="$d/quality-gate-dispatcher.sh" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) bad "mutante '$1' NÃO foi pego ($r)" ;; "RESULT "*) ok "mutante '$1' pego ($r)" ;; *) bad "mutante '$1': sem resultado ($r)" ;; esac
  }
  mutant "a pista normal fica com as do Kimi" pilot 'small) SMALL_CANDIDATES="$_kl_rest"; SMALL_COUNT' 'small) SMALL_CANDIDATES="$_kl_pool"; SMALL_COUNT'
  mutant "bandeira da faixa ignorada" pilot "  [ -e \"\$PILOT_KIMI_LANE_FLAG\" ] || { printf 'off'; return 0; }" ':'
  mutant "nó desligado ignorado" pilot "  [ -e \"\$PILOT_KIMI_NODE_FLAG\" ] || { printf 'node-off'; return 0; }" ':'
  mutant "bead de outro rig aceita" pilot 'case "$_kl_id" in ga-*) ;; *) _kl_other' 'case "$_kl_id" in *) ;; ga-*) _kl_other'
  mutant "a vaga conta todo template" pilot '([$live[] | select(.template == $kt and .state != "asleep")] | length) as $occ' '([$live[] | select(.state != "asleep")] | length) as $occ'
  mutant "sessão sem alias não ocupa" pilot '([$live[] | select(.template == $kt and .state != "asleep")] | length) as $occ' '([$live[] | select(.alias == ($kt + "-1") and .state != "asleep")] | length) as $occ'
  mutant "sem vaga e segue tentando" pilot 'case "${DISPATCH_RESULT:-}" in kimi_lane_wait|node_rollback_unconfirmed)' 'case "${DISPATCH_RESULT:-}" in nunca)'
  mutant "carimbo no DRY_RUN" pilot '  # (2) a rota de espera: só nas que ainda não a têm; o DRY_RUN não escreve
  if [ "${DRY_RUN:-0}" != "1" ]; then' '  # (2)
  if true; then'
  mutant "sessão que falha não desfaz" pilot '    if _pilot_node_first_rollback "$_kd_id" "$_kd_city" "$_kd_alias" "$_kd_sess"; then' '    if true; then'
  mutant "bloco do Kimi cai no mini" pilot '      DISPATCH_RESULT="kimi_lane_wait"
      return 1' '      DISPATCH_RESULT="kimi_lane_wait"'
  mutant "nó primeiro consultado na faixa" pilot '  [ "${_PILOT_KIMI_PASS:-0}" != "1" ] || return 0' '  :'
  mutant "gate restaura dog para lane:kimi" gate "    *\" lane:kimi \"*) printf 'kimi-lane' ;;" "    *\" lane:kimi \"*) printf '%s' \"\${2:-}\" ;;"
  mutant "veto ignorado" pilot '_ks_veto=$(_pilot_node_first_veto "$_ks_labels")' '_ks_veto=""'
  mutant "triagem sempre ok" pilot 'if $hit == "" then "ok" else "pii:" + $hit end' '"ok"'
  mutant "sem-texto passa" pilot 'then "sem-texto"' 'then "ok"'
  mutant "ilegível passa (campo)" pilot "*) printf 'ilegivel' ;; esac" "*) printf 'ok' ;; esac"
  mutant "ilegível passa (rótulos)" pilot "|| { printf 'ilegivel'; return 0; }" "|| { printf 'ok'; return 0; }"
  for t in cpf telefone conversa lead proprietario 'chip/frota' pipedrive email dado-pessoal 'shared/data'; do
    row=$(grep -F "[\"$t\", \"" "$DISPATCHER" | head -1 | sed 's/^ *//; s/,$//')
    mutant "termo '$t' ignorado" pilot "$row" "[\"$t\", \"(?!x)x\"]"
  done
  for t in lead 'chip/frota'; do
    row=$(grep -F "[\"$t\", \"" "$DISPATCHER" | head -1 | sed 's/^ *//; s/,$//')
    mutant "termo '$t' sem fronteira de palavra" pilot "$row" "${row//'\\b'/}"
  done
  mutant "a triagem não roda" pilot 'ga-*) _kl_verdict=$(_pilot_kimi_screen "$_kl_bead") ;;' 'ga-*) _kl_verdict=ok ;;'
  mutant "sem texto é despachada" pilot '        ok|fora-do-hq)' '        ok|fora-do-hq|sem-texto|ilegivel)'
  mutant "rebaixamento sem tirar o rótulo" pilot '_dm_args=(--remove-label lane:kimi)' '_dm_args=(-q)'
  mutant "rebaixamento sem devolver a rota" pilot 'if [ "$_dm_route" = "$PILOT_KIMI_ROUTE" ]; then _dm_args+=' 'if false; then _dm_args+='
  mutant "rebaixamento escreve no DRY_RUN" pilot '          if [ "${DRY_RUN:-0}" = "1" ]; then
            log "  faixa Kimi: $_kl_id seria rebaixada' '          if false; then
            log "  faixa Kimi: $_kl_id seria rebaixada'
  mutant "rebaixamento que falha conta como feito" pilot 'elif _pilot_kimi_demote "$_kl_bead" "$_kl_why"; then' 'elif true; then'
  mutant "as que esperam não são carimbadas" pilot "printf '%s\\n%s\\n%s' \"\$_kl_small\" \"\$_kl_big\" \"\$_kl_held\"" "printf '%s\\n%s\\n%s' \"\$_kl_small\" \"\$_kl_big\" '[]'"
  mutant "gate não aplica a faixa no FAIL" gate '        _GFAIL_ROUTE=$(gate_kimi_lane_route "${SRC_LABELS:-}" "$_GFAIL_ROUTE")' '        :'
fi
echo "pilot-dispatcher.kimi-lane selftest: $PASS passed, $FAIL failed"
echo "RESULT $FAIL/$((PASS+FAIL))"
[ "$FAIL" = 0 ]
