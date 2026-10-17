#!/usr/bin/env python3
"""wait-for-dolt-plan.py — quais jobs do HQ recebem o wait-for-dolt.sh, medido nos plists VIVOS (ga-sh8t23.2; revisão de arquitetura 15/10).

Contents
  Para que serve · Como decide · Uso · Três estados · Códigos

PARA QUE SERVE
  A bead pede "a lista dos jobs que leem Dolt no boot é MEDIDA (programa de cada RunAtLoad), não adivinhada, e cada plist alterado mostra o antes/depois". Este comando lê
  ~/Library/LaunchAgents (o que o launchd carregou — fonte ≠ o que roda: só 17 dos 115 plists com label HQ têm cópia no repositório, 98 existem só ali), mede o que o programa
  de cada RunAtLoad do escopo HQ faz com bd/gc/dolt, cruza com a política revisada (wait-for-dolt.policy.tsv: decisão + motivo por job) e mostra o que mudaria. Sem --apply é
  SÓ LEITURA. Nunca chama launchctl: recarregar job é o passo de ativação (runbook), com canário, e é de quem coordena a cidade.

COMO DECIDE (a medição é a evidência; a decisão é da política, que o plano confere contra a medição a cada execução)
  escopo   label com.gascity.* ou com.gastown.* cujo programa NÃO vive na árvore de outro rig (esses viram bead no rig dele). RunAtLoad=true.
  medição  LÊ = o programa tem uma CHAMADA a bd/gc/dolt (posição de comando, ou subprocess ["bd", ...]; comentário e texto entre aspas não contam) · TALVEZ = só menção solta ·
           NÃO ACHEI = programa legível sem menção · ILEGÍVEL = não consegui ler o programa (inclui script executado direto ou citado no `-c` que não existe). Segue o programa; os .sh/.py
           com caminho absoluto dentro de um `-c`; e o script que um interpretador (bash/sh/python) recebe como 1º argumento. NÃO segue script chamado por script (um job que lê o Dolt
           por dentro de outro script aparece como TALVEZ/NÃO ACHEI, e ficar sem wrapper é o comportamento de hoje).
           Posição de comando = início de linha, depois de ; & | ( ` $( ! { ou das palavras de controle (if/elif/else/while/until/then/do), e depois de prefixos (timeout com suas
           opções `-k D`/`-s S`/`--kill-after`, env, command, exec, nice, VAR=valor). O binário pode ser um alias de variável pelo NOME (termina em bd/gc/dolt: "$_gc", $GC_BIN), mas
           variável usada como ARGUMENTO de função não é comando. Linha de log (echo/printf/log) descarta só o seu próprio segmento: `echo ok; gc ...` e `echo "$(gc ...)"` contam.
  política wrap (embrulha) · isento (precisa rodar com o Dolt fora, ou tem ato útil que não precisa dele, ou é KeepAlive) · nao-medido (sem leitura medida). Na dúvida: isento.

USO   wait-for-dolt-plan.py [--dir D] [--policy F] [--wrapper W] [--timeout S] [--boot-window S] [--apply | --revert] [--backup-dir B] [--only LABEL ...]
  padrão: --dir ~/Library/LaunchAgents · --policy ao lado do script · --wrapper $GC_CITY_PATH/scripts/wait-for-dolt.sh · --timeout 300 · --boot-window 900.
  --apply  grava (com backup do original) o ProgramArguments `[W, --timeout S, --boot-window B, --, <comando original>...]` nos jobs `wrap` que ainda não estão embrulhados. Recusa TUDO
           (nada é escrito) com divergência de política ou wrapper ausente/não executável/com sintaxe ruim/sem o dolt-pid-lib.sh ao lado. Plist symlink, com chave Program, com backup
           já existente ou que o plutil -lint recusa é pulado SÓ ELE (vira falha no resumo, exit 1) e os demais seguem. Os comentários XML do plist não sobrevivem à reescrita; o backup
           guarda o original (um --backup-dir reaproveitado nunca sobrescreve). NÃO recarrega o job: vale no próximo boot ou quando o operador recarregar.
  --revert tira o prefixo de todo plist RunAtLoad embrulhado (qualquer um, não só os da política), também com backup. Idempotente. Plist que não consegui ler é listado ("NÃO LI") e
           conta como falha (exit 1): não sei se está embrulhado, e isso não é "nada a reverter".
  --only L restringe --apply/--revert ao label L (repetível): é o canário. Label que não existe no escopo, ou (no --apply) que a política não marca wrap, é uso errado (exit 2).

TRÊS ESTADOS  plist ilegível ou de forma estranha (topo que não é dict, Label que não é texto) aparece com o motivo (nunca some); programa ilegível é ILEGÍVEL (≠ NÃO ACHEI);
  política ilegível/duplicada → exit 3 sem plano (não chuto decisão).
  Divergência (job do escopo fora da política · wrap sem LÊ · wrap em KeepAlive · wrap sem StartInterval/StartCalendarInterval · isento/nao-medido já embrulhado · nao-medido que mede LÊ ·
  política cita job que não existe/é de fora · label em 2 arquivos · plist que não consegui ler (pode ser o gêmeo de um label wrap) · plist já embrulhado por OUTRO caminho do wrapper, ou cujo wrapper sumiu ou não executa) → exit 1: o plano é
  impresso mas --apply recusa. "Embrulhado" = argv0 é o --wrapper ou um wait-for-dolt.sh de qualquer caminho. Rodar o plano de tempos em tempos é o detector do último caso.

CÓDIGOS  0 plano/aplicação feitos, sem divergência · 1 divergência, falha ao escrever ou (--revert) plist não lido · 2 uso errado · 3 não consegui ler a entrada · 4 --apply recusado (wrapper).
"""
from __future__ import annotations

