#!/usr/bin/env python3
"""venv-rewrite-hook.py — hook PreToolUse (Bash): `venv/bin/python -m pytest ...` passa a ir pelo atalho de pytest (ga-7q35xn, épico ga-sokx7u).

Contents
    Por quê · O que reescreve · O que NUNCA reescreve · Resposta ao Claude Code · Log

POR QUÊ: o atalho da ga-fl2nek (pytest-shim.sh) entra pelo PATH; medido em 14 dias, 34% das rodadas de pytest de workers e crews chamam
    `venv/bin/python -m pytest` por CAMINHO EXPLÍCITO, que ignora o PATH. Um hook que reescreve o comando é a única forma mecânica de alcançá-las (não depende de o modelo
    obedecer uma instrução, que foi o que falhou com o preâmbulo da ga-yvs19w).

O QUE REESCREVE: uma palavra de COMANDO (início, depois de ; & && || | ( ou de if/then/do/while…, depois de atribuições VAR=x e de exec/time/nohup/command/env/timeout/nice/xargs)
    que seja `[caminho/]venv/bin/python[3[.x]]` — `venv`, `.venv`, `venv312`… — seguida de `[opções do python] -m pytest` (ou -mpytest), vira
    `/usr/bin/env PYTEST_SHIM_PY=<o mesmo caminho> <atalho>/bin/python3`; o resto do comando, os argumentos e o cwd ficam como estão. `env` e não `VAR=x`
    direto porque uma atribuição depois de `timeout 900` seria lida como o NOME do comando. O atalho roda o pytest com ESSE python quando o gate manda rodar aqui.

O QUE NUNCA REESCREVE: texto que só CITA o comando (aspas, comentário, mensagem de commit, grep, echo) · o CORPO de um heredoc e o interior de `$(…)`, crase ou `<(…)`
    (o lexer pula por cima: um pytest ali dentro continua como o worker digitou, e o que está FORA deles é reescrito normalmente) · palavra com expansão (`$`, `~`, `*`…) no
    caminho do python · python sem `-m pytest`. O comando INTEIRO segue como veio (Bail) quando: redirecionamento ANTES do comando, aspas/heredoc/substituição sem fechar, heredoc DENTRO de `$(…)` (contar parênteses não enxerga o corpo),
    já traz PYTEST_SHIM_PY ou GC_PYTEST_SHIM=off (o worker pediu o bypass), atalho ausente ou sem bit de execução, entrada que não é um Bash com comando em texto. Na dúvida o
    hook NÃO escreve nada: o comando de hoje roda como hoje (fail-open). Ele nunca falha o comando e sempre sai 0.

RESPOSTA AO CLAUDE CODE: só `hookSpecificOutput.updatedInput` (o tool_input INTEIRO com o campo command trocado, para não perder description/timeout). NUNCA
    `permissionDecision`: um "allow" aprovaria o comando composto inteiro (inclusive um `rm -rf` antes do pytest que hoje cai numa regra `ask`). Medido ao vivo
    (13/10, claude -p): `updatedInput` sozinho é aplicado; as regras de permissão avaliam o comando JÁ reescrito. O transcrito guarda o comando ORIGINAL
    (por isso o log abaixo: é a única prova de que a reescrita aconteceu).

LOG: uma linha por comando reescrito em $CITY/.gc/logs/pytest-venv-rewrite.jsonl ({"ts","src":"venv-rewrite","session","n","py"}). Arquivo PRÓPRIO, não o pytest-shim.jsonl:
    o coverage.py conta as linhas daquele por `ran=`. Falha ao gravar o log nunca atrapalha o comando.
"""
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SHIM_PY3 = os.path.join(HERE, "bin", "python3")
CITY = os.environ.get("PYTEST_SHIM_CITY") or os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or "/Users/athos/gt/.gascity-gastown-hq"
LOG = os.path.join(CITY, ".gc", "logs", "pytest-venv-rewrite.jsonl")

SAFE_PATH = re.compile(r"^[A-Za-z0-9_./+-]+$")
VENV_PY = re.compile(r"^/?(?:[A-Za-z0-9_.+-]+/)*\.?venv[A-Za-z0-9_-]*/bin/python[0-9.]*$")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
REDIR = re.compile(r"^[0-9]*[<>]")
STARTERS = {"if", "then", "elif", "else", "do", "while", "until", "!", "{"}
PASSTHRU = {"exec", "time", "nohup", "command"}   # palavras que ficam na frente do comando de verdade
DURATION = re.compile(r"^[0-9]+(?:\.[0-9]+)?[smhd]?$")
XARGS_WITH_VALUE = {"-n", "-I", "-P", "-L", "-s", "-d", "-E", "-a"}   # opções do xargs cujo valor vem na palavra seguinte


class Bail(Exception):
    """Algo que o hook não sabe ler com certeza: o comando passa como veio."""


