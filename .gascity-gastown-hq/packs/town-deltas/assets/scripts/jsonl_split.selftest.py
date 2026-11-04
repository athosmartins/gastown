#!/usr/bin/env python3
"""jsonl_split.selftest.py (ga-e4cbc5s) — testes do divisor jsonl_split.py.

Contents
  Escopo · Como rodar · O que cada bloco prova

ESCOPO: hermético. Só tmpdir, `git` local e subprocess do próprio helper; sem rede, sem dolt, sem bd.
COMO RODAR: python3 -I jsonl_split.selftest.py   (rc 0 = tudo passou; a última linha é `=== RESULT: PASS=n FAIL=n ===`)
O QUE PROVA:
  A. split: uma peça por dia de created_at (+ undated), linhas VERBATIM e na ordem de entrada, qualquer envelope de entrada, união das
     peças = a tabela (nenhuma linha some nem repete), peça que não mudou NÃO é regravada, dia que esvaziou some, o mtime do diretório sempre avança;
  B. fail-closed: documento truncado/com lixo, contagem diferente de --expect-rows ou chave ausente deixam as peças como estavam (e sem temporário);
  C. higiene: temporário de processo morto é varrido, arquivo estranho no diretório fica, mais dias que handles abertos funciona;
  D. count-head: linhas da tabela no HEAD do archive, em documento único (layout antigo) ou em peças (novo); ausente = 0; os dois juntos, peça
     corrompida ou repo ilegível = erro SEM número no stdout.
"""
import io
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "jsonl_split.py")
sys.path.insert(0, HERE)
import jsonl_hourly as jh  # noqa: E402
import jsonl_split as js  # noqa: E402

PASS = FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  PASS: " + name)
    else:
        FAIL += 1
        print("  FAIL: %s %s" % (name, detail))


def run(*args):
    p = subprocess.run([sys.executable, "-I", TOOL] + list(args), capture_output=True)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def row(i, day, **kw):
    d = {"id": "c%03d" % i, "created_at": "%s 10:%02d:00" % (day, i % 60), "text": "linha %d" % i}
    d.update(kw)
    return d


def doc(rows, style="dolt"):
    body = ",".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) for r in rows)
    return {"dolt": '{"rows": [%s]}\n', "jq": '{"rows":[%s]}\n', "bare": '{"rows":[%s]}'}[style] % body


