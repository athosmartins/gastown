#!/usr/bin/env python3
"""test_gate_root_class.py (ga-mw5gdyu.5): hermetic suite for packs/town-deltas/assets/gate-root-class.py, the closed root-class vocabulary a reviewer's FAIL must use and the audit the gate runs on it.
FAIL_REASONS is fed in its real shape: one string where an entry break is the two characters backslash-n and a reviewer's own line break stays a real newline (see raw(), entry(), union_entry()). `python3 -I scripts/test_gate_root_class.py` (3.9+); GRC_UNDER_TEST=<copy> runs it against a mutant."""
import contextlib, importlib.util, io, json, os, re, subprocess, sys, unittest  # noqa: E401
from unittest import mock

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SUT = os.environ.get("GRC_UNDER_TEST") or os.path.join(HERE, "..", "packs", "town-deltas", "assets", "gate-root-class.py")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ASSETS = os.path.join(HERE, "..", "packs", "town-deltas", "assets")
DISPATCHER = os.path.join(ASSETS, "quality-gate-dispatcher.sh")
G = load("grc", SUT)
METER = load("grm", os.path.join(HERE, "gate-refusal-meter.py"))
UNION = load("e5union", os.path.join(ASSETS, "gate-e5-union.py"))


def raw(*lines):
    """FAIL_REASONS as the dispatcher builds it: lines joined by the two characters backslash-n, the last one closed too."""
    return "\\n".join(lines) + "\\n"


def entry(n, comment):
    """One entry as gate_collect_verdicts appends it: every backslash of the comment doubled, a real newline inside it kept, the two characters backslash-n at the end."""
    return "Reviewer %d FAIL: %s\\n" % (n, comment.replace("\\", "\\\\"))


def union_entry(*comments):
    """FAIL_REASONS as gate_e5_union_reasons leaves it: the union text as it is (real newlines, nothing doubled) closed by the two characters backslash-n."""
    return UNION.union([{"index": i + 1, "text": c} for i, c in enumerate(comments)])[0].rstrip("\n") + "\\n"


REV = "Reviewer 1 FAIL: VERDICT: FAIL"
TAIL = "Non-blocking findings: none"


def fail(*issues, tail=TAIL):
    return raw(REV, "Summary: s", *["Blocking issue %d: %s" % (i + 1, t) for i, t in enumerate(issues)], tail)


def cli(text, *args):
    p = subprocess.run([sys.executable, "-I", SUT] + list(args), input=text.encode("utf-8"), capture_output=True)
    return p.returncode, p.stdout.decode("utf-8"), p.stderr.decode("utf-8")


class Vocabulary(unittest.TestCase):
    def test_closed_list_is_unique_one_line_and_readable_by_the_meter(self):
        names = [n for n, _ in G.VOCAB]
        self.assertEqual(len(names), len(set(names)))
        self.assertIn("error-vs-empty", names)  # the class the prompt, root-class-count.sh and the first check already use
        self.assertEqual(names[-1], "outra")  # the one that needs a why is the last and the only one that does
        for n, d in G.VOCAB:
            with self.subTest(n):
                self.assertTrue(re.fullmatch(METER.NAME, n), "the meter would not read this name as a class")  # a name the meter cannot read is a class nobody counts
                self.assertTrue(d.strip() and "\n" not in d and "\\" not in d)

    def test_task_block_names_every_class_and_states_both_rules(self):
        b = G.task_block()
        for n, d in G.VOCAB:
            self.assertIn(n, b)
            self.assertIn(d, b)
        self.assertIn("root-class:outra", b)
        self.assertRegex(b, r"(?i)one line")  # outra owes one line of why
        self.assertRegex(b, r"(?i)not accepted")  # a class outside the list
        self.assertIn("sem classe", b)  # and what happens to a FAIL with none
        self.assertTrue(b.isascii() and not b.endswith("\n\n"))  # the task is plain ASCII text


