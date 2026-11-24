#!/usr/bin/env bash
# pilot-dispatcher.lanes-unmeasured.selftest.sh — ga-d3ryi7k (faixa que o Pilot NÃO conseguiu medir não é faixa CHEIA)
#
# Contents
#   O que prova · Como roda · Controle negativo
#
# O PROBLEMA: em 23/11 23:41 um Dolt isca subiu para as rigs com redirect e toda leitura delas respondeu "database not found". A consulta de story:in-flight falhou, a trava da ga-1fssl
# (inflight_slots_from_query) pôs as DUAS pistas em 0 vaga, e o Pilot saiu em "Both lanes full ... backing off" ANTES da passada do nó (_pilot_wa_node_pass, ga-2hd02v.9): o Hetzner ficou ocioso ~12 h.
# A trava da ga-1fssl está certa para o MINI (contagem que não se leu nunca libera vaga lá); o erro foi chamar o desconhecido de "cheio" e deixar o nó pagar por isso.
#
# O QUE PROVA: (1) inflight_slots_unmeasured (pura): 1 se o que FOI lido deixa folga, 0 se não; número ilegível = 0 (o inerte); a de ga-1fssl continua dando 0 com a consulta falha.
#   (2) _pilot_lanes_unmeasured, EXECUTADA em filho sob `set -euo pipefail`: com PILOT_NODE_FIRST=on fora do DRY_RUN e com a leitura do PRÓPRIO HQ respondendo a varredura vira a passada só-nó
#   (_PILOT_NODE_ONLY=1) com as vagas de sondagem, e SÓ nesse caso; off, shadow, vazio, DRY_RUN, a chave PILOT_LANES_UNMEASURED_NODE_PASS=off, o HQ que não leu (ou o flag dele vazio/nunca posto) ou
#   pista lida como cheia recuam, e dizem "NÃO MEDIDAS", nunca "Both lanes full"; o alarme (notify) sai na 2a varredura
#   seguida e a cada 6a, não a cada varredura; o DRY_RUN não escreve estado nem avisa; contador ilegível recomeça de 0 e AVISA; a recuperação limpa o contador e avisa quando houve alarme.
#   (3) o ponto de chamada, a região VERBATIM do dispatcher: medido e cheio sai com o texto de sempre, byte a byte; não medido + on segue; não medido + off sai SEM chamar a pista de "cheia".
#   (4) a ligação no arquivo real (deriva): a recuperação é chamada, SMALL_SLOTS/BIG_SLOTS seguem vindo de inflight_slots_from_query, o top-up de pool roda ANTES do ponto de chamada.
#   O dispatcher REAL rodando (DRY_RUN=1, bd falso com a consulta de in-flight falhando) está no selftest grande: Scenario ga-d3ryi7k-a/b em pilot-dispatcher.selftest.sh.
# COMO RODA: as funções e a região são extraídas VERBATIM do dispatcher (awk) e rodam em shells filhos com `log`/`warn`/`notify` falsos (selftest-sandbox-path.lib.sh para o PATH). Sem o conserto as
#   asserções reprovam uma a uma. CONTROLE NEGATIVO: LU_NO_MUTANTS=1 pula a bateria de mutantes (cada guarda desligada numa cópia do dispatcher tem que reprovar este arquivo).
# Variáveis: PILOT_DISPATCHER_PATH · LU_NO_MUTANTS=1
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ -n "${LU_MUTANT:-}" ] || echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; [ -z "${LU_MUTANT:-}" ] || { echo "RESULT $FAIL/$((PASS+FAIL))"; exit 1; }; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

# vazio (a função não existe) → texto vazio, e quem usa reprova a asserção; falhou/ilegível → idem, nunca um valor inventado
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
# region <início> <fim> — as linhas de [início, fim) VERBATIM (regex em ENVIRON: o awk -v comeria as barras)
region() { RA="$1" RB="$2" awk 'f==0 && $0 ~ ENVIRON["RA"] {f=1} f==1 && n>0 && $0 ~ ENVIRON["RB"] {exit} f==1 {print; n++}' "$DISPATCHER"; }
FUNC_FROM_QUERY="$(fn_src inflight_slots_from_query)"
FUNC_UNMEAS="$(fn_src inflight_slots_unmeasured)"
FUNC_LU="$(fn_src _pilot_lanes_unmeasured)"
FUNC_CLEAR="$(fn_src _pilot_lanes_unmeasured_clear)"
# a região do ponto de chamada: do bloco que chama a função até o `exit 0` que fecha o recuo (o `fi` seguinte é incluído pelo awk de `region` até a próxima âncora)
BRANCH_SRC="$(region '^# ga-d3ryi7k: the lanes show 0 slots' '^# ga-vdac4cj: from here to the tail of Step 2c')"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-lanes-unmeasured-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/city/.gc"
sandbox_path_init "$WORK" jq date mkdir dirname cat rm || exit 2

