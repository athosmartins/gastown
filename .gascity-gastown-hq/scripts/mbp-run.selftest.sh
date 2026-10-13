#!/usr/bin/env bash
# mbp-run.selftest.sh — hermético: ssh/rsync são stubs no PATH; nada toca o MBP nem o live.
#
# Contents
#   Casos · Preflight de saúde (ga-9e2rjh) · Presença do Athos (ga-77c1qg) · Controle negativo
#
# CASOS: off(99) · inalcançável(98) · RAM baixa(98) · bateria baixa(98) · slots cheios(96) ·
#   slot de dono morto é reaped · rc do remoto propagado e logado · ssh 255 no meio(98) · nota de shared/data ·
#   slot liberado ao fim · exec: push/pull + limpeza do scratch · uso errado(97) · base ausente(97).
# PREFLIGHT DE SAÚDE (ga-9e2rjh): o stub do ssh EXECUTA o script remoto de verdade (sob bash 3.2 quando existe /bin/bash,
#   como no MBP) com vm_stat/sysctl/pmset/memory_pressure falsos — o que se testa é o parsing real, não uma saída enlatada.
#   swap ALTO mas parado passa (o defeito: 5.248 MB recusou com 3,8 GB de RAM livre) · teto absoluto do swap · swap que
#   CRESCE recusa (fronteira 128/129) · swap encolhendo passa · pressão 2/4 recusa · pressão/swap/RAM ILEGÍVEL recusa com
#   motivo próprio ("ilegivel:*"), nunca igual a "baixo" (inclui pmset ilegível: não vira "bateria") · "1.50G" lido como 1536 · page size vem do cabeçalho do vm_stat ·
#   cada recusa vira UMA linha no log com motivo e números · --check/--seed não logam recusa · a contagem de 72 h do
#   mbp-offload.sh (counts): sem log / vazio / por motivo / fora da janela, e linha ilegível AVISADA (nunca omitida).
#   MBP_OFFLOAD_UNDER_TEST=<script> roda os casos da contagem contra outro mbp-offload.sh.
# CONTROLE NEGATIVO: cada porta do preflight é removida do script (sed no marcador "# gate:<nome>") e o mutante TEM que
#   deixar de reproduzir o (rc, motivo) do script real — prova que o teste enxerga o defeito, inclusive "ilegível virou baixo".
# PRESENÇA DO ATHOS (ga-77c1qg): a biblioteca mbp-presence.sh roda de verdade (ioreg/plutil/pmset falsos, plist no formato REAL do
#   ioreg): bloqueada vence input recente · 599 s não é fora e 600 s é · app segurando a tela segura o "fora" · cada leitura que falha
#   cai em "uso", nunca em "livre" · só dá para forçar PIORAR (nunca forçar "livre"). mbp-run: teto de slots por modo (núcleos, RAM,
#   1 em uso, total e não só números baixos), pausa (local e no MBP) rc 99 antes da saúde, seed em fundo, e a execução SUPERVISIONADA
#   rodando de verdade sob bash com python/taskpolicy/renice falsos: prioridade na largada, rebaixamento no meio da execução quando o
#   Athos volta ou pausa, sem atrasar o fim da execução nem deixar processo para trás. mbp-offload: modos do status, tarefas órfãs,
#   JSON, total do dia (sob cada jq), pause/resume. gascity-mbp (mbp-controle.sh). MBP_SELFTEST_ONLY=presenca|chave roda só essa parte;
#   MBP_SELFTEST_SKIP=presenca pula a presença (a suíte antiga, sozinha, cabe nos 900 s do prod test do ga-9e2rjh).
# MBP_RUN_UNDER_TEST=<script> roda a mesma bateria contra outro mbp-run.sh (ex.: o antigo, para ver os testes novos falharem).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="${MBP_RUN_UNDER_TEST:-$HERE/mbp-run.sh}"
T=$(mktemp -d "${TMPDIR:-/tmp}/mbp-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/bin" "$T/fake" "$T/city/.gc/logs" "$T/wt/tests"
: > "$T/wt/tests/test_x.py"

# stub ssh: lê o script do stdin, decide pelo marcador "# MBP:<NOME>" e pelo STUB_* do ambiente.
# PREFLIGHT executa o script recebido (stdin) com as ferramentas falsas de $FAKE na frente do PATH; STUB_PF_RAW injeta a
# saída crua no lugar (para testar só o lado local: campo vazio, número com lixo...).
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [ "${STUB_UNREACHABLE:-0}" = 1 ]; then exit 255; fi
case "$args" in *"bash -s"*) s=$(cat); name=$(printf '%s' "$s" | sed -n '1s/^# MBP://p') ;; *) name="DIRECT"; s="" ;; esac
echo "$name" >> "$STUB_LOG"
# HOME falso: a biblioteca de presença e a listagem de tarefas leem $HOME/gt-remote (PAUSE, slots/) no "MBP"
rexec() { printf '%s\n' "$s" | HOME="$STUB_HOME" PATH="$FAKE:$PATH" STUB_REAL_SLEEP="${1:-0}" "$STUB_REMOTE_BASH" -s -- ${2:-}; }
case "$name" in
  PREFLIGHT)
    if [ -n "${STUB_PF_RAW:-}" ]; then printf '%b\n' "$STUB_PF_RAW"; else
      rm -f "$STUB_SWAPCNT"; sample=""
      case "$args" in *"bash -s -- "*) sample=${args##*bash -s -- } ;; esac
      rexec 0 "$sample"
    fi ;;
  SLOT_ACQUIRE)
    if [ "${STUB_SLOTS:-free}" = exec ]; then rexec 0; exit $?
    elif [ "${STUB_SLOTS:-free}" = full ]; then
      echo "BUSY 1 otherhost:11:$(date +%s) 0"; echo "BUSY 2 otherhost:12:$(date +%s) 0"; echo "BUSY 3 otherhost:13:$(date +%s) 0"; echo FULL; exit 3
    elif [ "${STUB_SLOTS:-free}" = dead ] && [ ! -f "$STUB_REAPED" ]; then
      h=$(hostname -s); echo "BUSY 1 $h:999999:$(date +%s) 0"; echo "BUSY 2 otherhost:12:$(date +%s) 0"; echo "BUSY 3 otherhost:13:$(date +%s) 0"; echo FULL; exit 3
    else echo "SLOT=1"; fi ;;
  SLOT_REAP) if [ "${STUB_SLOTS:-free}" = exec ]; then rexec 0; exit $?; else touch "$STUB_REAPED"; fi ;;
  SLOT_RELEASE) if [ "${STUB_SLOTS:-free}" = exec ]; then rexec 0; exit $?; fi ;;
  MIRROR) if [ "${STUB_NOBASE:-0}" = 1 ]; then echo NOBASE; exit 97; else echo MIRROR_OK; fi ;;
  RUN|EXEC)
    printf '%s\n' "$s" > "$(dirname "$STUB_LOG")/last-script-$name.sh"
    # STUB_RUNMODE=exec: executa o script recebido de verdade (sleep REAL: o vigia precisa esperar), com python/taskpolicy/renice falsos
    if [ "${STUB_RUNMODE:-canned}" = exec ]; then rexec 1; exit $?
    elif [ "$name" = RUN ]; then [ "${STUB_RUN_RC:-0}" = 255 ] && exit 255; echo "${STUB_RUN_OUT:-stub-run-ok}"; exit "${STUB_RUN_RC:-0}"
    else echo "stub-exec-ok"; exit "${STUB_RUN_RC:-0}"; fi ;;
  DIRECT) echo "DIRECT:$args" >> "$STUB_LOG"; [ -z "${STUB_DIRECT_OUT:-}" ] || echo "$STUB_DIRECT_OUT"; exit "${STUB_DIRECT_RC:-0}" ;;
esac
exit 0
EOF
cat > "$T/bin/rsync" <<'EOF'
#!/usr/bin/env bash
echo "RSYNC:$*" >> "$STUB_LOG"
case "$*" in *gt-remote/bin*) [ "${STUB_RSYNC_FAIL_BIN:-0}" = 1 ] && exit 1 ;; esac   # só a cópia de ferramentas para ~/gt-remote/bin
exit "${STUB_RSYNC_RC:-0}"
EOF

# ferramentas falsas do MBP (só o preflight as enxerga). Padrão saudável: 8000 MB livres, swap 1000 MB parado, pressão 1.
cat > "$T/fake/vm_stat" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_VM_FAIL:-0}" = 1 ] && exit 1
ps=${STUB_PAGE_SIZE:-16384}
total=$(( ${STUB_AVAIL_MB:-8000} * 1048576 / ps ))
f=$(( total / 2 )); i=$(( total / 4 )); s=$(( total - f - i ))
out="Mach Virtual Memory Statistics: (page size of $ps bytes)
Pages free:                               $f.
Pages active:                             123456.
Pages inactive:                           $i.
Pages speculative:                        $s.
Pages throttled:                          0.
Pages wired down:                         54321.
Pages purgeable:                          100.
Pages occupied by compressor:             ${STUB_COMP_PAGES:-337212}.
Swapouts:                                 1."
if [ -n "${STUB_VM_DROP:-}" ]; then printf '%s\n' "$out" | grep -v "$STUB_VM_DROP"; else printf '%s\n' "$out"; fi
EOF
# sysctl: vm.swapusage devolve STUB_SWAP_MB na 1ª leitura e STUB_SWAP2_MB (padrão = o mesmo) nas seguintes; *_RAW devolve texto cru
cat > "$T/fake/sysctl" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -n ] && shift
case "${1:-}" in
  vm.swapusage)
    n=$(cat "$STUB_SWAPCNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$STUB_SWAPCNT"
    if [ "$n" -le 1 ]; then raw="${STUB_SWAP_RAW:-}"; mb="${STUB_SWAP_MB:-1000}"
    else raw="${STUB_SWAP2_RAW:-${STUB_SWAP_RAW:-}}"; mb="${STUB_SWAP2_MB:-${STUB_SWAP_MB:-1000}}"; fi
    if [ -n "$raw" ]; then printf '%s\n' "$raw"; else echo "total = 8192.00M  used = ${mb}.00M  free = 1.00M  (encrypted)"; fi ;;
  kern.memorystatus_vm_pressure_level) [ "${STUB_PRESSURE_FAIL:-0}" = 1 ] && exit 1; echo "${STUB_PRESSURE:-1}" ;;
  vm.loadavg) echo "{ 1.00 1.10 1.20 }" ;;
  hw.ncpu) [ "${STUB_NCPU_FAIL:-0}" = 1 ] && exit 1; echo "${STUB_NCPU:-12}" ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/fake/memory_pressure" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_MP_FAIL:-0}" = 1 ] && exit 1
echo "The system has 17179869184 (1048576 pages with a page size of 16384)."
echo "System-wide memory free percentage: ${STUB_MP_PCT:-54}%"
EOF
cat > "$T/fake/pmset" <<'EOF'
#!/usr/bin/env bash
case "$*" in *assertions*)
  [ "${STUB_ASSERT_FAIL:-0}" = 1 ] && exit 1
  [ -n "${STUB_ASSERT_RAW:-}" ] && { printf '%s\n' "$STUB_ASSERT_RAW"; exit 0; }
  printf 'Assertion status system-wide:\n   BackgroundTask                 0\n   PreventUserIdleDisplaySleep    %s\n   PreventSystemSleep             0\n' "${STUB_HOLD:-0}"
  exit 0 ;;