class Audit(unittest.TestCase):
    def a(self, text):
        return G.audit(text)

    def test_a_valid_class_classifies_and_changes_nothing_but_the_note(self):
        t = fail("x never checks the read root-class:error-vs-empty")
        r = self.a(t)
        self.assertEqual((r["state"], r["valid"], r["invalid"]), ("classificada", ["error-vs-empty"], []))
        self.assertEqual(r["text"], t + r["note"])
        self.assertTrue(r["note"].endswith("\\n") and "error-vs-empty" in r["note"] and "\n" not in r["note"])

    def test_every_valid_class_counts_once_in_order_of_first_appearance(self):
        r = self.a(fail("a root-class:comment-lies", "b root-class:error-vs-empty", "c root-class:comment-lies"))
        self.assertEqual((r["state"], r["valid"], r["invalid"]), ("classificada", ["comment-lies", "error-vs-empty"], []))

    def test_a_fail_with_no_class_is_sem_classe_and_says_so_in_its_text(self):
        t = fail("x never checks the read", "y lies in the docstring")
        r = self.a(t)
        self.assertEqual((r["state"], r["valid"], r["invalid"]), ("sem_classe", [], []))
        self.assertEqual(r["text"], t + r["note"])
        self.assertIn("SEM CLASSE", r["note"])

    def test_a_class_outside_the_vocabulary_is_not_accepted_it_is_renamed_and_listed(self):
        r = self.a(fail("x root-class:third-state"))
        self.assertEqual((r["state"], r["valid"], r["invalid"]), ("fora_do_vocabulario", [], ["third-state"]))
        self.assertNotIn("root-class:third-state", r["text"])
        self.assertIn("root-class-invalida:third-state", r["text"])
        self.assertIn("third-state", r["note"])
        self.assertIn("SEM CLASSE", r["note"])  # it counts as not classified

    def test_a_good_class_next_to_a_bad_one_keeps_the_refusal_classified_and_still_flags_the_bad_one(self):
        r = self.a(fail("a root-class:error-vs-empty", "b root-class:made-up and again root-class:made-up"))
        self.assertEqual((r["state"], r["valid"], r["invalid"]), ("classificada", ["error-vs-empty"], ["made-up"]))
        self.assertEqual(r["text"].count("root-class-invalida:made-up"), 2)
        self.assertEqual(r["text"].count("root-class:error-vs-empty"), 1)
        self.assertIn("made-up", r["note"])

    def test_names_are_matched_whole_a_vocabulary_word_inside_a_longer_one_is_not_that_class(self):
        for bad in ("root-class:error", "root-class:error-vs-empty-extra", "root-class:Error-vs-empty", "root-class:error_vs_empty", "root-class:3"):
            with self.subTest(bad):
                r = self.a(fail("x " + bad + " then root-class:comment-lies"))
                self.assertEqual((r["state"], r["valid"], r["invalid"]), ("classificada", ["comment-lies"], [bad[len("root-class:"):]]))
                self.assertIn("root-class:comment-lies", r["text"])  # the good neighbour keeps its label
                self.assertIn("root-class-invalida:" + bad[len("root-class:"):], r["text"])

    def test_punctuation_around_a_class_is_not_part_of_its_name(self):
        for wrap in ("(root-class:error-vs-empty)", "root-class:error-vs-empty.", "root-class:error-vs-empty,", "[root-class:error-vs-empty]", "`root-class:error-vs-empty`", "root-class:error-vs-empty-", "root-class:error-vs-empty;", "_root-class:error-vs-empty_"):
            with self.subTest(wrap):
                r = self.a(fail("x " + wrap))
                self.assertEqual((r["state"], r["valid"], r["invalid"]), ("classificada", ["error-vs-empty"], []))

    def test_outra_is_accepted_only_with_one_line_of_why_after_it(self):
        for why, state in (("root-class:outra - the lock is taken twice on retry", "classificada"), ("root-class:outra — the lock is taken twice on retry", "classificada"),
                           ("root-class:outra: the lock is taken twice on retry", "classificada"), ("(root-class:outra) the lock is taken twice on retry", "classificada"),
                           ("root-class:outra", "fora_do_vocabulario"), ("root-class:outra -", "fora_do_vocabulario"), ("root-class:outra - lock", "fora_do_vocabulario"),
                           ("root-class:outra", "fora_do_vocabulario")):
            with self.subTest(why):
                r = self.a(fail("a " + why))
                self.assertEqual((r["state"], r["valid"] == ["outra"], r["invalid"] == ["outra"]), (state, state == "classificada", state == "fora_do_vocabulario"))
        for why, n in (("abcdefgh", 1), ("abcdefg", 0)):  # MIN_WHY = 8 characters, boundary both sides
            self.assertEqual(len(self.a(fail("a root-class:outra - " + why))["valid"]), n)
        r = self.a(fail("a root-class:outra root-class:comment-lies"))  # another label is not a why
        self.assertEqual((r["state"], r["valid"], r["invalid"]), ("classificada", ["comment-lies"], ["outra"]))
        # the why must be on the SAME line: text on the next issue does not count
        r = self.a(fail("a root-class:outra", "b the lock is taken twice on retry root-class:error-vs-empty"))
        self.assertEqual((r["state"], r["valid"], r["invalid"]), ("classificada", ["error-vs-empty"], ["outra"]))

    def test_only_the_blocking_part_is_read_the_same_cut_the_meter_makes(self):
        t = fail("x with no class", tail="Non-blocking findings: low: y root-class:made-up and root-class:error-vs-empty")
        r = self.a(t)
        self.assertEqual((r["state"], r["valid"], r["invalid"]), ("sem_classe", [], []))
        self.assertIn("root-class:made-up", r["text"])  # outside the blocking part nothing is rewritten
        # the meter reads the same text the same way: one class counted = classified here too, none = not
        for t2, want in ((fail("x root-class:error-vs-empty"), ["error-vs-empty"]), (t, [])):
            part = METER.blocking_part("Blocking reasons:\n" + G.audit(t2)["text"].replace("\\n", "\n"))
            self.assertEqual(sorted(set(METER.CLASS_RE.findall(part))), want)

    def test_the_cut_is_at_the_FIRST_marker_so_a_second_reviewer_after_it_is_not_read_as_the_meter_does_not_read_it(self):
        r = self.a(raw(REV, "Blocking issue 1: a", TAIL, "Reviewer 2 FAIL: VERDICT: FAIL", "Blocking issue 1: b root-class:error-vs-empty", TAIL))
        self.assertEqual((r["state"], r["valid"], r["invalid"]), ("sem_classe", [], []))

    def test_the_not_classified_notes_say_how_far_they_read_so_they_never_promise_the_whole_text(self):
        for t in (fail("x with no class"), fail("x root-class:made-up"), raw(REV, "Blocking issue 1: a", TAIL, "Reviewer 2 FAIL: VERDICT: FAIL", "Blocking issue 1: b root-class:error-vs-empty", TAIL)):
            with self.subTest(t[:40]):
                r = self.a(t)
                self.assertEqual(r["state"] != "classificada", True)
                self.assertIn("lê-se até o 1º «Non-blocking findings:»", r["note"])  # the 3rd case: reviewer 2's class is past the cut, and the note must not say none of the blocking issues has one

    def test_the_prefix_is_read_as_the_meter_reads_it_a_wrong_case_prefix_is_no_label(self):
        r = self.a(fail("x Root-Class:error-vs-empty"))
        self.assertEqual((r["state"], r["valid"], r["invalid"]), ("sem_classe", [], []))
        self.assertIn("Root-Class:error-vs-empty", r["text"])

    def test_what_is_not_a_reviewer_rejection_is_nao_se_aplica_and_untouched(self):
        for t in ("", "Merge failed after all-PASS verdict. Merge result: failed. root-class:made-up", raw("Reviewer 1 verdict:TIMEOUT: closed without explicit PASS root-class:made-up"),
                  raw("Commit abc already carries a recorded FAIL verdict"), "Gate FAILED. Reviewer 1 FAIL: inline is not an entry"):
            with self.subTest(t[:40]):
                r = self.a(t)
                self.assertEqual((r["state"], r["valid"], r["invalid"], r["text"], r["note"]), ("nao_se_aplica", [], [], t, ""))

    def test_a_judged_fail_after_a_no_verdict_entry_is_still_audited(self):
        r = self.a(raw("Reviewer 1 verdict:TIMEOUT: died", "Reviewer 2 FAIL: VERDICT: FAIL", "Blocking issue 1: x root-class:error-vs-empty", TAIL))
        self.assertEqual((r["state"], r["valid"]), ("classificada", ["error-vs-empty"]))

    def test_everything_else_in_the_text_survives_byte_for_byte(self):
        odd = fail("regex \\\\b and \\\\n stay, tabs\tand ção and \U0001f600 root-class:bogus", "second root-class:comment-lies")
        r = self.a(odd)
        self.assertEqual(r["text"].replace("root-class-invalida:bogus", "root-class:bogus").replace(r["note"], ""), odd)
        t = fail("x root-class:comment-lies")[:-2]  # an input that does not end in the two-character break: the note starts its own entry
        self.assertFalse(t.endswith("\\n"))
        self.assertEqual(self.a(t)["text"], t + "\\n" + self.a(t)["note"])


