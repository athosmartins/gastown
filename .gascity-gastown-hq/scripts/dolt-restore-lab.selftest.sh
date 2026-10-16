#!/bin/bash
# dolt-restore-lab.selftest.sh — tests for dolt-restore-lab.sh (ga-ap2dd6).
#
# Hermetic: the REAL dolt CLI on tiny fixture databases (a restore drill that never restores
# proves nothing), a FAKE aws for the S3 path, a scratch HOME and DOLT_ROOT_PATH. Nothing of the
# live city, the live Dolt server, ~/.dolt or any network is touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${LAB_SCRIPT_UNDER_TEST:-$HERE/dolt-restore-lab.sh}"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
command -v dolt >/dev/null 2>&1 || { echo "SKIP: dolt ausente"; exit 0; }
# The lab refuses to run without a real `timeout` (macOS: Homebrew coreutils -> gtimeout), so the suite needs one too.
# Exit 2, not 0: a suite that could not run is not a suite that passed.
TO_REAL="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)"
[ -n "$TO_REAL" ] || { echo "UNKNOWN: nem timeout nem gtimeout no PATH (o laboratorio recusa rodar sem um deles; macOS: brew install coreutils)"; exit 2; }
# Ceiling for one lab run, only so a hung run cannot freeze the suite. Generous on purpose: a restore + flatten at host load ~80
# (two suites at once) took more than 90 s and the cap, not the lab, was what failed.
CAP="${LAB_TEST_CAP:-300}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (esperado '$2', veio '$1')"; fi; }

mkdir -p "$SCRATCH/home" "$SCRATCH/fixhome"
export DOLT_ROOT_PATH="$SCRATCH/fixhome"
# The fixture dolt calls run with the event flush off so no late `dolt send-metrics` writes into the scratch dir while it is
# being removed. Only these calls: the lab sets the switch itself, and a suite-wide export would hide it if it stopped.
DOLT_DISABLE_EVENT_FLUSH=1 dolt config --global --add user.name fixture >/dev/null 2>&1
DOLT_DISABLE_EVENT_FLUSH=1 dolt config --global --add user.email fixture@localhost >/dev/null 2>&1

