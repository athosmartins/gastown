#!/usr/bin/env python3
"""jsonl_split.py (ga-e4cbc5s) — parte o documento único de uma tabela do archive em peças por dia, e conta as linhas do HEAD.

Contents
  Por quê · Formato · Subcomandos · Regras de fail-closed

POR QUÊ: cada export regrava hq/comments.jsonl (509 MB) e hq/issues.jsonl (112 MB) inteiros e o git guarda cada versão como blob novo inteiro até a compactação
  da madrugada (~180 MB por backup; de dia o disco do mini fica no piso). Em peças por dia só a do dia (e as poucas de beads antigas editadas) muda entre dois
  backups, e o blob novo é de poucos MB. Quem lê o archive (o pacote horário, jsonl_hourly.py build) junta as peças de volta.

FORMATO: <out-dir>/AAAA-MM-DD.jsonl, dia = os 10 primeiros caracteres de `created_at` ("AAAA-MM-DD HH:MM:SS" do Dolt, ou com T); linha sem data legível vai para
  undated.jsonl — nunca some. Cada peça é UM documento no formato do Dolt (`{"rows": [` + linhas separadas por `,` + `]}` e quebra de linha); o texto de cada linha
  é copiado como está (nada é reserializado), na ordem da entrada.

SUBCOMANDOS (rc 0 ok / 1 entrada ilegível ou conta que não fecha / 2 uso)
  split --in F --out-dir D [--expect-rows N]
      DUAS passadas sobre F (documento único). A 1ª não grava: valida o documento inteiro, confere --expect-rows e mede cada peça (bytes, sha256). A 2ª grava SÓ as
      peças que diferem das de D (o pico de disco é o das peças que mudaram, não o da tabela) e confere o que gravou contra a 1ª. Peça de dia que esvaziou é apagada;
      o mtime de D sempre avança (o alarme de idade da tabela lê o diretório). stdout = {"rows","pieces","written","removed"}.
  count-head --repo R --db NAME --table T [--rev HEAD]
      stdout = linhas da tabela no `rev` do archive, em documento único (layout antigo) ou em peças (novo); ausente = 0.

FAIL-CLOSED: documento truncado/com lixo/fora da forma, --expect-rows diferente do lido ou arquivo que mudou entre as passadas => rc 1 e as peças ficam como
  estavam. count-head com documento único E peças no mesmo rev, peça ou repo ilegível => rc 1 SEM número no stdout: ler mal nunca vira 0 aqui.
"""
import argparse
import collections
import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile

# python3 -I não põe o diretório do script no sys.path
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from jsonl_hourly import DumpError, PIECE_HEAD, PIECE_TAIL, count_rows, iter_rows, sha256_file  # noqa: E402

KEY = "created_at"
MAX_OPEN = 32  # peças abertas ao mesmo tempo (o launchd dá 256 handles); com mais dias que isso a peça é reaberta em append
UNDATED = "undated"
_DAY = re.compile(r"\d{4}-\d{2}-\d{2}")
_PIECE = re.compile(r"^(?:\d{4}-\d{2}-\d{2}|undated)\.jsonl$")
_TMP = re.compile(r"^(?:\d{4}-\d{2}-\d{2}|undated)\.jsonl\.tmp\.p(\d{1,9})$")
_DB_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$")  # o mesmo molde de nome de banco do jsonl_hourly.MEMBER_RE


class SplitError(Exception):
    """Entrada ilegível ou conta que não fecha."""


def period(value):
    """Dia (AAAA-MM-DD) de um created_at; qualquer outra coisa (ausente, nulo, não-texto, fora do formato) é `undated`: a linha vai, nunca some."""
    return value[:10] if isinstance(value, str) and _DAY.fullmatch(value[:10]) else UNDATED


def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:  # PermissionError: o processo existe, é de outro usuário
        return True
    return True


def _tmp(out_dir, p):
    return os.path.join(out_dir, "%s.jsonl.tmp.p%d" % (p, os.getpid()))


def _stream(src):
    """(período, bytes) de cada linha de `src`, já com o separador (o cabeçalho na 1ª linha do período): o que entra na peça, na ordem."""
    seen = set()
    try:
        with open(src, "rb") as fh:
            for obj, text in iter_rows(fh, raw=True):
                p = period(obj.get(KEY))
                yield p, (b"," if p in seen else PIECE_HEAD) + text.encode("utf-8")
                seen.add(p)
    except (DumpError, OSError) as e:
        raise SplitError("entrada ilegível (%s): %s" % (src, e))


def _scan(src):
    """Passada 1, sem gravar nada: valida o documento inteiro e mede cada peça. -> {período: [linhas, sha256, bytes]}"""
    acc = {}
    for p, data in _stream(src):
        a = acc.setdefault(p, [0, hashlib.sha256(), 0])
        a[0] += 1
        a[1].update(data)
        a[2] += len(data)
    if not acc:  # tabela vazia: UMA peça sem linhas; zero arquivos seria "tabela ausente" (o git não guarda diretório vazio)
        acc[UNDATED] = [0, hashlib.sha256(PIECE_HEAD), len(PIECE_HEAD)]
    for a in acc.values():
        a[1].update(PIECE_TAIL)
        a[2] += len(PIECE_TAIL)
    return acc


