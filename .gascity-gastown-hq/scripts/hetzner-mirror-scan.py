#!/usr/bin/env python3
"""hetzner-mirror-scan.py — diz QUAIS CAMINHOS o servidor não pode receber, olhando o CONTEÚDO do histórico do espelho ainda não conferido (ga-2hd02v.1.3).

## Contents
  Uso · O que conta · O que NÃO garante · Códigos

USO: python3 -I hetzner-mirror-scan.py <repo.git> <estado-dir>. Para cada par (blob, caminho) que um commit novo de refs/remotes/origin/* introduz — todo status MENOS D, que não traz blob: A, M, T (troca de tipo)…; o mesmo blob com outro nome também: renomear não escapa — aplica a régua do
  hetzner-pii-scan.py (>=20 telefones ou >=3 CPFs; a função `counts` é importada de lá). Blob sinalizado nega o CAMINHO (todas as versões) em estado-dir/deny-extra (`!/caminho`, escapado como o sparse:oid lê).
  seen.tsv (1ª linha = a versão da régua; depois blob<TAB>0|1) evita reler; scanned-tips só avança quando TUDO foi lido e gravado — a última coisa que este script faz.
O QUE CONTA: a forma, em texto que o regex consegue LER. Só vale como legível o UTF-8 estrito, sem NUL e sem cabeçalho de PDF/zip/gzip; o resto (imagem, binário, UTF-16, zip, PDF, texto em outra codificação) o varredor não sabe ler, e NÃO SABER é SINALIZADO,
  nunca "limpo" (o nome do arquivo não ajuda: pdpj_<CPF>.png e um .zip de leads têm nome neutro). Blob > 50 MB, ou que o git não entrega por inteiro, também. Caminho sinalizado que o filtro não consegue negar (quebra de linha, controle, espaço no fim): rc 3.
  Estado de outra régua (sem a versão atual) ou sem seen.tsv não vale como cobertura: lê a história inteira de novo, e o selo gtmirror.scannedtips do espelho cai ANTES da leitura (o espelho fica inerte até a varredura nova terminar).
O QUE NÃO GARANTE: dado sem forma de telefone/CPF (nome, e-mail, CNPJ, endereço) nem lista pequena; lista que está dentro de texto legível mas codificada (base64, escapes) ou com dígitos que não são 0-9.
PROGRESSO: a varredura de uma história inteira pode passar do corte que o sync lhe dá (carga alta). A cada HETZNER_MIRROR_SCAN_CKPT s (30) grava deny-extra e DEPOIS seen.tsv (a ordem que a guarda do início exige); a rodada seguinte lê só os blobs que faltam (o `git log` que lista os pares roda de novo).
  O que NÃO anda no meio: scanned-tips, o selo de cobertura. Estado de outra régua derruba também o scanned-tips (senão `^velho` esconderia a história que a régua nova ainda não leu).
CÓDIGOS: 0 varredura completa e gravada · 3 não consegui varrer (a cobertura não avançou; o espelho continua "não pronto"; o já lido fica em seen.tsv) · 2 uso
"""
import importlib.util
import os
import re
import subprocess
import sys
import time

BIG = 50_000_000
PH_MIN, CP_MIN = 20, 3   # os limiares do main do hetzner-pii-scan.py; entram na versão da régua: mudar qualquer um invalida o seen.tsv
RULER = "ruler=2 phones>=%d cpfs>=%d unreadable=flag" % (PH_MIN, CP_MIN)
UNREADABLE = (b"%PDF-", b"PK\x03\x04", b"\x1f\x8b")   # PDF e arquivo compactado: o texto de dentro não é o que o regex vê
HERE = os.path.dirname(os.path.abspath(__file__))


