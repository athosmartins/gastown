"""Projection of the proposed levers + power table. Every input is read from a measured JSON or marked as an assumption."""
import json, math, os

SP = os.path.dirname(os.path.abspath(__file__))
cost = json.load(open(os.path.join(SP, "cost2.json")))
hit = json.load(open(os.path.join(SP, "hitrate.json")))
tok = json.load(open(os.path.join(SP, "role_tokens.json")))
td = json.load(open(os.path.join(SP, "td_sections.json")))
W_WR, W_RD = 2.0, 0.1
R = cost["rows"]
TOTAL = cost["total"]


def ratio(role):                      # tokens per char of the role's rendered prime (measured)
    return tok[role]["tokens"] / tok[role]["chars"]


def sec(role, name):                  # tokens of a town-deltas section for that role (template chars x measured ratio)
    return td[name] * ratio(role)


# (item, tokens, fraction removed, basis). fraction = share removed; the rest stays as a short stub that points to the on-demand source.
DUP = {"dog": 9845, "wa-worker": 2207, "ps-worker": 7156, "gate-reviewer": 1835, "refino-gate-reviewer": 2027, "auto-refiner": 2731}
CUTS = {
    "dog": [("near-duplicate work_query scripts (measured)", DUP["dog"], 1.0), ("engine-window-patch", sec("dog", "engine-window-patch"), .85),
            ("rule-3 athos.acao (guard exists)", sec("dog", "rule-3"), .85), ("next-action-mayor-waiting", sec("dog", "next-action-mayor-waiting"), .75),
            ("research-only-channels", sec("dog", "research-only-channels"), .75), ("models", sec("dog", "models"), .65),
            ("rule-1 + rule-2 (headless never asks Athos)", sec("dog", "rule-1") + sec("dog", "rule-2"), .70),
            ("nudge-permission-dialog (rm -rf/sudo denied)", sec("dog", "nudge-permission-dialog"), .80)],
    "wa-worker": [("near-duplicate scripts (measured)", DUP["wa-worker"], 1.0), ("engine-window-patch", sec("wa-worker", "engine-window-patch"), .85),
                  ("rule-3 athos.acao", sec("wa-worker", "rule-3"), .85), ("next-action-mayor-waiting", sec("wa-worker", "next-action-mayor-waiting"), .75),
                  ("models", sec("wa-worker", "models"), .65), ("rule-1 + rule-2", sec("wa-worker", "rule-1") + sec("wa-worker", "rule-2"), .70)],   # mockup-s3 stays in wa-worker: the S3 skill fired in only 4 of the 15 sessions that ran S3 commands (27%)
    "ps-worker": [("near-duplicate scripts (measured)", DUP["ps-worker"], 1.0), ("engine-window-patch", sec("ps-worker", "engine-window-patch"), .85),
                  ("rule-3 athos.acao", sec("ps-worker", "rule-3"), .85), ("next-action-mayor-waiting", sec("ps-worker", "next-action-mayor-waiting"), .75),
                  ("models", sec("ps-worker", "models"), .65), ("rule-1 + rule-2", sec("ps-worker", "rule-1") + sec("ps-worker", "rule-2"), .70),
                  ("mockup-s3 (0% use in sample)", sec("ps-worker", "mockup-s3"), .80)],
    "gate-reviewer": [("near-duplicate script (measured)", DUP["gate-reviewer"], 1.0), ("rule-1", sec("gate-reviewer", "rule-1"), .8), ("rule-2", sec("gate-reviewer", "rule-2"), .8),
                      ("rule-3 athos.acao", sec("gate-reviewer", "rule-3"), .9), ("rule-4 outward actions (reviewer is read-only)", sec("gate-reviewer", "rule-4"), .7),
                      ("models", sec("gate-reviewer", "models"), .7), ("secrets", sec("gate-reviewer", "secrets"), .8),
                      ("native Dolt-hang + mail lifecycle + architecture (~6.5k chars)", 6500 * ratio("gate-reviewer"), .8)],
    "refino-gate-reviewer": [("near-duplicate script (measured)", DUP["refino-gate-reviewer"], 1.0), ("rule-1", sec("refino-gate-reviewer", "rule-1"), .8),
                             ("rule-2", sec("refino-gate-reviewer", "rule-2"), .8), ("rule-3 athos.acao", sec("refino-gate-reviewer", "rule-3"), .9),
                             ("rule-4", sec("refino-gate-reviewer", "rule-4"), .7), ("models", sec("refino-gate-reviewer", "models"), .7),
                             ("secrets", sec("refino-gate-reviewer", "secrets"), .8), ("native Dolt-hang + mail + architecture", 6500 * ratio("refino-gate-reviewer"), .8)],
    "auto-refiner": [("near-duplicate scripts (measured)", DUP["auto-refiner"], 1.0), ("witness-startup (no witness runs)", sec("auto-refiner", "witness-startup"), 1.0),
                     ("engine-window-patch", sec("auto-refiner", "engine-window-patch"), .85), ("mockup-s3", sec("auto-refiner", "mockup-s3"), .8),
                     ("research-only-channels", sec("auto-refiner", "research-only-channels"), .75), ("next-action-mayor-waiting", sec("auto-refiner", "next-action-mayor-waiting"), .75),
                     ("nudge-permission-dialog", sec("auto-refiner", "nudge-permission-dialog"), .8), ("assignee-when-building", sec("auto-refiner", "assignee-when-building"), .8),
                     ("models", sec("auto-refiner", "models"), .65)],
}


