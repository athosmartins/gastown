#!/usr/bin/env python3
"""pre-gate-apuracao.py — apura o experimento E3 do P0 ga-ufskhy (ga-gnr3tw). READ-ONLY, roda a qualquer hora.

PERGUNTA: rodar o prompt do PRÓPRIO revisor no diff do construtor antes do /gate-done (Step 2b) sobe a aprovação
na 1a tentativa? BRAÇO `on` = a bead caiu na metade que roda a pré-revisão; `off` = controle. A atribuição é uma função
fixa do id da bead (pre-gate-review.sh: paridade do SHA-256 de "pregate:<bead>"). Toda submissão entra no roster
(runs.jsonl, evento `assign`) — o /gate-done Step 3 grava via `pre-gate-review.sh roster`, tenha o construtor rodado o
Step 2b ou não; o Step 2b (`run --bead`) grava também. Por isso a apuração é por INTENÇÃO DE TRATAR: conta a bead pelo
braço a que foi atribuída, tenha rodado a pré-revisão ou não. Aderência (quantas do braço `on` de fato rodaram) sai em
separado. Só fica fora do roster quem submeteu por um gate-done ANTIGO (sessão materializada antes do merge), sem Step 3 novo.

MÉTRICA PRIMÁRIA: aprovação na PRIMEIRA tentativa por braço (o 1o "Gate run complete" da branch depois da atribuição).
NÃO use "% de runs que reprovam": uma bead que reprova 3x e passa conta 3 FAIL + 1 PASS e infla o problema.

O QUE ESTE SCRIPT NÃO INVENTA (terceiro estado, dito em voz alta em vez de virar zero):
  * custo do CONSTRUTOR (retrabalho do braço on) — não é medido em lugar nenhum; sai como "NÃO MEDIDO".
  * custo do REVISOR por tentativa — é uma ESTIMATIVA (--reviewer-usd, padrão US$0,60 = 8,93/15 julgamentos do E0,
    ga-5vi6cp), rotulada como tal. O custo do pré-gate é EXATO (total_cost_usd de cada run).
  * a regra de atribuição é EXECUTADA (pre-gate-review.sh: pregate_arm_for_bead), nunca reimplementada aqui; se o braço
    gravado no roster divergir do recalculado, a bead vai para "anomalias" e sai da conta.

CRITÉRIO (bead ga-gnr3tw, item 4): on >= 70% E custo por bead aprovada (on) <= off  =>  PROPOR ligar pra todos (decisão do
Mayor). Senão, relatório do porquê. Com n < --min-n por braço o veredito é INCONCLUSIVO — não pare o experimento quando o
número agrada.
"""
import argparse
import calendar
import json
import math
import os
import re
import statistics
import subprocess
import sys
import time
from collections import defaultdict

HQ_DEFAULT = os.environ.get("GC_CITY_PATH") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GATE_LINE = re.compile(
    r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\].*Gate run complete: gate_run=(\S+) branch=(\S+) verdict=(\w+) elapsed=(\d+)s")


def parse_utc(s):
    return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))


def parse_local(s):
    # the dispatcher log stamps LOCAL time; records stamp UTC. Compare epochs, never the strings.
    return time.mktime(time.strptime(s, "%Y-%m-%d %H:%M:%S"))


def wilson(k, n, z=1.96):
    if n == 0:
        return (float("nan"), float("nan"), float("nan"))
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (p, max(0.0, c - h), min(1.0, c + h))


def newcombe_diff(k1, n1, k2, n2):
    """Newcombe (1998, method 10) CI for p1 - p2 from two Wilson intervals; (nan,nan,nan) if either arm is empty."""
    if n1 == 0 or n2 == 0:
        return (float("nan"), float("nan"), float("nan"))
    p1, l1, u1 = wilson(k1, n1)
    p2, l2, u2 = wilson(k2, n2)
    d = p1 - p2
    return (d, d - math.sqrt((p1 - l1) ** 2 + (u2 - p2) ** 2), d + math.sqrt((u1 - p1) ** 2 + (p2 - l2) ** 2))


