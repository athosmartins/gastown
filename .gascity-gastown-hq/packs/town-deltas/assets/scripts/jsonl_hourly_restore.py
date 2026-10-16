#!/usr/bin/env python3
"""jsonl_hourly_restore.py (ga-c0939v.3) — lado RESTORE do dump JSONL horário: solta um banco do snapshot, converte as
tabelas para o JSONL que o `bd import` entende e faz as contas que provam que o restore devolveu tudo.

Contents
  Por quê · Subcomandos · A conta · Regras de fail-closed

POR QUÊ: o snapshot só conta como RPO de 1 h se um restore dele reproduz os números do manifest. Este módulo é a metade
  Python dessa prova (o `bd import` / `bd export` reais ficam no jsonl-hourly-restore.sh, ga-c0939v.4). Lê as tabelas com o
  MESMO leitor do upload (jsonl_hourly.iter_rows): o que o manifest contou é o que o restore percorre.

SUBCOMANDOS (stdout = JSON, rc 0 ok / 1 dump ou entrada ilegível, ou prova reprovada / 2 uso)
  extract   --archive F.tar.gz --db NAME --out DIR      solta DIR/<db>/<tabela>.jsonl do artefato (bytes+sha256 de cada um)
  convert   --dump DIR --db NAME --out F.jsonl          tabelas de um banco -> JSONL do `bd import` + números para a conta
  reconcile --db NAME [--manifest M.json] --convert-stats S.json --imported I.jsonl --exported E.jsonl
                                                        a conta: manifest − exclusões por desenho = esperado = restaurado

A CONTA (issues, labels, dependências, comentários): manifest − exclusões por desenho = esperado = o que o export devolveu.
  Além da contagem, issue por issue (status, título, prioridade, tipo, descrição) e filho por filho (multiconjunto de
  labels, dependências e comentários) o que entrou no import tem que ter voltado igual. Exclusão por desenho = tombstone
  (o importer o pula), filho de issue que não está no dump, aresta cujo alvo não está no store e comentários de conteúdo
  idêntico que o import funde; cada uma aparece NOMEADA e CONTADA no relatório. Coluna do dump que o conversor não leva ao
  import (fora das conhecidas abaixo) é NOMEADA e contada em unmapped_columns: não some em silêncio, mas também não reprova a
  prova. Medido em 16/10 nos dumps ao vivo: gastown work_type=1667, wisp_type=10, row_lock=22; lexbh row_lock=16. Se o
  `bd import` aceita a coluna, é um nome a mais em _STR_FIELDS; quem mede isso com o bd real é a fatia 4.

FAIL-CLOSED: tabela ausente, truncada, malformada ou linha sem id/alvo é erro (rc 1) e o --out é REMOVIDO — o convert grava
  em <out>.part e só renomeia depois da última linha, porque o leitor emite linhas antes de validar o fim do documento. Valor
  do dump que o conversor não conseguiu carregar (prioridade não numérica, metadata que não é objeto, data fora do formato)
  é contado em bad_values e REPROVA a prova. Entrada da prova ilegível ou fora da forma (stats, manifest, import, export) dá
  verdict "fail" com rc 1 — nunca traceback, nunca "ok".
"""
import argparse
import collections
import hashlib
import json
import os
import re
import sys
import tarfile

# python3 -I não põe o diretório do script no sys.path
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from jsonl_hourly import DumpError, MEMBER_RE, TABLES, iter_rows  # noqa: E402

COUNTED = ("issues", "labels", "dependencies", "comments")
_DB_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$")  # o mesmo molde de nome de banco do MEMBER_RE
_BAD = (DumpError, KeyError, TypeError, AttributeError, ValueError)  # linha fora da forma esperada


def _db(v):
    if not _DB_RE.match(v):
        raise argparse.ArgumentTypeError("nome de banco fora do molde %s: %r" % (_DB_RE.pattern, v))
    return v


