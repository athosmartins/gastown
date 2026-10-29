#!/usr/bin/env python3
r"""rm-target-guard.py — hook PreToolUse (Bash) que recusa REMOVER o que não é descartável, julgando o ALVO e não a grafia do comando (ga-id0im4e).
A regra `Bash(rm -rf:*)` casa TEXTO e só barrou 2 de 7 grafias (ga-nkfwixz, guard-oracle-diff.md §3): `rm -fr`, `rm -r -f`, `rm --recursive --force`, `/bin/rm -rf`, `subprocess.run(['rm','-rf',X])` rodaram.
DORMENTE: nenhum settings.json chama este arquivo; ligar é decisão do Mayor (ATIVAÇÃO). Um agente (ou texto injetado que ele leu) não apaga dado do Dolt, `.git`, o HOME, a raiz de um repo nem a pasta de
/tmp que outras sessões usam, seja qual for a ordem das flags ou o embrulho (`env`, `sudo`, `timeout`, `bash -c`, `eval`, `find -delete`, `xargs`, `python -c`); `rm -rf /tmp/x` e `rm -rf build` passam. Sai 2 em qualquer modo.
COMO DECIDE: o texto é lido como o bash lê (aspas, `$'…'`, heredoc, `$( )`, `<( )`, crase, `cd`, `env -C`, `sudo -D`, chave `{a,b}` `{1..9}` na palavra do verbo e nas flags, opção do `rm` que não está escrita (`$F`, `${F:--rf}`, `$( )`, `{-rf,x}`, `rm *` com um arquivo `-rf`: o que não sei vale "talvez -r" para os operandos que sei), e variável com o escopo do bash: `V=x cmd`, subshell, pipe,
  `&&`, função, laço, `read`, `printf -v`, `+=`, `${V:-x}`, `C='rm -rf x'; $C`), os embrulhos saem, as opções do `rm`/`unlink`/`rmdir`/`shred`/`rimraf` são normalizadas e os OPERANDOS (`~`, `$HOME`, cwd, chave, glob que EXISTE)
  são julgados em duas formas, o texto e o `realpath`: vale a pior. Proibido: componente `.dolt` `.dolt-data` `.beads` `.git` `.gc-worktrees` `crew`, `/` e pasta de 1º nível, HOME e ancestrais, pasta DIRETA do HOME, `~/Library/CloudStorage`,
  `~/gt/*/shared/data` (e, numa remoção recursiva, `~/gt/<rig>` e `~/gt/<rig>/shared`), a raiz de /tmp e as pastas compartilhadas (`claude-<uid>`, `claude-<uid>/<projeto>`, `tmux-*`), pasta de sistema, raiz de repo git ou pasta que guarda um
  até 2 níveis abaixo, curinga que esvazia uma pasta que guarda repo. `find -delete|-exec rm` julga as raízes; `xargs rm`, alvo que não resolvo (`$VAR`, `$( )`) ou verbo que não resolvo com flag recursiva = bloqueado. Só `&&` fixa o cwd depois de um `cd`.
  Texto que o leitor não consegue fechar (aspas, `$( )`, crase, `${ }` ou heredoc sem fecho) e que cita remoção = bloqueado (`rm.unparsed`): perdeu o compasso do bash, e o que não dá para conferir não vira "liberado". Mesma regra para variável usada como comando (`C='rm -rf x $(date)'; eval "$C"`): o texto que ela recebeu cita remoção e não resolve.
CÓDIGOS: 0 liberado · 2 bloqueado. Erro do guarda num pedido Bash, texto acima de MAX_CMD (256 KB) ou prazo LIMIT (8 s) estourado = bloqueado. Travar o python NÃO sai 2 (o executor mata e o pedido segue): o prazo é cooperativo.
ATIVAÇÃO (do Mayor; agente não edita o settings do usuário): PreToolUse, matcher "Bash", UM hook `python3 -I <caminho>/rm-target-guard.py || exit 2` (o `|| exit 2` é OBRIGATÓRIO: cobre python que cai, some ou sai 1 ao escrever o aviso). O matcher é só Bash: tool que roda script de shell (Monitor) não é julgada. Para SUBSTITUIR a regra de prefixo,
  tire `Bash(rm -rf:*)` do `deny` (nó e overlays `pool-*`) ou do `ask` (mini: travou pool 54-97 min, ga-gkap9p) na MESMA camada. Primeiro o nó Hetzner com 48 h de observação; no mini só depois de refazer o replay das transcrições com 0 falso positivo.
MEDIDO (29/10): selftest com 708 linhas de tabela e 191 mutantes mortos; fuzzer contra o bash REAL do nó (5.2.21) com 6 sementes de 1.500, ~8.600 comandos válidos, 0 bypass; as linhas de opção não escrita contra o bash 3.2.57 do mini e o 5.3 do brew, 0 divergência. "0 bypass" vale para as sementes rodadas: o fuzzer não é prova. Replay A/B (guard
  anterior x este) de 408 pedidos Bash reais das transcrições locais do mini: 0 bloqueios novos e 0 perdidos, pior caso 0,01 s; mas 175 deles já eram bloqueados (112 `rm.worktrees`: script Python por heredoc dentro de `.gc-worktrees`): medir antes de ligar no mini. Replay de 31.820 pedidos do nó, de versão anterior. Custo ~50 ms por chamada.
LIMITES (trava contra engano, não sandbox): não vejo script que o comando executa (`bash x.sh`, `source`), alias/função de fora, caminho montado em pedaços, `rsync --delete`, `git clean`, `mv x /dev/null`, `git -c alias.x='!rm …'`, nem executor que
  recebe o rm como texto (`uv run python -c`, `tmux send-keys`, `at`); remoção NÃO recursiva de alvo desconhecido (`rm -f "$f"`) passa; `rm -rf *` em pasta direta do HOME ou de /tmp compartilhada julga cada achado, não a pasta (como o safe-clean). `D=(…)`, `${V^^}`, `${V:1:2}`, `${!V}`, `$((…))` valem "não sei"; chave até 16 alternativas, 3 níveis e 64 saídas.
  Falsos positivos (lado fechado): `rm -rf "$VAR"`, `.git` de cópia em scratch, `find -name '*.lock'` num work tree, script Python com API de remoção e caminho protegido, apóstrofo solto em comentário dentro de `$( )` junto de texto com rm. Selftest: rm-target-guard.selftest.sh [N] (RMTG_SEED).
"""
from __future__ import annotations

import glob
import itertools
import json
import os
import re
import sys
import time
import unicodedata

UNK = "\x00"  # "não sei": pedaço de caminho que o guarda não resolve (variável solta, substituição, ~usuário)
MAX_CMD = 262144  # acima disto o leitor não roda e o pedido é bloqueado: texto que não dá para conferir não vira "liberado"
GLOB_MAX = 20000  # curinga com mais achados que isto: o resto vale como alvo que não conheço
LS_BUDGET = 20000  # entradas de pasta lidas por julgamento (2 níveis); estourou = a pasta vale como se guardasse um repo
LIMIT = 8  # segundos para julgar um pedido; passou disto vale bloqueado (hook que estoura o tempo do harness falha ABERTO)
DEADLINE = float("inf")
ST: dict = {"raw": {}, "seen": {}, "late": False, "again": False, "funcs": set(), "fnvals": {}, "fn": 0, "nref": False, "open": False}  # estado de UM pedido (decide o zera): texto recebido por cada variável (raw), valores já atribuídos, se há laço/função (2º passo), funções definidas, o que o corpo delas atribui, corpo de função aberto, nameref declarado, fecho que o leitor não achou
RM_TEXT = re.compile(r"(?<![\w.-])(?:rm|unlink|rmdir|shred|rimraf)(?![\w-])|-delete|rmtree")
RM_VERBS = {"rm", "unlink", "rmdir", "shred", "rimraf"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "ash", "csh", "tcsh", "fish", "mksh", "yash", "posh", "rbash", "pdksh", "oksh"}
INTERP = re.compile(r"(?:python[\d.]*|pypy[\d.]*|node(?:js)?|perl|ruby|php|lua|luajit|deno|bun|awk|gawk|mawk|nawk|tclsh|wish|Rscript|julia|osascript|jshell|groovy)")
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "{", "}", "!", "coproc", "function"}
OPAQUE = {"chrt", "taskset", "parallel", "su", "runuser", "script", "trap", "watch", "unshare", "nsenter", "chroot", "setpriv", "numactl", "caffeinate", "unbuffer", "ssh"}
WRAP = {"env": ("-u -C -S --unset --chdir --split-string", 0), "command": ("", 0), "builtin": ("", 0), "exec": ("-a", 0), "nohup": ("", 0), "time": ("-f -o --format --output", 0),
        "timeout": ("-s -k --signal --kill-after", 1), "nice": ("-n --adjustment", 0), "ionice": ("-c -n -p --class --classdata", 0), "setsid": ("", 0), "stdbuf": ("-i -o -e", 0),
        "sudo": ("-u -g -C -D -h -p -r -t -T -U --user --group --chdir", 0), "doas": ("-u -C", 0), "flock": ("-w -E --timeout", 1), "busybox": ("", 0), "toybox": ("", 0), "npx": ("-p -c --package", 0),
        "strace": ("-o -e -p -s -u -E -a -b -I -O -P -X", 0), "ltrace": ("-o -e -p -s -u -a -b -I -n", 0)}
