#!/usr/bin/env bash
# prod-tests/gascity/story-ga-77c1qg.1.sh — prod test para ga-77c1qg.1 (fatia 1 de 2 de ga-77c1qg): o MBP é o notebook de
# trabalho do Athos; o Gas City só usa carga alta com evidência positiva de que ele está fora, e nunca sobrecarrega o MBP
# enquanto ele usa (decisão dele em 12/10, comentário de ga-sokx7u).
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-77c1qg.1). Sai 0 se passar. Os scripts do gascity rodam no lugar, então o
# que se confere aqui É a versão em produção. Não toca o MBP nem o log vivo: o selftest é hermético (ssh/ioreg/taskpolicy falsos).
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
RUN="$CITY/scripts/mbp-run.sh"
LIB="$CITY/scripts/mbp-presence.sh"
SELFTEST="$CITY/scripts/mbp-run.selftest.sh"
RUNBOOK="$CITY/docs/runbooks/mbp-offload.md"

log()  { echo "[prod-test:gascity ga-77c1qg.1] $*"; }
fail() { echo "[prod-test:gascity ga-77c1qg.1] FAIL: $*" >&2; exit 1; }

for f in "$RUN" "$LIB" "$SELFTEST" "$RUNBOOK"; do [[ -f "$f" ]] || fail "arquivo implantado ausente: $f"; done
for f in "$RUN" "$LIB" "$SELFTEST"; do bash -n "$f" 2>/dev/null || fail "erro de sintaxe em $f"; done
log "mbp-run.sh, mbp-presence.sh, selftest e runbook presentes; sintaxe ok"

# O runner usa a biblioteca implantada ao lado dele (se ela faltasse, o MBP contaria como EM USO e o ganho sumiria em silêncio)
grep -q 'PRESENCE_LIB="\$HERE/mbp-presence.sh"' "$RUN" || fail "mbp-run.sh não aponta para a biblioteca de presença ao lado dele"
# Só dá para forçar PIORAR: a biblioteca não pode ter um jeito de forçar "livre"
if grep -q -E 'PRESENCE_FORCE_(LIVRE|FREE)|MBP_FORCE_PRESENCE=livre' "$LIB" "$RUN"; then fail "existe um jeito de forçar 'livre' no código implantado"; fi
log "biblioteca ao lado do runner; nada força 'livre' ✓"

# O runbook descreve as regras e a medida
for key in 'Presença do Athos' 'EM USO' 'LIVRE' 'taskpolicy -b' 'MBP_FORCE_PRESENCE' 'MBP_SLOT_MEM_MB' 'mbp-run:demoted'; do
  grep -q -- "$key" "$RUNBOOK" || fail "runbook não descreve '$key'"
done
log "runbook descreve a presença, os tetos e o rebaixamento ✓"

# Comportamental: só a parte de presença do selftest hermético (a suíte antiga tem a própria história e o próprio orçamento)
# 2400 s: medido em 12/10 com o mini a load ~90, a suíte inteira (a antiga + esta) levou 26 min, e a parte de presença é a maior; o harness não impõe limite global
OUT="$(MBP_SELFTEST_ONLY=presenca timeout 2400 bash "$SELFTEST" 2>&1)" || {
  echo "$OUT" | tail -30 >&2
  fail "o selftest de presença falhou (ou estourou 2400 s) contra a árvore viva"
}
line=$(printf '%s\n' "$OUT" | grep -E '^[0-9]+/[0-9]+ ok$' | tail -1)
[[ -n "$line" ]] || fail "selftest sem a linha de resultado 'N/N ok':
$OUT"
pass=${line%%/*}; rest=${line#*/}; total=${rest%% *}
[[ "$pass" == "$total" && "$total" -ge 100 ]] || fail "selftest reportou '$line' (esperado todos ok e pelo menos 100 casos)"
printf '%s\n' "$OUT" | grep -q 'SELFTEST OK' || fail "selftest sem a linha 'SELFTEST OK'"
log "selftest de presença: $line ✓"

log "PASS"
exit 0
