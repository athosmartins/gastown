#!/usr/bin/env python3
r"""remote-clone-guard.py — substituto, no SERVIDOR Hetzner, do `gt tap guard cross-clone-block` do mini (ga-2hd02v.1.5; decisão Q4 do
Mayor: sessão remota só é liberada depois que existir um substituto). Hook PreToolUse (Bash, Edit, Write, MultiEdit, NotebookEdit).

Contents
  Para que serve · Como decide · Códigos · Limites
PARA QUE SERVE
  Uma sessão escreve no PRÓPRIO clone (o worktree `~/gt-remote/git/<rig>/wt/<bead>`) e em mais nada daquele território. Escrita de git
  (`git -C <outro clone> commit/push/merge/rebase/reset…`) ou de arquivo (Edit/Write) no clone de OUTRA sessão, ou no espelho (`repo.git`),
  é bloqueada com uma mensagem clara. Leitura (log/status/diff/show…) e escrita no próprio clone seguem livres. Vale sob
  `--dangerously-skip-permissions`: um hook que sai com 2 bloqueia a chamada em qualquer modo (medido no servidor, ver o runbook).
COMO DECIDE (sei que pode / sei que não pode / não sei, e o último NÃO vira "pode"): território = $RCG_ROOT, senão ~/gt-remote/git; clone próprio = o ancestral com `.git`
  de $CLAUDE_PROJECT_DIR. A regra inteira (onde o git pode estar, alvo, "não sei", heredoc, contexto do aninhado): docs/runbooks/hetzner-hardening.md, "Como o guarda decide".
CÓDIGOS: 0 liberado · 2 bloqueado — também o pedido que o guarda não consegue analisar em STEP_LIMIT passos ou TIME_LIMIT segundos (hook estourado no Claude Code, 600 s, NÃO bloqueia: a
  chamada seguiria sem conferência; o guarda se corta antes e fecha, ver Budget). `--selfcheck [settings.json [pasta-do-projeto…]]`: 0 se o guarda decide como deveria numa pasta de teste E (com o settings) todo
  PreToolUse de Bash/Edit/Write/MultiEdit/NotebookEdit é EXATAMENTE `python3 -I <este arquivo> || exit 2`, sem campo que mude QUANDO dispara (só type/command/timeout) e
  sem `disableAllHooks` nele nem em <pasta>/.claude/settings[.local].json; 1 caso contrário (o provider confere antes de abrir sessão real). Edit/Write em ~/.claude/hooks/** e ~/.claude/settings*.json bloqueiam.
LIMITES (é trava contra engano, não sandbox): a lista do que NÃO vejo e dos falsos positivos está no runbook, seção "Como o guarda decide".
"""
from __future__ import annotations

import json
import os
import re
import shlex
import signal
import sys
import tempfile

TOOLS_FILE = {"Edit": "file_path", "Write": "file_path", "MultiEdit": "file_path", "NotebookEdit": "notebook_path"}
READ = {"log", "status", "diff", "show", "rev-parse", "rev-list", "ls-files", "ls-tree", "cat-file", "blame", "describe", "shortlog",
        "grep", "show-ref", "for-each-ref", "name-rev", "merge-base", "diff-tree", "diff-index", "diff-files", "ls-remote", "whatchanged",
        "check-ignore", "count-objects", "fsck", "version", "help", "var", "cherry", "range-diff", "show-branch", "annotate", ""}
LIST_FLAGS = {"branch": {"-l", "--list", "-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose", "--show-current", "-i", "--ignore-case", "--no-color", "--no-column"},
              "tag": {"-l", "--list", "-i", "--ignore-case", "--no-column"}}
LIST_VAL = {"--contains", "--no-contains", "--merged", "--no-merged", "--points-at"}  # opções que só existem em modo lista e levam um commit (junto ou no argumento seguinte)
LIST_EQ = ("--sort=", "--format=", "--abbrev=", "--color=", "--column=")  # valor só junto da opção: separado, `--sort novo` é palavra solta e não sei o que é
CONFIG_SCOPE = {"--local", "--global", "--system", "--worktree", "--show-origin", "--show-scope", "--includes", "--no-includes", "--name-only", "-z", "--null"}
WRITES = re.compile(r"--(?:output|lost-found|open-files-in-pager|ext-diff)(?:=|$)|-O")  # flag de comando de LEITURA que grava arquivo ou roda programa
CFG_SAFE = re.compile(r"(?:color|advice)\.[\w.-]+|core\.(?:quotepath|abbrev|precomposeunicode)|safe\.directory|user\.(?:name|email)")  # chaves de `-c` que só mudam exibição/identidade; qualquer outra (alias.*, core.pager/fsmonitor/sshCommand/hooksPath, diff.external, filter.*, credential.helper…) pode fazer o git rodar um programa
CFG_ENV = re.compile(r"GIT_(?:CONFIG\w*|EXTERNAL_DIFF|PAGER|SSH\w*|ASKPASS|EDITOR|SEQUENCE_EDITOR|PROXY_COMMAND|EXEC_PATH|TEMPLATE_DIR)|SSH_ASKPASS")  # variáveis que fazem o git rodar um programa ou ler configuração de outro lugar
PUNCT, SEPS = set("();<>|&"), {";", "&&", "||", "|", "&", "|&", ";;"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "ash", "fish", "csh", "tcsh"}
DATA = {"cat", "tee", "git", "gh", "bd", "gc", "jq", "grep", "head", "tail", "wc", "sort", "uniq", "tr", "cut", "base64", "diff", "read", "mapfile", "true", ":"}  # leitores de heredoc que tratam o corpo como DADO; quem não está aqui pode executá-lo
REDIR = re.compile(r"(?:(?<![\w$])\d+)?(?:<<-?|<>|>>|>&|<&|>\||[<>])[ \t]*(?:'[^']*'|\"[^\"]*\"|[^\s;&|()<>'\"]+)?")  # `sh<<EOF`, `<<EOF bash`, `2>/dev/null sh <<EOF`: sem os redirecionamentos sobra o comando
# Embrulhos que o guarda descasca, cada um com a tabela das SUAS opções (uma tabela só para todos foi a brecha: `sudo -n` herdava o `-n` do xargs, que leva
# argumento, e o `git` virava o argumento). Quatro listas por embrulho: sem argumento · com argumento no token SEGUINTE · valor sempre colado (`-i{}`, `--eof=x`) ·
# muda o diretório onde o comando roda. Opção colada (`-oL`, `--x=y`) é uma palavra só. Opção que NÃO está na tabela = não sei onde o comando começa.
WOPT = {
    "command": ("-p -v -V", "", "", ""), "builtin": ("", "", "", ""), "nohup": ("", "", "", ""), "exec": ("-c -l", "-a", "", ""), "doas": ("-n -s", "-u -C", "", ""),
    "time": ("-p -v -a -q --portability --verbose --append --quiet", "-f -o --format --output", "", ""),
    "env": ("-i -0 -v --ignore-environment --null --debug", "-u -C -S -P --unset --chdir --split-string", "", "-C --chdir -S --split-string"),
    "sudo": ("-A -b -E -e -H -i -K -k -l -n -P -S -s -V -v --askpass --background --edit --set-home --login --list --non-interactive --preserve-groups --preserve-env "
             "--stdin --shell --validate --version --remove-timestamp --reset-timestamp",
             "-C -c -D -g -h -p -R -r -T -t -U -u --close-from --login-class --chdir --group --host --prompt --chroot --role --command-timeout --type --other-user --user",
             "", "-D -R --chdir --chroot"),
    "xargs": ("-0 -o -p -r -t -x --null --open-tty --interactive --no-run-if-empty --verbose --exit --show-limits",
              "-a -d -E -I -L -n -P -s --arg-file --delimiter --max-args --max-procs --max-chars --process-slot-var", "-e -i -l --eof --replace --max-lines", ""),
    "nice": ("", "-n --adjustment", "", ""), "timeout": ("-v --verbose --foreground --preserve-status", "-s -k --signal --kill-after", "", ""),
    "stdbuf": ("", "-i -o -e --input --output --error", "", ""), "setsid": ("-c -f -w --ctty --fork --wait", "", "", ""),
}
WRAP, SPLIT = set(WOPT), {"-S", "--split-string"}  # env -S 'git -C x commit': o valor da opção é um comando inteiro
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "{", "!", "coproc"}  # palavras reservadas que vêm ANTES de um comando: o git depois delas é o comando do trecho
LEAD = {"then", "do", "else", "elif", "!", "{", "time"}  # palavras que só LIGAM um bloco ao comando seguinte (o comando de verdade é a próxima)
OPAQUE = {"flock", "ionice", "chrt", "taskset", "parallel", "su", "runuser", "ssh", "script", "trap", "watch", "unshare", "nsenter", "chroot", "setpriv", "numactl",
          "strace", "fakeroot", "systemd-run", "busybox", "dbus-run-session", "xvfb-run", "unbuffer", "caffeinate", "tmux", "screen", "expect"}  # lançadores que não modelo: lista FECHADA (ver LIMITES)
