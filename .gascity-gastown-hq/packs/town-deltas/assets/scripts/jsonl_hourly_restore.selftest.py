#!/usr/bin/env python3
"""jsonl_hourly_restore.selftest.py (ga-c0939v.3) — testes do lado RESTORE do dump JSONL (jsonl_hourly_restore.py).

Contents
  Escopo · Como rodar · O que cada bloco prova

ESCOPO: hermético. Só tmpdir, subprocess dos próprios helpers e (bloco G) o fonte do restore executado em processo com um defeito
  injetado; sem rede, sem bd, sem dolt, sem AWS. O `bd import`/`bd export` reais não entram aqui (ga-c0939v.4): o "export" destes
  testes é o próprio import, adulterado de propósito.
COMO RODAR: python3 -I jsonl_hourly_restore.selftest.py   (rc 0 = tudo passou; a última linha é `=== RESULT: PASS=n FAIL=n ===`)
O QUE PROVA (os blocos seguem o nome A-E do commit 629fdabf1; A-C/E são do upload, em jsonl_hourly.selftest.py):
  D.  convert + reconcile: exclusões por desenho (tombstone, órfãos, aresta sem alvo) são contadas, e CADA divergência (label,
      dependência, comentário, título, descrição, status, prioridade, tipo, issue a mais ou a menos, manifest que não bate,
      valor que o conversor não conseguiu carregar) derruba a reconciliação — inclusive as de MESMA contagem. Comentários de
      conteúdo idêntico que o `bd import` funde (gastown: 14 de 443) são CONTADOS como exclusão, nunca escondidos, e a fusão
      não pode mascarar um comentário perdido ou trocado. Convert com dump ruim sai rc 1 e não deixa arquivo para trás;
  D2. entrada da prova ilegível (stats, manifest, import, export fora da forma) dá verdict fail, rc 1, stderr vazio — nunca ok;
  F.  extract: bytes+sha256 batem com o build; tabela faltando, membro repetido, gzip cortado e sobra de extração anterior
      não deixam arquivo; e a cadeia build -> inspect -> manifest -> extract -> convert -> reconcile fecha ponta a ponta;
  G.  a prova CONSEGUE reprovar: 6 reconcile defeituosos (ignora label/dependência/comentário perdido, não compara título,
      aceita issue a mais, ignora valor não carregado) são rodados contra os MESMOS casos e cada um deixa passar algum.
"""
import argparse
import contextlib
import gzip
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "jsonl_hourly_restore.py")
UPLOAD = os.path.join(HERE, "jsonl_hourly.py")
sys.path.insert(0, HERE)
import jsonl_hourly_restore as jhr  # noqa: E402

PASS = FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  PASS: " + name)
    else:
        FAIL += 1
        print("  FAIL: %s %s" % (name, detail))


def run(*args, helper=HELPER):
    p = subprocess.run([sys.executable, "-I", helper] + list(args), capture_output=True)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def table(rows_):
    return json.dumps({"rows": rows_}, separators=(",", ":")) if rows_ else "{}"


def put(path, text):
    with open(path, "w") as f:
        f.write(text)


def jlines(path):
    return [json.loads(l) for l in open(path)]


def put_lines(path, ls):
    put(path, "".join(json.dumps(r) + "\n" for r in ls))


def write_db(dump, db, **tables):
    os.makedirs(os.path.join(dump, db), exist_ok=True)
    for name in jhr.TABLES:
        put(os.path.join(dump, db, name + ".jsonl"), table(tables.get(name, [])))


def make_tar(members):
    bio = io.BytesIO()
    with tarfile.open(fileobj=bio, mode="w") as tf:
        for name, content in members:
            ti = tarfile.TarInfo(name=name)
            data = content.encode("utf-8")
            ti.size = len(data)
            tf.addfile(ti, io.BytesIO(data))
    return bio.getvalue()


def db_members(db, **tables):
    return [("%s/%s.jsonl" % (db, name), table(tables.get(name, []))) for name in jhr.TABLES]


print("=== jsonl_hourly_restore.selftest.py ===")

# ── D. convert + reconcile ────────────────────────────────────────────────────────────
print("-- D. convert / reconcile")
ISSUES = [
    {"id": "hq-1", "title": "um", "description": "d1", "status": "open", "priority": "1", "issue_type": "task",
     "created_at": "2026-05-16 13:03:54", "ephemeral": "0", "pinned": "1", "metadata": "{\"k\":\"v\"}", "weird_col": "zzz"},
    {"id": "hq-2", "title": "dois", "description": "", "status": "closed", "priority": "2", "issue_type": "bug",
     "closed_at": "2026-05-17 01:02:03", "metadata": "{}"},
    {"id": "hq-3", "title": "lápide", "status": "tombstone", "priority": "2", "issue_type": "task"},
]
LABELS = [{"issue_id": "hq-1", "label": "a"}, {"issue_id": "hq-1", "label": "b"}, {"issue_id": "hq-3", "label": "so-da-lapide"}]
DEPS = [
    {"issue_id": "hq-1", "depends_on_issue_id": "hq-2", "type": "blocks", "created_at": "2026-05-16 14:00:00"},
    {"issue_id": "hq-2", "depends_on_issue_id": "", "depends_on_external": "external:wa:wa-euo", "type": "related"},
    {"issue_id": "hq-2", "depends_on_issue_id": "hq-zpix6", "type": "blocks"},           # alvo fora do store => dangling
    {"issue_id": "hq-9", "depends_on_issue_id": "hq-1", "type": "blocks"},               # filho de issue que não existe => órfã
]
COMMENTS = [{"id": "c1", "issue_id": "hq-1", "author": "x", "text": "oi", "created_at": "2026-05-16 15:00:00"},
            {"id": "c2", "issue_id": "hq-9", "author": "x", "text": "órfão", "created_at": "2026-05-16 15:00:00"}]
