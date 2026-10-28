#!/usr/bin/env python3
"""hq-mutate-wa.py — varredura de MUTANTES do código do whatsapp_automation (lib/, daemons/) contra os testes pytest que o citam (ga-tmfmvxi): o resultado que alguém lê é a lista de linhas do código do WA que NENHUM teste da família pega.
## Contents
  Por quê · Uso · Alvos e família · O que roda · O que é herdado · Códigos de saída
POR QUÊ: o lastro do nó Hetzner (ga-2hd02v.5) já varre mutantes dos selftests do hq (hq-mutate.py). Esta é a mesma varredura para o código do WA que o wa-suite já testa: trocar UM trecho (`==` por `!=`, `and` por `or`, `<` por `<=`, `0` por `1`…) e rodar os testes
  dele; se todos passam, o mutante SOBREVIVEU e o teste é fraco naquela linha. Só o código do ESPELHO do nó (filtrado) entra: nenhum dado de lead, nenhum arquivo de fora da árvore.
USO: hq-mutate-wa.py plan  --tree WA --state ARQ [--fam-cap N]                                  alvos na ordem em que a varredura os pegaria, e por que pula os que pula
     hq-mutate-wa.py gen ARQUIVO [--tree WA]                                                    candidatos de UM arquivo, TAB (id, linha, operador, antes, depois), sem os de linha de log/print
     hq-mutate-wa.py sweep --tree WA --state ARQ --work DIR --jail hq-sandbox-run.py --python PY [--fam-cap N] [--pytest-timeout N] [--budget-s N] [--slots N] [--cap N] [--targets N] [--fsize-mb N] [--slot-mb N]
  Os argumentos de sempre (--budget-s, --slots, --cap, --targets, --fsize-mb, --slot-mb) e o resumo (a última linha do stdout, UM json) são os do hq-mutate.py: este arquivo CARREGA aquele motor (tem de estar na mesma pasta) e troca só o que é do hq:
  o plano (de onde vêm os alvos e a família) e a execução (um pytest no lugar de `bash selftest`). A varredura, os operadores, o veredito, o teto de escrita, o teto do slot, a prova da jaula e o estado são os do motor.
ALVOS E FAMÍLIA: alvo = `lib/**/*.py` e `daemons/**/*.py` (fora de tests/, crew/, archive/, venv, __pycache__, pastas `.bak`, `__init__.py`, conftest e arquivos de teste). A família do alvo `x.py` = os `tests/**/test_*.py` cujo nome é `test_x.py` ou `test_x_*.py` MAIS os que o importam
  (`import x`, `from x import …`, `from pkg import x`, `from pkg.x import …`): um sobrevivente é "nenhum destes testes pega", então a família tem de ser inteira, nunca cortada. Pulados (contados em `skipped`): sem-teste (família vazia) · familia-grande (mais de --fam-cap arquivos, 12) ·
  symlink · denylist:<trecho> (o alvo ou um teste cita sudo, systemctl, tmux, docker… — a lista do hq-mutate.py — ou os sinais de processo `os.kill`/`os.killpg`/`pthread_kill`/`raise_signal`/`psutil`: a jaula não barra sinal, e um mutante que muda o pid mataria processo do nó) · base-vermelha / base-ambiente
  (a família não passa SEM mutante dentro da jaula: sem rede, sem config/ real, HOME de mentira — é a regra do motor, o alvo volta a ser tentado em 2 dias). Candidato numa linha que abre com print( ou logger./logging./log.…( fica fora (trocar o texto de um log nunca reprova teste, só enche a lista).
O QUE RODA: por mutante, uma cópia da árvore inteira (sem .git, crew/, __pycache__, node_modules, *.bak-*) num slot, o mutante gravado nela e, DENTRO da jaula (escrita só no slot, TCP cortado, `env -i` com HOME e TMPDIR do slot): `PY -m pytest -p no:cacheprovider -p no:randomly -q -x --tb=no --timeout=N ARQUIVOS`, sob o teto de escrita por arquivo.
  rc 0 = os testes passaram = o mutante sobreviveu (confirmado por uma 2ª rodada numa cópia limpa); qualquer outro rc = morto. A baseline é a mesma linha sem mutante. PYTHONHASHSEED=0 e PYTHONDONTWRITEBYTECODE=1, como na suíte do wa-suite.
O QUE É HERDADO: o estado (json, `targets{arquivo: {hash, verdicts, survivors, total, skip, retry_after, swept}}`) é o do motor, e o hetzner-ballast-newfail.py lê o mesmo formato (`--fonte wa-mutants`). O hash do alvo é o do código + os arquivos da família (conftest.py fica de fora de propósito: muda quase todo dia
  e zeraria o estado inteiro a cada rodada).
CÓDIGOS: 0 · 2 uso · 3 estado ilegível, árvore ilegível, sem alvos, motor não carregou ou gravação que falhou · 97 jaula não provada · 143 interrompido (o estado já gravado vale). Os mesmos do hq-mutate.py.
"""
import argparse
import hashlib
import importlib.util
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
try:   # falhou/ilegível (o hq-mutate.py não está ao lado, não abre ou não compila) → rc 3 e nada roda: sem o motor não há varredura
    _spec = importlib.util.spec_from_file_location("hq_mutate", HERE / "hq-mutate.py")
    hqm = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(hqm)
