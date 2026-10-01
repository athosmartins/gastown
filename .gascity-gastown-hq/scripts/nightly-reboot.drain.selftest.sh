#!/usr/bin/env bash
# nightly-reboot.drain.selftest.sh — selftest do MODO DRENO do reboot noturno (ga-a2v0bz).
#
# O bug: o reboot noturno pulou 13 noites seguidas. O guard 3 ("hq beads
# in_progress") nunca zerava porque a cidade nunca para de trabalhar de
# madrugada, e o guard 4 (scraper das 00:01) cobria o resto. O desenho novo:
# o daemon dispara as 23:00 (modo dreno), grava o sinal de dreno que os
# despachantes leem, espera ate 23:40 e reinicia. Trabalho de agente em curso
# NAO segura mais o reboot — so os guards de SEGURANCA seguram (envio em voo,
# manutencao de Dolt), esperando ate 23:55.
#
# SEGURANCA — leia antes de mexer: o gate rejoga este arquivo contra o commit
# BASE (o script antigo), que tem `/sbin/shutdown -r now` FIXO, sem gancho de
# teste. Por isso todo cenario de dreno roda com a hora pinada em 23 — o script
# antigo sai no Guard 1 ("fora da janela 01:00-01:19") e NUNCA chega ao shutdown.
# O unico cenario com hora 1 mantem o guard hq bloqueando pra sempre (um
# construtor vivo, fresco), como o selftest original: nenhuma versao chega ao
# reboot. NAO adicione aqui um cenario hora=1 com todos os guards liberados.
#
# O que se prova (a classe, nao so o exemplo):
#   E1  o cenario do bug: guards 2/3/4 todos BLOQUEARIAM (gate com marker real,
#       construtor vivo, scraper rodando) -> as 23:40 o reboot sai mesmo assim
#   E2  o dreno e gravado ANTES de qualquer guard, com o boot-epoch real, e
#       e re-carimbado durante a espera
#   E3  guards de seguranca seguram: envio em voo / nao-sei / script ausente /
#       Dolt em manutencao -> SKIP depois do orcamento, sinal REMOVIDO (a cidade
#       volta a trabalhar), streak incrementa. "Nao consegui olhar" nao e "livre".
#   E4  o que passaria a ser morto fica registrado: log + snapshot pre-reboot
#   E5  scraper cortado: contador de noites seguidas, aviso so a partir da 2a
#   E6  arquivo de pendencia pro pos-boot; janela do Guard 1 (23:00-23:19 dreno,
#       01:00-01:19 legado, o resto SKIP sem tocar em nada)
#   E7  morte no meio da espera (SIGTERM) nao deixa a cidade drenada
#   E8  o calculo de "quantos segundos ate 23:40" (funcao pura, extraida)
#   E9  bd/Dolt PENDURADO (gate-fix 1): as chamadas "informativas" tem prazo —
#       o reboot sai mesmo assim, o log diz "TIMED OUT (unknown)", nada fica vivo
#   E10 SIGTERM com o script BLOQUEADO numa chamada bd: morre na hora e solta o dreno
#   E11 a espera ate 23:40 e decidida pelo RELOGIO: um sleep que volta cedo nao a encurta
#   E12 o padrao de manutencao do Dolt (guard de seguranca) contra o pgrep REAL,
#       com processos de mentira (positivos E negativos)
#   E13 shutdown que falha apaga a pendencia; shutdown que "pega" a mantem — e o log nao mente em nenhum dos dois
#   E14 o contador de scraper cortado so move perto do shutdown; mail pendurado tem prazo
#   E15 a noite PULADA tambem tem prazo: gc pendurado no registro do skip nao prende a instancia
#   E16 gate-fix 2: os guards de SEGURANCA sao lidos de novo logo antes do shutdown — um envio que
#       comecou no intervalo segura o reboot (e uma noite pulada ali NAO zera o streak)
#   E17 o ROTEAMENTO: o notify de verdade (NOTIFY_ROUTE_TEST=1) diz onde cai cada aviso. O padrao do
#       notify e o digest SILENCIOSO; so o aviso de alarme (noite pulada, N noites seguidas) vai com
#       NOTIFY_FORCE_PUSH, o aviso de rotina nao. (Nas rodadas E3/E15 tambem.)
#
# CARGA: este arquivo roda no gate, numa maquina com load 56-88. Nenhuma asserção pode depender de
# um orcamento de tempo "folgado o bastante": onde o resultado depende do relogio, ou o cenario da
# folga de verdade (E9: orcamento 40s para ~10s de uso) ou ele e montado para dar o MESMO resultado
# com qualquer carga (E9c: orcamento == prazo da sonda; E9d: so o bd do rig pendura).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/nightly-reboot.sh"
PASS=0; FAIL=0; SKIPPED=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
# skipped: uma checagem que NAO PODE rodar aqui (nao e passe, nem falha) — dita em voz alta
skipped() { echo "  - SKIP $*"; SKIPPED=$((SKIPPED+1)); }
# o notify de verdade, usado so em modo NOTIFY_ROUTE_TEST (nao envia nada): diz onde cairia cada aviso
REAL_NOTIFY="${NIGHTLY_REBOOT_SELFTEST_REAL_NOTIFY:-/Users/athos/.local/bin/notify}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── PATH de mentira: date (hora pinada) e sudo (sem escalar) ────────────────
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/date" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  +%-H) echo "${FAKE_HOUR:-23}" ;;
  +%-M) echo "${FAKE_MIN:-5}" ;;
  *) exec /bin/date "$@" ;;
esac
EOF
cat > "$FAKEBIN/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-u" ] && shift 2
exec "$@"
EOF
# sleep que pode "voltar cedo" (FAKE_SLEEP_EARLY=1): o que um sleep que nao consegue
# dar fork faz num host em load 60-88 — o E11 prova que isso nao encurta a espera
cat > "$FAKEBIN/sleep" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_SLEEP_EARLY:-}" ] && exit 0
exec /bin/sleep "$@"
EOF
chmod +x "$FAKEBIN/date" "$FAKEBIN/sudo" "$FAKEBIN/sleep"

real_boot_epoch() {
  /usr/sbin/sysctl -n kern.boottime | awk '{for (i = 1; i <= NF; i++) if ($i == "sec") { v = $(i+2); gsub(/[^0-9]/, "", v); print v; exit } }'
}
REAL_BOOT="$(real_boot_epoch)"

# ── world: um diretorio novo por cenario, com todos os fakes ────────────────
# Variaveis de ambiente do cenario (todas opcionais, default = "tudo livre"):
#   W_GATE_REAL    markers reais do gate            (default 0)
#   W_HQ_BUSY      1 = um construtor vivo, fresco    (default 0)
#   W_SCRAPER      1 = rodada do scraper em andamento(default 0)
#   W_SENDER_RC    rc do fake de envio em voo        (default 0; "missing" = sem o script)
#   W_SENDER_OK_AT 1-based: a chamada em que o fake passa a devolver 0 (default: nunca muda)
#   W_PGREP_RC     rc do fake de pgrep               (default 1 = nada rodando)
#   W_BD_HANG      1 = todo `bd` pendura (Dolt wedged): grava o pid e dorme 600s  (default 0)
#   W_GC_HANG      1 = todo `gc` pendura                                          (default 0)
#   W_BD_HANG_RIG  1 = so o `bd -C <rig>` pendura (o do HQ responde): garante que a sonda por rig RODA
#   W_SENDER_SEQ   "0 1 0" = rc do fake de envio por NUMERO DA CHAMADA (a ultima repete)
#   W_RIG          1 = cria um rig com .beads em $CITY, pro laco de contagem por rig (default 0)
#   W_SHUTDOWN_RC  rc do fake de shutdown            (default 0)
new_world() {
  W="$TMP/$1"; rm -rf "$W"; mkdir -p "$W/city/.gc/logs" "$W/city/scripts" "$W/rodada" "$W/run"
  CITY="$W/city"; LOGF="$CITY/.gc/logs/nightly-reboot.log"
  STREAK="$CITY/.gc/logs/nightly-reboot.streak"
  DRAIN="$W/run/city-drain.level"; PENDING="$CITY/.gc/logs/nightly-reboot.pending"
  SHUT="$W/shutdown.calls"; DRAIN_AT_SHUT="$W/drain-at-shutdown"; PEND_AT_SHUT="$W/pending-at-shutdown"
  DRAIN_AT_SENDER="$W/drain-at-sender"; GC_CALLS="$W/gc.calls"; NOTIFY_CALLS="$W/notify.calls"
  NOTIFY_FORCE="$W/notify.force"; NOTIFY_ROUTES="$W/notify.routes"
  : > "$SHUT"; : > "$GC_CALLS"; : > "$NOTIFY_CALLS"; : > "$NOTIFY_FORCE"; : > "$NOTIFY_ROUTES"
  [ "${W_RIG:-0}" = "1" ] && mkdir -p "$CITY/rigx/.beads"

  cat > "$CITY/scripts/gate-queue-composition.sh" <<EOF
#!/usr/bin/env bash
echo '{"total":${W_GATE_REAL:-0},"real":${W_GATE_REAL:-0},"phantom":0,"unknown":0}'
EOF
  cat > "$W/bd" <<EOF
#!/usr/bin/env bash
if [ "${W_BD_HANG:-0}" = "1" ]; then echo \$\$ >> "$W/bd.pids"; exec /bin/sleep 600; fi
if [ "${W_BD_HANG_RIG:-0}" = "1" ] && [ "\$1" = "-C" ] && [ "\$2" != "$CITY" ]; then echo \$\$ >> "$W/bd.pids"; exec /bin/sleep 600; fi
case "\$3" in
  list)
    if [ "${W_HQ_BUSY:-0}" = "1" ]; then
      printf '[{"id":"fake-inprogress-1","assignee":"fake-builder","updated_at":"%s"}]\n' "\$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    else echo '[]'; fi ;;
  query)
    echo '[{"id":"ga-fake-sess","issue_type":"session","status":"open","metadata":{"session_name":"fake-builder","alias":"fake-builder","template":"wa-worker","state":"awake"}}]' ;;