esac
[ "${STUB_PMSET_FAIL:-0}" = 1 ] && exit 1
[ -n "${STUB_PMSET_RAW:-}" ] && { printf '%s\n' "$STUB_PMSET_RAW"; exit 0; }
if [ "${STUB_POWER:-ac}" = ac ]; then src="AC Power"; else src="Battery Power"; fi
printf "Now drawing from '%s'\n -InternalBattery-0 (id=1)\t%s%%; discharging; 3:00 remaining present: true\n" "$src" "${STUB_BATT:-90}"
EOF
cat > "$T/fake/sleep" <<'EOF'
#!/usr/bin/env bash
if [ "${STUB_REAL_SLEEP:-0}" = 1 ]; then exec /bin/sleep "$@"; fi
echo "SLEEP:$*" >> "$STUB_LOG"
EOF
# ioreg falso, no formato REAL (medido no MBP em 12/10: dict raiz com IOConsoleUsers[ {CGSSessionScreenIsLocked, kCGSSessionOnConsoleKey, ...} ];
# a marca de bloqueio só existe com a tela bloqueada). Estado: env STUB_LOCKED/STUB_IDLE_S, ou o arquivo STUB_STATE_FILE (muda no meio da execução).
#   STUB_LOCKED: 1 bloqueada · 0 sem a marca · false marca=false · two (2 sessões, a do console bloqueada) · notconsole (nenhuma no console)
#                none (sem IOConsoleUsers) · garbage (não é plist) · fail (ioreg sai 1)
#   STUB_IDLE_S: segundos (ex. "30" ou "30,9000" = duas entradas) · none (nenhuma entrada) · fail (ioreg sai 1) · qualquer texto = entrada ilegível
cat > "$T/fake/ioreg" <<'EOF'
#!/usr/bin/env bash
lk=${STUB_LOCKED:-1}; idle=${STUB_IDLE_S:-5000}
if [ -n "${STUB_STATE_FILE:-}" ] && [ -f "$STUB_STATE_FILE" ]; then . "$STUB_STATE_FILE"; lk=${locked:-$lk}; idle=${idle_s:-$idle}; fi
sess() { # locked(true|false|absent) onconsole(true|false)
  printf '\t\t<dict>\n'
  [ "$1" = absent ] || printf '\t\t\t<key>CGSSessionScreenIsLocked</key>\n\t\t\t<%s/>\n' "$1"
  printf '\t\t\t<key>kCGSSessionIDKey</key>\n\t\t\t<integer>257</integer>\n\t\t\t<key>kCGSSessionOnConsoleKey</key>\n\t\t\t<%s/>\n\t\t\t<key>kCGSSessionUserNameKey</key>\n\t\t\t<string>user</string>\n\t\t</dict>\n' "$2"
}
case "$*" in
  *"-n Root"*)
    case "$lk" in
      fail) exit 1 ;;
      garbage) echo "this is not a plist"; exit 0 ;;
    esac
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n'
    [ "$lk" = 1 ] && printf '\t<key>IOConsoleLocked</key>\n\t<true/>\n'
    if [ "$lk" != none ]; then
      printf '\t<key>IOConsoleUsers</key>\n\t<array>\n'
      case "$lk" in
        1) sess true true ;;
        0) sess absent true ;;
        false) sess false true ;;
        two) sess false false; sess true true ;;
        notconsole) sess true false ;;
      esac
      printf '\t</array>\n'
    fi
    printf '\t<key>IOKitBuildVersion</key>\n\t<string>Darwin Kernel</string>\n</dict>\n</plist>\n' ;;
  *"-c IOHIDSystem"*)
    case "$idle" in
      fail) exit 1 ;;
      none) exit 0 ;;
    esac
    printf '%s\n' "$idle" | tr ',' '\n' | while read -r v; do
      case "$v" in ''|*[!0-9]*) printf '      | |   "HIDIdleTime" = %s\n' "$v" ;; *) printf '      | |   "HIDIdleTime" = %s000000000\n' "$v" ;; esac
    done ;;
