#!/usr/bin/env bash
# pilot-dispatcher.node-yield.selftest.sh — ga-2hd02v.1.19 (a bead de dog do HQ que o nó quer NÃO cede ao priority yield)
#
# O priority yield (ga-5fn5p3) cedia TODAS as P2+ a uma P0 do WA presa no pool wa-worker 2/2 ANTES do gancho do nó (medido 19/10 16:35, 1ª varredura com PILOT_NODE_FIRST=on: 192 P2+ cedidas,
# dispatched=0, node-first-shadow.jsonl sem linha nova). A vaga do nó não é a que a P0 do WA espera. Este arquivo é a MATRIZ DE DECISÃO de `_pilot_priority_node_exempt` (+ o invólucro
# `_pilot_priority_node_exempt_pre` da fase pré-claim) e a prova de que os três pontos de dispatch_one/dispatch_lane o chamam na ordem certa.
#
# Contents
#   O que prova · Como roda · Controle negativo
#
# O QUE PROVA: node com vaga → isenta (a bead não cede) · local / não sei / oráculo mudo ou incoerente / node sem `effective` → CEDE (o terceiro estado nunca vira node) · uma consulta por varredura,
#   mesmo com várias beads · no máximo `effective` beads isentas por varredura, e a mesma bead (antes e depois da claim) conta uma vez · shadow só registra e cede · off, valor que não existe e DRY_RUN
#   cedem sem consultar · rótulo de veto, bead rig-native e pool que não é gastown.dog cedem SEM gastar a consulta da varredura (a bead seguinte, que o nó quer, ainda a faz) · o invólucro pré-claim
#   cede para wa-worker/ps-worker e para JSON que não se lê · os três pontos de chamada existem, na ordem: yield pré-claim → yield pós-claim → gancho do nó → "o nó não ficou com a bead → cede".
# COMO RODA: as funções e as linhas de configuração são extraídas VERBATIM do dispatcher (awk/grep) e rodam num shell filho sob `set -euo pipefail`; `python3` é um falso no PATH do filho (PATH sem gc/bd
#   reais: selftest-sandbox-path.lib.sh) e conta as consultas. Contra um dispatcher sem as funções o arquivo se recusa a começar — o vermelho honesto.
# CONTROLE NEGATIVO: cada guarda desligada numa cópia do dispatcher (NY_NO_MUTANTS=1 pula): shadow isenta · sem teto de effective · veredito vazio isenta · consulta a cada bead · sem o filtro de veto ·
#   sem o filtro de alvo/cidade · wa-worker passa no pré-claim · a mesma bead conta duas vezes.
# Variáveis: PILOT_DISPATCHER_PATH · NY_NO_MUTANTS=1
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ -n "${NY_MUTANT:-}" ] || echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; [ -z "${NY_MUTANT:-}" ] || { echo "RESULT $FAIL/$((PASS+FAIL))"; exit 1; }; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
need_fn() { local s; s="$(fn_src "$1")"; [ -n "$s" ] || { echo "FATAL: $1() not found in $DISPATCHER (ga-2hd02v.1.19 not applied)" >&2; exit 2; }; printf '%s' "$s"; }
FUNC_EXEMPT="$(need_fn _pilot_priority_node_exempt)"
FUNC_PRE="$(need_fn _pilot_priority_node_exempt_pre)"
FUNC_SHADOW="$(need_fn _pilot_node_first_shadow)"
FUNC_VETO="$(need_fn _pilot_node_first_veto)"
VETO_LINE="$(grep -E '^PILOT_NODE_FIRST_VETO_LABELS="' "$DISPATCHER" | head -1)"
PNY_INIT="$(grep -E '^_PNY_(ASKED|VERDICT|EFFECTIVE|GRANTED|GRANTED_N|EXEMPT_THIS)=' "$DISPATCHER")"
[ -n "$VETO_LINE" ] && [ "$(printf '%s\n' "$PNY_INIT" | wc -l | tr -d ' ')" = 6 ] || { echo "FATAL: config lines (veto / _PNY_* x6) not found in $DISPATCHER" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-nodeyield-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
# o oráculo falso: conta a chamada, devolve $WORK/oracle.out e sai com $WORK/oracle.rc (sem arquivo: sai 127 como "comando que não rodou")
cat > "$WORK/bin/python3" <<'EOF'
#!/bin/sh
W="${SELFTEST_WORK:?}"
echo x >> "$W/oracle.calls"
[ -f "$W/oracle.rc" ] || exit 127
[ -f "$W/oracle.out" ] && cat "$W/oracle.out"
exit "$(cat "$W/oracle.rc")"
EOF
chmod +x "$WORK/bin/python3"
sandbox_path_init "$WORK" jq date timeout mkdir dirname cat || exit 2

LOG="$WORK/shadow.jsonl"; LINES="$WORK/lines.txt"
reset() { rm -f "$WORK"/oracle.out "$WORK"/oracle.rc "$WORK"/oracle.calls "$LOG" "$LINES"; }
oracle() { printf '%s' "$2" > "$WORK/oracle.out"; echo "$1" > "$WORK/oracle.rc"; }
calls() { [ -f "$WORK/oracle.calls" ] && wc -l < "$WORK/oracle.calls" | tr -d ' ' || echo 0; }

# run_ny '<código>' — roda o código num shell filho sob `set -euo pipefail`, depois das definições; imprime a última linha que ele echo-ar. Env: NY_MODE (padrão on) · NY_DRY
# pre <json> (definida no filho) imprime o rc de _pilot_priority_node_exempt_pre; cada chamada a $(pre …) é uma subshell, então o teto e a consulta única não se somam entre elas.
run_ny() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    log()  { echo "LOG $*" >> "$LINES"; }
    warn() { echo "WARN $*" >> "$LINES"; }
    GC_CITY="$WORK/city"
    PILOT_NODE_FIRST="${NY_MODE-on}"
    eval "$VETO_LINE"
    PILOT_NODE_CAPACITY_BIN="$WORK/fake-capacity.py"
    PILOT_NODE_FIRST_LOG="$LOG"
    DRY_RUN="${NY_DRY:-0}"
    eval "$PNY_INIT"
    eval "$FUNC_VETO"; eval "$FUNC_SHADOW"; eval "$FUNC_EXEMPT"; eval "$FUNC_PRE"
    pre() { local x=0; _pilot_priority_node_exempt_pre "$@" || x=$?; printf '%s' "$x"; }
    eval "$1"
  ) 2>&1 | tail -1
}
D=gastown.dog

