#!/usr/bin/env python3
"""hq-sandbox-run.py — roda um comando numa jaula Landlock SEM root: escrita só nas pastas dadas e nenhuma conexão TCP (ga-2hd02v.5.6.1).

## Contents
  Por quê · Uso · O que a jaula barra e o que não barra · Códigos de saída · Prova

POR QUÊ: o lastro do nó Hetzner vai rodar MUTANTES de scripts do hq (um `-z` virado em `-n`, um `&&` virado em `||`) como `runner`, o mesmo usuário que tem ~/gt-remote. O nó não tem bwrap,
  o AppArmor barra userns sem privilégio e o único helper de root (gt-netns-run) só corta a rede: um mutante que derruba uma guarda poderia apagar o que o `runner` alcança. O Landlock (kernel
  6.8 do nó, ABI 4) é o único isolamento de arquivos que o `runner` consegue pôr em si mesmo, sem root, sem pedir nada a ninguém.
USO: hq-sandbox-run.py [--rw DIR]... -- CMD [ARG...]   confina este processo e dá exec no comando (o Landlock vale para os filhos e não sai)
     hq-sandbox-run.py --probe                          imprime a ABI do Landlock (`HQSB: abi=N`) ou `HQSB: indisponivel <motivo>` (rc 97)
     hq-sandbox-run.py --prove --rw DIR                 PROVA que a jaula barra (ver "Prova"): `HQSB: provado ...` rc 0, ou `HQSB: inerte <motivo>` rc 97
O QUE BARRA: toda escrita fora de --rw e de /dev (criar, apagar, renomear, truncar, mkdir, symlink) e todo bind/connect TCP. LEITURA e exec ficam livres (o selftest precisa ler o resto do
  sistema). NÃO barra: UDP (o DNS) nem socket unix (a ABI 4 não cobre; a ABI 6 cobre os unix); por isso o chamador também recusa alvo que fale com rede, gc, bd ou dolt.
CÓDIGOS: o do comando (via exec) · 64 uso errado ou --rw que anularia a jaula (`/`, o HOME ou um pai dele, pasta que não existe) · 97 sem jaula (não é Linux, kernel sem Landlock, ABI < 4, ou a
  chamada falhou): o comando NÃO rodou. Fail-closed: sem jaula provada nada roda.
PROVA: o rc de uma chamada não prova nada (o `systemd-run -p PrivateNetwork=yes` voltou 0 sem isolar, ver gt-netns-run). `--prove` roda a MESMA jaula num filho que tenta criar, apagar, truncar,
  renomear e criar pasta FORA de --rw e conectar num TCP que o pai escuta; depois o PAI confere os fatos (a sentinela fora continua inteira, nada novo apareceu fora, ninguém conectou) e que o
  filho conseguiu escrever DENTRO e em /dev/null (jaula que barra tudo também não serve). A saída do filho é só um segundo testemunho.
"""
import ctypes
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile

SYS_CREATE, SYS_ADD_RULE, SYS_RESTRICT = 444, 445, 446   # iguais em todas as arquiteturas (tabela unificada)
VERSION_FLAG = 1
PR_SET_NO_NEW_PRIVS = 38
RULE_PATH_BENEATH = 1
MIN_ABI = 4
# direitos de ESCRITA (os de leitura e exec ficam fora do que a jaula trata, logo livres): escrever, apagar arquivo/pasta, criar de todo tipo, mover entre pastas (ABI 2), truncar (ABI 3)
A_WRITE_FILE, A_REMOVE_DIR, A_REMOVE_FILE = 1 << 1, 1 << 4, 1 << 5
A_MAKE = (1 << 6) | (1 << 7) | (1 << 8) | (1 << 9) | (1 << 10) | (1 << 11) | (1 << 12)
A_REFER, A_TRUNCATE = 1 << 13, 1 << 14
FS_WRITE = A_WRITE_FILE | A_REMOVE_DIR | A_REMOVE_FILE | A_MAKE | A_REFER | A_TRUNCATE
NET_BIND_TCP, NET_CONNECT_TCP = 1 << 0, 1 << 1


class Sem(Exception):
    """a jaula não pôde ser posta: o comando não roda"""


