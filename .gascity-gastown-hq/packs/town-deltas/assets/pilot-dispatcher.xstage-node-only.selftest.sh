#!/usr/bin/env bash
# pilot-dispatcher.xstage-node-only.selftest.sh — ga-2hd02v.13 (o cede-ao-Gate por memória do mini ainda faz a passada só-nó)
#
# Contents
#   O que prova · Como roda
#
# 22/10 a noite toda: swap 7 GB no mini + gate congestionado → "Cross-stage YIELD (ga-d0hz3)" → a varredura saía (exit 0) ANTES da passada de WA no nó, e o
# Hetzner ficou sem bead com 5 node:ok aprovadas. A memória apertada é a do MINI; a sessão do nó não a gasta. Com o yield contido SÓ por memória (cota e Dolt
# calmos), PILOT_NODE_FIRST=on e fora do DRY_RUN, a varredura segue na passada só-nó (_PILOT_NODE_ONLY=1) e o mini continua cedendo.
#
# O QUE PROVA: memória + gate congestionado + on → segue só-nó, grava a pausa cross-stage-yield uma vez e NÃO diz "dispatching normally" · off, shadow, vazio,
#   valor que não existe e DRY_RUN saem como sempre · cota ou Dolt contidos saem como sempre, mesmo com memória e on · gate vazio ou recurso calmo → segue
#   normal (node_only 0).
# COMO RODA: a região do dispatcher (do cabeçalho ga-d0hz3 até ga-nq0jo) é extraída VERBATIM (awk) e roda num shell filho sob `set -euo pipefail` com leitores
#   falsos. Contra o dispatcher sem o conserto, o caso 1 reprova (sai com "deferred").
# Variáveis: PILOT_DISPATCHER_PATH
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
region() { RA="$1" RB="$2" awk 'f==0 && $0 ~ ENVIRON["RA"] {f=1} f==1 && n>0 && $0 ~ ENVIRON["RB"] {exit} f==1 {print; n++}' "$DISPATCHER"; }
XSTAGE_SRC="$(region '^# ── ga-d0hz3: CROSS-STAGE admission gate' '^# ga-nq0jo: reaching here')"
# vazio (âncora que não casa) → nada a testar: FATAL, nunca um verde vazio
[ -n "$XSTAGE_SRC" ] || { echo "FATAL: região ga-d0hz3 não encontrada em $DISPATCHER" >&2; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/runner.sh" <<'EOF'
set -euo pipefail
log()  { echo "LOG $*"; }
warn() { echo "WARN $*"; }
notify() { :; }
_pilot_write_sweep_pause_state() { echo "PAUSE_STATE $*" >> "$WORK/pause.calls"; }
_pilot_quota_limited() { echo "${GT_QUOTA:-0}"; }
_pilot_memory_tight() { [ "${GT_MEM:-1}" = 1 ]; }
_pilot_gate_congested() { echo "${GT_CONG:-1}"; }
CROSS_STAGE_PRIORITY_ENABLED=1
PILOT_DOLT_SATURATED_AT_START="${GT_DOLT:-0}"
PILOT_MEM_TIGHT_REASON=swap-used; PILOT_MEM_TIGHT_DETAIL="swap_used=7302MB"; PILOT_MEM_TIGHT_BLIND=""
PILOT_NODE_FIRST="${GT_MODE-on}"; DRY_RUN="${GT_DRY:-0}"
_PILOT_NODE_ONLY=0
eval "$XSTAGE_SRC"
echo "REACHED node_only=${_PILOT_NODE_ONLY}"
EOF
run() {
  rm -f "$WORK/pause.calls"
  OUT="$(env XSTAGE_SRC="$XSTAGE_SRC" WORK="$WORK" "$@" bash "$WORK/runner.sh" 2>&1)"
  NODE_ONLY="$(printf '%s\n' "$OUT" | sed -n 's/^REACHED node_only=//p')"   # vazio = não chegou ao fim (saiu)
  DEFERRED=0; printf '%s\n' "$OUT" | grep -q 'deferred: cross-stage' && DEFERRED=1
  NORMAL=0; printf '%s\n' "$OUT" | grep -q 'dispatching normally' && NORMAL=1
  PAUSES="$(grep -c '^PAUSE_STATE 1 cross-stage-yield ' "$WORK/pause.calls" 2>/dev/null || echo 0)"
}
expect() { # <desc> <node_only esperado ("" = saiu)> <deferred> <normal> <pausas>
  if [ "$NODE_ONLY" = "$2" ] && [ "$DEFERRED" = "$3" ] && [ "$NORMAL" = "$4" ] && [ "$PAUSES" = "$5" ]; then ok "$1"
  else bad "$1 — esperado node_only='$2' deferred=$3 normal=$4 pausas=$5; veio node_only='$NODE_ONLY' deferred=$DEFERRED normal=$NORMAL pausas=$PAUSES"; fi
}

echo "pilot-dispatcher.xstage-node-only.selftest — cede-ao-Gate por memória do mini segue na passada só-nó (ga-2hd02v.13)"
echo "── 1. memória do mini + gate congestionado + on, fora do DRY_RUN → passada só-nó"
run;                       expect "segue só-nó, pausa cross-stage-yield gravada 1x, sem 'dispatching normally'" 1 0 0 1
printf '%s\n' "$OUT" | grep -q 'Cross-stage YIELD (ga-d0hz3)' && ok "a linha do YIELD continua no log (o operador vê que o mini cedeu)" || bad "a linha do YIELD sumiu"
printf '%s\n' "$OUT" | grep -q 'passada só-nó (ga-2hd02v.13)' && ok "o log diz que a varredura segue só-nó" || bad "nenhuma linha diz a passada só-nó"
echo "── 2. o que NÃO liga a passada: sai como sempre"
run GT_MODE=off;           expect "PILOT_NODE_FIRST=off" "" 1 0 1
run GT_MODE=shadow;        expect "PILOT_NODE_FIRST=shadow" "" 1 0 1
run GT_MODE=;              expect "PILOT_NODE_FIRST vazio" "" 1 0 1
run GT_MODE=talvez;        expect "PILOT_NODE_FIRST com valor que não existe" "" 1 0 1
run GT_DRY=1;              expect "DRY_RUN" "" 1 0 1
run GT_QUOTA=1;            expect "cota contida (o nó segue a conta do pool do mini)" "" 1 0 1
run GT_DOLT=1;             expect "Dolt quente (a passada escreve no Dolt)" "" 1 0 1
echo "── 3. sem yield: segue normal, node_only 0"
run GT_CONG=0;             expect "gate vazio: recurso contido mas segue normal" 0 0 1 0
run GT_MEM=0;              expect "recurso calmo: nem pergunta ao gate" 0 0 0 0

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
