#!/bin/bash
# disk-recovery-d2-heavy-jobs.selftest.sh — selftest do degrau D2 da escada de recuperação de disco (ga-1p1i5jr.2).
#
# ## Contents
#   O que prova · Hermetismo · Cenários de parada (S) · Cenários de retomada (R) · Bateria de mutantes
#
# O QUE PROVA. Que o D2 (a) só para o que a allowlist manda, só com o disco no piso e só com o pai certo; (b) nunca age quando não consegue LER o estado (df, ps, allowlist,
# registro) — três estados, "não sei" não vira "baixo" nem "bom"; (c) só afirma que parou depois de PROVAR a morte (ps E kill -0), escala TERM→KILL e não manda KILL às cegas quando não consegue provar;
# (d) não para sem antes gravar o registro; (e) retoma só com o disco de volta, na janela, com run_id LIDO e bem formado (nunca adivinhado) e com o ambiente do plist — e não retoma quando a trava não
# pôde ser criada (rc 30, causa diferente de "outra instância"); (f) devolve UMA linha e os códigos do contrato; (g) o job lançado pela retomada não sobrevive à decisão que o lançou: `launchctl submit` é KeepAlive (o launchd
# relança o job depois de TODA saída), então quando o job acaba — com qualquer código, ou parado pela escada — o rótulo some e o código de saída fica guardado; o launchd de brinquedo RELANÇA de verdade (R20-R26).
# Cada guarda tem um MUTANTE: a bateria final estraga uma linha do script (marcada `# MUT:<nome>`) e exige que o cenário correspondente FALHE.
#
# HERMETISMO. Processos de brinquedo (um `bash fakejob-A.sh` num diretório temporário) levam TERM/KILL de verdade — nada além deles; a allowlist do teste é ancorada no diretório temporário DESTA instância,
# então duas instâncias do selftest podem rodar ao mesmo tempo na máquina sem matar os toys uma da outra (S17). ps/aws/launchctl/df vêm de stubs ou de
# D2_FREE_MB; a allowlist é a do teste (a real só é lida em modo --dry-run, com ps simulado); o df de verdade só roda em s_real_df (somente leitura). O launchctl de brinquedo, em STUB_LC_RUN, EXECUTA o comando
# do `submit` (uma raiz do rfb de brinquedo em bash puro, sob $TMPDIR) com KeepAlive, e o `reap` mata o que sobrar. Pid LIDO DE ARQUIVO (os .sup/.pid do launchctl de brinquedo, o toy.pid) só leva sinal se a linha de
# comando dele carregar o diretório temporário DESTA instância (own_pid/kill_own; o stub exige ainda que o job seja filho do supervisor dele): um arquivo de pid velho, cujo número o macOS já deu a outro programa, não
# leva KILL (S18); sem poder provar de quem é o pid, ninguém recebe sinal. O pior que escreve em disco são alguns KB em $TMPDIR. Duração ~2 min.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REAL="$HERE/disk-recovery-d2-heavy-jobs.sh"
REAL_ALLOW="$HERE/disk-recovery-d2-allowlist.tsv"
T=$(mktemp -d "${TMPDIR:-/tmp}/d2selftest.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
case "$T" in */d2selftest.*) ;; *) echo "FAIL: diretório temporário inesperado: $T"; exit 1 ;; esac
TAB=$(printf '\t')
MYUID=$(id -u)
PASS=0; FAIL=0; QUIET=0; RUNS=0; BADLINES=0
JOBS=""

ok()  { PASS=$((PASS + 1)); [ "$QUIET" = 1 ] || echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); [ "$QUIET" = 1 ] || echo "  FAIL: $1"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (obtive '$2', esperava '$3')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (não achei '$3' em: $2)" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1 (achei '$3' em: $2)" ;; *) ok "$1" ;; esac; }

# Identidade antes de sinal (S18). Um pid LIDO DE ARQUIVO pode já ser de outro programa: o macOS reaproveita pids em minutos (o espaço vai até 99999; medido no mini a 02/11, load ~90: ~650 pids/s = volta em ~2,5 min; o revisor
# do gate mediu ~300 pids/s = ~5,5 min) e esta bateria dura mais que isso sob load. O $T é único (mktemp), então só um processo DESTA instância carrega "$T/" na linha de comando.
# vazio (o ps não lista o pid: já morreu) → não é nosso, nada a sinalizar; falhou/ilegível (ps quebrado) → idem: o estado inerte é NÃO sinalizar, nunca "sinaliza assim mesmo".
own_pid() {  # $1=pid → rc 0 = o pid vive E a linha de comando dele carrega o $T desta instância · 1 = não provei que é nosso
  local c
  [ -n "${1:-}" ] || return 1
  c=$(ps -o command= -p "$1" 2>/dev/null) || return 1
  case "$c" in *"$T/"*) return 0 ;; esac
  return 1
}
kill_own() {  # $1=sinal $2=pid → sinaliza SÓ se own_pid provar; pid velho, reaproveitado ou ilegível não leva nada
  own_pid "$2" && kill -"$1" "$2" 2>/dev/null
  return 0
}
lc_cleanup() {  # termina o supervisor e o job que o stub-launchctl (modo STUB_LC_RUN) deixou de pé num cenário, sem sinal às cegas
  local d f p
  for d in "$T"/case*; do
    rm -f "$d/lc.log.submitted"      # o supervisor para de relançar sozinho: não depende de pid algum
    for f in "$d/lc.log.sup" "$d/lc.log.pid"; do
      [ -f "$f" ] || continue
      p=$(cat "$f" 2>/dev/null)
      kill_own KILL "$p"             # só se o pid ainda for um processo DESTA instância
      rm -f "$f"                     # cada arquivo de pid vale UMA varredura: a próxima reap não o relê (o pid pode ter mudado de dono)
    done
  done
  return 0
}
reap() {
  local p
  # os $JOBS são filhos DIRETOS deste shell e ainda não reapados (nenhum cenário dá wait neles antes do reap; o único `wait` solto, em r_reread, roda sem spawn): o kernel guarda o pid até o wait daqui, então o kill não erra de alvo
  for p in $JOBS; do kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  JOBS=""
  lc_cleanup
}
finish_all() { reap; rm -rf "$T"; }
trap finish_all EXIT

job_alive() {  # rc 0 = vivo (zumbi não conta)
  local st; st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')
  [ -n "$st" ] && [ "${st#Z}" = "$st" ]
}

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────────────────────────────────
cat >"$T/fakejob-A.sh" <<'EOF'
#!/bin/bash
while :; do sleep 1; done
EOF
cat >"$T/fakejob-stubborn-A.sh" <<'EOF'
#!/bin/bash
trap '' TERM
while :; do sleep 1; done
EOF
cat >"$T/stub-ps" <<'EOF'
#!/bin/bash
cat "${STUB_PS_FILE:?}"
EOF
cat >"$T/stub-aws" <<'EOF'
#!/bin/bash
[ "${STUB_AWS_FAIL:-0}" = 1 ] && exit 1
E="${STUB_AWS_EPOCH:-1}"; P="${STUB_AWS_PID:-1}"
echo "2026-09-30 07:22:33       1704 stream-run-1790760275-48733.json"
echo "2026-09-29 22:51:12       1392 stream-run-1790728666-49289.cnpj_socios.json"
echo "2026-11-01 00:45:20       1491 stream-run-${E}-99999999.cnpj_empresas.json"
if [ "${STUB_AWS_NONE:-0}" != 1 ]; then
  echo "2026-11-01 00:45:20       1491 stream-run-${E}-${P}.cnpj_empresas.json"
  echo "2026-11-01 05:00:18       1506 stream-run-${E}-${P}.cnpj_estabelecimentos.json"
