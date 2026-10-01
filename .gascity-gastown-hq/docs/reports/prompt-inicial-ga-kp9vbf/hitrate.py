import json, collections, datetime as dt, statistics as st

d = json.load(open("sessions.json"))
tok = json.load(open("role_tokens.json"))
POOL = ["dog", "wa-worker", "ps-worker", "gate-reviewer", "refino-gate-reviewer", "auto-refiner"]


def ts(x):
    return dt.datetime.fromisoformat(x["start"])


# regime filter: reviewers' current prompt only exists from 2026-09-30 on
def keep(x):
    if x["role"] in ("gate-reviewer", "refino-gate-reviewer"):
        return x["start"] >= "2026-09-30"
    return True


by = collections.defaultdict(list)
for x in d:
    if x["role"] in POOL and x["start"] and keep(x):
        by[x["role"]].append(x)

print("ARRIVAL GAPS between consecutive same-role session starts, and share that a 1h cache entry would still be alive")
print("(upper-bound-ish: the entry is refreshed by every later read; a session that starts <60 min after the previous one's start finds it warm)")
print(f"{'role':22s} {'n':>4s} {'span(h)':>8s} {'sess/day':>9s} {'gap med(min)':>13s} {'<=5min':>7s} {'<=60min':>8s}")
rows = {}
for r in POOL:
    v = sorted(by[r], key=ts)
    if len(v) < 2:
        # a role with < 2 sessions has no gap to measure: say so, and leave it OUT of hitrate.json (cost2/projection then fail loudly on it
        # instead of reading a made-up rate)
        print(f"{r:22s} {len(v):4d}  sem amostra (< 2 sessões: não há intervalo para medir)")
        continue
    gaps = [(ts(b) - ts(a)).total_seconds() / 60 for a, b in zip(v, v[1:])]
    span_h = (ts(v[-1]) - ts(v[0])).total_seconds() / 3600
    # count the first session after a long gap (>60min) as a cold start (miss)
    hit60 = sum(1 for g in gaps if g <= 60) / len(v)          # first session of the window is always a miss -> divide by n
    hit5 = sum(1 for g in gaps if g <= 5) / len(v)
    rows[r] = dict(n=len(v), span_h=span_h, per_day=len(v) / max(span_h, 1) * 24, gap_med=st.median(gaps), hit5=hit5, hit60=hit60)
    print(f"{r:22s} {len(v):4d} {span_h:8.1f} {rows[r]['per_day']:9.0f} {rows[r]['gap_med']:13.1f} {100*hit5:6.0f}% {100*hit60:7.0f}%")
json.dump(rows, open("hitrate.json", "w"), indent=1)
