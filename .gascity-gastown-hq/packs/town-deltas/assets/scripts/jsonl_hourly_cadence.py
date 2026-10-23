#!/usr/bin/env python3
"""jsonl_hourly_cadence.py (ga-c0939v.7) — mede, pelo log do jsonl-hourly-offsite, a cadência REAL do upload ao S3.

Contents
  Por quê · O que conta como publicação · Causas · Saída · Códigos de saída

POR QUÊ: "o upload é horário" era uma intenção, não uma medida. Lendo o log de 16 a 23/10 (124 gaps), 93% dos intervalos entre duas
  publicações do latest.json passaram de 60 min (mediana 1h10) sem que NENHUM run tivesse falhado: o `interval = "1h"` do order soma-se à
  sobra de despacho do controller (mediana ~6 min, p90 ~18 min). Este script refaz a conta, para conferir depois de qualquer mudança de
  cadência (ou de um alarme) com número e não com relato.

O QUE CONTA COMO PUBLICAÇÃO (= o latest.json andou no S3; é o que o restore e o `--status` leem):
  `OK <stem>` (snapshot novo verificado) · `HEAD ... já está no S3 ...: ponto batido` (HEAD igual; só o `checked_at` andou) ·
  `FALHOU: ... (snapshot novo subiu: key=...)` (fonte parada com HEAD novo: o snapshot subiu e o latest.json andou, mas o run saiu rc 1).
  NÃO contam: `FALHOU:` sem "snapshot novo subiu" (nada subiu, ou subiu e o latest.json NÃO andou) e `UNKNOWN:` (nada foi tentado).
  Um run que loga `OK` e, segundos depois, `FALHOU ... snapshot novo subiu` com a MESMA chave é UMA publicação, não duas.

CAUSAS de um gap acima do limite, pelo que o log registra ENTRE as duas publicações (a mais grave primeiro): disco (`UNKNOWN: pouco disco`) ·
  fonte parada (`fonte parada`) · run morto (`run anterior não terminou`) · falha do upload (outro `FALHOU:`) · sem veredito (outro `UNKNOWN:`) ·
  e, se o log não registra nada no meio, "disparo atrasado": o order não rodou no horário (sobra do controller), que não deixa rastro no log.

ATRASO DO DADO ATÉ O S3: por snapshot novo, `dado de há Ns` (quanto o HEAD que o exporter já tinha comitado esperou até este run pegá-lo) + a duração do run
  (da linha `snapshot ...` ao `OK`). É a parte do atraso que ESTE upload controla; o resto do RPO é o exporter (intervalo até comitar), que o log do upload não vê.
  NÃO se mede a "idade do dado publicado" amostrada no tempo: o exporter só comita quando o dado muda, então uma noite parada envelhece o último snapshot (medido:
  p90 de 7 h) sem que nada tenha sido perdido; isso confundiria cidade ociosa com dado atrasado. `ponto batido` (HEAD igual) não traz dado novo e fica de fora.

QUANTIS: posto mais próximo, para cima (índice int(p*n) da lista ordenada): com 10 valores o p90 é o maior. É a conta de toda a medição de 16-23/10.
SAÍDA: texto (padrão) ou `--json`. UTC em tudo. `--since AAAA-MM-DD[THH:MM:SSZ]` recorta a janela; `--limit-s` muda o limite (3600);
  `--list` lista cada gap acima do limite com a causa.
CÓDIGOS: 0 medido · 2 log ilegível ou com menos de 2 publicações na janela (sem número, não é "tudo bem") · 3 uso.
"""
import argparse
import datetime
import json
import os
import re
import sys

TS = re.compile(r"^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\] (.*)$")
SNAP = re.compile(r"^snapshot (\S+) \(HEAD \S+, dado de há (\d+)s\)")
OKL = re.compile(r"^OK (\S+?):")
KEY = re.compile(r"key=\S*?/snap/(\S+?)\.tar\.gz")
CAUSE_ORDER = ["disco", "fonte parada", "run morto", "falha do upload", "sem veredito", "disparo atrasado"]


