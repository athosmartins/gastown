#!/usr/bin/env python3
"""jev_gate_fail_categoria_report.py (ga-bwzzqd, epic ga-aijm2v) — distribution table for the
gate-fail-categoria shadow front (jev_gate_fail_categoria_experiment.py). Its own module for
the same reason jev_quem_pensa_report.py is separate from the generic jev_experiment_report.py:
this front's records (mode "gate-fail-categoria") have their own schema (a 5-way category, not
a yes/no suppression decision) and would not fit the generic tables.

THE QUESTION THE TABLE ANSWERS: of every gate rejection that got a repair attempt, what
fraction does Jev call "ajuste pequeno e localizado" (the ONE category this front proposes as
a "conserto leve" — minimal-context repair — candidate, ga-bwzzqd's Mecanismo), and does that
group actually repair in fewer attempts than the base rate?

WHAT IS MEASURED vs NOT (say every time, so nobody reads this as validated):
  - MEASURED: Jev's per-category answers, the verdict of the review that judged the repair,
    and attempts-until-approval (recomputed from quality-gate.jsonl at report time).
  - NOT measured here: any comparison against a HAND-LABELED ground truth. ga-bwzzqd's Medir
    (a)/(b) — labeling ~100 historical FAILs by hand and scoring Jev against those labels — is
    separate follow-up work; every number below is Jev grading itself, not validated accuracy.
  - NOT measured: tokens or outcome of an actual "conserto leve" session — none has run. This
    front is pure observation; nothing it logs has changed which session repairs a bead.

CLI:
  python3 jev_gate_fail_categoria_report.py [--resumo-pt] [--json] [--log PATH] [--gate-log PATH]
    default: the full English report; --resumo-pt: the short Portuguese block for the daily
    ntfy; --json: the raw summary.
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
import jev_gate_fail_categoria_experiment as fc  # noqa: E402
import jev_gate_verdict_experiment as gv  # noqa: E402
import jev_quem_pensa_experiment as qp  # noqa: E402

MIN_SPAN_HOURS = 48.0
SMALL_SAMPLE = 10
CATEGORIES = list(fc.CATEGORY_QUESTIONS)  # fixed order, matches the experiment's own dict


def dedupe_records(events: list[dict]) -> list[dict]:
    """One record per entity_id: the LAST answered (jev_ok=True) one, else the last failed
    one — same rule as jev_quem_pensa_report.dedupe_records, so a retried entity counts once
    and a later good answer replaces an earlier nao_sei."""
    best: dict[str, dict] = {}
    for ev in events:
        if ev.get("mode") != fc.MODE or ev.get("experiment") != fc.EXPERIMENT or not ev.get("entity_id"):
            continue
        prev = best.get(ev["entity_id"])
        if prev is None or ev.get("jev_ok") is True or prev.get("jev_ok") is not True:
            best[ev["entity_id"]] = ev
    return list(best.values())


def load_records(log_path) -> list[dict]:
    return dedupe_records(qp._read_jsonl(log_path))


def attempts_until_approval(reviews_by_bead: dict[str, list[dict]]) -> dict[str, int | None]:
    """bead -> number of gate reviews up to and including the first PASS; None = not approved
    yet. Same definition as jev_quem_pensa_report's own helper (kept here too so this report
    never has to import THAT report module just for one function)."""
    out: dict[str, int | None] = {}
    for bead, revs in reviews_by_bead.items():
        out[bead] = next((i + 1 for i, r in enumerate(revs) if r["result"] == "PASS"), None)
    return out


def _new_row() -> dict:
    return {"n": 0, "pass": 0, "attempts": [], "pending": 0}


def summarize(records: list[dict], attempts_by_bead: dict[str, int | None] | None) -> dict:
    """attempts_by_bead None = the gate log could not be read: attempts are reported as
    unavailable rather than as zero -- the same third-state discipline as every other Jev
    report in this city."""
    answered = [r for r in records if r.get("jev_ok") is True]
    rows: dict[str, dict] = defaultdict(_new_row)
    base = _new_row()
    leve = _new_row()  # the "seria_leve" (conserto-leve candidate) rows, across any category
    for r in answered:
        cat = r.get("categoria_jev") or "incerta"
        targets = [rows[cat], base]
        if r.get("seria_leve"):
            targets.append(leve)
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
    stamps = sorted(t for t in (r.get("desfecho_ts") for r in records) if t)
    span_h = None
    if len(stamps) >= 2:
        a, b = gv._parse_ts(stamps[0]), gv._parse_ts(stamps[-1])
        if a and b:
            span_h = (b - a).total_seconds() / 3600.0
    return {
        "total": len(records),
        "answered": len(answered),
        "nao_sei": len(records) - len(answered),
        "rows": dict(rows),
        "base": base,
        "leve": leve,
        "span_hours": span_h,
        "first_ts": stamps[0] if stamps else None,
        "last_ts": stamps[-1] if stamps else None,
        "attempts_measured": attempts_by_bead is not None,
    }


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


def format_report(s: dict, now: datetime | None = None) -> str:
    now = now or datetime.now(timezone.utc)
    lines = [
        "GATE-FAIL-CATEGORIA (Jev, SHADOW): why did the reviewer reject it, and would a "
        "'conserto leve' (minimal-context repair) have been a candidate?",
        "Nothing below changed any real session -- pure observation. No calibration against "
        f"hand-labeled ground truth yet ('{fc.LIGHT_FIX_CATEGORY}' below is Jev's own raw read, unvalidated).",
    ]
    if not s["total"]:
        lines.append("No records yet (this front logs only after a repair's review lands).")
        return "\n".join(lines)
    lines += [
        "",
        f"── {s['total']} repair-review decisions, {s['answered']} answered by Jev, "
        f"{s['nao_sei']} nao_sei (Jev down/every question garbled/no category cleared the floor "
        f"-- counted apart) ──",
    ]
    if s["first_ts"]:
        span = "n/a" if s["span_hours"] is None else f"{s['span_hours']:.0f} h"
        flag = ""
        if s["span_hours"] is None or s["span_hours"] < MIN_SPAN_HOURS:
            flag = f"  [PRELIMINARY: less than {MIN_SPAN_HOURS:.0f} h of gate outcomes]"
        lines.append(f"   gate outcomes from {s['first_ts']} to {s['last_ts']} ({span}){flag}")
    if not s["answered"]:
        return "\n".join(lines)
    lines.append(f"   {'categoria (Jev)':<16} {'repair approved':<30} {'mean attempts to approval':<26} pending")
    for cat in CATEGORIES + ["incerta"]:
        row = s["rows"].get(cat)
        if not row:
            continue
        ok, att, pend = _row_cells(row, s["attempts_measured"])
        lines.append(f"   {cat:<16} {ok:<30} {att:<26} {pend}")
    ok, att, pend = _row_cells(s["base"], s["attempts_measured"])
    lines.append(f"   {'ALL':<16} {ok:<30} {att:<26} {pend}   <- base rate of everything Jev answered")
    lv = s["leve"]
    ok, att, pend = _row_cells(lv, s["attempts_measured"])
    lines.append(
        f"   '{fc.LIGHT_FIX_CATEGORY}' confident (>= {fc.CONFIDENCE_THRESHOLD}, the 'conserto leve' candidates): "
        f"{lv['n']} of {s['answered']} -- repair approved: {ok}, mean attempts: {att}, {pend}"
    )
    lines += [
        "",
        "MEASURED: Jev's per-category answers; the gate verdict of the review that judged the "
        "repair; attempts until approval (recomputed from quality-gate.jsonl now).",
        "NOT measured: accuracy against hand-labeled FAILs (ga-bwzzqd Medir a/b, not done here); "
        "tokens/outcome of an actual light-fix session (none has run).",
    ]
    return "\n".join(lines)


def format_resumo_pt(s: dict) -> str:
    if not s["total"]:
        return "Gate-fail-categoria (Jev, so observacao): ainda sem dados."
    if not s["answered"]:
        return f"Gate-fail-categoria (Jev, so observacao): {s['total']} consertos vistos, {s['nao_sei']} sem resposta do Jev (nao_sei)."
    lv = s["leve"]
    parts = [
        "Gate-fail-categoria (Jev, so observacao — sem mudanca real):",
        f"{s['answered']} consertos classificados, {lv['n']} 'ajuste pequeno' com confianca "
        f">= {fc.CONFIDENCE_THRESHOLD} (candidatos a conserto leve); desses, aprovado "
        f"{_pct(lv['pass'], lv['n'])} vs {_pct(s['base']['pass'], s['base']['n'])} geral"
        + (" (amostra pequena)" if lv["n"] < SMALL_SAMPLE else ""),
    ]
    if s["nao_sei"]:
        parts.append(f"{s['nao_sei']} sem resposta do Jev (nao_sei)")
    if s["span_hours"] is None or s["span_hours"] < MIN_SPAN_HOURS:
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
