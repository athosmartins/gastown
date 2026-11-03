#!/usr/bin/env bash
# disk-recovery-ladder.selftest.sh — testa o maestro da escada de recuperação de disco (ga-1p1i5jr.1) SEM tocar na máquina.
#
# O QUE É SIMULADO  df, swap e relógio (arquivos `DR_FREE_MB_FILE` / `DR_SWAP_MB_FILE` / `DR_NOW_FILE`: cada "rodada" do launchd é uma chamada com a hora que o teste escolhe, então 6 h de reinício
#   passam em segundos), os degraus D2/D3/D4 (stubs que registram a chamada e devolvem o rc que o teste manda), `notify` e `gc mail` (stubs que anotam a chamada e falham quando o teste manda; o `notify` imita os
#   códigos de política do de verdade quando recebe NOTIFY_STRICT_EXIT=1: 10 segurado, 11 dedup, 12 resumo/teto). Nada real é parado, reiniciado ou enviado. O trecho que lê o `df`/`sysctl` de verdade é testado
#   com shims no PATH (o `df` shim também prova que NUNCA se lê `df /`); `mv`, `ln` e `cp` com defeito entram do mesmo jeito, para provar que o arquivo de estado nunca fica sem existir.
# O QUE É VERIFICADO  uma seção por regra do maestro (títulos abaixo): fronteiras dos limiares, histerese, lacuna, ordem e um degrau por rodada, piso duro, teto de 6 h do D4, df ilegível = não age,
#   e "tentado ≠ entregue": nenhuma marca de "já avisei" é gravada sem um canal confirmar (notify e mail falhando → a rodada seguinte avisa de novo).
#   Gate-fix 3: (a) swap ilegível NÃO trava a escada (só entra no texto: segue com o df e DIZ "swap NÃO verificado"), o `sysctl` é chamado sempre com LC_ALL=C e a vírgula do pt_BR (launchd) é lida;
#   (b) a trava de instância única tem TRÊS estados: peguei / outra instância viva (10, calado) / não consegui tomar nem verificar (30 + aviso -p 4, no máx. 1/h, entregue-depois-carimbado).
#   Retomada do D2 (ga-1p1i5jr.6): o stub do D2 devolve rc 10 calado a cada `--resume` (o maestro o chama TODA rodada) e o teste manda 0/20/30/99/2/1/estouro/ausente/sem permissão; só o 10 é silêncio, a falha da CHAMADA é alerta,
#   o aviso sai no máx. 1 por hora por classe e a marca só depois de um canal confirmar; dry-run e saída antecipada não chamam o `--resume`. Mutantes (rc 20 ignorado etc.) em docs/runbooks/disco-escada-recuperacao.md.
#   As seções novas ficam logo no começo do arquivo: um mutante rodado com ST_FAILFAST=1 é pego em segundos, sem esperar o arquivo inteiro.
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
# degrau simulado. Modo em $STUB_DIR/mode.<nome>: linhas rc=N msg=... setfree=N setswap=MISSING (apaga o arquivo do swap: o swap só fica ilegível na re-medição que vem depois do degrau) slp=N killp=1 waitfor=ARQUIVO (espera o arquivo existir, no máx. 30 s: segura o degrau sem depender da velocidade da máquina)
n=$(basename "$0"); rc=0; msg="stub $n"; setfree=""; setswap=""; slp=0; killp=0; waitfor=""
# --resume (só o D2 tem): o maestro chama a CADA rodada, então o padrão é o rc 10 calado ("nada a retomar"); o teste manda outro em mode.<nome>.resume (rrc= rmsg='...' rslp=N, lido como shell: mensagem entre aspas).
# Não mexe em state_at_call.* nem em pid.* (são do --run) e só anota a chamada em `calls`.
if [ "${1:-}" = "--resume" ]; then
  rrc=10; rmsg="nada a retomar (stub)"; rslp=0
  [ -f "$STUB_DIR/mode.$n.resume" ] && . "$STUB_DIR/mode.$n.resume"
  echo "$n $1" >> "$STUB_DIR/calls"
  [ "$rslp" -gt 0 ] && sleep "$rslp"
  echo "$rmsg"
  exit "$rrc"
fi
[ -f "$STUB_DIR/mode.$n" ] && . "$STUB_DIR/mode.$n"
echo "$n $1" >> "$STUB_DIR/calls"
echo $$ > "$STUB_DIR/pid.$n"
cp "$DR_STATE" "$STUB_DIR/state_at_call.$n" 2>/dev/null
[ -n "$setfree" ] && printf '%s' "$setfree" > "$DR_FREE_MB_FILE"
[ "$setswap" = MISSING ] && rm -f "$DR_SWAP_MB_FILE"
[ "$killp" = 1 ] && kill -9 "$PPID"
[ "$slp" -gt 0 ] && sleep "$slp"
w=0; while [ -n "$waitfor" ] && [ ! -e "$waitfor" ] && [ "$w" -lt 300 ]; do sleep 0.1; w=$((w+1)); done
echo "$msg"
exit "$rc"
STUB
  chmod 755 "$W/stubs/$n"
