#!/usr/bin/env python3
"""test_gate_check_trial.py (ga-mw5gdyu.3): hermetic suite for packs/town-deltas/assets/gate_check_trial.py, the A/B ruler of a check in trial. The ORACLE is the real third-state-reads-check.py (the A/B that already runs in the gate): conf grammar and arm
draw must be the same, so a new check's arms ARE the gate's arms, and its conf reader is the REAL consumer of what write_conf writes. `python3 -I scripts/test_gate_check_trial.py` (3.9+); GCT_UNDER_TEST=<copy> runs it against a mutant."""
import errno, importlib.util, json, os, re, shutil, sys, tempfile, unittest  # noqa: E401
from unittest import mock

sys.dont_write_bytecode = True  # loading the lib and the oracle must not write a __pycache__ into packs/
HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "packs", "town-deltas", "assets")
SUT = os.environ.get("GCT_UNDER_TEST") or os.path.join(ASSETS, "gate_check_trial.py")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


T = load("gct", SUT)
ORACLE = load("tsr_check", os.path.join(ASSETS, "third-state-reads-check.py"))
STEM = "third-state-reads"  # the oracle's own salt and conf name: the lib derives them from <stem>-check.py
BEADS = ["ga-%05d" % n for n in range(1000)]


def lines(path):
    with open(path) as fh:
        return fh.read().splitlines()


class Dir(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="gct-")
        self.addCleanup(shutil.rmtree, self.d, True)

    def conf(self, text):
        path = os.path.join(self.d, STEM + ".conf")
        if os.path.lexists(path):
            os.remove(path)
        if text is not None:
            with open(path, "w") as fh:
                fh.write(text)


class StemOf(unittest.TestCase):
    def test_the_registry_cell_names_the_check_and_nothing_else_does(self):
        # a wrong stem flips ANOTHER check's conf; the cell is data from a delivery, so a path that escapes the tree is refused
        good = "packs/town-deltas/assets/third-state-reads-check.py"
        for cell, want in ((good + " (gate-hard-checks.sh passo 2e, braço A/B enforce/holdout)", (STEM, good)), ("foo-check.py", ("foo", "foo-check.py")), ("a/b/foo_bar-1-check.py extra", ("foo_bar-1", "a/b/foo_bar-1-check.py")),
                           ("", None), ("   ", None), ("foo.py", None), ("-check.py", None), ("x/-check.py", None), ("Foo-check.py", None), ("foo-check.py.bak", None), ("/etc/foo-check.py", None),
                           ("../foo-check.py", None), ("a/../foo-check.py", None), ("./foo-check.py", None), ("a//foo-check.py", None), ("a\\foo-check.py", None), ("foo-check.py/", None)):
            with self.subTest(cell):
                stem, rel, why = T.stem_of(cell)
                self.assertEqual(((stem, rel), why) if want else (stem, rel), (want, "") if want else (None, None))
                self.assertTrue(want or why, "a refusal must say why")


class ArmFor(unittest.TestCase):
    def test_same_draw_as_the_gates_own_ab(self):
        # the oracle decides; a different hash, salt format or `<` vs `<=` at the boundary moves some of 1000 beads at one of these pcts
        empty = tempfile.mkdtemp(prefix="gct-")
        self.addCleanup(shutil.rmtree, empty, True)
        for pct in (1, 10, 37, 50, 63, 99, 100):
            for b in BEADS:
                self.assertEqual(T.arm_for(STEM, b, pct), ORACLE.arm_of(empty, b, pct, False)[0], (pct, b))

    def test_half_is_half_and_the_stem_is_the_salt(self):
        a, b = ([T.arm_for(stem, x, 50) for x in BEADS] for stem in ("foo", "bar"))
        self.assertTrue(440 <= a.count("enforce") <= 560 and a != b, "two checks in trial must not share one split")


