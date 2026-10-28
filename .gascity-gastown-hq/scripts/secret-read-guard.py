#!/usr/bin/env python3
r"""secret-read-guard.py — hook PreToolUse que recusa LER ou ESCREVER segredo pelas ferramentas de arquivo e pelo Bash (ga-nkfwixz).
Nasceu da comparação com o cc-safety-net 2.7.0 (docs/runbooks/guard-oracle-diff.md): nenhum guard nosso olhava caminho de segredo. DORMENTE: nenhum
settings.json chama este arquivo; ligar é decisão do Mayor (o trecho do hook e a medição estão no runbook).

Contents
  Para que serve · Como decide · Códigos · Limites
PARA QUE SERVE
  Um agente (ou um texto injetado que ele leu) não lê `~/.ssh`, `~/.aws`, `~/.claude/.credentials.json`, `.env`, chave privada, `.netrc`… com Read, Grep, Glob, Edit,
  Write, MultiEdit, NotebookEdit nem com `cat` & cia. Segredo entra no comando pelo `secret <item>` (Bitwarden), nunca lendo o arquivo. Hook que sai 2 bloqueia em qualquer modo, `--dangerously-skip-permissions` incluso (medido no remote-clone-guard).
COMO DECIDE
  Ferramenta de arquivo: o caminho do pedido (file_path, notebook_path, path, o diretório fixo do pattern de Glob; Grep/Glob sem path = o cwd) é resolvido (`~`, `$HOME`, cwd, link
  simbólico) e comparado com o catálogo; Grep/Glob também recusam um glob que NOMEIA a família (`.env*`, `*.pem`). Bash: o texto é lido como o bash lê (aspas, comentário, heredoc,
  `bash -c`/`eval`/`$( )`, `cd`, embrulho `timeout`/`nohup`/`env`/`sudo`), cada palavra vira candidato a caminho (chave `{a,b}` primeiro, depois `~`, `$HOME`, atribuição anterior,
  `${X:-padrão}`, glob que EXISTE) e o código inline de python/node/perl/ruby/php/awk é varrido por literais de caminho. $( ) e crase rodam em QUALQUER palavra (atribuição, redirecionamento,
  here-string, heredoc sem aspas). Caminho com pedaço que não sei resolver: valem a pasta literal antes dele, o nome do fim e o caminho com o pedaço tirado (ele pode ser vazio). Verbo que só olha metadado (echo, ls, stat, test, cd, `git status|ls-files|check-ignore`, o padrão do
  grep, o valor de `find -name`) não conta como leitura, salvo quando a saída vira operando de outro comando (`xargs`, `read`, `$( )`); redirecionamento conta sempre.
CÓDIGOS: 0 liberado · 2 bloqueado. Falha do próprio guarda num pedido que ele cobre = bloqueado (nunca "liberado"); aninhamento acima de 6 níveis e glob que não termina de ser conferido em 4 s também ("não consigo ler" = bloqueado).
LIMITES (trava contra engano, não sandbox; o fecho de verdade é permissão de arquivo por usuário Unix): não vejo caminho montado em pedaços (`chr()`, concatenação,
  `base64 -d`), variável que não é HOME nem atribuída na mesma chamada (raiz desconhecida + pasta de segredo + nome comum, `$X/.gnupg/pubring.kbx`, passa), variável de laço, `~usuario`,
  script que o comando executa (`bash x.sh`), segredo no ambiente, nem o que um programa lê sozinho (`ssh` usa a chave). Lista completa: docs/runbooks/guard-oracle-diff.md, "Limites".
"""
from __future__ import annotations

import functools
import glob
import json
import os
import re
import sys
import time

FILE_TOOLS = {"Read": "file_path", "Edit": "file_path", "Write": "file_path", "MultiEdit": "file_path", "NotebookEdit": "notebook_path", "NotebookRead": "notebook_path"}
WRITE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
COVERED = {"Bash", "Grep", "Glob", *FILE_TOOLS}
BUDGET_S = 4.0  # segundos que um pedido tem para conferir os casos de glob (nó: ~20 mil caminhos/s; mini: bem menos): sem tempo BLOQUEIA (secret.glob-too-wide), nunca olha uma parte e libera o resto
LATE = [0.0]  # o prazo do pedido em curso, em time.monotonic() (decide() recarrega)
real_home = functools.lru_cache(maxsize=None)(os.path.realpath)  # um glob larga milhares de caminhos e cada um confere o HOME real: só o 1º resolve

