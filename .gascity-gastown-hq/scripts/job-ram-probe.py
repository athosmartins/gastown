#!/usr/bin/env python3
"""job-ram-probe.py — pegada de RAM POR JOB do launchd, amostrada de 5 em 5 s (ga-sh8t23.3; revisão de arquitetura 15/10).

Contents
  Para que serve · Como mede · Três estados · Uso · Limites

PARA QUE SERVE
  O `ram-owner-sampler` (5 min) agrupa por NOME DE PROCESSO: não diz de qual job do launchd é cada MB e perde o que dura menos que o passo. A fatia .3 só move um horário com a pegada
  medida do job (label → processo → pico de RSS). Este comando amostra a janela, soma o RSS da ÁRVORE de cada job (o processo que o launchd iniciou e seus filhos) e grava UMA linha por
  amostra, com swap, % livre e disco livre. `--summary` lê os arquivos e imprime a tabela, o pico simultâneo e os saltos de swap com quem cresceu nos 60 s antes. SÓ LEITURA do sistema: ps, launchctl list,
  sysctl, memory_pressure. A única escrita é o arquivo de saída (com teto de tamanho e piso de disco: o disco do mini vive a 98 %, a ferramenta não pode piorá-lo).

COMO MEDE
  `launchctl list` dá label → PID dos jobs rodando; `ps` dá a árvore (ppid). RSS do job = soma da raiz e dos descendentes, cada pid UMA vez. O nome do processo é o do `ram_owner_lib.label()`,
  o MESMO do sampler (dá para casar com o histórico dele). Custo de uma amostra ≈ 0,2 s (um ps de ~650 linhas); vai gravado em `dt_ms`. Instância única por arquivo (flock).

TRÊS ESTADOS (o que não sei NÃO vira zero)
  `ps` que falha ou vem vazio → `ps_ok:false`, sem RSS total e sem jobs (uma máquina sempre tem processos: tabela vazia é "não li"). `launchctl list` que falha ou vem sem nenhuma linha →
  `lc_ok:false`: o RSS total fica, mas SEM atribuição a job. Swap/% livre/disco livre que não li → `null`. Job que acabou entre o launchctl e o ps some da amostra (não vira 0 MB). No resumo, amostras
  assim e linhas ilegíveis são CONTADAS e ditas; arquivo que não abre ou sem nenhuma amostra → exit 3 (não sei ≠ nada rodou).

USO
  job-ram-probe.py [--start HH:MM] [--until HH:MM | --duration S | --ticks N] [--interval S] [--out ARQ] [--max-mb N] [--min-free-gb N] [--check-every N] [--fixture-dir D]
  job-ram-probe.py --summary ARQ... [--swap-step MB] [--big-mb MB] [--disk-step MB]
  Com --start espera até a hora (local); se já estiver dentro de [start, until] começa agora. Códigos: 0 · 2 uso errado · 3 não consegui ler/nenhuma amostra · 4 outra instância
  no mesmo arquivo · 5 arquivo passou do teto · 6 disco abaixo do piso. Teste: `bash scripts/job-ram-probe.selftest.sh`.

LIMITES  Job que dura menos que o passo (5 s) pode passar entre duas amostras. Processo que se desanexa do job (reparent para o launchd) sai da árvore. A soma de RSS conta página compartilhada
  uma vez por processo (superestima árvores com vários processos do mesmo binário). RSS é o residente: memória já enviada ao swap não aparece nele, por isso o salto de swap é lido à parte.
  A causa de um salto é INDÍCIO (quem cresceu nos 60 s antes), não prova.
"""
from __future__ import annotations

import argparse
import bisect
import collections
import datetime as dt
import fcntl
import json
import os
import shutil
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ram_owner_lib as lib  # noqa: E402  (ps_snapshot, swap_usage, mem_free_pct, label: a MESMA leitura do ram-owner-sampler)

PERSISTENT = 0.9  # visto em >= 90 % das amostras válidas = daemon (KeepAlive), não job da janela
LOOKBACK = 60     # s antes de um salto de swap em que se procura quem cresceu
GROW_KB = 50 * 1024