echo "pilot-dispatcher.lanes-unmeasured.selftest — ga-d3ryi7k"
echo "── (0) o que o dispatcher tem que trazer"
{ [ -n "$FUNC_FROM_QUERY" ] && [ -n "$FUNC_UNMEAS" ] && [ -n "$FUNC_LU" ] && [ -n "$FUNC_CLEAR" ] && [ -n "$BRANCH_SRC" ]; } \
  && ok "as 3 funções novas e o ponto de chamada estão no dispatcher" \
  || { bad "faltam funções ou o ponto de chamada no dispatcher (unmeasured='${FUNC_UNMEAS:+ok}' lu='${FUNC_LU:+ok}' clear='${FUNC_CLEAR:+ok}' branch='${BRANCH_SRC:+ok}')"; echo; echo "Results: $PASS passed, $FAIL failed"; exit 1; }

# ── (1) a função pura ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "── (1) inflight_slots_unmeasured: 1 se o que foi lido deixa folga, senão 0; ilegível = 0"
eval "$FUNC_FROM_QUERY"; eval "$FUNC_UNMEAS"
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (veio '$2', esperado '$3')"; fi; }
eq "max=3 lido=0 → 1 (sobra mais de 1: o orçamento de sondagem é 1, não 3)" "$(inflight_slots_unmeasured 3 0)" 1
eq "max=3 lido=2 → 1 (sobra exatamente 1)" "$(inflight_slots_unmeasured 3 2)" 1
eq "max=3 lido=3 → 0 (o que se leu já enche a pista)" "$(inflight_slots_unmeasured 3 3)" 0
eq "max=1 lido=5 → 0 (nunca negativo)" "$(inflight_slots_unmeasured 1 5)" 0
eq "max=0 → 0 (pista desligada continua desligada)" "$(inflight_slots_unmeasured 0 0)" 0
eq "max vazio → 0 (não sei o teto: o inerte)" "$(inflight_slots_unmeasured '' 0)" 0
eq "lido vazio → 0 (não sei o que se leu)" "$(inflight_slots_unmeasured 3 '')" 0
eq "lido não numérico → 0" "$(inflight_slots_unmeasured 3 abc)" 0
eq "zero à esquerda não vira octal: max=08 lido=07 → 1" "$(inflight_slots_unmeasured 08 07)" 1
eq "ga-1fssl intacta: a consulta que falhou continua dando 0 vaga NO MINI, qualquer teto" "$(inflight_slots_from_query 0 5 0)" 0

# ── (2) a função, executada ───────────────────────────────────────────────────────────────────────────────────────────────────────────
cat > "$WORK/lu-runner.sh" <<'EOF'
set -euo pipefail
PATH="$SANDBOX_PATH"
log()    { echo "LOG $*"; }
warn()   { echo "WARN $*"; }
notify() { echo "NOTIFY $*" >> "$WORK/notify.calls"; return "${LU_NOTIFY_RC:-0}"; }
eval "$FUNC_UNMEAS"; eval "$FUNC_LU"; eval "$FUNC_CLEAR"
GC_CITY="$WORK/city"
[ -z "${LU_STATE+x}" ] || export PILOT_LANES_UNMEASURED_STATE="$LU_STATE"
MAX_SMALL="${LU_MAX_SMALL-3}"; MAX_BIG="${LU_MAX_BIG-1}"; IN_FLIGHT_SMALL="${LU_IN_SMALL-0}"; IN_FLIGHT_BIG="${LU_IN_BIG-0}"
SMALL_SLOTS=0; BIG_SLOTS=0; _PILOT_NODE_ONLY=0
IN_FLIGHT_HQ_QUERY_OK=1; [ -z "${LU_HQ+x}" ] || IN_FLIGHT_HQ_QUERY_OK="$LU_HQ"; [ -z "${LU_HQ_UNSET+x}" ] || unset IN_FLIGHT_HQ_QUERY_OK
PILOT_NODE_FIRST="${LU_MODE-on}"; DRY_RUN="${LU_DRY:-0}"
[ -z "${LU_SWITCH+x}" ] || PILOT_LANES_UNMEASURED_NODE_PASS="$LU_SWITCH"
[ -z "${LU_AFTER+x}" ] || PILOT_LANES_UNMEASURED_ALERT_AFTER="$LU_AFTER"
[ -z "${LU_EVERY+x}" ] || PILOT_LANES_UNMEASURED_ALERT_EVERY="$LU_EVERY"
rc=0
case "${LU_CALL:-lu}" in
  lu)    _pilot_lanes_unmeasured || rc=$? ;;
  clear) _pilot_lanes_unmeasured_clear || rc=$? ;;
