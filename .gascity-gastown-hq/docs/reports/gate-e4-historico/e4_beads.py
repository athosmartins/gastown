#!/usr/bin/env python3
"""ga-26k2y1 E4 step 1c — bead-level outcome + story-side/builder-side features from e4.db (pure function of the dataset).

bead_out: one row per bead that the gate judged at least once (a PASS record or a FAIL verdict inside the extraction window).
  first_try_pass   1 if the FIRST gate outcome on the bead is PASS, 0 if it is any FAIL   (gate-process FAILs included — see fail_kind_first)
  first_review_ok  same, but a FAIL_PROCESS first outcome is dropped from the denominator (no reviewer looked at the code)
  n_fail_review / n_fail_process / attempts_to_pass / final ('passed' | 'needs_human' | 'open')
  builder (Era B: the 'Author (EXCLUDED from reviewing)' in the reviewer task) and builder_kind (crew | pool | dog | other | unknown)
  size_lines (= total DIFF lines incl. context, from the DIFF header) / size_files of the FIRST attempt (Era B only; NULL earlier — declared in the report)
  story-side (known at creation/refino time): desc_len, ac_field, ac_in_desc, n_paths, mentions_edge, mentions_failmode, external_effect, issue_type, priority, lane, ctx, exec, refino_swept
Caveat carried into the report: labels are the CURRENT state of the bead, so only labels that are set before the builder starts (lane:*, ctx:*, exec:*, refino:*) are used as predictors.
"""
import json, os, re, sqlite3

HERE = os.path.dirname(os.path.abspath(__file__))
RX_AC = re.compile(r"(?i)crit[eé]rios? de (?:aceite|aceita[cç][aã]o)|acceptance criteria|\bDoD\b|definition of done|\baceite\b")
RX_EDGE = re.compile(r"(?i)caso[- ]limite|edge[- ]case|\bbordas?\b|\bvazi[oa]s?\b|\bnulo\b|\bnull\b|desconhecid|third[- ]state|terceiro estado|indispon[ií]vel|n[aã]o (?:encontr|houver|existir)")
RX_FAILMODE = re.compile(r"(?i)se (?:falhar|der erro|n[aã]o conseguir|a consulta falhar)|em caso de (?:erro|falha)|fallback|fail[- ]closed|fail[- ]open|quando (?:n[aã]o (?:sabe|h[aá]|houver)|falh)")
RX_PATH = re.compile(r"\b[\w./-]+\.(?:py|js|sh|html|toml|md|sql|json|yaml|yml|plist)\b")
RX_EXTERNAL = re.compile(r"(?i)whapi|pipedrive|whatsapp|\benvi(?:o|ar|a)\b|mensagem|disparo|\bliga[cç]|\bligar\b|\bs3\b|bucket|cobran|\bcusto|\bgasto|publicar|motherduck|outreach|preg[aã]o|assertiva|hex\.tech|\bsms\b|e-?mail")


def kind_of(author, branch=""):
    """crew | pool | dog | mayor_marker | other | unknown.
    The marker's Author field is the identity that ran /gate-done. 44% of Era-B runs carry 'mayor' there (measured), which says nothing about who built the
    change, so 'mayor' is its own stratum unless the branch itself names a crew (crew/<name>/...). Never guessed beyond that."""
    a, b = (author or "").lower(), (branch or "").lower()
    if not a and not b:
        return "unknown"
    if b.startswith("crew/"):
        return "crew"
    if re.search(r"dog", a):
        return "dog"
    if re.search(r"worker|polecat|adhoc|ga-?wisp|^s-ga-wisp", a) and not re.search(r"-(?:wa|ps)-?(?:ga)?wisp", a):
        return "pool"
    if re.search(r"^(?:mila|batista|oracle|thies|digo|peter)", a):
        return "crew"
    if a in ("mayor", "gastown.mayor"):
        return "mayor_marker"
    return "other"


