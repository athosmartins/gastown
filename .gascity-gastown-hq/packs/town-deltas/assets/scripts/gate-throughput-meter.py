#!/usr/bin/env python3
"""gate-throughput-meter.py — quantas beads o gate revisa por hora, e o alarme quando fica abaixo da meta (ga-v8p1tx.1.1).

POR QUE EXISTE: Athos, 14/11: "média sempre de ao menos 8 revisadas por hora". Medido no mesmo dia: 2,8/h
(27 runs em 9,4 h; melhor dia 98/24 h ≈ 4/h). Sem medidor, a missão (ga-v8p1tx.1) só seria notada quando alguém
fizesse a conta à mão. Este script faz a conta, no launchd, e avisa o Mayor com a causa provável.

FONTE: as linhas "=== Gate run complete: ... verdict=PASS|FAIL ===" de .gc/logs/quality-gate-dispatcher.log
(horário local BRT, -03). SKIPPED_* e qualquer outro veredito NÃO contam: "revisada" é PASS + FAIL.

O QUE MEDE (agora = --now ou o relógio):
  - taxa da janela: runs nas últimas 3 h / 3
  - média de 24 h: runs nas últimas 24 h / 24, mais os 24 baldes de 1 h (do mais velho ao mais novo)
  - com --day YYYY-MM-DD: o mesmo para o dia local inteiro (usado pelo relatório diário das 09:03)

ALARME (--alarm; é o que o launchd roda a cada 15 min): taxa da janela < meta (8/h) → UM mail ao Mayor com a causa
provável, no máximo um por cooldown (6 h; no máximo 4 por dia). Causa, lida da fila do gate (.gc/gate-focus.state,
que o gate-focus-mode.sh grava a cada 5 min): fila com ≥ 3 markers (mais que os 2 revisores locais) ⇒ REVISORES;
fila menor ⇒ OFERTA (quem constrói não está entregando); fila ilegível ou velha ⇒ "causa não medida".

TRÊS ESTADOS em tudo: um número, ou "não medido (<motivo>)". Log que não abre, ou que começa DEPOIS do início da
janela (rotação), nunca vira "0 revisadas" — vira "não medido", que não dispara o alarme de taxa. Para o medidor
não ficar cego em silêncio: ≥ 3 h seguidas sem conseguir medir mandam UM mail "medidor cego" (mesmo cooldown).

INERTE SOB DÚVIDA: o estado do cooldown é gravado ANTES do mail; se não der para gravar, o mail não sai (e o
run sai 1). Se o mail falha, o cooldown volta ao valor anterior (se nem isso der para gravar, o WARN diz que o cooldown
ficou consumido) e o run sai 1 — tenta de novo no próximo ciclo.

Uso: gate-throughput-meter.py [--day YYYY-MM-DD] [--json] [--alarm] [--now EPOCH] [--city PATH] [--log PATH]
  sem --alarm: só imprime (dry run, não escreve estado nem manda mail).
Ambiente: GATE_MEASURE_TARGET_PER_H (8), GATE_MEASURE_WINDOW_H (3), GATE_MEASURE_COOLDOWN_S (21600),
  GATE_MEASURE_BLIND_AFTER_S (10800), GATE_MEASURE_QUEUE_FULL (3), GATE_MEASURE_GC (gc).
"""
import argparse, datetime, fcntl, json, os, re, subprocess, sys, time

TZ = datetime.timezone(datetime.timedelta(hours=-3))
LOG_NAME = "quality-gate-dispatcher.log"
RUN_RE = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] .*=== Gate run complete: .*?verdict=([A-Za-z_]+)")
TS_RE = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]")


def _num(name, default):
    # vazio → default; ilegível (não é número) → default também, e o valor usado aparece no log do run
    try:
        return float(os.environ.get(name) or default)
    except ValueError:
        return float(default)


TARGET = _num("GATE_MEASURE_TARGET_PER_H", 8)
WINDOW_H = int(_num("GATE_MEASURE_WINDOW_H", 3))
COOLDOWN_S = _num("GATE_MEASURE_COOLDOWN_S", 21600)
BLIND_AFTER_S = _num("GATE_MEASURE_BLIND_AFTER_S", 10800)
QUEUE_FULL = int(_num("GATE_MEASURE_QUEUE_FULL", 3))
STATE_MAX_AGE_S = 1800   # gate-focus.state mais velho que isto não diz nada sobre a fila de agora
LOG_STALE_S = 1800       # dispatcher sem escrever nada há tanto tempo = suspeito de parado