def _libc():
    return ctypes.CDLL(None, use_errno=True)


def abi():
    """ABI do Landlock, ou levanta Sem. Vazio (variável de teste) → Sem; falhou (syscall negada ou ausente) → Sem."""
    if os.environ.get("HQSB_FORCE_UNAVAILABLE") == "1":
        raise Sem("forcado-indisponivel")
    if not sys.platform.startswith("linux"):
        raise Sem("nao-linux")
    n = _libc().syscall(SYS_CREATE, None, 0, VERSION_FLAG)
    if n < 0:
        raise Sem("kernel-sem-landlock errno=%d" % ctypes.get_errno())
    if n < MIN_ABI:
        raise Sem("abi-baixa %d<%d" % (n, MIN_ABI))
    return n


def confine(rw):
    libc = _libc()
    abi()
    attr = ctypes.create_string_buffer(struct.pack("=QQ", FS_WRITE, NET_BIND_TCP | NET_CONNECT_TCP))
    fd = libc.syscall(SYS_CREATE, attr, 16, 0)
    if fd < 0:
        raise Sem("create errno=%d" % ctypes.get_errno())
    for d in list(rw) + ["/dev"]:
        pfd = os.open(d, os.O_PATH | os.O_DIRECTORY)
        rule = ctypes.create_string_buffer(struct.pack("=Qi", FS_WRITE if d != "/dev" else A_WRITE_FILE | A_TRUNCATE, pfd))   # struct packed { u64 allowed_access; s32 parent_fd; }
        r = libc.syscall(SYS_ADD_RULE, fd, RULE_PATH_BENEATH, rule, 0)
        os.close(pfd)
        if r != 0:
            raise Sem("add_rule %s errno=%d" % (d, ctypes.get_errno()))
    if libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        raise Sem("no_new_privs errno=%d" % ctypes.get_errno())
    if libc.syscall(SYS_RESTRICT, fd, 0) != 0:
        raise Sem("restrict_self errno=%d" % ctypes.get_errno())
    os.close(fd)


def check_rw(dirs):
    """--rw que anularia a jaula (a raiz, o HOME ou um pai dele) ou que não existe → mensagem; senão None"""
    home = os.path.realpath(os.path.expanduser("~"))
    for d in dirs:
        if not os.path.isabs(d) or not os.path.isdir(d):
            return "--rw %s: precisa ser uma pasta absoluta que existe" % d
        r = os.path.realpath(d)
        if r == "/" or r == home or home.startswith(r.rstrip("/") + "/"):
            return "--rw %s libera escrita no HOME ou acima: a jaula não serviria" % d
    return None


PROVA_FILHO = r'''
import os, socket, sys
fora, porta, dentro = sys.argv[1], int(sys.argv[2]), sys.argv[3]
def tenta(nome, f):
    try:
        f()
        print("%s:ESCAPOU" % nome)
    except OSError:
        print("%s:barrado" % nome)
def criar():
    open(os.path.join(fora, "novo"), "w").close()
def apagar():
    os.remove(os.path.join(fora, "sentinela"))
def truncar():
    open(os.path.join(fora, "sentinela"), "w").close()
def renomear():
    os.rename(os.path.join(fora, "sentinela"), os.path.join(fora, "movida"))
def pasta():
    os.mkdir(os.path.join(fora, "pasta"))
def tcp():
    s = socket.create_connection(("127.0.0.1", porta), 3)
    s.close()
for n, f in (("criar", criar), ("apagar", apagar), ("truncar", truncar), ("renomear", renomear), ("pasta", pasta), ("tcp", tcp)):
    tenta(n, f)
try:
    with open(dentro, "w") as f:
        f.write("ok")
    with open(dentro) as f:
        assert f.read() == "ok"
    os.remove(dentro)
    print("dentro:ok")
except (OSError, AssertionError):
    print("dentro:FALHOU")
try:
    with open("/dev/null", "w") as f:
        f.write("x")
    print("devnull:ok")
except OSError:
    print("devnull:FALHOU")
'''


