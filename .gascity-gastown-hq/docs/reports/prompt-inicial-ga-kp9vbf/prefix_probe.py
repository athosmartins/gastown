"""Structure of a dog session's first turn: what precedes the doctrine, and the cache-creation TTL split."""
import glob, json, os, re, sys, importlib.util

spec = importlib.util.spec_from_file_location(
    "ppm", __import__("os").path.join(__import__("os").path.dirname(__import__("os").path.abspath(__file__)), "..", "..", "..", "packs", "town-deltas", "assets", "pool-preamble-measure.py"))
ppm = importlib.util.module_from_spec(spec); spec.loader.exec_module(ppm)

# pick the most recent complete dog transcript that is not this session
want = sys.argv[1] if len(sys.argv) > 1 else "dog"
cands = []
for p in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
    if "dogs-gastown-dog" not in p and want == "dog":
        continue
    cands.append((os.path.getmtime(p), p))
cands.sort(reverse=True)
shown = 0
for _, p in cands:
    recs = []
    try:
        for line in open(p, errors="replace"):
            try:
                recs.append(json.loads(line))
            except Exception:
                pass
    except OSError:
        continue
    users = [r for r in recs if r.get("type") == "user" and not r.get("isSidechain")]
    if not users:
        continue
    txt = ppm.first_text(users[0])
    m = ppm.BEACON.match(txt.lstrip())
    if not m or not m.group(1).startswith("gastown.dog"):
        continue
    if "a41e926b" in p:      # skip my own session
        continue
    print("transcript:", p)
    print("first user record: type(content) =", type((users[0].get("message") or {}).get("content")).__name__,
          " total chars =", len(txt))
    c = (users[0].get("message") or {}).get("content")
    if isinstance(c, list):
        for i, b in enumerate(c):
            t = b.get("text", "") if isinstance(b, dict) else str(b)
            print(f"  block {i}: {b.get('type') if isinstance(b, dict) else '?'} {len(t):7d} chars  starts: {t[:70]!r}")
    # where is the doctrine marker vs variable markers?
    for label, rx in [("beacon", r"\[gascity\] \S+ • \d{4}-"), ("gitStatus", r"gitStatus"), ("doctrine start", r"# Dog Context"),
                      ("system-reminder", r"<system-reminder>"), ("SessionStart hook", r"SessionStart hook")]:
        pos = [mm.start() for mm in re.finditer(rx, txt)]
        print(f"  {label:18s} offsets: {pos[:6]}")
    # first assistant usage with cache_creation breakdown
    for r in recs:
        if r.get("type") == "assistant" and not r.get("isSidechain"):
            u = (r.get("message") or {}).get("usage") or {}
            if (u.get("cache_creation_input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0) > 0:
                print("  first assistant usage:", json.dumps({k: u.get(k) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "cache_creation")}))
                break
    shown += 1
    if shown >= 2:
        break
