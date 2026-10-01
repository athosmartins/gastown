#!/usr/bin/env python3
"""e9-apuracao.py — apura o experimento E9 do P0 ga-ufskhy (ga-798p6w). READ-ONLY, roda a qualquer hora.

PERGUNTA: entregar ao construtor, no INÍCIO do build, um plano técnico (arquivos, funções, casos-limite, o teste que reprova)
produzido por um planejador Opus somente-leitura (e9-plan.sh) reduz o custo por bead APROVADA sem derrubar a aprovação na 1a
tentativa? BRAÇO `on` = a bead recebe o plano; `off` = controle (o fluxo de hoje). A atribuição é uma função fixa do id da bead
(e9-arms.sh: SHA-256 de "e9-planner:<salt>:<bead>" mod 100 < planner_pct) — o Pilot grava o roster NO DESPACHO (e9-arms.sh assign),
tenha o construtor rodado o planejador ou não. Por isso a análise é por INTENÇÃO DE TRATAR: a bead conta no braço a que foi
atribuída; uma bead `on` cujo planejador falhou continua no `on` (aderência sai em separado).

FONTES. O roster (<hq>/.gc/e9-roster.jsonl: eventos `assign` e `plan_run`), o JSON do medidor E8 (`bead-token-meter.py report --json`,
passe com --meter: custo por bead e veredito do gate), o git (--repo: arquivos realmente alterados, PLAN-DEVIATION).

O QUE ESTE SCRIPT NÃO INVENTA (terceiro estado, dito em voz alta em vez de virar zero):
  * custo de uma bead com token SEM PREÇO (o medidor marca unpriced_tokens>0), com campo ausente/não-numérico, ou com um run do
    planejador sem custo PROVADO (PENDING sem desfecho, interrompido, cost_known!=true) => custo DESCONHECIDO. A bead sai da
    comparação de custo e é CONTADA; se passar de --max-unknown-share de um braço, o veredito de custo é INDETERMINADO.
    "Nenhuma linha de plan_run" é diferente: um run lançado grava a linha PENDING ANTES de gastar, então bead sem linha = nada
    gasto = planejador US$ 0 CONHECIDO.
  * o braço: é recomputado EXECUTANDO e9-arms.sh (nunca reimplementado aqui). Roster que diverge do recomputado vai para
    "anomalias" e sai da conta. Se não for possível recomputar, nada é apurado (exit 2): "sem braço" não é "off".
  * beads FORA do roster (construídas antes de ligar, ou por um caminho sem o hook do Pilot) não entram — não receberam a dica,
    então não são nem tratamento nem controle. São contadas.
  * arquivos REALIZADOS vêm do git (commits com "(<bead>)" no assunto, sem docs/*.md); sem --repo, ou sem commit achado,
    o campo é "NÃO MEDIDO" — nunca 0 arquivos. NÃO observa superfícies/externo/migração (não se recuperam de um diff): a classe
    realizada é por TAMANHO, e a calibração compara a contagem de arquivos prevista com a realizada.

CRITÉRIO (pré-registrado em docs/e9-planner-complexity.md, seção 4; decisão é do Mayor, este script nunca age):
  n >= --min-n beads por braço (com custo conhecido) E
  ADOTAR      = custo por bead aprovada do `on` pelo menos --min-effect (30%) menor, com o limite superior do IC de 95% abaixo de 0,
                E a aprovação na 1a tentativa NÃO CAI: a estimativa da diferença on−off >= -3 pp (--max-fp-drop) E o limite inferior
                do IC >= -10 pp (--fp-ci-floor). Por que não "IC >= -3 pp": provar não-inferioridade de 3 pp exige ~4.200 beads por
                braço (tabela de poder do E8), contra ~174 que o teste de custo pede — a regra nunca chegaria a ADOTAR. A guarda
                realista é: a estimativa não cai mais que 3 pp e o IC exclui uma queda grande (10 pp). O que ela NÃO prova (uma
                queda de 3 a 10 pp) é dito no veredito.
  NÃO ADOTAR  = mesmo o melhor extremo do IC não alcança o efeito mínimo, OU a queda de aprovação já passa de 3 pp com confiança
                (limite superior do IC < -3 pp).
  INDETERMINADO = o resto (precisa de mais beads) — ou custo incompleto.
  Com n < --min-n por braço o veredito é INCONCLUSIVO — não pare o experimento quando o número agrada.
"""
import argparse
import calendar
import importlib.util
import json
import math
import os
import random
import re
import statistics
import subprocess
import sys
import tempfile
import time
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
HQ_DEFAULT = os.environ.get("GC_CITY_PATH") or os.path.dirname(HERE)
BEAD_IN_SUBJECT = re.compile(r"\(([a-z][a-z0-9]*-[a-z0-9]+)\)")
FACT_FILES = re.compile(r"\barquivos=(\d+)\b")


