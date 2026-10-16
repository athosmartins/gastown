#!/usr/bin/env python3
"""nightly-grid.py — a grade noturna lida dos plists VIVOS do launchd (ga-sh8t23.1; revisão de arquitetura 15/10).

Contents
  Para que serve · O que mostra · Três estados · Uso · Limites

PARA QUE SERVE
  O critério da ga-sh8t23 ("nenhum minuto da madrugada com mais de 1 job de pico") não é verificável sem a grade: ela só existia na cabeça e em ~400 plists.
  Este comando a lê de onde ela RODA (~/Library/LaunchAgents, o que o launchd carregou), não dos plists do repositório: fonte ≠ o que roda. SÓ LEITURA: não
  chama launchctl load/unload, não escreve nada, não move job. Detector sem poll: roda quando alguém pede (um guarda com StartInterval seria outro bead).

O QUE MOSTRA
  Resumo (plists, ilegíveis, lidos via plutil, formato desconhecido, não carregados, RunAtLoad, calendário, StartInterval, KeepAlive) · minutos com N ou mais inícios (`--min-collision`, padrão 3) · a grade
  minuto a minuto da janela (`--from`/`--to`, padrão 00:00-07:59) · o que dispara "a cada minuto" por calendário (sem Minute) · StartInterval por faixa · o
  conjunto RunAtLoad, que é o que sobe junto no boot (`--boot` lista tudo). Entrada de calendário sem a chave Hour = toda hora; sem Minute = todo minuto (curinga,
  como no launchd). Weekday/Day/Month são condicionais: entram na contagem MARCADOS (`job [seg]`), porque num dia em que valem colidem de verdade.

TRÊS ESTADOS (o que não sei NÃO vira "não tem")
  plist ilegível aparece na saída com o motivo, e o que tem StartCalendarInterval que não conheço aparece listado; os dois são contados: nunca somem. `launchctl list` que falha ou vem sem
  nenhum job → "carregado: desconhecido": todos entram na grade e o relatório diz isso (nunca "nada carregado"). Plist em disco cujo label não está carregado fica
  numa seção própria e FORA das colisões. Pasta ilegível → exit 3 sem grade (não sei ≠ grade vazia); filtro que não casa nada → diz isso.

  Plist que o expat do Python recusa mas o launchd aceita (ex.: `--x` dentro de comentário XML) é lido pelo `plutil -convert xml1` (NG_PLUTIL troca o binário) e contado
  em "lidos via plutil"; só vai para "ilegíveis" se os dois falham.

USO  nightly-grid.py [--dir D] [--match REGEX] [--from HH:MM] [--to HH:MM] [--min-collision N] [--boot] [--json] [--loaded-file ARQ]
  --match filtra pelo NOME do arquivo (padrão: gascity|whatsapp|gastown|urblink, ou seja, o que é nosso). --loaded-file lê a saída de `launchctl list` de um arquivo
  (testes). NG_LAUNCHCTL troca o binário. Códigos: 0 relatório feito (mesmo com colisão: é detecção, não bloqueio) · 2 uso errado · 3 não consegui ler a entrada.

LIMITES  só entende StartCalendarInterval (dict ou lista de dict), StartInterval, RunAtLoad e KeepAlive; WatchPaths/QueueDirectories não têm horário e ficam fora. A hora
  do StartInterval depende de quando o job foi carregado (após o reboot noturno: todos juntos), por isso é resumo e não grade. Quanto de RAM cada job usa NÃO sai daqui.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import plistlib
import re
import subprocess
import sys

DAYS = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]
BANDS = ((60, "<= 1 min"), (300, "<= 5 min"), (900, "<= 15 min"), (3600, "<= 1 h"), (10 ** 9, "> 1 h"))


def hhmm(arg: str) -> int:
    m = re.fullmatch(r"(\d{1,2}):(\d{2})", arg)
    if not m or int(m.group(1)) > 23 or int(m.group(2)) > 59:
        raise argparse.ArgumentTypeError(f"hora inválida: {arg!r} (use HH:MM)")
    return int(m.group(1)) * 60 + int(m.group(2))


def fmt(minute: int) -> str:
    return f"{minute // 60:02d}:{minute % 60:02d}"


def cond_text(entry: dict) -> str:
    """Condição de uma entrada de calendário (vazio = todo dia). Chave que não é inteiro válido → ValueError (o job vai para `odd`)."""
    out = []
    for key, lo, hi in (("Weekday", 0, 7), ("Day", 1, 31), ("Month", 1, 12)):  # (chave, mínimo, máximo)
        v = entry.get(key)  # vazio → sem restrição nessa chave; ilegível (não é inteiro na faixa) → ValueError, e o job é listado como "formato que não conheço"
        if v is None:
            continue
        if isinstance(v, bool) or not isinstance(v, int) or not lo <= v <= hi:
            raise ValueError(f"{key}={v!r}")
        out.append(DAYS[v % 7] if key == "Weekday" else f"{'dia' if key == 'Day' else 'mês'} {v}")
    return ",".join(out)


def starts(entry: dict, lo: int, hi: int):
    """Inícios [(minuto do dia, condição)] de UMA entrada dentro de [lo, hi]; None = sem Minute, dispara a cada minuto (não expande)."""
    minute, hour = entry.get("Minute"), entry.get("Hour")  # vazio → curinga (como o launchd); ilegível (não é inteiro na faixa) → ValueError
    for v, top in ((minute, 59), (hour, 23)):
        if v is not None and (isinstance(v, bool) or not isinstance(v, int) or not 0 <= v <= top):
            raise ValueError(f"Hour/Minute inválido: {entry!r}")
    cond = cond_text(entry)
    if minute is None:
        return None
    return [(h * 60 + minute, cond) for h in (range(24) if hour is None else [hour]) if lo <= h * 60 + minute <= hi]


def load_plist(path: str):
    """→ (dict, "plistlib"|"plutil"). O launchd aceita XML que o expat do Python recusa (medido 16/10: `--dry-run` dentro de um comentário `<!-- -->` em 2 plists vivos,
    jobs carregados e agendados que sumiriam da grade). Falhou no plistlib → o plutil converte e o plistlib lê o resultado; falhou nos dois (ou sem plutil) → sobe a
    exceção do plistlib e o plist vai para `bad`. vazio → n/a."""
    try:
        with open(path, "rb") as fh:
            return plistlib.load(fh), "plistlib"
    except Exception as first:  # noqa: BLE001
        try:
            r = subprocess.run([os.environ.get("NG_PLUTIL", "plutil"), "-convert", "xml1", "-o", "-", path], capture_output=True, timeout=15)
            if r.returncode == 0:
                return plistlib.loads(r.stdout), "plutil"
        except (OSError, subprocess.SubprocessError, ValueError):
            pass
        raise first


def read_plists(d: str, match: str):
    """→ (jobs, bad). vazio → pasta sem plist que case: ([], []) e o relatório diz isso; falhou (a pasta não abre) → OSError, e main sai 3 sem grade; plist
    ilegível → vai para `bad` com o motivo, nunca some."""
    jobs, bad = [], []
    for name in sorted(n for n in os.listdir(d) if n.endswith(".plist") and re.search(match, n)):
        try:
            p, via = load_plist(os.path.join(d, name))
            if not isinstance(p, dict):
                raise ValueError("não é um dicionário")
        except Exception as e:  # noqa: BLE001 — qualquer defeito do arquivo vira linha do relatório
            bad.append({"file": name, "why": f"{type(e).__name__}: {str(e)[:80]}"})
            continue
        cal = p.get("StartCalendarInterval")  # vazio → sem horário de calendário; ilegível (nem dict nem lista de dict) → `odd`
        cal = [] if cal is None else [cal] if isinstance(cal, dict) else cal
        iv = p.get("StartInterval")
        jobs.append({"label": str(p.get("Label") or name[:-6]), "file": name, "via": via, "boot": p.get("RunAtLoad") is True, "keepalive": bool(p.get("KeepAlive")),
                     "interval": iv if isinstance(iv, int) and not isinstance(iv, bool) and iv > 0 else None, "cal": cal,
                     "odd": not isinstance(cal, list) or not all(isinstance(e, dict) for e in cal)})
    return jobs, bad


def loaded_labels(path):
    """Conjunto de labels carregados, ou None = não sei. vazio → um `launchctl list` sem NENHUMA linha de job é resposta suspeita (a máquina sempre tem): None, não
    "nada carregado"; falhou (binário ausente, rc != 0, tempo esgotado) → None; arquivo de --loaded-file ilegível → OSError (main sai 3)."""
    if path:
        with open(path) as fh:
            text = fh.read()
    else:
        try:
            r = subprocess.run([os.environ.get("NG_LAUNCHCTL", "launchctl"), "list"], capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            return None
        if r.returncode != 0:
            return None
        text = r.stdout
    lines = text.splitlines()
    if lines and lines[0].startswith("PID"):  # o cabeçalho sai; sem cabeçalho a primeira linha É um job e não pode se perder
        lines = lines[1:]
    labels = {f[2] for f in (ln.split("\t") for ln in lines) if len(f) == 3}
    return labels or None


def build(jobs, bad, loaded, lo, hi, n):
    seen, every, per, odd, off = collections.defaultdict(dict), [], collections.Counter(), [], []  # seen: minuto -> {label: condições ou None se algum início é diário}
    for j in jobs:
        if loaded is not None and j["label"] not in loaded:
            off.append(j["label"])
            continue
        try:  # o calendário do job inteiro ou nada: um job que falha na 2ª entrada não deixa a 1ª solta na grade
            got = [] if j["odd"] else [starts(e, lo, hi) for e in j["cal"]]
        except ValueError:
            got = None
        if j["odd"] or got is None:
            odd.append(j["label"])
        for hit in got or []:
            if hit is None:
                every.append(j["label"])
            for minute, cond in hit or []:  # o MESMO job em cinco dias da semana é um job só no minuto (cinco entradas de calendário não são cinco jobs colidindo)
                cur = seen[minute].get(j["label"], set())  # vazio → ainda sem início nesse minuto; None = algum início é diário, e o diário vale mais que o condicional
                seen[minute][j["label"]] = None if cur is None or not cond else cur | {cond}
        if j["interval"]:
            per[next(b for lim, b in BANDS if j["interval"] <= lim)] += 1
    day_order = lambda t: (DAYS.index(t[:3]) if t[:3] in DAYS else 9, t)  # noqa: E731 — dias da semana na ordem de DAYS (dom primeiro, como no launchd), depois dia/mês
    grid = {m: [lb + (f" [{','.join(sorted(c, key=day_order))}]" if c else "") for lb, c in sorted(d.items())] for m, d in seen.items()}
    live = [j for j in jobs if j["label"] not in off]  # o formato do calendário não diz nada sobre RunAtLoad/KeepAlive/StartInterval: esses seguem contados
    boot = sorted(j["label"] for j in live if j["boot"])
    return {"window": [fmt(lo), fmt(hi)], "min_collision": n, "loaded": "desconhecido" if loaded is None else "conhecido",
            "counts": {"plists": len(jobs) + len(bad), "ilegiveis": len(bad), "formato_desconhecido": len(odd), "lidos_via_plutil": sum(1 for j in jobs if j["via"] == "plutil"), "nao_carregados": len(off), "boot_runatload": len(boot),
                       "calendario": sum(1 for j in live if j["cal"]), "start_interval": sum(per.values()), "keepalive": sum(1 for j in live if j["keepalive"])},
            "collisions": {fmt(m): v for m, v in sorted(grid.items()) if len(v) >= n}, "grid": {fmt(m): v for m, v in sorted(grid.items())},
            "every_minute": sorted(set(every)), "periodic": dict(per), "boot": boot, "unreadable": bad, "odd": sorted(set(odd)), "not_loaded": sorted(off)}


def render(r, show_boot):
    c, out = r["counts"], []
    out += [f"# Grade noturna {r['window'][0]}-{r['window'][1]} (plists vivos; carregado: {r['loaded']})", "",
            f"plists {c['plists']} · ilegíveis {c['ilegiveis']} · lidos via plutil {c['lidos_via_plutil']} · formato desconhecido {c['formato_desconhecido']} · não carregados {c['nao_carregados']} · RunAtLoad {c['boot_runatload']} · "
            f"com calendário {c['calendario']} · StartInterval {c['start_interval']} · KeepAlive {c['keepalive']}", ""]
    if r["loaded"] == "desconhecido":
        out += ["AVISO: não consegui ler `launchctl list`; todos os plists entram na grade (pode haver job que não está carregado).", ""]
    if c["plists"] == 0:
        out += ["Nenhum plist casa com o filtro (confira --dir e --match): nada a mostrar, e isso NÃO é uma grade vazia.", ""]
    out += [f"## Minutos com {r['min_collision']} ou mais inícios ({len(r['collisions'])})", ""]
    out += [f"* {t} — {len(v)}: {', '.join(v)}" for t, v in r["collisions"].items()] or ["(nenhum)"]
    out += ["", "## Grade (só os minutos com início; `[seg]` = condicional, vale só no dia indicado)", ""]
    out += [f"* {t} — {', '.join(v)}" for t, v in r["grid"].items()] or ["(nenhum início na janela)"]
    out += ["", f"## A cada minuto por calendário ({len(r['every_minute'])}; fora das colisões)", ""] + [f"* {x}" for x in r["every_minute"]]
    out += ["", "## StartInterval por faixa (a hora depende de quando foi carregado: resumo, não grade)", ""] + [f"* {b}: {r['periodic'].get(b, 0)}" for _, b in BANDS]
    pref = collections.Counter(".".join(x.split(".")[:2]) for x in r["boot"])
    out += ["", f"## Sobe junto no boot — RunAtLoad ({len(r['boot'])})", ""] + [f"* {p}: {n}" for p, n in pref.most_common()]
    if show_boot:
        out += [""] + [f"  - {x}" for x in r["boot"]]
    for title, key in (("Ilegíveis", "unreadable"), ("Formato de calendário que não conheço", "odd"), ("Em disco mas NÃO carregados (fora das colisões)", "not_loaded")):
        out += ["", f"## {title} ({len(r[key])})", ""] + [f"* {x['file']}: {x['why']}" if isinstance(x, dict) else f"* {x}" for x in r[key]]
    return "\n".join(out) + "\n"


def main(argv) -> int:
    ap = argparse.ArgumentParser(description="grade noturna lida dos plists vivos do launchd (somente leitura)")
    ap.add_argument("--dir", default=os.path.expanduser("~/Library/LaunchAgents"))
    ap.add_argument("--match", default=r"gascity|whatsapp|gastown|urblink")
    ap.add_argument("--from", dest="lo", type=hhmm, default=0)
    ap.add_argument("--to", dest="hi", type=hhmm, default=7 * 60 + 59)
    ap.add_argument("--min-collision", type=int, default=3)
    ap.add_argument("--boot", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--loaded-file")
    a = ap.parse_args(argv[1:])
    if a.min_collision < 1 or a.lo > a.hi:
        print("nightly-grid: --min-collision >= 1 e --from <= --to", file=sys.stderr)
        return 2
    try:
        jobs, bad = read_plists(a.dir, a.match)
        loaded = loaded_labels(a.loaded_file)
    except (OSError, re.error) as e:
        print(f"nightly-grid: não consegui ler a entrada ({type(e).__name__}: {e}); sem grade, que não é o mesmo que grade vazia", file=sys.stderr)
        return 3
    rep = build(jobs, bad, loaded, a.lo, a.hi, a.min_collision)
    sys.stdout.write(json.dumps(rep, ensure_ascii=False, indent=1) + "\n" if a.json else render(rep, a.boot))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
