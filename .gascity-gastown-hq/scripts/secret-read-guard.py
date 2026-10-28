#!/usr/bin/env python3
r"""secret-read-guard.py — hook PreToolUse que recusa LER ou ESCREVER segredo pelas ferramentas de arquivo e pelo Bash (ga-nkfwixz).
Veio da comparação com o cc-safety-net 2.7.0 (docs/runbooks/guard-oracle-diff.md): nenhum guard nosso olhava caminho de segredo. DORMENTE: nenhum
settings.json chama este arquivo ainda; ligar é decisão do Mayor (o trecho do hook está no runbook).

Contents
  Para que serve · Como decide · Códigos · Limites
PARA QUE SERVE
  Um agente (ou um texto injetado que ele leu) não lê `~/.ssh`, `~/.aws`, `~/.claude/.credentials.json`, `.env`, chave privada, `.netrc`… com Read, Grep, Glob,
  Edit, Write, MultiEdit, NotebookEdit nem com `cat` & cia. Segredo entra num comando pelo `secret <item>` (Bitwarden), nunca lendo o arquivo. Vale sob
  `--dangerously-skip-permissions`: hook que sai 2 bloqueia a chamada em qualquer modo.
COMO DECIDE
  Ferramenta de arquivo: o caminho do pedido (file_path, notebook_path, path, o diretório fixo do pattern de Glob/Grep) é resolvido (`~`, `$HOME`, cwd, link
  simbólico) e comparado com o catálogo; Grep/Glob também recusam um glob que NOMEIA a família (`.env*`, `*.pem`, `id_rsa*`). Bash: o texto é lido como o shell
  lê (aspas, comentário, heredoc, `bash -c`/`eval`/`$( )`), cada palavra vira candidato a caminho (com `~`, `$HOME`, atribuição anterior, chave `{a,b}` e glob
  que EXISTE no disco) e o código inline de python/node/perl/ruby/php/awk é varrido por literais de caminho. Verbo que só olha metadado (echo, printf, ls, stat,
  test, touch, `git status|ls-files|check-ignore`, o padrão do grep, o valor de `find -name`) não conta como leitura; redirecionamento conta sempre.
CÓDIGOS: 0 liberado · 2 bloqueado. Falha do próprio guarda num pedido de ferramenta que ele cobre = bloqueado (nunca "liberado"). `--selfcheck` roda sondas internas.
LIMITES (é trava contra engano, não sandbox; o fecho de verdade é permissão de arquivo por usuário Unix): não vejo caminho montado em pedaços (`chr()`, concatenação,
  `base64 -d`), variável que não é HOME nem atribuída na mesma chamada, script que o comando executa (`bash x.sh`), `cd <dir>` seguido de nome relativo que não é
  segredo por si (`config`), nem o que um programa lê por conta própria (`ssh` usa a chave sozinho). Detalhe e falsos positivos: runbook guard-oracle-diff.md.
"""
from __future__ import annotations

import glob
import json
import os
import re
import sys

FILE_TOOLS = {"Read": "file_path", "Edit": "file_path", "Write": "file_path", "MultiEdit": "file_path", "NotebookEdit": "notebook_path", "NotebookRead": "notebook_path"}
WRITE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
COVERED = {"Bash", "Grep", "Glob", *FILE_TOOLS}

# --- catálogo (portado do cc-safety-net 2.7.0, src/core/rules/secret.ts, e cortado ao que existe nas nossas máquinas) ---
HOME_DIRS = {".ssh": "secret.home.ssh", ".aws": "secret.home.aws", ".gcp": "secret.home.gcp", ".gnupg": "secret.home.gnupg"}
HOME_SUB = (  # (partes sob o HOME, regra, é arquivo?) — arquivo aceita também `<nome>.bak|.old…`; pasta vale com qualquer filho
    ((".config", "gcloud"), "secret.home.gcloud-config", False), ((".config", "rclone"), "secret.home.rclone", False), ((".dolt", "creds"), "secret.home.dolt-creds", False),
    (("gt-remote", "keys"), "secret.home.gt-remote-keys", False), ((".config", "gh", "hosts.yml"), "secret.home.gh-hosts", True),
    ((".kube", "config"), "secret.home.kube-config", True), ((".docker", "config.json"), "secret.home.docker-config", True),
    ((".claude", ".credentials.json"), "secret.cli.claude-code", True))
