#!/usr/bin/env python3
"""test_gate_refusal_meter.py (ga-mw5gdyu.1): hermetic suite for scripts/gate-refusal-meter.py. The gate log is a REAL file in a temp city; `gc`/`bd` are `Fake`, a table over P.run that RECORDS every call and fails on
one nobody planned (so the argv of every read is part of the contract); `Real` runs run() with real processes. `python3 -I scripts/test_gate_refusal_meter.py` (3.9+); GRM_UNDER_TEST=<copy> runs it against a mutant."""
import contextlib, hashlib, importlib.util, io, json, os, shutil, subprocess, sys, tempfile, unittest  # noqa: E401
from unittest import mock

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SUT = os.environ.get("GRM_UNDER_TEST") or os.path.join(HERE, "gate-refusal-meter.py")
_spec = importlib.util.spec_from_file_location("grm", SUT)
P = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(P)

NOW, IN, OLD = "2026-11-26T16:00:00Z", "2026-11-24T10:00:00Z", "2026-11-01T10:00:00Z"  # the 7-day window is 11-19T16:00 .. NOW
MERGE = "Merge failed after all-PASS verdict"  # a FAIL nobody rejected: no comment is read for it


def slurp(path, mode="r"):
    with open(path, mode) as fh:
        return fh.read()


def rec(bead, result="PASS", ts=IN, reason="", **kw):
    return dict({"ts": ts, "event": "dispatcher_complete", "bead": bead, "rig": "gascity", "result": result, "reason": reason, "gate_run": "gr-" + str(bead), "dry_run": "0"}, **kw)


class Fake:
    def __init__(self, root, table):
        self.root, self.table, self.calls = root, table, []

    def __call__(self, argv, timeout):
        key = tuple(a.replace(self.root, "{R}") for a in argv[1:])
        self.calls.append(key)
        if key not in self.table:
            raise AssertionError("unplanned call: %r" % (key,))
        v = self.table[key]
        return (v[0], v[1].replace("{R}", self.root)) if isinstance(v[1], str) else v


