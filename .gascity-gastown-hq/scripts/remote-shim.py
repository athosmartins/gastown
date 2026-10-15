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

CONFIG (JSON em $REMOTE_SHIM_CONF, senão ~/.config/remote-shim/shim.json):
  {"host": "127.0.0.1", "port": 2222, "user": "athos", "identity_file": "/home/runner/.ssh/mini_shim_ed25519",
   "known_hosts_file": "/home/runner/.ssh/mini_shim_known_hosts", "control_dir": "/home/runner/.cache/remote-shim", "connect_timeout": 10}
  `host`, `user`, `identity_file` e `known_hosts_file` são obrigatórios; o resto tem padrão. Config ausente ou ruim → exit 78 e NENHUM ssh.

INSTALAR (nada é gravado sem --apply):
  remote-shim.py install --bin-dir /home/runner/.local/bin [--apply]   # copia este arquivo para <bin-dir>/remote-shim e liga bd, gc, gate-done a ele
  Não sobrescreve um `bd`/`gc`/`gate-done` que já exista e não seja o nosso (exit 3).

CÓDIGOS: o do comando remoto (o ssh passa o código dele adiante) · 255 ssh não conseguiu falar com o mini · 78 config ausente ou ruim (ou pasta da conexão que não dá para criar) ·
  77 pedido recusado pelo wrapper no mini · 2 uso · 3 install recusado · 127 não achei o ssh.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import sys
from pathlib import Path

PROTO = "rs1"
MAX_CMD = 200_000
TOOLS = ("bd", "gc", "gate-done")
# O mesmo conjunto de nomes que o wrapper aceita (ENV_VAL): o selftest compara os dois. GC_SESSION_ID fica de fora de propósito (o wrapper o recusa).
FORWARD_ENV = ("GC_AGENT", "GC_ALIAS", "GC_HOOK_EVENT_NAME", "GC_MANAGED_SESSION_HOOK", "GC_SESSION_NAME",
               "GC_SESSION_ORIGIN", "GC_TEMPLATE")
CONF_KEYS = {"host", "port", "user", "identity_file", "known_hosts_file", "control_dir", "connect_timeout"}


def need(cond: bool) -> None:  # no lugar de assert: `python -O` apaga assert, e uma validação que some com uma flag não é guarda
    if not cond:
        raise ValueError("config fora do formato")


def die(msg: str, rc: int) -> None:
    print(f"remote-shim: {msg}", file=sys.stderr)
    sys.exit(rc)


def load_conf() -> dict:
    path = os.environ.get("REMOTE_SHIM_CONF") or os.path.expanduser("~/.config/remote-shim/shim.json")
    try:
        c = json.loads(Path(path).read_text())
        need(isinstance(c, dict) and not (set(c) - CONF_KEYS) and {"host", "user", "identity_file", "known_hosts_file"} <= set(c))
        c = {"port": 22, "connect_timeout": 10, "control_dir": os.path.expanduser("~/.cache/remote-shim"), **c}
        need(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.:-]{0,252}", str(c["host"])) and re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", str(c["user"])))
        need(isinstance(c["port"], int) and 0 < c["port"] < 65536 and isinstance(c["connect_timeout"], int) and 0 < c["connect_timeout"] <= 120)
        need(all(isinstance(c[k], str) and os.path.isabs(c[k]) for k in ("identity_file", "known_hosts_file", "control_dir")))
        need(os.path.isfile(c["identity_file"]) and os.path.isfile(c["known_hosts_file"]))
    except (OSError, ValueError, TypeError, KeyError):
        die(f"config ausente ou ruim ({path}): preciso de host, user, identity_file e known_hosts_file existentes (ver `remote-shim.py` --help). "
            "Não vou chamar o mini sem a chave do host conferida.", 78)
    return c


def request(tool: str) -> None:
    c = load_conf()
    payload = json.dumps({"tool": tool, "argv": sys.argv[1:], "env": {k: os.environ[k] for k in FORWARD_ENV if k in os.environ}},
                         separators=(",", ":"))  # ensure_ascii: o JSON sai em ASCII puro
    cmd = f"{PROTO} {base64.urlsafe_b64encode(payload.encode()).decode().rstrip('=')}"
    if len(cmd) > MAX_CMD:
        die("pedido grande demais para o ssh (texto longo: use --stdin)", 2)
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
