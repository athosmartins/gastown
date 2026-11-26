#!/usr/bin/env python3
"""gate-root-class.py — ga-mw5gdyu.5: the CLOSED root-class vocabulary a reviewer's FAIL must use, and the audit the gate runs on what the reviewers wrote.
Why: 244 of 308 refusals in 14 days carried no root-class (scripts/gate-refusal-meter.py counts them as "sem rótulo"), so the auto-improvement cycle had nothing to act on.

  gate-root-class.py task-block   prints the block gate-review-task.lib.sh adds to the reviewer task (the list, and the two rules: one class per blocking issue; outra owes one line of why).
  gate-root-class.py audit        reads FAIL_REASONS on stdin (the dispatcher's escaped one-string form: an entry break is the two characters backslash-n) and prints ONE ascii json object
                                  {state, valid, invalid, text, note}. `text` is FAIL_REASONS with every rejected label renamed root-class-invalida:<name> (inside the blocking part only) and `note` appended;
                                  the gate writes `text` to the gate-run comment, so the meter, which counts every root-class:<name> it reads, only ever sees accepted classes.
  state   classificada          at least one accepted class in the blocking part.
          sem_classe            a reviewer rejection with no label at all: counted as not classified, never dropped.
          fora_do_vocabulario   labels, but none accepted (not in the list, or outra with no why): the class is NOT accepted, it is listed in `invalid` and counts as not classified.
          nao_se_aplica         no judged "Reviewer N FAIL:" entry (a merge failure, a reviewer that never judged): nothing to classify, text unchanged.
          nao_sei               every "Reviewer N FAIL:" entry is what the dispatcher writes when it has NO reason for a verdict:FAIL (its comments could not be read, or held nothing to parse), alone or as every issue of an E5 union:
                                what the reviewer wrote is unknown, so it is neither "no label" nor a class. Text unchanged, no note.
Read as the meter reads (scripts/gate-refusal-meter.py): the blocking part is the text up to the FIRST "Non-blocking findings:", if there is one (what follows it, a second reviewer's labels included, is neither read nor renamed, as the meter does not read it) and the label
is the lowercase `root-class:` prefix; only the NAME is read wider (Error-vs-empty is seen and rejected, where the meter would not see it at all). The notes say how far they read. Run it ONCE per run: its own note and the
renamed labels are not recognised on a second pass.
EXIT 0 answered · 2 usage · 3 could not audit (stdin unreadable or not UTF-8, or an internal error): NOTHING on stdout, so a caller records "não sei" and never a state."""
import json
import re
import sys

VOCAB = (
    ("error-vs-empty", "a read that could not be made (failed, unreadable, timed out) is treated as the same result as an empty or a known one: the third state collapsed, a silent fail-open, an error reported as success"),
    ("comment-lies", "a comment, docstring, log line or doc promises more than the code next to it does"),
    ("instance-not-class", "the fix covers the instance that was cited and leaves sibling instances of the same defect in the code it touches"),
    ("stale-state", "state that goes stale, contradicts itself or is never reset: a cache, counter, label, cursor or flag read after its truth changed"),
    ("test-misses-bug", "a test that passes without exercising the path it claims to test, or that would still pass with the defect in place"),
    ("wrong-scope", "the change does less or more than the task asked (a missing piece, an unrelated edit) or acts on the wrong target, store or file"),
    ("incomplete-error-handling", "an error or exception path that is not handled at all: a crash, an unhandled branch, a missing cleanup or rollback"),
    ("race-concurrency", "an ordering or concurrency defect: a race, a duplicate run, a lock taken twice or not at all, a check-then-act gap"),
    ("outra", "none of the above fits: write root-class:outra - <one line: why no class fits>, on the same line"),
)
NAMES = tuple(n for n, _ in VOCAB)
# What the dispatcher writes IN PLACE OF a reason it does not have (quality-gate-dispatcher.sh, gate_collect_verdicts, the verdict:FAIL branch): "verdict:FAIL — its reason could not be read this sweep (…)" when `bd comments` failed,
# "INCONCLUSIVE — verdict:FAIL with empty/unparseable reason (…)" when it answered with nothing to parse. Neither is what a reviewer wrote, so neither can lack a class; test_gate_root_class.py and the selftest read both from the dispatcher.
UNREAD = r"(?:verdict:FAIL [\u2013\u2014-] its reason could not be read this sweep|INCONCLUSIVE [\u2013\u2014-] verdict:FAIL with empty/unparseable reason)"
UNREAD_AT, UNREAD_LINE = re.compile(r"[ \t]*" + UNREAD), re.compile(r"\n" + UNREAD)  # at the start of an entry body / on a line of an E5 union (whose lines are real newlines)
UNION_RE = re.compile(r"E5: union of \d+ independent reviews.*?(\d+) distinct issue\(s\) below")  # the header gate-e5-union.py writes
USAGE = "uso: gate-root-class.py task-block | audit   (audit lê o FAIL_REASONS no stdin)"
TOKEN_RE = re.compile(r"root-class:([A-Za-z0-9][A-Za-z0-9_-]*)")  # wider than the meter's NAME on purpose: an attempt at a label (Error-vs-empty) must be SEEN to be rejected
ENTRY_RE = re.compile(r"(?:^|\\n|\n)Reviewer \S+ FAIL:")  # a judged rejection starts an entry (after the escaped break backslash-n, or a real one)
BREAK_RE = re.compile(r"\\n|\n")
NONBLOCKING, MIN_WHY, NOTE = "Non-blocking findings:", 8, "Classificação da recusa (gate): "
READ = " (lê-se até o 1º «Non-blocking findings:», se houver, como o medidor)"


