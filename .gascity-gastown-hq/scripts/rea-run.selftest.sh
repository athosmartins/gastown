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
#   (árvore morta, scratch e trava limpos, rc 143, aviso no stderr e evento `signal` no log) · timeout (124) ·
#   REMOÇÃO DA TRAVA SERIALIZADA (gate-fix 2, ga-qm9q1b): 3 chamadores escalonados contra UMA trava velha com a janela "julguei →
#   ajo" alargada por um ps lento — nunca 2 comandos pesados ao mesmo tempo, uma única remoção; mutex de remoção ocupado/sem
#   lockf = não remove (91), solto pelo kernel quando o segurador morre; release sem mutex deixa a trava; gravação do dono
#   exclusiva (a trava refeita por outro nunca é tomada nem apagada, nem na falha); mkdir que falha porque a trava sumiu tenta de
#   novo; release de trava que já não é minha não apaga; marcador de timeout privado (nada escrito dentro da trava) ·
#   scratch órfão: só o de pid MORTO é apagado (pid vivo, nome sem pid, symlink e vizinho preservados) ·
#   O ENV DE QUEM CHAMA NÃO MUDA O VEREDITO (gate-fix 4, ga-szz40p): dono vivo lido sob TZ=UTC, TZ=Asia/Tokyo e LC_ALL=pt_BR.UTF-8
#   (a string de `ps lstart` muda com eles) espera (91), nunca é reaped; ponta a ponta, A grava o dono num env e B chega noutro;
#   o swap saudável/alto lido sob vírgula decimal (pt_BR) não vira 93 ·
#   --push/--pull/--env · uso errado (94, inclusive dois --push de mesmo nome) · log sem argumentos do comando · --check ·
#   --pull no MBP que falhou (mbp-run sai 0 e só avisa): 93, nunca "chegou" · configuração numérica com zero à esquerda, sinal ou
#   estouro: 93 sem rodar (a aritmética do bash leria 08/010 como octal).
# CONTROLE NEGATIVO: cada porta (marcador "# gate:<nome>" no script: disk, swap, lock, lock-live, cleanup, fallback, timeout,
#   exit-trap, self-chain, opt-sem-valor, ilegivel-disco/swap/pgrep, pull-mbp, isnum, push-dup, e as do gate-fix 2: reap-mutex,
#   reap-rejudge, owner-claim, owner-lost, lock-vanish, release-owner, orphan-live, timeout-private, sinal-log, e as do gate-fix 4:
#   proc-start-env (testada por metade: sem TZ=UTC e sem LC_ALL=C) e sysctl-env) é removida numa cópia e
#   o mutante TEM que deixar de reproduzir o resultado do script real no caso que a protege — inclusive "ilegível virou pode-rodar".
#   O teste de concorrência também tem que FALHAR no rea-run.sh anterior ao gate-fix 2 (a corrida existia de verdade): ver o
#   comentário da seção 7b e REA_RUN_UNDER_TEST.
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
# imita o sysctl de verdade: sob LC_ALL de vírgula decimal (pt_BR, de_DE) ele imprime "3015,31M" (medido no mini, 13/10)
sep=.; case "${LC_ALL:-}" in pt_BR*|de_DE*) sep=, ;; esac
used=$(printf '%s' "${STUB_SWAP_USED:-1000.00M}" | tr . "$sep")
printf 'total = 8192%s00M  used = %s  free = 100%s00M  (encrypted)\n' "$sep" "$used" "$sep"
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
# lê o arquivo UMA vez: o teste o apaga no meio do polling, e testar-e-depois-ler dava rc 0 com saída vazia (flaky sob carga)
out=$(cat "${STUB_PGREP_FILE:-/nonexistent}" 2>/dev/null) || exit 1
if printf '%s\n' "$out" | grep -q '^ERR'; then exit 2; fi
[ -n "$out" ] || exit 1
printf '%s\n' "$out"; exit 0
EOF
cat > "$T/bin/mbp-run.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_MBP_LOG"
[ -n "${STUB_MBP_OUT:-}" ] && echo "$STUB_MBP_OUT"
# STUB_MBP_PULL=write imita o `rsync -a host:X/REL DEST` do mbp-run real: escreve o destino por arquivo temporário + rename
#   (inode novo) e CARREGA o mtime do remoto (STUB_MBP_PULL_MTIME, no passado = relógio do MBP atrasado). STUB_MBP_PULL_SKIP=REL
#   faz o pull desse REL falhar do jeito do mbp-run real: só avisa no stderr e segue — o rc continua o do comando.
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = -- ] && break
  [ "${args[$i]}" = --pull ] || continue
  pl=${args[$((i + 1))]}; rel=${pl%%:*}; dest=${pl#*:}
  if [ "${STUB_MBP_PULL:-}" != write ] || [ "${STUB_MBP_PULL_SKIP:-}" = "$rel" ]; then
    [ -n "${STUB_MBP_PULL:-}" ] && echo "pull de $rel falhou" >&2
    continue
  fi
  [ -d "$dest" ] && dest="$dest/$(basename "$rel")"
  printf 'NOVO\n' > "$dest.rsync-tmp" && touch -t "${STUB_MBP_PULL_MTIME:-200101010000}" "$dest.rsync-tmp" && mv "$dest.rsync-tmp" "$dest"
done
exit "${STUB_MBP_RC:-99}"
EOF
cat > "$T/bin/ps-slow" <<'EOF'
#!/usr/bin/env bash
# REA_RUN_PS: o ps de verdade, mas a leitura de `lstart` do pid STUB_PS_SLOW_PID demora STUB_PS_DELAY s. Alarga de forma DETERMINÍSTICA
#   a janela entre "julguei a trava velha" e "ajo sobre o caminho dela" (em produção são milissegundos que nenhum teste enxerga).
if [ -n "${STUB_PS_SLOW_PID:-}" ]; then
  case "$*" in *lstart*"-p $STUB_PS_SLOW_PID") sleep "${STUB_PS_DELAY:-1}" ;; esac
