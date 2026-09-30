#!/usr/bin/env python3
"""ga-26k2y1 E4 step 1 — mechanical extraction of the whole gate history into a small sqlite dataset. READ-ONLY on Dolt.

Sources (all read through the live Dolt sql-server; port is read from the live dolt-config.yaml, never hardcoded):
  x_comments   source-bead comments in hq / whatsapp_automation / property_scrapers / gastown, paged by DAY on created_at
               (a month-wide scan on hq blows the server's 30s read_timeout; a timed-out window is split in halves down to 1 h; a window that still fails at 1 h is
               NOT retried further: it is listed in x_meta -> errors and printed at the end, so a gap is visible, never silent)
                 kind V = 'GATE-FEEDBACK%'          (the FAIL verdict text handed back to the builder)
                 kind P = 'Quality gate PASSED%'     (the merge record: branch, sha, gate_run)
                 kind B = 'Gate FAILED (attempt%'    (dispatcher bookkeeping, one per FAIL — NOT a verdict; it quotes "GATE-FEEDBACK above",
                                                      which is why a substring count of GATE-FEEDBACK is ~2x the number of verdicts)
                 kind X = other '%quality gate FAILED%' (measured only: a completeness check on the V prefix rule)
  x_beads      issues row + labels for every bead that appears in x_comments
  x_runs       hq gate-run beads (label type:quality-gate-run; exist only from 2026-08-18) + their header comment
  x_tasks      reviewer-1 task header per run (Author, Rig, Branch SHA, CHANGED FILES, DIFF SUMMARY) from the verdict bead
               (label gate-run:<id>); only the first HEAD_CHARS of the task are kept — the full diff stays in Dolt and is fetched on demand
Usage: nice -n 10 python3 e4_extract.py [--from 2026-05-15] [--to 2026-10-01] [--out e4.db]
"""
import argparse, datetime as dt, json, os, re, sqlite3, sys, time
import pymysql

CFG = "/Users/athos/gt/.gascity-gastown-hq/.gc/runtime/packs/dolt/dolt-config.yaml"
DBS = ["hq", "whatsapp_automation", "property_scrapers", "gastown"]
HEAD_CHARS = 6000
PORT = int(re.search(r"^\s*port:\s*(\d+)", open(CFG).read(), re.M).group(1))


def connect(db):
    return pymysql.connect(host="127.0.0.1", port=PORT, user="root", database=db, read_timeout=25,
                           connect_timeout=10, autocommit=True, charset="utf8mb4")


class Q:
    """One DB connection with reconnect+retry. A query that keeps failing raises — callers decide, nothing is silently skipped."""
    def __init__(self, db):
        self.db, self.conn, self.errors = db, None, []

    def run(self, sql, args=(), tries=3):
        last = None
        for i in range(tries):
            try:
                if self.conn is None:
                    self.conn = connect(self.db)
                cur = self.conn.cursor()
                cur.execute(sql, args)
                return cur.fetchall()
            except (pymysql.err.OperationalError, pymysql.err.InterfaceError) as e:
                last = e
                try:
                    self.conn.close()
                except Exception:
                    pass   # closing a connection that already died: nothing to recover; the reconnect on the next line is what matters
                self.conn = None
                time.sleep(1.5 * (i + 1))
        raise last


def windows(a, b):
    d, end = dt.datetime.fromisoformat(a), dt.datetime.fromisoformat(b)
    while d < end:
        yield d, min(d + dt.timedelta(days=1), end)
        d += dt.timedelta(days=1)


SQL_COMMENTS = """SELECT id, issue_id, author, created_at,
   CASE WHEN text LIKE 'GATE-FEEDBACK%%' THEN 'V' WHEN text LIKE 'Quality gate PASSED%%' THEN 'P'
        WHEN text LIKE 'Gate FAILED (attempt%%' THEN 'B' ELSE 'X' END, text
   FROM comments WHERE created_at >= %s AND created_at < %s
    AND (text LIKE 'GATE-FEEDBACK%%' OR text LIKE 'Quality gate PASSED%%' OR text LIKE 'Gate FAILED (attempt%%' OR text LIKE '%%quality gate FAILED%%')"""


