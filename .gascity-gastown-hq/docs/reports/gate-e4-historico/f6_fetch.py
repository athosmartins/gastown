#!/usr/bin/env python3
"""ga-26k2y1 E4 / Frente 6 step 1 — fetch the FULL stored reviewer task (which embeds the complete diff the reviewer saw) and the reviewer's full
verdict comment for every gate run of the Era-B beads that had >=2 reviewer FAILs. READ-ONLY on Dolt; cached in e4.db tables task_full / verdict_full.
Only the runs that matter: every FAIL_REVIEW run of those beads plus the PASS run that closed them."""
import os, re, sqlite3, sys, time
import pymysql

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = "/Users/athos/gt/.gascity-gastown-hq/.gc/runtime/packs/dolt/dolt-config.yaml"
PORT = int(re.search(r"^\s*port:\s*(\d+)", open(CFG).read(), re.M).group(1))
s = sqlite3.connect(os.path.join(HERE, "e4.db"))
s.executescript("""CREATE TABLE IF NOT EXISTS task_full(run_id TEXT, verdict_bead TEXT, text TEXT, PRIMARY KEY(run_id, verdict_bead));
                   CREATE TABLE IF NOT EXISTS verdict_full(run_id TEXT, verdict_bead TEXT, author TEXT, created_at TEXT, text TEXT);""")
have_task = {r[0] for r in s.execute("select run_id from x_tasks")}
att = {}
for r in s.execute("select db, bead_id, outcome, gate_run from attempts order by db, bead_id, created_at, rowid"):
    att.setdefault((r[0], r[1]), []).append(r)
runs = []
for (db, bead), rows in att.items():
    rev = [r for r in rows if r[2] == "FAIL_REVIEW"]
    if len(rev) >= 2 and all(r[3] in have_task for r in rev):
        runs += [r[3] for r in rows if r[2] in ("FAIL_REVIEW", "PASS") and r[3] in have_task]
runs = sorted(set(runs))
done = {r[0] for r in s.execute("select distinct run_id from task_full")}
todo = [r for r in runs if r not in done]
print(f"runs needed: {len(runs)}  already cached: {len(done)}  to fetch: {len(todo)}", flush=True)
vb = {}
for run, vbead in s.execute("select run_id, verdict_bead from x_tasks"):
    vb.setdefault(run, []).append(vbead)
conn = None
def q(sql, args):
    global conn
    for i in range(3):
        try:
            if conn is None:
                conn = pymysql.connect(host="127.0.0.1", port=PORT, user="root", database="hq", read_timeout=25, connect_timeout=10, autocommit=True, charset="utf8mb4")
            cur = conn.cursor(); cur.execute(sql, args); return cur.fetchall()
        except (pymysql.err.OperationalError, pymysql.err.InterfaceError):
            conn = None; time.sleep(2 * (i + 1))
    raise RuntimeError("dolt read failed 3x")
t0 = time.time(); n = 0
for i in range(0, len(todo), 12):
    chunk = todo[i:i + 12]
    ids = sorted({v for r in chunk for v in vb.get(r, [])}); ph = ",".join(["%s"] * len(ids))
    rows = q(f"SELECT issue_id, author, created_at, text FROM comments WHERE issue_id IN ({ph}) ORDER BY created_at", ids)
    owner = {v: r for r in chunk for v in vb.get(r, [])}
    for issue_id, author, ca, text in rows:
        run = owner[issue_id]
        if text.startswith("QUALITY GATE REVIEW"):
            s.execute("INSERT OR REPLACE INTO task_full VALUES (?,?,?)", (run, issue_id, text))
        else:
            s.execute("INSERT INTO verdict_full VALUES (?,?,?,?,?)", (run, issue_id, author, str(ca), text))
        n += 1
    s.commit(); time.sleep(0.05)
    print(f"  {min(i + 12, len(todo))}/{len(todo)} runs  comments={n}  t={time.time()-t0:.0f}s", flush=True)
print("done. task_full:", s.execute("select count(*), sum(length(text)) from task_full").fetchone(), " verdict_full:", s.execute("select count(*) from verdict_full").fetchone())
