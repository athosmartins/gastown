#!/usr/bin/env python3
"""jev_experiment_report.py (wa-dln9g) — end-of-day report for the Jev A/B experiment
(see jev_experiment.py for the harness itself and the full design rationale).

Reads JEV_LOG (one JSON line per evaluated candidate escalation — only escalations the
underlying watchdog's OWN heuristic already decided to fire are logged; see
jev_experiment.py's --heuristic-would-escalate gate) and reports, for a given day:

  MEASURED (never estimated):
    - control arm: how many candidate escalations actually fired (100% of them, by
      construction — control never suppresses).
    - experiment arm: how many candidate escalations fired vs were suppressed, and
      Jev's own real token cost for every call it made (input/output, straight from
      Cloudflare's response `usage` field).
    - escalation-count reduction: experiment's fire rate vs control's fire rate, as a
      plain percentage. This needs no cost model at all — it's a headcount, not tokens.

  ESTIMATED (always labeled as such, never blended into the measured numbers above):
    - tokens "saved" by each suppression, using BASELINE_TOKENS_PER_ESCALATION — a
      provisional placeholder (see the constant below), not something derived from
      real per-escalation session-transcript measurement yet. Until that measurement
      exists, treat this number as an order-of-magnitude sketch, not a fact.

Usage: python3 jev_experiment_report.py [--date YYYY-MM-DD] [--experiment NAME] [--json]
Defaults to today (UTC) and all experiments in the log.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

JEV_LOG = Path(os.environ.get("JEV_EXPERIMENT_LOG", "/Users/athos/gt/.gascity-gastown-hq/.gc/logs/jev-experiment.jsonl"))

# ── PROVISIONAL baseline, not measured (wa-dln9g) ──────────────────────────────────
# What a single "wake Mayor for one mail-triage item" cycle plausibly costs in tokens,
# ballparked from this session's own observed pattern of a few thousand tokens for a
# simple few-tool-call triage turn, riding on an already-warm/cached system prompt —
# NOT from an automated measurement of real session transcripts (that would require
# correlating mail timestamps to session-transcript spans, deliberately deferred out
# of v1 as its own follow-up rather than rushed here — see wa-dln9g comments).
# Replace this constant (and mark it MEASURED instead of PROVISIONAL in the report
# below) once that correlation exists. Until then every "tokens saved" figure in this
# report is explicitly an estimate built on a guess, not a fact — say so, every time.
BASELINE_TOKENS_PER_ESCALATION_PROVISIONAL = 4000


def load_events(date: str | None, experiment: str | None) -> list[dict]:
    if not JEV_LOG.exists():
        return []
    out = []
    with JEV_LOG.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue  # a corrupt line is data-quality noise, not a reason to crash the report
            if date and not ev.get("ts", "").startswith(date):
                continue
            if experiment and ev.get("experiment") != experiment:
                continue
            out.append(ev)
    return out


def summarize(events: list[dict]) -> dict:
    by_exp: dict[str, dict] = defaultdict(
        lambda: {
            "control_fired": 0,
            "experiment_fired": 0,
            "experiment_suppressed": 0,
            "experiment_jev_unavailable": 0,  # ok=False for a reason OTHER than "control arm" itself
            "jev_tokens_in": 0,
            "jev_tokens_out": 0,
        }
    )
    for ev in events:
        s = by_exp[ev.get("experiment", "unknown")]
        if ev.get("arm") == "control":
            s["control_fired"] += 1
            continue
        # experiment arm
        if ev.get("suppress"):
            s["experiment_suppressed"] += 1
        else:
            s["experiment_fired"] += 1
            if not ev.get("jev_ok"):
                s["experiment_jev_unavailable"] += 1
        s["jev_tokens_in"] += int(ev.get("jev_tokens_in") or 0)
        s["jev_tokens_out"] += int(ev.get("jev_tokens_out") or 0)
    return dict(by_exp)


def format_report(summary: dict, date_label: str) -> str:
    if not summary:
        return f"Jev experiment report ({date_label}): no candidate escalations logged for this window."

    lines = [f"Jev experiment report — {date_label}", ""]
    for name, s in sorted(summary.items()):
        control_total = s["control_fired"]
        exp_total = s["experiment_fired"] + s["experiment_suppressed"]
        lines.append(f"## {name}")
        lines.append(f"  Control arm : {control_total} candidate escalation(s), {control_total} fired (100% — control never suppresses)")
        lines.append(
            f"  Experiment arm: {exp_total} candidate escalation(s), "
            f"{s['experiment_fired']} fired, {s['experiment_suppressed']} suppressed"
            + (f" ({s['experiment_jev_unavailable']} of the fired ones fired because Jev was unavailable/uncredentialed, not because it said yes)" if s["experiment_jev_unavailable"] else "")
        )
        if control_total > 0 and exp_total > 0:
            control_rate = control_total / control_total  # trivially 1.0, kept explicit for readability
            exp_rate = s["experiment_fired"] / exp_total
            reduction_pct = (1 - exp_rate / control_rate) * 100
            lines.append(f"  MEASURED escalation-count reduction (experiment vs control fire rate): {reduction_pct:.1f}%")
        else:
            lines.append("  MEASURED escalation-count reduction: n/a (need >=1 candidate in both arms same day)")
        lines.append(f"  Jev cost (MEASURED, from real API usage): {s['jev_tokens_in']} input + {s['jev_tokens_out']} output tokens")
        avoided_estimate = s["experiment_suppressed"] * BASELINE_TOKENS_PER_ESCALATION_PROVISIONAL
        net_estimate = avoided_estimate - s["jev_tokens_in"] - s["jev_tokens_out"]
        lines.append(
            f"  Tokens avoided (ESTIMATED, PROVISIONAL baseline={BASELINE_TOKENS_PER_ESCALATION_PROVISIONAL}/escalation, "
            f"NOT yet measured from real session transcripts): "
            f"{s['experiment_suppressed']} suppressed x baseline - Jev cost = ~{net_estimate} tokens"
        )
        if control_total > 0:
            pct_of_control_estimate = 100 * net_estimate / (control_total * BASELINE_TOKENS_PER_ESCALATION_PROVISIONAL)
            lines.append(f"  ESTIMATED % tokens saved vs an all-control baseline: {pct_of_control_estimate:.1f}%")
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--date", default=None, help="YYYY-MM-DD (UTC); default: report over ALL logged data")
    ap.add_argument("--experiment", default=None, help="filter to one experiment name")
    ap.add_argument("--json", action="store_true", help="print the raw summary dict as JSON instead of prose")
    args = ap.parse_args()

    events = load_events(args.date, args.experiment)
    summary = summarize(events)

    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        print(format_report(summary, args.date or "all-time"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
