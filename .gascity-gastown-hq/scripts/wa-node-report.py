#!/usr/bin/env python3
"""wa-node-report.py — o WhatsApp foi mesmo ao nó, e o nó ficou ocupado? A prova do dia seguinte da ga-2hd02v.3. SÓ LEITURA.

Contents
  Para quê · Uso · O que diz · Estados que não se confundem · O que NÃO diz

PARA QUÊ (Athos 20/10: "o que não pode é ficar menos do que 100% ocupado"): responder em um comando as duas perguntas que decidem os próximos passos da ga-2hd02v.3 —
  (1) quantas beads de WhatsApp o Pilot mandou ao nó, e a sombra já tem base para ligar `PILOT_WA_NODE_ROUTE=auto`? (2) quanto da CPU do nó foi usada, hora a hora?
USO      wa-node-report.py [--hours N] [--city DIR] [--json] [--min-hours H] [--min-beads B] [--busy-pct P] [--pilot-log ARQ] [--dispatchable ARQ] [--exempt-log ARQ]
         --hours N      janela, em horas, até agora (48; inteiro de 1 a 99999, "010" é dez)        --city DIR   a cidade (GC_CITY_PATH, senão /Users/athos/gt/.gascity-gastown-hq)
         --min-hours H  quantas HORAS UTC COM DADO bastam para REVISAR a flip para auto (24)        --min-beads B  quantas beads COM VEREDITO bastam (30)
         --busy-pct P   a partir de quantos % de CPU a leitura conta como "perto de 100%" (90)       --json       o mesmo em JSON
         --pilot-log    o log do Pilot (<cidade>/.gc/logs/pilot-dispatcher.log; o horário dele não traz fuso: é lido no fuso de quem roda, o mini)   --dispatchable  a fila (~/.gc/pilot-dispatchable.json)
         --exempt-log   o log da passada do nó (<cidade>/.gc/wa-node-exempt.jsonl: uma linha `wa-node-pass-probe` por sonda, com os motivos do classificador)
         (a janela padrão é 48 h porque 24 horas com dado numa janela de 24 h não deixam folga: ela toca 25 horas UTC no máximo, e uma hora sem veredito já reprova)
         exit 0 ok · 2 uso · 3 NENHUM dos dois logs deu para usar (ausente ou ilegível) · 4 relatório não formado
O QUE DIZ  1. a rota (<cidade>/.gc/wa-node-route.jsonl: o que o despachante e o Pilot gravam): cobertura da sombra (horas COM VEREDITO — node/mini/não sei —, não o intervalo entre a primeira e a última nem hora só de "não li"),
              o veredito de cada bead (o ÚLTIMO da janela), as que foram ao nó de verdade, as que o classificador mandou ao nó mas não couberam (sem vaga), as que mudaram de veredito,
              que é onde mora o falso "node", e as de ESCRITA NÃO CONFIRMADA (rc 13 do despachante, ou o Pilot que estourou o prazo), que o relatório lista para conferir à mão.
              No modo `shadow` o Pilot só roda o `check` do despachante e NÃO grava `apply`: o veredito vem da linha `pilot-node-route` (rc 0/10/11 + o `verdict` do JSON em `out`);
           2. o FUNIL de WA até o gancho do nó (medido em 20/10: 222 beads de WA na fila, 2 despachadas no dia, e as duas deram `mini`): quantas a cedência por prioridade e o teto do pool do mini
              seguraram ANTES do gancho (<cidade>/.gc/logs/pilot-dispatcher.log) e o tamanho da fila despachável (~/.gc/pilot-dispatchable.json). O nó só recebe o que chega ao gancho; é o primeiro limite do uso dele por WA;
           3. a CPU do nó por hora, em UTC (<cidade>/.gc/hetzner-occupancy.jsonl: uma leitura a cada 15 min do hetzner-occupancy-watch), a média, quantas leituras ficaram perto de 100%
              e quantas sessões wa-worker-remote estavam vivas;
           4. a prontidão MECÂNICA da sombra: horas e beads suficientes para alguém REVISAR. Não é aprovação: quem liga o `auto` é uma pessoa, depois de conferir uma a uma as beads `node` da lista;
           5. os MOTIVOS (ga-2hd02v.3.17: a passada de 05:39Z sondou 12 beads e mandou 0 ao nó, e o log só dizia "mini 5 · não sei 7"): de cada sonda da passada do Pilot (<cidade>/.gc/wa-node-exempt.jsonl),
              o veredito e a classe de cada motivo; a tabela motivo × contagem (beads pela ÚLTIMA sonda, sondas ao todo, até 3 exemplos) e o resumo das passadas (quantas, quantas sondas, quantas ao nó, por que pararam).
ESTADOS QUE NÃO SE CONFUNDEM  log ausente ("ainda não houve rodada") ≠ log vazio ≠ log ilegível ≠ zero decisões na janela. Linha que não dá para ler vem CONTADA e avisada, nunca omitida em
           silêncio. Linha de outro assunto no mesmo log (o `tipo:"reaper"` que o reaper grava em hetzner-occupancy.jsonl; um `event` que o despachante não conhece) não é leitura nem decisão: fica fora das contas e vem CONTADA. CPU que não foi lida (a 1ª leitura só semeia o baseline; o ssh falhou) NUNCA vira 0%: entra em "sem CPU lida". Sessões não lidas, ou lidas com entrada ilegível
           (`sessoes.ilegiveis`: a lista pode estar incompleta), não viram "0 sessões". Linha do Pilot cujo rc e `verdict` discordam NUNCA vira mini nem node: vai a "outro" e à lista de conferência.
           O log do Pilot, o da passada do nó e a fila têm os mesmos três estados (ausente / vazio / ilegível), e a fila que não é o objeto com `items` em lista é ilegível, nunca "0 candidatas". Sem o log de rota, "quantas chegaram ao gancho
           e quantas pararam antes" é NÃO SEI (null no JSON), nunca 0 e nunca "todas pararam". Nos motivos, `sem-motivo` (o classificador respondeu sem razão) ≠ `ilegivel` (a razão não foi lida) ≠ `sem-saida`
           (prazo/erro/script ausente: não houve resposta dele); sem NENHUMA sonda na janela o texto diz isso e não "zero motivos"; sonda sem bead/veredito conhecido e `event` desconhecido ficam FORA da tabela e CONTADOS.
O QUE NÃO DIZ  se um motivo é CERTO: "caminho-fora-do-filtro" pode ser mini legítimo (dado, credencial, só-no-mac) ou um falso mini; a tabela diz quantas e dá exemplos para ler à mão. Também não diz que nenhuma bead com dado de lead foi ao nó: o relatório não vê o conteúdo da bead. Lista as que foram (e por quê) para a conferência humana. A garantia de que dado de lead
           não chega ao nó é o espelho git com a varredura de CPF/telefone, não este relatório. Também não diz que o WA RODOU bem no nó: só que a bead foi atribuída lá.
           No funil, "sem NENHUMA linha na rota" não é "o nó nunca viu": o gancho sai sem gravar com PILOT_WA_NODE_ROUTE=off, quando a bead já é do nó ou não deu para relê-la (label/auto), quando o despachante não
           está executável e quando o orçamento de spawn do sweep acabou. Por isso o relatório diz o número com essas palavras e avisa quando o Pilot não gravou linha nenhuma na janela (`gancho_gravou`).
           O horário do log do Pilot não traz fuso: é lido no fuso de quem roda o relatório. Rodá-lo em outra máquina, ou com TZ diferente do mini, desloca a janela do funil (a da rota e da CPU é UTC).
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
# wa-node-exempt.jsonl (a passada do Pilot que manda WA ao nó, ga-2hd02v.3.17): `wa-node-pass-probe` é UMA sonda do classificador (veredito + motivos); o resumo e a sombra são da mesma passada e ficam FORA do agregado de motivos
EXEMPT_SONDA = "wa-node-pass-probe"
EXEMPT_CONHECIDOS = ("wa-node-pass-summary", "wa-node-pass-shadow")
# os vereditos que a sonda grava: os três do classificador (trazem motivos) e os três em que não houve saída dele (prazo, erro, script ausente)
SONDA_VEREDITOS = ("node", "mini", "unknown", "timeout", "error", "missing")
SONDA_CLASSIFICADOS = ("node", "mini", "unknown")
ABSENTE = object()  # a chave não existe na linha (≠ existe com null)
SONDA_ROTULOS = {"node": "node", "mini": "mini", "unknown": "não sei", "timeout": "prazo estourou (sem veredito)", "error": "erro (sem veredito)", "missing": "script ausente (sem veredito)"}


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
        # vazio → nenhuma bead com linha; falhou/ilegível → a linha com `rc` ilegível ou a leitura que falhou TAMBÉM entra: o funil quer "tem linha na rota" (o gancho rodou), não "tem veredito". Privado: main() tira antes do JSON
        "_beads": set(beads),
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


def sonda_tokens(verdict, classes):
    """as palavras "veredito:classe" de UMA sonda, as mesmas que o Pilot soma no resumo da passada. vazio (classes=[]: o classificador respondeu sem motivo) → "sem-motivo";
    falhou/ilegível (classes null, ou que não é lista de texto) → "ilegivel": "não li" NUNCA vira "sem motivo"; veredito sem saída do classificador (prazo, erro, script ausente) → "sem-saida"."""
    if verdict not in SONDA_CLASSIFICADOS:
        return [verdict + ":sem-saida"]
    if not isinstance(classes, list) or any(not isinstance(c, str) or not c.strip() for c in classes):
        return [verdict + ":ilegivel"]
    if not classes:
        return [verdict + ":sem-motivo"]
    return [verdict + ":" + c for c in sorted(set(classes))]


def analyse_motivos(rows, lo, hi):
    """motivo × contagem das sondas da passada do nó (wa-node-exempt.jsonl). Só `wa-node-pass-probe` na janela entra no agregado; o veredito de uma bead é a ÚLTIMA sonda dela na janela (a mesma regra da rota).
    `por_motivo[veredito:classe]` = {beads (pela última sonda), sondas (todas as da janela), exemplos (até 3 beads)}. Linha sem hora legível, sonda sem bead ou com veredito fora dos seis conhecidos NÃO entram no agregado e vêm
    CONTADAS (sem_hora, fora_do_formato); `event` desconhecido idem (eventos_desconhecidos); resumo e sombra da passada vêm contados à parte (outros_conhecidos), e o resumo dá `passadas`: quantas, o modo de cada uma, quantas SONDAS (a mesma bead é sondada de novo a cada varredura: o veredito `node` não é memorizado),
    em quantas sondas o veredito foi `node` (o que o classificador DISSE) e, à parte, o que FOI ao nó: `kept` (despacho que deu certo) e `released` (veredito node, despacho que falhou), por que pararam.
    `leitura` (só sonda CLASSIFICADA: node/mini/unknown) separa quatro estados do campo `leitura` da sonda: lista com entradas = a leitura FALHOU (`falhou`, por motivo em `por_slug`, até 3 `exemplos`); `[]` = leu tudo (não conta);
    null, texto ou item que não é texto = `ilegivel`; chave ausente (Pilot sem o campo) = `sem_campo`. Os dois últimos NUNCA viram "leu tudo": o relatório diz que não dá para saber."""
    sem_hora = fora_formato = 0
    ev = []
    for i, r in enumerate(rows):
        e = route_epoch(r)
        if e is None:
            sem_hora = sem_hora + 1
            continue
        if lo <= e <= hi:
            ev.append((e, i, r))
    ev.sort(key=lambda t: t[:2])
    ultima, sondas_tok, conhecidos, novos = {}, {}, {}, {}
    sondas = 0
    pas = {"n": 0, "sondadas": 0, "node": 0, "kept": 0, "released": 0, "parou_por": {}, "modos": {}, "sem_numero": 0, "sem_numero_acao": 0}
    leitura = {"falhou": 0, "por_slug": {}, "exemplos": [], "ilegivel": 0, "sem_campo": 0}
    for _e, _i, r in ev:
        kind = r.get("event")
        if kind == "wa-node-pass-summary":
            conhecidos[kind] = conhecidos.get(kind, 0) + 1
            pas["n"] += 1
            # vazio (campo ausente) e ilegível (texto, bool, negativo) são o mesmo aviso: a passada conta, mas o número dela NÃO entra na soma (nunca vira 0 em silêncio)
            pr, nd = r.get("probed"), r.get("node")
            if all(isinstance(x, int) and not isinstance(x, bool) and x >= 0 for x in (pr, nd)):
                pas["sondadas"] += pr
                pas["node"] += nd
            else:
                pas["sem_numero"] += 1
            # o que foi AO NÓ é `kept` (despacho que deu certo), nunca `node` (veredito: conta antes de qualquer despacho, e na sombra nada é despachado). kept e released andam juntos: sem os dois legíveis o
            # resumo inteiro fica FORA da conta de entregas e vem contado (nunca vira 0, nem entra só metade)
            kp, rl = r.get("kept"), r.get("released")
            if all(isinstance(x, int) and not isinstance(x, bool) and x >= 0 for x in (kp, rl)):
                pas["kept"] += kp
                pas["released"] += rl
            else:
                pas["sem_numero_acao"] += 1
            md = r.get("mode")
            md = md if isinstance(md, str) and md else "?"
            pas["modos"][md] = pas["modos"].get(md, 0) + 1
            st = r.get("stopped")
            st = st if isinstance(st, str) and st else "?"
            pas["parou_por"][st] = pas["parou_por"].get(st, 0) + 1
            continue
        if kind in EXEMPT_CONHECIDOS:
            conhecidos[kind] = conhecidos.get(kind, 0) + 1
            continue
        if kind != EXEMPT_SONDA:
            nome = kind if (isinstance(kind, str) and kind) else "?"
            novos[nome] = novos.get(nome, 0) + 1
            continue
        bid, v = r.get("bead"), r.get("verdict")
        if not isinstance(bid, str) or not bid or v not in SONDA_VEREDITOS:
            fora_formato += 1
            continue
        sondas += 1
        if v in SONDA_CLASSIFICADOS:
            lt = r.get("leitura", ABSENTE)
            if lt is ABSENTE:
                leitura["sem_campo"] += 1
            elif not isinstance(lt, list) or any(not isinstance(x, str) or not x for x in lt):
                leitura["ilegivel"] += 1
            elif lt:
                leitura["falhou"] += 1
                for slug in {x.split(":", 1)[0] for x in lt}:
                    leitura["por_slug"][slug] = leitura["por_slug"].get(slug, 0) + 1
                if bid not in leitura["exemplos"] and len(leitura["exemplos"]) < 3:
                    leitura["exemplos"].append(bid)
        toks = sonda_tokens(v, r.get("classes"))
        for t in toks:
            sondas_tok[t] = sondas_tok.get(t, 0) + 1
        ultima[bid] = (v, toks)
    por_veredito = {v: 0 for v in SONDA_VEREDITOS}
    por_motivo = {}
    for bid, (v, toks) in ultima.items():
        por_veredito[v] += 1
        for t in toks:
            m = por_motivo.setdefault(t, {"beads": 0, "sondas": 0, "exemplos": []})
            m["beads"] += 1
            if len(m["exemplos"]) < 3:
                m["exemplos"].append(bid)
    for t, n in sondas_tok.items():
        por_motivo.setdefault(t, {"beads": 0, "sondas": 0, "exemplos": []})["sondas"] = n
    return {"sondas": sondas, "beads": len(ultima), "por_veredito": por_veredito, "por_motivo": por_motivo, "passadas": pas, "leitura": leitura, "sem_hora": sem_hora,
            "fora_do_formato": fora_formato, "outros_conhecidos": conhecidos, "eventos_desconhecidos": novos}


# o log do Pilot: "[2026-10-20 15:50:54] [pilot-dispatcher] …". Só a bead de WA (id wa-…) entra; cada padrão é uma linha que o Pilot escreve ANTES do gancho do nó (ou no despacho ao mini)
LOG_TS = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] ")
# o id é `wa-` + base36 + sufixos `.N` (wa-hut4l5.4). O ponto final da frase ("Claim acquired on wa-qp98sy.") não é do id: com ele a mesma bead entraria duas vezes
WA_ID = r"(wa-[A-Za-z0-9]+(?:\.[0-9]+)*)"
FUNIL = (
    ("cedida", re.compile(r"ga-5fn5p3: " + WA_ID + r" P\d+ cedida a P0/P1 ")),
    ("teto", re.compile(r"ga-in9ebr: " + WA_ID + r" QUEUED — routed to wa-worker, pool at session cap")),
    ("teto", re.compile(r"ga-in9ebr: wa-worker pool at session cap \(.*?\) — QUEUED " + WA_ID + r": claim released")),
    ("claim", re.compile(r"Claim acquired on " + WA_ID)),
    ("mini", re.compile(r"RIG-NATIVE dispatch \([^)]*\): assigning " + WA_ID + r" → wa-worker ")),
)
FUNIL_ROTULOS = (
    ("cedida", "cedidas a P0/P1 (param ANTES do gancho do nó)"), ("teto", "paradas no teto do pool wa-worker do mini (idem)"),
    ("claim", "reivindicadas (claim)"), ("mini", "despachadas ao wa-worker do MINI"),
)
SWEEP_START = "=== Pilot sweep start"


def analyse_funil(path, lo, hi):
    """(estado, análise). ausente → ('ausente'): o Pilot ainda não escreveu, NÃO é zero; falhou ao ler → ('ilegivel'): nunca vira zero; vazio → ('vazio').
    Sem uma linha de WA na janela → zeros com estado ok (a resposta é "nenhuma"). A linha do funil cuja hora falta ou é impossível não entra nas contas e vem CONTADA em `sem_hora`;
    linha de continuação que não casa com nenhum padrão não é do funil e não conta. A hora do log não traz fuso: é lida no fuso de quem roda."""
    try:
        with open(path, "rb") as f:
            raw = f.read().decode("utf-8", "replace")
    except FileNotFoundError:
        return "ausente", None
    except OSError:
        return "ilegivel", None
    cats = {c: {"linhas": 0, "_beads": set()} for c, _ in FUNIL_ROTULOS}
    rodadas = sem_hora = 0
    for ln in raw.split("\n"):
        m = LOG_TS.match(ln)
        e = None
        if m:
            try:
                e = time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
            except (ValueError, OverflowError):
                e = None  # hora impossível (mês 13, 99:99): tratada como sem hora, abaixo
        hit = None
        if SWEEP_START not in ln:
            for c, rx in FUNIL:
                mm = rx.search(ln)
                if mm:
                    hit = (c, mm.group(1))
                    break
        if e is None:
            # sem hora legível: só conta se for uma linha DO FUNIL (padrão ou início de rodada); o resto do log (continuações, linhas de outros assuntos) não é assunto daqui
            if hit or SWEEP_START in ln:
                sem_hora += 1
            continue
        if not (lo <= e <= hi):
            continue
        if SWEEP_START in ln:
            rodadas += 1
        elif hit:
            cats[hit[0]]["linhas"] += 1
            cats[hit[0]]["_beads"].add(hit[1])
    return ("ok" if raw.strip() else "vazio"), {"rodadas": rodadas, "sem_hora": sem_hora, "categorias": cats}


def read_fila(path, now):
    """(estado, análise). ausente → ('ausente'); ilegível, ou JSON que não é o objeto com `items` em lista → ('ilegivel'): nunca vira '0 candidatas'.
    Item que não é objeto não é candidata de WA: fica fora de `wa` e vem CONTADO em `itens_ilegiveis`. `generated_at` ausente, no futuro ou impossível → idade None (não sei), nunca 0."""
    try:
        with open(path, "rb") as f:
            o = json.loads(f.read().decode("utf-8"))
    except FileNotFoundError:
        return "ausente", None
    except (OSError, ValueError):
        return "ilegivel", None
    if not isinstance(o, dict) or not isinstance(o.get("items"), list):
        return "ilegivel", None
    wa, prio, ileg = 0, {}, 0
    for it in o["items"]:
        if not isinstance(it, dict):
            ileg += 1
        elif it.get("store") == "whatsapp_automation":
            wa += 1
            k = str(it.get("priority", "?"))
            prio[k] = prio.get(k, 0) + 1
    g = o.get("generated_at")
    idade = None
    if isinstance(g, str) and TS_RE.match(g):
        try:
            idade = now - calendar.timegm(time.strptime(g, "%Y-%m-%dT%H:%M:%SZ"))
        except (ValueError, OverflowError):
            idade = None  # tem a forma de uma hora mas é impossível (mês 13): não sei a idade
        if idade is not None and idade < 0:  # gerada depois de "agora": o relógio de um dos dois está errado; não finge idade
            idade = None
    return "ok", {"wa": wa, "total": len(o["items"]), "itens_ilegiveis": ileg, "prioridades": prio, "idade_s": idade, "ttl_s": num(o.get("ttl_seconds"))}


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
    fu = res["funil"]
    L.append("[2] FUNIL DE WA ATÉ O GANCHO DO NÓ (%s)" % fu["arquivo"])
    aviso = estado_txt(fu["estado"], 0, fu["arquivo"])
    if aviso:
        L.append("  " + aviso)
    fi = res["fila"]
    aviso = estado_txt(fi["estado"], 0, fi["arquivo"])
    if aviso:
        L.append("  " + aviso)
    if fi["estado"] == "ok":
        q = fi["analise"]
        idade = "gerada há %s min%s" % (fnum(q["idade_s"] / 60.0, 0), "" if q["ttl_s"] is None or q["idade_s"] <= q["ttl_s"] else ", VENCIDA") if q["idade_s"] is not None else "sem hora de geração legível"
        extra = ("; %d item(ns) que não é(são) objeto, fora da conta de WA" % q["itens_ilegiveis"]) if q["itens_ilegiveis"] else ""
        L.append("  fila despachável: %d de WA entre %d (%s); por prioridade: %s%s" % (q["wa"], q["total"], idade, ", ".join("P%s=%d" % kv for kv in sorted(q["prioridades"].items())) or "—", extra))
    if fu["estado"] == "ok":
        a = fu["analise"]
        L.append("  %d rodada(s) do Pilot na janela (a hora do log é lida no fuso de quem roda). Beads de WA, na janela:" % a["rodadas"])
        for c, rot in FUNIL_ROTULOS:
            L.append("    %-52s %6d linha(s)  %4d bead(s)" % (rot, a["categorias"][c]["linhas"], a["categorias"][c]["beads"]))
        if a["sem_hora"]:
            L.append("  %d linha(s) do funil sem hora legível (ausente ou impossível), FORA das contas acima" % a["sem_hora"])
        if a["no_gancho"] is None:
            L.append("  quantas têm linha na rota e quantas pararam antes: NÃO SEI — o log de rota (seção 1) não foi lido, e sem ele não dá para dizer o que o gancho viu")
        else:
            L.append("    %-52s %6s           %4d bead(s)  (atribuídas ao nó: %d)" % ("com alguma linha na rota (o gancho gravou)", "", a["no_gancho"], a["ao_no"]))
            L.append("  cedidas ou no teto e SEM NENHUMA linha na rota: %d bead(s)" % a["pararam_antes"])
            if not a["gancho_gravou"]:
                L.append("  ATENÇÃO — o Pilot não gravou NENHUMA linha de rota na janela (PILOT_WA_NODE_ROUTE=off? gancho fora do ar?): 'sem linha na rota' não diz nada sobre o nó")
            else:
                L.append("  (sem linha na rota não prova que o nó não viu: o gancho sai sem gravar se a bead já é do nó ou não deu para relê-la, e se o despachante não está executável; confira os modos do Pilot na seção 1)")
    L.append("")
    L.append("[3] CPU DO NÓ POR HORA, UTC (%s) — média das leituras de cada hora (uma leitura vale uma; a fronteira da hora é a do `epoch`, ±15 min)" % res["ocupacao"]["arquivo"])
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
    L.append("[4] PRONTIDÃO DA SOMBRA PARA REVISAR O `auto` (mecânica; NÃO é aprovação)")
    if p is None:
        L.append("  sem log de rota utilizável (ausente ou ilegível): não dá para dizer")
    elif p["suficiente_para_revisar"]:
        extra = ("; %d mudaram de veredito" % p["instaveis"] if p["instaveis"] else "") + ("; %d com escrita não confirmada" % p["escrita_nao_confirmada"] if p["escrita_nao_confirmada"] else "") + ("; %d com rc/veredito incoerentes" % p["incoerentes"] if p["incoerentes"] else "")
        L.append("  base suficiente PARA REVISAR: confira as %d bead(s) da lista acima%s. Quem liga o auto é uma pessoa." % (p["a_conferir"], extra))
    else:
        L.append("  INSUFICIENTE: " + "; ".join(p["falta"]) + ". Não ligue o `auto` com isto.")
    L.append("")
    mo = res["motivos"]
    L.append("[5] MOTIVOS DAS SONDAS DA PASSADA DO NÓ (%s) — por que o classificador deu cada veredito (ga-2hd02v.3.17)" % mo["arquivo"])
    aviso = estado_txt(mo["estado"], mo["ilegiveis"], mo["arquivo"])
    if aviso:
        L.append("  " + aviso)
    if mo["estado"] == "ok":
        a = mo["analise"]
        pa = a["passadas"]
        L.append("  %d passada(s) com resumo na janela; pararam por: %s" % (pa["n"], ", ".join("%s=%d" % kv for kv in sorted(pa["parou_por"].items())) or "—"))
        if pa["n"]:
            L.append("  modo das passadas: %s" % ", ".join("%s=%d" % kv for kv in sorted(pa["modos"].items(), key=lambda kv: (-kv[1], kv[0]))))
            # nenhum resumo legível = NÃO SEI, nunca um 0 que pareça medida
            if pa["sem_numero"] < pa["n"]:
                L.append("  sondas: %d — a MESMA bead é sondada de novo a cada varredura (o veredito `node` não é memorizado), então isto NÃO é um número de beads" % pa["sondadas"])
                L.append("  veredito `node` em %d sonda(s) — o que o classificador DISSE, não o que foi ao nó" % pa["node"])
            else:
                L.append("  sondas e vereditos `node`: não dá para dizer (nenhum resumo com probed/node legível)")
            if pa["sem_numero_acao"] < pa["n"]:
                L.append("  ao nó de fato (despacho que deu certo): %d; soltas (veredito node, mas o despacho falhou): %d" % (pa["kept"], pa["released"]))
            else:
                L.append("  ao nó de fato: não dá para dizer (nenhum resumo com kept/released legível)")
            if pa["modos"].get("shadow"):
                L.append("  modo sombra em %d passada(s): nada é despachado, então 0 ao nó ali é o esperado — não prova que o nó não receberia" % pa["modos"]["shadow"])
        if pa["sem_numero"]:
            L.append("  ATENÇÃO — %d resumo(s) sem número legível (probed/node ausente ou fora do formato): contados como passada, FORA das somas" % pa["sem_numero"])
        if pa["sem_numero_acao"]:
            L.append("  ATENÇÃO — %d resumo(s) sem `kept`/`released` legíveis (ausente ou fora do formato): contados como passada, FORA da conta de entregas (nunca viram 0)" % pa["sem_numero_acao"])
        if not a["sondas"]:
            L.append("  nenhuma sonda `%s` na janela: a passada não gravou motivos (Pilot sem o ga-2hd02v.3.17, passada desligada ou memória de vereditos cobrindo tudo) — isto NÃO é 'zero motivos'" % EXEMPT_SONDA)
        else:
            L.append("  %d sonda(s) em %d bead(s) distinta(s); veredito da bead = a ÚLTIMA sonda dela na janela:" % (a["sondas"], a["beads"]))
            for v in SONDA_VEREDITOS:
                if a["por_veredito"][v]:
                    L.append("    %-52s %d" % (SONDA_ROTULOS[v], a["por_veredito"][v]))
            L.append("  motivo × contagem (uma bead conta em cada motivo que tem; `sem-motivo` = o classificador respondeu sem razão, `ilegivel` = a razão não foi lida, `sem-saida` = não houve saída dele):")
            L.append("    %-44s %6s %7s  %s" % ("veredito:motivo", "beads", "sondas", "exemplos"))
            for t, m in sorted(a["por_motivo"].items(), key=lambda kv: (-kv[1]["beads"], -kv[1]["sondas"], kv[0])):
                L.append("    %-44s %6d %7d  %s" % (t, m["beads"], m["sondas"], ", ".join(m["exemplos"]) or "—"))
        le = a["leitura"]
        if le["falhou"]:
            L.append("  ATENÇÃO — a leitura FALHOU em %d sonda(s) classificada(s) (%s): o veredito pode estar pior do que o certo (o que o classificador não leu, ele não pôde ver); exemplos: %s" % (le["falhou"], ", ".join("%s=%d" % kv for kv in sorted(le["por_slug"].items())), ", ".join(le["exemplos"])))
        if le["ilegivel"]:
            L.append("  ATENÇÃO — %d sonda(s) classificada(s) com o campo `leitura` ilegível (null ou fora do formato): não dá para dizer se a leitura falhou nelas" % le["ilegivel"])
        if le["sem_campo"]:
            L.append("  %d sonda(s) classificada(s) de um Pilot sem o campo `leitura`: não dá para dizer se a leitura falhou nelas" % le["sem_campo"])
        if a["sem_hora"] > 0:
            L.append("  %d linha(s) do log sem hora legível, FORA das contas acima" % a["sem_hora"])
        if a["fora_do_formato"]:
            L.append("  ATENÇÃO — %d sonda(s) sem bead ou com veredito que este relatório não conhece, FORA das contas acima: o formato mudou?" % a["fora_do_formato"])
        if len(a["eventos_desconhecidos"]) > 0:
            L.append("  ATENÇÃO — %d linha(s) de `event` que este relatório não conhece, FORA das contas (%s): o formato do log mudou?" % (sum(a["eventos_desconhecidos"].values()), ", ".join("%s=%d" % kv for kv in sorted(a["eventos_desconhecidos"].items()))))
    return "\n".join(L) + "\n"


def parse_args(argv):
    ap = argparse.ArgumentParser(prog="wa-node-report.py", add_help=True)
    ap.add_argument("--hours", default="48")
    ap.add_argument("--city", default=None)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--min-hours", default="24")
    ap.add_argument("--min-beads", default="30")
    ap.add_argument("--busy-pct", default="90")
    ap.add_argument("--pilot-log", default=None)
    ap.add_argument("--dispatchable", default=None)
    ap.add_argument("--exempt-log", default=None)
    a = ap.parse_args(argv)
    # vazio ou fora de 'dígitos' → uso errado (rc 2), nunca um padrão silencioso; decimal mesmo com zero à esquerda
    for nome, v, lo_, hi_ in (("--hours", a.hours, 1, 99999), ("--min-hours", a.min_hours, 0, 99999), ("--min-beads", a.min_beads, 0, 99999), ("--busy-pct", a.busy_pct, 1, 100)):
        if not re.fullmatch(r"[0-9]{1,6}", v or "") or not (lo_ <= int(v, 10) <= hi_):
            sys.stderr.write("wa-node-report: %s quer um inteiro de %d a %d (veio '%s')\n" % (nome, lo_, hi_, v))
            sys.exit(2)
    a.hours, a.min_hours, a.min_beads, a.busy_pct = int(a.hours, 10), int(a.min_hours, 10), int(a.min_beads, 10), int(a.busy_pct, 10)
    # ausente (None) → o caminho padrão; vazio ("") → uso errado, rc 2: um caminho em branco não pode virar "o padrão" em silêncio
    for nome, v in (("--pilot-log", a.pilot_log), ("--dispatchable", a.dispatchable), ("--exempt-log", a.exempt_log)):
        if v is not None and v == "":
            sys.stderr.write("wa-node-report: %s quer um caminho (veio vazio)\n" % nome)
            sys.exit(2)
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
    exe_p = a.exempt_log if a.exempt_log is not None else os.path.join(city, ".gc", "wa-node-exempt.jsonl")
    xe, xrows, xbad = read_jsonl(exe_p)
    ra = analyse_route(rrows, lo, hi) if re_ in ("ok", "vazio") else None
    xa = analyse_motivos(xrows, lo, hi) if xe in ("ok", "vazio") else None
    oa = analyse_occ(orows, lo, hi, a.busy_pct) if oe in ("ok", "vazio") else None
    log_p = a.pilot_log if a.pilot_log is not None else os.path.join(city, ".gc", "logs", "pilot-dispatcher.log")
    fila_p = a.dispatchable if a.dispatchable is not None else os.path.join(os.path.expanduser("~"), ".gc", "pilot-dispatchable.json")
    fe, fa = analyse_funil(log_p, lo, hi)
    qe, qa = read_fila(fila_p, now)
    if fa is not None:
        antes = fa["categorias"]["cedida"]["_beads"] | fa["categorias"]["teto"]["_beads"]
        # rota ausente/ilegível (ra None) → None: "não sei o que o gancho viu", NUNCA "0 viram" nem "todas pararam antes". Rota vazia (ra com 0 beads) é uma resposta: nenhuma tem linha
        fa["pararam_antes"] = len(antes - ra["_beads"]) if ra else None
        fa["no_gancho"] = len(ra["_beads"]) if ra else None
        fa["ao_no"] = len(ra["ao_no_de_verdade"]) if ra else None
        # o Pilot gravou ALGUMA linha de rota na janela? Se não, "sem linha na rota" não diz nada do nó (modo off, gancho fora do ar). Rota não lida → None
        fa["gancho_gravou"] = bool(ra["modos"]) if ra else None
        for c in fa["categorias"].values():
            c["beads"] = len(c.pop("_beads"))
    if ra:
        ra.pop("_beads", None)
    res = {
        "janela": {"horas": a.hours, "inicio": lo, "fim": hi},
        "rota": {"arquivo": rota_p, "estado": re_, "ilegiveis": rbad, "analise": ra},
        "ocupacao": {"arquivo": occ_p, "estado": oe, "ilegiveis": obad, "analise": oa},
        "funil": {"arquivo": log_p, "estado": fe, "analise": fa},
        "fila": {"arquivo": fila_p, "estado": qe, "analise": qa},
        "prontidao": prontidao(ra, a.min_hours, a.min_beads, a.hours) if ra else None,
        "motivos": {"arquivo": exe_p, "estado": xe, "ilegiveis": xbad, "analise": xa},
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
