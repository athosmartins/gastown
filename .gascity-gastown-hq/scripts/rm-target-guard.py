#!/usr/bin/env python3
r"""rm-target-guard.py — hook PreToolUse (Bash) que recusa REMOVER o que não é descartável, julgando o ALVO e não a grafia do comando (ga-id0im4e).
Nasceu da medição de ga-nkfwixz (docs/runbooks/guard-oracle-diff.md, seção 3): a regra `Bash(rm -rf:*)` casa TEXTO e só barrou 2 de 7 grafias (`bash -c`, `env`); `rm -fr`,
`rm -r -f`, `rm --recursive --force`, `/bin/rm -rf` e `subprocess.run(['rm','-rf',X])` rodaram. DORMENTE: nenhum settings.json chama este arquivo; ligar (e trocar a regra
de prefixo por ele) é decisão do Mayor — trecho, política e medição em docs/runbooks/rm-target-guard.md.

Contents
  Para que serve · Como decide · Códigos · Limites
PARA QUE SERVE
  Um agente (ou um texto injetado que ele leu) não apaga dado do Dolt, `.git`, o HOME, a raiz de um repo nem a pasta de /tmp que outras sessões usam, seja qual for a ordem das
  flags ou o embrulho (`env`, `sudo`, `timeout`, `bash -c`, `eval`, `find -delete`, `xargs`, `python -c`). Limpar scratch continua livre: `rm -rf /tmp/x` passa. Hook que sai 2 bloqueia em
  qualquer modo, `--dangerously-skip-permissions` incluso. A regra de prefixo `Bash(rm -rf:*)` trava pool sem humano (ask) ou nega até o scratch (deny, nó): este guard a substitui.
COMO DECIDE
  O texto é lido como o bash lê (aspas, `$'…'`, comentário, heredoc, `$( )`, crase, `cd`, `VAR=`, `for`), os embrulhos saem, e cada `rm`/`unlink`/`rmdir`/`shred` tem as opções
  normalizadas (`-fr`, `-r -f`, `--recur`, `--`, opção depois do operando): sobram os OPERANDOS, resolvidos (`~`, `$HOME`, cwd, chave `{a,b}`, glob que EXISTE) e julgados em duas formas, o
  texto e o `realpath` (link simbólico): vale a pior. Proibido: componente `.dolt` `.dolt-data` `.beads` `.git` `.gc-worktrees` `crew` (a trava velha `.git/*.lock` sai), `/` e pasta de 1º nível, o
  HOME e seus ancestrais, pasta DIRETA do HOME apagada por inteiro, `~/Library/CloudStorage`, `~/gt/*/shared/data`, a raiz de /tmp e as pastas compartilhadas (`claude-<uid>`,
  `claude-<uid>/<projeto>`, `tmux-*`), pasta de sistema, pasta que é raiz de repo git (worktree ou bare) ou guarda um até 2 níveis abaixo, curinga que esvazia (`*`, `.*`) uma delas. Livre:
  /tmp, /var/tmp, o scratchpad da sessão, `~/.cache`, `node_modules`, `__pycache__`, `*.pyc` e o resto do trabalho (`rm -rf build`). `find … -delete|-exec rm` julga as raízes (com filtro de
  nome com ao menos 1 caractere literal só valem as regras absolutas e a de Dolt/repo bare); `xargs rm` com operando vindo do pipe, alvo que não resolvo (variável solta, `$( )`) ou verbo que não resolvo com
  flag recursiva, numa remoção RECURSIVA = bloqueado (estado inerte). Só `&&` fixa o cwd depois de um `cd`; com `;` `||` `&` valem o cwd velho E o novo (o `cd` pode ter falhado).
CÓDIGOS: 0 liberado · 2 bloqueado. Falha do próprio guarda num pedido Bash = bloqueado (nunca "liberado"). Texto acima de MAX_CMD (256 KB) = bloqueado: não dá para conferir.
LIMITES (trava contra engano, não sandbox): não vejo script que o comando executa (`bash x.sh`), alias/função de fora, caminho montado em pedaços, `shutil.rmtree(variável)`, `rsync --delete`,
  `git clean`, `mv x /dev/null`, nem o que um programa apaga sozinho. Código inline só vale se cita verbo de remoção e um literal de caminho (ou `['rm','-rf',x]`).
"""
from __future__ import annotations

import glob
import json
import os
import re
import sys
import unicodedata

