#!/usr/bin/env python3
"""gate-review-test-time.py — antes×depois do tempo de teste por sessão de revisor do gate (ga-xm1jfl). Só LÊ.

Contents
  O que mede · Uso · Limites · Selftest

O QUE MEDE
  dias      revisao_media_min por dia: média/mediana/p90 de elapsed_s dos eventos dispatcher_complete de .gc/quality-gate.jsonl,
            com o MESMO filtro do painel (lib/produtividade_gate.py::_analisar_gate: sem dry_run, resultado PASS/FAIL, com bead,
            elapsed > 0). É a métrica que o Athos olha (15 -> 27 min em ga-bk5j8u).
  sessoes   por sessão de revisor (transcrições em ~/.claude/projects/*gate-reviewer): minutos totais e minutos ESPERANDO TESTE =
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
  Opção sem valor, desconhecida ou com valor inválido é uso errado (rc 2, com a mensagem): nunca cai no padrão em silêncio ("sem corte", "desde sempre").
  Linha de log ou de transcrição ilegível é pulada e CONTADA no aviso do fim, nunca some.

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
import os
import re
import statistics
import sys
import tempfile
from datetime import datetime, timezone

CITY = os.environ.get("GATE_PYTEST_CITY") or os.environ.get("GC_CITY_PATH") or "/Users/athos/gt/.gascity-gastown-hq"
TRANSCRIPTS = os.environ.get("GATE_REVIEW_TRANSCRIPTS") or os.path.expanduser(
    "~/.claude/projects/-Users-athos-gt--gascity-gastown-hq--gc-agents-gate-reviewer")
PYTEST_RX = re.compile(r"pytest")


def epoch(s):
    """ISO 8601 -> epoch; None quando não dá para ler (nunca 0: 'não sei' não é 'meia-noite de 1970')."""
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return None


def pctl(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p * (len(xs) - 1))))]


def fmt(v):
    return "-" if v is None else f"{v:.1f}"


def gate_events(path):
    """Eventos que o painel conta. Linha ilegível é pulada e CONTADA (devolvida), não some em silêncio."""
    out, bad = [], 0
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
            try:
                el = float(e.get("elapsed_s") or 0)
            except (TypeError, ValueError):
                el = 0.0
            if e.get("event") != "dispatcher_complete" or str(e.get("dry_run")) == "1" or res not in ("PASS", "FAIL") \
                    or ts is None or not e.get("bead") or el <= 0:
                continue
            out.append((ts, el / 60.0))
    return out, bad


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
        evs, bad = gate_events(path)
    except OSError as e:
        print(f"dias: não consegui ler {path}: {e}", file=sys.stderr)
        return 2
    by = {}
    for ts, m in evs:
        by.setdefault(datetime.fromtimestamp(ts).strftime("%Y-%m-%d"), []).append(m)
    print(f"{'dia':<11}{'revisões':>9}{'média min':>11}{'mediana':>9}{'p90':>7}")
    for d in sorted(by)[-days:]:
        xs = by[d]
        print(f"{d:<11}{len(xs):>9}{fmt(statistics.mean(xs)):>11}{fmt(statistics.median(xs)):>9}{fmt(pctl(xs, 0.9)):>7}")
    if bad:
        print(f"(aviso: {bad} linha(s) dispatcher_complete ilegíveis foram puladas)")
    return 0


def session_stats(path):
    """(início_epoch, minutos_totais, minutos_esperando_teste, nº de chamadas de teste, chamadas sem resultado, linhas ilegíveis) ou None.
    Linha que não é JSON, ou é JSON que não é um objeto (`null`, um número), é pulada e CONTADA (último campo), nunca some em silêncio nem derruba a leitura;
    linha em branco não conta."""
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
            if ts is None:
                continue
            first = ts if first is None else min(first, ts)
            last = ts if last is None else max(last, ts)
            c = (o.get("message") or {}).get("content")
            if not isinstance(c, list):
                continue
            for b in c:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use" and b.get("name") == "Bash":
                    cmd = (b.get("input") or {}).get("command") or ""
                    if PYTEST_RX.search(cmd):
                        uses[b.get("id")] = ts
                elif b.get("type") == "tool_result" and b.get("tool_use_id") in uses:
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
        # gate: 3 válidos no mesmo dia + dry_run + resultado ERROR + sem bead + elapsed 0 + linha quebrada
        g = os.path.join(t, "qg.jsonl")
        rows = [
            '{"ts":"2026-10-10T12:00:00Z","event":"dispatcher_complete","bead":"a","result":"PASS","elapsed_s":600}',
            '{"ts":"2026-10-10T13:00:00Z","event":"dispatcher_complete","bead":"b","result":"FAIL","elapsed_s":1200}',
            '{"ts":"2026-10-10T14:00:00Z","event":"dispatcher_complete","bead":"c","result":"PASS","elapsed_s":1800}',
            '{"ts":"2026-10-10T14:00:00Z","event":"dispatcher_complete","bead":"d","result":"PASS","elapsed_s":9999,"dry_run":"1"}',
            '{"ts":"2026-10-10T14:00:00Z","event":"dispatcher_complete","bead":"e","result":"ERROR","elapsed_s":9999}',
            '{"ts":"2026-10-10T14:00:00Z","event":"dispatcher_complete","result":"PASS","elapsed_s":9999}',
            '{"ts":"2026-10-10T14:00:00Z","event":"dispatcher_complete","bead":"f","result":"PASS","elapsed_s":0}',
            '{"ts":"2026-10-10T14:00:00Z","event":"dispatcher_complete","bead":"g","result":"PASS","elapsed_s":',
        ]
        open(g, "w").write("\n".join(rows) + "\n")
        evs, bad = gate_events(g)
        ok(len(evs) == 3, f"filtro do painel: 3 eventos válidos (vieram {len(evs)})")
        ok(bad == 1, f"linha quebrada é CONTADA, não some (bad={bad})")
        ok(abs(statistics.mean(m for _, m in evs) - 20.0) < 1e-6, "média = 20 min")
        ok(epoch("lixo") is None and epoch(None) is None, "data ilegível dá None, não 0")

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
                           (("dias", "--dias", "abc"), "--dias"), (("sessoes", "--n", "1.5"), "--n")):
            r, msg = run_main(*args)
            ok(r == 2 and frag in msg, f"uso errado {' '.join(args)}: rc 2 e a mensagem diz o motivo (rc={r}, '{msg.strip()[:70]}')")
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
        open(w2, "w").write('{"ts":"2026-10-12T10:00:00Z","session":"s","ran":"mbp","secs":10,"mbp_secs":10,"local_secs":0,"detail":""}\n'
                            'null\n[1,2]\n7\n'
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
        evs, bad = gate_events_from_lines(['null', '[]', '{"event":"dispatcher_complete","ts":"2026-10-10T12:00:00Z","bead":"a","result":"PASS","elapsed_s":60}',
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
    try:
        return int(opts[name]) if name in opts else default
    except ValueError:
        raise UsageError(f"{name} precisa de um número inteiro (veio '{opts[name]}')")


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
