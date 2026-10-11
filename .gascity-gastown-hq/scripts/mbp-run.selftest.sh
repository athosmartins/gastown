#!/usr/bin/env bash
# mbp-run.selftest.sh — hermético: ssh/rsync são stubs no PATH; nada toca o MBP nem o live.
#
# Contents
#   Casos · Controle negativo
#
# CASOS: off(99) · inalcançável(98) · RAM baixa(98) · swap alto(98) · bateria baixa(98) · slots cheios(96) ·
#   slot de dono morto é reaped · rc do remoto propagado e logado · ssh 255 no meio(98) · nota de shared/data ·
#   slot liberado ao fim · exec: push/pull + limpeza do scratch · uso errado(97) · base ausente(97).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/mbp-run.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/mbp-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/bin" "$T/city/.gc/logs" "$T/wt/tests"
: > "$T/wt/tests/test_x.py"

# stub ssh: lê o script do stdin, decide pelo marcador "# MBP:<NOME>" e pelo STUB_* do ambiente.
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [ "${STUB_UNREACHABLE:-0}" = 1 ]; then exit 255; fi
case "$args" in *"bash -s"*) s=$(cat); name=$(printf '%s' "$s" | sed -n '1s/^# MBP://p') ;; *) name="DIRECT"; s="" ;; esac
echo "$name" >> "$STUB_LOG"
case "$name" in
  PREFLIGHT) echo "avail_mb=${STUB_AVAIL_MB:-8000}"; echo "swap_mb=${STUB_SWAP_MB:-1000}"; echo "power=${STUB_POWER:-ac}"; echo "batt=${STUB_BATT:-90}"; echo "load=1.0" ;;
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
chmod +x "$T/bin/ssh" "$T/bin/rsync"

unset MBP_MAX_SWAP_MB MBP_MIN_AVAIL_MB MBP_MIN_BATT MBP_MAX_SLOTS MBP_SLOT_MAX_AGE_S MBP_RUN_TIMEOUT_S MBP_HOST
export PATH="$T/bin:$PATH" MBP_CITY="$T/city" MBP_SSH="$T/bin/ssh" MBP_RSYNC="$T/bin/rsync"
export STUB_LOG="$T/stub.log" STUB_REAPED="$T/reaped"
FLAG="$T/city/.gc/mbp-offload.on"
fails=0; n=0
reset() { : > "$STUB_LOG"; rm -f "$STUB_REAPED" "$T/city/.gc/logs/mbp-run.jsonl"; unset STUB_UNREACHABLE STUB_AVAIL_MB STUB_SWAP_MB STUB_POWER STUB_BATT STUB_SLOTS STUB_NOBASE STUB_RUN_RC STUB_RUN_OUT STUB_RSYNC_RC; }
expect() { # nome rc_esperado rc_real [grep-no-log padrão]
  n=$((n+1))
  if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; else echo "FAIL $1: esperado rc=$2, veio $3"; fails=$((fails+1)); fi
}
has() { # nome arquivo padrão
  n=$((n+1)); if grep -q -E "$3" "$2"; then echo "ok   $1"; else echo "FAIL $1: '$3' ausente em $2"; fails=$((fails+1)); fi
}
hasnt() {
  n=$((n+1)); if grep -q -E "$3" "$2"; then echo "FAIL $1: '$3' presente em $2"; fails=$((fails+1)); else echo "ok   $1"; fi
}
run() { "$RUN" --repo wa --dir "$T/wt" "$@" >"$T/out" 2>"$T/err"; echo $?; }

# 1 off
reset; rm -f "$FLAG"; rc=$(run -- tests/test_x.py); expect "off" 99 "$rc"; hasnt "off não chama ssh" "$STUB_LOG" 'PREFLIGHT'
date > "$FLAG"
# 2 inalcançável
reset; rc=$(STUB_UNREACHABLE=1 run -- tests/test_x.py); expect "inalcançável" 98 "$rc"
# 3 RAM baixa
reset; rc=$(STUB_AVAIL_MB=1000 run -- tests/test_x.py); expect "RAM baixa" 98 "$rc"; has "msg RAM" "$T/err" 'sem RAM'
hasnt "RAM baixa não pega slot" "$STUB_LOG" 'SLOT_ACQUIRE'
# 4 swap alto
reset; rc=$(STUB_SWAP_MB=6000 run -- tests/test_x.py); expect "swap alto" 98 "$rc"
# 5 bateria baixa sem tomada
reset; rc=$(STUB_POWER=battery STUB_BATT=30 run -- tests/test_x.py); expect "bateria baixa" 98 "$rc"
# 5b bateria ok sem tomada passa
reset; rc=$(STUB_POWER=battery STUB_BATT=80 run -- tests/test_x.py); expect "bateria 80% sem tomada passa" 0 "$rc"
# 6 slots cheios
reset; rc=$(STUB_SLOTS=full run -- tests/test_x.py); expect "slots cheios" 96 "$rc"; hasnt "cheios não roda" "$STUB_LOG" '^RUN$'
# 7 slot de dono morto é reaped e roda
reset; rc=$(STUB_SLOTS=dead run -- tests/test_x.py); expect "dono morto reaped" 0 "$rc"; has "chamou SLOT_REAP" "$STUB_LOG" 'SLOT_REAP'
# 8 propaga rc e loga
reset; rc=$(STUB_RUN_RC=7 run -- tests/test_x.py -q); expect "rc remoto propagado" 7 "$rc"
has "jsonl tem rc 7" "$T/city/.gc/logs/mbp-run.jsonl" '"rc":7'
# 9 libera slot ao fim
has "SLOT_RELEASE ao fim" "$STUB_LOG" 'SLOT_RELEASE'
# 10 ssh 255 no meio
reset; rc=$(STUB_RUN_RC=255 run -- tests/test_x.py); expect "ssh caiu no meio" 98 "$rc"; has "libera mesmo assim" "$STUB_LOG" 'SLOT_RELEASE'
# 11 nota de shared/data
reset; rc=$(STUB_RUN_RC=1 STUB_RUN_OUT="FileNotFoundError: shared/data/x.db" run -- tests/test_x.py); expect "falha com shared/data" 1 "$rc"; has "nota shared/data" "$T/err" 'NOTE: shared/data'
# 12 sucesso: rsync do worktree com exclusões e sem --delete-excluded
reset; rc=$(run -- tests/test_x.py); expect "sucesso" 0 "$rc"; has "rsync exclui .git" "$STUB_LOG" 'RSYNC:.*--exclude \.git'; hasnt "não apaga excluídos" "$STUB_LOG" 'delete-excluded'
has "stdout do remoto chega" "$T/out" 'stub-run-ok'
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

# controle negativo: sem a checagem de flag o caso "off" PASSARIA a rodar — prova que o teste 1 enxerga o defeito
reset; rm -f "$FLAG"; neg=$(sed 's/^\[ -f "\$FLAG" \] || {.*$/true/' "$RUN" > "$T/mut.sh"; chmod +x "$T/mut.sh"; "$T/mut.sh" --repo wa --dir "$T/wt" -- tests/test_x.py >/dev/null 2>&1; echo $?)
n=$((n+1)); if [ "$neg" != 99 ]; then echo "ok   controle negativo (mutante sem a trava não sai 99: rc=$neg)"; else echo "FAIL controle negativo: o mutante ainda saiu 99"; fails=$((fails+1)); fi

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