UNK = "\x00"  # "não sei": pedaço de caminho que o guarda não resolve (variável solta, substituição, ~usuário)
MAX_CMD = 262144  # acima disto o leitor não roda e o pedido é bloqueado: texto que não dá para conferir não vira "liberado"
GLOB_MAX = 20000  # curinga com mais achados que isto: o resto vale como alvo que não conheço
LS_BUDGET = 20000  # entradas de pasta lidas por julgamento (2 níveis); estourou = a pasta vale como se guardasse um repo
RM_TEXT = re.compile(r"(?<![\w.-])(?:rm|unlink|rmdir|shred|rimraf)(?![\w-])|-delete|rmtree")
RM_VERBS = {"rm", "unlink", "rmdir", "shred", "rimraf"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "ash"}
INTERP = re.compile(r"(?:python[\d.]*|node(?:js)?|perl|ruby|php|lua|deno|bun|awk|gawk|mawk)")
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "{", "}", "!", "coproc", "function"}
OPAQUE = {"chrt", "taskset", "parallel", "su", "runuser", "script", "trap", "watch", "unshare", "nsenter", "chroot", "setpriv", "numactl", "caffeinate", "unbuffer", "ssh"}
WRAP = {"env": ("-u -C -S --unset --chdir --split-string", 0), "command": ("", 0), "builtin": ("", 0), "exec": ("-a", 0), "nohup": ("", 0), "time": ("-f -o --format --output", 0),
        "timeout": ("-s -k --signal --kill-after", 1), "nice": ("-n --adjustment", 0), "ionice": ("-c -n -p --class --classdata", 0), "setsid": ("", 0), "stdbuf": ("-i -o -e", 0),
        "sudo": ("-u -g -C -D -h -p -r -t -T -U --user --group", 0), "doas": ("-u -C", 0), "flock": ("-w -E --timeout", 1), "busybox": ("", 0), "toybox": ("", 0), "npx": ("-p -c --package", 0),
        "strace": ("-o -e -p -s -u -E -a -b -I -O -P -X", 0), "ltrace": ("-o -e -p -s -u -a -b -I -n", 0)}
XARGS_VAL = {"-I", "-n", "-P", "-L", "-d", "-E", "-s", "-a", "--max-args", "--max-procs", "--max-lines", "--delimiter", "--eof", "--max-chars", "--arg-file", "--replace"}
SELECT = {"-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-regex", "-iregex", "-lname", "-ilname"}  # testes de NOME: só eles filtram de verdade (-mtime, -size… casam quase tudo)
ASSIGN = re.compile(r"[A-Za-z_]\w*=")
VAR = re.compile(r"\$(?:(\w+)|\{(\w+)\})")
MASS = re.compile(r"\.?\*|\.\[!\.\]\*|\.\?\*|\.\.\?\*|\?\*")  # último pedaço de um curinga que casa TUDO da pasta (`*`, `.*`, `.[!.]*`)

# --- catálogo (espelha a lista NEGA/PERMITE do safe-clean, aprovada pelo Athos em 15/08, ga-gkap9p) ---
DENY_COMP = {".dolt": "rm.dolt", ".dolt-data": "rm.dolt", ".beads": "rm.dolt", ".git": "rm.git", ".gc-worktrees": "rm.worktrees", "crew": "rm.crew"}
ALLOW_COMP = {"node_modules", "__pycache__", ".pytest_cache"}
ALLOW_HOME = ((".cache",), (".npm", "_cacache"), ("Library", "Caches", "go-build"))
SCRATCH = ("/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/dev/shm", "/private/var/folders")
SYSTEM = {x.casefold() for x in ("etc", "usr", "var", "bin", "sbin", "lib", "lib32", "lib64", "boot", "opt", "System", "Library", "Applications", "private", "Volumes", "dev", "proc", "sys", "mnt", "media", "srv", "root", "run", "snap", "home", "Users")}
RULES = {
    "rm.dolt": "dados do Dolt/beads (.dolt, .dolt-data, .beads): apagar derruba o plano de dados da cidade", "rm.git": "histórico de um repo (.git)",
    "rm.worktrees": "worktrees da cidade (.gc-worktrees): podem guardar trabalho de crew sem entregar", "rm.crew": "clone de crew (crew/): trabalho de agente sem entregar",
    "rm.root": "raiz do sistema de arquivos ou pasta de 1º nível", "rm.home": "o HOME ou um ancestral dele", "rm.home-child": "pasta direta do HOME (~/gt, ~/gt-remote, ~/.claude, ~/.ssh…) apagada por inteiro",
    "rm.cloud": "~/Library/CloudStorage: documentos pessoais do Athos", "rm.rig-data": "~/gt/<rig>/shared/data: dados de produção", "rm.system": "pasta de sistema",
    "rm.shared-tmp": "pasta de /tmp compartilhada com outras sessões (a raiz, claude-<uid>, claude-<uid>/<projeto>, tmux-*)", "rm.repo-root": "raiz de repo git (ou pasta que guarda um): trabalho sem entregar",
    "rm.mass": "curinga que esvazia uma pasta protegida (rm -rf *)", "rm.target-unknown": "alvo que o guarda não consegue resolver (variável solta, substituição) numa remoção recursiva",
    "rm.too-deep": "comando aninhado fundo demais para conferir", "rm.too-big": "comando grande demais para conferir"}
ANSI = re.compile(r"\\(x[0-9a-fA-F]{1,2}|[0-7]{1,3}|u[0-9a-fA-F]{1,4}|U[0-9a-fA-F]{1,8}|c.|.)", re.S)
LIT = re.compile(r"""'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)\"""", re.S)
ARGV = re.compile(r"""\[\s*['"](?:[^'"\n]*/)?(rm|unlink|rmdir|shred|rimraf)['"]\s*,([^\]]*)\]|['"](?:[^'"\n]*/)?(rm|unlink|rmdir|shred|rimraf)['"]\s*,\s*\[([^\]]*)\]""")
ELEM = re.compile(r"""\s*(?:'(?P<s>(?:[^'\\]|\\.)*)'|"(?P<d>(?:[^"\\]|\\.)*)"|(?P<e>[^,\s][^,]*))\s*(?:,|$)""")  # um elemento de lista de argv: literal ou expressão
DEL = re.compile(r"rmtree|remove|unlink|rmdir|rimraf|rmSync|rm_rf|rm_r\b|delete|trash")  # API de remoção: só com ela um literal de caminho solto no código inline conta


