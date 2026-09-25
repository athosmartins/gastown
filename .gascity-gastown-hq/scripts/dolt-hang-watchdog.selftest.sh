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

# (b) checagem estatica de cobertura: os 5 pontos de mutacao conhecidos (recuperacao
# saudavel, saturacao, escrita de strike, veto/restart, ga-xyhl9d PID-change forensic
# capture) tem de estar TODOS atras do mesmo helper — nao 4 de 5, que foi exatamente
# o estado que passou pelo attempt 1 quando era 3 de 4.
if [ -f "$SRC" ]; then
  _gate_count=$(grep -cE '^[[:space:]]*if is_dry_run' "$SRC")
  [ "$_gate_count" -eq 5 ] && ok "5/5 pontos de mutacao conhecidos usam is_dry_run (nenhum novo ficou de fora)" \
                            || bad "regressao: esperava 5 call-sites de 'if is_dry_run', achei ${_gate_count} — algum ramo de mutacao ficou sem gate"
fi

# ── ga-xyhl9d (sling ga-oyw1tw): PID-change/death forensic snapshot.
#
# The 2026-09-25 00:26:43 Dolt death left this file with NOTHING to show for
# it: the separate process-keeper respawned Dolt in ~14s, well inside this
# watchdog's own ~60-90s cadence, so probe_ok() only ever saw a healthy (if
# different) server and cleared state as normal. Mayor's decision on ga-xyhl9d
# (2026-09-25 04:01, option b): track the last-seen PID across invocations and
# capture a read-only forensic snapshot the instant it changes or disappears.
#
# Tested with DOLT_WATCHDOG_PID_OVERRIDE (same seam as DOLT_WATCHDOG_CPU_PID
# above) so a PID change can be simulated across invocations without a real
# Dolt process, entirely isolated, and a fake `gc` on PATH so probe_ok()
# resolves deterministically and the run exits via the ordinary healthy path
# right after check_pid_change().
#
# HERMETIC BY CONSTRUCTION (gate ga-u9utfa, blocking issue 2 -- the same class as
# ga-153cq gate attempts 2 and 3 in this very file): the healthy branch of the script
# runs `rm -f` on $STRIKES and $CPU_VETO_FILE. Invoked without overriding both, every
# run here deleted the REAL watchdog's live counters at /tmp/dolt-hang-watchdog.*,
# resetting the consecutive-strike progress of a genuinely failing Dolt. Listing the
# two overrides at each call site is how six call sites forgot them, so there is now
# exactly ONE way to run the script in this block -- _wd() -- and it always sets every
# scratch path (LOG, STRIKES, CPU_VETO, LASTPID, DEATH_LOG_DIR). Extra env goes in as
# arguments. Nothing in this block may call `bash "$SRC"` any other way.
#
# The fake `log` is installed FROM THE START, not only where a case needs to control
# it: the real `log show` takes ~10-20s per call under load (this file took 2 minutes
# and every case depended on what the host's unified log happened to contain). ──
echo
echo "ga-xyhl9d: PID-change forensic snapshot (check_pid_change / capture_death_snapshot)"
if [ -f "$SRC" ]; then
  _tmpd4=$(mktemp -d)
  mkdir -p "$_tmpd4/bin" "$_tmpd4/deathlogs"
  cat > "$_tmpd4/bin/gc" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "dolt" ] && [ "${2:-}" = "health" ]; then
  echo '{"server":{"reachable":true}}'
  exit 0
fi
exit 1
FAKE
  chmod +x "$_tmpd4/bin/gc"

  # Fake `log`: answers the two windows the snapshot asks for. FAKE_LOG_MODE drives the
  # forensic window (--last 3m), FAKE_BURST_MODE the burst-count window (--last 1m).
  # Default (both unset) is a quiet host: no events, exit 0. The `_hdr` line is the
  # column header the REAL `log show` prints even for a zero-event window (measured).
  cat > "$_tmpd4/bin/log" <<'FAKE'