MAN_OK = {"databases": {"hq": {"issues": 3, "labels": 3, "dependencies": 4, "comments": 2}}}

with tempfile.TemporaryDirectory(prefix="jhrst.") as T:
    P = lambda *a: os.path.join(T, *a)  # noqa: E731
    write_db(P("dump"), "hq", issues=ISSUES, labels=LABELS, dependencies=DEPS, comments=COMMENTS,
             config=[{"key": "issue_prefix", "value": "hq"}])
    imp = P("imp.jsonl")
    rc, so, se = run("convert", "--dump", P("dump"), "--db", "hq", "--out", imp)
    st = json.loads(so)
    check("convert: rc 0 e nada de <out>.part sobrando", rc == 0 and not os.path.exists(imp + ".part"), so + se)
    check("convert: contagens das tabelas e do que foi escrito",
          st["table_rows"] == {"issues": 3, "labels": 3, "dependencies": 4, "comments": 2}
          and st["written"] == {"issues": 2, "labels": 2, "dependencies": 2, "comments": 1}, so)
    check("convert: tombstone, órfãos e dependência com alvo fora do store são CONTADOS",
          st["tombstones_skipped"] == 1 and st["orphans"] == {"labels": 1, "dependencies": 1, "comments": 1}
          and st["dangling_dependencies"] == 1 and st["db"] == "hq", so)
    check("convert: coluna desconhecida com valor aparece em unmapped_columns; prefixo vai para config; nenhum bad_values",
          st["unmapped_columns"] == {"weird_col": 1} and st["config"] == {"issue_prefix": "hq"}
          and not any(st["bad_values"].values()), so)
    recs = {r["id"]: r for r in jlines(imp)}
    check("convert: tipos (priority int, pinned bool, data RFC3339, metadata objeto)",
          recs["hq-1"]["priority"] == 1 and recs["hq-1"]["pinned"] is True and recs["hq-1"]["created_at"] == "2026-05-16T13:03:54Z"
          and recs["hq-1"]["metadata"] == {"k": "v"} and "ephemeral" not in recs["hq-1"], json.dumps(recs["hq-1"]))
    check("convert: dep externa mantém o alvo external:… (coluna depends_on_external)",
          any(d["depends_on_id"] == "external:wa:wa-euo" for d in recs["hq-2"]["dependencies"]), json.dumps(recs["hq-2"]))
    check("convert: dep dangling e tombstone não são escritos", all(d["depends_on_id"] != "hq-zpix6" for d in recs["hq-2"]["dependencies"]) and "hq-3" not in recs)
    put(P("stats.json"), so)
    json.dump(MAN_OK, open(P("man.json"), "w"))

    # valor que o conversor não consegue carregar: contado em bad_values (e a prova reprova mais abaixo)
    write_db(P("dump-bad"), "hq", issues=[{"id": "hq-1", "title": "t", "status": "open", "priority": "abc", "issue_type": "task",
                                           "created_at": "ontem", "metadata": "[1]", "estimated_minutes": "x"}])
    rc, so_bad, _ = run("convert", "--dump", P("dump-bad"), "--db", "hq", "--out", P("imp-bad.jsonl"))
    bv = json.loads(so_bad)["bad_values"]
    check("convert: prioridade, estimativa, metadata não-objeto e data fora do formato são CONTADOS em bad_values",
          rc == 0 and bv == {"bad_priority": 1, "bad_estimated_minutes": 1, "bad_metadata": 1, "bad_timestamp": 1}, so_bad)
    put(P("stats-bad.json"), so_bad)
    json.dump({"databases": {"hq": {"issues": 1, "labels": 0, "dependencies": 0, "comments": 0}}}, open(P("man-bad.json"), "w"))

    def rec(manifest, exp, stats=P("stats.json"), imported=imp, db="hq"):
        args = ["reconcile", "--db", db, "--convert-stats", stats, "--imported", imported, "--exported", exp]
        if manifest:
            args += ["--manifest", manifest]
        rc_, so_, se_ = run(*args)
        return rc_, json.loads(so_), se_

    # ── os casos que TÊM de reprovar: o mesmo conjunto roda no bloco G contra reconcile defeituoso ──
    def e_drop_label(ls): ls[0]["labels"] = ls[0]["labels"][:1]
    def e_swap_label(ls): ls[0]["labels"] = ["a", "zzz"]
    def e_retitle(ls): ls[1]["title"] = "outro"
    def e_drop_issue(ls): del ls[1]
    def e_add_issue(ls): ls.append({"_type": "issue", "id": "hq-77", "title": "fantasma", "status": "open"})
    def e_drop_dep(ls): ls[0].pop("dependencies")
    def e_retype_dep(ls): ls[0]["dependencies"][0]["type"] = "related"
    def e_empty_ext(ls): [d.update(depends_on_id="") for d in ls[1]["dependencies"] if d["depends_on_id"].startswith("external:")]
    def e_drop_comment(ls): ls[0].pop("comments")
    def e_swap_comment(ls): ls[0]["comments"][0]["text"] = "outro texto"
    def e_desc(ls): ls[0]["description"] = "adulterada"
    def e_status(ls): ls[0]["status"] = "closed"
    def e_prio(ls): ls[0]["priority"] = 3
    def e_type(ls): ls[1]["issue_type"] = "feature"

    CASES = []  # (nome, manifest, stats, import, export)
    for i, (name, fn) in enumerate((("label a menos", e_drop_label), ("label trocada (mesma contagem)", e_swap_label),
                                    ("título diferente", e_retitle), ("issue a menos", e_drop_issue), ("issue a mais", e_add_issue),
                                    ("dependência a menos", e_drop_dep), ("dependência com outro tipo (mesma contagem)", e_retype_dep),
                                    ("alvo externo vazio (a regressão dos 202 external:)", e_empty_ext),
                                    ("comentário a menos", e_drop_comment), ("comentário com outro texto (mesma contagem)", e_swap_comment),
                                    ("descrição adulterada", e_desc), ("status diferente", e_status), ("prioridade diferente", e_prio),
                                    ("tipo diferente", e_type))):
        ls = jlines(imp)
        fn(ls)
        put_lines(P("exp-%d.jsonl" % i), ls)
        check("  (mutação %s realmente altera o export)" % name, open(P("exp-%d.jsonl" % i)).read() != open(imp).read())
        CASES.append((name, P("man.json"), P("stats.json"), imp, P("exp-%d.jsonl" % i)))
    json.dump({"databases": {"hq": {"issues": 4, "labels": 3, "dependencies": 4, "comments": 2}}}, open(P("man-4.json"), "w"))
    CASES.append(("arquivo do dump não bate com o manifest (issues 4 vs 3)", P("man-4.json"), P("stats.json"), imp, imp))
    put(P("exp-bad.jsonl"), open(P("imp-bad.jsonl")).read())
    CASES.append(("valor do dump que o conversor não carregou (export igual ao import)", P("man-bad.json"), P("stats-bad.json"), P("imp-bad.jsonl"), P("exp-bad.jsonl")))

    rc, rp, se = rec(P("man.json"), imp)
    check("reconcile: export idêntico ao import => ok, com as exclusões por desenho no relatório",
          rc == 0 and rp["verdict"] == "ok" and rp["exclusions"]["tombstones"] == 1 and rp["exclusions"]["dangling_dependencies"] == 1
          and rp["manifest_checked"] is True and not rp["problems"], json.dumps(rp))
    rc, rp, se = rec(None, imp)
    check("reconcile: sem --manifest a conta roda e o relatório diz manifest_checked=false", rc == 0 and rp["manifest_checked"] is False, json.dumps(rp))
    probs = {}
    for name, man, stats, imported, exp in CASES:
        rc, rp, se = rec(man, exp, stats, imported)
        probs[name] = " | ".join(rp["problems"])
        check("reconcile reprova: %s" % name, rc == 1 and rp["verdict"] == "fail" and rp["problems"], json.dumps(rp)[:300])
    check("reconcile: label a menos é apontada como 'labels do dump não voltaram' (a classe do erro, não só a contagem)",
          "1 labels do dump não voltaram" in probs["label a menos"], probs["label a menos"])
    check("reconcile: comentário a menos é apontado como 'comments do dump não voltaram'", "1 comments do dump não voltaram" in probs["comentário a menos"])
    check("reconcile: o valor não carregado é NOMEADO (bad_priority…), não só 'fail'", "bad_priority" in probs["valor do dump que o conversor não carregou (export igual ao import)"])
    rc, rp, se = rec(P("man-4.json"), imp)
    check("reconcile: o manifest que não bate é dito 'artefato difere do manifest em issues'", any("difere do manifest em issues" in p for p in rp["problems"]))

    # comentários de conteúdo idêntico e ids diferentes: o `bd import` guarda UM (gastown real: 443 escritos, 429 voltaram)
    twin = {"issue_id": "hq-1", "author": "x", "text": "igual", "created_at": "2026-05-16 15:00:00"}
    write_db(P("dump3"), "hq", issues=[{"id": "hq-1", "title": "um", "status": "open", "priority": "1", "issue_type": "task"}],
             comments=[dict(twin, id="c1"), dict(twin, id="c2"),
                       {"id": "c3", "issue_id": "hq-1", "author": "y", "text": "único", "created_at": "2026-05-16 16:00:00"}],
             config=[{"key": "issue_prefix", "value": "hq"}])
    rc, so3, se3 = run("convert", "--dump", P("dump3"), "--db", "hq", "--out", P("imp3.jsonl"))
    check("convert: gêmeos são escritos os dois (o conversor não decide fundir nada)", rc == 0 and json.loads(so3)["written"]["comments"] == 3, so3 + se3)
    put(P("stats3.json"), so3)
    json.dump({"databases": {"hq": {"issues": 1, "labels": 0, "dependencies": 0, "comments": 3}}}, open(P("man3.json"), "w"))

    def rec3(mutate):
        ls = jlines(P("imp3.jsonl"))
        mutate(ls)
        put_lines(P("exp3.jsonl"), ls)
        rc_, rp_, _ = rec(P("man3.json"), P("exp3.jsonl"), P("stats3.json"), P("imp3.jsonl"))
        return rc_, rp_

    def by_text(ls, text):
        return [c for c in ls[0]["comments"] if c["text"] == text]

    rc, rp = rec3(lambda ls: ls[0].update(comments=[c for c in ls[0]["comments"] if c["id"] != "c2"]))
    ctab = {r["table"]: r for r in rp["table"]}["comments"]
    check("reconcile: gêmeos fundidos pelo import => ok, a fusão (1) aparece em exclusions e na tabela",
          rc == 0 and rp["verdict"] == "ok" and rp["exclusions"]["duplicate_comments_collapsed"] == 1
          and ctab["manifest"] == 3 and ctab["excluded_by_design"] == 1 and ctab["expected"] == 2 and ctab["restored"] == 2 and ctab["diff"] == 0,
          json.dumps(rp)[:400])
    rc, rp = rec3(lambda ls: None)
    check("reconcile: gêmeos mantidos pelo import (versão que não funde) => ok, fusão 0",
          rc == 0 and rp["verdict"] == "ok" and rp["exclusions"]["duplicate_comments_collapsed"] == 0, json.dumps(rp)[:300])
    rc, rp = rec3(lambda ls: ls[0].update(comments=by_text(ls, "único")))
    check("reconcile reprova: os DOIS gêmeos sumiram (a fusão deixa um, nunca zero)",
          rc == 1 and any("1 comments do dump não voltaram" in p for p in rp["problems"]), json.dumps(rp)[:300])
    rc, rp = rec3(lambda ls: ls[0].update(comments=by_text(ls, "igual")[:1] + [{"id": "zz", "author": "y", "text": "inventado", "created_at": "2026-05-16T16:00:00Z"}]))
    check("reconcile reprova: fusão de gêmeos não mascara comentário perdido + comentário inventado de mesma contagem",
          rc == 1 and any("do dump não voltaram" in p for p in rp["problems"]) and any("apareceram" in p for p in rp["problems"]), json.dumps(rp)[:300])
    rc, rp = rec3(lambda ls: ls[0].update(comments=ls[0]["comments"] + [dict(by_text(ls, "igual")[0], id="c9")]))
    check("reconcile reprova: o import devolveu o gêmeo MAIS vezes do que foi escrito", rc == 1 and rp["verdict"] == "fail", json.dumps(rp)[:300])

    # convert fail-closed: dump ruim => rc 1, nada de <out> nem <out>.part (mesmo que existisse um <out> de execução anterior)
    def convert_with(patch, name="o2.jsonl"):
        d2 = P("dump2")
        os.makedirs(os.path.join(d2, "hq"), exist_ok=True)
        for t in jhr.TABLES:
            body = open(P("dump", "hq", t + ".jsonl")).read()
            body = patch.get(t, body)
            if body is None:
                if os.path.exists(os.path.join(d2, "hq", t + ".jsonl")):
                    os.unlink(os.path.join(d2, "hq", t + ".jsonl"))
            else:
                put(os.path.join(d2, "hq", t + ".jsonl"), body)
        put(P(name), "velho\n")
        r = run("convert", "--dump", d2, "--db", "hq", "--out", P(name))
        return r, os.path.exists(P(name)) or os.path.exists(P(name) + ".part")

    # coluna NOT NULL do bd AUSENTE de uma linha = dump com outra forma (desconhecido): erro, nunca "" nem "blocks". Uma por coluna.
    CM = {"id": "c1", "issue_id": "hq-1", "author": "x", "text": "oi", "created_at": "2026-05-16 15:00:00"}
    DP = {"issue_id": "hq-1", "depends_on_issue_id": "hq-2", "type": "blocks"}
    wo = lambda d, k: {a: b for a, b in d.items() if a != k}  # noqa: E731
    NOT_NULL = (tuple(("comentário sem %s (veio 'body')" % k, {"comments": table([dict(wo(CM, k), body="oi")])}) for k in ("id", "author", "text", "created_at"))
                + (("dependência sem type", {"dependencies": table([wo(DP, "type")])}),
                   ("dependência com type vazio", {"dependencies": table([dict(DP, type="")])}),
                   ("issue com id vazio", {"issues": table([{"id": ""}])}), ("config sem key", {"config": table([{"value": "hq"}])})))
    for label, patch in (("tabela ausente", {"comments": None}), ("issues truncado", {"issues": '{"rows":[{"id":"hq-1","title":"t"}'}),
                         ("dependência sem alvo nenhum", {"dependencies": table([{"issue_id": "hq-1", "depends_on_issue_id": "", "depends_on_external": "", "type": "blocks"}])}),
                         ("issue sem id", {"issues": table([{"title": "sem id"}])}),
                         ("id de issue repetido", {"issues": table([{"id": "hq-1"}, {"id": "hq-1"}])}),
                         ("label sem issue_id", {"labels": table([{"label": "a"}])})) + NOT_NULL:
        (rc, so, se), left = convert_with(patch)
        check("convert: %s => rc 1, JSON de erro, nenhum arquivo sobra" % label, rc == 1 and "error" in json.loads(so) and not left, so + se)

    # defesa em profundidade: o arquivo muda entre as duas passadas e o leitor levanta DumpError com o <out>.part já escrito
    real_rows, passes = jhr._rows, {"issues": 0}

    def flaky(base, name):
        yield from real_rows(base, name)
        if name == "issues":
            passes["issues"] += 1
            if passes["issues"] == 2:
                raise jhr.DumpError("simulado: o arquivo mudou entre as passadas")

    jhr._rows = flaky
    ns = type("A", (), {"dump": P("dump"), "db": "hq", "out": P("o3.jsonl")})()
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = jhr.cmd_convert(ns)
    jhr._rows = real_rows
    check("convert: erro na 2ª passada (com a saída parcial já em disco) => rc 1 e nem <out> nem <out>.part",
          rc == 1 and "error" in json.loads(buf.getvalue()) and not os.path.exists(P("o3.jsonl")) and not os.path.exists(P("o3.jsonl.part")), buf.getvalue())
    rc, so, se = run("convert", "--dump", P("dump"), "--db", "../hq", "--out", P("o4.jsonl"))
    check("convert: nome de banco fora do molde (../hq) => rc 2 (uso), nada gravado", rc == 2 and not os.path.exists(P("o4.jsonl")), so + se)

    # controle: coluna PRESENTE e vazia é valor (não é "desconhecido") e segue como veio; só a AUSENTE é erro
    two = [{"id": "hq-1", "title": "um", "status": "open", "priority": "1", "issue_type": "task"}, {"id": "hq-2", "title": "dois", "status": "open", "priority": "1", "issue_type": "task"}]
    write_db(P("dump-empty"), "hq", issues=two, comments=[dict(CM, author="", text="")], dependencies=[dict(DP, type="related", metadata="{}", thread_id="", id="d1")])
    rc, so, se = run("convert", "--dump", P("dump-empty"), "--db", "hq", "--out", P("imp-empty.jsonl"))
    r1 = {r["id"]: r for r in jlines(P("imp-empty.jsonl"))}["hq-1"]
    check("convert: autor e texto PRESENTES e vazios passam como vieram; type presente é mantido; metadata '{}' e thread_id '' não são coluna perdida",
          rc == 0 and r1["comments"][0]["author"] == "" and r1["comments"][0]["text"] == "" and r1["dependencies"][0]["type"] == "related"
          and json.loads(so)["unmapped_columns"] == {}, so + se)
    # coluna de OUTRA tabela que o conversor não leva ao import: nomeada "<tabela>.<coluna>" e contada (o docstring promete; antes só as issues eram auditadas)
    write_db(P("dump-um"), "hq", issues=two, labels=[{"issue_id": "hq-1", "label": "a", "cor": "azul"}], comments=[dict(CM, anexo="x.png")],
             dependencies=[dict(DP, type="waits-for", id="d1", metadata="{\"gate\":\"all-children\"}", thread_id="th-9")], config=[{"key": "k", "value": "v", "nota": "z"}])
    rc, so, se = run("convert", "--dump", P("dump-um"), "--db", "hq", "--out", P("imp-um.jsonl"))
    check("convert: coluna de labels/comments/dependencies/config que o conversor não leva é NOMEADA e contada (waits-for com metadata não some em silêncio)",
          rc == 0 and json.loads(so)["unmapped_columns"] == {"labels.cor": 1, "comments.anexo": 1, "dependencies.metadata": 1, "dependencies.thread_id": 1, "config.nota": 1}, so + se)

    # ── D2. entrada da prova ilegível: verdict fail, rc 1, stderr vazio ──
    print("-- D2. reconcile com entrada ilegível")
    put(P("empty.json"), "")
    put(P("notjson.json"), "{isto não é json")
    put(P("list.json"), "[1, 2]")
    json.dump({"databases": {"hq": {"issues": 3, "labels": "3", "dependencies": 4, "comments": 2}}}, open(P("man-str.json"), "w"))
    json.dump({"databases": {"hq": {"issues": 3, "labels": 3, "dependencies": 4}}}, open(P("man-lack.json"), "w"))
    json.dump({"outra": 1}, open(P("man-nodbs.json"), "w"))
    json.dump({"databases": {"outro": {}}}, open(P("man-nodb.json"), "w"))
    json.dump(dict(st, db="wa"), open(P("stats-wa.json"), "w"))
    json.dump({k: v for k, v in st.items() if k != "bad_values"}, open(P("stats-nobv.json"), "w"))
    json.dump({k: v for k, v in st.items() if k != "unmapped_columns"}, open(P("stats-noum.json"), "w"))
    put(P("exp-corrupt.jsonl"), open(imp).read() + "{isto não é json\n")
    put(P("exp-list.jsonl"), "[1]\n")
    put(P("exp-noid.jsonl"), '{"_type":"issue","title":"sem id"}\n')
    put(P("exp-empty.jsonl"), "")
    for fn_, (key, col) in (("exp-noauthor.jsonl", ("comments", "author")), ("exp-nodeptype.jsonl", ("dependencies", "type"))):
        ls_ = jlines(imp)
        ls_[0][key][0].pop(col)  # o export do bd trouxe as duas chaves em todas as linhas medidas (16/10, lexbh): sumiu = o bd perdeu o dado, não "vazio"
        put_lines(P(fn_), ls_)
    for label, args, *why in (
            ("stats vazio (0 bytes)", dict(stats=P("empty.json"))), ("stats que não é JSON", dict(stats=P("notjson.json"))),
            ("stats ausente", dict(stats=P("nao-existe.json"))), ("stats que é lista", dict(stats=P("list.json"))),
            ("stats sem bad_values", dict(stats=P("stats-nobv.json"))), ("stats sem unmapped_columns", dict(stats=P("stats-noum.json"))),
            ("stats de OUTRO banco", dict(stats=P("stats-wa.json"))),
            ("manifest vazio", dict(manifest=P("empty.json"))), ("manifest sem 'databases'", dict(manifest=P("man-nodbs.json"))),
            ("manifest que é lista", dict(manifest=P("list.json"))), ("banco ausente do manifest", dict(manifest=P("man-nodb.json"))),
            ("manifest com contagem em texto", dict(manifest=P("man-str.json")), "contagem inteira de labels"),
            ("manifest sem a contagem de comments", dict(manifest=P("man-lack.json")), "contagem inteira de comments"),
            ("export ausente", dict(exp=P("nao-existe.jsonl"))), ("export com linha que não é JSON", dict(exp=P("exp-corrupt.jsonl"))),
            ("export com linha que não é objeto", dict(exp=P("exp-list.jsonl"))), ("export com issue sem id", dict(exp=P("exp-noid.jsonl"))),
            ("export vazio (0 linhas)", dict(exp=P("exp-empty.jsonl"))), ("import ausente", dict(imported=P("nao-existe.jsonl"))),
            ("export com comentário sem author", dict(exp=P("exp-noauthor.jsonl")), "ilegível ou fora da forma"),
            ("export com dependência sem type", dict(exp=P("exp-nodeptype.jsonl")), "ilegível ou fora da forma")):
        rc, rp, se = rec(args.get("manifest", P("man.json")), args.get("exp", imp), args.get("stats", P("stats.json")), args.get("imported", imp))
        check("reconcile reprova (sem traceback): %s" % label, rc == 1 and rp["verdict"] == "fail" and rp["problems"] and se == ""
              and all(w in " ".join(rp["problems"]) for w in why), json.dumps(rp)[:200] + se[:200])

