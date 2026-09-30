#!/usr/bin/env python3
"""ga-26k2y1 E4 — backfill the tri-state columns of the LLM tables from the SAVED raw model output. Makes no model call, no Dolt read, no git read.

Why: the first versions of f6_judge.py / f6_git.py / pairs_judge.py stored a model-reported boolean as int(bool(v)) and a parsed-diff flag as int(bool(v)), so a field the model left out
(or a DIFF header that did not parse) was stored as 0, the same value as an explicit "no". The fixed scripts store NULL (f6_analyze.tri). Re-running the model would change the labels, so this
script only re-reads what the first run saved and rewrites these columns:
  f6_judge_<tag>.same_class   f6_git_<tag>.same_class   pair_out_<tag>.beyond_cited         <- from the raw output  (raw_f6_<tag>/, raw_f6git_<tag>/, raw_pairs_<tag>/ under --raw-dir)
  pair_out_<tag>.pass_partial / fail_partial                                                  <- recomputed from the stored task texts (an unparsed DIFF header is NULL, not 0)
A raw answer is applied to a stored row ONLY when it carries the same label (f6) / the same fix_types and first_time (pairs) as that row: that is the check that the id mapping is right.
Rows whose raw answer is missing or disagrees are counted and printed, and left as they are. Run e4_parse.py and f6_analyze.py first (this script rebuilds the batches from them).

  python3 e4_backfill_tristate.py --raw-dir <dir holding raw_f6_main/ raw_f6git_git/ raw_pairs_main/> [--dry-run]
"""
import argparse, collections, json, os, re, sqlite3, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import f6_judge as J
import pairs_judge as P
from f6_analyze import tri

HERE = os.path.dirname(os.path.abspath(__file__))


