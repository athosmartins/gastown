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
            do painel). Duas diferenças de propósito, as duas CONTADAS no aviso em vez de sumirem: (1) elapsed_s que não se lê num evento julgado
            (texto, `true`, [] ou {}, NaN, Infinity, inteiro que não cabe em float — o painel lê como 0 s, 1 s ou infinito); (2) evento que o painel
            contaria mas cujo ts não se lê (ausente, ilegível, sem fuso, fora do que o dia BRT calcula) — o painel o descarta sem dizer.
            --dias N são os últimos N dias QUE TÊM evento, não N dias de calendário: um buraco no log alarga o intervalo (a coluna da data mostra).
            É a métrica que o Athos olha (15 -> 27 min em ga-bk5j8u).
  sessoes   por sessão de revisor (transcrições em UMA pasta, ~/.claude/projects/-Users-athos-gt--gascity-gastown-hq--gc-agents-gate-reviewer;
            GATE_REVIEW_TRANSCRIPTS troca a pasta; as vizinhas — refino-gate-reviewer, sessões ad hoc em /private/tmp — NÃO entram, e a
            pasta lida é impressa acima da tabela): minutos totais e minutos ESPERANDO TESTE =
            soma da duração das chamadas Bash cujo comando cita pytest (python3 -m pytest, gate-pytest.sh, tail/sleep em log de pytest
            que o comando nomeia). --corte <ISO> parte as sessões em antes/depois do deploy do wrapper e compara as médias.
            O que a tabela NÃO consegue medir é DITO no aviso, nunca some: sessão cuja chamada de teste nunca voltou (sem duração, fica fora
            da média — e é justamente a espera mais longa), arquivo de transcrição que não abre, linha ilegível. Se NENHUMA sessão entra na
            tabela, o rc 2 diz qual dessas coisas aconteceu: "chamada que nunca voltou" não é "ninguém rodou teste".
            É uma DICA, não a medida (veja LIMITES): a medida é `dias` (revisao_media_min) e `wrapper` (os segundos que o próprio
            wrapper registra).
  wrapper   o que o gate-pytest.sh registrou em .gc/logs/gate-pytest.jsonl: execuções por destino (mbp, local, mbp+local), segundos
            no MBP e aqui, e os motivos de rodar aqui. Só existe depois do deploy.

USO
  gate-review-test-time.py dias [--dias 7]
  gate-review-test-time.py sessoes [--n 20] [--corte 2026-10-12T06:00:00Z]
  gate-review-test-time.py wrapper [--desde 2026-10-12T06:00:00Z]
  gate-review-test-time.py --selftest
  Opção sem valor, desconhecida ou com valor inválido (--dias e --n: inteiro >= 1; 0 e negativo não são "nenhum" nem "tudo"; --corte e --desde:
  data ISO COM fuso, 2026-10-12T06:00:00Z ou ...-03:00 — sem fuso seria lida na zona da máquina, e o dia do `dias` é BRT) é uso errado
  (rc 2, com a mensagem): nunca cai no padrão em silêncio ("sem corte", "desde sempre") nem vira uma medição vazia.
  Linha de log ou de transcrição ilegível é pulada e CONTADA no aviso do fim, nunca some; transcrição que nem abre também é contada. `dias` sem NENHUM evento contável (log vazio,
  girado, formato mudado) é rc 2 com a mensagem — "não consegui medir" não é "zero revisões".

