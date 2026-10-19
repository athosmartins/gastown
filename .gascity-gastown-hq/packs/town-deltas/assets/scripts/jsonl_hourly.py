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
           [--previous P.json | --baseline-unavailable MOTIVO] [--suspect-drop-pct 20 --suspect-min-rows 100] [--accept-drop]
                                                        manifest do snapshot (verdict ok|suspect|broken) a partir do que foi lido do artefato; com o
                                                        manifest anterior, tabela que caiu > 20% (e tinha >= 100 linhas) sem queda de issues = suspect
  retention --prefix P --now EPOCH [--keep-recent-h 48 --keep-daily-days 14 --floor 6 --protect STEM]  < chaves
                                                        chaves a apagar (só o formato exato de snapshot; stdin = lista de chaves)

FAIL-CLOSED: dump truncado, com lixo depois do `}` final, com vírgula sobrando ou fora da forma
  `{"rows":[...]}` / `{}` é ERRO, nunca "contei até onde deu": uma contagem parcial passaria por contagem do
  manifest e a prova de restore compararia dois números igualmente errados. Idem para o tar de entrada do build sem a marca
  de fim (cortado num limite de membro), e para o manifest cujo inspect e build não descrevem os mesmos arquivos com os mesmos
  bytes. Na retenção, só snapshot COMPLETO (tar.gz + manifest) ocupa vaga do piso ou ancora o "primeiro do dia", e botão fora do
  limite (--floor < 1, janela < 0) é recusado com rc 2 em vez de afinar a política.
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

# espaço de JSON são exatamente 4 caracteres; `\s` casaria também NBSP, U+2028, VT, FF — e "lixo depois do } final é erro" não valeria
_W = r"[ \t\r\n]*"
_WS = re.compile(_W)
_HEAD = re.compile(_W + r'\{' + _W + r'"rows"' + _W + r':' + _W + r'\[')
_EMPTY = re.compile(_W + r'\{' + _W + r'\}' + _W + r'\Z')


class DumpError(Exception):
    """Dump que não segue a forma conhecida (truncado, malformado, com lixo)."""


def iter_rows(fh, chunk=CHUNK):
    """Gera cada objeto de `rows` lendo `fh` (binário) em blocos; memória ~ bloco + maior linha.

    ATENÇÃO a quem consome em streaming: as linhas saem ANTES de o fim do documento ser validado. Se o iterador levantar
    DumpError (truncado, lixo depois do `}`), tudo que já foi emitido tem que ser descartado — só `count_rows` é seguro
    por construção (a exceção joga fora o contador)."""
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


class _Tail:
    """Leitura do tar de entrada que lembra os últimos 1024 bytes. O tarfile em modo stream lê um tar cortado num limite de membro
    como "fim do arquivo"; a marca de fim (>= 1024 bytes NUL, que todo tar completo tem) é o que separa o completo do cortado.
    Escaparia à checagem só um tar cortado logo depois de um membro cujo PRÓPRIO conteúdo termina em >= 1024 NUL (um .jsonl termina em `}` ou `}\\n`)."""

    def __init__(self, src):
        self.src, self.tail, self.n = src, b"", 0

    def read(self, size=-1):
        b = self.src.read(size)
        self.n += len(b)
        self.tail = (self.tail + b)[-1024:]
        return b

    def has_end_marker(self):
        return self.n >= 1024 and self.tail == bytes(1024)


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
    tail = _Tail(sys.stdin.buffer)
    # fileobj + filename="" : o GzipFile não grava o nome do arquivo de saída no cabeçalho, então o mesmo
    # conteúdo dá os mesmos bytes (e o mesmo sha256) em qualquer diretório de trabalho
    with tarfile.open(fileobj=tail, mode="r|") as src, open(args.out, "wb") as raw, \
            gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=args.level, mtime=0) as gz, \
            tarfile.open(fileobj=gz, mode="w|", format=tarfile.PAX_FORMAT) as dst:
        for m in src:
            if not m.isreg():
                if m.issym() or m.islnk():
                    skipped.append(m.name)   # não viaja, mas é NOMEADO; diretórios (um por pasta no git archive) não entram
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
        # o tarfile para na 1ª faixa de zeros; o resto do stdin é lido até o fim para conferir a marca de fim do tar
        # vazio (stdin já no fim) → o laço não roda e a marca é conferida; falhou (OSError) → sobe ao main: rc 1 e o --files-out não é escrito
        while tail.read(CHUNK):
            pass
        if not tail.has_end_marker():
            raise SystemExit("tar de entrada sem a marca de fim (cortado num limite de membro?): %d bytes lidos" % tail.n)
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


