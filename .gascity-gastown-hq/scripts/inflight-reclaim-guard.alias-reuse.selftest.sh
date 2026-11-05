#!/usr/bin/env bash
# inflight-reclaim-guard.alias-reuse.selftest.sh — o reclaim guard e o alias de slot de pool reaproveitado (ga-lotseol).
#
# Contents
#   O que prova · Como roda · Saída
#
# O QUE PROVA: o alias de um slot de pool (gastown.dog-2) é reaproveitado por cada nova sessão do slot. Um dog que morre no meio do claim deixa a bead com assignee=<alias>, e a sessão nova
#   que herdou o alias a "segura" para sempre (wa-6g3m49, wa-25odi9.1, wa-e4ca55.3 em 05/11). Os checks LS-* dentro do `--selftest` do guard provam a regra (bead parada desde ANTES de a sessão
#   nascer não é dela; crew de alias estável, id/session_name e dado ilegível seguem valendo como dono). Este script prova que esses checks PRENDEM a regra: roda o executor de mutantes, que
#   troca um trecho por vez numa cópia do guard — ou da lib bead_state.py, onde mora o corpo da regra desde o ga-d63o9n1 — e exige que o check certo reprove, e prova que o executor não devolve
#   verde quando não deveria (guard ou lib ausente, mutante velho).
# COMO RODA: bash scripts/inflight-reclaim-guard.alias-reuse.selftest.sh   (~35 s no nó Linux, medido; o --selftest do guard é hermético por desenho, ga-dbibq, e cada cópia roda com
#   GC_SELFTEST=1 e ledger descartável. Bateria com vários filhos: no nó, não no mini:
#   mbp-run.sh --repo hq --dir <worktree>/.gascity-gastown-hq -- scripts/inflight-reclaim-guard.alias-reuse.selftest.sh)
#   ALIAS_GUARD_UNDER_TEST=<arquivo>   aponta para outro guard (precisa dos irmãos bead_state.py, gc_ledger.py e park_labels.py ao lado; a bead_state.py ao lado dele é a lib mutada)
# SAÍDA: uma linha ok/FAIL por checagem e `RESULT: <p> passed, <f> failed`; exit 0 só sem falha.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${ALIAS_GUARD_UNDER_TEST:-$HERE/inflight-reclaim-guard.py}"
MUT="$HERE/inflight-reclaim-guard.alias-reuse.mutants.py"
LIB="$(dirname "$GUARD")/bead_state.py"
[ -f "$GUARD" ] || { echo "FATAL: guard ausente: $GUARD"; exit 2; }
[ -f "$MUT" ] || { echo "FATAL: executor de mutantes ausente: $MUT"; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: lib ausente: $LIB"; exit 2; }

PASS=0
FAIL=0
check() {  # check <nome> <rc da condição> [detalhe]
  if [ "$2" = 0 ]; then echo "ok: $1"; PASS=$((PASS + 1)); else echo "FAIL: $1${3:+ — $3}"; FAIL=$((FAIL + 1)); fi
}

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/irg-alias-st.XXXXXX")" || { echo "FATAL: sem diretório temporário"; exit 2; }
trap 'rm -rf "$SCRATCH"' EXIT

# 1. Guard que não abre = FATAL rc 2, nunca "0 mutantes, todos mortos".
out="$(ALIAS_MUTANTS_GUARD=/nonexistent/inflight-reclaim-guard.py python3 -I "$MUT" 2>&1)"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q '^FATAL' && ! printf '%s' "$out" | grep -q 'MUTANTES:'
check "executor: guard que não abre = FATAL rc 2, sem 'MUTANTES:'" $? "rc=$rc saída=$(printf '%s' "$out" | head -c 120)"

# 2. Mutante velho (o trecho não existe mais no guard) = FATAL rc 2: o guard mudou e o mutante deixou de provar algo.
printf '# guard sem nenhum dos trechos dos mutantes\n' > "$SCRATCH/inflight-reclaim-guard.py"
out="$(ALIAS_MUTANTS_GUARD="$SCRATCH/inflight-reclaim-guard.py" ALIAS_MUTANTS_LIB="$LIB" python3 -I "$MUT" 2>&1)"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'velho' && ! printf '%s' "$out" | grep -q 'MUTANTES:'
check "executor: trecho que sumiu do guard = FATAL rc 2 ('velho'), sem 'MUTANTES:'" $? "rc=$rc saída=$(printf '%s' "$out" | head -c 160)"

# 2b. A lib (onde mora o corpo da regra) vale o mesmo para o open() do inflight-reclaim-guard.alias-reuse.mutants.py: ausente = FATAL; trecho que sumiu dela = FATAL 'velho'. Sem isto, mover a regra de novo deixaria os mutantes de corpo mirando o vazio.
out="$(ALIAS_MUTANTS_GUARD="$GUARD" ALIAS_MUTANTS_LIB=/nonexistent/bead_state.py python3 -I "$MUT" 2>&1)"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q '^FATAL' && ! printf '%s' "$out" | grep -q 'MUTANTES:'
check "executor: lib que não abre = FATAL rc 2, sem 'MUTANTES:'" $? "rc=$rc saída=$(printf '%s' "$out" | head -c 120)"
printf '# lib sem nenhum dos trechos dos mutantes\n' > "$SCRATCH/bead_state.py"
out="$(ALIAS_MUTANTS_GUARD="$GUARD" ALIAS_MUTANTS_LIB="$SCRATCH/bead_state.py" python3 -I "$MUT" 2>&1)"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'velho.*lib' && ! printf '%s' "$out" | grep -q 'MUTANTES:'
check "executor: trecho que sumiu da lib = FATAL rc 2 ('velho', nomeia a lib), sem 'MUTANTES:'" $? "rc=$rc saída=$(printf '%s' "$out" | head -c 160)"

# 3. A bateria de verdade: controle (cópia sem mutação passa, com os checks LS-*) + todos os mutantes mortos pelo check certo.
out="$(ALIAS_MUTANTS_GUARD="$GUARD" python3 -I "$MUT" 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
printf '%s' "$out" | grep -q '^controle: a cópia sem mutação passa'
check "controle: a cópia sem mutação passa o --selftest do guard, com os checks LS-*" $?
total="$(printf '%s' "$out" | sed -n 's/^MUTANTES: [0-9]*\/\([0-9]*\) mortos$/\1/p')"
[ "$rc" = 0 ] && [ -n "$total" ] && [ "$total" -ge 14 ] && printf '%s' "$out" | grep -q "^MUTANTES: $total/$total mortos"
check "todos os mutantes mortos pelo check LS-* que prende a guarda (rc=0, >= 14 mutantes)" $? "rc=$rc total=${total:-?}"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
