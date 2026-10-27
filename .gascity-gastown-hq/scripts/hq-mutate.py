#!/usr/bin/env python3
"""hq-mutate.py — varredura de MUTANTES do código que os *.selftest.sh do hq cobrem (ga-2hd02v.5.6.2): o resultado que alguém lê é a lista de testes que NÃO pegam um bug.

## Contents
  Por quê · Uso · Alvos · Operadores · Veredito · Estado · Códigos de saída

POR QUÊ: um selftest verde com o código quebrado não prova nada. Trocar UM trecho do script (um `-gt` por `-ge`, um `&&` por `||`, um `exit 1` por `exit 0`) e rodar a família de selftests dele diz se algum
  reprova; se nenhum reprova, o mutante SOBREVIVEU e o teste é fraco naquela linha. É trabalho de CPU que o lastro do nó Hetzner pode gastar com nice 19 sem custo, e cada achado vira um bead (ga-2hd02v.5.6).
USO: hq-mutate.py gen ARQUIVO [--tree HQ]                  imprime os candidatos (id, linha, operador, antes, depois), um por linha, TAB; com --tree o id é o que o `sweep` grava (caminho relativo à árvore)
     hq-mutate.py plan  --tree HQ --state ARQ              imprime os alvos na ordem em que a varredura os pegaria (e por que pula os que pula)
     hq-mutate.py sweep --tree HQ --state ARQ --work DIR --jail hq-sandbox-run.py [--budget-s N] [--slots N] [--cap N] [--targets N]
  A última linha do stdout do `sweep` é UM json: result (completo | parcial | sem-novidade | sem-cobertura | interrompido | sem-jaula | sem-alvos | estado-ilegivel | gravacao-falhou), contagens, skipped{motivo: n}, survivors[] (até 15; `survivors_cortados` conta os que ficaram de fora).
  `sem-novidade` = o que havia para varrer JÁ estava coberto e igual; `sem-cobertura` = nada foi examinado (tudo pulado, ou nenhum mutante rodou): quem lê só o result não pode confundir os dois. `nao_sei` conta os alvos em que o
  `bash -n` não pôde decidir: nenhum veredito, o resto do alvo espera a próxima varredura. `restam` = candidatos já conhecidos e ainda sem veredito (um --cap que fecha como `completo` deixa `restam` > 0).
ALVOS: o SUJEITO de cada `X.selftest.sh` de scripts/ e de packs/town-deltas/assets/ é o `X.sh` ou `X.py` da mesma pasta (com o nome aparado, `a-b-c` → `a-b`, até 3 vezes) E o selftest tem de CITAR o
  nome do arquivo (sem isso o sujeito é outro e todo mutante sobreviveria: ruído). A FAMÍLIA do sujeito são todos os selftests que caem nele; todos rodam a cada mutante. Nunca se mutam os arquivos do
  lastro (hetzner-ballast*), do próprio motor (hq-mutate*) nem da jaula (hq-sandbox-run*). Alvo cujo texto (sujeito + família) cita sudo, systemctl, pkill, docker, gc, bd, dolt (os três só se existem
  neste host e não são o symlink do remote-shim, o atalho do nó Hetzner) etc. é PULADO como `denylist:<palavra>`: o Landlock não barra sinal nem socket unix. A denylist lê o texto do sujeito e da família, não os scripts que eles chamam: o risco que sobra é o de um mutante de UM token de código que a bateria hq-selftests do lastro já roda sem jaula. Baseline (a família sem mutante) que não dá 0 pula o alvo (`base-vermelha`, `base-ambiente` se 97) por 2 dias.
OPERADORES: no shell só entre tokens soltos (um scanner com pilha passa por aspas, `$( )` e `$(( ))`, comentário e corpo de heredoc: nada em string ou heredoc é mutado; o código de um `$( )` solto sim, o de um `"$( )"` entre aspas duplas não: fica sem mutar, nunca mutado errado); no python pelos
  tokens (`tokenize`). Se o scanner de shell TERMINA com aspa, `$(` ou heredoc aberto ele se perdeu (o `bash -n` aceita esses arquivos) e a lista que ele deu é incompleta: o alvo é pulado como `scan-perdido` (a linha em
  que a construção abriu vai em `perdidos` e no estado), nunca contado como coberto. Mutante que não compila (`bash -n`, `compile()`) é `invalid` e não gasta a cota; se o `bash -n` nem pôde rodar (sem bash, preso, morto
  por sinal) não se sabe: `nao_sei`. Id estável = sha1(arquivo:linha:operador:antes>depois:ocorrência), com o caminho relativo à árvore.
VEREDITO: morto = algum selftest da família saiu != 0 (prazo e 97 incluídos) · sobrevivente = todos 0; roda DE NOVO numa cópia limpa: se a 2ª reprova é `flaky` (não se reporta), senão `confirmed`.
  Execução cortada pelo TERM NÃO é veredito (o rc dela é do sinal, não de um teste): nada se grava e o mutante roda de novo na próxima varredura.
  Cada mutante roda numa CÓPIA da árvore dentro da jaula (--rw só a pasta do slot, HOME e TMPDIR descartáveis, ambiente limpo: `env -i` e só PATH, LANG, LC_*, USER); a jaula é PROVADA antes de qualquer mutante (`--prove`): sem prova, rc 97 e nada roda.
ESTADO (--state, json, trocado por arquivo temporário): por alvo o hash do conteúdo (e da revisão do scanner), o veredito de cada id, os sobreviventes e a data. Hash igual e tudo coberto = `sem-novidade` (varrer de
  novo o mesmo conteúdo seria queima disfarçada). Ordem: alvos com arquivo mudado nos últimos 7 dias (git log), depois selftests SEM mutante embutido, depois o menos recente. --cap limita os mutantes por alvo por
  varredura. O motor NÃO trava o --state: garantir UM sweep por vez por --state é de quem chama (dois ao mesmo tempo = o último a gravar vence). Estado que lê mas tem forma errada = estado-ilegivel (rc 3).
CÓDIGOS: 0 · 2 uso · 3 estado ilegível/corrompido (NUNCA se zera), árvore ilegível, sem alvos ou gravação que falhou · 97 jaula não provada · 143 interrompido (o estado já gravado vale).
"""
import argparse
import hashlib
import io
import itertools
import json
import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import tokenize
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

