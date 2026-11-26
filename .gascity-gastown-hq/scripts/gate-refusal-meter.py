#!/usr/bin/env python3
"""gate-refusal-meter.py — ga-mw5gdyu.1 (auto-melhoria, fatia 1): weekly meter of the gate's refusals by root class. READ-ONLY and the cycle's EVALUATOR: it measures, it opens no bead, sends no mail and edits nothing
(--save writes ONE json+txt pair under .gc/). Generalises scripts/root-class-count.sh (which counts only root-class:error-vs-empty, and by label: how many were LABELLED, not how many refusals) and uses third-state-report.py's
definitions of first attempt and refusal (one difference: a verdict whose bead is empty is `unusable` here, not one anonymous bead), so both tell the same story. Runbook: docs/runbooks/gate-refusal-meter.md.

MEASURES  (window = --days, default 7, ending --now)
  first attempt   the FIRST real verdict of a bead over the whole .gc/quality-gate.jsonl (dispatcher_complete, dry_run != 1, PASS|FAIL); the bead counts when that verdict falls in the window; approved = PASS.
  refusal         a FAIL in the window whose reason is a reviewer's ("Reviewer ..."). Other FAILs (merge after all-PASS, bead closed) are counted apart: nobody rejected the code.
  class           every root-class:<name> in the BLOCKING part of the gate-run comment (HQ store) — all classes, not one. A refusal naming two classes counts once in each; with none it is "sem rótulo" and is
                  grouped by the title of each of its blocking issues (the verdict's own words, normalised). A refusal whose comment cannot be read is "sem leitura": neither labelled nor unlabelled.
  inventory       beads carrying root-class:<name>, per store of `gc rig list` (never a hardcoded list), for the classes seen above + error-vs-empty + --class; labelled beads, NOT refusals (see root-class-count.sh).
THREE STATES everywhere: measured / "sem dado" / NÃO MEDIDO (a log, store, command or comment that could not be read is never 0). `complete` is false and `gaps` says why whenever anything was not measured.
EVALUATOR  json.evaluator.sha256 is the hash of THIS file: a comparison between two runs is only valid when it is equal; a later slice that edits this script changes it.
EXIT  0 report printed (cells may be NÃO MEDIDO) · 1 --save could not write (the report was still printed) · 2 NÃO SEI: the gate log is absent, unreadable or has no usable row (nothing is counted) · 64 usage."""
import argparse
import concurrent.futures
import contextlib
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import unicodedata

SCHEMA, MIN_N, TOP, WORKERS, CALL_TIMEOUT = 1, 5, 10, 8, 60
DEFAULT_CITY = "/Users/athos/gt/.gascity-gastown-hq"
USAGE = "uso: gate-refusal-meter.py [--days N>=1] [--now YYYY-MM-DDTHH:MM:SSZ] [--city DIR] [--class NOME ...] [--json] [--save]"
UTC = datetime.timezone.utc
TS_RE = re.compile(r'"ts"\s*:\s*"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)"')
NAME = r"[a-z0-9](?:[a-z0-9_-]*[a-z0-9])?"
CLASS_RE = re.compile(r"root-class:(%s)" % NAME)
TITLE_RE = re.compile(r"^[ \t>*_#-]*Blocking issue[ \t]*\d+[ \t*_]*:[ \t*_]*(.*)$", re.I | re.M)
NO_TITLE = "(sem título de bloqueante)"


def parse_ts(s):
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


