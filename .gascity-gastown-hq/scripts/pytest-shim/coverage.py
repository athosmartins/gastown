#!/usr/bin/env python3
"""coverage.py — quanto do pytest de workers e crews o atalho (pytest-shim.sh) alcança, e quanto foi ao MBP (ga-fl2nek).

Contents
    Por quê · Uso · O que conta

POR QUÊ: o aceite da ga-fl2nek é ">= 70% das rodadas de pytest dos workers no MBP" e o da ga-7q35xn é "a forma `venv/bin/python -m pytest` desviada". O log do atalho (pytest-shim.jsonl) só vê o que PASSOU pelo atalho; o pytest
    chamado por caminho explícito (`venv/bin/python -m pytest`) não passa pelo PATH e é invisível ali. O denominador honesto vem dos transcritos: este script conta, por
    FORMA de chamada, os comandos Bash dos workers e crews que rodaram pytest, e junta com o log do atalho e o mbp-run.jsonl.

USO:    python3 -I scripts/pytest-shim/coverage.py [--dias 14] [--desde 2026-10-14T00:00:00Z]
        --dias: janela dos transcritos (arquivos de ~/.claude/projects modificados nos últimos N dias; só as pastas de projeto cujo nome cita whatsapp-automation ou
        property-scrapers — raiz fixa, nunca varredura do $HOME). --desde: corta o log do atalho e o mbp-run.jsonl no mesmo instante (ISO com fuso, qualquer
        deslocamento: `...Z`, `...-03:00` — o corte é feito em INSTANTES, não em texto; os logs gravam UTC `...Z`). Linha de log sem ts legível não é "antes" nem
        "depois" do corte: fica fora da conta e o relatório diz quantas.

O QUE CONTA: um comando Bash com UMA forma de pytest (a primeira que casa), nesta ordem:
    mbp-run.sh                      o worker chamou o wrapper à mão (preâmbulo ga-yvs19w)
    venv/bin/python -m pytest       caminho explícito de python: NÃO passa pelo PATH. Desde a ga-7q35xn o hook venv-rewrite-hook.py a reescreve para o atalho, e o relatório
                                    separa as que o hook ALCANÇA (a mesma leitura estrutural do hook: rodada de nível de topo) das FORA do alcance (texto entre aspas, `bash -c "…"`)
    python3|python -m pytest        passa pelo atalho (stub python3/python)
    pytest solto                    passa pelo atalho (stub pytest); só em posição de comando (início, depois de ; && || | ( ou `exec`), não texto que cita pytest
    outro                           cita pytest sem rodá-lo (grep, edição de arquivo): não conta como rodada
TRANSCRITO ≠ O QUE RODOU: o transcrito guarda o comando ORIGINAL que o modelo digitou, não o que o hook reescreveu (medido ao vivo, 13/10). Por isso a contagem de venv nos
transcritos NUNCA cai depois do deploy, e a prova de que o hook agiu é o log dele ($CITY/.gc/logs/pytest-venv-rewrite.jsonl, uma linha por comando): o alcance efetivo conta as
rodadas venv até o MENOR entre "o hook alcança" (transcritos) e "o hook reescreveu" (log) — um hook inerte ou sessões velhas sem o hook não inflam o número.
Contagem de COMANDOS, não de arquivos de teste: um comando com 5 arquivos é uma rodada. É aproximação (uma linha com dois pytest conta uma vez) — serve para o
denominador do aceite, não para contabilidade.
"""
import argparse
import collections
import importlib.util
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

