#!/usr/bin/env python3
"""repro-lock.py (ga-89ix4m4) -- o teste que REPRODUZ o bug é commitado antes do conserto e fica TRAVADO até o gate-done.

Contents
  Por que · As três peças · A gramática (trailers do git) · Comandos · O que a checagem do gate decide · Estados · Limites

POR QUE. Em bead tipo bug o gate só confere em metade das submissões (braço B) se o teste novo falha no código antigo, e nada impedia o
construtor de afrouxar o teste enquanto conserta: teste reescrito junto com o conserto não prova que o bug sumiu. Aqui o teste entra num
commit PRÓPRIO, medido falhando no código de hoje, e depois dele ninguém mexe nesses arquivos sem deixar motivo registrado.

AS TRÊS PEÇAS (um arquivo só: o hook e o gate rodam `python3 -I <este arquivo>`, e -I não põe a pasta do script no sys.path).
  lock / release / done / status   o construtor. `lock` confere a bead (issue_type=bug), a árvore (só os arquivos de teste sujos), roda a reprodução
                                   (--cmd: tem de FALHAR) e faz o commit dos arquivos com os trailers abaixo; grava o estado local do hook.
  guard                            o motor do hook PreToolUse (repro-lock-guard.sh): Edit/Write/MultiEdit/NotebookEdit num arquivo travado → exit 2.
  check                            a checagem do gate (passo 2f do gate-hard-checks.sh): relê SÓ o git de base..head e diz ok/fail/aviso/nao-se-aplica.

A GRAMÁTICA. A trava mora na HISTÓRIA, não em arquivo de estado: sobrevive a rebase, a worktree novo e ao conserto depois de uma reprovação.
  Repro-Lock: <bead>                 o commit é a trava desta bead
  Repro-Lock-File: <caminho>         um por arquivo travado (relativo à raiz do repo)
  Repro-Lock-Release: <bead>         commit VAZIO que libera a trava
  Repro-Lock-Release-Reason: <texto> o motivo (>= 20 caracteres), o mesmo que `release` grava na bead
Só o ÚLTIMO parágrafo da mensagem conta (um texto citando «Repro-Lock:» no meio da prosa não é trailer).

O QUE A CHECAGEM DO GATE DECIDE (por bead, em base..head, commits em ordem topológica):
  sem trava declarada                      nao-se-aplica (crews e submissões antigas não mudam)
  trava depois de commit comum             fail (o teste tem de ser o 1º commit: depois dele o conserto)    [liberada: aviso]
  commit da trava mexe em OUTRO arquivo    fail (o commit da trava leva só os arquivos declarados, todos adicionados/alterados)
  commit seguinte mexe num arquivo travado fail (inclusive apagar/renomear, e mesmo que um commit depois o restaure)
  release com motivo                       aviso (o motivo vai ao comentário do marcador, ao rótulo e ao log; nunca recusa sozinho)
  git que falha ou objeto ausente → nao-sei (rc 2): NUNCA ok, NUNCA fail.
  O que o CONSTRUTOR controla nunca vira «não sei» (seria um jeito de desligar o passo): merge vale pela linha do 1º pai (o que cada merge trouxe aparece no diff dele); trava ou liberação fora
  dessa linha, e trava declarada num histórico de mais de 2000 commits, são fail; o texto da mensagem não desloca nenhum registro (rev-list + cat-file --batch, tamanho no cabeçalho).

ESTADOS (três, em tudo): tem / não tem / não sei. «Não sei» não vira «sem trava»: a checagem sai 2, o `lock` recusa, o hook (que só atrapalha) falha ABERTO e
registra UNGUARDED no log, porque quem recusa de verdade é o gate.

LIMITES, ditos de antemão. O hook cobre as ferramentas Edit/Write/MultiEdit/NotebookEdit; escrever o arquivo por Bash (sed -i, redirecionamento) não é barrado
aqui — quem pega é o gate, que compara o commit. Quem apaga o commit da trava com reset e recomita junto sem trailer não tem trava nenhuma: a trava ajuda o
construtor a ser honesto e dá ao gate o que provar, não impede um construtor de má fé (o braço B e o revisor continuam). O estado local do hook (<git-dir>/repro-lock/)
só existe no worktree onde o `lock` rodou; o gate lê a história e vale em qualquer lugar.

Códigos de saída: 0 ok · 1 fail (check) · 2 NÃO SEI / recusado / erro de uso do ambiente · 64 uso · (guard: 2 só com «repro-lock-guard: BLOCKED» na 1ª linha do stderr).
Testes: python3 -I scripts/test_repro_lock.py (REPRO_LOCK_UNDER_TEST=<cópia> roda contra um mutante).
"""
import json
import os
import re
import subprocess
import sys
import time

LOCK_KEY, FILE_KEY, REL_KEY, WHY_KEY = "Repro-Lock", "Repro-Lock-File", "Repro-Lock-Release", "Repro-Lock-Release-Reason"
TRAILER_RE = re.compile(r"^(%s|%s|%s|%s): (\S.*?)\s*$" % tuple(re.escape(k) for k in (WHY_KEY, REL_KEY, FILE_KEY, LOCK_KEY)))
ANY_TRAILER_RE = re.compile(r"^[A-Za-z][A-Za-z0-9-]*: \S")
BEAD_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SHA_RE = re.compile(r"^[0-9a-fA-F]{7,64}$")
STATE_DIR = "repro-lock"
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
MIN_REASON, MAX_REASON = 20, 300
MAX_COMMITS, MAX_LINES = 2000, 40
GIT_TIMEOUT = 60
BLOCKED = "repro-lock-guard: BLOCKED"
# a saída de um teste que falha por ambiente ou coleta (não pelo bug) e que um construtor confunde com «reproduz»; --expect desliga a heurística
WRONG_REASON = re.compile(r"ModuleNotFoundError|ImportError|SyntaxError|IndentationError|command not found|No such file or directory|fixture '[^']*' not found|"
                          r"no tests ran|collected 0 items|ERROR collecting|Cannot find module|cannot find package", re.I)


