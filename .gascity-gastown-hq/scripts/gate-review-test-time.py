#!/usr/bin/env python3
"""gate-review-test-time.py — antes×depois do tempo de teste por sessão de revisor do gate (ga-xm1jfl). Só LÊ.

Contents
  O que mede · Uso · Limites · Selftest

O QUE MEDE
  dias      revisao_media_min por dia: média/mediana/p90 de elapsed_s dos eventos dispatcher_complete de .gc/quality-gate.jsonl,
            com o MESMO filtro do painel (lib/produtividade_gate.py::_analisar_gate + _agregar: sem dry_run, resultado PASS/FAIL, com bead,
            e JULGADO = PASS ou FAIL com "Reviewer N FAIL: VERDICT: FAIL" no reason; só então elapsed > 0) e o MESMO dia (BRT, UTC-3, como o
            painel — não o fuso da máquina). Os SEM VEREDITO (FAIL por TIMEOUT, bead já fechado, merge que falhou depois do all-PASS...)
            ficam FORA da média, porque o elapsed deles é a espera, não uma revisão, e aparecem CONTADOS na última coluna (o `sem_veredito`
            do painel). Única diferença de propósito: elapsed_s que não se lê num evento julgado (texto, `true`, NaN, Infinity — o painel lê como
            0 s, 1 s ou infinito) fica FORA e é CONTADO no aviso.
            É a métrica que o Athos olha (15 -> 27 min em ga-bk5j8u).
  sessoes   por sessão de revisor (transcrições em UMA pasta, ~/.claude/projects/-Users-athos-gt--gascity-gastown-hq--gc-agents-gate-reviewer;
            GATE_REVIEW_TRANSCRIPTS troca a pasta; as vizinhas — refino-gate-reviewer, sessões ad hoc em /private/tmp — NÃO entram, e a
            pasta lida é impressa acima da tabela): minutos totais e minutos ESPERANDO TESTE =
            soma da duração das chamadas Bash cujo comando cita pytest (python3 -m pytest, gate-pytest.sh, tail/sleep em log de pytest
            que o comando nomeia). --corte <ISO> parte as sessões em antes/depois do deploy do wrapper e compara as médias.
            É uma DICA, não a medida (veja LIMITES): a medida é `dias` (revisao_media_min) e `wrapper` (os segundos que o próprio
            wrapper registra).
  wrapper   o que o gate-pytest.sh registrou em .gc/logs/gate-pytest.jsonl: execuções por destino (mbp, local, mbp+local), segundos
            no MBP e aqui, e os motivos de rodar aqui. Só existe depois do deploy.

USO
  gate-review-test-time.py dias [--dias 7]
  gate-review-test-time.py sessoes [--n 20] [--corte 2026-10-12T06:00:00Z]
  gate-review-test-time.py wrapper [--desde 2026-10-12T06:00:00Z]
  gate-review-test-time.py --selftest
  Opção sem valor, desconhecida ou com valor inválido (--dias e --n: inteiro >= 1; 0 e negativo não são "nenhum" nem "tudo") é uso errado
  (rc 2, com a mensagem): nunca cai no padrão em silêncio ("sem corte", "desde sempre") nem vira uma medição vazia.
  Linha de log ou de transcrição ilegível é pulada e CONTADA no aviso do fim, nunca some. `dias` sem NENHUM evento contável (log vazio,
  girado, formato mudado) é rc 2 com a mensagem — "não consegui medir" não é "zero revisões".

LIMITES
  "Esperando teste" é um LIMITE INFERIOR: uma espera que o comando não rotula como pytest (sleep 60; tail $S/t1.log) não entra. A
  definição NÃO é a mesma antes e depois: antes o revisor esperava com nomes que ele mesmo escolhia, e depois o comando do wrapper
  cita gate-pytest.sh mas o poll dele (sleep 30; tail $S/gp.log) não cita nada — então o "depois" pode parecer melhor do que é.
  Por isso a tabela de `sessoes` é só uma dica; a manchete é revisao_media_min (`dias`) e os segundos do wrapper (`wrapper`),
  que não dependem de como o revisor batiza o log. A duração de cada chamada é a
  diferença entre o carimbo do tool_use e o do tool_result na transcrição; chamada sem resultado casado não conta (e é contada à parte).
"""
import contextlib
import glob
import io
import json
import math
import os
import re
import statistics
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone

CITY = os.environ.get("GATE_PYTEST_CITY") or os.environ.get("GC_CITY_PATH") or "/Users/athos/gt/.gascity-gastown-hq"
TRANSCRIPTS = os.environ.get("GATE_REVIEW_TRANSCRIPTS") or os.path.expanduser(
    "~/.claude/projects/-Users-athos-gt--gascity-gastown-hq--gc-agents-gate-reviewer")
PYTEST_RX = re.compile(r"pytest")
# Cópias de lib/produtividade_gate.py (rig whatsapp_automation) — o `dias` só vale "o mesmo filtro do painel" enquanto estas duas forem iguais às de lá:
BRT = timezone(timedelta(hours=-3))                               # o painel agrupa por dia em BRT, não no fuso da máquina
RX_JULGADO = re.compile(r"Reviewer \d+ FAIL: VERDICT: FAIL")      # FAIL com parecer de revisor; o resto é "sem veredito"