# Queda brusca de uma tabela contra o snapshot anterior (ga-l6v576). Em 18/10 o export do hq cortou `comments` em 10.112 linhas (79 x 128) contra as
# 35.132 do dia 17 — uma queda de 71% — e o manifest saiu `verdict: ok`: inspect conta o que o artefato TEM, e um export cortado é um documento
# bem formado. Só uma régua externa (o snapshot anterior) vê isso.
# 20%: acima do que qualquer tabela oscila de uma hora para outra e muito abaixo do que um corte do Dolt faz. Comentário só cresce; `issues` do hq anda
#   ~1% por hora; o corte medido tira 68-71% (11.776 de 36.930 linhas no run vivo de 19/10; 10.112 de 35.132 no snapshot de 18/10). Entre 2% e 68% há
#   folga para os dois lados — e quem cai entre 20% e 68% já foi pego antes, pelo gate de contagem do próprio jsonl-export.sh.
# 100 linhas: tabela pequena oscila em termos relativos sem significar nada (config 12 -> 8 é -33%); o corte do Dolt só acontece com a tabela grande.
SUSPECT_DROP_PCT = 20
SUSPECT_MIN_PREV_ROWS = 100


def _baseline(prev, baseline_unavailable):
    """(estado, contagens, motivo, chave) da régua. estado: none (1º run, não há anterior) | unavailable (há, mas não serve; `motivo` diz por quê) | compared.
    vazio → none; ilegível/fora da forma/broken/suspect → unavailable. Nenhum dos dois vira "sem queda" em silêncio: o manifest guarda o estado."""
    if baseline_unavailable:
        return "unavailable", None, str(baseline_unavailable), None
    if prev is None:
        return "none", None, None, None
    if not isinstance(prev, dict) or not isinstance(prev.get("databases"), dict):
        return "unavailable", None, "manifest anterior fora da forma (sem `databases`)", None
    if prev.get("verdict") != "ok":
        return "unavailable", None, "manifest anterior com verdict %r não serve de régua" % (prev.get("verdict"),), None
    key = prev.get("artifact", {}).get("key") if isinstance(prev.get("artifact"), dict) else None
    return "compared", prev["databases"], None, key


def _rows(v):
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else None


def sharp_drops(cur_dbs, prev_dbs, drop_pct, min_rows):
    """Tabelas que caíram mais de drop_pct% contra o anterior, sem explicação. Devolve lista de textos, uma por tabela.
    Só entra na conta o par (banco, tabela) com contagem inteira nos dois lados e >= min_rows no anterior: banco novo, tabela nova e anterior ilegível
    são "não sei", e não sei não é queda. Explicação (só para tabela filha): o `issues` do MESMO banco caiu além do limite — filhos somem com o pai
    (uma purga); o `issues` em si não tem quem o explique. Uma purga de verdade que coincida com um corte de filhos fica escondida: a defesa primária é o
    gate de contagem por tabela do jsonl-export.sh, esta é a segunda."""
    out = []

    def dropped(cur, prev):
        cur, prev = _rows(cur), _rows(prev)
        if cur is None or prev is None or prev < min_rows:
            return None
        return (prev - cur) * 100 // prev if cur * 100 < prev * (100 - drop_pct) else None

    for db in sorted(cur_dbs):
        cur_tabs, prev_tabs = cur_dbs[db], prev_dbs.get(db)
        if not isinstance(cur_tabs, dict) or not isinstance(prev_tabs, dict):
            continue
        parent_fell = dropped(cur_tabs.get("issues"), prev_tabs.get("issues")) is not None
        for t in TABLES:
            pct = dropped(cur_tabs.get(t), prev_tabs.get(t))
            if pct is None or (t != "issues" and parent_fell):
                continue
            out.append("%s/%s: %d -> %d linhas (-%d%%) contra o snapshot anterior%s" % (
                db, t, prev_tabs[t], cur_tabs[t], pct, "" if t == "issues" else ", sem queda correspondente em issues"))
    return out