class Cant(Exception):
    """Não consegui saber: vira exit 2 / nao-sei, nunca ok e nunca fail."""


# ----------------------------------------------------------------------------- git / bd
def _env():
    e = dict(os.environ)
    e.update({"GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"})
    return e


def git(repo, *args, stdin=None, timeout=GIT_TIMEOUT):
    """stdout (bytes) de `git -C repo <args>`. vazio → saída vazia é resposta legítima (rev-list sem commits); falhou (rc != 0, git ausente, estouro) → Cant com a causa, nunca vazio."""
    try:
        p = subprocess.run(["git", "-C", repo] + list(args), input=stdin, capture_output=True, timeout=timeout, env=_env())
    except (OSError, subprocess.SubprocessError) as e:
        raise Cant("git %s não rodou: %s" % (args[0] if args else "", e))
    if p.returncode != 0:
        raise Cant("git %s falhou (rc %d): %s" % (" ".join(args[:3]), p.returncode, p.stderr.decode("utf-8", "replace").strip()[:200]))
    return p.stdout


def git_text(repo, *args, stdin=None):
    return git(repo, *args, stdin=stdin).decode("utf-8", "replace").strip()


def bd(*args, timeout=45):
    """stdout (texto) de `bd <args>`. vazio → saída vazia volta como texto vazio e o chamador decide; falhou (rc != 0, bd ausente, estouro) → Cant, nunca texto vazio."""
    exe = os.environ.get("REPRO_LOCK_BD", "bd")
    try:
        p = subprocess.run([exe] + list(args), capture_output=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        raise Cant("bd %s não rodou: %s" % (args[0] if args else "", e))
    if p.returncode != 0:
        raise Cant("bd %s falhou (rc %d): %s" % (" ".join(args[:2]), p.returncode, p.stderr.decode("utf-8", "replace").strip()[:200]))
    return p.stdout.decode("utf-8", "replace")


def bead_type(bead):
    """issue_type da bead. vazio → bead sem issue_type = Cant (não sei o tipo); falhou/ilegível (bd cai, JSON torto, forma inesperada) → Cant."""
    out = bd("show", bead, "--json")
    try:
        data = json.loads(out)
    except ValueError as e:
        raise Cant("bd show %s devolveu JSON ilegível: %s" % (bead, e))
    item = data[0] if isinstance(data, list) and data else data
    t = item.get("issue_type") if isinstance(item, dict) else None
    if not isinstance(t, str) or not t:
        raise Cant("bd show %s não trouxe issue_type" % bead)
    return t


# ----------------------------------------------------------------------------- gramática
def safe_rel(path):
    """Caminho relativo, POSIX, sem `..`, `.git`, newline ou NUL: o que cabe num trailer e que o git aceita como pathspec literal."""
    if not isinstance(path, str) or not path or len(path) > 300 or any(c in path for c in "\0\n\r") or path != path.strip():
        return False
    if path.startswith("/") or path.endswith("/") or "\\" in path:
        return False
    return all(p not in ("", ".", "..", ".git") for p in path.split("/"))


def parse_trailers(msg):
    """[(chave, valor)] dos trailers repro-lock da ÚLTIMA parágrafo (precisa de pelo menos 2 parágrafos: a 1ª linha sozinha é o assunto)."""
    paras = re.split(r"\n[ \t]*\n", msg.replace("\r\n", "\n").rstrip())
    if len(paras) < 2:
        return []
    out = []
    for line in paras[-1].split("\n"):
        m = TRAILER_RE.match(line)
        if m:
            out.append((m.group(1), m.group(2)))
    return out


def with_trailers(msg, trailers):
    """Junta os trailers ao bloco final da mensagem se ele já é só trailers (ex.: Co-Authored-By); senão abre um parágrafo novo."""
    msg = msg.replace("\r\n", "\n").strip("\n").rstrip()
    paras = re.split(r"\n[ \t]*\n", msg)
    if len(paras) >= 2 and all(ANY_TRAILER_RE.match(ln) for ln in paras[-1].split("\n")):
        return msg + "\n" + "\n".join(trailers) + "\n"
    return msg + "\n\n" + "\n".join(trailers) + "\n"


def lock_beads(msg):
    """As beads que os trailers Repro-Lock: da mensagem nomeiam."""
    return sorted({v for k, v in parse_trailers(msg) if k == LOCK_KEY})


def event_of(msg, bead):
    """('lock', [arquivos]) | ('release', motivo) | None para esta bead. Trailer de OUTRA bead não conta."""
    tr = parse_trailers(msg)
    files = []
    for k, v in tr:
        if k == FILE_KEY and v not in files:
            files.append(v)
    if any(k == REL_KEY and v == bead for k, v in tr):
        why = [v for k, v in tr if k == WHY_KEY]
        return "release", (why[0] if why else "")
    if any(k == LOCK_KEY and v == bead for k, v in tr):
        return "lock", files
    return None


# ----------------------------------------------------------------------------- história
def list_commits(repo, base, head, first_parent=False):
    """[(sha, [pais])] de base..head, do mais velho ao mais novo (topológico). vazio → [] = a branch não tem commit próprio; falhou/ilegível → Cant.
    Só rev-list: texto do construtor não passa por aqui, então nada que ele escreva desloca um registro."""
    args = ["rev-list", "--reverse", "--topo-order", "--parents"] + (["--first-parent"] if first_parent else []) + ["%s..%s" % (base, head)]
    out = []
    for line in git_text(repo, *args).splitlines():
        shas = line.split()
        if not shas or not all(SHA_RE.match(x) for x in shas):
            raise Cant("git rev-list devolveu uma linha ilegível")
        out.append((shas[0], shas[1:]))
    return out


def commit_messages(repo, shas):
    """{sha: mensagem}. O `cat-file --batch` põe o TAMANHO de cada objeto no cabeçalho, então o texto do commit (NUL, separadores, trailers falsos) não desloca o registro seguinte: quem escreve a
    mensagem é o construtor, e um formato que ela pudesse quebrar viraria «não sei» por escolha dele. vazio → {}; falhou/ilegível (objeto ausente, resposta cortada) → Cant."""
    if not shas:
        return {}
    raw = git(repo, "cat-file", "--batch", stdin=("\n".join(shas) + "\n").encode("ascii"))
    out, pos = {}, 0
    for sha in shas:
        nl = raw.find(b"\n", pos)
        head = raw[pos:nl].decode("ascii", "replace").split() if nl >= 0 else []
        if len(head) != 3 or head[0] != sha or head[1] != "commit" or not head[2].isdigit():
            raise Cant("cat-file não trouxe o commit %s (%s)" % (sha[:7], " ".join(head) or "resposta cortada"))
        size = int(head[2])
        body = raw[nl + 1:nl + 1 + size]
        if len(body) != size:
            raise Cant("cat-file cortou o commit %s" % sha[:7])
        pos = nl + 1 + size + 1
        _, sep, msg = body.decode("utf-8", "replace").partition("\n\n")
        out[sha] = msg if sep else ""
    return out


def read_range(repo, base, head):
    """[{sha, parents, msg}] de base..head. Para o CONSTRUTOR (lock/release): história longa demais é «não sei» e recusa; o gate não usa isto (ver analyze)."""
    commits = list_commits(repo, base, head)
    if len(commits) > MAX_COMMITS:
        raise Cant("história com mais de %d commits em base..head: não leio" % MAX_COMMITS)
    msgs = commit_messages(repo, [s for s, _ in commits])
    return [{"sha": s, "parents": p, "msg": msgs[s]} for s, p in commits]


def changed_files(repo, sha, parents):
    """{caminho: status} do commit contra o 1º pai (contra a árvore vazia se não tem pai: um commit-raiz no meio do intervalo não pode virar «não sei»). vazio → {} = commit vazio (o release é assim);
    falhou/ilegível (par status/caminho torto) → Cant."""
    flags = ["diff-tree", "-r", "-z", "--no-renames", "--name-status"]
    raw = git(repo, *(flags + ["--root", "--no-commit-id", sha] if not parents else flags + [parents[0], sha]))
    toks = raw.split(b"\0")
    if toks and toks[-1] == b"":
        toks.pop()
    if len(toks) % 2:
        raise Cant("diff-tree de %s devolveu pares status/caminho tortos" % sha[:7])
    return {toks[i + 1].decode("utf-8", "replace"): toks[i].decode("ascii", "replace")[:1] for i in range(0, len(toks), 2)}


def blobs_at(repo, rev, paths):
    """{caminho: (modo, blob)} dos caminhos que existem em rev. vazio → {} = nenhum existe (o chamador trata como apagado); falhou/ilegível → Cant."""
    if not paths:
        return {}
    raw = git(repo, "ls-tree", "-z", rev, "--", *paths)
    out = {}
    for rec in raw.split(b"\0"):
        if not rec:
            continue
        meta, _, path = rec.partition(b"\t")
        bits = meta.decode("ascii", "replace").split()
        if len(bits) != 3 or not path:
            raise Cant("ls-tree de %s devolveu uma linha ilegível" % rev[:7])
        out[path.decode("utf-8", "replace")] = (bits[0], bits[2])
    return out


def grep_lock(repo, base, head, bead):
    """True se alguma mensagem de base..head traz «Repro-Lock: <bead>» (texto fixo, sem ler commit por commit: serve a histórico longo). vazio → False (a busca respondeu e não achou); falhou → Cant."""
    return bool(git_text(repo, "log", "-n", "1", "--format=%H", "-F", "--grep=%s: %s" % (LOCK_KEY, bead), "%s..%s" % (base, head)))


def analyze(repo, base, head, bead):
    """O veredito da história de base..head para `bead`: dict(verdict, reason, locks, files, releases, lines).
    «Não sei» (Cant) só sobra para o que o construtor NÃO controla (git que falha, objeto ausente): o que ele controla (merge, histórico longo, texto da mensagem, commit-raiz) é julgado, e uma trava
    declarada que não dá para provar é RECUSA, nunca um jeito de desligar o passo."""
    res = {"verdict": "nao-se-aplica", "reason": "sem-trava-declarada", "locks": 0, "files": 0, "releases": 0, "lines": []}
    allc = list_commits(repo, base, head)
    if len(allc) > MAX_COMMITS:
        if grep_lock(repo, base, head, bead):
            res.update(verdict="fail", reason="historia-longa-demais-com-trava",
                       lines=["historia-longa-demais-com-trava: mais de %d commits em base..head e uma trava declarada: não dá para provar que o teste não mudou; reduza a branch (rebase/squash)" % MAX_COMMITS])
        else:
            res["reason"] = "historia-longa-sem-trava"
        return res
    msgs = commit_messages(repo, [s for s, _ in allc])
    events_all = {s: event_of(msgs[s], bead) for s, _ in allc}
    res["locks"] = sum(1 for e in events_all.values() if e and e[0] == "lock")
    if res["locks"] == 0:
        foreign = sorted({b for s, _ in allc for b in lock_beads(msgs[s]) if b != bead})
        if foreign:
            res.update(verdict="aviso", reason="trava-so-de-outra-bead",
                       lines=["trailers Repro-Lock de outra(s) bead(s): %s (o gate julga %s: o id do trailer tem de ser o do nome da branch; numa branch empilhada isto é esperado)" % (", ".join(foreign[:5]), bead)])
        return res
    viol, notes = [], []
    commits = allc
    if any(len(p) > 1 for _, p in allc):
        # com merge a ordem não é uma fila: vale a linha do 1º pai (o que cada merge TROUXE aparece no diff dele contra o 1º pai); evento fora dela não dá para provar
        commits = list_commits(repo, base, head, first_parent=True)
        chain = {s for s, _ in commits}
        off = [s for s, e in events_all.items() if e is not None and s not in chain]
        if off:
            viol.append(("trava-fora-da-linha-principal", "o(s) commit(s) %s têm Repro-Lock/Repro-Lock-Release fora da linha do 1º pai da branch: não dá para provar a ordem; refaça a branch sem esse merge (rebase sobre origin/main)" % ", ".join(s[:7] for s in off[:5])))
    events = [events_all[s] for s, _ in commits]
    nrel = sum(1 for e in events if e and e[0] == "release")
    res["releases"] = nrel
    baseline, ever = {}, set()
    first_other = None
    for i, ((sha, parents), ev) in enumerate(zip(commits, events)):
        sha7 = sha[:7]
        if ev is None and first_other is None:
            first_other = i
        if ev is not None and ev[0] == "release":
            if len(ev[1]) < MIN_REASON:
                viol.append(("liberacao-sem-motivo", "%s: Repro-Lock-Release sem Repro-Lock-Release-Reason de pelo menos %d caracteres" % (sha7, MIN_REASON)))
            else:
                notes.append("liberada em %s: %s" % (sha7, ev[1][:MAX_REASON]))
            baseline.clear()
            continue
        if ev is not None:
            files = ev[1]
            if not files or not all(safe_rel(f) for f in files):
                viol.append(("trava-sem-arquivos", "%s: Repro-Lock sem Repro-Lock-File válido (caminho relativo, sem .., sem espaço nas pontas)" % sha7))
                continue
            touched = changed_files(repo, sha, parents)
            extra = sorted(set(touched) - set(files))
            if extra:
                viol.append(("commit-da-trava-mexe-em-outro-arquivo", "%s também mexe em %s" % (sha7, ", ".join(extra[:5]))))
            nomove = sorted(f for f in files if touched.get(f) not in ("A", "M"))
            if nomove:
                viol.append(("trava-declara-arquivo-que-o-commit-nao-adiciona-nem-altera", "%s declara %s" % (sha7, ", ".join(nomove[:5]))))
            here = blobs_at(repo, sha, files)
            for f in files:
                mode_blob = here.get(f)
                if mode_blob is None or mode_blob[0] not in ("100644", "100755"):
                    viol.append(("arquivo-da-trava-nao-e-regular", "%s: %s" % (sha7, f)))
                    continue
                if f in baseline and baseline[f] != mode_blob[1]:
                    viol.append(("teste-travado-alterado", "%s: a trava seguinte muda %s sem liberação antes" % (sha7, f)))
                baseline[f] = mode_blob[1]
                ever.add(f)
            continue
        if baseline:
            for f in sorted(f for f in changed_files(repo, sha, parents) if f in baseline):
                viol.append(("teste-travado-alterado", "%s mexe em %s depois da trava" % (sha7, f)))
    late_idx = [i for i, ev in enumerate(events) if ev is not None and ev[0] == "lock" and first_other is not None and i > first_other]
    if late_idx:
        late = ", ".join(commits[i][0][:7] for i in late_idx)
        if nrel:
            notes.append("trava depois de commit comum (%s), com liberação registrada" % late)
        else:
            before = sum(1 for j in range(late_idx[0]) if events[j] is None)
            viol.append(("trava-nao-e-o-primeiro-commit", "a trava %s vem depois de %d commit(s) comum(ns): o teste tem de ser o 1º commit, antes de qualquer conserto" % (late, before)))
    res["files"] = len(ever)
    if viol:
        res.update(verdict="fail", reason=viol[0][0], lines=["%s: %s" % kv for kv in viol])
    elif nrel:
        res.update(verdict="aviso", reason="trava-liberada-com-motivo", lines=notes)
    else:
        res.update(verdict="ok", reason="trava-integra", lines=[])
    if res["verdict"] == "fail" and notes:
        res["lines"] += ["nota: " + n for n in notes]
    return res


# ----------------------------------------------------------------------------- estado local do hook
def state_dir(gitdir):
    return os.path.join(gitdir, STATE_DIR)


def load_states(gitdir):
    """[(arquivo, dict)] das travas locais deste worktree. vazio → [] (pasta ausente = sem trava); falhou/ilegível (JSON torto, forma inesperada) → o arquivo entra em `bad`, nunca vira «sem trava»."""
    d = state_dir(gitdir)
    try:
        names = sorted(n for n in os.listdir(d) if n.endswith(".json"))
    except FileNotFoundError:
        return [], []
    except OSError as e:
        raise Cant("não consegui listar %s: %s" % (d, e))
    good, bad = [], []
    for n in names:
        p = os.path.join(d, n)
        try:
            with open(p, encoding="utf-8") as fh:
                st = json.loads(fh.read())
        except (OSError, ValueError):
            bad.append(p)
            continue
        if not isinstance(st, dict) or st.get("v") != 1 or not isinstance(st.get("files"), list) or not isinstance(st.get("bead"), str) \
                or not all(safe_rel(f) for f in st["files"]) or not st["files"]:
            bad.append(p)
            continue
        good.append((p, st))
    return good, bad


def prune_state_dir(gitdir):
    """Apaga a pasta de estado quando ficou vazia: o caminho rápido do hook é «a pasta existe?», e uma pasta vazia o mandaria ao python em toda edição. Não vazia ou sem permissão: fica, só custa um python."""
    try:
        os.rmdir(state_dir(gitdir))
    except OSError:
        pass


def write_state(gitdir, st):
    import tempfile  # só o construtor grava: o hook (caminho quente) não paga o import
    d = state_dir(gitdir)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".w-", dir=d)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(st, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, os.path.join(d, st["bead"] + ".json"))