class Conf(Dir):
    TEXTS = (None, "", "# só comentário\n", "mode=enforce\nenforce_pct=50\n", "enforce_pct=50\n", "mode=warn\n", "mode=off\n", "mode=bogus\n", "enforce_pct=0\n", "enforce_pct=101\n", "enforce_pct=5x\n",
             "mode=enforce # c\nenforce_pct=50\n", "junk\n", "mode = enforce\nenforce_pct = 50\n", "mode=ENFORCE\n", "enforce_pct=100\nmode=off\n", "\n\n",
             "mode=enforce\u2028enforce_pct=50\n", "mode=enforce\renforce_pct=50\r\n", "# a\u2028b\nmode=off\n", "mode=off\x85\n")  # the real reader cuts at every str.splitlines() boundary and so must the lib: they must AGREE, whatever that is

    def test_reads_the_conf_exactly_like_the_real_check(self):
        for text in self.TEXTS:
            with self.subTest(text):
                self.conf(text)
                self.assertEqual(T.load_conf(self.d, STEM), ORACLE.load_conf(self.d))

    def test_a_conf_that_cannot_be_read_is_never_absent_or_off(self):
        os.mkdir(os.path.join(self.d, STEM + ".conf"))  # a directory where the file should be
        self.assertEqual((T.load_conf(self.d, STEM), T.resolve(self.d, STEM, "ga-1")[0]), (("unreadable", None, None), "nao-sei"))
        os.rmdir(os.path.join(self.d, STEM + ".conf"))
        os.symlink(os.path.join(self.d, "nowhere"), os.path.join(self.d, STEM + ".conf"))  # dangling link: "absent" would switch the check off by silence
        self.assertEqual((T.load_conf(self.d, STEM), ORACLE.load_conf(self.d)), (("unreadable", None, None),) * 2)

    def test_the_real_check_reads_what_write_conf_wrote(self):
        for mode, pct, want, text in (("enforce", 50, ("ok", "enforce", 50), "mode=enforce\nenforce_pct=50\n"), ("enforce", 100, ("ok", "enforce", 100), None), ("enforce", 1, ("ok", "enforce", 1), None), ("off", None, ("ok", "off", 100), "mode=off\n"), ("warn", None, ("ok", "warn", 100), None)):
            with self.subTest((mode, pct)):
                self.assertEqual(T.write_conf(self.d, STEM, mode, pct), "")
                self.assertEqual(ORACLE.load_conf(self.d), want)  # a conf the check rejects would make it answer NÃO SEI to every submission
                self.assertTrue(text is None or "\n".join(lines(os.path.join(self.d, STEM + ".conf"))) + "\n" == text)
        self.assertEqual(os.listdir(self.d), [STEM + ".conf"], "the temp file of the atomic replace must not stay behind")

    def test_a_note_rides_in_a_comment_the_real_check_ignores_and_comes_back_from_the_same_read(self):
        self.assertEqual(T.write_conf(self.d, STEM, "enforce", 50, note='ratchet {"a": "x # y"}'), "")
        self.assertEqual((T.read_conf(self.d, STEM), ORACLE.load_conf(self.d)), (("ok", "enforce", 50, ['ratchet {"a": "x # y"}']), ("ok", "enforce", 50)))
        self.conf("# a\nmode=off # inline, not a note\n   # c\n")
        self.assertEqual(T.read_conf(self.d, STEM), ("ok", "off", 100, ["a", "c"]))
        self.conf("# a\u2028# b\nmode=off\n")  # comment lines are cut the way the real reader cuts them too: two notes, not one
        self.assertEqual((T.read_conf(self.d, STEM), ORACLE.load_conf(self.d)), (("ok", "off", 100, ["a", "b"]), ("ok", "off", 100)))
        self.assertTrue(T.write_conf(self.d, STEM, "off", None, note="duas\nlinhas"))  # two lines would leave the second one as a (broken) setting

    def test_a_note_the_real_checks_line_splitter_would_cut_is_refused_and_dumps_line_never_makes_one(self):
        for sep in ("\n", "\r", "\r\n", "\x0b", "\x0c", "\x1c", "\x1d", "\x1e", "\x85", "\u2028", "\u2029"):  # every boundary of str.splitlines(), which the real check's load_conf uses: the rest of the note would be read as a (broken) setting
            with self.subTest(repr(sep)):
                self.conf(None)
                self.assertTrue(T.write_conf(self.d, STEM, "enforce", 50, note="a" + sep + "b"))
                self.assertFalse(os.path.exists(os.path.join(self.d, STEM + ".conf")))
        obj = {"k": "x\u2028y\u2029z\x85w\ry\nq\x1cv", "é": ["ç"]}
        s = T.dumps_line(obj)
        self.assertEqual((s.splitlines(), json.loads(s)), ([s], obj))
        self.assertTrue("é" in s and "ç" in s and s.index('"k"') < s.index("é"), s)  # only the characters that cut a line are escaped: accents stay readable for whoever cats the conf; keys are sorted
        self.assertEqual(T.write_conf(self.d, STEM, "enforce", 50, note="ratchet " + s), "")
        self.assertEqual((ORACLE.load_conf(self.d), T.read_conf(self.d, STEM)[3]), (("ok", "enforce", 50), ["ratchet " + s]))  # the real check still reads the conf, and the note comes back whole

    def test_bad_arguments_and_a_failed_write_say_so_and_leave_nothing_behind(self):
        for mode, pct in (("bogus", 50), ("enforce", 0), ("enforce", 101), ("enforce", "50"), ("enforce", None), ("enforce", True), ("", 50)):
            with self.subTest((mode, pct)):
                self.assertTrue(T.write_conf(self.d, STEM, mode, pct))
        self.assertEqual(os.listdir(self.d), [])
        self.assertTrue(T.write_conf(os.path.join(self.d, "nao-existe"), STEM, "off", None))
        os.mkdir(os.path.join(self.d, STEM + ".conf"))  # the rename cannot replace a directory: the temp file written before it must not stay behind
        self.assertTrue(T.write_conf(self.d, STEM, "off", None))
        self.assertEqual(os.listdir(self.d), [STEM + ".conf"])


