#!/bin/bash
# disk-recovery-d4-calls-in-flight.selftest.sh — prova do leitor de "ligação em curso" (ga-1p1i5jr.4.1), com bancos de mentira (sqlite em WAL).
#
# ## Contents
#   O que prova
#
# O QUE PROVA: ok / block / unknown nos TRÊS estados, e que "não consegui ler" nunca vira "não há ligação" (banco ausente, arquivo corrompido,
#   tabela ausente → unknown, exit 2); o bloqueio vence o unknown; linha órfã antiga não segura mas é CONTADA no detalhe; linha sem data segura;
#   estado terminal não segura; banco WAL SEM -shm/-wal abre (a falha medida ao vivo em 01/11: `mode=ro` deu 34 erros em 40 leituras); o arquivo
#   principal do banco não muda; banco que não existe não é criado; a conexão recusa escrita (a premissa do `PRAGMA query_only`); a ordem de
#   resolução do banco (PIX_CALL_QUEUE_DEMAND_DB > CLIENTES_DB > padrão sob DR4_WA_DIR); o corte padrão de órfã (240 min, com uma linha de 240,5);
#   --max-age-min 1 aceito; --help rc 0; e o que o leitor passa ao sqlite3.connect (mode=rw, uri=True, timeout=10) por um spy (ga-eedg7fw).
set -uo pipefail

D=$(cd "$(dirname "$0")" && pwd)
CALLS="${DR4_ST_CALLS:-$D/disk-recovery-d4-calls-in-flight.py}"
T=$(mktemp -d "${TMPDIR:-/tmp}/d4-calls-selftest.XXXXXX") || { echo "FAIL: sem diretório temporário"; exit 1; }
trap 'rm -rf "$T" 2>/dev/null' EXIT
PASS=0; FAIL=0
check() {  # $1=descrição; resto = comando de teste
  local d=$1; shift
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $d"; fi
}
chk() {  # $1=descrição; $2=expressão de shell (eval) — para && || ! e $(...)
  local d=$1; shift
  if eval "$*"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $d"; fi
}

cat > "$T/mkfix.py" <<'PYEOF'
import sqlite3, sys
kind, path, rows = sys.argv[1], sys.argv[2], sys.argv[3:]
con = sqlite3.connect(path)
con.execute("PRAGMA journal_mode=WAL")
if kind == "pix":
    con.execute("CREATE TABLE pix_call_log (id INTEGER PRIMARY KEY, call_id TEXT, state TEXT, started_at TEXT, ended_at TEXT, updated_at TEXT)")
    col, table = "state", "pix_call_log"
elif kind == "vb":
    con.execute("CREATE TABLE voicebot_call_log (id INTEGER PRIMARY KEY, call_id TEXT, status TEXT, started_at TEXT, updated_at TEXT)")
    col, table = "status", "voicebot_call_log"
else:   # banco sem a tabela de ligações
    con.execute("CREATE TABLE outra (x INTEGER)"); rows = []; col = table = None
for i, r in enumerate(rows):   # "estado@minutos-atrás", "estado@NNNs" (segundos-atrás: cai ENTRE dois cortes de minutos) ou "estado@null" (started_at NULL)
    state, _, age = r.partition("@")
    if age in ("", "null"):
        ts = "NULL"
    elif age.endswith("s"):
        ts = "datetime('now','localtime','-%d seconds')" % int(age[:-1])
    else:
        ts = "datetime('now','localtime','-%d minutes')" % int(age)
    con.execute("INSERT INTO %s (call_id, %s, started_at) VALUES (?, ?, %s)" % (table, col, ts), ("c%d" % i, state))
con.commit()
con.close()
PYEOF
mkfix() { /usr/bin/python3 -I "$T/mkfix.py" "$@"; }
# moldes: o python do sistema (SQLite 3.51) deixa -wal/-shm ao fechar; só o .db é copiado, então cada cenário parte de um WAL SEM esses arquivos
mkfix pix "$T/pix.empty.db"; mkfix vb "$T/vb.empty.db"
fresh() {  # copia os moldes vazios para $T/pix.db e $T/vb.db
  rm -f "$T"/pix.db* "$T"/vb.db*; cp "$T/pix.empty.db" "$T/pix.db"; cp "$T/vb.empty.db" "$T/vb.db"
}
run() {  # [args...] → RC, OUT (aponta os dois bancos de $T)
  OUT=$(env "PIX_CALL_QUEUE_DEMAND_DB=${PIX:-$T/pix.db}" "VOICEBOT_COST_DB=${VB:-$T/vb.db}" /usr/bin/python3 -I "$CALLS" "$@" 2>&1); RC=$?
}
contains() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }

