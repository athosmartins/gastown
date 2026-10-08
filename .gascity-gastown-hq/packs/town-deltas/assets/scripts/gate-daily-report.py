#!/usr/bin/env python3
"""gate-daily-report.py — the 4 gate numbers, every morning, by script (ga-ufskhy; Athos 05/10 and 07/10).

The Mayor promised a daily report on 05/10 and did not deliver it on 06 and 07. This file is the fix: launchd
runs it at 09:03 BRT; it reads the gate's own records and posts the result as a comment on the program bead
(ga-ufskhy) plus one phone notification. No human in the loop, no memory of a promise.

WHAT IT REPORTS, for the previous local day (BRT) unless --day is given:
  1. first-attempt approval      PASS among beads whose FIRST verdict ever fell on that day
  2. approvals (PASS) that day   and verdicts, FAIL, pass rate over all verdicts
  3. median review minutes       dispatcher elapsed_s, PASS+FAIL
  4. gate queue depth now        from .gc/gate-focus.state (what gate-focus-mode.sh measured last), with its age
plus: the switches (gate focus mode, E5, E11, E12, pre-gate) and the MODEL PER ROLE — the alias in each
agents/<role>/agent.toml resolved through the newest Claude Code model catalog on this machine — compared with
the previous run's snapshot. Athos, 07/10: "nunca rollback de modelo; nunca um modelo que já tem sucessor" —
so this never pins a model; it only makes a change VISIBLE the day it happens (the 28/09 Sonnet 5 -> 5.5 switch
went unexplained for a week).

THREE STATES everywhere: a number, or "não medido (<why>)". A file that cannot be read never prints as 0.

Usage: gate-daily-report.py [--day YYYY-MM-DD] [--post] [--city PATH]
  --post   comment on ga-ufskhy via `bd` and send `notify`; without it, print only (dry run).
"""
import argparse, datetime, glob, json, os, re, statistics, subprocess, sys

TZ = datetime.timezone(datetime.timedelta(hours=-3))
PROGRAM_BEAD = os.environ.get("GATE_DAILY_PROGRAM_BEAD", "ga-ufskhy")
ROLES = ("gate-reviewer", "wa-worker", "ps-worker", "refino-gate-reviewer", "auto-refiner",
         "digo-wa", "oracle-wa", "peter-wa", "thies-wa", "mila-wa", "batista-wa")


def nm(why):
    return f"não medido ({why})"


def read_jsonl_day(city, day):
    """Returns (metrics dict) or a string reason when the file could not be read."""
    path = os.path.join(city, ".gc", "quality-gate.jsonl")
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError as e:
        return f"jsonl ilegível: {e.__class__.__name__}"
    rows = []
    with fh:
        for line in fh:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("event") != "dispatcher_complete" or str(e.get("dry_run")) == "1":
                continue
            r = str(e.get("result", "")).upper()
            if r not in ("PASS", "FAIL"):
                continue
            try:
                ts = datetime.datetime.fromisoformat(str(e["ts"]).replace("Z", "+00:00")).astimezone(TZ)
            except (KeyError, ValueError):
                continue
            try:
                el = float(e.get("elapsed_s") or 0)
            except ValueError:
                el = 0.0
            rows.append((ts, str(e.get("bead") or ""), r, el, str(e.get("rig") or "")))
    rows.sort()
    first = {}
    for ts, b, r, el, rig in rows:
        first.setdefault(b, (ts, r))
    d = [x for x in rows if x[0].date() == day]
    p = sum(1 for x in d if x[2] == "PASS")
    fa = [v for v in first.values() if v[0].date() == day]
    fp = sum(1 for v in fa if v[1] == "PASS")
    by_rig = {}
    for ts, b, r, el, rig in d:
        by_rig.setdefault(rig or "?", [0, 0])[0 if r == "PASS" else 1] += 1
    return {
        "verdicts": len(d), "pass": p, "fail": len(d) - p,
        "pass_rate": (p / len(d)) if d else None,
        "first_n": len(fa), "first_pass": fp, "first_rate": (fp / len(fa)) if fa else None,
        "median_min": (statistics.median([x[3] / 60 for x in d]) if d else None),
        "by_rig": by_rig,
    }