VERSION = 1
SCAN_REV = 2   # entra no hash do alvo: muda quando o scanner ou a regra de veredito mudam, e o que uma revisão velha gravou deixa de valer
SELFTEST_DIRS = ("scripts", "packs/town-deltas/assets")
NOT_SUBJECT = re.compile(r"^(hetzner-ballast|hq-mutate|hq-sandbox-run)|\.selftest\.|\.mutants\.")
EMBEDDED = re.compile(r"\bp?mut\b|[Mm]utante|MUT_")
SKIP_S = 2 * 86400
DENY = r"\b(?:sudo|doas|systemctl|launchctl|pkill|killall|osascript|docker|podman|tmux|ssh-add|busctl|dbus-send|socat|gt-netns-run|gt-iso-run)\b|git push|\bkill\b[^\n]*\s-1\b|--unix-socket|\bnc\s+-U"
PASS_ENV = ("PATH", "LANG", "LC_ALL", "LC_CTYPE", "USER", "LOGNAME")
MAX_LINE = 6000
SHIMS = ("remote-shim", "remote-shim.py")


def real_bins():
    # gc, bd e dolt só são perigo quando são o programa de verdade. No nó Hetzner `gc` e `bd` são symlinks para o remote-shim (ssh ao mini): na jaula o TCP está cortado e o HOME é descartável (sem shim.json o shim sai 78 antes de qualquer ssh)
    return [b for b in ("gc", "bd", "dolt") if shutil.which(b) and os.path.basename(os.path.realpath(shutil.which(b))) not in SHIMS]


DENY_RX = re.compile(DENY + "".join(r"|\b%s\b" % b for b in real_bins()))