def _unlink(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


# ── extract (um banco do artefato -> DIR/<db>/<tabela>.jsonl) ─────────────────────────
def _clear(out):
    for t in TABLES:
        _unlink(os.path.join(out, t + ".jsonl"))


def cmd_extract(args):
    out, got, seen = os.path.join(args.out, args.db), [], set()
    os.makedirs(out, exist_ok=True)
    try:
        # vazio (artefato sem membro deste banco) → `missing` lista as 6 tabelas, o diretório é limpo e rc 1; falhou/ilegível
        # (gzip/tar ruim, membro repetido, leitura curta) → exceção, o diretório é limpo e o main devolve rc 1. Com rc 0 as 6
        # tabelas foram regravadas, então o diretório só tem tabelas DESTE artefato (processo morto no meio sai com rc != 0).
        with tarfile.open(args.archive, "r|gz") as tf:
            for m in tf:
                mm = MEMBER_RE.match(m.name) if m.isreg() else None
                if not mm or mm.group(1) != args.db:
                    continue
                if mm.group(2) in seen:
                    raise DumpError("membro repetido no artefato: %s" % m.name)
                seen.add(mm.group(2))
                h, n = hashlib.sha256(), 0
                with open(os.path.join(out, mm.group(2) + ".jsonl"), "wb") as w:
                    src = tf.extractfile(m)
                    while True:
                        b = src.read(1024 * 1024)
                        if not b:
                            break
                        w.write(b)
                        h.update(b)
                        n += len(b)
                if n != m.size:
                    raise DumpError("leitura curta em %s: %d de %d bytes" % (m.name, n, m.size))
                got.append({"path": m.name, "bytes": n, "sha256": h.hexdigest()})
    except BaseException:
        _clear(out)
        raise
    missing = [t for t in TABLES if t not in seen]
    if missing:
        _clear(out)
    print(json.dumps({"files": [] if missing else got, "missing": missing}, sort_keys=True))
    return 1 if missing else 0


# ── convert (tabelas -> JSONL do bd import) ───────────────────────────────────────────
_TS_FIELDS = ("created_at", "updated_at", "closed_at", "started_at", "due_at", "defer_until")
_STR_FIELDS = ("title", "description", "design", "notes", "acceptance_criteria", "status", "issue_type",
               "assignee", "owner", "created_by", "close_reason", "external_ref", "source_system", "spec_id")
_BOOL_FIELDS = ("pinned", "ephemeral", "is_template", "no_history")
# colunas que o bd recalcula (não são dado): ficam fora de unmapped_columns. Qualquer OUTRA coluna com valor que não esteja
# em _KNOWN é contada lá, nunca descartada em silêncio
_COMPUTED = {"id", "is_blocked", "content_hash", "compaction_level", "timeout_ns"}
_KNOWN = set(_TS_FIELDS) | set(_STR_FIELDS) | set(_BOOL_FIELDS) | {"priority", "estimated_minutes", "metadata"} | _COMPUTED
_TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d+)?$")


def _ts(v, stats):
    """'2026-05-16 13:03:54' (UTC, sem zona) -> RFC3339. Fora desse formato segue como veio, mas CONTADO (reprova a prova)."""
    v = v.strip()
    if _TS_RE.match(v):
        return v.replace(" ", "T") + "Z"
    stats["bad_timestamp"] += 1
    return v


def _truthy(v):
    return str(v).strip().lower() in ("1", "true", "t", "yes")


def convert_issue_row(row, stats):
    out = {"_type": "issue", "id": row["id"]}
    for k in _STR_FIELDS:
        v = row.get(k)
        if isinstance(v, str) and v != "":
            out[k] = v
    for k in _TS_FIELDS:
        v = row.get(k)
        if isinstance(v, str) and v != "":
            out[k] = _ts(v, stats)
    for k in ("priority", "estimated_minutes"):
        if k in row and str(row[k]).strip() != "":
            try:
                out[k] = int(row[k])
            except ValueError:
                stats["bad_" + k] += 1
    for k in _BOOL_FIELDS:
        if k in row and _truthy(row[k]):
            out[k] = True
    md = row.get("metadata")
    if isinstance(md, str) and md.strip() not in ("", "{}", "null"):
        try:
            obj = json.loads(md)
        except ValueError:
            obj = None
        if isinstance(obj, dict):
            if obj:
                out["metadata"] = obj
        else:
            stats["bad_metadata"] += 1
    elif isinstance(md, dict) and md:
        out["metadata"] = md
    for k, v in row.items():
        if k not in _KNOWN and v not in ("", None, "0"):
            stats["unmapped_columns"][k] = stats["unmapped_columns"].get(k, 0) + 1
    return out


def _rows(base, name):
    """Linhas de <base>/<name>.jsonl, uma a uma. O leitor emite antes de validar o fim: quem consome descarta tudo se a exceção vier."""
    path = os.path.join(base, name + ".jsonl")
    # ausente → DumpError (nunca "tabela vazia"); vazia (`{}` ou "rows":[]) → nenhuma linha; ilegível/truncada → DumpError no meio
    try:
        f = open(path, "rb")
    except FileNotFoundError:
        raise DumpError("tabela ausente: %s" % path)
    with f:
        yield from iter_rows(f)