def repo_ids(directory):
    """(raiz, git-dir) absolutos do repo que contém `directory`. falhou (não é repo, git ausente) → Cant."""
    out = git_text(directory, "rev-parse", "--show-toplevel", "--absolute-git-dir").split("\n")
    if len(out) != 2 or not out[0] or not out[1]:
        raise Cant("git rev-parse devolveu o formato inesperado em %s" % directory)
    return out[0], out[1]


# ----------------------------------------------------------------------------- hook
def guard_cmd(stdin_text, who_cmd):
    """Motor do hook. Devolve (rc, stderr). rc 2 só com o arquivo TRAVADO; qualquer dúvida é 0 (o hook só atrapalha, quem recusa de verdade é o gate) e o chamador registra."""
    try:
        payload = json.loads(stdin_text)
    except ValueError:
        return 0, "UNGUARDED payload do hook não é JSON"
    ti = payload.get("tool_input") if isinstance(payload, dict) else None
    tool = payload.get("tool_name") if isinstance(payload, dict) else None
    if tool not in EDIT_TOOLS or not isinstance(ti, dict):
        return 0, ""
    path = ti.get("file_path") or ti.get("notebook_path")
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else os.getcwd()
    if not isinstance(path, str) or not path:
        return 0, ""
    target = path if os.path.isabs(path) else os.path.join(cwd, path)
    d = os.path.dirname(target)
    while d and not os.path.isdir(d) and os.path.dirname(d) != d:
        d = os.path.dirname(d)  # Write pode criar a pasta: sobe até a que existe
    try:
        top, gd = repo_ids(d)
        good, bad = load_states(gd)
    except Cant as e:
        return 0, "UNGUARDED %s" % e
    for p, st in good:
        for rel in st["files"]:
            if same_file(target, os.path.join(top, rel)):
                return 2, block_message(rel, st, who_cmd)
    # estado ilegível = o hook não sabe o que guardar: deixa passar e DIZ (o wrapper registra UNGUARDED); quem recusa de verdade é o gate
    return 0, "".join("UNGUARDED estado ilegível %s\n" % p for p in bad).rstrip("\n")


