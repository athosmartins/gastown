#!/usr/bin/env python3
"""third-state-arm-coverage.py — ga-r4z4ve: alarm when the gate's runs outnumber the recorded third-state arms. Detection only.

Why: on 25/10 the check was ON (.gc/third-state-reads.conf: enforce, 50%) and had no effect for six days — 2 rows in .gc/third-state-reads-arms.jsonl
against 437 beads with a first gate verdict — and nothing complained: "switched on" and "ran" are different facts and every file kept looking healthy.
The cause (ga-r4z4ve): step 2e lived only in formulas/mol-quality-gate-runner.toml, which nothing pours (the live gate is guard -> dispatcher ->
reviewers), so it ran only when someone found the formula and typed it by hand — the 2 rows most likely come from such loose runs (the builder's /gate-done
uses --no-record; where exactly they came from cannot be read from outside the mini).
ga-vywjzsp moved 2b-2e into the guard (Step 5b-pre5), so every swept marker draws and records its arm. This watches that from the OUTSIDE, with a source the guard
does not write: every bead with a real verdict in quality-gate.jsonl (dispatcher_complete PASS|FAIL, not a dry run) must have a row in the arms file, whatever the guard's own labels say.

Counted per BEAD, not per row: the first row of a bead wins forever, so a re-run finds the row of its first sweep. Only mode=enforce draws arms
(warn / off / no conf record nothing by design: said, not alarmed). Runs that completed before conf mtime + TSAC_SLACK_H are not counted: their
marker may have been swept before the check was switched on. Alarm "diverge" = at least TSAC_MIN_RUNS beads in the window AND at least
TSAC_MIN_UNCOVERED of them without an arm AND more than TSAC_MAX_UNCOVERED_PCT % of them without one (a few legitimate holes exist: a diff that edits
the check itself is not judged, a fetch can fail — both fail open and loud in the guard). On their own keys: a conf the check cannot parse (it answers
NÃO SEI to every submission), a kill-switch flag standing longer than TSAC_SWITCH_MAX_H, and a gate log or sibling script that cannot be read (blind).
A gate log that is only PARTLY readable is blind too (ga-r4z4ve gate-fix 1): an unparseable line, a PASS|FAIL verdict whose ts or bead cannot be used, or one with an
empty bead (the dispatcher could not read the marker) may be a run nobody can see. Each is dated by its own ts, else by the readable row written after it (the log is
appended in order); only what is provably before the window is left out. Anything else makes "ok" and "poucos-runs" into NÃO SEI (key cego|gate-log-parcial);
a "diverge" stands and says the real number may be larger.
Each key is cooldown-deduped (TSAC_ESCALATE_AFTER_S), forgotten when its condition was evaluated and is gone, kept when it could not be evaluated.

Exit (CLI): 0 nothing to report (also: not switched on, too few runs) | 1 an alarmable finding | 2 NÃO SEI (never "0 runs", never "ok").
--order (the gc order): 0 once every finding was alarmed or deduped, 2 only when an alarm DELIVERY failed (a failed run in the order log).
Env: GC_CITY_PATH | GC_CITY, THIRD_STATE_READS_STATE_DIR (same as the check), TSAC_STATE_DIR, TSAC_ROUTER, TSAC_WINDOW_H=24, TSAC_SLACK_H=8,
TSAC_MIN_RUNS=5, TSAC_MIN_UNCOVERED=2, TSAC_MAX_UNCOVERED_PCT=10, TSAC_SWITCH_MAX_H=72, TSAC_ESCALATE_AFTER_S=86400, TSAC_DELIVER_TIMEOUT_S=120, TSAC_LOG_TAIL_BYTES=8388608.
A garbage value is the default, never "no limit". Kill switch: THIRD_STATE_ARM_COVERAGE=off or .gc/third-state-arm-coverage.off (a loud no-op).
"""
import argparse
import datetime
import fcntl
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys

