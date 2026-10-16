#!/usr/bin/env python3
"""jsonl_hourly.py (ga-c0939v.1) — helper do upload horário do dump JSONL: empacota e verifica o snapshot.

Contents
  Por quê · Formato do dump · Subcomandos · Regras de fail-closed

POR QUÊ: o dump que o jsonl-export.sh grava a cada 15 min (git archive em packs/maintenance/jsonl-archive)
  é o único artefato do city com RPO < 24 h. Este módulo faz o que o shell não faz bem: empacotar o
  snapshot SEM carregar 400 MB em memória e CONTAR as linhas de cada tabela lendo o artefato final (o
  mesmo caminho que o restore percorre). O lado do RESTORE (converter as tabelas para o JSONL do
  `bd import` e fazer as contas) é o jsonl_hourly_restore.py, que importa o leitor daqui (ga-c0939v.3).

FORMATO DO DUMP (medido em 16/10): <db>/<tabela>.jsonl, tabela em {issues, comments, dependencies, labels,
  config, metadata}; cada arquivo é UMA linha `{"rows":[{...},...]}` (com ou sem espaço depois do `:`) vinda de
  `dolt sql -r json`; tabela vazia sai como `{}`. Todos os valores de coluna são STRINGS ("priority":"1",
  "ephemeral":"0", "metadata":"{}", datas "AAAA-MM-DD HH:MM:SS" em UTC). Os `<db>.jsonl` da raiz são cópias de
  <db>/issues.jsonl (cmp igual em hq e whatsapp_automation) e ficam FORA do pacote; `*.tmp.*` são sobras de
  export abortado que o exporter chegou a commitar e também ficam fora.

SUBCOMANDOS (stdout = JSON, rc 0 ok / 1 dump ilegível / 2 uso)
  build   --out F.tar.gz --files-out F.json   < tar     filtra o tar do `git archive`, grava o .tar.gz e a lista de arquivos (bytes+sha256)
  inspect F.tar.gz                                      conta linhas por <db>/<tabela> LENDO o artefato; erro de parse vira entrada em "errors"
  count   F.jsonl                                       número de linhas de um dump (uma tabela)
  manifest --inspect I.json --built B.json --captured-epoch N --head-epoch N --head-sha S --key K [--require db,db]
                                                        manifest do snapshot (verdict ok|broken) a partir do que foi lido do artefato
  retention --prefix P --now EPOCH [--keep-recent-h 48 --keep-daily-days 14 --floor 6 --protect STEM]  < chaves
                                                        chaves a apagar (só o formato exato de snapshot; stdin = lista de chaves)

FAIL-CLOSED: dump truncado, com lixo depois do `}` final, com vírgula sobrando ou fora da forma
  `{"rows":[...]}` / `{}` é ERRO, nunca "contei até onde deu": uma contagem parcial passaria por contagem do
  manifest e a prova de restore compararia dois números igualmente errados.
"""
import argparse
import codecs
import fnmatch
import gzip
import hashlib
import io
import json
import re
import sys
import tarfile

TABLES = ("issues", "comments", "dependencies", "labels", "config", "metadata")
MEMBER_RE = re.compile(r"^(?:\./)?([A-Za-z0-9_][A-Za-z0-9_.-]*)/(" + "|".join(TABLES) + r")\.jsonl$")
CHUNK = 8 * 1024 * 1024
# uma linha (issue com description enorme, comentário colado de log) cabe com folga; acima disso o
# arquivo é lixo e ler o resto dele para a memória só atrasaria o erro.
MAX_ROW_CHARS = 128 * 1024 * 1024

_WS = re.compile(r"\s*")
_HEAD = re.compile(r'\s*\{\s*"rows"\s*:\s*\[')
_EMPTY = re.compile(r"\s*\{\s*\}\s*\Z")


class DumpError(Exception):
    """Dump que não segue a forma conhecida (truncado, malformado, com lixo)."""


