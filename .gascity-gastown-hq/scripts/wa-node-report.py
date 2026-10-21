#!/usr/bin/env python3
"""wa-node-report.py — o WhatsApp foi mesmo ao nó, e o nó ficou ocupado? A prova do dia seguinte da ga-2hd02v.3. SÓ LEITURA.

Contents
  Para quê · Uso · O que diz · Estados que não se confundem · O que NÃO diz

PARA QUÊ (Athos 20/10: "o que não pode é ficar menos do que 100% ocupado"): responder em um comando as duas perguntas que decidem os próximos passos da ga-2hd02v.3 —
  (1) quantas beads de WhatsApp o Pilot mandou ao nó, e a sombra já tem base para ligar `PILOT_WA_NODE_ROUTE=auto`? (2) quanto da CPU do nó foi usada, hora a hora?
USO      wa-node-report.py [--hours N] [--city DIR] [--json] [--min-hours H] [--min-beads B] [--busy-pct P]
         --hours N      janela, em horas, até agora (48; inteiro de 1 a 99999, "010" é dez)        --city DIR   a cidade (GC_CITY_PATH, senão /Users/athos/gt/.gascity-gastown-hq)
         --min-hours H  quantas HORAS UTC COM DADO bastam para REVISAR a flip para auto (24)        --min-beads B  quantas beads COM VEREDITO bastam (30)
         --busy-pct P   a partir de quantos % de CPU a leitura conta como "perto de 100%" (90)       --json       o mesmo em JSON
         (a janela padrão é 48 h porque 24 horas com dado numa janela de 24 h não deixam folga: ela toca 25 horas UTC no máximo, e uma hora sem veredito já reprova)
         exit 0 ok · 2 uso · 3 NENHUM dos dois logs deu para usar (ausente ou ilegível) · 4 relatório não formado
O QUE DIZ  1. a rota (<cidade>/.gc/wa-node-route.jsonl: o que o despachante e o Pilot gravam): cobertura da sombra (horas COM VEREDITO — node/mini/não sei —, não o intervalo entre a primeira e a última nem hora só de "não li"),
              o veredito de cada bead (o ÚLTIMO da janela), as que foram ao nó de verdade, as que o classificador mandou ao nó mas não couberam (sem vaga), as que mudaram de veredito,
              que é onde mora o falso "node", e as de ESCRITA NÃO CONFIRMADA (rc 13 do despachante, ou o Pilot que estourou o prazo), que o relatório lista para conferir à mão.
              No modo `shadow` o Pilot só roda o `check` do despachante e NÃO grava `apply`: o veredito vem da linha `pilot-node-route` (rc 0/10/11 + o `verdict` do JSON em `out`);
           2. a CPU do nó por hora, em UTC (<cidade>/.gc/hetzner-occupancy.jsonl: uma leitura a cada 15 min do hetzner-occupancy-watch), a média, quantas leituras ficaram perto de 100%
              e quantas sessões wa-worker-remote estavam vivas;
           3. a prontidão MECÂNICA da sombra: horas e beads suficientes para alguém REVISAR. Não é aprovação: quem liga o `auto` é uma pessoa, depois de conferir uma a uma as beads `node` da lista.
ESTADOS QUE NÃO SE CONFUNDEM  log ausente ("ainda não houve rodada") ≠ log vazio ≠ log ilegível ≠ zero decisões na janela. Linha que não dá para ler vem CONTADA e avisada, nunca omitida em
           silêncio. Linha de outro assunto no mesmo log (o `tipo:"reaper"` que o reaper grava em hetzner-occupancy.jsonl; um `event` que o despachante não conhece) não é leitura nem decisão: fica fora das contas e vem CONTADA. CPU que não foi lida (a 1ª leitura só semeia o baseline; o ssh falhou) NUNCA vira 0%: entra em "sem CPU lida". Sessões não lidas, ou lidas com entrada ilegível
           (`sessoes.ilegiveis`: a lista pode estar incompleta), não viram "0 sessões". Linha do Pilot cujo rc e `verdict` discordam NUNCA vira mini nem node: vai a "outro" e à lista de conferência.
O QUE NÃO DIZ  que nenhuma bead com dado de lead foi ao nó: o relatório não vê o conteúdo da bead. Lista as que foram (e por quê) para a conferência humana. A garantia de que dado de lead
           não chega ao nó é o espelho git com a varredura de CPF/telefone, não este relatório. Também não diz que o WA RODOU bem no nó: só que a bead foi atribuída lá.
           A CPU de cada hora é a média das leituras cujo `epoch` cai nela (uma leitura vale uma, qualquer que seja a janela de medida `janela_s` dela) e a leitura de uma hora
           vai para a hora UTC do seu `epoch`, não da janela que ela mediu: a fronteira da hora é aproximada em até 15 min.
"""
import argparse
import calendar
import json
import math
import os
import re
import sys
import time