def same_file(a, b):
    """Mesmo arquivo pelo inode (APFS ignora maiúsculas e links valem) ou, se algum não existe ainda, pelo caminho resolvido. falhou (corrida, permissão) → cai no caminho resolvido."""
    try:
        if os.path.exists(a) and os.path.exists(b) and os.path.samefile(a, b):
            return True
    except OSError:
        pass
    return os.path.realpath(a) == os.path.realpath(b)


def block_message(rel, st, who_cmd):
    b = st["bead"]
    return (
        "%s — «%s» está TRAVADO pela bead %s (commit da trava %s): é o teste que reproduz o bug e prova o conserto, e afrouxá-lo junto com o conserto não prova que o bug sumiu. "
        "NÃO repita a chamada e NÃO contorne por Bash (sed -i, tee, redirecionamento, git checkout/restore): o gate compara o teste do tip com o commit da trava e recusa a submissão (passo 2f).\n"
        "O que fazer:\n"
        "1. Conserte o CÓDIGO, não o teste. Precisa de mais casos? Crie OUTRO arquivo de teste: este fica como está.\n"
        "2. Já entregou (gate-done) e vai seguir noutra bead? %s done %s\n"
        "3. O teste tem defeito de verdade? %s release %s --reason \"<o que está errado no teste, %d+ caracteres>\": grava o motivo na bead e no git (o revisor vê) e destrava; sem motivo registrado o gate recusa."
        % (BLOCKED, rel, b, str(st.get("lock_sha", "?"))[:7], who_cmd, b, who_cmd, b, MIN_REASON))