def _write(src, out_dir, want, acc):
    """Passada 2: grava as peças de `want` em <período>.jsonl.tmp.p<pid> e confere linhas e sha256 contra a passada 1."""
    opened, got = collections.OrderedDict(), {}

    def put(p, data):
        f = opened.pop(p, None) or open(_tmp(out_dir, p), "ab")
        opened[p] = f
        f.write(data)
        while len(opened) > MAX_OPEN:
            opened.popitem(last=False)[1].close()

    try:
        for p, data in _stream(src):
            if p in want:
                g = got.setdefault(p, [0, hashlib.sha256()])
                g[0] += 1
                g[1].update(data)
                put(p, data)
        for p in want:
            g = got.setdefault(p, [0, hashlib.sha256()])
            if g[0] == 0:  # a peça sem linhas: o cabeçalho ainda falta
                g[1].update(PIECE_HEAD)
                put(p, PIECE_HEAD)
            g[1].update(PIECE_TAIL)
            put(p, PIECE_TAIL)
    except OSError as e:
        raise SplitError("falha gravando as peças de %s: %s" % (src, e))
    finally:
        for f in opened.values():
            f.close()
    if any(got[p][0] != acc[p][0] or got[p][1].hexdigest() != acc[p][1].hexdigest() for p in want):
        raise SplitError("%s mudou entre as duas leituras" % src)


def split_doc(src, out_dir, expect_rows=None):
    acc = _scan(src)
    rows = sum(a[0] for a in acc.values())
    if expect_rows is not None and rows != expect_rows:
        raise SplitError("%s tem %d linhas, esperava %d" % (src, rows, expect_rows))
    os.makedirs(out_dir, exist_ok=True)
    # temporário de processo que morreu (ou que reaproveitou o nosso pid) é sobra; o de processo vivo é de outro e fica
    for name in os.listdir(out_dir):
        m = _TMP.match(name)
        if m and (int(m.group(1)) == os.getpid() or not _alive(int(m.group(1)))):
            os.unlink(os.path.join(out_dir, name))
    want = []
    for p in sorted(acc):
        final = os.path.join(out_dir, p + ".jsonl")
        try:
            same = os.stat(final).st_size == acc[p][2] and sha256_file(final)[0] == acc[p][1].hexdigest()
        except FileNotFoundError:
            same = False
        if not same:
            want.append(p)
    try:
        if want:
            _write(src, out_dir, want, acc)
            for p in want:
                os.replace(_tmp(out_dir, p), os.path.join(out_dir, p + ".jsonl"))
    finally:
        for p in want:
            try:
                os.unlink(_tmp(out_dir, p))
            except FileNotFoundError:
                pass
    removed = 0
    for name in os.listdir(out_dir):
        if _PIECE.match(name) and name[:-6] not in acc:
            os.unlink(os.path.join(out_dir, name))
            removed += 1
    os.utime(out_dir, None)
    return {"rows": rows, "pieces": len(acc), "written": len(want), "removed": removed}


def count_head(repo, db, table, rev="HEAD"):
    """Linhas de <db>/<table> no `rev` do archive: documento único (layout antigo) ou peças (novo). Ausente = 0; os dois juntos ou ilegível = SplitError."""
    single, pieces = "%s/%s.jsonl" % (db, table), "%s/%s" % (db, table)
    ls = subprocess.run(["git", "-C", repo, "ls-tree", "--name-only", rev, "--", single, pieces], capture_output=True)
    if ls.returncode != 0:
        raise SplitError("git ls-tree %s: %s" % (rev, ls.stderr.decode("utf-8", "replace").strip()))
    found = set(ls.stdout.decode("utf-8", "replace").split("\n")) - {""}
    if found == {single, pieces}:
        raise SplitError("%s e %s/ no mesmo %s: a tabela está nos dois layouts" % (single, pieces, rev))
    if not found:
        return 0
    n = 0
    p = subprocess.Popen(["git", "-C", repo, "archive", "--format=tar", rev, "--", found.pop()], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=p.stdout, mode="r|") as tf:
            for m in tf:
                if m.isreg():
                    n += count_rows(tf.extractfile(m))
        for _ in iter(lambda: p.stdout.read(1 << 20), b""):  # o resto do stream, para o git terminar
            pass
    except (DumpError, tarfile.TarError, OSError) as e:
        p.kill()
        p.wait()
        raise SplitError("lendo %s/%s em %s: %s" % (db, table, rev, e))
    err = p.stderr.read().decode("utf-8", "replace").strip()
    if p.wait() != 0:
        raise SplitError("git archive %s: %s" % (rev, err))
    return n


def _db(v):
    if not _DB_RE.match(v):
        raise argparse.ArgumentTypeError("nome de banco fora do molde %s: %r" % (_DB_RE.pattern, v))
    return v


def main(argv=None):
    ap = argparse.ArgumentParser(prog="jsonl_split.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("split")
    sp.add_argument("--in", dest="src", required=True)
    sp.add_argument("--out-dir", required=True)
    sp.add_argument("--expect-rows", type=int)
    ch = sub.add_parser("count-head")
    ch.add_argument("--repo", required=True)
    ch.add_argument("--db", required=True, type=_db)
    ch.add_argument("--table", required=True, choices=("issues", "comments"))
    ch.add_argument("--rev", default="HEAD")
    args = ap.parse_args(argv)
    try:
        if args.cmd == "split":
            print(json.dumps(split_doc(args.src, args.out_dir, args.expect_rows)))
        else:
            print(count_head(args.repo, args.db, args.table, args.rev))
    except (SplitError, OSError) as e:
        sys.stderr.write("jsonl_split: %s\n" % e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
