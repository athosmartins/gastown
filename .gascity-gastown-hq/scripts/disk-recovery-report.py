#!/usr/bin/python3
"""disk-recovery-report.py — relatório da escada de recuperação de disco, lido do LOG do maestro (ga-1p1i5jr.5, partes (b) e (c) do D5).

## Contents
  Para que serve · Uso · O que o relatório diz · Aceite da missão · Saídas · Três estados

PARA QUE SERVE. O D5 pede (b) 24 h em produção com o log mostrando as decisões e (c) um relatório: quantas vezes cada degrau rodou, quanto disco cada um devolveu e se
alguma janela > 60 min com o disco < 3 GB ficou sem ação da escada. Esta ferramenta LÊ o log que o maestro (disk-recovery-ladder.sh) escreve — o mesmo formato na simulação
ponta a ponta (disk-recovery-e2e.selftest.sh) e no canário — e calcula isso: relato de agente não é medição, o número sai do artefato.

USO. disk-recovery-report.py [--log CAMINHO ...] [--since 'AAAA-MM-DD HH:MM'] [--until '...'] [--min-hours 24] [--json]
  Sem --log: $GC_CITY_PATH/.gc/logs/disk-recovery.log e o .1 (a rotação em 5 MB), se existir; sem GC_CITY_PATH, a cidade que contém este script. Só LÊ; não escreve nada.

O QUE O RELATÓRIO DIZ. (1) Cobertura: primeira e última linha, horas cobertas, maior silêncio (o maestro escreve ao menos 1 linha por hora, mesmo sem episódio, ENQUANTO o job roda e .gc/disk-recovery.off não existe) e linhas sem carimbo
  (cada uma vale pela hora da linha de cima: com --since/--until só contam as do período).
  (2) Por degrau (D2, D3, D4): chamadas `--run`, quantas agiram / adiaram (rc 10) / falharam (rc 20) / não leram (rc 30) / ficaram sem linha de resultado, e os MB devolvidos
  (soma de livre depois − antes das que agiram). O D4 reinicia o mini e mata o maestro no meio: a chamada fica SEM linha de resultado; o relatório a conta como "reinício pedido"
  (inferido) e mede o que devolveu pela 1ª leitura DEPOIS da chamada. (3) Janelas com o livre < 3072 MB e o que a escada fez dentro delas.

ACEITE DA MISSÃO ("nenhuma janela > 60 min com disco < 3 GB sem uma ação da escada no log"). Janela = leituras seguidas com livre < --low-mb (padrão 3072), unidas por lacunas
  de leitura (uma lacuna no meio de uma janela baixa NÃO a interrompe: sem leitura não se sabe que recuperou). Ação da escada = uma chamada `--run` de degrau no log, dentro da
  janela ou até --grace-s (300 s) depois do fim dela (a chamada do D4 é escrita na mesma rodada da última leitura baixa). Janela > --window-min (60) SEM ação = NÃO ATENDIDO.
  Leitura baixa seguida de silêncio maior que --max-gap-s (600 s, a regra de lacuna do maestro) antes de uma leitura boa: o fim da janela é INCERTO; se o pior caso (até essa
  leitura) passa de 60 min sem ação, o veredito é NÃO VERIFICADO, nunca ATENDIDO. Também são NÃO VERIFICADO: um log sem nenhuma leitura; uma janela ainda ABERTA no fim do log (a última
  leitura é baixa, ou o carimbo anda para trás) e sem nenhuma ação da escada — o relatório não tem "agora", o que veio depois é desconhecido; e QUALQUER silêncio de mais de 65 min entre
  duas linhas, até entre duas leituras boas (sem leitura não se sabe que o disco ficou bom; o job parado 23 h num canário de 24 h não passa). Rótulo da janela com chamada: OK (algum degrau
  agiu), OK_ADIADA (só adiaram, rc 10), OK_TENTOU (falhou, não leu ou morreu sem resultado). Se o disco nunca ficou ≤ 5 GB e nenhum degrau foi chamado, o relatório diz que o canário
  NÃO exercitou a escada (o aceite vale por vacuidade).

SAÍDAS. 0 = aceite ATENDIDO e cobertura >= --min-hours · 1 = NÃO ATENDIDO, NÃO VERIFICADO ou cobertura curta (o relatório sai assim mesmo) · 2 = uso · 3 = não consegui ler um
  log pedido (arquivo ausente, sem permissão, é um diretório): NÃO imprime relatório nenhum, "0 eventos" de um log que não li seria mentira.

TRÊS ESTADOS. Log ausente/ilegível = rc 3 (não sei), log vazio = relatório sem leituras (NÃO VERIFICADO), linha sem carimbo = contada à parte e nunca vira leitura nem ação; `depois=?`
  (a re-medição do maestro falhou) = devolvido DESCONHECIDO (fora da soma, contado); reinício do D4 sem nenhuma leitura depois = "sem leitura depois", nunca "+0 MB". Carimbo que anda
  para trás quebra a continuidade: nunca une duas janelas.
"""
import argparse
import datetime
import json
import os
import re
import sys

