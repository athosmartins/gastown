#!/usr/bin/env python3
"""third-state-report.py — ga-57e7l0.2 (fatia 3/3): first-attempt approval and the third-state share of rejections, per path and per arm.

Read-only: reads .gc/quality-gate.jsonl, .gc/e12-roster.jsonl, the optional slice-2 files and `bd comments` of the failed gate runs. It writes
no bead and sends no mail (--save writes ONE text file under .gc/ and the answered-reads cache).

Definitions
  first attempt   the FIRST real gate verdict of a bead (event dispatcher_complete, dry_run != 1, result PASS|FAIL) over the whole log; a bead
                  counts in the window when that first verdict falls inside it. Approved = that verdict is PASS.
  rejection       a FAIL verdict inside the window whose reason is a reviewer's ("Reviewer ..."). "Merge failed after all-PASS" and "source bead
                  closed" are FAILs too, but nobody rejected the code: they are counted apart and stay out of the share.
  third state     the blocking part of the gate-run comment ("Blocking reasons:" up to "Non-blocking findings:") carries root-class:error-vs-empty,
                  or the manual ledger (assets/third-state-manual.tsv) says so for that bead and UTC day. The two sources are shown apart.

THREE STATES everywhere, never two: data / no data ("sem dado") / do not know ("NÃO SEI" or "sem leitura"). A file that cannot be read is never
"0 beads"; a gate run whose comments cannot be read is never "not third state"; an unparseable log line is counted, never dropped; a cell with
fewer than 5 observations prints "n<5, sem conclusão", never a clean percentage.

Exit: 0 = report printed (cells may still be "sem dado"/"sem leitura"); 2 = NÃO SEI (the gate log is absent, unreadable or empty); 64 = usage.
"""
import argparse
import collections
import concurrent.futures
import datetime
import json
import os
import re
import subprocess
import sys
import time

MIN_N = 5
LABEL = "root-class:error-vs-empty"
GOAL_FIRST, GOAL_THIRD = 60.0, 30.0
BASELINE = "14/10 (linha de base): 1ª tentativa 36% (4/11); FAIL em 52% dos vereditos; ~85% das reprovações por 3º estado (6 de 7)."
UTC = datetime.timezone.utc
BRT = datetime.timezone(datetime.timedelta(hours=-3))
TS_RE = re.compile(r'"ts"\s*:\s*"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)"')
HERE = os.path.dirname(os.path.abspath(__file__))


def parse_ts(s):
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


def read_jsonl(path):
    """-> ("ok", rows, bad, bad_ts) | ("absent", ...) | ("unreadable", ...). bad = unparseable non-blank lines; bad_ts = their ts when still legible."""
    # vazio → ("ok", [], 0, []): a real empty file; falhou/ilegível → "absent" (ENOENT) or "unreadable" (any other error), never an empty list
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
        if m:
            bad_ts.append(parse_ts(m.group(1)))
    return "ok", rows, bad, bad_ts


def read_ledger(path):
    """-> (state, {(bead, day): class}, bad). Columns: bead TAB UTC-day TAB 3o-estado|outro TAB source; '#' lines and blanks are skipped."""
    # vazio → ("ok", {}, 0): no manual classification, the label alone decides; falhou/ilegível → "absent"/"unreadable" (printed), and a row
    # that does not parse is counted in bad — never read as "outro"
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        return "absent", {}, 0
    except (OSError, ValueError):
        return "unreadable", {}, 0
    out, bad = {}, 0
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        f = line.split("\t")
        if len(f) >= 3 and f[2].strip() in ("3o-estado", "outro") and re.fullmatch(r"\d{4}-\d\d-\d\d", f[1].strip()):
            out[(f[0].strip(), f[1].strip())] = f[2].strip()
        else:
            bad += 1
    return "ok", out, bad


def arm_map(path):
    """-> (state, {bead: arm}, bad) from a roster-style jsonl ({"bead","arm"}); the first row of a bead wins (its original assignment)."""
    # vazio → ("ok", {}, 0): nobody enrolled; falhou/ilegível → the state says absent/unreadable and the caller prints NÃO SEI, not "everyone out"
    st, rows, bad, _ = read_jsonl(path)
    arms = {}
    for r in rows:
        b, a = r.get("bead"), r.get("arm")
        if isinstance(b, str) and isinstance(a, str) and b not in arms:
            arms[b] = a
        elif not (isinstance(b, str) and isinstance(a, str)):
            bad += 1
    return st, arms, bad


