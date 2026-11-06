#!/usr/bin/env python3
"""wa-schema-dbs.py — cópia SÓ-SCHEMA (DDL, nenhuma linha) dos bancos SQLite de produção do WA para o nó Hetzner (ga-kzwlkhh). Roda no MINI; doc: docs/runbooks/hetzner-wa-node.md

## Contents
  Para que serve · Subcomandos · Segurança · Três estados · Códigos de saída

PARA QUE SERVE: o código do WA fixa `shared/data/x.db` e o nó não tem o arquivo, então a bead que só precisa do CAMINHO ia ao mini. Com a cópia só-schema no mesmo caminho do worktree, o classificador (wa-node-classify.py) deixa de tratar
  esse banco como mole (`mole-banco-com-schema:<db>`) — só se o recibo gravado aqui disser que o nó o TEM e o wt-add dele o põe no worktree (placement ok). DuckDB/MotherDuck (`md:`) seguem duros; teste que lê DADO do banco fica vermelho no nó e volta ao mini.
SUBCOMANDOS: build --out DIR (acha os bancos citados pelo código do WA em origin/main que existem em shared/data, recria o DDL num banco novo, confere zero linha, varre o DDL e escreve DIR/{shared/data/*.db,MANIFEST.json,schema.sql}
  e uma linha WASCHEMA por banco) · deliver --from DIR (ssh ao nó: o nó RECONFERE tudo e troca ~/gt-remote/git/schema-dbs/<rig> de forma atômica; só então grava o recibo .gc/wa-schema-dbs/delivered.json) · run (build + deliver; é o que o launchd chama
  1x por dia). Interruptor: o arquivo .gc/wa-schema-dbs/off desliga o job E apaga o recibo (o classificador volta a tratar o banco como mole na hora).
SEGURANÇA: só lê sqlite_master e user_version do banco real (mode=rw + PRAGMA query_only=ON: o sqlite 3.51 do mini não abre WAL sem -wal/-shm em mode=ro), nunca uma linha. O DDL passa pelo hetzner-pii-scan.py com limiar 1 telefone / 1 CPF
  (o espelho usa 20/3): achou = aquele banco não vai. Fora também: não-SQLite (DuckDB), nome com cara de segredo, DDL que não reproduz, cópia com linha, arquivo grande. O nó não confia no mini (ver NODE_PROG).
TRÊS ESTADOS: banco ilegível/travado/sem permissão FICA DE FORA com o motivo (nunca "sem schema"); git, varredor de PII ou ssh que falham não entregam nada (nunca "nenhum banco" apagando o que o nó já tem); recibo só depois do nó confirmar cada sha256.
CÓDIGOS: 0 ok (ou desligado/outro run em curso) · 2 não consegui confirmar a entrega (ssh caiu, resposta ilegível) · 3 não consegui montar (git, varredor, nenhum banco) · 4 o nó recusou · 64 uso errado."""
import argparse
import base64
import fcntl
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.environ.get("WA_SCHEMA_STATE", os.path.join(HERE, "..", ".gc", "wa-schema-dbs"))
WA_ROOT = os.environ.get("WA_SCHEMA_WA_ROOT", "/Users/athos/gt/whatsapp_automation")
REF = os.environ.get("WA_SCHEMA_REF", "origin/main")
GIT = os.environ.get("WA_SCHEMA_GIT", "git")
SSH = os.environ.get("MBP_SSH", "ssh")
HOST = os.environ.get("HETZNER_NODE_HOST", "hetzner-teste")
SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4"]
PII_SCAN = os.environ.get("WA_SCHEMA_PII", os.path.join(HERE, "hetzner-pii-scan.py"))
RIG = "whatsapp_automation"
KEY_RE = re.compile(r"^shared/data/(?:[A-Za-z0-9_][A-Za-z0-9_.\-]*/)*[A-Za-z0-9_][A-Za-z0-9_.\-]*\.(?:db|sqlite3?)$")   # o mesmo SCHEMA_KEY_RE do classificador: o único formato de caminho do recibo
SECRET_RE = re.compile(r"segred|chave|senha|secret|token|credenc|credential|passw|cookie|oauth|jwt|apikey|private", re.I)
MAX_BYTES = 2_000_000
try:
    BUSY_S = float(os.environ.get("WA_SCHEMA_BUSY_S", "5"))