esac
EOF
# taskpolicy falso: `taskpolicy -b cmd...` registra e executa cmd; `taskpolicy -b -p PID` só registra. renice falso só registra.
cat > "$T/fake/taskpolicy" <<'EOF'
#!/usr/bin/env bash
echo "TP:$*" >> "$STUB_LOG"
[ "${2:-}" = -p ] && exit 0   # `taskpolicy -b -p PID`: só registra (o `-p` do pytest, mais adiante na linha, NÃO conta)
shift   # -b
exec "$@"
EOF
# nice falso: registra o `-n N` pedido e executa o comando SEM aplicar (a árvore de processos da máquina de teste já pode estar em nice 10,
# e nice 20 é o teto: o valor real não distinguiria os modos)
cat > "$T/fake/nice" <<'EOF'
#!/usr/bin/env bash
echo "NICE:$1 $2" >> "$STUB_LOG"
shift 2
exec "$@"
EOF
cat > "$T/fake/renice" <<'EOF'
#!/usr/bin/env bash
echo "RENICE:$*" >> "$STUB_LOG"
EOF
# python falso do venv do MBP (só roda quando STUB_RUNMODE=exec): registra o nice com que nasceu e os slots que viu, dorme, sai com STUB_RUN_RC
mkdir -p "$T/home/gt-remote/venv/bin" "$T/home/gt-remote/exec" "$T/home/gt-remote/slots"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do mkdir -p "$T/home/gt-remote/mirror/wa-$i" "$T/home/gt-remote/exec/$i"; done
cat > "$T/home/gt-remote/venv/bin/python" <<'EOF'
#!/usr/bin/env bash
echo "PY args=$*" >> "$STUB_LOG"
cat "$HOME"/gt-remote/slots/*/info >> "$STUB_SEEN" 2>/dev/null
# gatilhos de virada RELATIVOS ao início do trabalho (um temporizador do teste correria contra o preflight e o rsync, que numa máquina carregada demoram)
if [ -n "${STUB_FLIP_STATE:-}" ]; then ( /bin/sleep 1.5; printf '%b' "$STUB_FLIP_STATE" > "$STUB_STATE_FILE" ) </dev/null >/dev/null 2>&1 & fi
if [ -n "${STUB_FLIP_PAUSE:-}" ]; then ( /bin/sleep 1.5; echo "origem=mbp desde=agora" > "$HOME/gt-remote/PAUSE" ) </dev/null >/dev/null 2>&1 & fi
/bin/sleep "${STUB_RUN_SLEEP:-0}"
# espera (limitada: N voltas de 0,5 s) o vigia rebaixar a árvore, em vez de dormir um tempo fixo: numa máquina com load 90 cada ioreg/ps do vigia
# leva segundos, e um sleep fixo faria o teste medir a carga da máquina, não o rebaixamento
if [ -n "${STUB_WAIT_RENICE:-}" ]; then i=0; while [ "$i" -lt "$STUB_WAIT_RENICE" ] && ! grep -q '^RENICE:' "$STUB_LOG"; do /bin/sleep 0.5; i=$((i+1)); done; fi
echo "5 passed in 0.1s"
exit "${STUB_RUN_RC:-0}"
EOF
chmod +x "$T/bin/ssh" "$T/bin/rsync" "$T/fake/"* "$T/home/gt-remote/venv/bin/python"

unset MBP_MAX_SWAP_MB MBP_MAX_SWAP_GROWTH_MB MBP_SWAP_SAMPLE_S MBP_MAX_PRESSURE_LEVEL MBP_MIN_AVAIL_MB MBP_MIN_BATT MBP_MAX_SLOTS MBP_SLOT_MAX_AGE_S MBP_RUN_TIMEOUT_S MBP_HOST
export PATH="$T/bin:$PATH" MBP_CITY="$T/city" MBP_SSH="$T/bin/ssh" MBP_RSYNC="$T/bin/rsync"
export STUB_LOG="$T/stub.log" STUB_REAPED="$T/reaped" STUB_SWAPCNT="$T/swapcnt" FAKE="$T/fake" STUB_HOME="$T/home" STUB_SEEN="$T/seen-info" STUB_STATE_FILE="$T/presence.state"
if [ -x /bin/bash ]; then export STUB_REMOTE_BASH=/bin/bash; else export STUB_REMOTE_BASH=bash; fi
FLAG="$T/city/.gc/mbp-offload.on"
FLAG_PAUSE="$T/city/.gc/mbp-offload.pause"
J="$T/city/.gc/logs/mbp-run.jsonl"
fails=0; n=0
reset() { : > "$STUB_LOG"; rm -f "$STUB_REAPED" "$J" "$STUB_STATE_FILE" "$STUB_SEEN" "$FLAG_PAUSE" "$T/home/gt-remote/PAUSE"; mkdir -p "$T/home/gt-remote/slots"; find "$T/home/gt-remote/slots" -mindepth 1 -delete 2>/dev/null
  unset STUB_LOCKED STUB_IDLE_S STUB_HOLD STUB_ASSERT_FAIL STUB_ASSERT_RAW STUB_NCPU STUB_NCPU_FAIL STUB_RSYNC_FAIL_BIN STUB_WAIT_RENICE STUB_RUNMODE STUB_RUN_SLEEP STUB_FLIP_STATE STUB_FLIP_PAUSE STUB_DIRECT_OUT STUB_DIRECT_RC STUB_REAL_SLEEP MBP_FORCE_PRESENCE MBP_MAX_SLOTS MBP_USE_SLOTS MBP_SLOT_MEM_MB MBP_AWAY_IDLE_S MBP_WATCH_S PRESENCE_FORCE_USO PRESENCE_AWAY_S
  unset STUB_UNREACHABLE STUB_AVAIL_MB STUB_SWAP_MB STUB_SWAP2_MB STUB_SWAP_RAW STUB_SWAP2_RAW STUB_PRESSURE STUB_PRESSURE_FAIL STUB_VM_FAIL STUB_VM_DROP STUB_PAGE_SIZE STUB_COMP_PAGES STUB_MP_FAIL STUB_MP_PCT STUB_PF_RAW STUB_POWER STUB_BATT STUB_PMSET_FAIL STUB_PMSET_RAW STUB_SLOTS STUB_NOBASE STUB_RUN_RC STUB_RUN_OUT STUB_RSYNC_RC; }
expect() { # nome rc_esperado rc_real [grep-no-log padrão]
  n=$((n+1))
  if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; else echo "FAIL $1: esperado rc=$2, veio $3"; fails=$((fails+1)); fi
}
eq() { # nome esperado real
  n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1 ($3)"; else echo "FAIL $1: esperado '$2', veio '$3'"; fails=$((fails+1)); fi
}
has() { # nome arquivo padrão
  n=$((n+1)); if grep -q -E "$3" "$2"; then echo "ok   $1"; else echo "FAIL $1: '$3' ausente em $2"; fails=$((fails+1)); fi
}
hasnt() {
  n=$((n+1)); if grep -q -E "$3" "$2"; then echo "FAIL $1: '$3' presente em $2"; fails=$((fails+1)); else echo "ok   $1"; fi
}
run() { "$RUN" --repo wa --dir "$T/wt" "$@" >"$T/out" 2>"$T/err"; echo $?; }
chk() { "$RUN" --check >"$T/out" 2>"$T/err"; echo $?; }
# outcome <script>: "rc:motivo" de uma execução; o motivo vem da última linha de recusa do log ("-" se não houve recusa)
outcome() {
  local s="$1" rc r
  rm -f "$J"
  "$s" --repo wa --dir "$T/wt" -- tests/test_x.py >/dev/null 2>&1; rc=$?
  r=$(grep '"mode":"preflight"' "$J" 2>/dev/null | tail -1 | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p')
  echo "$rc:${r:--}"
}

# ---- PRESENÇA DO ATHOS (ga-77c1qg) ---------------------------------------------------------------------------------
# A biblioteca e o runner rodam DE VERDADE (sob /bin/bash 3.2 quando existe, como no MBP) com ioreg/pmset/taskpolicy/renice/python falsos;
# o plist do ioreg falso tem o formato REAL medido no MBP. Nada toca o MBP verdadeiro.
LIB="$HERE/mbp-presence.sh"
LIBX=""   # biblioteca sob teste (os controles negativos apontam para uma mutante)
libp() { HOME="$T/home" PATH="$FAKE:$PATH" "$STUB_REMOTE_BASH" -c 'PRESENCE_LIB_ONLY=1; . "$1"; presence_probe' _ "${LIBX:-$LIB}" 2>/dev/null; }
pv() { libp | sed -n "s/^$1=//p"; }
verdict() { local o; o=$(libp); printf '%s/%s' "$(printf '%s\n' "$o" | sed -n 's/^presence=//p')" "$(printf '%s\n' "$o" | sed -n 's/^presence_why=//p')"; }
mkslot() { mkdir -p "$T/home/gt-remote/slots/$1"; printf '%s\n' "${2:-otherhost:1:$(date +%s)}" > "$T/home/gt-remote/slots/$1/owner"; }
slot_names() { ls -1 "$T/home/gt-remote/slots" | sort -n | tr '\n' ' '; }
capof() { "${1:-$RUN}" --check 2>/dev/null | sed -n 's/^slot_cap=//p'; }
runx() { local s="$1"; shift; "$s" --repo wa --dir "$T/wt" -- "$@" >"$T/out" 2>"$T/err"; echo $?; }
runs() { MBP_WATCH_S="${MBP_WATCH_S:-1}" run "$@"; }   # execução supervisionada com o vigia a cada 1 s (reset limpa MBP_WATCH_S)
PF_OK='avail_mb=8000\nswap_mb=5000\nswap_delta_mb=0\npressure=1\npower=ac\nbatt=90'

presenca_cases() {
echo "--- presença do Athos (ga-77c1qg)"
reset
# --- a regra, na biblioteca ---
eq "bloqueada → livre" "livre/bloqueada" "$(STUB_LOCKED=1 STUB_IDLE_S=5 verdict)"
eq "desbloqueada + teclado há 30 s → uso" "uso/input_recente" "$(STUB_LOCKED=0 STUB_IDLE_S=30 verdict)"
eq "599 s sem input (fronteira) → uso" "uso/input_recente" "$(STUB_LOCKED=0 STUB_IDLE_S=599 verdict)"
eq "600 s sem input (fronteira) → livre" "livre/ocioso" "$(STUB_LOCKED=0 STUB_IDLE_S=600 verdict)"
eq "marca de bloqueio =false → desbloqueada" "uso/input_recente" "$(STUB_LOCKED=false STUB_IDLE_S=30 verdict)"
eq "limiar configurável (PRESENCE_AWAY_S=60): 61 s → livre" "livre/ocioso" "$(PRESENCE_AWAY_S=60 STUB_LOCKED=0 STUB_IDLE_S=61 verdict)"
eq "limiar inválido volta a 600" "uso/input_recente" "$(PRESENCE_AWAY_S=abc STUB_LOCKED=0 STUB_IDLE_S=599 verdict)"
eq "sem input há 5000 s mas app segura a tela (reunião) → uso" "uso/tela_em_uso" "$(STUB_LOCKED=0 STUB_IDLE_S=5000 STUB_HOLD=1 verdict)"
eq "app segurando a tela NÃO atrapalha a tela bloqueada" "livre/bloqueada" "$(STUB_LOCKED=1 STUB_HOLD=1 verdict)"
eq "pmset assertions falhou → ilegível, uso" "uso/ilegivel:tela" "$(STUB_LOCKED=0 STUB_IDLE_S=5000 STUB_ASSERT_FAIL=1 verdict)"
eq "pmset assertions sem a linha → ilegível, uso" "uso/ilegivel:tela" "$(STUB_LOCKED=0 STUB_IDLE_S=5000 STUB_ASSERT_RAW='nothing here' verdict)"
# --- leitura que falha NUNCA vira livre ---
eq "ociosidade ilegível (ioreg HID falhou) → uso" "uso/ilegivel:ociosidade" "$(STUB_LOCKED=0 STUB_IDLE_S=fail verdict)"
eq "nenhuma entrada HIDIdleTime → uso" "uso/ilegivel:ociosidade" "$(STUB_LOCKED=0 STUB_IDLE_S=none verdict)"
eq "entrada HID com lixo → ilegível, uso" "uso/ilegivel:ociosidade" "$(STUB_LOCKED=0 STUB_IDLE_S=abc verdict)"
eq "duas entradas HID: vale a de input mais recente" "uso/input_recente" "$(STUB_LOCKED=0 STUB_IDLE_S=30,9000 verdict)"
eq "duas entradas HID, uma com lixo → ilegível" "uso/ilegivel:ociosidade" "$(STUB_LOCKED=0 STUB_IDLE_S=abc,9000 verdict)"
eq "bloqueio ilegível (ioreg falhou) + 5000 s sem input → livre (a evidência positiva é só do input)" "livre/ocioso" "$(STUB_LOCKED=fail STUB_IDLE_S=5000 verdict)"
eq "bloqueio ilegível + input há 10 s → uso" "uso/input_recente" "$(STUB_LOCKED=fail STUB_IDLE_S=10 verdict)"
eq "bloqueio E ociosidade ilegíveis → uso" "uso/ilegivel:presenca" "$(STUB_LOCKED=fail STUB_IDLE_S=fail verdict)"
eq "saída que não é plist = bloqueio ilegível" "uso/ilegivel:presenca" "$(STUB_LOCKED=garbage STUB_IDLE_S=none verdict)"
eq "sem IOConsoleUsers (tela de login) não é 'desbloqueada'" "uso/ilegivel:presenca" "$(STUB_LOCKED=none STUB_IDLE_S=none verdict)"
eq "nenhuma sessão no console não é 'desbloqueada'" "uso/ilegivel:presenca" "$(STUB_LOCKED=notconsole STUB_IDLE_S=none verdict)"
eq "duas sessões: vale a do console (bloqueada)" "livre/bloqueada" "$(STUB_LOCKED=two STUB_IDLE_S=5 verdict)"
eq "bloqueada lida do plist real: locked=1" 1 "$(STUB_LOCKED=1 pv locked)"
eq "sem a marca (sessão do console lida): locked=0" 0 "$(STUB_LOCKED=0 pv locked)"
eq "ociosidade lida em segundos (ns / 1e9)" 4321 "$(STUB_IDLE_S=4321 pv idle_s)"
# --- só dá para PIORAR ---
eq "PRESENCE_FORCE_USO=1 vence a tela bloqueada" "uso/forcado" "$(PRESENCE_FORCE_USO=1 STUB_LOCKED=1 verdict)"
eq "não existe forçar livre (variáveis de 'forçar livre' são ignoradas)" "uso/input_recente" "$(PRESENCE_FORCE_LIVRE=1 PRESENCE_FORCE=livre STUB_LOCKED=0 STUB_IDLE_S=30 verdict)"
# --- pausa ---
reset; eq "sem arquivo de pausa: paused=0" 0 "$(pv paused)"
echo "origem=mbp desde=ontem|x" > "$T/home/gt-remote/PAUSE"
eq "com o arquivo: paused=1" 1 "$(pv paused)"; eq "pause_info: numa linha e sem '|'" "origem=mbp desde=ontemx" "$(pv pause_info)"
# --- caminhos de entrada da biblioteca ---
reset
eq "executada direto imprime o veredito" "presence=livre" "$(HOME="$T/home" PATH="$FAKE:$PATH" STUB_LOCKED=1 "$STUB_REMOTE_BASH" "$LIB" 2>/dev/null | sed -n 1p)"
eq "colada num 'bash -s' (como vai ao MBP) NÃO imprime nada" "" "$(HOME="$T/home" PATH="$FAKE:$PATH" STUB_LOCKED=1 "$STUB_REMOTE_BASH" -s < "$LIB" 2>/dev/null)"

# --- mbp-run: teto de slots por modo ---
reset; eq "livre, 12 núcleos, RAM sobrando: teto 12" 12 "$(STUB_AVAIL_MB=30000 capof)"
eq "livre, 8 núcleos: teto 8" 8 "$(STUB_AVAIL_MB=30000 STUB_NCPU=8 capof)"
eq "núcleos ilegíveis: teto de reserva 3 (não inventa)" 3 "$(STUB_AVAIL_MB=30000 STUB_NCPU_FAIL=1 capof)"
eq "MBP_MAX_SLOTS=5 troca o teto de núcleos" 5 "$(MBP_MAX_SLOTS=5 STUB_AVAIL_MB=30000 capof)"
eq "MBP_MAX_SLOTS inválido é ignorado" 12 "$(MBP_MAX_SLOTS=abc STUB_AVAIL_MB=30000 capof)"
eq "RAM decide: 3840 MB disponíveis (3072 + 1 fatia) → 2" 2 "$(STUB_AVAIL_MB=3840 capof)"
eq "RAM decide: 3839 MB (falta 1 MB para a 2ª fatia) → 1" 1 "$(STUB_AVAIL_MB=3839 capof)"
eq "RAM no mínimo (3072) → 1" 1 "$(STUB_AVAIL_MB=3072 capof)"
eq "fatia de RAM configurável (MBP_SLOT_MEM_MB=100)" 10 "$(MBP_SLOT_MEM_MB=100 STUB_AVAIL_MB=4000 capof)"
eq "desbloqueado, teclado há 30 s (em uso): teto 1" 1 "$(STUB_LOCKED=0 STUB_IDLE_S=30 STUB_AVAIL_MB=30000 capof)"
eq "em uso: MBP_USE_SLOTS=2 sobe o teto" 2 "$(MBP_USE_SLOTS=2 STUB_LOCKED=0 STUB_IDLE_S=30 capof)"
eq "em uso: MBP_USE_SLOTS=0 (inválido) volta a 1" 1 "$(MBP_USE_SLOTS=0 STUB_LOCKED=0 STUB_IDLE_S=30 capof)"
eq "MBP_FORCE_PRESENCE=uso vence a tela bloqueada" 1 "$(MBP_FORCE_PRESENCE=uso STUB_AVAIL_MB=30000 capof)"
eq "MBP_FORCE_PRESENCE=livre é ignorado (só existe forçar uso)" 1 "$(MBP_FORCE_PRESENCE=livre STUB_LOCKED=0 STUB_IDLE_S=30 STUB_AVAIL_MB=30000 capof)"
eq "saída do MBP sem campo de presença = em uso (teto 1)" 1 "$(STUB_PF_RAW="$PF_OK" capof)"
eq "presença com valor fora de {livre,uso} = em uso" 1 "$(STUB_PF_RAW="$PF_OK\npresence=talvez\nncpu=12\npaused=0" capof)"
reset; STUB_AVAIL_MB=30000 chk >/dev/null
has "--check mostra a presença" "$T/out" '^presence=livre$'; has "--check mostra o porquê" "$T/out" '^presence_why=bloqueada$'
has "--check mostra paused" "$T/out" '^paused=0$'; has "--check mostra paused_local" "$T/out" '^paused_local=0$'
has "--check mostra os núcleos" "$T/out" '^ncpu=12$'

# --- a presença NÃO recusa por si; a saúde continua valendo; a pausa vem antes ---
reset; rc=$(STUB_LOCKED=0 STUB_IDLE_S=30 run -- tests/test_x.py); expect "em uso + MBP saudável: roda (rc 0)" 0 "$rc"
has "log: em uso, não rebaixada" "$J" '"presence":"uso","demoted":0'
reset; rc=$(run -- tests/test_x.py); expect "livre + MBP saudável: roda" 0 "$rc"; has "log: livre" "$J" '"presence":"livre","demoted":0'
reset; eq "em uso + RAM baixa: a saúde ainda recusa" "98:ram" "$(STUB_LOCKED=0 STUB_IDLE_S=30 STUB_AVAIL_MB=1000 outcome "$RUN")"; has "recusa registra a presença" "$J" '"presence":"uso"'
echo "origem=mbp desde=hoje" > "$T/home/gt-remote/PAUSE"
eq "pausa no MBP: rc 99 com motivo próprio" "99:pausado_mbp" "$(outcome "$RUN")"; has "pausa no log com rc 99" "$J" '"rc":99,.*"reason":"pausado_mbp"'
rc=$(run -- tests/test_x.py); expect "pausa no MBP: rc 99" 99 "$rc"; has "mensagem diz quem pausou" "$T/err" 'pausado pelo Athos \(origem=mbp'
reset; echo "origem=mbp desde=hoje" > "$T/home/gt-remote/PAUSE"
eq "pausa vem antes da saúde (RAM baixa + pausa = pausa)" "99:pausado_mbp" "$(STUB_AVAIL_MB=1000 outcome "$RUN")"
reset; echo "origem=mbp desde=hoje" > "$T/home/gt-remote/PAUSE"; rc=$(chk); expect "--check com a pausa no MBP: rc 99" 99 "$rc"; has "--check mostra paused=1" "$T/out" '^paused=1$'
reset; echo "origem=painel desde=hoje" > "$FLAG_PAUSE"; rc=$(run -- tests/test_x.py); expect "pausa local: rc 99" 99 "$rc"
hasnt "pausa local não chama ssh" "$STUB_LOG" 'PREFLIGHT'; has "mensagem da pausa local" "$T/err" 'pausado pelo Athos \(origem=painel'
reset; echo "origem=painel desde=hoje" > "$FLAG_PAUSE"; rc=$("$RUN" --seed wa >"$T/out" 2>"$T/err"; echo $?); expect "--seed com pausa local: rc 99" 99 "$rc"
hasnt "--seed pausado não chama ssh" "$STUB_LOG" 'PREFLIGHT'
reset; echo "origem=mbp desde=hoje" > "$T/home/gt-remote/PAUSE"; rc=$("$RUN" --seed wa >"$T/out" 2>"$T/err"; echo $?); expect "--seed com pausa no MBP: rc 99" 99 "$rc"
reset; "$RUN" --seed wa >"$T/out" 2>"$T/err"; hasnt "--seed LIVRE: receptor do rsync em prioridade normal" "$STUB_LOG" 'rsync-path'
reset; STUB_LOCKED=0 STUB_IDLE_S=30 "$RUN" --seed wa >"$T/out" 2>"$T/err"; has "--seed EM USO: receptor do rsync em fundo" "$STUB_LOG" 'RSYNC:.*--rsync-path=taskpolicy -b rsync'

# --- slots: teto TOTAL por modo (o script de slot roda de verdade, sob a pasta falsa do MBP) ---
reset; for i in 1 2 3 4 5; do mkslot $i; done
rc=$(STUB_SLOTS=exec STUB_AVAIL_MB=30000 run -- tests/test_x.py); expect "livre com 5 slots ocupados e teto 12: roda" 0 "$rc"
has "pegou o slot 6" "$J" '"slot":"6"'; eq "slots 1..5 intactos e o 6 liberado" "1 2 3 4 5 " "$(slot_names)"
reset; for i in $(seq 1 12); do mkslot $i; done
rc=$(STUB_SLOTS=exec STUB_AVAIL_MB=30000 run -- tests/test_x.py); expect "livre com os 12 slots ocupados: 96" 96 "$rc"; has "mensagem diz o teto e o modo" "$T/err" 'teto 12, modo livre'
reset; mkslot 1
eq "livre limitado pela RAM (teto 2), slot 1 ocupado: pega o 2" "0:-" "$(STUB_SLOTS=exec STUB_AVAIL_MB=3900 outcome "$RUN")"; has "no slot 2" "$J" '"slot":"2"'
reset; mkslot 1; mkslot 2
rc=$(STUB_SLOTS=exec STUB_AVAIL_MB=3900 run -- tests/test_x.py); expect "livre limitado pela RAM (teto 2), 2 ocupados: 96" 96 "$rc"
reset; mkslot 2; mkslot 3
rc=$(STUB_SLOTS=exec STUB_LOCKED=0 STUB_IDLE_S=30 run -- tests/test_x.py); expect "EM USO com os slots 2 e 3 ocupados: 96 (o teto é do TOTAL, não dos números baixos)" 96 "$rc"
eq "o slot 1 que ele chegou a tomar foi devolvido; os alheios intactos" "2 3 " "$(slot_names)"; has "mensagem: teto 1, modo uso" "$T/err" 'teto 1, modo uso'
reset; rc=$(STUB_SLOTS=exec STUB_LOCKED=0 STUB_IDLE_S=30 run -- tests/test_x.py); expect "EM USO sem nada ocupado: roda" 0 "$rc"; has "no slot 1" "$J" '"slot":"1"'
reset; mkslot 1 "$(hostname -s):999999:$(date +%s)"
rc=$(STUB_SLOTS=exec STUB_LOCKED=0 STUB_IDLE_S=30 run -- tests/test_x.py); expect "EM USO com slot de dono morto: recolhe e roda" 0 "$rc"; has "avisa do slot morto" "$T/err" 'slot 1 morto'
reset; mkslot 1 "otherhost:1:$(( $(date +%s) - 20000 ))"
rc=$(STUB_SLOTS=exec STUB_LOCKED=0 STUB_IDLE_S=30 run -- tests/test_x.py); expect "EM USO com slot velho (> 4 h) de outro host: recolhe e roda" 0 "$rc"

# --- execução supervisionada: roda de verdade sob bash, com python/taskpolicy/renice falsos ---
reset; rc=$(STUB_RUNMODE=exec STUB_SLOTS=exec runs -- tests/test_x.py -q); expect "supervisionada, livre: roda" 0 "$rc"
has "livre: o python nasce com nice -n 10" "$STUB_LOG" '^NICE:-n 10$'; hasnt "livre: sem taskpolicy na largada" "$STUB_LOG" '^TP:'
has "a saída do python chega ao chamador" "$T/out" '5 passed'; hasnt "livre sem mudança: sem aviso de rebaixamento" "$T/out" 'mbp-run:demoted'
has "livre: log presence=livre demoted=0" "$J" '"presence":"livre","demoted":0'
has "o slot descreve a tarefa (repo, modo, arquivo, presença)" "$STUB_SEEN" '^repo=wa mode=pytest what=test_x\.py presence=livre$'
reset; rc=$(STUB_RUNMODE=exec STUB_RUN_RC=7 runs -- tests/test_x.py); expect "supervisionada: rc do pytest propaga" 7 "$rc"; has "log com rc 7" "$J" '"rc":7'
reset; rc=$(STUB_RUNMODE=exec STUB_LOCKED=0 STUB_IDLE_S=30 runs -- tests/test_x.py); expect "supervisionada, em uso: roda" 0 "$rc"
has "em uso: o python nasce com nice -n 19" "$STUB_LOG" '^NICE:-n 19$'; has "em uso: sob taskpolicy -b" "$STUB_LOG" 'TP:-b nice -n 19 '
has "em uso: log presence=uso" "$J" '"presence":"uso","demoted":0'
reset; rc=$(MBP_FORCE_PRESENCE=uso STUB_RUNMODE=exec runs -- tests/test_x.py); expect "forçado a uso com a tela bloqueada: roda" 0 "$rc"; has "forçado: nice -n 19" "$STUB_LOG" '^NICE:-n 19$'
# o Athos volta NO MEIO da execução (teclado): o vigia rebaixa a árvore
reset; rc=$(STUB_RUNMODE=exec STUB_WAIT_RENICE=60 STUB_FLIP_STATE='locked=0\nidle_s=2\n' runs -- tests/test_x.py)
expect "volta no meio: a execução termina normalmente" 0 "$rc"
has "avisa que o Athos voltou, com o motivo" "$T/out" '^\[mbp-run:demoted\] o Athos voltou ao MBP \(input_recente\)'
has "renice 19 na árvore" "$STUB_LOG" '^RENICE:-n 19 -p [0-9]+'; has "taskpolicy -b -p na árvore" "$STUB_LOG" '^TP:-b -p [0-9]+'
has "log: rebaixada no meio" "$J" '"presence":"livre","demoted":1'
# o Athos aciona a pausa NO MEIO da execução
reset; rc=$(STUB_RUNMODE=exec STUB_WAIT_RENICE=60 STUB_FLIP_PAUSE=1 runs -- tests/test_x.py)
expect "pausa no meio: termina normalmente" 0 "$rc"; has "avisa que ele pausou" "$T/out" '^\[mbp-run:demoted\] o Athos pausou o Gas City'; has "log: rebaixada" "$J" '"demoted":1'
# largou EM USO (já nasceu em fundo): o vigia continua cobrindo filhos novos, mas não anuncia "voltou" nem marca demoted
reset; rc=$(STUB_RUNMODE=exec STUB_RUN_SLEEP=3 STUB_LOCKED=0 STUB_IDLE_S=30 runs -- tests/test_x.py); expect "largou em uso: termina" 0 "$rc"
hasnt "largou em uso: sem aviso de 'voltou'" "$T/out" 'mbp-run:demoted'; has "largou em uso: demoted=0 no log" "$J" '"presence":"uso","demoted":0'
# ele não volta: ninguém é rebaixado
reset; rc=$(STUB_RUNMODE=exec STUB_RUN_SLEEP=3 runs -- tests/test_x.py); expect "sem mudança durante a execução: roda" 0 "$rc"
hasnt "sem mudança: nenhum renice" "$STUB_LOG" '^RENICE:'; hasnt "sem mudança: nenhum taskpolicy -p" "$STUB_LOG" '^TP:'
# o fim da execução NÃO espera o intervalo do vigia, e nada fica para trás
reset; SECONDS=0; rc=$(MBP_WATCH_S=37 STUB_RUNMODE=exec STUB_RUN_SLEEP=1 runs -- tests/test_x.py -k gc-leftover-token); el=$SECONDS
expect "intervalo longo do vigia: termina" 0 "$rc"; n=$((n+1)); if [ "$el" -lt 20 ]; then echo "ok   o fim da execução não espera o vigia (${el}s, intervalo 37 s)"; else echo "FAIL a execução esperou o vigia (${el}s)"; fails=$((fails+1)); fi
n=$((n+1)); if pgrep -f 'sleep 37' >/dev/null 2>&1 || pgrep -f gc-leftover-token >/dev/null 2>&1; then echo "FAIL ficou processo para trás (vigia ou python)"; fails=$((fails+1)); else echo "ok   nenhum processo para trás (vigia nem python)"; fi
# TERM/HUP no script remoto (ssh que cai): a árvore do trabalho morre, rc 143
reset; STUB_RUNMODE=exec runs -- tests/test_x.py -k gc-term-token >/dev/null
SCRIPT="$(dirname "$STUB_LOG")/last-script-RUN.sh"
n=$((n+1)); if [ -s "$SCRIPT" ]; then echo "ok   o stub guardou o script RUN enviado ao MBP"; else echo "FAIL script RUN não guardado"; fails=$((fails+1)); fi
HOME="$T/home" PATH="$FAKE:$PATH" STUB_REAL_SLEEP=1 STUB_RUN_SLEEP=25 "$STUB_REMOTE_BASH" -s < "$SCRIPT" >/dev/null 2>&1 &
RP=$!; sleep 3; kill -TERM "$RP" 2>/dev/null; wait "$RP" 2>/dev/null; trc=$?
eq "TERM no script remoto: rc 143" 143 "$trc"; sleep 1
n=$((n+1)); if pgrep -f gc-term-token >/dev/null 2>&1; then echo "FAIL o python sobreviveu ao TERM"; fails=$((fails+1)); pkill -f gc-term-token 2>/dev/null; else echo "ok   TERM mata a árvore do trabalho"; fi
# exec (REA/APK): mesmo caminho supervisionado, --env continua valendo
reset; printf '#!/usr/bin/env bash\necho "FOO=$FOO"\n' > "$T/bin/fakecmd"; chmod +x "$T/bin/fakecmd"
STUB_RUNMODE=exec STUB_LOCKED=0 STUB_IDLE_S=30 "$RUN" --exec --env FOO=bar -- "$T/bin/fakecmd" >"$T/out" 2>"$T/err"; expect "exec em uso" 0 "$?"
has "exec: --env chega ao comando" "$T/out" 'FOO=bar'; has "exec em uso: nice -n 19" "$STUB_LOG" '^NICE:-n 19$'; has "exec em uso: sob taskpolicy -b" "$STUB_LOG" 'TP:-b nice -n 19 '
reset; STUB_RUNMODE=exec "$RUN" --exec -- "$T/bin/fakecmd" >"$T/out" 2>"$T/err"; has "exec livre: nice -n 10" "$STUB_LOG" '^NICE:-n 10$'
# erro de configuração dentro do MBP: sem o espelho, rc 97
reset; rmdir "$T/home/gt-remote/mirror/wa-1"; rc=$(STUB_RUNMODE=exec runs -- tests/test_x.py); expect "espelho ausente: rc 97 (como antes)" 97 "$rc"; mkdir -p "$T/home/gt-remote/mirror/wa-1"

reset
}

# ---- A CHAVE MANUAL, O STATUS E O CONTROLE DENTRO DO MBP (ga-77c1qg.2) --------------------------------------------------
CONTROLE="$HERE/mbp-controle.sh"
OFFL="${MBP_OFFLOAD_UNDER_TEST:-$HERE/mbp-offload.sh}"
tdy() { PATH="${JQPIN:+$JQPIN:}$PATH" MBP_CITY="$T/city" bash "$OFFL" today 2>&1; }
t_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
t_ayer=$(date -u -v-30H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 hours ago' +%Y-%m-%dT%H:%M:%SZ)
r_line() { printf '{"ts":"%s","repo":"wa","mode":"pytest","slot":"1","rc":0,"secs":%s,"nargs":2%s}\n' "$1" "$2" "$3"; }
chave_cases() {
echo "--- chave manual, status e gascity-mbp (ga-77c1qg.2)"
reset
# --- chave de pausa do lado do MBP e instalação das ferramentas ---
reset; STUB_DIRECT_OUT=REMOVED "$RUN" --remote-pause off >"$T/out" 2>"$T/err"; expect "--remote-pause off: removida" 0 "$?"
reset; STUB_DIRECT_OUT=ABSENT "$RUN" --remote-pause off >"$T/out" 2>"$T/err"; expect "--remote-pause off: já não havia" 0 "$?"
reset; "$RUN" --remote-pause off >"$T/out" 2>"$T/err"; expect "--remote-pause off sem resposta do MBP: NÃO diz que saiu (98)" 98 "$?"
reset; STUB_DIRECT_OUT=STILL "$RUN" --remote-pause off >"$T/out" 2>"$T/err"; expect "--remote-pause off: o arquivo continuou lá (98)" 98 "$?"
reset; STUB_UNREACHABLE=1 "$RUN" --remote-pause off >"$T/out" 2>"$T/err"; expect "--remote-pause off com MBP inalcançável (98)" 98 "$?"
reset; "$RUN" --remote-pause on >"$T/out" 2>"$T/err"; expect "--remote-pause on" 0 "$?"; has "grava origem e data no MBP" "$STUB_LOG" "DIRECT:.*gt-remote/PAUSE"
reset; STUB_DIRECT_RC=1 "$RUN" --remote-pause on >"$T/out" 2>"$T/err"; expect "--remote-pause on que falha (98)" 98 "$?"
reset; "$RUN" --remote-pause talvez >"$T/out" 2>"$T/err"; expect "--remote-pause com argumento inválido (97)" 97 "$?"
reset; "$RUN" --install-tools >"$T/out" 2>"$T/err"; expect "--install-tools" 0 "$?"
has "instala a biblioteca" "$STUB_LOG" 'RSYNC:.*mbp-presence\.sh.*gt-remote/bin/mbp-presence\.sh'; has "instala o gascity-mbp" "$STUB_LOG" 'RSYNC:.*mbp-controle\.sh.*gt-remote/bin/gascity-mbp'
has "dá permissão de execução" "$STUB_LOG" 'DIRECT:.*chmod 755 gt-remote/bin/mbp-presence\.sh gt-remote/bin/gascity-mbp'
# o seed (reseed noturno) atualiza as ferramentas do MBP no fim e NUNCA falha por causa delas
if ls -d /Users/athos/gt/whatsapp_automation/venv/lib/python3.*/site-packages >/dev/null 2>&1; then
  reset; "$RUN" --seed wa >"$T/out" 2>"$T/err"; expect "--seed completo" 0 "$?"; has "o seed termina atualizando o gascity-mbp" "$STUB_LOG" 'RSYNC:.*mbp-controle\.sh.*gt-remote/bin/gascity-mbp'
  reset; STUB_RSYNC_FAIL_BIN=1 "$RUN" --seed wa >"$T/out" 2>"$T/err"; expect "--seed com a atualização das ferramentas falhando: a semeadura não falha" 0 "$?"; has "avisa que não atualizou" "$T/err" 'AVISO: não atualizei ~/gt-remote/bin'
