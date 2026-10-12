#!/usr/bin/env bash
# prod-tests/gascity/story-ga-77c1qg.2.sh — prod test para ga-77c1qg.2 (fatia 2 de 2 de ga-77c1qg): a chave manual "pausar até eu
# liberar" (do mini e de dentro do MBP), o status que diz o modo e por quê, o `gascity-mbp`, e o reseed noturno que trata a pausa
# como PULADO (nunca FALHOU). Decisão do Athos em 12/10 (comentário de ga-sokx7u): ele precisa poder ligar/desligar à mão e ver
# se o Gas City está usando o MBP e como.
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-77c1qg.2). Sai 0 se passar. Hermético: não toca o MBP nem o log vivo.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
OFFLOAD="$CITY/scripts/mbp-offload.sh"
CONTROLE="$CITY/scripts/mbp-controle.sh"
RUN="$CITY/scripts/mbp-run.sh"
RESEED="$CITY/scripts/mbp-nightly-reseed.sh"
SELFTEST="$CITY/scripts/mbp-run.selftest.sh"
RESEED_SELFTEST="$CITY/scripts/mbp-nightly-reseed.selftest.sh"
RUNBOOK="$CITY/docs/runbooks/mbp-offload.md"

log()  { echo "[prod-test:gascity ga-77c1qg.2] $*"; }
fail() { echo "[prod-test:gascity ga-77c1qg.2] FAIL: $*" >&2; exit 1; }

for f in "$OFFLOAD" "$CONTROLE" "$RUN" "$RESEED" "$SELFTEST" "$RESEED_SELFTEST" "$RUNBOOK"; do [[ -f "$f" ]] || fail "arquivo implantado ausente: $f"; done
for f in "$OFFLOAD" "$CONTROLE" "$RUN" "$RESEED" "$SELFTEST" "$RESEED_SELFTEST"; do bash -n "$f" 2>/dev/null || fail "erro de sintaxe em $f"; done
log "scripts, selftests e runbook presentes; sintaxe ok"

# O `gascity-mbp` não mexe em nada fora de ~/gt-remote (nenhum perfil de shell, nenhum PATH)
if grep -n -E '\.zshrc|\.zprofile|\.bash_profile|\.bashrc|\.profile|LaunchAgents|crontab' "$CONTROLE" | grep -v '^[0-9]*:#' >/dev/null; then
  fail "mbp-controle.sh escreve em perfil de shell/launchd/cron (deveria tocar só em ~/gt-remote)"
fi
# resume só apaga a pausa daqui depois de confirmar que a do MBP saiu: o selftest tem o controle negativo; aqui só a presença da trava
grep -q -- '--local-only' "$OFFLOAD" || fail "mbp-offload.sh sem 'resume --local-only' (única saída quando o MBP não responde)"
# o reseed noturno enxerga a pausa
grep -q 'mbp-offload.pause' "$RESEED" || fail "mbp-nightly-reseed.sh não olha a pausa do Athos"
for key in 'gascity-mbp' 'resume --local-only' 'PULADO' 'SwiftBar'; do grep -q -- "$key" "$RUNBOOK" || fail "runbook não descreve '$key'"; done
log "trava do resume, reseed e runbook ✓"

run_suite() { # rótulo, comando...
  local label="$1"; shift
  local out; out="$("$@" 2>&1)" || { echo "$out" | tail -30 >&2; fail "$label falhou (ou estourou 900 s) contra a árvore viva"; }
  local line; line=$(printf '%s\n' "$out" | grep -E '^[0-9]+/[0-9]+ ok$' | tail -1)
  [[ -n "$line" ]] || fail "$label sem a linha de resultado 'N/N ok':
$out"
  local pass=${line%%/*} rest=${line#*/}; local total=${rest%% *}
  [[ "$pass" == "$total" && "$total" -ge 50 ]] || fail "$label reportou '$line' (esperado todos ok e pelo menos 50 casos)"
  printf '%s\n' "$out" | grep -q 'SELFTEST OK' || fail "$label sem a linha 'SELFTEST OK'"
  log "$label: $line ✓"
}
run_suite "selftest da chave/status/gascity-mbp" env MBP_SELFTEST_ONLY=chave timeout 900 bash "$SELFTEST"
run_suite "selftest do reseed noturno" timeout 900 bash "$RESEED_SELFTEST"

log "PASS"
exit 0
