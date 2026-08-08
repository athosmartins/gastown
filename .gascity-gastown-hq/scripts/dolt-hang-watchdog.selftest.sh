#!/usr/bin/env bash
# dolt-hang-watchdog.selftest.sh — ga-153cq
#
# POR QUE ESTE ARQUIVO EXISTE: o dolt-hang-watchdog e o unico caminho automatico
# que manda SIGQUIT no processo Dolt da cidade inteira — a doutrina do CLAUDE.md
# chama isso de NEVER, e ele ja rodou 87 vezes. Um script com esse poder nao
# tinha NENHUM teste. O que este arquivo trava e o VETO: que a etapa destrutiva
# consulte de fato o discriminador que o proprio arquivo documenta (hang real
# vive em ~0% CPU), em vez de so registra-lo no ramo onde nao decide nada.
#
# Testa a LOGICA DE DECISAO isoladamente — nunca toca no Dolt de verdade, nunca
# manda sinal pra processo nenhum. Um teste que precisasse de um Dolt pendurado
# pra rodar nunca rodaria, e e justamente por isso que nao havia teste.
#
# Uso: bash dolt-hang-watchdog.selftest.sh
set -uo pipefail
PASS=0; FAIL=0
ok()  { echo "  ok  $*"; PASS=$((PASS+1)); }
bad() { echo "  BAD $*"; FAIL=$((FAIL+1)); }

# Replica EXATA do predicado de veto do script (mesma ordem de avaliacao).
# Devolve: VETO | RESTART
decide() {
  local cpu="$1" vetoes="$2" alive="${3:-20}" vmax="${4:-5}"
  if [ -n "$cpu" ] && [ "$cpu" -ge "$alive" ] && [ "$vetoes" -lt "$vmax" ]; then
    echo VETO; else echo RESTART; fi
}

echo "== ga-153cq: veto de CPU na etapa destrutiva =="

# 1. O caso que motivou tudo: saturacao real medida no log vivo (50-207% CPU).
for C in 50 69 110 207; do
  R=$(decide "$C" 0)
  [ "$R" = VETO ] && ok "cpu=${C}% (saturacao medida no log vivo) -> VETO" \
                  || bad "cpu=${C}% deveria VETAR o restart, deu $R"
done

# 2. Hang de verdade: o proprio arquivo define como ~0% CPU. TEM de reiniciar —
#    este e o controle que impede o conserto preguicoso (vetar sempre trocaria
#    'mata servidor sadio' por 'nunca recupera hang real', que e pior).
for C in 0 1 5 19; do
  R=$(decide "$C" 0)
  [ "$R" = RESTART ] && ok "cpu=${C}% (hang real, ~0%) -> RESTART" \
                     || bad "cpu=${C}% e hang real e TEM de reiniciar, deu $R"
done

# 3. Fronteira exata do limiar — >= e nao >.
[ "$(decide 20 0)" = VETO ]    && ok "cpu=20% (limiar exato) -> VETO" || bad "limiar deve ser >=, 20% deu RESTART"
[ "$(decide 19 0)" = RESTART ] && ok "cpu=19% (logo abaixo) -> RESTART" || bad "19% deveria reiniciar"

# 4. ⚠️ O veto NAO pode ser permanente: spin-deadlock tambem queima CPU.
#    Depois de CPU_VETO_MAX confirmacoes vetadas seguidas, tem de ceder.
[ "$(decide 207 4)" = VETO ]    && ok "cpu alto, 4/5 vetos -> ainda VETO" || bad "4 vetos ainda deveria vetar"
[ "$(decide 207 5)" = RESTART ] && ok "cpu alto, veto ESGOTADO (5/5) -> RESTART (nao trava pra sempre)" \
                                || bad "veto esgotado tem de deixar reiniciar — senao hang real nunca recupera"
[ "$(decide 207 9)" = RESTART ] && ok "vetos acima do teto -> RESTART" || bad "acima do teto deveria reiniciar"

# 5. ⚠️ CPU DESCONHECIDA (pgrep/ps falharam) nao pode virar veto silencioso:
#    'nao sei' tem de cair no comportamento anterior (reinicia), nunca em
#    'assume que esta vivo e nunca recupera'. Classe erro-vs-vazio.
[ "$(decide "" 0)" = RESTART ] && ok "cpu desconhecida ('') -> RESTART (nao-sei nao vira veto)" \
                               || bad "cpu vazia virou VETO — 'nao sei' colapsou em 'esta vivo'"

# 6. Os dois bounds do confirm nao podem discordar: o connect_timeout interno
#    tem de acompanhar o SERVE_CONFIRM_TIMEOUT externo, senao o externo e enfeite.
SRC="$(dirname "$0")/dolt-hang-watchdog.sh"
if [ -f "$SRC" ]; then
  grep -q 'connect_timeout=int(sys.argv\[2\])' "$SRC" \
    && ok "connect_timeout deriva do SERVE_CONFIRM_TIMEOUT (nao mais fixo em 8)" \
    || bad "connect_timeout voltou a ser fixo — o bound externo vira enfeite"
  grep -q 'cpu=\${_strike_cpu' "$SRC" \
    && ok "CPU registrada TAMBEM no ramo de strike (evidencia p/ auditar restart)" \
    || bad "CPU nao esta logada no ramo de strike — sem evidencia retroativa"
  grep -q 'rm -f "\$CPU_VETO_FILE"' "$SRC" \
    && ok "contador de veto e limpo na recuperacao" \
    || bad "contador de veto nunca limpo — vira contagem regressiva pro restart"
else
  bad "nao achei dolt-hang-watchdog.sh ao lado — drift-guards nao rodaram"
fi

echo
echo "dolt-hang-watchdog selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
