#!/usr/bin/env python3
"""gate-checks-ratchet.py — ga-mw5gdyu.3 (auto-melhoria, fatia 3): the ratchet. A check born from a .2 bead enters the gate's A/B on half of the submissions and is PROMOTED or SWITCHED OFF by itself. DRY-RUN by default; --apply acts. Runbook: docs/runbooks/gate-checks-ratchet.md.

STATE     the check's own conf, <stem>.conf, IS the state: its settings (enforce 50 in trial, enforce 100 promoted, mode=off switched off) and ONE comment line, `# ratchet {json}`, with the trial's key (class `since`), phase, entry time and, once decided, when, why and
          the numbers. Settings and record go in ONE atomic write, so there is no ledger to disagree with the conf and no half-decided state. A conf without that line is somebody else's: NÃO SEI, never overwritten. To restart a class delete its conf; to stop
          it for good set its registry row to desligada (the ratchet then leaves it alone) AND delete the conf (no conf = the check is not switched on). The registry (versioned) is not edited: the city tree only advances by pull --ff-only.
TRIAL     one per registry row `em-teste` whose `check` cell starts with <dir>/<stem>-check.py (see gate_check_trial.py), and no other row names that check (one conf per check). Entry = conf enforce 50 (the check reads it through gate_check_trial.resolve; `holdout` runs it as warn); a new `since` is a new trial.
DECISION  after 14 days or 30 beads with a run (whichever first), on the runs the check recorded since the entry: first-attempt approval per arm (the METER's own first_attempt, over the beads whose first verdict came after the check first ran on them) and false
          refusals = beads the check refused in the enforce arm whose cited point shows up WAIVED (`dispensados`) in a LATER run of the same bead: the author overrode it instead of fixing it (the meter has no ground truth for this). Promote iff approval(enforce)
          >= approval(holdout) and false refusals <= 10% of the refused beads and the check answered `nao-sei` (could not verify) on at most 20% of the runs of each arm (a blind check passes the first two for free); else switch off and say why. It needs
          >= 5 first-attempt beads per arm and >= 5 refused beads: with less, or with a check too blind to promote, it WAITS, and at --cap-days (28) it switches off for dados-insuficientes. It never decides on a read that failed OR was only partly readable:
          a gate log with a damaged line, or a verdict without a usable ts/bead, that may belong to the trial (the meter's rule: one whose ts is legible and older than the entry cannot) is NÃO SEI, and so is a runs file with a damaged line.
NEVER     edits the meter, its test, the ruler or the check: it writes only the conf of a class in trial.
Exit: 0 report · 1 a write failed · 2 NÃO SEI (registry, gate log, conf or runs unreadable or partly damaged, a conf that is not ours, a row outside the contract or sharing its check with another row; the other classes are still handled) · 64 usage · 70 unplanned."""
import argparse
import datetime
import importlib.util
import json
import os
import sys
import traceback

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SLICE, SCHEMA, UTC = "ga-mw5gdyu.3", 1, datetime.timezone.utc
DEFAULT_CITY = "/Users/athos/gt/.gascity-gastown-hq"
DAYS, MIN_SUBMISSIONS, CAP_DAYS, FALSE_MAX_PCT, UNKNOWN_MAX_PCT, PHASES = 14, 30, 28, 10, 20, ("trial", "promovida", "desligada")
USAGE = "uso: gate-checks-ratchet.py [--apply] [--json] [--days N>=1] [--min-submissions N>=1] [--cap-days N>=days] [--now AAAA-MM-DDTHH:MM:SSZ] [--city DIR]"


def load(name, path):
    """A sibling as a module, or None (missing, syntax error, anything the import raises): the caller says NÃO SEI, never runs with half the definitions."""
    # vazio → n/a (a file is never "empty" here); falhou/ilegível → None
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:  # noqa: BLE001 - any failure to import is the same answer: not usable
        return None


P = load("gate_refusal_checks", os.path.join(HERE, "gate-refusal-checks.py"))  # the .2 script: the registry reader
T = load("gate_check_trial", os.path.join(HERE, "..", "packs", "town-deltas", "assets", "gate_check_trial.py"))  # the A/B ruler of the checks in trial


