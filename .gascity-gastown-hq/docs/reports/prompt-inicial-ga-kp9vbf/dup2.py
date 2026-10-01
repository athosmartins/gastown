import re, json, os, collections
SP = os.path.dirname(os.path.abspath(__file__))
tok = json.load(open(os.path.join(SP, "role_tokens.json")))
ROLES = ["dog", "wa-worker", "ps-worker", "gate-reviewer", "refino-gate-reviewer", "auto-refiner", "mayor", "peter-wa"]
P = {r: open(os.path.join(SP, "primes", r + ".md")).read() for r in ROLES}

# near-duplication: content covered by 120-char shingles that occur >1 time (counts every repeat after the first)
def repeated_chars(text, k=120):
    seen, rep = set(), 0
    covered = bytearray(len(text))
    first = {}
    for i in range(0, len(text) - k + 1):
        s = text[i:i + k]
        if s in first:
            for j in range(i, i + k):
                covered[j] = 1
        else:
            first[s] = i
    return sum(covered)

print(f"{'role':22s} {'chars':>8s} {'repeat chars':>13s} {'%':>6s} {'~tokens':>8s} | long-line (>=1500c) chars  count")
for r in ROLES:
    t = P[r]
    rc = repeated_chars(t)
    ratio = tok[r]["tokens"] / tok[r]["chars"]
    longs = [len(l) for l in t.split("\n") if len(l) >= 1500]
    print(f"{r:22s} {len(t):8,d} {rc:13,d} {100*rc/len(t):5.1f}% {rc*ratio:8,.0f} | {sum(longs):8,d} chars in {len(longs)} lines")