fi
[ "${STUB_AWS_AMBIG:-0}" = 1 ] && echo "2026-11-01 05:00:18       1506 stream-run-$((E + 1))-${P}.cnpj_socios.json"
exit 0
EOF
cat >"$T/stub-ps-seq" <<'EOF'
#!/bin/bash
# as STUB_PS_GOOD primeiras chamadas são o ps de verdade; depois STUB_PS_AFTER: fail = ps quebrado · empty = ps legível sem nenhum job
n=$(($(cat "${STUB_PS_COUNT:?}" 2>/dev/null || echo 0) + 1)); echo "$n" >"$STUB_PS_COUNT"
[ "$n" -le "${STUB_PS_GOOD:-1}" ] && exec ps "$@"
[ "${STUB_PS_AFTER:-fail}" = fail ] && exit 1
printf '    1     0 %s 10-00:00:01 /sbin/launchd\n' "$(id -u)"
EOF
cat >"$T/stub-launchctl" <<'EOF'
#!/bin/bash
# launchctl de brinquedo. Padrão: `list` com resposta ENLATADA (STUB_LC_MODE = alive | gone | listfail | listfail2).
# STUB_LC_RUN=1: o `submit` EXECUTA o comando do jeito que o launchd executa um job de `submit` — KeepAlive: relança depois de TODA saída, mesmo rc 0 (aqui
# STUB_LC_THROTTLE s depois, em vez dos ~10 s do launchd), até o `remove`; o `remove` termina o job com SIGTERM e para o relançamento. `list` mostra PID enquanto o job vive.
# Estado ao lado do log: .submitted (o rótulo existe) · .pid (job vivo) · .sup (supervisor) · .started · .runs (uma linha por lançamento) · .status (rc do último).
LOG="${STUB_LC_LOG:?}"
own_job() {  # rc 0 = $LOG.pid é um job VIVO e FILHO do supervisor deste rótulo ($LOG.sup); o pid fica em JOBP. pid velho, reaproveitado ou ilegível (vazio ou ps quebrado) → 1: ninguém recebe sinal por causa dele
  local sp pp
  JOBP=$(cat "$LOG.pid" 2>/dev/null); sp=$(cat "$LOG.sup" 2>/dev/null)
  [ -n "$JOBP" ] && [ -n "$sp" ] || return 1
  pp=$(ps -o ppid= -p "$JOBP" 2>/dev/null | tr -d ' ')
  [ -n "$pp" ] && [ "$pp" = "$sp" ]
}
case "${1:-}" in
  submit)
    { echo "--- submit"; printf '%s\n' "$@"; } >>"$LOG"
    [ "${STUB_LC_SUBMIT_FAIL:-0}" = 1 ] && exit 1
    : >"$LOG.submitted"
    [ "${STUB_LC_RUN:-0}" = 1 ] || exit 0
    shift; OUTF=/dev/null
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
      case "$1" in -o) OUTF=$2; shift ;; esac
      shift
    done
    shift      # o `--`
    rm -f "$LOG.started"
    (
      while [ -f "$LOG.submitted" ]; do
        "$@" >>"$OUTF" 2>&1 &
        jp=$!; echo "$jp" >"$LOG.pid"; echo run >>"$LOG.runs"; : >"$LOG.started"
        wait "$jp"; echo $? >"$LOG.status"; rm -f "$LOG.pid"
        [ -f "$LOG.submitted" ] || break
        sleep "${STUB_LC_THROTTLE:-1}"
      done
      rm -f "$LOG.sup"      # o supervisor acabou: o pid dele não vale mais para ninguém
    ) >/dev/null 2>&1 &
    echo $! >"$LOG.sup"
    i=0; while [ ! -f "$LOG.started" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done      # como o launchd: o job já está de pé quando o submit volta
    exit 0 ;;
  remove)
    echo "--- remove $*" >>"$LOG"
    n=$(cat "$LOG.rmn" 2>/dev/null || echo 0)
    if [ "$n" -lt "${STUB_LC_REMOVE_FAILS:-0}" ]; then echo $((n + 1)) >"$LOG.rmn"; exit 1; fi      # as primeiras STUB_LC_REMOVE_FAILS chamadas FALHAM (nada é removido)
    [ -f "$LOG.submitted" ] || exit 113      # rótulo desconhecido (já removido)
    rm -f "$LOG.submitted"
    if [ "${STUB_LC_RUN:-0}" = 1 ] && own_job; then kill -TERM "$JOBP" 2>/dev/null; fi      # só o filho vivo do MEU supervisor; um .pid velho não leva TERM
    exit 0 ;;
  list)
    echo "--- list $*" >>"$LOG"
    [ "${STUB_LC_MODE:-}" = listfail ] && exit 1      # o próprio launchctl quebrado (rc 1), que NÃO é o "não conheço o rótulo" (113)
    [ -f "$LOG.submitted" ] || exit 113
    [ "${STUB_LC_MODE:-}" = listfail2 ] && exit 1     # quebra só DEPOIS do submit (o list de antes, que deu 113, passou)
    if [ "${STUB_LC_RUN:-0}" = 1 ]; then
      if own_job; then
        printf '{\n\t"LastExitStatus" = 0;\n\t"PID" = %s;\n};\n' "$JOBP"
      else
        printf '{\n\t"LastExitStatus" = %s;\n};\n' $(( $(cat "$LOG.status" 2>/dev/null || echo 0) * 256 ))
      fi
      exit 0
    fi
    case "${STUB_LC_MODE:-alive}" in
      alive) printf '{\n\t"LastExitStatus" = 0;\n\t"PID" = 4242;\n};\n' ;;
      gone)  exit 113 ;;
    esac
    exit 0 ;;
esac
exit 64
EOF
chmod +x "$T/stub-ps" "$T/stub-ps-seq" "$T/stub-aws" "$T/stub-launchctl"
"$(command -v python3)" -I -c '
import plistlib, sys
plistlib.dump({"Label": "fixture", "EnvironmentVariables": {"LANG": "pt_BR.UTF-8", "RFB_STREAM_WINDOW": "21-6", "RFB_STREAM_MEMORY_LIMIT": "2GB", "RFB_STREAM_RSS_CEILING_GIB": "4"}}, open(sys.argv[1], "wb"))' "$T/fixture.plist"
mkdir -p "$T/tmp"

NOW0=$(date +%s)
ALLOW_RE="^bash ${T}/fakejob-A\.sh\$"      # ancorada no $T DESTA instância: outra instância do selftest na máquina tem toys com a mesma forma de linha de comando e não pode ser casada
ALLOW_PRE='.*'

mk_allow() {  # $1=arquivo $2=match_re $3=parent_re $4=stop_mb $5=resume_mb $6=janela $7=maxage
  printf 'joba\trfb\t%s\t%s\t%s\t%s\t%s\t%s\tcomo: TERM; retoma com --resume-run\n' "$2" "$3" "$4" "$5" "$6" "$7" >"$1"
}

CASE=0
newcase() {  # cria um diretório de caso, exporta o ambiente do D2 e (opcional) o estado de brinquedo
  CASE=$((CASE + 1)); C="$T/case$CASE"; mkdir -p "$C/city/.gc/logs"
  export D2_CITY="$C/city" D2_STATE="$C/state" D2_LOG="$C/log" D2_LOCK="$C/lock.d" D2_ALLOWLIST="$C/allow.tsv"
  # folgas generosas: o stub responde na hora, então não custam tempo; só evitam falso vermelho com a máquina em swap (load 36 medido em 01/11: S5 já falhou por timeout do S3)
  export D2_TERM_GRACE_S=1 D2_KILL_WAIT_S=6 D2_S3_TIMEOUT_S=15 D2_RESUME_WATCH_S=1 D2_MAX_MATCH=3
  export D2_AWS_BIN="$T/stub-aws" D2_LAUNCHCTL_BIN="$T/stub-launchctl" D2_RFB_PLIST="$T/fixture.plist" D2_RFB_ROOT=/nonexistent-root D2_RFB_PYTHON=/nonexistent-python
  export STUB_LC_LOG="$C/lc.log" STUB_LC_MODE=alive STUB_AWS_FAIL=0 STUB_AWS_NONE=0 STUB_AWS_AMBIG=0 STUB_LC_SUBMIT_FAIL=0 STUB_LC_RUN=0 STUB_LC_THROTTLE=1 STUB_LC_REMOVE_FAILS=0
  export TMPDIR="$T/tmp" D2_HOUR=23
  unset D2_FREE_MB D2_PS_BIN D2_DF_BIN D2_NOW D2_VOLUME D2_LOCKPS_BIN D2_LOCK_WAIT_S STUB_PS_FILE STUB_PS_COUNT STUB_PS_GOOD STUB_PS_AFTER STUB_STATE_FAIL
  mk_allow "$D2_ALLOWLIST" "$ALLOW_RE" "$ALLOW_PRE" 3072 8000 21-6 3600
  : >"$STUB_LC_LOG"
}
run_sut() {  # args → OUT (stdout), RC; confere que o stdout é UMA linha
  local n
  OUT=$("$SUT" "$@" 2>"$C/stderr"); RC=$?
  RUNS=$((RUNS + 1))
  n=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
  if [ "$n" != 1 ] || [ -z "$OUT" ]; then BADLINES=$((BADLINES + 1)); bad "stdout deveria ser UMA linha e tem $n (args: $*)"; fi
}
spawn() {  # $1=script [argumentos do job...] → JOBPID
  bash "$@" >/dev/null 2>&1 &
  JOBPID=$!; JOBS="$JOBS $JOBPID"; sleep 0.4
}
state_line() {  # $1=evento $2=pid $3=início $4=run_id $5=ts
  printf '%s\t%s\tjoba\t%s\t%s\t%s\t5000\tfixture\n' "${5:-$NOW0}" "$1" "$2" "$3" "$4" >>"$D2_STATE"
}
stub_env_for_job() { export STUB_AWS_PID="$JOBPID" STUB_AWS_EPOCH="$(date +%s)"; }

# ── a retomada de VERDADE: o launchctl de brinquedo executa o comando do submit (KeepAlive) sobre uma raiz do rfb de brinquedo ──────────────
LABEL_T="com.gascity.d2-resume.rfb"
mk_rfb_root() {  # $1=modo do job de brinquedo (exit3 | exit1 | ok-after2 | fail-after2 | long) → liga STUB_LC_RUN e aponta o D2 para a raiz de brinquedo
  RFBROOT="$C/rfbroot"; RCFILE="$C/city/.gc/disk-recovery-d2-resume-rfb.rc"; mkdir -p "$RFBROOT/scripts"
  cat >"$RFBROOT/scripts/job_timeout.sh" <<'EOF'
#!/bin/bash
# job_timeout.sh de brinquedo: <segundos> <rótulo> --soft -- <comando...>; o comando roda como FILHO e o rc é repassado (como o de verdade)
shift 4
"$@"
exit $?
EOF
  cat >"$RFBROOT/scripts/rfb_stream_refresh.py" <<'EOF'
#!/bin/bash
# "python" de brinquedo: o modo vem de toy.mode (ao lado de scripts/); cada execução deixa uma linha em toy.runs e o seu pid em toy.pid
root=$(cd "$(dirname "$0")/.." && pwd)
echo "run $*" >>"$root/toy.runs"; echo $$ >"$root/toy.pid"
case "$(cat "$root/toy.mode" 2>/dev/null)" in
  exit3) exit 3 ;;
  exit1) exit 1 ;;
  ok-after2) sleep 2; exit 0 ;;
  fail-after2) sleep 2; exit 1 ;;
  long) i=0; while [ "$i" -lt 40 ]; do sleep 1; i=$((i + 1)); done; exit 0 ;;      # limitado: se o cenário não o matar, ele some sozinho