except (OSError, ImportError, SyntaxError, AttributeError) as _e:
    print("hq-mutate-wa: não carrego o motor hq-mutate.py ao lado (%s: %s)" % (type(_e).__name__, _e), file=sys.stderr)
    sys.exit(3)

SCAN_REV = 1   # entra no hash do alvo: muda quando este plano ou a regra de família mudam, e o que uma revisão velha gravou deixa de valer
SUBJECT_DIRS = ("lib", "daemons")
TEST_DIR = "tests"
SKIP_DIRS = {"tests", "crew", "archive", "venv", "node_modules", "__pycache__", "build", "dist"}
NOT_WA_SUBJECT = re.compile(r"^(?:test_|conftest|__init__\.py$|setup\.py$)|_test\.py$")
WA_DENY = re.compile(r"\bos\.kill(?:pg)?\b|\bpthread_kill\b|\braise_signal\b|\bpsutil\b")
NOISE = re.compile(r"^\s*(?:print|logger\.\w+|logging\.\w+|log\.\w+|_?log\w*)\(")
IMPORT = re.compile(r"^[ \t]*(?:from[ \t]+([\w.]+)[ \t]+import[ \t]+(\([^)]*\)|[^\n]*)|import[ \t]+([\w., \t]+))", re.M)
COPY_IGNORE = shutil.ignore_patterns(".git", "__pycache__", "*.pyc", "crew", "node_modules", "*.bak-*")
FAM_CAP = 12
PYTEST_TMO = 120
PYTHON = ""   # o python do venv do WA (--python): só o sweep o usa

_candidates = hqm.candidates


def wa_candidates(path, rel):
    """os candidatos do motor, sem os de linha de log/print: trocar o texto de uma mensagem nunca reprova teste, e o sobrevivente que isso gera só enche a lista"""
    text, cands = _candidates(path, rel)
    lines = text.splitlines()
    return text, [c for c in cands if not (0 < c["line"] <= len(lines) and NOISE.match(lines[c["line"] - 1]))]


def wa_subjects(tree):
    """os .py de lib/ e daemons/ que podem ser alvo, em ordem. vazio (pasta ausente) → nenhum daquela pasta; falhou/ilegível (pasta que não abre) → o os.walk a pula em silêncio, e a árvore sem NENHUM alvo o plano recusa"""
    out = []
    for sub in SUBJECT_DIRS:
        for dp, dns, fns in os.walk(tree / sub):
            dns[:] = sorted(d for d in dns if d not in SKIP_DIRS and not d.startswith(".") and ".bak" not in d)
            for fn in sorted(fns):
                if fn.endswith(".py") and not NOT_WA_SUBJECT.search(fn) and not hqm.NOT_SUBJECT.search(fn) and ".bak" not in fn:
                    out.append(Path(dp) / fn)
    return out


