#!/usr/bin/env bash
# disk-recovery-ladder.selftest.sh — testa o maestro da escada de recuperação de disco (ga-1p1i5jr.1) SEM tocar na máquina.
#
# O QUE É SIMULADO  df, swap e relógio (arquivos `DR_FREE_MB_FILE` / `DR_SWAP_MB_FILE` / `DR_NOW_FILE`: cada "rodada" do launchd é uma chamada com a hora que o teste escolhe, então 6 h de reinício
#   passam em segundos), os degraus D2/D3/D4 (stubs que registram a chamada e devolvem o rc que o teste manda), `notify` e `gc mail` (stubs que só anotam). Nada real é parado, reiniciado
#   ou enviado. O trecho que lê o `df`/`sysctl` de verdade é testado com shims no PATH (o `df` shim também prova que NUNCA se lê `df /`).
# O QUE É VERIFICADO  uma seção por regra do maestro (títulos abaixo): fronteiras dos limiares, histerese, lacuna, ordem e um degrau por rodada, piso duro, teto de 6 h do D4, leituras ilegíveis = não age.
# COMO RODAR     bash scripts/disk-recovery-ladder.selftest.sh        (~3-5 min sob carga)
#   O caminho de quem tem o disco apertado é pelo guarda: scripts/heavy-guard.sh --what selftest-hq --max-file-mb 512 -- bash scripts/disk-recovery-ladder.selftest.sh
#   Para testar uma cópia modificada do maestro (mutantes): DR_LADDER_PATH=/caminho/disk-recovery-ladder.mutN.sh ST_FAILFAST=1 bash scripts/disk-recovery-ladder.selftest.sh
#   (ST_FAILFAST=1 sai no 1º FAIL com rc 1: o mutante foi pego; se chegar ao fim com rc 0, o selftest NÃO pega aquele mutante)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LADDER="${DR_LADDER_PATH:-$HERE/disk-recovery-ladder.sh}"
[ -f "$LADDER" ] || { echo "FATAL: maestro não encontrado em $LADDER"; exit 1; }
# variáveis DR_* do ambiente de quem chamou não podem vazar para dentro dos testes (os testes passam o que querem por `env -i`)
for _v in $(compgen -e | grep '^DR_'); do [ "$_v" = DR_LADDER_PATH ] || unset "$_v"; done

W="$(mktemp -d "${TMPDIR:-/tmp}/dr-selftest.XXXXXX")" || { echo "FATAL: mktemp"; exit 1; }
case "$W" in */dr-selftest.??????) ;; *) echo "FATAL: diretório de trabalho estranho: $W"; exit 1 ;; esac
trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$W/stubs" "$W/sd" "$W/tmp" "$W/bin" "$W/home"
SD="$W/sd"                                 # STUB_DIR: o que os stubs leem (modos) e escrevem (chamadas)
CITY="$W/city"
STATE="$CITY/.gc/disk-recovery.state"; LOG="$CITY/.gc/logs/disk-recovery.log"; OFF="$CITY/.gc/disk-recovery.off"; LOCK="$CITY/.gc/disk-recovery.lock"
T0=1000000
PASS=0; FAIL=0; OUT=""; RC=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() {
  FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed 's/^/        | /' | tail -n 12
  # ST_FAILFAST=1 (para mutantes): o primeiro FAIL já prova que o mutante foi pego; não gasta os minutos do resto
  if [ "${ST_FAILFAST:-0}" = 1 ]; then printf '\n(ST_FAILFAST) parei no 1º FAIL: %s passaram, %s falharam\n' "$PASS" "$FAIL"; exit 1; fi
  return 0
}
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else nope "$3 (obtido '$1', esperado '$2')"; fi; }
# has/hasnt: casamento de texto fixo por `case` (sem fork nem pipe: um `printf | grep -q` sob pipefail deu falso FAIL com a máquina sob carga, com o texto presente)
has()   { case "$1" in *"$2"*) ok "$3" ;; *) nope "$3 (faltou: $2)" ;; esac; }
hasnt() { case "$1" in *"$2"*) nope "$3 (não devia ter: $2)" ;; *) ok "$3" ;; esac; }
section() { printf '\n== %s\n' "$1"; }

# ── stubs ───────────────────────────────────────────────────────────────────────────────────────────────────
for n in d2 d3 d4; do
  cp /dev/null "$W/stubs/$n"
  cat > "$W/stubs/$n" <<'STUB'
#!/bin/bash
# degrau simulado. Modo em $STUB_DIR/mode.<nome>: linhas rc=N msg=... setfree=N slp=N killp=1
n=$(basename "$0"); rc=0; msg="stub $n"; setfree=""; slp=0; killp=0
[ -f "$STUB_DIR/mode.$n" ] && . "$STUB_DIR/mode.$n"
echo "$n $1" >> "$STUB_DIR/calls"
echo $$ > "$STUB_DIR/pid.$n"
cp "$DR_STATE" "$STUB_DIR/state_at_call.$n" 2>/dev/null
[ -n "$setfree" ] && printf '%s' "$setfree" > "$DR_FREE_MB_FILE"
[ "$killp" = 1 ] && kill -9 "$PPID"
[ "$slp" -gt 0 ] && sleep "$slp"
echo "$msg"
exit "$rc"
STUB
  chmod 755 "$W/stubs/$n"
done
cat > "$W/stubs/notify" <<'STUB'
#!/bin/bash
p=""; t=""
while [ $# -gt 1 ]; do case "$1" in -p) p=$2; shift 2 ;; -t) t=$2; shift 2 ;; *) shift ;; esac; done
echo "p=$p force=${NOTIFY_FORCE_PUSH:-} t=$t msg=$1" >> "$STUB_DIR/notify.log"
case "$(cat "$STUB_DIR/notify.mode" 2>/dev/null)" in fail) echo "boom"; exit 1 ;; hang) sleep 30 ;; esac
exit 0
STUB
cat > "$W/stubs/gc" <<'STUB'
#!/bin/bash
echo "to=$3 subj=$5" >> "$STUB_DIR/mail.log"
case "$(cat "$STUB_DIR/mail.mode" 2>/dev/null)" in fail) echo "boom"; exit 1 ;; esac
exit 0
STUB
chmod 755 "$W/stubs/notify" "$W/stubs/gc"
printf '#!/bin/bash\nexit 0\n' > "$W/stubs/noexec"; chmod 644 "$W/stubs/noexec"

