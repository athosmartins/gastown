#!/usr/bin/env python3
"""auto-melhoria-weekly.py — ga-mw5gdyu.4 (auto-melhoria, fatia 4): the weekly summary of the «recusas → checagens» cycle, for Athos. 3 to 5 lines in Portuguese, through `notify` AND a mail to the Mayor: how the first-attempt approval moved (this week x the one
before), which root classes the gate refused, which checks were asked for, entered the A/B, were promoted or switched off. The cycle's REPORTER: it reads the .1 meter, the .2 registry and bead store and the .3 confs and writes nothing of theirs; it asks nothing (a
product decision that comes up goes through a bead with athos.acao, never through this message). Dry-run by default (prints the text); --apply sends. Runbook: docs/runbooks/auto-melhoria-weekly.md.

WEEK      [now-7d, now] and [now-14d-1s, now-7d-1s], both through the meter's own measure(): a first attempt means here what it means everywhere, and a first verdict on the boundary falls in exactly one week. measure() also runs the meter's inventory: its result is not used here and its gaps are not ours.
CHECKS    asked = beads of the .2 loop (label auto-melhoria:checagem) created in the week. entered / promoted / switched off = the `# ratchet {json}` record in the conf of each `em-teste` registry row whose `since` is the trial the conf records, by the record's own
          `entrou` / `em` time. No conf yet = the ratchet has not entered it (nothing to count); a conf that cannot be read, is not the ratchet's, or decided without a readable time is `sem leitura`, never a zero.
THREE STATES  each piece is measured / "sem dado" / NÃO MEDIDO (with why). A piece that fails does not stop the others and the report still goes: a blind week is not a quiet week. `complete` is false and the exit is 2 whenever something was not measured (1 when a channel failed too: a report that did not arrive is the worse news).
SILENCE   nothing is sent from NIGHT_START_HOUR to NIGHT_END_HOUR local (00h-08h, end exclusive: the calendar math of quiet_hours.py, one definition of "quiet" for the city). The live level file is NOT asked: it can still say QUIET for minutes after 08:00 and would
          hold the one weekly run. A window that cannot be read holds the report (exit 2). A held run is not retried: run it by hand after the window.
EXIT  0 reported (printed, or sent in full) and everything measured · 1 a channel did not take it (the other one was still tried) · 2 something not measured, or the window unreadable · 64 usage · 70 an exception nobody planned (also a meter whose report changed shape: compose() comes before the send, so nothing goes out)."""
import argparse
import calendar
import datetime
import importlib.util
import json
import math
import os
import re
import subprocess
import sys
import time
import traceback
import types

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SLICE, SCHEMA, UTC = "ga-mw5gdyu.4", 1, datetime.timezone.utc
WEEK, SECOND = datetime.timedelta(days=7), datetime.timedelta(seconds=1)
CALL_TIMEOUT, SEND_TIMEOUT, TOP, PRIO, TITLE, Z = 60, 30, 3, "3", "Auto-melhoria da semana", 1.96
DEFAULT_CITY = "/Users/athos/gt/.gascity-gastown-hq"
USAGE = "uso: auto-melhoria-weekly.py [--apply] [--json] [--now AAAA-MM-DDTHH:MM:SSZ] [--city DIR] [--bd BIN] [--gc BIN] [--notify BIN] [--mayor ENDEREÇO]"
LOG_STATE = {"absent": "ausente", "unreadable": "ilegível", "empty": "sem nenhum veredito"}


def load(name, path):
    """A sibling as a module, or None (missing, syntax error, anything the import raises): that piece is then NÃO MEDIDO and the others still run."""
    # vazio → n/a (a file is never "empty" here); falhou/ilegível → None
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:  # noqa: BLE001 - any failure to import is the same answer: not usable
        return None


