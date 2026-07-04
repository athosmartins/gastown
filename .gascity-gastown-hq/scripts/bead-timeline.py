#!/usr/bin/env python3
"""bead-timeline.py <bead-id> — forensic timeline for one bead. (ga-2026-07-04)

LEAN OTel-alternative. The scout's OpenObserve store has no macOS-arm64 binary
and this box is capacity-constrained (16GB, swap-heavy), so instead of an
always-on telemetry store we reconstruct "what happened to bead X" from durable
state we already have — the bead's lifecycle timestamps + current labels (Dolt
via `bd`), its LIVE gate marker/run beads, and the machine-health flow-ledger —
and print a chronological timeline + a diagnosis. Answers, in one command, the
thing we grep-by-hand today: "where is this bead, how long has it been there,
and was the machine (Dolt/disk) sick while it stalled?"

Low Dolt cost by design: a couple of `bd show`/`bd list` calls, NO
dolt_history_* table scan (that heavy per-commit scan is the v2 enhancement,
gated on a Dolt-load budget).

Usage:  python3 bead-timeline.py <bead-id> [--store <path>]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

STORES = [
    "/Users/athos/gt/.gascity-gastown-hq",
    "/Users/athos/gt/whatsapp_automation",
    "/Users/athos/gt/property_scrapers",
]
LEDGER = "/Users/athos/gt/.gascity-gastown-hq/.gc/logs/flow-ledger.jsonl"


def _bd(store: str, args: list[str]) -> object | None:
    try:
        out = subprocess.run(["bd", "-C", store, *args, "--json"],
                             capture_output=True, text=True, timeout=20)
        if out.returncode != 0 or not out.stdout.strip():
            return None
        return json.loads(out.stdout)
    except Exception:
        return None


def _one(v):
    return (v[0] if isinstance(v, list) and v else (None if isinstance(v, list) else v))


def parse_iso(s: str | None):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def now_utc():
    return datetime.now(timezone.utc)


def fmt_dur(td) -> str:
    if td is None:
        return "?"
    secs = int(td.total_seconds())
    sign = "-" if secs < 0 else ""
    secs = abs(secs)
    d, secs = divmod(secs, 86400)
    h, secs = divmod(secs, 3600)
    m, _ = divmod(secs, 60)
    parts = []
    if d:
        parts.append(f"{d}d")
    if h:
        parts.append(f"{h}h")
    parts.append(f"{m}m")
    return sign + " ".join(parts)


def find_bead(bead_id: str, store_override: str | None):
    stores = [store_override] if store_override else STORES
    for st in stores:
        b = _one(_bd(st, ["show", bead_id]))
        if isinstance(b, dict) and b.get("id"):
            return st, b
    return None, None


def gate_markers(store: str, bead_id: str) -> list[dict]:
    rows = _bd(store, ["list", "-l", f"source-bead:{bead_id}", "--all"])
    return rows if isinstance(rows, list) else []


def ledger_context(start, end) -> dict:
    """Summarize machine health during [start, end] from the flow-ledger."""
    if not os.path.exists(LEDGER):
        return {}
    halt = 0
    dolt_down = 0
    max_usage = 0
    n = 0
    try:
        with open(LEDGER) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                ts = parse_iso(e.get("ts"))
                if ts is None:
                    continue
                if start and ts < start:
                    continue
                if end and ts > end:
                    continue
                n += 1
                if e.get("halt_imminent") is True or e.get("event") == "halt-imminent":
                    halt += 1
                if e.get("dolt_reachable") is False:
                    dolt_down += 1
                try:
                    up = int(e.get("usage_pct") or 0)
                    max_usage = max(max_usage, up)
                except Exception:
                    pass
    except Exception:
        return {}
    return {"events": n, "halt_imminent": halt, "dolt_unreachable": dolt_down,
            "max_disk_pct": max_usage}


def gate_labels(b: dict) -> list[str]:
    return [l for l in (b.get("labels") or []) if l.startswith("gate")]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("bead_id")
    ap.add_argument("--store", default=None, help="force a specific store path")
    args = ap.parse_args(argv)

    store, b = find_bead(args.bead_id, args.store)
    if not b:
        print(f"bead {args.bead_id} not found in any store")
        return 1

    created = parse_iso(b.get("created_at"))
    started = parse_iso(b.get("started_at"))
    updated = parse_iso(b.get("updated_at"))
    closed = parse_iso(b.get("closed_at"))
    status = b.get("status")
    end = closed or now_utc()

    # ── build chronological events ──
    events = []  # (dt, label)
    if created:
        events.append((created, f"created  (status→open, type={b.get('issue_type','?')})"))
    if started and started != created:
        events.append((started, f"started  (in_progress, assignee={b.get('assignee') or '-'})"))
    for m in gate_markers(store, args.bead_id):
        mc = parse_iso(m.get("created_at"))
        gs = [l.split(":", 1)[1] for l in (m.get("labels") or []) if l.startswith("gate-status:")]
        br = next((l.split(":", 1)[1] for l in (m.get("labels") or []) if l.startswith("branch:")), "?")
        if mc:
            events.append((mc, f"gate marker {m['id']}  (branch {br}, gate-status:{','.join(gs) or '?'})"))
    if closed:
        events.append((closed, f"closed  ({b.get('close_reason') or status})"))
    events.sort(key=lambda x: x[0])

    # ── print ──
    print(f"━━━ BEAD TIMELINE: {b['id']}  [{os.path.basename(store)}] ━━━")
    print(f"  {b.get('title','')[:78]}")
    print(f"  status={status}  assignee={b.get('assignee') or '-'}  rig={b.get('rig') or '-'}")
    gl = gate_labels(b)
    if gl:
        print(f"  gate labels (now): {', '.join(gl)}")
    print(f"  total age: {fmt_dur((end - created) if created else None)}"
          f"  ({'closed' if closed else 'OPEN'})")
    print()
    prev = None
    for dt, label in events:
        gap = f"  (+{fmt_dur(dt - prev)})" if prev else ""
        print(f"  {dt.astimezone().strftime('%m-%d %H:%M')}  {label}{gap}")
        prev = dt

    # ── biggest gap = where it 'stalled' ──
    if len(events) >= 2:
        gaps = [(events[i + 1][0] - events[i][0], events[i], events[i + 1])
                for i in range(len(events) - 1)]
        biggest = max(gaps, key=lambda g: g[0])
        # also consider the gap from the last event to now (if open)
        if not closed and events:
            tail = end - events[-1][0]
            if tail > biggest[0]:
                print(f"\n  ⏱  LONGEST GAP: {fmt_dur(tail)} SINCE '{events[-1][1].split('  ')[0]}' → NOW (still open)")
            else:
                print(f"\n  ⏱  LONGEST GAP: {fmt_dur(biggest[0])} between "
                      f"'{biggest[1][1].split('  ')[0]}' and '{biggest[2][1].split('  ')[0]}'")
        else:
            print(f"\n  ⏱  LONGEST GAP: {fmt_dur(biggest[0])} between "
                  f"'{biggest[1][1].split('  ')[0]}' and '{biggest[2][1].split('  ')[0]}'")

    # ── machine context during the bead's window ──
    ctx = ledger_context(created, end)
    if ctx:
        flags = []
        if ctx.get("halt_imminent"):
            flags.append(f"disk-HALT×{ctx['halt_imminent']}")
        if ctx.get("dolt_unreachable"):
            flags.append(f"Dolt-unreachable×{ctx['dolt_unreachable']}")
        if ctx.get("max_disk_pct", 0) >= 90:
            flags.append(f"disk-peak {ctx['max_disk_pct']}%")
        verdict = ("⚠ machine was SICK during this window: " + ", ".join(flags)) if flags \
            else "✓ machine healthy during this window (no disk/Dolt alarms)"
        print(f"\n  MACHINE CONTEXT ({ctx.get('events',0)} health samples): {verdict}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
