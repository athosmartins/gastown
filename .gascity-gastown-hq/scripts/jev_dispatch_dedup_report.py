#!/usr/bin/env python3
"""jev_dispatch_dedup_report.py (ga-55gq9p, epic ga-aijm2v) — summary table for the
dispatch-dedup shadow front (jev_dispatch_dedup_experiment.py's `run` command). Its own module
for the same reason jev_gate_fail_categoria_report.py is separate from the generic
jev_experiment_report.py: this front's records (mode "dispatch-dedup") hold a per-candidate
array, not a single yes/no suppression decision, and would not fit the generic tables.

THE QUESTION THE TABLE ANSWERS: of every bead the Pilot dispatched, on how many did Jev say
"a closed bead already resolved this, holding would have been correct" — and how does that
compare to the OFFLINE calibration precision/recall (32 hand-verified historical pairs, see
ga-55gq9p's own bead comment and jev_dispatch_dedup_experiment.py's `calibrate` command)?

WHAT IS MEASURED vs NOT (say every time, so nobody reads this as validated):
  - MEASURED here: how many live dispatches Jev flagged as "seria_segurada", against how many
    it checked, and the candidate recall surfaced for each flag.
  - NOT measured here: whether a LIVE flag was actually correct — nobody has gone back to
    confirm a live "seria_segurada" bead really was a duplicate. That is what the OFFLINE
    32-pair calibration (run separately, `calibrate` subcommand) is for: it is the only number
    in this whole front backed by a known-correct label, and the live table below should always
    be read next to it, never as its own validated accuracy.
  - NOT measured: any real dispatch has ever been held or rerouted because of this front —
    SHADOW means every real dispatch already happened by the time this logs anything.

CLI:
  python3 jev_dispatch_dedup_report.py [--resumo-pt] [--json] [--log PATH]
    default: the full English report; --resumo-pt: the short Portuguese block for the daily
    ntfy; --json: the raw summary.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import jev_dispatch_dedup_experiment as dd  # noqa: E402
import jev_experiment as je  # noqa: E402
import jev_quem_pensa_experiment as qp  # noqa: E402

SMALL_SAMPLE = 10


def dedupe_records(events: list[dict]) -> list[dict]:
    """One record per entity_id: the LAST answered (jev_ok=True) one, else the last failed
    one — same rule as jev_quem_pensa_report.dedupe_records / jev_gate_fail_categoria_report.
    dedupe_records, so a retried entity counts once and a later good answer replaces an
    earlier failure."""
    best: dict[str, dict] = {}
    for ev in events:
        if ev.get("mode") != dd.MODE or ev.get("experiment") != dd.EXPERIMENT or not ev.get("entity_id"):
            continue
        prev = best.get(ev["entity_id"])
        if prev is None or ev.get("jev_ok") is True or prev.get("jev_ok") is not True:
            best[ev["entity_id"]] = ev
    return list(best.values())


def load_records(log_path) -> list[dict]:
    return dedupe_records(qp._read_jsonl(log_path))


def summarize(records: list[dict]) -> dict:
    answered = [r for r in records if r.get("jev_ok") is True]
    flagged = [r for r in answered if r.get("seria_segurada")]
    zero_candidates = [r for r in answered if r.get("candidatos_checados", 0) == 0]
    per_candidate_calls = sum(r.get("candidatos_checados", 0) for r in answered)
    per_candidate_ok = sum(
        1 for r in answered for c in (r.get("candidatos") or []) if c.get("jev_ok") is True
    )
    tokens_in = sum(r.get("tokens_in", 0) or 0 for r in answered)
    tokens_out = sum(r.get("tokens_out", 0) or 0 for r in answered)
    stamps = sorted(t for t in (r.get("ts") for r in records) if t)
    return {
        "total": len(records),
        "answered": len(answered),
        "nao_sei": len(records) - len(answered),
        "zero_candidates": len(zero_candidates),
        "flagged": [{"bead": r.get("bead"), "melhor_candidato": r.get("melhor_candidato"),
                     "rig": r.get("rig"), "ts": r.get("ts")} for r in flagged],
        "n_flagged": len(flagged),
        "per_candidate_calls": per_candidate_calls,
        "per_candidate_ok": per_candidate_ok,
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
        "first_ts": stamps[0] if stamps else None,
        "last_ts": stamps[-1] if stamps else None,
    }


def _pct(num: int, den: int) -> str:
    return "n/a" if den == 0 else f"{100 * num / den:.0f}%"


def format_report(s: dict) -> str:
    lines = [
        "DISPATCH-DEDUP (Jev, SHADOW): before/soon after a Pilot dispatch, would a CLOSED bead "
        "already have resolved the same problem?",
        "Nothing below changed any real dispatch -- pure observation, run AFTER the real "
        "dispatch already happened. Live flags here are UNVALIDATED; the only validated numbers "
        "for this front are the offline 32-pair `calibrate` precision/recall (see ga-55gq9p).",
    ]
    if not s["total"]:
        lines.append("No records yet (this front logs only after the hourly order has run at least once).")
        return "\n".join(lines)
    lines += [
        "",
        f"── {s['total']} dispatches checked, {s['answered']} answered (bd_show + recall both "
        f"worked), {s['nao_sei']} nao_sei (bead or recall unreadable -- counted apart) ──",
    ]
    if s["first_ts"]:
        lines.append(f"   dispatches from {s['first_ts']} to {s['last_ts']}")
    if not s["answered"]:
        return "\n".join(lines)
    lines.append(
        f"   {s['zero_candidates']} of {s['answered']} had zero recall candidates (nothing "
        f"close enough in closed history to ask Jev about)"
    )
    small = " (small sample)" if s["n_flagged"] < SMALL_SAMPLE else ""
    lines.append(
        f"   flagged 'seria_segurada' (a closed candidate confidently resolves the same "
        f"problem): {s['n_flagged']} of {s['answered']} ({_pct(s['n_flagged'], s['answered'])}){small}"
    )
    if s["flagged"]:
        lines.append("   flagged dispatches (bead -> candidate that would have held it):")
        for f in s["flagged"][:20]:
            lines.append(f"     {f['bead']:<14} -> {f['melhor_candidato']:<14} rig={f['rig']} ts={f['ts']}")
        if len(s["flagged"]) > 20:
            lines.append(f"     ... and {len(s['flagged']) - 20} more")
    lines.append(
        f"   per-candidate Jev calls: {s['per_candidate_calls']} ({s['per_candidate_ok']} answered "
        f"ok) -- tokens_in={s['tokens_in']} tokens_out={s['tokens_out']}"
    )
    lines += [
        "",
        "MEASURED: how many live dispatches Jev flagged, and which candidate.",
        "NOT measured: whether a live flag was actually a real duplicate -- read this next to "
        "the offline calibrate() precision/recall, never as its own validated accuracy.",
    ]
    return "\n".join(lines)


def format_resumo_pt(s: dict) -> str:
    if not s["total"]:
        return "Dispatch-dedup (Jev, so observacao): ainda sem dados."
    if not s["answered"]:
        return f"Dispatch-dedup (Jev, so observacao): {s['total']} dispatches vistos, {s['nao_sei']} sem resposta (nao_sei)."
    parts = [
        "Dispatch-dedup (Jev, so observacao -- sem mudanca real no dispatch):",
        f"{s['answered']} dispatches checados, {s['n_flagged']} marcados 'seria segurada' "
        f"({_pct(s['n_flagged'], s['answered'])})"
        + (" (amostra pequena)" if s["n_flagged"] < SMALL_SAMPLE else "")
        + " -- ver calibracao offline (32 pares) para precisao/recall validados.",
    ]
    if s["nao_sei"]:
        parts.append(f"{s['nao_sei']} sem resposta (nao_sei)")
    return f"{parts[0]} {' | '.join(parts[1:])}" if len(parts) > 1 else parts[0]


def build_summary(log_path=None) -> dict:
    records = load_records(log_path or je.JEV_LOG)
    return summarize(records)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--resumo-pt", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--log", default=None)
    args = ap.parse_args()
    summary = build_summary(args.log)
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2, default=str))
    elif args.resumo_pt:
        print(format_resumo_pt(summary))
    else:
        print(format_report(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
