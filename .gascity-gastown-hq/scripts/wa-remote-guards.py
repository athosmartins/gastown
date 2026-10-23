#!/usr/bin/env python3
"""wa-remote-guards.py — G12, G6, G7 e G7b do pre-push do WA, rodados NO MINI sobre os OBJETOS do sha que o nó empurrou (ga-2hd02v.3.11).

Contents
  O que é · Por que não roda o hook · Como roda, em ordem · O que não faz · Códigos de saída · Uso

O QUE É
  O gate-done-remote.py (ga-2hd02v.3.10) entrega a bead remota do WA ao gate SEM o pre-push do rig: o hook executa ~12 scripts da ÁRVORE empurrada, e nenhum código do nó pode
  rodar no mini antes da revisão. Sobrou a brecha de a bead chegar ao gate sem NENHUM guard. Este executável fecha a parte que importa mais, na ordem que o Mayor decidiu
  (ga-2hd02v.3.11, opção 2): G12 (daemon agendado que gasta dinheiro sem aprovação: decisão wa-qig1q), G6 (registro MDS), G7 (ntfy direto), G7b (ação do notify).

POR QUE NÃO RODA O HOOK
  Rodar os guards do worktree dava PASS falso (liam os dados do main, não do sha) e rodar os do sha executava código do nó. Aqui o CÓDIGO é sempre o de confiança (os mesmos
  arquivos em `origin/main` do rig, já revisados pelo gate) e os DADOS são os objetos do sha, lidos com git e gravados como arquivos inertes: nada do que veio do nó é importado,
  executado nem seguido (symlink). Um push que muda o próprio guard é checado pelo guard antigo; o diff do guard é do revisor.

COMO RODA, EM ORDEM (passo que não consegue saber algo para sem dizer "passou": "não sei" nunca vira "pode")
  1. Confere o sha (um commit do rig) e resolve `origin/main` UMA vez: esse commit é a CONFIANÇA (de onde vêm os guards) e a base do diff (`origin/main...sha`, como o `origin/main...HEAD` do hook).
  2. Lê a árvore do sha (`git ls-tree -r`) e exporta, como arquivos regulares 0600 sob `<scratch>/tree`, só o que os guards leem: *.py, *.sh, *.plist, scripts/notify e
     lib/mds_consumers.d/*.json. Symlink nesses caminhos, arquivo maior que 8 MB, caminho com `..`/`.git`, colisão de nome (macOS não distingue maiúscula) ou pouco disco → "não sei".
  3. Carrega os arquivos de confiança de `origin/main` em memória (lib/launchd_paid_guard.py, scripts/check_mds_registry_guard.py, lib/mds_consumer_registry.py, scripts/check_ntfy_bypass_guard.py,
     scripts/check_notify_action_prefix_guard.py) e aponta a raiz deles para a exportação. Chama o `check()` de cada guard, NUNCA o `main()` (o main de G6 e G7 devolve 0 se der exceção:
     "fail OPEN"). O `subprocess` do módulo é trocado por um que só entende `git diff --name-only … A...B` e `git ls-files -z -- *.plist` e que RECUSA (em vez de devolver lista vazia) quando o git falha.
  4. G12: o registro de aprovações vem do sha (a mudança dele É a aprovação), lido por `ast` sem executar: o módulo só pode ter docstring e UMA atribuição de um dict literal com chaves str.
  5. Imprime uma linha por guard e, no fim, `wa-remote-guards: RESULT=PASS|BLOCKED|UNKNOWN sha=… trusted=…`: sem essa linha o chamador não aceita um rc 0.

O QUE NÃO FAZ
  Não roda as suítes pytest, G1, G2, G8, mockup, templates Jinja nem os avisos: seguem só como AVISO no self_audit do marcador. Não faz fetch (a confiança é o `origin/main` que o rig tem agora;
  o relatório diz qual). Não honra GT_SKIP_*: a sessão remota não monta esse ambiente e um bypass não é decisão dela. Não apaga o `--scratch` (quem o criou o recolhe); sem `--scratch` usa um
  temporário próprio e o remove ao sair. Um plist que o scanner não consegue ler continua "passa" (contrato do scanner) com AVISO e contagem, MAS só se este sha não o acrescenta nem o altera: alterado e ilegível é "não sei".

CÓDIGOS DE SAÍDA
  0 os quatro passaram (ou G7b não se aplica: sem scripts/notify na árvore) · 1 algum BLOQUEOU (o relatório diz qual e o que fazer) · 2 não consegui saber (uso, git, árvore, guard de confiança ausente
  ou com forma outra): trate como recusa, nunca como passou.

USO
  wa-remote-guards.py --repo <repositório git do rig> --sha <40 hex> [--scratch <pasta>] [--trusted-ref refs/remotes/origin/main]
"""
from __future__ import annotations

