#!/usr/bin/env bash
# rea-run.selftest.sh — hermético: mbp-run, df, sysctl e pgrep são stubs; nada toca o MBP, o live nem o disco real.
#
# Contents
#   Casos · Controle negativo
#
# CASOS: caminho do MBP (rc 0 e rc do comando propagados, 96..99 caem para o mini, --local, mbp-run ausente, argumentos
#   repassados) · execução no mini (cwd = scratch, REA_RUN_SCRATCH, scratch e trava soltos) · a 2ª execução ESPERA a 1ª ·
#   disco (fronteira 10 GB) · swap (fronteira 6144 MB, unidades M/G) · df/sysctl/pgrep ILEGÍVEL = 93, nunca "pode rodar" ·
#   outro `rea` (espera, desiste em 91, some e segue; o próprio wrapper e seus ancestrais NÃO contam) · trava de dono morto,
#   de pid reaproveitado e sem dono é reaped; de dono vivo NÃO é · trava não criável = 93 · rc do comando · SIGTERM no meio
#   (árvore morta, scratch e trava limpos, rc 143) · timeout (124) · scratch órfão apagado, symlink e vizinho preservados ·
#   --push/--pull/--env · uso errado (94) · log sem argumentos do comando · --check.
# CONTROLE NEGATIVO: cada porta (marcador "# gate:<nome>" no script: disk, swap, lock, lock-live, cleanup, fallback, timeout,
#   exit-trap, self-chain, opt-sem-valor, ilegivel-disco/swap/pgrep) é removida numa cópia e o mutante TEM que deixar de reproduzir o resultado
#   do script real no caso que a protege — inclusive "ilegível virou pode-rodar".
# REA_RUN_UNDER_TEST=<script> roda a mesma bateria contra outro rea-run.sh.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="${REA_RUN_UNDER_TEST:-$HERE/rea-run.sh}"
T=$(mktemp -d "${TMPDIR:-/tmp}/rea-run-selftest.XXXXXX") || exit 1
T=${T//\/\//\/}   # TMPDIR termina em "/": o wrapper normaliza "//" e o teste compara caminhos
BGPIDS=""
cleanup() { for p in $BGPIDS; do kill -KILL "$p" 2>/dev/null; done; chmod -R u+w "$T" 2>/dev/null; find "$T" -depth -delete 2>/dev/null; }
trap cleanup EXIT
mkdir -p "$T/bin"
PASS=0; FAIL=0
ok() { # nome condição(0=ok)
  if [ "$2" -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; [ -n "${OUT:-}" ] && printf '      saída: %s\n' "$(printf '%s' "$OUT" | tail -5)"; fi
}
eq() { [ "$2" = "$3" ]; ok "$1 (esperado '$2', veio '$3')" $?; }
has() { case "$3" in *"$2"*) ok "$1" 0 ;; *) ok "$1 (faltou '$2')" 1 ;; esac; }

# ---- stubs ---------------------------------------------------------------------------------------------------------
cat > "$T/bin/df" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_DF_FAIL:-0}" = 1 ] && exit 1
[ -n "${STUB_DF_RAW:-}" ] && { printf '%b\n' "$STUB_DF_RAW"; exit 0; }
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s5 238000000 100 %s 99%% /System/Volumes/Data\n' "${STUB_DF_KB:-20971520}"
EOF
cat > "$T/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_SWAP_FAIL:-0}" = 1 ] && exit 1
[ -n "${STUB_SWAP_RAW:-}" ] && { printf '%b\n' "$STUB_SWAP_RAW"; exit 0; }
printf 'total = 8192.00M  used = %s  free = 100.00M  (encrypted)\n' "${STUB_SWAP_USED:-1000.00M}"
EOF
cat > "$T/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
# STUB_PGREP_SAMPLES: arquivo de linhas de comando; aplica o padrão recebido (-f PADRÃO) e imprime o nº da linha casada
if [ -n "${STUB_PGREP_SAMPLES:-}" ]; then
  [ "$1" = -f ] || exit 3
  hits=$(grep -n -E -- "$2" "$STUB_PGREP_SAMPLES" | cut -d: -f1)
  [ -n "$hits" ] || exit 1
  printf '%s\n' "$hits"; exit 0
