#!/usr/bin/env python3
"""ga-26k2y1 E4 step 3 — quantitative analysis on the mechanical dataset (e4.db). No network, no LLM. Every rate prints its n.
Sections: A weekly/regime pass rates | B first-try pass by size, builder, rig | C story-side traits (univariate + logistic regression with controls)
          D FAIL composition (reviewer vs gate-process) | E rework cost (rounds, wall-clock) | F same-diff noise (same bead+sha, different verdict)
Regime cut = reviewer prompt v2, 2026-09-25 13:04 -03 == 2026-09-25 16:04Z (Dolt timestamps are UTC)."""
import collections, datetime as dt, json, math, os, sqlite3
import numpy as np, pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
CUT = "2026-09-25 16:04:00"
s = sqlite3.connect(f"file:{os.path.join(HERE, 'e4.db')}?mode=ro", uri=True)
out = {}
def wilson(k, n, z=1.96):
    if n == 0: return (float("nan"),) * 2
    p = k / n; d = 1 + z * z / n; c = p + z * z / (2 * n); h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (c - h) / d, (c + h) / d
def fmt(k, n):
    lo, hi = wilson(k, n); return f"{k/n:.3f} [{lo:.3f},{hi:.3f}] n={n}" if n else "n=0"

att = pd.read_sql("select * from attempts", s); att["created_at"] = pd.to_datetime(att["created_at"])
bo = pd.read_sql("select * from bead_out", s); bo["first_ts"] = pd.to_datetime(bo["first_ts"])
bo["post"] = (bo["first_ts"] >= pd.Timestamp(CUT)).astype(int)
bo["difflines"] = bo["size_lines"]
runs = pd.read_sql("select * from runs2", s)
bo = bo.merge(runs[["run_id", "diff_partial"]], left_on="first_run", right_on="run_id", how="left")

# ---------------- A ----------------
print("== A. attempt-level pass rate (PASS / all gate outcomes) by ISO week ==")
att["wk"] = att["created_at"].dt.strftime("%G-W%V")
for wk, g in att.groupby("wk"):
    n = len(g); k = int((g.outcome == "PASS").sum())
    if n >= 40: print(f"  {wk}: {fmt(k, n)}")
pre, post = att[(att.created_at >= "2026-09-18") & (att.created_at < CUT)], att[att.created_at >= CUT]
print(f"  18/09..cut  : {fmt(int((pre.outcome=='PASS').sum()), len(pre))}\n  cut..30/09  : {fmt(int((post.outcome=='PASS').sum()), len(post))}")
print("== A2. bead-level first-try pass by month and regime ==")
for m, g in bo.groupby("month"): print(f"  {m}: {fmt(int(g.first_try_pass.sum()), len(g))}")
for r, g in bo[bo.first_ts >= "2026-09-18"].groupby("post"): print(f"  from 18/09, post={r}: {fmt(int(g.first_try_pass.sum()), len(g))}")
out["first_try_overall"] = [int(bo.first_try_pass.sum()), len(bo)]

# ---------------- B ----------------
eb = bo[bo.difflines.notna()].copy()
eb["sizeb"] = pd.cut(eb.difflines, [0, 200, 800, 3000, 1e9], labels=["<200", "200-799", "800-2999", ">=3000"], right=False)
print(f"\n== B. first-try pass by size (diff lines; Era B beads, n={len(eb)}) ==")
for r in (0, 1):
    for b, g in eb[eb.post == r].groupby("sizeb", observed=True): print(f"  post={r} size {b:9s}: {fmt(int(g.first_try_pass.sum()), len(g))}")
print("  partial diff at first attempt:")
for p, g in eb.groupby("diff_partial"): print(f"    diff_partial={int(p)}: {fmt(int(g.first_try_pass.sum()), len(g))}")
print("  by builder kind (Era B):")
for b, g in eb.groupby("builder_kind"): print(f"    {b:13s}: {fmt(int(g.first_try_pass.sum()), len(g))}")
print("  by rig (all beads):")
for b, g in bo.groupby("rig"): print(f"    {b:4s}: {fmt(int(g.first_try_pass.sum()), len(g))}")

# ---------------- C ----------------
print("\n== C. story-side traits (all beads unless noted; first_try_pass rate) ==")
def uni(col, label=None, data=bo):
    print(f"  -- {label or col}")
    for v, g in data.groupby(col, dropna=False):
        if len(g) >= 15: print(f"     {str(v):12s}: {fmt(int(g.first_try_pass.sum()), len(g))}")
bo["desc_b"] = pd.cut(bo.desc_len, [-1, 300, 800, 1600, 3200, 1e9], labels=["<300", "300-799", "800-1599", "1600-3199", ">=3200"])
bo["paths_b"] = pd.cut(bo.n_paths, [-1, 0, 2, 5, 1e9], labels=["0", "1-2", "3-5", ">=6"])
for c in ("ac_field", "ac_in_desc", "mentions_edge", "mentions_failmode", "external_effect", "refino_swept", "lane", "ctx", "exec", "issue_type", "desc_b", "paths_b"): uni(c)
print("  -- same traits, ONLY post-cut beads")
for c in ("mentions_edge", "ac_in_desc", "external_effect", "desc_b"): uni(c, c + " (post)", bo[bo.post == 1])

