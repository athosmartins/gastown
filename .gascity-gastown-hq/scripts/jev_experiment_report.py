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

SHADOW MODE (ga-aijm2v.1/F0): a separate event shape (mode=="shadow", from
jev_experiment.py's evaluate_shadow()/`evaluate-shadow` CLI) where the real decisor's
decision — not Jev's — is what actually happened. These events never enter the
MEASURED/ESTIMATED numbers above (summarize() skips them explicitly so they can never
silently pollute the suppression-experiment counts) and get their OWN report section:

  MEASURED (never estimated):
    - concordance: how often Jev's own lean (noul >= 0.5) matched decisao_atual, as a
      plain percentage over COMPARABLE evaluations only (jev_ok=True) — an unavailable
      Jev is counted separately and NEVER folded into "agreed" or "disagreed" (third
      state; see the TERCEIRO ESTADO note in jev_experiment.py's evaluate_shadow()).
    - would-dispense count: how many evaluations Jev was confident enough (either
      direction, >= the confidence threshold) that a live deployment could have
      skipped the real decisor for that one case.
    - Jev's own real token cost for every call it made.

  ESTIMATED (always labeled as such, never blended into the measured numbers above):
    - tokens the real decisor would have saved on the would-dispense cases: the
      caller's OWN real token count when it supplied one (decisao_atual_tokens), else
      the same PROVISIONAL baseline used for the suppression experiment above.

Usage: python3 jev_experiment_report.py [--date YYYY-MM-DD] [--experiment NAME] [--json | --resumo-pt]
Without --date it reports over ALL logged data; --date filters to one UTC day. --resumo-pt
prints the short Portuguese block that jev-daily-report.sh sends as the end-of-day ntfy.
Run `python3 jev_experiment_report.py selftest` for a mocked check against a synthetic log
(no live JEV_EXPERIMENT_LOG needed).
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
        if ev.get("mode") == "shadow":
            # ga-aijm2v.1/F0: shadow events have no arm/suppress fields -- without this
            # skip they'd fall through to the "experiment arm" branch below and silently
            # count as suppression-experiment data. summarize_shadow() owns these instead.
            continue
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


def _metrics(s: dict) -> dict:
    """The derived numbers both output formats print — computed in ONE place so the
    Portuguese daily summary can never drift from the full report."""
    control_total = s["control_fired"]
    exp_total = s["experiment_fired"] + s["experiment_suppressed"]
    reduction_pct = None
    if control_total > 0 and exp_total > 0:
        control_rate = control_total / control_total  # trivially 1.0, kept explicit for readability
        exp_rate = s["experiment_fired"] / exp_total
        reduction_pct = (1 - exp_rate / control_rate) * 100
    avoided_estimate = s["experiment_suppressed"] * BASELINE_TOKENS_PER_ESCALATION_PROVISIONAL
    net_estimate = avoided_estimate - s["jev_tokens_in"] - s["jev_tokens_out"]
    pct_of_control_estimate = None
    if control_total > 0:
        pct_of_control_estimate = 100 * net_estimate / (control_total * BASELINE_TOKENS_PER_ESCALATION_PROVISIONAL)
    return {
        "control_total": control_total,
        "exp_total": exp_total,
        "reduction_pct": reduction_pct,
        "net_estimate": net_estimate,
        "pct_of_control_estimate": pct_of_control_estimate,
    }


def summarize_shadow(events: list[dict]) -> dict:
    """ga-aijm2v.1/F0 — mirrors summarize() above but for mode=="shadow" events only.
    Kept as a SEPARATE function (not a branch inside summarize()) so the existing
    suppression-experiment aggregation stays byte-for-byte unchanged for old logs."""
    by_exp: dict[str, dict] = defaultdict(
        lambda: {
            "agree": 0,
            "disagree": 0,
            "unknown": 0,  # jev_ok=False -- third state, counted apart, never folded into agree/disagree
            "would_dispense": 0,
            "jev_tokens_in": 0,
            "jev_tokens_out": 0,
            "decisao_atual_tokens_would_save": 0,  # sum of REAL decisao_atual_tokens on would-dispense cases
            "would_dispense_missing_real_tokens": 0,  # would-dispense cases with no real token count supplied
        }
    )
    for ev in events:
        if ev.get("mode") != "shadow":
            continue
        s = by_exp[ev.get("experiment", "unknown")]
        s["jev_tokens_in"] += int(ev.get("jev_tokens_in") or 0)
        s["jev_tokens_out"] += int(ev.get("jev_tokens_out") or 0)
        agree = ev.get("agree")
        if agree is True:
            s["agree"] += 1
        elif agree is False:
            s["disagree"] += 1
        else:
            s["unknown"] += 1
        if ev.get("would_dispense"):
            s["would_dispense"] += 1
            dat = ev.get("decisao_atual_tokens")
            if dat is not None:
                s["decisao_atual_tokens_would_save"] += int(dat)
            else:
                s["would_dispense_missing_real_tokens"] += 1
    return dict(by_exp)


def _shadow_metrics(s: dict) -> dict:
    """Derived numbers for a shadow-mode experiment — mirrors _metrics() above: computed
    in ONE place so format_report()/format_resumo_pt() can never drift from each other."""
    compared = s["agree"] + s["disagree"]  # excludes "unknown" -- third state never folded in
    concordance_pct = (100 * s["agree"] / compared) if compared > 0 else None
    # ESTIMATED: real decisao_atual_tokens where the caller supplied them, PROVISIONAL
    # baseline for the would-dispense cases that didn't -- same estimate discipline as
    # BASELINE_TOKENS_PER_ESCALATION_PROVISIONAL above, never blended into a MEASURED number.
    estimated_saved = (
        s["decisao_atual_tokens_would_save"]
        + s["would_dispense_missing_real_tokens"] * BASELINE_TOKENS_PER_ESCALATION_PROVISIONAL
        - s["jev_tokens_in"]
        - s["jev_tokens_out"]
    )
    return {
        "compared": compared,
        "concordance_pct": concordance_pct,
        "would_dispense": s["would_dispense"],
        "estimated_tokens_saved": estimated_saved,
    }


def format_report(summary: dict, shadow_summary: dict, date_label: str) -> str:
    if not summary and not shadow_summary:
        return f"Jev experiment report ({date_label}): no candidate escalations logged for this window."

    lines = [f"Jev experiment report — {date_label}", ""]
    for name, s in sorted(summary.items()):
        m = _metrics(s)
        control_total = m["control_total"]
        exp_total = m["exp_total"]
        lines.append(f"## {name}")
        lines.append(f"  Control arm : {control_total} candidate escalation(s), {control_total} fired (100% — control never suppresses)")
        lines.append(
            f"  Experiment arm: {exp_total} candidate escalation(s), "
            f"{s['experiment_fired']} fired, {s['experiment_suppressed']} suppressed"
            + (f" ({s['experiment_jev_unavailable']} of the fired ones fired because Jev was unavailable/uncredentialed, not because it said yes)" if s["experiment_jev_unavailable"] else "")
        )
        if m["reduction_pct"] is not None:
            lines.append(f"  MEASURED escalation-count reduction (experiment vs control fire rate): {m['reduction_pct']:.1f}%")
        else:
            lines.append("  MEASURED escalation-count reduction: n/a (need >=1 candidate in both arms same day)")
        lines.append(f"  Jev cost (MEASURED, from real API usage): {s['jev_tokens_in']} input + {s['jev_tokens_out']} output tokens")
        lines.append(
            f"  Tokens avoided (ESTIMATED, PROVISIONAL baseline={BASELINE_TOKENS_PER_ESCALATION_PROVISIONAL}/escalation, "
            f"NOT yet measured from real session transcripts): "
            f"{s['experiment_suppressed']} suppressed x baseline - Jev cost = ~{m['net_estimate']} tokens"
        )
        if m["pct_of_control_estimate"] is not None:
            lines.append(f"  ESTIMATED % tokens saved vs an all-control baseline: {m['pct_of_control_estimate']:.1f}%")
        lines.append("")
    for name, s in sorted(shadow_summary.items()):
        m = _shadow_metrics(s)
        total = s["agree"] + s["disagree"] + s["unknown"]
        lines.append(f"## {name} (shadow)")
        lines.append(
            f"  Shadow evaluations: {total} ({m['compared']} comparable, {s['unknown']} Jev-unavailable — never counted as agree/disagree)"
        )
        if m["concordance_pct"] is not None:
            lines.append(f"  MEASURED concordance (Jev vs current decisor): {m['concordance_pct']:.1f}% ({s['agree']}/{m['compared']})")
        else:
            lines.append("  MEASURED concordance: n/a (no comparable evaluations — Jev was unavailable every time)")
        lines.append(f"  Would-dispense cases (Jev >= confidence threshold either way): {m['would_dispense']}")
        lines.append(f"  Jev cost (MEASURED, from real API usage): {s['jev_tokens_in']} input + {s['jev_tokens_out']} output tokens")
        lines.append(
            f"  Tokens the current decisor would have saved on those cases (ESTIMATED — real counts where the "
            f"caller supplied them, PROVISIONAL baseline={BASELINE_TOKENS_PER_ESCALATION_PROVISIONAL} for the "
            f"{s['would_dispense_missing_real_tokens']} that didn't): ~{m['estimated_tokens_saved']} tokens"
        )
        lines.append("")
    return "\n".join(lines)


def _pct_pt(x: float) -> str:
    return f"{x:.1f}".replace(".", ",") + "%"


def format_resumo_pt(summary: dict, shadow_summary: dict, date_label: str) -> str:
    """wa-dln9g — the end-of-day phone notification the Athos asked for ("a % of saved
    tokens for each end of day"). Same numbers as format_report() (both read _metrics()/
    _shadow_metrics()), in Portuguese and short. Keeps the MEDIDO / ESTIMATIVA split, and
    says out loud when Jev was unavailable — a day where the filter never ran must not
    read like a day where it ran and saved nothing.

    ga-aijm2v.1/F0: includes shadow-mode fronts (F2-F5) alongside the suppression
    experiment whenever either has data — the daily ntfy must not silently drop shadow
    results just because it was written for the suppression shape first."""
    if not summary and not shadow_summary:
        return f"Dia {date_label}: nenhum alerta candidato registrado — nada a medir."
    blocos = []
    for name, s in sorted(summary.items()):
        m = _metrics(s)
        linhas = [
            f"{name}: controle {m['control_total']} alerta(s); experimento {m['exp_total']}, "
            f"dos quais {s['experiment_suppressed']} silenciado(s) pelo Jev.",
        ]
        if m["reduction_pct"] is None:
            linhas.append("Redução de alertas (medida): sem dado — faltou alerta num dos grupos.")
        else:
            linhas.append(f"Redução de alertas (medida): {_pct_pt(m['reduction_pct'])}.")
        if m["pct_of_control_estimate"] is None:
            linhas.append(f"Tokens economizados (estimativa): ~{m['net_estimate']} — sem grupo controle no dia pra comparar.")
        else:
            linhas.append(
                f"Tokens economizados (estimativa, base provisória "
                f"{BASELINE_TOKENS_PER_ESCALATION_PROVISIONAL}/alerta): ~{m['net_estimate']} "
                f"= {_pct_pt(m['pct_of_control_estimate'])}."
            )
        linhas.append(f"Custo do Jev (medido): {s['jev_tokens_in']} + {s['jev_tokens_out']} tokens.")
        if s["experiment_jev_unavailable"]:
            linhas.append(
                f"⚠️ Jev indisponível em {s['experiment_jev_unavailable']} de {m['exp_total']} alerta(s) do "
                "experimento — esses dispararam sem filtro, então o número do dia sai subestimado."
            )
        blocos.append("\n".join(linhas))
    for name, s in sorted(shadow_summary.items()):
        m = _shadow_metrics(s)
        total = s["agree"] + s["disagree"] + s["unknown"]
        linhas = [
            f"{name} (sombra): {total} avaliação(ões), {s['agree']} concordou, {s['disagree']} discordou, "
            f"{s['unknown']} Jev indisponível.",
        ]
        if m["concordance_pct"] is None:
            linhas.append("Concordância (medida): sem dado — Jev indisponível em todas.")
        else:
            linhas.append(f"Concordância (medida): {_pct_pt(m['concordance_pct'])} ({s['agree']}/{m['compared']}).")
        linhas.append(f"Casos que dispensariam o decisor atual (Jev confiante): {m['would_dispense']}.")
        linhas.append(
            f"Tokens que o decisor atual teria poupado (estimativa, real quando informado, "
            f"base provisória {BASELINE_TOKENS_PER_ESCALATION_PROVISIONAL} para os "
            f"{s['would_dispense_missing_real_tokens']} sem número real): ~{m['estimated_tokens_saved']}."
        )
        linhas.append(f"Custo do Jev (medido): {s['jev_tokens_in']} + {s['jev_tokens_out']} tokens.")
        blocos.append("\n".join(linhas))
    return "\n\n".join(blocos)


def _selftest() -> int:
    """Mocked check against a synthetic log — no live JEV_EXPERIMENT_LOG needed.
    Run: python3 jev_experiment_report.py selftest"""
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

    # A synthetic shadow log: 3 agree, 1 disagree, 1 Jev-unavailable (must be counted
    # apart, never folded into agree/disagree) for experiment "F-synthetic".
    events = [
        {"mode": "shadow", "experiment": "F-synthetic", "agree": True, "would_dispense": True,
         "decisao_atual_tokens": 500, "jev_tokens_in": 10, "jev_tokens_out": 2},
        {"mode": "shadow", "experiment": "F-synthetic", "agree": True, "would_dispense": True,
         "decisao_atual_tokens": None, "jev_tokens_in": 10, "jev_tokens_out": 2},
        {"mode": "shadow", "experiment": "F-synthetic", "agree": True, "would_dispense": False,
         "jev_tokens_in": 10, "jev_tokens_out": 2},
        {"mode": "shadow", "experiment": "F-synthetic", "agree": False, "would_dispense": False,
         "jev_tokens_in": 10, "jev_tokens_out": 2},
        {"mode": "shadow", "experiment": "F-synthetic", "agree": None, "would_dispense": False,
         "jev_tokens_in": 0, "jev_tokens_out": 0},
        # A plain suppression-mode event (no "mode" key) for the SAME log -- must land only
        # in summarize(), never leak into summarize_shadow(), and vice versa.
        {"experiment": "F-synthetic", "arm": "control", "suppress": False, "jev_ok": False,
         "jev_tokens_in": 0, "jev_tokens_out": 0},
    ]

    shadow_summary = summarize_shadow(events)
    s = shadow_summary["F-synthetic"]
    ok("shadow summary: 3 agree, 1 disagree, 1 unknown (third state counted apart)",
       s["agree"] == 3 and s["disagree"] == 1 and s["unknown"] == 1)
    ok("shadow summary: 2 would-dispense (1 with a real token count, 1 without)",
       s["would_dispense"] == 2 and s["decisao_atual_tokens_would_save"] == 500 and s["would_dispense_missing_real_tokens"] == 1)

    m = _shadow_metrics(s)
    # compared = agree + disagree = 4 (unknown excluded); concordance = 3/4 = 75.0%
    ok("shadow metrics: concordance computed over comparable evaluations only (75.0%, excludes the 1 unknown)",
       m["compared"] == 4 and m["concordance_pct"] == 75.0)
    # estimated_saved = 500 (real) + 1*4000 (provisional, the missing-real-tokens case)
    # - jev cost (4 of the 5 events carry 10in/2out each; the 5th, jev_ok=False, carries 0)
    expected_estimate = 500 + BASELINE_TOKENS_PER_ESCALATION_PROVISIONAL - (4 * 10 + 4 * 2)
    ok(f"shadow metrics: estimated tokens saved blends real + provisional correctly ({expected_estimate})",
       m["estimated_tokens_saved"] == expected_estimate)

    # The plain suppression-mode event in the SAME log must not leak into shadow's counts,
    # and the shadow events must not leak into summarize()'s suppression counts.
    suppression_summary = summarize(events)
    ss = suppression_summary["F-synthetic"]
    ok("suppression summary sees only its own event, unpolluted by the 5 shadow events",
       ss["control_fired"] == 1 and ss["experiment_fired"] == 0 and ss["experiment_suppressed"] == 0)

    # format_report()/format_resumo_pt() must not crash on shadow-only or mixed input,
    # and the concordance number must actually appear in both renderings.
    report_text = format_report(suppression_summary, shadow_summary, "selftest")
    ok("format_report() renders the shadow block with the right concordance figure", "75.0%" in report_text and "(shadow)" in report_text)
    resumo_text = format_resumo_pt(suppression_summary, shadow_summary, "selftest")
    ok("format_resumo_pt() renders the shadow block with the right concordance figure (pt-BR comma)", "75,0%" in resumo_text and "(sombra)" in resumo_text)

    # Shadow-only (no suppression data at all) must not hit the "no data" early return.
    empty_suppression = summarize([])
    only_shadow_report = format_report(empty_suppression, shadow_summary, "selftest")
    ok("format_report() with shadow data but no suppression data does not print 'no candidate escalations'",
       "no candidate escalations logged" not in only_shadow_report)

    print(f"\njev_experiment_report selftest: PASS={passed} FAIL={failed}")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--date", default=None, help="YYYY-MM-DD (UTC); default: report over ALL logged data")
    ap.add_argument("--experiment", default=None, help="filter to one experiment name")
    ap.add_argument("--json", action="store_true", help="print the raw summary dict as JSON instead of prose")
    ap.add_argument("--resumo-pt", action="store_true", help="short Portuguese summary (the daily ntfy, see jev-daily-report.sh)")
    # Optional (not required) subcommand: every existing caller passes only the flags
    # above with no positional at all, so leaving this unrequired keeps `args.cmd` simply
    # None for them -- zero change in behavior. Only `selftest` uses it.
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("selftest", help="mocked check against a synthetic log, no live JEV_EXPERIMENT_LOG needed")
    args = ap.parse_args()

    if args.cmd == "selftest":
        return _selftest()

    # A missing log means "can't know", not "nothing happened": load_events() returns []
    # for both, and every output format would then print its "no data" line — which the
    # daily ntfy would deliver to the Athos as a fact. Fail loudly instead.
    if not JEV_LOG.exists():
        print(f"jev-experiment log not found: {JEV_LOG} — cannot tell whether anything was logged", file=sys.stderr)
        return 2

    events = load_events(args.date, args.experiment)
    summary = summarize(events)
    shadow_summary = summarize_shadow(events)

    if args.json:
        print(json.dumps({"suppression": summary, "shadow": shadow_summary}, ensure_ascii=False, indent=2))
    elif args.resumo_pt:
        print(format_resumo_pt(summary, shadow_summary, args.date or "todo o período"))
    else:
        print(format_report(summary, shadow_summary, args.date or "all-time"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
