#!/usr/bin/env bash
# pilot-dispatcher.node-first.selftest.sh — ga-2hd02v.1.11 (modo SOMBRA do "nó primeiro")
#
# O Pilot ganhou `_pilot_node_first_shadow`: com PILOT_NODE_FIRST=shadow ele pergunta ao oráculo do nó (scripts/hetzner-capacity.py verdict) para onde uma bead de dog iria e
# REGISTRA a resposta; o despacho não muda. Este arquivo é a MATRIZ DE DECISÃO dessa função e a prova de que ela é inerte quando desligada.
#
# Contents
#   O que prova · Como roda · Controle negativo
#
# O QUE PROVA: o padrão entregue é `off` (nada é consultado nem gravado) · valor desconhecido (`on` não existe) vale off, com aviso · DRY_RUN não consulta (a consulta mede o nó
#   e grava estado) · só bead de dog do HQ entra (pool gastown.dog, bead da cidade) · rótulo de veto vale por TOKEN (`node:never-ever` não é `node:never`) · o JSON do oráculo e o
#   exit code têm que CONCORDAR: "node" só com exit 0, e "node" com exit 1, JSON ilegível, saída vazia ou oráculo ausente são `unknown`, NUNCA `node` · a função devolve 0 e não
#   aborta sob `set -euo pipefail` mesmo com oráculo quebrado ou log que não grava · a chamada dentro do dispatch_one existe uma vez, depois de _IS_RIG_NATIVE, com `|| true`.
# COMO RODA: a função e a linha de configuração são extraídas VERBATIM do dispatcher (awk/grep) e rodam num shell filho sob o `set -euo pipefail` dele; `python3` é um
#   falso no PATH do filho (PATH sem gc/bd reais: selftest-sandbox-path.lib.sh). Contra um dispatcher sem a função o arquivo se recusa a começar — o vermelho honesto.
# CONTROLE NEGATIVO: sem a checagem de coerência rc×veredito · off que consulta mesmo assim · veto por substring · sem o filtro de pool · cada um aplicado numa cópia do dispatcher.
# Variáveis: PILOT_DISPATCHER_PATH · NF_NO_MUTANTS=1
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ -n "${NF_MUTANT:-}" ] || echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; [ -z "${NF_MUTANT:-}" ] || { echo "RESULT $FAIL/$((PASS+FAIL))"; exit 1; }; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
FUNC="$(fn_src _pilot_node_first_shadow)"
[ -n "$FUNC" ] || { echo "FATAL: _pilot_node_first_shadow() not found in $DISPATCHER (ga-2hd02v.1.11 not applied)" >&2; exit 2; }
DEFAULT_LINE="$(grep -E '^PILOT_NODE_FIRST="' "$DISPATCHER" | head -1)"
VETO_LINE="$(grep -E '^PILOT_NODE_FIRST_VETO_LABELS="' "$DISPATCHER" | head -1)"
[ -n "$DEFAULT_LINE" ] && [ -n "$VETO_LINE" ] || { echo "FATAL: PILOT_NODE_FIRST config lines not found in $DISPATCHER" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-nodefirst-selftest.XXXXXX")"
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
rec() { [ -f "$LOG" ] && jq -r "$1" "$LOG" 2>/dev/null | tail -1 || echo "SEM-LOG"; }

# run_nf — uma chamada da função num shell filho sob `set -euo pipefail`; imprime o rc dela. Env: NF_MODE NF_DRY NF_TARGET NF_NATIVE NF_LABELS NF_LOG
run_nf() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    log()  { echo "LOG $*" >> "$LINES"; }
    warn() { echo "WARN $*" >> "$LINES"; }
    GC_CITY="$WORK/city"
    if [ -n "${NF_USE_DEFAULTS:-}" ]; then eval "$DEFAULT_LINE"; else PILOT_NODE_FIRST="${NF_MODE:-shadow}"; fi
    eval "$VETO_LINE"
    PILOT_NODE_CAPACITY_BIN="$WORK/fake-capacity.py"
    PILOT_NODE_FIRST_LOG="${NF_LOG:-$LOG}"
    DRY_RUN="${NF_DRY:-0}"
    eval "$FUNC"
    # BARE, sem `if`/`||`: em contexto condicional o bash desliga o errexit dentro do corpo e esconderia um comando que aborta.
    _pilot_node_first_shadow "story-1" "${NF_TARGET:-gastown.dog}" "${NF_NATIVE:-0}" "${NF_LABELS:-story:approved,exec:auto}"
    echo "rc=$?"
  ) 2>&1 | tail -1
}

