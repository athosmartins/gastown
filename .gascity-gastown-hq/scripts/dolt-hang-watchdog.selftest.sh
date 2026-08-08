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

# ── ga-153cq gate-FAIL 1: DRY_RUN tem de ser SEM EFEITO COLATERAL de ponta a
# ponta. O reviewer pegou: o gate do DRY_RUN estava ABAIXO da secao de veto, entao
# um dry run ainda ESCREVIA o contador real e ainda DISPARAVA notify — inclusive um
# P5 dizendo "restarting Dolt anyway" pra um restart que ele nunca fazia.
# ⚠️ E o meu proprio teste ESCONDEU isso porque passava CPU_VETO_FILE explicito:
# teste que fornece o override nao consegue descobrir que o override e OBRIGATORIO.
# Por isso os asserts abaixo rodam SEM override de veto-file, que e o caso real. ──
echo "ga-153cq: DRY_RUN e side-effect-free de ponta a ponta (sem override de estado)"
if [ -f "$SRC" ]; then
  # (a) ordem no fonte: a interceptacao do DRY_RUN tem de vir ANTES do write e dos notify
  _dry_ln=$(grep -n 'DOLT_WATCHDOG_DRY_RUN:-0' "$SRC" | head -1 | cut -d: -f1)
  _wr_ln=$(grep -n 'echo "\$_vetoes" > "\$CPU_VETO_FILE"' "$SRC" | head -1 | cut -d: -f1)
  _nt_ln=$(grep -n 'notify -p [45] -t .Dolt hang-watchdog.' "$SRC" | head -1 | cut -d: -f1)
  if [ -n "$_dry_ln" ] && [ -n "$_wr_ln" ] && [ "$_dry_ln" -lt "$_wr_ln" ]; then
    ok "DRY_RUN intercepta ANTES do write do contador de veto (linha $_dry_ln < $_wr_ln)"
  else
    bad "ga-153cq regressao: DRY_RUN (${_dry_ln:-?}) nao vem antes do write do CPU_VETO_FILE (${_wr_ln:-?})"
  fi
  if [ -n "$_dry_ln" ] && [ -n "$_nt_ln" ] && [ "$_dry_ln" -lt "$_nt_ln" ]; then
    ok "DRY_RUN intercepta ANTES de qualquer notify (linha $_dry_ln < $_nt_ln)"
  else
    bad "ga-153cq regressao: DRY_RUN (${_dry_ln:-?}) nao vem antes do 1o notify (${_nt_ln:-?}) — dry run manda alerta falso"
  fi

  # (b) comportamento real: dry run SEM override de veto-file nao pode criar/mexer no arquivo
  _real_veto="/tmp/dolt-hang-watchdog.cpuveto"
  _had=$([ -f "$_real_veto" ] && cat "$_real_veto" 2>/dev/null || echo "__ausente__")
  _tmpd=$(mktemp -d)
  env DOLT_WATCHDOG_DRY_RUN=1 \
      DOLT_WATCHDOG_LOG="$_tmpd/l" DOLT_WATCHDOG_STRIKES_FILE="$_tmpd/s" \
      DOLT_WATCHDOG_PROBE_TIMEOUT=1 DOLT_WATCHDOG_SERVE_CONFIRM=2 BEADS_DOLT_PORT=1 \
      DOLT_WATCHDOG_CPU_ALIVE_PCT=0 \
      bash "$SRC" >/dev/null 2>&1
  env DOLT_WATCHDOG_DRY_RUN=1 \
      DOLT_WATCHDOG_LOG="$_tmpd/l" DOLT_WATCHDOG_STRIKES_FILE="$_tmpd/s" \
      DOLT_WATCHDOG_PROBE_TIMEOUT=1 DOLT_WATCHDOG_SERVE_CONFIRM=2 BEADS_DOLT_PORT=1 \
      DOLT_WATCHDOG_CPU_ALIVE_PCT=0 \
      bash "$SRC" >/dev/null 2>&1
  env DOLT_WATCHDOG_DRY_RUN=1 \
      DOLT_WATCHDOG_LOG="$_tmpd/l" DOLT_WATCHDOG_STRIKES_FILE="$_tmpd/s" \
      DOLT_WATCHDOG_PROBE_TIMEOUT=1 DOLT_WATCHDOG_SERVE_CONFIRM=2 BEADS_DOLT_PORT=1 \
      DOLT_WATCHDOG_CPU_ALIVE_PCT=0 \
      bash "$SRC" >/dev/null 2>&1
  _now=$([ -f "$_real_veto" ] && cat "$_real_veto" 2>/dev/null || echo "__ausente__")
  [ "$_had" = "$_now" ] && ok "3 dry runs sem override NAO tocaram o contador real ($_had)" \
                        || bad "ga-153cq regressao: dry run mexeu no contador real de producao ($_had -> $_now)"
  grep -q 'DRY-RUN: would VETO' "$_tmpd/l" 2>/dev/null \
    && ok "dry run REPORTA o ramo de veto que teria tomado (nao ficou mudo)" \
    || bad "dry run nao reportou o ramo de veto — perde o valor de diagnostico"
  rm -rf "$_tmpd"
else
  bad "nao achei o script ao lado — asserts de DRY_RUN nao rodaram"
fi

echo
echo "dolt-hang-watchdog selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