esac
echo "RESULT rc=$rc node_only=$_PILOT_NODE_ONLY small=$SMALL_SLOTS big=$BIG_SLOTS"
EOF
STATE_F="$WORK/city/.gc/pilot-lanes-unmeasured.count"
lu() { # <VAR=valor...> — roda a função num filho e deixa LU_OUT / LU_RC / LU_NODE_ONLY / LU_SMALL / LU_BIG
  LU_OUT="$(env FUNC_UNMEAS="$FUNC_UNMEAS" FUNC_LU="$FUNC_LU" FUNC_CLEAR="$FUNC_CLEAR" SANDBOX_PATH="$SANDBOX_PATH" WORK="$WORK" "$@" bash "$WORK/lu-runner.sh" 2>&1)"
  # só a linha RESULT que o runner imprime: o log da função também diz "small=… big=…" e não pode entrar na conta
  local _res; _res="$(printf '%s\n' "$LU_OUT" | sed -n 's/^RESULT rc=\([0-9]*\) node_only=\([0-9]*\) small=\([0-9]*\) big=\([0-9]*\)$/\1 \2 \3 \4/p')"
  LU_RC="$(printf '%s' "$_res" | cut -d' ' -f1)"; LU_NODE_ONLY="$(printf '%s' "$_res" | cut -d' ' -f2)"
  LU_SMALL="$(printf '%s' "$_res" | cut -d' ' -f3)"; LU_BIG="$(printf '%s' "$_res" | cut -d' ' -f4)"
}
notifies() { [ -f "$WORK/notify.calls" ] && wc -l < "$WORK/notify.calls" | tr -d ' ' || echo 0; }
fresh() { rm -f "$STATE_F" "$WORK/notify.calls"; }
expect_go() { # <desc> <small> <big>
  if [ "$LU_RC" = 0 ] && [ "$LU_NODE_ONLY" = 1 ] && [ "$LU_SMALL" = "$2" ] && [ "$LU_BIG" = "$3" ]; then ok "$1 — segue só-nó, vagas de sondagem small=$LU_SMALL big=$LU_BIG"
  else bad "$1 — esperado rc=0 node_only=1 small=$2 big=$3; veio rc='$LU_RC' node_only='$LU_NODE_ONLY' small='$LU_SMALL' big='$LU_BIG' :: $LU_OUT"; fi
}
expect_back() { # <desc>
  if [ "$LU_RC" = 1 ] && [ "$LU_NODE_ONLY" = 0 ] && [ "$LU_SMALL" = 0 ] && [ "$LU_BIG" = 0 ]; then ok "$1 — recua (rc=1), o mini e a passada só-nó seguem DESLIGADOS"
  else bad "$1 — esperado rc=1 node_only=0 small=0 big=0; veio rc='$LU_RC' node_only='$LU_NODE_ONLY' small='$LU_SMALL' big='$LU_BIG' :: $LU_OUT"; fi
}
says() { printf '%s\n' "$LU_OUT" | grep -q -- "$1"; }

echo "── (2) quando a varredura segue na passada só-nó, e quando recua"
fresh; lu LU_MODE=on
expect_go "PILOT_NODE_FIRST=on, fora do DRY_RUN, pistas com folga" 1 1
says "NÃO MEDIDAS" && ok "diz NÃO MEDIDAS" || bad "o log não diz NÃO MEDIDAS :: $LU_OUT"
says "Both lanes full" && bad "o log chama o desconhecido de 'Both lanes full' :: $LU_OUT" || ok "nunca chama de 'Both lanes full'"
says "só-nó" && ok "diz que a varredura segue na passada só-nó (quem lê o log sabe o que ela faz)" || bad "o log não diz 'só-nó'"
fresh; lu LU_MODE=on LU_IN_SMALL=3 LU_IN_BIG=0
expect_go "small lida como cheia, big com folga: só a big ganha vaga de sondagem" 0 1
fresh; lu LU_MODE=on LU_IN_SMALL=3 LU_IN_BIG=1
expect_back "as duas lidas como cheias (o que se leu basta para dizer 'cheio no mínimo')"
says "NÃO MEDIDAS" && ok "mesmo recuando, diz NÃO MEDIDAS (não 'cheias')" || bad "recuo sem a palavra NÃO MEDIDAS :: $LU_OUT"
for m in off shadow maybe ""; do fresh; lu "LU_MODE=$m"; expect_back "PILOT_NODE_FIRST='${m:-vazio}'"; done
fresh; lu LU_MODE=on LU_DRY=1; expect_back "DRY_RUN=1 (a passada só-nó consulta o nó e grava estado)"
fresh; lu LU_MODE=on LU_SWITCH=off; expect_back "PILOT_LANES_UNMEASURED_NODE_PASS=off (a chave de volta ao recuo de antes)"
fresh; lu LU_MODE=on LU_SWITCH=maybe; expect_back "PILOT_LANES_UNMEASURED_NODE_PASS=maybe (valor que não existe nunca liga a passada)"
fresh; lu LU_MODE=on LU_MAX_SMALL= LU_MAX_BIG=; expect_back "tetos ilegíveis (vazios): não sei quanta folga há, o inerte é recuar"
fresh; lu LU_MODE=on LU_IN_SMALL=abc LU_IN_BIG=abc; expect_back "contagens lidas que não são número: o inerte é recuar"
fresh; lu LU_MODE=on LU_HQ=0
expect_back "a leitura do PRÓPRIO HQ falhou (o Dolt do HQ não responde): não continua, as claims do nó são escritas lá"
says "HQ" && says "NÃO MEDIDAS" && ok "e diz que foi o HQ que não respondeu, sem chamar de 'cheia'" || bad "o recuo por HQ ilegível não diz HQ / NÃO MEDIDAS :: $LU_OUT"
fresh; lu LU_MODE=on LU_HQ=1; expect_go "o HQ respondeu e só uma rig falhou (o caso real de 23/11)" 1 1
fresh; lu LU_MODE=on LU_HQ=; expect_back "o flag do HQ vazio não é 'o HQ respondeu': recua"
fresh; lu LU_MODE=on LU_HQ_UNSET=1; expect_back "o flag do HQ que nunca foi posto não é 'o HQ respondeu': recua (o inerte)"
fresh; lu LU_MODE=on LU_HQ=maybe; expect_back "o flag do HQ com valor que não existe: recua"
fresh; lu LU_MODE=on LU_HQ=0; lu LU_MODE=on LU_HQ=0; [ "$(notifies)" = 1 ] && ok "o HQ fora também alarma (na 2a): o problema é real, só não há o que o nó faça" || bad "HQ fora sem alarme na 2a varredura"

