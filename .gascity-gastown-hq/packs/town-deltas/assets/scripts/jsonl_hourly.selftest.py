#!/usr/bin/env python3
"""jsonl_hourly.selftest.py (ga-c0939v.1) — testes do helper jsonl_hourly.py.

Contents
  Escopo · Como rodar · O que cada bloco prova

ESCOPO: hermético. Só tmpdir e subprocess do próprio helper; sem rede, sem bd, sem dolt, sem AWS.
COMO RODAR: python3 -I jsonl_hourly.selftest.py   (rc 0 = tudo passou; a última linha é `=== RESULT: PASS=n FAIL=n ===`)
O QUE PROVA:
  A. o parser incremental conta certo em QUALQUER tamanho de bloco (1 byte inclusive) e REJEITA todo dump truncado,
     com lixo, com vírgula sobrando ou não-UTF-8 — a varredura de truncamento cobre cada prefixo possível de um dump válido;
     só os 4 espaços de JSON valem como espaço (NBSP, U+2028, VT, FF são lixo);
  B. build/inspect: só entram <db>/<tabela>.jsonl, o artefato é determinístico, lixo de export abortado fica de fora, symlink/
     hardlink é NOMEADO em skipped, tar de entrada cortado num limite de membro falha (rc != 0) e tabela ilegível vira erro;
  C. manifest: broken quando falta tabela, banco obrigatório ou há erro de parse, ou quando o inspect e o build não descrevem os
     mesmos arquivos com os mesmos bytes;
  C2. banco ignorado (--ignore-db): sai do artefato, é NOMEADO no manifest, e nunca vale para banco obrigatório;
  E. retention: só toca chaves no formato exato, respeita piso, janela recente, primeiro do dia e o protegido; uma chave na
     forma exata mas com data impossível (mês 13) é ignorada, reportada e nunca apagada, sem parar a retenção das outras;
     upload quebrado (sem manifest) não ancora o "primeiro do dia" nem ocupa o piso; botão fora do limite é recusado (rc 2).
NÃO COBRE o lado do restore (convert/extract/reconcile): a suíte dele é jsonl_hourly_restore.selftest.py (ga-c0939v.3); os blocos
  seguem o nome original A-E do commit 629fdabf1, por isso não há bloco D aqui.
"""
import datetime
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "jsonl_hourly.py")
sys.path.insert(0, HERE)
import jsonl_hourly as jh  # noqa: E402

PASS = FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  PASS: " + name)
    else:
        FAIL += 1
        print("  FAIL: %s %s" % (name, detail))


def run(*args, stdin=None):
    p = subprocess.run([sys.executable, "-I", HELPER] + list(args), input=stdin, capture_output=True)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def rows(data, chunk):
    return list(jh.iter_rows(io.BytesIO(data), chunk))


def raises(data, chunk):
    try:
        rows(data, chunk)
    except jh.DumpError:
        return True
    except Exception as e:  # qualquer outra exceção é bug do parser, não "rejeitou o dump"
        print("    exceção inesperada: %r" % (e,))
        return False
    return False


print("=== jsonl_hourly.selftest.py ===")

# ── A. parser ─────────────────────────────────────────────────────────────────────────
print("-- A. iter_rows")
CHUNKS = (1, 2, 3, 5, 7, 64, 1 << 20)
good = {
    "duas linhas": (b'{"rows":[{"a":"1"},{"a":"2"}]}', 2),
    "com espaços": (b'{"rows": [ {"a":"1"} , {"a":"2"} ] }\n', 2),
    "rows vazio": (b'{"rows":[]}', 0),
    "tabela vazia {}": (b"{}", 0),
    "{} com quebra de linha": (b"{}\n", 0),
    "{} com espaços": (b"  {}  \n\n", 0),
    "}, { dentro de string": (b'{"rows":[{"t":"x},{y"},{"t":"z"}]}', 2),
    "aspas e barras escapadas": (b'{"rows":[{"t":"a\\"b\\\\c"},{"t":"\\u00e9"}]}', 2),
    "multibyte": ('{"rows":[{"t":"ação — 日本語 🙂"},{"t":"é"}]}'.encode("utf-8"), 2),
}
for name, (data, want) in good.items():
    got = [len(rows(data, c)) for c in CHUNKS]
    check("conta %s em todos os tamanhos de bloco" % name, all(g == want for g in got), "got=%s want=%d" % (got, want))

mb = rows('{"rows":[{"t":"ação — 日本語 🙂"}]}'.encode("utf-8"), 1)
check("multibyte em bloco de 1 byte volta idêntico", mb == [{"t": "ação — 日本語 🙂"}], repr(mb))
nest = rows(b'{"rows":[{"t":"x},{y"},{"t":"z"}]}', 1)
check("}, { dentro de string não parte a linha", nest == [{"t": "x},{y"}, {"t": "z"}], repr(nest))

bad_docs = {
    "arquivo vazio": b"",
    "só espaços": b"   \n",
    "truncado no meio da linha": b'{"rows":[{"a":"1"},{"a":"2',
    "truncado depois da vírgula": b'{"rows":[{"a":"1"},',
    "falta o ] e o }": b'{"rows":[{"a":"1"}',
    "falta o } final": b'{"rows":[{"a":"1"}]',
    "só o cabeçalho": b'{"rows":',
    "lixo depois do }": b'{"rows":[{"a":"1"}]}xyz',
    "segundo documento": b'{"rows":[{"a":"1"}]}{"rows":[]}',
    "}} duplo": b'{"rows":[{"a":"1"}]}}',
    "vírgula sobrando": b'{"rows":[{"a":"1"},]}',
    "vírgula na frente": b'{"rows":[,{"a":"1"}]}',
    "linhas sem vírgula": b'{"rows":[{"a":"1"}{"a":"2"}]}',
    "linha que não é objeto": b'{"rows":[1,2]}',
    "array no topo": b'[{"a":"1"}]',
    "chave errada": b'{"data":[{"a":"1"}]}',
    "{} com lixo": b"{} x",
    "{}{}": b"{}{}",
    "não-UTF8": b'{"rows":[{"a":"\xff\xfe"}]}',
    "json inválido na linha": b'{"rows":[{"a":}]}',
    # espaço que NÃO é espaço de JSON (só ' ', \t, \n, \r são): o docstring promete que lixo depois do } final é erro
    "NBSP depois do } final": b'{"rows":[{"a":"1"}]}\xc2\xa0',
    "U+2028 entre as linhas": b'{"rows":[{"a":"1"}\xe2\x80\xa8,{"a":"2"}]}',
    "NBSP antes do cabeçalho": b'\xc2\xa0{"rows":[]}',
    "NBSP em {} vazio": b"{}\xc2\xa0",
    "VT depois do ]": b'{"rows":[{"a":"1"}]\x0b}',
}
for name, data in bad_docs.items():
    got = [raises(data, c) for c in CHUNKS]
    check("rejeita %s em todos os tamanhos de bloco" % name, all(got), "got=%s" % got)