fi
exec /bin/ps "$@"
EOF
chmod +x "$T/bin/"*
# mv/ln que imitam o processo PARADO entre o mkdir e a gravação do dono: quando ele volta e grava (.../owner), a trava dele já foi
# removida e REFEITA por outro, com dono VIVO (STUB_FOREIGN_PID/START). STUB_CLAIM_MODE: real = a gravação segue sobre a trava do
# outro · fail = a gravação falha depois da troca · failclean = a gravação falha e ninguém trocou nada (erro de verdade).
mkdir -p "$T/claim" "$T/vanish"
cat > "$T/claim/stub" <<'EOF'
#!/usr/bin/env bash
base=$(basename "$0"); prev=""; last=""
for a in "$@"; do prev=$last; last=$a; done
if [ -n "${STUB_CLAIM_MODE:-}" ]; then
  case "$last" in */owner)
    [ "$STUB_CLAIM_MODE" = failclean ] && exit 1
    lock=$(dirname "$last"); body=$(cat "$prev" 2>/dev/null)
    rm -rf "$lock"; mkdir "$lock"
    printf '%s\n%s\n%s\n' "$STUB_FOREIGN_PID" "$(date +%s)" "$STUB_FOREIGN_START" > "$lock/owner"
    [ "$STUB_CLAIM_MODE" = fail ] && exit 1
    printf '%s\n' "$body" > "$prev" ;;
  esac
fi
exec "/bin/$base" "$@"
EOF
chmod +x "$T/claim/stub"; ln -s stub "$T/claim/mv"; ln -s stub "$T/claim/ln"
# mkdir que falha UMA vez no caminho da trava, sem criá-la (a trava existia e o dono soltou no meio)
cat > "$T/vanish/mkdir" <<'EOF'
#!/usr/bin/env bash
last=""; for a in "$@"; do last=$a; done
if [ "${STUB_MKDIR_FAIL_ONCE:-}" = "$last" ] && [ ! -e "$STUB_MKDIR_MARK" ]; then : > "$STUB_MKDIR_MARK"; exit 1; fi
exec /bin/mkdir "$@"
EOF
chmod +x "$T/vanish/mkdir"
N=0
reset_env() {
  N=$((N+1))
  export REA_RUN_CITY="$T/city.$N" REA_RUN_SCRATCH_ROOT="$T/scr.$N" REA_RUN_MBP_RUN="$T/bin/mbp-run.sh"
  export REA_RUN_DF="$T/bin/df" REA_RUN_SYSCTL="$T/bin/sysctl" REA_RUN_PGREP="$T/bin/pgrep"
  export REA_RUN_POLL_S=0.1 REA_RUN_KILL_GRACE_S=1 REA_RUN_WAIT_S=30 REA_RUN_TIMEOUT_S=60 REA_RUN_MIN_FREE_GB=10 REA_RUN_MAX_SWAP_MB=6144
  export STUB_MBP_LOG="$T/mbp.$N.log" STUB_PGREP_FILE="$T/pgrep.$N" MARK="$T/mark.$N"
  unset REA_RUN_LOCK_DIR STUB_PGREP_SAMPLES REA_RUN_PGREP_PATTERN STUB_DF_FAIL STUB_DF_RAW STUB_DF_KB STUB_SWAP_FAIL STUB_SWAP_RAW STUB_SWAP_USED STUB_MBP_OUT STUB_MBP_PULL STUB_MBP_PULL_SKIP STUB_MBP_PULL_MTIME REA_RUN_LOCK_ORPHAN_S REA_RUN_NICE REA_RUN_PS STUB_PS_SLOW_PID STUB_PS_DELAY REA_RUN_LOCKF REA_RUN_REAP_WAIT_S STUB_CLAIM_MODE STUB_FOREIGN_PID STUB_FOREIGN_START STUB_MKDIR_FAIL_ONCE STUB_MKDIR_MARK
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

# --pull no caminho do MBP: o mbp-run real só AVISA quando o pull falha e sai com o rc do comando (0). O wrapper confere se o
# destino chegou NESTA execução; o critério é identidade (inode+ctime+tamanho), nunca mtime: o rsync -a copia o mtime do MBP.
reset_env; export STUB_MBP_RC=0 STUB_MBP_PULL=write
run --pull "out.json:$T/pm.$N.json" -- sh -c true
eq "MBP pull chegou: rc 0" 0 "$RC"; eq "MBP pull chegou: conteúdo" NOVO "$(cat "$T/pm.$N.json" 2>/dev/null)"; has "MBP pull chegou: log sem motivo" '"mode":"mbp","rc":0,"secs":' "$(cat "$LOGF")"
has "MBP pull chegou: reason '-'" '"reason":"-"' "$(cat "$LOGF")"
reset_env; export STUB_MBP_RC=0 STUB_MBP_PULL=write STUB_MBP_PULL_MTIME=200101010000; echo VELHO > "$T/pm.$N.json"
run --pull "out.json:$T/pm.$N.json" -- sh -c true
eq "MBP pull com mtime do passado (relógio do MBP atrasado) sobre destino velho: rc 0" 0 "$RC"; eq "MBP pull sobre velho: conteúdo novo" NOVO "$(cat "$T/pm.$N.json" 2>/dev/null)"
reset_env; export STUB_MBP_RC=0 STUB_MBP_PULL=skip
run --pull "out.json:$T/pm.$N.json" -- sh -c true
eq "MBP pull que falhou (destino não existe) com comando rc 0: 93" 93 "$RC"; [ ! -e "$T/pm.$N.json" ]; ok "MBP pull falho: nada no destino" $?
has "MBP pull falho: mensagem" "pull de 'out.json' falhou" "$OUT"; has "MBP pull falho: log marca" '"mode":"mbp","rc":0' "$(cat "$LOGF")"; has "MBP pull falho: motivo" '"reason":"pull-falhou"' "$(cat "$LOGF")"
reset_env; export STUB_MBP_RC=0 STUB_MBP_PULL=skip; echo VELHO > "$T/pm.$N.json"
run --pull "out.json:$T/pm.$N.json" -- sh -c true
eq "MBP pull que falhou com destino VELHO de uma execução anterior: 93 (não lê dado velho como novo)" 93 "$RC"; eq "MBP pull falho: o velho segue lá, intocado" VELHO "$(cat "$T/pm.$N.json")"
reset_env; export STUB_MBP_RC=5 STUB_MBP_PULL=skip
run --pull "out.json:$T/pm.$N.json" -- sh -c true
eq "MBP pull falho com comando já falho: mantém o rc 5" 5 "$RC"; has "MBP pull falho + rc 5: motivo" '"reason":"pull-falhou"' "$(cat "$LOGF")"
reset_env; export STUB_MBP_RC=0 STUB_MBP_PULL=write STUB_MBP_PULL_SKIP=b.json
run --pull "a.json:$T/pa.$N.json" --pull "b.json:$T/pb.$N.json" -- sh -c true
eq "MBP 2 pulls, só o 2º falhou: 93 (confere todos, não só o primeiro)" 93 "$RC"; [ -f "$T/pa.$N.json" ]; ok "MBP 2 pulls: o 1º chegou" $?
has "MBP 2 pulls: mensagem cita o que falhou" "pull de 'b.json' falhou" "$OUT"
reset_env; export STUB_MBP_RC=0 STUB_MBP_PULL=write; mkdir "$T/pd.$N"; echo VELHO > "$T/pd.$N/out.json"
run --pull "out.json:$T/pd.$N" -- sh -c true
eq "MBP pull para dentro de diretório existente (arquivo trocado por rename): rc 0" 0 "$RC"; eq "MBP pull em diretório: conteúdo novo" NOVO "$(cat "$T/pd.$N/out.json")"
reset_env; export STUB_MBP_RC=0 STUB_MBP_PULL=skip; mkdir "$T/pd.$N"; echo VELHO > "$T/pd.$N/out.json"
run --pull "out.json:$T/pd.$N" -- sh -c true
eq "MBP pull para diretório que ninguém tocou: 93" 93 "$RC"
reset_env; export STUB_MBP_RC=98 STUB_MBP_PULL=skip
run --pull "out.json:$T/pm.$N.json" -- sh -c 'echo x > out.json'
eq "MBP rc 98 + --pull: roda no mini e o pull local chega (rc 0)" 0 "$RC"; [ -f "$T/pm.$N.json" ]; ok "MBP rc 98 + --pull: destino veio do mini" $?
has "MBP rc 98: o aviso diz que o comando pode já ter rodado no MBP" "pode já ter rodado" "$OUT"
reset_env; export STUB_MBP_RC=96; run -- true; case "$OUT" in *"pode já ter rodado"*) ok "MBP rc 96: sem o aviso de 'pode já ter rodado' (recusou antes de rodar)" 1 ;; *) ok "MBP rc 96: sem o aviso de 'pode já ter rodado'" 0 ;; esac

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
# mesmo formato que o proc_start do script grava no dono: TZ=UTC e locale C (a hora de início não pode depender do env de quem lê)
pstart() { LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | sed 's/  */ /g;s/^ //;s/ $//'; }
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

