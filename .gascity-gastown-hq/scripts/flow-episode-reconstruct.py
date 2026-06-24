#!/usr/bin/env python3
"""flow-episode-reconstruct.py — stall-episode reconstruction from flow-ledger.jsonl (imp04).

Reads ONLY the flat ledger file (zero Dolt calls, zero bd calls).
Detects stall episodes by tracking when per-stage snapshot values
(dispatched, merged, refined, backlog) drop to zero consecutively,
and correlating with bead_transition events when present.

Episode schema:
  {
    "episode_id":   str,            # stable ID: "ep-<stage>-<start_epoch_sec>"
    "stage":        str,            # one of VALID_STAGES
    "start_ts":     str,            # ISO8601Z of first stall observation
    "end_ts":       str | null,     # ISO8601Z when resolved; null if still_open
    "duration_sec": int | null,     # end-start in seconds; null if still_open
    "resolution":   str             # one of VALID_RESOLUTIONS
  }

stage values:
  tria, refina, aprova, executa, revisa, delivery,
  crew-liveness, dolt, disk, quota

resolution values:
  auto_resolved, human_product, human_technical, agent_healed,
  still_open, external

Usage:
  flow-episode-reconstruct.py [--ledger <path>] [--open-only] [--json]
  flow-episode-reconstruct.py --selftest

Output:
  Human-readable table (default) or JSON array (--json).
  --open-only: emit only unresolved episodes.
"""

from __future__ import annotations

import json
import sys
import os
import argparse
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# ── constants ─────────────────────────────────────────────────────────────────
VALID_STAGES = frozenset({
    "tria", "refina", "aprova", "executa", "revisa", "delivery",
    "crew-liveness", "dolt", "disk", "quota",
})

VALID_RESOLUTIONS = frozenset({
    "auto_resolved", "human_product", "human_technical",
    "agent_healed", "still_open", "external",
})

DEFAULT_LEDGER = os.path.join(
    os.environ.get("GC_LEDGER_DIR",
                   "/Users/athos/gt/.gascity-gastown-hq/.gc/logs"),
    "flow-ledger.jsonl",
)

# A stage is "stalled" when its flow metric drops to zero for this many
# consecutive interval_snapshot entries. This prevents single-sweep gaps from
# creating spurious episodes.
STALL_CONFIRM_SWEEPS: int = int(os.environ.get("FER_STALL_CONFIRM_SWEEPS", "2"))

# Map from snapshot field → stage name
SNAPSHOT_STAGE_MAP = {
    "dispatched": "executa",    # dispatch=0 → execution stall
    "merged":     "delivery",   # merged=0   → delivery stall
    "refined":    "refina",     # refined=0  → refino stall
}


# ── data types ────────────────────────────────────────────────────────────────
def _parse_ts(ts_str: str) -> Optional[datetime]:
    """Parse ISO8601Z timestamp, return None on failure."""
    try:
        return datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def _epoch(dt: datetime) -> int:
    return int(dt.timestamp())


def _episode_id(stage: str, start_ts: str) -> str:
    """Generate stable episode ID from stage + start timestamp."""
    dt = _parse_ts(start_ts)
    epoch_sec = _epoch(dt) if dt else 0
    return f"ep-{stage}-{epoch_sec}"


# ── ledger reader ─────────────────────────────────────────────────────────────
def read_ledger(ledger_path: str) -> list[dict]:
    """Read and parse ledger lines. Returns list of dicts (invalid lines skipped)."""
    records: list[dict] = []
    try:
        with open(ledger_path, "r", encoding="utf-8") as fh:
            for lineno, raw in enumerate(fh, 1):
                line = raw.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                    if isinstance(rec, dict):
                        records.append(rec)
                except json.JSONDecodeError:
                    # Skip malformed lines — fail-open
                    continue
    except FileNotFoundError:
        # Ledger doesn't exist yet — return empty (not an error)
        return []
    except OSError as exc:
        print(f"[flow-episode-reconstruct] WARN: cannot read ledger: {exc}", file=sys.stderr)
        return []
    return records