def _convert(base, db, out_path, stats):
    labels, deps, config = list(_rows(base, "labels")), list(_rows(base, "dependencies")), list(_rows(base, "config"))
    by_label, by_dep, by_comment = {}, {}, {}
    for r in labels:
        by_label.setdefault(r["issue_id"], []).append(r["label"])
    for r in deps:
        by_dep.setdefault(r["issue_id"], []).append(r)
    n_comments = 0
    for r in _rows(base, "comments"):
        n_comments += 1
        by_comment.setdefault(r["issue_id"], []).append(r)
    # 1ª passada: ids que vão existir. O importer só aceita aresta cujo alvo está no store (ou é `external:`); a aresta para
    # um issue de outro banco / escrubado volta como "dangling", contada em vez de sumir calada.
    ids, every = set(), set()
    for row in _rows(base, "issues"):
        if row["id"] in every:
            raise DumpError("issue repetido no dump: %s" % row["id"])
        every.add(row["id"])
        if row.get("status") != "tombstone":
            ids.add(row["id"])
    total = {"issues": 0, "labels": len(labels), "dependencies": len(deps), "comments": n_comments}
    n_issues = n_tomb = n_lab = n_dep = n_com = n_dangling = 0
    with open(out_path, "w", encoding="utf-8") as out:
        for row in _rows(base, "issues"):
            total["issues"] += 1
            if row.get("status") == "tombstone":
                n_tomb += 1  # o importer pula tombstone; contamos para a reconciliação
                continue
            rec = convert_issue_row(row, stats)
            iid = rec["id"]
            if iid in by_label:
                rec["labels"] = by_label[iid]
                n_lab += len(by_label[iid])
            if iid in by_dep:
                kept = []
                for d in by_dep[iid]:
                    # a coluna é depends_on_issue_id OU depends_on_external ("external:wa:wa-euo"); nunca as duas
                    target = d.get("depends_on_issue_id") or d.get("depends_on_external") or d.get("depends_on_id") or ""
                    if not target:
                        raise DumpError("dependência sem alvo em %s" % iid)
                    if not target.startswith("external:") and target not in ids:
                        n_dangling += 1
                        continue
                    kept.append({"issue_id": d["issue_id"], "depends_on_id": target, "type": d.get("type") or "blocks",
                                 **({"created_at": _ts(d["created_at"], stats)} if d.get("created_at") else {}),
                                 **({"created_by": d["created_by"]} if d.get("created_by") else {})})
                if kept:
                    rec["dependencies"] = kept
                n_dep += len(kept)
            if iid in by_comment:
                rec["comments"] = [{"id": c.get("id", ""), "issue_id": iid, "author": c.get("author", ""),
                                    "text": c.get("text", ""), "created_at": _ts(c.get("created_at", ""), stats)}
                                   for c in by_comment[iid]]
                n_com += len(by_comment[iid])
            n_issues += 1
            out.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
    # o que sobrou sem dono: filhos de issue que não está no dump (ou é tombstone) não têm onde ser embutidos
    orphan = {"labels": sum(len(v) for k, v in by_label.items() if k not in ids),
              "dependencies": sum(len(v) for k, v in by_dep.items() if k not in ids),
              "comments": sum(len(v) for k, v in by_comment.items() if k not in ids)}
    return {
        "db": db,
        "table_rows": total,
        "tombstones_skipped": n_tomb,
        "written": {"issues": n_issues, "labels": n_lab, "dependencies": n_dep, "comments": n_com},
        "orphans": orphan,
        "dangling_dependencies": n_dangling,
        "config": {r["key"]: r["value"] for r in config if "key" in r},
        "bad_values": {k: stats[k] for k in ("bad_priority", "bad_estimated_minutes", "bad_metadata", "bad_timestamp")},
        "unmapped_columns": stats["unmapped_columns"],
    }


def cmd_convert(args):
    part = args.out + ".part"
    stats = {"bad_priority": 0, "bad_estimated_minutes": 0, "bad_metadata": 0, "bad_timestamp": 0, "unmapped_columns": {}}
    try:
        doc = _convert(os.path.join(args.dump, args.db), args.db, part, stats)
        os.replace(part, args.out)
    except _BAD + (OSError,) as e:
        _unlink(part)
        _unlink(args.out)  # sobra de execução anterior também: quem ignorar o rc não pode importar um arquivo velho
        print(json.dumps({"error": "%s: %s" % (type(e).__name__, e)}))
        return 1
    print(json.dumps(doc, sort_keys=True))
    return 0


