#!/usr/bin/env bash
# gate-hq-selftest-rules.selftest.sh — ga-075h15: o parágrafo HQ SELFTESTS do prompt do revisor aparece SÓ quando deve.
#
# Contents
#   Casos · Controles negativos (mutantes)
#
# O invariante que importa é o mesmo do TEST WRAPPER (gate-test-wrapper-rules.selftest.sh): com a chave desligada (nó off,
# gate-hq-selftest.off, mbp-run.sh ausente ou sem permissão, texto do builder) o prompt do revisor é BYTE-IDÊNTICO ao de antes.
# Aqui o nó Linux é a ÚNICA perna que conta: o repo hq não tem MBP (o mbp-run.sh responde 97), então mbp-offload.on sozinho NÃO liga o parágrafo.
# Hermético: cidade falsa em tmp. Rode com /bin/bash (3.2): é o interpretador do dispatcher.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/gate-review-task.lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/gate-hqst-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
check() { if [ "$2" = "1" ]; then ok "$1"; else bad "$1"; fi; }
# shellcheck disable=SC1090
. "$LIB" || { echo "FAIL: não consegui carregar $LIB"; exit 1; }

C="$T/city"; mkdir -p "$C/.gc" "$C/scripts"
printf '#!/bin/sh\nexit 0\n' > "$C/scripts/mbp-run.sh"; chmod +x "$C/scripts/mbp-run.sh"
printf '#!/bin/sh\nexit 0\n' > "$C/scripts/gate-pytest.sh"; chmod +x "$C/scripts/gate-pytest.sh"
render() { gate_render_review_task 1 1 feat/x tester gascity abc123 "LENS" "a.py" "sum" "HDR" "DIFF" "$1" VB-1 "${2:-bead}"; }
has() { if [[ "$2" == *"$1"* ]]; then echo 1; else echo 0; fi; }
empty() { [ -z "$1" ] && echo 1 || echo 0; }

# 1 caminhos que NÃO imprimem nada
out=$(gate_hq_selftest_rules ""); check "cidade vazia: nada" "$(empty "$out")"
out=$(gate_hq_selftest_rules "$C"); check "nó desligado (sem hetzner-node.on): nada" "$(empty "$out")"
touch "$C/.gc/mbp-offload.on"; out=$(gate_hq_selftest_rules "$C"); check "só mbp-offload.on (o hq não tem MBP): nada" "$(empty "$out")"
rm -f "$C/.gc/mbp-offload.on"
touch "$C/.gc/hetzner-node.on"
touch "$C/.gc/gate-hq-selftest.off"; out=$(gate_hq_selftest_rules "$C"); check "nó ligado + gate-hq-selftest.off: nada" "$(empty "$out")"; rm -f "$C/.gc/gate-hq-selftest.off"
touch "$C/.gc/gate-pytest.off"; out=$(gate_hq_selftest_rules "$C"); check "gate-pytest.off NÃO desliga o hq (interruptores independentes): imprime" "$([ -n "$out" ] && echo 1 || echo 0)"; rm -f "$C/.gc/gate-pytest.off"
chmod -x "$C/scripts/mbp-run.sh"; out=$(gate_hq_selftest_rules "$C"); check "mbp-run.sh sem permissão de execução: nada" "$(empty "$out")"
chmod +x "$C/scripts/mbp-run.sh"
mv "$C/scripts/mbp-run.sh" "$C/scripts/x.sh"; out=$(gate_hq_selftest_rules "$C"); check "mbp-run.sh ausente: nada" "$(empty "$out")"
mv "$C/scripts/x.sh" "$C/scripts/mbp-run.sh"

