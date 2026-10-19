#!/usr/bin/env bash
# prod-tests/gascity/story-ga-elvr8e.sh — prod test para ga-elvr8e (fatia B de ga-2hd02v.1.11; o run.sh escolhe o teste pelo id da bead entregue): o teto do nó Hetzner por medição (degraus 1→3→6→10) e o veredito "nó ou mini"
# (scripts/hetzner-capacity.py), mais o MODO SOMBRA do Pilot (PILOT_NODE_FIRST=shadow). O que esta fatia PROMETE é ficar inerte até alguém ligar; por isso o teste
# confere primeiro a inércia (padrão do Pilot = off, oráculo que não consegue ler diz NÃO SEI e nunca NÓ) e só depois roda as baterias contra a árvore viva.
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-elvr8e). Pressupõe a fatia A (ga-5yp4n1: oráculo + bateria) já no main. Sai 0 se passar. Hermético: não fala com o nó, não toca em .gc/ vivo (pasta de estado temporária e
# GC_SSH_CONFIG apontando para o nada). Não roda os mutantes (são a evidência do gate): só a bateria de casos.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
CAP="$CITY/scripts/hetzner-capacity.py"
CAPT="$CITY/scripts/hetzner-capacity.selftest.sh"
ASSETS="$CITY/packs/town-deltas/assets"
PILOT="$ASSETS/pilot-dispatcher.sh"
PILOTT="$ASSETS/pilot-dispatcher.node-first.selftest.sh"
RUNBOOK="$CITY/docs/runbooks/hetzner-capacity.md"
PY="${PROD_TEST_PY:-/usr/bin/python3}"   # o 3.9 do sistema: é o mais velho que o script promete

log()  { echo "[prod-test:gascity ga-elvr8e] $*"; }
fail() { echo "[prod-test:gascity ga-elvr8e] FAIL: $*" >&2; exit 1; }

for f in "$CAP" "$CAPT" "$PILOT" "$PILOTT" "$RUNBOOK"; do [[ -f "$f" ]] || fail "arquivo implantado ausente: $f"; done
[[ -x "$CAP" ]] || fail "$CAP não é executável"
for f in "$CAPT" "$PILOT" "$PILOTT"; do bash -n "$f" 2>/dev/null || fail "erro de sintaxe em $f"; done
"$PY" -I -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$CAP" 2>/dev/null || fail "$CAP não compila no $PY ($("$PY" --version 2>&1))"
log "arquivos presentes, sintaxe ok (python $("$PY" --version 2>&1 | awk '{print $2}'))"

# ── INÉRCIA 1: o Pilot entregue vem desligado, e `on` não existe
grep -q '^PILOT_NODE_FIRST="${PILOT_NODE_FIRST:-off}"$' "$PILOT" || fail "o padrão de PILOT_NODE_FIRST no pilot-dispatcher.sh não é off"
grep -q "valores: off | shadow" "$PILOT" || fail "o pilot-dispatcher.sh não recusa valor desconhecido de PILOT_NODE_FIRST"
n=$(grep -c '^  _pilot_node_first_shadow "\$STORY_ID" "\$_SLING_TARGET" "\$_IS_RIG_NATIVE" "\$STORY_LABELS" || true$' "$PILOT")
[[ "$n" == 1 ]] || fail "a chamada _pilot_node_first_shadow no dispatch_one aparece $n vezes (esperado 1, com || true)"
log "Pilot: padrão off, valor desconhecido recusado, chamada única e protegida ✓"

# ── INÉRCIA 2: o oráculo, sem como ler a config, diz NÃO SEI — nunca NÓ (pasta de estado temporária; nada de ssh: não há destino para medir)
T="$(mktemp -d "${TMPDIR:-/tmp}/prodtest-hc.XXXXXX")" || fail "sem pasta temporária"
trap 'rm -rf "$T"' EXIT
export HETZNER_CAPACITY_DIR="$T/estado" GC_SSH_CONFIG="$T/nao-existe.json" HETZNER_CAPACITY_SHIM_CONFIG="$T/nao-existe-shim.json"
out="$("$PY" -I "$CAP" --json verdict 2>/dev/null)"; rc=$?
[[ "$rc" == 2 ]] || fail "verdict sem a config do provider devia sair 2 (NÃO SEI), saiu $rc: $out"
printf '%s' "$out" | "$PY" -I -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if d["verdict"]=="unknown" and d["reason"]=="provider_config" else 1)' \
  || fail "verdict sem a config do provider devia ser unknown/provider_config: $out"
