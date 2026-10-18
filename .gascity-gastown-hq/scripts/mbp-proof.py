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
  e2e [--bead ID] [--model M] [--timeout S] [--keep] [--delete-branch]   a prova (a–e) com o MBP livre; ver abaixo (NÃO está nesta fatia: vem em ga-w7qwl1.1.4).

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

CÓDIGOS  0 tudo passou · 1 alguma prova reprovou · 2 uso · 3 não consegui começar (pré-condição) · 4 interrompida: o Athos voltou ao MBP (nada mais foi medido; a sessão é parada)
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

PROMPT = """This is a minimal end-to-end check of a worker running on a laptop. Do exactly the steps below, one Bash call each, in order. Do not ask questions, \
do not edit any other file. If a step fails, still run the remaining steps, then finish with: FAILED step <n>.
1. command -v bd gc
2. bd show {bead} --json
3. bd comment {bead} "{name}: sessao remota no MBP {run} leu esta bead"
4. mkdir -p mbp-proof && echo "mbp-proof {run}" > mbp-proof/{run}.txt && git add mbp-proof/{run}.txt && git commit -m "chore(mbp-proof): {run} (sem dado, descartavel)"
5. git push origin HEAD:refs/heads/worker/{run}
6. echo E2E-$((6*7))-OK
"""


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


class Proof:
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
    if "/Users/" in d["command"].replace(MHOME, "").replace(MINI_HOME, "") and MHOME != MINI_HOME:
        bad.append("sobrou caminho do mini no comando")
    for b in bad:
        print("PROBLEMA:", b)
    return 1 if bad else 0


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
    if "_erro" in s or s["tmux"]["rc"] == 0 and s["tmux"]["out"]:
        pr.say(f"NAO INSTALEI: sessão aberta no socket do provider, ou o MBP não respondeu: {s.get('_erro') or s['tmux']['out']}")
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
    for name in ("plan",):
        p = sub.add_parser(name)
        p.add_argument("--bead", default="ga-w7qwl1.1", type=_arg(BEAD_RE.pattern, "id de bead"))
        p.add_argument("--model", default="haiku", type=_arg(r"[A-Za-z0-9._-]{1,40}", "modelo"))
    i = sub.add_parser("install")
    i.add_argument("--apply", action="store_true")
    a = ap.parse_args(argv)
    if not SESSION_RE.fullmatch(SESSION):
        ap.error(f"MBP_PROOF_SESSION inválido: {SESSION!r} (remote-test-remote-mbp-<n>)")
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    return {"plan": cmd_plan, "install": cmd_install}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
