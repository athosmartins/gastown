#!/usr/bin/env python3
"""jsonl_hourly.selftest.py (ga-c0939v) — testes do helper jsonl_hourly.py.

Contents
  Escopo · Como rodar · O que cada bloco prova

ESCOPO: hermético. Só tmpdir e subprocess do próprio helper; sem rede, sem bd, sem dolt, sem AWS.
COMO RODAR: python3 -I jsonl_hourly.selftest.py   (rc 0 = tudo passou; a última linha é `=== RESULT: PASS=n FAIL=n ===`)
O QUE PROVA:
  A. o parser incremental conta certo em QUALQUER tamanho de bloco (1 byte inclusive) e REJEITA todo dump truncado,
     com lixo, com vírgula sobrando ou não-UTF-8 — a varredura de truncamento cobre cada prefixo possível de um dump válido;
  B. build/inspect: só entram <db>/<tabela>.jsonl, o artefato é determinístico, lixo de export abortado fica de fora e
     tabela ilegível vira erro (nunca contagem parcial);
  C. manifest: broken quando falta tabela, banco obrigatório ou há erro de parse;
  C2. banco ignorado (--ignore-db): sai do artefato, é NOMEADO no manifest, e nunca vale para banco obrigatório;
  D. convert + reconcile: exclusões por desenho são contadas, e CADA divergência (label, dep, título, issue a mais ou a menos,
     manifest que não bate) derruba a reconciliação — o teste de que a prova de restore consegue reprovar. Comentários de
     conteúdo idêntico que o `bd import` funde (gastown: 14 de 443) são CONTADOS como exclusão, nunca escondidos, e a fusão
     não pode mascarar um comentário perdido ou trocado;
  E. retention: só toca chaves no formato exato, respeita piso, janela recente, primeiro do dia e o protegido.
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

# ── D. convert + reconcile ────────────────────────────────────────────────────────────
print("-- D. convert / reconcile")
with tempfile.TemporaryDirectory(prefix="jhst.") as T:
    dump = os.path.join(T, "dump")
    os.makedirs(os.path.join(dump, "hq"))
    issues = [
        {"id": "hq-1", "title": "um", "description": "d1", "status": "open", "priority": "1", "issue_type": "task",
         "created_at": "2026-05-16 13:03:54", "ephemeral": "0", "pinned": "1", "metadata": "{\"k\":\"v\"}", "weird_col": "zzz"},
        {"id": "hq-2", "title": "dois", "description": "", "status": "closed", "priority": "2", "issue_type": "bug",
         "closed_at": "2026-05-17 01:02:03", "metadata": "{}"},
        {"id": "hq-3", "title": "lápide", "status": "tombstone", "priority": "2", "issue_type": "task"},
    ]
    labels = [{"issue_id": "hq-1", "label": "a"}, {"issue_id": "hq-1", "label": "b"}, {"issue_id": "hq-3", "label": "so-da-lapide"}]
    deps = [
        {"issue_id": "hq-1", "depends_on_issue_id": "hq-2", "type": "blocks", "created_at": "2026-05-16 14:00:00"},
        {"issue_id": "hq-2", "depends_on_issue_id": "", "depends_on_external": "external:wa:wa-euo", "type": "related"},
        {"issue_id": "hq-2", "depends_on_issue_id": "hq-zpix6", "type": "blocks"},           # alvo fora do store => dangling
        {"issue_id": "hq-9", "depends_on_issue_id": "hq-1", "type": "blocks"},               # filho de issue que não existe => órfã
    ]
    comments = [{"id": "c1", "issue_id": "hq-1", "author": "x", "text": "oi", "created_at": "2026-05-16 15:00:00"},
                {"id": "c2", "issue_id": "hq-9", "author": "x", "text": "órfão", "created_at": "2026-05-16 15:00:00"}]
    for name, rows_ in (("issues", issues), ("labels", labels), ("dependencies", deps), ("comments", comments),
                        ("config", [{"key": "issue_prefix", "value": "hq"}]), ("metadata", [])):
        open(os.path.join(dump, "hq", name + ".jsonl"), "w").write(table(rows_))
    imp = os.path.join(T, "imp.jsonl")
    rc, so, se = run("convert", "--dump", dump, "--db", "hq", "--out", imp)
    st = json.loads(so)
    check("convert: rc 0", rc == 0, so + se)
    check("convert: contagens das tabelas e do que foi escrito",
          st["table_rows"] == {"issues": 3, "labels": 3, "dependencies": 4, "comments": 2}
          and st["written"] == {"issues": 2, "labels": 2, "dependencies": 2, "comments": 1}, so)
    check("convert: tombstone, órfãos e dependência com alvo fora do store são CONTADOS",
          st["tombstones_skipped"] == 1 and st["orphans"] == {"labels": 1, "dependencies": 1, "comments": 1}
          and st["dangling_dependencies"] == 1, so)
    check("convert: coluna desconhecida com valor aparece em unmapped_columns; prefixo vai para config",
          st["unmapped_columns"] == {"weird_col": 1} and st["config"] == {"issue_prefix": "hq"}, so)
    recs = {r["id"]: r for r in map(json.loads, open(imp))}
    check("convert: tipos (priority int, pinned bool, data RFC3339, metadata objeto)",
          recs["hq-1"]["priority"] == 1 and recs["hq-1"]["pinned"] is True and recs["hq-1"]["created_at"] == "2026-05-16T13:03:54Z"
          and recs["hq-1"]["metadata"] == {"k": "v"} and "ephemeral" not in recs["hq-1"], json.dumps(recs["hq-1"]))
    check("convert: dep externa mantém o alvo external:… (coluna depends_on_external)",
          any(d["depends_on_id"] == "external:wa:wa-euo" for d in recs["hq-2"]["dependencies"]), json.dumps(recs["hq-2"]))
    check("convert: dep dangling e tombstone não são escritos", all(d["depends_on_id"] != "hq-zpix6" for d in recs["hq-2"]["dependencies"]) and "hq-3" not in recs)

    stats_f = os.path.join(T, "stats.json")
    open(stats_f, "w").write(so)
    manifest_ok = os.path.join(T, "man.json")
    json.dump({"databases": {"hq": {"issues": 3, "labels": 3, "dependencies": 4, "comments": 2}}}, open(manifest_ok, "w"))

    def export_copy(mutate=None):
        out = os.path.join(T, "exp.jsonl")
        lines = [json.loads(l) for l in open(imp)]
        if mutate:
            lines = mutate(lines)
        with open(out, "w") as f:
            for r in lines:
                f.write(json.dumps(r) + "\n")
        if mutate:  # mutação que não muda nada não prova nada: o teste tem que enxergar isso
            check("  (mutação %s realmente altera o export)" % mutate.__name__, open(out).read() != open(imp).read())
        return out

    def rec(manifest, exp):
        rc_, so_, _ = run("reconcile", "--db", "hq", "--manifest", manifest, "--convert-stats", stats_f, "--imported", imp, "--exported", exp)
        return rc_, json.loads(so_)

    rc, rep = rec(manifest_ok, export_copy())
    check("reconcile: export idêntico ao import => ok, com as exclusões por desenho no relatório",
          rc == 0 and rep["verdict"] == "ok" and rep["exclusions"]["tombstones"] == 1 and rep["exclusions"]["dangling_dependencies"] == 1, json.dumps(rep))

    def drop_label(ls):
        ls[0]["labels"] = ls[0]["labels"][:1]
        return ls

    def retitle(ls):
        ls[1]["title"] = "outro"
        return ls

    def drop_issue(ls):
        return ls[:1]

    def add_issue(ls):
        return ls + [{"_type": "issue", "id": "hq-77", "title": "fantasma", "status": "open"}]

    def drop_dep(ls):
        ls[0].pop("dependencies")
        return ls

    def empty_ext_target(ls):
        for d in ls[1]["dependencies"]:
            if d["depends_on_id"].startswith("external:"):
                d["depends_on_id"] = ""
        return ls

    def drop_comment(ls):
        ls[0].pop("comments", None)
        return ls

    def chg_desc(ls):
        ls[0]["description"] = "adulterada"
        return ls

    def chg_status(ls):
        ls[0]["status"] = "closed"
        return ls

    for name, fn in (("label a menos", drop_label), ("título diferente", retitle), ("issue a menos", drop_issue),
                     ("issue a mais", add_issue), ("dependência a menos", drop_dep),
                     ("alvo externo vazio (a regressão dos 202 external:)", empty_ext_target),
                     ("comentário a menos", drop_comment), ("descrição adulterada", chg_desc), ("status diferente", chg_status)):
        rc, rep = rec(manifest_ok, export_copy(fn))
        check("reconcile reprova: %s" % name, rc == 1 and rep["verdict"] == "fail" and rep["problems"], json.dumps(rep)[:300])

    rc, rep = rec(manifest_ok, export_copy(drop_label))
    check("reconcile: label a menos é apontada como 'labels do dump não voltaram' (a classe do erro, não só a contagem)",
          any("1 labels do dump não voltaram" in p for p in rep["problems"]), json.dumps(rep)[:300])
    rc, rep = rec(manifest_ok, export_copy(drop_comment))
    check("reconcile: comentário a menos é apontado como 'comments do dump não voltaram'",
          any("1 comments do dump não voltaram" in p for p in rep["problems"]), json.dumps(rep)[:300])

    bad_man = os.path.join(T, "man-bad.json")
    json.dump({"databases": {"hq": {"issues": 4, "labels": 3, "dependencies": 4, "comments": 2}}}, open(bad_man, "w"))
    rc, rep = rec(bad_man, export_copy())
    check("reconcile reprova: arquivo do dump não bate com o manifest (issues 4 vs 3)", rc == 1 and any("manifest" in p for p in rep["problems"]), json.dumps(rep)[:300])
    nodb = os.path.join(T, "man-nodb.json")
    json.dump({"databases": {"outro": {}}}, open(nodb, "w"))
    rc_, so_, _ = run("reconcile", "--db", "hq", "--manifest", nodb, "--convert-stats", stats_f, "--imported", imp, "--exported", export_copy())
    check("reconcile reprova: banco ausente do manifest", rc_ == 1 and json.loads(so_)["verdict"] == "fail", so_)

    # comentários de conteúdo idêntico e ids diferentes: o `bd import` guarda UM (gastown real: 443 escritos, 429 voltaram)
    dump3 = os.path.join(T, "dump3")
    os.makedirs(os.path.join(dump3, "hq"))
    twin = {"issue_id": "hq-1", "author": "x", "text": "igual", "created_at": "2026-05-16 15:00:00"}
    for name, rows_ in (("issues", [{"id": "hq-1", "title": "um", "status": "open", "priority": "1", "issue_type": "task"}]),
                        ("labels", []), ("dependencies", []),
                        ("comments", [dict(twin, id="c1"), dict(twin, id="c2"),
                                      {"id": "c3", "issue_id": "hq-1", "author": "y", "text": "único", "created_at": "2026-05-16 16:00:00"}]),
                        ("config", [{"key": "issue_prefix", "value": "hq"}]), ("metadata", [])):
        open(os.path.join(dump3, "hq", name + ".jsonl"), "w").write(table(rows_))
    imp3 = os.path.join(T, "imp3.jsonl")
    rc, so3, se3 = run("convert", "--dump", dump3, "--db", "hq", "--out", imp3)
    stats3 = os.path.join(T, "stats3.json")
    open(stats3, "w").write(so3)
    check("convert: gêmeos são escritos os dois (o conversor não decide fundir nada)", rc == 0 and json.loads(so3)["written"]["comments"] == 3, so3 + se3)
    man3 = os.path.join(T, "man3.json")
    json.dump({"databases": {"hq": {"issues": 1, "labels": 0, "dependencies": 0, "comments": 3}}}, open(man3, "w"))

    def exp3(mutate):
        out = os.path.join(T, "exp3.jsonl")
        lines = [json.loads(l) for l in open(imp3)]
        mutate(lines)
        with open(out, "w") as f:
            for r in lines:
                f.write(json.dumps(r) + "\n")
        return out

    def rec3(mutate):
        rc_, so_, _ = run("reconcile", "--db", "hq", "--manifest", man3, "--convert-stats", stats3, "--imported", imp3, "--exported", exp3(mutate))
        return rc_, json.loads(so_)

    def by_text(ls, text):
        return [c for c in ls[0]["comments"] if c["text"] == text]

    def collapse_twins(ls):
        ls[0]["comments"] = [c for c in ls[0]["comments"] if c["id"] != "c2"]

    rc, rep = rec3(collapse_twins)
    ctab = {r["table"]: r for r in rep["table"]}["comments"]
    check("reconcile: gêmeos fundidos pelo import => ok, a fusão (1) aparece em exclusions e na tabela",
          rc == 0 and rep["verdict"] == "ok" and rep["exclusions"]["duplicate_comments_collapsed"] == 1
          and ctab["manifest"] == 3 and ctab["excluded_by_design"] == 1 and ctab["expected"] == 2 and ctab["restored"] == 2 and ctab["diff"] == 0,
          json.dumps(rep)[:400])
    rc, rep = rec3(lambda ls: None)
    check("reconcile: gêmeos mantidos pelo import (versão que não funde) => ok, fusão 0",
          rc == 0 and rep["verdict"] == "ok" and rep["exclusions"]["duplicate_comments_collapsed"] == 0, json.dumps(rep)[:300])

    def lose_both_twins(ls):
        ls[0]["comments"] = by_text(ls, "único")

    rc, rep = rec3(lose_both_twins)
    check("reconcile reprova: os DOIS gêmeos sumiram (a fusão deixa um, nunca zero)",
          rc == 1 and any("1 comments do dump não voltaram" in p for p in rep["problems"]), json.dumps(rep)[:300])

    def collapse_and_swap(ls):  # a contagem fecha (2 = 3 − 1 fundido), mas o comentário único foi trocado por outro inventado
        ls[0]["comments"] = by_text(ls, "igual")[:1] + [{"id": "zz", "author": "y", "text": "inventado", "created_at": "2026-05-16T16:00:00Z"}]

    rc, rep = rec3(collapse_and_swap)
    check("reconcile reprova: fusão de gêmeos não mascara comentário perdido + comentário inventado de mesma contagem",
          rc == 1 and any("do dump não voltaram" in p for p in rep["problems"]) and any("apareceram" in p for p in rep["problems"]), json.dumps(rep)[:300])

    def triple(ls):
        ls[0]["comments"] = ls[0]["comments"] + [dict(by_text(ls, "igual")[0], id="c9")]

    rc, rep = rec3(triple)
    check("reconcile reprova: o import devolveu o gêmeo MAIS vezes do que foi escrito", rc == 1 and rep["verdict"] == "fail", json.dumps(rep)[:300])

    # convert fail-closed
    def convert_with(patch):
        d2 = os.path.join(T, "dump2")
        subprocess.run(["rm", "-rf", d2])
        os.makedirs(os.path.join(d2, "hq"))
        for name in ("issues", "labels", "dependencies", "comments", "config", "metadata"):
            body = open(os.path.join(dump, "hq", name + ".jsonl")).read()
            if name in patch:
                body = patch[name]
            if body is not None:
                open(os.path.join(d2, "hq", name + ".jsonl"), "w").write(body)
        return run("convert", "--dump", d2, "--db", "hq", "--out", os.path.join(T, "o2.jsonl"))

    rc, so, _ = convert_with({"comments": None})
    check("convert: tabela ausente => rc 1 (não converte pela metade)", rc == 1 and "error" in json.loads(so), so)
    rc, so, _ = convert_with({"issues": '{"rows":[{"id":"hq-1","title":"t"}'})
    check("convert: issues truncado => rc 1", rc == 1 and "error" in json.loads(so), so)
    rc, so, _ = convert_with({"dependencies": table([{"issue_id": "hq-1", "depends_on_issue_id": "", "depends_on_external": "", "type": "blocks"}])})
    check("convert: dependência sem alvo nenhum => rc 1", rc == 1 and "error" in json.loads(so), so)

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

print("=== RESULT: PASS=%d FAIL=%d ===" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