# ── reconcile (contas do restore) ─────────────────────────────────────────────────────
def _fp(rec):
    # descrição ausente, null ou "" → "" nos DOIS lados (o conversor omite descrição vazia); tipo errado → exceção, vira linha fora da forma
    d = rec.get("description") or ""
    return (rec.get("status", ""), rec.get("title", ""), int(rec.get("priority", 0) or 0), rec.get("issue_type", ""),
            hashlib.sha1(d.encode("utf-8")).hexdigest())


def _scan(path):
    """Lê um JSONL do bd (import ou export) e devolve fingerprints por issue e MULTICONJUNTOS (Counter) de labels,
    dependências e comentários. Contar por conjunto esconderia linhas repetidas: foi assim que 14 comentários
    idênticos do gastown viraram "429 de 443" sem que ninguém soubesse explicar a diferença."""
    fps, labels, deps, comments = {}, collections.Counter(), collections.Counter(), collections.Counter()
    # arquivo vazio (0 linhas) → 0 issues, e a conta o compara com o esperado (só passa se o esperado também for 0); ausente, linha
    # ilegível ou fora da forma → DumpError, que o cmd_reconcile devolve como verdict fail
    try:
        f = open(path, "r", encoding="utf-8")
    except OSError as e:
        raise DumpError("%s: %s" % (path, e))
    with f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
                if rec.get("_type", "issue") != "issue":
                    continue
                iid = rec["id"]
                fps[iid] = _fp(rec)
                for lb in rec.get("labels") or []:
                    labels[(iid, lb)] += 1
                for d in rec.get("dependencies") or []:
                    deps[(d["issue_id"], d["depends_on_id"], d.get("type") or "blocks")] += 1
                for c in rec.get("comments") or []:
                    comments[(iid, c.get("author", ""), c.get("text", ""), c.get("created_at", ""))] += 1
            except _BAD as e:
                raise DumpError("%s:%d linha ilegível ou fora da forma (%s: %s)" % (path, n, type(e).__name__, e))
    return fps, labels, deps, comments


def reconcile(db, manifest_counts, conv, imp_path, exp_path):
    """Devolve (verdict, relatório). verdict: ok | fail. Cada exclusão por desenho aparece no relatório."""
    tr, orph = conv["table_rows"], conv["orphans"]
    problems = []
    if conv.get("db") != db:
        problems.append("os números do convert são do banco %r, não de %r" % (conv.get("db"), db))
    bad = {k: v for k, v in conv["bad_values"].items() if v}
    if bad:
        problems.append("o conversor não conseguiu carregar valores do dump: %s" % json.dumps(bad, sort_keys=True))
    if manifest_counts is not None:
        for t in COUNTED:
            if manifest_counts[t] != tr[t]:
                problems.append("artefato difere do manifest em %s: manifest=%s arquivo=%s" % (t, manifest_counts[t], tr[t]))
    base = manifest_counts if manifest_counts is not None else tr
    ifp, ilab, idep, icom = _scan(imp_path)
    efp, elab, edep, ecom = _scan(exp_path)
    expected = {
        "issues": base["issues"] - conv["tombstones_skipped"],
        "labels": base["labels"] - orph["labels"],
        "dependencies": base["dependencies"] - orph["dependencies"] - conv["dangling_dependencies"],
        "comments": base["comments"] - orph["comments"],
    }
    restored = {"issues": len(efp), "labels": sum(elab.values()), "dependencies": sum(edep.values()), "comments": sum(ecom.values())}
    # o que o conversor escreveu tem que bater com o que as contas esperam (senão o erro é nosso, não do bd)
    written = {"issues": len(ifp), "labels": sum(ilab.values()), "dependencies": sum(idep.values()), "comments": sum(icom.values())}
    # Comentários de conteúdo idêntico (mesma issue, autor, texto e data) com ids diferentes: o `bd import` guarda UM só
    # (medido no gastown: 14 de 443). O conteúdo está lá, mas a contagem cai — então a diferença é exclusão por desenho,
    # CONTADA no relatório, e só vale se toda linha do dump voltou ao menos uma vez e nada voltou a mais do que foi escrito.
    collapsed = sum(icom[k] - ecom[k] for k in icom if 0 < ecom[k] < icom[k])
    expected_restored = dict(expected, comments=expected["comments"] - collapsed)
    for t in COUNTED:
        if written[t] != expected[t]:
            problems.append("conversor escreveu %s=%d, contas esperavam %d" % (t, written[t], expected[t]))
        if restored[t] != expected_restored[t]:
            problems.append("restore tem %s=%d, esperado %d" % (t, restored[t], expected_restored[t]))
    missing_ids = sorted(set(ifp) - set(efp))
    extra_ids = sorted(set(efp) - set(ifp))
    diff_fp = sorted(i for i in set(ifp) & set(efp) if ifp[i] != efp[i])
    if missing_ids:
        problems.append("%d issue(s) do dump não voltaram (ex.: %s)" % (len(missing_ids), ",".join(missing_ids[:5])))
    if extra_ids:
        problems.append("%d issue(s) apareceram sem estar no dump (ex.: %s)" % (len(extra_ids), ",".join(extra_ids[:5])))
    if diff_fp:
        problems.append("%d issue(s) voltaram com status/título/prioridade/tipo/descrição diferentes (ex.: %s)" % (len(diff_fp), ",".join(diff_fp[:5])))
    for name, a, b in (("labels", ilab, elab), ("dependencies", idep, edep), ("comments", icom, ecom)):
        gone = sum(1 for k in a if b[k] == 0)
        extra = sum(1 for k in b if b[k] > a[k])
        if gone:
            problems.append("%d %s do dump não voltaram" % (gone, name))
        if extra:
            problems.append("%d %s apareceram sem estar no dump (ou voltaram mais vezes do que foram escritos)" % (extra, name))
    table = []
    for t in COUNTED:
        exp_t = expected_restored[t]
        table.append({"table": t, "manifest": base[t], "excluded_by_design": base[t] - exp_t, "expected": exp_t,
                      "restored": restored[t], "diff": restored[t] - exp_t})
    rep = {"verdict": "ok" if not problems else "fail", "db": db, "manifest_checked": manifest_counts is not None,
           "table": table, "problems": problems,
           "exclusions": {"tombstones": conv["tombstones_skipped"], "orphans": orph,
                          "dangling_dependencies": conv["dangling_dependencies"], "duplicate_comments_collapsed": collapsed},
           "unmapped_columns": conv.get("unmapped_columns", {})}
    return rep["verdict"], rep