fi
f="${STUB_PGREP_FILE:-/nonexistent}"
[ -f "$f" ] || exit 1
if grep -q '^ERR' "$f"; then exit 2; fi
[ -s "$f" ] || exit 1
cat "$f"; exit 0
EOF
cat > "$T/bin/mbp-run.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_MBP_LOG"
[ -n "${STUB_MBP_OUT:-}" ] && echo "$STUB_MBP_OUT"
exit "${STUB_MBP_RC:-99}"
EOF
chmod +x "$T/bin/"*
N=0
reset_env() {
  N=$((N+1))
  export REA_RUN_CITY="$T/city.$N" REA_RUN_SCRATCH_ROOT="$T/scr.$N" REA_RUN_MBP_RUN="$T/bin/mbp-run.sh"
  export REA_RUN_DF="$T/bin/df" REA_RUN_SYSCTL="$T/bin/sysctl" REA_RUN_PGREP="$T/bin/pgrep"
  export REA_RUN_POLL_S=0.1 REA_RUN_KILL_GRACE_S=1 REA_RUN_WAIT_S=30 REA_RUN_TIMEOUT_S=60 REA_RUN_MIN_FREE_GB=10 REA_RUN_MAX_SWAP_MB=6144
  export STUB_MBP_LOG="$T/mbp.$N.log" STUB_PGREP_FILE="$T/pgrep.$N" MARK="$T/mark.$N"
  unset REA_RUN_LOCK_DIR STUB_PGREP_SAMPLES REA_RUN_PGREP_PATTERN STUB_DF_FAIL STUB_DF_RAW STUB_DF_KB STUB_SWAP_FAIL STUB_SWAP_RAW STUB_SWAP_USED STUB_MBP_OUT
  export STUB_MBP_RC=99
  find "$REA_RUN_CITY" "$REA_RUN_SCRATCH_ROOT" -depth -delete 2>/dev/null
  : > "$STUB_MBP_LOG"; rm -f "$STUB_PGREP_FILE" "$MARK"
  mkdir -p "$REA_RUN_CITY/.gc/run" "$REA_RUN_CITY/.gc/logs"
  LOCK="$REA_RUN_CITY/.gc/run/rea-run.lock"; LOGF="$REA_RUN_CITY/.gc/logs/rea-run.jsonl"
}
run() { OUT=$("$RUN" "$@" 2>&1); RC=$?; }
clean_after() { # nome — scratch e trava soltos
  [ -z "$(ls -A "$REA_RUN_SCRATCH_ROOT" 2>/dev/null)" ]; ok "$1: scratch apagado" $?
  [ ! -e "$LOCK" ]; ok "$1: trava solta" $?
}
mbp_calls() { grep -c . "$STUB_MBP_LOG"; }

# ---- 1. execução no mini ---------------------------------------------------------------------------------------------
reset_env
run --local -- sh -c 'printf "%s\n%s\n%s\n" "$PWD" "$REA_RUN_SCRATCH" "$REA_RUN_MODE" > "$0"; test -n "$(ls -A "$PWD")" || true' "$MARK"
eq "mini: rc 0" 0 "$RC"
l1=$(sed -n 1p "$MARK" 2>/dev/null); l2=$(sed -n 2p "$MARK" 2>/dev/null)
eq "mini: cwd é o scratch" "$l2" "$l1"
case "$l1" in "$(cd "$REA_RUN_SCRATCH_ROOT" && pwd -P)"/run.*|"$REA_RUN_SCRATCH_ROOT"/run.*) ok "mini: scratch dentro da raiz" 0 ;; *) ok "mini: scratch dentro da raiz ($l1)" 1 ;; esac
eq "mini: REA_RUN_MODE" local "$(sed -n 3p "$MARK" 2>/dev/null)"
clean_after "mini"
has "mini: log ran/local" '"event":"ran","mode":"local","rc":0' "$(cat "$LOGF")"
eq "mini: --local não chama o mbp-run" 0 "$(mbp_calls)"
eq "mini: raiz do scratch é 0700" 700 "$(stat -f %Lp "$REA_RUN_SCRATCH_ROOT" 2>/dev/null || stat -c %a "$REA_RUN_SCRATCH_ROOT")"

# rc do comando propagado; scratch e trava limpos mesmo com falha
reset_env; run --local -- sh -c 'exit 7'; eq "rc do comando propagado" 7 "$RC"; clean_after "falha do comando"
has "log guarda o rc 7" '"rc":7' "$(cat "$LOGF")"

# ---- 2. caminho do MBP -----------------------------------------------------------------------------------------------
reset_env; export STUB_MBP_RC=0 STUB_MBP_OUT=remoto-ok
run -- sh -c "echo local > '$MARK'"
eq "MBP rc 0: rc 0" 0 "$RC"; has "MBP: saída do mbp-run" remoto-ok "$OUT"
[ ! -e "$MARK" ]; ok "MBP rc 0: comando NÃO rodou no mini" $?
has "MBP: chamou --exec" "--exec -- sh -c" "$(cat "$STUB_MBP_LOG")"
has "MBP: log ran/mbp" '"mode":"mbp"' "$(cat "$LOGF")"
reset_env; export STUB_MBP_RC=3
run -- sh -c "echo local > '$MARK'"; eq "MBP rc do comando propagado" 3 "$RC"
[ ! -e "$MARK" ]; ok "MBP rc 3: sem fallback" $?
for c in 96 97 98 99; do
  reset_env; export STUB_MBP_RC=$c
  run -- sh -c "echo local > '$MARK'"
  eq "MBP rc $c: roda no mini, rc 0" 0 "$RC"; [ -e "$MARK" ]; ok "MBP rc $c: comando rodou no mini" $?
  has "MBP rc $c: log fallback" '"event":"fallback"' "$(cat "$LOGF")"
  clean_after "fallback $c"