DEFAULT_CITY = "/Users/athos/gt/.gascity-gastown-hq"
TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
# os vereditos de verdade; o resto (nao-elegivel, nao-li, falha-escrita, outro) diz por que a bead não chegou a um veredito
VEREDITOS = ("node-despachada", "node-sombra", "node-sem-vaga", "node-sem-etiqueta", "mini", "nao-sei")
NODE_CATS = ("node-despachada", "node-sombra", "node-sem-vaga", "node-sem-etiqueta")
# rc 12 do despachante que é "o nó está cheio" (o classificador disse node); os outros rc 12 (bead não livre, corrida perdida) não são capacidade
SEM_VAGA = ("slot-ocupado", "slot-sem-alias-livre", "sessao-viva", "oraculo-local", "oraculo-sem-vaga")
ROTULOS = {
    "node-despachada": "node, atribuída ao nó", "node-sombra": "node, só sombra (shadow/dry-run)", "node-sem-vaga": "node, mas sem vaga no nó",
    "node-sem-etiqueta": "node pelo classificador, sem a etiqueta node:ok", "mini": "mini", "nao-sei": "não sei (o classificador recusa)",
    "nao-elegivel": "não elegível", "nao-li": "não li", "falha-escrita": "escrita falhou (rc 13)", "outro": "outro (rc ou saída fora do formato)",
}
# o `check` do despachante devolve um par COERENTE (classify_checked): rc 0 só com verdict node, 10 só com mini, 11 só com unknown
SHADOW_PAR = {0: ("node", "node-sombra"), 10: ("mini", "mini"), 11: ("unknown", "nao-sei")}
# os `event` que o despachante e o Pilot gravam em wa-node-route.jsonl; qualquer outro é evento DESCONHECIDO (formato novo?): contado e dito, nunca só somado em "linhas na janela"
EVENTOS_ROTA = ("apply", "release", "read", "classify", "pilot-node-route")


def num(x):
    """número finito ou None: bool e NaN/inf não são número"""
    if isinstance(x, bool) or not isinstance(x, (int, float)):
        return None
    return float(x) if math.isfinite(x) else None


def read_jsonl(path):
    """(estado, linhas, ilegiveis). ausente → ('ausente'): ainda não houve rodada, NÃO é zero; falhou ao abrir/ler → ('ilegivel'): nunca vira vazio;
    vazio → ('vazio'); só lixo → ('ilegivel'). Linha que não é um objeto JSON entra em `ilegiveis` (avisada), não some."""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        return "ausente", [], 0
    except OSError:
        return "ilegivel", [], 0
    rows, bad = [], 0
    for ln in raw.split(b"\n"):
        if not ln.strip():
            continue
        try:
            o = json.loads(ln.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            bad += 1
            continue
        if isinstance(o, dict):
            rows.append(o)
        else:
            bad += 1
    if not rows and bad:
        return "ilegivel", [], bad
    return ("ok" if rows else "vazio"), rows, bad


def route_epoch(r):
    ts = r.get("ts")
    if not isinstance(ts, str) or not TS_RE.match(ts):
        return None
    try:
        return calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))
    except ValueError:
        return None


def cat_of(rc, detail):
    """o rc e o detalhe que o wa-node-dispatch.sh grava num `apply` → a categoria. Detalhe que não é um dos conhecidos NÃO vira um veredito vizinho: vai a 'outro'"""
    if rc == 0 and detail.startswith("dry-run:"):
        return "node-sombra"
    if rc == 0 and detail.startswith("despachada"):
        return "node-despachada"
    if rc == 10:
        # base=… é o node sem a etiqueta; "classificador:mini …" é o mini; o resto (texto novo, vazio) não é nem um nem outro
        return "node-sem-etiqueta" if detail.startswith("base=") else ("mini" if detail.startswith("classificador:mini") else "outro")
    if rc == 11:
        return "nao-sei" if detail.startswith("classificador:unknown") else "nao-li"
    if rc == 12:
        return "node-sem-vaga" if re.split(r"[ =:]", detail, maxsplit=1)[0] in SEM_VAGA else "nao-elegivel"
    if rc == 13:
        return "falha-escrita"
    return "outro"


def shadow_cat(rc, out):
    """(categoria, incoerente, base) de uma linha `pilot-node-route` do modo shadow: o rc do `check` e o `verdict` do JSON em `out`.
    Só o par coerente (0+node, 10+mini, 11+unknown) dá veredito. vazio → rc 11 sem saída é a bead que o despachante não leu ('nao-li', não 'não sei');
    falhou/ilegível → rc fora de 0/10/11 (prazo, sinal) é 'nao-li'; rc e veredito que discordam, ou saída que não é o JSON do classificador, é 'outro' + incoerente: nunca vira mini nem node."""
    v, base = None, None
    if isinstance(out, str) and out.strip():
        try:
            o = json.loads(out)
        except ValueError:
            o = None
        if isinstance(o, dict):
            v = o.get("verdict") if isinstance(o.get("verdict"), str) else None
            bs = o.get("basis")
            base = bs if isinstance(bs, str) and re.fullmatch(r"[A-Za-z0-9_-]+", bs) else None
    if rc not in SHADOW_PAR:
        return "nao-li", False, None
    esperado, cat = SHADOW_PAR[rc]
    if v == esperado:
        return cat, False, base if cat == "node-sombra" else None
    if rc == 11 and not (isinstance(out, str) and out.strip()):
        return "nao-li", False, None
    return "outro", True, None