#!/usr/bin/env bash
_ev()  { echo "2026-09-25 00:26:43.000000-0300 0x1 Default 0x0 1 0 kernel: $1;"; }
_hdr() { echo "Timestamp                       Thread     Type        Activity             PID    TTL  "; }
case "$*" in
  *"--last 3m"*)
    case "${FAKE_LOG_MODE:-}" in
      many)  i=0; while [ "$i" -lt 1500 ]; do _ev "seq=$i"; i=$((i+1)); done ;;
      slow)  echo "partial-line-before-timeout"; exec sleep 5 ;;
      few)   _ev "seq=0" ;;
      fail3) echo "log: Bad predicate (Unable to parse the format string \"x\"): x" >&2; exit 64 ;;
    esac ;;
  *"--last 1m"*)
    case "${FAKE_BURST_MODE:-}" in
      burst) _hdr; i=0; while [ "$i" -lt 7 ]; do _ev "Retrieve User by ID $i"; i=$((i+1)); done ;;
      zero)  _hdr ;;
      slow)  _hdr; exec sleep 5 ;;
      fail)  echo "log: Bad predicate (Unable to parse the format string \"x\"): x" >&2; exit 64 ;;
    esac ;;
esac
exit 0
FAKE
  chmod +x "$_tmpd4/bin/log"

  _lastpid="$_tmpd4/lastpid"
  _deaths="$_tmpd4/deathlogs"
  _count_deaths() { find "$_deaths" -maxdepth 1 -name 'dolt-death-*.txt' 2>/dev/null | wc -l | tr -d ' '; }
  _newest_snap()  { find "$_deaths" -maxdepth 1 -name 'dolt-death-*.txt' 2>/dev/null | head -1; }
  # THE one way to run the script in this block. See the HERMETIC note above.
  _wd() {
    env PATH="$_tmpd4/bin:$PATH" DOLT_WATCHDOG_LOG="$_tmpd4/l" \
        DOLT_WATCHDOG_STRIKES_FILE="$_tmpd4/s" DOLT_WATCHDOG_CPU_VETO_FILE="$_tmpd4/v" \
        DOLT_WATCHDOG_LASTPID_FILE="$_lastpid" DOLT_WATCHDOG_DEATH_LOG_DIR="$_deaths" \
        "$@" bash "$SRC" >/dev/null 2>&1
  }

  # (1) First-ever observation: no baseline on disk -> no snapshot, baseline established.
  #     Also the POSITIVE CONTROL for hermeticity: seed scratch strikes/veto, and require
  #     that the healthy branch consumed THESE. If _wd stopped pointing the script at the
  #     scratch paths, it would consume (or miss) the real /tmp files instead and these
  #     scratch files would survive.
  echo 2 > "$_tmpd4/s"; echo 3 > "$_tmpd4/v"
  _wd DOLT_WATCHDOG_PID_OVERRIDE=1111
  [ "$(_count_deaths)" = "0" ] && ok "first observation (no baseline) -> no snapshot fired" \
                               || bad "first observation should not fire a snapshot -- $(_count_deaths) file(s) found"
  [ "$(cat "$_lastpid" 2>/dev/null)" = "1111" ] && ok "first observation establishes baseline (lastpid=1111)" \
                               || bad "baseline not established after first observation: $(cat "$_lastpid" 2>/dev/null)"
  if [ ! -e "$_tmpd4/s" ] && [ ! -e "$_tmpd4/v" ] && grep -q 'Dolt healthy again .* clearing 2 strike' "$_tmpd4/l" 2>/dev/null; then
    ok "hermetic: the healthy branch consumed the SCRATCH strikes/veto (seeded 2/3), never the real /tmp counters"
  else
    bad "ga-u9utfa regressao: scratch strikes/veto were not the ones the script touched -- _wd no longer isolates the live watchdog counters"
  fi

  # (2) Same PID observed again -> still no snapshot, baseline unchanged.
  _wd DOLT_WATCHDOG_PID_OVERRIDE=1111
  [ "$(_count_deaths)" = "0" ] && ok "unchanged PID (1111 -> 1111) -> no snapshot fired" \
                               || bad "unchanged PID should not fire a snapshot -- $(_count_deaths) file(s) found"

  # (3) PID CHANGES (1111 -> 2222) -> exactly one snapshot, baseline advances.
  _wd DOLT_WATCHDOG_PID_OVERRIDE=2222
  [ "$(_count_deaths)" = "1" ] && ok "PID changed (1111 -> 2222) -> exactly one snapshot fired" \
                               || bad "PID change should fire exactly one snapshot -- found $(_count_deaths)"
  [ "$(cat "$_lastpid" 2>/dev/null)" = "2222" ] && ok "baseline advanced to new PID (2222)" \
                               || bad "baseline did not advance: $(cat "$_lastpid" 2>/dev/null)"
  _snap1="$(_newest_snap)"
  if [ -n "$_snap1" ] && grep -q 'previous_pid: 1111' "$_snap1" && grep -q 'current_pid:  2222' "$_snap1"; then
    ok "snapshot file records old and new PID correctly"
  else
    bad "snapshot file missing or does not record previous/current PID as expected: ${_snap1:-<none>}"
  fi
  [ -n "$_snap1" ] && [ "$(tail -1 "$_snap1")" = "=== end of snapshot ===" ] \
    && ok "snapshot ends with its end-mark (the file is whole)" \
    || bad "ga-u9utfa: snapshot has no end-mark as its last line -- completeness cannot be checked"
  grep -q 'Dolt PID CHANGED (1111 -> 2222)' "$_tmpd4/l" 2>/dev/null \
    && ok "watchdog log records the PID-change event" \
    || bad "watchdog log missing the PID-change event line"
  grep -q 'forensic snapshot captured:' "$_tmpd4/l" 2>/dev/null \
    && ok "a whole snapshot is logged as captured" \
    || bad "a successful capture was not logged as captured"

  # (4) PID DISAPPEARS -> a second snapshot, baseline cleared. The previous PID must be
  #     really DEAD now (a child we started and reaped): an empty lookup with a still-alive
  #     previous PID is a different case, (4b). Fake PIDs like 2222 would make this depend
  #     on whether the host happens to have a process with that number.
  sleep 0 & _deadpid=$!; wait "$_deadpid" 2>/dev/null
  if kill -0 "$_deadpid" 2>/dev/null; then
    bad "test precondition: reaped PID ${_deadpid} still answers kill -0 -- disappearance case not exercised"
  else
    echo "$_deadpid" > "$_lastpid"
    _wd DOLT_WATCHDOG_PID_OVERRIDE=
    [ "$(_count_deaths)" = "2" ] && ok "PID disappeared (dead ${_deadpid} -> none) -> a second snapshot fired" \
                                 || bad "PID disappearance should fire a snapshot -- found $(_count_deaths), expected 2"
    [ -f "$_lastpid" ] && bad "lastpid file should be removed once the PID disappears, but it still exists" \
                       || ok "lastpid file removed once the PID disappears"
  fi

  # (4b) Resolver returns EMPTY but the previous PID is still ALIVE. dolt_server_pid's own
  #      contract says empty = UNKNOWN (its lsof/ps verification can miss a live server under
  #      saturation), so this must NOT be logged as a death: no snapshot, baseline kept -- and
  #      the payoff, a real death+respawn on the NEXT run is still caught because the
  #      baseline survived (before: baseline deleted -> that change was invisible).
  sleep 60 & _livepid=$!
  echo "$_livepid" > "$_lastpid"
  _before="$(_count_deaths)"
  : > "$_tmpd4/l"
  _wd DOLT_WATCHDOG_PID_OVERRIDE=
  [ "$(_count_deaths)" = "$_before" ] && ok "empty lookup + previous PID alive -> UNKNOWN, no snapshot fired" \
                                      || bad "ga-xyhl9d: an EMPTY (unknown) lookup with a live previous PID fired a snapshot as if Dolt had died"
  [ "$(cat "$_lastpid" 2>/dev/null)" = "$_livepid" ] && ok "baseline KEPT through the unknown lookup (still ${_livepid})" \
                                                     || bad "ga-xyhl9d: unknown lookup deleted/changed the baseline ($(cat "$_lastpid" 2>/dev/null))"
  grep -q 'treating as UNKNOWN' "$_tmpd4/l" 2>/dev/null \
    && ok "the unknown lookup is SAID in the log (not silent)" \
    || bad "ga-xyhl9d: unknown lookup left no line in the log"
  _wd DOLT_WATCHDOG_PID_OVERRIDE=8888
  _snap4b="$(grep -l 'current_pid:  8888' "$_deaths"/dolt-death-*.txt 2>/dev/null | head -1)"
  if [ "$(_count_deaths)" = "$((_before + 1))" ] && [ -n "$_snap4b" ] && grep -q "previous_pid: ${_livepid}" "$_snap4b"; then
    ok "a real change right after the unknown run (${_livepid} -> 8888) is still caught"
  else
    bad "ga-xyhl9d: the change after an unknown lookup was lost (deaths=$(_count_deaths), expected $((_before + 1)))"
  fi
  kill "$_livepid" 2>/dev/null; wait "$_livepid" 2>/dev/null

  # (5) DRY_RUN must not create a snapshot file or advance the real baseline,
  #     but must still report what it WOULD have done (same promise as every
  #     other mutation site in this file).
  _before="$(_count_deaths)"
  echo 3333 > "$_lastpid"
  _wd DOLT_WATCHDOG_PID_OVERRIDE=4444 DOLT_WATCHDOG_DRY_RUN=1
  [ "$(_count_deaths)" = "$_before" ] && ok "DRY-RUN PID change -> no new snapshot written (still ${_before})" \
                                      || bad "DRY-RUN should not write a snapshot -- found $(_count_deaths), expected ${_before}"
  [ "$(cat "$_lastpid" 2>/dev/null)" = "3333" ] && ok "DRY-RUN does not advance the real lastpid baseline (still 3333)" \
                               || bad "ga-xyhl9d regressao: DRY-RUN mutated the real lastpid file ($(cat "$_lastpid" 2>/dev/null))"
  grep -q 'DRY-RUN: Dolt PID changed (3333 -> 4444)' "$_tmpd4/l" 2>/dev/null \
    && ok "DRY-RUN reports the PID-change branch it would have taken (not silent)" \
    || bad "DRY-RUN did not report the simulated PID change"

  # (6) The snapshot must be BOUNDED. Measured 2026-09-25: `ps -ef | grep -i dolt`
  #     matched every `claude` agent session (its whole system prompt, which says
  #     "dolt", sits in argv: ~100 KB per line) and one snapshot came out 1.1 MB,
  #     90% of it that section, burying the dolt/supervisor rows. A fake `ps -ef`
  #     reproduces that shape; any other `ps` call falls through to the real one so
  #     the rest of the script is unaffected. FAKE_PS_MODE: `empty` = ps produced
  #     nothing, `rows` = 130 dolt-matching rows (over the 120-row cap).
  cat > "$_tmpd4/bin/ps" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "-ef" ]; then
  case "${FAKE_PS_MODE:-}" in
    empty) exit 1 ;;
    rows)
      echo "  UID   PID  PPID   C STIME   TTY           TIME CMD"
      i=0; while [ "$i" -lt 130 ]; do echo "  501 5${i} 1 0 8:00AM ?? 0:00.00 dolt worker $i"; i=$((i+1)); done
      exit 0 ;;
  esac
  echo "  UID   PID  PPID   C STIME   TTY           TIME CMD"
  echo "  501 63228     1   0  8:00AM ??         1:00.00 /opt/homebrew/bin/dolt sql-server --config /x/dolt-config.yaml"
  for _i in 1 2 3; do
    printf '  501 4110%s 25378   0  8:11AM ttys008    0:34.05 claude --append-system-prompt ' "$_i"
    head -c 100000 /dev/zero | tr '\0' 'x'
    echo " ... mentions dolt ..."
  done
  exit 0
