#!/usr/bin/env python3
"""ga-26k2y1 E4 step 1d — ADDITIVE fix to runs2 (does not drop anything, so it is safe while other jobs read e4.db).
Why: the stored DIFF SUMMARY line is cut mid-number for big diffs ("14 files changed, 1958 ..."), so insertions/deletions parse as 0 for exactly the large runs.
The DIFF header line is exact and always present: 'FULL DIFF (complete — N lines across M file(s)...)' or 'PARTIAL DIFF — showing A of B files (C of D total diff lines)'.
Adds to runs2: diff_lines (total diff lines the change has), diff_partial (1 if the reviewer got a partial diff), shown_files, total_files, shown_lines."""
import os, re, sqlite3
HERE = os.path.dirname(os.path.abspath(__file__))
s = sqlite3.connect(os.path.join(HERE, "e4.db"), timeout=120)
cols = {r[1] for r in s.execute("PRAGMA table_info(runs2)")}
for c in ("diff_lines", "diff_partial", "shown_files", "total_files", "shown_lines"):
    if c not in cols:
        s.execute(f"ALTER TABLE runs2 ADD COLUMN {c} INT")
n = ok = 0
for run, head in s.execute("SELECT r.run_id, t.head FROM runs2 r JOIN x_tasks t ON t.run_id=r.run_id AND t.reviewer_index='1'").fetchall():
    n += 1
    m = re.search(r"\n(FULL DIFF \(complete[^\n]*|PARTIAL DIFF[^\n]*)", head or "")
    if not m:
        continue
    line = m.group(1)
    pm = re.search(r"showing (\d+) of (\d+) files \((\d+) of (\d+) total diff lines\)", line)
    fm = re.search(r"(\d+) lines across (\d+) file", line)
    if pm:
        sf, tf, sl, tl = map(int, pm.groups()); part = 1
    elif fm:
        tl = sl = int(fm.group(1)); tf = sf = int(fm.group(2)); part = 0
    else:
        continue
    s.execute("UPDATE runs2 SET diff_lines=?, diff_partial=?, shown_files=?, total_files=?, shown_lines=? WHERE run_id=?", (tl, part, sf, tf, sl, run)); ok += 1
s.commit()
print(f"runs2 rows with a task head: {n}; header parsed: {ok}; partial: {s.execute('select count(*) from runs2 where diff_partial=1').fetchone()[0]}")
