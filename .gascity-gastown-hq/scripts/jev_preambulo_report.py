#!/usr/bin/env python3
"""jev_preambulo_report.py (ga-aijm2v.7) — the "preambulo" table of the daily Jev report: what would Jev have
left out of each pool session's doctrine (jev_preambulo_experiment.py), and is that safe?

Its own module on purpose: the generic jev_experiment_report.py knows suppression and yes/no-shadow fronts, and
this front's records (mode "preambulo") are skipped there so they never count as suppression alerts.

THREE QUESTIONS THE TABLE ANSWERS
  1. SIZE OF THE PRIZE: per role and per section, how often would Jev cut, and how many tokens is that
     (ESTIMATED: chars cut / chars-per-token from the manifest; the ceiling — cutting every eligible section — is
     printed next to it so a mean is never read without its bound).
  2. IS THE SPLIT HONEST: while every session still gets the full doctrine (`aplicado` false), the `arm` a bead was
     assigned to must make NO difference at the gate. Approval at the FIRST review per arm, with Wilson intervals and
     a Newcombe interval for the difference — an A/A check, and the exact comparison the A/B will make.
  3. WOULD IT HAVE HURT: first-attempt rejections whose reason text cites a section Jev would have cut
     (per_task.eligible[*].cite_terms, case-insensitive substring). A HEURISTIC, said so in the report, and it can only
     miss (the reviewer may not name the rule) — so a 0 here is "no evidence of harm", never "proof of none".

WHAT IS MEASURED vs NOT
  - MEASURED: Jev's answers, the gate verdict of each bead's first review (recomputed from quality-gate.jsonl now, so a
    bead judged after its record was written still counts).
  - ESTIMATED: every token figure (chars / chars_per_token).
  - NOT measured: tokens per session per arm. That needs sessions that really receive the cut; the shadow phase has none.
  - Third states are never folded into a percentage: a failed/partial Jev call, a bead the gate never saw, a rejection
    whose reason could not be read are each counted APART and named.

CLI:
  python3 jev_preambulo_report.py [--resumo-pt] [--json] [--full-to PATH] [--log PATH] [--gate-log PATH] [--no-citations]
    default: the full English report; --resumo-pt: the short Portuguese block the daily ntfy appends;
    --full-to PATH also writes the full report there in the same run (the rejection-reason lookups read bd,
    so the daily job asks for both texts from ONE invocation instead of paying for them twice).
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import jev_experiment as je  # noqa: E402
import jev_gate_verdict_experiment as gv  # noqa: E402
import jev_preambulo_experiment as pe  # noqa: E402
import jev_quem_pensa_experiment as qp  # noqa: E402

MIN_SPAN_HOURS = 48.0
SMALL_SAMPLE = 10
MAX_CITATION_LOOKUPS = 25
Z95 = 1.959964


# ── statistics (stdlib) ──────────────────────────────────────────────────────────────
def wilson(k: int, n: int, z: float = Z95) -> tuple[float, float] | None:
    """Wilson score interval for k successes of n; None when n == 0 (no data is not a 0% rate)."""
    if n <= 0:
        return None
    p = k / n
    d = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / d
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return max(0.0, centre - half), min(1.0, centre + half)


def newcombe_diff(k1: int, n1: int, k2: int, n2: int, z: float = Z95) -> tuple[float, float, float] | None:
    """(difference p1-p2, low, high): Newcombe's hybrid-score interval for two independent proportions. None if either
    arm is empty."""
    if n1 <= 0 or n2 <= 0:
        return None
    p1, p2 = k1 / n1, k2 / n2
    l1, u1 = wilson(k1, n1, z)
    l2, u2 = wilson(k2, n2, z)
    d = p1 - p2
    return d, d - math.sqrt((p1 - l1) ** 2 + (u2 - p2) ** 2), d + math.sqrt((u1 - p1) ** 2 + (p2 - l2) ** 2)


# ── records ──────────────────────────────────────────────────────────────────────────
def dedupe_records(events: list[dict]) -> list[dict]:
    """One record per bead: an answered one wins over a failed one, later over earlier. A retried bead counts once and
    a failure logged AFTER an answer never erases it."""
    best: dict[str, dict] = {}
    for ev in events:
        if ev.get("mode") != pe.MODE or not ev.get("entity_id"):
            continue
        prev = best.get(ev["entity_id"])
        if prev is None or ev.get("jev_status") == "ok" or prev.get("jev_status") != "ok":
            best[ev["entity_id"]] = ev
    return list(best.values())


def load_records(log_path) -> list[dict]:
    return dedupe_records(qp._read_jsonl(log_path))


def first_review_by_bead(reviews_by_bead: dict[str, list[dict]]) -> dict[str, dict]:
    return {bead: revs[0] for bead, revs in reviews_by_bead.items() if revs}


# ── summary ──────────────────────────────────────────────────────────────────────────
def _section_row() -> dict:
    return {"asked": 0, "cut": 0, "kept_jev": 0, "kept_floor": 0, "kept_unavailable": 0, "kept_injection": 0, "kept_unknown": 0, "p_sum": 0.0}


def summarize(records: list[dict], first_reviews: dict[str, dict] | None, policy: dict | None,
              fetch_reason=None, max_lookups: int = MAX_CITATION_LOOKUPS) -> dict:
    """first_reviews None = the gate log could not be read (reported as unavailable, never as zero approvals).
    policy None = the manifest could not be loaded (the ceiling and the citation check are then unavailable).
    fetch_reason(gate_run) -> str | None reads a rejection's reason (None = unreadable); None = citations not checked."""
    status = defaultdict(int)
    for r in records:
        status[r.get("jev_status", "?")] += 1
    usable = [r for r in records if r.get("jev_status") in ("ok", "parcial")]

    roles: dict[str, dict] = {}
    sections: dict[str, dict] = defaultdict(_section_row)
    for r in usable:
        role = roles.setdefault(r.get("pool", "?"), {"n": 0, "cuts_something": 0, "tokens": 0, "chars": 0, "chars_doutrina": 0, "ceiling_tokens": 0})
        role["n"] += 1
        role["cuts_something"] += 1 if r.get("cortadas") else 0
        role["tokens"] += int(r.get("tokens_estimados_poupados") or 0)
        role["chars_doutrina"] += int(r.get("chars_doutrina_papel") or 0)
        if policy:
            role["ceiling_tokens"] += int(round(sum(policy["sizes"].get(s, 0) for s in r.get("elegiveis", [])) / policy["pt"]["chars_per_token"]))
        for sid in r.get("elegiveis", []):
            row = sections[sid]
            p = (r.get("prob") or {}).get(sid)
            if p is not None:
                row["asked"] += 1
                row["p_sum"] += float(p)
            why = ((r.get("motivos") or {}).get(sid) or "").split(":")[0]
            if why == "jev_dispensa":
                row["cut"] += 1
            elif why == "jev_precisa":
                row["kept_jev"] += 1
            elif why == "piso_estrutural":
                row["kept_floor"] += 1
            elif why == "suspeita_injecao":
                row["kept_injection"] += 1
            elif why == "jev_indisponivel":
                row["kept_unavailable"] += 1
            else:  # a motive this report does not know (or none at all): said so, not filed under a real answer
                row["kept_unknown"] += 1

    stamps = sorted(t for t in (r.get("ts") for r in records) if t)
    span_h = None
    if len(stamps) >= 2:
        a, b = gv._parse_ts(stamps[0]), gv._parse_ts(stamps[-1])
        if a and b:
            span_h = (b - a).total_seconds() / 3600.0

    applied = [r for r in usable if r.get("aplicado") is True]
    arms: dict[str, dict] = {a: {"n": 0, "gated": 0, "pass1": 0, "not_gated": 0, "would_cut_tokens": 0, "applied_n": 0, "applied_tokens": 0}
                             for a in ("control", "experiment")}
    arms_unknown = 0
    for r in usable:
        row = arms.get(r.get("arm"))
        if row is None:
            arms_unknown += 1  # missing/unknown arm: outside both columns, but counted and shown — never silently dropped
            continue
        row["n"] += 1
        row["would_cut_tokens"] += int(r.get("tokens_estimados_poupados") or 0)
        if r.get("aplicado") is True:
            row["applied_n"] += 1
            row["applied_tokens"] += int(r.get("tokens_estimados_poupados") or 0)
        if first_reviews is not None:
            rv = first_reviews.get(r.get("bead"))
            if rv is None:
                row["not_gated"] += 1
            else:
                row["gated"] += 1
                row["pass1"] += 1 if rv.get("result") == "PASS" else 0

    gate = {"available": first_reviews is not None, "arms": arms, "arms_unknown": arms_unknown, "diff": None}
    if first_reviews is not None:
        gate["diff"] = newcombe_diff(arms["experiment"]["pass1"], arms["experiment"]["gated"], arms["control"]["pass1"], arms["control"]["gated"])

    citations = {"checked": 0, "unreadable": 0, "capped": 0, "candidates": 0, "hits": [], "available": fetch_reason is not None and policy is not None and first_reviews is not None}
    if citations["available"]:
        cand = []
        for r in usable:
            rv = first_reviews.get(r.get("bead"))
            if rv is not None and rv.get("result") == "FAIL" and r.get("cortadas"):
                cand.append((r, rv))
        cand.sort(key=lambda x: x[1].get("ts", ""), reverse=True)  # most recent first: they are the ones still in the window
        citations["candidates"] = len(cand)
        for r, rv in cand[:max_lookups]:
            reason = fetch_reason(rv.get("gate_run"))
            if reason is None:
                citations["unreadable"] += 1
                continue
            citations["checked"] += 1
            low = reason.lower()
            for sid in r["cortadas"]:
                terms = [t for t in policy["pt"]["eligible"].get(sid, {}).get("cite_terms", []) if t.lower() in low]
                if terms:
                    # the most specific term that matched (a reason naming "pending-engine-window" also contains "engine-window")
                    citations["hits"].append({"bead": r["bead"], "section": sid, "term": max(terms, key=len), "gate_run": rv.get("gate_run")})
        citations["capped"] = max(0, len(cand) - max_lookups)

    limiar = policy["pt"]["threshold"] if policy else next((r["limiar"] for r in reversed(usable) if r.get("limiar") is not None), None)
    cpt = policy["pt"]["chars_per_token"] if policy else None
    return {
        "total": len(records),
        "limiar": limiar,
        "chars_per_token": cpt,
        "status": dict(status),
        "usable": len(usable),
        "applied": len(applied),
        "roles": roles,
        "sections": {k: dict(v) for k, v in sections.items()},
        "span_hours": span_h,
        "first_ts": stamps[0] if stamps else None,
        "last_ts": stamps[-1] if stamps else None,
        "gate": gate,
        "citations": citations,
        "policy_available": policy is not None,
    }


