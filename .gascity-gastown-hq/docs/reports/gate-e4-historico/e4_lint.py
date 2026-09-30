#!/usr/bin/env python3
"""ga-26k2y1 E4 step 6 — how much of the FAIL population could a purely MECHANICAL detector (no LLM) point at? Two measurements per candidate pattern, both on data already in e4.db:
  recall ceiling  share of blocking issues whose own text names the pattern literally (a detector that flags that pattern could have pointed at the site the reviewer cites)
  noise           on the FAIL->PASS pairs with a FULL diff on both sides (pair_out_main.fail_partial = pass_partial = 0; a partial diff scans fewer files, so it would bias the comparison):
                  how many lines the pattern flags per rejected diff and per approved diff, and the share of diffs with >=1 flagged line
The 'names the pattern' regexes on the issue text are deliberately loose: read that column as an UPPER bound.
The rejected and the approved diff of a pair are two versions of ONE change and share most of their added lines, so comparing fire%FAIL with fire%PASS cannot show whether a pattern
discriminates bad from good code; what the noise table does measure is the share of APPROVED diffs a pattern fires on (fire%PASS = how often it would have accused an accepted change).
A pattern that fires on most approved diffs is a poor gate but can still be a useful 'justify this line' prompt.
Only ADDED lines of the diff are scanned (code the change introduces). Comment patterns scan comment-looking added lines only."""
import collections, os, re, sqlite3, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from f6_analyze import parse_task

HERE = os.path.dirname(os.path.abspath(__file__))
s = sqlite3.connect(f"file:{os.path.join(HERE, 'e4.db')}?mode=ro", uri=True)
COMMENT = re.compile(r"^\s*(#|//|\*|/\*|\"\"\"|''')")
CODE_PATTERNS = {
    "shell_swallow (|| true, 2>/dev/null, || echo, || :)": re.compile(r"\|\|\s*true\b|2>\s*/dev/null|\|\|\s*echo\b|\|\|\s*:\s*($|;|\))"),
    "py_broad_except (except Exception / bare except / suppress)": re.compile(r"except\s+Exception\b|except\s*:|contextlib\.suppress|check\s*=\s*False"),
    "js_empty_catch (catch{} / .catch(()=>))": re.compile(r"catch\s*\(\s*\w*\s*\)\s*\{\s*\}|\.catch\(\s*\(\s*\)\s*=>"),
    "empty_default_read (.get(k, 0/''/[]/None), or \"\", // \"\")": re.compile(r"\.get\([^,()]+,\s*(?:0|\"\"|''|None|\[\]|\{\}|False)\s*\)|\bor\s+(?:\"\"|''|0|\[\]|\{\})\b|//\s*\"\""),
    "vacuous_quantifier (all( / any( / .every( / .some()": re.compile(r"\ball\(|\bany\(|\.every\(|\.some\("),
}
COMMENT_PATTERNS = {
    "absolute_word_in_comment (never/always/only/all/every/cannot/nunca/sempre/apenas/todos)": re.compile(r"\b(never|always|only|cannot|impossible|guarantee[sd]?|every|nunca|sempre|apenas|somente|garante|todos|nenhum|jamais)\b", re.I),
}
ALL = {**CODE_PATTERNS, **COMMENT_PATTERNS}
# what to look for in the issue TEXT to count "the reviewer named this pattern"
NAMED = {
    "shell_swallow (|| true, 2>/dev/null, || echo, || :)": re.compile(r"\|\|\s*true|2>\s*/dev/null|\|\|\s*echo|\|\|\s*:"),
    "py_broad_except (except Exception / bare except / suppress)": re.compile(r"except\s+Exception|bare except|except\s*:|suppress|swallow"),
    "js_empty_catch (catch{} / .catch(()=>))": re.compile(r"empty catch|catch\s*\(\s*\w*\s*\)\s*\{\s*\}|\.catch\("),
    "empty_default_read (.get(k, 0/''/[]/None), or \"\", // \"\")": re.compile(r"\.get\(|\bor\s+\"\"|// \"\"|defaults? to (?:0|empty|\"\"|None)|falls? back to (?:0|empty|None)"),
    "vacuous_quantifier (all( / any( / .every( / .some()": re.compile(r"\ball\(\s*\[\s*\]|\ball\(|\bvacuous|passes on an empty|empty (?:list|set|iterable)"),
    "absolute_word_in_comment (never/always/only/all/every/cannot/nunca/sempre/apenas/todos)": re.compile(r"\b(?:never|always|only|cannot|guarantee|every|all)\b[^.\n]{0,60}(?:comment|docstring)|(?:comment|docstring)[^.\n]{0,80}\b(?:never|always|only|cannot|guarantee|every|all)\b|absolute", re.I),
}

# ---- recall ceiling over the whole census ----
issues = [r[0] for r in s.execute("select text from bi")]
print(f"== recall ceiling: blocking issues whose text names the pattern (n={len(issues)}) ==")
for name, rx in NAMED.items():
    k = sum(1 for t in issues if rx.search(t)); print(f"  {k/len(issues):5.1%} ({k:4d})  {name}")
anyk = sum(1 for t in issues if any(rx.search(t) for rx in NAMED.values()))
print(f"  {anyk/len(issues):5.1%} ({anyk:4d})  ANY of the above")

# ---- noise on pairs ----
tasks = {}
for run, text in s.execute("select run_id, text from task_full"): tasks.setdefault(run, text)
try:
    pairs = s.execute("select p.fail_run, p.pass_run from pairs p join pair_out_main o using(fail_comment) where o.fail_partial = 0 and o.pass_partial = 0").fetchall()   # NULL fails '= 0': left out
    n_all = s.execute("select count(*) from pair_out_main").fetchone()[0]
except sqlite3.OperationalError as e:
    sys.exit(f"the pair flags come from pairs_judge.py (pair_out_main): {e}")
stat = {n: dict(f_fire=0, p_fire=0, f_lines=0, p_lines=0) for n in ALL}; used = 0
for fr, pr in pairs:
    if fr not in tasks or pr not in tasks: continue
    used += 1
    for tag, run in (("f", fr), ("p", pr)):
        added = [l for d in parse_task(tasks[run])["files"].values() for l in d["added"]]
        for name, rx in ALL.items():
            pool = [l for l in added if COMMENT.match(l)] if name in COMMENT_PATTERNS else [l for l in added if not COMMENT.match(l)]
            n = sum(1 for l in pool if rx.search(l))
            stat[name][f"{tag}_lines"] += n; stat[name][f"{tag}_fire"] += int(n > 0)
if used == 0:
    sys.exit("no FAIL->PASS pairs with stored diffs in e4.db: run pairs_select.py first")
print(f"\n== noise on {used} FAIL->PASS pairs with a full diff on both sides ({n_all} judged; the rest have a partial or unparsed diff) — added lines of the rejected diff vs the approved diff ==")
print("  fire%PASS is the informative column (how often the pattern would accuse an accepted change); the two versions of one change share most lines, so FAIL vs PASS is not a discrimination test")
print(f"  {'pattern':78s} fire%FAIL fire%PASS  lines/FAILdiff lines/PASSdiff")
for name, v in stat.items():
    print(f"  {name:78s} {v['f_fire']/used:7.0%} {v['p_fire']/used:9.0%}  {v['f_lines']/used:13.1f} {v['p_lines']/used:14.1f}")