HEREDOC = re.compile(r"<<(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z_0-9]*)\2")
CMP = r"(?<=\s)(-lt|-le|-gt|-ge)(?=\s)"
SH_OPS = (  # (operador, regex com o trecho a trocar no grupo 1, troca, contexto exigido antes do trecho)
    ("eq-ne", r"(?<=\s)(-eq|-ne)(?=\s)", {"-eq": "-ne", "-ne": "-eq"}, None),
    ("cmp-neg", CMP, {"-lt": "-ge", "-ge": "-lt", "-gt": "-le", "-le": "-gt"}, None),
    ("cmp-lim", CMP, {"-lt": "-le", "-le": "-lt", "-gt": "-ge", "-ge": "-gt"}, None),
    ("num+1", r"(?<=\s)-(?:eq|ne|lt|le|gt|ge) (\d+)(?=\s)", lambda s: str(int(s) + 1), None),
    ("str-eq", r"(?<=\s)(==|=|!=)(?=\s)", {"==": "!=", "=": "!=", "!=": "="}, r"\[|\btest\b"),
    ("z-n", r"\[\[? (?:! )?(-[zn])(?= )", {"-z": "-n", "-n": "-z"}, None),
    ("and-or", r"(&&|\|\|)", {"&&": "||", "||": "&&"}, None),
    ("neg-if", r"\b(?:if|elif|while|until) (! )", lambda s: "", None),
    ("neg-if", r"\b(?:if|elif|while|until) ()(?=[^!\s])", lambda s: "! ", None),
    ("neg-test", r"(?:^|&&|\|\|) *\[\[? (! )", lambda s: "", None),
    ("neg-test", r"(?:^|&&|\|\|) *\[\[? ()(?=[^!\s])", lambda s: "! ", None),
    ("exit-rc", r"\b(?:exit|return) (\d+)\b", lambda s: "1" if s == "0" else "0", None),
    ("sem-exit", r"( \|\| (?:exit|return)(?: \d+)?)(?= *(?:$|[;)}&#]))", lambda s: "", None),
)
PY_SWAP = {"==": "!=", "!=": "==", "<": ">=", ">": "<=", "<=": ">", ">=": "<", "and": "or", "or": "and", "True": "False", "False": "True"}
PY_LIM = {"<": "<=", "<=": "<", ">": ">=", ">=": ">"}


class Lost(ValueError):
    """o scanner de shell acabou o arquivo com aspas, $( ) ou heredoc abertos: perdeu o fio, e o que sobrou de candidatos não vale"""


def sh_masks(lines):
    """uma máscara por linha: True onde há CÓDIGO (fora de aspas, de comentário e do corpo de heredoc). Levanta Lost se o arquivo acaba com algo aberto"""
    st = [["cmd", 0, 0]]   # pilha [tipo, parênteses abertos, linha onde abriu]: cmd (código) · sub (dentro de $( )) · dq · sq · ansi ($'..': a barra escapa)
    here, out = None, []
    for n, line in enumerate(lines, 1):
        mask = [False] * len(line)
        out.append(mask)
        if here:
            if (line.lstrip("\t") if here[1] else line).rstrip("\n") == here[0]:
                here = None
            continue
        i = 0
        while i < len(line):
            c, top = line[i], st[-1]
            k = top[0]
            if k == "sq":
                if c == "'":
                    st.pop()
            elif k in ("dq", "ansi"):
                if c == "\\":
                    i += 1
                elif c == ('"' if k == "dq" else "'"):
                    st.pop()
                elif k == "dq" and line.startswith("$(", i):
                    st.append(["sub", 0, n])
                    i += 1
            elif c == "\\":
                i += 1
            elif c == "'":
                st.append(["ansi" if line[i - 1:i] == "$" else "sq", 0, n])
            elif c == '"':
                st.append(["dq", 0, n])
            elif c == "$" and line.startswith("$(", i):
                st.append(["sub", 0, n])
                i += 1
            elif k == "sub" and c in "()":
                if c == "(" or top[1]:
                    top[1] += 1 if c == "(" else -1
                else:
                    st.pop()
            elif c == "#" and (i == 0 or line[i - 1] in " \t;&|()"):
                break
            else:
                # `<<` dentro de aritmética ($(( 1 << n )), (( x << 2 ))) é deslocamento, não heredoc; `<<<` é here-string (o 2º `<` dele não abre heredoc)
                m = HEREDOC.match(line, i) if line.startswith("<<", i) and line[i - 1:i] != "<" and not (k == "sub" and top[1]) and line[:i].count("((") <= line[:i].count("))") else None
                if m:
                    here = (m.group(3), m.group(1) == "-", n)
                    i = m.end()
                    continue
                mask[i] = all(e[0] in ("cmd", "sub") for e in st)
            i += 1
    if here or len(st) > 1:
        raise Lost("scanner perdido: %s aberto no fim do arquivo (desde a linha %d)" % (("heredoc", here[2]) if here else (st[-1][0], st[-1][2])))
    return out


