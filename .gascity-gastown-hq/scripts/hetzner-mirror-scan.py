#!/usr/bin/env python3
"""hetzner-mirror-scan.py — olha o CONTEÚDO de tudo que o histórico do espelho (hetzner-mirror.sh) ainda não foi conferido e diz QUAIS CAMINHOS o servidor não pode receber (ga-2hd02v.1.3).

## Contents
  Uso · O que conta · O que NÃO garante · Códigos

USO: python3 -I hetzner-mirror-scan.py <repo.git> <estado-dir>
  Lê as pontas de refs/remotes/origin/*, percorre os commits novos desde a última varredura COMPLETA (estado-dir/scanned-tips) e, para cada par (blob, caminho) que um commit introduz
  (inclui o mesmo blob com outro nome: renomear não escapa), aplica a MESMA régua do hetzner-pii-scan.py (>=20 telefones ou >=3 CPFs distintos; a função `counts` é importada de lá, não copiada).
  Um blob sinalizado nega o CAMINHO (todas as versões dele, de qualquer commit) em estado-dir/deny-extra, uma linha por caminho no formato do filtro (`!/caminho`, escapado como o sparse:oid lê).
  Memória entre rodadas: estado-dir/seen.tsv (blob<TAB>0|1) evita reler; scanned-tips só avança quando TUDO foi lido e gravado — a última coisa que este script faz.
O QUE CONTA: a forma, como o hetzner-pii-scan.py. Blob > 50 MB, ou que o git não entrega, vale como SINALIZADO/ilegível (não saber não é "limpo").
O QUE NÃO GARANTE: dado sem forma de telefone/CPF (nome, e-mail, CNPJ, endereço) nem lista pequena. Um caminho sinalizado cujo nome não cabe numa linha do filtro (quebra de linha, controle, espaço no fim) NÃO tem como ser negado:
  o script recusa (rc 3) em vez de seguir sem negá-lo.
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
        tips = git(repo, "for-each-ref", "--format=%(objectname) %(refname)", "refs/remotes/origin").decode().splitlines()
        tipshas = sorted({l.split(" ", 1)[0] for l in tips})
        old = []
        if os.path.exists(os.path.join(st, "scanned-tips")):
            old = [l.split(" ", 1)[0] for l in open(os.path.join(st, "scanned-tips")).read().splitlines() if l]
        if old:   # uma ponta velha que o git não conhece mais (gc, prune) não pode virar `^sha`: o git log recusaria; sem ela a varredura só lê mais
            chk = subprocess.run(["git", "-C", repo, "cat-file", "--batch-check"], input="".join(o + "\n" for o in old).encode(), capture_output=True)
            if chk.returncode != 0:
                raise RuntimeError("cat-file --batch-check falhou")
            old = [f[0] for f in (l.split() for l in chk.stdout.decode().splitlines()) if len(f) >= 2 and f[1] == "commit"]
        seen = {}
        if os.path.exists(os.path.join(st, "seen.tsv")):
            for l in open(os.path.join(st, "seen.tsv")).read().splitlines():
                o, _, f = l.partition("\t")
                if o and f in ("0", "1"):
                    seen[o] = f == "1"
        deny = set(l for l in (open(os.path.join(st, "deny-extra")).read().splitlines() if os.path.exists(os.path.join(st, "deny-extra")) else []) if l)
        revs = "".join(s + "\n" for s in tipshas) + "".join("^" + o + "\n" for o in old)
        raw = git(repo, "log", "--stdin", "-m", "-z", "--raw", "--no-renames", "--no-abbrev", "--format=", "--diff-filter=AMC", inp=revs.encode()) if tipshas else b""
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
                cat.stdout.read(1)
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
        cat.wait()
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