def put(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read_piece(path):
    with open(path, "rb") as f:
        return list(jh.iter_rows(f))


def names(d):
    return sorted(n for n in os.listdir(d) if not n.startswith("."))


def st(path):
    s = os.stat(path)
    return (s.st_ino, s.st_mtime_ns, s.st_size)


print("=== jsonl_split.selftest.py ===")
with tempfile.TemporaryDirectory(prefix="jssp.") as T:
    # ── A. split ─────────────────────────────────────────────────────────────────────────────
    print("-- A. split")
    src, out = os.path.join(T, "comments.jsonl"), os.path.join(T, "hq", "comments")
    rows = [row(1, "2026-11-02"), row(2, "2026-11-01"), row(3, "2026-11-02"), row(4, "2026-11-03"), row(5, "2026-11-01"),
            {"id": "c006", "text": "sem data"}, {"id": "c007", "created_at": None, "text": "nulo"},
            {"id": "c008", "created_at": "2026-11-03T08:00:00Z", "text": "ISO com T"}, {"id": "c009", "created_at": "ontem", "text": "lixo"}]
    put(src, doc(rows))
    r = js.split_doc(src, out)
    check("split: um arquivo por dia + undated (sem data, nulo e ilegível juntos)",
          names(out) == ["2026-11-01.jsonl", "2026-11-02.jsonl", "2026-11-03.jsonl", "undated.jsonl"], repr(names(out)))
    check("split: o relatório conta linhas, peças e gravadas", (r["rows"], r["pieces"], r["written"], r["removed"]) == (9, 4, 4, 0), repr(r))
    got = {n[:-6]: [x["id"] for x in read_piece(os.path.join(out, n))] for n in names(out)}
    check("split: linhas de cada peça na ORDEM de entrada",
          got == {"2026-11-01": ["c002", "c005"], "2026-11-02": ["c001", "c003"], "2026-11-03": ["c004", "c008"], "undated": ["c006", "c007", "c009"]}, repr(got))
    check("split: a união das peças é a tabela (nenhuma linha some nem repete)",
          sorted(x["id"] for n in names(out) for x in read_piece(os.path.join(out, n))) == sorted(x["id"] for x in rows))
    p1 = open(os.path.join(out, "2026-11-01.jsonl"), "rb").read()
    check("split: cada peça é UM documento no formato do Dolt (cabeçalho, linhas com vírgula, `]}` e quebra de linha)",
          p1.startswith(jh.PIECE_HEAD) and p1.endswith(jh.PIECE_TAIL) and p1.count(b"\n") == 1 and jh.PIECE_HEAD == b'{"rows": [', repr(p1[:30]))

    raw = '{"rows": [{"id":"a","created_at":"2026-11-01 00:00:01","text":"x\\u003cy \\u00e9 \\" ,{ } ação 🙂"},\n {"id":"b","created_at":"2026-11-01 00:00:02", "text" : "z"}]}\n'
    put(src, raw)
    js.split_doc(src, out)
    want = '{"id":"a","created_at":"2026-11-01 00:00:01","text":"x\\u003cy \\u00e9 \\" ,{ } ação 🙂"},{"id":"b","created_at":"2026-11-01 00:00:02", "text" : "z"}'
    check("split: o TEXTO de cada linha vai verbatim (escapes, espaços e multibyte intactos, nada reserializado)",
          open(os.path.join(out, "2026-11-01.jsonl"), "rb").read().decode("utf-8") == '{"rows": [' + want + ']}\n')

    same = None
    for style in ("dolt", "jq", "bare"):
        put(src, doc(rows[:5], style))
        js.split_doc(src, out)
        cur = {n: open(os.path.join(out, n), "rb").read() for n in names(out)}
        same = cur if same is None else same
        check("split: envelope de entrada '%s' dá as mesmas peças" % style, cur == same)
    put(src, doc(rows[:5]))
    js.split_doc(src, out)
    check("split: caiu a linha 'undated' do conjunto anterior => peça undated.jsonl removida", "undated.jsonl" not in names(out), repr(names(out)))

    # idempotência: a mesma tabela não regrava nada (mesmo inode, mesmo mtime)
    before = {n: st(os.path.join(out, n)) for n in names(out)}
    time.sleep(0.02)
    r2 = js.split_doc(src, out)
    check("split: segunda rodada com a mesma tabela => 0 peças gravadas, mesmos inodes e mtimes",
          r2["written"] == 0 and before == {n: st(os.path.join(out, n)) for n in names(out)}, repr(r2))
    # uma linha nova no último dia: só aquela peça muda
    put(src, doc(rows[:5] + [row(10, "2026-11-03")]))
    r3 = js.split_doc(src, out)
    after = {n: st(os.path.join(out, n)) for n in names(out)}
    check("split: linha nova de hoje => grava SÓ a peça do dia; as outras seguem com inode e mtime de antes",
          r3["written"] == 1 and all(after[n] == before[n] for n in ("2026-11-01.jsonl", "2026-11-02.jsonl")) and after["2026-11-03.jsonl"] != before["2026-11-03.jsonl"], repr(r3))
    # mesmo tamanho em bytes, conteúdo diferente (prioridade "1" -> "2"): a peça TEM que ser regravada, o tamanho sozinho não prova que é a mesma
    base5 = rows[:5] + [row(10, "2026-11-03")]
    put(src, doc([dict(x, text=x["text"].replace("linha", "linhb")) if x["id"] == "c004" else x for x in base5]))
    r3b = js.split_doc(src, out)
    check("split: mesmo tamanho, conteúdo diferente => a peça é regravada com o conteúdo novo",
          r3b["written"] == 1 and b"linhb 4" in open(os.path.join(out, "2026-11-03.jsonl"), "rb").read(), repr(r3b))
    # o dia que esvaziou some; o mtime do diretório avança mesmo sem nada para gravar
    put(src, doc([x for x in rows[:5] + [row(10, "2026-11-03")] if not x["created_at"].startswith("2026-11-01")]))
    r4 = js.split_doc(src, out)
    check("split: dia sem nenhuma linha => a peça some", names(out) == ["2026-11-02.jsonl", "2026-11-03.jsonl"] and r4["removed"] == 1, repr((names(out), r4)))
    os.utime(out, (1000, 1000))
    js.split_doc(src, out)
    check("split: o mtime do DIRETÓRIO avança a cada rodada boa, mesmo sem peça nova (é o carimbo de 'o exporter passou por aqui')", os.stat(out).st_mtime > time.time() - 60)
    put(src, "{}\n")
    r5 = js.split_doc(src, out)
    check("split: tabela vazia ({}) => zero peças, o diretório fica e as antigas somem", names(out) == [] and r5["rows"] == 0 and r5["pieces"] == 0, repr((names(out), r5)))

    # ── B. fail-closed ───────────────────────────────────────────────────────────────────────
    print("-- B. fail-closed")
    put(src, doc(rows[:5]))
    js.split_doc(src, out)
    keep = {n: open(os.path.join(out, n), "rb").read() for n in names(out)}
    good_doc = doc(rows[:5] + [row(11, "2026-12-01")])
    bad = {"truncado": good_doc[:-9], "lixo depois do }": good_doc + "xyz", "linha que não é objeto": '{"rows": [1, 2]}', "vazio": ""}
    for label, text in bad.items():
        put(src, text)
        rc, so, se = run("split", "--in", src, "--out-dir", out)
        check("split (%s): rc 1, causa no stderr, peças como estavam, sem temporário" % label,
              rc == 1 and se.strip() and keep == {n: open(os.path.join(out, n), "rb").read() for n in names(out) if ".tmp." not in n}
              and not [n for n in os.listdir(out) if ".tmp." in n], "rc=%s %s %s" % (rc, so, se[-100:]))
    put(src, good_doc)
    rc, so, se = run("split", "--in", src, "--out-dir", out, "--expect-rows", "5")
    check("--expect-rows diferente do que foi lido => rc 1 e NADA muda (a peça 2026-12-01 não aparece)",
          rc == 1 and "2026-12-01.jsonl" not in names(out) and keep == {n: open(os.path.join(out, n), "rb").read() for n in names(out)}, "rc=%s %s" % (rc, se[-120:]))
    rc, so, se = run("split", "--in", src, "--out-dir", out, "--expect-rows", "6")
    check("--expect-rows igual => rc 0 e o relatório sai em JSON no stdout", rc == 0 and json.loads(so)["rows"] == 6 and "2026-12-01.jsonl" in names(out), "rc=%s %s %s" % (rc, so, se))
    rc, so, se = run("split", "--in", src, "--out-dir", out, "--expect-rows", "abc")
    check("--expect-rows que não é número => rc 2 (uso), nada muda", rc == 2, "rc=%s %s" % (rc, se[-80:]))
    rc, so, se = run("split", "--in", os.path.join(T, "nao-existe.jsonl"), "--out-dir", out)
    check("entrada que não existe => rc 1 (nunca 'tabela vazia')", rc == 1 and "2026-12-01.jsonl" in names(out), "rc=%s %s" % (rc, se[-80:]))

    # a 2ª passada confere o que gravou contra a 1ª: se a tabela mudou entre as duas leituras, nenhuma peça vira definitiva
    out4, real_scan = os.path.join(T, "hq", "mudou"), js._scan
    put(src, doc(rows[:5]))

    def lying_scan(*a):
        acc = real_scan(*a)
        acc["2026-11-02"][0] += 1
        return acc
    js._scan = lying_scan
    try:
        try:
            js.split_doc(src, out4)
            raised = False
        except js.SplitError:
            raised = True
    finally:
        js._scan = real_scan
    check("arquivo que mudou entre as duas passadas => SplitError, nenhuma peça definitiva e nenhum temporário", raised and names(out4) == [], repr(names(out4)))

    # ── C. higiene ───────────────────────────────────────────────────────────────────────────
    print("-- C. higiene")
    out2 = os.path.join(T, "hq", "issues")
    os.makedirs(out2)
    dead = subprocess.Popen([sys.executable, "-c", "pass"])
    dead.wait()
    put(os.path.join(out2, "2026-11-02.jsonl.tmp.p%d" % dead.pid), "sobra de processo morto")
    put(os.path.join(out2, "2026-11-04.jsonl.tmp.p%d" % os.getppid()), "temporário de processo vivo (o dono é outro)")
    put(os.path.join(out2, "LEIAME"), "arquivo estranho")
    put(src, doc(rows[:5]))
    js.split_doc(src, out2)
    left = names(out2)
    check("higiene: temporário de processo MORTO é varrido; o de processo vivo e o arquivo estranho ficam",
          "2026-11-02.jsonl.tmp.p%d" % dead.pid not in left and "2026-11-04.jsonl.tmp.p%d" % os.getppid() in left and "LEIAME" in left, repr(left))
    many = [row(i, "2026-10-%02d" % (1 + i % 25)) for i in range(100)]
    put(src, doc(many))
    old_max = js.MAX_OPEN
    js.MAX_OPEN = 3
    try:
        out3 = os.path.join(T, "hq", "many")
        js.split_doc(src, out3)
    finally:
        js.MAX_OPEN = old_max
    check("higiene: 25 dias com linhas intercaladas e só 3 handles abertos => todas as linhas no lugar certo, sem repetir",
          len(names(out3)) == 25 and sorted(x["id"] for n in names(out3) for x in read_piece(os.path.join(out3, n))) == sorted(x["id"] for x in many)
          and all(x["created_at"].startswith(n[:-6]) for n in names(out3) for x in read_piece(os.path.join(out3, n))))
    check("higiene: nenhum temporário sobra depois de uma rodada boa", not [n for n in os.listdir(out3) if ".tmp." in n])

    # ── D. count-head ────────────────────────────────────────────────────────────────────────
    print("-- D. count-head")
    repo = os.path.join(T, "repo")
    os.makedirs(repo)

    def git(*a):
        return subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + list(a),
                              capture_output=True, text=True)

    git("init", "-q")
    os.makedirs(os.path.join(repo, "hq"))
    put(os.path.join(repo, "hq", "issues.jsonl"), doc([row(i, "2026-11-01") for i in range(7)], "jq"))
    git("add", "-A"), git("commit", "-q", "-m", "legado")
    rc, so, se = run("count-head", "--repo", repo, "--db", "hq", "--table", "issues")
    check("count-head: documento único no HEAD => o número de linhas", rc == 0 and so.strip() == "7", "rc=%s %s %s" % (rc, so, se[-100:]))
    rc, so, se = run("count-head", "--repo", repo, "--db", "hq", "--table", "comments")
    check("count-head: tabela que o HEAD não tem => 0 (primeira rodada), rc 0", rc == 0 and so.strip() == "0", "rc=%s %s %s" % (rc, so, se[-100:]))
    os.unlink(os.path.join(repo, "hq", "issues.jsonl"))
    put(src, doc([row(i, "2026-11-0%d" % (1 + i % 3)) for i in range(11)]))
    js.split_doc(src, os.path.join(repo, "hq", "issues"))
    git("add", "-A"), git("commit", "-q", "-m", "peças")
    rc, so, se = run("count-head", "--repo", repo, "--db", "hq", "--table", "issues")
    check("count-head: peças no HEAD => a soma das linhas das peças", rc == 0 and so.strip() == "11", "rc=%s %s %s" % (rc, so, se[-100:]))
    put(os.path.join(repo, "hq", "issues", "2026-11-01.jsonl"), "pela metade")        # só na árvore de trabalho: o HEAD manda
    rc, so, se = run("count-head", "--repo", repo, "--db", "hq", "--table", "issues")
    check("count-head: lê o HEAD, não a árvore de trabalho", rc == 0 and so.strip() == "11", "rc=%s %s" % (rc, so))
    git("checkout", "-q", "--", "hq")
    put(os.path.join(repo, "hq", "issues.jsonl"), doc([row(0, "2026-11-01")]))
    git("add", "-A"), git("commit", "-q", "-m", "misto")
    rc, so, se = run("count-head", "--repo", repo, "--db", "hq", "--table", "issues")
    check("count-head: documento único E peças no mesmo HEAD => rc 1, SEM número (não escolhe um dos dois)", rc == 1 and not so.strip() and se.strip(), "rc=%s %s %s" % (rc, so, se[-100:]))
    git("rm", "-q", "--", "hq/issues.jsonl"), git("commit", "-q", "-m", "tira o único")
    put(os.path.join(repo, "hq", "issues", "2026-11-02.jsonl"), '{"rows": [{"id":"x"}')
    git("add", "-A"), git("commit", "-q", "-m", "peça cortada")
    rc, so, se = run("count-head", "--repo", repo, "--db", "hq", "--table", "issues")
    check("count-head: peça corrompida => rc 1, SEM número", rc == 1 and not so.strip() and se.strip(), "rc=%s %s %s" % (rc, so, se[-100:]))
    rc, so, se = run("count-head", "--repo", os.path.join(T, "nao-e-repo"), "--db", "hq", "--table", "issues")
    check("count-head: repo ilegível => rc 1, SEM número (o chamador decide; nunca vira 0 aqui)", rc == 1 and not so.strip(), "rc=%s %s %s" % (rc, so, se[-100:]))
    rc, so, se = run("count-head", "--repo", repo, "--db", "../x", "--table", "issues")
    check("count-head: nome de banco fora do molde => rc 2", rc == 2, "rc=%s %s" % (rc, se[-80:]))

print("=== RESULT: PASS=%d FAIL=%d ===" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
