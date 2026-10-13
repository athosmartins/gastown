#!/usr/bin/env python3
"""coverage.py — quanto do pytest de workers e crews o atalho (pytest-shim.sh) alcança, e quanto foi ao MBP (ga-fl2nek).

Contents
    Por quê · Uso · O que conta

POR QUÊ: o aceite da ga-fl2nek é ">= 70% das rodadas de pytest dos workers no MBP". O log do atalho (pytest-shim.jsonl) só vê o que PASSOU pelo atalho; o pytest
    chamado por caminho explícito (`venv/bin/python -m pytest`) não passa pelo PATH e é invisível ali. O denominador honesto vem dos transcritos: este script conta, por
    FORMA de chamada, os comandos Bash dos workers e crews que rodaram pytest, e junta com o log do atalho e o mbp-run.jsonl.

USO:    python3 -I scripts/pytest-shim/coverage.py [--dias 14] [--desde 2026-10-14T00:00:00Z]
        --dias: janela dos transcritos (arquivos de ~/.claude/projects modificados nos últimos N dias; só as pastas de projeto cujo nome cita whatsapp-automation ou
        property-scrapers — raiz fixa, nunca varredura do $HOME). --desde: corta o log do atalho e o mbp-run.jsonl no mesmo instante (ISO com fuso).

O QUE CONTA: um comando Bash com UMA forma de pytest (a primeira que casa), nesta ordem:
    mbp-run.sh                      o worker chamou o wrapper à mão (preâmbulo ga-yvs19w)
    venv/bin/python -m pytest       caminho explícito de python: NÃO passa pelo atalho (o limite conhecido)
    python3|python -m pytest        passa pelo atalho (stub python3/python)
    pytest solto                    passa pelo atalho (stub pytest); só em posição de comando (início, depois de ; && || | ( ou `exec`), não texto que cita pytest
    outro                           cita pytest sem rodá-lo (grep, edição de arquivo): não conta como rodada
Contagem de COMANDOS, não de arquivos de teste: um comando com 5 arquivos é uma rodada. É aproximação (uma linha com dois pytest conta uma vez) — serve para o
denominador do aceite, não para contabilidade.
"""
import argparse
import collections
import json
import os
import re
import sys
import time
from datetime import datetime

PROJECTS = os.path.expanduser("~/.claude/projects")
CITY = os.environ.get("GC_CITY_PATH") or "/Users/athos/gt/.gascity-gastown-hq"
FORMS = (
    ("mbp-run.sh", re.compile(r"mbp-run\.sh")),
    ("venv/bin/python -m pytest", re.compile(r"(?:^|[\s;&|(])(?:\S*/)?(?:\.?venv[\w-]*)/bin/python[0-9.]*\s+(?:-\S+\s+)*-m\s*pytest\b")),
    ("python3|python -m pytest", re.compile(r"(?:^|[;&|(]\s*|\bexec\s+|\btimeout\s+\d+\s+|\bnice\s+(?:-n\s*\d+\s+)?|\benv\s+(?:\S+=\S+\s+)*|=\S*\s+)python3?(?:\.\d+)?\s+(?:-\S+\s+)*-m\s*pytest\b")),
    ("pytest solto", re.compile(r"(?:^|[;&|(]\s*|\bexec\s+|\btimeout\s+\d+\s+|\bnice\s+(?:-n\s*\d+\s+)?)pytest(?:\s|$)")),
)


def classify(cmd):
    if "pytest" not in cmd and "mbp-run" not in cmd:
        return None
    # linha a linha: um heredoc de Python que cita pytest no texto não é uma chamada
    for line in cmd.splitlines():
        for name, rx in FORMS:
            if rx.search(line):
                return name
    return "outro"


def transcripts(dias):
    cut = time.time() - dias * 86400
    if not os.path.isdir(PROJECTS):
        return
    for d in os.listdir(PROJECTS):
        if not re.search(r"whatsapp-automation|property-scrapers", d):
            continue
        p = os.path.join(PROJECTS, d)
        for f in os.listdir(p):
            fp = os.path.join(p, f)
            if f.endswith(".jsonl") and os.path.getmtime(fp) >= cut:
                yield d, fp


