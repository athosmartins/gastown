#!/usr/bin/env python3
"""ga-26k2y1 E4 / Frente 6 step 4 — git-grounded second pass for later-round issues the diff-only judge could not decide (INDETERMINATE), plus a mechanical git AUDIT of
the diff-only LATENT / INTRODUCED labels. READ-ONLY git (`git show <sha>:<path>`, `git cat-file -e <sha>^{commit}`); no checkout, no worktree, no writes to any repo.

Second pass: for each INDETERMINATE issue, the cited files are read (if none is cited: the first of the round-N change's files, up to 40, that contain one of the issue's first 6 symbols;
at most 3 are picked, and only the first 2 files are shown) AT the round-1 sha, at the previous round's sha (round >=3) and at the round-N sha; windows of +-16 lines around the best
symbol hits are shown to the same judge prompt (f6_judge.SYSTEM).
Grounding rule (checked here, never trusted from the model): `r1_line` must occur verbatim in one of the files read @round-1-sha and `rn_line` in one of them @round-N-sha; LATENT
without both -> INDETERMINATE (also when git could not be read: unknown is never grounded).
Audit (default --audit 0 = EVERY diff-only LATENT / INTRODUCED label; a positive N audits a seeded sample of N LATENT + N//2 INTRODUCED labels; --audit-only skips the second pass
and so makes no LLM call). Files searched per issue: the files the issue cites + every file of the round-1 change + every file of the round-N change, in that order, capped at
MAX_AUDIT_FILES (issues that hit the cap are counted and printed). A diff-only LATENT label is CONFIRMED when `r1_line` is found in those files at the round-1 sha AND at the round-N
sha, NOT_CONFIRMED when it is missing from either; an INTRODUCED label is CONFIRMED when `rn_line` is found in none of them at the round-1 sha, CONTRADICTED when it is. When a file
could not be read from git and nothing that was read settles the question, the verdict is UNREADABLE — never a default CONFIRMED / NOT_CONFIRMED. See audit_verdict().
Results: tables f6_git_<tag> and f6_audit."""
import argparse, collections, concurrent.futures as cf, json, os, random, re, sqlite3, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from f6_judge import SYSTEM, tokens_of, call
from f6_analyze import parse_task, tri

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = {"whatsapp_automation": "/Users/athos/gt/whatsapp_automation/.repo.git", "property_scrapers": "/Users/athos/gt/property_scrapers/.repo.git"}
DEFAULT_REPO = "/Users/athos/gt/.git"
MAX_AUDIT_FILES = 80
GIT_ENV = {**os.environ, "LC_ALL": "C"}     # the 'path does not exist' message is matched below: keep it in English
UNREADABLE = object()                        # git could not answer — a fact about this tool, NOT about the code (contrast: None = the file is absent at that commit)
_cache = {}
_commit_cache = {}


