#!/usr/bin/env python3
"""dolt-load-attributor — quem responde por quantos % da carga do Dolt.

PROBLEMA QUE RESOLVE: `information_schema.processlist` do Dolt mostra todas as
conexões como user=root host=localhost — não diz QUEM. E o `gc dolt health` /
CPU agregado dizem QUANTO, nunca DE QUEM. Sem atribuição, toda discussão de
carga vira palpite (foi exatamente o que travou o ga-c30ak por dias).

COMO ATRIBUI: a cada ciclo tira um snapshot ATÔMICO de (a) conexões TCP na porta
do Dolt via lsof e (b) a tabela de processos via um único `ps`. Junta os dois por
PID. Um PID de cliente efêmero (bd/gc invocado por um daemon) morre em
milissegundos — por isso o `ps` precisa ser do MESMO instante, senão a resolução
falha e a amostra vira "?" (foi o que aconteceu no meu primeiro protótipo).

REGRA DE DONO: se o pai é o launchd, o processo É o serviço — usa os args dele.
Senão, sobe a árvore até achar um ancestral com identidade útil (script, daemon),
porque o cliente direto costuma ser só `bd`/`gc` e isso não diz nada.

O QUE MEDE: connection-samples, não CPU-por-processo. O macOS não atribui CPU do
servidor Dolt ao cliente que o fez trabalhar. Connection-share é PROXY, não
medida direta — está honesto no relatório.
"""
import json, os, re, subprocess, sys, time
from collections import Counter
from datetime import datetime, timezone

PORT = os.environ.get("DOLT_PORT", "")
OUT = os.path.expanduser(os.environ.get("DOLT_ATTR_LOG",
      "~/gt/.gascity-gastown-hq/.gc/logs/dolt-load-attribution.jsonl"))

def dolt_port():
    """Porta DERIVADA do processo vivo — nunca de arquivo/memória (doutrina da casa:
    dolt-server.port está STALE e diz 3307; a real é outra)."""
    if PORT:
        return PORT
    try:
        pid = subprocess.run(["pgrep","-f","dolt sql-server"],capture_output=True,
                             text=True,timeout=10).stdout.split()[0]
        out = subprocess.run(["lsof","-nP","-p",pid],capture_output=True,
                             text=True,timeout=20).stdout
        for ln in out.splitlines():
            if "LISTEN" in ln:
                m = re.search(r":(\d+)\s+\(LISTEN\)", ln)
                if m: return m.group(1)
    except Exception:
        pass
    return ""

def ps_snapshot():
    """UM ps para todo o ciclo. pid -> (ppid, args)."""
    try:
        out = subprocess.run(["ps","-eo","pid=,ppid=,args="],capture_output=True,
                             text=True,timeout=20).stdout
    except Exception:
        return {}
    tbl = {}
    for ln in out.splitlines():
        parts = ln.split(None, 2)
        if len(parts) < 3: continue
        try: tbl[int(parts[0])] = (int(parts[1]), parts[2])
        except ValueError: continue
    return tbl

def conn_pids(port):
    if not port: return []
    try:
        out = subprocess.run(["lsof","-nP",f"-iTCP:{port}","-sTCP:ESTABLISHED"],
                             capture_output=True,text=True,timeout=20).stdout
    except Exception:
        return []
    pids = []
    for ln in out.splitlines()[1:]:
        f = ln.split()
        if len(f) > 1 and f[0] != "dolt":
            try: pids.append(int(f[1]))
            except ValueError: pass
    return pids

_NOISE = re.compile(r'^(/bin/(ba)?sh|/usr/bin/env|timeout|gtimeout|sudo|nohup|xargs)\b')

def owner(pid, tbl):
    """Sobe a árvore até um ancestral com identidade. Para no launchd."""
    seen, cur = set(), pid
    while cur in tbl and cur not in seen:
        seen.add(cur)
        ppid, args = tbl[cur]
        pargs = tbl.get(ppid, (0,""))[1]
        # pai é launchd -> este processo É o serviço
        if "launchd" in pargs or ppid <= 1:
            return label(args)
        # cliente genérico (bd/gc/python solto) -> sobe
        base = os.path.basename(args.split()[0]) if args.split() else ""
        if base in ("bd","gc","beads","python","python3","Python") or _NOISE.match(args):
            cur = ppid
            continue
        return label(args)
    return label(tbl.get(pid,(0,"?"))[1])

def label(args):
    """Rótulo curto e estável a partir da linha de comando."""
    if not args: return "?"
    a = args.strip()
    m = re.search(r'/([a-zA-Z0-9_-]+)\.(py|sh)\b', a)
    if m: return m.group(1)
    m = re.search(r'\bgc\s+([a-z-]+(?:\s+[a-z-]+)?)', a)
    if m: return "gc " + m.group(1)
    m = re.search(r'\bbd\s+([a-z-]+)', a)
    if m: return "bd " + m.group(1)
    tok = a.split()[0]
    return os.path.basename(tok)[:40]

def sample(port, tbl):
    c = Counter()
    for p in conn_pids(port):
        c[owner(p, tbl)] += 1
    return c

def main():
    cycles = int(os.environ.get("DOLT_ATTR_CYCLES","20"))
    gap = float(os.environ.get("DOLT_ATTR_GAP","1.0"))
    port = dolt_port()
    if not port:
        print("FATAL: porta do Dolt não derivável do processo vivo", file=sys.stderr)
        return 1
    total = Counter()
    for _ in range(cycles):
        tbl = ps_snapshot()
        total.update(sample(port, tbl))
        time.sleep(gap)
    n = sum(total.values())
    cpu = ""
    try:
        pid = subprocess.run(["pgrep","-f","dolt sql-server"],capture_output=True,
                             text=True,timeout=10).stdout.split()[0]
        cpu = subprocess.run(["ps","-o","pcpu=","-p",pid],capture_output=True,
                             text=True,timeout=10).stdout.strip()
    except Exception: pass
    rec = {"ts": datetime.now(timezone.utc).isoformat(), "port": port,
           "samples": n, "cycles": cycles, "dolt_cpu_end": cpu,
           "by_owner": dict(total.most_common())}
    try:
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        with open(OUT,"a") as f: f.write(json.dumps(rec)+"\n")
    except Exception as e:
        print(f"(aviso: não gravei o log: {e})", file=sys.stderr)
    print(f"Dolt :{port} — {n} connection-samples em {cycles} ciclos | CPU ao fim: {cpu}%")
    print(f"{'dono':<34} {'amostras':>9} {'%':>7}")
    for k,v in total.most_common(14):
        print(f"{k:<34} {v:>9} {100*v/n:>6.1f}%")
    if n == 0:
        print("(zero amostras — Dolt ocioso ou lsof sem permissão)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