XARGS_VAL = {"-I", "-J", "-S", "-R", "-n", "-P", "-L", "-d", "-E", "-s", "-a", "--max-args", "--max-procs", "--max-lines", "--delimiter", "--eof", "--max-chars", "--arg-file", "--replace"}
SELECT = {"-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-regex", "-iregex", "-lname", "-ilname"}  # testes de NOME: só eles filtram de verdade (-mtime, -size… casam quase tudo)
ASSIGN = re.compile(r"([A-Za-z_]\w*)(\+?)=")
VAR = re.compile(r"\$(?:(\w+)|\{(\w+)(?:(:?[-=+]|%%?|##?|//?)((?:[^{}]|\{[^{}]*\})*))?\})")  # $N, ${N} e ${N<operador>palavra}; a palavra aceita 1 nível de chave (`${U:-${HOME}/x}`, `${U:-x{a..a}}`)
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
    "rm.cloud": "~/Library/CloudStorage: documentos pessoais do Athos", "rm.rig-data": "~/gt/<rig>/shared/data (dados de produção) e as duas pastas que o levam junto, ~/gt/<rig> e ~/gt/<rig>/shared, removidas por inteiro", "rm.system": "pasta de sistema",
    "rm.shared-tmp": "pasta de /tmp compartilhada com outras sessões (a raiz, claude-<uid>, claude-<uid>/<projeto>, tmux-*)", "rm.repo-root": "raiz de repo git (ou pasta que guarda um): trabalho sem entregar",
    "rm.mass": "curinga que esvazia uma pasta que guarda repo (rm -rf *)", "rm.target-unknown": "alvo que o guarda não consegue resolver (variável solta, substituição) numa remoção recursiva",
    "rm.too-deep": "comando aninhado fundo demais para conferir", "rm.too-big": "comando grande demais para conferir",
    "rm.unparsed": "aspas, $( ), crase, ${ } ou heredoc sem fecho e o texto cita remoção: o leitor perdeu o compasso do bash e não dá para conferir"}
ANSI = re.compile(r"\\(x[0-9a-fA-F]{1,2}|[0-7]{1,3}|u[0-9a-fA-F]{1,4}|U[0-9a-fA-F]{1,8}|c.|.)", re.S)
LIT = re.compile(r"""'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)\"""", re.S)
ARGV = re.compile(r"""\[\s*['"](?:[^'"\n]*/)?(rm|unlink|rmdir|shred|rimraf)['"]\s*,([^\]]*)\]|['"](?:[^'"\n]*/)?(rm|unlink|rmdir|shred|rimraf)['"]\s*,\s*\[([^\]]*)\]""")
ELEM = re.compile(r"""\s*(?:'(?P<s>(?:[^'\\]|\\.)*)'|"(?P<d>(?:[^"\\]|\\.)*)"|(?P<e>[^,\s][^,]*))\s*(?:,|$)""")  # um elemento de lista de argv: literal ou expressão
# nomes de API de remoção (sem as palavras genéricas remove/delete: scripts de edição as citam o tempo todo): em qualquer parte do código ligam a leitura dos literais de caminho
NAMES = r"rmtree|remove_tree|rimraf(?:Sync)?|rm_rf?\b|rmSync|rmdirSync|unlinkSync|removedirs|os\.(?:remove|unlink|rmdir)\b|\.(?:rm|rmdir|unlink)(?=\s*\()|FileUtils\.(?:rm|remove)\w*|File\.delete|Dir\.rmdir|(?<![\w.])(?:unlink|rmdir|rm)(?=\s*\()"
DELAPI = re.compile(NAMES)
DELREC = re.compile(r"rmtree|remove_tree|remove_dir|remove_entry|rimraf|rm_rf?\b|removedirs|rmSync|recursive")  # a API que apaga pasta inteira; `os.remove`/`unlink` apagam um arquivo
DELCALL = re.compile("(?:" + NAMES + r")\s*\(?\s*['\"]([^'\"\n]+)['\"]")  # o literal passado DIRETO à API: `rmtree('gt-remote')`
GITNAMES = re.compile(r"\.git|objects|refs|head|pack|index|config|hooks|logs|info|description|lock|sample|idx|[0-9a-f]{6,}", re.I)  # nomes de dentro de um .git: um filtro que os casa apaga história