def verdicts(rows):
    """Real PASS/FAIL gate verdicts with a usable bead and ts, sorted by time. -> (list, no_ts, other_results, dry)."""
    out, no_ts, other, dry = [], 0, 0, 0
    for i, d in enumerate(rows):
        if d.get("event") != "dispatcher_complete":
            continue
        if str(d.get("dry_run")) == "1":
            dry += 1
            continue
        if d.get("result") not in ("PASS", "FAIL"):
            other += 1
            continue
        try:
            t = parse_ts(d["ts"])
        except (KeyError, TypeError, ValueError):
            t = None
        if t is None or not isinstance(d.get("bead"), str):
            no_ts += 1
            continue
        out.append((t, i, d))
    out.sort(key=lambda x: (x[0], x[1]))
    return out, no_ts, other, dry


def blocking_part(text):
    """The text between 'Blocking reasons:' and 'Non-blocking findings:' (or the end); None if the comment has no blocking part."""
    # vazio → None (this comment says nothing about blocking; it is not "no blocking issue"); the caller decides what no comment at all means
    i = text.find("Blocking reasons:")
    if i < 0:
        return None
    j = text.find("Non-blocking findings:", i)
    return text[i:j if j >= 0 else len(text)]


def read_gate_run(bd, city, gate_run, timeout, deadline):
    """-> "3o-estado" | "outro" | None. None = could NOT tell (bd failed/timed out, unparseable output, no blocking part, out of time)."""
    # vazio → None: a gate run with no comment carrying a blocking part is unread, not "outro"; falhou/ilegível → None as well (a non-zero exit,
    # a timeout, bad JSON and the deadline having passed are all "sem leitura"); only a readable blocking part is an answer
    if time.monotonic() > deadline:
        return None
    try:
        p = subprocess.run([bd, "-C", city, "comments", gate_run, "--json"], capture_output=True, text=True, timeout=timeout)
        if p.returncode != 0:
            return None
        comments = json.loads(p.stdout, strict=False)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    if not isinstance(comments, list):
        return None
    parts = [blocking_part(c["text"]) for c in comments if isinstance(c, dict) and isinstance(c.get("text"), str)]
    parts = [x for x in parts if x is not None]
    if not parts:
        return None
    return "3o-estado" if any(LABEL in x for x in parts) else "outro"


def load_cache(path):
    # vazio → {} (nothing answered yet); falhou/ilegível → {} too, but only because the cache holds ANSWERS: losing it costs time, never a number
    try:
        with open(path, encoding="utf-8") as fh:
            c = json.load(fh)
    except (OSError, ValueError):
        return {}
    return {k: v for k, v in c.items() if v in ("3o-estado", "outro")} if isinstance(c, dict) else {}


def classify(rej, ledger, cache, args, city):
    """-> {id(rec): (class, via)}; class in 3o-estado|outro|desconhecido, via in manual|rotulo|-. Only answered reads enter the cache."""
    res, todo = {}, {}
    for t, _, d in rej:
        man = ledger.get((d["bead"], d["ts"][:10]))
        run = d.get("gate_run")
        if man:
            res[id(d)] = (man, "manual")
        elif not isinstance(run, str) or not run:
            res[id(d)] = ("desconhecido", "-")
        elif run in cache:
            res[id(d)] = (cache[run], "rotulo")
        elif args.no_classify:
            res[id(d)] = ("desconhecido", "-")
        else:
            todo[run] = None
    deadline = time.monotonic() + args.deadline_s
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(read_gate_run, args.bd, city, run, args.timeout_s, deadline): run for run in todo}
        for f in concurrent.futures.as_completed(futs):
            todo[futs[f]] = f.result()
    cache.update({r: v for r, v in todo.items() if v})
    for t, _, d in rej:
        if id(d) not in res:
            v = todo.get(d["gate_run"])
            res[id(d)] = (v, "rotulo") if v else ("desconhecido", "-")
    return res


