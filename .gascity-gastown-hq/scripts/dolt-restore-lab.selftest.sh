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

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (esperado '$2', veio '$1')"; fi; }

mkdir -p "$SCRATCH/home" "$SCRATCH/fixhome"
export DOLT_ROOT_PATH="$SCRATCH/fixhome"
dolt config --global --add user.name fixture >/dev/null 2>&1
dolt config --global --add user.email fixture@localhost >/dev/null 2>&1

# mkfix <name> <commits> — db "<name>" with tables issues/comments (N rows each, N=commits) and a file:// backup
mkfix() {
  local name="$1" n="$2" i
  mkdir -p "$SCRATCH/fix/$name-src" && ( cd "$SCRATCH/fix/$name-src" && dolt init >/dev/null 2>&1 \
    && dolt sql -q "CREATE TABLE issues (id INT PRIMARY KEY, t VARCHAR(40)); CREATE TABLE comments (id INT PRIMARY KEY, b VARCHAR(40));" >/dev/null \
    && dolt add -A && dolt commit -m c0 >/dev/null )
  i=1   # not `seq 1 N`: BSD seq counts DOWN for N=0 and the fixture silently grew two commits
  while [ "$i" -le "$n" ]; do
    ( cd "$SCRATCH/fix/$name-src" && dolt sql -q "INSERT INTO issues VALUES ($i,'segredo$i'); INSERT INTO comments VALUES ($i,'cpf$i');" >/dev/null \
      && dolt add -A && dolt commit -m "c$i" >/dev/null )
    i=$((i+1))
  done
  ( cd "$SCRATCH/fix/$name-src" && dolt backup add b "file://$SCRATCH/fix/$name-bk" >/dev/null 2>&1 && dolt backup sync b >/dev/null 2>&1 )
}
# manifest <file> <db> <issues> <comments>
manifest() { printf '{"schema":1,"db":"%s","tables":{"issues":%s,"comments":%s}}\n' "$2" "$3" "$4" > "$1"; }
# jget <report> <dotted.key>
jget() { python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d=d[k]
print(d)' "$1" "$2" 2>/dev/null; }

WD="$SCRATCH/wd"; REP="$SCRATCH/report.json"
# lab <args...> — runs the script with a clean env; sets RC, OUT (stdout), ERR (stderr)
lab() {
  rm -f "$REP"
  OUT=$(env -u DOLT_ROOT_PATH HOME="$SCRATCH/home" bash "$SCRIPT" run --workdir "$WD" --report "$REP" "$@" 2>"$SCRATCH/err"); RC=$?
  ERR=$(cat "$SCRATCH/err")
}
leftovers() { find "$WD" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '; }

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
check "$(leftovers)" 0 "workdir limpo no fim (restore apagado, trava solta)"
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
check "$(leftovers)" 0 "falha tambem limpa o workdir"

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
LAB_DISK_MARGIN_PCT=99999999 lab --db alpha --source "$SRC" --manifest "$SCRATCH/m.ok.json"
check "$RC" 2 "disco insuficiente: rc 2 (nao e falha do backup)"
check "$(leftovers)" 0 "recusa por disco nao deixa nada no workdir"
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
check "$(leftovers)" 0 "a copia buscada e o restaurado somem do workdir"
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

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
