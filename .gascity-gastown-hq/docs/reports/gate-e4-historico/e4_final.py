#!/usr/bin/env python3
"""ga-26k2y1 E4 step 5 — aggregate the LLM-labelled tables into the numbers of the report. Pure function of e4.db (cls_primary, cls_second, f6_judge_main, f6_git_git, f6_audit, pair_out_main
plus the mechanical tables).
Sections: 1 class mix | 2 inter-judge agreement | 3 recurrence (>=3 FAIL beads) vs chance, and class transitions | 4 Frente 6 latent defects | 5 pairs: what the fix added (pairs with a FULL
diff on both sides only) | (the ceilings per proposal are e4_ceilings.py, not here).
Every percentage prints its n. Sections 2, 4 and 5 are skipped, with a message, when their table is missing or empty."""
import collections, itertools, json, math, os, random, sqlite3
import numpy as np, pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
CUT = "2026-09-25 16:04:00"
s = sqlite3.connect(f"file:{os.path.join(HERE, 'e4.db')}?mode=ro", uri=True)
def has(t): return s.execute("select count(*) from sqlite_master where name=?", (t,)).fetchone()[0] > 0
def wilson(k, n, z=1.96):
    if n == 0: return (float("nan"),) * 2
    p = k / n; d = 1 + z * z / n; c = p + z * z / (2 * n); h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)); return (c - h) / d, (c + h) / d
def pct(k, n):
    lo, hi = wilson(k, n); return f"{k/n:5.1%} [{lo:.1%},{hi:.1%}] n={n}" if n else "n=0"
out = {}
def frac(x, n): return x / n if n else float("nan")   # unknown, not 0, when there is nothing to divide by

# ---- base frame: one row per blocking issue with its class ----
bi = pd.read_sql("""select b.bi_id, b.db, b.rig, b.bead_id, b.comment_id, b.created_at, b.month, b.text_len, c.cls, c.tags, c.conf,
                    a.gate_run, a.attempt_no, a.n_blocking from bi b join cls_primary c using(bi_id) join attempts a on a.comment_id=b.comment_id""", s)
bi["post"] = (bi.created_at >= CUT).astype(int); bi["tags"] = bi.tags.map(json.loads)
runs = pd.read_sql("select run_id, diff_lines, diff_partial, author from runs2", s)
bi = bi.merge(runs, left_on="gate_run", right_on="run_id", how="left")
N = len(bi)
print(f"classified blocking issues: {N} of {s.execute('select count(*) from bi').fetchone()[0]}  mean conf={bi.conf.mean():.2f}  share conf<0.6: {pct(int((bi.conf<0.6).sum()), N)}")

# ---------------- 1 ----------------
print("\n== 1. class mix (share of blocking issues) ==")
names = {"A": "A behaviour bug", "B": "B edge case / third state", "C": "C statement promises more than code", "D": "D test does not prove it", "E": "E scope / story", "F": "F speculative", "Z": "Z process / not code"}
for c in "ABCDEFZ": print(f"  {names[c]:38s} {pct(int((bi.cls==c).sum()), N)}")
print("  by period:")
for lab, g in (("pre-cut", bi[bi.post == 0]), ("post-cut", bi[bi.post == 1])):
    print(f"   {lab:9s} n={len(g):4d}  " + "  ".join(f"{c}={100*(g.cls==c).mean():4.1f}%" for c in "ABCDEFZ"))
print("  by month:")
for m, g in bi.groupby("month"): print(f"   {m} n={len(g):4d}  " + "  ".join(f"{c}={100*(g.cls==c).mean():4.1f}%" for c in "ABCDEFZ"))
print("  by rig:")
for m, g in bi.groupby("rig"): print(f"   {m:3s} n={len(g):4d}  " + "  ".join(f"{c}={100*(g.cls==c).mean():4.1f}%" for c in "ABCDEFZ"))
tagc = collections.Counter(t for ts in bi.tags for t in ts)
print("  top subtags (share of issues carrying the tag):")
for t, n in tagc.most_common(22): print(f"     {t:32s} {pct(n, N)}")
out["class_share"] = {c: float((bi.cls == c).mean()) for c in "ABCDEFZ"}; out["tag_counts"] = dict(tagc)

