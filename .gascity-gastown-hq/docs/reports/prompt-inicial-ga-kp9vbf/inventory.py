import re, json, collections, os

SP = os.path.dirname(os.path.abspath(__file__))
tok = json.load(open(os.path.join(SP, "role_tokens.json")))
ROLES = ["dog", "wa-worker", "ps-worker", "gate-reviewer", "refino-gate-reviewer", "auto-refiner", "mayor", "peter-wa"]
P = {r: open(os.path.join(SP, "primes", r + ".md")).read() for r in ROLES}

# --- 1) claims in the bead, checked against the rendered artifact
print("1) CLAIM CHECK on rendered primes (count of occurrences)")
probes = {"Gas Town Architecture": r"## Gas Town Architecture", "Dolt hang diag (SHOW FULL PROCESSLIST)": r"SHOW FULL PROCESSLIST",
          "Mail lifecycle": r"Mail lifecycle", "WITNESS block": r"(?i)witness", "Shutdown Dance": r"Shutdown Dance",
          "THIRD STATE rule": r"THIRD STATE|3º estado|terceiro estado|third state", "Propulsion Principle": r"Propulsion Principle"}
print(f"{'':42s}" + "".join(f"{r[:8]:>9s}" for r in ROLES))
for name, rx in probes.items():
    print(f"{name:42s}" + "".join(f"{len(re.findall(rx, P[r])):9d}" for r in ROLES))

# --- 2) exact duplication: identical long lines repeated inside one prime
print("\n2) EXACT DUPLICATION inside each prime (identical lines >= 300 chars)")
print(f"{'role':22s} {'dup chars':>10s} {'% of prime':>10s} {'~tokens':>8s}  biggest repeated line (len x count)")
dup_tokens = {}
for r in ROLES:
    lines = P[r].split("\n")
    c = collections.Counter(l for l in lines if len(l) >= 300)
    dup = sum(len(l) * (n - 1) for l, n in c.items() if n > 1)
    top = max(((len(l), n) for l, n in c.items() if n > 1), default=(0, 0))
    ratio = tok[r]["tokens"] / tok[r]["chars"]
    dup_tokens[r] = dup * ratio
    print(f"{r:22s} {dup:10,d} {100*dup/len(P[r]):9.1f}% {dup*ratio:8,.0f}  {top[0]} x {top[1]}")

# --- 3) town-deltas sections (from template markers)
T = open(__import__("os").path.join(__import__("os").path.dirname(__import__("os").path.abspath(__file__)), "..", "..", "..", "packs", "town-deltas", "template-fragments", "town-deltas.template.md")).read()
marks = [(m.start(), m.group(1)) for m in re.finditer(r"\{\{/\* td:(?:core:)?([a-z0-9-]+) \*/", T)]
sections = {}
for i, (pos, name) in enumerate(marks):
    # section starts at the beginning of the line holding the marker (guard `{{ if ...}}` shares that line)
    start = T.rfind("\n", 0, pos) + 1
    end = T.rfind("\n", 0, marks[i + 1][0]) + 1 if i + 1 < len(marks) else len(T)
    sections[name] = T[start:end]
json.dump({k: len(v) for k, v in sections.items()}, open(os.path.join(SP, "td_sections.json"), "w"), indent=1)
ratio = tok["dog"]["tokens"] / tok["dog"]["chars"]
print("\n3) TOWN-DELTAS sections (template chars; ~tokens at the dog ratio %.3f tok/char)" % ratio)
tot = 0
for k, v in sorted(sections.items(), key=lambda kv: -len(kv[1])):
    tot += len(v)
    print(f"  {k:28s} {len(v):7,d} chars  ~{len(v)*ratio:6,.0f} tok")
print(f"  {'TOTAL':28s} {tot:7,d} chars  ~{tot*ratio:6,.0f} tok")