def launchd_pids(fixture=None):
    """label -> pid dos jobs RODANDO agora; None = não consegui ler.
    vazio → None (o launchd sempre tem jobs: saída sem nenhuma linha é "não li", nunca "nenhum job rodando"); falhou/ilegível (exit != 0, timeout, byte não-UTF-8) → None."""
    try:
        if fixture is not None:
            with open(fixture, encoding="utf-8") as f:
                out = f.read()
        else:
            r = subprocess.run([os.environ.get("JRP_LAUNCHCTL", "launchctl"), "list"], capture_output=True, text=True, timeout=20)
            if r.returncode != 0:
                return None
            out = r.stdout
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    lines = out.splitlines()
    if lines and lines[0].startswith("PID"):
        lines = lines[1:]
    pids, rows = {}, 0
    for ln in lines:
        f = ln.split("\t")
        if len(f) != 3:
            continue
        rows += 1
        if f[0].isdigit():  # "-" = carregado e parado
            pids[f[2]] = int(f[0])
    return pids if rows else None


def job_trees(tbl, roots):
    """label -> [rss_kb, nproc, processo de maior RSS, rss dele]. Raiz + descendentes; cada pid conta UMA vez (ciclo ou pid já contado não soma de novo)."""
    kids = collections.defaultdict(list)
    for pid, p in tbl.items():
        kids[p["ppid"]].append(pid)
    out, seen = {}, set()
    for label, root in roots.items():
        if root not in tbl:  # o job acabou entre o launchctl e o ps: some desta amostra (não vira 0 MB) [guard:vanished]
            continue
        stack, tot, n, top = [root], 0, 0, (-1, "?")
        while stack:
            pid = stack.pop()
            if pid in seen or pid not in tbl:  # ciclo ou pid já contado não soma de novo [guard:seen]
                continue
            seen.add(pid)
            p = tbl[pid]
            tot += p["rss_kb"]
            n += 1
            if p["rss_kb"] > top[0]:
                top = (p["rss_kb"], lib.label(p["args_head"]))
            stack.extend(kids.get(pid, ()))
        out[label] = [tot, n, top[1], max(top[0], 0)]
    return out


def read_mem_fixture(path):
    """(swap_used_mb, free_pct, disk_free_mb) de um arquivo "<swap> <free> [<disco>]"; '-' ou campo ausente = não li. vazio/ilegível → (None, None, None)."""
    try:
        with open(path, encoding="utf-8") as f:
            v = f.read().split()
        num = lambda x, kind: None if x == "-" else kind(x)
        return num(v[0], float), num(v[1], int), (num(v[2], int) if len(v) > 2 else None)
    except (OSError, ValueError, IndexError):
        return None, None, None


def disk_free_mb(path):
    """MB livres no volume de `path`. vazio não existe (a leitura sempre responde); falhou → None (nunca 0)."""
    try:
        return int(shutil.disk_usage(path).free / 1048576)
    except OSError:
        return None


def tick(i, fixture_dir, disk_path):
    t0 = time.time()
    if fixture_dir:
        fx = lambda ext: os.path.join(fixture_dir, f"{i}.{ext}")
        tbl, pids = lib.ps_snapshot(fx("ps")), launchd_pids(fx("launchctl"))
        swap, free, disk = read_mem_fixture(fx("mem"))
    else:
        # ps: vazio/falhou → {} (ps_ok:false, sem RSS e sem jobs); swap/% livre: falhou → None → null no JSON
        tbl, pids = lib.ps_snapshot(), launchd_pids()
        swap, free, disk = lib.swap_usage()[0], lib.mem_free_pct(), disk_free_mb(disk_path)
    ps_ok = bool(tbl)  # tabela vazia = não li (uma máquina sempre tem processos)
    rec = {"ts": int(t0), "ps_ok": ps_ok, "lc_ok": pids is not None, "swap_used_mb": swap, "free_pct": free, "disk_free_mb": disk,
           "total_rss_kb": sum(p["rss_kb"] for p in tbl.values()) if ps_ok else None,
           "jobs": job_trees(tbl, pids) if ps_ok and pids is not None else {}}
    rec["dt_ms"] = int((time.time() - t0) * 1000)
    return rec