class Unread(unittest.TestCase):
    """A verdict:FAIL whose reason the dispatcher does not have is not a reviewer who left the class out: what it writes in that reviewer's place has no class to lack (gate attempt 1)."""

    def bodies(self):
        # vazio (the wording moved or went) → the count assertion fails the suite; falhou/ilegível (no dispatcher next to the helper) → the test errors: never a pass on strings that no longer exist
        with open(DISPATCHER, encoding="utf-8") as f:
            found = re.findall(r'^\s*FAIL_COMMENT="((?:verdict:FAIL|INCONCLUSIVE) [^"]*)"$', f.read(), re.M)
        self.assertEqual(len(found), 2, found)  # unread (bd comments failed) and empty (answered, nothing parseable): a third body must be taught to UNREAD in gate-root-class.py
        return [b.replace("$VB", "ga-vb1") for b in found]

    def test_each_placeholder_the_dispatcher_writes_is_nao_sei_with_the_text_untouched_and_no_note(self):
        for b in self.bodies():
            with self.subTest(b[:32]):
                t = entry(1, b)
                self.assertEqual(G.audit(t), {"state": "nao_sei", "valid": [], "invalid": [], "text": t, "note": ""})

    def test_next_to_an_unread_reviewer_the_judged_one_decides_the_state_in_either_order(self):
        un = self.bodies()[0]
        judged = lambda n, label: "Reviewer %d FAIL: VERDICT: FAIL\\nBlocking issue 1: x%s\\nNon-blocking findings: none\\n" % (n, label)  # noqa: E731
        for t, want in ((entry(1, un) + judged(2, ""), "sem_classe"), (judged(1, "") + entry(2, un), "sem_classe"),
                        (entry(1, un) + judged(2, " root-class:error-vs-empty"), "classificada"), (judged(1, " root-class:error-vs-empty") + entry(2, un), "classificada")):
            with self.subTest(want=want):
                self.assertEqual(G.audit(t)["state"], want)

    def test_a_reviewer_who_quotes_a_placeholder_inside_a_sentence_is_still_judged(self):
        # a reviewer of the dispatcher quotes these very strings: only an entry that IS the placeholder is unread
        for b in self.bodies():
            for label, want in ((" root-class:error-vs-empty", "classificada"), ("", "sem_classe")):
                with self.subTest(b[:12], want=want):
                    t = entry(1, "VERDICT: FAIL\nBlocking issue 1: gate_collect_verdicts writes %s as if a reviewer had said it%s\nNon-blocking findings: none" % (b, label))
                    self.assertEqual(G.audit(t)["state"], want)

    def test_an_e5_union_of_nothing_but_placeholders_is_nao_sei_and_one_real_reviewer_makes_it_judged(self):
        un, em = self.bodies()
        real = "VERDICT: FAIL\nBlocking issue 1: scripts/foo.py:40 x never checks the read%s\nNon-blocking findings: none"
        for cs, want in (((un, em), "nao_sei"), ((un, un.replace("ga-vb1", "ga-vb2")), "nao_sei"), ((un, un), "nao_sei"),  # the last pair merges into ONE issue: still nothing a reviewer wrote
                         ((real % "", un), "sem_classe"), ((un, real % " root-class:error-vs-empty"), "classificada")):
            with self.subTest(want=want, comments=[c[:12] for c in cs]):
                t = union_entry(*cs)
                self.assertTrue(t.startswith("Reviewer 1 FAIL: VERDICT: FAIL — E5: union"), t[:60])  # the producer's own header: if it is reworded this test must say so
                r = G.audit(t)
                self.assertEqual((r["state"], r["text"] == t, r["note"] == ""), (want, want == "nao_sei", want == "nao_sei"))
        quoting = "VERDICT: FAIL\nBlocking issue 1: scripts/foo.py:40 the dispatcher writes " + un + " as if a reviewer had said it\nNon-blocking findings: none"
        self.assertEqual(G.audit(union_entry(quoting, un))["state"], "sem_classe")  # a reviewer quoting a placeholder mid-sentence is no placeholder line: 1 line of 2 issues
        self.assertEqual(G.audit(union_entry(real % "", un) + entry(3, un))["state"], "sem_classe")  # a placeholder ENTRY after a union that holds a real reviewer does not make the union one
        pasted = "VERDICT: FAIL\nBlocking issue 1: x\n" + "\n".join([un] * 3) + "\nNon-blocking findings: none"  # a reviewer pasting the dispatcher's line three times on lines of its own
        self.assertEqual(G.audit(union_entry(pasted, "VERDICT: FAIL\nBlocking issue 1: y"))["state"], "sem_classe")  # 3 placeholder lines for 2 issues: not "every issue is one"

    def test_the_real_shape_real_newlines_inside_an_entry_doubled_backslashes_and_the_backslash_n_terminator(self):
        c = "VERDICT: FAIL\nSummary: regex \\b and \\n stay\nBlocking issue 1: x never checks the read root-class:error-vs-empty\nNon-blocking findings: none"
        t = entry(1, c)
        self.assertEqual((t.count("\n"), t.count("\\\\n")), (3, 1))  # three REAL newlines, and the reviewer's own backslash-n doubled
        self.assertEqual(G.audit(t)["state"], "classificada")
        self.assertEqual(G.audit(entry(1, c.replace(" root-class:error-vs-empty", "")))["state"], "sem_classe")


