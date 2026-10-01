#!/usr/bin/env python3
"""e2-readout.py - ga-5c3msy: E2 read-out feasibility (read-only; run: python3 e2-readout.py). E2 = crews effort medium->high from 2026-09-30T00:00Z (29/09 21:00 -03);
metric = 1st-round gate pass-rate of crew branches built by post-E2 sessions, vs a 37% baseline.
Two questions: (1) did post-E2 crew messages actually run at `high`?  (2) how many NAMED-crew branches could even enter the sample?
Gate log is read raw (jq-equivalent) so the answer does not depend on the ledger's `branches` field, which does not capture crew-built branches."""
import json, collections, os
from pathlib import Path

CITY = Path(os.environ.get("GC_CITY_PATH") or "/Users/athos/gt/.gascity-gastown-hq")
LEDGER = CITY / ".gc/token-ledger/sessions.jsonl"
GATE = CITY / ".gc/quality-gate.jsonl"
E2_START = "2026-09-30T00:00:00"          # ISO strings compare lexicographically
E2_DAY = "2026-09-30"
NAMED = {"peter", "batista", "oracle", "mila", "thies", "digo"}   # crew/<name>/<bead>; crew/wa-worker|ps-worker are pool builders

# ---- (1) effort mix of crew messages on/after the E2 start (by message day, as the meter sums it)
eff = collections.Counter(); per_alias = collections.defaultdict(collections.Counter); nsess = collections.Counter()
for line in LEDGER.read_text().splitlines():
    try:
        s = json.loads(line)
    except Exception:
        continue
    if s.get("role") != "crew" or (s.get("first_ts") or "") < E2_START:
        continue                              # only sessions STARTED after the change: an older long-running one still carries the old effort
    touched = False
    for day, keys in (s.get("days") or {}).items():
        if day < E2_DAY:
            continue
        for key, c in keys.items():
            model, _, effort = key.partition("|")
            if not model.startswith("claude-opus"):
                continue                     # the haiku title/summary calls are not the crew's working effort
            eff[effort or "?"] += c.get("msgs", 0)
            per_alias[s["alias"]][effort or "?"] += c.get("msgs", 0)
            touched = True
    if touched:
        nsess[s["alias"]] += 1
tot = sum(eff.values())
print(f"(1) Opus crew messages in sessions STARTED on/after {E2_START}Z: {tot}")
for e, n in eff.most_common():
    print(f"    effort={e:<7} {n:>6}  {n / tot:6.1%}")
print("    by crew (sessions touching the window; msgs by effort):")
for a in sorted(per_alias):
    t = sum(per_alias[a].values())
    mix = ", ".join(f"{e}={n} ({n / t:.0%})" for e, n in per_alias[a].most_common())
    print(f"      {a:<10} sessions={nsess[a]}  msgs={t:<5} {mix}")
print(f"    crew-members with ZERO sessions in the window: {sorted(a for a in ('batista-wa','digo-wa','mila-wa','oracle-wa','peter-wa','thies-wa') if a not in per_alias)}")

# ---- (2) ceiling on the branch sample, straight from the gate log
first_event, first_verdict, bad, no_dry = {}, {}, 0, 0
for line in GATE.read_text(errors="replace").splitlines():
    try:
        r = json.loads(line)
    except Exception:
        bad += 1
        continue
    b = r.get("branch") or ""
    if not b.startswith("crew/") or not r.get("ts"):
        continue
    first_event.setdefault(b, r["ts"])
    if r.get("event") == "dispatcher_complete" and r.get("result") in ("PASS", "FAIL"):
        if r.get("dry_run") is None:
            no_dry += 1       # field absent (or null): real run or rehearsal is UNKNOWN - not a real verdict, and not dropped silently either
        elif str(r.get("dry_run")) in ("0", "false", "False", ""):
            first_verdict.setdefault(b, (r["ts"], r["result"]))
print(f"\n(2) gate log: {len(first_event)} crew/* branches ever seen, {bad} unreadable lines (ignored, counted), "
      f"{no_dry} verdicts without dry_run (real run or rehearsal UNKNOWN: kept out of the sample, counted)")
rows = []
for b, ts in first_event.items():
    who = b.split("/")[1]
    if who in NAMED and ts >= E2_START and b in first_verdict:
        rows.append((who, b, first_verdict[b]))
by = collections.defaultdict(lambda: [0, 0])
for who, b, (ts, res) in rows:
    by[who][0] += 1
    by[who][1] += res == "PASS"
n = sum(v[0] for v in by.values()); p = sum(v[1] for v in by.values())
print(f"    NAMED-crew branches first seen by the gate on/after the E2 start AND with a real verdict: {n}  (1st-round PASS {p})")
for who in sorted(by):
    print(f"      {who:<8} n={by[who][0]:<3} pass={by[who][1]}")
if n:
    z = 1.96; q = p / n; den = 1 + z * z / n
    c = (q + z * z / (2 * n)) / den
    h = z * ((q * (1 - q) / n + z * z / (4 * n * n)) ** 0.5) / den
    print(f"    1st-round pass {q:.0%}, Wilson 95% CI {max(0, c - h):.0%}-{min(1, c + h):.0%}")
    # power to see a +10pp lift over a 37% baseline at this n (two-proportion, alpha 5%, 80% power, equal arms) needs ~n_req per arm
    p1, p2 = 0.37, 0.47
    n_req = ((1.96 + 0.84) ** 2 * (p1 * (1 - p1) + p2 * (1 - p2))) / ((p2 - p1) ** 2)
    print(f"    for scale: detecting 37% -> 47% needs ~{n_req:.0f} branches per arm; this sample is {n} and is NOT split by the effort each branch's builder ran at")