# ---- verdict-level frame ----
v = bi.groupby("comment_id").agg(cls=("cls", list), tags=("tags", lambda x: sorted({t for ts in x for t in ts})), n=("bi_id", "count"), post=("post", "first"), bead=("bead_id", "first"),
                                 rig=("rig", "first"), attempt=("attempt_no", "first"), size=("diff_lines", "first"), created=("created_at", "first")).reset_index()
print(f"\n  verdict-level: {len(v)} reviewer FAIL verdicts carry at least one classified issue; issues per verdict (mean) {v.n.mean():.2f}")

# ---------------- 2 ----------------
if has("cls_second") and s.execute("select count(*) from cls_second").fetchone()[0]:
    d = pd.read_sql("select p.bi_id, p.cls a, s.cls b, p.tags ta, s.tags tb from cls_primary p join cls_second s using(bi_id)", s)
    n = len(d); agree = int((d.a == d.b).sum())
    cats = sorted(set(d.a) | set(d.b)); pa = (d.a == d.b).mean()
    pe = sum(((d.a == c).mean()) * ((d.b == c).mean()) for c in cats); kappa = (pa - pe) / (1 - pe) if pe < 1 else float("nan")
    jac = []
    for x, y in zip(d.ta, d.tb):
        x, y = set(json.loads(x)), set(json.loads(y))
        if x or y: jac.append(len(x & y) / len(x | y))
    print(f"\n== 2. second independent judgement (Opus 5.5 vs Sonnet 5.5): n={n}  class agreement {pct(agree, n)}  Cohen kappa={kappa:.2f}  mean tag Jaccard={np.mean(jac):.2f}")
    conf = d[d.a != d.b].groupby(["a", "b"]).size().sort_values(ascending=False).head(8)
    print("   most frequent disagreements (primary->second):", {f"{a}->{b}": int(k) for (a, b), k in conf.items()})
    out["agreement"] = dict(n=n, agree=agree, kappa=float(kappa))
else:
    print("\n== 2. second independent judgement: cls_second missing or empty — section skipped ==")

# ---------------- 3 ----------------
print("\n== 3. recurrence: beads with >=3 reviewer FAIL rounds (all classified rounds) ==")
seq = v.sort_values("created").groupby("bead").agg(rounds=("comment_id", list), cls=("cls", list), tags=("tags", list), n=("comment_id", "count")).reset_index()
multi = seq[seq.n >= 3]
tot = same_prev = seen_before = tag_seen = tag_prev = cnt = 0
for _, r in multi.iterrows():
    for k in range(1, r.n):
        cnt += 1
        cur, prev, past = set(r.cls[k]), set(r.cls[k - 1]), set().union(*[set(x) for x in r.cls[:k]])
        same_prev += bool(cur & prev); seen_before += bool(cur & past)
        ct, pt, pas = set(r.tags[k]), set(r.tags[k - 1]), set().union(*[set(x) for x in r.tags[:k]])
        tag_prev += bool(ct & pt); tag_seen += bool(ct & pas)
# chance baseline: same procedure, but every round keeps its own number of issues and gets classes / subtags drawn at random from the pooled issues of ALL >=3-round beads
# (so the overall class mix is preserved in expectation, the per-bead structure is not); mean over CHANCE_DRAWS repetitions
CHANCE_DRAWS = 60
rng = random.Random(7); allc = [c for cl in multi.cls for x in cl for c in x]; allt = [t for tl in multi.tags for x in tl for t in x]
def chance():
    sp = sb = tsp = tsb = 0
    for _, r in multi.iterrows():
        sizes = [len(x) for x in r.cls]; tsz = [len(x) for x in r.tags]
        cs = [set(rng.sample(allc, k)) for k in sizes]; ts = [set(rng.sample(allt, k)) if k else set() for k in tsz]
        for k in range(1, r.n):
            sp += bool(cs[k] & cs[k - 1]); sb += bool(cs[k] & set().union(*cs[:k])); tsp += bool(ts[k] & ts[k - 1]); tsb += bool(ts[k] & set().union(*ts[:k]))
    return sp, sb, tsp, tsb