esac
exit 99
EOF
  chmod +x "$RFBROOT/scripts/job_timeout.sh" "$RFBROOT/scripts/rfb_stream_refresh.py"
  printf '%s\n' "$1" >"$RFBROOT/toy.mode"
  export D2_RFB_ROOT="$RFBROOT" D2_RFB_PYTHON=/bin/bash STUB_LC_RUN=1
}
toy_runs() { if [ -f "$RFBROOT/toy.runs" ]; then wc -l <"$RFBROOT/toy.runs" | tr -d ' '; else echo 0; fi; }      # quantas vezes o job de brinquedo EXECUTOU
label_gone() {  # $1=segundos → rc 0 = o rótulo da retomada sumiu do launchd de brinquedo (list = 113) dentro do prazo
  local i=0 max=$(( $1 * 5 ))
  while [ "$i" -lt "$max" ]; do
    "$T/stub-launchctl" list "$LABEL_T" >/dev/null 2>&1; [ $? -eq 113 ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

# ═════════════════ CENÁRIOS DE PARADA ═══════════════════════════════════════════════════════════════════════════════════════
s_usage() {
  newcase; run_sut; eq "S1 sem argumento: rc 2 (uso)" "$RC" 2
  run_sut --nada; eq "S1 argumento desconhecido: rc 2" "$RC" 2
  run_sut --run --dry-run; eq "S1 dois argumentos: rc 2" "$RC" 2
  [ ! -e "$D2_LOG" ]; check $? "S1 uso errado não escreve no log de produção"
}

s_stop_guard() {  # livre ACIMA do piso: o job fica
  newcase; spawn "$T/fakejob-A.sh"; export D2_FREE_MB=4000
  run_sut --run
  eq "S4 livre 4000 > piso 3072: rc 10 (guarda adiou)" "$RC" 10
  job_alive "$JOBPID"; check $? "S4 o job segue vivo"
  has "S4 a linha diz que a guarda segurou" "$OUT" "guarda segura"
  [ ! -e "$D2_STATE" ]; check $? "S4 nada foi registrado (nada foi parado)"
  reap
}

s_stop_ok() {
  newcase; spawn "$T/fakejob-A.sh"; stub_env_for_job; export D2_FREE_MB=2500
  run_sut --run
  eq "S5 livre 2500 <= piso 3072: rc 0 (agiu)" "$RC" 0
  job_alive "$JOBPID"; [ $? -ne 0 ]; check $? "S5 o job MORREU (provado por ps)"
  has "S5 a linha nomeia job e pid" "$OUT" "joba (pid $JOBPID"
  has "S5 a linha traz o run_id lido do S3 (epoch-pid)" "$OUT" "-${JOBPID}"
  has "S5 a linha diz como retomar" "$OUT" "--resume quando livre >= 8000 MB"
  local st; st=$(cat "$D2_STATE" 2>/dev/null)
  case "$(printf '%s\n' "$st" | sed -n 2p | cut -f6)" in *-"$JOBPID") ;; *) [ "$QUIET" = 1 ] || echo "  (diag S5) estado: $st | log: $(cat "$D2_LOG" 2>/dev/null) | aws: $("$D2_AWS_BIN" s3 ls x 2>&1 | tr '\n' '/')" ;; esac
  eq "S5 o registro tem STOPPING e STOPPED" "$(printf '%s\n' "$st" | cut -f2 | tr '\n' ',')" "STOPPING,STOPPED,"
  has "S5 o STOPPED carrega pid e run_id" "$(printf '%s\n' "$st" | sed -n 2p)" "${TAB}${JOBPID}${TAB}"
  has "S5 o STOPPED carrega o run_id <epoch>-<pid>" "$(printf '%s\n' "$st" | sed -n 2p | cut -f6)" "-${JOBPID}"
  [ ! -e "$D2_LOCK" ]; check $? "S5 a trava foi solta"
  [ -z "$(ls "$T/tmp" 2>/dev/null)" ]; check $? "S5 nenhum temporário ficou em \$TMPDIR"
  reap
}

s_stop_ambiguous() {
  newcase; spawn "$T/fakejob-A.sh"; stub_env_for_job; export D2_FREE_MB=2500 STUB_AWS_AMBIG=1
  run_sut --run
  eq "S5b dois run_ids casam pid+hora: ainda para (rc 0)" "$RC" 0
  eq "S5b ...mas o run_id fica '-': não adivinha" "$(sed -n 2p "$D2_STATE" | cut -f6)" "-"
  reap
}

s_stop_s3_down() {
  newcase; spawn "$T/fakejob-A.sh"; stub_env_for_job; export D2_FREE_MB=2500 STUB_AWS_FAIL=1
  run_sut --run
  eq "S5c S3 ilegível: emergência, para assim mesmo (rc 0)" "$RC" 0
  eq "S5c ...run_id '-' (o --resume tenta de novo)" "$(sed -n 2p "$D2_STATE" | cut -f6)" "-"
  reap
}

s_stubborn() {  # ignora TERM: tem de escalar para KILL
  newcase; export D2_FREE_MB=2500
  mk_allow "$D2_ALLOWLIST" "^bash ${T}/fakejob-stubborn-A\.sh\$" "$ALLOW_PRE" 3072 8000 21-6 3600
  spawn "$T/fakejob-stubborn-A.sh"; stub_env_for_job
  run_sut --run
  eq "S6 job que ignora TERM: rc 0 depois do KILL" "$RC" 0
  job_alive "$JOBPID"; [ $? -ne 0 ]; check $? "S6 o job MORREU"
  has "S6 o log registra a escalada para KILL (prova de que ignorou o TERM)" "$(cat "$D2_LOG" 2>/dev/null)" "sobreviveu à graça"
  reap
}

s_parent_guard() {  # casa a regex do processo mas não o pai: intocável
  newcase; spawn "$T/fakejob-A.sh"; export D2_FREE_MB=2500
  mk_allow "$D2_ALLOWLIST" "$ALLOW_RE" '^o-pai-do-launchd$' 3072 8000 21-6 3600
  run_sut --run
  eq "S7 pai errado: rc 10, nada a parar" "$RC" 10
  job_alive "$JOBPID"; check $? "S7 o processo (mesmo casando a regex) segue vivo"
  reap
}

s_df_unreadable() {
  newcase; spawn "$T/fakejob-A.sh"; export D2_DF_BIN="$T/nao-existe"
  run_sut --run
  eq "S8 df ilegível: rc 30 (não leu, não agiu)" "$RC" 30; has "S8 a causa na linha é o df" "$OUT" "(df)"
  job_alive "$JOBPID"; check $? "S8 o job segue vivo"
  [ ! -e "$D2_STATE" ]; check $? "S8 nada registrado"
  reap
}

s_ps_unreadable() {
  newcase; spawn "$T/fakejob-A.sh"; export D2_FREE_MB=2500 D2_PS_BIN="$T/nao-existe"
  run_sut --run
  eq "S9 ps ilegível: rc 30" "$RC" 30; has "S9 a causa na linha é o ps" "$OUT" "ler o ps"
  job_alive "$JOBPID"; check $? "S9 o job segue vivo"
  reap
}

s_broad_regex() {  # regex larga demais: 4 processos casam, limite 3
  newcase; export D2_FREE_MB=2500
  mk_allow "$D2_ALLOWLIST" "^bash ${T}/fakejob-" "$ALLOW_PRE" 3072 8000 21-6 3600
  cp "$T/fakejob-A.sh" "$T/fakejob-B.sh"; cp "$T/fakejob-A.sh" "$T/fakejob-C.sh"; cp "$T/fakejob-A.sh" "$T/fakejob-D.sh"
  local p1 p2 p3 p4
  spawn "$T/fakejob-A.sh"; p1=$JOBPID; spawn "$T/fakejob-B.sh"; p2=$JOBPID; spawn "$T/fakejob-C.sh"; p3=$JOBPID; spawn "$T/fakejob-D.sh"; p4=$JOBPID
  run_sut --run
  eq "S10 regex que casa 4 processos (limite 3): rc 30" "$RC" 30; has "S10 a causa na linha é a regex larga" "$OUT" "larga demais"
  local alive=0 p; for p in $p1 $p2 $p3 $p4; do job_alive "$p" && alive=$((alive + 1)); done
  eq "S10 nenhum dos 4 foi tocado" "$alive" 4
  reap
}