def sh_raw(text):
    out, off = [], 0
    lines = text.splitlines(keepends=True)
    for n, (line, mask) in enumerate(zip(lines, sh_masks(lines)), 1):
        for op, rx, rep, ctx in SH_OPS:
            for m in re.finditer(rx, line):
                s, e = m.span(1)
                lo, hi = (s, e) if e > s else (s - 1, s)   # inserção: vale o espaço antes dela (o que vem depois pode ser a aspa que abre um argumento)
                if not all(mask[max(lo, 0):hi]) or (ctx and not re.search(ctx, line[:s])):
                    continue
                old = m.group(1)
                out.append((n, op, off + s, off + e, old, rep[old] if isinstance(rep, dict) else rep(old)))
        off += len(line)
    return out


def py_raw(text):
    offs = [0]
    for line in io.StringIO(text).readlines():
        offs.append(offs[-1] + len(line))
    out = []
    for t in tokenize.generate_tokens(io.StringIO(text).readline):
        (r, c), (r2, c2) = t.start, t.end
        if r != r2:
            continue
        s, e, w = offs[r - 1] + c, offs[r - 1] + c2, t.string
        if t.type in (tokenize.OP, tokenize.NAME) and w in PY_SWAP:
            out.append((r, "swap", s, e, w, PY_SWAP[w]))
        if t.type == tokenize.OP and w in PY_LIM:
            out.append((r, "lim", s, e, w, PY_LIM[w]))
        if t.type == tokenize.NAME and w == "not":
            out.append((r, "sem-not", s, e, w, ""))
        if t.type == tokenize.NUMBER and w.isdigit():
            out.append((r, "num", s, e, w, "1" if w == "0" else "0" if w == "1" else str(int(w) + 1)))
    return out


def candidates(path, rel):
    """(texto, candidatos ordenados por id). Levanta se o arquivo não abre ou não tokeniza: quem chama conta como `ilegivel`, nunca como zero candidatos"""
    text = path.read_text(encoding="utf-8")
    seen, out = {}, []
    for line, op, s, e, old, new in (sh_raw(text) if path.suffix == ".sh" else py_raw(text)):
        if old == new:
            continue
        key = "%s:%d:%s:%s>%s" % (rel, line, op, old, new)
        seen[key] = seen.get(key, 0) + 1
        mid = hashlib.sha1(("%s:%d" % (key, seen[key])).encode()).hexdigest()[:10]
        out.append({"id": mid, "line": line, "op": op, "old": old, "new": new, "s": s, "e": e})
    return text, sorted(out, key=lambda m: m["id"])


def valid(path, text):
    """True compila · False não compila · None não deu para saber (sem bash, bash preso): não roda, não grava veredito (a próxima varredura tenta) e o resumo conta em nao_sei"""
    if path.suffix == ".py":
        try:
            compile(text, str(path), "exec")
            return True
        except (SyntaxError, ValueError):
            return False
    try:
        rc = subprocess.run(["bash", "-n"], input=text, capture_output=True, text=True, timeout=30).returncode
    except (OSError, subprocess.TimeoutExpired):
        return None
    return True if rc == 0 else False if rc in (1, 2) else None


def find_subject(d, stem, text):
    cand = stem
    for _ in range(4):
        for ext in (".sh", ".py"):
            name = cand + ext
            if (d / name).is_file() and not NOT_SUBJECT.search(name) and re.search(r"(?<![\w.-])" + re.escape(name) + r"(?![\w-])", text):
                return d / name
        trimmed = re.sub(r"[-.][^-.]+$", "", cand)
        if trimmed == cand:
            break
        cand = trimmed
    return None


def complete(ent):
    """o alvo tem mutantes (total > 0) e todos já têm veredito"""
    return ent.get("total", 0) > 0 and len(ent.get("verdicts", {})) >= ent["total"]


