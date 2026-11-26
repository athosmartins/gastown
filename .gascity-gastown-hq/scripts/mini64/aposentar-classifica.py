#!/usr/bin/env python3
"""aposentar-classifica.py — o que cada plist do LaunchAgents e, segundo aposentar-camadas.tsv (ga-ke5w2ie.4).

O veredito sobre o plist e plistlib (o leitor dos lints do repo), nunca grep: um Label em comentario XML e mencao, nao rotulo.
Uso: --tsv ARQUIVO --agents-dir DIRETORIO [--familias "pref1 pref2 ..."]
Lista (TAB, '#' comenta): acao(aposentar|manter) camada dominio(gui|system) tipo(exato|prefixo) padrao [nota]. Vale a regra MAIS ESPECIFICA (exato >
prefixo mais longo); padrao repetido e erro; system so aceita exato (o script nao varre /Library/LaunchDaemons). A camada de 1a aparicao entre as
'aposentar' e a primeira a agir.
Saida (TSV; NADA sai se a lista ou o diretorio forem invalidos, rc 2): CAMADA n · PLISTS lidos ilegiveis quebrados fora · ALVO camada dominio rotulo
arquivo|- regra · MANTER camada rotulo arquivo regra · LIVRE rotulo arquivo (da familia da cidade, sem regra: continua rodando) · ILEGIVEL arquivo motivo
(3o estado: nunca vira "nada") · QUEBRADO arquivo destino (link sem destino: o launchd nao o carrega).
Python 3.9 de proposito: o mini traz o do Command Line Tools."""
from __future__ import annotations

import argparse
import os
import plistlib
import re
import sys

LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
CAMADA_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
# as 9 familias medidas nos plists do repo da cidade e do repo do WA (a bead citava so 4)
FAMILIAS = ("com.whatsapp. com.urblink. br.urblink. com.phoneproxy. com.gastown. com.realestate. com.gascity. com.athos. com.whatsapp-automation.")


class Invalido(Exception):
    pass


def ler_regras(caminho):
    # vazio (so comentarios, ou so 'manter') → Invalido, nunca "nada a fazer"; falhou/ilegivel (nao abre, nao e UTF-8, linha fora do formato) → Invalido
    try:
        with open(caminho, "r", encoding="utf-8") as f:
            linhas = f.read().split("\n")
    except (OSError, UnicodeDecodeError) as e:
        raise Invalido("nao consegui ler a lista de camadas %s: %s" % (caminho, e))
    regras, vistos = [], {}
    for n, bruta in enumerate(linhas, 1):
        linha = bruta.rstrip("\r")
        if not linha.strip() or linha.lstrip().startswith("#"):
            continue
        c = [x.strip() for x in linha.split("\t", 5)]
        if len(c) < 5:
            raise Invalido("linha %d da lista: esperava 5 ou 6 colunas separadas por TAB (acao camada dominio tipo padrao [nota]), achei %d" % (n, len(c)))
        acao, camada, dominio, tipo, padrao = c[:5]
        for nome, v, ok in (("acao", acao, ("aposentar", "manter")), ("dominio", dominio, ("gui", "system")), ("tipo", tipo, ("exato", "prefixo"))):
            if v not in ok:
                raise Invalido("linha %d da lista: %s '%s' invalido (use %s)" % (n, nome, v, " ou ".join(ok)))
        if not CAMADA_RE.match(camada):
            raise Invalido("linha %d da lista: nome de camada '%s' invalido (minusculas, digitos e hifen)" % (n, camada))
        if not LABEL_RE.match(padrao):
            raise Invalido("linha %d da lista: padrao '%s' tem caractere fora de [A-Za-z0-9._-] (iria para o alvo do launchctl)" % (n, padrao))
        if dominio == "system" and tipo != "exato":
            raise Invalido("linha %d da lista: dominio system so aceita tipo exato (o script nao varre /Library/LaunchDaemons)" % n)
        chave = (dominio, tipo, padrao)
        if chave in vistos:
            raise Invalido("linha %d da lista: o padrao %s (%s, %s) esta repetido, ja e a linha %d" % (n, padrao, dominio, tipo, vistos[chave]))
        vistos[chave] = n
        regras.append({"n": n, "acao": acao, "camada": camada, "dominio": dominio, "tipo": tipo, "padrao": padrao})
    if not regras:
        raise Invalido("a lista de camadas %s nao tem nenhuma regra (so comentarios?): lista vazia nao e 'nada a fazer'" % caminho)
    if not any(r["acao"] == "aposentar" for r in regras):
        raise Invalido("a lista de camadas %s nao tem nenhuma regra 'aposentar'" % caminho)
    return regras


