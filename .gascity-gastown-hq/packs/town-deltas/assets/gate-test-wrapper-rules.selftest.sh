#!/usr/bin/env bash
# gate-test-wrapper-rules.selftest.sh — ga-xm1jfl: o parágrafo TEST WRAPPER do prompt do revisor aparece SÓ quando deve.
#
# Contents
#   Casos · Controle negativo
#
# O invariante que importa: com a chave desligada (offload off, gate-pytest.off, wrapper ausente, texto do builder) o prompt do
# revisor é BYTE-IDÊNTICO ao de antes — "chave desligada = comportamento idêntico ao de hoje". Hermético: cidade falsa em tmp.
# Rode com /bin/bash (3.2): é o interpretador do dispatcher.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/gate-review-task.lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/gate-twr-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
check() { if [ "$2" = "1" ]; then ok "$1"; else bad "$1"; fi; }
# shellcheck disable=SC1090
. "$LIB" || { echo "FAIL: não consegui carregar $LIB"; exit 1; }

C="$T/city"; mkdir -p "$C/.gc" "$C/scripts"
printf '#!/bin/sh\nexit 0\n' > "$C/scripts/gate-pytest.sh"; chmod +x "$C/scripts/gate-pytest.sh"
render() { gate_render_review_task 1 1 feat/x tester gascity abc123 "LENS" "a.py" "sum" "HDR" "DIFF" "$1" VB-1 "${2:-bead}"; }
has() { if [[ "$2" == *"$1"* ]]; then echo 1; else echo 0; fi; }

# 1 caminhos que NÃO imprimem nada
out=$(gate_test_wrapper_rules ""); check "cidade vazia: nada" "$([ -z "$out" ] && echo 1 || echo 0)"
out=$(gate_test_wrapper_rules "$C"); check "offload.on ausente: nada" "$([ -z "$out" ] && echo 1 || echo 0)"
touch "$C/.gc/mbp-offload.on"
touch "$C/.gc/gate-pytest.off"; out=$(gate_test_wrapper_rules "$C"); check "gate-pytest.off presente: nada" "$([ -z "$out" ] && echo 1 || echo 0)"
rm -f "$C/.gc/gate-pytest.off"
chmod -x "$C/scripts/gate-pytest.sh"; out=$(gate_test_wrapper_rules "$C"); check "wrapper sem permissão de execução: nada" "$([ -z "$out" ] && echo 1 || echo 0)"
chmod +x "$C/scripts/gate-pytest.sh"
mv "$C/scripts/gate-pytest.sh" "$C/scripts/x.sh"; out=$(gate_test_wrapper_rules "$C"); check "wrapper ausente: nada" "$([ -z "$out" ] && echo 1 || echo 0)"
mv "$C/scripts/x.sh" "$C/scripts/gate-pytest.sh"

# 2 caminho que imprime
PARA=$(gate_test_wrapper_rules "$C")
check "tudo ligado: imprime" "$([ -n "$PARA" ] && echo 1 || echo 0)"
check "cita o caminho do wrapper da cidade" "$(has "\"$C/scripts/gate-pytest.sh\" --dir <your-worktree> --" "$PARA")"
check "pede para copiar a linha final no veredito" "$(has "gate-pytest: ran=mbp rc=0 secs=11" "$PARA")"
check "diz para passar arquivos, nunca diretório" "$(has "never a directory" "$PARA")"
check "diz que o resultado de aqui é o que vale" "$(has "the result from here is the one that counts" "$PARA")"
check "diz que o vermelho que passa isolado roda o comando inteiro aqui (-x / pulado não somem)" "$(has "when the failed tests pass alone here the whole command is run here as well" "$PARA")"
check "diz que o verde do MBP pode ser vazio (sem shared/data nem .env)" "$(has "A clean pass on the MacBook can still be empty" "$PARA")"
check "manda tratar o verde como não verificado quando o código lê dado" "$(has "treat that pass as unverified" "$PARA")"
check "diz que, sem saber qual teste pulou, todos os arquivos rodam aqui" "$(has "every target file, when it cannot tell which test skipped" "$PARA")"
check "não promete que tudo o que o wrapper imprime é confiável" "$([ "$(has "safe to believe" "$PARA")" = 0 ] && echo 1 || echo 0)"
APOS=$(printf '%s' "$PARA" | tr -cd "'" | wc -c | tr -d ' ')
check "sem apóstrofo (o texto do prompt não pode ter: ga-6aj348)" "$([ "$APOS" = 0 ] && echo 1 || echo 0)"

# 3 prompt renderizado: ligado = desligado + o parágrafo, e mais nada
ON=$(render "$C")
check "bead mode ligado: tem o parágrafo" "$(has "TEST WRAPPER" "$ON")"
touch "$C/.gc/gate-pytest.off"; OFF=$(render "$C"); rm -f "$C/.gc/gate-pytest.off"
check "bead mode com a chave: não tem o parágrafo" "$([ "$(has "TEST WRAPPER" "$OFF")" = 0 ] && echo 1 || echo 0)"
STRIPPED="${ON/"$PARA"/}"
check "ligado MENOS o parágrafo == desligado (nada mais mudou, byte a byte)" "$([ "$STRIPPED" = "$OFF" ] && echo 1 || echo 0)"
# a ordem dos três marcos: fim do RUNNING TESTS < parágrafo < comandos do veredito (índices por awk, sem case dentro de $())
pos() { printf '%s' "$ON" | awk -v k="$1" 'BEGIN{RS="\001"} {print index($0,k)}'; }
P1=$(pos "best defence the gate has."); P2=$(pos "TEST WRAPPER"); P3=$(pos "After completing your review")
check "o parágrafo fica logo depois do RUNNING TESTS e antes dos comandos do veredito" "$([ "$P1" -gt 0 ] && [ "$P2" -gt "$P1" ] && [ "$P3" -gt "$P2" ] && echo 1 || echo 0)"

# 4 texto do builder (pre-gate) nunca recebe: não há gate nem cidade
TXT=$(render "" text); check "text mode: sem parágrafo" "$([ "$(has "TEST WRAPPER" "$TXT")" = 0 ] && echo 1 || echo 0)"
GC_CITY="$C" TXT2=$(GC_CITY="$C" render "" text); check "text mode ignora GC_CITY do ambiente" "$([ "$(has "TEST WRAPPER" "$TXT2")" = 0 ] && echo 1 || echo 0)"

# 5 sintaxe sob o bash 3.2 do dispatcher
if [ -x /bin/bash ]; then /bin/bash -n "$LIB" && ok "lib parseia sob /bin/bash" || bad "lib NÃO parseia sob /bin/bash"; else bad "/bin/bash ausente — não dá para checar"; fi

# controle negativo: sem o teste do interruptor o caso "gate-pytest.off presente" PASSARIA a imprimir
sed '/gate-pytest.off" \] && return 0/d' "$LIB" > "$T/mut.lib.sh"
cmp -s "$LIB" "$T/mut.lib.sh" && bad "controle: o mutante é idêntico (sed não casou)" || {
  mutout=$( . "$T/mut.lib.sh"; touch "$C/.gc/gate-pytest.off"; gate_test_wrapper_rules "$C"; rm -f "$C/.gc/gate-pytest.off" )
  if [ -n "$mutout" ]; then ok "controle negativo (o mutante sem o interruptor imprime com a chave ligada — o caso 1 pegaria)"; else bad "controle negativo: o mutante também ficou calado"; fi; }

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