# ── text ─────────────────────────────────────────────────────────────────────────────
def _pct(num: int, den: int) -> str:
    return "n/a" if den == 0 else f"{100 * num / den:.0f}%"


def _ci(k: int, n: int) -> str:
    w = wilson(k, n)
    return "n/a" if w is None else f"{_pct(k, n)} [{100 * w[0]:.0f}-{100 * w[1]:.0f}%] of {n}" + (" (small sample)" if n < SMALL_SAMPLE else "")


def format_report(s: dict) -> str:
    lines = [
        "PREAMBULO (Jev, phase 2 SHADOW): which optional doctrine sections would Jev leave out of each pool task?",
        "Every session still receives the FULL doctrine — nothing below alters any session (aplicado=false)."
        + (f" [{s['applied']} record(s) say aplicado=true: the live cut has started]" if s["applied"] else ""),
    ]
    if not s["total"]:
        lines.append("No preambulo records yet (the hourly jev-preambulo order writes one per task a pool session picked up).")
        return "\n".join(lines)
    st = s["status"]
    lines.append(
        f"{s['total']} tasks: {st.get('ok', 0)} answered by Jev, {st.get('parcial', 0)} partial, {st.get('falhou', 0)} failed "
        f"(Jev down/malformed — counted apart, those sections stay), {st.get('nao_chamado_injecao', 0)} not asked (injection marker in the text — everything stays)"
    )
    if s["first_ts"]:
        span = "n/a" if s["span_hours"] is None else f"{s['span_hours']:.0f} h"
        flag = "" if (s["span_hours"] is not None and s["span_hours"] >= MIN_SPAN_HOURS) else f"  [PRELIMINARY: less than {MIN_SPAN_HOURS:.0f} h of records]"
        lines.append(f"records from {s['first_ts']} to {s['last_ts']} ({span}){flag}")

    lines += ["", "── size of the prize, per role (ESTIMATED tokens = chars cut / chars-per-token) ──"]
    for role, r in sorted(s["roles"].items()):
        ceil = f", ceiling {r['ceiling_tokens'] / r['n']:.0f} (cut every eligible section)" if s["policy_available"] and r["n"] else ""
        share = (f" = {100 * r['tokens'] / max(1.0, r['chars_doutrina'] / s['chars_per_token']):.0f}% of its doctrine"
                 if r["chars_doutrina"] and s["chars_per_token"] else "")
        lines.append(f"   {role:<10} {r['n']:>4} tasks: Jev would cut >=1 section in {_pct(r['cuts_something'], r['n'])}; mean {r['tokens'] / r['n']:.0f} tokens/task{ceil}{share}")

    thr = "?" if s["limiar"] is None else s["limiar"]
    lines += ["", f"── per section (asked = Jev gave an answer; a section is cut only if P(needed) < {thr}) ──",
              f"   {'section':<26} {'asked':>5} {'cut':>5} {'kept:jev':>9} {'kept:floor':>10} {'kept:no-jev':>11} {'kept:inject':>11} {'mean P':>7}"]
    for sid, r in sorted(s["sections"].items()):
        mean_p = "n/a" if not r["asked"] else f"{r['p_sum'] / r['asked']:.2f}"
        lines.append(f"   {sid:<26} {r['asked']:>5} {r['cut']:>5} {r['kept_jev']:>9} {r['kept_floor']:>10} {r['kept_unavailable']:>11} {r['kept_injection']:>11} {mean_p:>7}")
    unknown = sum(r["kept_unknown"] for r in s["sections"].values())
    if unknown:
        lines.append(f"   ! {unknown} section decision(s) carry an unrecognised or missing motive — kept, and counted apart (not in any column above)")

    g = s["gate"]
    lines += ["", "── approval at the FIRST gate review, by arm (A/A while nothing is applied: the arms must not differ) ──"]
    if not g["available"]:
        lines.append("   gate log unreadable — approval NOT computed (this is not zero).")
    else:
        for arm in ("control", "experiment"):
            a = g["arms"][arm]
            lines.append(f"   {arm:<10} {_ci(a['pass1'], a['gated']):<40} {a['not_gated']} task(s) never seen by the gate (counted apart) | est. tokens the arm would cut: {a['would_cut_tokens']:,}")
        if g["arms_unknown"]:
            lines.append(f"   ! {g['arms_unknown']} record(s) with no/unknown arm — in neither row above (counted apart)")
        if g["diff"] is None:
            lines.append("   difference experiment - control: n/a (an arm has no gated task yet)")
        else:
            d, lo, hi = g["diff"]
            note = ""
            if s["applied"] == 0 and (lo > 0 or hi < 0):
                note = "  <- the arms differ while NOTHING is applied: look at the split before trusting any A/B"
            lines.append(f"   difference experiment - control: {100 * d:+.1f} pp, 95% CI [{100 * lo:+.1f}, {100 * hi:+.1f}] (Newcombe){note}")

    c = s["citations"]
    lines += ["", "── first-attempt rejections that cite a section Jev would have cut (HEURISTIC: cite_terms substring; can only miss) ──"]
    if not c["available"]:
        lines.append("   not checked (policy, gate log or reason reader unavailable).")
    else:
        lines.append(f"   {c['candidates']} first-attempt rejection(s) with a would-be cut; reasons read: {c['checked']}, unreadable: {c['unreadable']}, not looked up (cap): {c['capped']}")
        if c["hits"]:
            for h in c["hits"][:8]:
                lines.append(f"   ! {h['bead']}: rejection mentions '{h['term']}' — section '{h['section']}' would have been cut (gate_run {h['gate_run']})")
        else:
            lines.append("   no rejection cites a would-be-cut section (absence of evidence; the reviewer may not name the rule).")

    lines += ["", "MEASURED: Jev's answers; the gate verdict of each task's first review (recomputed from quality-gate.jsonl now).",
              "ESTIMATED: every token figure. NOT measured: tokens per session per arm — needs sessions that really receive the cut (`gc prime` has no per-task input yet)."]
    return "\n".join(lines)


