#!/usr/bin/env bash
# prod-tests/gascity/story-ga-xm1jfl.sh — prod test for ga-xm1jfl: os testes dirigidos do REVISOR do gate passam pelo
# scripts/gate-pytest.sh (MBP quando saudável, aqui quando não), anunciado no prompt do revisor só quando a chave está ligada.
#
# Contents
#   O que verifica · Por que não toca o MBP
#
# O QUE VERIFICA (nos arquivos IMPLANTADOS, não numa cópia): o wrapper existe, é executável e parseia sob /bin/bash 3.2; a lib do
#   prompt parseia sob /bin/bash 3.2 e carrega gate_test_wrapper_rules; o mbp-run.sh que o wrapper chama existe; a lista
#   gate-pytest.force-local está implantada e legível (sem ela o wrapper roda tudo aqui, avisando); e os dois selftests
#   novos (o do wrapper e o do parágrafo do prompt) mais o do invariante de apóstrofos do prompt (ga-6aj348) passam contra
#   eles. Com a chave de verdade ligada, o parágrafo sai do prompt real; com `.gc/gate-pytest.off`, não sai — conferido na cidade viva.
# POR QUE NÃO TOCA O MBP: o selftest do wrapper usa stubs de ssh/rsync/python; rodar o MBP de verdade aqui seria depender de uma
#   máquina que o gate não controla para dizer que o deploy está de pé. O caminho real foi exercitado à mão (ga-xm1jfl, comentário).
#
# Called by run.sh after deploy (STORY_ID=ga-xm1jfl). Exits 0 on pass.
set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
WRAPPER="$CITY/scripts/gate-pytest.sh"
WRAPPER_ST="$CITY/scripts/gate-pytest.selftest.sh"
FORCE_LIST="$CITY/scripts/gate-pytest.force-local"
MBPRUN="$CITY/scripts/mbp-run.sh"
TASKLIB="$ASSETS/gate-review-task.lib.sh"
LIB_ST="$ASSETS/gate-test-wrapper-rules.selftest.sh"
APOS_ST="$ASSETS/gate-6aj348-recall-bar.selftest.sh"
BASH32=/bin/bash

log()  { echo "[prod-test:gascity ga-xm1jfl] $*"; }
fail() { echo "[prod-test:gascity ga-xm1jfl] FAIL: $*" >&2; exit 1; }

for f in "$WRAPPER" "$WRAPPER_ST" "$MBPRUN" "$TASKLIB" "$LIB_ST" "$APOS_ST"; do [[ -f "$f" ]] || fail "missing: $f"; done
# A lista force-local é o remédio do verde vazio (runbook): sem ela legível o wrapper manda TUDO rodar aqui (e avisa), então um deploy que esqueceu a lista
# não quebra nada, mas tira o ganho em silêncio — por isso o prod test exige a lista implantada e legível.
[[ -r "$FORCE_LIST" ]] || fail "force-local list missing or unreadable: $FORCE_LIST (the wrapper would run every target locally and the offload would gain nothing)"
[[ -x "$WRAPPER" ]] || fail "$WRAPPER is not executable (reviewers would get 'permission denied' instead of a test run)"
[[ -x "$BASH32" ]]  || fail "$BASH32 not executable — cannot run the real-interpreter syntax check"
log "Deployed wrapper, force-local list, mbp-run, prompt lib and selftests found."

log "Syntax under $BASH32 ($("$BASH32" --version | head -n1 | sed 's/ (.*//'))..."
"$BASH32" -n "$WRAPPER"  || fail "gate-pytest.sh does not parse under $BASH32"
"$BASH32" -n "$TASKLIB"  || fail "gate-review-task.lib.sh does not parse under $BASH32"
log "  syntax OK ✓"

grep -q 'gate_test_wrapper_rules()' "$TASKLIB" || fail "gate_test_wrapper_rules is missing from the deployed prompt lib"
grep -q '_GATE_TW=\$(gate_test_wrapper_rules' "$TASKLIB" || fail "the task body no longer calls gate_test_wrapper_rules"

log "Wrapper selftest (hermetic: stub ssh/rsync/python)..."
out=$("$BASH32" "$WRAPPER_ST" 2>&1) || { echo "$out" | tail -15 >&2; fail "gate-pytest.selftest.sh failed"; }
echo "$out" | tail -2 | sed 's/^/  /'

log "Prompt-paragraph selftest..."
out=$("$BASH32" "$LIB_ST" 2>&1) || { echo "$out" | tail -15 >&2; fail "gate-test-wrapper-rules.selftest.sh failed"; }
echo "$out" | tail -2 | sed 's/^/  /'

log "Prompt apostrophe/recall-bar invariants (ga-6aj348)..."
out=$("$BASH32" "$APOS_ST" 2>&1) || { echo "$out" | tail -15 >&2; fail "gate-6aj348-recall-bar.selftest.sh failed"; }
echo "$out" | tail -1 | sed 's/^/  /'

# A cidade viva: o parágrafo acompanha as duas chaves reais.
log "Live-city switches drive the real prompt paragraph..."
# shellcheck disable=SC1090
( . "$TASKLIB" || exit 3
  live=$(gate_test_wrapper_rules "$CITY")
  if [[ ( -f "$CITY/.gc/mbp-offload.on" || -f "$CITY/.gc/hetzner-node.on" ) && ! -f "$CITY/.gc/gate-pytest.off" ]]; then
    [[ -n "$live" ]] || { echo "offload ON and no gate-pytest.off, yet the paragraph is empty" >&2; exit 1; }
    echo "  switches ON  -> paragraph present ✓"
  else
    [[ -z "$live" ]] || { echo "a switch is OFF, yet the paragraph is not empty" >&2; exit 1; }
    echo "  a switch is OFF -> paragraph absent ✓ (prompt identical to before)"
  fi ) || fail "live-city switch check failed"

log "PASS"
exit 0