def try_ts(s):
    """parse_ts, or None when s is not a real timestamp (missing, not a string, month 13...): each caller decides what "no timestamp" means."""
    try:
        return parse_ts(s)
    except (TypeError, ValueError):
        return None


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def run(argv, timeout):
    """-> (rc, stdout); (None, "") when the command could not run or timed out."""
    # vazio → (rc, ""): it ran and printed nothing; falhou → (None, ""): not run / timed out, which every caller reads as NÃO MEDIDO and never as an empty answer
    try:
        p = subprocess.run(argv, capture_output=True, text=True, errors="replace", timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None, ""
    return p.returncode, p.stdout


def read_log(path):
    """-> (state, rows, bad, bad_ts). state ok|absent|unreadable; bad = unparseable non-blank lines; bad_ts = the ts of those that still show one."""
    # vazio → ("ok", [], 0, []) and the caller says NÃO SEI (a log with no row is not "0 verdicts"); falhou/ilegível → "absent" (ENOENT) / "unreadable" (any other error), never an empty list
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except FileNotFoundError:
        return "absent", [], 0, []
    except OSError:
        return "unreadable", [], 0, []
    rows, bad, bad_ts = [], 0, []
    for line in raw.decode("utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            d = json.loads(line)
        except ValueError:
            d = None
        if isinstance(d, dict):
            rows.append(d)
            continue
        bad += 1
        m = TS_RE.search(line)
        t = try_ts(m.group(1)) if m else None  # a ts that shows but is impossible (month 13) is None: the line stays "may be in the window"
        if t is not None:
            bad_ts.append(t)
    return "ok", rows, bad, bad_ts


def verdicts(rows):
    """Real PASS/FAIL verdicts (dry runs and other results are out BY DESIGN) with a usable bead and ts, sorted by time. -> (list of (t, i, row), unusable)."""
    out, unusable = [], 0
    for i, d in enumerate(rows):
        # vazio → the row is not a verdict and is skipped on purpose; ts/bead missing or unreadable → counted in `unusable`, never dropped quietly and never one anonymous bead
        if d.get("event") != "dispatcher_complete" or str(d.get("dry_run")) == "1" or d.get("result") not in ("PASS", "FAIL"):
            continue
        t = try_ts(d.get("ts"))
        if t is None or not isinstance(d.get("bead"), str) or not d["bead"].strip():
            unusable += 1
            continue
        out.append((t, i, d))
    out.sort(key=lambda x: (x[0], x[1]))
    return out, unusable


def first_attempt(vs, lo, now):
    seen, n, ok = set(), 0, 0
    for t, _, d in vs:
        if d["bead"] in seen:
            continue
        seen.add(d["bead"])
        if lo <= t <= now:
            n, ok = n + 1, ok + (d["result"] == "PASS")
    return {"n": n, "approved": ok, "pct": round(100.0 * ok / n, 1) if n else None, "state": "sem dado" if n == 0 else "n<5" if n < MIN_N else "ok"}


def blocking_part(text):
    """The text from 'Blocking reasons:' up to 'Non-blocking findings:' (or the end); None if the comment has no blocking part."""
    # vazio → None: this comment says nothing about blocking (it is NOT "no blocking issue"); the caller treats "no comment with a blocking part at all" as unread
    i = text.find("Blocking reasons:")
    if i < 0:
        return None
    j = text.find("Non-blocking findings:", i)
    return text[i:j if j >= 0 else len(text)]


def read_part(bd, city, gate_run, timeout):
    """-> the blocking text of a gate run's comments, or None = could NOT tell (command failed, bad JSON, no comment with a blocking part)."""
    # vazio → None: a gate run with no comment that has a blocking part is unread, never "unlabelled"; falhou/ilegível → None as well (rc != 0, no run/timeout, bad JSON, not a list)
    rc, out = run([bd, "-C", city, "comments", gate_run, "--json"], timeout)
    if rc != 0:
        return None
    try:
        cs = json.loads(out, strict=False)
    except ValueError:
        return None
    parts = [blocking_part(c["text"]) for c in cs if isinstance(c, dict) and isinstance(c.get("text"), str)] if isinstance(cs, list) else []
    parts = [x for x in parts if x is not None]
    return "\n".join(parts) if parts else None


def title_key(title):
    """The verdict's own words, normalised: a [bracketed class name] is taken alone, then the first 8 words (accents, case, digits, paths and punctuation gone)."""
    t = title.strip()
    if t.startswith("["):
        t = re.split(r"[\]:]", t[1:], maxsplit=1)[0]
    return " ".join(re.findall(r"[a-z]+", unicodedata.normalize("NFKD", t).encode("ascii", "ignore").decode().lower())[:8])


def classify(refs, bd, city):
    """refs: reviewer rejections [(t, i, row)] in time order. -> the `refusals` block: classes by label, unlabelled grouped by words, unread apart."""
    gr = lambda d: d["gate_run"] if isinstance(d.get("gate_run"), str) else ""  # noqa: E731
    runs = sorted({gr(d) for _, _, d in refs} - {""})
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as ex:
        parts = dict(zip(runs, ex.map(lambda r: read_part(bd, city, r, CALL_TIMEOUT), runs)))
    classes, groups, unread, labeled = {}, {}, [], 0
    for _, _, d in refs:
        # vazio → no gate_run to ask about: unread (listed by bead), never "unlabelled"; falhou → parts[run] is None, the same
        part = parts.get(gr(d))
        if part is None:
            unread.append(gr(d) or "bead:" + d["bead"])
            continue
        rig = d["rig"] if isinstance(d.get("rig"), str) and d["rig"] else "unknown"
        names = sorted(set(CLASS_RE.findall(part)))
        labeled += bool(names)
        for n in names:
            c = classes.setdefault(n, {"refusals": 0, "beads": set(), "rigs": {}})
            c["refusals"], c["rigs"][rig] = c["refusals"] + 1, c["rigs"].get(rig, 0) + 1
            c["beads"].add(d["bead"])
        for k in ([] if names else sorted({title_key(t) for t in TITLE_RE.findall(part)} - {""}) or [NO_TITLE]):
            g = groups.setdefault(k, {"key": k, "refusals": 0, "example": {"bead": d["bead"], "gate_run": gr(d)}})
            g["refusals"] += 1
    top = sorted(groups.values(), key=lambda g: (-g["refusals"], g["key"]))
    return {"total": len(refs), "labeled": labeled, "unlabeled": len(refs) - len(unread) - labeled, "unread": len(unread), "unread_runs": sorted(unread), "unlabeled_groups_total": len(groups), "unlabeled_groups": top[:TOP],
            "classes": {n: dict(c, beads=len(c["beads"])) for n, c in sorted(classes.items())}}


def rig_stores(gc):
    """-> ({rig name: store path}, why). Empty dict = the stores could not be derived (why says so): NÃO MEDIDO, never "0 stores"."""
    # vazio → ({}, "nenhum path"): gc answered and named no store; falhou/ilegível → ({}, why): rc != 0, not run/timeout, bad JSON or an unexpected shape
    rc, out = run([gc, "rig", "list", "--json"], CALL_TIMEOUT)
    if rc != 0:
        return {}, "gc rig list " + ("não rodou ou estourou o prazo" if rc is None else "falhou (rc=%s)" % rc)
    try:
        d = json.loads(out, strict=False)
    except ValueError:
        return {}, "gc rig list: resposta ilegível"
    rigs = d if isinstance(d, list) else d.get("rigs") if isinstance(d, dict) else None
    if not isinstance(rigs, list):
        return {}, "gc rig list: resposta ilegível"
    stores = {}
    for r in (r for r in rigs if isinstance(r, dict)):
        p = r.get("path") or r.get("work_dir")
        if isinstance(p, str) and p.strip() and p not in stores.values():
            stores[str(r.get("name") or os.path.basename(p))] = p
    return stores, "" if stores else "gc rig list não devolveu nenhum path"


def count_label(bd, store, name, lo, now):
    """-> (cell, why): cell = {"total", "in_window", "undated"} for the beads of one store labelled root-class:<name> (any status), or None = NÃO MEDIDO (why says so)."""
    # vazio → a real 0 (the list answered with no bead); falhou/ilegível → (None, why): no directory, rc != 0, not run/timeout, bad JSON, or a shape that is neither a list nor {"issues": [...]}
    if not os.path.isdir(store):
        return None, "diretório ausente"
    rc, out = run([bd, "-C", store, "list", "--label", "root-class:" + name, "--status", "all", "--json", "--limit", "0"], CALL_TIMEOUT)
    if rc != 0:
        return None, "bd não rodou ou estourou o prazo" if rc is None else "bd falhou (rc=%s)" % rc
    try:
        d = json.loads(out, strict=False)
    except ValueError:
        return None, "resposta ilegível"
    bs = d if isinstance(d, list) else d.get("issues") if isinstance(d, dict) else None
    if not isinstance(bs, list):
        return None, "resposta ilegível"
    cell = {"total": len(bs), "in_window": 0, "undated": 0}
    for b in bs:
        # vazio/ilegível → "undated": a bead whose created_at is missing or unparseable is counted in the total and flagged, never silently outside the window
        t = try_ts(b.get("created_at")) if isinstance(b, dict) else None
        if t is None:
            cell["undated"] += 1
            continue
        cell["in_window"] += lo <= t <= now
    return cell, ""


def inventory(args, lo, now, seen):
    stores, why = rig_stores(args.gc)
    inv = {"state": "ok" if stores else "nao-medido", "why": why, "stores": list(stores), "classes": {}, "unmeasured": []}
    jobs = [(n, s) for n in sorted(set(seen) | {"error-vs-empty"} | set(args.class_)) for s in stores]
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as ex:
        for (n, s), (cell, w) in zip(jobs, ex.map(lambda j: count_label(args.bd, stores[j[1]], j[0], lo, now), jobs)):
            inv["classes"].setdefault(n, {})[s] = cell
            if cell is None:
                inv["unmeasured"].append("%s×%s: %s" % (s, n, w))
    return inv


def evaluator():
    """The hash of this very file: two runs are comparable only while it is equal. None = could not be taken (a hash nobody took is not "unchanged")."""
    # vazio → n/a (a file always has a hash); falhou/ilegível → sha256 None, and measure() records the gap
    try:
        with open(__file__, "rb") as fh:
            h = hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        h = None
    return {"script": "gate-refusal-meter.py", "sha256": h}


def measure(args, now):
    lo = now - datetime.timedelta(days=args.days)
    rep = {"schema": SCHEMA, "evaluator": evaluator(), "window": {"days": args.days, "from": iso(lo), "to": iso(now)}, "first_attempt": None, "refusals": None, "inventory": None, "complete": False, "gaps": []}
    if rep["evaluator"]["sha256"] is None:
        rep["gaps"].append("avaliador: não consegui ler o próprio arquivo; sem o hash, duas rodadas não são comparáveis")
    st, rows, bad, bad_ts = read_log(os.path.join(args.city, ".gc", "quality-gate.jsonl"))
    rep["gate_log"] = {"state": st if st != "ok" or rows else "empty", "bad_lines": bad, "bad_maybe_in_window": 0, "unusable": 0}
    if rep["gate_log"]["state"] != "ok":
        rep["gaps"].append("NÃO SEI: o quality-gate.jsonl está %s; nada foi contado" % rep["gate_log"]["state"])
        rep["line"] = "NÃO SEI: o quality-gate.jsonl está %s. Nada foi contado — isto NÃO é 0 recusas nem 0%%." % rep["gate_log"]["state"]
        return rep, 2
    vs, unusable = verdicts(rows)
    maybe = bad - sum(1 for t in bad_ts if t < lo)  # a bad line whose ts is legible and BEFORE the window cannot hide a verdict of it; any other might
    rep["gate_log"].update(bad_maybe_in_window=maybe, unusable=unusable)
    if maybe:
        rep["gaps"].append("%d linha(s) ilegível(is) do quality-gate.jsonl podem ser da janela" % maybe)
    if unusable:
        rep["gaps"].append("%d veredito(s) sem ts/bead utilizável ficaram fora da conta" % unusable)
    rep["first_attempt"] = first_attempt(vs, lo, now)
    fails = [x for x in vs if lo <= x[0] <= now and x[2]["result"] == "FAIL"]
    # vazio → a FAIL with no reason is not a reviewer's rejection (it lands in other_fail, as in third-state-report.py); the reason is the dispatcher's own first line, "Reviewer N FAIL: ..." for a rejection
    rev = [x for x in fails if str(x[2].get("reason", "")).startswith("Reviewer")]
    rep["refusals"] = dict(classify(rev, args.bd, args.city), other_fail=len(fails) - len(rev))
    if rep["refusals"]["unread"]:
        rep["gaps"].append("%d recusa(s) SEM LEITURA do comentário do gate-run: não entram em classe nem em sem-rótulo" % rep["refusals"]["unread"])
    inv = rep["inventory"] = inventory(args, lo, now, rep["refusals"]["classes"])
    undated = sum(c["undated"] for by in inv["classes"].values() for c in by.values() if c)
    for gap, msg in ((inv["state"] != "ok", "inventário NÃO MEDIDO: %s" % inv["why"]), (inv["unmeasured"], "inventário: %d célula(s) store×classe NÃO MEDIDA(S)" % len(inv["unmeasured"])),
                     (undated, "inventário: %d bead(s) com created_at ilegível: a janela não os alcança" % undated)):
        if gap:
            rep["gaps"].append(msg)
    rep["complete"] = not rep["gaps"]
    f, stores = rep["first_attempt"], "NÃO MEDIDO (%s)" % inv["why"] if inv["state"] != "ok" else "%d store(s)%s" % (len(inv["stores"]), ", %d célula(s) NÃO MEDIDA(S)" % len(inv["unmeasured"]) if inv["unmeasured"] else "")
    fa = {"sem dado": "sem dado", "n<5": "n<5, sem conclusão (n=%d)" % f["n"]}.get(f["state"]) or "%.0f%% (%d/%d)" % (f["pct"], f["approved"], f["n"])
    r = rep["refusals"]
    rep["line"] = "gate-refusal-meter %dd até %s: 1ª tentativa %s · recusas %d = %d rotuladas + %d sem rótulo + %d SEM LEITURA (+%d outras FAIL) · inventário %s · %s" % (
        args.days, iso(now), fa, r["total"], r["labeled"], r["unlabeled"], r["unread"], r["other_fail"], stores, "COMPLETO" if rep["complete"] else "INCOMPLETO")
    return rep, 0


def render(rep):
    out, r, inv = [rep["line"]], rep["refusals"], rep["inventory"]
    if r is None:
        return out
    out += ["  classe %-32s %3d recusa(s) em %d bead(s)" % (n, c["refusals"], c["beads"]) for n, c in sorted(r["classes"].items(), key=lambda x: (-x[1]["refusals"], x[0]))]
    out += ["  sem rótulo %3d× %s (ex.: %s)" % (g["refusals"], g["key"], g["example"]["bead"]) for g in r["unlabeled_groups"]]
    if r["unlabeled_groups_total"] > len(r["unlabeled_groups"]):
        out.append("  … mais %d grupo(s) sem rótulo só no JSON" % (r["unlabeled_groups_total"] - len(r["unlabeled_groups"])))
    out += ["  inventário %-32s %s" % (n, " · ".join("%s %s" % (s, "NÃO MEDIDO" if c is None else "%d (+%d na janela)" % (c["total"], c["in_window"])) for s, c in by.items())) for n, by in inv["classes"].items()]
    return out + ["  ⚠ " + g for g in rep["gaps"]]


def save(city, ext, body):
    """Replace .gc/gate-refusal-meter.last.<ext> atomically (temp file + rename); on failure the temp file is removed (best effort) and OSError is raised."""
    dst = os.path.join(city, ".gc", "gate-refusal-meter.last." + ext)
    tmp = "%s.tmp.%d" % (dst, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(body)
        os.replace(tmp, dst)
    except OSError:
        with contextlib.suppress(OSError):
            os.remove(tmp)
        raise


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--now")
    ap.add_argument("--city", default=os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or DEFAULT_CITY)
    ap.add_argument("--bd", default=os.environ.get("GATE_REFUSAL_BD") or "bd")
    ap.add_argument("--gc", default=os.environ.get("GATE_REFUSAL_GC") or "gc")
    ap.add_argument("--class", dest="class_", action="append", default=[])
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--save", action="store_true")
    try:
        args = ap.parse_args(argv)
        if not 1 <= args.days <= 3650 or not all(re.fullmatch(NAME, c) for c in args.class_):
            raise ValueError("uso")
        now = parse_ts(args.now) if args.now else datetime.datetime.now(UTC).replace(microsecond=0)
    except (SystemExit, ValueError):
        sys.stderr.write(USAGE + "\n")
        return 64
    rep, rc = measure(args, now)
    body, text = json.dumps(rep, ensure_ascii=False, sort_keys=True, indent=1) + "\n", "\n".join(render(rep)) + "\n"
    sys.stdout.write(body if args.json else text)
    if args.save:  # also a NÃO SEI report: the saved file must never keep last week's numbers looking current
        try:
            save(args.city, "json", body)
            save(args.city, "txt", text)
        except OSError as e:
            sys.stderr.write("não consegui gravar o relatório: %s\n" % e)
            return rc or 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
