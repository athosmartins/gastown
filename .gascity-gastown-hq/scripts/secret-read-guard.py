#!/usr/bin/env python3
r"""secret-read-guard.py — hook PreToolUse que recusa LER ou ESCREVER segredo pelas ferramentas de arquivo e pelo Bash (ga-nkfwixz).
Nasceu da comparação com o cc-safety-net 2.7.0 (docs/runbooks/guard-oracle-diff.md): nenhum guard nosso olhava caminho de segredo. DORMENTE: nenhum
settings.json chama este arquivo; ligar é decisão do Mayor (o trecho do hook e a medição estão no runbook).

PARA QUE SERVE
  Um agente (ou um texto injetado que ele leu) não lê `~/.ssh`, `~/.aws`, `~/.claude/.credentials.json`, `.env`, chave privada, `.netrc`… com Read, Grep, Glob, Edit,
  Write, MultiEdit, NotebookEdit nem com `cat` & cia. Segredo entra no comando pelo `secret <item>` (Bitwarden), nunca lendo o arquivo. Hook que sai 2 bloqueia em qualquer modo, `--dangerously-skip-permissions` incluso (medido no remote-clone-guard).
COMO DECIDE
  Ferramenta de arquivo: o caminho do pedido (file_path, notebook_path, path, o diretório fixo do pattern de Glob; Grep/Glob sem path = o cwd) é resolvido (`~`, `$HOME`, cwd, link simbólico)
  e comparado com o catálogo; Grep/Glob também recusam um glob que NOMEIA a família (`.env*`, `*.pem`). Bash: o texto é lido como o bash lê (aspas, comentário, heredoc, `bash -c`/`eval`/`$( )`, `cd`,
  embrulho `timeout`/`nohup`/`env`/`sudo`), cada palavra vira candidato a caminho (chave `{a,b}` e `{x..y[..n]}` primeiro, depois `~`, `$HOME`, atribuição anterior, `${X:-padrão}`, glob que EXISTE) e o código inline
  de python/node/perl/ruby/php/awk é varrido por literais de caminho. $( ) e crase rodam em QUALQUER palavra. Caminho com pedaço que não sei resolver: valem a pasta literal antes dele, o nome do fim e o
  caminho com o pedaço tirado. Verbo que só olha metadado (echo, ls, stat, test, cd, `git status|ls-files|check-ignore`, o padrão do grep, o valor de `find -name`) não conta como leitura, salvo quando a
  saída vira operando de outro comando (`xargs`, `read`, `$( )`); redirecionamento conta sempre.
  CWD E VARIÁVEL = CONJUNTO, não um valor: um `cd` pode falhar, ser condicional ou cair noutra pasta (CDPATH, cdable_vars), e uma atribuição pode não ter rodado. Cada linha vale para TODOS os cwds que ela pode ter
  (o de antes continua possível; destino que não existe não entra) e cada variável vale com TODOS os valores que recebeu na chamada (até 512 combinações; mais, ou mais de 64 cwds, bloqueia).
CÓDIGOS: 0 liberado · 2 bloqueado. Falha do próprio guarda num pedido que ele cobre = bloqueado (nunca "liberado"); aninhamento acima de 6 níveis, byte NUL num caminho e glob cujos CASOS não terminam de ser conferidos em 4 s também ("não consigo ler" = bloqueado).
  O prazo de 4 s só é conferido quando o glob devolve um caso: um glob que percorre muito e casa pouco (`cat d/*/*/*/*/x`) NÃO é limitado por ele, e um hook que passa do timeout do harness não sai 2 (não bloqueia).
LIMITES (trava contra engano, não sandbox; o fecho de verdade é permissão de arquivo por usuário Unix): não vejo caminho montado em pedaços (`chr()`, concatenação,
  `base64 -d`), variável que não é HOME nem atribuída na mesma chamada (raiz desconhecida + pasta de segredo + nome comum, `$X/.gnupg/pubring.kbx`, passa), variável de laço, script que o
  comando executa (`bash x.sh`), segredo no ambiente, nem o que um programa lê sozinho (`ssh` usa a chave). Depois de um `cd` que não sigo (`cd $X`, `cd` relativo com CDPATH/cdable_vars em jogo, `eval "cd …"`) o cwd
  é desconhecido: nome de segredo e arquivo que existe numa pasta de segredo bloqueiam; `grep -r x .` e criar arquivo novo de nome comum, não. CDPATH atribuído por nome montado (`declare "$n=…"`), `eval "$cmd"`, alias,
  `~+`, `~-`, `~usuário`, `${HOME%/}` e `shopt -s globstar dotglob` não são modelados. Lista completa: docs/runbooks/guard-oracle-diff.md, "Limites".
"""
from __future__ import annotations

