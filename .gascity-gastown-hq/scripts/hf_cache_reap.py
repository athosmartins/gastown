#!/usr/bin/env python3
"""hf_cache_reap.py (wa-9eh0v) — fourth reclaim lever for dolt-disk-floor-guard.sh.

WHY: the 2026-09-04 double Dolt outage (12h apart, both ENOSPC) showed the
guard's three existing reclaim levers (`gc dolt-cleanup --force`,
scratchpad-reaper.sh, transcript-reaper.sh) can ALL report "0GB reclaimed" in
the same cycle — live evidence in dolt-disk-floor-guard.log at 07:31:23 that
day: "reclaimed=0GB avail_before=2GB". They had already run their course.
The lever that actually recovered the disk both times was a human manually
clearing ~/.cache/huggingface (the `recall` CLI's sentence-transformers
model cache — see recall_lib.py) via huggingface_hub's own
scan_cache_dir()/delete_revisions() API, already authorized by Athos for
this specific cache in the prior (2026-07-14, ga-vs55) incident. This
automates that exact, already-proven action instead of waiting on a human to
notice, diagnose, and intervene by hand a third time.

SAFE BY DESIGN: recall_lib.py's load_model() already treats a missing/empty
cache as an expected, self-healing condition (wa-h9dc1 bootstrap: cache-miss
-> one ~180s-bounded online download -> retry). Wiping this cache costs one
slow `recall` call next time it's used, not a hard failure — a deliberately
cheap price against a city-wide Dolt outage.

PROD sentinel (mirrors SCRATCHPAD_REAPER_PROD / TRANSCRIPT_REAPER_PROD in
dolt-disk-floor-guard.sh — ga-h565g / ga-lfj05): without
HF_CACHE_REAP_PROD=1 this DRY-RUNS — scans and reports what it would free,
deletes nothing. The guard's own _reap_hf_cache() is the only caller that
should ever set it to "1".

CLI contract: exit 0 on success (including "nothing to reclaim" and
dry-run), nonzero only on a real error (wrong interpreter, scan failure).
Optional first arg overrides the cache dir scanned (used by the selftest;
production always omits it and gets huggingface_hub's own default
resolution, i.e. HF_HOME / ~/.cache/huggingface/hub).
"""
import sys


def main(argv: list[str]) -> int:
    import os
    from pathlib import Path

    cache_dir = argv[1] if len(argv) > 1 else None
    prod = os.environ.get("HF_CACHE_REAP_PROD") == "1"

    try:
        from huggingface_hub import scan_cache_dir
    except ImportError as exc:
        print(f"HF_CACHE_REAP: ERROR huggingface_hub not importable ({exc}) — wrong interpreter?", file=sys.stderr)
        return 1

    # scan_cache_dir() RAISES on a cache_dir that does not exist at all yet
    # (distinct from "exists but empty", which it handles fine and reports
    # as repos=0) — a brand-new machine where nothing has ever populated the
    # cache is a legitimate "nothing to reclaim", not an error, so check
    # existence up front rather than let a routine first-run state read as a
    # scan failure.
    resolved_dir = cache_dir
    if resolved_dir is None:
        from huggingface_hub.constants import HF_HUB_CACHE
        resolved_dir = HF_HUB_CACHE
    if not Path(resolved_dir).exists():
        print(f"HF_CACHE_REAP: nothing to reclaim (cache dir does not exist yet: {resolved_dir})")
        return 0

    try:
        info = scan_cache_dir(cache_dir=cache_dir)
    except Exception as exc:  # anything else (corrupt cache, permissions) must not crash the guard cycle
        print(f"HF_CACHE_REAP: ERROR scan_cache_dir failed ({exc})", file=sys.stderr)
        return 1

    # A partial/degraded scan (e.g. one corrupt repo dir among many) does not
    # raise — it surfaces as non-empty info.warnings while info.repos still
    # reports whatever it COULD read. Log it rather than silently proceeding
    # as if the scan were clean; this never blocks the reclaim itself.
    for warning in info.warnings:
        print(f"HF_CACHE_REAP: WARNING during scan: {warning}", file=sys.stderr)

    revisions = [rev.commit_hash for repo in info.repos for rev in repo.revisions]
    if not revisions:
        print(f"HF_CACHE_REAP: nothing to reclaim (repos=0 size_on_disk={info.size_on_disk})")
        return 0

    strategy = info.delete_revisions(*revisions)
    expected = strategy.expected_freed_size

    if not prod:
        print(
            f"HF_CACHE_REAP: DRY-RUN would free {expected} bytes across "
            f"{len(info.repos)} repo(s)/{len(revisions)} revision(s) "
            f"(set HF_CACHE_REAP_PROD=1 to actually delete)"
        )
        return 0

    strategy.execute()
    print(
        f"HF_CACHE_REAP: reclaimed {expected} bytes across "
        f"{len(info.repos)} repo(s)/{len(revisions)} revision(s)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
