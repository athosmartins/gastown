#!/usr/bin/env python3
"""ga-26k2y1 E4 step 7 — CEILINGS per proposal, at VERDICT level and strict: a FAIL verdict counts as covered by a proposal only if EVERY blocking issue in it is in the
proposal's family (one uncovered issue and the verdict still FAILs). A ceiling is what the proposal could prevent if it worked perfectly; the effectiveness is NOT measured here
(it is what the A/B experiment measures). Two different metrics are kept apart on purpose:
  first-try approval   moves only if round-1 FAIL verdicts disappear (builder-side proposals)
  rework rounds        moves if later rounds disappear (reviewer-completeness and gate-mechanics proposals) — first-try approval does NOT move
Reads cls_primary, attempts, bead_out, f6 tables (whichever exist). Pure function of e4.db."""
import collections, json, os, sqlite3
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__)); CUT = "2026-09-25 16:04:00"
s = sqlite3.connect(f"file:{os.path.join(HERE, 'e4.db')}?mode=ro", uri=True)
bi = pd.read_sql("select b.comment_id, b.bead_id, c.cls, c.tags, a.attempt_no, a.created_at from bi b join cls_primary c using(bi_id) join attempts a on a.comment_id=b.comment_id", s)
bi["tags"] = bi.tags.map(json.loads)
v = bi.groupby("comment_id").agg(cls=("cls", list), tags=("tags", lambda x: sorted({t for ts in x for t in ts})), created=("created_at", "first"), bead=("bead_id", "first")).reset_index()
v["post"] = (v.created >= CUT).astype(int); N = len(v)
def share(mask, label, base=v):
    k = int(mask.sum()); print(f"  {label:78s} {k/len(base):6.1%}  ({k}/{len(base)})")
print(f"reviewer FAIL verdicts with classified issues: {N}  (pre-cut {int((v.post==0).sum())}, post-cut {int((v.post==1).sum())})")
def all_in(classes): return lambda cl: all(c in classes for c in cl)
print("\n== strict verdict-level coverage by issue-class family ==")
for lab, fam in (("ONLY class B (edge case / third state)", "B"), ("ONLY class A (behaviour bug)", "A"), ("ONLY class C (statement promises more than code)", "C"), ("ONLY class D (test does not prove it)", "D"),
                 ("only B/C/D (the 'shapes' the reviewer prompt names: third state, misleading comment, vacuous test)", "BCD"), ("only A/B (behaviour + edge cases, no comment/test/scope class)", "AB")):
    m = v.cls.map(all_in(set(fam))); share(m, lab)
    for post in (0, 1): print(f"       {'post' if post else 'pre '}-cut: {m[v.post==post].mean():5.1%} of {int((v.post==post).sum())}")
share(v.cls.map(lambda cl: any(c == "B" for c in cl)), "verdicts with >=1 class-B issue (any)")
share(v.cls.map(lambda cl: any(c in "EFZ" for c in cl)), "verdicts with >=1 E/F/Z issue (scope / speculative / process)")
print("\n== third-state subtags (verdict has >=1) ==")
for t in ("b.empty_read_as_ok", "b.error_swallowed_default", "b.decided_var_not_acted_var", "b.third_state_other", "c.absolute_comment", "d.vacuous_pass", "d.path_not_exercised", "x.external_effect"):
    share(v.tags.map(lambda ts, t=t: t in ts), t)
print("\n== first-try approval vs rework rounds (bead level) ==")
bo = pd.read_sql("select first_outcome, first_try_pass, n_fail_review, n_fail_process, first_ts from bead_out", s); bo["post"] = (bo.first_ts >= CUT).astype(int)
n = len(bo); k = int((bo.first_outcome == "FAIL_PROCESS").sum())
print(f"  beads whose FIRST gate outcome was a gate-process FAIL (no reviewer judged the code): {k}/{n} = {k/n:.1%}  -> first-try approval {bo.first_try_pass.mean():.1%} would be {(bo.first_try_pass.sum() + k*bo.first_try_pass.mean())/n:.1%} if those had been re-run and passed at the base rate")
print(f"  process FAIL attempts overall: {int(bo.n_fail_process.sum())} of {int(bo.n_fail_process.sum() + bo.n_fail_review.sum())} ({bo.n_fail_process.sum()/(bo.n_fail_process.sum()+bo.n_fail_review.sum()):.1%}) — each one a wasted gate cycle + a gate:fix-attempt slot")
for post in (0, 1):
    g = bo[bo.post == post]; print(f"  post-cut={post}: first-try approval {g.first_try_pass.mean():.1%} (n={len(g)}); mean FAIL attempts per bead {(g.n_fail_review+g.n_fail_process).mean():.2f}")
tot_fail_rev = int(bo.n_fail_review.sum())
later = int(bo[bo.n_fail_review >= 2].n_fail_review.sub(1).sum())
print(f"  reviewer FAIL verdicts total {tot_fail_rev}; of them 'later rounds' (2nd, 3rd... on the same bead): {later} ({later/tot_fail_rev:.1%})")
# The Frente 6 ceiling (rounds a complete first review could fold into round 1) is computed in e4_final.py section 4 from the FINAL labels (diff pass + git pass + audit).
