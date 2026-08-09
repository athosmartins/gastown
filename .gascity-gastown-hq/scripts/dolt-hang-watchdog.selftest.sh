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
  # (a) ordem no fonte: a interceptacao do DRY_RUN tem de vir ANTES do write e dos notify.
  # ga-153cq gate-FAIL 2: isto costumava dar grep em 'DOLT_WATCHDOG_DRY_RUN:-0', que
  # apos o fix vira a definicao da variavel DRY_RUN la no topo do arquivo — sempre
  # "antes" de qualquer coisa por construcao, o que teria tornado este assert
  # verdadeiro pra sempre e mudo (nao prova mais nada sobre O GATE DA SECAO DE VETO
  # especificamente). Agora ha 4 call-sites de `if is_dry_run` (recuperacao saudavel,
  # saturacao, escrita de strike, veto/restart, nessa ordem linear no arquivo) — o
  # ULTIMO e o da secao de veto, entao pega o ultimo, nao o primeiro.
  _dry_ln=$(grep -n 'if is_dry_run' "$SRC" | tail -1 | cut -d: -f1)
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
  # ga-153cq gate-FAIL 2: precisa de DOLT_WATCHDOG_MAX_STRIKES=1 agora — antes, estas
  # 3 chamadas alcancavam o ramo de veto por ACUMULAR no STRIKES_FILE scratch entre
  # as 3 (1, depois 2, depois 3=MAX_STRIKES). Mas isso so funcionava por causa do
  # PROPRIO bug do blocking-issue-1 (a escrita de strike era incondicional mesmo sob
  # DRY_RUN=1) — com esse bug corrigido, um dry run nunca mais persiste strike
  # nenhum, entao as 3 chamadas releriam sempre o mesmo "0" e nunca acumulariam.
  # MAX_STRIKES=1 faz CADA chamada alcancar "confirmado" sozinha, sem depender de
  # acumulo — e continua sem tocar o contador real (e disso que este teste trata).
  #
  # ga-153cq gate-FAIL 3 (reviewer right a third time, same block): DOLT_WATCHDOG_
  # CPU_ALIVE_PCT=0 below makes ANY cpu reading qualify as "alive", but until now
  # that reading itself came from dolt_cpu_pct()'s raw, unscoped pgrep — so this
  # assertion only reached the veto branch when the REVIEW HOST happened to have a
  # live 'dolt sql-server' process. No live Dolt (bare CI box, mid-outage debugging
  # — exactly when this script matters) meant dolt_cpu_pct() correctly returned ""
  # and the veto branch was silently never exercised at all: pass/fail decoupled
  # from the code under test, decided by ambient host state instead. Fixed at the
  # source (DOLT_WATCHDOG_CPU_PID override, see dolt-hang-watchdog.sh) rather than
  # patched here alone — DOLT_WATCHDOG_CPU_PID=$$ points dolt_cpu_pct() at THIS
  # selftest's own PID, always alive for the duration of the call, so `ps` always
  # returns a real (if near-zero) reading independent of whether Dolt is running.
  _real_veto="/tmp/dolt-hang-watchdog.cpuveto"
  _had=$([ -f "$_real_veto" ] && cat "$_real_veto" 2>/dev/null || echo "__ausente__")
  _tmpd=$(mktemp -d)
  env DOLT_WATCHDOG_DRY_RUN=1 DOLT_WATCHDOG_MAX_STRIKES=1 \
      DOLT_WATCHDOG_LOG="$_tmpd/l" DOLT_WATCHDOG_STRIKES_FILE="$_tmpd/s" \
      DOLT_WATCHDOG_PROBE_TIMEOUT=1 DOLT_WATCHDOG_SERVE_CONFIRM=2 BEADS_DOLT_PORT=1 \
      DOLT_WATCHDOG_CPU_ALIVE_PCT=0 DOLT_WATCHDOG_CPU_PID=$$ \
      bash "$SRC" >/dev/null 2>&1
  env DOLT_WATCHDOG_DRY_RUN=1 DOLT_WATCHDOG_MAX_STRIKES=1 \
      DOLT_WATCHDOG_LOG="$_tmpd/l" DOLT_WATCHDOG_STRIKES_FILE="$_tmpd/s" \
      DOLT_WATCHDOG_PROBE_TIMEOUT=1 DOLT_WATCHDOG_SERVE_CONFIRM=2 BEADS_DOLT_PORT=1 \
      DOLT_WATCHDOG_CPU_ALIVE_PCT=0 DOLT_WATCHDOG_CPU_PID=$$ \
      bash "$SRC" >/dev/null 2>&1
  env DOLT_WATCHDOG_DRY_RUN=1 DOLT_WATCHDOG_MAX_STRIKES=1 \
      DOLT_WATCHDOG_LOG="$_tmpd/l" DOLT_WATCHDOG_STRIKES_FILE="$_tmpd/s" \
      DOLT_WATCHDOG_PROBE_TIMEOUT=1 DOLT_WATCHDOG_SERVE_CONFIRM=2 BEADS_DOLT_PORT=1 \
      DOLT_WATCHDOG_CPU_ALIVE_PCT=0 DOLT_WATCHDOG_CPU_PID=$$ \
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

