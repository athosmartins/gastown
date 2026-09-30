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
    ga-5vi6cp), rotulada como tal. O custo do pré-gate é EXATO só para os runs cujo registro PROVA o custo
    (cost_known=true e um cost_usd numérico, finito e >= 0 — run_cost()). Um run sem evento de resultado (timeout, kill,
    stream sem resultado) tem custo DESCONHECIDO e pode ter gasto até o teto por run: ele NÃO entra como 0 — a soma vira
    LIMITE INFERIOR (≥), e a condição de custo do critério fica INDETERMINADA. Registro sem cost_known=true (inclusive um
    cost_usd=0 de um escritor antigo) também é desconhecido: só o escritor atual sabe dizer que sabia.
  * runs INTERROMPIDOS. O escritor grava DUAS linhas por run lançado, amarradas por run_id: PENDING (verdict=PENDING, antes
    de o claude começar) e a FINAL (o desfecho). Aqui elas são UM run só (settle_runs: a FINAL vence a PENDING). Um run sem
    FINAL foi lançado e gastou — só que ninguém sabe quanto nem com que resultado. Há três causas e o relatório as separa,
    nenhuma vira "SEM REGISTRO" (que quer dizer: o construtor nem rodou o Step 2b): (a) INTERROMPIDO por sinal ou saída
    anormal (a FINAL diz reason=interrupted:<SIG> / abnormal-exit); (b) SEM DESFECHO GRAVADO há mais de --pending-grace-min
    (SIGKILL, reboot, queda — a PENDING ficou); (c) EM CURSO (PENDING recente: o run pode ainda terminar). Nos três o custo
    é DESCONHECIDO — entram como run lançado sem custo (soma vira ≥, condição de custo INDETERMINADA), nunca como EXATO.
  * runs em que NENHUM revisor julgou (timeout com revisor vivo, revisor que morreu antes de julgar): a linha "Gate run
    complete" do dispatcher só emite PASS ou FAIL, e esses runs saem como FAIL. NÃO são separáveis deste log. A taxa da
    1a tentativa os conta como reprovação — viés para BAIXO nos dois braços, e mais severo no teste absoluto "on >= alvo".
    O que o script imprime como "token inesperado" é só a guarda para o dia em que o dispatcher emitir outra palavra;
    hoje lê 0 e NÃO mede infra.
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
ANY_STAMP = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]")
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
                row = json.loads(line)
            except ValueError:
                bad += 1
                continue
            # valid JSON that is not a record (12, null, [..], "x") is as unreadable as truncated JSON: counted, and it
            # must not crash the report on the first r.get() (that would print a traceback instead of the measurement)
            if isinstance(row, dict):
                rows.append(row)
            else:
                bad += 1
    return rows, bad


def run_cost(r):
    """US$ of one launched run, or None when the record does not PROVE a cost.

    Three states, never two: known (cost_known is True AND cost_usd is a finite number >= 0), unknown (anything else).
    The old reading — float(r.get("cost_usd", 0) or 0) — turned a missing, null, zero-by-default or garbage cost into 0.00
    and printed it as EXATO; a string there raised inside float(). bool is excluded: True is an int in Python."""
    if r.get("cost_known") is not True:
        return None
    c = r.get("cost_usd")
    if isinstance(c, bool) or not isinstance(c, (int, float)) or not math.isfinite(c) or c < 0:
        return None
    return float(c)


def settle_runs(rows):
    """One record per LAUNCHED run. A launched run leaves two rows tied by run_id — PENDING (written before claude starts) and
    the FINAL outcome — and they are ONE run: counting both would double every run and its cost. The FINAL row wins over the
    PENDING one; a PENDING with no FINAL stays (the run was launched and its outcome is unknown). A launched row with no
    run_id cannot be tied to any other row, so it is its own run — merging unrelated rows would be the wrong direction to err."""
    best, anonymous = {}, []
    for r in rows:
        if r.get("event") != "run" or r.get("launched") is not True:
            continue
        rid = r.get("run_id")
        if not isinstance(rid, str) or not rid:
            anonymous.append(r)
            continue
        cur = best.get(rid)
        # a PENDING row never replaces a settled one; anything else replaces (among two settled rows the later one wins)
        if cur is None or r.get("verdict") != "PENDING" or cur.get("verdict") == "PENDING":
            best[rid] = r
    return list(best.values()) + anonymous


