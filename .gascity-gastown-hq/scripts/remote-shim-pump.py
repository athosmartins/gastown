#!/usr/bin/env python3
"""remote-shim-pump.py — o mini PUXA os pedidos de bd/gc das sessões do MBP (ga-w7qwl1.1). Sem segredo novo no MBP.

## Contents
- Como funciona
- Uso
- Limites e o que o puxador nunca faz

COMO FUNCIONA  (por que o mini puxa em vez do MBP chamar: docs/runbooks/remote-shim.md — o MBP não ganha chave nem credencial nova)
  sessão no MBP -> `bd`/`gc` = remote-shim.py (transport "spool") grava req/<id>.json em <spool_dir> (0700) e espera resp/<id>.json
  mini: este puxador -> ssh -> "agente" (um trecho de Python que este arquivo carrega; NADA fica gravado no MBP) ->
        get:  move req/ -> claimed/ (rename: um pedido é pego uma vez só) e devolve uma linha JSON por pedido
        roda `remote-shim-wrapper.py serve --config <wrapper_config>` com SSH_ORIGINAL_COMMAND = o pedido: a MESMA lista de permissões,
        a MESMA identidade e o MESMO log de auditoria do caminho do Hetzner (o wrapper não sabe o transporte)
        put:  grava resp/<id>.json (inteiro, por rename) só para um pedido que está em claimed/
  O agente também varre arquivos velhos do spool (15 min) e toca pump.alive: o cliente no MBP recusa na hora (75) quando ele está parado.
  Última faxina (ga-w7qwl1.1.7): no `stop`, depois de encerrar o puxador (ou de ver que não havia um), o agente roda em modo `reap` e apaga o que tem mais de REAP_GRACE_S (90 s) em req/, resp/ e claimed/
        (a resposta de um cliente que morreu antes de ler); o que é mais novo fica, porque um puxador novo pode já ter escrito uma resposta que o cliente ainda vai ler.
        Desfechos, numa linha: limpei · não havia (saem 0) · NÃO DEU PARA VER · NÃO DEU PARA LIMPAR (saem 1, com o rc e a última linha do erro). Não cria nada no MBP e não roda com o puxador ainda vivo.

USO  (host e caminhos vêm de `hosts.<host>.shim` em session-ssh.json: spool_dir (no MBP), wrapper_config (no mini), parallel, idle_exit_s, poll_s)
  remote-shim-pump.py ensure --host mbp    sobe o puxador se não houver um (o provedor chama isto depois de abrir uma sessão)
  remote-shim-pump.py run    --host mbp    em primeiro plano (o `ensure` o lança desacoplado)
  remote-shim-pump.py status --host mbp    roda? há quanto tempo? últimos pedidos
  remote-shim-pump.py stop   --host mbp    encerra o puxador (os pedidos em andamento terminam) e faz a última faxina do spool no MBP

LIMITES E O QUE O PUXADOR NUNCA FAZ
  - só roda enquanto <estado>/<host>/running/ tem sessão nossa; sem sessão, sai depois de idle_exit_s (padrão 90 s) e o MBP não é mais tocado (a única exceção é a faxina do `stop`, uma vez, a pedido de quem parou o puxador)
  - não grava nada no MBP fora do spool; não guarda nem repassa argv no log (só ts, host, id, rc, tamanhos, duração)
  - pedido: cmd até 200000 caracteres, entrada padrão até 1 MiB; resposta: stdout e stderr até 8 MiB cada (corta com marca); não repete pedido que o wrapper já iniciou (rc 125 = pode ter rodado: o cliente decide)
  - ssh falhando: espera 2^n s (até 60 s) e tenta de novo; o MBP dormindo/fora não derruba nada, só deixa os pedidos sem resposta (rc 75/125)
"""
from __future__ import annotations