SSH_OK = {"config", "known_hosts", "known_hosts.old"}  # sob ~/.ssh: só LER; escrever em qualquer um (authorized_keys, config) continua bloqueado
BASENAMES = {n: "secret.basename." + n.strip(".").replace("_", "-").replace(".", "-") for n in
             (".env", ".npmrc", ".pypirc", ".netrc", ".git-credentials", ".pgpass", ".my.cnf", "id_rsa", "id_dsa", "id_ed25519", "id_ecdsa", "credentials")}
KEY_PREFIXES = ("id_rsa", "id_dsa", "id_ed25519", "id_ecdsa")
DOT_VARIANTS = {".bak", ".backup", ".copy", ".disabled", ".key", ".old", ".orig", ".pem", ".save", ".tmp"}
SECRET_EXT = {"pem", "p12", "pfx", "pkcs12", "jks", "keystore", "keyring", "kdb", "kdbx", "key", "keypair", "ovpn"}
ENV_TEMPLATE = (".example", ".sample", ".template", ".tpl")  # `.env.local.example`; `.env.defaults` e `.env.example.x` também passam
BROAD_SKIP = ("node_modules", "__pycache__", "site-packages", "dist-packages")  # certificados de pacote não são segredo nosso: só as regras largas (extensão, *_rsa) pulam
BROAD_KEY = re.compile(r"[^.]*_(?:rsa|dsa|ed25519|ecdsa)")

SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "ash"}
INTERP = re.compile(r"(?:python[\d.]*|node(?:js)?|perl|ruby|php|lua|deno|bun|awk|gawk|mawk|osascript)")
CODE_FLAGS = {"-c", "-e", "-E", "-r", "-p", "--eval", "--print", "--command"}
EXEMPT = {"echo", "printf", "ls", "ll", "la", "stat", "test", "[", "[[", "true", "false", ":", "cd", "pushd", "popd"}
GIT_EXEMPT = {"check-ignore", "ls-files", "status"}
GREPS = {"grep", "egrep", "fgrep", "rg", "ag", "ack"}
FIND_VAL = {"-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-regex", "-iregex", "-lname", "-ilname"}
ASSIGN = re.compile(r"[A-Za-z_]\w*=")
RUN = re.compile(r"[~$/\w.{}@+%-]+")  # um "pedaço de caminho" dentro de código inline


def homes() -> list:
    out = []
    for h in (os.environ.get("HOME"), os.path.expanduser("~"), "/root"):
        # vazio → pulo (sem HOME o catálogo âncora só em /home/* e /Users/*); falhou → realpath devolve o texto normalizado
        if h and h != "~":
            for v in (os.path.normpath(h), os.path.realpath(h)):
                if v not in out:
                    out.append(v)
    return out


def rel_to_home(parts: list) -> list:
    """Possíveis 'partes sob o HOME' de um caminho absoluto já em partes (uma lista de listas, minúsculas)."""
    low, res = [p.casefold() for p in parts], []
    for h in homes():
        hp = [p.casefold() for p in h.split("/") if p]
        if hp and low[:len(hp)] == hp:
            res.append(low[len(hp):])
    if len(low) >= 2 and low[0] in ("home", "users"):
        res.append(low[2:])
    return res