import functools
import glob
import itertools
import json
import os
import re
import stat
import sys
import time

FILE_TOOLS = {"Read": "file_path", "Edit": "file_path", "Write": "file_path", "MultiEdit": "file_path", "NotebookEdit": "notebook_path", "NotebookRead": "notebook_path"}
WRITE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
COVERED = {"Bash", "Grep", "Glob", *FILE_TOOLS}
BUDGET_S = 4.0  # segundos que um pedido tem para conferir os CASOS de glob (nó: ~20 mil caminhos/s; mini: bem menos): estourou no meio dos casos BLOQUEIA (secret.glob-too-wide), nunca olha uma parte e libera o resto. Só é conferido quando o glob devolve um caso: o que percorre muito e casa pouco não é limitado (Limites)
LATE = [0.0]  # o prazo do pedido em curso, em time.monotonic() (decide() recarrega)
CDP = [False]  # CDPATH ou cdable_vars em jogo neste pedido (decide() recarrega, scan_bash liga): um `cd` relativo sem ./ ou ../ pode cair noutra pasta que não a do cwd
CDP_MENTION = re.compile(r"cdpath|cdable_?vars", re.I)  # bash: CDPATH e `shopt -s cdable_vars`; zsh: o array `cdpath` e `setopt cdable_vars` (opção sem diferença de caixa nem de `_`)
ALTS = "\0alts"  # chave do env: nome -> TODOS os valores que a variável recebeu na chamada (atribuição repetida ou condicional: o shell pode ter ficado com qualquer um)
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
ASSIGN = re.compile(r"[A-Za-z_]\w*\+?=")
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


def valuations(text: str, env: dict) -> list:
    """Cada valoração de `env` para as variáveis que `text` cita e que receberam valores diferentes na chamada (`D=a; [ -f x ] && D=b`: o shell pode ter ficado com qualquer um): [env] se não há
    nenhuma. Passou de 512 combinações (um laço `for` de 30 ids vale 30; só o PRODUTO entre variáveis explode): OverflowError, quem chama decide (classify BLOQUEIA)."""
    alts = env.get(ALTS) or {}  # vazio → nenhuma variável com valores alternativos, vale o env como está; falhou/ilegível → n/a (dict em memória)
    names = [n for n in dict.fromkeys(re.findall(r"\$\{?(" + NAME + ")", text)) if n in alts]
    combos = list(itertools.product(*(alts[n] for n in names)))
    if len(combos) > 512:
        raise OverflowError(text)
    return [dict(env, **dict(zip(names, c))) for c in combos] if names else [env]


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


SEQ = re.compile(r"(?<!\$)\{([+-]?\d+|[^{},.])\.\.([+-]?\d+|[^{},.])(?:\.\.([+-]?\d+))?\}")  # `{x..y}` e `{x..y..n}`: x e y inteiros ou um caractere só