done
reset_env; rm -f "$T/nobin"; REA_RUN_MBP_RUN="$T/nao-existe" run -- sh -c "echo local > '$MARK'"
eq "mbp-run ausente: roda no mini" 0 "$RC"; [ -e "$MARK" ]; ok "mbp-run ausente: comando rodou" $?
reset_env; export STUB_MBP_RC=0; echo x > "$T/in.txt"
run --push "$T/in.txt" --pull "out.txt:$T/o.txt" --env A=1 --env B=2 -- sh -c 'true'
has "MBP: repassa push/pull/env" "--exec --push $T/in.txt --pull out.txt:$T/o.txt --env A=1 --env B=2 -- sh -c true" "$(cat "$STUB_MBP_LOG")"

# ---- 3. serialização: a 2ª execução espera ---------------------------------------------------------------------------
reset_env; L="$T/order.$N"; : > "$L"
"$RUN" --local -- sh -c "echo A-start >> '$L'; sleep 1; echo A-end >> '$L'" >/dev/null 2>&1 & pa=$!; BGPIDS="$BGPIDS $pa"
sleep 0.4
"$RUN" --local -- sh -c "echo B-start >> '$L'; echo B-end >> '$L'" >/dev/null 2>&1 & pb=$!; BGPIDS="$BGPIDS $pb"
wait $pa; ra=$?; wait $pb; rb=$?
eq "serialização: ordem" "A-start A-end B-start B-end" "$(tr '\n' ' ' < "$L" | sed 's/ $//')"
eq "serialização: rc A" 0 "$ra"; eq "serialização: rc B" 0 "$rb"; clean_after "serialização"

# ---- 4. disco e swap -------------------------------------------------------------------------------------------------
reset_env; export STUB_DF_KB=10485760; run --local -- sh -c "echo x > '$MARK'"
eq "disco: exatamente 10 GB passa" 0 "$RC"
reset_env; export STUB_DF_KB=10485759; run --local -- sh -c "echo x > '$MARK'"
eq "disco: 10 GB - 1 KB recusa (92)" 92 "$RC"; [ ! -e "$MARK" ]; ok "disco: comando NÃO rodou" $?
has "disco: mensagem com os números" "disco livre" "$OUT"; has "disco: log com motivo" '"reason":"disco-baixo"' "$(cat "$LOGF")"
has "disco: log com free_gb" '"free_gb":9' "$(cat "$LOGF")"; clean_after "recusa por disco"
reset_env; export STUB_SWAP_USED=6144.00M; run --local -- sh -c "echo x > '$MARK'"; eq "swap: exatamente 6144 MB passa" 0 "$RC"
reset_env; export STUB_SWAP_USED=6145.00M; run --local -- sh -c "echo x > '$MARK'"
eq "swap: 6145 MB recusa (92)" 92 "$RC"; [ ! -e "$MARK" ]; ok "swap: comando NÃO rodou" $?; has "swap: log com motivo" '"reason":"swap-alto"' "$(cat "$LOGF")"
reset_env; export STUB_SWAP_USED=6.1G; run --local -- sh -c true; eq "swap: 6.1G lido como 6246 MB e recusa" 92 "$RC"
reset_env; export STUB_SWAP_USED=5.9G; run --local -- sh -c true; eq "swap: 5.9G passa" 0 "$RC"
reset_env; export STUB_SWAP_USED=512K; run --local -- sh -c true; eq "swap: 512K passa" 0 "$RC"
reset_env; export STUB_DF_KB=1 STUB_SWAP_USED=7000M; run --local -- sh -c true; has "disco E swap: os dois motivos" "disco-baixo+swap-alto" "$(cat "$LOGF")"
reset_env; export STUB_DF_KB=1; run --local -- sh -c true; eq "recusa pré-trava não deixa lixo" 92 "$RC"; clean_after "pré-checagem"