echo "── node com vaga: a bead de dog do HQ não cede (uma consulta por varredura, no máximo effective isentas)"
reset; oracle 0 '{"verdict":"node","reason":"free_slot","effective":2}'
# as chamadas de uma mesma varredura rodam em sequência no MESMO shell filho (o estado _PNY_* é do processo; $(…) o perderia)
r=$(run_ny 'x1=0; _pilot_priority_node_exempt ga-a '$D' 0 story:approved || x1=$?; x2=0; _pilot_priority_node_exempt ga-b '$D' 0 story:approved || x2=$?; x3=0; _pilot_priority_node_exempt ga-c '$D' 0 story:approved || x3=$?; x4=0; _pilot_priority_node_exempt ga-a '$D' 0 story:approved || x4=$?; echo "a=$x1 b=$x2 c=$x3 a2=$x4"')
[ "$r" = "a=0 b=0 c=1 a2=0" ] && ok "effective=2: a e b isentas, c cede (teto), a de novo (pós-claim da mesma bead) continua isenta — $r" || bad "isenção/teto errados: $r"
[ "$(calls)" = 1 ] && ok "quatro perguntas, UMA consulta ao oráculo na varredura" || bad "o oráculo foi consultado $(calls) vezes (esperado 1)"
reset; oracle 0 '{"verdict":"node","reason":"free_slot","effective":1}'
r=$(run_ny 'x1=0; _pilot_priority_node_exempt ga-a '$D' 0 story:approved || x1=$?; x2=0; _pilot_priority_node_exempt ga-a '$D' 0 story:approved || x2=$?; x3=0; _pilot_priority_node_exempt ga-b '$D' 0 story:approved || x3=$?; echo "a=$x1 a2=$x2 b=$x3"')
[ "$r" = "a=0 a2=0 b=1" ] && ok "effective=1: a passa pré e pós-claim (conta UMA vez) e b cede — $r" || bad "a mesma bead contou duas vezes ou o teto falhou: $r"