# varredura de truncamento: nenhum prefixo próprio de um dump válido pode ser aceito
doc = '{"rows":[{"a":"é","b":"x},{y"},{"b":"2"}]}\n'.encode("utf-8")
accepted = []
for cut in range(len(doc) - 1):  # o prefixo sem o "\n" final ainda é um documento completo
    for c in (1, 4, 1 << 20):
        try:
            rows(doc[:cut], c)
            accepted.append((cut, c))
        except jh.DumpError:
            pass
check("varredura: nenhum prefixo truncado de um dump válido é aceito (%d cortes x 3 blocos)" % (len(doc) - 1),
      not accepted, "aceitos=%s" % accepted[:5])
def why(data, chunk):
    try:
        rows(data, chunk)
    except jh.DumpError as e:
        return str(e)
    return ""


check("dump cortado depois de uma linha completa diz que truncou DENTRO de rows (não só que falta o })",
      all("truncado dentro de rows" in why(b'{"rows":[{"a":"1"}', c) for c in CHUNKS), [why(b'{"rows":[{"a":"1"}', c) for c in CHUNKS])
check("o dump inteiro e o dump sem o \\n final são aceitos", len(rows(doc, 3)) == 2 and len(rows(doc[:-1], 3)) == 2)
ws_ok = b'{"rows":\t[ {"a":"1"}\t,\r\n{"a":"2"} ]\r\n}\r\n'
check("os 4 espaços de JSON (espaço, tab, \\r, \\n) seguem aceitos em todo lugar", all(len(rows(ws_ok, c)) == 2 for c in CHUNKS)
      and all(len(rows(b" \t\r\n{}\r\n\t ", c)) == 0 for c in CHUNKS))

# ── B. build / inspect ────────────────────────────────────────────────────────────────
print("-- B. build / inspect")


def make_tar(members):
    bio = io.BytesIO()
    with tarfile.open(fileobj=bio, mode="w") as tf:
        for name, content in members:
            ti = tarfile.TarInfo(name=name)
            data = content.encode("utf-8") if isinstance(content, str) else content
            ti.size = len(data)
            ti.mtime = 1234567890  # propositalmente diferente de 0: o build tem que zerar
            tf.addfile(ti, io.BytesIO(data))
    return bio.getvalue()


def table(rows_):
    return json.dumps({"rows": rows_}, separators=(",", ":")) if rows_ else "{}"


def db_members(db, issues, comments=(), deps=(), labels=(), config=(), metadata=()):
    return [("%s/issues.jsonl" % db, table(list(issues))), ("%s/comments.jsonl" % db, table(list(comments))),
            ("%s/dependencies.jsonl" % db, table(list(deps))), ("%s/labels.jsonl" % db, table(list(labels))),
            ("%s/config.jsonl" % db, table(list(config))), ("%s/metadata.jsonl" % db, table(list(metadata)))]