ch = np.array([chance() for _ in range(CHANCE_DRAWS)]).mean(axis=0)
print(f"  beads with >=3 FAIL rounds: {len(multi)}  round transitions (k>=2): {cnt}")
print(f"  round k shares >=1 CLASS with round k-1 : {pct(same_prev, cnt)}   chance baseline {frac(ch[0], cnt):.1%}")
print(f"  round k shares >=1 CLASS with any earlier round: {pct(seen_before, cnt)}   chance baseline {frac(ch[1], cnt):.1%}")
print(f"  round k shares >=1 SUBTAG with round k-1 : {pct(tag_prev, cnt)}   chance baseline {frac(ch[2], cnt):.1%}")
print(f"  round k shares >=1 SUBTAG with any earlier round: {pct(tag_seen, cnt)}   chance baseline {frac(ch[3], cnt):.1%}")
out["recurrence"] = dict(beads=len(multi), transitions=cnt, same_prev=same_prev, seen_before=seen_before, tag_prev=tag_prev, tag_seen=tag_seen, chance=[float(frac(x, cnt)) for x in ch])
def transitions(pop):
    """(round transitions, Counter of (class in round k-1, class in round k), transitions whose round k-1 has a B, transitions whose round k has a B) over the beads of `pop`.
    A transition counts a (class, class) pair once, so B->B / transitions is the share of transitions with a B on both sides."""
    trans, nt, prev_b, cur_b = collections.Counter(), 0, 0, 0
    for _, r in pop.iterrows():
        for k in range(1, r.n):
            nt += 1; prev_b += "B" in r.cls[k - 1]; cur_b += "B" in r.cls[k]
            for a in set(r.cls[k - 1]):
                for b in set(r.cls[k]): trans[(a, b)] += 1
    return nt, trans, prev_b, cur_b
# two populations, each with ITS OWN denominator: the statistics above use the >=3-round beads (`multi`); the >=2-round beads are a larger group (their extra transitions come from beads with exactly 2 rounds)
for lab, pop in ((">=3 FAIL rounds (the population of the statistics above)", multi), (">=2 FAIL rounds", seq[seq.n >= 2])):
    nt, trans, prev_b, cur_b = transitions(pop)
    print(f"  class transitions, beads with {lab}: {len(pop)} beads, {nt} round transitions; top pairs (round k-1 -> round k):", [f"{a}->{b}: {n} of {nt} ({n/nt:.1%})" for (a, b), n in trans.most_common(6)])
    print(f"     B->B {pct(trans[('B', 'B')], nt)}; if a B in round k were independent of a B in round k-1: {prev_b / nt * cur_b / nt:.1%}")
    if pop is multi: out["recurrence"]["bb_transitions"] = dict(n=nt, bb=trans[("B", "B")], expected_if_independent=prev_b / nt * cur_b / nt)

