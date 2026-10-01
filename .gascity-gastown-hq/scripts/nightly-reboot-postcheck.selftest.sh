#!/usr/bin/env bash
# nightly-reboot-postcheck.selftest.sh — selftest da conferencia POS-BOOT do reboot
# noturno (ga-a2v0bz).
#
# O que ela resolve: o reboot noturno agora acontece as 23:40, mas "reiniciou" nao e
# "a cidade voltou inteira". Antes o Mayor conferia a mao (Dolt, envio, mapa). Este
# script e essa conferencia, e o selftest prova a CLASSE de erro que importa aqui:
# tres estados (ok / FAIL / unknown) que nunca viram um so, e um boot que NAO e do
# reboot noturno nunca gera conferencia nem notificacao.
#
# SEGURANCA: nada aqui chama shutdown, bd, gc real, nem rede real. Todo binario externo
# (sysctl, launchctl, curl, notify, gc, a sonda do Dolt) e um fake no diretorio do
# cenario, injetado pelas mesmas variaveis de ambiente que o script expoe.
#
#   P1  sem pendencia -> silencio total (e o caso de TODO login que nao e do reboot)
#   P2  mesmo boot / boot mais antigo -> o reboot ainda nao aconteceu: deixa a pendencia
#   P3  pendencia velha (>3h) -> nao atribui este boot ao reboot noturno; descarta
#   P4  tudo ok -> notify OK, pendencia removida, SEM mail; sonda chamada com --robust
#   P5  Dolt caido em todas as rodadas -> COM PROBLEMA + mail, esgota as rodadas
#   P5c o mail ao mayor que FALHA ou PENDURA e registrado (rc / TIMED OUT) — nunca parece enviado
#   P5e o prazo do mail vale tambem pra um gc que IGNORA o TERM: folga curta e KILL
#   P5b o orcamento e em SEGUNDOS (relogio), nao so em rodadas
#   P6  tres estados: probe rc 2 / launchctl com erro / curl sem resposta = unknown
#   P7  um servico sobe na 2a rodada -> re-confere TUDO e fecha ok
#   P8  envio: ausente / carregado sem PID = FAIL; rodando = ok
#   P9  mapa = ORIGEM (loopback) + TUNEL (cloudflared): o pior dos dois vence (FAIL > unknown > ok); a URL
#       publica (Cloudflare Access responde 302 na BORDA, com o mapa de pe ou nao) NUNCA entra no veredito
#   P16 o filtro de problemas olha o ESTADO, nao o texto: um FAIL cujo detalhe contem ' ok: ' nao some do aviso
#   P10 dreno: vivo neste boot = FAIL; de outro boot = ok; ilegivel = unknown; NUNCA removido
#   P11 pendencia ilegivel -> avisa e descarta; kern.boottime ilegivel -> mantem a pendencia
#   P12 trava: dono vivo -> sai; dono morto -> assume; trava de OUTRO boot com pid reaproveitado
#       (vivo, mas de outro processo) -> assume; boot ilegivel do nosso lado -> NAO assume
#   P13 --now: 4 linhas, sem notify, sem log, sem tocar na pendencia; arg ruim -> exit 2
#   P14 estatico: nunca faz `source` da sonda, nunca chama o goroutine dump (kill -QUIT)
#   P15 contrato com nightly-reboot.sh: mesmas chaves da pendencia, mesmos caminhos, mesmo formato do dreno
#
# ROTEAMENTO (gate FAIL 2/3): o `notify` manda pro digest SILENCIOSO por padrao; -p 4 e o titulo nao
# mudam isso. P4/P5/P6/P11 perguntam ao notify DE VERDADE (NOTIFY_ROUTE_TEST=1, nao envia nada) onde cai
# a chamada exata que o script fez: os avisos de falha tem que cair no PUSH, o "OK" de rotina nao.
# Antes, estes testes trocavam o notify por um fake que so gravava argv — e passavam sem exercitar isso.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/nightly-reboot-postcheck.sh"
PASS=0; FAIL=0; SKIPPED=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
# skipped: uma checagem que NAO PODE rodar aqui (nao e passe, nem falha) — dita em voz alta
skipped() { echo "  - SKIP $*"; SKIPPED=$((SKIPPED+1)); }
REAL_NOTIFY="${NIGHTLY_REBOOT_SELFTEST_REAL_NOTIFY:-/Users/athos/.local/bin/notify}"

if [ ! -f "$SCRIPT" ]; then
  bad "nightly-reboot-postcheck.sh nao existe ao lado deste selftest — nada a testar"
  echo ""; echo "nightly-reboot-postcheck selftest: PASS=$PASS FAIL=$FAIL SKIPPED=$SKIPPED"; exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BOOT_BEFORE=1790000000
BOOT_NOW=1790000500

