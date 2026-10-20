#!/usr/bin/env bash
# prod-tests/gascity/story-ga-2hd02v.1.10.sh — prod test da história ga-2hd02v.1.10 (Hetzner: wa-worker no nó só com bead sem dado de lead/cliente — classificação + roteamento).
#
# Contents
#   O que verifica · O que não verifica · Por que é seguro rodar · O que é aviso e não falha
#
# O QUE VERIFICA (nos arquivos IMPLANTADOS, não numa cópia): o classificador, o despachante e o gancho do Pilot existem e parseiam; os três selftests terminam com "N/N ok" e o mínimo de casos
#   (classificador com 40 mutantes, despachante com 60, gancho do Pilot com 30 — mutante que sobrevive derruba o selftest); o template wa-worker-remote nasce INERTE (min_active_sessions = 0; quantas sessões o teto deixa abrir é
#   conferido por story-ga-2hd02v.3.sh, que também cobre o modo `pilot` de N slots);
#   o gancho do Pilot nasce DESLIGADO (padrão `off` no fonte, e nenhum arquivo de configuração da cidade o liga); o prompt do worker remoto não tem skill com barra no início (ga-7nxfa1).
# O QUE NÃO VERIFICA — e não diz que verifica: as "3 beads reais entregues pelo nó" e a "varredura do nó sem arquivo de dado de lead" que a história pede. Elas dependem do flip da ga-2hd02v.1.6 e do
#   gate-done remoto da ga-2hd02v.1.13, e a ativação viva (PILOT_WA_NODE_ROUTE, `wa-worker` em worktree_rigs do host) é passo de ligar do runbook docs/runbooks/hetzner-wa-node.md, não deste teste.
#   Este teste PASSAR não diz que o nó entregou uma bead nem que está limpo.
# POR QUE É SEGURO RODAR: os selftests usam stubs de bd/gc/ssh e uma cidade temporária; as leituras da configuração são só leitura. Nada é despachado, atribuído nem escrito em bead, e o servidor não é tocado.
# O QUE É AVISO E NÃO FALHA: arquivo de configuração da cidade que não existe nesta árvore (não há o que ligar ali).
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-2hd02v.1.10). Sai 0 se passar.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
BASH32=/bin/bash
log()  { echo "[prod-test:gascity ga-2hd02v.1.10] $*"; }
warn() { echo "[prod-test:gascity ga-2hd02v.1.10] AVISO: $*"; }
fail() { echo "[prod-test:gascity ga-2hd02v.1.10] FAIL: $*" >&2; exit 1; }
[[ -x "$BASH32" ]] || fail "$BASH32 não executa — não dá para checar a sintaxe no interpretador de verdade"
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

CLS="$CITY/scripts/wa-node-classify.py"; CLS_ST="$CITY/scripts/wa-node-classify.selftest.sh"
DSP="$CITY/scripts/wa-node-dispatch.sh";  DSP_ST="$CITY/scripts/wa-node-dispatch.selftest.sh"
PIL="$ASSETS/pilot-dispatcher.sh";        PIL_ST="$ASSETS/pilot-dispatcher.wa-node-route.selftest.sh"
AGENT="$CITY/agents/wa-worker-remote/agent.toml"; PROMPT="$CITY/agents/wa-worker-remote/prompt.template.md"
RUNBOOK="$CITY/docs/runbooks/hetzner-wa-node.md"
need "$CLS" "$CLS_ST" "$DSP" "$DSP_ST" "$PIL" "$PIL_ST" "$AGENT" "$PROMPT" "$RUNBOOK"
[[ -x "$DSP" && -x "$DSP_ST" && -x "$CLS_ST" ]] || fail "wa-node-dispatch.sh / os selftests sem permissão de execução"
syntax "$DSP" "$DSP_ST" "$CLS_ST" "$PIL" "$PIL_ST"
python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$CLS" || fail "$CLS não parseia"
log "arquivos implantados presentes; sintaxe ok ✓"

# ── inerte por padrão ────────────────────────────────────────────────────────
grep -qE '^min_active_sessions *= *0$' "$AGENT" && grep -qE '^max_active_sessions *= *[1-9]$' "$AGENT" || fail "wa-worker-remote não é 0..N sessões, com N de um dígito ($AGENT)"
grep -q 'PILOT_WA_NODE_ROUTE:-off' "$PIL" || fail "o padrão do gancho do Pilot não é off ($PIL)"
live=0
for f in "$CITY/city.toml" "$CITY"/packs/town-deltas/orders/*.toml "$CITY"/packs/town-deltas/*.toml "$CITY"/packs/town-deltas/assets/*.toml; do
  [[ -f "$f" ]] || continue
  if grep -nE 'PILOT_WA_NODE_ROUTE *= *"?(shadow|label|auto)' "$f" >/dev/null 2>&1; then
    live=1; warn "$f liga o gancho (PILOT_WA_NODE_ROUTE): confira se é o passo de ligar do runbook, com o flip da 1.6 provado"
  fi
done
[[ "$live" = 0 ]] && log "nenhum arquivo da cidade liga PILOT_WA_NODE_ROUTE; o gancho segue desligado ✓"
if grep -nE '(^|[[:space:]`(])/[a-z][a-z-]+' "$PROMPT" >/dev/null 2>&1; then
  fail "prompt do wa-worker-remote tem skill com barra no início (ga-7nxfa1): $PROMPT"
fi
grep -q 'hetzner-wa-node.md' "$AGENT" || fail "agent.toml não aponta para o runbook"
log "template inerte (min 0), sem skill com barra, aponta para o runbook ✓"

# ── os selftests, contra a árvore viva ───────────────────────────────────────
run_suite "classificador wa-node-classify (133 itens, 40 mutantes)"      125 timeout 600 "$BASH32" "$CLS_ST"
run_suite "despachante wa-node-dispatch (319 itens, 60 mutantes)"        310 timeout 900 "$BASH32" "$DSP_ST"
run_suite "gancho do Pilot _pilot_wa_node_decide (257 itens, 30 mutantes)"  250 timeout 900 "$BASH32" "$PIL_ST"

log "OK — classificação + roteamento prontos e INERTES. As 3 beads reais e a varredura do nó são passos de ligar (docs/runbooks/hetzner-wa-node.md)."