else echo "SKIP --seed completo: venv local do WA ausente neste host (esse caminho NÃO foi exercitado)"; fi

# --- mbp-offload: modos do status, tarefas órfãs, JSON, pause/resume ---
cat > "$T/bin/fake-check" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--check" ]; then printf '%b\n' "${STUB_CHECK_OUT:-}"; exit "${STUB_CHECK_RC:-0}"; fi
echo "fake-run: $*" >> "$STUB_LOG"; exit "${STUB_REMOTE_RC:-0}"
EOF
chmod +x "$T/bin/fake-check"
CK_LIVRE='avail_mb=8000\npressure=1\nncpu=12\npresence=livre\npresence_why=bloqueada\nlocked=1\nidle_s=8114\ndisplay_hold=0\npaused=0\npause_info=\nswap_mb=5000\nswap_delta_mb=0\noffload_flag=on\npaused_local=0\npause_local_info=\nslot_cap=12'
st() { MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" status "$@" 2>&1; }
reset; rm -f "$FLAG"; STUB_CHECK_OUT="$CK_LIVRE"; export STUB_CHECK_OUT
has "status: sem a bandeira = DESLIGADO" <(st) '^Modo: DESLIGADO'
date > "$FLAG"
has "status: LIVRE com o porquê e o teto" <(st) '^Modo: LIVRE — Athos fora \(tela bloqueada\): até 12 tarefas ao mesmo tempo'
export STUB_CHECK_OUT='avail_mb=8000\npresence=uso\npresence_why=input_recente\nidle_s=42\npaused=0\nslot_cap=1'
has "status: EM USO, o porquê e 1 tarefa" <(st) '^Modo: EM USO — tratado como "Athos no MBP" \(teclado/mouse há 42 s\): no máximo 1 tarefa por vez, prioridade de fundo'
export STUB_CHECK_OUT='presence=uso\npresence_why=tela_em_uso\nidle_s=5000\npaused=0\nslot_cap=1'
has "status: tela segurada por app é dito" <(st) 'um app segura a tela acesa'
export STUB_CHECK_OUT='presence=uso\npresence_why=ilegivel:presenca\nidle_s=\npaused=0\nslot_cap=1'
has "status: presença ilegível é dita, não escondida" <(st) 'não consegui ler a presença \(presenca\): por segurança conta como em uso'
export STUB_CHECK_OUT='presence=livre\npresence_why=bloqueada\npaused=1\npause_info=origem=mbp desde=hoje\nslot_cap=12'
has "status: pausa no MBP = PAUSADO com a origem" <(st) '^Modo: PAUSADO \(origem=mbp desde=hoje\)'
export STUB_CHECK_OUT='presence=livre\npresence_why=bloqueada\npaused=0\nslot_cap=12\npause_local_info=origem=painel desde=ontem'; echo "origem=painel desde=ontem" > "$FLAG_PAUSE"
has "status: pausa local = PAUSADO com a origem" <(st) '^Modo: PAUSADO \(origem=painel desde=ontem\)'; rm -f "$FLAG_PAUSE"
export STUB_CHECK_OUT='avail_mb=\nxx=1'; STUB_CHECK_RC=98
has "status: MBP que não respondeu = INDEFINIDO, não 'livre' nem 'em uso'" <(st) '^Modo: INDEFINIDO — MBP inalcançável'
hasnt "status: inalcançável não inventa tarefas" <(st) 'Rodando agora'; unset STUB_CHECK_RC
# tarefas: viva (dono = este processo) e órfã (pid morto, mesmo host)
HN=$(hostname -s)
export STUB_CHECK_OUT="presence=livre\npresence_why=bloqueada\npaused=0\nslot_cap=12\ntask=1|$HN:$$:$(date +%s)|repo=wa mode=pytest what=test_x.py presence=livre|0\ntask=2|$HN:999999:$(( $(date +%s) - 120 ))|repo=wa mode=pytest what=test_y.py presence=livre|0\ntask=3|otherhost:7:$(date +%s)|repo=ps mode=exec what=rea presence=uso|0"
st > "$T/out"
has "status: conta só as tarefas vivas (2 de 3)" "$T/out" '^Rodando agora no MBP: 2 tarefa\(s\)'; has "status: tarefa viva descrita" "$T/out" 'slot 1: repo=wa mode=pytest what=test_x\.py'
has "status: slot de dono morto aparece como ÓRFÃO, não como rodando" "$T/out" 'slot 2: .*test_y\.py.*\[ÓRFÃO'
hasnt "status: a viva não é chamada de órfã" <(grep 'slot 1:' "$T/out") 'ÓRFÃO'
# controle negativo: sem a regra do dono morto, o slot órfão contaria como tarefa rodando (3 em vez de 2)
mutoff() { sed -e "$1" "$OFFL" > "$T/mutoff.sh"; chmod +x "$T/mutoff.sh"; cmp -s "$OFFL" "$T/mutoff.sh" && { n=$((n+1)); echo "FAIL controle $2: o sed não mudou nada"; fails=$((fails+1)); return 1; }; return 0; }
if mutoff 's/! kill -0 "\$p" 2>\/dev\/null; then continue; fi/false; then continue; fi/' orfa; then
  MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$T/mutoff.sh" status > "$T/outm" 2>&1; n=$((n+1))
  if grep -q '^Rodando agora no MBP: 3 tarefa' "$T/outm"; then echo "ok   controle órfã: sem a regra o slot morto conta como rodando (3)"; else echo "FAIL controle órfã: o mutante ainda conta 2"; fails=$((fails+1)); fi; fi
# JSON
j=$(st --json); n=$((n+1)); if printf '%s' "$j" | jq -e . >/dev/null 2>&1; then echo "ok   status --json é JSON válido"; else echo "FAIL status --json não é JSON: $j"; fails=$((fails+1)); fi
eq "json: modo" livre "$(printf '%s' "$j" | jq -r .mode)"; eq "json: teto" 12 "$(printf '%s' "$j" | jq -r .slot_cap)"; eq "json: 3 tarefas listadas" 3 "$(printf '%s' "$j" | jq -r '.tasks | length')"
eq "json: chaves antigas continuam (offload, healthy, health, recent)" "true" "$(printf '%s' "$j" | jq -r 'has("offload") and has("healthy") and has("health") and has("recent")')"
eq "json: tarefas não vazam para dentro de health" "false" "$(printf '%s' "$j" | jq -r '.health | has("task")')"
eq "json: pausa local/MBP separadas" "false/false" "$(printf '%s' "$j" | jq -r '"\(.paused.local)/\(.paused.mbp)"')"
export STUB_CHECK_OUT='presence=uso\npresence_why=input_recente\nidle_s=42\npaused=0\nslot_cap=1'; j=$(st --json)
eq "json em uso: modo, ociosidade e porquê" "em_uso/42/input_recente" "$(printf '%s' "$j" | jq -r '"\(.mode)/\(.idle_s)/\(.mode_why)"')"
mkdir -p "$(dirname "$J")"; { r_line "$t_now" 4 ',"presence":"livre"'; printf '{"ts":"%s","repo":"wa","mode":"pytest","slot":"1","rc":0,"secs":4,"nargs":2,"presen' "$t_now"; echo; } > "$J"
j=$(st --json); n=$((n+1)); if printf '%s' "$j" | jq -e . >/dev/null 2>&1; then echo "ok   status --json continua JSON válido com linha truncada no log"; else echo "FAIL JSON quebrou com linha truncada no log"; fails=$((fails+1)); fi
unset STUB_CHECK_OUT
# pause / resume
reset; unset STUB_REMOTE_RC
MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" pause >"$T/out" 2>&1; expect "pause" 0 "$?"
n=$((n+1)); if [ -s "$FLAG_PAUSE" ]; then echo "ok   pause grava o arquivo local ($(head -n 1 "$FLAG_PAUSE"))"; else echo "FAIL pause não gravou o arquivo"; fails=$((fails+1)); fi
has "pause empurra a pausa para o MBP" "$STUB_LOG" 'fake-run: --remote-pause on'; hasnt "pause com MBP ok: sem aviso" "$T/out" 'AVISO'
MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" resume >"$T/out" 2>&1; expect "resume" 0 "$?"
n=$((n+1)); if [ ! -e "$FLAG_PAUSE" ]; then echo "ok   resume remove o arquivo local"; else echo "FAIL resume não removeu"; fails=$((fails+1)); fi
has "resume tira a pausa do MBP" "$STUB_LOG" 'fake-run: --remote-pause off'
reset; STUB_REMOTE_RC=98 MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" pause >"$T/out" 2>&1; expect "pause com MBP inalcançável: pausa daqui vale" 0 "$?"
has "pause avisa que o MBP não recebeu" "$T/out" 'AVISO: o MBP não recebeu a pausa'; n=$((n+1)); if [ -s "$FLAG_PAUSE" ]; then echo "ok   a pausa local ficou"; else echo "FAIL pausa local perdida"; fails=$((fails+1)); fi
STUB_REMOTE_RC=98 MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" resume >"$T/out" 2>&1; expect "resume sem confirmar o MBP: NÃO libera (rc 1)" 1 "$?"
n=$((n+1)); if [ -s "$FLAG_PAUSE" ]; then echo "ok   a pausa local continua (estado inerte)"; else echo "FAIL resume apagou a pausa sem confirmar o MBP"; fails=$((fails+1)); fi
has "resume explica o que fazer" "$T/out" 'resume --local-only'
# controle negativo: sem confirmar que a pausa do MBP saiu, o resume apagaria a daqui (e o MBP seguiria pausado sem ninguém ver)
if mutoff 's/elif "\$RUN" --remote-pause off >\/dev\/null 2>&1; then rm -f "\$PAUSE"/elif true; then rm -f "$PAUSE"/' resume; then
  STUB_REMOTE_RC=98 MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$T/mutoff.sh" resume >/dev/null 2>&1; n=$((n+1))
  if [ ! -e "$FLAG_PAUSE" ]; then echo "ok   controle resume: sem a confirmação do MBP a pausa daqui seria apagada"; else echo "FAIL controle resume: o mutante manteve a pausa"; fails=$((fails+1)); fi
  echo "origem=painel desde=hoje" > "$FLAG_PAUSE"; fi
: > "$STUB_LOG"; STUB_REMOTE_RC=98 MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" resume --local-only >"$T/out" 2>&1; expect "resume --local-only" 0 "$?"
n=$((n+1)); if [ ! -e "$FLAG_PAUSE" ]; then echo "ok   --local-only remove só a daqui"; else echo "FAIL --local-only não removeu"; fails=$((fails+1)); fi
hasnt "--local-only não tenta o MBP" "$STUB_LOG" 'fake-run: --remote-pause off'
MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" install-mbp >/dev/null 2>&1; has "install-mbp chama o mbp-run" "$STUB_LOG" 'fake-run: --install-tools'
MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" bogus >/dev/null 2>&1; expect "comando desconhecido: rc 2" 2 "$?"

# --- gascity-mbp (mbp-controle.sh), o controle de dentro do MBP ---
ctl() { HOME="$T/home" GASCITY_MBP_HOME="$T/home/gt-remote" PATH="$FAKE:$PATH" "$STUB_REMOTE_BASH" "$CONTROLE" "$@" 2>&1; }
reset; ctl status > "$T/out"; has "gascity-mbp status: LIVRE" "$T/out" '^Gas City: LIVRE — você está fora \(tela bloqueada\)'
STUB_LOCKED=0 STUB_IDLE_S=30 ctl status > "$T/out"; has "gascity-mbp status: EM USO" "$T/out" '^Gas City: EM USO — tratado como "você está no MBP" \(teclado/mouse há 30 s\)'
ctl pausar > "$T/out"; has "pausar avisa o efeito" "$T/out" 'PAUSADO neste MBP'; has "pausar grava origem=mbp" "$T/home/gt-remote/PAUSE" '^origem=mbp desde='
ctl status > "$T/out"; has "status depois de pausar: PAUSADO" "$T/out" '^Gas City: PAUSADO \(origem=mbp'
eq "o mbp-run enxerga a pausa feita pelo gascity-mbp" "99:pausado_mbp" "$(outcome "$RUN")"
ctl liberar > "$T/out"; has "liberar avisa" "$T/out" 'LIBERADO'; n=$((n+1)); if [ ! -e "$T/home/gt-remote/PAUSE" ]; then echo "ok   liberar apaga o arquivo"; else echo "FAIL liberar não apagou"; fails=$((fails+1)); fi
reset; mkslot 1 "otherhost:1:$(date +%s)"; printf 'repo=wa mode=pytest what=test_x.py presence=livre\n' > "$T/home/gt-remote/slots/1/info"; mkslot 2 "otherhost:2:$(( $(date +%s) - 20000 ))"
ctl status > "$T/out"; has "status: conta 1 tarefa (a velha é órfã)" "$T/out" '^Tarefas do Gas City rodando aqui: 1$'; has "status: órfã identificada" "$T/out" 'slot 2: .*provável órfão'
ctl menubar > "$T/out"; eq "menubar livre: título" "🟢 Gas City: 1" "$(sed -n 1p "$T/out")"; has "menubar tem a ação de pausar" "$T/out" '^Pausar até eu liberar \| bash=.* param1=pausar '
STUB_LOCKED=0 STUB_IDLE_S=30 ctl menubar > "$T/out"; eq "menubar em uso: título" "🟠 Gas City: 1" "$(sed -n 1p "$T/out")"
echo "origem=mbp desde=x" > "$T/home/gt-remote/PAUSE"; ctl menubar > "$T/out"; eq "menubar pausado: título" "⏸ Gas City: pausado" "$(sed -n 1p "$T/out")"
reset; GASCITY_MBP_LIB=/nonexistent ctl status > "$T/out"; rc=$?; has "sem a biblioteca: diz o que fazer" "$T/out" 'install-mbp'
ctl bogus >/dev/null; expect "gascity-mbp comando desconhecido: rc 2" 2 "$?"

# --- total do dia (sob cada jq conhecido) ---
today_cases() { local L="$1"
reset; eq "hoje[$L]: sem log" "sem log ainda" "$(tdy)"
reset; mkdir -p "$(dirname "$J")"; : > "$J"; eq "hoje[$L]: log vazio é 0, não ilegível" "0 execuções, 0 min no MBP (livre: 0, em uso: 0)" "$(tdy)"
reset; mkdir -p "$(dirname "$J")"; { r_line "$t_now" 4 ',"presence":"livre","demoted":0'; r_line "$t_now" 60 ',"presence":"uso","demoted":1'; r_line "$t_now" 30 ''
  r_line "$t_ayer" 600 ',"presence":"livre"'; printf '{"ts":"%s","repo":"-","mode":"preflight","slot":"-","rc":98,"secs":0,"nargs":0,"reason":"ram"}\n' "$t_now"; } > "$J"
eq "hoje[$L]: separa livre/em uso/sem presença; ontem e recusa ficam fora" "3 execuções, 1 min no MBP (livre: 1, em uso: 1, sem presença registrada: 1)" "$(tdy)"
reset; mkdir -p "$(dirname "$J")"; { r_line "$t_now" 4 ',"presence":"livre"'; printf '{"ts":"%s","repo":"wa","mode":"pyt' "$t_now"; echo; } > "$J"
eq "hoje[$L]: linha truncada é avisada" "1 execuções, 0 min no MBP (livre: 1, em uso: 0); 1 linha(s) ilegível(is) no log (não contadas)" "$(tdy)"
reset; mkdir -p "$(dirname "$J")"; { r_line "$t_now" 4 ',"presence":"livre"'; printf '{"ts":"ontem","repo":"wa","mode":"pytest","secs":1}\n'; echo null; } > "$J"
eq "hoje[$L]: ts ilegível e linha que não é objeto são avisados" "1 execuções, 0 min no MBP (livre: 1, em uso: 0); 2 linha(s) ilegível(is) no log (não contadas)" "$(tdy)"
}
JQPIN=""; today_cases "jq do PATH"
for cand in /usr/bin/jq /opt/homebrew/bin/jq; do
  if [ -x "$cand" ]; then d="$T/jqpin$(printf '%s' "$cand" | tr '/' '_')"; mkdir -p "$d"; ln -sf "$cand" "$d/jq"; JQPIN="$d"; today_cases "$cand $("$cand" --version 2>&1)"
  else echo "SKIP total do dia sob $cand: não existe neste host (esse jq NÃO foi exercitado)"; fi
done
JQPIN=""
reset; mkdir -p "$(dirname "$J")" "$T/nojq"; r_line "$t_now" 4 '' > "$J"; ln -sf "$(command -v date)" "$T/nojq/date"; ln -sf "$(command -v dirname)" "$T/nojq/dirname"
eq "hoje: jq ausente é 'ilegível', nunca '0 execuções'" "ilegível" "$(PATH="$T/nojq" MBP_CITY="$T/city" /bin/bash "$OFFL" today 2>&1)"
reset
}