fi
exec /bin/ps "$@"
FAKE
  chmod +x "$_tmpd4/bin/ps"
  rm -f "$_deaths"/dolt-death-*.txt
  echo 5555 > "$_lastpid"
  _wd DOLT_WATCHDOG_PID_OVERRIDE=6666
  _snap6="$(_newest_snap)"
  if [ -n "$_snap6" ]; then
    _ps6="$(awk '/^--- ps:/{f=1;next} /^--- /{f=0} f' "$_snap6")"
    printf '%s' "$_ps6" | grep -q 'dolt sql-server --config /x/dolt-config.yaml' \
      && ok "bounded ps section still shows the real dolt sql-server row" \
      || bad "ga-xyhl9d: ps section lost the dolt sql-server row"
    _psmax="$(printf '%s\n' "$_ps6" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
    [ "$_psmax" -le 240 ] && ok "ps section lines are capped (longest ${_psmax} chars, 3 x 100 KB argv fed in)" \
                          || bad "ga-xyhl9d regressao: ps section has a ${_psmax}-char line -- unbounded argv leaked into the snapshot"
    _allmax="$(awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$_snap6")"
    [ "$_allmax" -le 1000 ] && ok "no line anywhere in the snapshot exceeds 1000 chars (longest ${_allmax})" \
                            || bad "ga-xyhl9d regressao: snapshot has a ${_allmax}-char line -- some section embeds unbounded external text"
  else
    bad "ga-xyhl9d: bounded-snapshot case produced no snapshot file"
  fi

  # (6b) The ps section states its own cap and its own failure -- the log section already
  #      does; a `head -120` with no note (or an empty section when `ps` itself failed) reads
  #      as "these are all the rows" / "no dolt process".
  _runps() {  # $1 = FAKE_PS_MODE; leaves the newest snapshot path in $_snapps
    rm -f "$_deaths"/dolt-death-*.txt; echo 6000 > "$_lastpid"
    _wd FAKE_PS_MODE="$1" DOLT_WATCHDOG_PID_OVERRIDE=6001
    _snapps="$(_newest_snap)"
  }
  _runps rows
  if [ -n "$_snapps" ]; then
    grep -q 'TRUNCATED: showing the first 120 of 131 ps rows -- 11 were dropped' "$_snapps" \
      && ok "ps rows over the cap -> snapshot states the truncation (first 120 of 131)" \
      || bad "ga-xyhl9d: ps rows truncated 131 -> 120 with NO note in the snapshot"
  else bad "ga-xyhl9d: ps-cap case produced no snapshot file"; fi
  _runps empty
  if [ -n "$_snapps" ]; then
    grep -q 'ps returned NO rows -- the process tree is UNKNOWN' "$_snapps" \
      && ok "ps produced nothing -> snapshot says the tree is UNKNOWN (not an empty section)" \
      || bad "ga-xyhl9d: ps failure left an empty section indistinguishable from 'no dolt process'"
  else bad "ga-xyhl9d: ps-failure case produced no snapshot file"; fi

  # (7) Truncation and timeout of the `log show` window must be STATED in the file,
  #     not silent. Measured 2026-09-25: under memory pressure jetsam/memorystatus lines
  #     alone filled the 1000-line cap and `tail` dropped the oldest ~47s of the 3-minute
  #     window -- the part that would hold the moment of death -- with nothing in the file
  #     saying so.
  _run7() {  # $1 = FAKE_LOG_MODE, $2 = extra env words (or empty); leaves the newest snapshot path in $_snap7
    rm -f "$_deaths"/dolt-death-*.txt; echo 7000 > "$_lastpid"
    _wd FAKE_LOG_MODE="$1" $2 DOLT_WATCHDOG_PID_OVERRIDE=7001
    _snap7="$(_newest_snap)"
  }

  _run7 many ""
  if [ -n "$_snap7" ]; then
    grep -q 'TRUNCATED: showing the newest 1000 of 1500 matching lines -- the oldest 500 were dropped' "$_snap7" \
      && ok "log window over the cap -> snapshot states the truncation (newest 1000 of 1500)" \
      || bad "ga-xyhl9d: log window truncated 1500 -> 1000 with NO note in the snapshot (silent truncation)"
    grep -q 'seq=1499;' "$_snap7" && ! grep -q 'seq=0;' "$_snap7" \
      && ok "truncation keeps the newest lines and drops the oldest (seq=1499 kept, seq=0 dropped)" \
      || bad "ga-xyhl9d: truncation did not keep newest/drop oldest as documented"
  else bad "ga-xyhl9d: truncation case produced no snapshot file"; fi

  _run7 few ""
  if [ -n "$_snap7" ]; then
    { ! grep -q 'TRUNCATED' "$_snap7" && ! grep -q 'TIMED OUT' "$_snap7" && ! grep -q 'FAILED rc=' "$_snap7" && ! grep -q 'UNAVAILABLE' "$_snap7"; } \
      && ok "small window -> no truncation / timeout / failure / unavailable note (markers are not unconditional)" \
      || bad "ga-xyhl9d: a healthy 1-line window carried a TRUNCATED/TIMED OUT/FAILED/UNAVAILABLE note -- the markers fire unconditionally"
  else bad "ga-xyhl9d: control case produced no snapshot file"; fi

  _run7 slow "DOLT_WATCHDOG_SNAP_LOG_TIMEOUT=1"
  if [ -n "$_snap7" ]; then
    grep -q 'log show TIMED OUT after 1s' "$_snap7" \
      && ok "log show timeout -> snapshot says the window is PARTIAL (not silent)" \
      || bad "ga-xyhl9d: log show timed out with NO note in the snapshot (silent partial window)"
  else bad "ga-xyhl9d: timeout case produced no snapshot file"; fi

  # (7b) A `log show` that FAILS (not times out) prints an error message; without a note it
  #      sat in the window section looking like log events (gate ga-u9utfa: instance fixed
  #      for the timeout, class not swept). Real `log show` exits 64 on a bad predicate.
  _run7 fail3 ""
  if [ -n "$_snap7" ]; then
    grep -q 'log show FAILED rc=64' "$_snap7" \
      && ok "log show failure (rc=64) -> the forensic window says its lines are an ERROR, not events" \
      || bad "ga-u9utfa: a failed log show (rc=64) left its error text in the window with no note"
  else bad "ga-u9utfa: log-failure case produced no snapshot file"; fi

  # (8) The burst count (ga-oyw1tw hypothesis evidence) must never be a NUMBER when the
  #     query did not answer. Measured against the real `log show`: a zero-event window
  #     prints the column header (a bare `grep -c .` said 1), a bad predicate prints one
  #     error line and exits 64 (said 1), a timeout-killed query printed 0, and N real
  #     events said N+1 -- so "no burst" and "could not look" were the same number.
  _run7 few "FAKE_BURST_MODE=burst"
  if [ -n "$_snap7" ]; then
    grep -qx 'count: 7' "$_snap7" \
      && ok "burst: 7 events (+ column header) -> count: 7 (header not counted)" \
      || bad "ga-u9utfa: 7 real events + header did not yield 'count: 7' -- got: $(grep -m1 '^count:' "$_snap7")"
  else bad "ga-u9utfa: burst case produced no snapshot file"; fi

  _run7 few "FAKE_BURST_MODE=zero"
  if [ -n "$_snap7" ]; then
    grep -qx 'count: 0' "$_snap7" \
      && ok "zero-event window (header only) -> count: 0 (was 1: the header counted as an event)" \
      || bad "ga-u9utfa: a zero-event window did not yield 'count: 0' -- got: $(grep -m1 '^count:' "$_snap7")"
  else bad "ga-u9utfa: zero-window case produced no snapshot file"; fi

  _run7 few "FAKE_BURST_MODE=slow DOLT_WATCHDOG_SNAP_BURST_TIMEOUT=1"
  if [ -n "$_snap7" ]; then
    { grep -q 'count: UNAVAILABLE (log show TIMED OUT after 1s' "$_snap7" && ! grep -qE '^count: [0-9]' "$_snap7"; } \
      && ok "burst query timed out -> count: UNAVAILABLE (never a number that reads as 'no burst')" \
      || bad "ga-u9utfa: a timed-out burst query did not say UNAVAILABLE -- got: $(grep -m1 '^count:' "$_snap7")"
  else bad "ga-u9utfa: burst-timeout case produced no snapshot file"; fi

  _run7 few "FAKE_BURST_MODE=fail"
  if [ -n "$_snap7" ]; then
    { grep -q 'count: UNAVAILABLE (log show FAILED rc=64' "$_snap7" && ! grep -qE '^count: [0-9]' "$_snap7"; } \
      && ok "burst query failed (rc=64) -> count: UNAVAILABLE (the error line is not counted as an event)" \
      || bad "ga-u9utfa: a failed burst query did not say UNAVAILABLE -- got: $(grep -m1 '^count:' "$_snap7")"
  else bad "ga-u9utfa: burst-failure case produced no snapshot file"; fi

  # (9) "captured" must mean WHOLE. The disk has already run out of space once; a snapshot
  #     that cannot be written used to be logged as "forensic snapshot captured: <path>" for a
  #     file that did not exist. DEATH_LOG_DIR under a regular FILE makes mkdir and the
  #     redirect fail deterministically without needing a full disk.
  : > "$_tmpd4/afile"
  echo 9000 > "$_lastpid"
  : > "$_tmpd4/l"
  _wd DOLT_WATCHDOG_PID_OVERRIDE=9001 DOLT_WATCHDOG_DEATH_LOG_DIR="$_tmpd4/afile/sub"
  { grep -q 'forensic snapshot capture FAILED or INCOMPLETE' "$_tmpd4/l" && ! grep -q 'forensic snapshot captured:' "$_tmpd4/l"; } \
    && ok "snapshot that could not be written -> logged as FAILED, never as captured" \
    || bad "ga-u9utfa: an unwritable snapshot dir was still logged as 'captured' (log: $(tr '\n' '|' < "$_tmpd4/l" | cut -c1-200))"
  [ "$(cat "$_lastpid" 2>/dev/null)" = "9001" ] \
    && ok "baseline still advances when the snapshot fails (no re-fire every run)" \
    || bad "ga-u9utfa: baseline did not advance after a failed snapshot ($(cat "$_lastpid" 2>/dev/null))"

  rm -rf "$_tmpd4"