def next_at(hm, after):
    """Primeiro instante >= after cujo relógio local é HH:MM."""
    t = dt.datetime.fromtimestamp(after).replace(hour=hm // 60, minute=hm % 60, second=0, microsecond=0)
    if t.timestamp() < after:
        t += dt.timedelta(days=1)
    return t.timestamp()


def plan(now, start_hm, until_hm):
    """(início, fim) em epoch. Dentro da janela [start, until] já passou o próximo início de hoje e o fim ainda vem: começa agora."""
    end = next_at(until_hm, now) if until_hm is not None else None
    start = next_at(start_hm, now) if start_hm is not None else now
    if end is not None and start > end:  # [guard:inside]
        start = now
    return start, end


def hhmm(arg):
    try:
        h, m = arg.split(":")
        if not (0 <= int(h) <= 23 and 0 <= int(m) <= 59):
            raise ValueError
        return int(h) * 60 + int(m)
    except ValueError:
        raise argparse.ArgumentTypeError(f"hora inválida: {arg!r} (use HH:MM)")


def record(a):
    out = a.out or os.path.join(os.environ.get("GC_CITY_PATH") or os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."), ".gc", time.strftime("job-ram-probe-%Y%m%d.jsonl"))
    outdir = os.path.dirname(os.path.abspath(out))
    os.makedirs(outdir, exist_ok=True)
    floor = a.min_free_gb * 1024 ** 3
    # disco: vazio não existe (uma leitura sempre responde); falhou → OSError sobe (sem saber o espaço, não escrevo)
    if shutil.disk_usage(outdir).free < floor:
        print(f"job-ram-probe: disco abaixo do piso de {a.min_free_gb} GB; não gravo", file=sys.stderr)
        return 6
    lock = open(out + ".lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print(f"job-ram-probe: outra instância já grava em {out}", file=sys.stderr)
        return 4
    now = time.time()
    start, end = plan(now, a.start, a.until)
    if a.duration is not None:
        end = start + a.duration
    while time.time() < start:
        time.sleep(min(30.0, max(0.05, start - time.time())))
    n = 0
    with open(out, "a", encoding="utf-8") as f:
        while (end is None or time.time() < end) and (a.ticks is None or n < a.ticks):
            t0 = time.time()
            f.write(json.dumps(tick(n, a.fixture_dir, outdir), separators=(",", ":")) + "\n")
            f.flush()
            n += 1
            if f.tell() > a.max_mb * 1024 * 1024:  # [guard:cap]
                print(f"job-ram-probe: {out} passou de {a.max_mb} MB; parei", file=sys.stderr)
                return 5
            if n % a.check_every == 0 and shutil.disk_usage(outdir).free < floor:  # [guard:floor]
                print(f"job-ram-probe: disco abaixo do piso de {a.min_free_gb} GB; parei", file=sys.stderr)
                return 6
            if not a.fixture_dir and not (a.ticks is not None and n >= a.ticks):
                time.sleep(max(0.0, a.interval - (time.time() - t0)))
    return 0


def load(paths):
    """Amostras ordenadas e a contagem de linhas ilegíveis. Arquivo que não abre → OSError (exit 3); linha que não é JSON de amostra → contada em `bad`, nunca descartada em silêncio."""
    recs, bad = [], 0
    for p in paths:
        with open(p, encoding="utf-8") as f:
            for ln in f:
                if not ln.strip():
                    continue
                try:
                    r = json.loads(ln)
                    if not (isinstance(r, dict) and isinstance(r.get("ts"), int) and isinstance(r.get("jobs"), dict)):
                        raise ValueError
                    recs.append(r)
                except ValueError:
                    bad += 1  # [guard:bad]
    return sorted(recs, key=lambda r: r["ts"]), bad


def clock(ts):
    return time.strftime("%H:%M:%S", time.localtime(ts))


def mb(kb):
    return f"{kb / 1024:.0f}"


def grew(recs, tss, b):
    """Top 3 labels que mais cresceram (pico nos LOOKBACK s até `b` menos o RSS antes da janela). None = não sei (alguma amostra sem ps ou sem launchctl)."""
    j = bisect.bisect_right(tss, b["ts"] - LOOKBACK) - 1
    win = [r for r in recs[max(j, 0):] if r["ts"] <= b["ts"]]
    if j < 0 or any(not (r.get("ps_ok") and r.get("lc_ok")) for r in win):  # [guard:unknown]
        return None
    base = recs[j]["jobs"]
    peak = {}
    for r in win[1:]:
        for lab, v in r["jobs"].items():
            if v[0] > peak.get(lab, (0, ""))[0]:
                peak[lab] = (v[0], v[2])
    gr = [(v - base.get(lab, [0])[0], lab, name, lab not in base) for lab, (v, name) in peak.items() if v - base.get(lab, [0])[0] >= GROW_KB]
    return sorted(gr, reverse=True)[:3]


def summarize(recs, bad, swap_step, big_mb, disk_step):
    ok = [r for r in recs if r.get("ps_ok") and r.get("lc_ok")]
    no_ps = sum(1 for r in recs if not r.get("ps_ok"))
    no_lc = sum(1 for r in recs if not r.get("lc_ok"))
    steps = [b["ts"] - a["ts"] for a, b in zip(recs, recs[1:])]
    dts = [r["dt_ms"] for r in recs if isinstance(r.get("dt_ms"), int)]
    L = [f"# job-ram-probe: {len(ok)} amostras com atribuição de {len(recs)} ({clock(recs[0]['ts'])}-{clock(recs[-1]['ts'])}) · passo mediano {statistics.median(steps) if steps else 0:.0f} s · "
         f"custo da amostra: mediana {statistics.median(dts) if dts else 0:.0f} ms, máx {max(dts) if dts else 0} ms"]
    if no_ps or no_lc or bad:
        L.append(f"AVISO: {no_ps} amostras sem ps, {no_lc} sem launchctl (essas NÃO atribuem RAM a job), {bad} linhas ilegíveis: o que não li não está nas tabelas abaixo.")
    seen = collections.defaultdict(list)
    for r in ok:
        for lab, v in r["jobs"].items():
            seen[lab].append((r["ts"], v[0], v[2]))
    daemons = {lab for lab, s in seen.items() if len(s) >= PERSISTENT * len(ok)}
    win = {lab: s for lab, s in seen.items() if lab not in daemons}
    sw = [r["swap_used_mb"] for r in recs if r.get("swap_used_mb") is not None]
    fr = [r["free_pct"] for r in recs if r.get("free_pct") is not None]
    tot = [r["total_rss_kb"] for r in recs if r.get("total_rss_kb") is not None]
    L += ["", "## Memória e swap",
          f"* swap usado: {min(sw):.0f}..{max(sw):.0f} MB ({len(recs) - len(sw)} amostras sem leitura)" if sw else "* swap usado: sem nenhuma leitura",
          f"* % livre: {min(fr)}..{max(fr)}" if fr else "* % livre: sem nenhuma leitura",
          f"* RSS total: {min(tot) / 1048576:.1f}..{max(tot) / 1048576:.1f} GB" if tot else "* RSS total: sem nenhuma leitura"]
    sr = [r for r in recs if r.get("swap_used_mb") is not None]
    tss = [r["ts"] for r in recs]
    jumps = [(a, b) for a, b in zip(sr, sr[1:]) if b["swap_used_mb"] - a["swap_used_mb"] >= swap_step]
    L.append(f"* saltos de swap >= {swap_step:.0f} MB entre amostras seguidas: {len(jumps)}")
    for a, b in jumps:
        g = grew(recs, tss, b)
        who = "sem atribuição (sem amostra de base 60 s antes, ou amostra sem ps/launchctl na janela)" if g is None else ("; ".join(f"{lab} +{mb(d)} MB{' (novo)' if new else ''} [{name}]" for d, lab, name, new in g) or "ninguém cresceu >= 50 MB")
        L.append(f"  - {clock(b['ts'])}  {a['swap_used_mb']:.0f} -> {b['swap_used_mb']:.0f} MB (+{b['swap_used_mb'] - a['swap_used_mb']:.0f}, em {b['ts'] - a['ts']} s)  nos {LOOKBACK} s antes: {who}")
    dk = [r for r in recs if r.get("disk_free_mb") is not None]
    L += ["", "## Disco (volume do arquivo de saída)",
          f"* livre: {min(r['disk_free_mb'] for r in dk)}..{max(r['disk_free_mb'] for r in dk)} MB ({len(recs) - len(dk)} amostras sem leitura)" if dk else "* livre: sem nenhuma leitura (arquivo sem o campo, ou statvfs falhou)"]
    drops = [(a, b) for a, b in zip(dk, dk[1:]) if a["disk_free_mb"] - b["disk_free_mb"] >= disk_step]
    L.append(f"* quedas >= {disk_step:.0f} MB entre amostras seguidas: {len(drops)}")
    for a, b in drops:
        run = sorted(((v[0], lab) for lab, v in b["jobs"].items() if lab in win), reverse=True)[:4]
        who = "sem atribuição (amostra sem ps/launchctl)" if not (b.get("ps_ok") and b.get("lc_ok")) else (", ".join(f"{lab} ({mb(kb)} MB)" for kb, lab in run) or "nenhum job da janela rodando")
        L.append(f"  - {clock(b['ts'])}  {a['disk_free_mb']} -> {b['disk_free_mb']} MB (-{a['disk_free_mb'] - b['disk_free_mb']}, em {b['ts'] - a['ts']} s)  jobs da janela rodando (maiores): {who}")
    if not ok:  # nenhuma amostra atribuiu RAM a job: sem tabela de jobs (não sei ≠ nenhum job rodou)
        return "\n".join(L + ["", "## Jobs: nenhuma amostra com ps E launchctl válidos; sem tabela de jobs (não sei ≠ nenhum job rodou)."])
    L += ["", f"## Jobs da janela (não persistentes: {len(win)}), por pico da árvore", "| label | pico MB | às | processo de maior RSS | visto (início..fim) | amostras |", "|---|---|---|---|---|---|"]
    for lab, s in sorted(win.items(), key=lambda kv: -max(x[1] for x in kv[1]))[:40]:
        ts, kb, name = max(s, key=lambda x: x[1])
        L.append(f"| {lab} | {mb(kb)} | {clock(ts)} | {name} | {clock(s[0][0])}..{clock(s[-1][0])} | {len(s)} |")
    if not win:
        L.append("(nenhum job não persistente apareceu nas amostras com atribuição)")
    sim = [(sum(v[0] for lab, v in r["jobs"].items() if lab in win), r) for r in ok]
    if sim:
        top, r = max(sim, key=lambda x: x[0])
        big = lambda rr: sorted(lab for lab, v in rr["jobs"].items() if lab in win and v[0] >= big_mb * 1024)
        many = sum(1 for _, rr in sim if len(big(rr)) >= 2)
        L += ["", f"## Simultaneidade dos jobs da janela (\"de pico\" = árvore >= {big_mb:.0f} MB)",
              f"* maior soma de uma amostra: {mb(top)} MB às {clock(r['ts'])} ({len(big(r))} jobs de pico: {', '.join(big(r)) or 'nenhum'})",
              f"* amostras com 2 ou mais jobs de pico ao mesmo tempo: {many} de {len(sim)}"]
    dsum = sorted(((max(x[1] for x in seen[lab]), lab) for lab in daemons), reverse=True)
    L += ["", f"## Persistentes (visto em >= {PERSISTENT * 100:.0f} % das amostras): {len(daemons)} labels, soma dos picos {mb(sum(k for k, _ in dsum))} MB; maiores:"]
    L += [f"* {lab}: {mb(k)} MB" for k, lab in dsum[:8]]
    return "\n".join(L)


def main(argv=None):
    ap = argparse.ArgumentParser(description="pegada de RAM por job do launchd (somente leitura do sistema)")
    ap.add_argument("--summary", nargs="+", metavar="ARQ")
    ap.add_argument("--start", type=hhmm)
    ap.add_argument("--until", type=hhmm)
    ap.add_argument("--duration", type=float)
    ap.add_argument("--ticks", type=int)
    ap.add_argument("--interval", type=float, default=5.0)
    ap.add_argument("--out")
    ap.add_argument("--max-mb", type=float, default=40.0)
    ap.add_argument("--check-every", type=int, default=12, help="amostras entre duas conferências do piso de disco")
    ap.add_argument("--min-free-gb", type=float, default=1.0)
    ap.add_argument("--fixture-dir")
    ap.add_argument("--swap-step", type=float, default=200.0)
    ap.add_argument("--big-mb", type=float, default=150.0)
    ap.add_argument("--disk-step", type=float, default=300.0)
    a = ap.parse_args(argv)
    if a.summary:
        try:
            recs, bad = load(a.summary)
        except (OSError, ValueError) as e:  # ValueError: byte que não é UTF-8
            print(f"job-ram-probe: não consegui ler a entrada: {e}", file=sys.stderr)
            return 3
        if not recs:  # [guard:empty]
            print(f"job-ram-probe: nenhuma amostra legível ({bad} linhas ilegíveis); sem relatório (não sei ≠ nada rodou)", file=sys.stderr)
            return 3
        print(summarize(recs, bad, a.swap_step, a.big_mb, a.disk_step))
        return 0
    if a.interval < 1 or a.max_mb <= 0 or a.check_every < 1 or (a.duration is None and a.until is None and a.ticks is None):
        print("job-ram-probe: uso errado (--interval >= 1; informe --until, --duration ou --ticks; ou use --summary)", file=sys.stderr)
        return 2
    return record(a)


if __name__ == "__main__":
    sys.exit(main())