# ── world: um diretorio novo por cenario, com todos os fakes ────────────────
# Variaveis do cenario (todas opcionais; default = "tudo bem"):
#   W_BOOT         boot atual que o fake de sysctl informa    (default BOOT_NOW; "garbage" = ilegivel)
#   W_DOLT_RC      rc da sonda (0 ok | 1 unreachable | 2 unknown)   (default 0)
#   W_DOLT_OK_AT   a partir de qual chamada a sonda passa a dar 0
#   W_SENDER       running | nopid | absent | error             (default running)
#   W_SENDER_OK_AT a partir de qual chamada o launchctl passa a "running"
#   W_MAP_CODE / W_MAP_RC   resposta da ORIGEM do mapa (127.0.0.1:8099) no fake de curl  (default 200 / 0)
#   W_EDGE_CODE    resposta de QUALQUER outra URL (a borda publica)  (default 302 — o que o Cloudflare Access da)
#   W_TUNNEL       running | nopid | absent | error | weird  (job do cloudflared; default running)
#   W_READY_BODY / W_READY_RC   resposta do /ready do cloudflared  (default readyConnections=4 / 0)
#   W_LSOF         ok | none | error | ipv6 | multi | missing  (listeners do pid do tunel; default ok = :20241)
#   W_DOLT_OUT     texto que a sonda imprime quando rc=1  (default 'unhealthy')
#   W_GC_RC        rc do fake de gc (mail send)                (default 0)
#   W_GC_HANG      1 = o gc pendura (Dolt wedged): grava o pid e dorme 600s
new_world() {
  W="$TMP/$1"; rm -rf "$W"; mkdir -p "$W/city/.gc/logs" "$W/run" "$W/vm"
  LOGF="$W/city/.gc/logs/nightly-reboot.log"
  PENDING="$W/city/.gc/logs/nightly-reboot.pending"
  DRAIN="$W/run/city-drain.level"
  NOTIFY_CALLS="$W/notify.calls"; GC_CALLS="$W/gc.calls"; PROBE_ARGS="$W/probe.args"
  NOTIFY_FORCE="$W/notify.force"; NOTIFY_ROUTES="$W/notify.routes"
  : > "$NOTIFY_CALLS"; : > "$GC_CALLS"; : > "$PROBE_ARGS"; : > "$NOTIFY_FORCE"; : > "$NOTIFY_ROUTES"
  touch "$W/vm/swapfile0" "$W/vm/swapfile1" "$W/vm/notaswap"

  # grava os argumentos, se veio NOTIFY_FORCE_PUSH, e pra onde o notify DE VERDADE mandaria esta chamada exata
  cat > "$W/notify" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_CALLS"
echo "force=\${NOTIFY_FORCE_PUSH:-} :: \$*" >> "$NOTIFY_FORCE"
if [ -x "$REAL_NOTIFY" ]; then r="\$(NOTIFY_ROUTE_TEST=1 "$REAL_NOTIFY" "\$@" 2>/dev/null | head -1)"; [ -n "\$r" ] || r="unreadable"; else r="n/a"; fi
echo "\$r :: \$*" >> "$NOTIFY_ROUTES"
EOF
  cat > "$W/gc" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GC_CALLS"
if [ "${W_GC_HANG:-0}" = "1" ]; then echo \$\$ >> "$W/gc.pids"; exec /bin/sleep 600; fi
if [ "${W_GC_HANG:-0}" = "2" ]; then echo \$\$ >> "$W/gc.pids"; trap '' TERM; while :; do /bin/sleep 1; done; fi
echo "gc: simulated output"
exit ${W_GC_RC:-0}
EOF
  # kern.boottime REAL tem usec: um parse guloso (.*sec = N) devolveria o usec.
  cat > "$W/sysctl" <<EOF
#!/usr/bin/env bash
if [ "${W_BOOT:-$BOOT_NOW}" = "garbage" ]; then echo "oops"; exit 0; fi
echo "{ sec = ${W_BOOT:-$BOOT_NOW}, usec = 958892 } Wed Oct  1 07:00:00 2026"
EOF
  cat > "$W/probe.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$PROBE_ARGS"
n=\$(( \$(cat "$W/n.probe" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$W/n.probe"
rc=${W_DOLT_RC:-0}
if [ -n "${W_DOLT_OK_AT:-}" ] && [ "\$n" -ge "${W_DOLT_OK_AT:-0}" ]; then rc=0; fi
case "\$rc" in 0) echo healthy ;; 1) echo "${W_DOLT_OUT:-unhealthy}" ;; *) echo unknown ;; esac
exit "\$rc"
EOF
  # launchctl: o MESMO fake atende o job do envio e o do tunel, escolhido pelo rotulo ($2); o contador
  # e por rotulo, pra "sobe na 2a rodada" continuar querendo dizer 2a rodada
  cat > "$W/launchctl" <<EOF
#!/usr/bin/env bash
cf="$W/n.launchctl.\$2"
n=\$(( \$(cat "\$cf" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$cf"
if [ "\$2" = "br.urblink.cloudflared.urblink-ops" ]; then mode="${W_TUNNEL:-running}"; else mode="${W_SENDER:-running}"; fi
if [ "\$2" != "br.urblink.cloudflared.urblink-ops" ] && [ -n "${W_SENDER_OK_AT:-}" ] && [ "\$n" -ge "${W_SENDER_OK_AT:-0}" ]; then mode=running; fi
case "\$mode" in
  running) printf '{\n\t"Label" = "%s";\n\t"LastExitStatus" = 0;\n\t"PID" = 42650;\n};\n' "\$2" ;;
  nopid)   printf '{\n\t"Label" = "%s";\n\t"LastExitStatus" = 256;\n};\n' "\$2" ;;
  absent)  echo "Could not find service \"\$2\" in domain for port"; exit 113 ;;
  error)   echo "launchctl: unexpected failure"; exit 5 ;;
  weird)   echo "something else entirely" ;;
esac
EOF
  # curl: responde conforme a URL — e GRAVA toda URL chamada. A origem do mapa e o /ready do tunel tem
  # respostas proprias; qualquer outra URL e "a borda publica", que o Cloudflare Access responde com 302
  # estando o mapa de pe ou nao. Um fake que respondesse igual pra tudo (como o antigo) nao distingue um
  # script que olha a origem de um que olha a borda — foi exatamente o que deixou esse furo passar.
  # (default numa variavel a parte: `${V:-{...}}` com JSON dentro fecha a expansao na 1a chave e, com V
  #  definida, devolve "valor}" — corpo corrompido sem ninguem ver)
  READY_DEFAULT='{"status":200,"readyConnections":4,"connectorId":"fake"}'
  # (sem os dois pontos: W_READY_BODY="" e um corpo VAZIO de verdade, nao "use o default")
  printf '%s' "${W_READY_BODY-$READY_DEFAULT}" > "$W/ready.body"
  cat > "$W/curl" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do url="\$a"; done
echo "\$url" >> "$W/curl.urls"
case "\$url" in
  *:20240/ready) printf 'not the ready json'; exit 0 ;;
  */ready) cat "$W/ready.body"; exit ${W_READY_RC:-0} ;;
  http://127.0.0.1:8099/) printf '%s' "${W_MAP_CODE:-200}"; exit ${W_MAP_RC:-0} ;;
  *) printf '%s' "${W_EDGE_CODE:-302}"; exit 0 ;;
esac
EOF
  # lsof: so o que o script pergunta — os listeners TCP do pid do tunel, em formato -F n
  cat > "$W/lsof" <<EOF
#!/usr/bin/env bash
case "${W_LSOF:-ok}" in
  ok)    printf 'p42650\nf9\nn127.0.0.1:20241\n' ;;
  ipv6)  printf 'p42650\nf9\nn[::1]:20241\n' ;;
  multi) printf 'p42650\nf8\nn127.0.0.1:20240\nf9\nn127.0.0.1:20241\n' ;;
  none)  : ;;
  error) echo "lsof: WARNING: can't stat() fs" >&2; exit 1 ;;
esac
EOF
  [ "${W_LSOF:-ok}" = "missing" ] && rm -f "$W/lsof"
  chmod +x "$W/notify" "$W/gc" "$W/sysctl" "$W/probe.sh" "$W/launchctl" "$W/curl" "$W/lsof" 2>/dev/null
}

write_pending() {  # $1 = issued epoch   $2 = boot_before (default BOOT_BEFORE)
  printf 'issued=%s\nboot_before=%s\nmode=drain\n' "$1" "${2:-$BOOT_BEFORE}" > "$PENDING"
}
now_s() { /bin/date +%s; }

# run_pc [args...] -> RC, OUT (stdout+stderr)
run_pc() {
  OUT="$(env CITY="$W/city" GC_BIN="$W/gc" NOTIFY_BIN="$W/notify" SYSCTL_BIN="$W/sysctl" \
      LAUNCHCTL_BIN="$W/launchctl" CURL_BIN="$W/curl" LSOF_BIN="$W/lsof" \
      NIGHTLY_REBOOT_LOG="$LOGF" NIGHTLY_REBOOT_PENDING_FILE="$PENDING" NIGHTLY_REBOOT_DRAIN_FILE="$DRAIN" \
      NIGHTLY_REBOOT_POSTCHECK_DOLT_PROBE="$W/probe.sh" NIGHTLY_REBOOT_POSTCHECK_VM_DIR="$W/vm" \
      NIGHTLY_REBOOT_POSTCHECK_INTERVAL=0 NIGHTLY_REBOOT_POSTCHECK_MAX_ATTEMPTS="${MAXA:-3}" \
      NIGHTLY_REBOOT_POSTCHECK_MAX_WAIT_SECS="${MAXW:-1200}" \
      bash "$SCRIPT" "$@" 2>&1)"; RC=$?
}
n_lines() { local n; n="$(grep -c . "$1" 2>/dev/null)"; echo "${n:-0}"; }
log_has() { grep -qF -- "$1" "$LOGF" 2>/dev/null; }
notify_has() { grep -qF -- "$1" "$NOTIFY_CALLS"; }
# force_of <trecho>: "1" se o script mandou com NOTIFY_FORCE_PUSH, "" se nao, "NONE" se nao mandou
force_of() { local l; l="$(grep -F -- "$1" "$NOTIFY_FORCE" 2>/dev/null | head -1)"; [ -n "$l" ] || { echo NONE; return; }; l="${l#force=}"; echo "${l%% ::*}"; }
route_of() { local l; l="$(grep -F -- "$1" "$NOTIFY_ROUTES" 2>/dev/null | head -1)"; [ -n "$l" ] || { echo NONE; return; }; echo "${l%% ::*}"; }
# assert_push <rotulo> <trecho>: mandado COM o override E o notify de verdade o poe no push
assert_push() {
  local label="$1" frag="$2" f r
  f="$(force_of "$frag")"; r="$(route_of "$frag")"
  case "$f" in
    NONE) bad "$label: o aviso '$frag' nem foi mandado. chamadas: $(tr '\n' '|' < "$NOTIFY_CALLS")"; return ;;
    1) ok "$label: mandado com NOTIFY_FORCE_PUSH" ;;
    *) bad "$label: mandado SEM NOTIFY_FORCE_PUSH — cai no digest silencioso (o alerta primario ninguem ve)" ;;
  esac
  case "$r" in
    push*) ok "$label: o notify de verdade o poe no PUSH ($r)" ;;
    n/a) skipped "$label: notify de verdade ausente em $REAL_NOTIFY — so o override foi provado, nao a rota" ;;
    *) bad "$label: o notify de verdade o poe em '$r' — o aviso nao chega" ;;
  esac
}