def _load_e3():
    """wilson / newcombe_diff / load_jsonl / recompute_arms (pregate) come from E3's readout — one source for the interval maths."""
    path = os.path.join(HERE, "pre-gate-apuracao.py")
    spec = importlib.util.spec_from_file_location("pre_gate_apuracao", path)
    if spec is None or spec.loader is None or not os.path.isfile(path):
        raise ImportError(f"não achei {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def pct(x, digits=0):
    return "n/a" if x != x else f"{100 * x:.{digits}f}%"


def usd(x):
    return "n/a" if x is None else f"US$ {x:,.2f}"


def parse_utc(s):
    return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))


def num(v):
    """A number we can trust, or None. Roster values are strings (jq --arg); the meter's are JSON numbers. bool is excluded (True is
    an int in Python), and so are NaN/inf and negatives: none of those is a measurement of a cost or a count."""
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, str):
        try:
            v = float(v)
        except ValueError:
            return None
    if not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0:
        return None
    return float(v)


# ── roster ────────────────────────────────────────────────────────────────────────────────────────────────────
def read_roster(e3, path, want_salt, since):
    """assigns {bead: row} (the first assignment wins), conflicts, plan_run rows, bad count, salts seen."""
    rows, bad = e3.load_jsonl(path)
    assigns, conflicts, runs, salts, bad_assign = {}, [], [], defaultdict(int), 0
    cand = []
    for r in rows:
        if r.get("event") != "assign":
            continue
        try:
            ts = parse_utc(r["ts"])
        except (KeyError, ValueError, TypeError):
            bad_assign += 1
            continue
        if not r.get("bead") or not r.get("salt") or r.get("planner_arm") not in ("on", "off"):
            bad_assign += 1
            continue
        salts[r["salt"]] += 1
        cand.append((ts, r))
    if want_salt is None and cand:
        want_salt = max(cand, key=lambda t: t[0])[1]["salt"]   # the experiment that is running now = the latest salt
    for ts, r in sorted(cand, key=lambda t: t[0]):
        if r["salt"] != want_salt or (since and ts < since):
            continue
        b = r["bead"]
        if b in assigns:
            if assigns[b]["planner_arm"] != r["planner_arm"]:
                conflicts.append(b)
            continue
        assigns[b] = dict(r, _ts=ts)
    for r in rows:
        if r.get("event") == "plan_run" and r.get("salt") == want_salt:
            runs.append(r)
    return assigns, conflicts, runs, bad, bad_assign, want_salt, dict(salts)


def settle_runs(rows):
    """One record per LAUNCHED run. PENDING (before the spend) and FINAL (the outcome) share a run_id and are ONE run: the FINAL
    wins; a PENDING with no FINAL stays (launched, outcome and cost unknown). A launched row with no run_id is its own run."""
    best, anon = {}, []
    for r in rows:
        if r.get("launched") != "true":
            continue
        rid = r.get("run_id")
        if not rid:
            anon.append(r)
            continue
        prev = best.get(rid)
        if prev is None or (prev.get("verdict") == "PENDING" and r.get("verdict") != "PENDING"):
            best[rid] = r
    return list(best.values()) + anon


def run_cost(r):
    """US$ of one launched run, or None when the record does not PROVE a cost (cost_known=true AND a finite number >= 0)."""
    if r.get("cost_known") != "true":
        return None
    return num(r.get("cost_usd"))


def planner_cost(runs):
    """Total planner spend for one bead: 0.0 when no run was launched (a launched run writes PENDING BEFORE it spends), None when ANY
    launched run has no proven cost."""
    total = 0.0
    for r in runs:
        c = run_cost(r)
        if c is None:
            return None
        total += c
    return total