def run_kind(r, now, grace_s):
    """'finished' | 'interrupted' | 'lost' | 'live' — what became of one settled launched run. Three unfinished states, never one:
      interrupted  the writer itself settled it as interrupted (a TERM/INT/HUP handler, or the EXIT net: abnormal-exit)
      live         a PENDING row younger than the grace window: the run may simply still be going
      lost         a PENDING row older than that (SIGKILL, reboot, a crash) — or one whose age cannot be established (an
                   unreadable ts, a stamp in the future): an unknown age is not evidence that it is still running"""
    if r.get("verdict") == "PENDING":
        try:
            age = now - parse_utc(r["ts"])
        except (KeyError, ValueError, TypeError):
            return "lost"
        return "live" if 0 <= age <= grace_s else "lost"
    if r.get("verdict") == "INCONCLUSIVE" and str(r.get("reason", "")).startswith(("interrupted", "abnormal-exit")):
        return "interrupted"
    return "finished"


# O que o revisor VIU decide o que o seu PASS vale. Sobre um diff que ele viu só em parte (ou de cobertura desconhecida) o
# PASS diz "nada nos arquivos que li", que não é a liberação que o PASS total dá ao construtor: misturar os dois na linha de
# calibração faria "pré-revisão PASS → gate 1a-PASS" medir uma coisa que não é a que o Step 2b promete.
PASS_PARCIAL = "PASS sem cobertura total"
# Um run lançado que nunca teve desfecho (PENDING sem FINAL, ou interrompido) não tem veredito: não é PASS, não é FAIL e não é
# um INCONCLUSIVE de "não deu pra julgar" — é um run cujo veredito ninguém sabe. Grupo próprio, fora da calibração do PASS.
SEM_DESFECHO = "run sem desfecho (interrompido ou em curso)"


def run_coverage(r):
    """'full' | 'partial' | 'unknown' — quanto do diff o revisor viu neste run. Três estados, nunca dois.

    Registro novo traz `coverage` (full | partial:<n>/<m> | unknown). Registro anterior a ele traz só `partial`: False quer
    dizer que o diff inteiro foi mostrado, True que foi parcial; ausente ou de outro tipo NÃO quer dizer 'inteiro'."""
    cov = r.get("coverage")
    if isinstance(cov, str) and cov:
        return "full" if cov == "full" else ("partial" if cov.startswith("partial") else "unknown")
    if r.get("partial") is False:
        return "full"
    if r.get("partial") is True:
        return "partial"
    return "unknown"