GIT_FLAG = re.compile(r"-[Phv]|--(?:no-pager|bare|no-replace-objects|no-lazy-fetch|no-optional-locks|no-advice|literal-pathspecs|glob-pathspecs|noglob-pathspecs|"
                      r"icase-pathspecs|no-global-excludes|version|help|html-path|man-path|info-path|attr-source=.*|namespace=.*|list-cmds=.*)")  # opções de topo do git que conheço e não levam o valor no token seguinte
ASSIGN, NUM = re.compile(r"([A-Za-z_]\w*)=(.*)", re.S), re.compile(r"[\d.]+[smhd]?")
FD = re.compile(r"(^|[\s;&|(])\d+(?=[<>])")  # `2>/dev/null`, `1>&2`: o número colado no redirecionamento é o descritor, não um argumento
SHELLY = re.compile(r"[$`*?\[{]")
PIECE = re.compile(r"&&|\|\||\|&|;;|[;&|()]|[<>]+&?")
SUBST = re.compile(r"\$S([0-9a-f]*)\$")
INTERP = re.compile(r"(?:python|pypy|perl|ruby|php|lua)[\d.]*|node(?:js)?|deno|bun|[gmn]?awk")  # interpretador cujo código (python -c, node -e, perl -e, php -r, lua -e, deno eval, bun -e, programa do awk) pode rodar um shell: o texto entre aspas dele é conferido como comando
LIT = re.compile(r"'((?:[^'\\]|\\.)*)'|\"((?:[^\"\\]|\\.)*)\"|(?:\bq[qx]?|%[xQq])\s*(?:\{([^}]*)\}|\(([^)]*)\)|\[([^\]]*)\]|([^\w\s{(\[<'\"])((?:(?!\6).)*)\6|<([^>]*)>)|\[(=*)\[(.*?)\]\9\]", re.S)  # literal do código de um interpretador: entre aspas simples ou duplas; q{…}/qq{…}/qx{…} do perl e %x/%Q/%q do ruby com {} () [] <> ou outro delimitador de UM caractere que não seja letra, dígito, _, espaço nem aspa (q!…!, q#…#, q/…/); [[…]] e [=[…]=] do lua. Um grupo por forma (o extrator pega o último não vazio); {} () [] <> não aninham: leio até o PRIMEIRO fechamento (ver LIMITES)
CODECD = re.compile(r"chdir|\bcwd\b|\bGIT_[A-Z_]+")  # o código muda o diretório ou o repositório do shell que abre (os.chdir, cwd=, {'cwd': …}, GIT_DIR/GIT_WORK_TREE no env): o git de dentro roda em lugar "não sei". Qualquer `cwd` vale, até a chave de um JSON (falso positivo assumido); nome de variável montado em pedaços não vejo
PIPES, VAR, MANY = ("|", "|&"), re.compile(r"\$(\w+)|\$\{(\w+)\}"), 64
PFMT = re.compile(r"%(?:%|[-+ #0]*\d*(?:\.\d+)?[a-zA-Z])")  # uma conversão do printf (%s, %b, %5d) ou o %% literal
HEREDOC = re.compile(r"(?<!<)<<(-?)[ \t]*(['\"]?)([^\s'\"<>|&;()]+)\2")  # o delimitador é a palavra INTEIRA (END-OF-FILE, EOF.txt), não só \w+
PROT = {c: chr(0xF0000 + ord(c)) for c in "();<>|&'"}  # `;<>…` entre aspas ou depois de `\` é TEXTO: antes do shlex (que tira as aspas) vira um caractere de uso privado, e só depois volta (ver protect)
UNPROT = str.maketrans({v: k for k, v in PROT.items()})
ANSI = re.compile(r"\\(x[0-9a-fA-F]{1,2}|u[0-9a-fA-F]{1,4}|U[0-9a-fA-F]{1,8}|[0-7]{1,3}|c.|.)", re.S)  # os escapes de `$'…'`
ESC = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\\": "\\", "'": "'", '"': '"', "?": "?"}
# git que escreve onde o ARGUMENTO manda, sem -C nem --git-dir: `worktree remove ../outro`, `clone <repo> <outro>/x`, `init <outro>/x`, `checkout-index --prefix=<outro>/`…
DEST = {"worktree", "init", "clone", "checkout-index", "submodule", "archive", "bundle", "format-patch"}  # nestes TODA palavra (e o valor de `--opção=valor`) pode ser o caminho
PATHOPT = {"--output", "--prefix", "--separate-git-dir", "--lost-found", "--file", "--template"}  # em QUALQUER subcomando: a opção cujo valor é um caminho onde o git escreve
URL = re.compile(r"\w+://")
CONT = re.compile(r"(?<!\\)((?:\\\\)*)\\\n")  # barra + newline com número ÍMPAR de barras: continuação de linha (com número par a última barra é a barra escapada)
STEP_LIMIT, TIME_LIMIT, WORK = 50000, 5.0, [0]  # teto por pedido: passos de conferência (ver tick) e segundos de relógio (ver main); WORK = passos gastos até agora


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


def lists_only(sub: str, rest: list) -> bool:
    """`git branch`/`git tag` que só LISTA. vazio → lista; opção que não conheço, ou palavra solta (nome novo) sem opção de lista → não sei, e não sei é escrita."""
    listing, val = any(t.partition("=")[0] in LIST_VAL or t in ("-l", "--list") for t in rest), False
    for t in rest:
        if val:  # o commit da opção anterior; começando por `-` é outra opção escondida
            val = False
            if t.startswith("-"):
                return False
        elif t in LIST_FLAGS[sub] or t.startswith(LIST_EQ) or t.partition("=")[0] in LIST_VAL or (sub == "tag" and re.fullmatch(r"-n\d*", t)):
            val = t in LIST_VAL
        elif t.startswith("-") or not listing:
            return False
    return True


def reads_config(rest: list) -> bool:
    """`git config` que só LÊ: --get…/--list, ou UMA palavra (a chave) com no máximo o escopo. Duas palavras = `chave valor` (grava); outra opção grava ou abre editor."""
    flags = [t for t in rest if t.startswith("-")]
    return any(t in ("--get", "--get-all", "--get-regexp", "--list", "-l") for t in rest) or (len(rest) - len(flags) == 1 and all(t in CONFIG_SCOPE for t in flags))


def is_read(sub: str, rest: list) -> bool:
    if any(WRITES.match(t) for t in rest):
        return False
    if sub in READ:
        return True
    if sub in LIST_FLAGS:
        return lists_only(sub, rest)
    first = rest[0] if rest else ""
    return ((sub == "stash" and first in ("list", "show")) or (sub == "worktree" and first == "list") or (sub == "reflog" and first in ("", "show"))
            or (sub == "notes" and first in ("list", "show")) or (sub == "remote" and (rest in ([], ["-v"]) or rest[:1] in (["show"], ["get-url"]) or rest[:2] in (["-v", "show"], ["-v", "get-url"])))
            or (sub == "config" and reads_config(rest)))


def quotes(s: str, k: int, q: str):
    """Um passo do leitor de aspas do shell: (próximo índice, estado) a partir de s[k] no estado q ("" fora, "'" simples, '"' dupla, "$'" ANSI-C)."""
    c = s[k]
    if q == "'":
        return k + 1, ("" if c == "'" else q)
    if c == "\\" and q != "'":
        return k + 2, q  # barra + o caractere seguinte: o par é texto (fora de aspas simples)
    if q:
        return k + 1, ("" if c == q[-1] else q)
    return (k + 2, "$'") if s.startswith("$'", k) else (k + 1, c if c in "'\"" else "")