echo "── terceiro estado: o que não é node cede"
reset; oracle 1 '{"verdict":"local","reason":"node_full"}'
r=$(run_ny 'x1=0; _pilot_priority_node_exempt ga-a '$D' 0 story:approved || x1=$?; x2=0; _pilot_priority_node_exempt ga-b '$D' 0 story:approved || x2=$?; echo "a=$x1 b=$x2"')
[ "$r" = "a=1 b=1" ] && [ "$(calls)" = 1 ] && ok "local/1: cede, e a 2ª bead não consulta de novo" || bad "local não cedeu ou consultou de novo ($r calls=$(calls))"
reset
r=$(run_ny 'x1=0; _pilot_priority_node_exempt ga-a '$D' 0 story:approved || x1=$?; echo "a=$x1"')
[ "$r" = "a=1" ] && [ "$(calls)" = 1 ] && ok "oráculo que não rodou (127): cede — leitura que falhou nunca vai ao nó" || bad "oráculo mudo não cedeu ($r)"
reset; oracle 0 'isto não é json'
r=$(run_ny 'x1=0; _pilot_priority_node_exempt ga-a '$D' 0 story:approved || x1=$?; echo "a=$x1"')
[ "$r" = "a=1" ] && ok "JSON ilegível com exit 0: cede" || bad "JSON ilegível não cedeu ($r)"
reset; oracle 1 '{"verdict":"node","reason":"free_slot","effective":3}'
r=$(run_ny 'x1=0; _pilot_priority_node_exempt ga-a '$D' 0 story:approved || x1=$?; echo "a=$x1"')
[ "$r" = "a=1" ] && ok "node com exit 1 (incoerente): cede" || bad "node incoerente não cedeu ($r)"
reset; oracle 0 '{"verdict":"node","reason":"free_slot"}'
r=$(run_ny 'x1=0; _pilot_priority_node_exempt ga-a '$D' 0 story:approved || x1=$?; echo "a=$x1"')
[ "$r" = "a=1" ] && ok "node sem effective: cede (sem número de vagas não há alias a escolher)" || bad "node sem effective isentou ($r)"

echo "── modos: shadow só registra, off / valor desconhecido / DRY_RUN não consultam"
reset; oracle 0 '{"verdict":"node","reason":"free_slot","effective":2}'
r=$(NY_MODE=shadow run_ny 'x1=0; _pilot_priority_node_exempt ga-a '$D' 0 story:approved || x1=$?; echo "a=$x1"')
[ "$r" = "a=1" ] && [ "$(calls)" = 1 ] && [ "$(jq -r .shadow "$LOG" 2>/dev/null | tail -1)" = true ] && [ "$(jq -r .verdict "$LOG" 2>/dev/null | tail -1)" = node ] \
  && ok "shadow: CEDE, consulta uma vez e registra a linha (shadow=true, verdict=node)" || bad "shadow isentou ou não registrou ($r calls=$(calls) log=$(tail -1 "$LOG" 2>/dev/null))"
for m in off maybe ""; do
  reset; oracle 0 '{"verdict":"node","reason":"free_slot","effective":2}'
  r=$(NY_MODE=$m run_ny 'x1=0; _pilot_priority_node_exempt ga-a '$D' 0 story:approved || x1=$?; echo "a=$x1"')
  [ "$r" = "a=1" ] && [ "$(calls)" = 0 ] && [ ! -e "$LOG" ] && ok "PILOT_NODE_FIRST='$m': cede sem consultar nem gravar" || bad "PILOT_NODE_FIRST='$m' consultou ou isentou ($r calls=$(calls))"
done
reset; oracle 0 '{"verdict":"node","reason":"free_slot","effective":2}'
r=$(NY_DRY=1 run_ny 'x1=0; _pilot_priority_node_exempt ga-a '$D' 0 story:approved || x1=$?; echo "a=$x1"')
[ "$r" = "a=1" ] && [ "$(calls)" = 0 ] && ok "DRY_RUN: cede sem consultar (a consulta mede o nó e grava estado)" || bad "DRY_RUN consultou ou isentou ($r calls=$(calls))"