def raw_array(path):
    """The JSON array the model answered with (same extraction as the judges), or None when the file is missing / does not parse."""
    try:
        return json.loads(re.search(r"\[\s*\{.*\}\s*\]", open(path, encoding="utf-8").read(), re.S).group(0))
    except (OSError, AttributeError, ValueError):
        return None


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--raw-dir", default=HERE); ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--tag", default="main", help="tag of f6_judge_<tag> / pair_out_<tag>"); ap.add_argument("--git-tag", default="git", help="tag of f6_git_<tag>"); a = ap.parse_args()
    s = sqlite3.connect(os.path.join(HERE, "e4.db"), timeout=120)
    changes = []   # (sql, params), applied at the end
    stat = collections.OrderedDict()   # per column: rows in the table, raw answers that matched the stored row, unmatched, rewritten, rewritten to NULL

    # ---------- f6_judge_<tag>.same_class : rebuild each bead's batch to map the model's local ids (q1..qN) to bi_id ----------
    tasks = {r[0]: r[1] for r in s.execute("select run_id, text from task_full")}
    verdicts = collections.defaultdict(list)
    for run, au, text in s.execute("select run_id, author, text from verdict_full where text like 'VERDICT:%' or author like 'gate-reviewer%'"): verdicts[run].append((text,))
    att = collections.defaultdict(list)
    for r in s.execute("select db, bead_id, comment_id, gate_run from attempts where outcome='FAIL_REVIEW' order by db, bead_id, created_at, rowid"): att[r[1]].append(dict(comment_id=r[2], run=r[3]))
    shas = {r[0]: r[1] for r in s.execute("select run_id, sha from runs2")}
    cur = {r[0]: (r[1], r[2]) for r in s.execute(f"select bi_id, label_raw, same_class from f6_judge_{a.tag}")}
    st = stat.setdefault(f"f6_judge_{a.tag}.same_class", dict(rows=len(cur), matched=0, unmatched=0, changed=0, to_null=0))
    for bead in sorted({r[0] for r in s.execute(f"select distinct bead_id from f6_judge_{a.tag}")}):
        arr = raw_array(os.path.join(a.raw_dir, f"raw_f6_{a.tag}", f"{bead}.txt"))
        rounds = [dict(r, sha=shas.get(r["run"], "?" * 9)) for r in att[bead]]
        issues = J.build(s, bead, rounds, tasks, verdicts)[1]
        # the raw answers of the first run are keyed by the full bi_id (before the short batch-local ids were introduced) or by q1..qN: accept either
        got = {}
        for o in arr or []: got["q" + str(o.get("id")).lstrip("qQ")] = got[str(o.get("id"))] = o
        for it in issues:
            o = got.get(it["sid"]) if it["sid"] in got else got.get(it["bi_id"])
            if it["bi_id"] not in cur: continue
            if o is None or str(o.get("label", "")).upper() != cur[it["bi_id"]][0]: st["unmatched"] += 1; continue
            st["matched"] += 1; new = tri(o.get("same_class_as_earlier"))
            if new != cur[it["bi_id"]][1]:
                st["changed"] += 1; st["to_null"] += new is None
                changes.append((f"update f6_judge_{a.tag} set same_class=? where bi_id=?", (new, it["bi_id"])))

    # ---------- f6_git_<tag>.same_class : the second pass numbers a bead's INDETERMINATE issues q1..qN in the order of f6_judge_<tag> ----------
    ind = collections.defaultdict(list)
    for bi_id, bead in s.execute(f"select bi_id, bead_id from f6_judge_{a.tag} where label='INDETERMINATE'"): ind[bead].append(bi_id)
    cur = {r[0]: (r[1], r[2]) for r in s.execute(f"select bi_id, label_raw, same_class from f6_git_{a.git_tag}")}
    st = stat.setdefault(f"f6_git_{a.git_tag}.same_class", dict(rows=len(cur), matched=0, unmatched=0, changed=0, to_null=0))
    for bead, ids in sorted(ind.items()):
        arr = raw_array(os.path.join(a.raw_dir, f"raw_f6git_{a.git_tag}", f"{bead}.txt"))
        got = {str(o.get("id")).lstrip("qQ"): o for o in arr} if arr else {}
        for n, bi_id in enumerate(ids):
            if bi_id not in cur: continue
            o = got.get(str(n + 1))
            if o is None or str(o.get("label", "")).upper() != cur[bi_id][0]: st["unmatched"] += 1; continue
            st["matched"] += 1; new = tri(o.get("same_class_as_earlier"))
            if new != cur[bi_id][1]:
                st["changed"] += 1; st["to_null"] += new is None
                changes.append((f"update f6_git_{a.git_tag} set same_class=? where bi_id=?", (new, bi_id)))

    # ---------- pair_out_<tag>.beyond_cited (raw answers are keyed by the fail_comment id) ----------
    cur = {r[0]: r[1:] for r in s.execute(f"select fail_comment, fix_types, first_time, beyond_cited from pair_out_{a.tag}")}
    st = stat.setdefault(f"pair_out_{a.tag}.beyond_cited", dict(rows=len(cur), matched=0, unmatched=0, changed=0, to_null=0))
    raw_by_id = {}
    pdir = os.path.join(a.raw_dir, f"raw_pairs_{a.tag}")
    for fn in (sorted(os.listdir(pdir)) if os.path.isdir(pdir) else []):
        for o in raw_array(os.path.join(pdir, fn)) or []: raw_by_id[str(o.get("id"))] = o
    for fc, (ft, first, old) in cur.items():
        o = raw_by_id.get(fc)
        if o is None or json.dumps([t for t in (o.get("fix_types") or []) if t in P.TYPES]) != ft or str(o.get("first_time") or "") != first: st["unmatched"] += 1; continue
        st["matched"] += 1; new = tri(o.get("beyond_cited"))
        if new != old:
            st["changed"] += 1; st["to_null"] += new is None
            changes.append((f"update pair_out_{a.tag} set beyond_cited=? where fail_comment=?", (new, fc)))

    # ---------- pair_out_<tag>.pass_partial / fail_partial : recompute from the task texts ----------
    ptasks = {}
    for run, text in s.execute("select run_id, text from task_full"): ptasks.setdefault(run, text)
    cur = {r[0]: r[1:] for r in s.execute(f"select fail_comment, pass_partial, fail_partial from pair_out_{a.tag}")}
    st = stat.setdefault(f"pair_out_{a.tag}.pass_partial/fail_partial", dict(rows=len(cur), matched=0, unmatched=0, changed=0, to_null=0))
    for bead, fc, fr, pr in s.execute("select bead_id, fail_comment, fail_run, pass_run from pairs"):
        if fc not in cur: continue
        if fr not in ptasks or pr not in ptasks: st["unmatched"] += 1; continue
        m = P.delta_of(ptasks[fr], ptasks[pr])[1]; st["matched"] += 1
        if (m["pass_partial"], m["fail_partial"]) != cur[fc]:
            st["changed"] += 1; st["to_null"] += m["pass_partial"] is None or m["fail_partial"] is None
            changes.append((f"update pair_out_{a.tag} set pass_partial=?, fail_partial=? where fail_comment=?", (m["pass_partial"], m["fail_partial"], fc)))

    for k, v in stat.items(): print(f"{k:45s} rows={v['rows']:4d}  raw answer matched the stored row: {v['matched']:4d}  unmatched (left as is): {v['unmatched']:3d}  rewritten: {v['changed']:3d} (of which to NULL: {v['to_null']})")
    if a.dry_run: print("--dry-run: nothing written"); return
    for sql, params in changes: s.execute(sql, params)
    s.commit(); print(f"wrote {len(changes)} cell(s)")


if __name__ == "__main__":
    main()
