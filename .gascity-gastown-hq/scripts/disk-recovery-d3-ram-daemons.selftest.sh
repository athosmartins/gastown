#!/usr/bin/env bash
# disk-recovery-d3-ram-daemons.selftest.sh — testa o degrau D3 da escada de disco (ga-1p1i5jr.3) SEM tocar na máquina.
#
# ## Contents
#   O que é simulado · O que é verificado · Como rodar
#
# O QUE É SIMULADO  launchctl (list/kickstart), ps, footprint, curl (API do demand-dashboard e as portas), df e sysctl são shims no PATH; os bancos de ligação são sqlite REAIS e temporários
#   (pix_call_log e voicebot_call_log); o restart guardado, o deploy_freeze e o relógio do disco (arquivos DR_FREE_MB_FILE / DR_SWAP_MB_FILE) são stubs. Nada real é reiniciado, pausado ou enviado.
# O QUE É VERIFICADO  saída = UMA linha, ASCII, ≤ 290, nada antes dela (stdout+stderr juntos, como o maestro lê) e rc 0/10/20/30/2 em cada cenário · fronteiras (livre 4608/4609, idade 3599/3600 s,
#   footprint 99/100 MB, janela de ligação 1799/1801 s) · ordem por footprint e parada ao recuperar · só labels da allowlist · cada guarda de ligação (pix dialing/bridged, voicebot live, banco
#   ausente/corrompido/sem tabela = não sei), e a guarda de novo ENTRE um daemon e o seguinte · freeze (congelado, livre, ilegível) · prova do restart (PID novo + porta; kickstart que falha,
#   mesmo PID, porta fora, 4xx) · demand-dashboard pelo guardado (argumentos, env, notify desligado, pausa nossa que sobra é desfeita E lida de volta, pausa alheia intocada, despausa recusada,
#   daemon voltando devagar, guardado que estoura o tempo, sobra de rodada anterior) · TERM no meio do guardado despausa a fila · orçamento de tempo · trava (viva, morta, solta no fim) ·
#   interruptor · dry-run sem efeito colateral · df/swap lidos do jeito certo (nunca `df /`) e ilegíveis = 30 · variável numérica inválida · rotação do log · bancos só lidos.
# COMO RODAR      bash scripts/disk-recovery-d3-ram-daemons.selftest.sh        (~1-3 min)
#   Para testar uma cópia modificada do degrau (mutantes): DR_D3_PATH=/caminho/disk-recovery-d3-ram-daemons.mutN.sh bash scripts/disk-recovery-d3-ram-daemons.selftest.sh
set -uo pipefail
ulimit -f 40960 2>/dev/null   # nenhum arquivo deste teste passa de 20 MB (disco apertado é o assunto)

HERE="$(cd "$(dirname "$0")" && pwd)"
D3="${DR_D3_PATH:-$HERE/disk-recovery-d3-ram-daemons.sh}"
[ -f "$D3" ] || { echo "FATAL: degrau nao encontrado em $D3"; exit 1; }
for _v in $(compgen -e | grep '^DR_'); do [ "$_v" = DR_D3_PATH ] || unset "$_v"; done

W="$(mktemp -d "${TMPDIR:-/tmp}/dr-d3-selftest.XXXXXX")" || { echo "FATAL: mktemp"; exit 1; }
case "$W" in */dr-d3-selftest.??????) ;; *) echo "FATAL: diretorio de trabalho estranho: $W"; exit 1 ;; esac
BG_PIDS=""
cleanup() { local p; for p in $BG_PIDS; do kill "$p" 2>/dev/null; done; chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
SD="$W/sd"; BIN="$W/bin"; CITY="$W/city"; WA="$W/wa"; PIX="$W/pix.db"; VOICE="$W/voice.db"
LOG="$CITY/.gc/logs/disk-recovery-d3.log"; LOCK="$CITY/.gc/disk-recovery-d3.lock"; OFF="$CITY/.gc/disk-recovery.off"
mkdir -p "$BIN" "$W/tmp" "$W/home" "$WA"
PASS=0; FAIL=0; OUT=""; RC=0; EXTRA_ENV=""
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed 's/^/        | /' | tail -n 8; return 0; }
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else nope "$3 (obtido '$1', esperado '$2')"; fi; }
has()   { if printf '%s' "$1" | grep -q -F -- "$2"; then ok "$3"; else nope "$3 (faltou: $2)"; fi; }
hasnt() { if printf '%s' "$1" | grep -q -F -- "$2"; then nope "$3 (nao devia ter: $2)"; else ok "$3"; fi; }
section() { printf '\n== %s\n' "$1"; }

# ── shims ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
cat > "$BIN/launchctl" <<'SH'
#!/bin/bash
S="$STUB_DIR"
case "${1:-}" in
  list)
    [ -f "$S/launchctl.listfail" ] && { echo "launchctl: falhou" >&2; exit 1; }
    [ -f "$S/launchctl.listempty" ] && exit 0
    printf 'PID\tStatus\tLabel\n'
    printf -- '-\t0\tcom.apple.algo\n'
    while read -r label pid et fp unit; do printf '%s\t0\t%s\n' "$pid" "$label"; done < "$S/procs"
    if [ -f "$S/launchctl.big" ]; then awk 'BEGIN { for (i = 0; i < 4000; i++) printf "-\t0\tcom.apple.filler.%0200d\n", i }'; fi
    exit 0
    ;;
  kickstart)
    shift; [ "${1:-}" = "-k" ] && shift
    svc=$1; label=${svc##*/}
    echo "kickstart $svc" >> "$S/calls"
    rc=0; mode=ok; setfree=""; newfp=80; hook=""
    [ -f "$S/kick.$label" ] && . "$S/kick.$label"
    [ "$rc" -ne 0 ] && { echo "kickstart: falhou" >&2; exit "$rc"; }
    case "$mode" in
      ok) n=$(( $(cat "$S/counter") + 1 )); echo "$n" > "$S/counter"
          awk -v l="$label" -v n="$n" -v f="$newfp" '$1==l {$2=n; $3="00:02"; $4=f; $5="MB"} {print}' "$S/procs" > "$S/procs.new" && mv "$S/procs.new" "$S/procs" ;;
      samepid) ;;
      down) awk -v l="$label" '$1==l {$2="-"} {print}' "$S/procs" > "$S/procs.new" && mv "$S/procs.new" "$S/procs" ;;
    esac
    [ -n "$setfree" ] && printf '%s' "$setfree" > "$S/free"
    [ -n "$hook" ] && eval "$hook"
    exit 0 ;;
  *) exit 0 ;;