def _read_json(path, what):
    # arquivo de 0 bytes ou JSON quebrado → ilegível, nunca "documento vazio"; ausente → idem
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        raise DumpError("%s ilegível (%s): %s" % (what, path, e))


def _fail(*problems):
    print(json.dumps({"verdict": "fail", "problems": list(problems)}, sort_keys=True))
    return 1


def cmd_reconcile(args):
    try:
        conv = _read_json(args.convert_stats, "stats do convert")
        counts = None
        if args.manifest:
            counts = _read_json(args.manifest, "manifest")["databases"].get(args.db)
            if counts is None:
                return _fail("banco %s não está no manifest" % args.db)
            lacking = [t for t in COUNTED if type(counts.get(t)) is not int]
            if lacking:
                return _fail("manifest sem contagem inteira de %s para o banco %s" % (",".join(lacking), args.db))
        verdict, rep = reconcile(args.db, counts, conv, args.imported, args.exported)
    except _BAD + (OSError,) as e:
        return _fail("entrada da prova ilegível ou fora da forma: %s: %s" % (type(e).__name__, e))
    print(json.dumps(rep, sort_keys=True))
    return 0 if verdict == "ok" else 1


def main(argv=None):
    ap = argparse.ArgumentParser(prog="jsonl_hourly_restore.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    x = sub.add_parser("extract")
    x.add_argument("--archive", required=True)
    x.add_argument("--db", required=True, type=_db)
    x.add_argument("--out", required=True)
    x.set_defaults(fn=cmd_extract)
    v = sub.add_parser("convert")
    v.add_argument("--dump", required=True)
    v.add_argument("--db", required=True, type=_db)
    v.add_argument("--out", required=True)
    v.set_defaults(fn=cmd_convert)
    r = sub.add_parser("reconcile")
    r.add_argument("--db", required=True, type=_db)
    r.add_argument("--manifest")
    r.add_argument("--convert-stats", required=True)
    r.add_argument("--imported", required=True)
    r.add_argument("--exported", required=True)
    r.set_defaults(fn=cmd_reconcile)
    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except (DumpError, tarfile.TarError, OSError, EOFError) as e:
        print(json.dumps({"error": "%s: %s" % (type(e).__name__, e)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