def ep(s):
    return int(datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp())


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def hm(sec):
    sec = int(sec)
    return "%dh%02dm" % (sec // 3600, (sec % 3600) // 60)


def classify(msg):
    """Linha do log -> causa de run que NÃO publicou, ou None se a linha não é um desfecho que não publicou."""
    if msg.startswith("UNKNOWN:"):
        return "disco" if "pouco disco" in msg else ("fonte parada" if "fonte parada" in msg else "sem veredito")
    if msg.startswith("FALHOU:") and "snapshot novo subiu" not in msg:
        return "fonte parada" if "fonte parada" in msg else "falha do upload"
    if "run anterior não terminou" in msg:
        return "run morto"
    return None


def lag_of(start, stem, t_done):
    """Atraso do dado até o S3 de um snapshot novo: idade do HEAD ao começar o run + duração do run. Sem a linha `snapshot` do mesmo stem: None (não se inventa)."""
    if stem in start:
        t0, head_age = start[stem]
        return head_age + (t_done - t0)
    return None


def parse(lines):
    """-> (publicações [{t, kind, stem, lag}], não-publicações [(t, causa)]). Linha que não casa o formato do log é ignorada."""
    pubs, misses = [], []
    start = {}            # stem -> (início do run, idade do HEAD em s), da linha `snapshot ...`
    last_ok_stem = None
    for line in lines:
        m = TS.match(line.rstrip("\n"))
        if not m:
            continue
        # falhou/ilegível → linha ignorada: tem a forma de um carimbo e não é uma data (mês 13): não derruba a medição nem vira publicação
        try:
            t, msg = ep(m.group(1)), m.group(2)
        except ValueError:
            continue
        sm = SNAP.match(msg)
        if sm:
            start[sm.group(1)] = (t, int(sm.group(2)))
            continue
        om = OKL.match(msg)
        if om:
            stem = om.group(1)
            pubs.append({"t": t, "kind": "novo", "stem": stem, "lag": lag_of(start, stem, t)})
            last_ok_stem = stem
            continue
        if "ponto batido" in msg:
            pubs.append({"t": t, "kind": "mesmo", "stem": None, "lag": None})
            continue
        if msg.startswith("FALHOU:") and "snapshot novo subiu" in msg:
            km = KEY.search(msg)
            stem = km.group(1) if km else None
            if stem is not None and stem == last_ok_stem:
                continue            # o mesmo run já foi contado pelo `OK`
            pubs.append({"t": t, "kind": "novo+falha", "stem": stem, "lag": lag_of(start, stem, t)})
            last_ok_stem = stem
            continue
        c = classify(msg)
        if c:
            misses.append((t, c))
    return pubs, misses


def quantiles(vals):
    v = sorted(vals)
    n = len(v)
    pick = lambda p: v[min(n - 1, int(p * n))]  # noqa: E731
    return {"min": v[0], "p50": pick(0.5), "p90": pick(0.9), "p99": pick(0.99), "max": v[-1]}


def analyse(pubs, misses, limit_s):
    gaps = []
    for a, b in zip(pubs, pubs[1:]):
        between = sorted({c for (t, c) in misses if a["t"] < t < b["t"]}, key=CAUSE_ORDER.index)
        gaps.append({"from": iso(a["t"]), "to": iso(b["t"]), "gap_s": b["t"] - a["t"], "causes": between or ["disparo atrasado"]})
    over = [g for g in gaps if g["gap_s"] > limit_s]
    by_cause = {}
    for g in over:
        by_cause[g["causes"][0]] = by_cause.get(g["causes"][0], 0) + 1
    out = {
        "publications": len(pubs), "window": [iso(pubs[0]["t"]), iso(pubs[-1]["t"])], "limit_s": limit_s,
        "gap_s": quantiles([g["gap_s"] for g in gaps]), "gaps_over_limit": len(over), "gaps": len(gaps),
        "share_over_limit": round(len(over) / len(gaps), 4), "over_by_primary_cause": by_cause, "over": over,
    }
    lags = [p["lag"] for p in pubs if p["lag"] is not None]
    if lags:
        out["pickup_lag_s"] = quantiles(lags)
    out["kinds"] = {k: sum(1 for p in pubs if p["kind"] == k) for k in ("novo", "novo+falha", "mesmo")}
    return out


def render(res, show_list):
    L = []
    L.append("publicações do latest.json: %d, de %s a %s" % (res["publications"], res["window"][0], res["window"][1]))
    g = res["gap_s"]
    L.append("gap entre publicações: min %s  p50 %s  p90 %s  p99 %s  max %s" % tuple(hm(g[k]) for k in ("min", "p50", "p90", "p99", "max")))
    L.append("  gaps > %s: %d de %d (%.0f%%)" % (hm(res["limit_s"]), res["gaps_over_limit"], res["gaps"], 100.0 * res["share_over_limit"]))
    if res["over_by_primary_cause"]:
        L.append("  por causa (a mais grave de cada gap): " + " · ".join("%s %d" % (c, res["over_by_primary_cause"][c]) for c in CAUSE_ORDER if c in res["over_by_primary_cause"]))
    k = res["kinds"]
    if "pickup_lag_s" in res:
        d = res["pickup_lag_s"]
        L.append("atraso do dado até o S3 (HEAD já comitado + duração do run), %d snapshot(s) novo(s): p50 %s  p90 %s  max %s" % (
            k["novo"] + k["novo+falha"], hm(d["p50"]), hm(d["p90"]), hm(d["max"])))
    else:
        L.append("atraso do dado até o S3: sem como medir (nenhum snapshot novo com a linha `dado de há` na janela)")
    L.append("publicações: %d com snapshot novo, %d só batendo o ponto (HEAD igual: nada novo a subir)" % (k["novo"] + k["novo+falha"], k["mesmo"]))
    if show_list:
        L.append("gaps acima do limite:")
        for x in res["over"]:
            L.append("  %s  %s -> %s   %s" % (hm(x["gap_s"]), x["from"], x["to"], ", ".join(x["causes"])))
    return "\n".join(L)


def main(argv):
    ap = argparse.ArgumentParser(description="Cadência real do upload JSONL ao S3, pelo log (ga-c0939v.7)")
    city = os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or "/Users/athos/gt/.gascity-gastown-hq"
    ap.add_argument("--log", default=os.path.join(city, ".gc/logs/jsonl-hourly-offsite.log"))
    ap.add_argument("--since", default=None, help="AAAA-MM-DD ou AAAA-MM-DDTHH:MM:SSZ (UTC)")
    ap.add_argument("--limit-s", type=int, default=3600)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--json", action="store_true")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 3 if e.code else 0
    if a.limit_s < 1:
        print("--limit-s precisa ser >= 1", file=sys.stderr)
        return 3
    since = None
    if a.since:
        for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d"):
            try:
                since = int(datetime.datetime.strptime(a.since, fmt).replace(tzinfo=datetime.timezone.utc).timestamp())
                break
            except ValueError:
                pass
        if since is None:
            print("--since ilegível: %r" % a.since, file=sys.stderr)
            return 3
    # vazio → log sem linhas: nada a medir (rc 2, não "0 atrasos"); falhou/ilegível → idem: rc 2 com o motivo, nunca um relatório vazio com cara de saudável
    try:
        with open(a.log, encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except OSError as e:
        print("não li o log %s: %s" % (a.log, e), file=sys.stderr)
        return 2
    pubs, misses = parse(lines)
    if since is not None:
        pubs = [p for p in pubs if p["t"] >= since]
        misses = [m for m in misses if m[0] >= since]
    if len(pubs) < 2:
        print("menos de 2 publicações na janela (%d): sem gap para medir" % len(pubs), file=sys.stderr)
        return 2
    res = analyse(pubs, misses, a.limit_s)
    print(json.dumps(res, ensure_ascii=False) if a.json else render(res, a.list))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