def melhor_regra(rotulo, regras):
    """A regra gui mais especifica que casa com o rotulo (exato > prefixo mais longo), ou None."""
    melhor = None
    for r in regras:
        if r["dominio"] != "gui":
            continue
        if r["tipo"] == "exato" and rotulo == r["padrao"]:
            esp = (2, len(r["padrao"]))
        elif r["tipo"] == "prefixo" and rotulo.startswith(r["padrao"]):
            esp = (1, len(r["padrao"]))
        else:
            continue
        if melhor is None or esp > melhor[0]:
            melhor = (esp, r)
    return melhor[1] if melhor else None


def ler_plists(diretorio):
    # vazio (diretorio sem .plist) → listas vazias, o chamador decide; falhou/ilegivel (diretorio que nao abre) → Invalido
    try:
        nomes = sorted(os.listdir(diretorio))
    except OSError as e:
        raise Invalido("nao consegui ler o diretorio %s: %s" % (diretorio, e))
    lidos, ilegiveis, quebrados, vistos = [], [], [], set()
    for nome in nomes:
        caminho = os.path.join(diretorio, nome)
        if not nome.endswith(".plist"):
            continue
        if os.path.islink(caminho) and not os.path.exists(caminho):
            quebrados.append((caminho, os.readlink(caminho)))
            continue
        try:
            if not os.path.isfile(caminho):
                raise ValueError("nao e um arquivo regular")
            with open(caminho, "rb") as f:
                dados = plistlib.load(f)
        except Exception as e:  # plistlib levanta ExpatError, InvalidFileException, ValueError ou OSError conforme o formato: todo erro e "ilegivel", nunca "vazio"
            ilegiveis.append((caminho, "plist ilegivel (%s)" % type(e).__name__))
            continue
        rotulo = dados.get("Label") if isinstance(dados, dict) else None
        if not isinstance(rotulo, str) or not LABEL_RE.match(rotulo):
            ilegiveis.append((caminho, "plist sem Label valido (so [A-Za-z0-9._-])"))
        elif rotulo not in vistos:  # o mesmo Label em dois arquivos: vale o 1o (ordem do nome); o 2o e copia velha
            vistos.add(rotulo)
            lidos.append((rotulo, caminho))
    return lidos, ilegiveis, quebrados


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--tsv", required=True)
    ap.add_argument("--agents-dir", required=True)
    ap.add_argument("--familias", default=FAMILIAS)
    a = ap.parse_args(argv)
    try:
        regras = ler_regras(a.tsv)
        lidos, ilegiveis, quebrados = ler_plists(a.agents_dir)
    except Invalido as e:
        sys.stderr.write("aposentar-classifica: %s\n" % e)
        return 2
    ordem = []
    for r in regras:
        if r["acao"] == "aposentar" and r["camada"] not in ordem:
            ordem.append(r["camada"])
    alvos, manter, livres, achados, fora = [], [], [], set(), 0
    for rotulo, caminho in lidos:
        r = melhor_regra(rotulo, regras)
        if r is None:
            if any(rotulo.startswith(p) for p in a.familias.split()):
                livres.append((rotulo, caminho))
            else:
                fora += 1
        else:
            desc = "linha %d: %s %s" % (r["n"], r["tipo"], r["padrao"])
            if r["acao"] == "aposentar":
                alvos.append((r["camada"], "gui", rotulo, caminho, desc))
                achados.add(rotulo)
            else:
                manter.append((r["camada"], rotulo, caminho, desc))
    for r in regras:  # regra exata sem plist no disco: o disable vale mesmo assim; prefixo so expande o que existe
        if r["acao"] == "aposentar" and r["tipo"] == "exato" and (r["dominio"] == "system" or r["padrao"] not in achados):
            arq = "/Library/LaunchDaemons/%s.plist" % r["padrao"] if r["dominio"] == "system" else "-"
            alvos.append((r["camada"], r["dominio"], r["padrao"], arq, "linha %d: exato %s" % (r["n"], r["padrao"])))
    alvos.sort(key=lambda x: (ordem.index(x[0]), x[1] != "gui", x[2]))
    def ln(*c):  # campo com TAB ou quebra de linha (caminho esquisito) nao pode quebrar o TSV de saida
        return "\t".join(str(x).replace("\t", " ").replace("\n", " ").replace("\r", " ") for x in c)
    out = [ln("CAMADA", c) for c in ordem] + [ln("PLISTS", len(lidos), len(ilegiveis), len(quebrados), fora)]
    out += [ln("ALVO", *x) for x in alvos] + [ln("MANTER", *x) for x in sorted(manter, key=lambda x: x[1])]
    out += [ln("LIVRE", *x) for x in sorted(livres)] + [ln("ILEGIVEL", *x) for x in ilegiveis] + [ln("QUEBRADO", *x) for x in quebrados]
    sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