def task_block():
    # wording: no standalone "list", "show", "create" or "comments" — the E5 selftest's fake bd matches those as substrings of the task text it receives as an argument
    rows = "\n".join("  %s - %s" % nd for nd in VOCAB)
    return ("ROOT CLASS OF EACH BLOCKING ISSUE (required in a FAIL): end every \"Blocking issue N:\" line with exactly one root-class:<class>, <class> being one of this CLOSED set:\n" + rows + "\n"
            "A class outside this set is not accepted: the gate records the issue as not classified and counts it. A FAIL whose issues carry no class at all is recorded as \"sem classe\" and counted too. "
            "Choose the class by the kind of defect, not by the file it is in.")


def has_why(rest):
    """outra owes one line of why: what follows the label up to the line break, minus separators and other labels, is at least MIN_WHY characters."""
    line = TOKEN_RE.sub("", BREAK_RE.split(rest, maxsplit=1)[0])
    return len(re.sub(r"^[\s:()\[\]*_`,.;\u2013\u2014-]+", "", line)) >= MIN_WHY


def unread(body):
    """body = the text from just after one "Reviewer N FAIL:" header: True when no reviewer wrote the entry it opens, only what the dispatcher writes in its place (UNREAD), alone or as EVERY distinct issue of an
    E5 union (its header counts them; a real reviewer always adds at least one issue of its own, a free-form comment included). A later entry cannot change the answer: its placeholder follows its own header on the same line."""
    if UNREAD_AT.match(body):
        return True
    u = UNION_RE.search(body)
    return bool(u) and len(UNREAD_LINE.findall(body)) == int(u.group(1))


def audit(text):
    ents = list(ENTRY_RE.finditer(text))
    if all(unread(text[m.end():]) for m in ents):
        # vazio (no "Reviewer N FAIL:" entry: a merge failure, no verdict) → nao_se_aplica; ilegível (every entry is the dispatcher's own placeholder: what the reviewer wrote was never read) → nao_sei, never "no label"
        return {"state": "nao_sei" if ents else "nao_se_aplica", "valid": [], "invalid": [], "text": text, "note": ""}
    cut = text.find(NONBLOCKING)
    head, rest = (text, "") if cut < 0 else (text[:cut], text[cut:])
    valid, invalid = [], []

    def judge(m):
        name = m.group(1).rstrip("-_")
        ok = name in NAMES and (name != "outra" or has_why(m.string[m.end():]))
        if name not in (valid if ok else invalid):
            (valid if ok else invalid).append(name)
        return m.group(0) if ok else "root-class-invalida:" + m.group(1)

    out = TOKEN_RE.sub(judge, head) + rest
    state = "classificada" if valid else "fora_do_vocabulario" if invalid else "sem_classe"
    bad = "Classe(s) NÃO aceita(s) (fora do vocabulário fechado, ou outra sem porquê): %s." % ", ".join(invalid)
    note = NOTE + {"classificada": "classificada — %s." % ", ".join(valid) + (" " + bad if invalid else ""),
                   "sem_classe": "SEM CLASSE — nenhum bloqueante traz uma classe do vocabulário fechado" + READ + "; contada como não classificada.",
                   "fora_do_vocabulario": "SEM CLASSE — " + bad + " Nenhuma classe válida consta" + READ + "; contada como não classificada."}[state] + "\\n"
    return {"state": state, "valid": valid, "invalid": invalid, "text": (out if out.endswith("\\n") else out + "\\n") + note, "note": note}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv == ["task-block"]:
        sys.stdout.write(task_block() + "\n")
        return 0
    if argv == ["audit"]:
        try:
            # vazio → audit() answers nao_se_aplica; falhou/ilegível (stdin not readable, not UTF-8, audit raising) → rc 3 and NOTHING on stdout: the caller records "nao_sei", never a state
            answer = json.dumps(audit(sys.stdin.buffer.read().decode("utf-8")), ensure_ascii=True, separators=(",", ":"))
        except Exception as e:  # noqa: BLE001 — every failure ends the same way: no answer
            sys.stderr.write("gate-root-class audit: %s: %s\n" % (type(e).__name__, e))
            return 3
        sys.stdout.write(answer + "\n")
        return 0
    sys.stderr.write(USAGE + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
