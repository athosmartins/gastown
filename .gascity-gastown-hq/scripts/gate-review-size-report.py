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
identificador do run. A mudança que acompanha este script (marker=/bead= nas duas linhas
de `scaled ...`) é o que a torna possível — daí este relatório só ter dado ÚTIL a partir
da data em que aquela mudança entrou em produção.

O QUE ELE NÃO FAZ
-----------------
Não decide, não muda limiar, não alarma. Emite um relatório para o Mayor decidir. Um
alarme a mais nesta cidade seria contraproducente (ver ga-ysc82: vigilância calibrada pra
pipeline saudável vira ruído quando a fila cresce).
"""
import os
import re
import subprocess
import sys
from collections import defaultdict

CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
LOG = os.path.join(CITY, ".gc/logs/quality-gate-dispatcher.log")

# Faixas escolhidas em torno do limiar da literatura (400) para que o relatório mostre
# o degrau, se ele existir, em vez de médias que o escondem.
BUCKETS = [(0, 200), (200, 400), (400, 800), (800, 2000), (2000, 10**9)]

SIZE_RE = re.compile(
    r"for diff \(marker=(\S+) bead=(\S+) (\d+) files, (\d+) lines"
)
VERDICT_RE = re.compile(r"Gate run complete: gate_run=(\S+) branch=(\S+) verdict=(\w+)")
MARKER_RUN_RE = re.compile(r"Run (\S+) admitted")


def main() -> int:
    if not os.path.exists(LOG):
        print("FALHA: log do dispatcher não encontrado em %s" % LOG, file=sys.stderr)
        return 1

    size_by_bead = {}
    verdict_by_branch = {}
    branch_by_bead = {}

    for ln in open(LOG, errors="ignore"):
        m = SIZE_RE.search(ln)
        if m:
            _marker, bead, _files, lines = m.groups()
            # primeira leitura por bead: o tamanho no momento da revisão
            size_by_bead.setdefault(bead, int(lines))
            continue
        v = VERDICT_RE.search(ln)
        if v:
            _run, branch, verdict = v.groups()
            verdict_by_branch[branch] = verdict

    # branch -> bead pelo sufixo do nome (crew/<x>/<bead> ou fix/<bead>-...)
    for branch in verdict_by_branch:
        for bead in size_by_bead:
            if bead and bead in branch:
                branch_by_bead[bead] = branch
                break

    pairs = [
        (size_by_bead[b], verdict_by_branch[branch_by_bead[b]])
        for b in branch_by_bead
        if b in size_by_bead
    ]

    print("=" * 68)
    print(" RELATÓRIO tamanho-do-diff x veredito do gate (ga-ub8yq)")
    print("=" * 68)

    # ── Distribuição: sempre disponível, não depende da correlação ────────────
    sizes = sorted(size_by_bead.values())
    if sizes:
        def pct(p):
            return sizes[min(int(len(sizes) * p), len(sizes) - 1)]
        print("\nDISTRIBUIÇÃO (n=%d)" % len(sizes))
        print("  p50=%d  p75=%d  p90=%d  p95=%d  p99=%d"
              % (pct(.5), pct(.75), pct(.9), pct(.95), pct(.99)))
        acima = sum(1 for s in sizes if s > 400)
        print("  acima de 400 linhas: %d (%d%%) — limite útil da literatura"
              % (acima, acima * 100 // len(sizes)))
    else:
        print("\nDISTRIBUIÇÃO: SEM DADOS.")
        print("  Provável causa: o log ainda não tem linhas no formato novo")
        print("  (marker=/bead=). Ele só passa a existir DEPOIS que a mudança do")
        print("  ga-ub8yq entrar em produção. Isto NÃO é 'tudo certo' — é 'ainda")
        print("  não mede'.")

    # ── A correlação: é o entregável ──────────────────────────────────────────
    print("\nCORRELAÇÃO tamanho x reprovação (n=%d runs pareados)" % len(pairs))
    if not pairs:
        print("  SEM PARES. Não conclua nada daqui — não é 'sem problema',")
        print("  é 'sem medição'. Se a distribuição acima tem dados mas isto")
        print("  está vazio, o casamento branch<->bead falhou e o script é que")
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