def body_end(s: str, j: int) -> int:
    """Índice do `)` que fecha o `$(` cujo miolo começa em s[j], ou len(s). Parêntese entre aspas ou escapado não conta, nem os de um `case … esac`."""
    d, q, k, cs = 1, "", j, 0
    while k < len(s):
        c, w = s[k], re.match(r"(case|esac)\b", s[k:]) if not q and (k == 0 or not (s[k - 1].isalnum() or s[k - 1] in "_-")) else None
        if w:
            cs = max(0, cs + (1 if w.group(1) == "case" else -1))
        elif not q and not cs and c in "()":
            d += 1 if c == "(" else -1
            if not d:
                return k
        k, q = quotes(s, k, q)
    return len(s)


def hide(cmd: str) -> str:
    """Cada $( ) e crase que o SHELL expande vira UMA palavra opaca `$S<hex do miolo>$`: o shlex não as abre, e `one` confere o miolo no diretório certo.
    Entre aspas simples, em $'…' ou escapado (`\\$(`) é texto: fica, e o shell aninhado que o recebe (bash -c, eval) o confere já sem as aspas de fora."""
    out, i, k, q = [], 0, 0, ""
    while k < len(cmd):
        if q not in ("'", "$'") and (cmd.startswith("$(", k) or cmd[k] == "`"):
            if cmd[k] == "`":
                e = k + 1
                while e < len(cmd) and cmd[e] != "`":
                    e += 2 if cmd[e] == "\\" else 1
                body, nxt = cmd[k + 1:e], e + 1
            else:
                e = body_end(cmd, k + 2)
                body, nxt = cmd[k + 2:e], e + 1
            out += [cmd[i:k], "$S" + body.encode().hex() + "$"]
            i = k = min(nxt, len(cmd))
            continue
        k, q = quotes(cmd, k, q)
    return "".join(out) + cmd[i:]


def decomment(cmd: str) -> str:
    r"""`#` que começa palavra, fora de aspas, abre comentário até o fim da linha: ali aspa, crase e `\` são TEXTO para o shell. Viram espaço — as palavras
    do comentário seguem conferidas (lado fechado), mas não pareiam com a aspa de um `-m 'msg'` adiante nem juntam a linha seguinte."""
    out, k, q = list(cmd), 0, ""
    while k < len(cmd):
        if not q and cmd[k] == "#" and (k == 0 or cmd[k - 1] in " \t\n;&|()"):
            e = cmd.find("\n", k)
            e = len(cmd) if e < 0 else e
            for j in range(k, e):
                if cmd[j] in "'\"`\\":
                    out[j] = " "
            k = e
            continue
        k, q = quotes(cmd, k, q)
    return "".join(out)


def runs_text(seg: list) -> bool:
    """O comando do trecho executa texto que recebe (shell, eval/source, ssh/su… — OPAQUE)? vazio → não; só o COMANDO decide, não as palavras (`git commit -m "bash"` não é shell)."""
    _, s, _, opq = peel(seg)  # opq = embrulho com opção que não conheço: não sei o que ele roda, vale como lançador
    return bool(s) and (opq or os.path.basename(s[0]) in SHELLS | OPAQUE | {"eval", "source", "."})


def data_reader(s: str) -> bool:
    """O pedaço da linha do `<<` trata o corpo como DADO? Só se o comando (sem atribuições/palavras reservadas/embrulhos) está em DATA; o resto → não (é conferido)."""
    try:
        _, seg, _, opq = peel(shlex.split(s))
    except ValueError:
        return False
    return not opq and (not seg or os.path.basename(seg[0]) in DATA)


def opener_ok(s: str, i: int) -> bool:
    """O `<<` em s[i] abre heredoc para o SHELL? Não entre aspas/escapado, depois de `#` de comentário, nem dentro de `$( )`/`$(( ))` na linha; na dúvida, não."""
    q, k, cm, dp = "", 0, False, 0
    while k < i:
        c = s[k]
        if c == "\n":
            cm, dp = False, 0
        elif q == "'":
            q = "" if c == "'" else q
        elif c == "\\" and q != "'":
            k += 1  # barra + o caractere seguinte são um par: se o par cobre s[i], o `<` está escapado (k passa de i)
        elif q == '"':
            q = "" if c == '"' else q
        elif cm:
            pass
        elif c in "'\"":
            q = c
        elif c == "#" and (k == 0 or s[k - 1] in " \t;&|("):
            cm = True
        elif c == "(" and k and s[k - 1] in "$(":
            dp += 1
        elif c == ")" and dp:
            dp -= 1
        k += 1
    return not q and not cm and not dp and k == i


def heredocs(cmd: str) -> str:
    """Corpo de heredoc DE VERDADE some até a linha que é EXATAMENTE o delimitador (sem terminador nada some); o $( ) de delimitador sem aspas fica; se um shell lê (`bash <<EOF`), o corpo fica."""
    out, pos = [], 0
    while (m := HEREDOC.search(cmd, pos)):
        eol = cmd.find("\n", m.end())
        if not opener_ok(cmd, m.start()) or eol < 0:
            out.append(cmd[pos:m.start() + 1])
            pos = m.start() + 1
            continue
        j, end = eol + 1, None
        while end is None and j <= len(cmd):
            nl = cmd.find("\n", j)
            line = cmd[j:nl if nl >= 0 else len(cmd)]
            if (line.lstrip("\t") if m.group(1) else line) == m.group(3):
                end = (j, nl if nl >= 0 else len(cmd))
            j = nl + 1 if nl >= 0 else len(cmd) + 1
        if end is None:
            out.append(cmd[pos:m.end()])
            pos = m.end()
            continue
        opener, body = cmd[m.start():eol], cmd[eol + 1:max(end[0] - 1, eol + 1)]
        if not all(data_reader(s) for s in re.split(r"[;&|(]+", REDIR.sub(" ", cmd[cmd.rfind("\n", 0, m.start()) + 1:eol]))):
            repl = opener + "\n" + body
        else:
            repl = opener + ("" if m.group(2) else "\n: " + " ".join(x.group(0) for x in SUBST.finditer(hide(body))))
        out.append(cmd[pos:m.start()] + repl)
        pos = end[1]
    return "".join(out) + cmd[pos:]


def ansi(m) -> str:
    r"""Um escape de `$'…'`: \xHH, \NNN (octal), \uHHHH, \n, \t… O que não conheço fica como está (o bash também mantém a barra)."""
    e = m.group(1)
    if e[0] in "xuU" and len(e) > 1:
        return chr(min(int(e[1:], 16), 0x10FFFF))
    if e[0] in "01234567":
        return chr(int(e, 8) & 255)
    return ESC.get(e, m.group(0))


class Unclosed(ValueError):
    """Aspa que não fecha (ou `\\` no fim): `pos` é onde ela abre no texto que o protect() leu."""

    def __init__(self, pos: int):
        super().__init__("aspas que não fecham")
        self.pos = pos


def protect(cmd: str) -> str:
    """O shlex tira as aspas e a barra: `'>'` e `\\>` saem como `>`, igual a um `>` de verdade, e `''` sai como palavra vazia. Aqui cada `;&|()<>` que o SHELL lê como
    texto (entre aspas, ou depois de `\\`) vira um caractere reservado (PROT), que words() devolve ao texto DEPOIS de decidir quem é operador. `$'…'` leva os escapes
    decodificados (`$'\\x67it'` é git; `$'\\''` é uma aspa, não o fim) e `$"…"` perde o `$`. Unclosed = aspas que não fecham ou `\\` no fim (a posição vai junto)."""
    out, i, q, qpos = [], 0, "", 0
    while i < len(cmd):
        c = cmd[i]
        if q == "'":
            q = "" if c == "'" else q
            out.append(c if c == "'" else PROT.get(c, c))
        elif q == '"' and c != "\\":
            q = "" if c == '"' else q
            out.append(c if c == '"' else PROT.get(c, c))
        elif c == "\\" and i + 1 < len(cmd):  # dentro de aspas duplas ou fora: barra + o caractere seguinte é um par só
            out += [cmd[i + 1]] if q == '"' and cmd[i + 1] in "$`" else [c, PROT.get(cmd[i + 1], cmd[i + 1])]  # em "…", `\$`/`\`` perdem a barra (o shlex a manteria; o bash não)
            i += 1
        elif q:
            out.append(c)  # barra solta no fim, dentro de aspas duplas: o laço acaba com a aspa aberta
        elif c == "\\":
            raise Unclosed(i)  # barra solta no fim, fora de aspas (as de dentro de aspas e as seguidas de caractere já foram tratadas acima)
        elif c == "$" and (m := SUBST.match(cmd, i)):  # o `$S<hex>$` de hide(): inteiro, sem olhar a aspa que vem depois dele
            out.append(m.group())
            i = m.end() - 1
        elif c == "$" and cmd[i + 1:i + 2] == '"':  # `$"…"` (tradução de locale) é só `"…"`: o `$` vai embora
            pass
        elif c == "$" and cmd[i + 1:i + 2] == "'":
            j = i + 2
            while j < len(cmd) and cmd[j] != "'":
                j += 2 if cmd[j] == "\\" else 1
            if j >= len(cmd):
                raise Unclosed(i + 1)
            out.append("'" + "".join(PROT.get(x, x) for x in ANSI.sub(ansi, cmd[i + 2:j])) + "'")
            i = j
        else:
            if c in "'\"":
                q, qpos = c, i
            out.append(c)
        i += 1
    if q:
        raise Unclosed(qpos)
    return "".join(out)