with tempfile.TemporaryDirectory(prefix="jhst.") as T:
    members = (db_members("hq", [{"id": "hq-1"}, {"id": "hq-2"}], comments=[{"id": "c1", "issue_id": "hq-1"}])
               + db_members("wa", [{"id": "wa-1"}])
               + [("hq.jsonl", table([{"id": "hq-1"}])),                     # cópia legada da raiz
                  ("hq/issues.jsonl.tmp.99", "lixo"),                         # sobra de export abortado
                  ("hq/outro.jsonl", "{}"), ("a/b/issues.jsonl", "{}"), ("README", "x")])
    tar_bytes = make_tar(members)
    out1, f1 = os.path.join(T, "a.tar.gz"), os.path.join(T, "a.json")
    rc, so, se = run("build", "--out", out1, "--files-out", f1, stdin=tar_bytes)
    built = json.load(open(f1))
    check("build: rc 0 e só os 12 arquivos <db>/<tabela>.jsonl entram", rc == 0 and len(built["files"]) == 12, "rc=%s %s %s" % (rc, so, se))
    check("build: raiz legada, *.tmp.*, tabela desconhecida e subdiretório fundo ficam em skipped",
          sorted(built["skipped"]) == sorted(["hq.jsonl", "hq/issues.jsonl.tmp.99", "hq/outro.jsonl", "a/b/issues.jsonl", "README"]), repr(built["skipped"]))
    out2, f2 = os.path.join(T, "b.tar.gz"), os.path.join(T, "b.json")
    run("build", "--out", out2, "--files-out", f2, stdin=tar_bytes)
    check("build: determinístico (mesma entrada, mesmo sha256 do artefato)", json.load(open(f2))["artifact"]["sha256"] == built["artifact"]["sha256"])
    check("build: sha256 de cada arquivo bate com o conteúdo",
          all(f["sha256"] == __import__("hashlib").sha256(dict(members)[f["path"]].encode()).hexdigest() for f in built["files"]))
    rc, so, _ = run("inspect", out1)
    insp = json.loads(so)
    check("inspect: rc 0 e contagens lidas do artefato", rc == 0 and insp["databases"]["hq"]["issues"] == 2
          and insp["databases"]["hq"]["comments"] == 1 and insp["databases"]["wa"]["issues"] == 1 and insp["databases"]["wa"]["labels"] == 0, so)

    rc, so, _ = run("build", "--out", os.path.join(T, "c.tar.gz"), "--files-out", os.path.join(T, "c.json"),
                    stdin=make_tar([("README", "x"), ("hq.jsonl", "{}")]))
    check("build: tar sem nenhum <db>/<tabela>.jsonl => rc 1", rc == 1, so)
    rc, so, se = run("build", "--out", os.path.join(T, "d.tar.gz"), "--files-out", os.path.join(T, "d.json"),
                     stdin=make_tar([("hq/issues.jsonl", "{}"), ("hq/issues.jsonl", "{}")]))
    check("build: membro repetido => erro (não escolhe um em silêncio)", rc != 0, "%s %s" % (so, se))

    # tar de entrada cortado num LIMITE de membro: o tarfile em modo stream lê isso como "fim do arquivo" e o build dava rc 0 com
    # o banco inteiro faltando. Um tar completo termina em >= 1024 bytes NUL; sem isso o build tem que falhar, em qualquer ponto de corte.
    offs = [mi.offset for mi in tarfile.open(fileobj=io.BytesIO(tar_bytes)).getmembers()]
    cut_rcs = {}
    for idx in (1, 6, 12):   # começo do 2º, do 7º (o banco 'wa' some inteiro) e do 13º membro
        cut_rcs[idx] = run("build", "--out", os.path.join(T, "cut.tar.gz"), "--files-out", os.path.join(T, "cut.json"), stdin=tar_bytes[:offs[idx]])
    check("build: tar cortado num limite de membro => rc != 0 e a causa vai para o stderr (não rc 0 com banco faltando)",
          all(r[0] != 0 and r[2].strip() for r in cut_rcs.values()), repr({i: (r[0], r[2][-80:]) for i, r in cut_rcs.items()}))
    rc, so, se = run("build", "--out", os.path.join(T, "full.tar.gz"), "--files-out", os.path.join(T, "full.json"), stdin=tar_bytes)
    check("build: o tar completo (com a faixa final de zeros) segue passando", rc == 0, "%s %s" % (so, se))

    # symlink/hardlink não viaja, mas não pode sumir em silêncio: entra em skipped (e daí em `excluded` do manifest).
    # Diretórios NÃO entram: o `git archive` emite um por pasta e inundaria o manifest.
    bio = io.BytesIO()
    with tarfile.open(fileobj=bio, mode="w") as tf_:
        for nm, ty, ln in (("hq", tarfile.DIRTYPE, ""), ("wa/labels.jsonl", tarfile.SYMTYPE, "issues.jsonl"), ("wa/config.jsonl", tarfile.LNKTYPE, "hq/config.jsonl")):
            ti = tarfile.TarInfo(name=nm)
            ti.type, ti.linkname = ty, ln
            tf_.addfile(ti)
        for nm, content in db_members("hq", [{"id": "hq-1"}]):
            ti = tarfile.TarInfo(name=nm)
            ti.size = len(content.encode())
            tf_.addfile(ti, io.BytesIO(content.encode()))
    link_out, link_files = os.path.join(T, "link.tar.gz"), os.path.join(T, "link.json")
    rc, so, se = run("build", "--out", link_out, "--files-out", link_files, stdin=bio.getvalue())
    link_built = json.load(open(link_files))
    check("build: symlink e hardlink ficam NOMEADOS em skipped; o diretório não", rc == 0
          and sorted(link_built["skipped"]) == ["wa/config.jsonl", "wa/labels.jsonl"], "%s %s" % (rc, link_built["skipped"]))

    bad_members = db_members("hq", [{"id": "hq-1"}]) + [("hq/comments.jsonl", '{"rows":[{"id":"c1"},{"id":"c2"')]
    bad_members = [m for i, m in enumerate(bad_members) if not (m[0] == "hq/comments.jsonl" and i < 5)]
    outb, fb = os.path.join(T, "e.tar.gz"), os.path.join(T, "e.json")
    run("build", "--out", outb, "--files-out", fb, stdin=make_tar(bad_members))
    rc, so, _ = run("inspect", outb)
    insp_bad = json.loads(so)
    check("inspect: tabela truncada => rc 1, erro nomeado e SEM contagem parcial dessa tabela",
          rc == 1 and any(e["path"] == "hq/comments.jsonl" for e in insp_bad["errors"])
          and "comments" not in insp_bad["databases"].get("hq", {}), so)

    # ── C. manifest ───────────────────────────────────────────────────────────────────
    print("-- C. manifest")
    meta = {"captured_epoch": 1000300, "head_epoch": 1000000, "head_sha": "a" * 40, "key": "p/snap/x.tar.gz"}
    m = jh.build_manifest(insp, built, meta, ["hq", "wa"])
    check("manifest ok: verdict ok, sem problemas, datas e idade do HEAD", m["verdict"] == "ok" and not m["problems"]
          and m["source"]["head_age_s"] == 300 and m["data_as_of"] == "1970-01-12T13:46:40Z", json.dumps(m["problems"]))
    check("manifest ok: sha/bytes do artefato e linhas por arquivo", m["artifact"]["sha256"] == built["artifact"]["sha256"]
          and {f["path"]: f["rows"] for f in m["files"]}["hq/issues.jsonl"] == 2)
    check("manifest: banco obrigatório ausente => broken", jh.build_manifest(insp, built, meta, ["hq", "nada"])["verdict"] == "broken")
    zero = json.loads(json.dumps(insp))
    zero["databases"]["wa"]["issues"] = 0
    check("manifest: banco obrigatório com 0 issues => broken", jh.build_manifest(zero, built, meta, ["wa"])["verdict"] == "broken")
    check("manifest: sem bancos => broken", jh.build_manifest({"databases": {}, "files": [], "errors": []}, built, meta, [])["verdict"] == "broken")
    check("manifest: erro de parse no artefato => broken", jh.build_manifest(insp_bad, built, meta, [])["verdict"] == "broken")
    # o que o build gravou e o que o inspect leu do artefato têm que ser o MESMO conjunto, com os mesmos bytes: senão o veredito
    # (calculado sobre o que foi lido) descreve outra coisa que não o que subiu, e files[].rows sai null com verdict ok.
    no_wa = json.loads(json.dumps(insp))
    del no_wa["databases"]["wa"]
    no_wa["files"] = [f for f in no_wa["files"] if not f["path"].startswith("wa/")]
    mw = jh.build_manifest(no_wa, built, meta, [])
    check("manifest: banco gravado pelo build mas AUSENTE do que o inspect leu (e não obrigatório) => broken, nomeando o arquivo",
          mw["verdict"] == "broken" and any("wa/issues.jsonl" in p for p in mw["problems"]), json.dumps(mw["problems"])[:200])
    diff_b = json.loads(json.dumps(insp))
    diff_b["files"][0]["bytes"] += 1
    md = jh.build_manifest(diff_b, built, meta, [])
    check("manifest: bytes do arquivo diferentes entre o inspect e o build => broken, nomeando o arquivo",
          md["verdict"] == "broken" and any(diff_b["files"][0]["path"] in p for p in md["problems"]), json.dumps(md["problems"])[:200])
    extra = json.loads(json.dumps(insp))
    extra["files"].append({"path": "hq/fantasma.jsonl", "bytes": 3, "rows": 0})
    me = jh.build_manifest(extra, built, meta, [])
    check("manifest: arquivo que o inspect leu e o build não gravou => broken, nomeando o arquivo",
          me["verdict"] == "broken" and any("hq/fantasma.jsonl" in p for p in me["problems"]), json.dumps(me["problems"])[:200])
    nofiles = json.loads(json.dumps(insp))
    del nofiles["files"]
    check("manifest: inspect sem a chave `files` (ilegível) => broken, nunca ok", jh.build_manifest(nofiles, built, meta, [])["verdict"] == "broken")
    miss = json.loads(json.dumps(insp))
    del miss["databases"]["hq"]["labels"]
    mm = jh.build_manifest(miss, built, meta, [])
    check("manifest: banco sem uma das 6 tabelas => broken, nomeando o arquivo",
          mm["verdict"] == "broken" and any("hq/labels.jsonl" in p for p in mm["problems"]), json.dumps(mm["problems"]))
    ins_f, bu_f = os.path.join(T, "i.json"), os.path.join(T, "b2.json")
    json.dump(insp, open(ins_f, "w"))
    json.dump(built, open(bu_f, "w"))
    rc, so, _ = run("manifest", "--inspect", ins_f, "--built", bu_f, "--captured-epoch", "1000300", "--head-epoch", "1000000",
                    "--head-sha", "b" * 40, "--key", "k", "--require", "hq,wa")
    check("manifest (CLI): rc 0 e verdict ok", rc == 0 and json.loads(so)["verdict"] == "ok", so)
    rc, so, _ = run("manifest", "--inspect", ins_f, "--built", bu_f, "--captured-epoch", "1000300", "--head-epoch", "1000000",
                    "--head-sha", "b" * 40, "--key", "k", "--require", "hq,fantasma")
    check("manifest (CLI): banco obrigatório ausente => rc 1", rc == 1 and json.loads(so)["verdict"] == "broken", so)

    # ── C3. queda brusca contra o snapshot anterior => suspect (ga-l6v576) ─────────────────────────────────────────
    # 18/10: o export do hq cortou comments em 10.112 linhas (79 x 128) contra 35.132 do dia 17 e o manifest saiu `verdict: ok`. A queda não é
    # perda: o export vinha truncado. O verdict agora olha o snapshot anterior (o apontado por latest.json).
    print("-- C3. queda brusca contra o anterior => suspect")

    def counts_of(base, **over):
        """cópia de `base` (um inspect ou um manifest) com as contagens trocadas: over = {"hq": {"comments": 10112}}"""
        d = json.loads(json.dumps(base))
        for db_, tabs in over.items():
            d["databases"].setdefault(db_, {}).update(tabs)
        return d

    def mf(prev, ins=None, **kw):
        """build_manifest com o anterior; um TypeError (parâmetro que ainda não existe) vira FAIL do teste, não queda da suíte"""
        try:
            return jh.build_manifest(ins if ins is not None else insp, built, meta, ["hq", "wa"], prev=prev, **kw)
        except Exception as e:  # noqa: BLE001
            return {"verdict": "erro: %r" % e, "problems": [], "suspect": [], "baseline": {}}

    prev_ok = counts_of(m, hq={"issues": 4000, "comments": 35132, "dependencies": 9000, "labels": 3000, "config": 12, "metadata": 4},
                        wa={"issues": 300, "comments": 500, "dependencies": 100, "labels": 40, "config": 5, "metadata": 2})
    cur_ins = counts_of(insp, hq={"issues": 4010, "comments": 35140, "dependencies": 9005, "labels": 3002, "config": 12, "metadata": 4},
                        wa={"issues": 300, "comments": 500, "dependencies": 100, "labels": 40, "config": 5, "metadata": 2})
    mg = mf(prev_ok, cur_ins)
    check("suspect: tudo igual ou crescendo => ok, baseline compared", mg["verdict"] == "ok" and not mg.get("suspect")
          and mg.get("baseline", {}).get("state") == "compared", json.dumps([mg["verdict"], mg.get("suspect"), mg.get("baseline")]))
    trunc = counts_of(cur_ins, hq={"comments": 10112})
    mt = mf(prev_ok, trunc)
    check("suspect: hq/comments 35.132 -> 10.112 (o caso de 18/10) => suspect, NÃO ok", mt["verdict"] == "suspect", mt["verdict"])
    check("suspect: o motivo NOMEIA banco, tabela e os dois números; `problems` (o que é broken) continua vazio",
          any("hq/comments" in s and "35132" in s and "10112" in s for s in mt.get("suspect", [])) and not mt["problems"], json.dumps(mt.get("suspect")))
    check("suspect: só a tabela que caiu é nomeada", len(mt.get("suspect", [])) == 1, json.dumps(mt.get("suspect")))
    exact = counts_of(cur_ins, hq={"comments": 28106})   # 35132 * 80% = 28105,6: 28106 é uma queda de 19,99% (limite: > 20%)
    over_ = counts_of(cur_ins, hq={"comments": 28105})   # 20,0006%
    check("suspect: no limite (queda de 19,99%) => ok; um a menos (queda > 20%) => suspect",
          mf(prev_ok, exact)["verdict"] == "ok" and mf(prev_ok, over_)["verdict"] == "suspect")
    tiny_prev = counts_of(prev_ok, wa={"labels": 99})
    check("suspect: tabela pequena no anterior (< 100 linhas) oscila à vontade: 99 -> 0 => ok; 100 -> 0 => suspect",
          mf(tiny_prev, counts_of(cur_ins, wa={"labels": 0}))["verdict"] == "ok"
          and mf(counts_of(prev_ok, wa={"labels": 100}), counts_of(cur_ins, wa={"labels": 0}))["verdict"] == "suspect")
    # filhos somem junto com o pai: se `issues` do mesmo banco caiu tanto quanto, a queda das outras tabelas tem explicação (uma purga)
    purge = counts_of(cur_ins, hq={"issues": 1500, "comments": 9000, "dependencies": 3000, "labels": 1000})
    mp = mf(prev_ok, purge)
    check("suspect: issues caiu junto (purga) => os filhos que caíram têm explicação, mas o `issues` em si segue suspect (ninguém o explica)",
          mp["verdict"] == "suspect" and len(mp.get("suspect", [])) == 1 and "hq/issues" in mp["suspect"][0], json.dumps(mp.get("suspect")))
    kids_only = counts_of(cur_ins, hq={"comments": 100, "labels": 5})
    check("suspect: comments E labels caindo com issues estável => as duas tabelas são nomeadas",
          len(mf(prev_ok, kids_only).get("suspect", [])) == 2)
    no_hq = json.loads(json.dumps(prev_ok))
    del no_hq["databases"]["hq"]
    no_cm = json.loads(json.dumps(prev_ok))
    del no_cm["databases"]["hq"]["comments"]
    check("suspect: banco novo (sem anterior), tabela sem anterior e anterior ilegível NÃO entram na conta (não sei != caiu)",
          mf(no_hq, trunc)["verdict"] == "ok" and mf(no_cm, trunc)["verdict"] == "ok"
          and mf({"verdict": "ok", "databases": {"zz": {"issues": 10}}}, trunc)["verdict"] == "ok"
          and mf({"verdict": "ok", "databases": {"hq": {"comments": "abc", "issues": None}}}, trunc)["verdict"] == "ok")
    check("baseline: sem anterior (1º run) => ok, state none; nada de suspect", mf(None)["verdict"] == "ok" and mf(None)["baseline"].get("state") == "none")
    mu = mf(None, baseline_unavailable="S3 não respondeu")
    check("baseline: anterior que não deu para ler => ok MAS dito no manifest (state unavailable + motivo), nunca calado",
          mu["verdict"] == "ok" and mu["baseline"].get("state") == "unavailable" and "S3 não respondeu" in mu["baseline"].get("why", ""), json.dumps(mu.get("baseline")))
    check("baseline: anterior fora da forma (sem `databases`) => unavailable, nunca compared",
          mf({"verdict": "ok"})["baseline"].get("state") == "unavailable" and mf([1, 2])["baseline"].get("state") == "unavailable")
    prev_broken = json.loads(json.dumps(prev_ok))
    prev_broken["verdict"] = "broken"
    check("baseline: o anterior declarado broken/suspect não serve de régua => unavailable",
          mf(prev_broken)["baseline"].get("state") == "unavailable")
    miss_wa = json.loads(json.dumps(insp))
    del miss_wa["databases"]["wa"]
    miss_wa["files"] = [f for f in miss_wa["files"] if not f["path"].startswith("wa/")]
    try:
        mbk = jh.build_manifest(miss_wa, built, meta, ["hq", "wa"], prev=prev_ok)["verdict"]
    except Exception as e:  # noqa: BLE001
        mbk = "erro: %r" % e
    check("broken vence suspect: banco obrigatório ausente E queda brusca => broken", mbk == "broken", mbk)
    check("limiar por parâmetro: com --suspect-drop-pct 90 a queda de 71% passa", mf(prev_ok, trunc, suspect_drop_pct=90)["verdict"] == "ok")
    check("limiar por parâmetro: piso de linhas 100000 deixa tudo passar", mf(prev_ok, trunc, suspect_min_rows=100000)["verdict"] == "ok")
    ma = mf(prev_ok, trunc, accept_drop=True)
    check("accept_drop: verdict ok, mas o manifest guarda o que foi aceito (`suspect` e baseline.accepted)",
          ma["verdict"] == "ok" and len(ma.get("suspect", [])) == 1 and ma["baseline"].get("accepted") is True, json.dumps([ma["verdict"], ma.get("suspect"), ma["baseline"]]))
    check("constantes: o limiar e o piso estão no módulo (20% e 100 linhas)", getattr(jh, "SUSPECT_DROP_PCT", None) == 20 and getattr(jh, "SUSPECT_MIN_PREV_ROWS", None) == 100)

    def jget(so, *path):
        """campo de uma saída JSON do CLI; saída que não é JSON (uso, traceback) lê como None e o check reprova"""
        try:
            d = json.loads(so)
            for k in path:
                d = d[k]
            return d
        except (ValueError, KeyError, TypeError):
            return None

    # CLI: --previous / --baseline-unavailable / --suspect-* / --accept-drop
    cur_f, prev_f, prev_bad_f = os.path.join(T, "ci.json"), os.path.join(T, "pm.json"), os.path.join(T, "pbad.json")
    json.dump(trunc, open(cur_f, "w"))
    json.dump(prev_ok, open(prev_f, "w"))
    open(prev_bad_f, "w").write("{não é json")
    cli = ["manifest", "--inspect", cur_f, "--built", bu_f, "--captured-epoch", "1000300", "--head-epoch", "1000000", "--head-sha", "b" * 40, "--key", "k", "--require", "hq,wa"]
    rc, so, se = run(*cli, "--previous", prev_f)
    check("manifest (CLI): --previous com queda brusca => rc 1 e verdict suspect", rc == 1 and jget(so, "verdict") == "suspect", "%s %s %s" % (rc, so[:200], se[:200]))
    rc, so, _ = run(*cli)
    check("manifest (CLI): sem --previous => rc 0, state none", rc == 0 and jget(so, "baseline", "state") == "none", so[:200])
    rc, so, _ = run(*cli, "--previous", prev_bad_f)
    check("manifest (CLI): --previous ilegível => rc 0 mas baseline unavailable (o comparador não derruba o manifest)",
          rc == 0 and jget(so, "baseline", "state") == "unavailable", so[:300])
    rc, so, _ = run(*cli, "--previous", os.path.join(T, "nao-existe.json"))
    check("manifest (CLI): --previous apontando para arquivo que não existe => unavailable", rc == 0 and jget(so, "baseline", "state") == "unavailable", so[:300])
    rc, so, _ = run(*cli, "--baseline-unavailable", "latest.json ilegível")
    check("manifest (CLI): --baseline-unavailable MOTIVO => unavailable com o motivo",
          rc == 0 and jget(so, "baseline") == {"state": "unavailable", "why": "latest.json ilegível"}, so[:300])
    rc, so, _ = run(*cli, "--previous", prev_f, "--suspect-drop-pct", "90")
    check("manifest (CLI): --suspect-drop-pct 90 => rc 0", rc == 0 and jget(so, "verdict") == "ok", so[:200])
    rc, so, _ = run(*cli, "--previous", prev_f, "--accept-drop")
    check("manifest (CLI): --accept-drop => rc 0, suspect guardado", rc == 0 and jget(so, "verdict") == "ok" and jget(so, "suspect"), so[:300])
    rc, so, _ = run(*cli, "--previous", prev_f, "--suspect-drop-pct", "0")
    check("manifest (CLI): --suspect-drop-pct 0 é recusado (rc 2): queda de 0% nunca é limiar", rc == 2, "%s %s" % (rc, so[:100]))

    # ── C2. bancos ignorados (o 1º upload real reprovou por causa de bench_hq_copy: config/metadata com 0 bytes) ──
    print("-- C2. bancos ignorados por padrão de nome")
    junk_members = (db_members("hq", [{"id": "hq-1"}, {"id": "hq-2"}]) + db_members("wa", [{"id": "wa-1"}])
                    + [(n, t) for n, t in db_members("bench_hq_copy", [{"id": "b-1"}]) if not n.endswith(("config.jsonl", "metadata.jsonl"))]
                    + [("bench_hq_copy/config.jsonl", ""), ("bench_hq_copy/metadata.jsonl", ""), ("bench_hq_copy.jsonl", table([{"id": "b-1"}]))]
                    + db_members("fixdepkeys_0d16f874c5d7", [{"id": "f-1"}]) + [("fixdepkeys_0d16f874c5d7/issues.jsonl.tmp.Td3hQh", "")])
    junk_tar = make_tar(junk_members)

    def pipeline(tar_bytes, tag, ignore=None, require="hq,wa"):
        """build -> inspect -> manifest como o shell encadeia; devolve (build_rc, built, inspect, manifest, manifest_rc)."""
        art, fl = os.path.join(T, tag + ".tar.gz"), os.path.join(T, tag + ".files.json")
        args = ["build", "--out", art, "--files-out", fl] + (["--ignore-db", ignore] if ignore is not None else [])
        brc, _, _ = run(*args, stdin=tar_bytes)
        if brc != 0:
            return brc, None, None, None, None
        _, so, _ = run("inspect", art)
        ins_p, bu_p = os.path.join(T, tag + ".insp.json"), fl
        open(ins_p, "w").write(so)
        mrc, mso, _ = run("manifest", "--inspect", ins_p, "--built", bu_p, "--captured-epoch", "1000300", "--head-epoch", "1000000",
                          "--head-sha", "c" * 40, "--key", "k", "--require", require)
        return brc, json.load(open(fl)), json.loads(so), json.loads(mso), mrc

    brc, bu, ins_j, man, mrc = pipeline(junk_tar, "junk-noignore")
    check("SEM ignorar: o mesmo fixture do 1º upload real fica broken, e o problema nomeia o banco lixo (o teste reproduz o incidente)",
          mrc == 1 and man["verdict"] == "broken" and any("bench_hq_copy/config.jsonl" in p for p in man["problems"]), json.dumps(man and man["problems"]))
    brc, bu, ins_j, man, mrc = pipeline(junk_tar, "junk-ignore", ignore="bench_*,fixdepkeys_*")
    check("ignorando bench_*,fixdepkeys_*: rc 0, verdict ok, sem problemas", mrc == 0 and man["verdict"] == "ok" and not man["problems"], json.dumps(man and man["problems"]))
    check("ignorando: o artefato tem só hq e wa (12 arquivos) — o lixo não viaja",
          len(bu["files"]) == 12 and sorted(ins_j["databases"]) == ["hq", "wa"], "%s %s" % (len(bu["files"]), sorted(ins_j["databases"])))
    check("ignorando: o manifest NOMEIA os bancos ignorados e os padrões (nada some em silêncio)",
          man["ignored_dbs"] == ["bench_hq_copy", "fixdepkeys_0d16f874c5d7"] and man["ignore_patterns"] == ["bench_*", "fixdepkeys_*"],
          json.dumps([man.get("ignored_dbs"), man.get("ignore_patterns")]))
    check("ignorando: a cópia legada da raiz e a sobra *.tmp.* seguem em excluded, não em ignored_dbs",
          "bench_hq_copy.jsonl" in man["excluded"] and "fixdepkeys_0d16f874c5d7/issues.jsonl.tmp.Td3hQh" in man["excluded"]
          and not any(d.endswith(".jsonl") for d in man["ignored_dbs"]), json.dumps(man["excluded"]))
    check("ignorar não enfraquece a checagem dos outros: contagens de hq/wa intactas", man["databases"]["hq"]["issues"] == 2 and man["databases"]["wa"]["issues"] == 1)
    brc, bu, ins_j, man, mrc = pipeline(junk_tar, "junk-hq-ignored", ignore="hq*,bench_*,fixdepkeys_*")
    check("banco OBRIGATÓRIO que casa com o padrão => broken, e a razão diz que foi ignorado (não só 'ausente')",
          mrc == 1 and man["verdict"] == "broken" and any("hq" in p and "ignorad" in p for p in man["problems"]), json.dumps(man and man["problems"]))
    brc, *_ = pipeline(junk_tar, "junk-all", ignore="*")
    check("padrão '*' => build rc 1 (nada sobra para subir)", brc == 1)
    brc, bu, ins_j, man, mrc = pipeline(junk_tar, "junk-sloppy", ignore=" bench_* , ,fixdepkeys_*,")
    check("padrões com espaços e itens vazios: aparados, sem padrão vazio que casaria tudo",
          mrc == 0 and man["ignore_patterns"] == ["bench_*", "fixdepkeys_*"], json.dumps(man and man.get("ignore_patterns")))
    brc, bu, ins_j, man, mrc = pipeline(junk_tar, "junk-empty", ignore="")
    check("--ignore-db '' (vazio) equivale a não ignorar nada: continua broken", mrc == 1 and man["verdict"] == "broken" and man["ignored_dbs"] == [], json.dumps(man and man["problems"]))
    near_tar = make_tar(db_members("hq", [{"id": "hq-1"}]) + db_members("wa", [{"id": "wa-1"}])
                        + [(n, t) for n, t in db_members("benchmark_real", [{"id": "r-1"}]) if not n.endswith("config.jsonl")] + [("benchmark_real/config.jsonl", "")])
    brc, bu, ins_j, man, mrc = pipeline(near_tar, "near", ignore="bench_*,fixdepkeys_*")
    check("nome parecido que NÃO casa (benchmark_real) segue valendo: broken (o padrão não é prefixo solto)",
          mrc == 1 and any("benchmark_real/config.jsonl" in p for p in man["problems"]), json.dumps(man and man["problems"]))
    brc, bu, ins_j, man, mrc = pipeline(make_tar(db_members("hq", [{"id": "hq-1"}]) + db_members("wa", [{"id": "wa-1"}]) + db_members("BENCH_x", [{"id": "x"}])),
                                        "case", ignore="bench_*")
    check("casamento diferencia maiúsculas (BENCH_x não é bench_*): na dúvida, não ignora", mrc == 0 and "BENCH_x" in man["databases"] and man["ignored_dbs"] == [])