else
  bad "nao achei o script ao lado — asserts de PID-change nao rodaram"
fi

# ── ga-wxwao (case 2): the post-restart "still unhealthy" branch must call the
# canonical escalate_emergency() path (--class town-halted), not the raw ad-hoc
# `notify -p 5` it used to (which only ever reached push because its message
# happened to contain "NEEDS HUMAN", matching notify's own content classifier —
# a silent, wording-dependent fragility). Static check, not dynamic: reaching
# this branch by actually running the script means surviving the SAME
# kill -QUIT + restart machinery the gate-FAIL 2/3 blocks above work so hard to
# avoid — and here dolt_server_pid() (ga-0bjqix) would correctly find THIS
# HOST'S REAL PRODUCTION Dolt process, not a scratch fixture (no
# STRIKES/veto-file-style override exists for PID resolution at the kill
# site). There is
# no safe way to dynamically exercise this specific branch. The function being
# called (escalate_emergency.py) has its own independent --selftest (17/0 as of
# this fix) — this file's job is only to prove the RIGHT call, with the RIGHT
# class, replaced the old raw notify, not to re-verify escalate_emergency()'s
# own internals. ──
echo "ga-wxwao: post-restart still-unhealthy branch calls escalate_emergency (--class town-halted), not raw notify"
if [ -f "$SRC" ]; then
  _still_unhealthy_block=$(sed -n '/WARN: Dolt STILL unhealthy after restart/,/^fi$/p' "$SRC")
  if [ -n "$_still_unhealthy_block" ]; then
    if printf '%s' "$_still_unhealthy_block" | grep 'escalate_emergency\.py' >/dev/null; then
      ok "still-unhealthy branch calls escalate_emergency.py"
    else
      bad "ga-wxwao regressao: still-unhealthy branch nao chama mais escalate_emergency.py"
    fi
    if printf '%s' "$_still_unhealthy_block" | grep -- '--class town-halted' >/dev/null; then
      ok "escalate_emergency call uses --class town-halted (correct sanctioned class)"
    else
      bad "ga-wxwao regressao: escalate_emergency call nao usa --class town-halted"
    fi
    if printf '%s' "$_still_unhealthy_block" | grep -E "notify[[:space:]]+-p[[:space:]]+5[[:space:]]+-t[[:space:]]+'Dolt hang-watchdog'" >/dev/null; then
      bad "ga-wxwao regressao: ramo still-unhealthy AINDA chama notify -p 5 direto — dupla notificacao (escalate_emergency ja chama notify internamente)"
    else
      ok "raw ad-hoc 'notify -p 5' call removed from still-unhealthy branch (no double-notify)"
    fi
    if printf '%s' "$_still_unhealthy_block" | grep "NEEDS HUMAN" >/dev/null; then
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