import argparse
import ast
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import types
from pathlib import Path
from typing import NamedTuple

SHA_RE = re.compile(r"[0-9a-f]{40}")
GIT_TIMEOUT = 120  # um git que pendura não segura a submissão para sempre (o wrapper corta tudo em timeout_s); o dos guards, 10 s, devolvia "lista vazia" sob carga
MAX_BLOB = 8 * 1024 * 1024  # o maior .py/.sh/.plist do WA hoje tem 1,2 MB: acima de 8 MB não leio (nem finjo ter lido)
MAX_TOTAL = 400 * 1024 * 1024
DISK_MARGIN = 512 * 1024 * 1024  # o piso do disco do mini é apertado (ga-vln2py): a exportação não pode comer a margem
BATCH = 400  # blobs por `git cat-file --batch`
TRUSTED_REF = "refs/remotes/origin/main"
REGISTRY_NAME = "APPROVED_SCHEDULED_PAID_DAEMONS"
REGISTRY_PATH = "lib/approved_scheduled_paid_daemons.py"
NOTIFY_PATH = "scripts/notify"
MDS_DIR = "lib/mds_consumers.d/"
# o que cada guard carrega do checkout de CONFIANÇA (origin/main). Um `lib.*` que o guard passe a importar e não esteja aqui NÃO é achado na árvore empurrada: o import falha e vira "não sei".
TRUSTED_FILES = {
    "g12": ("lib/launchd_paid_guard.py", "lib.launchd_paid_guard"),
    "g6reg": ("lib/mds_consumer_registry.py", "lib.mds_consumer_registry"),
    "g6": ("scripts/check_mds_registry_guard.py", "wa_trusted.check_mds_registry_guard"),
    "g7": ("scripts/check_ntfy_bypass_guard.py", "wa_trusted.check_ntfy_bypass_guard"),
    "g7b": ("scripts/check_notify_action_prefix_guard.py", "wa_trusted.check_notify_action_prefix_guard"),
}


class Unknown(Exception):
    """Não consegui saber: nunca vira "passou" (rc 2)."""


class Entry(NamedTuple):
    mode: str
    oid: str
    size: int
    path: str


def say(msg: str) -> None:
    print(f"wa-remote-guards: {msg}", flush=True)


def safe(s) -> str:
    """Texto de nome de arquivo/Label que veio do nó, sem caractere de controle (escape de terminal) nem surrogate: ele vai parar no log e no terminal do revisor."""
    return re.sub(r"[^\x20-\x7e¡-퟿-￿]", "?", str(s))[:300]


def git(repo: str, *args: str, inp: bytes = None, timeout: int = GIT_TIMEOUT) -> bytes:
    # vazio → devolve b"" (quem chama decide se vazio é resposta); falhou (rc != 0, timeout, git ausente) → Unknown com o motivo: nunca vira saída vazia
    cmd = ["git", "-C", repo] + list(args)
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_REPLACE_OBJECTS": "1"}
    try:
        r = subprocess.run(cmd, input=inp, capture_output=True, timeout=timeout, env=env)
    except (OSError, subprocess.SubprocessError) as e:
        raise Unknown(f"git {args[0] if args else ''}: {type(e).__name__}: {e}")
    if r.returncode != 0:
        raise Unknown(f"git {' '.join(args[:3])}: rc={r.returncode}: {safe(r.stderr.decode('utf-8', 'replace').strip())[:160]}")
    return r.stdout


def commit_of(repo: str, ref: str) -> str:
    out = git(repo, "rev-parse", "--verify", "-q", f"{ref}^{{commit}}").decode().strip()
    if not SHA_RE.fullmatch(out):
        raise Unknown(f"{ref!r} não resolveu para um commit")
    return out


def wanted(path: str) -> bool:
    """O que os guards leem. Outra coisa da árvore nem é lida."""
    return path.endswith((".py", ".sh", ".plist")) or path == NOTIFY_PATH or (path.startswith(MDS_DIR) and path.endswith(".json"))