def main():
    s = sqlite3.connect(os.path.join(HERE, "e4.db"))
    s.executescript("DROP TABLE IF EXISTS bead_out;")
    s.execute("""CREATE TABLE bead_out(db TEXT, rig TEXT, bead_id TEXT, title TEXT, issue_type TEXT, priority INT, created_at TEXT, first_ts TEXT, month TEXT,
        n_outcomes INT, n_fail_review INT, n_fail_process INT, n_pass INT, first_outcome TEXT, first_try_pass INT, first_review_ok INT, attempts_to_pass INT, final TEXT,
        builder TEXT, builder_kind TEXT, size_lines INT, size_files INT, first_run TEXT,
        desc_len INT, ac_field INT, ac_in_desc INT, n_paths INT, mentions_edge INT, mentions_failmode INT, external_effect INT,
        lane TEXT, ctx TEXT, exec TEXT, refino_swept INT, needs_human INT, fix_attempt_label INT, PRIMARY KEY(db, bead_id))""")
    runs = {r[0]: r for r in s.execute("SELECT run_id, author, n_files, branch, diff_lines FROM runs2")}
    beads = {(r[0], r[1]): r for r in s.execute("SELECT db,id,title,issue_type,priority,created_at,description,acceptance_criteria,labels,status FROM x_beads")}
    att = {}
    for r in s.execute("SELECT db,bead_id,created_at,outcome,gate_run FROM attempts ORDER BY db,bead_id,created_at,rowid"):
        att.setdefault((r[0], r[1]), []).append(r)
    rig = {"hq": "hq", "whatsapp_automation": "wa", "property_scrapers": "ps", "gastown": "gt"}
    n = skipped = 0
    for (db, bid), rows in att.items():
        b = beads.get((db, bid))
        if not b:
            skipped += 1   # gate outcome on a bead whose issues row was not extracted: counted below, never silently dropped
            continue
        labels = json.loads(b[8] or "[]"); L = set(labels)
        outs = [r[3] for r in rows]
        fr = sum(o == "FAIL_REVIEW" or o == "FAIL_UNSTRUCT" for o in outs); fp = sum(o == "FAIL_PROCESS" for o in outs); pp = sum(o == "PASS" for o in outs)
        first = rows[0]
        passed = pp > 0
        atp = next((i + 1 for i, o in enumerate(outs) if o == "PASS"), None)
        final = "passed" if passed else ("needs_human" if any(l.startswith("gate:needs-human") for l in labels) else "open")
        run = runs.get(first[4])
        builder = run[1] if run else ""
        size = run[4] if run and run[4] is not None else None   # exact diff-line count from the DIFF header (the summary line's insertions/deletions are cut for big diffs)
        desc = (b[6] or ""); ac = (b[7] or "")
        first_ok = 1 if first[3] == "PASS" else 0
        review_ok = None if first[3] == "FAIL_PROCESS" else first_ok
        lab = lambda p: next((l.split(":", 1)[1] for l in labels if l.startswith(p)), "")
        fa = max([int(l.rsplit(":", 1)[1]) for l in labels if l.startswith("gate:fix-attempt:") and l.rsplit(":", 1)[1].isdigit()] or [0])
        s.execute("INSERT INTO bead_out VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                  (db, rig[db], bid, b[2], b[3], b[4], b[5], first[2], first[2][:7], len(rows), fr, fp, pp, first[3], first_ok, review_ok, atp, final,
                   builder, kind_of(builder, run[3] if run else ""), size, run[2] if run else None, first[4],
                   len(desc), int(bool(ac.strip())), int(bool(RX_AC.search(desc))), len(set(RX_PATH.findall(desc))), int(bool(RX_EDGE.search(desc + " " + ac))),
                   int(bool(RX_FAILMODE.search(desc + " " + ac))), int(bool(RX_EXTERNAL.search((b[2] or "") + " " + desc))),
                   lab("lane:"), lab("ctx:"), lab("exec:"), int(any(l.startswith("refino:") for l in labels)),
                   int(any(l.startswith("gate:needs-human") for l in labels)), fa))
        n += 1
    s.commit()
    print("bead_out rows:", n, " skipped (no issues row):", skipped)
    for q in ("SELECT month, COUNT(*), SUM(first_try_pass), ROUND(1.0*SUM(first_try_pass)/COUNT(*),3) FROM bead_out GROUP BY 1 ORDER BY 1",
              "SELECT rig, COUNT(*), ROUND(1.0*SUM(first_try_pass)/COUNT(*),3) FROM bead_out GROUP BY 1",
              "SELECT final, COUNT(*) FROM bead_out GROUP BY 1", "SELECT builder_kind, COUNT(*), ROUND(1.0*SUM(first_try_pass)/COUNT(*),3) FROM bead_out GROUP BY 1",
              "SELECT n_fail_review+n_fail_process nf, COUNT(*) FROM bead_out GROUP BY 1 ORDER BY 1"):
        print(q[:70], "->", s.execute(q).fetchall())


if __name__ == "__main__":
    main()