PROJECTS = os.path.expanduser("~/.claude/projects")
CITY = os.environ.get("GC_CITY_PATH") or "/Users/athos/gt/.gascity-gastown-hq"
VENV = "venv/bin/python -m pytest"
VENV_HOOK = VENV + " [o hook alcança]"
VENV_OUT = VENV + " [fora do alcance do hook]"
FORMS = (
    ("mbp-run.sh", re.compile(r"mbp-run\.sh")),
    ("venv/bin/python -m pytest", re.compile(r"(?:^|[\s;&|(])(?:\S*/)?(?:\.?venv[\w-]*)/bin/python[0-9.]*\s+(?:-\S+\s+)*-m\s*pytest\b")),
    ("python3|python -m pytest", re.compile(r"(?:^|[;&|(]\s*|\bexec\s+|\btimeout\s+\d+\s+|\bnice\s+(?:-n\s*\d+\s+)?|\benv\s+(?:\S+=\S+\s+)*|=\S*\s+)python3?(?:\.\d+)?\s+(?:-\S+\s+)*-m\s*pytest\b")),
    ("pytest solto", re.compile(r"(?:^|[;&|(]\s*|\bexec\s+|\btimeout\s+\d+\s+|\bnice\s+(?:-n\s*\d+\s+)?)pytest(?:\s|$)")),
)


def parse_iso(s):
    """Instante ISO-8601 COM fuso → datetime em UTC. None se não abrir ou se não tiver fuso (sem fuso a data seria lida na zona da máquina)."""
    # vazio → None; ilegível → None. Quem chama trata None como "não sei", nunca como "antes do corte" nem como "depois"
    try:
        d = datetime.fromisoformat(re.sub(r"[zZ]$", "+00:00", str(s).strip()))
    except ValueError:
        return None
    return d.astimezone(timezone.utc) if d.tzinfo is not None else None


