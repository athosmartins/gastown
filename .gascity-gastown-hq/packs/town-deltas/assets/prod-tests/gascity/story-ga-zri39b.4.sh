#!/usr/bin/env bash
# prod-tests/gascity/story-ga-zri39b.4.sh — prod test da fatia 4 de 4 da ga-zri39b (nó Linux de testes, Hetzner, teste de 1 semana aprovado pelo Athos em 13/10):
# semeadura do nó (base pelo filtro, auditoria, dependências sem os pacotes do macOS) e o order de reseed diário.
#
# Contents
#   O que verifica · O que não verifica · Por que é seguro rodar · O que é aviso e não falha
#
# O QUE VERIFICA (nos arquivos IMPLANTADOS, não numa cópia): o order e o wrapper de reseed existem; os selftests do nó (com a semeadura e a auditoria que dá ALARME) e o do reseed passam contra os arquivos vivos; e o freeze local do venv do WA é legível (senão toda noite sairia rc 97).
# O QUE NÃO VERIFICA — e não diz que verifica: o CONTEÚDO do servidor. A prova de que a semeadura não leva segredo/dado é o selftest (rsync de verdade contra uma árvore com vazamentos plantados, mais a auditoria
#   que dá ALARME rc 98, com controle negativo). A varredura do que o servidor guarda de verdade (nome de segredo/dado, token, arquivo grande, CONTEÚDO com lista de telefones/CPFs, base e espelhos) é da
#   story-ga-zri39b.1.sh, e esta fatia NÃO mantém cópia dela: a cópia que existia aqui ficou para trás (só olhava nome, só a wa-base, sem token e sem conteúdo, e lia um `find` que falhou como "limpo"; o revisor
#   do gate a rodou contra um `.pdpj_token.txt` plantado e a cópia equivalente da fatia 2 devolveu "limpo"). Este teste PASSAR não diz nada sobre o que o servidor guarda.
# POR QUE É SEGURO RODAR: os selftests usam stubs de ssh/rsync/python e uma cidade temporária; as leituras vivas são SÓ leitura. Nada é semeado, instalado nem apagado no servidor, e nenhuma
#   bandeira é ligada ou desligada.
# O QUE É AVISO E NÃO FALHA: o venv local do WA ausente, o `uv` fora do PATH ou um freeze curto (a semeadura do nó recusaria com rc 97 até alguém arrumar o venv; o código em si está provado pelos selftests).
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-zri39b.4). Sai 0 se passar.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
BASH32=/bin/bash
TMPS=()
cleanup() { local d; for d in "${TMPS[@]+"${TMPS[@]}"}"; do [[ -n "$d" && -d "$d" ]] && { find "$d" -mindepth 1 -delete 2>/dev/null; rmdir "$d" 2>/dev/null; }; done; }
trap cleanup EXIT
log()  { echo "[prod-test:gascity ga-zri39b.4] $*"; }
warn() { echo "[prod-test:gascity ga-zri39b.4] AVISO: $*"; }
fail() { echo "[prod-test:gascity ga-zri39b.4] FAIL: $*" >&2; exit 1; }
[[ -x "$BASH32" ]] || fail "$BASH32 não executa — não dá para checar a sintaxe no interpretador de verdade"
tmpcity() { local d; d="$(mktemp -d "${TMPDIR:-/tmp}/zri39b-prod.XXXXXX")"; TMPS+=("$d"); mkdir -p "$d/.gc/logs"; printf '%s' "$d"; }
need() { local f; for f in "$@"; do [[ -f "$f" ]] || fail "arquivo implantado ausente: $f"; done; }
syntax() { local f; for f in "$@"; do "$BASH32" -n "$f" || fail "$f não parseia sob $BASH32"; done; }
# run_suite <rótulo> <mínimo de casos> <comando...>: o selftest tem de terminar com a linha "N/N ok" (todos ok) e o mínimo de casos
run_suite() {
  local label="$1" min="$2"; shift 2
  local out; out="$("$@" 2>&1)" || { echo "$out" | tail -25 >&2; fail "$label falhou (ou estourou o tempo) contra a árvore viva"; }
  local line; line=$(printf '%s\n' "$out" | grep -E '^[0-9]+/[0-9]+ ok$' | tail -1)
  [[ -n "$line" ]] || fail "$label sem a linha de resultado 'N/N ok':
$out"
  local pass=${line%%/*} rest=${line#*/}; local total=${rest%% *}
  [[ "$pass" == "$total" && "$total" -ge "$min" ]] || fail "$label reportou '$line' (esperado todos ok e pelo menos $min casos)"
  printf '%s\n' "$out" | grep -qE 'SELFTEST OK|RESULT: .* 0 failed' || fail "$label sem a linha final de sucesso"
  log "$label: $line ✓"
}
RUN="$CITY/scripts/mbp-run.sh"; SELFTEST="$CITY/scripts/mbp-run.selftest.sh"
RESEED_ST="$CITY/scripts/hetzner-node-reseed.selftest.sh"; ORDER="$ASSETS/../orders/hetzner-node-reseed.toml"; ORDER_SH="$ASSETS/scripts/hetzner-node-reseed-order.sh"
need "$RUN" "$SELFTEST" "$RESEED_ST" "$ORDER" "$ORDER_SH"
[[ -x "$ORDER_SH" ]] || fail "o wrapper do order de reseed sem permissão de execução"
syntax "$RUN" "$SELFTEST" "$RESEED_ST" "$ORDER_SH"
grep -q '^trigger *= *"cron"' "$ORDER" && grep -q 'hetzner-node-reseed-order.sh' "$ORDER" || fail "o order hetzner-node-reseed não está no formato esperado ($ORDER)"
log "arquivos implantados presentes; sintaxe ok; order no pack ✓"

run_suite "selftest do nó Linux (mbp-run.sh), com a semeadura e a auditoria" 250 env MBP_SELFTEST_ONLY=node timeout 900 "$BASH32" "$SELFTEST"
run_suite "selftest do order de reseed do nó" 30 timeout 300 "$BASH32" "$RESEED_ST"
# o --seed vivo SÓ se prova até onde não escreve no servidor: o freeze local precisa ser legível (um venv ilegível faria toda noite sair 97)
lv="${HETZNER_SEED_VENV:-/Users/athos/gt/whatsapp_automation/venv}"
if [[ -x "$lv/bin/python" ]]; then
  uvbin="$(command -v uv 2>/dev/null || { [[ -x "$HOME/.local/bin/uv" ]] && echo "$HOME/.local/bin/uv"; })"
  if [[ -n "$uvbin" ]]; then n="$("$uvbin" pip freeze --python "$lv/bin/python" 2>/dev/null | grep -c .)"; [[ "$n" -ge 20 ]] && log "freeze do venv local legível: $n pacotes ✓" || warn "freeze do venv local veio com $n linhas (a semeadura do nó recusaria com rc 97)"
  else warn "uv ausente neste PATH; o reseed usaria pip no venv local"; fi
else warn "venv local do WA ($lv) ausente: a semeadura do nó sairia 97"; fi

log "PASS"
exit 0