def tree_entries(repo: str, sha: str) -> list:
    # vazio (árvore sem arquivo) → lista vazia, e o relatório diz 0 plists; falhou/ilegível (git rc != 0, linha fora do formato) → Unknown
    raw = git(repo, "ls-tree", "-r", "-z", "-l", sha)
    out = []
    for rec in raw.split(b"\0"):
        if not rec:
            continue
        try:
            meta, path = rec.split(b"\t", 1)
            mode, typ, oid, size = meta.decode().split(None, 3)
            out.append(Entry(mode, oid, 0 if size.strip() == "-" else int(size), os.fsdecode(path)))
        except ValueError:
            raise Unknown(f"linha do ls-tree fora do formato: {safe(os.fsdecode(rec))[:80]!r}")
    return out


def check_path(path: str) -> None:
    parts = path.split("/")
    if path.startswith("/") or "\0" in path or any(p in ("", ".", "..", ".git") for p in parts):
        raise Unknown(f"caminho que não exporto: {safe(path)!r}")


def export_tree(repo: str, entries: list, root: Path) -> dict:
    """Grava como arquivos inertes só o que os guards leem. Devolve contagens. Qualquer coisa que impeça uma leitura fiel → Unknown (a exportação incompleta daria PASS por ausência)."""
    todo = []
    for e in entries:
        if not wanted(e.path):
            continue
        check_path(e.path)
        if e.mode == "160000":  # submódulo: o hook também não o vê num checkout sem `submodule update`
            continue
        if e.mode == "120000":
            raise Unknown(f"symlink em {safe(e.path)!r}: seguir o link leria fora da árvore, e não seguir esconderia o alvo")
        if e.mode not in ("100644", "100755"):
            raise Unknown(f"modo {e.mode} em {safe(e.path)!r}")
        if e.size > MAX_BLOB:
            raise Unknown(f"{safe(e.path)!r} tem {e.size} bytes (> {MAX_BLOB}): não leio o que não consigo ler inteiro")
        todo.append(e)
    total = sum(e.size for e in todo)
    if total > MAX_TOTAL:
        raise Unknown(f"{total} bytes a exportar (> {MAX_TOTAL})")
    # vazio (disco sem espaço) não existe: shutil.disk_usage ou devolve o número ou levanta; falhou → Unknown
    try:
        free = shutil.disk_usage(root.parent).free
    except OSError as e:
        raise Unknown(f"não li o espaço em disco de {root.parent} ({type(e).__name__})")
    if free < total + DISK_MARGIN:
        raise Unknown(f"disco com {free // 1048576} MB livres para exportar {total // 1048576} MB (margem {DISK_MARGIN // 1048576} MB)")
    try:
        root.mkdir(parents=True, exist_ok=False, mode=0o700)  # exist_ok=False: uma exportação que sobrou de outra execução não se mistura com esta
    except OSError as e:
        raise Unknown(f"não criei {root} ({type(e).__name__}): sobra de outra execução ou pasta ilegível")
    for i in range(0, len(todo), BATCH):
        chunk = todo[i:i + BATCH]
        # vazio (chunk sem blob) não ocorre; falhou/ilegível (objeto ausente, cabeçalho fora do formato, tamanho que não bate) → Unknown
        raw = git(repo, "cat-file", "--batch", inp=("".join(e.oid + "\n" for e in chunk)).encode())
        pos = 0
        for e in chunk:
            nl = raw.find(b"\n", pos)
            head = raw[pos:nl].split() if nl >= 0 else []
            if len(head) != 3 or head[0].decode() != e.oid or head[1] != b"blob":
                raise Unknown(f"cat-file não devolveu o blob de {safe(e.path)!r}")
            size = int(head[2])
            data = raw[nl + 1:nl + 1 + size]
            if len(data) != size or size != e.size:
                raise Unknown(f"blob de {safe(e.path)!r} veio com {len(data)} bytes, esperava {e.size}")
            pos = nl + 1 + size + 1
            dest = root / e.path
            try:
                dest.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)  # O_EXCL: dois caminhos que colidem (macOS) não se sobrescrevem em silêncio
                with os.fdopen(fd, "wb") as fh:
                    fh.write(data)
            except OSError as ex:
                raise Unknown(f"não gravei {safe(e.path)!r} ({type(ex).__name__}): colisão de nome ou disco")
    return {"files": len(todo), "bytes": total}


