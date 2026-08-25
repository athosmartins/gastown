#!/usr/bin/env python3
"""recall.py — CLI entrypoint (ga-ps28g). See recall_lib.py for the "why".

Usage:
    recall "has the gate two-branch race for the same bead been fixed?"
    recall --json "what broke last time with tick_unconfirmed"
    recall --rebuild "force a full index rebuild"

Prints the ~5 most relevant CLOSED beads (HQ + WA, telemetry-filtered):
id, title, close_reason, and the 1-2 most relevant comments. Use this
INSTEAD of `bd list --status closed` + several full `bd show` reads when
checking "has this been done? / what broke last time?".

Run directly via the venv (no bare `python3 recall.py` on system python —
sentence-transformers/tiktoken live only in $GC_CITY_PATH/.gc/recall-venv):

    $GC_CITY_PATH/.gc/recall-venv/bin/python3 recall.py "<query>"

or via the `recall` wrapper on PATH, which does that for you.

Exit codes — do not conflate these (wa-h9dc1): 0 = ran fine, including the
legitimate "No matching closed beads found." outcome; 2 = CLI usage error
(argparse, e.g. empty query); 3 = could NOT search at all (e.g. embedding
model unavailable) — callers must treat this differently from "0 results".
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import recall_lib as rl  # noqa: E402


def _short(text: str, n: int) -> str:
    text = (text or "").strip()
    return text if len(text) <= n else text[: n - 1].rstrip() + "…"


def format_result(rank: int, r: dict) -> str:
    b = r["bead"]
    via = "+".join(r.get("via", []))
    lines = [f"[{rank}] {b['id']}  ({b.get('store', '?')}/{via})  {b.get('title', '')}"]
    cr = _short(b.get("close_reason", ""), 280)
    if cr:
        lines.append(f"    closed: {cr}")
    for ct in r.get("top_comments", []):
        lines.append(f"    comment: {_short(ct.replace(chr(10), ' '), 240)}")
    return "\n".join(lines)


def ensure_index(force_rebuild: bool, verbose_progress) -> "rl.RecallIndex":
    idx = rl.load_index(progress=verbose_progress)
    if idx is None:
        verbose_progress("recall: no index yet — building the initial index (first run, ~1min)...")
        idx = rl.build_full_index(progress=verbose_progress)
        rl.save_index(idx)
        return idx
    idx, changed = rl.update_index_if_stale(idx, force=force_rebuild, progress=verbose_progress)
    return idx


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="recall",
        description="Hybrid semantic+lexical recall over CLOSED Gas City beads "
                     "(HQ+WA). Use instead of bd-list+read for 'has this been "
                     "done? / what broke last time?' questions.",
    )
    parser.add_argument("query", nargs="+", help="natural-language question")
    parser.add_argument("--json", action="store_true", help="machine-readable JSON output")
    parser.add_argument("--rebuild", action="store_true", help="force a full index refresh check now")
    parser.add_argument("-k", type=int, default=3, help="top-k per retrieval arm before union+dedup (default 3)")
    parser.add_argument("-q", "--quiet", action="store_true", help="suppress progress/status lines on stderr")
    args = parser.parse_args(argv)
    query = " ".join(args.query).strip()
    if not query:
        parser.error("empty query")

    def progress(msg: str):
        if not args.quiet:
            print(msg, file=sys.stderr)

    t0 = time.time()
    try:
        idx = ensure_index(args.rebuild, progress)
        model = rl.load_model()
        results = rl.hybrid_retrieve(query, idx, model=model, k=args.k)
        for r in results:
            r["top_comments"] = rl.top_comments(r["bead"], query, model=model, n=2)
    except rl.RecallModelUnavailableError as e:
        # Distinct from "ran fine, 0 results" (exit 0) and from argparse's
        # usage-error convention (exit 2) — callers must not read this as
        # "no matching beads" (wa-h9dc1).
        print(f"recall: unavailable — could not search: {e}", file=sys.stderr)
        return 3

    elapsed = time.time() - t0
    rl.log_usage(query, results, idx, elapsed)

    if args.json:
        out = [{
            "id": r["bead"]["id"],
            "store": r["bead"]["store"],
            "title": r["bead"]["title"],
            "close_reason": r["bead"]["close_reason"],
            "closed_at": r["bead"]["closed_at"],
            "via": r["via"],
            "semantic_score": r["semantic_score"],
            "top_comments": r["top_comments"],
        } for r in results]
        print(json.dumps(out, indent=2))
    else:
        if not results:
            print("No matching closed beads found.")
        else:
            for rank, r in enumerate(results, 1):
                print(format_result(rank, r))
        progress(f"\n({len(results)} beads, {elapsed:.2f}s, index={idx.meta.get('n_beads')} beads)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
