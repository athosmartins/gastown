#!/usr/bin/env python3
"""hq-sandbox-run.py — roda um comando numa jaula Landlock SEM root: escrita só nas pastas dadas e nenhuma conexão TCP (ga-2hd02v.5.6.1).

## Contents
  Por quê · Uso · O que a jaula barra e o que não barra · Códigos de saída · Prova

POR QUÊ: o lastro do nó Hetzner vai rodar MUTANTES de scripts do hq (um `-z` virado em `-n`, um `&&` virado em `||`) como `runner`, o mesmo usuário que tem ~/gt-remote. O nó não tem bwrap,
  o AppArmor barra userns sem privilégio e o único helper de root (gt-netns-run) só corta a rede: um mutante que derruba uma guarda poderia apagar o que o `runner` alcança. O Landlock (kernel
  6.8 do nó, ABI 4) é o único isolamento de arquivos que o `runner` consegue pôr em si mesmo, sem root, sem pedir nada a ninguém.
USO: hq-sandbox-run.py [--rw DIR]... -- CMD [ARG...]   confina este processo e dá exec no comando (o Landlock vale para os filhos e não sai)
     hq-sandbox-run.py --probe                          imprime a ABI do Landlock (`HQSB: abi=N`) ou `HQSB: indisponivel <motivo>` (rc 97)
     hq-sandbox-run.py --prove --rw DIR [--rw DIR]...   PROVA que a jaula barra (ver "Prova"): `HQSB: provado ...` rc 0, ou `HQSB: inerte <motivos>` rc 97
O QUE BARRA: toda escrita fora de --rw e de /dev (criar de todo tipo, apagar, renomear, mover entre pastas, truncar) e todo bind/connect TCP. LEITURA e exec ficam livres (o selftest precisa ler o resto
  do sistema). NÃO barra: UDP (o DNS) nem socket unix (a ABI 4 não cobre; o escopo de unix que a ABI 6 traz é só o ABSTRATO, não os de caminho como o do ssh-agent); por isso o chamador
  também recusa alvo que fale com rede, gc, bd ou dolt. Dispositivo (mknod de char/bloco): sem CAP_MKNOD o kernel recusa com ou sem jaula; a prova só aceita o EACCES da jaula (ver "Prova").
CÓDIGOS: o do comando (via exec) · 64 uso errado, --rw que anularia a jaula (`/`, o HOME ou um pai dele, pasta que não existe) ou HOME ilegível (sem o HOME a recusa não se confere) · 97 sem jaula (não é Linux,
  kernel sem Landlock, ABI < 4, ou a chamada falhou): o comando NÃO rodou. Fail-closed: sem jaula provada nada roda. Depois do exec o 64/97/127 do COMANDO não se distingue do lançador (inerente ao exec):
  quem precisa separar os dois roda `--probe`/`--prove` antes.
PROVA: o rc de uma chamada não prova nada (o `systemd-run -p PrivateNetwork=yes` voltou 0 sem isolar, ver gt-netns-run). `--prove` roda a MESMA jaula (todos os --rw) num filho que tenta, FORA de --rw, UMA
  operação por direito da jaula (escrever, truncar, apagar arquivo, apagar pasta, criar arquivo/pasta/symlink/fifo/socket/dispositivo, renomear, bind e connect TCP), e DENTRO de cada --rw o mesmo leque de
  operações com resultado, mais o mover entre pastas (o A_REFER só se vê por dentro: sem ele o kernel dá EXDEV até no --rw). O PAI confere os fatos: as sentinelas fora continuam como estavam, nada novo apareceu fora, ninguém conectou, e cada operação de dentro deixou o artefato esperado na pasta
  (o pai lê o artefato, não a palavra do filho). Só o EACCES conta como "barrado": é a assinatura do Landlock (um connect recusado, um caminho que sumiu ou o EPERM de quem não tem CAP_MKNOD
  não provam nada, e o EPERM é exatamente o que um direito perdido de mknod devolveria). A probe de truncar usa truncate(2), que só pede A_TRUNCATE: o open("w") pede também A_WRITE_FILE e não isola.
  Limites: bind e /dev/null não deixam rastro que o pai veja (bind, só o errno do filho; /dev/null, o marcador que o filho cria DEPOIS de gravar lá); o EACCES do bind é o do Landlock.
  A saída da prova diz QUAIS motivos reprovaram (`filho-nao-barrou-X`, `alterado-X`, `sumiu-X`, `apareceu-fora:X`, `tcp-conectou`, `dentro-X` no 1º --rw e `dentro1-X`, `dentro2-X`... nos outros): um direito perdido acusa o seu, e a jaula
  que nem sobe acusa todos (`filho-sem-saida` e o stderr do lançador filho).
"""
import ctypes
import os
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tempfile