echo "── quem entra: veto, rig-native e outro pool cedem SEM gastar a consulta da varredura"
reset; oracle 0 '{"verdict":"node","reason":"free_slot","effective":2}'
r=$(run_ny 'x1=0; _pilot_priority_node_exempt ga-v '$D' 0 story:approved,node:never || x1=$?; x2=0; _pilot_priority_node_exempt ga-n '$D' 1 story:approved || x2=$?; x3=0; _pilot_priority_node_exempt ga-w wa-worker 0 story:approved || x3=$?; x4=0; _pilot_priority_node_exempt ga-d gastown.dog-2 0 story:approved || x4=$?; echo "calls0 v=$x1 n=$x2 w=$x3 d=$x4"')
[ "$r" = "calls0 v=1 n=1 w=1 d=1" ] && [ "$(calls)" = 0 ] && ok "veto node:never, rig-native, wa-worker e gastown.dog-2: cedem e o oráculo não é consultado" || bad "um filtro de entrada falhou ($r calls=$(calls))"
r=$(run_ny 'x1=0; _pilot_priority_node_exempt ga-v '$D' 0 story:approved,node:never || x1=$?; x2=0; _pilot_priority_node_exempt ga-w wa-worker 0 story:approved || x2=$?; x3=0; _pilot_priority_node_exempt ga-ok '$D' 0 story:approved || x3=$?; echo "v=$x1 w=$x2 ok=$x3"')
[ "$r" = "v=1 w=1 ok=0" ] && [ "$(calls)" = 1 ] && ok "depois de um veto e de um wa-worker, a bead que o nó quer ainda faz a consulta (e passa) — a pergunta não foi gasta" || bad "a consulta foi gasta por bead que não entra ($r calls=$(calls))"
reset; oracle 0 '{"verdict":"node","reason":"free_slot","effective":2}'
r=$(run_ny 'x1=0; _pilot_priority_node_exempt ga-v '$D' 0 story:approved,node:never-ever || x1=$?; echo "v=$x1"')
[ "$r" = "v=0" ] && ok "veto vale por token inteiro (node:never-ever NÃO é node:never)" || bad "veto casou por substring ($r)"

echo "── invólucro pré-claim (só tem o JSON da bead)"
reset; oracle 0 '{"verdict":"node","reason":"free_slot","effective":4}'
J_DOG='{"id":"ga-p1","labels":["story:approved"],"metadata":{"gc.routed_to":"gastown.dog"}}'
J_RIG='{"id":"ga-p2","labels":["story:approved"],"metadata":{"story.rig":"gascity"}}'
J_WA='{"id":"wa-p3","labels":["story:approved"],"metadata":{"gc.routed_to":"wa-worker"}}'
J_PS='{"id":"ps-p4","labels":["story:approved"],"metadata":{"gc.routed_to":"ps-worker"}}'
J_VETO='{"id":"ga-p5","labels":["story:approved","exec:manual"],"metadata":{"gc.routed_to":"gastown.dog"}}'
r=$(run_ny "echo \"dog=\$(pre '$J_DOG') rig=\$(pre '$J_RIG') wa=\$(pre '$J_WA') ps=\$(pre '$J_PS') veto=\$(pre '$J_VETO') lixo=\$(pre 'isto não é json') semid=\$(pre '{\"labels\":[]}')\"")
[ "$r" = "dog=0 rig=0 wa=1 ps=1 veto=1 lixo=1 semid=1" ] && ok "dog roteado e rig→dog: isentam · wa-worker, ps-worker, veto, JSON que não se lê e JSON sem id: cedem — $r" || bad "invólucro pré-claim decidiu errado: $r"