esac
EOF
  cat > "$W/gc" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GC_CALLS"
if [ "${W_GC_HANG:-0}" = "1" ]; then echo \$\$ >> "$W/gc.pids"; exec /bin/sleep 600; fi
EOF
  # grava (1) os argumentos, (2) se o aviso veio com NOTIFY_FORCE_PUSH, (3) pra onde o notify DE VERDADE
  # mandaria esta chamada exata (NOTIFY_ROUTE_TEST=1: nao envia nada; herda o NOTIFY_FORCE_PUSH do script)
  cat > "$W/notify" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_CALLS"
echo "force=\${NOTIFY_FORCE_PUSH:-} :: \$*" >> "$NOTIFY_FORCE"
if [ -x "$REAL_NOTIFY" ]; then r="\$(NOTIFY_ROUTE_TEST=1 "$REAL_NOTIFY" "\$@" 2>/dev/null | head -1)"; [ -n "\$r" ] || r="unreadable"; else r="n/a"; fi
echo "\$r :: \$*" >> "$NOTIFY_ROUTES"
EOF
  cat > "$W/shutdown" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SHUT"
cp "$DRAIN" "$DRAIN_AT_SHUT" 2>/dev/null
cp "$PENDING" "$PEND_AT_SHUT" 2>/dev/null
cp "$CITY/.gc/logs/nightly-reboot.scraper-cut.streak" "$W/cut-at-shutdown" 2>/dev/null
exit ${W_SHUTDOWN_RC:-0}
EOF
  cat > "$W/softwareupdate" <<'EOF'
#!/usr/bin/env bash
echo "No new software available."; exit 0
EOF
  # fake do guard de envio em voo (central_sender_restart_safe.py): exit 0/1/2
  SENDER="$W/sender_safe.py"; SENDER_N="$W/sender.calls"; : > "$SENDER_N"
  if [ "${W_SENDER_RC:-0}" != "missing" ]; then
    cat > "$SENDER" <<EOF
#!/usr/bin/env python3
import os, sys
n = len(open("$SENDER_N").read().split()) + 1
open("$SENDER_N", "a").write("x\n")
if n == 1 and os.path.exists("$DRAIN"):
    open("$DRAIN_AT_SENDER", "w").write("present")
seq = "${W_SENDER_SEQ:-}".split()
if seq:
    sys.exit(int(seq[min(n, len(seq)) - 1]))
ok_at = int("${W_SENDER_OK_AT:-0}")
if ok_at and n >= ok_at:
    sys.exit(0)
sys.exit(int("${W_SENDER_RC:-0}"))
EOF
  fi
  cat > "$W/pgrep" <<EOF
#!/usr/bin/env bash
[ "${W_PGREP_RC:-1}" = "0" ] && echo "4242 bash /x/dolt-compact-routine.sh"
exit ${W_PGREP_RC:-1}
EOF
  chmod +x "$CITY/scripts/gate-queue-composition.sh" "$W/bd" "$W/gc" "$W/notify" "$W/shutdown" "$W/softwareupdate" "$W/pgrep"
  # rodada do scraper: marker "running" apontando pra um pid vivo (este shell)
  if [ "${W_SCRAPER:-0}" = "1" ]; then
    printf '{"status":"running","pid":%s,"started_at":"%s","rodada_id":"rod-test","phase":"scraping"}\n' \
      "$$" "$(/bin/date '+%Y-%m-%dT%H:%M:%S')" > "$W/rodada/rod-test.json"
  fi
}

# nr_env: o ambiente do script de verdade (tudo faked, hora pinada). Num array pra que
# run_nr e start_nr_bg nunca divirjam.
nr_env() {
  NRENV=( PATH="$FAKEBIN:$PATH" CITY="$CITY" GC_BIN="$W/gc" BD_BIN="$W/bd" NOTIFY_BIN="$W/notify" NOTIFY_AS_USER="$USER"
          SHUTDOWN_BIN="$W/shutdown" SOFTWAREUPDATE_BIN="$W/softwareupdate" SCRAPER_RODADA_DIR="$W/rodada"
          NIGHTLY_REBOOT_DRAIN_FILE="$DRAIN" NIGHTLY_REBOOT_DRAIN_WAIT_SECS=0
          NIGHTLY_REBOOT_SAFETY_RETRY_INTERVAL=0 NIGHTLY_REBOOT_SAFETY_MAX_ATTEMPTS=3
          NIGHTLY_REBOOT_SENDER_SAFE_PY="$SENDER" NIGHTLY_REBOOT_PGREP_BIN="$W/pgrep"
          NIGHTLY_REBOOT_RETRY_INTERVAL=0 NIGHTLY_REBOOT_RETRY_MAX_ATTEMPTS=2 )
}
# run_nr [VAR=val ...] — roda o script de verdade, tudo faked e a hora pinada. Tem um limite
# de tempo (NR_LIMIT, default 120s): um script que PENDURA reprova o cenario em vez de
# pendurar a suite inteira — e e exatamente o defeito que o E9/E10 existem pra pegar.
# NR_TIMED_OUT=1 depois de um estouro.
run_nr() {
  nr_env
  NR_TIMED_OUT=0
  env "${NRENV[@]}" "$@" /bin/bash "$SCRIPT" > "$W/stdout" 2> "$W/stderr" &
  local pid=$! ticks=0 max=$(( ${NR_LIMIT:-120} * 4 ))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max" ]; then
      kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; NR_TIMED_OUT=1; return 124
    fi
    /bin/sleep 0.25; ticks=$((ticks+1))
  done
  wait "$pid"
}
# start_nr_bg [VAR=val ...] — mesmo ambiente, em background; o pid fica em NRPID.
start_nr_bg() {
  nr_env
  env "${NRENV[@]}" "$@" /bin/bash "$SCRIPT" > "$W/stdout" 2> "$W/stderr" &
  NRPID=$!
}
# pids_alive <arquivo de pids>: quantos dos pids gravados ainda estao vivos
pids_alive() {
  local f="$1" p n=0
  [ -f "$f" ] || { echo 0; return; }
  for p in $(cat "$f"); do kill -0 "$p" 2>/dev/null && n=$((n+1)); done
  echo "$n"
}
kill_pids() { local p; [ -f "$1" ] && for p in $(cat "$1"); do kill -KILL "$p" 2>/dev/null; done; return 0; }
rebooted()   { [ -s "$SHUT" ] && grep -q -- '-r now' "$SHUT"; }
log_has()    { grep -q -E -- "$1" "$LOGF" 2>/dev/null; }
# force_of <trecho do aviso>: "1" se o script mandou com NOTIFY_FORCE_PUSH, "" se nao, "NONE" se nao mandou
force_of() { local l; l="$(grep -F -- "$1" "$NOTIFY_FORCE" 2>/dev/null | head -1)"; [ -n "$l" ] || { echo NONE; return; }; l="${l#force=}"; echo "${l%% ::*}"; }
# route_of <trecho do aviso>: o que o notify de verdade respondeu ("push ...", "digest", "n/a", "NONE")
route_of() { local l; l="$(grep -F -- "$1" "$NOTIFY_ROUTES" 2>/dev/null | head -1)"; [ -n "$l" ] || { echo NONE; return; }; echo "${l%% ::*}"; }
# assert_push <rotulo> <trecho>: o aviso foi mandado COM o override E o notify de verdade o poe no push.
# Sem o notify de verdade aqui, so a metade do override e provada — e dito.
assert_push() {
  local label="$1" frag="$2" f r
  f="$(force_of "$frag")"; r="$(route_of "$frag")"
  case "$f" in
    NONE) bad "$label: o aviso '$frag' nem foi mandado. chamadas: $(tr '\n' '|' < "$NOTIFY_CALLS" 2>/dev/null)"; return ;;
    1) ok "$label: mandado com NOTIFY_FORCE_PUSH" ;;
    *) bad "$label: mandado SEM NOTIFY_FORCE_PUSH — cai no digest silencioso" ;;
  esac
  case "$r" in
    push*) ok "$label: o notify de verdade o poe no PUSH ($r)" ;;
    n/a) skipped "$label: notify de verdade ausente em $REAL_NOTIFY — so o override foi provado, nao a rota" ;;
    *) bad "$label: o notify de verdade o poe em '$r' — o aviso nao chega" ;;
  esac
}