def run_class(r, now, grace_s):
    v, reason = r.get("verdict", "?"), str(r.get("reason", ""))
    if v == "PLANNED":
        return "planejado"
    if v == "PENDING":
        try:
            age = now - parse_utc(r["ts"])
        except (KeyError, ValueError, TypeError):
            return "sem desfecho gravado"
        return "em curso" if age <= grace_s else "sem desfecho gravado"
    if v == "INCONCLUSIVE":
        if reason.startswith(("interrupted", "abnormal-exit")):
            return "interrompido"
        return "inconclusivo: " + (reason.split(":")[0] or "?")
    return "veredito desconhecido (%s)" % v


# ── arms: ask the REAL rule ─────────────────────────────────────────────────────────────────────────────────────
def recompute_arms(hq, salt, pct_val, beads):
    """Run e9-arms.sh `arms planner` under a throwaway state dir whose conf carries the recorded salt and pct. {bead: 'on'|'off'|None}."""
    if not beads:
        return {}
    script = os.path.join(hq, "packs/town-deltas/assets/e9-arms.sh")
    if not os.path.isfile(script):
        raise RuntimeError(f"não achei {script}")
    with tempfile.TemporaryDirectory(prefix="e9-apuracao-") as d:
        with open(os.path.join(d, "e9-ab.conf"), "w") as f:
            f.write(f"planner_pct={int(pct_val)}\ncomplexity=on\nsalt={salt}\n")
        env = dict(os.environ, E9_STATE_DIR=d)
        r = subprocess.run(["/bin/bash", script, "arms", "planner"], input="\n".join(sorted(beads)) + "\n",
                           capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise RuntimeError(f"e9-arms.sh arms planner saiu com {r.returncode}: {r.stderr.strip()[:200]}")
    out = {}
    for line in r.stdout.splitlines():
        b, _, a = line.partition(" ")
        out[b] = a if a in ("on", "off") else None
    return out


# ── meter ─────────────────────────────────────────────────────────────────────────────────────────────────────
def load_meter(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    beads = data.get("beads") if isinstance(data, dict) else None
    if not isinstance(beads, dict):
        raise ValueError("JSON sem o objeto 'beads' — não é a saída de `bead-token-meter.py report --json`")
    return {k: v for k, v in beads.items() if isinstance(v, dict)}


def meter_cost(rec):
    """build + review + pre-gate US$ of one bead from the meter, or None (unknown): unpriced tokens, a missing or non-numeric field."""
    unpriced = num(rec.get("unpriced_tokens"))
    if unpriced is None or unpriced > 0:
        return None
    parts = [num(rec.get(k)) for k in ("build_usd", "review_usd", "pregate_usd")]
    if any(p is None for p in parts):
        return None
    return sum(parts)


# ── git ───────────────────────────────────────────────────────────────────────────────────────────────────────
def is_doc(path):
    return path.endswith(".md") or path.startswith("docs/") or "/docs/" in path


def git_realized(repo, ref, since_iso):
    """({bead: set(files)} from commits whose subject carries "(<bead>)", sans docs; {bead} with a PLAN-DEVIATION commit). None, None if git fails."""
    try:
        log = subprocess.run(["git", "-C", repo, "log", ref, "--no-merges", "--name-only", "--format=@@%H%x09%s", f"--since={since_iso}"],
                             capture_output=True, text=True, timeout=300)
        dev = subprocess.run(["git", "-C", repo, "log", ref, "--no-merges", "--grep=PLAN-DEVIATION", "--format=%H%x09%s", f"--since={since_iso}"],
                             capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.SubprocessError):
        return None, None
    if log.returncode != 0 or dev.returncode != 0:
        return None, None
    files, cur = defaultdict(set), None
    for line in log.stdout.splitlines():
        if line.startswith("@@"):
            m = BEAD_IN_SUBJECT.search(line.partition("\t")[2])
            cur = m.group(1) if m else None
        elif line.strip() and cur and not is_doc(line.strip()):
            files[cur].add(line.strip())
    deviated = set()
    for line in dev.stdout.splitlines():
        m = BEAD_IN_SUBJECT.search(line.partition("\t")[2])
        if m:
            deviated.add(m.group(1))
    return dict(files), deviated


def size_class(n_files):
    return "S" if n_files <= 2 else ("M" if n_files <= 7 else "L")


# ── statistics ────────────────────────────────────────────────────────────────────────────────────────────────
def ratio(rows):
    """sum(cost) / count(approved) over [(cost, approved)] — the cost of the failures is in the numerator on purpose: the bead the arm
    could not get approved is part of what an approved bead costs. None when nothing was approved."""
    a = sum(1 for _, ap in rows if ap)
    return None if a == 0 else sum(c for c, _ in rows) / a


def boot_rel_diff(on, off, reps, seed):
    """Percentile 95% CI of ratio(on)/ratio(off) - 1, resampling beads WITHIN each arm; fixed seed so a rerun prints the same number."""
    rng = random.Random(seed)
    ds = []
    for _ in range(reps):
        ron = ratio([on[rng.randrange(len(on))] for _ in range(len(on))])
        roff = ratio([off[rng.randrange(len(off))] for _ in range(len(off))])
        if ron is not None and roff:
            ds.append(ron / roff - 1)
    if len(ds) < max(20, reps // 2):
        return (float("nan"), float("nan"))
    ds.sort()
    return (ds[int(0.025 * len(ds))], ds[min(len(ds) - 1, int(0.975 * len(ds)))])


def chi2_2x2(a, b, c, d):
    """Pearson chi-square (1 df, no continuity correction) and its p-value for [[a,b],[c,d]]; (nan, nan) when a margin is empty."""
    n = a + b + c + d
    r1, r2, c1, c2 = a + b, c + d, a + c, b + d
    if 0 in (r1, r2, c1, c2):
        return (float("nan"), float("nan"))
    chi = n * (a * d - b * c) ** 2 / (r1 * r2 * c1 * c2)
    return (chi, math.erfc(math.sqrt(chi / 2)))


def median(xs):
    return statistics.median(xs) if xs else float("nan")


# ── the report ────────────────────────────────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--hq", default=HQ_DEFAULT)
    ap.add_argument("--roster", help="e9-roster.jsonl (padrão: <hq>/.gc/e9-roster.jsonl)")
    ap.add_argument("--meter", help="saída de `bead-token-meter.py report --json` (custo e veredito do gate por bead)")
    ap.add_argument("--repo", help="checkout git (arquivos realizados, PLAN-DEVIATION); padrão: não mede")
    ap.add_argument("--ref", default="origin/main", help="ref onde procurar os commits mergeados (padrão origin/main)")
    ap.add_argument("--salt", help="salt do experimento (padrão: o da atribuição mais recente)")
    ap.add_argument("--since", help="YYYY-MM-DD (UTC): só conta atribuições a partir desta data")
    ap.add_argument("--min-n", type=int, default=174, help="beads com custo conhecido por braço (E8: -30%% de custo, CV 1,0 => 174)")
    ap.add_argument("--min-effect", type=float, default=0.30, help="redução mínima do custo por bead aprovada (padrão 30%%)")
    ap.add_argument("--max-fp-drop", type=float, default=0.03, help="queda máxima tolerada, na ESTIMATIVA, da aprovação da 1a tentativa (padrão 3 pp)")
    ap.add_argument("--fp-ci-floor", type=float, default=0.10, help="o limite inferior do IC da diferença de aprovação não pode ser pior que isto (padrão 10 pp)")
    ap.add_argument("--max-unknown-share", type=float, default=0.10, help="acima disso de beads sem custo num braço, o custo é INDETERMINADO")
    ap.add_argument("--pending-grace-min", type=float, default=40.0, help="minutos que um run PENDING conta como 'em curso'")
    ap.add_argument("--boot", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=9)
    ap.add_argument("--now", type=float, help="época UTC 'de agora' (só teste)")
    ap.add_argument("--json", action="store_true", help="imprime o resultado estruturado em JSON em vez do texto")
    a = ap.parse_args()

    try:
        e3 = _load_e3()
    except Exception as exc:   # noqa: BLE001 — any import failure is the same fact: the interval maths is not available
        print(f"FALHA: não consigo carregar pre-gate-apuracao.py (as contas de intervalo): {exc} — NADA foi apurado.", file=sys.stderr)
        return 2
    roster_path = a.roster or os.path.join(a.hq, ".gc/e9-roster.jsonl")
    if not os.path.isfile(roster_path):
        print(f"FALHA: não consigo ler o roster em {roster_path} — NADA foi apurado (isto não é 'zero beads': o experimento pode "
              f"nunca ter sido ligado).", file=sys.stderr)
        return 2
    since = parse_utc(a.since + "T00:00:00Z") if a.since else None
    now = a.now if a.now is not None else time.time()

    assigns, conflicts, run_rows, bad_rows, bad_assign, salt, salts = read_roster(e3, roster_path, a.salt, since)
    if not assigns:
        print(f"FALHA: o roster não tem nenhuma atribuição legível para o salt '{salt}' (salts vistos: {salts or 'nenhum'}) — NADA foi apurado.",
              file=sys.stderr)
        return 2

    # ── arms: recomputed by the real rule, per (salt, pct) actually recorded ──
    by_pct = defaultdict(list)
    for b, r in assigns.items():
        by_pct[num(r.get("planner_pct"))].append(b)
    recomputed = {}
    for pv, beads in by_pct.items():
        if pv is None:
            for b in beads:
                recomputed[b] = None
            continue
        try:
            recomputed.update(recompute_arms(a.hq, salt, pv, beads))
        except (RuntimeError, OSError) as exc:
            print(f"FALHA: não consegui recomputar o braço pela regra real: {exc} — NADA foi apurado ('sem braço' não é 'off').", file=sys.stderr)
            return 2
    arm, anomalies = {}, []
    for b, r in assigns.items():
        rc = recomputed.get(b)
        if rc is None or rc != r["planner_arm"]:
            anomalies.append((b, r["planner_arm"], rc))
        else:
            arm[b] = rc
    runs_by_bead = defaultdict(list)
    for r in settle_runs(run_rows):
        runs_by_bead[r.get("bead")].append(r)

    out = {"salt": salt, "pct_seen": sorted(k for k in by_pct if k is not None), "assigned": len(assigns), "arms_ok": len(arm),
           "anomalies": len(anomalies), "conflicts": len(conflicts), "bad_rows": bad_rows, "bad_assign_rows": bad_assign}
    L = []
    P = L.append
    P("=" * 78)
    P(f"E9 — planejador no início do build (ga-798p6w) — salt '{salt}', planner_pct {out['pct_seen']}")
    P("=" * 78)
    n_on = sum(1 for v in arm.values() if v == "on")
    n_off = len(arm) - n_on
    P("\n1. ROSTER E BRAÇOS")
    P(f"   atribuídas: {len(assigns)}  |  braço confere com o recomputado: {len(arm)} (on {n_on} / off {n_off})")
    if anomalies:
        P(f"   ANOMALIAS (roster ≠ regra, ou não recomputável) — fora da conta: {len(anomalies)}: "
          + ", ".join(f"{b}[{ra}→{rc}]" for b, ra, rc in anomalies[:8]) + (" …" if len(anomalies) > 8 else ""))
    if conflicts:
        P(f"   CONFLITO (a mesma bead com braços diferentes no roster) — a 1a atribuição vence: {len(conflicts)}: {', '.join(conflicts[:8])}")
    if bad_rows or bad_assign:
        P(f"   linhas ilegíveis no roster: {bad_rows} (JSON) + {bad_assign} (atribuição sem campo/ts) — CONTADAS, não ignoradas")
    if len(out["pct_seen"]) > 1:
        P(f"   ATENÇÃO: o planner_pct MUDOU durante o experimento ({out['pct_seen']}): cada bead conta pelo braço que recebeu, mas a "
          f"proporção on/off não é mais um sorteio único")
    if n_on + n_off:
        P(f"   proporção on: {pct(n_on / (n_on + n_off))} (esperado ≈ planner_pct)")

    # independence from E3's coin
    try:
        pg = e3.recompute_arms(os.path.join(a.hq, "packs/town-deltas/assets"), list(arm))
    except Exception:   # noqa: BLE001
        pg = {}
    cells = defaultdict(int)
    for b, v in arm.items():
        if pg.get(b) in ("on", "off"):
            cells[(v, pg[b])] += 1
    if cells:
        chi, p = chi2_2x2(cells[("on", "on")], cells[("on", "off")], cells[("off", "on")], cells[("off", "off")])
        P(f"   independência do braço da E3 (pregate): on×on {cells[('on','on')]}, on×off {cells[('on','off')]}, "
          f"off×on {cells[('off','on')]}, off×off {cells[('off','off')]}  χ²={chi:.2f} p={p:.2f}"
          + ("  ← DEPENDENTES (p<0,05): não atribua a diferença a um só experimento" if p == p and p < 0.05 else "  (independentes)"))
        out["independence_p_vs_pregate"] = None if p != p else round(p, 4)
    else:
        P("   independência da E3: NÃO MEDIDA (sem braço pregate recomputável)")

    # ── compliance ──
    P("\n2. ADERÊNCIA (beads atribuídas ao braço on)")
    classes = defaultdict(int)
    planner_total, planner_unknown = 0.0, 0
    for b, v in arm.items():
        if v != "on":
            continue
        rs = runs_by_bead.get(b, [])
        if not rs:
            classes["nunca rodou o planejador (nenhum run lançado)"] += 1
            continue
        cl = [run_class(r, now, a.pending_grace_min * 60) for r in rs]
        classes["planejado" if "planejado" in cl else cl[-1]] += 1
        c = planner_cost(rs)
        if c is None:
            planner_unknown += 1
        else:
            planner_total += c
    for k in sorted(classes, key=lambda k: (-classes[k], k)):
        P(f"   {k:<52} {classes[k]:>4}")
    if n_on:
        P(f"   aderência (planejado / atribuídas on): {pct(classes['planejado'] / n_on)}  — a análise NÃO a usa: é por intenção de tratar")
    P(f"   custo do planejador nas beads on: {usd(planner_total)} exatos"
      + (f" + {planner_unknown} bead(s) com run de custo DESCONHECIDO (a soma é um LIMITE INFERIOR)" if planner_unknown else ""))
    out["compliance"] = dict(classes)

    # ── outcomes ──
    meter = None
    if a.meter:
        try:
            meter = load_meter(a.meter)
        except (OSError, ValueError) as exc:
            print(f"FALHA: não consigo ler o medidor em {a.meter}: {exc} — NADA foi apurado.", file=sys.stderr)
            return 2
    verdict, why = "INCONCLUSIVO", []
    if meter is None:
        P("\n3. CUSTO E APROVAÇÃO — NÃO MEDIDOS: passe --meter <report.json> (saída de `bead-token-meter.py report --json`; o medidor é o E8, ga-5c3msy).")
        why.append("sem --meter")
    else:
        pop, off_roster = {}, 0
        no_verdict = {"on": 0, "off": 0}
        for b, rec in meter.items():
            if b not in assigns:
                off_roster += 1
            elif b in arm and rec.get("first_gate") in ("PASS", "FAIL"):
                pop[b] = rec
            elif b in arm:
                no_verdict[arm[b]] += 1   # measured, but the gate has not ruled (key missing or null): out of the comparison, never out of the count
        not_in_meter = sum(1 for b in arm if b not in meter)
        P("\n3. POPULAÇÃO COM DESFECHO (intenção de tratar)")
        P(f"   beads do medidor com veredito do gate: {len(pop)}  |  fora do roster (não receberam a dica; não entram): {off_roster}"
          f"  |  no roster sem medição ainda: {not_in_meter}")
        P(f"   no medidor mas SEM veredito do gate ainda (fora da conta; contadas): on {no_verdict['on']} / off {no_verdict['off']}")
        out["no_gate_verdict"] = no_verdict
        cost_rows = {"on": [], "off": []}
        unknown = {"on": 0, "off": 0}
        fp = {"on": [0, 0], "off": [0, 0]}
        for b, rec in pop.items():
            v = arm[b]
            fp[v][1] += 1
            fp[v][0] += 1 if rec.get("first_gate") == "PASS" else 0
            mc, pc = meter_cost(rec), planner_cost(runs_by_bead.get(b, []))
            if mc is None or pc is None:
                unknown[v] += 1
            else:
                cost_rows[v].append((mc + pc, rec.get("ever_pass") is True))
        P("\n4. APROVAÇÃO NA 1a TENTATIVA (métrica co-primária)")
        for v in ("on", "off"):
            k, n = fp[v]
            p_, lo, hi = e3.wilson(k, n)
            P(f"   {v:<3} {k}/{n} = {pct(p_)}  IC95% [{pct(lo)}, {pct(hi)}]")
        d, dlo, dhi = e3.newcombe_diff(fp["on"][0], fp["on"][1], fp["off"][0], fp["off"][1])
        P(f"   on − off = {d*100:+.1f} pp  IC95% [{dlo*100:+.1f}, {dhi*100:+.1f}] pp" if d == d else "   on − off: n/a (um braço vazio)")
        P("\n5. CUSTO POR BEAD APROVADA (métrica primária; US$ equivalente-API do medidor E8 + planejador)")
        for v in ("on", "off"):
            rows = cost_rows[v]
            tot = len(rows) + unknown[v]
            P(f"   {v:<3} beads com custo conhecido {len(rows)}/{tot}"
              + (f"  (SEM custo: {unknown[v]} = {pct(unknown[v] / tot)})" if unknown[v] else "")
              + (f"  → {usd(ratio(rows))} por aprovada" if ratio(rows) is not None else "  → n/a (nenhuma aprovada)"))
        r_on, r_off = ratio(cost_rows["on"]), ratio(cost_rows["off"])
        rel = lo_c = hi_c = float("nan")
        if cost_rows["on"] and cost_rows["off"] and r_on is not None and r_off:
            rel = r_on / r_off - 1
            lo_c, hi_c = boot_rel_diff(cost_rows["on"], cost_rows["off"], a.boot, a.seed)
            P(f"   on / off − 1 = {rel*100:+.1f}%  IC95% (bootstrap {a.boot}, seed {a.seed}) [{lo_c*100:+.1f}%, {hi_c*100:+.1f}%]")
        else:
            P("   on / off − 1: n/a")

        # verdict
        n_known = {v: len(cost_rows[v]) for v in cost_rows}
        shares = {v: (unknown[v] / (n_known[v] + unknown[v]) if n_known[v] + unknown[v] else 0.0) for v in unknown}
        if min(n_known.values()) < a.min_n:
            verdict = "INCONCLUSIVO"
            why.append(f"n com custo conhecido por braço = {n_known['on']} on / {n_known['off']} off; o mínimo é {a.min_n}")
        elif max(shares.values()) > a.max_unknown_share:
            verdict = "INDETERMINADO"
            why.append(f"custo desconhecido em mais de {pct(a.max_unknown_share)} de um braço ({pct(shares['on'])} on / {pct(shares['off'])} off)")
        elif rel != rel or d != d:
            verdict = "INDETERMINADO"
            why.append("não consegui calcular a diferença (braço sem aprovada ou IC degenerado)")
        else:
            cost_ok = rel <= -a.min_effect and hi_c < 0
            cost_dead = lo_c > -a.min_effect
            fp_ok = (d >= -a.max_fp_drop) and (dlo >= -a.fp_ci_floor)
            fp_bad = dhi < -a.max_fp_drop
            if cost_ok and fp_ok:
                verdict = "ADOTAR"
            elif cost_dead or fp_bad:
                verdict = "NÃO ADOTAR"
            else:
                verdict = "INDETERMINADO"
            why.append(f"custo: ponto {rel*100:+.1f}% (exige ≤ {-a.min_effect*100:.0f}% e IC superior < 0 → {'ok' if cost_ok else 'NÃO'}"
                       f"{'; nem o melhor extremo do IC alcança o efeito mínimo' if cost_dead else ''})")
            why.append(f"aprovação: estimativa {d*100:+.1f} pp (exige ≥ {-a.max_fp_drop*100:.0f}) e limite inferior do IC {dlo*100:+.1f} pp "
                       f"(exige ≥ {-a.fp_ci_floor*100:.0f}) → {'ok' if fp_ok else 'NÃO'}"
                       f"{'; a queda já passa do tolerado com confiança' if fp_bad else ''}")
            if fp_ok:
                why.append(f"a guarda de aprovação NÃO exclui uma queda entre {a.max_fp_drop*100:.0f} e {a.fp_ci_floor*100:.0f} pp — só uma maior")
        out.update({"cost_per_approved": {"on": r_on, "off": r_off}, "rel_diff": None if rel != rel else rel,
                    "rel_ci": [None if lo_c != lo_c else lo_c, None if hi_c != hi_c else hi_c],
                    "first_pass": {v: fp[v] for v in fp}, "cost_unknown": unknown,
                    "first_pass_diff_pp": None if d != d else d * 100})

        # ── realized complexity: strata and calibration ──
        files = deviated = None
        if a.repo:
            earliest = min(r["_ts"] for r in assigns.values())
            files, deviated = git_realized(a.repo, a.ref, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(earliest - 86400)))
        P("\n6. ESTRATOS POR TAMANHO REALIZADO (descritivo, NÃO confirmatório; S ≤2 arquivos, M 3–7, L ≥8, sem docs)")
        if files is None:
            P("   NÃO MEDIDO: " + ("passe --repo <checkout>" if not a.repo else f"git log em {a.repo} {a.ref} falhou"))
        else:
            cell = defaultdict(lambda: {"on": [], "off": []})
            sem_commit = {"on": 0, "off": 0}
            for b, rec in pop.items():
                fs = files.get(b)
                if not fs:
                    sem_commit[arm[b]] += 1
                    continue
                cell[size_class(len(fs))][arm[b]].append(rec)
            for cl in ("S", "M", "L"):
                for v in ("on", "off"):
                    rs = cell[cl][v]
                    k = sum(1 for r in rs if r.get("first_gate") == "PASS")
                    rr = [(c, ap) for c, ap in [(meter_cost(r), r.get("ever_pass") is True) for r in rs] if c is not None]
                    P(f"   {cl} {v:<3} n={len(rs):>3}  1a tentativa {k}/{len(rs)}" + (f" = {pct(k/len(rs))}" if rs else "")
                      + (f"   {usd(ratio(rr))}/aprovada (sem planejador)" if rr and ratio(rr) is not None else ""))
            P(f"   sem commit mergeado achado para a bead (classe NÃO MEDIDA — fora dos estratos): on {sem_commit['on']}, off {sem_commit['off']}")
            out["strata_unmeasured"] = sem_commit

            P("\n7. CALIBRAÇÃO DO PLANEJADOR (arquivos previstos × realizados, beads on planejadas e mergeadas)")
            pairs, no_facts = [], 0
            for b, v in arm.items():
                if v != "on":
                    continue
                pl = [r for r in runs_by_bead.get(b, []) if r.get("verdict") == "PLANNED"]
                if not pl or not files.get(b):
                    continue
                m = FACT_FILES.search(pl[-1].get("facts", ""))
                if not m:
                    no_facts += 1
                    continue
                pairs.append((int(m.group(1)), len(files[b])))
            if pairs:
                within1 = sum(1 for p_, r_ in pairs if abs(p_ - r_) <= 1)
                within50 = sum(1 for p_, r_ in pairs if abs(p_ - r_) <= 0.5 * max(r_, 1))
                P(f"   n={len(pairs)}  mediana prevista {median([p_ for p_, _ in pairs]):.0f} × realizada {median([r_ for _, r_ in pairs]):.0f}"
                  f"  |  viés médio (prev − real) {statistics.mean(p_ - r_ for p_, r_ in pairs):+.1f}"
                  f"  |  ±1 arquivo: {pct(within1 / len(pairs))}  ±50%: {pct(within50 / len(pairs))}")
                P("   (esta é a medida de que o roteamento por complexidade depende: se a previsão erra, rotear por ela erra junto)")
            else:
                P("   NÃO MEDIDA: nenhuma bead on planejada tem commit mergeado achado" + (f" ({no_facts} sem 'arquivos=' nos fatos)" if no_facts else ""))
            planned_merged = [b for b, v in arm.items() if v == "on" and any(r.get("verdict") == "PLANNED" for r in runs_by_bead.get(b, [])) and files.get(b)]
            if planned_merged and deviated is not None:
                dv = sum(1 for b in planned_merged if b in deviated)
                P(f"   PLAN-DEVIATION declarado: {dv}/{len(planned_merged)} = {pct(dv / len(planned_merged))} das beads planejadas e mergeadas "
                  f"(o construtor discordou do plano e disse por quê)")
            out["calibration_pairs"] = len(pairs)

    P("\n8. VEREDITO (pré-registrado; quem decide é o Mayor — este script nunca liga, desliga nem muda nada)")
    P(f"   {verdict}")
    for w in why:
        P(f"   - {w}")
    P("\nLIMITES: o custo é US$ equivalente-API (não a cobrança da assinatura); beads ainda sem aprovação carregam custo parcial nos DOIS braços;"
      "\n         cenários 'em curso' (PENDING recente) não têm desfecho; o planejador só existe para builds despachados pelo Pilot com o hook ligado.")
    out["verdict"] = verdict
    out["verdict_reasons"] = why
    if a.json:
        print(json.dumps(out, ensure_ascii=False, indent=1, sort_keys=True, default=str))
    else:
        print("\n".join(L))
    return 0


if __name__ == "__main__":
    sys.exit(main())
