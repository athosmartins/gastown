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
#   rebaixamento que não grava deixa a bead esperando; a de outro rig não é triada. (triagem, comentários) _pilot_kimi_screen_comments: `[]` é ok, termo em qualquer comentário é piic:<termo>
#   (a bead é rebaixada), leitura que falha, saída vazia com rc 0, lista que não é lista ou text que não é texto é ilegivel (a bead espera); os comentários só são lidos da que passou no JSON.
#   (número longo) CPF de 11 dígitos, CNPJ (com ou sem máscara) e telefone sem máscara casam, e também CPF/CNPJ/telefone com espaço, ponto, barra ou hífen entre os grupos (mascarado por inteiro ou pela metade,
#   espaço sem quebra e dígito de largura total incluídos); sha, id de bead, data, data com hora, versão, contagem e número curto não. (telefone, rodada 1 do gate) (31) 9 9999-8888, (31) 9 9999 8888,
#   +55 (31) 9 9999-8888, 9 9999-8888 e 3333 4444 casam, e travessão, hífen não separável e menos Unicode valem como hífen.
#   (gate, rodada 1) o bloco do FAIL que decide a rota roda VERBATIM (marcadores SELFTEST-EXTRACT): rótulos em cache, cache vazio com releitura sem cache, e leitura que não rende (bd que falha, saída vazia, lixo, sem rótulo,
#   rótulo que não é texto) = a rota fica, com aviso e nota no comentário — nunca "sem lane:kimi" calado. (pilot_sweep) o que dispatch_one devolve sem despachar entra na contagem pelo nome. (soltas) kimi_lane_released não gasta
#   as 3 tentativas, mas tem teto de 10. (carimbo) a lista dos que precisam do carimbo que não se lê é dita (NÃO LI), nunca "carimbada=0". (texto) nada afirma "nenhuma vai a pool Claude".
#   (rodada 2, bloqueante) ESPERA DE PROPÓSITO NÃO É PARADA: o predicado de saturação e o Step 5 (a sequência do "Pilot estagnado") rodam VERBATIM (marcadores SELFTEST-EXTRACT): uma lane:kimi esperando e mais nada =
#   saturado, streak zerado, nenhum toque; o controle (candidato comum que não despachou) segue contando e tocando; espera + falha no mesmo sweep NÃO isenta; contador ilegível/ausente/com zero à esquerda; o marcador
#   POOL-SATURATED nomeia a espera e sai byte a byte igual sem ela. A passada deixa KIMI_LANE_WAITING (esperas) e soma as FALHAS (rebaixamento, carimbo, lista do carimbo, triagem ilegível, nó que falhou, retorno sem nome)
#   em NONQUEUE_FAILS. kimi_lane_failed (lista de sessões que não se leu, ou atribuição, sessão ou aviso que falhou: _PKL_FAULT) é um nome à parte de kimi_lane_wait (vaga ocupada, orçamento de spawn). (não bloqueante) a triagem lê também metadata story.criterios/estrela_guia/equilibrios; o
#   FAIL do gate de uma bead lane:kimi acrescenta a nota de que kimi-lane não é um pool.
# COMO RODA: as funções são extraídas VERBATIM dos dispatchers (awk) e rodam num shell filho sob `set -euo pipefail`, com `gc` e `bd` FALSOS num PATH sem os reais; dispatch_one é um falso que
#   registra o que recebeu. Contra um dispatcher sem as funções o arquivo se recusa a começar.
# CONTROLE NEGATIVO: cada mutante (pista que não separa as do Kimi, bandeira ignorada, bead de outro rig aceita, vaga que conta todo template, bloco do Kimi que cai no mini, gate que restaura dog,
#   veto ignorado, cada termo da lista ignorado, termo sem fronteira de palavra, cada forma do número longo e do telefone, travessão que não vale como hífen, sem-texto/ilegível que passa, comentários que não são triados
#   ou cuja leitura falha/vem vazia/malformada conta como ok, rebaixamento que não tira o rótulo/a rota/escreve no DRY_RUN, gate que não relê/não avisa/não anota, passada que não nota o resultado, solta que gasta
#   tentativa ou sem teto, lista do carimbo que falha sem dizer; rodada 2: predicado que ignora a espera, que isenta com falha ou com despacho, contador ilegível que isenta, passada que não conta a espera ou não soma
#   cada uma das falhas, kimi_lane_failed que vira espera ou não para a passada, metadata story.* fora da triagem, nota do gate fora do lugar) é aplicado numa cópia e a bateria tem de reprovar.
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
for f in gc_json_or_unknown _pilot_slow_spawn_budget_spent _pilot_note_spawn_timing _pilot_node_first_rollback _pilot_node_first_veto _pilot_kimi_lane_closed _pilot_kimi_pick_alias _pilot_kimi_dispatch _pilot_kimi_screen _pilot_kimi_screen_comments _pilot_kimi_demote _pilot_kimi_lane_pass; do
  src="$(fn_src "$f" "$DISPATCHER")"
  [ -n "$src" ] || { echo "FATAL: $f() not found in $DISPATCHER (ga-do1ixn.3 not applied)" >&2; exit 2; }
  FUNCS="$FUNCS
$src"
done
GFUNC=""
for f in gate_kimi_lane_route gate_lane_labels_from_show gate_fail_lane_labels; do
  src="$(fn_src "$f" "$GATE")"
  [ -n "$src" ] || { echo "FATAL: $f() not found in $GATE" >&2; exit 2; }
  GFUNC="$GFUNC
$src"
done
# o bloco do FAIL que decide a rota da bead lane:kimi, entre os marcadores SELFTEST-EXTRACT (roda VERBATIM nos testes do gate)
GBLOCK="$(awk '/# SELFTEST-EXTRACT gate-fail-kimi-lane: BEGIN/{f=1;next} /# SELFTEST-EXTRACT gate-fail-kimi-lane: END/{f=0} f' "$GATE")"
[ -n "$GBLOCK" ] || { echo "FATAL: bloco SELFTEST-EXTRACT gate-fail-kimi-lane vazio ou ausente em $GATE" >&2; exit 2; }
# o predicado de saturação e o Step 5 (a sequência "Pilot estagnado"), entre os marcadores SELFTEST-EXTRACT: rodam VERBATIM nos testes da espera de propósito (rodada 2)
PRED_BLOCK="$(awk '/# SELFTEST-EXTRACT pilot-saturation-predicate: BEGIN/{f=1;next} /# SELFTEST-EXTRACT pilot-saturation-predicate: END/{f=0} f' "$DISPATCHER")"
STEP5_BLOCK="$(awk '/# SELFTEST-EXTRACT pilot-stall-step5: BEGIN/{f=1;next} /# SELFTEST-EXTRACT pilot-stall-step5: END/{f=0} f' "$DISPATCHER")"
[ -n "$PRED_BLOCK" ] && [ -n "$STEP5_BLOCK" ] || { echo "FATAL: bloco SELFTEST-EXTRACT pilot-saturation-predicate/pilot-stall-step5 vazio ou ausente em $DISPATCHER" >&2; exit 2; }

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
# bd FALSO: uma bead (assignee/status em arquivo; honra --if-assignee) e os comentários de cada id. Registra toda chamada.
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
  show) # $W/bd.show.raw: o que o `show` imprime, byte a byte (vazio = rc 0 sem saída); $W/bead.labels: a lista JSON de rótulos que entra no objeto
        if [ -f "$W/bd.show.raw" ]; then cat "$W/bd.show.raw"; exit 0; fi
        s=open; [ ! -f "$W/bead.status" ] || s=$(cat "$W/bead.status")
        lab=""; [ ! -f "$W/bead.labels" ] || lab=",\"labels\":$(cat "$W/bead.labels")"
        printf '[{"id":"%s","assignee":"%s","status":"%s"%s}]\n' "$4" "$(cur)" "$s" "$lab"; exit 0 ;;
  comments) # `bd -C C comments <id> --json`: imprime $W/comments.<id> (arquivo vazio = rc 0 sem saída); sem arquivo = bead sem comentários
        if [ -f "$W/comments.$4" ]; then cat "$W/comments.$4"; else echo '[]'; fi; exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/gc" "$WORK/bin/bd"
sandbox_path_init "$WORK" jq date timeout mkdir dirname cat sleep head || exit 2