def match(path: str, write: bool, homerules: bool = True):
    """Regra de segredo de um caminho absoluto, ou None. homerules=False pula as regras ancoradas no HOME (só as por NOME)."""
    parts = [p for p in path.split("/") if p]
    if not parts:
        return None
    base, low = parts[-1].casefold(), [p.casefold() for p in parts]
    for rel in (rel_to_home(parts) if homerules else []):
        if rel and rel[0] in HOME_DIRS:
            if rel[0] == ".ssh" and not write and len(rel) == 2 and (rel[1] in SSH_OK or rel[1].endswith(".pub")):
                continue
            return HOME_DIRS[rel[0]]
        for sub, rule, is_file in HOME_SUB:
            n = len(sub)
            if rel[:n - 1] == list(sub[:-1]) and len(rel) >= n and (rel[n - 1] == sub[-1] or (is_file and rel[n - 1].startswith(sub[-1] + ".")) or (not is_file and rel[n - 1] == sub[-1])):
                return rule
    if re.search(r"\s", base):
        return None  # as regras abaixo são por NOME de arquivo; texto com espaço (mensagem de commit, argumento de código) não é nome
    if base == ".env.defaults" or base.endswith(ENV_TEMPLATE) and base.startswith(".env.") or base.startswith((".env.example.", ".env.sample.")):
        return None
    if base.endswith(".pub") and base[:-4] in KEY_PREFIXES:
        return None
    if base in BASENAMES:
        return BASENAMES[base]
    if base.startswith(".env."):
        return "secret.pattern.env-variant"
    for p in KEY_PREFIXES + ("credentials",):
        if base.startswith(p) and len(base) > len(p):
            if base[len(p)] in "-_" and p != "credentials":
                return "secret.variant." + p.replace("_", "-") + ".separator"
            if base[len(p):] in DOT_VARIANTS:
                return "secret.variant." + p.replace("_", "-") + "." + base[len(p) + 1:]
    if any(s in low[:-1] for s in BROAD_SKIP) or ("vendor" in low and any(x in low for x in ("bundle", "cache"))):
        return None
    if "." not in base and BROAD_KEY.fullmatch(base):
        return "secret.pattern.ssh-key-basename"
    ext = base.rsplit(".", 1)[-1] if "." in base else ""
    return "secret.ext." + ext if ext in SECRET_EXT else None


def expand(s: str, cwd, env: dict) -> str:
    s = s.strip().strip("`")
    for name, val in env.items():
        s = s.replace("${" + name + "}", val).replace("$" + name, val) if val else s
    if s == "~" or s.startswith("~/"):
        s = (homes() or ["~"])[0] + s[1:]
    s = re.sub(r"^\$\{?HOME\}?(?=/|$)", lambda _: (homes() or ["$HOME"])[0], s)
    return s if os.path.isabs(s) else os.path.join(cwd or os.getcwd(), s)


def braces(s: str, depth: int = 3) -> list:
    m = re.search(r"\{([^{}]*,[^{}]*)\}", s)
    if not m or depth == 0:
        return [s]
    return [r for alt in m.group(1).split(",")[:16] for r in braces(s[:m.start()] + alt + s[m.end():], depth - 1)][:64]


def classify(raw: str, cwd, write: bool = False, env=None):
    """(regra, caminho) se `raw` é um caminho de segredo; None se não é, ou se não sei resolver (variável que não conheço)."""
    raw = (raw or "").strip()
    if not raw or re.match(r"[A-Za-z][\w+.-]*://", raw) or raw.startswith("-"):
        return None
    for cand in braces(expand(raw, cwd, env or {})):
        if "$" in cand or "`" in cand:
            continue  # variável que não conheço: não sei → não bloqueio (limite documentado)
        # vazio → o literal vale; falhou/ilegível (permissão, loop de link) → glob devolve [] e o literal vale
        paths = (sorted(glob.glob(cand))[:50] or [cand]) if re.search(r"[*?\[]", cand) else [cand]
        for p in paths:
            for form in (os.path.normpath(p), os.path.realpath(p)):
                r = match(form, write)
                if r and r.startswith(("secret.home.", "secret.cli.")) and "/" not in raw and not write and not os.path.lexists(form):
                    r = match(form, write, False)  # palavra solta que só cai na pasta do segredo por causa de um `cd` e não existe lá (`cd ~/.ssh; head -n 2 config`): vale só o NOME
                if r:
                    return r, form
    return None