except ValueError:
    BUSY_S = 5.0


class Falha(Exception):
    """um motivo curto (nunca valor de dado) pelo qual um banco fica de fora ou a rodada não segue; rc é o código de saída quando a rodada inteira cai."""

    def __init__(self, msg, rc=3):
        Exception.__init__(self, msg)
        self.rc = rc


def cited(repo, ref):
    """caminhos shared/data/... dos bancos que o código do WA em <ref> cita (caminho fixado ou nome solto). Só o TOKEN decide o que procurar no disco; o que não existe lá some sem ruído."""
    # vazio (nenhum .db citado) -> set() e o build recusa; falhou (git sem resposta, rc > 1) -> Falha: nunca "nenhum banco"
    try:
        r = subprocess.run([GIT, "-C", repo, "grep", "-I", "-h", "-o", "-E", r"[A-Za-z0-9_./-]*[A-Za-z0-9_-]\.(db|sqlite3?)", ref, "--", "*.py", "*.sh", "*.js", "*.mjs", "*.cjs", "*.ts"],
                           capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired):
        raise Falha("git-sem-resposta")
    if r.returncode not in (0, 1):
        raise Falha("git-rc-%d" % r.returncode)
    out = set()
    for t in r.stdout.split():
        rel = t if t.startswith("shared/data/") else ("shared/data/" + t if "/" not in t else "")
        if KEY_RE.match(rel):
            out.add(rel)
    return out


def schema_of(src):
    """(linhas de sqlite_master com DDL, (user_version, application_id)) — SÓ o schema, nunca uma linha de dado."""
    # vazio (sem objeto) -> ([], ...) e o banco fica de fora (sem-schema); falhou (travado, corrompido, sem permissão, não é SQLite) -> Falha com o motivo: nunca "sem schema"
    try:
        with open(src, "rb") as fh:
            if fh.read(16) != b"SQLite format 3\x00":
                raise Falha("nao-sqlite")
        con = sqlite3.connect("file:%s?mode=rw" % urllib.parse.quote(src), uri=True, timeout=BUSY_S)
        try:
            con.execute("PRAGMA query_only=ON")
            rows = con.execute("SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY rowid").fetchall()
            ver = (con.execute("PRAGMA user_version").fetchone()[0], con.execute("PRAGMA application_id").fetchone()[0])
        finally:
            con.close()
    except (OSError, sqlite3.Error) as e:
        raise Falha("ilegivel:%s" % type(e).__name__)
    return rows, ver