# ── E. retention ──────────────────────────────────────────────────────────────────────
print("-- E. retention")
P = "jsonl-hourly"
NOW = datetime.datetime(2026, 10, 16, 12, 0, 0, tzinfo=datetime.timezone.utc)


def stem(hours_ago, n):
    t = NOW - datetime.timedelta(hours=hours_ago)
    return t.strftime("%Y%m%dT%H%M%SZ") + "-" + ("%012x" % n)


def keys_for(stems, kinds=("tar.gz", "manifest.json")):
    return ["%s/snap/%s.%s" % (P, s, k) for s in stems for k in kinds]


def retention(keys, **kw):
    args = dict(prefix=P, now=int(NOW.timestamp()), keep_recent_s=48 * 3600, keep_daily_days=14, floor=6)
    args.update(kw)
    return jh.retention_deletes(keys, **args)


hourly = [stem(h, h + 1) for h in range(0, 120)]
dels = retention(keys_for(hourly))
kept_stems = {s for s in hourly if "%s/snap/%s.tar.gz" % (P, s) not in dels}
check("retention: 120 snapshots horários => 53 ficam (49 da janela de 48 h + 4 primeiros-do-dia)", len(kept_stems) == 53, str(len(kept_stems)))
check("retention: o mais novo e o mais velho do dia mais antigo ficam", hourly[0] in kept_stems and hourly[-1] in kept_stems)
check("retention: nunca apaga só metade de um snapshot (tar.gz e manifest saem juntos)",
      all(("%s/snap/%s.manifest.json" % (P, s) in dels) == ("%s/snap/%s.tar.gz" % (P, s) in dels) for s in hourly))
