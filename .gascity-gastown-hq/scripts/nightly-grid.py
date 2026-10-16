#!/usr/bin/env python3
"""nightly-grid.py — a grade noturna lida dos plists VIVOS do launchd (ga-sh8t23.1; revisão de arquitetura 15/10).

Contents
  Para que serve · O que mostra · Três estados · Uso · Limites

PARA QUE SERVE
  O critério da ga-sh8t23 ("nenhum minuto da madrugada com mais de 1 job de pico") não é verificável sem a grade: ela só existia na cabeça e em ~400 plists.
  Este comando a lê de onde ela RODA (~/Library/LaunchAgents, o que o launchd carregou), não dos plists do repositório: fonte ≠ o que roda. SÓ LEITURA: não
  chama launchctl load/unload, não escreve nada, não move job. Detector sem poll: roda quando alguém pede (um guarda com StartInterval seria outro bead).

O QUE MOSTRA
  Resumo (plists, ilegíveis, lidos via plutil, formato desconhecido, não carregados, RunAtLoad, calendário, StartInterval, KeepAlive) · minutos em que N ou mais jobs distintos podem começar no
  MESMO dia da semana (`--min-collision`, padrão 3; o pico por dia, não o total de labels do minuto: jobs de seg, ter e qua são 3 labels e pico 1) · a grade
  minuto a minuto da janela (`--from`/`--to`, padrão 00:00-07:59) · o que dispara "a cada minuto" por calendário (sem Minute, com a hora quando tem Hour e só se a hora toca a janela) ·
  StartInterval por faixa · o conjunto RunAtLoad, que é o que sobe junto no boot (`--boot` lista tudo). Entrada de calendário sem a chave Hour = toda hora; sem Minute = todo minuto
  (curinga, como no launchd). Weekday/Day/Month são condicionais: entram na grade MARCADOS (`job [seg]`). Day/Month não se cruzam com o dia da semana: o job conta em todos os dias (limite superior).

TRÊS ESTADOS (o que não sei NÃO vira "não tem")
  plist ilegível aparece na saída com o motivo; calendário que não conheço, e StartInterval/RunAtLoad/KeepAlive com tipo que o launchd não documenta (`"300"` em vez de 300), aparecem em "formato que
  não conheço" com a chave; tudo é contado: nunca some, e o valor malformado não conta como se fosse válido. `launchctl list` que falha, vem sem nenhum job ou vem com byte que não é UTF-8 →
  "carregado: desconhecido": todos entram na grade e o relatório diz isso (nunca "nada carregado"). Plist em disco cujo label não está carregado fica
  numa seção própria e FORA das colisões. Pasta ilegível, `--loaded-file` ilegível (não abre ou não é UTF-8) ou `--match` que não é regex → exit 3 sem grade (não sei ≠ grade vazia);
  filtro que não casa nada → diz isso.

  Plist que o expat do Python recusa mas o launchd aceita (ex.: `--x` dentro de comentário XML) é lido pelo `plutil -convert xml1` (NG_PLUTIL troca o binário) e contado
  em "lidos via plutil"; só vai para "ilegíveis" se os dois falham.

USO  nightly-grid.py [--dir D] [--match REGEX] [--from HH:MM] [--to HH:MM] [--min-collision N] [--boot] [--json] [--loaded-file ARQ]
  --match filtra pelo NOME do arquivo (padrão: gascity|whatsapp|gastown|urblink, ou seja, o que é nosso). --loaded-file lê a saída de `launchctl list` de um arquivo
  (testes). NG_LAUNCHCTL troca o binário. Códigos: 0 relatório feito (mesmo com colisão: é detecção, não bloqueio) · 2 uso errado · 3 não consegui ler a entrada (pasta, --loaded-file, --match).

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
VALID = {"StartInterval": lambda v: isinstance(v, int) and not isinstance(v, bool) and v > 0,  # tipo que o launchd documenta para cada chave que o gerador usa
         "RunAtLoad": lambda v: isinstance(v, bool), "KeepAlive": lambda v: isinstance(v, (bool, dict))}
BANDS = ((60, "<= 1 min"), (300, "<= 5 min"), (900, "<= 15 min"), (3600, "<= 1 h"), (float("inf"), "> 1 h"))  # a última faixa pega QUALQUER inteiro (o "nunca" int32 é 2147483647)


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
    """→ (inícios, curinga) de UMA entrada. inícios = [(minuto do dia, condição)] dentro de [lo, hi]. curinga = None, ou o texto (`hora 3`, `seg`, "" se é todo dia) quando a entrada
    não tem Minute e dispara a cada minuto DENTRO da janela (não expande). Sem Minute e com a hora inteira fora da janela → ([], None): não dispara na madrugada."""
    minute, hour = entry.get("Minute"), entry.get("Hour")  # vazio → curinga (como o launchd); ilegível (não é inteiro na faixa) → ValueError
    for v, top in ((minute, 59), (hour, 23)):
        if v is not None and (isinstance(v, bool) or not isinstance(v, int) or not 0 <= v <= top):
            raise ValueError(f"Hour/Minute inválido: {entry!r}")
    cond, hours = cond_text(entry), range(24) if hour is None else [hour]
    if minute is None:
        if not any(h * 60 <= hi and h * 60 + 59 >= lo for h in hours):  # a hora inteira (hh:00-hh:59) cai fora da janela → não entra em "a cada minuto" de uma grade noturna
            return [], None
        return [], ",".join(x for x in (f"hora {hour}" if hour is not None else "", cond) if x)
    return [(h * 60 + minute, cond) for h in hours if lo <= h * 60 + minute <= hi], None


def weekdays(cond: str) -> frozenset:
    """Dias da semana (índice em DAYS) em que uma condição vale. Sem Weekday na condição (diário, ou só Day/Month) → os 7: Day/Month não se cruza com o dia da semana aqui, e
    contar o job em todos os dias é o limite SUPERIOR (o lado seguro para quem procura colisão)."""
    return frozenset(DAYS.index(p) for p in cond.split(",") if p in DAYS) or frozenset(range(7))


def day_peak(by_label: dict) -> int:
    """Maior número de jobs DISTINTOS que podem começar no MESMO dia da semana neste minuto (by_label: label → None = algum início diário | {condições}). Três jobs em seg, ter e
    qua são 3 labels no minuto mas pico 1: nunca rodam juntos."""
    per_day = collections.Counter()
    for conds in by_label.values():
        for k in frozenset(range(7)) if not conds else frozenset().union(*map(weekdays, conds)):
            per_day[k] += 1
    return max(per_day.values(), default=0)


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
    rx = re.compile(match)  # compila ANTES de olhar a pasta: regex inválida sobe re.error (main sai 3) mesmo numa pasta sem nenhum .plist, em vez de "nenhum plist casa"
    for name in sorted(n for n in os.listdir(d) if n.endswith(".plist") and rx.search(n)):
        try:
            p, via = load_plist(os.path.join(d, name))
            if not isinstance(p, dict):
                raise ValueError("não é um dicionário")
        except Exception as e:  # noqa: BLE001 — qualquer defeito do arquivo vira linha do relatório
            bad.append({"file": name, "why": f"{type(e).__name__}: {str(e)[:80]}"})
            continue
        cal = p.get("StartCalendarInterval")  # vazio → sem horário de calendário; ilegível (nem dict nem lista de dict) → `odd`
        cal = [] if cal is None else [cal] if isinstance(cal, dict) else cal
        # chave ausente → sem defeito (o job só não usa isso); chave PRESENTE com tipo que não conheço (`"300"` em vez de 300, `"true"` em vez de true) → `bad_keys` e o job vai para
        # "formato que não conheço" com a chave: não sei se o launchd a honra, e "não sei" não vira "não tem". O valor malformado não conta como RunAtLoad/KeepAlive/StartInterval.
        bad_keys = [f"{k}={p[k]!r}"[:60] for k, valid in VALID.items() if k in p and not valid(p[k])]
        iv, ka = p.get("StartInterval"), p.get("KeepAlive")
        jobs.append({"label": str(p.get("Label") or name[:-6]), "file": name, "via": via, "boot": p.get("RunAtLoad") is True, "keepalive": VALID["KeepAlive"](ka) and bool(ka),
                     "interval": iv if VALID["StartInterval"](iv) else None, "cal": cal, "bad_keys": bad_keys,
                     "odd": not isinstance(cal, list) or not all(isinstance(e, dict) for e in cal)})
    return jobs, bad


def loaded_labels(path):
    """Conjunto de labels carregados, ou None = não sei. vazio → um `launchctl list` sem NENHUMA linha de job é resposta suspeita (a máquina sempre tem): None, não
    "nada carregado"; falhou (binário ausente, rc != 0, tempo esgotado, saída que não é UTF-8) → None; arquivo de --loaded-file ilegível (não abre ou não é UTF-8) → OSError/UnicodeError
    (main sai 3). Trocar o byte ruim por "?" não serve: o label mudaria e um job carregado sairia da grade como "não carregado"."""
    if path:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    else:
        try:
            r = subprocess.run([os.environ.get("NG_LAUNCHCTL", "launchctl"), "list"], capture_output=True, text=True, encoding="utf-8", timeout=30)
        except (OSError, subprocess.SubprocessError, UnicodeError):
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
    odd_why = collections.defaultdict(list)  # label -> motivos de "formato que não conheço"
    for j in jobs:
        if loaded is not None and j["label"] not in loaded:
            off.append(j["label"])
            continue
        try:  # o calendário do job inteiro ou nada: um job que falha na 2ª entrada não deixa a 1ª solta na grade
            got = [] if j["odd"] else [starts(e, lo, hi) for e in j["cal"]]
        except ValueError:
            got = None
        why = (["calendário"] if j["odd"] or got is None else []) + j["bad_keys"]
        if why:
            odd.append(j["label"])
            odd_why[j["label"]] += why
        for hits, wild in got or []:
            if wild is not None:  # sem Minute e com a hora dentro da janela: a hora vai junto, senão "toda hora" e "só às 03h" ficam iguais
                every.append(j["label"] + (f" [{wild}]" if wild else ""))
            for minute, cond in hits:  # o MESMO job em cinco dias da semana é um job só no minuto (cinco entradas de calendário não são cinco jobs colidindo)
                cur = seen[minute].get(j["label"], set())  # vazio → ainda sem início nesse minuto; None = algum início é diário, e o diário vale mais que o condicional
                seen[minute][j["label"]] = None if cur is None or not cond else cur | {cond}
        if j["interval"]:
            per[next(b for lim, b in BANDS if j["interval"] <= lim)] += 1
    day_order = lambda t: (DAYS.index(t[:3]) if t[:3] in DAYS else 9, t)  # noqa: E731 — dias da semana na ordem de DAYS (dom primeiro, como no launchd), depois dia/mês
    grid = {m: [lb + (f" [{','.join(sorted(c, key=day_order))}]" if c else "") for lb, c in sorted(d.items())] for m, d in seen.items()}
    live = [j for j in jobs if j["label"] not in off]  # o formato do calendário não diz nada sobre RunAtLoad/KeepAlive/StartInterval: esses seguem contados
    boot = sorted(j["label"] for j in live if j["boot"])
    peaks = {m: day_peak(d) for m, d in seen.items()}  # colisão = pico no MESMO dia da semana, não o total de labels do minuto (jobs de dias disjuntos nunca rodam juntos)
    return {"window": [fmt(lo), fmt(hi)], "min_collision": n, "loaded": "desconhecido" if loaded is None else "conhecido",
            "counts": {"plists": len(jobs) + len(bad), "ilegiveis": len(bad), "formato_desconhecido": len(set(odd)), "lidos_via_plutil": sum(1 for j in jobs if j["via"] == "plutil"), "nao_carregados": len(off), "boot_runatload": len(boot),
                       "calendario": sum(1 for j in live if j["cal"]), "start_interval": sum(per.values()), "keepalive": sum(1 for j in live if j["keepalive"])},
            "collisions": {fmt(m): v for m, v in sorted(grid.items()) if peaks[m] >= n}, "peak": {fmt(m): peaks[m] for m in sorted(grid)}, "grid": {fmt(m): v for m, v in sorted(grid.items())},
            "every_minute": sorted(set(every)), "periodic": dict(per), "boot": boot, "unreadable": bad, "odd": sorted(set(odd)), "odd_why": {x: odd_why[x] for x in sorted(set(odd))}, "not_loaded": sorted(off)}


def render(r, show_boot):
    c, out = r["counts"], []
    out += [f"# Grade noturna {r['window'][0]}-{r['window'][1]} (plists vivos; carregado: {r['loaded']})", "",
            f"plists {c['plists']} · ilegíveis {c['ilegiveis']} · lidos via plutil {c['lidos_via_plutil']} · formato desconhecido {c['formato_desconhecido']} · não carregados {c['nao_carregados']} · RunAtLoad {c['boot_runatload']} · "
            f"com calendário {c['calendario']} · StartInterval {c['start_interval']} · KeepAlive {c['keepalive']}", ""]
    if r["loaded"] == "desconhecido":
        out += ["AVISO: não consegui ler `launchctl list`; todos os plists entram na grade (pode haver job que não está carregado).", ""]
    if c["plists"] == 0:
        out += ["Nenhum plist casa com o filtro (confira --dir e --match): nada a mostrar, e isso NÃO é uma grade vazia.", ""]
    out += [f"## Minutos com {r['min_collision']} ou mais inícios no mesmo dia da semana ({len(r['collisions'])})", ""]
    out += [f"* {t} — {r['peak'][t]}{'' if r['peak'][t] == len(v) else f' no mesmo dia ({len(v)} jobs no total)'}: {', '.join(v)}" for t, v in r["collisions"].items()] or ["(nenhum)"]
    out += ["", "## Grade (só os minutos com início; `[seg]` = condicional, vale só no dia indicado)", ""]
    out += [f"* {t} — {', '.join(v)}" for t, v in r["grid"].items()] or ["(nenhum início na janela)"]
    out += ["", f"## A cada minuto por calendário ({len(r['every_minute'])}; fora das colisões)", ""] + [f"* {x}" for x in r["every_minute"]]
    out += ["", "## StartInterval por faixa (a hora depende de quando foi carregado: resumo, não grade)", ""] + [f"* {b}: {r['periodic'].get(b, 0)}" for _, b in BANDS]
    pref = collections.Counter(".".join(x.split(".")[:2]) for x in r["boot"])
    out += ["", f"## Sobe junto no boot — RunAtLoad ({len(r['boot'])})", ""] + [f"* {p}: {n}" for p, n in pref.most_common()]
    if show_boot:
        out += [""] + [f"  - {x}" for x in r["boot"]]
    rows = {"unreadable": [f"{x['file']}: {x['why']}" for x in r["unreadable"]], "odd": [f"{x}: {'; '.join(r['odd_why'][x])}" for x in r["odd"]], "not_loaded": r["not_loaded"]}
    for title, key in (("Ilegíveis", "unreadable"), ("Formato que não conheço (calendário, StartInterval, RunAtLoad, KeepAlive)", "odd"), ("Em disco mas NÃO carregados (fora das colisões)", "not_loaded")):
        out += ["", f"## {title} ({len(r[key])})", ""] + [f"* {x}" for x in rows[key]]
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
    except (OSError, UnicodeError, re.error) as e:  # UnicodeError: --loaded-file que não é UTF-8; sem grade, igual a pasta ilegível
        print(f"nightly-grid: não consegui ler a entrada ({type(e).__name__}: {e}); sem grade, que não é o mesmo que grade vazia", file=sys.stderr)
        return 3
    rep = build(jobs, bad, loaded, a.lo, a.hi, a.min_collision)
    sys.stdout.write(json.dumps(rep, ensure_ascii=False, indent=1) + "\n" if a.json else render(rep, a.boot))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
