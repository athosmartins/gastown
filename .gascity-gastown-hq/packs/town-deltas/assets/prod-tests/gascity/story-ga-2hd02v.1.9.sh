#!/usr/bin/env bash
# prod-tests/gascity/story-ga-2hd02v.1.9.sh — prod test para ga-2hd02v.1.9: revisores do gate no nó Hetzner (gate-reviewer-remote).
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-2hd02v.1.9). Sai 0 se passar. Os scripts rodam no lugar, então o que se confere
# aqui É a versão em produção. Hermético: não abre sessão, não fala com o nó, não cria a flag, não toca na config viva. O que isto
# prova é a ESCOLHA e a COSTURA (o selftest usa `gc`, `bd` e `gc-session-ssh` de mentira) e que a fatia chegou INERTE. Que um revisor
# do nó conclui uma revisão com veredito igual ao do local só se mede com a flag ligada, depois do flip da 1.6 (runbook, "Provar").
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
LIB="$ASSETS/gate-remote-reviewers.lib.sh"
SELFTEST="$ASSETS/gate-remote-reviewers.selftest.sh"
DISPATCHER="$ASSETS/quality-gate-dispatcher.sh"
TOML="$CITY/agents/gate-reviewer-remote/agent.toml"
PROMPT="$CITY/agents/gate-reviewer-remote/prompt.template.md"
RUNBOOK="$CITY/docs/runbooks/gate-reviewer-remote.md"

log()  { echo "[prod-test:gascity ga-2hd02v.1.9] $*"; }
fail() { echo "[prod-test:gascity ga-2hd02v.1.9] FAIL: $*" >&2; exit 1; }

for f in "$LIB" "$SELFTEST" "$DISPATCHER" "$TOML" "$PROMPT" "$RUNBOOK"; do [[ -f "$f" ]] || fail "arquivo implantado ausente: $f"; done
for f in "$LIB" "$SELFTEST" "$DISPATCHER"; do
  bash -n "$f" 2>/dev/null || fail "erro de sintaxe em $f"
  /bin/bash -n "$f" 2>/dev/null || fail "erro de sintaxe no bash do sistema (3.2) em $f"
done
log "lib, selftest, dispatcher, template, prompt e runbook presentes; sintaxe ok (bash e /bin/bash)"

# O dispatcher carrega a lib e a usa nos dois pontos de spawn; sem isso a fatia é letra morta
grep -q 'gate-remote-reviewers.lib.sh' "$DISPATCHER" || fail "o dispatcher implantado não carrega gate-remote-reviewers.lib.sh"
[[ "$(grep -c 'gate_remote_pick_template || true' "$DISPATCHER")" == "2" ]] || fail "o dispatcher deveria escolher o template em 2 pontos (Step 7 e re-convocação)"
grep -q 'SELFTEST-EXTRACT reviewer-spawn-node-first: BEGIN' "$DISPATCHER" || fail "dispatcher sem o bloco node-first"
log "dispatcher carrega a lib e escolhe nos 2 pontos de spawn ✓"

# O template: não é singleton (o guarda crew-session-dedup mataria o 2º), não tem sessão de pé, e não tem prompt que o atalho recuse
[[ "$(sed -n 's/^max_active_sessions *= *\([0-9]*\).*/\1/p' "$TOML")" == "2" ]] || fail "agent.toml: max_active_sessions deveria ser 2"
[[ "$(sed -n 's/^min_active_sessions *= *\([0-9]*\).*/\1/p' "$TOML")" == "0" ]] || fail "agent.toml: min_active_sessions deveria ser 0"
if grep -q 'drain-ack && exit' "$PROMPT"; then fail "o prompt do nó manda rodar drain-ack, que o atalho recusa"; fi
log "template: máx 2, mín 0, prompt sem drain-ack ✓"

# Chegou INERTE: a flag é decisão do Mayor depois do flip da 1.6. Esta fatia não a cria; se existir, alguém a ligou de propósito, e só avisamos.
if [[ -e "$CITY/.gc/gate-remote-reviewers.on" ]]; then
  log "AVISO: a flag .gc/gate-remote-reviewers.on existe (alguém ligou o nó); o teste não a exige nem a remove"
else
  log "flag .gc/gate-remote-reviewers.on ausente: a fatia chegou inerte ✓"
fi

# O runbook descreve o que o Mayor precisa para ligar e provar
for key in 'Ligar' 'Provar' 'gate-remote-reviewers.on' 'worktree_rigs' 'rc 77' 'bd comment' 'idle_timeout' 'Decisões que são do Mayor' 'THIRD STATE'; do
  grep -q -- "$key" "$RUNBOOK" || fail "runbook não descreve '$key'"
done
log "runbook descreve ligar, provar, o rc 77, o teto e as decisões do Mayor ✓"

# Comportamental: o selftest hermético contra a árvore viva (inclui o `decide()` do atalho com o texto real da tarefa e os mutantes)
OUT="$(timeout 900 bash "$SELFTEST" 2>&1)" || {
  echo "$OUT" | tail -40 >&2
  fail "o selftest gate-remote-reviewers falhou (ou estourou 900 s) contra a árvore viva"
}
line=$(printf '%s\n' "$OUT" | grep -E '^gate-remote-reviewers selftest: [0-9]+ passed, [0-9]+ failed$' | tail -1)
[[ -n "$line" ]] || fail "selftest sem a linha de resultado:
$(printf '%s\n' "$OUT" | tail -10)"
pass=$(printf '%s' "$line" | sed -n 's/.*: \([0-9]*\) passed, \([0-9]*\) failed/\1/p'); nfail=$(printf '%s' "$line" | sed -n 's/.*: \([0-9]*\) passed, \([0-9]*\) failed/\2/p')
[[ "$nfail" == "0" && "${pass:-0}" -ge 140 ]] || fail "selftest reportou '$line' (esperado 0 falhas e pelo menos 140 asserções)"
printf '%s\n' "$OUT" | grep -q 'mutant .* killed' || fail "selftest sem mutantes mortos"
if printf '%s\n' "$OUT" | grep -q 'SURVIVED'; then fail "selftest com mutante sobrevivente"; fi
log "selftest: $line ✓"

log "PASS"
exit 0