def names_family(comp: str):
    """Um glob de Grep/Glob que NOMEIA a família de segredo (`.env*`, `*.pem`, `id_rsa*`, `credentials*`), sem caminho."""
    c = comp.casefold()
    lit = re.split(r"[*?\[{]", c)[0]
    if comp and not re.search(r"[*?\[{]", comp):
        return match("/x/" + comp, False)
    for b in (".env", ".npmrc", ".netrc", ".pypirc", ".git-credentials", "credentials") + KEY_PREFIXES:
        if lit.startswith(b) and not lit.startswith((".env.example", ".env.sample", ".envrc")):
            return "secret.glob." + b.strip(".")
    return "secret.glob.ext." + c.rsplit(".", 1)[-1] if re.fullmatch(r"[*?\w{},-]*\.(?:" + "|".join(sorted(SECRET_EXT)) + ")", c) else None


# --- Bash ---
class Op(str):
    """Operador do shell (`;` `&&` `|` `(` `>` `2>>` `<<<`…). Uma palavra entre aspas igual a `;` NÃO é operador: por isso o tipo."""


SEP_OPS = {";", "&&", "||", "|", "|&", "&", ";;", "(", ")"}
REDIR = re.compile(r"\d*(?:&?>>?|<|>&|<&|>\||<>)")
RESERVED = {"{", "}", "then", "do", "else", "elif", "fi", "done", "!", "if", "while", "until"}


def skip_subst(t: str, i: int) -> int:
    """t[i:] começa em `$(`, `${` ou crase: devolve o índice depois do fecho (aspas e parênteses aninhados respeitados; sem fecho = fim do texto)."""
    n = len(t)
    if t[i] == "`":
        j = i + 1
        while j < n and t[j] != "`":
            j += 2 if t[j] == "\\" else 1
        return min(j + 1, n)
    if t.startswith("${", i):
        j = t.find("}", i)
        return n if j < 0 else j + 1
    depth, j = 0, i + 1
    while j < n:
        c = t[j]
        if c == "\\":
            j += 2; continue
        if c == "'":
            j = t.find("'", j + 1); j = n if j < 0 else j + 1; continue
        if c == '"':
            j += 1
            while j < n and t[j] != '"':
                if t[j] == "\\":
                    j += 2
                elif (t[j] == "$" and t[j + 1:j + 2] in ("(", "{")) or t[j] == "`":
                    j = skip_subst(t, j)
                else:
                    j += 1
            j += 1; continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return n


def lex(text: str):
    """Texto -> (palavras e Op, heredocs). Um leitor só, com as regras de aspas do bash: comentário, `\\`, '…', "…" (só `\\$ \\` \\" \\\\` escapam), $'…',
    $( ) e crase ficam DENTRO da palavra, newline vira `;`, e o corpo de heredoc sai do fluxo: (corpo, palavras de quem o lê)."""
    toks, docs, pend, cur, word, i, n = [], [], [], [], False, 0, len(text)

    def flush():
        nonlocal cur, word
        if word:
            toks.append("".join(cur))
        cur, word = [], False

    def command_words(tail: str):
        k = len(toks)
        while k and not (isinstance(toks[k - 1], Op) and toks[k - 1] in SEP_OPS):
            k -= 1
        return [os.path.basename(str(t)) for t in toks[k:] if not isinstance(t, Op)] + [os.path.basename(w) for w in re.split(r"[\s;&|()<>]+", tail) if w]

    while i < n:
        c = text[i]
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
            if text[i + 1:i + 2] != "\n":
                cur.append(text[i + 1:i + 2]); word = True
            i += 2
        elif c == "'":
            j = text.find("'", i + 1); j = n if j < 0 else j
            cur.append(text[i + 1:j]); word = True; i = j + 1
        elif c == '"':
            i += 1; word = True
            while i < n and text[i] != '"':
                d = text[i]
                if d == "\\" and i + 1 < n:
                    e = text[i + 1]
                    cur.append(e if e in '$`"\\' else ("" if e == "\n" else "\\" + e)); i += 2
                elif (d == "$" and text[i + 1:i + 2] in ("(", "{")) or d == "`":
                    j = skip_subst(text, i); cur.append(text[i:j]); i = j
                else:
                    cur.append(d); i += 1
            i += 1
        elif c == "$" and text[i + 1:i + 2] == "'":
            i += 2; word = True
            while i < n and text[i] != "'":
                if text[i] == "\\" and i + 1 < n:
                    cur.append({"n": "\n", "t": "\t", "\\": "\\", "'": "'", '"': '"'}.get(text[i + 1], "\\" + text[i + 1])); i += 2
                else:
                    cur.append(text[i]); i += 1
            i += 1
        elif (c == "$" and text[i + 1:i + 2] in ("(", "{")) or c == "`":
            j = skip_subst(text, i); cur.append(text[i:j]); word = True; i = j
        elif c in ";&|()<>":
            pre = ""
            if c in "<>" and word and "".join(cur).isdigit():  # `2>`: o descritor faz parte do operador
                pre, cur, word = "".join(cur), [], False
            else:
                flush()
            op = re.match(r"<<<|<<-?|&&|\|\||\|&|;;|&>>|&>|>>|>&|<&|>\||<>|[;&|()<>]", text[i:]).group(0)
            i += len(op)
            if op in ("<<", "<<-"):
                m = re.match(r"[ \t]*(?:'([^']*)'|\"([^\"]*)\"|\\?([\w.-]+))", text[i:])
                if m:  # o delimitador não é palavra; quem lê o heredoc está antes ou depois dele, na mesma linha
                    eol = text.find("\n", i)
                    pend.append((m.group(1) or m.group(2) or m.group(3) or "", op == "<<-", command_words(text[i + m.end(): n if eol < 0 else eol])))
                    i += m.end(); continue
            toks.append(Op(pre + op))
        else:
            cur.append(c); word = True; i += 1
    flush()
    for delim, tabs, recv in pend:  # `cat <<EOF` sem newline depois: não há corpo
        docs.append(("", recv))
    return toks, docs