# ---- 7b. a remoção da trava é serializada e re-julgada DENTRO do mutex (gate-fix 2) ------------------------------------------
# O reap era check-then-act: julgava UMA trava velha e depois movia o que estivesse no caminho NA HORA — a trava nova e viva que outro
# chamador acabara de criar. Aqui o ps de `lstart` do dono morto demora (alarga julgar→agir, em produção milissegundos) e três
# chamadores entram escalonados (0, 0,5 e 1 s) contra UMA trava velha: quem julga primeiro já refez a trava (viva) quando o seguinte age.
conc_peak() { awk '$1=="+"{n++; if(n>m)m=n} $1=="-"{n--} END{print m+0}' "$1"; }   # pico de comandos pesados ao mesmo tempo
probe_reap_conc() { # script → "pico=<m> rcs=<rc,rc,rc,> reaps=<k>"
  reset_env
  local C="$T/conc.$N" E="$T/conc-err.$N" p pids="" rcs=""
  : > "$C"; : > "$E"; mklock 999999 "Mon Jan  1 00:00:00 2001"
  export REA_RUN_PS="$T/bin/ps-slow" STUB_PS_SLOW_PID=999999 STUB_PS_DELAY=1.2
  for _ in 1 2 3; do
    "$1" --local -- sh -c "echo + >> '$C'; sleep 2; echo - >> '$C'" >/dev/null 2>>"$E" & pids="$pids $!"
    sleep 0.5
  done
  BGPIDS="$BGPIDS$pids"
  for p in $pids; do wait "$p"; rcs="$rcs$?,"; done
  echo "pico=$(conc_peak "$C") rcs=$rcs reaps=$(grep -c 'trava órfã removida' "$E")"
}
OUT=$(probe_reap_conc "$RUN")
has "reap concorrente (3 chamadores × 1 trava velha): NUNCA 2 comandos pesados ao mesmo tempo" "pico=1 " "$OUT"
has "reap concorrente: todos terminam, rc 0 (os que perdem esperam, não falham com 93)" "rcs=0,0,0," "$OUT"
has "reap concorrente: uma única remoção da órfã" "reaps=1" "$OUT"