def words(cmd: str) -> list:
    """As palavras do comando como (texto, operador?). operador = pontuação do SHELL (`;`, `&&`, `>`, `<(`…): `';'`, `\\;`, `'>'` e `''` são palavras, e a vazia FICA (`git -C '' -C x`).
    Aspa ou crase de COMENTÁRIO não conta (decomment). Aspa que ainda não fecha (ou `\\` no fim): o shell recusaria a linha; o guarda tira a aspa que o leitor
    deu como solta (a última aberta) e confere o resto como comando — UMA hipótese, a do lado fechado: mais texto vira comando, nenhum vira palavra entre aspas."""
    cmd = FD.sub(r"\1", hide(CONT.sub(r"\1", decomment(heredocs(cmd)))).replace("\n", " ; "))  # newline separa comandos; `\` + newline os junta; heredoc só o que o shell lê como heredoc
    while True:  # termina: cada volta tira um caractere, e a próxima aspa solta só pode estar mais adiante (o que sobra de um tipo de aspa depois de tirar a solta é par ou tem uma só)
        try:
            text = protect(cmd)
            break
        except Unclosed as e:
            cmd = cmd[:e.pos] + cmd[e.pos + 1:]
    lx = shlex.shlex(text, posix=True, punctuation_chars=True)
    lx.whitespace_split, lx.commenters = True, ""
    return [(t.translate(UNPROT), bool(t) and set(t) <= PUNCT) for t in lx]


class Many(Exception):
    """Mais variantes de um eval/pipe (o produto dos textos que cada variável pode ter) do que o guarda confere: decide() BLOQUEIA o pedido, nunca o libera por não ter conferido."""


def say(c: str, a: list, flow):
    """O texto de UMA variante: o que `c a…` imprime (stdin = flow, None = não sei), ou None = não sei."""
    if c == "echo":
        fl = ""
        while a and re.fullmatch(r"-[neE]+", a[0]):
            fl, a = fl + a[0], a[1:]
        return (ANSI.sub(ansi, " ".join(a)) if "e" in fl else " ".join(a)) + "\n"
    a = a[1:] if c == "printf" and a[:1] == ["--"] else a
    if c == "printf" and a:  # o formato reaproveitado até acabar os argumentos, como o printf do shell; sem conversão, uma vez só; o argumento do %b leva os escapes decodificados
        f = ANSI.sub(ansi, a[0])
        n = sum(m.group() != "%%" for m in PFMT.finditer(f))
        conv = lambda m, it: "%" if m.group() == "%%" else ANSI.sub(ansi, next(it, "")) if m.group()[-1] == "b" else next(it, "")  # noqa: E731
        return "".join(PFMT.sub(lambda m, it=iter(a[1 + i:1 + i + n]): conv(m, it), f) for i in range(0, max(len(a) - 1, 1) if n else 1, n or 1))
    if flow is not None and (c == "tee" or c == "cat" and all(x[:1] == "-" for x in a)):  # só repassam o stdin (cat com arquivo lê o arquivo)
        return flow
    if flow is not None and c == "base64" and {"-d", "--decode", "-D"} & set(a):
        import base64  # aqui e não no topo: o hook roda em todo comando Bash, e o import custa (~20 ms medidos sob carga)
        try:  # vazio → texto vazio; base64 inválido (ValueError) → None = não sei, nunca "vazio"; byte que não é texto vira U+FFFD (o resto continua conferido)
            return base64.b64decode(flow).decode(errors="replace")
        except ValueError:
            return None
    return "\n".join(x[::-1] for x in flow.split("\n")) if flow is not None and c == "rev" else None


def printed(seg: list, flow, may: dict):
    """Os textos que o comando pode imprimir (uma lista: cada variável do argumento pode guardar mais de um texto), ou None = não sei. Só o que dá para ler sem rodar nada:
    echo/printf com texto literal; cat/tee (repassam), base64 -d e rev sobre o que chegou pelo pipe (flow, None = não sei). O shell que lê o pipe sem -c e o
    `eval "$(…)"` conferem esses textos como comando. A variante que não leio (None) fica de fora; sem nenhuma que eu leia → None."""
    _, s, _, opq = peel(seg)
    c, a = (os.path.basename(s[0]), s[1:]) if s and not opq else ("", [])
    # `c='…'; echo "$c" | sh`, `echo "$(echo … | base64 -d)" | sh`: variável e $( ) lidos como no eval
    outs = [say(c, v, None) for v in reveal(a, may)] if c in ("echo", "printf") else [say(c, a, f) for f in (flow if flow is not None else [None])]
    return [o for o in outs if o is not None] or None


def pipefed(seg: list, flow):
    """Shell ligado por um pipe a textos que conheço (flow): sem -c ele lê o programa do stdin, que é `sh -c '<texto>'`. O -c e o texto vão para o fim do trecho, e então
    quem confere o trecho — agora, ou na CHAMADA da função em que ele está — já sabe abri-lo (com -c próprio vale o primeiro -c: o shell ignora o stdin). Mais de um texto
    possível: um script só, um depois do outro (só aumenta o que bloqueia). flow None = não sei."""
    if flow is None:
        return seg
    _, s, _, opq = peel(seg)
    return seg if opq or not s or os.path.basename(s[0]) not in SHELLS else seg + ["-c", "\n".join(flow)]


def pipe_out(body: str, may: dict):
    """O que o miolo de um `$( )` imprime quando é só um pipeline que sei ler (printed); None = não sei (outro operador, ou um comando que não leio)."""
    flow, seg = None, []
    for tok, op in words(body) + [("|", True)]:
        if not op:
            seg.append(tok)
        elif tok in PIPES:
            flow, seg = printed(seg, flow, may), []
        else:
            return None
    return flow


def texts(w: str, may: dict):
    """Os textos que a palavra `w` pode ter depois de expandida, só do que dá para ler sem rodar nada: um `$( )` que só imprime texto (pipe_out), `$NOME`/`${NOME}` de
    variável que guardo (may: TODOS os textos que ela pode ter, ver setvar) e a própria palavra. None = não sei (`$( )` que não leio, variável sem texto): quem chama decide se isso
    é "fica como está" (reveal) ou "NOME passa a não ter texto" (setvar). Só a palavra INTEIRA é trocada, nunca um pedaço dela."""
    m, v = SUBST.fullmatch(w), VAR.fullmatch(w)
    # vazio (variável sem texto, $( ) que não leio) → None, a palavra fica; falhou/ilegível (hex do marcador inválido) → a exceção sobe e main() bloqueia
    t = pipe_out(bytes.fromhex(m.group(1)).decode(), may) if m else may.get(v.group(1) or v.group(2)) if v else [w]
    return list(dict.fromkeys(x.rstrip("\n") if m else x for x in t)) if t else None


def reveal(ws: list, may: dict) -> list:
    """As VARIANTES das palavras de um `eval`/`echo`: cada palavra com seus textos possíveis (texts), uma variante por combinação. Palavra sem texto fica como está.
    Mais de MANY variantes → Many (o pedido bloqueia): truncar deixaria passar a combinação que ficou de fora."""
    out = [[]]
    for w in ws:
        out = [o + [t] for o in out for t in texts(w, may) or [w]]
        if len(out) > MANY:
            raise Many
    return out