def substitutions(w: str):
    """Corpos de $( ) e crase dentro de UMA palavra."""
    i, out = 0, []
    while i < len(w):
        if (w[i] == "$" and w[i + 1:i + 2] == "(") or w[i] == "`":
            j = skip_subst(w, i)
            out.append(w[i + 2:j - 1] if w[i] == "$" else w[i + 1:j - 1] if w[j - 1:j] == "`" else w[i + 1:j]); i = j
        else:
            i += 1
    return out


def literals(code: str, cwd, env):
    for run in RUN.findall(code):
        hit = classify(run.strip("{}"), cwd, False, env)
        if hit:
            return hit
    return None


def cd_target(words: list, cwd, env: dict):
    """O diretório depois de um `cd`/`pushd` (assumo que rodou); None se a linha não é cd ou não sei o destino."""
    ws = [w for w in words if not (isinstance(w, str) and ASSIGN.match(w))]
    while ws and ws[0] in ("time", "command", "builtin", "!"):  # continuam sendo o cd do próprio shell (`timeout`, `env`, `nohup` rodariam um programa externo)
        ws = ws[1:]
    if not ws or os.path.basename(ws[0]) not in ("cd", "pushd"):
        return None
    args = [a for a in ws[1:] if a not in ("-L", "-P", "-e", "-@", "--")]
    if not args:
        return homes()[0] if homes() else None
    d = expand(args[0], cwd, env)
    return None if "$" in d or args[0] == "-" else os.path.normpath(d)


def scan_bash(cmd: str, cwd, depth: int = 0, env=None, strict: bool = False):
    env = dict(env or {})
    if depth > 6:
        return None
    toks, docs = lex(cmd)
    for body, recv in docs:
        hit = None  # corpo lido como DADO (cat, git commit -F -, tee…): o texto citar `.env` não é ler `.env`
        if any(w in SHELLS for w in recv):
            hit = scan_bash(body, cwd, depth + 1, env)
        if not hit and any(INTERP.fullmatch(w) for w in recv):
            hit = literals(body, cwd, env)
        if hit:
            return hit
    # a saída de um echo/ls vira operando de outro comando (`echo P | xargs cat`, `while read f`): nesses casos nenhum verbo é isento
    strict = strict or any(not isinstance(t, Op) and os.path.basename(t) in ("xargs", "parallel", "read", "mapfile", "readarray") for t in toks)
    cur, here, saved = [], cwd, []
    for t in toks + [Op(";")]:
        if isinstance(t, Op) and t in SEP_OPS:
            hit = one(cur, here, depth, env, strict)
            if hit:
                return hit
            here = cd_target(cur, here, env) or here
            if t == "(":
                saved.append(here)
            elif t == ")" and saved:
                here = saved.pop()
            cur = []
        else:
            cur.append(t)
    return None