def skip_subst(cmd, i):
    """cmd[i] abre `$(`, `<(` ou `>(` (i aponta para o `(`): devolve o índice logo depois do `)` que fecha, olhando aspas e parênteses aninhados. Não fecha → Bail."""
    depth, n = 0, len(cmd)
    while i < n:
        ch = cmd[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        elif ch == "'":
            i = cmd.find("'", i + 1)
            if i < 0:
                raise Bail("aspas sem fechar numa substituição")
        elif ch == '"':
            i += 1
            while i < n and cmd[i] != '"':
                i += 2 if cmd[i] == "\\" else 1
        elif ch == "\\":
            i += 1
        elif ch == "<" and cmd[i:i + 2] == "<<" and cmd[i:i + 3] != "<<<":
            # contar parênteses não enxerga o corpo de um heredoc: um `)` desbalanceado ali fecharia a substituição cedo e o resto do corpo seria lido como comando de topo
            raise Bail("heredoc dentro de substituição")
        i += 1
    raise Bail("substituição sem fechar")


def read_heredoc_delim(cmd, i):
    """cmd[i:] vem logo depois de `<<`: (delimitador sem aspas, tira_tabs, índice depois da palavra)."""
    n = len(cmd)
    strip = i < n and cmd[i] == "-"
    if strip:
        i += 1
    while i < n and cmd[i] in " \t":
        i += 1
    j, delim = i, ""
    while j < n and cmd[j] not in " \t\n;|&()<>":
        if cmd[j] in "'\"\\":
            j += 1
            continue
        delim += cmd[j]; j += 1
    if not delim:
        raise Bail("heredoc sem delimitador")
    return delim, strip, j


def lex(cmd):
    """[(texto, início, fim, simples, tipo)] — `simples` = palavra sem aspas, escape nem expansão; tipo 'word' ou 'op'. Corpo de heredoc, `$(…)`, crase e `<(…)`
    ficam DENTRO da palavra que os contém (ou são pulados), nunca viram comando. Qualquer coisa fora do que sabemos ler levanta Bail (nunca um chute)."""
    out, i, n, pending = [], 0, len(cmd), []
    while i < n:
        c = cmd[i]
        if c in " \t":
            i += 1
        elif c == "\n":
            out.append((";", i, i + 1, True, "op")); i += 1
            for delim, strip in pending:     # o corpo de cada heredoc pendente começa na linha seguinte e vai até a linha que é só o delimitador
                while True:
                    if i >= n:
                        raise Bail("heredoc sem fechar")
                    eol = cmd.find("\n", i)
                    eol = n if eol < 0 else eol
                    ln = cmd[i:eol].lstrip("\t") if strip else cmd[i:eol]
                    i = min(eol + 1, n)
                    if ln == delim:
                        break
            pending = []
        elif c == "\\" and i + 1 < n and cmd[i + 1] == "\n":
            i += 2
        elif c == "#":
            while i < n and cmd[i] != "\n":
                i += 1
        elif c in ";|&()":
            j = i + 1
            if c in "|&" and j < n and cmd[j] == c:
                j += 1
            elif c == "|" and j < n and cmd[j] == "&":
                j += 1
            out.append((cmd[i:j], i, j, True, "op")); i = j
        else:
            start, simple = i, True
            while i < n and cmd[i] not in " \t\n;|()":
                ch = cmd[i]
                if ch == "&":
                    # `>&`, `&>`, `2>&1` são redirecionamento (parte da palavra); um & sozinho separa comandos
                    if (i > start and cmd[i - 1] in "<>") or (i + 1 < n and cmd[i + 1] == ">"):
                        i += 1; simple = False; continue
                    break
                if ch in "'\"":
                    simple = False
                    q = ch; i += 1
                    while i < n and cmd[i] != q:
                        if q == '"' and cmd[i] == "\\":
                            i += 1
                        elif q == '"' and cmd[i:i + 2] == "$(":
                            i = skip_subst(cmd, i + 1) - 1
                        i += 1
                    if i >= n:
                        raise Bail("aspas sem fechar")
                    i += 1
                elif ch == "\\":
                    simple = False; i += 2
                elif ch == "`":
                    simple = False
                    i = cmd.find("`", i + 1)
                    if i < 0:
                        raise Bail("crase sem fechar")
                    i += 1
                elif ch in "$<>" and cmd[i + 1:i + 2] == "(":
                    simple = False; i = skip_subst(cmd, i + 1)
                elif ch == "<" and cmd[i:i + 2] == "<<" and cmd[i:i + 3] != "<<<":
                    simple = False
                    delim, strip, i = read_heredoc_delim(cmd, i + 2)
                    pending.append((delim, strip))
                elif ch in "$*?[]{}~<>":
                    simple = False; i += 1
                else:
                    i += 1
            if i == start:
                raise Bail("caractere que não sei ler")
            out.append((cmd[start:i], start, i, simple, "word"))
    if pending:
        raise Bail("heredoc sem corpo")
    return out


def py_args_are_pytest(words):
    """As opções do INTERPRETADOR até `-m pytest` (mesma leitura do pytest-shim.sh py_pytest_skip): True só se o primeiro argumento que não é opção do python é `-m pytest`."""
    k = 0
    while k < len(words):
        w = words[k]
        if w == "-m":
            return k + 1 < len(words) and words[k + 1] == "pytest"
        if w == "-mpytest":
            return True
        if w == "-c" or w.startswith("-c"):
            return False
        if w in ("-W", "-X", "--check-hash-based-pycs"):
            if k + 1 >= len(words):
                return False
            k += 2
        elif w.startswith("-") and len(w) > 1:
            k += 1
        else:
            return False
    return False


def rewrite(cmd, shim_py3):
    """(comando novo, caminhos reescritos). Sem nada a reescrever: (cmd, [])."""
    if "pytest" not in cmd:
        return cmd, []
    toks = lex(cmd)
    spans, expecting, i = [], True, 0
    while i < len(toks):
        text, s, e, simple, kind = toks[i]
        if kind == "op":
            expecting = text != ")"
            i += 1
            continue
        if not expecting:
            i += 1
            continue
        if REDIR.match(text):
            raise Bail("redirecionamento antes do comando")
        if ASSIGN.match(text):
            if text.startswith("PYTEST_SHIM_PY=") or text == "GC_PYTEST_SHIM=off":
                raise Bail("o comando já tem PYTEST_SHIM_PY ou pediu o bypass")
            i += 1
            continue
        if simple and text in STARTERS | PASSTHRU:
            i += 1
            continue
        if simple and text in ("env", "nice", "timeout", "xargs"):
            i += 1
            while i < len(toks) and toks[i][4] == "word":
                t = toks[i][0]
                if text == "env" and (ASSIGN.match(t) or t.startswith("-")):
                    if t.startswith("PYTEST_SHIM_PY=") or t == "GC_PYTEST_SHIM=off":
                        raise Bail("o comando já tem PYTEST_SHIM_PY ou pediu o bypass")
                    i += 1; continue
                if text == "nice" and (t.startswith("-") or (i > 0 and toks[i - 1][0] == "-n" and t.isdigit())):
                    i += 1; continue
                if text == "xargs":
                    if t.startswith("-"):
                        i += 2 if t in XARGS_WITH_VALUE else 1
                        continue
                    break
                if text == "timeout":
                    if t.startswith("-"):
                        i += 2 if t in ("-k", "-s") else 1
                        continue
                    if DURATION.match(t):
                        i += 1
                    break
                break
            continue
        # palavra de comando de verdade
        if simple and VENV_PY.match(text) and SAFE_PATH.match(text):
            args = []
            j = i + 1
            while j < len(toks) and toks[j][4] == "word":
                args.append(toks[j][0]); j += 1
            if py_args_are_pytest(args):
                spans.append((s, e, text))
        expecting = False
        i += 1
    if not spans:
        return cmd, []
    new = cmd
    for s, e, text in reversed(spans):
        new = new[:s] + f"/usr/bin/env PYTEST_SHIM_PY={text} {shim_py3}" + new[e:]
    return new, [t for _, _, t in spans]


def log_rewrite(paths):
    # vazio → nada a gravar (não chega aqui); falhou/ilegível (disco, permissão) → o comando segue reescrito e a linha some: fail-open de propósito, o coverage.py
    # compara este log com os transcritos e a diferença aparece lá
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        row = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "src": "venv-rewrite",
               "session": os.environ.get("GC_SESSION_NAME", ""), "n": len(paths), "py": paths[0]}
        with open(LOG, "a") as fh:
            fh.write(json.dumps(row) + "\n")
    except Exception:
        pass


def main():
    # vazio (stdin vazio) e ilegível (não é JSON, não é objeto) → sem saída, rc 0: o comando segue como veio
    try:
        d = json.load(sys.stdin)
    except Exception:
        return 0
    if not isinstance(d, dict) or d.get("tool_name") != "Bash":
        return 0
    ti = d.get("tool_input")
    cmd = ti.get("command") if isinstance(ti, dict) else None
    if not isinstance(cmd, str) or not cmd:
        return 0
    if not (SAFE_PATH.match(SHIM_PY3) and os.path.isfile(SHIM_PY3) and os.access(SHIM_PY3, os.X_OK)):
        return 0
    try:
        new, paths = rewrite(cmd, SHIM_PY3)
    except Bail:
        return 0
    except Exception:
        return 0
    if not paths or new == cmd:
        return 0
    out = dict(ti)
    out["command"] = new
    sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "updatedInput": out}}))
    sys.stdout.flush()
    log_rewrite(paths)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BaseException:
        sys.exit(0)