import argparse
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time

HQ_PREFIXES = ("com.gascity.", "com.gastown.")
GT_ROOT = os.environ.get("WFD_GT_ROOT", "/Users/athos/gt")
OTHER_RIG = re.compile(re.escape(GT_ROOT) + r"/(?!\.gascity-gastown-hq)[^./][^/]*/")   # programa na árvore de OUTRO rig
CITY = os.environ.get("GC_CITY_PATH") or GT_ROOT + "/.gascity-gastown-hq"
HERE = os.path.dirname(os.path.abspath(__file__))
SHELLS = ("bash", "sh", "zsh")
CLIS = ("bd", "gc", "dolt")
DECISIONS = ("wrap", "isento", "nao-medido")
WRAPPER_NAME = "wait-for-dolt.sh"
# chamada em posição de comando (início, ; & | ( ` $( ! { then do else elif if while until), com prefixos comuns (timeout [opções] N, env, VAR=x) e o binário por caminho ou por variável conhecida
_TMO = r"timeout\s+(?:(?:-[ks]\s+|--(?:kill-after|signal)\s+)\S+\s+|-\S+\s+)*\S+\s+"   # GUARD:timeout-options — `timeout -k 5 10 gc`, `-s KILL 5 bd`, `--foreground 10 dolt`: as opções vêm antes do prazo
_KW = r"\b(?:then|do|else|elif|if|while|until)\b"   # GUARD:keyword-anchors — `if bd show …; then`, `while bd list | …; do`: o comando vem logo depois da palavra
_BRACE = r"\{(?=\s)"   # GUARD:brace-anchor — `f() { bd list; }`; `{` colado em texto (`${GC}`) não abre grupo
_ASSIGN = r"\w+=(?:[^\s$(`]|\$\{?\w+\}?)*\s+"   # GUARD:assign-prefix — `VAR=x cmd`; o valor não abre `$(…)`: em `x=$(fn "$MY_GC" 20)` o que vem depois do espaço é ARGUMENTO, não comando
_CMDPOS = r"(?:^|[;&|(`]|\$\(|" + _KW + r"|" + _BRACE + r"|!)\s*(?:(?:" + _TMO + r"|env\s+|command\s+|exec\s+|nice\s+|(?:bash|sh)\s+|" + _ASSIGN + r")*)"
_VARBIN = r"\$\{?(?i:(?:\w*_)?(?:bd|gc|dolt)(?:_bin)?)\}?"   # GUARD:var-binary — variável EXECUTADA cujo nome termina em bd/gc/dolt: $BD, $GC_BIN, $_gc, $LCA_BD (alias local do binário). $GC_CITY e $BDIR não casam
_BIN = r"(?:(?:\"?\$\{?\w+\}?\"?/|[\w./-]*/)?\"?(?:bd|gc|dolt)\"?|\"?(?:" + _VARBIN + r"|\$\{?BD_LIST_CACHED\}?)\"?)"
SH_STRONG = re.compile(_CMDPOS + _BIN + r"(?=\s|$)")
LOGCMD = re.compile(r"^\s*(echo|printf|log|warn|info|die|fail|err|note|emit\w*|_log\w*|notify)\b")
SEGSPLIT = re.compile(r";|&&|\|\|?|(?<![>&])&(?![>&])")   # separadores de comando; `2>&1` e `&>` não separam
PY_STRONG = re.compile(r"""\[\s*["'](?:bd|gc|dolt)["']\s*[,\]]|\[\s*(?:GC|BD|GC_BIN|BD_BIN)\s*,|\bpymysql\.connect|mysql\.connector\.connect""")
WEAK = re.compile(r"(?<![\w./$-])(?:bd|gc|dolt)(?![\w/-])")   # `.gc/logs`, `$GC_CITY`, `dolt-pid-lib.sh` não são menção
# só ordena a EVIDÊNCIA mostrada (a linha com subcomando de verdade vence a que é texto de log); não decide LÊ
_SUB = r"(?:list|show|update|close|query|ready|create|comment|label|config|reopen|session|mail|rig|dolt|bd|nudge|agent|events|suspend|resume|reload|supervisor|sql|status|restart)"
SUB_SH = re.compile(r"(?:bd|gc|dolt|" + _VARBIN + r"|\$\{?BD_LIST_CACHED\}?)\"?\s+(?:(?:-C|--city)\s+\S+\s+)*" + _SUB + r"\b")
SUB_PY = re.compile(r"""(?:["'](?:bd|gc|dolt)["']|\b(?:GC|BD|GC_BIN|BD_BIN))\s*,\s*(?:["'](?:-C|--city)["']\s*,\s*[^,\]]+,\s*)*["']""" + _SUB + r"""["']|\[\s*["'](?:bd|gc|dolt)["']\s*\]\s*\+""")
INLINE_PATH = re.compile(r"(/[\w./-]+\.(?:sh|py))\b")


