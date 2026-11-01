#!/bin/bash
# disk-recovery-d2-heavy-jobs.selftest.sh — selftest do degrau D2 da escada de recuperação de disco (ga-1p1i5jr.2).
#
# ## Contents
#   O que prova · Hermetismo · Cenários de parada (S) · Bateria de mutantes
#
# O QUE PROVA. Que o D2 (a) só para o que a allowlist manda, só com o disco no piso e só com o pai certo; (b) nunca age quando não consegue LER o estado (df, ps, allowlist)
# — três estados, "não sei" não vira "baixo" nem "bom"; (c) só afirma que parou depois de PROVAR a morte, e escala TERM→KILL; (d) não para sem antes gravar o registro;
# (e) devolve UMA linha e os códigos do contrato. A retomada (--resume) e os cenários dela vêm na fatia 2/2 (ga-1p1i5jr.2.1).
# Cada guarda tem um MUTANTE: a bateria final estraga uma linha do script (marcada `# MUT:<nome>`) e exige que o cenário correspondente FALHE.
#
# HERMETISMO. Processos de brinquedo (um `bash fakejob-A.sh` num diretório temporário) levam TERM/KILL de verdade — nada além deles. ps/aws/df vêm de stubs ou de
# D2_FREE_MB; a allowlist é a do teste (a real só é lida em modo --dry-run, com ps simulado). O pior que escreve em disco são alguns KB em $TMPDIR. Duração ~1 min.
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