sys.dont_write_bytecode = True   # the order runs inside the city's git tree: no __pycache__ next to the siblings it imports
HERE = os.path.dirname(os.path.abspath(__file__))
UTC = datetime.timezone.utc
RC_OK, RC_FOUND, RC_UNKNOWN = 0, 1, 2
ARM_VALUES = ("enforce", "holdout")
TS_FMT = "%Y-%m-%dT%H:%M:%SZ"
# the guard's own line (quality-gate-guard.sh, Step 5b-pre5): "[<local time>] [quality-gate-guard] HARDCHECK step=2e verdict=.. reason=.. bead=<id> .. checker=[..arm=<arm>]"
GUARD_LINE = re.compile(r"^\[[^\]]*\] \[quality-gate-guard\] HARDCHECK step=2e verdict=(\S+) reason=(\S+) bead=(\S+) ")


def env_int(name, default):
    """A garbage, empty or negative value is the default, never 'no limit'. (Callers that cannot take 0 also say `or default`.)"""
    v = os.environ.get(name, "")
    return int(v) if re.fullmatch(r"[0-9]{1,9}", v) else default


def load_sibling(fname):
    """-> (module, "") | (None, why). The conf rules and the log reader are the check's and the report's own, not copies that can drift."""
    # vazio → n/a (a module is code, there is no empty read); falhou/ilegível → (None, why): NÃO SEI + a "cego" alarm, never "no conf" / "no runs"
    try:
        spec = importlib.util.spec_from_file_location(fname[:-3].replace("-", "_"), os.path.join(HERE, fname))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod, ""
    except (Exception, SystemExit) as e:   # not a list of the failures someone imagined: a sibling that dies at import in ANY way is 'cego' (and a sys.exit(0) at import would read as 'nothing to report')
        return None, "%s: %s: %s" % (fname, type(e).__name__, e)


def scan_arms(path, beads):
    """-> (state, {bead: arm | "linha-invalida" | "linha-corrompida"}, rows, bad, last_ts). Same rule as the check's arm_of: the first line that names the
    bead decides; a line that does not parse and carries the bead's id is "linha-corrompida" (the check answers NÃO SEI there, never a redraw)."""
    # vazio → ("ok", {}, 0, 0, None): no bead has a row (a never-written file IS the divergence, not "fine");
    # falhou/ilegível → "absent" / "unreadable" with no rows: every run counts as uncovered and the state says why
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except FileNotFoundError:
        return "absent", {}, 0, 0, None
    except OSError:
        return "unreadable", {}, 0, 0, None
    out, rows, bad, last = {}, 0, 0, None
    for line in raw.decode("utf-8", "replace").splitlines():
        if not line.strip():
            continue
        try:
            d = json.loads(line)
        except ValueError:
            bad += 1
            for b in beads:
                if b not in out and json.dumps(b) in line:
                    out[b] = "linha-corrompida"
            continue
        if not isinstance(d, dict):
            bad += 1
            continue
        rows += 1
        b = d.get("bead")
        if isinstance(b, str) and b in beads and b not in out:
            out[b] = d["arm"] if d.get("arm") in ARM_VALUES else "linha-invalida"
        try:
            t = datetime.datetime.strptime(str(d.get("ts")), TS_FMT).replace(tzinfo=UTC)
            last = t if last is None or t > last else last
        except ValueError:
            pass
    return "ok", out, rows, bad, last


def guard_lines(path, beads, tail):
    """-> (state, {bead: (verdict, reason, arm)}) from the guard's HARDCHECK step=2e lines (newest wins): why each uncovered bead has no arm."""
    # vazio → ("ok", {}): no line names these beads (the guard never ran 5b-pre5 for them, or the log rolled over: said as such);
    # falhou/ilegível → ("absent" | "unreadable", {}): the diagnosis is missing, the verdict never depends on it
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - tail))
            raw = fh.read()
    except FileNotFoundError:
        return "absent", {}
    except OSError:
        return "unreadable", {}
    out = {}
    for line in raw.decode("utf-8", "replace").splitlines():
        m = GUARD_LINE.match(line)
        if m and m.group(3) in beads:
            arm = re.search(r"\barm=([a-z-]+)\]\s*$", line)
            out[m.group(3)] = (m.group(1), m.group(2), arm.group(1) if arm else "?")
    return "ok", out


