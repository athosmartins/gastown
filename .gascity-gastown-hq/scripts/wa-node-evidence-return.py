#!/usr/bin/env python3
"""wa-node-evidence-return.py — das beads que foram ao nó POR TEREM DADO CITADO COMO EVIDÊNCIA, quantas o nó soltou depois? (ga-t05a1z9, item 4). SÓ LEITURA.

Contents
  Para quê · Uso · O que diz · Estados que não se confundem · O que NÃO diz

PARA QUÊ  o classificador (wa-node-classify.py) passou a mandar ao nó a bead que CITA um banco/log/json como prova ("medido em queue.db") em vez de exigi-lo: o dado continua sem ir ao nó, então se a bead
          na verdade precisava lê-lo ela cai lá como teste vermelho e volta ao mini. Isto mede esse custo do erro: quantas dessas beads foram SOLTAS depois de despachadas.
USO       wa-node-evidence-return.py [--hours N] [--route-log ARQ] [--json]
          --hours N      janela, em horas, até agora (168 = 7 dias; inteiro de 1 a 99999)       --route-log   o log de rota (<cidade>/.gc/wa-node-route.jsonl; cidade = GC_CITY_PATH)
          exit 0 ok · 2 uso · 3 log de rota ausente ou ilegível (NÃO é "zero beads")
O QUE DIZ  lê o log de rota que o Pilot e o despachante gravam e, para cada linha `pilot-node-route` com rc 0 (a bead FOI ao nó) cujo `out` é o JSON do classificador, olha se o `info` dele tem alguma
          marca `evidencia-de-dado:`/`evidencia-de-doc:`. Dessas beads (a ÚLTIMA ida de cada uma na janela), conta as que têm um evento `release` com rc 0 DEPOIS da ida (o nó não ficou com elas) e as que
          não têm. Diz também quantas idas ao nó NÃO tinham `out` legível: aí não dá para saber se havia evidência, e elas ficam fora das duas contas, nomeadas.
ESTADOS QUE NÃO SE CONFUNDEM  log ausente ≠ log vazio ≠ log ilegível ≠ nenhuma bead com evidência na janela. Linha que não dá para ler vem CONTADA e avisada, nunca omitida em silêncio. `out` ilegível numa
          ida é "não sei" (contada à parte), nunca "sem evidência". Um `release` ANTERIOR à ida não conta como volta.
O QUE NÃO DIZ  não vê a bead que o nó construiu e o gate reprovou: ela segue atribuída ao nó até o inflight-reclaim-guard agir, e aqui aparece em "seguem no nó" (o relatório não distingue "construindo" de
          "reprovada e esperando reclaim"). Também não diz se a bead que ficou no nó foi bem construída; só que ninguém a soltou. `release` de bead que nunca teve evidência não entra.
"""
import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone

EX_OK, EX_USAGE, EX_NOLOG = 0, 2, 3
MARCAS = ("evidencia-de-dado:", "evidencia-de-doc:")   # o que o wa-node-classify.py põe no `info`, uma por caminho (até 8; o resto vira `evidencia-de-dado-mais:N`, que tem os dois-pontos depois do `mais` e por isso não casa aqui: as 8 nomeadas já bastam)


def parse_ts(s):
    """epoch de um carimbo 2026-11-01T15:17:12Z, ou None se não for isso (linha sem hora legível não entra na janela: é contada como ilegível)."""
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def classifier_json(out):
    """o dict do classificador dentro de `out`, ou None se não der para ler. Aceita o JSON puro ou, se o despachante imprimiu texto antes, a última linha que começa por `{`."""
    if not isinstance(out, str) or not out.strip():
        return None
    cands = [out] + [l for l in reversed(out.splitlines()) if l.lstrip().startswith("{")]
    for c in cands:
        try:
            d = json.loads(c)
        except ValueError:
            continue
        if isinstance(d, dict) and isinstance(d.get("info"), list):
            return d
    return None


def has_evidence(d):
    return any(isinstance(x, str) and x.startswith(MARCAS) for x in d["info"])


