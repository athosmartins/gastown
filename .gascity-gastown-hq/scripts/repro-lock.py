#!/usr/bin/env python3
"""repro-lock.py (ga-89ix4m4): o teste que REPRODUZ o bug é commitado antes do conserto e fica TRAVADO. Contrato, fluxo e limites: docs/runbooks/repro-lock.md.

A trava mora na HISTÓRIA do git (trailers do ÚLTIMO parágrafo da mensagem: Repro-Lock, Repro-Lock-File, Repro-Lock-Release, Repro-Lock-Release-Reason), então hook e gate leem a mesma coisa pela MESMA simulação.
lock/release: o construtor · guard: o motor do hook PreToolUse (exit 2 num arquivo travado) · check: o passo 2f do gate (lê só o git de base..head). Testes: scripts/test_repro_lock.py.
«Não sei» (rc 2) só para o que o construtor NÃO controla (git que falha, objeto ausente); merge, histórico longo e texto de mensagem são JULGADOS: virar «não sei» seria um jeito de desligar o passo.
"""
import json
import os
import re
import subprocess
import sys

LOCK, FILE, REL, WHY = "Repro-Lock", "Repro-Lock-File", "Repro-Lock-Release", "Repro-Lock-Release-Reason"
TRAILER = re.compile(r"^(%s|%s|%s|%s): (\S.*?)\s*$" % (WHY, REL, FILE, LOCK))
BEAD = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SHA = re.compile(r"^[0-9a-fA-F]{7,64}$")
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
MIN_REASON, MAX_REASON, MAX_COMMITS, MAX_LINES, TIMEOUT = 20, 300, 2000, 40, 60
BLOCKED = "repro-lock-guard: BLOCKED"
# a falha de AMBIENTE ou de coleta que um construtor confunde com «reproduz o bug» (--expect desliga a heurística)
WRONG = re.compile(r"ModuleNotFoundError|ImportError|SyntaxError|IndentationError|command not found|No such file or directory|fixture '[^']*' not found|Permission denied|no tests ran|collected 0 items|ERROR collecting", re.I)


class Cant(Exception):
    """Não consegui saber: vira exit 2 / nao-sei, nunca ok e nunca fail."""


def run(cmd, timeout, **kw):
    """stdout (bytes). vazio → saída vazia é resposta legítima; falhou (rc != 0, binário ausente, estouro) → Cant com a causa, nunca vazio."""
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout, **kw)
    except (OSError, subprocess.SubprocessError) as e:
        raise Cant("%s não rodou: %s" % (" ".join(cmd[:4]), e))
    if p.returncode != 0:
        raise Cant("%s falhou (rc %d): %s" % (" ".join(cmd[:4]), p.returncode, p.stderr.decode("utf-8", "replace").strip()[:200]))
    return p.stdout