def ansi(body: str) -> str:
    """Conteúdo de $'…' como o bash o decodifica (`$'\\x72m'` é `rm`)."""
    def one(m):
        e = m.group(1)
        if e[0] in "xuU": return chr(min(int(e[1:], 16), 0x10FFFF))
        if e[0].isdigit(): return chr(int(e, 8) & 0xFF)
        return chr(ord(e[1]) & 0x1F) if e[0] == "c" and len(e) > 1 else {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v"}.get(e, e)
    return ANSI.sub(one, body)

def home() -> str:
    # vazio → HOME ausente ou vazio cai no expanduser; falhou → expanduser devolve o texto como veio e nenhum caminho começa com ele
    return os.path.normpath(os.environ.get("HOME") or os.path.expanduser("~"))

def tilde(s: str) -> str:
    """`~` e `~/x` viram o HOME; `~usuário` não sei resolver (UNK)."""
    return home() + s[1:] if s == "~" or s.startswith("~/") else (UNK + s if s.startswith("~") else s)

def param(v: str, op: str, w: str) -> list:
    """Valores de `${N<op>w}` com N valendo v: padrão (`:-` `-` `:=` `=`), alternativo (`:+` `+`), corte (`%` `%%` `#` `##`) e troca (`/` `//`). v, palavra com `[ ]` ou operador que não sei vale "não sei"."""
    c, k = op[0] == ":", op[-1]
    if k in "-=+": return ([v, w] if k != "+" else [w, ""]) if UNK in v else [(w if c and v == "" else v) if k != "+" else (w if v or not c else "")]  # `:` conta o vazio como ausente
    g = lambda q: "".join(".*" if x == "*" else "." if x == "?" else re.escape(x) for x in q)  # noqa: E731
    pat, _, rep = w.partition("/")
    if UNK in v + w or "[" in w or (k == "/" and (not pat or pat[0] in "#%")) or len(v) > 256 or w.count("*") > 2: return [UNK]  # valor longo ou muitos `*`: o regex recuaria por tempo exponencial, fora do prazo cooperativo; "não sei" bloqueia a recursiva
    if k == "/": return [re.sub(g(pat), lambda _: rep, v, count=0 if op == "//" else 1)]
    r = range(len(v) + 1)
    if k == "%": return [next((v[:i] for i in (reversed(r) if op == "%" else r) if re.fullmatch(g(w), v[i:])), v)]
    return [next((v[i:] for i in (r if op == "#" else reversed(r)) if re.fullmatch(g(w), v[:i])), v)]

def expand(s: str, cwd, env: dict) -> list:
    """Candidatos de uma palavra depois de $VAR, ${VAR}, $(pwd) e $(mktemp…): lista (a variável de um `for` tem vários valores); o que não sei vira UNK."""
    s = re.sub(r"\$\(\s*pwd\s*\)|`\s*pwd\s*`", "$PWD", s)
    s = re.sub(r"\$\(\s*mktemp\b[^()`]*\)|`\s*mktemp\b[^`]*`", "/tmp/mktemp.x", s)
    outs = [s]
    for _ in range(4):
        nxt, more = [], False
        for t in outs:
            m = VAR.search(t)
            if m is None: nxt.append(t); continue
            more, name = True, m.group(1) or m.group(2)
            vals = env[name] if name in env else [home()] if name == "HOME" else [cwd] if name == "PWD" and cwd else [" "] if name == "IFS" else [UNK]
            nxt += [t[:m.start()] + x + t[m.end():] for v in vals for w in (expand(re.sub("[\"']", "", m.group(4)), cwd, env) if m.group(3) else [""]) for x in (param(v, m.group(3), w) if m.group(3) else [v])]  # a palavra do operador também se expande, sem as aspas que o bash tira (`${D%$E}`, `${D:+"$HOME/x"}`)
        outs = nxt[:64]
        if not more: break
    return [UNK if (UNK in t or re.search(r"[$`]", t)) else t for t in outs]

SEQ = re.compile(r"\{(-?\d+|[A-Za-z])\.\.(-?\d+|[A-Za-z])(?:\.\.(-?\d+))?\}")

def span(a: str, b: str, step) -> list:
    """Valores de `{a..b}` / `{a..b..passo}` (número, com zeros à esquerda se um extremo os tem, ou letra); mais de 16 = [UNK] (não sei)."""
    num, k = a.lstrip("-").isdigit(), abs(int(step or 1)) or 1
    x, y = (int(a), int(b)) if num else (ord(a), ord(b))
    rng = range(x, y + 1, k) if x <= y else range(x, y - 1, -k)
    if len(rng) > 16: return [UNK]
    w = max(len(a), len(b)) if num and any(len(t.lstrip("-")) > 1 and t.lstrip("-")[0] == "0" for t in (a, b)) else 0
    return [str(v).zfill(w) if num else chr(v) for v in rng]

def braces(s: str, depth: int = 3) -> list:
    """Expansão de chave: `{a,b}` e sequência (`{1..3}`, `{a..e}`). Passou do teto (16 alternativas, 3 níveis, 64 resultados) = [UNK + s] (não sei), nunca corta em silêncio."""
    m = next((q for q in SEQ.finditer(s) if q.group(1).lstrip("-").isdigit() == q.group(2).lstrip("-").isdigit()), None)  # `{1..a}` o bash não expande
    alts = span(*m.groups()) if m else None
    if m is None:
        m = re.search(r"\{([^{}]*,[^{}]*)\}", s)
        alts = m.group(1).split(",") if m else None
    if m is None: return [s]
    out = [r for alt in alts for r in braces(s[:m.start()] + alt + s[m.end():], depth - 1)] if depth and len(alts) <= 16 else None
    if out is None or len(out) > 64: return [UNK + s]
    return out

def setvar(env: dict, name: str, vals: list, strong: bool):
    """Atribui `name`. Forte (a linha sempre roda): troca o valor. Fraca (pode não rodar: `&&`, ramo, `case`, corpo de função): soma ao que havia, e nome que não conheço conta como "não sei".
    Mais de 16 valores = "não sei", nunca corta. ST["seen"] guarda todo valor já atribuído: o 2º passo o usa no corpo de laço e de função."""
    ST["seen"].setdefault(name, set()).update(vals)
    if ST["fn"]: ST["fnvals"].setdefault(name, set()).update(vals)
    new = list(vals) if strong else list(dict.fromkeys(env.get(name, [UNK]) + list(vals)))
    env[name] = new if len(new) <= 16 else [UNK]

def assign(w: str, env: dict, cwd, strong: bool):
    """`NOME=v` e `NOME+=v` (anexa ao que havia; nome que não conheço vira "não sei")."""
    m = ASSIGN.match(w)
    ST["raw"].setdefault(m.group(1), set()).add(w[m.end():])  # o texto recebido, antes de expandir: o que `eval "$NOME"` leria se o valor não resolver
    vals = [tilde(x) for x in expand(("${%s}" % m.group(1) if m.group(2) else "") + w[m.end():], cwd, env)]
    if m.group(2) and UNK in "".join(env.get(m.group(1), [UNK])): vals += [tilde(x) for x in expand(w[m.end():], cwd, env)]  # `+=` num nome que não sei (pode estar vazio): `D+=/etc` vira `/etc` ou o que o ambiente trouxe + `/etc`
    setvar(env, m.group(1), vals, strong)
    for k in [k for k in env if ST["nref"] and k != m.group(1)]:  # com um nameref declarado `r=x` pode gravar em qualquer outra variável
        setvar(env, k, [UNK], True)

def merge(env: dict, snap: dict, *alts: dict):
    """Fim de subshell, ramo de if ou corpo de laço: `env` volta ao que era em `snap` e o que ele (e os outros ramos, `alts`) mudou entra como "talvez"."""
    seen = alts + (dict(env),)
    env.clear()
    env.update(snap)
    for a in seen:
        for k, v in a.items():
            if snap.get(k) != v: setvar(env, k, v, False)

def pieces(raw: str, cwd, env: dict) -> list:
    """Candidatos de uma palavra: o texto expandido E, se havia `$`, cada pedaço que o shell tira dele sem aspas (separador: espaço e o IFS que o texto atribuiu; IFS que não sei = qualquer pontuação)."""
    ts, ifs = expand(raw, cwd, env), "".join(env.get("IFS", [" "]))
    if "$" not in raw or not ifs: return ts
    sep = re.compile(r"[^\w./~-]+" if UNK in ifs else "[\\s" + re.escape(ifs) + "]+")
    return ts + [q for t in ts if UNK not in t for q in sep.split(t) if q and q != t]

def wild(env: dict):
    """Nome calculado (`read "$n"`, `eval "$n=x"`), nameref ou `source`: qualquer variável pode ter mudado, então todas viram "não sei"."""
    for k in list(env): setvar(env, k, [UNK], True)

def widen(env: dict):
    """2º passo: o corpo de um laço ou de uma função pode rodar depois de QUALQUER atribuição do texto, então no topo dele cada valor já atribuído vale como "talvez"."""
    for k, v in list(ST["seen"].items()) if ST["again"] else (): setvar(env, k, sorted(v), False)

def candidates(raw: str, cwds: list, env: dict) -> list:
    """[(caminho absoluto | None = não sei, padrão com curinga | None)] que a palavra pode ser: ~, $VAR, chave, cwd e glob que EXISTE resolvidos."""
    out = []
    for t in pieces(raw, cwds[0], env):  # as aspas já se perderam: vale o valor inteiro E cada pedaço dele
        t = tilde(t)
        bs = [t] if UNK in t else [tilde(x) for x in braces(t)]  # o bash expande a chave ANTES do til: `{~/gt,x}` entrega ~/gt como HOME/gt
        if UNK not in t and t not in bs:  # o que veio de variável não passa por chave (`T='x{a,b}'; rm $T`, `C='rm x{k..k}'; $C`): o rm recebe o texto como está; o digitado passa. Sem saber qual, valem os dois
            bs = bs + [t]
        for b in bs:
            for cwd in ([None] if os.path.isabs(b) else cwds):
                if UNK in b or (cwd is None and not os.path.isabs(b)):
                    out.append((None, None))
                    continue
                p = os.path.normpath(b if os.path.isabs(b) else os.path.join(cwd, b))
                if re.search(r"[*?\[]", p):
                    # vazio → glob sem resultado: o rm recebe o texto como veio e o padrão vale; falhou/ilegível (permissão, laço de link) → glob devolve [] e o padrão vale
                    if sum(bool(re.search(r"[*?\[]", c)) for c in p.split("/")) > 2:  # curinga fundo (/*/*/*/x) percorre o disco inteiro: não expando; o TEXTO do padrão ainda é julgado e, numa remoção recursiva, vale alvo que não conheço
                        out += [(p, p), (None, None)]
                        continue
                    hits = sorted(itertools.islice(glob.iglob(p), GLOB_MAX + 1))
                    out += [(h, p) for h in hits[:GLOB_MAX] or [p]] + ([(None, None)] if len(hits) > GLOB_MAX else [])  # achados além do teto: não os vi, valem como alvo que não conheço
                else: out.append((p, None))
    return out

def present(p: str) -> bool:
    # vazio → não existe (FileNotFoundError, NotADirectoryError): sem marca; falhou/ilegível (sem permissão, laço de link, nome inválido) → conta como existente: o estado inerte é "tem marca"
    try: os.lstat(p); return True
    except (FileNotFoundError, NotADirectoryError): return False
    except (OSError, ValueError): return True

def ls(d: str, bud: list) -> list:
    # vazio → []; sumiu ou não é pasta → [] (não há o que o rm apague); falhou/ilegível (sem permissão de listar) → OverflowError, que quem chama trata como "guarda", igual a passar do orçamento
    try: names = sorted(os.listdir(d))
    except (FileNotFoundError, NotADirectoryError): return []
    except (OSError, ValueError): raise OverflowError(d)
    bud[0] -= len(names)
    if bud[0] < 0: raise OverflowError(d)
    return names

def marked(d: str, git: bool = True) -> bool:
    # vazio → sem marca; falhou/ilegível → present diz "existe" (a pasta vale com marca); isfile/isdir de HEAD/objects/refs dizem não e só o repo bare passa sem marca. git=False: só dado (Dolt, beads, repo bare), não a árvore de trabalho de um clone
    j = lambda n: os.path.join(d, n)  # noqa: E731
    return any(present(j(m)) for m in ((".git",) if git else ()) + (".dolt", ".beads")) or (os.path.isfile(j("HEAD")) and os.path.isdir(j("objects")) and os.path.isdir(j("refs")))

def holds(d: str, git: bool = True) -> bool:
    """`d` é raiz de repo git (worktree ou bare), .dolt ou .beads, ou guarda um até 2 níveis abaixo (`~/gt-remote/git/gascity` guarda repo.git e wt/<sessão>)? Pasta grande demais para ler
    (LS_BUDGET entradas) vale como "guarda": o estado inerte, nunca "não vi nada"."""
    real = lambda x: os.path.isdir(x) and not os.path.islink(x)  # noqa: E731
    if not os.path.isdir(d): return False
    if marked(d, git): return True
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
    if len(parts) <= 1: return "rm.root"
    hps = [[unicodedata.normalize("NFC", x).casefold() for x in h.split("/") if x] for h in {home(), os.path.realpath(home())}]
    if any(low == hp[:len(low)] for hp in hps): return "rm.home"
    k = next((len(hp) for hp in hps if low[:len(hp)] == hp), None)
    rel, relp = (low[k:], parts[k:]) if k is not None else (None, None)
    if rel is not None and rel[:2] == ["library", "cloudstorage"]: return "rm.cloud"
    if rel is not None and rel[:1] == ["gt"] and ((len(rel) >= 4 and rel[2:4] == ["shared", "data"]) or (rec and (len(rel) == 2 or (len(rel) == 3 and rel[2] == "shared")))):  # os 2 ancestrais levam o dado junto, com ou sem filtro de nome
        return "rm.rig-data"
    if any(c in ALLOW_COMP for c in parts) or (f.endswith(".pyc") and not os.path.isdir(f)) or (relp is not None and any(relp[:len(a)] == list(a) for a in ALLOW_HOME)): return None
    if rel is not None:  # o HOME vence o scratch: um HOME dentro de /tmp (teste) continua sendo HOME
        # vazio → o caminho não existe (typo ou criado antes na mesma linha): vale como pasta; falhou/ilegível → lexists diz não e vale como pasta
        if len(rel) == 1 and rec and not selective and not (os.path.lexists(f) and not os.path.isdir(f)):
            return "rm.home-child"
    else:
        for root in SCRATCH:
            rp = [x for x in root.split("/") if x]
            if low[:len(rp)] == rp:
                rest = low[len(rp):]
                dir_ = os.path.isdir(f) or (rec and not os.path.lexists(f))  # arquivo existente nessas pastas não derruba a sessão de ninguém; pasta, ou nome que não existe numa remoção recursiva, sim
                return "rm.shared-tmp" if (not rest or rest[0].startswith("tmux-") or (dir_ and ((rest[0].startswith("claude-") and len(rest) < 3) or (rp[-1] == "folders" and len(rest) < 4)))) else None
        if low[0] in SYSTEM: return "rm.system"
    if selective:  # filtro de nome: o que vale é só a regra absoluta e dado (Dolt, beads, repo bare) embaixo da raiz; árvore de trabalho com `.git` pode (`find . -name '*.pyc' -delete`)
        return "rm.repo-root" if holds(f, False) or (holds(f) and any(GITNAMES.search(p) for p in selective)) else None
    if pat and MASS.fullmatch(pat.rsplit("/", 1)[-1]) and holds(os.path.dirname(pat)): return "rm.mass"
    return "rm.repo-root" if holds(f) else None

def classify(p: str, rec: bool, selective: bool = False, pat=None):
    """Regra que proíbe remover `p` (absoluto) ou None. Julga o texto E o caminho real (link simbólico): qualquer um proibido vale."""
    for f in dict.fromkeys((os.path.normpath(p), os.path.realpath(p))):
        r = judge(f, rec, selective, pat)
        if r: return r
    return None

def check(ops: list, rec: bool, selective, cwds: list, env: dict, lenient: bool = False, maybe: bool = False):
    """(regra, alvo) do 1º operando proibido; operando que não resolvo só barra numa remoção recursiva. lenient (literal pelado de código inline): só vale o que existe e o desconhecido não barra. maybe (algo que não sei pode ser `-r`): os operandos que sei valem como recursivos, os que não sei seguem a regra de antes."""
    for raw in ops:
        for p, pat in candidates(raw, cwds, env):
            if time.monotonic() > DEADLINE: return "rm.too-big", "tempo esgotado"
            if p is None:
                if rec and not lenient: return "rm.target-unknown", raw.replace(UNK, "?")
                continue
            if lenient and not os.path.lexists(p):  # literal pelado que não existe quase nunca é caminho: só vale o que existe
                continue
            r = classify(p, rec or maybe, selective, pat)
            if r: return r, (pat if r == "rm.mass" else p)
    return None

def rm_args(verb: str, args: list):
    """(operandos, recursivo): opção agrupada (-fr, -rfv), longa por prefixo único (--recur), `--` e opção DEPOIS do operando (GNU); só o `rm` (e o `rimraf`) é recursivo."""
    ops, rec, end = [], False, False
    for a in args:
        if end or a == "-" or not a.startswith("-"):
            ops.append(a)
        elif a == "--":
            end = True
        elif a.startswith("--"):
            n = a[2:].split("=", 1)[0]
            rec = rec or (bool(n) and "recursive".startswith(n))
        else: rec = rec or bool(set(a[1:]) & {"r", "R"})
    return ops, (rec and verb == "rm") or verb == "rimraf"

def dyn_opts(args: list, cwd, env: dict):
    """Opções do `rm` que não estão escritas (`F=-rf; rm $F x`, `rm ${F:--rf} x`, `rm $(echo -rf) x`, `rm {-rf,x}`, `rm *` numa pasta com um arquivo `-rf`), só antes do `--`: (as que sei, se há pedaço que não sei: talvez seja `-r`)."""
    # vazio → variável de valor vazio some e glob sem achado fica literal: nenhuma opção; falhou/ilegível (UNK: variável que não conheço ou substituição) → `maybe`, nunca "não é opção"
    ws = args[:args.index("--") if "--" in args else len(args)]
    ts = [t for a in ws if re.search(r"[$`]", a) for t in pieces(a, cwd, env)] + [b for a in ws if "{" in a for b in braces(a)] + [os.path.basename(p) for a in ws if "/" not in a and re.search(r"[*?\[]", a) for p, _ in candidates(a, [cwd], env) if p]
    return [t for t in ts if t[:1] == "-" and t != "-"], any(UNK in t for t in ts)

# --- Bash (o mesmo leitor do secret-read-guard.py: o hook é um arquivo só, não importa o irmão) ---
class Q(str):
    """Palavra com aspas ou barra ANTES do primeiro `=` (`"D=x"`, `D"="x`): o bash não a lê como atribuição, é um comando."""

class Op(str):
    """Operador do shell (`;` `&&` `|` `(` `>` `2>>` `<<<`…). Uma palavra entre aspas igual a `;` NÃO é operador: por isso o tipo."""

SEP_OPS = {";", "&&", "||", "|", "|&", "&", ";;", "(", ")"}
REDIR = re.compile(r"\d*(?:&?>>?|<|>&|<&|>\||<>)")
OPRE = re.compile(r"<<<|<<-?|&&|\|\||\|&|;;|&>>|&>|>>|>&|<&|>\||<>|[;&|()<>]")
HDOC = re.compile(r"[ \t]*(?:'([^']*)'|\"([^\"]*)\"|\\?([\w.-]+))")  # delimitador de heredoc: 'EOF', "EOF" ou EOF

def skip_subst(t: str, i: int) -> int:
    """t[i:] começa em `$(`, `<(`, `>(`, `${` ou crase: o índice depois do fecho. Sem fecho = fim do texto (quem relê o corpo acusa o que ficou aberto; o `${ }`, que ninguém relê, acusa aqui). Dentro de `$( )`: aspas (com `\\"`, `$'…'`), `$( )`/`${ }`/crase
    aninhados e corpo de heredoc (o apóstrofo solto de um texto de commit) pulam inteiros; `${` fecha na 1ª `}` fora de aspas (a ' protege a `}`) e a crase na 1ª crase, aspas não a escondem (o bash casa a crase sem olhar aspas); chave solta não conta."""
    n, j, depth, hd = len(t), i + 1, 0, []
    if t[i] == "`" or t.startswith("${", i):  # crase fecha na 1ª crase (aspas não a escondem), `${` na 1ª `}` fora de aspas (a ' protege a `}`)
        e, q, j = t[i] if t[i] == "`" else "}", None, i + 1 + (t[i] == "$")
        while j < n and not (t[j] == e and q is None):
            c = t[j]
            if c == "\\" and q != "'": j += 1
            elif e == "}" and c in "'\"": q = None if q == c else (q or c)  # na crase as aspas NÃO escondem o fecho (o bash casa a crase sem olhar aspas)
            elif e == "}" and q != "'" and (c == "`" or (c == "$" and t[j + 1:j + 2] in ("{", "("))): j = skip_subst(t, j) - 1
            j += 1
        ST["open"] |= j >= n
        return min(j + 1, n)
    dq = False
    while j < n:
        c, nx = t[j], t[j + 1:j + 2]
        if c == "\\": j += 1
        elif c == '"': dq = not dq
        elif c == "`" or (c == "$" and nx in ("(", "{")) or (c in "<>" and nx == "(" and not dq): j = skip_subst(t, j) - 1
        elif dq: pass
        elif c == "'" or (c == "$" and nx == "'"):
            q = c == "$"; j += 1 + q
            while j < n and t[j] != "'": j += 2 if q and t[j] == "\\" else 1
        elif c in "()":
            depth += 1 if c == "(" else -1
            if depth == 0: return j + 1
        elif c == "<" and nx == "<":
            m = None if t[j + 2:j + 3] == "<" else HDOC.match(t, j + 2 + (t[j + 2:j + 3] == "-"))
            if m: hd.append((m.group(1) or m.group(2) or m.group(3) or "", t[j + 2:j + 3] == "-")); j = m.end() - 1
            else: j += 1
        elif c == "\n" and hd:  # o corpo do heredoc vai até a linha do delimitador
            for delim, tabs in hd:
                while True:
                    e = t.find("\n", j + 1); e = n if e < 0 else e
                    ok, j = (t[j + 1:e].lstrip("\t") if tabs else t[j + 1:e]) == delim, e
                    if ok or e >= n: break
                if not ok: return n
            hd = []
        j += 1
    return n

def lex(text: str):
    """Texto -> (palavras e Op, heredocs). Um leitor só, com as regras de aspas do bash: comentário, `\\`, '…', "…" (só `\\$ \\` \\" \\\\` escapam), $'…', $( ) e
    crase ficam DENTRO da palavra, newline vira `;` e o corpo de heredoc sai do fluxo: (corpo, palavras de quem o lê)."""
    toks, docs, pend, cur, word, i, n, q, ar = [], [], [], [], False, 0, len(text), None, 0  # ar = fundo de `(( ))` aritmético: ali `<<` é deslocamento, não heredoc

    def mark():
        nonlocal q
        q = len("".join(cur)) if q is None else q

    def flush():
        nonlocal cur, word, q
        if word:
            w = "".join(cur)
            toks.append(Q(w) if q is not None and "=" in w and q <= w.index("=") else w)
        cur, word, q = [], False, None

    while i < n:
        c, nx = text[i], text[i + 1:i + 2]
        if c in " \t":
            flush(); i += 1
        elif c == "\n":
            flush(); toks.append(Op(";")); i += 1
            for delim, tabs, recv, qd in pend:
                body = []
                while i < n:
                    j = text.find("\n", i)
                    line, i = (text[i:], n) if j < 0 else (text[i:j], j + 1)
                    if (line.lstrip("\t") if tabs else line) == delim: break
                    body.append(line)
                else: ST["open"] = True  # heredoc sem a linha do delimitador
                docs.append(("\n".join(body), recv, qd))
            pend = []
        elif c == "#" and not word:
            while i < n and text[i] != "\n":
                i += 1
        elif c == "\\":
            mark(); cur.append("" if nx == "\n" else nx); word = word or nx != "\n"; i += 2
        elif c == "'" or (c == "$" and nx == "'"):  # '…' literal; $'…' decodificado
            mark(); i += 1 + (c == "$"); word = True; j = i
            while j < n and text[j] != "'": j += 2 if c == "$" and text[j] == "\\" else 1
            cur.append(ansi(text[i:j]) if c == "$" else text[i:j]); i = j + 1; ST["open"] |= j >= n
        elif c == '"':
            mark(); i += 1; word = True
            while i < n and text[i] != '"':
                d, e = text[i], text[i + 1:i + 2]
                if d == "\\" and e:
                    cur.append(e if e in '$`"\\' else ("" if e == "\n" else "\\" + e)); i += 2
                elif (d == "$" and e in ("(", "{")) or d == "`":
                    j = skip_subst(text, i); cur.append(text[i:j]); i = j
                else:
                    cur.append(d); i += 1
            ST["open"] |= i >= n; i += 1
        elif (c == "$" and nx in ("(", "{")) or c == "`" or (c in "<>" and nx == "("):  # `<(cmd)` e `>(cmd)` (substituição de processo) ficam DENTRO da palavra como o $( )
            j = skip_subst(text, i); cur.append(text[i:j]); word = True; i = j
        elif c in ";&|()<>":
            pre = ""
            if c in "<>" and word and "".join(cur).isdigit():  # `2>`: o descritor faz parte do operador
                pre, cur, word, q = "".join(cur), [], False, None
            else: flush()
            op = OPRE.match(text, i).group(0)
            if op in "()" and (ar or (op == "(" and nx == "(" and (not toks or toks[-1] in KEYWORDS | {"for"} or (isinstance(toks[-1], Op) and toks[-1] in SEP_OPS)))): ar += 1 if op == "(" else -1  # `((` no começo de comando
            i += len(op)
            m = HDOC.match(text, i) if op in ("<<", "<<-") and not ar else None
            if m:  # o delimitador não é palavra; quem lê o heredoc está antes ou depois dele, na mesma linha
                k = len(toks)
                while k and not (isinstance(toks[k - 1], Op) and toks[k - 1] in SEP_OPS): k -= 1
                eol = text.find("\n", i)
                words = [str(t) for t in toks[k:] if not isinstance(t, Op)] + re.split(r"[\s;&|()<>]+", text[m.end(): n if eol < 0 else eol])
                pend.append((m.group(1) or m.group(2) or m.group(3) or "", op == "<<-", [os.path.basename(w) for w in words if w], m.group(3) is None or "\\" in m.group(0)))  # o 4º: delimitador entre aspas (o corpo não expande $( ))
                i = m.end()
            else: toks.append(Op(pre + op))
        else:
            cur.append(c); word = True; i += 1
    flush()
    return toks, docs + [("", r, True) for _, _, r, _ in pend]  # `cat <<EOF` sem newline depois: não há corpo

def substitutions(w: str):
    """Corpos de $( ), <( ), >( ) e crase dentro de UMA palavra."""
    i, out = 0, []
    while i < len(w):
        if (w[i] in "$<>" and w[i + 1:i + 2] == "(") or w[i] == "`":  # $( ), <( ), >( ) e crase
            j = skip_subst(w, i)
            out.append(w[i + 1:j] if w.startswith("$((", i) else w[i + 2:j - 1] if w[i] != "`" else w[i + 1:j - (w[j - 1:j] == "`")]); i = j  # `$((`: o corpo vai com o 2º `(`, lido como `(( ))` (o `<<` ali é deslocamento)
        else: i += 1
    return out

def peel(ws: list, pre=None) -> list:
    """Tira atribuição (NAME=v, guardada em `pre`: quem chama decide o que ela vale), palavra reservada e embrulho (env, sudo, timeout…) do começo: o comando de verdade (vazio = só atribuição).
    `command -v rm` consulta, não roda. Atribuição com aspas antes do `=` (`"D=x"`) é comando, não atribuição, salvo depois de um embrulho (o `env` a recebe como argumento)."""
    ws, wrapped = list(ws), False
    while ws:
        b = os.path.basename(ws[0])
        if ASSIGN.match(ws[0]) and (wrapped or not isinstance(ws[0], Q)):
            if pre is not None: pre.append(ws[0])
            ws = ws[1:]
        elif ws[0] in KEYWORDS:
            ws = ws[1:]
        elif b in WRAP:
            takes, npos, looked, shell, wrapped = set(WRAP[b][0].split()), WRAP[b][1], False, False, True
            ws = ws[1:]
            if pre is not None and b != "time":
                pre.append(None)  # marca "passou por embrulho": `env D=x` sem comando só lista o ambiente, não atribui no shell (`time` é palavra reservada: `time D=x` atribui)
            while ws and ws[0][:1] == "-" and len(ws[0]) > 1:
                o, ws = ws[0], ws[1:]
                if o == "--": break
                key, eq, val = o.partition("=") if o[:2] == "--" else (o[:2], "", o[2:])
                if key in takes and not (eq or val):
                    val, ws = (ws[0] if ws else ""), ws[1:]
                if pre is not None and key in {"env": ("-C", "--chdir"), "sudo": ("-D", "--chdir")}.get(b, ()): pre.append((val,))  # a pasta em que o comando de dentro roda: quem chama a aplica ao cwd
                if (b == "env" and key in ("-S", "--split-string")) or (b == "npx" and key in ("-c", "--call")):  # o valor da opção é um comando inteiro numa palavra só
                    ws = [str(t) for t in lex(val)[0]] + ws
                looked = looked or (b == "command" and key in ("-v", "-V"))
                shell = shell or (b in ("sudo", "doas") and key in ("-s", "-i", "--shell", "--login"))  # `sudo -s 'texto'`: o resto é uma linha de comando para o shell de quem sobe
            if looked: return []
            ws = ws[npos:]
            if shell and ws: ws = [str(t) for t in lex(" ".join(ws))[0]]
            if b == "flock" and ws[:1] in (["-c"], ["--command"]) and len(ws) > 1:  # `flock arquivo -c 'rm -rf x'`
                ws = [str(t) for t in lex(ws[1])[0]] + ws[2:]
        else: break
    return ws

def cd_target(ws: list, cwds: list, env: dict):
    """As pastas depois de um `cd`/`pushd` (assumo que rodou); None se a linha não é cd; [None] se não sei o destino."""
    ws = [w for w in ws if not ASSIGN.match(w)]
    while ws and ws[0] in KEYWORDS | CTL | {"time", "command", "builtin"}: ws = ws[1:]  # `then cd x`, `do cd x`, `{ cd x`: o cd depois de palavra de bloco também vale
    if not ws or os.path.basename(ws[0]) not in ("cd", "pushd", "popd"): return None
    if os.path.basename(ws[0]) == "popd": return [None]  # volta a uma pasta que não rastreio
    args = [a for a in ws[1:] if a not in ("-L", "-P", "-e", "-@", "--")]
    if args[:1] == ["-"]: return [None]
    return [p for p, _ in candidates(args[0], cwds, env)] if args else [home()]

def inline(code: str, cwds: list, depth: int, env: dict):
    """Código inline de python/node/perl/ruby/awk. Confere `['rm','-rf',x]`, texto de shell com rm (`os.system`) e, se o código usa uma API de remoção (DELAPI) ou algum literal cita
    rm/unlink/rmdir/shred, cada literal de caminho (`d='/x'; shutil.rmtree(d)`, `'rm -rf ' + '/x'`). A palavra solta "remove"/"delete" não liga nada."""
    for m in ARGV.finditer(code):
        rest = m.group(2) if m.group(1) else m.group(4)  # literal vira o texto; expressão (variável, concatenação) vira UNK
        els = [g.group("s") if g.group("s") is not None else g.group("d") if g.group("d") is not None else UNK for g in ELEM.finditer(rest)]
        ops, rec = rm_args(m.group(1) or m.group(3), els)
        if hit := check(ops, rec, False, cwds, env): return hit
    lits = [m.group(1) if m.group(1) is not None else m.group(2) for m in LIT.finditer(code)]
    deletes = bool(DELAPI.search(code)) or any(RM_TEXT.search(x) for x in lits)
    for lit in lits:
        if hit := scan_bash(lit, cwds, depth + 1, env) if RM_TEXT.search(lit) and re.search(r"\s", lit.strip()) else None: return hit
    strict = DELCALL.findall(code) + [x for x in lits if deletes and x and not re.search(r"\s", x) and re.search(r"\w", x) and re.match(r"[~/.]|\w+/", x)]
    bare = [x for x in lits if deletes and x and len(x) < 256 and "\n" not in x and re.search(r"\w", x)]  # qualquer outro literal pode ser um nome relativo (`d='gt-remote'; rmtree(d)`): julgado, mas um `$x` solto nele não bloqueia
    rec = bool(DELREC.search(code)) or any(re.search(r"\s-[a-zA-Z]*[rR]|--recurs", x) for x in lits if RM_TEXT.search(x))
    return check(strict, True, False, cwds, env) or check(bare, rec, False, cwds, env, True)

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
    prev = peel(feed[-1]) if feed else []
    return prev[1:] if prev and os.path.basename(prev[0]) in ("echo", "printf") else [UNK]

def said(feed: list):
    """O texto que o `echo` da etapa anterior do pipe imprime (palavras ainda com ~ e $), ou None se não sei (outro comando, opção do echo, redirecionamento)."""
    prev = peel(feed[-1]) if feed else []
    ws = prev[1:]
    ok = prev and os.path.basename(prev[0]) == "echo" and not any(isinstance(w, Op) for w in ws) and not (ws and ws[0][:1] == "-")
    return " ".join(tilde(str(w)) for w in ws) if ok else None

CTL = {"then", "elif", "else", "fi", "done", "esac", "{", "}", "function", "case", "while", "until"}  # palavras que abrem ou fecham bloco; as outras (`do`, `if`, `!`…) o `peel` tira

def block(ws: list, env: dict, b: dict, nsaved: int) -> list:
    """Tira de `ws` o que abre ou fecha bloco (`then else fi done { } case esac function`, a abertura de `for`/`while`) e guarda o que cada bloco enxerga: if/laço = [env antes, env dos outros ramos, `elif` à espera do then],
    `{ }` = None (grupo) ou o env de fora (corpo de função, que só roda na chamada). Fecho sem abertura (texto torto) não faz nada."""
    ws, fr = list(ws), b["frames"]
    while ws and not isinstance(ws[0], Op) and ws[0] in CTL:
        k, top = ws[0], (fr[-1] if fr else None)
        if k == "case":
            b["cases"].append(nsaved)
            break
        ws.pop(0)
        if k == "function":  # `function f { …`: o nome sai, o `{` seguinte abre o corpo
            if ws and ws[0] != "{": ST["funcs"].add(str(ws.pop(0)))
            ST["late"] = b["fnew"] = True
        elif k in ("while", "until") or (k == "then" and not (top and top[2])):
            fr.append([dict(env), [], False])
            if k != "then":
                widen(env); ST["late"] = True
        elif k == "then":
            top[2] = False
        elif k in ("else", "elif") and top:
            top[1].append(dict(env)); env.clear(); env.update(top[0]); top[2] = k == "elif"
        elif k in ("fi", "done") and top:
            fr.pop(); merge(env, top[0], *top[1])
        elif k == "esac" and b["cases"]:
            b["cases"].pop()
        elif k == "{":
            b["grp"].append(dict(env) if b["fnew"] else None)
            if b["fnew"]: ST["fn"] += 1; widen(env)
            b["fnew"] = False
        elif k == "}" and b["grp"]:
            snap = b["grp"].pop()
            if snap is not None: ST["fn"] -= 1; env.clear(); env.update(snap)
    if peel(ws)[:1] in (["for"], ["select"]):
        fr.append([dict(env), [], False]); widen(env); ST["late"] = True
    b["fnew"] = b["fnew"] and not ws
    return ws

def scan_bash(cmd: str, cwds: list, depth: int = 0, env=None, share: bool = False):
    env = env if share and env is not None else dict(env or {})
    if depth > 6: return "rm.too-deep", cmd[:60]
    toks, docs = lex(cmd)
    seq, blk, prev = toks + [Op(";")], {"frames": [], "grp": [], "cases": [], "fnew": False}, ";"  # prev = o separador de antes do comando
    cur, here, saved, feed, ever = [], list(cwds), [], [], list(cwds)  # feed = comandos anteriores da MESMA pipeline; ever = todo cwd que vi (o heredoc roda em algum deles); saved = (cwd, env) de cada `(`
    for i, t in enumerate(seq):
        if not (isinstance(t, Op) and t in SEP_OPS):
            cur.append(t)
            continue
        ws = list(cur)
        hd = [w for w in ws if w not in ("time", "!", "-p")]  # `time f() {` e `! f() {` também definem f (o resto é texto que o bash recusa inteiro)
        if t == "(" and len(hd) == 1 and hd[0] not in KEYWORDS | CTL and os.path.basename(hd[0]) not in WRAP and seq[i + 1:i + 2] == [")"]:  # `f() {`: cabeçalho de função
            ST["funcs"].add(str(hd[0])); ST["late"] = blk["fnew"] = True; ws = []
        ws = block(ws, env, blk, len(saved))
        if ws:
            # pipeline e `&` rodam em subshell mas (lastpipe, zsh) podem valer no shell: o que mudam entra como "talvez". Grupo `{ }`, `case`, depois de `&&`/`||`: pode não rodar, atribuição é "talvez".
            iso = t in ("|", "|&", "&") or prev in ("|", "|&")
            weak = iso or bool(blk["cases"]) or bool(blk["grp"] and blk["grp"][-1] is None) or prev in ("&&", "||")
            before = dict(env) if iso else None
            if hit := one(ws, here, depth, env, feed, None, not weak): return hit
            if before is not None: merge(env, before)
            if t == "(" and ASSIGN.fullmatch(str(ws[-1])):  # `D=(a b)`: matriz, o valor não leio
                setvar(env, ASSIGN.match(ws[-1]).group(1), [UNK], True)
        feed = feed + [cur] if t in ("|", "|&") else []
        new = cd_target(cur, here, env)
        if new is not None:  # o cd só vale com certeza depois de `&&`; com `;` `||` `&` `|` ele pode ter falhado e o shell ficou onde estava: valem os dois (o pior vence)
            merged = here + [p for p in new if p not in here]
            here = new if t == "&&" else merged if len(merged) <= 8 else merged[:7] + [None]  # nunca descarta o cwd mais novo: acima do teto entra um "não sei"
            grown = ever + [p for p in here if p not in ever]
            ever = grown if len(grown) <= 8 else grown[:7] + [None]
        if t == "(":
            saved.append((here, dict(env)))
        elif t == ")" and saved and not (blk["cases"] and len(saved) == blk["cases"][-1]):  # o `)` de um padrão de `case` não fecha subshell
            here, snap = saved.pop()
            env.clear(); env.update(snap)
        cur, prev = [], str(t)
    denv = {k: [UNK] for k in env}  # o corpo roda no meio da linha e eu só tenho o ambiente do FIM: variável atribuída por fora vale "não sei", nunca o valor final
    for body, recv, qd in docs:  # corpo lido por shell ou interpretador é código, no cwd do comando que o lê (qual foi? valem todos os que vi); por cat, tee, git commit -F - é texto, salvo o $( ) de um delimitador sem aspas
        hit = scan_bash(body, ever, depth + 1, denv) if any(w in SHELLS for w in recv) else None
        hit = hit or (inline(body, ever, depth + 1, denv) if any(INTERP.fullmatch(w) for w in recv) else None)
        for sb in () if qd else substitutions(body): hit = hit or scan_bash(sb, ever, depth + 1, denv)
        if hit: return hit
    return None

def one(ws: list, cwds: list, depth: int, env: dict, feed: list, app=None, strong: bool = True):
    words, here, k = [], [], 0
    while k < len(ws):  # redirecionamento: o operador e a palavra seguinte não são argumentos
        t = ws[k]
        if isinstance(t, Op) and k + 1 < len(ws) and (REDIR.fullmatch(t) or t == "<<<"):
            if t == "<<<": here.append(str(ws[k + 1]))
            k += 2
        else:
            k += 1
            if not isinstance(t, Op): words.append(t)
    for w in words:  # $( ) e crase dentro de QUALQUER palavra rodam, mesmo atrás de um echo
        for body in substitutions(w):
            if hit := scan_bash(body, cwds, depth + 1, env): return hit
        for m in re.finditer(r"\$\{(\w+):?=", w):  # `${D:=x}` atribui D no shell que lê a palavra
            setvar(env, m.group(1), [UNK], True)
    pre = []
    ws = peel(words, pre)
    wrapped, cd, pre = None in pre, [a[0] for a in pre if isinstance(a, tuple)], [a for a in pre if isinstance(a, str)]
    cenv = dict(env)  # o que um comando de dentro (bash -c, eval, find -exec, xargs…) enxerga: o ambiente de fora com o prefixo `NOME=v` somado como "talvez". Os operandos do próprio verbo usam `env`: o shell os expande ANTES do prefixo valer
    for a in pre: assign(a, cenv, cwds[0], False)
    if not ws:  # só atribuição: vale no shell (atrás de `env`/`command` não: aí é argumento do embrulho)
        for a in pre if not wrapped else (): assign(a, env, cwds[0], strong)
        return None
    for d in cd:  # `env -C DIR cmd`, `sudo -D DIR cmd`: o comando de dentro roda em DIR (não resolvo = cwd "não sei", que barra a remoção recursiva)
        new = [p for p, _ in candidates(d, cwds, env)]; cwds = new if len(new) <= 8 else new[:7] + [None]
    if ws[0] in ST["funcs"]:  # chamada de função: o que o corpo atribui entra como "talvez"
        for k, v in list(ST["fnvals"].items()): setvar(env, k, sorted(v), False)
    if len(ws) > 3 and ws[0] in ("for", "select") and ws[2] == "in":  # `for d in a b; do rm -rf "$d"; done` (e `time for …`): $d passa a valer cada item
        setvar(env, ws[1], [tilde(x) for w in ws[3:] for x in pieces(w, cwds[0], env)], strong)
        return None
    if re.search(r"[$`*?\[]|\{[^{}]*(?:,|\.\.)", ws[0]) and ws[0] not in ("[", "[["):  # verbo que sai de variável, substituição, curinga ou chave (`$R -rf x`, `$(echo rm) -rf x`, `/bin/r? -rf x`, `{rm,-rf,x}`)
        bs = braces(ws[0])  # cada alternativa da chave é uma PALAVRA (`{rm,-rf,x}` = rm -rf x; `r{m,} -rf x` = rm r -rf x); passou do teto = não sei
        if UNK not in bs[0] and bs != [ws[0]]: return one(bs + ws[1:], cwds, depth + 1, cenv, feed, app, False)
        v = expand(bs[0], cwds[0], env)
        if re.match(r"[^=]*\$[^=]*\+?=", ws[0]):  # `$n=x` (só vira atribuição dentro de eval): o nome vem de variável
            wild(env)
        known = [x for x in v if UNK not in x and x != ws[0]]  # cada valor que sei é uma linha de comando: vira palavras (`C='rm -rf x*'; $C`, `rm${IFS}-rf${IFS}x`), também quando outro valor é "não sei" (`true && C=…`); valor vazio some e o resto vira o comando
        for x in known:
            for rd in (x.split(), [str(t) for t in lex(x)[0]]):  # `$C` solto: o bash só parte o valor em branco e expande curinga, aspas, `;`, `#` e `\` dele são LETRAS (`C="rm -rf 'a ~/p b'"; $C` apaga ~/p); `eval "$C"` e `bash -c "$C"` leem o valor como texto de shell (aspas valem). Aqui os dois chegam como `$C`: leio dos dois jeitos (bloqueia a mais, nunca a menos)
                if hit := one(rd + ws[1:], cwds, depth + 1, cenv, feed, app, False): return hit
        if len(known) == len(v): return None
        # vazio → variável sem texto recebido (veio de `read`/`for`) ou texto que resolve (o "não sei" é de uma atribuição fraca): segue a regra de antes; falhou/ilegível → texto recebido cita remoção e traz `$( )`/crase que não resolvo: bloqueia, nunca libera
        if any(RM_TEXT.search(t) and UNK in "".join(expand(t, cwds[0], env)) for t in ST["raw"].get(re.sub(r"\W", "", ws[0]), ())): return "rm.unparsed", ws[0].replace(UNK, "?")
        ops, rec = rm_args("rm", ws[1:])  # um valor que não sei que programa é: com flag recursiva vale como rm; sem ela valem as regras absolutas nos operandos, e texto de shell com rm nos argumentos é lido
        for a in ws[1:]:
            if hit := scan_bash(a, cwds, depth + 1, cenv) if RM_TEXT.search(a) and re.search(r"\s", a.strip()) else None: return hit
        return check(ops, rec, () if rec else ("",), cwds, env)
    verb, args = os.path.basename(ws[0]), ws[1:]
    if verb in ("export", "declare", "typeset", "local", "readonly"):  # `export D=x`: vale para os comandos seguintes
        if verb in ("declare", "typeset", "local") and any(re.fullmatch(r"-\w*n\w*", a) for a in args):  # nameref: `r=x` passa a gravar em outra variável
            ST["nref"] = True; wild(env)
        for a in args:
            if ASSIGN.match(a):
                assign(a, env, cwds[0], strong)
            elif "=" in a and re.search(r"[$`]", a.split("=", 1)[0]):  # `export "$n=x"`: o nome é calculado
                wild(env)
        return None
    if verb in ("read", "mapfile", "readarray", "getopts", "unset", "let") or (verb == "printf" and "-v" in args):  # comandos que gravam em variável pelo NOME que recebem
        # vazio → sem nome para gravar; falhou/ilegível (nome calculado `"$n"`: não sei qual é) → qualquer variável pode ter mudado
        if any(re.search(r"[$`]", a) for a in (args[args.index("-v") + 1:][:1] if verb == "printf" else args)): wild(env)
        names, src = [a for a in args if re.fullmatch(r"\w+", a)], None
        if verb == "printf" and len(args) == 4 and args[0] == "-v" and args[2] == "%s":  # valor que sei: `printf -v N %s V` e `read [-r] N <<< V` (IFS padrão, sem barra invertida)
            src, tgt = args[3], args[1]
        elif verb == "read" and names and [a for a in args if a != "-r"] == names[-1:] and env.get("IFS", [" "]) == [" "]:  # a linha vem do `<<<` ou do echo do pipe
            src, tgt = tilde(here[0]) if len(here) == 1 else said(feed), names[-1]
        vals = [x.strip() if verb == "read" else x for x in expand(src, cwds[0], env)] if src is not None and "\\" not in src else None
        for n in names + ["REPLY"]:  # ramo que pode não rodar (`&&`, if) soma ao valor de antes em vez de trocá-lo
            setvar(env, n, vals if vals is not None and n == tgt else [UNK], strong)
        return None
    if verb in ("source", "."):  # o arquivo que ele roda pode atribuir qualquer coisa
        wild(env)
    if verb in RM_VERBS:
        args = [y for a in args for y in (braces(a) if a[:1] == "-" and "{" in a else [a])]  # `--{recursive,force}`: o bash entrega duas opções
        xo, maybe = dyn_opts(args, cwds[0], env)  # `F=-rf; rm $F x`: a opção que não está escrita vale como se estivesse; pedaço que não sei só torna recursivos os operandos que sei
        ops, rec = rm_args(verb, xo + args)
        return check(ops + list(app or []), rec or (verb == "rm" and any(UNK in a for a in args)), False, cwds, env, maybe=maybe and verb == "rm")  # chave além do teto = opção que não sei, vale recursiva
    if verb == "xargs":
        i = 0
        while i < len(args) and args[i][:1] == "-" and len(args[i]) > 1:
            i += 2 if args[i] in XARGS_VAL else 1
            if args[i - 1] == "--": break
        return one(args[i:], cwds, depth, cenv, [], fed(feed), False) if args[i:] else None
    if verb == "find":
        i = 0
        while i < len(args) and args[i] in ("-H", "-L", "-P"): i += 1
        j = i
        while j < len(args) and args[j][:1] not in ("-", "(", "!"): j += 1
        roots, expr, rmish = args[i:j] or ["."], args[j:], "-delete" in args[j:]
        for x, t in enumerate(expr):
            if t in ("-exec", "-execdir", "-ok", "-okdir"):
                cmd = expr[x + 1:]
                end = next((y for y, w in enumerate(cmd) if w == ";" or (w == "+" and y and cmd[y - 1] == "{}")), len(cmd))
                sub = peel(cmd[:end])
                rmish = rmish or bool(sub) and os.path.basename(sub[0]) in RM_VERBS
                if hit := one(cmd[:end], cwds, depth, cenv, [], None, False): return hit
        # filtro de nome só vale se filtra de verdade (narrow) e nada o anula: `-o`, `!`, `-not` fazem o -delete valer para o que o filtro NÃO casa
        sel = () if {"!", "-not", "-o", "-or"} & set(expr) else tuple(expr[x + 1] for x, t in enumerate(expr) if t in SELECT and x + 1 < len(expr) and narrow(t, expr[x + 1]))
        return check(roots, True, sel, cwds, env) if rmish else None
    shellish = verb in SHELLS or verb in ("eval", "source", ".")
    if shellish or INTERP.fullmatch(verb):
        sub = dict(cenv)  # `eval` roda no shell de quem chama: o que ele atribui volta; `bash -c`, `sh x` e os interpretadores rodam numa cópia
        run = (lambda s: scan_bash(s, cwds, depth + 1, sub, verb == "eval")) if shellish else (lambda s: inline(s, cwds, depth + 1, sub))
        for body in [b for a in args for b in substitutions(a)]:  # o que `<( )` e `$( )` imprimem é o programa (`bash <(echo 'rm -rf x')`, `bash -c "$(cat <<'EOF'…EOF)"`, `eval "$(echo rm -rf x)"`)
            tk, dcs = lex(body)
            for w in code_of(tk) + [d for d, _, _ in dcs]:
                if hit := run(w): return hit
        code = " ".join(args) if verb == "eval" else None
        for x, a in enumerate(args if code is None else []):
            if re.fullmatch(r"-[a-zA-Z]*[ceEpr]|--(?:eval|print|command)", a):
                code = args[x + 1] if x + 1 < len(args) else None
                break
        if code is None and verb.endswith("awk"): code = next((a for a in args if not a.startswith("-")), None)
        code = code or (here[0] if here else None)
        if not code and verb != "eval" and ("-" in args or "-s" in args or not [a for a in args if not a.startswith("-")]):  # lê o programa do stdin: o que vem pelo pipe é código
            for w in [c for st in feed for c in code_of(st)]:
                if hit := run(w): return hit
        hit = run(code) if code else None
        if verb == "eval" and not hit:
            for k, v in sub.items():
                if cenv.get(k) != v: setvar(env, k, v, strong)
        return hit
    if verb in OPAQUE:  # não modelo o que o lançador faz: o comando de dentro (palavra solta ou texto entre aspas) vale
        for j, w in enumerate(args):
            if re.search(r"\s", w):
                if hit := scan_bash(w, cwds, depth + 1, cenv): return hit
            elif os.path.basename(w) in RM_VERBS | {"find", "xargs"} | SHELLS: return one(args[j:], cwds, depth + 1, cenv, [], None, False)
    for x, a in enumerate(args):  # corredor de código que não conheço (xonsh, elvish, nu…): a convenção `-c 'texto'` entrega o programa; só texto que cita rm e tem espaço (não pega `git -c k=v`, `cut -c1-5`, `grep -e`)
        if a in ("-c", "--command") and x + 1 < len(args) and RM_TEXT.search(args[x + 1]) and re.search(r"\s", args[x + 1].strip()):
            if hit := scan_bash(args[x + 1], cwds, depth + 1, cenv): return hit
    return None

def decide(inp: dict):
    """None = liberado; (regra, alvo, operação) = bloqueado."""
    global DEADLINE
    if inp.get("tool_name") != "Bash": return None
    DEADLINE = time.monotonic() + LIMIT
    cmd, cwd = str((inp.get("tool_input") or {}).get("command") or ""), inp.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR")
    if len(cmd) > MAX_CMD: return "rm.too-big", cmd[:60], "comando Bash"  # não dá para conferir e a busca de texto não prova nada (`r''m`, `$'\x72m'`): bloqueado
    ST.update(raw={}, seen={}, late=False, again=False, funcs=set(), fnvals={}, fn=0, nref=False, open=False)
    ctx = [os.path.realpath(cwd)] if isinstance(cwd, str) and os.path.isabs(cwd) else [None]
    hit = scan_bash(cmd, ctx)
    if not hit and ST["late"]:  # laço ou função: o corpo pode rodar depois de atribuições que vêm DEPOIS dele no texto; o 2º passo o lê com todos os valores já vistos
        ST.update(again=True, fn=0)
        hit = scan_bash(cmd, ctx)
    if not hit and ST["open"] and any(RM_TEXT.search(x) for x in (re.sub(r"['\"\\]", "", cmd), ansi(cmd))):  # vazio → todo fecho achado, nada a dizer; falhou/ilegível (fecho perdido) e o texto cita remoção → bloqueado
        hit = "rm.unparsed", cmd[:60]
    return (hit[0], hit[1], "comando Bash") if hit else None

def message(hit) -> str:
    rule, target, op = hit
    return ("[HOOK BLOCK: rm-target-guard] NÃO É CANCELAMENTO DO USUÁRIO — política automática de proteção contra remoção.\n"
            f"BLOQUEADO: {op} apagaria alvo protegido ({rule}: {RULES.get(rule, rule)}).\nAlvo: {target}\n"
            "Scratch continua livre: `rm -rf /tmp/<pasta>` (ou o scratchpad da sessão) passa; no mini `safe-clean <caminho-absoluto>`; no nó `find <pasta> -mindepth 1 -delete`. "
            "Alvo em variável ou `$( )`: escreva o caminho por extenso. Dado do Dolt, `.git`, HOME e raiz de repo não se apagam por agente: se a tarefa exige mesmo, devolva a bead ao Mayor.\n")

def main() -> int:
    # vazio → stdin vazio não traz pedido nenhum, libera; falhou/ilegível (não é JSON, não é objeto, o guarda estourou) → bloqueado: um pedido que o guarda não consegue ler não vira "liberado"
    raw = sys.stdin.buffer.read().decode("utf-8", "replace")  # bytes inválidos não podem derrubar a leitura (exit 1 NÃO bloqueia o hook)
    if not raw.strip(): return 0
    try:
        hit = decide(json.loads(raw))
    except Exception as e:  # noqa: BLE001 — falha do guarda não pode virar "liberado"
        print(f"[HOOK BLOCK: rm-target-guard] o guarda falhou ({type(e).__name__}) e não consigo conferir este pedido: bloqueado.", file=sys.stderr)
        return 2
    if hit: print(message(hit), file=sys.stderr)
    return 2 if hit else 0

if __name__ == "__main__": sys.exit(main())