def load_trusted(repo: str, tsha: str, key: str, scratch: Path) -> types.ModuleType:
    """Carrega UM arquivo de `origin/main` em memória. Nada do sha empurrado entra no sys.path: o `lib` é um pacote vazio de mentira, então `from lib.x import y` só acha o que está em sys.modules."""
    rel, name = TRUSTED_FILES[key]
    # vazio (arquivo ausente no commit de confiança) → Unknown "guard de confiança ausente"; falhou/ilegível (git, não UTF-8, exceção ao carregar) → Unknown
    try:
        text = git(repo, "cat-file", "blob", f"{tsha}:{rel}").decode("utf-8")
    except UnicodeDecodeError:
        raise Unknown(f"{rel} em {tsha[:12]} não é UTF-8")
    mod = types.ModuleType(name)
    mod.__file__ = str(scratch / "trusted" / rel)  # caminho de mentira (a pasta não existe): só dá a raiz que o guard calcula por __file__, e o atalho a sobrescreve
    saved = list(sys.path)
    try:
        exec(compile(text, mod.__file__, "exec"), mod.__dict__)
    except (Exception, SystemExit) as e:
        raise Unknown(f"o guard de confiança {rel} não carregou ({type(e).__name__}: {safe(e)[:120]})")
    finally:
        sys.path[:] = saved  # o check_mds_registry_guard.py faz sys.path.insert(0, <raiz>)
    if name.startswith("lib."):
        sys.modules[name] = mod
    return mod


def need(mod: types.ModuleType, *names: str) -> None:
    missing = [n for n in names if not hasattr(mod, n)]
    if missing:
        raise Unknown(f"{mod.__name__} mudou de forma (falta {', '.join(missing)}): atualize wa-remote-guards.py junto com o guard")


class GitFacade:
    """Substituto do módulo `subprocess` DENTRO de um guard de confiança. Só aceita os dois comandos git que os guards fazem hoje, roda-os no rig (não no cwd de mentira) com timeout nosso, e levanta
    Unknown quando o git falha: o guard trata CalledProcessError/TimeoutExpired/OSError como "lista vazia" (= passou), então a exceção NÃO pode ser dessas classes."""
    CalledProcessError = subprocess.CalledProcessError
    TimeoutExpired = subprocess.TimeoutExpired

    def __init__(self, repo: str, rng: str, plists: list):
        self.repo, self.rng, self.plists = repo, rng, plists

    def run(self, argv, **kw):
        a = [str(x) for x in argv]
        is_diff = a[:3] == ["git", "diff", "--name-only"] and a[3:] in ([self.rng], ["--diff-filter=A", self.rng])  # G7: `--name-only RANGE`; G6: `--name-only --diff-filter=A RANGE`
        is_ls_files = len(a) == 7 and a[:2] == ["git", "-C"] and a[3:] == ["ls-files", "-z", "--", "*.plist"]  # G12: all_repo_plists() → _tracked_plists_via_git()
        if is_diff:
            out = git(self.repo, "-c", "core.quotepath=false", "diff", "--no-ext-diff", "--no-textconv", *a[2:])
            return subprocess.CompletedProcess(a, 0, out.decode("utf-8") if kw.get("text") else out, "" if kw.get("text") else b"")
        if is_ls_files:
            out = b"".join(p.encode("utf-8", "surrogateescape") + b"\0" for p in self.plists)
            return subprocess.CompletedProcess(a, 0, out.decode("utf-8", "surrogateescape") if kw.get("text") else out, "" if kw.get("text") else b"")
        raise Unknown(f"o guard pediu um comando que o atalho não prevê: {safe(' '.join(a))[:100]}")