# ---- 5. ilegível = 93, nunca "pode rodar" -----------------------------------------------------------------------------
for spec in "STUB_DF_FAIL=1:ilegivel:disco" "STUB_DF_RAW=lixo:ilegivel:disco" "STUB_DF_RAW=Filesystem\\nx y z NaN:ilegivel:disco" \
            "STUB_SWAP_FAIL=1:ilegivel:swap" "STUB_SWAP_RAW=lixo:ilegivel:swap" "STUB_SWAP_RAW=total = 1M  used = ?  free = 1M:ilegivel:swap"; do
  reset_env; var=${spec%%=*}; rest=${spec#*=}; val=${rest%:ilegivel:*}; why="ilegivel:${rest##*:ilegivel:}"
  export "$var=$val"; run --local -- sh -c "echo x > '$MARK'"
  eq "ilegível ($spec): rc 93" 93 "$RC"; [ ! -e "$MARK" ]; ok "ilegível ($spec): comando NÃO rodou" $?
  has "ilegível ($spec): motivo no log" "\"reason\":\"$why\"" "$(cat "$LOGF")"; clean_after "ilegível"
done
reset_env; export STUB_DF_FAIL=1; run --local -- sh -c true; has "ilegível: log grava free_gb null" '"free_gb":null' "$(cat "$LOGF")"

# ---- 6. outro `rea` rodando ------------------------------------------------------------------------------------------
sleep 60 & other=$!; BGPIDS="$BGPIDS $other"
reset_env; echo "$other" > "$STUB_PGREP_FILE"; run --local --wait-s 1 -- sh -c "echo x > '$MARK'"
eq "outro rea: desiste em 91" 91 "$RC"; [ ! -e "$MARK" ]; ok "outro rea: comando NÃO rodou" $?; has "outro rea: motivo" '"reason":"outro-rea"' "$(cat "$LOGF")"; clean_after "outro rea"
reset_env; echo "$other" > "$STUB_PGREP_FILE"; ( sleep 1; rm -f "$STUB_PGREP_FILE" ) & BGPIDS="$BGPIDS $!"
run --local -- sh -c "echo x > '$MARK'"; eq "outro rea some: segue" 0 "$RC"; [ -e "$MARK" ]; ok "outro rea some: comando rodou" $?
reset_env; echo ERR > "$STUB_PGREP_FILE"; run --local -- sh -c "echo x > '$MARK'"
eq "pgrep ilegível: 93" 93 "$RC"; [ ! -e "$MARK" ]; ok "pgrep ilegível: comando NÃO rodou" $?; has "pgrep ilegível: motivo" 'ilegivel:pgrep' "$(cat "$LOGF")"
reset_env; PF="$STUB_PGREP_FILE" RR="$RUN" bash -c 'echo $$ > "$PF"; exec "$RR" --local --wait-s 2 -- true' >/dev/null 2>&1
eq "o próprio wrapper não conta como outro rea" 0 "$?"
reset_env; PF="$STUB_PGREP_FILE" RR="$RUN" bash -c 'echo $$ > "$PF"; "$RR" --local --wait-s 2 -- true' >/dev/null 2>&1
eq "o ancestral do wrapper não conta como outro rea" 0 "$?"
kill "$other" 2>/dev/null
# o padrão padrão casa processo `node .../bin/rea` e NÃO casa texto "bin/rea" em argumento alheio
reset_env; export STUB_PGREP_SAMPLES="$T/samples.$N"
cat > "$STUB_PGREP_SAMPLES" <<'SAMPLES'
node /opt/homebrew/bin/rea observe-web-session http://127.0.0.1:9301 ABC
/opt/homebrew/opt/node@22/bin/node /opt/homebrew/bin/rea list-browser-targets x
node --max-old-space-size=4096 /opt/homebrew/bin/rea inspect-web-page
node /opt/homebrew/lib/node_modules/rea-agents/scripts/rea.mjs doctor
node /opt/homebrew/bin/rea
claude -p Rode pgrep -fl 'bin/rea ' antes de começar
sh -c echo node /x/bin/rea y; sleep 30
vim /opt/homebrew/bin/rea notas
node /opt/homebrew/bin/read-something arg
node /x/bin/area foo
SAMPLES
run --check
has "padrão: casa as 5 formas reais de rea (linhas 1-5) e só elas" "outro rea: sim (pid 1 2 3 4 5)" "$OUT"
eq "padrão: rc 92 (há outro rea)" 92 "$RC"

# ---- 7. a trava -------------------------------------------------------------------------------------------------------
pstart() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/  */ /g;s/^ //;s/ $//'; }
mklock() { mkdir -p "$LOCK"; printf '%s\n%s\n%s\n' "$1" "$(date +%s)" "$2" > "$LOCK/owner"; }
reset_env; mklock 999999 "Mon Jan  1 00:00:00 2001"; run --local -- sh -c "echo x > '$MARK'"
eq "trava de dono morto é reaped" 0 "$RC"; has "trava morta: aviso" "trava órfã removida" "$OUT"; [ -e "$MARK" ]; ok "trava morta: comando rodou" $?; clean_after "trava morta"
sleep 60 & holder=$!; BGPIDS="$BGPIDS $holder"
reset_env; mklock "$holder" "$(pstart "$holder")"; run --local --wait-s 1 -- sh -c "echo x > '$MARK'"
eq "trava de dono VIVO não é reaped (91)" 91 "$RC"; [ ! -e "$MARK" ]; ok "dono vivo: comando NÃO rodou" $?
eq "dono vivo: trava intacta" "$holder" "$(sed -n 1p "$LOCK/owner" 2>/dev/null)"; has "dono vivo: motivo" '"reason":"trava-ocupada"' "$(cat "$LOGF")"
reset_env; mklock "$holder" "Mon Jan  1 00:00:00 2001"; run --local -- sh -c "echo x > '$MARK'"
eq "pid reaproveitado (início diferente) é reaped" 0 "$RC"; [ -e "$MARK" ]; ok "pid reaproveitado: comando rodou" $?
kill "$holder" 2>/dev/null
reset_env; mkdir -p "$LOCK"; run --local --wait-s 1 -- sh -c "echo x > '$MARK'"
eq "trava SEM dono e recém-criada espera (91)" 91 "$RC"; [ ! -e "$MARK" ]; ok "sem dono recente: comando NÃO rodou" $?
reset_env; mkdir -p "$LOCK"; touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-5 min' +%Y%m%d%H%M.%S)" "$LOCK"
run --local -- sh -c "echo x > '$MARK'"; eq "trava sem dono e velha é reaped" 0 "$RC"
reset_env; : > "$T/arquivo.$N"; export REA_RUN_LOCK_DIR="$T/arquivo.$N/lock"; run --local -- sh -c "echo x > '$MARK'"
eq "trava não criável: 93" 93 "$RC"; [ ! -e "$MARK" ]; ok "trava não criável: comando NÃO rodou" $?; has "trava não criável: motivo" 'trava-nao-criavel' "$(cat "$LOGF")"

# ---- 8. sinal e timeout -----------------------------------------------------------------------------------------------
reset_env; PIDF="$T/gpid.$N"
"$RUN" --local -- sh -c "sleep 60 & echo \$! > '$PIDF'; wait" >/dev/null 2>&1 & w=$!; BGPIDS="$BGPIDS $w"
for _ in $(seq 1 50); do [ -s "$PIDF" ] && break; sleep 0.1; done
gp=$(cat "$PIDF" 2>/dev/null); kill -0 "$gp" 2>/dev/null; ok "SIGTERM: neto vivo antes do sinal" $?
kill -TERM "$w"; wait "$w"; rc=$?
eq "SIGTERM: rc 143" 143 "$rc"
sleep 0.3; kill -0 "$gp" 2>/dev/null; [ $? -ne 0 ]; ok "SIGTERM: neto morto" $?
clean_after "SIGTERM"
# SIGKILL no wrapper não limpa: a PRÓXIMA execução reaps a trava de dono morto e apaga o scratch órfão
reset_env; PIDK="$T/kpid.$N"
"$RUN" --local -- sh -c "echo \$\$ > '$PIDK'; sleep 30" >/dev/null 2>&1 & w=$!; BGPIDS="$BGPIDS $w"
for _ in $(seq 1 50); do [ -s "$PIDK" ] && break; sleep 0.1; done
kill -KILL "$w"; wait "$w" 2>/dev/null
[ -d "$LOCK" ]; ok "SIGKILL: a trava ficou (dono morto)" $?
[ -n "$(ls -A "$REA_RUN_SCRATCH_ROOT" 2>/dev/null)" ]; ok "SIGKILL: o scratch ficou" $?
run --local -- sh -c "echo x > '$MARK'"
eq "SIGKILL: a próxima execução roda" 0 "$RC"; has "SIGKILL: trava reaped" "trava órfã removida" "$OUT"; has "SIGKILL: scratch órfão apagado" "scratch órfão" "$OUT"
clean_after "pós-SIGKILL"
kk=$(cat "$PIDK" 2>/dev/null); kill -KILL $(pgrep -P "$kk" 2>/dev/null) "$kk" 2>/dev/null
# o timeout tem relógio de parede próprio: o comando que passou do prazo é encerrado
reset_env; export REA_RUN_TIMEOUT_S=1; s0=$(date +%s)
run --local -- sh -c "sleep 20; echo fim > '$MARK'"; s1=$(date +%s)
eq "timeout: rc 124" 124 "$RC"; [ ! -e "$MARK" ]; ok "timeout: comando encerrado antes de terminar" $?
[ $((s1 - s0)) -lt 15 ]; ok "timeout: voltou antes do comando acabar ($((s1 - s0)) s de 20)" $?; has "timeout: aviso" "timeout de 1s" "$OUT"; clean_after "timeout"

# ---- 9. scratch órfão ------------------------------------------------------------------------------------------------
reset_env; mkdir -p "$REA_RUN_SCRATCH_ROOT/run.OLD" "$REA_RUN_SCRATCH_ROOT/keepme" "$T/victim.$N"
echo captura > "$REA_RUN_SCRATCH_ROOT/run.OLD/cap.json"; echo v > "$T/victim.$N/arquivo"; echo k > "$REA_RUN_SCRATCH_ROOT/keepme/k"
ln -s "$T/victim.$N" "$REA_RUN_SCRATCH_ROOT/run.LINK"; chmod -R go-rwx "$REA_RUN_SCRATCH_ROOT"
run --local -- true
eq "órfão: rc 0" 0 "$RC"; [ ! -e "$REA_RUN_SCRATCH_ROOT/run.OLD" ]; ok "órfão run.OLD apagado" $?
[ -f "$T/victim.$N/arquivo" ]; ok "symlink run.LINK: alvo NÃO apagado" $?
[ -L "$REA_RUN_SCRATCH_ROOT/run.LINK" ]; ok "symlink run.LINK: preservado e avisado" $?; has "symlink: aviso" "symlink" "$OUT"
[ -f "$REA_RUN_SCRATCH_ROOT/keepme/k" ]; ok "vizinho fora de run.* intacto" $?

# ---- 10. push / pull / env / uso -------------------------------------------------------------------------------------
reset_env; echo conteudo > "$T/in.$N.txt"
run --local --push "$T/in.$N.txt" --pull "out.txt:$T/out.$N.txt" --env FOO=bar -- sh -c 'cat in/in.'"$N"'.txt > out.txt; echo "$FOO" >> out.txt'
eq "push/pull/env: rc 0" 0 "$RC"; eq "push+pull+env: conteúdo" "conteudo bar" "$(tr '\n' ' ' < "$T/out.$N.txt" 2>/dev/null | sed 's/ $//')"; clean_after "push/pull"
reset_env; run --local;                                  eq "uso: sem comando = 94" 94 "$RC"
# opção sem valor NÃO pode travar em laço (o `shift 2` falha sem consumir nada): roda com relógio de parede
run_limited() { # segundos args... — mata se passar do prazo; RC=124 nesse caso
  local lim=$1 rcf="$T/rcl.$N" pid; shift; rm -f "$rcf"
  ( "$RUN" "$@" >/dev/null 2>&1; echo $? > "$rcf" ) & pid=$!
  for _ in $(seq 1 $((lim * 10))); do [ -f "$rcf" ] && break; sleep 0.1; done
  if [ -f "$rcf" ]; then RC=$(cat "$rcf"); else RC=124; kill -KILL $(pgrep -P "$pid" 2>/dev/null) "$pid" 2>/dev/null; fi
}
for o in --push --pull --env --wait-s; do reset_env; run_limited 20 --local "$o"; eq "uso: $o sem valor = 94 (sem laço)" 94 "$RC"; done
reset_env; export REA_RUN_POLL_S=.; run --local -- true;  eq "config: POLL_S '.' = 93" 93 "$RC"
reset_env; export REA_RUN_POLL_S=0; run --local -- true;  eq "config: POLL_S 0 = 93" 93 "$RC"
reset_env; export REA_RUN_TIMEOUT_S=0; run --local -- true; eq "config: TIMEOUT 0 = 93" 93 "$RC"
reset_env; run --local --bogus -- true;                  eq "uso: opção desconhecida = 94" 94 "$RC"
reset_env; run --local --pull "/etc/passwd:$T/x" -- true; eq "uso: --pull absoluto = 94" 94 "$RC"
reset_env; run --local --pull "../x:$T/x" -- true;       eq "uso: --pull com .. = 94" 94 "$RC"
reset_env; run --local --pull "a/../../x:$T/x" -- true;  eq "uso: --pull a/../.. = 94" 94 "$RC"
reset_env; run --local --pull "semdestino" -- true;      eq "uso: --pull sem destino = 94" 94 "$RC"
reset_env; run --local --push "$T/nao-existe" -- true;   eq "uso: --push inexistente = 94" 94 "$RC"
reset_env; run --local --env "1BAD=x" -- true;           eq "uso: --env inválido = 94" 94 "$RC"
reset_env; REA_RUN_MIN_FREE_GB=abc run --local -- true;  eq "config: limite não numérico = 93" 93 "$RC"
reset_env; export STUB_DF_KB=1; run --local --push "$T/nao-existe" -- true; eq "uso vence recusa de máquina" 94 "$RC"

# --pull que falha: rc 0 não pode esconder "não veio"
reset_env; run --local --pull "nao-existe.txt:$T/p.$N.txt" -- true
eq "pull falho com comando ok: 93" 93 "$RC"; has "pull falho: mensagem" "pull de 'nao-existe.txt' falhou" "$OUT"
has "pull falho: log marca" '"reason":"pull-falhou"' "$(cat "$LOGF")"; clean_after "pull falho"
reset_env; run --local --pull "nao-existe.txt:$T/p.$N.txt" -- sh -c 'exit 5'
eq "pull falho com comando já falho: mantém o rc 5" 5 "$RC"; has "pull falho + rc 5: log marca" '"reason":"pull-falhou"' "$(cat "$LOGF")"
reset_env; REA_RUN_MBP_RUN="$T/nao-existe" run -- true
eq "mbp-run ausente: roda no mini" 0 "$RC"; has "mbp-run ausente: aviso" "mbp-run.sh ausente" "$OUT"; has "mbp-run ausente: log" '"reason":"mbp-run-ausente"' "$(cat "$LOGF")"
# pgrep rc 0 com saída vazia é incoerente = ilegível
cat > "$T/bin/pgrep-vazio" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$T/bin/pgrep-vazio"
reset_env; REA_RUN_PGREP="$T/bin/pgrep-vazio" run --local -- sh -c "echo x > '$MARK'"
eq "pgrep rc 0 sem saída: 93" 93 "$RC"; [ ! -e "$MARK" ]; ok "pgrep incoerente: comando NÃO rodou" $?

# ---- 11. log sem argumentos --------------------------------------------------------------------------------------------
reset_env; run --local -- sh -c 'true' SEGREDO-TOKEN-123 https://x.example/?k=1
LOGTXT=$(cat "$LOGF"); case "$LOGTXT" in *SEGREDO*|*example*) ok "log vaza argumento" 1 ;; *) ok "log não vaza argumento" 0 ;; esac
has "log: nome do comando" '"cmd":"sh"' "$LOGTXT"; has "log: nº de argumentos" '"nargs":4' "$LOGTXT"