# ---------------- 4 ----------------
if has("f6_judge_main") and s.execute("select count(*) from f6_judge_main").fetchone()[0]:
    j = pd.read_sql("""select j.*, f.round1_view, f.r1_partial, f.rN_partial, f.r1_cov_lines, f.round1_run from f6_judge_main j join f6_issue f using(bi_id)""", s)
    j["src"] = "diff"; j["label_final"] = j.label; j["quotes_ok"] = ((j.r1_line_ok == 1) & (j.rn_line_ok == 1)).astype(int)
    if has("f6_git_git"):
        g = pd.read_sql("select bi_id, label gl, r1_line_ok gr1, rn_line_ok grn, r1_status gst, same_class gsame, r1_file_absent gabs from f6_git_git", s)
        j = j.merge(g, on="bi_id", how="left")
        res = (j.label == "INDETERMINATE") & j.gl.notna() & (j.gl != "INDETERMINATE")
        j.loc[res, "label_final"] = j.loc[res, "gl"]; j.loc[res, "src"] = "git"; j.loc[res, "r1_status"] = j.loc[res, "gst"]; j.loc[res, "same_class"] = j.loc[res, "gsame"]
        j.loc[res, "quotes_ok"] = ((j.loc[res, "gr1"] == 1) & (j.loc[res, "grn"] == 1)).astype(int)
    aud = pd.read_sql("select bi_id, verdict av from f6_audit", s) if has("f6_audit") else pd.DataFrame(columns=["bi_id", "av"])
    j = j.merge(aud, on="bi_id", how="left")
    print(f"   git audit verdicts (diff-only LATENT / INTRODUCED labels): {dict(aud.av.value_counts())}  — UNREADABLE = git could not be read, counted as neither confirmed nor refuted")
    # an INTRODUCED label whose 'new' line is found in a round-1 file is contradicted by git: undecided in the lower bound, counted as a possible LATENT in the upper bound
    contra = (j.label_final == "INTRODUCED") & (j.av == "CONTRADICTED"); n_contra = int(contra.sum()); j.loc[contra, "label_final"] = "INDETERMINATE"
    n = len(j); print(f"\n== 4. FRENTE 6 — later-round blocking issues (Era-B beads with >=2 reviewer FAILs): n={n} issues, {j.bead_id.nunique()} beads ==")
    print("   diff-only judge:", {k: int(x) for k, x in j.label.value_counts().items()})
    print(f"   resolved by the git-grounded second pass: {int((j.src=='git').sum())} of {int((j.label=='INDETERMINATE').sum())} undecided")
    print("   FINAL labels:")
    for lab, k in j.label_final.value_counts().items(): print(f"     {lab:14s} {pct(int(k), n)}")
    lat = j[j.label_final == "LATENT"].copy()
    lat["verified"] = ((lat.src == "git") & (lat.quotes_ok == 1)) | (lat.av == "CONFIRMED")
    print(f"   LATENT: {len(lat)}; verified against git (quotes present at the round-1 AND round-N sha): {int(lat.verified.sum())}; audit NOT_CONFIRMED: {int((lat.av=='NOT_CONFIRMED').sum())}; unaudited/unverified: {int((~lat.verified & (lat.av!='NOT_CONFIRMED')).sum())}")
    intro = j[j.label_final == "INTRODUCED"]
    iv = int((((intro.src == "diff") & (intro.av == "CONFIRMED")) | ((intro.src == "git") & (intro.grn == 1))).sum()) if "grn" in intro else int(((intro.src == "diff") & (intro.av == "CONFIRMED")).sum())
    print(f"   INTRODUCED: {len(intro)}; verified (a quote was checked and is absent from round 1 / present at round N): {iv}; unverified (no usable quote): {len(intro) - iv}")
    print(f"   INTRODUCED labels contradicted by git (the 'new' line already existed in round 1): {n_contra} -> moved to INDETERMINATE above")
    print(f"   LOWER bound LATENT (git-verified only): {pct(int(lat.verified.sum()), n)}   UPPER bound (every LATENT label + the {n_contra} contradicted INTRODUCED): {pct(len(lat) + n_contra, n)}")
    print("   LATENT: round-1 reviewer status:", {k: int(x) for k, x in lat.r1_status.value_counts().items()})
    sc_known = lat.same_class.dropna()   # NULL = the judge left the field out: not counted as "not the same class"
    print(f"   LATENT that are also 'same class as an earlier round': {pct(int(sc_known.sum()), len(sc_known))}  (field missing for {len(lat) - len(sc_known)} of {len(lat)} LATENT: left out of both numerator and denominator)")
    print("   by round of the issue:")
    for r, g in j.groupby("rnd"):
        if len(g) >= 8: print(f"     round {r}: n={len(g):3d}  LATENT {100*(g.label_final=='LATENT').mean():4.1f}%  INTRODUCED {100*(g.label_final=='INTRODUCED').mean():4.1f}%  REPEATED {100*(g.label_final=='REPEATED').mean():4.1f}%  FROM_MAIN {100*(g.label_final=='FROM_MAIN').mean():4.1f}%  INDET {100*(g.label_final=='INDETERMINATE').mean():4.1f}%")
    dl = pd.read_sql("select run_id, diff_lines, diff_partial from runs2", s)
    j = j.merge(dl, left_on="round1_run", right_on="run_id", how="left")
    j["r1size"] = pd.cut(j.diff_lines, [0, 200, 800, 3000, 1e9], labels=["<200", "200-799", "800-2999", ">=3000"], right=False)
    print("   LATENT share (of decided issues = LATENT+INTRODUCED+REPEATED+FROM_MAIN) by ROUND-1 diff size:")
    for b, g in j.groupby("r1size", observed=True):
        d = g[g.label_final != "INDETERMINATE"]
        if len(d): print(f"     {b:9s} {pct(int((d.label_final=='LATENT').sum()), len(d))}   (undecided {int((g.label_final=='INDETERMINATE').sum())} of {len(g)})")
    print("   by round-1 diff partial:", {int(k): pct(int((g[g.label_final != 'INDETERMINATE'].label_final == 'LATENT').sum()), int((g.label_final != 'INDETERMINATE').sum())) for k, g in j.groupby("diff_partial")})
    r1n = pd.read_sql("select a.bead_id, a.n_blocking, a.attempt_no from attempts a where a.outcome='FAIL_REVIEW'", s).sort_values(["bead_id", "attempt_no"]).groupby("bead_id").first().reset_index()
    j = j.merge(r1n[["bead_id", "n_blocking"]].rename(columns={"n_blocking": "r1_nblock"}), on="bead_id", how="left")
    for lab, m in (("round-1 verdict listed exactly 1 blocking issue", j.r1_nblock == 1), ("round-1 verdict listed >=2", j.r1_nblock >= 2)):
        d = j[m & (j.label_final != "INDETERMINATE")]; print(f"     {lab}: LATENT {pct(int((d.label_final=='LATENT').sum()), len(d))}")
    vv = j.groupby(["bead_id", "rnd"]).label_final.agg(list).reset_index(); nv = len(vv)
    al = int(sum(all(x == "LATENT" for x in l) for l in vv.label_final)); anyl = int(sum(any(x == "LATENT" for x in l) for l in vv.label_final))
    print(f"   later-round FAIL VERDICTS: {nv};  containing >=1 LATENT issue: {pct(anyl, nv)};  ENTIRELY latent (round avoidable if round 1 had found it): {pct(al, nv)}")
    eb_fail = int(pd.read_sql("select count(*) c from attempts a join runs2 r on r.run_id=a.gate_run where a.outcome='FAIL_REVIEW'", s).c[0])
    print(f"   entirely-latent rounds = {pct(al, eb_fail)} of ALL Era-B reviewer FAIL verdicts (numerator: only the {j.bead_id.nunique()} judged beads, and a round with any INDETERMINATE issue is not counted; "
          f"whether a complete round-1 review would have caught these defects is what the shadow phase of proposal 2 measures)")
    # cost of the avoidable rounds: wall-clock between the previous outcome on the bead and this FAIL, and the gate run elapsed
    at = pd.read_sql("select a.bead_id, a.comment_id, a.created_at, a.attempt_no, a.gate_run, r.elapsed_s from attempts a left join runs2 r on r.run_id=a.gate_run order by a.bead_id, a.attempt_no", s)
    at["created_at"] = pd.to_datetime(at.created_at); at["prev"] = at.groupby("bead_id").created_at.shift(1); at["gap_h"] = (at.created_at - at.prev).dt.total_seconds() / 3600
    rev = pd.read_sql("select bead_id, comment_id, gate_run from attempts where outcome='FAIL_REVIEW' order by bead_id, created_at, rowid", s); rev["rnd"] = rev.groupby("bead_id").cumcount() + 1
    ent = vv[vv.label_final.map(lambda l: all(x == "LATENT" for x in l))][["bead_id", "rnd"]]
    m = ent.merge(rev, on=["bead_id", "rnd"]).merge(at[["comment_id", "gap_h", "elapsed_s"]], on="comment_id", how="left")
    print(f"   cost of the {len(m)} entirely-latent rounds: cycle time from previous outcome median {m.gap_h.median():.1f} h, SUM {m.gap_h.sum():.0f} h wall-clock (queue+idle included); gate elapsed median {m.elapsed_s.median()/60:.0f} min, SUM {m.elapsed_s.sum()/3600:.0f} h; each also cost one builder fix session")
    out["f6"] = dict(n=n, final=dict(j.label_final.value_counts()), verdicts=nv, any_latent=anyl, all_latent=al, latent_verified=int(lat.verified.sum()), latent_all=len(lat))

