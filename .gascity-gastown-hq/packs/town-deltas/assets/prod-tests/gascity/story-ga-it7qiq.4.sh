#!/usr/bin/env bash
# prod-tests/gascity/story-ga-it7qiq.4.sh — prod test para ga-it7qiq.4: o Pilot decide em memória, com a listagem de refs que já tem, o POSITIVO do `_filter_built`
# (bead que já tem branch de entrega), em vez de rodar a função exata (1 + até 14 `git for-each-ref`) por par (bead, repo).
# O que a fatia PROMETE: mesmo veredito (achou/não achou) e mesma ref no log que a função exata — inclusive para ref com '/' depois do id (fix/<id>-x/y, crew/a/b/<id>), que o
# git NÃO devolve para o glob (casa por caminho: '*' não atravessa '/') e que um `case` do bash aceitaria; o custo de git de uma passada cai para UMA listagem por repo; repo cuja
# listagem falhou, id com caractere de glob e lista de globs vazia continuam "não consegui saber" (candidato MANTIDO e contado), nunca "não tem branch".
# O Pilot lê o pilot-dispatcher.sh do disco a cada varredura (não há daemon a reiniciar): o que está em disco é o que roda na próxima passada.
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-it7qiq.4). Sai 0 se passar. Hermético: a bateria usa repos git descartáveis, shims de `bd`/`git` e uma cidade temporária;
# nada de Dolt, bead ou repo vivos. Não roda os mutantes (FBB_SKIP_MUTATION=1; são a evidência do gate): só as checagens do veredito, do custo e dos três estados.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
DISP="$ASSETS/pilot-dispatcher.sh"
LIB="$ASSETS/delivery-branch-patterns.sh"
SELF="$ASSETS/pilot-dispatcher.filter-built-batch.selftest.sh"
BASH32=/bin/bash

log()  { echo "[prod-test:gascity ga-it7qiq.4] $*"; }
fail() { echo "[prod-test:gascity ga-it7qiq.4] FAIL: $*" >&2; exit 1; }

[[ -x "$BASH32" ]] || fail "$BASH32 não executa — não dá para checar a sintaxe no interpretador de produção"
for f in "$DISP" "$LIB" "$SELF"; do [[ -f "$f" ]] || fail "arquivo implantado ausente: $f"; done
for f in "$DISP" "$LIB" "$SELF"; do "$BASH32" -n "$f" 2>/dev/null || fail "$f não parseia sob $BASH32"; done
log "arquivos implantados presentes; sintaxe ok sob $BASH32"

# ── O que está implantado é a versão com a decisão em memória: o casamento por caminho sobre as linhas do índice e a sonda de globs
n=$(grep -c '_matched_ref=\$(_delivery_branch_listed_ref "\$id" <<< "\$_bf_lines") || _bf_rc=\$?' "$DISP")
[[ "$n" == 1 ]] || fail "o _filter_built não decide o positivo em memória com _delivery_branch_listed_ref ($n ocorrências, esperado 1)"
n=$(grep -c '^_delivery_branch_listed_ref() {' "$DISP")
[[ "$n" == 1 ]] || fail "_delivery_branch_listed_ref não está definida uma vez no dispatcher ($n definições)"
n=$(grep -c '\[ "\${#_t}" -eq "\$_gs" \] || continue' "$DISP")
[[ "$n" == 1 ]] || fail "o casamento em memória não exige o mesmo número de '/' do glob — aceitaria fix/<id>-x/y, que o git não devolve ($n ocorrências, esperado 1)"
n=$(grep -c '&& gc_delivery_branch_globs "ga-probe" >/dev/null 2>&1; then' "$DISP")
[[ "$n" == 1 ]] || fail "o pré-filtro não confere que há lista de globs antes de ler 'sem ref' como 'sem branch' ($n ocorrências, esperado 1)"
log "dispatcher implantado: positivo em memória, casamento por caminho (mesmo nº de '/'), sonda de globs ✓"

# ── A bateria da fatia contra a árvore viva (sem os mutantes): veredito, custo (uma listagem por repo, nenhuma por bead) e os três estados
out="$(env FBB_SKIP_MUTATION=1 timeout 900 "$BASH32" "$SELF" 2>&1)" || { printf '%s\n' "$out" | grep -E '^  BAD' | head -20 >&2; printf '%s\n' "$out" | tail -5 >&2; fail "a bateria filter-built-batch falhou (ou estourou o prazo) contra a árvore viva"; }
line=$(printf '%s\n' "$out" | grep -E '^== filter-built-batch: [0-9]+ passed, [0-9]+ failed ==$' | tail -1)
[[ -n "$line" ]] || fail "a bateria sem a linha de resultado: $(printf '%s\n' "$out" | tail -4)"
set -- $(printf '%s' "$line" | grep -oE '[0-9]+' | head -2)
[[ "$2" == "0" && "$1" -ge 33 ]] || fail "a bateria reportou '$line' (esperado 0 falhas e pelo menos 33 checagens sem os mutantes)"
printf '%s\n' "$out" | grep -q '^  ok: 14 candidates .*one listing per repo, none per bead' || fail "a bateria não provou o custo de uma listagem por repo (a linha da seção 2 sumiu)"
printf '%s\n' "$out" | grep -qF "  ok: a '/' inside the fix/<id>-* tail is no delivery -> |rc=1" || fail "a bateria não provou que fix/<id>-x/y não é entrega (a linha da seção 2d sumiu)"
printf '%s\n' "$out" | grep -qF "  ok: git itself: fix/<id>-*, crew/*/<id> and crew/*/<id>-* return none of the three slash-tail refs" || fail "a bateria não fixou a premissa sobre o git (glob por caminho) — a linha da seção 2d sumiu ou o git mudou"
log "bateria filter-built-batch: $line ✓"

log "PASS"
exit 0