untouched = ["%s/latest.json" % P, "%s/_probe/x" % P, "%s/snap/notes.txt" % P, "%s/snap/20261001T000000Z-zzzzzzzzzzzz.tar.gz" % P,
             "jsonl-archive/snap/20200101T000000Z-%012x.tar.gz" % 1, "%s/snap/20200101T000000Z-%012x.tar.gz.bak" % (P, 1), "snap/20200101T000000Z-%012x.tar.gz" % 1]
check("retention: chave fora do formato exato (latest, _probe, notes, sha inválido, outro prefixo, sufixo extra) NUNCA é apagada",
      retention(keys_for(hourly) + untouched) == dels)
check("retention: piso — com poucos snapshots velhos nada é apagado abaixo do piso",
      retention(keys_for([stem(500 + i, i + 1) for i in range(5)])) == [])
old6 = [stem(500 + i, i + 1) for i in range(10)]
d6 = retention(keys_for(old6), keep_daily_days=0)
check("retention: piso de 6 mantém os 6 mais novos mesmo fora de qualquer janela", len(d6) == 8 and all("%s.tar.gz" % old6[i] not in " ".join(d6) for i in range(6)), str(d6))
prot = old6[9]
check("retention: o snapshot protegido (apontado por latest.json) não é apagado",
      not any(prot in k for k in retention(keys_for(old6), keep_daily_days=0, protect=prot)))