# ----------------------------------------------------------------------------- construtor
def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def die(msg, rc=2):
    sys.stderr.write("repro-lock: %s\n" % msg)
    return rc


def porcelain_paths(repo):
    """Caminhos sujos da árvore. vazio → [] = árvore limpa; falhou/ilegível → Cant."""
    raw = git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    toks = [t for t in raw.split(b"\0") if t]
    out, i = [], 0
    while i < len(toks):
        rec = toks[i].decode("utf-8", "replace")
        if len(rec) < 4:
            raise Cant("git status devolveu uma linha ilegível")
        out.append(rec[3:])
        if rec[0] in "RC":
            i += 1  # renomeado/copiado traz o caminho de origem no token seguinte
            if i < len(toks):
                out.append(toks[i].decode("utf-8", "replace"))
        i += 1
    return out


def base_of(repo):
    """merge-base de HEAD com origin/main (ou main). Falhou → None: o chamador avisa que não conferiu a ordem, o gate confere de qualquer jeito."""
    for ref in ("origin/main", "main"):
        try:
            return git_text(repo, "merge-base", "HEAD", ref)
        except Cant:
            continue
    return None


def run_repro(top, cmd, timeout):
    """(rc, cauda). vazio → saída vazia é cauda vazia; falhou (estouro, bash ausente) → Cant: «não consegui rodar» nunca é «reproduz». No estouro mata o GRUPO inteiro: um neto
    (pytest-xdist, um servidor de teste) segurando o pipe deixaria o communicate() esperando para sempre."""
    try:
        proc = subprocess.Popen(["bash", "-c", cmd], cwd=top, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    except (OSError, subprocess.SubprocessError) as e:
        raise Cant("a reprodução não rodou: %s" % e)
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, 9)
        except OSError:
            proc.kill()
        proc.communicate()
        raise Cant("a reprodução passou de %ds e foi interrompida: não sei se reproduz" % timeout)
    lines = [ln[:200] for ln in out.decode("utf-8", "replace").splitlines() if ln.strip()][-12:]
    return proc.returncode, "\n".join(lines)[-1500:]


