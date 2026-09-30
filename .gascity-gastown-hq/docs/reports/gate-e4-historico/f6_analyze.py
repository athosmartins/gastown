#!/usr/bin/env python3
"""ga-26k2y1 E4 / Frente 6 step 2 — mechanical analysis of what the reviewer SAW, from the stored reviewer tasks. Pure function of e4.db (task_full, x_tasks, attempts, bi).

(The population-wide partial-diff / FAIL-rate analysis lives in e4_stats2.py, which sizes runs by the exact DIFF header.)
M2 (Era-B beads with >=2 reviewer FAILs): for every LATER-round blocking issue, was the file it cites visible to the reviewer in ROUND 1?
      round1_view: omitted  = file is in the round-1 OMITTED FILES list (unseen by construction)
                   shown    = file's diff was in the round-1 task (candidate LATENT — needs a content check)
                   absent   = file not in the round-1 diff at all (added later / context file)
                   nocite   = the issue cites no file that appears in any round's diff
      overlap      = share of the round-N added lines of that file that already existed IDENTICALLY as added lines in round 1
Writes f6_issue(bi_id, ...) and prints the aggregates used in the report."""
import collections, os, re, sqlite3

HERE = os.path.dirname(os.path.abspath(__file__))
RX_PATH = re.compile(r"[\w][\w./-]*\.(?:py|js|sh|html|toml|md|json|sql|ya?ml|plist|css|txt)\b")


def parse_task(text):
    d = {"partial": None, "omitted": [], "files": {}, "shown_files": 0, "total_files": None, "shown_lines": None, "total_lines": None}
    m = re.search(r"\n(FULL DIFF \(complete[^\n]*|PARTIAL DIFF[^\n]*)\n", text)
    if m:
        d["partial"] = m.group(1).startswith("PARTIAL")
        pm = re.search(r"showing (\d+) of (\d+) files \((\d+) of (\d+) total diff lines\)", m.group(1))
        if pm:
            d["shown_files"], d["total_files"], d["shown_lines"], d["total_lines"] = map(int, pm.groups())
        else:
            fm = re.search(r"(\d+) lines across (\d+) file", m.group(1))
            if fm:
                d["total_lines"] = d["shown_lines"] = int(fm.group(1)); d["total_files"] = d["shown_files"] = int(fm.group(2))
    om = re.search(r"OMITTED FILES \((\d+)\):\n((?:  - [^\n]+\n)+)", text)
    if om:
        d["omitted"] = [l[4:].strip() for l in om.group(2).splitlines()]
    body = text.split("\n--- YOUR TASK ---")[0]
    for sec in re.split(r"(?m)^diff --git ", body)[1:]:
        fm = re.match(r"a/(\S+) b/(\S+)", sec)
        if not fm:
            continue
        added = [l[1:].strip() for l in sec.splitlines() if l.startswith("+") and not l.startswith("+++")]
        d["files"][fm.group(2)] = {"added": [a for a in added if len(a) > 3], "text": sec}
    return d


def cited_files(issue_text, universe):
    toks = {t.strip("./") for t in RX_PATH.findall(issue_text)}
    hit = set()
    for f in universe:
        base = f.rsplit("/", 1)[-1]
        if any(f.endswith(t) or t.endswith(f) or (t == base) for t in toks if len(t) > 3):
            hit.add(f)
    return hit


def main():
    s = sqlite3.connect(os.path.join(HERE, "e4.db"))
    # ---------------- M2 ----------------
    s.executescript("DROP TABLE IF EXISTS f6_issue;")
    s.execute("""CREATE TABLE f6_issue(bi_id TEXT PRIMARY KEY, bead_id TEXT, round INT, gate_run TEXT, round1_run TEXT, cited TEXT, round1_view TEXT, overlap REAL,
                 r1_partial INT, r1_cov_files REAL, r1_cov_lines REAL, rN_partial INT, r1_omitted_n INT)""")
    tasks = {}
    for run, text in s.execute("select run_id, text from task_full"):
        if run not in tasks:
            tasks[run] = parse_task(text)
    att = collections.defaultdict(list)
    for r in s.execute("select db, bead_id, comment_id, outcome, gate_run from attempts where outcome='FAIL_REVIEW' order by db, bead_id, created_at, rowid"):
        att[(r[0], r[1])].append(r)
    out = collections.Counter(); ovl = []
    for (db, bead), rev in att.items():
        if len(rev) < 2 or not all(r[4] in tasks for r in rev):
            continue
        r1 = tasks[rev[0][4]]
        for rnd, a in enumerate(rev, start=1):
            if rnd == 1:
                continue
            tN = tasks[a[4]]
            for bi_id, itext in s.execute("select bi_id, text from bi where comment_id=?", (a[2],)).fetchall():
                universe = set(r1["files"]) | set(r1["omitted"]) | set(tN["files"])
                cf = cited_files(itext, universe)
                view, overlap = "nocite", None
                if cf:
                    if any(f in r1["omitted"] for f in cf): view = "omitted"
                    elif any(f in r1["files"] for f in cf): view = "shown"
                    else: view = "absent"
                    shown_both = [f for f in cf if f in r1["files"] and f in tN["files"] and tN["files"][f]["added"]]
                    if shown_both:
                        a1 = set(); aN = []
                        for f in shown_both: a1 |= set(r1["files"][f]["added"]); aN += tN["files"][f]["added"]
                        overlap = sum(1 for x in aN if x in a1) / len(aN); ovl.append((view, overlap))
                cov_f = (r1["shown_files"] / r1["total_files"]) if r1["total_files"] else None
                cov_l = (r1["shown_lines"] / r1["total_lines"]) if r1["total_lines"] else None
                s.execute("INSERT INTO f6_issue VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                          (bi_id, bead, rnd, a[4], rev[0][4], ",".join(sorted(cf)), view, overlap, int(bool(r1["partial"])), cov_f, cov_l, int(bool(tN["partial"])), len(r1["omitted"])))
                out[view] += 1
    s.commit()
    n = sum(out.values())
    print(f"\nM2  later-round issues in Era-B multi-fail beads: {n}   round1_view: " + ", ".join(f"{k}={v} ({v/n:.0%})" for k, v in out.most_common()))
    print("    of these, issues whose bead had a PARTIAL round-1 diff:", s.execute("select count(*), sum(r1_partial) from f6_issue").fetchone())
    for v in ("shown", "absent", "omitted"):
        o = [x for vv, x in ovl if vv == v]
        if o: print(f"    overlap[{v}] n={len(o)} median={sorted(o)[len(o)//2]:.2f}  share>=0.8: {sum(1 for x in o if x >= .8)/len(o):.2f}  share==0: {sum(1 for x in o if x == 0)/len(o):.2f}")


if __name__ == "__main__":
    main()