def wopt(w: str, seg: list):
    """Lê as opções do embrulho `w` no começo de `seg` (o que vem DEPOIS do nome dele): devolve (o resto, cego), ou None = há opção que não está na tabela WOPT
    do embrulho, e então não sei onde o comando começa (a palavra seguinte pode ser o valor da opção ou o próprio comando). cego = alguma opção muda o diretório."""
    flag, arg, joined, chd = (set(x.split()) for x in WOPT[w])  # vazio → n/a (só é chamado com w em WRAP); falhou → KeyError, e main() bloqueia o pedido que cita git
    blind = False
    while seg and seg[0][:1] == "-":
        t, seg = seg[0], seg[1:]
        if t == "--":
            break
        if t[:2] == "--":
            name, eq, val = t.partition("=")
            given = [(name, val if eq else None)]
        elif w == "nice" and t[1:].isdigit():  # `nice -5 git …`
            continue
        else:  # `-nE`, `-oL`, `-I{}`: as letras uma a uma; a letra com valor leva o resto da palavra, ou a palavra seguinte se não sobrou nada
            given = []
            for k, ch in enumerate(t[1:]):
                given.append(("-" + ch, t[k + 2:] or None))
                if "-" + ch in arg | joined:
                    break
        for name, val in given:
            if name not in flag | arg | joined:
                return None
            if name in arg and val is None:
                val, seg = (seg[0] if seg else ""), seg[1:]
            blind = blind or name in chd
            if name in SPLIT:
                seg = [val or ""] + seg
    if w == "timeout" and seg and NUM.fullmatch(seg[0]):  # a duração é a primeira palavra sem `-`
        seg = seg[1:]
    return seg, blind


def peel(seg: list):
    """Tira atribuições (VAR=x) e embrulhos (command, env, sudo, xargs…) do começo: devolve (atribuições, o comando de verdade, cego, opaco).
    cego = uma opção do embrulho (env -C/-S/--chdir, sudo -D) muda onde o comando roda e o guarda não a modela: o diretório vira "não sei".
    opaco = o embrulho tem uma opção que não conheço: não sei onde o comando começa, e ele vale como lançador OPACO (seg volta começando no embrulho)."""
    env: dict = {}
    blind = False
    while seg:
        m = ASSIGN.fullmatch(seg[0])
        if m:
            env[m.group(1)], seg = m.group(2), seg[1:]
        elif os.path.basename(seg[0]) in WRAP:
            r = wopt(os.path.basename(seg[0]), seg[1:])
            if r is None:
                return env, seg, blind, True
            seg, b = r
            blind = blind or b
        elif seg[0] in KEYWORDS:  # `if git …`, `then git …`, `{ git …`, `! git …`: o comando começa na palavra seguinte
            seg = seg[3:] if seg[0] == "coproc" and seg[2:3] == ["{"] else seg[1:]  # `coproc NOME { git …; }` tem um nome no meio
        elif seg[0] == "function":  # `function f { git …; }`: o nome vai embora, o `{` é palavra reservada
            seg = seg[2:]
        else:
            break
    return env, seg, blind, False


def chdir(args: list, cwd, push: bool):
    """Diretório depois de `cd`/`pushd`, ou None = não sei. Só leio o que conheço: as opções -L/-P/-e/-@, o `--` e UM argumento. Opção que não conheço,
    mais de um argumento (no bash o cd falha, no zsh troca texto do caminho), `-`, `pushd +N/-N` (gira a pilha) e `pushd` sem argumento (troca o topo)
    → None. vazio (cd sem argumento) → HOME. Nunca devolve o diretório de antes por não ter entendido: isso seria "sei onde estou" sem saber."""
    while args and re.fullmatch(r"-[LPe@]+", args[0]):
        args = args[1:]
    if args[:1] == ["--"]:
        args = args[1:]
    if len(args) > 1 or (push and not args) or (args and args[0][:1] in ("-", "+")):
        return None
    p = res(args[0] if args else "~", cwd)
    return p if p is None or os.path.isdir(p) else None  # diretório que não existe na hora do hook: o cd FALHA e o shell fica onde estava → "não sei"


def dests(sub: str, rest: list) -> list:
    """As palavras que dizem ONDE o git escreve quando o lugar vem como argumento (e não como -C/--git-dir): em DEST toda palavra, o valor de `--opção=valor` e o
    `-oVALOR` colado; em qualquer subcomando o valor de PATHOPT (`--output=x`, `--prefix x`). URL (`https://…`) não é caminho."""
    out, val = [], False
    for t in rest:
        name, eq, v = t.partition("=")
        if val:  # o valor da opção anterior, no token seguinte
            out, val = out + [t], False
        elif name in PATHOPT:
            out, val = (out + [v], False) if eq else (out, True)
        elif sub in DEST:
            out.append(v if t[:2] == "--" and eq else "" if t[:2] == "--" else t[2:] if t[:1] == "-" else t)
    return [x for x in out if x and not URL.match(x)]


def git_hit(seg: list, env: dict, cwd, terr: str, own):
    gd, wt, i, lost = env.get("GIT_DIR"), env.get("GIT_WORK_TREE"), 1, False
    runs = any(CFG_ENV.fullmatch(k) for k in env)  # o git deste comando pode rodar um programa que o guarda não vê (configuração injetada): leitura deixa de valer como leitura
    while i < len(seg) and seg[i].startswith("-"):
        a = seg[i]
        if a == "-C" and i + 1 < len(seg):
            cwd, i = res(seg[i + 1], cwd), i + 2
        elif a in ("-c", "--config-env") and i + 1 < len(seg):
            runs, i = runs or not CFG_SAFE.fullmatch(seg[i + 1].partition("=")[0]), i + 2
        elif a in ("--namespace", "--attr-source") and i + 1 < len(seg):  # valor no token seguinte: sem pular, ele viraria o subcomando e o `-C` depois dele nunca seria lido
            i += 2
        elif a.startswith("--config-env="):
            runs, i = runs or not CFG_SAFE.fullmatch(a.partition("=")[2].partition("=")[0]), i + 1
        elif a in ("-p", "--paginate") or a.startswith("--exec-path"):  # o pager e o diretório de programas do git são programas que o guarda não vê
            runs, i = True, i + 1
        elif a.startswith(("--git-dir", "--work-tree")):
            k, _, v = a.partition("=")
            if not v and i + 1 < len(seg):
                v, i = seg[i + 1], i + 1
            gd, wt = (v, wt) if k == "--git-dir" else (gd, v)
            i += 1
        else:  # opção de topo que não conheço pode levar um valor no token seguinte: não sei onde está o subcomando nem o `-C` que viria depois → diretório "não sei", e vale como escrita
            if not GIT_FLAG.fullmatch(a):
                lost, cwd = True, None
            i += 1
    sub, rest = (seg[i] if i < len(seg) else ""), seg[i + 1:]
    if SHELLY.search(sub):  # `git $FLAGS -C x commit`, `git "$@"`: o shell ainda expande a palavra do subcomando, e o que sair pode ser opção (um `-C`) que não leio → diretório "não sei", e vale como escrita
        lost, cwd = True, None
    read = not lost and is_read(sub, rest)
    if read and not runs:
        return None
    for t in [cwd] + [res(x, cwd) for x in (gd, wt) if x] + [res(x, cwd) for x in dests(sub, rest)]:
        if t is None or (inside(t, terr) and not (own and inside(t, own))):
            return t, "git " + sub + (" (leitura com configuração que roda programa: -c, GIT_PAGER…)" if read else "")
    return None


class Budget(Exception):
    """Estourou o teto de passos ou de segundos: o pedido NÃO foi conferido, então não passa — main() bloqueia. O guarda se corta ANTES do prazo do hook no Claude Code (600 s), porque hook estourado não bloqueia: a chamada seguiria sem conferência."""


def tick(n: int = 1) -> None:
    """Unidades de trabalho: 1 por trecho que one() confere (o comando aninhado também passa por ele), n por n entradas copiadas ao registrar uma aninhada. Passou de STEP_LIMIT → Budget."""
    WORK[0] += n
    if WORK[0] > STEP_LIMIT:
        raise Budget(f"mais de {STEP_LIMIT} passos de conferência")