SYS_CREATE, SYS_ADD_RULE, SYS_RESTRICT = 444, 445, 446   # iguais em todas as arquiteturas (tabela unificada)
VERSION_FLAG = 1
PR_SET_NO_NEW_PRIVS = 38
RULE_PATH_BENEATH = 1
MIN_ABI = 4
# direitos de ESCRITA (os de leitura e exec ficam fora do que a jaula trata, logo livres): escrever, apagar arquivo/pasta, criar de todo tipo, mover entre pastas (ABI 2), truncar (ABI 3).
# Um por linha e com nome: o selftest zera UM deles por vez (`A_X = 0` tira o direito da jaula inteira, inclusive da regra do /dev) e confere que a prova acusa exatamente aquele.
A_WRITE_FILE = 1 << 1
A_REMOVE_DIR = 1 << 4
A_REMOVE_FILE = 1 << 5
A_MAKE_CHAR = 1 << 6
A_MAKE_DIR = 1 << 7
A_MAKE_REG = 1 << 8
A_MAKE_SOCK = 1 << 9
A_MAKE_FIFO = 1 << 10
A_MAKE_BLOCK = 1 << 11
A_MAKE_SYM = 1 << 12
A_REFER = 1 << 13
A_TRUNCATE = 1 << 14
FS_WRITE = (A_WRITE_FILE | A_REMOVE_DIR | A_REMOVE_FILE | A_MAKE_CHAR | A_MAKE_DIR | A_MAKE_REG | A_MAKE_SOCK | A_MAKE_FIFO | A_MAKE_BLOCK | A_MAKE_SYM | A_REFER | A_TRUNCATE)
NET_BIND_TCP = 1 << 0
NET_CONNECT_TCP = 1 << 1


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
    """--rw que anularia a jaula (a raiz, o HOME ou um pai dele) ou que não existe → mensagem; HOME que não dá para ler também → mensagem; senão None"""
    if not dirs:
        return None
    # vazio → o HOME vazio vira "/" no expanduser; falhou → sem passwd e sem HOME devolve o "~" literal (vira <cwd>/~). Nos dois a guarda ficaria inerte em silêncio, então recusa (64): HOME tem de ser uma pasta absoluta que existe e que não seja a raiz
    home = os.path.realpath(os.path.expanduser("~"))
    if not os.path.isabs(home) or not os.path.isdir(home) or home == "/":
        return "HOME ilegível (%r): a recusa de --rw = HOME não poderia ser conferida" % home
    for d in dirs:
        if not os.path.isabs(d) or not os.path.isdir(d):
            return "--rw %s: precisa ser uma pasta absoluta que existe" % d
        r = os.path.realpath(d)
        if r == "/" or r == home or home.startswith(r.rstrip("/") + "/"):
            return "--rw %s libera escrita no HOME ou acima: a jaula não serviria" % d
    return None