echo "== ok, e o banco WAL sem -shm/-wal"
fresh
sha_before=$(shasum "$T/pix.db" "$T/vb.db" | awk '{print $1}' | tr '\n' ' ')
no_side_files=0; [ ! -e "$T/pix.db-shm" ] && [ ! -e "$T/pix.db-wal" ] && no_side_files=1
run
check "dois bancos vazios: rc 0 e 'ok' (veio $RC: $OUT)" [ "$RC" = 0 ]
check "precondição: o banco WAL começou SEM -shm/-wal" [ "$no_side_files" = 1 ]
check "banco WAL sem -shm/-wal abre (a falha medida ao vivo: mode=ro dava 34 erros em 40)" [ "$RC" = 0 ]
check "linha de saída começa com 'ok'" contains "ok"
sha_after=$(shasum "$T/pix.db" "$T/vb.db" | awk '{print $1}' | tr '\n' ' ')
check "não alterou o arquivo principal dos bancos" [ "$sha_before" = "$sha_after" ]
chk "o -wal que sobra está VAZIO (nenhuma escrita de dado)" '[ ! -s "$T/pix.db-wal" ] && [ ! -s "$T/vb.db-wal" ]'

echo "== block"
fresh; rm -f "$T/pix.db"; mkfix pix "$T/pix.db" "dialing@3"
run;  check "pix 'dialing' recente: block (rc 1; veio $RC: $OUT)" [ "$RC" = 1 ]
fresh; rm -f "$T/pix.db"; mkfix pix "$T/pix.db" "bridged@30"
run;  check "pix 'bridged' (30 min): block (rc 1)" [ "$RC" = 1 ]
fresh; rm -f "$T/vb.db"; mkfix vb "$T/vb.db" "live@2"
run;  check "voicebot 'live' recente: block (rc 1)" [ "$RC" = 1 ]
fresh; rm -f "$T/pix.db"; mkfix pix "$T/pix.db" "dialing@null"
run;  check "pix 'dialing' SEM data conta como em curso (não dá pra provar que é órfã): rc 1" [ "$RC" = 1 ]
fresh; PIX="$T/pix.db" VB="$T/nao-existe.db" run
chk "ok + unknown = unknown (rc 2)" '[ "$RC" = 2 ]'
fresh; rm -f "$T/pix.db"; mkfix pix "$T/pix.db" "dialing@1"
VB="$T/nao-existe.db" run;  check "block (pix) + unknown (voicebot): o bloqueio vence (rc 1; veio $RC)" [ "$RC" = 1 ]

echo "== órfãs e estados terminais"
fresh; rm -f "$T/pix.db"; mkfix pix "$T/pix.db" "dialing@360" "bridged@500"
run;  check "órfãs antigas (> 4 h) NÃO seguram: rc 0 (veio $RC: $OUT)" [ "$RC" = 0 ]
chk "órfãs antigas: o detalhe as CONTA (não somem em silêncio)" 'contains "2 órfã(s) ignorada(s)"'
fresh; rm -f "$T/pix.db"; mkfix pix "$T/pix.db" "answered_talked@2" "no_answer@1" "voicemail@1"
run;  check "estados terminais recentes NÃO seguram: rc 0" [ "$RC" = 0 ]
fresh; rm -f "$T/vb.db"; mkfix vb "$T/vb.db" "live@600"
run;  check "voicebot 'live' órfão antigo não segura: rc 0" [ "$RC" = 0 ]
run --max-age-min 1000;  check "--max-age-min maior que a idade: a mesma linha volta a segurar (rc 1)" [ "$RC" = 1 ]

