#!/usr/bin/env python3
"""wa-node-report.py — o WhatsApp foi mesmo ao nó, e o nó ficou ocupado? A prova do dia seguinte da ga-2hd02v.3. SÓ LEITURA.

Contents
  Para quê · Uso · O que diz · Estados que não se confundem · O que NÃO diz

PARA QUÊ (Athos 20/10: "o que não pode é ficar menos do que 100% ocupado"): responder em um comando as duas perguntas que decidem os próximos passos da ga-2hd02v.3 —
  (1) quantas beads de WhatsApp o Pilot mandou ao nó, e a sombra já tem base para ligar `PILOT_WA_NODE_ROUTE=auto`? (2) quanto da CPU do nó foi usada, hora a hora?
USO      wa-node-report.py [--hours N] [--city DIR] [--json] [--min-hours H] [--min-beads B] [--busy-pct P]
         --hours N      janela, em horas, até agora (24; inteiro de 1 a 99999, "010" é dez)        --city DIR   a cidade (GC_CITY_PATH, senão /Users/athos/gt/.gascity-gastown-hq)
         --min-hours H  quantas horas de sombra bastam para REVISAR a flip para auto (24)           --min-beads B  quantas beads distintas bastam (30)
         --busy-pct P   a partir de quantos % de CPU a leitura conta como "perto de 100%" (90)       --json       o mesmo em JSON
         exit 0 ok · 2 uso · 3 NENHUM dos dois logs deu para usar (ausente ou ilegível) · 4 relatório não formado
O QUE DIZ  1. a rota (<cidade>/.gc/wa-node-route.jsonl: o que o despachante e o Pilot gravam): cobertura da sombra, o veredito de cada bead (o ÚLTIMO da janela), as que foram ao nó
              de verdade, as que o classificador mandou ao nó mas não couberam (sem vaga) e as que mudaram de veredito, que é onde mora o falso "node";
           2. a CPU do nó por hora, em UTC (<cidade>/.gc/hetzner-occupancy.jsonl: uma leitura a cada 15 min do hetzner-occupancy-watch), a média, quantas leituras ficaram perto de 100%
              e quantas sessões wa-worker-remote estavam vivas;
           3. a prontidão MECÂNICA da sombra: horas e beads suficientes para alguém REVISAR. Não é aprovação: quem liga o `auto` é uma pessoa, depois de conferir uma a uma as beads `node` da lista.
ESTADOS QUE NÃO SE CONFUNDEM  log ausente ("ainda não houve rodada") ≠ log vazio ≠ log ilegível ≠ zero decisões na janela. Linha que não dá para ler vem CONTADA e avisada, nunca omitida em
           silêncio. CPU que não foi lida (a 1ª leitura só semeia o baseline; o ssh falhou) NUNCA vira 0%: entra em "sem CPU lida". Sessões não lidas não viram "0 sessões".
O QUE NÃO DIZ  que nenhuma bead com dado de lead foi ao nó: o relatório não vê o conteúdo da bead. Lista as que foram (e por quê) para a conferência humana. A garantia de que dado de lead
           não chega ao nó é o espelho git com a varredura de CPF/telefone, não este relatório. Também não diz que o WA RODOU bem no nó: só que a bead foi atribuída lá.
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
    "node-despachada": "node, atribuída ao nó", "node-sombra": "node, só sombra (dry-run)", "node-sem-vaga": "node, mas sem vaga no nó",
    "node-sem-etiqueta": "node pelo classificador, sem a etiqueta node:ok", "mini": "mini", "nao-sei": "não sei (o classificador recusa)",
}


def is_rc(r, n):
    """o rc da linha é o inteiro n (bool não é inteiro aqui: False == 0 em Python)"""
    v = r.get("rc")
    return isinstance(v, int) and not isinstance(v, bool) and v == n


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
    """o rc e o detalhe que o wa-node-dispatch.sh grava num `apply` → a categoria"""
    if rc == 0 and detail.startswith("dry-run:"):
        return "node-sombra"
    if rc == 0 and detail.startswith("despachada"):
        return "node-despachada"
    if rc == 10:
        return "node-sem-etiqueta" if detail.startswith("base=") else "mini"
    if rc == 11:
        return "nao-sei" if detail.startswith("classificador:unknown") else "nao-li"
    if rc == 12:
        return "node-sem-vaga" if re.split(r"[ =:]", detail, 1)[0] in SEM_VAGA else "nao-elegivel"
    if rc == 13:
        return "falha-escrita"
    return "outro"


def analyse_route(rows, lo, hi):
    ev, sem_hora = [], 0
    for i, r in enumerate(rows):
        e = route_epoch(r)
        if e is None:
            sem_hora += 1
        elif lo <= e <= hi:
            ev.append((e, i, r))
    ev.sort(key=lambda t: (t[0], t[1]))
    beads, modos, decisoes, apply_ilegivel = {}, {}, 0, 0
    soltas, leitura_falhou, pilot_last = 0, 0, {}
    for e, _i, r in ev:
        bid, kind = r.get("bead"), r.get("event")
        if not isinstance(bid, str) or not bid:
            apply_ilegivel += 1
            continue
        b = beads.setdefault(bid, {"cats": [], "razoes": None, "base": None, "despachada": False, "ultimo_rc": None})
        if kind == "apply":
            rc, det = r.get("rc"), r.get("detail")
            if isinstance(rc, bool) or not isinstance(rc, int) or not isinstance(det, str):
                apply_ilegivel += 1
                continue
            decisoes += 1
            c = cat_of(rc, det)
            b["cats"].append(c)
            b["ultimo_rc"] = rc
            if c == "node-despachada":
                b["despachada"] = True
            m = None
            if c in ("node-sombra", "node-despachada"):
                m = re.match(r"(?:dry-run: iria para|despachada para) \S+ \(([A-Za-z0-9_-]+)\)", det)
            elif c == "node-sem-etiqueta":
                m = re.match(r"base=([A-Za-z0-9_-]+)", det)
            if m:
                b["base"] = m.group(1)
        elif kind == "release" and is_rc(r, 0):
            soltas += 1
        elif kind in ("read", "classify"):
            leitura_falhou += 1
        elif kind == "pilot-node-route":
            mo = r.get("mode") if isinstance(r.get("mode"), str) else "?"
            modos[mo] = modos.get(mo, 0) + 1
            pilot_last = {"spawn": r.get("spawn"), "slots": r.get("slots"), "mode": mo}
            out = r.get("out")
            # vazio ('') → sem razões; texto que não é JSON ou sem `reasons` em lista → sem razões (a conferência humana lê a bead): nunca inventa
            if is_rc(r, 0) and isinstance(out, str) and out.strip():
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
    node_lista = sorted(bid for bid, b in beads.items() if any(c in NODE_CATS for c in b["cats"]))
    horas = round((ev[-1][0] - ev[0][0]) / 3600.0, 2) if ev else 0.0
    return {
        "linhas_na_janela": len(ev), "sem_hora": sem_hora, "primeira": ev[0][0] if ev else None, "ultima": ev[-1][0] if ev else None, "horas_cobertas": horas,
        "decisoes": decisoes, "beads_distintas": sum(1 for b in beads.values() if b["cats"]), "modos": modos, "pilot_ultimo": pilot_last,
        "veredito_final": final, "fora_do_veredito": outros, "apply_ilegivel": apply_ilegivel, "leituras_que_falharam": leitura_falhou, "soltas": soltas,
        "ao_no_de_verdade": sorted(bid for bid, b in beads.items() if b["despachada"]), "instaveis": sorted(instaveis),
        "node_para_conferir": [{"bead": bid, "ultimo": beads[bid]["final"], "base": beads[bid]["base"], "razoes": beads[bid]["razoes"]} for bid in node_lista],
    }


def analyse_occ(rows, lo, hi, busy_pct):
    horas, sem_epoch, total = {}, 0, 0
    cpu_ok = cpu_sem = sess_lida = sess_nao = wa_leituras = 0
    soma_pct = 0.0
    perto = 0
    for r in rows:
        ep = num(r.get("epoch"))
        if ep is None:
            sem_epoch += 1
            continue
        if not (lo <= ep <= hi):
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
        # sessões não lidas (lido=false, lista que não é lista de texto) → não entram na média de WA: "0 sessões" seria mentira
        if isinstance(nomes, list) and all(isinstance(n, str) for n in nomes):
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
        "leituras": total, "sem_epoch": sem_epoch, "cpu_lidas": cpu_ok, "cpu_sem_leitura": cpu_sem,
        "pct_medio": round(soma_pct / cpu_ok, 1) if cpu_ok else None, "perto_de_100": perto, "busy_pct": busy_pct,
        "perto_de_100_pct": round(100.0 * perto / cpu_ok, 1) if cpu_ok else None,
        "sessoes_lidas": sess_lida, "sessoes_nao_lidas": sess_nao, "leituras_com_wa_no_no": wa_leituras, "horas": tabela,
    }


def prontidao(rota, min_hours, min_beads):
    falta = []
    if rota["horas_cobertas"] < min_hours:
        falta.append("a sombra cobre %s h de %d" % (fnum(rota["horas_cobertas"]), min_hours))
    if rota["beads_distintas"] < min_beads:
        falta.append("%d bead(s) distinta(s) de %d" % (rota["beads_distintas"], min_beads))
    return {"suficiente_para_revisar": not falta, "falta": falta, "a_conferir": len(rota["node_para_conferir"]), "instaveis": len(rota["instaveis"])}


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
        L.append("  cobertura: %s → %s (%s h), %d linha(s) na janela, %d sem hora legível" % (iso(a["primeira"]), iso(a["ultima"]), fnum(a["horas_cobertas"], 2), a["linhas_na_janela"], a["sem_hora"]))
        L.append("  modos do Pilot vistos: %s; spawn=%s slots=%s (da última linha)" % (", ".join("%s=%d" % kv for kv in sorted(a["modos"].items())) or "nenhum", a["pilot_ultimo"].get("spawn") or "—", a["pilot_ultimo"].get("slots") or "—"))
        L.append("  %d decisão(ões) do despachante sobre %d bead(s) distinta(s); veredito = o ÚLTIMO da bead na janela:" % (a["decisoes"], a["beads_distintas"]))
        for c in VEREDITOS:
            L.append("    %-52s %d" % (ROTULOS[c], a["veredito_final"][c]))
        if a["fora_do_veredito"]:
            L.append("    sem veredito (não elegível / não li / falha de escrita): %s" % ", ".join("%s=%d" % kv for kv in sorted(a["fora_do_veredito"].items())))
        if a["apply_ilegivel"] or a["leituras_que_falharam"]:
            L.append("    linhas de apply ilegíveis: %d; leituras de bead que falharam: %d (a sonda do disk floor entra aqui)" % (a["apply_ilegivel"], a["leituras_que_falharam"]))
        L.append("  WhatsApp ao nó DE VERDADE (atribuída pelo despachante): %d bead(s)%s; soltas depois da entrega: %d" % (len(a["ao_no_de_verdade"]), (" — " + ", ".join(a["ao_no_de_verdade"][:12])) if a["ao_no_de_verdade"] else "", a["soltas"]))
        if a["instaveis"]:
            L.append("  ATENÇÃO — mudaram de veredito (node e depois mini/não sei; é onde mora o falso 'node'): %s" % ", ".join(a["instaveis"]))
        if a["node_para_conferir"]:
            L.append("  PARA CONFERIR UMA A UMA (todo veredito node da janela; nenhuma pode tocar dado de lead):")
            for n in a["node_para_conferir"][:40]:
                L.append("    %s  [%s%s]  %s" % (n["bead"], ROTULOS.get(n["ultimo"], n["ultimo"] or "—"), (", base " + n["base"]) if n["base"] else "", ("razões: " + "; ".join(n["razoes"])) if n["razoes"] else "razões: —"))
            if len(a["node_para_conferir"]) > 40:
                L.append("    … mais %d (use --json)" % (len(a["node_para_conferir"]) - 40))
    L.append("")
    L.append("[2] CPU DO NÓ POR HORA, UTC (%s)" % res["ocupacao"]["arquivo"])
    o = res["ocupacao"]
    aviso = estado_txt(o["estado"], o["ilegiveis"], o["arquivo"])
    if aviso:
        L.append("  " + aviso)
    if o["estado"] == "ok":
        b = o["analise"]
        L.append("  %d leitura(s) na janela (esperadas ~%d, uma a cada 15 min); CPU lida em %d, SEM CPU lida em %d (a 1ª leitura só semeia o baseline; não entram na média)" % (b["leituras"], res["janela"]["horas"] * 4, b["cpu_lidas"], b["cpu_sem_leitura"]))
        L.append("  META (Athos 20/10): nó em ~100%%. Média da janela: %s%%; leituras com CPU >= %d%%: %d de %d (%s%%)" % (fnum(b["pct_medio"]), b["busy_pct"], b["perto_de_100"], b["cpu_lidas"], fnum(b["perto_de_100_pct"])))
        L.append("  sessões wa-worker-remote vivas em %d leitura(s) (de %d com sessões lidas; %d sem sessões lidas)" % (b["leituras_com_wa_no_no"], b["sessoes_lidas"], b["sessoes_nao_lidas"]))
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
        L.append("  base suficiente PARA REVISAR: confira as %d bead(s) node da lista acima%s. Quem liga o auto é uma pessoa." % (p["a_conferir"], "; %d mudaram de veredito" % p["instaveis"] if p["instaveis"] else ""))
    else:
        L.append("  INSUFICIENTE: " + "; ".join(p["falta"]) + ". Não ligue o `auto` com isto.")
    return "\n".join(L) + "\n"


def parse_args(argv):
    ap = argparse.ArgumentParser(prog="wa-node-report.py", add_help=True)
    ap.add_argument("--hours", default="24")
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
        "prontidao": prontidao(ra, a.min_hours, a.min_beads) if ra else None,
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