class WithTheMeter(unittest.TestCase):
    def test_the_meter_counts_only_accepted_classes_from_audited_refusals_and_the_rest_as_unlabelled(self):
        runs = {"ok": fail("a root-class:error-vs-empty"), "mixed": fail("a root-class:comment-lies", "b root-class:made-up"), "bad": fail("a root-class:made-up"), "none": fail("a")}
        body = {r: "Gate FAILED.\nBranch: b\n\nBlocking reasons:\n" + G.audit(t)["text"].replace("\\n", "\n") for r, t in runs.items()}  # what gate_render_reasons gives the gate-run comment
        refs = [(METER.parse_ts("2026-11-25T10:00:00Z"), i, {"bead": r, "gate_run": r, "rig": "gascity"}) for i, r in enumerate(runs)]
        with mock.patch.object(METER, "run", lambda argv, timeout: (0, json.dumps([{"text": body[argv[4]]}]))):  # argv = bd -C <city> comments <gate_run> --json
            r = METER.classify(refs, "bd", "/city", METER.parse_ts("2026-11-19T16:00:00Z"), METER.parse_ts("2026-11-26T16:00:00Z"))
        self.assertEqual(({n: c["refusals"] for n, c in r["classes"].items()}, r["labeled"], r["unlabeled"], r["unread"]), ({"comment-lies": 1, "error-vs-empty": 1}, 2, 2, 0))
        self.assertEqual([(c["labeled"], c["unlabeled"], c["pct"]) for c in r["weekly"]], [(2, 2, 50.0)])