def _commit_resolves(repo, sha):
    """`git show <sha>:<path>` prints the same 'path ... does not exist in <sha>' for an absent path and for a sha that is not in the repo at all, so ask about the commit first."""
    k = (repo, sha)
    if k not in _commit_cache:
        try:
            _commit_cache[k] = subprocess.run(["git", "--git-dir", repo, "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True, timeout=40, env=GIT_ENV).returncode == 0
        except subprocess.TimeoutExpired:
            _commit_cache[k] = False
    return _commit_cache[k]


def show(repo, sha, path):
    """File content at a commit: str | None (the commit resolves and git says the path does not exist there) | UNREADABLE (unknown commit, missing repo, timeout, any other git error).
    The two non-str results are never merged: 'absent at that sha' is a fact about the code, UNREADABLE only says this tool could not look."""
    k = (repo, sha, path)
    if k not in _cache:
        if not _commit_resolves(repo, sha):
            _cache[k] = UNREADABLE
        else:
            try:
                r = subprocess.run(["git", "--git-dir", repo, "show", f"{sha}:{path}"], capture_output=True, timeout=40, env=GIT_ENV)
            except subprocess.TimeoutExpired:
                _cache[k] = UNREADABLE
            else:
                if r.returncode == 0: _cache[k] = r.stdout.decode("utf-8", "replace")
                elif b"does not exist in" in r.stderr or b"exists on disk, but not in" in r.stderr: _cache[k] = None
                else: _cache[k] = UNREADABLE
    return _cache[k]


def text_of(x): return x if isinstance(x, str) else None   # a show() result as plain text: absent and UNREADABLE both give None


def norm(x): return re.sub(r"\s+", " ", x or "").strip()


def file_windows(text, toks, ctx=16, max_w=3):
    lines = text.split("\n")
    hits = [(sum(1 for t in toks if t in l), i) for i, l in enumerate(lines)]
    hits = [h for h in hits if h[0]]
    if not hits: return "(no cited symbol occurs in this file version)"
    picked = []
    for sc, i in sorted(hits, key=lambda h: (-h[0], h[1])):
        if any(abs(i - u) <= ctx for u in picked): continue
        picked.append(i)
        if len(picked) >= max_w: break
    return "\n...\n".join("\n".join(f"{j+1:5d}| {lines[j][:150]}" for j in range(max(0, i - ctx), min(len(lines), i + ctx + 1))) for i in sorted(picked))[:4200]


def changed_files(task_text):
    """Full path list of the change: the CHANGED FILES block (measured on the 832 stored tasks: its length equals the header's total_files in all 832; a task without the block
    falls back to the parsed diff files + the OMITTED FILES list), because the diff sections are empty for the 'PARTIAL DIFF ... showing 12 of 3108 lines' tasks."""
    m = re.search(r"CHANGED FILES:\n(.*?)\n\s*\n\s*DIFF SUMMARY:", task_text, re.S)
    listed = [l.strip() for l in m.group(1).splitlines() if l.strip()] if m else []
    d = parse_task(task_text)
    seen, out = set(), []
    for f in listed + list(d["files"]) + d["omitted"]:
        if f not in seen:
            seen.add(f); out.append(f)
    return out


def quote_norm(x):
    """quotes come from diff lines: drop the leading +/- marker and collapse whitespace before looking them up in a file at a sha"""
    return norm(re.sub(r"^[+\-]", "", (x or "").strip(), count=1))


def contains(repo, sha, files, quote):
    """Is the normalised `quote` inside any of `files` as they are at `sha`?  True | False | None.
    None = no readable file contains it AND at least one file could not be read (UNREADABLE): 'not found' cannot be concluded. A file git says is absent at the sha simply does not contain it.
    An empty quote is never found (False)."""
    q = quote_norm(quote)
    if not q: return False
    unreadable = False
    for f in files:
        t = show(repo, sha, f)
        if t is UNREADABLE: unreadable = True
        elif t is not None and q in norm(t): return True
    return None if unreadable else False


def audit_verdict(label, a1, an, b1, rn_quote):
    """The audit's decision as a pure function. a1 / an: `r1_line` found in the files at the round-1 / round-N sha; b1: `rn_line` found in the files at the round-1 sha —
    each True / False / None (None = unreadable, cannot say). label: the diff-only label being audited (LATENT | INTRODUCED)."""
    if label == "LATENT":
        if a1 is True and an is True: return "CONFIRMED"
        if a1 is False or an is False: return "NOT_CONFIRMED"
        return "UNREADABLE"
    if not quote_norm(rn_quote): return "NO_QUOTE"        # nothing to look up: an empty quote can neither confirm nor contradict "introduced later"
    if b1 is True: return "CONTRADICTED"
    if b1 is None: return "UNREADABLE"
    return "CONFIRMED"


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--tag", default="git"); ap.add_argument("--model", default="sonnet"); ap.add_argument("--effort", default="high")
    ap.add_argument("--workers", type=int, default=2); ap.add_argument("--limit", type=int, default=0); ap.add_argument("--audit", type=int, default=0, help="0 = audit every LATENT/INTRODUCED label"); ap.add_argument("--src", default="main")
    ap.add_argument("--audit-only", action="store_true", help="skip the git-grounded second pass (no LLM call) and re-run only the mechanical audit"); a = ap.parse_args()
    s = sqlite3.connect(os.path.join(HERE, "e4.db"), timeout=120)
    s.execute(f"""CREATE TABLE IF NOT EXISTS f6_git_{a.tag}(bi_id TEXT PRIMARY KEY, bead_id TEXT, rnd INT, label_raw TEXT, label TEXT, ungrounded INT, r1_status TEXT, same_class INT,
                  r1_line TEXT, rn_line TEXT, r1_line_ok INT, rn_line_ok INT, conf REAL, why TEXT, files_read TEXT, r1_file_absent INT)""")
    s.execute("CREATE TABLE IF NOT EXISTS f6_audit(bi_id TEXT PRIMARY KEY, label TEXT, kind TEXT, r1_line_in_r1_file INT, r1_line_in_rn_file INT, rn_line_in_r1_file INT, verdict TEXT)")
    os.makedirs(os.path.join(HERE, f"raw_f6git_{a.tag}"), exist_ok=True)
    tasks = {r[0]: r[1] for r in s.execute("select run_id, text from task_full")}
    runinfo = {r[0]: r[1:] for r in s.execute("select run_id, sha, rig_name from runs2")}
    att = collections.defaultdict(list)
    for r in s.execute("select bead_id, comment_id, gate_run from attempts where outcome='FAIL_REVIEW' order by db, bead_id, created_at, rowid"):
        att[r[0]].append(dict(comment_id=r[1], run=r[2]))
    fi = {r[0]: r for r in s.execute("select bi_id, cited, round1_run, gate_run, round from f6_issue")}
    itext = {r[0]: r[1] for r in s.execute("select bi_id, text from bi")}
    verd = collections.defaultdict(list)
    for run, text in s.execute("select run_id, text from verdict_full where text like 'VERDICT:%' or author like 'gate-reviewer%'"): verd[run].append(text)
    done = {r[0] for r in s.execute(f"select bi_id from f6_git_{a.tag}")}
    ind = [] if a.audit_only else [r for r in s.execute(f"select bi_id, bead_id, rnd from f6_judge_{a.src} where label='INDETERMINATE'") if r[0] not in done]
    if a.limit: ind = ind[: a.limit]
    byb = collections.defaultdict(list)
    for bi_id, bead, rnd in ind: byb[bead].append((bi_id, rnd))
    print(f"[f6git] INDETERMINATE issues to re-judge with git: {len(ind)} in {len(byb)} beads", flush=True)

    def evidence(bi_id, rounds):
        _, cited, r1run, nrun, rnd = fi[bi_id]
        r1sha, rig = runinfo[r1run][0], runinfo[r1run][1]; nsha = runinfo[nrun][0]; repo = REPO.get(rig, DEFAULT_REPO)
        prev = rounds[rnd - 2]; psha = runinfo[prev["run"]][0]
        toks = tokens_of(itext[bi_id])
        files = [f for f in (cited or "").split(",") if f]
        if not files:   # no file cited: files of round N whose content contains the symbols
            for f in changed_files(tasks[nrun])[:40]:
                t = text_of(show(repo, nsha, f))
                if t and any(tok in t for tok in toks[:6]): files.append(f)
                if len(files) >= 3: break
        blocks, absent = [], 0
        for f in files[:2]:
            texts = {"r1": show(repo, r1sha, f), "rN": show(repo, nsha, f)}
            if rnd >= 3 and psha != r1sha: texts["prev"] = show(repo, psha, f)
            if texts["r1"] is None: absent += 1
            for lab, t in texts.items():
                nm = {"r1": f"ROUND-1 (sha {r1sha[:9]})", "prev": f"ROUND-{rnd-1} (sha {psha[:9]})", "rN": f"ROUND-{rnd} (sha {nsha[:9]})"}[lab]
                blocks.append(f"[{f} @ {nm}]\n" + ("(FILE DOES NOT EXIST at this sha)" if t is None else "(this file version COULD NOT BE READ from git)" if t is UNREADABLE else file_windows(t, toks)))
        return files, blocks, absent, repo, r1sha, nsha

    def work(bead):
        rounds = att[bead]; parts, meta = [], {}
        sid_of = {bi_id: f"q{n + 1}" for n, (bi_id, _) in enumerate(byb[bead])}   # short ids: the model mangles 60-char composite ids
        for bi_id, rnd in byb[bead]:
            files, blocks, absent, repo, r1sha, nsha = evidence(bi_id, rounds)
            meta[bi_id] = (files, absent, repo, r1sha, nsha)
            parts.append(f'<conteudo_externo id="{sid_of[bi_id]}">\nROUND {rnd} blocking issue:\n{itext[bi_id][:2600]}\n\nFILES READ FROM GIT: {", ".join(files) or "(none found)"}\n' + "\n\n".join(blocks) + "\n</conteudo_externo>")
        r1v = "\n---\n".join(verd.get(rounds[0]["run"], []))[:4800] or "(round-1 verdict text not stored)"
        prompt = (f"Bead {bead}. The FILE WINDOWS below are read directly from git at each round's sha (full files, not diffs), so an unchanged line appearing at both shas is proof the code existed in round 1.\n\n"
                  f"<conteudo_externo id=\"round1-reviewer-verdict\">\nROUND-1 REVIEWER'S FULL VERDICT:\n{r1v}\n</conteudo_externo>\n\nJudge each of the {len(byb[bead])} issues.\n\n" + "\n\n".join(parts))
        last = None
        for _ in range(2):
            try:
                out, cost = call(a.model, a.effort, prompt)
                open(os.path.join(HERE, f"raw_f6git_{a.tag}", f"{bead}.txt"), "w", encoding="utf-8").write(out)
                arr = json.loads(re.search(r"\[\s*\{.*\}\s*\]", out, re.S).group(0)); raw = {str(o.get("id")).lstrip("qQ"): o for o in arr}   # the model sometimes answers "1" for "q1"
                if any(sid_of[b].lstrip("q") not in raw for b, _ in byb[bead]): raise ValueError("missing ids")
                got = {b: raw[sid_of[b].lstrip("q")] for b, _ in byb[bead]}
                return bead, got, meta, cost
            except Exception as e:  # noqa: BLE001
                last = e; time.sleep(3)
        return bead, last, meta, 0.0
    total = 0.0
    with cf.ThreadPoolExecutor(max_workers=a.workers) as ex:
        for bead, got, meta, cost in ex.map(work, sorted(byb)):
            if isinstance(got, Exception): print(f"  {bead} FAILED: {got}", flush=True); continue
            total += cost
            for bi_id, rnd in byb[bead]:
                o = got[bi_id]; files, absent, repo, r1sha, nsha = meta[bi_id]; lab = str(o.get("label", "")).upper()
                ok1 = okn = False
                if o.get("r1_line") and o.get("rn_line"):
                    ok1 = contains(repo, r1sha, files, o["r1_line"]) is True     # None (unreadable) is not grounding either
                    okn = contains(repo, nsha, files, o["rn_line"]) is True
                fin, ung = (("INDETERMINATE", 1) if lab == "LATENT" and not (ok1 and okn) else (lab, 0))
                s.execute(f"INSERT OR REPLACE INTO f6_git_{a.tag} VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                          (bi_id, bead, rnd, lab, fin, ung, str(o.get("r1_reviewer_status") or ""), tri(o.get("same_class_as_earlier")), str(o.get("r1_line") or "")[:400], str(o.get("rn_line") or "")[:400],
                           int(ok1), int(okn), float(o.get("conf") or 0), str(o.get("why") or "")[:300], ",".join(files), int(absent > 0)))
            s.commit(); print(f"  {bead}: {dict(collections.Counter(str(got[b].get('label')) for b, _ in byb[bead]))} cost=${cost:.2f} total=${total:.2f}", flush=True)
    print(f"[f6git] second pass finished total=${total:.2f}", flush=True)

    # ---- mechanical audit of the diff-only labels (no LLM) ----
    rng = random.Random(3009)
    rows = s.execute(f"select j.bi_id, j.label, j.r1_line, j.rn_line, f.round1_run, f.gate_run, f.cited from f6_judge_{a.src} j join f6_issue f using(bi_id) where j.label in ('LATENT','INTRODUCED')").fetchall()
    lat = [r for r in rows if r[1] == "LATENT"]; intro = [r for r in rows if r[1] == "INTRODUCED"]
    pick = (lat + intro) if a.audit == 0 else (rng.sample(lat, min(a.audit, len(lat))) + rng.sample(intro, min(a.audit // 2, len(intro))))
    capped = 0
    for bi_id, lab, r1l, rnl, r1run, nrun, cited in pick:
        r1sha, rig = runinfo[r1run][0], runinfo[r1run][1]; nsha = runinfo[nrun][0]; repo = REPO.get(rig, DEFAULT_REPO)
        # cited files first (the cap never drops them), then every file of the round-1 change, then every file of the round-N change
        files = list(dict.fromkeys([f for f in (cited or "").split(",") if f] + changed_files(tasks[r1run]) + changed_files(tasks[nrun])))
        if len(files) > MAX_AUDIT_FILES: capped += 1; files = files[:MAX_AUDIT_FILES]
        a1, an, b1 = contains(repo, r1sha, files, r1l), contains(repo, nsha, files, r1l), contains(repo, r1sha, files, rnl)
        verdict = audit_verdict(lab, a1, an, b1, rnl)
        s.execute("INSERT OR REPLACE INTO f6_audit VALUES (?,?,?,?,?,?,?)", (bi_id, lab, "git", tri(a1), tri(an), tri(b1), verdict))   # NULL = unreadable, not 0
    s.commit()
    print(f"[audit] issues audited: {len(pick)}; file list hit the {MAX_AUDIT_FILES}-file cap: {capped}")
    for lab in ("LATENT", "INTRODUCED"):
        r = s.execute("select verdict, count(*) from f6_audit where label=? group by 1", (lab,)).fetchall(); print(f"[audit] {lab}: {dict(r)}")


if __name__ == "__main__":
    main()