# ═══ E1: o cenario do bug ════════════════════════════════════════════════════
echo "E1: gate com marker real + construtor vivo + scraper rodando -> as 23:40 reinicia assim mesmo"
W_GATE_REAL=2 W_HQ_BUSY=1 W_SCRAPER=1 new_world e1
printf '13\n' > "$STREAK"      # 13 noites puladas: a noite boa tem que zerar
run_nr FAKE_HOUR=23
if rebooted; then ok "E1 reboot emitido (shutdown -r now) com os 3 guards de trabalho bloqueando"; else bad "E1 NAO reiniciou — o bug das 13 noites continua. log: $(tail -3 "$LOGF" 2>/dev/null | tr '\n' '|')"; fi
[ "$(grep -c -- '-r now' "$SHUT")" = "1" ] && ok "E1 exatamente 1 shutdown" || bad "E1 numero de shutdowns != 1"
log_has "drain mode" && ok "E1 o log fala do dreno" || bad "E1 o log nao menciona o dreno"
[ "$(cat "$STREAK" 2>/dev/null)" = "0" ] && ok "E1 streak 13 -> 0 (a noite que reinicia zera o alarme)" || bad "E1 streak deveria zerar, veio '$(cat "$STREAK" 2>/dev/null)'"
[ "$(force_of "Reiniciando")" = "" ] && ok "E1 o aviso de ROTINA ('Reiniciando...') nao e forcado — fica no digest, de proposito" || bad "E1 o aviso de rotina saiu com NOTIFY_FORCE_PUSH='$(force_of "Reiniciando")' (NONE = nem foi mandado)"

# ═══ E2: o sinal de dreno ════════════════════════════════════════════════════
echo "E2: dreno gravado antes dos guards, com boot-epoch real, e re-carimbado"
new_world e2
run_nr FAKE_HOUR=23
[ -f "$DRAIN_AT_SENDER" ] && ok "E2 o sinal ja existia quando o 1o guard de seguranca rodou" || bad "E2 o sinal NAO existia antes do guard (dreno tem que vir primeiro)"
if [ -f "$DRAIN_AT_SHUT" ]; then
  S="$(sed -n 1p "$DRAIN_AT_SHUT")"; WR="$(sed -n 2p "$DRAIN_AT_SHUT")"; BT="$(sed -n 3p "$DRAIN_AT_SHUT")"; UN="$(sed -n 4p "$DRAIN_AT_SHUT")"
  [ "$S" = "DRAIN" ] && ok "E2 linha 1 = DRAIN" || bad "E2 linha 1 deveria ser DRAIN, veio '$S'"
  [ "$BT" = "$REAL_BOOT" ] && ok "E2 boot-epoch = kern.boottime real ($BT)" || bad "E2 boot-epoch deveria ser $REAL_BOOT, veio '$BT'"
  NOWE=$(/bin/date +%s)
  [ "$UN" -gt "$NOWE" ] 2>/dev/null && ok "E2 teto (until) no futuro" || bad "E2 until deveria estar no futuro: '$UN'"
else
  bad "E2 sinal ausente no momento do shutdown (cp falhou)"
fi
# re-carimbo: espera de 3s com carimbo a cada 1s
new_world e2b
T0=$(/bin/date +%s)
run_nr FAKE_HOUR=23 NIGHTLY_REBOOT_DRAIN_WAIT_SECS=3 NIGHTLY_REBOOT_DRAIN_STAMP_INTERVAL=1
WR2="$(sed -n 2p "$DRAIN_AT_SHUT" 2>/dev/null)"
[ -n "$WR2" ] && [ "$WR2" -ge $(( T0 + 2 )) ] && ok "E2 sinal re-carimbado durante a espera (gravado em T0+$((WR2-T0))s)" || bad "E2 sinal nao foi re-carimbado (gravado='$WR2' T0=$T0)"

# ═══ E3: guards de seguranca seguram ═════════════════════════════════════════
echo "E3: envio em voo / nao-sei / script ausente / Dolt em manutencao -> SKIP e solta a cidade"
# run_e3 <nome> <rc do envio> <rc do pgrep>: um guard de seguranca bloqueando, tudo o mais livre
run_e3() {
  local name="$1" srcrc="$2" pgrc="$3" why="$4" res
  W_SENDER_RC="$srcrc" W_PGREP_RC="$pgrc" new_world "e3-$name"
  run_nr FAKE_HOUR=23
  # prova POSITIVA de que o fluxo de dreno rodou e foi o guard de seguranca que segurou — sem isto, "nao reiniciou"
  # passaria igual no script antigo, que so sai no Guard 1 (fora da janela) sem nunca avaliar nada
  log_has "SKIP: safety guards still blocked" && ok "E3 $name: SKIP veio do guard de SEGURANCA (nao da janela)" || bad "E3 $name: o SKIP nao foi do guard de seguranca"
  log_has "$why" && ok "E3 $name: o log traz a razao do guard ('$why')" || bad "E3 $name: o log nao traz a razao '$why'"
  res="$(rebooted && echo REBOOTED || echo none)|$([ -f "$DRAIN" ] && echo flag || echo noflag)|$(cat "$STREAK" 2>/dev/null)"
  [ "${res%%|*}" = "none" ] && ok "E3 $name: NAO reiniciou" || bad "E3 $name: reiniciou com guard de seguranca bloqueando ($res)"
  case "$res" in *"|noflag|"*) ok "E3 $name: sinal de dreno REMOVIDO (cidade solta)" ;; *) bad "E3 $name: sinal de dreno ficou no disco ($res)" ;; esac
  case "$res" in *"|1") ok "E3 $name: streak = 1" ;; *) bad "E3 $name: streak deveria ser 1 ($res)" ;; esac
  log_has "SKIP" && ok "E3 $name: SKIP registrado" || bad "E3 $name: sem SKIP no log"
  assert_push "E3 $name: aviso de noite pulada" "Reboot noturno pulado"
}
run_e3 sender-em-voo 1 1 "central_sender"
run_e3 sender-nao-sei 2 1 "unknown treated as NOT safe"
run_e3 sender-ausente missing 1 "not readable"
run_e3 dolt-manutencao 0 0 "Dolt maintenance"
run_e3 pgrep-falha 0 2 "unknown treated as NOT safe"
# tentativa N: o envio libera na 2a chamada -> reinicia, e o log conta a tentativa
W_SENDER_RC=1 W_SENDER_OK_AT=2 new_world e3c; run_nr FAKE_HOUR=23
LOGF="$W/city/.gc/logs/nightly-reboot.log"
rebooted && ok "E3 envio libera na 2a tentativa -> reinicia" || bad "E3 deveria reiniciar quando o envio libera"
grep -q "attempt 1" "$LOGF" && ok "E3 a tentativa bloqueada ficou no log" || bad "E3 sem registro da tentativa bloqueada"

