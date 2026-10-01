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
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/nightly-reboot.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

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
chmod +x "$FAKEBIN/date" "$FAKEBIN/sudo"

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
new_world() {
  W="$TMP/$1"; rm -rf "$W"; mkdir -p "$W/city/.gc/logs" "$W/city/scripts" "$W/rodada" "$W/run"
  CITY="$W/city"; LOGF="$CITY/.gc/logs/nightly-reboot.log"
  STREAK="$CITY/.gc/logs/nightly-reboot.streak"
  DRAIN="$W/run/city-drain.level"; PENDING="$CITY/.gc/logs/nightly-reboot.pending"
  SHUT="$W/shutdown.calls"; DRAIN_AT_SHUT="$W/drain-at-shutdown"; PEND_AT_SHUT="$W/pending-at-shutdown"
  DRAIN_AT_SENDER="$W/drain-at-sender"; GC_CALLS="$W/gc.calls"; NOTIFY_CALLS="$W/notify.calls"
  : > "$SHUT"; : > "$GC_CALLS"; : > "$NOTIFY_CALLS"

  cat > "$CITY/scripts/gate-queue-composition.sh" <<EOF
#!/usr/bin/env bash
echo '{"total":${W_GATE_REAL:-0},"real":${W_GATE_REAL:-0},"phantom":0,"unknown":0}'
EOF
  cat > "$W/bd" <<EOF
#!/usr/bin/env bash
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
EOF
  cat > "$W/notify" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_CALLS"
EOF
  cat > "$W/shutdown" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SHUT"
cp "$DRAIN" "$DRAIN_AT_SHUT" 2>/dev/null
cp "$PENDING" "$PEND_AT_SHUT" 2>/dev/null
exit 0
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

# run_nr [VAR=val ...] — roda o script de verdade, tudo faked e a hora pinada.
run_nr() {
  env PATH="$FAKEBIN:$PATH" CITY="$CITY" GC_BIN="$W/gc" BD_BIN="$W/bd" NOTIFY_BIN="$W/notify" NOTIFY_AS_USER="$USER" \
      SHUTDOWN_BIN="$W/shutdown" SOFTWAREUPDATE_BIN="$W/softwareupdate" SCRAPER_RODADA_DIR="$W/rodada" \
      NIGHTLY_REBOOT_DRAIN_FILE="$DRAIN" NIGHTLY_REBOOT_DRAIN_WAIT_SECS=0 \
      NIGHTLY_REBOOT_SAFETY_RETRY_INTERVAL=0 NIGHTLY_REBOOT_SAFETY_MAX_ATTEMPTS=3 \
      NIGHTLY_REBOOT_SENDER_SAFE_PY="$SENDER" NIGHTLY_REBOOT_PGREP_BIN="$W/pgrep" \
      NIGHTLY_REBOOT_RETRY_INTERVAL=0 NIGHTLY_REBOOT_RETRY_MAX_ATTEMPTS=2 \
      "$@" /bin/bash "$SCRIPT" > "$W/stdout" 2> "$W/stderr"
}
rebooted()   { [ -s "$SHUT" ] && grep -q -- '-r now' "$SHUT"; }
log_has()    { grep -q -E -- "$1" "$LOGF" 2>/dev/null; }

# ═══ E1: o cenario do bug ════════════════════════════════════════════════════
echo "E1: gate com marker real + construtor vivo + scraper rodando -> as 23:40 reinicia assim mesmo"
W_GATE_REAL=2 W_HQ_BUSY=1 W_SCRAPER=1 new_world e1
printf '13\n' > "$STREAK"      # 13 noites puladas: a noite boa tem que zerar
run_nr FAKE_HOUR=23
if rebooted; then ok "E1 reboot emitido (shutdown -r now) com os 3 guards de trabalho bloqueando"; else bad "E1 NAO reiniciou — o bug das 13 noites continua. log: $(tail -3 "$LOGF" 2>/dev/null | tr '\n' '|')"; fi
[ "$(grep -c -- '-r now' "$SHUT")" = "1" ] && ok "E1 exatamente 1 shutdown" || bad "E1 numero de shutdowns != 1"
log_has "drain mode" && ok "E1 o log fala do dreno" || bad "E1 o log nao menciona o dreno"
[ "$(cat "$STREAK" 2>/dev/null)" = "0" ] && ok "E1 streak 13 -> 0 (a noite que reinicia zera o alarme)" || bad "E1 streak deveria zerar, veio '$(cat "$STREAK" 2>/dev/null)'"

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

echo ""
echo "nightly-reboot drain selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
