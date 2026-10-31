#!/usr/bin/env python3
"""jev_cut_output_report.py (ga-wk0qi2, child of ga-aijm2v) — daily/cumulative digest for the
cut-large-output SHADOW front: the fixed rule, and the Jev tier (ga-d0hm85) for a sample of the outputs the fixed rule does
not reach (cut-output-shadow.py logs the raw shadow records; jev_cut_output_
join.py adds the offline "was the cut content referenced later" verdict). Reports CUMULATIVE
totals to date, same choice as jev_gate_fail_classify_report.py — this front is high-VOLUME (it
fires on every large Bash output across every pool session, unlike a rare real-review-FAIL), so a
running total is more informative on any given day than a slice that might be near-empty on a
quiet day.

THE JEV TIER'S THREE STATES (the reason this report has its own section for it): a Jev record is judged in full, judged in
part, or NOT JUDGED, and the report keeps the three apart. Only a record judged IN FULL carries a tokens_would_save and
only it enters the average; a partial record contributes a floor (tokens_saved_lower_bound) that is printed separately; a
record or block that was NOT JUDGED is counted on its own, with its reasons, and is never a 0 and never in an average. The
consumer does not trust the producer: a Jev row that carries a saving number without coverage "full" (the old tier's
shape, a hand-edited row, a future bug) is counted as inconsistent and left out of every number. And an unmatched output
whose Jev attempt left no result row is printed as a LOST attempt, not as a quiet day.

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
FIXED_EXPERIMENT = "cut-output-fixed"
JEV_EXPERIMENT = "cut-output-jev"
JEV_FULL_STATES = ("judged-relevant", "judged-cuttable")  # the only record states that may carry a saving number
EVENT_SUCCESS = coc.EVENT_SUCCESS
EVENT_FAILURE = coc.EVENT_FAILURE

# Two error rows a selftest run left in the LIVE jev-experiment.jsonl on 2026-09-29T00:03:17Z, before that suite
# pointed the log at a throwaway file (stage "engine", errors JSONDecodeError and RuntimeError, session and
# tool_use_id null): they are test exhaust, not hook failures. The Mayor's standing decision for the same kind of
# incident (the 40 stress-run rows, 21:56) is to leave the append-only shared log alone and exclude at read, so
# these two are excluded by their exact entity_id -- a genuine error row is never ignored.
IGNORED_ERROR_ENTITY_IDS = frozenset({"no-tool-use-id-a63be92ef344", "no-tool-use-id-afd9ff542c61"})


def _is_number(v: object) -> bool:
    """A real count/amount: an int or float that is not a bool (True is an int in Python and must not be a saving)."""
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _count_jev_row(s: dict, rec: dict) -> None:
    """Adds one Jev-tier row's state, coverage, block and cost counters to `s`. Pure; a field that is missing or the wrong
    type lands in an 'unreadable' bucket instead of being read as a value."""
    state = rec.get("jev_state")
    if state == "judged-relevant":
        s["jev_judged_relevant"] += 1
    elif state == "judged-cuttable":
        s["jev_judged_cuttable"] += 1
    elif state == "not-judged":
        s["jev_not_judged"] += 1
    else:
        s["jev_state_unreadable"] += 1
    coverage = rec.get("coverage")
    if coverage in ("full", "partial", "none"):
        s["cov_" + coverage] += 1
        if coverage == "full" and state == "judged-relevant":
            s["full_relevant"] += 1
        elif coverage == "full" and state == "judged-cuttable":
            s["full_cuttable"] += 1
    else:
        s["cov_unreadable"] += 1
    counts = [rec.get(k) for k in ("blocks_relevant", "blocks_cuttable", "blocks_not_judged")]
    if all(_is_number(c) for c in counts):
        s["blocks_relevant"] += counts[0]
        s["blocks_cuttable"] += counts[1]
        s["blocks_not_judged"] += counts[2]
        s["blocks_total"] += sum(counts)
    else:
        s["rows_without_block_detail"] += 1
    reasons = rec.get("not_judged_reasons")
    if isinstance(reasons, dict):
        for reason, n in reasons.items():
            if isinstance(reason, str) and _is_number(n):
                s["not_judged_reasons"][reason] = s["not_judged_reasons"].get(reason, 0) + n
    if rec.get("jev_ok") is False:
        s["calls_failed"] += 1
    if rec.get("jev_called") is False:
        s["calls_not_made"] += 1
    for src, dst in (("jev_tokens_in", "tokens_in"), ("jev_tokens_out", "tokens_out")):
        if _is_number(rec.get(src)):
            s[dst] += rec[src]


def compute_stats(records: list[dict]) -> dict:
    """Pure. Splits records into the source experiment (the fixed rule) and its cut-output-join
    counterparts (keyed by entity_id), then aggregates. Only this front's own modes
    are read (RECORD_MODE / JOIN_MODE): a mode=="shadow" row of the same experiment name is not this
    front's data. Never raises on a malformed or missing field on any one record -- one bad record is
    skipped, not fatal to the report."""
    stats: dict = {exp: {
        "count": 0,
        "tokens_would_save_total": 0,
        "tokens_would_save_known": 0,  # how many records had a non-None tokens_would_save
        "unknown_count": 0,  # shape recognized, rule could not cut it (rule "unknown")
        "unmatched_count": 0,  # a large output no fixed rule applies to (rule "unmatched"): nothing evaluated, nothing cut
        # Every REAL cut (tokens_would_save > 0) is in exactly one of four places, and the report says how many are
        # in each: a join candidate (joined, or pending), no_signature_count, or unjoinable_count. A cut in none of
        # them reads as covered by the referenced-later rate while the join never looks at it.
        # -- nothing distinctive to search for: the offline join skips it
        "no_signature_count": 0,
        # -- signatures, but the row lacks what the join needs to search with (transcript path, tool_use_id,
        #    entity_id) or carries the signature list as something that is not a list: the join cannot act on it
        "unjoinable_count": 0,
        # which hook event the row came from: PostToolUseFailure = the command exited non-zero (PostToolUse fires
        # ONLY for exit 0), so the failed-command population is countable apart; a row with no hook_event at all
        # (logged before the field existed) is in neither bucket
        "failure_count": 0,
        "event_unrecorded_count": 0,
        "no_gain_count": 0,  # rule "no-gain" -- shape recognized, cutting would not shrink it
        # ---- Jev tier only (all zero for the fixed rule) ----
        "jev_judged_relevant": 0,  # record states: judged, nothing to cut
        "jev_judged_cuttable": 0,  # judged, at least one block cuttable
        "jev_not_judged": 0,  # NOT ONE block judged -- never a 0, never in an average
        "jev_state_unreadable": 0,  # a Jev row with no readable jev_state: counted apart, not guessed
        "full_relevant": 0, "full_cuttable": 0,  # coverage "full" x state: nothing to cut / something cuttable
        "cov_full": 0, "cov_partial": 0, "cov_none": 0, "cov_unreadable": 0,
        "inconsistent_count": 0,  # carries a saving number without coverage "full": left out of every number
        "lower_bound_total": 0, "lower_bound_count": 0,  # partial records: the floor of the saving, printed apart
        "blocks_total": 0, "blocks_relevant": 0, "blocks_cuttable": 0, "blocks_not_judged": 0,
        "rows_without_block_detail": 0,  # the tier itself broke (exception record) or the counters are unreadable
        "not_judged_reasons": {},  # block-level reason -> blocks
        "calls_failed": 0, "calls_not_made": 0, "tokens_in": 0, "tokens_out": 0,
    } for exp in SOURCE_EXPERIMENTS}
    tier = {"attempted": 0, "sampled_out": 0, "disabled": 0, "unrecorded": 0}
    attempted_ids: set[str] = set()  # unmatched rows stamped 'attempted'
    jev_result_ids: set[str] = set()  # entity ids that have a Jev result row
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
        saved_is_number = _is_number(saved)
        real_cut = saved if saved_is_number else None  # the cut this row claims, for the where-did-every-cut-go accounting
        if exp == JEV_EXPERIMENT:
            if isinstance(rec.get("entity_id"), str):
                jev_result_ids.add(rec["entity_id"])
            _count_jev_row(s, rec)
            coverage = rec.get("coverage")
            if saved_is_number and not (coverage == "full" and rec.get("jev_state") in JEV_FULL_STATES):
                # a number on a row that was not judged in full: do not average it, do not bucket it, say so
                s["inconsistent_count"] += 1
                saved_is_number = False
                real_cut = None
            lower_bound = rec.get("tokens_saved_lower_bound")
            if coverage == "partial" and _is_number(lower_bound):
                s["lower_bound_total"] += lower_bound
                s["lower_bound_count"] += 1
                real_cut = lower_bound
        if saved_is_number:
            s["tokens_would_save_total"] += saved
            s["tokens_would_save_known"] += 1
        if real_cut is not None and real_cut > 0:
            if not rec.get("omitted_signatures"):
                s["no_signature_count"] += 1
            elif not is_join_candidate(rec):
                s["unjoinable_count"] += 1
        rule = rec.get("rule")
        if rule == "unknown":
            s["unknown_count"] += 1
        elif rule == "unmatched":
            s["unmatched_count"] += 1
            if exp == FIXED_EXPERIMENT:
                stamp = rec.get("jev_tier")
                if stamp == "attempted":
                    tier["attempted"] += 1
                    if isinstance(rec.get("entity_id"), str):
                        attempted_ids.add(rec["entity_id"])
                elif stamp == "sampled-out":
                    tier["sampled_out"] += 1
                elif stamp == "disabled":
                    tier["disabled"] += 1
                else:
                    tier["unrecorded"] += 1  # logged before the stamp existed (or unreadable): not guessed
        elif rule == "no-gain":
            s["no_gain_count"] += 1

    by_experiment = {exp: {"referenced_true": 0, "referenced_false": 0, "referenced_unknown": 0} for exp in SOURCE_EXPERIMENTS}
    referenced_true = 0
    referenced_false = 0
    referenced_unknown = 0
    by_event = {"success": {"referenced_true": 0, "referenced_false": 0}, "failure": {"referenced_true": 0, "referenced_false": 0}}
    for key, v in joins.items():
        slot = by_experiment[key[0]]
        if v is True:
            referenced_true += 1
            slot["referenced_true"] += 1
        elif v is False:
            referenced_false += 1
            slot["referenced_false"] += 1
        else:
            referenced_unknown += 1
            slot["referenced_unknown"] += 1
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
        # and by the tier whose cut they are about (the fixed rule's and Jev's populations are not the same)
        "by_experiment": by_experiment,
    }
    # What became of the Jev tier for the unmatched outputs. "attempted" with no result row is a LOST attempt (the call or
    # the hook died after the fixed-rule row was written): it is in no Jev number and the report says how many.
    tier["unmatched"] = stats[FIXED_EXPERIMENT]["unmatched_count"]
    tier["attempted_lost"] = len(attempted_ids - jev_result_ids)
    stats["jev_tier"] = tier
    stats["errors"] = {"total": error_total, "by_kind": error_kinds}
    return stats


def log_problem(path: Path) -> str | None:
    """Why the log could not be READ, or None when it can. read_jsonl() answers [] for a log it cannot open,
    exactly as it does for an empty one, so without this an unreadable (or missing, or wrongly pointed-at) log
    printed "0 case(s)" and "Hook errors: none logged" -- the words of a quiet day. There are three states:
    has rows / has none / could not be read, and the third must not print as the second. An EMPTY readable
    log is a real "no rows" and is not a problem. Never raises."""
    try:
        with path.open("rb") as f:
            f.read(1)
    except OSError as e:
        return f"{type(e).__name__}: {e.strerror or e}"
    return None


def _jev_lines(stats: dict) -> list[str]:
    """The Jev tier's section of the full report. Every count that could pass for "nothing happened" says what it counts:
    a record judged in full, a floor over partial records, NOT JUDGED records and blocks (each on its own line, never a 0 and
    never in the average), and attempts that left no result row."""
    s = stats[JEV_EXPERIMENT]
    t = stats["jev_tier"]
    lines = ["  Jev tier (a sample of the outputs no fixed rule applies to, judged block by block after an egress guard; off unless a human turns it on -- ga-d0hm85):"]
    if not t["unmatched"] and not s["count"]:
        lines.append("    no output without a fixed rule logged yet, and no Jev result row")
        return lines
    stamp = (f"    unmatched outputs: {t['unmatched']} -- tier attempted {t['attempted']}, sampled out {t['sampled_out']}, "
             f"disabled {t['disabled']}")
    if t["unrecorded"]:
        stamp += f", {t['unrecorded']} with no stamp (logged before the field existed)"
    lines.append(stamp)
    if t["attempted_lost"]:
        lines.append(
            f"    {t['attempted_lost']} attempt(s) have NO result row -- the call or the hook died after the fixed-rule row was written "
            f"(see 'engine_rc_137' under Hook errors); they are in no Jev number below"
        )
    if not s["count"]:
        lines.append("    no Jev result row logged")
        return lines
    avg = (s["tokens_would_save_total"] / s["tokens_would_save_known"]) if s["tokens_would_save_known"] else None
    avg_txt = f"avg tokens_would_save={avg:.0f} over {s['tokens_would_save_known']}" if avg is not None else "no measurable tokens_would_save yet"
    lines.append(
        f"    judged in FULL: {s['cov_full']} record(s) ({s['full_relevant']} with nothing to cut, {s['full_cuttable']} with something cuttable); "
        f"{avg_txt} -- only these enter the average"
    )
    if s["cov_partial"]:
        lines.append(
            f"    PARTIAL (some blocks NOT JUDGED): {s['cov_partial']} record(s); their judged-cuttable blocks alone would save >= "
            f"{s['lower_bound_total']} tokens (a floor over {s['lower_bound_count']}) -- kept OUT of the average, the unjudged part is not assumed to be nothing"
        )
    lines.append(
        f"    NOT JUDGED at all: {s['jev_not_judged']} record(s) (Jev unreachable, no usable answer, or everything withheld/over budget) -- "
        f"counted on their own: never a 0 saving, never in an average"
    )
    reasons = ", ".join(f"{r} x{n}" for r, n in sorted(s["not_judged_reasons"].items(), key=lambda kv: (-kv[1], kv[0])))
    lines.append(
        f"    blocks: {s['blocks_total']} -- {s['blocks_relevant']} relevant, {s['blocks_cuttable']} cuttable, "
        f"{s['blocks_not_judged']} NOT JUDGED" + (f" ({reasons})" if reasons else "")
    )
    if s["rows_without_block_detail"]:
        lines.append(f"    {s['rows_without_block_detail']} record(s) carry no block counters (the tier itself failed, or the row is unreadable) -- in no block number")
    unreadable = s["jev_state_unreadable"] + s["cov_unreadable"]
    if unreadable:
        lines.append(f"    {unreadable} unreadable state/coverage field(s) on Jev rows -- counted apart, not guessed")
    if s["inconsistent_count"]:
        lines.append(
            f"    {s['inconsistent_count']} Jev row(s) carry a saving number without coverage 'full' -- NOT trusted: in no average and no total"
        )
    lines.append(
        f"    Jev cost: {s['tokens_in']} input / {s['tokens_out']} output tokens; {s['calls_failed']} call(s) failed, "
        f"{s['calls_not_made']} not made (nothing was sendable)"
    )
    return lines


def format_report(stats: dict) -> str:
    if stats.get("log_problem"):
        # nothing was read, so every number below would be a zero that means "unknown" -- print none of them
        return (
            f"Cut-large-output (ga-wk0qi2, SHADOW): LOG NOT READ ({stats['log_problem']}) -- no case, join or hook-error "
            f"count is available; this is NOT a report of zero cases."
        )
    lines = ["Cut-large-output (ga-wk0qi2, SHADOW — nothing is actually cut yet):"]
    label = "Fixed rule (pytest/log-tail, no AI)"
    s = stats["cut-output-fixed"]
    avg = (s["tokens_would_save_total"] / s["tokens_would_save_known"]) if s["tokens_would_save_known"] else None
    lines.append(f"  {label}: {s['count']} case(s), avg tokens_would_save={avg:.0f}" if avg is not None else f"  {label}: {s['count']} case(s), no measurable tokens_would_save yet")
    if s["unknown_count"]:
        lines.append(f"    {s['unknown_count']} unknown (shape recognized but the rule could not cut it, kept in full; not in the average)")
    if s["unmatched_count"]:
        lines.append(
            f"    {s['unmatched_count']} unmatched (large output no fixed rule applies to, kept in full -- the FIXED rule evaluated nothing, so "
            f"they are not in the average; this is how much large output the rule does not reach; the Jev tier below judges a sample of them)"
        )
    if s["no_gain_count"]:
        lines.append(
            f"    {s['no_gain_count']} no-gain (shape recognized, but cutting would not shrink the output -- nothing omitted; "
            f"a measured 0 tokens saved, so it IS in the average, unlike 'unknown')"
        )
    lines.extend(_jev_lines(stats))
    j = stats["joins"]
    total_cases = stats[FIXED_EXPERIMENT]["count"]
    if total_cases:
        # PostToolUse fires only for a command that exited 0; one that exited non-zero fires PostToolUseFailure. Its
        # output is shown apart so the rate below cannot be carried by exit-0 runs, and a 0 here is said out loud:
        # it is exactly what a missing PostToolUseFailure registration looks like.
        failed_cases = stats[FIXED_EXPERIMENT]["failure_count"]
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
        unrecorded = stats[FIXED_EXPERIMENT]["event_unrecorded_count"]
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
        lines.append(
            "  The rate counts only signatures (bead id, path, sha, error-line snippet) a later turn quoted VERBATIM; a later turn "
            "that acted on the cut content without quoting it is not seen, so a low rate does not show that cutting would lose nothing"
        )
    jj = j["by_experiment"][JEV_EXPERIMENT]
    if jj["referenced_true"] + jj["referenced_false"] + jj["referenced_unknown"]:
        jdecided = jj["referenced_true"] + jj["referenced_false"]
        jrate = f"{jj['referenced_true'] / jdecided * 100:.1f}%" if jdecided else "n/a"
        lines.append(
            f"    of which the Jev tier's cuts (only the blocks it judged cuttable): referenced later {jj['referenced_true']}, "
            f"not referenced {jj['referenced_false']}, unknown {jj['referenced_unknown']} (rate {jrate}) -- a different population "
            f"from the fixed rule's, so compare the two rates, do not read the total as one"
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
    unjoinable = sum(stats[exp]["unjoinable_count"] for exp in SOURCE_EXPERIMENTS)
    if unjoinable:
        lines.append(
            f"  {unjoinable} cut(s) the join cannot check (the row has signatures but no transcript path or tool_use_id, or a "
            f"malformed signature list) — outside the rate above (not looked for is not 'looked for and not found')"
        )
    e = stats["errors"]
    if e["total"]:
        kinds = ", ".join(f"{stage}: {err} x{n}" for (stage, err), n in sorted(e["by_kind"].items(), key=lambda kv: (-kv[1], kv[0])))
        note = " (engine_rc_137 = the wrapper's watchdog killed the engine)" if any(err == "engine_rc_137" for _, err in e["by_kind"]) else ""
        lines.append(f"  Hook errors: {e['total']} call(s) whose measurement was LOST -- {kinds}{note}")
    else:
        lines.append(
            "  Hook errors: none logged (a zero here means 'none that could be written down': jq missing, an unparseable "
            "payload, an unwritable log or a missing wrapper script leave no row)"
        )
    return "\n".join(lines)


def format_resumo_pt(stats: dict) -> str:
    if stats.get("log_problem"):
        return (
            f"Cortar-saída-grande (SOMBRA): log não lido ({stats['log_problem']}) -- sem dado nenhum, isto NÃO é zero caso."
        )
    fixed = stats["cut-output-fixed"]["count"]
    fixed_unknown = stats["cut-output-fixed"]["unknown_count"]
    fixed_unmatched = stats["cut-output-fixed"]["unmatched_count"]
    j = stats["joins"]
    rate_str = f"{j['referenced_rate']*100:.1f}%" if j["referenced_rate"] is not None else "sem dado"
    # cases the fixed rule could not read count as observed, but they cut nothing -- say so instead
    # of letting "N via regra fixa" read as N cuts
    fixed_notes = []
    if fixed_unknown:
        fixed_notes.append(f"{fixed_unknown} sem corte: formato não reconhecido")
    if fixed_unmatched:
        fixed_notes.append(f"{fixed_unmatched} sem regra aplicável")
    fixed_note = f" ({'; '.join(fixed_notes)})" if fixed_notes else ""
    # "conferido(s)" is the population the rate is computed over (a verdict of yes or no); joins with no verdict
    # (unknown) and cuts still waiting for their session to end are named apart, not folded into that count
    decided = j["referenced_true"] + j["referenced_false"]
    join_notes = ""
    if j["referenced_unknown"]:
        join_notes += f", {j['referenced_unknown']} sem veredito"
    if j["pending"]:
        join_notes += f", {j['pending']} aguardando a sessão terminar"
    total_cases = stats[FIXED_EXPERIMENT]["count"]
    failed_cases = stats[FIXED_EXPERIMENT]["failure_count"]
    extra = ""
    if failed_cases:
        extra += f" {failed_cases} de {total_cases} casos vieram de comandos com falha."
    if stats["errors"]["total"]:
        extra += f" O hook perdeu {stats['errors']['total']} medição(ões) por erro."
    jev = stats[JEV_EXPERIMENT]
    tier = stats["jev_tier"]
    jev_note = ""
    if jev["count"] or tier["attempted"]:
        jev_note = (
            f" Jev (amostra do que a regra fixa não corta): {jev['cov_full']} julgado(s) por inteiro, {jev['cov_partial']} parcial(is), "
            f"{jev['jev_not_judged']} NÃO julgado(s) (fora de qualquer média, nunca contam como zero)"
            + (f", {tier['attempted_lost']} tentativa(s) sem resultado" if tier["attempted_lost"] else "")
            + "."
        )
    elif tier["unmatched"]:
        jev_note = f" Jev: nenhuma tentativa ({tier['disabled']} desligado, {tier['sampled_out']} fora da amostra, {tier['unrecorded']} sem carimbo)."
    return (
        f"Cortar-saída-grande (SOMBRA, nada é cortado de verdade ainda): {fixed} caso(s) via regra fixa{fixed_note}.{jev_note} "
        f"Join offline: {decided} conferido(s){join_notes}, taxa de 'precisou depois' = {rate_str} "
        f"(só conta citação literal, taxa baixa não prova que cortar não perde nada; teto esperado do bead: ~8%).{extra}"
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
    stats["log_problem"] = log_problem(log_path)  # None when readable; read_jsonl's [] cannot tell that from "no rows"
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
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "e1", "referenced_later": True},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "e2", "referenced_later": False},
        {"mode": RECORD_MODE, "experiment": "unrelated-front", "entity_id": "e9", "tokens_would_save": 999},
    ]
    stats = compute_stats(records)
    ok("fixed-rule count", stats["cut-output-fixed"]["count"] == 2)
    ok("fixed-rule tokens_would_save_total", stats["cut-output-fixed"]["tokens_would_save_total"] == 300)
    ok("fixed-rule tokens_would_save_known counts both numbers", stats["cut-output-fixed"]["tokens_would_save_known"] == 2)
    ok("unrelated-front is ignored entirely", "unrelated-front" not in stats)
    ok("joins total = 2", stats["joins"]["total"] == 2)
    ok("joins referenced_true = 1", stats["joins"]["referenced_true"] == 1)
    ok("joins referenced_false = 1", stats["joins"]["referenced_false"] == 1)
    ok("joins referenced_rate = 1/2", abs(stats["joins"]["referenced_rate"] - 0.5) < 1e-9)

    report_text = format_report(stats)
    ok("format_report names the fixed rule", "Fixed rule" in report_text)
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
    # out. ----
    sig_records = [
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "s1", "tokens_would_save": 100, "omitted_signatures": ["ga-x"]},
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "s2", "tokens_would_save": 90, "omitted_signatures": []},
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "s3", "tokens_would_save": 80},  # field missing
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "s4", "rule": "unknown", "tokens_would_save": None, "omitted_signatures": []},
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "s5", "tokens_would_save": 0, "omitted_signatures": []},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "s1", "referenced_later": False},
    ]
    sig_stats = compute_stats(sig_records)
    ok("fixed tier: exactly the real cuts with an empty/missing omitted_signatures are 'nothing to look for' "
       "(s2, s3) -- not the one with signatures (s1), the 'unknown' one with no cut (s4), or the zero-token one (s5)",
       sig_stats["cut-output-fixed"].get("no_signature_count") == 2)
    sig_text = format_report(sig_stats)
    ok("format_report says how many cuts had nothing to look for and are outside the rate", "2 cut(s) had no signature to look for" in sig_text)
    quiet_text = format_report(compute_stats([
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "q1", "tokens_would_save": 100, "omitted_signatures": ["ga-x"],
         "transcript_path": "/tmp/q.jsonl", "tool_use_id": "q1"},
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "q2", "tokens_would_save": 50, "omitted_signatures": ["/a/b/c"],
         "transcript_path": "/tmp/q.jsonl", "tool_use_id": "q2"},
    ]))
    ok("format_report stays quiet about both when every cut has signatures and the join can check every one",
       "no signature to look for" not in quiet_text and "the join cannot check" not in quiet_text)

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
        {"mode": "shadow", "experiment": "cut-output-fixed", "entity_id": "t2", "command": "c", "tokens_would_save": 9999},
        {"mode": "shadow-join", "experiment": "cut-output-jev", "entity_id": "t", "referenced_later": True},
        {"mode": "shadow-join", "experiment": "cut-output-fixed", "entity_id": "t2", "referenced_later": True},
    ])
    ok("legacy mode=='shadow' rows of a cut-output experiment are ignored (count and total unchanged)",
       legacy_stats["cut-output-fixed"]["count"] == stats["cut-output-fixed"]["count"]
       and legacy_stats["cut-output-fixed"]["tokens_would_save_total"] == stats["cut-output-fixed"]["tokens_would_save_total"])
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
        _cand("p1"), _cand("p2"),                                                        # waiting for the join
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
        _ev("ok1", "PostToolUse"), _ev("ok2", "PostToolUse"), _ev("ok3", "PostToolUse"),
        _ev("f1", "PostToolUseFailure", exit_code=1), _ev("f2", "PostToolUseFailure", exit_code=2),
        _ev("f3", "PostToolUseFailure", exit_code=1),
        _cand("old1"),  # no hook_event at all (a row from before the field existed)
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "ok1", "referenced_later": False},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "ok2", "referenced_later": False},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "f1", "referenced_later": True},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "f2", "referenced_later": False},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "old1", "referenced_later": True},
    ]
    split_stats = compute_stats(split_records)
    ok("failed-command cases are counted (f1, f2, f3)", split_stats["cut-output-fixed"]["failure_count"] == 3)
    ok("a row with no hook_event is counted apart, in neither bucket", split_stats["cut-output-fixed"]["event_unrecorded_count"] == 1)
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
    ok("error rows are NOT cases: the case count is unchanged", err_stats["cut-output-fixed"]["count"] == stats["cut-output-fixed"]["count"])
    ok("error rows do not enter the offline join", err_stats["joins"] == stats["joins"])
    err_text = format_report(err_stats)
    ok("format_report names the lost measurements and their reasons",
       "3 call(s) whose measurement was LOST" in err_text and "wrapper: engine_rc_137 x2" in err_text and "engine: TypeError x1" in err_text)
    none_text = format_report(stats)
    ok("with no error rows the report still says so -- and what a zero cannot see (jq missing, unwritable log, missing wrapper)",
       "Hook errors: none logged" in none_text and "unwritable log" in none_text)
    # the wrapper cannot even SIZE a payload jq cannot parse (e.g. an output truncated through an emoji leaves a lone
    # surrogate escape that jq rejects and python accepts), so that call gets `{}` and NO row: a zero here does not
    # cover it, and the wrapper's own header says so -- the report's footnote has to name it too
    ok("the 'none logged' footnote also names the payload the wrapper cannot parse (no row either)",
       "an unparseable payload" in none_text)
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

    # ---- ga-d0hm85: the Jev tier is back, and the report does not trust its rows ----
    fixed_only = [r for r in records if r.get("experiment") != "cut-output-jev"]
    jev_leftover = {"mode": RECORD_MODE, "experiment": "cut-output-jev", "entity_id": "j1", "tokens_would_save": 500, "jev_ok": True,
                    "omitted_signatures": ["ga-x"], "transcript_path": "/tmp/j.jsonl", "tool_use_id": "j1"}
    old_shape = compute_stats(fixed_only + [jev_leftover])
    ok("a Jev row in the OLD tier's shape (a saving number, no coverage, no state) is counted as a row ...", old_shape["cut-output-jev"]["count"] == 1)
    ok("... but its number is NOT trusted: inconsistent, in no average and no total (the consumer does not trust the producer)",
       old_shape["cut-output-jev"]["inconsistent_count"] == 1 and old_shape["cut-output-jev"]["tokens_would_save_known"] == 0
       and old_shape["cut-output-jev"]["tokens_would_save_total"] == 0)
    ok("... and its unreadable state/coverage is counted apart, not guessed", old_shape["cut-output-jev"]["jev_state_unreadable"] == 1 and old_shape["cut-output-jev"]["cov_unreadable"] == 1)
    ok("... and the report says so", "NOT trusted" in format_report(old_shape) and "unreadable state/coverage" in format_report(old_shape))
    ok("a fixed-only log still reports a Jev section, and it says there is nothing yet (it does not stay silent)",
       "Jev tier" in format_report(compute_stats([r for r in fixed_only if r.get("rule") != "unmatched"])) and "no output without a fixed rule logged yet" in format_report(compute_stats([r for r in fixed_only if r.get("rule") != "unmatched"])))
    ok("the phone text stays quiet about Jev when there is no unmatched output and no Jev row", "Jev" not in format_resumo_pt(compute_stats([r for r in fixed_only if r.get("rule") != "unmatched"])))

    # ---- rows built by the REAL producer (cut_output_jev), so a drift between the two files fails here, loudly ----
    import cut_output_jev as cjev

    prose = "\n\n".join(f"paragraph {i}: " + "ordinary words " * 25 for i in range(12))
    pmeta = {"session_id": "s", "transcript_path": "/tmp/s.jsonl", "command": "tool", "hook_event": coc.EVENT_SUCCESS, "exit_code": None}

    def _produce(eid: str, jev_result):
        bl = cjev.build_blocks(prose, max_blocks=4)
        cjev.plan_send(bl, prose, max_chars=10**6)
        cjev.resolve_blocks(bl, jev_result)
        return cjev.build_jev_record(jev_result, bl, prose, dict(pmeta, entity_id=eid, tool_use_id=eid))

    def _fixed_unmatched(eid: str, stamp):
        row = {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": eid, "rule": "unmatched", "tokens_would_save": None,
               "hook_event": coc.EVENT_SUCCESS}
        if stamp is not None:
            row["jev_tier"] = stamp
        return row

    cut_ans = {"ok": True, "answers": {f"block_{i}": 0.02 for i in range(4)}, "bad": {}, "tokens_in": 500, "tokens_out": 4}
    rel_ans = {"ok": True, "answers": {f"block_{i}": 0.95 for i in range(4)}, "bad": {}, "tokens_in": 500, "tokens_out": 4}
    part_ans = {"ok": True, "answers": {"block_0": 0.02, "block_1": 0.95, "block_3": 0.95}, "bad": {"block_2": "unparseable_answer: x"}, "tokens_in": 500, "tokens_out": 4}
    bad_ans = {"ok": True, "answers": {}, "bad": {f"block_{i}": "unparseable_answer: x" for i in range(4)}, "tokens_in": 500, "tokens_out": 1}
    down = {"ok": False, "error": "deadline"}
    produced = {"cut": _produce("j-cut", cut_ans), "rel": _produce("j-rel", rel_ans), "part": _produce("j-part", part_ans),
                "bad": _produce("j-bad", bad_ans), "down": _produce("j-down", down)}
    jev_log = (
        [_fixed_unmatched(eid, "attempted") for eid in ("j-cut", "j-rel", "j-part", "j-bad", "j-down", "j-lost")]
        + [_fixed_unmatched("u-so", "sampled-out"), _fixed_unmatched("u-dis", "disabled"), _fixed_unmatched("u-old", None)]
        + list(produced.values())
    )
    js = compute_stats(jev_log)
    jv = js["cut-output-jev"]
    ok("producer->report: 5 Jev result rows counted", jv["count"] == 5)
    ok("producer->report: record states land in their own buckets (1 relevant-in-full, 2 with something cuttable, 2 NOT JUDGED)",
       (jv["jev_judged_relevant"], jv["jev_judged_cuttable"], jv["jev_not_judged"]) == (1, 2, 2))
    ok("producer->report: coverage 2 full, 1 partial, 2 none", (jv["cov_full"], jv["cov_partial"], jv["cov_none"]) == (2, 1, 2))
    ok("producer->report: the average has exactly the two FULL records (the all-relevant 0 and the cut), nobody else",
       jv["tokens_would_save_known"] == 2 and jv["tokens_would_save_total"] == produced["cut"]["tokens_would_save"] + 0 and jv["inconsistent_count"] == 0)
    ok("producer->report: the partial record's floor is counted apart and is NOT in the total",
       jv["lower_bound_count"] == 1 and jv["lower_bound_total"] == produced["part"]["tokens_saved_lower_bound"] > 0)
    ok("producer->report: NOT-JUDGED blocks are counted: 1 (partial) + 4 (all-bad) + 4 (call failed)", jv["blocks_not_judged"] == 9)
    ok("producer->report: the reasons are summed per class", jv["not_judged_reasons"] == {"no-answer:unparseable_answer": 5, "call-failed:deadline": 4})
    ok("producer->report: block totals reconcile (relevant + cuttable + not-judged == total)", jv["blocks_relevant"] + jv["blocks_cuttable"] + jv["blocks_not_judged"] == jv["blocks_total"] == 20)
    ok("producer->report: Jev token cost sums only over calls that answered", jv["tokens_in"] == 2000 and jv["calls_failed"] == 1)
    tr = js["jev_tier"]
    ok("tier stamps: 6 attempted, 1 sampled out, 1 disabled, 1 unstamped (older row) -- unmatched total 9",
       (tr["attempted"], tr["sampled_out"], tr["disabled"], tr["unrecorded"], tr["unmatched"]) == (6, 1, 1, 1, 9))
    ok("an attempt with NO result row is counted as LOST (j-lost), not as a quiet day", tr["attempted_lost"] == 1)
    jtext = format_report(js)
    ok("report: the not-judged line is there, with its own count", "NOT JUDGED at all: 2 record(s)" in jtext)
    ok("report: the partial line is there with a floor, and says it is out of the average", "PARTIAL" in jtext and "OUT of the average" in jtext)
    ok("report: the lost attempt is printed", "1 attempt(s) have NO result row" in jtext)
    ok("report: the block line carries the reasons", "9 NOT JUDGED" in jtext and "no-answer:unparseable_answer x5" in jtext and "call-failed:deadline x4" in jtext)
    ok("report: the case population is the FIXED rows only -- a sampled output has a fixed row AND a Jev row, and must count once "
       "(9 fixed + 5 Jev rows printed as '0 of 9 case(s)', not 14)",
       js["cut-output-fixed"]["count"] == 9 and "exited non-zero (PostToolUseFailure): 0 of 9 case(s)" in jtext and "of 14 case(s)" not in jtext)
    ok("phone text: names the three states and the lost attempt in Portuguese",
       "2 julgado(s) por inteiro, 1 parcial(is), 2 NÃO julgado(s)" in format_resumo_pt(js) and "1 tentativa(s) sem resultado" in format_resumo_pt(js))

    # ---- THE gate verdict ga-nw6sbx, as the report assertion (c): a Jev tier whose every call judged nothing must not read
    # as "measured, saves ~0" ----
    only_bad = [_fixed_unmatched("b1", "attempted"), _fixed_unmatched("b2", "attempted"), _produce("b1", bad_ans), _produce("b2", bad_ans)]
    bs = compute_stats(only_bad)
    btext = format_report(bs)
    ok("ga-nw6sbx (c): only not-judged Jev rows -> no average is printed for the Jev tier, and it says 'no measurable tokens_would_save yet'",
       bs["cut-output-jev"]["tokens_would_save_known"] == 0 and "judged in FULL: 0 record(s)" in btext and "no measurable tokens_would_save yet" in btext.split("  Jev tier (")[1])
    ok("ga-nw6sbx (c): ... and the NOT JUDGED line appears with the count (the old report printed 'avg tokens_would_save=0' and nothing else)", "NOT JUDGED at all: 2 record(s)" in btext)
    ok("ga-nw6sbx (c): ... and the phone text says 2 NÃO julgado(s), 0 por inteiro", "0 julgado(s) por inteiro" in format_resumo_pt(bs) and "2 NÃO julgado(s)" in format_resumo_pt(bs))
    # the SAME records with the old producer's collapse (a zero on a row that judged nothing) would have averaged to 0:
    collapsed = [dict(r, tokens_would_save=0) for r in only_bad if r.get("experiment") == "cut-output-jev"]
    cs = compute_stats([r for r in only_bad if r.get("experiment") != "cut-output-jev"] + collapsed)
    ok("ga-nw6sbx (c): and even a producer that regresses to the old 0 cannot fool the report -- coverage 'none' makes the zero inconsistent, not an average",
       cs["cut-output-jev"]["tokens_would_save_known"] == 0 and cs["cut-output-jev"]["inconsistent_count"] == 2)

    # ---- a Jev row about a lost attempt is not double counted, and rows with odd types never raise ----
    odd = compute_stats([
        {"mode": RECORD_MODE, "experiment": "cut-output-jev", "entity_id": ["x"], "jev_state": 5, "coverage": None, "blocks_relevant": "3",
         "not_judged_reasons": {"a": "many", 3: 1}, "jev_tokens_in": True, "tokens_would_save": True, "tokens_saved_lower_bound": "9"},
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": 7, "rule": "unmatched", "jev_tier": ["attempted"]},
    ])
    ok("odd types on Jev/unmatched rows never raise, and land in the 'unreadable' buckets",
       odd["cut-output-jev"]["jev_state_unreadable"] == 1 and odd["cut-output-jev"]["rows_without_block_detail"] == 1 and odd["jev_tier"]["unrecorded"] == 1
       and odd["cut-output-jev"]["tokens_would_save_known"] == 0 and odd["cut-output-jev"]["tokens_in"] == 0)
    jj_stats = compute_stats([
        {"mode": RECORD_MODE, "experiment": "cut-output-jev", "entity_id": "k1", "omitted_signatures": ["ga-cutme"], "transcript_path": "/t", "tool_use_id": "k1",
         "jev_state": "judged-cuttable", "coverage": "full", "tokens_would_save": 30},
        {"mode": JOIN_MODE, "experiment": "cut-output-jev", "entity_id": "k1", "referenced_later": True},
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "f1", "tokens_would_save": 10, "omitted_signatures": ["ga-f"], "transcript_path": "/t", "tool_use_id": "f1"},
        {"mode": JOIN_MODE, "experiment": "cut-output-fixed", "entity_id": "f1", "referenced_later": False},
    ])
    ok("the join verdicts are split by tier: Jev 1 referenced / fixed 1 not", jj_stats["joins"]["by_experiment"]["cut-output-jev"]["referenced_true"] == 1 and jj_stats["joins"]["by_experiment"]["cut-output-fixed"]["referenced_false"] == 1)
    ok("the report prints the Jev tier's own referenced-later line", "of which the Jev tier's cuts" in format_report(jj_stats))

    # ---- 'unmatched': a large output no fixed rule applies to. It is one row of the rule's own third state (nothing was
    # evaluated, nothing cut), so it is counted apart and kept OUT of the average -- unlike 'no-gain', a measured zero ----
    um_stats = compute_stats([
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "m1", "rule": "unmatched", "tokens_would_save": None, "omitted_signatures": []},
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "m2", "rule": "unmatched", "tokens_would_save": None, "omitted_signatures": []},
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "m3", "rule": "pytest", "tokens_would_save": 100, "omitted_signatures": ["ga-x"],
         "transcript_path": "/tmp/m.jsonl", "tool_use_id": "m3"},
    ])
    um = um_stats["cut-output-fixed"]
    ok("unmatched: counted on their own (2), and not folded into 'unknown' (a recognized shape) or 'no-gain' (a measured zero)",
       um.get("unmatched_count") == 2 and um["unknown_count"] == 0 and um["no_gain_count"] == 0)
    ok("unmatched: still observed cases (3) but not in the average (1 known number)", um["count"] == 3 and um["tokens_would_save_known"] == 1)
    ok("unmatched: an unmatched row is not a 'cut with no signature' either (it cut nothing)", um["no_signature_count"] == 0)
    um_text = format_report(um_stats)
    ok("format_report says how many large outputs no fixed rule applies to, kept in full and outside the average",
       "2 unmatched" in um_text and "no fixed rule applies" in um_text and "not in the average" in um_text)
    ok("format_report stays quiet about unmatched when there are none", "unmatched" not in format_report(stats))
    ok("format_resumo_pt says how many had no rule to apply ('sem regra')", "2 sem regra" in format_resumo_pt(um_stats))
    ok("format_resumo_pt stays quiet about 'sem regra' when there are none", "sem regra" not in format_resumo_pt(stats))

    # ---- accounting must be EXHAUSTIVE (gate_run ga-nw6sbx, same-class sibling): every real cut (tokens_would_save > 0) is
    # in exactly one place -- a candidate (joined, or pending), or 'no signature', or 'the join cannot check it'. A cut
    # with signatures but no transcript path / tool_use_id was in none: not pending, not joined, not counted, and the
    # report did not say so, so its rate looked like it covered every cut ----
    acct_stats = compute_stats([
        _cand("c1"),                                   # a candidate, not joined yet: pending
        _cand("c2", omitted_signatures=[]),            # nothing to look for
        _cand("c3", transcript_path=None),             # signatures, but no transcript to search
        _cand("c4", tool_use_id=None),                 # signatures, but no call to locate in it
        _cand("c5", omitted_signatures="not-a-list"),  # a malformed signature list (truthy, not a list)
        _cand("c6", tokens_would_save=0, omitted_signatures=[]),  # a real no-gain row (nothing omitted): not a cut, in no bucket by design
        {"mode": RECORD_MODE, "experiment": "cut-output-fixed", "entity_id": "c7", "rule": "unknown", "tokens_would_save": None},
    ])
    ac = acct_stats["cut-output-fixed"]
    ok("accounting: cuts the join cannot act on (c3, c4, c5) are counted apart", ac.get("unjoinable_count") == 3)
    ok("accounting: ...and no cut is counted twice (c2 stays 'no signature', c1 stays a candidate)",
       ac["no_signature_count"] == 1 and acct_stats["joins"]["pending"] == 1)
    real_cuts = 5  # c1..c5 have tokens_would_save > 0
    ok("accounting is exhaustive: pending + joined + no-signature + cannot-check == every real cut",
       acct_stats["joins"]["pending"] + acct_stats["joins"]["total"] + ac["no_signature_count"] + (ac.get("unjoinable_count") or 0) == real_cuts)
    ok("format_report says how many cuts the join cannot check, outside the rate",
       "3 cut(s) the join cannot check" in format_report(acct_stats))
    ok("format_report stays quiet about that when every cut is checkable", "the join cannot check" not in format_report(stats))

    empty_stats = compute_stats([])
    ok("compute_stats on empty input never raises, counts are zero", empty_stats["cut-output-fixed"]["count"] == 0 and empty_stats["joins"]["total"] == 0)
    ok("format_report on empty stats doesn't crash and says no joined cases yet", "no joined cases yet" in format_report(empty_stats))
    ok("format_resumo_pt on empty stats doesn't crash", isinstance(format_resumo_pt(empty_stats), str))

    # ---- the join's module docstring says a low rate does not show that cutting loses nothing (only a VERBATIM
    # quote counts; a later turn that used the cut content without quoting it is invisible), and that the report
    # says so. A promise in a comment is only worth what the printed report delivers, so the caveat is pinned
    # where the rate is printed -- the full report and the phone text -- and only when there IS a rate to
    # misread. (Worded without the word "safe": the report never states a verdict, see the test above.) ----
    with_rate = compute_stats(records)
    with_rate_text = format_report(with_rate)
    ok("format_report: next to the rate it says only VERBATIM quotes count and a low rate does not show that cutting loses nothing",
       "VERBATIM" in with_rate_text and "does not show" in with_rate_text)
    ok("format_resumo_pt: the phone text says the rate counts only literal quotes ('citação literal')",
       "citação literal" in format_resumo_pt(with_rate))
    ok("format_report: no caveat when there is no joined case to misread yet", "VERBATIM" not in format_report(compute_stats([])))

    # ---- gate_run ga-q6bac0, low finding: a log that cannot be READ is not a log with no rows. read_jsonl() returns
    # [] for both, so an unreadable log printed "0 case(s)" and "Hook errors: none logged" -- the words of a quiet
    # day (three states: has rows / has none / could not be read). ----
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory() as td_r:
        td_p = Path(td_r)
        empty_log = td_p / "empty.jsonl"
        empty_log.write_text("")
        some_log = td_p / "some.jsonl"
        some_log.write_text('{"mode": "cut-output", "experiment": "cut-output-fixed", "entity_id": "z1", "tokens_would_save": 10}\n')
        not_a_file = td_p / "a-directory"
        not_a_file.mkdir()
        gone_log = td_p / "no-such-log.jsonl"
        ok("log_problem: a readable log is no problem", log_problem(some_log) is None)
        ok("log_problem: an EMPTY log is readable -- 'no rows' is a real answer, not a problem", log_problem(empty_log) is None)
        ok("log_problem: a log that does not exist is a problem (no data was read)", isinstance(log_problem(gone_log), str) and bool(log_problem(gone_log)))
        ok("log_problem: a path that cannot be opened for reading (a directory) is a problem", isinstance(log_problem(not_a_file), str) and bool(log_problem(not_a_file)))

        bad_stats = compute_stats([])
        bad_stats["log_problem"] = "PermissionError: Permission denied"
        bad_text = format_report(bad_stats)
        ok("format_report: an unreadable log says LOG NOT READ and why", "LOG NOT READ" in bad_text and "Permission denied" in bad_text)
        ok("format_report: an unreadable log does NOT print the quiet-day words ('0 case(s)', 'none logged')",
           "case(s)" not in bad_text and "none logged" not in bad_text and "no joined cases yet" not in bad_text)
        bad_pt = format_resumo_pt(bad_stats)
        ok("format_resumo_pt: an unreadable log says so, and prints no count that could pass for a real zero",
           "log não lido" in bad_pt and "Permission denied" in bad_pt and "0 caso(s)" not in bad_pt and "conferido" not in bad_pt)
        ok("format_report/format_resumo_pt: a stats dict with no log_problem key behaves as before (readable)",
           "LOG NOT READ" not in format_report(compute_stats([])) and "log não lido" not in format_resumo_pt(compute_stats([])))

        me = str(Path(__file__).resolve())
        run_bad = subprocess.run([sys.executable, me, "--log", str(not_a_file)], capture_output=True, text=True, timeout=60)
        ok("end to end: --log <unreadable path> prints LOG NOT READ (and still exits 0: the daily report is best-effort)",
           "LOG NOT READ" in run_bad.stdout and run_bad.returncode == 0)
        run_bad_pt = subprocess.run([sys.executable, me, "--resumo-pt", "--log", str(gone_log)], capture_output=True, text=True, timeout=60)
        ok("end to end: --resumo-pt on a missing log prints the Portuguese 'log não lido' line", "log não lido" in run_bad_pt.stdout)
        run_empty = subprocess.run([sys.executable, me, "--log", str(empty_log)], capture_output=True, text=True, timeout=60)
        ok("end to end (control): an empty but readable log is still an ordinary report, not LOG NOT READ",
           "LOG NOT READ" not in run_empty.stdout and "0 case(s)" in run_empty.stdout)

    print(f"\njev_cut_output_report selftest: PASS={passed} FAIL={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
