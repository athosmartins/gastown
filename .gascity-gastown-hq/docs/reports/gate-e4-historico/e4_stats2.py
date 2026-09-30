#!/usr/bin/env python3
"""ga-26k2y1 E4 step 3b — reviewer coverage and size-normalised risk (no LLM; pure function of e4.db). Uses the exact DIFF-header size (runs2.diff_lines / shown_lines).
A  FAIL rate per run by the share of the diff the reviewer actually received, within size bands (partial diffs are the 'reviewer never saw it' mechanism)
B  first-attempt FAIL probability per 100 diff lines by size bucket — does splitting a big change reduce total rework, or only per-bead FAIL probability?
C  gate-process FAILs (no reviewer judged the code) by period
D  reviewer structure: reviewers per run, review lens, and blocking issues per FAIL verdict by exact diff size ("did the reviewer stop at the first defect?" signal)
E  reviewer timeouts / no verdict (FAIL_PROCESS subtype) by diff size — does the review budget cut big reviews short?"""
import math, os, sqlite3
import numpy as np, pandas as pd
HERE = os.path.dirname(os.path.abspath(__file__)); CUT = "2026-09-25 16:04:00"
s = sqlite3.connect(f"file:{os.path.join(HERE, 'e4.db')}?mode=ro", uri=True)
def wilson(k, n, z=1.96):
    if n == 0: return (float("nan"),) * 2
    p = k / n; d = 1 + z * z / n; c = p + z * z / (2 * n); h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)); return (c - h) / d, (c + h) / d
def pct(k, n): lo, hi = wilson(k, n); return f"{k/n:5.1%} [{lo:.1%},{hi:.1%}] n={n}" if n else "n=0"

r = pd.read_sql("select run_id, source_bead, created_at, verdict, diff_lines, shown_lines, diff_partial from runs2 where verdict in ('PASS','FAIL') and diff_lines is not null", s)
r["cov"] = (r.shown_lines / r.diff_lines).clip(upper=1.0)
r["covb"] = pd.cut(r["cov"], [-0.001, 0.10, 0.50, 0.9999, 1.0], labels=["<10%", "10-49%", "50-99%", "100%"])
r["sizeb"] = pd.cut(r.diff_lines, [0, 200, 800, 3000, 1e9], labels=["<200", "200-799", "800-2999", ">=3000"], right=False)
r["fail"] = (r.verdict == "FAIL").astype(int); r["post"] = (r.created_at >= CUT).astype(int)
print("== A. FAIL rate per run by share of the diff the reviewer received (runs with a PASS/FAIL verdict AND a parsed diff size, n=%d) ==" % len(r))
for c, g in r.groupby("covb", observed=True): print(f"  received {c:7s}: FAIL {pct(int(g.fail.sum()), len(g))}")
print("  ... within size >=800 diff lines (where partial diffs live):")
big = r[r.diff_lines >= 800]
for c, g in big.groupby("covb", observed=True): print(f"     received {c:7s}: FAIL {pct(int(g.fail.sum()), len(g))}   median size {int(g.diff_lines.median())}")
print("  size bands x partial (FAIL rate):")
for b, g in r.groupby("sizeb", observed=True):
    a, p = g[g.diff_partial == 0], g[g.diff_partial == 1]
    print(f"     {b:9s} full {pct(int(a.fail.sum()), len(a))}   |  partial {pct(int(p.fail.sum()), len(p)) if len(p) else 'n=0'}")
print("  runs where the reviewer got <10% of the diff:", int((r["cov"] < 0.10).sum()), "of", len(r), f"({(r['cov'] < 0.10).mean():.2%})")

print("\n== B. first-attempt FAIL probability vs size (Era-B beads) — per bead and per 100 diff lines ==")
b = pd.read_sql("select size_lines, first_try_pass, first_ts from bead_out where size_lines is not null", s)
b["fail"] = 1 - b.first_try_pass; b["sizeb"] = pd.cut(b.size_lines, [0, 200, 800, 3000, 1e9], labels=["<200", "200-799", "800-2999", ">=3000"], right=False); b["post"] = (b.first_ts >= CUT).astype(int)
for post in (0, 1):
    print(f"  post-cut={post}")
    for c, g in b[b.post == post].groupby("sizeb", observed=True):
        pf = g.fail.mean(); per100 = g.fail.sum() / (g.size_lines.sum() / 100)
        print(f"     {c:9s} n={len(g):4d}  P(first attempt FAILs)={pf:.3f}  median lines={int(g.size_lines.median()):5d}  FAILs per 100 diff lines={per100:.3f}  (total lines in bucket={int(g.size_lines.sum())})")
