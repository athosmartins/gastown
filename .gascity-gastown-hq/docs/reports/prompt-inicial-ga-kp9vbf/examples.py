"""Print example Bash commands that match a detector, per role, so the detector can be validated against reality."""
import glob, importlib.util, json, os, re, sys, collections

spec = importlib.util.spec_from_file_location("ppm", __import__("os").path.join(__import__("os").path.dirname(__import__("os").path.abspath(__file__)), "..", "..", "..", "packs", "town-deltas", "assets", "pool-preamble-measure.py"))
ppm = importlib.util.module_from_spec(spec); spec.loader.exec_module(ppm)
us = importlib.util.spec_from_file_location("us", "usage_scan.py")
src = open("usage_scan.py").read().replace("\nmain()\n", "\n")   # import without running main
ns = {}
exec(compile(src, "usage_scan.py", "exec"), ns)

role, name = sys.argv[1], sys.argv[2]
rx = re.compile(sys.argv[3])
neg = re.compile(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else None
limit = int(sys.argv[5]) if len(sys.argv) > 5 else 8
since = sys.argv[6] if len(sys.argv) > 6 else "2026-09-30"
shown, seen_norm = 0, collections.Counter()
for p in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
    alias = None
    start = None
    try:
        recs = [json.loads(l) for l in open(p, errors="replace") if l.strip()]
    except Exception:
        continue
    for r in recs:
        if r.get("type") == "user" and not r.get("isSidechain"):
            m = ppm.BEACON.match(ppm.first_text(r).lstrip()); alias = m.group(1) if m else ""; break
    if ppm.role_of(alias) != role:
        continue
    ts = next((r.get("timestamp") for r in recs if r.get("timestamp")), "") or ""
    if ts[:10] < since:
        continue
    seen = set()
    for r in recs:
        if r.get("type") != "assistant" or r.get("isSidechain"):
            continue
        for b in (r.get("message") or {}).get("content") or []:
            if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash" and b.get("id") not in seen:
                seen.add(b.get("id"))
                cmd = str((b.get("input") or {}).get("command") or "")
                if rx.search(cmd) and not (neg and neg.search(cmd)):
                    key = re.sub(r"\s+", " ", cmd)[:90]
                    seen_norm[key] += 1
for k, n in seen_norm.most_common(limit):
    print(f"{n:4d}x  {k}")
print(f"-- distinct matching commands: {len(seen_norm)}  total: {sum(seen_norm.values())}")
