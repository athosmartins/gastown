#!/usr/bin/env bash
# prod-tests/gascity/story-ga-2hd02v.5.13.sh — prod test da história ga-2hd02v.5.13 (Fila WA no nó: a política da prova para os `unknown` — regra 9 do classificador, «teste vermelho em main» como oráculo).
#
# Contents
#   O que verifica · O que não verifica · Por que é seguro rodar
#
# O QUE VERIFICA (nos arquivos IMPLANTADOS, não numa cópia): o classificador wa-node-classify.py e o selftest existem e parseiam; a regra 9 está no classificador implantado (as funções, as constantes e o `derivado` no
#   basis) e no runbook; o classificador IMPLANTADO, rodado de verdade num repositório git de mentira (um teste em origin/main, sem dado real e sem rede), decide como a regra manda: bug que diz «reprova em main» = node
#   `prova-oraculo-teste-vermelho:1-teste(s)` com basis `derivado`; a MESMA bead do tipo tarefa = unknown (controle negativo); «não reprova em main» = unknown; teste que não está em origin/main = unknown com a nota
#   `oraculo-teste-fora-de-main`; bead que fala de envio = mini (freio). Por fim o selftest inteiro, com os mutantes, termina com «N/N ok» e o mínimo de casos.
# O QUE NÃO VERIFICA — e não diz que verifica: a passada real do Pilot com «ficaram com o nó» > 0 e uma bead construída no nó e aprovada no gate. Isso só se observa DEPOIS do deploy, com o Pilot ligado no modo do nó
#   (docs/runbooks/hetzner-wa-node.md); este teste PASSAR não diz que o nó entregou uma bead. Também não lê a fila WA de verdade: a medição de 05/11 (5 → 11 node nas 171 beads) está no runbook.
# POR QUE É SEGURO RODAR: o repositório de mentira mora numa pasta temporária (apagada ao sair); WA_NODE_REPO, WA_NODE_MIRROR e WA_NODE_CACHE são fixados nela, então o classificador nunca olha o repo do WA, o espelho
#   nem o cache de verdade. Nenhuma bead é lida ou escrita, nada vai à rede.
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-2hd02v.5.13). Sai 0 se passar.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
BASH32=/bin/bash
log()  { echo "[prod-test:gascity ga-2hd02v.5.13] $*"; }
fail() { echo "[prod-test:gascity ga-2hd02v.5.13] FAIL: $*" >&2; exit 1; }
[[ -x "$BASH32" ]] || fail "$BASH32 não executa — não dá para checar a sintaxe no interpretador de verdade"
need() { local f; for f in "$@"; do [[ -f "$f" ]] || fail "arquivo implantado ausente: $f"; done; }

CLS="$CITY/scripts/wa-node-classify.py"; CLS_ST="$CITY/scripts/wa-node-classify.selftest.sh"
RUNBOOK="$CITY/docs/runbooks/hetzner-wa-node.md"
need "$CLS" "$CLS_ST" "$RUNBOOK"
[[ -x "$CLS_ST" ]] || fail "$CLS_ST sem permissão de execução"
"$BASH32" -n "$CLS_ST" || fail "$CLS_ST não parseia sob $BASH32"
python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$CLS" || fail "$CLS não parseia"
log "arquivos implantados presentes; sintaxe ok ✓"

# ── a regra 9 está no que foi implantado ─────────────────────────────────────
for needle in 'def red_in_main(' 'def oracle_derivation(' 'def judged_oracle(' 'MAIN_RE = ' 'RED_RE = ' 'GREEN_RE = ' '"prova-oraculo-teste-vermelho:"))'; do
  grep -qF -- "$needle" "$CLS" || fail "o classificador implantado não tem a regra 9 (falta: $needle) — o deploy não trouxe esta história? ($CLS)"
done
grep -qF -- 'Oráculo = teste vermelho em `main`' "$RUNBOOK" || fail "o runbook não descreve a regra 9 ($RUNBOOK)"
grep -qF -- 'Medido em 05/11 (ga-2hd02v.5.13)' "$RUNBOOK" || fail "o runbook não traz a medição de 05/11 e a decisão A1/A2/B ($RUNBOOK)"
log "regra 9 presente no classificador e no runbook implantados ✓"