esac
SH
cat > "$BIN/ps" <<'SH'
#!/bin/bash
pid=""; while [ $# -gt 0 ]; do case "$1" in -p) pid=$2; shift ;; esac; shift; done
[ -f "$STUB_DIR/ps.fail" ] && exit 1
[ -f "$STUB_DIR/ps.garbage.$pid" ] && { echo "lixo"; exit 0; }
awk -v p="$pid" '$2==p {print "  " $3; f=1} END {exit f ? 0 : 1}' "$STUB_DIR/procs"
SH
cat > "$BIN/footprint" <<'SH'
#!/bin/bash
pid=$2
[ -f "$STUB_DIR/fp.fail.$pid" ] && exit 1
[ -f "$STUB_DIR/fp.garbage.$pid" ] && { echo "nada aqui"; exit 0; }
line=$(awk -v p="$pid" '$2==p {print $4, $5}' "$STUB_DIR/procs"); [ -n "$line" ] || exit 1
set -- $line
printf 'Python [%s]: 64-bit    Footprint: %s %s (16384 bytes per page)\n\n    phys_footprint: %s %s\n    phys_footprint_peak: 9999 MB\n' "$pid" "$1" "$2" "$1" "$2"
SH
cat > "$BIN/curl" <<'SH'
#!/bin/bash
S="$STUB_DIR"; method=GET; body=""; fmt=""; out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift ;; -d) body=$2; shift ;; -w) fmt=$2; shift ;; -o) out=$2; shift ;; -m|-H) shift ;;
    -*) ;; *) url=$1 ;;
  esac
  shift
done
port=$(printf '%s' "$url" | sed -n 's#^http://[^:/]*:\([0-9]*\)/.*#\1#p')
code=200; bodyout=""
if [ "$port" = 8095 ]; then
  if [ -f "$S/dd_down_n" ]; then n=$(cat "$S/dd_down_n"); if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$S/dd_down_n"; exit 7; fi; fi
  dm=ok; [ -f "$S/dd_mode" ] && dm=$(cat "$S/dd_mode")
  case "$dm" in
    down) exit 7 ;;
    http500) code=500 ;;
    garbage) bodyout="isto nao e json" ;;
    patch400) [ "$method" = PATCH ] && code=400 ;;
  esac
  case "$url" in
    */api/outreach/config)
      if [ "$method" = PATCH ]; then
        if [ "$code" = 200 ]; then
          sp=$(printf '%s' "$body" | jq -r .system_paused); by=$(printf '%s' "$body" | jq -r .system_paused_by)
          printf '%s|%s' "$sp" "$by" > "$S/dd_config"; echo "PATCH sp=$sp by=$by" >> "$S/calls"
        else echo "PATCH-RECUSADO" >> "$S/calls"; fi
        bodyout='{"ok":true}'
      elif [ -z "$bodyout" ]; then
        IFS='|' read -r sp by < "$S/dd_config"
        if [ -f "$S/dd_numeric" ]; then bodyout=$(jq -cn --argjson p "$sp" --arg by "$by" '{system_paused:$p, system_paused_by:$by}')
        else bodyout=$(jq -cn --arg p "$sp" --arg by "$by" '{system_paused:$p, system_paused_by:$by}'); fi
      fi ;;
  esac
else
  c=200; [ -f "$S/port.$port" ] && c=$(cat "$S/port.$port")
  [ "$c" = down ] && exit 7
  code=$c
fi
case "$fmt" in
  *'\n%{http_code}'*) printf '%s\n%s' "$bodyout" "$code" ;;
  *'%{http_code}'*) printf '%s' "$code" ;;
  *) [ "$out" = /dev/null ] || printf '%s' "$bodyout" ;;
esac
exit 0
SH
cat > "$BIN/df" <<'SH'
#!/bin/bash
echo "df $*" >> "$STUB_DIR/calls"
[ -f "$STUB_DIR/df.fail" ] && exit 1
printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\n'
if [ "${*: -1}" = "/System/Volumes/Data" ]; then
  printf '/dev/disk3s5 471000 466700 %s 99%% %s\n' "$(cat "$STUB_DIR/df.avail")" "${DF_MOUNT:-/System/Volumes/Data}"
else
  printf '/dev/disk3s1s1 471000 12000 90000 12%% /\n'