def load_hook():
    """O módulo do hook (mesmo diretório), ou None. Com ele a leitura de "o hook alcança" é a MESMA do hook, não uma regex parecida."""
    # vazio (arquivo ausente) e ilegível (não importa) → None: o relatório diz que o alcance do hook não pôde ser medido, e conta a forma venv inteira como "fora do alcance"
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "venv-rewrite-hook.py")
    try:
        spec = importlib.util.spec_from_file_location("venv_rewrite_hook", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod if hasattr(mod, "rewrite") else None
    except Exception:
        return None


def hook_reaches(hook, cmd):
    """True se o hook reescreveria ALGUMA rodada deste comando. Sem o módulo, ou se o hook não sabe ler o comando (Bail/erro), False."""
    if hook is None:
        return False
    try:
        return bool(hook.rewrite(cmd, "/x/bin/python3")[1])
    except Exception:
        return False


def classify(cmd):
    if "pytest" not in cmd and "mbp-run" not in cmd:
        return None
    # linha a linha: um heredoc de Python que cita pytest no texto não é uma chamada
    for line in cmd.splitlines():
        for name, rx in FORMS:
            if rx.search(line):
                return name
    return "outro"


def transcripts(dias, desde=None):
    # com --desde a janela começa NESSE instante (o arquivo modificado antes dele não tem linha depois); sem, é --dias contados de agora
    cut = desde.timestamp() if desde else time.time() - dias * 86400
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


def scan(dias, desde=None, hook=None):
    """(contagem por forma, linhas de transcrito que citam pytest mas não abriram como JSON, comandos sem timestamp legível fora do corte).
    Linha ilegível não é "nenhuma rodada": é dita no relatório. Com `desde`, só entram os comandos cujo timestamp, lido como INSTANTE, é >= desde."""
    forms = collections.Counter()
    unreadable = no_ts = 0
    for _, fp in transcripts(dias, desde):
        with open(fp, errors="replace") as fh:
            for line in fh:
                if "pytest" not in line and "mbp-run" not in line:
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    unreadable += 1
                    continue
                if not isinstance(o, dict):
                    unreadable += 1
                    continue
                c = (o.get("message") or {}).get("content")
                if not isinstance(c, list):
                    continue
                for b in c:
                    if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash":
                        cmd = (b.get("input") or {}).get("command", "")
                        k = classify(cmd) if isinstance(cmd, str) else None
                        if not k:
                            continue
                        if desde:
                            # vazio (sem timestamp) ou ilegível → fora do corte e contado em no_ts; nunca "antes do corte" calado
                            t = parse_iso(o.get("timestamp", ""))
                            if t is None:
                                no_ts += 1
                                continue
                            if t < desde:
                                continue
                        if k == VENV:
                            k = VENV_HOOK if hook_reaches(hook, cmd) else VENV_OUT
                        forms[k] += 1
    return forms, unreadable, no_ts


def read_jsonl(path, desde):
    """(linhas, linhas que não abriram como objeto JSON, linhas sem ts legível fora do corte). `desde` é um instante (datetime UTC) ou None.
    Arquivo ausente → (None, 0, 0): "ainda não existe". Arquivo que existe e não abre é outra coisa — sai com erro, não vira "ainda não existe"."""
    rows, bad, no_ts = [], 0, 0
    # vazio (arquivo ausente) → None, o relatório diz "sem log"; falhou/ilegível (permissão, I/O) → sai com o erro: contagem de aceite parcial é pior que nenhuma
    try:
        with open(path) as fh:
            for line in fh:
                if not line.strip():
                    continue
                # vazio (linha em branco) → pulada acima; falhou/ilegível (não é JSON, ou JSON que não é objeto) → contada em `bad`, o relatório diz
                try:
                    r = json.loads(line)
                except ValueError:
                    bad += 1
                    continue
                if not isinstance(r, dict):
                    bad += 1
                    continue
                if desde:
                    # vazio (sem ts) ou ilegível (não abre / sem fuso) → fora da conta e contada em `no_ts`; nunca "antes do corte" calado
                    t = parse_iso(r.get("ts", ""))
                    if t is None:
                        no_ts += 1
                        continue
                    if t < desde:
                        continue
                rows.append(r)
    except FileNotFoundError:
        return None, 0, 0
    except OSError as e:
        sys.exit(f"não consegui ler {path}: {e}")
    return rows, bad, no_ts


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dias", type=int, default=14)
    ap.add_argument("--desde", default=None, help="ISO com fuso, ex.: 2026-10-14T00:00:00Z ou 2026-10-13T21:00:00-03:00")
    a = ap.parse_args(argv)
    if a.dias < 1:
        ap.error("--dias precisa ser >= 1 (0 ou negativo varreria zero transcritos e o relatório diria 0 rodadas como se fosse medida)")
    desde = None
    if a.desde is not None:
        # vazio ("") e ilegível/sem fuso → sai com erro: `--desde "$VAR"` com VAR vazia não pode virar "sem corte" calado (a contagem do aceite sairia inflada)
        desde = parse_iso(a.desde)
        if desde is None:
            sys.exit("--desde inválido ou sem fuso (ISO com fuso, ex.: 2026-10-14T00:00:00Z ou 2026-10-13T21:00:00-03:00): sem fuso a data seria lida na zona da máquina")
    # o corte que de fato vale, em UTC — é este texto que vai nos rótulos, não o que foi digitado
    cut_txt = ""
    if desde:
        cut_txt = f" (desde {desde.strftime('%Y-%m-%dT%H:%M:%SZ')}" + (f", digitado {a.desde}" if a.desde.strip() != desde.strftime("%Y-%m-%dT%H:%M:%SZ") else "") + ")"
    hook = load_hook()
    forms, unreadable, t_no_ts = scan(a.dias, desde, hook)
    runs = {k: v for k, v in forms.items() if k != "outro"}
    total = sum(runs.values())
    janela = cut_txt.strip(" ()") if desde else f"últimos {a.dias} dias"
    print(f"== rodadas de pytest nos transcritos de workers e crews ({janela}; {forms.get('outro', 0)} comandos só citam pytest e não contam)")
    for k, v in sorted(runs.items(), key=lambda x: -x[1]):
        print(f"  {v:5d}  {k}")
    if unreadable:
        print(f"  AVISO: {unreadable} linha(s) de transcrito citavam pytest mas não abriram como JSON — a contagem acima pode estar abaixo do real")
    if t_no_ts:
        print(f"  AVISO: {t_no_ts} comando(s) de pytest nos transcritos sem timestamp legível ficaram FORA do corte — a contagem acima pode estar abaixo do real")
    if hook is None:
        print("  AVISO: venv-rewrite-hook.py ausente ou ilegível ao lado deste script — o alcance do hook NÃO foi medido (a forma venv inteira conta como fora do alcance)")
    reach = runs.get("python3|python -m pytest", 0) + runs.get("pytest solto", 0)
    v_hook, v_out = runs.get(VENV_HOOK, 0), runs.get(VENV_OUT, 0)
    if total:
        print(f"  -> o atalho pelo PATH ALCANÇA {reach} de {total} ({100 * reach // total}%); forma venv/bin/python: {v_hook + v_out} ({100 * (v_hook + v_out) // total}%), das quais o hook alcança {v_hook} e {v_out} ficam fora (texto entre aspas ou forma que o hook não lê)")
    rows, bad, no_ts = read_jsonl(os.path.join(CITY, ".gc/logs/pytest-shim.jsonl"), desde)
    print("== log do atalho" + cut_txt)
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
    if no_ts:
        print(f"  AVISO: {no_ts} linha(s) do log do atalho sem ts legível ficaram FORA do corte — a contagem acima pode estar abaixo do real")
    print("== mbp-run.jsonl" + cut_txt + ": recusas do preflight e execuções (insumo do aceite de carga)")
    mrows, mbad, mno_ts = read_jsonl(os.path.join(CITY, ".gc/logs/mbp-run.jsonl"), desde)
    if mrows is None:
        print("  (sem mbp-run.jsonl)")
    else:
        ref = collections.Counter(r.get("reason", "?") for r in mrows if r.get("mode") == "preflight")
        ran = sum(1 for r in mrows if r.get("mode") in ("pytest", "exec"))
        print(f"  execuções no MBP: {ran}; recusas: " + (", ".join(f"{k}={v}" for k, v in ref.most_common()) or "nenhuma"))
        if mno_ts:
            print(f"  AVISO: {mno_ts} linha(s) do mbp-run.jsonl sem ts legível ficaram FORA do corte — a contagem acima pode estar abaixo do real")
        if mbad:
            print(f"  AVISO: {mbad} linha(s) do mbp-run.jsonl não abriram como objeto JSON")
    print("== hook venv-rewrite (log)" + cut_txt + ": a prova de que a reescrita aconteceu (o transcrito guarda o comando original)")
    hrows, hbad, hno_ts = read_jsonl(os.path.join(CITY, ".gc/logs/pytest-venv-rewrite.jsonl"), desde)
    rewrote = None if hrows is None else len(hrows)
    if rewrote is None:
        print("  (sem pytest-venv-rewrite.jsonl: o hook ainda não reescreveu nenhum comando)")
    else:
        print(f"  comandos reescritos: {rewrote}  (comandos venv que o hook alcança nos transcritos: {v_hook})")
        if hno_ts:
            print(f"  AVISO: {hno_ts} linha(s) do log do hook sem ts legível ficaram FORA do corte")
        if hbad:
            print(f"  AVISO: {hbad} linha(s) do log do hook não abriram como objeto JSON")
        if rewrote < v_hook:
            print(f"  AVISO: o hook reescreveu {rewrote} de {v_hook} comandos que alcança — sessões abertas antes do deploy (o hook só vale ao (re)nascer) ou hook inerte (`pool-preamble-build.py live`, `pytest-shim-activate.sh --check`)")
        elif rewrote > v_hook:
            print(f"  AVISO: o log tem mais reescritas ({rewrote}) que comandos venv nos transcritos ({v_hook}) — transcrito incompleto ou janela diferente")
    done_venv = min(v_hook, rewrote or 0)
    mbp_hand = runs.get("mbp-run.sh", 0)
    if total:
        eff = reach + done_venv + mbp_hand
        print(f"  -> alcance EFETIVO: {eff} de {total} ({100 * eff // total}%) = PATH {reach} + venv reescrito {done_venv} (o menor entre o que o hook alcança e o que o log prova) + mbp-run.sh à mão {mbp_hand}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