s_allowlist_invalid() {
  newcase; export D2_FREE_MB=2500
  a30() { run_sut --run; eq "S11 $1: rc 30" "$RC" 30; has "S11 $1: a causa na linha" "$OUT" "$2"; }
  printf 'joba\trfb\tx\ty\t3072\t8000\t21-6\t3600\n' >"$D2_ALLOWLIST"; a30 "linha com 8 colunas" "esperava 9 colunas"
  mk_allow "$D2_ALLOWLIST" "$ALLOW_RE" "$ALLOW_PRE" 8000 3072 21-6 3600; a30 "resume <= stop (sem histerese)" "histerese"
  mk_allow "$D2_ALLOWLIST" "$ALLOW_RE" "$ALLOW_PRE" 3072 8000 21-21 3600; a30 "janela início = fim" "início = fim"
  mk_allow "$D2_ALLOWLIST" '(' "$ALLOW_PRE" 3072 8000 21-6 3600; a30 "regex que não compila" "regex inválida"
  printf '# só comentário\n\n' >"$D2_ALLOWLIST"; a30 "allowlist sem linha ativa" "sem nenhuma linha ativa"
  rm -f "$D2_ALLOWLIST"; a30 "allowlist ausente" "ilegível"
}

s_state_unwritable() {  # sem registro, não para
  newcase; spawn "$T/fakejob-A.sh"; export D2_FREE_MB=2500
  : >"$C/umarquivo"; export D2_STATE="$C/umarquivo/state"
  run_sut --run
  eq "S12 registro não grava: rc 20" "$RC" 20
  job_alive "$JOBPID"; check $? "S12 o job NÃO foi parado (sem registro, não para)"
  has "S12 a linha diz por quê" "$OUT" "NÃO parei"
  reap
}

s_lock() {
  newcase; spawn "$T/fakejob-A.sh"; export D2_FREE_MB=2500
  mkdir -p "$D2_LOCK"; printf '%s' "$$" >"$D2_LOCK/pid"
  run_sut --run
  eq "S13 trava com dono vivo: rc 10 (outra instância)" "$RC" 10
  job_alive "$JOBPID"; check $? "S13 o job segue vivo"
  rm -rf "$D2_LOCK"; mkdir -p "$D2_LOCK"; printf '%s' "999999" >"$D2_LOCK/pid"
  stub_env_for_job
  run_sut --run
  eq "S13 trava velha (dono morto) é tomada: rc 0" "$RC" 0
  reap
  newcase; spawn "$T/fakejob-A.sh"; export D2_FREE_MB=2500
  : >"$C/umarquivo"; export D2_LOCK="$C/umarquivo/lock.d"
  run_sut --run
  eq "S13 trava que não dá para criar (erro de gravação): rc 30, não é 'outra instância'" "$RC" 30; has "S13 ...a causa na linha é a trava" "$OUT" "a trava"
  hasnt "S13 ...e a linha não diz 'outra instância'" "$OUT" "outra instância"
  job_alive "$JOBPID"; check $? "S13 o job segue vivo (sem trava, não age)"
  reap
  newcase; spawn "$T/fakejob-A.sh"; stub_env_for_job; export D2_FREE_MB=2500   # o pid da trava é de OUTRO programa vivo (pid reaproveitado): não é D2, a trava é abandonada
  mkdir -p "$D2_LOCK"; printf '%s' "$JOBPID" >"$D2_LOCK/pid"
  run_sut --run; eq "S13 pid da trava reaproveitado por outro programa: trava tomada (rc 0)" "$RC" 0
  reap
  newcase; spawn "$T/fakejob-A.sh"; export D2_FREE_MB=2500 D2_LOCKPS_BIN="$T/nao-existe"   # não consigo ver quem é o dono: não roubo a trava
  mkdir -p "$D2_LOCK"; printf '%s' "$$" >"$D2_LOCK/pid"
  run_sut --run; eq "S13 dono da trava ilegível: rc 30 (não roubo)" "$RC" 30
  [ -d "$D2_LOCK" ]; check $? "S13 ...e a trava do outro continua lá"
  job_alive "$JOBPID"; check $? "S13 o job segue vivo"
  reap
  newcase; spawn "$T/fakejob-A.sh"; stub_env_for_job; export D2_FREE_MB=2500 D2_LOCK_WAIT_S=0   # pasta da trava SEM pid: nova = o dono está começando; velha = abandonada
  mkdir -p "$D2_LOCK"
  run_sut --run; eq "S13 pasta de trava nova sem pid (dono começando): rc 10, não é abandonada" "$RC" 10
  [ -d "$D2_LOCK" ]; check $? "S13 ...e a pasta segue lá"
  touch -t 202001010000 "$D2_LOCK"
  run_sut --run; eq "S13 pasta de trava velha sem pid (> 2 min): abandonada, tomada (rc 0)" "$RC" 0
  reap
}

s_dry_run() {  # só diz; não escreve nada
  newcase; spawn "$T/fakejob-A.sh"; export D2_FREE_MB=2500
  run_sut --dry-run
  eq "S3 --dry-run com o disco no piso: rc 0 (agiria)" "$RC" 0
  has "S3 a linha diz 'pararia'" "$OUT" "pararia joba (pid $JOBPID"
  job_alive "$JOBPID"; check $? "S3 o job segue vivo"
  [ ! -e "$D2_STATE" ] && [ ! -e "$D2_LOG" ] && [ ! -e "$D2_LOCK" ]; check $? "S3 --dry-run não criou estado, log nem trava"
  [ ! -s "$STUB_LC_LOG" ]; check $? "S3 --dry-run não chamou o launchctl"
  export D2_FREE_MB=4000; run_sut --dry-run; eq "S3 --dry-run com o disco folgado: rc 10" "$RC" 10
  reap
}

s_real_allowlist() {  # a allowlist REAL contra um ps simulado: o regex de verdade só pega o job de verdade
  newcase; export D2_ALLOWLIST="$REAL_ALLOW" D2_FREE_MB=2000 D2_PS_BIN="$T/stub-ps" STUB_PS_FILE="$C/ps.txt"
  local other=$((MYUID + 1))
  {
    printf '    1     0 %s 10-00:00:01 /sbin/launchd\n' "$MYUID"
    printf ' 5001     1 %s 11:06:37 /bin/bash /Users/athos/gt/whatsapp_automation/scripts/job_timeout.sh 21600 com.whatsapp.rfb-monthly-refresh --soft -- /bin/bash -c R=/Users/athos/gt/whatsapp_automation; S=$R/scripts/rfb_monthly_refresh.py; exec /opt/homebrew/bin/python3 "$S"\n' "$MYUID"
    printf ' 5002  5001 %s 11:06:37 /opt/homebrew/Cellar/python@3.14/3.14.5/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python /Users/athos/gt/whatsapp_automation/scripts/rfb_monthly_refresh.py\n' "$MYUID"
    printf ' 6000     1 %s 01:00 -zsh\n' "$MYUID"
    printf ' 6001  6000 %s 00:05 /opt/homebrew/bin/python3 -m py_compile scripts/rfb_monthly_refresh.py\n' "$MYUID"
    printf ' 7000     1 %s 01:00 /bin/bash /some/gate-selftest.sh\n' "$MYUID"
    printf ' 7001  7000 %s 00:09 /opt/homebrew/bin/python3 /Users/athos/gt/whatsapp_automation/scripts/rfb_monthly_refresh.py --dry-run\n' "$MYUID"
    printf ' 8001  6000 %s 00:09 /usr/bin/vim /Users/athos/gt/whatsapp_automation/scripts/rfb_monthly_refresh.py\n' "$MYUID"
    printf ' 9001  5001 %s 00:09 /opt/homebrew/bin/python3 /Users/athos/gt/whatsapp_automation/scripts/rfb_stream_refresh.py --resume-run 1-2\n' "$other"
  } >"$C/ps.txt"
  run_sut --dry-run
  eq "S2 allowlist real: rc 0 (acha o job)" "$RC" 0
  has "S2 o job de verdade (pid 5002) é o alvo" "$OUT" "pid 5002"
  hasnt "S2 o wrapper job_timeout.sh (5001) não é alvo" "$OUT" "5001"
  hasnt "S2 python -m py_compile (6001) não é alvo" "$OUT" "6001"
  hasnt "S2 --dry-run rodado por gate/gente (7001, pai errado) não é alvo" "$OUT" "7001"
  hasnt "S2 vim (8001) não é alvo" "$OUT" "8001"
  hasnt "S2 processo de OUTRO usuário (9001) não é alvo" "$OUT" "9001"
  : >"$C/ps.txt"; printf '    1     0 %s 10-00:00:01 /sbin/launchd\n' "$MYUID" >"$C/ps.txt"
  run_sut --dry-run; eq "S2 nada rodando: rc 10" "$RC" 10
}

s_real_df() {  # df de VERDADE (sem D2_FREE_MB) e ps só com o launchd: rc 10 exige que o df tenha sido lido (rc 30 = df falhou) e o MB tem de bater com um df independente
  newcase; export D2_PS_BIN="$T/stub-ps" STUB_PS_FILE="$C/ps.txt"; printf '    1     0 %s 10-00:00:01 /sbin/launchd\n' "$MYUID" >"$C/ps.txt"
  local vol=/System/Volumes/Data got want; [ -d "$vol" ] || vol=/; export D2_VOLUME="$vol"      # no nó Linux o volume do mini não existe
  run_sut --dry-run
  eq "S2b df real: rc 10 (leu o livre; rc 30 = o df falhou)" "$RC" 10
  got=$(printf '%s' "$OUT" | sed -n 's/.*(livre \([0-9][0-9]*\) MB).*/\1/p'); want=$(( $(df -Pk "$vol" | awk 'NR==2 { print $4 }') / 1024 ))
  [ -n "$got" ] && [ $((got > want ? got - want : want - got)) -le 1024 ]; check $? "S2b o MB lido (${got:-nenhum}) bate com um df independente ($want) a ±1024 MB"
}