def registry_labels(text: str) -> set:
    """Os Labels aprovados, lidos de `lib/approved_scheduled_paid_daemons.py` do SHA sem executá-lo. Só aceito docstring + `from __future__` + UMA atribuição `APPROVED_SCHEDULED_PAID_DAEMONS = {…}` com chaves str:
    qualquer outro código poderia mudar o dict depois (um `del` esconderia a falta de aprovação) e eu estaria avaliando um registro que o import real não produz. Valores nunca são avaliados."""
    # vazio ({}) → nenhum Label aprovado, e é resposta; falhou/ilegível (não parseia, forma outra, chave que não é str) → Unknown
    try:
        tree = ast.parse(text)
    except (SyntaxError, ValueError, RecursionError, MemoryError) as e:
        raise Unknown(f"{REGISTRY_PATH} não parseia ({type(e).__name__})")
    found = None
    for i, node in enumerate(tree.body):
        if i == 0 and isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
            continue
        if isinstance(node, ast.ImportFrom) and node.module == "__future__":
            continue
        target = value = None
        if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            target, value = node.target.id, node.value
        elif isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            target, value = node.targets[0].id, node.value
        if target != REGISTRY_NAME or found is not None or not isinstance(value, ast.Dict):
            raise Unknown(f"{REGISTRY_PATH} tem código além de uma atribuição literal de {REGISTRY_NAME} (linha {node.lineno}): não avalio sem executar")
        found = value
    if found is None:
        raise Unknown(f"{REGISTRY_PATH} não define {REGISTRY_NAME}")
    labels = set()
    for k in found.keys:
        if not (isinstance(k, ast.Constant) and isinstance(k.value, str)):
            raise Unknown(f"{REGISTRY_PATH}: chave que não é um texto literal (linha {getattr(k, 'lineno', '?')})")
        labels.add(k.value)
    return labels


class Run(NamedTuple):
    repo: str
    sha: str
    tsha: str
    rng: str
    root: Path
    entries: list
    scratch: Path


def guard_g12(c: Run) -> tuple:
    mod = load_trusted(c.repo, c.tsha, "g12", c.scratch)
    need(mod, "REPO_ROOT", "subprocess", "scan_plist", "all_repo_plists", "unapproved_scheduled_paid_daemons")
    # vazio (sem o arquivo do registro na árvore) → Unknown: o import do hook quebraria e o push seria barrado; falhou/ilegível (não UTF-8, forma outra) → Unknown
    reg = c.root / REGISTRY_PATH
    if not reg.is_file():
        raise Unknown(f"{REGISTRY_PATH} não existe no sha: sem o registro não sei o que está aprovado")
    try:
        labels = registry_labels(reg.read_text(encoding="utf-8"))
    except UnicodeDecodeError:
        raise Unknown(f"{REGISTRY_PATH} não é UTF-8")
    stub = types.ModuleType("lib.approved_scheduled_paid_daemons")
    stub.APPROVED_SCHEDULED_PAID_DAEMONS = {label: {} for label in sorted(labels)}  # o scanner faz `from lib.approved_scheduled_paid_daemons import …` dentro da função: acha isto, não o arquivo do nó
    sys.modules["lib.approved_scheduled_paid_daemons"] = stub
    mod.REPO_ROOT = c.root
    mod.subprocess = GitFacade(c.repo, c.rng, [e.path for e in c.entries if e.path.endswith(".plist") and e.mode in ("100644", "100755")])
    raw_scan, seen = mod.scan_plist, {}

    def scan_once(p):  # unapproved_scheduled_paid_daemons() chama scan_plist() de novo para cada plist: com a memória, cada um é lido UMA vez (304 plists, ~40 s sob carga)
        if str(p) not in seen:
            seen[str(p)] = raw_scan(p)
        return seen[str(p)]

    mod.scan_plist = scan_once
    plists = mod.all_repo_plists()
    infos = [mod.scan_plist(p) for p in plists]
    bad = mod.unapproved_scheduled_paid_daemons(plists)
    broken = [i for i in infos if i.get("parse_error")]
    blind = [i for i in infos if i.get("unresolved_entrypoint") and not i.get("parse_error")]
    # vazio (nenhum plist ilegível) → sem diff a ler; falhou (git diff) → Unknown; plist ilegível que ESTE sha acrescenta/altera → Unknown (o hook o trata como passou, mas o nó é a fonte e o launchd pode ler o que o plistlib não lê)
    changed = set(git(c.repo, "-c", "core.quotepath=false", "diff", "--no-ext-diff", "--name-only", "-z", c.rng).decode("utf-8", "surrogateescape").split("\0")) if broken else set()
    unread = [os.path.relpath(i.get("plist_path", "?"), c.root) for i in broken if os.path.relpath(i.get("plist_path", "?"), c.root) in changed]
    if unread:
        raise Unknown(f"plist alterado neste sha que o scanner não conseguiu ler ({safe(unread[0])}; {len(unread)} no total): não sei se agenda algo pago")
    lines = []
    if broken:
        lines.append(f"AVISO: {len(broken)} plist(s) que o scanner não conseguiu ler (contam como passou, contrato dele): " + ", ".join(safe(os.path.relpath(i.get('plist_path', '?'), c.root)) for i in broken[:5]))
    if blind:
        lines.append(f"AVISO: {len(blind)} plist(s) agendado(s) sem entrypoint resolvido (o scanner não vê o que rodam): " + ", ".join(safe(i.get("label")) for i in blind[:5]))
    for i in bad:
        lines.append(f"BLOQUEADO Label={safe(i.get('label'))} plist={safe(os.path.relpath(i.get('plist_path', '?'), c.root))} scripts={safe(', '.join(i.get('scripts') or []))} marcadores_pagos={safe(', '.join(i.get('paid_markers') or []))}")
    if bad:
        lines.append(f"Conserto: depois de o Athos revisar o volume de chamadas, acrescente cada Label a {REGISTRY_PATH} no mesmo sha (essa mudança, revisada pelo gate, É a aprovação) e entregue de novo.")
    return ("BLOCKED" if bad else "PASS"), f"{len(plists)} plist(s) lido(s), {len(bad)} sem aprovação, {len(labels)} Label(s) aprovado(s) no sha", lines


