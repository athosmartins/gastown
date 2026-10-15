#!/usr/bin/env python3
"""gate-lane-tally.py — ga-atsahv item 4: how many gate rounds the DOC/TEST fast lane saved.

Reads .gc/quality-gate.jsonl (read-only). Two event kinds matter:
  gate_lane            one per lane decision (lane fast|normal, reason, reason_code, counts, the files that
                       decided, would_have_reviewers = what a normal run of that diff would have spent) —
                       written by gate-fastlane.lib.sh at the lane decision (or by the dispatcher itself when that lib is
                       not loaded). A DRY_RUN=1 sweep writes the event too, with dry_run=1; it is not counted.
  dispatcher_complete  one per finished run; carries `lane` and the PASS/FAIL result

Headline numbers (window = last --days):
  * diffs evaluated (the LAST decision per marker — a marker re-claimed three times is one diff, not three)
  * how many took the fast lane vs the normal gate
  * reviewer runs saved = for each fast run that COMPLETED AND PASSED, the reviewers a normal run would have used,
    taken from the decision that was in effect when that run happened (a fast run that did not merge saved nothing —
    its diff is gated again — and a marker re-decided later does not rewrite what an earlier run saved)
  * lanes granted and then REVOKED at the push (gate_lane events with reason_code revoked-at-push): the diff that was
    about to land was not the diff the lane had checked, so the marker went back to the normal gate. Counted per
    event, not per marker — the re-decision that follows replaces the marker's last lane, and must not hide this
  * of the diffs that went to the normal gate: how many were doc/test-only but bounced by a mechanical check
    (scan finding / test failed / test with no runner / unscannable) — the number that says whether the lane's
    checks are too tight
No bead is mailed and no bead ID is hardcoded: a previous weekly gate report was disabled for mailing a
settled question to a bead that no longer existed. --weekly appends one line to a history file and sends ONE
notify line, and only if the window held at least one decision OR a signal that something happened without
one (unreadable log lines, fast runs that completed with no gate_lane event, revoked lanes — see SIGNALS).

What counts as an UNREADABLE line (the number that says the tally may be under-counting): a line that claims to be
ours — it opens with {"ts" (compact or spaced) or names gate_lane / dispatcher_complete — and cannot be read, AND sits
inside the window. "Inside the window" is the line's own ts when it has a readable one, otherwise its place in the
append-only log (the ts of the last dated line before it). A line that is not ours and carries no ts — a lone "{" or
"}", a key line of a pretty-printed object, a line of prose — cannot be placed by a ts and is not damage of ours: it is
counted apart as undatable_lines, shown as information, and is never a signal. The live log opens with 20 such lines
(two pretty-printed guard events from before the producers wrote one object per line); counting them as damage made
the weekly cry wolf on every run, forever, and left the damage counter unable to tell 20 from 21.

A window with zero decisions has two meanings and they must not read alike: nothing happened (quiet, no
history line, no notify) or something happened that the decisions cannot show — every gate_lane line truncated
by a disk-full append, or the producer stopped while fast runs kept merging. The second is reported loudly.

The task-rapida lane (ga-dzzqvw) has its own section, built from the same log: grants (the LAST decision per marker), why the others were
not granted (tr_code), the FIRST review of each granted marker and how long it took, and the bugs opened after a grant that cite its task.
Only a run that ended with PASS or FAIL is a review; one the dispatcher closed with neither (SKIPPED_BEAD_CLOSED...) is counted apart and
never enters the first-review counts or the median. The bug count is a number ONLY when every grant was looked up: in the HQ store and in the
store of its own rig (from `gc rig list`, by the rig on the event) — a grant with no bead id, no rig, a rig whose store does not resolve or a
store that cannot be read makes it null ("could not tell"), with how many and why; what the other grants turned up is kept as a floor.

exit 0  tallied. A window with zero decisions and no signal is a valid, quiet tally and says so; zero decisions
        WITH a signal is tallied too, but as a warning (report, history line, notify), never as "nothing happened"
exit 2  could not tally — log missing/unreadable. NOT "0 saved": error and empty must not look the same.
"""
import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys

DEFAULT_CITY = os.environ.get("GC_CITY_PATH") or "/Users/athos/gt/.gascity-gastown-hq"