# ── ga-153cq gate-FAIL 2: o teste acima protegia o contador de VETO contra
# escrita real, mas ainda passava DOLT_WATCHDOG_STRIKES_FILE pra um scratch dir —
# ou seja, protegia exatamente o contador que este bloco existe pra checar. O
# reviewer confirmou por busca no repo: o UNICO lugar que pareia DRY_RUN=1 com
# um override de STRIKES era este proprio selftest. Nenhum plist/wrapper real
# da esse override — entao o uso "natural" (`DOLT_WATCHDOG_DRY_RUN=1 bash
# dolt-hang-watchdog.sh`, exatamente o caso de uso documentado no topo do
# arquivo) escreve no MESMO /tmp/dolt-hang-watchdog.strikes que o cron real de
# 60s le. Este bloco testa isso de verdade — SEM overridar STRIKES_FILE — e
# protege o arquivo real com snapshot+restore (trap) pra nao deixar o
# contador de producao pior do que achou, mesmo que o codigo sob teste esteja
# quebrado (o proprio ponto do teste). Um `gc` falso no PATH torna probe_ok()
# deterministico (sem race contra latencia real do `gc dolt health`, ao
# contrario do teste acima que depende de PROBE_TIMEOUT=1 vencer essa corrida). ──
echo "ga-153cq gate-FAIL 2: DRY_RUN e side-effect-free tambem pro contador de STRIKES (sem override, caminho real)"
if [ -f "$SRC" ]; then
  _tmpd2=$(mktemp -d)
  mkdir -p "$_tmpd2/bin"
  cat > "$_tmpd2/bin/gc" <<'FAKE'
#!/usr/bin/env bash
# Fake `gc`: forca probe_ok() a FALHAR de forma deterministica (unreachable),
# sem depender de vencer corrida nenhuma contra o `gc dolt health` de verdade.
if [ "${1:-}" = "dolt" ] && [ "${2:-}" = "health" ]; then
  echo '{"server":{"reachable":false}}'
  exit 0
fi
exit 1
FAKE
  chmod +x "$_tmpd2/bin/gc"

  _real_strikes="/tmp/dolt-hang-watchdog.strikes"
  _snap=$([ -f "$_real_strikes" ] && cat "$_real_strikes" 2>/dev/null || echo "__ausente__")
  _restore_real_strikes() {
    if [ "$_snap" = "__ausente__" ]; then rm -f "$_real_strikes"; else echo "$_snap" > "$_real_strikes"; fi
  }
  trap _restore_real_strikes EXIT

  # DOLT_WATCHDOG_MAX_STRIKES=1 so faz ESTA invocacao decidir "confirmado" em 1
  # tiro (alcanca o ramo mais fundo do DRY_RUN, o que o gate-FAIL 2 relatou) sem
  # precisar de 3 chamadas — o override e so do LIMIAR de decisao desta run, nao
  # muda o que fica de fato gravado no contador real.
  env PATH="$_tmpd2/bin:$PATH" \
      DOLT_WATCHDOG_DRY_RUN=1 DOLT_WATCHDOG_MAX_STRIKES=1 \
      DOLT_WATCHDOG_LOG="$_tmpd2/l" \
      DOLT_WATCHDOG_SERVE_CONFIRM=2 BEADS_DOLT_PORT=1 \
      bash "$SRC" >/dev/null 2>&1
  _now=$([ -f "$_real_strikes" ] && cat "$_real_strikes" 2>/dev/null || echo "__ausente__")
  [ "$_snap" = "$_now" ] && ok "dry run confirmado (sem override de STRIKES_FILE) NAO tocou o contador real ($_snap)" \
                         || bad "ga-153cq regressao: dry run avancou o contador REAL de strikes de producao ($_snap -> $_now)"
  grep -qE 'DRY-RUN: would (advance strike counter|kill -QUIT)' "$_tmpd2/l" 2>/dev/null \
    && ok "dry run REPORTA a simulacao de strike (nao ficou mudo)" \
    || bad "dry run nao reportou nada sobre o strike simulado — perde o valor de diagnostico"
  _restore_real_strikes
  trap - EXIT
  rm -rf "$_tmpd2"