echo "── padrão e modos"
reset
r=$(NF_USE_DEFAULTS=1 NF_MODE= run_nf); calls_n=$(calls)
[ "$r" = "rc=0" ] && [ "$calls_n" = 0 ] && [ ! -e "$LOG" ] && ok "padrão entregue (linha de configuração do dispatcher) = off: rc 0, nada consultado, nada gravado" || bad "padrão não é inerte (r=$r calls=$calls_n)"
case "$DEFAULT_LINE" in *':-off}"'*) ok "a linha de configuração diz :-off" ;; *) bad "o padrão da linha de configuração não é off: $DEFAULT_LINE" ;; esac
reset; oracle 0 '{"verdict":"node","reason":"free_slot"}'
r=$(NF_MODE=off run_nf); [ "$r" = "rc=0" ] && [ "$(calls)" = 0 ] && [ ! -e "$LOG" ] && ok "off: não chama o oráculo e não grava" || bad "off não é inerte (r=$r calls=$(calls))"
r=$(NF_MODE=on run_nf); [ "$r" = "rc=0" ] && [ "$(calls)" = 0 ] && grep -q "WARN.*PILOT_NODE_FIRST='on' não existe" "$LINES" && ok "'on' não existe: vale off e avisa" || bad "valor desconhecido não foi tratado como off com aviso (r=$r)"
r=$(NF_DRY=1 run_nf); [ "$r" = "rc=0" ] && [ "$(calls)" = 0 ] && [ ! -e "$LOG" ] && grep -q "DRY_RUN" "$LINES" && ok "DRY_RUN: não consulta o nó (a consulta mede e grava estado)" || bad "DRY_RUN consultou ou gravou (r=$r)"

echo "── quem entra"
reset; oracle 0 '{"verdict":"node","reason":"free_slot"}'
r=$(NF_TARGET=wa-worker run_nf); [ "$r" = "rc=0" ] && [ "$(calls)" = 0 ] && ok "pool que não é gastown.dog: fora" || bad "wa-worker consultou o oráculo (calls=$(calls))"
r=$(NF_NATIVE=1 run_nf);        [ "$r" = "rc=0" ] && [ "$(calls)" = 0 ] && ok "bead rig-native: fora" || bad "bead rig-native consultou o oráculo"
r=$(NF_LABELS="story:approved,node:never" run_nf)
[ "$r" = "rc=0" ] && [ "$(calls)" = 0 ] && [ "$(rec .verdict)" = local ] && [ "$(rec .reason)" = "veto:node:never" ] && ok "rótulo node:never: não consulta, registra local veto:node:never" || bad "veto não funcionou (calls=$(calls) rec=$(rec .reason))"
reset; oracle 0 '{"verdict":"node","reason":"free_slot"}'
r=$(NF_LABELS="story:approved,node:never-ever" run_nf); [ "$r" = "rc=0" ] && [ "$(calls)" = 1 ] && ok "veto vale por token inteiro (node:never-ever NÃO é node:never)" || bad "veto casou por substring (calls=$(calls))"
reset; oracle 0 '{"verdict":"node","reason":"free_slot"}'
r=$(NF_LABELS="needs:engine-window" run_nf); [ "$(calls)" = 0 ] && ok "needs:engine-window é veto (engine só se mexe no mini)" || bad "needs:engine-window não vetou"