# reason_code -> (bucket, bounced_by_a_mechanical_check). The CODES are the contract with the producers
# (gate-fastlane.lib.sh sets GATE_LANE_REASON_CODE on every decision; the dispatcher sets no-changed-files, decision-errored and lib-not-loaded itself).
# This used to match a substring of the free-text reason — and drifted: the lib's sentence changed, the needle
# never matched again, and every code/prompt diff (~96% of decisions) was reported as "touches the gate's own
# policy". gate-lane-tally.selftest.sh fails when a code a producer emits is not here (or a code here has no producer);
# gate-fastlane.selftest.sh §4e runs the REAL decision through the REAL tally and fails on a wrong bucket.
REASON_CODES = {
    "code-or-prompt":   ("tem arquivo de código ou prompt/doutrina", False),
    "scan-findings":    ("só doc/teste, barrado pelo scan (dado pessoal/segredo)", True),
    "scan-failed":      ("só doc/teste, scan não rodou", True),
    "history-code":     ("só doc/teste no resultado final, mas um commit do histórico mexe em código/prompt (e um commit posterior desfez)", True),
    "history-unverified": ("só doc/teste, mas o histórico de commits não pôde ser verificado (commits demais, merge com conteúdo, git falhou)", True),
    "test-failed":      ("só doc/teste, teste novo não passou/não rodou", True),
    "test-unrunnable":  ("só doc/teste, teste sem runner (js/ts/go...)", True),
    "unclassifiable":   ("diff inclassificável (symlink, caminho com aspas, vazio...)", False),
    "diff-raw-failed":  ("git não conseguiu listar o diff", False),
    "policy":           ("mexe na política do próprio gate", False),
    "disabled":         ("fast-lane desligado (variável de ambiente)", False),
    "flag-file":        ("fast-lane desligado (arquivo .gc/gate-fastlane.off)", False),
    "switch-unreadable": ("fast-lane sem como achar o interruptor (GC_CITY e GATE_FASTLANE_OFF_FILE vazios)", False),
    "no-input":         ("fast-lane sem runner/base/head para decidir", False),
    "no-changed-files": ("lista de arquivos do dispatcher vazia (erro de git ou diff vazio)", False),
    "decision-errored": ("decisão da fast-lane deu erro", False),
    "lib-not-loaded":   ("lib da fast-lane não carregou", False),
    "revoked-at-push":  ("fast-lane concedida e revogada no push (o diff mudou ou deixou de ser elegível)", False),
    "not-evaluated":    ("fast-lane não chegou a avaliar", False),
}
_NO_CODE = "sem reason_code no evento"
_UNKNOWN_CODE = "outro (reason_code desconhecido)"

# tr_code -> label: the codes of the task-rapida lane (ga-dzzqvw). The lane writes its own answer to tr_code on the gate_lane event and
# never to reason_code, so the fast lane's buckets above cannot be moved by it. Same codes, same words as gate_taskrapida_codes in
# gate-taskrapida.lib.sh; gate-taskrapida.selftest.sh fails when the two lists drift.
TR_REASON_CODES = {
    "granted":           "concedida: task pequena, fora da lista de risco",
    "disabled":          "faixa desligada por GATE_TASKRAPIDA_ENABLED",
    "switch-off":        "chave .gc/gate-task-rapida.on ausente (faixa desligada)",
    "switch-unreadable": "chave da faixa ilegivel ou sem local",
    "lane-decided":      "a fast-lane (doc/teste) ja decidiu esta rodada",
    "bad-inputs":        "entrada da decisao vazia",
    "e5-active":         "rodada com revisor extra do E5",
    "policy-files":      "diff mexe em arquivo de politica do gate",
    "not-task":          "bead de origem nao e task",
    "type-unreadable":   "tipo do bead de origem ilegivel",
    "opted-out":         "bead com a label gate:normal-only (pediu o gate normal)",
    "labels-unreadable": "labels do bead de origem ilegiveis",
    "cap-invalid":       "teto de linhas ilegivel (variavel de ambiente)",
    "counter-missing":   "contador de linhas de producao (E11) nao carregado",
    "diff-failed":       "git nao devolveu o diff",
    "count-failed":      "contagem de linhas ilegivel",
    "binary-file":       "arquivo binario no diff",
    "empty-diff":        "diff vazio",
    "over-limit":        "mais de 200 linhas de producao",
    "over-total":        "diff grande demais no total (com testes e docs)",
    "risk-unreadable":   "lista de risco ausente, ilegivel, vazia ou malformada",
    "risk-file":         "arquivo do diff casa com a lista de risco",
    "lib-not-loaded":    "lib da faixa nao carregada no dispatcher",
    "no-changed-files":  "lista de arquivos do dispatcher vazia (erro de git)",
    "decision-errored":  "decisao da faixa deu erro ou resposta incoerente",
}
_TR_OVER_S = 600   # the story's bar: the first verdict of a lane run in <= 10 min of the clock


def _ts(s):
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