def test_index(tree):
    """({caminho relativo: bytes} dos tests/**/test_*.py, {nome: {testes que importam esse nome}}, {módulo: {testes que levam o nome dele}}). vazio (sem tests/) → índices vazios e o plano recusa; falhou/ilegível (arquivo de teste que não abre)
    → OSError sobe: o plano não sai com uma família MENOR do que a de verdade (um sobrevivente falso por teste que ficou de fora)"""
    files, imp, named = {}, {}, {}
    for dp, dns, fns in os.walk(tree / TEST_DIR):
        dns[:] = sorted(d for d in dns if d not in SKIP_DIRS - {"tests"} and not d.startswith(".") and ".bak" not in d)
        for fn in sorted(fns):
            if not (fn.startswith("test_") and fn.endswith(".py")):
                continue
            p = Path(dp) / fn
            rel = p.relative_to(tree).as_posix()
            files[rel] = p.read_bytes()
            body = fn[len("test_"):-len(".py")]
            for i in [i for i, c in enumerate(body) if not c.isalnum()] + [len(body)]:   # test_a_b.py é do módulo `a` e do `a_b`: o nome inteiro, ou o prefixo que termina antes de um não-alfanumérico
                if i:
                    named.setdefault(body[:i], set()).add(rel)
            for m in IMPORT.finditer(files[rel].decode("utf-8", "replace")):
                if m.group(3):
                    names = {w for part in m.group(3).split(",") for w in re.findall(r"\w+", part.split(" as ")[0])}
                else:
                    names = set(m.group(1).split(".")) | set(re.findall(r"\w+", m.group(2)))
                for n in names:
                    imp.setdefault(n, set()).add(rel)
    return files, imp, named


def family(stem, imp, named):
    """os testes do módulo `stem`: pelo nome (test_<stem>.py, test_<stem>_*.py) e pelos que o importam, ordenados"""
    return sorted(named.get(stem, set()) | imp.get(stem, set()))


def wa_make_plan(tree, state, recent):
    """alvos (sujeito + família) na ordem da varredura; cada um com `skip` (motivo) ou None. Levanta OSError se a árvore não abre ou não é a do WA"""
    if not (tree / TEST_DIR).is_dir() or not any((tree / d).is_dir() for d in SUBJECT_DIRS):
        raise OSError("a árvore não tem tests/ e lib/ ou daemons/ (não é a do WA)")
    files, imp, named = test_index(tree)
    subjects = wa_subjects(tree)
    if not subjects:
        raise OSError("a árvore não tem nenhum .py em lib/ ou daemons/")
    plan, now = [], time.time()
    for subj in subjects:
        rel = subj.relative_to(tree).as_posix()
        fam = family(subj.stem, imp, named)
        big = len(fam) > FAM_CAP   # família grande não roda: o conteúdo dela não entra no hash nem na busca da denylist (um stem genérico como `config` leva centenas de testes, e ler todos para cada alvo é o que travava o plano)
        blobs = [subj.read_bytes()] + ([] if big else [files[f] for f in fam])
        h = hashlib.sha1(b"\0".join(blobs + [b"\n".join(f.encode() for f in fam) if big else b""]) + b"v%d.s%d.wa%d" % (hqm.VERSION, hqm.SCAN_REV, SCAN_REV)).hexdigest()
        old = state["targets"].get(rel, {})
        old = old if old.get("hash") == h else {}
        text = "" if big or not fam else b"\n".join(blobs).decode("utf-8", "replace")
        deny = hqm.DENY_RX.search(text) or WA_DENY.search(text)
        if subj.resolve() != subj:   # symlink no arquivo ou na pasta: o motor grava o mutante FORA da jaula e a cópia guarda o link, o mutante iria ao arquivo de verdade
            skip = "symlink"
        elif not fam:
            skip = "sem-teste"
        elif big:
            skip = "familia-grande"
        elif deny:
            skip = "denylist:" + deny.group(0)
        elif old.get("skip") and now < old.get("retry_after", 0):
            skip = old["skip"]
        elif "total" in old and len(old.get("verdicts", {})) >= old["total"]:   # total 0 (nenhum candidato) também: não há o que varrer de novo
            skip = "sem-novidade"
        else:
            skip = None
        plan.append({"rel": rel, "subject": subj, "family": fam, "hash": h, "skip": skip, "old": old,
                     "recent": recent is not None and bool(({rel} | set(fam)) & recent), "embedded": False, "swept": old.get("swept", 0)})
    plan.sort(key=lambda t: (not t["recent"], t["swept"], t["rel"]))
    return plan