def load_counts():
    spec = importlib.util.spec_from_file_location("hetzner_pii_scan", os.path.join(HERE, "hetzner-pii-scan.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.counts


def esc(p):   # como o hetzner-pii-scan.py: o sparse:oid lê `\` `*` `?` `[` como padrão
    return "!/" + re.sub(r"([\\*?\[\]])", r"\\\1", p)


def lines(t):   # só \n separa linha, como o git lê o filtro: str.splitlines() também parte em U+2028/U+2029/U+0085, que o guarda de caminho deixa passar
    return [l for l in t.split("\n") if l]


def readable(body):   # texto POSITIVAMENTE legível ou None ("não sei ler"): UTF-8 estrito, sem NUL, sem cabeçalho de PDF/zip/gzip
    if b"\0" in body or body.startswith(UNREADABLE):
        return None
    try:
        return body.decode("utf-8")
    except UnicodeDecodeError:
        return None


def atomic(path, text):
    tmp = "%s.new.%d" % (path, os.getpid())   # um nome por processo: dois varredores ao mesmo tempo não misturam bytes no mesmo .new
    with open(tmp, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def save(st, deny, seen):   # deny-extra ANTES de seen.tsv: seen com blob sinalizado e deny-extra vazio é o estado que a guarda do início recusa
    atomic(os.path.join(st, "deny-extra"), "".join(d + "\n" for d in sorted(deny)))
    atomic(os.path.join(st, "seen.tsv"), "#" + RULER + "\n" + "".join("%s\t%d\n" % (o, v) for o, v in sorted(seen.items())))


def git(repo, *args, inp=None):
    r = subprocess.run(["git", "-C", repo] + list(args), input=inp, capture_output=True)
    if r.returncode != 0:
        raise RuntimeError("git %s: %s" % (args[0], r.stderr.decode("utf8", "replace").strip()[:200]))
    return r.stdout


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("uso: hetzner-mirror-scan.py <repo.git> <estado-dir>\n")
        return 2
    repo, st = argv
    os.makedirs(st, exist_ok=True)
    counts = load_counts()
    try:
        ckpt = float(os.environ.get("HETZNER_MIRROR_SCAN_CKPT", "30"))
        for f in os.listdir(st):
            if ".new." in f:   # temporário que um corte deixou (o nome leva o pid de quem morreu; ninguém mais o apaga)
                os.remove(os.path.join(st, f))
        tips = lines(git(repo, "for-each-ref", "--format=%(objectname) %(refname)", "refs/remotes/origin").decode())
        tipshas = sorted({l.split(" ", 1)[0] for l in tips})
        seen, old, valid = {}, [], False
        if os.path.exists(os.path.join(st, "seen.tsv")):
            ls = lines(open(os.path.join(st, "seen.tsv")).read())
            if ls[:1] == ["#" + RULER]:
                valid = True   # outra régua (ou sem versão) não vale: seen vazio e sem cobertura anterior, relê tudo. scanned-tips sem seen.tsv da régua atual também não vale (estado sumido não é cobertura)
                for l in ls[1:]:
                    o, _, f = l.partition("\t")
                    if o and f in ("0", "1"):
                        seen[o] = f == "1"
                if os.path.exists(os.path.join(st, "scanned-tips")):
                    old = [l.split(" ", 1)[0] for l in lines(open(os.path.join(st, "scanned-tips")).read())]
        if not valid:   # estado de outra régua ou sumido: o selo de cobertura que o ESPELHO guarda cai AGORA, não só no fim; senão ele serviria, com o filtro velho, durante a releitura inteira
            u = subprocess.run(["git", "-C", repo, "config", "--unset", "gtmirror.scannedtips"], capture_output=True)
            if u.returncode not in (0, 5):   # 5 = não havia selo
                raise RuntimeError("não consegui derrubar o selo de cobertura anterior (gtmirror.scannedtips)")
            if os.path.exists(os.path.join(st, "scanned-tips")):   # o checkpoint torna seen.tsv válido ANTES do fim: com o scanned-tips velho aqui, a rodada seguinte leria só `^velho` e nunca veria a história que a régua nova não leu
                os.remove(os.path.join(st, "scanned-tips"))
        if old:   # uma ponta velha que o git não conhece mais (gc, prune) não pode virar `^sha`: o git log recusaria; sem ela a varredura só lê mais
            chk = subprocess.run(["git", "-C", repo, "cat-file", "--batch-check"], input="".join(o + "\n" for o in old).encode(), capture_output=True)
            if chk.returncode != 0:
                raise RuntimeError("cat-file --batch-check falhou")
            old = [f[0] for f in (l.split() for l in chk.stdout.decode().splitlines()) if len(f) >= 2 and f[1] == "commit"]
        deny = set(lines(open(os.path.join(st, "deny-extra")).read())) if os.path.exists(os.path.join(st, "deny-extra")) else set()
        if any(seen.values()) and not deny:   # blob sinalizado sem nenhum caminho negado = deny-extra perdido (restauro parcial, apagado); regravá-lo vazio enfraqueceria o filtro em silêncio
            raise RuntimeError("seen.tsv tem blob sinalizado mas deny-extra está vazio ou sumiu: apague seen.tsv e scanned-tips em %s para reler tudo" % st)
        revs = "".join(s + "\n" for s in tipshas) + "".join("^" + o + "\n" for o in old)
        raw = git(repo, "log", "--stdin", "-m", "-z", "--raw", "--no-renames", "--no-abbrev", "--format=", "--diff-filter=d", inp=revs.encode()) if tipshas else b""
        pairs, toks = set(), raw.split(b"\0")
        i = 0
        while i < len(toks):
            t = toks[i]
            if t.startswith(b":"):
                f = t.split()
                if len(f) < 5 or i + 1 >= len(toks):
                    raise RuntimeError("saída do git log ilegível")
                if f[1] != b"160000":   # gitlink (submódulo): não há blob
                    pairs.add((f[3].decode(), toks[i + 1]))
                i += 2
            else:
                i += 1
        cat = subprocess.Popen(["git", "-C", repo, "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        newblobs = flagged = 0
        last, dirty = time.monotonic(), False
        for oid, path in sorted(pairs):
            if oid not in seen:
                cat.stdin.write(oid.encode() + b"\n")
                cat.stdin.flush()
                hdr = cat.stdout.readline().split()
                if len(hdr) < 3 or hdr[1] != b"blob":
                    raise RuntimeError("o git não entregou o blob %s" % oid)
                size = int(hdr[2])
                body = cat.stdout.read(size)
                if len(body) != size or cat.stdout.read(1) != b"\n":   # o git morreu no meio do blob: conteúdo truncado NÃO é conteúdo limpo
                    raise RuntimeError("leitura curta do blob %s (%d de %d bytes)" % (oid, len(body), size))
                txt = None if size > BIG else readable(body)   # não sei ler (ou grande demais) = sinalizado, nunca "limpo"
                ph, cp = counts(txt) if txt is not None else (0, 0)
                seen[oid] = txt is None or ph >= PH_MIN or cp >= CP_MIN
                newblobs += 1
                flagged += seen[oid]
                dirty = True
            if seen[oid]:
                p = path.decode("utf8", "surrogateescape")
                if re.search(r"[\x00-\x1f\x7f]|\s$", p) or not p:
                    raise RuntimeError("caminho sinalizado que o filtro não consegue negar (quebra de linha, controle ou espaço no fim): %r" % p[:80])
                deny.add(esc(p))
            if dirty and time.monotonic() - last >= ckpt:   # depois do deny.add DESTE par: o seen e o deny-extra que vão ao disco andam juntos
                save(st, deny, seen)
                last, dirty = time.monotonic(), False
        cat.stdin.close()
        if cat.wait() != 0:
            raise RuntimeError("git cat-file terminou com erro")
        save(st, deny, seen)
        atomic(os.path.join(st, "scanned-tips"), "".join(l + "\n" for l in sorted(tips)))
        print("scan: %d commit(s)-par lidos, %d blob(s) novos, %d sinalizado(s); %d caminho(s) negados por conteúdo" % (len(pairs), newblobs, flagged, len(deny)))
        return 0
    except (RuntimeError, OSError, ValueError, UnicodeError) as e:
        sys.stderr.write("hetzner-mirror-scan: NÃO consegui varrer — %s\n" % e)
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
