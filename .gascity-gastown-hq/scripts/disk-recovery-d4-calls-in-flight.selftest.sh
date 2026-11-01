#!/bin/bash
# disk-recovery-d4-calls-in-flight.selftest.sh — prova do leitor de "ligação em curso" (ga-1p1i5jr.4.1), com bancos de mentira (sqlite em WAL).
#
# ## Contents
#   O que prova
#
# O QUE PROVA: ok / block / unknown nos TRÊS estados, e que "não consegui ler" nunca vira "não há ligação" (banco ausente, arquivo corrompido,
#   tabela ausente → unknown, exit 2); o bloqueio vence o unknown; linha órfã antiga não segura mas é CONTADA no detalhe; linha sem data segura;
#   estado terminal não segura; banco WAL SEM -shm/-wal abre (a falha medida ao vivo em 01/11: `mode=ro` deu 34 erros em 40 leituras); o arquivo
#   principal do banco não muda; banco que não existe não é criado; a conexão recusa escrita (a premissa do `PRAGMA query_only`).
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
for i, r in enumerate(rows):   # "estado@minutos-atrás" ou "estado@null" (started_at NULL)
    state, _, age = r.partition("@")
    ts = "NULL" if age in ("", "null") else "datetime('now','localtime','-%d minutes')" % int(age)
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