echo "── (2) o alarme: não a cada varredura; na 2a seguida e a cada 6a"
fresh
for i in 1 2 3 4 5 6 7; do
  lu LU_MODE=on; n="$(notifies)"
  case "$i" in
    1) [ "$n" = 0 ] && ok "1a varredura sem medida: sem notify (um soluço de leitura não acorda ninguém); contador gravado" || bad "1a: notify saiu ($n)" ;;
    2) [ "$n" = 1 ] && ok "2a seguida: o alarme sai (1 notify)" || bad "2a: esperado 1 notify, vieram $n" ;;
    3|4|5) [ "$n" = 1 ] && ok "${i}a seguida: sem repetir" || bad "${i}a: esperado 1 notify, vieram $n" ;;
    6) [ "$n" = 2 ] && ok "6a seguida: o alarme repete (2 notify no total)" || bad "6a: esperado 2 notify, vieram $n" ;;
    7) [ "$n" = 2 ] && ok "7a seguida: sem repetir" || bad "7a: esperado 2 notify, vieram $n" ;;
  esac
done
[ "$(cat "$STATE_F" 2>/dev/null)" = 7 ] && ok "o contador gravado é 7" || bad "o contador gravado não é 7: '$(cat "$STATE_F" 2>/dev/null)'"
grep -q 'NÃO MEDIDAS' "$WORK/notify.calls" && grep -q 'ga-d3ryi7k' "$WORK/notify.calls" && ok "o texto do aviso diz NÃO MEDIDAS e cita a bead" || bad "texto do aviso inesperado: $(head -1 "$WORK/notify.calls")"
fresh; lu LU_MODE=on LU_AFTER=1; [ "$(notifies)" = 1 ] && ok "PILOT_LANES_UNMEASURED_ALERT_AFTER=1: avisa já na 1a" || bad "ALERT_AFTER=1 não avisou na 1a"
fresh; lu LU_MODE=on LU_AFTER=abc; lu LU_MODE=on LU_AFTER=abc; [ "$(notifies)" = 1 ] && ok "ALERT_AFTER ilegível volta ao padrão (2)" || bad "ALERT_AFTER ilegível não voltou ao padrão"
fresh; lu LU_MODE=off; lu LU_MODE=off; [ "$(notifies)" = 1 ] && ok "o alarme sai também quando a varredura recua (o problema é a leitura, não o modo)" || bad "recuo sem alarme"
fresh; lu LU_MODE=on LU_NOTIFY_RC=1; lu LU_MODE=on LU_NOTIFY_RC=1; [ "$(notifies)" = 1 ] && ok "notify que falha não derruba a varredura (rc da função segue 0)" || bad "notify que falha mudou o resultado"
[ "$LU_RC" = 0 ] || bad "notify que falha derrubou a função (rc=$LU_RC)"

echo "── (2) o estado: DRY_RUN não escreve nem avisa; contador ilegível recomeça de 0 e avisa"
fresh; lu LU_MODE=on LU_DRY=1; lu LU_MODE=on LU_DRY=1
{ [ ! -e "$STATE_F" ] && [ "$(notifies)" = 0 ]; } && ok "DRY_RUN: nenhum arquivo de estado, nenhum notify (a varredura de ensaio não muda nada)" || bad "DRY_RUN escreveu estado ou avisou"
fresh; printf 'lixo' > "$STATE_F"; lu LU_MODE=on
{ [ "$(cat "$STATE_F")" = 1 ] && says "ilegível"; } && ok "contador com lixo: recomeça de 0 (grava 1) e AVISA" || bad "contador ilegível tratado em silêncio ou mal :: $LU_OUT"
fresh; mkdir -p "$STATE_F"; lu LU_MODE=on LU_STATE="$STATE_F"
{ [ "$LU_RC" = 0 ] && says "WARN"; } && ok "estado que não grava (é um diretório): a varredura segue e AVISA" || bad "estado que não grava derrubou a varredura ou calou :: $LU_OUT"
rmdir "$STATE_F" 2>/dev/null || true