# mkfix <name> <commits> — db "<name>" with tables issues/comments (N rows each, N=commits) and a file:// backup
mkfix() {
  local name="$1" n="$2" i
  mkdir -p "$SCRATCH/fix/$name-src" && ( export DOLT_DISABLE_EVENT_FLUSH=1; cd "$SCRATCH/fix/$name-src" && dolt init >/dev/null 2>&1 \
    && dolt sql -q "CREATE TABLE issues (id INT PRIMARY KEY, t VARCHAR(40)); CREATE TABLE comments (id INT PRIMARY KEY, b VARCHAR(40));" >/dev/null \
    && dolt add -A && dolt commit -m c0 >/dev/null )
  i=1   # not `seq 1 N`: BSD seq counts DOWN for N=0 and the fixture silently grew two commits
  while [ "$i" -le "$n" ]; do
    ( export DOLT_DISABLE_EVENT_FLUSH=1; cd "$SCRATCH/fix/$name-src" && dolt sql -q "INSERT INTO issues VALUES ($i,'segredo$i'); INSERT INTO comments VALUES ($i,'cpf$i');" >/dev/null \
      && dolt add -A && dolt commit -m "c$i" >/dev/null )
    i=$((i+1))
  done
  ( export DOLT_DISABLE_EVENT_FLUSH=1; cd "$SCRATCH/fix/$name-src" && dolt backup add b "file://$SCRATCH/fix/$name-bk" >/dev/null 2>&1 && dolt backup sync b >/dev/null 2>&1 )
}
# manifest <file> <db> <issues> <comments>
manifest() { printf '{"schema":1,"db":"%s","tables":{"issues":%s,"comments":%s}}\n' "$2" "$3" "$4" > "$1"; }
# jget <report> <dotted.key>
jget() { python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d=d[k]
print(d)' "$1" "$2" 2>/dev/null; }

WD="$SCRATCH/wd"; REP="$SCRATCH/report.json"
# lab <args...> — runs the script with a clean env; sets RC, OUT (stdout), ERR (stderr).
# Capped at 90s: a script that stops finishing must show up as a failed case (rc 124), never as a hung suite.
lab() {
  rm -f "$REP"
  OUT=$(env -u DOLT_ROOT_PATH HOME="$SCRATCH/home" "$TO_REAL" "$CAP" bash "$SCRIPT" run --workdir "$WD" --report "$REP" "$@" 2>"$SCRATCH/err"); RC=$?
  ERR=$(cat "$SCRATCH/err")
}
# mkpath <dir> — symlinks to every tool the lab uses, WITHOUT timeout/gtimeout (the caller adds one if it wants one)
mkpath() {
  local d="$1" t p; mkdir -p "$d"
  for t in dolt python3 date hostname du df awk sed head tail cat cut tr grep mktemp mkdir rm sleep ps find wc ls uname env pkill pgrep dirname basename; do
    p="$(command -v "$t" 2>/dev/null)"; case "$p" in /*) ln -sf "$p" "$d/$t" ;; esac
  done
}
# lab_path <dir> <args...> — like lab, with PATH = that dir only
lab_path() {
  local pd="$1"; shift
  rm -f "$REP"
  OUT=$(env -u DOLT_ROOT_PATH HOME="$SCRATCH/home" PATH="$pd" "$TO_REAL" "$CAP" "$BASH" "$SCRIPT" run --workdir "$WD" --report "$REP" "$@" 2>"$SCRATCH/err"); RC=$?
  ERR=$(cat "$SCRATCH/err")
}
# wrapper <name> <shell-line-for-$1-matching> — a dolt stand-in: runs <body> when the first dolt arg is <arg>, else the real dolt
wrapper() {  # wrapper <file> <first-arg> <body...>
  local f="$SCRATCH/$1" a="$2"; shift 2
  printf '#!/bin/bash\nif [ "$1" = %s ]; then %s; fi\nexec dolt "$@"\n' "$a" "$*" > "$f"; chmod +x "$f"
}
leftovers() { find "$WD" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '; }
# check_clean <label> — the workdir must be empty; when it is not, say WHAT is left (a bare count made a failure undiagnosable)
check_clean() {
  local n; n=$(leftovers)
  check "$n" 0 "$1"
  [ "$n" = 0 ] || echo "      sobrou em \$WD: $(find "$WD" -mindepth 1 -maxdepth 2 2>/dev/null | sed "s#^$WD/##" | head -6 | tr '\n' ' ')"
}

mkfix alpha 5
manifest "$SCRATCH/m.ok.json" alpha 5 5
SRC="file://$SCRATCH/fix/alpha-bk"
SUM_BEFORE=$(cd "$SCRATCH/fix/alpha-bk" && find . -type f | sort | xargs cksum | cksum)

echo "── restore verificado ──"
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 0 "backup bom + manifest certo: rc 0"
check "$(jget "$REP" verdict)" OK "relatorio diz OK"
check "$(jget "$REP" tables.issues.restored)" 5 "contagem restaurada fica no relatorio"
echo "$OUT" | grep -q '^RESULT: OK db=alpha rc=0 ' && ok "linha RESULT legivel por maquina" || bad "linha RESULT: $OUT"
check_clean "workdir limpo no fim (restore apagado, trava solta)"
check "$(cd "$SCRATCH/fix/alpha-bk" && find . -type f | sort | xargs cksum | cksum)" "$SUM_BEFORE" "a ORIGEM nunca e tocada"
check "$(jget "$REP" fetch_s)" None "fetch_s nao medido vira null, nao string vazia"
[ ! -e "$SCRATCH/home/.dolt" ] && ok "o ~/.dolt do usuario do host nao e criado" || bad "criou ~/.dolt no HOME"
if grep -q -E 'segredo|cpf[0-9]' "$REP" "$SCRATCH/err"; then bad "conteudo de linha vazou no relatorio ou no log"; else ok "relatorio e log so tem contagens (nenhum valor de linha)"; fi

echo "── --keep ──"
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" --keep
[ "$RC" -eq 0 ] && [ "$(ls -d "$WD"/run-*/restored/alpha 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && ok "--keep guarda o restaurado" || bad "--keep"
rm -rf "$WD"

echo "── FAIL = checado e quebrado ──"
manifest "$SCRATCH/m.more.json" alpha 6 5
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.more.json"
check "$RC" 1 "restaurado < manifest: rc 1"
echo "$ERR" | grep -q 'issues: restaurado 5 < esperado 6' && ok "o motivo cita a tabela e os numeros" || bad "motivo: $ERR"
printf '{"schema":1,"db":"alpha","tables":{"issues":5,"nao_existe":1}}\n' > "$SCRATCH/m.missing.json"
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.missing.json"
check "$RC" 1 "tabela do manifest ausente no restaurado: rc 1 (ausente nao vira zero nem OK)"
manifest "$SCRATCH/m.less.json" alpha 3 3
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.less.json"
check "$RC" 0 "restaurado >= esperado passa (linhas criadas depois da contagem so somam)"
cp -R "$SCRATCH/fix/alpha-bk" "$SCRATCH/nomanifest-bk"; rm -f "$SCRATCH/nomanifest-bk/manifest"
lab --db alpha --source "file://$SCRATCH/nomanifest-bk" --manifest "$SCRATCH/m.ok.json"
check "$RC" 1 "backup sem o arquivo manifest do dolt: rc 1"
cp -R "$SCRATCH/fix/alpha-bk" "$SCRATCH/broken-bk"; find "$SCRATCH/broken-bk" -name '*.darc' -exec sh -c ': > "$1"' _ {} \;
lab --db alpha --source "file://$SCRATCH/broken-bk" --manifest "$SCRATCH/m.ok.json"
check "$RC" 1 "arquivos do backup esvaziados: rc 1 (nunca OK)"
check_clean "falha tambem limpa o workdir"

echo "── UNKNOWN = nao consegui checar ──"
lab --db alpha --source "$SRC" --manifest "$SCRATCH/nao-existe.json"
check "$RC" 2 "manifest ausente: rc 2"
echo '{"schema":1,"db":"alpha","tables":{}}' > "$SCRATCH/m.empty.json"
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.empty.json"
check "$RC" 2 "manifest SEM tabelas: rc 2 (vazio nao verifica nada, nao e OK)"
echo 'isto nao e json' > "$SCRATCH/m.garbage.json"
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.garbage.json"
check "$RC" 2 "manifest ilegivel: rc 2"
manifest "$SCRATCH/m.other.json" outrodb 5 5
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.other.json"
check "$RC" 2 "manifest de OUTRO banco: rc 2"
check "$(jget "$REP" restore_s | grep -c -E '^[0-9]+$')" 1 "mesmo sem manifest valido o restore e cronometrado"
printf '{"schema":1,"db":"alpha","tables":{"issues; DROP TABLE issues":1}}\n' > "$SCRATCH/m.inject.json"
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.inject.json"
check "$RC" 2 "nome de tabela com SQL no manifest: rc 2"
printf '{"schema":1,"db":"alpha","tables":{"issues":true}}\n' > "$SCRATCH/m.bool.json"
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.bool.json"
check "$RC" 2 "contagem booleana no manifest: rc 2"
LAB_DOLT=/nao/existe/dolt lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "dolt ausente: rc 2"
# a `df` stub that reports 1 KB free (the margin setting is capped, so a huge margin can no longer fake a full disk)
mkpath "$SCRATCH/pb-df"; ln -sf "$TO_REAL" "$SCRATCH/pb-df/timeout"
rm -f "$SCRATCH/pb-df/df"; printf '#!/bin/bash\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "stub 100 99 1 99%% /"\n' > "$SCRATCH/pb-df/df"; chmod +x "$SCRATCH/pb-df/df"
lab_path "$SCRATCH/pb-df" --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "disco insuficiente: rc 2 (nao e falha do backup)"
echo "$ERR" | grep -q 'disco insuficiente' && ok "e o motivo e o disco, nao uma configuracao" || bad "motivo: $ERR"
check_clean "recusa por disco nao deixa nada no workdir"
lab --db alpha --source "$SCRATCH/fix/alpha-bk" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "origem sem esquema file:// ou s3://: rc 2"
lab --db 'a b' --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "nome de banco invalido: rc 2"

echo "── SLOW = passou mas acima do RTO ──"
cat > "$SCRATCH/slow-dolt.sh" <<EOF
#!/bin/bash
[ "\$1" = backup ] && sleep 2
exec dolt "\$@"
EOF
chmod +x "$SCRATCH/slow-dolt.sh"
LAB_DOLT="$SCRATCH/slow-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" --rto-seconds 1
check "$RC" 3 "restore certo mas mais lento que o RTO: rc 3"
check "$(jget "$REP" verdict)" SLOW "relatorio diz SLOW"
LAB_DOLT="$SCRATCH/slow-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.less.json" --rto-seconds 1
manifest "$SCRATCH/m.more2.json" alpha 9 9
LAB_DOLT="$SCRATCH/slow-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.more2.json" --rto-seconds 1
check "$RC" 1 "FAIL vence SLOW quando os dois acontecem"

echo "── workdir e trava ──"
OUT=$(env -u DOLT_ROOT_PATH HOME="$SCRATCH/home" bash "$SCRIPT" run --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" --workdir relativo 2>/dev/null); check "$?" 2 "workdir relativo: rc 2"
OUT=$(env -u DOLT_ROOT_PATH HOME="$SCRATCH/home" bash "$SCRIPT" run --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" --workdir "$SCRATCH/home" 2>/dev/null); check "$?" 2 "workdir = HOME: rc 2"
mkdir -p "$SCRATCH/livedb/.dolt"
OUT=$(env -u DOLT_ROOT_PATH HOME="$SCRATCH/home" bash "$SCRIPT" run --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" --workdir "$SCRATCH/livedb" 2>/dev/null); check "$?" 2 "workdir que e um banco vivo (.dolt): rc 2"
[ -d "$SCRATCH/livedb/.dolt" ] && ok "o banco vivo recusado continua la" || bad "apagou o .dolt"
mkdir -p "$WD/.lab.lock"; sleep 30 & LIVE=$!; echo "$LIVE" > "$WD/.lab.lock/pid"
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "outra rodada viva segura a trava: rc 2"
[ -d "$WD/.lab.lock" ] && ok "a trava alheia nao e apagada por quem foi recusado" || bad "apagou a trava alheia"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 0 "trava de pid morto e recolhida e a rodada roda"
rm -rf "$WD"

echo "── S3 (aws falso) ──"
mkdir -p "$SCRATCH/s3/urblink-test/alpha"; cp -R "$SCRATCH/fix/alpha-bk/." "$SCRATCH/s3/urblink-test/alpha/"
cat > "$SCRATCH/fake-aws.sh" <<'EOF'
#!/bin/bash
m() { echo "$FAKE_S3_ROOT/${1#s3://}"; }
[ "$1" = s3 ] || exit 2
case "$2" in
  ls)   [ -n "${FAKE_AWS_LS_FAIL:-}" ] && exit 1; echo "Total Objects: 3"; echo "   Total Size: $(( $(du -sk "$(m "$5")" | cut -f1) * 1024 ))" ;;
  sync) [ -n "${FAKE_AWS_SYNC_FAIL:-}" ] && exit 1; mkdir -p "$4"; cp -R "$(m "$3")/." "$4/" ;;
esac
EOF
chmod +x "$SCRATCH/fake-aws.sh"
export FAKE_S3_ROOT="$SCRATCH/s3"
LAB_AWS="$SCRATCH/fake-aws.sh" lab --db alpha --source s3://urblink-test/alpha --manifest "$SCRATCH/m.ok.json"
check "$RC" 0 "origem s3://: busca, restaura e confere (rc 0)"
check "$(jget "$REP" source_kind)" s3 "relatorio diz s3"
check "$(jget "$REP" fetch_s | grep -c -E '^[0-9]+$')" 1 "fetch_s medido"
check_clean "a copia buscada e o restaurado somem do workdir"
[ -f "$SCRATCH/s3/urblink-test/alpha/manifest" ] && ok "o 'bucket' de origem continua intacto" || bad "apagou a origem s3"
FAKE_AWS_SYNC_FAIL=1 LAB_AWS="$SCRATCH/fake-aws.sh" lab --db alpha --source s3://urblink-test/alpha --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "aws sync falhou: rc 2 UNKNOWN (credencial/rede nao e backup quebrado)"
FAKE_AWS_LS_FAIL=1 LAB_AWS="$SCRATCH/fake-aws.sh" lab --db alpha --source s3://urblink-test/alpha --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "aws ls falhou: rc 2 (tamanho ilegivel nao vira 0)"
mkdir -p "$SCRATCH/s3/urblink-test/vazio"
LAB_AWS="$SCRATCH/fake-aws.sh" lab --db alpha --source s3://urblink-test/vazio --manifest "$SCRATCH/m.ok.json"
check "$RC" 1 "prefixo S3 vazio: rc 1 (nao ha backup para restaurar)"
rm -rf "$WD"

echo "── flatten ──"
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" --flatten
check "$RC" 0 "restore + flatten: rc 0"
check "$(jget "$REP" flatten.result)" OK "flatten OK"
check "$(jget "$REP" flatten.commits_before)" 7 "commits antes"
check "$(jget "$REP" flatten.commits_after)" 2 "commits depois (raiz + 1 snapshot)"
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$(jget "$REP" flatten.result)" SKIPPED "sem --flatten nada e achatado"
mkfix tiny 0
manifest "$SCRATCH/m.tiny.json" tiny 0 0
lab --db tiny --source "file://$SCRATCH/fix/tiny-bk" --manifest "$SCRATCH/m.tiny.json" --flatten
check "$(jget "$REP" flatten.result)" SKIPPED "historia de 2 commits: nada a achatar"
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.more.json" --flatten
check "$(jget "$REP" flatten.result)" SKIPPED "restore nao verificado: nao achata"
# a flatten whose `reset` silently does nothing must be reported as FAIL, not as a flattened db
cat > "$SCRATCH/noop-reset-dolt.sh" <<EOF
#!/bin/bash
[ "\$1" = reset ] && exit 0
exec dolt "\$@"
EOF
chmod +x "$SCRATCH/noop-reset-dolt.sh"
LAB_DOLT="$SCRATCH/noop-reset-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" --flatten
check "$(jget "$REP" flatten.result)" FAIL "reset que nao faz nada: flatten FAIL"
check "$RC" 0 "e o rc continua sendo o do RESTORE (flatten e pesquisa, nao alarme de backup)"
cat > "$SCRATCH/nogc-dolt.sh" <<EOF
#!/bin/bash
[ "\$1" = gc ] && exit 1
exec dolt "\$@"
EOF
chmod +x "$SCRATCH/nogc-dolt.sh"
LAB_DOLT="$SCRATCH/nogc-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" --flatten
check "$(jget "$REP" flatten.result)" FAIL "dolt gc falhando: flatten FAIL"
# the property the flatten decision (ga-2895yv) rests on: no data lost. A flatten that drops a row between the
# soft reset and the snapshot commit still shrinks the history, so ONLY the per-table recount can catch it.
cat > "$SCRATCH/lossy-dolt.sh" <<EOF
#!/bin/bash
[ "\$1" = add ] && dolt sql -q "DELETE FROM issues WHERE id = 1" >/dev/null 2>&1
exec dolt "\$@"
EOF
chmod +x "$SCRATCH/lossy-dolt.sh"
LAB_DOLT="$SCRATCH/lossy-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" --flatten
check "$(jget "$REP" flatten.result)" FAIL "flatten que perde uma linha: FAIL"
echo "$(jget "$REP" flatten.why)" | grep -q 'contagem-mudou-no-flatten:issues(5->4)' && ok "o motivo cita a tabela e 5->4" || bad "motivo: $(jget "$REP" flatten.why)"

echo "── gate-fix 1: sem 'timeout' o laboratorio recusa (nunca roda sem limite) ──"
LAB_TIMEOUT_BIN=/nao/existe/timeout lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "LAB_TIMEOUT_BIN apontando para o nada: rc 2"
echo "$ERR" | grep -q 'timeout' && ok "o motivo fala de timeout" || bad "motivo: $ERR"
check "$(jget "$REP" restore_s)" None "e nada foi restaurado (restore_s null)"
LAB_TIMEOUT_BIN="$(command -v false)" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "um 'timeout' que nao funciona (sonda falha): rc 2, nao 'restore falhou'"
mkpath "$SCRATCH/pb-none"
lab_path "$SCRATCH/pb-none" --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "PATH sem timeout nem gtimeout (launchd/ssh no macOS): rc 2"
echo "$ERR" | grep -q 'gtimeout' && ok "o motivo ensina o gtimeout (brew install coreutils)" || bad "motivo: $ERR"
mkpath "$SCRATCH/pb-gt"; ln -sf "$TO_REAL" "$SCRATCH/pb-gt/gtimeout"
lab_path "$SCRATCH/pb-gt" --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 0 "PATH so com gtimeout: roda (rc 0)"
check "$(jget "$REP" timeout_bin)" gtimeout "o relatorio diz qual timeout usou"
LAB_RESTORE_TIMEOUT=0 lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "LAB_RESTORE_TIMEOUT=0 (desligaria o limite): rc 2"
LAB_FETCH_TIMEOUT=abc lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "LAB_FETCH_TIMEOUT=abc: rc 2"
check_clean "recusa nao deixa nada no workdir"

echo "── gate-fix 2: restore que nao terminou = UNKNOWN; so o 'nao' do dolt (status 1) e FAIL ──"
# the hang is `sleep 31.<pid of this suite>`: the orphan check below must count only THIS run's sleep (the host runs other suites)
wrapper hang-restore-dolt.sh backup ': > "'"$SCRATCH"'/restore-started"; exec sleep 31.'"$$"''
LAB_RESTORE_TIMEOUT=2 LAB_DOLT="$SCRATCH/hang-restore-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "restore que estoura o tempo: rc 2 (nao e backup quebrado)"
check "$(jget "$REP" verdict)" UNKNOWN "relatorio diz UNKNOWN"
echo "$ERR" | grep -q 'nao terminou' && ok "o motivo diz que nao terminou" || bad "motivo: $ERR"
check_clean "workdir limpo depois do estouro"
wrapper kill-restore-dolt.sh backup 'kill -9 $$'
LAB_DOLT="$SCRATCH/kill-restore-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "restore morto por sinal (kill -9): rc 2"
wrapper panic-restore-dolt.sh backup 'exit 2'
LAB_DOLT="$SCRATCH/panic-restore-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "restore com status 2 (panic do Go, nao o 'nao' do dolt): rc 2"
wrapper refuse-restore-dolt.sh backup 'exit 1'
LAB_DOLT="$SCRATCH/refuse-restore-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 1 "restore recusado pelo dolt (status 1): continua FAIL"
wrapper silent-restore-dolt.sh backup 'exit 0'
LAB_DOLT="$SCRATCH/silent-restore-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "restore que 'termina bem' sem criar o banco: rc 2, nao OK nem FAIL"
wrapper hang-sql-dolt.sh sql 'exec sleep 31'
LAB_SQL_TIMEOUT=2 LAB_DOLT="$SCRATCH/hang-sql-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "contagem que estoura o tempo: rc 2 (nao 'tabela ausente' rc 1)"
check "$(jget "$REP" tables.issues.restored)" None "contagem nao medida fica null no relatorio"
LAB_SQL_TIMEOUT=abc lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "LAB_SQL_TIMEOUT=abc: rc 2"
# The real timeout is 30 s and the hang 120 s: the limit applies to EVERY flatten step, and at host load ~100 even
# `checkout -b` took more than the 8 s this used to use, so which step timed out was luck. Here only the result is
# asserted for the real timeout; the step NAME is asserted with a deterministic stand-in that exits 124 at once.
wrapper hang-gc-dolt.sh gc 'exec sleep 120'
LAB_FLATTEN_TIMEOUT=30 LAB_DOLT="$SCRATCH/hang-gc-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" --flatten
check "$(jget "$REP" flatten.result)" UNKNOWN "passo do flatten que estoura o tempo de verdade: flatten UNKNOWN (nao FAIL)"
echo "$(jget "$REP" flatten.why)" | grep -q 'nao-terminou:' && ok "o motivo diz que o passo nao terminou" || bad "motivo: $(jget "$REP" flatten.why)"
check "$RC" 0 "e o rc segue sendo o do restore"
wrapper st124-gc-dolt.sh gc 'exit 124'
LAB_DOLT="$SCRATCH/st124-gc-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" --flatten
check "$(jget "$REP" flatten.result)" UNKNOWN "dolt gc que sai com 124 (como o timeout): flatten UNKNOWN"
echo "$(jget "$REP" flatten.why)" | grep -q 'nao-terminou:gc' && ok "o motivo cita o passo gc" || bad "motivo: $(jget "$REP" flatten.why)"
wrapper kill-reset-dolt.sh reset 'kill -9 $$'
LAB_DOLT="$SCRATCH/kill-reset-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" --flatten
check "$(jget "$REP" flatten.result)" UNKNOWN "passo do flatten morto por sinal: UNKNOWN"
LAB_DOLT="$SCRATCH/refuse-restore-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" --flatten
check "$RC" 1 "(controle) recusa do dolt com --flatten: rc 1 e flatten pulado"

echo "── gate-fix 3: manifest sem 'db' ou 'schema' conhecido nao verifica nada ──"
mk_m() { printf '%s\n' "$2" > "$SCRATCH/$1"; }
mk_m m.nodb.json '{"schema":1,"tables":{"issues":5,"comments":5}}'
mk_m m.noschema.json '{"db":"alpha","tables":{"issues":5,"comments":5}}'
mk_m m.schema99.json '{"schema":99,"db":"alpha","tables":{"issues":5,"comments":5}}'
mk_m m.schematrue.json '{"schema":true,"db":"alpha","tables":{"issues":5,"comments":5}}'
mk_m m.schemastr.json '{"schema":"1","db":"alpha","tables":{"issues":5,"comments":5}}'
mk_m m.dbnull.json '{"schema":1,"db":null,"tables":{"issues":5,"comments":5}}'
mk_m m.dbnum.json '{"schema":1,"db":7,"tables":{"issues":5,"comments":5}}'
mk_m m.huge.json '{"schema":1,"db":"alpha","tables":{"issues":99999999999999999999999,"comments":5}}'
for pair in "nodb:sem db" "noschema:sem schema" "schema99:schema 99" "schematrue:schema true" "schemastr:schema como texto" "dbnull:db null" "dbnum:db numerico" "huge:contagem gigante"; do
  lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.${pair%%:*}.json"
  check "$RC" 2 "manifest ${pair#*:}: rc 2 (nao OK)"
done
echo "$ERR" | grep -q 'contagem invalida' && ok "contagem gigante e recusada com motivo" || bad "motivo: $ERR"
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.noschema.json"
echo "$ERR" | grep -q 'schema' && ok "o motivo cita o schema" || bad "motivo: $ERR"

echo "── gate-fix 4: aborto, opcao sem valor, margem de disco ──"
LAB_DISK_MARGIN_PCT=abc lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "LAB_DISK_MARGIN_PCT=abc: rc 2 (nao aborta com variavel nao definida)"
echo "$OUT" | grep -q '^RESULT: UNKNOWN ' && ok "e a linha RESULT sai" || bad "sem linha RESULT: $OUT"
LAB_DISK_MARGIN_PCT=08 lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 0 "LAB_DISK_MARGIN_PCT=08 e decimal 8 (nao octal): roda"
LAB_DISK_MARGIN_PCT=99999999999999999999 lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "margem gigante (daria a volta no inteiro de 64 bits): rc 2"
LAB_DISK_MARGIN_PCT=0 lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "margem 0 (desligaria a checagem de disco): rc 2"
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" --rto-seconds abc
check "$RC" 2 "--rto-seconds abc: rc 2"
OUT=$(env -u DOLT_ROOT_PATH HOME="$SCRATCH/home" "$TO_REAL" 60 bash "$SCRIPT" run --workdir "$WD" --report "$REP" --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" --rto-seconds 2>"$SCRATCH/err"); RC=$?
check "$RC" 2 "opcao sem valor no fim da linha: rc 2 (nao gira para sempre)"
grep -q -- '--rto-seconds' "$SCRATCH/err" && ok "e diz qual opcao ficou sem valor" || bad "stderr: $(cat "$SCRATCH/err")"
# the safety net: whatever aborts the script after the traps are armed still ends as UNKNOWN with a RESULT line and a report
rm -f "$REP"; rm -rf "$WD"
OUT=$(env -u DOLT_ROOT_PATH HOME="$SCRATCH/home" DOLT_RESTORE_LAB_LIB=1 bash -c '
  source "$1"; DB=alpha; REPORT="$2"; WORKDIR="$3"
  arm_traps
  : "$VARIAVEL_QUE_NAO_EXISTE"
  echo "NAO DEVIA CHEGAR AQUI"' _ "$SCRIPT" "$REP" "$WD" 2>"$SCRATCH/err"); RC=$?
check "$RC" 2 "aborto no meio do script (variavel nao definida): rc 2"
echo "$OUT" | grep -q '^RESULT: UNKNOWN db=alpha rc=2 ' && ok "o aborto ainda emite a linha RESULT" || bad "saida: $OUT"
echo "$OUT" | grep -q 'NAO DEVIA' && bad "o script seguiu depois do aborto" || ok "e nao segue rodando"
check "$(jget "$REP" verdict)" UNKNOWN "e grava o relatorio com UNKNOWN"
echo "$(jget "$REP" reason)" | grep -q 'abortada' && ok "o motivo diz que abortou" || bad "motivo: $(jget "$REP" reason)"
# a SIGTERM in the middle of the restore: UNKNOWN on the RESULT line, no leftovers, no orphan dolt
rm -f "$SCRATCH/restore-started" "$REP"; rm -rf "$WD"
env -u DOLT_ROOT_PATH HOME="$SCRATCH/home" LAB_DOLT="$SCRATCH/hang-restore-dolt.sh" bash "$SCRIPT" run --workdir "$WD" --report "$REP" \
  --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" >"$SCRATCH/sig.out" 2>"$SCRATCH/sig.err" &
LABP=$!
i=0; while [ ! -e "$SCRATCH/restore-started" ] && [ "$i" -lt 1800 ]; do sleep 0.1; i=$((i+1)); done
kill -TERM "$LABP" 2>/dev/null; wait "$LABP" 2>/dev/null; SIGRC=$?
case "$SIGRC" in 2|143) ok "SIGTERM no restore: o shell sai por sinal ou rc 2 (nunca 0/1/3): $SIGRC" ;; *) bad "SIGTERM no restore saiu com $SIGRC" ;; esac
grep -q '^RESULT: UNKNOWN ' "$SCRATCH/sig.out" && ok "SIGTERM: a linha RESULT diz UNKNOWN" || bad "sem RESULT UNKNOWN: $(cat "$SCRATCH/sig.out")"
check "$(jget "$REP" verdict)" UNKNOWN "SIGTERM: relatorio UNKNOWN"
check_clean "SIGTERM: nada fica no workdir (restaurado e trava saem)"
sleep 1; ORPHANS=$(pgrep -f "sleep 31\.$$" | wc -l | tr -d ' ')
check "$ORPHANS" 0 "SIGTERM: o dolt filho nao fica orfao"
[ "$ORPHANS" -eq 0 ] || pkill -f "sleep 31\.$$" 2>/dev/null

echo "── gate-fix 5: file:// relativo ──"
( cd "$SCRATCH/fix" && env -u DOLT_ROOT_PATH HOME="$SCRATCH/home" "$TO_REAL" "$CAP" bash "$SCRIPT" run --workdir "$WD" --report "$REP" \
    --db alpha --source "file://alpha-bk" --manifest "$SCRATCH/m.ok.json" >"$SCRATCH/out" 2>"$SCRATCH/err" ); check "$?" 2 "--source file://relativo: rc 2 (nao 'restore falhou' rc 1)"
grep -q 'absoluto' "$SCRATCH/err" && ok "o motivo pede caminho absoluto" || bad "motivo: $(cat "$SCRATCH/err")"
lab --db alpha --source "file:///" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "--source file:/// (a raiz): rc 2"

echo "── gate-fix: o que nao deu para ler nao vira OK, nem relatorio velho ──"
# a report that cannot be written must not leave a stale one behind, and the RESULT line must say so
OUT=$(env -u DOLT_ROOT_PATH HOME="$SCRATCH/home" "$TO_REAL" "$CAP" bash "$SCRIPT" run --workdir "$WD" --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json" \
  --report "$SCRATCH/nao-existe-dir/r.json" 2>/dev/null); RC=$?
check "$RC" 0 "relatorio que nao grava nao muda o veredito do restore"
echo "$OUT" | grep -q 'report=falhou' && ok "mas a linha RESULT avisa 'report=falhou'" || bad "RESULT: $OUT"
printf 'RELATORIO VELHO\n' > "$SCRATCH/stale-report.json"
cat > "$SCRATCH/nowrite-py.sh" <<EOF
#!/bin/bash
[ "\$3" = "$SCRATCH/stale-report.json" ] && exit 1
exec python3 "\$@"
EOF
chmod +x "$SCRATCH/nowrite-py.sh"
OUT=$(env -u DOLT_ROOT_PATH HOME="$SCRATCH/home" LAB_PY="$SCRATCH/nowrite-py.sh" "$TO_REAL" "$CAP" bash "$SCRIPT" run --workdir "$WD" --db alpha --source "$SRC" \
  --manifest "$SCRATCH/m.ok.json" --report "$SCRATCH/stale-report.json" 2>/dev/null); RC=$?
[ ! -e "$SCRATCH/stale-report.json" ] && ok "o relatorio da rodada anterior e apagado antes de rodar" || bad "relatorio velho sobreviveu"
# the owner of a lock writes its pid a moment after mkdir: an empty pid is "being written", not "stale"
rm -rf "$WD"; mkdir -p "$WD/.lab.lock"; sleep 30 & LIVE=$!
( sleep 1; echo "$LIVE" > "$WD/.lab.lock/pid" ) &
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "trava com pid ainda sendo gravado: segura (rc 2), nao e recolhida como velha"
[ -d "$WD/.lab.lock" ] && ok "e a trava continua la" || bad "recolheu a trava de quem estava gravando o pid"
kill "$LIVE" 2>/dev/null; wait 2>/dev/null
rm -rf "$WD"; mkdir -p "$WD/.lab.lock"
lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 0 "trava sem pid nenhum, de verdade abandonada: recolhida depois de alguns segundos"
rm -rf "$WD"
LAB_AWS=/nao/existe/aws lab --db alpha --source s3://urblink-test/alpha --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "aws ausente com origem s3://: rc 2"
echo "$ERR" | grep -q 'aws ausente' && ok "o motivo diz 'aws ausente'" || bad "motivo: $ERR"
cat > "$SCRATCH/partial-aws.sh" <<'EOF'
#!/bin/bash
[ "$2" = ls ] && { echo "   Total Size: 1024"; exit 1; }
exec "$FAKE_REAL_AWS" "$@"
EOF
chmod +x "$SCRATCH/partial-aws.sh"
FAKE_REAL_AWS="$SCRATCH/fake-aws.sh" LAB_AWS="$SCRATCH/partial-aws.sh" lab --db alpha --source s3://urblink-test/alpha --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "aws ls que imprime o tamanho mas falha: rc 2 (tamanho nao confiavel)"
rm -rf "$WD"

echo "── dolt tardio: send-metrics recriando o workdir depois da limpeza ──"
# The real dolt starts a detached `dolt send-metrics` after a command. At host load 60-100 it ran AFTER the cleanup and recreated
# $RUN/dolt-home/.dolt, leaving a stray run-* in the workdir (the intermittent "workdir nao ficou vazio" failures of the suite).
# This stand-in is that process made deterministic: unless DOLT_DISABLE_EVENT_FLUSH=1 it waits for its dolt-home to be removed
# and then recreates it. It also records the switch every call saw.
cat > "$SCRATCH/late-dolt.sh" <<EOF
#!/bin/bash
echo "\${DOLT_DISABLE_EVENT_FLUSH:-unset}" >> "$SCRATCH/late-env.log"
if [ "\${DOLT_DISABLE_EVENT_FLUSH:-}" != 1 ] && [ -n "\${DOLT_ROOT_PATH:-}" ]; then
  : > "$SCRATCH/late-spawned"
  ( n=0; while [ -d "\$DOLT_ROOT_PATH" ] && [ "\$n" -lt 600 ]; do sleep 0.2; n=\$((n+1)); done
    mkdir -p "\$DOLT_ROOT_PATH/.dolt" && : > "\$DOLT_ROOT_PATH/.dolt/config_global.json"
    : > "$SCRATCH/late-finished" ) >/dev/null 2>&1 &
fi
exec dolt "\$@"
EOF
chmod +x "$SCRATCH/late-dolt.sh"
# wait_late — give a late process (if the run started one) the time to do its damage: no fixed sleep, so the case does not depend on load
wait_late() { local n=0; while [ -e "$SCRATCH/late-spawned" ] && [ ! -e "$SCRATCH/late-finished" ] && [ "$n" -lt 450 ]; do sleep 0.2; n=$((n+1)); done; }
rm -rf "$WD"; rm -f "$SCRATCH/late-env.log" "$SCRATCH/late-spawned" "$SCRATCH/late-finished"
LAB_DOLT="$SCRATCH/late-dolt.sh" lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 0 "rodada com dolt que dispara processo tardio: rc 0"
wait_late
check "$([ -s "$SCRATCH/late-env.log" ] && sort -u "$SCRATCH/late-env.log" | tr '\n' ' ')" "1 " "todo dolt da rodada recebe DOLT_DISABLE_EVENT_FLUSH=1"
check "$([ -e "$SCRATCH/late-spawned" ] && echo disparou || echo nenhum)" nenhum "nenhum processo tardio chega a ser disparado"
check_clean "e nada recria o workdir depois da limpeza"
# the earliest refusal of all (--db) still runs `dolt version` for the report: the switch must already be on at the top of the run
rm -rf "$WD"; rm -f "$SCRATCH/late-env.log" "$SCRATCH/late-spawned" "$SCRATCH/late-finished"
LAB_DOLT="$SCRATCH/late-dolt.sh" lab --db "nome invalido" --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "--db invalido (a recusa mais cedo de todas): rc 2"
wait_late
check "$([ -s "$SCRATCH/late-env.log" ] && sort -u "$SCRATCH/late-env.log" | tr '\n' ' ')" "1 " "o dolt do relatorio de uma rodada recusada cedo tambem recebe a chave"
check_clean "rodada recusada cedo: nada recria o workdir"
rm -rf "$WD"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