reap() {
  local p
  for p in $JOBS; do kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  JOBS=""
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
chmod +x "$T/stub-ps" "$T/stub-aws"
mkdir -p "$T/tmp"

ALLOW_RE='^bash [^ ]*/fakejob-A\.sh$'
ALLOW_PRE='.*'

mk_allow() {  # $1=arquivo $2=match_re $3=parent_re $4=stop_mb $5=resume_mb $6=janela $7=maxage
  printf 'joba\trfb\t%s\t%s\t%s\t%s\t%s\t%s\tcomo: TERM; retoma com --resume-run\n' "$2" "$3" "$4" "$5" "$6" "$7" >"$1"
}

CASE=0
newcase() {  # cria um diretório de caso, exporta o ambiente do D2 e (opcional) o estado de brinquedo
  CASE=$((CASE + 1)); C="$T/case$CASE"; mkdir -p "$C/city/.gc/logs"
  export D2_CITY="$C/city" D2_STATE="$C/state" D2_LOG="$C/log" D2_LOCK="$C/lock.d" D2_ALLOWLIST="$C/allow.tsv"
  # folgas generosas: o stub responde na hora, então não custam tempo; só evitam falso vermelho com a máquina em swap (load 36 medido em 01/11: S5 já falhou por timeout do S3)
  export D2_TERM_GRACE_S=1 D2_KILL_WAIT_S=6 D2_S3_TIMEOUT_S=15 D2_MAX_MATCH=3
  export D2_AWS_BIN="$T/stub-aws"
  export STUB_AWS_FAIL=0 STUB_AWS_NONE=0 STUB_AWS_AMBIG=0
  export TMPDIR="$T/tmp"
  unset D2_FREE_MB D2_PS_BIN D2_DF_BIN D2_NOW STUB_PS_FILE
  mk_allow "$D2_ALLOWLIST" "$ALLOW_RE" "$ALLOW_PRE" 3072 8000 21-6 3600
}
run_sut() {  # args → OUT (stdout), RC; confere que o stdout é UMA linha
  local n
  OUT=$("$SUT" "$@" 2>"$C/stderr"); RC=$?
  RUNS=$((RUNS + 1))
  n=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
  if [ "$n" != 1 ] || [ -z "$OUT" ]; then BADLINES=$((BADLINES + 1)); bad "stdout deveria ser UMA linha e tem $n (args: $*)"; fi
}
spawn() {  # $1=script → JOBPID
  bash "$1" >/dev/null 2>&1 &
  JOBPID=$!; JOBS="$JOBS $JOBPID"; sleep 0.4
}
stub_env_for_job() { export STUB_AWS_PID="$JOBPID" STUB_AWS_EPOCH="$(date +%s)"; }

# ═════════════════ CENÁRIOS DE PARADA ═══════════════════════════════════════════════════════════════════════════════════════
s_usage() {
  newcase; run_sut; eq "S1 sem argumento: rc 2 (uso)" "$RC" 2
  run_sut --nada; eq "S1 argumento desconhecido: rc 2" "$RC" 2
  run_sut --run --dry-run; eq "S1 dois argumentos: rc 2" "$RC" 2
  run_sut --resume; eq "S1 --resume ainda não existe (fatia 2/2): rc 2" "$RC" 2
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
  has "S5 a linha diz como retomar à mão (com o run_id lido)" "$OUT" "--resume-run "
  has "S5 ...e a partir de que livre" "$OUT" "-${JOBPID} quando livre >= 8000 MB"
  local st; st=$(cat "$D2_STATE" 2>/dev/null)
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
  has "S5b ...e a linha diz que o run_id NÃO foi lido" "$OUT" "run_id NÃO lido"
  reap
}

s_stop_s3_down() {
  newcase; spawn "$T/fakejob-A.sh"; stub_env_for_job; export D2_FREE_MB=2500 STUB_AWS_FAIL=1
  run_sut --run
  eq "S5c S3 ilegível: emergência, para assim mesmo (rc 0)" "$RC" 0
  eq "S5c ...run_id '-' (não adivinha)" "$(sed -n 2p "$D2_STATE" | cut -f6)" "-"
  has "S5c ...e a linha diz que o run_id NÃO foi lido" "$OUT" "run_id NÃO lido"
  reap
}

s_stubborn() {  # ignora TERM: tem de escalar para KILL
  newcase; export D2_FREE_MB=2500
  mk_allow "$D2_ALLOWLIST" '^bash [^ ]*/fakejob-stubborn-A\.sh$' "$ALLOW_PRE" 3072 8000 21-6 3600
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
  eq "S8 df ilegível: rc 30 (não leu, não agiu)" "$RC" 30
  job_alive "$JOBPID"; check $? "S8 o job segue vivo"
  [ ! -e "$D2_STATE" ]; check $? "S8 nada registrado"
  reap
}

s_ps_unreadable() {
  newcase; spawn "$T/fakejob-A.sh"; export D2_FREE_MB=2500 D2_PS_BIN="$T/nao-existe"
  run_sut --run
  eq "S9 ps ilegível: rc 30" "$RC" 30
  job_alive "$JOBPID"; check $? "S9 o job segue vivo"
  reap
}

s_broad_regex() {  # regex larga demais: 4 processos casam, limite 3
  newcase; export D2_FREE_MB=2500
  mk_allow "$D2_ALLOWLIST" '^bash [^ ]*/fakejob-' "$ALLOW_PRE" 3072 8000 21-6 3600
  cp "$T/fakejob-A.sh" "$T/fakejob-B.sh"; cp "$T/fakejob-A.sh" "$T/fakejob-C.sh"; cp "$T/fakejob-A.sh" "$T/fakejob-D.sh"
  local p1 p2 p3 p4
  spawn "$T/fakejob-A.sh"; p1=$JOBPID; spawn "$T/fakejob-B.sh"; p2=$JOBPID; spawn "$T/fakejob-C.sh"; p3=$JOBPID; spawn "$T/fakejob-D.sh"; p4=$JOBPID
  run_sut --run
  eq "S10 regex que casa 4 processos (limite 3): rc 30" "$RC" 30
  local alive=0 p; for p in $p1 $p2 $p3 $p4; do job_alive "$p" && alive=$((alive + 1)); done
  eq "S10 nenhum dos 4 foi tocado" "$alive" 4
  reap
}

s_allowlist_invalid() {
  newcase; export D2_FREE_MB=2500
  printf 'joba\trfb\tx\ty\t3072\t8000\t21-6\t3600\n' >"$D2_ALLOWLIST"; run_sut --run; eq "S11 linha com 8 colunas: rc 30" "$RC" 30
  mk_allow "$D2_ALLOWLIST" "$ALLOW_RE" "$ALLOW_PRE" 8000 3072 21-6 3600; run_sut --run; eq "S11 resume <= stop (sem histerese): rc 30" "$RC" 30
  mk_allow "$D2_ALLOWLIST" "$ALLOW_RE" "$ALLOW_PRE" 3072 8000 21-21 3600; run_sut --run; eq "S11 janela início = fim: rc 30" "$RC" 30
  mk_allow "$D2_ALLOWLIST" '(' "$ALLOW_PRE" 3072 8000 21-6 3600; run_sut --run; eq "S11 regex que não compila: rc 30" "$RC" 30
  printf '# só comentário\n\n' >"$D2_ALLOWLIST"; run_sut --run; eq "S11 allowlist sem linha ativa: rc 30" "$RC" 30
  rm -f "$D2_ALLOWLIST"; run_sut --run; eq "S11 allowlist ausente: rc 30" "$RC" 30
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
}

s_dry_run() {  # só diz; não escreve nada
  newcase; spawn "$T/fakejob-A.sh"; export D2_FREE_MB=2500
  run_sut --dry-run
  eq "S3 --dry-run com o disco no piso: rc 0 (agiria)" "$RC" 0
  has "S3 a linha diz 'pararia'" "$OUT" "pararia joba (pid $JOBPID"
  job_alive "$JOBPID"; check $? "S3 o job segue vivo"
  [ ! -e "$D2_STATE" ] && [ ! -e "$D2_LOG" ] && [ ! -e "$D2_LOCK" ]; check $? "S3 --dry-run não criou estado, log nem trava"
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
  unset D2_FREE_MB D2_PS_BIN; run_sut --dry-run
  has "S2 a leitura REAL do df devolve um inteiro positivo de MB" "$OUT" "livre "
  case "$OUT" in *"livre "[1-9]*) ok "S2 o df real foi lido (inteiro positivo)" ;; *) [ "$RC" = 10 ] && bad "S2 df real não deu inteiro: $OUT" || ok "S2 df real lido (rc $RC)" ;; esac
}

SCENARIOS="s_usage s_dry_run s_real_allowlist s_stop_guard s_stop_ok s_stop_ambiguous s_stop_s3_down s_stubborn s_parent_guard s_df_unreadable s_ps_unreadable s_broad_regex s_allowlist_invalid s_state_unwritable s_lock"

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
kill_mutant parent        parent        '        if (cmd[p] ~ ENVIRON["RE"]) printf "%s\t%s\t%s\t%d\t%s\n", p, U[p], PP[p], secs(E[p]), cmd[p]   # MUT:parent' s_parent_guard
kill_mutant stopguard     stopguard     '    if false; then       # MUT:stopguard' s_stop_guard
kill_mutant freefail      freefail      '  free=$(read_free_mb) || free=0      # MUT:freefail' s_df_unreadable
kill_mutant killescalate  killescalate  '  :                   # MUT:killescalate' s_stubborn
kill_mutant record        record        '      :      # MUT:record' s_stop_ok
kill_mutant recordfirst   recordfirst   '    state_append STOPPING "$id" "$pid" "$start" - "$free" "x" || true      # MUT:recordfirst' s_state_unwritable

echo "=== resultado: $PASS passaram, $FAIL falharam ==="
[ "$FAIL" -eq 0 ]