def iter_rows(fh, chunk=CHUNK):
    """Gera cada objeto de `rows` lendo `fh` (binário) em blocos; memória ~ bloco + maior linha."""
    dec = codecs.getincrementaldecoder("utf-8")(errors="strict")
    jd = json.JSONDecoder()
    st = {"buf": "", "pos": 0, "eof": False}

    def fill():
        data = fh.read(chunk)
        try:
            if not data:
                st["eof"] = True
                text = dec.decode(b"", final=True)
            else:
                text = dec.decode(data)
        except UnicodeDecodeError as e:
            raise DumpError("bytes que não são UTF-8: %s" % e)
        st["buf"] = st["buf"][st["pos"]:] + text
        st["pos"] = 0

    # cabeçalho: `{"rows":[` ou `{}` (tabela vazia)
    fill()
    while True:
        buf, pos = st["buf"], st["pos"]
        m = _HEAD.match(buf, pos)
        if m:
            st["pos"] = m.end()
            break
        if _EMPTY.match(buf, pos):
            # `{}` + espaço: só vale se o arquivo acaba aí (quem decide é o EOF)
            if st["eof"]:
                return
            fill()
            continue
        if st["eof"] or len(buf) - pos >= 256:
            raise DumpError('não começa com {"rows":[ nem é {}')
        fill()

    want = "first"  # first: objeto ou ] · comma_or_end: , ou ] · object: só objeto
    while True:
        buf = st["buf"]
        pos = _WS.match(buf, st["pos"]).end()
        st["pos"] = pos
        if pos >= len(buf):
            if st["eof"]:
                raise DumpError("truncado dentro de rows")
            fill()
            continue
        c = buf[pos]
        if c == "]" and want != "object":
            st["pos"] = pos + 1
            break
        if want == "comma_or_end":
            if c != ",":
                raise DumpError("esperava , ou ] depois de uma linha, achei %r" % c)
            st["pos"] = pos + 1
            want = "object"
            continue
        if c != "{":
            raise DumpError("esperava { de linha, achei %r" % c)
        try:
            obj, end = jd.raw_decode(buf, pos)
        except json.JSONDecodeError as e:
            if st["eof"]:
                raise DumpError("linha truncada ou malformada: %s" % e)
            if len(buf) - pos > MAX_ROW_CHARS:
                raise DumpError("linha maior que %d caracteres" % MAX_ROW_CHARS)
            fill()
            continue
        st["pos"] = end
        want = "comma_or_end"
        yield obj

    # depois do ]: só `}` e espaço até o fim
    closed = False
    while True:
        buf = st["buf"]
        pos = _WS.match(buf, st["pos"]).end()
        st["pos"] = pos
        if pos >= len(buf):
            if st["eof"]:
                break
            fill()
            continue
        if not closed and buf[pos] == "}":
            closed = True
            st["pos"] = pos + 1
            continue
        raise DumpError("lixo depois do fim de rows: %r" % buf[pos:pos + 20])
    if not closed:
        raise DumpError("falta o } final")


def count_rows(fh, chunk=CHUNK):
    n = 0
    for _ in iter_rows(fh, chunk):
        n += 1
    return n


def _sha256_stream(fh, bufsize=1024 * 1024):
    h = hashlib.sha256()
    n = 0
    while True:
        b = fh.read(bufsize)
        if not b:
            break
        h.update(b)
        n += len(b)
    return h.hexdigest(), n


def sha256_file(path):
    with open(path, "rb") as f:
        return _sha256_stream(f)


# ── build ─────────────────────────────────────────────────────────────────────────────
class _Hasher(io.RawIOBase):
    """Leitura que alimenta sha256 e contagem de bytes; é o `fileobj` que o tarfile copia para o pacote."""

    def __init__(self, src):
        self.src, self.h, self.n = src, hashlib.sha256(), 0

    def readable(self):
        return True

    def read(self, size=-1):
        b = self.src.read(size)
        self.h.update(b)
        self.n += len(b)
        return b


def parse_ignore(spec):
    """'a*, b_* ,' -> ['a*', 'b_*']. Aparado e sem itens vazios (um padrão vazio não pode virar 'casa com tudo')."""
    return [x.strip() for x in (spec or "").split(",") if x.strip()]


def db_ignored(db, patterns):
    # fnmatchcase: diferencia maiúsculas de minúsculas em qualquer SO; na dúvida, NÃO ignora (o banco entra e é verificado)
    return any(fnmatch.fnmatchcase(db, p) for p in patterns)


def cmd_build(args):
    files, skipped = [], []
    seen = set()
    ignore, ignored = parse_ignore(args.ignore_db), set()
    # fileobj + filename="" : o GzipFile não grava o nome do arquivo de saída no cabeçalho, então o mesmo
    # conteúdo dá os mesmos bytes (e o mesmo sha256) em qualquer diretório de trabalho
    with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as src, open(args.out, "wb") as raw, \
            gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=args.level, mtime=0) as gz, \
            tarfile.open(fileobj=gz, mode="w|", format=tarfile.PAX_FORMAT) as dst:
        for m in src:
            if not m.isreg():
                continue
            name = m.name
            mm = MEMBER_RE.match(name)
            if not mm:
                skipped.append(name)
                continue
            if db_ignored(mm.group(1), ignore):
                ignored.add(mm.group(1))   # banco de teste/benchmark que o exporter arquiva: não viaja, mas o manifest o nomeia
                continue
            if name in seen:
                raise SystemExit("membro repetido no tar: %s" % name)
            seen.add(name)
            hs = _Hasher(src.extractfile(m))
            ti = tarfile.TarInfo(name=name)
            ti.size = m.size
            ti.mtime = 0
            ti.mode = 0o644
            dst.addfile(ti, fileobj=hs)
            if hs.n != m.size:
                raise SystemExit("leitura curta em %s: %d de %d bytes" % (name, hs.n, m.size))
            files.append({"path": name, "bytes": hs.n, "sha256": hs.h.hexdigest()})
    sha, n = sha256_file(args.out)
    doc = {"files": files, "skipped": skipped, "ignored_dbs": sorted(ignored), "ignore_patterns": ignore,
           "artifact": {"bytes": n, "sha256": sha}}
    with open(args.files_out, "w") as f:
        json.dump(doc, f, sort_keys=True)
    print(json.dumps({"files": len(files), "skipped": len(skipped), "ignored_dbs": len(ignored), "bytes": n, "sha256": sha}))
    return 0 if files else 1


