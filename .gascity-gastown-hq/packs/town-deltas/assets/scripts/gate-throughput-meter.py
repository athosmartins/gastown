#!/usr/bin/env python3
"""gate-throughput-meter.py — reviews per hour done by the gate, and the alarm when it falls under 8/h (ga-v8p1tx.1.1).

## Contents
- What it measures
- The alarm
- Three states
- Usage and knobs

## What it measures
Athos, 14/11: "média sempre de ao menos 8 revisadas por hora" (mission ga-v8p1tx.1; measured that morning: 2,8/h).
Source: the 'Gate run complete' lines (verdict PASS or FAIL) of .gc/logs/quality-gate-dispatcher.log. One line = one
review finished. SKIPPED_BEAD_CLOSED and every other verdict is not a review and is not counted; a gate_run id seen
twice counts once. Line stamps are local time of the machine (BRT, -03:00), read as such.

## The alarm
Rate = reviews finished in the trailing window (3 h by default) / window hours. Under the target (8/h) → one mail to
the Mayor with the three hourly counts, the 24 h average and a PROBABLE CAUSE read from the gate queue
(.gc/gate-focus.state, written every 5 min by gate-focus-mode.sh):
  fila 0 → oferta (nothing reaches the gate: builders/delivery); fila 1-2 → rasa (weak supply and the 2 reviewer
  slots ≈ 8/h with no slack); fila ≥ 3 → revisores (work is waiting for a reviewer).
One mail per episode (re-sent every 6 h while it lasts), stamped in .gc/state/gate-throughput-meter.json ONLY after the
mail was delivered, so a failed send is retried by the next run. Recovery (rate back to ≥ target) is logged, not mailed.
The same numbers go to the morning report (gate-daily-report.py, line 7) via daily_summary().

## Three states
A number, or "não medido (<why>)" — a log that cannot be read, or that starts later than the window it must cover, is
BLIND, never "0 reviews/h". Blind = no alarm decision, exit 1 (launchd keeps stderr), and one mail to the Mayor after an
hour of blindness, so a meter that sees nothing does not pass for a quiet gate. If the state file cannot be written the
meter does NOT send mail (it could not remember having sent it → one mail every 10 min); it logs a WARN and exits 1.

## Usage and knobs
  gate-throughput-meter.py [--city PATH] [--now EPOCH] [--report] [--dry-run]
    --report   print the numbers only: no state, no lock, no mail
    --dry-run  decide and log, send nothing, write no state (also GTM_DRY_RUN=1)
  env: GTM_ENABLED=0 (kill-switch) · GTM_TARGET (8) · GTM_WINDOW_H (3) · GTM_REMAIL_S (21600) · GTM_BLIND_MAIL_S (3600)
       GTM_QUEUE_MAX_AGE_S (1200) · GTM_GC_BIN (gc)
  One instance at a time (flock on .gc/state/gate-throughput-meter.lock); a second one logs and exits 0.
"""
import argparse, datetime, fcntl, json, os, re, shutil, subprocess, sys, time

sys.dont_write_bytecode = True  # imported by gate-daily-report.py from a tracked directory: no __pycache__ there

BRT = datetime.timezone(datetime.timedelta(hours=-3))
LINE_TS = re.compile(r"^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\]")
RUN_DONE = re.compile(r"=== Gate run complete: gate_run=(\S+) .*?verdict=(PASS|FAIL)\b")


def nm(why):
    return "não medido (%s)" % why


def env_num(name, default):
    """A positive number from the environment. vazio → default; ilegível/≤0 → default (a typo must neither turn the
    alarm off nor into a busy loop)."""
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        v = float(raw)
    except ValueError:
        return default
    return v if v > 0 else default


def fmt(x):
    return ("%.1f" % x).replace(".", ",")


