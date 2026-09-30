#!/usr/bin/env python3
"""ga-26k2y1 E4 step 1b — parse the raw extraction (x_* tables in e4.db) into analysis tables. Pure function of e4.db; no network, no Dolt.

  attempts   one row per gate OUTCOME on a source bead: every 'GATE-FEEDBACK' (FAIL) and every 'Quality gate PASSED' comment.
               outcome: PASS | FAIL_REVIEW (>=1 reviewer blocking issue) | FAIL_PROCESS (gate mechanics: merge failed after ALL-PASS,
               SHA fail-closed replay, source bead already closed, rebase, ...) | FAIL_UNSTRUCT (reviewer FAIL without parsable markers)
               attempt_no = position of the outcome among that bead's outcomes ordered by created_at (1 = first time the gate judged it)
  bi         one row per BLOCKING ISSUE (a verdict can carry several, from several reviewers); non-blocking findings are cut off
  runs2      gate-run registry rows joined with the reviewer-1 task header (Author, Branch SHA, files, insertions, deletions) — 2026-08-18+ only
"""
import argparse, hashlib, json, os, re, sqlite3

HERE = os.path.dirname(os.path.abspath(__file__))
RIG = {"hq": "hq", "whatsapp_automation": "wa", "property_scrapers": "ps", "gastown": "gt"}
RX_HDR = re.compile(r"GATE-FEEDBACK \(gate_run=(\S+) branch=([^)]*)\)")
# two PASS comment variants exist for the same merge: 'Quality gate PASSED. Branch X merged to Y (sha=Z) ... (gate_run=R)' and, when the dispatcher declines to close the bead,
# 'Quality gate PASSED and branch X merged to Y (sha=Z) — but NOT closing (...)' (no gate_run). Measured 2026-09-30: 601 of 4,491 PASS rows were the second variant and 600 of them
# duplicated a first-variant row with the same (bead, sha) — counting both inflated attempt-level pass rates by ~13%.
RX_PASS = re.compile(r"Quality gate PASSED(?:\.| and) [Bb]ranch (\S+) merged to (\S+) \(sha=([0-9a-f]{7,40})\)")
RX_GATE_RUN = re.compile(r"gate_run=([^\s)]+)")
RX_RBLOCK = re.compile(r"(?m)^Reviewer (\d+) (FAIL|PASS)[^\n]*?:[ \t]*")
RX_NONBLOCK = re.compile(r"(?im)^\W*(?:\*\*)?(?:non-blocking|nonblocking|what does not block|low confidence)\b")
RX_MARK = re.compile(r"(?im)^[ \t>*_#-]*(?:\*\*)?blocking issue\s*#?(\d+)\b[^\n]*")
PROCESS = [  # (subtype, regex on the text after the header) — order matters, first match wins
    ("merge_failed_after_all_pass", re.compile(r"(?i)merge failed after all-pass|merge result:")),
    ("sha_failclosed_replay", re.compile(r"(?i)already carries a recorded fail verdict|fail-closed by sha")),
    ("source_bead_already_closed", re.compile(r"(?i)source bead \S+ is already closed|already-terminal bead|2-branch race")),
    ("needs_rebase_or_conflict", re.compile(r"(?i)needs-rebase|rebase|merge conflict|conflict")),
    ("reviewer_timeout_or_no_verdict", re.compile(r"(?i)timed out|timeout|no verdict|died before|did not (?:return|deliver)")),
]


