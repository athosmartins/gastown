#!/usr/bin/env bash
# inflight-reclaim-guard.worktree-rail.selftest.sh — o reclaim guard e o trilho de progresso do WORKTREE (ga-s90p58a).
#
# Contents
#   O que prova · Como roda · Saída
#
# O QUE PROVA: o trilho "há branch recente?" do guard só lê refs/remotes/origin/; uma bead de rig SEM remote (traco-bim) não tinha trilho de progresso, e o trabalho vivo e não commitado do worktree
#   ~/gt/<rig>-wt/<bead> não segurava o reclaim (depois do ga-lotseol a bead do dog morto é reclamada no prazo normal, mesmo com 3 arquivos não commitados no disco). Os checks WT-* dentro do `--selftest`
#   do guard provam a regra com git de verdade (repos sem remote, worktrees, datas de commit e mtimes fixados): commit ou alteração no working tree dentro de RECLAIM_TTL segura; parado há mais que isso
#   = reclaim normal; git que erra, estoura o prazo, saída ilegível, worktree que sumiu, carimbo no futuro = "pode haver progresso" (segura), com aviso visível e contado; e o `run_cycle` REAL, ponta a
#   ponta, nas cenas do aceite. Este script prova que esses checks PRENDEM a regra: roda o executor de mutantes, que troca um trecho por vez numa cópia do guard e exige que o check certo reprove, e
#   prova que o executor não devolve verde quando não deveria (guard ausente, mutante velho, controle vermelho).
# COMO RODA: bash scripts/inflight-reclaim-guard.worktree-rail.selftest.sh   (~2 min no nó Linux, medido: cada filho roda o --selftest inteiro, que monta repos de git em diretórios temporários e
#   roda com GC_SELFTEST=1 e ledger descartável. Bateria com vários filhos: no nó, não no mini:
#   mbp-run.sh --repo hq --dir <worktree>/.gascity-gastown-hq -- scripts/inflight-reclaim-guard.worktree-rail.selftest.sh)
#   WT_RAIL_GUARD_UNDER_TEST=<arquivo>   aponta para outro guard (precisa dos irmãos bead_state.py, gc_ledger.py e park_labels.py ao lado)
# SAÍDA: uma linha ok/FAIL por checagem e `RESULT: <p> passed, <f> failed`; exit 0 só sem falha.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${WT_RAIL_GUARD_UNDER_TEST:-$HERE/inflight-reclaim-guard.py}"
MUT="$HERE/inflight-reclaim-guard.worktree-rail.mutants.py"
[ -f "$GUARD" ] || { echo "FATAL: guard ausente: $GUARD"; exit 2; }
[ -f "$MUT" ] || { echo "FATAL: executor de mutantes ausente: $MUT"; exit 2; }

PASS=0
FAIL=0
check() {  # check <nome> <rc da condição> [detalhe]
  if [ "$2" = 0 ]; then echo "ok: $1"; PASS=$((PASS + 1)); else echo "FAIL: $1${3:+ — $3}"; FAIL=$((FAIL + 1)); fi
}

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/irg-wtrail-st.XXXXXX")" || { echo "FATAL: sem diretório temporário"; exit 2; }
trap 'rm -rf "$SCRATCH"' EXIT

# 1. Guard que não abre = FATAL rc 2, nunca "0 mutantes, todos mortos".
out="$(WT_RAIL_MUTANTS_GUARD=/nonexistent/inflight-reclaim-guard.py python3 -I "$MUT" 2>&1)"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q '^FATAL' && ! printf '%s' "$out" | grep -q 'MUTANTES:'
check "executor: guard que não abre = FATAL rc 2, sem 'MUTANTES:'" $? "rc=$rc saída=$(printf '%s' "$out" | head -c 120)"

# 2. Mutante velho (o trecho não existe mais no guard) = FATAL rc 2: o guard mudou e o mutante deixou de provar algo.
printf '# guard sem nenhum dos trechos dos mutantes\n' > "$SCRATCH/inflight-reclaim-guard.py"
out="$(WT_RAIL_MUTANTS_GUARD="$SCRATCH/inflight-reclaim-guard.py" python3 -I "$MUT" 2>&1)"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'velho' && ! printf '%s' "$out" | grep -q 'MUTANTES:'
check "executor: trecho que sumiu do guard = FATAL rc 2 ('velho'), sem 'MUTANTES:'" $? "rc=$rc saída=$(printf '%s' "$out" | head -c 160)"

# 3. Controle vermelho (o guard TEM todos os trechos, mas o --selftest dele reprova sem mutação alguma) = FATAL rc 2: com o harness reprovando tudo, "todos mortos" não provaria nada.
mkdir "$SCRATCH/red" && cp "$HERE"/bead_state.py "$HERE"/gc_ledger.py "$HERE"/park_labels.py "$SCRATCH/red/" && sed 's/^RECLAIM_TTL = 1500 /RECLAIM_TTL = 1 /' "$GUARD" > "$SCRATCH/red/inflight-reclaim-guard.py"
cmp -s "$GUARD" "$SCRATCH/red/inflight-reclaim-guard.py" && echo "FATAL: o sed do controle vermelho não mudou nada no guard" && exit 2
out="$(WT_RAIL_MUTANTS_GUARD="$SCRATCH/red/inflight-reclaim-guard.py" python3 -I "$MUT" 2>&1)"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'controle vermelho' && ! printf '%s' "$out" | grep -q 'MUTANTES:'
check "executor: controle vermelho (o --selftest reprova sem mutação) = FATAL rc 2, sem 'MUTANTES:'" $? "rc=$rc saída=$(printf '%s' "$out" | head -c 160)"

# 4. A bateria de verdade: controle (cópia sem mutação passa, com os checks WT-*) + todos os mutantes mortos pelo check certo.
out="$(WT_RAIL_MUTANTS_GUARD="$GUARD" python3 -I "$MUT" 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
printf '%s' "$out" | grep -q '^controle: a cópia sem mutação passa'
check "controle: a cópia sem mutação passa o --selftest do guard, com os checks WT-*" $?
total="$(printf '%s' "$out" | sed -n 's/^MUTANTES: [0-9]*\/\([0-9]*\) mortos$/\1/p')"
[ "$rc" = 0 ] && [ -n "$total" ] && [ "$total" -ge 50 ] && printf '%s' "$out" | grep -q "^MUTANTES: $total/$total mortos"
check "todos os mutantes mortos pelo check WT-* que prende a guarda (rc=0, >= 50 mutantes)" $? "rc=$rc total=${total:-?}"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
