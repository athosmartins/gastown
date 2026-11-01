#!/usr/bin/env python3
"""ga-86aie91: where does one gate ADMISSION ROUND spend its time? Read-only, from the dispatcher log.

    python3 -I segments.py <quality-gate-dispatcher.log> [--since "YYYY-MM-DD HH:MM:SS"] [--rounds] [--hourly]

A round = one "=== Dispatcher sweep start" up to the next one (a multi-admit re-exec under the same lock) or the end of the log.
Only rounds that ADMITTED (they have a "Gate-run bead:" and a "Verdicts requested" line) are measured. Landmarks, all log lines:

    T0   "=== Dispatcher sweep start"
    FND  first "Found N queued marker(s)"        T0->FND  = Phase C + janitors + mid-sweep (the pre-admission part)
    HR   first "Headroom OK"                      FND->HR  = headroom / pool-ceiling probe
    GRB  "Gate-run bead: <id>"                    HR->GRB  = pick, claim, fetch, rebase, size, lane
    SPN  "All N reviewer sessions spawned"        GRB->SPN = verdict bead, reviewer spawn, task delivery
    VRQ  "Verdicts requested"                     SPN->VRQ = Step 7b, the ACK wait (what ga-86aie91 removes when it can)
    gap  next round's T0 - this round's VRQ       ~1 s when the burst continues; ~61 s when it ended (launchd StartInterval=60)

--hourly also prints admissions per hour ("Gate-run bead:" lines per local hour) and the share of rounds that finalized a run.
vazio (no round admitted) -> prints "rounds that admitted: 0" and nothing else; falhou/ilegivel (a line whose timestamp cannot be parsed) -> that
line is skipped and COUNTED in "unparsable lines", never turned into a zero.
"""
import datetime
import re
import statistics
import sys

TS = re.compile(r"^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] \[quality-gate-dispatcher\] (.*)")
LANDMARKS = (
    ("T0", re.compile(r"^=== Dispatcher sweep start")),
    ("FND", re.compile(r"^Found \d+ queued marker")),
    ("HR", re.compile(r"^Headroom OK")),
    ("GRB", re.compile(r"^Gate-run bead: ")),
    ("SPN", re.compile(r"^All \d+ reviewer sessions spawned")),
    ("VRQ", re.compile(r"^Verdicts requested")),
)
FINALIZING = re.compile(r"^Phase C: gate-run \S+ .*complete .*Finalizing")


def epoch(stamp):
    return datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S").timestamp()


def read_rounds(path, since):
    rounds, cur, bad = [], None, 0
    with open(path, errors="replace") as fh:
        for line in fh:
            m = TS.match(line)
            if not m:
                continue
            stamp, msg = m.groups()
            if stamp < since:
                continue
            try:
                t = epoch(stamp)
            except ValueError:
                bad += 1
                continue
            if LANDMARKS[0][1].match(msg):
                if cur is not None:
                    cur["next_T0"] = t
                    rounds.append(cur)
                cur = {"T0": t, "stamp": stamp, "finalized": 0}
                continue
            if cur is None:
                continue
            if FINALIZING.match(msg):
                cur["finalized"] += 1
                continue
            for name, rx in LANDMARKS[1:]:
                if rx.match(msg):
                    if name == "VRQ" or name not in cur:  # VRQ: the last one of the round; the others: the first
                        cur[name] = t
                    break
    if cur is not None:
        rounds.append(cur)
    return rounds, bad


def seg(r, a, b):
    return r[b] - r[a] if a in r and b in r else None


def summarize(values):
    v = sorted(x for x in values if x is not None)
    if not v:
        return "n=0"
    p90 = v[max(0, int(len(v) * 0.9) - 1)]
    return "n=%d median=%.0f mean=%.0f p90=%.0f max=%.0f" % (len(v), statistics.median(v), statistics.mean(v), p90, v[-1])


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    path, since = argv[1], "0000"
    if "--since" in argv:
        since = argv[argv.index("--since") + 1]
    rounds, bad = read_rounds(path, since)
    adm = [r for r in rounds if "GRB" in r and "VRQ" in r and "FND" in r]
    print("rounds that admitted: %d   unparsable lines: %d   since: %s" % (len(adm), bad, since))
    if not adm:
        return 0
    rows = []
    for r in adm:
        rows.append({
            "pre (T0->Found)":     seg(r, "T0", "FND"),
            "headroom":            seg(r, "FND", "HR"),
            "pick..gate-run":      seg(r, "HR", "GRB"),
            "spawn":               seg(r, "GRB", "SPN"),
            "ACK wait (7b)":       seg(r, "SPN", "VRQ"),
            "ROUND (T0->VRQ)":     seg(r, "T0", "VRQ"),
            "gap to next sweep":   (r["next_T0"] - r["VRQ"]) if "next_T0" in r else None,
        })
    for k in rows[0]:
        print("  %-18s %s" % (k, summarize([x[k] for x in rows])))
    tot = [x["ROUND (T0->VRQ)"] for x in rows if x["ROUND (T0->VRQ)"] is not None]
    gaps = [x["gap to next sweep"] for x in rows if x["gap to next sweep"] is not None]
    if tot and gaps:
        per = statistics.mean(tot) + statistics.mean(gaps)
        print("  admissions/h implied by the mean round + mean gap: %.1f  (%.0f s per admission)" % (3600.0 / per, per))
    print("  rounds that finalized >= 1 run: %d/%d" % (sum(1 for r in adm if r["finalized"]), len(adm)))
    if "--rounds" in argv:
        for r in adm[-30:]:
            print("   ", r["stamp"], {k: (None if v is None else int(v)) for k, v in zip(rows[0].keys(), [seg(r, "T0", "FND"), seg(r, "FND", "HR"), seg(r, "HR", "GRB"), seg(r, "GRB", "SPN"), seg(r, "SPN", "VRQ"), seg(r, "T0", "VRQ"), (r["next_T0"] - r["VRQ"]) if "next_T0" in r else None])})
    if "--hourly" in argv:
        per_hour = {}
        with open(path, errors="replace") as fh:
            for line in fh:
                m = TS.match(line)
                if m and m.group(1) >= since and m.group(2).startswith("Gate-run bead: "):
                    per_hour[m.group(1)[:13]] = per_hour.get(m.group(1)[:13], 0) + 1
        print("  admissions per local hour (Gate-run bead lines):")
        for h in sorted(per_hour):
            print("    %sh  %d" % (h, per_hour[h]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