echo "── veredito do oráculo → registro"
reset; oracle 0 '{"verdict":"node","reason":"free_slot","ceiling":3,"active":1,"effective":3}'
r=$(run_nf); [ "$r" = "rc=0" ] && [ "$(rec .verdict)" = node ] && [ "$(rec .story)" = story-1 ] && [ "$(rec .ceiling)" = 3 ] && [ "$(rec .shadow)" = true ] \
  && ok "node/0: registra node, a bead, os campos do oráculo (ceiling) e shadow=true" || bad "registro de node errado (r=$r rec=$(rec -c .))"
grep -q "LOG.*IRIA ao nó" "$LINES" && ok "node: a linha de log diz que IRIA ao nó (e que hoje não vai)" || bad "linha de log de node ausente"
reset; oracle 1 '{"verdict":"local","reason":"node_full"}'; r=$(run_nf)
[ "$r" = "rc=0" ] && [ "$(rec .verdict)" = local ] && [ "$(rec .reason)" = node_full ] && ok "local/1: registra local e o motivo" || bad "registro de local errado"
reset; oracle 2 '{"verdict":"unknown","reason":"reading_stale"}'; r=$(run_nf)
[ "$r" = "rc=0" ] && [ "$(rec .verdict)" = unknown ] && grep -q "LOG.*não sei se o nó pode" "$LINES" && ok "unknown/2: registra unknown, nunca node" || bad "registro de unknown errado"

echo "── o oráculo e o exit code têm que concordar; falha nunca vira node"
reset; oracle 1 '{"verdict":"node","reason":"free_slot"}'; r=$(run_nf)
[ "$r" = "rc=0" ] && [ "$(rec .verdict)" = unknown ] && [ "$(rec .reason)" = "oraculo_incoerente(rc=1,verdict=node)" ] && ok "JSON diz node mas exit 1 → unknown (contradição)" || bad "node com exit 1 virou '$(rec .verdict)'"
reset; oracle 0 'isto nao e json'; r=$(run_nf)
[ "$r" = "rc=0" ] && [ "$(rec .verdict)" = unknown ] && ok "exit 0 com saída que não é JSON → unknown" || bad "saída ilegível virou '$(rec .verdict)'"
reset; oracle 0 ''; r=$(run_nf)
[ "$r" = "rc=0" ] && [ "$(rec .verdict)" = unknown ] && [ "$(rec .reason)" = "oraculo_sem_resposta(rc=0)" ] && ok "exit 0 sem saída nenhuma → unknown (sem resposta)" || bad "saída vazia virou '$(rec .verdict)' / '$(rec .reason)'"
reset; r=$(run_nf)
[ "$r" = "rc=0" ] && [ "$(rec .verdict)" = unknown ] && [ "$(rec .reason)" = "oraculo_sem_resposta(rc=127)" ] && ok "oráculo que nem roda (rc 127): a função NÃO aborta sob set -e; registra unknown" || bad "oráculo ausente derrubou ou virou '$(rec .verdict)' (r=$r)"
reset; oracle 0 '{"verdict":"local","reason":"x"}'; r=$(run_nf)
[ "$(rec .verdict)" = unknown ] && ok "JSON diz local mas exit 0 → unknown (contradição nos dois sentidos)" || bad "local com exit 0 virou '$(rec .verdict)'"

echo "── o registro não pode derrubar o despacho"
reset; oracle 0 '{"verdict":"node","reason":"free_slot"}'; mkdir -p "$WORK/ro"; chmod 555 "$WORK/ro"
r=$(NF_LOG="$WORK/ro/sub/shadow.jsonl" run_nf)
[ "$r" = "rc=0" ] && grep -q "WARN.*não consegui gravar a decisão-sombra" "$LINES" && ok "log que não grava: avisa e devolve 0" || bad "log não gravável derrubou ou não avisou (r=$r)"
chmod 755 "$WORK/ro"