# shims de df e sysctl (só nos testes do leitor real)
cat > "$W/bin/df" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_DIR/df.args"
case "${STUB_DF_MODE:-ok}" in
  ok)      printf 'Filesystem   1048576-blocks   Used Available Capacity Mounted on\n/dev/disk3s5          228000 200000      4096      98%% %s\n' "/System/Volumes/Data" ;;
  root)    printf 'Filesystem   1048576-blocks   Used Available Capacity Mounted on\n/dev/disk3s1s1        228000  16000    190000      8%% %s\n' "/" ;;
  fail)    echo "df: boom" >&2; exit 1 ;;
  empty)   : ;;
  garbage) printf 'Filesystem   1048576-blocks   Used Available Capacity Mounted on\n/dev/disk3s5          228000 200000      abc      98%% %s\n' "/System/Volumes/Data" ;;
  big)     printf 'Filesystem   1048576-blocks   Used Available Capacity Mounted on\n/dev/disk3s5          228000 200000 99999999999      98%% %s\n' "/System/Volumes/Data" ;;
esac
STUB
cat > "$W/bin/sysctl" <<'STUB'
#!/bin/bash
case "${STUB_SYSCTL_MODE:-ok}" in
  ok)      echo "total = 2048.00M  used = 1536.25M  free = 511.75M  (encrypted)" ;;
  gig)     echo "total = 4096.00M  used = 2.50G  free = 1.50G  (encrypted)" ;;
  fail)    exit 1 ;;
  garbage) echo "total = ?  used = ??  free = ?" ;;
  kilo)    echo "total = 2048.00M  used = 1536.25K  free = 511.75M  (encrypted)" ;;
  noused)  echo "total = 2048.00M  free = 511.75M" ;;
  empty)   : ;;
esac
STUB
chmod 755 "$W/bin/df" "$W/bin/sysctl"

# ── ambiente e helpers ──────────────────────────────────────────────────────────────────────────────────────
BASE=( "PATH=$PATH" "HOME=$W/home" "TMPDIR=$W/tmp" "STUB_DIR=$SD"
  "DR_CITY=$CITY" "DR_STATE=$STATE" "DR_LOG=$LOG" "DR_OFF_FILE=$OFF" "DR_LOCK=$LOCK"
  "DR_FREE_MB_FILE=$W/free" "DR_SWAP_MB_FILE=$W/swap" "DR_NOW_FILE=$W/now"
  "DR_D2_CMD=$W/stubs/d2" "DR_D3_CMD=$W/stubs/d3" "DR_D4_CMD=$W/stubs/d4"
  "DR_NOTIFY_BIN=$W/stubs/notify" "DR_GC_BIN=$W/stubs/gc" "DR_SETTLE_S=0" )
XENV=()

