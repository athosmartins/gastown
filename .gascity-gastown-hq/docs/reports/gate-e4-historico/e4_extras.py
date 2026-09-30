#!/usr/bin/env python3
"""ga-26k2y1 E4 step 8 — small extra numbers for the report (pure function of e4.db): dataset counts, multi-label comparability with the 2026-08-12 taxonomy
(docs/gate-analysis/2026-08-12-gate-failure-taxonomy.md counted an issue in every family it touched; e4_final.py counts ONE primary class), verdicts with any D / C issue,
pair breakdown by regime, A/B sample-size arithmetic."""
import json, math, os, sqlite3
import pandas as pd
HERE = os.path.dirname(os.path.abspath(__file__)); CUT = "2026-09-25 16:04:00"
s = sqlite3.connect(f"file:{os.path.join(HERE, 'e4.db')}?mode=ro", uri=True)
q = lambda sql: s.execute(sql).fetchall()
print("== dataset ==")
print("  x_comments by db/kind:", q("select db, kind, count(*) from x_comments group by 1,2"))
print("  attempts by outcome:", q("select outcome, count(*) from attempts group by 1"))
print("  beads gated by rig:", q("select rig, count(*) from bead_out group by 1"), " blocking issues:", q("select count(*) from bi")[0][0], " gate-run beads:", q("select count(*) from runs2")[0][0], " stored tasks:", q("select count(*) from task_full")[0][0])
print("  first/last attempt:", q("select min(created_at), max(created_at) from attempts"))
print("  extraction meta:", json.loads(q("select v from x_meta")[0][0]).get("errors"))
bi = pd.read_sql("select b.bi_id, b.comment_id, c.cls, c.tags, a.created_at from bi b join cls_primary c using(bi_id) join attempts a on a.comment_id=b.comment_id", s)
bi["tags"] = bi.tags.map(json.loads); N = len(bi)
print("\n== multi-label view (an issue counts in every family it carries a tag of) — compare with the 2026-08-12 table (n=443) ==")
fam = {"comment/docstring lies (c.*)": lambda r: any(t.startswith("c.") for t in r.tags) or r.cls == "C",
       "3rd state collapsed (b.empty_read_as_ok / b.error_swallowed_default / b.third_state_other / b.decided_var...)": lambda r: any(t in ("b.empty_read_as_ok", "b.error_swallowed_default", "b.third_state_other", "b.decided_var_not_acted_var") for t in r.tags),
       "test does not catch the bug (d.*)": lambda r: any(t.startswith("d.") for t in r.tags) or r.cls == "D",
       "stale / contradictory state (b.stale_state)": lambda r: "b.stale_state" in r.tags,
       "race / concurrency (b.race_concurrency)": lambda r: "b.race_concurrency" in r.tags,
       "instance vs class (x.fixed_instance_not_class)": lambda r: "x.fixed_instance_not_class" in r.tags,
       "scope (e.*)": lambda r: any(t.startswith("e.") for t in r.tags) or r.cls == "E"}
for k, f in fam.items(): print(f"  {sum(1 for _, r in bi.iterrows() if f(r))/N:5.1%}  {k}")
print("  mean tags per issue:", round(bi.tags.map(len).mean(), 2), "| issues with no tag:", f"{(bi.tags.map(len)==0).mean():.1%}")
v = bi.groupby("comment_id").agg(cls=("cls", list), created=("created_at", "first")).reset_index(); v["post"] = (v.created >= CUT).astype(int)
print("\n== verdict-level: any D / any C / any A ==")
for c in "DCA":
    m = v.cls.map(lambda l, c=c: c in l); print(f"  verdicts with >=1 class-{c} issue: {m.mean():.1%} ({int(m.sum())}/{len(v)})  pre {m[v.post==0].mean():.1%}  post {m[v.post==1].mean():.1%}")