# ── P1: sem pendencia -> silencio total ─────────────────────────────────────
echo "P1: sem pendencia (todo login que nao e do reboot)"
new_world p1; run_pc
[ "$RC" = "0" ] && ok "P1 exit 0" || bad "P1 exit=$RC (esperado 0). out: $OUT"
[ "$(n_lines "$NOTIFY_CALLS")" = "0" ] && ok "P1 nenhum notify" || bad "P1 notificou sem pendencia"
[ "$(n_lines "$PROBE_ARGS")" = "0" ] && ok "P1 nenhuma sonda chamada" || bad "P1 conferiu sem pendencia"
[ ! -s "$LOGF" ] && ok "P1 nenhuma linha de log" || bad "P1 escreveu no log sem pendencia: $(cat "$LOGF")"

# ── P2: o reboot ainda nao aconteceu ────────────────────────────────────────
echo "P2: mesmo boot / boot mais antigo -> deixa a pendencia"
for b in "$BOOT_BEFORE" "$((BOOT_BEFORE - 100))"; do
  W_BOOT="$b" new_world p2; write_pending "$(( $(now_s) - 300 ))"; run_pc
  [ "$RC" = "0" ] && ok "P2 boot=$b exit 0" || bad "P2 boot=$b exit=$RC"
  [ -e "$PENDING" ] && ok "P2 boot=$b pendencia mantida" || bad "P2 boot=$b removeu a pendencia (o reboot nem aconteceu)"
  [ "$(n_lines "$NOTIFY_CALLS")" = "0" ] && ok "P2 boot=$b sem notify" || bad "P2 boot=$b notificou"
  [ "$(n_lines "$PROBE_ARGS")" = "0" ] && ok "P2 boot=$b sem conferencia" || bad "P2 boot=$b conferiu antes do reboot"
  log_has "same boot" && ok "P2 boot=$b log explica" || bad "P2 boot=$b sem 'same boot' no log"
done

# ── P3: pendencia velha ──────────────────────────────────────────────────────
echo "P3: pendencia de 4h -> este boot nao e do reboot noturno"
new_world p3; write_pending "$(( $(now_s) - 14400 ))"; run_pc
[ "$RC" = "0" ] && ok "P3 exit 0" || bad "P3 exit=$RC"
[ ! -e "$PENDING" ] && ok "P3 pendencia descartada" || bad "P3 deixou a pendencia velha (reportaria de novo a cada login)"
[ "$(n_lines "$NOTIFY_CALLS")" = "0" ] && ok "P3 sem notify (nao e nosso boot)" || bad "P3 notificou um boot que nao e do noturno"
[ "$(n_lines "$PROBE_ARGS")" = "0" ] && ok "P3 sem conferencia" || bad "P3 conferiu"
log_has "WARN" && ok "P3 log com WARN" || bad "P3 sem WARN no log"

# ── P4: tudo ok ──────────────────────────────────────────────────────────────
echo "P4: tudo ok"
new_world p4; write_pending "$(( $(now_s) - 300 ))"; run_pc
[ "$RC" = "0" ] && ok "P4 exit 0" || bad "P4 exit=$RC. out: $OUT"
notify_has "Reboot noturno OK" && ok "P4 notify 'Reboot noturno OK'" || bad "P4 sem notify de sucesso: $(cat "$NOTIFY_CALLS")"
notify_has "-p 3" && ok "P4 prioridade 3 (rotina)" || bad "P4 prioridade errada: $(cat "$NOTIFY_CALLS")"
notify_has "swap: 2 arquivo(s)" && ok "P4 notify traz o swap pos-boot (2 swapfiles do fake)" || bad "P4 sem swap no notify: $(cat "$NOTIFY_CALLS")"
[ ! -e "$PENDING" ] && ok "P4 pendencia removida" || bad "P4 pendencia ficou (re-reporta a cada login)"
[ "$(n_lines "$GC_CALLS")" = "0" ] && ok "P4 sem mail ao mayor numa noite limpa" || bad "P4 mandou mail numa noite limpa: $(cat "$GC_CALLS")"
[ "$(cat "$PROBE_ARGS")" = "--robust" ] && ok "P4 sonda chamada com --robust (nao a bare, que le Dolt lento como caido)" || bad "P4 args da sonda = '$(cat "$PROBE_ARGS")' (esperado --robust)"
log_has "all four checks ok" && ok "P4 log RESULT" || bad "P4 sem RESULT no log"
[ "$(force_of "Reboot noturno OK")" = "" ] && ok "P4 o 'OK' de rotina NAO e forcado — fica no digest, de proposito" || bad "P4 o OK de rotina saiu com NOTIFY_FORCE_PUSH='$(force_of "Reboot noturno OK")' (NONE = nem foi mandado)"

# ── P5: Dolt caido em todas as rodadas ───────────────────────────────────────
echo "P5: Dolt unreachable em todas as rodadas"
W_DOLT_RC=1 new_world p5; write_pending "$(( $(now_s) - 300 ))"; run_pc
[ "$RC" = "1" ] && ok "P5 exit 1" || bad "P5 exit=$RC"
notify_has "COM PROBLEMA" && ok "P5 notify COM PROBLEMA" || bad "P5 notify: $(cat "$NOTIFY_CALLS")"
notify_has "-p 4" && ok "P5 prioridade 4 (alta)" || bad "P5 prioridade: $(cat "$NOTIFY_CALLS")"
notify_has "dolt FAIL" && ok "P5 o notify diz QUAL check caiu e como (dolt FAIL)" || bad "P5 notify sem 'dolt FAIL': $(cat "$NOTIFY_CALLS")"
assert_push "P5 COM PROBLEMA (Dolt caido)" "COM PROBLEMA"
grep -qF "mail send mayor" "$GC_CALLS" && ok "P5 mail ao mayor (best-effort, secundario)" || bad "P5 sem mail ao mayor: $(cat "$GC_CALLS")"
[ "$(cat "$W/n.probe")" = "3" ] && ok "P5 esgotou as 3 rodadas (MAX_ATTEMPTS) antes de desistir" || bad "P5 rodadas=$(cat "$W/n.probe") (esperado 3)"
[ ! -e "$PENDING" ] && ok "P5 pendencia removida mesmo com problema" || bad "P5 pendencia ficou"
notify_has "sender ok" && bad "P5 listou o que esta OK como problema" || ok "P5 o notify de problema lista so o que NAO esta ok"