def pct(a, b):
    return 100.0 * a / b


def first_cell(c):
    n, p = c["n"], c["pass"]
    if n == 0:
        return "sem dado", "-"
    if n < MIN_N:
        return "n<5, sem conclusão (n=%d)" % n, "-"
    v = pct(p, n)
    return "%.0f%% (%d/%d)" % (v, p, n), ("atinge" if v >= GOAL_FIRST else "NÃO atinge")


def third_cell(c):
    t, o, u = c["third"], c["outro"], c["unk"]
    n = t + o
    note = " · sem leitura: %d" % u if u else ""
    if n + u == 0:
        return "sem dado", "-"
    if n < MIN_N:
        return "n<5, sem conclusão (n=%d)%s" % (n, note), "-"
    v = pct(t, n)
    if not u:
        return "%.0f%% (%d/%d)" % (v, t, n), ("atinge" if v < GOAL_THIRD else "NÃO atinge")
    lo, hi = pct(t, n + u), pct(t + u, n + u)
    verdict = "atinge" if hi < GOAL_THIRD else ("NÃO atinge" if lo >= GOAL_THIRD else "sem conclusão")
    return "%.0f%% (%d/%d), faixa %.0f–%.0f%%%s" % (v, t, n, lo, hi, note), verdict


def tally(groups, first, rej, cls, key):
    """groups: names in print order. key(bead) -> group name. Returns {group: counters}."""
    cells = {g: collections.Counter() for g in groups}
    for b, d in first:
        c = cells[key(b)]
        c["n"] += 1
        c["pass"] += d["result"] == "PASS"
    for t, _, d in rej:
        c = cells[key(d["bead"])]
        k = cls[id(d)][0]
        c["third" if k == "3o-estado" else "outro" if k == "outro" else "unk"] += 1
    return cells


def table(title, cells, why_blank=None):
    rows = [title, "  %-30s %-34s %-12s %-52s %s" % ("célula", "1ª tentativa aprovada", "meta ≥60%", "reprovações por 3º estado", "meta <30%")]
    for g, c in cells.items():
        a, av = first_cell(c)
        b, bv = third_cell(c)
        rows.append("  %-30s %-34s %-12s %-52s %s" % (g, a, av, b, bv))
    if why_blank:
        rows.append("  " + why_blank)
    return rows