# ── episode reconstruction ────────────────────────────────────────────────────
def reconstruct_episodes(records: list[dict]) -> list[dict]:
    """Reconstruct stall episodes from flat ledger records.

    Algorithm:
    1. Process interval_snapshot records chronologically.
    2. For each stage metric (dispatched, merged, refined), track a run of
       consecutive zero-flow snapshots (when backlog>0 to confirm real demand).
    3. After STALL_CONFIRM_SWEEPS consecutive zeros with backlog>0, open an episode.
    4. When the metric becomes non-zero again, close the episode as auto_resolved.
    5. bead_transition records that carry stage/resolution fields can close episodes
       with a specific resolution.
    6. Episodes still open at end of ledger → resolution=still_open.

    Returns a list of episode dicts sorted by start_ts descending (newest first).
    """
    # Per-stage state: consecutive zero count, episode start ts, episode start idx
    # Use dicts initialized before use (define-before-use discipline)
    zero_run: dict[str, int] = {s: 0 for s in SNAPSHOT_STAGE_MAP.values()}
    episode_start_ts: dict[str, Optional[str]] = {s: None for s in SNAPSHOT_STAGE_MAP.values()}
    open_episodes: dict[str, dict] = {}  # stage → current open episode
    closed_episodes: list[dict] = []

    def _open_episode(stage: str, start_ts: str) -> dict:
        eid = _episode_id(stage, start_ts)
        ep = {
            "episode_id":   eid,
            "stage":        stage,
            "start_ts":     start_ts,
            "end_ts":       None,
            "duration_sec": None,
            "resolution":   "still_open",
        }
        open_episodes[stage] = ep
        return ep

    def _close_episode(stage: str, end_ts: str, resolution: str) -> None:
        ep = open_episodes.pop(stage, None)
        if ep is None:
            return
        start_dt = _parse_ts(ep["start_ts"])
        end_dt = _parse_ts(end_ts)
        dur = (
            int((end_dt - start_dt).total_seconds())
            if start_dt and end_dt
            else None
        )
        ep["end_ts"] = end_ts
        ep["duration_sec"] = dur
        ep["resolution"] = resolution
        closed_episodes.append(ep)

    # Sort by ts ascending
    def _ts_key(rec: dict) -> str:
        return rec.get("ts", "")

    sorted_records = sorted(records, key=_ts_key)

    for rec in sorted_records:
        kind = rec.get("kind", "")
        ts = rec.get("ts", "")

        if kind == "interval_snapshot":
            backlog = rec.get("backlog", 0)
            has_demand = (backlog or 0) > 0

            for field, stage in SNAPSHOT_STAGE_MAP.items():
                val = rec.get(field, 0) or 0

                if val == 0 and has_demand:
                    # Zero-flow with demand — increment run
                    zero_run[stage] += 1
                    if episode_start_ts[stage] is None:
                        episode_start_ts[stage] = ts

                    if (
                        zero_run[stage] >= STALL_CONFIRM_SWEEPS
                        and stage not in open_episodes
                    ):
                        _open_episode(stage, episode_start_ts[stage] or ts)
                else:
                    # Flow resumed (or no demand) — close any open episode
                    if stage in open_episodes:
                        _close_episode(stage, ts, "auto_resolved")
                    zero_run[stage] = 0
                    episode_start_ts[stage] = None

        elif kind == "bead_transition":
            # bead_transition can carry an explicit resolution to close an episode
            stage = rec.get("stage", "")
            resolution = rec.get("resolution", "")
            if stage in open_episodes and resolution in VALID_RESOLUTIONS and resolution != "still_open":
                _close_episode(stage, ts, resolution)

    # Remaining open episodes → still_open
    for stage, ep in list(open_episodes.items()):
        closed_episodes.append(ep)

    # Sort newest first
    closed_episodes.sort(key=lambda e: e.get("start_ts", ""), reverse=True)
    return closed_episodes


