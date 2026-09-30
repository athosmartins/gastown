#!/usr/bin/env python3
"""ga-26k2y1 E4 step 4 (pairs) — select FAIL -> PASS pairs: per Era-B bead, the FIRST PASS that directly follows a reviewer FAIL (FAIL_REVIEW), taken only when both gate runs
have a stored reviewer-task header (x_tasks). The stored task embeds the diff the reviewer saw, so no git is needed and dangling shas do not matter — but that diff is WHOLE only
when the task header says FULL DIFF; pairs_judge.py records the partial flags (pair_out_<tag>.fail_partial / pass_partial) and the consumers drop the partial pairs.
Writes pairs(bead_id, db, fail_run, pass_run, fail_comment, month, n_fail_before) — no partial flags here. Fetches the missing task texts (read-only Dolt) into task_full.
Selection: every candidate if there are <=260; otherwise a seeded uniform sample per month, sized in proportion to the month's share of the candidates with a floor of 20 per
month (a month with fewer than 20 candidates is taken whole, so the small months are over-represented and the total can pass 260). One pair per bead; n_fail_before (how many
reviewer FAILs preceded the PASS) is recorded but plays no part in the selection."""
import os, random, re, sqlite3, sys, time, collections
import pymysql
HERE = os.path.dirname(os.path.abspath(__file__))
CFG = "/Users/athos/gt/.gascity-gastown-hq/.gc/runtime/packs/dolt/dolt-config.yaml"
PORT = int(re.search(r"^\s*port:\s*(\d+)", open(CFG).read(), re.M).group(1))
s = sqlite3.connect(os.path.join(HERE, "e4.db"), timeout=120)
have = {r[0] for r in s.execute("select run_id from x_tasks")}
cands = []
seq = collections.defaultdict(list)
for r in s.execute("select db, bead_id, comment_id, created_at, outcome, gate_run from attempts order by db, bead_id, created_at, rowid"):
    seq[(r[0], r[1])].append(r)
for (db, bead), rows in seq.items():
    for i in range(1, len(rows)):
        if rows[i][4] == "PASS" and rows[i - 1][4] == "FAIL_REVIEW" and rows[i][5] in have and rows[i - 1][5] in have:
            nb = sum(1 for x in rows[:i] if x[4] == "FAIL_REVIEW")
            cands.append((db, bead, rows[i - 1][5], rows[i][5], rows[i - 1][2], rows[i - 1][3][:7], nb))
            break
print("FAIL->PASS candidate beads (Era B):", len(cands), " by month:", dict(collections.Counter(c[5] for c in cands)))
rng = random.Random(300926)
if len(cands) > 260:
    by = collections.defaultdict(list)
    for c in cands: by[c[5]].append(c)
    sel = []
    for m, cs in by.items():
        k = max(20, round(260 * len(cs) / len(cands))); sel += rng.sample(cs, min(k, len(cs)))
    cands = sel
print("selected pairs:", len(cands))
s.execute("DROP TABLE IF EXISTS pairs")
s.execute("CREATE TABLE pairs(bead_id TEXT, db TEXT, fail_run TEXT, pass_run TEXT, fail_comment TEXT, month TEXT, n_fail_before INT)")
s.executemany("INSERT INTO pairs VALUES (?,?,?,?,?,?,?)", [(c[1], c[0], c[2], c[3], c[4], c[5], c[6]) for c in cands]); s.commit()
# fetch the task texts we do not have yet
s.executescript("CREATE TABLE IF NOT EXISTS task_full(run_id TEXT, verdict_bead TEXT, text TEXT, PRIMARY KEY(run_id, verdict_bead));")
cached = {r[0] for r in s.execute("select distinct run_id from task_full")}
todo = sorted({r for c in cands for r in (c[2], c[3])} - cached)
vb = collections.defaultdict(list)
for run, v in s.execute("select run_id, verdict_bead from x_tasks"): vb[run].append(v)
print("task texts to fetch:", len(todo))
conn = None
def q(sql, args):
    global conn
    for i in range(3):
        try:
            if conn is None: conn = pymysql.connect(host="127.0.0.1", port=PORT, user="root", database="hq", read_timeout=25, connect_timeout=10, autocommit=True, charset="utf8mb4")
            cur = conn.cursor(); cur.execute(sql, args); return cur.fetchall()
        except (pymysql.err.OperationalError, pymysql.err.InterfaceError):
            conn = None; time.sleep(2 * (i + 1))
    raise RuntimeError("dolt read failed 3x")
t0 = time.time()
for i in range(0, len(todo), 12):
    chunk = todo[i:i + 12]; ids = sorted({v for r in chunk for v in vb[r]}); ph = ",".join(["%s"] * len(ids))
    owner = {v: r for r in chunk for v in vb[r]}
    for iid, text in q(f"SELECT issue_id, text FROM comments WHERE issue_id IN ({ph}) AND text LIKE 'QUALITY GATE REVIEW%%'", ids):
        s.execute("INSERT OR REPLACE INTO task_full VALUES (?,?,?)", (owner[iid], iid, text))
    s.commit(); time.sleep(0.05)
print(f"fetched; task_full now: {s.execute('select count(*) from task_full').fetchone()[0]} rows  t={time.time()-t0:.0f}s")