s_recheck_unreadable() {  # o ps lê na 1ª passada e falha na re-conferência: ninguém recebe sinal
  newcase; spawn "$T/fakejob-A.sh"; export D2_FREE_MB=2500 D2_PS_BIN="$T/stub-ps-seq" STUB_PS_COUNT="$C/n" STUB_PS_GOOD=1 STUB_PS_AFTER=fail
  run_sut --run
  eq "S14 ps falha na re-conferência: rc 30 (identidade não provada, não agiu)" "$RC" 30; has "S14 a causa na linha é a re-conferência" "$OUT" "re-conferência"
  job_alive "$JOBPID"; check $? "S14 o job segue vivo (nenhum sinal sem identidade provada)"
  [ ! -e "$D2_STATE" ]; check $? "S14 nada registrado"
  reap
}

s_stop_unproven() {  # depois do TERM o ps quebra (fail) ou deixa de listar o pid que ainda vive (empty): morte NÃO provada = rc 20, sem KILL às cegas
  local mode
  for mode in fail empty; do
    newcase; mk_allow "$D2_ALLOWLIST" "^bash ${T}/fakejob-stubborn-A\.sh\$" "$ALLOW_PRE" 3072 8000 21-6 3600
    spawn "$T/fakejob-stubborn-A.sh"; export D2_FREE_MB=2500 D2_PS_BIN="$T/stub-ps-seq" STUB_PS_COUNT="$C/n" STUB_PS_GOOD=2 STUB_PS_AFTER=$mode
    run_sut --run
    eq "S15 ($mode) morte não comprovada: rc 20" "$RC" 20; has "S15 ($mode) a linha diz que NÃO foi comprovada" "$OUT" "NÃO comprovada"
    job_alive "$JOBPID"; check $? "S15 ($mode) sem KILL às cegas: o job que ignora TERM segue vivo"
    eq "S15 ($mode) o registro tem STOPPING e STOP_FAILED (não STOPPED)" "$(cut -f2 "$D2_STATE" | tr '\n' ',')" "STOPPING,STOP_FAILED,"
    reap
  done
}

s_isolation() {  # OUTRA instância deste selftest rodando ao mesmo tempo na máquina tem toys com a mesma forma de linha de comando (`bash <dir>/fakejob-A.sh`): a allowlist do teste só pode casar os MEUS, senão uma instância mata os jobs da outra (falso vermelho)
  newcase; export D2_FREE_MB=2500
  mkdir -p "$T/alien"; cp "$T/fakejob-A.sh" "$T/alien/fakejob-A.sh"
  spawn "$T/alien/fakejob-A.sh"; local alien=$JOBPID
  spawn "$T/fakejob-A.sh"; stub_env_for_job
  run_sut --run
  eq "S17 o job deste selftest foi parado: rc 0" "$RC" 0
  job_alive "$alien"; check $? "S17 o toy de OUTRO selftest (outro diretório, mesma forma de linha de comando) segue vivo"
  reap
}

s_stop_resumed() {  # o job RETOMADO leva `--resume-run <id>` na PRÓPRIA linha de comando: o run_id da parada vem dali (lido, não adivinhado). As chaves do S3 do run retomado ficam sob o id ANTIGO, então pid+hora não achariam nada
  newcase; export D2_FREE_MB=2500 STUB_AWS_FAIL=1      # S3 fora do ar: o id só pode vir da linha de comando
  mk_allow "$D2_ALLOWLIST" "^bash ${T}/fakejob-A\.sh( |\$)" "$ALLOW_PRE" 3072 8000 21-6 3600
  spawn "$T/fakejob-A.sh" --resume-run "$RID_OK"; stub_env_for_job
  run_sut --run
  eq "S16 job retomado parado: rc 0" "$RC" 0
  eq "S16 o STOPPED carrega o run_id da linha de comando (com o S3 fora do ar)" "$(sed -n 2p "$D2_STATE" | cut -f6)" "$RID_OK"
  has "S16 a linha traz o run_id" "$OUT" "run_id $RID_OK"
  reap
  export D2_FREE_MB=9000; run_sut --resume
  eq "S16 o --resume seguinte retoma esse mesmo run: rc 0" "$RC" 0
  has "S16 ...e o submit leva o run_id da linha de comando" "$(cat "$STUB_LC_LOG")" "$RID_OK"
  newcase; export D2_FREE_MB=2500 STUB_AWS_FAIL=1      # id com cara de comando na linha de comando: não é tomado como run_id
  mk_allow "$D2_ALLOWLIST" "^bash ${T}/fakejob-A\.sh( |\$)" "$ALLOW_PRE" 3072 8000 21-6 3600
  spawn "$T/fakejob-A.sh" --resume-run "1793-5;touch $C/PWNED"; stub_env_for_job
  run_sut --run
  eq "S16 id mal formado na linha de comando: o run_id fica '-' (não adivinha)" "$(sed -n 2p "$D2_STATE" | cut -f6)" "-"
  [ ! -e "$C/PWNED" ]; check $? "S16 nada foi executado"
  reap
}

SCENARIOS="s_usage s_dry_run s_real_allowlist s_real_df s_recheck_unreadable s_stop_unproven s_stop_guard s_stop_ok s_stop_ambiguous s_stop_s3_down s_stubborn s_parent_guard s_df_unreadable s_ps_unreadable s_broad_regex s_allowlist_invalid s_state_unwritable s_lock"   # (a lista final, com os r_*, é montada depois dos cenários de retomada)
# ═════════════════ CENÁRIOS DE RETOMADA ═══════════════════════════════════════════════════════════════════════════════════
RID_OK="1793502901-66632"
r_nothing() { newcase; export D2_FREE_MB=9000; run_sut --resume; eq "R1 nada pendente: rc 10" "$RC" 10; }

r_hysteresis() {
  newcase; export D2_FREE_MB=6000; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  run_sut --resume
  eq "R2 livre 6000 < 8000: rc 10 (adiado)" "$RC" 10
  [ ! -s "$STUB_LC_LOG" ]; check $? "R2 o launchctl NÃO foi chamado"
}

r_window() {
  newcase; export D2_FREE_MB=9000 D2_HOUR=14; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  run_sut --resume
  eq "R3 fora da janela 21-6 (14h): rc 10" "$RC" 10
  [ ! -s "$STUB_LC_LOG" ]; check $? "R3 o launchctl NÃO foi chamado"
  export D2_HOUR=3; run_sut --resume; eq "R3 03h está na janela (21-6 vira a meia-noite): lança" "$RC" 0
}

r_launch_ok() {
  newcase; export D2_FREE_MB=9000; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  run_sut --resume
  eq "R4 disco ok + janela + run_id: rc 0 (retomou)" "$RC" 0
  local lc; lc=$(cat "$STUB_LC_LOG")
  has "R4 submit levou --resume-run" "$lc" "--resume-run"
  has "R4 submit levou o run_id lido do registro" "$lc" "$RID_OK"
  has "R4 submit chamou o rfb_stream_refresh.py" "$lc" "/nonexistent-root/scripts/rfb_stream_refresh.py"
  has "R4 submit levou o teto de memória do plist (RFB_STREAM_MEMORY_LIMIT)" "$lc" "RFB_STREAM_MEMORY_LIMIT=2GB"
  has "R4 submit levou o teto de RSS do plist" "$lc" "RFB_STREAM_RSS_CEILING_GIB=4"
  has "R4 submit usa o job_timeout.sh (--soft)" "$lc" "job_timeout.sh"
  eq "R4 o registro ganhou RESUME_STARTED" "$(tail -n 1 "$D2_STATE" | cut -f2)" "RESUME_STARTED"
  run_sut --resume; eq "R14 depois de retomada não há mais pendente: rc 10" "$RC" 10
}

r_refused() {  # o job de brinquedo roda DE VERDADE dentro do launchd de brinquedo (STUB_LC_RUN) e sai com o rc 3 do portão dele
  newcase; mk_rfb_root exit3; export D2_FREE_MB=9000; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  run_sut --resume
  eq "R5 o job recusa (rc 3 NÃO RODEI): rc 10" "$RC" 10
  eq "R5 o registro ganhou RESUME_REFUSED" "$(tail -n 1 "$D2_STATE" | cut -f2)" "RESUME_REFUSED"
  has "R5 a linha diz que o job recusou" "$OUT" "recusou"
  eq "R5 o job rodou uma vez" "$(toy_runs)" 1
  printf 'long\n' >"$RFBROOT/toy.mode"; run_sut --resume
  eq "R5 segue pendente: na próxima tentativa o job sobe (rc 0)" "$RC" 0
  eq "R5 ...e rodou de novo (2 execuções)" "$(toy_runs)" 2
  reap
}