done
cat > "$W/stubs/notify" <<'STUB'
#!/bin/bash
p=""; t=""
while [ $# -gt 1 ]; do case "$1" in -p) p=$2; shift 2 ;; -t) t=$2; shift 2 ;; *) shift ;; esac; done
echo "p=$p force=${NOTIFY_FORCE_PUSH:-} t=$t msg=$1 strict=${NOTIFY_STRICT_EXIT:-}" >> "$STUB_DIR/notify.log"
# strict=N = como o notify de verdade (scripts/notify, policy_exit): sem NOTIFY_STRICT_EXIT sai 0 em todo caminho que não empurrou (resumo, dedup, segurado até as 7h); com ele sai N (10 segurado, 11 dedup, 12 resumo/teto, ...)
m=$(cat "$STUB_DIR/notify.mode" 2>/dev/null)
case "$m" in fail) echo "boom"; exit 1 ;; hang) sleep 30 ;; strict=*) [ "${NOTIFY_STRICT_EXIT:-}" = 1 ] && { echo "policy"; exit "${m#strict=}"; } ;; esac
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
echo "LC_ALL=${LC_ALL:-unset}" >> "$STUB_DIR/sysctl.env"     # com que LC_ALL o maestro chamou (o sysctl de verdade muda o decimal com ele)
case "${STUB_SYSCTL_MODE:-ok}" in
  ok)      echo "total = 2048.00M  used = 1536.25M  free = 511.75M  (encrypted)" ;;
  gig)     echo "total = 4096.00M  used = 2.50G  free = 1.50G  (encrypted)" ;;
  comma)   echo "total = 2048,00M  used = 1536,25M  free = 511,75M  (encrypted)" ;;      # o que o mini imprime sob o launchd (pt_BR): 'used = 3015,31M' (scripts/rea-run.sh:71)
  commagig) echo "total = 4096,00M  used = 2,50G  free = 1,50G  (encrypted)" ;;
  locale)  case "${LC_ALL:-}" in C) echo "total = 2048.00M  used = 1536.25M  free = 511.75M  (encrypted)" ;; *) echo "total = 2048,00M  used = 1536,25M  free = 511,75M  (encrypted)" ;; esac ;;   # como o real: ponto só com LC_ALL=C
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
ncallall() { local n; n=$(grep -v -x -F 'd2 --resume' "$SD/calls" 2>/dev/null | grep -c .); echo "${n:-0}"; }   # chamadas de --run/--dry-run; o --resume (toda rodada) conta à parte em nresume
nresume() { local n; n=$(grep -c -x -F 'd2 --resume' "$SD/calls" 2>/dev/null); echo "${n:-0}"; }
rmode() { printf '%s\n' "$@" > "$SD/mode.d2.resume"; }   # o que o D2 --resume devolve: rmode rrc=20 "rmsg='...'"
nnotify() { local n; n=$(grep -c -F -- "$1" "$SD/notify.log" 2>/dev/null); echo "${n:-0}"; }
nmail()   { local n; n=$(grep -c -F -- "$1" "$SD/mail.log" 2>/dev/null); echo "${n:-0}"; }
sv()  { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -n 1; }
logtxt() { cat "$LOG" 2>/dev/null; }
mkstate() {  # arquivo since2 since3 since4 [acted4_ts] [hard_n]: estado COMPLETO (todas as chaves do save_state) escrito à mão; última leitura = T0, sem lacuna
  printf 'v=1\nlast_ts=%s\nlast_free_mb=2900\nlast_swap_mb=0\nhard_n=%s\nhard_ts=0\nacted4_ts=%s\nesc4=0\nwarn_ts=0\nhb_ts=%s\nsince2=%s\nsince3=%s\nsince4=%s\nst2=none\nst3=none\nst4=none\nat2=0\nat3=0\nat4=0\nnt2=0\nnt3=0\nnt4=0\nut2=0\nut3=0\nut4=0\n' \
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

# ── retomada do D2 (ga-1p1i5jr.6): o maestro chama `d2 --resume` TODA rodada, depois do --run ──────────────────────────────────────────────────────
# Sem este chamador o job que o D2 parou só recomeça do zero no tick das 00:15. O stub devolve rc 10 calado por padrão (rmode manda outro). Seções logo no começo: um mutante é pego em segundos com ST_FAILFAST=1.
RM20="$CITY/.gc/disk-recovery.resume-rc20"; RM30="$CITY/.gc/disk-recovery.resume-rc30"; RMB="$CITY/.gc/disk-recovery.resume-broken"
RN0='p=3 force= t=Disco: D2 retomou o job'
RN20='p=4 force=1 t=Disco: a retomada do D2 FALHOU'
RN30='p=4 force=1 t=Disco: D2 não leu o estado da retomada'
RNB='p=4 force=1 t=Disco: a retomada do D2 falhou na chamada'
RNA='p=4 force=1 t=Disco: não consigo chamar a retomada do D2'
nmarks() { ls "$CITY/.gc" 2>/dev/null | grep -c '^disk-recovery\.resume-'; }   # marcas de 1 h da retomada (vazio/ilegível → 0, que é o lado que AVISA)

section "retomada do D2 (--resume): chamada a cada rodada, DEPOIS do --run; só o rc 10 é silêncio"
reset; tick 20000 0 "$T0"
eq "$RC,$(nresume)" "0,1" "disco folgado, escada em repouso: o --resume é chamado mesmo assim (1 vez por rodada)"
eq "$(nnotify p=),$(nmail to=),$(nmarks)" "0,0,0" "rc 10 (nada a retomar): silêncio — nenhum aviso, nenhum mail, nenhuma marca"
hasnt "$(logtxt)" "retomada do D2" "rc 10: nem uma linha no log do maestro (rodada a cada 2 min)"
tick 20000 0 $((T0 + 120)); eq "$(nresume)" 2 "…e de novo na rodada seguinte"
reset; tick 5000 0 "$T0"; tick 5000 0 $((T0 + 450)); tick 5000 0 $((T0 + 900))
eq "$(tail -n 2 "$SD/calls" | tr '\n' ',')" "d2 --run,d2 --resume," "escada em degrau: o --run vai primeiro e o --resume depois, na MESMA rodada"
reset; rmode rrc=0 "rmsg='retomou rfb --resume-run 1700000000-4242: de pé depois de 25s'"
tick 20000 0 "$T0"
eq "$RC,$(nnotify "$RN0"),$(nmail to=)" "0,1,0" "rc 0 (retomou): saída 0, 1 notify -p 3 'retomou' sem push forçado, sem mail"
has "$(cat "$SD/notify.log")" "1700000000-4242" "rc 0: a linha do D2 (com o run_id) vai na mensagem"
has "$(logtxt)" "retomada do D2: rc=0" "rc 0: o log diz"
eq "$(nmarks)" 0 "rc 0: sem marca de 1 h (quem impede repetir é o registro do próprio D2)"
reset; rmode rrc=20 "rmsg='retomada --resume-run 1700000000-4242 saiu com rc 3 antes de 25s (retome à mão com o run_id)'"
tick 20000 0 "$T0"
eq "$RC,$(nnotify "$RN20"),$(nmail 'subj=Disco: a retomada do D2 FALHOU')" "20,1,1" "rc 20 (não subiu): saída 20, 1 notify -p 4 FORÇADO + 1 mail ao Mayor"
has "$(cat "$SD/notify.log")" "1700000000-4242" "rc 20: o run_id vai no alerta (para retomar à mão)"
eq "$(cat "$RM20" 2>/dev/null)" "$T0" "rc 20: a marca de 1 h guarda a hora do aviso entregue"
tick 20000 0 $((T0 + 120))
eq "$RC,$(nnotify "$RN20"),$(nmail 'subj=Disco: a retomada do D2 FALHOU')" "20,1,1" "rc 20 2 min depois: segue saída 20 mas SÓ log (no máx. 1 aviso e 1 mail por hora)"
has "$(logtxt)" "só log" "…e o log diz que calou"
tick 20000 0 $((T0 + 3599)); eq "$(nnotify "$RN20")" 1 "rc 20 aos 3599 s do aviso: ainda calado"
tick 20000 0 $((T0 + 3600)); eq "$(nnotify "$RN20"),$(nmail 'subj=Disco: a retomada do D2 FALHOU')" "2,2" "rc 20 aos 3600 s: avisa de novo (notify e mail)"
reset; rmode rrc=30 "rmsg='não consegui ler o registro /x; não ajo'"
tick 20000 0 "$T0"
eq "$RC,$(nnotify "$RN30"),$(nmail to=)" "30,1,0" "rc 30 (não li o estado): saída 30, 1 notify -p 4 forçado, sem mail"
has "$(cat "$SD/notify.log")" "não consegui ler o estado" "rc 30: o alerta diz 'não consegui ler o estado'"
tick 20000 0 $((T0 + 120)); eq "$(nnotify "$RN30")" 1 "rc 30 de novo 2 min depois: só log (1 por hora)"
tick 20000 0 $((T0 + 3600)); eq "$(nnotify "$RN30")" 2 "rc 30 aos 3600 s: avisa de novo"

section "retomada do D2: falha da CHAMADA é ALERTA, nunca o silêncio do rc 10 (ausente, sem permissão, rc 99, rc 2, estouro de prazo)"
reset; XENV=("DR_D2_CMD=$W/nao-existe"); tick 20000 0 "$T0"
eq "$RC,$(nnotify "$RNA")" "0,1" "D2 ausente: 1 aviso -p 4 forçado (não é silêncio); a saída não muda, como no degrau ausente"
has "$OUT" "retomada do D2 NÃO chamada" "D2 ausente: diz no stdout/log"
eq "$(cat "$RMB" 2>/dev/null)" "$T0" "D2 ausente: marca de 1 h da classe broken"
tick 20000 0 $((T0 + 120)); eq "$RC,$(nnotify "$RNA")" "0,1" "D2 ausente 2 min depois: aviso calado (1 por hora)"
tick 20000 0 $((T0 + 3600)); eq "$(nnotify "$RNA")" 2 "D2 ausente aos 3600 s: avisa de novo"
reset; XENV=("DR_D2_CMD=$W/stubs/noexec"); tick 20000 0 "$T0"
eq "$RC,$(nnotify "$RNA")" "0,1" "D2 sem permissão de execução: mesmo alerta"
for code in 99 2 1; do
  reset; rmode "rrc=$code" "rmsg='saí com $code'"; tick 20000 0 "$T0"
  eq "$RC,$(nnotify "$RNB")" "20,1" "rc $code (fora de 0/10/20/30): alerta -p 4 forçado, nunca tratado como rc 10"
  has "$(cat "$SD/notify.log")" "rc inesperado $code" "rc $code: o alerta diz o rc"
done
reset; XENV=(DR_RESUME_TIMEOUT_S=1); rmode rrc=0 rslp=30 "rmsg='retomou'"
SECONDS=0; tick 20000 0 "$T0"; el=$SECONDS
[ "$el" -le 25 ] && ok "estouro: prazo do --resume limitado (${el}s para um D2 de 30 s e limite 1 s)" || nope "demorou ${el}s"
eq "$RC,$(nnotify "$RNB"),$(nnotify "$RN0")" "20,1,0" "estourou o prazo: alerta de chamada (e NÃO o 'retomou' que o D2 diria se acabasse)"
has "$(cat "$SD/notify.log")" "estourou 1s" "estouro: o alerta diz"
[ -z "$(ls "$W/tmp" 2>/dev/null)" ] && ok "estouro não deixa temporário para trás" || nope "temporários sobraram: $(ls "$W/tmp")"
reset; XENV=("DR_D2_CMD=$W/nao-existe"); tick 20000 0 "$T0"; XENV=(); rmode rrc=20 "rmsg='x'"; tick 20000 0 $((T0 + 120))
eq "$(nnotify "$RNA"),$(nnotify "$RN20")" "1,1" "a marca de 1 h é POR CLASSE: o alerta de chamada não cala o rc 20 que vem logo depois"

section "retomada do D2: tentado ≠ entregue — a marca de 1 h só com algum canal confirmando; marca ilegível não cala"
reset; rmode rrc=20 "rmsg='x'"; echo fail > "$SD/notify.mode"; echo fail > "$SD/mail.mode"
tick 20000 0 "$T0"
eq "$RC,$(nnotify "$RN20"),$(nmail 'subj=Disco: a retomada do D2 FALHOU')" "20,1,1" "rc 20 com notify e mail falhando: tentou os dois"
[ ! -e "$RM20" ] && ok "…e a marca NÃO é gravada" || nope "marca gravada sem nenhum canal confirmar"
has "$(logtxt)" "NÃO entregue" "…e o log diz"
rm -f "$SD/notify.mode" "$SD/mail.mode"; tick 20000 0 $((T0 + 120))
eq "$(nnotify "$RN20"),$([ -e "$RM20" ] && echo marca || echo sem)" "2,marca" "…canais de volta: a rodada seguinte avisa e só então grava a marca"
reset; rmode rrc=20 "rmsg='x'"; echo fail > "$SD/notify.mode"; tick 20000 0 "$T0"
eq "$([ -e "$RM20" ] && echo marca || echo sem)" "marca" "rc 20 com o notify falhando mas o mail confirmando: a marca vale (algum canal entregou)"
reset; XENV=("DR_D2_CMD=$W/nao-existe"); echo fail > "$SD/notify.mode"; tick 20000 0 "$T0"
eq "$([ -e "$RMB" ] && echo marca || echo sem)" "sem" "alerta de chamada (só notify) com o notify falhando: sem marca"
rm -f "$SD/notify.mode"; tick 20000 0 $((T0 + 120))
eq "$(nnotify "$RNA"),$([ -e "$RMB" ] && echo marca || echo sem)" "2,marca" "…notify de volta: avisa na rodada seguinte e grava a marca"
for junk in lixo "" "$((T0 + 99999))"; do
  reset; rmode rrc=20 "rmsg='x'"; printf '%s\n' "$junk" > "$RM20"; tick 20000 0 "$T0"
  eq "$(nnotify "$RN20")" 1 "marca '$junk' (lixo, vazia ou no FUTURO): não cala o aviso"
done
reset; rmode rrc=20 "rmsg='x'"; printf '%s\n' "$((T0 - 100))" > "$RM20"; tick 20000 0 "$T0"
eq "$(nnotify "$RN20")" 0 "marca de 100 s atrás: calado (a janela é de 1 h)"
# marca que a LEITURA falha (um diretório no lugar do arquivo: o cat sai com erro, até como root): o aviso sai, e segue saindo a cada rodada, nunca cala
reset; rmode rrc=20 "rmsg='x'"; mkdir -p "$RM20"; tick 20000 0 "$T0"
eq "$RC,$(nnotify "$RN20")" "20,1" "marca ilegível (cat falha: é um diretório): o aviso sai, não é tratado como 'avisei há pouco'"
tick 20000 0 $((T0 + 120)); eq "$(nnotify "$RN20")" 2 "…e na rodada seguinte sai de novo (marca ilegível nunca cala)"

section "retomada do D2: dry-run e saídas antecipadas NÃO chamam o --resume (sem leitura nenhuma, nada age)"
reset; rmode rrc=0 "rmsg='retomou'"; setfree 20000; setswap 0; printf '%s' "$T0" > "$W/now"; runl --dry-run
eq "$RC,$(nresume),$(nnotify p=)" "0,0,0" "dry-run: o --resume NÃO é chamado (não tem modo dry-run) e nada é avisado"
has "$OUT" "não tem modo dry-run" "dry-run: diz por que não chamou"
reset; rmode rrc=0 "rmsg='retomou'"; touch "$OFF"; tick 20000 0 "$T0"
eq "$RC,$(nresume)" "10,0" "interruptor ligado: não chama o --resume"
reset; rmode rrc=0 "rmsg='retomou'"; : > "$LOCK"; tick 20000 0 "$T0"
eq "$RC,$(nresume)" "30,0" "trava que não consigo tomar: não chama o --resume"
reset; rmode rrc=0 "rmsg='retomou'"; tick MISSING 0 "$T0"
eq "$RC,$(nresume)" "30,0" "df ilegível: não chama o --resume"

section "interruptor"
reset; touch "$OFF"; tick MISSING MISSING "$T0"
eq "$RC" 10 "interruptor ligado → 10 sem nem ler o df"
eq "$(nnotify p=)" 0 "interruptor: df ilegível NÃO avisou (nem leu)"
[ ! -e "$STATE" ] && ok "interruptor: nenhum estado gravado" || nope "interruptor: gravou estado"
has "$OUT" "interruptor ligado" "interruptor: diz no stdout/log"
rm -f "$OFF"; tick 20000 0 "$T0"; eq "$RC" 0 "interruptor desligado: volta a rodar"

section "trava que não consigo tomar nem verificar: TERCEIRO ESTADO (gate-fix 3) — saída 30 + aviso, nunca 'outra instância' calada"
# Antes: o mkdir falhava por um motivo que não era "já existe" (diretório sem escrita, disco sem espaço, um arquivo no lugar), o `cat pid` vinha vazio, o `find` não achava a pasta e a rodada saía 10, calada,
# culpando uma 2ª instância que não existe: a escada morta e muda, sem o alarme que o estado não gravável já tem. Agora é rc 2 do acquire_lock → WARN + notify -p 4 (1 por hora, entregue) + saída 30.
NL='p=4 force=1 t=Disco: a escada não consegue tomar a trava'
NOLOCK="$CITY/.gc/disk-recovery.nolock"
reset; : > "$LOCK"; tick 20000 0 "$T0"
eq "$RC,$(nnotify "$NL")" "30,1" "um ARQUIVO no lugar da trava (o mkdir falha e não há diretório) → 30 e 1 aviso -p 4 forçado, não 10 calado"
has "$OUT" "não consegui tomar nem verificar a trava" "…WARN no stdout"
has "$(logtxt)" "mkdir $LOCK falhou e a trava não existe" "…e o log diz o motivo"
eq "$(ncallall)" 0 "…sem chamar degrau"
[ ! -e "$STATE" ] && ok "…e sem ler nem gravar o estado (a rodada nem começou)" || nope "gravou estado sem ter a trava"
setfree 20000; setswap 0; printf '%s' "$T0" > "$W/now"; runl --dry-run
eq "$RC" 0 "dry-run não toma a trava: roda do mesmo jeito com ela inviável"
tick 20000 0 $((T0 + 120))
eq "$(nnotify "$NL")" 1 "…no máximo 1 por hora (2ª rodada calada)"
touch -t 200001010000 "$NOLOCK"; tick 20000 0 $((T0 + 240))
eq "$(nnotify "$NL")" 2 "…e de novo depois de 1 h"
# tentado ≠ entregue: a marca de 1 h só é gravada depois que o notify CONFIRMOU
reset; : > "$LOCK"; echo fail > "$SD/notify.mode"; tick 20000 0 "$T0"
eq "$(nnotify "$NL")" 1 "trava inviável com o notify falhando: 1 tentativa"
[ ! -e "$NOLOCK" ] && ok "…e a marca de 1 h NÃO é gravada" || nope "marca gravada sem o notify confirmar"
rm -f "$SD/notify.mode"; tick 20000 0 $((T0 + 120))
eq "$(nnotify "$NL")" 2 "…notify de volta: a rodada seguinte avisa"
[ -e "$NOLOCK" ] && ok "…e só então grava a marca" || nope "marca não gravada depois da entrega"
for code in 10 11; do   # STRICT: 10 segurado até as 7h e 11 dedup = o aviso está garantido (mesma leitura do resto do maestro)
  reset; : > "$LOCK"; echo "strict=$code" > "$SD/notify.mode"; tick 20000 0 "$T0"; tick 20000 0 $((T0 + 120))
  eq "$(nnotify "$NL"),$([ -e "$NOLOCK" ] && echo marca || echo sem)" "1,marca" "notify rc=$code com STRICT (segurado até as 7h / dedup): conta como entregue, a marca é gravada e a rodada seguinte não repete"
done
reset; : > "$LOCK"; echo "strict=12" > "$SD/notify.mode"; tick 20000 0 "$T0"; tick 20000 0 $((T0 + 120))
eq "$(nnotify "$NL"),$([ -e "$NOLOCK" ] && echo marca || echo sem)" "2,sem" "notify rc=12 com STRICT (resumo mudo, nada saiu): NÃO é entrega, sem marca, repete na rodada seguinte"
# 2ª tentativa do mkdir: a outra instância pode soltar a trava entre o nosso mkdir (falhou) e o teste "existe?"; isso NÃO é terceiro estado
mkdir -p "$W/mkbin2"
printf '#!/bin/bash\ncase "$*" in *disk-recovery.lock) [ -e "$STUB_DIR/mk.once" ] || { : > "$STUB_DIR/mk.once"; exit 1; } ;; esac\nexec /bin/mkdir "$@"\n' > "$W/mkbin2/mkdir"; chmod 755 "$W/mkbin2/mkdir"
reset; XENV=("PATH=$W/mkbin2:$PATH"); tick 20000 0 "$T0"
eq "$RC,$(nnotify "$NL")" "0,0" "o 1º mkdir falha sem haver trava (a outra instância soltou no meio) e o 2º passa: a rodada roda (0), sem alarme falso"
# instância VIVA com a trava há mais de LOCK_MAX_MIN: presa (df pendurado num disco doente, pid reaproveitado por um editor que tem o nome do script). Calar para sempre (10) é a escada morta e muda
mkdir -p "$W/psbin2"; printf '#!/bin/bash\necho "/bin/bash /x/disk-recovery-ladder.sh --run"\n' > "$W/psbin2/ps"; chmod 755 "$W/psbin2/ps"
reset; sleep 30 & other=$!; mkdir "$LOCK"; echo "$other" > "$LOCK/pid"; XENV=("PATH=$W/psbin2:$PATH")
tick 20000 0 "$T0"
eq "$RC,$(nnotify "$NL")" "10,0" "dono VIVO (ps lê o maestro) com a trava há < 60 min → 10 calado: é o caso normal, sem aviso"
touch -t 200001010000 "$LOCK"; tick 20000 0 $((T0 + 120))
eq "$RC,$(nnotify "$NL")" "30,1" "dono vivo com a trava há > 60 min → 30 e 1 aviso (instância presa)"
has "$(logtxt)" "tem a trava há mais de 60 min" "…o log diz que a instância está presa"
[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$other" ] && ok "…e a trava do processo vivo fica intacta (aviso, não roubo)" || nope "a trava de um processo vivo foi mexida"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
reset; XENV=(DR_LOCK_MAX_MIN=0); tick 20000 0 "$T0"
has "$(logtxt)" "DR_LOCK_MAX_MIN='0'->60" "DR_LOCK_MAX_MIN=0 (abaixo do mínimo, 1: toda trava viva viraria 'presa') cai no padrão e o log diz"
if [ "$(id -u)" != 0 ]; then
  reset; mkdir -p "$W/ro"; chmod 555 "$W/ro"; XENV=("DR_LOCK=$W/ro/lock")
  tick 20000 0 "$T0"
  eq "$RC,$(nnotify "$NL"),$(ncallall)" "30,1,0" "diretório da trava SEM ESCRITA (a sonda do revisor: antes saía 10 calado) → 30, 1 aviso e nenhum degrau"
  chmod 755 "$W/ro"
  # o mkdir passa, mas a trava nasce sem permissão de escrita e o pid não grava (shim de mkdir)
  mkdir -p "$W/mkbin"
  printf '#!/bin/bash\n/bin/mkdir "$@" || exit $?\nfor a in "$@"; do case "$a" in */disk-recovery.lock) chmod 555 "$a" ;; esac; done\n' > "$W/mkbin/mkdir"; chmod 755 "$W/mkbin/mkdir"
  reset; XENV=("PATH=$W/mkbin:$PATH"); tick 20000 0 "$T0"
  eq "$RC,$(nnotify "$NL")" "30,1" "mkdir passou mas o pid não grava → 30 e 1 aviso"
  has "$(logtxt)" "não consegui gravar o pid" "…o log diz"
  [ ! -d "$LOCK" ] && ok "…e a trava sem dono foi desfeita (senão a rodada seguinte ficaria 'ocupada' por 1 min)" || nope "a trava sem pid sobrou"
  XENV=(); tick 20000 0 $((T0 + 120)); eq "$RC" 0 "…sem o defeito a rodada seguinte roda normal"
  # trava velha (pid morto) que não sai: diretório pai sem escrita (o rmdir falha) e, em outro arranjo, o próprio diretório da trava sem escrita (o rm do pid falha)
  ( : ) & dead=$!; wait "$dead"
  reset; mkdir -p "$W/ro/lock"; echo "$dead" > "$W/ro/lock/pid"; chmod 555 "$W/ro"; XENV=("DR_LOCK=$W/ro/lock")
  tick 20000 0 "$T0"
  eq "$RC,$(nnotify "$NL")" "30,1" "trava VELHA (pid morto) que não sai porque o diretório pai não deixa remover → 30 e 1 aviso (não 'ocupada')"
  has "$(logtxt)" "que não consegui remover" "…o log diz"
  chmod 755 "$W/ro"
  reset; mkdir -p "$W/ro/lock"; echo "$dead" > "$W/ro/lock/pid"; chmod 555 "$W/ro/lock"; XENV=("DR_LOCK=$W/ro/lock")
  tick 20000 0 "$T0"
  eq "$RC,$(nnotify "$NL")" "30,1" "trava velha cujo pid não consigo apagar (o laço de 2 tentativas acaba com a trava ainda lá) → 30 e 1 aviso"
  chmod 755 "$W/ro/lock"
  # estado: `-e` falso por erro de stat (sem permissão no diretório) NÃO é "primeira rodada" (acted4_ts=0 liga o reinício)
  reset; mkdir -p "$W/ro"; : > "$W/ro/state"; chmod 000 "$W/ro"; XENV=("DR_STATE=$W/ro/state")
  tick 20000 0 "$T0"
  has "$OUT" "estado salvo ilegível" "estado num diretório que não consigo pesquisar: tratado como ILEGÍVEL (acted4_ts = agora)"
  hasnt "$(logtxt)" "primeira rodada" "…e NÃO como 'primeira rodada' (acted4_ts=0, teto de 6 h perdido)"
  chmod 755 "$W/ro"
fi
# o pai do estado existe mas é um ARQUIVO (executável, para o `-x` sozinho não bastar): não há diretório de estado, então o `-e` falso não é "primeira rodada"
reset; : > "$W/notdir"; chmod 755 "$W/notdir"; XENV=("DR_STATE=$W/notdir/state")
tick 20000 0 "$T0"
has "$OUT" "estado salvo ilegível" "pai do estado é um arquivo (não um diretório): tratado como ILEGÍVEL (acted4_ts = agora)"
hasnt "$(logtxt)" "primeira rodada" "…e NÃO como 'primeira rodada'"

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
# gate-fix 2 (tentado ≠ entregue): o carimbo de "1 por hora" só vale depois que o notify CONFIRMOU; sem confirmação a rodada seguinte avisa de novo
reset; echo fail > "$SD/notify.mode"; tick MISSING 0 "$T0"
eq "$(nnotify 'p=4 force=1'),$(sv warn_ts)" "1,0" "df ilegível com o notify falhando: 1 tentativa e o carimbo de 1 h NÃO é gravado"
rm -f "$SD/notify.mode"; tick MISSING 0 $((T0 + 120))
eq "$(nnotify 'p=4 force=1'),$(sv warn_ts)" "2,$((T0 + 120))" "…notify de volta: a rodada seguinte avisa e só então grava o carimbo"
tick MISSING 0 $((T0 + 240))
eq "$(nnotify 'p=4 force=1')" 2 "…e depois fica calado (1 por hora)"
# carimbo no FUTURO (relógio que andou para trás): "agora - carimbo" negativo não pode calar o aviso
reset; tick 20000 0 "$T0"
sed 's/^warn_ts=0$/warn_ts=9999999999/' "$STATE" > "$STATE.x" && mv "$STATE.x" "$STATE"
tick MISSING 0 $((T0 + 120))
eq "$(nnotify 'p=4 force=1')" 1 "carimbo de aviso no FUTURO (relógio andou para trás): não cala o aviso de leitura impossível"

section "leitura ilegível: swap NÃO trava a escada (gate-fix 3: só texto, fail-open VISÍVEL)"
# O swap só entra no texto das mensagens: os limiares são de disco. Um swap que não leio não pode desligar a rede de segurança (o sysctl em vírgula do pt_BR fez exatamente isso: rodada recusada, 1 aviso por hora, nenhum degrau).
for bad in MISSING "" abc -1 2.5; do
  reset; walk 5000 777 "$T0" $((T0 + 800)) 100
  tick 5000 "$bad" $((T0 + 900))
  eq "$RC,$(ncall d2 --run)" "0,1" "swap='$bad': a rodada SEGUE (0) e o D2 É chamado no tempo dele (o swap não decide nada)"
  has "$(logtxt)" "swap NÃO verificado" "swap='$bad': o log diz que o swap não foi verificado"
  has "$(cat "$SD/notify.log")" "swap ? MB" "swap='$bad': o aviso do D2 diz 'swap ?' (não inventa 0)"
  eq "$(nnotify 'não consegue ler o disco')" 0 "swap='$bad': NÃO avisa 'a escada não consegue ler o disco' (o disco foi lido)"
  eq "$(sv last_swap_mb)" 777 "swap='$bad': o estado guarda o ÚLTIMO swap lido (777), não '?'"
  tick 5000 "$bad" $((T0 + 1000))
  hasnt "$OUT$(logtxt)" "estado salvo ilegível" "swap='$bad': a rodada seguinte lê o estado sem achar que está corrompido (o estado só guarda número)"
  tick 5000 9 $((T0 + 1100))
  eq "$(sv last_swap_mb)" 9 "swap='$bad': swap lido de volta → o estado passa a guardar o novo valor"
done
reset; walk 5000 0 "$T0" $((T0 + 800)) 100
tick MISSING 0 $((T0 + 900)); tick 5000 MISSING $((T0 + 1000))
eq "$(ncall d2 --run)" 1 "df ilegível numa rodada e swap ilegível na outra: o cronômetro do df seguiu (a lacuna não passou de 600 s)"
# a re-medição que vem DEPOIS de um degrau também lê o swap: se ele sumiu nesse momento, o log diz (o aviso do degrau segue com o livre novo) e o estado fica com o último swap lido
reset; mode d2 rc=0 setfree=9000 setswap=MISSING
walk 5000 0 "$T0" $((T0 + 900)) 100
has "$(logtxt)" "re-medição depois do D2: [swap NÃO verificado" "swap ilegível só na re-medição depois do D2: o log diz que não foi verificado"
eq "$(sv last_free_mb),$(sv last_swap_mb)" "9000,0" "…o estado guarda o livre da re-medição (9000) e o último swap LIDO (0), não '?'"
# o batimento de 1 h ('ok:') é a linha que o Athos lê com o disco folgado: com o swap ilegível ela diz que ele não foi verificado
reset; tick 20000 MISSING "$T0"
has "$(logtxt)" "ok: livre=20000MB swap=?MB (sem episódio; batimento 1/h) [swap NÃO verificado" "disco folgado e swap ilegível: o batimento diz swap=?MB e que o swap não foi verificado"

section "leitor real: df do volume Data (nunca o /) e swap, com LC_ALL=C e com a vírgula do pt_BR (gate-fix 3)"
# O mini roda a escada no launchd com LANG=pt_BR.UTF-8: o `sysctl vm.swapusage` imprime 'used = 3015,31M' (scripts/rea-run.sh:71). O leitor só aceitava ponto: a rodada era recusada e a escada nunca agia.
# Aqui os shims de df/sysctl no PATH (o resto dos testes injeta os números por arquivo); o shim 'locale' só dá ponto se for chamado com LC_ALL=C, como o sysctl de verdade.
BASE_FULL=("${BASE[@]}")
BASE=( "PATH=$W/bin:/usr/bin:/bin:/usr/sbin:/sbin" "HOME=$W/home" "TMPDIR=$W/tmp" "STUB_DIR=$SD"
  "DR_CITY=$CITY" "DR_STATE=$STATE" "DR_LOG=$LOG" "DR_OFF_FILE=$OFF" "DR_LOCK=$LOCK" "DR_NOW_FILE=$W/now"
  "DR_D2_CMD=$W/stubs/d2" "DR_D3_CMD=$W/stubs/d3" "DR_D4_CMD=$W/stubs/d4" "DR_NOTIFY_BIN=$W/stubs/notify" "DR_GC_BIN=$W/stubs/gc" )
rm -f "$W/df.all" "$W/sysctl.all"
real() {  # df-modo sysctl-modo [VAR=valor extra]: dry-run com os shims; acumula o que df/sysctl receberam (o reset apaga $SD)
  [ -f "$SD/df.args" ] && cat "$SD/df.args" >> "$W/df.all"; [ -f "$SD/sysctl.env" ] && cat "$SD/sysctl.env" >> "$W/sysctl.all"
  reset; XENV=("STUB_DF_MODE=$1" "STUB_SYSCTL_MODE=$2" ${3:+"$3"}); printf '%s' "$T0" > "$W/now"; runl --dry-run
}
real ok ok;      eq "$RC" 0 "df e sysctl legíveis → 0"; has "$OUT" "livre=4096MB swap=1536MB" "df Available e swap em uso (M) lidos"
real ok gig;     has "$OUT" "swap=2560MB" "swap em G convertido para MB"
real ok comma;   eq "$RC" 0 "sysctl com VÍRGULA decimal ('used = 1536,25M', o mini sob o launchd) → 0 (antes: recusava a rodada)"; has "$OUT" "livre=4096MB swap=1536MB" "…e lê 1536 MB"
real ok commagig; has "$OUT" "swap=2560MB" "'used = 2,50G' → 2560 MB"
real ok locale LC_ALL=pt_BR.UTF-8; has "$OUT" "swap=1536MB" "sysctl que só dá ponto com LC_ALL=C, com LC_ALL=pt_BR.UTF-8 herdado do launchd: o maestro chama com LC_ALL=C e lê 1536 MB"
real ok locale LANG=pt_BR.UTF-8;   has "$OUT" "swap=1536MB" "…idem com só LANG=pt_BR.UTF-8"
for m in root fail empty garbage big; do real "$m" ok; eq "$RC" 30 "df '$m' → 30"; has "$OUT" "df de /System/Volumes/Data ilegível" "df '$m': diz"; done
for m in fail garbage kilo noused empty; do   # o swap só entra no texto: ilegível NÃO recusa a rodada (o df, que decide, foi lido)
  real ok "$m"; eq "$RC" 0 "sysctl '$m' → 0: a escada segue com o df"; has "$OUT" "swap=?MB" "sysctl '$m': a leitura diz swap=?MB (não inventa 0)"; has "$OUT" "swap NÃO verificado" "sysctl '$m': diz que o swap não foi verificado"
  hasnt "$OUT" "leitura impossível" "sysctl '$m': sem WARN de leitura impossível (o disco foi lido)"
done
[ -f "$SD/df.args" ] && cat "$SD/df.args" >> "$W/df.all"; [ -f "$SD/sysctl.env" ] && cat "$SD/sysctl.env" >> "$W/sysctl.all"
bad=$(grep -v -x -- '-Pm /System/Volumes/Data' "$W/df.all" | head -n 1)
[ -s "$W/df.all" ] && [ -z "$bad" ] && ok "df chamado SEMPRE com -Pm /System/Volumes/Data (nunca df /)" || nope "df chamado de outro jeito: '$bad'"
bad=$(grep -v -x -- 'LC_ALL=C' "$W/sysctl.all" | head -n 1)
[ -s "$W/sysctl.all" ] && [ -z "$bad" ] && ok "sysctl chamado SEMPRE com LC_ALL=C (o decimal do locale não decide a leitura)" || nope "sysctl chamado sem LC_ALL=C: '$bad'"
BASE=("${BASE_FULL[@]}")

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

section "aviso que NINGUÉM recebeu não vira carimbo de 1 h (gate-fix 2: tentado ≠ entregue)"
reset; mode d2 rc=20; echo fail > "$SD/notify.mode"; echo fail > "$SD/mail.mode"
walk 5000 0 "$T0" $((T0 + 900)) 300
eq "$(nnotify 'p=4 force=1 t=Disco: degrau D2 FALHOU'),$(nmail 'D2 FALHOU'),$(sv nt2)" "1,1,0" "D2 FALHOU com notify e mail sem confirmação: 1 tentativa de cada, carimbo NÃO gravado"
has "$(logtxt)" "aviso de D2 FALHOU NÃO entregue" "…e o log diz que vai repetir"
rm -f "$SD/notify.mode" "$SD/mail.mode"
tick 5000 0 $((T0 + 1200))
eq "$(nnotify 'p=4 force=1 t=Disco: degrau D2 FALHOU'),$(nmail 'D2 FALHOU'),$(sv nt2)" "2,2,$((T0 + 1200))" "canais de volta: a chamada seguinte do D2 (5 min) avisa e só então grava o carimbo"
tick 5000 0 $((T0 + 1500))
eq "$(nnotify 'p=4 force=1 t=Disco: degrau D2 FALHOU'),$(nmail 'D2 FALHOU')" "2,2" "…entregue: calado de novo pela hora seguinte"
reset; mode d2 rc=0
walk 5000 0 "$T0" $((T0 + 900)) 300
mode d2 rc=20
walk 5000 0 $((T0 + 1400)) $((T0 + 2400)) 500; tick 5000 0 $((T0 + 2700))
eq "$(nnotify 'p=3 force= t=Disco: degrau D2 agiu'),$(nnotify 'p=4 force=1 t=Disco: degrau D2 FALHOU')" "1,1" "D2 agiu e 30 min depois FALHA: o aviso de FALHOU sai (o carimbo do 'agiu' não cala outra classe de aviso)"
reset; mode d2 rc=30; echo fail > "$SD/notify.mode"
walk 5000 0 "$T0" $((T0 + 900)) 300
eq "$(nnotify 'p=3 force= t=Disco: degrau D2 não leu'),$(sv ut2)" "1,0" "D2 não leu com o notify falhando: 1 tentativa e o carimbo de 1 h NÃO é gravado"
rm -f "$SD/notify.mode"; tick 5000 0 $((T0 + 1200))
eq "$(nnotify 'p=3 force= t=Disco: degrau D2 não leu'),$(sv ut2)" "2,$((T0 + 1200))" "…notify de volta: a chamada seguinte do D2 (5 min) avisa e só então grava o carimbo"
tick 5000 0 $((T0 + 1500))
eq "$(nnotify 'p=3 force= t=Disco: degrau D2 não leu')" 2 "…entregue: calado de novo pela hora seguinte"
reset; mode d2 rc=30; mode d3 rc=10; mode d4 rc=30
walk 2500 0 "$T0" $((T0 + 3600)) 300
eq "$(nnotify 'p=3 force= t=Disco: degrau D2 não leu'),$(nnotify 'p=4 force=1 t=Disco: degrau D4 não leu')" "1,1" "D2 não leu aos 15 min e D4 não leu aos 60: os dois avisos saem (carimbo POR degrau; o D2 em -p 3 não cala o D4 em -p 4 forçado)"

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
# gate-fix 2: a marca "já avisei" (absent) só é gravada depois que o notify CONFIRMOU; sem isso o D2 sumido fica mudo pelo episódio inteiro
reset; XENV=("DR_D2_CMD=$W/nao-existe"); echo fail > "$SD/notify.mode"
walk 5000 0 "$T0" $((T0 + 900)) 300
eq "$(nnotify 'p=4 force=1 t=Disco: degrau D2 ausente'),$(sv st2)" "1,none" "D2 ausente com o notify falhando: 1 tentativa e a marca 'já avisei' (absent) NÃO é gravada"
rm -f "$SD/notify.mode"; tick 5000 0 $((T0 + 1000))
eq "$(nnotify 'p=4 force=1 t=Disco: degrau D2 ausente'),$(sv st2)" "2,absent" "…notify de volta: a rodada seguinte avisa e só então grava absent"
tick 5000 0 $((T0 + 1100)); tick 5000 0 $((T0 + 1200))
eq "$(nnotify 'p=4 force=1 t=Disco: degrau D2 ausente')" 2 "…e depois fica calado (uma vez por episódio)"

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

section "escalada do teto de 6 h: só conta como feita se algum canal CONFIRMOU a entrega (gate-fix 2: tentado ≠ entregue)"
# D4 agiu aos 60 min; a repetição do 'acted' é aos 30 min (T0+5400): é aí que o teto de 6 h cai na escalada. Rodadas de 300 s (a lacuna máxima é 600 s).
capwalk() { reset; mode d2 rc=10; mode d3 rc=10; mode d4 rc=0; walk 2500 0 "$T0" $((T0 + 5100)) 300; }
# o instante T0+5100 (D4 já agiu, o teto está prestes a cair na escalada) é guardado uma vez; cada variante volta a ele sem refazer a caminhada de 5100 s
caprestore() { rm -f "$SD/notify.mode" "$SD/mail.mode" "$CITY/.gc/disk-recovery.nosave"; cp "$W/cap.state" "$STATE"; cp "$W/cap.calls" "$SD/calls"; : > "$SD/notify.log"; : > "$SD/mail.log"; : > "$LOG"; }
capwalk; cp "$STATE" "$W/cap.state"; cp "$SD/calls" "$W/cap.calls"
cp "$STATE" "$W/state.before"; cp "$LOG" "$W/log.before"; : > "$SD/notify.log"; : > "$SD/mail.log"
setfree 2500; setswap 0; printf '%s' $((T0 + 5400)) > "$W/now"; runl --dry-run
has "$OUT" "ESCALA:" "dry-run no teto de 6 h: mostra a escalada"
cmp -s "$STATE" "$W/state.before" && cmp -s "$LOG" "$W/log.before" && ok "dry-run no teto: estado e log intactos (esc4 não gravado)" || nope "dry-run no teto mexeu no estado ou no log"
eq "$(nnotify p=)$(nmail to=)" 00 "dry-run no teto: nada de notify/mail"
echo fail > "$SD/notify.mode"; echo fail > "$SD/mail.mode"
tick 2500 0 $((T0 + 5400))
eq "$(nnotify 'preciso de um humano'),$(nmail 'já disparou'),$(sv esc4)" "1,1,0" "escalada com notify E mail sem confirmação: 1 tentativa de cada e esc4 NÃO gravado"
has "$(logtxt)" "escalada NÃO entregue" "…e o log diz que repete"
rm -f "$SD/notify.mode" "$SD/mail.mode"
tick 2500 0 $((T0 + 5520))
eq "$(nnotify 'preciso de um humano'),$(nmail 'já disparou'),$(sv esc4)" "2,2,1" "canais de volta: a rodada seguinte escala de novo (o único 'preciso de um humano' não se perde)"
walk 2500 0 $((T0 + 5640)) $((T0 + 6000)) 120
eq "$(nnotify 'preciso de um humano'),$(nmail 'já disparou'),$(ncall d4 --run)" "2,2,1" "…entregue: calado de novo, e o D4 nunca é chamado de novo"
for ch in notify mail; do
  caprestore; echo fail > "$SD/$ch.mode"
  tick 2500 0 $((T0 + 5400)); rm -f "$SD/$ch.mode"; tick 2500 0 $((T0 + 5520))
  eq "$(sv esc4),$(nnotify 'preciso de um humano'),$(nmail 'já disparou')" "1,1,1" "só o $ch falhou: o outro canal entregou, a escalada vale e NÃO repete"
done
# NOTIFY_STRICT_EXIT=1 só nos avisos de -p >= 4 (push forçado): sem ele o notify sai 0 em todo caminho que não empurrou e o rc 0 não prova que chegou ao telefone.
# Com ele (scripts/notify, policy_exit): 10 segurado até as 7h (silêncio 22h–7h do Athos; fica no history.db e o flush das 7h empurra) e 11 dedup = o aviso já está garantido; 12 resumo/teto, 1 transporte, 13, 14 = nada saiu.
for code in 10 11 12 13 14 1; do
  caprestore; echo "strict=$code" > "$SD/notify.mode"; echo fail > "$SD/mail.mode"
  tick 2500 0 $((T0 + 5400)); tick 2500 0 $((T0 + 5520))
  case "$code" in
    10|11) eq "$(sv esc4),$(nnotify 'preciso de um humano')" "1,1" "notify rc=$code com STRICT (segurado até as 7h / dedup) + mail sem confirmação: a escalada vale e NÃO repete (nada se perde)"
           has "$(logtxt)" "conto como entregue" "…e o log diz que contou como entregue" ;;
    *)     eq "$(sv esc4),$(nnotify 'preciso de um humano')" "0,2" "notify rc=$code com STRICT (nada saiu) + mail sem confirmação: a escalada NÃO vale e repete a cada rodada" ;;
  esac