# ---- controles negativos da presença -------------------------------------------------------------------------------
# Cada mutante tira UMA regra e TEM que deixar de reproduzir o resultado do script real no cenário que a regra guarda.
mut_compare() { # rótulo esperado cenário(função) arquivo-original sed-expr destino-da-mutante
  local label="$1" want="$2" scen="$3" src="$4" expr="$5" dst="$6" real mut
  sed -e "$expr" "$src" > "$dst"; chmod +x "$dst"
  cmp -s "$src" "$dst" && { n=$((n+1)); echo "FAIL controle $label: o sed não mudou nada (marcador sumiu?)"; fails=$((fails+1)); return 0; }
  real=$($scen real); mut=$($scen mut)
  eq "controle $label: o script real dá '$want'" "$want" "$real"
  n=$((n+1)); if [ "$mut" != "$want" ]; then echo "ok   controle $label: a mutante sem a regra não reproduz ($mut)"; else echo "FAIL controle $label: a mutante ainda reproduz '$want'"; fails=$((fails+1)); fi
}
neg_presenca() {
  echo "--- controles negativos (presença)"
  cp "$LIB" "$T/lib.real"; cp "$LIB" "$T/mbp-presence.sh"; cp "$CONTROLE" "$T/mbp-controle.sh"
  # biblioteca: cenários que chamam a lib mutante
  sc_lib() { reset; if [ "$1" = mut ]; then LIBX="$T/lib.mut"; else LIBX=""; fi; "$2"; LIBX=""; }
  s1() { STUB_LOCKED=0 STUB_IDLE_S=5000 STUB_ASSERT_FAIL=1 verdict; }
  s2() { STUB_LOCKED=0 STUB_IDLE_S=600 verdict; }
  s3() { STUB_LOCKED=0 STUB_IDLE_S=5000 STUB_HOLD=1 verdict; }
  s4() { STUB_LOCKED=1 STUB_IDLE_S=5 verdict; }
  s5() { STUB_LOCKED=notconsole STUB_IDLE_S=fail verdict; }
  s6() { STUB_LOCKED=0 STUB_IDLE_S=fail verdict; }
  s7() { PRESENCE_FORCE_USO=1 STUB_LOCKED=1 verdict; }
  c1() { sc_lib "$1" s1; }; c2() { sc_lib "$1" s2; }; c3() { sc_lib "$1" s3; }; c4() { sc_lib "$1" s4; }; c5() { sc_lib "$1" s5; }; c6() { sc_lib "$1" s6; }; c7() { sc_lib "$1" s7; }
  mut_compare "lib: tela ilegível virou livre" "uso/ilegivel:tela" c1 "$LIB" 's/else PR_WHY=ilegivel:tela; fi/else PR_MODE=livre; PR_WHY=ilegivel:tela; fi/' "$T/lib.mut"
  mut_compare "lib: fronteira de 600 s (-lt virou -le)" "livre/ocioso" c2 "$LIB" 's/-lt "\$PRESENCE_AWAY_S"/-le "$PRESENCE_AWAY_S"/' "$T/lib.mut"
  mut_compare "lib: app segurando a tela é ignorado" "uso/tela_em_uso" c3 "$LIB" 's/elif \[ "\$PR_HOLD" = 0 \]; then/elif true; then/' "$T/lib.mut"
  mut_compare "lib: bloqueada deixa de valer" "livre/bloqueada" c4 "$LIB" 's/elif \[ "\$PR_LOCKED" = 1 \]; then PR_MODE=livre/elif false; then PR_MODE=livre/' "$T/lib.mut"
  mut_compare "lib: bloqueio ilegível lido como desbloqueado" "uso/ilegivel:presenca" c5 "$LIB" 's/^  echo$/  echo 0/' "$T/lib.mut"
  mut_compare "lib: ociosidade ilegível lida como 'muito tempo'" "uso/ilegivel:ociosidade" c6 "$LIB" 's/^  \[ -n "\$raw" \] || { echo; return; }/  [ -n "$raw" ] || { echo 99999; return; }/' "$T/lib.mut"
  mut_compare "lib: PRESENCE_FORCE_USO deixa de valer" "uso/forcado" c7 "$LIB" 's/if \[ "\${PRESENCE_FORCE_USO:-0}" = 1 \]; then/if false; then/' "$T/lib.mut"
  # mbp-run: a mutante mora em $T (junto da cópia da biblioteca)
  sm_occ() { reset; mkslot 2; mkslot 3; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; STUB_SLOTS=exec STUB_LOCKED=0 STUB_IDLE_S=30 outcome "$s"; }
  sm_cap_unknown() { reset; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; STUB_PF_RAW="$PF_OK" capof "$s"; }
  sm_pause_remote() { reset; echo "origem=mbp desde=hoje" > "$T/home/gt-remote/PAUSE"; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; outcome "$s"; }
  sm_pause_local() { reset; echo "origem=painel desde=hoje" > "$FLAG_PAUSE"; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; outcome "$s"; }
  sm_cap_uso() { reset; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; STUB_LOCKED=0 STUB_IDLE_S=30 STUB_AVAIL_MB=30000 capof "$s"; }
  sm_seed_bg() { reset; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; STUB_LOCKED=0 STUB_IDLE_S=30 "$s" --seed wa >/dev/null 2>&1; grep -c 'rsync-path' "$STUB_LOG"; }   # 2 = os dois rsync da semeadura (árvore-base e site-packages)
  sm_demote() { reset; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"
    STUB_RUNMODE=exec STUB_WAIT_RENICE=16 MBP_WATCH_S=1 STUB_FLIP_STATE='locked=0\nidle_s=2\n' runx "$s" tests/test_x.py >/dev/null; grep -c '^RENICE:' "$STUB_LOG" | sed 's/^[1-9][0-9]*$/demoted/'; }
  sm_start_bg() { reset; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; STUB_RUNMODE=exec STUB_LOCKED=0 STUB_IDLE_S=30 runx "$s" tests/test_x.py >/dev/null; sed -n 's/^NICE:-n \([0-9]*\)$/nice\1/p' "$STUB_LOG" | head -n 1; }
  sm_cap_mem() { reset; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; STUB_AVAIL_MB=3840 capof "$s"; }
  mut_compare "run: teto total (checagem de ocupação depois do mkdir)" "96:-" sm_occ "$RUN" 's/-le \$cap \]; then echo "SLOT=\\\$n"/-le 999 ]; then echo "SLOT=\\$n"/' "$T/mut.sh"
  mut_compare "run: presença desconhecida virou livre" 1 sm_cap_unknown "$RUN" 's/\*) PRES=uso; PRES_WHY=\${PRES_WHY:-ilegivel:presenca} ;; esac/*) PRES=livre ;; esac/' "$T/mut.sh"
  mut_compare "run: pausa no MBP deixa de valer" "99:pausado_mbp" sm_pause_remote "$RUN" 's/\[ "\$(pf_get paused)" = 1 \]/[ "$(pf_get pausedX)" = 1 ]/' "$T/mut.sh"
  mut_compare "run: pausa local deixa de valer" "99:-" sm_pause_local "$RUN" '/pausado pelo Athos (\$(head -n 1/s/.*/true/' "$T/mut.sh"
  mut_compare "run: teto do modo EM USO" 1 sm_cap_uso "$RUN" 's/  else echo "\$USE_SLOTS"; fi/  else echo 12; fi/' "$T/mut.sh"
  mut_compare "run: seed em uso deixa de usar prioridade de fundo" 2 sm_seed_bg "$RUN" 's/\[ "\$PRES" = livre \] || RSYNC_PATH_OPT=(--rsync-path="taskpolicy -b rsync")/true/' "$T/mut.sh"
  mut_compare "run: vigia deixa de rebaixar" demoted sm_demote "$RUN" 's/    if ! mbp_calm; then$/    if false; then/' "$T/mut.sh"
  mut_compare "run: largada em uso deixa de ser em fundo" nice19 sm_start_bg "$RUN" 's/  if ! mbp_calm; then MBP_STARTED_CALM=0;/  if false; then MBP_STARTED_CALM=0;/' "$T/mut.sh"
  mut_compare "run: teto pela RAM" 2 sm_cap_mem "$RUN" 's/\[ "\$mem" -ge "\$cpu" \] || cpu=\$mem/true/' "$T/mut.sh"
}