def make_plan(tree, state, recent):
    """alvos (sujeito + família) na ordem da varredura; cada um com `skip` (motivo) ou None. Levanta OSError se a árvore não abre"""
    if not (tree / "scripts").is_dir():
        raise OSError("a árvore não tem scripts/")
    fam = {}
    for sub in SELFTEST_DIRS:
        d = tree / sub
        for st in sorted(d.glob("*.selftest.sh")) if d.is_dir() else []:
            subj = find_subject(d, st.name[:-len(".selftest.sh")], st.read_text(encoding="utf-8", errors="replace"))
            if subj:
                fam.setdefault(subj, []).append(st)
    plan, now = [], time.time()
    for subj, sts in fam.items():
        rel = subj.relative_to(tree).as_posix()
        names = [s.relative_to(tree).as_posix() for s in sts]
        blobs = [subj.read_bytes()] + [s.read_bytes() for s in sts]
        h = hashlib.sha1(b"\0".join(blobs) + b"v%d.s%d" % (VERSION, SCAN_REV)).hexdigest()
        text = b"\n".join(blobs).decode("utf-8", "replace")
        fam_text = b"\n".join(blobs[1:]).decode("utf-8", "replace")
        old = state["targets"].get(rel, {})
        old = old if old.get("hash") == h else {}
        deny = DENY_RX.search(text)
        if deny:
            skip = "denylist:" + deny.group(0)
        elif old.get("skip") and now < old.get("retry_after", 0):
            skip = old["skip"]
        elif "total" in old and len(old.get("verdicts", {})) >= old["total"]:   # total 0 (nenhum candidato) também: não há o que varrer de novo
            skip = "sem-novidade"
        else:
            skip = None
        plan.append({"rel": rel, "subject": subj, "family": names, "hash": h, "skip": skip, "old": old,
                     "recent": recent is not None and bool(({rel} | set(names)) & recent), "embedded": bool(EMBEDDED.search(fam_text)),
                     "swept": old.get("swept", 0)})
    plan.sort(key=lambda t: (not t["recent"], t["embedded"], t["swept"], t["rel"]))
    return plan