young_half = stem(1, 0xabc)
old_half = stem(30 * 24, 0xdef)
d = retention(keys_for(hourly[:8]) + ["%s/snap/%s.tar.gz" % (P, young_half), "%s/snap/%s.tar.gz" % (P, old_half)])
check("retention: tar.gz sem manifest com menos de 2 h (upload em curso) fica; o antigo é lixo e sai",
      "%s/snap/%s.tar.gz" % (P, young_half) not in d and "%s/snap/%s.tar.gz" % (P, old_half) in d, str(d))
broken_new = [stem(300 + i, 0x500 + i) for i in range(6)]       # 6 uploads quebrados, mais novos que os bons
good_old = [stem(600 + i, 0x600 + i) for i in range(3)]         # 3 bons, fora de qualquer janela
d = retention(keys_for(good_old) + ["%s/snap/%s.tar.gz" % (P, s) for s in broken_new], keep_daily_days=0)
check("retention: uploads quebrados em sequência não ocupam o piso — os snapshots completos continuam salvos",
      not any(g in k for k in d for g in good_old) and all("%s.tar.gz" % b in " ".join(d) for b in broken_new), str(d))
check("retention: lista vazia ou sem chave de snapshot => nada a apagar", retention([]) == [] and retention(untouched) == [])
rc, so, _ = run("retention", "--prefix", P, "--now", str(int(NOW.timestamp())), stdin="\n".join(keys_for(hourly)).encode())
check("retention (CLI): mesma saída que a função", rc == 0 and so.split() == dels)
# Forma exata de snapshot, mas a data não existe (mês 13): UMA chave dessas não pode parar a retenção de todas as outras
# (antes: ValueError, nenhuma apagada, só um traceback no log), nunca é apagada, e é REPORTADA — não some calada.
junk_stem = "20261399T999999Z-%012x" % 7
junk_keys = keys_for([junk_stem])
skipped = []
try:
    d_junk = retention(keys_for(hourly) + junk_keys, skipped=skipped)