def parse_ts(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%d %H:%M:%S").replace(tzinfo=BRT).timestamp()
    except ValueError:
        return None


def log_path(city):
    return os.path.join(city, ".gc", "logs", "quality-gate-dispatcher.log")


def read_completions(path):
    """→ (runs, first_ts, last_ts, None) or (None, None, None, reason).
    runs = sorted [(epoch, gate_run)] of PASS/FAIL completions; first/last = oldest/newest stamped line of the log."""
    # vazio → runs == [] (a log that covers the time and has no completion is a real zero);
    # falhou/ilegível → a reason string and runs None, never an empty list
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError as e:
        return None, None, None, "log do dispatcher ilegível: %s" % e.__class__.__name__
    runs, first, last = {}, None, None
    try:
        with fh:
            for line in fh:
                m = LINE_TS.match(line)
                if not m:
                    continue
                ts = parse_ts(m.group(1))
                if ts is None:
                    continue
                if first is None:
                    first = ts
                last = ts
                if "Gate run complete" not in line:
                    continue
                r = RUN_DONE.search(line)
                if r and r.group(1) not in runs:
                    runs[r.group(1)] = ts
    except OSError as e:
        return None, None, None, "log do dispatcher ilegível no meio da leitura: %s" % e.__class__.__name__
    if first is None:
        return None, None, None, "log do dispatcher sem nenhuma linha com carimbo de hora"
    return sorted((t, g) for g, t in runs.items()), first, last, None


def count(runs, lo, hi):
    return sum(1 for t, _ in runs if lo <= t < hi)


def hourly(runs, now, n):
    """Counts of the n hours before `now`, most recent first: [now-1h, now), [now-2h, now-1h) ..."""
    return [count(runs, now - 3600 * (i + 1), now - 3600 * i) for i in range(n)]


def evaluate(runs, first, now, target, hours):
    """ok / alarm / blind for the trailing window. Blind when the log starts after the window opens."""
    lo = now - hours * 3600
    if first > lo:
        return {"state": "blind", "why": "o log do dispatcher só cobre desde %s, menos que a janela de %dh"
                % (datetime.datetime.fromtimestamp(first, BRT).strftime("%d/%m %H:%M"), hours)}
    n = count(runs, lo, now)
    rate = n / float(hours)
    out = {"state": "alarm" if rate < target else "ok", "n": n, "rate": rate, "hours": hours,
           "per_hour": hourly(runs, now, hours)}
    if first <= now - 86400:
        out["n24"] = count(runs, now - 86400, now)
        out["avg24"] = out["n24"] / 24.0
    else:
        out["avg24"] = None
        out["avg24_why"] = "o log só cobre desde %s" % datetime.datetime.fromtimestamp(first, BRT).strftime("%d/%m %H:%M")
    return out


def queue_read(city, now, max_age):
    """→ (depth or None, text). Three states: a depth; 'não medido (<why>)' for absent / corrupt / stale."""
    # vazio/ausente → depth None, 'não medido'; ilegível ou velho demais → depth None, 'não medido' with the reason
    p = os.path.join(city, ".gc", "gate-focus.state")
    try:
        with open(p, encoding="utf-8") as fh:
            kv = dict(l.strip().split("=", 1) for l in fh if "=" in l)
    except OSError:
        return None, nm("sem gate-focus.state")
    try:
        depth, at = int(kv["depth"]), int(kv["at"])
    except (KeyError, ValueError):
        return None, nm("gate-focus.state corrompido")
    age = now - at
    if age > max_age or age < -300:
        return None, nm("gate-focus.state de %d min atrás" % (age // 60))
    return depth, "%d (medida há %d min)" % (depth, max(age, 0) // 60)


def cause_of(depth):
    """→ (short label for the mail subject, sentence for the body). depth None = queue not measured → undetermined."""
    if depth is None:
        return "causa indeterminada", "causa indeterminada: a fila do gate não foi medida"
    if depth == 0:
        return "oferta", "OFERTA: fila do gate vazia — nada chega pra revisar (construtores/entrega), não é falta de revisor"
    if depth <= 2:
        return "fila rasa", "fila rasa (%d): oferta fraca e os 2 slots de revisor (≈8/h) já sem folga" % depth
    return "revisores", "REVISORES: %d beads esperando revisor — capacidade do gate (slots/revisores)" % depth


def state_path(city):
    return os.path.join(city, ".gc", "state", "gate-throughput-meter.json")


def read_state(path):
    """The saved state, or {} when there is none. Absent = first run; unreadable or corrupt also reads as {} — the
    worst case is one repeated mail, never a missed alarm — and the next write replaces the file."""
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return {}
    return d if isinstance(d, dict) else {}


def write_state(path, d):
    """True when the state is on disk. False (nothing changed) otherwise."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp.%d" % os.getpid()
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(d, fh)
            os.replace(tmp, path)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return True
    except OSError:
        return False


def send_mail(city, subject, body):
    """None when the mail was delivered, else a one-line reason. Only rc 0 counts as delivered."""
    # falhou (rc≠0 / timeout / gc não inicia) → a reason string, never None
    gc = os.environ.get("GTM_GC_BIN") or shutil.which("gc") or "gc"
    env = dict(os.environ, GC_CITY_PATH=city)
    try:
        r = subprocess.run([gc, "mail", "send", "mayor", "-s", subject, "-m", body], cwd=city, env=env,
                           timeout=90, capture_output=True, text=True, errors="replace")
    except subprocess.TimeoutExpired:
        return "gc mail send passou de 90s sem terminar"
    except OSError as e:
        return "%s: %s" % (e.__class__.__name__, e)
    if r.returncode != 0:
        tail = " | ".join((r.stderr or "").strip().splitlines())[-300:]
        return "gc mail send saiu com rc=%d: %s" % (r.returncode, tail or "(sem stderr)")
    return None


def alarm_mail(ev, qtext, cause, target, since, last_seen, now, repeat):
    short, cause = cause
    ph = ev["per_hour"]
    names = ["última hora", "2ª hora atrás", "3ª hora atrás"] + ["%dª hora atrás" % (i + 1) for i in range(3, len(ph))]
    avg24 = nm(ev["avg24_why"]) if ev["avg24"] is None else "%s/h (%d revisadas em 24 h)" % (fmt(ev["avg24"]), ev["n24"])
    subj = "Gate abaixo de %s/h: %s/h nas últimas %dh — %s" % (fmt(target), fmt(ev["rate"]), ev["hours"], short)
    lines = []
    if repeat:
        lines.append("AINDA em alarme desde %s (mail repetido a cada 6 h)." % datetime.datetime.fromtimestamp(since, BRT).strftime("%d/%m %H:%M"))
    lines += [
        "Revisadas pelo gate: %s/h na janela de %dh (%d revisadas; meta ≥ %s/h, Athos 14/11, missão ga-v8p1tx.1)."
        % (fmt(ev["rate"]), ev["hours"], ev["n"], fmt(target)),
        "Por hora: " + "; ".join("%s %d" % (names[i], c) for i, c in enumerate(ph)) + ".",
        "Média 24 h: %s." % avg24,
        "Fila do gate agora: %s." % qtext,
        "Causa provável: %s." % cause,
        "Último registro do dispatcher há %d min." % max((now - last_seen) // 60, 0),
        "Ver: bash scripts/gate-queue-composition.sh (fila real/fantasma) · .gc/logs/quality-gate-dispatcher.log · "
        ".gc/logs/gate-throughput-meter.log",
        "Fonte: linhas 'Gate run complete' (PASS+FAIL) do log do dispatcher. Medidor: ga-v8p1tx.1.1.",
    ]
    return subj, "\n".join(lines)


def logline(city, msg, out=True):
    line = "[%s] %s" % (datetime.datetime.now(BRT).strftime("%Y-%m-%d %H:%M:%S"), msg)
    if out:
        print(line)
    try:
        os.makedirs(os.path.join(city, ".gc", "logs"), exist_ok=True)
        with open(os.path.join(city, ".gc", "logs", "gate-throughput-meter.log"), "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass  # the stdout line above is still kept by launchd


def daily_summary(city, day, now=None):
    """The morning report's line 7 for local day `day` (a date): the day's average per hour, how many hours reached the
    target, and the trailing 3 h at report time. 'não medido (<why>)' for what cannot be known."""
    now = time.time() if now is None else now
    target = env_num("GTM_TARGET", 8.0)
    runs, first, _last, why = read_completions(log_path(city))
    if runs is None:
        return nm(why)
    d0 = datetime.datetime(day.year, day.month, day.day, tzinfo=BRT).timestamp()
    if first > d0:
        day_txt = nm("o log do dispatcher só cobre desde %s" % datetime.datetime.fromtimestamp(first, BRT).strftime("%d/%m %H:%M"))
    else:
        end = min(d0 + 86400, now)
        span_h = (end - d0) / 3600.0
        if span_h <= 0:
            day_txt = nm("dia no futuro")
        else:
            n = count(runs, d0, end)
            hrs = [count(runs, d0 + 3600 * i, d0 + 3600 * (i + 1)) for i in range(int(span_h))]
            day_txt = "%s/h no dia (%d revisadas em %s h%s; %d de %d horas com ≥ %s)" % (
                fmt(n / span_h), n, ("%d" % span_h) if span_h == int(span_h) else fmt(span_h),
                ", dia em andamento" if d0 + 86400 > now else "", sum(1 for h in hrs if h >= target), len(hrs), fmt(target))
    ev = evaluate(runs, first, now, target, 3)
    if ev["state"] == "blind":
        last3 = nm(ev["why"])
    else:
        last3 = "%s/h nas últimas 3 h até agora (%d revisadas)" % (fmt(ev["rate"]), ev["n"])
    return "%s; %s; meta ≥ %s/h" % (day_txt, last3, fmt(target))


def run(city, now, dry, report):
    target = env_num("GTM_TARGET", 8.0)
    hours = int(env_num("GTM_WINDOW_H", 3))
    remail = env_num("GTM_REMAIL_S", 21600)
    blind_mail_after = env_num("GTM_BLIND_MAIL_S", 3600)
    qmax = env_num("GTM_QUEUE_MAX_AGE_S", 1200)
    runs, first, last, why = read_completions(log_path(city))
    sp = state_path(city)
    st = read_state(sp)
    ev = None if runs is None else evaluate(runs, first, now, target, hours)

    if ev is None or ev["state"] == "blind":
        reason = why if ev is None else ev["why"]
        logline(city, "BLIND: %s — sem decisão de alarme, nenhum número (nunca 0/h)" % reason)
        if report or dry:
            return 1
        st["blind_since"] = st.get("blind_since") or now
        if now - st["blind_since"] >= blind_mail_after and now - st.get("blind_mailed", 0) >= remail:
            if not write_state(sp, st):
                logline(city, "WARN: estado ilegível/não gravável (%s) — sem mail de cegueira (não saberia deduplicar)" % sp)
                return 1
            err = send_mail(city, "Medidor do gate CEGO há %d min (revisadas/hora)" % ((now - st["blind_since"]) // 60),
                            "O medidor de revisadas/hora do gate não consegue medir: %s.\nSem ele o alarme de <%s/h não dispara. "
                            "Medidor: gate-throughput-meter.py (ga-v8p1tx.1.1)." % (reason, fmt(target)))
            if err:
                logline(city, "WARN: mail de cegueira ao Mayor FALHOU (%s) — sem carimbo, a próxima rodada tenta de novo" % err)
                return 1
            st["blind_mailed"] = now
        write_state(sp, st)
        return 1

    depth, qtext = queue_read(city, now, qmax)
    cause = cause_of(depth)
    avg24 = nm(ev["avg24_why"]) if ev["avg24"] is None else "%s/h" % fmt(ev["avg24"])
    summary = "%d revisadas em %dh = %s/h (por hora, mais recente primeiro: %s); média 24 h %s; fila: %s" % (
        ev["n"], hours, fmt(ev["rate"]), "/".join(str(c) for c in ev["per_hour"]), avg24, qtext)
    if report:
        print("%s: %s | %s" % (ev["state"].upper(), summary, cause[1]))
        return 0

    if ev["state"] == "ok":
        if st.get("alarm_since"):
            logline(city, "RECOVERED: %s — alarme desde %s encerrado" % (
                summary, datetime.datetime.fromtimestamp(st["alarm_since"], BRT).strftime("%d/%m %H:%M")))
        else:
            logline(city, "OK: %s" % summary)
        if not dry:
            st.pop("alarm_since", None); st.pop("last_mail", None); st.pop("blind_since", None); st.pop("blind_mailed", None)
            if not write_state(sp, st):
                logline(city, "WARN: não consegui gravar %s" % sp)
                return 1
        return 0

    # ALARM
    st.pop("blind_since", None); st.pop("blind_mailed", None)
    since = st.get("alarm_since") or now
    last_mail = st.get("last_mail")
    due = last_mail is None or now - last_mail >= remail
    logline(city, "ALARM: %s | %s%s" % (summary, cause[1], "" if due else " | mail já enviado há %d min" % ((now - last_mail) // 60)))
    if dry:
        logline(city, "DRY_RUN: %s" % ("enviaria mail ao Mayor" if due else "sem mail novo (dentro do intervalo)"))
        return 0
    if not due:
        return 0 if write_state(sp, dict(st, alarm_since=since)) else 1
    # Probe the state write BEFORE sending: a mail that cannot be remembered would repeat every run.
    if not write_state(sp, dict(st, alarm_since=since)):
        logline(city, "WARN: estado não gravável (%s) — NÃO enviei o mail (não saberia deduplicar)" % sp)
        return 1
    subj, body = alarm_mail(ev, qtext, cause, target, since, last, now, repeat=last_mail is not None)
    err = send_mail(city, subj, body)
    if err:
        logline(city, "WARN: mail ao Mayor FALHOU (%s) — sem carimbo, a próxima rodada tenta de novo" % err)
        return 1
    st.update(alarm_since=since, last_mail=now)
    if not write_state(sp, st):
        logline(city, "WARN: mail enviado mas o carimbo não gravou em %s — a próxima rodada pode repetir" % sp)
        return 1
    logline(city, "MAIL: alarme enviado ao Mayor — %s" % subj)
    return 0


def main():
    ap = argparse.ArgumentParser(description="revisadas/hora do gate + alarme ao Mayor (ga-v8p1tx.1.1)")
    ap.add_argument("--city", default=os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or "/Users/athos/gt/.gascity-gastown-hq")
    ap.add_argument("--now", type=float, default=None, help="epoch (tests)")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if os.environ.get("GTM_ENABLED", "1") == "0":
        print("gate-throughput-meter: GTM_ENABLED=0 — desligado")
        return 0
    now = a.now if a.now is not None else time.time()
    dry = a.dry_run or os.environ.get("GTM_DRY_RUN") == "1"
    if a.report:
        return run(a.city, now, dry, True)
    lock_path = os.path.join(a.city, ".gc", "state", "gate-throughput-meter.lock")
    try:
        os.makedirs(os.path.dirname(lock_path), exist_ok=True)
        lock = open(lock_path, "w")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        logline(a.city, "outra instância em andamento — saindo")
        return 0
    except OSError as e:
        logline(a.city, "WARN: sem lock (%s) — não rodo sem exclusão mútua" % e.__class__.__name__)
        return 1
    return run(a.city, now, dry, False)


if __name__ == "__main__":
    sys.exit(main())
