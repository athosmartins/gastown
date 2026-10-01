import json, collections

d = json.load(open("sessions.json"))
cost = json.load(open("cost2.json"))
W = dict(input=1.0, cache_write=2.0, cache_read=0.1, output=5.0)
POOL = ["dog", "wa-worker", "ps-worker", "gate-reviewer", "refino-gate-reviewer", "auto-refiner"]


def keep(x):
    return x["start"] >= "2026-09-30" if x["role"] in ("gate-reviewer", "refino-gate-reviewer") else True


by = collections.defaultdict(list)
for x in d:
    if x["role"] in POOL and keep(x):
        by[x["role"]].append(x)

print("WHERE THE WTE GOES (share of each role's weighted tokens)")
print(f"{'role':22s} {'cache_read':>10s} {'cache_write':>11s} {'output':>8s}   | first-turn write {'':>0s} of cache_write")
tot = collections.Counter()
for r in POOL:
    v = by[r]
    c = collections.Counter()
    first_w = 0
    for x in v:
        for k in W:
            c[k] += W[k] * x["tok"][k]
        first_w += W["cache_write"] * (x["first_split"][1] + x["first_split"][0])
    s = sum(c.values())
    pd = cost["rows"][r]["per_day"] / len(v)      # scale session sums to per-day
    for k in W:
        tot[k] += c[k] * pd
    print(f"{r:22s} {100*c['cache_read']/s:9.0f}% {100*c['cache_write']/s:10.0f}% {100*c['output']/s:7.0f}%   | first-turn write = {100*first_w/max(1,c['cache_write']):.0f}% of cache_write")
T = sum(tot.values())
print(f"\nPOOL TOTAL/day {T:,.0f} WTE: cache_read {100*tot['cache_read']/T:.0f}%  cache_write {100*tot['cache_write']/T:.0f}%  output {100*tot['output']/T:.0f}%  input {100*tot['input']/T:.1f}%")
dshare = sum((cost['rows'][r]['d_first'] + cost['rows'][r]['d_reread']) * cost['rows'][r]['per_day'] for r in POOL)
print(f"Entire doctrine (all 6 roles): {dshare:,.0f} WTE/day = {100*dshare/cost['total']:.1f}% of pool")
# non-doctrine fixed prefix (system, tool schemas, hooks, memory...) = first-turn minus doctrine
nd = 0
for r in POOL:
    v = by[r]
    ft = sorted(x["first"] for x in v)[len(v) // 2]
    rest = max(0, ft - cost["rows"][r]["D"])
    nd += rest * (0.1 * max(0, cost['rows'][r]['turns_mean'] - 1)) * cost['rows'][r]['per_day']
print(f"Non-doctrine fixed prefix re-reads (approx, excl. first write): {nd:,.0f} WTE/day = {100*nd/cost['total']:.1f}% of pool")