# ── inspect ───────────────────────────────────────────────────────────────────────────
def inspect_archive(path):
    dbs, files, errors = {}, [], []
    with tarfile.open(path, "r|gz") as tf:
        for m in tf:
            if not m.isreg():
                continue
            mm = MEMBER_RE.match(m.name)
            if not mm:
                errors.append({"path": m.name, "error": "membro fora do layout <db>/<tabela>.jsonl"})
                continue
            db, table = mm.group(1), mm.group(2)
            fh = tf.extractfile(m)
            hs = _Hasher(fh)
            try:
                n = count_rows(hs)
                if hs.n != m.size:
                    raise DumpError("leitura curta: %d de %d bytes" % (hs.n, m.size))
            except DumpError as e:
                errors.append({"path": m.name, "error": str(e)})
                n = None
            else:
                dbs.setdefault(db, {})[table] = n
            files.append({"path": m.name, "bytes": m.size, "rows": n})
    return {"databases": dbs, "files": files, "errors": errors}


def cmd_inspect(args):
    doc = inspect_archive(args.archive)
    print(json.dumps(doc, sort_keys=True))
    return 1 if doc["errors"] or not doc["databases"] else 0


def cmd_count(args):
    with open(args.file, "rb") as f:
        try:
            n = count_rows(f)
        except DumpError as e:
            print(json.dumps({"error": str(e)}))
            return 1
    print(json.dumps({"rows": n}))
    return 0


# ── manifest (inspect + build -> manifest do snapshot) ────────────────────────────────
def _iso(epoch):
    import datetime
    return datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_manifest(insp, built, meta, required_dbs):
    """Junta o que foi LIDO do artefato (inspect) com o que foi gravado (build). verdict: ok | broken."""
    problems = []
    for e in insp.get("errors", []):
        problems.append("%s: %s" % (e["path"], e["error"]))
    dbs = insp.get("databases", {})
    for db, tables in sorted(dbs.items()):
        for t in TABLES:
            if t not in tables:
                problems.append("%s/%s.jsonl ausente do snapshot" % (db, t))
    ignored_dbs = sorted(built.get("ignored_dbs", []))
    for db in required_dbs:
        if db in ignored_dbs:
            problems.append("banco obrigatório %s foi ignorado pelos padrões %s" % (db, built.get("ignore_patterns", [])))
        elif db not in dbs:
            problems.append("banco obrigatório %s ausente do snapshot" % db)
        elif dbs[db].get("issues", 0) == 0:
            problems.append("banco obrigatório %s com 0 issues" % db)
    if not dbs:
        problems.append("snapshot sem nenhum banco")
    rows = {f["path"]: f.get("rows") for f in insp.get("files", [])}
    files = [{"path": f["path"], "bytes": f["bytes"], "sha256": f["sha256"], "rows": rows.get(f["path"])}
             for f in built.get("files", [])]
    return {
        "schema": 1,
        "kind": "jsonl-hourly-snapshot",
        "verdict": "ok" if not problems else "broken",
        "problems": problems,
        "captured_at": _iso(meta["captured_epoch"]),
        "data_as_of": _iso(meta["head_epoch"]),
        "source": {"archive_head": meta["head_sha"], "head_age_s": int(meta["captured_epoch"]) - int(meta["head_epoch"])},
        "artifact": {"key": meta["key"], "format": "tar.gz", "layout": "<db>/<tabela>.jsonl",
                     "bytes": built["artifact"]["bytes"], "sha256": built["artifact"]["sha256"]},
        "databases": dbs,
        "files": files,
        "excluded": sorted(built.get("skipped", [])),
        "ignored_dbs": ignored_dbs,
        "ignore_patterns": built.get("ignore_patterns", []),
        "scope": "tabelas issues/comments/dependencies/labels/config/metadata como o jsonl-export.sh as arquiva (escrubbed: message, event, wisp, agent ficam de fora)",
    }