echo "── (2) a recuperação: limpa o contador e avisa só se houve alarme"
fresh; echo 3 > "$STATE_F"; lu LU_CALL=clear LU_MODE=on
{ [ ! -e "$STATE_F" ] && says "voltaram a ser MEDIDAS" && says "3"; } && ok "contador apagado e a recuperação dita no log com a contagem" || bad "recuperação não limpou ou não disse :: $LU_OUT"
[ "$(notifies)" = 1 ] && ok "a sequência durou 3 (houve alarme): o aviso de recuperação sai" || bad "esperado 1 notify de recuperação, vieram $(notifies)"
fresh; echo 1 > "$STATE_F"; lu LU_CALL=clear LU_MODE=on
{ [ ! -e "$STATE_F" ] && [ "$(notifies)" = 0 ]; } && ok "soluço de 1 varredura (nunca houve alarme): limpa em silêncio, sem notify" || bad "soluço de 1 varredura gerou notify de recuperação"
fresh; lu LU_CALL=clear LU_MODE=on
{ [ "$LU_RC" = 0 ] && ! says "voltaram" && [ "$(notifies)" = 0 ]; } && ok "sem contador: nada a dizer, nada a avisar" || bad "recuperação sem sequência falou :: $LU_OUT"
fresh; echo 4 > "$STATE_F"; lu LU_CALL=clear LU_DRY=1 LU_MODE=on
{ [ -e "$STATE_F" ] && [ "$(notifies)" = 0 ]; } && ok "DRY_RUN não apaga o contador nem avisa" || bad "DRY_RUN mexeu no contador"

# ── (3) o ponto de chamada: a região verbatim ─────────────────────────────────────────────────────────────────────────────────────────
cat > "$WORK/branch-runner.sh" <<'EOF'
set -euo pipefail
PATH="$SANDBOX_PATH"
log()    { echo "LOG $*"; }
warn()   { echo "WARN $*"; }
notify() { :; }
eval "$FUNC_UNMEAS"; eval "$FUNC_LU"
GC_CITY="$WORK/city"; export PILOT_LANES_UNMEASURED_STATE="$WORK/city/.gc/branch.count"
MAX_SMALL=3; MAX_BIG=1; IN_FLIGHT_SMALL="${B_IN_SMALL-0}"; IN_FLIGHT_BIG="${B_IN_BIG-0}"
IN_FLIGHT_SMALL_CLASSIFIED=3; IN_FLIGHT_UNCLASSIFIED=0
IN_FLIGHT_QUERY_OK="${B_QOK-1}"
IN_FLIGHT_HQ_QUERY_OK=1; [ -z "${B_HQ+x}" ] || IN_FLIGHT_HQ_QUERY_OK="$B_HQ"
SMALL_SLOTS="${B_SMALL-0}"; BIG_SLOTS="${B_BIG-0}"; _PILOT_NODE_ONLY=0
PILOT_NODE_FIRST="${B_MODE-on}"; DRY_RUN="${B_DRY:-0}"
bd() { if [ "${B_BD_FAIL:-0}" = 1 ]; then return 1; fi; echo '[{"id":"x-1","labels":["story:approved"]}]'; }
eval "$BRANCH_SRC"
echo "FELL_THROUGH node_only=$_PILOT_NODE_ONLY small=$SMALL_SLOTS big=$BIG_SLOTS"
EOF
branch() { # <VAR=valor...> — roda a região; B_EXIT = 1 se o `exit 0` dela rodou (nunca chegou ao FELL_THROUGH)
  rm -f "$WORK/city/.gc/branch.count"
  B_OUT="$(env FUNC_UNMEAS="$FUNC_UNMEAS" FUNC_LU="$FUNC_LU" BRANCH_SRC="$BRANCH_SRC" SANDBOX_PATH="$SANDBOX_PATH" WORK="$WORK" "$@" bash "$WORK/branch-runner.sh" 2>&1)"; B_RC=$?
  B_EXIT=1; case "$B_OUT" in *FELL_THROUGH*) B_EXIT=0 ;; esac
}
echo "── (3) o ponto de chamada (a região verbatim do dispatcher)"
branch B_QOK=1
{ [ "$B_EXIT" = 1 ] && [ "$B_RC" = 0 ]; } && ok "consulta lida, pistas cheias: sai (exit 0) como sempre" || bad "mudou o caminho da pista genuinamente cheia :: $B_OUT"
printf '%s\n' "$B_OUT" | grep -qF 'LOG Both lanes full (small=3/3 unclassified_lane=0, big=0/1). Pilot backing off.' && ok "e com o texto de sempre, byte a byte" || bad "o texto de 'Both lanes full' mudou para a pista lida :: $B_OUT"
printf '%s\n' "$B_OUT" | grep -qF '(HQ; both lanes full — none can dispatch this sweep)' && ok "a linha 'Dispatch queue' da pista cheia segue igual" || bad "a linha 'Dispatch queue' da pista cheia mudou :: $B_OUT"
printf '%s\n' "$B_OUT" | grep -q 'NÃO MEDIDAS' && bad "pista lida e cheia foi chamada de NÃO MEDIDA :: $B_OUT" || ok "pista lida e cheia NUNCA é chamada de não medida"
branch B_QOK=0 B_MODE=on
{ [ "$B_EXIT" = 0 ] && [ "$B_RC" = 0 ]; } && ok "consulta que falhou + on: NÃO sai — a varredura segue para a passada do nó" || bad "consulta que falhou + on saiu em 'Both lanes full' (o defeito de 23/11) :: $B_OUT"
printf '%s\n' "$B_OUT" | grep -q 'FELL_THROUGH node_only=1 small=1 big=1' && ok "chega ao resto da varredura com node_only=1 e as vagas de sondagem" || bad "estado ao seguir inesperado :: $B_OUT"
printf '%s\n' "$B_OUT" | grep -q 'Both lanes full' && bad "a varredura que segue ainda diz 'Both lanes full' :: $B_OUT" || ok "a varredura que segue não diz 'Both lanes full'"
branch B_QOK=0 B_MODE=on B_HQ=0
{ [ "$B_EXIT" = 1 ] && [ "$B_RC" = 0 ]; } && ok "consulta que falhou + on + HQ que não respondeu: recua" || bad "seguiu para a passada do nó com o HQ fora :: $B_OUT"
printf '%s\n' "$B_OUT" | grep -qF 'LOG Lanes NOT MEASURED' && ok "e o recuo diz 'Lanes NOT MEASURED'" || bad "recuo com HQ fora sem a linha 'Lanes NOT MEASURED' :: $B_OUT"
branch B_QOK=0 B_MODE=off
{ [ "$B_EXIT" = 1 ] && [ "$B_RC" = 0 ]; } && ok "consulta que falhou + off: recua (não há passada do nó)" || bad "consulta que falhou + off não recuou :: $B_OUT"
printf '%s\n' "$B_OUT" | grep -qF 'Both lanes full' && bad "o recuo por leitura falha chama a pista de 'Both lanes full' :: $B_OUT" || ok "e o recuo NÃO a chama de 'Both lanes full'"
printf '%s\n' "$B_OUT" | grep -q 'LOG Lanes NOT MEASURED' && ok "o recuo diz 'Lanes NOT MEASURED ... Pilot backing off'" || bad "o recuo não traz a linha 'Lanes NOT MEASURED' :: $B_OUT"
printf '%s\n' "$B_OUT" | grep -qF 'lanes NOT MEASURED this sweep — none can dispatch)' && ok "a linha 'Dispatch queue' também deixa de culpar a capacidade" || bad "a linha 'Dispatch queue' do recuo por leitura falha ainda culpa a capacidade :: $B_OUT"
branch B_QOK=0 B_MODE=on B_DRY=1
{ [ "$B_EXIT" = 1 ] && [ "$B_RC" = 0 ]; } && ok "consulta que falhou + on + DRY_RUN: recua" || bad "DRY_RUN seguiu para a passada do nó :: $B_OUT"
branch B_QOK=1 B_SMALL=2 B_BIG=1
[ "$B_EXIT" = 0 ] && ok "pista com vaga (consulta lida): nem entra no recuo, a função não é chamada" || bad "com vaga, a varredura recuou :: $B_OUT"
printf '%s\n' "$B_OUT" | grep -q 'NÃO MEDIDAS' && bad "pista com vaga e lida foi chamada de não medida" || ok "e não aparece NÃO MEDIDAS"

