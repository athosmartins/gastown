#!/usr/bin/env python3
"""hq-mutate-wa.py — varredura de MUTANTES do código do whatsapp_automation (lib/, daemons/) contra os testes pytest que o citam (ga-tmfmvxi): o resultado que alguém lê é a lista de linhas do código do WA que NENHUM teste da família pega.
## Contents
  Por quê · Uso · Alvos e família · O que roda · Conjunto de falhas · O que é herdado · Códigos de saída
POR QUÊ: o lastro do nó Hetzner (ga-2hd02v.5) já varre mutantes dos selftests do hq (hq-mutate.py). Esta é a mesma varredura para o código do WA que o wa-suite já testa: trocar UM trecho (`==` por `!=`, `and` por `or`, `<` por `<=`, `0` por `1`…) e rodar os testes
  dele; se todos passam, o mutante SOBREVIVEU e o teste é fraco naquela linha. Só o código do ESPELHO do nó (filtrado) entra: nenhum dado de lead, nenhum arquivo de fora da árvore.
USO: hq-mutate-wa.py plan  --tree WA --state ARQ [--fam-cap N] [--max-bad N]                    alvos na ordem em que a varredura os pegaria, e por que pula os que pula
     hq-mutate-wa.py gen ARQUIVO [--tree WA]                                                    candidatos de UM arquivo, TAB (id, linha, operador, antes, depois), sem os de linha de log/print
     hq-mutate-wa.py sweep --tree WA --state ARQ --work DIR --jail hq-sandbox-run.py --python PY [--fam-cap N] [--max-bad N] [--pytest-timeout N] [--budget-s N] [--slots N] [--slots-max N --slots-file ARQ] [--cap N] [--targets N] [--fsize-mb N] [--slot-mb N] [--data-mb N]
  Os argumentos de sempre (--budget-s, --slots, --cap, --targets, --fsize-mb, --slot-mb) e o resumo (a última linha do stdout, UM json) são os do hq-mutate.py: este arquivo CARREGA aquele motor (tem de estar na mesma pasta) e troca só o que é do hq:
  o plano (de onde vêm os alvos e a família) e a execução (um pytest no lugar de `bash selftest`). A varredura, os operadores, o veredito, o teto de escrita, o teto do slot, a prova da jaula e o estado são os do motor.
ALVOS E FAMÍLIA: alvo = `lib/**/*.py` e `daemons/**/*.py` (fora de tests/, crew/, archive/, venv, __pycache__, pastas `.bak`, `__init__.py`, conftest e arquivos de teste). A família do alvo `x.py` = os `tests/**/test_*.py` cujo nome é `test_x.py` ou `test_x_*.py` MAIS os que o importam
  (`import x`, `from x import …`, `from pkg import x`, `from pkg.x import …`): um sobrevivente é "nenhum destes testes pega", então a família tem de ser inteira, nunca cortada. Pulados (contados em `skipped`): sem-teste (família vazia) · familia-grande (mais de --fam-cap arquivos, 12) ·
  symlink · denylist:<trecho> (o alvo ou um teste cita sudo, systemctl, tmux, docker… — a lista do hq-mutate.py — ou os sinais de processo `os.kill`/`os.killpg`/`pthread_kill`/`raise_signal`/`psutil`: a jaula não barra sinal, e um mutante que muda o pid mataria processo do nó) · base-vermelha / base-ambiente
  (a família não passa SEM mutante dentro da jaula: sem rede, sem config/ real, HOME de mentira — é a regra do motor, o alvo volta a ser tentado em 2 dias). Candidato numa linha que abre com print( ou logger./logging./log.…( fica fora (trocar o texto de um log nunca reprova teste, só enche a lista).
O QUE RODA: por mutante, uma cópia da árvore inteira (sem .git, crew/, __pycache__, node_modules, *.bak-*) num slot, o mutante gravado nela e, DENTRO da jaula (escrita só no slot, TCP cortado, `env -i` com HOME e TMPDIR do slot): `PY -m pytest -p no:cacheprovider -p no:randomly -q -x --tb=no --timeout=N ARQUIVOS`, sob o teto de escrita por arquivo.
  rc 0 = os testes passaram = o mutante sobreviveu (confirmado por uma 2ª rodada numa cópia limpa); qualquer outro rc = morto. A baseline é a mesma linha sem mutante. PYTHONHASHSEED=0 e PYTHONDONTWRITEBYTECODE=1, como na suíte do wa-suite.
CONJUNTO DE FALHAS (ga-z137atn, --max-bad N; 0 = desligado, o padrão): sem a regra a baseline tem de dar 0, e a família com UM teste quebrado por ambiente na jaula (PermissionError, duckdb, caminho de /Users…) vira base-vermelha com TODOS os mutantes dela sem julgar (19,3 mil no WA em 06/11).
  Com a regra a baseline roda a família inteira, sem `-x` e com `--continue-on-collection-errors`, e um plugin do pytest (PLUGIN, escrito no slot e carregado com `-p wam_plug`) anota os testes que quebram e os módulos que não coletam. De 1 a N quebrados e até 5% dos testes que rodaram (20 × quebrados <= bons + quebrados), com todo
  módulo que não coletou na família, o alvo ENTRA: cada mutante roda com `-x` SEM esses testes (pelo id exato: o --deselect do pytest é por prefixo e levaria o irmão que passa) e sem esses módulos, e morre só quem faz falhar um teste que PASSAVA na baseline. Arquivo do plugin ausente ou ilegível, rc que não é 1 e quebrado demais seguem base-vermelha (nunca
  verde por falta de leitura). Os mutantes de um alvo verde, e tudo com a regra desligada, rodam a linha de sempre. O PREÇO: o teste excluído não mata, então o sobrevivente de um alvo com `excl` pode ser pego no mini por um teste que não roda aqui: o estado grava `excl` (quantos ficaram fora), o resumo diz `near_green` (alvos que a regra aceitou na varredura) e `controle_falhou` (alvos que o controle reprovou) e o
  hetzner-ballast-newfail.py marca a linha. A base-vermelha gravada sem `rule` (pelo motor antigo, ou com a regra desligada) vence na hora com a regra ligada, em vez de esperar os 2 dias; a que a regra deixou vermelha grava `rule`=1 e espera. O hash do alvo NÃO muda: os alvos já cobertos não são varridos de novo.
O QUE É HERDADO: o estado (json, `targets{arquivo: {hash, verdicts, survivors, total, skip, retry_after, swept, excl, rule}}`) é o do motor, e o hetzner-ballast-newfail.py lê o mesmo formato (`--fonte wa-mutants`). O hash do alvo é o do código + os arquivos da família (conftest.py fica de fora de propósito: muda quase todo dia
  e zeraria o estado inteiro a cada rodada).
CÓDIGOS: 0 · 2 uso · 3 estado ilegível, árvore ilegível, sem alvos, motor não carregou ou gravação que falhou · 97 jaula não provada · 143 interrompido (o estado já gravado vale). Os mesmos do hq-mutate.py.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import re
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
COPY_IGNORE = (".git", "__pycache__", "*.pyc", "crew", "node_modules", "*.bak-*")
FAM_CAP = 12
PYTEST_TMO = 120
PYTHON = ""   # o python do venv do WA (--python): só o sweep o usa
MAX_BAD = 0   # --max-bad (ga-z137atn): até quantos testes quebrados a baseline tolera e o alvo ainda entra. 0 = regra desligada: a baseline tem de dar 0, como sempre
EXCL = {}   # alvo → (hash, quantos testes e módulos ficaram fora do veredito): a baseline que a regra aceitou deixa aqui o que o estado e o resumo gravam
CTL_FAIL = set()   # alvos que a regra ia aceitar e o CONTROLE reprovou: o resumo conta (`controle_falhou`), senão a rejeição ficaria igual a «vermelho» e ninguém veria a regra anulada
RED = {}   # alvo → hash: a baseline que ficou vermelha COM a regra ligada; o estado grava rule=1 (foi julgada pela regra, não pelo «qualquer teste quebrado» de antes)
# o plugin do pytest da regra, escrito no slot (slot/plug/wam_plug.py) e carregado com `-p wam_plug`. Duas funções, uma por variável do ambiente: WAM_FAILS = arquivo onde anotar quem quebrou (baseline) e WAM_SKIP = json com os ids EXATOS que não rodam (mutante).
# Exato de propósito: o --deselect do pytest é por PREFIXO, e `test_x` também tiraria o irmão `test_x_mais` que passa (medido no pytest 9). A leitura do WAM_SKIP é do wrapper, que a grava com json.dumps na hora de lançar: não há como vir ilegível
PLUGIN = '''import json, os
# vazio (variável ausente: baseline sem a regra, ou mutante sem nada a pular) → nada é gravado e nada é tirado
_f, _s = os.environ.get("WAM_FAILS"), os.environ.get("WAM_SKIP")
_skip = set(json.loads(_s)) if _s else set()
_bad, _mods, _ok = set(), set(), [0]


def pytest_runtest_logreport(report):
    if report.failed:
        _bad.add(report.nodeid)
    elif report.when == "call" and report.passed:
        _ok[0] += 1


def pytest_collectreport(report):
    if report.failed:
        _mods.add(report.nodeid)


def pytest_collection_modifyitems(config, items):
    gone = [i for i in items if i.nodeid in _skip]
    if gone:
        config.hook.pytest_deselected(items=gone)
        items[:] = [i for i in items if i.nodeid not in _skip]


def pytest_sessionfinish(session, exitstatus):
    if _f:
        try:
            with open(_f, "w", encoding="utf-8") as fh:
                json.dump({"tests": sorted(_bad), "mods": sorted(_mods), "passed": _ok[0]}, fh)
        except OSError:
            pass   # uma gravação que falha nunca muda o desfecho do pytest: sem o arquivo a baseline continua vermelha (near_green dá None)
'''


def near_green(tgt, path):
    """{"tests": [...], "mods": [...]} (o que fica fora do veredito) se a baseline vermelha é PEQUENA, senão None: continua vermelha. Pequena = de 1 a MAX_BAD quebrados (testes + módulos que não coletam), até 5% dos testes que rodaram
    e todo módulo que não coletou é da família (um erro de conftest ou de pacote derrubaria TODO mutante: ficaria «morto» sem o código ter sido testado)"""
    # vazio (o plugin não gravou: pytest morto pelo prazo) / falhou-ilegível (não abre, não é json, falta chave, tipo errado) → None: vermelha de verdade, nunca verde por falta de leitura
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        tests, mods, passed = d["tests"], d["mods"], d["passed"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if not (isinstance(tests, list) and isinstance(mods, list) and type(passed) is int and all(isinstance(x, str) for x in tests + mods)):
        return None
    bad = len(tests) + len(mods)
    if not (0 < bad <= MAX_BAD and bad * 20 <= passed + bad and all(m in tgt["family"] for m in mods)):   # 0 quebrados com rc 1 não se explica: vermelha
        return None
    return {"tests": tests, "mods": mods}


def stale_red(old):
    """True se a base-vermelha gravada NÃO foi julgada pela regra (sem `rule`: o motor antigo, ou a regra desligada, a julgou por «qualquer teste quebrado»): com a regra ligada ela vence na hora e o alvo volta a ser tentado, em vez de esperar os 2 dias do retry_after"""
    # vazio (sem `rule`, ou 0) → não foi julgada pela regra: vence (custa uma baseline); só a base-vermelha: a base-ambiente (jaula não provada) não depende da regra
    return MAX_BAD > 0 and old.get("skip") == "base-vermelha" and not old.get("rule")


_candidates = hqm.candidates
_save_state, _summary = hqm.save_state, hqm.summary


def wa_save_state(path, state):
    """grava o estado do motor com o que a regra decidiu nesta varredura: `excl` nos alvos que ela aceitou (quantos testes e módulos da família ficaram fora do veredito: o leitor marca com isso o sobrevivente que um desses testes pode pegar no mini) e `rule`=1 nos que ela deixou
    vermelhos (foram julgados pela regra: não vencem na hora, ver stale_red). Fica depois do `ent.clear()` do motor, que zera a entrada de hash novo; sem decisão da regra nesta varredura o que já estava fica (os sobreviventes já julgados foram julgados sem aqueles testes)"""
    for rel, (h, n) in list(EXCL.items()):
        ent = state["targets"].get(rel)   # vazio (o motor ainda não abriu a entrada) → nada; hash diferente = a entrada é de outro conteúdo → nada
        if ent is not None and ent.get("hash") == h:
            ent["excl"] = n
    for rel, h in list(RED.items()):
        ent = state["targets"].get(rel)   # idem
        if ent is not None and ent.get("hash") == h:
            ent["rule"] = 1
    _save_state(path, state)


def wa_summary(result, **kw):
    """o resumo do motor (a última linha do stdout) ganha near_green = alvos que a regra aceitou nesta varredura e controle_falhou = alvos que ela ia aceitar e o controle reprovou; sem a regra o resumo é o de sempre"""
    if MAX_BAD > 0:
        kw["near_green"], kw["controle_falhou"] = len(EXCL), len(CTL_FAIL)
    _summary(result, **kw)


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
        elif old.get("skip") and now < old.get("retry_after", 0) and not stale_red(old):
            skip = old["skip"]
        elif "total" in old and len(old.get("verdicts", {})) >= old["total"]:   # total 0 (nenhum candidato) também: não há o que varrer de novo
            skip = "sem-novidade"
        else:
            skip = None
        plan.append({"rel": rel, "subject": subj, "family": fam, "hash": h, "skip": skip, "old": old,
                     "recent": recent is not None and bool(({rel} | set(fam)) & recent), "embedded": False, "swept": old.get("swept", 0)})
    plan.sort(key=lambda t: (not t["recent"], t["swept"], t["rel"]))
    return plan


def wa_exec_family(ctx, slot_n, tgt, text, tmo, ctl=None):
    """copia a árvore para o slot, grava o mutante (text=None: a baseline) e roda UM pytest com a família na jaula; (rc do pytest, segundos). O mesmo desenho do exec_family do motor, com a árvore do WA como raiz e o pytest no lugar do bash.
    Com --max-bad (ga-z137atn): a baseline roda a família INTEIRA, sem -x, e o PLUGIN anota quem quebra; uma vermelha PEQUENA (near_green) vira rc 0 e guarda tgt["excl"]. O mutante desse alvo roda sem os testes anotados (pelo id exato) e sem os módulos
    que não coletam: morre só quem faz falhar um teste que PASSAVA. Alvo sem excl, e a regra desligada, rodam a linha de sempre. `ctl` = o CONTROLE: a baseline que a regra acabou de aceitar (a exclusão), rodando de novo o código de verdade, sem mutante, com a exclusão aplicada"""
    slot = ctx.work / ("slot-%d" % slot_n)
    hqm.wipe(ctx, slot)
    (slot / "tmp").mkdir(parents=True)
    (slot / "home").mkdir()
    clone = slot / "clone"
    hqm.copy_tree(ctx.tree, clone, COPY_IGNORE)
    if text is not None:
        (clone / tgt["rel"]).write_text(text, encoding="utf-8")
    base_kb = hqm.slot_kb(slot) or 0   # vazio/falhou (du não mediu) → 0: o limite passa a valer sobre o slot inteiro, nunca sem limite
    excl = ctl or tgt.get("excl")   # vazio (alvo verde, a regra desligada, ou a própria baseline: o excl só nasce depois dela) → nenhum teste fora; só o controle e o mutante de um alvo que a regra aceitou têm excl
    base = MAX_BAD > 0 and text is None and not ctl   # a baseline da regra: família inteira, sem -x, o plugin anota
    plug = base or bool(excl and excl["tests"])   # sem teste a pular o mutante não precisa do plugin: os módulos que não coletam saem da lista de arquivos
    plugenv = []
    if plug:
        (slot / "plug").mkdir()
        (slot / "plug" / "wam_plug.py").write_text(PLUGIN, encoding="utf-8")
        plugenv = ["PYTHONPATH=%s" % (slot / "plug"), "WAM_FAILS=%s" % (slot / "plug" / "out.json") if base else "WAM_SKIP=%s" % json.dumps(excl["tests"])]
    # `env -i` DENTRO da jaula, como no motor: do ambiente de quem chama só passa PASS_ENV; HOME e TMPDIR são do slot (a jaula confere o --rw contra o HOME de verdade). PYTHONHASHSEED=0 é o da suíte do wa-suite (gt-iso-run)
    kv = ["%s=%s" % (k, os.environ[k]) for k in hqm.PASS_ENV if k in os.environ] + ["HOME=%s" % (slot / "home"), "TMPDIR=%s" % (slot / "tmp"), "PYTHONDONTWRITEBYTECODE=1", "PYTHONHASHSEED=0",
                                                                                      "GIT_AUTHOR_NAME=gt", "GIT_AUTHOR_EMAIL=gt@no", "GIT_COMMITTER_NAME=gt", "GIT_COMMITTER_EMAIL=gt@no"] + plugenv
    fam = [f for f in tgt["family"] if f not in (excl["mods"] if excl else [])]
    pytest = ([PYTHON, "-m", "pytest", "-p", "no:cacheprovider", "-p", "no:randomly"] + (["-p", "wam_plug"] if plug else []) + ["-q"] + ([] if base else ["-x"]) + ["--tb=no", "--no-header", "--timeout=%d" % PYTEST_TMO]
              + (["--continue-on-collection-errors"] if base else []) + fam)
    cmd = [sys.executable, "-I", ctx.a.jail, "--rw", str(slot), "--", "env", "-i", *kv, "timeout", "-k", "5", str(tmo), sys.executable, "-I", "-c", hqm.CAPPER, hqm.cap_arg(ctx.a), *pytest]
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
    secs = int(time.time() - t0)   # só a baseline, sem o controle abaixo: o prazo dos mutantes é 3× isto
    if base and rc == 1:   # rc 1 = testes quebrados (e módulos que não coletam: o --continue-on-collection-errors os conta); qualquer outro rc (prazo, jaula, teto, interrompido) segue como o motor o lê
        got = near_green(tgt, slot / "plug" / "out.json")
        # o CONTROLE: o código de verdade, sem mutante, com a exclusão aplicada como o mutante a terá, tem de dar 0. Um teste quebrado que deixa rastro de que outros dependem (arquivo, estado global), ou um id que não casa, deixaria a família vermelha também SEM mutante, e TODO mutante
        # "morreria" sem o código ter sido testado. rc != 0 (prazo e jaula incluídos) = o alvo continua base-vermelha. Falha de infra do controle (disco cheio) sobe e a baseline fica sem veredito
        if got is not None:
            if wa_exec_family(ctx, slot_n, tgt, None, tmo, ctl=got)[0] == 0:
                tgt["excl"], rc = got, 0
                EXCL[tgt["rel"]] = (tgt["hash"], len(got["tests"]) + len(got["mods"]))
            else:
                CTL_FAIL.add(tgt["rel"])
    if base and rc != 0:   # a regra olhou e deixou vermelha (quebrado demais, plugin sem arquivo, controle que não deu 0, prazo, jaula): o estado grava rule=1
        RED[tgt["rel"]] = tgt["hash"]
    hqm.wipe(ctx, slot)
    return rc, secs


def main(argv=None):
    global FAM_CAP, PYTEST_TMO, PYTHON, MAX_BAD
    ap = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    ap.add_argument("--python")
    ap.add_argument("--fam-cap", type=int, default=FAM_CAP)
    ap.add_argument("--pytest-timeout", type=int, default=PYTEST_TMO)
    ap.add_argument("--max-bad", type=int, default=MAX_BAD)
    mine, rest = ap.parse_known_args(sys.argv[1:] if argv is None else argv)
    if mine.fam_cap < 1 or mine.pytest_timeout < 1:   # sem família ou sem prazo por teste não há varredura
        print("hq-mutate-wa: --fam-cap e --pytest-timeout têm de ser inteiros >= 1", file=sys.stderr)
        return 2
    if mine.max_bad < 0:   # 0 desliga a regra; menos que isso não quer dizer nada
        print("hq-mutate-wa: --max-bad tem de ser um inteiro >= 0 (0 = sem a regra de conjunto de falhas)", file=sys.stderr)
        return 2
    if rest[:1] == ["sweep"] and not (mine.python and os.access(mine.python, os.X_OK)):   # sem o python do venv do WA os testes não importam nada: toda baseline sairia vermelha e o resumo diria que nada foi examinado
        print("hq-mutate-wa: sweep precisa de --python apontando para o python do venv do WA (executável)", file=sys.stderr)
        return 2
    FAM_CAP, PYTEST_TMO, PYTHON, MAX_BAD = mine.fam_cap, mine.pytest_timeout, mine.python or "", mine.max_bad
    hqm.make_plan, hqm.exec_family, hqm.candidates = wa_make_plan, wa_exec_family, wa_candidates
    hqm.save_state, hqm.summary = wa_save_state, wa_summary
    return hqm.main(rest)


if __name__ == "__main__":
    sys.exit(main())
