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
import cut_output_classifier as coc  # noqa: E402
import jev_experiment as je  # noqa: E402
from jev_cut_output_join import JOIN_MODE, RECORD_MODE, SOURCE_EXPERIMENTS, is_join_candidate, read_jsonl  # noqa: E402

ERROR_EXPERIMENT = coc.ERROR_EXPERIMENT
EVENT_SUCCESS = coc.EVENT_SUCCESS
EVENT_FAILURE = coc.EVENT_FAILURE

# Two error rows a selftest run left in the LIVE jev-experiment.jsonl on 2026-09-29T00:03:17Z, before that suite
# pointed the log at a throwaway file (stage "engine", errors JSONDecodeError and RuntimeError, session and
# tool_use_id null): they are test exhaust, not hook failures. The Mayor's standing decision for the same kind of
# incident (the 40 stress-run rows, 21:56) is to leave the append-only shared log alone and exclude at read, so
# these two are excluded by their exact entity_id -- a genuine error row is never ignored.
IGNORED_ERROR_ENTITY_IDS = frozenset({"no-tool-use-id-a63be92ef344", "no-tool-use-id-afd9ff542c61"})


def compute_stats(records: list[dict]) -> dict:
    """Pure. Splits records into the two source experiments (fixed-rule, Jev-tier) and their
    cut-output-join counterparts (keyed by entity_id), then aggregates. Only this front's own modes
    are read (RECORD_MODE / JOIN_MODE): a mode=="shadow" row of the same experiment name is not this
    front's data. Never raises on a malformed or missing field on any one record -- one bad record is
    skipped, not fatal to the report."""
    stats: dict = {exp: {
        "count": 0,
        "tokens_would_save_total": 0,
        "tokens_would_save_known": 0,  # how many records had a non-None tokens_would_save
        "jev_unreachable_count": 0,  # cut-output-jev only
        "unknown_count": 0,  # cut-output-fixed only: shape recognized, rule could not cut it (rule "unknown")
        # real cuts (tokens_would_save > 0) with no signature to search for: the offline join skips them,
        # so they are outside the referenced-later rate -- counted here so the report can say so
        "no_signature_count": 0,
        "sampled_count": 0,  # cut-output-jev only: Jev judged a head+tail sample, not the whole output
        # which hook event the row came from: PostToolUseFailure = the command exited non-zero (PostToolUse fires
        # ONLY for exit 0), so the failed-command population is countable apart; a row with no hook_event at all
        # (logged before the field existed) is in neither bucket
        "failure_count": 0,
        "event_unrecorded_count": 0,
        "no_gain_count": 0,  # cut-output-fixed only: rule "no-gain" -- shape recognized, cutting would not shrink it
    } for exp in SOURCE_EXPERIMENTS}
    joins: dict[tuple[str, str], bool | None] = {}
    candidates: set[tuple[str, str]] = set()  # records the join could act on (whether or not it has yet)
    event_of: dict[tuple[str, str], object] = {}  # (experiment, entity_id) -> the row's hook_event, for the join split
    error_kinds: dict[tuple[str, str], int] = {}
    error_total = 0

    for rec in records:
        mode = rec.get("mode")
        exp = rec.get("experiment")
        if exp == ERROR_EXPERIMENT:
            # A lost measurement (wrapper or engine). Only this front's own mode; a stray-selftest row is excluded by
            # its exact id. A malformed row is still ONE lost measurement -- str() so an odd type cannot raise.
            eid = rec.get("entity_id")
            if mode == RECORD_MODE and not (isinstance(eid, str) and eid in IGNORED_ERROR_ENTITY_IDS):
                kind = (str(rec.get("stage")), str(rec.get("error")))
                error_kinds[kind] = error_kinds.get(kind, 0) + 1
                error_total += 1
            continue
        if exp not in SOURCE_EXPERIMENTS:
            continue
        if mode == JOIN_MODE:
            eid = rec.get("entity_id")
            if isinstance(eid, str):  # an unhashable/odd-typed id (partial multi-writer line) is skipped, not a key
                joins[(exp, eid)] = rec.get("referenced_later")
            continue
        if mode != RECORD_MODE:
            continue
        if is_join_candidate(rec):
            candidates.add((exp, rec["entity_id"]))
        s = stats[exp]
        s["count"] += 1
        hook_event = rec.get("hook_event")
        if hook_event == EVENT_FAILURE:
            s["failure_count"] += 1
        elif hook_event != EVENT_SUCCESS:
            s["event_unrecorded_count"] += 1
        if isinstance(rec.get("entity_id"), str):
            event_of[(exp, rec["entity_id"])] = hook_event
        saved = rec.get("tokens_would_save")
        if isinstance(saved, (int, float)):
            s["tokens_would_save_total"] += saved
            s["tokens_would_save_known"] += 1
            if saved > 0 and not rec.get("omitted_signatures"):
                s["no_signature_count"] += 1
        if exp == "cut-output-jev" and rec.get("jev_ok") is False:
            s["jev_unreachable_count"] += 1
        if exp == "cut-output-jev" and rec.get("sampled") is True:
            s["sampled_count"] += 1
        if exp == "cut-output-fixed" and rec.get("rule") == "unknown":
            s["unknown_count"] += 1
        if exp == "cut-output-fixed" and rec.get("rule") == "no-gain":
            s["no_gain_count"] += 1

    referenced_true = 0
    referenced_false = 0
    referenced_unknown = 0
    by_event = {"success": {"referenced_true": 0, "referenced_false": 0}, "failure": {"referenced_true": 0, "referenced_false": 0}}
    for key, v in joins.items():
        if v is True:
            referenced_true += 1
        elif v is False:
            referenced_false += 1
        else:
            referenced_unknown += 1
        bucket = {EVENT_SUCCESS: "success", EVENT_FAILURE: "failure"}.get(event_of.get(key))  # type: ignore[arg-type]
        if bucket is not None and v is not None:
            by_event[bucket]["referenced_true" if v else "referenced_false"] += 1

    stats["joins"] = {
        "total": len(joins),
        "referenced_true": referenced_true,
        "referenced_false": referenced_false,
        "referenced_unknown": referenced_unknown,
        "referenced_rate": (referenced_true / (referenced_true + referenced_false)) if (referenced_true + referenced_false) > 0 else None,
        # candidates with no join record yet: the join leaves a case unrecorded while its session may still
        # produce later turns (jev_cut_output_join.py, SETTLING), so they are outside every number above
        "pending": len(candidates - set(joins)),
        # the same verdicts split by the event of the row they joined (rows with no hook_event are in neither)
        "by_event": by_event,
    }
    stats["errors"] = {"total": error_total, "by_kind": error_kinds}
    return stats