hold_reap_mutex() { # segura o mutex de reap num processo à parte (HOLDER); o mutex é do kernel: some quando ele morre, KILL inclusive
  local fifo="$T/fifo.$N" held="$T/held.$N"; rm -f "$fifo" "$held"; mkfifo "$fifo"
  bash -c 'exec 8>>"$1"; lockf -s -t 0 8 || exit 3; echo held > "$3"; exec 7<>"$2"; read -t 60 -u 7 _' _ "$LOCK.reap" "$fifo" "$held" &
  HOLDER=$!; BGPIDS="$BGPIDS $HOLDER"
  for _ in $(seq 1 50); do [ -s "$held" ] && break; sleep 0.1; done
  [ -s "$held" ]
}
reset_env; export REA_RUN_REAP_WAIT_S=1; mklock 999999 "Mon Jan  1 00:00:00 2001"
hold_reap_mutex; ok "mutex de reap: segurador no ar" $?
run --local --wait-s 2 -- sh -c "echo x > '$MARK'"
eq "órfã + mutex de reap ocupado: NÃO remove às cegas (91)" 91 "$RC"; [ ! -e "$MARK" ]; ok "mutex ocupado: comando NÃO rodou" $?
eq "mutex ocupado: a trava velha segue lá, intocada" 999999 "$(sed -n 1p "$LOCK/owner" 2>/dev/null)"
has "mutex ocupado: a mensagem diz por quê" "mutex de reap" "$OUT"; has "mutex ocupado: motivo" '"reason":"trava-ocupada"' "$(cat "$LOGF")"
kill -KILL "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
run --local -- sh -c "echo x > '$MARK'"
eq "segurador do mutex morreu (SIGKILL): o kernel soltou e a próxima execução remove a órfã" 0 "$RC"
has "mutex solto pelo kernel: órfã removida" "trava órfã removida" "$OUT"; [ -e "$MARK" ]; ok "mutex solto: comando rodou" $?; clean_after "mutex solto"
reset_env; mklock 999999 "Mon Jan  1 00:00:00 2001"; REA_RUN_LOCKF="$T/nao-existe/lockf" run --local --wait-s 1 -- sh -c "echo x > '$MARK'"
eq "sem lockf: a órfã NÃO é removida (91) — 'não sei' nunca vira 'pode remover'" 91 "$RC"; [ ! -e "$MARK" ]; ok "sem lockf: comando NÃO rodou" $?
eq "sem lockf: a trava velha segue lá" 999999 "$(sed -n 1p "$LOCK/owner" 2>/dev/null)"
# solto o dono: sem o mutex a trava FICA (o dono morto a torna órfã) e a próxima execução a remove
reset_env; export REA_RUN_REAP_WAIT_S=1; hold_reap_mutex; ok "release: segurador no ar" $?
run --local -- true
eq "release sem mutex: o rc é o do comando (0)" 0 "$RC"; has "release sem mutex: avisa" "sem o mutex de reap" "$OUT"; [ -d "$LOCK" ]; ok "release sem mutex: a trava fica (dono morto)" $?
kill -KILL "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
run --local -- sh -c "echo x > '$MARK'"; eq "release sem mutex: a próxima execução remove a órfã e roda" 0 "$RC"; has "...e avisa" "trava órfã removida" "$OUT"; clean_after "pós release sem mutex"

# gravar o dono da trava: o processo parado entre o mkdir e a gravação volta DEPOIS de a trava dele ter sido removida e refeita por
# outro (dono vivo). O `mv` antigo sobrescrevia o dono do outro; o erro apagava a trava do outro. Agora a gravação é `ln` (exclusiva).
sleep 60 >/dev/null 2>&1 & foreign=$!; BGPIDS="$BGPIDS $foreign"; fstart=$(pstart "$foreign")
for mode in real fail; do
  reset_env; export STUB_CLAIM_MODE=$mode STUB_FOREIGN_PID=$foreign STUB_FOREIGN_START="$fstart"
  PATH="$T/claim:$PATH" run --local --wait-s 1 -- sh -c "echo x > '$MARK'"
  eq "dono: gravação perdida ($mode) — espera como os demais (91), não toma nem apaga a trava do outro" 91 "$RC"
  [ ! -e "$MARK" ]; ok "dono ($mode): comando NÃO rodou" $?
  eq "dono ($mode): o dono do outro segue na trava" "$foreign" "$(sed -n 1p "$LOCK/owner" 2>/dev/null)"
done
reset_env; export STUB_CLAIM_MODE=failclean
PATH="$T/claim:$PATH" run --local -- sh -c "echo x > '$MARK'"
eq "dono: falha de verdade ao gravar (ninguém trocou nada): 93" 93 "$RC"; has "dono: falha real — motivo" '"reason":"trava-sem-dono"' "$(cat "$LOGF")"
[ ! -e "$LOCK" ]; ok "dono: falha real não deixa trava vazia" $?; [ ! -e "$MARK" ]; ok "dono: falha real — comando NÃO rodou" $?
# o mkdir da trava falha porque existia e o dono soltou logo depois: tenta de novo, não é "trava não criável"
reset_env; export STUB_MKDIR_FAIL_ONCE="$LOCK" STUB_MKDIR_MARK="$T/mk.$N"; rm -f "$STUB_MKDIR_MARK"
PATH="$T/vanish:$PATH" run --local -- sh -c "echo x > '$MARK'"
eq "mkdir falhou e a trava já não existe (o dono soltou): tenta de novo, rc 0" 0 "$RC"; [ -e "$MARK" ]; ok "mkdir que sumiu: comando rodou" $?; clean_after "mkdir que sumiu"
# release: a trava que já não é minha NÃO é apagada
reset_env; takeover="printf '%s\n%s\n%s\n' $foreign 1 '$fstart' > '$LOCK/o.new' && mv -f '$LOCK/o.new' '$LOCK/owner'"
run --local -- sh -c "$takeover"
eq "release: rc do comando" 0 "$RC"; has "release: a trava já não é minha" "já não é minha" "$OUT"
eq "release: a trava do outro segue lá" "$foreign" "$(sed -n 1p "$LOCK/owner" 2>/dev/null)"
# o marcador de timeout não vai para dentro da trava (que pode já ser de outro): a trava só tem o dono
reset_env; export REA_RUN_TIMEOUT_S=1; takeover="printf '%s\n%s\n%s\n' $foreign 1 '$fstart' > '$LOCK/o.new' && mv -f '$LOCK/o.new' '$LOCK/owner'"
run --local -- sh -c "$takeover; ls -A '$LOCK' | tr '\n' ' ' > '$T/seen.$N'; sleep 20"
eq "timeout com a trava trocada: rc 124 (o marcador é privado)" 124 "$RC"
eq "timeout: nada além do dono do outro dentro da trava dele (visto de dentro do comando)" "owner" "$(sed 's/ $//' "$T/seen.$N" 2>/dev/null)"
eq "timeout: a trava do outro segue lá depois" "$foreign" "$(sed -n 1p "$LOCK/owner" 2>/dev/null)"
rm -rf "$LOCK"