print("  reading: if 'FAILs per 100 diff lines' FALLS with size, the same lines split into small beads would produce MORE first-attempt FAILs, not fewer.")

print("\n== C. gate-process FAILs (no reviewer judged the code) ==")
a = pd.read_sql("select created_at, outcome, process_subtype from attempts where outcome<>'PASS'", s); a["post"] = (a.created_at >= CUT).astype(int)
for post, g in a.groupby("post"): print(f"  post-cut={post}: process FAILs {pct(int((g.outcome=='FAIL_PROCESS').sum()), len(g))} of all FAIL attempts;  " + str(dict(g[g.outcome == 'FAIL_PROCESS'].process_subtype.value_counts())))
tot = a[a.outcome == "FAIL_PROCESS"]
print(f"  overall: {len(tot)} process FAILs of {len(a)} FAIL attempts ({len(tot)/len(a):.1%}); each consumed one gate:fix-attempt slot although no code defect was cited")

print("\n== D. reviewer structure ==")
import re
tk = pd.read_sql("select run_id, reviewer_index, head from x_tasks", s)
of_n = tk["head"].map(lambda h: (re.search(r"reviewer \d+ of (\d+)", h or "") or [None, "?"])[1]); lens = tk["head"].map(lambda h: (re.search(r"YOUR REVIEW LENS:\s*([A-Z][A-Za-z ]+?)[:.(]", h or "") or [None, "?"])[1].strip())
print("  stored reviewer tasks:", len(tk), " 'reviewer i of N' -> N:", dict(of_n.value_counts()), " lens:", dict(lens.value_counts()))
bv = pd.read_sql("select a.n_blocking, r.diff_lines from attempts a join runs2 r on r.run_id=a.gate_run where a.outcome='FAIL_REVIEW' and r.diff_lines is not null", s)
bv["sizeb"] = pd.cut(bv.diff_lines, [0, 200, 800, 3000, 1e9], labels=["<200", "200-799", "800-2999", ">=3000"], right=False)
print(f"  reviewer FAIL verdicts with a known diff size: {len(bv)}; blocking issues per verdict by diff size (share listing exactly 1 issue):")
for b, g in bv.groupby("sizeb", observed=True): print(f"     {b:9s} n={len(g):4d} mean={g.n_blocking.mean():.2f}  exactly one: {pct(int((g.n_blocking == 1).sum()), len(g))}")
print(f"     all sizes: mean={bv.n_blocking.mean():.2f}  exactly one: {pct(int((bv.n_blocking == 1).sum()), len(bv))}")

print("\n== E. reviewer timeout / no verdict by diff size ==")
to = pd.read_sql("""select a.process_subtype, r.diff_lines, r.diff_partial from attempts a join runs2 r on r.run_id=a.gate_run
                    where a.outcome='FAIL_PROCESS' and r.diff_lines is not null""", s)
allr = pd.read_sql("select diff_lines, diff_partial from runs2 where diff_lines is not null", s)
t1 = to[to.process_subtype == "reviewer_timeout_or_no_verdict"]
print(f"  timed-out / no-verdict runs with a known size: {len(t1)}; median diff lines {int(t1.diff_lines.median())} vs {int(allr.diff_lines.median())} for all runs; partial-diff share {t1.diff_partial.mean():.1%} vs {allr.diff_partial.mean():.1%}")
allr["sizeb"] = pd.cut(allr.diff_lines, [0, 200, 800, 3000, 1e9], labels=["<200", "200-799", "800-2999", ">=3000"], right=False)
t1 = t1.assign(sizeb=pd.cut(t1.diff_lines, [0, 200, 800, 3000, 1e9], labels=["<200", "200-799", "800-2999", ">=3000"], right=False))
for b, g in allr.groupby("sizeb", observed=True):
    k = int((t1.sizeb == b).sum()); print(f"     {b:9s} runs={len(g):4d}  timed-out/no-verdict {pct(k, len(g))}")