def format_report(stats: dict) -> str:
    lines = ["Cut-large-output (ga-wk0qi2, SHADOW — nothing is actually cut yet):"]
    for exp, label in (("cut-output-fixed", "Fixed-rule tier (pytest/log-tail, no AI)"), ("cut-output-jev", "Jev tier (unstructured large blocks)")):
        s = stats[exp]
        avg = (s["tokens_would_save_total"] / s["tokens_would_save_known"]) if s["tokens_would_save_known"] else None
        lines.append(f"  {label}: {s['count']} case(s), avg tokens_would_save={avg:.0f}" if avg is not None else f"  {label}: {s['count']} case(s), no measurable tokens_would_save yet")
        if exp == "cut-output-fixed" and s["unknown_count"]:
            lines.append(f"    {s['unknown_count']} unknown (shape recognized but the rule could not cut it, kept in full; not in the average)")
        if exp == "cut-output-fixed" and s["no_gain_count"]:
            lines.append(
                f"    {s['no_gain_count']} no-gain (shape recognized, but cutting would not shrink the output -- nothing omitted; "
                f"a measured 0 tokens saved, so it IS in the average, unlike 'unknown')"
            )
        if exp == "cut-output-jev":
            lines.append(f"    Jev unreachable in {s['jev_unreachable_count']}/{s['count']} case(s) (third state, never counted as a cut)")
            if s["sampled_count"]:
                lines.append(
                    f"    {s['sampled_count']} judged only a head+tail sample (their tokens_would_save is a lower bound: "
                    f"the never-judged middle counts as kept)"
                )
    j = stats["joins"]
    total_cases = sum(stats[exp]["count"] for exp in SOURCE_EXPERIMENTS)
    if total_cases:
        # PostToolUse fires only for a command that exited 0; one that exited non-zero fires PostToolUseFailure. Its
        # output is shown apart so the rate below cannot be carried by exit-0 runs, and a 0 here is said out loud:
        # it is exactly what a missing PostToolUseFailure registration looks like.
        failed_cases = sum(stats[exp]["failure_count"] for exp in SOURCE_EXPERIMENTS)
        fe = j["by_event"]["failure"]
        f_decided = fe["referenced_true"] + fe["referenced_false"]
        f_rate = f"{fe['referenced_true'] / f_decided * 100:.1f}%" if f_decided else "n/a"
        if failed_cases:
            lines.append(
                f"  From commands that exited non-zero (PostToolUseFailure): {failed_cases} of {total_cases} case(s); offline join: "
                f"{fe['referenced_true']} referenced later / {fe['referenced_false']} not (rate {f_rate}) -- shown apart so the "
                f"rate below cannot be carried by exit-0 runs"
            )
        else:
            lines.append(
                f"  From commands that exited non-zero (PostToolUseFailure): 0 of {total_cases} case(s) -- none yet; if agents ran "
                f"failing commands, check that PostToolUseFailure:Bash is registered (PostToolUse fires only for exit 0)"
            )
        unrecorded = sum(stats[exp]["event_unrecorded_count"] for exp in SOURCE_EXPERIMENTS)
        if unrecorded:
            lines.append(f"  {unrecorded} case(s) carry no hook_event (logged before the field existed); in neither split")
    if j["total"] == 0:
        lines.append("  Offline join (referenced-later): no joined cases yet (run jev_cut_output_join.py).")
    else:
        rate_str = f"{j['referenced_rate']*100:.1f}%" if j["referenced_rate"] is not None else "n/a"
        lines.append(
            f"  Offline join: {j['total']} case(s) checked — referenced later: {j['referenced_true']}, "
            f"not referenced: {j['referenced_false']}, unknown: {j['referenced_unknown']} "
            f"(measured rate: {rate_str}; bead's own expected ceiling: ~8% of reread — compare, do not auto-decide)"
        )
    if j["pending"]:
        lines.append(
            f"  {j['pending']} cut(s) not joined yet — their session may still be running (a False verdict is written "
            f"only once it is over, so the rate above reads high until then) or the join's --limit/--since-hours "
            f"window has not reached them; not in the rate above"
        )
    no_signature = sum(stats[exp]["no_signature_count"] for exp in SOURCE_EXPERIMENTS)
    if no_signature:
        lines.append(
            f"  {no_signature} cut(s) had no signature to look for — outside the rate above "
            f"(nothing to search is not 'searched and not found')"
        )
    e = stats["errors"]
    if e["total"]:
        kinds = ", ".join(f"{stage}: {err} x{n}" for (stage, err), n in sorted(e["by_kind"].items(), key=lambda kv: (-kv[1], kv[0])))
        note = " (engine_rc_137 = the wrapper's watchdog killed the engine)" if any(err == "engine_rc_137" for _, err in e["by_kind"]) else ""
        lines.append(f"  Hook errors: {e['total']} call(s) whose measurement was LOST -- {kinds}{note}")
    else:
        lines.append(
            "  Hook errors: none logged (a zero here means 'none that could be written down': jq missing, an unwritable "
            "log or a missing wrapper script leave no row)"
        )
    return "\n".join(lines)