def build(args, city):
    gc = os.path.join(city, ".gc")
    # vazio → a log with no readable row is NÃO SEI (exit 2), not "0 beads"; falhou/ilegível → absent/unreadable are NÃO SEI (exit 2) too
    st, rows, bad, bad_ts = read_jsonl(os.path.join(gc, "quality-gate.jsonl"))
    if st != "ok" or not rows:
        why = {"absent": "o arquivo não existe", "unreadable": "o arquivo não pôde ser lido"}.get(st, "o arquivo está vazio ou sem nenhuma linha legível")
        return ["NÃO SEI: %s (%s). Nada foi contado — isto NÃO é 0 beads nem 0%%." % (why, os.path.join(gc, "quality-gate.jsonl"))], 2
    now = parse_ts(args.now) if args.now else datetime.datetime.now(UTC).replace(microsecond=0)
    lo = now - datetime.timedelta(days=args.days)
    vs, no_ts, other, dry = verdicts(rows)
    seen, first = set(), []
    for t, _, d in vs:
        if d["bead"] not in seen:
            seen.add(d["bead"])
            if lo <= t <= now:
                first.append((d["bead"], d))
    inwin = [(t, i, d) for t, i, d in vs if t >= lo and t <= now]
    rej = [x for x in inwin if x[2]["result"] == "FAIL" and str(x[2].get("reason", "")).startswith("Reviewer")]
    nonrev = sum(1 for x in inwin if x[2]["result"] == "FAIL") - len(rej)

    # vazio → no manual rows, the label alone decides; falhou/ilegível → a NÃO SEI line is printed and the label alone decides
    lst, ledger, lbad = read_ledger(args.ledger)
    cache_path = os.path.join(gc, "third-state-report.cache.json")
    # vazio → nothing answered yet, every failed gate run is read; falhou/ilegível → same (the cache holds answers only), never a number
    cache = load_cache(cache_path)
    cls = classify(rej, ledger, cache, args, city)
    if not args.no_classify:
        try:
            tmp = cache_path + ".tmp.%d" % os.getpid()
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(cache, fh)
            os.replace(tmp, cache_path)
        except OSError as e:
            sys.stderr.write("aviso: não gravei o cache (%s); só custa tempo na próxima rodada, nenhum número muda\n" % e)

    # vazio → nobody enrolled: every bead is "fora do roster"; falhou/ilegível → path and E12 arm print NÃO SEI, never "fora do roster"
    rst, roster, rbad = arm_map(os.path.join(gc, "e12-roster.jsonl"))
    out = ["Relatório do 3º estado — janela %s → %s UTC (%d dias; BRT %s)" % (lo.strftime("%Y-%m-%d %H:%M"), now.strftime("%Y-%m-%d %H:%M"), args.days, now.astimezone(BRT).strftime("%d/%m %H:%M")),
           BASELINE, "Meta (7 dias): reprovações por 3º estado <30%; 1ª tentativa aprovada ≥60%.", ""]
    inwin_bad = sum(1 for t in bad_ts if lo <= t <= now)
    out.append("Fonte: %d vereditos reais na janela (%d beads com 1ª tentativa na janela), %d reprovações de revisor, %d FAIL que não são rejeição de código (merge/bead fechado; fora do %%)." % (len(inwin), len(first), len(rej), nonrev))
    if bad:
        out.append("⚠ %d linhas ilegíveis no quality-gate.jsonl (fora da conta, mas contadas aqui); %d têm ts legível dentro da janela; as outras %d não dizem a que data pertencem — os números podem estar incompletos." % (bad, inwin_bad, bad - len(bad_ts)))
    if no_ts:
        out.append("⚠ %d registros de veredito sem ts/bead legível (fora da conta)." % no_ts)
    if other or dry:
        out.append("Fora da conta, por desenho: %d resultado(s) que não são PASS/FAIL (ex.: bead já fechado), %d dry-runs." % (other, dry))
    unk = sum(1 for v in cls.values() if v[0] == "desconhecido")
    if unk:
        out.append("⚠ %d reprovações sem leitura do comentário do gate-run (bd falhou, sem prazo ou gate-run sem parte bloqueante): ficam como 'sem leitura', nunca como 'não é 3º estado'." % unk)
    man = sum(1 for v in cls.values() if v[1] == "manual")
    lab = sum(1 for v in cls.values() if v[1] == "rotulo" and v[0] == "3o-estado")
    out.append("Classe 3º estado vem de: %d pelo rótulo %s na parte bloqueante, %d pela classificação manual (assets/third-state-manual.tsv)." % (lab, LABEL, man))
    if lst != "ok":
        out.append("⚠ NÃO SEI: ledger manual %s — só o rótulo decide (a classificação manual de 14/10 não entra)." % ("ausente" if lst == "absent" else "ilegível"))
    elif lbad:
        out.append("⚠ %d linhas ilegíveis no ledger manual (não aplicadas)." % lbad)
    out.append("")

    tot = tally(["todos"], first, rej, cls, lambda b: "todos")
    out += table("Total", tot)
    out.append("")
    if rst == "ok":
        pil = tally(["Pilot sling (no roster E12)", "fora do roster (pool/crew)"], first, rej, cls, lambda b: "Pilot sling (no roster E12)" if b in roster else "fora do roster (pool/crew)")
        note = "fora do roster = top-up, gate-fix, self-serve e crew juntos. Crew não é separável: nenhum registro liga o bead ao construtor (só o roster, que enrola o que o Pilot manda). Quem quiser a linha 'crew' precisa gravar o caminho no roster." + ("  ⚠ %d linhas ilegíveis no roster." % rbad if rbad else "")
        out += table("Por CAMINHO de entrega", pil, note)
        arms = sorted({a for a in roster.values()})
        names = ["E12 " + a for a in arms] + ["sem E12 (fora do roster)"]
        key = lambda b: ("E12 " + roster[b]) if b in roster else "sem E12 (fora do roster)"
        out += [""] + table("Por BRAÇO — E12 (treated_pct=100 desde 07/10: braço controle vazio, só histórico)", tally(names, first, rej, cls, key))
    else:
        out += ["Por CAMINHO e por BRAÇO E12: NÃO SEI — o roster .gc/e12-roster.jsonl está %s; sem ele não dá para dizer quais beads o Pilot despachou. Isto NÃO é 'ninguém no roster'." % ("ausente" if rst == "absent" else "ilegível")]
    out.append("")
    conf = os.path.join(gc, "third-state-reads.conf")
    # vazio → a conf that exists but is empty is "ligada" (the check exists); falhou/ilegível → ENOENT is "fatia 2 não ligada", any other stat error is
    # NÃO SEI (never folded into "não ligada")
    try:
        os.stat(conf)
        conf_state = "on"
    except FileNotFoundError:
        conf_state = "off"
    except OSError:
        conf_state = "unknown"
    if conf_state == "unknown":
        out += ["Por BRAÇO — checagem da fatia 2: NÃO SEI — não consegui nem consultar %s; não é o mesmo que 'fatia 2 não ligada'." % conf]
    elif conf_state == "off":
        out += ["Por BRAÇO — checagem da fatia 2 (enforce_pct): fatia 2 NÃO ligada (sem %s). Todo veredito desta janela é SEM a checagem; não há braço com/sem para comparar." % conf]
    else:
        # vazio → no bead recorded: all "sem registro de braço"; falhou/ilegível → NÃO SEI (conf on but the arm record cannot be read)
        ast, arms2, abad = arm_map(os.path.join(gc, "third-state-reads-arms.jsonl"))
        if ast != "ok":
            out += ["Por BRAÇO — checagem da fatia 2: NÃO SEI — a conf existe mas .gc/third-state-reads-arms.jsonl está %s; sem o registro por bead não dá para separar com/sem." % ("ausente" if ast == "absent" else "ilegível")]
        else:
            names2 = ["com a checagem (enforce)", "sem a checagem (holdout)", "sem registro de braço"]
            m = {"enforce": names2[0], "holdout": names2[1]}
            out += table("Por BRAÇO — checagem da fatia 2 (enforce_pct)", tally(names2, first, rej, cls, lambda b: m.get(arms2.get(b), names2[2])), ("⚠ %d linhas ilegíveis no registro de braços." % abad) if abad else None)
    return out, 0