def guard_g6(c: Run) -> tuple:
    reg = load_trusted(c.repo, c.tsha, "g6reg", c.scratch)
    need(reg, "_REGISTRY_DIR", "registered_script_paths")
    mod = load_trusted(c.repo, c.tsha, "g6", c.scratch)
    need(mod, "_REPO_ROOT", "subprocess", "check")
    reg._REPO_ROOT, reg._REGISTRY_DIR = c.root, c.root / "lib" / "mds_consumers.d"
    mod._REPO_ROOT, mod.subprocess = c.root, GitFacade(c.repo, c.rng, [])
    skipped: list = []
    try:
        offenders = mod.check(c.rng, skipped=skipped)
    except Unknown:
        raise
    except Exception as e:  # o main() do guard devolveria 0 aqui ("fail OPEN"); o atalho não
        raise Unknown(f"G6 levantou {type(e).__name__}: {safe(e)[:120]}")
    lines = [f"AVISO: fragmento MDS registrado mas inválido (não bloqueia, como no hook): {safe(s.get('file'))}: {safe(s.get('reason'))}" for s in skipped]
    lines += [f"BLOQUEADO {safe(p)}: lê ops.mega_data_set e parece gravar um derivado, sem fragmento em lib/mds_consumers.d/<nome>.json" for p in offenders]
    if offenders:
        lines.append("Conserto: um fragmento lib/mds_consumers.d/<nome>.json no mesmo sha (esquema em lib/mds_consumers.d/README.md) e entregue de novo.")
    return ("BLOCKED" if offenders else "PASS"), f"{len(offenders)} escritor(es) MDS sem registro", lines


def guard_g7(c: Run) -> tuple:
    mod = load_trusted(c.repo, c.tsha, "g7", c.scratch)
    need(mod, "_REPO_ROOT", "subprocess", "check")
    mod._REPO_ROOT, mod.subprocess = c.root, GitFacade(c.repo, c.rng, [])
    try:
        offenders = mod.check(c.rng)
    except Unknown:
        raise
    except Exception as e:
        raise Unknown(f"G7 levantou {type(e).__name__}: {safe(e)[:120]}")
    lines = [f"BLOQUEADO {safe(p)}: posta direto no ntfy.sh em vez de passar pelo scripts/notify (lib/notify_cli.py: send_via_notify_cli)" for p in offenders]
    return ("BLOCKED" if offenders else "PASS"), f"{len(offenders)} arquivo(s) com post direto ao ntfy.sh", lines


def guard_g7b(c: Run) -> tuple:
    present = [e for e in c.entries if e.path == NOTIFY_PATH]
    if not present:  # vazio (a árvore não tem scripts/notify): o guard é inaplicável e o hook também o pula; falhou/ilegível (existe e não lê) → Unknown abaixo
        return "PASS", f"{NOTIFY_PATH} não existe no sha: inaplicável (o hook também pula)", []
    mod = load_trusted(c.repo, c.tsha, "g7b", c.scratch)
    need(mod, "check")
    try:
        src = (c.root / NOTIFY_PATH).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise Unknown(f"não li {NOTIFY_PATH} exportado ({type(e).__name__})")
    try:
        problems = mod.check(src)
    except Exception as e:
        raise Unknown(f"G7b levantou {type(e).__name__}: {safe(e)[:120]}")
    if not isinstance(problems, list):
        raise Unknown("G7b devolveu algo que não é uma lista de problemas")
    return ("BLOCKED" if problems else "PASS"), f"{len(problems)} problema(s) no scripts/notify", [f"BLOQUEADO {safe(p)}" for p in problems]


