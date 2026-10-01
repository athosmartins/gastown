"""Cost model v2. Units = WTE (weighted token-equivalents, base-input price = 1):
   input 1x, cache_write 1h 2x (every write in these transcripts is the 1h tier), cache_read 0.1x, output 5x.
ASSUMPTION (published price ratios, not measured here): the 2x / 0.1x / 5x multipliers."""
import json, collections, statistics as st

d = json.load(open("sessions.json"))
tok = json.load(open("role_tokens.json"))
hit = json.load(open("hitrate.json"))
W = dict(input=1.0, cache_write=2.0, cache_read=0.1, output=5.0)
POOL = ["dog", "wa-worker", "ps-worker", "gate-reviewer", "refino-gate-reviewer", "auto-refiner"]


def keep(x):
    if x["role"] in ("gate-reviewer", "refino-gate-reviewer"):
        return x["start"] >= "2026-09-30"
    return True


by = collections.defaultdict(list)
for x in d:
    if x["role"] in POOL and keep(x):
        by[x["role"]].append(x)

wte = lambda x: sum(W[k] * x["tok"][k] for k in W)
rows = {}
print(f"{'role':22s} {'n':>4s} {'sess/d':>6s} {'turns(med)':>10s} {'WTE/sess':>10s} {'D tok':>7s} {'D first-write':>13s} {'D re-reads':>11s} {'D share':>8s} {'WTE/day':>11s}")
for r in POOL:
    v = by[r]
    n = len(v)
    D = tok[r]["tokens"]
    mean_wte = sum(wte(x) for x in v) / n
    turns = [x["turns"] for x in v]
    mean_turns = sum(turns) / n
    d_first = D * W["cache_write"]
    d_reread = D * W["cache_read"] * max(0, mean_turns - 1)
    share = (d_first + d_reread) / mean_wte
    per_day = hit[r]["per_day"]
    rows[r] = dict(n=n, per_day=per_day, turns_med=st.median(turns), turns_mean=mean_turns, wte_sess=mean_wte, D=D, d_first=d_first,
                   d_reread=d_reread, share=share, wte_day=mean_wte * per_day)
    print(f"{r:22s} {n:4d} {per_day:6.0f} {st.median(turns):10.0f} {mean_wte:10,.0f} {D:7,d} {d_first:13,.0f} {d_reread:11,.0f} {100*share:7.0f}% {mean_wte*per_day:11,.0f}")

tot = sum(x["wte_day"] for x in rows.values())
print(f"\nTotal pool WTE/day (these 6 roles): {tot:,.0f}")

print("\nLEVERS (WTE/day saved, vs the pool total above)")
# L1: doctrine in the system prompt -> first-turn write (2x) becomes a read (0.1x) on cache hits
l1 = {r: rows[r]["per_day"] * hit[r]["hit60"] * rows[r]["D"] * (W["cache_write"] - W["cache_read"]) for r in POOL}
for r in POOL:
    print(f"  L1 cache placement  {r:22s} hit60={100*hit[r]['hit60']:3.0f}%  saves {l1[r]:12,.0f}  ({100*l1[r]/rows[r]['wte_day']:.1f}% of the role)")
print(f"  L1 total {sum(l1.values()):,.0f}  = {100*sum(l1.values())/tot:.1f}% of pool")

# L2: trim doctrine text by X% (per-turn re-reads at 0.1x and, when not cached cross-session, the first write at 2x)
for pct in (0.25, 0.40):
    l2 = {r: pct * (rows[r]["d_first"] + rows[r]["d_reread"]) * rows[r]["per_day"] for r in POOL}
    print(f"  L2 trim {int(pct*100)}% of doctrine (no L1)   total {sum(l2.values()):12,.0f} = {100*sum(l2.values())/tot:.1f}% of pool; "
          + ", ".join(f"{r[:6]} {100*l2[r]/rows[r]['wte_day']:.1f}%" for r in POOL))

# L3: ps-worker sessions that never claimed anything
v = [x for x in by["ps-worker"] if not x["proc"].get("bd_claim")]
idle_share = len(v) / len(by["ps-worker"])
idle_wte = sum(wte(x) for x in v) / max(1, len(v))
l3 = idle_share * rows["ps-worker"]["per_day"] * idle_wte
print(f"  L3 ps-worker sessions with no claim: {len(v)}/{len(by['ps-worker'])} = {100*idle_share:.0f}%; mean {idle_wte:,.0f} WTE each; "
      f"saves {l3:,.0f} WTE/day = {100*l3/tot:.1f}% of pool (and {100*l3/rows['ps-worker']['wte_day']:.0f}% of ps-worker)")
json.dump(dict(rows=rows, total=tot, l1=l1, l3=l3, idle_share=idle_share, idle_wte=idle_wte), open("cost2.json", "w"), indent=1)
