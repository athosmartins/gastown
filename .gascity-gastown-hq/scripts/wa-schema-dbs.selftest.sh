#!/bin/bash
# wa-schema-dbs.selftest.sh — hermético: um "WA" de mentira (repo git com origin/main + shared/data com bancos de todos os feitios) e um `ssh` de mentira que roda o programa do NÓ num HOME temporário. (ga-kzwlkhh)
#
# ## Contents
#   Build · Falhas do build · Entrega · O nó não confia no mini · Interruptor, lock e run · Consistência · Controle negativo (mutantes)
#
# BUILD: o banco citado e existente vira cópia só-schema (zero linha, mesmo DDL, user_version); DuckDB, banco vazio, PII no DDL e nome de segredo ficam de fora COM motivo; o dado nunca aparece no stage; o banco real não muda (nem sobra -wal/-shm).
# FALHAS: git, varredor de PII, banco travado e "nenhum banco" não entregam nada (rc 3), nunca "nenhum banco" apagando o que o nó tem. ENTREGA: o nó instala, o recibo só nasce depois do sha256 conferido e o placement vem do script do nó;
#   ssh que cai, resposta ilegível ou sha256 diferente do enviado = rc 2 e o recibo antigo fica. NÓ: adulteração (sha256, linhas, caminho com .., link, lixo) é recusada e a loja que existia NÃO muda.
# WSD_S=<script> (caminho ABSOLUTO) testa outra cópia do gerador. Leva ~30 s.
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); WS=${WSD_S:-$HERE/wa-schema-dbs.py}; PII=$HERE/hetzner-pii-scan.py; CLS=$HERE/wa-node-classify.py; RG=$HERE/hetzner-remote-git.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/wsd.XXXXXX"); T=$(cd "$T" && pwd -P); N=0; F=0
trap 'find "$T" -depth -delete 2>/dev/null' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ok() { N=$((N+1)); echo "ok   $N - $1"; }
bad() { N=$((N+1)); F=$((F+1)); echo "FAIL $N - $1"; [ -z "${2:-}" ] || echo "     $2" | head -n 6; return 0; }
has() { printf '%s' "$OUT" | grep -qF -- "$1" && ok "$2" || bad "$2 (faltou: $1)" "$OUT"; }
hasnt() { printf '%s' "$OUT" | grep -qF -- "$1" && bad "$2 (apareceu: $1)" "$OUT" || ok "$2"; }
py() { python3 -I -c "$@"; }

# ── fixture: o WA de mentira (queue.db com 3 linhas e um telefone, WAL, FTS, DDL com telefone, nome de segredo, não-SQLite, vazio, travável, não citado) ────────────────────────────────────────────────────
cat > "$T/mkfix.py" <<'PY'
import os, sqlite3, subprocess, sys
root = sys.argv[1]; os.makedirs(root + "/shared/data"); D = lambda n: root + "/shared/data/" + n
def db(name, ddl, rows=(), wal=False, ver=0):
    c = sqlite3.connect(D(name))
    if wal: c.execute("PRAGMA journal_mode=WAL")
    for s in list(ddl) + list(rows): c.execute(s)
    c.execute("PRAGMA user_version=%d" % ver); c.commit(); c.close()
P = "5511987654321"
db("queue.db", ["CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, phone TEXT DEFAULT '', body TEXT)", "CREATE INDEX ix_phone ON messages(phone)", "CREATE VIEW v_recent AS SELECT id FROM messages ORDER BY id DESC LIMIT 10",
   "CREATE TRIGGER t_ins AFTER INSERT ON messages BEGIN SELECT 1; END"], ["INSERT INTO messages(phone, body) VALUES ('%s', 'oi %s')" % (P, P)] * 3, ver=7)
db("webhook.db", ["CREATE TABLE ev (id INTEGER PRIMARY KEY, payload TEXT)"], ["INSERT INTO ev(payload) VALUES ('%s')" % P], wal=True)
for mod in ("fts5(body)", "fts4(body)", None):   # o sqlite do Python do mini pode não ter FTS5: cai para FTS4 e, sem módulo nenhum, para uma tabela comum (o caso das tabelas-sombra então só prova a cópia comum)
    try: db("fts.db", ["CREATE VIRTUAL TABLE docs USING " + mod if mod else "CREATE TABLE docs (body)", "CREATE TABLE meta (k TEXT)"], ["INSERT INTO docs(body) VALUES ('dados de %s')" % P]); break
    except sqlite3.OperationalError: pass