fi
SH
cat > "$BIN/sysctl" <<'SH'
#!/bin/bash
[ -f "$STUB_DIR/sysctl.fail" ] && exit 1
cat "$STUB_DIR/sysctl.out"
SH
chmod 755 "$BIN"/*
cat > "$W/guarded" <<'SH'
#!/bin/bash
S="$STUB_DIR"
echo "guarded $* | DRAIN=${GUARDED_RESTART_DRAIN_TIMEOUT:-} READY=${GUARDED_RESTART_READY_TIMEOUT:-} NOTIFY=${GUARDED_RESTART_NOTIFY_BIN:-} URL=${DEMAND_DASHBOARD_URL:-}" >> "$S/calls"
mode=ok; [ -f "$S/guarded.mode" ] && mode=$(cat "$S/guarded.mode")
agent=$1; bead=${2:-}
pause()   { printf '1|%s' "$agent: restart guardado $bead" > "$S/dd_config"; }
unpause() { printf '0|%s' "$agent: fim do restart guardado $bead" > "$S/dd_config"; }
kick()    { launchctl kickstart -k "gui/501/com.whatsapp.demand-dashboard"; }
case "$mode" in
  ok)               pause; kick; unpause; echo "VEREDITO: OK"; exit 0 ;;
  leave_paused)     pause; kick; echo "VEREDITO: OK"; exit 0 ;;
  fail_after_pause) pause; echo "VEREDITO: FALHOU - OutreachWorker nao drenou"; exit 1 ;;
  fail_nopause)     echo "VEREDITO: FALHOU - GET inicial nao conectou"; exit 1 ;;
  foreign)          kick; echo "VEREDITO: OK - pausa alheia mantida"; exit 0 ;;
  nopid)            pause; unpause; echo "VEREDITO: OK"; exit 0 ;;
  slow)             pause; echo started > "$S/guarded.started"; sleep 60; exit 0 ;;
esac
SH
cat > "$W/freeze" <<'SH'
#!/bin/bash
label=$2; echo "freeze $*" >> "$STUB_DIR/calls"
rc=10; [ -f "$STUB_DIR/freeze.$label" ] && rc=$(cat "$STUB_DIR/freeze.$label")
exit "$rc"
SH
chmod 755 "$W/guarded" "$W/freeze"

# ── cenário ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
mkdbs() {
  rm -f "$PIX" "$VOICE"
  sqlite3 "$PIX" "CREATE TABLE pix_call_log (call_id TEXT, phone_norm TEXT, state TEXT NOT NULL DEFAULT 'dialing', started_at TEXT DEFAULT (datetime('now','localtime')), updated_at TEXT DEFAULT (datetime('now','localtime')));"
  sqlite3 "$VOICE" "CREATE TABLE voicebot_call_log (call_id TEXT, status TEXT NOT NULL DEFAULT 'live', started_at TEXT DEFAULT (datetime('now','localtime')), updated_at TEXT DEFAULT (datetime('now','localtime')));"
}
addpix()   { sqlite3 "$PIX" "INSERT INTO pix_call_log (call_id, phone_norm, state, started_at, updated_at) VALUES ('c$RANDOM', '5511', '$1', datetime('now','localtime','-$2 seconds'), datetime('now','localtime','-$2 seconds'));"; }
addvoice() { sqlite3 "$VOICE" "INSERT INTO voicebot_call_log (call_id, status, started_at, updated_at) VALUES ('v$RANDOM', '$1', datetime('now','localtime','-$2 seconds'), datetime('now','localtime','-$2 seconds'));"; }
hookfor() {  # $1=label $2..=comando que o kickstart roda DEPOIS de reiniciar (efeito colateral simulado)
  local l=$1; shift; printf '%s\n' "$*" > "$SD/hook.$l.sh"; printf 'hook="bash %s/hook.%s.sh"\n' "$SD" "$l" >> "$SD/kick.com.whatsapp.$l"
}
setproc()  { awk -v l="com.whatsapp.$1" -v f="$2" -v v="$3" '$1==l {$f=v} {print}' "$SD/procs" > "$SD/procs.new" && mv "$SD/procs.new" "$SD/procs"; }   # campos: 2=pid 3=etime 4=fp 5=unidade
reset() {
  rm -rf "$SD" "$CITY"; mkdir -p "$SD" "$CITY/.gc/logs" "$W/tmp"; rm -f "$W/tmp"/* 2>/dev/null
  cat > "$SD/procs" <<'EOF'
com.whatsapp.demand-dashboard 1001 05:00:00 500 MB
com.whatsapp.map-viewer 1002 02:10:04 700 MB
com.whatsapp.ficha360 1003 07:34:47 140 MB
com.whatsapp.clientes-dashboard 1004 03:00:00 73 MB
EOF
  echo 2000 > "$SD/counter"; printf '3000' > "$SD/free"; printf '4800' > "$SD/swap"; printf '0|' > "$SD/dd_config"
  : > "$SD/calls"; mkdbs; EXTRA_ENV=""
}
run_d3() {
  [ $# -gt 0 ] || set -- --run
  OUT=$(env -i HOME="$W/home" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$W/tmp" STUB_DIR="$SD" \
      DR_CITY="$CITY" DR_D3_WA="$WA" DR_D3_PIX_DB="$PIX" DR_D3_VOICE_DB="$VOICE" DR_D3_GUARDED="$W/guarded" DR_D3_FREEZE_CMD="$W/freeze" \
      DR_FREE_MB_FILE="$SD/free" DR_SWAP_MB_FILE="$SD/swap" DR_D3_SETTLE_S=0 DR_D3_READY_S=3 DR_D3_DRAIN_S=3 DR_D3_DESPAUSE_S=3 DR_D3_GUARD_SLACK_S=2 DR_D3_CMD_S=5 DR_D3_CURL_S=2 \
      $EXTRA_ENV "$D3" "$@" 2>&1); RC=$?
  CALLS=$(cat "$SD/calls" 2>/dev/null)
  SEQ=$(printf '%s\n' "$CALLS" | awk '/^kickstart/ {sub(/.*com\.whatsapp\./, ""); printf "%s,", $0} /^guarded/ {printf "G,"}')
}
expect() {  # $1=rc $2=trecho da linha (ou vazio) $3=descrição — rc, UMA linha só (stdout+stderr), ASCII, <= 290, e o trecho
  local want=$1 frag=$2 desc=$3 nl bad=""
  nl=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
  [ "$RC" = "$want" ] || bad="rc=$RC (esperado $want)"
  [ "$nl" = 1 ] && [ -n "$OUT" ] || bad="$bad; saida com $nl linhas"
  [ "${#OUT}" -le 290 ] || bad="$bad; linha com ${#OUT} caracteres"
  [ -z "$(printf '%s' "$OUT" | LC_ALL=C tr -d '\0-\177')" ] || bad="$bad; nao-ASCII"
  if [ -n "$frag" ] && ! printf '%s' "$OUT" | grep -q -F -- "$frag"; then bad="$bad; faltou '$frag'"; fi
  if [ -z "$bad" ]; then ok "$desc"; else nope "$desc ($bad)"; fi
}
kicks() { printf '%s' "$SEQ"; }
npatch() { printf '%s\n' "$CALLS" | grep -c '^PATCH ' ; }
lockgone() { if [ ! -d "$LOCK" ]; then ok "$1: trava solta no fim"; else nope "$1: trava ficou"; fi; }

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
section "uso, interruptor, disco já recuperado, fronteira 4608/4609"
reset; run_d3 --foo; eq "$RC" 2 "argumento errado: rc 2"; has "$OUT" "uso:" "argumento errado: diz o uso"
reset; run_d3 --run extra >/dev/null 2>&1; eq "$RC" 2 "argumento a mais: rc 2"; eq "$(kicks)" "" "argumento a mais: nada reiniciado"
reset; printf '9000' > "$SD/free"; run_d3; expect 10 "ja recuperado" "livre 9000: nada a fazer"; eq "$(kicks)" "" "livre 9000: nada reiniciado"; lockgone "livre 9000"
reset; printf '4609' > "$SD/free"; run_d3; expect 10 "ja recuperado" "livre 4609 (> 4608): nada a fazer"
reset; printf '4608' > "$SD/free"; run_d3; expect 0 "map-viewer" "livre 4608 (nao e > 4608): age"
reset; touch "$OFF"; run_d3; expect 10 "desligado" "interruptor ligado: sai 10"; eq "$CALLS" "" "interruptor ligado: nenhum comando rodou"
reset; printf '4609' > "$SD/free"; run_d3 --dry-run; expect 10 "DRY-RUN D3 nada a fazer" "dry-run com disco recuperado"

section "df e swap lidos do jeito certo (nunca df /) e ilegíveis = 30"
reset; EXTRA_ENV="DR_FREE_MB_FILE= DR_SWAP_MB_FILE="; printf '4300' > "$SD/df.avail"; printf 'total = 6144.00M  used = 4876.50M  free = 1267.50M  (encrypted)' > "$SD/sysctl.out"
run_d3; expect 0 "livre 4300->" "df: lido do volume Data (4300), nao do /"; has "$OUT" "swap 4876->" "sysctl: used = 4876.50M vira 4876"
has "$CALLS" "df -Pm /System/Volumes/Data" "df chamado com -Pm no volume Data"; eq "$(printf '%s\n' "$CALLS" | grep -c -x -E 'df +(-[A-Za-z]+ +)*/')" 0 "df nunca chamado com / (so o volume Data)"
reset; EXTRA_ENV="DR_FREE_MB_FILE= DR_SWAP_MB_FILE="; printf '4300' > "$SD/df.avail"; printf 'total = 8.00G  used = 4.50G  free = 3.50G' > "$SD/sysctl.out"
run_d3; has "$OUT" "swap 4608->" "sysctl: used = 4.50G vira 4608"
reset; EXTRA_ENV="DR_FREE_MB_FILE= DR_SWAP_MB_FILE="; printf '4300' > "$SD/df.avail"; printf 'total = 6144.00M  used = 12K  free = 1M' > "$SD/sysctl.out"
run_d3; expect 30 "nao consegui ler" "swap com unidade K: ilegivel = 30"; eq "$(kicks)" "" "swap ilegivel: nada reiniciado"
reset; EXTRA_ENV="DR_FREE_MB_FILE= DR_SWAP_MB_FILE="; printf '4300' > "$SD/df.avail"; touch "$SD/sysctl.fail"; run_d3; expect 30 "swap" "sysctl falha: 30"
reset; EXTRA_ENV="DR_FREE_MB_FILE= DR_SWAP_MB_FILE="; printf '4300' > "$SD/df.avail"; printf 'used = 4G' > "$SD/sysctl.out"; touch "$SD/df.fail"; run_d3; expect 30 "df do volume Data ilegivel" "df falha: 30"
reset; EXTRA_ENV="DR_FREE_MB_FILE= DR_SWAP_MB_FILE= DF_MOUNT=/"; printf '4300' > "$SD/df.avail"; printf 'used = 4096.0M' > "$SD/sysctl.out"; run_d3; expect 30 "df do volume Data ilegivel" "df de outro ponto de montagem: 30"
reset; printf 'abc' > "$SD/free"; run_d3; expect 30 "ilegivel" "livre com lixo: 30"
reset; rm -f "$SD/swap"; run_d3; expect 30 "swap" "arquivo de swap ausente: 30"; eq "$(kicks)" "" "swap ausente: nada reiniciado"
reset; run_d3 --dry-run; EXTRA_ENV=""; reset; rm -f "$SD/free"; run_d3 --dry-run; expect 30 "DRY-RUN D3 nao consegui ler" "dry-run com df ilegivel: 30"