def pre_group(r):
    """O veredito de um run da pré-revisão para a calibração: PASS só com cobertura total; PASS_PARCIAL quando o revisor
    disse PASS sem ter visto tudo — venha isso como PASS de um escritor antigo (cobertura não total) ou como o INCONCLUSIVE
    partial-diff / coverage-unknown do escritor atual (o script recusa a liberação, e o registro guarda o motivo)."""
    v = r.get("verdict", "?")
    if v == "PENDING" or (v == "INCONCLUSIVE" and str(r.get("reason", "")).startswith(("interrupted", "abnormal-exit"))):
        return SEM_DESFECHO
    if v == "PASS" and run_coverage(r) != "full":
        return PASS_PARCIAL
    if v == "INCONCLUSIVE" and str(r.get("reason", "")).startswith(("partial-diff", "coverage-unknown")):
        return PASS_PARCIAL
    return v


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
    ap.add_argument("--wait-h", type=float, default=48.0,
                    help="horas que uma branch ainda sem desfecho do gate conta como 'aguardando'; depois disso ela vai para 'sem desfecho localizável'")
    ap.add_argument("--pending-grace-min", type=float, default=40.0,
                    help="minutos que um run com linha PENDING e sem FINAL conta como 'em curso' (padrão 40 = teto de 25 min do run + kill-after + folga); depois disso é 'sem desfecho gravado'")
    ap.add_argument("--now", type=float, help="época UTC 'de agora' (só para teste; padrão: o relógio)")
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
    log_start = None               # the earliest dated line of the log: how far back it can testify at all
    with open(log_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            t = ANY_STAMP.match(line)
            if t:
                try:
                    e = parse_local(t.group(1))
                    log_start = e if log_start is None else min(log_start, e)
                except (ValueError, OverflowError):
                    pass
            m = GATE_LINE.match(line)
            if m:
                outcomes[m.group(3)].append((parse_local(m.group(1)), m.group(4)))

    # ── runs por bead ──
    launched = defaultdict(list)    # bead -> [record] (só as que lançaram o claude; UM registro por run — settle_runs)
    refused = defaultdict(list)     # bead -> [reason] (guarda/busy/etc.: nada foi gasto)
    capped = set()
    for r in settle_runs(rows):
        if r.get("bead"):
            launched[r["bead"]].append(r)
    for r in rows:
        if r.get("event") != "run" or not r.get("bead") or r.get("launched") is True:
            continue
        if r.get("reason") == "max-runs":
            capped.add(r["bead"])
        elif r.get("verdict") == "INCONCLUSIVE":
            refused[r["bead"]].append(str(r.get("reason", "?")).split(":")[0])

    # ── por branch: 1a tentativa, tentativas totais, tempo até o 1o PASS ──
    per = {}
    now = a.now if a.now is not None else time.time()
    # "no gate outcome found for this branch" is NOT one answer. Only the first is a bead that simply has not been judged yet:
    #   waiting   the assignment is recent (<= --wait-h): the gate has not run, or not finished, yet
    #   stale     older than that and still no outcome: renamed branch, never submitted to the gate, or a stuck gate
    #   log_gap   the dispatcher log does not reach back to the assignment (rotated, or no dated line at all): an outcome may
    #             exist and simply not be readable here
    # All three stay out of the rates; each is printed, so none of them can pass for "still waiting".
    waiting = stale = log_gap = 0
    for b, v in roster.items():
        after = [(t, vd) for (t, vd) in outcomes.get(b, []) if t >= v["ts"] - 60]
        if not after:
            if log_start is None or v["ts"] < log_start - 60:
                log_gap += 1
            elif now - v["ts"] <= a.wait_h * 3600:
                waiting += 1
            else:
                stale += 1
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
    print(f"  aguardando 1o desfecho do gate: {waiting} (atribuídas há ≤ {a.wait_h:g}h)   desfecho com token inesperado (nem PASS nem FAIL): on={other['on']} off={other['off']}")
    print("  nota: FAIL inclui runs em que NENHUM revisor julgou (timeout ou morte do revisor) — NÃO separável deste log, que só emite PASS ou FAIL.")
    print("        O 'token inesperado' acima é só a guarda para o dia em que o dispatcher emitir outra palavra: hoje lê 0 e NÃO mede infra.")
    if stale or log_gap:
        print(f"  ⚠ SEM desfecho e FORA da conta: {stale} sem desfecho localizável após {a.wait_h:g}h (branch renomeada, nunca chegou ao gate ou gate parado), "
              f"{log_gap} que o log do dispatcher não cobre (log rodado ou sem linha datada — pode haver desfecho que não dá pra ler daqui)")
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
            verdicts[pre_group(launched[b][0])] += 1
        print("  1o veredito da pré-revisão nas beads que rodaram: " + ", ".join(f"{k}={v}" for k, v in sorted(verdicts.items())))
        for v in ("PASS", PASS_PARCIAL, "FAIL"):
            grp = [per[b] for b in per if per[b]["arm"] == "on" and per[b]["bead"] in launched and pre_group(launched[per[b]["bead"]][0]) == v and per[b]["first"] in ("PASS", "FAIL")]
            if grp:
                kk = sum(1 for p in grp if p["first"] == "PASS")
                nota = "  [FORA da calibração do PASS: o revisor não viu o diff inteiro]" if v == PASS_PARCIAL else "  [calibração; n pequeno, olhe o IC antes de concluir]"
                print(f"     pré-revisão {v} → gate 1a-PASS {kk}/{len(grp)} ({pct(kk/len(grp))}){nota}")
    print("  (a taxa por INTENÇÃO DE TRATAR acima já inclui quem não rodou; baixa aderência DILUI o efeito, não o inverte)")
    # ── runs lançados sem desfecho: a causa é dita, e o custo é DESCONHECIDO nos três casos ──
    # Todo o roster, não só as branches que já têm desfecho do gate: um run interrompido numa bead que ainda aguarda o gate
    # também gastou, e a tabela de custo (que só conta branches com desfecho) não o mostraria.
    grace_s = a.pending_grace_min * 60
    bead_arm = {v["bead"]: v["arm"] for v in roster.values() if v["bead"]}
    unfinished = {"on": defaultdict(int), "off": defaultdict(int)}
    for b, rs in launched.items():
        if b not in bead_arm:
            continue
        for r in rs:
            kind = run_kind(r, now, grace_s)
            if kind != "finished":
                unfinished[bead_arm[b]][kind] += 1
    print("  ── RUNS LANÇADOS SEM DESFECHO (o custo de cada um é DESCONHECIDO) ──")
    print(f"  INTERROMPIDOS por sinal ou saída anormal (TERM/INT/HUP, dreno, abnormal-exit): on={unfinished['on']['interrupted']} off={unfinished['off']['interrupted']}")
    print(f"  SEM DESFECHO GRAVADO há mais de {a.pending_grace_min:g} min (SIGKILL, reboot, queda — só a linha PENDING ficou): on={unfinished['on']['lost']} off={unfinished['off']['lost']}")
    print(f"  EM CURSO (linha PENDING de ≤ {a.pending_grace_min:g} min — pode ainda terminar): on={unfinished['on']['live']} off={unfinished['off']['live']}")
    print("  (não são 'SEM REGISTRO': o run FOI lançado e gastou. Contam no teto por bead e entram nos custos como desconhecidos — nunca como 0, nunca como EXATO.)")
    contaminated = sorted({p["bead"] for p in per.values() if p["arm"] == "off" and launched.get(p["bead"])})
    if contaminated:
        print(f"  ⚠ CONTROLE CONTAMINADO: {len(contaminated)} bead(s) do braço OFF rodaram a pré-revisão (--force): {', '.join(contaminated[:5])}"
              f"{' …' if len(contaminated) > 5 else ''} — por INTENÇÃO DE TRATAR continuam contando como off, mas o contraste on×off está mais fraco do que parece")
    print()

    # ── custo / tempo ──
    def arm_cost(arm):
        ps = [p for p in per.values() if p["arm"] == arm]
        approved = [p for p in ps if p["approved"]]
        # known and unknown are summed APART: an unknown run contributes nothing to the sum AND is counted, so the figure
        # can be printed as the lower bound it is (never as a total that happens to include a 0 it invented)
        costs = [run_cost(r) for b in {p["bead"] for p in ps} for r in launched.get(b, [])]
        pre_usd = sum(c for c in costs if c is not None)
        n_unknown = sum(1 for c in costs if c is None)
        rev_usd = a.reviewer_usd * sum(p["attempts"] for p in ps)
        return ps, approved, pre_usd, rev_usd, n_unknown

    def lb(x, unknown):   # "≥" marks a figure that is only a lower bound
        return ("n/a" if x != x else (("≥" if unknown else "") + f"{x:.2f}"))
    # Runs of roster beads that are NOT in this table (no gate outcome yet: waiting, stale, log gap, or a first outcome that is neither
    # PASS nor FAIL) still spent money, and a run killed mid-review is the kind that never reaches an outcome. Leaving them out of the
    # "is any cost unknown?" test would print EXATO with that spend missing — the same hole as an unrecorded run, one step later.
    # Their known cost stays out of the SUM (the table's population is stated below); their UNKNOWN cost is what forces the lower bound.
    in_table = {p["bead"] for p in per.values()}
    outside = {"on": 0, "off": 0}
    for b, rs in launched.items():
        if b in bead_arm and b not in in_table:
            outside[bead_arm[b]] += sum(1 for r in rs if run_cost(r) is None)
    print("  ── CUSTO POR BEAD APROVADA (PARCIAL) ──")
    print(f"  {'braço':<10}{'beads':>6}{'aprov.':>7}{'tent./bead':>11}{'pré-gate US$':>14}{'revisor US$ (estim.)':>22}{'US$/aprovada':>14}")
    cost_per, unk = {}, {}
    for arm in ("on", "off"):
        ps, ap_, pre_usd, rev_usd, unk[arm] = arm_cost(arm)
        unk[arm] += outside[arm]
        cpa = (pre_usd + rev_usd) / len(ap_) if ap_ else float("nan")
        cost_per[arm] = cpa
        att = statistics.mean([p["attempts"] for p in ps]) if ps else float("nan")
        print(f"  {arm:<10}{len(ps):>6}{len(ap_):>7}{('n/a' if att != att else f'{att:.2f}'):>11}{lb(pre_usd, unk[arm]):>14}{rev_usd:>22.2f}{lb(cpa, unk[arm]):>14}")
    unknown_total = unk["on"] + unk["off"]
    n_cost = {arm: sum(1 for p in per.values() if p["arm"] == arm) for arm in ("on", "off")}
    print(f"  (esta tabela conta TODA branch com algum desfecho do gate: on={n_cost['on']} off={n_cost['off']}; a tabela da taxa acima só as "
          f"de 1o desfecho PASS/FAIL: on={n_on} off={n_off} — a diferença são as de 1o desfecho com token inesperado: on={other['on']} off={other['off']})")
    if unknown_total:
        outside_total = outside["on"] + outside["off"]
        outside_note = (f" Inclui {outside_total} run(s) de beads do roster que ainda não têm desfecho do gate: fora da soma, mas gastaram."
                        if outside_total else "")
        print(f"  ⚠ run(s) do pré-gate lançados SEM custo conhecido: on={unk['on']} off={unk['off']}"
              f" (timeout, kill, stream sem evento de resultado, ou run interrompido / sem desfecho gravado) — um run assim pode ter gasto até o teto de gasto por run."
              f"{outside_note}"
              f" O pré-gate US$ e o US$/aprovada acima são LIMITE INFERIOR (≥) e a condição de custo fica INDETERMINADA.")
        print("  pré-gate = LIMITE INFERIOR (soma só dos runs com total_cost_usd conhecido).")
    else:
        print("  pré-gate = EXATO (total_cost_usd por run).")
    print(f"  revisor = ESTIMATIVA {a.reviewer_usd:.2f}/tentativa (E0). construtor = NÃO MEDIDO:")
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
    # three states: True / False / None (= cannot tell). With ANY launched run of unknown cost in either arm the two
    # US$/aprovada are lower bounds, and "on <= off" between two lower bounds proves nothing in either direction. The same
    # goes for an arm with no approved bead: its US$/aprovada is NaN (a division by zero approvals), and a comparison against
    # NaN is False — which would print NÃO for something that was never computed.
    cost_calc = c_on == c_on and c_off == c_off
    cost_ok = None if (unknown_total or not cost_calc) else (c_on <= c_off)
    cost_why = (f"custo do pré-gate desconhecido em {unknown_total} run(s)" if unknown_total
                else "um braço sem bead aprovada: US$/aprovada não calculável")
    print("  (nota: a taxa conta como reprovação os runs em que nenhum revisor julgou — viés para BAIXO em 'on ≥ alvo': um NÃO abaixo pode ser em parte infra, não conteúdo.)")
    print(f"  on ≥ {pct(a.target)}?  {pct(p_on)}  → {'SIM' if rate_ok else 'NÃO'}")
    print(f"  US$/aprovada on ≤ off (PARCIAL, sem construtor)?  {lb(c_on, unk['on'])} vs {lb(c_off, unk['off'])}  → "
          f"{'INDETERMINADO (' + cost_why + ')' if cost_ok is None else ('SIM' if cost_ok else 'NÃO')}")
    excl0 = (d == d) and dlo > 0
    print(f"  diferença exclui 0 (efeito real, não acaso)?  → {'SIM' if excl0 else 'NÃO'}")
    if not rate_ok or not excl0 or cost_ok is False:
        # a failed condition is decisive whatever the unknown cost turns out to be
        print("  ► CRITÉRIO NÃO ATINGIDO — escrever o relatório do porquê (qual condição falhou acima).")
    elif cost_ok is None:
        print(f"  ► CRITÉRIO INDETERMINADO — taxa e diferença passam, mas a condição de custo não se decide ({cost_why}): "
              "NÃO proponha ligar a pré-revisão com este número. Não pare o experimento; apure de novo.")
    else:
        print("  ► CRITÉRIO ATINGIDO — propor ligar a pré-revisão pra todos (decisão do Mayor; custo do construtor ainda não medido).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