def cmd_lock(a):
    bead = a.bead
    if not BEAD_RE.match(bead):
        return die("id de bead inválido: %r" % bead, 64)
    top, gd = repo_ids(os.getcwd())
    norm = []
    for f in a.files:
        absf = os.path.realpath(f if os.path.isabs(f) else os.path.join(os.getcwd(), f))
        rel = os.path.relpath(absf, os.path.realpath(top)).replace(os.sep, "/")
        if not safe_rel(rel):
            return die("arquivo fora do repo ou de nome que não cabe no trailer: %r" % f)
        if os.path.islink(os.path.join(top, rel)) or not os.path.isfile(os.path.join(top, rel)):
            return die("%s não é arquivo regular" % rel)
        if rel not in norm:
            norm.append(rel)
    if not norm:
        return die("nenhum arquivo de teste dado", 64)
    already, _ = load_states(gd)
    if any(st["bead"] == bead for _, st in already):
        return die("a bead %s já tem trava neste worktree (repro-lock status). Para travar OUTROS arquivos, libere antes (release com motivo) ou inclua todos num lock só" % bead)
    # vazio/falhou → bd não respondeu o tipo: não sei, não trava (o estado inerte de um construtor sem trava é o gate de sempre)
    t = bead_type(bead)
    if t != "bug":
        return die("a bead %s é do tipo %r: a trava vale só para bead tipo bug (o teste que reproduz o bug tem de falhar ANTES do conserto)" % (bead, t))
    dirty = porcelain_paths(top)
    other = sorted(set(dirty) - set(norm))
    if other:
        return die("a árvore tem outras mudanças (%s): o commit da trava leva SÓ os arquivos de teste, e o teste só prova o bug no código ainda sem conserto. "
                   "Guarde essas mudanças antes (commit separado depois da trava, ou git stash push -u -m <tag> com tag única)" % ", ".join(other[:6]))
    clean = sorted(f for f in norm if f not in dirty)
    if clean:
        return die("%s não tem mudança nova: a trava é o commit que ADICIONA ou ALTERA o teste" % ", ".join(clean))
    base = base_of(top)
    if base is None:
        sys.stderr.write("repro-lock: AVISO — não achei origin/main nem main: não conferi se a trava é o 1º commit da branch (o gate confere)\n")
    else:
        prior = [c for c in read_range(top, base, "HEAD") if event_of(c["msg"], bead) is None]
        if prior:
            return die("a branch já tem %d commit(s) comum(ns) à frente de origin/main (%s): o teste tem de ser o 1º commit, antes de qualquer conserto"
                       % (len(prior), ", ".join(c["sha"][:7] for c in prior[:5])))
    repro = None
    if a.cmd:
        rc, tail = run_repro(top, a.cmd, a.timeout)
        if rc == 0:
            return die("a reprodução PASSA no código de hoje (rc 0): o teste não reproduz o bug, não há o que travar.\n%s" % tail)
        if rc in (126, 127):
            return die("a reprodução não rodou (rc %d: comando não encontrado ou sem permissão):\n%s" % (rc, tail))
        if a.expect:
            if not re.search(a.expect, tail):
                return die("a reprodução falhou (rc %d), mas a saída não casa --expect %r: não é o motivo certo.\n%s" % (rc, a.expect, tail))
        elif WRONG_REASON.search(tail):
            return die("a reprodução falhou (rc %d), mas parece falha de AMBIENTE ou de coleta, não do bug (%r). Corrija o teste, ou confirme o motivo com "
                       "--expect '<regex da asserção do bug>'.\n%s" % (rc, WRONG_REASON.search(tail).group(0), tail))
        repro = {"cmd": a.cmd, "rc": rc, "tail": tail}
    else:
        sys.stderr.write("repro-lock: AVISO — sem --cmd: não medi que o teste FALHA no código de hoje. Rode-o e confira o motivo antes de seguir (o comentário da bead diz «não medido»).\n")
    msg = with_trailers(a.message or "test(%s): reproduz o bug antes do conserto (trava de teste)" % bead,
                        ["%s: %s" % (LOCK_KEY, bead)] + ["%s: %s" % (FILE_KEY, f) for f in norm])
    git(top, "add", "--", *norm)
    try:
        git(top, "commit", "-q", "-F", "-", stdin=msg.encode("utf-8"))
    except Cant as e:
        return die("o commit da trava falhou (os arquivos ficaram no índice, nada foi travado): %s" % e)
    sha = git_text(top, "rev-parse", "HEAD")
    touched = changed_files(top, sha, [sha + "^"])
    if sorted(touched) != sorted(norm):
        return die("o commit %s mexeu em %s, não só nos arquivos pedidos (um hook de commit mexeu?): NÃO travei. Confira com git show --stat" % (sha[:7], sorted(touched)))
    who = os.environ.get("GC_SESSION_NAME") or os.environ.get("GC_ALIAS") or os.environ.get("GC_AGENT") or ""
    try:
        write_state(gd, {"v": 1, "bead": bead, "files": norm, "toplevel": os.path.realpath(top), "lock_sha": sha, "locked_at": now(), "session": who, "repro": repro})
    except OSError as e:
        return die("o commit da trava %s existe e o GATE vai conferi-lo, mas não consegui gravar o estado do hook (%s): o hook NÃO vai barrar edição do teste" % (sha[:7], e))
    note = "[repro-lock] TRAVADO: %s @ %s. O teste que reproduz o bug entrou ANTES do conserto e não pode mudar até o gate-done (o gate compara o commit da trava; mudou depois = recusa). %s" % (
        ", ".join(norm), sha[:7], ("Reprodução: `%s` saiu com rc=%d (falha no código de hoje)." % (a.cmd, repro["rc"])) if repro else "Reprodução NÃO medida (sem --cmd).")
    if not a.no_comment:
        try:
            bd("comment", bead, note)
        except Cant as e:
            sys.stderr.write("repro-lock: AVISO — não consegui comentar na bead (%s); comente você: %s\n" % (e, note))
    print("repro-lock: travado %s @ %s (bead %s)." % (", ".join(norm), sha[:7], bead))
    print("Agora conserte o CÓDIGO. O hook recusa editar o teste; depois do gate-done rode: repro-lock done %s" % bead)
    return 0


