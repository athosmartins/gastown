import json, collections, datetime as dt

d = json.load(open("sessions.json"))
# post-overlay window for each role: the arms differ (gate-reviewer got pool-reviewer overlay ~29-30/09). Show first-turn by day first.
byday = collections.defaultdict(list)
for x in d:
    if x["role"] in ("gate-reviewer", "refino-gate-reviewer") and x["start"]:
        byday[(x["role"], x["start"][:10])].append(x["first"])
print("reviewer first-turn by day (median, n):")
import statistics as st
for k in sorted(byday):
    print("  ", k[0][:6], k[1], int(st.median(byday[k])), len(byday[k]))

ROLES = ["dog", "wa-worker", "ps-worker", "gate-reviewer", "refino-gate-reviewer", "auto-refiner"]
# restrict reviewers to the current regime (>= 2026-09-30) for a like-for-like prompt; others are already single-regime
def keep(x):
    if x["role"] in ("gate-reviewer", "refino-gate-reviewer"):
        return x["start"] and x["start"] >= "2026-09-30"
    return True

by = collections.defaultdict(list)
for x in d:
    if x["role"] in ROLES and keep(x):
        by[x["role"]].append(x)

def pct(v, key, field, nd=0):
    """% of sessions in v whose `field` has `key`. An EMPTY sample is 'sem amostra', never 0% (no sessions != no use)."""
    if not v:
        return f"{'sem amostra':>12s}"
    return f"{100 * sum(1 for x in v if x[field].get(key)) / len(v):11.{nd}f}%"


keys = sorted({k for x in d for k in x["proc"]})
print("\nPROCEDURE USE — % of sessions with >=1 Bash call matching (n in header)")
hdr = f"{'procedure':18s}" + "".join(f"{r[:11]:>12s}" for r in ROLES)
print(hdr)
print(f"{'(n sessions)':18s}" + "".join(f"{len(by[r]):12d}" for r in ROLES))
for k in keys:
    row = f"{k:18s}"
    for r in ROLES:
        v = by[r]
        row += pct(v, k, "proc")
    print(row)

vk = sorted({k for x in d for k in x["viol"]})
print("\nVIOLATION detectors — % of sessions with >=1 hit")
for k in vk:
    row = f"{k:24s}"
    for r in ROLES:
        v = by[r]
        row += pct(v, k, "viol", 1)
    print(row)

print("\nTOOLS used (top, % of sessions)")
alltools = collections.Counter()
for x in d:
    for t in x["tools"]:
        alltools[t] += 1
for t, _ in alltools.most_common(25):
    row = f"{t[:28]:28s}"
    for r in ROLES:
        v = by[r]
        row += pct(v, t, "tools")
    print(row)

print("\nSKILLS invoked (sessions)")
sk = collections.defaultdict(collections.Counter)
for r in ROLES:
    for x in by[r]:
        for s in x["skills"]:
            sk[r][s] += 1
for r in ROLES:
    print(" ", r, dict(sk[r]))