def build_manifest(insp, built, meta, required_dbs, prev=None, baseline_unavailable=None,
                   suspect_drop_pct=SUSPECT_DROP_PCT, suspect_min_rows=SUSPECT_MIN_PREV_ROWS, accept_drop=False):
    """Junta o que foi LIDO do artefato (inspect) com o que foi gravado (build) e, com `prev` (o manifest do snapshot anterior), com o que havia antes.
    verdict: ok | suspect | broken. broken = o artefato não descreve o que diz; suspect = o artefato é legível mas uma tabela caiu bruscamente contra o anterior
    sem explicação (lista em `suspect`); accept_drop (decisão de quem opera, um run só) mantém `suspect` e `baseline.accepted` no manifest e o torna ok."""
    problems = []
    for e in insp.get("errors", []):
        problems.append("%s: %s" % (e["path"], e["error"]))
    # o veredito é calculado sobre o que o inspect LEU; o que subiu é o que o build GRAVOU. Têm que ser o mesmo conjunto, com os mesmos
    # bytes — senão ok descreveria outro artefato.
    # vazio (inspect sem arquivos) → tudo que o build gravou vira "não lido": broken; falhou/ilegível (sem a chave `files`) → o mesmo, broken
    insp_bytes = {f["path"]: f.get("bytes") for f in insp.get("files", [])}
    built_bytes = {f["path"]: f["bytes"] for f in built.get("files", [])}
    for p in sorted(set(insp_bytes) | set(built_bytes)):
        if p not in insp_bytes:
            problems.append("%s gravado pelo build mas não lido do artefato" % p)
        elif p not in built_bytes:
            problems.append("%s lido do artefato mas não gravado pelo build" % p)
        elif insp_bytes[p] != built_bytes[p]:
            problems.append("%s: %s bytes lidos do artefato, %s gravados pelo build" % (p, insp_bytes[p], built_bytes[p]))
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
    state, prev_dbs, why, prev_key = _baseline(prev, baseline_unavailable)
    suspect = sharp_drops(dbs, prev_dbs, suspect_drop_pct, suspect_min_rows) if state == "compared" else []
    baseline = {"state": state}
    if prev_key:
        baseline["key"] = prev_key
    if why:
        baseline["why"] = why
    if suspect and accept_drop:
        baseline["accepted"] = True
    verdict = "broken" if problems else ("suspect" if suspect and not accept_drop else "ok")
    return {
        "schema": 1,
        "kind": "jsonl-hourly-snapshot",
        "verdict": verdict,
        "problems": problems,
        "suspect": suspect,
        "baseline": baseline,
        "suspect_rule": {"drop_pct": suspect_drop_pct, "min_prev_rows": suspect_min_rows},
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
    prev, unavailable = None, args.baseline_unavailable
    if args.previous and not unavailable:
        # falhou/ilegível/ausente → a régua não existe e o manifest DIZ isso (baseline.unavailable); um comparador que derruba o manifest pararia o RPO de 1 h
        try:
            with open(args.previous) as f:
                prev = json.load(f)
        except (OSError, ValueError) as e:
            unavailable = "manifest anterior ilegível (%s: %s)" % (type(e).__name__, e)
    doc = build_manifest(insp, built, meta, [d for d in args.require.split(",") if d], prev=prev, baseline_unavailable=unavailable,
                         suspect_drop_pct=args.suspect_drop_pct, suspect_min_rows=args.suspect_min_rows, accept_drop=args.accept_drop)
    print(json.dumps(doc, sort_keys=True))
    return 0 if doc["verdict"] == "ok" else 1


# ── retention ─────────────────────────────────────────────────────────────────────────
def retention_deletes(keys, prefix, now, keep_recent_s, keep_daily_days, floor, protect=None, orphan_grace_s=7200, skipped=None):
    """Quais chaves apagar. Só toca chaves no formato exato <prefix>/snap/<AAAAMMDDTHHMMSSZ>-<sha12>.(tar.gz|manifest.json).
    Chave na forma exata cuja data não existe (mês 13) não é lida como snapshot: nunca é apagada e entra em `skipped` (lista de
    saída, opcional) para quem chama dizer que ignorou; as outras seguem normalmente."""
    import datetime
    rx = re.compile(r"^" + re.escape(prefix) + r"/snap/(\d{8}T\d{6}Z)-([0-9a-f]{12})\.(tar\.gz|manifest\.json)$")
    stems = {}
    for k in keys:
        m = rx.match(k)
        if not m:
            continue
        stem = m.group(1) + "-" + m.group(2)
        # vazio → não se aplica (a regex só deixa passar o carimbo na forma exata); ilegível (data impossível) → a chave sai do
        # jogo, fica no S3 e é reportada em `skipped`; derrubar a execução inteira pararia a retenção de TODAS as chaves por causa de UMA.
        try:
            ts = datetime.datetime.strptime(m.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
        except ValueError:
            if skipped is not None:
                skipped.append(k)
            continue
        d = stems.setdefault(stem, {"ts": ts, "kinds": set()})
        d["kinds"].add(m.group(3))
    if not stems:
        return []
    # o piso e o "primeiro do dia" contam só snapshots COMPLETOS: um upload quebrado não pode ocupar a vaga de um bom — nem a
    # sequência do piso, nem a âncora do dia (órfão como 1º carimbo do dia apagaria todos os completos daquele dia)
    complete_desc = [x for x in sorted(stems, key=lambda x: stems[x]["ts"], reverse=True)
                     if stems[x]["kinds"] == {"tar.gz", "manifest.json"}]
    keep = set(complete_desc[:floor])
    if protect:
        keep.add(protect)
    first_of_day = {}
    for st in sorted(complete_desc, key=lambda x: stems[x]["ts"]):
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


def _int_range(lo, hi):
    def conv(s):
        v = int(s)   # não-número: ValueError, que o argparse transforma em rc 2
        if not lo <= v <= hi:
            raise argparse.ArgumentTypeError("precisa estar entre %d e %d (recebi %d)" % (lo, hi, v))
        return v
    conv.__name__ = "inteiro"
    return conv


def _int_min(lo):
    def conv(s):
        v = int(s)   # não-número: ValueError, que o argparse transforma em rc 2
        if v < lo:
            raise argparse.ArgumentTypeError("precisa ser >= %d (recebi %d)" % (lo, v))
        return v
    conv.__name__ = "inteiro"
    return conv


def cmd_retention(args):
    keys = [l.strip() for l in sys.stdin if l.strip()]
    protect = None
    if args.protect:
        protect = re.sub(r"\.(tar\.gz|manifest\.json)$", "", args.protect.rsplit("/", 1)[-1])
    skipped = []
    for k in retention_deletes(keys, args.prefix, args.now, args.keep_recent_h * 3600, args.keep_daily_days, args.floor, protect, skipped=skipped):
        print(k)
    if skipped:
        # stderr, não stdout: stdout é a lista de chaves a apagar e o chamador a lê linha a linha
        print("retention: %d chave(s) com data impossível ignoradas, NÃO apagadas: %s" % (len(skipped), ", ".join(sorted(skipped)[:5])), file=sys.stderr)
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
    mf.add_argument("--previous", default="", help="manifest do snapshot anterior (o de latest.json); sem ele não há régua (baseline none)")
    mf.add_argument("--baseline-unavailable", default="", metavar="MOTIVO", help="o anterior existe mas não deu para ler: o manifest diz, em vez de calar")
    mf.add_argument("--suspect-drop-pct", type=_int_range(1, 99), default=SUSPECT_DROP_PCT, help="queda (%%) que torna uma tabela suspect")
    mf.add_argument("--suspect-min-rows", type=_int_min(1), default=SUSPECT_MIN_PREV_ROWS, help="tabelas com menos linhas no anterior não entram na conta")
    mf.add_argument("--accept-drop", action="store_true", help="aceita a queda (decisão de quem opera): verdict ok, `suspect` e baseline.accepted ficam no manifest")
    mf.set_defaults(fn=cmd_manifest)
    rt = sub.add_parser("retention")
    rt.add_argument("--prefix", required=True)
    rt.add_argument("--now", type=int, required=True)
    # único caminho que decide o que se APAGA do backup de DR (a lista sai em stdout; quem apaga é o chamador): valor que afinaria a
    # política abaixo do piso é recusado (rc 2), não aplicado
    rt.add_argument("--keep-recent-h", type=_int_min(0), default=48)
    rt.add_argument("--keep-daily-days", type=_int_min(0), default=14)
    rt.add_argument("--floor", type=_int_min(1), default=6)
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