def fetch_window(q, a, b, depth=0):
    """Rows for [a,b); on repeated timeout split the window (down to 1h) instead of skipping it."""
    try:
        return q.run(SQL_COMMENTS, (a, b))
    except pymysql.err.OperationalError:
        if (b - a) <= dt.timedelta(hours=1) or depth > 5:
            q.errors.append((str(a), str(b)))
            return []
        m = a + (b - a) / 2
        return fetch_window(q, a, m, depth + 1) + fetch_window(q, m, b, depth + 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="a", default="2026-05-15")
    ap.add_argument("--to", dest="b", default="2026-10-01")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "e4.db"))
    args = ap.parse_args()
    if os.path.exists(args.out):
        os.remove(args.out)
    s = sqlite3.connect(args.out)
    s.executescript("""
    CREATE TABLE x_comments(db TEXT, id TEXT PRIMARY KEY, issue_id TEXT, author TEXT, created_at TEXT, kind TEXT, text TEXT);
    CREATE TABLE x_beads(db TEXT, id TEXT, title TEXT, issue_type TEXT, priority INT, status TEXT, assignee TEXT, created_by TEXT,
                         created_at TEXT, closed_at TEXT, description TEXT, acceptance_criteria TEXT, design TEXT, notes_len INT,
                         close_reason TEXT, metadata TEXT, labels TEXT, PRIMARY KEY(db, id));
    CREATE TABLE x_runs(id TEXT PRIMARY KEY, title TEXT, created_at TEXT, closed_at TEXT, status_label TEXT, source_bead TEXT, close_reason TEXT, header TEXT);
    CREATE TABLE x_tasks(run_id TEXT, verdict_bead TEXT, reviewer_index TEXT, verdict_label TEXT, head TEXT);
    CREATE TABLE x_meta(k TEXT, v TEXT);
    """)
    t0 = time.time()
    meta = dict(port=PORT, started=dt.datetime.now(dt.timezone.utc).isoformat(), window=[args.a, args.b], errors={})
    # ---- 1. comments -----------------------------------------------------------------------------------------------
    per_db = {}
    for db in DBS:
        q = Q(db); n = 0
        for a, b in windows(args.a, args.b):
            rows = fetch_window(q, a, b)
            s.executemany("INSERT OR IGNORE INTO x_comments VALUES (?,?,?,?,?,?,?)",
                          [(db, r[0], r[1], r[2], str(r[3]), r[4], r[5]) for r in rows])
            n += len(rows)
            time.sleep(0.03)
        s.commit(); per_db[db] = n; meta["errors"][db] = q.errors
        print(f"[comments] {db:22s} {n:6d} rows  errors={len(q.errors)}  t={time.time()-t0:.0f}s", flush=True)
    # ---- 2. beads + labels for every bead that has any of those comments --------------------------------------------
    for db in DBS:
        ids = [r[0] for r in s.execute("SELECT DISTINCT issue_id FROM x_comments WHERE db=?", (db,))]
        q = Q(db)
        for i in range(0, len(ids), 150):
            chunk = ids[i:i + 150]; ph = ",".join(["%s"] * len(chunk))
            rows = q.run(f"""SELECT id,title,issue_type,priority,status,assignee,created_by,created_at,closed_at,description,acceptance_criteria,
                             design,LENGTH(notes),LEFT(close_reason,600),CAST(metadata AS CHAR) FROM issues WHERE id IN ({ph})""", chunk)
            labs = {}
            for iid, lab in q.run(f"SELECT issue_id,label FROM labels WHERE issue_id IN ({ph})", chunk):
                labs.setdefault(iid, []).append(lab)
            s.executemany("INSERT OR REPLACE INTO x_beads VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                          [(db, r[0], r[1], r[2], r[3], r[4], r[5], r[6], str(r[7]), str(r[8]) if r[8] else None, r[9], r[10], r[11], r[12],
                            r[13], r[14], json.dumps(sorted(labs.get(r[0], [])))) for r in rows])
            time.sleep(0.03)
        s.commit()
        print(f"[beads]    {db:22s} {len(ids):6d} ids  t={time.time()-t0:.0f}s", flush=True)
    # ---- 3. hq gate-run beads (2026-08-18 onward) -------------------------------------------------------------------
    q = Q("hq"); nruns = 0
    for a, b in windows(max(args.a, "2026-08-10"), args.b):
        rows = q.run("""SELECT i.id, i.title, i.created_at, i.closed_at, LEFT(i.close_reason,300),
                          GROUP_CONCAT(l.label SEPARATOR '|')
                        FROM issues i JOIN labels l ON l.issue_id=i.id
                        WHERE i.created_at >= %s AND i.created_at < %s AND i.title LIKE 'gate-run:%%'
                        GROUP BY i.id, i.title, i.created_at, i.closed_at, i.close_reason
                        HAVING SUM(l.label='type:quality-gate-run') > 0""", (a, b))
        for r in rows:
            labs = (r[5] or "").split("|")
            st = next((x for x in labs if x.startswith("gate-status:")), "")
            sb = next((x.split(":", 1)[1] for x in labs if x.startswith("source-bead:")), "")
            hdr = q.run("SELECT LEFT(text, 900) FROM comments WHERE issue_id=%s ORDER BY created_at LIMIT 1", (r[0],))
            s.execute("INSERT OR REPLACE INTO x_runs VALUES (?,?,?,?,?,?,?,?)",
                      (r[0], r[1], str(r[2]), str(r[3]) if r[3] else None, st, sb, r[4], hdr[0][0] if hdr else ""))
            nruns += 1
        time.sleep(0.03)
    s.commit(); meta["errors"]["hq_runs"] = q.errors
    print(f"[runs]     hq gate-run beads {nruns}  t={time.time()-t0:.0f}s", flush=True)
    # ---- 4. reviewer task headers per run --------------------------------------------------------------------------
    run_ids = [r[0] for r in s.execute("SELECT id FROM x_runs")]
    q = Q("hq"); ntask = 0
    for i in range(0, len(run_ids), 40):
        chunk = run_ids[i:i + 40]; ph = ",".join(["%s"] * len(chunk))
        rows = q.run(f"""SELECT lr.label, lr.issue_id, lv.label, c.created_at, SUBSTRING(c.text, 1, {HEAD_CHARS})
                         FROM labels lr JOIN comments c ON c.issue_id = lr.issue_id
                         LEFT JOIN labels lv ON lv.issue_id = lr.issue_id AND lv.label LIKE 'verdict:%%'
                         WHERE lr.label IN ({','.join(['%s'] * len(chunk))}) AND c.text LIKE 'QUALITY GATE REVIEW%%'""",
                     [f"gate-run:{x}" for x in chunk])
        for lab, vb, vl, ca, head in rows:
            m = re.search(r"reviewer (\d+) of (\d+)", head or "")
            s.execute("INSERT INTO x_tasks VALUES (?,?,?,?,?)", (lab.split(":", 1)[1], vb, m.group(1) if m else "", vl or "", head))
            ntask += 1
        time.sleep(0.03)
    s.commit(); meta["errors"]["hq_tasks"] = q.errors
    print(f"[tasks]    reviewer task headers {ntask}  t={time.time()-t0:.0f}s", flush=True)
    meta.update(finished=dt.datetime.now(dt.timezone.utc).isoformat(), comments_per_db=per_db, seconds=round(time.time() - t0))
    s.execute("INSERT INTO x_meta VALUES ('meta', ?)", (json.dumps(meta),)); s.commit()
    print("DONE", json.dumps({k: meta[k] for k in ("comments_per_db", "seconds")}), "errors:", {k: len(v) for k, v in meta["errors"].items()})


if __name__ == "__main__":
    main()