# ---- 12. --check -------------------------------------------------------------------------------------------------------
reset_env; run --check;                                  eq "check: ok = 0" 0 "$RC"; has "check: mostra o estado" "disco livre" "$OUT"
reset_env; export STUB_DF_KB=1; run --check;             eq "check: disco baixo = 92" 92 "$RC"
reset_env; export STUB_SWAP_FAIL=1; run --check;         eq "check: swap ilegível = 93" 93 "$RC"
reset_env; echo 999999 > "$STUB_PGREP_FILE"; run --check; eq "check: outro rea = 92" 92 "$RC"
reset_env; echo ERR > "$STUB_PGREP_FILE"; run --check;   eq "check: pgrep ilegível = 93" 93 "$RC"
reset_env; run --check; [ -z "$(ls -A "$REA_RUN_SCRATCH_ROOT" 2>/dev/null)" ] && [ ! -e "$LOCK" ]; ok "check não cria scratch nem trava" $?

# ---- CONTROLE NEGATIVO -------------------------------------------------------------------------------------------------
# Cada probe devolve uma linha "rc|efeito"; o mutante TEM que devolver outra coisa que o script real.
mutate() { # gate sed-expr
  local f="$T/mut-$1.sh"
  sed -e "$2" "$RUN" > "$f"; chmod +x "$f"
  cmp -s "$f" "$RUN" && { printf 'FAIL: mutante %s idêntico ao original (marcador sumiu?)\n' "$1"; FAIL=$((FAIL+1)); }
  printf '%s' "$f"
}
probe_disk() { reset_env; export STUB_DF_KB=1; RUN="$1" run --local -- sh -c "echo x > '$MARK'"; echo "$RC|$([ -e "$MARK" ] && echo rodou || echo parou)"; }
probe_swap() { reset_env; export STUB_SWAP_USED=7000M; RUN="$1" run --local -- sh -c "echo x > '$MARK'"; echo "$RC|$([ -e "$MARK" ] && echo rodou || echo parou)"; }
probe_lock() { reset_env; local L="$T/morder.$N"; : > "$L"
  "$1" --local -- sh -c "echo A-start >> '$L'; sleep 1; echo A-end >> '$L'" >/dev/null 2>&1 & local a=$!
  sleep 0.4; "$1" --local -- sh -c "echo B-start >> '$L'; echo B-end >> '$L'" >/dev/null 2>&1 & local b=$!
  wait $a; wait $b; tr '\n' ' ' < "$L"; }