def analyse_route(rows, lo, hi):
    ev, sem_hora = [], 0
    for i, r in enumerate(rows):
        e = route_epoch(r)
        if e is None:
            sem_hora += 1
        elif lo <= e <= hi:
            ev.append((e, i, r))
    ev.sort(key=lambda t: (t[0], t[1]))
    beads, modos, decisoes = {}, {}, 0
    apply_ilegivel = outras_ilegiveis = soltas = leitura_falhou = pilot_linhas = 0
    pilot_last, dec_ts, ver_ts = {}, [], []
    desconhecidos = {}
    for e, _i, r in ev:
        bid, kind = r.get("bead"), r.get("event")
        # vazio → sem `event` também é desconhecido ('?'); falhou/ilegível → `event` que não é um dos 5 conhecidos (ou nem é texto): não vira bead, não vira decisão, mas CONTA aqui e aparece no texto
        if kind not in EVENTOS_ROTA:
            nome = kind if isinstance(kind, str) and kind else "?"
            desconhecidos[nome] = desconhecidos.get(nome, 0) + 1
            continue
        if not isinstance(bid, str) or not bid:
            # sem bead: um `apply` assim é uma decisão perdida; o resto (read/classify/release/pilot) é linha sem dono. As duas contam, separadas
            if kind == "apply":
                apply_ilegivel += 1
            else:
                outras_ilegiveis += 1
            continue
        b = beads.setdefault(bid, {"cats": [], "razoes": None, "base": None, "despachada": False, "ultimo_rc": None, "incerta": False, "incoerente": False})
        rc = r.get("rc")
        rc_ok = isinstance(rc, int) and not isinstance(rc, bool)
        if kind == "apply":
            det = r.get("detail")
            if not rc_ok or not isinstance(det, str):
                apply_ilegivel += 1
                continue
            decisoes += 1
            dec_ts.append(e)
            c = cat_of(rc, det)
            if c in VEREDITOS:
                ver_ts.append(e)
            b["cats"].append(c)
            b["ultimo_rc"] = rc
            if c == "node-despachada":
                b["despachada"] = True
                b["incerta"] = False
            # rc 13 = o estado da escrita é incerto (prazo, bd fora, releitura que falhou): só "conferencia-falhou-desfeito" releu e provou que nada nosso sobrou
            if rc == 13 and not det.startswith("conferencia-falhou-desfeito"):
                b["incerta"] = True
            m = None
            if c in ("node-sombra", "node-despachada"):
                m = re.match(r"(?:dry-run: iria para|despachada para) \S+ \(([A-Za-z0-9_-]+)\)", det)
            elif c == "node-sem-etiqueta":
                m = re.match(r"base=([A-Za-z0-9_-]+)", det)
            if m:
                b["base"] = m.group(1)
        elif kind == "release":
            # 0 = solta (releu e conferiu); 12 = não era do nó (nada escrito); 13 = a soltura pode ou não ter pegado: a bead segue na lista de conferência até uma soltura/despacho confirmar
            if not rc_ok:
                outras_ilegiveis += 1
            elif rc == 0:
                soltas += 1
                b["incerta"] = False
            elif rc == 13:
                b["incerta"] = True
        elif kind in ("read", "classify"):
            leitura_falhou += 1
        elif kind == "pilot-node-route":
            mo = r.get("mode") if isinstance(r.get("mode"), str) else "?"
            modos[mo] = modos.get(mo, 0) + 1
            if not rc_ok:
                outras_ilegiveis += 1
                continue
            pilot_linhas += 1
            dec_ts.append(e)
            pilot_last = {"ts": e, "mode": mo, "rc": rc}
            out = r.get("out")
            if mo == "shadow":
                # shadow: o Pilot só roda o `check` e NÃO grava `apply`; esta linha É a decisão. Em label/auto o veredito é a linha `apply` do despachante (não se conta duas vezes)
                decisoes += 1
                c, inco, base = shadow_cat(rc, out)
                if c in VEREDITOS:
                    ver_ts.append(e)
                b["cats"].append(c)
                b["ultimo_rc"] = rc
                if inco:
                    b["incoerente"] = True
                if base:
                    b["base"] = base
            elif rc == 13 or rc >= 124:
                # label/auto: o `apply` morto por prazo/sinal (124, 137, 143, 128+n) não deixa linha própria, e a escrita pode ter pegado (o Pilot segura a bead por isso)
                b["incerta"] = True
            # vazio ('') → sem razões; texto que não é JSON ou sem `reasons` em lista → sem razões (a conferência humana lê a bead): nunca inventa
            if rc == 0 and isinstance(out, str) and out.strip():
                try:
                    o = json.loads(out)
                    rs = o.get("reasons") if isinstance(o, dict) else None
                    if isinstance(rs, list):
                        b["razoes"] = [str(x) for x in rs][:6]
                except ValueError:
                    pass
    final, instaveis = {k: 0 for k in VEREDITOS}, []
    outros = {}
    for bid, b in beads.items():
        vs = [c for c in b["cats"] if c in VEREDITOS]
        if vs:
            b["final"] = vs[-1]
            final[vs[-1]] += 1
            if any(c in NODE_CATS for c in vs) and any(c in ("mini", "nao-sei") for c in vs):
                instaveis.append(bid)
        elif b["cats"]:
            b["final"] = b["cats"][-1]
            outros[b["final"]] = outros.get(b["final"], 0) + 1
        else:
            b["final"] = None
    com_veredito = sum(1 for b in beads.values() if any(c in VEREDITOS for c in b["cats"]))
    # a lista de conferência = todo node da janela + toda bead cujo estado a máquina não soube dizer (escrita incerta, rc e veredito que discordam): listar a mais é o lado seguro
    node_lista = sorted(bid for bid, b in beads.items() if any(c in NODE_CATS for c in b["cats"]) or b["incerta"] or b["incoerente"])
    # cobertura = horas UTC COM VEREDITO (linha que deu node/mini/não sei); hora só com "não li"/"não elegível"/"falha de escrita" é hora em que a sombra rodou e NÃO disse nada: não conta, e a contagem larga vai à parte
    horas_dado = len({time.strftime("%Y-%m-%dT%H", time.gmtime(t)) for t in ver_ts})
    horas_decisao = len({time.strftime("%Y-%m-%dT%H", time.gmtime(t)) for t in dec_ts})
    lacuna = max((y - x for x, y in zip(ver_ts, ver_ts[1:])), default=0)
    avisos = []
    if pilot_linhas and not com_veredito:
        avisos.append("o Pilot gravou %d linha(s) e NENHUMA deu veredito (rc ou saída fora do formato do `check`?): este relatório não vale até isso ser explicado" % pilot_linhas)
    return {
        "linhas_na_janela": len(ev), "sem_hora": sem_hora, "primeira": ev[0][0] if ev else None, "ultima": ev[-1][0] if ev else None,
        "horas_cobertas": horas_dado, "horas_com_decisao": horas_decisao, "eventos_desconhecidos": desconhecidos, "intervalo_h": round((ev[-1][0] - ev[0][0]) / 3600.0, 2) if ev else 0.0, "maior_lacuna_h": round(lacuna / 3600.0, 2),
        "decisoes": decisoes, "beads_distintas": sum(1 for b in beads.values() if b["cats"]), "beads_com_veredito": com_veredito, "modos": modos, "pilot_ultimo": pilot_last,
        "pilot_linhas": pilot_linhas, "veredito_final": final, "fora_do_veredito": outros, "apply_ilegivel": apply_ilegivel, "outras_ilegiveis": outras_ilegiveis,
        "leituras_que_falharam": leitura_falhou, "soltas": soltas, "avisos": avisos,
        "ao_no_de_verdade": sorted(bid for bid, b in beads.items() if b["despachada"]), "instaveis": sorted(instaveis),
        "escrita_nao_confirmada": sorted(bid for bid, b in beads.items() if b["incerta"]), "incoerentes": sorted(bid for bid, b in beads.items() if b["incoerente"]),
        # base e razões vêm do ÚLTIMO node da bead; se ela teve node e o veredito final já não é node (node e depois mini), elas são do node ANTERIOR, e `do_node_anterior` diz isso (bead que nunca foi node não tem o que rotular)
        "node_para_conferir": [{"bead": bid, "ultimo": beads[bid]["final"], "base": beads[bid]["base"], "razoes": beads[bid]["razoes"], "do_node_anterior": beads[bid]["final"] not in NODE_CATS and any(c in NODE_CATS for c in beads[bid]["cats"]),
                                "escrita_nao_confirmada": beads[bid]["incerta"], "incoerente": beads[bid]["incoerente"]} for bid in node_lista],
    }