# --- catálogo (portado do cc-safety-net 2.7.0, src/core/rules/secret.ts, cortado ao que existe nas nossas máquinas) ---
HOME_DIRS = {".ssh": "secret.home.ssh", ".aws": "secret.home.aws", ".gcp": "secret.home.gcp", ".gnupg": "secret.home.gnupg"}
HOME_SUB = (  # (partes sob o HOME, regra, é arquivo?) — arquivo aceita também `<nome>.bak|.old…`; pasta vale com qualquer filho
    ((".config", "gcloud"), "secret.home.gcloud-config", False), ((".config", "rclone"), "secret.home.rclone", False), ((".dolt", "creds"), "secret.home.dolt-creds", False),
    (("gt-remote", "keys"), "secret.home.gt-remote-keys", False), ((".config", "gh", "hosts.yml"), "secret.home.gh-hosts", True),
    ((".kube", "config"), "secret.home.kube-config", True), ((".docker", "config.json"), "secret.home.docker-config", True), ((".claude", ".credentials.json"), "secret.cli.claude-code", True))
SSH_OK = {"config", "known_hosts", "known_hosts.old"}  # sob ~/.ssh só LER (e `*.pub`); escrever em qualquer um (authorized_keys, config) continua bloqueado
BASENAMES = {n: "secret.basename." + n.strip(".").replace("_", "-").replace(".", "-") for n in
             (".env", ".npmrc", ".pypirc", ".netrc", ".git-credentials", ".pgpass", ".my.cnf", "id_rsa", "id_dsa", "id_ed25519", "id_ecdsa", "credentials")}
KEYS = ("id_rsa", "id_dsa", "id_ed25519", "id_ecdsa")
DOT_VARIANTS = {".bak", ".backup", ".copy", ".disabled", ".key", ".old", ".orig", ".pem", ".save", ".tmp"}
SECRET_EXT = {"pem", "p12", "pfx", "pkcs12", "jks", "keystore", "keyring", "kdb", "kdbx", "key", "keypair", "ovpn"}
ENV_TEMPLATE = (".example", ".sample", ".template", ".tpl")  # `.env.local.example`; `.env.defaults` e `.env.example.x` também passam
BROAD_SKIP = ("node_modules", "__pycache__", "site-packages", "dist-packages")  # certificado de pacote não é segredo nosso: só as regras largas (extensão, *_rsa) pulam
BROAD_KEY = re.compile(r"[^.]*_(?:rsa|dsa|ed25519|ecdsa)")

SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "ash"}
INTERP = re.compile(r"(?:python[\d.]*|node(?:js)?|perl|ruby|php|lua|deno|bun|awk|gawk|mawk|osascript)")
EXEMPT = {"echo", "printf", "ls", "ll", "la", "stat", "test", "[", "[[", "true", "false", ":", "cd", "pushd", "popd"}
GIT_EXEMPT = {"check-ignore", "ls-files", "status"}
GREPS = {"grep", "egrep", "fgrep", "rg", "ag", "ack"}
READERS = GREPS | {"cat", "head", "tail", "less", "more", "strings", "xxd", "od", "base64", "wc", "file", "diff", "cmp", "sort", "uniq", "cut", "nl", "tac", "rev", "sed", "awk", "gawk", "mawk", "find", "ls", "stat"}
GREP_VAL = {"-e", "--regexp", "-A", "-B", "-C", "-m", "-g", "--glob", "-t", "--type", "--max-count", "--include", "--exclude", "--exclude-dir"}
FIND_VAL = {"-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-regex", "-iregex", "-lname", "-ilname"}
FEEDERS = {"xargs", "parallel", "read", "mapfile", "readarray"}  # a saída de um echo/ls vira operando deles: nesses casos nenhum verbo é isento
ASSIGN = re.compile(r"[A-Za-z_]\w*=")
WRAP_VAL = {"sudo": {"-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U"}, "doas": {"-u", "-C"}, "timeout": {"-k", "-s"}, "nice": {"-n"}, "ionice": {"-c", "-n", "-p"}, "env": {"-u", "-C", "-S"}, "nohup": set(),
            "command": set(), "time": set(), "exec": set(), "builtin": set(), "stdbuf": set(), "setsid": set(), "unbuffer": set(), "caffeinate": set()}  # embrulho -> opções que levam valor
ANSI = re.compile(r"\\(x[0-9a-fA-F]{1,2}|[0-7]{1,3}|u[0-9a-fA-F]{1,4}|U[0-9a-fA-F]{1,8}|c.|.)", re.S)