section "ordem por footprint, parada ao recuperar, allowlist"
reset; echo 'setfree=4700' > "$SD/kick.com.whatsapp.map-viewer"; run_d3
expect 0 "reiniciei map-viewer pid 1002->2001" "recuperou no 1o: reinicia so o maior (map-viewer)"; eq "$(kicks)" "map-viewer," "recuperou no 1o: um kickstart so"
has "$OUT" "parei: disco recuperado" "recuperou no 1o: diz por que parou"; has "$OUT" "700->80 MB porta 8099 ok" "recuperou no 1o: footprint antes->depois e porta"; has "$OUT" "livre 3000->4700" "recuperou no 1o: livre antes->depois"; lockgone "recuperou no 1o"
reset; echo 'setfree=3500' > "$SD/kick.com.whatsapp.map-viewer"; echo 'setfree=3800' > "$SD/kick.com.whatsapp.ficha360"; run_d3
expect 0 "reiniciei" "nao recuperou: continua pelos demais"; eq "$(kicks)" "map-viewer,G,demand-dashboard,ficha360," "ordem map-viewer(700) > demand-dashboard(500) > ficha360(140); clientes(73) fora"
has "$OUT" "clientes-dashboard (73 MB < 100 MB)" "clientes-dashboard pulado por tamanho"
reset; setproc ficha360 4 900; run_d3; eq "$(kicks | cut -d, -f1)" "ficha360" "ordem segue o footprint de AGORA (ficha360 900 vira o primeiro)"
reset; setproc map-viewer 4 500; run_d3; eq "$(kicks | cut -d, -f1-2)" "G,demand-dashboard" "empate de footprint: ordem da lista (demand-dashboard antes)"
reset; setproc demand-dashboard 4 1.5 ; setproc demand-dashboard 5 GB; run_d3 --dry-run; has "$OUT" "demand-dashboard (1536 MB)" "footprint em GB convertido (1.5 GB = 1536 MB)"
reset; setproc demand-dashboard 4 800000 ; setproc demand-dashboard 5 KB; run_d3 --dry-run; has "$OUT" "demand-dashboard (781 MB)" "footprint em KB convertido"
reset; setproc map-viewer 4 99; run_d3 --dry-run; has "$OUT" "map-viewer (99 MB < 100 MB)" "footprint 99 MB: pulado"
reset; setproc map-viewer 4 100; run_d3 --dry-run; has "$OUT" "map-viewer (100 MB)" "footprint 100 MB: elegivel"
reset; for n in 1 2 3; do :; done; run_d3
bad=$(printf '%s\n' "$CALLS" | grep '^kickstart' | grep -v -E 'gui/[0-9]+/com\.whatsapp\.(demand-dashboard|map-viewer|ficha360|clientes-dashboard)$' || true)
eq "$bad" "" "so labels da allowlist foram reiniciados"
reset; EXTRA_ENV="DR_D3_PIX_DB=$W/nao-existe.db"; run_d3; expect 30 "pix=?" "banco pix ausente: 30, sem reiniciar"; eq "$(kicks)" "" "banco pix ausente: nada reiniciado"; [ ! -e "$W/nao-existe.db" ] && ok "banco ausente NAO e criado" || nope "banco ausente foi criado"