def analyse_occ(rows, lo, hi, busy_pct):
    horas, sem_epoch, total = {}, 0, 0
    cpu_ok = cpu_sem = sess_lida = sess_nao = sess_ileg = wa_leituras = 0
    soma_pct = 0.0
    perto = 0
    eventos, sem_forma = {}, 0
    for r in rows:
        ep = num(r.get("epoch"))
        if ep is None:
            sem_epoch += 1
            continue
        if not (lo <= ep <= hi):
            continue
        # O arquivo é compartilhado: o reaper grava nele {"ts","epoch","tipo":"reaper",…} (hetzner-idle-session-reaper.py), sem cpu nem sessoes. Isso NÃO é uma rodada do vigia.
        # Toda rodada do vigia traz as chaves `cpu` e `sessoes` (hetzner-occupancy-watch.py, o `rd`), mesmo quando a leitura falhou (cpu.lido=false): vazio → a chave existe e o conteúdo não presta = leitura que falhou, e
        # conta abaixo como "SEM CPU lida"/"sem sessões lidas"; falhou/ilegível → linha com `tipo`, ou sem cpu NEM sessoes, não é leitura: fica fora de leituras/hora/sem-CPU, mas é CONTADA à parte e dita no texto (nunca em silêncio, nunca como CPU não lida).
        if "tipo" in r:
            tp = r.get("tipo")
            tp = tp if isinstance(tp, str) and tp else "?"
            eventos[tp] = eventos.get(tp, 0) + 1
            continue
        if "cpu" not in r and "sessoes" not in r:
            sem_forma += 1
            continue
        total += 1
        key = time.strftime("%Y-%m-%dT%H:00Z", time.gmtime(ep))
        h = horas.setdefault(key, {"leituras": 0, "cpu_lidas": 0, "cpu_sem": 0, "soma_pct": 0.0, "min": None, "max": None, "soma_nuc": 0.0, "sess_lidas": 0, "soma_wa": 0, "com_wa": 0})
        h["leituras"] += 1
        cpu = r.get("cpu")
        # cpu ausente/ilegível, lido=false (1ª leitura, ssh falhou) ou % fora de 0..100 → "sem CPU lida", NUNCA 0%
        pct = num(cpu.get("pct")) if isinstance(cpu, dict) and cpu.get("lido") is True else None
        nuc = num(cpu.get("nucleos")) if pct is not None else None
        if pct is None or nuc is None or not (0.0 <= pct <= 100.0) or nuc < 0:
            h["cpu_sem"] += 1
            cpu_sem += 1
        else:
            h["cpu_lidas"] += 1
            h["soma_pct"] += pct
            h["soma_nuc"] += nuc
            h["min"] = pct if h["min"] is None else min(h["min"], pct)
            h["max"] = pct if h["max"] is None else max(h["max"], pct)
            cpu_ok += 1
            soma_pct += pct
            if pct >= busy_pct:
                perto += 1
        ss = r.get("sessoes")
        nomes = ss.get("nomes") if isinstance(ss, dict) and ss.get("lido") is True else None
        ileg = ss.get("ilegiveis") if isinstance(ss, dict) else None
        # `ilegiveis` ausente ou 0 = a lista é inteira; qualquer outra coisa (N>0, ou um valor que não é inteiro) = o watch viu entrada/estado que não leu, e a que não leu pode ser um WA
        lista_inteira = ileg is None or (isinstance(ileg, int) and not isinstance(ileg, bool) and ileg == 0)
        # sessões não lidas (lido=false, lista que não é lista de texto) ou lidas pela metade (`ilegiveis`) → não entram na média de WA: "0 sessões" seria mentira
        if isinstance(nomes, list) and not lista_inteira:
            sess_nao += 1
            sess_ileg += 1
        elif isinstance(nomes, list) and all(isinstance(n, str) for n in nomes):
            wa = sum(1 for n in nomes if n.startswith("wa-worker-remote"))
            h["sess_lidas"] += 1
            h["soma_wa"] += wa
            sess_lida += 1
            if wa:
                h["com_wa"] += 1
                wa_leituras += 1
        else:
            sess_nao += 1
    tabela = []
    for k in sorted(horas):
        h = horas[k]
        tabela.append({
            "hora": k, "leituras": h["leituras"], "cpu_lidas": h["cpu_lidas"], "cpu_sem": h["cpu_sem"],
            "pct_medio": round(h["soma_pct"] / h["cpu_lidas"], 1) if h["cpu_lidas"] else None, "pct_min": h["min"], "pct_max": h["max"],
            "nucleos_medio": round(h["soma_nuc"] / h["cpu_lidas"], 2) if h["cpu_lidas"] else None,
            "wa_medio": round(h["soma_wa"] / h["sess_lidas"], 2) if h["sess_lidas"] else None,
        })
    return {
        "leituras": total, "sem_epoch": sem_epoch, "eventos_que_nao_sao_leitura": eventos, "linhas_sem_forma_de_leitura": sem_forma, "cpu_lidas": cpu_ok, "cpu_sem_leitura": cpu_sem,
        "pct_medio": round(soma_pct / cpu_ok, 1) if cpu_ok else None, "perto_de_100": perto, "busy_pct": busy_pct,
        "perto_de_100_pct": round(100.0 * perto / cpu_ok, 1) if cpu_ok else None,
        "sessoes_lidas": sess_lida, "sessoes_nao_lidas": sess_nao, "sessoes_com_entrada_ilegivel": sess_ileg, "leituras_com_wa_no_no": wa_leituras, "horas": tabela,
    }