# ── F. extract + cadeia ponta a ponta ─────────────────────────────────────────────────
print("-- F. extract / cadeia build -> extract -> convert -> reconcile")


def upload(args, stdin=None):
    p = subprocess.run([sys.executable, "-I", UPLOAD] + list(args), input=stdin, capture_output=True)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


with tempfile.TemporaryDirectory(prefix="jhrst.") as T:
    P = lambda *a: os.path.join(T, *a)  # noqa: E731
    members = (db_members("hq", issues=ISSUES, labels=LABELS, dependencies=DEPS, comments=COMMENTS, config=[{"key": "issue_prefix", "value": "hq"}])
               + db_members("wa", issues=[{"id": "wa-1", "title": "w", "status": "open", "priority": "1", "issue_type": "task"}])
               + [("hq.jsonl", table([{"id": "hq-1"}]))])
    rc, so, se = upload(["build", "--out", P("art.tar.gz"), "--files-out", P("built.json")], stdin=make_tar(members))
    check("cadeia: build do upload (slice 1) rc 0", rc == 0, so + se)
    rc, so, se = upload(["inspect", P("art.tar.gz")])
    put(P("insp.json"), so)
    rc2, so2, se2 = upload(["manifest", "--inspect", P("insp.json"), "--built", P("built.json"), "--captured-epoch", "1760000000",
                            "--head-epoch", "1759999000", "--head-sha", "abc123", "--key", "jsonl-hourly/x.tar.gz", "--require", "hq,wa"])
    put(P("manifest.json"), so2)
    check("cadeia: inspect + manifest do upload dão verdict ok", rc == 0 and rc2 == 0 and json.loads(so2)["verdict"] == "ok", so2[:300] + se2)

    rc, so, se = run("extract", "--archive", P("art.tar.gz"), "--db", "hq", "--out", P("x"))
    got = {f["path"]: f for f in json.loads(so)["files"]}
    built = {f["path"]: f for f in json.load(open(P("built.json")))["files"]}
    check("extract: rc 0, só as 6 tabelas do banco pedido (wa e a cópia da raiz ficam de fora)",
          rc == 0 and sorted(got) == sorted("hq/%s.jsonl" % t for t in jhr.TABLES) and not os.path.exists(P("x", "wa")), so)
    check("extract: bytes e sha256 de cada arquivo batem com o que o build gravou e com o que está em disco",
          all(got[p]["sha256"] == built[p]["sha256"] and got[p]["bytes"] == built[p]["bytes"]
              and hashlib.sha256(open(P("x", p), "rb").read()).hexdigest() == got[p]["sha256"] for p in got), so)
    rc, so, se = run("convert", "--dump", P("x"), "--db", "hq", "--out", P("imp.jsonl"))
    put(P("stats.json"), so)
    put(P("exp.jsonl"), open(P("imp.jsonl")).read())
    rc2, so2, se2 = run("reconcile", "--db", "hq", "--manifest", P("manifest.json"), "--convert-stats", P("stats.json"),
                        "--imported", P("imp.jsonl"), "--exported", P("exp.jsonl"))
    rp = json.loads(so2)
    check("cadeia: o MANIFEST REAL do upload fecha a conta do restore (hq: 3 issues, 1 tombstone, 1 dangling)",
          rc == 0 and rc2 == 0 and rp["verdict"] == "ok" and rp["manifest_checked"] and rp["exclusions"]["tombstones"] == 1, so2[:400] + se2)

    def gz(members_):
        return gzip.compress(make_tar(members_))

    def extract_case(label, archive_bytes, expect_missing=None, pre=()):
        put_bytes = P("case.tar.gz")
        open(put_bytes, "wb").write(archive_bytes)
        out = P("xc")
        os.makedirs(os.path.join(out, "hq"), exist_ok=True)
        for t in pre:
            put(os.path.join(out, "hq", t + ".jsonl"), "SOBRA\n")
        rc_, so_, se_ = run("extract", "--archive", put_bytes, "--db", "hq", "--out", out)
        left = sorted(os.listdir(os.path.join(out, "hq")))
        check("extract: %s => rc 1 e nenhuma tabela sobra no diretório" % label, rc_ == 1 and left == [], "%s %s %s" % (so_[:200], se_[:100], left))
        if expect_missing:
            check("extract: %s => 'missing' nomeia %s" % (label, expect_missing), expect_missing in json.loads(so_)["missing"], so_[:200])

    no_labels = [m for m in db_members("hq", issues=ISSUES) if not m[0].endswith("/labels.jsonl")]
    extract_case("tabela faltando no artefato", gz(no_labels), "labels")
    extract_case("tabela faltando + sobra de extração anterior", gz(no_labels), "labels", pre=("labels", "issues"))
    extract_case("artefato sem nenhum membro do banco", gz(db_members("wa", issues=[])), "issues")
    extract_case("membro repetido", gz(db_members("hq", issues=ISSUES) + [("hq/issues.jsonl", table(ISSUES))]))
    extract_case("não é gzip", b"isto nao e um tar.gz")
    full = gz(db_members("hq", issues=ISSUES * 50, comments=COMMENTS * 50))
    extract_case("gzip cortado no meio", full[:len(full) // 2])
    rc, so, se = run("extract", "--archive", P("art.tar.gz"), "--db", "../x", "--out", P("x2"))
    check("extract: nome de banco fora do molde (../x) => rc 2 e nada criado", rc == 2 and not os.path.exists(P("x2")), so + se)

# ── G. a prova CONSEGUE reprovar: reconcile defeituoso contra os MESMOS casos ─────────
print("-- G. mutantes de reconcile")
SRC = open(os.path.join(HERE, "jsonl_hourly_restore.py")).read()
NO_LABEL = [('COUNTED = ("issues", "labels", "dependencies", "comments")', 'COUNTED = ("issues", "dependencies", "comments")'),
            ('("labels", ilab, elab), ', "")]
NO_DEP = [('COUNTED = ("issues", "labels", "dependencies", "comments")', 'COUNTED = ("issues", "labels", "comments")'),
          ('("dependencies", idep, edep), ', "")]
NO_COMMENT = [('COUNTED = ("issues", "labels", "dependencies", "comments")', 'COUNTED = ("issues", "labels", "dependencies")'),
              (', ("comments", icom, ecom)', "")]
MUTANTS = (
    ("ignora label perdida", NO_LABEL), ("ignora dependência perdida", NO_DEP), ("ignora comentário perdido", NO_COMMENT),
    ("não compara título/descrição/status/prioridade/tipo", [("diff_fp = sorted(i for i in set(ifp) & set(efp) if ifp[i] != efp[i])", "diff_fp = []")]),
    ("aceita issue a mais", [('COUNTED = ("issues", "labels", "dependencies", "comments")', 'COUNTED = ("labels", "dependencies", "comments")'),
                             ("extra_ids = sorted(set(efp) - set(ifp))", "extra_ids = []")]),
    ("ignora valor que o conversor não carregou", [('bad = {k: v for k, v in conv["bad_values"].items() if v}', "bad = {}")]),
)
def load_variant(text):
    """Executa o fonte (original ou com um defeito injetado) como módulo à parte, no mesmo processo: cada mutante roda ~15 casos."""
    mod = types.ModuleType("jhr_variant")
    mod.__file__ = os.path.join(HERE, "jsonl_hourly_restore.py")  # o módulo põe o diretório dele no sys.path para achar jsonl_hourly
    exec(compile(text, mod.__file__, "exec"), mod.__dict__)
    return mod


with tempfile.TemporaryDirectory(prefix="jhrst.") as T2:
    P2 = lambda *a: os.path.join(T2, *a)  # noqa: E731
    # os casos do bloco D precisam dos arquivos dele: refaz o cenário mínimo aqui (import, stats, manifests e os exports adulterados)
    write_db(P2("dump"), "hq", issues=ISSUES, labels=LABELS, dependencies=DEPS, comments=COMMENTS, config=[{"key": "issue_prefix", "value": "hq"}])
    _, st_s, _ = run("convert", "--dump", P2("dump"), "--db", "hq", "--out", P2("imp.jsonl"))
    put(P2("stats.json"), st_s)
    json.dump(MAN_OK, open(P2("man.json"), "w"))
    write_db(P2("dump-bad"), "hq", issues=[{"id": "hq-1", "title": "t", "status": "open", "priority": "abc", "issue_type": "task"}])
    _, bad_s, _ = run("convert", "--dump", P2("dump-bad"), "--db", "hq", "--out", P2("imp-bad.jsonl"))
    put(P2("stats-bad.json"), bad_s)
    json.dump({"databases": {"hq": {"issues": 1, "labels": 0, "dependencies": 0, "comments": 0}}}, open(P2("man-bad.json"), "w"))
    G_CASES = []
    for i, fn in enumerate((e_drop_label, e_swap_label, e_retitle, e_drop_issue, e_add_issue, e_drop_dep, e_retype_dep, e_empty_ext,
                            e_drop_comment, e_swap_comment, e_desc, e_status, e_prio, e_type)):
        ls = jlines(P2("imp.jsonl"))
        fn(ls)
        put_lines(P2("exp-%d.jsonl" % i), ls)
        G_CASES.append((P2("man.json"), P2("stats.json"), P2("imp.jsonl"), P2("exp-%d.jsonl" % i)))
    G_CASES.append((P2("man-bad.json"), P2("stats-bad.json"), P2("imp-bad.jsonl"), P2("imp-bad.jsonl")))
    CONTROL = (P2("man.json"), P2("stats.json"), P2("imp.jsonl"), P2("imp.jsonl"))  # export idêntico: tem de dar ok

    def verdicts(mod):
        """Por caso (os de G_CASES e, por último, o controle positivo): True = o reconcile disse ok."""
        out = []
        for man, stats, imported, exp in G_CASES + [CONTROL]:
            ns = argparse.Namespace(db="hq", manifest=man, convert_stats=stats, imported=imported, exported=exp)
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc_ = mod.cmd_reconcile(ns)
            out.append(rc_ == 0 and json.loads(buf.getvalue()).get("verdict") == "ok")
        return out

    base_v = verdicts(load_variant(SRC))
    check("mutantes: o reconcile verdadeiro reprova TODOS os %d casos e aprova o controle positivo" % len(G_CASES), base_v == [False] * len(G_CASES) + [True], str(base_v))
    for label, edits in MUTANTS:
        text, ok = SRC, True
        for old, new in edits:
            if text.count(old) != 1:
                ok = False
            text = text.replace(old, new)
        check("mutante '%s': o trecho trocado existe uma vez no reconcile (refatorou? atualize o mutante)" % label, ok)
        v = verdicts(load_variant(text))
        check("mutante '%s': ainda roda (controle positivo ok) e deixa passar ao menos um caso => a suíte o pegaria" % label,
              v[-1] and any(v[:-1]), str(v))

print("=== RESULT: PASS=%d FAIL=%d ===" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
