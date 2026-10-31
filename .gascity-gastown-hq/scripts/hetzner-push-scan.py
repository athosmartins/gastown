#!/usr/bin/env python3
"""hetzner-push-scan.py — olha o CONTEÚDO de um pacote que o `mbp-run.sh --exec --node-first --push` mandaria ao nó Linux (ga-jq08gyi).

## Contents
  Uso · O que confere · O que NÃO garante · Códigos

USO: python3 -I hetzner-push-scan.py [--member-max-mb N] [--total-max-mb N] [--max-depth N] <extensão> <arquivo>
     python3 -I hetzner-push-scan.py --creds -- <texto>...      (valor de --env e palavras do comando: algum tem CARA de credencial?)
  <extensão> em minúsculas e sem ponto: a que o mbp-run.sh já conferiu (NODE_EXEC_EXT). Os três tetos existem para o selftest; o mbp-run.sh usa os padrões (membro 256 MB, total 4096 MB, 4 níveis de contêiner).
O QUE CONFERE: (1) MAGIC BYTES: o arquivo começa como o tipo que o nome diz (apk apks xapk apkm aab jar aar ipa = zip; dex; so = ELF; dylib = Mach-O; exe dll = MZ; asar = cabeçalho de pickle). Texto, arquivo vazio ou outro tipo
  com nome de pacote não passa; extensão fora da tabela também não. (2) CONTEÚDO, pelo critério do hetzner-pii-scan.py (as regex vêm de lá, e um teste confere que este varredor conta como o `counts` dele): o arquivo cru e CADA
  membro de zip, recursivo (zip dentro de zip é o xapk/apks), mais o que está dentro de gzip, bzip2 e xz, é uma UNIDADE; a unidade com >=20 telefones ou >=3 CPFs RETÉM o push. A leitura crua do arquivo inteiro pega o que o diretório
  do zip não mostra (lista colada depois do fim) e os binários que não são zip (dex, so, asar, exe...).
O QUE NÃO GARANTE: é heurística de forma, a mesma do hetzner-pii-scan.py: não vê dado sem forma de telefone/CPF (nome, e-mail, CNPJ, endereço), nem lista abaixo dos limiares, nem lista em formato que o regex não lê (base64, UTF-16,
  texto partido em páginas de SQLite, compressão sem cabeçalho como brotli). É um retrato: arquivo editado entre esta leitura e o rsync não é revarrido (a mesma janela do node_guard).
  O QUE NÃO ABRE (vira rc 3, fica no MBP): tudo que o `zipfile` do Python recusa — por exemplo o jar sombreado com entradas sobrepostas ("possible zip bomb": o jadx-headless-mcp-0.7.1-all.jar do REA é assim, medido), e
  qualquer zip malformado que outro leitor tolere (um APK ofuscado, se houver) — e os contêineres 7z/rar/zstd/lz4. CUSTO (medido 31/10 neste servidor, carga ~20): ~12 MB/s de bytes VARRIDOS, que são o arquivo cru mais cada membro descomprimido (em geral 2 a 4 vezes o tamanho do arquivo): jadx.jar de 74 MB e 34 mil membros = 252 MB
  varridos em 20 s; apktool.jar de 21 MB = 84 MB em 7 s; a memória é plana (88 MB de RSS). Pior caso: o teto de 4096 MB varridos, uns 6 min (extrapolado, não medido).
--CREDS: JWT (eyJ...), sk-..., Bearer ..., chave privada PEM, token do GitHub/Slack/AWS/Google e URL com usuário:senha@. É heurística de FORMA e roda neste Python, o mesmo no selftest e no mini: a regex não é de grep, cujo dialeto muda
  entre o macOS e o Linux. rc 0 nenhum texto tem cara · 1 algum tem · 3 não deu para olhar · 2 uso errado (sem o `--`). Nunca imprime os textos.
CÓDIGOS: 0 leu TUDO e nenhuma unidade tem lista · 1 RETIDO (conteúdo, ou o tipo não é o que o nome diz) · 3 NÃO DEU PARA LER (zip corrompido ou cifrado, contêiner que não abre, passou de um teto, erro de E/S): é o terceiro estado,
  quem chama trata como retido · 2 uso errado. Exceção inesperada também é 3: erro nunca é "limpo". A linha do stdout diz o porquê (nome do membro e contagens; nunca um número de telefone/CPF).
"""
import importlib.util
import io
import mmap
import os
import re
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
MIN_PHONES, MIN_CPFS = 20, 3   # os limiares do main do hetzner-pii-scan.py; o selftest do mbp-run confere os dois lados (um não muda sem o outro)
MB = 1 << 20
ZIP_EXT = ("apk", "apks", "xapk", "apkm", "aab", "jar", "aar", "ipa")
MACHO = (b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca")   # fino e fat, as duas ordens
OPAQUE = (b"7z\xbc\xaf\x27\x1c", b"Rar!", b"\x28\xb5\x2f\xfd", b"\x04\x22\x4d\x18")   # 7z, rar, zstd, lz4: contêineres que este varredor não abre
CRED = re.compile(
    r"eyJ[A-Za-z0-9_=-]{6,}\.[A-Za-z0-9_=-]{6,}"                                        # JWT
    r"|(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{12,}"                                            # chave sk-... (OpenAI, Anthropic)
    r"|bearer\s+[A-Za-z0-9._~+/=-]{8,}"                                                  # Authorization: Bearer ...
    r"|-----BEGIN [A-Z ]*PRIVATE KEY"                                                    # chave privada PEM
    r"|(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"      # GitHub
    r"|xox[abprs]-[A-Za-z0-9-]{10,}"                                                     # Slack
    r"|AKIA[0-9A-Z]{16}"                                                                 # AWS
    r"|AIza[0-9A-Za-z_-]{30,}"                                                           # Google
    r"|[A-Za-z][A-Za-z0-9+.-]*://[^/@\s]+:[^/@\s]+@",                                   # URL com usuário:senha@
    re.IGNORECASE)
PROBE = "tel +55 11 98765-4321, (21) 91234-5678, 11 97777-7777 e (11) 99999-9999; 5511912345678 grudado 115511912345678; cpf 123.456.789-09 e 123.456.789-09 e 111.222.333-44"


class Held(Exception):
    pass


class Unreadable(Exception):
    pass


def load_pii():
    spec = importlib.util.spec_from_file_location("hetzner_pii_scan", os.path.join(HERE, "hetzner-pii-scan.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def regexes(mod):   # as MESMAS regex do hetzner-pii-scan.py, em bytes (o padrão é todo ASCII: casar em bytes e em texto dá o mesmo)
    return re.compile(mod.PH.pattern.encode("ascii")), re.compile(mod.CPF.pattern.encode("ascii"))


def collect(buf, rx):   # (telefones distintos, CPFs distintos) de um bloco de bytes, com as regras do `counts` do hetzner-pii-scan.py
    ph, cp = set(), set()
    for m in rx[0].finditer(buf):
        d = re.sub(rb"\D", b"", m.group(0))
        if len(set(d[-8:])) > 3:   # cauda sintética (até 3 algarismos distintos nos 8 últimos) não conta
            ph.add(d[-11:])
    for m in rx[1].finditer(buf):
        cp.add(re.sub(rb"\D", b"", m.group(0)))
    return len(ph), len(cp)


def magic_ok(ext, head):   # o começo do arquivo é o do tipo que o nome diz; extensão fora da tabela nunca vale
    if ext in ZIP_EXT:
        return head.startswith(b"PK\x03\x04")
    if ext == "dex":
        return re.match(rb"dex\n[0-9]{3}\x00", head) is not None
    if ext == "so":
        return head.startswith(b"\x7fELF")
    if ext == "dylib":
        return head[:4] in MACHO
    if ext in ("exe", "dll"):
        return head.startswith(b"MZ")
    if ext == "asar":
        return head.startswith(b"\x04\x00\x00\x00")
    return False


class State:
    def __init__(self, member_max, total_max, max_depth, rx):
        self.member_max, self.total_max, self.max_depth, self.rx = member_max, total_max, max_depth, rx
        self.read = 0    # bytes varridos, somando todas as unidades
        self.units = 0


def unit(buf, label, st):   # uma unidade (o arquivo cru, um membro, o que saiu de um gzip): conta e confere os limiares
    st.read += len(buf)
    if st.read > st.total_max:
        raise Unreadable(label, "passou do teto de %d MB lidos" % (st.total_max // MB))
    st.units += 1
    p, c = collect(buf, st.rx)
    if p >= MIN_PHONES or c >= MIN_CPFS:
        raise Held(label, "%d telefones, %d CPFs" % (p, c))


def inflate(kind, buf, label, st):   # gzip/bzip2/xz inteiro em memória, com teto; fluxo truncado ou com sobra é "não deu para ler"
    if kind == "gz":
        d = zlib.decompressobj(31)
    elif kind == "bz2":
        import bz2
        d = bz2.BZ2Decompressor()
    else:
        import lzma
        d = lzma.LZMADecompressor()
    # vazio → fluxo vazio ou curto: o fim não chegou (d.eof falso) = truncado, rc 3; falhou/ilegível → zlib.error / OSError / ImportError (módulo ausente) sobem ao main e viram rc 3
    out = d.decompress(buf, st.member_max + 1)
    if len(out) > st.member_max:
        raise Unreadable(label, "descomprime além do teto de %d MB" % (st.member_max // MB))
    if not d.eof or d.unused_data:
        raise Unreadable(label, "fluxo %s truncado ou com dados depois do fim" % kind)
    return out


def walk(buf, label, depth, st):   # buf: os bytes de uma unidade já lida inteira; abre o que for zip/gzip/bzip2/xz, recusa o que não sabe abrir
    unit(buf, label, st)
    if buf[:4] == b"PK\x03\x04":
        zip_members(io.BytesIO(buf), label, depth, st)
        return
    kind = "gz" if buf[:3] == b"\x1f\x8b\x08" else "bz2" if re.match(rb"BZh[1-9]1AY&SY", buf[:10]) else "xz" if buf[:6] == b"\xfd7zXZ\x00" else None
    if kind:
        if depth >= st.max_depth:
            raise Unreadable(label, "contêineres aninhados demais (teto %d)" % st.max_depth)
        walk(inflate(kind, buf, label, st), "%s!%s" % (label, kind), depth + 1, st)
    elif buf.startswith(OPAQUE):
        raise Unreadable(label, "contêiner (7z, rar, zstd ou lz4) que este varredor não abre")


def zip_members(f, label, depth, st):
    if depth >= st.max_depth:
        raise Unreadable(label, "contêineres aninhados demais (teto %d)" % st.max_depth)
    with zipfile.ZipFile(f) as z:
        for info in z.infolist():
            if info.is_dir():
                continue
            name = "%s!%s" % (label, ascii(info.filename)[1:-1][:100])
            if info.flag_bits & 0x1:
                raise Unreadable(name, "membro cifrado")
            # o zipfile corta a leitura no file_size do cabeçalho: o teto vale pelo que ele diz, e mentira dele vira CRC errado (BadZipFile = 3), nunca uma bomba
            if info.file_size > st.member_max:
                raise Unreadable(name, "membro de %d MB passa do teto de %d MB" % (info.file_size // MB, st.member_max // MB))
            # vazio → membro de 0 bytes é uma unidade sem telefones e segue; falhou/ilegível → BadZipFile (CRC, cifrado, sobreposto) ou NotImplementedError (método) sobem ao main e viram rc 3
            with z.open(info) as m:
                data = m.read()
            walk(data, name, depth + 1, st)


def scan_file(ext, path, st):
    with open(path, "rb") as f:
        # vazio → arquivo de 0 bytes: sem magic = RETIDO (nunca "tipo certo"); falhou/ilegível → OSError sobe ao main e vira rc 3
        if not magic_ok(ext, f.read(8)):
            raise Held("arquivo", "o começo não é de um .%s (magic bytes)" % ascii(ext)[1:-1][:20])
        with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:   # sem copiar o arquivo para a memória: até NODE_EXEC_MAX_MB (1 GB) passam por aqui
            unit(mm, "arquivo", st)
        if ext in ZIP_EXT:
            f.seek(0)
            zip_members(f, "arquivo", 0, st)


def creds(texts):   # 0 nenhum texto tem cara de credencial · 1 algum tem · 3 não deu para olhar. Nunca imprime o texto.
    try:
        for t in texts:
            if CRED.search(t):
                print("credencial: um dos %d textos tem cara de credencial (JWT, sk-, Bearer, chave, token de provedor, URL com senha)" % len(texts))
                return 1
    except Exception as e:
        print("ilegível: erro %s ao olhar os textos" % type(e).__name__)
        return 3
    return 0


def main(argv):
    lim = {"--member-max-mb": 256, "--total-max-mb": 4096, "--max-depth": 4}
    args = list(argv)
    if args[:1] == ["--creds"]:   # só com o `--`: sem ele o texto cairia no parser de arquivo abaixo e iria parar numa mensagem de erro
        if args[1:2] != ["--"]:
            sys.stderr.write("uso: hetzner-push-scan.py --creds -- <texto>...\n")
            return 2
        return creds(args[2:])
    try:
        while args and args[0] in lim:
            lim[args[0]] = int(args[1])
            del args[:2]
        if len(args) != 2 or any(v < 1 for v in lim.values()):
            raise ValueError("uso")
    except (ValueError, IndexError):
        sys.stderr.write("uso: hetzner-push-scan.py [--member-max-mb N] [--total-max-mb N] [--max-depth N] <extensão> <arquivo>\n")
        return 2
    ext, path = args
    st = None
    try:
        # falhou/ilegível → hetzner-pii-scan.py ausente ou quebrado: rc 3, sem a régua dele não se conta (vazio não se aplica: o módulo ou carrega ou levanta)
        pii = load_pii()
        rx = regexes(pii)
        if pii.counts(PROBE) != collect(PROBE.encode("utf-8"), rx):   # a régua do hetzner-pii-scan.py mudou e este varredor não a acompanha: não conta com régua errada
            raise Unreadable("régua", "este varredor não conta mais como o hetzner-pii-scan.py (o counts dele mudou)")
        st = State(lim["--member-max-mb"] * MB, lim["--total-max-mb"] * MB, lim["--max-depth"], rx)
        scan_file(ext, path, st)
    except Held as e:
        print("retido: %s: %s" % e.args)
        return 1
    except Unreadable as e:
        print("ilegível: %s: %s" % e.args)
        return 3
    except Exception as e:   # erro inesperado (zip corrompido, E/S, memória...) é "não sei", nunca "limpo"
        print("ilegível: erro %s ao varrer: %s" % (type(e).__name__, ascii(str(e))[:160]))
        return 3
    print("ok: %d unidades, %d MB lidos" % (st.units, st.read // MB))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