def one(ws: list, cwd, depth: int, env: dict, strict: bool = False):
    words, redirs, here = [], [], []
    k = 0
    while k < len(ws):  # redirecionamento conta sempre, seja qual for o verbo: o operador e a palavra seguinte (o alvo)
        t = ws[k]
        if isinstance(t, Op):
            if REDIR.fullmatch(t) and k + 1 < len(ws):
                redirs.append((str(ws[k + 1]), ">" in t)); k += 2; continue
            if t == "<<<" and k + 1 < len(ws):
                here.append(str(ws[k + 1])); k += 2; continue
            k += 1; continue
        words.append(t); k += 1
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
        env[name] = expand(val, cwd, env) if val else ""
        i += 1
    ws = words[i:]
    if not ws:
        return None
    verb, args = os.path.basename(ws[0]), ws[1:]
    for w in ws:  # $( ) e crase dentro de uma palavra (`echo "$(cat ~/.ssh/id_rsa)"`) rodam MESMO que o verbo seja isento, e a saída é operando de outro comando
        for body in substitutions(w):
            hit = scan_bash(body, cwd, depth + 1, env, True)
            if hit:
                return hit
    skip = set()  # índices (em args) de palavras que são CÓDIGO e não caminho
    nest = next((k for k, w in enumerate(ws) if os.path.basename(w) in SHELLS or os.path.basename(w) == "eval" or INTERP.fullmatch(os.path.basename(w))), None)
    if nest is not None:  # o 1º shell/interpretador da linha, mesmo atrás de embrulho (`timeout 5 bash -c …`, `nohup sh -c …`, `env A=1 python3 -c …`)
        nv, nargs, code = os.path.basename(ws[nest]), ws[nest + 1:], None
        if nv == "eval":  # eval junta os argumentos num texto só
            code, skip = " ".join(nargs), set(range(nest, len(args)))
        else:
            for k, a in enumerate(nargs):
                if a in CODE_FLAGS or re.fullmatch(r"-[a-zA-Z]*[ce]", a):
                    code, skip = (nargs[k + 1] if k + 1 < len(nargs) else None), {nest + k + 1}
                    break
            if code is None and nv.endswith("awk"):
                k = next((k for k, a in enumerate(nargs) if not a.startswith("-")), None)
                code, skip = (nargs[k], {nest + k}) if k is not None else (None, skip)
            if code is None and here:
                code = here[0]
        if code:
            hit = scan_bash(code, cwd, depth + 1, env) if nv in SHELLS or nv == "eval" else literals(code, cwd, env)
            if hit:
                return hit
    if not strict and (verb in EXEMPT or (verb == "git" and next((a for a in args if not a.startswith("-")), "") in GIT_EXEMPT)):
        return None
    if verb in GREPS:  # o 1º operando é o padrão (a menos que haja -e/--regexp): citar `.env` num padrão não é ler `.env`
        pat_done = any(a in ("-e", "--regexp") or a.startswith("--regexp=") for a in args)
        for k, a in enumerate(args):
            if a in ("-e", "--regexp", "-A", "-B", "-C", "-m", "-g", "--glob", "-t", "--type", "--max-count", "--include", "--exclude", "--exclude-dir"):
                skip.add(k + 1)
            elif a.startswith("--regexp="):
                skip.add(k)
            elif not a.startswith("-") and not pat_done and (k - 1) not in skip and (k == 0 or args[k - 1] not in ("-f", "--file")):
                skip.add(k); pat_done = True
    for k, a in enumerate(args):
        if k in skip or (verb == "find" and k and args[k - 1] in FIND_VAL):
            continue
        cand = (a.split("=", 1)[1] if re.match(r"-{0,2}[A-Za-z_][\w-]*=", a) else a).lstrip("@")
        if cand.startswith("-"):
            continue
        hit = classify(cand, cwd, False, env)
        if not hit and re.fullmatch(r"[^\s:/][^\s:]*:[^\s]+", cand):  # `scp host:~/.ssh/id_rsa`: o que vem depois do `:` também é caminho (e `doc: id_rsa` não é)
            hit = classify(cand.split(":", 1)[1], cwd, False, env)
        if hit:
            return hit
    return None