def format_resumo_pt(s: dict) -> str:
    """Short lines for the daily ntfy. Says 'so observacao' so nobody reads it as a change."""
    if not s["total"]:
        return "Preambulo por tarefa (so observacao): ainda sem dados."
    parts = [f"Preambulo por tarefa (so observacao, toda sessao segue com a doutrina inteira): {s['total']} tarefas"]
    u = s["usable"]
    cuts = sum(r["cuts_something"] for r in s["roles"].values())
    tokens = sum(r["tokens"] for r in s["roles"].values())
    if u:
        parts.append(f"Jev cortaria >=1 secao em {_pct(cuts, u)} (~{tokens / u:.0f} tokens/tarefa, estimado)")
    g = s["gate"]
    if g["available"]:
        ctl, exp = g["arms"]["control"], g["arms"]["experiment"]
        if ctl["gated"] and exp["gated"]:
            parts.append(f"aprovacao 1a tentativa: controle {_pct(ctl['pass1'], ctl['gated'])} vs experimento {_pct(exp['pass1'], exp['gated'])} (sem corte real: devem ser iguais)")
    c = s["citations"]
    if c["available"] and c["candidates"]:
        parts.append(f"reprovacoes que citam secao cortada: {len(c['hits'])} de {c['checked']} lidas")
    bad = s["status"].get("falhou", 0) + s["status"].get("parcial", 0)
    if bad:
        parts.append(f"{bad} sem resposta completa do Jev (secoes ficam)")
    if s["span_hours"] is None or s["span_hours"] < MIN_SPAN_HOURS:
        parts.append(f"preliminar: menos de {MIN_SPAN_HOURS:.0f}h de dados")
    return f"{parts[0]} | {' | '.join(parts[1:])}" if len(parts) > 1 else parts[0]