else
  bad "nao achei o script ao lado — asserts de STRIKES/DRY_RUN nao rodaram"
fi

# ── ga-153cq gate-FAIL 2, blocking issue 2: os ramos de RECUPERACAO (saude
# provada, saturacao provada) tambem limpavam STRIKES/CPU_VETO_FILE sem checar
# DRY_RUN — mesma classe, variavel diferente, mesmo arquivo, mesmo commit que
# so consertou a escrita de strike. Nao arma nada destrutivo (so reseta um
# contador de seguranca pra MAIS cautela, nunca menos) mas ainda mente sob a
# flag que promete zero efeito colateral. Testado 100% isolado (arquivos
# scratch com sentinela pre-existente + `gc` falso) porque este ramo especifico
# exige um probe_ok() BEM-SUCEDIDO — nao ha razao pra depender da saude real do
# Dolt neste host no momento exato em que o selftest roda. ──
echo "ga-153cq gate-FAIL 2 (blocking issue 2): ramo de recuperacao saudavel nao limpa STRIKES/veto sob DRY_RUN"
if [ -f "$SRC" ]; then
  _tmpd3=$(mktemp -d)
  mkdir -p "$_tmpd3/bin"
  cat > "$_tmpd3/bin/gc" <<'FAKE'
#!/usr/bin/env bash
# Fake `gc`: forca probe_ok() a SUCEDER de forma deterministica (saudavel),
# pra exercitar o ramo de recuperacao sem depender da saude real do Dolt.
if [ "${1:-}" = "dolt" ] && [ "${2:-}" = "health" ]; then
  echo '{"server":{"reachable":true}}'
  exit 0
fi
exit 1
FAKE
  chmod +x "$_tmpd3/bin/gc"
  echo 2 > "$_tmpd3/s"   # sentinela: contador de strikes PRE-EXISTENTE (scratch, isolado)
  echo 3 > "$_tmpd3/v"   # sentinela: contador de veto PRE-EXISTENTE (scratch, isolado)
  env PATH="$_tmpd3/bin:$PATH" \
      DOLT_WATCHDOG_DRY_RUN=1 \
      DOLT_WATCHDOG_LOG="$_tmpd3/l" \
      DOLT_WATCHDOG_STRIKES_FILE="$_tmpd3/s" DOLT_WATCHDOG_CPU_VETO_FILE="$_tmpd3/v" \
      bash "$SRC" >/dev/null 2>&1
  [ "$(cat "$_tmpd3/s" 2>/dev/null)" = "2" ] && ok "ramo saudavel: DRY_RUN nao zerou o contador de strikes pre-existente" \
                                  || bad "ga-153cq regressao: ramo saudavel zerou/mexeu em strikes mesmo sob DRY_RUN"
  [ "$(cat "$_tmpd3/v" 2>/dev/null)" = "3" ] && ok "ramo saudavel: DRY_RUN nao zerou o contador de veto pre-existente" \
                                  || bad "ga-153cq regressao: ramo saudavel zerou/mexeu no veto mesmo sob DRY_RUN"
  grep -qE 'DRY-RUN: Dolt healthy' "$_tmpd3/l" 2>/dev/null \
    && ok "dry run REPORTA o ramo de recuperacao saudavel que teria tomado (nao ficou mudo)" \
    || bad "dry run nao reportou o ramo de recuperacao saudavel — perde o valor de diagnostico"
  rm -rf "$_tmpd3"