# --- decisão ---
def glob_dir(pattern: str, root):
    """Diretório fixo de um pattern de Glob (tudo antes do 1º curinga) e o último componente."""
    p = os.path.expanduser(pattern) if pattern.startswith("~") else pattern
    fixed = re.split(r"[*?\[{]", p)[0]
    d = fixed if fixed.endswith("/") else os.path.dirname(fixed)
    return (d or None), p.rsplit("/", 1)[-1]


def decide(inp: dict):
    """None = liberado; (regra, alvo, operação) = bloqueado."""
    tool, ti, cwd = inp.get("tool_name"), inp.get("tool_input") or {}, inp.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or None
    if tool == "Bash":
        hit = scan_bash(str(ti.get("command") or ""), cwd)
        return (hit[0], hit[1], "comando Bash") if hit else None
    if tool in FILE_TOOLS:
        # vazio → sem caminho no pedido = nada a conferir (a própria ferramenta recusa); falhou → classify nunca levanta por texto
        hit = classify(str(ti.get(FILE_TOOLS[tool]) or ""), cwd, tool in WRITE_TOOLS)
        return (hit[0], hit[1], ("escrita" if tool in WRITE_TOOLS else "leitura") + " (" + tool + ")") if hit else None
    if tool in ("Grep", "Glob"):
        hit = classify(str(ti.get("path") or ""), cwd)
        pats = [str(ti.get("glob") or "")] if tool == "Grep" else [str(ti.get("pattern") or "")]
        for pat in pats:
            if hit or not pat:
                continue
            d, comp = glob_dir(pat, cwd) if tool == "Glob" else (None, pat.rsplit("/", 1)[-1])
            hit = (classify(d, cwd) if d else None) or ((names_family(comp), pat) if names_family(comp) else None)
        return (hit[0], hit[1], tool) if hit else None
    return None


def message(hit) -> str:
    rule, target, op = hit
    return ("[HOOK BLOCK: secret-read-guard] NÃO É CANCELAMENTO DO USUÁRIO — política automática de proteção de segredos.\n"
            f"BLOQUEADO: {op} em segredo ({rule}).\nAlvo: {target}\n"
            "Segredo não passa pelo agente: chave, token e senha vêm do cofre (`secret <item>` dentro do comando que os usa), nunca lendo o arquivo. "
            "Arquivo de exemplo (`.env.example`) e chave pública (`*.pub`) seguem liberados. Se a tarefa exige mesmo este arquivo, devolva a bead ao Mayor.\n")


def selfcheck() -> int:
    ok = True
    for tool, ti, want in (("Read", {"file_path": "~/.ssh/id_ed25519"}, True), ("Read", {"file_path": "~/.ssh/config"}, False), ("Write", {"file_path": "~/.ssh/authorized_keys"}, True),
                           ("Read", {"file_path": "/work/.env"}, True), ("Read", {"file_path": "/work/.env.example"}, False), ("Bash", {"command": "cat ~/.aws/credentials"}, True),
                           ("Bash", {"command": "echo .env"}, False), ("Glob", {"pattern": "**/.env"}, True), ("Grep", {"pattern": "x", "path": "/work"}, False)):
        got = decide({"tool_name": tool, "tool_input": ti, "cwd": "/work"}) is not None
        if got != want:
            ok = False
            print(f"selfcheck: {tool} {ti}: bloqueou={got}, deveria={want}", file=sys.stderr)
    print("selfcheck: " + ("ok" if ok else "FALHOU"))
    return 0 if ok else 1


def main(argv: list) -> int:
    if argv[1:2] == ["--selfcheck"]:
        return selfcheck()
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
    sys.exit(main(sys.argv))