done
has "$(grep -F 'preciso de um humano' "$SD/notify.log")" "force=1" "o notify da escalada sai com o push forçado"
has "$(grep -F 'preciso de um humano' "$SD/notify.log")" "strict=1" "…e com NOTIFY_STRICT_EXIT=1"
reset; echo strict=12 > "$SD/notify.mode"; mode d2 rc=0; mode d3 rc=0
walk 3500 0 "$T0" $((T0 + 1800)) 300
hasnt "$(grep -F 'degrau D2 agiu' "$SD/notify.log")" "strict=1" "D2 agiu (-p 3, roteamento normal): sem STRICT (rc 0 = o roteador aceitou, resumo incluído)"
has "$(grep -F 'degrau D3 agiu' "$SD/notify.log")" "strict=1" "D3 agiu (-p 4 forçado): com STRICT"
has "$(logtxt)" "notify NÃO confirmado rc=12" "…e o resumo mudo em -p 4 vira 'NÃO confirmado' no log"

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

for k in ut2 ut3 ut4; do   # campos novos do gate-fix 2: um valor que não é número chegaria à aritmética do carimbo e, sob set -u, abortaria a rodada
  reset; tick 20000 0 "$T0"
  sed "s/^$k=0\$/$k=abc/" "$STATE" > "$STATE.x" && mv "$STATE.x" "$STATE"
  tick 20000 0 $((T0 + 120))
  eq "$RC" 0 "estado salvo com $k=abc: a rodada segue (0), sem abortar"
  has "$OUT" "estado salvo ilegível" "estado salvo com $k=abc: ilegível, avisa e recomeça"
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
  # gate-fix 2: a marca do aviso (arquivo vazio) só é tocada depois que o notify CONFIRMOU
  reset; mkdir -p "$W/ro"; chmod 555 "$W/ro"; XENV=("DR_STATE=$W/ro/state"); echo fail > "$SD/notify.mode"
  tick 20000 0 "$T0"
  eq "$(nnotify 'p=4 force=1 t=Disco: a escada não consegue gravar o estado')" 1 "estado não gravável com o notify falhando: 1 tentativa"
  [ ! -e "$CITY/.gc/disk-recovery.nosave" ] && ok "…e a marca de 1 h NÃO é gravada" || nope "marca gravada sem o notify confirmar"
  rm -f "$SD/notify.mode"; tick 20000 0 $((T0 + 120))
  eq "$(nnotify 'p=4 force=1 t=Disco: a escada não consegue gravar o estado')" 2 "…notify de volta: a rodada seguinte avisa"
  [ -e "$CITY/.gc/disk-recovery.nosave" ] && ok "…e só então grava a marca" || nope "marca não gravada depois da entrega"
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