echo "== unknown: não consegui ler nunca vira 'não há ligação'"
fresh; PIX="$T/nao-existe.db" run
check "banco ausente: unknown (rc 2; veio $RC: $OUT)" [ "$RC" = 2 ]
check "banco ausente NÃO é criado" [ ! -e "$T/nao-existe.db" ]
fresh; echo "isto não é um banco" > "$T/lixo.db"; PIX="$T/lixo.db" run
check "arquivo corrompido: unknown (rc 2)" [ "$RC" = 2 ]
fresh; rm -f "$T/pix.db"; mkfix outra "$T/pix.db"; run
chk "tabela ausente no pix: unknown (rc 2) e diz qual" '[ "$RC" = 2 ] && contains "tabela pix_call_log ausente"'
fresh; rm -f "$T/vb.db"; mkfix outra "$T/vb.db"; run
chk "tabela ausente no voicebot: unknown (rc 2) e diz qual" '[ "$RC" = 2 ] && contains "tabela voicebot_call_log ausente"'

echo "== qual banco o leitor abre (a ordem PIX_CALL_QUEUE_DEMAND_DB > CLIENTES_DB > padrão sob DR4_WA_DIR)"
# vazio → o padrão sob DR4_WA_DIR (sem nenhuma das variáveis, ele NÃO pode cair num caminho de verdade); falhou/ilegível → unknown (banco ausente), nunca ok
runenv() {  # [VAR=val ...] → RC, OUT; ambiente LIMPO (só o que o caso passa), para a resolução do padrão não herdar nada do shell
  OUT=$(env -i PATH="$PATH" "$@" /usr/bin/python3 -I "$CALLS" 2>&1); RC=$?
}
fresh; rm -f "$T/pix.db"; mkfix pix "$T/pix.db" "dialing@3"
runenv "CLIENTES_DB=$T/pix.db" "VOICEBOT_COST_DB=$T/vb.db" "DR4_WA_DIR=$T/wa-inexistente"
chk "só CLIENTES_DB (sem PIX_CALL_QUEUE_DEMAND_DB): é ele que o leitor abre → block (rc 1) com a ligação do pix" '[ "$RC" = 1 ] && contains "pix: 1 ligação(ões) em curso"'
fresh; rm -f "$T/pix.db"; mkfix pix "$T/pix.db" "dialing@3"
mkdir -p "$T/other"; cp "$T/pix.empty.db" "$T/other/clientes.db"
runenv "PIX_CALL_QUEUE_DEMAND_DB=$T/pix.db" "CLIENTES_DB=$T/other/clientes.db" "VOICEBOT_COST_DB=$T/vb.db" "DR4_WA_DIR=$T/wa-inexistente"
chk "PIX_CALL_QUEUE_DEMAND_DB vence CLIENTES_DB: abre o do pix (block, rc 1), não o vazio do CLIENTES_DB" '[ "$RC" = 1 ] && contains "pix: 1 ligação(ões) em curso"'
mkdir -p "$T/wa/shared/data"; rm -f "$T/wa/shared/data"/*
mkfix pix "$T/wa/shared/data/demand_assignments.db" "dialing@3"; mkfix vb "$T/wa/shared/data/voicebot_cost.db" "live@3"
runenv "DR4_WA_DIR=$T/wa"
chk "sem nenhuma variável de banco: o padrão é <DR4_WA_DIR>/shared/data/{demand_assignments,voicebot_cost}.db → block com os DOIS (rc 1)" '[ "$RC" = 1 ] && contains "pix: 1 ligação(ões) em curso" && contains "voicebot: 1 ligação(ões) em curso"'
runenv "DR4_WA_DIR=$T/wa-inexistente"
chk "sem variável e sem o diretório padrão: unknown (rc 2) com o caminho que tentou, nunca ok" '[ "$RC" = 2 ] && contains "banco ausente ($T/wa-inexistente/shared/data/demand_assignments.db)"'

echo "== o corte padrão de órfã é 240 min (4 h), e --max-age-min 1 é o menor valor aceito"
fresh; rm -f "$T/pix.db"; mkfix pix "$T/pix.db" "dialing@239" ; run
chk "linha de 239 min: ainda em curso com o padrão (block, rc 1)" '[ "$RC" = 1 ]'
fresh; rm -f "$T/pix.db"; mkfix pix "$T/pix.db" "dialing@14430s" ; run
chk "linha de 240,5 min (14430 s): já é órfã com o padrão de 240 (rc 0 e a conta '1 órfã(s) ignorada(s) (> 240 min)')" '[ "$RC" = 0 ] && contains "1 órfã(s) ignorada(s) (> 240 min)"'
run --max-age-min 241;  chk "a mesma linha de 240,5 min com --max-age-min 241: volta a segurar (rc 1)" '[ "$RC" = 1 ]'
fresh; rm -f "$T/pix.db"; mkfix pix "$T/pix.db" "dialing@0" "bridged@5"
run --max-age-min 1;  chk "--max-age-min 1 é ACEITO (não é erro de uso): a linha de 0 min segura (rc 1) e a de 5 min é a órfã contada" '[ "$RC" = 1 ] && contains "1 órfã(s) ignorada(s) (> 1 min)"'

echo "== --help não é erro"
run --help;  chk "--help: rc 0 (pedir ajuda não falha) e mostra o uso" '[ "$RC" = 0 ] && contains "usage:"'

echo "== o que o leitor passa ao sqlite3.connect (a premissa que o resto do teste supõe)"
# O sqlite do sistema é compilado com USE_URI: com uri=False ele ainda entende "file:...?mode=rw", e nenhum teste de COMPORTAMENTO distingue
# uri=True de False aqui (o mutante hq-mutants L80 True→False é equivalente nesse sqlite). Então a chamada é gravada e conferida: três coisas que um
# refactor poderia trocar sem que nada mais reprove — mode=rw (mode=ro deu 34 erros em 40 leituras de um WAL sem -shm/-wal), uri=True (é ele que
# faz o sqlite ler "file:" como URI nos sqlite sem USE_URI) e o timeout de 10 s (quanto o leitor espera uma escrita em curso antes de dizer unknown).
cat > "$T/spy.py" <<'PYEOF'
import os, runpy, sqlite3, sys
real = sqlite3.connect
log = open(os.environ["DR4_SPY_LOG"], "a")
def spy(*a, **k):
    log.write("connect target=%s uri=%r timeout=%r\n" % (a[0] if a else None, k.get("uri"), k.get("timeout")))
    log.flush()
    return real(*a, **k)
sqlite3.connect = spy
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
PYEOF
fresh; : > "$T/spy.log"
SPY_OUT=$(env "PIX_CALL_QUEUE_DEMAND_DB=$T/pix.db" "VOICEBOT_COST_DB=$T/vb.db" "DR4_SPY_LOG=$T/spy.log" /usr/bin/python3 -I "$T/spy.py" "$CALLS" 2>&1); SPY_RC=$?
# vazio → zero linhas = o leitor nem tentou abrir (a asserção abaixo reprova); falhou/ilegível → o spy.log é criado acima, então não há "ausente" aqui
spy_lines=$(wc -l < "$T/spy.log" | tr -d ' ')
check "o leitor roda inteiro sob o spy (rc 0; veio $SPY_RC: $SPY_OUT)" [ "$SPY_RC" = 0 ]
check "abre exatamente DOIS bancos (pix e voicebot), nem mais nem menos (veio $spy_lines)" [ "$spy_lines" = 2 ]
check "pix: file:<db>?mode=rw, uri=True, timeout=10" [ "$(sed -n 1p "$T/spy.log")" = "connect target=file:$T/pix.db?mode=rw uri=True timeout=10" ]
check "voicebot: file:<db>?mode=rw, uri=True, timeout=10" [ "$(sed -n 2p "$T/spy.log")" = "connect target=file:$T/vb.db?mode=rw uri=True timeout=10" ]

echo "== uso e a premissa do query_only"
run --max-age-min 0;  check "--max-age-min 0: erro de uso (rc 64)" [ "$RC" = 64 ]
run --bogus;          check "argumento desconhecido: erro de uso (rc 64)" [ "$RC" = 64 ]
fresh; rm -f "$T/pix.db"; mkfix pix "$T/pix.db" "dialing@1"
w=$(/usr/bin/python3 -I -c "
import sqlite3
c = sqlite3.connect('file:$T/pix.db?mode=rw', uri=True); c.execute('PRAGMA query_only=ON')
try:
    c.execute(\"INSERT INTO pix_call_log (call_id, state) VALUES ('x','dialing')\"); print('escreveu')
except sqlite3.Error:
    print('recusou')
" 2>&1)
check "query_only recusa escrita (a premissa do leitor; veio: $w)" [ "$w" = recusou ]

echo
echo "disk-recovery-d4-calls-in-flight.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
