#!/usr/bin/env python3
"""ga-26k2y1 E4 step 2 — classify blocking issues with a FIXED taxonomy (taxonomy_prompt.md), in BATCHES (never one call per item).

Reads  e4.db  table `bi_sample(bi_id, text, prio, month, rig)`  (built by e4_sample.py; read in `prio` order), writes `cls_<tag>(bi_id, cls, tags, conf, why, batch, model)`.
Resumable: items already present in cls_<tag> are skipped; every finished batch is committed at once. The raw model output of each call is written to raw_<tag>/ for
inspection; a batch whose call fails or whose output does not parse is re-sent to the model ONCE (a second call; it overwrites the raw file), then reported as FAILED and left undone.
Low concurrency + nice (the machine runs at load 40+).

  python3 e4_classify.py --tag primary --model sonnet --effort medium --batch 12 [--limit N] [--ids-file f.txt]
  python3 e4_classify.py --tag second  --model claude-opus-5-5 --effort medium --batch 12 --ids-file second_ids.txt
"""
import argparse, json, os, re, sqlite3, subprocess, sys, time, concurrent.futures as cf

HERE = os.path.dirname(os.path.abspath(__file__))
MAX_CHARS = 1600          # per blocking issue; longer texts keep head + tail (the verdict's conclusion is usually at the end)
CLASSES = set("ABCDEFZ")


def clip(t, n=MAX_CHARS):
    t = (t or "").strip()
    return t if len(t) <= n else t[: n * 2 // 3] + "\n[...clipped...]\n" + t[-n // 3:]


def build_prompt(items):
    # batch-local short ids (1..N): on ~3% of the first full run the model shortened the 60-char composite ids when echoing them back ("missing ids")
    body = "\n".join(f'<conteudo_externo id="{k + 1}">\n{clip(t)}\n</conteudo_externo>' for k, (i, t) in enumerate(items))
    return f"Classify each of the {len(items)} blocking issues below. Return only the JSON array.\n\n{body}\n"


def call(model, effort, system, prompt, timeout=420):
    cmd = ["nice", "-n", "15", "claude", "-p", "--model", model, "--effort", effort, "--no-session-persistence", "--setting-sources", "",
           "--strict-mcp-config", "--disable-slash-commands", "--tools", "", "--output-format", "json", "--max-budget-usd", "1.0",
           "--system-prompt", system]
    r = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"claude rc={r.returncode}: {r.stderr[-300:]}")
    j = json.loads(r.stdout)
    if j.get("is_error"):
        raise RuntimeError(f"claude error: {str(j.get('result'))[:300]}")
    return j.get("result", ""), float(j.get("total_cost_usd") or 0)


def parse(out, ids):
    m = re.search(r"\[\s*\{.*\}\s*\]", out, re.S)
    if not m:
        raise ValueError("no JSON array in output")
    arr = json.loads(m.group(0))
    got = {str(o.get("id")): o for o in arr}
    short = {str(k + 1): i for k, i in enumerate(ids)}       # short id shown to the model -> real bi_id
    missing = [k for k in short if k not in got]
    if missing:
        raise ValueError(f"missing ids {missing[:3]}...")
    bad = [k for k in short if str(got[k].get("cls", "")).upper()[:1] not in CLASSES]
    if bad:
        raise ValueError(f"bad class for {bad[:3]}")
    return {short[k]: got[k] for k in short}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=os.path.join(HERE, "e4.db"))
    ap.add_argument("--tag", required=True)
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--effort", default="medium")
    ap.add_argument("--batch", type=int, default=12)
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--ids-file")
    a = ap.parse_args()
    system = open(os.path.join(HERE, "taxonomy_prompt.md"), encoding="utf-8").read()
    s = sqlite3.connect(a.db, timeout=60)
    s.execute(f"CREATE TABLE IF NOT EXISTS cls_{a.tag}(bi_id TEXT PRIMARY KEY, cls TEXT, tags TEXT, conf REAL, why TEXT, batch TEXT, model TEXT)")
    os.makedirs(os.path.join(HERE, f"raw_{a.tag}"), exist_ok=True)
    done = {r[0] for r in s.execute(f"SELECT bi_id FROM cls_{a.tag}")}
    want = {l.strip() for l in open(a.ids_file)} if a.ids_file else None
    rows = [(i, t) for i, t in s.execute("SELECT bi_id, text FROM bi_sample ORDER BY prio, rowid") if i not in done and (want is None or i in want)]
    if a.limit:
        rows = rows[: a.limit]
    batches = [rows[i:i + a.batch] for i in range(0, len(rows), a.batch)]
    print(f"[{a.tag}] {len(rows)} items to do in {len(batches)} batches (already done: {len(done)})", flush=True)
    total_cost, fails = 0.0, 0

    def work(ix):
        b = batches[ix]; ids = [i for i, _ in b]; name = f"{a.tag}-{ix:04d}"
        last = None
        for attempt in range(2):
            try:
                out, cost = call(a.model, a.effort, system, build_prompt(b))
                open(os.path.join(HERE, f"raw_{a.tag}", name + ".txt"), "w", encoding="utf-8").write(out)
                return ix, parse(out, ids), cost, name
            except Exception as e:  # noqa: BLE001 — recorded, batch retried once, then reported (never silently dropped)
                last = e; time.sleep(3)
        return ix, last, 0.0, name

    with cf.ThreadPoolExecutor(max_workers=a.workers) as ex:
        for ix, res, cost, name in ex.map(work, range(len(batches))):
            if isinstance(res, Exception) or res is None:
                fails += 1; print(f"  batch {name} FAILED: {res}", flush=True); continue
            total_cost += cost
            s.executemany(f"INSERT OR REPLACE INTO cls_{a.tag} VALUES (?,?,?,?,?,?,?)",
                          [(i, str(o.get("cls")).upper()[:1], json.dumps(o.get("tags") or []), float(o.get("conf") or 0), str(o.get("why") or "")[:200], name, a.model)
                           for i, o in res.items()])
            s.commit()
            print(f"  batch {name} ok ({len(res)} items) cost=${cost:.3f} total=${total_cost:.2f}", flush=True)
    print(f"[{a.tag}] finished: failed_batches={fails} cost=${total_cost:.2f}")


if __name__ == "__main__":
    main()
