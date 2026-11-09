#!/usr/bin/env bash
# disk-recovery-d3-ram-daemons.selftest.sh — testa o degrau D3 da escada de disco (ga-1p1i5jr.3) SEM tocar na máquina.
#
# ## Contents
#   O que é simulado · O que é verificado · Como rodar
#
# O QUE É SIMULADO  launchctl (list/kickstart), ps (por PID e a lista -ax do Safari), footprint, top (bw-serve), osascript (quit do Safari), secret (prova do cofre), sleep (modo lento), curl (API do demand-dashboard e as portas), df e sysctl são shims no PATH; os bancos de ligação são sqlite REAIS e temporários (o shim do sqlite3 só impõe a regra do mini: `-readonly` não abre banco WAL sem -wal/-shm)
#   (pix_call_log e voicebot_call_log); o restart guardado, o deploy_freeze e o relógio do disco (arquivos DR_FREE_MB_FILE / DR_SWAP_MB_FILE) são stubs. Nada real é reiniciado, pausado ou enviado.
#   A trava da rodada da campanha é um flock REAL: um processo python vivo a toma como o campanha_diaria_loop; o python3 que o D3 chama é o de verdade, atrás de um shim que só injeta falha, lentidão ou mudez.
# O QUE É VERIFICADO  saída = UMA linha, ASCII, ≤ 290, nada antes dela (stdout+stderr juntos, como o maestro lê) e rc 0/10/20/30/2 em cada cenário · fronteiras (livre 4608/4609, idade 3599/3600 s,
#   footprint 99/100 MB, janela de ligação 1799/1801 s) · ordem por footprint e parada ao recuperar · só labels da allowlist · cada guarda de ligação (pix dialing/bridged, voicebot live, banco
#   ausente/corrompido/sem tabela = não sei), e a guarda de novo ENTRE um daemon e o seguinte · freeze (congelado, livre, ilegível) · prova do restart (PID novo + porta; kickstart que falha,
#   mesmo PID, porta fora, 4xx) · demand-dashboard pelo guardado (argumentos, env, notify desligado, pausa nossa que sobra é desfeita E lida de volta, pausa alheia intocada, despausa recusada,
#   daemon voltando devagar, guardado que estoura o tempo, sobra de rodada anterior) · TERM no meio do guardado despausa a fila ·
#   a LINHA FINAL nunca diz "conferida"/"nada a fazer" por cima de dúvida na fila (TERM com daemon fora do ar / PATCH recusado / sem pausa nossa em aberto / no meio da despausa da sobra; sobra nossa que
#   o PATCH recusou = 20; fila ilegível no início = 30 se nada foi reiniciado; o guardado que deixa a fila livre apaga a dúvida; o aviso sobrevive ao corte de 290) · orçamento de tempo · trava (viva, morta, solta no fim) ·
#   interruptor · dry-run sem efeito colateral · df/swap lidos do jeito certo (nunca `df /`) e ilegíveis = 30 · variável numérica inválida · rotação do log · bancos só lidos (também WAL sem -wal/-shm, que o sqlite3 do mini não abre com -readonly: shim) ·
#   (ga-1p1i5jr.7) Safari: só o executável Safari.app/.../Safari, idade 7199/7200 s, prova de que saiu, falha não para o resto e não repete por 6 h, lista de processos vazia/ilegível ≠ fechado ·
#   bw-serve: MEM+CMPRS 800/801 MB e unidades do top, idade 21599/21600 s, secret antes e depois (valor nunca lido), ordem Safari → bw-serve → daemons ·
#   label ausente ≠ domínio errado · "D3 retomou o envio" na linha · sobra de pausa desfeita antes de ler o disco · teto de tempo em segundos de relógio ·
#   (ga-13qui1k) rodada da campanha em curso: o demand-dashboard (e só ele) espera a trava; tomada = pula, livre/ausente/dono morto (corpo velho no arquivo) = age, ilegível (diretório, ENOTDIR, python3 quebrado/travado/calado) = pula e conta
#   como "não consegui ler"; relida imediatamente antes de agir (rodada que começa depois do scan); a leitura não cria nem muda nada e não deixa a trava tomada; caminho padrão; pior caso do orçamento.
# COMO RODAR      bash scripts/disk-recovery-d3-ram-daemons.selftest.sh        (~1-3 min)
#   Para testar uma cópia modificada do degrau (mutantes): DR_D3_PATH=/caminho/disk-recovery-d3-ram-daemons.mutN.sh ST_FAILFAST=1 bash scripts/disk-recovery-d3-ram-daemons.selftest.sh  (ST_FAILFAST=1 sai no 1º FAIL com rc 1)
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
LOG="$CITY/.gc/logs/disk-recovery-d3.log"; LOCK="$CITY/.gc/disk-recovery-d3.lock"; OFF="$CITY/.gc/disk-recovery.off"; STAMP="$CITY/.gc/disk-recovery-d3-safari-fail.stamp"
mkdir -p "$BIN" "$W/tmp" "$W/home" "$WA"
RLD="$W/rl"; RLOCK="$RLD/round.lock"; HOLDER=""   # a trava (flock) da rodada da campanha: nasce AUSENTE em cada cenario (reset); rl_hold a toma de verdade; todo run_d3 aponta o D3 para ela (nunca para o /tmp real da maquina)
PASS=0; FAIL=0; OUT=""; RC=0; EXTRA_ENV=""
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() {
  FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed 's/^/        | /' | tail -n 8
  # ST_FAILFAST=1 (para mutantes): o primeiro FAIL já prova que o mutante foi pego (rc 1); chegar ao fim com rc 0 = o selftest NÃO pega aquele mutante
  if [ "${ST_FAILFAST:-0}" = 1 ]; then printf '\n(ST_FAILFAST) parei no 1º FAIL: %s passaram, %s falharam\n' "$PASS" "$FAIL"; exit 1; fi
  return 0
}
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
    [ -f "$S/launchctl.nodomain" ] && exit 0
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
pid=""; ax=0; while [ $# -gt 0 ]; do case "$1" in -p) pid=$2; shift ;; -axo) ax=1 ;; esac; shift; done
[ -f "$STUB_DIR/ps.fail" ] && exit 1
if [ "$ax" = 1 ]; then   # lista de processos (Safari): apps = "pid etime comm"; apps.fail / apps.empty / apps.garbage = ilegivel
  [ -f "$STUB_DIR/apps.fail" ] && exit 1
  [ -f "$STUB_DIR/apps.empty" ] && exit 0
  [ -f "$STUB_DIR/apps.garbage" ] && { echo "ps: opcao estranha"; exit 0; }
  cat "$STUB_DIR/apps"; exit 0
fi
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
echo "LC_ALL=${LC_ALL:-unset}" >> "$STUB_DIR/sysctl.env"     # com que LC_ALL o D3 chamou (o sysctl de verdade muda o decimal com ele)
[ -f "$STUB_DIR/sysctl.fail" ] && exit 1
# sysctl.pt = como o do mini sob o launchd (pt_BR): vírgula decimal, a não ser que o chamador force LC_ALL=C
if [ -f "$STUB_DIR/sysctl.pt" ] && [ "${LC_ALL:-}" != C ]; then sed 's/\./,/g' "$STUB_DIR/sysctl.out"; else cat "$STUB_DIR/sysctl.out"; fi
SH
cat > "$BIN/top" <<'SH'
#!/bin/bash
S="$STUB_DIR"; pid=""
while [ $# -gt 0 ]; do case "$1" in -pid) pid=$2; shift ;; esac; shift; done
[ -f "$S/top.fail.$pid" ] && exit 1
printf 'Processes: 400 total\nDisks: 1/2 read\n\n'
[ -f "$S/top.garbage.$pid" ] && { echo "nada aqui"; exit 0; }
printf 'MEM    CMPRS\n'
[ -f "$S/top.$pid" ] && cat "$S/top.$pid"
exit 0
SH
cat > "$BIN/osascript" <<'SH'
#!/bin/bash
S="$STUB_DIR"; echo "osascript $*" >> "$S/calls"
mode=ok; rc=0; setfree=""; [ -f "$S/osa.mode" ] && . "$S/osa.mode"
[ "$mode" = slow ] && sleep 60
[ "$rc" -ne 0 ] && { echo "execution error: Not authorized to send Apple events to Safari. (-1743)" >&2; exit "$rc"; }
[ "$mode" = breakps ] && touch "$S/apps.fail"
if [ "$mode" = ok ]; then grep -v '/Safari.app/Contents/MacOS/Safari$' "$S/apps" > "$S/apps.new"; mv "$S/apps.new" "$S/apps"; fi
[ -n "$setfree" ] && printf '%s' "$setfree" > "$S/free"
exit 0
SH
cat > "$BIN/secret" <<'SH'
#!/bin/bash
S="$STUB_DIR"; echo "secret $*" >> "$S/calls"
if [ /dev/fd/1 -ef /dev/null ]; then echo "stdout-do-secret=devnull" >> "$S/calls"; else echo "stdout-do-secret=CAPTURADO" >> "$S/calls"; fi   # o degrau tem de mandar o stdout para /dev/null
echo "S3CR3T-CANARY-VALUE"   # o valor: o degrau NUNCA pode le-lo
if [ -f "$S/secret.fail_n" ]; then n=$(cat "$S/secret.fail_n"); if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$S/secret.fail_n"; echo "secret: bw serve unavailable" >&2; exit 5; fi; fi
[ -f "$S/secret.fail" ] && { echo "secret: no response from bw serve" >&2; exit 5; }
exit 0
SH
cat > "$BIN/sleep" <<'SH'
#!/bin/bash
# com sleep.slow o `sleep 0.05` do run_bounded fica 10x mais lento (host carregado); os de 1 s ou mais passam intactos
if [ -f "$STUB_DIR/sleep.slow" ] && [ "${1:-}" = 0.05 ]; then exec /bin/sleep 0.5; fi
exec /bin/sleep "$@"
SH
cat > "$BIN/sqlite3" <<'SH'
#!/bin/bash
# o sqlite3 do mini (3.51): `-readonly` num banco WAL SEM -wal/-shm nao abre ("unable to open database file", rc 14; medido no mini pelo revisor do gate em 03/11 e pelo D4 em 01/11). O 3.45 do Linux abre (e ainda cria -wal/-shm): o shim impoe a regra do mini; o resto vai ao sqlite3 de verdade
ro=0; for a in "$@"; do [ "$a" = -readonly ] && ro=1; done
if [ "$ro" = 1 ]; then for a in "$@"; do
  { [ -f "$a" ] && [ ! -e "$a-wal" ] && [ ! -e "$a-shm" ] && [ "$(head -c 20 "$a" | tail -c 2 | od -An -tx1 | tr -d ' \n')" = 0202 ]; } && { echo "Error: in prepare, unable to open database file (14)" >&2; exit 14; }
done; fi
PATH="${PATH#"${0%/*}":}" exec sqlite3 "$@"
SH
cat > "$BIN/python3" <<'SH'
#!/bin/bash
# a trava da rodada e lida por um python3 DE VERDADE (flock real); python3.fail = interpretador quebrado (rc 1), python3.slow = trava (o stub do Xcode CLT pedindo instalacao, por exemplo),
# python3.mute = sai com o rc do arquivo SEM rodar nem dizer nada (programa vazio, wrapper); python3.trace = nao le nada: anota o caminho da trava que recebeu (ultimo argumento) e diz «livre» (rc 10), para provar o caminho
# padrao sem tocar no /tmp real da maquina
S="$STUB_DIR"; echo "python3 probe" >> "$S/calls"
[ -f "$S/python3.fail" ] && { echo "python3: interpretador quebrado" >&2; exit 1; }
[ -f "$S/python3.slow" ] && exec /bin/sleep 30
[ -f "$S/python3.mute" ] && exit "$(cat "$S/python3.mute")"
[ -f "$S/python3.trace" ] && { echo "python3 trava ${*: -1}" >> "$S/calls"; echo livre; exit 10; }
PATH="${PATH#"${0%/*}":}" exec python3 "$@"
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
# o dono da trava da rodada, como o campanha_diaria_loop (lib/cdp_driver_lock.py do whatsapp_automation): flock EXCLUSIVO num processo vivo e o corpo «pid=… holder=… since=…» no arquivo; quando o dono morre o kernel solta o flock e o corpo FICA
cat > "$W/holder.py" <<'PY'
import fcntl, os, sys, time
path, ready = sys.argv[1], sys.argv[2]
go = sys.argv[3] if len(sys.argv) > 3 else ""
try:
    while go and not os.path.exists(go):
        time.sleep(0.05)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    os.ftruncate(fd, 0)
    os.write(fd, ("pid=%d holder=selftest since=%s\n" % (os.getpid(), time.strftime("%Y-%m-%dT%H:%M:%S"))).encode())
    open(ready, "w").close()
    time.sleep(600)
except Exception:
    sys.exit(3)
PY
cat > "$W/trylock.py" <<'PY'
import fcntl, sys
try:
    fcntl.flock(open(sys.argv[1], "rb"), fcntl.LOCK_EX | fcntl.LOCK_NB)
except Exception:
    sys.exit(1)
PY

# ── cenário ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
mkdbs() {
  rm -f "$PIX" "$VOICE"
  sqlite3 "$PIX" "CREATE TABLE pix_call_log (call_id TEXT, phone_norm TEXT, state TEXT NOT NULL DEFAULT 'dialing', started_at TEXT DEFAULT (datetime('now','localtime')), updated_at TEXT DEFAULT (datetime('now','localtime')));"
  sqlite3 "$VOICE" "CREATE TABLE voicebot_call_log (call_id TEXT, status TEXT NOT NULL DEFAULT 'live', started_at TEXT DEFAULT (datetime('now','localtime')), updated_at TEXT DEFAULT (datetime('now','localtime')));"
}
addpix()   { sqlite3 "$PIX" "INSERT INTO pix_call_log (call_id, phone_norm, state, started_at, updated_at) VALUES ('c$RANDOM', '5511', '$1', datetime('now','localtime','-$2 seconds'), datetime('now','localtime','-$2 seconds'));"; }
addvoice() { sqlite3 "$VOICE" "INSERT INTO voicebot_call_log (call_id, status, started_at, updated_at) VALUES ('v$RANDOM', '$1', datetime('now','localtime','-$2 seconds'), datetime('now','localtime','-$2 seconds'));"; }
walmk()  { sqlite3 "$PIX" "PRAGMA journal_mode=WAL;" > /dev/null; sqlite3 "$VOICE" "PRAGMA journal_mode=WAL;" > /dev/null; }   # os dois bancos viram WAL (como em producao); depois do addpix/addvoice, walrun tira o -wal/-shm antes do D3
walrun() { rm -f "$PIX-wal" "$PIX-shm" "$VOICE-wal" "$VOICE-shm"; run_d3 "$@"; }   # os apps abrem e fecham a conexao a cada operacao: o banco de producao fica WAL SEM -wal/-shm (o SQLite 3.51 do mac pode deixa-los vazios ao fechar, por isso tirar explicitamente)
hookfor() {  # $1=label $2..=comando que o kickstart roda DEPOIS de reiniciar (efeito colateral simulado)
  local l=$1; shift; printf '%s\n' "$*" > "$SD/hook.$l.sh"; printf 'hook="bash %s/hook.%s.sh"\n' "$SD" "$l" >> "$SD/kick.com.whatsapp.$l"
}
setproc()  { awk -v l="com.whatsapp.$1" -v f="$2" -v v="$3" '$1==l {$f=v} {print}' "$SD/procs" > "$SD/procs.new" && mv "$SD/procs.new" "$SD/procs"; }   # campos: 2=pid 3=etime 4=fp 5=unidade
addsafari() { printf '%5s %s %s\n' 9100 "$1" "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari" >> "$SD/apps"; }   # $1=etime do Safari aberto
addbw()     { printf 'com.gastown.bw-serve %s %s 1 MB\n' "$1" "$2" >> "$SD/procs"; printf '%s\n' "$3" > "$SD/top.$1"; }              # $1=pid $2=etime $3="MEM CMPRS" que o top mostra
hookbw()    { printf '%s\n' "$*" > "$SD/hook.bw.sh"; printf 'hook="bash %s/hook.bw.sh"\n' "$SD" >> "$SD/kick.com.gastown.bw-serve"; }     # efeito colateral depois do kickstart do bw-serve
seqall()    { printf '%s\n' "$CALLS" | awk '/^osascript/ {printf "O,"} /^secret/ {printf "S,"} /^kickstart/ {sub(/.*gui\/[0-9]+\//, ""); sub(/com\.whatsapp\./, ""); sub(/com\.gastown\./, ""); printf "%s,", $0} /^guarded/ {printf "G,"}'; }
alloff()    { local l; for l in demand-dashboard map-viewer ficha360 clientes-dashboard; do setproc $l 2 -; done; }                       # todos os daemons da allowlist parados
rl_drop() { if [ -n "$HOLDER" ]; then kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; BG_PIDS="${BG_PIDS/ $HOLDER/}"; fi; HOLDER=""; }   # morrer solta o flock (o corpo do arquivo fica); tira o PID da lista do cleanup (PID reusado)
rl_wait() { local _; for _ in $(seq 1 100); do [ -f "$W/holder.ready" ] && return 0; sleep 0.1; done; return 1; }
rl_hold() {  # [$1=arquivo-go]. Sem $1 so volta com a trava TOMADA; com $1 o dono espera o arquivo aparecer para toma-la (uma rodada que comeca no meio do D3)
  rl_drop; rm -f "$W/holder.ready"
  python3 -I "$W/holder.py" "$RLOCK" "$W/holder.ready" ${1:+"$1"} </dev/null >/dev/null 2>&1 &
  HOLDER=$!; BG_PIDS="$BG_PIDS $HOLDER"
  [ -n "${1:-}" ] || rl_wait || nope "o dono da trava da rodada nao subiu"
}
rl_free() { python3 -I "$W/trylock.py" "$RLOCK"; }   # rc 0 = a trava esta LIVRE agora (um flock EXCLUSIVO nao-bloqueante pegou, e foi solto ao sair)
reset() {
  rl_drop; rm -rf "$SD" "$CITY" "$RLD"; mkdir -p "$SD" "$CITY/.gc/logs" "$W/tmp"; rm -f "$W/tmp"/* 2>/dev/null
  cat > "$SD/procs" <<'EOF'
com.whatsapp.demand-dashboard 1001 05:00:00 500 MB
com.whatsapp.map-viewer 1002 02:10:04 700 MB
com.whatsapp.ficha360 1003 07:34:47 140 MB
com.whatsapp.clientes-dashboard 1004 03:00:00 73 MB
EOF
  cat > "$SD/apps" <<'EOF'
    1 05:00:00 /sbin/launchd
  412 03:10:11 /usr/sbin/cfprefsd
14869 22:19:25 /System/Library/PrivateFrameworks/SafariPlatformSupport.framework/Versions/A/XPCServices/com.apple.SafariPlatformSupport.Helper.xpc/Contents/MacOS/com.apple.SafariPlatformSupport.Helper
EOF
  echo 2000 > "$SD/counter"; printf '3000' > "$SD/free"; printf '4800' > "$SD/swap"; printf '0|' > "$SD/dd_config"
  : > "$SD/calls"; mkdbs; EXTRA_ENV=""
}
run_d3() {
  [ $# -gt 0 ] || set -- --run
  OUT=$(env -i HOME="$W/home" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$W/tmp" STUB_DIR="$SD" \
      DR_CITY="$CITY" DR_D3_WA="$WA" DR_D3_PIX_DB="$PIX" DR_D3_VOICE_DB="$VOICE" DR_D3_GUARDED="$W/guarded" DR_D3_FREEZE_CMD="$W/freeze" DR_D3_ROUND_LOCK="$RLOCK" \
      DR_FREE_MB_FILE="$SD/free" DR_SWAP_MB_FILE="$SD/swap" DR_D3_SETTLE_S=0 DR_D3_READY_S=3 DR_D3_DRAIN_S=3 DR_D3_DESPAUSE_S=3 DR_D3_GUARD_SLACK_S=2 DR_D3_CMD_S=5 DR_D3_CURL_S=2 \
      $EXTRA_ENV "$D3" "$@" 2>&1); RC=$?
  # um host sem o locale pedido em EXTRA_ENV (o nó Linux não tem pt_BR.UTF-8) faz o bash avisar 'setlocale: cannot change locale' em stderr antes de o script rodar: ruído do host, não do D3
  OUT=$(printf '%s\n' "$OUT" | grep -v -E '^[^ ]*bash: warning: setlocale: ')
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
# gate-fix 3 (ga-1p1i5jr.1): sob o launchd o mini roda com LANG=pt_BR.UTF-8 e o sysctl imprime 'used = 3015,31M'. O D3 já exportava LC_ALL=C (linha 58 do script), então o caso de locale abaixo NÃO é vermelho
# contra o D3 de antes: é guarda de regressão (se tirarem aquela linha o caso cai). O que era vermelho, e é o que este bloco prova, é a vírgula: um leitor só de ponto recusava a rodada (rc 30).
reset; EXTRA_ENV="DR_FREE_MB_FILE= DR_SWAP_MB_FILE= LC_ALL=pt_BR.UTF-8 LANG=pt_BR.UTF-8"; printf '4300' > "$SD/df.avail"; printf 'total = 6144.00M  used = 4876.50M  free = 1267.50M  (encrypted)' > "$SD/sysctl.out"; touch "$SD/sysctl.pt"
run_d3; expect 0 "livre 4300->" "swap com LC_ALL/LANG=pt_BR herdados (o sysctl só dá ponto com LC_ALL=C): o D3 chama o sysctl com LC_ALL=C e age"; has "$OUT" "swap 4876->" "…e lê 4876 MB"
eq "$(grep -v -x 'LC_ALL=C' "$SD/sysctl.env" | head -n 1)" "" "sysctl chamado SEMPRE com LC_ALL=C"; [ -s "$SD/sysctl.env" ] && ok "…e foi chamado" || nope "o sysctl nem foi chamado"
reset; EXTRA_ENV="DR_FREE_MB_FILE= DR_SWAP_MB_FILE="; printf '4300' > "$SD/df.avail"; printf 'total = 6144,00M  used = 4876,50M  free = 1267,50M  (encrypted)' > "$SD/sysctl.out"
run_d3; expect 0 "livre 4300->" "vírgula decimal mesmo com LC_ALL=C (cinto e suspensório): lida"; has "$OUT" "swap 4876->" "…'4876,50M' vira 4876"
reset; EXTRA_ENV="DR_FREE_MB_FILE= DR_SWAP_MB_FILE="; printf '4300' > "$SD/df.avail"; printf 'total = 8,00G  used = 4,50G  free = 3,50G' > "$SD/sysctl.out"
run_d3; has "$OUT" "swap 4608->" "'used = 4,50G' vira 4608"
reset; EXTRA_ENV="DR_FREE_MB_FILE= DR_SWAP_MB_FILE="; printf '4300' > "$SD/df.avail"; printf 'total = 6144,00M  used = 1,2,3M  free = 1M' > "$SD/sysctl.out"
run_d3; expect 30 "nao consegui ler" "'1,2,3M' (duas vírgulas) continua ilegível = 30"
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
reset; addbw 5001 08:00:00 "700M 300M"; run_d3   # com o bw-serve grande tambem: so os labels da allowlist (os 4 + o bw-serve) sao reiniciados
bad=$(printf '%s\n' "$CALLS" | grep '^kickstart' | grep -v -E 'gui/[0-9]+/(com\.whatsapp\.(demand-dashboard|map-viewer|ficha360|clientes-dashboard)|com\.gastown\.bw-serve)$' || true)
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
# cksum (POSIX, no mini e no no Linux): o md5 -q nao existe no Linux e la o teste "passava" comparando vazio com vazio; sem soma legivel o teste FALHA
reset; addpix dialing 10; before=$(cksum < "$PIX"; cksum < "$VOICE"); run_d3; after=$(cksum < "$PIX"; cksum < "$VOICE")
case "$before" in *[0-9]*) eq "$before" "$after" "guardas so leem: os dois bancos ficam byte a byte iguais" ;; *) nope "guardas so leem: cksum nao devolveu soma (teste vazio)" ;; esac
reset; hookfor map-viewer "sqlite3 '$VOICE' \"INSERT INTO voicebot_call_log (call_id,status) VALUES ('x','live');\""; run_d3
expect 0 "parei: ligacao em curso (pix=0 voicebot=1) antes de demand-dashboard" "ligacao aparece entre um daemon e o seguinte: para (rc 0 porque agiu)"; eq "$(kicks)" "map-viewer," "guarda reavaliada antes de CADA daemon: so o map-viewer foi reiniciado"
# gate-fix 1 (ga-1p1i5jr.5): os bancos de producao sao WAL sem -wal/-shm e o sqlite3 do mini nao os abre com -readonly (o shim impoe isso): a guarda tem de LER, nao cair em "?" (30 = o D3 cego, como no log de producao: "pix=? voicebot=0")
reset; walmk; walrun; expect 0 "reiniciei" "bancos WAL sem -wal/-shm, nenhuma ligacao: a guarda le 0 e 0 e o D3 age (nao 30)"
reset; walmk; addpix dialing 10; walrun; expect 10 "ligacao em curso (pix=1 voicebot=0)" "WAL sem -wal/-shm + pix dialing: a guarda LE a ligacao e adia"; eq "$(kicks)" "" "WAL + pix dialing: nada reiniciado"
reset; walmk; addvoice live 30; walrun; expect 10 "ligacao em curso (pix=0 voicebot=1)" "WAL sem -wal/-shm + voicebot live: adia"
reset; walmk; addpix dialing 10; rm -f "$PIX-wal" "$PIX-shm" "$VOICE-wal" "$VOICE-shm"; before=$(cksum < "$PIX"; cksum < "$VOICE"); run_d3; after=$(cksum < "$PIX"; cksum < "$VOICE")
case "$before" in *[0-9]*) eq "$before" "$after" "WAL: ler com o banco aberto para escrita (query_only) nao muda um byte do arquivo principal" ;; *) nope "WAL: cksum nao devolveu soma (teste vazio)" ;; esac

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
eq "$(cat "$SD/dd_config" | cut -c1-2)" "0|" "guardado ok: fila despausada no fim"; eq "$(npatch)" 0 "guardado ok: D3 nao precisou despausar nada"; hasnt "$OUT" "retomou" "guardado ok: a linha nao fala em retomada (o guardado ja despausou)"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo leave_paused > "$SD/guarded.mode"; run_d3
expect 0 "reiniciei demand-dashboard" "guardado deixa a fila pausada (nossa): D3 despausa"; has "$OUT" "D3 retomou o envio da fila do demand-dashboard (a pausa era nossa)" "D3 despausou a fila sozinho: a linha final DIZ que foi ele quem retomou o envio"; eq "$(cat "$SD/dd_config" | cut -c1-2)" "0|" "pausa nossa que sobrou: lida de volta 0"; eq "$(npatch)" 1 "pausa nossa que sobrou: exatamente 1 PATCH de despausa"
has "$CALLS" "PATCH sp=0 by=disk-recovery-d3:" "despausa assinada com o prefixo do degrau"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo leave_paused > "$SD/guarded.mode"; touch "$SD/dd_numeric"; run_d3; expect 0 "reiniciei demand-dashboard" "system_paused numerico (1) tambem e lido"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo fail_after_pause > "$SD/guarded.mode"; run_d3
expect 20 "demand-dashboard: guardado rc=1 [VEREDITO: FALHOU - OutreachWorker nao drenou]; fila conferida" "guardado falha depois de pausar: 20 e fila despausada por nos"; eq "$(cat "$SD/dd_config" | cut -c1-2)" "0|" "guardado falha: pausa nossa desfeita"; has "$OUT" "D3 retomou o envio: a pausa era nossa" "guardado falha + D3 despausa: a linha diz que o D3 retomou o envio"
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

section "rodada da campanha em curso: o demand-dashboard espera a trava (flock) da rodada diaria (ga-13qui1k; 08/11 20:39 o D3 o reiniciou no meio da rodada das 20:15)"
# trava TOMADA por um processo vivo, como o campanha_diaria_loop a toma: o demand-dashboard fica de fora, os outros agem, a linha e o log dizem por que
reset; rl_hold; run_d3
expect 0 "demand-dashboard (rodada da campanha em curso)" "trava da rodada tomada: o demand-dashboard e pulado e a linha diz por que"
eq "$(kicks)" "map-viewer,ficha360," "trava tomada: so os outros daemons sao reiniciados (nem guardado nem kickstart do demand-dashboard)"
hasnt "$CALLS" "guarded" "trava tomada: o restart guardado nao e chamado (a fila nem chega a ser pausada)"; eq "$(npatch)" 0 "trava tomada: nenhum PATCH na fila"
has "$(cat "$LOG")" "pulo demand-dashboard: rodada da campanha em curso" "trava tomada: o motivo vai no log"; lockgone "trava tomada"
reset; rl_hold; before=$(cksum < "$RLOCK"); run_d3 >/dev/null; after=$(cksum < "$RLOCK")
case "$before" in *[0-9]*) eq "$after" "$before" "trava tomada: a leitura nao muda um byte do arquivo (o corpo e a identidade do dono)" ;; *) nope "trava tomada: cksum nao devolveu soma (teste vazio)" ;; esac
if rl_free; then nope "trava tomada: depois da leitura do D3 o dono perdeu a trava"; else ok "trava tomada: o dono segue com a trava depois da leitura do D3"; fi
# trava LIVRE (o arquivo existe e ninguem o segura; ou o dono morreu e o corpo ficou; ou nunca houve rodada): o comportamento de sempre, e a leitura nao deixa a trava tomada
reset; mkdir -p "$RLD"; : > "$RLOCK"; run_d3
expect 0 "reiniciei map-viewer" "arquivo da trava existe e ninguem a segura: livre"; eq "$(kicks)" "map-viewer,G,demand-dashboard,ficha360," "trava livre: o demand-dashboard e reiniciado pelo guardado, na ordem de sempre"
has "$CALLS" "python3 probe" "trava livre: a trava foi lida (livre por ter olhado, nao por nao ter olhado)"
if rl_free; then ok "trava livre: a leitura do D3 nao deixa a trava tomada (a rodada das 20:15 nao perde a vez)"; else nope "trava livre: depois do D3 a trava ficou tomada"; fi
reset; rl_hold; rl_drop
[ -s "$RLOCK" ] && ok "dono morto: o corpo «pid=… holder=…» ficou no arquivo" || nope "dono morto: o arquivo nao guarda o corpo do dono (teste vazio)"
run_d3; expect 0 "reiniciei map-viewer" "dono da trava morto (o kernel solta o flock, o corpo fica): livre"; eq "$(kicks)" "map-viewer,G,demand-dashboard,ficha360," "dono morto: o demand-dashboard e reiniciado (corpo velho nao conta como rodada em curso)"
reset; run_d3; expect 0 "reiniciei map-viewer" "trava ausente (pasta e arquivo; ENOENT): nenhuma rodada a tomou, livre"; eq "$(kicks)" "map-viewer,G,demand-dashboard,ficha360," "trava ausente: o demand-dashboard e reiniciado"
[ ! -e "$RLD" ] && ok "trava ausente: a leitura nao cria a pasta nem o arquivo" || nope "trava ausente: o D3 criou $RLD"
reset; mkdir -p "$RLD"; run_d3; has "$(kicks)" "G,demand-dashboard" "pasta da trava sem o arquivo (ENOENT): livre"; [ ! -e "$RLOCK" ] && ok "pasta sem arquivo: a leitura nao cria o arquivo" || nope "o D3 criou $RLOCK"
# ilegivel NUNCA vira «livre»: o demand-dashboard fica de fora (os outros agem) e a linha diz «trava da rodada ilegivel»
reset; mkdir -p "$RLOCK"; run_d3
expect 0 "demand-dashboard (trava da rodada ilegivel)" "trava que e um DIRETORIO (nao e arquivo comum): ilegivel, o demand-dashboard e pulado"; eq "$(kicks)" "map-viewer,ficha360," "trava ilegivel: so os outros daemons sao reiniciados"
has "$(cat "$LOG")" "trava da rodada ($RLOCK) ilegivel: rc=99 nao e arquivo comum" "diretorio: a causa vai no log"
reset; : > "$W/arquivo-comum"; EXTRA_ENV="DR_D3_ROUND_LOCK=$W/arquivo-comum/round.lock"; run_d3
expect 0 "demand-dashboard (trava da rodada ilegivel)" "pasta da trava e um arquivo (ENOTDIR, nao ENOENT): ilegivel, nao «ausente»"; has "$(cat "$LOG")" "rc=99 abrir: ENOTDIR" "ENOTDIR: a causa vai no log"
reset; touch "$SD/python3.fail"; run_d3
expect 0 "demand-dashboard (trava da rodada ilegivel)" "python3 quebrado (rc 1): ilegivel"; has "$(cat "$LOG")" "pulo demand-dashboard: trava da rodada ilegivel" "python3 quebrado: o motivo vai no log"
reset; touch "$SD/python3.slow"; EXTRA_ENV="DR_D3_CMD_S=1"; t0=$SECONDS; run_d3; dt=$((SECONDS - t0))
expect 0 "demand-dashboard (trava da rodada ilegivel)" "python3 que trava: encerrado no teto (CMD_S), ilegivel"; OUT=$(grep -h 'ilegivel: rc=' "$LOG" | cut -c1-200); has "$OUT" "rc=124" "python3 que trava: o log diz que estourou o tempo (rc=124)"
[ "$dt" -lt 20 ] && ok "python3 parado por 30 s: a leitura tem teto, o D3 nao espera (${dt} s)" || nope "python3 parado por 30 s: o D3 esperou ${dt} s (a leitura da trava nao tem teto)"
for m in 0 10; do   # sem a palavra «tomada»/«livre» o rc sozinho nao vale: um programa vazio sai 0, um wrapper pode sair 10
  reset; echo "$m" > "$SD/python3.mute"; run_d3
  expect 0 "demand-dashboard (trava da rodada ilegivel)" "python3 que sai $m calado (sem dizer tomada/livre): ilegivel, nao «rodada em curso» nem «livre»"; eq "$(kicks)" "map-viewer,ficha360," "python3 calado (rc $m): o demand-dashboard nao e reiniciado"
done
reset; for l in map-viewer ficha360 clientes-dashboard; do setproc $l 2 -; done; touch "$SD/python3.fail"; run_d3
expect 30 "nao consegui ler e nao agi" "trava ilegivel e nada mais a fazer: 30, nao 10"; eq "$(kicks)" "" "trava ilegivel e nada mais a fazer: nada reiniciado"
reset; for l in map-viewer ficha360 clientes-dashboard; do setproc $l 2 -; done; rl_hold; run_d3
expect 10 "demand-dashboard (rodada da campanha em curso)" "trava tomada e nada mais a fazer: 10, a linha diz o pulo"; eq "$(kicks)" "" "trava tomada e nada mais a fazer: nada reiniciado"
# so o demand-dashboard consulta a trava (a rodada so fala com a :8095); a trava tomada nao muda o que se faz com os demais
reset; setproc demand-dashboard 2 -; run_d3; hasnt "$CALLS" "python3 probe" "demand-dashboard parado: a trava nem e lida"
reset; rl_hold; addbw 5001 08:00:00 "700M 300M"; run_d3
eq "$(seqall)" "S,bw-serve,S,map-viewer,ficha360," "trava tomada: o bw-serve e os outros daemons seguem, so o demand-dashboard fica de fora"
# a trava lida por padrao e a da rodada (DEFAULT_LOCK_PATH de lib/campanha_diaria/round_lock.py do whatsapp_automation); o python3 de mentira so anota o caminho (nao toca no /tmp real da maquina)
reset; touch "$SD/python3.trace"; EXTRA_ENV="DR_D3_ROUND_LOCK="; run_d3 --dry-run; has "$CALLS" "python3 trava /tmp/wa_campanha_diaria/round.lock" "sem DR_D3_ROUND_LOCK a trava lida e /tmp/wa_campanha_diaria/round.lock (a da rodada)"
# dry-run LE a trava (so assim diz a verdade do que o --run faria) e nao faz nada
reset; rl_hold; run_d3 --dry-run
expect 10 "faria reiniciar (maior primeiro): map-viewer (700 MB), ficha360 (140 MB)" "dry-run com a trava tomada: o demand-dashboard nao entra no que faria"; has "$OUT" "demand-dashboard (rodada da campanha em curso)" "dry-run com a trava tomada: a linha diz o pulo"
hasnt "$CALLS" "kickstart" "dry-run com a trava tomada: nenhum kickstart"; has "$CALLS" "python3 probe" "dry-run: a trava foi lida"
# a rodada comeca DEPOIS do scan (durante o restart do map-viewer, o 1o da ordem): a trava e lida de novo imediatamente antes de agir, nao so no scan
reset; rm -f "$W/holder.go"; rl_hold "$W/holder.go"; hookfor map-viewer "touch '$W/holder.go'; for _ in \$(seq 1 100); do [ -f '$W/holder.ready' ] && break; sleep 0.1; done"; run_d3
expect 0 "demand-dashboard (rodada da campanha em curso)" "rodada que comeca depois do scan: o demand-dashboard e pulado (a trava e relida antes de agir)"; eq "$(kicks)" "map-viewer,ficha360," "rodada que comeca no meio do D3: so map-viewer e ficha360"
# o pior caso do demand-dashboard conta o python3 da trava: 5 comandos de D3_CMD_S (2 sqlite3 + launchctl + freeze + a trava). CMD_S=20 e orcamento 104: 114 s nao cabem (os 94 s de antes cabiam)
reset; setproc demand-dashboard 4 900; EXTRA_ENV="DR_D3_CMD_S=20 DR_D3_BUDGET_S=104"; run_d3
expect 10 "sem tempo para demand-dashboard" "orcamento de 104 s: o pior caso do demand-dashboard (114 s, com o python3 da trava) nao cabe"; eq "$(kicks)" "" "sem tempo para o demand-dashboard: nada reiniciado"

section "TERM no meio do guardado despausa a fila"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo slow > "$SD/guarded.mode"
( env -i HOME="$W/home" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$W/tmp" STUB_DIR="$SD" DR_CITY="$CITY" DR_D3_WA="$WA" DR_D3_PIX_DB="$PIX" DR_D3_VOICE_DB="$VOICE" \
    DR_D3_GUARDED="$W/guarded" DR_D3_FREEZE_CMD="$W/freeze" DR_D3_ROUND_LOCK="$RLOCK" DR_FREE_MB_FILE="$SD/free" DR_SWAP_MB_FILE="$SD/swap" DR_D3_SETTLE_S=0 DR_D3_READY_S=3 DR_D3_DRAIN_S=3 DR_D3_DESPAUSE_S=3 \
    DR_D3_GUARD_SLACK_S=100 DR_D3_CMD_S=5 DR_D3_CURL_S=2 "$D3" --run > "$W/term.out" 2>&1; echo $? > "$W/term.rc" ) &
BGP=$!; BG_PIDS="$BG_PIDS $BGP"
for _ in $(seq 1 150); do [ -f "$SD/guarded.started" ] && break; sleep 0.1; done
if [ -f "$SD/guarded.started" ]; then
  d3pid=$(cat "$LOCK/pid" 2>/dev/null); kill -TERM "$d3pid" 2>/dev/null
  for _ in $(seq 1 100); do [ -f "$W/term.rc" ] && break; sleep 0.1; done
  OUT=$(cat "$W/term.out" 2>/dev/null); RC=$(cat "$W/term.rc" 2>/dev/null || echo ?)
  expect 20 "interrompido (TERM)" "TERM: sai 20 com a linha dizendo"; has "$OUT" "fila do demand-dashboard conferida" "TERM: a fila foi conferida de verdade, a linha diz"; eq "$(cut -c1-2 < "$SD/dd_config")" "0|" "TERM: a pausa nossa foi desfeita antes de sair"; lockgone "TERM"
  eq "$(pgrep -f "$W/guarded" | head -1)" "" "TERM: o guardado em andamento foi encerrado junto"
else
  nope "TERM: o guardado stub nao chegou a rodar"
fi

section "sobra de pausa nossa e fila ilegivel: a linha final nao diz 'nada a fazer' nem 'conferida' por cima de duvida (gate-fix 1)"
# sobra NOSSA + despausa recusada (400) + disco ja recuperado: a fila SEGUE PARADA → 20, nunca "nada a fazer" com rc 10
reset; printf '1|disk-recovery-d3: restart guardado ga-1p1i5jr.3' > "$SD/dd_config"; printf '9000' > "$SD/free"; echo patch400 > "$SD/dd_mode"; run_d3
expect 20 "fila do demand-dashboard NAO despausada" "sobra nossa + PATCH recusado (400) + livre 9000: 20 e a linha diz que a fila segue parada"
hasnt "$OUT" "D3 nada a fazer" "sobra nao despausada: a cabeca da linha nao e 'nada a fazer'"; has "$OUT" "disco ja recuperado" "sobra nao despausada: a linha ainda diz o resto (disco recuperado)"
has "$CALLS" "PATCH-RECUSADO" "sobra nao despausada: tentou despausar"; eq "$(cut -c1-2 < "$SD/dd_config")" "1|" "sobra nao despausada: a fila continua pausada (e a linha nao mente)"; lockgone "sobra nao despausada"
# a sobra existe e o disco NAO recuperou: segue agindo nos outros daemons, mas o rc final e 20 (acao + duvida na fila = 20, como no restart guardado)
reset; printf '1|disk-recovery-d3: restart guardado ga-1p1i5jr.3' > "$SD/dd_config"; echo patch400 > "$SD/dd_mode"; setproc demand-dashboard 2 -; setproc ficha360 4 50; run_d3
expect 20 "NAO despausada" "sobra nao despausada + disco nao recuperou: 20 mesmo tendo reiniciado outro"; has "$OUT" "reiniciei map-viewer" "sobra nao despausada: o que foi reiniciado entra na linha"
# o guardado deixou a fila livre depois: a duvida do inicio acabou, nada de 20 por uma sobra que ja nao existe
reset; printf '1|disk-recovery-d3: restart guardado ga-1p1i5jr.3' > "$SD/dd_config"; echo patch400 > "$SD/dd_mode"; setproc map-viewer 4 50; setproc ficha360 4 50; run_d3
expect 0 "reiniciei demand-dashboard" "sobra nao despausada mas o guardado deixou a fila livre e lida: 0"; hasnt "$OUT" "NAO despausada" "fila conferida depois: a linha nao repete a duvida do inicio"
# sobra nossa despausada e lida de volta: rc inalterado, a linha conta
reset; printf '1|disk-recovery-d3: restart guardado ga-1p1i5jr.3' > "$SD/dd_config"; printf '9000' > "$SD/free"; run_d3
expect 10 "sobra de pausa nossa da rodada anterior: despausada e conferida" "sobra despausada e lida de volta: 10 e a linha conta"; eq "$(cut -c1-2 < "$SD/dd_config")" "0|" "sobra despausada: fila livre"
# pausa de outro dono: nao tocada e nao e duvida
reset; printf '1|athos: parada' > "$SD/dd_config"; printf '9000' > "$SD/free"; run_d3; expect 10 "ja recuperado" "sobra de OUTRO dono: nao e duvida, 10"; hasnt "$OUT" "fila" "sobra de outro dono: a linha nao fala da fila"
# fila ilegivel no inicio: nao sei ≠ "nada a fazer"
for dm in down http500 garbage; do
  reset; echo "$dm" > "$SD/dd_mode"; printf '9000' > "$SD/free"; run_d3
  expect 30 "fila do demand-dashboard ilegivel no inicio" "fila ilegivel ($dm) + livre 9000: 30, nao 10"; hasnt "$OUT" "D3 nada a fazer" "fila ilegivel ($dm): a cabeca da linha nao e 'nada a fazer'"; eq "$(kicks)" "" "fila ilegivel ($dm): nada reiniciado"; eq "$(npatch)" 0 "fila ilegivel ($dm): nenhum PATCH"
done
reset; echo down > "$SD/dd_mode"; for l in demand-dashboard map-viewer ficha360 clientes-dashboard; do setproc $l 2 -; done; run_d3
expect 30 "ilegivel no inicio" "fila ilegivel + nenhum daemon elegivel: 30"
reset; echo down > "$SD/dd_mode"; addpix dialing 5; run_d3; expect 30 "ilegivel no inicio" "fila ilegivel + ligacao em curso (adiado): 30, nao 10"
# fila ilegivel mas ja agiu em outro daemon: rc 0, a linha avisa logo no comeco
reset; echo down > "$SD/dd_mode"; setproc demand-dashboard 2 -; run_d3
expect 0 "agiu: fila do demand-dashboard ilegivel no inicio" "fila ilegivel + reiniciou outro daemon: rc 0 e a linha avisa no comeco"; has "$OUT" "reiniciei map-viewer" "fila ilegivel + agiu: diz o que reiniciou"
# o aviso vem ANTES do que pode ser cortado nos 290: uma linha longa de pulos nao o derruba
reset; echo down > "$SD/dd_mode"; for l in demand-dashboard map-viewer ficha360 clientes-dashboard; do setproc $l 3 00:30; done; run_d3
expect 30 "ilegivel no inicio" "fila ilegivel + linha longa de pulos: o aviso sobrevive ao corte de 290"
# dry-run nao le a fila e nao muda de rc por causa dela
reset; echo down > "$SD/dd_mode"; run_d3 --dry-run; expect 10 "DRY-RUN D3: faria reiniciar" "dry-run com fila ilegivel: sem efeito (dry-run nao confere a fila)"

section "TERM: a linha so diz da fila o que foi conferido (gate-fix 1)"
# term_run <arquivo-sinal em $SD> <comando ao chegar no ponto, ou vazio> [VAR=valor ...] — roda o degrau em segundo plano, manda TERM quando o sinal aparece; deixa OUT/RC como o run_d3
term_run() {
  local sig=$1 act=$2 d3pid; shift 2
  rm -f "$W/term.out" "$W/term.rc"
  ( env -i HOME="$W/home" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$W/tmp" STUB_DIR="$SD" DR_CITY="$CITY" DR_D3_WA="$WA" DR_D3_PIX_DB="$PIX" DR_D3_VOICE_DB="$VOICE" \
      DR_D3_GUARDED="$W/guarded" DR_D3_FREEZE_CMD="$W/freeze" DR_D3_ROUND_LOCK="$RLOCK" DR_FREE_MB_FILE="$SD/free" DR_SWAP_MB_FILE="$SD/swap" DR_D3_SETTLE_S=0 DR_D3_READY_S=3 DR_D3_DRAIN_S=3 DR_D3_DESPAUSE_S=3 \
      DR_D3_GUARD_SLACK_S=100 DR_D3_CMD_S=5 DR_D3_CURL_S=2 "$@" "$D3" --run > "$W/term.out" 2>&1; echo $? > "$W/term.rc" ) &
  BGP=$!; BG_PIDS="$BG_PIDS $BGP"
  for _ in $(seq 1 150); do [ -f "$SD/$sig" ] && break; sleep 0.1; done
  if [ ! -f "$SD/$sig" ]; then OUT=""; RC="?"; return 1; fi
  [ -z "$act" ] || eval "$act"
  d3pid=$(cat "$LOCK/pid" 2>/dev/null); kill -TERM "$d3pid" 2>/dev/null
  for _ in $(seq 1 150); do [ -f "$W/term.rc" ] && break; sleep 0.1; done
  OUT=$(cat "$W/term.out" 2>/dev/null); RC=$(cat "$W/term.rc" 2>/dev/null || echo ?); CALLS=$(cat "$SD/calls" 2>/dev/null)
  return 0
}
# TERM no meio do guardado com o daemon FORA DO AR: a despausa nao se confirma → a linha NAO pode dizer "conferida"
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo slow > "$SD/guarded.mode"
if term_run guarded.started "echo down > '$SD/dd_mode'"; then
  expect 20 "interrompido (TERM)" "TERM com o daemon fora do ar: 20"; has "$OUT" "fila do demand-dashboard NAO confirmada" "TERM + despausa nao confirmada: a linha diz 'NAO confirmada'"
  hasnt "$OUT" "conferida" "TERM + despausa nao confirmada: a linha NAO diz 'conferida'"; eq "$(cut -c1-2 < "$SD/dd_config")" "1|" "TERM + daemon fora do ar: a fila de fato ficou pausada (a linha nao mente)"; lockgone "TERM com daemon fora do ar"
else nope "TERM com daemon fora do ar: o guardado stub nao chegou a rodar"; fi
# TERM no meio do guardado e despausa recusada (400): idem
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo slow > "$SD/guarded.mode"
if term_run guarded.started "echo patch400 > '$SD/dd_mode'"; then
  expect 20 "fila do demand-dashboard NAO confirmada" "TERM + PATCH recusado (400): 20 e 'NAO confirmada'"; hasnt "$OUT" "conferida" "TERM + PATCH recusado: nao diz 'conferida'"
else nope "TERM + PATCH recusado: o guardado stub nao chegou a rodar"; fi
# TERM no meio do guardado com a fila OK: conferida de verdade
reset; setproc map-viewer 4 50; setproc ficha360 4 50; echo slow > "$SD/guarded.mode"
if term_run guarded.started ""; then
  expect 20 "fila do demand-dashboard conferida" "TERM com a fila acessivel: a linha diz 'conferida'"; hasnt "$OUT" "NAO confirmada" "TERM com a fila acessivel: nao diz 'NAO confirmada'"; eq "$(cut -c1-2 < "$SD/dd_config")" "0|" "TERM com a fila acessivel: pausa nossa desfeita"
else nope "TERM com a fila acessivel: o guardado stub nao chegou a rodar"; fi
# TERM quando NAO ha pausa nossa em aberto (reiniciando o map-viewer): a linha nao fala da fila
reset; setproc ficha360 4 50; hookfor map-viewer "touch '$SD/kick.started'; sleep 60"
if term_run kick.started ""; then
  expect 20 "interrompido (TERM)" "TERM sem pausa nossa em aberto: 20"; hasnt "$OUT" "fila" "TERM sem pausa nossa em aberto: a linha nao fala da fila"; eq "$(npatch)" 0 "TERM sem pausa nossa em aberto: nenhum PATCH"; lockgone "TERM sem pausa"
else nope "TERM sem pausa nossa: o kickstart stub nao chegou a rodar"; fi
# TERM no meio da despausa da sobra (daemon recusa o PATCH): o degrau tenta de novo na saida e a linha diz 'NAO confirmada'
reset; printf '1|disk-recovery-d3: restart guardado ga-1p1i5jr.3' > "$SD/dd_config"; echo patch400 > "$SD/dd_mode"; printf '9000' > "$SD/free"
( while ! grep -q PATCH-RECUSADO "$SD/calls" 2>/dev/null; do sleep 0.1; done; touch "$SD/sobra.tentou" ) & BG_PIDS="$BG_PIDS $!"
if term_run sobra.tentou "" DR_D3_DESPAUSE_S=30; then
  expect 20 "fila do demand-dashboard NAO confirmada" "TERM no meio da despausa da sobra: 20 e 'NAO confirmada'"; hasnt "$OUT" "conferida" "TERM no meio da despausa da sobra: nao diz 'conferida'"
  [ "$(printf '%s\n' "$CALLS" | grep -c PATCH-RECUSADO)" -ge 1 ] && ok "TERM no meio da despausa da sobra: tentou despausar" || nope "TERM no meio da despausa da sobra: nenhuma tentativa"
else nope "TERM no meio da despausa da sobra: o degrau nao chegou a tentar"; fi
# sobra nossa NAO despausada no inicio e TERM depois, com o PATCH ainda recusado: a leitura de agora vale mais que a do inicio (uma frase so, sem "NAO despausada" + "NAO confirmada" juntas)
reset; printf '1|disk-recovery-d3: restart guardado ga-1p1i5jr.3' > "$SD/dd_config"; echo patch400 > "$SD/dd_mode"; setproc ficha360 4 50; hookfor map-viewer "touch '$SD/kick.started'; sleep 60"
if term_run kick.started ""; then
  expect 20 "fila do demand-dashboard NAO confirmada" "sobra nao despausada + TERM: 20 e 'NAO confirmada'"; hasnt "$OUT" "NAO despausada" "sobra nao despausada + TERM: a frase do inicio sai da linha (vale a leitura de agora)"
else nope "sobra nao despausada + TERM: o kickstart stub nao chegou a rodar"; fi
# TERM no guardado DEPOIS de 3 reinicios (lista longa) com a fila inconfirmavel: o estado da fila vem antes da lista e sobrevive ao corte de 290
reset; setproc demand-dashboard 4 101; setproc clientes-dashboard 4 120; echo slow > "$SD/guarded.mode"
if term_run guarded.started "echo down > '$SD/dd_mode'"; then
  expect 20 "fila do demand-dashboard NAO confirmada" "TERM depois de 3 reinicios + fila inconfirmavel: a linha longa mantem 'NAO confirmada'"; has "$OUT" "depois de: map-viewer pid" "TERM depois de 3 reinicios: a lista do que foi reiniciado ainda aparece"
  has "$OUT" "ficha360 pid" "TERM depois de 3 reinicios: o 2o reiniciado esta na lista"
else nope "TERM depois de 3 reinicios: o guardado stub nao chegou a rodar"; fi

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

section "Safari: fecha o que esta aberto ha mais de 2 h, prova que saiu e nunca confunde ilegivel com fechado (ga-1p1i5jr.7)"
reset; run_d3; hasnt "$CALLS" "osascript" "so o helper SafariPlatformSupport na lista: Safari fechado, osascript nunca chamado"; hasnt "$OUT" "afari" "Safari fechado: a linha nao fala dele"
reset; printf '%5s 05:00:00 /Users/x/Safari.app/Contents/MacOS/SafariHelper\n%5s 05:00:00 /Applications/Safari Technology Preview.app/Contents/MacOS/Safari Technology Preview\n' 9200 9201 >> "$SD/apps"; run_d3 >/dev/null
hasnt "$CALLS" "osascript" "outro executavel com 'Safari' no nome (SafariHelper, Technology Preview): nao e o Safari"
reset; addsafari 1-02:00:00; run_d3; expect 0 "fechei Safari (aberto ha 26h)" "Safari aberto ha 26 h: fechado e a linha diz"; eq "$(seqall)" "O,map-viewer,G,demand-dashboard,ficha360," "Safari primeiro, depois os daemons (nao recuperou)"
has "$CALLS" "osascript -e tell application \"Safari\" to quit" "o quit e pelo osascript"; lockgone "Safari fechado"; [ ! -e "$STAMP" ] && ok "quit ok: nenhuma marca de falha" || nope "quit ok deixou marca de falha"
reset; addsafari 01:59:59; run_d3 >/dev/null; hasnt "$CALLS" "osascript" "Safari com 7199 s: ainda novo, nao e fechado"
reset; addsafari 02:00:00; run_d3 >/dev/null; has "$CALLS" "osascript" "Safari com 7200 s: fechado"
reset; addsafari 5-00:10:00; echo 'setfree=4700' > "$SD/osa.mode"; run_d3
expect 0 "parei: disco recuperado" "Safari fechado recupera o disco: para"; eq "$(seqall)" "O," "recuperou no Safari: nem bw-serve nem daemons"; has "$OUT" "fechei Safari (aberto ha 120h)" "recuperou no Safari: diz o que fez"
reset; addsafari 1-00:00:00; run_d3 --dry-run; expect 10 "faria reiniciar (maior primeiro): fechar safari (aberto ha 24h), map-viewer" "dry-run: diz que fecharia o Safari"; hasnt "$CALLS" "osascript" "dry-run: osascript nao chamado"; [ ! -e "$STAMP" ] && ok "dry-run: nenhuma marca gravada" || nope "dry-run gravou marca"
reset; addsafari 1-00:00:00; EXTRA_ENV="DR_D3_BUDGET_S=5"; run_d3; expect 10 "sem tempo para safari" "sem tempo para o Safari: nao comeca"; hasnt "$CALLS" "osascript" "sem tempo: osascript nao chamado"
# ── ilegivel NUNCA vira "fechado": a lista de processos vazia, com lixo ou que falha
for m in fail empty garbage; do
  reset; addsafari 1-00:00:00; touch "$SD/apps.$m"; run_d3; expect 0 "safari (lista de processos (ps) ilegivel)" "lista de processos $m: pulado como 'nao sei'"; hasnt "$CALLS" "osascript" "lista de processos $m: osascript nao chamado"
  reset; alloff; touch "$SD/apps.$m"; run_d3; expect 30 "safari (lista de processos (ps) ilegivel)" "lista de processos $m e nada mais elegivel: 30, nao 10"
done
# ── falha do quit: nao para o resto, rc 20, marca, nao repete por 6 h
reset; addsafari 1-00:00:00; echo 'rc=1' > "$SD/osa.mode"; run_d3
expect 20 "safari: osascript rc=1 (execution error: Not authorized" "osascript recusado: 20 e a linha diz o erro"; has "$OUT" "e reiniciei: map-viewer" "Safari que nao fecha nao impede os daemons (segue e diz)"; eq "$(seqall)" "O,map-viewer,G,demand-dashboard,ficha360," "osascript falhou: os daemons rodaram"
case "$(cat "$STAMP" 2>/dev/null)" in ''|*[!0-9]*) nope "osascript falhou: marca de falha ausente ou nao numerica" ;; *) ok "osascript falhou: marca de falha gravada (epoch)" ;; esac
run_d3; eq "$(printf '%s\n' "$CALLS" | grep -c '^osascript')" 1 "2a rodada dentro das 6 h: osascript NAO e repetido"; has "$OUT" "safari (quit falhou ha 0 min, nao repito antes de 360 min)" "2a rodada: a linha diz que nao repete"
echo $(( $(date +%s) - 22000 )) > "$STAMP"; run_d3 >/dev/null; eq "$(printf '%s\n' "$CALLS" | grep -c '^osascript')" 2 "falha de 22000 s atras (> 6 h): tenta de novo"
echo 'rc=0' > "$SD/osa.mode"; echo $(( $(date +%s) - 22000 )) > "$STAMP"; run_d3 >/dev/null; [ ! -e "$STAMP" ] && ok "quit ok depois de uma falha antiga: a marca some" || nope "marca ficou depois do quit ok"
reset; addsafari 1-00:00:00; for g in abc ""; do printf '%s' "$g" > "$STAMP"; run_d3 >/dev/null; hasnt "$CALLS" "osascript" "marca '$g' ilegivel: osascript nao chamado"; done
reset; alloff; addsafari 1-00:00:00; printf 'abc' > "$STAMP"; run_d3; expect 30 "marca da ultima falha de quit ilegivel" "marca ilegivel e nada mais a fazer: 30"
reset; addsafari 1-00:00:00; echo $(( $(date +%s) + 99999 )) > "$STAMP"; run_d3 >/dev/null; hasnt "$CALLS" "osascript" "marca do futuro (relogio voltou): nao sei quando falhou, nao tenta"
# Safari que falha (soft) E um daemon que falha (halting) na mesma rodada: a linha traz as DUAS falhas
reset; addsafari 1-00:00:00; echo 'rc=1' > "$SD/osa.mode"; echo 'rc=113' > "$SD/kick.com.whatsapp.map-viewer"; run_d3
expect 20 "safari: osascript rc=1" "Safari falha e o map-viewer tambem: a linha diz a falha do Safari"; has "$OUT" "map-viewer: kickstart rc=113" "Safari falha e o map-viewer tambem: a linha diz a falha do daemon"; eq "$(seqall)" "O,map-viewer," "as duas falhas: o daemon que falha para a rodada"
reset; addsafari 1-00:00:00; echo 'mode=noeffect' > "$SD/osa.mode"; EXTRA_ENV="DR_D3_SAFARI_QUIT_S=2"; run_d3; expect 20 "safari: osascript rc=0 mas o Safari seguiu aberto 2s depois" "osascript rc 0 mas o Safari fica: 20 (nao confia so no rc)"; [ -e "$STAMP" ] && ok "Safari que nao saiu: marca gravada" || nope "Safari que nao saiu: sem marca"
reset; addsafari 1-00:00:00; echo 'mode=breakps' > "$SD/osa.mode"; EXTRA_ENV="DR_D3_SAFARI_QUIT_S=2"; run_d3; expect 20 "a lista de processos ficou ilegivel: nao provei que o Safari saiu" "quit ok mas a prova ilegivel: 20, nunca 'fechei'"; hasnt "$OUT" "fechei Safari" "prova ilegivel: a linha nao diz que fechou"
reset; addsafari 1-00:00:00; echo 'mode=slow' > "$SD/osa.mode"; EXTRA_ENV="DR_D3_CMD_S=1"; run_d3; expect 20 "safari: osascript rc=124" "osascript travado (prompt de permissao): encerrado no teto, 20"

section "bw-serve: so passa de 800 MB (MEM+CMPRS), com o secret respondendo antes e depois; o valor do segredo nunca e lido (ga-1p1i5jr.7)"
reset; run_d3 >/dev/null; hasnt "$CALLS" "secret" "bw-serve nao carregado: nada feito, secret nao chamado"
reset; addbw 5001 08:00:00 "500M 300M"; run_d3 --dry-run; hasnt "$OUT" "bw-serve" "800 MB (500M+300M): nao passa de 800, fora"
reset; addbw 5001 08:00:00 "500M 301M"; run_d3 --dry-run; has "$OUT" "bw-serve (801 MB)" "801 MB: entra"
reset; addbw 5001 08:00:00 "900000K 0K"; run_d3 --dry-run; has "$OUT" "bw-serve (878 MB)" "unidade K convertida"
reset; addbw 5001 08:00:00 "1G 100M+"; run_d3 --dry-run; has "$OUT" "bw-serve (1124 MB)" "unidade G e sufixo + do top lidos"
reset; addbw 5001 08:00:00 "1.5G 2048K-"; run_d3 --dry-run; has "$OUT" "bw-serve (1538 MB)" "decimal e sufixo - do top lidos"
reset; addbw 5001 05:59:59 "700M 300M"; run_d3 --dry-run; hasnt "$OUT" "bw-serve" "bw-serve com 21599 s: ainda novo, fora"
reset; addbw 5001 06:00:00 "700M 300M"; run_d3 --dry-run; has "$OUT" "bw-serve (1000 MB)" "bw-serve com 21600 s: entra"
reset; addbw 5001 08:00:00 "700M 300M"; run_d3 --dry-run; hasnt "$CALLS" "secret" "dry-run: o secret NAO e chamado (ele pode carregar o job)"; hasnt "$CALLS" "kickstart" "dry-run com bw-serve grande: nenhum kickstart"
# ── ilegivel NUNCA vira "pequeno"/"ok"
for m in fail garbage; do
  reset; addbw 5001 08:00:00 "700M 300M"; touch "$SD/top.$m.5001"; run_d3; expect 0 "bw-serve (MEM+CMPRS (top) ilegivel)" "top $m: bw-serve pulado como 'nao sei', os daemons seguem"; hasnt "$(seqall)" "bw-serve" "top $m: bw-serve nao reiniciado"
done
reset; alloff; addbw 5001 08:00:00 "700M 300M"; rm -f "$SD/top.5001"; run_d3; expect 30 "bw-serve (MEM+CMPRS (top) ilegivel)" "top sem a linha de valores e nada mais elegivel: 30 (nao e '0 MB')"
reset; addbw 5001 08:00:00 "700X 300M"; run_d3 --dry-run; has "$OUT" "bw-serve (MEM+CMPRS (top) ilegivel)" "unidade desconhecida (X): ilegivel, nao entra como 0 MB"; hasnt "$OUT" "faria reiniciar (maior primeiro): bw-serve" "unidade desconhecida: bw-serve nao entra na lista do que faria"
reset; alloff; addbw 5001 08:00:00 "700M 300M"; echo 3 > "$SD/freeze.com.gastown.bw-serve"; run_d3; expect 30 "bw-serve (deploy_freeze ilegivel)" "freeze do bw-serve ilegivel: 30"
reset; addbw 5001 08:00:00 "700M 300M"; echo 0 > "$SD/freeze.com.gastown.bw-serve"; run_d3; has "$OUT" "bw-serve (congelado (deploy_freeze))" "bw-serve congelado: pulado"; hasnt "$(seqall)" "bw-serve" "bw-serve congelado: nao reiniciado"
reset; addbw 5001 08:00:00 "700M 300M"; touch "$SD/secret.fail"; run_d3; has "$(cat "$LOG")" "pulo bw-serve: secret ja falha antes do restart (cofre doente: nao mexo)" "secret ja falhando antes: o cofre nao e tocado (o motivo vai no log; a linha de 290 pode cortar o fim)"; hasnt "$(seqall)" "bw-serve" "secret ja falhando: sem kickstart do bw-serve"
reset; alloff; addbw 5001 08:00:00 "700M 300M"; touch "$SD/secret.fail"; run_d3; expect 30 "cofre doente" "secret ja falhando e nada mais a fazer: 30"
reset; addbw 5001 08:00:00 "700M 300M"; addpix dialing 5; run_d3; expect 10 "ligacao em curso (pix=1 voicebot=0) antes de bw-serve" "ligacao em curso: o bw-serve espera"; eq "$(seqall)" "S," "ligacao em curso: so o secret de antes rodou, nem bw-serve nem daemons"
# ── restart
reset; addbw 5001 08:00:00 "700M 300M"; echo '30M 20M' > "$SD/top.2001"; echo 'setfree=4700' > "$SD/kick.com.gastown.bw-serve"; run_d3
expect 0 "reiniciei bw-serve pid 5001->2001 1000->50 MB secret ok" "bw-serve grande: reiniciado, PID novo + secret ok, MEM antes->depois"; eq "$(seqall)" "S,bw-serve,S," "secret ANTES, kickstart, secret DEPOIS; recuperou: nenhum daemon"
has "$OUT" "parei: disco recuperado" "recuperou no bw-serve: diz por que parou"; has "$CALLS" "secret motherduck-token" "a prova usa o item configurado"
eq "$(grep -rl S3CR3T "$W" --exclude-dir=bin 2>/dev/null | head -1)" "" "o VALOR do segredo nao vazou (nem linha, nem log, nem arquivo temporario)"; lockgone "bw-serve reiniciado"
has "$CALLS" "stdout-do-secret=devnull" "o stdout do secret vai para /dev/null (o valor nao passa nem pelo arquivo temporario)"; hasnt "$CALLS" "stdout-do-secret=CAPTURADO" "nenhuma chamada do secret com o stdout capturado"
reset; addsafari 1-00:00:00; addbw 5001 08:00:00 "700M 300M"; run_d3; expect 0 "fechei Safari" "Safari + bw-serve + daemons"; eq "$(seqall)" "O,S,bw-serve,S,map-viewer,G,demand-dashboard,ficha360," "ordem: Safari, bw-serve, daemons"
reset; addbw 5001 08:00:00 "700M 300M"; echo 'rc=7' > "$SD/kick.com.gastown.bw-serve"; run_d3; expect 20 "bw-serve: kickstart rc=7" "kickstart do bw-serve falha: 20"; eq "$(seqall)" "S,bw-serve," "bw-serve falhou: para, nenhum daemon"
reset; addbw 5001 08:00:00 "700M 300M"; echo 'mode=samepid' > "$SD/kick.com.gastown.bw-serve"; run_d3; expect 20 "bw-serve: sem PID novo + secret respondendo" "bw-serve com o mesmo PID: 20"
reset; addbw 5001 08:00:00 "700M 300M"; hookbw "touch '$SD/secret.fail'"; EXTRA_ENV="DR_D3_READY_S=2"; run_d3
expect 20 "COFRE SEM RESPOSTA" "secret falha DEPOIS do restart: 20 e o aviso 'COFRE SEM RESPOSTA'"; eq "$(seqall | sed 's/S,//g')" "bw-serve," "secret falhou depois: o degrau PARA, nenhum daemon reiniciado"; lockgone "secret falhou depois"
reset; addbw 5001 08:00:00 "700M 300M"; hookbw "echo 2 > '$SD/secret.fail_n'"; echo 'setfree=4700' >> "$SD/kick.com.gastown.bw-serve"; EXTRA_ENV="DR_D3_READY_S=15"; run_d3
expect 0 "bw-serve pid 5001->2001" "cofre voltando devagar (2 falhas, 3a ok): espera e prova"
reset; addbw 5001 08:00:00 "700M 300M"; EXTRA_ENV="DR_D3_BUDGET_S=5"; run_d3; expect 10 "sem tempo para bw-serve" "sem tempo para o bw-serve: nao comeca"; hasnt "$CALLS" "secret" "sem tempo: secret nao chamado"

section "label ausente x dominio errado, sobra de pausa antes de ler o disco, teto de tempo em segundos de relogio (ga-1p1i5jr.7)"
reset; grep -v map-viewer "$SD/procs" > "$SD/procs.new"; mv "$SD/procs.new" "$SD/procs"; run_d3; expect 0 "map-viewer (nao carregado no launchd)" "label fora da lista (dominio certo): 'nao carregado', os outros agem"; hasnt "$(kicks)" "map-viewer" "label nao carregado: nao reiniciado"
reset; touch "$SD/launchctl.nodomain"; run_d3; expect 30 "launchctl ilegivel" "lista sem nenhum label da cidade (dominio errado): 30, nao 'nada a fazer'"; eq "$(kicks)" "" "dominio errado: nada reiniciado"
reset; printf '1|disk-recovery-d3: restart guardado ga-1p1i5jr.3' > "$SD/dd_config"; rm -f "$SD/free"; run_d3
expect 30 "sobra de pausa nossa da rodada anterior: despausada e conferida" "df ilegivel + sobra de pausa nossa: a linha conta a sobra desfeita"; eq "$(cut -c1-2 < "$SD/dd_config")" "0|" "df ilegivel: a pausa nossa foi desfeita ANTES de ler o disco"
reset; printf '1|disk-recovery-d3: restart guardado ga-1p1i5jr.3' > "$SD/dd_config"; echo patch400 > "$SD/dd_mode"; rm -f "$SD/free"; run_d3
expect 20 "fila do demand-dashboard NAO despausada" "df ilegivel + sobra que o PATCH recusou: 20 (a fila segue parada e a linha diz)"; has "$OUT" "df do volume Data ilegivel" "df ilegivel + sobra: a linha tambem diz o df"
# run_bounded: o teto de 1 s e de RELOGIO. Com o `sleep 0.05` 10x mais lento (host carregado) contar tiques levaria ~10 s
touch "$SD/sleep.slow"; rb=$( ( eval "$(sed -n '/^run_bounded() {/,/^}/p' "$D3")"; PATH="$BIN:$PATH"; export STUB_DIR="$SD" TMPDIR="$W/tmp"; T0=$SECONDS; run_bounded 1 sleep 30; echo "$? $((SECONDS - T0))" ) 2>/dev/null ); rm -f "$SD/sleep.slow"
set -- $rb; eq "${1:-?}" 124 "run_bounded: comando que estoura o teto sai com 124"; [ "${2:-99}" -le 6 ] && ok "run_bounded: teto de 1 s em relogio (${2:-?} s com o sleep 0.05 10x mais lento)" || nope "run_bounded: teto de 1 s levou ${2:-?} s com o sleep lento (conta tiques, nao segundos)"

printf '\n%s passaram, %s falharam\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