section "estado novo troca o ruim por rename: o STATE nunca fica sem existir (sem ele = 'primeira rodada' = teto de 6 h perdido)"
mkdir -p "$W/mvbin" "$W/lnbin"
printf '#!/bin/bash\ncase "$*" in *.tmp.*) exit 1 ;; esac\nexec /bin/mv "$@"\n' > "$W/mvbin/mv"   # só o mv do estado NOVO (arquivo .tmp.) falha
printf '#!/bin/bash\nexit 1\n' > "$W/lnbin/ln"; cp "$W/lnbin/ln" "$W/lnbin/cp"                    # nem link nem cópia da evidência
chmod 755 "$W/mvbin/mv" "$W/lnbin/ln" "$W/lnbin/cp"
reset; mode d4 rc=0
tick 1400 0 "$T0"; tick 1400 0 $((T0 + 120))
eq "$(ncall d4 --run)" 1 "D4 disparou uma vez (2 leituras < 1,5 GB)"
printf 'lixo' > "$STATE"
XENV=("PATH=$W/mvbin:$PATH"); tick 1400 0 $((T0 + 240)); XENV=()
eq "$RC" 30 "o mv do estado novo falhou → 30"
[ "$(cat "$STATE" 2>/dev/null)" = lixo ] && ok "…o estado ruim continua no lugar (nunca houve um instante sem STATE)" || nope "o STATE sumiu quando o mv do estado novo falhou"
[ -n "$(ls "$STATE".corrupt-* 2>/dev/null)" ] && ok "…e a evidência (.corrupt) foi guardada" || nope "sem .corrupt"
hasnt "$(logtxt)" "não consegui guardar o estado ruim" "…sem aviso falso de evidência perdida (a 2ª gravação da rodada reconhece o .corrupt que já existe)"
tick 1400 0 $((T0 + 360)); tick 1400 0 $((T0 + 480))
eq "$(ncall d4 --run)" 1 "…e as rodadas seguintes NÃO reiniciam de novo (o teto de 6 h valeu o tempo todo)"
reset; printf 'lixo' > "$STATE"; XENV=("PATH=$W/lnbin:$PATH"); tick 20000 0 "$T0"
eq "$RC,$(sv acted4_ts)" "0,$T0" "sem link nem cópia da evidência: o estado novo é gravado mesmo assim (acted4_ts = agora)"
has "$(logtxt)" "não consegui guardar o estado ruim" "…e o log diz que a evidência se perdeu"
reset; mkdir -p "$STATE"
tick 20000 0 "$T0"
[ "$RC" = 0 ] && [ -f "$STATE" ] && ok "estado que é um DIRETÓRIO (sem link duro, sem cópia): sai do caminho e o estado novo nasce, a escada não fica cega" || nope "diretório no lugar do estado: rc=$RC e o estado novo não nasceu"
[ -n "$(ls -d "$STATE".corrupt-* 2>/dev/null)" ] && ok "…e o diretório foi guardado como .corrupt" || nope "o diretório sumiu sem ser guardado"

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
# o degrau da 1ª instância fica parado até o arquivo de liberação existir (em vez de um sleep fixo de 3 s): a trava segue ocupada pelo tempo que o teste precisar, qualquer que seja a velocidade da máquina
rm -f "$W/release"
reset; walk 5000 0 "$T0" $((T0 + 800)) 100; mode d2 rc=10 "waitfor=$W/release"
printf '%s' 5000 > "$W/free"; printf '%s' 0 > "$W/swap"; printf '%s' $((T0 + 900)) > "$W/now"
( env -i "${BASE[@]}" /bin/bash "$LADDER" --run > "$W/first.out" 2>&1 ) &
bgpid=$!
i=0; while [ ! -s "$SD/calls" ] || ! grep -q '^d2 --run$' "$SD/calls"; do sleep 0.2; i=$((i+1)); [ "$i" -gt 40 ] && break; done
runl --run
eq "$RC" 10 "segunda instância enquanto a primeira roda → 10"
has "$(logtxt)" "outra instância" "…e diz no log"
runl --dry-run; eq "$RC" 0 "dry-run não toma a trava"
touch "$W/release"; wait "$bgpid"
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
reset; XENV=(DR_D4_HARD_N=0)
tick 20000 0 "$T0"; tick 20000 0 $((T0 + 120))
eq "$(ncall d4 --run)" 0 "DR_D4_HARD_N=0 (abaixo do mínimo, 1) cai no padrão: com o disco folgado o D4 NÃO é chamado"
has "$(logtxt)" "DR_D4_HARD_N='0'->2" "…e o log diz que caiu no padrão"