CALLS="$WORK/calls.log"; LINES="$WORK/lines.txt"; DCALLS="$WORK/dispatch.log"; NOTES="$WORK/notes.log"
reset() { rm -f "$WORK"/gc.*.rc "$WORK"/sessions.json "$WORK"/bead.assignee "$WORK"/bead.status "$WORK"/bead.labels "$WORK"/bd.show.raw "$WORK"/bd.fail.on "$WORK"/comments.* "$CALLS" "$LINES" "$DCALLS" "$NOTES" "$WORK/pass.counters" "$WORK/kd.fault" "$WORK/gate.kimi.note" "$WORK"/city/.gc/*.on; echo open > "$WORK/bead.status"; }
sess() { # sess alias:state[:template] ... → sessions.json
  local a j='[]' al st tp
  for a in "$@"; do
    IFS=: read -r al st tp <<<"$a"
    j=$(jq -c --arg al "$al" --arg st "$st" --arg tp "${tp:-kimi-worker-remote}" '. + [{id:("ga-" + $al), name:$al, alias:$al, template:$tp, state:$st, closed:false}]' <<<"$j")
  done
  printf '{"sessions":%s}\n' "$j" > "$WORK/sessions.json"
}
on()  { : > "$WORK/city/.gc/kimi-lane.on"; : > "$WORK/city/.gc/hetzner-node.on"; }
writes() { grep -v 'session list' "$CALLS" 2>/dev/null | grep -v '^bd .* comments ' | grep -vc '^bd .* show ' || true; }
b() { # b id labels_csv [route] [descrição] → um objeto de candidata (descrição limpa por padrão; "" = vazia)
  jq -cn --arg id "$1" --arg l "$2" --arg r "${3:-}" --arg d "${4-Mexe só no script do gate e no selftest.}" '{id:$id, title:("t " + $id), description:$d, priority:2, labels:($l | split(",") | map(select(length > 0))), metadata:(if $r == "" then {} else {"gc.routed_to":$r} end)}'
}

# run_pass SMALL_JSON BIG_JSON — a passada num filho; imprime "small=<ids> big=<ids> dispatched=<n>". KL_DRC = rc do dispatch_one falso; KL_DRES = o DISPATCH_RESULT dele (definida e vazia = dispatch_one sem nome);
# KL_REL = ids ("ga-r1 ga-r2") para os quais ele devolve rc 1 com kimi_lane_released (solta antes de gastar a vaga). _pilot_sweep_note grava "<id> <rc> <nome>" em $NOTES.
# KL_JQFAIL=1 troca o jq do filho por um que falha só na leitura de "quais beads precisam do carimbo" (a que usa startswith("ga-")).
run_pass() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    log()  { echo "LOG $*" >> "$LINES"; }
    warn() { echo "WARN $*" >> "$LINES"; }
    _top_candidate() { printf '%s' "$1" | jq -c '.[0] // empty'; }
    _bead_tier() { echo story; }
    _dolt_saturated() { return 1; }
    _pilot_sweep_note() { echo "$1 $2 ${3-}" >> "$NOTES"; }
    dispatch_one() {
      local _di_id; _di_id=$(printf '%s' "$1" | jq -r .id)
      echo "$_di_id lane=$2 kimi=${_PILOT_KIMI_PASS:-0}" >> "$DCALLS"
      case " ${KL_REL:-} " in *" $_di_id "*) DISPATCH_RESULT=kimi_lane_released; return 1 ;; esac
      DISPATCH_RESULT="${KL_DRES-node_ok}"; return "${KL_DRC:-0}"
    }
    if [ "${KL_JQFAIL:-0}" = 1 ]; then jq() { case "$*" in *'startswith("ga-")'*) return 5 ;; esac; command jq "$@"; }; fi
    GC_CITY="$WORK/city"; PILOT_KIMI_LANE_FLAG="$GC_CITY/.gc/kimi-lane.on"; PILOT_KIMI_NODE_FLAG="$GC_CITY/.gc/hetzner-node.on"
    PILOT_KIMI_TEMPLATE="kimi-worker-remote"; PILOT_KIMI_ROUTE="kimi-lane"; DRY_RUN="${KL_DRY:-0}"; DISPATCHED=0
    PILOT_NODE_FIRST_VETO_LABELS="node:never needs:engine-window exec:manual"
    SMALL_CANDIDATES="$1"; BIG_CANDIDATES="$2"; SMALL_COUNT=0; BIG_COUNT=0
    NONQUEUE_FAILS=0; KIMI_LANE_WAITING=0   # o dispatcher os declara no topo, junto de POOL_CAP_QUEUED
    eval "$FUNCS"
    _pilot_kimi_lane_pass
    echo "waiting=${KIMI_LANE_WAITING-?} nqf=${NONQUEUE_FAILS-?}" > "$WORK/pass.counters"
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
    # KD_JQFAIL=1: o jq que escolhe a vaga (o que declara $occ) morre; os outros jq seguem
    if [ "${KD_JQFAIL:-0}" = 1 ]; then jq() { case "$*" in *'$occ'*) return 5 ;; esac; command jq "$@"; }; fi
    eval "$FUNCS"
    _pilot_kimi_dispatch "ga-k1" "$WORK/city" "Título"
    echo "fault=${_PKL_FAULT-?}" > "$WORK/kd.fault"
    echo "res=${_PNF_RESULT-?} alias=${_PNF_ALIAS-?}"
  ) 2>&1 | tail -1
}

# run_step5 INICIAL [VAR=valor ...] — o predicado de saturação e o Step 5 VERBATIM num filho (notify/log/warn falsos; sem bd nem gc). INICIAL = o valor que o arquivo do streak já tem (none = sem arquivo).
# Imprime "sat=<0|1> estado=<n|none> notify=<n>": o predicado, o streak depois do sweep e quantas vezes o "Pilot estagnado" tocou.
run_step5() {
  local init="$1" sat st nt; shift
  rm -f "$WORK/city/.gc/pilot-dispatcher-stall.count" "$WORK/notify.log" "$WORK/step5.log"
  [ "$init" = none ] || printf '%s\n' "$init" > "$WORK/city/.gc/pilot-dispatcher-stall.count"
  sat=$(
    set -euo pipefail
    log() { echo "$*" >> "$WORK/step5.log"; }; warn() { :; }
    notify() { echo "$*" >> "$WORK/notify.log"; }
    GC_CITY="$WORK/city"; DRY_RUN=0; DISPATCHED=0; SMALL_SLOTS=3; BIG_SLOTS=3; POOL_CAP_QUEUED=0; PRIORITY_YIELDED=0; NONQUEUE_FAILS=0; KIMI_LANE_WAITING=0
    for kv in "$@"; do eval "$kv"; done
    eval "$PRED_BLOCK"
    eval "$STEP5_BLOCK"
    echo "$_pool_saturated_sweep"
  ) || sat="rc$?"
  st=none; [ ! -f "$WORK/city/.gc/pilot-dispatcher-stall.count" ] || st=$(cat "$WORK/city/.gc/pilot-dispatcher-stall.count")
  nt=0; [ ! -f "$WORK/notify.log" ] || nt=$(grep -c 'Pilot estagnado' "$WORK/notify.log" || true)
  echo "sat=$sat estado=$st notify=$nt"
}
cset() { printf '%s\n' "$2" > "$WORK/comments.$1"; }   # cset <id> <json>: o que `bd comments <id> --json` imprime para esse id
cj() { jq -cn --arg t "$1" '[{author:"mayor", created_at:"2026-10-28T12:00:00Z", id:"c1", issue_id:"ga-x", text:$t}]'; }   # UM comentário, no formato do bd
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

echo "── passada: o que dispatch_one devolve entra na contagem da varredura (pilot_sweep) pelo NOME (rodada 1, bloqueante 1)"
reset; on; r=$(run_pass "[$K1]" "[]")
[ "$(cat "$NOTES" 2>/dev/null)" = "ga-k1 0 node_ok" ] && ok "despachada: _pilot_sweep_note ga-k1 0 node_ok" || bad "nota da despachada: '$(cat "$NOTES" 2>/dev/null)'"
reset; on; r=$(KL_DRC=1 KL_DRES=kimi_lane_wait run_pass "[$K1,$K2]" "[]")
[ "$(cat "$NOTES" 2>/dev/null)" = "ga-k1 1 kimi_lane_wait" ] && ok "sem vaga: a nota leva o NOME kimi_lane_wait (uma só: a passada para)" || bad "nota do kimi_lane_wait: '$(cat "$NOTES" 2>/dev/null)'"
reset; on; r=$(KL_DRC=1 KL_DRES=node_rollback_unconfirmed run_pass "[$K1,$K2]" "[]")
[ "$(cat "$NOTES" 2>/dev/null)" = "ga-k1 1 node_rollback_unconfirmed" ] && [ "$(grep -c . "$DCALLS")" = 1 ] && ok "desfazer sem confirmar: a nota leva o nome (failed_other no resumo) e a passada para" || bad "nota do node_rollback_unconfirmed: '$(cat "$NOTES" 2>/dev/null)' tentativas=$(grep -c . "$DCALLS")"
reset; on; r=$(KL_DRC=1 KL_DRES= run_pass "[$K1,$K2]" "[]")
[ "$(head -1 "$NOTES" 2>/dev/null)" = "ga-k1 1 " ] && [ "$(grep -c . "$DCALLS")" = 2 ] && ok "dispatch_one que falha sem nome: a nota vai sem nome (unclassified, nunca sumida) e a passada tenta a próxima" || bad "nota sem nome: '$(cat "$NOTES" 2>/dev/null)' tentativas=$(grep -c . "$DCALLS")"

echo "── passada: soltas (kimi_lane_released) não gastam as 3 tentativas, mas têm teto próprio (rodada 1, não bloqueante)"
R1=$(b ga-r1 lane:kimi); R2=$(b ga-r2 lane:kimi); R3=$(b ga-r3 lane:kimi); R4=$(b ga-r4 lane:kimi)
reset; on; r=$(KL_REL="ga-r1 ga-r2 ga-r3 ga-r4" run_pass "[$R1,$R2,$R3,$R4,$K1]" "[]")
[ "$(tail -1 "$DCALLS")" = "ga-k1 lane=small kimi=1" ] && [ "$(grep -c . "$DCALLS")" = 5 ] && echo "$r" | grep -q 'dispatched=1' && ok "4 soltas à frente: a limpa de trás (ga-k1) ainda tem a vez e é despachada (a cabeça da fila não trava a faixa)" || bad "soltas à frente: '$r' / $(cat "$DCALLS" 2>/dev/null)"
grep -q 'soltas=4' "$LINES" && [ "$(grep -c 'ga-r. 1 kimi_lane_released' "$NOTES")" = 4 ] && ok "o resumo conta soltas=4 e cada uma entra na contagem da varredura com o nome" || bad "soltas no resumo/notas: $(grep -h 'faixa Kimi:' "$LINES" | tail -1) / $(cat "$NOTES" 2>/dev/null)"
RS=""; RIDS=""; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do RS="$RS$(b ga-s$i lane:kimi),"; RIDS="$RIDS ga-s$i"; done
reset; on; r=$(KL_REL="$RIDS" run_pass "[${RS}$K1]" "[]")
[ "$(grep -c . "$DCALLS")" = 10 ] && ! grep -q 'ga-k1' "$DCALLS" && grep -q ' · soltas · ' "$LINES" && grep -q 'soltas=10' "$LINES" && echo "$r" | grep -q 'dispatched=0' && ok "12 soltas à frente: a passada para no teto de 10 (cada solta custa uma claim e uma solta no HQ) e diz o motivo 'soltas'" || bad "teto de soltas: $(grep -c . "$DCALLS") tentativas / $(grep -h 'faixa Kimi:' "$LINES" | tail -1)"

echo "── passada: lista dos que precisam do carimbo que não se lê ≠ nada a carimbar (rodada 1, não bloqueante)"
reset; on; r=$(run_pass "[$K1]" "[]")
grep -q 'rota carimbada=1 (falhas 0)' "$LINES" && ! grep -q '^WARN' "$LINES" && ok "controle: lista lida, UMA carimbada, sem aviso" || bad "controle do carimbo: $(cat "$LINES" 2>/dev/null)"
reset; on; r=$(KL_JQFAIL=1 run_pass "[$K1]" "[]")
grep -q '^WARN ga-do1ixn.3: faixa Kimi: não consegui ler quais beads precisam do carimbo' "$LINES" && grep -q 'rota carimbada=NÃO LI a lista (nada carimbado)' "$LINES" && ! grep -q 'routed_to=kimi-lane' "$CALLS" && ok "extração que falha: aviso e o resumo diz NÃO LI (nunca 'carimbada=0'); nada é carimbado" || bad "extração que falha: $(cat "$LINES" 2>/dev/null) / $(grep routed_to "$CALLS" 2>/dev/null)"

echo "── passada: o texto não promete o que a sondagem dos dogs desmente (rodada 1, não bloqueante)"
reset; on; r=$(run_pass "[$K1]" "[]")
grep -q 'uma rota de pool posta por fora (gastown.dog) vale até o carimbo desta passada' "$LINES" && ! grep -q 'nenhuma vai a pool Claude' "$LINES" && ok "o log da passada diz que o Pilot não despacha a pool Claude e que uma rota gastown.dog posta por fora vale até o carimbo" || bad "texto do log: $(grep -h 'faixa Kimi:' "$LINES" | tail -1)"
RUNBOOK="$SELF_DIR/../../../docs/runbooks/gc-session-ssh.md"
if [ -f "$RUNBOOK" ]; then
  { ! grep -q 'nenhuma vai a pool Claude' "$DISPATCHER" "$RUNBOOK"; } && ok "nem o dispatcher nem o runbook afirmam 'nenhuma vai a pool Claude'" || bad "o absoluto 'nenhuma vai a pool Claude' voltou: $(grep -ln 'nenhuma vai a pool Claude' "$DISPATCHER" "$RUNBOOK")"
else echo "  SKIP runbook gc-session-ssh.md não está em $RUNBOOK (checagem de redação só do dispatcher)"; { ! grep -q 'nenhuma vai a pool Claude' "$DISPATCHER"; } && ok "o dispatcher não afirma 'nenhuma vai a pool Claude'" || bad "o absoluto voltou no dispatcher"; fi

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
lr=$(grep -n '_GFAIL_ROUTE=$(gate_kimi_lane_route "$_GFAIL_LANE_LABELS" "$_GFAIL_ROUTE")' "$GATE" | cut -d: -f1); lwr=$(grep -n 'update "$BEAD_ID" --set-metadata "gc.routed_to=$_GFAIL_ROUTE"' "$GATE" | head -1 | cut -d: -f1); l0=$(grep -n '_GFAIL_ROUTE=$(gate_fail_restore_route' "$GATE" | cut -d: -f1)
{ [ -n "$lr" ] && [ -n "$lwr" ] && [ -n "$l0" ] && [ "$l0" -lt "$lr" ] && [ "$lr" -lt "$lwr" ]; } && ok "o FAIL aplica a faixa Kimi depois de calcular a rota e antes de gravá-la" || bad "ordem no FAIL (rota=$l0 kimi=$lr escrita=$lwr)"
echo "── gate: rótulos que o FAIL não leu (rodada 1, bloqueante 2) — o bloco do FAIL roda VERBATIM, com bd falso"
# run_gblock <SRC_LABELS (a leitura em cache do começo do FAIL)> <rota restaurada> — imprime "route=<..> note=<0|1>"; warn do gate grava "WARN ..." em $LINES
run_gblock() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    warn() { echo "WARN $*" >> "$LINES"; }
    BEAD_CITY="$WORK/city"; BEAD_ID=ga-g1; SRC_LABELS="$1"; _GFAIL_ROUTE="$2"
    eval "$GFUNC"
    eval "$GBLOCK"
    printf '%s' "${_GFAIL_KIMI_NOTE-?}" > "$WORK/gate.kimi.note"
    echo "route=$_GFAIL_ROUTE note=$([ -n "$_GFAIL_LANE_NOTE" ] && echo 1 || echo 0)"
  ) 2>&1 | tail -1
}
nshow() { local n; n=$(grep -c '^bd .* show ga-g1 ' "$CALLS" 2>/dev/null) || n=0; echo "${n:-0}"; }   # arquivo ausente (nenhuma chamada) = 0
nwarn() { local n; n=$(grep -c '^WARN ' "$LINES" 2>/dev/null) || n=0; echo "${n:-0}"; }
reset; r=$(run_gblock "story:approved lane:kimi gate:needs-fix" gastown.dog)
[ "$r" = "route=kimi-lane note=0" ] && [ "$(nshow)" = 0 ] && [ "$(nwarn)" = 0 ] && ok "rótulos em cache com lane:kimi: kimi-lane, sem reler e sem aviso" || bad "cache com lane:kimi: '$r' shows=$(nshow) warns=$(nwarn)"
reset; r=$(run_gblock "story:approved gate:needs-fix" gastown.dog)
[ "$r" = "route=gastown.dog note=0" ] && [ "$(nshow)" = 0 ] && [ "$(nwarn)" = 0 ] && ok "rótulos em cache sem lane:kimi: a rota que veio fica, sem reler e sem aviso" || bad "cache sem lane:kimi: '$r' shows=$(nshow) warns=$(nwarn)"
reset; printf '%s' '["gate:needs-fix","lane:kimi"]' > "$WORK/bead.labels"; r=$(run_gblock "" gastown.dog)
[ "$r" = "route=kimi-lane note=0" ] && [ "$(nshow)" = 1 ] && [ "$(nwarn)" = 0 ] && ok "cache vazio: relê UMA vez sem cache, acha lane:kimi e devolve kimi-lane, sem aviso" || bad "cache vazio + lane:kimi na releitura: '$r' shows=$(nshow) warns=$(nwarn)"
reset; printf '%s' '["gate:needs-fix","story:approved"]' > "$WORK/bead.labels"; r=$(run_gblock "" gastown.dog)
[ "$r" = "route=gastown.dog note=0" ] && [ "$(nshow)" = 1 ] && [ "$(nwarn)" = 0 ] && ok "cache vazio, releitura sem lane:kimi: leu de verdade, a rota fica, sem aviso (não é falha)" || bad "cache vazio + sem lane:kimi na releitura: '$r' shows=$(nshow) warns=$(nwarn)"
reset; printf '%s' 'show ga-g1' > "$WORK/bd.fail.on"; r=$(run_gblock "" gastown.dog)
[ "$r" = "route=gastown.dog note=1" ] && [ "$(nwarn)" = 1 ] && grep -q '^WARN .*ga-g1' "$LINES" && ok "cache vazio e releitura que falha: a rota fica (nunca sem rota), com UM aviso que nomeia a bead e a nota para o comentário do FAIL" || bad "releitura que falha: '$r' warns=$(nwarn) $(cat "$LINES" 2>/dev/null)"
reset; printf '%s' 'show ga-g1' > "$WORK/bd.fail.on"; r=$(run_gblock "" wa-worker)
[ "$r" = "route=wa-worker note=1" ] && ok "a rota restaurada de outro rig (wa-worker) também fica quando os rótulos não foram lidos" || bad "wa-worker sem rótulos: '$r'"
for rawcase in 'vazia (rc 0 sem saída)|' 'lixo|isto-nao-e-json' 'lista vazia|[]' 'sem rótulos|[{"id":"ga-g1"}]' 'rótulos que não são texto|[{"id":"ga-g1","labels":[1]}]' 'rótulos nulos|[{"id":"ga-g1","labels":null}]'; do
  reset; printf '%s' "${rawcase#*|}" > "$WORK/bd.show.raw"; r=$(run_gblock "" gastown.dog)
  [ "$r" = "route=gastown.dog note=1" ] && [ "$(nwarn)" = 1 ] && ok "releitura ${rawcase%%|*}: não li — a rota fica, com aviso e nota (bead no gate sempre tem rótulo; nenhum rótulo é leitura que não rendeu)" || bad "releitura ${rawcase%%|*}: '$r' warns=$(nwarn)"
done
# a rota kimi-lane não é um pool: a frase do comentário ("so pool workers can self-serve this bead") não vale para ela, e a nota diz o que vale (rodada 2, não bloqueante)
reset; r=$(run_gblock "story:approved lane:kimi gate:needs-fix" gastown.dog); kn=$(cat "$WORK/gate.kimi.note" 2>/dev/null)
case "$kn" in *lane:kimi*"não é um pool"*"passada da faixa Kimi"*) ok "FAIL de bead lane:kimi: o comentário ganha a nota 'a rota kimi-lane não é um pool; quem a leva de volta é a passada da faixa Kimi'" ;; *) bad "nota da rota kimi-lane: '$kn'" ;; esac
reset; r=$(run_gblock "story:approved gate:needs-fix" gastown.dog); kn=$(cat "$WORK/gate.kimi.note" 2>/dev/null)
[ -z "$kn" ] && [ -f "$WORK/gate.kimi.note" ] && ok "FAIL de bead comum: SEM nota da faixa (a frase do pool vale) — o arquivo existe e está vazio, não ausente" || bad "bead comum com nota da faixa ou sem o bloco: '$kn'"
reset; printf '%s' 'show ga-g1' > "$WORK/bd.fail.on"; r=$(run_gblock "" gastown.dog); kn=$(cat "$WORK/gate.kimi.note" 2>/dev/null)
[ -z "$kn" ] && [ -f "$WORK/gate.kimi.note" ] && ok "rótulos que não li: a rota ficou gastown.dog, então a nota da faixa NÃO sai (só a nota dos rótulos não lidos, que já existe)" || bad "nota da faixa com rótulos não lidos: '$kn'"
n=$(grep -c '\$_GFAIL_LANE_NOTE\$_GFAIL_KIMI_NOTE The Pilot will also re-dispatch' "$GATE" || true); [ "$n" = 1 ] && ok "o comentário do FAIL leva a nota da faixa Kimi UMA vez, logo depois da nota dos rótulos" || bad "nota \$_GFAIL_KIMI_NOTE no comentário do FAIL: $n ocorrência(s)"
n=$(grep -c '\$_GFAIL_ROUTE_UNKNOWN_NOTE\$_GFAIL_LANE_NOTE' "$GATE" || true); [ "$n" = 1 ] && ok "o comentário do FAIL leva a nota dos rótulos não lidos (UMA vez, ao lado da nota da rota)" || bad "nota \$_GFAIL_LANE_NOTE no comentário do FAIL: $n ocorrência(s)"
{ ! printf '%s\n' "$GFUNC" | grep -Eq '(^|[^_a-z-])(warn|log) '; } && ok "as funções do gate rodam dentro de \$(...): nenhuma chama warn/log (a saída viraria rótulo)" || bad "warn/log dentro de função do gate que roda em \$(...)"

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
numero-longo|cliente 12345678901
numero-longo|a empresa 12345678000190
numero-longo|manda pro 5531999998888
numero-longo|ligar 98765-4321
numero-longo|CNPJ 12.345.678/0001-90
numero-longo|fixo 3456-7890
numero-longo|zap 11-9876-5432
numero-longo|zap 11 98765 4321
numero-longo|zap 11.98765.4321
numero-longo|zap 011 9 8765 4321
numero-longo|zap 55 11 98765 4321
numero-longo|ligar 98765 4321
numero-longo|ligar 98765.4321
numero-longo|documento 123 456 789 09
numero-longo|documento 123.456.789 09
numero-longo|documento 123456789-09
numero-longo|documento 123.456.78909
numero-longo|documento 123-456-789-09
numero-longo|empresa 12345678/0001-90
numero-longo|empresa 12345678/000190
numero-longo|empresa 12.345.678/000190
numero-longo|empresa 12 345 678 0001 90
numero-longo|empresa 12.345.678 0001 90
telefone|(31) 9 9999-8888
telefone|(31) 9 9999 8888
telefone|+55 (31) 9 9999-8888
telefone|(31) 99999–8888
telefone|(31)99999-8888
telefone|(31) 3333-4444
telefone|+55 31 99999 8888
telefone|+5531999998888
numero-longo|9 9999-8888
numero-longo|9 9999 8888
numero-longo|3333 4444
numero-longo|3333.4444
numero-longo|zap 11 98765–4321
EOF
# hífen que não é o ASCII: o gate achou "(31) 99999–8888" (travessão) e o hífen não separável (U+2011) passando; todos valem como "-" antes de casar
for dash in '\xe2\x80\x90' '\xe2\x80\x91' '\xe2\x80\x92' '\xe2\x80\x93' '\xe2\x80\x94' '\xe2\x80\x95' '\xe2\x88\x92' '\xef\xbc\x8d'; do
  r=$(S lane:kimi "T" "zap 11 98765$(printf "$dash")4321"); [ "$r" = pii:numero-longo ] && ok "separador Unicode $dash no telefone 11 98765-4321: casa como hífen" || bad "separador $dash em 'zap 11 98765?4321': '$r'"
  r=$(S lane:kimi "T" "fixo 3333$(printf "$dash")4444"); [ "$r" = pii:numero-longo ] && ok "separador Unicode $dash no fixo 3333-4444: casa como hífen" || bad "separador $dash em 'fixo 3333?4444': '$r'"
done
r=$(S lane:kimi "T" "commits d12b6923f e 6474abc8d na bead ga-do1ixn.3, 123456789 linhas, porta 1234567, dia 2026-10-28, v1.2.3"); [ "$r" = ok ] && ok "número curto, sha, id de bead e data NÃO casam como número longo" || bad "falso positivo de número: '$r'"
for t in '2026-10-28 19:15:00' '28/10/2026 19:15' '28.10.2026' '2026-10-28 2026-10-29' 'versão 1.2.3 e 4.5.6' 'linhas 120 130 140 150' 'ip 10.0.0.1 e 172.16.0.254' '5000 MB livres, 4803 MB' 'teto 1000 linhas, 800 de produção' 'ga-do1ixn.3 e ga-do1ixn.5'; do
  r=$(S lane:kimi "T" "$t"); [ "$r" = ok ] && ok "data, hora, versão e contagem NÃO casam como número longo: '$t'" || bad "falso positivo de número em '$t': '$r'"
done
r=$(S lane:kimi "T" "zap $(printf '11\xc2\xa098765\xc2\xa04321')"); [ "$r" = pii:numero-longo ] && ok "o espaço sem quebra (U+00A0) entre os grupos também casa" || bad "NBSP: '$r'"
r=$(S lane:kimi "T" "zap $(printf '\xef\xbc\x91\xef\xbc\x91\xef\xbc\x99\xef\xbc\x98\xef\xbc\x97\xef\xbc\x96\xef\xbc\x95\xef\xbc\x94\xef\xbc\x93\xef\xbc\x92\xef\xbc\x91')"); [ "$r" = pii:numero-longo ] && ok "dígitos de largura total também casam" || bad "dígito largo: '$r'"
r=$(S lane:kimi "T" "$(printf 'o proprieta\xcc\x81rio do lote')"); [ "$r" = "pii:proprietario" ] && ok "acento decomposto (NFD) também casa" || bad "NFD: '$r'"
r=$(S lane:kimi "Importar leads" "texto limpo"); [ "$r" = "pii:lead" ] && ok "o termo no TÍTULO basta" || bad "título: '$r'"
r=$(run_screen '{"id":"ga-s","title":"t","description":"limpo","notes":"fala do WhatsApp"}'); [ "$r" = "pii:telefone" ] && ok "o termo nas notas também barra" || bad "notas: '$r'"
# rodada 2 (não bloqueante): os campos de texto que o dispatch_one trata como conteúdo da bead (metadata story.criterios, story.estrela_guia, story.equilibrios) também passam pela triagem
for mk in story.criterios story.estrela_guia story.equilibrios; do
  r=$(run_screen "$(jq -cn --arg k "$mk" '{id:"ga-s",title:"t",description:"limpo",labels:[],metadata:{($k):"importar o CPF do cliente"}}')"); [ "$r" = "pii:cpf" ] && ok "termo em metadata $mk: barra (pii:cpf)" || bad "metadata $mk: '$r'"
done
r=$(run_screen '{"id":"ga-s","title":"t","description":"limpo","labels":[],"metadata":{"story.criterios":"abre o painel e confere o log","story.estrela_guia":"rápido","story.equilibrios":"sem risco"}}'); [ "$r" = ok ] && ok "CONTROLE: metadata story.* limpos não barram" || bad "metadata limpo: '$r'"
r=$(run_screen '{"id":"ga-s","title":"t","description":"limpo","labels":[],"metadata":{"gc.routed_to":"kimi-lane","pilot.dispatching_at":"1793280866"}}'); [ "$r" = ok ] && ok "CONTROLE: metadata operacional (rota, carimbo de tempo) não é triado como texto" || bad "metadata operacional: '$r'"
r=$(run_screen '{"id":"ga-s","title":"t","description":"limpo","labels":[],"metadata":{"story.criterios":{"a":1}}}'); [ "$r" = ilegivel ] && ok "story.criterios que não é texto: ilegivel (espera; nunca ok)" || bad "story.criterios objeto: '$r'"
r=$(run_screen '{"id":"ga-s","title":"t","description":"limpo","labels":[],"metadata":"isto-nao-e-objeto"}'); [ "$r" = ilegivel ] && ok "metadata que não é objeto: ilegivel" || bad "metadata string: '$r'"
r=$(S lane:kimi "T" "um leader, um chipset, leadership, conversão de cores, o log do gate"); [ "$r" = ok ] && ok "palavra inteira: leader/chipset/leadership/conversão não casam" || bad "palavra inteira: '$r'"
r=$(run_screen '{"id":"ga-s","title":"t","labels":[]}'); [ "$r" = "sem-texto" ] && ok "sem descrição: sem-texto" || bad "sem descrição: '$r'"
r=$(S lane:kimi "T" "   "); [ "$r" = "sem-texto" ] && ok "descrição só de espaço: sem-texto" || bad "descrição em branco: '$r'"
r=$(S lane:kimi "" "texto"); [ "$r" = "sem-texto" ] && ok "título vazio: sem-texto" || bad "título vazio: '$r'"
for bj in '{"id":"ga-s","title":"t","description":{"a":1}}' '{"id":"ga-s","title":5,"description":"x"}' '{"id":"ga-s","title":"t","description":"x","labels":"lane:kimi"}' '{"id":"ga-s","title":"t","description":"x","labels":[1]}' 'isto-nao-e-json' '[1]'; do
  r=$(run_screen "$bj"); [ "$r" = "ilegivel" ] && ok "ilegivel ← $bj" || bad "$bj: esperava ilegivel, veio '$r'"
done

echo "── triagem dos comentários (unidade): sem comentário é ok, termo barra, o que não se lê espera"
run_cscreen() { ( set -euo pipefail; PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK; GC_CITY="$WORK/city"; PILOT_NODE_FIRST_VETO_LABELS="node:never needs:engine-window exec:manual"; eval "$FUNCS"; _pilot_kimi_screen_comments "$1" ) 2>&1 | tail -1; }
reset; r=$(run_cscreen ga-c0); [ "$r" = ok ] && grep -q 'bd -C .* comments ga-c0 --json' "$CALLS" && ok "sem comentários ([]): ok, lendo com bd comments <id> --json" || bad "sem comentários: '$r' / $(cat "$CALLS" 2>/dev/null)"
reset; cset ga-c0 "$(cj 'rodei o selftest, passou em 82 casos')"; r=$(run_cscreen ga-c0); [ "$r" = ok ] && ok "comentário limpo: ok" || bad "comentário limpo: '$r'"
for pair in 'cpf|o CPF do Zezinho' 'telefone|liga no WhatsApp dele' 'email|manda para fulano@exemplo.com.br' 'numero-longo|conta 12345678901'; do
  reset; cset ga-c0 "$(cj "${pair#*|}")"; r=$(run_cscreen ga-c0); [ "$r" = "piic:${pair%%|*}" ] && ok "piic:${pair%%|*} ← comentário '${pair#*|}'" || bad "comentário '${pair#*|}': esperava piic:${pair%%|*}, veio '$r'"
done
reset; cset ga-c0 '[{"text":"tudo certo"},{"text":"ok"},{"text":"a lista de leads vai junto"}]'; r=$(run_cscreen ga-c0); [ "$r" = "piic:lead" ] && ok "o termo no ÚLTIMO de vários comentários também barra" || bad "vários comentários: '$r'"
reset; cset ga-c0 "$(cj "$(printf 'o proprieta\xcc\x81rio do lote')")"; r=$(run_cscreen ga-c0); [ "$r" = "piic:proprietario" ] && ok "acento decomposto (NFD) no comentário também casa" || bad "NFD no comentário: '$r'"
reset; printf '%s' 'comments ga-c0' > "$WORK/bd.fail.on"; r=$(run_cscreen ga-c0); [ "$r" = ilegivel ] && ok "bd comments que falha: ilegivel (nunca ok)" || bad "leitura que falha: '$r'"
reset; : > "$WORK/comments.ga-c0"; r=$(run_cscreen ga-c0); [ "$r" = ilegivel ] && ok "bd comments que sai 0 sem imprimir nada: ilegivel (vazio não é '[]')" || bad "saída vazia: '$r'"
run_cscreen_stub() { ( set -euo pipefail; PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK; GC_CITY="$WORK/city"; eval "$FUNCS"; _pilot_kimi_screen() { printf '%s' "$KL_STUB"; }; _pilot_kimi_screen_comments "$1" ) 2>&1 | tail -1; }
for w in ilegivel sem-texto veto:node:never ''; do
  reset; r=$(KL_STUB="$w" run_cscreen_stub ga-c0); [ "$r" = ilegivel ] && ok "a triagem do texto respondeu '${w:-<vazio>}': nos comentários vira ilegivel (só ok e pii: têm significado)" || bad "resposta '$w' da triagem: esperava ilegivel, veio '$r'"
done
for cj_bad in '{"a":1}' '[1]' '[{"text":5}]' '[{"id":"1"}]' '[{"text":null}]' 'isto-nao-e-json'; do
  reset; cset ga-c0 "$cj_bad"; r=$(run_cscreen ga-c0); [ "$r" = ilegivel ] && ok "ilegivel ← $cj_bad" || bad "$cj_bad: esperava ilegivel, veio '$r'"
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
[ ! -s "$DCALLS" ] && [ ! -s "$CALLS" ] && grep -q 'wa-p9 espera' "$LINES" && ok "bead de outro rig: não é triada nem escrita (semana 1: só HQ), apenas espera: nenhuma chamada ao bd nem ao gc" || bad "outro rig: $(cat "$CALLS" "$LINES" 2>/dev/null)"
echo "── triagem dos comentários (passada): um comentário com termo rebaixa; o que não se lê espera"
C1=$(b ga-c1 "lane:kimi" kimi-lane); C2=$(b ga-c2 "lane:kimi"); C3=$(b ga-c3 "lane:kimi"); C4=$(b ga-c4 "lane:kimi"); C5=$(b ga-c5 "lane:kimi"); WC=$(b wa-c9 "lane:kimi" wa-worker)
reset; on; cset ga-c1 "$(cj 'a CPF do Zezinho está na planilha')"; r=$(run_pass "[$C1,$C2]" "[]")
[ "$(cat "$DCALLS" 2>/dev/null)" = "ga-c2 lane=small kimi=1" ] && grep -q 'update ga-c1 --remove-label lane:kimi --set-metadata gc.routed_to=gastown.dog -q' "$CALLS" && ok "termo num COMENTÁRIO: a bead é rebaixada (rótulo e rota) e só a limpa (ga-c2) vai a dispatch_one" || bad "comentário com termo: '$r' / $(cat "$DCALLS" "$CALLS" 2>/dev/null)"
grep -q 'comment ga-c1 .*termo .cpf. nos comentários' "$CALLS" && ! grep -q 'comment ga-c1 .*Zezinho' "$CALLS" && grep -q 'rebaixadas=1 (falhas 0)' "$LINES" && ok "o comentário na bead diz o NOME do termo e que foi nos comentários; não copia o trecho" || bad "comentário de rebaixo: $(grep ' comment ' "$CALLS")"
grep -q 'bd -C .* comments ga-c2 --json' "$CALLS" && ok "a bead que passou no JSON tem os comentários lidos (uma leitura por bead)" || bad "sem leitura dos comentários de ga-c2: $(cat "$CALLS")"
reset; on; r=$(run_pass "[$V1,$P1,$E1,$X1,$WC]" "[]")
! grep -q ' comments ' "$CALLS" && ok "veto, termo, sem texto, campo ilegível e bead de outro rig: nenhuma leitura de comentário (já decididas ou fora do HQ)" || bad "leu comentários à toa: $(grep ' comments ' "$CALLS")"
reset; cset ga-c1 "$(cj 'a CPF do Zezinho')"; r=$(run_pass "[$C1]" "[]")
grep -q 'update ga-c1 --remove-label lane:kimi' "$CALLS" && grep -q 'fechada:off' "$LINES" && ok "faixa FECHADA: o comentário com termo rebaixa do mesmo jeito" || bad "faixa fechada, comentário: $(cat "$CALLS" "$LINES" 2>/dev/null)"
reset; on; cset ga-c1 "$(cj 'a CPF do Zezinho')"; r=$(KL_DRY=1 run_pass "[$C1,$C2]" "[]")
[ ! -s "$DCALLS" ] && [ "$(writes)" = 0 ] && grep -q 'ga-c1 seria rebaixada (dry-run, nada escrito) — a triagem de dado pessoal casou com o termo .cpf. nos comentários' "$LINES" && ok "DRY_RUN: lê os comentários, diz o que rebaixaria e não escreve nem despacha" || bad "DRY_RUN com comentário: writes=$(writes) $(cat "$LINES" "$CALLS" 2>/dev/null)"
reset; on; printf '%s' 'comments ga-c3' > "$WORK/bd.fail.on"; r=$(run_pass "[$C3,$C2]" "[]")
[ "$(cat "$DCALLS" 2>/dev/null)" = "ga-c2 lane=small kimi=1" ] && ! grep -q 'remove-label' "$CALLS" && grep -q "ga-c3 espera — triagem 'ilegivel'" "$LINES" && grep -q 'esperando a triagem=1' "$LINES" && ok "leitura dos comentários que falha: a bead ESPERA (não vai ao Kimi, não é rebaixada); só ga-c2 vai" || bad "leitura que falha: '$r' / $(cat "$DCALLS" "$LINES" "$CALLS" 2>/dev/null)"
grep -q 'update ga-c3 --set-metadata gc.routed_to=kimi-lane' "$CALLS" && ok "…e a que espera é carimbada (não cai numa pista Claude por falta de rota)" || bad "ga-c3 sem carimbo: $(grep ga-c3 "$CALLS")"
reset; on; : > "$WORK/comments.ga-c4"; cset ga-c5 '{"a":1}'; r=$(run_pass "[$C4,$C5,$C2]" "[]")
[ "$(cat "$DCALLS" 2>/dev/null)" = "ga-c2 lane=small kimi=1" ] && ! grep -q 'remove-label' "$CALLS" && grep -q 'esperando a triagem=2' "$LINES" && ok "saída vazia (rc 0) ou lista que não é lista: as duas esperam, só ga-c2 vai" || bad "vazio/não-lista: '$r' / $(cat "$DCALLS" "$LINES" 2>/dev/null)"
PASSFN="$(fn_src _pilot_kimi_lane_pass "$DISPATCHER")"
pl() { printf '%s\n' "$PASSFN" | grep -nF -- "$1" | head -1 | cut -d: -f1; }
l_sc=$(pl '_kl_verdict=$(_pilot_kimi_screen "$_kl_bead")'); l_cm=$(pl '_kl_verdict=$(_pilot_kimi_screen_comments "$_kl_id")'); l_st=$(pl '--set-metadata "gc.routed_to=$PILOT_KIMI_ROUTE"'); l_dr=$(pl 'if [ "${DRY_RUN:-0}" = "1" ]; then'); l_dm=$(pl 'elif _pilot_kimi_demote "$_kl_bead" "$_kl_why"; then'); l_dp=$(pl 'dispatch_one "$_kl_pick"')
{ [ -n "$l_sc" ] && [ -n "$l_cm" ] && [ -n "$l_st" ] && [ -n "$l_dp" ] && [ "$l_sc" -lt "$l_cm" ] && [ "$l_cm" -lt "$l_st" ] && [ "$l_st" -lt "$l_dp" ]; } && ok "a triagem (JSON, depois os comentários) roda antes do carimbo e do despacho" || bad "ordem da passada (triagem=$l_sc comentários=$l_cm carimbo=$l_st despacho=$l_dp)"
{ [ -n "$l_dr" ] && [ -n "$l_dm" ] && [ "$l_dr" -lt "$l_dm" ]; } && ok "o teste do DRY_RUN vem antes do rebaixamento" || bad "DRY_RUN depois do rebaixamento (dry=$l_dr rebaixa=$l_dm)"

echo "── espera de propósito não é parada (rodada 2, bloqueante 1): o predicado de saturação e o Step 5 REAIS"
# O que o gate achou: a bead lane:kimi que espera de propósito (faixa fechada, vaga ocupada, triagem, outro rig) tirava a pool do "sem candidatos" mas nada a contava como espera; com dispatched=0 e vaga livre o
# Step 5 somava um sweep parado e, a cada 3º, mandava o p4 "Pilot estagnado" (15 min) — e o imparavel-check, que só se cala com o marcador POOL-SATURATED, a leria como fila parada.
# Aqui roda o predicado e o Step 5 VERBATIM, com o estado do streak já em 2 (o próximo sweep seria o 3º, o que toca).
r=$(run_step5 2 KIMI_LANE_WAITING=1)
[ "$r" = "sat=1 estado=none notify=0" ] && ok "UMA lane:kimi esperando e mais nada: saturado (espera, não parada) — o streak zera e o 'Pilot estagnado' NÃO toca" || bad "lane:kimi esperando, streak 2: '$r' (esperado 'sat=1 estado=none notify=0')"
r=$(run_step5 5 KIMI_LANE_WAITING=4)
[ "$r" = "sat=1 estado=none notify=0" ] && ok "…também no 6º sweep seguido, com 4 esperando (o toque de 15 em 15 min não volta)" || bad "4 esperando, streak 5: '$r'"
r=$(run_step5 2 NONQUEUE_FAILS=1)
[ "$r" = "sat=0 estado=3 notify=1" ] && ok "CONTROLE: um candidato comum que não despachou (NONQUEUE_FAILS) continua somando o streak e tocando no 3º — o gate do Step 5 foi mesmo alcançado" || bad "controle sem espera: '$r' (esperado 'sat=0 estado=3 notify=1')"
r=$(run_step5 2 KIMI_LANE_WAITING=1 NONQUEUE_FAILS=1)
[ "$r" = "sat=0 estado=3 notify=1" ] && ok "espera + uma falha de verdade no mesmo sweep: NÃO é saturado — a falha segue contada e o alarme toca (a espera não a esconde)" || bad "espera + falha: '$r'"
r=$(run_step5 2 KIMI_LANE_WAITING=1 DISPATCHED=1)
[ "$r" = "sat=0 estado=none notify=0" ] && ok "espera + um despacho: não é saturado e o streak zera pelo caminho de sempre (despachou)" || bad "espera + despacho: '$r'"
r=$(run_step5 2 KIMI_LANE_WAITING=x)
[ "$r" = "sat=0 estado=3 notify=1" ] && ok "contador que não é número: NÃO isenta o sweep (uma conta que não li nunca vira 'espera de propósito')" || bad "contador ilegível: '$r'"
r=$(run_step5 2 KIMI_LANE_WAITING=08)
[ "$r" = "sat=1 estado=none notify=0" ] && ok "contador com zero à esquerda (08) é lido como decimal, não como octal inválido" || bad "contador 08: '$r'"
r=$(run_step5 2 'unset KIMI_LANE_WAITING')
[ "$r" = "sat=0 estado=3 notify=1" ] && ok "contador ausente: vale 0 (sem erro com set -u) e o sweep parado conta como antes" || bad "contador ausente: '$r'"
r=$(run_step5 2 POOL_CAP_QUEUED=2)
[ "$r" = "sat=1 estado=none notify=0" ] && ok "CONTROLE: fila de teto de pool (ga-in9ebr) segue saturada como antes" || bad "controle teto de pool: '$r'"
r=$(run_step5 2 PRIORITY_YIELDED=1)
[ "$r" = "sat=1 estado=none notify=0" ] && ok "CONTROLE: cessão a P0/P1 (ga-5fn5p3) segue saturada como antes" || bad "controle cessão: '$r'"
# o marcador que o imparavel-check lê ("ga-in9ebr: POOL-SATURATED sweep") sai igual quando a causa é a fila de teto, e nomeia a espera da faixa Kimi quando ela é parte da causa
run_step5 2 KIMI_LANE_WAITING=3 >/dev/null; m=$(grep 'ga-in9ebr: POOL-SATURATED sweep' "$WORK/step5.log" 2>/dev/null)
case "$m" in "ga-in9ebr: POOL-SATURATED sweep — dispatched=0 only because 0 candidate(s) are queued behind full worker capacity and 3 lane:kimi bead(s) wait on purpose in the Kimi lane"*"(backpressure, not a stall).") ok "o marcador POOL-SATURATED (o que o imparavel-check lê) sai com o mesmo prefixo e nomeia as 3 lane:kimi que esperam" ;; *) bad "marcador com espera da faixa: '$m'" ;; esac
run_step5 2 POOL_CAP_QUEUED=2 >/dev/null; m=$(grep 'ga-in9ebr: POOL-SATURATED sweep' "$WORK/step5.log" 2>/dev/null)
[ "$m" = "ga-in9ebr: POOL-SATURATED sweep — dispatched=0 only because 2 candidate(s) are queued behind full worker capacity (backpressure, not a stall)." ] && ok "CONTROLE: sem lane:kimi esperando o marcador sai BYTE A BYTE como antes (o que o imparavel-check e os outros selftests leem não muda)" || bad "marcador sem a faixa Kimi mudou: '$m'"
run_step5 2 NONQUEUE_FAILS=1 >/dev/null; ! grep -q 'POOL-SATURATED' "$WORK/step5.log" 2>/dev/null && ok "CONTROLE: sweep que não é saturado não escreve o marcador" || bad "marcador escrito num sweep não saturado: $(cat "$WORK/step5.log")"

echo "── passada: o que a passada deixa para o predicado — espera (KIMI_LANE_WAITING) e falha (NONQUEUE_FAILS) separadas"
cnt() { cat "$WORK/pass.counters" 2>/dev/null || echo "sem-arquivo"; }
reset; r=$(run_pass "[$K1]" "[]"); c=$(cnt)
[ "$c" = "waiting=1 nqf=0" ] && ok "faixa FECHADA com uma bead limpa: 1 espera, 0 falhas" || bad "fechada: '$c'"
reset; on; r=$(run_pass "[$K1]" "[]"); c=$(cnt)
[ "$c" = "waiting=0 nqf=0" ] && ok "aberta e despachada: nada esperando, nenhuma falha" || bad "despachada: '$c'"
reset; on; r=$(KL_DRC=1 KL_DRES=kimi_lane_wait run_pass "[$K1,$K2]" "[]"); c=$(cnt)
[ "$c" = "waiting=2 nqf=0" ] && ok "vaga ocupada (kimi_lane_wait): as 2 esperam (a que tentou e a que nem tentou), 0 falhas" || bad "vaga ocupada: '$c'"
reset; on; r=$(KL_DRC=1 KL_DRES=kimi_lane_released run_pass "[$K1]" "[]"); c=$(cnt)
[ "$c" = "waiting=1 nqf=0" ] && ok "solta (kimi_lane_released): espera, 0 falhas" || bad "solta: '$c'"
reset; on; r=$(run_pass "[$KW]" "[]"); c=$(cnt)
[ "$c" = "waiting=1 nqf=0" ] && ok "bead de outro rig (semana 1: só HQ): espera, 0 falhas" || bad "outro rig: '$c'"
reset; on; r=$(run_pass "[$E1]" "[]"); c=$(cnt)
[ "$c" = "waiting=1 nqf=0" ] && ok "sem texto (descrição vazia): espera na triagem, 0 falhas" || bad "sem-texto: '$c'"
reset; on; r=$(run_pass "[$N1]" "[]"); c=$(cnt)
[ "$c" = "waiting=0 nqf=0" ] && ok "sem lane:kimi: nada esperando, nenhuma falha" || bad "sem lane:kimi: '$c'"
echo "   …e o que é FALHA do nó ou da passada não vira espera: soma em NONQUEUE_FAILS, que desliga a isenção"
reset; on; r=$(KL_DRC=1 KL_DRES=kimi_lane_failed run_pass "[$K1,$K2]" "[]"); c=$(cnt)
[ "$c" = "waiting=2 nqf=1" ] && [ "$(grep -c . "$DCALLS")" = 1 ] && ok "kimi_lane_failed (atribuição, sessão ou aviso falhou): 1 falha e a passada para" || bad "kimi_lane_failed: '$c' tentativas=$(grep -c . "$DCALLS" 2>/dev/null)"
reset; on; r=$(KL_DRC=1 KL_DRES=node_rollback_unconfirmed run_pass "[$K1]" "[]"); c=$(cnt)
[ "$c" = "waiting=1 nqf=1" ] && ok "desfazer sem confirmar (node_rollback_unconfirmed): 1 falha" || bad "node_rollback_unconfirmed: '$c'"
reset; on; r=$(KL_DRC=1 KL_DRES= run_pass "[$K1]" "[]"); c=$(cnt)
[ "$c" = "waiting=1 nqf=1" ] && ok "dispatch_one que falha SEM nome: é falha, não espera (o que não sei dizer não é isento)" || bad "falha sem nome: '$c'"
reset; on; cset ga-c3 "$(cj 'ok')"; printf '%s' 'comments ga-c3' > "$WORK/bd.fail.on"; r=$(run_pass "[$C3]" "[]"); c=$(cnt)
[ "$c" = "waiting=1 nqf=1" ] && ok "triagem ilegível (leitura dos comentários falhou): 1 falha — não parece espera calma" || bad "ilegível: '$c'"
reset; on; printf '%s' '--remove-label' > "$WORK/bd.fail.on"; r=$(run_pass "[$V1]" "[]"); c=$(cnt)
[ "$c" = "waiting=1 nqf=1" ] && ok "rebaixamento que não gravou: 1 falha" || bad "rebaixamento que falha: '$c'"
reset; printf '%s' 'gc.routed_to=kimi-lane' > "$WORK/bd.fail.on"; r=$(run_pass "[$K1]" "[]"); c=$(cnt)
[ "$c" = "waiting=1 nqf=1" ] && ok "carimbo que não gravou: 1 falha" || bad "carimbo que falha: '$c'"
reset; r=$(KL_JQFAIL=1 run_pass "[$K1]" "[]"); c=$(cnt)
[ "$c" = "waiting=1 nqf=1" ] && ok "lista do carimbo que não se leu: 1 falha" || bad "lista do carimbo: '$c'"

echo "── kimi_lane_failed: falha do nó ≠ espera de propósito (rodada 2, não bloqueante: o mesmo nome cobria os dois)"
reset; sess; echo 1 > "$WORK/gc.new.rc"; r=$(run_kd); f=$(cat "$WORK/kd.fault" 2>/dev/null)
[ "$r" = "res=mini alias=" ] && [ "$f" = "fault=1" ] && ok "a sessão não abriu: nada ficou escrito (mini) e a falha é marcada (fault=1)" || bad "sessão que não abre: '$r' '$f'"
reset; sess; echo 1 > "$WORK/gc.nudge.rc"; r=$(run_kd); f=$(cat "$WORK/kd.fault" 2>/dev/null)
[ "$r" = "res=mini alias=" ] && [ "$f" = "fault=1" ] && ok "o aviso falhou: falha marcada" || bad "aviso que falha: '$r' '$f'"
reset; sess; printf '%s' 'update ga-k1 --assignee' > "$WORK/bd.fail.on"; r=$(run_kd); f=$(cat "$WORK/kd.fault" 2>/dev/null)
[ "$r" = "res=mini alias=" ] && [ "$f" = "fault=1" ] && ok "a atribuição falhou: falha marcada" || bad "atribuição que falha: '$r' '$f'"
reset; sess kimi-worker-remote-1:active; r=$(run_kd); f=$(cat "$WORK/kd.fault" 2>/dev/null)
[ "$r" = "res=mini alias=" ] && [ "$f" = "fault=0" ] && ok "vaga ocupada: espera de propósito, SEM falha" || bad "vaga ocupada: '$r' '$f'"
reset; echo 1 > "$WORK/gc.list.rc"; r=$(run_kd); f=$(cat "$WORK/kd.fault" 2>/dev/null)
[ "$r" = "res=mini alias=" ] && [ "$f" = "fault=1" ] && ok "lista de sessões que não se leu (gc session list falhou): sem vaga e nada escrito, mas é FALHA — 'não consegui ler' não é 'a vaga está ocupada'" || bad "lista ilegível: '$r' '$f'"
reset; printf '%s\n' '{"sessions":"nao-e-lista"}' > "$WORK/sessions.json"; r=$(run_kd); f=$(cat "$WORK/kd.fault" 2>/dev/null)
[ "$r" = "res=mini alias=" ] && [ "$f" = "fault=1" ] && ok "lista de sessões que não é uma lista: sem vaga e FALHA (mesma família)" || bad "lista que não é lista: '$r' '$f'"
reset; sess; r=$(KD_JQFAIL=1 run_kd); f=$(cat "$WORK/kd.fault" 2>/dev/null)
[ "$r" = "res=mini alias=" ] && [ "$f" = "fault=1" ] && ok "a escolha da vaga que não rende (jq morreu): sem vaga e FALHA (mesma família)" || bad "jq da vaga que falha: '$r' '$f'"
reset; sess kimi-worker-remote-1:active; r=$(run_kd); f=$(cat "$WORK/kd.fault" 2>/dev/null)
[ "$r" = "res=mini alias=" ] && [ "$f" = "fault=0" ] && ok "CONTROLE: lista lida e vaga ocupada continua espera de propósito (fault=0)" || bad "controle vaga ocupada: '$r' '$f'"
reset; sess; r=$(run_kd); f=$(cat "$WORK/kd.fault" 2>/dev/null)
[ "$r" = "res=node alias=kimi-worker-remote-1" ] && [ "$f" = "fault=0" ] && ok "despacho que deu certo: sem falha" || bad "despacho certo: '$r' '$f'"
KB="$(awk '/^  if \[ "\$\{_PILOT_KIMI_PASS:-0\}" = "1" \]; then/{f=1} f{print} f&&/^  fi$/{exit}' "$DISPATCHER")"
printf '%s\n' "$KB" | grep -qF 'if [ "${_PKL_FAULT:-0}" = "1" ]; then DISPATCH_RESULT="kimi_lane_failed"; else DISPATCH_RESULT="kimi_lane_wait"; fi' && ok "dispatch_one: o bloco da faixa devolve kimi_lane_failed quando _PKL_FAULT=1 e kimi_lane_wait quando não" || bad "bloco da faixa em dispatch_one sem os dois nomes: $(printf '%s\n' "$KB" | cut -c1-160)"

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
  mutant "sem vaga e segue tentando" pilot 'kimi_lane_wait|node_rollback_unconfirmed) _kl_stop=' 'nunca) _kl_stop='
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
  mutant "ilegível passa (campo)" pilot "pii:*) printf '%s' \"\$_ks_out\" ;; *) printf 'ilegivel' ;; esac" "pii:*) printf '%s' \"\$_ks_out\" ;; *) printf 'ok' ;; esac"
  mutant "ilegível passa (rótulos)" pilot "else error(\"labels\") end' 2>/dev/null) || { printf 'ilegivel'; return 0; }" "else error(\"labels\") end' 2>/dev/null) || { printf 'ok'; return 0; }"
  mutant "palavra desconhecida da triagem passa nos comentários" pilot "\"\${_kc_v#pii:}\" ;; *) printf 'ilegivel' ;; esac" "\"\${_kc_v#pii:}\" ;; *) printf 'ok' ;; esac"
  for t in cpf telefone conversa lead proprietario 'chip/frota' pipedrive email dado-pessoal 'shared/data' numero-longo; do
    row=$(grep -F "[\"$t\", \"" "$DISPATCHER" | head -1 | sed 's/^ *//; s/,$//')
    mutant "termo '$t' ignorado" pilot "$row" "[\"$t\", \"(?!x)x\"]"
  done
  for alt in '\\b\\d{10,}\\b|' '\\b\\d{2}[\\s.]?\\d{3}[\\s.]?\\d{3}[\\s./-]?\\d{4}[\\s-]?\\d{2}\\b|' '\\b\\d{3}[\\s.-]?\\d{3}[\\s.-]?\\d{3}[\\s.-]?\\d{2}\\b|' '\\b0?\\d{2}[\\s.-]?9?[\\s.-]?\\d{4}[\\s.-]?\\d{4}\\b|' '\\b9[\\s.-]?\\d{4}[\\s.-]\\d{4}\\b|' '|\\b[2-5]\\d{3}[\\s.-]\\d{4}\\b'; do
    mutant "número longo sem a forma '$alt'" pilot "$alt" ""
  done
  for t in lead 'chip/frota'; do
    row=$(grep -F "[\"$t\", \"" "$DISPATCHER" | head -1 | sed 's/^ *//; s/,$//')
    mutant "termo '$t' sem fronteira de palavra" pilot "$row" "${row//'\\b'/}"
  done
  mutant "a triagem não roda" pilot '_kl_verdict=$(_pilot_kimi_screen "$_kl_bead")' '_kl_verdict=ok'
  mutant "os comentários não são triados" pilot '[ "$_kl_verdict" != ok ] || _kl_verdict=$(_pilot_kimi_screen_comments "$_kl_id")' ':'
  mutant "piic não rebaixa" pilot 'veto:*|pii:*|piic:*)' 'veto:*|pii:*)'
  mutant "leitura de comentários que falha conta como ok" pilot "comments \"\$_kc_id\" --json 2>/dev/null) || { printf 'ilegivel'; return 0; }" "comments \"\$_kc_id\" --json 2>/dev/null) || { printf 'ok'; return 0; }"
  mutant "saída vazia dos comentários conta como ok" pilot "[ -n \"\$_kc_json\" ] || { printf 'ilegivel'; return 0; }" "[ -n \"\$_kc_json\" ] || _kc_json='[]'"
  mutant "comentários que não são lista passam" pilot 'else error("comments") end' 'else "" end'
  mutant "comentário com text que não é texto passa" pilot 'all(.[]; (.text | type) == "string")' 'all(.[]; true)'
  mutant "termo do comentário não vira piic" pilot "pii:*) printf 'piic:%s' \"\${_kc_v#pii:}\"" "pii:*) printf 'ok'"
  mutant "sem texto é despachada" pilot '        ok|fora-do-hq)' '        ok|fora-do-hq|sem-texto|ilegivel)'
  mutant "rebaixamento sem tirar o rótulo" pilot '_dm_args=(--remove-label lane:kimi)' '_dm_args=(-q)'
  mutant "rebaixamento sem devolver a rota" pilot 'if [ "$_dm_route" = "$PILOT_KIMI_ROUTE" ]; then _dm_args+=' 'if false; then _dm_args+='
  mutant "rebaixamento escreve no DRY_RUN" pilot '          if [ "${DRY_RUN:-0}" = "1" ]; then
            log "  faixa Kimi: $_kl_id seria rebaixada' '          if false; then
            log "  faixa Kimi: $_kl_id seria rebaixada'
  mutant "rebaixamento que falha conta como feito" pilot 'elif _pilot_kimi_demote "$_kl_bead" "$_kl_why"; then' 'elif true; then'
  mutant "as que esperam não são carimbadas" pilot "printf '%s\\n%s\\n%s' \"\$_kl_small\" \"\$_kl_big\" \"\$_kl_held\"" "printf '%s\\n%s\\n%s' \"\$_kl_small\" \"\$_kl_big\" '[]'"
  mutant "gate não aplica a faixa no FAIL" gate '        _GFAIL_ROUTE=$(gate_kimi_lane_route "$_GFAIL_LANE_LABELS" "$_GFAIL_ROUTE")' '        :'
  mutant "gate: cache vazio não relê" gate '  [ -n "$_gl" ] || _gl=$(gate_lane_labels_from_show "$(bd -C "${1:-}" show "${2:-}" --json 2>/dev/null || true)")' '  :'
  mutant "gate: rótulo que não se leu conta como lido" gate '  [ -n "$_gl" ] || return 1' '  :'
  mutant "gate: sem aviso quando não leu os rótulos" gate 'warn "  ga-do1ixn.3: não consegui ler os rótulos de $BEAD_ID' ': "  ga-do1ixn.3: não consegui ler os rótulos de $BEAD_ID'
  mutant "gate: sem nota de rótulos não lidos" gate '_GFAIL_LANE_NOTE=" NOTE: os rótulos da bead não foram lidos' '_GFAIL_LANE_NOTE_X=" NOTE: os rótulos da bead não foram lidos'
  mutant "gate: comentário do FAIL sem a nota" gate '$_GFAIL_ROUTE_UNKNOWN_NOTE$_GFAIL_LANE_NOTE' '$_GFAIL_ROUTE_UNKNOWN_NOTE'
  mutant "gate: rótulos que não são texto passam" gate 'if all(.[]; type=="string") then join(" ") else empty end' 'join(" ")'
  mutant "a passada não nota o que dispatch_one devolveu" pilot '        _pilot_sweep_note "$_kl_id" "$_kl_rc" "${DISPATCH_RESULT:-}"' '        :'
  mutant "a despachada não é notada" pilot '_pilot_sweep_note "$_kl_id" 0 "${DISPATCH_RESULT:-}"; break' 'break'
  mutant "solta gasta uma das 3 tentativas" pilot 'kimi_lane_released) _kl_tries=$((_kl_tries - 1)); _kl_rel=$((_kl_rel + 1)) ;;' 'kimi_lane_released) _kl_rel=$((_kl_rel + 1)) ;;'
  mutant "soltas sem teto" pilot '[ "$_kl_rel" -lt "$_kl_rel_max" ] || { _kl_stop="soltas"; break; }' ':'
  mutant "solta não é contada" pilot 'kimi_lane_released) _kl_tries=$((_kl_tries - 1)); _kl_rel=$((_kl_rel + 1)) ;;' 'kimi_lane_released) _kl_tries=$((_kl_tries - 1)) ;;'
  mutant "lista do carimbo que falha parece 'nada a carimbar'" pilot '_kl_ids=""; _kl_idsfail=1' '_kl_ids=""'
  mutant "lista do carimbo que falha sem aviso" pilot 'warn "ga-do1ixn.3: faixa Kimi: não consegui ler quais beads precisam do carimbo' ': "ga-do1ixn.3: faixa Kimi: não consegui ler quais beads precisam do carimbo'
  mutant "o log promete 'nenhuma vai a pool Claude'" pilot 'o Pilot não despacha nenhuma a pool Claude; uma rota de pool posta por fora (gastown.dog) vale até o carimbo desta passada' 'nenhuma vai a pool Claude'
  mutant "a bead de outro rig é triada" pilot '        ga-*)
          _kl_verdict=$(_pilot_kimi_screen "$_kl_bead")' '        *)
          _kl_verdict=$(_pilot_kimi_screen "$_kl_bead")'
  mutant "telefone sem a forma (DD) com 9 solto" pilot '|\\(\\d{2}\\)\\s*9?[\\s.-]?\\d{4}[\\s.-]?\\d{4}' ''
  mutant "telefone sem a forma +55 com parêntese" pilot '|\\+\\s?55\\s?\\(?\\d{2}\\)?' ''
  mutant "travessão e hífen Unicode não valem como hífen" pilot ' | gsub("[\u2010-\u2015\u2212\uFF0D]"; "-")' ''
  echo "   …rodada 2 (espera de propósito não é parada)"
  mutant "predicado ignora a espera da faixa" pilot '${PRIORITY_YIELDED:-0} + _kimi_wait_n )) -gt 0 ]' '${PRIORITY_YIELDED:-0} )) -gt 0 ]'
  mutant "contador ilegível isenta o sweep" pilot "case \"\$_kimi_wait_n\" in ''|*[!0-9]*) _kimi_wait_n=0 ;;" "case \"\$_kimi_wait_n\" in ''|*[!0-9]*) _kimi_wait_n=1 ;;"
  mutant "zero à esquerda lido como octal" pilot '*) _kimi_wait_n=$((10#$_kimi_wait_n)) ;; esac' '*) : ;; esac'
  mutant "a isenção vale com falha no sweep" pilot '_kimi_wait_n )) -gt 0 ] && [ "${NONQUEUE_FAILS:-0}" -eq 0 ]; then' '_kimi_wait_n )) -gt 0 ]; then'
  mutant "a isenção vale com despacho" pilot 'if [ "$DISPATCHED" -eq "0" ] && [ $(( ${POOL_CAP_QUEUED:-0} + ${PRIORITY_YIELDED:-0} + _kimi_wait_n ))' 'if [ $(( ${POOL_CAP_QUEUED:-0} + ${PRIORITY_YIELDED:-0} + _kimi_wait_n ))'
  mutant "marcador POOL-SATURATED sem a espera da faixa" pilot '${_py_sat_note}${_kl_sat_note} (backpressure' '${_py_sat_note} (backpressure'
  mutant "a passada não conta a espera" pilot 'KIMI_LANE_WAITING=$((_kl_n - _kl_sent))' 'KIMI_LANE_WAITING=0'
  mutant "a passada não soma nenhuma falha" pilot 'NONQUEUE_FAILS=$(( ${NONQUEUE_FAILS:-0} + _kl_demfail + _kl_stampfail + _kl_idsfail + _kl_unread + _kl_dfault ))' 'NONQUEUE_FAILS=${NONQUEUE_FAILS:-0}'
  mutant "rebaixamento que falha não soma" pilot '+ _kl_demfail + _kl_stampfail' '+ _kl_stampfail'
  mutant "carimbo que falha não soma" pilot '+ _kl_stampfail + _kl_idsfail' '+ _kl_idsfail'
  mutant "lista do carimbo ilegível não soma" pilot '+ _kl_idsfail + _kl_unread' '+ _kl_unread'
  mutant "triagem ilegível não soma" pilot '+ _kl_unread + _kl_dfault ))' '+ _kl_dfault ))'
  mutant "falha do despacho não soma" pilot '+ _kl_unread + _kl_dfault ))' '+ _kl_unread ))'
  mutant "triagem ilegível conta como sem-texto" pilot '[ "$_kl_verdict" = sem-texto ] || _kl_unread=$((_kl_unread + 1))' ':'
  mutant "retorno sem nome conta como espera" pilot 'kimi_lane_wait|kimi_lane_released) ;; *) _kl_dfault=$((_kl_dfault + 1)) ;; esac' '*) ;; esac'
  mutant "kimi_lane_failed não para a passada" pilot 'kimi_lane_wait|kimi_lane_failed|node_rollback_unconfirmed) _kl_stop=' 'kimi_lane_wait|node_rollback_unconfirmed) _kl_stop='
  mutant "falha do nó sai com o nome da espera" pilot 'if [ "${_PKL_FAULT:-0}" = "1" ]; then DISPATCH_RESULT="kimi_lane_failed"; else' 'if false; then DISPATCH_RESULT="kimi_lane_failed"; else'
  mutant "lista de sessões ilegível conta como vaga ocupada" pilot 'if [ "${_PKL_PICK_UNREAD:-0}" = "1" ]; then
      _PKL_FAULT=1' 'if false; then
      _PKL_FAULT=1'
  mutant "gc session list que falha não marca a leitura" pilot 'session list --json) || { _PKL_PICK_UNREAD=1; return 1; }' 'session list --json) || { return 1; }'
  mutant "lista que não é lista não marca a leitura" pilot '>/dev/null 2>&1 || { _PKL_PICK_UNREAD=1; return 1; }' '>/dev/null 2>&1 || return 1'
  mutant "jq da vaga que falha não marca a leitura" pilot "2>/dev/null) || { _PKL_PICK_UNREAD=1; return 1; }" "2>/dev/null) || return 1"
  mutant "a marca de leitura não zera na entrada" pilot '_PKL_ALIAS=""; _PKL_ALIAS_STATE=""; _PKL_PICK_UNREAD=0
  # vazio/falhou' '_PKL_ALIAS=""; _PKL_ALIAS_STATE=""
  # vazio/falhou'
  mutant "falha do nó não é marcada" pilot '    _PKL_FAULT=1
    warn' '    warn'
  mutant "a marca de falha não zera na entrada" pilot '_PNF_RESULT="mini"; _PKL_FAULT=0' '_PNF_RESULT="mini"'
  mutant "metadata story.* fora da triagem" pilot ', .metadata["story.criterios"], .metadata["story.estrela_guia"], .metadata["story.equilibrios"] ] | map(txt)) as $f' '] | map(txt)) as $f'
  mutant "story.criterios fora da triagem" pilot ', .metadata["story.criterios"],' ','
  mutant "story.estrela_guia fora da triagem" pilot ', .metadata["story.estrela_guia"],' ','
  mutant "story.equilibrios fora da triagem" pilot ', .metadata["story.equilibrios"] ]' ' ]'
  mutant "gate: nota da faixa em todo FAIL" gate 'if [ "$_GFAIL_ROUTE" = "kimi-lane" ]; then
          _GFAIL_KIMI_NOTE=' 'if true; then
          _GFAIL_KIMI_NOTE='
  mutant "gate: comentário do FAIL sem a nota da faixa" gate '$_GFAIL_LANE_NOTE$_GFAIL_KIMI_NOTE The Pilot' '$_GFAIL_LANE_NOTE The Pilot'
fi
echo "pilot-dispatcher.kimi-lane selftest: $PASS passed, $FAIL failed"
echo "RESULT $FAIL/$((PASS+FAIL))"
[ "$FAIL" = 0 ]