# 2 caminho que imprime
PARA=$(gate_hq_selftest_rules "$C")
check "tudo ligado: imprime" "$([ -n "$PARA" ] && echo 1 || echo 0)"
check "cita o mbp-run.sh DA cidade, com --repo hq e o --dir do hq dentro do worktree" "$(has "\"$C/scripts/mbp-run.sh\" --repo hq --dir <your-worktree>/.gascity-gastown-hq -- scripts/X.selftest.sh" "$PARA")"
check "uma bateria por chamada, caminho relativo, sem .." "$(has "One battery per call, the path relative to that directory and without .. in it" "$PARA")"
check "rc 96 a 99 = rode local, e NÃO é falha" "$([ "$(has "Exit 96 to 99" "$PARA")$(has "NOT a failure" "$PARA")" = 11 ] && echo 1 || echo 0)"
check "rc != 0 do nó: rodar a mesma bateria aqui antes de chamar de defeito" "$(has "run the same battery here before you call it a defect" "$PARA")"
check "rc 96-99 = rodar local PELO guarda de disco (heavy-guard.sh), e recusa 75/76 NÃO se contorna (ga-vln2py)" "$([ "$(has "\"$C/scripts/heavy-guard.sh\" --what X -- bash scripts/X.selftest.sh" "$PARA")$(has "refuses with exit 75" "$PARA")$(has "do NOT run the battery here by another route" "$PARA")" = 111 ] && echo 1 || echo 0)"
check "explica por quê: o nó só recebe código/doc/config (nunca .beads, .gc, Dolt, backup)" "$(has "never .beads, .gc, Dolt data or backups" "$PARA")"
check "quem decide o que fica no mini é o wrapper (97); não adivinhar" "$([ "$(has "it answers 97" "$PARA")$(has "do not guess" "$PARA")" = 11 ] && echo 1 || echo 0)"
check "bateria curta (< 60 s) roda aqui, com o custo da ida e volta (~1 min) dito como medido" "$([ "$(has "The round trip adds" "$PARA")$(has "a battery under about 60 s runs here" "$PARA")$(has "measured 55 to 78 s" "$PARA")" = 111 ] && echo 1 || echo 0)"
check "NÃO repete o custo de 6 s do pytest do wa (não vale para o hq)" "$([ "$(has "about 6 s" "$PARA")" = 0 ] && echo 1 || echo 0)"
check "NÃO duplica a lista mac-only (a fonte é hetzner-mac-only.hq.txt)" "$([ "$(has "launchctl" "$PARA")$(has "osascript" "$PARA")$(has "mac-only.hq.txt" "$PARA")" = 000 ] && echo 1 || echo 0)"
APOS=$(printf '%s' "$PARA" | tr -cd "'" | wc -c | tr -d ' ')
check "sem apóstrofo (o texto do prompt não pode ter: ga-6aj348)" "$([ "$APOS" = 0 ] && echo 1 || echo 0)"

# 3 prompt renderizado. A base é o prompt de ANTES desta bead: nenhuma bandeira (nem nó, nem MBP) = nem TEST WRAPPER nem HQ SELFTESTS.
# Com o nó ligado o TEST WRAPPER (ga-xm1jfl) também aparece, então ele sai da conta junto: ligado - TW - HQ == base, byte a byte.
rm -f "$C/.gc/hetzner-node.on"; BASE=$(render "$C"); touch "$C/.gc/hetzner-node.on"
check "base (nenhuma bandeira): sem TEST WRAPPER e sem HQ SELFTESTS" "$([ "$(has "TEST WRAPPER" "$BASE")$(has "HQ SELFTESTS" "$BASE")" = 00 ] && echo 1 || echo 0)"
TWP=$(gate_test_wrapper_rules "$C")
ON=$(render "$C")
check "bead mode ligado: tem o parágrafo" "$(has "HQ SELFTESTS" "$ON")"
touch "$C/.gc/gate-hq-selftest.off"; OFF=$(render "$C"); rm -f "$C/.gc/gate-hq-selftest.off"
check "bead mode com a chave: não tem o parágrafo" "$([ "$(has "HQ SELFTESTS" "$OFF")" = 0 ] && echo 1 || echo 0)"
STRIPPED="${ON/"$PARA"/}"
check "ligado MENOS o parágrafo == com a chave (nada mais mudou, byte a byte)" "$([ "$STRIPPED" = "$OFF" ] && echo 1 || echo 0)"
OFF_NOTW="${OFF/"$TWP"/}"
check "com a chave MENOS o TEST WRAPPER == base (a chave devolve o prompt de antes)" "$([ "$OFF_NOTW" = "$BASE" ] && echo 1 || echo 0)"
ON_BARE="${STRIPPED/"$TWP"/}"
check "ligado MENOS os dois parágrafos == base (byte a byte)" "$([ "$ON_BARE" = "$BASE" ] && echo 1 || echo 0)"
pos() { printf '%s' "$1" | awk -v k="$2" 'BEGIN{RS="\001"} {print index($0,k)}'; }
# o marco do fim do RUNNING TESTS é a ÚLTIMA frase do bloco: se for reescrito, troque este marco junto (marco ausente -> P1=0 -> reprova).
P1=$(pos "$ON" "failing test blocks only when this diff made it fail."); P2=$(pos "$ON" "HQ SELFTESTS"); P3=$(pos "$ON" "After completing your review")
check "o parágrafo fica logo depois do RUNNING TESTS e antes dos comandos do veredito" "$([ "$P1" -gt 0 ] && [ "$P2" -gt "$P1" ] && [ "$P3" -gt "$P2" ] && echo 1 || echo 0)"