section "elegibilidade: congelado, idade, parado, leituras ilegíveis"
reset; echo 0 > "$SD/freeze.com.whatsapp.map-viewer"; run_d3; expect 0 "map-viewer (congelado" "map-viewer congelado: pulado"; hasnt "$(kicks)" "map-viewer" "map-viewer congelado: nao reiniciado"
reset; for l in demand-dashboard map-viewer ficha360 clientes-dashboard; do echo 3 > "$SD/freeze.com.whatsapp.$l"; done; run_d3; expect 30 "deploy_freeze ilegivel" "freeze ilegivel em todos: 30"; eq "$(kicks)" "" "freeze ilegivel: nada reiniciado"
reset; echo 3 > "$SD/freeze.com.whatsapp.map-viewer"; run_d3; expect 0 "map-viewer (deploy_freeze ilegivel)" "freeze ilegivel num so: os outros agem e a linha diz"; hasnt "$(kicks)" "map-viewer" "freeze ilegivel num so: ele nao e reiniciado"
reset; EXTRA_ENV="DR_D3_FREEZE_CMD=$W/nao-existe-freeze"; run_d3; expect 30 "deploy_freeze ilegivel" "helper de freeze que nem executa: 30"
reset; for l in demand-dashboard map-viewer ficha360 clientes-dashboard; do setproc $l 3 59:59; done; run_d3; expect 10 "reiniciado ha 59 min" "idade 3599 s: ninguem e reiniciado"; eq "$(kicks)" "" "idade 3599 s: nada reiniciado"
reset; setproc map-viewer 3 01:00:00; run_d3 --dry-run; has "$OUT" "faria reiniciar (maior primeiro): map-viewer" "idade 3600 s: elegivel"
reset; setproc map-viewer 3 2-03:04:05; run_d3 --dry-run; has "$OUT" "map-viewer (700 MB)" "etime com dias (2-03:04:05) lido"
reset; touch "$SD/ps.garbage.1002"; run_d3 --dry-run; has "$OUT" "map-viewer (idade do processo ilegivel)" "etime ilegivel: pulado como 'nao sei'"
reset; setproc map-viewer 2 -; run_d3 --dry-run; has "$OUT" "map-viewer (parado, sem PID)" "label sem PID: 'parado'"
reset; for l in demand-dashboard ficha360 clientes-dashboard; do setproc $l 2 -; done; touch "$SD/fp.fail.1002"; run_d3; expect 30 "footprint ilegivel" "so resta um e o footprint falha: 30"; eq "$(kicks)" "" "footprint ilegivel: nada reiniciado"
reset; touch "$SD/fp.garbage.1002"; run_d3 --dry-run; has "$OUT" "map-viewer (footprint ilegivel)" "footprint sem a linha phys_footprint: ilegivel, nao 0 MB"
reset; touch "$SD/launchctl.listfail"; run_d3; expect 30 "launchctl ilegivel" "launchctl list falha: 30"; eq "$(kicks)" "" "launchctl falha: nada reiniciado"
reset; touch "$SD/launchctl.big"; run_d3 --dry-run; has "$OUT" "faria reiniciar (maior primeiro): map-viewer (700 MB), demand-dashboard (500 MB), ficha360 (140 MB)" "launchctl list GRANDE (~800 KB, passa do buffer do pipe): lido inteiro, sem 'Broken pipe' virar 'ilegivel'"
reset; touch "$SD/launchctl.big"; run_d3; expect 0 "reiniciei map-viewer" "launchctl list GRANDE no --run tambem"; hasnt "$(cat "$LOG")" "Broken pipe" "launchctl list GRANDE: nenhum 'Broken pipe' no log"
reset; touch "$SD/launchctl.listempty"; run_d3; expect 30 "launchctl ilegivel" "launchctl list vazio: 30 (nao e 'tudo parado')"
reset; for l in demand-dashboard map-viewer ficha360 clientes-dashboard; do setproc $l 2 -; done; run_d3; expect 10 "nenhum daemon elegivel" "todos parados: 10 (nada a fazer)"
reset; EXTRA_ENV="DR_D3_GUARDED=$W/nao-existe"; run_d3; has "$OUT" "demand-dashboard (sem jq ou sem o restart guardado)" "sem o guardado: demand-dashboard fica de fora"; hasnt "$(kicks)" "G" "sem o guardado: nunca reinicia o demand-dashboard por kickstart cru"

