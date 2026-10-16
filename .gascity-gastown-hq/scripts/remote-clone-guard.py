#!/usr/bin/env python3
"""remote-clone-guard.py — substituto, no SERVIDOR Hetzner, do `gt tap guard cross-clone-block` do mini (ga-2hd02v.1.5; decisão Q4 do
Mayor: sessão remota só é liberada depois que existir um substituto). Hook PreToolUse (Bash, Edit, Write, MultiEdit, NotebookEdit).

Contents
  Para que serve · Como decide · Códigos · Limites

PARA QUE SERVE
  Uma sessão escreve no PRÓPRIO clone (o worktree `~/gt-remote/git/<rig>/wt/<bead>`) e em mais nada daquele território. Escrita de git
  (`git -C <outro clone> commit/push/merge/rebase/reset…`) ou de arquivo (Edit/Write) no clone de OUTRA sessão, ou no espelho (`repo.git`),
  é bloqueada com uma mensagem clara. Leitura (log/status/diff/show…) e escrita no próprio clone seguem livres. Vale sob
  `--dangerously-skip-permissions`: um hook que sai com 2 bloqueia a chamada em qualquer modo (medido no servidor, ver o runbook).

COMO DECIDE (os três estados — sei que pode / sei que não pode / não sei — e o último NÃO vira "pode")
  Território = $RCG_ROOT, senão ~/gt-remote/git. Clone próprio = o ancestral com `.git` de $CLAUDE_PROJECT_DIR (sem a variável: não há clone
  próprio, e toda escrita no território é bloqueada). Para cada `git` do comando (depois de ; && || | ( ), de cd/pushd, de command/env/
  sudo/xargs/nohup…, de bash -c / eval / $(…) / crases / find -exec) o alvo é o diretório depois dos `-C` (relativos entre si), mais
  --git-dir/--work-tree/GIT_DIR/GIT_WORK_TREE, resolvido com realpath (symlink para outro clone não escapa). Subcomando que não está na
  lista de LEITURA (inclusive o que não conheço, alias…) conta como escrita. Alvo no território e fora do clone próprio → bloqueia; alvo
  que não consigo resolver ($VAR, glob, crase, ~usuário) numa escrita → bloqueia, com a mensagem dizendo para usar caminho literal.
  Falha do próprio guarda (JSON ruim, exceção) → bloqueia: o comando do hook é `python3 -I <este arquivo> || exit 2`, então travar,
  sumir o python ou o arquivo também sai com 2 (o hook que sai com 1 ou 127 NÃO bloqueia: seria falha aberta).

CÓDIGOS: 0 liberado · 2 bloqueado. `--selfcheck [settings.json [pasta-do-projeto…]]`: 0 se o guarda decide como deveria numa pasta de teste E
  (com o settings) todo PreToolUse de Bash/Edit/Write/MultiEdit/NotebookEdit chama ESTE arquivo com `|| exit 2` e `disableAllHooks` não está
  ligado nele nem em <pasta>/.claude/settings[.local].json; 1 caso contrário (é o que o provider confere antes de abrir sessão real).
  Edit/Write em ~/.claude/hooks/** e ~/.claude/settings*.json também são bloqueados (o guarda não se desliga por engano).

LIMITES (é trava contra engano, não sandbox contra quem quer burlar): script que o comando executa (`bash x.sh`), `python -c`, `source`,
  variável que guarda o git, e redirecionamento de shell (`> arquivo`), `sed -i`, `rm`/`cp` no clone alheio ou nos hooks não são vistos. O fecho de verdade
  (usuário Unix por sessão) é outro trabalho; ver o runbook.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import sys
import tempfile

TOOLS_FILE = {"Edit": "file_path", "Write": "file_path", "MultiEdit": "file_path", "NotebookEdit": "notebook_path"}
READ = {"log", "status", "diff", "show", "rev-parse", "rev-list", "ls-files", "ls-tree", "cat-file", "blame", "describe", "shortlog",
        "grep", "show-ref", "for-each-ref", "name-rev", "merge-base", "diff-tree", "diff-index", "diff-files", "ls-remote", "whatchanged",
        "check-ignore", "count-objects", "fsck", "version", "help", "var", "cherry", "range-diff", "show-branch", "annotate", ""}
LIST_FLAGS = {"branch": {"-l", "--list", "-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose", "--show-current"},
              "tag": {"-l", "--list", "-n"}}
WRITES = re.compile(r"--(?:output|lost-found|open-files-in-pager|ext-diff)(?:=|$)|-O")  # flag de comando de LEITURA que grava arquivo ou roda programa
PUNCT, SEPS = set("();<>|&"), {";", "&&", "||", "|", "&", "|&", ";;"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
WRAP = {"command", "builtin", "exec", "nohup", "time", "env", "sudo", "doas", "xargs", "nice", "timeout", "stdbuf", "setsid"}
OPT_ARG = {"-I", "-n", "-L", "-P", "-d", "-s", "-E", "-u", "-g", "-C", "-D", "--chdir"}  # opções de xargs/sudo/env que levam o valor no argumento seguinte
ASSIGN, NUM = re.compile(r"([A-Za-z_]\w*)=(.*)", re.S), re.compile(r"\d+[smhd]?")
SHELLY = re.compile(r"[$`*?\[{]")
PIECE = re.compile(r"&&|\|\||\|&|;;|[;&|()]|[<>]+&?")
SUBST, BACKTICK = re.compile(r"\$S([0-9a-f]*)\$"), re.compile(r"`([^`]*)`")
HEREDOC = re.compile(r"(<<-?\s*(['\"]?)(\w+)\2[^\n]*)\n(.*?)\n[ \t]*\3[ \t]*(?=\n|$)", re.S)


def inside(p: str, root: str) -> bool:
    return p == root or p.startswith(root.rstrip("/") + "/")


def res(p: str, cwd, shell: bool = True):
    """Caminho absoluto real, ou None = não sei (variável, glob, crase, ~usuário, ou relativo sem saber o diretório)."""
    if shell and (SHELLY.search(p) or p == "-"):
        return None
    if p == "~" or p.startswith("~/"):
        p = os.path.expanduser("~") + p[1:]
    elif p.startswith("~"):
        return None
    if cwd is None and not p.startswith("/"):
        return None
    return os.path.realpath(os.path.join(cwd or "/", p))


def own_clone(proj, terr: str):
    p = os.path.realpath(proj) if proj else ""
    while p and inside(p, terr) and p != terr:
        if os.path.exists(os.path.join(p, ".git")):
            return p
        p = os.path.dirname(p)
    return None


def claude_conf(p: str) -> bool:
    """Hook ou settings do claude no HOME: quem os escreve desliga este guarda (o provider só os confere na ABERTURA da sessão)."""
    h = os.path.realpath(os.path.expanduser("~")) + "/.claude/"
    return p.startswith(h) and bool(re.fullmatch(r"hooks/.*|settings[^/]*\.json", p[len(h):]))


def is_read(sub: str, rest: list) -> bool:
    if any(WRITES.match(t) for t in rest):
        return False
    if sub in READ:
        return True
    if sub in LIST_FLAGS:
        return all(t in LIST_FLAGS[sub] for t in rest)
    first = rest[0] if rest else ""
    return ((sub == "stash" and first in ("list", "show")) or (sub == "worktree" and first == "list") or (sub == "reflog" and first in ("", "show"))
            or (sub == "notes" and first in ("list", "show")) or (sub == "remote" and (rest in ([], ["-v"]) or rest[:1] in (["show"], ["get-url"]) or rest[:2] in (["-v", "show"], ["-v", "get-url"])))
            or (sub == "config" and any(t in ("--get", "--get-all", "--get-regexp", "--list", "-l") for t in rest)))


def hide(cmd: str) -> str:
    """Cada $( ) e crase vira UMA palavra opaca `$S<hex do miolo>$`: o shlex não as abre, e `one` confere o miolo no diretório certo."""
    cmd, out, i = BACKTICK.sub(r"$(\1)", cmd), [], 0
    while (j := cmd.find("$(", i)) >= 0:
        d, k = 1, j + 2
        while k < len(cmd) and d:
            d, k = d + (cmd[k] == "(") - (cmd[k] == ")"), k + 1
        out += [cmd[i:j], "$S" + cmd[j + 2:k - (d == 0)].encode().hex() + "$"]
        i = k
    return "".join(out) + cmd[i:]


def heredoc(m) -> str:
    """O corpo de um heredoc é texto (cita comandos, tem apóstrofo) e some; só o $( ) de um delimitador SEM aspas roda, e fica."""
    return m.group(1) + ("" if m.group(2) else "\n: " + " ".join(x.group(0) for x in SUBST.finditer(hide(m.group(4)))))


def words(cmd: str) -> list:
    cmd = hide(HEREDOC.sub(heredoc, cmd)).replace("\n", " ; ")  # newline separa comandos
    try:
        lx = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lx.whitespace_split, lx.commenters = True, ""
        return list(lx)
    except ValueError:  # aspas que não fecham: o sh é quem vai dizer; aqui só não há como conferir por tokens, então separa na marra
        return re.findall(r"[^\s;&|()]+|[;&|()]+", cmd.replace("'", "").replace('"', ""))


def peel(seg: list):
    """Tira atribuições (VAR=x) e embrulhos (command, env, sudo, xargs…) do começo: devolve (atribuições, o comando de verdade, cego).
    cego = uma opção do embrulho (env -C/-S/--chdir, sudo -D) muda onde o comando roda e o guarda não a modela: o diretório vira "não sei"."""
    env: dict = {}
    blind = False
    while seg:
        m = ASSIGN.fullmatch(seg[0])
        if m:
            env[m.group(1)], seg = m.group(2), seg[1:]
        elif os.path.basename(seg[0]) in WRAP:
            seg = seg[1:]
            while seg and (seg[0].startswith("-") or ASSIGN.fullmatch(seg[0]) or NUM.fullmatch(seg[0])):
                m = ASSIGN.fullmatch(seg[0])
                if m:  # `env GIT_DIR=x git …` também aponta o git para outro lugar
                    env[m.group(1)] = m.group(2)
                blind = blind or seg[0][:2] in ("-C", "-D", "-S") or seg[0].startswith(("--chdir", "--split-string"))
                seg = seg[2:] if seg[0] in OPT_ARG else seg[1:]
        else:
            break
    return env, seg, blind


def git_hit(seg: list, env: dict, cwd, terr: str, own):
    gd, wt, i = env.get("GIT_DIR"), env.get("GIT_WORK_TREE"), 1
    while i < len(seg) and seg[i].startswith("-"):
        a = seg[i]
        if a == "-C" and i + 1 < len(seg):
            cwd, i = res(seg[i + 1], cwd), i + 2
        elif a in ("-c", "--config-env", "--namespace") and i + 1 < len(seg):
            i += 2
        elif a.startswith(("--git-dir", "--work-tree")):
            k, _, v = a.partition("=")
            if not v and i + 1 < len(seg):
                v, i = seg[i + 1], i + 1
            gd, wt = (v, wt) if k == "--git-dir" else (gd, v)
            i += 1
        else:
            i += 1
    sub, rest = (seg[i] if i < len(seg) else ""), seg[i + 1:]
    if is_read(sub, rest):
        return None
    for t in [cwd] + [res(x, cwd) for x in (gd, wt) if x]:
        if t is None or (inside(t, terr) and not (own and inside(t, own))):
            return t, "git " + sub
    return None


def scan(cmd: str, cwd, terr: str, own, depth: int = 0):
    """O 1º (alvo, operação) de escrita contra clone alheio no comando, ou None. alvo None = não consegui resolver."""
    if depth > 3:
        return None, "comando aninhado fundo demais para conferir"
    st, stack, seg = {"cwd": cwd, "env": {}}, [], []

    def one(seg: list, blind: bool = False):
        for w in seg:  # $(…) e crases dentro de qualquer palavra rodam (até no valor de VAR=…): confere o miolo
            for m in SUBST.finditer(w):
                r = scan(bytes.fromhex(m.group(1)).decode(), st["cwd"], terr, own, depth + 1)
                if r:
                    return r
        env, seg, b = peel(seg)
        blind = blind or b
        if not seg:
            st["env"].update(env)  # `GIT_DIR=x; git …`: sem saber se foi exportada, vale para os comandos seguintes
            return None
        cwd, c = None if blind else st["cwd"], os.path.basename(seg[0])
        if " " in seg[0]:  # env -S 'git -C x commit': um comando inteiro numa palavra só
            return scan(" ".join(seg), cwd, terr, own, depth + 1)
        if c in ("export", "declare", "typeset"):
            st["env"].update({m.group(1): m.group(2) for m in map(ASSIGN.fullmatch, seg[1:]) if m})
        elif c in ("cd", "pushd"):
            st["cwd"] = res(seg[1] if len(seg) > 1 else "~", st["cwd"])
        elif c == "popd":
            st["cwd"] = None
        elif c in SHELLS:
            for j, t in enumerate(seg[1:-1], 1):
                if re.fullmatch(r"-[a-z]*c[a-z]*", t):
                    return scan(seg[j + 1], cwd, terr, own, depth + 1)
        elif c == "eval":
            return scan(" ".join(seg[1:]), cwd, terr, own, depth + 1)
        elif c == "find":
            for j, t in enumerate(seg):
                if t in ("-exec", "-execdir", "-ok", "-okdir"):
                    r = one(seg[j + 1:], blind)
                    if r:
                        return r
        elif c == "git":
            return git_hit(seg, {**st["env"], **env}, cwd, terr, own)
        return None

    skip = False
    for tok in words(cmd) + [";"]:
        if skip:  # alvo de redirecionamento
            skip = False
        elif set(tok) <= PUNCT:  # o shlex junta pontuação colada (`);`, `&&(`, `2>&1`): separa de novo
            for pc in PIECE.findall(tok):
                if pc in SEPS or pc in ("(", ")"):
                    r = one(seg)
                    if r:
                        return r
                    seg = []
                    if pc == "(":
                        stack.append(st["cwd"])
                    elif pc == ")" and stack:
                        st["cwd"] = stack.pop()
                else:
                    skip = True  # redirecionamento: a palavra seguinte é o arquivo
        else:
            seg.append(tok)
    return None


def decide(inp: dict, terr: str, proj):
    """None = liberado; (alvo, operação) = bloqueado."""
    tool, ti, cwd = inp.get("tool_name"), inp.get("tool_input") or {}, inp.get("cwd") or None
    own = own_clone(proj, terr)
    if tool == "Bash":
        return scan(str(ti.get("command") or ""), os.path.realpath(cwd) if cwd else None, terr, own)
    if tool in TOOLS_FILE:
        p = res(str(ti.get(TOOLS_FILE[tool]) or ""), os.path.realpath(cwd) if cwd else None, shell=False)
        if p is None or claude_conf(p) or (inside(p, terr) and not (own and inside(p, own))):
            return p, "escrita de arquivo (" + tool + ")" + (" em hook/settings do claude" if p and claude_conf(p) else "")
    return None


def message(hit, terr: str, proj) -> str:
    target, op = hit
    own = own_clone(proj, terr)
    why = (f"Alvo: {target}\n" if target else "Alvo: não consegui resolver o caminho (variável, glob, crase ou ~usuário)\n")
    return ("[HOOK BLOCK: remote-clone-guard] NÃO É CANCELAMENTO DO USUÁRIO — política automática de isolamento entre sessões.\n"
            f"BLOQUEADO: {op} fora do seu clone.\n{why}Seu clone: {own or '(nenhum: CLAUDE_PROJECT_DIR fora do território ' + terr + ')'}\n"
            "Cada sessão escreve só no PRÓPRIO worktree; o clone de outra sessão, o espelho (repo.git) e os hooks/settings do claude não são seus. Para publicar: faça "
            "commit no seu worktree e dê push da sua branch (worker/<bead>). Se o caminho tem variável ou glob, use o caminho literal.\n"
            "Leitura continua liberada: git -C <outro clone> log / status / diff / show.\n")


def selfcheck(args: list) -> int:
    ok = True
    with tempfile.TemporaryDirectory() as d:
        d = os.path.realpath(d)
        terr = d + "/git"
        for c in ("own", "other"):
            os.makedirs(f"{terr}/r/wt/{c}")
            open(f"{terr}/r/wt/{c}/.git", "w").close()
        proj = terr + "/r/wt/own"
        for tool, ti, want in (("Bash", {"command": f"git -C {terr}/r/wt/other commit -m x"}, True),
                               ("Bash", {"command": f"git -C {terr}/r/wt/other log"}, False),
                               ("Bash", {"command": "git commit -m x"}, False),
                               ("Write", {"file_path": terr + "/r/wt/other/f"}, True),
                               ("Write", {"file_path": proj + "/f"}, False)):
            got = decide({"tool_name": tool, "tool_input": ti, "cwd": proj}, terr, proj) is not None
            if got != want:
                ok = False
                print(f"selfcheck: {tool} {ti}: bloqueou={got}, deveria={want}", file=sys.stderr)
    if args:
        me = os.path.abspath(__file__)
        try:
            s = json.load(open(args[0]))
            groups = (s.get("hooks") or {}).get("PreToolUse") or []
            if s.get("disableAllHooks"):
                raise ValueError("disableAllHooks ligado")
            for d in args[1:]:  # a camada do PROJETO (a pasta da sessão) também pode ligar disableAllHooks: ausente = nada a conferir; ilegível = falha
                for f in (os.path.join(d, ".claude", n) for n in ("settings.json", "settings.local.json")):
                    if os.path.exists(f) and json.load(open(f)).get("disableAllHooks"):
                        raise ValueError(f"{f}: disableAllHooks ligado na camada do projeto")
            for tool in ("Bash",) + tuple(TOOLS_FILE):
                if not any((g.get("matcher") in (None, "", "*") or re.fullmatch(g["matcher"], tool)) and any(me in h.get("command", "") and h["command"].endswith("|| exit 2")
                                                                              for h in g.get("hooks", [])) for g in groups):
                    raise ValueError(f"{tool}: nenhum hook PreToolUse chama {me} com `|| exit 2`")
        except (OSError, ValueError, AttributeError, KeyError, TypeError, re.error) as e:
            ok = False
            print(f"selfcheck: settings {args[0]}: {e}", file=sys.stderr)
    print("selfcheck: " + ("ok" if ok else "FALHOU"))
    return 0 if ok else 1


def main(argv: list) -> int:
    if argv[1:2] == ["--selfcheck"]:
        return selfcheck(argv[2:])
    raw = sys.stdin.read()
    terr = os.path.realpath(os.environ.get("RCG_ROOT") or os.path.expanduser("~/gt-remote/git"))
    proj = os.environ.get("CLAUDE_PROJECT_DIR")
    try:
        hit = decide(json.loads(raw), terr, proj)
    except Exception as e:  # noqa: BLE001 — falha do guarda não pode virar "liberado" quando o pedido pode tocar git ou arquivo
        if not re.search(r"git|file_path|notebook_path", raw):
            return 0
        print(f"[HOOK BLOCK: remote-clone-guard] o guarda falhou ({type(e).__name__}) e não consigo conferir este pedido: bloqueado.", file=sys.stderr)
        return 2
    if hit:
        print(message(hit, terr, proj), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