class Resolve(Dir):
    def test_what_a_check_does_with_each_conf_and_bead(self):
        enf, hold = [next(x for x in BEADS if ORACLE.arm_of(self.d, x, 50, False)[0] == a) for a in ("enforce", "holdout")]
        half = "mode=enforce\nenforce_pct=50\n"
        for text, bead, want in ((None, enf, ("desligado", None, "-")), ("mode=off\n", enf, ("desligado", None, "-")), ("junk\n", enf, ("nao-sei", None, "-")), ("mode=warn\n", enf, ("ok", "warn", "-")),
                                 ("mode=enforce\n", enf, ("ok", "enforce", "enforce")), (half, enf, ("ok", "enforce", "enforce")), (half, hold, ("ok", "warn", "holdout")), (half, "", ("nao-sei", None, "-")), ("mode=enforce\n", "", ("ok", "enforce", "enforce"))):
            with self.subTest((text, bead)):
                self.conf(text)
                st, eff, arm, why = T.resolve(self.d, STEM, bead)
                self.assertEqual((st, eff, arm), want)
                self.assertEqual(bool(why), st != "ok", "only 'ok' comes without a why")


class Rows(Dir):
    def row(self, **kw):
        return dict({"bead": "ga-1", "ts": "2026-11-27T10:00:00Z", "arm": "enforce", "verdict": "ok", "pontos": [], "dispensados": []}, **kw)

    def test_row_validation(self):
        for name, kw, ok in (("ok", {}, True), ("achados com ponto", {"verdict": "achados", "pontos": ["a.py#1"]}, True), ("holdout", {"arm": "holdout"}, True), ("nao-sei", {"verdict": "nao-sei"}, True),
                             ("achados sem ponto", {"verdict": "achados"}, False), ("veredito inventado", {"verdict": "falhou"}, False), ("braço inventado", {"arm": "x"}, False), ("bead vazia", {"bead": ""}, False),
                             ("bead só espaço", {"bead": "  "}, False), ("bead não texto", {"bead": 7}, False), ("ts impossível", {"ts": "2026-13-45T10:00:00Z"}, False), ("ts sem Z", {"ts": "2026-11-27T10:00:00"}, False), ("ts com segundo 60", {"ts": "2026-11-27T10:00:60Z"}, False), ("ts com segundo 61", {"ts": "2026-11-27T10:00:61Z"}, False),
                             ("ponto vazio", {"pontos": [""]}, False), ("ponto não texto", {"pontos": [3]}, False), ("dispensados texto", {"dispensados": "a.py#1"}, False)):
            with self.subTest(name):
                self.assertEqual(T.row_ok(self.row(**kw)) == "", ok, T.row_ok(self.row(**kw)))
        d = self.row()
        del d["pontos"], d["dispensados"]
        self.assertEqual(T.row_ok(d), "")  # absent keys are []
        self.assertTrue(T.row_ok([1]) and T.row_ok("x") and T.row_ok(None))  # not an object

    def test_record_run_appends_one_parseable_line_and_refuses_what_the_reader_would_reject(self):
        p = os.path.join(self.d, STEM + "-runs.jsonl")
        self.assertEqual(T.record_run(self.d, STEM, "ga-1", "enforce", "achados", ["a.py#1"], [], ts="2026-11-27T10:00:00Z"), "")
        self.assertEqual(T.record_run(self.d, STEM, "ga-2", "holdout", "ok"), "")
        rows = [json.loads(x) for x in lines(p)]
        self.assertEqual(rows[0], {"bead": "ga-1", "ts": "2026-11-27T10:00:00Z", "arm": "enforce", "verdict": "achados", "pontos": ["a.py#1"], "dispensados": []})
        self.assertEqual(lines(p)[0], '{"arm": "enforce", "bead": "ga-1", "dispensados": [], "pontos": ["a.py#1"], "ts": "2026-11-27T10:00:00Z", "verdict": "achados"}')  # one compact-enough, key-sorted line: stable to diff and to grep
        self.assertTrue(re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", rows[1]["ts"]), rows[1]["ts"])
        with open(p) as fh:
            self.assertTrue(fh.read().endswith("\n"))
        for args in (("ga-3", "holdout", "achados"), ("", "enforce", "ok"), ("ga-3", "enforce", "achados", "a.py#1"), ("ga-3", "enforce", "ok", (), (), "2026-11-27T10:00:60Z")):  # no cited point / no bead / a text where a list belongs (not the list of its characters) / a second the reader cannot parse
            self.assertTrue(T.record_run(self.d, STEM, *args), args)
        self.assertEqual(len(lines(p)), 2, "a refused row must not be written")
        self.assertTrue(T.record_run(os.path.join(self.d, "nao-existe"), STEM, "ga-1", "enforce", "ok"))  # said, not raised

    def test_a_run_line_is_one_line_for_every_splitter(self):
        pt = "src/é\u2028x\u2029y\x85z.py#1"  # json.dumps(ensure_ascii=False) leaves U+0085, U+2028 and U+2029 raw, and str.splitlines() cuts a line at each of them
        self.assertEqual(T.record_run(self.d, STEM, "ga-1", "enforce", "achados", [pt], ts="2026-11-27T10:00:00Z"), "")
        with open(os.path.join(self.d, STEM + "-runs.jsonl"), encoding="utf-8") as fh:
            text = fh.read()
        self.assertEqual((text.splitlines(), json.loads(text)["pontos"]), (text.split("\n")[:-1], [pt]))

    def test_a_point_with_a_lone_surrogate_is_recorded_not_raised(self):
        # os.fsdecode of a file name holding a byte that is not UTF-8 gives a lone surrogate (U+DC80): json.dumps(ensure_ascii=False) keeps it and a strict .encode("utf-8") would raise out of record_run, which promises to SAY why
        pt = "src/" + chr(0xDC80) + ".py#1"
        self.assertEqual(T.record_run(self.d, STEM, "ga-1", "enforce", "achados", [pt], ts="2026-11-27T10:00:00Z"), "")
        with open(os.path.join(self.d, STEM + "-runs.jsonl"), "rb") as fh:
            self.assertEqual(json.loads(fh.read().decode("utf-8"))["pontos"], [pt])  # the point comes back as it went in: the reader compares points between runs

    def test_a_short_write_is_finished_and_a_write_that_cannot_be_finished_is_said(self):
        real, p, calls = os.write, os.path.join(self.d, STEM + "-runs.jsonl"), []

        def half(fd, data):  # what a nearly full disk does: part of the line, and the call says how much
            calls.append(len(data))
            return real(fd, bytes(data)[:max(1, len(data) // 2)])
        with mock.patch("os.write", half):
            self.assertEqual(T.record_run(self.d, STEM, "ga-1", "enforce", "ok", ts="2026-11-27T10:00:00Z"), "")
        with open(p) as fh:
            text = fh.read()
        self.assertTrue(len(calls) > 1 and text.endswith("\n") and text.count("\n") == 1 and json.loads(text)["bead"] == "ga-1", (calls, text))  # ONE whole line, in more than one call

        n = []

        def enospc(fd, data):  # half of the line, then the disk is full
            n.append(1)
            if len(n) > 1:
                raise OSError(errno.ENOSPC, "No space left on device")
            return real(fd, bytes(data)[:len(data) // 2])
        with mock.patch("os.write", enospc):
            why = T.record_run(self.d, STEM, "ga-2", "enforce", "ok", ts="2026-11-27T10:00:00Z")
        self.assertTrue("No space left" in why and "parcial" in why, why)  # said (not ""), with the warning that half a line may be there: the ratchet counts it as damage

        k = []

        def stuck(fd, data):  # a write that returns 0 forever must not hang the check that called it
            k.append(1)
            if len(k) > 5:
                raise AssertionError("looped on a write that makes no progress")
            return 0
        with mock.patch("os.write", stuck):
            why = T.record_run(self.d, STEM, "ga-3", "enforce", "ok", ts="2026-11-27T10:00:00Z")
        self.assertTrue(why and "parcial" not in why, why)  # said, and nothing was written, so no warning about half a line


if __name__ == "__main__":
    unittest.main()