def git(repo, *args, stdin=None):
    return run(["git", "-C", repo, *args], TIMEOUT, input=stdin, env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", LC_ALL="C"))


def gt(repo, *args):
    return git(repo, *args).decode("utf-8", "replace").strip()


def bd(*args):
    return run([os.environ.get("REPRO_LOCK_BD", "bd"), *args], 45).decode("utf-8", "replace")


def bead_type(bead):
    """issue_type da bead. vazio/ilegível (JSON torto, sem issue_type) → Cant: não sei o tipo; bd que cai → Cant."""
    try:
        data = json.loads(bd("show", bead, "--json"))
        t = (data[0] if isinstance(data, list) and data else data)["issue_type"]
    except (ValueError, KeyError, TypeError) as e:
        raise Cant("bd show %s não trouxe um issue_type legível: %r" % (bead, e))
    if not isinstance(t, str) or not t:
        raise Cant("bd show %s trouxe um issue_type vazio" % bead)
    return t


def safe_rel(path):
    """Caminho relativo e POSIX, sem `..`, `.git`, newline, NUL nem barra invertida: o que cabe num trailer e num pathspec literal."""
    return isinstance(path, str) and 0 < len(path) <= 300 and not any(c in path for c in "\0\n\r\\") and all(p not in ("", ".", "..", ".git") for p in path.split("/"))


def parse_trailers(msg):
    """[(chave, valor)] dos trailers repro-lock do ÚLTIMO parágrafo."""
    paras = re.split(r"\n[ \t]*\n", msg.replace("\r\n", "\n").rstrip())
    return [m.groups() for m in map(TRAILER.match, paras[-1].split("\n")) if m]


def event_of(msg):
    """('release', bead, motivo) | ('lock', bead, [arquivos]) | None. Release vence lock no mesmo commit."""
    tr = parse_trailers(msg)
    for k, v in tr:
        if k == REL:
            return "release", v, ([w for kk, w in tr if kk == WHY] or [""])[0]
    for k, v in tr:
        if k == LOCK:
            return "lock", v, [w for kk, w in tr if kk == FILE]
    return None


def list_commits(repo, base, head):
    """[(sha, [pais])] de base..head, do mais velho ao mais novo. vazio → [] (sem commit próprio); falhou/ilegível → Cant. Só rev-list: texto do construtor não passa por aqui."""
    out = []
    for line in gt(repo, "rev-list", "--reverse", "--topo-order", "--parents", "%s..%s" % (base, head)).splitlines():
        shas = line.split()
        if not shas or not all(SHA.match(x) for x in shas):
            raise Cant("git rev-list devolveu uma linha ilegível")
        out.append((shas[0], shas[1:]))
    return out


def commit_messages(repo, shas):
    """{sha: mensagem}. `cat-file --batch` põe o TAMANHO de cada objeto no cabeçalho: NUL, separadores ou trailers falsos no texto do construtor não deslocam o registro seguinte.
    vazio → {}; falhou/ilegível (objeto ausente, resposta cortada) → Cant."""
    if not shas:
        return {}
    raw, out, pos = git(repo, "cat-file", "--batch", stdin=("\n".join(shas) + "\n").encode("ascii")), {}, 0
    for sha in shas:
        nl = raw.find(b"\n", pos)
        head = raw[pos:nl].decode("ascii", "replace").split() if nl >= 0 else []
        if len(head) != 3 or not head[2].isdigit() or len(raw) < nl + 1 + int(head[2]):
            raise Cant("cat-file não trouxe o commit %s (%s)" % (sha[:7], " ".join(head) or "resposta cortada"))
        size = int(head[2])
        out[sha] = raw[nl + 1:nl + 1 + size].decode("utf-8", "replace").partition("\n\n")[2]
        pos = nl + 2 + size
    return out


def changed_files(repo, sha, parents):
    """{caminho: (modo, blob)} do commit contra o 1º pai (contra a árvore vazia se é raiz). vazio → {} (commit vazio: o release é assim); par torto → Cant."""
    flags = ["diff-tree", "-r", "-z", "--no-renames", "--raw"]
    toks = git(repo, *(flags + [parents[0], sha] if parents else flags + ["--root", "--no-commit-id", sha])).split(b"\0")
    toks = toks[:-1] if toks and toks[-1] == b"" else toks
    meta = [t.decode("ascii", "replace").split() for t in toks[::2]]
    if len(toks) % 2 or any(len(m) != 5 or not m[0].startswith(":") for m in meta):
        raise Cant("diff-tree de %s devolveu pares meta/caminho tortos" % sha[:7])
    return {toks[i + 1].decode("utf-8", "replace"): (m[1], m[3]) for i, m in zip(range(0, len(toks), 2), meta)}


def simulate(repo, commits, evs):
    """Percorre `commits` em ordem com os eventos da bead que importa (None = commit comum). -> (violações [(razão, texto)], notas, {arquivo: blob} das travas AINDA valendo, arquivos já travados, nº de releases)."""
    viol, notes, base, ever, nrel, first_other, late = [], [], {}, set(), 0, None, []
    for i, ((sha, parents), ev) in enumerate(zip(commits, evs)):
        s7 = sha[:7]
        if ev is None:
            first_other = i if first_other is None else first_other
            if base:
                viol += [("teste-travado-alterado", "%s mexe em %s depois da trava" % (s7, f)) for f in sorted(changed_files(repo, sha, parents)) if f in base]
        elif ev[0] == "release":
            nrel += 1
            if len(ev[2]) < MIN_REASON:
                viol.append(("liberacao-sem-motivo", "%s: Repro-Lock-Release sem Repro-Lock-Release-Reason de pelo menos %d caracteres" % (s7, MIN_REASON)))
            else:
                notes.append("liberada em %s: %s" % (s7, ev[2][:MAX_REASON]))
            base.clear()
        else:
            files = ev[2]
            late += [s7] if first_other is not None else []
            if not files or not all(safe_rel(f) for f in files):
                viol.append(("trava-sem-arquivos", "%s: Repro-Lock sem Repro-Lock-File válido (caminho relativo, sem .., sem espaço nas pontas)" % s7))
                continue
            touched = changed_files(repo, sha, parents)
            if set(touched) - set(files):
                viol.append(("commit-da-trava-mexe-em-outro-arquivo", "%s também mexe em %s" % (s7, ", ".join(sorted(set(touched) - set(files))[:5]))))
            for f in files:
                mode, blob = touched.get(f, ("", ""))
                if mode not in ("100644", "100755"):
                    viol.append(("arquivo-da-trava-nao-e-regular-nem-novo", "%s: %s" % (s7, f)))
                    continue
                if f in base and base[f] != blob:
                    viol.append(("teste-travado-alterado", "%s: a trava seguinte muda %s sem liberação antes" % (s7, f)))
                base[f] = blob
                ever.add(f)
    if late:
        if nrel:
            notes.append("trava depois de commit comum (%s), com liberação registrada" % ", ".join(late))
        else:
            viol.append(("trava-nao-e-o-primeiro-commit", "a trava %s vem depois de commit comum: o teste tem de ser o 1º commit, antes de qualquer conserto" % ", ".join(late)))
    return viol, notes, base, ever, nrel


def read_events(repo, base, head):  # (commits [(sha, pais)], {sha: evento}) de base..head
    commits = list_commits(repo, base, head)
    return commits, {s: event_of(m) for s, m in commit_messages(repo, [s for s, _ in commits]).items()}


def has_lock(repo, base, head, bead=""):
    """True se alguma mensagem de base..head traz «Repro-Lock: <bead>» (texto fixo, sem ler commit por commit: serve a histórico longo e ao caminho barato do hook). falhou → Cant."""
    return bool(gt(repo, "log", "-n", "1", "--format=%H", "-F", "--grep=%s: %s" % (LOCK, bead), "%s..%s" % (base, head)))


def analyze(repo, base, head, bead):
    """O veredito de base..head para `bead`: dict(verdict, reason, locks, files, releases, lines). Uma trava declarada que não dá para provar é RECUSA, nunca «não sei»."""
    res = {"verdict": "nao-se-aplica", "reason": "sem-trava-declarada", "locks": 0, "files": 0, "releases": 0, "lines": []}
    n = gt(repo, "rev-list", "--count", "%s..%s" % (base, head))
    if not n.isdigit():
        raise Cant("git rev-list --count devolveu %r" % n[:20])
    if int(n) > MAX_COMMITS:
        if has_lock(repo, base, head, bead):
            res.update(verdict="fail", reason="historia-longa-demais-com-trava", lines=["mais de %d commits em base..head e uma trava declarada: não dá para provar que o teste não mudou; reduza a branch" % MAX_COMMITS])
        else:
            res["reason"] = "historia-longa-sem-trava"
        return res
    commits, all_evs = read_events(repo, base, head)
    mine = {s: (e if e and e[1] == bead else None) for s, e in all_evs.items()}
    res["locks"] = sum(1 for e in mine.values() if e and e[0] == "lock")
    if not res["locks"]:
        other = sorted({e[1] for e in all_evs.values() if e and e[0] == "lock"})
        if other:
            res.update(verdict="aviso", reason="trava-so-de-outra-bead", lines=["trailers Repro-Lock de outra(s) bead(s): %s (o gate julga %s: o id do trailer tem de ser o do nome da branch; numa branch empilhada isto é esperado)" % (", ".join(other[:5]), bead)])
        return res
    if any(len(p) > 1 for _, p in commits):
        res.update(verdict="fail", reason="trava-em-branch-com-merge", lines=["a branch tem commit de merge e uma trava declarada: não dá para provar a ordem; refaça com rebase sobre origin/main"])
        return res
    viol, notes, _, ever, nrel = simulate(repo, commits, [mine[s] for s, _ in commits])
    res.update(files=len(ever), releases=nrel)
    if viol:
        res.update(verdict="fail", reason=viol[0][0], lines=["%s: %s" % v for v in viol])
    elif nrel:
        res.update(verdict="aviso", reason="trava-liberada-com-motivo", lines=notes)
    else:
        res.update(verdict="ok", reason="trava-integra")
    return res


def base_of(repo):
    """merge-base de HEAD com origin/main (ou main); nenhum dos dois → None (o chamador diz que não sabe)."""
    for ref in ("origin/main", "main"):
        try:
            return gt(repo, "merge-base", "HEAD", ref)
        except Cant:
            continue
    return None


def locked_now(repo, base):
    """{arquivo: bead} das travas que valem em HEAD: a MESMA simulação do gate (release libera). vazio → {}; falhou → Cant."""
    commits, evs = read_events(repo, base, "HEAD")
    out = {}
    for b in sorted({e[1] for e in evs.values() if e and e[0] == "lock"}):
        out.update({f: b for f in simulate(repo, commits, [e if e and e[1] == b else None for e in (evs[s] for s, _ in commits)])[2]})
    return out


def same_file(a, b):
    """Mesmo arquivo pelo inode (hardlink, APFS sem maiúscula) ou, se algum não existe ainda ou a leitura falha, pelo caminho resolvido (um Write recria o que sumiu)."""
    try:
        return os.path.samefile(a, b)
    except OSError:
        return os.path.realpath(a) == os.path.realpath(b)


def guard_cmd(text, who):
    """Motor do hook -> (rc, stderr). rc 2 só com o arquivo TRAVADO; dúvida é 0 (o hook só atrapalha, quem recusa de verdade é o gate) com «UNGUARDED …» para o wrapper contar."""
    try:
        p = json.loads(text)
    except ValueError:
        return 0, "UNGUARDED payload do hook não é JSON"
    p = p if isinstance(p, dict) else {}
    ti = p.get("tool_input") if isinstance(p.get("tool_input"), dict) else {}
    path = ti.get("file_path") or ti.get("notebook_path")
    if p.get("tool_name") not in EDIT_TOOLS or not isinstance(path, str) or not path:
        return 0, ""
    target = path if os.path.isabs(path) else os.path.join(p["cwd"] if isinstance(p.get("cwd"), str) else os.getcwd(), path)
    d = os.path.dirname(target)
    while d and not os.path.isdir(d) and os.path.dirname(d) != d:
        d = os.path.dirname(d)  # Write pode criar a pasta: sobe até a que existe
    try:
        top = gt(d, "rev-parse", "--show-toplevel")
        base = base_of(top)
        if base is None:
            return 0, "UNGUARDED não achei origin/main nem main em %s" % top
        locked = locked_now(top, base) if has_lock(top, base, "HEAD") else {}
    except Cant as e:
        return 0, "UNGUARDED %s" % e
    for f, bead in sorted(locked.items()):
        if same_file(target, os.path.join(top, f)):
            return 2, ("%s — «%s» está TRAVADO pela bead %s: é o teste que reproduz o bug, e afrouxá-lo junto com o conserto não prova que o bug sumiu. NÃO repita a chamada e NÃO contorne por Bash (sed -i, tee, git checkout): o gate "
                       "compara o teste do tip com o commit da trava e recusa a submissão (passo 2f).\nConserte o CÓDIGO; mais casos vão em OUTRO arquivo de teste; defeito REAL do teste: %s release %s --reason \"<o que está errado, %d+ caracteres>\" (o motivo vai à bead e ao revisor) e só então edite." % (BLOCKED, f, bead, who, bead, MIN_REASON))
    return 0, ""


def die(msg, rc=2):
    sys.stderr.write("repro-lock: %s\n" % msg)
    return rc


def run_repro(top, cmd, timeout):
    """(rc, cauda). falhou (estouro, bash ausente) → Cant: «não consegui rodar» nunca é «reproduz». No estouro mata o GRUPO: um neto (xdist) segurando o pipe travaria o communicate()."""
    try:
        proc = subprocess.Popen(["bash", "-c", cmd], cwd=top, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, 9)
        proc.communicate()
        raise Cant("a reprodução passou de %ds e foi interrompida: não sei se reproduz" % timeout)
    except (OSError, subprocess.SubprocessError) as e:
        raise Cant("a reprodução não rodou: %s" % e)
    return proc.returncode, "\n".join([ln[:200] for ln in out.decode("utf-8", "replace").splitlines() if ln.strip()][-12:])[-1500:]


def cmd_lock(a):
    top = gt(os.getcwd(), "rev-parse", "--show-toplevel")
    files = []
    for f in a.files:
        rel = os.path.relpath(os.path.realpath(os.path.join(os.getcwd(), f)), os.path.realpath(top)).replace(os.sep, "/")
        if not safe_rel(rel) or not os.path.isfile(os.path.join(top, rel)):
            return die("%r não é arquivo regular dentro do repo (ou o nome não cabe num trailer)" % f)
        files += [rel] if rel not in files else []
    t = bead_type(a.bead)  # bd que cai → Cant → «NÃO SEI», nada travado: o estado inerte
    if t != "bug":
        return die("a bead %s é do tipo %r: a trava vale só para bead tipo bug" % (a.bead, t))
    if not gt(top, "status", "--porcelain", "--", *files):
        return die("nenhum arquivo tem mudança nova: a trava é o commit que ADICIONA ou ALTERA o teste")
    base = base_of(top)
    if base is None:
        return die("NÃO SEI: não achei origin/main nem main para conferir que o teste é o 1º commit da branch")
    if list_commits(top, base, "HEAD"):
        return die("a branch já tem commit à frente de origin/main: o teste tem de ser o 1º commit, antes de qualquer conserto")
    rc, tail = run_repro(top, a.cmd, a.timeout)
    if rc == 0:
        return die("a reprodução PASSA no código de hoje: não reproduz o bug:\n%s" % tail)
    if (not re.search(a.expect, tail)) if a.expect else WRONG.search(tail):
        return die("a reprodução falhou (rc %d), mas %s.\n%s" % (rc, "a saída não casa --expect %r" % a.expect if a.expect else "parece falha de AMBIENTE ou de coleta, não do bug: confirme o motivo com --expect '<regex da asserção>'", tail))
    git(top, "add", "--", *files)
    msg = "test(%s): reproduz o bug antes do conserto (trava de teste)\n\n%s\n" % (a.bead, "\n".join(["%s: %s" % (LOCK, a.bead)] + ["%s: %s" % (FILE, f) for f in files]))
    git(top, "commit", "-q", "-F", "-", "--", *files, stdin=msg.encode())  # `-- <arquivos>`: o commit leva SÓ os testes, o que mais estiver no índice fica de fora
    sha = gt(top, "rev-parse", "HEAD")
    try:
        bd("comment", a.bead, "[repro-lock] TRAVADO: %s @ %s. O teste que reproduz o bug entrou ANTES do conserto e não pode mudar (o gate compara o commit da trava). Reprodução: `%s` saiu com rc=%d (falha no código de hoje)." % (", ".join(files), sha[:7], a.cmd, rc))
    except Cant as e:
        sys.stderr.write("repro-lock: AVISO — não consegui comentar na bead (%s); comente você\n" % e)
    print("repro-lock: travado %s @ %s (bead %s). Conserte o CÓDIGO; o hook recusa editar o teste e o gate compara o commit." % (", ".join(files), sha[:7], a.bead))
    return 0


def cmd_release(a):
    reason = " ".join(a.reason.split())[:MAX_REASON]
    if len(reason) < MIN_REASON:
        return die("--reason precisa de pelo menos %d caracteres: diga o que está errado no teste (o revisor lê isto)" % MIN_REASON, 64)
    top = gt(os.getcwd(), "rev-parse", "--show-toplevel")
    bd("comment", a.bead, "[repro-lock] LIBERADA a trava da bead. Motivo: %s" % reason)  # a bead é o registro que o revisor lê: sem o comentário gravado NADA é liberado (Cant sai antes)
    head = gt(top, "rev-parse", "HEAD")
    msg = "chore(%s): libera a trava de teste (motivo registrado)\n\n%s: %s\n%s: %s\n" % (a.bead, REL, a.bead, WHY, reason)
    new = git(top, "commit-tree", gt(top, "rev-parse", "HEAD^{tree}"), "-p", head, "-F", "-", stdin=msg.encode()).decode().strip()
    git(top, "update-ref", "-m", "repro-lock: release", "HEAD", new, head)
    print("repro-lock: trava da bead %s LIBERADA em %s; o motivo está na bead e no commit, e o gate o mostra ao revisor." % (a.bead, new[:7]))
    return 0


def cmd_check(a):
    if not (SHA.match(a.base) and SHA.match(a.head) and BEAD.match(a.bead)):
        return die("check: base/head precisam ser sha em hexadecimal e a bead um id válido", 64)
    flag = os.path.join(os.environ.get("GC_CITY_PATH", "/nonexistent"), ".gc", "repro-lock-check.off")
    if os.environ.get("REPRO_LOCK_CHECK") == "off" or os.path.exists(flag):
        print("NOTE: repro-lock-check: is switched OFF (%s); nothing was checked" % ("REPRO_LOCK_CHECK=off" if os.environ.get("REPRO_LOCK_CHECK") == "off" else flag))
        return 0
    try:
        r = analyze(a.repo, a.base, a.head, a.bead)
    except Cant as e:
        print("repro-lock-check: verdict=nao-sei reason=leitura-falhou locks=- files=- releases=-\n  %s" % str(e)[:200])
        return 2
    print("repro-lock-check: verdict=%s reason=%s locks=%d files=%d releases=%d" % (r["verdict"], r["reason"], r["locks"], r["files"], r["releases"]))
    for ln in r["lines"][:MAX_LINES]:  # o texto é do construtor: sem controle, e < > viram aspas angulares (a cerca <conteudo_externo> do comentário no marcador não fecha por dentro)
        print("  " + re.sub(r"[\x00-\x1f]", " ", ln).replace("<", "‹").replace(">", "›")[:200])
    return 1 if r["verdict"] == "fail" else 0


def cmd_guard(a):
    try:
        rc, err = guard_cmd(sys.stdin.read(), "python3 %s" % os.path.abspath(__file__))
    except (OSError, ValueError) as e:  # vazio/ilegível → UNGUARDED (rc 0, contado no log pelo wrapper), nunca bloqueio
        rc, err = 0, "UNGUARDED stdin ilegível: %s" % e
    sys.stderr.write(err + "\n" if err else "")
    return rc


def main(argv=None):
    import argparse  # só a linha de comando precisa; o hook entra por cmd_guard
    ap = argparse.ArgumentParser(prog="repro-lock", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="sub", required=True)
    p = sub.add_parser("lock", help="commita o teste que reproduz o bug e o trava")
    p.add_argument("bead")
    p.add_argument("files", nargs="+")
    p.add_argument("--cmd", required=True, help="comando que roda o teste; tem de FALHAR no código de hoje")
    p.add_argument("--expect", help="regex que a saída da falha tem de casar (o motivo certo)")
    p.add_argument("--timeout", type=int, default=900)
    p.set_defaults(fn=cmd_lock)
    p = sub.add_parser("release", help="saída de emergência: libera a trava com motivo registrado")
    p.add_argument("bead")
    p.add_argument("--reason", required=True)
    p.set_defaults(fn=cmd_release)
    p = sub.add_parser("check", help="a checagem do gate (passo 2f do gate-hard-checks.sh)")
    for k in ("repo", "base", "head", "bead"):
        p.add_argument("--" + k, required=True)
    p.set_defaults(fn=cmd_check)
    sub.add_parser("guard", help="motor do hook PreToolUse (payload JSON no stdin)").set_defaults(fn=cmd_guard)
    a = ap.parse_args(argv)
    if a.sub in ("lock", "release") and not BEAD.match(a.bead):
        return die("id de bead inválido: %r" % a.bead, 64)
    try:
        return a.fn(a)
    except Cant as e:
        return die("NÃO SEI: %s" % e)


if __name__ == "__main__":
    sys.exit(main())