# ---- 7c. o dono da trava é identificado por um formato FIXO, não pelo env de quem lê (gate-fix 4, ga-szz40p) ----------------
# O dono grava a hora de início do processo (ps lstart) e quem chega compara a STRING. Ela muda com TZ e locale de quem chama: o mesmo
# pid dá "Tue Oct 13 06:24:05 2026" (TZ do mini), "Tue Oct 13 09:24:05 2026" (TZ=UTC) e "ter 13 out 06:24:05 2026" (LC_ALL=pt_BR.UTF-8).
# Sem o env fixado, um 2º chamador de env diferente lia "início diferente" = pid reaproveitado, tomava a trava de um dono VIVO e rodava
# um 2º comando pesado ao mesmo tempo — o que a trava existe para impedir. Aqui o env difere DE PROPÓSITO e o dono vivo tem que ser
# respeitado (91, nada roda, trava intacta). Os testes TÊM que falhar no rea-run.sh sem o env fixado (REA_RUN_UNDER_TEST).
ps_env() { env $1 ps -o lstart= -p "$2" 2>/dev/null | sed 's/  */ /g;s/^ //;s/ $//'; }   # $1 = "VAR=x VAR2=y" (sem aspas: vira vários argumentos)
sleep 60 & holder=$!; BGPIDS="$BGPIDS $holder"
SWAP_PONTO='total = 8192.00M  used = 1000.00M  free = 100.00M  (encrypted)'   # swap em formato fixo: aqui só a TRAVA está em teste (o swap tem os casos dele, abaixo)
for e in "TZ=Asia/Tokyo" "TZ=America/New_York" "LC_ALL=pt_BR.UTF-8" "LC_ALL=pt_BR.UTF-8 TZ=Asia/Tokyo"; do
  [ "$(ps_env "$e" "$holder")" != "$(pstart "$holder")" ]; ok "pré-condição: sob $e o ps mostra OUTRA string da hora de início (senão o caso não prova nada)" $?
  reset_env; export STUB_SWAP_RAW="$SWAP_PONTO"; mklock "$holder" "$(pstart "$holder")"
  OUT=$(env $e "$RUN" --local --wait-s 1 -- sh -c "echo x > '$MARK'" 2>&1); RC=$?
  eq "dono vivo lido sob $e: espera (91), não reaps" 91 "$RC"; [ ! -e "$MARK" ]; ok "dono vivo sob $e: comando NÃO rodou" $?
  eq "dono vivo sob $e: trava intacta" "$holder" "$(sed -n 1p "$LOCK/owner" 2>/dev/null)"; has "dono vivo sob $e: motivo" '"reason":"trava-ocupada"' "$(cat "$LOGF")"
  case "$OUT" in *"trava órfã removida"*) ok "dono vivo sob $e: sem 'trava órfã removida'" 1 ;; *) ok "dono vivo sob $e: sem 'trava órfã removida'" 0 ;; esac
done
kill "$holder" 2>/dev/null
# ponta a ponta: A é um rea-run de verdade (grava o dono com o env DELE) e B chega com outro env — o que roda em produção é cron/agente × shell
cross_env() { # script envA envB — A segura a trava e roda; B espera 1 s e NÃO pode tomá-la
  local s=$1 ea=$2 eb=$3 a o own
  reset_env; export STUB_SWAP_RAW="$SWAP_PONTO"; rm -f "$MARK.a"
  env $ea "$s" --local -- sh -c "echo a > '$MARK.a'; sleep 30" >/dev/null 2>&1 & a=$!; BGPIDS="$BGPIDS $a"
  for _ in $(seq 1 50); do [ -s "$MARK.a" ] && break; sleep 0.1; done
  o=$(env $eb "$s" --local --wait-s 1 -- sh -c "echo b > '$MARK'" 2>&1); local rc=$?
  own=$(sed -n 1p "$LOCK/owner" 2>/dev/null)
  kill -TERM "$a" 2>/dev/null; wait "$a" 2>/dev/null
  echo "$rc|$([ -e "$MARK" ] && echo B-rodou || echo B-parou)|dono=$([ "$own" = "$a" ] && echo A || echo outro)"
}
for pair in "REA_RUN_X=1|TZ=UTC" "TZ=Asia/Tokyo|TZ=UTC" "LC_ALL=C|LC_ALL=pt_BR.UTF-8" "LC_ALL=pt_BR.UTF-8 TZ=Asia/Tokyo|LC_ALL=C TZ=UTC"; do
  ea=${pair%%|*}; eb=${pair##*|}
  [ "$(ps_env "$ea" $$)" != "$(ps_env "$eb" $$)" ]; ok "pré-condição: A[$ea] e B[$eb] veem strings DIFERENTES da mesma hora de início" $?
  eq "A[$ea] segura, B[$eb] chega: B espera (91), não roda, o dono segue sendo A" "91|B-parou|dono=A" "$(cross_env "$RUN" "$ea" "$eb")"
done
# o outro lado da mesma moeda: sysctl vm.swapusage imprime "3015,31M" sob LC_ALL de vírgula decimal; o parser lia isso como ilegível (93)
# mesmo com a máquina saudável. A leitura também não pode depender do env de quem chama.
reset_env; case "$(LC_ALL=pt_BR.UTF-8 "$T/bin/sysctl" -n vm.swapusage)" in *,*) ok "stub do sysctl imita a vírgula decimal de pt_BR" 0 ;; *) ok "stub do sysctl imita a vírgula decimal de pt_BR" 1 ;; esac
reset_env; export STUB_SWAP_USED=1000.50M; OUT=$(LC_ALL=pt_BR.UTF-8 "$RUN" --local -- sh -c "echo x > '$MARK'" 2>&1); RC=$?
eq "swap saudável lido sob LC_ALL=pt_BR (vírgula): roda (0), não vira 93" 0 "$RC"; [ -e "$MARK" ]; ok "swap sob pt_BR: comando rodou" $?
reset_env; export STUB_SWAP_USED=7000.50M; OUT=$(LC_ALL=pt_BR.UTF-8 "$RUN" --local -- sh -c "echo x > '$MARK'" 2>&1); RC=$?
eq "swap alto lido sob LC_ALL=pt_BR: recusa pelo MOTIVO certo (92, não 93)" 92 "$RC"; [ ! -e "$MARK" ]; ok "swap alto sob pt_BR: comando NÃO rodou" $?; has "swap alto sob pt_BR: motivo" "swap-alto" "$(cat "$LOGF")"

