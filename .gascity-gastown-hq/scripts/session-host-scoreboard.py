#!/usr/bin/env -S python3 -I
"""session-host-scoreboard.py — quantas sessões de pool cada host abriu por noite (mini, MBP, Hetzner). ga-w7qwl1, fatia "placar por host".

Contents
  Uso · De onde vêm os números · O que conta · Saída · Limites

USO
  session-host-scoreboard.py [--noites N] [--json] [--city DIR] [--agora ISO]
  Uma "noite" vai das 20:00 às 08:00 do fuso da máquina e leva a data do dia em que começou (a de 14/10 vai de 14/10 20:00 a 15/10 08:00).
  Padrão: as últimas 7. Só lê arquivos; não fala com host nenhum e não grava nada.

DE ONDE VÊM OS NÚMEROS
  mini     <cidade>/.gc/events.jsonl, eventos `session.woke` (o engine acordou a sessão `subject`) cujo nome NÃO tem `-remote-`. Conta o
           pedido do engine, não a abertura confirmada: uma sessão que o engine acordou e que caiu logo depois também entra.
  remotos  <cidade>/.gc/runtime/session-ssh/<host>/events.jsonl, escrito pelo gc-session-ssh: `started` (sessão aberta de fato no host),
           `refused` (o start foi recusado, com o motivo: Athos no MBP, pausa, teto...). Host = o nome da pasta.
  O mini e os remotos usam fontes diferentes de propósito: o engine só vê o mini como "acordou"; quem sabe se o start no host remoto
  funcionou é o provider. Por isso a coluna do mini pode contar um pouco a mais.

O QUE CONTA
  Papel pelo nome da sessão: construtor = wa-worker, ps-worker, dog; revisor = gate-reviewer, refino-gate-reviewer, context-check-reviewer;
  o resto (auto-refiner, boot, crews...) vai em `outros`. O placar mostra construtores e revisores por noite e por host, e as recusas
  dos hosts remotos por motivo.

SAÍDA  texto (tabela por noite) ou --json: {"noites":[{"noite","hosts":{host:{"construtor","revisor","outros","recusas":{motivo:n}}}}]}
LIMITES  linha ilegível de um log não derruba a leitura: é contada e avisada ("N linhas ilegíveis"), nunca omitida em silêncio. Arquivo
  que não abre sai com erro (exit 1): "não consegui ler" não vira "zero construções".
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta

BUILDERS = ("wa-worker", "ps-worker", "dog")
REVIEWERS = ("gate-reviewer", "refino-gate-reviewer", "context-check-reviewer")
NIGHT_FROM, NIGHT_TO = 20, 8  # horas locais


def role(name: str) -> str:
    for r in REVIEWERS:
        if name == r or name.startswith(r + "-"):
            return "revisor"
    for b in BUILDERS:
        if name == b or name.startswith(b + "-"):
            return "construtor"
    return "outros"


def night_of(ts: datetime) -> str | None:
    """Data (YYYY-MM-DD) da noite a que o instante pertence, ou None se cai de dia."""
    t = ts.astimezone()
    if t.hour >= NIGHT_FROM:
        return t.date().isoformat()
    if t.hour < NIGHT_TO:
        return (t.date() - timedelta(days=1)).isoformat()
    return None


def parse_ts(s: str) -> datetime:
    """ISO 8601 com fuso. O engine grava de 5 a 9 casas de fração; o fromisoformat do Python 3.9 só aceita 3 ou 6, então normaliza para 6."""
    m = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)", s)
    if not m:
        raise ValueError(s)
    return datetime.fromisoformat(f"{m.group(1)}.{(m.group(2) or '')[:6].ljust(6, '0')}{'+00:00' if m.group(3) == 'Z' else m.group(3)}")


def read_lines(path: str, needle: str = ""):
    """Linhas JSON de um log, em fluxo. Devolve (objetos, nº de linhas ilegíveis). Arquivo ausente = ([], 0); que não abre = OSError.
    `needle`: só lê a fundo as linhas que o contêm (o events.jsonl do engine tem dezenas de MB e quase tudo nele não interessa); uma linha
    cortada que ainda traz o texto entra como ilegível, uma que o perdeu não podia ser deste tipo."""
    objs, bad = [], 0
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if not line.strip() or (needle and needle not in line):
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    bad += 1
                    continue
                if isinstance(o, dict):
                    objs.append(o)
                else:
                    bad += 1
    except FileNotFoundError:
        return [], 0
    return objs, bad


def collect(city: str, since: datetime):
    """({noite: {host: {construtor, revisor, outros, recusas{motivo:n}}}}, nº de linhas ilegíveis, avisos de fonte ausente)."""
    out: dict = defaultdict(lambda: defaultdict(lambda: {"construtor": 0, "revisor": 0, "outros": 0, "recusas": defaultdict(int)}))
    bad, warns = 0, []
    engine_log = os.path.join(city, ".gc", "events.jsonl")
    if not os.path.exists(engine_log):  # sem a fonte do mini, "0 sessões" seria mentira: a coluna dele está vazia por falta de log
        warns.append(f"{engine_log} não existe: a coluna do mini está vazia por falta de fonte, não por falta de sessões")
    ev, b = read_lines(engine_log, '"session.woke"')
    bad += b
    for o in ev:
        if o.get("type") != "session.woke":
            continue
        name = o.get("subject")
        try:
            ts = parse_ts(o["ts"])
        except (KeyError, ValueError, TypeError):
            bad += 1
            continue
        if not isinstance(name, str) or "-remote-" in name or ts < since:
            continue
        n = night_of(ts)
        if n:
            out[n]["mini"][role(name)] += 1
    base = os.path.join(city, ".gc", "runtime", "session-ssh")
    try:
        hosts = sorted(d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d)))
    except FileNotFoundError:
        hosts = []
    for h in hosts:
        ev, b = read_lines(os.path.join(base, h, "events.jsonl"))
        bad += b
        for o in ev:
            kind, name = o.get("event"), o.get("session")
            try:
                ts = parse_ts(o["ts"])
            except (KeyError, ValueError, TypeError):
                bad += 1
                continue
            if kind not in ("started", "refused") or not isinstance(name, str) or ts < since:
                continue
            n = night_of(ts)
            if not n:
                continue
            if kind == "started":
                out[n][h][role(name)] += 1
            else:
                out[n][h]["recusas"][str(o.get("reason") or "sem motivo")] += 1
    return out, bad, warns


def main(argv: list) -> int:
    ap = argparse.ArgumentParser(description="sessões de pool por host e por noite")
    ap.add_argument("--noites", type=int, default=7)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--city", default=os.environ.get("GC_CITY_PATH") or os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
    ap.add_argument("--agora", help="instante de referência (ISO com fuso); padrão: agora")
    a = ap.parse_args(argv)
    if a.noites < 1:
        sys.stderr.write("--noites tem que ser >= 1\n")
        return 2
    try:
        now = parse_ts(a.agora) if a.agora else datetime.now().astimezone()
    except ValueError:
        sys.stderr.write(f"--agora ilegível: {a.agora!r} (tem que ser ISO com fuso, ex.: 2026-10-15T09:00:00-03:00; a noite depende do fuso)\n")
        return 2
    since = (now.astimezone() - timedelta(days=a.noites + 1)).replace(hour=NIGHT_FROM, minute=0, second=0, microsecond=0)
    try:
        data, bad, warns = collect(a.city, since)
    except OSError as e:
        sys.stderr.write(f"não consegui ler os logs: {e}\n")
        return 1
    nights = sorted(data, reverse=True)[: a.noites]
    rows = [{"noite": n, "hosts": {h: dict(v, recusas=dict(v["recusas"])) for h, v in sorted(data[n].items())}} for n in nights]
    if a.json:
        print(json.dumps({"noites": rows, "linhas_ilegiveis": bad, "avisos": warns}, ensure_ascii=False, indent=2))
        return 0
    if not rows:
        print("sem sessões registradas nas últimas noites")
    for r in rows:
        print(f"noite de {r['noite']} (20:00 → 08:00)")
        for h, v in r["hosts"].items():
            rec = ", ".join(f"{m}={c}" for m, c in sorted(v["recusas"].items()))
            print(f"  {h:<10} construtores {v['construtor']:>3} · revisores {v['revisor']:>3} · outros {v['outros']:>3}" + (f" · recusas: {rec}" if rec else ""))
    if bad:
        print(f"AVISO: {bad} linha(s) ilegível(is) nos logs (não contadas)", file=sys.stderr)
    for w in warns:
        print(f"AVISO: {w}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
