#!/usr/bin/env python3
"""wa-node-evidence-return.py — das beads que foram ao nó POR TEREM DADO CITADO COMO EVIDÊNCIA, quantas deram sinal de erro? (ga-t05a1z9, item 4). SÓ LEITURA.

Contents
  Para quê · Uso · O que diz · Estados que não se confundem · O que NÃO diz

PARA QUÊ  o classificador (wa-node-classify.py) passou a mandar ao nó a bead que CITA um banco/log/json como prova ("medido em queue.db") em vez de exigi-lo: o dado continua sem ir ao nó, então se a bead
          na verdade precisava lê-lo ela cai lá como teste vermelho e o nó a devolve (ou o gate a reprova). Isto mede esse custo do erro.
USO       wa-node-evidence-return.py [--hours N] [--route-log ARQ] [--city DIR] [--bd CMD] [--json]
          --hours N      janela, em horas, até agora (168 = 7 dias; inteiro ASCII de 1 a 99999)
          --route-log    o log de rota (<cidade>/.gc/wa-node-route.jsonl)      --city  a cidade (GC_CITY_PATH ou GC_CITY; acha a loja de cada bead em <cidade>/.beads/routes.jsonl)
          --bd           o comando bd (WA_NODE_BD ou `bd`)
          exit 0 ok · 2 uso · 3 log de rota ausente ou ilegível (NÃO é "zero beads")
O QUE DIZ  DUAS leituras, cada uma só do que ela sabe dizer.
          (1) A IDA, pelo log de rota. Uma bead FOI ao nó quando duas linhas concordam: a do Pilot (`pilot-node-route`, modo label ou auto, rc 0, com o JSON do classificador em `out`) e a do despachante
              (`apply` rc 0, "despachada para ...", gravada no instante em que o `bd update` foi conferido). O `info` do `out` diz se a ida tinha `evidencia-de-dado:`/`evidencia-de-doc:`. Vale a ÚLTIMA ida confirmada
              de cada bead na janela: se o texto da bead mudou e a última ida já não tem evidência, a anterior não conta.
          (2) O ERRO, na própria bead (`bd show`), só para as beads com evidência que foram: `athos.node_recusa` preenchido = o worker do nó a devolveu; rótulo `gate:needs-fix`/`gate:failed`/`gate:fix-attempt:N`
              = o gate reprovou. Nenhum dos dois deixa linha no log de rota, por isso o log não serve para isto.
          O evento `release` NÃO é lido: ele é o passo DEPOIS DA ENTREGA (quem fecha o ciclo é o Mayor, `wa-node-dispatch.sh release`), e no log uma soltura depois da entrega e uma devolução não se distinguem.
ESTADOS QUE NÃO SE CONFUNDEM  log ausente ≠ log vazio ≠ log ilegível ≠ nenhuma bead com evidência na janela. Linha que não dá para ler vem CONTADA e avisada. Cada um destes fica fora da conta de idas e é
          contado à parte (os quatro primeiros com as beads NOMEADAS; sombra e dry-run só em número, e o modo desconhecido só em número no --json):
            sem confirmação do despachante · ida INCERTA (rc 13, 124 ou 128-255: o Pilot não sabe se a escrita pegou; é a mesma lista de `_pilot_wa_node_decide`) · `out` ilegível (não dá para saber se havia
            evidência) · despacho sem linha do Pilot (apply à mão: o `out` não foi gravado) · sombra (modo shadow: só o `check`, nada foi atribuído) · dry-run · modo desconhecido.
          Da bead com evidência: recusada · reprovada no gate · SEM SINAL de erro · não lida (bd não respondeu, loja não achada, saída que não é UTF-8, JSON estranho). "Não lida" nunca vira "sem sinal".
O QUE NÃO DIZ  (a) O ERRO TEM LIMITES: o rótulo do gate e a recusa não têm data, então podem ser anteriores à ida (a bead pode ter sido tentada no mini antes); e "sem sinal de erro" é só isso: pode estar
          construindo, entregue, solta depois da entrega, ou ter tido a ida DESFEITA (modo pilot: se a sessão do alias não sobe, o Pilot desfaz a escrita com um `bd update` direto e não deixa linha nenhuma:
          a bead volta ao mini sem rastro). (b) Não diz se a bead que ficou no nó foi bem construída. (c) A bead que foi SEM evidência só entra em `sem_evidencia`: o bd não é consultado para ela.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

EX_OK, EX_USAGE, EX_NOLOG = 0, 2, 3
MARCAS = ("evidencia-de-dado:", "evidencia-de-doc:")   # o que o wa-node-classify.py põe no `info`, uma por caminho (até 8; o resto vira `evidencia-de-dado-mais:N`, que tem os dois-pontos depois do `mais` e por isso não casa aqui: as 8 nomeadas já bastam)
MODOS_QUE_ESCREVEM = ("label", "auto")                # PILOT_WA_NODE_ROUTE: `shadow` só classifica (nada é atribuído); `off` não grava linha
PAREAR_S = 120        # o despachante grava a sua linha ANTES de o `apply` voltar e o Pilot grava a dele logo DEPOIS: a distância real é de segundos; 120 s é folga (o prazo do apply é 90 s, PILOT_WA_NODE_TIMEOUT), não medida
LEITURA_BD_S = 20     # prazo de cada `bd show`
ORCAMENTO_BD_S = 120  # prazo de TODAS as leituras de bead juntas: o que não coube vira "não lida", nunca "sem sinal"
ROTULOS_GATE = ("gate:needs-fix", "gate:failed")      # os rótulos que o gate põe ao reprovar (lidos de uma bead reprovada de verdade); mais o prefixo abaixo
PREFIXO_TENTATIVA_GATE = "gate:fix-attempt:"


def parse_ts(s):
    """epoch de um carimbo 2026-11-01T15:17:12Z, ou None se não for isso (linha sem hora legível não entra na janela: é contada como ilegível)."""
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def int_rc(v):
    """o rc como inteiro, ou None (texto, nulo, booleano ou ausente: o chamador conta a linha como ilegível)."""
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def rc_incerto(rc):
    """True se o Pilot trata o rc do `apply` como "a escrita pode ter pegado, não sei" (13, 124 e 128-255; 125-127 é "nada rodou"). Espelha o `case` de _pilot_wa_node_decide em pilot-dispatcher.sh."""
    return rc in (13, 124) or 128 <= rc <= 255


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


def evidencia_da_ida(out):
    """True = o `info` do classificador tem marca de evidência; False = tem `info` e nenhuma marca; None = `out` vazio ou ilegível (não sei)."""
    d = classifier_json(out)
    return None if d is None else any(isinstance(x, str) and x.startswith(MARCAS) for x in d["info"])


class Leitura(object):
    """o que o log de rota tem na janela, já separado por tipo de linha. Cada dict é {bead: ...}."""
    def __init__(self):
        self.pilot_ok = {}        # linhas do Pilot em label/auto com rc 0: [(ts, evidência True/False/None)]
        self.despachos = {}       # apply rc 0 "despachada ...": [ts]
        self.dry = {}             # apply rc 0 "dry-run ...": [ts]
        self.incertas = {}        # linhas do Pilot em label/auto com rc incerto: n
        self.sombra = {}          # linhas do Pilot em modo shadow: n
        self.modo_estranho = {}   # linhas do Pilot com modo que não é shadow/label/auto: n
        self.apply_estranho = 0   # apply rc 0 cujo detalhe não é "despachada ..." nem "dry-run ..."
        self.bad = 0              # linhas sem evento, bead, hora ou rc legível


def _add(d, bead, v):
    d.setdefault(bead, []).append(v)


def read_route(path, since):
    """Leitura do log de rota na janela [since, agora]. Falha ao abrir o arquivo sobe como OSError (o chamador responde rc 3)."""
    L = Leitura()
    # vazio → Leitura sem nada (o relatório diz que a janela não teve ida); falhou/ilegível → arquivo: OSError sobe (rc 3); linha: contada em `bad`, nunca omitida
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if not line.strip():
                continue
            try:
                r = json.loads(line)
                if not isinstance(r, dict):
                    raise ValueError("linha que não é objeto")
                ev, bead, ts = r.get("event"), r.get("bead"), parse_ts(r.get("ts"))
                if ts is None or not isinstance(bead, str) or not bead:
                    raise ValueError("linha sem evento/bead/hora")
            except ValueError:
                L.bad += 1
                continue
            if ts < since - PAREAR_S:
                continue          # a linha do despachante de uma ida logo no começo da janela é um pouco anterior a ela: entra só para parear
            if ev == "apply":
                rc = int_rc(r.get("rc"))
                if rc is None:
                    L.bad += 1
                elif rc == 0:
                    det = r.get("detail")
                    if isinstance(det, str) and det.startswith("despachada"):
                        _add(L.despachos, bead, ts)
                    elif isinstance(det, str) and det.startswith("dry-run"):
                        _add(L.dry, bead, ts)
                    else:
                        L.apply_estranho += 1      # rc 0 de um apply que não diz o que fez: não é ida, e não some
            elif ev == "pilot-node-route":
                if ts < since:
                    continue
                rc, mode = int_rc(r.get("rc")), r.get("mode")
                if rc is None:
                    L.bad += 1
                elif mode == "shadow":
                    L.sombra[bead] = L.sombra.get(bead, 0) + 1     # o `check` da sombra tem rc 0 e o mesmo `out`, mas nada foi atribuído
                elif mode not in MODOS_QUE_ESCREVEM:
                    L.modo_estranho[bead] = L.modo_estranho.get(bead, 0) + 1
                elif rc == 0:
                    _add(L.pilot_ok, bead, (ts, evidencia_da_ida(r.get("out"))))
                elif rc_incerto(rc):
                    L.incertas[bead] = L.incertas.get(bead, 0) + 1
                # o resto (10/11/12: o classificador ou o despachante recusaram; 125-127: nada rodou; outros): nada foi escrito, a bead seguiu no mini, e isso é o normal, não um estado a contar
    return L


def parear(L, since):
    """cruza a linha do Pilot com a do despachante, uma a uma (cada `despachada` serve a UMA linha). Devolve (idas, nao_confirmadas, dry_run, despacho_sem_linha):
    idas = {bead: evidência da ÚLTIMA ida confirmada}; nao_confirmadas = {bead: n} (rc 0 do Pilot sem `despachada` e sem `dry-run`); dry_run = n; despacho_sem_linha = {bead: n}."""
    idas, nao_conf, dry_n, usados = {}, {}, 0, {}
    for bead, linhas in L.pilot_ok.items():
        ds, dr = sorted(L.despachos.get(bead, [])), sorted(L.dry.get(bead, []))
        used_d, used_r = set(), set()
        ultima = None
        for ts, evid in sorted(linhas, key=lambda x: x[0]):
            c = [i for i, d in enumerate(ds) if i not in used_d and 0 <= ts - d <= PAREAR_S]
            if c:
                used_d.add(c[-1])
                if ultima is None or ts >= ultima[0]:
                    ultima = (ts, evid)
                continue
            c = [i for i, d in enumerate(dr) if i not in used_r and 0 <= ts - d <= PAREAR_S]
            if c:
                used_r.add(c[-1])
                dry_n += 1
            else:
                nao_conf[bead] = nao_conf.get(bead, 0) + 1
        if ultima is not None:
            idas[bead] = ultima[1]
        usados[bead] = used_d
    sem_linha = {}
    for bead, ds in L.despachos.items():
        n = sum(1 for i, d in enumerate(sorted(ds)) if i not in usados.get(bead, set()) and d >= since)
        if n:
            sem_linha[bead] = n
    return idas, nao_conf, dry_n, sem_linha


def loja_da_bead(city, bead):
    """a pasta da loja da bead (pelo prefixo, em <cidade>/.beads/routes.jsonl), ou None."""
    # vazio (sem linha do prefixo, id sem prefixo) → None; falhou/ilegível (arquivo ausente, linha que não é JSON, pasta que não existe) → None: a bead vira "não lida", nunca "sem sinal"
    if "-" not in bead:
        return None
    prefix = bead.split("-", 1)[0]
    try:
        with open(os.path.join(city, ".beads", "routes.jsonl"), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict) and r.get("prefix") == prefix and isinstance(r.get("path"), str) and r["path"]:
                    d = r["path"] if os.path.isabs(r["path"]) else os.path.join(city, r["path"])
                    return os.path.realpath(d) if os.path.isdir(d) else None
    except OSError:
        return None
    return None


def estado_da_bead(city, bd, bead, deadline):
    """(estado, motivo): estado = 'recusada' | 'gate' | 'sem_sinal' | None (não lida; o motivo diz por quê). Recusa ganha do gate quando as duas existem."""
    store = loja_da_bead(city, bead)
    if store is None:
        return None, "loja não achada em %s/.beads/routes.jsonl" % city
    restante = deadline - time.time()
    if restante <= 0:
        return None, "orçamento de leitura esgotado"
    # vazio (sem saída, ou saída sem a bead pedida) → não lida; falhou/ilegível (bd ausente, prazo, rc != 0, saída que não é UTF-8, JSON ruim, `labels`/`metadata` do tipo errado) → não lida. `labels`/`metadata` AUSENTES
    # numa bead lida valem "nenhum": é como o bd serializa a bead sem rótulo.
    try:
        p = subprocess.run([bd, "-C", store, "show", bead, "--json"], stdin=subprocess.DEVNULL, capture_output=True, text=True,
                           timeout=min(LEITURA_BD_S, restante))
    except (OSError, subprocess.SubprocessError, UnicodeError) as e:   # UnicodeError: text=True decodifica estrito e o byte que não é UTF-8 estoura AQUI, dentro do run (não no json.loads de baixo): sem ele o relatório morria em traceback (rc 1)
        return None, "bd não respondeu (%s)" % type(e).__name__
    if p.returncode != 0:
        return None, "bd show rc=%d" % p.returncode
    try:
        j = json.loads(p.stdout)
    except ValueError:
        return None, "bd show: JSON ilegível"
    if isinstance(j, list):
        j = j[0] if j else None
    if not isinstance(j, dict) or j.get("id") != bead:
        return None, "bd show: não devolveu a bead pedida"
    labels, md = j.get("labels", []), j.get("metadata", {})
    if labels is None:
        labels = []
    if md is None:
        md = {}
    if not isinstance(labels, list) or not isinstance(md, dict):
        return None, "bd show: labels/metadata com tipo estranho"
    rec = md.get("athos.node_recusa")
    if isinstance(rec, str) and rec.strip():
        return "recusada", ""
    if any(isinstance(x, str) and (x in ROTULOS_GATE or x.startswith(PREFIXO_TENTATIVA_GATE)) for x in labels):
        return "gate", ""
    return "sem_sinal", ""


def main(argv):
    ap = argparse.ArgumentParser(prog="wa-node-evidence-return.py", add_help=True)
    ap.add_argument("--hours", default="168")
    ap.add_argument("--route-log", default=None)
    ap.add_argument("--city", default=None)
    ap.add_argument("--bd", default=None)
    ap.add_argument("--json", action="store_true")
    try:
        a = ap.parse_args(argv[1:])
    except SystemExit as e:
        return EX_USAGE if e.code not in (0, None) else 0
    if not re.fullmatch(r"[0-9]{1,5}", a.hours) or not (1 <= int(a.hours) <= 99999):   # só dígitos ASCII: `str.isdigit` aceita "²" e o `int` quebra com traceback
        sys.stderr.write("uso: --hours é um inteiro de 1 a 99999\n")
        return EX_USAGE
    city = a.city or os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or "/Users/athos/gt/.gascity-gastown-hq"
    bd = a.bd or os.environ.get("WA_NODE_BD") or "bd"
    path = a.route_log or os.path.join(city, ".gc", "wa-node-route.jsonl")
    now = time.time()
    since = now - int(a.hours) * 3600
    # ausente/ilegível -> rc 3 com a razão (nunca "0 beads"); vazio (existe, sem linha na janela) -> relatório com zeros e o texto diz que a janela não teve nenhuma
    try:
        L = read_route(path, since)
    except OSError as e:
        sys.stderr.write("log de rota %s: %s (NÃO é zero beads)\n" % ("ausente" if isinstance(e, FileNotFoundError) else "ilegível", path))
        return EX_NOLOG
    idas, nao_conf, dry_n, sem_linha = parear(L, since)
    com = sorted(b for b, e in idas.items() if e is True)
    sem_ev = sorted(b for b, e in idas.items() if e is False)
    ev_desc = sorted(b for b, e in idas.items() if e is None)
    estado = {"recusada": [], "gate": [], "sem_sinal": [], "nao_lida": []}
    deadline = now + ORCAMENTO_BD_S
    for b in com:
        st, why = estado_da_bead(city, bd, b, deadline)
        if st is None:
            sys.stderr.write("bead %s não lida: %s\n" % (b, why))
            st = "nao_lida"
        estado[st].append(b)
    rep = {"janela_h": int(a.hours), "foram_ao_no": len(idas), "com_evidencia": len(com), "sem_evidencia": len(sem_ev),
           "evidencia_desconhecida": ev_desc,
           "recusadas_pelo_no": estado["recusada"], "reprovadas_no_gate": estado["gate"], "sem_sinal_de_erro": estado["sem_sinal"], "beads_nao_lidas": estado["nao_lida"],
           "idas_incertas": sorted(L.incertas), "sombra_linhas": sum(L.sombra.values()), "sombra_beads": len(L.sombra), "dry_run_linhas": dry_n,
           "sem_confirmacao_do_despachante": sorted(nao_conf), "despachos_sem_linha_do_pilot": sorted(sem_linha),
           "modo_desconhecido_linhas": sum(L.modo_estranho.values()), "apply_nao_reconhecido": L.apply_estranho, "linhas_ilegiveis": L.bad}
    if a.json:
        print(json.dumps(rep, ensure_ascii=False))
        return EX_OK
    lst = lambda xs: " ".join(xs)
    if not com:
        print("nenhuma bead com evidência foi ao nó (ida confirmada) nas últimas %d h" % rep["janela_h"])
    else:
        print("beads com evidência de dado que foram ao nó (ida confirmada; últimas %d h): %d" % (rep["janela_h"], len(com)))
        print("  o worker do nó devolveu (athos.node_recusa; custo do erro): %d  %s" % (len(estado["recusada"]), lst(estado["recusada"])))
        print("  o gate reprovou (rótulo gate:*; sem data, pode ser anterior à ida): %d  %s" % (len(estado["gate"]), lst(estado["gate"])))
        print("  sem sinal de erro (construindo, entregue, solta após a entrega, ou ida desfeita por falha de sessão: a leitura não distingue): %d  %s" % (len(estado["sem_sinal"]), lst(estado["sem_sinal"])))
        if estado["nao_lida"]:
            print("  AVISO: %d bead(s) NÃO LIDA(S) (o motivo vai ao stderr): não dá para saber se deram erro: %s" % (len(estado["nao_lida"]), lst(estado["nao_lida"])))
    if ev_desc:
        print("AVISO: %d ida(s) ao nó sem `out` legível: não dá para saber se tinham evidência (fora das contas acima): %s" % (len(ev_desc), lst(ev_desc)))
    if sem_linha:
        print("AVISO: %d bead(s) com despacho sem linha do Pilot (apply à mão, ou a linha se perdeu): não dá para saber se tinham evidência (fora das contas acima): %s" % (len(sem_linha), lst(sorted(sem_linha))))
    if L.incertas:
        print("AVISO: %d bead(s) com ida INCERTA (rc 13, 124 ou 128-255: o Pilot não sabe se a escrita pegou; sem `out`, a evidência é desconhecida): fora das contas acima: %s" % (len(L.incertas), lst(sorted(L.incertas))))
    if nao_conf:
        print("AVISO: %d bead(s) com linha do Pilot rc 0 sem `despachada` do despachante (apply perdido do log, ou log de outro lugar): não contam como ida: %s" % (len(nao_conf), lst(sorted(nao_conf))))
    if L.sombra:
        print("info: %d linha(s) em modo shadow (%d bead(s)): só classificação, nada foi atribuído; fora das contas acima" % (rep["sombra_linhas"], len(L.sombra)))
    if dry_n:
        print("info: %d linha(s) de dry-run (o apply não escreveu); fora das contas acima" % dry_n)
    if L.modo_estranho:
        print("AVISO: %d linha(s) do Pilot com modo que não é shadow/label/auto: fora das contas acima: %s" % (rep["modo_desconhecido_linhas"], lst(sorted(L.modo_estranho))))
    if L.apply_estranho:
        print("AVISO: %d linha(s) `apply` rc 0 do despachante sem \"despachada\" nem \"dry-run\": não contam como ida" % L.apply_estranho)
    if L.bad:
        print("AVISO: %d linha(s) do log de rota ilegível(is) (sem evento, bead, hora ou rc): fora das contas" % L.bad)
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv))