# ---- 8. sinal e timeout -----------------------------------------------------------------------------------------------
reset_env; PIDF="$T/gpid.$N"
"$RUN" --local -- sh -c "sleep 60 & echo \$! > '$PIDF'; wait" >/dev/null 2>"$T/sigerr.$N" & w=$!; BGPIDS="$BGPIDS $w"
for _ in $(seq 1 50); do [ -s "$PIDF" ] && break; sleep 0.1; done
gp=$(cat "$PIDF" 2>/dev/null); kill -0 "$gp" 2>/dev/null; ok "SIGTERM: neto vivo antes do sinal" $?
kill -TERM "$w"; wait "$w"; rc=$?
eq "SIGTERM: rc 143" 143 "$rc"
has "SIGTERM: o aviso do handler chega ao stderr (não é engolido pelo wait)" "recebi SIGTERM" "$(cat "$T/sigerr.$N" 2>/dev/null)"
has "SIGTERM: a execução cortada deixa UM evento no log" '"event":"signal","mode":"local","rc":143' "$(cat "$LOGF" 2>/dev/null)"
has "SIGTERM: motivo no log" '"reason":"sinal-term"' "$(cat "$LOGF" 2>/dev/null)"
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
# órfão = o nome traz o pid de quem o criou (run.<pid>.XXXXXX, tmo.<pid>) e esse pid morreu. Scratch de execução VIVA, de nome sem pid ou
# symlink NUNCA é apagado: o varredor não pode depender de a trava ter dado exclusividade (era o que apagava o scratch vivo do outro).
reset_env; R="$REA_RUN_SCRATCH_ROOT"
mkdir -p "$R/run.999999.OLD" "$R/run.$foreign.LIVE" "$R/run.SEMPID" "$R/keepme" "$T/victim.$N"
echo captura > "$R/run.999999.OLD/cap.json"; echo viva > "$R/run.$foreign.LIVE/cap.json"; echo s > "$R/run.SEMPID/s"; echo v > "$T/victim.$N/arquivo"; echo k > "$R/keepme/k"
: > "$R/tmo.999999"; : > "$R/tmo.$foreign"
ln -s "$T/victim.$N" "$R/run.999998.LINK"; chmod -R go-rwx "$R"
run --local -- true
eq "órfão: rc 0" 0 "$RC"; [ ! -e "$R/run.999999.OLD" ]; ok "órfão de pid morto (run.999999.OLD) apagado" $?
[ -f "$R/run.$foreign.LIVE/cap.json" ]; ok "scratch de execução VIVA (pid $foreign) NÃO é apagado" $?
[ -f "$R/run.SEMPID/s" ]; ok "nome sem pid (run.SEMPID): preservado" $?; has "nome sem pid: avisa" "não traz o pid" "$OUT"
[ ! -e "$R/tmo.999999" ]; ok "marcador de timeout de pid morto apagado" $?; [ -e "$R/tmo.$foreign" ]; ok "marcador de timeout de pid vivo preservado" $?
[ -f "$T/victim.$N/arquivo" ]; ok "symlink run.999998.LINK: alvo NÃO apagado" $?
[ -L "$R/run.999998.LINK" ]; ok "symlink run.999998.LINK: preservado e avisado" $?; has "symlink: aviso" "symlink" "$OUT"
[ -f "$R/keepme/k" ]; ok "vizinho fora de run.* intacto" $?
kill "$foreign" 2>/dev/null

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
reset_env; mkdir -p "$T/da.$N" "$T/db.$N"; echo 1 > "$T/da.$N/x.txt"; echo 2 > "$T/db.$N/x.txt"
run --local --push "$T/da.$N/x.txt" --push "$T/db.$N/x.txt" -- true; eq "uso: dois --push com o mesmo nome = 94 (um sobrescreveria o outro em ./in/)" 94 "$RC"
export STUB_MBP_RC=0; run --push "$T/da.$N/x.txt" --push "$T/db.$N/x.txt" -- true; eq "uso: mesmo nome também recusado no caminho do MBP" 94 "$RC"; eq "uso: ...e o mbp-run nem foi chamado" 0 "$(mbp_calls)"
reset_env; mkdir -p "$T/da.$N" "$T/db.$N"; echo 1 > "$T/da.$N/x.txt"; echo 2 > "$T/db.$N/y.txt"
run --local --push "$T/da.$N/x.txt" --push "$T/db.$N/y.txt" -- sh -c 'cat in/x.txt in/y.txt > out.txt' ; eq "uso: dois --push de nomes diferentes passam" 0 "$RC"
reset_env; run --local --env "1BAD=x" -- true;           eq "uso: --env inválido = 94" 94 "$RC"
reset_env; REA_RUN_MIN_FREE_GB=abc run --local -- true;  eq "config: limite não numérico = 93" 93 "$RC"
# número com zero à esquerda: o `[ -ge ]` o aceita, mas a aritmética do bash o lê como OCTAL (08/09 estouram, 010 vale 8) e o
# disco "sem folga" virava "com folga". Idem estouro de int64 na conta GB→KB. Tudo isso é configuração inválida = 93, sem rodar.
for spec in REA_RUN_MIN_FREE_GB=08 REA_RUN_MIN_FREE_GB=09 REA_RUN_MIN_FREE_GB=010 REA_RUN_MIN_FREE_GB=0999 REA_RUN_MIN_FREE_GB=00 \
            REA_RUN_MIN_FREE_GB=+5 REA_RUN_MIN_FREE_GB=99999999999999 REA_RUN_MIN_FREE_GB=9223372036854775807 REA_RUN_MAX_SWAP_MB=09 \
            REA_RUN_WAIT_S=08 REA_RUN_TIMEOUT_S=010 REA_RUN_KILL_GRACE_S=08 REA_RUN_LOCK_ORPHAN_S=08 REA_RUN_NICE=08; do
  reset_env; export "$spec"; run --local -- sh -c "echo x > '$MARK'"
  eq "config: $spec = 93" 93 "$RC"; [ ! -e "$MARK" ]; ok "config $spec: comando NÃO rodou" $?; has "config $spec: mensagem" "configuração inválida" "$OUT"
  case "$OUT" in *"value too great"*|*"unbound variable"*|*"syntax error"*) ok "config $spec: sem erro de aritmética do bash" 1 ;; *) ok "config $spec: sem erro de aritmética do bash" 0 ;; esac