def stamp(report, v):
    """-> datetime | None. A ts in the gate log's own format (report.parse_ts); anything else is None, never a guess."""
    # vazio → None (no ts key); falhou/ilegível → None as well: the caller keeps "I do not know when" as its own state and never reads it as "old"
    try:
        return report.parse_ts(v)
    except (TypeError, ValueError):
        return None


def read_gate_log(path, report):
    """-> (state, items) in FILE order: ("row", dict) | ("bad", ts | None). The same rule as report.read_jsonl (a line is a row iff it parses to a JSON object; every other
    non-blank line is bad, with its ts when still legible), but it keeps the order, which read_jsonl throws away and which is the only thing that dates a fragment with no
    ts of its own. The selftest pins the two readers to the same counts."""
    # vazio → ("ok", []): a real empty file; falhou/ilegível → "absent" (ENOENT) / "unreadable" (any other error) with no items: the caller is blind, never "0 runs"
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except FileNotFoundError:
        return "absent", []
    except OSError:
        return "unreadable", []
    items = []
    for line in raw.decode("utf-8", "replace").splitlines():
        if not line.strip():
            continue
        try:
            d = json.loads(line)
        except ValueError:
            d = None
        if isinstance(d, dict):
            items.append(("row", d))
            continue
        m = report.TS_RE.search(line)
        items.append(("bad", stamp(report, m.group(1)) if m else None))
    return "ok", items


def place(own, after, lo, now):
    """-> "in" | "out" | "doubt". Its own ts decides; with none, the readable row written AFTER it does (it was written before that row): a row before the window proves
    it is old. Nothing after it, or something not before the window: "doubt" -- counted as possibly inside, never as old."""
    if own is not None:
        return "in" if lo <= own <= now else "out"
    return "out" if after is not None and after < lo else "doubt"


def gate_gaps(items, lo, now, report, check_rows):
    """-> {"lin_<p>": unparseable lines, "reg_<p>": real PASS|FAIL verdict rows with no usable ts/bead} for p in in|doubt|out: what the readable verdicts say nothing about.
    check_rows: verdicts() found such rows (its no_ts count), so each row needs the per-row look; without them only the lines are placed."""
    # vazio → all zeros (every line parsed, every verdict has a ts and a bead); falhou/ilegível → counted by where it falls (see place): every one lands in a bucket, none is dropped,
    # and only "out" may leave the answer alone
    g = dict.fromkeys(("lin_in", "lin_doubt", "lin_out", "reg_in", "reg_doubt", "reg_out"), 0)
    nxt, after = [None] * len(items), None
    for i in range(len(items) - 1, -1, -1):   # the ts of the nearest readable row written after each position
        nxt[i] = after
        kind, x = items[i]
        if kind == "row":
            t = stamp(report, x.get("ts"))
            if t is not None:
                after = t
    for i, (kind, x) in enumerate(items):
        if kind == "bad":
            g["lin_" + place(x, nxt[i], lo, now)] += 1
        elif check_rows and report.verdicts([x])[1]:   # verdicts() is the one that says which rows have no usable ts/bead
            g["reg_" + place(stamp(report, x.get("ts")), nxt[i], lo, now)] += 1
    return g


def gaps_text(g):
    """One sentence on what the readable rows of the gate log do not account for ('' when nothing)."""
    parts, lin, reg = [], g["lin_in"] + g["lin_doubt"] + g["lin_out"], g["reg_in"] + g["reg_doubt"] + g["reg_out"]
    if lin:
        parts.append("%d linha(s) ilegivel(is): %d com ts dentro da janela, %d sem data propria que nao da para provar anteriores a janela, %d provadamente anteriores (nao contam)" % (lin, g["lin_in"], g["lin_doubt"], g["lin_out"]))
    if reg:
        parts.append("%d veredito(s) sem ts/bead legivel: %d dentro da janela, %d sem como provar que sao anteriores, %d provadamente anteriores (nao contam)" % (reg, g["reg_in"], g["reg_doubt"], g["reg_out"]))
    if g["blank"]:
        parts.append("%d veredito(s) com bead vazio na janela (o dispatcher nao leu o bead do marker)" % g["blank"])
    return "quality-gate.jsonl: " + "; ".join(parts) + "." if parts else ""