def table_stats(con):
    """(nº de tabelas, nº de tabelas com linha) fora das tabelas-sombra de tabela virtual (o FTS5 grava linhas de estrutura nelas)."""
    # vazio (sem tabela) -> (0, 0) e quem chama recusa; falhou (PRAGMA table_list só existe no sqlite >= 3.37) -> sem lista de sombras: elas contam como tabela com linha (mais estrito)
    try:
        shadow = {r[1] for r in con.execute("PRAGMA table_list") if r[2] == "shadow"}
    except sqlite3.Error:
        shadow = set()
    names = [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'") if r[0] not in shadow]
    return len(names), sum(1 for n in names if con.execute('SELECT 1 FROM "%s" LIMIT 1' % n.replace('"', '""')).fetchone())


def make_copy(dst, rows, ver):
    """grava em dst um banco novo só com o DDL (journal padrão, não WAL) e confere: >= 1 tabela e ZERO tabela com linha. Devolve o nº de tabelas."""
    con = sqlite3.connect(dst)
    try:
        for typ, _name, sql in rows:
            try:
                con.execute(sql)
            except sqlite3.OperationalError as e:
                if "already exists" not in str(e):   # tabela-sombra que o CREATE VIRTUAL TABLE já criou
                    raise Falha("ddl-falhou:" + typ)
        con.execute("PRAGMA user_version=%d" % ver[0])
        con.execute("PRAGMA application_id=%d" % ver[1])
        con.commit()
        ntab, ncom = table_stats(con)
    except sqlite3.Error:
        raise Falha("ddl-falhou")
    finally:
        con.close()
    if ntab == 0 or ncom:
        raise Falha("copia-sem-tabela" if ntab == 0 else "copia-com-linha")
    return ntab


def load_pii():
    """o módulo do hetzner-pii-scan.py (counts). Falhou/ilegível -> Falha: sem varredura nada sai."""
    try:
        spec = importlib.util.spec_from_file_location("pii", PII_SCAN)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.counts("x")
    except Exception:
        raise Falha("varredor-pii-ilegivel")
    return mod


def build(out, root, repo, ref):
    """monta out/shared/data/*.db + MANIFEST.json + schema.sql. Devolve (manifest, linhas do relatório)."""
    wanted, pii, dbs, fora, sql_out, ausentes = cited(repo, ref), load_pii(), {}, {}, [], 0
    for rel in sorted(wanted):
        src, dst = os.path.join(root, rel), os.path.join(out, rel)
        if not os.path.isfile(src):
            ausentes += 1
            continue
        try:
            if SECRET_RE.search(os.path.basename(rel)):
                raise Falha("nome-de-segredo")
            rows, ver = schema_of(src)
            if not rows:
                raise Falha("sem-schema")
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            ntab = make_copy(dst, rows, ver)
            ddl = "".join(s.rstrip().rstrip(";") + ";\n" for _t, _n, s in rows)
            ph, cpf = pii.counts(ddl)   # só contagens: o valor nunca vai a log nem a relatório
            if ph or cpf:
                raise Falha("pii-no-ddl:%dtel,%dcpf" % (ph, cpf))
            if os.path.getsize(dst) > MAX_BYTES:
                raise Falha("grande")
        except Falha as e:
            fora[rel] = str(e)
            if os.path.exists(dst):
                os.unlink(dst)
            continue
        with open(dst, "rb") as fh:
            dbs[rel] = {"sha256": hashlib.sha256(fh.read()).hexdigest(), "bytes": os.path.getsize(dst), "tables": ntab}
        sql_out.append("-- %s (user_version=%d)\n%s" % (rel, ver[0], ddl))
    if not dbs:
        raise Falha("nenhum-banco")
    man = {"v": 1, "rig": RIG, "built_at": int(time.time()), "ref": REF, "dbs": dbs, "excluded": fora}
    for name, text in (("MANIFEST.json", json.dumps(man, sort_keys=True)), ("schema.sql", "\n".join(sql_out))):
        with open(os.path.join(out, name), "w") as fh:
            fh.write(text)
    rep = ["WASCHEMA ok %s tabelas=%d bytes=%d" % (r, d["tables"], d["bytes"]) for r, d in sorted(dbs.items())] + ["WASCHEMA fora %s: %s" % kv for kv in sorted(fora.items())]
    rep.append("WASCHEMA BUILD %d bancos, %d fora, %d nomes citados sem arquivo em shared/data; varredura PII do DDL (limiar 1/1): limpa" % (len(dbs), len(fora), ausentes))
    return man, rep


NODE_PROG = r'''
import base64, hashlib, io, json, os, re, shutil, sqlite3, sys, tarfile, urllib.parse
KEY_RE = re.compile(__KEY_RE__)
def check(p):
    with open(p, "rb") as fh:
        if fh.read(16) != b"SQLite format 3\x00":
            raise ValueError("nao-sqlite")
    con = sqlite3.connect("file:%s?mode=ro&immutable=1" % urllib.parse.quote(p), uri=True)
    try:
        if con.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("integridade")
        try:
            shadow = {r[1] for r in con.execute("PRAGMA table_list") if r[2] == "shadow"}
        except sqlite3.Error:
            shadow = set()
        names = [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'") if r[0] not in shadow]
        if not names:
            raise ValueError("sem-tabela")
        if any(con.execute('SELECT 1 FROM "%s" LIMIT 1' % n.replace('"', '""')).fetchone() for n in names):
            raise ValueError("linhas")
    finally:
        con.close()
def main():
    rig = sys.argv[1] if len(sys.argv) > 1 else ""
    res = {"ok": False, "rig": rig, "dbs": {}, "rejected": {}, "placement": "absent"}
    gr = os.environ.get("GT_REMOTE_GIT") or os.path.expanduser("~/gt-remote/git")
    base = os.path.join(gr, "schema-dbs")
    new = os.path.join(base, ".new-%d" % os.getpid())
    try:
        if not re.match(r"^[a-z][a-z0-9_-]{0,40}$", rig):
            raise ValueError("rig-invalido")
        files = {}
        with tarfile.open(fileobj=io.BytesIO(base64.b64decode(PAYLOAD)), mode="r:gz") as tf:
            ms = tf.getmembers()
            if len(ms) > 200:
                raise ValueError("membros-demais")
            for m in ms:
                if not m.isreg() or m.size > 4000000 or not (m.name == "MANIFEST.json" or KEY_RE.match(m.name)):
                    raise ValueError("membro-invalido")
                files[m.name] = tf.extractfile(m).read()
        man = json.loads(files.pop("MANIFEST.json"))
        os.makedirs(new)
        for rel, data in sorted(files.items()):
            try:
                want = man["dbs"][rel]["sha256"]
                if hashlib.sha256(data).hexdigest() != want:
                    raise ValueError("sha256")
                p = os.path.join(new, rel)
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p, "wb") as fh:
                    fh.write(data)
                check(p)
                res["dbs"][rel] = want
            except (ValueError, KeyError, OSError, sqlite3.Error) as e:
                res["rejected"][rel] = type(e).__name__ if not isinstance(e, ValueError) else str(e)
        if not res["dbs"]:
            raise ValueError("nenhum-banco-aceito")
        for rel in set(files) - set(res["dbs"]):
            if os.path.exists(os.path.join(new, rel)):
                os.unlink(os.path.join(new, rel))
        with open(os.path.join(new, "MANIFEST"), "w") as fh:
            fh.write("".join(r + "\n" for r in sorted(res["dbs"])))
        final = os.path.join(base, rig)
        old = final + ".old-%d" % os.getpid()
        if os.path.isdir(final):
            os.rename(final, old)
        try:
            os.rename(new, final)
        except OSError:
            if os.path.isdir(old):
                os.rename(old, final)
            raise
        shutil.rmtree(old, ignore_errors=True)
        try:
            with open(os.path.join(os.environ.get("GT_REMOTE_BIN") or os.path.expanduser("~/gt-remote/bin"), "hetzner-remote-git.sh")) as fh:
                res["placement"] = "ok" if "schema-dbs-v1" in fh.read() else "absent"
        except OSError:
            pass
        res["ok"] = True
    except (ValueError, KeyError, OSError, tarfile.TarError, sqlite3.Error) as e:
        res["erro"] = type(e).__name__ if not isinstance(e, ValueError) else str(e)
        shutil.rmtree(new, ignore_errors=True)
    print("SCHEMA-INSTALL " + json.dumps(res, sort_keys=True))
    sys.exit(0 if res["ok"] else 1)
'''.replace("__KEY_RE__", repr(KEY_RE.pattern))


def deliver(stage, man):
    """manda os bancos ao nó e devolve o recibo (só o que o nó confirmou com o MESMO sha256 que o mini mandou)."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for rel in sorted(man["dbs"]) + ["MANIFEST.json"]:
            tf.add(os.path.join(stage, rel), arcname=rel)
    prog = NODE_PROG + "\nPAYLOAD = %r\nmain()\n" % base64.b64encode(buf.getvalue()).decode()
    # vazio (resposta sem a linha SCHEMA-INSTALL) / falhou (ssh rc 255, prazo, JSON torto, sha256 diferente do enviado): NÃO confirmei -> Falha 2 e o recibo antigo fica como estava
    try:
        r = subprocess.run([SSH] + SSH_OPTS + [HOST, "python3", "-I", "-", RIG], input=prog, capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired):
        raise Falha("ssh-sem-resposta", 2)
    line = next((l for l in reversed(r.stdout.splitlines()) if l.startswith("SCHEMA-INSTALL ")), "")
    try:
        res = json.loads(line[len("SCHEMA-INSTALL "):])
    except ValueError:
        raise Falha("ssh-rc-%d-sem-resposta" % r.returncode, 2)
    if r.returncode != 0 or res.get("ok") is not True:
        raise Falha("no-recusou:%s" % str(res.get("erro", "?"))[:60], 4)
    dbs = res.get("dbs")
    if not isinstance(dbs, dict) or not dbs or any(k not in man["dbs"] or v != man["dbs"][k]["sha256"] for k, v in dbs.items()):
        raise Falha("resposta-diferente-do-enviado", 2)
    return {"v": 1, "rig": RIG, "delivered_at": int(time.time()), "placement": "ok" if res.get("placement") == "ok" else "absent", "dbs": dbs, "node": HOST}, res.get("rejected", {})


def write_receipt(rec):
    os.makedirs(STATE, exist_ok=True)
    tmp = os.path.join(STATE, "delivered.json.tmp")
    with open(tmp, "w") as fh:
        json.dump(rec, fh, sort_keys=True)
    os.replace(tmp, os.path.join(STATE, "delivered.json"))


def read_manifest(stage):
    # vazio (MANIFEST sem bancos) / falhou (ausente, JSON torto) -> Falha 2: não entrego o que não li
    try:
        with open(os.path.join(stage, "MANIFEST.json")) as fh:
            man = json.load(fh)
        if man["v"] == 1 and man["dbs"]:
            return man
    except (OSError, ValueError, KeyError, TypeError):
        pass
    raise Falha("manifesto-ilegivel", 2)


def main(argv):
    ap = argparse.ArgumentParser(prog="wa-schema-dbs.py")
    ap.add_argument("cmd", choices=("build", "deliver", "run"))
    ap.add_argument("--out")
    ap.add_argument("--from", dest="src")
    a = ap.parse_args(argv)
    os.makedirs(STATE, exist_ok=True)
    # vazio (primeiro run) -> cria o lock; falhou (outro run segura) -> sai 0 sem fazer nada
    lock = open(os.path.join(STATE, "lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("WASCHEMA outro run em curso")
        return 0
    if a.cmd != "build" and os.path.exists(os.path.join(STATE, "off")):
        if os.path.exists(os.path.join(STATE, "delivered.json")):
            os.unlink(os.path.join(STATE, "delivered.json"))
        print("WASCHEMA desligado (arquivo off): recibo apagado, o classificador volta a tratar o banco como mole")
        return 0
    tmp = None
    try:
        if a.cmd == "deliver":
            stage = a.src
        else:
            stage = a.out or tempfile.mkdtemp(prefix="stage-", dir=STATE)
            tmp = stage if a.cmd == "run" else None
            os.makedirs(stage, exist_ok=True)
            _man, rep = build(stage, WA_ROOT, WA_ROOT, REF)
            print("\n".join(rep))
        if a.cmd == "build":
            return 0
        man = read_manifest(stage)
        rec, rejected = deliver(stage, man)
        write_receipt(rec)
        for k, v in sorted(rejected.items()):
            print("WASCHEMA no-rejeitou %s: %s" % (k, v))
        print("WASCHEMA ENTREGUE %d bancos no no %s, placement=%s%s" % (len(rec["dbs"]), HOST, rec["placement"], "" if rec["placement"] == "ok" else " (o hetzner-remote-git.sh do no ainda nao tem o wt-add novo: o classificador segue sem relaxar)"))
        if tmp:   # o último stage entregue fica em last/ (schema.sql e MANIFEST.json para conferir)
            shutil.rmtree(os.path.join(STATE, "last"), ignore_errors=True)
            os.replace(tmp, os.path.join(STATE, "last"))
            tmp = None
        return 0
    except Falha as e:
        print("WASCHEMA FALHOU: %s" % e)
        return e.rc
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