done
reset_env; run --local --wait-s 08 -- true;              eq "config: --wait-s 08 = 93" 93 "$RC"
reset_env; run --check --wait-s 09;                      eq "config: --check também valida (93)" 93 "$RC"
reset_env; export REA_RUN_MIN_FREE_GB=0 STUB_DF_KB=1; run --local -- sh -c "echo x > '$MARK'"
eq "config: MIN_FREE_GB=0 é válido (desliga o piso de disco)" 0 "$RC"; [ -e "$MARK" ]; ok "MIN_FREE_GB=0: comando rodou" $?
reset_env; export REA_RUN_MIN_FREE_GB=999999999999 STUB_DF_KB=20971520; run --local -- sh -c "echo x > '$MARK'"
eq "config: MIN_FREE_GB com 12 dígitos é válido e recusa (92), sem estourar a conta" 92 "$RC"; [ ! -e "$MARK" ]; ok "12 dígitos: comando NÃO rodou" $?
reset_env; export REA_RUN_MIN_FREE_GB=9; export STUB_DF_KB=9437184; run --local -- sh -c "echo x > '$MARK'"; eq "config: MIN_FREE_GB=9 (9 GB exatos) passa" 0 "$RC"
reset_env; export STUB_DF_RAW='Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 1 1 0123 1% /'; run --local -- true
eq "df com 'disponível' de zero à esquerda: ilegível = 93" 93 "$RC"
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
# A segura a trava por 3 s; B chega (só depois de A ter a trava) com --wait-s 1. Com o mkdir exclusivo B desiste em 91 sem rodar. Sem ele (`mkdir -p`
# sempre "consegue"), B cai no laço de gravação do dono, que não tem prazo: sai quando A solta — rodando (0) ou com 93 —, nunca em 91. O probe
# antigo comparava a ORDEM A/B e dependia de uma corrida (o spin de B contra o release de A): o mutante saía idêntico ao real em ~1 de 4 rodadas.
probe_lock() { reset_env; local am="$T/mlock-a.$N" r
  "$1" --local -- sh -c "echo a > '$am'; sleep 3" >/dev/null 2>&1 & local a=$!
  for _ in $(seq 1 50); do [ -s "$am" ] && break; sleep 0.1; done
  RUN="$1" run --local --wait-s 1 -- sh -c "echo x > '$MARK'"
  r="$RC|$([ -e "$MARK" ] && echo B-rodou || echo B-parou)"; wait $a 2>/dev/null; echo "$r"; }
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
probe_pull_mbp() { reset_env; export STUB_MBP_RC=0 STUB_MBP_PULL=skip; RUN="$1" run --pull "out.json:$T/pm.$N.json" -- sh -c true; echo "$RC|$(grep -c pull-falhou "$LOGF" 2>/dev/null)"; }
probe_isnum() { reset_env; export REA_RUN_MIN_FREE_GB=0999; RUN="$1" run --local -- sh -c "echo x > '$MARK'"; echo "$RC|$([ -e "$MARK" ] && echo rodou || echo parou)"; }
probe_dup_push() { reset_env; mkdir -p "$T/da.$N" "$T/db.$N"; echo 1 > "$T/da.$N/x.txt"; echo 2 > "$T/db.$N/x.txt"; RUN="$1" run --local --push "$T/da.$N/x.txt" --push "$T/db.$N/x.txt" -- true; echo "$RC"; }
mutant_check pull-mbp probe_pull_mbp '/# gate:pull-mbp/s/if \[ -n "\$pull_missing" \]/if false/'
mutant_check isnum probe_isnum '/# gate:isnum/s/.*/isnum() { [ "$1" -ge 0 ] 2>\/dev\/null; }/'
mutant_check push-dup probe_dup_push '/# gate:push-dup/s/exit 94/:/'
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
mutant_check timeout probe_timeout '/# gate:timeout/s/echo 1 > "\$TMO"; stop_tree "\$CHILD"/:/'

# ---- portas novas do gate-fix 2: reap/release sob mutex, gravação exclusiva do dono, varredor de órfãos, marcador privado ----
probe_conc() { probe_reap_conc "$1"; }
probe_mutex_held() { reset_env; export REA_RUN_REAP_WAIT_S=1; mklock 999999 "Mon Jan  1 00:00:00 2001"; hold_reap_mutex
  RUN="$1" run --local --wait-s 2 -- sh -c "echo x > '$MARK'"; kill -KILL "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
  echo "$RC|$([ -e "$MARK" ] && echo rodou || echo parou)"; }
probe_claim() { # $1 = script · $2 = modo (real|fail)
  reset_env; sleep 60 >/dev/null 2>&1 & local f=$!; BGPIDS="$BGPIDS $f"
  export STUB_CLAIM_MODE=$2 STUB_FOREIGN_PID=$f STUB_FOREIGN_START="$(pstart "$f")"
  PATH="$T/claim:$PATH" RUN="$1" run --local --wait-s 1 -- sh -c "echo x > '$MARK'"
  local own; own=$([ "$(sed -n 1p "$LOCK/owner" 2>/dev/null)" = "$f" ] && echo dono-do-outro || echo dono-trocado); kill "$f" 2>/dev/null
  echo "$RC|$own|$([ -e "$MARK" ] && echo rodou || echo parou)"; }