def pct(x, digits=0):
    return "n/a" if x != x else f"{100 * x:.{digits}f}%"


def load_jsonl(path):
    rows, bad = [], 0
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except ValueError:
                bad += 1
    return rows, bad


def recompute_arms(assets_dir, beads):
    """Ask the REAL pregate_arm_for_bead (bash) — one process for all beads. {bead: 'on'|'off'|None}"""
    if not beads:
        return {}
    script = os.path.join(assets_dir, "pre-gate-review.sh")
    code = 'source "$1"; shift; for b in "$@"; do a="$(pregate_arm_for_bead "$b")" || a=""; printf "%s\\t%s\\n" "$b" "$a"; done'
    r = subprocess.run(["bash", "-c", code, "_", script] + sorted(beads), capture_output=True, text=True)
    out = {}
    for line in r.stdout.splitlines():
        b, _, a = line.partition("\t")
        out[b] = a if a in ("on", "off") else None
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--since", help="YYYY-MM-DD (UTC): só conta atribuições a partir desta data")
    ap.add_argument("--hq", default=HQ_DEFAULT)
    ap.add_argument("--runs", help="runs.jsonl (padrão: <hq>/.gc/logs/pre-gate-review/runs.jsonl)")
    ap.add_argument("--log", help="log do dispatcher (padrão: <hq>/.gc/logs/quality-gate-dispatcher.log)")
    ap.add_argument("--min-n", type=int, default=30, help="mínimo de branches por braço para dar veredito (bead: ~30)")
    ap.add_argument("--reviewer-usd", type=float, default=0.60, help="ESTIMATIVA de US$ por tentativa do revisor (E0: 8,93/15)")
    ap.add_argument("--target", type=float, default=0.70, help="alvo de aprovação na 1a tentativa do braço on")
    a = ap.parse_args()

    runs_path = a.runs or os.path.join(a.hq, ".gc/logs/pre-gate-review/runs.jsonl")
    log_path = a.log or os.path.join(a.hq, ".gc/logs/quality-gate-dispatcher.log")
    assets = os.path.join(a.hq, "packs/town-deltas/assets")
    for label, p in (("runs.jsonl", runs_path), ("log do dispatcher", log_path)):
        if not os.path.isfile(p):
            print(f"FALHA: não consigo ler {label} em {p} — NADA foi apurado (isto não é 'zero beads').", file=sys.stderr)
            return 2

    rows, bad_rows = load_jsonl(runs_path)
    since = parse_utc(a.since + "T00:00:00Z") if a.since else None

    # ── roster: 1 linha por branch (a 1a atribuição vence; arm conflitante = anomalia) ──
    roster, conflicts, bad_assign = {}, [], 0
    for r in rows:
        if r.get("event") != "assign":
            continue
        # a roster row we cannot read is COUNTED, not skipped: a silent drop shrinks an arm and nobody would know
        if not r.get("branch") or r.get("arm") not in ("on", "off"):
            bad_assign += 1
            continue
        try:
            ts = parse_utc(r["ts"])
        except (KeyError, ValueError):
            bad_assign += 1
            continue
        if since and ts < since:
            continue
        b = r["branch"]
        if b in roster:
            if roster[b]["arm"] != r["arm"]:
                conflicts.append(b)
            continue
        roster[b] = {"bead": r.get("bead", ""), "arm": r["arm"], "ts": ts}

    recomputed = recompute_arms(assets, {v["bead"] for v in roster.values() if v["bead"]})
    if roster and not any(recomputed.values()):
        # Not one arm could be recomputed: the arm function did not run (script missing/unreadable, no sha tool). Treating
        # every bead as an "anomaly" would print a tidy empty report — an invalid measurement dressed as a null result.
        print(f"FALHA: não consegui recalcular NENHUM braço com {os.path.join(assets, 'pre-gate-review.sh')} "
              f"(script ilegível ou sem ferramenta sha256) — a apuração NÃO foi feita.", file=sys.stderr)
        return 2
    anomalies = []
    for b, v in list(roster.items()):
        rc = recomputed.get(v["bead"])
        if rc is None or rc != v["arm"]:
            anomalies.append((b, v["bead"], v["arm"], rc))
            del roster[b]
    for b in conflicts:
        roster.pop(b, None)

    # ── desfechos do gate por branch, em ordem ──
    outcomes = defaultdict(list)   # branch -> [(epoch, verdict)]
    with open(log_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = GATE_LINE.match(line)
            if m:
                outcomes[m.group(3)].append((parse_local(m.group(1)), m.group(4)))

    # ── runs por bead ──
    launched = defaultdict(list)    # bead -> [record] (só as que lançaram o claude)
    refused = defaultdict(list)     # bead -> [reason] (guarda/busy/etc.: nada foi gasto)
    capped = set()
    for r in rows:
        if r.get("event") != "run" or not r.get("bead"):
            continue
        if r.get("launched") is True:
            launched[r["bead"]].append(r)
        elif r.get("reason") == "max-runs":
            capped.add(r["bead"])
        elif r.get("verdict") == "INCONCLUSIVE":
            refused[r["bead"]].append(str(r.get("reason", "?")).split(":")[0])

    # ── por branch: 1a tentativa, tentativas totais, tempo até o 1o PASS ──
    per = {}
    waiting = 0
    for b, v in roster.items():
        after = [(t, vd) for (t, vd) in outcomes.get(b, []) if t >= v["ts"] - 60]
        if not after:
            waiting += 1
            continue
        first_v = after[0][1]
        pass_t = next((t for (t, vd) in after if vd == "PASS"), None)
        per[b] = {"arm": v["arm"], "bead": v["bead"], "first": first_v, "attempts": len(after),
                  "approved": pass_t is not None, "t_pass_min": (pass_t - v["ts"]) / 60 if pass_t else None}

    arms = {"on": [], "off": []}
    other = {"on": 0, "off": 0}
    for b, p in per.items():
        if p["first"] in ("PASS", "FAIL"):
            arms[p["arm"]].append(p)
        else:
            other[p["arm"]] += 1

    print("═══ APURAÇÃO DO E3 — PRÉ-REVISÃO DO CONSTRUTOR (ga-gnr3tw, P0 ga-ufskhy) ═══")
    print(f"  janela: {'a partir de ' + a.since if a.since else 'todo o roster'}   roster: {len(roster)} branches"
          f" ({sum(1 for v in roster.values() if v['arm']=='on')} on / {sum(1 for v in roster.values() if v['arm']=='off')} off)")
    print(f"  aguardando 1o desfecho do gate: {waiting}   desfecho não-PASS/FAIL (infra/timeout): on={other['on']} off={other['off']}")
    if anomalies or conflicts or bad_rows or bad_assign:
        print(f"  ⚠ anomalias FORA da conta: {len(anomalies)} com braço gravado ≠ recalculado (ou não recalculável), "
              f"{len(set(conflicts))} branch(es) com braços conflitantes, {bad_assign} linha(s) de atribuição malformada(s), "
              f"{bad_rows} linha(s) ilegível(is) em runs.jsonl")
        for b, bead, got, want in anomalies[:5]:
            print(f"      {b} bead={bead} gravado={got} recalculado={want}")
    print()

    n_on, n_off = len(arms["on"]), len(arms["off"])
    k_on = sum(1 for p in arms["on"] if p["first"] == "PASS")
    k_off = sum(1 for p in arms["off"] if p["first"] == "PASS")
    print("  ── PRIMÁRIA: aprovação na 1a tentativa (por INTENÇÃO DE TRATAR) ──")
    print(f"  {'braço':<10}{'branches':>9}{'1a-PASS':>9}{'taxa':>7}   IC95% (Wilson)")
    for label, n, k in (("on (pré)", n_on, k_on), ("off (ctrl)", n_off, k_off)):
        p, lo, hi = wilson(k, n)
        print(f"  {label:<10}{n:>9}{k:>9}{pct(p):>7}   {pct(lo)} – {pct(hi)}")
    d, dlo, dhi = newcombe_diff(k_on, n_on, k_off, n_off)
    if d == d:
        print(f"  diferença on − off: {100*d:+.1f}pp   IC95% (Newcombe): {100*dlo:+.1f} a {100*dhi:+.1f}pp"
              f"   {'(exclui 0)' if dlo > 0 or dhi < 0 else '(NÃO exclui 0 — indistinguível do acaso)'}")
    else:
        print("  diferença on − off: n/a (um dos braços está vazio)")
    min_n = min(n_on, n_off)
    if n_off > 0:
        p0 = k_off / n_off
        mde = 2.8 * math.sqrt(2 * p0 * (1 - p0) / max(min_n, 1)) if min_n else float("nan")
        print(f"  menor braço: {min_n} branches (mínimo pedido: {a.min_n}); efeito mínimo detectável com esse n (80% poder): "
              f"{'n/a' if mde != mde else '~%.0fpp' % (100*mde)}")
    print("  (piso de ruído do gate medido A/A em ga-rstae: ~±3pp — diferenças menores que isso são acaso)")
    print()

    # ── aderência ──
    on_beads = sorted({p["bead"] for p in per.values() if p["arm"] == "on"})
    ran = [b for b in on_beads if launched.get(b)]
    not_ran = [b for b in on_beads if not launched.get(b)]
    by_reason = defaultdict(int)
    for b in not_ran:
        if b in capped:
            by_reason["max-runs"] += 1
        elif refused.get(b):
            by_reason[refused[b][-1]] += 1
        else:
            by_reason["SEM REGISTRO (o construtor não rodou o Step 2b, ou a sessão usou um gate-done antigo)"] += 1
    print("  ── ADERÊNCIA (braço on) ──")
    print(f"  rodaram a pré-revisão: {len(ran)} de {len(on_beads)} beads ({pct(len(ran)/len(on_beads) if on_beads else float('nan'))})")
    for reason, c in sorted(by_reason.items(), key=lambda kv: -kv[1]):
        print(f"     não rodaram: {c:>3} × {reason}")
    if ran:
        verdicts = defaultdict(int)
        for b in ran:
            verdicts[launched[b][0].get("verdict", "?")] += 1
        print("  1o veredito da pré-revisão nas beads que rodaram: " + ", ".join(f"{k}={v}" for k, v in sorted(verdicts.items())))
        for v in ("PASS", "FAIL"):
            grp = [per[b] for b in per if per[b]["arm"] == "on" and per[b]["bead"] in launched and launched[per[b]["bead"]][0].get("verdict") == v and per[b]["first"] in ("PASS", "FAIL")]
            if grp:
                kk = sum(1 for p in grp if p["first"] == "PASS")
                print(f"     pré-revisão {v} → gate 1a-PASS {kk}/{len(grp)} ({pct(kk/len(grp))})  [calibração; n pequeno, olhe o IC antes de concluir]")
    print("  (a taxa por INTENÇÃO DE TRATAR acima já inclui quem não rodou; baixa aderência DILUI o efeito, não o inverte)")
    contaminated = sorted({p["bead"] for p in per.values() if p["arm"] == "off" and launched.get(p["bead"])})
    if contaminated:
        print(f"  ⚠ CONTROLE CONTAMINADO: {len(contaminated)} bead(s) do braço OFF rodaram a pré-revisão (--force): {', '.join(contaminated[:5])}"
              f"{' …' if len(contaminated) > 5 else ''} — por INTENÇÃO DE TRATAR continuam contando como off, mas o contraste on×off está mais fraco do que parece")
    print()

    # ── custo / tempo ──
    def arm_cost(arm):
        ps = [p for p in per.values() if p["arm"] == arm]
        approved = [p for p in ps if p["approved"]]
        pre_usd = sum(float(r.get("cost_usd", 0) or 0) for b in {p["bead"] for p in ps} for r in launched.get(b, []))
        rev_usd = a.reviewer_usd * sum(p["attempts"] for p in ps)
        return ps, approved, pre_usd, rev_usd
    print("  ── CUSTO POR BEAD APROVADA (PARCIAL) ──")
    print(f"  {'braço':<10}{'beads':>6}{'aprov.':>7}{'tent./bead':>11}{'pré-gate US$':>14}{'revisor US$ (estim.)':>22}{'US$/aprovada':>14}")
    cost_per = {}
    for arm in ("on", "off"):
        ps, ap_, pre_usd, rev_usd = arm_cost(arm)
        cpa = (pre_usd + rev_usd) / len(ap_) if ap_ else float("nan")
        cost_per[arm] = cpa
        att = statistics.mean([p["attempts"] for p in ps]) if ps else float("nan")
        print(f"  {arm:<10}{len(ps):>6}{len(ap_):>7}{('n/a' if att != att else f'{att:.2f}'):>11}{pre_usd:>14.2f}{rev_usd:>22.2f}{('n/a' if cpa != cpa else f'{cpa:.2f}'):>14}")
    print(f"  pré-gate = EXATO (total_cost_usd por run). revisor = ESTIMATIVA {a.reviewer_usd:.2f}/tentativa (E0). construtor = NÃO MEDIDO:")
    print("  o retrabalho do braço on (consertar o que a pré-revisão achou) não está em nenhum número acima — o custo real do on é MAIOR que o mostrado.")
    print("  (relógio: começa na PRIMEIRA linha do roster da branch — no braço on isso é o Step 2b, então o tempo da")
    print("   pré-revisão conta a desfavor do on, que é o certo: é custo dele)")
    for arm in ("on", "off"):
        ts_ = [p["t_pass_min"] for p in per.values() if p["arm"] == arm and p["t_pass_min"] is not None]
        print(f"  tempo da atribuição até o 1o PASS do gate ({arm}): "
              f"{'n/a' if not ts_ else 'mediana %.0f min (n=%d)' % (statistics.median(ts_), len(ts_))}  [proxy do tempo até o merge]")
    print()

    # ── veredito ──
    print("  ── VEREDITO (critério do ga-gnr3tw) ──")
    p_on = k_on / n_on if n_on else float("nan")
    if min_n < a.min_n:
        print(f"  INCONCLUSIVO: menor braço tem {min_n} < {a.min_n} branches. NÃO decida com isto; NÃO pare o experimento aqui.")
        return 0
    c_on, c_off = cost_per["on"], cost_per["off"]
    rate_ok = p_on >= a.target
    cost_ok = (c_on == c_on and c_off == c_off and c_on <= c_off)
    print(f"  on ≥ {pct(a.target)}?  {pct(p_on)}  → {'SIM' if rate_ok else 'NÃO'}")
    print(f"  US$/aprovada on ≤ off (PARCIAL, sem construtor)?  {('n/a' if c_on != c_on else f'{c_on:.2f}')} vs {('n/a' if c_off != c_off else f'{c_off:.2f}')}  → {'SIM' if cost_ok else 'NÃO'}")
    excl0 = (d == d) and dlo > 0
    print(f"  diferença exclui 0 (efeito real, não acaso)?  → {'SIM' if excl0 else 'NÃO'}")
    if rate_ok and cost_ok and excl0:
        print("  ► CRITÉRIO ATINGIDO — propor ligar a pré-revisão pra todos (decisão do Mayor; custo do construtor ainda não medido).")
    else:
        print("  ► CRITÉRIO NÃO ATINGIDO — escrever o relatório do porquê (qual condição falhou acima).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