# ── (4) o dispatcher real, sob `set -u`: a função roda no contexto do arquivo, não só com stubs ─────────────────────────────────────────
echo "── (4) a ligação no arquivo real (deriva)"
grep -qE '^_pilot_lanes_unmeasured_clear( \|\| true)?$|_pilot_lanes_unmeasured_clear( \|\| true)?$' "$DISPATCHER" && ok "a recuperação é chamada no Step 3, depois do cálculo das vagas" || bad "nenhuma chamada de _pilot_lanes_unmeasured_clear no fluxo"
grep -qE 'SMALL_SLOTS=\$\(inflight_slots_from_query "\$IN_FLIGHT_QUERY_OK" "\$MAX_SMALL" "\$IN_FLIGHT_SMALL"\)' "$DISPATCHER" && ok "SMALL_SLOTS continua vindo de inflight_slots_from_query (a trava da ga-1fssl no mini, intacta)" || bad "SMALL_SLOTS deixou de vir de inflight_slots_from_query"
grep -qE 'BIG_SLOTS=\$\(inflight_slots_from_query "\$IN_FLIGHT_QUERY_OK" "\$MAX_BIG" "\$IN_FLIGHT_BIG"\)' "$DISPATCHER" && ok "BIG_SLOTS idem" || bad "BIG_SLOTS deixou de vir de inflight_slots_from_query"
[ "$(grep -c '_pilot_lanes_unmeasured ' "$DISPATCHER")" -ge 1 ] && ok "a função é chamada de algum ponto do fluxo" || bad "_pilot_lanes_unmeasured nunca é chamada"
# o flag do HQ só cai no ramo do HQ (antes do laço das rigs), nunca no das rigs: a falha de uma rig não é o HQ fora
_hq_lines="$(grep -n 'IN_FLIGHT_HQ_QUERY_OK=0' "$DISPATCHER" | cut -d: -f1 | tr '\n' ' ')"; _rig_loop="$(grep -n '^_in_flight_rig_json=""' "$DISPATCHER" | head -1 | cut -d: -f1)"
{ [ "$(printf '%s' "$_hq_lines" | wc -w | tr -d ' ')" = 1 ] && [ -n "$_rig_loop" ] && [ "${_hq_lines% }" -lt "$_rig_loop" ]; } \
  && ok "IN_FLIGHT_HQ_QUERY_OK=0 é posto UMA vez, no ramo do HQ (linha ${_hq_lines% }, antes do laço das rigs na $_rig_loop)" \
  || bad "o flag do HQ é posto em outro lugar que o ramo do HQ (linhas: ${_hq_lines:-nenhuma}; laço das rigs: ${_rig_loop:-?})"