# ── o classificador implantado, num repo de mentira ──────────────────────────
T=$(mktemp -d "${TMPDIR:-/tmp}/wa-node-story-5-13.XXXXXX") || fail "sem pasta temporária"
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
RP="$T/repo"; mkdir -p "$RP/tests"
printf 'def test_a():\n    assert True\n' > "$RP/tests/test_prod_a.py"
gw() { env -i HOME="$T" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 git -C "$RP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
gw init -q . >/dev/null 2>&1 || fail "git init do repo de mentira falhou"
gw add -A >/dev/null 2>&1 && gw commit -q -m 1 >/dev/null 2>&1 || fail "commit do repo de mentira falhou"
gw update-ref refs/remotes/origin/main HEAD || fail "não consegui criar origin/main no repo de mentira"

# classify <tipo> <texto> → deixa a saída em $OUT e o código em $RC (o classificador devolve 0 node, 10 mini, 11 unknown)
OUT=""; RC=0
classify() {
  local json; json=$(printf '{"id":"wa-prodtest","title":"t","issue_type":"%s","description":"%s"}' "$1" "$2")
  OUT=$(printf '%s' "$json" | WA_NODE_REPO="$RP" WA_NODE_MIRROR="$T/espelho-ausente" WA_NODE_CACHE="$T/cache" python3 -I "$CLS" 2>/dev/null); RC=$?
}
# want <rótulo> <rc esperado> <regex da saída>
want() {
  [[ "$RC" == "$2" ]] && printf '%s' "$OUT" | grep -q -E -e "$3" || fail "$1 (rc=$RC, esperado $2 com /$3/; saída: $(printf '%s' "$OUT" | cut -c1-300))"
}
classify bug 'tests/test_prod_a.py reprova em origin/main desde o merge de ontem'
want "bug que diz «reprova em origin/main» não virou node pela regra 9" 0 '"verdict": "node", "basis": "derivado", "reasons": \["prova-oraculo-teste-vermelho:1-teste\(s\)"\]'
classify task 'tests/test_prod_a.py reprova em origin/main desde o merge de ontem'
want "controle negativo: a MESMA bead do tipo tarefa tem de ficar unknown" 11 '"verdict": "unknown"'
classify bug 'tests/test_prod_a.py não reprova em origin/main; o problema aparece só no tablet'
want "«não reprova em main» não pode valer como teste vermelho" 11 '"verdict": "unknown"'
classify bug 'tests/test_prod_novo.py reprova em origin/main'
want "teste que não está em origin/main não pode estar vermelho lá" 11 '"verdict": "unknown".*"oraculo-teste-fora-de-main:tests/test_prod_novo\.py"'
classify bug 'Corrigir o envio da mensagem: tests/test_prod_a.py reprova em origin/main'
want "bead que fala de envio tem de ir ao mini (freio), mesmo com o teste vermelho" 10 '"verdict": "mini".*freio-derivado:envio-acao'
log "classificador implantado: bug+vermelho = node; tarefa, negação, teste ausente = unknown; envio = mini ✓"

# ── o selftest inteiro, contra a árvore viva ─────────────────────────────────
# o selftest tem de terminar com a linha «N/N ok» (todos ok) e o mínimo de casos (a bateria de mutantes entra na conta)
out="$(timeout 1800 "$BASH32" "$CLS_ST" 2>&1)" || { echo "$out" | tail -25 >&2; fail "selftest do classificador falhou (ou estourou o tempo) contra a árvore viva"; }
line=$(printf '%s\n' "$out" | grep -E '^[0-9]+/[0-9]+ ok' | tail -1)
[[ -n "$line" ]] || fail "selftest do classificador sem a linha de resultado 'N/N ok':
$out"
pass=${line%%/*}; rest=${line#*/}; total=${rest%% *}
[[ "$pass" == "$total" && "$total" -ge 650 ]] || fail "selftest do classificador reportou '$line' (esperado todos ok e pelo menos 650 casos)"
printf '%s\n' "$out" | grep -qE 'SELFTEST OK' || fail "selftest do classificador sem a linha final de sucesso"
log "selftest do classificador (mutantes inclusos): $line ✓"

log "OK — a regra 9 está implantada e decide como o runbook diz. A bead real construída no nó e aprovada no gate, e o «ficaram com o nó» > 0 numa passada real do Pilot, só se observam DEPOIS do deploy: este teste não os cobre."
