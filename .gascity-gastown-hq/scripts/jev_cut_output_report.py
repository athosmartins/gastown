#!/usr/bin/env python3
"""jev_cut_output_report.py (ga-wk0qi2, child of ga-aijm2v) — daily/cumulative digest for the
cut-large-output SHADOW front (cut-output-shadow.py logs the raw shadow records; jev_cut_output_
join.py adds the offline "was the cut content referenced later" verdict). Reports CUMULATIVE
totals to date, same choice as jev_gate_fail_classify_report.py — this front is high-VOLUME (it
fires on every large Bash output across every pool session, unlike a rare real-review-FAIL), so a
running total is more informative on any given day than a slice that might be near-empty on a
quiet day.

NUMBERS ONLY, NO VERDICT: this script never says "safe to go live" or "not safe" — ga-aijm2v's
own doctrine for every front here is "measure first, a HUMAN decides after seeing the number"
(this bead's own Autorização section, verbatim). The report surfaces the measured
referenced-later rate next to the bead's own stated expectation (~8% of reread) for a human to
compare, and nothing more.

CLI:
  python3 jev_cut_output_report.py                 full report, cumulative to date
  python3 jev_cut_output_report.py --resumo-pt      short Portuguese summary block
  python3 jev_cut_output_report.py selftest         pure (writes its own temp log), no network
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import jev_experiment as je  # noqa: E402
from jev_cut_output_join import JOIN_MODE, SOURCE_EXPERIMENTS, read_jsonl  # noqa: E402


def compute_stats(records: list[dict]) -> dict:
    """Pure. Splits records into the two source experiments (fixed-rule, Jev-tier) and their
    shadow-join counterparts (keyed by entity_id), then aggregates. Never raises on a malformed
    or missing field on any one record -- one bad record is skipped, not fatal to the report."""
    stats: dict = {exp: {
        "count": 0,
        "tokens_would_save_total": 0,
        "tokens_would_save_known": 0,  # how many records had a non-None tokens_would_save
        "jev_unreachable_count": 0,  # cut-output-jev only
    } for exp in SOURCE_EXPERIMENTS}
    joins: dict[tuple[str, str], bool | None] = {}

    for rec in records:
        mode = rec.get("mode")
        exp = rec.get("experiment")
        if exp not in SOURCE_EXPERIMENTS:
            continue
        if mode == JOIN_MODE:
            eid = rec.get("entity_id")
            if eid is not None:
                joins[(exp, eid)] = rec.get("referenced_later")
            continue
        if mode != "shadow":
            continue
        s = stats[exp]
        s["count"] += 1
        saved = rec.get("tokens_would_save")
        if isinstance(saved, (int, float)):
            s["tokens_would_save_total"] += saved
            s["tokens_would_save_known"] += 1
        if exp == "cut-output-jev" and rec.get("jev_ok") is False:
            s["jev_unreachable_count"] += 1

    referenced_true = 0
    referenced_false = 0
    referenced_unknown = 0
    for v in joins.values():
        if v is True:
            referenced_true += 1
        elif v is False:
            referenced_false += 1
        else:
            referenced_unknown += 1

    stats["joins"] = {
        "total": len(joins),
        "referenced_true": referenced_true,
        "referenced_false": referenced_false,
        "referenced_unknown": referenced_unknown,
        "referenced_rate": (referenced_true / (referenced_true + referenced_false)) if (referenced_true + referenced_false) > 0 else None,
    }
    return stats


def format_report(stats: dict) -> str:
    lines = ["Cut-large-output (ga-wk0qi2, SHADOW — nothing is actually cut yet):"]
    for exp, label in (("cut-output-fixed", "Fixed-rule tier (pytest/log-tail, no AI)"), ("cut-output-jev", "Jev tier (unstructured large blocks)")):
        s = stats[exp]
        avg = (s["tokens_would_save_total"] / s["tokens_would_save_known"]) if s["tokens_would_save_known"] else None
        lines.append(f"  {label}: {s['count']} case(s), avg tokens_would_save={avg:.0f}" if avg is not None else f"  {label}: {s['count']} case(s), no measurable tokens_would_save yet")
        if exp == "cut-output-jev":
            lines.append(f"    Jev unreachable in {s['jev_unreachable_count']}/{s['count']} case(s) (third state, never counted as a cut)")
    j = stats["joins"]
    if j["total"] == 0:
        lines.append("  Offline join (referenced-later): no joined cases yet (run jev_cut_output_join.py).")
    else:
        rate_str = f"{j['referenced_rate']*100:.1f}%" if j["referenced_rate"] is not None else "n/a"
        lines.append(
            f"  Offline join: {j['total']} case(s) checked — referenced later: {j['referenced_true']}, "
            f"not referenced: {j['referenced_false']}, unknown: {j['referenced_unknown']} "
            f"(measured rate: {rate_str}; bead's own expected ceiling: ~8% of reread — compare, do not auto-decide)"
        )
    return "\n".join(lines)


def format_resumo_pt(stats: dict) -> str:
    fixed = stats["cut-output-fixed"]["count"]
    jev = stats["cut-output-jev"]["count"]
    j = stats["joins"]
    rate_str = f"{j['referenced_rate']*100:.1f}%" if j["referenced_rate"] is not None else "sem dado"
    return (
        f"Cortar-saída-grande (SOMBRA, nada é cortado de verdade ainda): {fixed} caso(s) via regra fixa, "
        f"{jev} via Jev. Join offline: {j['total']} conferido(s), taxa de 'precisou depois' = {rate_str} "
        f"(teto esperado do bead: ~8%)."
    )


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        return _selftest()

    ap = argparse.ArgumentParser()
    ap.add_argument("--resumo-pt", action="store_true")
    ap.add_argument("--log", default=None, help="override jev-experiment.jsonl path (test seam)")
    args = ap.parse_args()

    log_path = Path(args.log) if args.log else je.JEV_LOG
    records = read_jsonl(log_path)
    stats = compute_stats(records)
    print(format_resumo_pt(stats) if args.resumo_pt else format_report(stats))
    return 0


def _selftest() -> int:
    passed = 0
    failed = 0

    def ok(label: str, cond: bool) -> None:
        nonlocal passed, failed
        if cond:
            passed += 1
            print(f"  ok  {label}")
        else:
            failed += 1
            print(f"  FAIL {label}")

    records = [
        {"mode": "shadow", "experiment": "cut-output-fixed", "entity_id": "e1", "tokens_would_save": 100},
        {"mode": "shadow", "experiment": "cut-output-fixed", "entity_id": "e2", "tokens_would_save": 200},
        {"mode": "shadow", "experiment": "cut-output-jev", "entity_id": "e3", "tokens_would_save": 50, "jev_ok": True},
        {"mode": "shadow", "experiment": "cut-output-jev", "entity_id": "e4", "tokens_would_save": None, "jev_ok": False},
        {"mode": "shadow-join", "experiment": "cut-output-fixed", "entity_id": "e1", "referenced_later": True},
        {"mode": "shadow-join", "experiment": "cut-output-fixed", "entity_id": "e2", "referenced_later": False},
        {"mode": "shadow-join", "experiment": "cut-output-jev", "entity_id": "e3", "referenced_later": False},
        {"mode": "shadow", "experiment": "unrelated-front", "entity_id": "e9", "tokens_would_save": 999},
    ]
    stats = compute_stats(records)
    ok("fixed-rule count", stats["cut-output-fixed"]["count"] == 2)
    ok("fixed-rule tokens_would_save_total", stats["cut-output-fixed"]["tokens_would_save_total"] == 300)
    ok("jev-tier count", stats["cut-output-jev"]["count"] == 2)
    ok("jev-tier tokens_would_save_known excludes the None case", stats["cut-output-jev"]["tokens_would_save_known"] == 1)
    ok("jev-tier jev_unreachable_count", stats["cut-output-jev"]["jev_unreachable_count"] == 1)
    ok("unrelated-front is ignored entirely", "unrelated-front" not in stats)
    ok("joins total = 3", stats["joins"]["total"] == 3)
    ok("joins referenced_true = 1", stats["joins"]["referenced_true"] == 1)
    ok("joins referenced_false = 2", stats["joins"]["referenced_false"] == 2)
    ok("joins referenced_rate = 1/3", abs(stats["joins"]["referenced_rate"] - (1 / 3)) < 1e-9)

    report_text = format_report(stats)
    ok("format_report mentions both tiers", "Fixed-rule tier" in report_text and "Jev tier" in report_text)
    ok("format_report never claims a verdict (no 'safe'/'unsafe' word)", "safe" not in report_text.lower())

    pt = format_resumo_pt(stats)
    ok("format_resumo_pt is non-empty and mentions SOMBRA", "SOMBRA" in pt)

    empty_stats = compute_stats([])
    ok("compute_stats on empty input never raises, counts are zero", empty_stats["cut-output-fixed"]["count"] == 0 and empty_stats["joins"]["total"] == 0)
    ok("format_report on empty stats doesn't crash and says no joined cases yet", "no joined cases yet" in format_report(empty_stats))
    ok("format_resumo_pt on empty stats doesn't crash", isinstance(format_resumo_pt(empty_stats), str))

    print(f"\njev_cut_output_report selftest: PASS={passed} FAIL={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