def format_resumo_pt(stats: dict) -> str:
    fixed = stats["cut-output-fixed"]["count"]
    fixed_unknown = stats["cut-output-fixed"]["unknown_count"]
    jev = stats["cut-output-jev"]["count"]
    j = stats["joins"]
    rate_str = f"{j['referenced_rate']*100:.1f}%" if j["referenced_rate"] is not None else "sem dado"
    # cases the fixed rule could not read count as observed, but they cut nothing -- say so instead
    # of letting "N via regra fixa" read as N cuts
    fixed_note = f" ({fixed_unknown} sem corte: formato não reconhecido)" if fixed_unknown else ""
    # "conferido(s)" is the population the rate is computed over (a verdict of yes or no); joins with no verdict
    # (unknown) and cuts still waiting for their session to end are named apart, not folded into that count
    decided = j["referenced_true"] + j["referenced_false"]
    join_notes = ""
    if j["referenced_unknown"]:
        join_notes += f", {j['referenced_unknown']} sem veredito"
    if j["pending"]:
        join_notes += f", {j['pending']} aguardando a sessão terminar"
    total_cases = sum(stats[exp]["count"] for exp in SOURCE_EXPERIMENTS)
    failed_cases = sum(stats[exp]["failure_count"] for exp in SOURCE_EXPERIMENTS)
    extra = ""
    if failed_cases:
        extra += f" {failed_cases} de {total_cases} casos vieram de comandos com falha."
    if stats["errors"]["total"]:
        extra += f" O hook perdeu {stats['errors']['total']} medição(ões) por erro."
    return (
        f"Cortar-saída-grande (SOMBRA, nada é cortado de verdade ainda): {fixed} caso(s) via regra fixa{fixed_note}, "
        f"{jev} via Jev. Join offline: {decided} conferido(s){join_notes}, taxa de 'precisou depois' = {rate_str} "
        f"(teto esperado do bead: ~8%).{extra}"
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
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "e1", "tokens_would_save": 100},
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "e2", "tokens_would_save": 200},
        {"mode": RECORD_MODE, "experiment": "cut-output-jev", "entity_id": "e3", "tokens_would_save": 50, "jev_ok": True},
        {"mode": RECORD_MODE, "experiment": "cut-output-jev", "entity_id": "e4", "tokens_would_save": None, "jev_ok": False},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "e1", "referenced_later": True},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "e2", "referenced_later": False},
        {"mode": JOIN_MODE, "experiment": "cut-output-jev", "entity_id": "e3", "referenced_later": False},
        {"mode": RECORD_MODE, "experiment": "unrelated-front", "entity_id": "e9", "tokens_would_save": 999},
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

    # ---- ga-wk0qi2 gate feedback attempt 4: 'unknown' fixed-rule records (the rule recognized the
    # shape but could not cut it safely) are counted and shown SEPARATELY, and their None
    # tokens_would_save must not enter the average as if it were a measured "saves nothing" ----
    unk_records = records + [
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "e10", "rule": "unknown", "tokens_would_save": None},
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "e11", "rule": "unknown", "tokens_would_save": None},
    ]
    unk_stats = compute_stats(unk_records)
    ok("unknown records still count as observed fixed-rule cases", unk_stats["cut-output-fixed"]["count"] == 4)
    ok("unknown records are counted on their own", unk_stats["cut-output-fixed"]["unknown_count"] == 2)
    ok("the plain stats report zero unknown", stats["cut-output-fixed"]["unknown_count"] == 0)
    ok("unknown records do not enter the tokens_would_save average", unk_stats["cut-output-fixed"]["tokens_would_save_known"] == 2)
    ok("format_report shows the unknown count", "2 unknown" in format_report(unk_stats))
    ok("format_report stays quiet about unknown when there are none", "unknown" not in format_report(stats).split("Offline join")[0])
    ok("format_resumo_pt says how many fixed-rule cases could not be cut", "2 sem corte" in format_resumo_pt(unk_stats))
    ok("format_resumo_pt stays quiet about 'sem corte' when there are none", "sem corte" not in format_resumo_pt(stats))

    # ---- gate_run ga-qxm60a, low finding: the referenced-later rate silently leaves out every cut that
    # had no signature to look for (the join skips them -- nothing to search is not "searched, not
    # found"), yet the report sets that rate beside the bead's ~8% ceiling. Say how many were left
    # out. And a Jev saving computed from a head+tail SAMPLE is a lower bound: say how many. ----
    sig_records = [
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "s1", "tokens_would_save": 100, "omitted_signatures": ["ga-x"]},
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "s2", "tokens_would_save": 90, "omitted_signatures": []},
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "s3", "tokens_would_save": 80},  # field missing
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "s4", "rule": "unknown", "tokens_would_save": None, "omitted_signatures": []},
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "s5", "tokens_would_save": 0, "omitted_signatures": []},
        {"mode": RECORD_MODE, "experiment": "cut-output-jev", "entity_id": "s6", "tokens_would_save": 50, "jev_ok": True, "sampled": True, "omitted_signatures": ["/a/b/c"]},
        {"mode": RECORD_MODE, "experiment": "cut-output-jev", "entity_id": "s7", "tokens_would_save": 40, "jev_ok": True, "sampled": False, "omitted_signatures": []},
        {"mode": RECORD_MODE, "experiment": "cut-output-jev", "entity_id": "s8", "tokens_would_save": None, "jev_ok": False},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "s1", "referenced_later": False},
    ]
    sig_stats = compute_stats(sig_records)
    ok("fixed tier: exactly the real cuts with an empty/missing omitted_signatures are 'nothing to look for' "
       "(s2, s3) -- not the one with signatures (s1), the 'unknown' one with no cut (s4), or the zero-token one (s5)",
       sig_stats["cut-output-fixed"].get("no_signature_count") == 2)
    ok("Jev tier: a cut with no signatures is counted (s7); an unreachable Jev (no cut) is not (s8)",
       sig_stats["cut-output-jev"].get("no_signature_count") == 1)
    ok("Jev tier: sampled judgements are counted (s6)", sig_stats["cut-output-jev"].get("sampled_count") == 1)
    sig_text = format_report(sig_stats)
    ok("format_report says how many cuts had nothing to look for and are outside the rate", "3 cut(s) had no signature to look for" in sig_text)
    ok("format_report says how many Jev numbers come from a sample (lower bound)", "1 judged only a head+tail sample" in sig_text)
    quiet_text = format_report(compute_stats([
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "q1", "tokens_would_save": 100, "omitted_signatures": ["ga-x"]},
        {"mode": RECORD_MODE, "experiment": "cut-output-jev", "entity_id": "q2", "tokens_would_save": 50, "jev_ok": True, "sampled": False, "omitted_signatures": ["/a/b/c"]},
    ]))
    ok("format_report stays quiet about both when every cut has signatures and nothing was sampled",
       "no signature to look for" not in quiet_text and "head+tail sample" not in quiet_text)

    # compute_stats promises to never raise on a malformed record. A join record whose entity_id is not
    # hashable (a list, from a partially-written multi-writer line) was used as a dict key -> TypeError.
    try:
        bad_stats = compute_stats([
            {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": ["unhashable"], "referenced_later": True},
            {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "good", "referenced_later": False},
            {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "x", "tokens_would_save": "not-a-number", "omitted_signatures": 5},
        ])
        bad_raised = None
    except Exception as e:  # noqa: BLE001
        bad_stats, bad_raised = None, type(e).__name__
    ok(f"compute_stats: a join record with an unhashable entity_id is skipped, never raises (raised: {bad_raised})", bad_raised is None)
    ok("compute_stats: the well-formed join record beside it is still counted", bad_stats is not None and bad_stats["joins"]["total"] == 1)

    # ---- gate_run ga-75ya0i: this front's rows have their own mode. A legacy mode=="shadow" row of the same
    # experiment (the 40 stress-run rows in the live log: entity_id "t", command "c") is NOT this front's
    # data -- jev_experiment_report.summarize_shadow() owns that mode -- so it must not count here either ----
    legacy_stats = compute_stats(records + [
        {"mode": "shadow", "experiment": "cut-output-jev", "entity_id": "t", "command": "c", "tokens_would_save": 9999, "jev_ok": False},
        {"mode": "shadow-join", "experiment": "cut-output-jev", "entity_id": "t", "referenced_later": True},
    ])
    ok("legacy mode=='shadow' rows of a cut-output experiment are ignored (count unchanged)",
       legacy_stats["cut-output-jev"]["count"] == stats["cut-output-jev"]["count"] and legacy_stats["cut-output-jev"]["jev_unreachable_count"] == stats["cut-output-jev"]["jev_unreachable_count"])
    ok("legacy 'shadow' / 'shadow-join' rows do not touch the join counts either", legacy_stats["joins"] == stats["joins"])

    # ---- gate_run ga-75ya0i, blocking issue 1 (report side): records the join has NOT written a verdict for
    # yet (session still live) are shown as waiting -- the join leaves them unrecorded on purpose, and a
    # report that only says "N case(s) checked" reads a backlog exactly like a finished measurement ----
    def _cand(eid, exp="cut-output-fixed", **kw):
        r = {"mode": RECORD_MODE, "experiment": exp, "entity_id": eid, "tokens_would_save": 10, "omitted_signatures": ["ga-x"],
             "transcript_path": "/tmp/t.jsonl", "tool_use_id": eid}
        r.update(kw)
        return r

    pend_records = [
        _cand("p1"), _cand("p2", exp="cut-output-jev", jev_ok=True),                    # waiting for the join
        _cand("p3"), {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "p3", "referenced_later": False},  # joined
        _cand("p4", omitted_signatures=[]),                                              # nothing to look for: never a candidate
        _cand("p5", tool_use_id=None),                                                   # no call to locate: never a candidate
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "p6", "rule": "unknown", "tokens_would_save": None},
    ]
    pend_stats = compute_stats(pend_records)
    ok("pending backlog: exactly the records the join could act on and has not joined yet (p1, p2)", pend_stats["joins"]["pending"] == 2)
    ok("pending backlog counts nothing when every candidate is joined or unjoinable", stats["joins"]["pending"] == 0)
    ok("every pending record is one is_join_candidate() accepts (the report and the join cannot disagree)",
       all(is_join_candidate(r) for r in pend_records if r["mode"] == RECORD_MODE and r["entity_id"] in ("p1", "p2", "p3"))
       and not is_join_candidate(pend_records[4]) and not is_join_candidate(pend_records[5]))
    pend_text = format_report(pend_stats)
    ok("format_report says how many cuts are still waiting for their session to finish, outside the rate",
       "2 cut(s) not joined yet" in pend_text and "session" in pend_text)
    ok("format_report stays quiet about waiting cuts when there are none", "not joined yet" not in format_report(stats))
    ok("format_resumo_pt says how many are still waiting", "2 aguardando" in format_resumo_pt(pend_stats))
    ok("format_resumo_pt stays quiet about waiting cuts when there are none", "aguardando" not in format_resumo_pt(stats))

    # the phone text used to print "N conferido(s)" counting unknown joins next to a rate whose denominator
    # excludes them: N must be the cases the rate is computed over, with the unknown ones named apart
    unk_join = compute_stats([
        _cand("u1"), _cand("u2"), _cand("u3"),
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "u1", "referenced_later": True},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "u2", "referenced_later": False},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "u3", "referenced_later": None},
    ])
    unk_pt = format_resumo_pt(unk_join)
    ok("format_resumo_pt: the checked count is the rate's own denominator (2), unknown joins are named apart (1)",
       "2 conferido(s)" in unk_pt and "1 sem veredito" in unk_pt and "50.0%" in unk_pt)
    ok("format_resumo_pt: no 'sem veredito' when no join is unknown", "sem veredito" not in format_resumo_pt(stats))

    # ---- gate_run ga-vrv1tz, blocking issue 1 (report side): PostToolUse does not fire for a command that exits
    # non-zero, so before the PostToolUseFailure registration the rate was measured on the commands that WORKED
    # only -- and nothing in the report said so. The rows now carry hook_event; the report shows the
    # failed-command population APART (an exit-0-dominated rate must not be able to hide it), and says out loud
    # when there are none. ----
    def _ev(eid, event, exp="cut-output-fixed", **kw):
        return _cand(eid, exp=exp, hook_event=event, **kw)

    split_records = [
        _ev("ok1", "PostToolUse"), _ev("ok2", "PostToolUse"), _ev("ok3", "PostToolUse", exp="cut-output-jev", jev_ok=True),
        _ev("f1", "PostToolUseFailure", exit_code=1), _ev("f2", "PostToolUseFailure", exit_code=2),
        _ev("f3", "PostToolUseFailure", exp="cut-output-jev", jev_ok=True, exit_code=1),
        _cand("old1"),  # no hook_event at all (a row from before the field existed)
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "ok1", "referenced_later": False},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "ok2", "referenced_later": False},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "f1", "referenced_later": True},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "f2", "referenced_later": False},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "old1", "referenced_later": True},
    ]
    split_stats = compute_stats(split_records)
    ok("failed-command cases are counted per tier (2 fixed... 1 in the fixed tier is f1+f2, 1 in the Jev tier is f3)",
       split_stats["cut-output-fixed"]["failure_count"] == 2 and split_stats["cut-output-jev"]["failure_count"] == 1)
    ok("a row with no hook_event is counted apart, in neither bucket", split_stats["cut-output-fixed"]["event_unrecorded_count"] == 1
       and split_stats["cut-output-jev"]["event_unrecorded_count"] == 0)
    ok("the offline join is split by the event of the row it joined: exit-0 runs 0/2 referenced later",
       split_stats["joins"]["by_event"]["success"] == {"referenced_true": 0, "referenced_false": 2})
    ok("the offline join is split: failed runs 1/2 referenced later", split_stats["joins"]["by_event"]["failure"] == {"referenced_true": 1, "referenced_false": 1})
    ok("the overall rate is untouched by the split (unrecorded-event joins still count in the total)",
       split_stats["joins"]["referenced_true"] == 2 and split_stats["joins"]["referenced_false"] == 3)
    split_text = format_report(split_stats)
    ok("format_report shows the failed-command population apart, with both counts and its own rate",
       "exited non-zero (PostToolUseFailure): 3 of 7 case(s)" in split_text and "1 referenced later / 1 not" in split_text and "50.0%" in split_text)
    ok("format_report says how many rows carry no hook_event", "1 case(s) carry no hook_event" in split_text)
    zero_fail_text = format_report(compute_stats([_ev("z1", "PostToolUse"), _ev("z2", "PostToolUse")]))
    ok("format_report says out loud when NO case came from a failed command (a missing registration looks exactly like this)",
       "exited non-zero (PostToolUseFailure): 0 of 2 case(s)" in zero_fail_text and "registered" in zero_fail_text)
    ok("no such hint for an empty log (nothing to be missing yet)", "registered" not in format_report(compute_stats([])))
    ok("format_resumo_pt says how many cases came from failed commands", "3 de 7" in format_resumo_pt(split_stats))

    # ---- gate_run ga-vrv1tz, medium finding: fail-open was silent AND uncounted -- a dead hook read like a quiet
    # day ("0 case(s)"). The wrapper and the engine now leave an error row per lost measurement; the report
    # counts them by (stage, error), and a "none" is qualified by what a row cannot record. ----
    err_records = [
        {"mode": RECORD_MODE, "experiment": ERROR_EXPERIMENT, "entity_id": "wrapper-1", "stage": "wrapper", "error": "engine_rc_137", "size": 4000},
        {"mode": RECORD_MODE, "experiment": ERROR_EXPERIMENT, "entity_id": "wrapper-2", "stage": "wrapper", "error": "engine_rc_137", "size": 9000},
        {"mode": RECORD_MODE, "experiment": ERROR_EXPERIMENT, "entity_id": "no-tool-use-id-x", "stage": "engine", "error": "TypeError"},
        {"mode": "shadow", "experiment": ERROR_EXPERIMENT, "entity_id": "wrapper-3", "stage": "wrapper", "error": "engine_rc_1"},  # not this front's mode
    ]
    err_stats = compute_stats(records + err_records)
    ok("error rows are counted per (stage, error)", err_stats["errors"]["by_kind"] == {("wrapper", "engine_rc_137"): 2, ("engine", "TypeError"): 1})
    ok("error rows are counted in total", err_stats["errors"]["total"] == 3)
    ok("error rows are NOT cases: the tier counts are unchanged", err_stats["cut-output-fixed"]["count"] == stats["cut-output-fixed"]["count"]
       and err_stats["cut-output-jev"]["count"] == stats["cut-output-jev"]["count"])
    ok("error rows do not enter the offline join", err_stats["joins"] == stats["joins"])
    err_text = format_report(err_stats)
    ok("format_report names the lost measurements and their reasons",
       "3 call(s) whose measurement was LOST" in err_text and "wrapper: engine_rc_137 x2" in err_text and "engine: TypeError x1" in err_text)
    none_text = format_report(stats)
    ok("with no error rows the report still says so -- and what a zero cannot see (jq missing, unwritable log, missing wrapper)",
       "Hook errors: none logged" in none_text and "unwritable log" in none_text)
    ok("format_resumo_pt says how many measurements the hook lost", "3 medição" in format_resumo_pt(err_stats))
    ok("format_resumo_pt stays quiet about hook errors when there are none", "medição" not in format_resumo_pt(stats))
    # the two rows a pre-guard selftest run left in the live log (2026-09-29T00:03:17Z) are not hook failures
    stray = compute_stats([
        {"mode": RECORD_MODE, "experiment": ERROR_EXPERIMENT, "entity_id": eid, "stage": "engine", "error": "RuntimeError"}
        for eid in sorted(IGNORED_ERROR_ENTITY_IDS)
    ] + [{"mode": RECORD_MODE, "experiment": ERROR_EXPERIMENT, "entity_id": "no-tool-use-id-real", "stage": "engine", "error": "RuntimeError"}])
    ok("the two stray selftest error rows in the live log are excluded at read; a genuine one beside them still counts",
       len(IGNORED_ERROR_ENTITY_IDS) == 2 and stray["errors"]["total"] == 1)
    try:
        odd_err = compute_stats([
            {"mode": RECORD_MODE, "experiment": ERROR_EXPERIMENT, "entity_id": ["unhashable"], "stage": ["x"], "error": {"y": 1}},
            {"mode": RECORD_MODE, "experiment": ERROR_EXPERIMENT},
        ])
        odd_err_raised = None
    except Exception as e:  # noqa: BLE001
        odd_err, odd_err_raised = None, type(e).__name__
    ok(f"a malformed error row never raises (raised: {odd_err_raised}) and is still one lost measurement", odd_err_raised is None and odd_err["errors"]["total"] == 2)

    # ---- gate_run ga-vrv1tz, low finding: 'no-gain' is a measured zero -- counted apart, and it stays in the average
    # (the rule DID evaluate the output), unlike 'unknown' (could not read it) ----
    ng_stats = compute_stats([
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "n1", "rule": "no-gain", "tokens_would_save": 0, "omitted_signatures": []},
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "n2", "rule": "pytest", "tokens_would_save": 100, "omitted_signatures": ["ga-x"]},
    ])
    ok("no-gain cases are counted on their own", ng_stats["cut-output-fixed"]["no_gain_count"] == 1)
    ok("no-gain cases stay in the average as a real zero: (0 + 100) / 2", "avg tokens_would_save=50" in format_report(ng_stats))
    ok("format_report says what a no-gain case is", "1 no-gain" in format_report(ng_stats) and "would not shrink" in format_report(ng_stats))
    ok("format_report stays quiet about no-gain when there are none", "no-gain" not in format_report(stats))

    empty_stats = compute_stats([])
    ok("compute_stats on empty input never raises, counts are zero", empty_stats["cut-output-fixed"]["count"] == 0 and empty_stats["joins"]["total"] == 0)
    ok("format_report on empty stats doesn't crash and says no joined cases yet", "no joined cases yet" in format_report(empty_stats))
    ok("format_resumo_pt on empty stats doesn't crash", isinstance(format_resumo_pt(empty_stats), str))

    print(f"\njev_cut_output_report selftest: PASS={passed} FAIL={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