def per_session_doctrine_cost(role, D, h):
    """WTE per session for D tokens of doctrine: first turn (miss=write 2x, hit=read 0.1x) + re-read every later turn."""
    T = R[role]["turns_mean"]
    return D * ((1 - h) * W_WR + h * W_RD + W_RD * max(0, T - 1))


out = {}
print(f"{'role':22s} {'D today':>8s} {'cut':>7s} {'D prop':>8s} {'-%':>5s} | WTE/day: trim only {'':>0s}  L1 only   L1+trim | %role (L1+trim)")
sum_trim = sum_l1 = sum_both = 0
for role, items in CUTS.items():
    D = tok[role]["tokens"]
    cut = sum(t * f for _, t, f in items)
    Dp = D - cut
    pd = R[role]["per_day"]
    h = hit[role]["hit60"]
    before = per_session_doctrine_cost(role, D, 0.0) * pd
    trim = before - per_session_doctrine_cost(role, Dp, 0.0) * pd
    l1 = before - per_session_doctrine_cost(role, D, h) * pd
    both = before - per_session_doctrine_cost(role, Dp, h) * pd
    sum_trim += trim; sum_l1 += l1; sum_both += both
    out[role] = dict(D=D, cut=cut, Dp=Dp, trim=trim, l1=l1, both=both, items=[(n, round(t), f) for n, t, f in items])
    print(f"{role:22s} {D:8,d} {cut:7,.0f} {Dp:8,.0f} {100*cut/D:4.0f}% | {trim:12,.0f} {l1:11,.0f} {both:11,.0f} | {100*both/R[role]['wte_day']:5.1f}%")
print(f"{'TOTAL':22s} {'':8s} {'':7s} {'':8s} {'':5s} | {sum_trim:12,.0f} {sum_l1:11,.0f} {sum_both:11,.0f} | {100*sum_both/TOTAL:5.1f}% of pool ({TOTAL:,.0f})")
l3 = cost["l3"]
print(f"\nL3 (stop the lx-b5q/ps-worker respawn loop): {l3:,.0f} WTE/day = {100*l3/TOTAL:.1f}% of pool")
print(f"L1+trim+L3 (overlap-free approx; L3 sessions are ps-worker, trim/L1 on ps-worker partly overlap): {sum_both + l3:,.0f} = {100*(sum_both + l3)/TOTAL:.1f}% of pool")
idle = cost["idle_share"]
combined = sum_both - idle * out["ps-worker"]["both"] + l3          # L3 removes `idle` of ps-worker sessions, so trim/L1 only apply to the rest
print(f"COMBINED (L1 + trim + L3, ps-worker overlap removed: idle share {100*idle:.0f}%): {combined:,.0f} WTE/day = {100*combined/TOTAL:.1f}% of pool")
out["_combined"] = dict(wte_day=combined, pct_pool=100 * combined / TOTAL)
json.dump(out, open(os.path.join(SP, "projection.json"), "w"), indent=1)

# ------------------------------------------------------------------ power
z = lambda p: {0.05: 1.6449, 0.025: 1.96, 0.2: 0.8416}[p]
print("\nPOWER (one-sided alpha 0.05, power 0.80)")
p0 = 0.56
for delta in (0.05, 0.08, 0.10):
    n = 2 * p0 * (1 - p0) * (z(0.05) + z(0.2)) ** 2 / delta ** 2
    print(f"  non-inferiority on first-try approval (p0={p0:.2f}), margin -{int(delta*100)}pp: n/arm={math.ceil(n):5d} beads -> {math.ceil(n)/ (59.7/2):5.1f} days at 59.7 beads/day split 50/50")
for name, p, perday in (("dog rm -rf attempt", .386, 79), ("dog git add -A/commit -a", .096, 79), ("wa-worker git add -A", .128, 32), ("gate-reviewer rm -rf attempt", .362, 136)):
    for delta in (0.10, 0.05):
        n = (z(0.05) + z(0.2)) ** 2 * 2 * p * (1 - p) / delta ** 2
        print(f"  detector '{name}' base {100*p:.1f}%: detect +{int(delta*100)}pp -> n/arm={math.ceil(n):4d} sessions = {math.ceil(n)/(perday/2):5.1f} days at {perday}/day split 50/50")
# McNemar paired (shadow of reviewer): psi = discordant share, delta = asymmetry
for psi, d in ((0.20, 0.06), (0.15, 0.05)):
    n = (z(0.05) * math.sqrt(psi) + z(0.2) * math.sqrt(psi - d * d)) ** 2 / d ** 2
    print(f"  paired shadow (McNemar) psi={psi} delta={d}: {math.ceil(n)} pairs")
rev_cost = 1_152_388
print(f"  cost of 342 extra reviewer sessions ~ {342*rev_cost:,.0f} WTE = {342*rev_cost/TOTAL:.2f} days of the whole pool")
