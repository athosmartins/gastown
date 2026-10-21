#!/usr/bin/env bash
# prod-tests/gascity/story-ga-2hd02v.4.sh — prod test da história ga-2hd02v.4 (Hetzner 100%: ps-worker remoto — classificação, roteamento e gate-done do nó para o rig property_scrapers).
#
# Contents
#   O que verifica · O que não verifica · Por que é seguro rodar · O que é aviso e não falha
#
# O QUE VERIFICA (nos arquivos IMPLANTADOS, não numa cópia): o classificador, o filtro e a lista mac-only do PS, o despachante, o gancho do Pilot e o gate-done-remote existem e parseiam; os selftests
#   terminam com "N/N ok" e o mínimo de casos; o template ps-worker-remote nasce INERTE (min_active_sessions = 0, 1 só); o despachante do PS fixa o modo pilot (a bead do PS não está na loja que o
#   pool enxerga); o gancho do Pilot nasce DESLIGADO (padrão `off` no fonte, e nenhum arquivo de configuração da cidade o liga); o prompt do worker remoto não tem skill com barra no início (ga-7nxfa1)
#   e usa `bd -C property_scrapers`; a Seção 1 do filtro do PS é a do WA; se os 5 arquivos de teste que dependem do binário `node` estão FORA da lista mac-only, o nó tem o Node do pin
#   (scripts/hetzner-nodejs-guard.sh, ga-2hd02v.4.11: FALHA se o nó não tem, AVISO se não deu para saber).
# O QUE NÃO VERIFICA — e não diz que verifica: a "1 bead de PS construída no nó, passando no gate" que a história pede. Ela depende de ligar o gancho (PILOT_PS_NODE_ROUTE) e de uma bead real com
#   `node:ok`: passos 6–7 do runbook docs/runbooks/hetzner-ps-node.md, não deste teste. Este teste PASSAR não diz que o nó entregou uma bead de PS.
# POR QUE É SEGURO RODAR: os selftests usam stubs de bd/gc/ssh e uma cidade temporária; as leituras da configuração são só leitura. A única chamada de rede é o `hetzner-nodejs.sh check` do guarda do Node: só leitura, ssh com BatchMode e prazo. Nada é despachado, atribuído nem escrito em bead, e o servidor não é tocado.
#   O selftest do gancho roda sem os mutantes aqui (PS_NODE_ROUTE_ST_NOMUT=1): eles são a bateria do gate.
# O QUE É AVISO E NÃO FALHA: arquivo de configuração da cidade que não existe nesta árvore (não há o que ligar ali); o guarda do Node que não conseguiu saber (ssh ao nó caiu, script ausente, prazo): o teste
#   passa mas a última linha diz "Node do nó NÃO verificado" — nunca fica verde sem dizer.
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-2hd02v.4). Sai 0 se passar.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
BASH32=/bin/bash
log()  { echo "[prod-test:gascity ga-2hd02v.4] $*"; }
warn() { echo "[prod-test:gascity ga-2hd02v.4] AVISO: $*"; }
fail() { echo "[prod-test:gascity ga-2hd02v.4] FAIL: $*" >&2; exit 1; }
[[ -x "$BASH32" ]] || fail "$BASH32 não executa — não dá para checar a sintaxe no interpretador de verdade"
need() { local f; for f in "$@"; do [[ -f "$f" ]] || fail "arquivo implantado ausente: $f"; done; }
syntax() { local f; for f in "$@"; do "$BASH32" -n "$f" || fail "$f não parseia sob $BASH32"; done; }
# run_suite <rótulo> <mínimo de casos> <comando...>: o selftest tem de terminar com a linha "N/N ok" (todos ok) e o mínimo de casos
run_suite() {
  local label="$1" min="$2"; shift 2
  local out; out="$("$@" 2>&1)" || { echo "$out" | tail -25 >&2; fail "$label falhou (ou estourou o tempo) contra a árvore viva"; }
  local line; line=$(printf '%s\n' "$out" | grep -E '^[0-9]+/[0-9]+ ok' | tail -1)
  [[ -n "$line" ]] || fail "$label sem a linha de resultado 'N/N ok':
$out"
  local pass=${line%%/*} rest=${line#*/}; local total=${rest%% *}
  [[ "$pass" == "$total" && "$total" -ge "$min" ]] || fail "$label reportou '$line' (esperado todos ok e pelo menos $min casos)"
  printf '%s\n' "$out" | grep -qE 'SELFTEST OK' || fail "$label sem a linha final de sucesso"
  log "$label: $line ✓"
}

CLS="$CITY/scripts/ps-node-classify.py";  CLS_ST="$CITY/scripts/ps-node-classify.selftest.sh"
DSP="$CITY/scripts/ps-node-dispatch.sh";  DSP_ST="$CITY/scripts/ps-node-dispatch.selftest.sh"
GDR="$CITY/scripts/gate-done-remote.py";  GDR_ST="$CITY/scripts/gate-done-remote.selftest.sh"
PIL="$ASSETS/pilot-dispatcher.sh";        PIL_ST="$ASSETS/pilot-dispatcher.ps-node-route.selftest.sh"
FILTER_PS="$CITY/scripts/hetzner-rsync-filter.ps.txt"; FILTER_WA="$CITY/scripts/hetzner-rsync-filter.wa.txt"; MAC_PS="$CITY/scripts/hetzner-mac-only.ps.txt"
AGENT="$CITY/agents/ps-worker-remote/agent.toml"; PROMPT="$CITY/agents/ps-worker-remote/prompt.template.md"
RUNBOOK="$CITY/docs/runbooks/hetzner-ps-node.md"
need "$CLS" "$CLS_ST" "$DSP" "$DSP_ST" "$GDR" "$GDR_ST" "$PIL" "$PIL_ST" "$FILTER_PS" "$FILTER_WA" "$MAC_PS" "$AGENT" "$PROMPT" "$RUNBOOK"
[[ -x "$DSP" && -x "$DSP_ST" && -x "$CLS_ST" && -x "$GDR_ST" ]] || fail "ps-node-dispatch.sh / os selftests sem permissão de execução"
syntax "$DSP" "$DSP_ST" "$CLS_ST" "$GDR_ST" "$PIL" "$PIL_ST"
python3 -I -c 'import ast,sys; [ast.parse(open(f, encoding="utf-8").read()) for f in sys.argv[1:]]' "$CLS" "$GDR" || fail "$CLS ou $GDR não parseia"
log "arquivos implantados presentes; sintaxe ok ✓"