SILENCE_S = 3900   # o maestro escreve >= 1 linha por hora com o job rodando: mais de 65 min entre duas linhas = ninguém estava olhando o disco
TS = r"^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] "
RE_READ = re.compile(TS + r"(?:leitura|ok): livre=(\d+)MB swap=(?:\d+|\?)MB")
RE_CALL = re.compile(TS + r"degrau D([234]): chamando \S+ (--run|--dry-run) \(livre=(\d+)MB")
RE_OUT = re.compile(TS + r"degrau D([234]): rc=(\d+) \((acted|idle|failed|unknown)\) livre antes=(\d+)MB depois=(\d+|\?)MB")
RE_ALERT = re.compile(r"^(WARN|ERROR|ESCALA)")
FMT = "%Y-%m-%d %H:%M:%S"
CLASSES = ("acted", "idle", "failed", "unknown", "no_result")


class ReadError(Exception):
    pass


def read_lines(path):
    """As linhas de UM log. vazio (arquivo sem linhas) → lista vazia, o log existe e está vazio; falhou/ilegível (ausente, sem permissão, é um diretório) → ReadError, nunca lista vazia."""
    # vazio → lista vazia (log sem linhas); falhou/ilegível → ReadError (rc 3, nenhum relatório). Bytes inválidos viram U+FFFD em vez de derrubar a leitura: o log de uma máquina sem espaço pode ter uma linha cortada
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read().splitlines()
    except OSError as exc:
        raise ReadError("não consegui ler %s: %s" % (path, exc.strerror or exc.__class__.__name__))


def parse(paths):
    """→ (eventos na ordem do arquivo, a hora da linha de cima de cada linha sem carimbo válido: None se for a 1ª). Evento = dict com t (datetime) e kind: read | call | out | note."""
    ev, junk, last = [], [], None
    for path in paths:
        for line in read_lines(path):
            # vazio (linha sem carimbo) → entra em `junk` com a hora da linha de cima; falhou/ilegível (data impossível: mês 13) → idem. Nenhuma das duas vira leitura nem ação
            m = re.match(TS, line)
            try:
                t = datetime.datetime.strptime(m.group(1), FMT) if m else None
            except ValueError:   # carimbo com cara de data que não é (mês 13): não é linha de log legível
                t = None
            if t is None:
                junk.append(last)
                continue
            last = t
            r = RE_READ.match(line)
            if r:
                ev.append({"t": t, "kind": "read", "free": int(r.group(2))})
                continue
            r = RE_CALL.match(line)
            if r:
                ev.append({"t": t, "kind": "call", "rung": int(r.group(2)), "mode": r.group(3), "free": int(r.group(4)), "cls": None, "after": None})
                continue
            r = RE_OUT.match(line)
            if r:
                ev.append({"t": t, "kind": "out", "rung": int(r.group(2)), "cls": r.group(4), "before": int(r.group(5)), "after": int(r.group(6)) if r.group(6).isdigit() else None})
                continue
            ev.append({"t": t, "kind": "note", "text": line[22:][:90], "alert": bool(RE_ALERT.match(line[22:]))})
    return ev, junk   # na ORDEM do arquivo (o log é append-only; o --log mais velho vem primeiro): um relógio que andou para trás aparece como carimbo menor e quebra a continuidade, nunca é reordenado


def pair_calls(ev):
    """Anota cada chamada `--run` com o resultado (cls, e o 'depois' do maestro). Chamada sem linha de resultado antes da próxima do mesmo degrau (ou do fim do log) = no_result."""
    pending = {}
    for e in ev:
        if e["kind"] == "call" and e["mode"] == "--run":
            old = pending.pop(e["rung"], None)
            if old is not None:
                old["cls"] = "no_result"
            pending[e["rung"]] = e
        elif e["kind"] == "out":
            c = pending.pop(e["rung"], None)
            if c is not None:
                c["cls"], c["after"], c["before"] = e["cls"], e["after"], e["before"]
    for c in pending.values():
        c["cls"] = "no_result"