runl() {  # roda o maestro com os argumentos; OUT/RC
  OUT=$(env -i "${BASE[@]}" ${XENV[@]+"${XENV[@]}"} /bin/bash "$LADDER" "$@" 2>&1); RC=$?
}
setfree() { if [ "$1" = MISSING ]; then rm -f "$W/free"; else printf '%s' "$1" > "$W/free"; fi; }
setswap() { if [ "$1" = MISSING ]; then rm -f "$W/swap"; else printf '%s' "$1" > "$W/swap"; fi; }
tick() { setfree "$1"; setswap "$2"; printf '%s' "$3" > "$W/now"; runl --run; }   # livre swap agora
ncall()  { local n; n=$(grep -c -x -F "$1 $2" "$SD/calls" 2>/dev/null); echo "${n:-0}"; }
ncallall() { local n; n=$(grep -c . "$SD/calls" 2>/dev/null); echo "${n:-0}"; }
nnotify() { local n; n=$(grep -c -F -- "$1" "$SD/notify.log" 2>/dev/null); echo "${n:-0}"; }
nmail()   { local n; n=$(grep -c -F -- "$1" "$SD/mail.log" 2>/dev/null); echo "${n:-0}"; }
sv()  { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -n 1; }
logtxt() { cat "$LOG" 2>/dev/null; }
mkstate() {  # arquivo since2 since3 since4 [acted4_ts] [hard_n]: estado COMPLETO (todas as chaves do save_state) escrito à mão; última leitura = T0, sem lacuna
  printf 'v=1\nlast_ts=%s\nlast_free_mb=2900\nlast_swap_mb=0\nhard_n=%s\nhard_ts=0\nacted4_ts=%s\nesc4=0\nwarn_ts=0\nwarn2_ts=0\nhb_ts=%s\nsince2=%s\nsince3=%s\nsince4=%s\nst2=none\nst3=none\nst4=none\nat2=0\nat3=0\nat4=0\nnt2=0\nnt3=0\nnt4=0\n' \
    "$T0" "${6:-0}" "${5:-0}" "$T0" "$2" "$3" "$4" > "$1"
}
mode() { printf '%s\n' "${@:2}" > "$SD/mode.$1"; }
reset() {
  rm -rf "$CITY" "$W/ro"; mkdir -p "$CITY/.gc/logs"
  rm -f "$SD"/* "$W/tmp"/* "$W/stubs/d2.alt" 2>/dev/null
  : > "$SD/calls"; : > "$SD/notify.log"; : > "$SD/mail.log"
  XENV=(); setfree 20000; setswap 0; printf '%s' "$T0" > "$W/now"
}
WSEQ=""; WFIRST2=""; WFIRST3=""; WFIRST4=""; WMAX=0
walk() {  # livre swap de até passo: um tick a cada $5 s, de $3 a $4 (inclusive). WSEQ = "t=degrau ..."; WFIRSTn = 1º tick em que o Dn foi chamado; WMAX = mais chamadas numa rodada só
  local f=$1 s=$2 t=$3 to=$4 step=$5 before after n
  WSEQ=""; WFIRST2=""; WFIRST3=""; WFIRST4=""; WMAX=0
  while [ "$t" -le "$to" ]; do
    before=$(ncallall); local b2 b3 b4; b2=$(ncall d2 --run); b3=$(ncall d3 --run); b4=$(ncall d4 --run)
    tick "$f" "$s" "$t"
    after=$(ncallall); n=$((after - before)); [ "$n" -gt "$WMAX" ] && WMAX=$n
    [ "$(ncall d2 --run)" -gt "$b2" ] && { WSEQ="$WSEQ $t=d2"; [ -n "$WFIRST2" ] || WFIRST2=$t; }
    [ "$(ncall d3 --run)" -gt "$b3" ] && { WSEQ="$WSEQ $t=d3"; [ -n "$WFIRST3" ] || WFIRST3=$t; }
    [ "$(ncall d4 --run)" -gt "$b4" ] && { WSEQ="$WSEQ $t=d4"; [ -n "$WFIRST4" ] || WFIRST4=$t; }
    t=$((t + step))
  done
}

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
section "uso e rodada sem episódio"
reset
for a in "" "--bogus" "--run extra"; do runl $a; eq "$RC" 2 "argumentos '$a' → uso (2)"; done
tick 20000 0 "$T0"
eq "$RC" 0 "disco folgado: rodada 0"
eq "$(ncallall)$(nnotify p=)$(nmail to=)$(sv since2)$(sv since3)$(sv since4)" 000000 "disco folgado: nenhum degrau, aviso nem mail; cronômetros em 0"
eq "$(sv v)" 1 "estado gravado com a marca v=1"
has "$(logtxt)" "ok: livre=20000MB" "primeira rodada escreve o batimento"
n1=$(wc -l < "$LOG"); tick 20000 0 $((T0 + 120)); n2=$(wc -l < "$LOG")
eq "$n2" "$n1" "rodada tranquila seguinte (dentro de 1 h): nada novo no log"
[ ! -d "$LOCK" ] && ok "trava liberada ao sair" || nope "trava sobrou"

section "interruptor"
reset; touch "$OFF"; tick MISSING MISSING "$T0"
eq "$RC" 10 "interruptor ligado → 10 sem nem ler o df"
eq "$(nnotify p=)" 0 "interruptor: df ilegível NÃO avisou (nem leu)"
[ ! -e "$STATE" ] && ok "interruptor: nenhum estado gravado" || nope "interruptor: gravou estado"
has "$OUT" "interruptor ligado" "interruptor: diz no stdout/log"
rm -f "$OFF"; tick 20000 0 "$T0"; eq "$RC" 0 "interruptor desligado: volta a rodar"

section "leitura ilegível: NÃO age, avisa (df)"
for bad in MISSING "" abc -5 1.5 99999999999 0x10 " 100 "; do
  reset; walk 5000 0 "$T0" $((T0 + 800)) 100   # episódio em andamento (D2 a 100 s de vencer)
  tick "$bad" 0 $((T0 + 900))
  eq "$RC" 30 "df='$bad' → 30"
  eq "$(ncall d2 --run),$(nnotify 'p=4 force=1')" "0,1" "df='$bad': D2 NÃO foi chamado mesmo com o tempo vencido; aviso -p 4 forçado, 1 vez"
  has "$(logtxt)" "leitura impossível" "df='$bad': log diz"
  eq "$(sv since2)" "$T0" "df='$bad': cronômetro NÃO zerou (ilegível ≠ recuperou)"
done
reset; tick MISSING 0 "$T0"; tick MISSING 0 $((T0 + 120))
eq "$(nnotify 'p=4 force=1')" 1 "aviso de leitura impossível: 1 por hora (2ª rodada calada)"
tick MISSING 0 $((T0 + 3600))
eq "$(nnotify 'p=4 force=1')" 2 "aviso de leitura impossível: de novo depois de 1 h"
reset; setfree 20000; setswap 0; printf 'zz' > "$W/now"; runl --run
eq "$RC" 30 "relógio ilegível → 30"; has "$OUT" "relógio ilegível" "relógio ilegível: diz"

section "leitura ilegível: swap"
for bad in MISSING "" abc -1 2.5; do
  reset; walk 5000 0 "$T0" $((T0 + 800)) 100
  tick 5000 "$bad" $((T0 + 900))
  eq "$RC,$(ncall d2 --run)" "30,0" "swap='$bad' → 30 e D2 NÃO chamado"
  has "$(logtxt)" "swap (vm.swapusage) ilegível" "swap='$bad': log diz o que faltou"
done
tick 5000 0 $((T0 + 1000))
eq "$(ncall d2 --run)" 1 "leitura volta: o cronômetro seguiu (D2 chamado na 1ª rodada legível, tempo contado desde antes)"

section "fronteiras dos limiares (cronômetro começa em cada nível)"
for row in "5121 0 0 0" "5120 $T0 0 0" "4097 $T0 0 0" "4096 $T0 $T0 0" "3072 $T0 $T0 0" "3071 $T0 $T0 $T0"; do
  set -- $row; reset; tick "$1" 0 "$T0"
  eq "$(sv since2),$(sv since3),$(sv since4)" "$2,$3,$4" "livre=$1MB → cronômetros D2,D3,D4 = $2,$3,$4"
done

section "D2: tempo do limiar (899 s não, 900 s sim) e repetição"
reset
tick 5000 0 "$T0"; tick 5000 0 $((T0 + 450)); tick 5000 0 $((T0 + 899))
eq "$(ncall d2 --run)" 0 "D2 não chamado aos 899 s"
tick 5000 0 $((T0 + 900))
eq "$(ncall d2 --run),$(ncallall)" "1,1" "D2 chamado aos 900 s, com --run, e só o D2 (D3 e D4 não)"
eq "$(sv st2),$RC" "acted,0" "D2 rc 0 → marca acted, rodada 0"
eq "$(nnotify 'p=3 force= '),$(nmail 'to=mayor subj=Disco: degrau D2 agiu')" "1,1" "D2 agiu: notify -p 3 sem push forçado, 1 mail ao Mayor"
walk 5000 0 $((T0 + 1200)) $((T0 + 2400)) 300
eq "$(ncall d2 --run)" 1 "D2 acted: não repete em 25 min"
tick 5000 0 $((T0 + 2700))
eq "$(ncall d2 --run)" 2 "D2 acted: repete aos 30 min"
eq "$(nnotify 'p=3 force= t=Disco: degrau D2 agiu'),$(nmail 'D2 agiu')" "2,2" "D2 acted que repete: cada vez avisa e manda mail (só FALHOU é limitado)"

section "D2: cada código de saída do degrau"
for row in "10 idle 0 0 0" "20 failed 20 1 1" "30 unknown 0 0 0" "7 failed 20 1 1"; do
  set -- $row; reset; mode d2 "rc=$1"
  walk 5000 0 "$T0" $((T0 + 900)) 100
  eq "$(sv st2)" "$2" "D2 rc=$1 → marca $2"
  eq "$RC,$(nnotify 'FALHOU'),$(nmail 'FALHOU')" "$3,$4,$5" "D2 rc=$1 → saída do maestro $3, aviso FALHOU: $4, mail FALHOU: $5"
  tick 5000 0 $((T0 + 1140))
  eq "$(ncall d2 --run)" 1 "D2 rc=$1: não repete antes de 5 min"
  tick 5000 0 $((T0 + 1200))
  eq "$(ncall d2 --run)" 2 "D2 rc=$1: repete aos 5 min"
done
reset; mode d2 rc=30; walk 5000 0 "$T0" $((T0 + 900)) 100
has "$(cat "$SD/notify.log")" "não leu o estado" "D2 rc=30: avisa que o degrau não leu o estado"
eq "$(nnotify 'p=3 force= t=Disco: degrau D2 não leu')" 1 "D2 rc=30: -p 3 sem push forçado (normal)"
reset; mode d2 rc=10; mode d3 rc=10; mode d4 rc=30; walk 2500 0 "$T0" $((T0 + 3600)) 300
eq "$(nnotify 'p=4 force=1 t=Disco: degrau D4 não leu')" 1 "D4 rc=30 (cego com o disco crítico): -p 4 com push forçado"

section "D2 que continua FALHANDO: 1 aviso + 1 mail por hora por degrau, o resto só no log"
reset; mode d2 rc=20
walk 5000 0 "$T0" $((T0 + 4200)) 100   # chamadas aos 900 s e a cada 300 s depois; a última rodada (4200 s) é uma chamada sem aviso
c=$(ncall d2 --run)
[ "$c" -ge 10 ] && ok "D2 foi chamado $c vezes em 1 h (repete a cada 5 min)" || nope "D2 chamado só $c vezes"
eq "$(nnotify 'p=4 force=1 t=Disco: degrau D2 FALHOU'),$(nmail 'D2 FALHOU')" "1,1" "…mas só 1 aviso (push forçado) e 1 mail"
eq "$RC" 20 "…a saída do maestro continua 20 nas rodadas sem aviso"
has "$(logtxt)" "FALHOU de novo: o aviso e o mail dele saíram há" "…e o log diz que suprimiu"
tick 5000 0 $((T0 + 4500))
eq "$(nnotify 'p=4 force=1 t=Disco: degrau D2 FALHOU'),$(nmail 'D2 FALHOU')" "2,2" "passada 1 h do último aviso: avisa de novo"

section "D2: estourou o tempo → TERM e conta como falha"
reset; XENV=(DR_RUNG_TIMEOUT_S=1); mode d2 slp=30
walk 5000 0 "$T0" $((T0 + 800)) 100
SECONDS=0; tick 5000 0 $((T0 + 900)); el=$SECONDS
[ "$el" -le 25 ] && ok "tempo do degrau limitado (${el}s para um degrau de 30 s e limite 1 s)" || nope "demorou ${el}s"
eq "$(sv st2),$RC" "failed,20" "estourou → failed, saída 20"
has "$(logtxt)" "estourou 1s" "estourou: log diz"
if kill -0 "$(cat "$SD/pid.d2" 2>/dev/null)" 2>/dev/null; then nope "o degrau seguiu vivo depois do TERM"; else ok "o degrau foi encerrado"; fi
[ -z "$(ls "$W/tmp" 2>/dev/null)" ] && ok "estourar o tempo não deixa temporário para trás" || nope "temporários sobraram depois do timeout: $(ls "$W/tmp")"

section "ordem D2 → D3 → D4, um degrau por rodada (livre=2900, degraus devolvem 10)"
reset; mode d2 rc=10; mode d3 rc=10; mode d4 rc=10
walk 2900 0 "$T0" $((T0 + 3600)) 300
eq "$WFIRST2" $((T0 + 900))  "D2 entra aos 15 min"
eq "$WFIRST3" $((T0 + 1800)) "D3 entra aos 30 min"
eq "$WFIRST4" $((T0 + 3600)) "D4 entra aos 60 min (não antes: 3300 s sem chamada)"
eq "$WMAX" 1 "nunca mais de um degrau por rodada"
has "$WSEQ" "$((T0 + 2100))=d3" "repetição vai do mais alto para o mais baixo (D3 antes do D2 aos 35 min)"
eq "$(sv st4)" idle "D4 rc 10 (guarda adiou) → idle"
eq "$(sv acted4_ts)" 0 "D4 rc 10: a marca do reinício volta a 0"
eq "$(nmail 'D4')" 0 "D4 idle: sem mail"

section "1ª passada com VÁRIOS degraus vencidos ao mesmo tempo: D2 primeiro, depois D3, depois D4, um por rodada"
# Com rodadas a cada 5 min o cronômetro de um nível só vence depois de o de baixo já ter sido chamado, então o walk acima nunca tem dois
# vencidos juntos. Aqui o estado é escrito à mão (D2/D3/D4 vencidos, nenhum chamado ainda, leitura anterior de 2 min atrás, sem lacuna).
reset; mode d2 rc=10; mode d3 rc=10; mode d4 rc=10
mkstate "$STATE" $((T0 - 4000)) $((T0 - 4000)) $((T0 - 4000))
tick 2900 0 $((T0 + 120))
eq "$(ncall d2 --run)$(ncall d3 --run)$(ncall d4 --run)" 100 "D2, D3 e D4 vencidos juntos, nenhum chamado: a 1ª rodada chama SÓ o D2"
tick 2900 0 $((T0 + 240))
eq "$(ncall d2 --run)$(ncall d3 --run)$(ncall d4 --run)" 110 "…a rodada seguinte, SÓ o D3 (o D2 já foi chamado)"
tick 2900 0 $((T0 + 360))
eq "$(ncall d2 --run)$(ncall d3 --run)$(ncall d4 --run)" 111 "…e a seguinte, SÓ o D4"

section "D3 agiu: aviso -p 4 forçado; D4 agiu: -p 5 forçado"
reset; mode d2 rc=10; mode d3 rc=0
walk 3500 0 "$T0" $((T0 + 1800)) 300
eq "$(nnotify 'p=4 force=1 t=Disco: degrau D3 agiu'),$(nmail 'D3 agiu')" "1,1" "D3 agiu: notify -p 4 com NOTIFY_FORCE_PUSH=1, e mail"
reset; mode d2 rc=10; mode d3 rc=10; mode d4 rc=0
walk 2500 0 "$T0" $((T0 + 3600)) 300
eq "$(nnotify 'p=5 force=1 t=Disco: degrau D4 agiu'),$(nmail 'D4 agiu')" "1,1" "D4 agiu: notify -p 5 com NOTIFY_FORCE_PUSH=1, e mail"
has "$(cat "$SD/state_at_call.d4")" "acted4_ts=$((T0 + 3600))" "a marca do D4 já estava NO DISCO quando o D4 foi chamado"

section "piso duro: < 1,5 GB em 2 leituras seguidas chama o D4 sem pular a regra dos outros"
reset; tick 1400 0 "$T0"
eq "$(ncallall)" 0 "1 leitura abaixo de 1,5 GB: nada"
tick 1400 0 $((T0 + 120))
eq "$(ncall d4 --run)" 1 "2 leituras seguidas: D4"
eq "$(ncall d2 --run)$(ncall d3 --run)" 00 "…e só o D4 (D2/D3 ainda não tinham o tempo deles)"
has "$(logtxt)" "leituras < 1536MB seguidas=2" "log mostra a contagem do piso duro"
reset; tick 1400 0 "$T0"; tick 2000 0 $((T0 + 120)); tick 1400 0 $((T0 + 240)); tick 2000 0 $((T0 + 360)); tick 1400 0 $((T0 + 480))
eq "$(ncallall)" 0 "leituras abaixo do piso alternando com acima: nunca seguidas, nada"
for row in "1536 0" "1535 1"; do set -- $row; reset; tick "$1" 0 "$T0"; tick "$1" 0 $((T0 + 120)); eq "$(ncall d4 --run)" "$2" "2 leituras de $1 MB seguidas: D4 chamado $2 vez (o piso duro é < 1536)"; done
reset; tick 1400 0 "$T0"; tick 1400 0 $((T0 + 700))
eq "$(ncallall)" 0 "lacuna de 700 s entre as 2 leituras: a contagem recomeça (nada)"
reset; tick 1400 0 "$T0"; tick 1400 0 $((T0 + 1)); tick 1400 0 $((T0 + 99))
eq "$(ncall d4 --run)" 0 "rodadas coladas (1 s e 99 s depois, p.ex. --run à mão ao lado da agendada) contam como UMA leitura: nada"
tick 1400 0 $((T0 + 100))
eq "$(ncall d4 --run)" 1 "…a 2ª leitura só conta a partir de 100 s depois da 1ª: D4"

section "histerese de 512 MB"
reset; tick 5000 0 "$T0"; tick 5631 0 $((T0 + 300)); tick 5000 0 $((T0 + 600))
eq "$(sv since2)" "$T0" "5631 MB (< limiar+512): cronômetro NÃO zera"
tick 5000 0 $((T0 + 900))
eq "$(ncall d2 --run)" 1 "…e o D2 vence contando desde o início"
tick 5632 0 $((T0 + 1000))
eq "$(sv since2),$(sv st2)" "0,none" "5632 MB (= limiar+512): cronômetro e marca zeram"
has "$(logtxt)" "recuperou" "recuperação aparece no log"
walk 5000 0 $((T0 + 1100)) $((T0 + 1100 + 899)) 300; tick 5000 0 $((T0 + 1100 + 899))
eq "$(ncall d2 --run)" 1 "cronômetro recomeçou: 899 s depois ainda não chama"
tick 5000 0 $((T0 + 1100 + 900))
eq "$(ncall d2 --run)" 2 "…e chama aos 900 s do novo episódio"

section "lacuna entre leituras zera os cronômetros"
reset; tick 5000 0 "$T0"; tick 5000 0 $((T0 + 600)); tick 5000 0 $((T0 + 1200))
eq "$(ncall d2 --run)" 1 "lacuna de exatamente 600 s: continua contando (D2 aos 1200 s)"
reset; tick 5000 0 "$T0"; tick 5000 0 $((T0 + 600)); tick 5000 0 $((T0 + 1201))
eq "$(ncall d2 --run)" 0 "lacuna de 601 s: zera, NÃO chama D2 com o tempo que ninguém viu"
eq "$(sv since2)" $((T0 + 1201)) "…e o cronômetro recomeça na rodada atual"
has "$(logtxt)" "lacuna" "lacuna aparece no log"
reset; tick 5000 0 $((T0 + 2000)); tick 5000 0 $((T0 + 1500))
eq "$(sv since2)" $((T0 + 1500)) "relógio que andou para trás: zera"

section "um degrau resolve: re-mede e zera tudo"
reset; mode d2 rc=0 setfree=9000
walk 5000 0 "$T0" $((T0 + 900)) 100
eq "$(sv since2),$(sv st2),$(sv last_free_mb)" "0,none,9000" "D2 liberou espaço: re-medição vê 9000 e zera o cronômetro"
has "$(cat "$SD/notify.log")" "5000 -> 9000" "aviso mostra livre antes -> depois"
tick 9000 0 $((T0 + 960))
eq "$(ncall d3 --run)$(ncall d4 --run)" 00 "recuperou: D3/D4 não entram"

section "degrau ausente ou sem permissão de execução"
reset; XENV=("DR_D2_CMD=$W/nao-existe")
walk 5000 0 "$T0" $((T0 + 1500)) 100
eq "$(nnotify 'p=4 force=1 t=Disco: degrau D2 ausente')" 1 "D2 ausente: avisa UMA vez (não a cada rodada)"
has "$(logtxt)" "degrau D2 ausente" "D2 ausente: log diz"
eq "$(sv st2),$RC" "absent,0" "D2 ausente: marca absent, rodada não falha"
reset; XENV=("DR_D2_CMD=$W/stubs/noexec")
walk 5000 0 "$T0" $((T0 + 900)) 100
has "$(logtxt)" "degrau D2 ausente ou sem permissão" "D2 sem permissão de execução = ausente"
reset; XENV=("DR_D2_CMD=$W/nao-existe"); mode d3 rc=10; mode d4 rc=10
walk 3500 0 "$T0" $((T0 + 1800)) 100
eq "$WFIRST3" $((T0 + 1800)) "D2 ausente: pula para o D3, que entra na rodada em que o tempo dele vence"
eq "$(ncall d4 --run)" 0 "…e o D4 não entra"
reset; XENV=("DR_D2_CMD=$W/nao-existe" "DR_D3_CMD=$W/nao-existe"); mode d4 rc=10
walk 2900 0 "$T0" $((T0 + 3500)) 100
eq "$(ncall d4 --run)" 0 "D2 e D3 ausentes: o D4 NÃO é chamado antes do tempo dele (aos 3500 s)"
tick 2900 0 $((T0 + 3600))
eq "$(ncall d4 --run)" 1 "…e é chamado aos 3600 s"

section "teto de 6 h do D4: sem reinício em laço"
reset; mode d2 rc=10; mode d3 rc=10; mode d4 rc=0
walk 2500 0 "$T0" $((T0 + 3600)) 300
eq "$(ncall d4 --run)" 1 "D4 chamado aos 60 min"
walk 2500 0 $((T0 + 3600 + 540)) $((T0 + 3600 + 21060)) 540
eq "$(ncall d4 --run)" 1 "5 h 51 min depois: D4 NÃO foi chamado de novo"
eq "$(nnotify 'preciso de um humano')" 1 "…e escalou UMA vez (-p 5)"
eq "$(nnotify 'p=5 force=1 t=Disco: segue baixo'),$(nmail 'já disparou')" "1,1" "escalada com push forçado e 1 mail ao Mayor"
tick 2500 0 $((T0 + 3600 + 21600))
eq "$(ncall d4 --run)" 2 "passadas 6 h: o D4 pode ser chamado de novo"
reset; mode d2 rc=10; mode d3 rc=10; mode d4 rc=0
walk 2500 0 "$T0" $((T0 + 3600)) 300; tick 9000 0 $((T0 + 3900))
eq "$(sv st4),$(sv esc4),$(sv acted4_ts)" "none,0,$((T0 + 3600))" "disco recuperou: marca do D4 e escalada zeradas, mas a hora do último reinício fica (o teto de 6 h vale entre episódios)"
reset; XENV=(DR_D2_HOLD_S=60 DR_D3_HOLD_S=120 DR_D4_HOLD_S=180); mode d2 rc=10; mode d3 rc=10; mode d4 rc=0
walk 2500 0 "$T0" $((T0 + 180)) 60; tick 9000 0 $((T0 + 240)); walk 2500 0 $((T0 + 300)) $((T0 + 540)) 60
eq "$(ncall d4 --run),$(nnotify 'preciso de um humano')" "1,1" "novo episódio dentro de 6 h: D4 não repete e escala"

section "D4 falhou ou adiou: a marca de reinício volta"
reset; mode d2 rc=10; mode d3 rc=10; mode d4 rc=20
walk 2500 0 "$T0" $((T0 + 3600)) 300
eq "$(sv acted4_ts),$RC" "0,20" "D4 rc 20: acted4_ts volta a 0, saída 20"
tick 2500 0 $((T0 + 3900))
eq "$(ncall d4 --run)" 2 "D4 falhou: tenta de novo em 5 min (não é o teto de 6 h)"

section "processo morto no meio do D4 (reinício derruba o maestro)"
reset; mode d2 rc=10; mode d3 rc=10; mode d4 killp=1
walk 2500 0 "$T0" $((T0 + 3600)) 300
[ "$RC" -ne 0 ] && ok "maestro morreu junto (rc=$RC)" || nope "maestro não morreu"
eq "$(sv acted4_ts),$(sv st4)" "$((T0 + 3600)),unknown" "a marca estava gravada antes da morte"
tick 2500 0 $((T0 + 3660))
eq "$RC" 0 "trava velha (pid morto) é refeita: nova rodada roda"
walk 2500 0 $((T0 + 3960)) $((T0 + 4900)) 300
eq "$(ncall d4 --run),$(nnotify 'preciso de um humano')" "1,1" "depois da morte: D4 NÃO é chamado de novo e escala"
tick 2500 0 $((T0 + 3600 + 4000))
eq "$(sv since4),$(sv acted4_ts)" "$((T0 + 3600 + 4000)),$((T0 + 3600))" "boot (lacuna longa): cronômetros zeram e a hora do último reinício fica"

section "estado salvo ilegível: põe de lado, avisa, recomeça do zero"
for body in "lixo sem chave" "v=1\nsince2=abc" "v=1\nst2=bogus" "v=1\nsince2=-5" "v=1\nlast_ts=1.5" "since2=5" "v=1" "v=1\nlast_ts=1000800" ""; do
  lbl=$(printf "$body" | tr '\n' ' '); [ -n "$lbl" ] || lbl="(vazio)"
  reset; walk 5000 0 "$T0" $((T0 + 800)) 100
  printf "$body" > "$STATE"
  tick 5000 0 $((T0 + 900))
  eq "$RC,$(ncall d2 --run)" "0,0" "estado '$lbl' → rodada segue (0), D2 NÃO chamado por histórico que não li"
  has "$OUT" "estado salvo ilegível" "estado '$lbl': avisa"
  [ -n "$(ls "$STATE".corrupt-* 2>/dev/null)" ] && ok "estado '$lbl': posto de lado" || nope "estado '$lbl': não pôs de lado"
  eq "$(sv since2)" $((T0 + 900)) "estado '$lbl': cronômetro recomeça agora"
  eq "$(sv acted4_ts)" $((T0 + 900)) "estado '$lbl': acted4_ts = AGORA (não sei se o D4 acabou de disparar)"
done

section "estado CORTADO numa fronteira de linha (prefixo válido): chave que falta não vira 0 em silêncio"
reset; walk 5000 0 "$T0" $((T0 + 800)) 100; cp "$STATE" "$W/state.good"
nlines=$(wc -l < "$W/state.good")
for keep in 1 2 8 $((nlines - 1)); do
  head -n "$keep" "$W/state.good" > "$STATE"; rm -f "$STATE".corrupt-*
  tick 5000 0 $((T0 + 900))
  eq "$RC,$(ncall d2 --run)" "0,0" "estado cortado em $keep de $nlines linhas → rodada segue, D2 NÃO chamado por histórico que não li"
  has "$OUT" "estado salvo ilegível, incompleto ou inválido" "estado cortado em $keep linhas: AVISA (antes passava sem aviso)"
  [ -n "$(ls "$STATE".corrupt-* 2>/dev/null)" ] && ok "estado cortado em $keep linhas: posto de lado" || nope "estado cortado em $keep linhas: não pôs de lado"
  eq "$(sv acted4_ts)" $((T0 + 900)) "estado cortado em $keep linhas: acted4_ts = AGORA"
done
reset; walk 5000 0 "$T0" $((T0 + 800)) 100; tick 5000 0 $((T0 + 900))
[ -z "$(ls "$STATE".corrupt-* 2>/dev/null)" ] && ok "estado COMPLETO (controle): não é posto de lado" || nope "estado completo foi posto de lado"

section "estado perdido DEPOIS de o D4 disparar: o teto de 6 h vale (reinício em laço impossível)"
for body in "lixo sem chave" "v=1" "v=1\nlast_ts=1000120" ""; do
  lbl=$(printf "$body" | tr '\n' ' '); [ -n "$lbl" ] || lbl="(vazio)"
  reset; mode d4 rc=0
  tick 1400 0 "$T0"; tick 1400 0 $((T0 + 120))
  eq "$(ncall d4 --run)" 1 "estado '$lbl': D4 disparou uma vez (2 leituras < 1,5 GB)"
  printf "$body" > "$STATE"
  tick 1400 0 $((T0 + 240)); tick 1400 0 $((T0 + 360)); tick 1400 0 $((T0 + 480))
  eq "$(ncall d4 --run)" 1 "estado '$lbl' perdido + 2 leituras < 1,5 GB seguidas: o D4 NÃO é chamado de novo"
  eq "$(nnotify 'p=5 force=1 t=Disco: segue baixo'),$(nmail 'já disparou')" "1,1" "estado '$lbl': escala UMA vez (push forçado + mail) em vez de reiniciar"
done
tick 1400 0 $((T0 + 240 + 21840)); tick 1400 0 $((T0 + 240 + 21960))
eq "$(ncall d4 --run)" 2 "passadas 6 h da perda do estado: o D4 volta a poder ser chamado"
reset; mode d4 rc=0
tick 1400 0 "$T0"; tick 1400 0 $((T0 + 120)); rm -f "$STATE"
tick 1400 0 $((T0 + 240)); tick 1400 0 $((T0 + 360))
eq "$(ncall d4 --run)" 2 "estado AUSENTE (apagado à mão) é 1ª rodada de propósito: zera inclusive o teto (documentado no cabeçalho)"
has "$(logtxt)" "primeira rodada" "…e o log diz que é a primeira rodada"
reset; tick 20000 0 "$T0"; has "$(logtxt)" "primeira rodada" "sem estado = primeira rodada (sem aviso de corrompido)"
[ -z "$(ls "$STATE".corrupt-* 2>/dev/null)" ] && ok "primeira rodada não cria .corrupt" || nope "criou .corrupt à toa"
if [ "$(id -u)" != 0 ]; then
  reset; mkdir -p "$W/ro"; chmod 555 "$W/ro"; XENV=("DR_STATE=$W/ro/state")
  tick 20000 0 "$T0"
  eq "$RC" 30 "estado não gravável → 30"
  has "$(logtxt)" "não consegui gravar o estado" "estado não gravável: WARN no log"
  eq "$(nnotify 'p=4 force=1 t=Disco: a escada não consegue gravar o estado')" 1 "estado não gravável: avisa -p 4 com push forçado (a escada está cega)"
  tick 20000 0 $((T0 + 120))
  eq "$(nnotify 'p=4 force=1 t=Disco: a escada não consegue gravar o estado')" 1 "…no máximo 1 por hora (2ª rodada calada)"
  touch -t 200001010000 "$CITY/.gc/disk-recovery.nosave"; tick 20000 0 $((T0 + 240))
  eq "$(nnotify 'p=4 force=1 t=Disco: a escada não consegue gravar o estado')" 2 "…e de novo depois de 1 h"
  chmod 755 "$W/ro"

  section "estado ruim + estado não gravável: o arquivo ruim FICA no lugar até o novo estar gravado (senão o acted4_ts se perde de vez)"
  # limite do teste: dir somente-leitura também barra o rename, então isto prova o comportamento visível (nada some, o novo nasce com acted4_ts=agora), não a ordem tmp→aside em si (essa está no save_state)
  reset; mkdir -p "$W/ro"; XENV=("DR_STATE=$W/ro/state"); mode d4 rc=0
  printf 'lixo' > "$W/ro/state"; chmod 555 "$W/ro"
  tick 20000 0 "$T0"
  [ "$(cat "$W/ro/state" 2>/dev/null)" = lixo ] && [ -z "$(ls "$W/ro"/state.corrupt-* 2>/dev/null)" ] && ok "gravação falhou: o estado ruim continua no lugar (nada posto de lado)" || nope "estado ruim sumiu sem o novo estar gravado"
  chmod 755 "$W/ro"
  tick 20000 0 $((T0 + 120))
  [ -n "$(ls "$W/ro"/state.corrupt-* 2>/dev/null)" ] && eq "$(sed -n 's/^acted4_ts=//p' "$W/ro/state" | head -n 1)" $((T0 + 120)) "gravável de novo: o ruim vai para .corrupt e o novo estado nasce com acted4_ts = agora" || nope "gravável de novo: não pôs de lado ou não gravou"

  section "estado não gravável COM degrau vencido: o degrau NÃO é chamado (sem a marca no disco, reinício ou falha repetiriam a chamada)"
  reset; mkdir -p "$W/ro"; XENV=("DR_STATE=$W/ro/state"); mode d2 rc=0
  walk 5000 0 "$T0" $((T0 + 800)) 100
  chmod 555 "$W/ro"
  tick 5000 0 $((T0 + 900))
  eq "$(ncall d2 --run),$RC,$(nmail 'D2')$(nnotify 'degrau D2 agiu')" "0,30,00" "D2 vencido e estado não gravável: D2 NÃO foi chamado, saída 30, sem mail nem aviso de 'agiu'"
  has "$(logtxt)" "NÃO chamado: não consegui gravar a marca" "…e o log diz por quê"
  chmod 755 "$W/ro"
  tick 5000 0 $((T0 + 1020))
  eq "$(ncall d2 --run)" 1 "…gravável de novo: o D2 é chamado (o tempo dele continua contando)"

  # D2, D3 e D4 vencidos juntos (estado escrito à mão, como na seção da 1ª passada) e estado não gravável: a rodada ACABA no primeiro
  # degrau que não pôde gravar a marca; não tenta o D3 nem o D4 (uma linha só, não três) e nenhum é chamado.
  reset; mkdir -p "$W/ro"; XENV=("DR_STATE=$W/ro/state"); mode d2 rc=0; mode d3 rc=0; mode d4 rc=0
  mkstate "$W/ro/state" $((T0 - 4000)) $((T0 - 4000)) $((T0 - 4000))
  chmod 555 "$W/ro"
  tick 2900 0 $((T0 + 120))
  eq "$(ncallall),$RC,$(grep -c -F 'NÃO chamado: não consegui gravar a marca' "$LOG" 2>/dev/null)" "0,30,1" "D2, D3 e D4 vencidos e estado não gravável: nenhum chamado, saída 30, e a rodada acaba no 1º degrau (1 linha, não 1 por degrau)"
  chmod 755 "$W/ro"

  reset; mkdir -p "$W/ro"; XENV=("DR_STATE=$W/ro/state"); mode d4 rc=0
  tick 1400 0 "$T0"
  chmod 555 "$W/ro"
  tick 1400 0 $((T0 + 120))
  eq "$(ncall d4 --run),$RC" "0,30" "piso duro vencido (2 leituras < 1,5 GB) e estado não gravável: D4 NÃO foi chamado, saída 30"
  chmod 755 "$W/ro"
  tick 1400 0 $((T0 + 240))
  eq "$(ncall d4 --run)" 1 "…gravável de novo: o D4 é chamado"
  eq "$(sed -n 's/^acted4_ts=//p' "$W/ro/state" | head -n 1)" $((T0 + 240)) "…com a marca do reinício gravada"
fi

section "kill switch e dry-run"
reset; walk 5000 0 "$T0" $((T0 + 800)) 100
cp "$STATE" "$W/state.before"; cp "$LOG" "$W/log.before"
: > "$SD/notify.log"; : > "$SD/mail.log"
setfree 5000; setswap 0; printf '%s' $((T0 + 900)) > "$W/now"; runl --dry-run
eq "$RC,$(ncall d2 --dry-run),$(ncall d2 --run)" "0,1,0" "dry-run: rodada 0, D2 chamado com --dry-run e NUNCA com --run"
cmp -s "$STATE" "$W/state.before" && cmp -s "$LOG" "$W/log.before" && ok "dry-run: estado e log intactos" || nope "dry-run mexeu no estado ou no log"
eq "$(nnotify p=)$(nmail to=)" 00 "dry-run: nada de notify/mail"
has "$OUT" "[dry-run]" "dry-run: mostra o que faria"
reset; setfree 5000; setswap 0; runl --dry-run
[ ! -e "$STATE" ] && ok "dry-run sem estado: não cria arquivo" || nope "dry-run criou estado"
reset; printf 'lixo' > "$STATE"; runl --dry-run
[ -e "$STATE" ] && [ -z "$(ls "$STATE".corrupt-* 2>/dev/null)" ] && ok "dry-run: não move estado corrompido" || nope "dry-run mexeu no estado corrompido"
reset; touch "$OFF"; runl --dry-run; eq "$RC" 10 "dry-run respeita o kill switch"

section "trava de instância única"
reset; walk 5000 0 "$T0" $((T0 + 800)) 100; mode d2 rc=10 slp=3
printf '%s' 5000 > "$W/free"; printf '%s' 0 > "$W/swap"; printf '%s' $((T0 + 900)) > "$W/now"
( env -i "${BASE[@]}" /bin/bash "$LADDER" --run > "$W/first.out" 2>&1 ) &
bgpid=$!
i=0; while [ ! -s "$SD/calls" ] || ! grep -q '^d2 --run$' "$SD/calls"; do sleep 0.2; i=$((i+1)); [ "$i" -gt 40 ] && break; done
runl --run
eq "$RC" 10 "segunda instância enquanto a primeira roda → 10"
has "$(logtxt)" "outra instância" "…e diz no log"
runl --dry-run; eq "$RC" 0 "dry-run não toma a trava"
wait "$bgpid"
[ ! -d "$LOCK" ] && ok "primeira instância liberou a trava" || nope "trava sobrou"
reset; mkdir "$LOCK"; ( : ) & dead=$!; wait "$dead"; echo "$dead" > "$LOCK/pid"
tick 20000 0 "$T0"; eq "$RC" 0 "trava de pid morto é refeita"
reset; sleep 30 & other=$!; mkdir "$LOCK"; echo "$other" > "$LOCK/pid"
tick 20000 0 "$T0"; eq "$RC" 0 "trava com pid vivo que NÃO é o maestro (pid reaproveitado) é refeita"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
reset; mkdir -p "$W/psbin"; printf '#!/bin/bash\nexit 1\n' > "$W/psbin/ps"; chmod 755 "$W/psbin/ps"
sleep 30 & other=$!; mkdir "$LOCK"; echo "$other" > "$LOCK/pid"; XENV=("PATH=$W/psbin:$PATH")
tick 20000 0 "$T0"; eq "$RC" 10 "trava com pid VIVO e ps sem resposta → na dúvida a outra instância é a dona (10), a trava não é roubada"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
reset; mkdir "$LOCK"; tick 20000 0 "$T0"; eq "$RC" 10 "trava sem pid e recém-criada → ocupada (10)"
touch -t 200001010000 "$LOCK"; tick 20000 0 "$T0"; eq "$RC" 0 "trava sem pid e velha (> 1 min) é refeita"

section "configuração inválida cai no padrão e diz"
reset; XENV=(DR_D2_HOLD_S=abc DR_HYST_MB=99999999999 DR_D4_HOLD_S=-1)
walk 5000 0 "$T0" $((T0 + 600)) 300
eq "$(ncallall)" 0 "DR_D2_HOLD_S=abc: usou 900 (não 0): nada chamado aos 600 s"
has "$(logtxt)" "DR_D2_HOLD_S='abc'->900" "…e o log diz que caiu no padrão"
has "$(logtxt)" "DR_HYST_MB='99999999999'->512" "número comprido demais também cai no padrão"
has "$(logtxt)" "DR_D4_HOLD_S='-1'->3600" "número negativo também"

section "notify e mail com defeito não derrubam a rodada"
reset; echo fail > "$SD/notify.mode"; echo fail > "$SD/mail.mode"
walk 5000 0 "$T0" $((T0 + 900)) 100
eq "$RC,$(sv st2)" "0,acted" "notify e mail falhando: o degrau agiu, rodada 0, marca acted"
has "$(logtxt)" "WARN: notify rc=1" "notify falhou: WARN no log"
has "$(logtxt)" "WARN: gc mail send mayor rc=1" "mail falhou: WARN no log"
reset; XENV=("DR_GC_BIN=$W/sem-gc")
walk 5000 0 "$T0" $((T0 + 900)) 100
has "$(logtxt)" "WARN: gc mail send mayor rc=127" "gc ausente: WARN rc=127, sem travar"
reset; XENV=(DR_NOTIFY_TIMEOUT_S=1); echo hang > "$SD/notify.mode"
walk 5000 0 "$T0" $((T0 + 800)) 100
SECONDS=0; tick 5000 0 $((T0 + 900)); el=$SECONDS
[ "$el" -le 25 ] && ok "notify travado é cortado (${el}s)" || nope "notify travado segurou a rodada ${el}s"
has "$(logtxt)" "WARN: notify rc=124" "notify travado: rc=124 no log"
reset; XENV=("TMPDIR=$W/nao/existe")
walk 5000 0 "$T0" $((T0 + 900)) 100
eq "$(sv st2)" unknown "sem mktemp: o degrau fica unknown (não 'agiu')"

section "rotação do log"
reset; head -c 5000 /dev/zero | tr '\0' 'x' > "$LOG"; XENV=(DR_LOG_MAX_KB=1)
tick 20000 0 "$T0"
[ -f "$LOG.1" ] && ok "log acima do limite foi girado para .1" || nope "log não girou"

section "leitor real: df do volume Data (nunca o /) e swap"
BASE_FULL=("${BASE[@]}")
BASE=( "PATH=$W/bin:/usr/bin:/bin:/usr/sbin:/sbin" "HOME=$W/home" "TMPDIR=$W/tmp" "STUB_DIR=$SD"
  "DR_CITY=$CITY" "DR_STATE=$STATE" "DR_LOG=$LOG" "DR_OFF_FILE=$OFF" "DR_LOCK=$LOCK" "DR_NOW_FILE=$W/now"
  "DR_D2_CMD=$W/stubs/d2" "DR_D3_CMD=$W/stubs/d3" "DR_D4_CMD=$W/stubs/d4" "DR_NOTIFY_BIN=$W/stubs/notify" "DR_GC_BIN=$W/stubs/gc" )
real() { [ -f "$SD/df.args" ] && cat "$SD/df.args" >> "$W/df.all"; reset; XENV=("STUB_DF_MODE=$1" "STUB_SYSCTL_MODE=$2"); printf '%s' "$T0" > "$W/now"; runl --dry-run; }
real ok ok;      eq "$RC" 0 "df e sysctl legíveis → 0"; has "$OUT" "livre=4096MB swap=1536MB" "df Available e swap em uso (M) lidos"
real ok gig;     has "$OUT" "swap=2560MB" "swap em G convertido para MB"
for m in root fail empty garbage big; do real "$m" ok; eq "$RC" 30 "df '$m' → 30"; has "$OUT" "df de /System/Volumes/Data ilegível" "df '$m': diz"; done
for m in fail garbage kilo noused empty; do real ok "$m"; eq "$RC" 30 "sysctl '$m' → 30"; has "$OUT" "swap (vm.swapusage) ilegível" "sysctl '$m': diz"; done
cat "$SD/df.args" >> "$W/df.all"
bad=$(grep -v -x -- '-Pm /System/Volumes/Data' "$W/df.all" | head -n 1)
[ -s "$W/df.all" ] && [ -z "$bad" ] && ok "df chamado SEMPRE com -Pm /System/Volumes/Data (nunca df /)" || nope "df chamado de outro jeito: '$bad'"
BASE=("${BASE_FULL[@]}")

section "nada vazou"
[ -z "$(ls "$W/tmp" 2>/dev/null)" ] && ok "nenhum temporário sobrou em TMPDIR" || nope "temporários sobraram: $(ls "$W/tmp")"

printf '\n%s passaram, %s falharam\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
