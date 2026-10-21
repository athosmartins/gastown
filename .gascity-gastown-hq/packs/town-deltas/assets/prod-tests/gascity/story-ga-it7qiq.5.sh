#!/usr/bin/env bash
# prod-tests/gascity/story-ga-it7qiq.5.sh — prod test para ga-it7qiq.5: cache de TTL curto do `list-running` no provider de sessões (scripts/gc-session-ssh).
# O que a fatia PROMETE: a resposta BOA do host é reaproveitada por até `list_cache_s` s (10 por padrão) e start/stop a invalidam; erro, ssh fora e resposta cortada continuam erro quando o ssh é
# tentado (o cache nunca é o plano B de um erro e erro nunca vira lista vazia); `list_cache_s: 0` desliga. Cada chamada do engine é um processo novo do script, então não há daemon a reiniciar:
# o que está em disco é o que roda na próxima chamada.
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-it7qiq.5). Sai 0 se passar. Hermético: não fala com o nó (ssh FALSO), não toca em sessão nem em estado vivos (pasta temporária por execução,
# tmux em TMUX_TMPDIR de teste). Não roda os mutantes (são a evidência do gate): só o grupo `lr` da bateria, contra a árvore viva.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
PROV="$CITY/scripts/gc-session-ssh"
SELF="$CITY/scripts/gc-session-ssh.selftest.sh"
RUNBOOK="$CITY/docs/runbooks/gc-session-ssh.md"

log()  { echo "[prod-test:gascity ga-it7qiq.5] $*"; }
fail() { echo "[prod-test:gascity ga-it7qiq.5] FAIL: $*" >&2; exit 1; }

for f in "$PROV" "$SELF" "$RUNBOOK"; do [[ -f "$f" ]] || fail "arquivo implantado ausente: $f"; done
[[ -x "$PROV" ]] || fail "o provider implantado não é executável: $PROV"
python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$PROV" 2>/dev/null || fail "erro de sintaxe em $PROV"
bash -n "$SELF" 2>/dev/null || fail "erro de sintaxe em $SELF"
log "arquivos presentes, sintaxe ok"

# ── O que está implantado é a versão com o cache: a chave, a geração e as DUAS pontas do start (antes e depois do ssh) + o depois do stop
grep -q "^LIST_TTL, LIST_TTL_MAX = 10, 120$" "$PROV" || fail "o padrão (10 s) e o teto (120 s) de list_cache_s não são os da fatia"
n=$(grep -c '^        lr_invalidate(cfg)  # o list-running guardado deixa de valer ANTES' "$PROV")
[[ "$n" == 1 ]] || fail "o start não invalida o cache ANTES do ssh dele ($n ocorrências, esperado 1)"
n=$(grep -c '^            lr_invalidate(cfg)  # depois do ssh do start$' "$PROV")
[[ "$n" == 1 ]] || fail "o start não invalida o cache DEPOIS do ssh dele ($n ocorrências, esperado 1)"
n=$(grep -c '^            lr_invalidate(cfg)  # stop, depois' "$PROV")
[[ "$n" == 1 ]] || fail "o stop não invalida o cache ($n ocorrências, esperado 1)"
n=$(grep -c '^            live, t0 = host_live(cfg, dry)$' "$PROV")
[[ "$n" == 1 ]] || fail "o op_list_running não passa por host_live ($n ocorrências, esperado 1)"
log "provider implantado: padrão 10 s / teto 120 s, start invalida antes e depois, stop depois, list-running passa pelo cache ✓"

# ── O runbook diz o que o cache faz e como desligar
for key in '## Contents' 'Cache do `list-running`' 'list_cache_s' 'plano B' 'ga-it7qiq.5'; do
  grep -q -- "$key" "$RUNBOOK" || fail "runbook não descreve '$key'"
done
log "runbook ✓"

# ── O grupo `lr` da bateria contra a árvore viva (ssh falso; nada do host real)
out="$(env GCSSH_ONLY=lr GCSSH_UNDER_TEST="$PROV" timeout 900 bash "$SELF" 2>&1)" || { printf '%s\n' "$out" | grep -E '^FAIL' | head -20 >&2; printf '%s\n' "$out" | tail -5 >&2; fail "grupo lr falhou (ou estourou o prazo) contra a árvore viva"; }
line=$(printf '%s\n' "$out" | grep -E '^== [0-9]+/[0-9]+ ok ==$' | tail -1)
[[ -n "$line" ]] || fail "grupo lr sem a linha de resultado: $(printf '%s\n' "$out" | tail -4)"
set -- $(printf '%s' "$line" | grep -oE '[0-9]+' | head -2)
[[ "$1" == "$2" && "$2" -ge 50 ]] || fail "grupo lr reportou '$line' (esperado todos ok e pelo menos 50 casos)"
log "grupo lr: $line ✓"

log "PASS"
exit 0
