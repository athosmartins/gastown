#!/usr/bin/env bash
# prod-tests/gascity/story-ga-2hd02v.1.9.sh — revisores do gate no nó Hetzner (gate-reviewer-remote), chegando INERTES.
# Chamado por run.sh depois do deploy. Hermético: não abre sessão, não fala com o nó, não cria a flag, não toca na config viva.
# Revisão de verdade no nó com veredito igual ao do local só se mede com a flag ligada (runbook, "Provar").
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
SELFTEST="$ASSETS/gate-remote-reviewers.selftest.sh"
log()  { echo "[prod-test:gascity ga-2hd02v.1.9] $*"; }
fail() { echo "[prod-test:gascity ga-2hd02v.1.9] FAIL: $*" >&2; exit 1; }

for f in "$ASSETS/gate-remote-reviewers.lib.sh" "$SELFTEST" "$ASSETS/quality-gate-dispatcher.sh" \
         "$CITY/agents/gate-reviewer-remote/agent.toml" "$CITY/agents/gate-reviewer-remote/prompt.template.md" "$CITY/docs/runbooks/gate-reviewer-remote.md"; do
  [[ -f "$f" ]] || fail "arquivo implantado ausente: $f"
done
for f in "$ASSETS/gate-remote-reviewers.lib.sh" "$ASSETS/quality-gate-dispatcher.sh"; do
  bash -n "$f" 2>/dev/null && /bin/bash -n "$f" 2>/dev/null || fail "erro de sintaxe (bash ou /bin/bash 3.2) em $f"
done
log "arquivos implantados presentes; sintaxe ok"

# Chegou INERTE: a flag é decisão do Mayor depois do flip da 1.6; se existir, alguém a ligou de propósito (o teste não a exige nem a remove).
if [[ -e "$CITY/.gc/gate-remote-reviewers.on" ]]; then log "AVISO: a flag .gc/gate-remote-reviewers.on existe (o nó está ligado)"; else log "flag ausente: a fatia chegou inerte ✓"; fi

# Comportamental: o selftest hermético contra a árvore viva (escolha, costura no dispatcher, template, o `decide()` do atalho)
OUT="$(timeout 900 bash "$SELFTEST" 2>&1)" || { echo "$OUT" | tail -40 >&2; fail "o selftest gate-remote-reviewers falhou (ou estourou 900 s) contra a árvore viva"; }
line=$(printf '%s\n' "$OUT" | grep -E '^gate-remote-reviewers selftest: [0-9]+ passed, [0-9]+ failed$' | tail -1)
[[ -n "$line" ]] || fail "selftest sem a linha de resultado: $(printf '%s\n' "$OUT" | tail -5)"
pass=$(printf '%s' "$line" | sed -n 's/.*: \([0-9]*\) passed, \([0-9]*\) failed/\1/p'); nfail=$(printf '%s' "$line" | sed -n 's/.*: \([0-9]*\) passed, \([0-9]*\) failed/\2/p')
[[ "$nfail" == "0" && "${pass:-0}" -ge 100 ]] || fail "selftest reportou '$line' (esperado 0 falhas e pelo menos 100 asserções)"
log "selftest: $line ✓"
log "PASS"
exit 0
