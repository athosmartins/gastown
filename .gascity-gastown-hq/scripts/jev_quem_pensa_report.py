#!/usr/bin/env python3
"""jev_quem_pensa_report.py (ga-aijm2v.9) — calibration table for the quem-pensa shadow
experiments (jev_quem_pensa_experiment.py). Its own module on purpose: the generic
jev_experiment_report.py knows suppression and yes/no-shadow fronts, and this front's records
(mode "quem-pensa") are skipped there so they never leak into those tables.

THE QUESTION THE TABLE ANSWERS (ga-aijm2v.9, phase 1): does Jev's read predict the gate?
  - new task: does "facil" predict approval at the FIRST review (a Haiku candidate), and does
    "dificil" predict a rejection?
  - repair:   does "raciocinio" predict that the repair is rejected again (an Opus candidate),
    and does "mecanico" predict a clean pass?
Rows are grouped by Jev's choice x the calibrated probability band of that choice, so a
"confident" bucket can be compared with the base rate of everything Jev answered.

WHAT IS MEASURED vs NOT:
  - MEASURED: Jev's choice/probability/confidence, the verdict of the gate review that judged
    the decision, and the attempts until approval (recomputed from quality-gate.jsonl at
    report time, so a bead approved after the record was written still counts).
  - NOT measured in phase 1: tokens per attempt. Attempts are the proxy (each attempt is one
    fresh worker + one fresh reviewer session). Said in the report, every time.
  - "nao_sei" (Jev down/failed) is counted apart and NEVER folded into any percentage.

CLI:
  python3 jev_quem_pensa_report.py [--resumo-pt] [--json] [--log PATH] [--gate-log PATH]
    default: the full English report on stdout; --resumo-pt: the short Portuguese block the
    daily ntfy appends; --json: the raw summary.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import jev_experiment as je  # noqa: E402
import jev_gate_verdict_experiment as gv  # noqa: E402
import jev_quem_pensa_experiment as qp  # noqa: E402

MIN_SPAN_HOURS = 48.0
SMALL_SAMPLE = 10
BANDS = [("P>=0.85", 0.85, 1.01), ("0.70-0.85", 0.70, 0.85), ("P<0.70", 0.0, 0.70)]
ESCOLHAS = {qp.EXP_NOVA: ["facil", "media", "dificil"], qp.EXP_CONSERTO: ["mecanico", "raciocinio"]}
# the option whose confident answer would change the model, per experiment
CANDIDATE = {qp.EXP_NOVA: ("facil", "haiku"), qp.EXP_CONSERTO: ("raciocinio", "opus")}


def band_of(p: float) -> str:
    for name, lo, hi in BANDS:
        if lo <= p < hi:
            return name
    return BANDS[-1][0]


def dedupe_records(events: list[dict]) -> list[dict]:
    """One record per (experiment, entity): the LAST answered one, else the last failed one.
    A retried entity therefore counts once, a later good answer replaces an earlier "nao_sei",
    and a failure logged AFTER an answer never erases it."""
    best: dict[tuple[str, str], dict] = {}
    for ev in events:
        if ev.get("mode") != qp.MODE or not ev.get("entity_id"):
            continue
        key = (ev.get("experiment", ""), ev["entity_id"])
        prev = best.get(key)
        if prev is None or ev.get("jev_ok") is True or prev.get("jev_ok") is not True:
            best[key] = ev
    return list(best.values())


def load_records(log_path) -> list[dict]:
    return dedupe_records(qp._read_jsonl(log_path))


def attempts_until_approval(reviews_by_bead: dict[str, list[dict]]) -> dict[str, int | None]:
    """bead -> number of gate reviews up to and including the first PASS; None = not approved yet."""
    out: dict[str, int | None] = {}
    for bead, revs in reviews_by_bead.items():
        out[bead] = next((i + 1 for i, r in enumerate(revs) if r["result"] == "PASS"), None)
    return out


def _new_row() -> dict:
    return {"n": 0, "pass": 0, "attempts": [], "pending": 0}


def summarize(records: list[dict], attempts_by_bead: dict[str, int | None] | None) -> dict:
    """attempts_by_bead None = the gate log could not be read: attempts are reported as
    unavailable rather than as zero."""
    out: dict = {}
    for exp in (qp.EXP_NOVA, qp.EXP_CONSERTO):
        recs = [r for r in records if r.get("experiment") == exp]
        answered = [r for r in recs if r.get("jev_ok") is True]
        rows: dict[tuple[str, str], dict] = defaultdict(_new_row)
        base = _new_row()
        cand_choice, cand_model = CANDIDATE[exp]
        cand = _new_row()
        model_counts: dict[str, int] = defaultdict(int)
        for r in answered:
            model_counts[r.get("modelo_jev", "?")] += 1
            targets = [rows[(r.get("escolha_jev"), band_of(float(r.get("prob_escolha") or 0.0)))], base]
            if r.get("modelo_jev") == cand_model:
                targets.append(cand)
            for row in targets:
                row["n"] += 1
                if r.get("desfecho_veredito") == "PASS":
                    row["pass"] += 1
                if attempts_by_bead is not None:
                    a = attempts_by_bead.get(r.get("bead"))
                    if a is None:
                        row["pending"] += 1
                    else:
                        row["attempts"].append(a)
        stamps = sorted(t for t in (r.get("desfecho_ts") for r in recs) if t)
        span_h = None
        if len(stamps) >= 2:
            a, b = gv._parse_ts(stamps[0]), gv._parse_ts(stamps[-1])
            if a and b:
                span_h = (b - a).total_seconds() / 3600.0
        out[exp] = {
            "total": len(recs),
            "answered": len(answered),
            "nao_sei": len(recs) - len(answered),
            "rows": {f"{k[0]}|{k[1]}": v for k, v in rows.items()},
            "base": base,
            "candidate": cand,
            "candidate_choice": cand_choice,
            "candidate_model": cand_model,
            "models": dict(model_counts),
            "span_hours": span_h,
            "first_ts": stamps[0] if stamps else None,
            "last_ts": stamps[-1] if stamps else None,
            "attempts_measured": attempts_by_bead is not None,
        }
    return out


def _pct(num: int, den: int) -> str:
    return "n/a" if den == 0 else f"{100 * num / den:.0f}%"


def _mean(xs: list[int]) -> str:
    return "n/a" if not xs else f"{sum(xs) / len(xs):.2f}"


def _row_cells(row: dict, measured: bool) -> tuple[str, str, str]:
    small = " (small sample)" if row["n"] < SMALL_SAMPLE else ""
    ok = f"{_pct(row['pass'], row['n'])} of {row['n']}{small}"
    if not measured:
        return ok, "n/a (gate log unreadable)", ""
    return ok, _mean(row["attempts"]), f"{row['pending']} not approved yet"


def format_report(summary: dict, now: datetime | None = None) -> str:
    now = now or datetime.now(timezone.utc)
    lines = [
        "QUEM-PENSA (Jev, phase 1 SHADOW): would Jev's model choice have paid off?",
        f"Model actually used by pools and repairs: {qp.MODELO_PADRAO} — UNCHANGED in phase 1; nothing below alters any session.",
    ]
    if not any(s["total"] for s in summary.values()):
        lines.append("No quem-pensa records yet (the experiment logs only after the gate has judged a task).")
        return "\n".join(lines)
    for exp in (qp.EXP_NOVA, qp.EXP_CONSERTO):
        s = summary[exp]
        lines += ["", f"── {exp}: {s['total']} decisions, {s['answered']} answered by Jev, {s['nao_sei']} nao_sei (Jev down/failed — counted apart) ──"]
        if s["first_ts"]:
            span = "n/a" if s["span_hours"] is None else f"{s['span_hours']:.0f} h"
            flag = ""
            if s["span_hours"] is None or s["span_hours"] < MIN_SPAN_HOURS:
                flag = f"  [PRELIMINARY: less than {MIN_SPAN_HOURS:.0f} h of gate outcomes]"
            lines.append(f"   gate outcomes from {s['first_ts']} to {s['last_ts']} ({span}){flag}")
        if not s["answered"]:
            continue
        what = "approved at the first review" if exp == qp.EXP_NOVA else "repair approved"
        lines.append(f"   {'Jev says':<11} {'P(choice)':<10} {what:<34} {'mean attempts to approval':<26} pending")
        for escolha in ESCOLHAS[exp]:
            for name, _, _ in BANDS:
                row = s["rows"].get(f"{escolha}|{name}")
                if not row:
                    continue
                ok, att, pend = _row_cells(row, s["attempts_measured"])
                lines.append(f"   {escolha:<11} {name:<10} {ok:<34} {att:<26} {pend}")
        ok, att, pend = _row_cells(s["base"], s["attempts_measured"])
        lines.append(f"   {'ALL':<11} {'':<10} {ok:<34} {att:<26} {pend}   <- base rate of everything Jev answered")
        c = s["candidate"]
        lines.append(
            f"   {s['candidate_model'].upper()} candidates ({s['candidate_choice']}, probability AND Jev confidence >= {qp.CONFIDENCE_THRESHOLD}): "
            f"{c['n']} of {s['answered']} — {what}: {_pct(c['pass'], c['n'])}"
            + (" (small sample)" if c["n"] < SMALL_SAMPLE else "")
            + f" vs {_pct(s['base']['pass'], s['base']['n'])} base"
        )
        lines.append("   model Jev would have used: " + ", ".join(f"{m}={n}" for m, n in sorted(s["models"].items())))
    lines += [
        "",
        "MEASURED: Jev's answers; the gate verdict that judged each decision; attempts until approval (recomputed from quality-gate.jsonl now).",
        "NOT measured in phase 1: tokens per attempt — attempts are the proxy (each = one fresh worker + one fresh reviewer session).",
    ]
    return "\n".join(lines)


def format_resumo_pt(summary: dict) -> str:
    """Two short lines for the daily ntfy. Says 'so observacao' so nobody reads it as a change."""
    if not any(s["total"] for s in summary.values()):
        return "Quem pensa (so observacao): ainda sem dados."
    parts = ["Quem pensa (so observacao, o modelo real segue Sonnet):"]
    n = summary[qp.EXP_NOVA]
    if n["answered"]:
        c = n["candidate"]
        parts.append(
            f"tarefas novas {n['answered']}: Jev poria {c['n']} no Haiku (tarefa facil); "
            f"essas passaram de primeira {_pct(c['pass'], c['n'])} vs {_pct(n['base']['pass'], n['base']['n'])} geral"
            + (" (amostra pequena)" if c["n"] < SMALL_SAMPLE else "")
        )
    k = summary[qp.EXP_CONSERTO]
    if k["answered"]:
        c = k["candidate"]
        parts.append(
            f"consertos {k['answered']}: Jev poria {c['n']} no Opus (conserto que exige raciocinio); "
            f"conserto aprovado {_pct(c['pass'], c['n'])} vs {_pct(k['base']['pass'], k['base']['n'])} geral"
            + (" (amostra pequena)" if c["n"] < SMALL_SAMPLE else "")
        )
    nao_sei = n["nao_sei"] + k["nao_sei"]
    if nao_sei:
        parts.append(f"{nao_sei} sem resposta do Jev (nao_sei)")
    spans = [s["span_hours"] for s in summary.values() if s["span_hours"] is not None]
    if not spans or max(spans) < MIN_SPAN_HOURS:
        parts.append(f"preliminar: menos de {MIN_SPAN_HOURS:.0f}h de dados")
    return f"{parts[0]} {' | '.join(parts[1:])}" if len(parts) > 1 else parts[0]


def build_summary(log_path=None, gate_log=None) -> dict:
    records = load_records(log_path or je.JEV_LOG)
    gate_log = gate_log or f"{gv.DEFAULT_GC_CITY}/.gc/quality-gate.jsonl"
    attempts = None
    if Path(gate_log).exists():
        attempts = attempts_until_approval(qp.load_reviews(gate_log))
    return summarize(records, attempts)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--resumo-pt", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--log", default=None)
    ap.add_argument("--gate-log", default=None)
    args = ap.parse_args()
    summary = build_summary(args.log, args.gate_log)
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2, default=str))
    elif args.resumo_pt:
        print(format_resumo_pt(summary))
    else:
        print(format_report(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