LIMITES
  "Esperando teste" é um LIMITE INFERIOR: uma espera que o comando não rotula como pytest (sleep 60; tail $S/t1.log) não entra. A
  definição NÃO é a mesma antes e depois: antes o revisor esperava com nomes que ele mesmo escolhia, e depois o comando do wrapper
  cita gate-pytest.sh mas o poll dele (sleep 30; tail $S/gp.log) não cita nada — então o "depois" pode parecer melhor do que é.
  Por isso a tabela de `sessoes` é só uma dica; a manchete é revisao_media_min (`dias`) e os segundos do wrapper (`wrapper`),
  que não dependem de como o revisor batiza o log. A duração de cada chamada é a
  diferença entre o carimbo do tool_use e o do tool_result na transcrição; chamada sem resultado casado não conta na soma (e é contada à parte,
  de TODA sessão lida, também das que saem da tabela por causa dela).
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
    """ISO 8601 COM fuso (Z ou ±hh:mm) -> epoch; None quando não dá para ler (nunca 0: 'não sei' não é 'meia-noite de 1970').
    Data SEM fuso também é None: lida na zona da máquina ela cairia numa zona que ninguém escolheu, e o dia do `dias` é BRT. Data que o dia BRT não
    calcula (ano 1, ano 10000 depois do fuso) também é None: aceitá-la derrubaria o `dias` inteiro por uma linha estragada."""
    try:
        dt = datetime.fromisoformat(str(s).replace("Z", "+00:00"))
        if dt.tzinfo is None:
            return None
        ts = dt.timestamp()
        datetime.fromtimestamp(ts, BRT)
        return ts
    except (TypeError, ValueError, OverflowError, OSError):
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
            if e.get("event") != "dispatcher_complete" or str(e.get("dry_run")) == "1" or res not in ("PASS", "FAIL") or not e.get("bead"):
                continue  # o painel não conta este evento (outro evento, dry_run, resultado que não é PASS/FAIL, sem bead): fora, sem alarme
            if ts is None:  # o painel contaria o evento e eu não sei em que dia ele cai (ts ausente, ilegível ou sem fuso): CONTADO, não some
                bad += 1
                continue
            # vazio (sem reason) → FAIL sem parecer: "sem veredito", CONTADO fora da média; ilegível (reason que não é texto) → str() não casa, mesmo destino: nunca "julgado" por engano
            if res != "PASS" and not RX_JULGADO.match(str(e.get("reason") or "")):
                sem_veredito.append(ts)
                continue
            # vazio (ausente, null, "") e 0/negativo → fora da média sem alarme (o painel também os tira); falhou/ilegível ([] e {} incluídos, que são falsos mas NÃO são vazios) → CONTADO em `bad`, nunca vira "0 s" filtrado em silêncio
            raw = e.get("elapsed_s")
            try:
                el = 0.0 if raw is None or raw == "" else float(raw)
                if isinstance(raw, bool) or not math.isfinite(el):  # `true` não é 1 s e NaN/Infinity não é duração
                    el = None
            except (TypeError, ValueError, OverflowError):  # OverflowError: inteiro que não cabe em float (mesmo caso que cmd_wrapper já trata)
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
        print(f"(aviso: {bad} evento(s)/linha(s) dispatcher_complete ilegíveis ficaram de fora: JSON quebrado ou que não é objeto, ts que não se lê, ou julgado com elapsed_s que não se lê)")
    return 0


def session_stats(path):
    """(início_epoch, minutos_totais, minutos_esperando_teste, nº de chamadas de teste, chamadas sem resultado, linhas ilegíveis) ou None.
    TRÊS estados, que quem chama NÃO pode misturar: None = o arquivo não abriu (OSError: "não consegui saber"); início None = abriu, mas não tem nenhum
    carimbo legível (arquivo vazio, ou só lixo: as linhas ilegíveis dele continuam no último campo, não somem junto); início de verdade = a sessão.
    Linha que não é JSON, ou é JSON que não é um objeto (`null`, um número), é pulada e CONTADA (último campo), nunca some em silêncio nem derruba a leitura;
    o mesmo vale para o que está DENTRO dela e não tem o formato esperado (`message` que não é objeto, chamada Bash sem comando em texto, chamada de teste com id que não é texto; um resultado com id ilegível não casa, e a chamada dele cai em "sem resultado casado")
    e para a linha de carimbo ilegível que carrega chamada de ferramenta (ela sairia da soma sem rastro). Linha em branco, e linha sem carimbo e sem
    chamada (resumo, snapshot), não contam."""
    uses, first, last, wait, runs, unmatched, bad = {}, None, None, 0.0, 0, 0, 0
    # arquivo vazio → abre, sem carimbo, nada a contar; falhou (não abre) → None: o chamador CONTA o arquivo que ficou de fora, nunca o trata como sessão vazia
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
    if first is None or last is None:  # nenhum carimbo legível: sem sessão para medir, mas as linhas ilegíveis que ela teve continuam contadas (uses está vazio: só se guarda chamada com carimbo)
        return None, 0.0, 0.0, 0, 0, bad
    return first, (last - first) / 60.0, wait / 60.0, runs, unmatched, bad