import argparse
import base64
import fcntl
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.realpath(__file__))
WRAPPER = os.path.join(HERE, "remote-shim-wrapper.py")
SPOOL_ID = re.compile(r"[0-9]{13}-[0-9]{1,10}-[0-9a-f]{8}")  # o mesmo formato do cliente (remote-shim.py)
PATH_RE = re.compile(r"/[A-Za-z0-9_./+-]+")
HOST_NAME_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*")
REAP_OUT = re.compile(r"reap ([0-9]+) ([0-9]+) ([0-9]+)")  # o que o modo `reap` do agente imprime: apagados, poupados (dentro da carência), que não saíram
MAX_CMD, MAX_STDIN, MAX_OUT, MAX_BATCH = 200_000, 1 << 20, 8 << 20, 16
WRAPPER_LIMIT_S = 420  # acima do timeout_s padrão (300) do wrapper: se estourar aqui o wrapper travou, e o grupo dele é encerrado

# O agente que roda NO MBP. Vai por `python3 -I -c` (base64 na linha de comando); nada fica gravado lá. Só mexe dentro do spool.
AGENT = r'''
import base64, json, os, re, sys, time
sp, mode = sys.argv[1], sys.argv[2]
ID = re.compile(r"[0-9]{13}-[0-9]{1,10}-[0-9a-f]{8}")
MAXREQ, KEEP_S, ALIVE_EVERY_S = 1500000, 900, 10
REAP_GRACE_S = 90  # carência da faxina do `stop` (modo reap): só sai o que tem MAIS que isto; um puxador novo pode já ter escrito uma resposta que o cliente ainda vai ler
POLL_S = max(1, min(30, int(sys.argv[4]))) if len(sys.argv) > 4 else 15
os.umask(0o077)
try: st = os.lstat(sp)
except FileNotFoundError:  # sem a pasta: reap diz "sem-spool" e sai 0 (a faxina não cria spool no MBP); get/put: o erro sobe como sempre; falhou/ilegível (EACCES…): sobe também
    if mode != "reap": raise
    print("reap sem-spool"); sys.exit(0)
if os.path.islink(sp) or not os.path.isdir(sp) or st.st_uid != os.getuid() or st.st_mode & 0o077:
    sys.stderr.write("spool %s nao e uma pasta minha com modo 0700\n" % sp); sys.exit(78)
if mode != "reap":  # a faxina de parada não cria nada no MBP
    for d in ("req", "resp", "claimed"):
        os.makedirs(sp + "/" + d, 0o700, exist_ok=True)

def alive():
    p = sp + "/pump.alive"
    open(p, "a").close(); os.utime(p, None)

def sweep():
    old = time.time() - KEEP_S
    for d in ("req", "resp", "claimed"):
        for n in os.listdir(sp + "/" + d):
            f = sp + "/" + d + "/" + n
            try:
                if os.lstat(f).st_mtime < old: os.unlink(f)
            except OSError: pass

def write_resp(rid, rc, out, err):
    tmp = sp + "/resp/." + rid + ".tmp"
    with open(tmp, "w") as f:
        f.write(json.dumps({"id": rid, "rc": rc, "stdout_b64": out, "stderr_b64": err}, separators=(",", ":")))
    os.rename(tmp, sp + "/resp/" + rid + ".json")

b64 = lambda s: base64.b64encode(s.encode()).decode()  # noqa: E731

if mode == "get":
    mx = max(1, min(16, int(sys.argv[3])))
    alive(); sweep()
    end, last, got = time.time() + POLL_S, time.time(), 0
    while True:
        names = sorted(n for n in os.listdir(sp + "/req") if n.endswith(".json") and not n.startswith("."))
        for n in names:
            rid = n[:-5]
            if not ID.fullmatch(rid):
                try: os.unlink(sp + "/req/" + n)
                except OSError: pass
                continue
            if got >= mx: break
            try: os.rename(sp + "/req/" + n, sp + "/claimed/" + n)
            except OSError: continue
            got += 1
            try:
                with open(sp + "/claimed/" + n, "rb") as f: raw = f.read(MAXREQ + 1)
                if len(raw) > MAXREQ: raise ValueError("pedido maior que o limite")
                d = json.loads(raw)
                if not (isinstance(d, dict) and d.get("id") == rid and isinstance(d.get("cmd"), str) and isinstance(d.get("stdin_b64"), str)):
                    raise ValueError("forma inesperada")
                print(json.dumps({"id": rid, "cmd": d["cmd"], "stdin_b64": d["stdin_b64"]}, separators=(",", ":")))
            except (OSError, ValueError) as e:
                write_resp(rid, 78, "", b64("pedido ilegivel no spool: %s\n" % e))
                os.unlink(sp + "/claimed/" + n)
        if got:
            sys.stdout.flush(); break
        if time.time() > end: break
        if time.time() - last > ALIVE_EVERY_S: alive(); last = time.time()
        time.sleep(0.05)
elif mode == "put":
    n = 0
    for line in sys.stdin:
        if not line.strip(): continue
        d = json.loads(line)
        rid = d["id"]
        if not ID.fullmatch(rid) or not os.path.exists(sp + "/claimed/" + rid + ".json"): continue
        write_resp(rid, d["rc"], d["stdout_b64"], d["stderr_b64"])
        os.unlink(sp + "/claimed/" + rid + ".json"); n += 1
    print("ok", n)
elif mode == "reap":
    cut, gone, kept, bad = time.time() - REAP_GRACE_S, 0, 0, 0
    for d in ("req", "resp", "claimed"):
        # vazio ou sem a pasta → nada ali; listdir que FALHA (EACCES…) → o erro sobe: sai ≠ 0 e o mini diz que não deu para ver, nunca "nada a limpar"
        try: names = os.listdir(sp + "/" + d)
        except FileNotFoundError: continue
        for n in names:
            f = sp + "/" + d + "/" + n
            # sumiu entre o listdir e agora (o cliente leu a resposta, o puxador pegou o pedido) → já saiu, não conta; mtime ilegível ou unlink que falha → conta em `bad`, nunca como apagado
            try:
                if os.lstat(f).st_mtime >= cut: kept += 1
                else: os.unlink(f); gone += 1
            except FileNotFoundError: pass
            except OSError: bad += 1
    print("reap", gone, kept, bad)
else:
    sys.stderr.write("modo desconhecido\n"); sys.exit(64)
'''


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Cfg:
    def __init__(self, host: str) -> None:
        self.city = os.path.dirname(HERE)
        path = os.environ.get("GC_SSH_CONFIG") or os.path.join(self.city, ".gc", "session-ssh.json")
        try:
            with open(path) as f:
                raw = json.load(f)
        except (OSError, ValueError) as e:
            raise SystemExit(f"remote-shim-pump: configuração ilegível em {path}: {e}")
        h = ((raw or {}).get("hosts") or {}).get(host) if isinstance(raw, dict) else None
        if not isinstance(h, dict) or not HOST_NAME_RE.fullmatch(host):
            raise SystemExit(f"remote-shim-pump: host {host!r} não está em {path}")
        s = h.get("shim")
        if not isinstance(s, dict):
            raise SystemExit(f"remote-shim-pump: host {host}: sem o bloco `shim` (spool_dir, wrapper_config) na config")
        self.host, self.ssh = host, h.get("ssh")
        self.spool = s.get("spool_dir")
        self.wrapper_cfg = s.get("wrapper_config")
        self.parallel, self.idle_s, self.poll_s = s.get("parallel", 4), s.get("idle_exit_s", 90), s.get("poll_s", 15)
        self.connect_timeout = h.get("connect_timeout", 10)
        self.ssh_opts = [str(x) for x in h.get("ssh_opts") or []]
        self.path_extra = [x for x in h.get("path_extra") or [] if isinstance(x, str) and PATH_RE.fullmatch(x)]
        ok = (isinstance(self.ssh, str) and re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.@:-]*", self.ssh)
              and isinstance(self.spool, str) and PATH_RE.fullmatch(self.spool) and ".." not in self.spool.split("/")
              and isinstance(self.wrapper_cfg, str) and os.path.isabs(self.wrapper_cfg)
              and all(type(v) is int and 1 <= v <= 600 for v in (self.parallel, self.idle_s, self.connect_timeout, self.poll_s))
              and self.parallel <= 16 and self.poll_s <= 30)
        if not ok:
            raise SystemExit(f"remote-shim-pump: host {host}: bloco `shim` ou `ssh` inválido (spool_dir absoluto sem '..', wrapper_config absoluto, parallel<=16, idle_exit_s 1-600, poll_s 1-30)")
        base = os.environ.get("GC_EXEC_STATE_DIR") or os.path.join(self.city, ".gc", "runtime", "session-ssh")
        self.state = os.path.join(base, re.sub(r"[^A-Za-z0-9_.-]", "_", host))

    def sshv(self) -> list:
        a = [os.environ.get("GC_SSH_BIN") or "ssh", "-o", "BatchMode=yes", "-o", f"ConnectTimeout={self.connect_timeout}",
             "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3"]
        cm = os.path.join(os.path.expanduser("~"), ".ssh", "cm")  # a mesma conexão multiplexada do provedor e do mbp-run.sh
        try:
            os.makedirs(cm, 0o700, exist_ok=True)
            a += ["-o", "ControlMaster=auto", "-o", f"ControlPath={cm}/%C", "-o", "ControlPersist=600"]
        except OSError:
            pass
        return a + self.ssh_opts + [self.ssh]

    def agent_cmd(self, mode: str, *extra: str) -> str:
        code = base64.b64encode(AGENT.encode()).decode()
        path = "".join(d + ":" for d in self.path_extra) + "$PATH"
        return (f"export PATH={path}; exec python3 -I -c "
                + shlex.quote(f"import base64;exec(base64.b64decode('{code}').decode())") + " " + " ".join(shlex.quote(x) for x in (self.spool, mode) + extra))

    def registry_busy(self) -> bool:
        try:
            return bool(os.listdir(os.path.join(self.state, "running")))
        except FileNotFoundError:
            return False
        except OSError:
            return True  # não consegui ler: não sei, e "não sei" mantém o puxador de pé

    def log(self, msg: str) -> None:
        try:
            os.makedirs(self.state, 0o700, exist_ok=True)
            with open(os.path.join(self.state, "shim-pump.log"), "a") as f:
                f.write(f"{now()} {self.host} {msg}\n")
        except OSError:
            pass