def prontidao(rota, min_hours, min_beads, hours):
    """horas = horas UTC COM VEREDITO (não o intervalo primeira→última, nem hora só de "não li"/"não elegível"); beads = só as que chegaram a um VEREDITO (não elegível/não li/falha de escrita não contam)"""
    falta = []
    if min_hours > hours + 1:
        # uma janela de `hours` h toca no máximo hours+1 horas UTC: pedir mais é pedir o impossível, e isso não pode parecer "ainda não deu tempo"
        falta.append("--min-hours %d não cabe na janela de %d h (no máximo %d hora(s) UTC): aumente --hours" % (min_hours, hours, hours + 1))
    elif rota["horas_cobertas"] < min_hours:
        falta.append("a sombra tem veredito em %d hora(s) UTC de %d" % (rota["horas_cobertas"], min_hours))
    if rota["beads_com_veredito"] < min_beads:
        falta.append("%d bead(s) com veredito de %d" % (rota["beads_com_veredito"], min_beads))
    return {"suficiente_para_revisar": not falta, "falta": falta, "a_conferir": len(rota["node_para_conferir"]), "instaveis": len(rota["instaveis"]),
            "escrita_nao_confirmada": len(rota["escrita_nao_confirmada"]), "incoerentes": len(rota["incoerentes"])}