# A line's own, complete timestamp: the first key of every producer here, compact ({"ts":"…") or spaced ({"ts": "…").
_HEAD = re.compile(r'^\{\s*"ts"\s*:\s*"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)"')
# A line that claims to be one of our records even when its ts cannot be read (cut inside the ts, or garbage there).
_CLAIMS_OURS = re.compile(r'^\{\s*"ts"')
_OUR_EVENTS = ('"gate_lane"', '"dispatcher_complete"')


# Counters that say something happened (or went wrong) even when the window holds no lane decision. A tally with zero
# decisions and all of these zero is an empty week; with any of them non-zero it is not, and must not read as one.
SIGNALS = ("unreadable_lines", "fast_runs_completed", "lane_revoked_at_push")


def _signals(r):
    return [k for k in SIGNALS if r.get(k)]


def _is_dry(ev):
    """True only when the event says it came from a DRY_RUN=1 sweep. A missing field is NOT a dry run."""
    return str(ev.get("dry_run", "0")).strip().lower() in ("1", "true")


def _tr_bucket(e):
    """Why the task-rapida lane did not take this normal-lane decision: the label of its tr_code, or None when the lane never evaluated
    it (no tr_code: the run predates the lane, or the DOC/TEST lane took it). A code nobody listed (or one that is not a string) is its
    own bucket, loudly — never dropped and never read as 'not evaluated'."""
    code = e.get("tr_code")
    if code is None or code == "":
        return None
    return TR_REASON_CODES[code] if isinstance(code, str) and code in TR_REASON_CODES else _UNKNOWN_CODE