def nm(why):
    return f"não medido ({why})"


def fmt(x):
    return f"{x:.1f}".replace(".", ",")


def to_epoch(s):
    return datetime.datetime.strptime(s, "%Y-%m-%d %H:%M:%S").replace(tzinfo=TZ).timestamp()


def read_log(path):
    """Devolve dict(runs=[(epoch, veredito)], first=epoch|None, last=epoch|None) ou uma string com o motivo."""
    # vazio → runs=[] (é válido: o log abriu e não tem nenhum "Gate run complete"; a cobertura decide se isso é 0 de verdade);
    # falhou/ilegível → devolve o motivo em texto, e quem chama imprime "não medido" — nunca 0
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError as e:
        return f"log ilegível: {e.__class__.__name__}"
    runs, first, last = [], None, None
    try:
        with fh:
            for line in fh:
                if line[:1] != "[":
                    continue
                m = TS_RE.match(line)
                if not m:
                    continue
                try:
                    t = to_epoch(m.group(1))
                except ValueError:
                    continue
                if first is None:
                    first = t
                last = t
                if "Gate run complete" in line:
                    r = RUN_RE.match(line)
                    if r:
                        runs.append((t, r.group(2)))
    except OSError as e:
        return f"log ilegível: {e.__class__.__name__}"
    return {"runs": runs, "first": first, "last": last}


def count(runs, a, b):
    return sum(1 for t, v in runs if a <= t < b and v in ("PASS", "FAIL"))


def measure(log, now, day=None):
    """Mede as janelas. log = retorno de read_log. Cada métrica é número ou None + motivo em 'why'."""
    if isinstance(log, str):
        return {"ok": False, "why": log}
    first = log["first"]
    if first is None:
        # log aberto mas sem uma única linha datada: não há como saber a cobertura
        return {"ok": False, "why": "log sem nenhuma linha datada"}
    out = {"ok": True, "now": now, "last_line_age_s": None if log["last"] is None else now - log["last"], "why": {}}
    last_run = max((t for t, v in log["runs"] if v in ("PASS", "FAIL")), default=None)
    out["last_run_age_s"] = None if last_run is None else now - last_run
    w0 = now - WINDOW_H * 3600
    if first <= w0:
        n = count(log["runs"], w0, now + 1)
        out["window_h"], out["window_count"], out["window_rate"] = WINDOW_H, n, n / WINDOW_H
    else:
        out["window_rate"] = None
        out["why"]["window"] = f"log só começa em {datetime.datetime.fromtimestamp(first, TZ):%d/%m %H:%M}"
    if first <= now - 24 * 3600:
        out["hourly24"] = [count(log["runs"], now - (k + 1) * 3600, now - k * 3600) for k in range(23, -1, -1)]
        out["avg24"] = sum(out["hourly24"]) / 24
    else:
        out["avg24"] = None
        out["why"]["avg24"] = f"log só começa em {datetime.datetime.fromtimestamp(first, TZ):%d/%m %H:%M}"
    if day is not None:
        d0 = datetime.datetime(day.year, day.month, day.day, tzinfo=TZ).timestamp()
        d1 = d0 + 86400
        if d1 > now:
            out["day"] = {"date": day.isoformat(), "avg": None, "why": "dia ainda em curso"}
        elif first > d0:
            out["day"] = {"date": day.isoformat(), "avg": None,
                          "why": f"log só começa em {datetime.datetime.fromtimestamp(first, TZ):%d/%m %H:%M}"}
        else:
            h = [count(log["runs"], d0 + i * 3600, d0 + (i + 1) * 3600) for i in range(24)]
            out["day"] = {"date": day.isoformat(), "hourly": h, "total": sum(h), "avg": sum(h) / 24, "why": None}
    return out