def load_plist(path):
    """→ dict. O launchd aceita XML que o expat do Python recusa (comentário com `--` dentro): falhou no plistlib → o plutil converte e o plistlib lê o resultado; falhou nos dois → sobe a exceção do plistlib."""
    try:
        with open(path, "rb") as fh:
            return plistlib.load(fh)
    except Exception as first:  # noqa: BLE001
        try:
            r = subprocess.run([os.environ.get("WFD_PLUTIL", "plutil"), "-convert", "xml1", "-o", "-", path], capture_output=True, timeout=15)
            if r.returncode == 0:
                return plistlib.loads(r.stdout)
        except (OSError, subprocess.SubprocessError, ValueError):
            pass
        raise first


def code_only(line):
    """A linha de shell sem o que é TEXTO: literais entre aspas e comentário final viram brancos; `$(...)` e crase dentro de aspas duplas continuam sendo código, e "$VAR" sozinho
    (o binário entre aspas) vira $VAR. Sem isto uma mensagem de log/jq que cita `bd list` contava como chamada (medido: worktree-reaper.sh não chama bd/gc e aparecia como LÊ)."""
    line = re.sub(r'"(\$\{?\w+\}?)"', r"\1", line)
    out, st, i, n = [], [], 0, len(line)   # pilha: sq '...' · dq "..." · cs $(...) · bt `...`
    while i < n:
        c, ctx = line[i], (st[-1] if st else "code")
        if ctx == "sq":
            if c == "'":
                st.pop()
            out.append(" ")
        elif ctx == "dq":
            if c == "\\":
                out.append("  "); i += 2; continue
            if c == '"':
                st.pop(); out.append(" ")
            elif c == "$" and line.startswith("$(", i):
                st.append("cs"); out.append("$("); i += 2; continue
            elif c == "`":
                st.append("bt"); out.append(c)
            else:
                out.append(" ")
        else:   # código: topo, $(...) ou crase
            if c == "\\":
                out.append(line[i:i + 2]); i += 2; continue
            if c == "'":
                st.append("sq"); out.append(" ")
            elif c == '"':
                st.append("dq"); out.append(" ")
            elif c == "#" and (i == 0 or line[i - 1] in " \t;"):
                break
            elif c == "`":
                st.pop() if ctx == "bt" else st.append("bt"); out.append(c)
            elif c == "$" and line.startswith("$(", i):
                st.append("cs"); out.append("$("); i += 2; continue
            elif c == "(" and ctx == "cs":
                st.append("cs"); out.append(c)
            elif c == ")" and ctx == "cs":
                st.pop(); out.append(c)
            else:
                out.append(c)
        i += 1
    return "".join(out)


