#!/usr/bin/env -S python3 -I
"""session-host-scoreboard.py — quantas sessões de pool cada host abriu por noite (mini, MBP, Hetzner). ga-w7qwl1, fatia "placar por host".

Contents
  Uso · De onde vêm os números · O que conta · Saída · Limites

USO
  session-host-scoreboard.py [--noites N] [--json] [--city DIR] [--agora ISO]
  Uma "noite" vai das 20:00 às 08:00 do fuso da máquina e leva a data do dia em que começou (a de 14/10 vai de 14/10 20:00 a 15/10 08:00).
  Padrão: as últimas 7. Só lê arquivos; não fala com host nenhum e não grava nada.

DE ONDE VÊM OS NÚMEROS
  mini     <cidade>/.gc/events.jsonl e, como o engine RODA esse arquivo, os events.jsonl.archive-…-seq-A-B.gz anteriores (ligados pelo
           seq) que a janela pede; eventos `session.woke` (o engine acordou a sessão `subject`) cujo nome NÃO tem `-remote-`. Conta o
           pedido do engine, não a abertura confirmada: uma sessão que o engine acordou e que caiu logo depois também entra.
  remotos  <cidade>/.gc/runtime/session-ssh/<host>/events.jsonl, escrito pelo gc-session-ssh: `started` (sessão aberta de fato no host),
           `refused` (o start foi recusado, com o motivo: Athos no MBP, pausa, teto...). Host = o nome da pasta.
  O mini e os remotos usam fontes diferentes de propósito: o engine só vê o mini como "acordou"; quem sabe se o start no host remoto
  funcionou é o provider. Por isso a coluna do mini pode contar um pouco a mais.

O QUE CONTA
  Papel pelo nome da sessão: construtor = wa-worker, ps-worker, dog; revisor = gate-reviewer, refino-gate-reviewer, context-check-reviewer;
  o resto (auto-refiner, boot, crews...) vai em `outros`. O placar mostra construtores e revisores por noite e por host, e as recusas
  dos hosts remotos por motivo.

SAÍDA  texto (tabela por noite) ou --json: {"noites":[{"noite","em_curso","hosts":{host:{"construtor","revisor","outros",
  "recusas":{motivo:n},"cobertura"}}}],"cobertura_desde":{host:instante|"início"|null},"linhas_ilegiveis","avisos"}. Sai TODA noite pedida.
COBERTURA  cada fonte diz desde quando cobre (1º registro do arquivo mais antigo ligado; "início" = o log começa no seq 1 da cidade). Por
  noite e host: completa, parcial (a fonte começa no meio da noite) ou sem-fonte (números null, não 0). Fonte que não cobre a janela
  inteira vira AVISO no stderr: "o log não cobre" nunca sai igual a "não houve sessão".
LIMITES  linha ilegível de um log não derruba a leitura: é contada e avisada ("N linhas ilegíveis"), nunca omitida em silêncio. Arquivo
  que não abre, ou .gz corrompido, sai com erro (exit 1): "não consegui ler" não vira "zero construções".
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import sys
import zlib
from collections import defaultdict
from datetime import datetime, time, timedelta, timezone

BUILDERS = ("wa-worker", "ps-worker", "dog")
REVIEWERS = ("gate-reviewer", "refino-gate-reviewer", "context-check-reviewer")
NIGHT_FROM, NIGHT_TO = 20, 8  # horas locais


def role(name: str) -> str:
    """O papel pelo nome da sessão SEM o qualificador: o motor escreve `gastown.dog-2` (pack.) e `whatsapp_automation/claude-…` (rig/);
    sem tirar o prefixo, metade dos construtores do mini caía em "outros" (gate ga-ie7fcr: 164 gastown.dog-N num dia)."""
    name = re.split(r"[./]", name)[-1] if re.match(r"^[\w-]+[./]", name) else name
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
    """Linhas JSON de um log (texto ou .gz), em fluxo. Devolve (objetos, nº de linhas ilegíveis, 1º registro do arquivo ou None).
    Arquivo ausente = ([], 0, None); que não abre ou .gz corrompido = OSError. `needle`: só lê a fundo as linhas que o contêm (o
    events.jsonl do engine tem dezenas de MB e quase tudo nele não interessa); uma linha cortada que ainda traz o texto entra como
    ilegível, uma que o perdeu não podia ser deste tipo. O 1º registro (lido sempre) é o que diz desde quando o arquivo cobre."""
    objs, bad, head = [], 0, None
    try:
        with (gzip.open(path, "rt", encoding="utf-8", errors="replace") if path.endswith(".gz")
              else open(path, encoding="utf-8", errors="replace")) as f:
            for line in f:
                if not line.strip():
                    continue
                if head is None:
                    try:
                        o = json.loads(line)
                        head = o if isinstance(o, dict) else None
                    except ValueError:
                        pass
                if needle and needle not in line:
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
        return [], 0, None
    except (EOFError, zlib.error) as e:  # .gz truncado: "não consegui ler", nunca "o arquivo acabou aqui"
        raise OSError(f"{path}: {e}") from e
    return objs, bad, head


GENESIS = datetime.min.replace(tzinfo=timezone.utc)  # o log começa no 1º evento da cidade (seq 1): antes dele não houve sessão


def head_ts(head) -> datetime | None:
    try:
        return parse_ts(head["ts"])
    except (KeyError, ValueError, TypeError):
        return None


def engine_files(city: str, since: datetime, warns: list):
    """Os arquivos do engine a ler para cobrir [since, agora] e desde quando eles cobrem (GENESIS, um instante, ou None = sem fonte).
    O engine RODA o events.jsonl: o vivo começa com um `events.rotated` e o resto está em events.jsonl.archive-…-seq-A-B.gz. Volta-se
    do vivo para o arquivo anterior pelo seq (o anterior termina em seq-1) até um que comece antes de `since`; se a corrente quebra
    (arquivo apagado, seq sem par, 1º registro sem seq), a cobertura começa no último arquivo ligado — e isso vira aviso."""
    gc = os.path.join(city, ".gc")
    by_last = {}
    try:
        for f in os.listdir(gc):
            m = re.fullmatch(r"events\.jsonl\.archive-\d{8}T\d{6}Z-seq-(\d+)-(\d+)\.gz", f)
            if m:
                by_last[int(m.group(2))] = (os.path.join(gc, f), int(m.group(1)))
    except FileNotFoundError:
        pass
    path, first_seq = os.path.join(gc, "events.jsonl"), None
    while True:
        ev, b, head = read_lines(path, '"session.woke"')
        yield ev, b
        start = head_ts(head)
        if head is None or start is None:
            what = "não existe" if not os.path.exists(path) else "não tem 1º registro com data legível"
            if first_seq is None:  # o vivo
                warns.append(f"mini: {path} {what}: a coluna do mini fica sem fonte, não zerada")
                return None
            warns.append(f"mini: {os.path.basename(path)} {what}: a cobertura começa em {last_cover.astimezone().isoformat(timespec='minutes')}")
            return last_cover
        seq = head.get("seq") if first_seq is None else first_seq
        if type(seq) is int and seq == 1:
            return GENESIS
        if start <= since:
            return start
        prev = by_last.get(seq - 1) if type(seq) is int else None
        if prev is None:
            warns.append(f"mini: os logs do engine só cobrem a partir de {start.astimezone().isoformat(timespec='minutes')} "
                         f"(não achei o arquivo anterior a {os.path.basename(path)}): noites antes disso saem sem fonte ou parciais")
            return start
        last_cover, (path, first_seq) = start, prev


def coverage(cover, night: str):
    """completa / parcial / sem-fonte de uma fonte numa noite, pelo instante desde quando a fonte cobre."""
    ns, ne = night_bounds(night)
    if cover is None or cover >= ne:
        return "sem-fonte"
    return "completa" if cover <= ns else "parcial"


def night_bounds(night: str):
    d = datetime.strptime(night, "%Y-%m-%d").date()
    return (datetime.combine(d, time(NIGHT_FROM)).astimezone(), datetime.combine(d + timedelta(days=1), time(NIGHT_TO)).astimezone())


def collect(city: str, since: datetime):
    """({noite: {host: {construtor, revisor, outros, recusas{motivo:n}}}}, {host: desde quando cobre}, nº de linhas ilegíveis, avisos)."""
    out: dict = defaultdict(lambda: defaultdict(lambda: {"construtor": 0, "revisor": 0, "outros": 0, "recusas": defaultdict(int)}))
    bad, warns, covers = 0, [], {}
    gen = engine_files(city, since, warns)
    while True:
        try:
            ev, b = next(gen)
        except StopIteration as stop:
            covers["mini"] = stop.value
            break
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
        ev, b, head = read_lines(os.path.join(base, h, "events.jsonl"))
        bad += b
        covers[h] = head_ts(head)  # o provider não roda o log: ele começa no 1º fato do host; antes disso não há registro (não "zero")
        if covers[h] is None or covers[h] > since:
            warns.append(f"{h}: o log do host " + (f"começa em {covers[h].astimezone().isoformat(timespec='minutes')}" if covers[h]
                                                    else "não existe ou não tem data legível") + ": noites antes disso saem sem fonte")
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
    return out, covers, bad, warns


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
    t = now.astimezone()
    last = t.date() if t.hour >= NIGHT_FROM else t.date() - timedelta(days=1)  # a noite mais recente que já começou
    nights = [(last - timedelta(days=i)).isoformat() for i in range(a.noites)]  # TODAS as N noites, com ou sem dados
    since = night_bounds(nights[-1])[0]
    try:
        data, covers, bad, warns = collect(a.city, since)
    except OSError as e:
        sys.stderr.write(f"não consegui ler os logs: {e}\n")
        return 1
    rows = []
    for n in nights:
        hosts = {}
        for h in sorted(covers):
            c = coverage(covers[h], n)
            v = data[n][h] if n in data and h in data[n] else {"construtor": 0, "revisor": 0, "outros": 0, "recusas": {}}
            hosts[h] = (dict(v, recusas=dict(v["recusas"]), cobertura=c) if c != "sem-fonte"
                        else {"construtor": None, "revisor": None, "outros": None, "recusas": {}, "cobertura": c})
        rows.append({"noite": n, "em_curso": night_bounds(n)[1] > now, "hosts": hosts})
    cov = {h: ("início" if c is GENESIS else c.isoformat() if c else None) for h, c in sorted(covers.items())}
    if a.json:
        print(json.dumps({"noites": rows, "cobertura_desde": cov, "linhas_ilegiveis": bad, "avisos": warns}, ensure_ascii=False, indent=2))
        return 0
    for r in rows:
        print(f"noite de {r['noite']} (20:00 → 08:00)" + (" — em curso" if r["em_curso"] else ""))
        for h, v in r["hosts"].items():
            if v["cobertura"] == "sem-fonte":
                print(f"  {h:<10} sem fonte (o log não cobre esta noite)")
                continue
            rec = ", ".join(f"{m}={c}" for m, c in sorted(v["recusas"].items()))
            print(f"  {h:<10} construtores {v['construtor']:>3} · revisores {v['revisor']:>3} · outros {v['outros']:>3}" + (f" · recusas: {rec}" if rec else "")
                  + (f" · PARCIAL (log desde {cov[h][:16]})" if v["cobertura"] == "parcial" else ""))
    if bad:
        print(f"AVISO: {bad} linha(s) ilegível(is) nos logs (não contadas)", file=sys.stderr)
    for w in warns:
        print(f"AVISO: {w}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
