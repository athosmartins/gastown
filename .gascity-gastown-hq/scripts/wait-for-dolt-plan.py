#!/usr/bin/env python3
"""wait-for-dolt-plan.py — quais jobs do HQ recebem o wait-for-dolt.sh, medido nos plists VIVOS (ga-sh8t23.2; revisão de arquitetura 15/10).

Contents
  Para que serve · Como decide · Uso · Três estados · Códigos · Limites

PARA QUE SERVE
  A bead pede "a lista dos jobs que leem Dolt no boot é MEDIDA (programa de cada RunAtLoad), não adivinhada, e cada plist alterado mostra o antes/depois". Este comando lê
  ~/Library/LaunchAgents (o que o launchd carregou — fonte ≠ o que roda: só 17 dos 115 plists com label HQ têm cópia no repositório, 98 existem só ali), mede o que o programa
  de cada RunAtLoad do escopo HQ faz com bd/gc/dolt, cruza com a política revisada (wait-for-dolt.policy.tsv: decisão + motivo por job) e mostra o que mudaria. Sem --apply é
  SÓ LEITURA. Nunca chama launchctl: recarregar job é o passo de ativação (runbook), com canário, e é de quem coordena a cidade.

COMO DECIDE (a medição é a evidência; a decisão é da política, que o plano confere contra a medição a cada execução)
  escopo   label com.gascity.* ou com.gastown.* cujo programa NÃO vive na árvore de outro rig (esses viram bead no rig dele). RunAtLoad=true.
  medição  LÊ = o programa tem uma CHAMADA a bd/gc/dolt (posição de comando, ou subprocess ["bd", ...]; linha de log/comentário não conta) · TALVEZ = só menção solta ·
           NÃO ACHEI = programa legível sem menção · ILEGÍVEL = não consegui ler o programa (inclui script executado direto ou citado no `-c` que não existe). Segue o programa e os .sh/.py com caminho absoluto dentro de um `-c`; NÃO segue
           script chamado por script (um job que lê o Dolt por dentro de outro script aparece como TALVEZ/NÃO ACHEI, e ficar sem wrapper é o comportamento de hoje).
  política wrap (embrulha) · isento (precisa rodar com o Dolt fora, ou tem ato útil que não precisa dele, ou é KeepAlive) · nao-medido (sem leitura medida). Na dúvida: isento.

USO   wait-for-dolt-plan.py [--dir D] [--policy F] [--wrapper W] [--timeout S] [--boot-window S] [--apply | --revert] [--backup-dir B] [--only LABEL ...]
  padrão: --dir ~/Library/LaunchAgents · --policy ao lado do script · --wrapper $GC_CITY_PATH/scripts/wait-for-dolt.sh · --timeout 300 · --boot-window 900.
  --apply  grava (com backup do original) o ProgramArguments `[W, --timeout S, --boot-window B, --, <comando original>...]` nos jobs `wrap` que ainda não estão embrulhados. Recusa
           (nada é escrito) com divergência de política, wrapper ausente/não executável/com sintaxe ruim, ou plist symlink/com chave Program. Os comentários XML do plist
           não sobrevivem à reescrita; o backup guarda o original. NÃO recarrega o job: vale no próximo boot ou quando o operador recarregar.
  --revert tira o prefixo de todo plist RunAtLoad embrulhado (qualquer um, não só os da política), também com backup. Idempotente.
  --only L restringe --apply/--revert ao label L (repetível): é o canário. Label que não existe no escopo, ou (no --apply) que a política não marca wrap, é uso errado (exit 2).

TRÊS ESTADOS  plist ilegível aparece com o motivo (nunca some); programa ilegível é ILEGÍVEL (≠ NÃO ACHEI); política ilegível/duplicada → exit 3 sem plano (não chuto decisão).
  Divergência (job do escopo fora da política · wrap sem LÊ · wrap em KeepAlive · política cita job que não existe/é de fora · label em 2 arquivos · plist já embrulhado cujo
  wrapper sumiu ou não executa) → exit 1: o plano é impresso mas --apply recusa. Rodar o plano de tempos em tempos é o detector do último caso (job embrulhado que não sobe).

CÓDIGOS  0 plano/aplicação feitos, sem divergência · 1 divergência ou falha ao escrever · 2 uso errado · 3 não consegui ler a entrada · 4 --apply recusado (wrapper).
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
# chamada em posição de comando (início, ; & | ( ` $( then do !), com prefixos comuns (timeout N, env, VAR=x) e o binário por caminho ou por variável conhecida
_CMDPOS = r"(?:^|[;&|(`]|\$\(|\bthen\b|\bdo\b|!)\s*(?:(?:timeout\s+\S+\s+|env\s+|command\s+|exec\s+|nice\s+|(?:bash|sh)\s+|\w+=\S*\s+)*)"
_BIN = r"(?:(?:\"?\$\{?\w+\}?\"?/|[\w./-]*/)?\"?(?:bd|gc|dolt)\"?|\"?\$\{?(?:BD|GC|DOLT|BD_BIN|GC_BIN|bd_bin|gc_bin|BD_LIST_CACHED)\}?\"?)"
SH_STRONG = re.compile(_CMDPOS + _BIN + r"(?=\s|$)(?!-)")
LOGCMD = re.compile(r"^\s*(echo|printf|log|warn|info|die|fail|err|note|emit\w*|_log\w*|notify)\b")
PY_STRONG = re.compile(r"""\[\s*["'](?:bd|gc|dolt)["']\s*[,\]]|\[\s*(?:GC|BD|GC_BIN|BD_BIN)\s*,|\bpymysql\.connect|mysql\.connector\.connect""")
WEAK = re.compile(r"(?<![\w./$-])(?:bd|gc|dolt)(?![\w/-])")   # `.gc/logs`, `$GC_CITY`, `dolt-pid-lib.sh` não são menção
# só ordena a EVIDÊNCIA mostrada (a linha com subcomando de verdade vence a que é texto de log); não decide LÊ
_SUB = r"(?:list|show|update|close|query|ready|create|comment|label|config|reopen|session|mail|rig|dolt|bd|nudge|agent|events|suspend|resume|reload|supervisor|sql|status|restart)"
SUB_SH = re.compile(r"(?:bd|gc|dolt|\$\{?(?:BD|GC|DOLT|BD_BIN|GC_BIN|bd_bin|gc_bin|BD_LIST_CACHED)\}?)\"?\s+(?:(?:-C|--city)\s+\S+\s+)*" + _SUB + r"\b")
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
            if (PY_STRONG if py else SH_STRONG).search(code) and not (not py and LOGCMD.match(code)):
                calls += 1
                strong = strong or f"{name}:{i}: {s[:100]}"
                # evidência = a linha que mais parece chamada de verdade (subcomando + 2>/dev/null, $(...), || ou &&); empate → a primeira. Texto de ajuda dentro de string multilinha não tem isso.
                rank = 2 * bool((SUB_PY if py else SUB_SH).search(code)) + bool(re.search(r"2>|>/dev/null|\$\(|\|\||&&|capture_output|subprocess", line))
                if rank > best_rank:
                    best, best_rank = f"{name}:{i}: {s[:100]}", rank
            elif not weak and WEAK.search(line):
                weak = f"{name}:{i}: {s[:100]}"
    if strong:
        return "LE", (best or strong) + (f"  (+{calls - 1} linhas de chamada)" if calls > 1 else "  (1 linha de chamada)")
    if weak:
        return "TALVEZ", weak
    if unreadable or not srcs:
        return "ILEGIVEL", "nenhum arquivo de programa legível"
    return "NAO-ACHEI", ""


def inner(args, wrapper):
    """O comando original de um ProgramArguments já embrulhado (o que vem depois do `--`); não embrulhado → o próprio args. Embrulhado sem `--` → None (formato que não conheço)."""
    if not args or args[0] != wrapper:
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


def scan(dirpath, wrapper):
    """→ (linhas RunAtLoad, ilegíveis [(arquivo, motivo)], total de plists). Pasta ilegível → OSError (exit 3): não sei ≠ pasta vazia."""
    rows, bad, total = [], [], 0
    for fn in sorted(os.listdir(dirpath)):
        if not fn.endswith(".plist"):
            continue
        total += 1
        path = os.path.join(dirpath, fn)
        try:
            d = load_plist(path)
        except Exception as e:  # noqa: BLE001
            bad.append((fn, type(e).__name__ + ": " + str(e)[:80]))
            continue
        if d.get("RunAtLoad") is not True:
            continue
        label = d.get("Label") or fn[:-6]
        # vazio/ilegível (sem a lista) → args=None e o job vira ILEGÍVEL no escopo; nunca "não lê Dolt"
        args = d.get("ProgramArguments")
        args = [str(a) for a in args] if isinstance(args, list) else None
        row = dict(label=label, path=path, args=args, program=d.get("Program"), keepalive=bool(d.get("KeepAlive")), interval=bool(d.get("StartInterval")),
                   cal=bool(d.get("StartCalendarInterval")), link=os.path.islink(path))
        cmd = inner(args, wrapper) if args else None
        row["wrapped"] = bool(args) and args[0] == wrapper
        row["inner"] = cmd
        row["scope"] = label.startswith(HQ_PREFIXES) and not OTHER_RIG.search(" ".join(args or []) + " " + str(d.get("WorkingDirectory", "")))
        row["state"], row["evid"] = "", ""
        if row["scope"]:
            row["state"], row["evid"] = measure(cmd) if cmd else ("ILEGIVEL", "ProgramArguments ausente ou embrulho que não conheço")
        rows.append(row)
    return rows, bad, total


def divergences(rows, policy, wrapper):
    out = []
    wrapped = [r for r in rows if r["wrapped"]]
    if wrapped and not (os.path.isfile(wrapper) and os.access(wrapper, os.X_OK)):   # GUARD:wrapper-missing-div
        out.append(f"{len(wrapped)} plist(s) JÁ embrulhado(s) apontam para {wrapper}, que não existe ou não é executável: esses jobs NÃO vão subir")
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
    return out


def new_args(wrapper, timeout, boot, cmd):
    return [wrapper, "--timeout", str(timeout), "--boot-window", str(boot), "--"] + list(cmd)


def write_plist(row, args, backup_dir):
    """Reescreve ProgramArguments com backup e confere o resultado; qualquer falha restaura o original. → mensagem de erro ou None."""
    path = row["path"]
    if row["link"]:   # GUARD:symlink
        return "plist é symlink (a fonte é outro arquivo); não alterei"
    d = load_plist(path)
    if "Program" in d:   # GUARD:program-key
        return "tem a chave Program (o embrulho mudaria o executável); não alterei"
    os.makedirs(backup_dir, exist_ok=True)
    bak = os.path.join(backup_dir, os.path.basename(path))
    shutil.copy2(path, bak)   # GUARD:backup
    new = dict(d)
    new["ProgramArguments"] = args
    data = plistlib.dumps(new, sort_keys=False)
    tmp = path + ".wfd-tmp"
    try:
        if plistlib.loads(data) != new:
            return "a releitura do plist novo não bate; não alterei"
        with open(tmp, "wb") as fh:
            fh.write(data)
        shutil.copymode(path, tmp)
        lint = subprocess.run([os.environ.get("WFD_PLUTIL", "plutil"), "-lint", tmp], capture_output=True, timeout=15)
        if lint.returncode != 0:   # GUARD:lint
            return "plutil -lint recusou o plist novo; não alterei"
        os.replace(tmp, path)
    except (OSError, subprocess.SubprocessError, ValueError) as e:
        if os.path.exists(bak):
            shutil.copy2(bak, path)
        return f"falha ao escrever ({type(e).__name__}): original restaurado"
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return None


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
    div = divergences(rows, policy, a.wrapper)
    print(f"\n== DIVERGÊNCIAS ({len(div)}) ==")
    print("\n".join(div) if div else "(nenhuma)")
    if not a.apply:
        return 1 if div else 0
    if div:   # GUARD:apply-refuses-divergence
        print("\n--apply RECUSADO: há divergência entre a política e o que está vivo (nada foi escrito).", file=sys.stderr)
        return 1
    ok = os.path.isfile(a.wrapper) and os.access(a.wrapper, os.X_OK) and subprocess.run(["/bin/bash", "-n", a.wrapper], capture_output=True).returncode == 0
    if not ok:   # GUARD:wrapper-preflight
        print(f"\n--apply RECUSADO: wrapper {a.wrapper} ausente, não executável ou com erro de sintaxe — apontar plists para ele quebraria todos os jobs embrulhados.", file=sys.stderr)
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
