#!/usr/bin/env python3
"""hetzner-pii-scan.py — olha o CONTEÚDO do que o filtro do rsync (que só vê NOME e pasta) deixaria sair do mini para o nó Linux de testes (ga-zri39b).

## Contents
  Uso · O que conta · O que NÃO garante

USO: caminhos relativos a <raiz>, um por linha, no stdin ->  python3 -I hetzner-pii-scan.py <raiz> [--rules ARQ] [--min-phones N] [--min-cpfs N]
  Imprime "<telefones>\\t<cpfs>\\t<caminho>" (só contagens, nunca o valor) de cada arquivo retido, e com --rules grava `- /caminho` (rsync) para cada um.
  rc 0 = LEU todos os arquivos · 2 = uso errado / não consegui gravar --rules · 3 = algum arquivo não pôde ser lido (linha "-1<TAB>-1<TAB>caminho", também em --rules): varredura INCOMPLETA,
  quem chama NÃO pode tratar como "nada retido" nem confiar que a regra do caminho funciona (nome que o texto da regra não representa não casa no rsync). Não saber o que tem dentro não é "limpo".
  A regra `- /caminho` escapa \\ * ? [ como o rsync lê um padrão COM curinga; um caminho com barra invertida e sem curinga não casa. Quem usa --rules confere com um rsync -n que o caminho sumiu (mbp-run.sh node_guard).
O QUE CONTA: valores DISTINTOS com forma de celular brasileiro (+55 DDD 9xxxx-xxxx, ou (DDD) 9xxxx-xxxx) e de CPF (xxx.xxx.xxx-xx). Número de cauda sintética
  (últimos 8 dígitos com no máximo 3 algarismos diferentes) não conta. Retém com >=20 telefones ou >=3 CPFs: é a LISTA (dump de leads colado num .py, num .json) que
  vaza em massa; 1 ou 2 números num comentário ou numa fixture passam.
O QUE NÃO GARANTE: é heurística de forma. Não vê dado sem forma de telefone/CPF (nome, e-mail, CNPJ, endereço) nem lista pequena; o resto é do filtro (nome e pasta).
"""
import re
import sys

PH = re.compile(r"(?<![0-9])\+?55 ?\(?[1-9][0-9]\)? ?9?[0-9]{4}-?[0-9]{4}(?![0-9])|\([1-9][0-9]\) ?9?[0-9]{4}-[0-9]{4}(?![0-9])")
CPF = re.compile(r"(?<![0-9])[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}(?![0-9])")


def counts(text):
    ph = set()
    for m in PH.finditer(text):
        d = re.sub(r"\D", "", m.group(0))
        if len(set(d[-8:])) > 3:
            ph.add(d[-11:])
    return len(ph), len(set(re.sub(r"\D", "", m) for m in CPF.findall(text)))


def esc(p):
    return "/" + re.sub(r"([\\*?\[])", r"\\\1", p)


def main(argv):
    root, rules, nph, ncp = None, None, 20, 3
    it = iter(argv)
    try:
        for a in it:
            if a == "--rules":
                rules = next(it)
            elif a == "--min-phones":
                nph = int(next(it))
            elif a == "--min-cpfs":
                ncp = int(next(it))
            elif root is None and not a.startswith("--"):
                root = a
            else:
                raise ValueError(a)
        if root is None:
            raise ValueError("raiz")
    except (StopIteration, ValueError):
        sys.stderr.write("uso: hetzner-pii-scan.py <raiz> [--rules ARQ] [--min-phones N] [--min-cpfs N]  (caminhos no stdin)\n")
        return 2
    held, unread = [], 0
    for line in sys.stdin.read().split("\n"):
        rel = line.strip("\r")
        if not rel:
            continue
        try:
            # vazio → 0 telefones/0 CPFs (passa); ilegível/inexistente → -1 -1, retido E contado em `unread`: o rc 3 diz que a varredura não foi completa
            with open(root.rstrip("/") + "/" + rel, encoding="utf-8", errors="replace") as fh:
                p, c = counts(fh.read())
        except OSError:
            p, c = -1, -1
            unread += 1
        if p < 0 or p >= nph or c >= ncp:
            held.append((p, c, rel))
            print("%d\t%d\t%s" % (p, c, rel))
    if rules is not None:
        try:
            with open(rules, "w", encoding="utf-8") as out:
                out.write("".join("- %s\n" % esc(r) for _, _, r in held))
        except OSError:
            return 2
    return 3 if unread else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