section "guardas de ligação (pix e voicebot), fronteira de 1800 s, leitura só-leitura"
reset; addpix dialing 10; run_d3; expect 10 "ligacao em curso (pix=1 voicebot=0)" "pix dialing recente: adia"; eq "$(kicks)" "" "pix dialing: nada reiniciado"
reset; addpix bridged 600; run_d3; expect 10 "pix=1" "pix bridged: adia"
reset; addvoice live 30; run_d3; expect 10 "voicebot=1" "voicebot live: adia"; eq "$(kicks)" "" "voicebot live: nada reiniciado"
reset; addpix no_answer 5; addpix answered_talked 5; addpix queued 5; addvoice finished 5; run_d3; expect 0 "reiniciei" "linhas recentes que NAO estao em curso nao bloqueiam"
reset; addpix dialing 1801; addvoice live 3600; run_d3; expect 0 "reiniciei" "dialing/live orfaos (> 1800 s): nao bloqueiam"
reset; addpix dialing 1700; run_d3; expect 10 "pix=1" "dialing de 1700 s (dentro da janela de 1800) ainda bloqueia"
reset; EXTRA_ENV="DR_D3_CALL_WINDOW_S=60"; addpix dialing 90; run_d3; expect 0 "reiniciei" "janela configuravel (60 s): dialing de 90 s nao bloqueia"
reset; rm -f "$VOICE"; run_d3; expect 30 "voicebot=?" "banco voicebot ausente: 30"; eq "$(kicks)" "" "banco voicebot ausente: nada reiniciado"
reset; printf 'isto nao e um banco sqlite, e so lixo suficiente para ter mais de 100 bytes ........................................' > "$VOICE"; run_d3; expect 30 "voicebot=?" "banco voicebot corrompido: 30"
reset; sqlite3 "$PIX" "DROP TABLE pix_call_log;"; run_d3; expect 30 "pix=?" "tabela pix_call_log ausente: 30"
reset; : > "$VOICE"; run_d3; expect 30 "voicebot=?" "banco voicebot vazio (0 bytes, como o voicebot_call_log.db real): 30"
reset; addvoice live 10; rm -f "$PIX"; run_d3; expect 10 "ligacao em curso" "uma viva + outra ilegivel: vale a viva (10, nao 30)"
reset; addpix dialing 10; before=$(md5 -q "$PIX"); b2=$(md5 -q "$VOICE"); run_d3; after=$(md5 -q "$PIX"); a2=$(md5 -q "$VOICE"); eq "$before$b2" "$after$a2" "guardas so leem: os dois bancos ficam byte a byte iguais"
reset; hookfor map-viewer "sqlite3 '$VOICE' \"INSERT INTO voicebot_call_log (call_id,status) VALUES ('x','live');\""; run_d3
expect 0 "parei: ligacao em curso (pix=0 voicebot=1) antes de demand-dashboard" "ligacao aparece entre um daemon e o seguinte: para (rc 0 porque agiu)"; eq "$(kicks)" "map-viewer," "guarda reavaliada antes de CADA daemon: so o map-viewer foi reiniciado"

section "prova do restart: PID novo + porta"
reset; echo 'rc=113' > "$SD/kick.com.whatsapp.map-viewer"; run_d3; expect 20 "map-viewer: kickstart rc=113" "kickstart falha: 20"; eq "$(kicks)" "map-viewer," "kickstart falha: para, nao tenta o seguinte"
reset; echo 'mode=samepid' > "$SD/kick.com.whatsapp.map-viewer"; run_d3; expect 20 "sem PID novo + porta 8099" "PID igual depois do kickstart: 20"; eq "$(kicks)" "map-viewer," "PID igual: para"
reset; echo 'mode=down' > "$SD/kick.com.whatsapp.map-viewer"; run_d3; expect 20 "sem PID novo" "daemon que nao volta (sem PID): 20"
reset; hookfor map-viewer "echo 503 > '$SD/port.8099'"; run_d3; expect 20 "sem PID novo + porta 8099" "PID novo mas porta devolve 503: 20"
reset; hookfor map-viewer "echo down > '$SD/port.8099'"; run_d3; expect 20 "porta 8099" "PID novo mas porta fora do ar: 20"
reset; hookfor map-viewer "echo 404 > '$SD/port.8099'"; run_d3; expect 20 "porta 8099" "404 nao conta como respondendo: 20"
reset; echo 'setfree=4700' > "$SD/kick.com.whatsapp.map-viewer"; hookfor map-viewer "echo 302 > '$SD/port.8099'"; run_d3; expect 0 "porta 8099 ok" "redirect 302 conta como respondendo"
reset; echo 'setfree=3500' > "$SD/kick.com.whatsapp.map-viewer"; echo 'rc=1' > "$SD/kick.com.whatsapp.ficha360"; run_d3
expect 20 "ficha360: kickstart rc=1; antes disso reiniciei: map-viewer" "um agiu e o seguinte falha: 20 e a linha diz os dois"
reset; hookfor map-viewer "rm -f '$SD/free'"; run_d3; expect 0 "nao consegui re-medir" "re-medicao ilegivel depois de agir: para, rc 0"; eq "$(kicks)" "map-viewer," "re-medicao ilegivel: nao segue as cegas"