def ansi(body: str) -> str:
    """Conteúdo de $'…' como o bash o decodifica (`$'\\x2eenv'` é `.env`)."""
    def one(m):
        e = m.group(1)
        if e[0] in "xuU":
            return chr(min(int(e[1:], 16), 0x10FFFF))
        if e[0].isdigit():
            return chr(int(e, 8) & 0xFF)
        return chr(ord(e[1]) & 0x1F) if e[0] == "c" and len(e) > 1 else {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v"}.get(e, e)
    return ANSI.sub(one, body)
RUN = re.compile(r"[~$/\w.{}@+%-]+")  # um "pedaço de caminho" dentro de código inline


def home() -> str:
    # vazio → HOME ausente ou vazio cai no expanduser; falhou → expanduser devolve o texto como veio e o catálogo ainda âncora em /home/* e /Users/*
    return os.path.normpath(os.environ.get("HOME") or os.path.expanduser("~"))


def rels(parts: list) -> list:
    """Possíveis 'partes sob o HOME' (minúsculas) de um caminho absoluto em partes: o HOME daqui, /root, /home/<u>, /Users/<u>."""
    low, out = [p.casefold() for p in parts], []
    for h in {home(), real_home(home()), "/root"}:
        hp = [p.casefold() for p in h.split("/") if p]
        if hp and low[:len(hp)] == hp:
            out.append(low[len(hp):])
    return out + ([low[2:]] if len(low) >= 2 and low[0] in ("home", "users") else [])


def match(path: str, write: bool, homerules: bool = True):
    """Regra de segredo de um caminho absoluto, ou None. homerules=False pula as regras ancoradas no HOME (ficam só as por NOME)."""
    parts = [p for p in path.split("/") if p]
    if not parts:
        return None
    base, low = parts[-1].casefold(), [p.casefold() for p in parts]
    for rel in (rels(parts) if homerules else []):
        if rel and rel[0] in HOME_DIRS:
            if rel[0] == ".ssh" and not write and len(rel) == 2 and (rel[1] in SSH_OK or rel[1].endswith(".pub")):
                continue
            return HOME_DIRS[rel[0]]
        for sub, rule, is_file in HOME_SUB:
            n = len(sub)
            if rel[:n - 1] == list(sub[:-1]) and len(rel) >= n and (rel[n - 1] == sub[-1] or (is_file and rel[n - 1].startswith(sub[-1] + "."))):
                return rule
    if re.search(r"\s", base) or base == ".env.defaults" or (base.startswith(".env.") and base.endswith(ENV_TEMPLATE)) or base.startswith((".env.example.", ".env.sample.")):
        return None  # as regras abaixo são por NOME de arquivo: texto com espaço (mensagem de commit, argumento de código) não é nome; modelo de .env passa
    if base.endswith(".pub") and base[:-4] in KEYS:
        return None
    if base in BASENAMES:
        return BASENAMES[base]
    if base.startswith(".env."):
        return "secret.pattern.env-variant"
    for p in KEYS + ("credentials",):
        if base.startswith(p) and len(base) > len(p):
            if base[len(p)] in "-_" and p != "credentials":
                return "secret.variant." + p.replace("_", "-") + ".separator"
            if base[len(p):] in DOT_VARIANTS:
                return "secret.variant." + p.replace("_", "-") + "." + base[len(p) + 1:]
    if any(s in low[:-1] for s in BROAD_SKIP) or ("vendor" in low and ("bundle" in low or "cache" in low)):
        return None
    if "." not in base and BROAD_KEY.fullmatch(base):
        return "secret.pattern.ssh-key-basename"
    ext = base.rsplit(".", 1)[-1] if "." in base else ""
    return "secret.ext." + ext if ext in SECRET_EXT else None


NAME = r"[A-Za-z_][A-Za-z0-9_]*"
VAR = re.compile(r"\$\{(" + NAME + r")(?:(:?)[-=]([^{}]*))?\}|\$(" + NAME + r")")  # $NOME · ${NOME} · ${NOME:-padrão} (grupos: nome, ":", padrão, nome)
UNKNOWN = re.compile(r"[$`]")  # sobrou `$` ou crase num caminho: há um pedaço que não sei resolver
PIECE = re.compile(r"\$\{[^{}]*\}|\$\([^()]*\)|`[^`]*`|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@#?*!$-]")  # um pedaço desconhecido inteiro: ${…}, $(…), `…`, $NOME, $1


def tilde(s: str) -> str:
    return home() + s[1:] if s == "~" or s.startswith("~/") else s


def subst(s: str, env: dict) -> str:
    """O texto como o shell o entrega depois de `$NOME`, `${NOME}`, `${NOME:-padrão}` e `~`. UMA passada (o shell não reexpande o valor) e pelo NOME INTEIRO (`H=1` não come o
    `$HOME`); valor vazio vale (`X=` troca por nada); não corta pelo cwd (uma variável relativa é resolvida onde é USADA, não onde foi atribuída). HOME é conhecido; outro nome que
    não foi atribuído nesta chamada fica como está, com o `$`: quem chama sabe que ali há um pedaço desconhecido."""
    def one_var(m):
        name, colon, dflt = m.group(1) or m.group(4), m.group(2), m.group(3)
        # vazio → nome atribuído a "" vale "" (não é "desconhecido"); falhou/ilegível → nome que não conheço: sem padrão o `$` fica, com padrão vale o padrão (pode ser o que o shell abre)
        known = env[name] if name in env else (home() if name == "HOME" else None)
        if dflt is None:
            return m.group(0) if known is None else known
        return tilde(VAR.sub(one_var, dflt)) if known is None or (colon and not known) else known
    return tilde(VAR.sub(one_var, s.strip().strip("`")))


def expand(s: str, cwd, env: dict) -> str:
    s = subst(s, env)
    return s if os.path.isabs(s) else os.path.join(cwd or os.getcwd(), s)


def partial(cand: str, write: bool):
    """Regra de segredo de um caminho com pedaço desconhecido (`$VAR` de fora, `$( )`, crase), ou None. O que eu sei ainda vale: (A) a pasta literal ANTES do 1º pedaço
    desconhecido com um filho qualquer (`~/.ssh/$f` abre algo em ~/.ssh) e (B) o NOME do fim, se ele é literal (`$(echo ~)/.ssh/id_rsa`). O caso "o pedaço é vazio" (C) é do classify()."""
    comps = cand.split("/")
    # vazio → sem componente desconhecido não chega aqui (o chamador só entra com `$` ou crase); falhou/ilegível → None, que é "não consegui saber" e o chamador segue o limite documentado
    first = next((i for i, c in enumerate(comps) if UNKNOWN.search(c)), None)
    if first is None:
        return None
    hit = match("/".join(comps[:first]) + "/<desconhecido>" + (".pub" if comps[first].endswith(".pub") else ""), write) if first else None  # `$k.pub` segue chave pública
    if hit is None and not UNKNOWN.search(comps[-1]):
        hit = match("/" + "/".join(c for c in comps if c and not UNKNOWN.search(c)), write, False)
    return hit


def braces(s: str, depth: int = 3) -> list:
    """Expansão de chave. Passou do teto (16 alternativas, 3 níveis, 64 resultados) levanta OverflowError: quem chama BLOQUEIA, nunca corta em silêncio."""
    m = re.search(r"(?<!\$)\{([^{}]*,[^{}]*)\}", s)  # `${X:-a,b}` é expansão de parâmetro, não chave
    if not m:
        return [s]
    alts = m.group(1).split(",")
    out = [r for alt in alts for r in braces(s[:m.start()] + alt + s[m.end():], depth - 1)] if depth and len(alts) <= 16 else None
    if out is None or len(out) > 64:
        raise OverflowError(s)
    return out


def cases(cand: str):
    """Os caminhos que o glob de `cand` devolve, um a um. Passou do prazo do pedido (LATE) no meio deles: OverflowError, porque olhar uma parte e liberar o resto é o mesmo 0 de "não é segredo"."""
    n = 0
    for n, p in enumerate(glob.iglob(cand), 1):  # vazio → o literal vale; falhou/ilegível (permissão, loop de link) → glob devolve [] e o literal vale
        if time.monotonic() > LATE[0]:
            raise OverflowError(cand)
        yield p
    if not n:
        yield cand


def classify(raw: str, cwd, write: bool = False, env=None):
    """(regra, caminho) se `raw` é caminho de segredo; None se não é, ou se não sei resolver o caminho TODO (variável que não conheço: limite documentado, não bloqueio; mas a pasta
    literal antes do pedaço desconhecido e o nome do fim ainda valem, ver partial())."""
    raw = (raw or "").strip()
    if not raw or raw.startswith("-") or re.match(r"[A-Za-z][\w+.-]*://", raw):
        return None
    try:
        cands = [expand(b, cwd, env or {}) for b in braces(raw)]  # o bash faz a chave PRIMEIRO e depois o `~` e o `$` de cada palavra: `{~/.gnupg/x,y}` abre ~/.gnupg/x
    except OverflowError:
        return "secret.brace-expansion", raw
    for cand in cands:
        if UNKNOWN.search(cand):
            hit = partial(cand, write)
            if hit:
                return hit, cand
            # (C) o pedaço desconhecido pode ser VAZIO (variável não atribuída, `$( )` sem saída): sem ele o caminho segue o fluxo normal, glob incluso (`.cr*$X` é `.credentials.json`)
            bare = os.path.normpath(PIECE.sub("", cand))
            if bare == cand or UNKNOWN.search(bare):  # nada a tirar, ou sobrou pedaço que não sei tirar: não consigo saber, o limite documentado
                continue
            cand = bare
        try:
            for p in cases(cand) if re.search(r"[*?\[]", cand) else [cand]:
                for form in dict.fromkeys((os.path.normpath(p), os.path.realpath(p))):  # a mesma forma duas vezes é um custo só
                    r = match(form, write)
                    if r and r.startswith(("secret.home.", "secret.cli.")) and "/" not in raw and not write and not os.path.lexists(form):
                        r = match(form, write, False)  # palavra solta que só cai na pasta do segredo por causa de um `cd` e não existe lá (`cd ~/.ssh; head -n 2 config`): vale só o NOME
                    if r:
                        return r, form
        except OverflowError:  # sem tempo no meio dos casos do glob
            return "secret.glob-too-wide", cand
    return None


CRED_PARENTS = {sub[:k] for sub, _, _ in HOME_SUB for k in range(1, len(sub))}  # ancestrais de segredo do catálogo que não são segredo em si: ~/.claude (guarda .credentials.json), ~/.config, ~/.dolt, ~/gt-remote…


def broad(raw: str, cwd, env=None, deep: bool = True):
    """('secret.scan.home', caminho) se `raw` é o HOME, um ancestral dele ou `~/gt-remote` (ancestral de ~/gt-remote/keys): varrer isso recursivamente lê segredo. deep=True (quem LÊ
    conteúdo: grep -r, find, tar, cp -r, Grep) vale também para os outros ancestrais de segredo do catálogo (`~/.claude`, `~/.config`…); deep=False (Glob só lista nomes) fica no HOME e acima."""
    p = os.path.normpath(expand(raw or "", cwd, env or {})) if raw else ""
    if p and (p in ("/", "/home", "/Users", "/root", home(), home() + "/gt-remote") or home().startswith(p.rstrip("/") + "/")):
        return "secret.scan.home", p
    if p and deep and any(tuple(r) in CRED_PARENTS for r in rels([x for x in p.split("/") if x])):
        return "secret.scan.cred-parent", p
    return None


def names_family(comp: str):
    """Um glob de Grep/Glob que NOMEIA a família (`.env*`, `*.pem`, `id_rsa*`, `credentials*`), sem caminho; nome literal vale como arquivo."""
    c = comp.casefold()
    if comp and not re.search(r"[*?\[{]", comp):
        return match("/x/" + comp, False)
    lit = re.split(r"[*?\[{]", c)[0]
    if any(lit.startswith(b) for b in (".env", ".npmrc", ".netrc", ".pypirc", ".git-credentials", "credentials") + KEYS) and not lit.startswith((".env.example", ".env.sample", ".envrc")):
        return "secret.glob." + lit.strip(".")
    return "secret.glob.ext" if re.fullmatch(r"[*?\w{},-]*\.(?:" + "|".join(sorted(SECRET_EXT)) + ")", c) else None


# --- Bash ---
class Op(str):
    """Operador do shell (`;` `&&` `|` `(` `>` `2>>` `<<<`…). Uma palavra entre aspas igual a `;` NÃO é operador: por isso o tipo."""


SEP_OPS = {";", "&&", "||", "|", "|&", "&", ";;", "(", ")"}
REDIR = re.compile(r"\d*(?:&?>>?|<|>&|<&|>\||<>)")


def skip_subst(t: str, i: int) -> int:
    """t[i:] começa em `$(`, `${` ou crase: o índice depois do fecho (sem fecho = fim do texto). Aspas dentro pulam até a de fecho; parênteses aninhados contam."""
    n, j, depth = len(t), i + 1, 0
    if t[i] == "`":
        while j < n and t[j] != "`":
            j += 2 if t[j] == "\\" else 1  # a crase aninhada é \` dentro da de fora
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
            for delim, tabs, recv, quoted in pend:
                body = []
                while i < n:
                    j = text.find("\n", i)
                    line, i = (text[i:], n) if j < 0 else (text[i:j], j + 1)
                    if (line.lstrip("\t") if tabs else line) == delim:
                        break
                    body.append(line)
                docs.append(("\n".join(body), recv, quoted))
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
        elif c in ";&|()<>":
            pre = ""
            if c in "<>" and word and "".join(cur).isdigit():  # `2>`: o descritor faz parte do operador
                pre, cur, word = "".join(cur), [], False
            else:
                flush()
            op = re.match(r"<<<|<<-?|&&|\|\||\|&|;;|&>>|&>|>>|>&|<&|>\||<>|[;&|()<>]", text[i:]).group(0)
            i += len(op)
            m = re.match(r"[ \t]*(?:'([^']*)'|\"([^\"]*)\"|(\\?)([\w.-]+))", text[i:]) if op in ("<<", "<<-") else None
            if m:  # o delimitador não é palavra; quem lê o heredoc está antes ou depois dele, na mesma linha
                k = len(toks)
                while k and not (isinstance(toks[k - 1], Op) and toks[k - 1] in SEP_OPS):
                    k -= 1
                eol = text.find("\n", i)
                words = [str(t) for t in toks[k:] if not isinstance(t, Op)] + re.split(r"[\s;&|()<>]+", text[i + m.end(): n if eol < 0 else eol])
                quoted = m.group(1) is not None or m.group(2) is not None or bool(m.group(3))  # <<'E' <<"E" <<\E: o corpo é texto; sem aspas o bash EXPANDE $( ) e crase dele
                pend.append((m.group(1) or m.group(2) or m.group(4) or "", op == "<<-", [os.path.basename(w) for w in words if w], quoted))
                i += m.end()
            else:
                toks.append(Op(pre + op))
        else:
            cur.append(c); word = True; i += 1
    flush()
    return toks, docs + [("", r, True) for _, _, r, _ in pend]  # `cat <<EOF` sem newline depois: não há corpo


def substitutions(w: str):
    """Corpos de $( ) e crase dentro de UMA palavra."""
    i, out = 0, []
    while i < len(w):
        if (w[i] == "$" and w[i + 1:i + 2] == "(") or w[i] == "`":
            j = skip_subst(w, i)
            out.append(w[i + 2:j - 1] if w[i] == "$" else w[i + 1:j - (w[j - 1:j] == "`")]); i = j
        else:
            i += 1
    return out


def literals(code: str, cwd, env):
    return next((h for h in (classify(run.strip("{}"), cwd, False, env) for run in RUN.findall(code)) if h), None)


def real_verb(ws: list) -> int:
    """Índice do verbo de verdade atrás de embrulhos (`timeout 5 find …`, `nohup grep -r …`, `env A=1 tar …`, `sudo -u x cp -r …`, `command export D=…`); 0 se não há embrulho ou só há embrulho."""
    k = 0
    while k < len(ws) and os.path.basename(ws[k]) in WRAP_VAL:
        w, k = os.path.basename(ws[k]), k + 1
        while k < len(ws) and (ws[k].startswith("-") or ASSIGN.match(ws[k]) or re.fullmatch(r"\d+(?:\.\d+)?[smhd]?", ws[k])):
            k += 1 + (ws[k] in WRAP_VAL[w])
    return k if k < len(ws) else 0


def cd_target(words: list, cwd, env: dict):
    """O diretório depois de um `cd`/`pushd` (assumo que rodou); None se a linha não é cd ou não sei o destino."""
    ws = [w for w in words if not ASSIGN.match(w)]
    while ws and ws[0] in ("time", "command", "builtin", "!"):  # seguem sendo o cd do próprio shell (`timeout`, `env`, `nohup` rodariam um programa externo)
        ws = ws[1:]
    if not ws or os.path.basename(ws[0]) not in ("cd", "pushd"):
        return None
    args = [a for a in ws[1:] if a not in ("-L", "-P", "-e", "-@", "--")]
    d = expand(args[0], cwd, env) if args else home()
    return None if "$" in d or args[:1] == ["-"] else os.path.normpath(d)


def scan_bash(cmd: str, cwd, depth: int = 0, env=None, strict: bool = False):
    env = dict(env or {})
    if depth > 6:  # vazio → n/a; falhou/ilegível (aninhamento mais fundo do que eu varro) → BLOQUEIA: o que eu não leio pode ser o segredo (igual ao teto da chave {a,b})
        return "secret.nesting-too-deep", cmd[:80]
    toks, docs = lex(cmd)
    for body, recv, quoted in docs:  # corpo lido como DADO (cat, git commit -F -, tee…): o texto citar `.env` não é ler `.env`; lido por shell ou interpretador, é código
        hit = scan_bash(body, cwd, depth + 1, env) if any(w in SHELLS for w in recv) else None
        hit = hit or (literals(body, cwd, env) if any(INTERP.fullmatch(w) for w in recv) else None)
        for sub in () if quoted or hit else substitutions(body):  # delimitador SEM aspas: o $( ) e a crase do corpo RODAM, e a saída vira o texto que o leitor recebe
            hit = hit or scan_bash(sub, cwd, depth + 1, env, True)
        if hit:
            return hit
    strict = strict or any(not isinstance(t, Op) and os.path.basename(t) in FEEDERS for t in toks)
    cur, here, saved, feed = [], cwd, [], []  # feed = palavras dos comandos anteriores da MESMA pipeline
    for t in toks + [Op(";")]:
        if isinstance(t, Op) and t in SEP_OPS:
            hit = one(cur, here, depth, env, strict, feed)
            if hit:
                return hit
            feed = feed + cur if t in ("|", "|&") else []
            here = cd_target(cur, here, env) or here
            if t == "(":
                saved.append(here)
            elif t == ")" and saved:
                here = saved.pop()
            cur = []
        else:
            cur.append(t)
    return None


def one(ws: list, cwd, depth: int, env: dict, strict: bool = False, feed=()):
    words, redirs, herestr, k = [], [], [], 0
    while k < len(ws):  # redirecionamento conta sempre, seja qual for o verbo: o operador e a palavra seguinte (o alvo)
        t = ws[k]
        if isinstance(t, Op) and k + 1 < len(ws) and (REDIR.fullmatch(t) or t == "<<<"):
            (herestr if t == "<<<" else redirs).append((str(ws[k + 1]), ">" in t)); k += 2
        else:
            k += 1
            if not isinstance(t, Op):
                words.append(t)
    for tgt, wr in redirs:
        hit = classify(tgt, cwd, wr, env)
        if hit:
            return hit
    i = 0
    while i < len(words) and ASSIGN.match(words[i]):  # NAME=valor: o valor é candidato e vira variável para as palavras seguintes
        name, val = words[i].split("=", 1)
        hit = classify(val, cwd, False, env)
        if hit:
            return hit
        env[name] = subst(val, env)  # o valor como o shell o guarda: SEM juntar ao cwd (`D=.gnupg; cd ~; cat $D/x` abre ~/.gnupg/x)
        i += 1
    # $( ) e crase em QUALQUER palavra da linha rodam MESMO que o verbo seja isento ou que não haja verbo (`echo "$(cat ~/.ssh/id_rsa)"`, `X=$(cat ~/.ssh/id_rsa)`, `cat < $(…)`,
    # `cat <<< $(…)`), e a saída é operando de outro comando
    for w in words + [t for t, _ in redirs] + [t for t, _ in herestr]:
        for body in substitutions(w):
            hit = scan_bash(body, cwd, depth + 1, env, True)
            if hit:
                return hit
    ws = words[i:]
    if not ws:
        return None
    # o verbo é o de verdade, não o embrulho (`timeout 5 grep -r x ~/.claude` varre; `nohup find … | xargs cat` lista e lê); args segue com TODAS as palavras depois do 1º (candidatos a caminho)
    ev = real_verb(ws)
    verb, args, eargs, skip = os.path.basename(ws[ev]), ws[1:], ws[ev + 1:], set()  # skip = índices (em args) de palavras que são CÓDIGO ou padrão, não caminho
    if verb in ("export", "declare", "typeset", "local", "readonly"):  # `export D=.gnupg` também vira variável para as palavras seguintes
        for a in args:
            if ASSIGN.match(a):
                env[a.split("=", 1)[0]] = subst(a.split("=", 1)[1], env)
    nest = next((k for k, w in enumerate(ws) if os.path.basename(w) in SHELLS | {"eval"} or INTERP.fullmatch(os.path.basename(w))), None)
    if nest is not None:  # o 1º shell/interpretador da linha, mesmo atrás de embrulho (`timeout 5 bash -c …`, `nohup sh -c …`, `env A=1 python3 -c …`)
        nv, nargs, code = os.path.basename(ws[nest]), ws[nest + 1:], None
        if nv == "eval":  # eval junta os argumentos num texto só
            code, skip = " ".join(nargs), set(range(nest, len(args)))
        else:
            for k, a in enumerate(nargs):
                if re.fullmatch(r"-[a-zA-Z]*[ceEpr]|--(?:eval|print|command)", a):
                    code, skip = (nargs[k + 1] if k + 1 < len(nargs) else None), {nest + k + 1}
                    break
            k = next((k for k, a in enumerate(nargs) if not a.startswith("-")), None) if code is None and nv.endswith("awk") else None
            code, skip = (nargs[k], {nest + k}) if k is not None else (code or (herestr[0][0] if herestr else None), skip)
        if not code and nv != "eval" and ("-" in nargs or "-s" in nargs or not [a for a in nargs if not a.startswith("-")]):  # lê o programa do stdin: o que vem pelo pipe é código
            for w in feed:
                hit = scan_bash(str(w), cwd, depth + 1, env) if nv in SHELLS else literals(str(w), cwd, env)
                if hit:
                    return hit
        if code:
            hit = scan_bash(code, cwd, depth + 1, env) if nv in SHELLS | {"eval"} else literals(code, cwd, env)
            if hit:
                return hit
    if not strict and (verb in EXEMPT or (verb == "git" and next((a for a in eargs if not a.startswith("-")), "") in GIT_EXEMPT)):
        return None
    if verb in GREPS:  # o 1º operando é o padrão (a menos que haja -e/--regexp): citar `.env` num padrão não é ler `.env`
        pat_done = any(a in ("-e", "--regexp") or a.startswith("--regexp=") for a in eargs)
        for j, a in enumerate(eargs):  # j conta a partir do verbo de verdade; o índice em args é ev + j
            if a in GREP_VAL:
                skip.add(ev + j + 1)
            elif a.startswith("--regexp="):
                skip.add(ev + j)
            elif not a.startswith("-") and not pat_done and (ev + j - 1) not in skip and (j == 0 or eargs[j - 1] not in ("-f", "--file")):
                skip.add(ev + j); pat_done = True
    reads = verb in READERS and not (verb == "sed" and any(re.match(r"-[a-zA-Z]*i|--in-place", a) for a in eargs))  # quem não é leitor conhecido pode ESCREVER: sem a exceção de leitura de ~/.ssh
    names = verb == "find" and not strict and not any(a in ("-exec", "-execdir", "-ok", "-okdir") for a in eargs)  # `find -name .env` só lista; com -exec lê o que achou, e em modo estrito (a saída vira operando de xargs/read/$( )) o nome buscado é o que será lido
    scans = verb in GREPS or verb in ("tar", "zip", "rsync", "cp", "scp") or (verb == "find" and not names)
    for k, a in enumerate(args):
        if k in skip or (names and k and args[k - 1] in FIND_VAL):
            continue
        cand = (a.split("=", 1)[1] if re.match(r"-{0,2}[A-Za-z_][\w-]*=", a) else a).lstrip("@")
        cand = m.group(1) if (m := re.fullmatch(r"-[A-Za-z](.+)", cand)) else cand  # `ssh -i~/.ssh/id_rsa`: valor colado na opção
        hit = classify(cand, cwd, not reads, env) or (broad(cand, cwd, env) if scans else None)
        if not hit and re.fullmatch(r"[^\s:/][^\s:]*:[^\s]+", cand):  # `scp host:~/.ssh/id_rsa`: o que vem depois do `:` também é caminho (e `doc: id_rsa` não é)
            hit = classify(cand.split(":", 1)[1], cwd, not reads, env)
        if not hit and (m := re.fullmatch(r":(?:[0-3]:)?([^\s:][^\s]*)", cand)):  # `git show :.env` / `:0:.env`: o índice do git, o caminho vem depois do `:` (sem rev antes dele)
            hit = classify(m.group(1), cwd, not reads, env)
        if hit:
            return hit
    return None


# --- decisão ---
def decide(inp: dict):
    """None = liberado; (regra, alvo, operação) = bloqueado."""
    LATE[0] = time.monotonic() + BUDGET_S
    tool, ti, cwd = inp.get("tool_name"), inp.get("tool_input") or {}, inp.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or None
    if tool == "Bash":
        hit = scan_bash(str(ti.get("command") or ""), cwd)
        return (hit[0], hit[1], "comando Bash") if hit else None
    if tool in FILE_TOOLS:  # vazio → sem caminho no pedido = nada a conferir (a própria ferramenta recusa)
        hit = classify(str(ti.get(FILE_TOOLS[tool]) or ""), cwd, tool in WRITE_TOOLS)
        return (hit[0], hit[1], ("escrita" if tool in WRITE_TOOLS else "leitura") + " (" + tool + ")") if hit else None
    if tool in ("Grep", "Glob"):
        # vazio → `path` omitido é o cwd da ferramenta (Grep e Glob varrem o cwd): vale como se estivesse escrito; falhou/ilegível → pedido sem cwd usa o cwd do próprio hook (o da sessão)
        where = str(ti.get("path") or "") or cwd or os.getcwd()
        hit, pat = classify(where, cwd) or broad(where, cwd, deep=tool == "Grep"), str(ti.get("glob" if tool == "Grep" else "pattern") or "")
        if not hit and pat:
            p = os.path.expanduser(pat) if pat.startswith("~") else pat
            fixed = re.split(r"[*?\[{]", p)[0]  # Glob: o diretório fixo do pattern (antes do 1º curinga) também conta
            d = fixed if fixed.endswith("/") else os.path.dirname(fixed)
            fam = names_family(pat.rsplit("/", 1)[-1])
            hit = ((classify(d, cwd) or broad(d, cwd, deep=False)) if d and tool == "Glob" else None) or ((fam, pat) if fam else None)
        return (hit[0], hit[1], tool) if hit else None
    return None


def message(hit) -> str:
    rule, target, op = hit
    return ("[HOOK BLOCK: secret-read-guard] NÃO É CANCELAMENTO DO USUÁRIO — política automática de proteção de segredos.\n"
            f"BLOQUEADO: {op} em segredo ({rule}).\nAlvo: {target}\n"
            "Segredo não passa pelo agente: chave, token e senha vêm do cofre (`secret <item>` dentro do comando que os usa), nunca lendo o arquivo. "
            "Arquivo de exemplo (`.env.example`) e chave pública (`*.pub`) seguem liberados. Se a tarefa exige mesmo este arquivo, devolva a bead ao Mayor.\n")


def main() -> int:
    # vazio → stdin vazio é lixo, libera; falhou/ilegível (não é JSON) → bloqueia só se o texto cita um campo que este guarda lê (não dá para conferir o pedido)
    raw = sys.stdin.read()
    inp = None
    try:
        inp = json.loads(raw)
        hit = decide(inp)
    except Exception as e:  # noqa: BLE001 — falha do guarda não pode virar "liberado" num pedido que ele cobre
        if not (isinstance(inp, dict) and inp.get("tool_name") in COVERED) and not re.search(r"file_path|notebook_path|\"command\"|\"pattern\"", raw):
            return 0
        print(f"[HOOK BLOCK: secret-read-guard] o guarda falhou ({type(e).__name__}) e não consigo conferir este pedido: bloqueado.", file=sys.stderr)
        return 2
    if hit:
        print(message(hit), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