probe_claim_real() { probe_claim "$1" real; }
probe_claim_fail() { probe_claim "$1" fail; }
probe_vanish() { reset_env; export STUB_MKDIR_FAIL_ONCE="$LOCK" STUB_MKDIR_MARK="$T/mkv.$N"; rm -f "$STUB_MKDIR_MARK"
  PATH="$T/vanish:$PATH" RUN="$1" run --local -- sh -c "echo x > '$MARK'"; echo "$RC|$([ -e "$MARK" ] && echo rodou || echo parou)"; }
probe_release_takeover() { reset_env; sleep 60 >/dev/null 2>&1 & local f=$!; BGPIDS="$BGPIDS $f"; local fs; fs=$(pstart "$f")
  RUN="$1" run --local -- sh -c "printf '%s\n%s\n%s\n' $f 1 '$fs' > '$LOCK/o.new' && mv -f '$LOCK/o.new' '$LOCK/owner'"
  local own=ausente; [ "$(sed -n 1p "$LOCK/owner" 2>/dev/null)" = "$f" ] && own=do-outro; kill "$f" 2>/dev/null; rm -rf "$LOCK"
  echo "$RC|trava=$own"; }
probe_orphan_live() { reset_env; sleep 60 >/dev/null 2>&1 & local f=$!; BGPIDS="$BGPIDS $f"; local R="$REA_RUN_SCRATCH_ROOT"
  mkdir -p "$R/run.$f.LIVE"; echo viva > "$R/run.$f.LIVE/cap.json"; chmod -R go-rwx "$R"
  RUN="$1" run --local -- true; local v=apagado; [ -f "$R/run.$f.LIVE/cap.json" ] && v=intacto; kill "$f" 2>/dev/null
  echo "$RC|scratch-vivo=$v"; }
probe_timeout_private() { reset_env; export REA_RUN_TIMEOUT_S=1; sleep 60 >/dev/null 2>&1 & local f=$!; BGPIDS="$BGPIDS $f"; local fs; fs=$(pstart "$f")
  RUN="$1" run --local -- sh -c "printf '%s\n%s\n%s\n' $f 1 '$fs' > '$LOCK/o.new' && mv -f '$LOCK/o.new' '$LOCK/owner'; ls -A '$LOCK' | tr '\n' ' ' > '$T/seen.$N'; sleep 20"
  local ls_; ls_=$(sed 's/ $//' "$T/seen.$N" 2>/dev/null); kill "$f" 2>/dev/null; rm -rf "$LOCK"
  echo "$RC|lock=[$ls_]"; }
probe_sinal_log() { reset_env; local pf="$T/sl.$N"
  "$1" --local -- sh -c "sleep 30 & echo \$! > '$pf'; wait" >/dev/null 2>&1 & local w=$!
  for _ in $(seq 1 50); do [ -s "$pf" ] && break; sleep 0.1; done
  kill -TERM "$w"; wait "$w" 2>/dev/null; local rc=$?; sleep 0.3
  local gp; gp=$(cat "$pf" 2>/dev/null); kill -KILL "$gp" 2>/dev/null
  echo "$rc|signal-no-log=$(grep -c '"event":"signal"' "$LOGF" 2>/dev/null)"; }
mutant_check reap-mutex probe_conc '/# gate:reap-mutex/s/if "\$LOCKF_BIN" -s -t "\$REAP_WAIT_S" 8 2>\/dev\/null; then/if true; then/'
mutant_check reap-mutex-ocupado probe_mutex_held '/# gate:reap-mutex/s/if "\$LOCKF_BIN" -s -t "\$REAP_WAIT_S" 8 2>\/dev\/null; then/if true; then/'
mutant_check reap-rejudge probe_conc '/# gate:reap-rejudge/s/if \[ "\$(lock_state)" = stale \]; then/if true; then/'
mutant_check owner-claim probe_claim_real '/# gate:owner-claim/s/ln "\$tmp"/mv -f "$tmp"/'
mutant_check owner-lost probe_claim_fail '/# gate:owner-lost/s/\[ -e "\$LOCK_DIR\/owner" \] \&\& continue/false/'
mutant_check lock-vanish probe_vanish '/# gate:lock-vanish/s/.*/      die 93 "trava-nao-criavel" "mutante"/'
mutant_check release-owner probe_release_takeover '/# gate:release-owner/s/if \[ "\$(owner_field 1)" = "\$\$" \]; then/if true; then/'
mutant_check orphan-live probe_orphan_live '/# gate:orphan-live/s/alive "\$opid" \&\& continue/:/'
mutant_check timeout-private probe_timeout_private '/# gate:timeout-private/s/TMO="\$SCRATCH_ROOT\/tmo.\$\$"/TMO="$LOCK_DIR\/timeout"/'
mutant_check sinal-log probe_sinal_log '/# gate:sinal-log/s/.*/  :/'

# ---- portas novas do gate-fix 4: a hora de início do dono e a leitura do swap não dependem do env de quem chama ----------------
# Uma porta por metade do env fixado: tirar só TZ=UTC ou só LC_ALL=C já tem que reaparecer como trava de dono vivo tomada.
probe_ps_tz() { cross_env "$1" "TZ=Asia/Tokyo" "TZ=UTC"; }
probe_ps_lc() { cross_env "$1" "LC_ALL=C" "LC_ALL=pt_BR.UTF-8"; }
probe_swap_locale() { reset_env; export STUB_SWAP_USED=1000.50M; OUT=$(LC_ALL=pt_BR.UTF-8 "$1" --local -- sh -c "echo x > '$MARK'" 2>&1); RC=$?
  echo "$RC|$([ -e "$MARK" ] && echo rodou || echo parou)"; }
mutant_check proc-start-tz probe_ps_tz '/# gate:proc-start-env/s/ TZ=UTC//'
mutant_check proc-start-lc probe_ps_lc '/# gate:proc-start-env/s/LC_ALL=C //'
mutant_check sysctl-env probe_swap_locale '/# gate:sysctl-env/s/LC_ALL=C //'

printf '\nrea-run.selftest: %s ok, %s falha(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