def fnum(x, nd=1):
    """número em pt-BR com casas fixas; None (não li) → '—', nunca 0"""
    return "—" if x is None else (("%." + str(nd) + "f") % x).replace(".", ",")


def iso(e):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(e)) if e is not None else "—"


def estado_txt(est, bad, caminho):
    base = {"ausente": "AUSENTE (%s): ainda não houve rodada, isto NÃO é zero" % caminho, "ilegivel": "ILEGÍVEL (%s): não dá para dizer nada daqui" % caminho,
            "vazio": "vazio (%s): nenhuma linha ainda" % caminho, "ok": ""}[est]
    if bad and est != "ilegivel":
        base = (base + "; " if base else "") + "%d linha(s) ilegível(is), contadas e fora das contas" % bad
    return base


def render(res):
    L = []
    w = res["janela"]
    L.append("wa-node-report — janela de %s h, até %s" % (w["horas"], iso(w["fim"])))
    L.append("")
    L.append("[1] ROTA E SOMBRA (%s)" % res["rota"]["arquivo"])
    r = res["rota"]
    aviso = estado_txt(r["estado"], r["ilegiveis"], r["arquivo"])
    if aviso:
        L.append("  " + aviso)
    if r["estado"] in ("ok",):
        a = r["analise"]
        L.append("  cobertura: %s → %s; veredito em %d hora(s) UTC (decisão de qualquer tipo em %d; intervalo de %s h, maior silêncio entre vereditos %s h), %d linha(s) na janela, %d sem hora legível" % (iso(a["primeira"]), iso(a["ultima"]), a["horas_cobertas"], a["horas_com_decisao"], fnum(a["intervalo_h"], 2), fnum(a["maior_lacuna_h"], 2), a["linhas_na_janela"], a["sem_hora"]))
        pl = a["pilot_ultimo"]
        L.append("  modos do Pilot vistos: %s; última linha do Pilot: %s" % (", ".join("%s=%d" % kv for kv in sorted(a["modos"].items())) or "nenhum", ("%s, modo %s, rc %s" % (iso(pl["ts"]), pl["mode"], pl["rc"])) if pl else "—"))
        for av in a["avisos"]:
            L.append("  ATENÇÃO — " + av)
        if a["eventos_desconhecidos"]:
            L.append("  ATENÇÃO — %d linha(s) de evento que este relatório não conhece, FORA das contas (%s): o formato do log mudou?" % (sum(a["eventos_desconhecidos"].values()), ", ".join("%s=%d" % kv for kv in sorted(a["eventos_desconhecidos"].items()))))
        L.append("  %d decisão(ões) do despachante sobre %d bead(s) distinta(s); veredito = o ÚLTIMO da bead na janela:" % (a["decisoes"], a["beads_distintas"]))
        for c in VEREDITOS:
            L.append("    %-52s %d" % (ROTULOS[c], a["veredito_final"][c]))
        if a["fora_do_veredito"]:
            L.append("    sem veredito (não elegível / não li / falha de escrita): %s" % ", ".join("%s=%d" % kv for kv in sorted(a["fora_do_veredito"].items())))
        if a["apply_ilegivel"] or a["outras_ilegiveis"] or a["leituras_que_falharam"]:
            L.append("    linhas ilegíveis: apply %d, outras (sem bead ou sem rc) %d; leituras de bead que falharam: %d (a sonda do disk floor entra aqui)" % (a["apply_ilegivel"], a["outras_ilegiveis"], a["leituras_que_falharam"]))
        L.append("  WhatsApp ao nó DE VERDADE (atribuída pelo despachante): %d bead(s)%s; soltas depois da entrega: %d" % (len(a["ao_no_de_verdade"]), (" — " + ", ".join(a["ao_no_de_verdade"][:12])) if a["ao_no_de_verdade"] else "", a["soltas"]))
        if a["instaveis"]:
            L.append("  ATENÇÃO — mudaram de veredito (node e depois mini/não sei; é onde mora o falso 'node'): %s" % ", ".join(a["instaveis"]))
        if a["escrita_nao_confirmada"]:
            L.append("  ESCRITA NÃO CONFIRMADA — confira à mão se a bead está no nó (rc 13 do despachante, ou o Pilot que estourou o prazo): %s" % ", ".join(a["escrita_nao_confirmada"]))
        if a["incoerentes"]:
            L.append("  ATENÇÃO — linha do Pilot cujo rc e veredito discordam (o `check` não devolve isso; o formato mudou?). Não contam como mini nem como node: %s" % ", ".join(a["incoerentes"]))
        if a["node_para_conferir"]:
            L.append("  PARA CONFERIR UMA A UMA (todo veredito node da janela, mais as de escrita não confirmada e as incoerentes; nenhuma pode tocar dado de lead):")
            for n in a["node_para_conferir"][:40]:
                marca = (" ESCRITA NÃO CONFIRMADA" if n["escrita_nao_confirmada"] else "") + (" INCOERENTE" if n["incoerente"] else "")
                ant = " do node anterior" if n["do_node_anterior"] else ""
                L.append("    %s  [%s%s]%s  %s" % (n["bead"], ROTULOS.get(n["ultimo"], n["ultimo"] or "—"), (", base " + n["base"] + ant) if n["base"] else "", marca, ("razões" + ant + ": " + "; ".join(n["razoes"])) if n["razoes"] else "razões: —"))
            if len(a["node_para_conferir"]) > 40:
                L.append("    … mais %d (use --json)" % (len(a["node_para_conferir"]) - 40))
    L.append("")
    L.append("[2] CPU DO NÓ POR HORA, UTC (%s) — média das leituras de cada hora (uma leitura vale uma; a fronteira da hora é a do `epoch`, ±15 min)" % res["ocupacao"]["arquivo"])
    o = res["ocupacao"]
    aviso = estado_txt(o["estado"], o["ilegiveis"], o["arquivo"])
    if aviso:
        L.append("  " + aviso)
    if o["estado"] == "ok":
        b = o["analise"]
        L.append("  %d leitura(s) na janela (esperadas ~%d, uma a cada 15 min); CPU lida em %d, SEM CPU lida em %d (a 1ª leitura só semeia o baseline; não entram na média)" % (b["leituras"], res["janela"]["horas"] * 4, b["cpu_lidas"], b["cpu_sem_leitura"]))
        # vazio → nenhuma linha estranha, nada a dizer; N>0 → linhas que NÃO são leitura do vigia (o reaper grava no mesmo arquivo) ou sem `epoch`: ficaram fora das contas acima, e aqui está quantas
        fora = sum(b["eventos_que_nao_sao_leitura"].values()) + b["linhas_sem_forma_de_leitura"] + b["sem_epoch"]
        if fora:
            partes = ["%s=%d" % kv for kv in sorted(b["eventos_que_nao_sao_leitura"].items())]
            if b["linhas_sem_forma_de_leitura"]:
                partes.append("sem cpu nem sessões=%d" % b["linhas_sem_forma_de_leitura"])
            if b["sem_epoch"]:
                partes.append("sem epoch legível=%d" % b["sem_epoch"])
            L.append("  %d linha(s) que NÃO são leitura do vigia, FORA das contas acima (%s)" % (fora, ", ".join(partes)))
        L.append("  META (Athos 20/10): nó em ~100%%. Média da janela: %s%%; leituras com CPU >= %d%%: %d de %d (%s%%)" % (fnum(b["pct_medio"]), b["busy_pct"], b["perto_de_100"], b["cpu_lidas"], fnum(b["perto_de_100_pct"])))
        # vazio → nada a avisar (nenhuma leitura de sessões veio pela metade); N>0 → a lista daquelas leituras pode ter perdido um WA e elas ficam fora da conta
        sufixo = (", %d delas com entrada ilegível: a lista pode estar incompleta e não entra na conta" % b["sessoes_com_entrada_ilegivel"]) if b["sessoes_com_entrada_ilegivel"] else ""
        L.append("  sessões wa-worker-remote vivas em %d leitura(s) (de %d com sessões lidas; %d sem sessões lidas%s)" % (b["leituras_com_wa_no_no"], b["sessoes_lidas"], b["sessoes_nao_lidas"], sufixo))
        L.append("  %-14s %9s %8s %8s %6s %6s %8s %6s" % ("hora", "leituras", "cpu lida", "média %", "mín", "máx", "núcleos", "WA"))
        tab = b["horas"]
        if len(tab) > 72:
            L.append("  (%d hora(s) mais antigas omitidas aqui; --json traz todas)" % (len(tab) - 72))
            tab = tab[-72:]
        for h in tab:
            L.append("  %-14s %9d %8d %8s %6s %6s %8s %6s" % (h["hora"], h["leituras"], h["cpu_lidas"], fnum(h["pct_medio"]), fnum(h["pct_min"]), fnum(h["pct_max"]), fnum(h["nucleos_medio"], 2), fnum(h["wa_medio"], 2)))
    L.append("")
    p = res["prontidao"]
    L.append("[3] PRONTIDÃO DA SOMBRA PARA REVISAR O `auto` (mecânica; NÃO é aprovação)")
    if p is None:
        L.append("  sem log de rota utilizável (ausente ou ilegível): não dá para dizer")
    elif p["suficiente_para_revisar"]:
        extra = ("; %d mudaram de veredito" % p["instaveis"] if p["instaveis"] else "") + ("; %d com escrita não confirmada" % p["escrita_nao_confirmada"] if p["escrita_nao_confirmada"] else "") + ("; %d com rc/veredito incoerentes" % p["incoerentes"] if p["incoerentes"] else "")
        L.append("  base suficiente PARA REVISAR: confira as %d bead(s) da lista acima%s. Quem liga o auto é uma pessoa." % (p["a_conferir"], extra))
    else:
        L.append("  INSUFICIENTE: " + "; ".join(p["falta"]) + ". Não ligue o `auto` com isto.")
    return "\n".join(L) + "\n"