M = load("gate_refusal_meter", os.path.join(HERE, "gate-refusal-meter.py"))  # the .1 meter, the cycle's evaluator: only read
R = load("gate_checks_ratchet", os.path.join(HERE, "gate-checks-ratchet.py"))  # the .3 ratchet: its record reader, with the .2 registry reader (R.P) and the conf reader (R.T) it loads
Q = load("quiet_hours", os.path.join(HERE, "quiet_hours.py"))  # the silence window's calendar math


def run(argv, timeout):
    """-> (rc, stdout); (None, "") when the command could not run, timed out or cannot take that argument."""
    # vazio → (rc, ""): it ran and printed nothing; falhou → (None, ""): not run / timed out / a NUL in an argument (ValueError): every caller reads it as "could not tell", never as an empty answer
    try:
        p = subprocess.run(argv, capture_output=True, text=True, errors="replace", timeout=timeout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None, ""
    return p.returncode, p.stdout


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def local(t, fmt):
    return time.strftime(fmt, time.localtime(calendar.timegm(t.timetuple())))


def meter(args, t):
    """-> (report, why): what the .1 meter says about the 7 days ending `t`; (None, why) when it did not load or raised."""
    # vazio → n/a (a report is never empty); falhou → (None, why): a meter that did not load, or whose measure() raised, is NÃO MEDIDO here and never a made-up number
    if M is None:
        return None, "medidor não carregou"
    try:
        return M.measure(types.SimpleNamespace(days=7, city=args.city, bd=args.bd, gc=args.gc, class_=[]), t)[0], ""
    except Exception as e:  # noqa: BLE001 - whatever the meter raises is this piece's NÃO MEDIDO; the others still run
        return None, "medidor falhou (%s)" % type(e).__name__


def approval(rep, why):
    """-> (first_attempt, why): None = NÃO MEDIDO (no report, or the meter could not read its gate log: it then has no first_attempt)."""
    if rep is None:
        return None, why
    f = rep["first_attempt"]
    return (f, "") if f is not None else (None, "quality-gate.jsonl %s" % LOG_STATE.get(rep["gate_log"]["state"], rep["gate_log"]["state"]))


def fmt(f):
    return "sem dado" if f["n"] == 0 else "n<5 (n=%d)" % f["n"] if f["state"] != "ok" else "%.0f%% (%d/%d)" % (f["pct"], f["approved"], f["n"])


def noise(fc, fp):
    """True when two weeks' approval rates (both with n >= 5) differ by no more than chance explains: inside the 95% interval of the difference of two proportions. two weeks of ~50 beads each differ by up to ~19 points on luck alone, and Athos must not read that as the cycle working."""
    a, b = fc["approved"] / fc["n"], fp["approved"] / fp["n"]
    return abs(a - b) <= Z * math.sqrt(a * (1 - a) / fc["n"] + b * (1 - b) / fp["n"])


def requested(args, lo, now):
    """-> {state ok|nao-medido, why, n, classes, unknown}: beads of the .2 loop created in [lo, now]."""
    # vazio → ok with n=0 (the list answered and nothing was asked for this week: a real zero); falhou/ilegível → nao-medido (+why): no run/timeout, rc != 0, bad JSON, a shape that is not a list or {"issues": [...]}, or a bead with no readable labels; a bead whose created_at cannot be read goes to `unknown`
    out = {"state": "ok", "why": "", "n": 0, "classes": [], "unknown": 0}
    if R is None or R.P is None:
        return dict(out, state="nao-medido", why="catraca não carregou")
    rc, text = run([args.bd, "-C", args.city, "list", "--label", R.P.LABEL_LOOP, "--status", "all", "--json", "--limit", "0"], CALL_TIMEOUT)
    if rc != 0:
        return dict(out, state="nao-medido", why="bd não rodou ou estourou o prazo" if rc is None else "bd falhou (rc=%s)" % rc)
    try:
        d = json.loads(text, strict=False)
    except ValueError:
        return dict(out, state="nao-medido", why="resposta do bd ilegível")
    items = d if isinstance(d, list) else d.get("issues") if isinstance(d, dict) else None
    if not isinstance(items, list) or not all(isinstance(b, dict) and isinstance(b.get("labels"), list) for b in items):
        return dict(out, state="nao-medido", why="resposta do bd ilegível")
    for b in items:
        t = R.try_ts(b.get("created_at"))
        if t is None:
            out["unknown"] += 1
        elif lo <= t <= now:
            out["n"] += 1
            out["classes"] += [x for x in (l[len(R.P.LABEL_CLASS):] for l in b["labels"] if isinstance(l, str) and l.startswith(R.P.LABEL_CLASS)) if re.fullmatch(R.P.NAME, x)]
    out["classes"].sort()
    return out


def record(args, stem):
    """-> (record, why): the ratchet's record in the conf of `stem`. ("absent", "") = no conf yet (the ratchet has not entered the class); (None, why) = a conf that cannot be read or is not the ratchet's."""
    # vazio → ("absent", ""): no conf file; falhou/ilegível → (None, why): an unreadable or invalid conf, a damaged `# ratchet` line, or a conf without that line (somebody else's)
    st, _mode, _pct, notes = R.T.read_conf(os.path.join(args.city, ".gc"), stem)
    if st == "absent":
        return "absent", ""
    rec, why = R.record_of(notes) if st == "ok" else (None, "conf %s" % st)
    return (rec, "") if rec else (None, why or "a conf não é do ciclo")


def ratchet(args, lo, now):
    """-> {state ok|nao-medido, why, entrou, promovida, desligada, unknown}: what the ratchet did to each `em-teste` class in [lo, now], by the record in its conf."""
    # vazio → ok with empty lists (no em-teste row, or no conf written yet: nothing happened); falhou/ilegível → nao-medido (+why) when the registry or a sibling cannot be read; a class whose conf cannot be read, is not the ratchet's or has no readable decision time, and a registry row the reader could not take (`problems`), are `unknown`, and the rest still count
    out = {"state": "ok", "why": "", "entrou": [], "promovida": [], "desligada": [], "unknown": []}
    if R is None or R.P is None or R.T is None:
        return dict(out, state="nao-medido", why="catraca não carregou")
    st, regs, problems = R.P.read_registry(os.path.join(args.city, R.P.REGISTRY_REL))
    if st != "ok":
        return dict(out, state="nao-medido", why="registro " + {"absent": "ausente", "unreadable": "ilegível"}.get(st, "sem cabeçalho"))
    out["unknown"] += problems
    for cls, row in sorted(regs.items()):
        if row["status"] != "em-teste":
            continue
        stem, _, why = R.T.stem_of(row["check"])
        rec, why = (None, why) if stem is None else record(args, stem)
        if rec == "absent":
            continue
        if rec is None:
            out["unknown"].append("%s: %s" % (cls, why))
            continue
        if rec["since"] != row["since"]:  # the record of an older trial of this class: the ratchet will enter it again, nothing happened to the new one
            continue
        if lo <= R.try_ts(rec["entrou"]) <= now:
            out["entrou"].append(cls)
        dec = R.try_ts(rec.get("em")) if rec["fase"] != "trial" else None
        if rec["fase"] != "trial" and dec is None:
            out["unknown"].append("%s: decisão sem hora legível" % cls)
        elif dec is not None and lo <= dec <= now:
            out[rec["fase"]].append(cls)
    return out


def silent(now):
    """-> True inside the silence window, False outside, None = NÃO SEI (the caller holds the report)."""
    # vazio → n/a (a clock always answers); falhou/ilegível → None: quiet_hours.py did not load, or NIGHT_START_HOUR / NIGHT_END_HOUR is not a number
    if Q is None:
        return None
    t = calendar.timegm(now.timetuple())
    try:
        return Q.window_overlap_seconds(t, t + 1) > 0
    except ValueError:
        return None


def plural(n, one, many):
    return "%d %s" % (n, one if n == 1 else many)


def names(xs):
    return " (%s)" % ", ".join(xs[:TOP] + (["+%d" % (len(xs) - TOP)] if len(xs) > TOP else [])) if xs else ""


def compose(cur, prev, q, r):
    """-> (lines, complete): the 3 lines of the report (+1 warning when the gate log may be hiding verdicts) and whether every piece was measured."""
    (fc, why_c), (fp, why_p) = approval(*cur), approval(*prev)
    ref = cur[0]["refusals"] if cur[0] else None  # None together with fc: the meter has a refusals block exactly when it read its gate log
    if fc is None:
        l1 = "1ª tentativa: NÃO MEDIDO (%s)" % why_c
    elif fp is None:
        l1 = "1ª tentativa: %s; semana anterior NÃO MEDIDA (%s)" % (fmt(fc), why_p)
    else:
        d = int("%.0f" % fc["pct"]) - int("%.0f" % fp["pct"]) if fc["state"] == fp["state"] == "ok" else None  # the change is the one between the two numbers as printed
        l1 = "1ª tentativa: %s vs %s na semana anterior%s" % (fmt(fc), fmt(fp), "" if d is None else " (igual)" if d == 0 else " (%+d pts%s)" % (d, ", dentro do ruído" if noise(fc, fp) else ""))
    if ref is None:
        l2 = "Recusas do portão: NÃO MEDIDO (%s)" % why_c  # no refusals block only when the meter gave no report at all or could not read its gate log: why_c says which
    else:
        cl = sorted(ref["classes"].items(), key=lambda x: (-x[1]["refusals"], x[0]))
        top = ", ".join("%s %d" % (n, c["refusals"]) for n, c in cl[:TOP]) + (", +%d classe(s)" % (len(cl) - TOP) if len(cl) > TOP else "")
        l2 = "Recusas do portão: %d (%d com classe-raiz%s)%s" % (ref["total"], ref["labeled"], ", %d sem leitura" % ref["unread"] if ref["unread"] else "", " · " + top if top else "")
    seg = ["pedidas NÃO MEDIDO (%s)" % q["why"] if q["state"] != "ok" else plural(q["n"], "pedida", "pedidas") + names(q["classes"])]
    seg += ["em teste/promovidas/desligadas NÃO MEDIDO (%s)" % r["why"]] if r["state"] != "ok" else [plural(len(r["entrou"]), "entrou em teste", "entraram em teste") + names(r["entrou"]),
                                                                                                   plural(len(r["promovida"]), "promovida", "promovidas") + names(r["promovida"]), plural(len(r["desligada"]), "desligada", "desligadas") + names(r["desligada"])]
    unknown = q["unknown"] + len(r["unknown"])
    seg += ["%d sem leitura" % unknown] if unknown else []
    dmg = max([g["bad_maybe_in_window"] + g["unusable"] for g in (x["gate_log"] for x in (cur[0], prev[0]) if x)] or [0])
    lines = [l1, l2, "Checagens: " + " · ".join(seg)] + (["⚠ quality-gate.jsonl: %d linha(s) ilegível(is) ou veredito(s) sem ts/bead podem ser da semana: os números podem estar subestimados" % dmg] if dmg else [])
    return lines, bool(fc and fp and q["state"] == "ok" and r["state"] == "ok" and not unknown and not dmg)


def deliver(args, title, subject, body):
    """-> {notify, mail}: enviado | falhou | nao-rodou. Each channel is tried whatever the other did: a mail that fails must not eat the notify, nor the reverse."""
    # vazio → n/a (a send); falhou → falhou (rc != 0) / nao-rodou (no run, or timed out: the message MAY have left, so it is not read as "not sent")
    out = {}
    for ch, argv in (("notify", [args.notify, "-t", title, "-p", PRIO, body]), ("mail", [args.gc, "mail", "send", args.mayor, "-s", subject, "-m", body])):
        rc, _ = run(argv, SEND_TIMEOUT)
        out[ch] = "enviado" if rc == 0 else "nao-rodou" if rc is None else "falhou"
    return out


def status(args, rep):
    held, d, at = rep["silence"]["held"], rep["delivery"], rep["silence"]["local"]
    if held is None:
        return "adiado: não consegui ler a janela de silêncio (quiet_hours.py ou NIGHT_START_HOUR/NIGHT_END_HOUR); nada foi enviado"
    if held:
        return "%s: %s local está na janela de silêncio (00h-08h por padrão); nada foi enviado" % ("adiado" if args.apply else "dry-run: --apply adiaria", at)
    return "dry-run: nada foi enviado; --apply manda notify + mail ao Mayor" if d is None else "notify %s · mail %s" % (d["notify"], d["mail"])


class Parser(argparse.ArgumentParser):
    def error(self, message):  # argparse would print its own usage and exit 2 (NÃO SEI's code): every bad flag is exit 64 with ONE usage line
        raise ValueError(message)


def main(argv=None):
    ap = Parser(add_help=False)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--now")
    ap.add_argument("--city", default=os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or DEFAULT_CITY)
    ap.add_argument("--bd", default=os.environ.get("GATE_REFUSAL_BD") or "bd")
    ap.add_argument("--gc", default=os.environ.get("GATE_REFUSAL_GC") or "gc")
    ap.add_argument("--notify", default=os.environ.get("NOTIFY_BIN") or os.path.expanduser("~/.local/bin/notify"))
    ap.add_argument("--mayor", default="mayor")
    try:
        args = ap.parse_args(argv)
        now = datetime.datetime.strptime(args.now, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC) if args.now else datetime.datetime.now(UTC).replace(microsecond=0)
    except ValueError:
        sys.stderr.write(USAGE + "\n")
        return 64
    return cycle(args, now)


def cycle(args, now):
    """One run: the week x the one before, the checks, the silence window, then (--apply, outside the window) the send. -> the exit code."""
    lo = now - WEEK
    cur, prev = meter(args, now), meter(args, now - WEEK - SECOND)
    q, r = requested(args, lo, now), ratchet(args, lo, now)
    lines, complete = compose(cur, prev, q, r)
    held, message = silent(now), "\n".join(lines)
    subject = "Auto-melhoria: resumo da semana %s a %s" % (local(lo, "%d/%m"), local(now, "%d/%m"))
    rep = {"schema": SCHEMA, "slice": SLICE, "mode": "apply" if args.apply else "dry-run", "now": iso(now), "window": {"from": iso(lo), "to": iso(now)}, "silence": {"held": held, "local": local(now, "%H:%M")},
           "weeks": {k: approval(*x)[0] for k, x in (("cur", cur), ("prev", prev))}, "refusals": cur[0]["refusals"] if cur[0] else None, "checks": {"requested": q, "ratchet": r}, "evaluator": cur[0]["evaluator"] if cur[0] else None,
           "complete": complete, "title": TITLE, "subject": subject, "message": message, "delivery": deliver(args, TITLE, subject, message) if args.apply and held is False else None}
    sys.stdout.write(json.dumps(rep, ensure_ascii=False, sort_keys=True, indent=1) + "\n" if args.json else "%s\n%s\n%s\n" % (TITLE, message, status(args, rep)))
    return 1 if rep["delivery"] and set(rep["delivery"].values()) != {"enviado"} else 2 if held is None or not complete else 0


def entry(argv=None):
    """main() with a net under it: an exception nobody planned is exit 70 with the traceback on stderr, so exit 1 keeps its one meaning (a channel did not take the report)."""
    try:
        return main(argv)
    except Exception:  # noqa: BLE001 - anything unplanned is a bug of this script: say so loudly
        sys.stderr.write("auto-melhoria-weekly: ERRO INESPERADO (bug do script). Se foi depois do envio, notify e mail podem ter saído.\n%s" % traceback.format_exc())
        return 70


if __name__ == "__main__":
    sys.exit(entry())
