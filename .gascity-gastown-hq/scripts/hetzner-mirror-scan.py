#!/usr/bin/env python3
"""hetzner-mirror-scan.py — diz QUAIS CAMINHOS o servidor não pode receber, olhando o CONTEÚDO do histórico do espelho ainda não conferido (ga-2hd02v.1.3).

## Contents
  Uso · O que conta · O que NÃO garante · Códigos

USO: python3 -I hetzner-mirror-scan.py <repo.git> <estado-dir>. Para cada par (blob, caminho) que um commit novo de refs/remotes/origin/* introduz — todo status MENOS D, que não traz blob: A, M, T (troca de tipo)…; o mesmo blob com outro nome também: renomear não escapa — aplica a régua do
  hetzner-pii-scan.py (>=20 telefones ou >=3 CPFs; a função `counts` é importada de lá). Blob sinalizado nega o CAMINHO (todas as versões) em estado-dir/deny-extra (`!/caminho`, escapado como o sparse:oid lê).
  seen.tsv (blob<TAB>0|1) evita reler; scanned-tips só avança quando TUDO foi lido e gravado — a última coisa que este script faz.
O QUE CONTA: a forma. Blob > 50 MB, ou que o git não entrega por inteiro, vale como SINALIZADO/falha (não saber não é "limpo"). Caminho sinalizado que o filtro não consegue negar (quebra de linha, controle, espaço no fim): rc 3.
O QUE NÃO GARANTE: dado sem forma de telefone/CPF (nome, e-mail, CNPJ, endereço) nem lista pequena.
CÓDIGOS: 0 varredura completa e gravada · 3 não consegui varrer (nada avançou; o espelho continua "não pronto") · 2 uso
"""
import importlib.util
import os
import re
import subprocess
import sys

BIG = 50_000_000
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


def atomic(path, text):
    tmp = path + ".new"
    with open(tmp, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


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
        tips = lines(git(repo, "for-each-ref", "--format=%(objectname) %(refname)", "refs/remotes/origin").decode())
        tipshas = sorted({l.split(" ", 1)[0] for l in tips})
        old = []
        if os.path.exists(os.path.join(st, "scanned-tips")):
            old = [l.split(" ", 1)[0] for l in lines(open(os.path.join(st, "scanned-tips")).read())]
        if old:   # uma ponta velha que o git não conhece mais (gc, prune) não pode virar `^sha`: o git log recusaria; sem ela a varredura só lê mais
            chk = subprocess.run(["git", "-C", repo, "cat-file", "--batch-check"], input="".join(o + "\n" for o in old).encode(), capture_output=True)
            if chk.returncode != 0:
                raise RuntimeError("cat-file --batch-check falhou")
            old = [f[0] for f in (l.split() for l in chk.stdout.decode().splitlines()) if len(f) >= 2 and f[1] == "commit"]
        seen = {}
        if os.path.exists(os.path.join(st, "seen.tsv")):
            for l in lines(open(os.path.join(st, "seen.tsv")).read()):
                o, _, f = l.partition("\t")
                if o and f in ("0", "1"):
                    seen[o] = f == "1"
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
                if size > BIG:
                    seen[oid] = True
                else:
                    ph, cp = counts(body.decode("latin-1"))
                    seen[oid] = ph >= 20 or cp >= 3
                newblobs += 1
                flagged += seen[oid]
            if seen[oid]:
                p = path.decode("utf8", "surrogateescape")
                if re.search(r"[\x00-\x1f\x7f]|\s$", p) or not p:
                    raise RuntimeError("caminho sinalizado que o filtro não consegue negar (quebra de linha, controle ou espaço no fim): %r" % p[:80])
                deny.add(esc(p))
        cat.stdin.close()
        if cat.wait() != 0:
            raise RuntimeError("git cat-file terminou com erro")
        atomic(os.path.join(st, "deny-extra"), "".join(d + "\n" for d in sorted(deny)))
        atomic(os.path.join(st, "seen.tsv"), "".join("%s\t%d\n" % (o, v) for o, v in sorted(seen.items())))
        atomic(os.path.join(st, "scanned-tips"), "".join(l + "\n" for l in sorted(tips)))
        print("scan: %d commit(s)-par lidos, %d blob(s) novos, %d sinalizado(s); %d caminho(s) negados por conteúdo" % (len(pairs), newblobs, flagged, len(deny)))
        return 0
    except (RuntimeError, OSError, ValueError, UnicodeError) as e:
        sys.stderr.write("hetzner-mirror-scan: NÃO consegui varrer — %s\n" % e)
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