def read_kv(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return dict(l.strip().split("=", 1) for l in fh if "=" in l)
    except OSError:
        return None


def queue_now(city):
    st = read_kv(os.path.join(city, ".gc", "gate-focus.state"))
    if not st:
        return nm("sem gate-focus.state"), st
    try:
        depth = int(st.get("depth", ""))
        age_min = (datetime.datetime.now(tz=TZ).timestamp() - int(st.get("at", ""))) / 60
    except ValueError:
        return nm("gate-focus.state corrompido"), st
    return f"{depth} (medida há {age_min:.0f} min)", st


def switches(city, st):
    gc = os.path.join(city, ".gc")
    def flag(name):
        p = os.path.join(gc, name)
        if os.path.islink(p) and not os.path.exists(p):
            return "ilegível (symlink pendurado)"
        return "ligado" if os.path.exists(p) else "desligado"
    focus = "?"
    if st:
        focus = {"1": "LIGADO", "0": "desligado"}.get(st.get("active"), "ilegível")
    e5 = flag("gate-e5-second-reviewer.on")
    if e5 == "ligado" and focus == "LIGADO":
        e5 = "ligado, SUSPENSO pelo modo foco"
    e11 = flag("gate-e11-diff-cap.on")
    if e11 == "ligado":
        e11 += " (100%)" if flag("gate-e11-diff-cap.all") == "ligado" else " (50% por hash)"
    e12 = read_kv(os.path.join(gc, "e12-ab.conf"))
    e12s = "desligado" if e12 is None else f"ligado ({e12.get('treated_pct','?')}% tratados)"
    pregate = "desligado" if os.path.exists(os.path.join(gc, "pregate.off")) else "ligado"
    return {"modo foco": focus, "E5 2º revisor": e5, "E11 teto 800 linhas": e11,
            "E12 3º estado na escrita": e12s, "E3 pré-revisão": pregate}


def newest_catalog():
    files = glob.glob(os.path.expanduser("~/.gastown/claude-accounts/*/cache/model-catalog/*.json"))
    files += glob.glob(os.path.expanduser("~/.claude/cache/model-catalog/*.json"))
    best = None
    for f in files:
        try:
            j = json.load(open(f, encoding="utf-8"))
        except (OSError, ValueError):
            continue
        key = str(j.get("fetchedAt") or "")
        if best is None or key > best[0]:
            best = (key, j)
    return best[1] if best else None


def resolve_alias(alias, catalog):
    """alias ('sonnet','opus','haiku') -> model id via short_name; an explicit id passes through; unknown -> None."""
    if not alias:
        return None
    if alias.startswith("claude-"):
        return alias
    if not catalog:
        return None
    models = (((catalog.get("catalog") or {}).get("config") or {}).get("models")) or []
    hits = [m.get("id") for m in models if str(m.get("short_name", "")).lower() == alias.lower() and m.get("id")]
    return hits[0] if hits else None


def models_per_role(city):
    cat = newest_catalog()
    out = {}
    for role in ROLES:
        p = os.path.join(city, "agents", role, "agent.toml")
        try:
            txt = open(p, encoding="utf-8").read()
        except OSError:
            out[role] = {"alias": None, "model": nm("agent.toml ausente")}
            continue
        m = re.search(r'^model\s*=\s*"([^"]+)"', txt, re.M)
        alias = m.group(1) if m else None
        rid = resolve_alias(alias, cat)
        out[role] = {"alias": alias, "model": rid or nm("alias sem resolução no catálogo" if alias else "sem model= no agent.toml")}
    return out, ("catálogo " + str((cat or {}).get("fetchedAt") or "?")) if cat else "catálogo ausente"


def diff_models(city, now):
    """Compare with the previous snapshot; return list of change lines and write the new snapshot."""
    sp = os.path.join(city, ".gc", "state", "gate-daily-models.json")
    prev = None
    try:
        prev = json.load(open(sp, encoding="utf-8"))
    except (OSError, ValueError):
        prev = None
    changes = []
    if prev is None:
        changes.append("primeira foto dos modelos por papel (sem comparação)")
    else:
        for role, cur in now.items():
            old = (prev.get(role) or {}).get("model")
            if old and cur["model"] != old and not str(cur["model"]).startswith("não medido"):
                changes.append(f"MUDOU: {role} {old} -> {cur['model']} (alias {cur['alias']})")
    try:
        os.makedirs(os.path.dirname(sp), exist_ok=True)
        tmp = sp + ".tmp"
        json.dump(now, open(tmp, "w", encoding="utf-8"), indent=1)
        os.replace(tmp, sp)
    except OSError as e:
        changes.append(f"não consegui gravar a foto de hoje ({e.__class__.__name__})")
    return changes


def levers(city, day):
    """The day's lever facts, one line each, each from its own source and each honest about an unreadable source:
    timeouts + E13 graces (dispatcher log, local-dated lines), E11 decisions (guard log), E13 outcomes (ledger,
    UTC rows). An unreadable source prints 'não medido (motivo)' for ITS line — never a zero that looks like
    'nothing happened' (ga-ufskhy, 07/10)."""
    dstr = day.strftime("%Y-%m-%d")
    out = {}
    # timeouts + grace sweeps — dispatcher log
    p = os.path.join(city, ".gc", "logs", "quality-gate-dispatcher.log")
    try:
        runs, busy, graced = set(), set(), set()
        with open(p, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if not line.startswith("[" + dstr):
                    continue
                m = re.search(r"gate-run (ga-[a-z0-9]+) \(branch=[^)]*\) TIMED OUT after", line)
                if m:
                    runs.add(m.group(1))
                    if "busy=1" in line:
                        busy.add(m.group(1))
                m = re.search(r"gate-run (ga-[a-z0-9]+) \(branch=[^)]*\) is PAST its .*E13 GRACE", line)
                if m:
                    graced.add(m.group(1))
        out["timeouts"] = "%d run(s) estouraram o tempo%s" % (len(runs), (" (%d com revisor ocupado no corte)" % len(busy)) if runs else "")
        out["graced"] = "%d run(s) receberam grace E13" % len(graced)
    except OSError as e:
        out["timeouts"] = nm("log do dispatcher ilegível: %s" % e.__class__.__name__)
        out["graced"] = out["timeouts"]
    # E11 decisions — guard log
    p = os.path.join(city, ".gc", "logs", "quality-gate-guard.log")
    try:
        c = {}
        with open(p, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if not line.startswith("[" + dstr) or "E11-DIFF-CAP bead=" not in line:
                    continue
                m = re.search(r" verdict=([a-z-]+) ", line)
                if m:
                    c[m.group(1)] = c.get(m.group(1), 0) + 1
        if c:
            out["e11"] = "%d recusa(s), %d dentro do teto, %d controle, %d não medida(s)" % (
                c.get("recusa", 0), c.get("dentro-do-teto", 0), c.get("controle", 0),
                sum(v for k, v in c.items() if k.startswith("nao-medido")))
        else:
            out["e11"] = "0 decisões registradas"
    except OSError as e:
        out["e11"] = nm("log do guard ilegível: %s" % e.__class__.__name__)
    # E13 outcomes — ledger (UTC rows)
    p = os.path.join(city, ".gc", "gate-e13.jsonl")
    try:
        delivered, exhausted, graced_runs = set(), set(), set()
        with open(p, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    e = json.loads(line)
                    ts = datetime.datetime.fromisoformat(str(e["ts"]).replace("Z", "+00:00")).astimezone(TZ)
                except (ValueError, KeyError, TypeError):
                    continue
                if ts.date() != day:
                    continue
                run = str(e.get("run") or "")
                if e.get("event") == "e13_grace":
                    graced_runs.add(run)
                elif e.get("event") == "e13_outcome":
                    (delivered if e.get("outcome") == "delivered-past-budget" else exhausted).add(run)
        out["e13"] = "%d run(s) entregaram depois do orçamento, %d esgotaram a grace (ledger: %d com grace)" % (
            len(delivered), len(exhausted), len(graced_runs))
    except OSError as e:
        out["e13"] = nm("ledger E13 ilegível: %s" % e.__class__.__name__)
    return out


def pct(x):
    return nm("sem vereditos") if x is None else f"{x:.0%}"


def build(city, day):
    m = read_jsonl_day(city, day)
    q, st = queue_now(city)
    sw = switches(city, st)
    models, catnote = models_per_role(city)
    changes = diff_models(city, models)
    L = []
    L.append(f"GATE — relatório diário {day.strftime('%d/%m')} (script, {datetime.datetime.now(tz=TZ).strftime('%d/%m %H:%M')} BRT)")
    if isinstance(m, str):
        L.append(f"1) 1ª tentativa: {nm(m)}  2) aprovadas: {nm(m)}  3) revisão mediana: {nm(m)}")
    else:
        L.append(f"1) 1ª tentativa: {pct(m['first_rate'])} ({m['first_pass']}/{m['first_n']} beads)")
        L.append(f"2) aprovadas: {m['pass']} (vereditos {m['verdicts']}, FAIL {m['fail']}, taxa {pct(m['pass_rate'])})")
        med = nm("sem vereditos") if m["median_min"] is None else "%.0f min" % m["median_min"]
        L.append(f"3) revisão mediana: {med}")
        if m["by_rig"]:
            L.append("   por rig: " + "; ".join(f"{r} {v[0]}/{v[0]+v[1]}" for r, v in sorted(m["by_rig"].items())))
    L.append(f"4) fila do gate agora: {q}")
    lv = levers(city, day)
    L.append(f"5) tempo estourado: {lv['timeouts']} | {lv['graced']} | E13: {lv['e13']}")
    L.append(f"6) E11 (teto 800 linhas de produção): {lv['e11']}")
    L.append("Chaves: " + "; ".join(f"{k}={v}" for k, v in sw.items()))
    L.append("Modelos por papel (" + catnote + "): " + "; ".join(f"{r}={v['alias'] or '-'}→{v['model']}" for r, v in models.items() if r in ('gate-reviewer','wa-worker','ps-worker','digo-wa')))
    for c in changes:
        L.append("⚠ " + c if c.startswith("MUDOU") else "• " + c)
    L.append("Metas (Athos 05/10 + 07/10): sex 10/10 ≥50% 1ª / ≤20 min / ≥45 aprovadas / fila <15; seg 13/10 ≥60% / ≥60.")
    return "\n".join(L), m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day")
    ap.add_argument("--post", action="store_true")
    ap.add_argument("--city", default=os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or "/Users/athos/gt/.gascity-gastown-hq")
    a = ap.parse_args()
    day = datetime.date.fromisoformat(a.day) if a.day else (datetime.datetime.now(tz=TZ).date() - datetime.timedelta(days=1))
    text, m = build(a.city, day)
    print(text)
    try:
        os.makedirs(os.path.join(a.city, ".gc", "logs"), exist_ok=True)
        with open(os.path.join(a.city, ".gc", "logs", "gate-daily-report.log"), "a", encoding="utf-8") as fh:
            fh.write(text + "\n---\n")
    except OSError:
        pass
    if not a.post:
        return 0
    rc = 0
    try:
        subprocess.run(["bd", "-C", a.city, "comment", PROGRAM_BEAD, text], check=True, timeout=120, capture_output=True)
    except Exception as e:  # noqa: BLE001 — report the failure, never hide it
        print(f"WARN: comentário em {PROGRAM_BEAD} falhou: {e}", file=sys.stderr); rc = 1
    short = text.split("\n")[1:4]
    try:
        subprocess.run(["notify", "-t", f"Gate {day.strftime('%d/%m')}", "-p", "3", " · ".join(s.strip() for s in short)], timeout=30, capture_output=True)
    except Exception as e:  # noqa: BLE001
        print(f"WARN: notify falhou: {e}", file=sys.stderr); rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