class Cli(unittest.TestCase):
    def test_audit_reads_stdin_and_prints_one_ascii_json_object(self):
        t = fail("x root-class:comment-lies " + "ç")
        rc, out, err = cli(t, "audit")
        j = json.loads(out)
        self.assertEqual((rc, err, out.isascii(), out.count("\n"), j["state"], j["valid"], j["text"]), (0, "", True, 1, "classificada", ["comment-lies"], G.audit(t)["text"]))

    def test_task_block_prints_the_block_and_nothing_reads_stdin(self):
        rc, out, err = cli("", "task-block")
        self.assertEqual((rc, err, out), (0, "", G.task_block() + "\n"))

    def test_bad_usage_and_unreadable_input_are_a_failure_never_an_answer(self):
        for args, data in ((["audit", "x"], b""), ([], b""), (["nope"], b""), (["audit"], b"\xff\xfe not utf-8 \x80")):
            with self.subTest(args=args, data=data):
                p = subprocess.run([sys.executable, "-I", SUT] + args, input=data, capture_output=True)
                self.assertTrue(p.returncode != 0 and p.stdout == b"" and p.stderr, (p.returncode, p.stdout, p.stderr))  # nothing on stdout that a caller could mistake for a state
        err = io.StringIO()
        with mock.patch("sys.stdin", io.TextIOWrapper(io.BytesIO(b"x"))), mock.patch.object(G, "audit", side_effect=RuntimeError("boom")), contextlib.redirect_stderr(err):
            self.assertEqual(G.main(["audit"]), 3)
        self.assertIn("RuntimeError: boom", err.getvalue())


if __name__ == "__main__":
    unittest.main()