# Tentativas de FORA, uma por direito. O nome é o que o pai espera em FORA_SONDAS; o que cada uma isola está ao lado.
# `dentro` recebe as pastas de prova (uma por --rw, criadas pelo pai): cada passo deixa um artefato que o PAI confere, e um passo que falha só faz o artefato faltar (os outros seguem).
PROVA_FILHO = r'''
import errno, os, socket, stat, sys
fora, porta = sys.argv[1], int(sys.argv[2])
j = os.path.join
def tenta(nome, f):
    try:
        f()
        print("%s:ESCAPOU" % nome)
    except OSError as e:
        # só o EACCES é o Landlock. Um connect recusado (ECONNREFUSED), um caminho que sumiu (ENOENT) ou o EPERM de mknod sem CAP_MKNOD (o que um A_MAKE_CHAR/BLOCK perdido devolveria)
        # não são a jaula: saem como `erro-<errno>` e a prova fica inerte
        print("%s:%s" % (nome, "barrado" if e.errno == errno.EACCES else "erro-" + errno.errorcode.get(e.errno, str(e.errno))))
def escrever():
    fd = os.open(j(fora, "s_escrever"), os.O_WRONLY)   # sem O_TRUNC: só A_WRITE_FILE decide
    os.write(fd, b"x")
    os.close(fd)
def conectar():
    s = socket.create_connection(("127.0.0.1", porta), 3)
    s.close()
def ligar():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    s.close()
for nome, f in (
    ("escrever", escrever),                                                                               # A_WRITE_FILE
    ("truncar", lambda: os.truncate(j(fora, "s_truncar"), 0)),                                            # A_TRUNCATE (truncate(2); o open("w") pede também A_WRITE_FILE e não isola)
    ("apagar", lambda: os.remove(j(fora, "s_apagar"))),                                                   # A_REMOVE_FILE
    ("rmdir", lambda: os.rmdir(j(fora, "vazia"))),                                                        # A_REMOVE_DIR
    ("renomear", lambda: os.rename(j(fora, "s_renomear"), j(fora, "n-renomeada"))),                       # A_REMOVE_FILE + A_MAKE_REG juntos (não isola; o mover entre pastas é a prova do A_REFER, por dentro)
    ("criar", lambda: os.mknod(j(fora, "n-reg"), stat.S_IFREG | 0o600)),                                  # A_MAKE_REG
    ("pasta", lambda: os.mkdir(j(fora, "n-pasta"))),                                                      # A_MAKE_DIR
    ("elo", lambda: os.symlink("x", j(fora, "n-elo"))),                                                   # A_MAKE_SYM
    ("fifo", lambda: os.mkfifo(j(fora, "n-fifo"))),                                                       # A_MAKE_FIFO
    ("soquete", lambda: os.mknod(j(fora, "n-sock"), stat.S_IFSOCK | 0o600)),                              # A_MAKE_SOCK
    ("dispchar", lambda: os.mknod(j(fora, "n-chr"), stat.S_IFCHR | 0o600, os.makedev(1, 3))),             # A_MAKE_CHAR (sem a jaula: EPERM; com ela: EACCES)
    ("dispbloco", lambda: os.mknod(j(fora, "n-blk"), stat.S_IFBLK | 0o600, os.makedev(7, 0))),            # A_MAKE_BLOCK (idem)
    ("tcp", conectar),                                                                                    # NET_CONNECT_TCP
    ("bind", ligar),                                                                                      # NET_BIND_TCP
):
    tenta(nome, f)
def dentro(b):
    def passo(f):
        try:
            f()
        except Exception:
            pass
    def escrita():
        with open(j(b, "escrita"), "w") as f:
            f.write("ok")
    def pasta():
        os.mkdir(j(b, "pasta"))
    def movido():
        os.mkdir(j(b, "md"))
        with open(j(b, "m-origem"), "w") as f:
            f.write("m")
        os.rename(j(b, "m-origem"), j(b, "md", "movido"))   # entre pastas: pede A_REFER (sem ele o kernel dá EXDEV, mesmo dentro do --rw)
    def apagado():
        open(j(b, "a-apagar"), "w").close()
        os.remove(j(b, "a-apagar"))
        open(j(b, "apagado-ok"), "w").close()   # só depois de apagar: "sumiu" sozinho também vale para o passo que nunca rodou
    def rmdir():
        os.mkdir(j(b, "d-apagar"))
        os.rmdir(j(b, "d-apagar"))
        open(j(b, "rmdir-ok"), "w").close()
    def truncado():
        with open(j(b, "t"), "w") as f:
            f.write("abc")
        os.truncate(j(b, "t"), 1)
    def elo():
        os.symlink("x", j(b, "elo"))
    def fifo():
        os.mkfifo(j(b, "fifo"))
    def soquete():
        os.mknod(j(b, "sk"), stat.S_IFSOCK | 0o600)
    def devnull():
        with open("/dev/null", "w") as f:
            f.write("x")
        open(j(b, "devnull-ok"), "w").close()   # só depois de gravar em /dev/null: o pai não vê o /dev/null, vê este marcador
    for f in (escrita, pasta, movido, apagado, rmdir, truncado, elo, fifo, soquete, devnull):
        passo(f)
for b in sys.argv[3:]:
    dentro(b)
'''

# os nomes que o pai exige do filho (cada um com `:barrado`); a ordem e o texto de PROVA_FILHO não importam, o nome sim
FORA_SONDAS = ("escrever", "truncar", "apagar", "rmdir", "renomear", "criar", "pasta", "elo", "fifo", "soquete", "dispchar", "dispbloco", "tcp", "bind")
FORA_FIXOS = ("s_escrever", "s_truncar", "s_apagar", "s_renomear")   # arquivos com "vivo" fora do --rw; mais a pasta vazia "vazia"


def _le(p):
    with open(p) as f:
        return f.read()


def fatos_dentro(b):
    """(nome, teste) de cada passo de dentro: o artefato que o filho devia deixar em `b`, lido pelo PAI"""
    j = os.path.join
    return (
        ("escrita", lambda: _le(j(b, "escrita")) == "ok"),
        ("pasta", lambda: os.path.isdir(j(b, "pasta"))),
        ("movido", lambda: _le(j(b, "md", "movido")) == "m" and not os.path.lexists(j(b, "m-origem"))),
        ("apagado", lambda: os.path.lexists(j(b, "apagado-ok")) and not os.path.lexists(j(b, "a-apagar"))),   # apagar deixa o marcador E tira o alvo: o alvo ausente sozinho não distingue "apagou" de "nunca criou"
        ("rmdir", lambda: os.path.lexists(j(b, "rmdir-ok")) and not os.path.lexists(j(b, "d-apagar"))),
        ("truncado", lambda: _le(j(b, "t")) == "a"),
        ("elo", lambda: os.readlink(j(b, "elo")) == "x"),
        ("fifo", lambda: stat.S_ISFIFO(os.lstat(j(b, "fifo")).st_mode)),
        ("soquete", lambda: stat.S_ISSOCK(os.lstat(j(b, "sk")).st_mode)),
        ("devnull", lambda: os.path.lexists(j(b, "devnull-ok"))),
    )