def try_ts(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
    except (TypeError, ValueError):
        return None


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def expect(phase):
    """The (mode, pct) load_conf reads from the conf in each phase: the entry's split is the ruler's (T.TRIAL_PCT), the same number the arms of the runs are validated against."""
    return {"trial": ("enforce", T.TRIAL_PCT), "promovida": ("enforce", 100), "desligada": ("off", 100)}[phase]


def record_of(notes):
    """-> (record, why): the ratchet's own `# ratchet {json}` line of a conf. (None, "") = there is none (the conf is not ours); (None, why) = there is one and it is damaged."""
    for n in notes:
        if n.startswith("ratchet "):
            try:
                d = json.loads(n[8:])
            except ValueError:
                return None, "a linha `# ratchet` da conf não é JSON"
            if isinstance(d, dict) and d.get("v") == 1 and d.get("fase") in PHASES and isinstance(d.get("since"), str) and try_ts(d.get("entrou")):
                return d, ""
            return None, "a linha `# ratchet` da conf não tem o formato v1"
    return None, ""


def read_runs(path, stem):
    """-> (state, rows, bad): rows = [(dt, d)] in the order they were recorded (the file only grows), each a run of the contract whose arm is what the draw gives for that bead; bad = the line numbers (1-based, blank lines counted) of those that are not (a check that
    does not use the ruler is damage, not data). Lines are cut at "\\n" only: a raw U+2028 a stranger left inside a cited point is not a line break."""
    # vazio → ("ok", [], []) for an empty file, ("absent", [], []) when it does not exist; falhou/ilegível → "unreadable", never an empty list
    try:
        with open(path, "rb") as fh:
            lines = fh.read().decode("utf-8", errors="replace").split("\n")
    except FileNotFoundError:
        return "absent", [], []
    except OSError:
        return "unreadable", [], []
    rows, bad = [], []
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            d = json.loads(line)
        except ValueError:
            d = None
        if d is None or T.row_ok(d) or d["arm"] != T.arm_for(stem, d["bead"], T.TRIAL_PCT):
            bad.append(n)
        else:
            rows.append((try_ts(d["ts"]), d))
    return "ok", rows, bad


def measure(M, rows, vs, entry, now):
    """-> the evidence from the runs after `entry`. Approval = the meter's first_attempt over the beads whose FIRST verdict came after the check first ran on them (None when the gate log could not be read); a refusal is an `achados` run of the enforce
    arm, and it is false when a LATER run of that bead waives (`dispensados`) a point it cited; `unknown` = per arm, how many runs there were and how many of them the check answered `nao-sei` (it could not verify: it did nothing on that run)."""
    first_run, refused, waived, unknown = {}, {}, {}, {"enforce": [0, 0], "holdout": [0, 0]}
    for t, d in (r for r in rows if r[0] >= entry):
        first_run.setdefault(d["bead"], (t, d["arm"]))
        unknown[d["arm"]][0] += 1
        unknown[d["arm"]][1] += d["verdict"] == "nao-sei"
        if d["bead"] in refused:  # a refusal of this bead came strictly before this run
            waived[d["bead"]].update(d.get("dispensados", []))
        if d["arm"] == "enforce" and d["verdict"] == "achados":
            refused.setdefault(d["bead"], set()).update(d["pontos"])
            waived.setdefault(d["bead"], set())
    false = sorted(b for b in refused if refused[b] & waived[b])
    m = {"submissions": len(first_run), "enforce": None, "holdout": None, "refusals": {"beads": len(refused), "false": len(false)}, "false_beads": false[:5], "unknown": {a: {"runs": r, "nao_sei": k} for a, (r, k) in unknown.items()}, "min_n": M.MIN_N}
    if vs is not None:
        firsts = {}
        for v in vs:
            firsts.setdefault(v[2]["bead"], v)
        for arm in ("enforce", "holdout"):
            m[arm] = M.first_attempt([firsts[b] for b, (t, a) in first_run.items() if a == arm and b in firsts and firsts[b][0] >= t], entry, now)
    return m


def fmt(a):
    return "sem dado" if a["n"] == 0 else "n<5 (n=%d)" % a["n"] if a["state"] != "ok" else "%.0f%% (%d/%d)" % (a["pct"], a["approved"], a["n"])


def decide(m, days, args, gaps):
    """-> (verdict, why): em-andamento | aguardando-dados | promover | desligar | nao-sei. Not enough to judge = wait, and at the cap switch off; a gate log that could not be read is never "no data", and one that was only partly readable (`gaps`) is never "all of it"."""
    if days < args.days and m["submissions"] < args.min_submissions:
        return "em-andamento", "%.1f de %d dias, %d de %d beads com rodada" % (days, args.days, m["submissions"], args.min_submissions)
    enf, hold, ref, n, unk = m["enforce"], m["holdout"], m["refusals"], m["min_n"], m["unknown"]
    if enf is None:
        return "nao-sei", "o quality-gate.jsonl não pôde ser lido: sem a 1ª tentativa por braço nada é decidido"
    if gaps:
        return "nao-sei", "o quality-gate.jsonl está parcialmente ilegível (%s): a 1ª tentativa por braço pode estar errada e nada é decidido" % "; ".join(gaps)

    def wait(why):
        return ("desligar", "dados-insuficientes: " + why) if days >= args.cap_days else ("aguardando-dados", why)

    if enf["state"] != "ok" or hold["state"] != "ok":
        return wait("poucos beads de 1ª tentativa por braço (enforce %s, holdout %s; mínimo %d por braço)" % (fmt(enf), fmt(hold), n))
    cmp = "aprovação de 1ª tentativa enforce %s vs holdout %s; rodadas sem veredito da checagem (nao-sei) enforce %d/%d, holdout %d/%d" % (fmt(enf), fmt(hold), unk["enforce"]["nao_sei"], unk["enforce"]["runs"], unk["holdout"]["nao_sei"], unk["holdout"]["runs"])
    if enf["approved"] * hold["n"] < hold["approved"] * enf["n"]:
        return "desligar", cmp + ": MENOR no braço enforce"
    if ref["beads"] < n:
        return wait("%s; o braço enforce recusou %d bead(s), mínimo %d para medir a recusa falsa" % (cmp, ref["beads"], n))
    rate = "recusa falsa %d de %d bead(s) recusados (%.0f%%)" % (ref["false"], ref["beads"], 100.0 * ref["false"] / ref["beads"])
    if ref["false"] * 100 > FALSE_MAX_PCT * ref["beads"]:
        return "desligar", "%s; %s > %d%%" % (cmp, rate, FALSE_MAX_PCT)
    blind = [a for a in ("enforce", "holdout") if unk[a]["nao_sei"] * 100 > UNKNOWN_MAX_PCT * unk[a]["runs"]]  # a check that could not verify passes "enforce >= holdout" for free: it does not get promoted without having looked
    if blind:
        return wait("%s; %s; a checagem não deu veredito (nao-sei) em mais de %d%% das rodadas do braço %s" % (cmp, rate, UNKNOWN_MAX_PCT, " e ".join(blind)))
    return "promover", "%s; %s <= %d%%" % (cmp, rate, FALSE_MAX_PCT)


def conf_text(c):
    return "conf %s" % (c[0] if c[0] != "ok" else "mode=%s enforce_pct=%d" % (c[1], c[2]))


def put(cx, stem, phase, since, entrou, **extra):
    """Write the conf of `phase` with its record. -> "" or why."""
    mode, pct = expect(phase)
    return T.write_conf(cx.state, stem, mode, pct, note="ratchet " + T.dumps_line(dict(extra, v=1, fase=phase, since=since, entrou=entrou)))  # ONE line for every splitter: the real check cuts its conf with str.splitlines()


def step(cx, cls, row, rep):
    """One `em-teste` class -> its report row (verdict + why + the evidence), acting only under --apply."""
    out = {"class": cls, "since": row["since"], "check": row["check"], "verdict": "", "why": ""}
    stem, _, why = T.stem_of(row["check"])
    if stem is None:
        return dict(out, verdict="fora-do-contrato", why=why)
    others = sorted(c for c in cx.owners[stem] if c != cls)
    if others:  # the conf is one per check: a trial would rewrite the conf another row relies on (two trials, each other's at every --apply, restarting each other's window)
        return dict(out, verdict="fora-do-contrato", why="a checagem %s-check.py também é da classe %s: a conf é uma só por checagem e nada é gravado (dê a cada classe o seu script)" % (stem, ", ".join(others)))
    apply, since = cx.args.apply, row["since"]
    st, mode, pct, notes = T.read_conf(cx.state, stem)
    rec, why = record_of(notes)
    if st not in ("absent", "ok") or (st == "ok" and rec is None):
        return dict(out, verdict="nao-sei", why=why or "%s: %s.conf %s" % (conf_text((st, mode, pct)), stem, "não foi gravada pelo ciclo (apague-a para a checagem entrar no teste)" if st == "ok" else "não pôde ser lida"))
    if rec is None or rec["since"] != since:  # --- entry: no conf, or the record of an older trial of this class
        why = "conf enforce %d e a janela começa agora" % T.TRIAL_PCT
        if not apply:
            return dict(out, verdict="entraria", why=why)
        bad = put(cx, stem, "trial", since, iso(cx.now))
        return dict(out, verdict="erro-ao-aplicar" if bad else "entrou", why=bad or why)
    if rec["fase"] != "trial":  # --- decided: final for this since
        out.update(verdict="ja-decidida", why="%s em %s: %s" % (rec["fase"], rec.get("em", "?"), rec.get("why", "")))
        if (mode, pct) != expect(rec["fase"]):
            rep["gaps"].append("classe %s: decidida (%s) mas a %s não é a que o ciclo gravou: não mexo" % (cls, rec["fase"], conf_text((st, mode, pct))))
        return out
    if (mode, pct) != expect("trial"):  # --- in trial
        return dict(out, verdict="nao-sei", why="%s mudou durante o teste (os braços foram sorteados a %d): nada é decidido" % (conf_text((st, mode, pct)), T.TRIAL_PCT))
    rst, rows, bad = read_runs(T.runs_path(cx.state, stem), stem)
    if rst == "unreadable" or bad:
        return dict(out, verdict="nao-sei", why="o registro de rodadas %s: com ele ilegível ou estragado nada é decidido" % ("tem %d linha(s) fora do contrato (linhas %s%s)" % (len(bad), ", ".join(map(str, bad[:5])), ", …" if len(bad) > 5 else "") if bad else "não pôde ser lido"))
    g, entry = cx.gate(), try_ts(rec["entrou"])
    gaps = cx.gaps(entry)
    if g["vs"] is None:
        rep["gaps"].append("classe %s: quality-gate.jsonl %s: a 1ª tentativa por braço NÃO FOI MEDIDA" % (cls, g["state"]))
    rep["gaps"] += ["classe %s: %s" % (cls, x) for x in gaps]  # said even before a decision is due: it is what will hold it
    m = measure(cx.M, rows, g["vs"], entry, cx.now)
    days = (cx.now - entry).total_seconds() / 86400.0
    verdict, why = decide(m, days, cx.args, gaps)
    if rst == "absent" and verdict in ("aguardando-dados", "desligar"):
        why += " (a checagem nunca gravou uma rodada: %s não existe)" % os.path.basename(T.runs_path(cx.state, stem))
    out.update(days=round(days, 3), submissions=m["submissions"], enforce=m["enforce"], holdout=m["holdout"], refusals=m["refusals"], false_beads=m["false_beads"], unknown=m["unknown"], why=why)
    if verdict in ("em-andamento", "aguardando-dados", "nao-sei"):
        return dict(out, verdict=verdict)
    token = "promovida" if verdict == "promover" else "desligada"
    if not apply:
        return dict(out, verdict="promoveria" if token == "promovida" else "desligaria")
    bad = put(cx, stem, token, since, rec["entrou"], em=iso(cx.now), why=why, evidence=m)  # settings and record in ONE atomic write: the decision is whole or it did not happen
    return dict(out, verdict="erro-ao-aplicar" if bad else token, why=bad or why)


class Ctx(object):
    """One run: the clock, the flags, the meter module, which classes name which check (any status); the gate log is read once, and only when a trial needs it."""

    def __init__(self, args, now, M, owners):
        self.args, self.now, self.M, self.owners, self.state, self._gate = args, now, M, owners, os.path.join(args.city, ".gc"), None

    def gate(self):
        """-> the gate log as the meter reads it: {state, vs (the verdicts; None when the log is absent, unreadable or has no verdict in it: that is not "0 verdicts"), rows, bad, bad_ts, unusable} — the damage is kept for gaps(), never thrown away."""
        if self._gate is None:
            # vazio → "vazio" (no row, or rows with no verdict): vs None, and a due decision says NÃO SEI; falhou/ilegível → st absent/unreadable, vs None: the same; linha rasgada ou veredito sem ts/bead → bad/bad_ts/unusable, which gaps() turns into a hold
            st, rows, bad, bad_ts = self.M.read_log(os.path.join(self.state, "quality-gate.jsonl"))
            vs, unusable = self.M.verdicts(rows) if st == "ok" else ([], 0)
            self._gate = {"state": st if st != "ok" or vs else "vazio", "vs": vs or None, "rows": rows, "bad": bad, "bad_ts": bad_ts, "unusable": unusable}
        return self._gate

    def gaps(self, entry):
        """-> why-lines for what the gate log may be hiding from a trial that entered at `entry` ([] = nothing): the meter's own rule for its window — a damaged line, or a verdict without a usable bead, whose ts is legible and BEFORE the window cannot hide a verdict of it; any other might."""
        g = self.gate()
        # vazio → [] (nothing damaged, or all of it provably older than the trial); falhou/ilegível → n/a: this is derived from the ONE read in gate(), nothing is read here
        maybe = g["bad"] - sum(1 for t in g["bad_ts"] if t < entry)
        unusable = g["unusable"] - self.M.verdicts([d for d in g["rows"] if (self.M.try_ts(d.get("ts")) or entry) < entry])[1]
        return (["%d linha(s) ilegível(is) do quality-gate.jsonl podem ser do teste" % maybe] if maybe else []) + (["%d veredito(s) do quality-gate.jsonl sem ts/bead utilizável podem ser do teste" % unusable] if unusable else [])


class Parser(argparse.ArgumentParser):
    def error(self, message):  # argparse would print its own usage and exit 2 (NÃO SEI's code): every bad flag is exit 64 with ONE usage line
        raise ValueError(message)


def main(argv=None):
    ap = Parser(add_help=False)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--days", type=int, default=DAYS)
    ap.add_argument("--min-submissions", dest="min_submissions", type=int, default=MIN_SUBMISSIONS)
    ap.add_argument("--cap-days", dest="cap_days", type=int, default=CAP_DAYS)
    ap.add_argument("--now")
    ap.add_argument("--city", default=os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or DEFAULT_CITY)
    try:
        args = ap.parse_args(argv)
        now = try_ts(args.now) if args.now else datetime.datetime.now(UTC).replace(microsecond=0)
        if args.days < 1 or args.min_submissions < 1 or args.cap_days < args.days or now is None:
            raise ValueError("uso")
    except ValueError:
        sys.stderr.write(USAGE + "\n")
        return 64
    rep = {"schema": SCHEMA, "slice": SLICE, "mode": "apply" if args.apply else "dry-run", "now": iso(now), "thresholds": {"days": args.days, "min_submissions": args.min_submissions, "cap_days": args.cap_days}, "registry": {"state": None, "problems": []}, "classes": [], "gaps": []}
    return cycle(args, now, rep)


def cycle(args, now, rep):
    """One run: registry → one step per `em-teste` class → the report. -> the exit code."""
    def finish(rc, line):
        rep["line"] = line
        text = line + "\n" + "".join("  classe %-30s %-16s %s\n" % (c["class"], c["verdict"], c["why"]) for c in rep["classes"]) + "".join("  ⚠ %s\n" % g for g in rep["gaps"])
        sys.stdout.write(json.dumps(rep, ensure_ascii=False, sort_keys=True, indent=1) + "\n" if args.json else text)
        return rc

    M = P.load_meter(os.path.join(HERE, "gate-refusal-meter.py")) if P is not None and T is not None else None
    if M is None:
        return finish(2, "NÃO SEI: não consegui carregar gate-refusal-checks.py, gate_check_trial.py ou o medidor. Nada foi lido nem gravado.")
    st, regs, problems = P.read_registry(os.path.join(args.city, P.REGISTRY_REL))
    rep["registry"].update(state=st, problems=problems)
    rep["gaps"] += problems
    if st != "ok":
        return finish(2, "NÃO SEI: registro de classes cobertas %s. Nada foi lido nem gravado." % st)
    owners = {}
    for c, r in regs.items():  # every row, whatever its status: the conf of a check is one, and a row that is not in trial may still own it
        owners.setdefault(T.stem_of(r["check"])[0], []).append(c)
    cx, trials = Ctx(args, now, M, owners), sorted(c for c, r in regs.items() if r["status"] == "em-teste")
    rep["classes"] = [step(cx, cls, regs[cls], rep) for cls in trials]
    count = lambda *v: sum(1 for c in rep["classes"] if c["verdict"] in v)  # noqa: E731
    rc = 1 if count("erro-ao-aplicar") else 2 if count("nao-sei", "fora-do-contrato") else 0
    return finish(rc, "gate-checks-ratchet [%s]: %d classe(s) em teste · %d entrando/entrou · %d em andamento · %d aguardando dados · %d promovida(s)/promoveria · %d desligada(s)/desligaria · %d já decidida(s) · %d NÃO SEI · %d fora do contrato · %d erro(s)" % (
        rep["mode"], len(trials), count("entraria", "entrou"), count("em-andamento"), count("aguardando-dados"), count("promovida", "promoveria"), count("desligada", "desligaria"), count("ja-decidida"), count("nao-sei"), count("fora-do-contrato"), count("erro-ao-aplicar")))


def entry(argv=None):
    """main() with a net under it: an exception nobody planned is exit 70 with the traceback on stderr, so exit 1 keeps its one meaning (a write failed)."""
    try:
        return main(argv)
    except Exception:  # noqa: BLE001 - anything unplanned is a bug of this script: say so loudly, with where to look for what the run had already done
        sys.stderr.write("gate-checks-ratchet: ERRO INESPERADO (bug do script). O que esta rodada já gravou está nas confs .gc/<nome>.conf (linha `# ratchet`).\n%s" % traceback.format_exc())
        return 70


if __name__ == "__main__":
    sys.exit(entry())