GUARDS = (("G12", guard_g12), ("G6", guard_g6), ("G7", guard_g7), ("G7b", guard_g7b))  # a ordem do Mayor: o que gasta dinheiro primeiro


def execute(repo: str, sha: str, scratch: Path, trusted_ref: str) -> int:
    if not SHA_RE.fullmatch(sha):
        raise Unknown(f"--sha tem de ter 40 hex, recebi {safe(sha)[:50]!r}")
    # vazio (sha que não é commit do rig) → Unknown; falhou/ilegível → Unknown
    if git(repo, "cat-file", "-t", sha).decode().strip() != "commit":
        raise Unknown(f"{sha[:12]} não é um commit do rig")
    tsha = commit_of(repo, trusted_ref)
    rng = f"{tsha}...{sha}"  # o hook usa `origin/main...HEAD` (3 pontos, wa-f3olu); aqui com os dois lados em sha
    entries = tree_entries(repo, sha)
    root = scratch / "tree"
    t0 = time.monotonic()
    stats = export_tree(repo, entries, root)
    say(f"sha={sha[:12]} guards de confiança={trusted_ref}@{tsha[:12]} exportados={stats['files']} arquivo(s) {stats['bytes'] // 1024} KB em {time.monotonic() - t0:.1f}s")
    pkg = types.ModuleType("lib")  # pacote de mentira, vazio: `from lib.x import y` só acha o que está em sys.modules; nunca procura em sys.path (nem na árvore empurrada)
    pkg.__path__ = []
    sys.modules["lib"] = pkg
    ctx = Run(repo, sha, tsha, rng, root, entries, scratch)
    verdicts = []
    for name, fn in GUARDS:
        t0 = time.monotonic()
        try:
            status, summary, lines = fn(ctx)
        except Unknown as e:
            status, summary, lines = "UNKNOWN", "não consegui saber", [f"NÃO SEI: {safe(e)}"]
        except (Exception, SystemExit) as e:  # o que não previ (inclusive RecursionError de um .py hostil, sys.exit de dentro de um guard): nunca vira passou
            status, summary, lines = "UNKNOWN", "não consegui saber", [f"NÃO SEI: erro interno {type(e).__name__}: {safe(e)[:120]}"]
        say(f"{name} {status} ({summary}; {time.monotonic() - t0:.1f}s)")
        for ln in lines:
            say(f"  {ln}")
        verdicts.append(status)
    result = "BLOCKED" if "BLOCKED" in verdicts else "UNKNOWN" if "UNKNOWN" in verdicts else "PASS"
    say(f"RESULT={result} sha={sha} trusted={tsha}")
    return {"PASS": 0, "BLOCKED": 1, "UNKNOWN": 2}[result]


def main(argv: list) -> int:
    ap = argparse.ArgumentParser(prog="wa-remote-guards.py", add_help=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--sha", required=True)
    ap.add_argument("--scratch", default="")
    ap.add_argument("--trusted-ref", default=TRUSTED_REF)  # nome COMPLETO: `origin/main` sozinho resolve primeiro um branch LOCAL chamado origin/main (refs/heads vem antes de refs/remotes)
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    for s in (sys.stdout, sys.stderr):
        s.reconfigure(errors="replace")  # nome de arquivo do nó com byte que não é UTF-8 não pode derrubar o relatório
    own = not a.scratch
    scratch = Path(tempfile.mkdtemp(prefix="wa-remote-guards-")) if own else Path(a.scratch)
    try:
        if not own:
            scratch.mkdir(parents=True, exist_ok=True, mode=0o700)
        return execute(a.repo, a.sha, scratch, a.trusted_ref)
    except Unknown as e:
        say(f"NÃO SEI: {safe(e)}")
        say(f"RESULT=UNKNOWN sha={safe(a.sha)[:40]} trusted=?")
        return 2
    finally:
        if own:
            shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:  # o que não previ, fora do execute(): rc 2, nunca um traceback que o chamador leria como outra coisa
        print(f"wa-remote-guards: NÃO SEI: erro interno {type(e).__name__}: {safe(e)[:160]}\nwa-remote-guards: RESULT=UNKNOWN sha=? trusted=?", flush=True)
        sys.exit(2)