def rung_stats(ev):
    st = {n: dict({k: 0 for k in CLASSES}, calls=0, returned_mb=0, unknown_mb=0, no_gain=0, reboots_inferred=0, after_boot_mb=0, boot_unread=0) for n in (2, 3, 4)}
    reads = [e for e in ev if e["kind"] == "read"]
    for c in (e for e in ev if e["kind"] == "call" and e["mode"] == "--run"):
        s = st[c["rung"]]
        s["calls"] += 1
        s[c["cls"]] += 1
        if c["cls"] == "acted":
            if c["after"] is None:
                s["unknown_mb"] += 1
            else:
                s["returned_mb"] += c["after"] - c["before"]
                s["no_gain"] += 1 if c["after"] <= c["before"] else 0
        elif c["cls"] == "no_result" and c["rung"] == 4:   # o reinício mata o maestro: o pedido fica sem resultado; o que devolveu = a 1ª leitura DEPOIS da chamada
            s["reboots_inferred"] += 1
            nxt = [r for r in reads if r["t"] > c["t"]]
            if nxt:
                s["after_boot_mb"] += nxt[0]["free"] - c["free"]
            else:   # o log acaba sem nenhuma leitura depois do pedido (o mini não voltou?): quanto devolveu é DESCONHECIDO, não 0
                s["unknown_mb"] += 1
                s["boot_unread"] += 1
    return st


def windows(ev, low_mb, max_gap_s, grace_s, window_min):
    """Janelas com o livre < low_mb e o que a escada fez em cada uma → lista de dicts (start, end, secs, worst, open, min_free, readings, calls, acted, verdict)."""
    reads = [e for e in ev if e["kind"] == "read"]
    calls = [e for e in ev if e["kind"] == "call" and e["mode"] == "--run"]
    out, cur, prev = [], None, None
    grace = datetime.timedelta(seconds=grace_s)

    def close(w, silence, open_end=False):   # open_end: nenhuma leitura boa fechou a janela (o log acabou ou o carimbo andou para trás): o fim é desconhecido
        w["calls"] = [c for c in calls if w["start"] <= c["t"] <= w["end"] + grace]
        w["acted"] = sum(1 for c in w["calls"] if c["cls"] == "acted" or (c["cls"] == "no_result" and c["rung"] == 4))   # o D4 que reinicia não deixa resultado
        w["secs"] = int((w["end"] - w["start"]).total_seconds())
        w["worst"], w["open"] = w["secs"] + silence, open_end
        limit = window_min * 60
        if w["secs"] > limit and not w["calls"]:
            w["verdict"] = "VIOLACAO"
        elif (w["worst"] > limit or open_end) and not w["calls"]:
            w["verdict"] = "NAO_VERIFICADO"
        else:   # com chamada: agiu = OK; só adiou (rc 10) = OK_ADIADA; falhou/não leu/morreu sem resultado = OK_TENTOU (a escada tentou e não agiu)
            w["verdict"] = "OK" if (w["acted"] or not w["calls"]) else "OK_ADIADA" if all(c["cls"] == "idle" for c in w["calls"]) else "OK_TENTOU"
        out.append(w)

    for r in reads:
        gap = int((r["t"] - prev["t"]).total_seconds()) if prev else 0
        low = r["free"] < low_mb
        if cur is not None and gap < 0:   # carimbo para trás: não una nada, e o fim da janela anterior é desconhecido
            close(cur, 0, True)
            cur = None
        if cur is not None and not low:
            close(cur, gap if gap > max_gap_s else 0)   # a janela acaba na última leitura baixa; silêncio antes desta leitura boa = fim incerto por até `gap` s
            cur = None
        elif cur is not None:
            cur["end"], cur["readings"] = r["t"], cur["readings"] + 1
            cur["min_free"] = min(cur["min_free"], r["free"])
        if cur is None and low:
            cur = {"start": r["t"], "end": r["t"], "min_free": r["free"], "readings": 1}
        prev = r
    if cur is not None:   # o log acaba numa leitura baixa: o relatório não tem "agora", então o que veio depois é desconhecido
        close(cur, 0, True)
    return out