# as 2 chamadas do top-up seguem ANTES do recuo (ga-swnsg3): o pool do mini não espera a leitura que falhou
_ord="$(awk '/^_pilot_pool_topup "wa-worker"/{t=NR} /^_pilot_pool_topup "ps-worker"/{t2=NR} /_pilot_lanes_unmeasured \|\| true/{c=NR} END{print (t>0 && t2>0 && c>t2) ? "ok" : "bad"}' "$DISPATCHER")"
[ "$_ord" = ok ] && ok "o top-up de pool (wa-worker, ps-worker) roda ANTES do ponto de chamada: o mini segue enchendo o pool com a faixa não medida" || bad "ordem: o ponto de chamada ficou antes do top-up de pool"

if [ -z "${LU_MUTANT:-}" ] && [ -z "${LU_NO_MUTANTS:-}" ]; then
  echo "── controle negativo: cada guarda desligada numa cópia do dispatcher tem que reprovar este arquivo"
  nm=0
  mutant() {  # <nome> <âncora (ASCII, 1x)> <troca>
    nm=$((nm+1)); local m="$WORK/disp.mut$nm.sh"
    python3 -I -c 'import sys
s=open(sys.argv[1],encoding="utf-8").read()
if s.count(sys.argv[2])!=1: sys.exit(3)
open(sys.argv[4],"w",encoding="utf-8").write(s.replace(sys.argv[2],sys.argv[3]))' "$DISPATCHER" "$2" "$3" "$m" 2>/dev/null \
      || { bad "mutante '$1': a âncora não casa exatamente 1 vez"; return; }
    local r; r=$(LU_MUTANT=1 PILOT_DISPATCHER_PATH="$m" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) bad "mutante '$1' NÃO foi pego ($r)" ;; "RESULT "*) ok "mutante '$1' pego ($r)" ;; *) bad "mutante '$1': sem resultado ($r)" ;; esac
  }
  # as âncoras são ASCII de propósito (o python3 lê o argv no locale do shell e o arquivo em UTF-8: uma âncora com acento não casaria sob LC_ALL=C)
  mutant "a função nunca é chamada no ponto de chamada" $'  _pilot_lanes_unmeasured || true\nfi' $'  :\nfi'
  mutant "o ponto de chamada também roda com a consulta lida" '[ "$BIG_SLOTS" -eq "0" ] && [ "${IN_FLIGHT_QUERY_OK:-1}" != "1" ]; then' '[ "$BIG_SLOTS" -eq "0" ]; then'
  mutant "a passada só-nó liga sem PILOT_NODE_FIRST=on" 'if [ "${PILOT_NODE_FIRST:-off}" = "on" ] && [ "${DRY_RUN:-0}" != "1" ] && [ "${PILOT_LANES_UNMEASURED_NODE_PASS:-on}" = "on" ]' 'if [ "${DRY_RUN:-0}" != "1" ] && [ "${PILOT_LANES_UNMEASURED_NODE_PASS:-on}" = "on" ]'
  mutant "a passada só-nó liga no DRY_RUN" 'if [ "${PILOT_NODE_FIRST:-off}" = "on" ] && [ "${DRY_RUN:-0}" != "1" ] && [ "${PILOT_LANES_UNMEASURED_NODE_PASS:-on}" = "on" ]' 'if [ "${PILOT_NODE_FIRST:-off}" = "on" ] && [ "${PILOT_LANES_UNMEASURED_NODE_PASS:-on}" = "on" ]'
  mutant "a chave PILOT_LANES_UNMEASURED_NODE_PASS=off não desliga" 'if [ "${PILOT_NODE_FIRST:-off}" = "on" ] && [ "${DRY_RUN:-0}" != "1" ] && [ "${PILOT_LANES_UNMEASURED_NODE_PASS:-on}" = "on" ]' 'if [ "${PILOT_NODE_FIRST:-off}" = "on" ] && [ "${DRY_RUN:-0}" != "1" ]'
  mutant "a passada só-nó liga mesmo com o que se leu enchendo as pistas" $'     && { [ "$_lu_s" -gt 0 ] || [ "$_lu_b" -gt 0 ]; }; then\n    _lu_go=1' $'     && true; then\n    _lu_go=1'
  mutant "a passada só-nó continua mesmo com a leitura do HQ falha" '[ "$_lu_hq" = 1 ] \' 'true \'
  mutant "o flag do HQ nunca é lido" 'if [ "${IN_FLIGHT_HQ_QUERY_OK:-}" != "1" ]; then _lu_hq=0; fi' ':'
  mutant "o flag do HQ que não está posto vale como 'respondeu'" 'if [ "${IN_FLIGHT_HQ_QUERY_OK:-}" != "1" ]; then _lu_hq=0; fi' 'if [ "${IN_FLIGHT_HQ_QUERY_OK:-1}" != "1" ]; then _lu_hq=0; fi'
  mutant "o ramo do HQ não derruba o flag do HQ" $'  IN_FLIGHT_QUERY_OK=0\n  IN_FLIGHT_HQ_QUERY_OK=0\n' $'  IN_FLIGHT_QUERY_OK=0\n'
  mutant "a falha de uma rig derruba o flag do HQ" $'    _rig_inflight="[]"\n    IN_FLIGHT_QUERY_OK=0\n' $'    _rig_inflight="[]"\n    IN_FLIGHT_QUERY_OK=0\n    IN_FLIGHT_HQ_QUERY_OK=0\n'
  mutant "seguir dá vaga mas NÃO liga o só-nó (o mini despacharia)" 'SMALL_SLOTS="$_lu_s"; BIG_SLOTS="$_lu_b"; _PILOT_NODE_ONLY=1' 'SMALL_SLOTS="$_lu_s"; BIG_SLOTS="$_lu_b"; _PILOT_NODE_ONLY=0'
  mutant "a vaga de sondagem passa de 1" '  [ "$slots" -gt 1 ] && slots=1' '  :'
  mutant "a vaga de sondagem ignora o que se leu" 'slots=$((10#$max_slots - 10#$read_count))' 'slots=$((10#$max_slots))'
  mutant "contagem ilegivel vira vaga" $'  case "$read_count" in \'\'|*[!0-9]*) echo 0; return ;; esac' $'  case "$read_count" in \'\'|*[!0-9]*) echo 1; return ;; esac'
  mutant "zero a esquerda vira octal" 'slots=$((10#$max_slots - 10#$read_count))' 'slots=$(($max_slots - $read_count))'
  mutant "o alarme sai a cada varredura" 'if [ "$_lu_n" -eq "$_lu_after" ] || [ $((_lu_n % _lu_every)) -eq 0 ] || [ "$_lu_wrote" = 0 ]; then' 'if true; then'
  mutant "o alarme nunca sai na varredura N" 'if [ "$_lu_n" -eq "$_lu_after" ] || [ $((_lu_n % _lu_every)) -eq 0 ]' 'if false || [ $((_lu_n % _lu_every)) -eq 0 ]'
  mutant "o alarme padrao sai ja na 1a" 'local _lu_after="${PILOT_LANES_UNMEASURED_ALERT_AFTER:-2}"' 'local _lu_after="${PILOT_LANES_UNMEASURED_ALERT_AFTER:-1}"'
  mutant "o DRY_RUN grava estado e avisa" $'  if [ "${DRY_RUN:-0}" != "1" ]; then\n    # vazio (sem arquivo' $'  if true; then\n    # vazio (sem arquivo'
  mutant "contador ilegivel passa em silencio" $'case "$_lu_n" in \'\'|*[!0-9]*) warn "ga-d3ryi7k: contador' $'case "$_lu_n" in \'\'|*[!0-9]*) : "ga-d3ryi7k: contador'
  mutant "a recuperacao nunca e chamada" '[ "$IN_FLIGHT_QUERY_OK" != "1" ] || _pilot_lanes_unmeasured_clear || true' ':'
  mutant "a recuperacao avisa mesmo apos um soluco de 1 varredura" 'if [ "$_lc_n" = "?" ] || [ "$_lc_n" -ge "$_lc_after" ]; then' 'if true; then'
  mutant "a recuperacao apaga o contador no DRY_RUN" $'  [ "${DRY_RUN:-0}" != "1" ] || return 0\n  [ -f "$_lc_f" ] || return 0' $'  [ -f "$_lc_f" ] || return 0'
  mutant "o recuo ainda diz Both lanes full com a leitura falha" $'  if [ "${IN_FLIGHT_QUERY_OK:-1}" != "1" ]; then\n    log "Lanes NOT MEASURED (what' $'  if false; then\n    log "Lanes NOT MEASURED (what'
  mutant "a linha Dispatch queue ainda culpa a capacidade" $'  elif [ "${IN_FLIGHT_QUERY_OK:-1}" != "1" ]; then\n    # ga-d3ryi7k: the lanes were not measured' $'  elif false; then\n    # ga-d3ryi7k: the lanes were not measured'
  mutant "a trava da ga-1fssl no mini some (consulta que falhou dá vaga)" '[ "$query_ok" != "1" ] && { echo 0; return; }' ':'
fi
echo ""
if [ -n "${LU_MUTANT:-}" ]; then echo "RESULT $FAIL/$((PASS+FAIL))"; fi
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