r_crash() {
  newcase; mk_rfb_root exit1; export D2_FREE_MB=9000; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  run_sut --resume
  eq "R6 o job sai com rc 1 antes da vigia: rc 20" "$RC" 20
  eq "R6 o registro ganhou RESUME_FAILED" "$(tail -n 1 "$D2_STATE" | cut -f2)" "RESUME_FAILED"
  has "R6 a linha manda retomar à mão com o run_id" "$OUT" "$RID_OK"
  has "R6 a linha diz o rc com que o job saiu" "$OUT" "rc 1"
}

r_no_guess() {  # run_id '-' e S3 ilegível: NÃO inventa
  newcase; export D2_FREE_MB=9000 STUB_AWS_FAIL=1; state_line STOPPED 66632 "$NOW0" "-"
  run_sut --resume
  eq "R7 sem run_id e S3 ilegível: rc 30 (não adivinha)" "$RC" 30
  [ ! -s "$STUB_LC_LOG" ]; check $? "R7 o launchctl NÃO foi chamado"
  eq "R7 segue pendente" "$(tail -n 1 "$D2_STATE" | cut -f2)" "STOPPED"
}

r_derive() {  # run_id '-' mas o S3 acha: usa pid + hora de início do processo parado
  newcase; export D2_FREE_MB=9000; export STUB_AWS_PID=66632 STUB_AWS_EPOCH=1793502901
  state_line STOPPED 66632 1793502901 "-"
  run_sut --resume
  eq "R12 run_id achado no S3 (pid + hora): rc 0" "$RC" 0
  has "R12 submit levou o run_id derivado" "$(cat "$STUB_LC_LOG")" "$RID_OK"
}

r_bad_rid() {
  newcase; export D2_FREE_MB=9000; state_line STOPPED 66632 "$NOW0" "1793-5;touch $C/PWNED"
  run_sut --resume
  eq "R8 run_id com cara de comando: rc 10 (abandonado)" "$RC" 10
  [ ! -e "$C/PWNED" ]; check $? "R8 nada foi executado"
  hasnt "R8 o lixo não chegou ao launchctl" "$(cat "$STUB_LC_LOG")" "PWNED"
  eq "R8 o registro ganhou ABANDONED" "$(tail -n 1 "$D2_STATE" | cut -f2)" "ABANDONED"
}

r_too_old() {
  newcase; export D2_FREE_MB=9000; state_line STOPPED 66632 "$NOW0" "$RID_OK" "$((NOW0 - 7200))"
  run_sut --resume
  eq "R9 parado há 2 h > validade 1 h: rc 10 (abandonado)" "$RC" 10
  [ ! -s "$STUB_LC_LOG" ]; check $? "R9 o launchctl NÃO foi chamado"
  eq "R9 o registro ganhou ABANDONED" "$(tail -n 1 "$D2_STATE" | cut -f2)" "ABANDONED"
}

r_already_running() {
  newcase; export D2_FREE_MB=9000; spawn "$T/fakejob-A.sh"; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  run_sut --resume
  eq "R10 o job já voltou a rodar: rc 10 (abandonado)" "$RC" 10
  [ ! -s "$STUB_LC_LOG" ]; check $? "R10 o launchctl NÃO foi chamado"
  reap
}

r_plist_unreadable() {
  newcase; export D2_FREE_MB=9000 D2_RFB_PLIST="$C/nao-existe.plist"; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  run_sut --resume
  eq "R11 plist ilegível: rc 30 (não chuta o ambiente)" "$RC" 30
  ! grep -q '^--- submit' "$STUB_LC_LOG"; check $? "R11 nenhum submit"
}

r_not_in_allowlist() {
  newcase; export D2_FREE_MB=9000; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  sed -i.bak 's/joba/jobz/' "$D2_ALLOWLIST"
  run_sut --resume
  eq "R13 job que saiu da allowlist: rc 10 (abandonado)" "$RC" 10
  has "R13 o registro diz o MOTIVO (saiu da allowlist)" "$(tail -n 1 "$D2_STATE")" "saiu da allowlist"
  [ ! -s "$STUB_LC_LOG" ]; check $? "R13 o launchctl NÃO foi chamado"
}

r_submit_fails() {
  newcase; export D2_FREE_MB=9000 STUB_LC_SUBMIT_FAIL=1; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  run_sut --resume
  eq "R15 launchctl submit falha: rc 20" "$RC" 20
}

r_lock() {  # mesmo contrato de trava do --run (S13): rc igual (10 x 30) não basta, a CAUSA na linha é o que distingue "outra instância" de "não consegui criar a trava"
  newcase; export D2_FREE_MB=9000; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  mkdir -p "$D2_LOCK"; printf '%s' "$$" >"$D2_LOCK/pid"
  run_sut --resume
  eq "R16 trava com dono vivo: rc 10 (outra instância)" "$RC" 10; has "R16 ...e a linha diz 'outra instância'" "$OUT" "outra instância"
  [ ! -s "$STUB_LC_LOG" ]; check $? "R16 o launchctl NÃO foi chamado"
  eq "R16 segue pendente" "$(tail -n 1 "$D2_STATE" | cut -f2)" "STOPPED"
  newcase; export D2_FREE_MB=9000; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  : >"$C/umarquivo"; export D2_LOCK="$C/umarquivo/lock.d"
  run_sut --resume
  eq "R17 trava que não dá para criar (erro de gravação): rc 30, não é 'outra instância'" "$RC" 30; has "R17 ...a causa na linha é a trava" "$OUT" "a trava"
  hasnt "R17 ...e a linha não diz 'outra instância'" "$OUT" "outra instância"
  [ ! -s "$STUB_LC_LOG" ]; check $? "R17 o launchctl NÃO foi chamado (sem trava, não retoma)"
  eq "R17 segue pendente" "$(tail -n 1 "$D2_STATE" | cut -f2)" "STOPPED"
}

r_start_record() {  # o job subiu (rc 0) mas o RESUME_STARTED não gravou: o buraco no registro NÃO passa em silêncio (stdout e log)
  newcase; export D2_FREE_MB=9000; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  chmod 444 "$D2_STATE"
  ( : >>"$D2_STATE" ) 2>/dev/null; [ $? -ne 0 ]; check $? "R18 pré-condição: o registro está não gravável (rodando como root não vale)"
  run_sut --resume
  eq "R18 submit ok com o registro não gravável: rc 0 (o job subiu)" "$RC" 0
  has "R18 o submit foi feito" "$(cat "$STUB_LC_LOG")" "--- submit"
  has "R18 a linha traz ALERTA" "$OUT" "ALERTA"; has "R18 ...e nomeia o RESUME_STARTED que não gravou" "$OUT" "RESUME_STARTED"
  has "R18 o log traz o ALERTA" "$(cat "$D2_LOG" 2>/dev/null)" "ALERTA"
  eq "R18 o registro segue com o STOPPED (nada gravado)" "$(tail -n 1 "$D2_STATE" | cut -f2)" "STOPPED"
  chmod 644 "$D2_STATE"
}

r_list_fails() {  # launchctl list quebrado (rc 1) != "o launchd não conhece o rótulo" (113): não sei se já há retomada viva, então NÃO lança outra por cima
  newcase; export D2_FREE_MB=9000 STUB_LC_MODE=listfail; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  run_sut --resume
  eq "R19 launchctl list quebrado: rc 30 (não sei se há retomada viva)" "$RC" 30; has "R19 ...a causa na linha é o launchctl list" "$OUT" "launchctl list"
  ! grep -q '^--- submit' "$STUB_LC_LOG"; check $? "R19 nenhum submit"
  eq "R19 segue pendente" "$(tail -n 1 "$D2_STATE" | cut -f2)" "STOPPED"
}

r_lifecycle() {  # `launchctl submit` é KeepAlive: o launchd relança o job depois de TODA saída (~10 s), até o `remove`. O job que acaba DEPOIS da vigia tem de levar o rótulo embora
  local mode want
  for mode in ok-after2 fail-after2; do
    want=0; [ "$mode" = fail-after2 ] && want=1
    newcase; mk_rfb_root "$mode"; export D2_FREE_MB=9000; state_line STOPPED 66632 "$NOW0" "$RID_OK"
    run_sut --resume
    eq "R20 ($mode) o job segue vivo depois da vigia: rc 0 (retomou)" "$RC" 0
    label_gone 10; check $? "R20 ($mode) quando o job acaba o rótulo SOME do launchd (sem isso o KeepAlive o relança)"
    sleep 3      # três vezes o intervalo de relançamento do launchd de brinquedo
    eq "R20 ($mode) o job rodou UMA vez: o launchd não o relançou" "$(toy_runs)" 1
    eq "R20 ($mode) o código de saída do job ficou guardado (rc $want)" "$(cat "$RCFILE" 2>/dev/null)" "$want"
    reap
  done
}

r_stop_again() {  # a escada para de novo o job que ela mesma retomou (D2 --run: TERM no python): o launchd não pode desfazer a parada relançando o job
  newcase; mk_rfb_root long; export D2_FREE_MB=9000; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  run_sut --resume
  eq "R21 retomou: rc 0" "$RC" 0
  local tp; tp=$(cat "$RFBROOT/toy.pid" 2>/dev/null)
  own_pid "$tp"; check $? "R21 pré-condição: o job de brinquedo está vivo e é deste selftest (pid ${tp:-?})"
  kill_own TERM "$tp"      # toy.pid é arquivo de pid: só leva TERM se o pid ainda for o toy (linha de comando sob o $T)
  label_gone 10; check $? "R21 o job levou TERM e o rótulo SOME (o launchd não relança o que a escada acabou de parar)"
  sleep 3
  eq "R21 o job rodou UMA vez (não voltou sozinho)" "$(toy_runs)" 1
  eq "R21 o código que ficou é o do TERM (143)" "$(cat "$RCFILE" 2>/dev/null)" 143
  reap
}