class Pump:
    def __init__(self, cfg: Cfg) -> None:
        self.cfg, self.stop = cfg, False
        self.cv, self.inflight = threading.Condition(), 0
        self.ssh_child = None

    def ssh_run(self, mode: str, *extra: str, stdin: bytes = b"", timeout: int = 40) -> tuple:
        argv = self.cfg.sshv() + [self.cfg.agent_cmd(mode, *extra)]
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if mode == "get":
            self.ssh_child = p
        try:
            out, err = p.communicate(stdin, timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            out, err = p.communicate()
            return 255, out, err + b"\nremote-shim-pump: ssh passou do prazo"
        finally:
            if mode == "get":
                self.ssh_child = None
        return p.returncode, out, err

    def run_wrapper(self, cmd: str, stdin: bytes) -> tuple:
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.path.expanduser("~"), "LANG": "en_US.UTF-8",
               "SSH_ORIGINAL_COMMAND": cmd, "SSH_CLIENT": ""}  # SSH_CLIENT vazio: o wrapper registra "?" (não houve conexão ssh de entrada)
        p = subprocess.Popen([sys.executable, "-I", WRAPPER, "serve", "--config", self.cfg.wrapper_cfg], env=env, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            out, err = p.communicate(stdin, timeout=WRAPPER_LIMIT_S)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGTERM)  # o wrapper tem handler: encerra o filho (bd/gc) e anota no log dele
            except OSError:
                pass
            try:
                out, err = p.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except OSError:
                    pass
                out, err = p.communicate()
            return 125, out, err + b"\nremote-shim-pump: o wrapper passou do prazo e foi encerrado; pode ter rodado"
        rc = p.returncode
        return (128 - rc if rc < 0 else rc) & 0xFF, out, err

    @staticmethod
    def cut(b: bytes) -> bytes:
        return b if len(b) <= MAX_OUT else b[:MAX_OUT] + b"\n[... cortado pelo puxador em 8 MiB ...]\n"

    def job(self, rid: str, cmd: str, stdin: bytes) -> None:
        t0 = time.time()
        try:
            rc, out, err = self.run_wrapper(cmd, stdin)
            out, err = self.cut(out), self.cut(err)
            line = json.dumps({"id": rid, "rc": rc, "stdout_b64": base64.b64encode(out).decode(), "stderr_b64": base64.b64encode(err).decode()},
                              separators=(",", ":")).encode() + b"\n"
            put = "?"
            for i in range(3):  # a resposta é do pedido que JÁ rodou: perdê-la por um solavanco do ssh faria o cliente esperar até o prazo
                prc, pout, perr = self.ssh_run("put", stdin=line, timeout=60)
                if prc == 0 and pout.split() == [b"ok", b"1"]:
                    put = "ok"
                    break
                if prc == 0 and pout.split() == [b"ok", b"0"]:  # o agente rodou mas não entregou: o pedido não estava em claimed/ (repetir não o traz de volta)
                    put = "NÃO CONFIRMADA (ok 0: o pedido não estava em claimed/; se uma tentativa anterior caiu, ela pode ter entregue)"
                    break
                put = f"falhou rc={prc}"
                time.sleep(2 ** i)
            self.cfg.log(f"id={rid} rc={rc} out={len(out)} err={len(err)} dur={time.time() - t0:.2f}s put={put}")
        except Exception as e:  # um pedido que quebra o puxador não pode derrubar os outros
            self.cfg.log(f"id={rid} ERRO {type(e).__name__}: {str(e)[:120]}")
        finally:
            with self.cv:
                self.inflight -= 1
                self.cv.notify_all()

    def serve(self) -> int:
        cfg = self.cfg
        os.makedirs(cfg.state, 0o700, exist_ok=True)
        lock = open(os.path.join(cfg.state, "shim-pump.lock"), "a")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("remote-shim-pump: já há um puxador rodando")
            return 0
        except OSError as e:  # o flock FALHOU (ENOLCK…): isso não é "já há um"; sem o lock não subo, e o motivo fica no stderr do puxador
            print(f"remote-shim-pump: não consegui travar o lock ({e.strerror}); não subo às cegas", file=sys.stderr)
            return 1
        pidf = os.path.join(cfg.state, "shim-pump.pid")
        with open(pidf, "w") as f:
            f.write(str(os.getpid()))

        def on_term(_s, _f):
            self.stop = True
            c = self.ssh_child
            if c:
                try:
                    c.terminate()
                except OSError:
                    pass
        signal.signal(signal.SIGTERM, on_term)
        signal.signal(signal.SIGINT, on_term)
        cfg.log(f"puxador iniciado pid={os.getpid()} parallel={cfg.parallel} idle_exit_s={cfg.idle_s}")
        ex, idle_since, fails = ThreadPoolExecutor(max_workers=cfg.parallel, thread_name_prefix="shim"), None, 0
        try:
            while not self.stop:
                if cfg.registry_busy():
                    idle_since = None
                else:
                    idle_since = idle_since or time.time()
                    if time.time() - idle_since > cfg.idle_s:
                        cfg.log("sem sessão registrada: puxador encerrando")
                        break
                with self.cv:
                    while self.inflight >= cfg.parallel and not self.stop:
                        self.cv.wait(1.0)
                    free = cfg.parallel - self.inflight
                if self.stop:
                    break
                rc, out, err = self.ssh_run("get", str(free), str(cfg.poll_s), timeout=cfg.poll_s + 30)
                if rc != 0:
                    fails += 1
                    wait = min(60, 2 ** fails)
                    if fails in (1, 5) or fails % 20 == 0:
                        cfg.log(f"get falhou rc={rc} ({fails}ª seguida; espero {wait}s): {err.decode(errors='replace').strip()[:160]}")
                    for _ in range(wait * 5):
                        if self.stop:
                            break
                        time.sleep(0.2)
                    continue
                fails = 0
                for ln in out.decode(errors="replace").splitlines()[:MAX_BATCH]:
                    try:
                        d = json.loads(ln)
                        rid, cmd = d["id"], d["cmd"]
                        stdin = base64.b64decode(d["stdin_b64"], validate=True)
                        ok = SPOOL_ID.fullmatch(rid) and isinstance(cmd, str) and 0 < len(cmd) <= MAX_CMD and len(stdin) <= MAX_STDIN
                    except (ValueError, KeyError, TypeError):
                        ok = False
                    if not ok:
                        cfg.log("linha do agente recusada (fora do formato)")
                        continue
                    with self.cv:
                        self.inflight += 1
                    ex.submit(self.job, rid, cmd, stdin)
        finally:
            ex.shutdown(wait=True)
            cfg.log("puxador encerrado")
            try:
                os.unlink(pidf)
            except OSError:
                pass
        return 0


