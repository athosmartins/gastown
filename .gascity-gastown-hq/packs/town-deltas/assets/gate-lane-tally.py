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
notify line, and only if the window held at least one decision.

exit 0  tallied (a window with zero decisions is a valid tally: it says so)
exit 2  could not tally — log missing/unreadable. NOT "0 saved": error and empty must not look the same.
"""
import argparse
import datetime as dt
import json
import os
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


def _ts(s):
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


def _is_dry(ev):
    """True only when the event says it came from a DRY_RUN=1 sweep. A missing field is NOT a dry run."""
    return str(ev.get("dry_run", "0")).strip().lower() in ("1", "true")


def tally(log_path, days, now):
    since = now - dt.timedelta(days=days)
    since_s = since.strftime("%Y-%m-%dT%H:%M:%SZ")
    decisions = {}       # marker -> [(ts, gate_lane event)] in time order; the LAST one is the marker's current lane
    completes = []       # (ts, dispatcher_complete event) with lane == fast
    revoked = 0          # gate_lane events whose reason_code is revoked-at-push (per event, see the docstring)
    bad = 0
    with open(log_path, errors="replace") as fh:   # OSError propagates: unreadable != empty
        for line in fh:
            # cheap pre-filter: the ts is the first key; skip old lines without parsing them
            if line.startswith('{"ts":"') and line[7:27] < since_s:
                continue
            if '"gate_lane"' not in line and '"dispatcher_complete"' not in line:
                # not one of ours — but a line that is not even shaped like a JSON object is damage, not noise
                s = line.strip()
                if s and not (s.startswith("{") and s.endswith("}")):
                    bad += 1
                continue
            try:
                ev = json.loads(line)
                t = _ts(ev["ts"])
            except Exception:
                bad += 1
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

    fast = sum(1 for e in last_decision.values() if e.get("lane") == "fast")
    normal = len(last_decision) - fast
    buckets, bounced = {}, 0
    for e in last_decision.values():
        if e.get("lane") == "fast":
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
    return {
        "since": since_s, "days": days, "decisions": len(last_decision), "fast": fast, "normal": normal,
        "fast_runs_completed": len(completes), "fast_pass": passed, "fast_fail": failed,
        "reviewer_runs_saved": saved, "saved_unmatched_assumed_1": unmatched,
        "doc_test_only_bounced_by_check": bounced, "normal_reasons": buckets, "lane_revoked_at_push": revoked,
        "unreadable_lines": bad,
    }


def render(r):
    if r["decisions"] == 0:
        return f"Gate fast-lane — últimos {r['days']} dias (desde {r['since']}): nenhuma decisão de lane registrada na janela."
    pct = round(100 * r["fast"] / r["decisions"])
    out = [
        f"Gate fast-lane — últimos {r['days']} dias (desde {r['since']}):",
        f"  diffs avaliados: {r['decisions']} — fast-lane {r['fast']} ({pct}%) | gate normal {r['normal']}",
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
    if r["unreadable_lines"]:
        out.append(f"  ATENÇÃO: {r['unreadable_lines']} linha(s) do log ilegíveis foram puladas.")
    return "\n".join(out)


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
    a = ap.parse_args(argv)
    if a.list_codes:
        for code, (label, mech) in REASON_CODES.items():
            print(f"{code}\t{label}\t{1 if mech else 0}")
        return 0
    now = _ts(a.now) if a.now else dt.datetime.now(dt.timezone.utc)
    try:
        r = tally(a.log, a.days, now)
    except OSError as e:
        print(f"gate-lane-tally: cannot read {a.log}: {e} — NOT a zero tally", file=sys.stderr)
        return 2
    print(json.dumps(r, ensure_ascii=False) if a.json else render(r))
    if a.weekly:
        if r["decisions"] > 0:
            try:
                with open(a.out, "a") as fh:
                    fh.write(json.dumps({"ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"), **r}, ensure_ascii=False) + "\n")
            except OSError as e:
                print(f"gate-lane-tally: could not append to {a.out}: {e}", file=sys.stderr)
                return 2
            if not a.no_notify and not shutil.which("notify"):
                print("gate-lane-tally: `notify` is not on PATH — tally appended to the history file only", file=sys.stderr)
            if not a.no_notify and shutil.which("notify"):
                line = (f"{r['fast']}/{r['decisions']} diffs na fast-lane, {r['reviewer_runs_saved']} rodada(s) de revisor poupada(s) "
                        f"em {r['days']}d ({r['doc_test_only_bounced_by_check']} só-doc/teste barrados por checagem)")
                if r["lane_revoked_at_push"]:
                    line += f"; {r['lane_revoked_at_push']} lane(s) revogada(s) no push"
                try:
                    subprocess.run(["notify", "-k", "info", "-t", "Gate fast-lane (semana)", "-p", "2", line], timeout=30, check=False)
                except Exception as e:  # a failed notification must not fail the tally
                    print(f"gate-lane-tally: notify failed: {e!r}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