probe_cleanup() { reset_env; RUN="$1" run --local -- true; echo "$RC|$(ls -A "$REA_RUN_SCRATCH_ROOT" 2>/dev/null | wc -l | tr -d ' ')"; }
probe_fallback() { reset_env; export STUB_MBP_RC=98; RUN="$1" run -- sh -c "echo x > '$MARK'"; echo "$RC|$([ -e "$MARK" ] && echo rodou || echo parou)"; }
probe_timeout() { reset_env; export REA_RUN_TIMEOUT_S=1; RUN="$1" run --local -- sh -c "sleep 3; echo fim > '$MARK'"; echo "$RC|$([ -e "$MARK" ] && echo terminou || echo cortado)"; }
mutant_check() { # gate probe sed-expr
  local m real mut
  m=$(mutate "$1" "$3"); N=$((N+7)); real=$("$2" "$RUN"); N=$((N+7)); mut=$("$2" "$m")
  [ "$real" != "$mut" ]; ok "mutante '$1' muda o resultado (real='$real' mutante='$mut')" $?
}
probe_ilegivel_disco() { reset_env; export STUB_DF_RAW=lixo; RUN="$1" run --local -- sh -c "echo x > '$MARK'"; echo "$RC|$([ -e "$MARK" ] && echo rodou || echo parou)"; }
probe_ilegivel_swap() { reset_env; export STUB_SWAP_RAW=lixo; RUN="$1" run --local -- sh -c "echo x > '$MARK'"; echo "$RC|$([ -e "$MARK" ] && echo rodou || echo parou)"; }
probe_ilegivel_pgrep() { reset_env; echo ERR > "$STUB_PGREP_FILE"; RUN="$1" run --local -- sh -c "echo x > '$MARK'"; echo "$RC|$([ -e "$MARK" ] && echo rodou || echo parou)"; }
probe_self_chain() { reset_env; PF="$STUB_PGREP_FILE" RR="$1" bash -c 'echo $$ > "$PF"; exec "$RR" --local --wait-s 1 -- true' >/dev/null 2>&1; echo "$?"; }
probe_lock_live() { reset_env; sleep 30 & local h=$!; mklock "$h" "$(pstart "$h")"; RUN="$1" run --local --wait-s 1 -- sh -c "echo x > '$MARK'"; kill "$h" 2>/dev/null
  echo "$RC|$([ -e "$MARK" ] && echo rodou || echo parou)"; }