def pid_of(cfg: Cfg) -> int:
    try:
        pid = int(open(os.path.join(cfg.state, "shim-pump.pid")).read().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return 0


def held(cfg: Cfg) -> bool:
    """O puxador segura o flock enquanto vive (o pid sozinho pode ser de um processo que morreu e foi reaproveitado)."""
    try:
        f = open(os.path.join(cfg.state, "shim-pump.lock"), "a")
    except FileNotFoundError:
        return False  # a pasta de estado nem existe: o puxador nunca rodou aqui
    except OSError as e:
        raise SystemExit(f"remote-shim-pump: não consegui abrir o lock ({e.strerror}); não sei se há puxador rodando e não vou adivinhar")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(f, fcntl.LOCK_UN)
        return False
    except BlockingIOError:
        return True  # outro processo segura o flock: é o puxador vivo
    except OSError as e:  # ENOLCK, EBADF…: o flock falhou, o lock não está "ocupado"
        raise SystemExit(f"remote-shim-pump: não consegui testar o lock ({e.strerror}); não sei se há puxador rodando e não vou adivinhar")
    finally:
        f.close()


def stop_pump(cfg: Cfg) -> int:
    """Encerra o puxador (os pedidos em andamento terminam): 0 = encerrado ou não havia; 1 = não consegui."""
    if not held(cfg):
        print("remote-shim-pump: não há puxador rodando")
        return 0
    pid = pid_of(cfg)
    if not pid:
        print("remote-shim-pump: o lock está preso (há um puxador), mas não consegui ler o pid dele; não encerro às cegas", file=sys.stderr)
        return 1
    os.kill(pid, signal.SIGTERM)
    for _ in range(100):
        if not held(cfg):
            print("remote-shim-pump: encerrado")
            return 0
        time.sleep(0.2)
    print("remote-shim-pump: SIGTERM enviado, mas ainda termina pedidos em andamento", file=sys.stderr)
    return 1


def reap_spool(cfg: Cfg) -> int:
    """A última faxina do spool no MBP, depois do `stop` (ga-w7qwl1.1.7): a resposta que ninguém leu não fica lá até o próximo `ensure`.
    Quatro desfechos: limpei · não havia (saem 0) · NÃO DEU PARA VER · NÃO DEU PARA LIMPAR (saem 1, e a linha diz por quê): faxina que não rodou, ou rodou pela metade, nunca vira "ok" calado."""
    try:
        rc, out, err = Pump(cfg).ssh_run("reap", timeout=25)
    except OSError as e:  # nem consegui lançar o ssh (binário ausente…): o mesmo desfecho de um ssh que falhou
        rc, out, err = 255, b"", f"não consegui lançar o ssh: {e.strerror}".encode()
    text = out.decode(errors="replace").strip()
    # vazio ou fora da forma → NÃO DEU PARA VER, nunca "não havia"; falhou (ssh fora, 78 do spool, traceback do agente) → o mesmo, com o rc e a ÚLTIMA linha do erro (a do traceback é a que nomeia a exceção)
    m = REAP_OUT.fullmatch(text) if rc == 0 else None
    code = 1
    if rc == 0 and text == "reap sem-spool":
        msg, code = "não havia (o MBP não tem a pasta do spool)", 0
    elif m is None:
        lines = err.decode(errors="replace").strip().splitlines()
        why = lines[-1] if lines else (f"resposta fora da forma: {text[:60]!r}" if rc == 0 else "sem mensagem")
        msg = f"NÃO DEU PARA VER (ssh/agente rc={rc}: {why[:160]})"
    else:
        gone, kept, bad = (int(x) for x in m.groups())
        spared = f"; poupei {kept} dentro da carência" if kept else ""
        if bad:
            msg = f"NÃO DEU PARA LIMPAR TUDO: limpei {gone}, mas {bad} arquivo(s) velho(s) não saíram (apagar falhou); a sobra fica para o próximo sweep ou stop{spared}"
        elif gone:
            msg, code = f"limpei {gone} arquivo(s) velho(s){spared}", 0
        else:
            msg, code = f"não havia nada velho{spared}", 0
    cfg.log(f"faxina de parada: {msg}")
    print(f"remote-shim-pump: faxina do spool: {msg}", file=sys.stderr if code else sys.stdout)
    return code


def main(argv: list) -> int:
    ap = argparse.ArgumentParser(prog="remote-shim-pump.py", description=__doc__.split("## Contents")[0].strip())
    ap.add_argument("cmd", choices=["run", "ensure", "status", "stop"])
    ap.add_argument("--host", required=True)
    a = ap.parse_args(argv)
    cfg = Cfg(a.host)
    if a.cmd == "run":
        return Pump(cfg).serve()
    if a.cmd == "status":
        print(f"host={cfg.host} rodando={'sim' if held(cfg) else 'nao'} pid={pid_of(cfg) or '-'} sessoes_registradas={'sim' if cfg.registry_busy() else 'nao'}")
        try:
            print("".join(open(os.path.join(cfg.state, "shim-pump.log")).readlines()[-5:]), end="")
        except FileNotFoundError:
            pass  # nunca rodou: não há rabo de log a mostrar
        except OSError as e:
            print(f"log do puxador ilegível ({e.strerror})")
        return 0
    if a.cmd == "stop":
        rc = stop_pump(cfg)
        if rc:
            return rc  # não parou: com o puxador vivo há pedido em andamento em claimed/, e o sweep dele cuida do resto
        return reap_spool(cfg)
    # ensure: lança desacoplado se ninguém segura o lock; falhar aqui nunca pode derrubar quem chamou (o provedor)
    if held(cfg):
        return 0
    os.makedirs(cfg.state, 0o700, exist_ok=True)
    log = open(os.path.join(cfg.state, "shim-pump.stderr"), "a")
    subprocess.Popen([sys.executable, "-I", os.path.realpath(__file__), "run", "--host", cfg.host], stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                     start_new_session=True, close_fds=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