except ValueError as e:
    d_junk = "ValueError: %s" % e
check("retention: chave de data impossível não derruba a retenção das outras (mesma saída que sem ela)", d_junk == dels, str(d_junk)[:120])
check("retention: a chave de data impossível NUNCA é apagada e vem em `skipped`, par inteiro",
      isinstance(d_junk, list) and not any(junk_stem in k for k in d_junk) and sorted(skipped) == sorted(junk_keys), str(skipped))
rc, so, se = run("retention", "--prefix", P, "--now", str(int(NOW.timestamp())), stdin="\n".join(keys_for(hourly) + junk_keys).encode())
check("retention (CLI): rc 0, mesma saída, e o stderr NOMEIA a chave ignorada (não é silêncio)",
      rc == 0 and so.split() == dels and junk_stem in se, "rc=%s stderr=%s" % (rc, se[-160:]))

# Upload quebrado (tar.gz sem manifest) que é o PRIMEIRO carimbo do dia: ele não pode ser a âncora do "primeiro do dia", senão
# nenhum snapshot COMPLETO daquele dia fica (o órfão nunca pode ser mantido, e o dia some da faixa de 2-14 dias).
orphan_first = "20261011T000000Z-%012x" % 0xa01                                   # D-5, 00h: órfão, já passou da carência de 2 h
day_complete = ["20261011T%02d0000Z-%012x" % (h, 0xb00 + h) for h in (1, 2, 3)]  # D-5, 01h/02h/03h: completos
recent_ok = [stem(h, 0xc00 + h) for h in range(10)]                                # 10 recentes completos: o piso de 6 já está coberto
with_orphan = keys_for(day_complete + recent_ok) + ["%s/snap/%s.tar.gz" % (P, orphan_first)]
d_orphan = retention(with_orphan)
d_ctrl = retention(keys_for(day_complete + recent_ok))
kept_day = [s for s in day_complete if "%s/snap/%s.tar.gz" % (P, s) not in d_orphan]
check("retention: controle sem o órfão — exatamente 1 snapshot completo do dia D-5 fica (o primeiro)",
      [s for s in day_complete if "%s/snap/%s.tar.gz" % (P, s) not in d_ctrl] == [day_complete[0]], str(d_ctrl))