section "demand-dashboard pelo restart guardado"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; run_d3
expect 0 "reiniciei demand-dashboard pid 1001->2001" "guardado ok: reiniciou"; eq "$(kicks)" "G,demand-dashboard," "guardado ok: so o guardado reinicia o demand-dashboard"
has "$CALLS" "guarded disk-recovery-d3 ga-1p1i5jr.3 | DRAIN=3 READY=3 NOTIFY=/nonexistent URL=http://127.0.0.1:8095" "guardado chamado com agente, bead, tetos e notify desligado (sem aviso duplicado)"
eq "$(cat "$SD/dd_config" | cut -c1-2)" "0|" "guardado ok: fila despausada no fim"; eq "$(npatch)" 0 "guardado ok: D3 nao precisou despausar nada"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo leave_paused > "$SD/guarded.mode"; run_d3
expect 0 "reiniciei demand-dashboard" "guardado deixa a fila pausada (nossa): D3 despausa"; eq "$(cat "$SD/dd_config" | cut -c1-2)" "0|" "pausa nossa que sobrou: lida de volta 0"; eq "$(npatch)" 1 "pausa nossa que sobrou: exatamente 1 PATCH de despausa"
has "$CALLS" "PATCH sp=0 by=disk-recovery-d3:" "despausa assinada com o prefixo do degrau"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo leave_paused > "$SD/guarded.mode"; touch "$SD/dd_numeric"; run_d3; expect 0 "reiniciei demand-dashboard" "system_paused numerico (1) tambem e lido"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo fail_after_pause > "$SD/guarded.mode"; run_d3
expect 20 "demand-dashboard: guardado rc=1 [VEREDITO: FALHOU - OutreachWorker nao drenou]; fila conferida" "guardado falha depois de pausar: 20 e fila despausada por nos"; eq "$(cat "$SD/dd_config" | cut -c1-2)" "0|" "guardado falha: pausa nossa desfeita"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo fail_nopause > "$SD/guarded.mode"; run_d3; expect 20 "guardado rc=1" "guardado falha sem pausar: 20"; eq "$(npatch)" 0 "guardado falha sem pausar: D3 nao mexe na fila"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo foreign > "$SD/guarded.mode"; printf '1|athos: parada de emergencia' > "$SD/dd_config"; run_d3
expect 0 "reiniciei demand-dashboard" "pausa de outro dono: reinicia"; eq "$(cat "$SD/dd_config")" "1|athos: parada de emergencia" "pausa de outro dono: INTOCADA"; eq "$(npatch)" 0 "pausa de outro dono: nenhum PATCH"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo leave_paused > "$SD/guarded.mode"; echo patch400 > "$SD/dd_mode"; run_d3
expect 20 "fila NAO confirmada" "despausa recusada (400): 20, diz que nao confirmou"; has "$CALLS" "PATCH-RECUSADO" "despausa recusada: tentou"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo leave_paused > "$SD/guarded.mode"; echo 3 > "$SD/dd_down_n"; EXTRA_ENV="DR_D3_DESPAUSE_S=15 DR_D3_READY_S=15"; run_d3
expect 0 "reiniciei demand-dashboard" "daemon ainda subindo na hora de despausar: espera e despausa"; eq "$(cat "$SD/dd_config" | cut -c1-2)" "0|" "daemon voltando devagar: fila acabou despausada"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo nopid > "$SD/guarded.mode"; run_d3; expect 20 "sem PID novo + porta 8095" "guardado 'ok' mas PID igual: 20 (nao confia so no veredito)"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo slow > "$SD/guarded.mode"; EXTRA_ENV="DR_D3_DRAIN_S=1 DR_D3_READY_S=1 DR_D3_GUARD_SLACK_S=1"; run_d3
expect 20 "guardado rc=124" "guardado que estoura o tempo: encerrado (TERM), 20"; eq "$(cat "$SD/dd_config" | cut -c1-2)" "0|" "guardado encerrado no meio: pausa nossa desfeita"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; printf '1|disk-recovery-d3: restart guardado ga-1p1i5jr.3' > "$SD/dd_config"; printf '9000' > "$SD/free"; run_d3
expect 10 "ja recuperado" "sobra de rodada anterior: disco ja recuperado"; eq "$(cat "$SD/dd_config" | cut -c1-2)" "0|" "sobra de rodada anterior (KILL): pausa nossa desfeita no inicio"
reset; printf '1|disk-recovery-d3: restart guardado ga-1p1i5jr.3' > "$SD/dd_config"; printf '9000' > "$SD/free"; run_d3 --dry-run
eq "$(cat "$SD/dd_config" | cut -c1-2)" "1|" "dry-run NAO despausa"; eq "$(npatch)" 0 "dry-run: nenhum PATCH"
reset; printf '1|athos: parada' > "$SD/dd_config"; printf '9000' > "$SD/free"; run_d3; eq "$(cat "$SD/dd_config")" "1|athos: parada" "pausa de outro dono no inicio: nao tocada"