r_stale_rc() {  # o código de saída de uma retomada ANTERIOR (um 0 velho) não pode ser lido como o desta, nem impedir o job de rodar
  newcase; mk_rfb_root exit3; export D2_FREE_MB=9000; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  printf '0\n' >"$RCFILE"
  run_sut --resume
  eq "R22 com um rc 0 velho no arquivo o job rodou mesmo assim" "$(toy_runs)" 1
  eq "R22 ...e o código lido é o DESTE job (3, recusou): rc 10" "$RC" 10
  eq "R22 ...o registro é RESUME_REFUSED, não RESUME_STARTED" "$(tail -n 1 "$D2_STATE" | cut -f2)" "RESUME_REFUSED"
  reap
}

r_no_code() {  # o rótulo sumiu dentro da vigia e NÃO deixou código de saída: não sei o que houve → rc 20, nunca "terminou bem"
  newcase; export D2_FREE_MB=9000 STUB_LC_MODE=gone; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  run_sut --resume
  eq "R23 rótulo sumiu sem código de saída: rc 20" "$RC" 20
  has "R23 a linha diz que não leu o código" "$OUT" "não li o código"
  eq "R23 o registro ganhou RESUME_FAILED" "$(tail -n 1 "$D2_STATE" | cut -f2)" "RESUME_FAILED"
}

r_list_fails_after() {  # launchctl list quebra DEPOIS do submit (rc 1, que NÃO é o 113 de "sumiu"): não sei se a retomada está de pé → rc 20, nunca "viva"
  newcase; export D2_FREE_MB=9000 STUB_LC_MODE=listfail2; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  run_sut --resume
  eq "R24 launchctl list quebra depois do submit: rc 20" "$RC" 20
  has "R24 a causa na linha é o launchctl list" "$OUT" "launchctl list"
  eq "R24 o registro ganhou RESUME_FAILED" "$(tail -n 1 "$D2_STATE" | cut -f2)" "RESUME_FAILED"
}

r_rc_unclearable() {  # não consigo apagar o código de saída da retomada anterior (aqui o caminho é uma PASTA, que `rm -f` não apaga): não sei ler o próximo → rc 30 e nada é lançado
  newcase; mk_rfb_root exit3; export D2_FREE_MB=9000; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  mkdir -p "$RCFILE/dentro"
  run_sut --resume
  eq "R25 código de saída anterior que não dá para apagar: rc 30" "$RC" 30
  has "R25 a causa na linha é esse arquivo" "$OUT" "não consegui apagar"
  ! grep -q '^--- submit' "$STUB_LC_LOG"; check $? "R25 nenhum submit (o job não foi lançado)"
  eq "R25 segue pendente" "$(tail -n 1 "$D2_STATE" | cut -f2)" "STOPPED"
}

r_remove_fails_once() {  # o `remove` do wrapper FALHA uma vez: o launchd relança o wrapper, que já achou o código gravado e NÃO roda o job de novo — só tenta remover outra vez
  newcase; mk_rfb_root ok-after2; export D2_FREE_MB=9000 STUB_LC_REMOVE_FAILS=1; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  run_sut --resume
  eq "R26 retomou: rc 0" "$RC" 0
  label_gone 12; check $? "R26 o rótulo some na 2ª tentativa de remover (o wrapper relançado)"
  sleep 3
  eq "R26 o wrapper foi lançado 2 vezes (o remove falhou na 1ª)" "$(wc -l <"$STUB_LC_LOG.runs" | tr -d ' ')" 2
  eq "R26 ...mas o JOB rodou uma vez só" "$(toy_runs)" 1
  reap
}

r_reread() {  # outra instância TERMINA entre a minha 1ª leitura do registro e eu tomar a trava: o que li já não vale, releio com a trava na mão (senão ABANDONED por cima de um RESUME_STARTED, ou lançamento em dobro)
  newcase; export D2_FREE_MB=9000 D2_LOCK_WAIT_S=3; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  mkdir -p "$D2_LOCK"      # pasta de trava SEM pid e nova = o dono está começando: o --resume espera o pid aparecer (até D2_LOCK_WAIT_S)
  ( sleep 0.6; state_line RESUME_STARTED 66632 "$NOW0" "$RID_OK"; rm -rf "$D2_LOCK" ) &
  run_sut --resume; wait
  eq "R27 a outra instância retomou enquanto eu esperava a trava: rc 10 (nada a retomar)" "$RC" 10
  [ ! -s "$STUB_LC_LOG" ]; check $? "R27 o launchctl NÃO foi chamado (não retomo o que já foi retomado)"
  eq "R27 o registro termina no RESUME_STARTED da outra instância (nada por cima)" "$(tail -n 1 "$D2_STATE" | cut -f2)" "RESUME_STARTED"
}

r_launchctl_abs() {  # o wrapper chama o launchctl pelo caminho ABSOLUTO: o PATH do job é o do plist do rfb e pode não ter /bin; sem o `remove` o KeepAlive relança o job
  local oldp=$PATH
  newcase; export D2_FREE_MB=9000 D2_LAUNCHCTL_BIN=stub-launchctl PATH="$T:$PATH"; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  run_sut --resume
  PATH=$oldp
  eq "R29 launchctl dado por NOME no ambiente do D2: retomou (rc 0)" "$RC" 0
  has "R29 o wrapper recebeu o launchctl pelo caminho absoluto" "$(cat "$STUB_LC_LOG")" "$T/stub-launchctl"
}

r_pending_unreadable() {  # o registro existe e não consigo LÊ-LO: rc 30, nunca "nada a retomar" (terceiro estado: sem arquivo != arquivo ilegível)
  newcase; export D2_FREE_MB=9000; state_line STOPPED 66632 "$NOW0" "$RID_OK"
  chmod 000 "$D2_STATE"
  ( : <"$D2_STATE" ) 2>/dev/null; [ $? -ne 0 ]; check $? "R28 pré-condição: o registro está ilegível (rodando como root não vale)"
  run_sut --resume
  eq "R28 registro ilegível: rc 30 (não é 'nada a retomar')" "$RC" 30; has "R28 a causa na linha é o registro" "$OUT" "ler o registro"
  [ ! -s "$STUB_LC_LOG" ]; check $? "R28 o launchctl NÃO foi chamado"
  chmod 644 "$D2_STATE"
}

s_pid_identity() {  # S18: pid LIDO DE ARQUIVO só leva sinal se provar ser desta instância (arquivo velho + pid reaproveitado por outro programa); e o que prova ainda leva (senão "nunca mata" passaria)
  local foreign own out
  newcase
  sleep 300 & foreign=$!; JOBS="$JOBS $foreign"      # "outro programa": a linha de comando dele ("sleep 300") não carrega o $T desta instância
  spawn "$T/fakejob-A.sh"; own=$JOBPID               # um processo DESTA instância
  mkdir -p "$C/failps"; printf '#!/bin/bash\nexit 1\n' >"$C/failps/ps"; chmod +x "$C/failps/ps"
  # lc_cleanup com o ps QUEBRADO: não consegui provar de quem são os pids → ninguém recebe sinal (inerte), os arquivos mesmo assim são consumidos
  printf '%s\n' "$foreign" >"$C/lc.log.sup"; printf '%s\n' "$own" >"$C/lc.log.pid"; : >"$C/lc.log.submitted"
  ( PATH="$C/failps:$PATH"; lc_cleanup ); sleep 0.3      # tempo de um KILL (se houvesse) chegar: sem isso o job_alive logo abaixo pode ver o alvo ainda vivo
  job_alive "$foreign"; check $? "S18 ps quebrado: o pid de outro programa NÃO leva KILL"
  job_alive "$own"; check $? "S18 ps quebrado: nem o nosso (não provei, não sinalizo: estado inerte)"
  [ ! -e "$C/lc.log.sup" ] && [ ! -e "$C/lc.log.pid" ] && [ ! -e "$C/lc.log.submitted" ]; check $? "S18 ps quebrado: os arquivos foram consumidos e o rótulo some (o supervisor não relança)"
  # lc_cleanup com o ps de verdade: o arquivo VELHO aponta para outro programa (.sup) e para o nosso (.pid)
  printf '%s\n' "$foreign" >"$C/lc.log.sup"; printf '%s\n' "$own" >"$C/lc.log.pid"; : >"$C/lc.log.submitted"
  lc_cleanup; sleep 0.3
  job_alive "$foreign"; check $? "S18 o pid de OUTRO programa num arquivo de pid velho NÃO leva KILL"
  job_alive "$own"; [ $? -ne 0 ]; check $? "S18 o pid que prova ser desta instância leva KILL (o teste não passa por 'nunca mata')"
  [ ! -e "$C/lc.log.sup" ] && [ ! -e "$C/lc.log.pid" ]; check $? "S18 cada arquivo de pid vale UMA varredura (a próxima reap não o relê)"
  lc_cleanup; job_alive "$foreign"; check $? "S18 uma 2ª varredura (a reap de depois de cada cenário) deixa o pid de fora em paz"
  # o stub-launchctl: .pid aponta para um programa que NÃO é filho do supervisor (.sup) → `list` não o mostra como PID e `remove` não manda TERM
  newcase; export STUB_LC_RUN=1
  sleep 300 & foreign=$!; JOBS="$JOBS $foreign"      # outro "outro programa", vivo: o de cima pode já ter sido morto por uma implementação ruim da varredura
  : >"$C/lc.log.submitted"; printf '%s\n' "$foreign" >"$C/lc.log.pid"; printf '%s\n' "$own" >"$C/lc.log.sup"      # o pai de $foreign é ESTE shell, não $own: o .pid não é filho do "supervisor"
  job_alive "$foreign"; check $? "S18 stub: pré-condição: o pid de fora está vivo"
  out=$("$T/stub-launchctl" list x 2>/dev/null)
  hasnt "S18 stub: o list não mostra como PID de job o pid que não é filho do supervisor" "$out" '"PID"'
  "$T/stub-launchctl" remove x; job_alive "$foreign"; check $? "S18 stub: o remove não manda TERM ao pid que não é filho do supervisor"
}

