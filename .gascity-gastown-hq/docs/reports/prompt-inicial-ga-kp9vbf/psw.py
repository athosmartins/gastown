"""What do ps-worker sessions actually do? Print the final assistant text and the bash commands (short) of N sessions."""
import glob, importlib.util, json, os, re, collections, sys
spec = importlib.util.spec_from_file_location("ppm", __import__("os").path.join(__import__("os").path.dirname(__import__("os").path.abspath(__file__)), "..", "..", "..", "packs", "town-deltas", "assets", "pool-preamble-measure.py"))
ppm = importlib.util.module_from_spec(spec); spec.loader.exec_module(ppm)
role = sys.argv[1]; n = int(sys.argv[2])
shown = 0
outcomes = collections.Counter()
for p in sorted(glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")), key=os.path.getmtime, reverse=True):
    try:
        recs = [json.loads(l) for l in open(p, errors="replace") if l.strip()]
    except Exception:
        continue
    alias = None
    for r in recs:
        if r.get("type") == "user" and not r.get("isSidechain"):
            m = ppm.BEACON.match(ppm.first_text(r).lstrip()); alias = m.group(1) if m else ""; break
    if ppm.role_of(alias) != role:
        continue
    texts, cmds = [], []
    for r in recs:
        if r.get("type") != "assistant" or r.get("isSidechain"):
            continue
        for b in (r.get("message") or {}).get("content") or []:
            if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip():
                texts.append(b["text"].strip())
            if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash":
                cmds.append(re.sub(r"\s+", " ", str((b.get("input") or {}).get("command") or ""))[:110])
    last = texts[-1] if texts else ""
    key = "no-work" if re.search(r"no (assigned |pool |routed )?work|nothing to (do|claim)|queue (is )?empty|no ready|sem trabalho|nenhum trabalho|\[\]", last, re.I) else "other"
    outcomes[key] += 1
    if shown < n:
        print("=" * 100); print(alias, os.path.basename(p)[:8], "turns(cmds)=", len(cmds))
        for c in cmds[:5]:
            print("  $", c)
        print("  LAST:", last[:400].replace("\n", " "))
        shown += 1
print(outcomes)