def main():
    ap = argparse.ArgumentParser(description="1ª tentativa e % de FAIL de 3º estado por caminho e braço (somente leitura)")
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--city", default=os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or "/Users/athos/gt/.gascity-gastown-hq")
    ap.add_argument("--now", help="fim da janela, YYYY-MM-DDTHH:MM:SSZ (padrão: agora)")
    ap.add_argument("--no-classify", action="store_true", help="não chama bd: reprovações sem cache ficam 'sem leitura'")
    ap.add_argument("--save", action="store_true", help="grava também .gc/third-state-report.last.txt")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--timeout-s", type=int, default=60)
    ap.add_argument("--deadline-s", type=int, default=1200)
    ap.add_argument("--ledger", default=os.path.join(HERE, "third-state-manual.tsv"))
    ap.add_argument("--bd", default=os.environ.get("THIRD_STATE_BD", "bd"))
    try:
        args = ap.parse_args()
        if args.days < 1 or args.workers < 1:
            raise SystemExit(2)
        if args.now:
            parse_ts(args.now)
    except (SystemExit, ValueError) as e:
        if isinstance(e, SystemExit) and e.code == 0:
            return 0
        print("uso: third-state-report.py [--days N>=1] [--now YYYY-MM-DDTHH:MM:SSZ] [--city DIR] [--no-classify] [--save]", file=sys.stderr)
        return 64
    lines, rc = build(args, args.city)
    text = "\n".join(lines) + "\n"
    sys.stdout.write(text)
    if args.save:
        try:
            tmp = os.path.join(args.city, ".gc", "third-state-report.last.txt.tmp.%d" % os.getpid())
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write(text)
            os.replace(tmp, os.path.join(args.city, ".gc", "third-state-report.last.txt"))
        except OSError as e:
            sys.stderr.write("não consegui gravar o relatório: %s\n" % e)
            return rc or 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