# ═══ E4: o que sera morto fica registrado ════════════════════════════════════
echo "E4: guards 2/3/4 viram INFORMATIVOS — log + snapshot pre-reboot"
W_GATE_REAL=2 W_HQ_BUSY=1 W_SCRAPER=1 new_world e4; run_nr FAKE_HOUR=23
grep -q "informational.*gate-markers" "$LOGF" && ok "E4 log: gate-markers informativo" || bad "E4 log sem guard2 informativo"
grep -q "informational.*hq-in-progress" "$LOGF" && ok "E4 log: hq-in-progress informativo" || bad "E4 log sem guard3 informativo"
grep -q "informational.*scraper-daily" "$LOGF" && ok "E4 log: scraper-daily informativo" || bad "E4 log sem guard4 informativo"
SNAP="$(ls "$CITY"/.gc/logs/nightly-reboot-pre-*.txt 2>/dev/null | head -1)"
if [ -n "$SNAP" ]; then
  grep -q "fake-inprogress-1" "$SNAP" && ok "E4 snapshot cita o bead que sera morto e retomado" || bad "E4 snapshot nao cita o bead em voo"
  grep -q "rod-test" "$SNAP" && ok "E4 snapshot cita a rodada do scraper que sera cortada" || bad "E4 snapshot nao cita a rodada"
else
  bad "E4 snapshot nightly-reboot-pre-*.txt nao foi gerado"
fi
grep -q "macOS update" "$LOGF" && ok "E4 o passo de update do macOS continua no fluxo" || bad "E4 o passo de update do macOS sumiu do fluxo"

# ═══ E5: scraper cortado ═════════════════════════════════════════════════════
echo "E5: scraper cortado -> contador de noites; aviso so a partir da 2a seguida"
W_SCRAPER=1 new_world e5; run_nr FAKE_HOUR=23
SC="$CITY/.gc/logs/nightly-reboot.scraper-cut.streak"
[ "$(cat "$SC" 2>/dev/null)" = "1" ] && ok "E5 1a noite cortada: contador = 1" || bad "E5 contador deveria ser 1 ('$(cat "$SC" 2>/dev/null)')"
grep -q "mail send" "$GC_CALLS" && bad "E5 avisou ja na 1a noite (so a partir da 2a)" || ok "E5 sem aviso na 1a noite"
# 2a noite seguida: pre-semeia o contador em 1
W_SCRAPER=1 new_world e5b; printf '1\n' > "$CITY/.gc/logs/nightly-reboot.scraper-cut.streak"; run_nr FAKE_HOUR=23
[ "$(cat "$CITY/.gc/logs/nightly-reboot.scraper-cut.streak" 2>/dev/null)" = "2" ] && ok "E5 2a noite: contador = 2" || bad "E5 contador deveria ser 2"
grep -q "mail send" "$GC_CALLS" && ok "E5 2a noite seguida: avisa (mail)" || bad "E5 2a noite seguida deveria avisar"
# noite sem scraper rodando zera
new_world e5c; printf '2\n' > "$CITY/.gc/logs/nightly-reboot.scraper-cut.streak"; run_nr FAKE_HOUR=23
[ "$(cat "$CITY/.gc/logs/nightly-reboot.scraper-cut.streak" 2>/dev/null)" = "0" ] && ok "E5 noite sem corte zera o contador" || bad "E5 contador deveria zerar"

# ═══ E6: pendencia pro pos-boot e janela do Guard 1 ══════════════════════════
echo "E6: arquivo de pendencia + janelas do Guard 1"
new_world e6; run_nr FAKE_HOUR=23
if [ -f "$PEND_AT_SHUT" ]; then
  grep -q '^mode=drain' "$PEND_AT_SHUT" && ok "E6 pendencia: mode=drain" || bad "E6 pendencia sem mode=drain"
  grep -q "^boot_before=$REAL_BOOT" "$PEND_AT_SHUT" && ok "E6 pendencia: boot_before = boot real" || bad "E6 pendencia sem boot_before correto"
  grep -q '^issued=[0-9]\{10\}' "$PEND_AT_SHUT" && ok "E6 pendencia: issued=<epoch>" || bad "E6 pendencia sem issued"
else
  bad "E6 pendencia ausente quando o shutdown foi chamado (precisa existir ANTES)"
fi
for hm in "2:5" "23:25" "12:0"; do
  h="${hm%%:*}"; m="${hm##*:}"
  new_world "e6-$h-$m"; run_nr FAKE_HOUR=$h FAKE_MIN=$m
  if ! rebooted && [ ! -f "$DRAIN" ] && grep -q "SKIP" "$LOGF"; then ok "E6 ${h}:$(printf '%02d' $m) fora da janela -> SKIP sem sinal e sem reboot"; else bad "E6 ${h}:$(printf '%02d' $m) deveria SKIP sem tocar em nada"; fi
done
# janela legada 01:00: com um construtor vivo SEMPRE bloqueando (seguro p/ qualquer versao do script)
W_HQ_BUSY=1 new_world e6leg; run_nr FAKE_HOUR=1 FAKE_MIN=5
! rebooted && grep -q "SKIP" "$LOGF" && ok "E6 01:05 (legado) com construtor vivo -> fail-closed preservado" || bad "E6 legado 01:05 deveria bloquear e SKIP"
[ ! -f "$DRAIN" ] && ok "E6 legado nao grava sinal de dreno" || bad "E6 o fluxo legado NAO pode gravar dreno"

# ═══ E7: morte no meio da espera ═════════════════════════════════════════════
echo "E7: SIGTERM no meio da espera nao deixa a cidade drenada"
new_world e7
env PATH="$FAKEBIN:$PATH" CITY="$CITY" GC_BIN="$W/gc" BD_BIN="$W/bd" NOTIFY_BIN="$W/notify" NOTIFY_AS_USER="$USER" \
    SHUTDOWN_BIN="$W/shutdown" SOFTWAREUPDATE_BIN="$W/softwareupdate" SCRAPER_RODADA_DIR="$W/rodada" \
    NIGHTLY_REBOOT_DRAIN_FILE="$DRAIN" NIGHTLY_REBOOT_DRAIN_WAIT_SECS=60 NIGHTLY_REBOOT_DRAIN_STAMP_INTERVAL=60 \
    NIGHTLY_REBOOT_SENDER_SAFE_PY="$SENDER" NIGHTLY_REBOOT_PGREP_BIN="$W/pgrep" FAKE_HOUR=23 \
    /bin/bash "$SCRIPT" > "$W/stdout" 2> "$W/stderr" &
NRPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -f "$DRAIN" ] && break; sleep 0.25; done
if [ -f "$DRAIN" ]; then
  ok "E7 sinal gravado durante a espera"
  kill -TERM "$NRPID" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do kill -0 "$NRPID" 2>/dev/null || break; sleep 0.25; done
  kill -0 "$NRPID" 2>/dev/null && { bad "E7 o script nao morreu com SIGTERM"; kill -KILL "$NRPID" 2>/dev/null; } || ok "E7 o script morreu com SIGTERM"
  [ ! -f "$DRAIN" ] && ok "E7 sinal REMOVIDO na morte (cidade solta na hora, nao so em 30min)" || bad "E7 o sinal ficou no disco depois do SIGTERM"
  ! rebooted && ok "E7 morrer na espera nao reinicia" || bad "E7 reiniciou apesar do SIGTERM"
else
  # sem espera real nao ha o que provar: um script que sai na hora "passaria" tudo isto por vacuidade
  bad "E7 inconclusivo: o sinal nunca apareceu, entao nao houve espera pra interromper"
  kill -KILL "$NRPID" 2>/dev/null
fi
wait "$NRPID" 2>/dev/null

# ═══ E8: calculo do horario (funcao pura, extraida por sentinela) ════════════
echo "E8: segundos ate HH:MM (funcao pura)"
BLOCK="$(sed -n '/nightly-reboot.drain.selftest.sh:DRAIN-SCHEDULE-START/,/nightly-reboot.drain.selftest.sh:DRAIN-SCHEDULE-END/p' "$SCRIPT")"
if [ -z "$BLOCK" ]; then
  bad "E8 bloco DRAIN-SCHEDULE-START/END ausente em nightly-reboot.sh"