def prove(rw):
    """0 + `HQSB: provado` só se o PAI viu os fatos; 97 + `HQSB: inerte <motivo>` em qualquer dúvida"""
    try:
        a = abi()
    except Sem as e:
        return inerte("sem-jaula (%s)" % e)
    fora = tempfile.mkdtemp(prefix="hqsb-fora-")
    lis = socket.socket()
    try:
        sent = os.path.join(fora, "sentinela")
        with open(sent, "w") as f:
            f.write("vivo")
        lis.bind(("127.0.0.1", 0))
        lis.listen(4)
        lis.setblocking(False)
        dentro = os.path.join(rw[0], ".hqsb-prova-%d" % os.getpid())
        cmd = [sys.executable, os.path.abspath(__file__), "--rw", rw[0], "--", sys.executable, "-I", "-c", PROVA_FILHO, fora, str(lis.getsockname()[1]), dentro]
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=60)
        said = set(p.stdout.split())
        falhas = []
        for n in ("criar", "apagar", "truncar", "renomear", "pasta", "tcp"):
            if n + ":barrado" not in said:
                falhas.append("filho-nao-barrou-" + n)
        for n in ("dentro", "devnull"):
            if n + ":ok" not in said:
                falhas.append("filho-nao-escreveu-" + n)
        # os fatos, vistos pelo pai: vazio (a sentinela sumiu ou mudou) → ESCAPOU; lista de fora com mais que a sentinela → ESCAPOU; conexão aceita → ESCAPOU
        try:
            with open(sent) as f:
                if f.read() != "vivo":
                    falhas.append("sentinela-alterada")
        except OSError:
            falhas.append("sentinela-sumiu")
        if sorted(os.listdir(fora)) != ["sentinela"]:
            falhas.append("apareceu-algo-fora:" + ",".join(sorted(set(os.listdir(fora)) - {"sentinela"}))[:60])
        try:
            lis.accept()
            falhas.append("tcp-conectou")
        except BlockingIOError:
            pass
        if os.path.exists(dentro):
            falhas.append("sobra-dentro")
        if falhas:
            return inerte(" ".join(falhas) + " (rc filho=%d)" % p.returncode)
        print("HQSB: provado abi=%d (6 tentativas de fora barradas, escrita dentro e em /dev/null permitidas)" % a)
        return 0
    except (OSError, subprocess.SubprocessError) as e:
        return inerte("prova-quebrou %s: %s" % (type(e).__name__, e))
    finally:
        lis.close()
        shutil.rmtree(fora, ignore_errors=True)


def inerte(why):
    print("HQSB: inerte %s" % why)
    return 97


def main(argv):
    rw, mode, i = [], "run", 0
    while i < len(argv):
        a = argv[i]
        if a == "--rw" and i + 1 < len(argv):
            rw.append(argv[i + 1])
            i += 2
        elif a in ("--probe", "--prove"):
            mode = a[2:]
            i += 1
        elif a == "--":
            i += 1
            break
        else:
            print("hq-sandbox-run: argumento desconhecido %r\n%s" % (a, __doc__.split("\n")[0]), file=sys.stderr)
            return 64
    cmd = argv[i:]
    if mode == "probe":
        try:
            print("HQSB: abi=%d" % abi())
            return 0
        except Sem as e:
            print("HQSB: indisponivel %s" % e)
            return 97
    if mode == "prove" and not rw:
        print("hq-sandbox-run: --prove pede --rw DIR", file=sys.stderr)
        return 64
    if mode == "run" and not cmd:
        print("hq-sandbox-run: falta o comando depois de --", file=sys.stderr)
        return 64
    bad = check_rw(rw)
    if bad:
        print("hq-sandbox-run: " + bad, file=sys.stderr)
        return 64
    rw = [os.path.realpath(d) for d in rw]
    if mode == "prove":
        return prove(rw)
    try:
        confine(rw)
    except (Sem, OSError) as e:
        print("hq-sandbox-run: sem jaula, o comando NÃO roda (%s)" % e, file=sys.stderr)
        return 97
    try:
        os.execvp(cmd[0], cmd)
    except OSError as e:
        print("hq-sandbox-run: não consegui executar %s: %s" % (cmd[0], e), file=sys.stderr)
        return 127


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