def cmd_manifest(args):
    insp = json.load(open(args.inspect))
    built = json.load(open(args.built))
    meta = {"captured_epoch": args.captured_epoch, "head_epoch": args.head_epoch, "head_sha": args.head_sha, "key": args.key}
    doc = build_manifest(insp, built, meta, [d for d in args.require.split(",") if d])
    print(json.dumps(doc, sort_keys=True))
    return 0 if doc["verdict"] == "ok" else 1


# ── retention ─────────────────────────────────────────────────────────────────────────
def retention_deletes(keys, prefix, now, keep_recent_s, keep_daily_days, floor, protect=None, orphan_grace_s=7200):
    """Quais chaves apagar. Só toca chaves no formato exato <prefix>/snap/<AAAAMMDDTHHMMSSZ>-<sha12>.(tar.gz|manifest.json)."""
    import datetime
    rx = re.compile(r"^" + re.escape(prefix) + r"/snap/(\d{8}T\d{6}Z)-([0-9a-f]{12})\.(tar\.gz|manifest\.json)$")
    stems = {}
    for k in keys:
        m = rx.match(k)
        if not m:
            continue
        stem = m.group(1) + "-" + m.group(2)
        ts = datetime.datetime.strptime(m.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
        d = stems.setdefault(stem, {"ts": ts, "kinds": set()})
        d["kinds"].add(m.group(3))
    if not stems:
        return []
    # o piso conta só snapshots COMPLETOS: uploads quebrados em sequência não podem ocupar as vagas dos bons
    complete_desc = [x for x in sorted(stems, key=lambda x: stems[x]["ts"], reverse=True)
                     if stems[x]["kinds"] == {"tar.gz", "manifest.json"}]
    keep = set(complete_desc[:floor])
    if protect:
        keep.add(protect)
    first_of_day = {}
    for st in sorted(stems, key=lambda x: stems[x]["ts"]):
        day = datetime.datetime.fromtimestamp(stems[st]["ts"], datetime.timezone.utc).strftime("%Y%m%d")
        first_of_day.setdefault(day, st)
    for st, d in stems.items():
        age = now - d["ts"]
        complete = d["kinds"] == {"tar.gz", "manifest.json"}
        if not complete:
            if age < orphan_grace_s:
                keep.add(st)  # upload em andamento ou recém-terminado
            continue
        if age <= keep_recent_s:
            keep.add(st)
        elif age <= keep_daily_days * 86400 and first_of_day.get(
                datetime.datetime.fromtimestamp(d["ts"], datetime.timezone.utc).strftime("%Y%m%d")) == st:
            keep.add(st)
    if not keep:
        return []
    out = []
    for st in sorted(stems):
        if st in keep:
            continue
        for kind in sorted(stems[st]["kinds"]):
            out.append("%s/snap/%s.%s" % (prefix, st, kind))
    return out


def cmd_retention(args):
    keys = [l.strip() for l in sys.stdin if l.strip()]
    protect = None
    if args.protect:
        protect = re.sub(r"\.(tar\.gz|manifest\.json)$", "", args.protect.rsplit("/", 1)[-1])
    for k in retention_deletes(keys, args.prefix, args.now, args.keep_recent_h * 3600, args.keep_daily_days, args.floor, protect):
        print(k)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="jsonl_hourly.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--out", required=True)
    b.add_argument("--files-out", required=True)
    b.add_argument("--level", type=int, default=6)
    b.add_argument("--ignore-db", default="", help="padrões fnmatch separados por vírgula; bancos que casam não entram no artefato")
    b.set_defaults(fn=cmd_build)
    i = sub.add_parser("inspect")
    i.add_argument("archive")
    i.set_defaults(fn=cmd_inspect)
    c = sub.add_parser("count")
    c.add_argument("file")
    c.set_defaults(fn=cmd_count)
    mf = sub.add_parser("manifest")
    mf.add_argument("--inspect", required=True)
    mf.add_argument("--built", required=True)
    mf.add_argument("--captured-epoch", type=int, required=True)
    mf.add_argument("--head-epoch", type=int, required=True)
    mf.add_argument("--head-sha", required=True)
    mf.add_argument("--key", required=True)
    mf.add_argument("--require", default="")
    mf.set_defaults(fn=cmd_manifest)
    rt = sub.add_parser("retention")
    rt.add_argument("--prefix", required=True)
    rt.add_argument("--now", type=int, required=True)
    rt.add_argument("--keep-recent-h", type=int, default=48)
    rt.add_argument("--keep-daily-days", type=int, default=14)
    rt.add_argument("--floor", type=int, default=6)
    rt.add_argument("--protect", default="")
    rt.set_defaults(fn=cmd_retention)
    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except (DumpError, tarfile.TarError, OSError, EOFError) as e:
        print(json.dumps({"error": "%s: %s" % (type(e).__name__, e)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