else
  at() { /bin/date -j -f '%Y-%m-%d %H:%M:%S' "2026-10-01 $1" +%s; }
  secs() { ( eval "$BLOCK"; secs_until_hhmm "$1" "$2" ); }
  [ "$(secs 23:40 "$(at 23:00:00)")" = "2400" ] && ok "E8 23:00:00 -> 2400s ate 23:40" || bad "E8 23:00:00 deveria dar 2400, deu '$(secs 23:40 "$(at 23:00:00)")'"
  [ "$(secs 23:40 "$(at 23:39:30)")" = "30" ] && ok "E8 23:39:30 -> 30s" || bad "E8 23:39:30 deveria dar 30"
  [ "$(secs 23:40 "$(at 23:41:00)")" = "0" ] && ok "E8 depois do alvo -> 0 (nunca negativo)" || bad "E8 depois do alvo deveria dar 0"
  [ "$(secs 23:40 "$(at 23:40:00)")" = "0" ] && ok "E8 exatamente no alvo -> 0" || bad "E8 no alvo deveria dar 0"
  [ "$(secs lixo "$(at 23:00:00)")" = "ERR" ] && ok "E8 HH:MM invalido -> ERR (nao 0: nao colapsa erro em 'ja e hora')" || bad "E8 HH:MM invalido deveria dar ERR, deu '$(secs lixo "$(at 23:00:00)")'"
fi

# ═══ E9: bd/Dolt pendurado ═══════════════════════════════════════════════════
# O defeito (gate-fix 1): no modo dreno os guards de seguranca nunca tocam o bd, entao o
# PRIMEIRO contato com ele era uma chamada "informativa" sem prazo. Dolt wedged = o script
# ficava parado pra sempre, com a ultima linha do log dizendo "rebooting" — e o launchd
# nao dispara a proxima noite enquanto esta instancia "roda". Os fakes de bd responderem
# na hora (E1/E4) escondia isto: aqui o bd PENDURA.
echo "E9: bd pendurado (Dolt wedged) -> as chamadas informativas tem prazo e o reboot sai assim mesmo"
# Orcamento de 40s para ~10s de uso (sonda de 2s): a folga e REAL mesmo em load 60-90. A versao anterior
# dava 6s ao orcamento; em load 58 so os guards 2/3/4 ja o gastavam, a linha do laco por rig saia
# "NOT ATTEMPTED" e o teste reportava "laco sem prazo" — o script estava certo, o TESTE dependia da carga
# (gate FAIL 2/3). Por isso a linha do rig aceita TIMED OUT ou NOT ATTEMPTED aqui (o que nao pode e
# faltar, nem pendurar); os dois estados exatos tem cenario proprio, montado pra nao depender da carga:
# E9c (NOT ATTEMPTED) e E9d (TIMED OUT).
W_BD_HANG=1 W_RIG=1 new_world e9
T0=$(/bin/date +%s)
NR_LIMIT=90 run_nr FAKE_HOUR=23 NIGHTLY_REBOOT_INFO_PROBE_TIMEOUT_SECS=2 NIGHTLY_REBOOT_INFO_BUDGET_SECS=40
T1=$(/bin/date +%s)
[ "${NR_TIMED_OUT:-0}" = "0" ] && ok "E9 o script terminou sozinho em $((T1-T0))s (nao pendurou)" || bad "E9 o script PENDUROU ate o limite de 90s — com Dolt wedged o reboot nunca sai. ultimo log: $(tail -1 "$LOGF" 2>/dev/null)"
rebooted && ok "E9 reboot emitido (shutdown -r now) com o bd pendurado" || bad "E9 NAO reiniciou com o bd pendurado. ultimo log: $(tail -2 "$LOGF" 2>/dev/null | tr '\n' '|')"
[ $((T1-T0)) -le 60 ] && ok "E9 dentro do limite (${T0}->${T1} = $((T1-T0))s <= 60s; sem prazo seriam 600s)" || bad "E9 demorou $((T1-T0))s"
log_has "safety guards OK" && ok "E9 os guards de seguranca decidiram (nao foi o bd)" || bad "E9 sem 'safety guards OK' no log"
log_has "informational: guard3 hq-in-progress: unknown TIMED OUT" && ok "E9 guard3 (usa bd): 'unknown TIMED OUT' no log — nem 'ok', nem silencio" || bad "E9 guard3 sem a linha TIMED OUT. informational: $(grep 'informational' "$LOGF" 2>/dev/null | tr '\n' '|')"
log_has "informational: guard2 gate-markers: ok" && ok "E9 guard2 (o gate respondeu): continua 'ok' — os tres estados nao colapsam" || bad "E9 guard2 deveria dizer ok, o gate respondeu"
log_has "other rigs' in_progress counts (TIMED OUT|NOT ATTEMPTED)" && ok "E9 o laco de contagem por rig diz o que aconteceu (TIMED OUT ou NOT ATTEMPTED) — nao some e nao pendura" || bad "E9 laco por rig mudo. info: $(grep 'info:' "$LOGF" 2>/dev/null | tr '\n' '|')"
SNAP="$(ls "$CITY"/.gc/logs/nightly-reboot-pre-*.txt 2>/dev/null | head -1)"
if [ -n "$SNAP" ]; then grep -q "TIMED OUT" "$SNAP" && ok "E9 o snapshot registra que NAO deu pra ler (unknown), em vez de omitir" || bad "E9 snapshot sem a linha TIMED OUT"; else bad "E9 snapshot nao gerado"; fi
[ ! -f "$DRAIN" ] && ok "E9 sinal de dreno removido no fim" || bad "E9 sinal de dreno ficou no disco"
[ "$(pids_alive "$W/bd.pids")" = "0" ] && ok "E9 nenhum bd pendurado sobrou vivo (a arvore inteira foi morta no prazo)" || bad "E9 sobraram $(pids_alive "$W/bd.pids") bd pendurados vivos"
kill_pids "$W/bd.pids"

# E9c: orcamento == prazo da sonda e todo bd pendura. A 1a sonda que toca o bd gasta o orcamento INTEIRO
# (o prazo dela e min(sonda, o que resta) e ela so volta quando o relogio chega la), entao o que vem
# depois nao cabe — com QUALQUER carga: carga so atrasa o relogio, nunca o adianta.
echo "E9c: orcamento informativo esgotado -> o que nao coube e dito 'NOT ATTEMPTED' (unknown), nunca omitido"
W_BD_HANG=1 W_RIG=1 new_world e9c
NR_LIMIT=90 run_nr FAKE_HOUR=23 NIGHTLY_REBOOT_INFO_PROBE_TIMEOUT_SECS=2 NIGHTLY_REBOOT_INFO_BUDGET_SECS=2
[ "${NR_TIMED_OUT:-0}" = "0" ] && ok "E9c o script terminou sozinho" || bad "E9c o script pendurou"
rebooted && ok "E9c reboot emitido mesmo com o orcamento esgotado" || bad "E9c NAO reiniciou. ultimo log: $(tail -2 "$LOGF" 2>/dev/null | tr '\n' '|')"
log_has "informational: guard3 hq-in-progress: unknown (TIMED OUT|NOT ATTEMPTED)" && ok "E9c guard3 (usa bd): unknown, com o motivo" || bad "E9c guard3 sem motivo. informational: $(grep 'informational' "$LOGF" 2>/dev/null | tr '\n' '|')"
log_has "informational: guard4 scraper-daily: unknown NOT ATTEMPTED" && ok "E9c guard4: 'unknown NOT ATTEMPTED' — o orcamento acabou antes dele, e o log diz" || bad "E9c guard4 nao diz NOT ATTEMPTED. informational: $(grep 'informational' "$LOGF" 2>/dev/null | tr '\n' '|')"
log_has "other rigs' in_progress counts NOT ATTEMPTED" && ok "E9c contagem por rig: 'NOT ATTEMPTED' no log" || bad "E9c contagem por rig sem NOT ATTEMPTED. info: $(grep 'info:' "$LOGF" 2>/dev/null | tr '\n' '|')"
[ "$(pids_alive "$W/bd.pids")" = "0" ] && ok "E9c nenhum bd pendurado sobrou vivo" || bad "E9c sobraram bd pendurados vivos"
kill_pids "$W/bd.pids"