def flag_age(path, now, regular):
    """-> (seconds since its mtime, "") | (None, "") when there is no such flag | (None, why) when it cannot be told. `regular`: only a regular file counts (the guard's `[ -f ]`)."""
    # vazio → (None, ""): no flag, the check is not switched off; falhou/ilegível (stat denied, a symlink loop) → (None, why): the check (killed()) and the guard (`[ -f ]`)
    # treat a flag they cannot stat as NOT set, so it is not counted as a switch here either — but said, never silent
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return None, ""
    except OSError as e:
        return None, "interruptor %s ilegivel (%s): tratado como ausente, como a checagem faz" % (os.path.basename(path), type(e).__name__)
    if regular and not stat.S_ISREG(st.st_mode):
        return None, ""
    return max(0, int(now.timestamp() - st.st_mtime)), ""


def clean(x):
    """Bead ids come from files: printable id characters only, so a hostile line cannot write its own text into a mail."""
    return re.sub(r"[^A-Za-z0-9._:-]", "?", str(x))[:60]


def blind(res, key, subject, body, why):
    res.update(state="cego", verdict="nao-sei", rc=RC_UNKNOWN)
    res["notes"].append("NAO SEI: " + why)
    res["alarms"][key] = (subject, body)
    return res


def measure(city, now, a):
    """-> res: the facts, `alarms` {key: (subject, body)} that stand now, `unevaluated` key prefixes this tick could not judge (their old marks are kept)."""
    gc = os.path.join(city, ".gc")
    state = os.environ.get("THIRD_STATE_READS_STATE_DIR") or gc
    res = {"city": city, "state": "", "mode": "-", "pct": "-", "window": "-", "evaluated": False, "runs": 0, "covered": 0, "uncovered": [], "split": {},
           "rows": 0, "bad_rows": 0, "gaps": {}, "last_arm": None, "arms_file": "-", "switches": [], "diag": [], "notes": [], "verdict": "", "alarms": {}, "unevaluated": [], "rc": RC_OK}
    tool, why_tool = load_sibling("third-state-reads-check.py")
    report, why_report = load_sibling("third-state-report.py")
    if tool is None or report is None:
        res["unevaluated"] = ["diverge", "conf-quebrada", "interruptor-velho", "cego"]
        return blind(res, "cego|irmaos", "gate:3o-estado-alarme-cego -- nao consegui carregar os scripts irmaos",
                     "third-state-arm-coverage nao conseguiu carregar %s: sem as regras da conf e a leitura do log do gate nao ha como cobrir os bracos. DESCONHECIDO, nao 'ok' (ga-r4z4ve)." % (why_tool or why_report),
                     why_tool or why_report)
    # vazio → "absent": the check is not switched on, nothing to cover; falhou/ilegível → "unreadable" / "invalid:*": the check answers NÃO SEI to every
    # submission, so it is alarmed as conf-quebrada and never read as "absent"
    st, mode, pct = tool.load_conf(state)
    res["mode"], res["pct"] = mode or "-", pct if pct is not None else "-"
    if st == "absent":
        res["state"] = "nao-ligada"
    elif st != "ok":
        res["state"] = "conf-quebrada"
        res["alarms"]["conf-quebrada"] = ("gate:3o-estado-conf-quebrada -- %s nao e valida" % tool.CONF,
            "%s/%s esta '%s': a checagem responde NAO SEI a toda submissao e o guard segue sem ela (fail-open), nenhum braco e gravado. Conserte ou remova o arquivo (ga-r4z4ve)." % (state, tool.CONF, st))
    elif mode != "enforce":
        res["state"] = "sem-braco"
    for name, path, regular in ((tool.KILL, os.path.join(state, tool.KILL), False), ("gate-hardchecks.off", os.path.join(gc, "gate-hardchecks.off"), True)):
        age, why = flag_age(path, now, regular)
        if age is not None:
            res["switches"].append((name, age))
        if why:
            res["notes"].append(why)
    if st == "ok" and mode != "off":
        for name, age in res["switches"]:
            if age > a.switch_max_h * 3600:
                res["alarms"]["interruptor-velho|" + name] = ("gate:3o-estado-interruptor-esquecido -- %s ligado ha mais de %dh" % (name, a.switch_max_h),
                    "O arquivo %s existe ha %dh (limite %dh): a checagem de leitura nova sem teste de falha (ga-57e7l0.1) esta SEM efeito desde entao. Se foi de proposito, apague-o "
                    "quando acabar; se foi esquecido, apague agora (ga-r4z4ve)." % (name, age // 3600, a.switch_max_h))
        if res["state"] == "" and res["switches"]:
            res["state"] = "interruptor"
    if res["state"] != "":
        res["verdict"] = res["state"]
        res["rc"] = RC_FOUND if res["alarms"] else RC_OK
        res["unevaluated"] = (["diverge"] if res["state"] == "interruptor" else []) + ["cego"]   # this tick did not read the gate log either: its "cego" marks stay
        return res
    res["state"] = "ligada"
    lo = now - datetime.timedelta(hours=a.window_h)
    # vazio → n/a (load_conf just read this very file, so it exists); falhou/ilegível → an OSError here is not caught: the top-level handler turns it into rc 2 (NÃO SEI), loud, never a skipped gate
    conf_t = datetime.datetime.fromtimestamp(os.stat(os.path.join(state, tool.CONF)).st_mtime, UTC)
    if conf_t + datetime.timedelta(hours=a.slack_h) > lo:
        lo = conf_t + datetime.timedelta(hours=a.slack_h)
        res["notes"].append("conf alterada em %s: runs so contam a partir de %s (a folga cobre markers varridos antes)" % (conf_t.strftime("%Y-%m-%dT%H:%MZ"), lo.strftime("%Y-%m-%dT%H:%MZ")))
    res["window"] = "%s -> %s UTC (%dh)" % (lo.strftime("%Y-%m-%dT%H:%MZ"), now.strftime("%Y-%m-%dT%H:%MZ"), a.window_h)
    # vazio → no rows says nothing about runs: blind (NÃO SEI), never "0 runs"; falhou/ilegível → "absent" / "unreadable": blind as well
    gs, items = read_gate_log(os.path.join(gc, "quality-gate.jsonl"), report)
    rows = [d for k, d in items if k == "row"]
    if gs != "ok" or not rows:
        why = {"absent": "ausente", "unreadable": "ilegivel"}.get(gs, "vazio")
        res["unevaluated"] = ["diverge"]
        return blind(res, "cego|gate-log", "gate:3o-estado-alarme-cego -- nao consegui ler quality-gate.jsonl",
                     "third-state-arm-coverage nao conseguiu ler %s/quality-gate.jsonl (%s): sem os runs nao ha como dizer se os bracos estao sendo gravados. DESCONHECIDO, nao 'ok' (ga-r4z4ve)." % (gc, why),
                     "quality-gate.jsonl %s: nenhum run contado (isto NAO e 0 runs)" % why)
    vs, no_ts, _, _ = report.verdicts(rows)
    runs, blank = {}, 0
    for t, _, d in vs:
        if lo <= t <= now and d["bead"].strip():
            runs.setdefault(d["bead"], t)
        elif lo <= t <= now:
            blank += 1   # a real verdict whose bead the dispatcher could not read (extract "bead_id" came back empty): a run nobody can name, not "no run"
    # vazio → all zeros (nothing unreadable); falhou/ilegível → counted by where it falls (gate_gaps): a line or verdict that cannot be read is NÃO SEI unless it is provably
    # before the window, never "fewer runs"
    g = gate_gaps(items, lo, now, report, no_ts > 0)
    g["blank"] = blank
    res["gaps"] = g
    unknown = g["lin_in"] + g["lin_doubt"] + g["reg_in"] + g["reg_doubt"] + blank
    ast, arms, nrows, nbad, last = scan_arms(os.path.join(state, tool.ARMS), set(runs))
    res.update(evaluated=True, runs=len(runs), arms_file=ast, rows=nrows, bad_rows=nbad, last_arm=last)
    res["covered"] = sum(1 for b in runs if arms.get(b) in ARM_VALUES)
    res["split"] = {v: sum(1 for b in runs if arms.get(b) == v) for v in ARM_VALUES}
    res["uncovered"] = sorted((b, arms.get(b, "sem-linha")) for b in runs if arms.get(b) not in ARM_VALUES)
    n, u = len(runs), len(res["uncovered"])
    if u:
        ls, lines = guard_lines(os.path.join(gc, "logs", "quality-gate-guard.log"), {b for b, _ in res["uncovered"]}, a.log_tail)
        if ls != "ok":
            res["diag"].append("diagnostico pelo log do guard indisponivel (quality-gate-guard.log %s)" % ("ausente" if ls == "absent" else "ilegivel"))
        else:
            tally = {}
            for b, _ in res["uncovered"]:
                v = lines.get(b)
                k = "%s/%s (o log diz arm=%s)" % v if v else "sem linha HARDCHECK 2e no log (o 5b-pre5 nao rodou para ele, ou o log girou)"
                tally[k] = tally.get(k, 0) + 1
            res["diag"] += ["guard, passo 2e dos sem braco: %s x%d" % (k, c) for k, c in sorted(tally.items())]
    if n < a.min_runs:
        res["verdict"], res["unevaluated"] = "poucos-runs", ["diverge"]
    elif u >= a.min_uncovered and 100 * u > a.max_pct * n:
        res["verdict"] = "diverge"
        sample = ", ".join("%s (%s)" % (clean(b), why) for b, why in res["uncovered"][:8]) + (" ..." if u > 8 else "")
        res["alarms"]["diverge"] = ("gate:3o-estado-braco-nao-gravado -- %d de %d beads com veredito sem braco em %dh" % (u, n, a.window_h),
            "%d de %d beads com veredito real do gate em %s nao tem braco em %s/%s (limite: mais de %d%% e pelo menos %d). A conf esta ligada (mode=%s enforce_pct=%s) mas a checagem de "
            "3o estado nao esta rodando para eles: o mesmo buraco silencioso do ga-r4z4ve. Sem braco: %s. %s Veja: grep 'HARDCHECK step=2e' %s/logs/quality-gate-guard.log | tail; flags %s/gate-hardchecks.off "
            "e %s/%s; o arquivo de bracos precisa estar gravavel (estado dele: %s). Runbook: docs/runbooks/third-state-report.md, secao 'Alarme'." % (u, n, res["window"], state, tool.ARMS, a.max_pct, a.min_uncovered, res["mode"], res["pct"], sample,
            " ".join(res["diag"]), gc, gc, state, tool.KILL, ast))
        if unknown:
            subject, body = res["alarms"]["diverge"]
            res["alarms"]["diverge"] = (subject, body + " ATENCAO: " + gaps_text(g) + " O numero real de beads sem braco pode ser maior.")
    else:
        res["verdict"] = "ok"
    if unknown and res["verdict"] != "diverge":   # "ok" and "poucos-runs" both claim to know how many runs there were; with unreadable ones inside the window they do not (an earlier "diverge" mark is kept: this tick could not judge it)
        res["unevaluated"] = ["diverge"]
        return blind(res, "cego|gate-log-parcial", "gate:3o-estado-alarme-cego -- quality-gate.jsonl tem trechos que nao consegui ler",
                     "third-state-arm-coverage leu %s/quality-gate.jsonl so em parte: %s Os %d beads que li nao sao necessariamente todos os da janela, entao 'cobertura dentro do limite' nao se aplica: DESCONHECIDO, nao 'ok' (ga-r4z4ve). "
                     "Veja as linhas que nao sao JSON: grep -nv '^{.*}$' %s/quality-gate.jsonl | tail -20" % (gc, gaps_text(g), n, gc),
                     gaps_text(g) + " (isto NAO e 'cobertura ok')")
    if any(g.values()):   # said whenever anything is unreadable, provably old or not (a clean-looking "ok" must not hide that the log is not clean); here it has not changed the answer
        res["notes"].append(gaps_text(g))
    res["rc"] = RC_FOUND if res["alarms"] else RC_OK
    return res


def render(res):
    L = ["═══ third-state-arm-coverage (ga-r4z4ve) ═══", "  cidade: %s   checagem: %s (mode=%s enforce_pct=%s)   janela: %s" % (res["city"], res["state"], res["mode"], res["pct"], res["window"])]
    L += ["  " + x for x in res["notes"]]
    if res["switches"]:
        L.append("  interruptores presentes: " + ", ".join("%s (ha %dh)" % (n, age // 3600) for n, age in res["switches"]))
    if res["evaluated"]:
        last = res["last_arm"].strftime(TS_FMT) if res["last_arm"] else "nunca"
        L.append("  arquivo de bracos: %s, %d linha(s), %d ilegivel(is)/estranha(s), ultima gravacao %s" % (res["arms_file"], res["rows"], res["bad_rows"], last))
        L.append("  beads com veredito real na janela: %d; com braco: %d (enforce %d / holdout %d); SEM braco: %d" % (res["runs"], res["covered"], res["split"]["enforce"], res["split"]["holdout"], len(res["uncovered"])))
        L += ["    sem braco: %s (%s)" % (clean(b), why) for b, why in res["uncovered"][:10]]
    L += ["  " + x for x in res["diag"]]
    L.append({"ok": "  ✓ cobertura dentro do limite", "diverge": "  ✗ DIVERGE: beads com veredito e sem braco", "poucos-runs": "  ? sem conclusao: poucos beads com veredito na janela (isto NAO e 'ok')",
              "nao-ligada": "  - checagem nao ligada (sem conf): nada a cobrir", "sem-braco": "  - mode warn/off nao sorteia braco por desenho: nada a cobrir",
              "interruptor": "  - interruptor presente: a checagem esta desligada (alarme so se passar do limite de idade)", "conf-quebrada": "  ✗ CONF QUEBRADA: a checagem responde NAO SEI a tudo",
              "nao-sei": "  ? NAO SEI (isto NAO e 'ok')"}[res["verdict"]])
    return "\n".join(L)


def deliver(subject, body, city, timeout_s):
    """-> exit code of the router (or of `gc mail send mayor` without one); 1 when it could not run at all."""
    router = os.environ.get("TSAC_ROUTER") or os.path.join(city, "packs", "town-deltas", "assets", "escalation-router.sh")
    cmd = [router, "-s", subject, "-m", body, "--topic", "infra"] if os.path.isfile(router) and os.access(router, os.X_OK) else [os.environ.get("GC_BIN", "gc"), "mail", "send", "mayor", "-s", subject, "-m", body]
    # vazio → n/a (a command has an exit code); falhou (cannot run / times out / rc != 0) → the rc or 1: the caller does NOT record the alarm as sent and retries next tick
    try:
        return subprocess.run(cmd, capture_output=True, timeout=timeout_s).returncode
    except (OSError, subprocess.SubprocessError):
        return 1


def alarm(res, state_dir, city, now, escalate_s, timeout_s):
    """Cooldown per key. A delivery that failed is not recorded (retry next tick). A mark is dropped only when its key was evaluated and no longer stands; a key of a
    family this tick could not judge (`unevaluated`) keeps its mark. -> number of failed deliveries."""
    seen_file = os.path.join(state_dir, "third-state-arm-coverage-seen.json")
    # vazio → {} (nothing alarmed yet); falhou/ilegível (garbage, unreadable) → {} too: the cost is one repeated mail, never a swallowed one
    try:
        with open(seen_file, encoding="utf-8") as fh:
            seen = json.loads(fh.read())
        seen = seen if isinstance(seen, dict) else {}
    except (OSError, ValueError):
        seen = {}
    keep = {k: v for k, v in seen.items() if k in res["alarms"] or any(k.split("|")[0] == p for p in res["unevaluated"])}
    failed, t = 0, int(now.timestamp())
    for k, (subject, body) in sorted(res["alarms"].items()):
        last = seen.get(k, 0)
        if isinstance(last, int) and last and t - last < escalate_s:
            continue
        rc = deliver(subject, body, city, timeout_s)
        if rc != 0:
            failed += 1
            print("third-state-arm-coverage: ALARME NAO ENTREGUE (rc=%s) key='%s': nao gravo como visto, tento no proximo tick" % (rc, k), file=sys.stderr)
            continue
        keep[k] = t
    if keep != seen:
        try:
            os.makedirs(state_dir, exist_ok=True)
            with open(seen_file, "w", encoding="utf-8") as fh:
                json.dump(keep, fh)
        except OSError as e:
            print("third-state-arm-coverage: nao gravei %s (%s): o proximo tick pode repetir o aviso" % (seen_file, e), file=sys.stderr)
    return failed


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--city", default=os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY"))
    ap.add_argument("--now", help="YYYY-MM-DDTHH:MM:SSZ (default: now)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-alarm", action="store_true")
    ap.add_argument("--no-lock", action="store_true", help="selftest only")
    ap.add_argument("--order", action="store_true", help="gc order mode: exit 2 only when an alarm could not be delivered")
    a = ap.parse_args(argv)
    a.window_h, a.slack_h = env_int("TSAC_WINDOW_H", 24) or 24, env_int("TSAC_SLACK_H", 8)
    a.min_runs, a.min_uncovered = env_int("TSAC_MIN_RUNS", 5) or 5, env_int("TSAC_MIN_UNCOVERED", 2) or 2
    a.max_pct, a.switch_max_h = env_int("TSAC_MAX_UNCOVERED_PCT", 10), env_int("TSAC_SWITCH_MAX_H", 72) or 72
    a.log_tail = env_int("TSAC_LOG_TAIL_BYTES", 8 * 1024 * 1024) or 8 * 1024 * 1024
    if not a.city:
        guess = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
        a.city = guess if os.path.isfile(os.path.join(guess, "city.toml")) else ""
    if not a.city or not os.path.isdir(a.city):
        print("third-state-arm-coverage: NÃO SEI -- cidade não encontrada (defina GC_CITY_PATH ou --city); rc 2 = não rodei", file=sys.stderr)
        return RC_UNKNOWN
    city = os.path.realpath(a.city)
    # vazio → no flag file: the detector runs; falhou/ilegível (stat denied) → exists() is False: the detector runs too (a muted alarm is the dangerous side)
    if os.environ.get("THIRD_STATE_ARM_COVERAGE") == "off" or os.path.exists(os.path.join(city, ".gc", "third-state-arm-coverage.off")):
        print("NOTE: third-state-arm-coverage is switched OFF (THIRD_STATE_ARM_COVERAGE=off or .gc/third-state-arm-coverage.off) -- nothing checked.")
        return RC_OK
    try:
        now = datetime.datetime.strptime(a.now, TS_FMT).replace(tzinfo=UTC) if a.now else datetime.datetime.now(UTC).replace(microsecond=0)
    except ValueError:
        print("third-state-arm-coverage: --now inválido (YYYY-MM-DDTHH:MM:SSZ)", file=sys.stderr)
        return 64
    if not a.no_lock:
        try:
            os.makedirs(os.path.join(city, ".gc", "runtime"), exist_ok=True)
            lock = open(os.path.join(city, ".gc", "runtime", "third-state-arm-coverage.lock"), "w")   # held until the process ends
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("third-state-arm-coverage: outra instância já rodando -- %s" % ("saindo" if a.order else "NÃO rodei (rc 2 = desconhecido, repita)"), file=sys.stdout if a.order else sys.stderr)
            return RC_OK if a.order else RC_UNKNOWN
        except OSError as e:
            print("third-state-arm-coverage: não consegui o lock (%s) -- NÃO rodei (rc 2 = desconhecido, não 'ok')" % e, file=sys.stderr)
            return RC_UNKNOWN
    res = measure(city, now, a)
    if a.json:
        print(json.dumps(dict({k: v for k, v in res.items() if k != "alarms"}, alarm_keys=sorted(res["alarms"])), default=str, ensure_ascii=False))
    else:
        print(render(res))
    failed = 0
    if not a.no_alarm:
        failed = alarm(res, os.environ.get("TSAC_STATE_DIR") or os.path.join(city, ".gc", "runtime", "packs", "maintenance"), city, now,
                       env_int("TSAC_ESCALATE_AFTER_S", 86400) or 86400, env_int("TSAC_DELIVER_TIMEOUT_S", 120) or 120)
    return (RC_UNKNOWN if failed else RC_OK) if a.order else res["rc"]


if __name__ == "__main__":
    # an uncaught exception would exit 1 = "a finding": a crashed detector must say it could not tell (2), never look like an alarm
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:
        print("third-state-arm-coverage: NÃO SEI -- internal error: %s: %s" % (type(exc).__name__, exc))
        sys.exit(RC_UNKNOWN)
