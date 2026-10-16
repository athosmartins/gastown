#!/usr/bin/env python3
"""jsonl_hourly.selftest.py (ga-c0939v.1) — testes do helper jsonl_hourly.py.

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
  E. retention: só toca chaves no formato exato, respeita piso, janela recente, primeiro do dia e o protegido; uma chave na
     forma exata mas com data impossível (mês 13) é ignorada, reportada e nunca apagada, sem parar a retenção das outras.
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

print("=== RESULT: PASS=%d FAIL=%d ===" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
