#!/usr/bin/env python3
"""ga-26k2y1 E4 step 2a — the classification population = the CENSUS of blocking issues (every issue in e4.db `bi`), ordered by priority so that any
prefix of a partial run is still a usable sample:
  prio 0  issues filed on/after the reviewer-prompt-v2 cut (2026-09-25 16:04Z == 13:04 -03)
  prio 1  issues of beads that had >=2 reviewer FAILs (needed for recurrence and for the latent-defect front)
  prio 2  the rest, in a fixed pseudo-random order (md5 of bi_id) so a prefix is a random sample
Also writes bi_second (the ~10% independent second-judgement sample, stratified by month x rig, seeded) and prints the composition."""
import hashlib, os, sqlite3, random, collections

HERE = os.path.dirname(os.path.abspath(__file__))
CUT = "2026-09-25 16:04:00"
s = sqlite3.connect(os.path.join(HERE, "e4.db"))
s.executescript("DROP TABLE IF EXISTS bi_sample; DROP TABLE IF EXISTS bi_second;")
s.execute("CREATE TABLE bi_sample(bi_id TEXT PRIMARY KEY, text TEXT, prio INT, month TEXT, rig TEXT)")
multi = {(r[0], r[1]) for r in s.execute("SELECT db, bead_id FROM attempts WHERE outcome IN ('FAIL_REVIEW','FAIL_UNSTRUCT') GROUP BY 1,2 HAVING COUNT(*) >= 2")}
rows = []
for bi_id, db, bead, ca, text, month, rig in s.execute("SELECT bi_id, db, bead_id, created_at, text, month, rig FROM bi"):
    prio = 0 if ca >= CUT else (1 if (db, bead) in multi else 2)
    rows.append((bi_id, text, prio, month, rig, hashlib.md5(bi_id.encode()).hexdigest()))
rows.sort(key=lambda r: (r[2], r[5]))
s.executemany("INSERT INTO bi_sample VALUES (?,?,?,?,?)", [r[:5] for r in rows])
# second-judgement sample: 10%, stratified by month x rig, seeded
rng = random.Random(260930)
cells = collections.defaultdict(list)
for r in rows:
    cells[(r[3], r[4])].append(r[0])
pick = []
for k, ids in sorted(cells.items()):
    n = max(1, round(len(ids) * 0.10)) if len(ids) >= 5 else 0
    pick += rng.sample(ids, n)
s.execute("CREATE TABLE bi_second(bi_id TEXT PRIMARY KEY)")
s.executemany("INSERT INTO bi_second VALUES (?)", [(i,) for i in pick])
open(os.path.join(HERE, "second_ids.txt"), "w").write("\n".join(pick))
s.commit()
print("census:", len(rows), " prio counts:", collections.Counter(r[2] for r in rows), " second-judgement sample:", len(pick))