# ── output formatting ─────────────────────────────────────────────────────────
def _format_duration(sec: Optional[int]) -> str:
    if sec is None:
        return "open"
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h{m:02d}m"
    if m:
        return f"{m}m{s:02d}s"
    return f"{s}s"


def print_table(episodes: list[dict]) -> None:
    if not episodes:
        print("No stall episodes found.")
        return
    print(f"{'EPISODE_ID':<32}  {'STAGE':<16}  {'START':>20}  {'DURATION':>10}  {'RESOLUTION'}")
    print("-" * 100)
    for ep in episodes:
        print(
            f"{ep['episode_id']:<32}  "
            f"{ep['stage']:<16}  "
            f"{ep['start_ts']:>20}  "
            f"{_format_duration(ep['duration_sec']):>10}  "
            f"{ep['resolution']}"
        )


# ── selftest ──────────────────────────────────────────────────────────────────
def selftest() -> int:
    import tempfile

    global STALL_CONFIRM_SWEEPS

    PASS = 0
    FAIL = 0

    def ok(msg: str) -> None:
        nonlocal PASS
        PASS += 1
        print(f"  PASS: {msg}")

    def bad(msg: str) -> None:
        nonlocal FAIL
        FAIL += 1
        print(f"  FAIL: {msg}")

    print("=== flow-episode-reconstruct.py --selftest ===")

    STALL_CONFIRM_SWEEPS = 2  # use 2 for tests

    with tempfile.TemporaryDirectory() as tmp:
        ledger_file = os.path.join(tmp, "flow-ledger.jsonl")

        def write_lines(lines: list[dict]) -> None:
            with open(ledger_file, "a") as f:
                for d in lines:
                    f.write(json.dumps(d) + "\n")

        def clear_ledger() -> None:
            Path(ledger_file).write_text("")

        # T1: empty ledger → no episodes
        clear_ledger()
        recs = read_ledger(ledger_file)
        eps = reconstruct_episodes(recs)
        if len(eps) == 0:
            ok("T1: empty ledger → no episodes")
        else:
            bad(f"T1: expected 0 episodes, got {len(eps)}")

        # T2: dispatched=0 for STALL_CONFIRM_SWEEPS with backlog>0 → open episode
        clear_ledger()
        write_lines([
            {"ts": "2026-06-23T10:00:00Z", "kind": "interval_snapshot",
             "dispatched": 0, "merged": 1, "refined": 1, "backlog": 3},
            {"ts": "2026-06-23T10:05:00Z", "kind": "interval_snapshot",
             "dispatched": 0, "merged": 1, "refined": 1, "backlog": 3},
        ])
        recs = read_ledger(ledger_file)
        eps = reconstruct_episodes(recs)
        executa_eps = [e for e in eps if e["stage"] == "executa"]
        if len(executa_eps) == 1 and executa_eps[0]["resolution"] == "still_open":
            ok("T2: 2 zero-dispatch sweeps with backlog → still_open executa episode")
        else:
            bad(f"T2: expected 1 still_open executa episode, got {executa_eps}")

        # T3: episode closes auto_resolved when dispatch resumes
        clear_ledger()
        write_lines([
            {"ts": "2026-06-23T10:00:00Z", "kind": "interval_snapshot",
             "dispatched": 0, "merged": 1, "refined": 1, "backlog": 2},
            {"ts": "2026-06-23T10:05:00Z", "kind": "interval_snapshot",
             "dispatched": 0, "merged": 1, "refined": 1, "backlog": 2},
            {"ts": "2026-06-23T10:10:00Z", "kind": "interval_snapshot",
             "dispatched": 3, "merged": 1, "refined": 1, "backlog": 2},
        ])
        recs = read_ledger(ledger_file)
        eps = reconstruct_episodes(recs)
        executa_eps = [e for e in eps if e["stage"] == "executa"]
        if (
            len(executa_eps) == 1
            and executa_eps[0]["resolution"] == "auto_resolved"
            and executa_eps[0]["duration_sec"] == 600  # 10:10 - 10:00 = 600s
        ):
            ok("T3: episode closes auto_resolved with correct duration_sec=600")
        else:
            bad(f"T3: unexpected executa episode: {executa_eps}")

        # T4: 1 zero sweep (below confirm threshold) → no episode
        STALL_CONFIRM_SWEEPS = 2
        clear_ledger()
        write_lines([
            {"ts": "2026-06-23T10:00:00Z", "kind": "interval_snapshot",
             "dispatched": 0, "merged": 1, "refined": 1, "backlog": 5},
            {"ts": "2026-06-23T10:05:00Z", "kind": "interval_snapshot",
             "dispatched": 2, "merged": 1, "refined": 1, "backlog": 5},
        ])
        recs = read_ledger(ledger_file)
        eps = reconstruct_episodes(recs)
        executa_eps = [e for e in eps if e["stage"] == "executa"]
        if len(executa_eps) == 0:
            ok("T4: 1 zero sweep < confirm threshold → no episode opened")
        else:
            bad(f"T4: expected 0 episodes below threshold, got {executa_eps}")

        # T5: backlog=0 with dispatched=0 → no episode (no demand)
        clear_ledger()
        write_lines([
            {"ts": "2026-06-23T10:00:00Z", "kind": "interval_snapshot",
             "dispatched": 0, "merged": 0, "refined": 0, "backlog": 0},
            {"ts": "2026-06-23T10:05:00Z", "kind": "interval_snapshot",
             "dispatched": 0, "merged": 0, "refined": 0, "backlog": 0},
        ])
        recs = read_ledger(ledger_file)
        eps = reconstruct_episodes(recs)
        if len(eps) == 0:
            ok("T5: zero backlog + zero flow → no episode (idle is not a stall)")
        else:
            bad(f"T5: expected 0 episodes on idle pipeline, got {eps}")

        # T6: bead_transition closes episode with human_technical resolution
        clear_ledger()
        write_lines([
            {"ts": "2026-06-23T10:00:00Z", "kind": "interval_snapshot",
             "dispatched": 0, "merged": 0, "refined": 1, "backlog": 4},
            {"ts": "2026-06-23T10:05:00Z", "kind": "interval_snapshot",
             "dispatched": 0, "merged": 0, "refined": 1, "backlog": 4},
            {"ts": "2026-06-23T10:07:00Z", "kind": "bead_transition",
             "bead_id": "ga-test1", "stage": "executa",
             "from_state": "in-flight", "to_state": "open",
             "actor": "mayor", "source_daemon": "funnel-flow-healer",
             "resolution": "human_technical"},
        ])
        recs = read_ledger(ledger_file)
        eps = reconstruct_episodes(recs)
        executa_eps = [e for e in eps if e["stage"] == "executa"]
        if (
            len(executa_eps) == 1
            and executa_eps[0]["resolution"] == "human_technical"
        ):
            ok("T6: bead_transition closes episode with human_technical resolution")
        else:
            bad(f"T6: unexpected: {executa_eps}")

        # T7: delivery episode (merged=0)
        clear_ledger()
        write_lines([
            {"ts": "2026-06-23T10:00:00Z", "kind": "interval_snapshot",
             "dispatched": 1, "merged": 0, "refined": 1, "backlog": 2},
            {"ts": "2026-06-23T10:05:00Z", "kind": "interval_snapshot",
             "dispatched": 1, "merged": 0, "refined": 1, "backlog": 2},
        ])
        recs = read_ledger(ledger_file)
        eps = reconstruct_episodes(recs)
        delivery_eps = [e for e in eps if e["stage"] == "delivery"]
        if len(delivery_eps) == 1 and delivery_eps[0]["resolution"] == "still_open":
            ok("T7: zero merged with backlog → still_open delivery episode")
        else:
            bad(f"T7: expected 1 still_open delivery episode, got {delivery_eps}")

        # T8: malformed lines skipped gracefully
        clear_ledger()
        with open(ledger_file, "a") as f:
            f.write("not json at all\n")
            f.write('{"ts":"2026-06-23T10:00:00Z","kind":"interval_snapshot",'
                    '"dispatched":1,"merged":1,"refined":1,"backlog":1}\n')
        recs = read_ledger(ledger_file)
        if len(recs) == 1 and recs[0].get("kind") == "interval_snapshot":
            ok("T8: malformed lines skipped, valid lines parsed")
        else:
            bad(f"T8: expected 1 valid record, got {recs}")

        # T9: episode schema has all required fields
        clear_ledger()
        write_lines([
            {"ts": "2026-06-23T10:00:00Z", "kind": "interval_snapshot",
             "dispatched": 0, "merged": 1, "refined": 1, "backlog": 1},
            {"ts": "2026-06-23T10:05:00Z", "kind": "interval_snapshot",
             "dispatched": 0, "merged": 1, "refined": 1, "backlog": 1},
        ])
        recs = read_ledger(ledger_file)
        eps = reconstruct_episodes(recs)
        if eps:
            ep = eps[0]
            required = {"episode_id", "stage", "start_ts", "end_ts", "duration_sec", "resolution"}
            missing = required - ep.keys()
            if not missing:
                ok("T9: episode has all required schema fields")
            else:
                bad(f"T9: episode missing fields: {missing}")
        else:
            bad("T9: no episodes to check schema")

        # T10: episode_id is stable (deterministic from stage+start_ts)
        clear_ledger()
        write_lines([
            {"ts": "2026-06-23T10:00:00Z", "kind": "interval_snapshot",
             "dispatched": 0, "merged": 1, "refined": 1, "backlog": 1},
            {"ts": "2026-06-23T10:05:00Z", "kind": "interval_snapshot",
             "dispatched": 0, "merged": 1, "refined": 1, "backlog": 1},
        ])
        recs = read_ledger(ledger_file)
        eps1 = reconstruct_episodes(recs)
        eps2 = reconstruct_episodes(recs)
        if eps1 and eps2 and eps1[0]["episode_id"] == eps2[0]["episode_id"]:
            ok(f"T10: episode_id is deterministic: {eps1[0]['episode_id']!r}")
        else:
            bad(f"T10: non-deterministic episode_id: {eps1} vs {eps2}")

    print(f"\n=== RESULT: PASS={PASS} FAIL={FAIL} ===")
    return 0 if FAIL == 0 else 1