def _is_secs(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and x >= 0


def _id_re(bead):
    """The bead id as a WHOLE token: ga-abc must not match ga-abcd, ga-abc-x or ga-abc.2 (a child is another bead)."""
    return re.compile(r'(?<![\w.-])' + re.escape(bead) + r'(?![\w-]|\.\w)')


def _read_store(city, since_s, timeout):
    """One bead store's bugs created since the window opened -> (rows, why). `rows` is a list (possibly empty: a real "no bugs here") or None with the
    reason it could not be read: bd missing, timeout, rc != 0 (with its stderr), an answer that is not JSON, not a list, or a row with no id."""
    try:
        p = subprocess.run(["bd", "-C", city, "list", "-t", "bug", "--all", "--limit", "0", "--created-after", since_s, "--json"],
                           capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        return None, repr(e)
    if p.returncode != 0:   # before the JSON: a failing bd prints nothing parseable, and its rc and stderr are the diagnosis
        return None, f"bd saiu com {p.returncode}: {' '.join(p.stderr.split())[:120] or 'sem mensagem'}"
    try:
        rows = json.loads(p.stdout)
    except ValueError as e:
        return None, f"resposta do bd não é JSON ({e})"
    if not isinstance(rows, list):
        return None, "bd respondeu algo que não é uma lista"
    if any(not isinstance(row, dict) or not row.get("id") for row in rows):
        return None, "linha do bd ilegível (um bug que cita a task poderia estar nela)"
    return rows, ""


def _rig_paths(city, timeout=90):
    """rig name -> the path of its bead store, from `gc rig list` (the same list the dispatcher uses) -> (map, why). None + why when the list
    could not be read; a rig row without a usable path is simply absent, so its grants read as 'store not resolved'."""
    try:
        p = subprocess.run(["gc", "--city", city, "rig", "list", "--json"], capture_output=True, text=True, timeout=timeout)
        if p.returncode != 0:
            return None, f"gc rig list saiu com {p.returncode}: {' '.join(p.stderr.split())[:120] or 'sem mensagem'}"
        rigs = json.loads(p.stdout)["rigs"]
        if not isinstance(rigs, list):   # an answer in another shape would read as "no rig has a path" — say what it was instead
            return None, "gc rig list: o campo rigs não é uma lista"
        return {r["name"]: r["path"] for r in rigs if isinstance(r, dict) and isinstance(r.get("name"), str)
                and isinstance(r.get("path"), str) and r["path"].startswith("/")}, ""
    except Exception as e:
        return None, f"gc rig list: {e!r}"


def _bugs_after(grants, explicit, rig_paths, rig_why, since_s, always=(), timeout=90):
    """Bug beads opened AFTER a task of the lane was granted that cite that task (title or description). `grants` = [(bead, rig, granted_at)].
    A bug about a rig task is filed either in that rig's own store or in the HQ store (the gate's and the daemons' bugs are HQ beads that cite
    the rig task — measured on the live log), so each grant is looked up in BOTH: the rig's store (the path comes from `rig_paths`, by the rig
    on its event), every store in `always` (the HQ city) and every store in `explicit` (--bug-city). Returns a dict: count (an int ONLY when every grant was looked up, else None),
    ids, found (what the grants that WERE looked up turned up — a floor, not the total), uncovered (how many grants were not), note, stores
    (read OK), failed. A grant is NOT looked up — and the count then cannot be a number — when it has no bead id, no rig on its event (and no
    explicit store to stand in), a rig whose store did not resolve, or a store that could not be read: "I never looked where the answer lives"
    must not be reported as "no bugs". Nothing granted: a real 0, and nothing is called."""
    res = {"count": 0, "ids": [], "found": 0, "uncovered": 0, "note": "", "stores": [], "failed": []}
    if not grants:
        return res
    why, want = {}, []   # why: reason -> grants it left un-looked-up; want: (bead pattern, granted_at, its store or None = the explicit ones, looked_up)

    def lose(reason):
        why[reason] = why.get(reason, 0) + 1
        res["uncovered"] += 1
    for bead, rig, t in grants:
        if not (isinstance(bead, str) and bead):
            lose("sem bead de origem no evento")
        elif isinstance(rig, str) and rig:
            path = (rig_paths or {}).get(rig)
            if path is None:   # its bugs may still turn up in an explicit store, so it stays in `want` — but it is already counted as not looked up
                lose(f"loja do rig {rig} não resolvida" + (f" ({rig_why})" if rig_why else ""))
            want.append((_id_re(bead), t, path, path is not None))
        elif explicit:
            want.append((_id_re(bead), t, None, True))
        else:
            lose("sem rig no evento e nenhuma --bug-city dada")
    stores = list(dict.fromkeys(list(always) + list(explicit) + [path for _, _, path, _ in want if path]))
    rows_by, bad = {}, {}
    for s in stores:
        rows, w = _read_store(s, since_s, timeout)
        if rows is None:
            bad[s] = w
        else:
            rows_by[s] = rows
    found = {}
    for pat, t, path, looked_up in want:
        down = [s for s in list(always) + ([path] if path else list(explicit)) if s in bad]
        if looked_up and down:
            lose("busca falhou em " + ", ".join(f"{s} ({bad[s]})" for s in down))
        for s, rows in rows_by.items():
            for row in rows:
                text = f"{row.get('title') or ''}\n{row.get('description') or ''}"
                try:
                    created = dt.datetime.fromisoformat(str(row.get("created_at")).replace("Z", "+00:00"))
                    created = created if created.tzinfo else created.replace(tzinfo=dt.timezone.utc)
                except ValueError:
                    created = None   # undated: bd already cut at the window start, so it is counted (one too many beats one hidden)
                if (created is None or created > t) and pat.search(text):
                    found[row["id"]] = True
    res.update(found=len(found), ids=sorted(found), stores=sorted(rows_by), failed=sorted(f"{s}: {w}" for s, w in bad.items()),
               count=len(found) if not res["uncovered"] else None,
               note="; ".join(f"{n} concedida(s): {reason}" for reason, n in sorted(why.items())))
    return res


def tally(log_path, days, now, cities=None):
    since = now - dt.timedelta(days=days)
    since_s = since.strftime("%Y-%m-%dT%H:%M:%SZ")
    decisions = {}       # marker -> [(ts, gate_lane event)] in time order; the LAST one is the marker's current lane
    completes = []       # (ts, dispatcher_complete event) with lane == fast
    other_completes = [] # (ts, dispatcher_complete event) of every run that is not fast; whose run it was is settled below, by the marker's decision
    revoked = 0          # gate_lane events whose reason_code is revoked-at-push (per event, see the docstring)
    bad = 0              # lines that claim to be ours, cannot be read, and sit in the window: the tally may be under-counting
    undatable = 0        # lines in the window that are not ours and carry no ts of their own: information, never damage
    cursor_s = None      # ts of the last line that had a readable one — the log is append-only, so position is time
    with open(log_path, errors="replace") as fh:   # OSError propagates: unreadable != empty
        for line in fh:
            m = _HEAD.match(line)
            if m:
                cursor_s = m.group(1)
                if cursor_s < since_s:   # old: out of the window whatever else is wrong with it (the ts is complete, so the string compare is exact)
                    continue
            else:
                s = line.strip()
                if not s:
                    continue
                if cursor_s is None:
                    undatable += 1   # before any dated line: it cannot be placed at all — say so, do not drop it silently
                    continue
                if cursor_s < since_s:
                    continue   # no ts of its own, and it sits in a stretch before the window: out of the window
                if _CLAIMS_OURS.match(s) or any(n in line for n in _OUR_EVENTS):
                    bad += 1   # ours, in the window by position, and its ts is unreadable (cut short or garbage): a lost record
                else:
                    undatable += 1
                continue
            try:
                ev = json.loads(line)
                t = _ts(ev["ts"])
            except Exception:
                bad += 1   # it has the head of one of our records and in the window, but does not parse: cut short, or interleaved
                continue
            if t < since:
                continue
            if _is_dry(ev):   # a DRY_RUN=1 sweep merges nothing and must not move any number
                continue
            if ev.get("event") == "gate_lane":
                decisions.setdefault(ev.get("marker") or ev.get("branch") or "?", []).append((t, ev))
                if ev.get("reason_code") == "revoked-at-push":
                    revoked += 1
            elif ev.get("event") == "dispatcher_complete" and ev.get("lane") == "fast":
                completes.append((t, ev))
            elif ev.get("event") == "dispatcher_complete":
                other_completes.append((t, ev))

    for lst in decisions.values():
        lst.sort(key=lambda te: te[0])   # a stable sort: events with the same second keep their log order
    last_decision = {m: lst[-1][1] for m, lst in decisions.items()}

    def decision_in_effect(marker, when):
        """The marker's last decision made at or before `when` (the run's own), or None — never a LATER one."""
        found = None
        for t, e in decisions.get(marker or "", []):
            if t <= when:
                found = e
            else:
                break
        return found

    # A run belongs to the task-rapida lane when the decision in effect for its marker WHEN IT COMPLETED was the lane's grant — or when the event
    # says so itself. The event's own `lane` cannot be the test: a reviewed run is finalized by a later sweep that does not restore GATE_LANE, so
    # every one of them reads lane=normal (measured on the whole live log 2026-10-14: 6 real grants, 6 completions all lane=normal, none lane=task-rapida).
    # Reading only the event would report those runs as "no verdict yet" — a false zero. A normal-lane run of the same marker from BEFORE the grant
    # is not the lane's: the decision in effect then was another one.
    tr_completes = [(t, c) for t, c in other_completes
                    if c.get("lane") == "task-rapida" or (decision_in_effect(c.get("marker"), t) or {}).get("lane") == "task-rapida"]

    fast = sum(1 for e in last_decision.values() if e.get("lane") == "fast")
    tr_granted = {m: e for m, e in last_decision.items() if e.get("lane") == "task-rapida"}   # the task-rapida lane's own grants: not fast, not "normal"
    normal = len(last_decision) - fast - len(tr_granted)
    buckets, bounced = {}, 0
    for e in last_decision.values():
        if e.get("lane") in ("fast", "task-rapida"):
            continue
        code = e.get("reason_code") or ""
        if not code:
            name, mech = _NO_CODE, False
        elif code in REASON_CODES:
            name, mech = REASON_CODES[code]
        else:
            name, mech = _UNKNOWN_CODE, False
        buckets[name] = buckets.get(name, 0) + 1
        bounced += 1 if mech else 0

    saved, unmatched, passed, failed = 0, 0, 0, 0
    for t, c in completes:
        if c.get("result") == "PASS":
            passed += 1
            dec = decision_in_effect(c.get("marker"), t)
            if dec is not None and isinstance(dec.get("would_have_reviewers"), int):
                saved += dec["would_have_reviewers"]
            else:
                saved += 1
                unmatched += 1
        elif c.get("result") == "FAIL":
            failed += 1   # did not merge: its diff is gated again, so nothing was saved

    # the task-rapida lane: why the others were not granted, how its first reviews went, how long they took, and the bugs that came after
    tr_refusals = {}
    for e in last_decision.values():
        name = None if e.get("lane") == "task-rapida" else _tr_bucket(e)
        if name is not None:
            tr_refusals[name] = tr_refusals.get(name, 0) + 1
    # A review is a run that ENDED with a verdict. A run the dispatcher closed without one (SKIPPED_BEAD_CLOSED: "neither PASS nor FAIL", written with
    # no lane and elapsed_s 0) is not a first review and must not pass for a run time: it is counted apart, by its result, and a marker whose only
    # runs were of that kind is "no verdict". A run with no marker cannot be tied to any grant, so each is its own run — never merged into one.
    first = {}   # marker -> its FIRST run with a verdict in the window: the first review is what the lane is judged on
    ended, unattributed = {}, set()   # result -> runs that ended without a verdict; keys of `first` that belong to no marker
    for i, (t, c) in enumerate(sorted(tr_completes, key=lambda tc: tc[0])):
        res = c.get("result")
        if res not in ("PASS", "FAIL"):
            name = res if isinstance(res, str) and res else "(sem result)"
            ended[name] = ended.get(name, 0) + 1
            continue
        key = c.get("marker")
        if not (isinstance(key, str) and key):
            key = f"?{i}"
            unattributed.add(key)
        first.setdefault(key, c)
    secs = sorted(c["elapsed_s"] for c in first.values() if _is_secs(c.get("elapsed_s")))   # a run with no readable elapsed_s is counted apart, not as 0
    mid = (secs[(len(secs) - 1) // 2] + secs[len(secs) // 2]) / 2 if secs else None
    grants = [(e.get("bead"), e.get("rig"), decisions[m][-1][0]) for m, e in tr_granted.items()]
    rig_paths, rig_why = _rig_paths(DEFAULT_CITY) if any(isinstance(g[1], str) and g[1] for g in grants) else (None, "")   # no rig on any grant: no need to ask
    bugs = _bugs_after(grants, list(cities or []), rig_paths, rig_why, since_s, always=[DEFAULT_CITY])
    return {
        "since": since_s, "days": days, "decisions": len(last_decision), "fast": fast, "normal": normal,
        "fast_runs_completed": len(completes), "fast_pass": passed, "fast_fail": failed,
        "reviewer_runs_saved": saved, "saved_unmatched_assumed_1": unmatched,
        "doc_test_only_bounced_by_check": bounced, "normal_reasons": buckets, "lane_revoked_at_push": revoked,
        "unreadable_lines": bad, "undatable_lines": undatable,
        "tr_granted": len(tr_granted), "tr_refused": sum(tr_refusals.values()), "tr_refusals": tr_refusals,
        "tr_runs": len(first), "tr_first_pass": sum(1 for c in first.values() if c.get("result") == "PASS"),
        "tr_first_fail": sum(1 for c in first.values() if c.get("result") == "FAIL"),
        "tr_no_verdict": sum(1 for m in tr_granted if m not in first),   # granted in the window, no run with a verdict in it (yet)
        "tr_ended_no_verdict": sum(ended.values()), "tr_ended_results": ended,   # runs the dispatcher closed with neither PASS nor FAIL
        "tr_first_outside_grants": sum(1 for k in first if k not in unattributed and k not in tr_granted),   # marker re-decided after its run: in PASS/FAIL, not in "granted"
        "tr_unattributed": len(unattributed),
        "tr_elapsed_median_s": mid, "tr_elapsed_max_s": secs[-1] if secs else None,
        "tr_over_10min": sum(1 for s in secs if s > _TR_OVER_S), "tr_elapsed_unknown": len(first) - len(secs),
        "tr_bugs_after": bugs["count"], "tr_bugs_after_ids": bugs["ids"], "tr_bugs_note": bugs["note"], "tr_bugs_found_partial": bugs["found"],
        "tr_bugs_uncovered": bugs["uncovered"], "tr_stores": bugs["stores"], "tr_stores_failed": bugs["failed"],
        "tr_grant_rigs": sorted({g[1] for g in grants if isinstance(g[1], str) and g[1]}),   # the rigs the grants came from: what "every store was read" is measured against
    }


def _min(s):
    return f"{s / 60:.1f} min"


def _render_tr(r):
    """The task-rapida lane's lines. Only called when the lane decided something in the window (granted, or refused with a tr_code)."""
    out = [f"  faixa task-rapida: concedida {r['tr_granted']} | não concedida {r['tr_refused']}"]
    for name, n in sorted(r["tr_refusals"].items(), key=lambda kv: -kv[1]):
        out.append(f"    {n:>4}  não concedida: {name}")
    if not r["tr_granted"]:
        return out
    out.append(f"    1ª revisão: PASS {r['tr_first_pass']} | FAIL {r['tr_first_fail']} | sem veredito na janela {r['tr_no_verdict']} (de {r['tr_granted']} concedida(s))")
    if r["tr_ended_no_verdict"]:
        what = ", ".join(f"{k} {n}" for k, n in sorted(r["tr_ended_results"].items()))
        out.append(f"    {r['tr_ended_no_verdict']} run(s) da faixa encerrado(s) sem veredito PASS/FAIL ({what}): não são revisão — ficaram fora da 1ª revisão e da mediana")
    if r["tr_first_outside_grants"]:
        out.append(f"    ({r['tr_first_outside_grants']} 1ª revisão(ões) de marker(s) cuja concessão foi trocada depois: contam em PASS/FAIL, não em 'concedidas')")
    if r["tr_unattributed"]:
        out.append(f"    ({r['tr_unattributed']} run(s) da faixa sem marker no evento: contados um a um, sem ligar a nenhuma concessão)")
    if r["tr_elapsed_median_s"] is not None:
        out.append(f"    tempo do run (elapsed_s da 1ª rodada): mediana {_min(r['tr_elapsed_median_s'])}, máx {_min(r['tr_elapsed_max_s'])}, "
                   f"acima de 10 min: {r['tr_over_10min']}")
    if r["tr_elapsed_unknown"]:
        out.append(f"    ({r['tr_elapsed_unknown']} run(s) sem elapsed_s legível: ficaram fora da mediana)")
    if r["tr_bugs_after"] is None:
        out.append(f"    ATENÇÃO: bugs abertos depois citando uma task da faixa: NÃO DEU PARA APURAR em {r['tr_bugs_uncovered']} de {r['tr_granted']} concedida(s) "
                   f"({r['tr_bugs_note']}) — achados nas outras: {r['tr_bugs_found_partial']} — isto NÃO é zero")
    else:
        ids = f" ({', '.join(r['tr_bugs_after_ids'])})" if r["tr_bugs_after_ids"] else ""
        out.append(f"    bugs abertos depois citando uma task da faixa: {r['tr_bugs_after']}{ids} [lojas buscadas: {', '.join(r['tr_stores'])}]")
        if r["tr_bugs_note"]:
            out.append(f"    ({r['tr_bugs_note']})")
    return out


def render(r):
    head = f"Gate fast-lane — últimos {r['days']} dias (desde {r['since']}):"
    info = (f"  {r['undatable_lines']} linha(s) sem timestamp na janela foram ignoradas (não são registro da fast-lane; "
            "não contam como dano)") if r["undatable_lines"] else None
    if r["decisions"] == 0 and not _signals(r):
        return f"{head} nenhuma decisão de lane registrada na janela." + (f"\n{info}" if info else "")
    out = [head]
    if r["decisions"] == 0:
        # no decision could be read, yet the log says something happened: this is NOT an empty week
        out.append("  ATENÇÃO: nenhuma decisão de lane legível na janela, mas o log traz sinais de que algo aconteceu — "
                   "isto NÃO é uma semana sem movimento:")
        if r["fast_runs_completed"]:
            out.append(f"  {r['fast_runs_completed']} run(s) fast concluído(s) (PASS {r['fast_pass']}, FAIL {r['fast_fail']}) "
                       "sem nenhuma decisão de lane gravada na janela — o evento gate_lane não foi escrito (produtor parado) "
                       "ou as linhas dele se perderam")
            out.append(f"  rodadas de revisor poupadas: {r['reviewer_runs_saved']}")
    else:
        pct = round(100 * r["fast"] / r["decisions"])
        out += [
            f"  diffs avaliados: {r['decisions']} — fast-lane {r['fast']} ({pct}%) | task-rapida {r['tr_granted']} | gate normal {r['normal']}",
            f"  rodadas de revisor poupadas: {r['reviewer_runs_saved']} "
            f"(runs fast concluídos: {r['fast_runs_completed']} → PASS {r['fast_pass']}, FAIL {r['fast_fail']})",
        ]
    if r["lane_revoked_at_push"]:
        out.append(f"  fast-lane concedida e revogada(s) no push: {r['lane_revoked_at_push']} "
                   "(o diff mudou ou deixou de ser elegível entre a decisão e o merge; o marker voltou ao gate normal)")
    if r["saved_unmatched_assumed_1"]:
        out.append(f"  ({r['saved_unmatched_assumed_1']} run(s) fast sem decisão pareada no log, ou com a decisão sem contagem de revisores: contados como 1 revisor cada)")
    if r["normal"]:
        out.append(f"  dos {r['normal']} que foram ao gate normal — {r['doc_test_only_bounced_by_check']} eram só doc/teste mas barrados por checagem mecânica:")
        for name, n in sorted(r["normal_reasons"].items(), key=lambda kv: -kv[1]):
            out.append(f"    {n:>4}  {name}")
    if r["tr_granted"] or r["tr_refused"]:
        out += _render_tr(r)
    if r["unreadable_lines"]:
        out.append(f"  ATENÇÃO: {r['unreadable_lines']} linha(s) do log ilegíveis foram puladas — os números desta apuração podem estar subcontados.")
    if info:
        out.append(info)
    return "\n".join(out)


def notify_line(r):
    """The ONE line the weekly sends. It is the only channel a human reads (the text report goes to the order's log),
    so what the report warns about has to be here too — not only the headline numbers."""
    if r["decisions"] > 0:
        line = (f"{r['fast']}/{r['decisions']} diffs na fast-lane, {r['reviewer_runs_saved']} rodada(s) de revisor poupada(s) "
                f"em {r['days']}d ({r['doc_test_only_bounced_by_check']} só-doc/teste barrados por checagem)")
    else:
        line = f"ATENÇÃO: nenhuma decisão de lane legível em {r['days']}d, mas o log tem sinais de que algo aconteceu"
        if r["fast_runs_completed"]:
            line += f"; {r['fast_runs_completed']} run(s) fast concluído(s) sem decisão gravada"
    if r["lane_revoked_at_push"]:
        line += f"; {r['lane_revoked_at_push']} lane(s) revogada(s) no push"
    if r["saved_unmatched_assumed_1"] and r["decisions"] > 0:
        line += f"; {r['saved_unmatched_assumed_1']} run(s) fast sem decisão pareada contado(s) como 1 revisor"
    if r["tr_granted"] or r["tr_refused"]:
        line += f"; task-rapida: {r['tr_granted']} concedida(s), {r['tr_refused']} não concedida(s)"
        if r["tr_granted"]:
            line += f", 1ª revisão PASS {r['tr_first_pass']}/FAIL {r['tr_first_fail']}"
            if r["tr_elapsed_median_s"] is not None:
                line += f", mediana {_min(r['tr_elapsed_median_s'])}"
            stores = ", ".join(os.path.basename(x.rstrip("/")) for x in r["tr_stores"]) or "nenhuma"
            if r["tr_bugs_after"] is not None:
                line += f", bugs depois {r['tr_bugs_after']} (lojas: {stores})"
            else:   # the one number that says whether the shortened review is safe: when it cannot be had, the line says how much of it is missing and why
                line += (f", ATENÇÃO bugs depois NÃO apurado em {r['tr_bugs_uncovered']}/{r['tr_granted']} concedida(s) "
                         f"({r['tr_bugs_note'][:140]}); achados nas outras {r['tr_bugs_found_partial']} (lojas: {stores}) — não é zero")
        if r["tr_ended_no_verdict"]:
            line += f"; {r['tr_ended_no_verdict']} run(s) da faixa encerrado(s) sem veredito"
    if r["unreadable_lines"]:
        line += f"; ATENÇÃO {r['unreadable_lines']} linha(s) do log ilegíveis — números podem estar subcontados"
    return line


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--log", default=os.path.join(DEFAULT_CITY, ".gc/quality-gate.jsonl"))
    ap.add_argument("--now", help="ISO UTC, for tests (default: now)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--weekly", action="store_true", help="append the tally to --out and send one notify line")
    ap.add_argument("--out", default=os.path.join(DEFAULT_CITY, ".gc/gate-lane-tally.jsonl"))
    ap.add_argument("--no-notify", action="store_true")
    ap.add_argument("--list-codes", action="store_true", help="print the reason codes this tally knows, then exit")
    ap.add_argument("--list-tr-codes", action="store_true", help="print the task-rapida codes (tr_code) this tally knows, then exit")
    ap.add_argument("--bug-city", action="append", help="an EXTRA bead store searched for bugs that cite a task of the lane (repeatable). The HQ store and the store of each "
                    "grant's own rig (its path comes from `gc rig list`) are searched without being asked; a grant whose store cannot be resolved or read makes the count unknown, never 0")
    a = ap.parse_args(argv)
    if a.list_codes:
        for code, (label, mech) in REASON_CODES.items():
            print(f"{code}\t{label}\t{1 if mech else 0}")
        return 0
    if a.list_tr_codes:
        for code, label in TR_REASON_CODES.items():
            print(f"{code}\t{label}")
        return 0
    now = _ts(a.now) if a.now else dt.datetime.now(dt.timezone.utc)
    try:
        r = tally(a.log, a.days, now, cities=a.bug_city)
    except OSError as e:
        print(f"gate-lane-tally: cannot read {a.log}: {e} — NOT a zero tally", file=sys.stderr)
        return 2
    print(json.dumps(r, ensure_ascii=False) if a.json else render(r))
    if a.weekly:
        if r["decisions"] > 0 or _signals(r):   # only a window with neither a decision nor a signal is an empty week
            try:
                with open(a.out, "a") as fh:
                    fh.write(json.dumps({"ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"), **r}, ensure_ascii=False) + "\n")
            except OSError as e:
                print(f"gate-lane-tally: could not append to {a.out}: {e}", file=sys.stderr)
                return 2
            if not a.no_notify and not shutil.which("notify"):
                print("gate-lane-tally: `notify` is not on PATH — tally appended to the history file only", file=sys.stderr)
            if not a.no_notify and shutil.which("notify"):
                try:
                    sent = subprocess.run(["notify", "-k", "info", "-t", "Gate fast-lane (semana)", "-p", "2", notify_line(r)], timeout=30, check=False)
                    if sent.returncode != 0:   # a notify that ran and refused is as silent as one that is missing: say so
                        print(f"gate-lane-tally: `notify` exited {sent.returncode} — tally appended to the history file only", file=sys.stderr)
                except Exception as e:  # a failed notification must not fail the tally
                    print(f"gate-lane-tally: notify failed: {e!r}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