# o `verdict` acima inicializou $T/estado (lock + state.json) de propósito; o `status` é conferido numa pasta que NÃO existe: tem que continuar não existindo
out="$(HETZNER_CAPACITY_DIR="$T/so-leitura" "$PY" -I "$CAP" --json status 2>/dev/null)"; rc=$?
[[ "$rc" == 0 ]] || fail "status em pasta nova devia sair 0, saiu $rc"
printf '%s' "$out" | "$PY" -I -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if d["ceiling"]==1 and d["reads"]==0 else 1)' || fail "status em pasta nova devia ser degrau 1 sem leituras: $out"
[[ ! -e "$T/so-leitura" ]] || fail "status criou a pasta de estado (devia só ler): $(ls -A "$T/so-leitura")"
"$PY" -I "$CAP" --json set-ceiling 4 --reason "prod-test" >/dev/null 2>&1; rc=$?
[[ "$rc" == 3 ]] || fail "set-ceiling 4 (não é degrau) devia sair 3, saiu $rc"
log "oráculo: sem config → unknown (exit 2); status só lê; degrau fora da lista recusado ✓"
unset HETZNER_CAPACITY_DIR GC_SSH_CONFIG HETZNER_CAPACITY_SHIM_CONFIG

# ── O runbook diz o que falta (e onde está a fatia que falta)
for key in '## Contents' 'PILOT_NODE_FIRST' 'shadow' 'ga-2hd02v.1.14' 'ga-2hd02v.1.13' 'Medido, inferido, não testado'; do
  grep -q -- "$key" "$RUNBOOK" || fail "runbook não descreve '$key'"
done
log "runbook ✓"

run_suite() { # rótulo, padrão da linha de resultado, mínimo de casos, comando...
  local label="$1" pat="$2" min="$3"; shift 3
  local out; out="$("$@" 2>&1)" || { echo "$out" | tail -30 >&2; fail "$label falhou (ou estourou o prazo) contra a árvore viva"; }
  local line; line=$(printf '%s\n' "$out" | grep -E "$pat" | tail -1)
  [[ -n "$line" ]] || fail "$label sem a linha de resultado ($pat):
$(printf '%s\n' "$out" | tail -8)"
  local nums; nums=$(printf '%s' "$line" | grep -oE '[0-9]+' | head -2 | tr '\n' ' ')
  # shellcheck disable=SC2086
  set -- $nums
  [[ "$1" -ge "$min" ]] || fail "$label reportou '$line' (esperado pelo menos $min casos)"
  log "$label: $line ✓"
}
run_suite "bateria do Pilot (modo sombra)" '^── [0-9]+ ok, 0 falhas$' 20 env NF_NO_MUTANTS=1 timeout 300 bash "$PILOTT"
# a bateria do oráculo sai com "── N/N ok" (N = todos); sem os mutantes. Sob load 60+ no mini leva uns 6 min.
out="$(HC_NO_MUTANTS=1 timeout 900 bash "$CAPT" 2>&1)"; rc=$?
line=$(printf '%s\n' "$out" | grep -E '^── [0-9]+/[0-9]+ ok$' | tail -1)
[[ "$rc" == 0 && -n "$line" ]] || { printf '%s\n' "$out" | grep -E '^FAIL|^── ' | tail -15 >&2; fail "bateria do oráculo falhou (rc=$rc) ou sem a linha de resultado"; }
pass=$(printf '%s' "$line" | sed -E 's/^── ([0-9]+)\/([0-9]+) ok$/\1/'); total=$(printf '%s' "$line" | sed -E 's/^── ([0-9]+)\/([0-9]+) ok$/\2/')
[[ "$pass" == "$total" && "$total" -ge 60 ]] || fail "bateria do oráculo reportou '$line' (esperado todos ok e pelo menos 60 casos)"
log "bateria do oráculo: $line ✓"

log "PASS"
exit 0