def scan(cmd: str, cwd, terr: str, own, depth: int = 0, env=None, funcs=None, may=None):
    """O 1º (alvo, operação) de escrita contra clone alheio, ou None (alvo None = não resolvi). env/funcs/may = contexto de quem chamou: o aninhado nunca começa do zero."""
    if depth > 3:
        return None, "comando aninhado fundo demais para conferir"
    st, stack, seg = {"cwd": cwd, "env": dict(env or {}), "funcs": {} if funcs is None else funcs, "may": {k: list(v) for k, v in (may or {}).items()}}, [], []

    def seen(env: dict, keep: bool = False) -> dict:  # os textos que cada variável pode ter para um comando com o prefixo `env` (NOME=x cmd): o prefixo vale no lugar; keep = o prefixo vale JUNTO (o eval expande `"$NOME"` antes e `'$NOME'` depois)
        return {**st["may"], **{k: list(dict.fromkeys((st["may"].get(k, []) if keep else []) + (texts(v, st["may"]) or []))) for k, v in env.items()}}

    def sub(text: str, cwd, env: dict):  # trecho aninhado: mesmo contexto (variáveis do trecho de fora + as desta palavra, funções)
        return scan(text, cwd, terr, own, depth + 1, {**st["env"], **env}, st["funcs"], seen(env))

    def setvar(name: str, ts, unsure: bool, val: str = "$?"):
        """NOME passa a guardar `val` em env (o que o git lê: GIT_DIR…; "$?" = não sei) e os textos `ts` em may (o que eval/pipe leem; None = não sei o texto). Trecho que PODE não ter rodado:
        env vira "não sei" e may GUARDA os textos de antes E os novos — um valor inofensivo que talvez não tenha sido gravado não apaga o nocivo que talvez continue lá."""
        st["env"][name] = "$?" if unsure else val
        if not unsure:
            st["may"][name] = ts or []  # sei que rodou: o texto de antes acabou; sem texto legível (None) → vazio, nada a conferir
        elif ts:
            st["may"][name] = list(dict.fromkeys(st["may"].get(name, []) + ts))  # sem texto legível (None) → fica o que havia

    def inner(ws: list):
        for w in ws:  # $(…) e crases dentro de qualquer palavra rodam (até no valor de VAR=…, ou no alvo de um redirecionamento): confere o miolo
            for m in SUBST.finditer(w):
                r = sub(bytes.fromhex(m.group(1)).decode(), st["cwd"], {})
                if r:
                    return r
        return None

    def call(c: str, blind: bool, maybe: bool = False):  # reexecuta AGORA, neste cwd, o corpo guardado da função c: o 1º (alvo, operação) de escrita, ou None. maybe = a chamada pode não ter rodado (`[ -f x ] && f`): o corpo também
        st.setdefault("calling", set()).add(c)
        saved, was = st.get("lost"), st.get("maybe")  # a região perdida de quem chamou continua depois que esta chamada acaba: o que vem depois pode ser o resto do corpo que não roda; o mesmo vale para o "talvez"
        st["maybe"] = was or maybe
        try:
            body = list(st["funcs"][c])  # cópia: definir uma aninhada ali dentro acrescenta à lista de quem a define, e o que se acrescenta não é revisto nesta passada
            for i, (s, p, t) in enumerate(body):
                st["rest"] = body[i:]
                r = one(list(s), blind, p, t)
                if r:
                    return r
        finally:
            st["calling"].discard(c)
            st["lost"], st["maybe"] = saved, was
        return None

    def one(seg: list, blind: bool = False, prev: str = "", term: str = ";", ext: bool = False):  # ext = trecho que um programa roda (find -exec): cd ali não muda o shell; prev/term = o operador antes e depois do trecho: dizem se um cd rodou com certeza
        tick()
        r = inner(seg)
        if r:
            return r
        kw = bool(seg) and seg[0] in ("!", "coproc")
        if st.get("chain") and prev != "&&":
            st["cwd"], st["chain"] = None, False  # a cadeia && que sustentava um cd condicional acabou (`;`, `||`, `&`, newline…): não sei se ele rodou
        if seg and seg[0] in ("fi", "done", "esac", "else", "elif") and st.pop("cdblk", False):
            st["cwd"] = None
        blk = bool(seg) and seg[0] in ("if", "then", "else", "elif", "do", "while", "until")
        if seg and seg[0] != "{":
            st.pop("func", None)  # a cabeça `f (` que não foi seguida de `{` não era uma definição: a bandeira não pode ficar velha para o próximo `{` do texto
        if st.get("fdepth"):  # dentro de `f() { … }`: o corpo NÃO roda agora — guardo os trechos e confiro na CHAMADA, no cwd de lá (um git ali roda onde `f` for chamada)
            st["fdepth"] += seg.count("{") - seg.count("}")
            if seg != ["}"]:
                st["funcs"].setdefault(st["fname"], []).append((seg, prev, term))
            elif not st["fdepth"] and term == "&":
                st["cwd"] = None
            return None
        if st.get("calling"):
            if len(seg) == 1 and term == "(" and seg[0] not in KEYWORDS:
                st["nhead"] = seg[0]  # a cabeça `g (` de uma definição aninhada: o `{` que vem a seguir é o corpo dela
            elif seg and seg[0] != "{":
                st.pop("nhead", None)  # a cabeça que não foi seguida de `{` não era uma definição: a bandeira não pode ficar velha para o próximo `{`. Enquanto vale, o `{` é o corpo mesmo com um newline entre `g()` e ele (o separador é então o `;` do newline, não o `)`)
            if seg[:1] == ["function"] or seg[:1] == ["{"] and (prev == ")" or st.get("nhead")):  # definição aninhada num corpo reexecutado (`function g {`, `g() {`): o corpo dela não roda agora e onde ele acaba eu não sei (o `}` que o fecha não fica guardado)
                st["lost"] = True  # até o fim desta reexecução, `cd` e atribuição de variável valem "não sei" (ver unsure e o ramo do cd): o que o corpo que não roda faz não pode valer para o que vem depois
                nm = seg[1] if seg[0] == "function" and seg[1:2] else st.pop("nhead", None)
                if nm:  # a aninhada passa a existir: uma chamada dela depois, de fora, confere o resto desta lista (mais do que o corpo dela, que não sei onde acaba: lado fechado)
                    rest = st.get("rest") or ()
                    key = (nm, id(rest[0]) if rest else 0)
                    if key not in st.setdefault("regd", set()):  # a MESMA definição reexecutada (chamar g de novo: o corpo registrado traz o próprio cabeçalho) não se registra outra vez: a lista dobrava a cada chamada e 7 chamadas de g estouravam o teto
                        st["regd"].add(key)
                        tick(len(rest))  # a cópia custa tanto quanto conferir o que ela copia: conta no teto (centenas de aninhadas num corpo só não enchem a memória)
                        st["funcs"].setdefault(nm, []).extend(rest)
        if not st.get("calling") and (seg[:1] == ["{"] and st.pop("func", False) or seg[:1] == ["function"] and seg[2:3] == ["{"]):  # nunca ao REEXECUTAR um corpo guardado (calling): o `{` guardado ali reabria a definição com o nome velho, desviava o resto do corpo para a lista errada e o laço de chamada percorria essa lista sem fim (ga-tih62nv)
            if seg[0] == "function":
                st["fname"], seg = seg[1], seg[2:]
            st["fdepth"], st["funcs"] = 1, st.get("funcs", {})
            st["funcs"].setdefault(st["fname"], [])
            if seg[1:]:
                st["funcs"][st["fname"]].append((seg[1:], ";" if prev == ")" else prev, term))  # só o `)` do `f()` vira ";" (senão um corpo que começa por um grupo `{ … }` pareceria uma definição aninhada ao ser reexecutado); `||`, `&&`, `|`, `&` antes de `function f {` ficam: a definição pode não ter rodado
            return None
        if seg == ["}"]:
            if term == "&":
                st["cwd"] = None  # `{ …; } &`: o grupo roda em background; o cd de dentro não vale aqui fora
            return None
        lead = next((x for x in seg if x not in LEAD), "")  # a 1ª palavra que não é palavra reservada de ligação (`then if x; …` abre um bloco)
        if lead in ("fi", "done", "esac"):  # bloco em VÁRIAS linhas (`if …; then⏎ c=ok⏎ fi`): quem está dentro de if/for/while/until/case/select PODE não ter rodado, igual à forma de uma linha (que o `then`/`do` do trecho já marca)
            st["bdepth"] = max(st.get("bdepth", 0) - 1, 0)
        elif lead in ("if", "for", "while", "until", "case", "select"):
            st["bdepth"] = st.get("bdepth", 0) + 1
        fw, done = next((x for x in seg if x not in KEYWORDS and not ASSIGN.fullmatch(x)), ""), ""  # a palavra que o shell chama: a 1ª que não é VAR=x nem palavra reservada
        norun = bool(st.get("lost")) or kw or blk or prev in ("||", "|", "|&", "case)") or term in ("|", "|&", "&", ";;") or (prev == "&&" and term != "&&") or bool(st.get("maybe")) or st.get("bdepth", 0) > 0  # o trecho pode não ter rodado (maybe = o corpo de uma função chamada por um trecho assim; bdepth = dentro de um bloco aberto em linha anterior)
        if fw in st.get("funcs", {}) and fw not in st.setdefault("calling", set()):  # uma função com nome de comando que trato adiante (bash, env, cd, find, eval, export, sudo, git…) é chamada como FUNÇÃO: o corpo roda, e o resto do trecho segue conferido como se o nome fosse o programa (command X e env X ignoram a função: lado fechado)
            r = call(fw, blind, norun)
            if r:
                return r
            done = fw
        w0 = [os.path.basename(x) for x in seg]
        env, seg, b, opq = peel(seg)
        blind, wrapped = blind or b, any(x in WRAP for x in w0[:len(w0) - len(seg)])  # wrapped: `env cd x` roda o cd como PROGRAMA — o shell fica onde estava
        unsure = norun or bool(done)  # o trecho pode não ter rodado; done = a palavra de comando era uma função com nome de programa: o que o programa de verdade faz eu não sei
        if not seg:
            for k, v in env.items():  # `GIT_DIR=x; git …` vale p/ os seguintes; `true || GIT_DIR=x` = "não sei" ($ → não resolve)
                setvar(k, texts(v, st["may"]), unsure, v)
            return None
        cwd, c = None if blind else st["cwd"], os.path.basename(seg[0])
        if st.pop("or", False) and prev == "||" and c not in ("exit", "return"):
            cwd = st["cwd"] = None  # `cd a || cd b`, `cd a || true`: depois disto o shell pode estar em a OU onde estava; só `|| exit`/`|| return` mantém (se o cd falhou, nada mais roda)
        if " " in seg[0]:  # env -S 'git -C x commit': um comando inteiro numa palavra só
            return sub(" ".join(seg), cwd, env)
        if c in ("export", "declare", "typeset"):
            for m in filter(None, map(ASSIGN.fullmatch, seg[1:])):
                setvar(m.group(1), texts(m.group(2), st["may"]), unsure, m.group(2))
        elif c in ("cd", "pushd", "popd"):
            new = None if c == "popd" else chdir(seg[1:], st["cwd"], c == "pushd")
            if st.get("lost") or kw or wrapped or ext or prev in ("||", "|", "|&", "case)") or term in ("|", "|&", "&", ";;") or (prev == "&&" and term != "&&"):
                new = None
            if done:
                new = None  # a função chamada cd/pushd/popd foi reexecutada acima: o que ela fez de verdade com o diretório eu não sei, e o cd modelado aqui pode nem ter rodado
            if (blk or st.get("bdepth", 0) > 0) and new is not None:
                st["cdblk"] = True  # cd dentro de um ramo: vale até o fi/done/esac/else/elif
            if prev == "&&" and new is not None:
                st["chain"] = True  # cd que não é o 1º da cadeia (`x && cd a && …`): vale só enquanto a cadeia && continua (ver o topo de one())
            st["cwd"] = new
            if new is not None and term == "||":
                st["or"] = True  # o trecho seguinte decide: `|| exit` mantém, qualquer outra coisa vira "não sei"
        elif c in OPAQUE or opq:  # não modelo o que o lançador faz com diretório e ambiente: o git de dentro (palavra solta ou texto entre aspas) vale com diretório "não sei"
            for j, t in enumerate(seg[1:], 1):
                if os.path.basename(t) == "git":  # as palavras seguintes são argumentos do git (mensagem de commit…), não outro comando
                    return git_hit(seg[j:], {**st["env"], **env}, None, terr, own)
                if re.search(r"\s", t):
                    r = sub(t, None, env)
                    if r:
                        return r
        elif c in SHELLS:
            for j, t in enumerate(seg[1:-1], 1):
                if re.fullmatch(r"-[a-z]*c[a-z]*", t):
                    script = seg[j + 1:]
                    while len(script) > 1 and script[0][:1] in ("-", "+"):  # `bash -c -e 'cmd'`, `bash -c -- 'cmd'`: o script é a primeira palavra que não é opção
                        stop, script = script[0] == "--", script[1:]
                        if stop:
                            break
                    return sub(script[0], cwd, env)
        elif c == "eval":  # `eval "$(echo … | base64 -d)"`, `eval "$NOME"`: cada texto que dá para ler vira uma variante do que se confere (um script só: só aumenta o que bloqueia)
            return sub("\n".join(" ".join(v) for v in reveal(seg[1:], seen(env, True))), cwd, env)
        elif c == "printf" and seg[1:2] == ["-v"] and len(seg) > 3:  # printf -v NOME FORMATO ARGS…: NOME passa a guardar o texto; trecho que pode não ter rodado soma o texto novo ao de antes (setvar)
            t = printed(["printf"] + seg[3:], None, st["may"])  # vazio → NOME vazio; formato que não leio (None) → sem texto
            setvar(seg[2], t, unsure, t[0] if t and len(t) == 1 else "$?")
        elif INTERP.fullmatch(c):  # python -c / node -e / perl -e / awk: o texto entre aspas do código (os.system, shell=True, execSync, system, crase) roda num shell e é conferido como comando; lista de argumentos e texto montado em pedaços: não vejo
            cw = None if CODECD.search(" ".join(seg)) else cwd  # os.chdir / cwd=: o shell de dentro roda noutro diretório
            for t in seg[1:]:
                m = ASSIGN.fullmatch(t)  # `awk -v cmd="git …"`: o valor de NOME=valor também pode ser o comando (o peel o engoliria como atribuição); o literal vale com os escapes decodificados (`'\x67it …'` é git)
                for text in [t] + ([m.group(2)] if m else []) + [ANSI.sub(ansi, ([x for x in g if x] or [""])[-1]) for g in LIT.findall(t)]:
                    r = sub(text, cw, env)
                    if r:
                        return r
        elif c == "find":  # o `\;` e o `\(` do find são palavras (words() não os toma por operador do shell): todos os `-exec` do find estão neste trecho
            for j, t in enumerate(seg):
                if t in ("-exec", "-execdir", "-ok", "-okdir"):  # -exec/-ok rodam no diretório do find; -execdir/-okdir no de CADA achado, que não sei qual é: cego
                    r = one(seg[j + 1:], blind or t.endswith("dir"), ext=True)
                    if r:
                        return r
        elif c in st.get("funcs", {}) and c not in st.setdefault("calling", set()):  # chamada de função definida nesta chamada: o corpo roda AGORA, neste cwd
            if c != done:  # (já reexecutada acima quando era a palavra de comando; aqui chega o que um embrulho escondia: time f, command f)
                r = call(c, blind, unsure)  # chamada que pode não ter rodado: o corpo também (`[ -f x ] && f`)
                if r:
                    return r
            if c == "git":  # uma função chamada git NÃO isenta a chamada: a definição pode não ter rodado (`false && function git`, subshell, chamada condicional) e `command git`, `env git` e `\git` ignoram a função; o corpo já foi conferido acima, e o git de verdade também
                return git_hit(seg, {**st["env"], **env}, cwd, terr, own)
        elif c == "git":
            return git_hit(seg, {**st["env"], **env}, cwd, terr, own)
        return None

    skip, herestr, prev, flow, hs = False, False, "", None, None  # flow = o que o trecho anterior imprime, se um pipe o liga ao próximo; hs = o texto do here-string do trecho (o stdin dele, no lugar do pipe)
    for tok, op in words(cmd) + [(";", True)]:  # o `;` do fim fecha o último trecho
        if skip and not op:  # alvo de redirecionamento: só uma PALAVRA é alvo. Operador logo depois (`git … >` sem alvo, que o shell recusa) segue como operador: engolir o `;` do fim ou o `&&` deixava o trecho sem conferir
            skip = False
            r = inner([tok])  # `> $(git -C x commit)`: o $( ) do alvo roda
            if r:
                return r
            if herestr and runs_text(seg):  # `bash <<< 'git -C x commit'`: a palavra é o script que o shell vai ler
                r = sub(tok, st["cwd"], {})
                if r:
                    return r
            hs = [v[0] for v in reveal([tok], st["may"])] if herestr else hs  # `cat <<< '…' | sh`, `base64 -d <<< B64 | sh`: o texto é o stdin do produtor do pipe
            herestr = False
        elif op:  # o shlex junta pontuação colada (`);`, `&&(`, `2>&1`): separa de novo
            skip = herestr = False  # um operador que chega com um redirecionamento esperando alvo não é o alvo
            for pc in PIECE.findall(tok):
                if pc in SEPS or pc in ("(", ")"):
                    r = one(pipefed(seg, flow), False, prev, pc)
                    if r:
                        return r
                    flow, hs = printed(seg, flow if hs is None else hs, st["may"]) if pc in PIPES else None, None
                    c0 = next((i for i, w in enumerate(seg) if w not in KEYWORDS), len(seg))  # onde começa o comando do trecho
                    if seg[c0:c0 + 1] == ["case"] and "in" in seg[c0 + 2:]:
                        stack.append(None)  # `case … in`: o `)` que vem a seguir fecha um PADRÃO, não um subshell (a marca sai da pilha no `esac`)
                    elif seg[c0:c0 + 1] == ["esac"] and None in stack:
                        del stack[len(stack) - 1 - stack[::-1].index(None):]  # o `esac` fecha o `case` mais de dentro; subshell aberto dentro dele (script malformado) sai sem voltar nada
                    if pc == "(":
                        if not skip and (len(seg) == 1 and seg[0] not in KEYWORDS or len(seg) == 2 and seg[0] == "function" and seg[1] not in KEYWORDS):
                            st["func"], st["fname"] = True, seg[-1]  # `f (` e `function f (`: definição de função — o `{ … }` que vem a seguir é corpo que não roda agora
                        stack.append((st["cwd"], dict(st["env"]), {k: list(v) for k, v in st["may"].items()}))  # o `( )` roda num subshell: diretório e variáveis voltam a ser estes no `)`
                        skip = False  # `<(cmd)` / `>(cmd)`: o `<` que vem colado no `(` não é redirecionamento de arquivo, a palavra seguinte é um comando
                    elif pc == ")":
                        if stack and stack[-1] is not None:
                            st["cwd"], st["env"], st["may"] = stack.pop()
                        else:
                            pc = "case)"  # `)` sem `(` de subshell aberto (pilha vazia, ou o `case` mais de dentro é o que está aberto): fim de um padrão de `case` — o ramo pode nem rodar
                    seg, prev = [], pc
                else:
                    skip, herestr = True, pc == "<<<"  # redirecionamento: a palavra seguinte é o arquivo (ou, no here-string, o texto)
        else:
            seg.append(tok)
    if st.get("fdepth"):  # o fim da função não fecha (uma `{` entre aspas desconta a conta): a chamada pode ter caído no corpo — confiro o corpo como se rodasse, em diretório "não sei"
        st["fdepth"] = 0
        st.setdefault("calling", set()).add(st["fname"])  # este corpo também é reexecutado: conferido, não relido como definição (ver o `{` em one)
        body = list(st["funcs"].get(st["fname"], []))  # cópia, pelo mesmo motivo do laço de chamada de função acima
        for i, (s, p, t) in enumerate(body):
            st["rest"] = body[i:]
            r = one(list(s), True, p, t)
            if r:
                return r
    return None


