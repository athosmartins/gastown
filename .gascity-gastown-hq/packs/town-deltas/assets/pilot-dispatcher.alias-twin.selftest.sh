#!/usr/bin/env bash
# pilot-dispatcher.alias-twin.selftest.sh — o Pilot e o alias de slot de pool reaproveitado (ga-d63o9n1).
#
# Contents
#   O que prova · Como roda · Saída
#
# O QUE PROVA: os cenários AT-* do pilot-dispatcher.session-liveness.selftest.sh provam a regra do gêmeo de alias na ponte do Pilot (a sessão que casa o assignee SÓ pelo alias do slot e nasceu depois do
#   último toque da bead não é o builder). Este script prova que esses cenários PRENDEM a regra: roda o executor de mutantes (pilot-dispatcher.alias-twin.mutants.py), que troca um trecho por vez numa
#   cópia — da bead_state.py ou do pilot-dispatcher.sh — e exige que o cenário certo reprove, e prova que o executor não devolve verde quando não deveria (alvo ausente, mutante velho).
# COMO RODA: bash pilot-dispatcher.alias-twin.selftest.sh   (~20 s no nó Linux, medido)
# SAÍDA: uma linha ok/FAIL por checagem e `RESULT: <p> passed, <f> failed`; exit 0 só sem falha.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUT="$HERE/pilot-dispatcher.alias-twin.mutants.py"
[ -f "$MUT" ] || { echo "FATAL: executor de mutantes ausente: $MUT"; exit 2; }

PASS=0
FAIL=0
check() {  # check <nome> <rc da condição> [detalhe]
  if [ "$2" = 0 ]; then echo "ok: $1"; PASS=$((PASS + 1)); else echo "FAIL: $1${3:+ — $3}"; FAIL=$((FAIL + 1)); fi
}

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/pd-twin-st.XXXXXX")" || { echo "FATAL: sem diretório temporário"; exit 2; }
trap 'rm -rf "$SCRATCH"' EXIT
printf '# arquivo sem nenhum dos trechos dos mutantes\n' > "$SCRATCH/stale.txt"

# 1. Alvo que não abre, ou trecho que sumiu dele (mutante velho) = FATAL rc 2, nunca "0 mutantes, todos mortos".
fatal_case() {  # fatal_case <descrição> <padrão da linha FATAL> VAR=valor...
  local desc="$1" pat="$2" out rc
  shift 2
  out="$(env "$@" python3 -I "$MUT" 2>&1)"; rc=$?
  [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "^FATAL.*$pat" && ! printf '%s' "$out" | grep -q 'MUTANTES:'
  check "executor: $desc = FATAL rc 2, sem 'MUTANTES:'" $? "rc=$rc saída=$(printf '%s' "$out" | head -c 140)"
}
fatal_case "pilot-dispatcher.sh que não abre" "ausente" ALIAS_TWIN_MUTANTS_DISPATCHER=/nonexistent/pilot-dispatcher.sh
fatal_case "bead_state.py que não abre" "ausente" ALIAS_TWIN_MUTANTS_LIB=/nonexistent/bead_state.py
fatal_case "trecho que sumiu do pilot-dispatcher.sh" "velho" ALIAS_TWIN_MUTANTS_DISPATCHER="$SCRATCH/stale.txt"
fatal_case "trecho que sumiu da bead_state.py" "velho" ALIAS_TWIN_MUTANTS_LIB="$SCRATCH/stale.txt"

# 2. A bateria de verdade: controle (cópia sem mutação passa, com os cenários AT-*) + todos os mutantes mortos pelo cenário certo.
out="$(python3 -I "$MUT" 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
printf '%s' "$out" | grep -q '^controle: a cópia sem mutação passa'
check "controle: a cópia sem mutação passa o selftest de liveness, com os cenários AT-*" $?
total="$(printf '%s' "$out" | sed -n 's/^MUTANTES: [0-9]*\/\([0-9]*\) mortos$/\1/p')"
[ "$rc" = 0 ] && [ -n "$total" ] && [ "$total" -ge 13 ] && printf '%s' "$out" | grep -q "^MUTANTES: $total/$total mortos"
check "todos os mutantes mortos pelo cenário que prende a guarda (rc=0, >= 13 mutantes)" $? "rc=$rc total=${total:-?}"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