echo "── a chamada no dispatch_one"
ncalls=$(grep -c '^  _pilot_node_first_shadow "\$STORY_ID" "\$_SLING_TARGET" "\$_IS_RIG_NATIVE" "\$STORY_LABELS" || true$' "$DISPATCHER")
l_native=$(grep -n '^  \[ "\$STORY_BEAD_CITY" != "\$GC_CITY" \] && _IS_RIG_NATIVE=1$' "$DISPATCHER" | head -1 | cut -d: -f1)
l_call=$(grep -n '^  _pilot_node_first_shadow "\$STORY_ID"' "$DISPATCHER" | head -1 | cut -d: -f1)
l_dry=$(awk -v s="${l_call:-0}" 'NR>s && /^  if \[ "\$DRY_RUN" = "1" \]; then$/ {print NR; exit}' "$DISPATCHER")
[ "$ncalls" = 1 ] && ok "a chamada existe UMA vez, com || true" || bad "chamada no dispatch_one: $ncalls ocorrências (esperava 1, com || true)"
[ -n "$l_native" ] && [ -n "$l_call" ] && [ "$l_call" -gt "$l_native" ] && ok "a chamada vem DEPOIS de _IS_RIG_NATIVE ser calculado (l.$l_native → l.$l_call)" || bad "a chamada não vem depois de _IS_RIG_NATIVE ($l_native / $l_call)"
[ -n "$l_dry" ] && ok "e antes do bloco de despacho (DRY_RUN/sling/assign em l.$l_dry)" || bad "não achei o bloco de despacho depois da chamada"

if [ -n "${NF_MUTANT:-}" ]; then echo "RESULT $FAIL/$((PASS+FAIL))"; [ "$FAIL" = 0 ]; exit $?; fi
if [ -z "${NF_NO_MUTANTS:-}" ]; then
  echo "── controle negativo: cada mutante tem que reprovar a bateria"
  nm=0
  mutant() {  # mutant DESCRIÇÃO ANTES DEPOIS
    nm=$((nm+1)); local m="$WORK/disp.mut$nm.sh"
    python3 -I -c 'import sys
s=open(sys.argv[1],encoding="utf-8").read()
if s.count(sys.argv[2])!=1: sys.exit(3)
open(sys.argv[4],"w",encoding="utf-8").write(s.replace(sys.argv[2],sys.argv[3]))' "$DISPATCHER" "$2" "$3" "$m" 2>/dev/null \
      || { bad "mutante '$1': a âncora não casa exatamente 1 vez"; return; }
    local r; r=$(NF_MUTANT=1 PILOT_DISPATCHER_PATH="$m" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) bad "mutante '$1' NÃO foi pego ($r)" ;; "RESULT "*) ok "mutante '$1' pego ($r)" ;; *) bad "mutante '$1': sem resultado ($r)" ;; esac
  }
  export PATH_ORIG="$PATH"
  mutant "sem a checagem de coerência rc×veredito" '      node:0|local:1|unknown:2) : ;;' '      node:*|local:*|unknown:*) : ;;'
  mutant "off consulta mesmo assim" '    off) return 0 ;;' '    off) : ;;'
  mutant "veto por substring" '*",$_nf_l,"*) _nf_v="local"' '*"$_nf_l"*) _nf_v="local"'
  mutant "sem o filtro de pool" '  if [ "$_nf_target" != "gastown.dog" ] || [ "$_nf_native" != "0" ]; then return 0; fi' '  :'
  mutant "padrão vira shadow" 'PILOT_NODE_FIRST="${PILOT_NODE_FIRST:-off}"' 'PILOT_NODE_FIRST="${PILOT_NODE_FIRST:-shadow}"'
fi
echo "── $PASS ok, $FAIL falhas"
[ "$FAIL" = 0 ]