def confere_dentro(b):
    """os passos de dentro cujo artefato NÃO está como o filho devia deixar. Artefato ausente ou ilegível → o passo conta como falhado (nunca como feito)."""
    falhas = []
    for nome, f in fatos_dentro(b):
        # vazio (artefato ausente) → o passo não aconteceu: falha; falhou/ilegível (OSError) → também falha, nunca "feito"
        try:
            ok = f()
        except OSError:
            ok = False
        if not ok:
            falhas.append(nome)
    return falhas


def prove(rw):
    """0 + `HQSB: provado` só se o PAI viu os fatos; 97 + `HQSB: inerte <motivos>` em qualquer dúvida (inclusive a prova que quebra por motivo que ninguém previu)"""
    try:
        a = abi()
    except Sem as e:
        return inerte("sem-jaula (%s)" % e)
    j = os.path.join
    fora = tempfile.mkdtemp(prefix="hqsb-fora-")
    lis = socket.socket()
    bases = []
    try:
        for n in FORA_FIXOS:
            with open(j(fora, n), "w") as f:
                f.write("vivo")
        os.mkdir(j(fora, "vazia"))
        lis.bind(("127.0.0.1", 0))
        lis.listen(4)
        lis.setblocking(False)
        for d in rw:
            bases.append(j(d, ".hqsb-prova-%d" % os.getpid()))
            os.mkdir(bases[-1], 0o700)
        cmd = [sys.executable, os.path.abspath(__file__)]
        for d in rw:
            cmd += ["--rw", d]
        cmd += ["--", sys.executable, "-I", "-c", PROVA_FILHO, fora, str(lis.getsockname()[1])] + bases
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, errors="replace", timeout=60)
        said = set(p.stdout.split())
        falhas = []
        if not said:
            falhas.append("filho-sem-saida")   # a jaula nem subiu (ou o filho não rodou): a lista que segue é de TUDO, não de um direito
        for n in FORA_SONDAS:
            if n + ":barrado" not in said:
                falhas.append("filho-nao-barrou-" + n)
        # os fatos de fora, vistos pelo pai. vazio (fixo sumiu ou mudou) → ESCAPOU; falhou/ilegível (OSError) → também reprova, nunca "intacto"; lista de fora com mais que os fixos → ESCAPOU
        for n in FORA_FIXOS:
            try:
                if _le(j(fora, n)) != "vivo":
                    falhas.append("alterado-" + n)
            except OSError:
                falhas.append("sumiu-" + n)
        if not os.path.isdir(j(fora, "vazia")):
            falhas.append("sumiu-vazia")
        extra = set(os.listdir(fora)) - set(FORA_FIXOS) - {"vazia"}
        if extra:
            falhas.append("apareceu-fora:" + ",".join(sorted(extra)))
        # conexão aceita → ESCAPOU; nada na fila (BlockingIOError) → ninguém conectou
        try:
            lis.accept()
            falhas.append("tcp-conectou")
        except BlockingIOError:
            pass
        # os fatos de dentro de CADA --rw (o primeiro é "dentro-X", o segundo "dentro1-X"...); depois a pasta de prova sai, e se não saiu a prova reclama
        for i, b in enumerate(bases):
            falhas += ["%s-%s" % ("dentro" if i == 0 else "dentro%d" % i, n) for n in confere_dentro(b)]
            shutil.rmtree(b, ignore_errors=True)
            if os.path.lexists(b):
                falhas.append("sobra-dentro")
        if falhas:
            # o stderr do lançador filho só entra quando não houve saída (jaula que não sobe): é o único lugar onde o motivo (add_rule errno=22...) aparece
            return inerte(" ".join(falhas) + " (rc filho=%d%s)" % (p.returncode, "; stderr: " + p.stderr.strip().replace("\n", " | ")[:200] if not said else ""))
        print("HQSB: provado abi=%d (%d tentativas de fora barradas, %d operações por --rw conferidas pelo pai em %d pasta(s), /dev/null gravável)" % (a, len(FORA_SONDAS), len(fatos_dentro("")), len(rw)))
        return 0
    except Exception as e:
        return inerte("prova-quebrou %s: %s" % (type(e).__name__, e))
    finally:
        lis.close()
        shutil.rmtree(fora, ignore_errors=True)
        for b in bases:
            shutil.rmtree(b, ignore_errors=True)


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