def lock_files_from_history(top, bead):
    base = base_of(top)
    if base is None:
        raise Cant("não achei origin/main nem main para ler a história da trava")
    files = []
    for c in read_range(top, base, "HEAD"):
        ev = event_of(c["msg"], bead)
        if ev and ev[0] == "lock":
            files += [f for f in ev[1] if f not in files]
    return files


def cmd_release(a):
    bead = a.bead
    if not BEAD_RE.match(bead):
        return die("id de bead inválido: %r" % bead, 64)
    reason = " ".join((a.reason or "").split())
    if len(reason) < MIN_REASON:
        return die("--reason precisa de pelo menos %d caracteres: diga o que está errado no teste (o revisor lê isto)" % MIN_REASON, 64)
    reason = reason[:MAX_REASON]
    top, gd = repo_ids(os.getcwd())
    good, bad = load_states(gd)
    mine = [st for _, st in good if st["bead"] == bead]
    files = mine[0]["files"] if mine else lock_files_from_history(top, bead)
    if not files:
        return die("não há trava da bead %s neste worktree nem na história da branch" % bead)
    note = "[repro-lock] LIBERADA a trava de %s. Motivo: %s" % (", ".join(files), reason)
    # a bead é o registro que o revisor lê: sem o comentário gravado NADA é liberado (falhou → Cant, e o estado fica travado)
    bd("comment", bead, note)
    msg = with_trailers("chore(%s): libera a trava de teste (motivo registrado)" % bead, ["%s: %s" % (REL_KEY, bead), "%s: %s" % (WHY_KEY, reason)])
    head = git_text(top, "rev-parse", "HEAD")
    tree = git_text(top, "rev-parse", "HEAD^{tree}")
    new = git_text(top, "commit-tree", tree, "-p", head, "-F", "-", stdin=msg.encode("utf-8"))
    git(top, "update-ref", "-m", "repro-lock: release", "HEAD", new, head)
    gone = remove_states(gd, [p for p, st in good if st["bead"] == bead] + [p for p in bad if os.path.basename(p) == bead + ".json"])
    if gone[1]:
        sys.stderr.write("repro-lock: AVISO — não consegui apagar %s: o hook continua barrando; apague o(s) arquivo(s)\n" % ", ".join(gone[1]))
    print("repro-lock: trava de %s LIBERADA em %s. Motivo gravado na bead e no commit (Repro-Lock-Release-Reason); o gate responde aviso e mostra o motivo." % (bead, new[:7]))
    return 0


def remove_states(gd, paths):
    """(apagados, [os que não deu]). falhou (sem permissão, corrida) → o arquivo entra na segunda lista: o chamador diz, nunca finge que soltou."""
    done, failed = 0, []
    for p in paths:
        try:
            os.unlink(p)
            done += 1
        except OSError:
            failed.append(p)
    prune_state_dir(gd)
    return done, failed


def cmd_done(a):
    top, gd = repo_ids(os.getcwd())
    good, bad = load_states(gd)
    n, failed = remove_states(gd, [p for p, st in good if st["bead"] == a.bead] + [p for p in bad if os.path.basename(p) == a.bead + ".json"])
    if failed:
        return die("não consegui apagar %s: o hook continua barrando; apague o(s) arquivo(s)" % ", ".join(failed))
    print("repro-lock: %s — o hook deixa de barrar. O gate segue comparando o commit da trava; mudar o teste depois ainda recusa." % ("%d trava(s) local(is) removida(s)" % n if n else "nenhuma trava local desta bead"))
    return 0