db("piiddl.db", ["CREATE TABLE t (phone TEXT DEFAULT '5511987654321')"]); db("tokens.db", ["CREATE TABLE t (x TEXT)"]); db("empty.db", [], [], ver=1)
db("locked.db", ["CREATE TABLE t (x TEXT)"], ["INSERT INTO t VALUES ('a')"]); db("uncited.db", ["CREATE TABLE t (x TEXT)"]); db("testonly.db", ["CREATE TABLE t (x TEXT)"])
open(D("analytics.db"), "wb").write(b"\x00" * 8 + b"DUCK" + b"\x00" * 200)
code = {"lib/a.py": 'P = "shared/data/queue.db"\n', "lib/b.py": 'import os\nDB = os.path.join("shared", "data", "webhook.db")\nF = "fts.db"\n',
        "lib/c.py": 'X = ["piiddl.db", "tokens.db", "analytics.db", "empty.db", "locked.db", "ghost.db", "self.db"]\n', "tests/test_a.py": 'T = "shared/data/testonly.db"\n'}
for p, t in code.items():
    os.makedirs(os.path.dirname(os.path.join(root, p)), exist_ok=True); open(os.path.join(root, p), "w").write(t)
g = lambda *a: subprocess.run(["git", "-C", root] + list(a), check=True, capture_output=True)
g("init", "-q", "-b", "main"); g("add", "lib", "tests"); g("commit", "-qm", "f"); g("update-ref", "refs/remotes/origin/main", "HEAD")
PY
python3 -I "$T/mkfix.py" "$T/wa" || { echo "fixture nao montada"; exit 1; }
cat > "$T/nodetest.py" <<'PY'
import hashlib, importlib.util, io, os, sqlite3, subprocess, sys, tarfile
spec = importlib.util.spec_from_file_location("ws", sys.argv[1]); ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
mode, home = sys.argv[2], sys.argv[3]; A = "shared/data/a.db"
def mkdb(rows, tbl="t"):
    p = home + "/tmp.db"
    if os.path.exists(p): os.unlink(p)
    c = sqlite3.connect(p); c.execute("CREATE TABLE %s (x)" % tbl)
    for _ in range(rows): c.execute("INSERT INTO %s VALUES (1)" % tbl)
    c.commit(); c.close(); return open(p, "rb").read()
sha = lambda b: hashlib.sha256(b).hexdigest()
good, full = mkdb(0), mkdb(2)
files, man = {A: good}, {"v": 1, "dbs": {A: {"sha256": sha(good)}}}
if mode == "sha": files[A] = mkdb(0, "u")   # banco válido e vazio, mas OUTRO conteúdo: só o sha256 do manifesto o recusa
elif mode == "linhas": files[A] = full; man["dbs"][A]["sha256"] = sha(full)
elif mode == "notdb": files[A] = b"nao sou sqlite"; man["dbs"][A]["sha256"] = sha(files[A])
elif mode == "traversal": files["shared/data/../../evil.db"] = good; man["dbs"]["shared/data/../../evil.db"] = {"sha256": sha(good)}
elif mode == "mixed": files["shared/data/b.db"] = full; man["dbs"]["shared/data/b.db"] = {"sha256": sha(full)}
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w:gz") as tf:
    import json
    for n, b in list(files.items()) + [("MANIFEST.json", json.dumps(man).encode())]:
        ti = tarfile.TarInfo(n); ti.size = len(b); tf.addfile(ti, io.BytesIO(b))
    if mode == "symlink":
        ti = tarfile.TarInfo("shared/data/l.db"); ti.type = tarfile.SYMTYPE; ti.linkname = "/etc/passwd"; tf.addfile(ti)
payload = b"naoetar" if mode == "garbage" else buf.getvalue()
import base64
prog = ws.NODE_PROG + "\nPAYLOAD = %r\nmain()\n" % base64.b64encode(payload).decode()
r = subprocess.run(["python3", "-I", "-", "whatsapp_automation"], input=prog, capture_output=True, text=True, env=dict(os.environ, HOME=home, GT_REMOTE_GIT=home + "/gt-remote/git", GT_REMOTE_BIN=home + "/gt-remote/bin"))
print(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "SEM-SAIDA", "RC=%d" % r.returncode)
PY
printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$SSH_LOG"' '[ -n "${SSH_FAIL:-}" ] && { echo "ssh: Connection refused" >&2; exit 255; }' '[ -n "${SSH_FAKE_FILE:-}" ] && { cat > /dev/null; cat "$SSH_FAKE_FILE"; exit 0; }' \
  'while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; *) break ;; esac; done' 'shift' 'exec env HOME="$NODE_HOME" GT_REMOTE_GIT="$NODE_HOME/gt-remote/git" GT_REMOTE_BIN="$NODE_HOME/gt-remote/bin" "$@"' > "$T/ssh"