def sequence(m):
    """Os valores de uma sequência `{x..y[..n]}`, ou None se não é sequência (o shell a deixa como texto). Inteiros (sem o zero à esquerda que o shell preenche: nenhuma regra do catálogo
    depende de dígito); caracteres por código (o zsh anda por qualquer caractere, o bash só por letras: aqui vale o maior); passo 0 vale 1 e o sinal do passo não conta. Mais de 64 valores: OverflowError."""
    a, b, n = m.group(1), m.group(2), m.group(3)
    step = abs(int(n)) if n else 1
    if re.fullmatch(r"[+-]?\d+", a) and re.fullmatch(r"[+-]?\d+", b):
        lo, hi, fmt = int(a), int(b), str
    elif len(a) == 1 and len(b) == 1:
        lo, hi, fmt = ord(a), ord(b), chr
    else:
        return None
    step = step or 1
    if abs(hi - lo) // step + 1 > 64:
        raise OverflowError(m.group(0))
    return [fmt(lo + i * step * (1 if hi >= lo else -1)) for i in range(abs(hi - lo) // step + 1)]


def braces(s: str, depth: int = 3) -> list:
    """Expansão de chave, as duas formas: lista `{a,b}` e sequência `{x..y[..n]}`. Passou do teto (16 alternativas, 3 níveis, 64 resultados) levanta OverflowError: quem chama BLOQUEIA, nunca corta em silêncio."""
    m = re.search(r"(?<!\$)\{([^{}]*,[^{}]*)\}", s)  # `${X:-a,b}` é expansão de parâmetro, não chave
    q = next(((x, v) for x in SEQ.finditer(s) if (v := sequence(x)) is not None), None)  # vazio → não há sequência: segue só a lista; falhou/ilegível (mais de 64 valores) → OverflowError, que bloqueia
    if q and (not m or q[0].start() < m.start()):
        out = [r for v in q[1] for r in braces(s[:q[0].start()] + v + s[q[0].end():], depth - 1)] if depth else None
        if out is None or len(out) > 64:
            raise OverflowError(s)
        return out
    if not m:
        return [s]
    alts = m.group(1).split(",")
    out = [r for alt in alts for r in braces(s[:m.start()] + alt + s[m.end():], depth - 1)] if depth and len(alts) <= 16 else None
    if out is None or len(out) > 64:
        raise OverflowError(s)
    return out


BRACKET = re.compile(r"\[(?:[^\]\[]|\[:[a-z]+:\])+\]")
EXTGLOB = re.compile(r"[@+!*?]\((?:[^()]|\([^()]*\))*\)")  # extglob (`shopt -s extglob`): @(a|b) +(a) !(a) *(a) ?(a)


def cases(cand: str):
    """Os caminhos que o glob de `cand` devolve, um a um. Passou do prazo do pedido (LATE) no meio deles: OverflowError, porque olhar uma parte e liberar o resto é o mesmo 0 de "não é segredo"."""
    n, pat = 0, EXTGLOB.sub("*", BRACKET.sub(lambda m: "?" if "[:" in m.group(0) else m.group(0), cand.replace("[^", "[!")))  # o bash lê `[^c]` como `[!c]`; classe POSIX que o fnmatch não conhece vira `?`; grupo extglob vira `*` (casa a mais: nunca a menos)
    for n, p in enumerate(glob.iglob(pat), 1):  # vazio → o literal vale; falhou/ilegível (permissão, loop de link) → glob devolve [] e o literal vale
        if time.monotonic() > LATE[0]:
            raise OverflowError(cand)
        yield p
    if not n:
        yield cand


def classify(raw: str, cwd, write: bool = False, env=None):
    """(regra, caminho) se `raw` é caminho de segredo; None se não é, ou se não sei resolver o caminho TODO (variável que não conheço: limite documentado, não bloqueio; mas a pasta
    literal antes do pedaço desconhecido e o nome do fim ainda valem, ver partial()). Variável que recebeu valores diferentes na chamada: confere cada um (valuations())."""
    try:
        envs = valuations(raw or "", env or {})
    except OverflowError:  # variáveis demais com valor alternativo: não consigo conferir todas as combinações
        return "secret.too-many-values", (raw or "").strip()
    return next(filter(None, (classify_env(raw, cwd, write, e) for e in envs)), None)


def classify_env(raw: str, cwd, write: bool, env: dict):
    raw = (raw or "").strip()
    if "\x00" in raw:  # vazio → n/a; falhou/ilegível → byte NUL: nenhuma ferramenta abre esse caminho e cada versão do Python o trata de um jeito (3.9 engole o ValueError, 3.11+ levanta): bloqueia explícito
        return "secret.nul-byte", raw.replace("\x00", "\\x00")
    if not raw or raw.startswith("-") or re.match(r"[A-Za-z][\w+.-]*://", raw):
        return None
    try:
        alts = braces(raw)  # o bash faz a chave PRIMEIRO e depois o `~` e o `$` de cada palavra: `{~/.gnupg/x,y}` abre ~/.gnupg/x
        cands = [expand(b, cwd, env or {}) for b in alts]
    except OverflowError:
        return "secret.brace-expansion", raw
    for alt, cand in zip(alts, cands):
        if "\x00" in cand:  # o NUL veio do valor de uma variável ou do cwd do pedido
            return "secret.nul-byte", cand.replace("\x00", "\\x00")
        guess = isinstance(cwd, Guess) and not os.path.isabs(subst(alt, env or {}))  # nome relativo numa pasta que só suponho ser o cwd
        if UNKNOWN.search(cand):
            hit = partial(cand, write)
            hit = None if guess and hit and hit.startswith(("secret.home.", "secret.cli.")) else hit  # pasta suposta + pedaço desconhecido (`$f`, `$(…)`): a variável pode ser um caminho absoluto, não sei sob qual pasta cai; o nome do fim ainda vale
            if hit:
                return hit, cand
            # (C) o pedaço desconhecido pode ser VAZIO (variável não atribuída, `$( )` sem saída): sem ele o caminho segue o fluxo normal, glob incluso (`.cr*$X` é `.credentials.json`)
            bare = os.path.normpath(PIECE.sub("", cand))
            if bare == cand or UNKNOWN.search(bare):  # nada a tirar, ou sobrou pedaço que não sei tirar: não consigo saber, o limite documentado
                continue
            cand = bare
        try:
            for p in cases(cand) if re.search(r"[*?\[]|[@+!]\(", cand) else [cand]:
                for form in dict.fromkeys((os.path.normpath(p), os.path.realpath(p))):  # a mesma forma duas vezes é um custo só
                    r = match(form, write)
                    if r and r.startswith(("secret.home.", "secret.cli.")) and (guess or ("/" not in raw and not write)) and (not os.path.lexists(form) or (guess and os.path.normpath(p) == cwd)):
                        r = match(form, write, False)  # palavra solta que só cai na pasta do segredo por causa de um `cd` e não existe lá (`cd ~/.ssh; head -n 2 config`): vale só o NOME; na pasta suposta (Guess) vale o mesmo para qualquer nome relativo, com `/` e para escrita
                    if r:
                        return r, form
        except OverflowError:  # sem tempo no meio dos casos do glob
            return "secret.glob-too-wide", cand
    return None


CRED_PARENTS = {sub[:k] for sub, _, _ in HOME_SUB for k in range(1, len(sub))}  # ancestrais de segredo do catálogo que não são segredo em si: ~/.claude (guarda .credentials.json), ~/.config, ~/.dolt, ~/gt-remote…
BASES = sorted(CRED_PARENTS | {sub for sub, _, is_file in HOME_SUB if not is_file} | {(d,) for d in HOME_DIRS} | {()})  # pastas (sob o HOME) onde um nome relativo vira segredo


def broad(raw: str, cwd, env=None, deep: bool = True):
    """('secret.scan.home', caminho) se `raw` é o HOME, um ancestral dele ou `~/gt-remote` (ancestral de ~/gt-remote/keys): varrer isso recursivamente lê segredo. deep=True (quem LÊ
    conteúdo: grep -r, find, tar, cp -r, Grep) vale também para os outros ancestrais de segredo do catálogo (`~/.claude`, `~/.config`…); deep=False (Glob só lista nomes) fica no HOME e acima.
    Variável com valores alternativos: confere cada um (valuations())."""
    try:
        envs = valuations(raw or "", env or {})
    except OverflowError:
        return "secret.too-many-values", (raw or "").strip()
    return next(filter(None, (broad_env(raw, cwd, e, deep) for e in envs)), None)


def broad_env(raw: str, cwd, env: dict, deep: bool):
    if isinstance(cwd, Guess) and not os.path.isabs(subst(raw or "", env or {})): return None  # `.` numa pasta que só suponho ser o cwd: varrer o cwd de um `cd` que não sigo é o `grep -r x .` de todo dia, limite documentado
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
OPENERS = {"{", "then", "do", "else", "elif", "if", "while", "until", "!"}  # palavras reservadas que abrem a linha: o comando de verdade vem depois
DYN = re.compile(r"[$`]|^~|^[+-]\d*$")  # destino de `cd` que não sei seguir: $X, $( ), crase, ~usuario, `-` (OLDPWD), +N/-N (pilha do pushd)
UNSURE = object()  # o cwd depois de um `cd` assim: nem o anterior nem outro que eu invente (usá-lo sem passar por where() levanta TypeError, e o guarda bloqueia)
Guess = type("Guess", (str,), {})  # cada pasta que where() devolve no lugar do UNSURE: palavra relativa que não existe nela, ou que é ela mesma (`.`), vale só pelo NOME (`sleep 1`, `cat src/a.py`, `cp -r . /tmp/x` depois de `cd "$(git rev-parse --show-toplevel)"`)
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
        elif c == '"' or (c == "$" and nx == '"'):  # $"…" é "…" (tradução de locale)
            i += 1 + (c == "$"); word = True
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
        elif c == "(" and word and re.fullmatch(r"[A-Za-z_]\w*\+?=", "".join(cur)):  # NOME=(a b): array, UMA palavra só (os elementos são caminhos e `$NOME` é o 1º)
            j = skip_subst(text, i - 1); cur.append(text[i:j]); i = j
        elif c == "(" and word and cur and cur[-1][-1:] in ("@", "+", "!", "*", "?"):  # extglob `@(a|b)` e qualificador de glob do zsh `*(.)`: o grupo é parte da palavra (o cases() o lê)
            j = skip_subst(text, i - 1); cur.append(text[i:j]); i = j
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


def bare(ws: list) -> list:
    """A linha sem as palavras reservadas que a abrem (`{`, `then`, `do`, `if`, `function f`…): `{ cd x; cat y; }` e `if cd x; then cat y; fi` têm o `cd` e o `cat` como verbos."""
    while ws and (ws[0] in OPENERS or ws[0] == "function"):
        ws = ws[2:] if ws[0] == "function" else ws[1:]
    return ws


def where(cwd) -> list:
    """Onde conferir uma linha: o cwd; se não sei qual é (UNSURE), cada pasta em que um nome relativo vira segredo (o HOME e as pastas de segredo sob ele): vazio → n/a; falhou/ilegível → não consegui saber, vale todas."""
    return [Guess(os.path.join(home(), *p)) for p in BASES] if cwd is UNSURE else [cwd]


def uniq(items: list) -> list:
    """Os cwds sem repetir (UNSURE vale um só)."""
    out, keys = [], set()
    for c in items:
        k = "\0unsure" if c is UNSURE else str(c)
        if k not in keys:
            keys.add(k)
            out.append(c)
    return out


def pool(here: list) -> list:
    """Onde conferir uma linha: where() de CADA cwd possível, sem repetir (a mesma pasta conhecida e suposta vale a conhecida, a mais estrita)."""
    out = {}
    for c in here:
        for b in where(c):
            if str(b) not in out or (isinstance(out[str(b)], Guess) and not isinstance(b, Guess)):
                out[str(b)] = b
    return list(out.values())


def may_exist(p: str) -> bool:
    """O `cd` para `p` pode ter dado certo (então `p` é um cwd possível)? Existe como pasta: sim. Não existe: não (o `cd` falha e o cwd fica onde estava, que já está no conjunto)."""
    try:  # vazio → não existe: o cd falha; falhou/ilegível (permissão, loop de link, byte NUL) → não sei se existe: vale como possível
        return stat.S_ISDIR(os.stat(p).st_mode)
    except (FileNotFoundError, NotADirectoryError):
        return False
    except (OSError, ValueError):
        return True


def cd_targets(words: list, cwd, env: dict) -> list:
    """Os cwds possíveis depois da linha SE ela é um `cd` que rodou: [cwd] se ela não é cd; o destino do `cd`/`pushd` (um por valor possível da variável do destino e por pasta que o glob ou a chave do destino casa); UNSURE se não sei qual é (DYN,
    `popd`, `pushd` sem destino, relativo a um UNSURE, `eval` com `cd` dentro, e `cd` relativo sem ./ ou ../ quando CDPATH ou cdable_vars está em jogo: o shell o procura em
    outras pastas). `-P` (em qualquer posição) acrescenta a pasta com os links resolvidos: o `..` seguinte parte da pasta real. Quem chama junta isto ao conjunto de antes: o `cd` pode falhar ou ser condicional."""
    ws = [w for k, w in enumerate(words) if not ASSIGN.match(w) and not isinstance(w, Op) and not (k and isinstance(words[k - 1], Op))]  # sem atribuição, sem redirecionamento (operador e alvo)
    while ws and ws[0] in ("time", "command", "builtin", "!"):  # seguem sendo o cd do próprio shell (`timeout`, `env`, `nohup` rodariam um programa externo)
        ws = ws[1:]
    verb = os.path.basename(ws[0]) if ws else ""
    if verb == "eval" and re.search(r"\b(?:cd|pushd|popd)\b", " ".join(ws[1:])):  # roda no shell de quem chamou, e o que o texto faz eu não sigo
        return [UNSURE]
    if verb not in ("cd", "pushd", "popd"):
        return [cwd]
    args, physical = ws[1:], False
    while args and (args[0] == "--" or re.fullmatch(r"-[LPe@]+", args[0])):  # opções (combinadas: `-Pe`); `--` encerra. Opção que o cd não tem (`-x`, `pushd -n`) não troca de pasta: o cwd de antes já está no conjunto
        if args[0] == "--":
            args = args[1:]
            break
        physical = physical or "P" in args[0]  # o bash fica com a última entre -L e -P, o zsh com -P em qualquer posição: vale o maior (os dois cwds)
        args = args[1:]
    if verb == "popd" or (verb == "pushd" and not args):
        return [UNSURE]
    out = []
    try:
        evs = valuations(args[0], env) if args else [env]
    except OverflowError:  # variáveis demais com valor alternativo: não sei para onde foi
        return [UNSURE]
    for ev in evs:
        try:  # o shell faz chave e glob na palavra do destino (`cd ~/.cl*`, `cd ~/.{claude,x}`): cada pasta que casa é um destino possível
            ds = braces(subst(args[0], ev) if args else home())
        except OverflowError:  # chave além do teto: não sei para onde foi
            out.append(UNSURE)
            continue
        for d in ds:
            explicit = d in (".", "..") or d.startswith(("./", "../"))  # só / ./ ../ pulam o CDPATH
            if DYN.search(d) or (cwd is UNSURE and not os.path.isabs(d)) or (CDP[0] and not os.path.isabs(d) and not explicit):
                out.append(UNSURE)
                continue
            t = d if os.path.isabs(d) else os.path.join(cwd, d)
            try:  # vazio → glob que não casa nada vale o texto (o cd falha, o cwd fica); falhou/ilegível (sem tempo no meio dos casos) → não sei para onde foi
                for g in cases(t) if re.search(r"[*?\[]|[@+!]\(", t) else [t]:
                    out += [os.path.normpath(g)] + ([os.path.realpath(g)] if physical else [])
            except OverflowError:
                out.append(UNSURE)
    return out


def scan_bash(cmd: str, cwd, depth: int = 0, env=None, strict: bool = False):
    env = dict(env or {})
    if depth > 6:  # vazio → n/a; falhou/ilegível (aninhamento mais fundo do que eu varro) → BLOQUEIA: o que eu não leio pode ser o segredo (igual ao teto da chave {a,b})
        return "secret.nesting-too-deep", cmd[:80]
    toks, docs = lex(cmd)
    if any(CDP_MENTION.search(t) for t in toks if not isinstance(t, Op)):  # o pedido mexe em CDPATH/cdable_vars (ou o ambiente do hook já tem): vale desde a 1ª linha, em todos os níveis
        CDP[0] = True
    strict = strict or any(not isinstance(t, Op) and os.path.basename(t) in FEEDERS for t in toks)
    # here = TODOS os cwds possíveis agora (um `cd` pode falhar, ser condicional ou cair via CDPATH: o cwd de antes continua possível); feed = palavras dos comandos anteriores da MESMA pipeline; seen = todo cwd por onde passou
    cur, here, saved, feed, seen = [], [cwd], [], [], [cwd]
    for t in toks + [Op(";")]:
        if isinstance(t, Op) and t in SEP_OPS:
            cur, snap = bare(cur), dict(env)  # snap: cada pasta de pool() avalia a atribuição da linha a partir do mesmo env (`A=$A$A` não dobra a cada pasta)
            hit = next(filter(None, (one(cur, b, depth, env if k == 0 else dict(snap), strict, feed) for k, b in enumerate(pool(here)))), None)
            if hit:
                return hit
            feed = feed + cur if t in ("|", "|&") else []
            here = uniq(here + [n for c in here for n in cd_targets(cur, c, env) if n is UNSURE or n == c or may_exist(n)])  # destino que não existe: o cd falha e o cwd de antes já está no conjunto
            if len(here) > 64:  # vazio → n/a; falhou/ilegível (pastas demais por onde o cd passou) → BLOQUEIA: não confiro o que não caberia no prazo
                return "secret.cwd-too-many", cmd[:80]
            if t == "(":
                saved.append(here)
            elif t == ")" and saved:
                here = saved.pop()
            seen = uniq(seen + here)
            cur = []
        else:
            cur.append(t)
    # o corpo de heredoc roda onde o comando rodou, e o `cd` antes dele conta (`cd ~/.claude; bash <<EOF … cat .credentials.json`): vale cada cwd por onde passou
    for (body, recv, quoted), b in itertools.product(docs, pool(seen)):  # corpo lido como DADO (cat, git commit -F -, tee…): o texto citar `.env` não é ler `.env`; lido por shell ou interpretador, é código
        hit = scan_bash(body, b, depth + 1, env) if any(w in SHELLS for w in recv) else None
        hit = hit or (literals(body, b, env) if any(INTERP.fullmatch(w) for w in recv) else None)
        for sub in () if quoted or hit else substitutions(body):  # delimitador SEM aspas: o $( ) e a crase do corpo RODAM, e a saída vira o texto que o leitor recebe
            hit = hit or scan_bash(sub, b, depth + 1, env, True)
        if hit:
            return hit
    return None


def elems(val: str) -> list:
    """Os elementos de `(a b c)` (array: o lex o deixa numa palavra só) ou o próprio `val`: vazio → `()` não tem elemento; falhou/ilegível → texto sem fecho não é array e vale inteiro."""
    return [str(e) for e in lex(val[1:-1])[0] if not isinstance(e, Op)] if val[:1] == "(" and val[-1:] == ")" else [val]


def assign(word: str, cwd, env: dict):
    """`NOME=valor`, `NOME=(a b)`, `NOME+=…`: cada valor (ou elemento) é candidato a caminho (devolve a regra) e NOME vira variável para as palavras seguintes, com TODOS os valores que já recebeu na chamada (ALTS: a atribuição pode ser condicional): `$NOME` é o 1º elemento de um array,
    valor vazio vale vazio, e `+=` deixa o valor desconhecido (não sei o que havia antes)."""
    name, val = word.split("=", 1)
    els = elems(val)
    hit = next(filter(None, (classify(e, cwd, False, env) for e in els)), None)  # confere ANTES de gravar: `X=$X/a` lê o $X de antes da linha
    alts = dict(env.get(ALTS) or {})  # vazio → nenhuma variável com valor alternativo; falhou/ilegível → n/a (dict em memória)
    if name.endswith("+"):
        env.pop(name[:-1], None)
        alts.pop(name[:-1], None)
    else:
        first = els[0] if els else ""
        try:
            news = tuple(dict.fromkeys(subst(first, e) for e in valuations(first, env)))
        except OverflowError:  # o valor depende de variáveis demais com valor alternativo: não confiro as combinações
            return hit or ("secret.too-many-values", word[:80])
        before = alts.get(name) or ((env[name],) if name in env else ())  # o shell pode ter ficado com o valor de antes (atribuição condicional ou que falhou) ou com o novo: vale TODOS
        env[name] = subst(first, env)  # o valor como o shell o guarda: SEM juntar ao cwd (`D=.gnupg; cd ~; cat $D/x` abre ~/.gnupg/x)
        both = tuple(dict.fromkeys(before + news))
        if len(both) > 1:
            alts[name] = both
    env[ALTS] = alts
    return hit


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
        hit = assign(words[i], cwd, env)
        if hit:
            return hit
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
    for w in words:  # `: ${D:=.claude}` e `${D=…}` atribuem D (se estava vazio ou sem valor): o valor entra como mais um valor possível
        for m in re.finditer(r"\$\{(" + NAME + r")(?::?=)([^{}]*)\}", w):
            hit = assign(m.group(1) + "=" + m.group(2), cwd, env)
            if hit:
                return hit
    if ws[0] in ("for", "select") and len(ws) > 3 and ws[2] == "in" and re.fullmatch(NAME, ws[1]):  # `for d in .claude .gnupg`: d vale cada palavra (a união dos valores; lista com glob ou $( ) fica como escrita)
        for w in ws[3:]:
            hit = assign(ws[1] + "=" + w, cwd, env)
            if hit:
                return hit
    # o verbo é o de verdade, não o embrulho (`timeout 5 grep -r x ~/.claude` varre; `nohup find … | xargs cat` lista e lê); args segue com TODAS as palavras depois do 1º (candidatos a caminho)
    ev = real_verb(ws)
    verb, args, eargs, skip = os.path.basename(ws[ev]), ws[1:], ws[ev + 1:], set()  # skip = índices (em args) de palavras que são CÓDIGO ou padrão, não caminho
    if verb in ("export", "declare", "typeset", "local", "readonly"):  # `export D=.gnupg` também vira variável para as palavras seguintes
        for a in args:
            if ASSIGN.match(a):
                assign(a, cwd, env)  # só a variável: o laço de baixo confere o valor
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
    names = verb == "find" and not strict and not any(a in ("-exec", "-execdir", "-ok", "-okdir", "-delete") for a in eargs)  # `find -name .env` só lista; com -exec lê o que achou, e em modo estrito (a saída vira operando de xargs/read/$( )) o nome buscado é o que será lido
    scans = verb in GREPS or verb in ("tar", "zip", "rsync", "cp", "scp") or (verb == "find" and not names)
    for k, a in enumerate(args):
        if k in skip or (names and k and args[k - 1] in FIND_VAL):
            continue
        cand = (a.split("=", 1)[1] if re.match(r"-{0,2}[A-Za-z_][\w-]*=", a) else a).lstrip("@")
        cand = m.group(1) if (m := re.fullmatch(r"-[A-Za-z](.+)", cand)) else cand  # `ssh -i~/.ssh/id_rsa`: valor colado na opção
        hit = next(filter(None, (classify(c, cwd, not reads, env) or (broad(c, cwd, env) if scans else None) for c in elems(cand))), None)  # array `declare -a D=(a b)`: cada elemento
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
    CDP[0] = bool(os.environ.get("CDPATH") or CDP_MENTION.search(os.environ.get("BASHOPTS", "")))  # vazio → CDPATH ausente ou vazio, sem cdable_vars: o shell não procura o destino do cd em outras pastas; o ambiente do hook é o da sessão
    tool, ti, cwd = inp.get("tool_name"), inp.get("tool_input") or {}, inp.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()  # vazio → pedido sem cwd parte do cwd do hook (o da sessão)
    if tool == "Bash":
        hit = scan_bash(str(ti.get("command") or ""), cwd)
        return (hit[0], hit[1], "comando Bash") if hit else None
    if tool in FILE_TOOLS:  # vazio → sem caminho no pedido = nada a conferir (a própria ferramenta recusa)
        hit = classify(str(ti.get(FILE_TOOLS[tool]) or ""), cwd, tool in WRITE_TOOLS)
        return (hit[0], hit[1], ("escrita" if tool in WRITE_TOOLS else "leitura") + " (" + tool + ")") if hit else None
    if tool in ("Grep", "Glob"):
        # vazio → `path` omitido é o cwd da ferramenta (Grep e Glob varrem o cwd): vale como se estivesse escrito
        where = str(ti.get("path") or "") or cwd
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