# ── inerte por padrão ────────────────────────────────────────────────────────
grep -qE '^min_active_sessions *= *0$' "$AGENT" && grep -qE '^max_active_sessions *= *1$' "$AGENT" || fail "ps-worker-remote não é 0..1 sessão ($AGENT)"
grep -q 'PILOT_PS_NODE_ROUTE:-off' "$PIL" || fail "o padrão do gancho do Pilot não é off ($PIL)"
grep -q '^export WA_NODE_SPAWN="pilot"' "$DSP" || fail "o ps-node-dispatch.sh não fixa o modo pilot: sem ele a bead do PS (loja do rig) ficaria numa rota que o pool não enxerga ($DSP)"
live=0
for f in "$CITY/city.toml" "$CITY"/packs/town-deltas/orders/*.toml "$CITY"/packs/town-deltas/*.toml "$CITY"/packs/town-deltas/assets/*.toml "$CITY"/scripts/com.gascity.pilot.plist; do
  [[ -f "$f" ]] || continue
  if grep -nE 'PILOT_PS_NODE_ROUTE *=|<key>PILOT_PS_NODE_ROUTE</key>' "$f" >/dev/null 2>&1; then
    live=1; warn "$f liga ou configura o gancho (PILOT_PS_NODE_ROUTE): confira se é o passo de ligar do runbook"
  fi
done
[[ "$live" = 0 ]] && log "nenhum arquivo da cidade liga PILOT_PS_NODE_ROUTE; o gancho segue desligado ✓"
if grep -nE '(^|[[:space:]`(])/[a-z][a-z-]+' "$PROMPT" >/dev/null 2>&1; then
  fail "prompt do ps-worker-remote tem skill com barra no início (ga-7nxfa1): $PROMPT"
fi
grep -q 'bd -C property_scrapers' "$PROMPT" || fail "o prompt do ps-worker-remote não manda usar bd -C property_scrapers (a bead mora na loja do rig)"
grep -q 'hetzner-ps-node.md' "$AGENT" || fail "agent.toml não aponta para o runbook"
log "template inerte (0..1), modo pilot fixado, sem skill com barra, usa bd -C property_scrapers, aponta para o runbook ✓"

# a Seção 1 do filtro do PS é a do WA (o espelho git lê a do WA)
if ! diff <(sed -n '/^# SEÇÃO 1/,/^# SEÇÃO 2/p' "$FILTER_WA" | sed '$d') <(sed -n '/^# SEÇÃO 1/,/^# SEÇÃO 2/p' "$FILTER_PS" | sed '$d') >/dev/null; then
  fail "a Seção 1 do filtro do PS diverge da do WA ($FILTER_PS × $FILTER_WA)"
fi
grep -qE '^[^#[:space:]]' "$MAC_PS" || fail "a lista mac-only do PS não tem nenhum glob ($MAC_PS): o classificador devolveria unknown para tudo"
log "Seção 1 do filtro do PS igual à do WA; lista mac-only do PS tem globs ✓"

# ── o Node que justifica a lista (ga-2hd02v.4.11) ────────────────────────────
# os 5 arquivos de teste que dependem do binário `node` saíram da lista mac-only porque o nó tem o Node; se o nó for refeito sem ele, o PS manda bead ao nó e ela reprova alto
NJG="$CITY/scripts/hetzner-nodejs-guard.sh"
need "$NJG"; syntax "$NJG"
# vazio → o guarda sempre imprime uma linha; falhou/ilegível (rc 2) → aviso visível e a nota final, nunca verde calado
njg_out=$("$BASH32" "$NJG" 2>&1); njg_rc=$?
NODE_NOTE="Node do nó verificado"
case $njg_rc in
  0) log "$njg_out ✓" ;;
  1) fail "$njg_out" ;;
  *) warn "$njg_out"; NODE_NOTE="Node do nó NÃO verificado (aviso acima)" ;;
esac

# ── os selftests, contra a árvore viva ───────────────────────────────────────
run_suite "classificador ps-node-classify (mutantes inclusos)"       130 timeout 600 "$BASH32" "$CLS_ST"
run_suite "despachante ps-node-dispatch (mutantes inclusos)"          48 timeout 600 "$BASH32" "$DSP_ST"
run_suite "gate-done-remote (rigs gascity + property_scrapers)"      280 timeout 900 "$BASH32" "$GDR_ST"
PS_NODE_ROUTE_ST_NOMUT=1 run_suite "gancho do Pilot _pilot_ps_node_decide (sem mutantes)" 125 timeout 600 "$BASH32" "$PIL_ST"

log "OK — classificação, roteamento e gate-done do nó para o PS prontos e INERTES; $NODE_NOTE. A bead real no nó é passo de ligar (docs/runbooks/hetzner-ps-node.md)."