def epoch(s):
    """ISO 8601 -> epoch; None quando não dá para ler (nunca 0: 'não sei' não é 'meia-noite de 1970')."""
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return None


def pctl(xs, pct):
    """Percentil pelo posto mais próximo (nearest-rank), `pct` inteiro 1..100: o menor valor com ao menos pct% dos dados <= a ele. Conta em inteiro:
    round() é par-para-par e dava p90 de 6 amostras = o 5º valor, não o máximo."""
    if not xs:
        return None
    xs = sorted(xs)
    return xs[min(len(xs), max(1, -(-pct * len(xs) // 100))) - 1]


def dia_brt(ts):
    """Dia (AAAA-MM-DD) em BRT, como o painel agrupa — não o fuso da máquina."""
    return datetime.fromtimestamp(ts, BRT).strftime("%Y-%m-%d")


def fmt(v):
    return "-" if v is None else f"{v:.1f}"


def gate_events(path):
    """(julgados, sem_veredito, ilegíveis) — os PASS/FAIL que o painel conta, repartidos como ele reparte (lib/produtividade_gate.py::_agregar).
    julgados = [(ts, minutos)]: os que entram na média (PASS, ou FAIL com parecer de revisor; elapsed > 0). sem_veredito = [ts]: os que o painel
    conta mas NÃO põe na média (TIMEOUT, bead já fechado, merge que falhou...): o elapsed deles é a espera, não uma revisão. Linha ilegível é
    pulada e CONTADA (último valor), não some em silêncio."""
    out, sem_veredito, bad = [], [], 0
    with open(path, "rb") as fh:
        for line in fh:
            if b"dispatcher_complete" not in line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                bad += 1
                continue
            if not isinstance(e, dict):  # `null`, `[]`, um número: JSON válido que não é um evento — ilegível, contado, não um crash
                bad += 1
                continue
            res = str(e.get("result", "")).upper()
            ts = epoch(e.get("ts"))
            if e.get("event") != "dispatcher_complete" or str(e.get("dry_run")) == "1" or res not in ("PASS", "FAIL") \
                    or ts is None or not e.get("bead"):
                continue
            # vazio (sem reason) → FAIL sem parecer: "sem veredito", CONTADO fora da média; ilegível (reason que não é texto) → str() não casa, mesmo destino: nunca "julgado" por engano
            if res != "PASS" and not RX_JULGADO.match(str(e.get("reason") or "")):
                sem_veredito.append(ts)
                continue
            # vazio/0/negativo → fora da média sem alarme (o painel também os tira); falhou/ilegível → CONTADO em `bad`, nunca vira "0 s" filtrado em silêncio
            raw = e.get("elapsed_s")
            try:
                el = float(raw or 0)
                if isinstance(raw, bool) or not math.isfinite(el):  # `true` não é 1 s e NaN/Infinity não é duração
                    el = None
            except (TypeError, ValueError):
                el = None  # presente e ilegível: "não sei", não "0 s"
            if el is None:  # evento julgado, mas sem duração que se leia: CONTADO, não some como se fosse elapsed 0
                bad += 1
                continue
            if el <= 0:
                continue
            out.append((ts, el / 60.0))
    return out, sem_veredito, bad


def gate_events_from_lines(lines):
    """Só para o selftest: o mesmo gate_events, alimentado por linhas em memória."""
    with tempfile.TemporaryDirectory() as t:
        p = os.path.join(t, "g.jsonl")
        with open(p, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        return gate_events(p)


def cmd_dias(days, path=None):
    path = path or os.path.join(CITY, ".gc", "quality-gate.jsonl")
    try:
        evs, sem_veredito, bad = gate_events(path)
    except OSError as e:
        print(f"dias: não consegui ler {path}: {e}", file=sys.stderr)
        return 2
    if not evs and not sem_veredito:  # uma tabela sem linhas leria "zero revisões", e log vazio, girado ou ilegível NÃO é isso: é "não consegui medir", rc 2
        print(f"dias: nenhum evento dispatcher_complete contável em {path} (log vazio, girado ou de outro formato)"
              + (f"; {bad} evento(s)/linha(s) ilegíveis puladas" if bad else "") + " — isto NÃO é 'zero revisões'", file=sys.stderr)
        return 2
    by, sv = {}, {}
    for ts, m in evs:
        by.setdefault(dia_brt(ts), []).append(m)
    for ts in sem_veredito:
        sv[dia_brt(ts)] = sv.get(dia_brt(ts), 0) + 1
    print(f"{'dia (BRT)':<11}{'revisões':>9}{'média min':>11}{'mediana':>9}{'p90':>7}{'sem veredito':>14}")
    for d in sorted(set(by) | set(sv))[-days:]:
        xs = by.get(d, [])  # dia só com "sem veredito": linha com '-' na média, não sumida
        print(f"{d:<11}{len(xs):>9}{fmt(statistics.mean(xs) if xs else None):>11}{fmt(statistics.median(xs) if xs else None):>9}"
              f"{fmt(pctl(xs, 90)):>7}{sv.get(d, 0):>14}")
    if bad:
        print(f"(aviso: {bad} evento(s)/linha(s) dispatcher_complete ilegíveis ficaram de fora: JSON quebrado ou que não é objeto, ou julgado com elapsed_s que não se lê)")
    return 0


def session_stats(path):
    """(início_epoch, minutos_totais, minutos_esperando_teste, nº de chamadas de teste, chamadas sem resultado, linhas ilegíveis) ou None.
    Linha que não é JSON, ou é JSON que não é um objeto (`null`, um número), é pulada e CONTADA (último campo), nunca some em silêncio nem derruba a leitura;
    o mesmo vale para o que está DENTRO dela e não tem o formato esperado (`message` que não é objeto, chamada Bash sem comando em texto, chamada de teste com id que não é texto; um resultado com id ilegível não casa, e a chamada dele cai em "sem resultado casado")
    e para a linha de carimbo ilegível que carrega chamada de ferramenta (ela sairia da soma sem rastro). Linha em branco, e linha sem carimbo e sem
    chamada (resumo, snapshot), não contam."""
    uses, first, last, wait, runs, unmatched, bad = {}, None, None, 0.0, 0, 0, 0
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return None
    with fh:
        for line in fh:
            if not line.strip():
                continue
            try:
                o = json.loads(line)
            except ValueError:
                bad += 1
                continue
            if not isinstance(o, dict):
                bad += 1
                continue
            ts = epoch(o.get("timestamp"))
            # vazio (sem message/content: só estica o intervalo da sessão) → segue; ilegível (message que não é objeto) → CONTADA em `bad`, nem crash nem some
            m = o.get("message")
            if m is not None and not isinstance(m, dict):
                bad += 1
                m = None
            c = m.get("content") if m else None
            blocos = [b for b in c if isinstance(b, dict)] if isinstance(c, list) else []
            if ts is None:
                # sem carimbo legível não dá para datar a chamada: se a linha carrega uma, ela some da soma — CONTADA; sem chamada (resumo, snapshot) não há o que contar
                if any(b.get("type") in ("tool_use", "tool_result") for b in blocos):
                    bad += 1
                continue
            first = ts if first is None else min(first, ts)
            last = ts if last is None else max(last, ts)
            for b in blocos:
                if b.get("type") == "tool_use" and b.get("name") == "Bash":
                    # vazio (comando "") → não é teste, segue; ausente/ilegível (input que não é objeto, comando que não é texto) → CONTADA: não dá para dizer que não era teste
                    inp = b.get("input")
                    cmd = inp.get("command") if isinstance(inp, dict) else None
                    if not isinstance(cmd, str):
                        bad += 1
                    elif PYTEST_RX.search(cmd):
                        if isinstance(b.get("id"), str):
                            uses[b["id"]] = ts
                        else:  # chamada de teste cujo resultado nunca casaria: CONTADA, não some
                            bad += 1
                elif b.get("type") == "tool_result" and isinstance(b.get("tool_use_id"), str) and b["tool_use_id"] in uses:
                    wait += max(0.0, ts - uses.pop(b["tool_use_id"]))
                    runs += 1
    unmatched = len(uses)
    if first is None or last is None:
        return None
    return first, (last - first) / 60.0, wait / 60.0, runs, unmatched, bad


def cmd_sessoes(n, corte, dirpath=None):
    dirpath = dirpath or TRANSCRIPTS
    files = sorted(glob.glob(os.path.join(dirpath, "*.jsonl")), key=os.path.getmtime, reverse=True)
    rows, badl = [], 0
    for f in files:
        st = session_stats(f)
        if st:
            badl += st[5]  # de TODA sessão lida, também das que saem da tabela: uma linha estragada pode estar escondendo a chamada de teste que a poria nela
        if st and st[3] > 0:  # só sessões que rodaram teste: sem teste não há o que comparar
            rows.append(st)
        if len(rows) >= n and corte is None:
            break
    if not rows:
        print("sessoes: nenhuma sessão de revisor com teste achada em", dirpath, file=sys.stderr)
        return 2
    if corte is None:
        groups = [("últimas %d sessões com teste" % len(rows), rows)]
    else:
        c = epoch(corte)
        if c is None:
            print(f"sessoes: --corte '{corte}' não é uma data ISO", file=sys.stderr)
            return 2
        groups = [("antes do corte", [r for r in rows if r[0] < c][:n]), ("depois do corte", [r for r in rows if r[0] >= c][:n])]
    print(f"pasta lida: {dirpath}  (UMA pasta; sessões de outras pastas de revisor não entram)")
    print(f"{'grupo':<30}{'sessões':>8}{'min/sessão':>11}{'teste/sessão':>13}{'teste%':>8}{'chamadas':>9}")
    for name, g in groups:
        if not g:
            print(f"{name:<30}{0:>8}{'-':>11}{'-':>13}{'-':>8}{'-':>9}")
            continue
        tot = statistics.mean(r[1] for r in g)
        tw = statistics.mean(r[2] for r in g)
        print(f"{name:<30}{len(g):>8}{fmt(tot):>11}{fmt(tw):>13}{(100 * tw / tot if tot else 0):>7.0f}%{statistics.mean(r[3] for r in g):>9.1f}")
    un = sum(r[4] for r in rows)
    if un:
        print(f"(aviso: {un} chamada(s) de teste sem resultado casado na transcrição não entraram na soma)")
    if badl:
        print(f"(aviso: {badl} linha(s) de transcrição ilegíveis foram puladas)")
    print("(dica: esta tabela é só uma DICA. 'Teste/sessão' conta só chamada que cita pytest; depois do wrapper o revisor espera com nomes que ele "
          "escolhe (sleep 30; tail $S/gp.log), que não casam, e o depois pode parecer melhor do que é. A medida é revisao_media_min (dias) e "
          "os segundos que o wrapper registra (wrapper).)")
    return 0


def seconds(e, key):
    """Segundos de uma linha do log: número de verdade ou ValueError. Ausente, null e booleano NÃO são 0 s (bool é int em Python)."""
    v = e.get(key)
    if v is None or isinstance(v, bool):
        raise ValueError(key)
    return int(v)


def cmd_wrapper(desde, path=None):
    path = path or os.path.join(CITY, ".gc", "logs", "gate-pytest.jsonl")
    since = epoch(desde) if desde else None
    if desde and since is None:
        print(f"wrapper: --desde '{desde}' não é uma data ISO", file=sys.stderr)
        return 2
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError as e:
        print(f"wrapper: ainda não há {path} ({e.strerror}) — o wrapper não rodou ou não foi implantado", file=sys.stderr)
        return 2
    n, bad, ran, sec, motivos, sess = 0, 0, {}, [0, 0, 0], {}, set()
    with fh:
        for line in fh:
            if not line.strip():  # linha em branco não é linha ilegível (mesmo critério de session_stats)
                continue
            try:
                e = json.loads(line)
            except ValueError:
                bad += 1
                continue
            if not isinstance(e, dict):
                bad += 1
                continue
            ts = epoch(e.get("ts"))
            if since is not None:
                if ts is None:  # sem data não dá para dizer que é de depois do corte: fora da conta, mas DITO
                    bad += 1
                    continue
                if ts < since:
                    continue
            try:
                secs = (seconds(e, "secs"), seconds(e, "mbp_secs"), seconds(e, "local_secs"))
            except (TypeError, ValueError, OverflowError):  # segundos ausentes, null, booleano ou que não são número: a linha não entra na soma (e é contada), nunca vira 0
                bad += 1
                continue
            n += 1
            k = str(e.get("ran", "?"))
            ran[k] = ran.get(k, 0) + 1
            sec[0] += secs[0]; sec[1] += secs[1]; sec[2] += secs[2]
            if e.get("session"):
                sess.add(e["session"])
            d = str(e.get("detail") or "-")
            key = re.sub(r"[:(].*$", "", d.split(";")[0]) or "-"
            motivos[key] = motivos.get(key, 0) + 1
    print(f"execuções: {n}  sessões distintas: {len(sess)}  destino: " + ", ".join(f"{k}={v}" for k, v in sorted(ran.items())))
    print(f"segundos: total={sec[0]} no MBP={sec[1]} aqui={sec[2]}")
    print("motivos: " + ", ".join(f"{k}={v}" for k, v in sorted(motivos.items(), key=lambda kv: -kv[1])))
    if bad:
        print(f"(aviso: {bad} linha(s) ilegíveis puladas)")
    return 0


def selftest():
    fails = 0

    def ok(cond, msg):
        nonlocal fails
        print(("ok   " if cond else "FAIL ") + msg)
        fails += 0 if cond else 1

    with tempfile.TemporaryDirectory() as t:
        # gate: 3 JULGADOS no mesmo dia (PASS, PASS, FAIL com parecer de revisor) + 6 SEM VEREDITO (que o painel conta mas tira da média) + dry_run +
        # resultado ERROR + sem bead + elapsed 0 + linha quebrada
        g = os.path.join(t, "qg.jsonl")
        ev_ = '{"ts":"2026-10-10T%s:00:00Z","event":"dispatcher_complete","bead":"%s","result":"%s","elapsed_s":%s%s}'
        rows = [
            ev_ % ("12", "a", "PASS", "600", ""),
            ev_ % ("13", "b", "FAIL", "1200", ',"reason":"Reviewer 1 FAIL: VERDICT: FAIL\\nSummary: x"'),
            ev_ % ("14", "c", "PASS", "1800", ',"reason":"quorum_1_of_1_independent_sessions"'),
            # sem veredito: o elapsed é a ESPERA (3600 s), não uma revisão — ficam fora da média, CONTADOS à parte
            ev_ % ("15", "t", "FAIL", "3600", ',"reason":"TIMEOUT: reviewers did not submit verdicts within 45 minutes."'),
            ev_ % ("15", "v", "FAIL", "9999", ',"reason":"Reviewer 1 verdict:pending: verdict bead closed without explicit PASS"'),
            ev_ % ("15", "m", "FAIL", "9999", ',"reason":"Merge failed after all-PASS verdict. Merge result: failed_push_race."'),
            ev_ % ("15", "s", "FAIL", '"abc"', ',"reason":"source bead already closed"'),   # elapsed ilegível, mas num evento que nem entra na média: sem alarme
            ev_ % ("15", "n", "FAIL", "9999", ""),                                          # FAIL sem reason: sem parecer
            ev_ % ("15", "x", "FAIL", "9999", ',"reason":"o texto Reviewer 1 FAIL: VERDICT: FAIL no meio não é parecer"'),  # o painel usa .match: só vale no INÍCIO
            ev_ % ("14", "d", "PASS", "9999", ',"dry_run":"1"'),
            ev_ % ("14", "e", "ERROR", "9999", ""),
            '{"ts":"2026-10-10T14:00:00Z","event":"dispatcher_complete","result":"PASS","elapsed_s":9999}',
            ev_ % ("14", "f", "PASS", "0", ""),
            '{"ts":"2026-10-10T14:00:00Z","event":"dispatcher_complete","bead":"g","result":"PASS","elapsed_s":',
        ]
        open(g, "w").write("\n".join(rows) + "\n")
        evs, sv, bad = gate_events(g)
        ok(len(evs) == 3, f"filtro do painel: 3 eventos JULGADOS entram na média (vieram {len(evs)})")
        ok(abs(statistics.mean(m for _, m in evs) - 20.0) < 1e-6, f"média = 20 min, sem os 9999 s de espera dos sem-veredito (veio {statistics.mean(m for _, m in evs):.1f})")
        ok(len(sv) == 6, f"TIMEOUT, bead fechado, merge falho, 'source bead already closed', FAIL sem reason e reason com a frase no meio: 6 SEM VEREDITO contados (vieram {len(sv)})")
        ok(bad == 1, f"linha quebrada é CONTADA, não some; elapsed ilegível de sem-veredito NÃO alarma (bad={bad})")
        ok(epoch("lixo") is None and epoch(None) is None, "data ilegível dá None, não 0")
        # elapsed_s presente e ilegível, num evento que o painel contaria, é "não sei": CONTADO (bad), nunca vira "0 s" filtrado em silêncio
        base = '{"ts":"2026-10-10T12:00:00Z","event":"dispatcher_complete","bead":"a","result":"PASS",%s}'
        evs2, sv2, bad2 = gate_events_from_lines([base % '"elapsed_s":"abc"', base % '"elapsed_s":true', base % '"elapsed_s":NaN',
                                                  base % '"elapsed_s":Infinity', base % '"elapsed_s":[1]'])
        ok(not evs2 and not sv2 and bad2 == 5, f"elapsed_s texto, booleano, NaN, Infinity e lista: 5 CONTADOS, nenhum vira duração (evs={len(evs2)} bad={bad2})")
        evs3, sv3, bad3 = gate_events_from_lines([base % '"elapsed_s":null', base % '"x":1', base % '"elapsed_s":-5',
                                                  base.replace('"PASS"', '"ERROR"') % '"elapsed_s":"abc"',
                                                  base.replace('"result"', '"dry_run":"1","result"') % '"elapsed_s":"abc"',
                                                  base % '"elapsed_s":"90"'])
        ok(bad3 == 0 and not sv3 and len(evs3) == 1 and abs(evs3[0][1] - 1.5) < 1e-6,
           f"elapsed_s ausente/null/negativo e evento que o painel já exclui seguem filtrados sem alarme; \"90\" lê como 90 s (evs={len(evs3)} bad={bad3})")

        # dias: o dia é BRT (como o painel), não o fuso da máquina; sem-veredito tem coluna própria; dia só de sem-veredito não some; log sem evento contável é rc 2
        def run_dias(lines, days=7):
            p = os.path.join(t, "d.jsonl")
            open(p, "w").write("\n".join(lines) + ("\n" if lines else ""))
            o, e = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(o), contextlib.redirect_stderr(e):
                rc = cmd_dias(days, p)
            return rc, o.getvalue(), e.getvalue()
        tz0 = os.environ.get("TZ")
        if hasattr(time, "tzset"):  # máquina em UTC: com o dia no fuso LOCAL o evento de 02:30Z cairia em 10-10, e em BRT ele é 10-09
            os.environ["TZ"] = "UTC"
            time.tzset()
        try:
            ev_ts = ev_.replace("2026-10-10T%s:00:00Z", "%s")  # o mesmo evento, com o carimbo inteiro como 1º argumento
            rc, out, err = run_dias([ev_ts % ("2026-10-10T02:30:00Z", "a", "PASS", "600", ""),
                                     ev_ts % ("2026-10-10T12:00:00Z", "b", "PASS", "1800", ""),
                                     ev_ts % ("2026-10-11T12:00:00Z", "t", "FAIL", "3600", ',"reason":"TIMEOUT: x"')])
        finally:
            if hasattr(time, "tzset"):
                if tz0 is None:
                    os.environ.pop("TZ", None)
                else:
                    os.environ["TZ"] = tz0
                time.tzset()
        linhas = {l.split()[0]: l.split() for l in out.splitlines()[1:] if l.strip()}
        ok(rc == 0 and linhas.get("2026-10-09", [None, None])[1] == "1" and linhas.get("2026-10-10", [None, None])[1] == "1",
           f"dias: 02:30Z cai no dia 10-09 em BRT (e 12:00Z em 10-10), qualquer que seja o fuso da máquina (rc={rc}, dias={sorted(linhas)})")
        ok("2026-10-11" in linhas and linhas["2026-10-11"][1] == "0" and linhas["2026-10-11"][2] == "-" and linhas["2026-10-11"][-1] == "1",
           f"dias: dia só de sem-veredito aparece (0 revisões, média '-', 1 sem veredito), não some (linha={linhas.get('2026-10-11')})")
        rc, out, err = run_dias([])
        ok(rc == 2 and "NÃO é 'zero revisões'" in err, f"dias: log vazio = rc 2 e a mensagem, não uma tabela vazia que lê 'zero revisões' (rc={rc})")
        rc, out, err = run_dias([ev_ % ("12", "a", "PASS", '"abc"', "")])
        ok(rc == 2 and "1 evento(s)/linha(s) ilegíveis" in err, f"dias: só evento ilegível = rc 2, dizendo quantos (rc={rc}, err={err.strip()[:90]})")
        ok(cmd_dias(7, os.path.join(t, "nao-existe.jsonl")) == 2, "dias: log ausente = rc 2")

        # percentil: posto mais próximo, em inteiro — sem o round() par-para-par (6 amostras: p90 é o MÁXIMO, não o 5º)
        ok(pctl([1, 2, 3, 4, 5, 6], 90) == 6 and pctl(list(range(1, 11)), 90) == 9 and pctl([5], 90) == 5 and pctl([], 90) is None
           and pctl([3, 1, 2], 50) == 2 and pctl(list(range(1, 101)), 90) == 90, "pctl: p90 de 6 amostras = o máximo, de 10 = a 9ª, de 100 = a 90ª; vazio = None")

        # transcrição: 1 chamada de teste de 120 s, 1 chamada sem pytest de 300 s, 1 de teste sem resultado
        d = os.path.join(t, "tr"); os.makedirs(d)

        def ev(ts, content):
            return json.dumps({"timestamp": ts, "message": {"content": content}})
        lines = [
            ev("2026-10-12T10:00:00Z", [{"type": "text", "text": "oi"}]),
            ev("2026-10-12T10:01:00Z", [{"type": "tool_use", "id": "u1", "name": "Bash", "input": {"command": "python3 -m pytest tests/x.py"}}]),
            ev("2026-10-12T10:03:00Z", [{"type": "tool_result", "tool_use_id": "u1", "content": "ok"}]),
            ev("2026-10-12T10:03:10Z", [{"type": "tool_use", "id": "u2", "name": "Bash", "input": {"command": "sleep 300"}}]),
            ev("2026-10-12T10:08:10Z", [{"type": "tool_result", "tool_use_id": "u2", "content": "ok"}]),
            ev("2026-10-12T10:08:20Z", [{"type": "tool_use", "id": "u3", "name": "Bash", "input": {"command": "pytest -q"}}]),
            "isto não é json",
            "null",   # JSON válido que não é um evento: ilegível, contado, não um crash (`.get` num None)
            "7",
            "",       # linha em branco não é linha ilegível: não entra na conta
            ev("2026-10-12T10:10:00Z", [{"type": "text", "text": "fim"}]),
        ]
        p = os.path.join(d, "s1.jsonl"); open(p, "w").write("\n".join(lines) + "\n")
        st = session_stats(p)
        ok(st is not None and abs(st[1] - 10.0) < 1e-6, "sessão de 10 min")
        ok(st is not None and abs(st[2] - 2.0) < 1e-6, "esperando teste = 2 min (só a chamada com pytest; o sleep sem pytest não entra)")
        ok(st is not None and st[3] == 1 and st[4] == 1, "1 chamada casada, 1 sem resultado contada à parte")
        ok(st is not None and st[5] == 3, f"3 linhas ilegíveis (texto, null, número) CONTADAS, a em branco não (vieram {st[5] if st else None})")
        ok(session_stats(os.path.join(t, "nao-existe.jsonl")) is None, "arquivo ausente dá None")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rcs = cmd_sessoes(5, None, d)
        ok(rcs == 0 and "dica" in buf.getvalue() and "revisao_media_min" in buf.getvalue() and "wrapper" in buf.getvalue(),
           "sessoes: diz que a tabela é só uma dica e aponta a manchete (revisao_media_min + wrapper)")
        ok("3 linha(s) de transcrição ilegíveis" in buf.getvalue(), "sessoes: o aviso diz quantas linhas de transcrição foram puladas")
        ok(f"pasta lida: {d}" in buf.getvalue(), "sessoes: imprime a pasta lida acima da tabela (é UMA pasta, não um glob)")
        # DENTRO da linha: o que não tem o formato esperado é CONTADO (nem crash, nem some); linha sem carimbo e sem chamada (resumo) e `content` em texto são normais
        d2 = os.path.join(t, "tr2"); os.makedirs(d2)
        lines2 = [json.dumps(o) for o in (
            {"timestamp": "2026-10-12T10:00:00Z", "message": {"content": [{"type": "text", "text": "oi"}]}},
            {"type": "summary", "summary": "resumo sem carimbo e sem chamada"},                                                       # normal: não conta
            {"timestamp": "lixo", "message": {"content": [{"type": "tool_use", "id": "z1", "name": "Bash", "input": {"command": "pytest"}}]}},   # carimbo ilegível + chamada: 1
            {"timestamp": "2026-10-12T10:01:00Z", "message": "texto solto"},                                                          # message que não é objeto: 2
            {"timestamp": "2026-10-12T10:02:00Z", "message": {"content": [{"type": "tool_use", "id": "u1", "name": "Bash", "input": "pytest -q"}]}},   # input texto: 3
            {"timestamp": "2026-10-12T10:03:00Z", "message": {"content": [{"type": "tool_use", "id": "u2", "name": "Bash", "input": {"command": ["pytest"]}}]}},   # comando lista: 4
            {"timestamp": "2026-10-12T10:04:00Z", "message": {"content": [{"type": "tool_use", "id": ["u3"], "name": "Bash", "input": {"command": "pytest"}}]}},   # id lista: 5
            {"timestamp": "2026-10-12T10:05:00Z", "message": {"content": [{"type": "tool_result", "tool_use_id": ["u3"], "content": "ok"}]}},   # id ilegível no resultado: sem crash
            {"timestamp": "2026-10-12T10:06:00Z", "message": {"content": "prompt em texto"}},                                          # normal (o prompt do usuário é texto)
        )]
        p2 = os.path.join(d2, "s2.jsonl"); open(p2, "w").write("\n".join(lines2) + "\n")
        st2 = session_stats(p2)
        ok(st2 is not None and st2[5] == 5 and st2[3] == 0 and abs(st2[1] - 6.0) < 1e-6,
           f"session_stats: message/input/comando/id fora do formato e chamada de carimbo ilegível: 5 CONTADOS, sem crash; resumo e content em texto não (st={st2})")

        # opções: uma opção sem valor (último argumento), desconhecida, ou com valor inválido NÃO vira o padrão em silêncio ("sem corte", "desde sempre"): uso errado = rc 2
        def run_main(*args):
            e = io.StringIO()
            with contextlib.redirect_stderr(e), contextlib.redirect_stdout(io.StringIO()):
                r = main(["gate-review-test-time.py", *args])
            return r, e.getvalue()
        for args, frag in ((("wrapper", "--desde"), "--desde precisa de um valor"), (("sessoes", "--corte"), "--corte precisa de um valor"),
                           (("sessoes", "--n"), "--n precisa de um valor"), (("dias", "--dias"), "--dias precisa de um valor"),
                           (("wrapper", "--desde", "--n"), "--desde precisa de um valor"),
                           (("dias", "--dia", "3"), "desconhecid"), (("wrapper", "--desd=2026-10-12"), "desconhecid"), (("wrapper", "solto"), "desconhecid"),
                           (("dias", "--dias", "abc"), "--dias"), (("sessoes", "--n", "1.5"), "--n"),
                           # 0 e negativo são inteiros mas não são "nenhum" nem "tudo": `--dias 0` listava o histórico INTEIRO, `--dias -2` descartava dias, `--n 0` dava medição vazia
                           (("dias", "--dias", "0"), "--dias"), (("dias", "--dias", "-2"), "--dias"), (("sessoes", "--n", "0"), "--n"),
                           (("sessoes", "--n", "-1", "--corte", "2026-10-12T00:00:00Z"), "--n")):
            r, msg = run_main(*args)
            ok(r == 2 and frag in msg, f"uso errado {' '.join(args)}: rc 2 e a mensagem diz o motivo (rc={r}, '{msg.strip()[:70]}')")
        ok(int_opt({"--n": "3"}, "--n", 20) == 3 and int_opt({}, "--n", 20) == 20 and int_opt({"--dias": "1"}, "--dias", 7) == 1,
           "int_opt: inteiro >= 1 lido, ausente = o padrão do comando")
        ok(parse_opts(["--desde", "2026-10-12T00:00:00Z"], {"--desde"}) == {"--desde": "2026-10-12T00:00:00Z"} and parse_opts([], {"--desde"}) == {},
           "opções válidas e ausentes seguem: valor lido, ausente = {} (o padrão de cada comando)")

        # wrapper log
        w = os.path.join(t, "w.jsonl")
        open(w, "w").write('{"ts":"2026-10-12T10:00:00Z","session":"s","ran":"mbp","secs":10,"mbp_secs":10,"local_secs":0,"detail":""}\n'
                           '{"ts":"2026-10-12T10:01:00Z","session":"s","ran":"local","secs":30,"mbp_secs":0,"local_secs":30,"detail":"mbp-rc=98: x"}\nlixo\n')
        ok(cmd_wrapper(None, w) == 0, "wrapper: lê o log")
        ok(cmd_wrapper(None, os.path.join(t, "nao.jsonl")) == 2, "wrapper: log ausente = rc 2 (não finge zero execuções)")

        # linhas que são JSON válido mas não são um evento, segundos que não são número, data ilegível sob --desde: contadas, sem crash
        w2 = os.path.join(t, "w2.jsonl")
        open(w2, "w").write('\n   \n{"ts":"2026-10-12T10:00:00Z","session":"s","ran":"mbp","secs":10,"mbp_secs":10,"local_secs":0,"detail":""}\n'   # linhas em branco NÃO são ilegíveis
                            'null\n[1,2]\n\n7\n'
                            '{"ts":"2026-10-12T10:02:00Z","session":"s","ran":"local","secs":"muito","mbp_secs":0,"local_secs":0,"detail":""}\n'
                            '{"session":"s","ran":"local","secs":5,"mbp_secs":0,"local_secs":5,"detail":""}\n'
                            # segundos que FALTAM (null, chave ausente) ou são booleano não são 0 s: a linha é contada como ilegível, não como execução
                            '{"ts":"2026-10-12T10:03:00Z","session":"s","ran":"local","secs":null,"mbp_secs":0,"local_secs":0,"detail":""}\n'
                            '{"ts":"2026-10-12T10:04:00Z","session":"s","ran":"local","mbp_secs":0,"local_secs":0,"detail":""}\n'
                            '{"ts":"2026-10-12T10:05:00Z","session":"s","ran":"local","secs":true,"mbp_secs":0,"local_secs":0,"detail":""}\n'
                            '{"ts":"2026-10-12T10:06:00Z","session":"s","ran":"local","secs":7,"mbp_secs":null,"local_secs":7,"detail":""}\n')

        def run_wrapper(desde):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = cmd_wrapper(desde, w2)
            return rc, buf.getvalue()
        rc, out = run_wrapper(None)
        ok(rc == 0 and "execuções: 2 " in out and "mbp=1" in out and "local=1" in out, "wrapper: lixo não derruba e as 2 linhas boas entram")
        ok("8 linha(s) ilegíveis" in out, "wrapper: null, lista, número, segundos de lixo, null, ausente, booleano e mbp_secs null são CONTADOS (8)")
        ok("segundos: total=15 no MBP=10 aqui=5" in out, "wrapper: segundos ilegíveis não somam 0 nem entram na soma")
        rc, out = run_wrapper("2026-10-12T00:00:00Z")
        ok(rc == 0 and "execuções: 1 " in out and "9 linha(s) ilegíveis" in out, "wrapper --desde: linha sem data é contada, não some em silêncio")
        # `null` e `[]` não citam dispatcher_complete: irrelevantes, nem entram na conta. As duas últimas citam e não são objeto: contadas.
        evs, sv, bad = gate_events_from_lines(['null', '[]', '{"event":"dispatcher_complete","ts":"2026-10-10T12:00:00Z","bead":"a","result":"PASS","elapsed_s":60}',
                                               '"dispatcher_complete"', '["dispatcher_complete"]'])
        ok(len(evs) == 1 and bad == 2, f"gate: JSON que cita o evento e não é objeto é contado, não derruba (evs={len(evs)} bad={bad})")
    print("---")
    print("SELFTEST OK" if not fails else f"SELFTEST FALHOU ({fails})")
    return 0 if not fails else 1


class UsageError(Exception):
    pass


def parse_opts(args, allowed):
    """{opção: valor} das opções `--nome valor`. Opção sem valor (último argumento, ou seguida de outra opção), desconhecida ou solta é UsageError: a falta NUNCA
    cai no padrão em silêncio — `--desde` sem data leria o log "desde sempre" e `--corte` sem data, "sem corte", com a cara de uma medição de verdade."""
    out, i = {}, 0
    while i < len(args):
        a = args[i]
        if a not in allowed:
            raise UsageError(f"argumento desconhecido: {a} (aceita: {', '.join(sorted(allowed)) or 'nenhum'})")
        if i + 1 >= len(args) or args[i + 1].startswith("--"):
            raise UsageError(f"{a} precisa de um valor")
        out[a] = args[i + 1]
        i += 2
    return out


def int_opt(opts, name, default):
    """Opção ausente → o padrão do comando; presente e que não é inteiro >= 1 → UsageError. 0 e negativo são inteiros mas não são "nenhum" nem "tudo":
    `--dias 0` listaria o histórico inteiro (lista[-0:]), `--n -2` descartaria dias em silêncio, `--n 0` mostraria uma medição vazia."""
    if name not in opts:
        return default
    try:
        n = int(opts[name])
    except ValueError:
        n = 0
    if n < 1:
        raise UsageError(f"{name} precisa de um número inteiro >= 1 (veio '{opts[name]}')")
    return n


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[1] == "--selftest":
        return selftest()
    try:
        if argv[1] == "dias":
            return cmd_dias(int_opt(parse_opts(argv[2:], {"--dias"}), "--dias", 7))
        if argv[1] == "sessoes":
            o = parse_opts(argv[2:], {"--n", "--corte"})
            return cmd_sessoes(int_opt(o, "--n", 20), o.get("--corte"))
        if argv[1] == "wrapper":
            return cmd_wrapper(parse_opts(argv[2:], {"--desde"}).get("--desde"))
    except UsageError as e:
        print(f"{argv[1]}: {e}", file=sys.stderr)
        return 2
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