SCENARIOS="s_usage s_dry_run s_real_allowlist s_real_df s_recheck_unreadable s_stop_unproven s_stop_guard s_stop_ok s_stop_ambiguous s_stop_s3_down s_stubborn s_parent_guard s_df_unreadable s_ps_unreadable s_broad_regex s_allowlist_invalid s_state_unwritable s_lock s_isolation s_stop_resumed
r_nothing r_hysteresis r_window r_launch_ok r_refused r_crash r_no_guess r_derive r_bad_rid r_too_old r_already_running r_plist_unreadable r_not_in_allowlist r_submit_fails r_lock r_start_record r_list_fails
r_lifecycle r_stop_again r_stale_rc r_no_code r_list_fails_after r_rc_unclearable r_remove_fails_once r_reread r_pending_unreadable r_launchctl_abs s_pid_identity"

SUT="$REAL"
echo "=== disk-recovery-d2-heavy-jobs.selftest.sh ==="
bash -n "$REAL" && ok "o script tem sintaxe válida" || bad "o script tem erro de sintaxe"
[ -x "$REAL" ]; check $? "o script é executável"
head -n 1 "$REAL" | grep -q '^#!/bin/bash'; check $? "o script tem shebang"
for sc in $SCENARIOS; do echo "-- $sc"; $sc; reap; done
eq "toda execução do D2 devolveu exatamente UMA linha no stdout ($RUNS execuções)" "$BADLINES" 0

# ═════════════════ BATERIA DE MUTANTES ═════════════════════════════════════════════════════════════════════════════════════
echo "=== mutantes (cada guarda estragada tem de derrubar o seu cenário) ==="
mkdir -p "$T/mut"
mutate() {  # $1=nome $2=tag $3=linha nova → $T/mut/$1.sh ; rc 1 se a marca não é única ou o resultado não compila
  local n; n=$(grep -c "# MUT:$2\$" "$REAL")
  [ "$n" = 1 ] || { echo "  FAIL: mutante $1: a marca '# MUT:$2' aparece $n vezes no script (deveria ser 1)"; FAIL=$((FAIL + 1)); return 1; }
  NEWLINE="$3" TAG="# MUT:$2" awk '{ if (index($0, ENVIRON["TAG"]) > 0 && substr($0, length($0) - length(ENVIRON["TAG"]) + 1) == ENVIRON["TAG"]) print ENVIRON["NEWLINE"]; else print }' "$REAL" >"$T/mut/$1.sh"
  chmod +x "$T/mut/$1.sh"
  bash -n "$T/mut/$1.sh" 2>/dev/null || { echo "  FAIL: mutante $1 não compila (o teste do mutante estaria medindo um erro de sintaxe)"; FAIL=$((FAIL + 1)); return 1; }
  cmp -s "$REAL" "$T/mut/$1.sh" && { echo "  FAIL: mutante $1 ficou idêntico ao original"; FAIL=$((FAIL + 1)); return 1; }
  return 0
}
kill_mutant() {  # $1=nome $2=tag $3=linha nova $4=cenário
  local before after
  mutate "$1" "$2" "$3" || return 0
  SUT="$T/mut/$1.sh"; QUIET=1; before=$FAIL
  $4; reap
  after=$FAIL; QUIET=0; SUT="$REAL"
  if [ "$after" -gt "$before" ]; then ok "mutante '$1' MORRE no cenário $4 ($((after - before)) asserção(ões) falharam)"
  else bad "mutante '$1' SOBREVIVEU ao cenário $4 (a guarda não está protegida pelo teste)"; fi
  FAIL=$before                                   # as falhas do mutante eram esperadas: não contam como falha do selftest
}
kill_mutant dfread        dfread        '  out=$("$DF_BIN" -Pk "$VOLUME/__nao_existe__" 2>/dev/null) || return 1      # MUT:dfread' s_real_df
kill_mutant dfparse       dfparse       '  printf "%s\n" "$out" | awk '"'"'NR==2 { printf "%d", 1; ok=1 } END { exit ok ? 0 : 1 }'"'"'      # MUT:dfparse' s_real_df
kill_mutant parent        parent        '        if (cmd[p] ~ ENVIRON["RE"]) printf "%s\t%s\t%s\t%d\t%s\n", p, U[p], PP[p], secs(E[p]), cmd[p]   # MUT:parent' s_parent_guard
kill_mutant stopguard     stopguard     '    if false; then       # MUT:stopguard' s_stop_guard
kill_mutant freefail      freefail      '  free=$(read_free_mb) || free=0      # MUT:freefail' s_df_unreadable
kill_mutant pidgone       pidgone       '    [ "$r" -eq 1 ] && return 0      # MUT:pidgone' s_stop_unproven
kill_mutant killunknown   killunknown   '  :                      # MUT:killunknown' s_stop_unproven
kill_mutant recheck       recheck       '    if false; then :; fi      # MUT:recheck' s_recheck_unreadable
kill_mutant lockowner     lockowner     '  return 0      # MUT:lockowner' s_lock
kill_mutant lockunknown   lockunknown   '      :      # MUT:lockunknown' s_lock
kill_mutant lockyoung     lockyoung     '      :      # MUT:lockyoung' s_lock
kill_mutant killescalate  killescalate  '  :                   # MUT:killescalate' s_stubborn
kill_mutant record        record        '      :      # MUT:record' s_stop_ok
kill_mutant recordfirst   recordfirst   '    state_append STOPPING "$id" "$pid" "$start" - "$free" "x" || true      # MUT:recordfirst' s_state_unwritable
kill_mutant hyst          hyst          '    if false; then      # MUT:hyst' r_hysteresis
kill_mutant window        window        '    if false; then      # MUT:window' r_window
kill_mutant noguess       noguess       '        rid="${start}-${pid}"      # MUT:noguess' r_no_guess
kill_mutant ridvalid      ridvalid      '    if false; then      # MUT:ridvalid' r_bad_rid
kill_mutant resumelock    resumelock    '  acquire_lock || finish 10 "outra instância do D2 em execução ($LOCKD): saio sem agir"; lrc=0      # MUT:resumelock' r_lock
kill_mutant startrecord   startrecord   '      0)  state_append RESUME_STARTED "$id" "$pid" "$start" "$rid" "$free" "$LAUNCH_MSG" || true      # MUT:startrecord' r_start_record
kill_mutant listfail      listfail      '  :      # MUT:listfail' r_list_fails
kill_mutant wrapper       wrapper       'RESUME_WRAPPER='"'"'rcf=$1; lab=$2; lc=$3; root=$4; shift 4; ( cd "$root" && exec "$@" ); rc=$?; printf "%s\n" "$rc" >"$rcf"; exit "$rc"'"'"'      # MUT:wrapper' r_lifecycle
kill_mutant wrapperguard  wrapper       'RESUME_WRAPPER='"'"'rcf=$1; lab=$2; lc=$3; root=$4; shift 4; ( cd "$root" && exec "$@" ); rc=$?; printf "%s\n" "$rc" >"$rcf"; "$lc" remove "$lab"; exit "$rc"'"'"'      # MUT:wrapper' r_remove_fails_once
kill_mutant rcclear       rcclear       '  :      # MUT:rcclear' r_stale_rc
kill_mutant rccheck       rccheck       '  :      # MUT:rccheck' r_rc_unclearable
kill_mutant rcread        rcread        '  code=${code:-0}      # MUT:rcread' r_no_code
kill_mutant watchlist     watchlist     '    :      # MUT:watchlist' r_list_fails_after
kill_mutant cmdrid        cmdrid        '        :      # MUT:cmdrid' s_stop_resumed
kill_mutant pendread      pendread      '  pend=$(pending_rows) || true      # MUT:pendread' r_pending_unreadable
kill_mutant reread        reread        '  :      # MUT:reread' r_reread
kill_mutant maxage        maxage        '    if false; then      # MUT:maxage' r_too_old
kill_mutant running       running       '    if false; then      # MUT:running' r_already_running
kill_mutant rowgone       rowgone       '    if false; then      # MUT:rowgone' r_not_in_allowlist
kill_mutant lcabs         lcabs         '  lcabs=$LAUNCHCTL_BIN      # MUT:lcabs' r_launchctl_abs

echo "=== resultado: $PASS passaram, $FAIL falharam ==="
[ "$FAIL" -eq 0 ]