# ── P5b: o orcamento e de RELOGIO, nao so de rodadas ─────────────────────────
echo "P5b: orcamento em segundos — uma rodada que falha nao e instantanea"
W_DOLT_RC=1 new_world p5b; write_pending "$(( $(now_s) - 300 ))"; MAXA=40 MAXW=0 run_pc
[ "$RC" = "1" ] && ok "P5b exit 1" || bad "P5b exit=$RC"
[ "$(cat "$W/n.probe")" = "1" ] && ok "P5b prazo estourado -> 1 rodada so (nao as 40 do teto)" || bad "P5b rodadas=$(cat "$W/n.probe") com MAX_WAIT=0 (o prazo em segundos nao esta valendo: com Dolt fora cada rodada leva ~1min e 40 delas ~1h)"
notify_has "COM PROBLEMA" && ok "P5b o aviso de problema sai no prazo" || bad "P5b sem aviso: $(cat "$NOTIFY_CALLS")"
log_has "up to 0s" && ok "P5b o log declara o prazo" || bad "P5b log sem o prazo"

# ── P5c: o desfecho do mail ao mayor fica no log ─────────────────────────────
# O mail terminava em `>/dev/null 2>&1 || true` depois de logar "mailing mayor": um envio que
# falhou (ou que nunca voltou) era indistinguivel de um que saiu.
echo "P5c: mail ao mayor que falha / pendura e registrado, e nao prende o pos-boot"
W_DOLT_RC=1 W_GC_RC=1 new_world p5c; write_pending "$(( $(now_s) - 300 ))"; run_pc
log_has "mail to mayor FAILED (rc=1" && ok "P5c mail que falhou: 'FAILED (rc=1' no log, com a saida do gc" || bad "P5c sem registro do mail que falhou. log: $(grep -i mail "$LOGF" | tr '\n' '|')"
[ "$RC" = "1" ] && [ ! -e "$PENDING" ] && ok "P5c o mail falho nao muda o desfecho (exit 1, pendencia removida)" || bad "P5c exit=$RC pendencia=$([ -e "$PENDING" ] && echo ficou || echo removida)"
W_DOLT_RC=1 new_world p5c-ok; write_pending "$(( $(now_s) - 300 ))"; run_pc
log_has "mail to mayor: sent" && ok "P5c mail que saiu: 'sent' no log" || bad "P5c sem 'mail to mayor: sent'"
W_DOLT_RC=1 W_GC_HANG=1 new_world p5d; write_pending "$(( $(now_s) - 300 ))"
( /bin/sleep 40; for p in $(cat "$W/gc.pids" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done ) >/dev/null 2>&1 &
HG_WD=$!
T0=$(now_s); NIGHTLY_REBOOT_POSTCHECK_MAIL_TIMEOUT_SECS=2 run_pc; T1=$(now_s)
kill "$HG_WD" 2>/dev/null; wait "$HG_WD" 2>/dev/null
[ $((T1-T0)) -le 25 ] && ok "P5c gc pendurado: o pos-boot terminou em $((T1-T0))s (sem prazo ficava parado ate o gc voltar)" || bad "P5c o pos-boot ficou $((T1-T0))s preso no mail"
log_has "mail to mayor TIMED OUT" && ok "P5c o log diz que o mail NAO foi enviado (TIMED OUT)" || bad "P5c sem 'TIMED OUT' no log. mail: $(grep -i mail "$LOGF" | tr '\n' '|')"
[ "$RC" = "1" ] && [ ! -e "$PENDING" ] && ok "P5c gc pendurado: exit 1 e pendencia removida" || bad "P5c exit=$RC pendencia=$([ -e "$PENDING" ] && echo ficou || echo removida)"
n_alive=0; for p in $(cat "$W/gc.pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && n_alive=$((n_alive+1)); done
[ "$n_alive" = "0" ] && ok "P5c o gc pendurado foi morto" || bad "P5c sobrou gc pendurado vivo"
for p in $(cat "$W/gc.pids" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done

# P5e: o prazo do mail tambem vale pra um gc que IGNORA o TERM. Um unico TERM so e prazo pra quem o respeita:
# `trap '' TERM; while :; do sleep 1; done` sobrevive a ele, e o `wait` do script ficava preso (com a trava
# na mao) pelo tempo que o gc vivesse — o mesmo silencio que o prazo existe pra acabar. Depois de uma
# folga curta o script manda KILL.
echo "P5e: gc que ignora TERM -> TERM, folga, KILL; o pos-boot termina"
W_DOLT_RC=1 W_GC_HANG=2 new_world p5e; write_pending "$(( $(now_s) - 300 ))"
( /bin/sleep 60; for p in $(cat "$W/gc.pids" 2>/dev/null); do /usr/bin/pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done ) >/dev/null 2>&1 &
HG_WD=$!
T0=$(now_s); NIGHTLY_REBOOT_POSTCHECK_MAIL_TIMEOUT_SECS=2 run_pc; T1=$(now_s)
kill "$HG_WD" 2>/dev/null; wait "$HG_WD" 2>/dev/null
[ $((T1-T0)) -le 30 ] && ok "P5e gc que ignora TERM: o pos-boot terminou em $((T1-T0))s (sem o KILL ficava preso ate o limite do teste)" || bad "P5e o pos-boot ficou $((T1-T0))s preso num gc que ignora TERM"
log_has "mail to mayor TIMED OUT" && ok "P5e o log diz que o mail NAO foi enviado (TIMED OUT)" || bad "P5e sem 'TIMED OUT' no log. mail: $(grep -i mail "$LOGF" | tr '\n' '|')"
n_alive=0; for p in $(cat "$W/gc.pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && n_alive=$((n_alive+1)); done
[ "$n_alive" = "0" ] && ok "P5e o gc que ignorava TERM foi morto (KILL)" || bad "P5e sobrou gc vivo que ignora TERM"
for p in $(cat "$W/gc.pids" 2>/dev/null); do /usr/bin/pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done

# ── P6: tres estados, nunca colapsados ───────────────────────────────────────
echo "P6: 'nao consegui olhar' e unknown, nao ok e nao FAIL"
W_DOLT_RC=2 new_world p6a; write_pending "$(( $(now_s) - 300 ))"; run_pc
[ "$RC" = "1" ] && ok "P6 dolt unknown: exit 1 (unknown NAO e ok)" || bad "P6 dolt unknown: exit=$RC (colapsou em ok?)"
notify_has "dolt unknown" && ok "P6 dolt rotulado 'unknown'" || bad "P6 dolt rotulo: $(cat "$NOTIFY_CALLS")"
notify_has "dolt FAIL" && bad "P6 dolt unknown virou FAIL (colapsou 'nao sei' em 'caiu')" || ok "P6 dolt unknown NAO virou FAIL"
assert_push "P6 COM PROBLEMA (nao consegui olhar)" "COM PROBLEMA"
W_SENDER=error new_world p6b; write_pending "$(( $(now_s) - 300 ))"; run_pc
notify_has "sender unknown" && ok "P6 launchctl com erro -> sender unknown" || bad "P6 sender: $(cat "$NOTIFY_CALLS")"
W_MAP_CODE=000 W_MAP_RC=28 new_world p6c; write_pending "$(( $(now_s) - 300 ))"; run_pc
notify_has "map unknown" && ok "P6 origem do mapa sem resposta (rc 28, HTTP 000) -> map unknown" || bad "P6 map: $(cat "$NOTIFY_CALLS")"
W_DOLT_RC=127 new_world p6d; write_pending "$(( $(now_s) - 300 ))"; run_pc
notify_has "dolt unknown" && ok "P6 sonda com rc inesperado (127) -> unknown" || bad "P6 rc 127: $(cat "$NOTIFY_CALLS")"
new_world p6e; write_pending "$(( $(now_s) - 300 ))"; rm -f "$W/probe.sh"; run_pc
notify_has "dolt unknown" && ok "P6 sonda AUSENTE -> unknown (nao ok)" || bad "P6 sonda ausente: $(cat "$NOTIFY_CALLS")"

# ── P7: um servico sobe na 2a rodada ─────────────────────────────────────────
echo "P7: servico sobe na 2a rodada -> re-confere tudo, fecha ok"
W_SENDER=absent W_SENDER_OK_AT=2 new_world p7; write_pending "$(( $(now_s) - 300 ))"; run_pc
[ "$RC" = "0" ] && ok "P7 exit 0" || bad "P7 exit=$RC. out: $OUT"
notify_has "Reboot noturno OK" && ok "P7 notify de sucesso" || bad "P7 notify: $(cat "$NOTIFY_CALLS")"
notify_has "2 rodada(s)" && ok "P7 o notify diz que precisou de 2 rodadas" || bad "P7 notify sem contagem de rodadas: $(cat "$NOTIFY_CALLS")"
[ "$(cat "$W/n.probe")" = "2" ] && ok "P7 a rodada re-conferiu TODOS os checks (sonda 2x)" || bad "P7 sonda=$(cat "$W/n.probe")x"
log_has "retrying" && ok "P7 a rodada que falhou ficou no log" || bad "P7 sem 'retrying' no log"
[ "$(n_lines "$GC_CALLS")" = "0" ] && ok "P7 sem mail (terminou limpo)" || bad "P7 mandou mail"

# ── P8: envio ────────────────────────────────────────────────────────────────
echo "P8: envio"
W_SENDER=absent new_world p8a; write_pending "$(( $(now_s) - 300 ))"; run_pc
notify_has "sender FAIL" && ok "P8 job ausente -> FAIL" || bad "P8 ausente: $(cat "$NOTIFY_CALLS")"
notify_has "not loaded" && ok "P8 diz 'not loaded'" || bad "P8 sem 'not loaded'"
W_SENDER=nopid new_world p8b; write_pending "$(( $(now_s) - 300 ))"; run_pc
notify_has "sender FAIL" && ok "P8 carregado sem PID -> FAIL" || bad "P8 sem PID: $(cat "$NOTIFY_CALLS")"
notify_has "no PID" && ok "P8 diz 'no PID' e o ultimo exit" || bad "P8 sem 'no PID'"

W_SENDER=weird new_world p8c; write_pending "$(( $(now_s) - 300 ))"; run_pc
notify_has "sender unknown" && ok "P8 launchctl rc 0 mas sem dicionario de job -> unknown (nao 'sem PID' = FAIL)" || bad "P8 weird: $(cat "$NOTIFY_CALLS")"
echo "P8b: swap ilegivel nao pode parecer swap zerado"
new_world p8d; write_pending "$(( $(now_s) - 300 ))"; rm -rf "$W/vm"; run_pc
notify_has "swap: ?" && ok "P8b diretorio de swap ilegivel -> 'swap: ?'" || bad "P8b notify: $(cat "$NOTIFY_CALLS")"
notify_has "swap: 0" && bad "P8b disse 'swap: 0' sem ter olhado" || ok "P8b nao diz 'swap: 0' sem ter olhado"
[ "$RC" = "0" ] && ok "P8b o swap e informativo: nao muda o veredito" || bad "P8b exit=$RC"

# ── P9: mapa = origem + tunel ────────────────────────────────────────────────
# O veredito antigo vinha de https://mapa.urblink.com.br/, que fica atras do Cloudflare Access: sem
# credencial a BORDA responde 302 pro login antes de olhar a origem (medido 01/10: 302, server:
# cloudflare). Era 302 com o mapa de pe E com o mapa e o tunel mortos — "mapa ok" nunca podia ser
# outra coisa. O fake de curl agora responde 302 pra qualquer URL que nao seja a origem/o /ready,
# e grava toda URL chamada: o teste e se o veredito SEGUE a origem e o tunel, nao a borda.
echo "P9: mapa (origem + tunel; a borda publica nao entra)"
mapline() { grep -F -- 'map ' <<<"$OUT" | head -1; }
# a) origem respondendo (2xx/3xx) + tunel conectado -> ok
for c in 200 301 302; do
  W_MAP_CODE=$c new_world p9a; write_pending "$(( $(now_s) - 300 ))"; run_pc
  [ "$RC" = "0" ] && ok "P9 origem HTTP $c + tunel conectado -> ok" || bad "P9 origem HTTP $c exit=$RC. $(cat "$NOTIFY_CALLS")"
done
# b) o caso do bug: a ORIGEM esta fora (conexao recusada, rc 7) e a borda continua dando 302
W_MAP_CODE=000 W_MAP_RC=7 new_world p9b; write_pending "$(( $(now_s) - 300 ))"; run_pc
[ "$RC" = "1" ] && ok "P9 origem RECUSANDO conexao com a borda dando 302: exit 1 (o script antigo dava ok aqui)" || bad "P9 origem fora mas exit=$RC — o veredito segue a borda?"
notify_has "map FAIL" && ok "P9 origem recusando -> map FAIL" || bad "P9 origem recusando: $(cat "$NOTIFY_CALLS")"
notify_has "connection refused" && ok "P9 o aviso diz POR QUE (connection refused — nada escutando)" || bad "P9 sem o motivo: $(cat "$NOTIFY_CALLS")"
if grep -qvE '^(http://127\.0\.0\.1:8099/|http://127\.0\.0\.1:[0-9]+/ready)$' "$W/curl.urls" 2>/dev/null; then
  bad "P9 o script chamou uma URL que nao e a origem nem o /ready: $(grep -vE '^(http://127\.0\.0\.1:8099/|http://127\.0\.0\.1:[0-9]+/ready)$' "$W/curl.urls" | tr '\n' ' ')"
else
  ok "P9 so a origem e o /ready foram consultados — a URL publica nunca e chamada"
fi
# c) a origem fala 5xx
for c in 500 502 503; do
  W_MAP_CODE=$c new_world p9c; write_pending "$(( $(now_s) - 300 ))"; run_pc
  notify_has "map FAIL" && ok "P9 origem HTTP $c -> FAIL" || bad "P9 origem HTTP $c: $(cat "$NOTIFY_CALLS")"
done
# d) a origem nao deu uma resposta clara -> unknown (nao ok, nao FAIL)
for spec in "404:0" "403:0" "000:28" "garbage:0" "000:6"; do
  c="${spec%%:*}"; r="${spec##*:}"
  W_MAP_CODE=$c W_MAP_RC=$r new_world p9d; write_pending "$(( $(now_s) - 300 ))"; run_pc
  notify_has "map unknown" && ok "P9 origem HTTP '$c' curl rc $r -> unknown" || bad "P9 origem HTTP '$c' rc $r: $(cat "$NOTIFY_CALLS")"
  notify_has "map FAIL" && bad "P9 origem HTTP '$c' rc $r virou FAIL (colapsou 'nao sei' em 'caiu')" || ok "P9 origem HTTP '$c' rc $r NAO virou FAIL"
done
# e) tunel: o job do cloudflared
W_TUNNEL=absent new_world p9e; write_pending "$(( $(now_s) - 300 ))"; run_pc
notify_has "map FAIL" && ok "P9 tunel ausente no launchd -> map FAIL (origem ok nao salva)" || bad "P9 tunel ausente: $(cat "$NOTIFY_CALLS")"
notify_has "tunnel FAIL (br.urblink.cloudflared.urblink-ops is not loaded" && ok "P9 o aviso nomeia a METADE que caiu (tunnel) e o job" || bad "P9 sem a metade/o job: $(cat "$NOTIFY_CALLS")"
W_TUNNEL=nopid new_world p9e2; write_pending "$(( $(now_s) - 300 ))"; run_pc
notify_has "map FAIL" && ok "P9 tunel carregado sem PID -> map FAIL" || bad "P9 tunel sem PID: $(cat "$NOTIFY_CALLS")"
for m in error weird; do
  W_TUNNEL=$m new_world p9e3; write_pending "$(( $(now_s) - 300 ))"; run_pc
  notify_has "map unknown" && ok "P9 launchctl do tunel '$m' -> map unknown" || bad "P9 tunel '$m': $(cat "$NOTIFY_CALLS")"
done
# f) tunel com PID: quem decide e o /ready do proprio cloudflared (processo vivo != tunel conectado)
W_READY_BODY='{"status":503,"readyConnections":0}' new_world p9f; write_pending "$(( $(now_s) - 300 ))"; run_pc
notify_has "map FAIL" && ok "P9 tunel vivo mas readyConnections=0 -> map FAIL (um PID nao prova que o tunel carrega trafego)" || bad "P9 0 conexoes: $(cat "$NOTIFY_CALLS")"
notify_has "0 edge connections" && ok "P9 o aviso diz '0 edge connections'" || bad "P9 sem '0 edge connections': $(cat "$NOTIFY_CALLS")"
W_READY_BODY='{"status":200,"readyConnections":1}' new_world p9f2; write_pending "$(( $(now_s) - 300 ))"; run_pc
[ "$RC" = "0" ] && ok "P9 readyConnections=1 basta -> ok" || bad "P9 1 conexao exit=$RC. $(cat "$NOTIFY_CALLS")"
for spec in "refused:{}:7" "garbage:html-nao-json:0" "empty::0"; do
  IFS=: read -r nm body r <<<"$spec"; [ "$nm" = "refused" ] && body=""
  W_READY_BODY="$body" W_READY_RC=$r new_world p9g; write_pending "$(( $(now_s) - 300 ))"; run_pc
  notify_has "map unknown" && ok "P9 /ready sem resposta legivel ($nm) -> map unknown (nao ok: so o PID nao prova o tunel)" || bad "P9 /ready $nm: $(cat "$NOTIFY_CALLS")"
  notify_has "map FAIL" && bad "P9 /ready $nm virou FAIL (nao sei != caiu)" || ok "P9 /ready $nm NAO virou FAIL"
done
for m in none error missing; do
  W_LSOF=$m new_world p9h; write_pending "$(( $(now_s) - 300 ))"; run_pc
  notify_has "map unknown" && ok "P9 lsof '$m' (porta do /ready indescobrivel) -> map unknown" || bad "P9 lsof '$m': $(cat "$NOTIFY_CALLS")"
  notify_has "pid 42650 listening on" && ok "P9 lsof '$m': o aviso diz o que foi/nao foi achado" || bad "P9 lsof '$m' sem o detalhe: $(cat "$NOTIFY_CALLS")"
done
# a porta vem do PID vivo, nao de um numero escrito: 2 listeners (o 1o nao e o /ready) e IPv6 acham a certa
for m in multi ipv6; do
  W_LSOF=$m new_world p9i; write_pending "$(( $(now_s) - 300 ))"; run_pc
  [ "$RC" = "0" ] && ok "P9 lsof '$m' -> acha o /ready no listener certo -> ok" || bad "P9 lsof '$m' exit=$RC. $(cat "$NOTIFY_CALLS")"
done
# g) o pior dos dois vence, e o detalhe nomeia as duas metades
W_MAP_CODE=000 W_MAP_RC=7 W_TUNNEL=error new_world p9j; write_pending "$(( $(now_s) - 300 ))"; run_pc
notify_has "map FAIL" && ok "P9 origem FAIL + tunel unknown -> FAIL (FAIL vence unknown)" || bad "P9 FAIL+unknown: $(cat "$NOTIFY_CALLS")"
notify_has "origin FAIL (" && notify_has "tunnel unknown (" && ok "P9 o detalhe traz as DUAS metades com o estado de cada uma" || bad "P9 detalhe sem as duas metades: $(cat "$NOTIFY_CALLS")"
W_MAP_CODE=000 W_MAP_RC=28 W_TUNNEL=absent new_world p9k; write_pending "$(( $(now_s) - 300 ))"; run_pc
notify_has "map FAIL" && ok "P9 origem unknown + tunel FAIL -> FAIL" || bad "P9 unknown+FAIL: $(cat "$NOTIFY_CALLS")"
W_MAP_CODE=000 W_MAP_RC=28 new_world p9l; write_pending "$(( $(now_s) - 300 ))"; run_pc
notify_has "map unknown" && ok "P9 origem unknown + tunel ok -> unknown (so os DOIS ok dao ok)" || bad "P9 unknown+ok: $(cat "$NOTIFY_CALLS")"
W_TUNNEL=error new_world p9m; write_pending "$(( $(now_s) - 300 ))"; run_pc
notify_has "map unknown" && ok "P9 origem ok + tunel unknown -> unknown" || bad "P9 ok+unknown: $(cat "$NOTIFY_CALLS")"
# h) --now mostra a linha do mapa com as duas metades
new_world p9n; run_pc --now
grep -q '^map ok: origin ok (' <<<"$OUT" && grep -q 'tunnel ok (' <<<"$OUT" && ok "P9 --now: 'map ok: origin ok (...); tunnel ok (...)' (4 conexoes de borda no fake)" || bad "P9 --now: $(mapline)"
grep -q '4 edge connection(s) ready' <<<"$OUT" && ok "P9 --now: diz quantas conexoes de borda o tunel tem" || bad "P9 --now sem as conexoes: $(mapline)"

# ── P16: o filtro de problemas olha o ESTADO, nao o texto ────────────────────
# O aviso de problema lista so os checks que nao estao ok. Antes isso era `print_round | grep -v ' ok: '`:
# um check que FALHOU mas cujo detalhe (texto livre — a saida da sonda, "tunnel ok: ...") contem " ok: "
# era descartado como se estivesse ok, e o aviso saia sem a linha que explicava o problema.
echo "P16: um FAIL cujo detalhe contem ' ok: ' continua no aviso"
W_DOLT_RC=1 W_DOLT_OUT='unhealthy (the sender ok: fine, the map ok: fine — only dolt is down)' new_world p16; write_pending "$(( $(now_s) - 300 ))"; run_pc
notify_has "dolt FAIL" && ok "P16 'dolt FAIL' esta no aviso mesmo com ' ok: ' no detalhe" || bad "P16 a linha do dolt sumiu do aviso (filtro por texto?): $(cat "$NOTIFY_CALLS")"
notify_has "only dolt is down" && ok "P16 e o detalhe veio inteiro" || bad "P16 detalhe cortado: $(cat "$NOTIFY_CALLS")"
log_has "retrying" && grep -F 'retrying' "$LOGF" | grep -qF 'dolt FAIL' && ok "P16 a linha de 'retrying' do log tambem lista o dolt" || bad "P16 'retrying' sem o dolt: $(grep -F retrying "$LOGF" | head -1)"

# ── P10: dreno ───────────────────────────────────────────────────────────────
echo "P10: sinal de dreno"
new_world p10a; write_pending "$(( $(now_s) - 300 ))"
printf 'DRAIN\n%s\n%s\n%s\n' "$(now_s)" "$BOOT_NOW" "$(( $(now_s) + 3600 ))" > "$DRAIN"; run_pc
notify_has "drain FAIL" && ok "P10 sinal vivo NESTE boot -> FAIL" || bad "P10 vivo: $(cat "$NOTIFY_CALLS")"
[ -e "$DRAIN" ] && ok "P10 o postcheck NAO remove o sinal (o reboot e quem o invalida)" || bad "P10 removeu o sinal — nao e papel dele"
new_world p10b; write_pending "$(( $(now_s) - 300 ))"
printf 'DRAIN\n%s\n%s\n%s\n' "$(now_s)" "$BOOT_BEFORE" "$(( $(now_s) + 3600 ))" > "$DRAIN"; run_pc
[ "$RC" = "0" ] && ok "P10 sinal de OUTRO boot -> ok (os leitores o ignoram)" || bad "P10 outro boot exit=$RC. $(cat "$NOTIFY_CALLS")"
[ -e "$DRAIN" ] && ok "P10 sinal antigo continua no disco (nao e limpo aqui)" || bad "P10 removeu o sinal antigo"
new_world p10c; write_pending "$(( $(now_s) - 300 ))"
printf 'DRAIN\n123\nlixo\n999\n' > "$DRAIN"; run_pc
notify_has "drain unknown" && ok "P10 campo de boot ilegivel -> unknown" || bad "P10 ilegivel: $(cat "$NOTIFY_CALLS")"

echo "P10b: --now com kern.boottime ilegivel e um sinal de dreno presente"
W_BOOT=garbage new_world p10d
printf 'DRAIN\n%s\n%s\n%s\n' "$(now_s)" "$BOOT_NOW" "$(( $(now_s) + 3600 ))" > "$DRAIN"; run_pc --now
grep -q '^drain unknown:' <<<"$OUT" && ok "P10b sem o boot atual nao da pra dizer se o sinal e deste boot -> unknown (nao ok)" || bad "P10b saida: $(grep '^drain' <<<"$OUT")"
[ "$RC" = "1" ] && ok "P10b exit 1" || bad "P10b exit=$RC"
W_BOOT=garbage new_world p10e; run_pc --now
grep -q '^drain ok: no drain signal' <<<"$OUT" && ok "P10b sem sinal no disco, boottime ilegivel e irrelevante -> ok" || bad "P10b sem sinal: $(grep '^drain' <<<"$OUT")"

# ── P11: pendencia / boottime ilegiveis ──────────────────────────────────────
echo "P11: entradas ilegiveis"
new_world p11a; printf 'issued=abc\nboot_before=\n' > "$PENDING"; run_pc
[ "$RC" = "1" ] && ok "P11 pendencia ilegivel: exit 1" || bad "P11 pendencia ilegivel exit=$RC"
[ ! -e "$PENDING" ] && ok "P11 pendencia ilegivel descartada" || bad "P11 deixou a pendencia ilegivel"
notify_has "não conferido" && ok "P11 AVISA que nao conferiu (silencio seria 'tudo certo')" || bad "P11 sem aviso: $(cat "$NOTIFY_CALLS")"
assert_push "P11 'nao conferido'" "não conferido"
[ "$(n_lines "$PROBE_ARGS")" = "0" ] && ok "P11 nao conferiu servicos sem saber se o boot e nosso" || bad "P11 conferiu"
W_BOOT=garbage new_world p11b; write_pending "$(( $(now_s) - 300 ))"; run_pc
[ "$RC" = "1" ] && ok "P11 kern.boottime ilegivel: exit 1" || bad "P11 boottime exit=$RC"
[ -e "$PENDING" ] && ok "P11 mantem a pendencia (outro disparo pode conseguir ler)" || bad "P11 perdeu a pendencia"
[ "$(n_lines "$PROBE_ARGS")" = "0" ] && ok "P11 boottime ilegivel: nao conferiu" || bad "P11 conferiu sem saber se houve reboot"

# ── P12: trava de instancia unica ────────────────────────────────────────────
echo "P12: uma instancia por vez"
new_world p12a; write_pending "$(( $(now_s) - 300 ))"
sleep 30 & LIVE=$!
mkdir "$PENDING.lock.d"; echo "$LIVE" > "$PENDING.lock.d/pid"; run_pc
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
[ "$RC" = "0" ] && ok "P12 dono vivo: exit 0" || bad "P12 dono vivo exit=$RC"
[ "$(n_lines "$PROBE_ARGS")" = "0" ] && ok "P12 dono vivo: nao conferiu em duplicidade" || bad "P12 duas instancias conferiram"
[ -e "$PENDING" ] && ok "P12 dono vivo: pendencia intacta (e dele)" || bad "P12 mexeu na pendencia de outra instancia"
new_world p12b; write_pending "$(( $(now_s) - 300 ))"
sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null
mkdir "$PENDING.lock.d"; echo "$DEAD" > "$PENDING.lock.d/pid"; run_pc
[ "$RC" = "0" ] && notify_has "Reboot noturno OK" && ok "P12 dono MORTO: assume a trava e conclui (queda/power loss nao trava a conferencia)" || bad "P12 dono morto exit=$RC. $(cat "$NOTIFY_CALLS")"
[ ! -e "$PENDING.lock.d" ] && ok "P12 trava liberada no fim" || bad "P12 trava ficou"
# c) trava de OUTRO boot cujo pid hoje e de um processo VIVO e alheio (pids sao reaproveitados depois de
#    um reboot): sem o boot na trava, `kill -0` diria "instancia viva" e TODO login dali em diante sairia
#    mudo sem conferir nada
new_world p12c; write_pending "$(( $(now_s) - 300 ))"
sleep 30 & LIVE=$!
mkdir "$PENDING.lock.d"; echo "$LIVE" > "$PENDING.lock.d/pid"; echo "$((BOOT_BEFORE - 7))" > "$PENDING.lock.d/boot"; run_pc
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
[ "$RC" = "0" ] && notify_has "Reboot noturno OK" && ok "P12 trava de OUTRO boot com pid vivo e alheio: assume e conclui (nao fica mudo)" || bad "P12 trava de outro boot: exit=$RC, notify=$(cat "$NOTIFY_CALLS"), out=$OUT"
log_has "stale lock" && ok "P12 o log diz que a trava era de outro boot" || bad "P12 sem 'stale lock' no log"
[ ! -e "$PENDING.lock.d" ] && ok "P12 trava liberada no fim (pid E boot removidos)" || bad "P12 trava ficou: $(ls "$PENDING.lock.d" 2>/dev/null | tr '\n' ' ')"
# d) trava do MESMO boot com dono vivo: continua valendo
new_world p12d; write_pending "$(( $(now_s) - 300 ))"
sleep 30 & LIVE=$!
mkdir "$PENDING.lock.d"; echo "$LIVE" > "$PENDING.lock.d/pid"; echo "$BOOT_NOW" > "$PENDING.lock.d/boot"; run_pc
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
[ "$(n_lines "$PROBE_ARGS")" = "0" ] && ok "P12 trava do MESMO boot, dono vivo: nao conferiu em duplicidade" || bad "P12 duas instancias conferiram (trava do mesmo boot ignorada)"
log_has "another postcheck instance" && ok "P12 o log diz que outra instancia segura a trava" || bad "P12 sem a linha 'another postcheck instance'"
# e) NAO consegui ler o meu proprio boot: "nao sei" nao pode virar "a trava e de outro boot" —
#    estado inerte (respeita a trava), nunca o destrutivo (tomar uma trava que pode ser viva)
W_BOOT=garbage new_world p12e; write_pending "$(( $(now_s) - 300 ))"
sleep 30 & LIVE=$!
mkdir "$PENDING.lock.d"; echo "$LIVE" > "$PENDING.lock.d/pid"; echo "$BOOT_BEFORE" > "$PENDING.lock.d/boot"; run_pc
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
log_has "stale lock" && bad "P12 boot ilegivel do nosso lado virou 'trava de outro boot' (colapsou 'nao sei' em 'sim')" || ok "P12 boot ilegivel do nosso lado: NAO toma a trava"
[ -e "$PENDING.lock.d/pid" ] && ok "P12 a trava do dono vivo ficou intacta" || bad "P12 tomou/desfez uma trava de dono vivo sem saber o boot"

# ── P13: --now ───────────────────────────────────────────────────────────────
echo "P13: --now (sem efeito colateral)"
new_world p13a; write_pending "$(( $(now_s) - 300 ))"; run_pc --now
[ "$RC" = "0" ] && ok "P13 --now tudo ok: exit 0" || bad "P13 exit=$RC. out: $OUT"
[ "$(grep -c '^\(dolt\|sender\|map\|drain\) ok:' <<<"$OUT")" = "4" ] && ok "P13 uma linha por check (4)" || bad "P13 saida: $OUT"
[ "$(n_lines "$NOTIFY_CALLS")" = "0" ] && ok "P13 sem notify" || bad "P13 notificou"
[ -e "$PENDING" ] && ok "P13 pendencia intocada" || bad "P13 removeu a pendencia"
[ ! -s "$LOGF" ] && ok "P13 sem log" || bad "P13 escreveu no log"
[ "$(n_lines "$GC_CALLS")" = "0" ] && ok "P13 sem mail" || bad "P13 mandou mail"
W_DOLT_RC=1 new_world p13b; run_pc --now
[ "$RC" = "1" ] && ok "P13 --now com FAIL: exit 1" || bad "P13 exit=$RC"
grep -q '^dolt FAIL:' <<<"$OUT" && ok "P13 mostra o rotulo FAIL" || bad "P13 saida: $OUT"
run_pc --lixo
[ "$RC" = "2" ] && ok "P13 argumento invalido: exit 2" || bad "P13 arg invalido exit=$RC"
grep -q '^usage:' <<<"$OUT" && ok "P13 imprime usage" || bad "P13 sem usage"

# ── P14: estatico — a sonda nunca e carregada, o dump nunca e chamado ────────
echo "P14: estatico"
CODE="$(grep -vE '^[[:space:]]*#' "$SCRIPT")"
grep -qE '(^|[;&|[:space:]])(source|\.)[[:space:]]+[^#]*(gc-dolt-probe|DOLT_PROBE)' <<<"$CODE" \
  && bad "P14 o script carrega (source) a sonda — traz junto o kill -QUIT" || ok "P14 a sonda e chamada como subprocesso (nunca source)"
grep -qE 'goroutine_dump|kill -QUIT|kill -3' <<<"$CODE" \
  && bad "P14 o script chama o goroutine dump / SIGQUIT (derruba um Dolt vivo)" || ok "P14 nenhum caminho de codigo chama SIGQUIT"
grep -qF -- '--robust' <<<"$CODE" && ok "P14 usa --robust" || bad "P14 nao usa --robust"
grep -qE 'rm -rf' <<<"$CODE" && bad "P14 usa rm -rf (ga-gkap9p)" || ok "P14 sem rm -rf"
grep -qiE 'mapa\.urblink|cloudflareaccess|https?://[a-z0-9.-]+\.com' <<<"$CODE" \
  && bad "P14 o codigo menciona a URL publica do mapa / um host externo — o veredito do mapa nao pode vir da borda (Cloudflare Access responde 302 la, com o mapa de pe ou nao)" \
  || ok "P14 nenhuma URL externa no codigo: o mapa e julgado pela origem (loopback) e pelo tunel"

# ── P15: contrato com o nightly-reboot.sh (quem ESCREVE a pendencia e o dreno) ──
# Dois scripts escritos em separado concordam em chaves e caminhos por convencao. Se um
# renomear uma chave, a conferencia veria "pendencia ilegivel" toda noite — silenciosamente.
echo "P15: contrato com nightly-reboot.sh"
NIGHTLY="$SELF_DIR/nightly-reboot.sh"
if [ -f "$NIGHTLY" ]; then
  W_FMT="$(grep -E "printf 'issued=%s" "$NIGHTLY" | head -1)"
  for k in issued boot_before mode; do
    case "$W_FMT" in *"$k=%s"*) ok "P15 o reboot escreve a chave '$k'" ;; *) bad "P15 o reboot nao escreve '$k=' (linha: $W_FMT)" ;; esac
    grep -qE "pending_field $k\b" "$SCRIPT" && ok "P15 a conferencia le a chave '$k'" || bad "P15 a conferencia nao le '$k'"
  done
  d_pending="$(sed -n 's/^PENDING_FILE="\${NIGHTLY_REBOOT_PENDING_FILE:-\(.*\)}"$/\1/p' "$NIGHTLY" | head -1)"
  p_pending="$(sed -n 's/^PENDING_FILE="\${NIGHTLY_REBOOT_PENDING_FILE:-\(.*\)}"$/\1/p' "$SCRIPT" | head -1)"
  [ -n "$d_pending" ] && [ "$d_pending" = "$p_pending" ] && ok "P15 mesmo caminho default da pendencia ($d_pending)" || bad "P15 caminhos da pendencia divergem: reboot='$d_pending' conferencia='$p_pending'"
  d_drain="$(sed -n 's/^DRAIN_FILE="\${NIGHTLY_REBOOT_DRAIN_FILE:-\(.*\)}"$/\1/p' "$NIGHTLY" | head -1)"
  p_drain="$(sed -n 's/^DRAIN_FILE="\${NIGHTLY_REBOOT_DRAIN_FILE:-\(.*\)}"$/\1/p' "$SCRIPT" | head -1)"
  [ -n "$d_drain" ] && [ "$d_drain" = "$p_drain" ] && ok "P15 mesmo caminho default do sinal de dreno ($d_drain)" || bad "P15 caminhos do dreno divergem: reboot='$d_drain' conferencia='$p_drain'"
  grep -q 'drain_stamp()' "$NIGHTLY" && grep -qF "printf 'DRAIN\\n%s\\n%s\\n%s\\n'" "$NIGHTLY" \
    && ok "P15 o sinal tem o formato DRAIN|escrito|boot|ate que a conferencia le (boot = linha 3)" || bad "P15 formato do sinal de dreno mudou — a conferencia le a linha 3 como boot-epoch"
else
  bad "P15 nightly-reboot.sh nao esta ao lado — nao da pra conferir o contrato"
fi

echo ""
echo "nightly-reboot-postcheck selftest: PASS=$PASS FAIL=$FAIL SKIPPED=$SKIPPED"
[ "$FAIL" -eq 0 ]