def logit(X, y, ridge=1e-3, it=60):
    b = np.zeros(X.shape[1])
    for _ in range(it):
        p = 1 / (1 + np.exp(-np.clip(X @ b, -30, 30))); W = p * (1 - p)
        H = X.T @ (X * W[:, None]) + ridge * np.eye(X.shape[1]); g = X.T @ (y - p) - ridge * b
        step = np.linalg.solve(H, g); b += step
        if np.abs(step).max() < 1e-8: break
    se = np.sqrt(np.diag(np.linalg.inv(H))); return b, se
def design(d, cols):
    X = pd.DataFrame({"const": 1.0}, index=d.index)
    for c in cols:
        if c == "log_size": X[c] = np.log(d.difflines.clip(lower=10))
        elif c == "log_desc": X[c] = np.log1p(d.desc_len)
        elif c == "log_paths": X[c] = np.log1p(d.n_paths)
        elif c in ("lane", "ctx", "exec", "builder_kind", "rig", "issue_type"):
            top = d[c].value_counts(); ref = top.index[0]
            for v in top.index[1:]:
                if top[v] >= 25: X[f"{c}={v}"] = (d[c] == v).astype(float)
        else: X[c] = d[c].astype(float)
    return X
def report(name, d, cols):
    X = design(d, cols); y = d.first_try_pass.values.astype(float); b, se = logit(X.values, y)
    print(f"\n  logistic: {name}  n={len(d)}  base rate={y.mean():.3f}")
    rows = sorted(zip(X.columns, b, se), key=lambda r: -abs(r[1] / r[2]) if r[0] != "const" else 1e9)
    for n, bb, ss in rows: print(f"     {n:22s} OR={math.exp(bb):6.2f}  z={bb/ss:6.2f}" + ("  *" if abs(bb / ss) >= 2 else ""))
    return {n: [float(bb), float(ss)] for n, bb, ss in zip(X.columns, b, se)}
common = ["post", "ac_field", "ac_in_desc", "log_desc", "log_paths", "mentions_edge", "mentions_failmode", "external_effect", "refino_swept", "lane", "ctx", "exec", "issue_type", "rig"]
out["logit_all"] = report("all beads (no size/builder)", bo, common)
out["logit_eraB"] = report("Era-B beads (+ size, builder, partial diff)", eb, common + ["log_size", "diff_partial", "builder_kind"])

# ---------------- D ----------------
print("\n== D. FAIL composition ==")
f = att[att.outcome != "PASS"]
for o, n in f.outcome.value_counts().items(): print(f"  {o:14s} {fmt(n, len(f))}")
print("  FAIL_PROCESS subtypes:", dict(f[f.outcome == "FAIL_PROCESS"].process_subtype.value_counts()))
print("  reviewer FAIL verdicts, blocking issues per verdict (mean):", round(att[att.outcome == "FAIL_REVIEW"].n_blocking.mean(), 2), " share exactly 1:", round((att[att.outcome == "FAIL_REVIEW"].n_blocking == 1).mean(), 3))

# ---------------- E ----------------
print("\n== E. rework cost ==")
nfail = (bo.n_fail_review + bo.n_fail_process)
print(f"  beads gated: {len(bo)}  with >=1 FAIL: {int((nfail>0).sum())} ({(nfail>0).mean():.1%})  total FAIL attempts: {int(nfail.sum())}  (= extra gate rounds + fix cycles)")
print("  distribution of FAILs per bead:", dict(nfail.value_counts().sort_index()))
gaps = []
for (db, b), g in att.sort_values("created_at").groupby(["db", "bead_id"]):
    t = list(g.created_at); o = list(g.outcome)
    for i in range(1, len(t)):
        if o[i - 1] != "PASS": gaps.append((t[i] - t[i - 1]).total_seconds() / 3600)
gp = np.array(gaps)
print(f"  cycle time between a FAIL and the next gate outcome on the same bead: n={len(gp)} median={np.median(gp):.1f}h mean={gp.mean():.1f}h p90={np.percentile(gp,90):.1f}h  SUM={gp.sum():.0f}h (wall-clock; includes queueing and idle waiting, NOT builder effort)")
er = runs[(runs.status == "failed") & runs.elapsed_s.notna()]
print(f"  gate-run elapsed of FAILed runs (Era B): n={len(er)} median={er.elapsed_s.median()/60:.0f}min  SUM={er.elapsed_s.sum()/3600:.0f}h")
out["cycle_hours_sum"] = float(gp.sum()); out["fail_attempts"] = int(nfail.sum())

# ---------------- F ----------------
print("\n== F. same-diff noise: same source bead + same sha reviewed more than once ==")
r2 = runs[runs.sha != ""].copy()
grp = r2.groupby(["source_bead", "sha"])
multi = [(k, g) for k, g in grp if len(g) >= 2 and set(g.verdict) <= {"PASS", "FAIL"} and len(set(g.verdict)) >= 1]
flip = [(k, list(g.sort_values("created_at").verdict)) for k, g in multi if len(set(g.verdict)) > 1]
print(f"  (bead,sha) pairs reviewed >=2 times with a PASS/FAIL verdict each: {len(multi)}; verdict FLIPPED on the same sha: {len(flip)}")
for k, v in flip[:8]: print("    ", k[0], k[1][:9], v)
json.dump(out, open(os.path.join(HERE, "stats_out.json"), "w"), indent=1)