probe_sigterm() { reset_env; local pf="$T/mgp.$N"
  "$1" --local -- sh -c "sleep 30 & echo \$! > '$pf'; wait" >/dev/null 2>&1 & local w=$!
  for _ in $(seq 1 50); do [ -s "$pf" ] && break; sleep 0.1; done
  kill -TERM "$w"; wait "$w" 2>/dev/null; local rc=$?; sleep 0.3
  local gp; gp=$(cat "$pf" 2>/dev/null); local vivo=morto; kill -0 "$gp" 2>/dev/null && { vivo=vivo; kill -KILL "$gp" 2>/dev/null; }
  echo "$rc|scratch=$(ls -A "$REA_RUN_SCRATCH_ROOT" 2>/dev/null | wc -l | tr -d ' ')|neto=$vivo"; }
probe_opt_sem_valor() { reset_env; RUN="$1" run_limited 6 --local --push; echo "$RC"; }
mutant_check opt-sem-valor probe_opt_sem_valor '/# gate:opt-sem-valor/s/\[ \$# -ge 2 \] ||/true ||/'
mutant_check ilegivel-disco probe_ilegivel_disco '/# gate:ilegivel-disco/s/.*/  isnum "$kb" || kb=99999999/'
mutant_check ilegivel-swap probe_ilegivel_swap '/# gate:ilegivel-swap/s/.*/  isnum "$n" || n=0/'
mutant_check ilegivel-pgrep probe_ilegivel_pgrep '/# gate:ilegivel-pgrep/s/\*) return 2 ;;/*) return 0 ;;/'
mutant_check self-chain probe_self_chain '/# gate:self-chain/s/.*/  chain=" "/'
mutant_check lock-live probe_lock_live '/# gate:lock-live/s/.*/  if [ -n "$cur" ]; then echo stale; return; fi/'
mutant_check exit-trap probe_sigterm '/# gate:exit-trap/s/.*/  :/'
mutant_check disk probe_disk '/# gate:disk/s/.*/  :/'
mutant_check swap probe_swap '/# gate:swap/s/.*/  :/'
mutant_check lock probe_lock '/# gate:lock/s/if mkdir /if mkdir -p /'
mutant_check cleanup probe_cleanup '/# gate:cleanup/s/.*/  :/'
mutant_check fallback probe_fallback '/# gate:fallback/s/96|97|98|99)/NUNCA)/'
mutant_check timeout probe_timeout '/# gate:timeout/s/: > "\$LOCK_DIR\/timeout"; stop_tree "\$CHILD"/:/'

printf '\nrea-run.selftest: %s ok, %s falha(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