def read_route(path, since):
    """({bead: epoch da última ida COM evidência}, {bead: [epochs de release rc 0]}, nº de idas sem out legível, nº de linhas ilegíveis). Falha ao abrir o arquivo sobe como OSError."""
    sent, released, unreadable_out, bad = {}, {}, 0, 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if not line.strip():
                continue
            try:
                r = json.loads(line)
                ev, bead, ts = r.get("event"), r.get("bead"), parse_ts(r.get("ts"))
                if not isinstance(r, dict) or ts is None or not isinstance(bead, str) or not bead:
                    raise ValueError("linha sem evento/bead/hora")
            except (ValueError, AttributeError):
                bad += 1
                continue
            if ts < since:
                continue
            if ev == "pilot-node-route" and r.get("rc") == 0:
                d = classifier_json(r.get("out"))
                if d is None:
                    unreadable_out += 1          # foi ao nó e não sei se tinha evidência: fora das duas contas, mas contada
                elif has_evidence(d):
                    sent[bead] = max(sent.get(bead, 0), ts)
            elif ev == "release" and r.get("rc") == 0:
                released.setdefault(bead, []).append(ts)
    return sent, released, unreadable_out, bad


def main(argv):
    ap = argparse.ArgumentParser(prog="wa-node-evidence-return.py", add_help=True)
    ap.add_argument("--hours", default="168")
    ap.add_argument("--route-log", default=None)
    ap.add_argument("--json", action="store_true")
    try:
        a = ap.parse_args(argv[1:])
    except SystemExit as e:
        return EX_USAGE if e.code not in (0, None) else 0
    if not a.hours.isdigit() or not (1 <= int(a.hours) <= 99999):
        sys.stderr.write("uso: --hours é um inteiro de 1 a 99999\n")
        return EX_USAGE
    city = os.environ.get("GC_CITY_PATH") or "/Users/athos/gt/.gascity-gastown-hq"
    path = a.route_log or os.path.join(city, ".gc", "wa-node-route.jsonl")
    since = time.time() - int(a.hours) * 3600
    # ausente/ilegível -> rc 3 com a razão (nunca "0 beads"); vazio (existe, sem linha na janela) -> relatório com zeros e o texto diz que a janela não teve nenhuma
    try:
        sent, released, unreadable_out, bad = read_route(path, since)
    except OSError as e:
        sys.stderr.write("log de rota %s: %s (NÃO é zero beads)\n" % ("ausente" if isinstance(e, FileNotFoundError) else "ilegível", path))
        return EX_NOLOG
    back = sorted(b for b, t in sent.items() if any(r > t for r in released.get(b, [])))
    stay = sorted(b for b in sent if b not in back)
    rep = {"janela_h": int(a.hours), "foram_ao_no_com_evidencia": len(sent), "soltas_depois": len(back), "seguem_no_no": len(stay),
           "idas_sem_out_legivel": unreadable_out, "linhas_ilegiveis": bad, "soltas": back, "seguem": stay}
    if a.json:
        print(json.dumps(rep, ensure_ascii=False))
        return EX_OK
    if not sent:
        print("nenhuma bead com evidência foi ao nó nas últimas %d h" % rep["janela_h"])
    else:
        print("beads com evidência de dado que foram ao nó (últimas %d h): %d" % (rep["janela_h"], len(sent)))
        print("  soltas depois (o nó não ficou com elas; custo do erro): %d  %s" % (len(back), " ".join(back)))
        print("  seguem no nó (construindo, ou reprovadas esperando reclaim: este relatório não distingue): %d  %s" % (len(stay), " ".join(stay)))
    if unreadable_out:
        print("AVISO: %d ida(s) ao nó sem `out` legível: não dá para saber se tinham evidência (fora das contas acima)" % unreadable_out)
    if bad:
        print("AVISO: %d linha(s) do log de rota ilegível(is) (sem evento, bead ou hora): fora das contas" % bad)
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv))