# ---------------- 5 ----------------
if has("pair_out_main") and s.execute("select count(*) from pair_out_main").fetchone()[0]:
    pa = pd.read_sql("select * from pair_out_main", s); pa["ft"] = pa.fix_types.map(json.loads)
    full = (pa.fail_partial == 0) & (pa.pass_partial == 0)      # a NULL flag (unparsed DIFF header) is not 0: that pair is not known to be full
    part = (pa.fail_partial == 1) | (pa.pass_partial == 1)
    n_full, n_part = int(full.sum()), int(part.sum()); n_unk = len(pa) - n_full - n_part
    print(f"\n== 5. FAIL -> PASS pairs: {len(pa)} judged = {n_full} with a FULL diff on both sides (analysed) + {n_part} with a PARTIAL diff on >=1 side + {n_unk} with an unparsed DIFF header ==")
    print("   the partial / unparsed pairs are left out: the fix delta is a set difference of the two stored diffs, so the files a partial diff omits would read as added or removed by the fix")
    def pair_summary(p, tag, brief=False):
        n = len(p); c = collections.Counter(t for ts in p.ft for t in ts); ft = p.first_time.value_counts()
        print(f"   -- {tag} (n={n})")
        for t in (("third_state_guard", "edge_case_test", "scope_added", "scope_removed") if brief else [t for t, _ in c.most_common()]): print(f"      fix added {t:20s} {pct(c.get(t, 0), n)}")
        print("      first_time (single fix that would most plausibly have prevented the rejection):", {k: pct(int(x), n) for k, x in (ft.items() if not brief else [("third_state_guard", ft.get("third_state_guard", 0))])})
        bc = p.beyond_cited.dropna(); aa = {k: int(v) for k, v in p.addressed_all.value_counts().items()}
        print(f"      fix went BEYOND the cited example: {pct(int(bc.sum()), len(bc))} (field missing for {n - len(bc)});  addressed all blocking issues: {aa}")
        if not brief: print(f"      delta touches tests only: {pct(int(p.delta_tests_only.sum()), n)}; median delta lines added={int(p.delta_added.median())} removed={int(p.delta_removed.median())}")
        return c, ft
    if n_full:
        c, ft = pair_summary(pa[full].copy(), "FULL-diff pairs (the numbers the report uses)")
        pair_summary(pa, "ALL judged pairs incl. the partial ones (comparison only — contaminated)", brief=True)
        out["pairs"] = dict(n=n_full, n_judged=len(pa), n_partial=n_part, n_unparsed=n_unk, fix_types=dict(c), first_time=dict(ft))
    else:
        print("   no pair with a full diff on both sides: nothing to analyse")
if not (has("f6_judge_main") and s.execute("select count(*) from f6_judge_main").fetchone()[0]): print("\n== 4. FRENTE 6: f6_judge_main missing or empty — section skipped ==")
if not (has("pair_out_main") and s.execute("select count(*) from pair_out_main").fetchone()[0]): print("\n== 5. pairs: pair_out_main missing or empty — section skipped ==")
json.dump(out, open(os.path.join(HERE, "final_out.json"), "w"), indent=1, default=str)