printf '%s\n' '#!/bin/sh' 'echo "git de mentira: falha" >&2' 'exit 128' > "$T/git-quebra"; chmod 755 "$T/ssh" "$T/git-quebra"

# reset: estado do mini (STATE) e do nó (HOME) novos; wsrun roda o gerador com o ambiente de mentira; $EXTRA = VAR=valor a mais (sem espaço no valor)
EXTRA=; K=0
reset() { K=$((K+1)); ST=$T/st$K; NH=$T/nh$K; mkdir -p "$ST" "$NH/gt-remote/bin" "$NH/gt-remote/git"; : > "$T/ssh.log"; }
wsrun() { OUT=$(env WA_SCHEMA_WA_ROOT="$T/wa" WA_SCHEMA_STATE="$ST" WA_SCHEMA_BUSY_S=0.3 WA_SCHEMA_PII="$PII" MBP_SSH="$T/ssh" SSH_LOG="$T/ssh.log" NODE_HOME="$NH" $EXTRA python3 -I "$WS" "$@" 2>&1); RC=$?; }
newout() { O=$(mktemp -d "$T/o.XXXXXX"); }
sha() { py 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
rows() { py 'import sqlite3,sys;c=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True);print(sum(c.execute("select count(*) from "+n).fetchone()[0] for (n,) in c.execute("select name from sqlite_master where type=\"table\" and name not like \"sqlite_%\" and name not like \"docs_%\"")))' "$1"; }
SRC=$T/wa/shared/data

# ── build ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
[ "$(rows "$SRC/queue.db")" = 3 ] && grep -qa 5511987654321 "$SRC/queue.db" && ok "controle: o banco real tem 3 linhas e o telefone (senão 'sem dado no stage' não prova nada)" || bad "controle: fixture"
reset; newout; B0=$O; B_SHA=$(sha "$SRC/queue.db"); W_SHA=$(sha "$SRC/webhook.db"); wsrun build --out "$B0"
[ "$RC" = 0 ] && has 'WASCHEMA ok shared/data/queue.db tabelas=1' "build: rc 0 e a linha do banco (tabelas, bytes)" || bad "build: rc=$RC" "$OUT"
KEYS=$(py 'import json,sys;print(" ".join(sorted(json.load(open(sys.argv[1]))["dbs"])))' "$B0/MANIFEST.json")
[ "$KEYS" = "shared/data/fts.db shared/data/locked.db shared/data/queue.db shared/data/testonly.db shared/data/webhook.db" ] && ok "build: só entram os CITADOS pelo código que existem e passam (uncited.db fora; testonly.db entra: fixado em teste)" || bad "build: chaves do manifesto = $KEYS"
[ "$(rows "$B0/shared/data/queue.db")" = 0 ] && [ "$(rows "$B0/shared/data/webhook.db")" = 0 ] && ok "build: as cópias têm ZERO linha" || bad "build: cópia com linha"
SQ=$(py 'import sqlite3,sys;[print(sorted(r[0] for r in sqlite3.connect(p).execute("select sql from sqlite_master where sql is not null and name not like \"sqlite_%\"").fetchall()), sqlite3.connect(p).execute("pragma user_version").fetchone()) for p in sys.argv[1:]]' "$SRC/queue.db" "$B0/shared/data/queue.db")
[ "$(printf '%s\n' "$SQ" | sort -u | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$SQ" | grep -qF '(7,)' && ok "build: mesmo DDL (tabela, índice, view, trigger) e user_version=7 na cópia" || bad "build: DDL ou user_version diferem" "$SQ"
[ "$(grep -rac 5511987654321 "$B0" | awk -F: '{s+=$2} END {print s+0}')" = 0 ] && ok "build: nenhum telefone do banco real no stage (nem no schema.sql)" || bad "build: telefone no stage"
[ "$(sha "$SRC/queue.db")" = "$B_SHA" ] && [ "$(sha "$SRC/webhook.db")" = "$W_SHA" ] && [ -z "$(ls "$SRC" | grep -e '-wal$' -e '-shm$')" ] && ok "build: o banco real não muda (sha256 igual, WAL sem -wal/-shm de sobra)" || bad "build: o banco real mudou ou deixou -wal/-shm"
for kv in analytics.db:nao-sqlite empty.db:sem-schema piiddl.db:pii-no-ddl:1tel,0cpf tokens.db:nome-de-segredo; do has "WASCHEMA fora shared/data/${kv%%:*}: ${kv#*:}" "build: ${kv%%:*} fica de fora com o motivo ${kv#*:}"; done
has '2 nomes citados sem arquivo' "build: ghost.db e self.db (citados, sem arquivo) são contados e não viram erro"
# ── falhas do build: nada é entregue, nunca "nenhum banco" ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
reset; newout; EXTRA="WA_SCHEMA_GIT=$T/git-quebra"; wsrun build --out "$O"; EXTRA=
[ "$RC" = 3 ] && has 'git-rc-128' "git que falha: rc 3 com o motivo" && [ ! -e "$O/MANIFEST.json" ] && ok "git que falha: nenhum manifesto" || bad "git que falha: rc=$RC" "$OUT"
reset; newout; EXTRA="WA_SCHEMA_PII=/nonexistent/pii.py"; wsrun build --out "$O"; EXTRA=
[ "$RC" = 3 ] && has 'varredor-pii-ilegivel' "varredor de PII ilegível: rc 3, nada sai sem varredura" && [ ! -e "$O/MANIFEST.json" ] && ok "varredor ilegível: nenhum manifesto" || bad "varredor ilegível: rc=$RC" "$OUT"
reset; newout; EXTRA="WA_SCHEMA_REF=HEAD~5"; wsrun build --out "$O"; EXTRA=
[ "$RC" = 3 ] && ok "ref que não existe: rc 3" || bad "ref inexistente: rc=$RC" "$OUT"
reset; newout; py 'import sqlite3,sys,time;c=sqlite3.connect(sys.argv[1]);c.execute("BEGIN EXCLUSIVE");open(sys.argv[2],"w").write("1");time.sleep(12)' "$SRC/locked.db" "$T/lockflag" & LP=$!
i=0; while [ ! -e "$T/lockflag" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
wsrun build --out "$O"; kill $LP 2>/dev/null; wait $LP 2>/dev/null
has 'WASCHEMA fora shared/data/locked.db: ilegivel:OperationalError' "banco travado: fica de fora como ilegível (nunca 'sem schema') e o build segue com os outros"
# ── entrega (ssh de mentira = o programa do nó rodando num HOME temporário) ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
reset; wsrun deliver --from "$B0"
store=$NH/gt-remote/git/schema-dbs/whatsapp_automation
[ "$RC" = 0 ] && has 'placement=absent' "entrega: rc 0 e o placement vem do script do nó (sem o wt-add novo = absent)" || bad "entrega: rc=$RC" "$OUT"
[ "$(sha "$store/shared/data/queue.db")" = "$(sha "$B0/shared/data/queue.db")" ] && [ "$(wc -l < "$store/MANIFEST" | tr -d ' ')" = 5 ] && ok "entrega: a loja do nó tem os 5 bancos (mesmo sha256) e o MANIFEST" || bad "entrega: loja" "$(find "$store" -type f | head)"
REC=$(py 'import json,sys;r=json.load(open(sys.argv[1]));print(r["v"],r["placement"],len(r["dbs"]),r["rig"])' "$ST/delivered.json")
[ "$REC" = "1 absent 5 whatsapp_automation" ] && ok "entrega: recibo v1, placement absent, 5 bancos" || bad "entrega: recibo = $REC"
printf '# schema-dbs-v1\n' > "$NH/gt-remote/bin/hetzner-remote-git.sh"; mkdir -p "$store/shared/data"; : > "$store/shared/data/velho.db"; wsrun deliver --from "$B0"
[ "$(py 'import json,sys;print(json.load(open(sys.argv[1]))["placement"])' "$ST/delivered.json")" = ok ] && has 'placement=ok' "entrega com o marcador schema-dbs-v1 no script do nó: placement ok" || bad "entrega: placement" "$OUT"
[ ! -e "$store/shared/data/velho.db" ] && [ -z "$(ls -A "$NH/gt-remote/git/schema-dbs" | grep -e '^\.new' -e '\.old')" ] && ok "entrega: a loja é trocada INTEIRA (o que sumiu da lista some do nó) e não sobra .new/.old" || bad "entrega: loja velha ou resíduo" "$(ls -A "$NH/gt-remote/git/schema-dbs")"
R1=$(sha "$ST/delivered.json")
EXTRA="SSH_FAIL=1"; wsrun deliver --from "$B0"; EXTRA=
[ "$RC" = 2 ] && [ "$(sha "$ST/delivered.json")" = "$R1" ] && ok "ssh que cai: rc 2 e o recibo antigo fica como estava" || bad "ssh que cai: rc=$RC" "$OUT"
echo "lixo sem a linha esperada" > "$T/reply.txt"; EXTRA="SSH_FAKE_FILE=$T/reply.txt"; wsrun deliver --from "$B0"; EXTRA=
[ "$RC" = 2 ] && [ "$(sha "$ST/delivered.json")" = "$R1" ] && ok "resposta sem a linha SCHEMA-INSTALL: rc 2, recibo intacto" || bad "resposta ilegível: rc=$RC" "$OUT"
echo 'SCHEMA-INSTALL {"ok": true}' > "$T/reply.txt"; EXTRA="SSH_FAKE_FILE=$T/reply.txt"; wsrun deliver --from "$B0"; EXTRA=
[ "$RC" = 2 ] && ok "resposta ok sem bancos: rc 2" || bad "resposta ok sem bancos: rc=$RC" "$OUT"
c_sha_diff() { reset; py 'import json;print("SCHEMA-INSTALL " + json.dumps({"ok": True, "dbs": {"shared/data/queue.db": "0" * 64}, "placement": "ok", "rejected": {}}))' > "$T/reply.txt"; EXTRA="SSH_FAKE_FILE=$T/reply.txt"; wsrun deliver --from "$B0"; EXTRA=; [ "$RC" = 2 ] && [ ! -e "$ST/delivered.json" ]; }
c_sha_diff && ok "o nó diz ok mas com sha256 diferente do enviado: rc 2 e NENHUM recibo" || bad "sha256 diferente do enviado: rc=$RC" "$OUT"
# ── o nó não confia no mini: cada adulteração é recusada e a loja que existia não muda ──────────────────────────────────────────────────────────────────────────────────────────────────────
nodet() { reset; mkdir -p "$NH/gt-remote/git/schema-dbs/whatsapp_automation/shared/data"; echo old > "$NH/gt-remote/git/schema-dbs/whatsapp_automation/shared/data/keep.db"; NT=$(python3 -I "$T/nodetest.py" "$WS" "$1" "$NH" 2>&1); }
nodet ok; printf '%s' "$NT" | grep -q '"ok": true' && printf '%s' "$NT" | grep -q 'RC=0' && [ ! -e "$NH/gt-remote/git/schema-dbs/whatsapp_automation/shared/data/keep.db" ] && ok "nó: payload bom entra e troca a loja" || bad "nó: payload bom" "$NT"
for m in sha:sha256 linhas:linhas notdb:nao-sqlite; do nodet "${m%%:*}"; { printf '%s' "$NT" | grep -q '"ok": false' && printf '%s' "$NT" | grep -q 'nenhum-banco-aceito' && printf '%s' "$NT" | grep -q "shared/data/a.db\": \"${m#*:}\"" && printf '%s' "$NT" | grep -q 'RC=1' && [ -e "$NH/gt-remote/git/schema-dbs/whatsapp_automation/shared/data/keep.db" ]; } && ok "nó: ${m%%:*} -> o banco é recusado (${m#*:}), rc 1 e a loja velha fica" || bad "nó: ${m%%:*}" "$NT"; done
nodet mixed; printf '%s' "$NT" | grep -q '"ok": true' && printf '%s' "$NT" | grep -q '"rejected": {"shared/data/b.db": "linhas"}' && printf '%s' "$NT" | grep -q 'shared/data/a.db' && ok "nó: 1 bom + 1 com linhas -> o bom entra e o outro vai em rejected" || bad "nó: misto" "$NT"
for m in traversal:membro-invalido symlink:membro-invalido garbage:ReadError; do nodet "${m%%:*}"; { printf '%s' "$NT" | grep -q '"ok": false' && printf '%s' "$NT" | grep -q "\"erro\": \"${m#*:}\"" && printf '%s' "$NT" | grep -q 'RC=1' && [ -e "$NH/gt-remote/git/schema-dbs/whatsapp_automation/shared/data/keep.db" ]; } && ok "nó: ${m%%:*} -> payload inteiro recusado e a loja velha fica" || bad "nó: ${m%%:*}" "$NT"; done
# ── interruptor, lock e run ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
reset; wsrun run
[ "$RC" = 0 ] && [ -e "$ST/delivered.json" ] && [ -e "$ST/last/schema.sql" ] && [ -e "$ST/last/MANIFEST.json" ] && [ -z "$(ls "$ST" | grep '^stage-')" ] && ok "run: build + entrega, recibo gravado, o último stage fica em last/ e não sobra stage-*" || bad "run: rc=$RC" "$OUT"
R2=$(sha "$ST/delivered.json"); EXTRA="WA_SCHEMA_GIT=$T/git-quebra"; : > "$T/ssh.log"; wsrun run; EXTRA=
[ "$RC" = 3 ] && [ "$(sha "$ST/delivered.json")" = "$R2" ] && [ ! -s "$T/ssh.log" ] && [ -z "$(ls "$ST" | grep '^stage-')" ] && ok "run com build que falha: rc 3, o ssh nem é chamado, recibo intacto, sem stage-* de sobra" || bad "run com git quebrado: rc=$RC" "$OUT"
c_off() { reset; wsrun run; : > "$T/ssh.log"; : > "$ST/off"; wsrun run; [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qF 'desligado' && [ ! -e "$ST/delivered.json" ] && [ ! -s "$T/ssh.log" ]; }
c_off && ok "interruptor off: rc 0, o recibo é APAGADO (o classificador volta a tratar o banco como mole) e o ssh não é chamado" || bad "interruptor off: rc=$RC" "$OUT"
reset; wsrun build --out "$T/o.off"; : > "$ST/off"; wsrun build --out "$T/o.off2"
[ "$RC" = 0 ] && [ -e "$T/o.off2/MANIFEST.json" ] && ok "interruptor off não impede o build local (só a entrega)" || bad "off + build: rc=$RC" "$OUT"
reset; py 'import fcntl,sys,time;f=open(sys.argv[1]+"/lock","w");fcntl.flock(f,fcntl.LOCK_EX);open(sys.argv[1]+"/flag","w").write("1");time.sleep(8)' "$ST" & LP=$!
i=0; while [ ! -e "$ST/flag" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; wsrun run; kill $LP 2>/dev/null; wait $LP 2>/dev/null
[ "$RC" = 0 ] && has 'outro run em curso' "lock ocupado: rc 0, não faz nada" && [ ! -s "$T/ssh.log" ] && ok "lock ocupado: o ssh não é chamado" || bad "lock ocupado: rc=$RC" "$OUT"
# ── consistência com o classificador, com o wt-add do nó e com o Python 3.9 do mini ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
py 'import importlib.util as u,sys
def L(p,n):
    s=u.spec_from_file_location(n,p);m=u.module_from_spec(s);s.loader.exec_module(m);return m
a,b=L(sys.argv[1],"ws"),L(sys.argv[2],"cls")
sys.exit(0 if a.KEY_RE.pattern==b.SCHEMA_KEY_RE.pattern else 1)' "$WS" "$CLS" && ok "KEY_RE do gerador == SCHEMA_KEY_RE do classificador (o recibo só tem caminhos que os dois entendem)" || bad "KEY_RE diverge do classificador"
grep -qF 'schema-dbs-v1' "$RG" && grep -qF 'schema-dbs-v1' "$WS" && ok "o marcador de placement (schema-dbs-v1) está no wt-add do nó E no programa do nó" || bad "marcador de placement ausente de um dos lados"
py 'import ast,sys;ast.parse(open(sys.argv[1]).read(), feature_version=(3,9))' "$WS" && ok "gramática do Python 3.9 (o /usr/bin/python3 do mini)" || bad "o gerador usa gramática pós-3.9"
py 'import plistlib,sys
d=plistlib.load(open(sys.argv[1],"rb")); a=d["ProgramArguments"]
ok_=d["Label"]=="com.gascity.wa-schema-dbs" and a[:2]==["/usr/bin/python3","-I"] and a[2].endswith("/scripts/wa-schema-dbs.py") and a[-1]=="run" and "RunAtLoad" not in d and d["Nice"]==19 and d["StartCalendarInterval"]=={"Hour":5,"Minute":17}
sys.exit(0 if ok_ else 1)' "$HERE/../packs/town-deltas/assets/com.gascity.wa-schema-dbs.plist" && ok "plist: label, python3 -I + wa-schema-dbs.py run, diário 05:17, nice 19, SEM RunAtLoad (fora do escopo do wait-for-dolt)" || bad "plist com.gascity.wa-schema-dbs fora do combinado"

# ── controle negativo: UMA troca por mutante, o caso designado tem de reprovar (e passar no original) ─────────────────────────────────────────────────────────────────────────────────────────
mut() { # mut <nome> <trecho> <novo> <função do caso>
  local name=$1 W0=$WS; py 'import sys;s=open(sys.argv[1]).read()
if s.count(sys.argv[3])!=1: sys.exit(1)
open(sys.argv[2],"w").write(s.replace(sys.argv[3],sys.argv[4]))' "$W0" "$T/mut-$name.py" "$2" "$3" || { bad "mutante $name: o trecho original não existe exatamente uma vez"; return; }
  if ! "$4" >/dev/null 2>&1; then bad "mutante $name VAZIO: o original já reprova o caso designado"; return; fi
  WS=$T/mut-$name.py; if "$4" >/dev/null 2>&1; then bad "mutante $name SOBREVIVEU"; else ok "mutante $name morreu"; fi; WS=$W0
}
c_pii() { reset; newout; wsrun build --out "$O"; printf '%s' "$OUT" | grep -qF 'piiddl.db: pii-no-ddl' && [ ! -e "$O/shared/data/piiddl.db" ]; }
c_git() { reset; newout; EXTRA="WA_SCHEMA_GIT=$T/git-quebra"; wsrun build --out "$O"; EXTRA=; [ "$RC" = 3 ] && printf '%s' "$OUT" | grep -qF 'git-rc-128'; }
c_secret() { reset; newout; wsrun build --out "$O"; printf '%s' "$OUT" | grep -qF 'tokens.db: nome-de-segredo'; }
c_mix() { nodet mixed; printf '%s' "$NT" | grep -q '"rejected": {"shared/data/b.db": "linhas"}'; }
c_sha() { nodet sha; printf '%s' "$NT" | grep -q '"ok": false.*RC=1'; }
c_trav() { nodet traversal; printf '%s' "$NT" | grep -q '"erro": "membro-invalido"'; }
c_sw() { reset; wsrun run >/dev/null 2>&1; : > "$ST/off"; wsrun run >/dev/null 2>&1; [ ! -e "$ST/delivered.json" ]; }
c_lock() { reset; py 'import sqlite3,sys,time;c=sqlite3.connect(sys.argv[1]);c.execute("BEGIN EXCLUSIVE");open(sys.argv[2],"w").write("1");time.sleep(6)' "$SRC/locked.db" "$T/lockflag2" & LP=$!
  i=0; while [ ! -e "$T/lockflag2" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; newout; wsrun build --out "$O"; kill $LP 2>/dev/null; wait $LP 2>/dev/null; rm -f "$T/lockflag2"; printf '%s' "$OUT" | grep -qF 'locked.db: ilegivel'; }
mut git-rc-ignorado   'if r.returncode not in (0, 1):'             'if False:'                                       c_git
mut pii-desligado     '            if ph or cpf:'                 '            if False:'                           c_pii
mut segredo-aceito    '            if SECRET_RE.search(os.path.basename(rel)):' '            if False:'               c_secret
mut no-sem-sha        'if hashlib.sha256(data).hexdigest() != want:' 'if False:'                                    c_sha
mut no-sem-linhas     'raise ValueError("linhas")'          'pass'                                            c_mix
mut no-sem-caminho    'not (m.name == "MANIFEST.json" or KEY_RE.match(m.name))' 'False'                            c_trav
mut mini-sem-conferir 'any(k not in man["dbs"] or v != man["dbs"][k]["sha256"] for k, v in dbs.items())' 'False'    c_sha_diff
mut off-sem-apagar    '            os.unlink(os.path.join(STATE, "delivered.json"))' '            pass'                 c_sw
mut travado-vira-ok   '    except (OSError, sqlite3.Error) as e:'   '    except ZeroDivisionError as e:'         c_lock

echo; echo "wa-schema-dbs selftest: $((N-F))/$N ok"; [ "$F" = 0 ] && exit 0 || { echo "FAIL=$F"; exit 1; }