def build(paths, args):
    ev, junk = parse(paths)
    # vazio (--since/--until sem nada dentro) → relatório sem leituras, NÃO VERIFICADO; falhou/ilegível (data que não é data) → uso errado, rc 2 no argparse
    inside = lambda t: (not args.since or (t is not None and t >= args.since)) and (not args.until or (t is not None and t <= args.until))   # linha sem carimbo antes da 1ª (t None) só conta sem período
    ev = [e for e in ev if inside(e["t"])]
    pair_calls(ev)
    reads = [e for e in ev if e["kind"] == "read"]
    rep = {"logs": paths, "lines_unstamped": sum(1 for t in junk if inside(t)), "events": len(ev), "readings": len(reads), "hours": 0, "max_silence_min": 0, "silences_over_65min": []}
    long_gaps = []
    if ev:
        gaps = sorted(((b["t"] - a["t"]).total_seconds(), a["t"].strftime(FMT)) for a, b in zip(ev, ev[1:]))
        long_gaps = [g for g in gaps if g[0] > SILENCE_S]
        rep.update(first=ev[0]["t"].strftime(FMT), last=ev[-1]["t"].strftime(FMT), hours=round((ev[-1]["t"] - ev[0]["t"]).total_seconds() / 3600.0, 2))
        rep["max_silence_min"] = int(gaps[-1][0] // 60) if gaps else 0
        rep["silences_over_65min"] = [{"after": g[1], "min": int(g[0] // 60)} for g in long_gaps][-5:]
    rep["rungs"] = {"D%d" % n: s for n, s in rung_stats(ev).items()}
    rep["windows"] = [{"start": w["start"].strftime(FMT), "end": w["end"].strftime(FMT), "minutes": w["secs"] // 60, "worst_minutes": w["worst"] // 60, "min_free": w["min_free"],
                       "readings": w["readings"], "calls": ["D%d" % c["rung"] for c in w["calls"]], "acted": w["acted"], "verdict": w["verdict"], "open": w["open"]}
                      for w in windows(ev, args.low_mb, args.max_gap_s, args.grace_s, args.window_min)]
    rep["min_free"] = min((r["free"] for r in reads), default=None)
    rep["exercised"] = any(r["free"] <= 5120 for r in reads) or any(e["kind"] == "call" and e["mode"] == "--run" for e in ev)
    alerts = [e["text"] for e in ev if e["kind"] == "note" and e["alert"]]
    rep["alerts_total"], rep["alerts"] = len(alerts), alerts[:5]
    verdicts = [w["verdict"] for w in rep["windows"]]
    # ATENDIDO só quando nada ficou sem olhar: sem leitura, silêncio > 65 min (mesmo entre duas leituras boas) ou janela de fim incerto/em aberto = NÃO VERIFICADO
    rep["unverified_why"] = (["sem leituras"] if not reads else []) + (["%d silêncio(s) > %d min" % (len(long_gaps), SILENCE_S // 60)] if long_gaps else []) + (["janela(s) com fim incerto ou em aberto"] if "NAO_VERIFICADO" in verdicts else [])
    rep["acceptance"] = "NAO_ATENDIDO" if "VIOLACAO" in verdicts else "NAO_VERIFICADO" if rep["unverified_why"] else "ATENDIDO"
    rep["coverage_ok"] = rep["hours"] >= args.min_hours
    rep["green"] = rep["acceptance"] == "ATENDIDO" and rep["coverage_ok"]
    return rep


def render(rep, args):
    ln = ["Escada de disco — relatório do log (%s)" % ", ".join(rep["logs"])]
    if rep["readings"] == 0:
        ln.append("SEM LEITURAS no período: a escada não escreveu nenhuma leitura de disco aqui (parada, desligada ou período errado).")
    else:
        ln.append("Cobertura: %s → %s = %s h, %d leituras, maior silêncio %d min%s" % (rep["first"], rep["last"], rep["hours"], rep["readings"], rep["max_silence_min"],
                  "" if rep["coverage_ok"] else "  [CANÁRIO INCOMPLETO: menos de %s h]" % args.min_hours))
        ln.append("Menor livre visto: %s MB. %s" % (rep["min_free"], "" if rep["exercised"] else "O canário NÃO exercitou a escada (disco nunca ≤ 5 GB, nenhum degrau chamado): o aceite vale por vacuidade."))
    ln += ["  silêncio de %d min depois de %s (o maestro escreve ao menos 1 linha por hora enquanto o job roda e .gc/disk-recovery.off não existe: nesse intervalo ele não rodou, estava desligado ou o relógio saltou)" % (s["min"], s["after"])
           for s in rep["silences_over_65min"]]
    ln.append("Linhas sem carimbo: %d · avisos WARN/ERROR/ESCALA: %d" % (rep["lines_unstamped"], rep["alerts_total"]))
    ln += ["", "Degrau  chamadas  agiu  adiou(10)  falhou(20)  não leu(30)  sem resultado  devolveu (MB)"]
    for name in ("D2", "D3", "D4"):
        s = rep["rungs"][name]
        extra = ""
        if name == "D4":
            # nenhum reinício → +0 MB é verdade; reinício(s) sem leitura depois → não há número (desconhecido nunca vira +0 MB)
            after = "sem leitura depois (não sei quanto devolveu)" if s["boot_unread"] and s["boot_unread"] == s["reboots_inferred"] else "%+d MB%s" % (s["after_boot_mb"], " (+%d sem leitura depois)" % s["boot_unread"] if s["boot_unread"] else "")
            extra = "  reinícios pedidos (inferido): %d, 1ª leitura depois: %s" % (s["reboots_inferred"], after)
        elif s["unknown_mb"] or s["no_gain"]:
            extra = "  (%d sem medida depois, %d sem ganho)" % (s["unknown_mb"], s["no_gain"])
        ln.append("%-7s %8d %5d %10d %11d %12d %14d %14d%s" % (name, s["calls"], s["acted"], s["idle"], s["failed"], s["unknown"], s["no_result"], s["returned_mb"], extra))
    ln += ["", "Janelas com livre < %d MB: %d" % (args.low_mb, len(rep["windows"]))]
    ln += ["  %s → %s  %d min (pior caso %d)  mín %d MB  chamadas: %s  agiu: %d  [%s%s]" % (w["start"], w["end"], w["minutes"], w["worst_minutes"], w["min_free"], " ".join(w["calls"]) or "nenhuma", w["acted"], w["verdict"], ", em aberto no fim do log" if w["open"] else "")
           for w in rep["windows"]]
    ln += ["", "ACEITE (nenhuma janela > %d min com disco < %d MB sem ação da escada): %s%s" % (args.window_min, args.low_mb, rep["acceptance"].replace("_", " "), "  [%s]" % "; ".join(rep["unverified_why"]) if rep["acceptance"] == "NAO_VERIFICADO" else "")]
    return "\n".join(ln)


def default_logs():
    # vazio (GC_CITY_PATH sem valor) → a cidade que contém este script; o .1 só entra se existir (sem rotação ainda é normal), mas o principal sempre entra: ausente = ReadError (rc 3), nunca "sem eventos"
    city = os.environ.get("GC_CITY_PATH") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    base = os.path.join(city, ".gc", "logs", "disk-recovery.log")
    return ([base + ".1"] if os.path.lexists(base + ".1") else []) + [base]


def stamp(s):
    for f in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
        try:
            return datetime.datetime.strptime(s, f)
        except ValueError:
            pass
    raise argparse.ArgumentTypeError("data inválida '%s' (use 'AAAA-MM-DD HH:MM')" % s)


def main(argv):
    ap = argparse.ArgumentParser(description="relatório da escada de recuperação de disco, lido do log do maestro")
    ap.add_argument("--log", action="append", help="log do maestro (repita para o .1 rotacionado, do mais velho ao mais novo)")
    ap.add_argument("--since", type=stamp)
    ap.add_argument("--until", type=stamp)
    ap.add_argument("--min-hours", type=float, default=24.0)
    ap.add_argument("--low-mb", type=int, default=3072)
    ap.add_argument("--window-min", type=int, default=60)
    ap.add_argument("--max-gap-s", type=int, default=600)
    ap.add_argument("--grace-s", type=int, default=300)
    ap.add_argument("--json", action="store_true")
    try:
        args = ap.parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code else 0
    try:
        rep = build(args.log or default_logs(), args)
    except ReadError as exc:
        print("ERRO: %s (nada foi relatado: um log que não li não vira \"0 eventos\")" % exc, file=sys.stderr)
        return 3
    print(json.dumps(rep, indent=1, sort_keys=True) if args.json else render(rep, args))
    return 0 if rep["green"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