def git_recent(tree):
    """arquivos (relativos à árvore) mudados nos últimos 7 dias; None se o git não responde (a ordem então não conta com isso e o resumo diz `indisponivel`)"""
    try:
        r = subprocess.run(["git", "-C", str(tree), "log", "--since=7.days.ago", "--name-only", "--pretty=format:", "--relative"], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return {l for l in r.stdout.split("\n") if l} if r.returncode == 0 else None


def shaped(e):
    return (isinstance(e, dict) and isinstance(e.get("verdicts", {}), dict) and isinstance(e.get("survivors", {}), dict) and isinstance(e.get("skip", ""), str)
            and isinstance(e.get("total", 0), int) and isinstance(e.get("retry_after", 0), (int, float)) and isinstance(e.get("swept", 0), (int, float)))


def load_state(p):
    try:
        d = json.loads(Path(p).read_text(encoding="utf-8"))
        if d["v"] != VERSION or not isinstance(d["targets"], dict) or not all(shaped(e) for e in d["targets"].values()):
            raise ValueError("versão ou forma do estado desconhecida")
        return d
    except FileNotFoundError:
        return {"v": VERSION, "targets": {}}


def save_state(p, state):
    tmp = Path(str(p) + ".tmp")
    tmp.write_text(json.dumps(state, sort_keys=True), encoding="utf-8")
    os.replace(tmp, p)


class Ctx:
    def __init__(self, a, tree):
        self.a, self.tree, self.root = a, tree, tree.parent
        self.work = Path(a.work).resolve()
        self.slots = queue.Queue()
        for i in range(a.slots):
            self.slots.put(i)
        self.stop, self.pids, self.lock = threading.Event(), set(), threading.Lock()
        self.deadline = time.time() + a.budget_s


def wipe(ctx, p):
    if p.exists():
        if ctx.work not in p.resolve().parents:
            raise RuntimeError("recuso apagar fora do --work: %s" % p)
        subprocess.run(["chmod", "-R", "u+rwX", str(p)], capture_output=True)
        shutil.rmtree(p, ignore_errors=True)


def exec_family(ctx, slot_n, tgt, text, tmo):
    """copia a árvore para o slot, grava o mutante (text=None: a baseline) e roda a família na jaula; (rc do 1º selftest que não deu 0, ou 0; segundos)"""
    slot = ctx.work / ("slot-%d" % slot_n)
    wipe(ctx, slot)
    (slot / "tmp").mkdir(parents=True)
    (slot / "home").mkdir()
    clone = slot / "clone"
    shutil.copytree(ctx.root, clone, symlinks=True, ignore=shutil.ignore_patterns(".git"))
    cd = clone / ctx.tree.relative_to(ctx.root)
    if text is not None:
        (cd / tgt["rel"]).write_text(text, encoding="utf-8")
    # o HOME de mentira vai por `env` DENTRO da jaula: a jaula confere o --rw contra o HOME de VERDADE, e um slot que contém o HOME de mentira seria pai dele e recusado (rc 64 = baseline vermelha em tudo)
    # `env -i`: do ambiente do motor só passa PASS_ENV. SSH_AUTH_SOCK, TMUX, DBUS_*, XDG_RUNTIME_DIR, REMOTE_SHIM_CONF e tokens ficam de fora: o Landlock não barra socket unix nem sinal, então o mutante não pode herdar o endereço de nenhum
    kv = ["%s=%s" % (k, os.environ[k]) for k in PASS_ENV if k in os.environ] + ["HOME=%s" % (slot / "home"), "TMPDIR=%s" % (slot / "tmp"), "PYTHONDONTWRITEBYTECODE=1", "GIT_AUTHOR_NAME=gt", "GIT_AUTHOR_EMAIL=gt@no", "GIT_COMMITTER_NAME=gt", "GIT_COMMITTER_EMAIL=gt@no"]
    t0, rc = time.time(), 0
    for st in tgt["family"]:
        cmd = [sys.executable, "-I", ctx.a.jail, "--rw", str(slot), "--", "env", "-i", *kv, "timeout", "-k", "5", str(tmo), "bash", st]
        p = subprocess.Popen(cmd, cwd=cd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        with ctx.lock:
            ctx.pids.add(p.pid)
        try:
            rc = p.wait(timeout=tmo + 30)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            rc = p.wait()
        finally:
            with ctx.lock:
                ctx.pids.discard(p.pid)
        if rc != 0:
            break
    wipe(ctx, slot)
    return rc, int(time.time() - t0)


def run_slot(ctx, tgt, text, tmo):
    """(rc, segundos), ou None se o TERM chegou antes ou durante a execução: o rc que sobra (-9 do killpg) é do sinal, não de um teste, e não vira veredito"""
    slot_n = ctx.slots.get()
    try:
        r = None if ctx.stop.is_set() else exec_family(ctx, slot_n, tgt, text, tmo)
        return None if ctx.stop.is_set() else r
    finally:
        ctx.slots.put(slot_n)


def one_mutant(ctx, tgt, text, m):
    """k morto · s sobrevivente confirmado · f flaky · None não rodou (prazo da varredura ou TERM no meio): nenhum veredito se grava. O mutante já passou no valid() ao ser escolhido"""
    if ctx.stop.is_set() or time.time() > ctx.deadline:
        return None
    mutated = text[:m["s"]] + m["new"] + text[m["e"]:]
    r1 = run_slot(ctx, tgt, mutated, tgt["tmo"])
    if r1 is None or r1[0] != 0:
        return None if r1 is None else "k"
    r2 = run_slot(ctx, tgt, mutated, tgt["tmo"])
    return None if r2 is None else "s" if r2[0] == 0 else "f"


def on_term(ctx):
    def handler(*_):
        ctx.stop.set()
        for pid in list(ctx.pids):
            try:
                os.killpg(pid, signal.SIGKILL)
            except OSError:
                pass   # já saiu
    return handler


def summary(result, **kw):
    # o puxador do lastro troca por null uma linha de resumo de mais de ~8000 caracteres: os sobreviventes que não cabem saem da linha (ficam no estado) e a linha diz quantos cortou
    if "survivors" in kw:
        kw["survivors_cortados"] = max(0, len(kw["survivors"]) - 15)
        kw["survivors"] = kw["survivors"][:15]
    line = json.dumps(dict(result=result, **kw), sort_keys=True)
    while len(line) > MAX_LINE and kw.get("survivors"):
        kw["survivors"] = kw["survivors"][:-1]
        kw["survivors_cortados"] += 1
        line = json.dumps(dict(result=result, **kw), sort_keys=True)
    print(line, flush=True)


def prove(a):
    """(linha da prova, motivo): a linha só vem se a jaula FOI provada (rc 0 do --prove); sem ela nada roda"""
    if not Path(a.work).is_dir():
        return None, "o --work não existe"
    try:
        r = subprocess.run([sys.executable, "-I", a.jail, "--prove", "--rw", str(Path(a.work).resolve())], capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, type(e).__name__
    return (r.stdout.strip() if r.returncode == 0 else None), (r.stdout + r.stderr).strip()


def sweep(a):
    tree = Path(a.tree).resolve()
    if tree.parent == Path(a.work).resolve() or tree.parent in Path(a.work).resolve().parents:
        print("hq-mutate: o --work não pode ficar dentro da árvore que se copia", file=sys.stderr)
        return 2
    proof, why = prove(a)
    if proof is None:
        summary("sem-jaula", jail=why[:160])
        return 97
    try:
        state = load_state(a.state)
    except (OSError, ValueError, KeyError, TypeError) as e:
        summary("estado-ilegivel", erro="%s: %s" % (type(e).__name__, e)[:160])
        return 3
    recent = git_recent(tree)
    try:
        plan = make_plan(tree, state, recent)
    except OSError as e:
        summary("sem-alvos", erro=str(e)[:160])
        return 3
    if not plan:
        summary("sem-alvos", erro="nenhum selftest com sujeito")
        return 3
    ctx = Ctx(a, tree)
    signal.signal(signal.SIGTERM, on_term(ctx))
    t0, skipped, n = time.time(), {}, dict(run=0, killed=0, survived=0, confirmed=0, flaky=0, invalid=0, swept=0, unknown=0)
    new_surv, lost = [], []
    for t in [t for t in plan if t["skip"]]:
        skipped[t["skip"].split(":")[0]] = skipped.get(t["skip"].split(":")[0], 0) + 1
    todo = [t for t in plan if not t["skip"]]
    err = None
    for i in range(0, len(todo), max(2, a.targets)):
        if ctx.stop.is_set() or time.time() > ctx.deadline:
            break
        batch = todo[i:i + max(2, a.targets)]
        with ThreadPoolExecutor(a.slots) as ex:
            base = list(ex.map(lambda t: run_slot(ctx, t, None, 900), batch))
        if ctx.stop.is_set():
            break
        jobs = []
        for t, (rc, secs) in zip(batch, base):
            ent = state["targets"].setdefault(t["rel"], {})
            if ent.get("hash") != t["hash"]:
                ent.clear()
                ent["hash"] = t["hash"]
            ent["swept"] = int(time.time())
            if rc != 0:
                reason = "base-ambiente" if rc == 97 else "base-vermelha"
                skipped[reason] = skipped.get(reason, 0) + 1
                ent.update(skip=reason, retry_after=int(time.time()) + SKIP_S)
                continue
            ent.pop("skip", None)
            t["tmo"] = min(900, max(60, 3 * secs))
            try:
                text, cands = candidates(t["subject"], t["rel"])
            except (OSError, ValueError, SyntaxError, tokenize.TokenError) as e:
                why = "scan-perdido" if isinstance(e, Lost) else "ilegivel"   # perdido: o arquivo abre, mas os candidatos que o scanner deu não valem; o resumo diz onde
                skipped[why] = skipped.get(why, 0) + 1
                ent.update(skip=why, retry_after=int(time.time()) + SKIP_S, perdido=str(e)[:160])
                if why == "scan-perdido":
                    lost.append("%s: %s" % (t["rel"], e))
                continue
            ent["total"] = len(cands)
            ver = ent.setdefault("verdicts", {})
            ent.setdefault("survivors", {})
            pick = []
            for m in (c for c in cands if c["id"] not in ver):
                if len(pick) >= a.cap:
                    break
                ok = valid(t["subject"], text[:m["s"]] + m["new"] + text[m["e"]:])
                if ok:
                    pick.append(m)
                elif ok is None:
                    n["unknown"] += 1   # sem veredito e sem insistir (um bash preso custa 30 s por candidato): o alvo não fecha e a próxima varredura tenta de novo
                    break
                else:
                    ver[m["id"]] = "i"
                    n["invalid"] += 1
            n["swept"] += 1
            jobs.append([(t, text, m) for m in pick])
        order = [x for grp in itertools.zip_longest(*jobs) for x in grp if x is not None]   # um mutante de cada alvo por vez: o prazo corta todos por igual
        with ThreadPoolExecutor(a.slots) as ex:
            futs = {ex.submit(one_mutant, ctx, t, text, m): (t, m) for t, text, m in order}
            for f in as_completed(futs):
                t, m = futs[f]
                code = f.result()
                if code is None:
                    continue
                ent = state["targets"][t["rel"]]
                ent["verdicts"][m["id"]] = code
                n["run"] += 1
                if code == "k":
                    n["killed"] += 1
                else:
                    n["survived"] += 1
                    n["flaky" if code == "f" else "confirmed"] += 1
                if code == "s":
                    rec = {"id": m["id"], "file": t["rel"], "line": m["line"], "op": m["op"], "old": m["old"][:40], "new": m["new"][:40], "selftest": t["family"][:3]}
                    ent["survivors"][m["id"]] = rec
                    new_surv.append(rec)
        try:
            save_state(a.state, state)
        except OSError as e:
            err = "%s: %s" % (type(e).__name__, e)
            break
    done = not ctx.stop.is_set() and err is None and time.time() <= ctx.deadline
    ents = [(t, state["targets"].get(t["rel"], {})) for t in plan]
    cur = [e for t, e in ents if e.get("hash") == t["hash"]]
    # sem-cobertura: nada foi examinado nem antes (nenhum alvo com todos os mutantes julgados) nem agora; "completo"/"sem-novidade" sobre isso seria dizer coberto o que ninguém olhou
    result = ("interrompido" if ctx.stop.is_set() else "gravacao-falhou" if err else "sem-cobertura" if not n["run"] and not any(complete(e) for e in cur) and (done or not todo)
              else "sem-novidade" if not todo else "completo" if done else "parcial")
    summary(result, targets_swept=n["swept"], mutants_run=n["run"], killed=n["killed"], survived=n["survived"], confirmed=n["confirmed"], flaky=n["flaky"], invalid=n["invalid"], nao_sei=n["unknown"],
            restam=sum(max(0, e.get("total", 0) - len(e.get("verdicts", {}))) for e in cur), skipped=skipped, open_n=sum(len(e.get("survivors", {})) for e in state["targets"].values()), survivors=new_surv,
            perdidos=lost[:5], recent="ok" if recent is not None else "indisponivel", secs=int(time.time() - t0), jail=proof[:120], **({"erro": err[:160]} if err else {}))
    return 143 if ctx.stop.is_set() else 3 if err else 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="hq-mutate.py")
    sp = ap.add_subparsers(dest="cmd", required=True)
    g = sp.add_parser("gen")
    g.add_argument("file")
    g.add_argument("--tree")
    for name in ("plan", "sweep"):
        p = sp.add_parser(name)
        p.add_argument("--tree", required=True)
        p.add_argument("--state", required=True)
    s = sp.choices["sweep"]
    s.add_argument("--work", required=True)
    s.add_argument("--jail", required=True)
    for k, d in (("budget-s", 3600), ("slots", 4), ("cap", 40), ("targets", 8)):
        s.add_argument("--" + k, type=int, default=d)
    a = ap.parse_args(argv)
    if a.cmd == "gen":
        try:
            rel = Path(a.file).resolve().relative_to(Path(a.tree).resolve()).as_posix() if a.tree else Path(a.file).name   # com --tree o id é o que o sweep grava
            for m in candidates(Path(a.file), rel)[1]:
                print("\t".join((m["id"], str(m["line"]), m["op"], m["old"], m["new"])))
        except (OSError, ValueError, SyntaxError, tokenize.TokenError) as e:
            print("hq-mutate: não leio %s (%s)" % (a.file, e), file=sys.stderr)
            return 3
        return 0
    if a.cmd == "plan":
        try:
            for t in make_plan(Path(a.tree).resolve(), load_state(a.state), git_recent(Path(a.tree).resolve())):
                print("\t".join((t["skip"] or "todo", t["rel"], "recente" if t["recent"] else "-", "embutido" if t["embedded"] else "sem-embutido", str(t["swept"]), t["hash"])))
        except (OSError, ValueError, KeyError, TypeError) as e:
            print("hq-mutate: %s: %s" % (type(e).__name__, e), file=sys.stderr)
            return 3
        return 0
    return sweep(a)


if __name__ == "__main__":
    sys.exit(main())