def queue_cause(city, now, m):
    """(código, texto) da causa provável. Lê a fila do gate em gate-focus.state."""
    notes = []
    age = m.get("last_line_age_s")
    if age is not None and age > LOG_STALE_S:
        notes.append(f"o log do dispatcher não recebe linha nova há {age / 60:.0f} min (dispatcher parado?)")
    # vazio → arquivo sem depth/at = fila não medida; falhou/ilegível → idem (nunca "fila 0")
    path = os.path.join(city, ".gc", "gate-focus.state")
    depth = at = None
    try:
        with open(path, encoding="utf-8") as fh:
            kv = dict(l.strip().split("=", 1) for l in fh if "=" in l)
        depth, at = int(kv["depth"]), int(kv["at"])
    except (OSError, KeyError, ValueError):
        pass
    if depth is None or now - at > STATE_MAX_AGE_S:
        code, text = "desconhecida", "causa não medida: fila do gate ilegível ou velha (gate-focus.state)"
    elif depth >= QUEUE_FULL:
        code = "revisores"
        text = f"REVISORES: fila do gate com {depth} (≥ {QUEUE_FULL}, mais que os 2 revisores locais) e a revisão não escoa"
    else:
        code = "oferta"
        text = f"OFERTA: fila do gate com {depth} (< {QUEUE_FULL}); os revisores têm folga, falta bead chegando (builders, pool wa-worker, disco/load do mini)"
    return code, "; ".join(notes + [text])


def read_state(path):
    # vazio → {} (primeira execução, sem alarme anterior); falhou/ilegível → None (quem chama NÃO manda mail: inerte)
    try:
        with open(path, encoding="utf-8") as fh:
            return dict(l.strip().split("=", 1) for l in fh if "=" in l)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        return None


def write_state(path, st):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            for k, v in st.items():
                fh.write(f"{k}={v}\n")
        os.replace(tmp, path)
        return True
    except OSError:
        return False