echo "── os pontos de chamada no dispatcher"
L_PRE=$(grep -n '_pilot_priority_yield_for "\$pick" && ! _pilot_priority_node_exempt_pre "\$pick"' "$DISPATCHER" | head -1 | cut -d: -f1)
L_POST=$(grep -n 'if _pilot_priority_node_exempt "\$STORY_ID" "\$_PYS_TARGET" "\$_PYS_NATIVE" "\$STORY_LABELS"; then' "$DISPATCHER" | head -1 | cut -d: -f1)
L_RESET=$(grep -n '^  _PNY_EXEMPT_THIS=0$' "$DISPATCHER" | head -1 | cut -d: -f1)
L_HOOK=$(grep -n '_pilot_node_first_dispatch "\$STORY_ID" "\$STORY_BEAD_CITY" "\$STORY_TITLE"' "$DISPATCHER" | head -1 | cut -d: -f1)
L_CEDE=$(grep -n '\[ "\${_PNY_EXEMPT_THIS:-0}" = "1" \] && \[ "\${_PNF_RESULT:-}" != "node" \]' "$DISPATCHER" | head -1 | cut -d: -f1)
L_SLING=$(grep -n 'Dispatch via gc sling (HQ beads)' "$DISPATCHER" | head -1 | cut -d: -f1)
[ -n "$L_PRE" ] && ok "pré-claim (dispatch_lane): o yield só cede se o invólucro NÃO isenta (linha $L_PRE)" || bad "o ponto pré-claim não chama _pilot_priority_node_exempt_pre depois de _pilot_priority_yield_for"
[ -n "$L_POST" ] && [ -n "$L_RESET" ] && [ "$L_RESET" -lt "$L_POST" ] && ok "pós-claim (dispatch_one): _PNY_EXEMPT_THIS é zerado (linha $L_RESET) ANTES da pergunta (linha $L_POST) — a isenção de uma bead não vaza para a seguinte" || bad "pós-claim: sem o zeramento antes da pergunta (reset=$L_RESET ask=$L_POST)"
[ -n "$L_POST" ] && [ -n "$L_HOOK" ] && [ -n "$L_CEDE" ] && [ -n "$L_SLING" ] && [ "$L_POST" -lt "$L_HOOK" ] && [ "$L_HOOK" -lt "$L_CEDE" ] && [ "$L_CEDE" -lt "$L_SLING" ] \
  && ok "ordem: isenção ($L_POST) → gancho do nó ($L_HOOK) → 'o nó não ficou com a bead → cede' ($L_CEDE) → despacho ao mini ($L_SLING)" || bad "ordem dos pontos de chamada errada (post=$L_POST hook=$L_HOOK cede=$L_CEDE sling=$L_SLING)"

if [ -z "${NY_MUTANT:-}" ] && [ -z "${NY_NO_MUTANTS:-}" ]; then
  echo "── controle negativo: cada guarda desligada numa cópia do dispatcher tem que reprovar este arquivo"
  nm=0
  mutant() {
    nm=$((nm+1)); local m="$WORK/disp.mut$nm.sh"
    python3 -I -c 'import sys
s=open(sys.argv[1],encoding="utf-8").read()
if s.count(sys.argv[2])!=1: sys.exit(3)
open(sys.argv[4],"w",encoding="utf-8").write(s.replace(sys.argv[2],sys.argv[3]))' "$DISPATCHER" "$2" "$3" "$m" 2>/dev/null \
      || { bad "mutante '$1': a âncora não casa exatamente 1 vez"; return; }
    local r; r=$(NY_MUTANT=1 PILOT_DISPATCHER_PATH="$m" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) bad "mutante '$1' NÃO foi pego ($r)" ;; "RESULT "*) ok "mutante '$1' pego ($r)" ;; *) bad "mutante '$1': sem resultado ($r)" ;; esac
  }
  mutant "shadow também isenta" '  [ "$PILOT_NODE_FIRST" = "on" ] || return 1' '  :'
  mutant "sem o teto de effective" '  [ "$_PNY_GRANTED_N" -lt "$_PNY_EFFECTIVE" ] || return 1' '  :'
  mutant "veredito vazio isenta" '  [ "$_PNY_VERDICT" = "node" ] || return 1' '  [ "$_PNY_VERDICT" != "local" ] || return 1'
  mutant "consulta a cada bead" '  if [ "$_PNY_ASKED" != "1" ]; then' '  if true; then'
  mutant "sem o filtro de veto" '  [ -z "$(_pilot_node_first_veto "$_ne_labels")" ] || return 1' '  :'
  mutant "sem o filtro de alvo/cidade" '  { [ "$_ne_target" = "gastown.dog" ] && [ "$_ne_native" = "0" ]; } || return 1' '  :'
  mutant "wa-worker passa no pré-claim" '  case "$_routed" in wa-worker|wa-worker-*|ps-worker|ps-worker-*) return 1 ;; esac' '  :'
  mutant "a mesma bead conta duas vezes" '  case "$_PNY_GRANTED" in *" $_ne_id "*) return 0 ;; esac' '  :'
fi
echo "── $PASS ok, $FAIL falhas"
[ "$FAIL" = 0 ]