# ── glue ─────────────────────────────────────────────────────────────────────────────
def build_summary(log_path=None, gate_log=None, citations: bool = True, policy: dict | None = None, fetch_reason=None) -> dict:
    records = load_records(log_path or je.JEV_LOG)
    gate_log = gate_log or f"{gv.DEFAULT_GC_CITY}/.gc/quality-gate.jsonl"
    first = None
    if Path(gate_log).exists():
        first = first_review_by_bead(qp.load_reviews(gate_log))
    if policy is None:
        try:
            policy = pe.load_policy()
        except pe.PolicyError:
            policy = None
    if citations and fetch_reason is None:
        city = gv.DEFAULT_GC_CITY

        def fetch_reason(gate_run):  # noqa: F811 — the real reader; tests inject their own
            comments = qp._bd_comments(city, gate_run) if gate_run else None
            return qp.fail_reason(comments) if comments is not None else None
    return summarize(records, first, policy, fetch_reason=fetch_reason if citations else None)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--resumo-pt", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--log", default=None)
    ap.add_argument("--gate-log", default=None)
    ap.add_argument("--no-citations", action="store_true", help="skip the bd reads that fetch rejection reasons")
    ap.add_argument("--full-to", default=None, help="also write the full report to this file (same run)")
    args = ap.parse_args()
    summary = build_summary(args.log, args.gate_log, citations=not args.no_citations)
    if args.full_to:
        Path(args.full_to).write_text(format_report(summary) + "\n", encoding="utf-8")
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2, default=str))
    elif args.resumo_pt:
        print(format_resumo_pt(summary))
    else:
        print(format_report(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