section "TERM no meio do guardado despausa a fila"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo slow > "$SD/guarded.mode"
( env -i HOME="$W/home" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$W/tmp" STUB_DIR="$SD" DR_CITY="$CITY" DR_D3_WA="$WA" DR_D3_PIX_DB="$PIX" DR_D3_VOICE_DB="$VOICE" \
    DR_D3_GUARDED="$W/guarded" DR_D3_FREEZE_CMD="$W/freeze" DR_FREE_MB_FILE="$SD/free" DR_SWAP_MB_FILE="$SD/swap" DR_D3_SETTLE_S=0 DR_D3_READY_S=3 DR_D3_DRAIN_S=3 DR_D3_DESPAUSE_S=3 \
    DR_D3_GUARD_SLACK_S=100 DR_D3_CMD_S=5 DR_D3_CURL_S=2 "$D3" --run > "$W/term.out" 2>&1; echo $? > "$W/term.rc" ) &
BGP=$!; BG_PIDS="$BG_PIDS $BGP"
for _ in $(seq 1 150); do [ -f "$SD/guarded.started" ] && break; sleep 0.1; done
if [ -f "$SD/guarded.started" ]; then
  d3pid=$(cat "$LOCK/pid" 2>/dev/null); kill -TERM "$d3pid" 2>/dev/null
  for _ in $(seq 1 100); do [ -f "$W/term.rc" ] && break; sleep 0.1; done
  OUT=$(cat "$W/term.out" 2>/dev/null); RC=$(cat "$W/term.rc" 2>/dev/null || echo ?)
  expect 20 "interrompido (TERM)" "TERM: sai 20 com a linha dizendo"; eq "$(cut -c1-2 < "$SD/dd_config")" "0|" "TERM: a pausa nossa foi desfeita antes de sair"; lockgone "TERM"
  eq "$(pgrep -f "$W/guarded" | head -1)" "" "TERM: o guardado em andamento foi encerrado junto"
else
  nope "TERM: o guardado stub nao chegou a rodar"
fi

section "orçamento de tempo"
reset; EXTRA_ENV="DR_D3_BUDGET_S=5"; run_d3; expect 10 "sem tempo para map-viewer" "orcamento menor que o pior caso: nao comeca"; eq "$(kicks)" "" "sem tempo: nada reiniciado"
reset; EXTRA_ENV="DR_D3_DRAIN_S=100 DR_D3_BUDGET_S=90"; echo 'setfree=3500' > "$SD/kick.com.whatsapp.map-viewer"; run_d3
expect 0 "sem tempo para demand-dashboard" "o 1o cabe e o 2o (pior caso maior) nao: para e diz"; eq "$(kicks)" "map-viewer," "orcamento: so o map-viewer foi reiniciado"

section "trava de instância única"
reset; sleep 120 & LP=$!; BG_PIDS="$BG_PIDS $LP"; mkdir -p "$LOCK"; echo "$LP" > "$LOCK/pid"; run_d3; expect 10 "outra instancia rodando" "trava de dono vivo: 10"; eq "$(kicks)" "" "trava viva: nada reiniciado"
[ -d "$LOCK" ] && ok "trava viva: nao foi removida" || nope "trava viva foi removida"; kill "$LP" 2>/dev/null
reset; ( exit 0 ) & DP=$!; wait "$DP" 2>/dev/null; mkdir -p "$LOCK"; echo "$DP" > "$LOCK/pid"; printf '9000' > "$SD/free"; run_d3; expect 10 "ja recuperado" "trava de dono morto: tomada"; lockgone "trava morta"
reset; mkdir -p "$LOCK"; printf '9000' > "$SD/free"; run_d3; expect 10 "ja recuperado" "trava sem pid gravado: tratada como morta"; lockgone "trava sem pid"
reset; echo 'rc=1' > "$SD/kick.com.whatsapp.map-viewer"; run_d3; lockgone "falha de kickstart"

section "dry-run: lê tudo, não faz nada"
reset; run_d3 --dry-run; expect 10 "DRY-RUN D3: faria reiniciar (maior primeiro): map-viewer (700 MB), demand-dashboard (500 MB), ficha360 (140 MB)" "dry-run lista o que faria, na ordem"
hasnt "$CALLS" "kickstart" "dry-run: nenhum kickstart"; hasnt "$CALLS" "guarded" "dry-run: guardado nao chamado"; eq "$(npatch)" 0 "dry-run: nenhum PATCH"
[ ! -e "$LOG" ] && [ ! -d "$LOCK" ] && ok "dry-run: nao grava log nem toma trava" || nope "dry-run deixou log/trava"
reset; addpix dialing 5; run_d3 --dry-run; expect 10 "DRY-RUN D3: nada a fazer: ligacao em curso (pix=1 voicebot=0) antes de map-viewer" "dry-run com ligacao em curso: nada a fazer, diz por que"; eq "$(kicks)" "" "dry-run com ligacao em curso: nada reiniciado"
reset; touch "$OFF"; run_d3 --dry-run; expect 10 "desligado" "dry-run com interruptor: 10"
reset; touch "$SD/launchctl.listfail"; run_d3 --dry-run; expect 30 "DRY-RUN D3 nao consegui ler" "dry-run com launchctl ilegivel: 30"

section "configuração, log, linha única"
reset; EXTRA_ENV="DR_D3_MIN_AGE_S=abc"; setproc map-viewer 3 59:59; run_d3 >/dev/null; has "$(cat "$LOG")" "DR_D3_MIN_AGE_S='abc'->3600" "variavel invalida: cai no padrao e o log diz"; hasnt "$(kicks)" "map-viewer" "variavel invalida: vale o padrao 3600 (59:59 nao reinicia)"
reset; head -c 5000 /dev/zero | tr '\0' 'x' > "$LOG"; EXTRA_ENV="DR_D3_LOG_MAX_KB=1"; run_d3 >/dev/null; [ -f "$LOG.1" ] && ok "log grande: girado para .1" || nope "log nao girou"
reset; run_d3 >/dev/null; has "$(cat "$LOG")" "FIM rc=0:" "log tem a linha FIM com o rc"; has "$(cat "$LOG")" "reiniciando map-viewer" "log tem o detalhe de cada reinicio"
reset; run_d3; hasnt "$OUT" "[" "nenhum carimbo de log vaza para a saida"
reset; for l in demand-dashboard map-viewer ficha360 clientes-dashboard; do setproc $l 3 00:30; done; run_d3; expect 10 "nenhum daemon elegivel" "linha longa de pulos fica <= 290 e ASCII"

printf '\n%s passaram, %s falharam\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
