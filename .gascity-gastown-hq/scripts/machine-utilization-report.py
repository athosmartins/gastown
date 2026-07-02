#!/usr/bin/env python3
"""
machine-utilization-report.py — aggregate the sampler's JSONL into Athos's metric.

    UTILIZATION = working_minutes / (working_minutes + idle_STALLED_minutes)

i.e. of the time there was WORK to do, what fraction was the machine actually working.
Idle-CORRECT time (empty backlog) is excluded from the denominator — an idle night
with nothing to build is not a failure, so it must not drag the number down.

Usage:
  machine-utilization-report.py [--window today|24h|7d|<hours>h] [--json]

The number that matters most is IDLE-STALLED: minutes where work was available and
nothing was running (the 22h dispatch loop, the gate crash — this is where "imparável"
breaks, and it's what the old binary check missed).
"""
import json
import os
import sys
import time

HQ = "/Users/athos/gt/.gascity-gastown-hq"
JSONL = os.path.join(HQ, ".gc", "machine-utilization.jsonl")
NOW = int(os.environ.get("UTIL_NOW_EPOCH", str(int(time.time()))))


def parse_window(argv):
    w = "today"
    for i, a in enumerate(argv):
        if a == "--window" and i + 1 < len(argv):
            w = argv[i + 1]
    if w == "today":
        # since local midnight
        import datetime
        lt = datetime.datetime.fromtimestamp(NOW)
        midnight = datetime.datetime(lt.year, lt.month, lt.day).timestamp()
        return int(midnight), "hoje (desde 00:00 local)"
    if w.endswith("h"):
        try:
            hrs = float(w[:-1])
            return NOW - int(hrs * 3600), f"últimas {w}"
        except Exception:
            pass
    if w == "7d":
        return NOW - 7 * 86400, "últimos 7 dias"
    if w == "24h":
        return NOW - 86400, "últimas 24h"
    return NOW - 86400, "últimas 24h"


def load(since):
    rows = []
    if not os.path.exists(JSONL):
        return rows
    with open(JSONL) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
                if r.get("ts", 0) >= since:
                    rows.append(r)
            except Exception:
                continue
    return rows


def main():
    since, label = parse_window(sys.argv[1:])
    rows = load(since)
    n = len(rows)  # each row ~= 1 minute sample
    if n == 0:
        print(f"═══ UTILIZAÇÃO DA MÁQUINA — {label} ═══")
        print("  (sem amostras ainda — o sampler roda 1x/min; volte em alguns minutos)")
        return

    prod = sum(1 for r in rows if r.get("state") == "productive")
    stalled = sum(1 for r in rows if r.get("state") == "idle_stalled")
    winding = sum(1 for r in rows if r.get("state") == "winding_down")
    correct = sum(1 for r in rows if r.get("state") == "idle_correct")
    working = sum(1 for r in rows if r.get("working"))
    reviewing = sum(1 for r in rows if r.get("reviewing"))
    building = sum(1 for r in rows if r.get("building"))
    refining = sum(1 for r in rows if r.get("refining"))

    # THE metric: working over (working + idle-with-work). Idle-correct excluded.
    denom = working + stalled
    util = (working / denom * 100) if denom else None

    def pct(x):
        return f"{x / n * 100:.0f}%"

    if "--json" in sys.argv:
        print(json.dumps({
            "window": label, "samples_min": n,
            "utilization_pct": round(util, 1) if util is not None else None,
            "idle_stalled_min": stalled, "idle_stalled_pct": round(stalled / n * 100, 1),
            "productive_min": prod, "idle_correct_min": correct, "winding_down_min": winding,
            "reviewing_pct": round(reviewing / n * 100, 1),
            "building_pct": round(building / n * 100, 1),
            "refining_pct": round(refining / n * 100, 1),
        }, indent=2))
        return

    print(f"═══ UTILIZAÇÃO DA MÁQUINA — {label} ═══")
    print(f"  amostras: {n} min (~{n/60:.1f}h de cobertura)")
    print()
    if util is not None:
        verdict = "✅" if util >= 90 else "⚠️" if util >= 70 else "❌"
        print(f"  UTILIZAÇÃO: {verdict} {util:.0f}%  (trabalhando {working}min de {denom}min com-trabalho)")
    else:
        print("  UTILIZAÇÃO: — (nunca houve trabalho disponível na janela → ocioso-correto o tempo todo)")
    print()
    print(f"  🔴 OCIOSO-TRAVADO: {pct(stalled)} ({stalled}min) — trabalho disponível E nada rodando (a FALHA real)")
    print(f"  🟢 produtivo:      {pct(prod)} ({prod}min)")
    print(f"  ⚪ ocioso-correto: {pct(correct)} ({correct}min) — backlog vazio, ocioso é certo")
    print(f"  🔵 encerrando:     {pct(winding)} ({winding}min) — trabalhando sem fila")
    print()
    print(f"  breakdown do tempo trabalhando: revisando {pct(reviewing)} · construindo {pct(building)} · refinando {pct(refining)}")
    if stalled:
        # surface the worst stalled stretch's diagnostics
        worst = [r for r in rows if r.get("state") == "idle_stalled"]
        last = worst[-1]
        print()
        print(f"  último instante travado: fila-queued={last.get('avail_queued_markers')} "
              f"aprovadas={last.get('avail_approved')} bugs-prontos={last.get('avail_ready_bugs')} "
              f"| revisores={last.get('n_reviewer_procs')} building-fresh={last.get('n_building_fresh')}")


if __name__ == "__main__":
    main()