else
  bad "nao achei o script ao lado — asserts do ramo de recuperacao nao rodaram"
fi

# (b) checagem estatica de cobertura: os 4 pontos de mutacao conhecidos (recuperacao
# saudavel, saturacao, escrita de strike, veto/restart) tem de estar TODOS atras do
# mesmo helper — nao 3 de 4, que foi exatamente o estado que passou pelo attempt 1.
if [ -f "$SRC" ]; then
  _gate_count=$(grep -cE '^[[:space:]]*if is_dry_run' "$SRC")
  [ "$_gate_count" -eq 4 ] && ok "4/4 pontos de mutacao conhecidos usam is_dry_run (nenhum novo ficou de fora)" \
                            || bad "ga-153cq regressao: esperava 4 call-sites de 'if is_dry_run', achei ${_gate_count} — algum ramo de mutacao ficou sem gate"
fi

# ── ga-wxwao (case 2): the post-restart "still unhealthy" branch must call the
# canonical escalate_emergency() path (--class town-halted), not the raw ad-hoc
# `notify -p 5` it used to (which only ever reached push because its message
# happened to contain "NEEDS HUMAN", matching notify's own content classifier —
# a silent, wording-dependent fragility). Static check, not dynamic: reaching
# this branch by actually running the script means surviving the SAME
# kill -QUIT + restart machinery the gate-FAIL 2/3 blocks above work so hard to
# avoid — and here `pgrep -f 'dolt sql-server'` would find THIS HOST'S REAL
# PRODUCTION Dolt process, not a scratch fixture (no STRIKES/veto-file-style
# override exists for "which PID looks like Dolt" at the kill site). There is
# no safe way to dynamically exercise this specific branch. The function being
# called (escalate_emergency.py) has its own independent --selftest (17/0 as of
# this fix) — this file's job is only to prove the RIGHT call, with the RIGHT
# class, replaced the old raw notify, not to re-verify escalate_emergency()'s
# own internals. ──
echo "ga-wxwao: post-restart still-unhealthy branch calls escalate_emergency (--class town-halted), not raw notify"
if [ -f "$SRC" ]; then
  _still_unhealthy_block=$(sed -n '/WARN: Dolt STILL unhealthy after restart/,/^fi$/p' "$SRC")
  if [ -n "$_still_unhealthy_block" ]; then
    if printf '%s' "$_still_unhealthy_block" | grep -q 'escalate_emergency\.py'; then
      ok "still-unhealthy branch calls escalate_emergency.py"
    else
      bad "ga-wxwao regressao: still-unhealthy branch nao chama mais escalate_emergency.py"
    fi
    if printf '%s' "$_still_unhealthy_block" | grep -q -- '--class town-halted'; then
      ok "escalate_emergency call uses --class town-halted (correct sanctioned class)"
    else
      bad "ga-wxwao regressao: escalate_emergency call nao usa --class town-halted"
    fi
    if printf '%s' "$_still_unhealthy_block" | grep -qE "notify[[:space:]]+-p[[:space:]]+5[[:space:]]+-t[[:space:]]+'Dolt hang-watchdog'"; then
      bad "ga-wxwao regressao: ramo still-unhealthy AINDA chama notify -p 5 direto — dupla notificacao (escalate_emergency ja chama notify internamente)"
    else
      ok "raw ad-hoc 'notify -p 5' call removed from still-unhealthy branch (no double-notify)"
    fi
    if printf '%s' "$_still_unhealthy_block" | grep -q "NEEDS HUMAN"; then
      ok "message still says NEEDS HUMAN (human-readable urgency preserved, even though it's no longer load-bearing for notify's own classifier)"
    else
      bad "ga-wxwao: NEEDS HUMAN text lost from the escalation message"
    fi
  else
    bad "nao achei o bloco still-unhealthy no fonte — drift-guard nao rodou"
  fi
else
  bad "nao achei o script ao lado — asserts do ga-wxwao nao rodaram"
fi

echo
echo "dolt-hang-watchdog selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