# E9d: so o `bd -C <rig>` pendura; o do HQ responde. A sonda por rig RODA (ha folga de sobra no orcamento)
# e estoura o prazo: este e o cenario que prova o prazo do laco por rig sem depender de sorte.
echo "E9d: so o bd do RIG pendura -> a sonda por rig roda e estoura o prazo (TIMED OUT)"
W_BD_HANG_RIG=1 W_RIG=1 new_world e9d
NR_LIMIT=90 run_nr FAKE_HOUR=23 NIGHTLY_REBOOT_INFO_PROBE_TIMEOUT_SECS=2 NIGHTLY_REBOOT_INFO_BUDGET_SECS=40
[ "${NR_TIMED_OUT:-0}" = "0" ] && ok "E9d o script terminou sozinho" || bad "E9d o script pendurou no bd do rig"
rebooted && ok "E9d reboot emitido com o bd do rig pendurado" || bad "E9d NAO reiniciou. ultimo log: $(tail -2 "$LOGF" 2>/dev/null | tr '\n' '|')"
log_has "informational: guard3 hq-in-progress: ok" && ok "E9d o bd do HQ respondeu: guard3 'ok' (so o rig esta mudo)" || bad "E9d guard3 deveria dizer ok. informational: $(grep 'informational' "$LOGF" 2>/dev/null | tr '\n' '|')"
log_has "other rigs' in_progress counts TIMED OUT after 2s" && ok "E9d o laco por rig RODOU e estourou o prazo de 2s (TIMED OUT no log)" || bad "E9d laco por rig sem TIMED OUT. info: $(grep 'info:' "$LOGF" 2>/dev/null | tr '\n' '|')"
[ "$(pids_alive "$W/bd.pids")" = "0" ] && ok "E9d o bd do rig pendurado foi morto no prazo" || bad "E9d sobraram bd do rig vivos"
kill_pids "$W/bd.pids"

# ═══ E10: SIGTERM bloqueado numa chamada ═════════════════════════════════════
# Efeito secundario do mesmo defeito: bash adia o trap enquanto um filho em primeiro plano
# nao volta, entao o E7 ("a morte solta a cidade") so valia DENTRO do drain_sleep.
echo "E10: SIGTERM com o script parado numa chamada bd -> morre na hora, solta o dreno, nao deixa o bd"
W_BD_HANG=1 W_RIG=1 new_world e10
start_nr_bg FAKE_HOUR=23 NIGHTLY_REBOOT_INFO_PROBE_TIMEOUT_SECS=60 NIGHTLY_REBOOT_INFO_BUDGET_SECS=120
for _ in $(seq 1 80); do [ -s "$W/bd.pids" ] && break; /bin/sleep 0.25; done
if [ -s "$W/bd.pids" ]; then
  ok "E10 o script esta parado dentro de uma chamada bd"
  [ -f "$DRAIN" ] && ok "E10 o dreno esta no disco (a morte vai ter o que soltar)" || bad "E10 sem dreno no disco: o cenario nao prova nada"
  kill -TERM "$NRPID" 2>/dev/null
  for _ in $(seq 1 24); do kill -0 "$NRPID" 2>/dev/null || break; /bin/sleep 0.25; done
  if kill -0 "$NRPID" 2>/dev/null; then bad "E10 o script NAO morreu em 6s com SIGTERM (o trap ficou adiado atras da chamada)"; kill -KILL "$NRPID" 2>/dev/null; else ok "E10 o script morreu com SIGTERM em <6s"; fi
  [ ! -f "$DRAIN" ] && ok "E10 sinal de dreno REMOVIDO na morte" || bad "E10 o dreno ficou no disco depois do SIGTERM"
  for _ in 1 2 3 4 5 6 7 8; do [ "$(pids_alive "$W/bd.pids")" = "0" ] && break; /bin/sleep 0.25; done
  [ "$(pids_alive "$W/bd.pids")" = "0" ] && ok "E10 o bd pendurado morreu junto" || bad "E10 o bd pendurado sobreviveu ao script ($(pids_alive "$W/bd.pids") vivos)"
  ! rebooted && ok "E10 morrer na chamada nao reinicia" || bad "E10 reiniciou apesar do SIGTERM"
else
  bad "E10 inconclusivo: o bd nunca foi chamado, nao ha chamada bloqueada pra interromper"
  kill -KILL "$NRPID" 2>/dev/null
fi
wait "$NRPID" 2>/dev/null
kill_pids "$W/bd.pids"

# ═══ E11: a espera e do RELOGIO ══════════════════════════════════════════════
# A espera de 40min era um contador regressivo do que PEDIMOS pra dormir. Se o sleep nao
# consegue dar fork (host em load 60-88) ou volta cedo, o contador zera e os guards
# rodam as ~23:00 com a cidade mal drenada. O relogio manda; o contador e so o plano B.
echo "E11: um sleep que volta cedo nao encurta a espera (decide o relogio de parede)"
new_world e11
NR_LIMIT=120 run_nr FAKE_HOUR=23 FAKE_SLEEP_EARLY=1 NIGHTLY_REBOOT_DRAIN_WAIT_SECS=10
# Mede a ESPERA em si, pelos carimbos do proprio log (da linha "drain: waiting" ate o
# "safety guards OK"), e nao o tempo total: num host em load 70 o script antigo gasta ~10s
# so em forks lentos, e um limite de tempo total passava por acaso (medido ao provar este
# teste contra o script antigo). Sem STAMP_INTERVAL curto, o laco antigo e UMA volta so.
log_ts() { /bin/date -j -f '%Y-%m-%d %H:%M:%S' "$(grep -m1 -- "$1" "$LOGF" 2>/dev/null | sed -n 's/^\[\([^]]*\)\].*/\1/p')" +%s 2>/dev/null; }
TW="$(log_ts 'drain: waiting')"; TG="$(log_ts 'safety guards OK')"
rebooted && ok "E11 o reboot saiu" || bad "E11 nao reiniciou. ultimo log: $(tail -2 "$LOGF" 2>/dev/null | tr '\n' '|')"
case "$TW$TG" in ''|*[!0-9]*) bad "E11 inconclusivo: faltou 'drain: waiting' ou 'safety guards OK' no log (TW='$TW' TG='$TG')" ;;
  *) [ $((TG-TW)) -ge 10 ] && ok "E11 a espera durou >= 10s de RELOGIO ($((TG-TW))s) apesar de todo sleep voltar na hora" || bad "E11 a espera encolheu pra $((TG-TW))s (pedido: 10s): o contador de sleeps decidiu, nao o relogio" ;;
esac

# ═══ E12: o padrao de manutencao do Dolt, contra o pgrep REAL ════════════════════
# O guard de seguranca "Dolt em manutencao" usa um regex. O E3 troca o pgrep por um fake
# que devolve rc 0/1/2 SEM olhar o padrao — entao um regex quebrado (pgrep rc=2 => "nao sei
# => NAO e seguro" => SKIP toda noite) ou com falso-negativo passaria a suite inteira.
# Aqui o padrao e extraido do script e passa pelo pgrep do sistema, contra processos de mentira.
echo "E12: padrao DOLT_MAINT_PATTERN contra o pgrep real (positivos e negativos)"
PBLOCK="$(sed -n '/nightly-reboot.drain.selftest.sh:DOLT-MAINT-PATTERN-START/,/nightly-reboot.drain.selftest.sh:DOLT-MAINT-PATTERN-END/p' "$SCRIPT")"
if [ -z "$PBLOCK" ]; then
  bad "E12 bloco DOLT-MAINT-PATTERN-START/END ausente em nightly-reboot.sh"