def send_mail(subject, body):
    gc = os.environ.get("GATE_MEASURE_GC") or "gc"
    try:
        r = subprocess.run([gc, "mail", "send", "mayor/", "-s", subject, "-m", body], capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f"{e.__class__.__name__}: {e}"
    if r.returncode != 0:
        return False, f"rc={r.returncode} {r.stderr.decode('utf-8', 'replace').strip()[-300:]}"
    return True, ""


def log_line(city, text):
    try:
        os.makedirs(os.path.join(city, ".gc", "logs"), exist_ok=True)
        with open(os.path.join(city, ".gc", "logs", "gate-throughput-meter.log"), "a", encoding="utf-8") as fh:
            fh.write(f"[{datetime.datetime.fromtimestamp(time.time(), TZ):%Y-%m-%d %H:%M:%S}] {text}\n")
    except OSError:
        pass


def summary(m):
    if not m["ok"]:
        return nm(m["why"])
    w = nm(m["why"]["window"]) if m["window_rate"] is None else f"{fmt(m['window_rate'])}/h ({m['window_count']} em {m['window_h']} h)"
    a = nm(m["why"]["avg24"]) if m["avg24"] is None else f"{fmt(m['avg24'])}/h ({round(m['avg24'] * 24)} em 24 h)"
    return f"janela {m['window_h'] if 'window_h' in m else WINDOW_H} h: {w} | média 24 h: {a} | meta ≥ {fmt(TARGET)}/h"


def run_alarm(city, m, now):
    st_path = os.path.join(city, ".gc", "gate-throughput-meter.state")
    st = read_state(st_path)
    if st is None:
        print("WARN: estado do medidor ilegível; sem alarme (inerte)", file=sys.stderr)
        log_line(city, "WARN estado ilegível — sem alarme")
        return 1
    try:
        last_alarm = float(st.get("last_alarm_at", 0) or 0)
        blind_since = float(st.get("blind_since", 0) or 0)
    except ValueError:
        print("WARN: estado do medidor corrompido; sem alarme (inerte)", file=sys.stderr)
        log_line(city, "WARN estado corrompido — sem alarme")
        return 1
    subject = body = None
    kind = ""
    if m["ok"] and m["window_rate"] is not None:
        blind_since = 0
        if m["window_rate"] < TARGET:
            code, why = queue_cause(city, now, m)
            kind = "baixa"
            subject = f"Gate: {fmt(m['window_rate'])} revisadas/h nas últimas {m['window_h']} h (meta ≥ {fmt(TARGET)}) — causa provável: {code}"
            h = m.get("hourly24")
            body = "\n".join([
                f"- {m['window_count']} revisadas (PASS+FAIL) nas últimas {m['window_h']} h = {fmt(m['window_rate'])}/h; meta do Athos 14/11: ≥ {fmt(TARGET)}/h.",
                "- média 24 h: " + (nm(m["why"]["avg24"]) if m["avg24"] is None else f"{fmt(m['avg24'])}/h") + ".",
                "- por hora, últimas 6 h (mais velha → mais nova): " + (" ".join(str(x) for x in h[-6:]) if h else nm("sem 24 h de log")) + ".",
                "- última revisão: " + ("nenhuma no log" if m["last_run_age_s"] is None else f"há {m['last_run_age_s'] / 60:.0f} min") + ".",
                f"- causa provável — {why}.",
                "- missão: ga-v8p1tx.1 (filhas .2 slot wa-worker, .3 builders no Hetzner, .4 revisores remotos).",
                f"- este mail repete no máximo a cada {COOLDOWN_S / 3600:g} h enquanto a taxa seguir baixa; medidor: gate-throughput-meter.py (ga-v8p1tx.1.1).",
            ])
    else:
        why = m["why"] if not m["ok"] else m["why"].get("window", "janela sem cobertura")
        if not blind_since:
            blind_since = now
        if now - blind_since >= BLIND_AFTER_S:
            kind = "cego"
            subject = "Gate: medidor de revisadas/h CEGO há mais de " + f"{BLIND_AFTER_S / 3600:g} h"
            body = "\n".join([
                f"- não consigo medir a taxa do gate desde {datetime.datetime.fromtimestamp(blind_since, TZ):%d/%m %H:%M} BRT.",
                f"- motivo: {why}.",
                "- sem a medida o alarme de < 8/h não dispara: olhe .gc/logs/quality-gate-dispatcher.log e .gc/logs/gate-throughput-meter.log.",
            ])
    sent = ""
    if subject and now - last_alarm >= COOLDOWN_S:
        st["last_alarm_at"] = int(now)
        st["blind_since"] = int(blind_since) if blind_since else 0
        if not write_state(st_path, st):
            print("WARN: não consegui gravar o estado do medidor; mail NÃO enviado (inerte)", file=sys.stderr)
            log_line(city, f"WARN estado não gravável — mail '{kind}' NÃO enviado")
            return 1
        ok, err = send_mail(subject, body)
        if not ok:
            st["last_alarm_at"] = int(last_alarm)
            restored = write_state(st_path, st)
            note = "" if restored else "; cooldown NÃO restaurado (próximo alarme só depois dele)"
            print(f"WARN: mail ao Mayor falhou ({err}){note}", file=sys.stderr)
            log_line(city, f"WARN mail '{kind}' falhou: {err}{note}")
            return 1
        sent = f" ALARME-{kind}-ENVIADO"
    else:
        st["blind_since"] = int(blind_since) if blind_since else 0
        if not write_state(st_path, st):
            print("WARN: não consegui gravar o estado do medidor", file=sys.stderr)
            return 1
        if subject:
            sent = f" alarme-{kind}-em-cooldown({(COOLDOWN_S - (now - last_alarm)) / 60:.0f}min)"
    log_line(city, summary(m) + sent)
    return 0 if m["ok"] else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--alarm", action="store_true")
    ap.add_argument("--now", type=float)
    ap.add_argument("--city", default=os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or "/Users/athos/gt/.gascity-gastown-hq")
    ap.add_argument("--log")
    a = ap.parse_args()
    now = a.now if a.now is not None else time.time()
    day = datetime.date.fromisoformat(a.day) if a.day else None
    lock = None
    if a.alarm:
        # uma instância por vez: o medidor lê um log de dezenas de MB e não pode empilhar no launchd
        try:
            os.makedirs(os.path.join(a.city, ".gc"), exist_ok=True)
            lock = open(os.path.join(a.city, ".gc", "gate-throughput-meter.lock"), "w")
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("outro run do medidor em curso; saindo")
            return 0
        except OSError as e:
            print(f"WARN: lock do medidor indisponível ({e}); sem alarme (inerte)", file=sys.stderr)
            return 1
    log = read_log(a.log or os.path.join(a.city, ".gc", "logs", LOG_NAME))
    m = measure(log, now, day)
    if a.json:
        print(json.dumps(m, ensure_ascii=False))
    else:
        print(summary(m))
        if m.get("day"):
            d = m["day"]
            print(f"dia {d['date']}: " + (nm(d["why"]) if d["avg"] is None else f"{fmt(d['avg'])}/h ({d['total']} em 24 h)"))
    if a.alarm:
        return run_alarm(a.city, m, now)
    return 0 if m["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