section "notify e mail com defeito não derrubam a rodada"
reset; echo fail > "$SD/notify.mode"; echo fail > "$SD/mail.mode"
walk 5000 0 "$T0" $((T0 + 900)) 100
eq "$RC,$(sv st2)" "0,acted" "notify e mail falhando: o degrau agiu, rodada 0, marca acted"
has "$(logtxt)" "WARN: notify NÃO confirmado rc=1" "notify falhou: WARN no log"
has "$(logtxt)" "WARN: gc mail send mayor NÃO confirmado rc=1" "mail falhou: WARN no log"
reset; XENV=("DR_GC_BIN=$W/sem-gc")
walk 5000 0 "$T0" $((T0 + 900)) 100
has "$(logtxt)" "WARN: gc mail send mayor NÃO confirmado rc=127" "gc ausente: WARN rc=127, sem travar"
reset; XENV=(DR_NOTIFY_TIMEOUT_S=1); echo hang > "$SD/notify.mode"
walk 5000 0 "$T0" $((T0 + 800)) 100
SECONDS=0; tick 5000 0 $((T0 + 900)); el=$SECONDS
[ "$el" -le 25 ] && ok "notify travado é cortado (${el}s)" || nope "notify travado segurou a rodada ${el}s"
has "$(logtxt)" "WARN: notify NÃO confirmado rc=124" "notify travado: rc=124 no log"
reset; XENV=("TMPDIR=$W/nao/existe")
walk 5000 0 "$T0" $((T0 + 900)) 100
eq "$(sv st2)" unknown "sem mktemp: o degrau fica unknown (não 'agiu')"

section "rotação do log"
reset; head -c 5000 /dev/zero | tr '\0' 'x' > "$LOG"; XENV=(DR_LOG_MAX_KB=1)
tick 20000 0 "$T0"
[ -f "$LOG.1" ] && ok "log acima do limite foi girado para .1" || nope "log não girou"

section "nada vazou"
[ -z "$(ls "$W/tmp" 2>/dev/null)" ] && ok "nenhum temporário sobrou em TMPDIR" || nope "temporários sobraram: $(ls "$W/tmp")"

printf '\n%s passaram, %s falharam\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