else
  eval "$PBLOCK"
  PAT="${DOLT_MAINT_PATTERN_DEFAULT:-}"
  [ -n "$PAT" ] && ok "E12 padrao extraido do script" || bad "E12 DOLT_MAINT_PATTERN_DEFAULT vazio depois de extrair"
  /usr/bin/pgrep -f "$PAT" >/dev/null 2>&1; PRC=$?
  [ "$PRC" = "0" ] || [ "$PRC" = "1" ] && ok "E12 o pgrep real ACEITA o padrao (rc=$PRC, nao 2): o guard nao fica 'nao sei' toda noite" || bad "E12 o pgrep real rejeitou o padrao (rc=$PRC) — o guard viraria 'unknown => NAO e seguro' toda noite"
  MD="$TMP/maint"; mkdir -p "$MD"
  for n in dolt-compact-routine dolt-gc-maintenance dolt-gc-release-trigger dolt-backup-reseed dolt-backup-swap-repair dolt-backup-residue-reclaim dolt-offline-backup-sync; do
    printf '#!/bin/bash\n/bin/sleep 25\n' > "$MD/$n.sh"; chmod +x "$MD/$n.sh"
  done
  SPAWNED=""
  # spawn <nome> <esperado no argv> <cmd...>: sobe o processo de mentira e espera o argv final aparecer
  spawn() {
    local name="$1" want="$2" pid i; shift 2
    "$@" >/dev/null 2>&1 &
    pid=$!
    SPAWNED="$SPAWNED $pid"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
      /bin/ps -o command= -p "$pid" 2>/dev/null | grep -q -- "$want" && break
      /bin/sleep 0.25
    done
    eval "PID_$name=$pid"
  }
  spawn explicit   "dolt-compact-routine.sh"      /bin/bash "$MD/dolt-compact-routine.sh"
  spawn shebang    "dolt-gc-maintenance.sh"       "$MD/dolt-gc-maintenance.sh"
  spawn envbash    "dolt-gc-release-trigger.sh"   env bash "$MD/dolt-gc-release-trigger.sh"
  spawn nice       "dolt-backup-reseed.sh"        nice -n 5 /bin/bash "$MD/dolt-backup-reseed.sh"
  spawn doltgc     "dolt gc"                      /bin/bash -c 'exec -a "dolt gc" /bin/sleep 25'
  spawn mention    "dolt-compact-routine.sh"      /bin/bash -c '/bin/sleep 25' dolt-compact-routine.sh
  spawn sqlserver  "dolt sql-server"              /bin/bash -c 'exec -a "dolt sql-server" /bin/sleep 25'
  MATCHED=" $(/usr/bin/pgrep -f "$PAT" 2>/dev/null | tr '\n' ' ') "
  matches() { case "$MATCHED" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
  for nm in explicit shebang envbash nice doltgc; do
    eval "p=\$PID_$nm"
    matches "$p" && ok "E12 positivo '$nm' (pid $p: $(/bin/ps -o command= -p "$p" 2>/dev/null | cut -c1-70)) casa" || bad "E12 FALSO-NEGATIVO '$nm' (pid $p: $(/bin/ps -o command= -p "$p" 2>/dev/null | cut -c1-70)) NAO casou — o guard deixaria rebootar no meio da manutencao"
  done
  for nm in mention sqlserver; do
    eval "p=\$PID_$nm"
    matches "$p" && bad "E12 FALSO-POSITIVO '$nm' (pid $p: $(/bin/ps -o command= -p "$p" 2>/dev/null | cut -c1-70)) casou — o guard seguraria o reboot sem manutencao nenhuma" || ok "E12 negativo '$nm' (pid $p) NAO casa"
  done
  # (the group's own 2>/dev/null is what hides bash's "Killed: 9" job notices)
  { for p in $SPAWNED; do /usr/bin/pkill -KILL -P "$p"; kill -KILL "$p"; done; wait; } 2>/dev/null
fi

# ═══ E13: o hand-off pro pos-boot ════════════════════════════════════════════
echo "E13: shutdown que falha apaga a pendencia; shutdown que 'pega' (rc 0) a mantem"
W_SHUTDOWN_RC=1 new_world e13a; run_nr FAKE_HOUR=23
log_has "shutdown returned 1" && ok "E13 o log registra o shutdown que falhou" || bad "E13 sem 'shutdown returned 1' no log"
[ ! -f "$PENDING" ] && ok "E13 shutdown rc=1 -> pendencia REMOVIDA (nenhum reboot em andamento; outro reboot em <3h nao vira 'Reboot noturno OK')" || bad "E13 pendencia ficou no disco apos um shutdown que falhou"
log_has "ERROR: shutdown returned 1 — reboot did NOT happen" && ok "E13 rc=1: o log diz ERROR 'reboot did NOT happen' (e verdade)" || bad "E13 rc=1 sem a linha de ERROR no log"
new_world e13b; run_nr FAKE_HOUR=23
log_has "shutdown accepted \(rc 0\)" && ok "E13 rc=0: o log diz que o shutdown foi aceito" || bad "E13 rc=0 sem 'shutdown accepted (rc 0)' no log"
log_has "reboot did NOT happen" && bad "E13 rc=0: o log diz ERROR 'reboot did NOT happen' com a maquina caindo (mentira no log)" || ok "E13 rc=0: nenhum 'reboot did NOT happen' falso no log"
[ -f "$PENDING" ] && ok "E13 shutdown rc=0 -> pendencia FICA (a maquina esta caindo; e o que avisa o pos-boot que este boot e nosso)" || bad "E13 a pendencia sumiu num shutdown que pegou: o pos-boot nao saberia que o boot foi do noturno"

# ═══ E14: contador do scraper + mail pendurado ═══════════════════════════════
echo "E14: o contador de scraper cortado so move perto do shutdown; mail pendurado tem prazo"
W_SCRAPER=1 new_world e14a; run_nr FAKE_HOUR=23
LN_UPD="$(grep -n 'macOS update' "$LOGF" | head -1 | cut -d: -f1)"; LN_CUT="$(grep -n 'WILL BE CUT' "$LOGF" | head -1 | cut -d: -f1)"
LN_REB="$(grep -n 'rebooting now' "$LOGF" | head -1 | cut -d: -f1)"
if [ -n "$LN_UPD" ] && [ -n "$LN_CUT" ] && [ -n "$LN_REB" ]; then
  [ "$LN_CUT" -gt "$LN_UPD" ] && [ "$LN_CUT" -lt "$LN_REB" ] && ok "E14 'WILL BE CUT' vem DEPOIS do passo de update do macOS e ANTES do shutdown (linhas $LN_UPD < $LN_CUT < $LN_REB)" || bad "E14 contador movido na hora errada (update=$LN_UPD cut=$LN_CUT reboot=$LN_REB)"
else
  bad "E14 faltou linha no log (update='$LN_UPD' cut='$LN_CUT' reboot='$LN_REB')"
fi
[ "$(cat "$W/cut-at-shutdown" 2>/dev/null)" = "1" ] && ok "E14 o contador ja valia 1 quando o shutdown foi chamado" || bad "E14 contador no shutdown = '$(cat "$W/cut-at-shutdown" 2>/dev/null)', esperado 1"
# 2a noite seguida + gc que PENDURA: o mail tem prazo, o reboot sai, o log diz que NAO foi enviado
W_SCRAPER=1 W_GC_HANG=1 new_world e14b; printf '1\n' > "$CITY/.gc/logs/nightly-reboot.scraper-cut.streak"
T0=$(/bin/date +%s)
NR_LIMIT=40 run_nr FAKE_HOUR=23 NIGHTLY_REBOOT_INFO_PROBE_TIMEOUT_SECS=2 NIGHTLY_REBOOT_INFO_BUDGET_SECS=6
T1=$(/bin/date +%s)
[ "${NR_TIMED_OUT:-0}" = "0" ] && rebooted && ok "E14 gc pendurado: o reboot saiu mesmo assim ($((T1-T0))s)" || bad "E14 gc pendurado travou o reboot (timed_out=${NR_TIMED_OUT:-0})"
log_has "alarm mail to mayor TIMED OUT" && ok "E14 o log diz que o aviso NAO foi enviado (TIMED OUT)" || bad "E14 sem registro do mail que estourou o prazo. alarm: $(grep -i 'alarm' "$LOGF" 2>/dev/null | tr '\n' '|')"
[ "$(pids_alive "$W/gc.pids")" = "0" ] && ok "E14 o gc pendurado foi morto" || bad "E14 sobrou gc pendurado vivo"
kill_pids "$W/gc.pids"
# mail que funciona: o desfecho tambem e registrado
W_SCRAPER=1 new_world e14c; printf '1\n' > "$CITY/.gc/logs/nightly-reboot.scraper-cut.streak"; run_nr FAKE_HOUR=23
log_has "alarm mail to mayor: sent" && ok "E14 mail enviado: registrado como 'sent'" || bad "E14 sem 'alarm mail to mayor: sent' no log"

# ═══ E15: o SKIP tambem tem prazo ════════════════════════════════════════════
# record_skip termina em `gc mail send` (escreve uma bead). Com o Dolt wedged ele pendura, a
# instancia nunca sai e o launchd nao dispara a noite seguinte enquanto esta "roda": um SKIP
# que vira o SKIP de toda noite, em silencio. O streak e gravado ANTES, entao o prazo preserva a conta.
echo "E15: noite PULADA com gc pendurado -> a instancia sai e o streak fica (dreno e legado)"
# dreno: o guard de seguranca bloqueia sempre; streak 1 -> este skip e o 2o e dispara o alarme
W_SENDER_RC=1 W_GC_HANG=1 new_world e15a; printf '1\n' > "$STREAK"
T0=$(/bin/date +%s)
NR_LIMIT=60 run_nr FAKE_HOUR=23 NIGHTLY_REBOOT_SKIP_RECORD_TIMEOUT_SECS=3
T1=$(/bin/date +%s)
[ "${NR_TIMED_OUT:-0}" = "0" ] && ok "E15 dreno: o script terminou sozinho em $((T1-T0))s com o gc pendurado" || bad "E15 dreno: o script PENDUROU no registro do skip (limite 60s) — a proxima noite nao dispara"
log_has "SKIP: safety guards still blocked" && ok "E15 dreno: o SKIP veio do guard de seguranca" || bad "E15 dreno: sem o SKIP do guard de seguranca"
log_has "recording the skip .*TIMED OUT" && ok "E15 dreno: o log diz que o alarme pode nao ter saido (TIMED OUT)" || bad "E15 dreno: sem registro do prazo estourado. log: $(tail -3 "$LOGF" 2>/dev/null | tr '\n' '|')"
[ "$(cat "$STREAK" 2>/dev/null)" = "2" ] && ok "E15 dreno: streak 1 -> 2 (a conta foi gravada antes do mail)" || bad "E15 dreno: streak = '$(cat "$STREAK" 2>/dev/null)', esperado 2"
[ ! -f "$DRAIN" ] && ok "E15 dreno: cidade solta" || bad "E15 dreno: sinal de dreno ficou"
[ "$(pids_alive "$W/gc.pids")" = "0" ] && ok "E15 dreno: o gc pendurado foi morto" || bad "E15 dreno: sobrou gc pendurado vivo"
kill_pids "$W/gc.pids"
assert_push "E15 dreno: aviso de noite pulada" "Reboot noturno pulado"
assert_push "E15 dreno: alarme de 2 noites seguidas" "noites seguidas sem reiniciar"
# legado (01:05): um construtor vivo bloqueia pra sempre — nenhuma versao do script chega ao reboot
W_HQ_BUSY=1 W_GC_HANG=1 new_world e15b; printf '1\n' > "$STREAK"
T0=$(/bin/date +%s)
NR_LIMIT=60 run_nr FAKE_HOUR=1 FAKE_MIN=5 NIGHTLY_REBOOT_SKIP_RECORD_TIMEOUT_SECS=3
T1=$(/bin/date +%s)
[ "${NR_TIMED_OUT:-0}" = "0" ] && ok "E15 legado: o script terminou sozinho em $((T1-T0))s com o gc pendurado" || bad "E15 legado: o script PENDUROU no registro do skip (limite 60s)"
! rebooted && ok "E15 legado: nao reiniciou" || bad "E15 legado: reiniciou com o guard hq bloqueando"
[ "$(cat "$STREAK" 2>/dev/null)" = "2" ] && ok "E15 legado: streak 1 -> 2" || bad "E15 legado: streak = '$(cat "$STREAK" 2>/dev/null)', esperado 2"
log_has "recording the skip .*TIMED OUT" && ok "E15 legado: TIMED OUT registrado" || bad "E15 legado: sem registro do prazo estourado"
[ "$(pids_alive "$W/gc.pids")" = "0" ] && ok "E15 legado: o gc pendurado foi morto" || bad "E15 legado: sobrou gc pendurado vivo"
kill_pids "$W/gc.pids"
assert_push "E15 legado: aviso de noite pulada" "Reboot noturno pulado"
assert_push "E15 legado: alarme de 2 noites seguidas" "noites seguidas sem reiniciar"

# ═══ E16: os guards de seguranca sao lidos DE NOVO logo antes do shutdown ════════════════
# O defeito (gate FAIL 2/3, achado medio): o veredito dos guards de seguranca era lido uma vez, e entre
# ele e o shutdown vinham as sondas informativas (ate 75s), a contagem por rig, o update do macOS
# (sem prazo, por desenho) e o notify. O envio central NAO e travado pelo dreno: um envio que comeca
# nesse intervalo era cortado no meio — o "lead recebe duas mensagens" que o guard existe pra evitar.
echo "E16: os guards de seguranca sao lidos de novo logo antes do shutdown"
# a) um envio comeca no intervalo (chamada 1 livre = decisao; 2 bloqueada = re-checagem; 3 livre) -> segura e reinicia
W_SENDER_SEQ="0 1 0" new_world e16a
run_nr FAKE_HOUR=23
rebooted && ok "E16a o envio terminou durante a re-checagem -> reinicia" || bad "E16a NAO reiniciou. log: $(tail -3 "$LOGF" 2>/dev/null | tr '\n' '|')"
[ "$(grep -c -- '-r now' "$SHUT")" = "1" ] && ok "E16a exatamente 1 shutdown" || bad "E16a numero de shutdowns != 1"
log_has "final safety re-check" && ok "E16a o log registra a re-checagem final" || bad "E16a sem a re-checagem final no log (o veredito das 23:40 foi usado como esta)"
[ "$(wc -l < "$SENDER_N" | tr -d ' ')" = "3" ] && ok "E16a o guard de envio foi consultado 3x (decisao, re-checagem bloqueada, re-checagem livre)" || bad "E16a o guard de envio foi consultado $(wc -l < "$SENDER_N" | tr -d ' ')x, esperado 3"
log_has "attempt 1/3 blocked by a safety guard" && ok "E16a a tentativa bloqueada da re-checagem ficou no log" || bad "E16a sem a tentativa bloqueada no log"
# b) o envio fica em voo ate o fim -> SKIP; nada foi cortado, nada foi contado
W_SENDER_SEQ="0 1" W_SCRAPER=1 new_world e16b; printf '13\n' > "$STREAK"
run_nr FAKE_HOUR=23
! rebooted && ok "E16b envio em voo na re-checagem -> NAO reinicia" || bad "E16b reiniciou com um envio em voo (o veredito velho foi usado)"
log_has "final safety re-check" && ok "E16b a re-checagem final rodou" || bad "E16b sem a re-checagem final no log"
log_has "SKIP: safety guards still blocked" && ok "E16b SKIP do guard de seguranca" || bad "E16b sem SKIP do guard de seguranca"
[ ! -e "$PENDING" ] && ok "E16b a pendencia do pos-boot NAO foi gravada (nao houve reboot)" || bad "E16b a pendencia ficou no disco apos um SKIP"
[ ! -f "$DRAIN" ] && ok "E16b cidade solta (sinal de dreno removido)" || bad "E16b sinal de dreno ficou no disco"
[ "$(cat "$STREAK" 2>/dev/null)" = "14" ] && ok "E16b streak 13 -> 14 (a noite pulada aqui continua contando; nao zerou antes do shutdown)" || bad "E16b streak deveria ser 14, veio '$(cat "$STREAK" 2>/dev/null)'"
SCUT="$CITY/.gc/logs/nightly-reboot.scraper-cut.streak"
{ [ ! -s "$SCUT" ] || [ "$(cat "$SCUT" 2>/dev/null)" = "0" ]; } && ok "E16b o contador de scraper cortado nao andou (o scraper nao foi cortado)" || bad "E16b contador de scraper cortado = '$(cat "$SCUT" 2>/dev/null)' numa noite sem reboot"
assert_push "E16b aviso de noite pulada" "Reboot noturno pulado"

echo ""
echo "nightly-reboot drain selftest: PASS=$PASS FAIL=$FAIL SKIPPED=$SKIPPED"
[ "$FAIL" -eq 0 ]