def call_text(code):
    """O que sobra de uma linha de shell (já passada por code_only) para procurar CHAMADA. Só o SEGMENTO que é comando de log (echo/printf/log/warn…) perde o texto: o resto da linha continua
    valendo (`echo go; bd list`, `printf x | bd update`). Dentro do segmento de log só fica o que EXECUTA (`$(…)` e crase: `echo "$(bd list)"` chama). Descartar a linha toda por começar em
    `echo` fazia `echo go; bd list` virar "não chama" — um erro de leitura apresentado como medida."""
    keep = []
    for seg in SEGSPLIT.split(code):   # GUARD:log-split
        if LOGCMD.match(seg):   # GUARD:log-segment
            m = re.search(r"\$\(|`", seg)
            seg = seg[m.start():] if m else ""   # GUARD:log-tail
        keep.append(seg)
    return ";".join(keep)


def read_text(path):
    """→ texto, ou None quando não dá para ler (ausente/sem permissão/binário). vazio → "" (arquivo vazio é legível); falhou → None, e quem chama conta como ILEGÍVEL."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read(2_000_000)
    except OSError:
        return None
    return None if b"\0" in raw[:4096] else raw.decode("utf-8", "replace")


def measure(args):
    """→ (estado, evidência). LE | TALVEZ | NAO-ACHEI | ILEGIVEL; a evidência é `arquivo:linha: texto` para o humano conferir."""
    if not args:
        return "ILEGIVEL", "ProgramArguments vazio"
    if os.path.basename(args[0]) in CLIS:
        return "LE", "(programa) " + " ".join(args)[:100]
    named, srcs = [], []   # named = script que o job executa direto (shebang) ou cita no `-c`: ausente/ilegível = não sei, nunca "sem menção"
    if args[0].startswith("/") and args[0].endswith((".sh", ".py")):   # GUARD:direct-exec
        named.append(args[0])
    prog = os.path.basename(args[0])
    if len(args) > 1 and (prog in SHELLS or re.fullmatch(r"python[\d.]*", prog)) and args[1].startswith("/"):   # GUARD:interp-script — o programa do interpretador é o args[1]: ausente = não sei, mesmo que outro argumento seja legível
        named.append(args[1])
    if len(args) >= 3 and os.path.basename(args[0]) in SHELLS and args[1] == "-c":
        inline = " ".join(args[2:])
        srcs.append(("(inline)", inline))
        named += INLINE_PATH.findall(inline)
    paths = named + [a for a in args[1:] if a.startswith("/")]   # o resto dos argumentos com `/` pode ser diretório/dado: ausente aí não conta
    unreadable = 0
    for p in dict.fromkeys(paths):
        if not os.path.isfile(p):
            unreadable += p in named   # GUARD:named-missing
            continue
        text = read_text(p)
        if text is None:
            unreadable += 1
        else:
            srcs.append((os.path.basename(p), text))
    weak = strong = best = ""
    calls, best_rank = 0, -1
    for name, text in srcs:
        py = name.endswith(".py")
        for i, line in enumerate(text.splitlines(), 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            code = line if py else code_only(line)   # GUARD:code-only
            if (PY_STRONG if py else SH_STRONG).search(code if py else call_text(code)):
                calls += 1
                strong = strong or f"{name}:{i}: {s[:100]}"
                # evidência = a linha que mais parece chamada de verdade (subcomando + 2>/dev/null, $(...), || ou &&); empate → a primeira. Texto de ajuda dentro de string multilinha não tem isso.
                rank = 2 * bool((SUB_PY if py else SUB_SH).search(code)) + bool(re.search(r"2>|>/dev/null|\$\(|\|\||&&|capture_output|subprocess", line))
                if rank > best_rank:
                    best, best_rank = f"{name}:{i}: {s[:100]}", rank
            elif not weak and WEAK.search(line):
                weak = f"{name}:{i}: {s[:100]}"
    if strong:
        return "LE", (best or strong) + (f"  (+{calls - 1} outras linhas de chamada, {calls} no total)" if calls > 1 else "  (1 linha de chamada)")
    if weak:
        return "TALVEZ", weak
    if unreadable or not srcs:
        return "ILEGIVEL", "nenhum arquivo de programa legível"
    return "NAO-ACHEI", ""


def is_wrapped(args, wrapper):
    """Já embrulhado = argv0 é o --wrapper deste plano OU um wait-for-dolt.sh em QUALQUER caminho (outro GC_CITY_PATH, cópia de worktree já apagada). Só a igualdade de caminho dava "a embrulhar" e embrulhava por cima."""
    return bool(args) and (args[0] == wrapper or os.path.basename(args[0]) == WRAPPER_NAME)   # GUARD:wrapped-by-name


def inner(args, wrapper):
    """O comando original de um ProgramArguments já embrulhado (o que vem depois do `--`); não embrulhado → o próprio args. Embrulhado sem `--` → None (formato que não conheço)."""
    if not is_wrapped(args, wrapper):
        return args
    return args[args.index("--") + 1:] if "--" in args[1:] else None   # GUARD:inner-strip


def load_policy(path):
    """→ {label: (decisão, motivo)}. Arquivo ilegível, linha malformada, decisão desconhecida ou label repetido → ValueError/OSError (exit 3): não chuto decisão."""
    pol = {}
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.rstrip("\n").split("\t", 2)
            if len(parts) < 3 or not parts[0].strip() or parts[1].strip() not in DECISIONS or not parts[2].strip():
                raise ValueError(f"{path}:{n}: esperado `label<TAB>{'|'.join(DECISIONS)}<TAB>motivo`, veio {line.strip()[:80]!r}")
            if parts[0].strip() in pol:   # GUARD:policy-dup
                raise ValueError(f"{path}:{n}: label repetido: {parts[0].strip()}")
            pol[parts[0].strip()] = (parts[1].strip(), parts[2].strip())
    return pol


def plist_row(path, wrapper):
    """→ linha do plist, ou None quando ele não é RunAtLoad. Plist de forma estranha (topo que não é dicionário, Label que não é texto) levanta: quem chama lista o arquivo como ilegível."""
    d = load_plist(path)
    if not isinstance(d, dict):
        raise TypeError("o topo do plist não é um dicionário")
    if d.get("RunAtLoad") is not True:
        return None
    label = d.get("Label") or os.path.basename(path)[:-6]
    if not isinstance(label, str):
        raise TypeError("Label não é texto")
    # vazio/ilegível (sem a lista) → args=None e o job vira ILEGÍVEL no escopo; nunca "não lê Dolt"
    args = d.get("ProgramArguments")
    args = [str(a) for a in args] if isinstance(args, list) else None
    row = dict(label=label, path=path, args=args, program=d.get("Program"), keepalive=bool(d.get("KeepAlive")), interval=bool(d.get("StartInterval")),
               cal=bool(d.get("StartCalendarInterval")), link=os.path.islink(path))
    cmd = inner(args, wrapper) if args else None
    row["wrapped"] = is_wrapped(args, wrapper)
    row["inner"] = cmd
    row["scope"] = label.startswith(HQ_PREFIXES) and not OTHER_RIG.search(" ".join(args or []) + " " + str(d.get("WorkingDirectory", "")))
    row["state"], row["evid"] = "", ""
    if row["scope"]:
        row["state"], row["evid"] = measure(cmd) if cmd else ("ILEGIVEL", "ProgramArguments ausente ou embrulho que não conheço")
    return row


def scan(dirpath, wrapper):
    """→ (linhas RunAtLoad, ilegíveis [(arquivo, motivo)], total de plists). Pasta ilegível → OSError (exit 3): não sei ≠ pasta vazia. Plist que não leio OU de forma que não entendo vai para
    os ilegíveis com o motivo, e o resto do plano sai (nunca traceback, nunca some)."""
    rows, bad, total = [], [], 0
    for fn in sorted(os.listdir(dirpath)):
        if not fn.endswith(".plist"):
            continue
        total += 1
        try:
            row = plist_row(os.path.join(dirpath, fn), wrapper)
        except Exception as e:  # noqa: BLE001  GUARD:scan-guard
            bad.append((fn, type(e).__name__ + ": " + str(e)[:80]))
            continue
        if row:
            rows.append(row)
    return rows, bad, total


def divergences(rows, policy, wrapper, bad=()):
    out = []
    if bad:   # GUARD:bad-div — plist que não consegui ler pode ser o gêmeo de um label wrap ou um job já embrulhado: não sei ≠ "não existe", e aplicar às cegas é o erro
        out.append(f"{len(bad)} plist(s) não lido(s) ({', '.join(fn for fn, _ in bad[:8])}{', …' if len(bad) > 8 else ''}): pode ser o gêmeo de um label wrap ou um job já embrulhado, e não sei qual — arquive ou conserte")
    wrapped = [r for r in rows if r["wrapped"]]
    for p in sorted({r["args"][0] for r in wrapped}):   # o que o launchd roda é o argv0 do PLIST, não o --wrapper deste comando
        n = sum(r["args"][0] == p for r in wrapped)
        if p != wrapper:   # GUARD:wrapper-other-path
            out.append(f"{n} plist(s) embrulhado(s) por OUTRO caminho do wrapper: {p} (este plano usa {wrapper})")
        if not (os.path.isfile(p) and os.access(p, os.X_OK)):   # GUARD:wrapper-missing-div
            out.append(f"{n} plist(s) JÁ embrulhado(s) apontam para {p}, que não existe ou não é executável: esses jobs NÃO vão subir")
    live = {r["label"]: r for r in rows}
    files = {}
    for r in rows:
        files.setdefault(r["label"], []).append(os.path.basename(r["path"]))
    for label, fs in sorted(files.items()):
        if len(fs) > 1:   # GUARD:dup-label — o launchd só carrega um por label, e aqui não sei qual: não sei ≠ "o de nome certo"
            out.append(f"label em {len(fs)} arquivos ({', '.join(fs)}): {label} — qual deles o launchd carrega?")
    for r in rows:
        if r["scope"] and r["label"] not in policy:
            kind = ("KeepAlive " if r["keepalive"] else "") + ("I" if r["interval"] else "") + ("C" if r["cal"] else "")
            out.append(f"NÃO CLASSIFICADO (fora da política): {r['label']} [{r['state']} {kind.strip()}] {r['evid']}")
    for label, (dec, _why) in sorted(policy.items()):
        r = live.get(label)
        if r is None:
            out.append(f"política cita job sem plist RunAtLoad vivo: {label}")
        elif not r["scope"]:
            out.append(f"política cita job FORA do escopo HQ (é de outro rig): {label}")
        elif dec == "wrap" and r["state"] != "LE":
            out.append(f"wrap sem leitura medida ({r['state']}): {label}")
        elif dec == "wrap" and r["keepalive"]:   # GUARD:wrap-keepalive
            out.append(f"wrap em job KeepAlive (regra: daemon relança sozinho): {label}")
        elif dec == "wrap" and not (r["interval"] or r["cal"]):   # GUARD:no-trigger — prazo estourado (rc 75) sem gatilho só tenta de novo no próximo boot
            out.append(f"wrap sem gatilho de re-disparo: {label}")
        elif dec != "wrap" and r["wrapped"]:   # GUARD:iso-wrapped
            out.append(f"{dec} mas já embrulhado: {label}")
        elif dec == "nao-medido" and r["state"] == "LE":   # GUARD:nm-le — a premissa do nao-medido é "nenhuma chamada achada"
            out.append(f"nao-medido mas a medição achou chamada (LE): {label}")
    return out


def new_args(wrapper, timeout, boot, cmd):
    return [wrapper, "--timeout", str(timeout), "--boot-window", str(boot), "--"] + list(cmd)


def write_plist(row, args, backup_dir):
    """Reescreve ProgramArguments com backup e confere o resultado. → mensagem de erro ou None. NUNCA levanta: qualquer falha (ler, criar o backup, escrever) vira erro DESTE plist e o lote segue.
    O plist só é tocado pelo `os.replace` final (atômico): antes dele o original está intacto, e se o próprio replace falhar também."""
    path = row["path"]
    if row["link"]:   # GUARD:symlink
        return "plist é symlink (a fonte é outro arquivo); não alterei"
    bak, tmp = os.path.join(backup_dir, os.path.basename(path)), path + ".wfd-tmp"
    try:
        d = load_plist(path)
        if "Program" in d:   # GUARD:program-key
            return "tem a chave Program (o embrulho mudaria o executável); não alterei"
        if os.path.exists(bak):   # GUARD:backup-exists — já existe = o ORIGINAL de uma rodada anterior (--backup-dir reaproveitado); sobrescrever perderia o único backup do original
            return f"backup já existe em {bak} (--backup-dir reaproveitado?); não alterei"
        os.makedirs(backup_dir, exist_ok=True)
        shutil.copy2(path, bak)   # GUARD:backup
        new = dict(d)
        new["ProgramArguments"] = args
        data = plistlib.dumps(new, sort_keys=False)
        if plistlib.loads(data) != new:
            return "a releitura do plist novo não bate; não alterei"
        with open(tmp, "wb") as fh:
            fh.write(data)
        shutil.copymode(path, tmp)
        lint = subprocess.run([os.environ.get("WFD_PLUTIL", "plutil"), "-lint", tmp], capture_output=True, timeout=15)
        if lint.returncode != 0:   # GUARD:lint
            return "plutil -lint recusou o plist novo; não alterei"
        os.replace(tmp, path)
    except Exception as e:  # noqa: BLE001  GUARD:write-except
        return f"falha ao escrever ({type(e).__name__}: {str(e)[:60]}): o plist original não foi tocado"
    finally:
        try:
            os.unlink(tmp)   # já virou o plist (ou nunca nasceu) → FileNotFoundError, nada a limpar; falhou limpar → sobra o .wfd-tmp e o resultado acima não é mascarado
        except OSError:
            pass
    return None


def lib_ok(wrapper):
    """A sonda que o wrapper carrega (dolt-pid-lib.sh AO LADO dele) lê e define dolt_server_pid? Sem ela todo job embrulhado sairia 76 (inerte) no boot. Ausente/ilegível/sem a função → returncode ≠ 0 → recuso."""
    lib = os.path.join(os.path.dirname(wrapper), "dolt-pid-lib.sh")
    return subprocess.run(["/bin/bash", "-c", '. "$1" && type dolt_server_pid', "_", lib], capture_output=True).returncode == 0   # GUARD:lib-preflight


def show(rows, bad, total, policy, wrapper, a):
    scoped = [r for r in rows if r["scope"]]
    cnt = {}
    for r in scoped:
        cnt[r["state"]] = cnt.get(r["state"], 0) + 1
    by = {k: [r for r in scoped if policy.get(r["label"], ("", ""))[0] == k] for k in DECISIONS}
    print(f"wait-for-dolt-plan — {a.dir}: {total} plists, {len(rows)} com RunAtLoad, {len(scoped)} no escopo HQ, {len(rows) - len(scoped)} fora (outro rig/label), {len(bad)} ilegíveis")
    print("medido (escopo HQ): " + " · ".join(f"{k}={cnt.get(k, 0)}" for k in ("LE", "TALVEZ", "NAO-ACHEI", "ILEGIVEL")))
    print("política: " + " · ".join(f"{k}={len(v)}" for k, v in by.items()) + f" · embrulhados hoje: {sum(r['wrapped'] for r in by['wrap'])} de {len(by['wrap'])}")
    for fn, why in bad:
        print(f"ILEGÍVEL (plist não lido, fica fora da conta): {fn} — {why}")
    print(f"\n== WRAP ({len(by['wrap'])}) — --timeout {a.timeout} --boot-window {a.boot_window} ==")
    for r in by["wrap"]:
        kind = ("I" if r["interval"] else "") + ("C" if r["cal"] else "")
        print(f"{'JÁ EMBRULHADO' if r['wrapped'] else 'A EMBRULHAR  '} {r['label']} [{kind or '-'}]\n   leitura: {r['evid']}")
        if not r["wrapped"] and r["inner"]:
            print(f"   antes:  {r['inner']}\n   depois: {new_args(wrapper, a.timeout, a.boot_window, r['inner'])}")
    for k, title in (("isento", "ISENTOS"), ("nao-medido", "NÃO MEDIDOS (sem wrapper = comportamento de hoje)")):
        print(f"\n== {title} ({len(by[k])}) ==")
        for r in by[k]:
            print(f"{r['label']} [{r['state']}{', KeepAlive' if r['keepalive'] else ''}{', EMBRULHADO' if r['wrapped'] else ''}] — {policy[r['label']][1]}")
    out = [r for r in rows if not r["scope"]]
    print(f"\n== FORA DO ESCOPO ({len(out)}) — job de outro rig vira bead no rig dele ==")
    print(", ".join(r["label"] for r in out) if out else "(nenhum)")


def main(argv=None):
    ap = argparse.ArgumentParser(description="plano do wait-for-dolt nos plists vivos")
    ap.add_argument("--dir", default=os.path.expanduser("~/Library/LaunchAgents"))
    ap.add_argument("--policy", default=os.path.join(HERE, "wait-for-dolt.policy.tsv"))
    ap.add_argument("--wrapper", default=CITY + "/scripts/wait-for-dolt.sh")
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--boot-window", type=int, default=900)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--revert", action="store_true")
    ap.add_argument("--backup-dir", default=None)
    ap.add_argument("--only", action="append", default=[], metavar="LABEL", help="restringe --apply/--revert a este label (repetível); label que não existe/não é wrap = uso errado")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    if a.apply and a.revert or not (0 <= a.timeout <= 3600 and 0 <= a.boot_window <= 86400):
        print("uso errado: --apply e --revert são exclusivos; --timeout 0-3600; --boot-window 0-86400", file=sys.stderr)
        return 2
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = a.backup_dir or os.path.join(CITY, ".gc", "backups", f"wait-for-dolt-{stamp}")
    try:
        rows, bad, total = scan(a.dir, a.wrapper)
        policy = {} if a.revert else load_policy(a.policy)
    except (OSError, ValueError) as e:
        print(f"não consegui ler a entrada: {e}", file=sys.stderr)
        return 3
    known = {r["label"]: r for r in rows if r["scope"]}
    for lab in a.only:
        dec = policy.get(lab, ("ausente",))[0]
        if lab not in known or (a.apply and dec != "wrap"):   # GUARD:only-unknown — "não achei" ≠ "nada a fazer"
            print(f"uso errado: --only {lab}: " + ("não é um job RunAtLoad do escopo HQ" if lab not in known else f"a política diz {dec}, não wrap"), file=sys.stderr)
            return 2
    if a.revert:
        done = fail = 0
        for fn, why in bad:   # GUARD:revert-bad — plist que não li: não sei se está embrulhado, e isso NÃO é "nada a reverter"
            print(f"NÃO LI {fn} — {why}: não sei se está embrulhado; confira à mão"); fail += 1
        for r in rows:
            if not r["wrapped"] or (a.only and r["label"] not in a.only):
                continue
            if not r["inner"]:
                print(f"NÃO REVERTI {r['label']}: embrulho sem `--`, formato que não conheço"); fail += 1; continue
            err = write_plist(r, r["inner"], backup)
            print(f"{'ERRO ' if err else 'OK   '}{r['label']}" + (f" — {err}" if err else "")); fail += bool(err); done += not err
        print(f"revert: {done} revertido(s), {fail} falha(s); backup em {backup}; NADA foi recarregado (launchctl é passo do operador)")
        return 1 if fail else 0
    show(rows, bad, total, policy, a.wrapper, a)
    div = divergences(rows, policy, a.wrapper, bad)
    print(f"\n== DIVERGÊNCIAS ({len(div)}) ==")
    print("\n".join(div) if div else "(nenhuma)")
    if not a.apply:
        return 1 if div else 0
    if div:   # GUARD:apply-refuses-divergence
        print("\n--apply RECUSADO: há divergência entre a política e o que está vivo (nada foi escrito).", file=sys.stderr)
        return 1
    ok = os.path.isfile(a.wrapper) and os.access(a.wrapper, os.X_OK) and subprocess.run(["/bin/bash", "-n", a.wrapper], capture_output=True).returncode == 0 and lib_ok(a.wrapper)
    if not ok:   # GUARD:wrapper-preflight
        print(f"\n--apply RECUSADO: wrapper {a.wrapper} ausente, não executável, com erro de sintaxe ou sem o dolt-pid-lib.sh (com dolt_server_pid) ao lado — apontar plists para ele quebraria todos os jobs embrulhados.", file=sys.stderr)
        return 4
    todo = [r for r in rows if r["scope"] and policy[r["label"]][0] == "wrap" and not r["wrapped"] and (not a.only or r["label"] in a.only)]   # GUARD:idempotent
    done = fail = 0
    for r in todo:
        err = write_plist(r, new_args(a.wrapper, a.timeout, a.boot_window, r["inner"]), backup)
        print(f"{'ERRO ' if err else 'OK   '}{r['label']}" + (f" — {err}" if err else "")); fail += bool(err); done += not err
    print(f"\napply: {done} embrulhado(s), {fail} falha(s); backup em {backup}; NADA foi recarregado: o plist novo vale no próximo boot ou quando o operador recarregar o job")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