check("retention: órfão como 1º carimbo do dia NÃO é âncora — o 1º snapshot COMPLETO do dia continua salvo (mesmo resultado do controle)",
      kept_day == [day_complete[0]], "completos mantidos de D-5: %s" % kept_day)
check("retention: o órfão velho continua sendo apagado (lixo), só que sem levar os completos junto",
      "%s/snap/%s.tar.gz" % (P, orphan_first) in d_orphan)

# Botões da retenção: é o único caminho que APAGA do backup de DR. Valor que afina a política abaixo do piso (--floor -1 mantém
# todos MENOS o mais novo; janela negativa nada protege) é recusado no argparse (rc 2, nada na saída), nunca aplicado.
stdin_keys = "\n".join(keys_for(hourly)).encode()
base_args = ["retention", "--prefix", P, "--now", str(int(NOW.timestamp()))]
bad_knobs = {"--floor -1": ["--floor", "-1"], "--floor 0": ["--floor", "0"], "--floor x": ["--floor", "x"],
             "--keep-recent-h -1": ["--keep-recent-h", "-1"], "--keep-daily-days -1": ["--keep-daily-days", "-1"]}
got_knobs = {k: run(*(base_args + v), stdin=stdin_keys) for k, v in bad_knobs.items()}
check("retention (CLI): botão fora do limite (floor<1, janela<0, não-número) => rc 2 e NADA em stdout",
      all(r[0] == 2 and not r[1].strip() for r in got_knobs.values()), repr({k: (r[0], r[1][:40]) for k, r in got_knobs.items()}))
rc0, so0, _ = run(*(base_args + ["--keep-daily-days", "0", "--keep-recent-h", "0", "--floor", "1"]), stdin=stdin_keys)
check("retention (CLI): os limites exatos (janelas 0, piso 1) são aceitos", rc0 == 0 and so0.strip() != "")

print("=== RESULT: PASS=%d FAIL=%d ===" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
