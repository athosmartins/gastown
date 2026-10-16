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
  próprio, e toda escrita no território é bloqueada). Para cada `git` do comando (depois de ; && || | ( ) { das palavras reservadas if/then/else/
  elif/do/while/until/!/function, de cd/pushd, de command/env/sudo/xargs/nohup…, de bash -c / eval / $(…) / crases / <(…) / find -exec|-execdir|-ok|-okdir, e do
  corpo de um heredoc ou here-string que um shell lê) o alvo é o diretório depois dos `-C` (relativos entre si), mais --git-dir/--work-tree/GIT_DIR/
  GIT_WORK_TREE, resolvido com realpath (symlink para outro clone não escapa). Subcomando que não está na lista de LEITURA (inclusive o que não
  conheço, alias…) conta como escrita. Leitura que traz configuração capaz de rodar um programa também conta: `-c`/`--config-env` com chave que não é só
  de exibição ou identidade (alias.*, core.pager/fsmonitor/sshCommand, diff.external, filter.*…), `-p`/`--paginate`, `--exec-path`, GIT_CONFIG_*/GIT_PAGER/
  GIT_EXTERNAL_DIFF/GIT_SSH*/GIT_EDITOR… (lista fechada: chave que não conheço = não sei = escrita). Alvo no território e fora do clone próprio → bloqueia; alvo que não consigo resolver ($VAR, glob, crase,
  ~usuário) numa escrita → bloqueia, com a mensagem dizendo para usar caminho literal.
  cd/pushd só muda o diretório que EU entendo: opções -L/-P/-e/-@, `--` e UM argumento; o resto (`cd -Z x`, dois argumentos, `pushd +1`, `pushd`
  sozinho) deixa o diretório "não sei". O mesmo vale para o que o git não deixa eu ler: opção de topo que não conheço (`git --nova VALOR -C x`: o VALOR pode ser
  o valor da opção ou o subcomando) → diretório "não sei" e vale como escrita. Cada embrulho (command/env/sudo/xargs/nice/timeout/stdbuf…) tem a tabela das SUAS
  opções (WOPT; `sudo -n` não é o `-n` do xargs) e só entendo o que está nela: opção que não está = não sei onde o comando começa, e o embrulho vale como
  lançador OPACO (abaixo). `find -exec`/`-ok` rodam no diretório do find; `-execdir`/`-okdir` rodam no de CADA achado, que não sei qual é → "não sei" (git de
  escrita ali só passa com `-C <caminho absoluto>`). `bash -c -e '…'`: o script é a primeira palavra depois do -c que não é opção. O número colado no
  redirecionamento (`2>/dev/null`) é o descritor, não um argumento. Lançadores que não modelo (flock, ionice, ssh, su -c, parallel, script -c, trap, watch, tmux…; a lista OPAQUE)
  são abertos com o diretório "não sei": o git dentro deles só passa se for leitura ou com `-C <caminho absoluto>`. Um embrulho com opção que não conheço vale como um deles.
  Falha do próprio guarda (exceção) → bloqueia, se o pedido cita git/file_path/notebook_path; um stdin que nem é JSON e não cita nenhum dos três
  LIBERA (lixo no stdin não derruba a sessão inteira; o Claude sempre manda JSON válido). O comando do hook é `python3 -I <este arquivo> || exit 2`,
  então travar, sumir o python ou o arquivo também sai com 2 (o hook que sai com 1 ou 127 NÃO bloqueia: seria falha aberta).

CÓDIGOS: 0 liberado · 2 bloqueado. `--selfcheck [settings.json [pasta-do-projeto…]]`: 0 se o guarda decide como deveria numa pasta de teste E
  (com o settings) todo PreToolUse de Bash/Edit/Write/MultiEdit/NotebookEdit é EXATAMENTE `python3 -I <este arquivo> || exit 2` (citar o arquivo
  noutro lugar do comando não vale) e sem campo que mude QUANDO ele dispara (`if`, `async`…: só type/command/timeout) e `disableAllHooks` não está ligado nele nem em <pasta>/.claude/settings[.local].json; 1 caso contrário (é o que o
  provider confere antes de abrir sessão real). Edit/Write em ~/.claude/hooks/** e ~/.claude/settings*.json também são bloqueados (o guarda não se
  desliga por engano).

LIMITES (é trava contra engano, não sandbox contra quem quer burlar). NÃO vejo: script que o comando executa (`bash x.sh`, `source x`), `python -c` e
  outras linguagens, variável que guarda o git ou o diretório, comando montado em pipe (`echo '…' | sh`), função ou alias definido em OUTRA chamada,
  CDPATH, redirecionamento de shell (`> arquivo`), `sed -i`, `rm`/`cp` no clone alheio ou nos hooks, e a configuração que JÁ está no .git/config do clone
  alheio (alias, filter, textconv, fsmonitor: uma leitura lá a executa). A lista OPAQUE é fechada: um lançador que não
  está nela (`lockrun git …`) esconde o git numa palavra que não abro. Falsos positivos que ficam (todos no lado fechado): git com diretório implícito atrás de um lançador da
  lista (`flock L git commit`), de um embrulho com opção que não conheço (`sudo --nova git commit`) ou de um `-execdir`/`-okdir` bloqueia; e `git --opção-nova VALOR -C
  <seu clone> commit` bloqueia. Escreva `git -C <caminho absoluto do seu clone>`. O fecho de verdade (usuário Unix por sessão) é outro
  trabalho; ver o runbook.
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
OPAQUE = {"flock", "ionice", "chrt", "taskset", "parallel", "su", "runuser", "ssh", "script", "trap", "watch", "unshare", "nsenter", "chroot", "setpriv", "numactl",
          "strace", "fakeroot", "systemd-run", "busybox", "dbus-run-session", "xvfb-run", "unbuffer", "caffeinate", "tmux", "screen", "expect"}  # lançadores que não modelo: lista FECHADA (ver LIMITES)
GIT_FLAG = re.compile(r"-[Phv]|--(?:no-pager|bare|no-replace-objects|no-lazy-fetch|no-optional-locks|no-advice|literal-pathspecs|glob-pathspecs|noglob-pathspecs|"
                      r"icase-pathspecs|no-global-excludes|version|help|html-path|man-path|info-path|attr-source=.*|namespace=.*|list-cmds=.*)")  # opções de topo do git que conheço e não levam o valor no token seguinte
ASSIGN, NUM = re.compile(r"([A-Za-z_]\w*)=(.*)", re.S), re.compile(r"[\d.]+[smhd]?")
FD = re.compile(r"(^|[\s;&|(])\d+(?=[<>])")  # `2>/dev/null`, `1>&2`: o número colado no redirecionamento é o descritor, não um argumento
SHELLY = re.compile(r"[$`*?\[{]")
PIECE = re.compile(r"&&|\|\||\|&|;;|[;&|()]|[<>]+&?")
SUBST, BACKTICK = re.compile(r"\$S([0-9a-f]*)\$"), re.compile(r"`([^`]*)`")
HEREDOC = re.compile(r"(<<-?\s*(['\"]?)(\w+)\2[^\n]*)\n(.*?)\n[ \t]*\3[ \t]*(?=\n|$)", re.S)
CONT = re.compile(r"(?<!\\)((?:\\\\)*)\\\n")  # barra + newline com número ÍMPAR de barras: continuação de linha (com número par a última barra é a barra escapada)


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
    """`git branch`/`git tag` que só LISTA. vazio → lista (é o que o comando sem nada faz); opção que não conheço, ou palavra solta (nome novo) sem opção
    de lista que a faça valer como padrão → não sei, e não sei é escrita."""
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
    """`git config` que só LÊ: pede a chave (--get…, --list) ou dá UMA palavra só (a chave) com no máximo o escopo (--local/--global…). Duas palavras
    é `chave valor` (grava); qualquer outra opção (--unset, --edit, --add…) grava ou abre editor."""
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


def runs_text(seg: list) -> bool:
    """O comando do trecho executa texto que recebe (shell, eval/source, ssh/su… — OPAQUE)? vazio → não; só o COMANDO decide, não as palavras (`git commit -m "bash"` não é shell)."""
    _, s, _, opq = peel(seg)  # opq = embrulho com opção que não conheço: não sei o que ele roda, vale como lançador
    return bool(s) and (opq or os.path.basename(s[0]) in SHELLS | OPAQUE | {"eval", "source", "."})


def heredoc(m) -> str:
    """O corpo de um heredoc é texto (cita comandos, tem apóstrofo) e some; só o $( ) de um delimitador SEM aspas roda, e fica. Exceção: se quem lê é um shell
    (`bash <<EOF`, `ssh h <<EOF`, `cat <<EOF | sh`) o corpo É o script, e fica como comandos. Quem lê = os comandos da linha onde o heredoc abre."""
    line = m.string[m.string.rfind("\n", 0, m.start()) + 1:m.start()] + m.group(1)
    if any(runs_text(s.split()) for s in re.split(r"[;&|(]+", line)):
        return m.group(1) + "\n" + m.group(4)
    return m.group(1) + ("" if m.group(2) else "\n: " + " ".join(x.group(0) for x in SUBST.finditer(hide(m.group(4)))))


def words(cmd: str) -> list:
    cmd = FD.sub(r"\1", hide(CONT.sub(r"\1", HEREDOC.sub(heredoc, cmd))).replace("\n", " ; "))  # newline separa comandos; `\` + newline os junta
    try:
        lx = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lx.whitespace_split, lx.commenters = True, ""
        return list(lx)
    except ValueError:  # aspas que não fecham: o sh é quem vai dizer; aqui só não há como conferir por tokens, então separa na marra
        return re.findall(r"[^\s;&|()]+|[;&|()]+", cmd.replace("'", "").replace('"', ""))


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
    return res(args[0] if args else "~", cwd)


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
    for t in [cwd] + [res(x, cwd) for x in (gd, wt) if x]:
        if t is None or (inside(t, terr) and not (own and inside(t, own))):
            return t, "git " + sub + (" (leitura com configuração que roda programa: -c, GIT_PAGER…)" if read else "")
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
        env, seg, b, opq = peel(seg)
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
            st["cwd"] = chdir(seg[1:], st["cwd"], c == "pushd")
        elif c == "popd":
            st["cwd"] = None
        elif c in OPAQUE or opq:  # não modelo o que o lançador faz com diretório e ambiente: o git de dentro (palavra solta ou texto entre aspas) vale com diretório "não sei"
            for j, t in enumerate(seg[1:], 1):
                if os.path.basename(t) == "git":  # as palavras seguintes são argumentos do git (mensagem de commit…), não outro comando
                    return git_hit(seg[j:], {**st["env"], **env}, None, terr, own)
                if re.search(r"\s", t):
                    r = scan(t, None, terr, own, depth + 1)
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
                    return scan(script[0], cwd, terr, own, depth + 1)
        elif c == "eval":
            return scan(" ".join(seg[1:]), cwd, terr, own, depth + 1)
        elif c == "find" or c[:1] == "-":  # o `\;` do find fecha o trecho: um segundo `-exec …` chega aqui como PRIMEIRA palavra do trecho seguinte (ou depois de `-o`/`\)`)
            for j, t in enumerate(seg):
                if t in ("-exec", "-execdir", "-ok", "-okdir"):  # -exec/-ok rodam no diretório do find; -execdir/-okdir no de CADA achado, que não sei qual é: cego
                    r = one(seg[j + 1:], blind or t.endswith("dir"))
                    if r:
                        return r
        elif c == "git":
            return git_hit(seg, {**st["env"], **env}, cwd, terr, own)
        return None

    skip, herestr = False, False
    for tok in words(cmd) + [";"]:
        if skip:  # alvo de redirecionamento
            skip = False
            if herestr and runs_text(seg):  # `bash <<< 'git -C x commit'`: a palavra é o script que o shell vai ler
                r = scan(tok, st["cwd"], terr, own, depth + 1)
                if r:
                    return r
            herestr = False
        elif set(tok) <= PUNCT:  # o shlex junta pontuação colada (`);`, `&&(`, `2>&1`): separa de novo
            for pc in PIECE.findall(tok):
                if pc in SEPS or pc in ("(", ")"):
                    r = one(seg)
                    if r:
                        return r
                    seg = []
                    if pc == "(":
                        stack.append(st["cwd"])
                        skip = False  # `<(cmd)` / `>(cmd)`: o `<` que vem colado no `(` não é redirecionamento de arquivo, a palavra seguinte é um comando
                    elif pc == ")" and stack:
                        st["cwd"] = stack.pop()
                else:
                    skip, herestr = True, pc == "<<<"  # redirecionamento: a palavra seguinte é o arquivo (ou, no here-string, o texto)
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