def parse_verdict(text):
    """-> (gate_run, branch, outcome, process_subtype, n_reviewers, [(reviewer, k, text, structured)])"""
    m = RX_HDR.search(text[:400])
    gate_run, branch = (m.group(1), m.group(2)) if m else ("", "")
    body = text[m.end():] if m else text
    body = re.sub(r"^[^\n]*\n", "", body, count=1) if m else body   # drop the "quality gate FAILED. Fix THESE..." tail of the header line
    blocks = list(RX_RBLOCK.finditer(body))
    issues = []
    if not blocks:
        sub = next((n for n, rx in PROCESS if rx.search(body)), "other_no_reviewer_text")
        return gate_run, branch, "FAIL_PROCESS", sub, 0, issues
    for i, b in enumerate(blocks):
        seg = body[b.end(): blocks[i + 1].start() if i + 1 < len(blocks) else len(body)]
        if b.group(2) != "FAIL":
            continue
        nb = RX_NONBLOCK.search(seg)
        seg = seg[: nb.start()] if nb else seg
        marks = list(RX_MARK.finditer(seg))
        if marks:
            for j, mk in enumerate(marks):
                t = seg[mk.start(): marks[j + 1].start() if j + 1 < len(marks) else len(seg)].strip()
                issues.append((int(b.group(1)), int(mk.group(1)), t, 1))
        else:
            t = re.sub(r"(?is)^\s*VERDICT:\s*FAIL[^\n]*\n?", "", seg).strip()
            if t:
                issues.append((int(b.group(1)), 1, t, 0))
    nrev = len({r for r, _, _, _ in issues}) or sum(1 for b in blocks if b.group(2) == "FAIL")
    if not issues:
        return gate_run, branch, "FAIL_UNSTRUCT", "", nrev, issues
    out = "FAIL_REVIEW" if any(s for *_, s in issues) else "FAIL_UNSTRUCT"
    return gate_run, branch, out, "", nrev, issues


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--db", default=os.path.join(HERE, "e4.db")); a = ap.parse_args()
    s = sqlite3.connect(a.db)
    s.executescript("""DROP TABLE IF EXISTS attempts; DROP TABLE IF EXISTS bi; DROP TABLE IF EXISTS runs2;
    CREATE TABLE attempts(db TEXT, rig TEXT, bead_id TEXT, comment_id TEXT PRIMARY KEY, created_at TEXT, outcome TEXT, process_subtype TEXT,
                          gate_run TEXT, branch TEXT, n_reviewers_failed INT, n_blocking INT, merge_sha TEXT, attempt_no INT);
    CREATE TABLE bi(bi_id TEXT PRIMARY KEY, db TEXT, rig TEXT, bead_id TEXT, comment_id TEXT, created_at TEXT, month TEXT, reviewer INT, issue_no INT,
                    structured INT, text TEXT, text_len INT);
    CREATE TABLE runs2(run_id TEXT PRIMARY KEY, source_bead TEXT, created_at TEXT, closed_at TEXT, status TEXT, tier TEXT, reviewers_required INT,
                       elapsed_s INT, author TEXT, rig_name TEXT, branch TEXT, sha TEXT, n_files INT, insertions INT, deletions INT, verdict TEXT);""")
    n_v = n_p = 0
    for db, cid, iid, au, ca, kind, text in s.execute("SELECT db,id,issue_id,author,created_at,kind,text FROM x_comments WHERE kind IN ('V','P') ORDER BY created_at").fetchall():
        rig = RIG[db]
        if kind == "P":
            m = RX_PASS.search(text); g = RX_GATE_RUN.search(text)
            s.execute("INSERT INTO attempts VALUES (?,?,?,?,?,?,?,?,?,?,?,?,NULL)", (db, rig, iid, cid, ca, "PASS", "", g.group(1) if g else "", m.group(1) if m else "", 0, 0, m.group(3) if m else "")); n_p += 1
            continue
        gr, br, out, sub, nrev, issues = parse_verdict(text)
        # the dispatcher sometimes pastes the same reviewer text several times into one comment (up to 6x measured): count each distinct issue once
        uniq, seen = [], set()
        for rv, k, t, st in issues:
            h = hashlib.md5(re.sub(r"\s+", " ", t).encode()).hexdigest()[:10]
            if h in seen:
                continue
            seen.add(h); uniq.append((rv, k, t, st, h))
        s.execute("INSERT INTO attempts VALUES (?,?,?,?,?,?,?,?,?,?,?,?,NULL)", (db, rig, iid, cid, ca, out, sub, gr, br, nrev, len(uniq), "")); n_v += 1
        for rv, k, t, st, h in uniq:
            s.execute("INSERT INTO bi VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", (f"{db}:{cid}:{rv}:{k}:{h}", db, rig, iid, cid, ca, ca[:7], rv, k, st, t, len(t)))
    # attempt_no: order of gate outcomes per bead (duplicate PASS records for one merge sha collapse to one)
    # one PASS per (bead, merge sha): keep the variant that carries a gate_run, else the earliest
    s.execute("""DELETE FROM attempts WHERE outcome='PASS' AND merge_sha<>'' AND rowid NOT IN (
                   SELECT rowid FROM (SELECT rowid, ROW_NUMBER() OVER (PARTITION BY db, bead_id, merge_sha ORDER BY (gate_run=''), created_at, rowid) rn
                                      FROM attempts WHERE outcome='PASS' AND merge_sha<>'') WHERE rn=1)""")
    cur = None; n = 0
    for rowid, db, bead in s.execute("SELECT rowid, db, bead_id FROM attempts ORDER BY db, bead_id, created_at, rowid").fetchall():
        n = n + 1 if (db, bead) == cur else 1; cur = (db, bead)
        s.execute("UPDATE attempts SET attempt_no=? WHERE rowid=?", (n, rowid))
    # gate-run registry + reviewer-1 task header
    for rid, title, ca, cl, st, sb, hdr in s.execute("SELECT id,title,created_at,closed_at,status_label,source_bead,header FROM x_runs").fetchall():
        tier = re.search(r"Tier:\s*(\w+)", hdr or ""); rr = re.search(r"Reviewers required:\s*(\d+)", hdr or ""); el = re.search(r"Elapsed:\s*(\d+)s", hdr or "")
        t = s.execute("SELECT head, verdict_label FROM x_tasks WHERE run_id=? ORDER BY reviewer_index LIMIT 1", (rid,)).fetchone()
        head, vl = (t or ("", ""))
        au = re.search(r"Author \(EXCLUDED from reviewing\):\s*(\S+)", head); rg = re.search(r"\nRig:\s*(\S+)", head); sh = re.search(r"Branch SHA:\s*([0-9a-f]{7,40})", head)
        br = re.search(r"reviewer \d+ of \d+ for branch:\s*(\S+)", head); nf = re.search(r"(\d+) files? changed", head)
        ins = re.search(r"(\d+) insertions?\(\+\)", head); dele = re.search(r"(\d+) deletions?\(-\)", head)
        # insertions / deletions: NULL when the stored summary line was cut off (big diffs) — unknown, not 0. Size comes from diff_lines (e4_runs_aug.py).
        s.execute("INSERT INTO runs2 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                  (rid, sb, ca, cl, st.replace("gate-status:", ""), tier.group(1) if tier else "", int(rr.group(1)) if rr else None, int(el.group(1)) if el else None,
                   au.group(1) if au else "", rg.group(1) if rg else "", br.group(1) if br else "", sh.group(1) if sh else "",
                   int(nf.group(1)) if nf else None, int(ins.group(1)) if ins else None, int(dele.group(1)) if dele else None, (vl or "").replace("verdict:", "")))
    s.commit()
    # a header/PASS line that did not parse leaves gate_run='' (the row is kept, but it cannot be joined to runs2): count them so the gap is visible
    print("attempts with an unparsed gate_run:", s.execute("SELECT outcome, COUNT(*) FROM attempts WHERE gate_run='' GROUP BY 1").fetchall())
    for q in ("SELECT outcome, COUNT(*) FROM attempts GROUP BY 1", "SELECT process_subtype, COUNT(*) FROM attempts WHERE outcome='FAIL_PROCESS' GROUP BY 1",
              "SELECT rig, outcome, COUNT(*) FROM attempts GROUP BY 1,2", "SELECT COUNT(*), SUM(structured) FROM bi", "SELECT COUNT(*), SUM(author<>''), SUM(sha<>''), SUM(n_files IS NOT NULL) FROM runs2"):
        print(q[:60], "->", s.execute(q).fetchall())


if __name__ == "__main__":
    main()