# 3b com o TEST WRAPPER ligado também: os dois aparecem, nessa ordem, e cada um sai sem mexer no resto
touch "$C/.gc/mbp-offload.on"
BOTH=$(render "$C"); check "pytest e hq ligados: os dois parágrafos presentes" "$([ "$(has "TEST WRAPPER" "$BOTH")$(has "HQ SELFTESTS" "$BOTH")" = 11 ] && echo 1 || echo 0)"
Q1=$(pos "$BOTH" "TEST WRAPPER"); Q2=$(pos "$BOTH" "HQ SELFTESTS")
check "ordem: TEST WRAPPER antes do HQ SELFTESTS" "$([ "$Q1" -gt 0 ] && [ "$Q2" -gt "$Q1" ] && echo 1 || echo 0)"
BOTH_STRIPPED="${BOTH/"$PARA"/}"; BOTH_STRIPPED="${BOTH_STRIPPED/"$TWP"/}"
check "os dois ligados (nó + MBP) MENOS os dois parágrafos == base (byte a byte)" "$([ "$BOTH_STRIPPED" = "$BASE" ] && echo 1 || echo 0)"
rm -f "$C/.gc/mbp-offload.on"

# 4 texto do builder (pre-gate) nunca recebe: não há gate nem cidade
TXT=$(render "" text); check "text mode: sem parágrafo" "$([ "$(has "HQ SELFTESTS" "$TXT")" = 0 ] && echo 1 || echo 0)"
TXT2=$(GC_CITY="$C" render "" text); check "text mode ignora GC_CITY do ambiente" "$([ "$(has "HQ SELFTESTS" "$TXT2")" = 0 ] && echo 1 || echo 0)"

# 4b a faixa rápida (task-rapida) NÃO carrega o parágrafo, como o TEST WRAPPER
RAP=$(GATE_REVIEW_PROMPT_MODE=task-rapida render "$C")
check "task-rapida: sem o parágrafo (não há bateria para descarregar)" "$([ "$(has "HQ SELFTESTS" "$RAP")" = 0 ] && echo 1 || echo 0)"

# 5 sintaxe sob o bash 3.2 do dispatcher
if [ -x /bin/bash ]; then /bin/bash -n "$LIB" && ok "lib parseia sob /bin/bash" || bad "lib NÃO parseia sob /bin/bash"; else bad "/bin/bash ausente — não dá para checar"; fi

# controles negativos: cada linha de guarda é apagada DENTRO da função do hq, e o caso correspondente tem de PASSAR a imprimir.
# (sem este controle um teste que "não imprime" poderia estar passando por outro motivo)
mutate() { # $1 nome · $2 regexp da linha a apagar · $3 prepara a cidade · $4 desfaz
  sed "/^gate_hq_selftest_rules() {/,/^}/{\\#$2#d;}" "$LIB" > "$T/mut.lib.sh"
  if cmp -s "$LIB" "$T/mut.lib.sh"; then bad "controle $1: o mutante é idêntico (sed não casou)"; return; fi
  local mo; mo=$( . "$T/mut.lib.sh"; $3; gate_hq_selftest_rules "$C" ); $4
  if [ -n "$mo" ]; then ok "controle negativo $1 (o mutante imprime onde o código real calaria)"; else bad "controle $1: o mutante também ficou calado"; fi
}
mutate "sem o interruptor"          'gate-hq-selftest\.off'             "touch $C/.gc/gate-hq-selftest.off"  "rm -f $C/.gc/gate-hq-selftest.off"
mutate "sem a bandeira do nó"       'hetzner-node\.on'                  "rm -f $C/.gc/hetzner-node.on"       "touch $C/.gc/hetzner-node.on"
mutate "sem o teste de execução"    '-x "\$_city/scripts/mbp-run\.sh"'  "chmod -x $C/scripts/mbp-run.sh"     "chmod +x $C/scripts/mbp-run.sh"
# a fiação: sem o ${_GATE_HQ} no corpo o prompt ligado não leva o parágrafo (o caso do bloco 3 pegaria)
sed 's/\${_GATE_HQ}//' "$LIB" > "$T/mut4.lib.sh"
if cmp -s "$LIB" "$T/mut4.lib.sh"; then bad "controle sem a fiação: o mutante é idêntico (sed não casou)"; else
  mo=$( . "$T/mut4.lib.sh"; gate_render_review_task 1 1 feat/x tester gascity abc123 "LENS" "a.py" "sum" "HDR" "DIFF" "$C" VB-1 bead )
  if [ "$(has "HQ SELFTESTS" "$mo")" = 0 ]; then ok "controle negativo sem a fiação (o mutante renderiza o prompt SEM o parágrafo — o bloco 3 pegaria)"; else bad "controle sem a fiação: o mutante ainda traz o parágrafo"; fi; fi

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