def wa_exec_family(ctx, slot_n, tgt, text, tmo):
    """copia a árvore para o slot, grava o mutante (text=None: a baseline) e roda UM pytest com a família na jaula; (rc do pytest, segundos). O mesmo desenho do exec_family do motor, com a árvore do WA como raiz e o pytest no lugar do bash"""
    slot = ctx.work / ("slot-%d" % slot_n)
    hqm.wipe(ctx, slot)
    (slot / "tmp").mkdir(parents=True)
    (slot / "home").mkdir()
    clone = slot / "clone"
    shutil.copytree(ctx.tree, clone, symlinks=True, ignore=COPY_IGNORE)
    if text is not None:
        (clone / tgt["rel"]).write_text(text, encoding="utf-8")
    base_kb = hqm.slot_kb(slot) or 0   # vazio/falhou (du não mediu) → 0: o limite passa a valer sobre o slot inteiro, nunca sem limite
    # `env -i` DENTRO da jaula, como no motor: do ambiente de quem chama só passa PASS_ENV; HOME e TMPDIR são do slot (a jaula confere o --rw contra o HOME de verdade). PYTHONHASHSEED=0 é o da suíte do wa-suite (gt-iso-run)
    kv = ["%s=%s" % (k, os.environ[k]) for k in hqm.PASS_ENV if k in os.environ] + ["HOME=%s" % (slot / "home"), "TMPDIR=%s" % (slot / "tmp"), "PYTHONDONTWRITEBYTECODE=1", "PYTHONHASHSEED=0",
                                                                                      "GIT_AUTHOR_NAME=gt", "GIT_AUTHOR_EMAIL=gt@no", "GIT_COMMITTER_NAME=gt", "GIT_COMMITTER_EMAIL=gt@no"]
    pytest = [PYTHON, "-m", "pytest", "-p", "no:cacheprovider", "-p", "no:randomly", "-q", "-x", "--tb=no", "--no-header", "--timeout=%d" % PYTEST_TMO, *tgt["family"]]
    cmd = [sys.executable, "-I", ctx.a.jail, "--rw", str(slot), "--", "env", "-i", *kv, "timeout", "-k", "5", str(tmo), sys.executable, "-I", "-c", hqm.CAPPER, str(ctx.a.fsize_mb << 20), *pytest]
    t0 = time.time()
    p = subprocess.Popen(cmd, cwd=clone, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    with ctx.lock:
        ctx.pids.add(p.pid)
    try:
        rc = hqm.wait_capped(ctx, p, slot, base_kb, tmo + 30)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        rc = p.wait()
    finally:
        with ctx.lock:
            ctx.pids.discard(p.pid)
    hqm.wipe(ctx, slot)
    return rc, int(time.time() - t0)


def main(argv=None):
    global FAM_CAP, PYTEST_TMO, PYTHON
    ap = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    ap.add_argument("--python")
    ap.add_argument("--fam-cap", type=int, default=FAM_CAP)
    ap.add_argument("--pytest-timeout", type=int, default=PYTEST_TMO)
    mine, rest = ap.parse_known_args(sys.argv[1:] if argv is None else argv)
    if mine.fam_cap < 1 or mine.pytest_timeout < 1:   # sem família ou sem prazo por teste não há varredura
        print("hq-mutate-wa: --fam-cap e --pytest-timeout têm de ser inteiros >= 1", file=sys.stderr)
        return 2
    if rest[:1] == ["sweep"] and not (mine.python and os.access(mine.python, os.X_OK)):   # sem o python do venv do WA os testes não importam nada: toda baseline sairia vermelha e o resumo diria que nada foi examinado
        print("hq-mutate-wa: sweep precisa de --python apontando para o python do venv do WA (executável)", file=sys.stderr)
        return 2
    FAM_CAP, PYTEST_TMO, PYTHON = mine.fam_cap, mine.pytest_timeout, mine.python or ""
    hqm.make_plan, hqm.exec_family, hqm.candidates = wa_make_plan, wa_exec_family, wa_candidates
    return hqm.main(rest)


if __name__ == "__main__":
    sys.exit(main())
