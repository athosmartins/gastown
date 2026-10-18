#!/usr/bin/env python3
"""remote-shim.py — lado do SERVIDOR do atalho bd/gc/gate-done (ga-2hd02v.1.2, desenho do ga-ukxa3k). Fala com
remote-shim-wrapper.py, que roda no mini como forced-command da chave deste servidor.

Contents
  Como funciona · Config · Instalar · Códigos de saída

COMO FUNCIONA
  Este arquivo é instalado três vezes com nomes diferentes (`bd`, `gc`, `gate-done`, symlinks para ele) em /home/runner/.local/bin — o
  PATH que o gc injeta nos hooks (`$HOME/go/bin:$HOME/.local/bin`). Chamado como `gc prime --hook`, ele empacota {tool, argv, env}
  em `rs1 <base64url do JSON>` e SUBSTITUI o próprio processo por um `ssh` ao mini (execvp: stdin, stdout e o código de saída são os
  do comando remoto; um hook que lê o JSON da sessão no stdin continua funcionando). Quem decide se o pedido vale é o wrapper no mini;
  aqui só se garante que o pedido não se perde nem ganha poder: o `env` enviado é só a identidade da sessão (FORWARD_ENV — o wrapper
  recusa qualquer outra variável), e o ssh sobe sem agente, sem X11, sem encaminhamento, sem tty, só com a chave dedicada
  (IdentitiesOnly) e com a chave do host conferida (StrictHostKeyChecking=yes contra known_hosts_file: sem confiar na primeira vez).
  As sessões compartilham UMA conexão (ControlMaster) para não pagar o aperto de mão ssh a cada hook.

TRANSPORTE POR PUXADA (`"transport": "spool"`, o do MBP — ga-w7qwl1.1)
  O MBP não pode ganhar chave nova (aceite do ga-w7qwl1), então este lado NÃO fala com o mini: deixa o pedido (o mesmo `rs1 <base64url>` mais
  a entrada padrão) num spool privado (`spool_dir`, 0700, do dono) e espera a resposta. Quem puxa é o MINI (scripts/remote-shim-pump.py, pelo ssh
  que ele já usa para o MBP): roda o pedido no wrapper de sempre (mesma lista permitida) e devolve stdout, stderr e o código de saída, que
  este lado repete. Sem o mini puxando (o puxador toca `pump.alive` a cada ida e volta) o pedido nem é enviado: sai 75 na hora, não pendura o hook.
  Pedido que o mini já pegou e não respondeu no prazo sai 125 (pode ter rodado; não repita às cegas); pedido que ninguém pegou é retirado e sai 75.

CONFIG (JSON em $REMOTE_SHIM_CONF, senão `remote-shim.json` ao lado do script instalado, se existir, senão ~/.config/remote-shim/shim.json):
  {"host": "127.0.0.1", "port": 2222, "user": "athos", "identity_file": "/home/runner/.ssh/mini_shim_ed25519",
   "known_hosts_file": "/home/runner/.ssh/mini_shim_known_hosts", "control_dir": "/home/runner/.cache/remote-shim", "connect_timeout": 10}
  `host`, `user`, `identity_file` e `known_hosts_file` são obrigatórios; o resto tem padrão. Config ausente ou ruim → exit 78 e NENHUM ssh.
  Por puxada: {"transport": "spool", "spool_dir": "/Users/athos/gt-remote/shim", "timeout_s": 330}  (timeout_s 5-3600; padrão 330, acima dos 300 s do wrapper)

INSTALAR (nada é gravado sem --apply):
  remote-shim.py install --bin-dir /home/runner/.local/bin [--apply]   # copia este arquivo para <bin-dir>/remote-shim e liga bd, gc, gate-done a ele
  Não sobrescreve um `bd`/`gc`/`gate-done` que já exista e não seja o nosso (exit 3).

CÓDIGOS: o do comando remoto (o ssh passa o código dele adiante) · 255 ssh não conseguiu falar com o mini · 78 config ausente ou ruim (ou pasta da conexão que não dá para criar) ·
  77 pedido recusado pelo wrapper no mini · 2 uso · 3 install recusado · 127 não achei o ssh · só na puxada: 75 nada rodou (o mini não puxa, ou ninguém pegou o pedido
  a tempo) · 125 o mini pegou o pedido e não devolveu a resposta (pode ter rodado).
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import select
import shutil
import sys
import time
from pathlib import Path

PROTO = "rs1"
MAX_CMD = 200_000
TOOLS = ("bd", "gc", "gate-done")
# O mesmo conjunto de nomes que o wrapper aceita (ENV_VAL): o selftest compara os dois. GC_SESSION_ID fica de fora de propósito (o wrapper o recusa).
FORWARD_ENV = ("GC_AGENT", "GC_ALIAS", "GC_HOOK_EVENT_NAME", "GC_MANAGED_SESSION_HOOK", "GC_SESSION_NAME",
               "GC_SESSION_ORIGIN", "GC_TEMPLATE")
CONF_KEYS = {"host", "port", "user", "identity_file", "known_hosts_file", "control_dir", "connect_timeout"}
SPOOL_KEYS = {"transport", "spool_dir", "timeout_s"}
SPOOL_ID = re.compile(r"[0-9]{13}-[0-9]{1,10}-[0-9a-f]{8}")  # o puxador (remote-shim-pump.py) confere o MESMO formato
ALIVE_MAX_S = 60   # o puxador toca pump.alive a cada ida e volta (no máximo ~15 s); mais velho que isto = ninguém está puxando
MAX_STDIN = 1_000_000


def need(cond: bool) -> None:  # no lugar de assert: `python -O` apaga assert, e uma validação que some com uma flag não é guarda
    if not cond:
        raise ValueError("config fora do formato")


def die(msg: str, rc: int) -> None:
    print(f"remote-shim: {msg}", file=sys.stderr)
    sys.exit(rc)


def conf_path() -> str:
    """$REMOTE_SHIM_CONF; senão `remote-shim.json` ao lado do script instalado (o MBP: a sessão não leva variável nova e nada vai para o ~/.config do Athos); senão o padrão."""
    if os.environ.get("REMOTE_SHIM_CONF"):
        return os.environ["REMOTE_SHIM_CONF"]
    beside = os.path.join(os.path.dirname(os.path.realpath(__file__)), "remote-shim.json")  # vazio (sem arquivo ao lado) → o padrão; ilegível → load_conf sai 78 dizendo ESTE caminho
    return beside if os.path.isfile(beside) else os.path.expanduser("~/.config/remote-shim/shim.json")


def load_conf() -> dict:
    path = conf_path()
    try:
        c = json.loads(Path(path).read_text())
        need(isinstance(c, dict))
        if c.get("transport") == "spool":  # por puxada: nada de host, usuário nem chave
            need(not (set(c) - SPOOL_KEYS) and isinstance(c.get("spool_dir"), str) and os.path.isabs(c["spool_dir"]))
            c = {"timeout_s": 330, **c}
            need(type(c["timeout_s"]) is int and 5 <= c["timeout_s"] <= 3600)
            return c
        need("transport" not in c or c["transport"] == "ssh")
        c = {k: v for k, v in c.items() if k != "transport"}
        need(not (set(c) - CONF_KEYS) and {"host", "user", "identity_file", "known_hosts_file"} <= set(c))
        c = {"port": 22, "connect_timeout": 10, "control_dir": os.path.expanduser("~/.cache/remote-shim"), **c}
        need(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.:-]{0,252}", str(c["host"])) and re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", str(c["user"])))
        need(isinstance(c["port"], int) and 0 < c["port"] < 65536 and isinstance(c["connect_timeout"], int) and 0 < c["connect_timeout"] <= 120)
        need(all(isinstance(c[k], str) and os.path.isabs(c[k]) for k in ("identity_file", "known_hosts_file", "control_dir")))
        need(os.path.isfile(c["identity_file"]) and os.path.isfile(c["known_hosts_file"]))
    except (OSError, ValueError, TypeError, KeyError):
        die(f"config ausente ou ruim ({path}): preciso de host, user, identity_file e known_hosts_file existentes (ver `remote-shim.py` --help). "
            "Não vou chamar o mini sem a chave do host conferida.", 78)
    return c


def read_stdin() -> bytes:
    """A entrada padrão do comando, sem pendurar: tty, /dev/null, arquivo e pipe que fecha dão o que há; pipe aberto e mudo (ninguém escreve em 0,3 s) dá vazio."""
    try:
        fd = sys.stdin.fileno()
        if os.isatty(fd):
            return b""
    except (OSError, ValueError):  # entrada fechada
        return b""
    chunks, total, first = [], 0, True
    while True:
        try:
            if select.select([fd], [], [], 0.3 if first else 2.0)[0] == []:  # o claude escreve o JSON do hook de uma vez e fecha: silêncio = ninguém vai escrever
                break
            b = os.read(fd, 65536)
        except OSError:
            break
        if not b:
            break
        first, total = False, total + len(b)
        chunks.append(b)
        if total > MAX_STDIN:
            die(f"entrada padrão maior que {MAX_STDIN} bytes", 2)
    return b"".join(chunks)


def spool_poll(path: str):
    """A resposta já gravada (o puxador a põe com rename: ou existe inteira ou não existe), ou None."""
    try:
        with open(path, "rb") as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        die("resposta do mini ilegível; o pedido pode ter rodado — não repita às cegas", 125)


def spool_request(c: dict, cmd: str) -> None:
    sp = c["spool_dir"]
    try:  # o spool é do dono e de mais ninguém: outro usuário da máquina que pudesse escrever aqui mandaria pedidos com a identidade das sessões
        os.makedirs(sp, mode=0o700, exist_ok=True)
        st = os.lstat(sp)
        need(os.path.isdir(sp) and not os.path.islink(sp) and st.st_uid == os.getuid() and not st.st_mode & 0o077)  # confere ANTES de criar qualquer coisa dentro
        for d in ("req", "resp"):
            os.makedirs(f"{sp}/{d}", mode=0o700, exist_ok=True)
    except (OSError, ValueError):
        die(f"spool {sp} não é uma pasta minha com modo 0700 (ou não consegui criá-la)", 78)
    try:
        age = time.time() - os.stat(f"{sp}/pump.alive").st_mtime
    except OSError:
        age = None
    if age is None or age > ALIVE_MAX_S:  # sem o mini puxando o pedido ficaria parado até o prazo e travaria o hook: falha na hora, e nada rodou
        die("o mini não está puxando pedidos (pump.alive " + ("ausente" if age is None else f"parado há {int(age)} s") + "); nada foi enviado", 75)
    stdin = read_stdin()
    rid = f"{int(time.time() * 1000)}-{os.getpid()}-{os.urandom(4).hex()}"
    doc = json.dumps({"v": 1, "id": rid, "cmd": cmd, "stdin_b64": base64.b64encode(stdin).decode()}, separators=(",", ":"))
    tmp, req, rsp = f"{sp}/req/.{rid}.tmp", f"{sp}/req/{rid}.json", f"{sp}/resp/{rid}.json"
    try:  # gravado inteiro e só então publicado com rename: o puxador nunca lê um pedido pela metade
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(doc)
        os.rename(tmp, req)
    except OSError as e:
        die(f"não consegui gravar o pedido no spool: {e.strerror}", 75)
    t0 = time.time()
    while True:
        r = spool_poll(rsp)
        if r is not None:
            break
        if time.time() - t0 > c["timeout_s"]:
            try:
                os.unlink(req)  # ainda parado no spool = ninguém pegou: retirado, nada rodou
            except FileNotFoundError:  # já foi pego: pode ter rodado. Dou mais um tempo à resposta antes de desistir
                for _ in range(150):
                    r = spool_poll(rsp)
                    if r is not None:
                        break
                    time.sleep(0.1)
                if r is None:
                    die(f"o mini pegou o pedido {rid} e não devolveu a resposta em {c['timeout_s']} s; pode ter rodado — não repita às cegas", 125)
                break
            except OSError as e:
                die(f"estourou o prazo e não consegui retirar o pedido: {e.strerror}; pode ter rodado — não repita às cegas", 125)
            die(f"o mini não pegou o pedido em {c['timeout_s']} s; ele foi retirado e NADA rodou", 75)
        time.sleep(0.02 if time.time() - t0 < 2 else 0.1)
    try:
        out, err, rc = base64.b64decode(r["stdout_b64"], validate=True), base64.b64decode(r["stderr_b64"], validate=True), r["rc"]
        need(type(rc) is int and 0 <= rc <= 255 and r.get("id") == rid)
    except (KeyError, TypeError, ValueError):
        die("resposta do mini com forma inesperada; o pedido pode ter rodado — não repita às cegas", 125)
    try:
        os.unlink(rsp)
    except OSError:
        pass  # a faxina do puxador leva o que sobrar
    sys.stdout.buffer.write(out)
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(err)
    sys.stderr.buffer.flush()
    sys.exit(rc)


def request(tool: str) -> None:
    c = load_conf()
    payload = json.dumps({"tool": tool, "argv": sys.argv[1:], "env": {k: os.environ[k] for k in FORWARD_ENV if k in os.environ}},
                         separators=(",", ":"))  # ensure_ascii: o JSON sai em ASCII puro
    cmd = f"{PROTO} {base64.urlsafe_b64encode(payload.encode()).decode().rstrip('=')}"
    if len(cmd) > MAX_CMD:
        die("pedido grande demais para o ssh (texto longo: use --stdin)", 2)
    if c.get("transport") == "spool":
        spool_request(c, cmd)  # não volta: sai com o código do comando
    try:
        os.makedirs(c["control_dir"], mode=0o700, exist_ok=True)
    except OSError as e:  # sem a pasta o ControlPath não existe; e um crash sairia 1, que o `gc mail check` usa para "caixa vazia"
        die(f"não consegui criar a pasta da conexão multiplexada ({c['control_dir']}): {e.strerror}", 78)
    o = lambda s: ["-o", s]  # noqa: E731
    ssh = (["ssh", "-F", "/dev/null", "-T", "-a", "-x", "-i", c["identity_file"], "-p", str(c["port"])]
           + o("BatchMode=yes") + o("IdentitiesOnly=yes") + o("IdentityAgent=none") + o("PasswordAuthentication=no")
           + o("StrictHostKeyChecking=yes") + o(f"UserKnownHostsFile={c['known_hosts_file']}") + o("GlobalKnownHostsFile=/dev/null")
           + o("ForwardAgent=no") + o("ForwardX11=no") + o("ClearAllForwardings=yes") + o("PermitLocalCommand=no")
           + o(f"ConnectTimeout={c['connect_timeout']}") + o("ServerAliveInterval=15") + o("ServerAliveCountMax=3")
           + o("ControlMaster=auto") + o("ControlPersist=600") + o(f"ControlPath={c['control_dir']}/cm-%C") + o("LogLevel=ERROR")
           + ["--", f"{c['user']}@{c['host']}", cmd])
    try:
        os.execvp("ssh", ssh)
    except OSError as e:
        die(f"não consegui executar o ssh: {e.strerror}", 127)


def install(bin_dir: str, apply: bool) -> int:
    d, me = Path(bin_dir), Path(os.path.realpath(__file__))
    dest = d / "remote-shim"
    plan = [f"copiar {me} -> {dest}"] + [f"ligar {d / t} -> remote-shim" for t in TOOLS]
    for t in TOOLS:
        p = d / t
        if (p.exists() or p.is_symlink()) and not (p.is_symlink() and os.readlink(p) == "remote-shim"):
            print(f"remote-shim install: RECUSADO: {p} já existe e não é o nosso atalho; não sobrescrevo", file=sys.stderr)
            return 3
    print("\n".join(("" if apply else "[dry-run] ") + x for x in plan))
    if not apply:
        print("[dry-run] nada foi gravado; repita com --apply")
        return 0
    d.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(me, dest)
    dest.chmod(0o755)
    for t in TOOLS:
        if not (d / t).is_symlink():
            os.symlink("remote-shim", d / t)
    return 0


def main(argv: list[str]) -> int:
    name = os.path.basename(sys.argv[0])
    if name in TOOLS:
        request(name)  # não volta: ou execvp, ou sai
    ap = argparse.ArgumentParser(prog="remote-shim.py", description=__doc__.split("Contents")[0].strip())
    sub = ap.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("install")
    i.add_argument("--bin-dir", required=True)
    i.add_argument("--apply", action="store_true")
    sub.add_parser("forward-env")
    a = ap.parse_args(argv)
    if a.cmd == "forward-env":
        print("\n".join(FORWARD_ENV))
        return 0
    return install(a.bin_dir, a.apply)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