def parse_args(argv):
    ap = argparse.ArgumentParser(prog="wa-node-report.py", add_help=True)
    ap.add_argument("--hours", default="48")
    ap.add_argument("--city", default=None)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--min-hours", default="24")
    ap.add_argument("--min-beads", default="30")
    ap.add_argument("--busy-pct", default="90")
    a = ap.parse_args(argv)
    # vazio ou fora de 'dígitos' → uso errado (rc 2), nunca um padrão silencioso; decimal mesmo com zero à esquerda
    for nome, v, lo_, hi_ in (("--hours", a.hours, 1, 99999), ("--min-hours", a.min_hours, 0, 99999), ("--min-beads", a.min_beads, 0, 99999), ("--busy-pct", a.busy_pct, 1, 100)):
        if not re.fullmatch(r"[0-9]{1,6}", v or "") or not (lo_ <= int(v, 10) <= hi_):
            sys.stderr.write("wa-node-report: %s quer um inteiro de %d a %d (veio '%s')\n" % (nome, lo_, hi_, v))
            sys.exit(2)
    a.hours, a.min_hours, a.min_beads, a.busy_pct = int(a.hours, 10), int(a.min_hours, 10), int(a.min_beads, 10), int(a.busy_pct, 10)
    return a


def main(argv):
    a = parse_args(argv)
    for fl in (sys.stdout, sys.stderr):
        try:
            fl.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError, OSError):
            pass
    city = a.city or os.environ.get("GC_CITY_PATH") or DEFAULT_CITY
    # vazio → a hora de agora; ilegível (não é um inteiro) → uso errado, rc 2: um relógio falso mudaria a janela sem aviso
    now_env = os.environ.get("WA_NODE_REPORT_NOW", "")
    if now_env and not re.fullmatch(r"[0-9]{1,12}", now_env):
        sys.stderr.write("wa-node-report: WA_NODE_REPORT_NOW quer segundos desde 1970 (veio '%s')\n" % now_env)
        return 2
    now = int(now_env, 10) if now_env else int(time.time())
    lo, hi = now - a.hours * 3600, now
    rota_p, occ_p = os.path.join(city, ".gc", "wa-node-route.jsonl"), os.path.join(city, ".gc", "hetzner-occupancy.jsonl")
    re_, rrows, rbad = read_jsonl(rota_p)
    oe, orows, obad = read_jsonl(occ_p)
    ra = analyse_route(rrows, lo, hi) if re_ in ("ok", "vazio") else None
    oa = analyse_occ(orows, lo, hi, a.busy_pct) if oe in ("ok", "vazio") else None
    res = {
        "janela": {"horas": a.hours, "inicio": lo, "fim": hi},
        "rota": {"arquivo": rota_p, "estado": re_, "ilegiveis": rbad, "analise": ra},
        "ocupacao": {"arquivo": occ_p, "estado": oe, "ilegiveis": obad, "analise": oa},
        "prontidao": prontidao(ra, a.min_hours, a.min_beads, a.hours) if ra else None,
    }
    try:
        corpo = (json.dumps(res, ensure_ascii=False, sort_keys=True) + "\n") if a.json else render(res)
    except Exception as e:  # relatório que não se formou NUNCA sai pela metade como se estivesse completo
        sys.stderr.write("wa-node-report: ALERTA relatório não formado: %s\n" % e)
        return 4
    sys.stdout.write(corpo)
    if re_ not in ("ok", "vazio") and oe not in ("ok", "vazio"):
        sys.stderr.write("wa-node-report: nenhum dos dois logs deu para usar\n")
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
