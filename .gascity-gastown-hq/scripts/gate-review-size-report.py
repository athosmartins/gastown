#!/usr/bin/env python3
"""gate-review-size-report — correlaciona TAMANHO DO DIFF com VEREDITO do gate (ga-ub8yq).

POR QUE EXISTE
--------------
A literatura de code review (Cisco/SmartBear, 2.500 revisões / 3,2M linhas) mostra que
acima de ~400 linhas a detecção de defeitos despenca. Medimos a nossa distribuição e 33%
das revisões estão acima disso (p90=1000, p99=2400).

Mas o número que DECIDE o limiar não é a distribuição — é a correlação
tamanho x taxa de reprovação. Se o FAIL rate CAI nos diffs grandes, isso é evidência de
que o revisor DEGRADA (não de que código grande é mais limpo), e aí o gate de tamanho se
justifica com dado nosso em vez de por analogia com um estudo de 2006.

Essa correlação era IMPOSSÍVEL antes: a linha de log que traz o tamanho não carregava o
identificador do run, só o bead — e um bead que falha e é refeito gera VÁRIAS linhas de
tamanho (uma por tentativa) casadas com o veredito por heurística de substring de branch,
o que pareia o tamanho da tentativa ERRADA com o veredito de outra. A mudança que
acompanha este script (a linha nova "Gate-run size: gate_run=...") resolve isso: cada
tentativa vira um gate_run id ÚNICO, o mesmo que já aparece na linha "Gate run complete:
gate_run=...". Casar as duas por esse id — sem heurística nenhuma — é o que torna a
correlação possível. Este relatório só tem dado ÚTIL a partir da data em que essa mudança
entrou em produção.

O QUE ELE NÃO FAZ
-----------------
Não decide, não muda limiar, não alarma. Emite um relatório para o Mayor decidir. Um
alarme a mais nesta cidade seria contraproducente (ver ga-ysc82: vigilância calibrada pra
pipeline saudável vira ruído quando a fila cresce).
"""
import os
import re
import sys

CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
LOG = os.path.join(CITY, ".gc/logs/quality-gate-dispatcher.log")

# Faixas escolhidas em torno do limiar da literatura (400) para que o relatório mostre
# o degrau, se ele existir, em vez de médias que o escondem.
BUCKETS = [(0, 200), (200, 400), (400, 800), (800, 2000), (2000, 10**9)]

# Ambas as linhas carregam gate_run=<id> — ÚNICO por tentativa — e é a ÚNICA chave usada
# para parear. Nenhuma heurística de bead/branch: runs se intercalam no log (uma run pode
# terminar no meio de outra) e um bead falho-e-refeito gera várias linhas de tamanho, uma
# por tentativa — só o gate_run id distingue qual tamanho vai com qual veredito.
SIZE_RE = re.compile(r"Gate-run size: gate_run=(\S+) bead=(\S+) files=(\d+) lines=(\d+)")
VERDICT_RE = re.compile(r"Gate run complete: gate_run=(\S+) branch=(\S+) verdict=(\w+)")


def main() -> int:
    if not os.path.exists(LOG):
        print("FALHA: log do dispatcher não encontrado em %s" % LOG, file=sys.stderr)
        return 1

    size_by_run = {}
    verdict_by_run = {}

    for ln in open(LOG, errors="ignore"):
        m = SIZE_RE.search(ln)
        if m:
            run, _bead, _files, lines = m.groups()
            size_by_run[run] = int(lines)
            continue
        v = VERDICT_RE.search(ln)
        if v:
            run, _branch, verdict = v.groups()
            verdict_by_run[run] = verdict

    # Junção ÚNICA e SEM heurística: mesmo gate_run id nas duas linhas.
    pairs = [
        (size_by_run[r], verdict_by_run[r])
        for r in verdict_by_run
        if r in size_by_run
    ]
    # Runs abortadas (size logada mas o run nunca finalizou -> sem linha de veredito)
    # e vereditos de antes desta mudança entrar em produção (sem linha de size
    # correspondente) são descartados do pareamento, nunca casados com um run alheio.
    sizes_sem_veredito = sum(1 for r in size_by_run if r not in verdict_by_run)
    veredito_sem_size = sum(1 for r in verdict_by_run if r not in size_by_run)

    print("=" * 68)
    print(" RELATÓRIO tamanho-do-diff x veredito do gate (ga-ub8yq)")
    print("=" * 68)

    # ── Distribuição: sempre disponível, não depende da correlação ────────────
    sizes = sorted(size_by_run.values())
    if sizes:
        def pct(p):
            return sizes[min(int(len(sizes) * p), len(sizes) - 1)]
        print("\nDISTRIBUIÇÃO (n=%d tentativas)" % len(sizes))
        print("  p50=%d  p75=%d  p90=%d  p95=%d  p99=%d"
              % (pct(.5), pct(.75), pct(.9), pct(.95), pct(.99)))
        acima = sum(1 for s in sizes if s > 400)
        print("  acima de 400 linhas: %d (%d%%) — limite útil da literatura"
              % (acima, acima * 100 // len(sizes)))
    else:
        print("\nDISTRIBUIÇÃO: SEM DADOS.")
        print("  Provável causa: o log ainda não tem linhas no formato novo")
        print("  ('Gate-run size: gate_run=...'). Ele só passa a existir DEPOIS que a")
        print("  mudança do ga-ub8yq entrar em produção. Isto NÃO é 'tudo certo' — é")
        print("  'ainda não mede'.")

    # ── A correlação: é o entregável ──────────────────────────────────────────
    print("\nCORRELAÇÃO tamanho x reprovação (n=%d runs pareados; %d size sem veredito"
          " descartada(s), %d veredito sem size descartado(s))"
          % (len(pairs), sizes_sem_veredito, veredito_sem_size))
    if not pairs:
        print("  SEM PARES. Não conclua nada daqui — não é 'sem problema',")
        print("  é 'sem medição'. Se a distribuição acima tem dados mas isto")
        print("  está vazio, a junção por gate_run falhou e o script é que")
        print("  precisa de conserto.")
    else:
        for lo, hi, in [(b[0], b[1]) for b in BUCKETS]:
            grupo = [v for sz, v in pairs if lo <= sz < hi]
            if not grupo:
                continue
            fails = sum(1 for v in grupo if v == "FAIL")
            rot = "%5d-%-5s" % (lo, hi if hi < 10**9 else "inf")
            print("  %s linhas: n=%-4d FAIL=%d%%" % (rot, len(grupo), fails * 100 // len(grupo)))
        print("\nCOMO LER:")
        print("  FAIL rate CAINDO conforme o diff cresce  -> o revisor está DEGRADANDO;")
        print("     o gate de tamanho se justifica (fatiar, não revisar com mais afinco).")
        print("  FAIL rate ESTÁVEL ou SUBINDO             -> a revisão aguenta o tamanho;")
        print("     o limiar de 400 NÃO se aplica a nós e o passo (2) do ga-ub8yq cai.")
        print("  n pequeno em alguma faixa                -> não conclua sobre ela.")

    print("\nPRÓXIMA AÇÃO: registrar a leitura em ga-ub8yq e decidir o passo (2).")
    print("Este relatório NÃO decide nem alarma — é insumo.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