def cmd_sessoes(n, corte, dirpath=None):
    dirpath = dirpath or TRANSCRIPTS
    c = None
    if corte is not None:  # uso errado se diz ANTES de ler as transcrições: pasta vazia ou sem teste não pode mascará-lo como "nenhuma sessão achada"
        c = epoch(corte)
        if c is None:
            print(f"sessoes: --corte '{corte}' não é uma data ISO com fuso (termine em Z ou use ±hh:mm; sem fuso seria lida numa zona que ninguém escolheu)", file=sys.stderr)
            return 2
    files = sorted(glob.glob(os.path.join(dirpath, "*.jsonl")), key=os.path.getmtime, reverse=True)
    rows, badl, ilegiveis, sem_volta, un = [], 0, 0, 0, 0
    for f in files:
        st = session_stats(f)
        # vazio (sem carimbo, sem teste) → fora da tabela, sem alarme; falhou (o arquivo não abre) → CONTADO em `ilegiveis`, nunca tratado como "sessão sem teste"
        if st is None:
            ilegiveis += 1
            continue
        badl += st[5]  # de TODA sessão lida, também das que saem da tabela: uma linha estragada pode estar escondendo a chamada de teste que a poria nela
        un += st[4]    # idem as chamadas de teste que nunca voltaram: a sessão pode cair da tabela inteira, e é aí que a espera mais longa (revisor morto esperando) se esconderia
        if st[0] is not None and st[3] > 0:  # só sessões que rodaram teste e cuja duração se lê: sem teste não há o que comparar
            rows.append(st)
        elif st[4] > 0:  # chamada de teste existiu, mas nenhuma voltou: sem duração a sessão não entra na média — fica FORA da tabela e é DITO, não confundida com "não rodou teste"
            sem_volta += 1
        if len(rows) >= n and corte is None:
            break
    avisos = []
    if ilegiveis:
        avisos.append(f"{ilegiveis} arquivo(s) de transcrição não puderam ser lidos (permissão ou erro de leitura) e ficaram FORA")
    if sem_volta:
        avisos.append(f"{sem_volta} sessão(ões) ficaram FORA da tabela: nenhuma chamada de teste delas voltou com resultado (o revisor pode ter morrido esperando o teste, a espera mais longa)")
    if un:
        avisos.append(f"{un} chamada(s) de teste sem resultado casado na transcrição não entraram na soma")
    if badl:
        avisos.append(f"{badl} linha(s) de transcrição ilegíveis foram puladas")
    if not rows:
        print(f"sessoes: nenhuma sessão de revisor com teste achada em {dirpath}"
              + ("; " + "; ".join(avisos) + " — isto NÃO é 'ninguém rodou teste'" if avisos else ""), file=sys.stderr)
        return 2
    if corte is None:
        groups = [("últimas %d sessões com teste" % len(rows), rows)]
    else:
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
    for a in avisos:
        print(f"(aviso: {a})")
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
        print(f"wrapper: --desde '{desde}' não é uma data ISO com fuso (termine em Z ou use ±hh:mm; sem fuso seria lida numa zona que ninguém escolheu)", file=sys.stderr)
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
            # execução sem `detail` (todas as só-MBP) não tem motivo de rodar aqui: balde com nome próprio, não um "-" que lê como motivo; detail que a regex apagaria inteiro fica como veio
            primeiro = str(e.get("detail") or "").split(";")[0]
            key = re.sub(r"[:(].*$", "", primeiro) or primeiro or "(sem detalhe)"
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
        # presente e VAZIO ([] / {}) é ilegível, não "0 s": `raw or 0` os apagava em silêncio, e só ausente, null e "" são vazios de verdade; inteiro enorme não derruba o `dias` (OverflowError)
        evs4, sv4, bad4 = gate_events_from_lines([base % '"elapsed_s":[]', base % '"elapsed_s":{}', base % ('"elapsed_s":' + "9" * 400)])
        ok(not evs4 and not sv4 and bad4 == 3, f"elapsed_s [], {{}} e inteiro de 400 dígitos: 3 CONTADOS, sem crash e sem virar \"0 s\" filtrado (evs={len(evs4)} bad={bad4})")
        evs5, sv5, bad5 = gate_events_from_lines([base % '"elapsed_s":""', base % '"elapsed_s":0', base % '"elapsed_s":0.0'])
        ok(not evs5 and not sv5 and bad5 == 0, f"elapsed_s \"\", 0 e 0.0 são vazios de verdade: filtrados sem alarme (evs={len(evs5)} bad={bad5})")
        # ts ausente/ilegível num evento que o painel contaria (PASS/FAIL, com bead, sem dry_run) é "não sei o dia": CONTADO, não some; o que o painel já exclui segue sem alarme
        tsb = '{%s"event":"dispatcher_complete","bead":"a","result":"%s","elapsed_s":60%s}'
        evs6, sv6, bad6 = gate_events_from_lines([tsb % ('"ts":"lixo",', "PASS", ""), tsb % ("", "PASS", ""), tsb % ('"ts":"2026-10-10T12:00:00",', "PASS", ""),
                                                  tsb % ('"ts":"lixo",', "FAIL", ',"reason":"TIMEOUT: x"')])
        ok(not evs6 and not sv6 and bad6 == 4, f"ts ilegível, ausente ou sem fuso (PASS e FAIL sem veredito): 4 CONTADOS, nenhum some (evs={len(evs6)} sv={len(sv6)} bad={bad6})")
        evs7, sv7, bad7 = gate_events_from_lines([tsb % ('"ts":"lixo",', "ERROR", ""), tsb % ('"ts":"lixo",', "PASS", ',"dry_run":"1"')])
        ok(not evs7 and not sv7 and bad7 == 0, f"ts ilegível num evento que o painel já exclui (ERROR, dry_run) segue sem alarme (bad={bad7})")
        # data sem fuso não é lida na zona da máquina (o dia do `dias` é BRT; --corte "sem fuso" cairia numa zona que ninguém escolheu): None, e quem pediu a data ouve rc 2
        ok(epoch("2026-10-12T06:00:00Z") is not None and epoch("2026-10-12T03:00:00-03:00") == epoch("2026-10-12T06:00:00Z"), "epoch: data com fuso (Z ou +hh:mm) lê")
        ok(epoch("2026-10-12T06:00:00") is None and epoch("2026-10-12") is None, "epoch: data SEM fuso dá None, não a zona da máquina")

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
        # ts que a data aceita mas o dia BRT não calcula (ano 1, ano 10000 depois do fuso): é ilegível — CONTADO, o `dias` não morre com traceback por UMA linha estragada
        try:
            rc, out, err = run_dias([ev_ts % ("0001-01-01T00:00:00Z", "a", "PASS", "600", ""), ev_ts % ("9999-12-31T23:59:59-14:00", "c", "FAIL", "600", ',"reason":"TIMEOUT: x"'),
                                     ev_ts % ("2026-10-10T12:00:00Z", "b", "PASS", "600", "")])
        except Exception as ex:  # o crash vira FALHA com nome, não derruba o resto do selftest
            rc, out, err = None, "", f"{type(ex).__name__}: {ex}"
        ok(rc == 0 and "2026-10-10" in out and "2 evento(s)/linha(s)" in out, f"dias: ts fora do que o dia BRT calcula = 2 CONTADOS, sem crash, a linha boa segue (rc={rc}, err={err.strip()[:70]})")

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

        # sessoes: o que NÃO se consegue medir é DITO, nunca some da tabela em silêncio. a.jsonl = uma chamada de teste que nunca voltou (revisor morto no meio da espera, a maior de todas);
        # b.jsonl = uma chamada casada de 2 min; ok.jsonl igual; um DIRETÓRIO chamado *.jsonl = arquivo que não abre (open() dá OSError até como root, ao contrário de chmod 000)
        def run_sessoes(dirpath, n=5, corte=None):
            o, e = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(o), contextlib.redirect_stderr(e):
                rc = cmd_sessoes(n, corte, dirpath)
            return rc, o.getvalue(), e.getvalue()

        def sess_dir(name, **arquivos):
            dd = os.path.join(t, name); os.makedirs(dd)
            for fname, conteudo in arquivos.items():
                if conteudo is None:
                    os.makedirs(os.path.join(dd, fname + ".jsonl"))
                else:
                    open(os.path.join(dd, fname + ".jsonl"), "w").write(conteudo)
            return dd
        sem_volta = "\n".join([ev("2026-10-12T10:00:00Z", [{"type": "text", "text": "oi"}]),
                               ev("2026-10-12T10:01:00Z", [{"type": "tool_use", "id": "k1", "name": "Bash", "input": {"command": "python3 -m pytest tests/x.py"}}]),
                               ev("2026-10-12T10:40:00Z", [{"type": "text", "text": "fim"}])]) + "\n"
        casada = "\n".join([ev("2026-10-12T11:00:00Z", [{"type": "text", "text": "oi"}]),
                            ev("2026-10-12T11:01:00Z", [{"type": "tool_use", "id": "k2", "name": "Bash", "input": {"command": "python3 -m pytest tests/y.py"}}]),
                            ev("2026-10-12T11:03:00Z", [{"type": "tool_result", "tool_use_id": "k2", "content": "ok"}]),
                            ev("2026-10-12T11:10:00Z", [{"type": "text", "text": "fim"}])]) + "\n"
        rc, out, err = run_sessoes(sess_dir("tr3", a=sem_volta, b=casada))
        ok(rc == 0 and "1 sessão(ões) ficaram FORA da tabela" in out and "1 chamada(s) de teste sem resultado casado" in out and "últimas 1 sessões com teste" in out,
           f"sessoes: sessão cuja única chamada de teste nunca voltou fica FORA da tabela e o aviso DIZ (rc={rc}, aviso={[l for l in out.splitlines() if 'aviso' in l]})")
        rc, out, err = run_sessoes(sess_dir("tr4", a=sem_volta))
        ok(rc == 2 and "1 sessão(ões) ficaram FORA da tabela" in err and "NÃO é" in err,
           f"sessoes: só a sessão cuja chamada nunca voltou: rc 2, e a mensagem NÃO lê como 'ninguém rodou teste' (rc={rc}, err={err.strip()[:120]})")
        rc, out, err = run_sessoes(sess_dir("tr5"))
        ok(rc == 2 and "nenhuma sessão de revisor com teste" in err and "NÃO é" not in err and "FORA" not in err,
           f"sessoes: pasta sem transcrição nenhuma segue sendo 'nenhuma sessão com teste', sem aviso inventado (rc={rc}, err={err.strip()[:100]})")
        rc, out, err = run_sessoes(sess_dir("tr6", ok=casada, locked=None))
        ok(rc == 0 and "1 arquivo(s) de transcrição não puderam ser lidos" in out,
           f"sessoes: transcrição que não abre (OSError) é CONTADA no aviso, não some como se fosse vazia (rc={rc}, aviso={[l for l in out.splitlines() if 'aviso' in l]})")
        rc, out, err = run_sessoes(sess_dir("tr7", locked=None))
        ok(rc == 2 and "1 arquivo(s) de transcrição não puderam ser lidos" in err and "NÃO é" in err,
           f"sessoes: só transcrição ilegível: rc 2 dizendo que não leu, não 'ninguém rodou teste' (rc={rc}, err={err.strip()[:120]})")
        # transcrição sem NENHUM carimbo legível: não dá para medir, mas as linhas ilegíveis dela continuam CONTADAS (antes o None as levava embora); arquivo vazio é vazio
        lixo = sess_dir("tr8", ok=casada, lixo="isto não é json\n{quebrado\n", vazio="")
        stg = session_stats(os.path.join(lixo, "lixo.jsonl"))
        ok(stg is not None and stg[0] is None and stg[5] == 2, f"session_stats: arquivo só de lixo abre, não tem início e CONTA as 2 linhas ilegíveis (st={stg})")
        ste = session_stats(os.path.join(lixo, "vazio.jsonl"))
        ok(ste is not None and ste[0] is None and ste[5] == 0, f"session_stats: arquivo vazio abre, sem início e sem linha ilegível (st={ste})")
        rc, out, err = run_sessoes(lixo)
        ok(rc == 0 and "2 linha(s) de transcrição ilegíveis" in out and "arquivo(s) de transcrição não puderam" not in out,
           f"sessoes: as linhas ilegíveis de um arquivo sem carimbo aparecem no aviso; arquivo vazio não alarma (rc={rc}, aviso={[l for l in out.splitlines() if 'aviso' in l]})")
        # --corte inválido é uso errado ANTES de ler as transcrições: pasta vazia não pode mascará-lo como 'nenhuma sessão achada'; data sem fuso também
        for corte_ruim in ("lixo", "2026-10-12T06:00:00", "2026-10-12"):
            rc, out, err = run_sessoes(sess_dir("tr9-" + str(len(corte_ruim))), 5, corte_ruim)
            ok(rc == 2 and "--corte" in err and "nenhuma sessão" not in err, f"sessoes: --corte {corte_ruim!r} inválido/sem fuso: rc 2 nomeando --corte (rc={rc}, err={err.strip()[:100]})")
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
        with contextlib.redirect_stderr(io.StringIO()):
            rcd = (cmd_wrapper("2026-10-12T06:00:00", w), cmd_wrapper("2026-10-12", w))
        ok(rcd == (2, 2), f"wrapper: --desde sem fuso = rc 2, não lido na zona da máquina (rc={rcd})")
        # a execução sem `detail` (todas as só-MBP) não é um "motivo de rodar aqui": o balde tem nome próprio, não um '-' que parece um motivo
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            cmd_wrapper(None, w)
        ok("(sem detalhe)=1" in buf.getvalue() and "mbp-rc=98=1" in buf.getvalue() and "-=1" not in buf.getvalue(),
           f"wrapper: execução sem detail aparece como '(sem detalhe)', não como motivo '-' ({[l for l in buf.getvalue().splitlines() if l.startswith('motivos')]})")

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