def decide(inp: dict, terr: str, proj):
    """None = liberado; (alvo, operação) = bloqueado. Budget (passos demais) sobe para main(): sem veredito não há "liberado"."""
    WORK[0] = 0
    tool, ti, cwd = inp.get("tool_name"), inp.get("tool_input") or {}, inp.get("cwd") or None
    own = own_clone(proj, terr)
    if tool == "Bash":
        try:
            return scan(str(ti.get("command") or ""), os.path.realpath(cwd) if cwd else None, terr, own)
        except Many:
            return None, "eval/pipe com variáveis demais para conferir"
    if tool in TOOLS_FILE:
        p = res(str(ti.get(TOOLS_FILE[tool]) or ""), os.path.realpath(cwd) if cwd else None, shell=False)
        if p is None or claude_conf(p) or (inside(p, terr) and not (own and inside(p, own))):
            return p, "escrita de arquivo (" + tool + ")" + (" em hook/settings do claude" if p and claude_conf(p) else "")
    return None


def message(hit, terr: str, proj) -> str:
    target, op = hit
    own = own_clone(proj, terr)
    why = (f"Alvo: {target}\n" if target else "Alvo: não consegui resolver o caminho (variável, glob, crase ou ~usuário)\n")
    mine = own or ("(nenhum: CLAUDE_PROJECT_DIR não definido)" if not proj else "(nenhum: CLAUDE_PROJECT_DIR " + proj
                   + (" está no território " + terr + " mas não tem .git até a raiz dele)" if inside(os.path.realpath(proj), terr) else " fora do território " + terr + ")"))
    return ("[HOOK BLOCK: remote-clone-guard] NÃO É CANCELAMENTO DO USUÁRIO — política automática de isolamento entre sessões.\n"
            f"BLOQUEADO: {op} fora do seu clone.\n{why}Seu clone: {mine}\n"
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
        hook_re = re.compile(r"python3\s+-I\s+" + re.escape(me) + r"\s+\|\|\s+exit\s+2")  # o comando INTEIRO; citar o arquivo (echo, #, outro && …) não vale
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
                # além do comando, nenhum campo que mude QUANDO o hook dispara (`if`: o hook antigo só disparava em `git -C *`; `async`…). vazio → o grupo/hook sem campo extra vale; ilegível (grupo ou hook que não é objeto) → AttributeError/TypeError, e o selfcheck falha
                if not any((g.get("matcher") in (None, "", "*") or re.fullmatch(g["matcher"], tool)) and set(g) <= {"matcher", "hooks"}
                           and any(hook_re.fullmatch(h.get("command", "").strip()) and h.get("type") == "command" and set(h) <= {"type", "command", "timeout"} for h in g.get("hooks", []))
                           for g in groups):
                    raise ValueError(f"{tool}: nenhum hook PreToolUse é exatamente `python3 -I {me} || exit 2` (sem `if`, async… — só type/command/timeout)")
        except (OSError, ValueError, AttributeError, KeyError, TypeError, re.error) as e:
            ok = False
            print(f"selfcheck: settings {args[0]}: {e}", file=sys.stderr)
    print("selfcheck: " + ("ok" if ok else "FALHOU"))
    return 0 if ok else 1


def expired(signum, frame):
    raise Budget(f"mais de {TIME_LIMIT:g} s")


def late(why: str) -> str:
    return ("[HOOK BLOCK: remote-clone-guard] NÃO É CANCELAMENTO DO USUÁRIO — política automática de isolamento entre sessões.\n"
            f"BLOQUEADO: não consegui analisar este pedido a tempo ({why}), e o que o guarda não consegue conferir não passa.\n"
            "Reescreva em pedaços menores: um comando por chamada, sem definir função nem aninhar $( ), case ou eval no mesmo pedido. "
            "Para um script longo, grave o arquivo com a ferramenta Write e rode-o pelo caminho.\n")


def main(argv: list) -> int:
    if argv[1:2] == ["--selfcheck"]:
        return selfcheck(argv[2:])
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, TIME_LIMIT)  # armado antes de ler o stdin: o prazo do hook no Claude Code é 600 s e, estourado, a chamada SEGUE sem conferência
    try:
        return judge()
    except Budget as e:  # falhou/estourou ≠ liberado: sem veredito o pedido é bloqueado, com a mensagem de como reescrever
        print(late(str(e)), file=sys.stderr)
        return 2
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


def judge() -> int:
    raw = sys.stdin.read()
    terr = os.path.realpath(os.environ.get("RCG_ROOT") or os.path.expanduser("~/gt-remote/git"))
    proj = os.environ.get("CLAUDE_PROJECT_DIR")
    inp = None
    try:
        inp = json.loads(raw)
        hit = decide(inp, terr, proj)
    except Budget:
        raise  # a mensagem própria é a de main()
    except Exception as e:  # noqa: BLE001 — falha do guarda não pode virar "liberado" quando o pedido pode tocar git ou arquivo
        if not (isinstance(inp, dict) and inp.get("tool_name") in {"Bash", *TOOLS_FILE}) and not re.search(r"git|file_path|notebook_path", raw):
            return 0  # JSON lido e é Bash/Edit/Write: bloqueia mesmo sem a palavra "git" no texto (`g''it` não a tem); sem ser JSON e sem citar, libera
        print(f"[HOOK BLOCK: remote-clone-guard] o guarda falhou ({type(e).__name__}) e não consigo conferir este pedido: bloqueado.", file=sys.stderr)
        return 2
    if hit:
        print(message(hit, terr, proj), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