def ansi(body: str) -> str:
    """Conteúdo de $'…' como o bash o decodifica (`$'\\x72m'` é `rm`)."""
    def one(m):
        e = m.group(1)
        if e[0] in "xuU":
            return chr(min(int(e[1:], 16), 0x10FFFF))
        if e[0].isdigit():
            return chr(int(e, 8) & 0xFF)
        return chr(ord(e[1]) & 0x1F) if e[0] == "c" and len(e) > 1 else {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v"}.get(e, e)
    return ANSI.sub(one, body)


def home() -> str:
    # vazio → HOME ausente ou vazio cai no expanduser; falhou → expanduser devolve o texto como veio e nenhum caminho começa com ele
    return os.path.normpath(os.environ.get("HOME") or os.path.expanduser("~"))


def tilde(s: str) -> str:
    """`~` e `~/x` viram o HOME; `~usuário` não sei resolver (UNK)."""
    return home() + s[1:] if s == "~" or s.startswith("~/") else (UNK + s if s.startswith("~") else s)


def expand(s: str, cwd, env: dict) -> list:
    """Candidatos de uma palavra depois de $VAR, ${VAR}, $(pwd) e $(mktemp…): lista (a variável de um `for` tem vários valores); o que não sei vira UNK."""
    s = re.sub(r"\$\(\s*pwd\s*\)|`\s*pwd\s*`", "$PWD", s)
    s = re.sub(r"\$\(\s*mktemp\b[^()`]*\)|`\s*mktemp\b[^`]*`", "/tmp/mktemp.x", s)
    outs = [s]
    for _ in range(4):
        nxt, more = [], False
        for t in outs:
            m = VAR.search(t)
            if m is None:
                nxt.append(t)
                continue
            more, name = True, m.group(1) or m.group(2)
            vals = env[name] if name in env else [home()] if name == "HOME" else [cwd] if name == "PWD" and cwd else [UNK]
            nxt += [t[:m.start()] + v + t[m.end():] for v in vals]
        outs = nxt[:64]
        if not more:
            break
    return [UNK if (UNK in t or re.search(r"[$`]", t)) else t for t in outs]


def braces(s: str, depth: int = 3) -> list:
    """Expansão de chave. Passou do teto (16 alternativas, 3 níveis, 64 resultados) levanta OverflowError: quem chama trata como "não sei", nunca corta em silêncio."""
    m = re.search(r"\{([^{}]*,[^{}]*)\}", s)
    if not m:
        return [s]
    alts = m.group(1).split(",")
    out = [r for alt in alts for r in braces(s[:m.start()] + alt + s[m.end():], depth - 1)] if depth and len(alts) <= 16 else None
    if out is None or len(out) > 64:
        raise OverflowError(s)
    return out


def candidates(raw: str, cwds: list, env: dict) -> list:
    """[(caminho absoluto | None = não sei, padrão com curinga | None)] que a palavra pode ser: ~, $VAR, chave, cwd e glob que EXISTE resolvidos."""
    out = []
    for t in expand(raw, cwds[0], env):
        t = tilde(t)
        try:
            bs = [t] if UNK in t else braces(t)
        except OverflowError:
            bs = [UNK]
        for b in bs:
            for cwd in ([None] if os.path.isabs(b) else cwds):
                if UNK in b or (cwd is None and not os.path.isabs(b)):
                    out.append((None, None))
                    continue
                p = os.path.normpath(b if os.path.isabs(b) else os.path.join(cwd, b))
                if re.search(r"[*?\[]", p):
                    # vazio → glob sem resultado: o rm recebe o texto como veio e o padrão vale; falhou/ilegível (permissão, laço de link) → glob devolve [] e o padrão vale
                    hits = sorted(glob.glob(p))
                    out += [(h, p) for h in hits[:GLOB_MAX] or [p]] + ([(None, None)] if len(hits) > GLOB_MAX else [])  # achados além do teto: não os vi, valem como alvo que não conheço
                else:
                    out.append((p, None))
    return out


def ls(d: str, bud: list) -> list:
    # vazio → []; falhou/ilegível (permissão, sumiu no meio) → [] também: o rm não leria o que o guarda não consegue ler. Passou do orçamento → OverflowError (quem chama trata como "guarda")
    try:
        names = sorted(os.listdir(d))
    except (OSError, ValueError):
        return []
    bud[0] -= len(names)
    if bud[0] < 0:
        raise OverflowError(d)
    return names


def marked(d: str, git: bool = True) -> bool:
    # vazio → sem marca; falhou/ilegível → lexists/isfile/isdir dizem não e a pasta segue sem marca. git=False: só dado (Dolt, beads, repo bare), não a árvore de trabalho de um clone
    j = lambda n: os.path.join(d, n)  # noqa: E731
    return any(os.path.lexists(j(m)) for m in ((".git",) if git else ()) + (".dolt", ".beads")) or (os.path.isfile(j("HEAD")) and os.path.isdir(j("objects")) and os.path.isdir(j("refs")))


def holds(d: str, git: bool = True) -> bool:
    """`d` é raiz de repo git (worktree ou bare), .dolt ou .beads, ou guarda um até 2 níveis abaixo (`~/gt-remote/git/gascity` guarda repo.git e wt/<sessão>)? Pasta grande demais para ler
    (LS_BUDGET entradas) vale como "guarda": o estado inerte, nunca "não vi nada"."""
    real = lambda x: os.path.isdir(x) and not os.path.islink(x)  # noqa: E731
    if not os.path.isdir(d):
        return False
    if marked(d, git):
        return True
    bud = [LS_BUDGET]
    kids = lambda x: [n for n in ls(x, bud) if git or n != ".git"]  # noqa: E731 — só dado: o `.git` de um clone (HEAD+objects+refs) parece um repo bare, mas é o clone, não dado
    try:
        return any(real(pa) and (marked(pa, git) or any(real(pb) and marked(pb, git) for pb in (os.path.join(pa, b) for b in kids(pa)))) for pa in (os.path.join(d, a) for a in kids(d)))
    except OverflowError:
        return True


def judge(f: str, rec: bool, selective: bool, pat) -> str | None:
    """Regra que proíbe remover `f` (absoluto, normalizado) ou None. Ordem: componente negado → raiz/HOME → o que é livre → regras por lugar → estrutura."""
    parts = [x for x in f.split("/") if x]
    low = [unicodedata.normalize("NFC", x).casefold() for x in parts]  # APFS/HFS+ ignoram caixa e normalização: `.GIT`, `CREW`, `/USERS` são os mesmos nomes; só NEGAR usa `low`, liberar usa a caixa original
    for i, c in enumerate(low):
        if c in DENY_COMP and not (c == ".git" and i == len(low) - 2 and low[-1].endswith(".lock")):  # `.git/index.lock`: sair de uma trava velha é rotina
            return DENY_COMP[c]
    if len(parts) <= 1:
        return "rm.root"
    hps = [[unicodedata.normalize("NFC", x).casefold() for x in h.split("/") if x] for h in {home(), os.path.realpath(home())}]
    if any(low == hp[:len(low)] for hp in hps):
        return "rm.home"
    k = next((len(hp) for hp in hps if low[:len(hp)] == hp), None)
    rel, relp = (low[k:], parts[k:]) if k is not None else (None, None)
    if rel is not None and rel[:2] == ["library", "cloudstorage"]:
        return "rm.cloud"
    if rel is not None and len(rel) >= 4 and rel[0] == "gt" and rel[2:4] == ["shared", "data"]:
        return "rm.rig-data"
    if any(c in ALLOW_COMP for c in parts) or (f.endswith(".pyc") and not os.path.isdir(f)) or (relp is not None and any(relp[:len(a)] == list(a) for a in ALLOW_HOME)):
        return None
    if rel is not None:  # o HOME vence o scratch: um HOME dentro de /tmp (teste) continua sendo HOME
        # vazio → o caminho não existe (typo ou criado antes na mesma linha): vale como pasta; falhou/ilegível → lexists diz não e vale como pasta
        if len(rel) == 1 and rec and not selective and not (os.path.lexists(f) and not os.path.isdir(f)):
            return "rm.home-child"
    else:
        for root in SCRATCH:
            rp = [x for x in root.split("/") if x]
            if low[:len(rp)] == rp:
                rest = low[len(rp):]
                return "rm.shared-tmp" if (not rest or (rest[0].startswith("claude-") and len(rest) < 3) or rest[0].startswith("tmux-") or (rp[-1] == "folders" and len(rest) < 4)) else None
        if low[0] in SYSTEM:
            return "rm.system"
    if selective:  # filtro de nome: o que vale é só a regra absoluta e dado (Dolt, beads, repo bare) embaixo da raiz; árvore de trabalho com `.git` pode (`find . -name '*.pyc' -delete`)
        return "rm.repo-root" if holds(f, False) else None
    if pat and MASS.fullmatch(pat.rsplit("/", 1)[-1]) and holds(os.path.dirname(pat)):
        return "rm.mass"
    return "rm.repo-root" if holds(f) else None


def classify(p: str, rec: bool, selective: bool = False, pat=None):
    """Regra que proíbe remover `p` (absoluto) ou None. Julga o texto E o caminho real (link simbólico): qualquer um proibido vale."""
    for f in dict.fromkeys((os.path.normpath(p), os.path.realpath(p))):
        r = judge(f, rec, selective, pat)
        if r:
            return r
    return None


def check(ops: list, rec: bool, selective: bool, cwds: list, env: dict):
    """(regra, alvo) do 1º operando proibido; operando que não resolvo só barra numa remoção recursiva."""
    for raw in ops:
        for p, pat in candidates(raw, cwds, env):
            if p is None:
                if rec:
                    return "rm.target-unknown", raw.replace(UNK, "?")
                continue
            r = classify(p, rec, selective, pat)
            if r:
                return r, (pat if r == "rm.mass" else p)
    return None


def rm_args(verb: str, args: list):
    """(operandos, recursivo): opção agrupada (-fr, -rfv), longa por prefixo único (--recur), `--` e opção DEPOIS do operando (GNU); só o `rm` é recursivo."""
    ops, rec, end = [], False, False
    for a in args:
        if end or a == "-" or not a.startswith("-"):
            ops.append(a)
        elif a == "--":
            end = True
        elif a.startswith("--"):
            n = a[2:].split("=", 1)[0]
            rec = rec or (bool(n) and "recursive".startswith(n))
        else:
            rec = rec or bool(set(a[1:]) & {"r", "R"})
    return ops, (rec and verb == "rm") or verb == "rimraf"


# --- Bash (o mesmo leitor do secret-read-guard.py: o hook é um arquivo só, não importa o irmão) ---
class Op(str):
    """Operador do shell (`;` `&&` `|` `(` `>` `2>>` `<<<`…). Uma palavra entre aspas igual a `;` NÃO é operador: por isso o tipo."""


SEP_OPS = {";", "&&", "||", "|", "|&", "&", ";;", "(", ")"}
REDIR = re.compile(r"\d*(?:&?>>?|<|>&|<&|>\||<>)")
OPRE = re.compile(r"<<<|<<-?|&&|\|\||\|&|;;|&>>|&>|>>|>&|<&|>\||<>|[;&|()<>]")


def skip_subst(t: str, i: int) -> int:
    """t[i:] começa em `$(`, `${` ou crase: o índice depois do fecho (sem fecho = fim do texto). Aspas dentro pulam até a de fecho; parênteses aninhados contam."""
    n, j, depth = len(t), i + 1, 0
    if t[i] == "`":
        while j < n and t[j] != "`":
            j += 2 if t[j] == "\\" else 1
        return min(j + 1, n)
    if t.startswith("${", i):
        j = t.find("}", i)
        return n if j < 0 else j + 1
    while j < n:
        c = t[j]
        if c == "\\":
            j += 1
        elif c in "'\"":
            j = t.find(c, j + 1)
            j = n if j < 0 else j
        elif c == "(" or c == ")":
            depth += 1 if c == "(" else -1
            if depth == 0:
                return j + 1
        j += 1
    return n


def lex(text: str):
    """Texto -> (palavras e Op, heredocs). Um leitor só, com as regras de aspas do bash: comentário, `\\`, '…', "…" (só `\\$ \\` \\" \\\\` escapam), $'…', $( ) e
    crase ficam DENTRO da palavra, newline vira `;` e o corpo de heredoc sai do fluxo: (corpo, palavras de quem o lê)."""
    toks, docs, pend, cur, word, i, n = [], [], [], [], False, 0, len(text)

    def flush():
        nonlocal cur, word
        if word:
            toks.append("".join(cur))
        cur, word = [], False

    while i < n:
        c, nx = text[i], text[i + 1:i + 2]
        if c in " \t":
            flush(); i += 1
        elif c == "\n":
            flush(); toks.append(Op(";")); i += 1
            for delim, tabs, recv in pend:
                body = []
                while i < n:
                    j = text.find("\n", i)
                    line, i = (text[i:], n) if j < 0 else (text[i:j], j + 1)
                    if (line.lstrip("\t") if tabs else line) == delim:
                        break
                    body.append(line)
                docs.append(("\n".join(body), recv))
            pend = []
        elif c == "#" and not word:
            while i < n and text[i] != "\n":
                i += 1
        elif c == "\\":
            cur.append("" if nx == "\n" else nx); word = word or nx != "\n"; i += 2
        elif c == "'" or (c == "$" and nx == "'"):  # '…' literal; $'…' decodificado
            i += 1 + (c == "$"); word = True; j = i
            while j < n and text[j] != "'":
                j += 2 if c == "$" and text[j] == "\\" else 1
            cur.append(ansi(text[i:j]) if c == "$" else text[i:j]); i = j + 1
        elif c == '"':
            i += 1; word = True
            while i < n and text[i] != '"':
                d, e = text[i], text[i + 1:i + 2]
                if d == "\\" and e:
                    cur.append(e if e in '$`"\\' else ("" if e == "\n" else "\\" + e)); i += 2
                elif (d == "$" and e in ("(", "{")) or d == "`":
                    j = skip_subst(text, i); cur.append(text[i:j]); i = j
                else:
                    cur.append(d); i += 1
            i += 1
        elif (c == "$" and nx in ("(", "{")) or c == "`":
            j = skip_subst(text, i); cur.append(text[i:j]); word = True; i = j
        elif c in "<>" and nx == "(":  # `<(cmd)` e `>(cmd)`: substituição de processo, fica DENTRO da palavra como o $( )
            j = skip_subst(text, i); cur.append(text[i:j]); word = True; i = j
        elif c in ";&|()<>":
            pre = ""
            if c in "<>" and word and "".join(cur).isdigit():  # `2>`: o descritor faz parte do operador
                pre, cur, word = "".join(cur), [], False
            else:
                flush()
            op = OPRE.match(text, i).group(0)
            i += len(op)
            m = re.match(r"[ \t]*(?:'([^']*)'|\"([^\"]*)\"|\\?([\w.-]+))", text[i:]) if op in ("<<", "<<-") else None
            if m:  # o delimitador não é palavra; quem lê o heredoc está antes ou depois dele, na mesma linha
                k = len(toks)
                while k and not (isinstance(toks[k - 1], Op) and toks[k - 1] in SEP_OPS):
                    k -= 1
                eol = text.find("\n", i)
                words = [str(t) for t in toks[k:] if not isinstance(t, Op)] + re.split(r"[\s;&|()<>]+", text[i + m.end(): n if eol < 0 else eol])
                pend.append((m.group(1) or m.group(2) or m.group(3) or "", op == "<<-", [os.path.basename(w) for w in words if w]))
                i += m.end()
            else:
                toks.append(Op(pre + op))
        else:
            cur.append(c); word = True; i += 1
    flush()
    return toks, docs + [("", r) for _, _, r in pend]  # `cat <<EOF` sem newline depois: não há corpo


def substitutions(w: str):
    """Corpos de $( ) e crase dentro de UMA palavra."""
    i, out = 0, []
    while i < len(w):
        if (w[i] in "$<>" and w[i + 1:i + 2] == "(") or w[i] == "`":  # $( ), <( ), >( ) e crase
            j = skip_subst(w, i)
            out.append(w[i + 2:j - 1] if w[i] != "`" else w[i + 1:j - (w[j - 1:j] == "`")]); i = j
        else:
            i += 1
    return out


def peel(ws: list, env: dict) -> list:
    """Tira atribuição (NAME=v), palavra reservada e embrulho (env, sudo, timeout…) do começo: o comando de verdade (vazio = só atribuição). `command -v rm` consulta, não roda."""
    ws = list(ws)
    while ws:
        b = os.path.basename(ws[0])
        if ASSIGN.match(ws[0]):
            env[ws[0].split("=", 1)[0]] = [tilde(x) for x in expand(ws[0].split("=", 1)[1], None, env)]
            ws = ws[1:]
        elif ws[0] in KEYWORDS:
            ws = ws[1:]
        elif b in WRAP:
            takes, npos, looked = set(WRAP[b][0].split()), WRAP[b][1], False
            ws = ws[1:]
            while ws and ws[0][:1] == "-" and len(ws[0]) > 1:
                o, ws = ws[0], ws[1:]
                if o == "--":
                    break
                key, eq, val = o.partition("=") if o[:2] == "--" else (o[:2], "", o[2:])
                if key in takes and not (eq or val):
                    val, ws = (ws[0] if ws else ""), ws[1:]
                if (b == "env" and key in ("-S", "--split-string")) or (b == "npx" and key in ("-c", "--call")):  # o valor da opção é um comando inteiro numa palavra só
                    ws = [str(t) for t in lex(val)[0]] + ws
                looked = looked or (b == "command" and key in ("-v", "-V"))
            if looked:
                return []
            ws = ws[npos:]
            if b == "flock" and ws[:1] in (["-c"], ["--command"]) and len(ws) > 1:  # `flock arquivo -c 'rm -rf x'`
                ws = [str(t) for t in lex(ws[1])[0]] + ws[2:]
        else:
            break
    return ws


def cd_target(ws: list, cwds: list, env: dict):
    """As pastas depois de um `cd`/`pushd` (assumo que rodou); None se a linha não é cd; [None] se não sei o destino."""
    ws = [w for w in ws if not ASSIGN.match(w)]
    while ws and ws[0] in ("time", "command", "builtin", "!"):
        ws = ws[1:]
    if not ws or os.path.basename(ws[0]) not in ("cd", "pushd", "popd"):
        return None
    if os.path.basename(ws[0]) == "popd":  # volta a uma pasta que não rastreio
        return [None]
    args = [a for a in ws[1:] if a not in ("-L", "-P", "-e", "-@", "--")]
    if args[:1] == ["-"]:
        return [None]
    return [p for p, _ in candidates(args[0], cwds, env)] if args else [home()]


def inline(code: str, cwds: list, depth: int, env: dict):
    """Código inline de python/node/perl/ruby/awk. Confere `['rm','-rf',x]`, texto de shell com rm (`os.system`) e, se o código usa uma API de remoção (DEL), cada literal de caminho."""
    deletes = bool(DEL.search(code) or RM_TEXT.search(code))  # verbo de remoção em qualquer parte (`'rm -rf ' + '/caminho'`) liga a leitura dos literais de caminho
    for m in ARGV.finditer(code):
        rest = m.group(2) if m.group(1) else m.group(4)  # literal vira o texto; expressão (variável, concatenação) vira UNK
        els = [g.group("s") if g.group("s") is not None else g.group("d") if g.group("d") is not None else UNK for g in ELEM.finditer(rest)]
        ops, rec = rm_args(m.group(1) or m.group(3), els)
        hit = check(ops, rec, False, cwds, env)
        if hit:
            return hit
    for m in LIT.finditer(code):
        lit = m.group(1) if m.group(1) is not None else m.group(2)
        if RM_TEXT.search(lit) and re.search(r"\s", lit.strip()):
            hit = scan_bash(lit, cwds, depth + 1, env)
        elif deletes and lit and not re.search(r"\s", lit) and re.match(r"[~/.]|\w+/", lit):
            hit = check([lit], True, False, cwds, env)
        else:
            hit = None
        if hit:
            return hit
    return None


def code_of(stage: list) -> list:
    """Textos que um estágio de pipe (ou o corpo de `<( )`) entrega como programa a quem o lê: cada palavra e, no echo/printf, os argumentos JUNTOS (`echo rm -rf x | bash`)."""
    ws = [str(t) for t in stage if not isinstance(t, Op)]
    return ws + ([" ".join(ws[1:])] if ws and os.path.basename(ws[0]) in ("echo", "printf") else [])


def narrow(test: str, pat: str) -> bool:
    """O padrão de um -name/-regex… filtra de verdade? Sem caractere literal (fora de [colchetes] e, no regex, de `.*` `.+` `\\`) casa tudo: `*`, `.*`, `.*[a-z].*`."""
    s = re.sub(r"\[[^\]]*\]", "", pat)
    s = re.sub(r"\\[wWdDsSbB]|\.[*+?]|\\", "", s) if test in ("-regex", "-iregex") else s
    return bool(re.search(r"[A-Za-z0-9]", s))


def fed(feed: list) -> list:
    """Operandos que chegam a um xargs pelo pipe: os argumentos do echo/printf anterior; o resto não sei (UNK)."""
    prev = peel(feed[-1], {}) if feed else []
    return prev[1:] if prev and os.path.basename(prev[0]) in ("echo", "printf") else [UNK]


def scan_bash(cmd: str, cwds: list, depth: int = 0, env=None):
    env = dict(env or {})
    if depth > 6:
        return "rm.too-deep", cmd[:60]
    toks, docs = lex(cmd)
    for body, recv in docs:  # corpo lido por shell ou interpretador é código; por cat, tee, git commit -F - é texto
        hit = scan_bash(body, cwds, depth + 1, env) if any(w in SHELLS for w in recv) else None
        hit = hit or (inline(body, cwds, depth + 1, env) if any(INTERP.fullmatch(w) for w in recv) else None)
        if hit:
            return hit
    cur, here, saved, feed = [], list(cwds), [], []  # feed = comandos anteriores da MESMA pipeline
    for t in toks + [Op(";")]:
        if isinstance(t, Op) and t in SEP_OPS:
            hit = one(cur, here, depth, env, feed)
            if hit:
                return hit
            feed = feed + [cur] if t in ("|", "|&") else []
            new = cd_target(cur, here, env)
            if new is not None:  # o cd só vale com certeza depois de `&&`; com `;` `||` `&` `|` ele pode ter falhado e o shell ficou onde estava: valem os dois (o pior vence)
                merged = here + [p for p in new if p not in here]
                here = new if t == "&&" else merged if len(merged) <= 8 else merged[:7] + [None]  # nunca descarta o cwd mais novo: acima do teto entra um "não sei"
            if t == "(":
                saved.append(here)
            elif t == ")" and saved:
                here = saved.pop()
            cur = []
        else:
            cur.append(t)
    return None


def one(ws: list, cwds: list, depth: int, env: dict, feed: list, app=None):
    words, here, k = [], [], 0
    while k < len(ws):  # redirecionamento: o operador e a palavra seguinte não são argumentos
        t = ws[k]
        if isinstance(t, Op) and k + 1 < len(ws) and (REDIR.fullmatch(t) or t == "<<<"):
            if t == "<<<":
                here.append(str(ws[k + 1]))
            k += 2
        else:
            k += 1
            if not isinstance(t, Op):
                words.append(t)
    for w in words:  # $( ) e crase dentro de QUALQUER palavra rodam, mesmo atrás de um echo
        for body in substitutions(w):
            hit = scan_bash(body, cwds, depth + 1, env)
            if hit:
                return hit
    if len(words) > 3 and words[0] == "for" and words[2] == "in":  # `for d in a b; do rm -rf "$d"; done`: $d passa a valer cada item
        env[words[1]] = [tilde(x) for w in words[3:] for x in expand(w, cwds[0], env)]
        return None
    ws = peel(words, env)
    if not ws:
        return None
    if re.search(r"[$`*?\[]", ws[0]) and ws[0] not in ("[", "[["):  # verbo que sai de variável, substituição ou curinga (`$R -rf x`, `$(echo rm) -rf x`, `/bin/r? -rf x`)
        v = expand(ws[0], cwds[0], env)
        if len(v) == 1 and UNK not in v[0] and not re.search(r"[*?\[]", v[0]):
            ws = [v[0]] + ws[1:]
        else:  # não sei que programa é: com flag recursiva vale como rm; sem ela valem as regras absolutas nos operandos, e texto de shell com rm nos argumentos é lido
            ops, rec = rm_args("rm", ws[1:])
            for a in ws[1:]:
                hit = scan_bash(a, cwds, depth + 1, env) if RM_TEXT.search(a) and re.search(r"\s", a.strip()) else None
                if hit:
                    return hit
            return check(ops, rec, not rec, cwds, env)
    verb, args = os.path.basename(ws[0]), ws[1:]
    if verb in ("export", "declare", "typeset", "local", "readonly"):  # `export D=x`: vale para os comandos seguintes
        for a in args:
            if ASSIGN.match(a):
                env[a.split("=", 1)[0]] = [tilde(x) for x in expand(a.split("=", 1)[1], cwds[0], env)]
        return None
    procs = [w[2:-1] for w in words if w[:2] in ("<(", ">(") and w.endswith(")")]  # `bash <(echo 'rm -rf x')`: a SAÍDA do corpo é o programa de quem o lê
    if verb in RM_VERBS:
        ops, rec = rm_args(verb, args)
        return check(ops + list(app or []), rec, False, cwds, env)
    if verb == "xargs":
        i = 0
        while i < len(args) and args[i][:1] == "-" and len(args[i]) > 1:
            i += 2 if args[i] in XARGS_VAL else 1
            if args[i - 1] == "--":
                break
        return one(args[i:], cwds, depth, env, [], fed(feed)) if args[i:] else None
    if verb == "find":
        i = 0
        while i < len(args) and args[i] in ("-H", "-L", "-P"):
            i += 1
        j = i
        while j < len(args) and args[j][:1] not in ("-", "(", "!"):
            j += 1
        roots, expr, rmish = args[i:j] or ["."], args[j:], "-delete" in args[j:]
        for x, t in enumerate(expr):
            if t in ("-exec", "-execdir", "-ok", "-okdir"):
                cmd = expr[x + 1:]
                end = next((y for y, w in enumerate(cmd) if w == ";" or (w == "+" and y and cmd[y - 1] == "{}")), len(cmd))
                sub = peel(cmd[:end], {})
                rmish = rmish or bool(sub) and os.path.basename(sub[0]) in RM_VERBS
                hit = one(cmd[:end], cwds, depth, env, [])
                if hit:
                    return hit
        # filtro de nome só vale se filtra de verdade (narrow) e nada o anula: `-o`, `!`, `-not` fazem o -delete valer para o que o filtro NÃO casa
        sel = not ({"!", "-not", "-o", "-or"} & set(expr)) and any(t in SELECT and x + 1 < len(expr) and narrow(t, expr[x + 1]) for x, t in enumerate(expr))
        return check(roots, True, sel, cwds, env) if rmish else None
    shellish = verb in SHELLS or verb in ("eval", "source", ".")
    if shellish or INTERP.fullmatch(verb):
        run = (lambda s: scan_bash(s, cwds, depth + 1, env)) if shellish else (lambda s: inline(s, cwds, depth + 1, env))
        for body in procs:
            for w in code_of(lex(body)[0]):
                hit = run(w)
                if hit:
                    return hit
        code = " ".join(args) if verb == "eval" else None
        for x, a in enumerate(args if code is None else []):
            if re.fullmatch(r"-[a-zA-Z]*[ceEpr]|--(?:eval|print|command)", a):
                code = args[x + 1] if x + 1 < len(args) else None
                break
        if code is None and verb.endswith("awk"):
            code = next((a for a in args if not a.startswith("-")), None)
        code = code or (here[0] if here else None)
        if not code and verb != "eval" and ("-" in args or "-s" in args or not [a for a in args if not a.startswith("-")]):  # lê o programa do stdin: o que vem pelo pipe é código
            for w in [c for st in feed for c in code_of(st)]:
                hit = run(w)
                if hit:
                    return hit
        return run(code) if code else None
    if verb in OPAQUE:  # não modelo o que o lançador faz: o comando de dentro (palavra solta ou texto entre aspas) vale
        for j, w in enumerate(args):
            if re.search(r"\s", w):
                hit = scan_bash(w, cwds, depth + 1, env)
                if hit:
                    return hit
            elif os.path.basename(w) in RM_VERBS | {"find", "xargs"} | SHELLS:
                return one(args[j:], cwds, depth + 1, env, [])
    return None


def decide(inp: dict):
    """None = liberado; (regra, alvo, operação) = bloqueado."""
    if inp.get("tool_name") != "Bash":
        return None
    cmd, cwd = str((inp.get("tool_input") or {}).get("command") or ""), inp.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR")
    if len(cmd) > MAX_CMD:  # não dá para conferir e a busca de texto não prova nada (`r''m`, `$'\x72m'`): bloqueado
        return "rm.too-big", cmd[:60], "comando Bash"
    hit = scan_bash(cmd, [os.path.realpath(cwd)] if isinstance(cwd, str) and os.path.isabs(cwd) else [None])
    return (hit[0], hit[1], "comando Bash") if hit else None


def message(hit) -> str:
    rule, target, op = hit
    return ("[HOOK BLOCK: rm-target-guard] NÃO É CANCELAMENTO DO USUÁRIO — política automática de proteção contra remoção.\n"
            f"BLOQUEADO: {op} apagaria alvo protegido ({rule}: {RULES.get(rule, rule)}).\nAlvo: {target}\n"
            "Scratch continua livre: `rm -rf /tmp/<pasta>` (ou o scratchpad da sessão) passa; no mini `safe-clean <caminho-absoluto>`; no nó `find <pasta> -mindepth 1 -delete`. "
            "Alvo em variável ou `$( )`: escreva o caminho por extenso. Dado do Dolt, `.git`, HOME e raiz de repo não se apagam por agente: se a tarefa exige mesmo, devolva a bead ao Mayor.\n")


def main() -> int:
    # vazio → stdin vazio é lixo, libera; falhou/ilegível (não é JSON) → bloqueia só se o texto cita "command" (um pedido Bash que o guarda não consegue conferir)
    raw = sys.stdin.read()
    inp = None
    try:
        inp = json.loads(raw)
        hit = decide(inp)
    except Exception as e:  # noqa: BLE001 — falha do guarda não pode virar "liberado" num pedido que ele cobre
        if not (isinstance(inp, dict) and inp.get("tool_name") == "Bash") and '"command"' not in raw:
            return 0
        print(f"[HOOK BLOCK: rm-target-guard] o guarda falhou ({type(e).__name__}) e não consigo conferir este pedido: bloqueado.", file=sys.stderr)
        return 2
    if hit:
        print(message(hit), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