# ── main ─────────────────────────────────────────────────────────────────────
def main() -> int:
    global STALL_CONFIRM_SWEEPS

    parser = argparse.ArgumentParser(
        description="Reconstruct stall episodes from flow-ledger.jsonl (zero Dolt calls)."
    )
    parser.add_argument("--ledger", default=DEFAULT_LEDGER,
                        help=f"Path to flow-ledger.jsonl (default: {DEFAULT_LEDGER})")
    parser.add_argument("--open-only", action="store_true",
                        help="Emit only unresolved (still_open) episodes")
    parser.add_argument("--json", action="store_true",
                        help="Output JSON array instead of human-readable table")
    parser.add_argument("--confirm-sweeps", type=int, default=STALL_CONFIRM_SWEEPS,
                        help=f"Consecutive zero-flow sweeps to open an episode (default: {STALL_CONFIRM_SWEEPS})")
    parser.add_argument("--selftest", action="store_true",
                        help="Run self-tests and exit")
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    STALL_CONFIRM_SWEEPS = args.confirm_sweeps

    records = read_ledger(args.ledger)
    episodes = reconstruct_episodes(records)

    if args.open_only:
        episodes = [e for e in episodes if e["resolution"] == "still_open"]

    if args.json:
        print(json.dumps(episodes, indent=2, ensure_ascii=False))
    else:
        print_table(episodes)

    return 0


if __name__ == "__main__":
    sys.exit(main())