def scan(dias):
    """(contagem por forma, linhas de transcrito que citam pytest mas não abriram como JSON). Linha ilegível não é "nenhuma rodada": é dita no relatório."""
    forms = collections.Counter()
    unreadable = 0
    for _, fp in transcripts(dias):
        with open(fp, errors="replace") as fh:
            for line in fh:
                if "pytest" not in line and "mbp-run" not in line:
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    unreadable += 1
                    continue
                c = (o.get("message") or {}).get("content")
                if not isinstance(c, list):
                    continue
                for b in c:
                    if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash":
                        k = classify((b.get("input") or {}).get("command", ""))
                        if k:
                            forms[k] += 1
    return forms, unreadable


def read_jsonl(path, desde):
    rows, bad = [], 0
    try:
        with open(path) as fh:
            for line in fh:
                if not line.strip():
                    continue
                try:
                    r = json.loads(line)
                except ValueError:
                    bad += 1
                    continue
                if not desde or str(r.get("ts", "")) >= desde:
                    rows.append(r)
    except OSError:
        return None, 0
    return rows, bad


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dias", type=int, default=14)
    ap.add_argument("--desde", default=None, help="ISO com fuso, ex.: 2026-10-14T00:00:00Z")
    a = ap.parse_args(argv)
    if a.desde:
        try:
            tz = datetime.fromisoformat(a.desde.replace("Z", "+00:00")).tzinfo
        except ValueError:
            sys.exit("--desde inválido (ISO com fuso, ex.: 2026-10-14T00:00:00Z)")
        if tz is None:
            sys.exit("--desde precisa de fuso (ex.: 2026-10-14T00:00:00Z): sem fuso a data seria lida na zona da máquina")
    forms, unreadable = scan(a.dias)
    runs = {k: v for k, v in forms.items() if k != "outro"}
    total = sum(runs.values())
    print(f"== rodadas de pytest nos transcritos de workers e crews (últimos {a.dias} dias; {forms.get('outro', 0)} comandos só citam pytest e não contam)")
    for k, v in sorted(runs.items(), key=lambda x: -x[1]):
        print(f"  {v:5d}  {k}")
    if unreadable:
        print(f"  AVISO: {unreadable} linha(s) de transcrito citavam pytest mas não abriram como JSON — a contagem acima pode estar abaixo do real")
    reach = runs.get("python3|python -m pytest", 0) + runs.get("pytest solto", 0)
    if total:
        print(f"  -> o atalho ALCANÇA {reach} de {total} ({100 * reach // total}%); fora do alcance (caminho explícito de python): {runs.get('venv/bin/python -m pytest', 0)} ({100 * runs.get('venv/bin/python -m pytest', 0) // total}%)")
    rows, bad = read_jsonl(os.path.join(CITY, ".gc/logs/pytest-shim.jsonl"), a.desde)
    print("== log do atalho" + (f" (desde {a.desde})" if a.desde else ""))
    if rows is None:
        print("  (sem pytest-shim.jsonl: nenhuma execução passou pelo atalho ainda)")
    else:
        by = collections.Counter(r.get("ran", "?") for r in rows)
        n = len(rows)
        print(f"  rodadas pelo atalho: {n}  (mbp={by['mbp']}  mbp+local={by['mbp+local']}  local={by['local']})" + (f"  [{bad} linha(s) ilegível(is)]" if bad else ""))
        if n:
            print(f"  -> no MBP (verde aceito): {100 * by['mbp'] // n}% das rodadas que passaram pelo atalho")
        why = collections.Counter(re.sub(r":.*", "", r.get("detail", "")) for r in rows if r.get("ran") == "local")
        for k, v in why.most_common(8):
            print(f"     local por: {k or '(sem detalhe)'}: {v}")
    print("== mbp-run.jsonl" + (f" (desde {a.desde})" if a.desde else "") + ": recusas do preflight e execuções (insumo do aceite de carga)")
    mrows, mbad = read_jsonl(os.path.join(CITY, ".gc/logs/mbp-run.jsonl"), a.desde)
    if mrows is None:
        print("  (sem mbp-run.jsonl)")
    else:
        ref = collections.Counter(r.get("reason", "?") for r in mrows if r.get("mode") == "preflight")
        ran = sum(1 for r in mrows if r.get("mode") in ("pytest", "exec"))
        print(f"  execuções no MBP: {ran}; recusas: " + (", ".join(f"{k}={v}" for k, v in ref.most_common()) or "nenhuma"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