def is_ancestor(repo, old, new):
    """True/False. vazio → n/a (rc 0 ou 1 são as duas respostas); falhou/ilegível (rc != 0/1, git ausente, estouro) → Cant, nunca False."""
    try:
        p = subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", old, new], capture_output=True, timeout=GIT_TIMEOUT, env=_env())
    except (OSError, subprocess.SubprocessError) as e:
        raise Cant("git merge-base não rodou: %s" % e)
    if p.returncode not in (0, 1):
        raise Cant("git merge-base --is-ancestor falhou (rc %d): %s" % (p.returncode, p.stderr.decode("utf-8", "replace").strip()[:200]))
    return p.returncode == 0


def cmd_status(a):
    top, gd = repo_ids(os.getcwd())
    good, bad = load_states(gd)
    for p in bad:
        print("ILEGÍVEL %s (o hook NÃO guarda por causa dele: apague ou refaça a trava)" % p)
    if not good and not bad:
        print("repro-lock: nenhuma trava local neste worktree.")
    for _, st in good:
        try:
            live = blobs_at(top, "HEAD", st["files"])
            then = blobs_at(top, st["lock_sha"], st["files"])
            diff = sorted(f for f in st["files"] if live.get(f) != then.get(f))
            ancestor = is_ancestor(top, st["lock_sha"], "HEAD")
        except Cant as e:
            print("bead %s: não consegui conferir (%s)" % (st["bead"], e))
            continue
        print("bead %s: %s @ %s%s%s" % (st["bead"], ", ".join(st["files"]), st["lock_sha"][:7], "" if ancestor else "  [o commit da trava NÃO está no HEAD]",
                                         ("  [DIFERE do commit da trava: %s]" % ", ".join(diff)) if diff else ""))
    return 0


# ----------------------------------------------------------------------------- gate
def switched_off(city):
    if os.environ.get("REPRO_LOCK_CHECK") == "off":
        return "REPRO_LOCK_CHECK=off"
    flag = os.path.join(city, ".gc", "repro-lock-check.off") if city else ""
    if flag and os.path.exists(flag):
        return flag
    return ""


def cmd_check(a):
    if not (SHA_RE.match(a.base) and SHA_RE.match(a.head) and BEAD_RE.match(a.bead)):
        return die("check: base/head precisam ser sha em hexadecimal e a bead um id válido", 64)
    why = switched_off(a.city or os.environ.get("GC_CITY_PATH", ""))
    if why:
        print("NOTE: repro-lock-check: is switched OFF (%s); nothing was checked" % why)
        return 0
    try:
        r = analyze(a.repo, a.base, a.head, a.bead)
    except Cant as e:
        print("repro-lock-check: verdict=nao-sei reason=leitura-falhou locks=- files=- releases=-")
        print("  %s" % str(e)[:200])
        return 2
    print("repro-lock-check: verdict=%s reason=%s locks=%d files=%d releases=%d" % (r["verdict"], r["reason"], r["locks"], r["files"], r["releases"]))
    for ln in r["lines"][:MAX_LINES]:
        print("  " + re.sub(r"[\x00-\x1f]", " ", ln).replace("<", "‹").replace(">", "›")[:200])
    return 1 if r["verdict"] == "fail" else 0


def cmd_guard(a):
    who_cmd = "python3 %s" % os.path.abspath(__file__)
    # vazio → stdin sem nada = nada a julgar (rc 0); falhou/ilegível → UNGUARDED (rc 0, contado no log pelo wrapper): o hook só atrapalha, o gate é quem recusa
    try:
        text = sys.stdin.read()
    except (OSError, ValueError) as e:
        sys.stderr.write("UNGUARDED stdin ilegível: %s\n" % e)
        return 0
    rc, err = guard_cmd(text, who_cmd) if text.strip() else (0, "")
    if err:
        sys.stderr.write(err + "\n")
    return rc


def main(argv=None):
    import argparse  # só a linha de comando do construtor/gate precisa; o hook (caminho quente) entra por cmd_guard sem pagar o import
    ap = argparse.ArgumentParser(prog="repro-lock", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="sub", required=True)
    p = sub.add_parser("lock", help="commita o teste que reproduz o bug e o trava")
    p.add_argument("bead")
    p.add_argument("files", nargs="+")
    p.add_argument("--cmd", help="comando que roda o teste; tem de FALHAR no código de hoje")
    p.add_argument("--expect", help="regex que a saída da falha tem de casar (o motivo certo)")
    p.add_argument("--timeout", type=int, default=900)
    p.add_argument("-m", "--message", help="mensagem do commit (os trailers são acrescentados)")
    p.add_argument("--no-comment", action="store_true")
    p.set_defaults(fn=cmd_lock)
    p = sub.add_parser("release", help="saída de emergência: libera a trava com motivo registrado")
    p.add_argument("bead")
    p.add_argument("--reason", required=True)
    p.set_defaults(fn=cmd_release)
    p = sub.add_parser("done", help="depois do gate-done: o hook deixa de barrar")
    p.add_argument("bead")
    p.set_defaults(fn=cmd_done)
    p = sub.add_parser("status")
    p.set_defaults(fn=cmd_status)
    p = sub.add_parser("check", help="a checagem do gate (passo 2f do gate-hard-checks.sh)")
    p.add_argument("--repo", required=True)
    p.add_argument("--base", required=True)
    p.add_argument("--head", required=True)
    p.add_argument("--bead", required=True)
    p.add_argument("--city")
    p.set_defaults(fn=cmd_check)
    p = sub.add_parser("guard", help="motor do hook PreToolUse (payload JSON no stdin)")
    p.set_defaults(fn=cmd_guard)
    a = ap.parse_args(argv)
    try:
        return a.fn(a)
    except Cant as e:
        return die("NÃO SEI: %s" % e)


if __name__ == "__main__":
    sys.exit(main())