if [ -n "${MBP_SELFTEST_ONLY:-}" ]; then
  date > "$FLAG"
  case "$MBP_SELFTEST_ONLY" in
    presenca) presenca_cases; neg_presenca ;;
    chave) chave_cases ;;
    *) echo "MBP_SELFTEST_ONLY desconhecido: $MBP_SELFTEST_ONLY" >&2; exit 2 ;;
  esac
  echo "---"; echo "$((n-fails))/$n ok"
  [ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
  exit 0
fi

# 1 off
reset; rm -f "$FLAG"; rc=$(run -- tests/test_x.py); expect "off" 99 "$rc"; hasnt "off não chama ssh" "$STUB_LOG" 'PREFLIGHT'
date > "$FLAG"
# 2 inalcançável
reset; rc=$(STUB_UNREACHABLE=1 run -- tests/test_x.py); expect "inalcançável" 98 "$rc"
has "inalcançável vai ao log com motivo" "$J" '"reason":"inalcancavel".*"avail_mb":null'
# 3 RAM baixa
reset; rc=$(STUB_AVAIL_MB=1000 run -- tests/test_x.py); expect "RAM baixa" 98 "$rc"; has "msg RAM" "$T/err" 'sem RAM'
hasnt "RAM baixa não pega slot" "$STUB_LOG" 'SLOT_ACQUIRE'
has "RAM baixa vai ao log com motivo e número" "$J" '"reason":"ram".*"avail_mb":1000'
hasnt "recusa gravada no log não emite AVISO" "$T/err" 'AVISO'
# 3b a recusa que NÃO coube no log (aqui o caminho do log é um diretório) é AVISADA: a contagem de 72 h é a medida de aceitação,
#    e sem o aviso "recusas: nenhuma" mentiria — o rc segue 98 (o chamador roda local do mesmo jeito)
reset; mkdir -p "$J"; rc=$(STUB_AVAIL_MB=1000 run -- tests/test_x.py); expect "recusa com log não gravável: rc segue 98" 98 "$rc"
has "recusa que não coube no log é avisada com o motivo" "$T/err" "AVISO: recusa 'ram' NÃO gravada"; rmdir "$J"
# 5 bateria baixa sem tomada
reset; rc=$(STUB_POWER=battery STUB_BATT=30 run -- tests/test_x.py); expect "bateria baixa" 98 "$rc"; has "bateria vai ao log" "$J" '"reason":"bateria"'
# 5b bateria ok sem tomada passa
reset; rc=$(STUB_POWER=battery STUB_BATT=80 run -- tests/test_x.py); expect "bateria 80% sem tomada passa" 0 "$rc"
reset; eq "bateria 40% (limite) recusa" "98:bateria" "$(STUB_POWER=battery STUB_BATT=40 outcome "$RUN")"
reset; eq "bateria 41% passa" "0:-" "$(STUB_POWER=battery STUB_BATT=41 outcome "$RUN")"
# 5c ILEGÍVEL ≠ bateria baixa: pmset falhou / formato inesperado → "ilegivel:power" (antes virava "battery" e o log dizia "bateria");
#    na bateria sem a carga legível → "ilegivel:batt"; na tomada a carga ilegível não decide
reset; eq "pmset falhou" "98:ilegivel:power" "$(STUB_PMSET_FAIL=1 outcome "$RUN")"; has "fonte ilegível não vira 'bateria' no log" "$J" '"reason":"ilegivel:power"'
reset; eq "pmset: formato inesperado" "98:ilegivel:power" "$(STUB_PMSET_RAW='something else' outcome "$RUN")"
reset; eq "na bateria sem a carga legível" "98:ilegivel:batt" "$(STUB_PMSET_RAW="Now drawing from 'Battery Power'" outcome "$RUN")"
reset; eq "na tomada a carga ilegível não decide" "0:-" "$(STUB_PMSET_RAW="Now drawing from 'AC Power'" outcome "$RUN")"
# 6 slots cheios
reset; rc=$(STUB_SLOTS=full run -- tests/test_x.py); expect "slots cheios" 96 "$rc"; hasnt "cheios não roda" "$STUB_LOG" '^RUN$'
# 7 slot de dono morto é reaped e roda
reset; rc=$(STUB_SLOTS=dead run -- tests/test_x.py); expect "dono morto reaped" 0 "$rc"; has "chamou SLOT_REAP" "$STUB_LOG" 'SLOT_REAP'
# 8 propaga rc e loga
reset; rc=$(STUB_RUN_RC=7 run -- tests/test_x.py -q); expect "rc remoto propagado" 7 "$rc"
has "jsonl tem rc 7" "$J" '"rc":7'
# 9 libera slot ao fim
has "SLOT_RELEASE ao fim" "$STUB_LOG" 'SLOT_RELEASE'
# 10 ssh 255 no meio
reset; rc=$(STUB_RUN_RC=255 run -- tests/test_x.py); expect "ssh caiu no meio" 98 "$rc"; has "libera mesmo assim" "$STUB_LOG" 'SLOT_RELEASE'
# 11 nota de shared/data
reset; rc=$(STUB_RUN_RC=1 STUB_RUN_OUT="FileNotFoundError: shared/data/x.db" run -- tests/test_x.py); expect "falha com shared/data" 1 "$rc"; has "nota shared/data" "$T/err" 'NOTE: shared/data'
# 12 sucesso: rsync do worktree com exclusões e sem --delete-excluded
reset; rc=$(run -- tests/test_x.py); expect "sucesso" 0 "$rc"; has "rsync exclui .git" "$STUB_LOG" 'RSYNC:.*--exclude \.git'; hasnt "não apaga excluídos" "$STUB_LOG" 'delete-excluded'
has "stdout do remoto chega" "$T/out" 'stub-run-ok'
hasnt "execução saudável não loga recusa" "$J" '"mode":"preflight"'
# 13 uso errado
reset; rc=$("$RUN" --repo wa --dir "$T/wt" >"$T/out" 2>"$T/err"; echo $?); expect "sem args do pytest" 97 "$rc"
rc=$("$RUN" --repo xx --dir "$T/wt" -- a >"$T/out" 2>"$T/err"; echo $?); expect "repo inválido" 97 "$rc"
# 14 base ausente
reset; rc=$(STUB_NOBASE=1 run -- tests/test_x.py); expect "base ausente" 97 "$rc"; has "manda rodar --seed" "$T/err" '\-\-seed'; has "libera slot em 97" "$STUB_LOG" 'SLOT_RELEASE'
# 15 exec: push + pull + limpeza do scratch
reset; echo data > "$T/in.bin"; "$RUN" --exec --push "$T/in.bin" --pull "out.json:$T/" -- rea --version >"$T/out" 2>"$T/err"; rc=$?; expect "exec ok" 0 "$rc"
has "exec empurra" "$STUB_LOG" 'RSYNC:.*in\.bin'; has "exec puxa" "$STUB_LOG" 'RSYNC:.*out\.json'; has "exec limpa scratch" "$STUB_LOG" 'DIRECT:.*find .* -mindepth 1 -delete'
reset; STUB_RUN_RC=3 "$RUN" --exec -- false >"$T/out" 2>"$T/err"; r=$?; expect "exec propaga rc" 3 "$r"
# 16 --keep não limpa
reset; "$RUN" --exec --keep -- true >"$T/out" 2>"$T/err"; hasnt "--keep preserva scratch" "$STUB_LOG" 'DIRECT:.*-delete'

# ---- preflight de saúde (ga-9e2rjh) -------------------------------------------------------------------------------
# 17 o DEFEITO: swap alto mas PARADO não recusa (medido em 11/10: 5.248 MB recusou com 3,8 GB de RAM disponível)
reset; rc=$(STUB_SWAP_MB=5248 STUB_AVAIL_MB=3900 run -- tests/test_x.py); expect "swap 5248 MB parado com 3,9 GB livres PASSA" 0 "$rc"
hasnt "e não registra recusa" "$J" '"mode":"preflight"'
reset; rc=$(STUB_SWAP_MB=7900 run -- tests/test_x.py); expect "swap 7900 MB parado passa (abaixo do teto)" 0 "$rc"
# 18 teto absoluto do swap (padrão 8192, configurável)
reset; eq "swap 9000 MB (acima do teto) recusa" "98:swap_teto" "$(STUB_SWAP_MB=9000 outcome "$RUN")"; has "teto no log com o número" "$J" '"swap_mb":9000'
reset; eq "teto é configurável (MBP_MAX_SWAP_MB=4000)" "98:swap_teto" "$(MBP_MAX_SWAP_MB=4000 STUB_SWAP_MB=6000 outcome "$RUN")"
# 19 swap CRESCENDO recusa (o MBP está trocando memória agora); fronteira 128 passa, 129 recusa; encolher passa
reset; eq "swap 5000→5400 recusa" "98:swap_cresce" "$(STUB_SWAP_MB=5000 STUB_SWAP2_MB=5400 outcome "$RUN")"
has "crescimento no log" "$J" '"swap_delta_mb":400'
reset; STUB_SWAP_MB=5000 STUB_SWAP2_MB=5400 run -- tests/test_x.py >/dev/null; has "msg: swap cresceu 400 MB em 2s" "$T/err" 'swap cresceu 400 MB em 2s'
reset; eq "swap +128 MB (limite) passa" "0:-" "$(STUB_SWAP_MB=5000 STUB_SWAP2_MB=5128 outcome "$RUN")"
reset; eq "swap +129 MB recusa" "98:swap_cresce" "$(STUB_SWAP_MB=5000 STUB_SWAP2_MB=5129 outcome "$RUN")"
reset; eq "swap encolhendo (delta negativo) passa" "0:-" "$(STUB_SWAP_MB=5000 STUB_SWAP2_MB=4000 outcome "$RUN")"
reset; eq "crescimento é configurável (MBP_MAX_SWAP_GROWTH_MB=500)" "0:-" "$(MBP_MAX_SWAP_GROWTH_MB=500 STUB_SWAP_MB=5000 STUB_SWAP2_MB=5400 outcome "$RUN")"
# 20 janela da amostra: padrão 2 s, configurável, inválido volta ao padrão
reset; run -- tests/test_x.py >/dev/null; has "janela padrão 2 s" "$STUB_LOG" '^SLEEP:2$'
reset; MBP_SWAP_SAMPLE_S=5 run -- tests/test_x.py >/dev/null; has "janela configurável (5 s)" "$STUB_LOG" '^SLEEP:5$'
reset; MBP_SWAP_SAMPLE_S=abc run -- tests/test_x.py >/dev/null; has "janela inválida volta a 2 s" "$STUB_LOG" '^SLEEP:2$'
# 21 pressão de memória do kernel: 1 normal passa; 2 aviso e 4 crítico recusam; limite configurável
reset; eq "pressão 1 (normal) passa" "0:-" "$(STUB_PRESSURE=1 outcome "$RUN")"
reset; eq "pressão 2 (aviso) recusa" "98:pressao" "$(STUB_PRESSURE=2 outcome "$RUN")"; has "pressão no log" "$J" '"pressure":2'
reset; eq "pressão 4 (crítico) recusa" "98:pressao" "$(STUB_PRESSURE=4 outcome "$RUN")"
reset; eq "pressão 2 passa com MBP_MAX_PRESSURE_LEVEL=2" "0:-" "$(MBP_MAX_PRESSURE_LEVEL=2 STUB_PRESSURE=2 outcome "$RUN")"
reset; eq "pressão 4 recusa mesmo com MBP_MAX_PRESSURE_LEVEL=2" "98:pressao" "$(MBP_MAX_PRESSURE_LEVEL=2 STUB_PRESSURE=4 outcome "$RUN")"
# 22 ILEGÍVEL ≠ baixo: sysctl falhou, texto, valor fora de {1,2,4} → recusa com motivo próprio e null no log (nunca "1"/"0")
reset; eq "pressão: sysctl falhou" "98:ilegivel:pressure" "$(STUB_PRESSURE_FAIL=1 outcome "$RUN")"; has "pressão ilegível vai como null" "$J" '"pressure":null'
reset; eq "pressão: texto" "98:ilegivel:pressure" "$(STUB_PRESSURE=abc outcome "$RUN")"
reset; eq "pressão: valor fora de {1,2,4}" "98:ilegivel:pressure" "$(STUB_PRESSURE=3 outcome "$RUN")"
reset; eq "swap: lixo na 1ª e 2ª leitura" "98:ilegivel:swap_delta" "$(STUB_SWAP_RAW='vm.swapusage: unknown oid' outcome "$RUN")"; has "swap ilegível vai como null" "$J" '"swap_mb":null.*"swap_delta_mb":null'
reset; eq "swap: só a 2ª leitura ilegível" "98:ilegivel:swap_delta" "$(STUB_SWAP_MB=5000 STUB_SWAP2_RAW=garbage outcome "$RUN")"
reset; eq "swap: unidade desconhecida (K) não vira 0" "98:ilegivel:swap_delta" "$(STUB_SWAP_RAW='total = 8192.00K  used = 12.00K  free = 1.00K' outcome "$RUN")"
reset; eq "RAM: linha 'Pages speculative' sumiu" "98:ilegivel:avail" "$(STUB_VM_DROP='Pages speculative' outcome "$RUN")"; has "RAM ilegível vai como null" "$J" '"avail_mb":null'
reset; eq "RAM: cabeçalho do page size sumiu" "98:ilegivel:avail" "$(STUB_VM_DROP='page size' outcome "$RUN")"
reset; eq "RAM: vm_stat falhou" "98:ilegivel:avail" "$(STUB_VM_FAIL=1 outcome "$RUN")"
# lado local isolado (saída crua do remoto): campo vazio nunca é lido como número
OK_PF='avail_mb=8000\nswap_mb=5000\nswap_delta_mb=0\npressure=1\npower=ac\nbatt=90'
reset; eq "saída crua saudável passa" "0:-" "$(STUB_PF_RAW="$OK_PF" outcome "$RUN")"
reset; eq "crua: swap_delta vazio" "98:ilegivel:swap_delta" "$(STUB_PF_RAW='avail_mb=8000\nswap_mb=5000\nswap_delta_mb=\npressure=1\npower=ac\nbatt=90' outcome "$RUN")"
reset; eq "crua: swap_mb vazio com delta ok" "98:ilegivel:swap" "$(STUB_PF_RAW='avail_mb=8000\nswap_mb=\nswap_delta_mb=0\npressure=1\npower=ac\nbatt=90' outcome "$RUN")"
reset; eq "crua: avail_mb vazio" "98:ilegivel:avail" "$(STUB_PF_RAW='avail_mb=\nswap_mb=5000\nswap_delta_mb=0\npressure=1\npower=ac\nbatt=90' outcome "$RUN")"
reset; eq "crua: pressure ausente" "98:ilegivel:pressure" "$(STUB_PF_RAW='avail_mb=8000\nswap_mb=5000\nswap_delta_mb=0\npower=ac\nbatt=90' outcome "$RUN")"
# 23 informativos nunca decidem: memory_pressure falhar não recusa; o compressor alto de repouso também não
reset; rc=$(STUB_MP_FAIL=1 run -- tests/test_x.py); expect "memory_pressure falhou: só informativo, não recusa" 0 "$rc"
reset; rc=$(STUB_COMP_PAGES=900000 run -- tests/test_x.py); expect "compressor enorme: só informativo, não recusa" 0 "$rc"
# 24 --check mostra os números lidos (e nunca grava recusa; --seed idem)
reset; rc=$(chk); expect "--check saudável" 0 "$rc"
has "check: avail_mb" "$T/out" '^avail_mb=8000$'; has "check: swap_mb" "$T/out" '^swap_mb=1000$'; has "check: swap_delta_mb" "$T/out" '^swap_delta_mb=0$'
has "check: pressure" "$T/out" '^pressure=1$'; has "check: mem_free_pct" "$T/out" '^mem_free_pct=54$'; has "check: compressed_mb" "$T/out" '^compressed_mb=5268$'
reset; rc=$(STUB_PAGE_SIZE=4096 chk); expect "--check com page size 4096" 0 "$rc"; has "avail usa o page size do cabeçalho" "$T/out" '^avail_mb=8000$'
reset; rc=$(STUB_SWAP_RAW='total = 8192.00M  used = 1.50G  free = 6.50G  (encrypted)' chk); expect "--check com swap em G" 0 "$rc"; has "'1.50G' lido como 1536 MB" "$T/out" '^swap_mb=1536$'
reset; rc=$(STUB_AVAIL_MB=1000 chk); expect "--check recusa por RAM" 98 "$rc"; n=$((n+1)); if [ ! -e "$J" ]; then echo "ok   --check não grava recusa no log"; else echo "FAIL --check gravou no log"; fails=$((fails+1)); fi
reset; rc=$(STUB_AVAIL_MB=1000 "$RUN" --seed wa >"$T/out" 2>"$T/err"; echo $?); expect "--seed recusa por RAM" 98 "$rc"
n=$((n+1)); if [ ! -e "$J" ]; then echo "ok   --seed não grava recusa no log"; else echo "FAIL --seed gravou no log"; fails=$((fails+1)); fi

# 25 a contagem de 72 h do mbp-offload.sh (é por ela que se mede "recusa indevida"): três estados que não se confundem, e linha
#    ilegível AVISADA, nunca omitida — senão uma recusa truncada deixava "recusas: nenhuma" mentir
OFFLOAD="${MBP_OFFLOAD_UNDER_TEST:-$HERE/mbp-offload.sh}"
# A MESMA jq NÃO lê igual em toda parte (ga-9e2rjh, gate-fix 1): "A + B as $x | ..." é "(A+B) as $x" no jq 1.8.1 (homebrew) e
# "A + (B as $x | ...)" no 1.7.1-apple do /usr/bin — o que o launchd, de PATH mínimo, resolve. Os casos abaixo rodam portanto UMA
# VEZ por jq conhecido, cada um FIXADO por caminho absoluto na frente do PATH (JQPIN), além do jq que o PATH do ambiente der.
# Um jq que não existe neste host é AVISADO ("SKIP"), nunca contado como ok: cobertura que sumiu tem de aparecer.
JQPIN=""
cnt() { PATH="${JQPIN:+$JQPIN:}$PATH" bash "$OFFLOAD" counts 2>&1; }
t_now=$(date -u +%Y-%m-%dT%H:%M:%SZ); t_old=$(date -u -v-5d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 days ago' +%Y-%m-%dT%H:%M:%SZ)
l_run() { printf '{"ts":"%s","repo":"wa","mode":"pytest","slot":"1","rc":0,"secs":4,"nargs":2}\n' "$t_now"; }
l_ref() { printf '{"ts":"%s","repo":"-","mode":"preflight","slot":"-","rc":98,"secs":0,"nargs":0,"reason":"%s"}\n' "${2:-$t_now}" "$1"; }
counts_cases() { # rótulo do jq sob teste (vai no nome de cada caso)
local L="$1"
reset; eq "contagem[$L]: sem log" "sem log ainda" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; : > "$J"; eq "contagem[$L]: log vazio é 0, não ilegível" "0 execuções; recusas: nenhuma" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; { l_run; l_run; l_ref ram; l_ref ram; l_ref swap_cresce; l_ref ram "$t_old"; } > "$J"
eq "contagem[$L]: por motivo, e recusa de 5 dias atrás fica fora" "2 execuções; recusas: ram=2 swap_cresce=1" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; l_run > "$J"; eq "contagem[$L]: lido e sem recusa" "1 execuções; recusas: nenhuma" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; { l_run; l_ref ram; printf '{"ts":"%s","repo":"-","mode":"pref' "$t_now"; echo; } > "$J"
eq "contagem[$L]: linha de recusa truncada é avisada e o resto conta" "1 execuções; recusas: ram=1; 1 linha(s) ilegível(is) no log (não contadas)" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; { l_run; printf '{"ts":"%s","mode":"preflight","rc":98}\n' "$t_now"; } > "$J"
eq "contagem[$L]: recusa sem motivo não vira 'nenhuma' em silêncio" "1 execuções; recusas: nenhuma; 1 linha(s) ilegível(is) no log (não contadas)" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; { l_run; printf '{"ts":"ontem","mode":"preflight","rc":98,"reason":"ram"}\n'; } > "$J"
eq "contagem[$L]: ts que não vira data é avisado" "1 execuções; recusas: nenhuma; 1 linha(s) ilegível(is) no log (não contadas)" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; { l_run; echo null; echo 42; } > "$J"
eq "contagem[$L]: linha que não é objeto é avisada" "1 execuções; recusas: nenhuma; 2 linha(s) ilegível(is) no log (não contadas)" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; { l_run; printf '{"ts":"%s","repo":"x"}\n' "$t_now"; printf '{"ts":"%s","mode":7}\n' "$t_now"; } > "$J"
eq "contagem[$L]: linha com ts mas sem 'mode' em texto é avisada, não vira execução" "1 execuções; recusas: nenhuma; 2 linha(s) ilegível(is) no log (não contadas)" "$(cnt)"
}
JQPIN=""; counts_cases "jq do PATH"
for cand in /usr/bin/jq /opt/homebrew/bin/jq; do
  if [ -x "$cand" ]; then
    d="$T/jqpin$(printf '%s' "$cand" | tr '/' '_')"; mkdir -p "$d"; ln -sf "$cand" "$d/jq"
    JQPIN="$d"; counts_cases "$cand $("$cand" --version 2>&1)"
  else
    echo "SKIP contagem sob $cand: não existe neste host (esse jq NÃO foi exercitado)"
  fi
done
JQPIN=""
reset; mkdir -p "$(dirname "$J")"; l_run > "$J"; chmod 000 "$J"; eq "contagem: log sem permissão de leitura é 'ilegível', nunca 'nenhuma'" "ilegível" "$(cnt)"; chmod 644 "$J"
reset; mkdir -p "$(dirname "$J")" "$T/nojq"; l_run > "$J"; ln -sf "$(command -v date)" "$T/nojq/date"; ln -sf "$(command -v dirname)" "$T/nojq/dirname"
eq "contagem: jq ausente é 'ilegível', nunca 'nenhuma'" "ilegível" "$(PATH="$T/nojq" /bin/bash "$OFFLOAD" counts 2>&1)"

# controle negativo: sem a checagem de flag o caso "off" PASSARIA a rodar — prova que o teste 1 enxerga o defeito
reset; rm -f "$FLAG"; neg=$(sed 's/^\[ -f "\$FLAG" \] || {.*$/true/' "$RUN" > "$T/mut.sh"; chmod +x "$T/mut.sh"; "$T/mut.sh" --repo wa --dir "$T/wt" -- tests/test_x.py >/dev/null 2>&1; echo $?)
n=$((n+1)); if [ "$neg" != 99 ]; then echo "ok   controle negativo (mutante sem a trava não sai 99: rc=$neg)"; else echo "FAIL controle negativo: o mutante ainda saiu 99"; fails=$((fails+1)); fi
date > "$FLAG"

# controles negativos das portas do preflight: remove UMA porta (a linha marcada "# gate:<nome>") e exige que o mutante deixe de
# reproduzir o (rc, motivo) do script real no cenário que a porta guarda. Nas portas "ilegivel-*" o mutante ainda recusa (a
# comparação do número com vazio falha), mas com o motivo errado ("pressao", "swap_cresce"...): é exatamente o "ilegível virou
# baixo" que o log não pode contar como "baixo".
mutant() { # marcador esperado VAR=valor...  (o cenário que a porta guarda, como pares VAR=valor)
  local m="$1" want="$2" cnt real mut kv; shift 2
  cnt=$(grep -c "# gate:$m\$" "$RUN")
  eq "controle $m: uma única linha marcada '# gate:$m'" 1 "$cnt"; [ "$cnt" = 1 ] || return 0
  sed "/# gate:$m\$/s/.*/true/" "$RUN" > "$T/mut.sh"; chmod +x "$T/mut.sh"
  reset; real=$( for kv in "$@"; do export "$kv"; done; outcome "$RUN" )
  reset; mut=$( for kv in "$@"; do export "$kv"; done; outcome "$T/mut.sh" )
  eq "controle $m: o script real dá '$want'" "$want" "$real"
  n=$((n+1)); if [ "$mut" != "$want" ]; then echo "ok   controle $m: o mutante sem a porta não reproduz ($mut)"; else echo "FAIL controle $m: o mutante ainda reproduz '$want'"; fails=$((fails+1)); fi
}
mutant ram            98:ram                  STUB_AVAIL_MB=1000
mutant ilegivel-avail 98:ilegivel:avail       STUB_VM_DROP='Pages speculative'
mutant ilegivel-pressao 98:ilegivel:pressure  STUB_PRESSURE_FAIL=1
mutant pressao        98:pressao              STUB_PRESSURE=2
mutant ilegivel-delta 98:ilegivel:swap_delta  STUB_SWAP_RAW=garbage
mutant cresce         98:swap_cresce          STUB_SWAP_MB=5000 STUB_SWAP2_MB=5400
mutant ilegivel-swap  98:ilegivel:swap        "STUB_PF_RAW=avail_mb=8000\nswap_mb=\nswap_delta_mb=0\npressure=1\npower=ac\nbatt=90"
mutant teto           98:swap_teto            STUB_SWAP_MB=9000
mutant ilegivel-power 98:ilegivel:power       STUB_PMSET_FAIL=1
mutant ilegivel-batt  98:ilegivel:batt        "STUB_PMSET_RAW=Now drawing from 'Battery Power'"

# MBP_SELFTEST_SKIP=presenca: pula a presença (o prod test antigo ga-9e2rjh tem o orçamento de 900 s da suíte antiga; a presença tem o seu em story-ga-77c1qg.*)
if [ "${MBP_SELFTEST_SKIP:-}" != presenca ]; then
  presenca_cases; neg_presenca
  chave_cases
fi
echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
