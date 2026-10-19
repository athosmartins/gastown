#!/usr/bin/env bash
# prod-tests/gascity/story-ga-2hd02v.1.14.sh — prod test para ga-2hd02v.1.14: o modo `on` do PILOT_NODE_FIRST (o Pilot leva a bead de dog ao alias dog-remote-<n>, abre a sessão e avisa).
# O que esta fatia PROMETE é entregar o código com a chave DESLIGADA (ligar é decisão do Mayor, depois da sombra); por isso o teste confere primeiro a inércia (padrão off, o desvio só
# sob `on` + veredito node + fora de DRY_RUN, falha vira mini) e só depois roda as baterias contra a árvore viva.
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-2hd02v.1.14). Sai 0 se passar. Hermético: não fala com o nó, não chama `gc` nem `bd` reais (as baterias usam gc/bd FALSOS num PATH
# isolado), não toca em .gc/ vivo. Não roda os mutantes (são a evidência do gate): só a bateria de casos.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
PILOT="$ASSETS/pilot-dispatcher.sh"
NDT="$ASSETS/pilot-dispatcher.node-dispatch.selftest.sh"
NFT="$ASSETS/pilot-dispatcher.node-first.selftest.sh"
SET="$ASSETS/pilot-dispatcher.sweep-event.selftest.sh"
RUNBOOK="$CITY/docs/runbooks/hetzner-capacity.md"

log()  { echo "[prod-test:gascity ga-2hd02v.1.14] $*"; }
fail() { echo "[prod-test:gascity ga-2hd02v.1.14] FAIL: $*" >&2; exit 1; }

for f in "$PILOT" "$NDT" "$NFT" "$SET" "$RUNBOOK"; do [[ -f "$f" ]] || fail "arquivo implantado ausente: $f"; done
for f in "$PILOT" "$NDT" "$NFT" "$SET"; do bash -n "$f" 2>/dev/null || fail "erro de sintaxe em $f"; done
log "arquivos presentes, sintaxe ok"

# ── INÉRCIA: o Pilot entregue vem desligado e o desvio ao nó só existe sob a guarda tripla
grep -q '^PILOT_NODE_FIRST="${PILOT_NODE_FIRST:-off}"$' "$PILOT" || fail "o padrão de PILOT_NODE_FIRST no pilot-dispatcher.sh não é off"
grep -q "valores: off | shadow | on" "$PILOT" || fail "o pilot-dispatcher.sh não recusa valor desconhecido de PILOT_NODE_FIRST"
n=$(grep -c '^  if \[ "\$DRY_RUN" != "1" \] && \[ "\$PILOT_NODE_FIRST" = "on" \] && \[ "\${_PNF_VERDICT:-}" = "node" \]; then$' "$PILOT")
[[ "$n" == 1 ]] || fail "a guarda tripla do desvio ao nó (DRY_RUN != 1, on, veredito node) aparece $n vezes (esperado 1)"
n=$(grep -c '_pilot_node_first_dispatch "\$STORY_ID" "\$STORY_BEAD_CITY" "\$STORY_TITLE" "\${_PNF_EFFECTIVE:-}"' "$PILOT")
[[ "$n" == 1 ]] || fail "a chamada _pilot_node_first_dispatch no dispatch_one aparece $n vezes (esperado 1)"
grep -q 'DISPATCH_RESULT="node_rollback_unconfirmed"' "$PILOT" || fail "o desfazer não confirmado não tem resultado próprio (node_rollback_unconfirmed)"
log "Pilot: padrão off, desvio só sob on + node + fora de DRY_RUN, desfazer não confirmado nomeado ✓"

# ── O runbook diz como ligar, desligar e ler
for key in '## Contents' 'Ligar e desligar o nó primeiro' 'node_ok' 'node_rollback_unconfirmed' 'ga-2hd02v.1.14' 'DRY_RUN' 'Medido, inferido, não testado'; do
  grep -q -- "$key" "$RUNBOOK" || fail "runbook não descreve '$key'"
done
log "runbook ✓"

run_suite() { # rótulo, padrão da linha de resultado, mínimo de casos, comando...
  local label="$1" pat="$2" min="$3"; shift 3
  local out; out="$("$@" 2>&1)" || { echo "$out" | tail -30 >&2; fail "$label falhou (ou estourou o prazo) contra a árvore viva"; }
  local line; line=$(printf '%s\n' "$out" | grep -E "$pat" | tail -1)
  [[ -n "$line" ]] || fail "$label sem a linha de resultado ($pat):
$(printf '%s\n' "$out" | tail -8)"
  local nums; nums=$(printf '%s' "$line" | grep -oE '[0-9]+' | head -2 | tr '\n' ' ')
  # shellcheck disable=SC2086
  set -- $nums
  [[ "$1" -ge "$min" ]] || fail "$label reportou '$line' (esperado pelo menos $min casos)"
  log "$label: $line ✓"
}
run_suite "bateria do despacho ao nó (on)" '^── [0-9]+ ok, 0 falhas$' 50 env ND_NO_MUTANTS=1 timeout 300 bash "$NDT"
run_suite "bateria do Pilot (modo sombra/on)" '^── [0-9]+ ok, 0 falhas$' 40 env NF_NO_MUTANTS=1 timeout 300 bash "$NFT"
run_suite "bateria do evento de sweep" 'passed, 0 failed$' 50 timeout 300 bash "$SET"

log "PASS"
exit 0