print("\n== pairs by regime (only the pairs with a FULL diff on both sides, as in e4_final.py section 5) ==")
p = pd.read_sql("select p.*, a.created_at from pair_out_main p join attempts a on a.comment_id=p.fail_comment where p.fail_partial = 0 and p.pass_partial = 0", s)   # NULL (unparsed header) fails '= 0': left out
p["post"] = (p.created_at >= CUT).astype(int); p["ft"] = p.fix_types.map(json.loads)
for post, g in p.groupby("post"):
    bc = g.beyond_cited.dropna()   # NULL = the model left the field out: not counted as "no"
    print(f"  post={post} n={len(g)} beyond_cited={bc.mean():.0%} (n={len(bc)}) first_time top: {dict(g.first_time.value_counts().head(3))}")
print("\n== A/B arithmetic (two-proportion, alpha=0.05 two-sided, power 0.80) ==")
def n_per_arm(p1, p2): return math.ceil((1.96 + 0.8416) ** 2 * (p1 * (1 - p1) + p2 * (1 - p2)) / (p1 - p2) ** 2)
post = pd.read_sql("select first_try_pass, first_ts from bead_out where first_ts >= '2026-09-25 16:04:00'", s); base = post.first_try_pass.mean(); days = (pd.Timestamp("2026-09-30 13:00") - pd.Timestamp(CUT)).total_seconds() / 86400
rate = len(post) / days
print(f"  post-cut baseline first-try approval {base:.1%} on {len(post)} beads in {days:.1f} days = {rate:.1f} beads/day")
for d in (0.08, 0.10, 0.15):
    n = n_per_arm(base, base + d); print(f"  detect +{d:.0%}: {n} beads per arm -> {2*n} total -> {2*n/rate:.0f} days at 50/50")

print("\n== headline + second-reviewer experiment arithmetic ==")
bo = pd.read_sql("select n_fail_review, n_fail_process, first_try_pass, first_ts, final from bead_out", s)
print(f"  first gate outcome is PASS: {int(bo.first_try_pass.sum())} of {len(bo)} = {bo.first_try_pass.mean():.1%};  beads with zero FAIL attempts of any kind: {int(((bo.n_fail_review + bo.n_fail_process) == 0).sum())} (the difference = beads that passed first and were gated again later)")
ff = bo[(bo.n_fail_review + bo.n_fail_process) >= 1]; fin = {k: int(v) for k, v in ff.final.value_counts().items()}
print(f"  beads with >=1 FAIL attempt of any kind: {len(ff)}; final state {fin}; passed {fin.get('passed', 0)} of {len(ff)} = {fin.get('passed', 0)/len(ff):.1%}, and {fin.get('passed', 0)} of the {len(ff) - fin.get('open', 0)} that are no longer open")
fb = bo[bo.n_fail_review >= 1]; later = fb.n_fail_review - 1
print(f"  beads with >=1 reviewer FAIL: {len(fb)}; later-round verdicts per such bead: mean {later.mean():.3f}, sd {later.std():.3f}  (too noisy for a count metric)")
for d in (0.15, 0.20):
    nn = math.ceil(2 * later.std() ** 2 * (1.96 + 0.8416) ** 2 / d ** 2); print(f"     count metric, detect -{d:.2f} rounds/bead: {nn} beads per arm")
pc = fb[fb.first_ts >= CUT]; perday = len(pc) / days
p1 = float((fb.n_fail_review >= 2).mean())
print(f"  binary metric 'a bead with a first reviewer FAIL needs a 2nd FAIL round': baseline {p1:.1%} (all), post-cut first-FAIL beads/day = {perday:.1f}")
for d in (0.10, 0.15):
    nn = n_per_arm(p1, p1 - d); print(f"     detect -{d:.0%} ({p1:.1%} -> {p1-d:.1%}): {nn} first-FAIL beads per arm -> {2*nn} total -> {2*nn/perday:.0f} days at 50/50; shadow week ~ {perday*7:.0f} first FAILs")
