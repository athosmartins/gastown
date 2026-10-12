#!/usr/bin/env bash
# mbp-run.selftest.sh — hermético: ssh/rsync são stubs no PATH; nada toca o MBP nem o live.
#
# Contents
#   Casos · Preflight de saúde (ga-9e2rjh) · Controle negativo
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
case "$name" in
  PREFLIGHT)
    if [ -n "${STUB_PF_RAW:-}" ]; then printf '%b\n' "$STUB_PF_RAW"; else
      rm -f "$STUB_SWAPCNT"; sample=""
      case "$args" in *"bash -s -- "*) sample=${args##*bash -s -- } ;; esac
      printf '%s\n' "$s" | PATH="$FAKE:$PATH" "$STUB_REMOTE_BASH" -s -- $sample
    fi ;;
  SLOT_ACQUIRE)
    if [ "${STUB_SLOTS:-free}" = full ]; then
      echo "BUSY 1 otherhost:11:$(date +%s) 0"; echo "BUSY 2 otherhost:12:$(date +%s) 0"; echo "BUSY 3 otherhost:13:$(date +%s) 0"; echo FULL; exit 3
    elif [ "${STUB_SLOTS:-free}" = dead ] && [ ! -f "$STUB_REAPED" ]; then
      h=$(hostname -s); echo "BUSY 1 $h:999999:$(date +%s) 0"; echo "BUSY 2 otherhost:12:$(date +%s) 0"; echo "BUSY 3 otherhost:13:$(date +%s) 0"; echo FULL; exit 3
    else echo "SLOT=1"; fi ;;
  SLOT_REAP) touch "$STUB_REAPED" ;;
  MIRROR) if [ "${STUB_NOBASE:-0}" = 1 ]; then echo NOBASE; exit 97; else echo MIRROR_OK; fi ;;
  RUN) [ "${STUB_RUN_RC:-0}" = 255 ] && exit 255; echo "${STUB_RUN_OUT:-stub-run-ok}"; exit "${STUB_RUN_RC:-0}" ;;
  EXEC) echo "stub-exec-ok"; exit "${STUB_RUN_RC:-0}" ;;
  DIRECT) echo "DIRECT:$args" >> "$STUB_LOG" ;;
esac
exit 0
EOF
cat > "$T/bin/rsync" <<'EOF'
#!/usr/bin/env bash
echo "RSYNC:$*" >> "$STUB_LOG"; exit "${STUB_RSYNC_RC:-0}"
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
[ "${STUB_PMSET_FAIL:-0}" = 1 ] && exit 1
[ -n "${STUB_PMSET_RAW:-}" ] && { printf '%s\n' "$STUB_PMSET_RAW"; exit 0; }
if [ "${STUB_POWER:-ac}" = ac ]; then src="AC Power"; else src="Battery Power"; fi
printf "Now drawing from '%s'\n -InternalBattery-0 (id=1)\t%s%%; discharging; 3:00 remaining present: true\n" "$src" "${STUB_BATT:-90}"
EOF
cat > "$T/fake/sleep" <<'EOF'
#!/usr/bin/env bash
echo "SLEEP:$*" >> "$STUB_LOG"
EOF
chmod +x "$T/bin/ssh" "$T/bin/rsync" "$T/fake/"*

unset MBP_MAX_SWAP_MB MBP_MAX_SWAP_GROWTH_MB MBP_SWAP_SAMPLE_S MBP_MAX_PRESSURE_LEVEL MBP_MIN_AVAIL_MB MBP_MIN_BATT MBP_MAX_SLOTS MBP_SLOT_MAX_AGE_S MBP_RUN_TIMEOUT_S MBP_HOST
export PATH="$T/bin:$PATH" MBP_CITY="$T/city" MBP_SSH="$T/bin/ssh" MBP_RSYNC="$T/bin/rsync"
export STUB_LOG="$T/stub.log" STUB_REAPED="$T/reaped" STUB_SWAPCNT="$T/swapcnt" FAKE="$T/fake"
if [ -x /bin/bash ]; then export STUB_REMOTE_BASH=/bin/bash; else export STUB_REMOTE_BASH=bash; fi
FLAG="$T/city/.gc/mbp-offload.on"
J="$T/city/.gc/logs/mbp-run.jsonl"
fails=0; n=0
reset() { : > "$STUB_LOG"; rm -f "$STUB_REAPED" "$J"; unset STUB_UNREACHABLE STUB_AVAIL_MB STUB_SWAP_MB STUB_SWAP2_MB STUB_SWAP_RAW STUB_SWAP2_RAW STUB_PRESSURE STUB_PRESSURE_FAIL STUB_VM_FAIL STUB_VM_DROP STUB_PAGE_SIZE STUB_COMP_PAGES STUB_MP_FAIL STUB_MP_PCT STUB_PF_RAW STUB_POWER STUB_BATT STUB_PMSET_FAIL STUB_PMSET_RAW STUB_SLOTS STUB_NOBASE STUB_RUN_RC STUB_RUN_OUT STUB_RSYNC_RC; }
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

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
