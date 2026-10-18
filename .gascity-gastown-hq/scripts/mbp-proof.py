#!/usr/bin/env -S python3 -I
"""mbp-proof — a prova ao vivo da fatia 2 do ga-w7qwl1 (ga-w7qwl1.1): o ambiente da sessão no MBP. Python 3.9+, só biblioteca padrão.
Modelo: hetzner-proof.py (e2e). Runbooks: gc-session-ssh.md (MBP), remote-shim.md (puxada), remote-worker-bundle.md.

## Contents
- Subcomandos
- O que a prova confere (a–e)
- O que toca no MBP e o que desfaz
- Códigos de saída
- Configuração (ambiente)

SUBCOMANDOS
  plan [--bead ID]       OFFLINE: o bloco do host `mbp`, o pedido de start e o que o provider reescreveria (dry-run do provider). Nada conecta.
  install [--apply]      leva o bundle ao MBP (/Users/athos/gt-remote/bundle), o cliente do atalho (gt-remote/shim-bin) e o spool (gt-remote/shim), e grava a
                         config do wrapper no mini (~/.gastown/remote-shim-mbp.json). Sem --apply só mostra o plano. Com --apply exige o MBP LIVRE.
  e2e [--bead ID] [--model M] [--timeout S] [--keep] [--delete-branch]   a prova (a–e) com o MBP livre; ver abaixo.

O QUE A PROVA CONFERE (os critérios do ga-w7qwl1.1; cada linha vira PASS/FAIL no log, nunca "passou" por omissão)
  (a) a sessão `remote-test-remote-mbp-1` abre pelo provider, responde ao peek (ver tela) e ao nudge, e o stop deixa o MBP limpo (sessão, socket do tmux,
      arquivos do lançador, processos; depois a pasta de teste e a marca de confiança no ~/.claude.json são removidas e conferidas)
  (b) com a PAUSA do Athos ligada (o mesmo arquivo ~/gt-remote/PAUSE, com a marca desta rodada) o vigia — biblioteca de presença de verdade — rebaixa a árvore da
      sessão: nice/pri de CADA processo antes e depois, sem matar ninguém; a pausa desta rodada é desligada no fim e o rebaixamento não volta
  (c) de dentro da sessão: `bd show` e `bd comment` de uma bead de teste chegam ao mini pelo atalho com lista de permissões (cliente → spool → puxador do mini →
      wrapper); os hooks gc do city disparam; o MBP não ganha credencial de bd/Dolt nem chave (varredura antes/depois)
  (d) um branch de teste comitado no MBP chega ao origin DIRETO do MBP (credencial que o MBP já tem; nenhuma nova) e aparece no mini; varredura: nenhum dado de lead
      (o clone é raso, sem blobs e sem checkout fora de mbp-proof/) nem segredo novo no MBP depois
  (e) o bundle está instalado e CONFERIDO no MBP (verify lá) e a sessão roda `claude` com o --settings do bundle até o prompt de partida

O QUE TOCA NO MBP (tudo sob ~/gt-remote, e só o que está aqui) E O QUE DESFAZ
  install: gt-remote/bundle (o OUT do builder, igual ao que o verify confere), gt-remote/shim-bin (cliente do atalho), gt-remote/shim (spool 0700),
           gt-remote/bin/remote-bundle-build.py. Nada em ~/.claude, ~/.config nem ~/.ssh.
  e2e:     gt-remote/proof/<rodada> (clone raso, sem blobs; apagado no fim), uma entrada em ~/.claude.json (projects[<pasta>], a mesma que o claude gravaria ao aceitar
           a confiança; REMOVIDA no fim), gt-remote/PAUSE (só a desta rodada; só removida se a primeira linha ainda for a marca dela), gt-remote/bundle/run (apagada se
           não existia). O branch worker/<rodada> no origin FICA (apagá-lo é decisão: --delete-branch).

CÓDIGOS  0 tudo passou · 1 alguma prova reprovou, ou recusei instalar (config do wrapper alheia/ilegível, builder ou verify falhou) · 2 uso · 3 não consegui começar (pré-condição: MBP não livre, tmux aberto ou sem resposta) · 4 interrompida: o Athos voltou ao MBP (nada mais foi medido; a sessão é parada)
CONFIGURAÇÃO (ambiente)  MBP_PROOF_SSH (athos@athoss-macbook-pro.local) · MBP_PROOF_HOME (/Users/athos: o home no MBP) · MBP_PROOF_SESSION (remote-test-remote-mbp-1) ·
  MBP_PROOF_POLL (10: segundos entre olhadas) · MBP_PROOF_WATCH_CYCLE (5: o watch_s do provider) · MBP_PROOF_SHIM_WAIT (60: quanto esperar o atalho) · GC_SSH_BIN (o ssh, como no provider) · GC_CITY_PATH · só o selftest troca: MBP_PROOF_PROV, MBP_PROOF_PUMP,
  MBP_PROOF_PATHX, MBP_PROOF_SHIM_CLIENT, MBP_PROOF_BUILDER
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
CITY = os.environ.get("GC_CITY_PATH") or os.path.dirname(HERE)  # a cidade VIVA (bead, estado); o código pode vir de um worktree
MHOME = os.environ.get("MBP_PROOF_HOME", "/Users/athos").rstrip("/")
SSH_TARGET = os.environ.get("MBP_PROOF_SSH", "athos@athoss-macbook-pro.local")
SESSION = os.environ.get("MBP_PROOF_SESSION", "remote-test-remote-mbp-1")
POLL = float(os.environ.get("MBP_PROOF_POLL", "10"))
SHIM_WAIT = float(os.environ.get("MBP_PROOF_SHIM_WAIT", "60"))
WATCH_CYCLE = float(os.environ.get("MBP_PROOF_WATCH_CYCLE", "5"))  # watch_s do provider: de quanto em quanto o vigia olha a presença
PROV = os.environ.get("MBP_PROOF_PROV") or os.path.join(HERE, "gc-session-ssh")
PUMP = os.environ.get("MBP_PROOF_PUMP") or os.path.join(HERE, "remote-shim-pump.py")
BUILDER = os.environ.get("MBP_PROOF_BUILDER") or os.path.join(HERE, "remote-bundle-build.py")  # (só o selftest troca estes três)
SHIM_CLIENT = os.environ.get("MBP_PROOF_SHIM_CLIENT") or os.path.join(HERE, "remote-shim.py")
SSH_BIN = os.environ.get("GC_SSH_BIN") or "ssh"
MINI_HOME = os.path.realpath(os.path.expanduser("~"))

MGT = MHOME + "/gt-remote"
BUNDLE, SHIMBIN, SPOOL, PROOFS, MBIN = MGT + "/bundle", MGT + "/shim-bin", MGT + "/shim", MGT + "/proof", MGT + "/bin"
PAUSE = MGT + "/PAUSE"
HOST = "mbp"
SOCKET = "gc-remote"
PATHX = os.environ["MBP_PROOF_PATHX"].split(":") if os.environ.get("MBP_PROOF_PATHX") else [SHIMBIN, "/opt/homebrew/bin", MHOME + "/.local/bin"]  # o atalho PRIMEIRO; o resto é o que o provider já usa
WRAPPER_CFG = os.path.join(MINI_HOME, ".gastown", "remote-shim-mbp.json")
RUN_RE = re.compile(r"mbp-[0-9]{8}-[0-9]{6}")
SESSION_RE = re.compile(r"remote-test-remote-mbp-[0-9]{1,3}")
BEAD_RE = re.compile(r"[a-z]{2,8}-[a-z0-9]{2,16}(\.[0-9]{1,4}){0,3}")
MARK, NMARK = "E2E-42-OK", "NUDGE-25-OK"  # o prompt só traz `$((6*7))`/`$((5*5))`: ver o número na tela quer dizer que o comando RODOU, não que o texto foi ecoado
DIALOGS = ("trust this folder", "Yes, I trust", "Bypass Permissions", "Enter to confirm", "Choose the text style", "Security notes", "Do you want to proceed",
           "Please run /login", "Not logged in", "Invalid API key")
SECRET_RX = [r"ghp_[A-Za-z0-9]{30,}", r"gho_[A-Za-z0-9]{30,}", r"github_pat_[A-Za-z0-9_]{30,}", r"sk-ant-[A-Za-z0-9_-]{20,}", r"AKIA[0-9A-Z]{16}",
             r"-----BEGIN [A-Z ]*PRIVATE KEY-----", r"xox[baprs]-[A-Za-z0-9-]{10,}", r"://[^/\s:@]+:[^/\s@]{3,}@"]
# o padrão genérico "chave": "valor" fica à parte: o manifest.json que o builder grava tem o campo `"token"` com o NOME do comando do hook (não é segredo) e este padrão o pega
SECRET_KV = r"\"(?:password|passwd|secret|token|api_?key)\"\s*:\s*\"[^\"]{8,}\""
SECRET_RX.append(SECRET_KV)
FORBIDDEN = [r"\.beads", r"\.dolt", r".*\.sqlite3?", r".*\.db", r".*\.csv", r".*\.xlsx?", r".*\.parquet", r"\.env(\..*)?", r"id_(?:rsa|ed25519|ecdsa|dsa)(?:\.pub)?",
             r".*\.pem", r".*\.p12", r".*\.pfx", r"credentials(?:\.json)?"]

PROMPT = """This is a minimal end-to-end check of a worker running on a laptop. Do exactly the steps below, one Bash call each, in order. Do not ask questions, \
do not edit any other file. If a step fails, still run the remaining steps, then finish with: FAILED step <n>.
1. command -v bd gc
2. bd show {bead} --json
3. bd comment {bead} "{name}: sessao remota no MBP {run} leu esta bead"
4. mkdir -p mbp-proof && echo "mbp-proof {run}" > mbp-proof/{run}.txt && git add mbp-proof/{run}.txt && git commit -m "chore(mbp-proof): {run} (sem dado, descartavel)"
5. git push origin HEAD:refs/heads/worker/{run}
6. echo E2E-$((6*7))-OK
"""
NUDGE = "Run exactly this one Bash command and nothing else: echo NUDGE-$((5*5))-OK"


def host_block() -> dict:
    """O bloco `mbp` de session-ssh.json que a prova usa (a config VIVA só tem o servidor; a do MBP é decisão da fatia 3 e das janelas do engine)."""
    return {"ssh": SSH_TARGET, "cap": 2, "remote_root": BUNDLE, "remote_home": MHOME, "mini_home": MINI_HOME, "path_extra": PATHX,
            "presence_gate": True, "sleeps": True,
            "shim": {"spool_dir": SPOOL, "wrapper_config": WRAPPER_CFG, "idle_exit_s": 90, "poll_s": 2}}


def wrapper_config() -> dict:
    """A config do wrapper no MINI para o MBP: só a sessão de teste (a identidade da prova); sessões reais são da fatia 3."""
    return {"city": CITY, "identity_pattern": "^remote-test-remote-mbp-[0-9]{1,3}$", "nudge_pattern": "gastown\\.(mayor|deacon)", "gate_done_bin": None,
            "log": os.path.join(MINI_HOME, ".gastown", "logs", "remote-shim-mbp.log")}


def client_config() -> dict:
    return {"transport": "spool", "spool_dir": SPOOL, "timeout_s": 330}


def start_request(bead: str, model: str, run: str, workdir: str) -> dict:
    """O pedido que o engine mandaria ao provider: a ORDEM dos --settings é a do pool (só o último vale), o lançador de pool do mini vira `claude` no provider."""
    cmd = (f"{CITY}/packs/town-deltas/assets/scripts/claude-ctxcap-ab.sh --settings '{{\"remoteControlAtStartup\":false}}' --model {model} "
           f"--strict-mcp-config --dangerously-skip-permissions --settings {CITY}/.gc/settings.json")
    # --dangerously-skip-permissions: é o que o pool manda ao provider, e a prova existe para exercitar ESSE lançamento. No MBP isso deixa a sessão rodar qualquer comando
    # como o Athos; o que limita é o que está em gc-session-ssh.md (MBP, ponto 10). Uma lista de permissões para sessões reais é decisão da fatia 3, não desta.
    env = {k: SESSION for k in ("GC_ALIAS", "GC_AGENT", "GC_SESSION_NAME", "GC_TEMPLATE")}
    env.update(GC_SESSION_ORIGIN="ephemeral", GC_CITY=CITY, GC_CITY_PATH=CITY, LANG="en_US.UTF-8", TERM="xterm-256color")
    return {"command": cmd, "work_dir": workdir, "env": env, "prompt_flag": "",
            "prompt_suffix": shlex.quote(PROMPT.format(bead=bead, name=SESSION, run=run))}


def new_run() -> str:
    return "mbp-" + time.strftime("%Y%m%d-%H%M%S", time.gmtime())


def family(rows: list, root: int) -> set:
    """`root` e todos os seus descendentes nas linhas dadas (ppid → pid)."""
    kids = {root}
    changed = True
    while changed:
        changed = False
        for r in rows:
            if r["ppid"] in kids and r["pid"] not in kids:
                kids.add(r["pid"])
                changed = True
    return kids


def judge_tree(before: list, after: list, watcher: int) -> tuple:
    """(ok, linhas, detalhe). `before`/`after`: [{pid, ppid, ni, pri, comm}]. Vale o que existe nos DOIS instantes e não é o vigia nem filho dele (o `sleep` do ciclo).
    Processo com folga (nice < 19 antes) tem de terminar em nice >= 19; processo que já estava em 19 ou mais (sem folga: não há como rebaixar mais) só não pode ter subido de
    prioridade. OK só se ao menos um processo comparável tinha folga (senão nada prova o vigia) e nenhum falhou; processo que sumiu não conta contra nem a favor aqui (o
    chamador confere à parte que nada da sessão sumiu). Sem o vigia identificado (watcher 0) não há o que julgar."""
    if not watcher:
        return False, [], "o vigia não foi identificado na árvore da sessão"
    kids = family(before + after, watcher)
    b = {r["pid"]: r for r in before if r["pid"] not in kids}
    a = {r["pid"]: r for r in after if r["pid"] not in kids}
    rows, bad, room = [], [], 0
    for pid in sorted(set(b) & set(a)):
        x, y = b[pid], a[pid]
        rows.append((pid, x["comm"], x["ni"], y["ni"], x["pri"], y["pri"]))
        room += x["ni"] < 19
        if (x["ni"] < 19 and y["ni"] < 19) or y["ni"] < x["ni"]:
            bad.append(pid)
    if not rows:
        return False, rows, "nenhum processo da sessão existe antes e depois (nada a comparar)"
    if not room:
        return False, rows, "nenhum processo comparável tinha folga (todos já em nice >= 19 antes da pausa): o rebaixamento não se prova"
    return not bad, rows, ("sem rebaixar (ou prioridade devolvida): " + ", ".join(map(str, bad))) if bad else ""


def sha256_file(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


# ---------------------------------------------------------------- programas que rodam NO MBP (python3 -I -, JSON em argv[1], uma linha JSON na saída)
SNAP = r'''
import hashlib, json, os, subprocess, sys
C = json.loads(sys.argv[1])
home = C["home"]
def st(p):
    try:
        s = os.lstat(p)
    except FileNotFoundError:
        return None
    except OSError as e:
        return "erro:" + str(e.strerror)
    return [s.st_size, int(s.st_mtime), oct(s.st_mode & 0o7777)]
def walk(root, cap=4000):
    if not os.path.lexists(root):
        return None
    rows, trunc = {}, False
    for d, dirs, names in os.walk(root, followlinks=False):
        for x in dirs:
            rows[os.path.relpath(os.path.join(d, x), root) + "/"] = "link" if os.path.islink(os.path.join(d, x)) else "dir"
        for n in sorted(names):
            p = os.path.join(d, n)
            if len(rows) >= cap:
                trunc = True
                break
            try:
                if os.path.islink(p):
                    rows[os.path.relpath(p, root)] = "link"
                else:
                    with open(p, "rb") as f:
                        data = f.read(2000000)
                    rows[os.path.relpath(p, root)] = [os.path.getsize(p), hashlib.sha256(data).hexdigest()[:16]]
            except OSError as e:
                rows[os.path.relpath(p, root)] = "erro:" + str(e.strerror)
        if trunc:
            break
    return {"files": rows, "truncated": trunc}
def lsdir(p):
    try:
        return sorted(os.listdir(p))
    except FileNotFoundError:
        return None
    except OSError as e:
        return "erro:" + str(e.strerror)
def which(n, path):
    for d in path.split(":"):
        p = os.path.join(d, n)
        if d and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None
out = {}
pathx = ":".join(C["path_extra"] + [os.environ.get("PATH", "")])
hookpath = ":".join([home + "/go/bin", home + "/.local/bin", pathx])
tm = os.environ.get("TMUX_TMPDIR") or "/tmp"
sock = "%s/tmux-%d/%s" % (tm, os.getuid(), C["socket"])
out["tmux_socket"] = os.path.exists(sock)
try:
    r = subprocess.run(["tmux", "-L", C["socket"], "list-sessions", "-F", "#{session_name}"], capture_output=True, text=True, timeout=10, env=dict(os.environ, PATH=pathx))
    out["tmux"] = {"rc": r.returncode, "out": r.stdout.strip(), "err": r.stderr.strip()[:200]}
except OSError as e:
    out["tmux"] = {"rc": 127, "out": "", "err": str(e)[:200]}
out["run_dir"] = lsdir(C["bundle"] + "/run")
out["proofs"] = lsdir(C["proofs"])
out["spool"] = {d: lsdir(C["spool"] + "/" + d) for d in ("req", "resp", "claimed")}
out["spool_alive"] = os.path.exists(C["spool"] + "/pump.alive")
out["roots"] = {k: walk(C[k]) for k in ("bundle", "shimbin", "spool", "proofs")}
out["gt_top"] = {n: st(os.path.join(C["gt"], n)) for n in (lsdir(C["gt"]) or [])}
out["ssh_dir"] = {n: st(os.path.join(home, ".ssh", n)) for n in (lsdir(home + "/.ssh") or []) if not n.startswith("known_hosts")}
out["creds"] = {p: st(os.path.join(home, p)) for p in (".git-credentials", ".netrc", ".config/gh/hosts.yml", ".config/git/credentials", ".dolt", ".beads", ".config/bd", ".config/dolt")}
out["bins"] = {n: which(n, pathx) for n in ("bd", "gc", "dolt", "git", "tmux", "claude", "python3", "node")}
out["bins_hook"] = {n: which(n, hookpath) for n in ("bd", "gc", "dolt")}
out["shim_sha"] = None
try:
    with open(C["shimbin"] + "/remote-shim", "rb") as f:
        out["shim_sha"] = hashlib.sha256(f.read()).hexdigest()
except OSError:
    pass
out["links"] = {n: (os.readlink(C["shimbin"] + "/" + n) if os.path.islink(C["shimbin"] + "/" + n) else None) for n in ("bd", "gc", "gate-done")}
out["client_conf"] = None
try:
    with open(C["shimbin"] + "/remote-shim.json") as f:
        out["client_conf"] = json.load(f)
except (OSError, ValueError):
    pass
procs = []
try:
    for l in subprocess.run(["ps", "-axo", "pid=,args="], capture_output=True, text=True, timeout=20).stdout.split("\n"):
        f = l.strip().split(None, 1)
        if len(f) == 2 and f[0].isdigit() and ("--settings " + C["bundle"] + "/city/settings.json" in f[1] or "PRESENCE_LIB_ONLY" in f[1]):
            procs.append([int(f[0]), f[1][:100]])
except (OSError, subprocess.SubprocessError):
    procs = None
out["procs"] = procs
out["spool_mode"] = oct(os.stat(C["spool"]).st_mode & 0o777) if os.path.isdir(C["spool"]) else None
out["plib"] = os.path.isfile(C["plib"])
out["pause"] = os.path.exists(C["pause"])
out["py"] = sys.version.split()[0]
out["python"] = sys.executable
out["claude_json"] = None
try:
    with open(home + "/.claude.json") as f:
        cj = json.load(f)
    out["claude_json"] = {"ok": isinstance(cj, dict), "trusted": bool(C.get("workdir") and (cj.get("projects") or {}).get(C["workdir"], {}).get("hasTrustDialogAccepted"))}
except (OSError, ValueError):
    out["claude_json"] = {"ok": False, "trusted": False}
print(json.dumps(out))
'''

PREPARE = r'''
import json, os, shutil, subprocess, sys, tempfile
C = json.loads(sys.argv[1])
os.umask(0o077)
env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15", PATH=":".join(C["path_extra"] + [os.environ.get("PATH", "")]))
def git(*a, cwd=None, timeout=420):
    return subprocess.run(["git"] + list(a), cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
res = {"ok": False}
url = None
for u in C["urls"]:
    r = git("ls-remote", u, "HEAD", timeout=60)
    if r.returncode == 0 and r.stdout.strip():
        url = u
        break
    res.setdefault("tried", []).append([u, r.returncode, r.stderr.strip()[:200]])
if not url:
    res["why"] = "nenhuma URL do origin respondeu com a credencial que o MBP já tem"
    print(json.dumps(res)); sys.exit(0)
res["url"] = url
wd = C["workdir"]
if os.path.lexists(wd):
    res["why"] = "a pasta de trabalho já existe"; print(json.dumps(res)); sys.exit(0)
os.makedirs(os.path.dirname(wd), 0o700, exist_ok=True)
for step, args in (("clone", ["clone", "--no-checkout", "--depth", "1", "--filter=blob:none", "--single-branch", url, wd]),
                   ("sparse", ["-C", wd, "sparse-checkout", "set", "--no-cone", "/mbp-proof/"]),
                   ("branch", ["-C", wd, "checkout", "-q", "-b", "worker/" + C["run"]]),
                   ("name", ["-C", wd, "config", "user.name", C["session"]]),
                   ("email", ["-C", wd, "config", "user.email", C["session"] + "@gastown.invalid"])):
    r = git(*args)
    if r.returncode != 0:
        res["why"] = "%s saiu %d: %s" % (step, r.returncode, (r.stderr or r.stdout).strip()[:300]); print(json.dumps(res)); sys.exit(0)
hook = os.path.join(wd, ".git", "hooks", "pre-push")
with open(hook, "w") as f:
    f.write('#!/bin/sh\n# mbp-proof: o clone de teste só empurra o branch desta rodada\nwhile read lref lsha rref rsha; do\n  [ "$rref" = "refs/heads/worker/%s" ] || { echo "mbp-proof: push recusado: $rref" >&2; exit 1; }\ndone\nexit 0\n' % C["run"])
os.chmod(hook, 0o755)
p = C["home"] + "/.claude.json"
try:
    with open(p) as f:
        cj = json.load(f)
    if not isinstance(cj, dict):
        raise ValueError("não é objeto")
except (OSError, ValueError) as e:
    res["why"] = "~/.claude.json ilegível (%s): nada gravado" % e; print(json.dumps(res)); sys.exit(0)
pr = cj.setdefault("projects", {}).setdefault(wd, {})
pr.update(hasTrustDialogAccepted=True, hasCompletedProjectOnboarding=True)
pr.setdefault("allowedTools", [])
fd, t = tempfile.mkstemp(dir=os.path.dirname(p))
with os.fdopen(fd, "w") as f:
    json.dump(cj, f)
os.chmod(t, os.stat(p).st_mode & 0o777)
os.replace(t, p)
head = git("-C", wd, "rev-parse", "HEAD").stdout.strip()
objs = git("-C", wd, "cat-file", "--batch-all-objects", "--batch-check").stdout.split("\n")
res.update(ok=True, head=head, blobs=sum(1 for l in objs if " blob " in l),
           wtfiles=sorted(os.path.relpath(os.path.join(d, n), wd) for d, ds, ns in os.walk(wd) if ".git" not in d.split(os.sep) for n in ns))
print(json.dumps(res))
'''

GITSEE = r'''
import json, os, subprocess, sys
C = json.loads(sys.argv[1])
env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15", PATH=":".join(C["path_extra"] + [os.environ.get("PATH", "")]))
def git(*a):
    return subprocess.run(["git", "-C", C["workdir"]] + list(a), env=env, capture_output=True, text=True, timeout=120)
out = {}
out["log"] = git("log", "-1", "--format=%H|%an|%s").stdout.strip()
out["branch"] = git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
out["status"] = git("status", "--porcelain").stdout.strip()
out["changed"] = [l for l in git("diff", "--name-only", "HEAD~1", "HEAD").stdout.split("\n") if l]
r = git("ls-remote", C["url"], "refs/heads/worker/" + C["run"])
out["remote_sha"] = r.stdout.split("\t")[0] if r.returncode == 0 else ""
objs = git("cat-file", "--batch-all-objects", "--batch-check").stdout.split("\n")
out["blobs"] = sum(1 for l in objs if " blob " in l)
out["wtfiles"] = sorted(os.path.relpath(os.path.join(d, n), C["workdir"]) for d, ds, ns in os.walk(C["workdir"]) if ".git" not in d.split(os.sep) for n in ns)
print(json.dumps(out))
'''

TREE = r'''
import json, os, subprocess, sys
C = json.loads(sys.argv[1])
env = dict(os.environ, PATH=":".join(C["path_extra"] + [os.environ.get("PATH", "")]))
r = subprocess.run(["tmux", "-L", C["socket"], "list-panes", "-t", "=" + C["session"] + ":", "-F", "#{pane_pid}"], capture_output=True, text=True, env=env, timeout=10)
pane = int(r.stdout.split()[0]) if r.returncode == 0 and r.stdout.split() else None
rows = []
if pane:
    ps = subprocess.run(["ps", "-axo", "pid=,ppid=,nice=,pri=,stat=,args="], capture_output=True, text=True, timeout=20).stdout.split("\n")
    allp = {}
    for l in ps:
        f = l.split(None, 5)
        if len(f) >= 5 and f[0].isdigit() and f[1].isdigit():
            allp[int(f[0])] = {"pid": int(f[0]), "ppid": int(f[1]), "ni": int(f[2]) if f[2].lstrip("-").isdigit() else 0, "pri": int(f[3]) if f[3].lstrip("-").isdigit() else 0,
                               "stat": f[4], "comm": (f[5] if len(f) > 5 else "")[:600]}
    for pid, row in allp.items():
        q, hops = pid, 0
        while q and q != 1 and hops < 64:
            if q == pane:
                rows.append(row)
                break
            q = allp.get(q, {}).get("ppid", 0)
            hops += 1
watcher = next((x["pid"] for x in rows if "PRESENCE_LIB_ONLY" in x["comm"]), 0)  # a 1ª linha do `bash -c` do lançador; o resto do script pode cair em outra linha do ps
print(json.dumps({"pane": pane, "rows": rows, "watcher": watcher, "tmux_rc": r.returncode, "tmux_err": r.stderr.strip()[:160]}))
'''

PAUSE_PY = r'''
import json, os, sys, time
C = json.loads(sys.argv[1])
p, mark = C["pause"], C["mark"]
def first():
    try:
        with open(p) as f:
            return f.readline().rstrip("\n")
    except FileNotFoundError:
        return None
if C["mode"] == "on":
    os.makedirs(os.path.dirname(p), 0o700, exist_ok=True)
    try:
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        print(json.dumps({"ok": False, "why": "já existe uma pausa (do Athos?): " + str(first())[:100]})); sys.exit(0)
    with os.fdopen(fd, "w") as f:
        f.write("%s desde=%s\n" % (mark, time.strftime("%Y-%m-%dT%H:%M:%S%z")))
    print(json.dumps({"ok": True, "first": first()}))
else:
    f1 = first()
    if f1 is None:
        print(json.dumps({"ok": True, "why": "não havia pausa"}))
    elif f1.startswith(mark):
        os.unlink(p)
        print(json.dumps({"ok": not os.path.exists(p), "why": "pausa desta rodada removida"}))
    else:
        print(json.dumps({"ok": False, "why": "a pausa NÃO é desta rodada, deixei: " + f1[:100]}))
'''

CLEAN = r'''
import json, os, re, shutil, sys, tempfile
C = json.loads(sys.argv[1])
res = {"removed": []}
wd = C["workdir"]
if not re.fullmatch(re.escape(C["proofs"]) + r"/mbp-[0-9]{8}-[0-9]{6}", wd):
    print(json.dumps({"ok": False, "why": "pasta de trabalho fora do padrão, não apago: " + wd})); sys.exit(0)
if os.path.lexists(wd):
    shutil.rmtree(wd)
    res["removed"].append(wd)
p = C["home"] + "/.claude.json"
try:
    with open(p) as f:
        cj = json.load(f)
    if isinstance(cj, dict) and wd in (cj.get("projects") or {}):
        del cj["projects"][wd]
        fd, t = tempfile.mkstemp(dir=os.path.dirname(p))
        with os.fdopen(fd, "w") as f:
            json.dump(cj, f)
        os.chmod(t, os.stat(p).st_mode & 0o777)
        os.replace(t, p)
        res["removed"].append("~/.claude.json projects[%s]" % wd)
except (OSError, ValueError) as e:
    res["claude_json_error"] = str(e)[:120]
for d, flag in ((C["proofs"], C["proofs_new"]), (C["bundle"] + "/run", C["run_new"])):
    try:
        if flag and os.path.isdir(d) and not os.listdir(d):
            os.rmdir(d)
            res["removed"].append(d)
    except OSError as e:
        res.setdefault("errors", []).append("%s: %s" % (d, e.strerror))
sock = "%s/tmux-%d/%s" % (os.environ.get("TMUX_TMPDIR") or "/tmp", os.getuid(), C["socket"])
if C["socket_new"] and os.path.exists(sock):
    try:
        os.unlink(sock)
        res["removed"].append(sock + " (socket sobrando)")
    except OSError as e:
        res.setdefault("errors", []).append("%s: %s" % (sock, e.strerror))
res["ok"] = not os.path.lexists(wd) and "errors" not in res and "claude_json_error" not in res
print(json.dumps(res))
'''

SWEEP = r'''
import glob, json, os, re, sys
C = json.loads(sys.argv[1])
rx = [re.compile(x) for x in C["secret_rx"]]
fb = [re.compile(x) for x in C["forbidden"]]
hits, forb, scanned = [], [], 0
roots = list(C["roots"])
for g in C.get("globs", []):
    roots += sorted(glob.glob(g))  # a transcrição que o claude gravou no ~/.claude/projects do MBP para esta rodada
for root in roots:
    if not os.path.isdir(root):
        continue
    for d, dirs, names in os.walk(root, followlinks=False):
        if os.sep + ".git" + os.sep + "objects" in d + os.sep or d.endswith(os.sep + ".git" + os.sep + "objects"):
            dirs[:] = []
            continue
        for n in dirs + names:
            if any(x.fullmatch(n) for x in fb):
                forb.append(os.path.join(d, n))
        for n in names:
            p = os.path.join(d, n)
            if os.path.islink(p):
                continue
            try:
                if os.path.getsize(p) > 3000000:
                    continue
                with open(p, "rb") as f:
                    data = f.read().decode("utf-8", "replace")
            except OSError:
                continue
            scanned += 1
            for x in rx:
                if x.pattern not in C.get("skip", {}).get(p, []) and x.search(data):
                    hits.append([p, x.pattern[:40]])
print(json.dumps({"hits": hits, "forbidden": forb, "scanned": scanned}))
'''

HOOKLOG = r'''
import glob, json, os, sys
rows, bad = [], 0  # vazio (nenhuma transcrição) → [] e a prova reprova; linha ilegível → CONTADA e a prova reprova (uma linha perdida pode ser o hook que falhou)
for f in glob.glob(os.path.expanduser("~/.claude/projects/*%s*/*.jsonl") % sys.argv[1]):
    for line in open(f, errors="replace"):
        try:
            o = json.loads(line)
        except ValueError:
            bad += 1
            continue
        a = o.get("attachment") or {}
        if str(a.get("type", "")).startswith("hook_") and a.get("hookEvent") and a.get("command"):
            rows.append({"event": a["hookEvent"], "cmd": a["command"], "ms": a.get("durationMs"), "rc": a.get("exitCode"), "kind": a["type"],
                         "timeout": a.get("timeoutMs") if a.get("timedOut") else None})
print(json.dumps({"rows": rows, "unreadable": bad}))
'''


class Aborted(Exception):
    """O Athos voltou ao MBP no meio da prova: nada mais é medido."""


class Proof:
    def __init__(self, a: argparse.Namespace) -> None:
        self.a, self.checks = a, []
        self.run = new_run()
        self.wd = f"{PROOFS}/{self.run}"
        base = f"{CITY}/.gc/runtime/mbp-proof"
        self.base = base
        os.makedirs(base, 0o700, exist_ok=True)
        path = a.log or f"{CITY}/.gc/logs/mbp-proof-{self.run}.log"
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.f = open(path, "a")
        self.cfg_path = f"{base}/session-ssh-{self.run}.json"
        with open(self.cfg_path, "w") as f:
            json.dump({"default_host": HOST, "hosts": {HOST: host_block()}}, f, indent=1)
        self.env = dict(os.environ, GC_SSH_CONFIG=self.cfg_path, GC_EXEC_STATE_DIR=f"{base}/state", GC_SSH_HOST=HOST)
        self.started, self.paused_by_us, self.url, self.pre, self.tree0, self.sha, self.head0 = False, False, "", None, [], "", ""
        self.created = {"proofs_new": False, "run_new": False, "socket_new": False}
        self.t0 = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.say(f"mbp-proof {self.run} · sessão {SESSION} · log {path} · config do provider {self.cfg_path}")

    # ---- infraestrutura
    def say(self, msg: str) -> None:
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        self.f.write(line + "\n")
        self.f.flush()

    def check(self, name: str, ok: bool, detail: str = "") -> bool:
        self.checks.append((name, ok))
        self.say(f"{'PASS' if ok else 'FAIL'} {name}{' — ' + detail if detail else ''}")
        return ok

    def prov(self, *args: str, stdin: str = "", timeout: int = 180) -> subprocess.CompletedProcess:
        return subprocess.run([PROV, *args], input=stdin.encode(), capture_output=True, timeout=timeout, env=self.env)

    @staticmethod
    def out(p: subprocess.CompletedProcess) -> str:
        return (p.stdout + p.stderr).decode("utf-8", "replace").strip()

    def rsh(self, prog: str, stdin: bytes = b"", timeout: int = 120) -> subprocess.CompletedProcess:
        return rsh(f"export PATH={':'.join(PATHX)}:$PATH; {prog}", stdin, timeout)

    def rpy(self, script: str, arg: dict, timeout: int = 180) -> dict:
        """Roda um programa Python NO MBP e devolve o JSON da última linha. Vazio/ilegível/rc≠0 → {"_erro": ...}: o chamador reprova, nunca assume."""
        try:
            p = self.rsh(f"python3 -I - {shlex.quote(json.dumps(arg))}", script.encode(), timeout)
        except (OSError, subprocess.SubprocessError) as e:
            return {"_erro": f"{type(e).__name__}: {e}"}
        lines = [l for l in p.stdout.decode("utf-8", "replace").split("\n") if l.strip()]
        try:
            doc = json.loads(lines[-1])
            if p.returncode == 0 and isinstance(doc, dict):
                return doc
        except (ValueError, IndexError):
            pass
        return {"_erro": f"rc {p.returncode}: {(p.stderr or p.stdout).decode('utf-8', 'replace').strip()[-300:]}"}

    def snap(self, workdir: str = "") -> dict:
        return self.rpy(SNAP, {"home": MHOME, "gt": MGT, "bundle": BUNDLE, "shimbin": SHIMBIN, "spool": SPOOL, "proofs": PROOFS, "socket": SOCKET,
                               "path_extra": PATHX, "plib": f"{MBIN}/mbp-presence.sh", "pause": PAUSE, "workdir": workdir})

    def free(self) -> tuple:
        g = self.prov("gate", HOST, timeout=90)
        try:
            v = json.loads(g.stdout.decode("utf-8", "replace"))
        except ValueError:
            v = None
        if not isinstance(v, dict):  # corpo ilegível ou que não é um objeto: "não sei" NÃO é "livre", nem com exit 0 (só abre com evidência positiva)
            return False, f"veredito do gate ilegível: {self.out(g)[:160]}"
        return g.returncode == 0, v.get("reason") or self.out(g)[:160]

    def still_free(self, stage: str) -> None:
        """Aborta quando o Athos voltou (presença, pausa dele, bandeira desligada). A SAÚDE do MBP não aborta: a própria sessão a piora, e quem a protege é o vigia."""
        ok, why = self.free()
        if ok:
            return
        if why.startswith("MBP sem saúde"):
            self.say(f"aviso antes de {stage}: {why} (a sessão de teste pesa no MBP; sigo, o vigia e o gate de start é que protegem)")
            return
        raise Aborted(f"antes de {stage}: {why}")

    # ---- pré-condições
    def preconditions(self) -> bool:
        ok, why = self.free()
        self.say(f"gate do MBP (a regra do Athos, a mesma do start): {'livre' if ok else 'NÃO livre'} — {why}")
        if not ok:
            return False
        s = self.snap()
        if "_erro" in s:
            self.say(f"não consegui ler o estado do MBP: {s['_erro']}")
            return False
        self.pre = s
        need = [("python3", s["bins"].get("python3")), ("tmux", s["bins"].get("tmux")), ("git", s["bins"].get("git")), ("claude", s["bins"].get("claude"))]
        miss = [n for n, p in need if not p]
        self.say(f"MBP: python {s['py']} ({s['python']}) · " + " · ".join(f"{n} {p}" for n, p in need))
        bad = []
        if miss:
            bad.append("faltam no MBP: " + ", ".join(miss))
        if not s["plib"]:
            bad.append(f"sem a biblioteca de presença ({MBIN}/mbp-presence.sh): rode mbp-offload.sh install-mbp")
        ts = tmux_state(s)
        if ts == "aberta":
            bad.append("já há sessões no socket do provider: " + s["tmux"]["out"].replace("\n", ","))
        elif ts == "nao-sei":
            bad.append(f"não consegui saber se há sessão aberta no socket do provider (socket {s['tmux_socket']}): {s.get('tmux')}")
        elif s["tmux_socket"] and s["tmux"]["rc"] != 0:
            bad.append("sobrou um socket do tmux do provider sem servidor (limpe à mão antes: a prova mede que o stop não deixa socket)")
        if s["pause"]:
            bad.append("já existe uma pausa em gt-remote/PAUSE (o gate deveria ter recusado)")
        if s["proofs"]:
            bad.append("sobrou algo em gt-remote/proof: " + ",".join(s["proofs"]))
        if s["run_dir"]:
            bad.append("gt-remote/bundle/run não está vazia: " + ",".join(s["run_dir"]))
        if not s["claude_json"]["ok"]:
            bad.append("~/.claude.json ilegível: o claude do MBP nunca rodou aqui?")
        shadow = {n: p for n, p in s["bins_hook"].items() if p and not p.startswith(SHIMBIN + "/")}
        if shadow:
            bad.append("no PATH dos hooks (~/go/bin e ~/.local/bin à frente) existe " + ", ".join(f"{n}={p}" for n, p in shadow.items()) + ": esconderia o atalho")
        self.created["proofs_new"] = s["proofs"] is None
        self.created["run_new"] = s["run_dir"] is None
        self.created["socket_new"] = not s["tmux_socket"]
        # o bundle e o cliente instalados e conferidos NO MBP (critério e)
        v = self.rsh(f"python3 -I {shlex.quote(MBIN + '/remote-bundle-build.py')} verify {shlex.quote(BUNDLE)}")
        self.check("bundle instalado em gt-remote/bundle e conferido NO MBP (verify lá)", v.returncode == 0, (v.stdout + v.stderr).decode("utf-8", "replace").strip()[:200])
        lk = s["links"]
        same = s["shim_sha"] == sha256_file(SHIM_CLIENT)
        self.check("cliente do atalho instalado em shim-bin (bd, gc, gate-done) e igual ao do repositório", same and all(lk.get(n) == "remote-shim" for n in lk),
                   f"links {lk}, sha {'igual' if same else 'DIFERENTE'}")
        self.check("config do cliente é a da puxada (sem host, usuário nem chave) e o spool é 0700", s["client_conf"] == client_config() and s["spool_mode"] == "0o700",
                   f"{s['client_conf']} · spool {s['spool_mode']}")
        for b in bad:
            self.say("PRÉ-CONDIÇÃO: " + b)
        return not bad and all(ok for _, ok in self.checks)

    def shim_direct(self) -> bool:
        """O atalho chega ao mini ANTES de abrir a sessão: bd show pelo cliente instalado, com a identidade da sessão (o puxador sobe se não houver)."""
        e = subprocess.run([sys.executable, "-I", PUMP, "ensure", "--host", HOST], capture_output=True, env=self.env, timeout=60)
        self.say(f"puxador (ensure): rc {e.returncode} {self.out(e)[:120]}")
        ident = " ".join(f"{k}={SESSION}" for k in ("GC_ALIAS", "GC_AGENT", "GC_SESSION_NAME", "GC_TEMPLATE"))
        end, o = time.time() + SHIM_WAIT, ""
        while time.time() < end:
            p = self.rsh(f"env {ident} {shlex.quote(SHIMBIN + '/bd')} show {shlex.quote(self.a.bead)} --json | head -c 400", timeout=400)
            o = p.stdout.decode("utf-8", "replace")
            if '"id"' in o:
                break
            time.sleep(min(3, POLL))
        return self.check("atalho bd do MBP chega ao mini (cliente → spool → puxador → wrapper), com a identidade da sessão de teste", '"id"' in o, o[:100].replace("\n", " ") or "sem saída")

    # ---- a sessão
    def prepare(self) -> bool:
        urls = [self.a.repo_url] if self.a.repo_url else self.default_urls()
        r = self.rpy(PREPARE, {"home": MHOME, "run": self.run, "workdir": self.wd, "session": SESSION, "urls": urls, "path_extra": PATHX}, timeout=480)
        self.say(f"clone raso + identidade + hook de push + pasta pré-confiada: {json.dumps(r, ensure_ascii=False)[:500]}")
        if not r.get("ok"):
            return False
        self.url, self.head0 = r["url"], r["head"]
        self.check("clone sem dado: raso, sem blobs e sem nenhum arquivo no checkout", r["blobs"] == 0 and r["wtfiles"] == [], f"{r['blobs']} blobs, arquivos {r['wtfiles']}")
        return True

    @staticmethod
    def default_urls() -> list:
        u = subprocess.run(["git", "-C", CITY, "config", "remote.origin.url"], capture_output=True, text=True).stdout.strip()
        m = re.fullmatch(r"https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?", u)
        return [u] + ([f"git@github.com:{m.group(1)}.git"] if m else []) if u else []

    def start(self) -> bool:
        self.started = True  # o provider marca o registro antes do ssh do start: se falhar no meio, o stop do fim limpa
        p = self.prov("start", SESSION, stdin=json.dumps(start_request(self.a.bead, self.a.model, self.run, self.wd)), timeout=120)
        return self.check("start pelo provider (sessão de teste abre com o MBP livre)", p.returncode == 0, self.out(p)[:300])

    def watch(self, want: str, what: str, secs: int) -> str:
        """Espera `want` na tela. Diálogo desconhecido ou sessão que morre antes = falha com a tela; nunca responde a diálogo."""
        end, seen, n = time.time() + secs, "", 0
        while time.time() < end:
            time.sleep(POLL)
            n += 1
            if n % 3 == 0:
                self.still_free(what)
            seen = self.out(self.prov("peek", SESSION, "300"))
            if want in seen:
                return seen
            if any(d in seen for d in DIALOGS):
                self.check(f"{what}: sessão andou sem diálogo nem pedido de login", False, "tela:\n" + seen[-1200:])
                return seen
            run = self.out(self.prov("is-running", SESSION))
            if run != "true":
                self.check(f"{what}: sessão ficou de pé", False, f"is-running={run!r}; tela:\n{seen[-1200:]}")
                return seen
        self.check(f"{what} no prazo", False, f"{secs}s; tela:\n{seen[-1200:]}")
        return seen

    def evidence(self, screen: str) -> None:
        a = self.a
        ok = all(f"{SHIMBIN}/{n}" in screen for n in ("bd", "gc"))
        self.check("(c) na sessão, `bd` e `gc` resolvem para o atalho (nenhum bd/gc real escondendo)", ok, "tela sem os dois caminhos de shim-bin" if not ok else "")
        c = subprocess.run(["bd", "comments", a.bead, "--json"], capture_output=True, cwd=CITY, timeout=180)
        self.check("(c) o comentário da sessão está na bead, no mini", c.returncode == 0 and self.run in c.stdout.decode("utf-8", "replace"), f"bd comments rc {c.returncode}")
        g = self.rpy(GITSEE, {"workdir": self.wd, "run": self.run, "url": self.url, "path_extra": PATHX}, timeout=200)
        if "_erro" in g:
            self.check("(d) li o commit da sessão no MBP", False, g["_erro"])
            return
        sha = (re.match(r"^(\w{40})\|", g["log"]) or [None, ""])[1]
        self.sha = sha
        self.check("(d) commit no MBP, com a identidade da sessão, só do arquivo de teste", bool(sha) and sha != self.head0 and f"|{SESSION}|" in g["log"] and self.run in g["log"]
                   and g["changed"] == [f"mbp-proof/{self.run}.txt"] and g["status"] == "", f"{g['log']} · mudou {g['changed']} · status {g['status']!r}")
        self.check("(d) clone continua sem dado depois do commit: 1 blob (o do teste) e só o arquivo de teste no checkout", g["blobs"] <= 1 and g["wtfiles"] == [f"mbp-proof/{self.run}.txt"],
                   f"{g['blobs']} blobs, arquivos {g['wtfiles']}")
        got = ""
        for _ in range(12):
            r = subprocess.run(["git", "ls-remote", self.url, f"refs/heads/worker/{self.run}"], capture_output=True, timeout=90)
            got = r.stdout.decode().split("\t")[0]
            if got:
                break
            time.sleep(min(5, POLL))
        self.check("(d) o branch chegou ao origin DIRETO do MBP, com o sha do commit do MBP (e o MBP o vê igual)", bool(sha) and got == sha and g["remote_sha"] == sha,
                   f"origin {got[:12] or 'sem o branch'} · MBP {sha[:12]} · ls-remote do MBP {g['remote_sha'][:12] or '-'}")
        self.fetch_on_mini(sha)
        rc = self.rsh(f"python3 -I - {shlex.quote(self.run)}", HOOKLOG.encode(), 120)
        try:
            doc = json.loads(rc.stdout.decode("utf-8", "replace").strip().split("\n")[-1]) if rc.returncode == 0 else None
            rows, unreadable = doc["rows"], doc["unreadable"]
        except (ValueError, KeyError, TypeError, IndexError):
            rows = None
        if rows is None:
            self.check("(c) hooks da sessão lidos na transcrição do MBP", False, f"não consegui ler: rc {rc.returncode}")
            return
        gc = [r for r in rows if " gc " in r["cmd"]]
        prime = [r for r in gc if r["event"] == "SessionStart" and "gc prime" in r["cmd"] and r["kind"] == "hook_success" and r["rc"] == 0]
        ups = [r for r in gc if r["event"] == "UserPromptSubmit"]
        okr = lambda r: r["kind"] == "hook_success" and r["rc"] == 0
        self.check("(c) hooks gc do city (--settings do bundle) dispararam na sessão e passaram pelo atalho (SessionStart prime ok + UserPromptSubmit drain)",
                   bool(prime) and any("nudge drain" in r["cmd"] for r in ups) and all(okr(r) or r["timeout"] for r in gc) and unreadable == 0,
                   f"prime {[r['ms'] for r in prime]} ms · " + " · ".join(f"{r['cmd'].split('gc ', 1)[-1]}: {r['ms']} ms {'ok' if okr(r) else 'FALHOU/prazo'}" for r in ups) + f" · {unreadable} linhas ilegíveis")

    def fetch_on_mini(self, sha: str) -> None:
        """O branch aparece no mini: fetch raso e SEM blobs num repositório de teste; o conteúdo se confere pelo sha do blob na árvore (o blob não é baixado)."""
        tmp = f"{self.base}/fetch-{self.run}"
        ok, got, blob = True, "", ""
        want = subprocess.run(["git", "hash-object", "--stdin"], input=f"mbp-proof {self.run}\n".encode(), capture_output=True).stdout.decode().strip()
        try:
            for s in (["git", "init", "-q", "--bare", tmp],
                      ["git", "-C", tmp, "fetch", "-q", "--depth", "1", "--filter=blob:none", self.url, f"refs/heads/worker/{self.run}:refs/heads/probe"]):
                if subprocess.run(s, capture_output=True, timeout=240).returncode != 0:
                    ok = False
                    break
            if ok:
                got = subprocess.run(["git", "-C", tmp, "rev-parse", "refs/heads/probe"], capture_output=True, text=True).stdout.strip()
                lt = subprocess.run(["git", "-C", tmp, "ls-tree", f"refs/heads/probe", f"mbp-proof/{self.run}.txt"], capture_output=True, text=True).stdout.split()
                blob = lt[2] if len(lt) >= 3 else ""
        except (OSError, subprocess.SubprocessError):
            ok = False
        finally:
            if re.fullmatch(re.escape(self.base) + r"/fetch-mbp-[0-9]{8}-[0-9]{6}", tmp) and os.path.isdir(tmp):
                shutil.rmtree(tmp, ignore_errors=True)  # pasta que ESTE processo acabou de criar, com o nome validado acima
        self.check("(d) o branch aparece no mini (fetch raso num repositório de teste) com o sha do MBP e o arquivo com o conteúdo esperado",
                   ok and bool(sha) and got == sha and bool(want) and blob == want, f"fetch {'ok' if ok else 'FALHOU'} · {got[:12]} · blob {blob[:12]} (esperado {want[:12]})")

    def peek_nudge(self) -> None:
        self.still_free("o nudge")
        screen = self.out(self.prov("peek", SESSION, "300"))
        self.check("(a) peek mostra a tela da sessão (o claude no prompt, com o resultado dos passos)", bool(screen.strip()) and MARK in screen, f"{len(screen)} caracteres")
        n = self.prov("nudge", SESSION, stdin=NUDGE)
        self.check("(a) nudge entregue pelo provider", n.returncode == 0, self.out(n)[:160])
        seen = self.watch(NMARK, "(a) a sessão agiu sobre o nudge", 240)
        self.check("(a) a sessão respondeu ao nudge (rodou o comando pedido)", NMARK in seen)

    def tree(self) -> dict:
        return self.rpy(TREE, {"socket": SOCKET, "session": SESSION, "path_extra": PATHX}, timeout=60)

    def watchdog(self) -> None:
        self.still_free("a pausa")
        t0 = self.tree()
        rows0 = t0.get("rows") or []
        self.tree0 = rows0
        if "_erro" in t0 or not rows0:
            self.check("(b) li a árvore de processos da sessão antes da pausa", False, str(t0.get("_erro") or t0)[:200])
            return
        self.say("(b) árvore ANTES da pausa (pid ppid nice pri processo): " + " | ".join(f"{r['pid']} {r['ppid']} {r['ni']} {r['pri']} {r['comm'][:40]}" for r in rows0))
        if not self.check("(b) o vigia (biblioteca de presença de verdade) está de pé na árvore da sessão", bool(t0["watcher"]), "sem processo com PRESENCE_LIB_ONLY sob o painel"):
            return
        mark = f"origem=mbp-proof:{self.run}"
        p = self.rpy(PAUSE_PY, {"pause": PAUSE, "mark": mark, "mode": "on"})
        self.paused_by_us = bool(p.get("ok"))
        if not self.check("(b) pausa do Athos ligada (o arquivo gt-remote/PAUSE, com a marca desta rodada)", self.paused_by_us, str(p.get("why") or p.get("first") or p.get("_erro"))[:160]):
            return
        g = self.prov("gate", HOST, timeout=90)
        self.check("(b) com a pausa ligada o gate do provider recusa sessão nova", g.returncode == 1 and "paus" in self.out(g).lower(), self.out(g)[:160])
        end, last, ok = time.time() + 60, {}, False
        while time.time() < end:
            time.sleep(min(2, POLL))
            last = self.tree()
            ok, rows, why = judge_tree(rows0, last.get("rows") or [], t0["watcher"])
            if ok:
                break
        ok, rows, why = judge_tree(rows0, last.get("rows") or [], t0["watcher"])
        for pid, comm, n0, n1, p0, p1 in rows:
            self.say(f"(b) pid {pid:>6} {comm[:40]:40} nice {n0:>3} → {n1:>3}  pri {p0:>3} → {p1:>3}")
        self.check("(b) o vigia rebaixou a árvore da sessão (nice >= 19 em TODO processo comparável que tinha folga, e nenhum com a prioridade devolvida)", ok, why)
        alive = {r["pid"] for r in last.get("rows") or []}
        core = [r["pid"] for r in rows0 if f"--settings {BUNDLE}/city/settings.json" in r["comm"]]  # o claude e o shell que o lança; filho passageiro (git, sleep) some sem querer dizer nada
        gone = [pid for pid in core + [t0["pane"]] if pid not in alive]
        run = self.out(self.prov("is-running", SESSION))
        self.check("(b) a sessão NÃO foi morta (is-running true; o painel, o claude e o shell dele seguem vivos, os mesmos pids)", run == "true" and bool(core) and not gone,
                   f"is-running={run!r}, claude/shell {core}, sumiram {gone}" if core else "não achei o claude da sessão na árvore (nada a conferir)")
        off = self.rpy(PAUSE_PY, {"pause": PAUSE, "mark": mark, "mode": "off"})
        self.paused_by_us = not off.get("ok")
        self.check("(b) pausa desta rodada desligada", bool(off.get("ok")), str(off.get("why") or off.get("_erro"))[:160])
        time.sleep(2 * WATCH_CYCLE + 1)  # dois ciclos do vigia depois de a pausa sair: se ele fosse desfazer o rebaixamento, já teria feito
        t2 = self.tree()
        ok2, _, why2 = judge_tree(rows0, t2.get("rows") or [], t0["watcher"])
        self.check("(b) sem a pausa o rebaixamento NÃO volta a subir (continua >= 19)", ok2, why2)

    # ---- fim
    def finish(self, aborted: str = "") -> None:
        if self.paused_by_us:
            off = self.rpy(PAUSE_PY, {"pause": PAUSE, "mark": f"origem=mbp-proof:{self.run}", "mode": "off"})
            self.say(f"pausa desta rodada removida no fim: {off}" if off.get("ok") else
                     f"ATENÇÃO: não consegui remover a pausa desta rodada ({off}); remova à mão: ssh {SSH_TARGET} rm {PAUSE}")
        if self.started:
            try:
                p = self.prov("stop", SESSION)
                lst = self.out(self.prov("list-running", "remote-test"))
                self.check("(a) sessão parada pelo provider e fora da lista", p.returncode == 0 and SESSION not in lst.split(), self.out(p)[:200] or lst[:120])
            except (OSError, subprocess.SubprocessError) as e:
                self.check("(a) sessão parada pelo provider e fora da lista", False, f"não consegui parar/conferir: {type(e).__name__}: {e}")
            s = self.snap(self.wd)
            if "_erro" in s:
                self.check("(a) li o estado do MBP depois do stop", False, s["_erro"])
            else:
                clean = (tmux_state(s) == "livre" and not s["tmux_socket"] and s["run_dir"] in (None, []) and s["procs"] == [])
                self.check("(a) o stop deixa o MBP limpo: nenhuma sessão, sem socket do tmux, sem arquivo do lançador em run/, nenhum processo da sessão nem o vigia", clean,
                           f"tmux {s['tmux']} · socket {s['tmux_socket']} · run {s['run_dir']} · processos {s['procs']}")
                sw = self.rpy(SWEEP, {"roots": [self.wd, SPOOL, SHIMBIN, BUNDLE], "globs": [f"{MHOME}/.claude/projects/*{self.run}*"], "secret_rx": SECRET_RX, "forbidden": FORBIDDEN,
                                    "skip": {f"{BUNDLE}/manifest.json": [SECRET_KV]}})
                self.check("(d) varredura (antes de apagar a pasta de teste): nenhum segredo e nenhum arquivo de dado/credencial no clone, no spool, no atalho, no bundle nem na transcrição da sessão",
                           "_erro" not in sw and not sw["hits"] and not sw["forbidden"], f"{sw.get('scanned')} arquivos lidos · segredos {sw.get('hits')} · proibidos {sw.get('forbidden')}" if "_erro" not in sw else sw["_erro"])
        if self.a.delete_branch and self.url and self.sha:
            d = self.rsh(f"cd {shlex.quote(self.wd)} && git push origin --delete worker/{self.run}", timeout=120)
            self.say(f"branch worker/{self.run} apagado no origin: rc {d.returncode} {(d.stdout + d.stderr).decode('utf-8', 'replace').strip()[:160]}")
        q = subprocess.run([sys.executable, "-I", PUMP, "stop", "--host", HOST], capture_output=True, env=self.env, timeout=60)
        self.say(f"puxador do mini parado: rc {q.returncode} {self.out(q)[:120]}")
        if not self.a.keep and self.pre is not None:
            c = self.rpy(CLEAN, {"workdir": self.wd, "proofs": PROOFS, "home": MHOME, "bundle": BUNDLE, "socket": SOCKET, **self.created})
            self.say(f"limpeza no MBP: {json.dumps(c, ensure_ascii=False)[:400]}")
            self.check("(a) pasta de teste, marca de confiança no ~/.claude.json e diretórios criados pela prova removidos", bool(c.get("ok")), json.dumps(c, ensure_ascii=False)[:200])
            post = self.snap(self.wd)
            if "_erro" not in post and self.pre is not None:
                self.compare(self.pre, post)
        elif self.a.keep:
            self.say(f"--keep: a pasta de teste {self.wd} e a marca de confiança FICAM no MBP")

    def compare(self, pre: dict, post: dict) -> None:
        d = []
        for k in ("ssh_dir", "creds", "links", "client_conf", "shim_sha"):
            if pre[k] != post[k]:
                d.append(f"{k} mudou")
        for k in ("bundle", "shimbin"):
            if (pre["roots"][k] or {}).get("files") != (post["roots"][k] or {}).get("files"):
                d.append(f"{k} mudou")
        if any(v not in (None, []) for v in post["spool"].values()):  # as três pastas existem vazias depois de uma rodada (o cliente/puxador as criam) ou nem existem
            d.append(f"sobra no spool {post['spool']}")
        if post["bins"] != pre["bins"]:
            d.append("ferramentas no PATH mudaram")
        if post["proofs"] not in (None, []) or post["claude_json"]["trusted"] or post["pause"] or post["tmux_socket"] or post["run_dir"] not in (None, pre["run_dir"]):
            d.append(f"sobras: proof {post['proofs']} confiança {post['claude_json']['trusted']} pausa {post['pause']} socket {post['tmux_socket']} run {post['run_dir']}")
        top_new = sorted(set(post["gt_top"]) - set(pre["gt_top"]))
        if top_new:
            d.append(f"entradas novas em gt-remote: {top_new}")
        self.check("(c)(d) varredura depois: nada novo no MBP além do instalado (sem chave em ~/.ssh, sem credencial git/bd/Dolt nova, sem sobra de teste, bundle e atalho intactos)", not d,
                   "; ".join(d) or "ssh_dir, creds, bundle, shim-bin, spool, ferramentas e gt-remote iguais ao antes")

    def go(self) -> int:
        code = 0
        try:
            if not self.preconditions():
                self.say("NAO CONSEGUI começar: pré-condição não satisfeita")
                return 3
            if not self.shim_direct():
                self.say("NAO CONSEGUI começar: o atalho não chega ao mini")
                return 3
            if not self.prepare():
                self.say("NAO CONSEGUI começar: o MBP não preparou a pasta de teste (credencial do origin, clone ou ~/.claude.json)")
                return 3
            self.still_free("abrir a sessão")
            if self.start():
                screen = self.watch(MARK, "(e) a sessão rodou `claude` com o --settings do bundle até os 6 passos", self.a.timeout)
                if MARK in screen:
                    self.check("(e) a sessão rodou `claude` com o --settings do bundle e executou o prompt de partida até o fim", True)
                    time.sleep(min(5, POLL))
                    self.evidence(self.out(self.prov("peek", SESSION, "400")))
                    self.peek_nudge()
                    self.watchdog()
                self.say("--- tela final ---\n" + self.out(self.prov("peek", SESSION, "60"))[-2000:])
        except Aborted as e:
            self.say(f"INTERROMPIDA: o MBP deixou de estar livre — {e}. Nada mais é medido; a sessão é parada.")
            code = 4
        except (OSError, subprocess.SubprocessError) as e:
            self.check("execução até o fim sem interrupção", False, f"{type(e).__name__}: {e}")
        finally:
            self.finish()
        bad = [n for n, ok in self.checks if not ok]
        self.say(f"MBP-PROOF {'PASSOU' if not bad and code == 0 else 'INTERROMPIDA' if code == 4 else 'FALHOU'}: {sum(ok for _, ok in self.checks)} de {len(self.checks)} provas" + (f"; faltou: {bad}" if bad else ""))
        return code or (1 if bad or not self.checks else 0)


def rsh(prog: str, stdin: bytes = b"", timeout: int = 120) -> subprocess.CompletedProcess:
    cm = os.path.join(os.path.expanduser("~"), ".ssh", "cm")
    opts = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3"]
    try:
        os.makedirs(cm, 0o700, exist_ok=True)
        opts += ["-o", "ControlMaster=auto", "-o", f"ControlPath={cm}/%C", "-o", "ControlPersist=600"]
    except OSError:
        pass
    return subprocess.run([SSH_BIN, *opts, SSH_TARGET, prog], input=stdin, capture_output=True, timeout=timeout)


# ---------------------------------------------------------------- plan / install
def cmd_plan(a: argparse.Namespace) -> int:
    run = new_run()
    wd = f"{PROOFS}/{run}"
    print("== bloco do host `mbp` (session-ssh.json DESTA prova; a config viva só tem o servidor)")
    print(json.dumps({"default_host": HOST, "hosts": {HOST: host_block()}}, indent=1))
    print("== config do wrapper no mini\n" + json.dumps(wrapper_config(), indent=1))
    print("== config do cliente do atalho no MBP (ao lado do script)\n" + json.dumps(client_config()))
    env = dict(os.environ, GC_SSH_CONFIG="/dev/null")
    cfg = f"{CITY}/.gc/runtime/mbp-proof/session-ssh-plan.json"
    os.makedirs(os.path.dirname(cfg), 0o700, exist_ok=True)
    with open(cfg, "w") as f:
        json.dump({"default_host": HOST, "hosts": {HOST: host_block()}}, f)
    env["GC_SSH_CONFIG"] = cfg
    env["GC_EXEC_STATE_DIR"] = f"{CITY}/.gc/runtime/mbp-proof/state"
    p = subprocess.run([PROV, "--dry-run", "start", SESSION], input=json.dumps(start_request(a.bead, a.model, run, wd)).encode(), capture_output=True, env=env, timeout=60)
    print("== o que o provider faria no start (dry-run; nada conecta)")
    if p.returncode != 0:
        print(p.stdout.decode() + p.stderr.decode())
        return 1
    d = json.loads(p.stdout.decode())
    print(f"sessão {d['session']} ({d['session_kind']}) · would_refuse {d['would_refuse']} · work_dir {d['work_dir']}")
    print(f"comando: {d['command'][:600]}")
    print(f"env: {json.dumps(d['env'], sort_keys=True)}")
    print("lançador:\n  " + "\n  ".join(l[:200] for l in d["launcher"]))
    bad = []
    if d["would_refuse"]:
        bad.append("o provider recusaria: " + d["would_refuse"])
    if not d["command"].startswith("claude "):
        bad.append("o comando não começa em `claude` (o lançador de pool não foi reescrito)")
    if f"--settings {BUNDLE}/city/settings.json" not in d["command"]:
        bad.append("o --settings do city não aponta para o bundle do MBP")
    for b in bad:
        print("PROBLEMA:", b)
    return 1 if bad else 0


def tmux_state(s: dict) -> str:
    """livre | aberta | nao-sei, a partir do `tmux list-sessions` que o snap fez no MBP. É "livre" só com sessão nenhuma de fato (lista vazia, ou o texto de "sem servidor" /
    "sem socket" que o provider também trata assim); qualquer outra falha do tmux (versão, permissão, timeout, binário ausente) é "nao-sei", NUNCA "sem sessão"."""
    t = s.get("tmux") if "_erro" not in s else None
    if not isinstance(t, dict) or not isinstance(t.get("rc"), int) or not isinstance(t.get("out"), str):
        return "nao-sei"
    if t["rc"] == 0:
        return "aberta" if t["out"] else "livre"
    err = str(t.get("err"))
    if "no server running" in err or ("error connecting to" in err and "(No such file or directory)" in err):
        return "livre"
    return "nao-sei"


def cmd_install(a: argparse.Namespace) -> int:
    out = f"{CITY}/.gc/runtime/mbp-proof/bundle-out"
    stage_id = time.strftime("%Y%m%d%H%M%S", time.gmtime())
    role_dir = os.path.join(CITY, ".gc", "agents", "dogs", "gastown.dog-1")
    plan = [f"construir o bundle com o builder (--remote-root {BUNDLE} --remote-home {BUNDLE}/home, sem --skills) em {out} e conferi-lo aqui",
            f"enviar por tar/ssh para {MGT}/bundle.new.{stage_id}, conferir LÁ (verify + bundle_hash) e trocar por {BUNDLE} (a pasta run/ do provider é preservada)",
            f"instalar o cliente do atalho em {SHIMBIN} (bd, gc, gate-done → remote-shim) e remote-shim.json = {json.dumps(client_config())}",
            f"criar o spool {SPOOL} (0700) e levar remote-bundle-build.py para {MBIN}", f"gravar {WRAPPER_CFG} no mini"]
    print("\n".join(("" if a.apply else "[dry-run] ") + f"{i}. {x}" for i, x in enumerate(plan, 1)))
    if not a.apply:
        print("[dry-run] nada foi gravado nem conectado; repita com --apply (exige o MBP livre)")
        return 0
    pr = Proof.__new__(Proof)
    pr.a, pr.checks, pr.run = a, [], "install-" + stage_id
    pr.base = f"{CITY}/.gc/runtime/mbp-proof"
    os.makedirs(pr.base, 0o700, exist_ok=True)
    os.makedirs(f"{CITY}/.gc/logs", exist_ok=True)
    pr.f = open(f"{CITY}/.gc/logs/mbp-proof-install-{stage_id}.log", "a")
    pr.cfg_path = f"{pr.base}/session-ssh-install.json"
    with open(pr.cfg_path, "w") as f:
        json.dump({"default_host": HOST, "hosts": {HOST: host_block()}}, f)
    pr.env = dict(os.environ, GC_SSH_CONFIG=pr.cfg_path, GC_EXEC_STATE_DIR=f"{pr.base}/state", GC_SSH_HOST=HOST)
    ok, why = pr.free()
    pr.say(f"gate do MBP: {'livre' if ok else 'NÃO livre'} — {why}")
    if not ok:
        pr.say("NAO INSTALEI: o MBP precisa estar livre (Athos fora)")
        return 3
    s = pr.snap()
    ts = tmux_state(s)
    if ts != "livre":
        pr.say("NAO INSTALEI: " + (f"sessão aberta no socket do provider: {s['tmux']['out']}" if ts == "aberta" else f"não consegui saber se há sessão aberta no socket do provider ({s.get('_erro') or s.get('tmux')})"))
        return 3
    wc = json.dumps(wrapper_config(), indent=1) + "\n"
    try:
        have = open(WRAPPER_CFG).read() if os.path.exists(WRAPPER_CFG) else None
    except OSError as e:
        pr.say(f"NAO INSTALEI: {WRAPPER_CFG} existe e não consigo ler ({type(e).__name__}); confira à mão (não sobrescrevo) antes de repetir")
        return 1
    if have is not None and have != wc:
        pr.say(f"NAO INSTALEI: {WRAPPER_CFG} já existe e é diferente do que a prova grava; confira à mão (não sobrescrevo) antes de repetir")
        return 1
    steps = [[sys.executable, "-I", BUILDER, "build", "--city", CITY, "--claude-home", os.path.expanduser("~/.claude"), "--role", "dog", "--role-dir", role_dir,
              "--remote-root", BUNDLE, "--remote-home", BUNDLE + "/home", "--out", out],
             [sys.executable, "-I", BUILDER, "verify", out]]
    for st in steps:
        r = subprocess.run(st, capture_output=True, text=True)
        pr.say(f"{os.path.basename(st[2])} {st[3]}: rc {r.returncode} {(r.stdout + r.stderr).strip()[-200:]}")
        if r.returncode != 0:
            return 1
    with open(os.path.join(out, "manifest.json")) as f:
        want = json.load(f)["bundle_hash"]
    stage = f"{MGT}/bundle.new.{stage_id}"
    q = shlex.quote
    r = pr.rsh(f"umask 022; mkdir -p {q(MBIN)} {q(stage)} && chmod 700 {q(MGT)}")
    if r.returncode != 0:
        pr.say(f"mkdir no MBP saiu {r.returncode}: {r.stderr.decode()[:160]}")
        return 1
    tar = subprocess.Popen(["tar", "-C", out, "-cf", "-", "."], stdout=subprocess.PIPE, env=dict(os.environ, COPYFILE_DISABLE="1"))
    x = pr.rsh(f"tar -C {q(stage)} -xf -", tar.stdout.read(), 300)
    tar.wait()
    if tar.returncode != 0 or x.returncode != 0:
        pr.say(f"envio do bundle falhou: tar {tar.returncode}, destino {x.returncode} {x.stderr.decode()[:160]}")
        return 1
    with open(BUILDER, "rb") as f:
        r = pr.rsh(f"cat > {q(MBIN + '/remote-bundle-build.py')} && chmod 755 {q(MBIN + '/remote-bundle-build.py')}", f.read())
    if r.returncode != 0:  # senão um builder velho que já esteja lá conferiria o bundle novo
        pr.say(f"envio do builder para {MBIN} saiu {r.returncode}: {r.stderr.decode()[:160]}; a pasta {stage} FICA para inspeção")
        return 1
    v = pr.rsh(f"python3 -I {q(MBIN + '/remote-bundle-build.py')} verify {q(stage)} && python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"bundle_hash\"])' {q(stage + '/manifest.json')}")
    got = v.stdout.decode().strip()
    if v.returncode != 0 or got != want:
        pr.say(f"verify NO MBP reprovou (rc {v.returncode}, hash {got[:12]} vs {want[:12]}): {v.stderr.decode()[:200]}; a pasta {stage} FICA para inspeção")
        return 1
    swap = (f"set -e; B={q(BUNDLE)}; N={q(stage)}; O={q(MGT)}/bundle.old.{stage_id}\n"
            f'[ ! -d "$B/run" ] || mv "$B/run" "$N/run"\n[ ! -e "$B" ] || mv "$B" "$O"\nmv "$N" "$B"\n[ ! -d "$O" ] || find "$O" -delete\n')
    r = pr.rsh(swap)
    if r.returncode != 0:
        pr.say(f"troca do bundle saiu {r.returncode}: {r.stderr.decode()[:200]}")
        return 1
    v = pr.rsh(f"python3 -I {q(MBIN + '/remote-bundle-build.py')} verify {q(BUNDLE)}")
    pr.check("(e) bundle instalado em gt-remote/bundle e conferido NO MBP", v.returncode == 0, v.stderr.decode()[:200])
    with open(SHIM_CLIENT, "rb") as f:
        r = pr.rsh(f"mkdir -p {q(SHIMBIN)} && t=$(mktemp) && cat > \"$t\" && python3 -I \"$t\" install --bin-dir {q(SHIMBIN)} --apply; rc=$?; rm -f \"$t\"; exit $rc", f.read())
    pr.say(f"cliente do atalho: rc {r.returncode} {(r.stdout + r.stderr).decode()[-200:]}")
    r2 = pr.rsh(f"printf %s {q(json.dumps(client_config()))} > {q(SHIMBIN + '/remote-shim.json')} && mkdir -p {q(SPOOL)} && chmod 700 {q(SPOOL)}")
    pr.say(f"remote-shim.json + spool: rc {r2.returncode}")
    os.makedirs(os.path.dirname(WRAPPER_CFG), exist_ok=True)
    with open(WRAPPER_CFG, "w") as f:
        f.write(wc)
    s = pr.snap()
    pr.check("cliente do atalho em shim-bin igual ao do repositório, links bd/gc/gate-done e config da puxada", r.returncode == 0 and r2.returncode == 0 and "_erro" not in s
             and s["shim_sha"] == sha256_file(SHIM_CLIENT) and all(v == "remote-shim" for v in s["links"].values()) and s["client_conf"] == client_config() and s["spool_mode"] == "0o700")
    bad = [n for n, ok in pr.checks if not ok]
    pr.say(f"INSTALAÇÃO {'OK' if not bad else 'COM FALHA: ' + str(bad)}; bundle_hash {want[:12]}")
    return 1 if bad else 0


def _arg(rx: str, what: str):
    def check(v: str) -> str:
        if not re.fullmatch(rx, v):
            raise argparse.ArgumentTypeError(f"{what} inválido: {v!r}")
        return v
    return check


def main(argv: list) -> int:
    ap = argparse.ArgumentParser(prog="mbp-proof", description=__doc__.split("\n")[1])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "e2e"):
        p = sub.add_parser(name)
        p.add_argument("--bead", default="ga-w7qwl1.1", type=_arg(BEAD_RE.pattern, "id de bead"))
        p.add_argument("--model", default="haiku", type=_arg(r"[A-Za-z0-9._-]{1,40}", "modelo"))
        if name == "e2e":
            p.add_argument("--timeout", type=int, default=900)
            p.add_argument("--log", default="")
            p.add_argument("--keep", action="store_true", help="não apaga a pasta de teste nem a marca de confiança no MBP")
            p.add_argument("--delete-branch", action="store_true", help="apaga worker/<rodada> no origin no fim (padrão: fica)")
            p.add_argument("--repo-url", default="", type=_arg(r"(https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|file:///[A-Za-z0-9_./-]+)|", "url do origin"))
    i = sub.add_parser("install")
    i.add_argument("--apply", action="store_true")
    a = ap.parse_args(argv)
    if not SESSION_RE.fullmatch(SESSION):
        ap.error(f"MBP_PROOF_SESSION inválido: {SESSION!r} (remote-test-remote-mbp-<n>)")
    if a.cmd == "e2e" and not 5 <= a.timeout <= 3600:
        ap.error("--timeout vai de 5 a 3600")
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    return {"plan": cmd_plan, "install": cmd_install, "e2e": lambda x: Proof(x).go()}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