class T(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="grm-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.city = os.path.join(self.root, "city")
        self.logpath = os.path.join(self.city, ".gc", "quality-gate.jsonl")
        os.makedirs(os.path.dirname(self.logpath))

    def stores(self, *names):
        for n in names:
            os.makedirs(os.path.join(self.root, n), exist_ok=True)
        return ["{R}/" + n for n in names]

    def log(self, *rows):
        with open(self.logpath, "w") as fh:
            fh.write("".join((r if isinstance(r, str) else json.dumps(r)) + "\n" for r in rows))

    def go(self, table=None, *args):
        fake = Fake(self.root, table or {})
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(P, "run", fake), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = P.main(["--city", self.city, "--now", NOW] + list(args))
        return rc, out.getvalue(), err.getvalue(), fake

    def js(self, table=None, *args):
        rc, out, err, fake = self.go(table, "--json", *args)
        return rc, json.loads(out), fake


NO_RIGS = {("rig", "list", "--json"): (1, "")}  # the inventory cannot read its stores: nothing else is planned


class LogAndFirstAttempt(T):
    def test_unreadable_log_is_nao_sei_and_nothing_is_called(self):
        for name, state, put in (("ausente", "absent", lambda: None), ("vazio", "empty", lambda: self.log()), ("só lixo", "empty", lambda: self.log("{not json", "garbage")),
                                 ("diretório no lugar do log", "unreadable", lambda: os.makedirs(self.logpath))):
            with self.subTest(name):
                shutil.rmtree(self.logpath, ignore_errors=True) if os.path.isdir(self.logpath) else (os.path.exists(self.logpath) and os.remove(self.logpath))
                put()
                rc, j, fake = self.js()
                self.assertEqual((rc, j["gate_log"]["state"], j["complete"], fake.calls), (2, state, False, []))
                self.assertTrue(j["first_attempt"] is None and j["refusals"] is None and j["inventory"] is None)
                self.assertTrue(j["line"].startswith("NÃO SEI") and "NÃO é 0" in j["line"])

    def test_first_attempt_counts_the_first_real_verdict_of_each_bead(self):
        late, mid = "2026-11-25T09:00:00Z", "2026-11-24T09:00:00Z"
        for name, rows, want in (
                ("nada na janela", [rec("a", ts=OLD)], (0, 0, None, "sem dado")),
                ("n<5 não vira percentual limpo", [rec("a"), rec("b", "FAIL", reason=MERGE)], (2, 1, 50.0, "n<5")),
                ("pct não inteiro", [rec("a"), rec("b"), rec("c", "FAIL", reason=MERGE)], (3, 2, 66.7, "n<5")),
                ("só o 1º veredito conta: o retrabalho aprovado depois não salva o 1º FAIL", [rec(b) for b in "abcd"] + [rec("e", "FAIL", ts=mid, reason=MERGE), rec("e", ts=late)], (5, 4, 80.0, "ok")),
                ("1º veredito antes da janela: a bead fica fora, mesmo que reprove de novo dentro", [rec("o", ts=OLD), rec("o", "FAIL", reason=MERGE)] + [rec(b) for b in "abcde"], (5, 5, 100.0, "ok")),
                ("dry-run, resultado que não é PASS/FAIL e evento de outro tipo não contam", [rec("dry", dry_run="1"), rec("s", "SKIPPED_BEAD_CLOSED"), dict(rec("x"), event="gate_remerge")] + [rec(b) for b in "abcde"], (5, 5, 100.0, "ok")),
                ("ordem por ts, não pela ordem das linhas", [rec("z", ts=late), rec("z", "FAIL", ts=mid, reason=MERGE)] + [rec(b) for b in "abcd"], (5, 4, 80.0, "ok"))):
            with self.subTest(name):
                self.log(*rows)
                rc, j, _ = self.js(NO_RIGS)
                f = j["first_attempt"]
                self.assertEqual((rc, f["n"], f["approved"], f["pct"], f["state"]), (0, ) + want)

    def test_unusable_verdicts_and_bad_lines_are_counted_never_dropped(self):
        rows = [rec(b) for b in "abcde"] + [rec(""), rec(" "), dict(rec("nb"), bead=None), dict(rec("t1"), ts="garbage"), dict(rec("t2"), ts=None), {"event": "dispatcher_complete", "bead": "nots", "result": "PASS"},
                                              "", "   ", "{not json", "[1, 2]", '{"ts":"2026-10-15T00:00:00Z" not json', '{"ts":"2026-11-01T00:00:00Z" not json', '{"ts":"2026-11-19T16:00:00Z" not json', '{"ts":"2026-11-25T00:00:00Z" not json',
                                              '{"ts":"2026-13-45T25:61:61Z" not json']
        self.log(*rows)
        with open(self.logpath, "ab") as fh:
            fh.write(b"\xff\xfe broken bytes\n")
        rc, j, _ = self.js(NO_RIGS)
        g = j["gate_log"]
        self.assertEqual((rc, g["state"], g["unusable"], g["bad_lines"], g["bad_maybe_in_window"]), (0, "ok", 6, 8, 6))  # blank lines are not lines; only the 10-15 and 11-01 ones are provably before the window (11-19 is ON its edge)
        self.assertEqual(j["first_attempt"]["n"], 5)
        self.assertFalse(j["complete"])
        self.assertTrue(any("ilegíve" in x for x in j["gaps"]) and any("sem ts" in x or "inutiliz" in x for x in j["gaps"]))

    def test_usage_errors_exit_64(self):
        self.log(rec("a"))
        for args in (["--days", "0"], ["--days", "x"], ["--days", "100000"], ["--now", "ontem"], ["--class", "Nome Ruim"], ["--class", "x:y"], ["--bogus"]):
            with self.subTest(args):
                rc, out, err, fake = self.go(None, *args)
                self.assertEqual((rc, out, fake.calls), (64, "", []))
                self.assertIn("uso:", err)


REV = "Reviewer 1 FAIL: VERDICT: FAIL"
TAGS = "(root-class:error-vs-empty)"


def gate_text(*issues, tail=""):
    return "Gate FAILED.\nBranch: b\nTier: t\n\nBlocking reasons:\n%s\n%s\n%s" % (REV, "\n".join("Blocking issue %d: %s" % (i + 1, t) for i, t in enumerate(issues)), tail)


def comments(*texts):
    return (0, json.dumps([{"text": t, "author": "x"} for t in texts]))


def rd(run):
    return ("-C", "{R}/city", "comments", run, "--json")


def reads(fake):
    return [c for c in fake.calls if c[2:3] == ("comments",)]


class Refusals(T):
    def refuse(self, texts, **extra):
        """texts: {bead: gate-run comment text | (rc, out)}; one reviewer FAIL per bead, a table that reads each gate-run once."""
        self.log(*[rec(b, "FAIL", reason=REV, **extra.get(b, {})) for b in texts])
        t = dict(NO_RIGS)
        t.update({rd("gr-" + b): (comments(x) if isinstance(x, str) else x) for b, x in texts.items()})
        rc, j, fake = self.js(t)
        return j["refusals"], j, fake

    def test_every_class_in_the_blocking_part_counts_once_per_refusal(self):
        self.log(rec("b1", "FAIL", reason=REV), rec("b2", "FAIL", reason=REV, rig="whatsapp_automation"), rec("b3", "FAIL", reason=REV), rec("b4", "FAIL", reason=REV, rig=None),
                 rec("b1", "FAIL", reason=REV, ts="2026-11-25T10:00:00Z", gate_run="gr-b1x"))
        table = dict(NO_RIGS)
        table.update({rd("gr-b1"): comments(gate_text("a " + TAGS)), rd("gr-b1x"): comments(gate_text("b " + TAGS)),
                      rd("gr-b2"): comments(gate_text("c (root-class:error-vs-empty) e (root-class:unreachable-by-construction)")),
                      rd("gr-b3"): comments(gate_text("sem etiqueta", tail="Non-blocking findings:\nroot-class:armed-but-unreachable\n")),
                      rd("gr-b4"): comments("noise", gate_text("d " + TAGS, "e " + TAGS))})
        rc, j, fake = self.js(table)
        r = j["refusals"]
        self.assertEqual((r["total"], r["labeled"], r["unlabeled"], r["unread"], r["other_fail"]), (5, 4, 1, 0, 0))
        self.assertEqual(r["classes"], {"error-vs-empty": {"refusals": 4, "beads": 3, "rigs": {"gascity": 2, "unknown": 1, "whatsapp_automation": 1}},
                                        "unreachable-by-construction": {"refusals": 1, "beads": 1, "rigs": {"whatsapp_automation": 1}}})
        self.assertEqual([(g["key"], g["refusals"]) for g in r["unlabeled_groups"]], [("sem etiqueta", 1)])

    def test_unlabeled_refusals_are_grouped_by_the_words_of_their_blocking_issues(self):
        ok = "[teste que passa sem exercer o caminho que diz testar]"
        r, j, _ = self.refuse({"u1": gate_text(ok, "Docstring diz X mas o código faz Y (a.py:10)"), "u2": gate_text("[Teste que passa sem exercer o caminho que diz testar] e mais") + "- **Blocking issue 2:** Docstring diz X mas o código faz Y\n",
                               "u3": gate_text("o vigia fala com o servidor tmux ERRADO e nunca ve uma sessao da cidade. x.py:90"), "u4": "Gate FAILED.\nBlocking reasons:\n" + REV + "\nSummary: boom\n",
                               "u5": gate_text("x").replace("Blocking issue 1:", "blocking issue 1:"), "u6": gate_text("[terceiro estado: leitura que não respondeu = nenhuma]"), "u7": gate_text("???")})
        self.assertEqual([(g["key"], g["refusals"]) for g in r["unlabeled_groups"]],
                         [("(sem título de bloqueante)", 2), ("docstring diz x mas o codigo faz y", 2), ("teste que passa sem exercer o caminho que", 2), ("o vigia fala com o servidor tmux errado", 1),
                          ("terceiro estado", 1), ("x", 1)])
        self.assertEqual([g["example"] for g in r["unlabeled_groups"][:2]], [{"bead": "u4", "gate_run": "gr-u4"}, {"bead": "u1", "gate_run": "gr-u1"}])  # the first refusal seen, not the last
        self.assertEqual((r["labeled"], r["unlabeled"], r["classes"]), (0, 7, {}))

    def test_a_refusal_that_cannot_be_read_is_sem_leitura_never_unlabelled(self):
        bad = {"bd falhou (rc 1) mesmo com corpo válido": (1, comments(gate_text("x " + TAGS))[1]), "bd não rodou ou estourou o prazo": (None, ""), "lixo": (0, "{not json garbage"), "não é lista": (0, "{}"),
               "sem parte bloqueante": comments("outro comentário", "Gate FAILED.\nsem o marcador"), "lista vazia": (0, "[]")}
        beads = {"b%d" % i: v for i, v in reversed(list(enumerate(bad.values())))}  # out of order: the report sorts
        beads["ok"] = gate_text("x " + TAGS)
        r, j, fake = self.refuse(beads)
        self.assertEqual((r["total"], r["labeled"], r["unlabeled"], r["unread"]), (7, 1, 0, 6))
        self.assertEqual(r["unread_runs"], sorted("gr-b%d" % i for i in range(6)))
        self.assertFalse(j["complete"])
        self.assertTrue(any("SEM LEITURA" in x for x in j["gaps"]))

    def test_a_refusal_with_no_gate_run_is_sem_leitura_and_nothing_is_read_for_it(self):
        self.log(rec("n1", "FAIL", reason=REV, gate_run=""), rec("n2", "FAIL", reason=REV, gate_run=None), {k: v for k, v in rec("n3", "FAIL", reason=REV).items() if k != "gate_run"}, rec("n4", "FAIL", reason=REV, gate_run=123))
        rc, j, fake = self.js(NO_RIGS)
        self.assertEqual((j["refusals"]["unread"], j["refusals"]["unread_runs"], reads(fake)), (4, ["bead:n1", "bead:n2", "bead:n3", "bead:n4"], []))

    def test_comment_shapes_the_reader_must_survive(self):
        r, j, _ = self.refuse({"s1": "Non-blocking findings:\nx\n" + gate_text("a (root-class:abc)"), "s2": "Blocking reasons:\nBlocking issue 1: a (root-class:last-tag",
                               "s3": (0, '[3, {"text": 5}, {"text": "Blocking reasons:\\nBlocking issue 1: a (root-class:in-list)"}]'), "s4": comments(gate_text("a (root-class:first)"), gate_text("b (root-class:second)"))})
        self.assertEqual(({n: c["refusals"] for n, c in r["classes"].items()}, r["labeled"], r["unread"]), ({"abc": 1, "first": 1, "in-list": 1, "last-tag": 1, "second": 1}, 4, 0))

    def test_only_reviewer_rejections_inside_the_window_are_refusals(self):
        lo, hi = "2026-11-19T16:00:00Z", NOW
        self.log(rec("m1", "FAIL", reason=MERGE), rec("m2", "FAIL", reason="source bead closed"), rec("m3", "FAIL"), rec("p1", "PASS", reason=REV), rec("o1", "FAIL", reason=REV, ts=OLD),
                 rec("e1", "FAIL", reason=REV, ts=lo), rec("e2", "FAIL", reason=REV, ts=hi), rec("e3", "FAIL", reason=REV, ts="2026-11-19T15:59:59Z"), rec("e4", "FAIL", reason=REV, ts="2026-11-26T16:00:01Z"))
        table = dict(NO_RIGS)
        table.update({rd("gr-e1"): comments(gate_text("x")), rd("gr-e2"): comments(gate_text("y"))})
        rc, j, fake = self.js(table)
        self.assertEqual((j["refusals"]["total"], j["refusals"]["other_fail"], sorted(reads(fake))), (2, 3, [rd("gr-e1"), rd("gr-e2")]))
        self.assertEqual((j["first_attempt"]["n"], j["first_attempt"]["approved"]), (6, 1))  # m1-m3, p1 and the two edges; the beads at lo-1s, now+1s and OLD are out

    def test_a_gate_run_is_read_once_and_the_group_list_says_when_it_is_cut(self):
        n = P.TOP + 2
        self.log(*[rec("d%d" % i, "FAIL", reason=REV, gate_run="gr-shared" if i < 2 else "gr-d%d" % i) for i in range(n)])
        table = dict(NO_RIGS)
        table.update({rd("gr-shared"): comments(gate_text("zz comum")), **{rd("gr-d%d" % i): comments(gate_text("titulo %s" % chr(97 + i))) for i in range(2, n)}})
        rc, j, fake = self.js(table)
        r = j["refusals"]
        self.assertEqual((reads(fake).count(rd("gr-shared")), r["unlabeled_groups_total"], len(r["unlabeled_groups"])), (1, n - 1, P.TOP))
        self.assertEqual([(g["key"], g["refusals"]) for g in r["unlabeled_groups"][:3]], [("zz comum", 2), ("titulo c", 1), ("titulo d", 1)])
        self.assertIn("… mais 1 grupo(s) sem rótulo só no JSON", self.go(table)[1])


W1, W2 = "2026-11-12T16:00:00Z", "2026-11-19T16:00:00Z"  # --days 14 ending NOW: the older week is [W1, W2], the newer (W2, NOW]


def cellw(frm, to, lab, unl, unread, pct, state):
    return {"from": frm, "to": to, "labeled": lab, "unlabeled": unl, "unread": unread, "n": lab + unl, "pct": pct, "state": state}


class Weekly(T):
    def weeks(self, spec, *args):
        """spec: [(bead, ts, kind)], kind labeled|unlabeled|unread, one reviewer FAIL each -> (refusals.weekly, the whole report)."""
        table = dict(NO_RIGS)
        self.log(*[rec(b, "FAIL", reason=REV, ts=ts) for b, ts, _ in spec])
        for b, _, kind in spec:
            table[rd("gr-" + b)] = (1, "") if kind == "unread" else comments(gate_text("x " + TAGS if kind == "labeled" else "sem etiqueta"))
        self.table = table
        rc, j, _ = self.js(table, *args)
        return j["refusals"]["weekly"], j

    def test_the_labelled_fraction_is_per_week_oldest_first_and_only_over_the_refusals_that_were_read(self):
        old = [("o%d" % i, "2026-11-1%dT10:00:00Z" % (3 + i), k) for i, k in enumerate(("labeled", "unlabeled", "unlabeled", "unlabeled"))]
        new = [("n%d" % i, "2026-11-2%dT10:00:00Z" % i, k) for i, k in enumerate(("labeled",) * 4 + ("unlabeled",))] + [("u1", "2026-11-22T10:00:00Z", "unread")]
        w, j = self.weeks(old + new, "--days", "14")
        self.assertEqual(w, [cellw(W1, W2, 1, 3, 0, 25.0, "n<5"), dict(cellw(W2, NOW, 4, 1, 1, 80.0, "ok"))])  # the unread one is in `unread`, not in the denominator
        self.assertEqual((j["refusals"]["total"], j["refusals"]["labeled"], j["refusals"]["unlabeled"], j["refusals"]["unread"]), (10, 5, 4, 1))  # the totals the meter always had are untouched

    def test_a_week_with_nothing_read_is_sem_dado_never_zero_percent(self):
        w, _ = self.weeks([("a", "2026-11-25T10:00:00Z", "unread"), ("b", "2026-11-24T10:00:00Z", "unread")], "--days", "14")
        self.assertEqual(w, [cellw(W1, W2, 0, 0, 0, None, "sem dado"), cellw(W2, NOW, 0, 0, 2, None, "sem dado")])
        self.assertEqual(self.go(self.table, "--days", "14")[1].splitlines()[1], "  rotuladas por semana (só as lidas): 11-12→11-19 sem dado · 11-19→11-26 sem dado +2 SEM LEITURA")  # in words, never 0%
        self.log(rec("p"))  # no refusal at all
        self.assertEqual([c["state"] for c in self.js(NO_RIGS, "--days", "14")[1]["refusals"]["weekly"]], ["sem dado", "sem dado"])

    def test_every_refusal_lands_in_exactly_one_week_the_edges_included(self):
        spec = [("a", NOW, "labeled"), ("b", "2026-11-19T16:00:01Z", "labeled"), ("c", W2, "unlabeled"), ("d", W1, "unlabeled"), ("e", "2026-11-12T16:00:01Z", "labeled")]
        w, j = self.weeks(spec, "--days", "14")
        self.assertEqual([(c["from"], c["to"], c["labeled"], c["unlabeled"]) for c in w], [(W1, W2, 1, 2), (W2, NOW, 2, 0)])  # a refusal exactly 7 days old is the OLDER week's; `lo` itself is in the window
        self.assertEqual((sum(c["n"] for c in w), [c["pct"] for c in w]), (j["refusals"]["total"], [33.3, 100.0]))  # the percentage keeps one decimal

    def test_the_cells_follow_days_the_oldest_one_clipped_by_the_window(self):
        spec = [("a", "2026-11-25T10:00:00Z", "labeled"), ("b", "2026-11-17T10:00:00Z", "unlabeled")]
        for days, want in (("7", [(W2, NOW)]), ("10", [("2026-11-16T16:00:00Z", W2), (W2, NOW)]), ("14", [(W1, W2), (W2, NOW)]), ("21", [("2026-11-05T16:00:00Z", W1), (W1, W2), (W2, NOW)])):
            with self.subTest(days):
                w, _ = self.weeks(spec, "--days", days)
                self.assertEqual([(c["from"], c["to"]) for c in w], want)
        self.assertEqual([sum(c["n"] for c in self.weeks(spec, "--days", d)[0]) for d in ("7", "10")], [1, 2])  # the 11-17 refusal is outside a 7-day window and inside a 10-day one

    def test_text_mode_shows_the_fraction_right_under_the_headline(self):
        w, _ = self.weeks([("a", "2026-11-25T10:00:00Z", "labeled"), ("b", "2026-11-24T10:00:00Z", "unlabeled"), ("c", "2026-11-23T10:00:00Z", "unread")], "--days", "7")
        out = self.go(self.table_for(("a", "labeled"), ("b", "unlabeled"), ("c", "unread")), "--days", "7")[1].splitlines()
        self.assertEqual(out[1], "  rotuladas por semana (só as lidas): 11-19→11-26 n<5 (1/2) +1 SEM LEITURA")
        rows = [rec("r%d" % i, "FAIL", reason=REV, ts="2026-11-2%dT10:00:00Z" % (i % 6)) for i in range(5)]
        self.log(*rows)
        t = dict(NO_RIGS)
        t.update({rd("gr-r%d" % i): comments(gate_text("x " + TAGS)) for i in range(5)})
        self.assertEqual(self.go(t, "--days", "7")[1].splitlines()[1], "  rotuladas por semana (só as lidas): 11-19→11-26 100% (5/5)")

    def table_for(self, *spec):
        t = dict(NO_RIGS)
        t.update({rd("gr-" + b): (1, "") if kind == "unread" else comments(gate_text("x " + TAGS if kind == "labeled" else "sem etiqueta")) for b, kind in spec})
        return t

    def test_nao_sei_report_has_no_weeks(self):
        rc, j, _ = self.js()  # no log at all
        self.assertTrue(rc == 2 and j["refusals"] is None)


def ls(store, cls):
    return ("-C", store, "list", "--label", "root-class:" + cls, "--status", "all", "--json", "--limit", "0")


def beads(*created):
    return (0, json.dumps([{"id": "x%d" % i, "created_at": c} for i, c in enumerate(created)]))


def rigs(*pairs):
    return (0, json.dumps({"rigs": [{"name": n, "path": p} for n, p in pairs]}))


def cell(total, win, undated=0):
    return {"total": total, "in_window": win, "undated": undated}


class Inventory(T):
    def test_labelled_beads_are_counted_per_store_for_every_class_seen(self):
        s = self.stores("city", "wa", "ps")
        self.log(rec("b1", "FAIL", reason=REV))
        t = {("rig", "list", "--json"): (0, json.dumps({"rigs": [{"name": "gascity", "path": s[0]}, {"name": "wa", "path": s[1]}, {"name": "wa-de-novo", "path": s[1]}, {"name": "ps", "work_dir": s[2]}, {"name": "sem-path"}]})),
             rd("gr-b1"): comments(gate_text("x (root-class:armed-but-unreachable)"))}
        t.update({ls(s[0], "armed-but-unreachable"): beads(IN, OLD), ls(s[1], "armed-but-unreachable"): beads(), ls(s[2], "armed-but-unreachable"): beads(IN),
                  ls(s[0], "error-vs-empty"): beads(IN, IN, OLD, "bogus"), ls(s[1], "error-vs-empty"): beads(OLD, "2026-11-19T16:00:00Z", NOW), ls(s[2], "error-vs-empty"): beads(),
                  ls(s[0], "transient-infra-is-terminal"): beads(), ls(s[1], "transient-infra-is-terminal"): beads(IN), ls(s[2], "transient-infra-is-terminal"): beads()})
        rc, j, fake = self.js(t, "--class", "transient-infra-is-terminal", "--class", "error-vs-empty")
        inv = j["inventory"]
        self.assertEqual((rc, inv["state"], inv["stores"], inv["unmeasured"]), (0, "ok", ["gascity", "wa", "ps"], []))
        self.assertEqual(inv["classes"], {"armed-but-unreachable": {"gascity": cell(2, 1), "wa": cell(0, 0), "ps": cell(1, 1)}, "error-vs-empty": {"gascity": cell(4, 2, 1), "wa": cell(3, 2), "ps": cell(0, 0)},
                                          "transient-infra-is-terminal": {"gascity": cell(0, 0), "wa": cell(1, 1), "ps": cell(0, 0)}})
        self.assertFalse(j["complete"])  # one bead whose created_at cannot be read: its place in the window is unknown
        self.assertEqual(sum(c[2:3] == ("list",) for c in fake.calls), 9)  # a store shared by two rigs is asked once

    def test_a_cell_that_cannot_be_read_is_none_never_zero(self):
        s = self.stores(*"abcdefg")
        self.log(rec("a"))
        t = {("rig", "list", "--json"): rigs(*[(n, "{R}/" + n) for n in "abcdefgh"])}  # h has no directory
        t.update({ls(s[0], "error-vs-empty"): (0, "[]"), ls(s[1], "error-vs-empty"): (0, json.dumps({"issues": [3, {"created_at": IN}]})), ls(s[2], "error-vs-empty"): (1, ""), ls(s[3], "error-vs-empty"): (None, ""),
                  ls(s[4], "error-vs-empty"): (0, "{garbage"), ls(s[5], "error-vs-empty"): (0, '{"x": 1}'), ls(s[6], "error-vs-empty"): (0, "null")})
        rc, j, fake = self.js(t)
        inv = j["inventory"]
        self.assertEqual(inv["classes"]["error-vs-empty"], {"a": cell(0, 0), "b": cell(2, 1, 1), "c": None, "d": None, "e": None, "f": None, "g": None, "h": None})
        self.assertEqual(sorted(inv["unmeasured"]), ["c×error-vs-empty: bd falhou (rc=1)", "d×error-vs-empty: bd não rodou ou estourou o prazo", "e×error-vs-empty: resposta ilegível", "f×error-vs-empty: resposta ilegível",
                                                      "g×error-vs-empty: resposta ilegível", "h×error-vs-empty: diretório ausente"])
        self.assertTrue(not j["complete"] and any("6 célula" in x for x in j["gaps"]) and ls("{R}/h", "error-vs-empty") not in fake.calls)
        out = self.go(t)[1].splitlines()
        self.assertIn("inventário 8 store(s), 6 célula(s) NÃO MEDIDA(S) ·", out[0])
        self.assertEqual([" ".join(x.split()) for x in out if x.startswith("  inventário")], ["inventário error-vs-empty a 0 (+0 na janela) · b 2 (+1 na janela) · c NÃO MEDIDO · d NÃO MEDIDO · e NÃO MEDIDO · f NÃO MEDIDO · g NÃO MEDIDO · h NÃO MEDIDO"])

    def test_rig_stores_reads_both_shapes_and_only_real_paths(self):
        for d, want in (({"rigs": [{"name": "a", "path": "/x"}, {"path": "/y/z"}, {"name": "w", "work_dir": "/w"}, {"name": "n", "path": 5}, {"name": "d", "path": "/x"}, {"name": "e", "path": "  "}]}, {"a": "/x", "z": "/y/z", "w": "/w"}),
                        ([{"name": "l", "path": "/l"}], {"l": "/l"})):
            with self.subTest(want), mock.patch.object(P, "run", lambda argv, t, d=d: (0, json.dumps(d))):
                self.assertEqual(P.rig_stores("gc"), (want, ""))

    def test_rig_list_unreadable_is_nao_medido_while_the_refusals_still_count(self):
        for name, answer, why in (("rc 1", (1, ""), "falhou (rc=1)"), ("não rodou", (None, ""), "não rodou"), ("lixo", (0, "{garbage"), "ilegível"), ("não é lista nem objeto com rigs", (0, "3"), "ilegível"),
                                  ("objeto sem rigs", (0, "{}"), "ilegível"), ("sem rigs", (0, '{"rigs": []}'), "nenhum path"), ("rig sem path", (0, '{"rigs": [{"name": "x"}, 4]}'), "nenhum path")):
            with self.subTest(name):
                self.log(rec("a"))
                rc, j, fake = self.js({("rig", "list", "--json"): answer})
                self.assertEqual((rc, j["inventory"]["state"], j["inventory"]["stores"], j["inventory"]["classes"]), (0, "nao-medido", [], {}))
                self.assertIn(why, j["inventory"]["why"])
                self.assertTrue(j["first_attempt"]["n"] == 1 and not j["complete"] and any("inventário NÃO MEDIDO" in x for x in j["gaps"]))


class Output(T):
    def test_window_follows_days_and_now(self):
        self.log(rec("a", ts="2026-11-14T10:00:00Z"), rec("b"))
        for days, frm, n in (("7", "2026-11-19T16:00:00Z", 1), ("14", "2026-11-12T16:00:00Z", 2)):
            with self.subTest(days):
                rc, j, _ = self.js(NO_RIGS, "--days", days)
                self.assertEqual((j["window"], j["first_attempt"]["n"]), ({"days": int(days), "from": frm, "to": NOW}, n))

    def test_evaluator_hash_is_the_hash_of_this_very_file_and_unreadable_is_not_a_hash(self):
        self.log(rec("a"))
        rc, j, _ = self.js(NO_RIGS)
        self.assertEqual(j["evaluator"], {"script": "gate-refusal-meter.py", "sha256": hashlib.sha256(slurp(SUT, "rb")).hexdigest()})
        with mock.patch.object(P, "__file__", "/nonexistent/gate-refusal-meter.py"):
            rc, j, _ = self.js(NO_RIGS)
        self.assertEqual((j["evaluator"]["sha256"], j["complete"], any("avaliador" in x for x in j["gaps"])), (None, False, True))
        os.remove(self.logpath)
        self.assertTrue(self.js()[1]["evaluator"]["sha256"])  # a NÃO SEI report carries it too

    def test_text_mode_prints_the_line_first_then_the_detail(self):
        s = self.stores("city")
        self.log(rec("b1"), rec("b2", "FAIL", reason=REV), rec("b3", "FAIL", reason=REV), rec("b4", "FAIL", reason=REV), rec("m1", "FAIL", reason=MERGE), rec("b5"), rec("b6"))
        t = {("rig", "list", "--json"): rigs(("gascity", s[0])), ls(s[0], "error-vs-empty"): beads(IN, OLD), rd("gr-b2"): comments(gate_text("x " + TAGS)), rd("gr-b3"): comments(gate_text("teste que passa")), rd("gr-b4"): (1, "")}
        rc, out, err, _ = self.go(t)
        self.assertEqual([" ".join(x.split()) for x in out.splitlines()], [  # spacing is layout, the words and their order are the contract
            "gate-refusal-meter 7d até 2026-11-26T16:00:00Z: 1ª tentativa 43% (3/7) · recusas 3 = 1 rotuladas + 1 sem rótulo + 1 SEM LEITURA (+1 outras FAIL) · inventário 1 store(s) · INCOMPLETO",
            "rotuladas por semana (só as lidas): 11-19→11-26 n<5 (1/2) +1 SEM LEITURA", "classe error-vs-empty 1 recusa(s) em 1 bead(s)", "sem rótulo 1× teste que passa (ex.: b3)", "inventário error-vs-empty gascity 2 (+1 na janela)",
            "⚠ 1 recusa(s) SEM LEITURA do comentário do gate-run: não entram em classe nem em sem-rótulo"])
        self.assertEqual((rc, err), (0, ""))
        rc, j, _ = self.js(t)
        self.assertEqual(j["line"], out.splitlines()[0])

    def test_line_says_what_was_not_measured(self):
        self.log(rec("a"), rec("b"))
        rc, j, _ = self.js(NO_RIGS)
        self.assertIn("1ª tentativa n<5, sem conclusão (n=2)", j["line"])
        self.assertIn("inventário NÃO MEDIDO (gc rig list falhou (rc=1))", j["line"])
        self.log(rec("o", ts=OLD))
        self.assertIn("1ª tentativa sem dado", self.js(NO_RIGS)[1]["line"])

    def test_save_writes_json_and_text_and_a_failed_run_overwrites_the_last_good_one(self):
        gc = os.path.join(self.city, ".gc")
        last = lambda ext: os.path.join(gc, "gate-refusal-meter.last." + ext)  # noqa: E731
        self.log(rec("a"))
        rc, out, _, _ = self.go(NO_RIGS, "--save", "--json")
        self.assertEqual((slurp(last("json")), slurp(last("txt")).splitlines()[0]), (out, json.loads(out)["line"]))
        self.assertEqual(sorted(os.listdir(gc)), ["gate-refusal-meter.last.json", "gate-refusal-meter.last.txt", "quality-gate.jsonl"])  # no temp file left
        os.remove(self.logpath)
        rc, out, _, _ = self.go(None, "--save")
        self.assertEqual((rc, json.loads(slurp(last("json")))["gate_log"]["state"], slurp(last("txt")).startswith("NÃO SEI")), (2, "absent", True))  # never last week's numbers
        self.log(rec("a"))
        os.remove(last("json")), os.makedirs(last("json"))
        rc, out, err, _ = self.go(NO_RIGS, "--save")
        self.assertEqual((rc, "não consegui gravar" in err, out.startswith("gate-refusal-meter")), (1, True, True))
        self.assertEqual([x for x in os.listdir(gc) if ".tmp." in x], [])
        os.remove(self.logpath)
        rc, out, err, _ = self.go(None, "--save")
        self.assertEqual((rc, "não consegui gravar" in err), (2, True))  # a failed save never hides the NÃO SEI exit code


class Real(T):
    def test_run_answers_rc_and_output_and_is_none_when_it_cannot_run(self):
        self.assertEqual(P.run([sys.executable, "-c", "print('oi'); raise SystemExit(3)"], 30), (3, "oi\n"))
        self.assertEqual(P.run([sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'\\xff')"], 30), (0, "�"))
        self.assertEqual(P.run(["/nonexistent/bd"], 5), (None, ""))
        with mock.patch("subprocess.run", side_effect=subprocess.TimeoutExpired("bd", 1)):
            self.assertEqual(P.run(["bd"], 1), (None, ""))

    def test_cli_end_to_end_with_real_executables_named_by_flag_and_by_env(self):
        s = os.path.join(self.root, "s1")
        os.makedirs(s)
        for name, body in (("fakegc", 'printf \'{"rigs":[{"name":"r1","path":"%s"}]}\' "$R1"'), ("fakebd", 'echo "$@" >> "$LOGF"; case "$*" in *comments*) echo \'[{"text":"Blocking reasons:\\nBlocking issue 1: z (root-class:abc-d)"}]\';; *) echo \'[]\';; esac')):
            with open(os.path.join(self.root, name), "w") as fh:
                fh.write("#!/bin/sh\n" + body + "\n")
            os.chmod(os.path.join(self.root, name), 0o755)
        self.log(rec("b1", "FAIL", reason=REV))
        gc_, bd_ = os.path.join(self.root, "fakegc"), os.path.join(self.root, "fakebd")
        good = {k: v for k, v in os.environ.items() if k not in ("GC_CITY_PATH", "GC_CITY")}
        good.update(R1=s, LOGF=os.path.join(self.root, "calls.log"))
        for extra, env in (([], dict(good, GC_CITY_PATH=self.city, GATE_REFUSAL_GC=gc_, GATE_REFUSAL_BD=bd_)),
                           (["--gc", gc_, "--bd", bd_], dict(good, GC_CITY=self.city, GATE_REFUSAL_GC="/nonexistent/gc", GATE_REFUSAL_BD="/nonexistent/bd"))):
            p = subprocess.run([sys.executable, "-I", SUT, "--now", NOW, "--json"] + extra, capture_output=True, text=True, env=env)
            j = json.loads(p.stdout)
            self.assertEqual((p.returncode, list(j["refusals"]["classes"]), j["inventory"]["classes"]["abc-d"]["r1"], j["complete"]), (0, ["abc-d"], {"total": 0, "in_window": 0, "undated": 0}, True))


if __name__ == "__main__":
    unittest.main()
