#!/usr/bin/env python3
"""test_auto_melhoria_weekly.py (ga-mw5gdyu.4): hermetic suite for scripts/auto-melhoria-weekly.py. The gate log, the registry and the confs are REAL files in a temp city; the confs come out of the REAL ratchet writer and the weekly numbers
are the REAL meter's. Only the processes are fake: `FakeRun` records every call the script itself makes (notify, gc mail, bd list) and `meter_run` answers the meter's own reads (gate-run comments; the inventory is left unreadable on purpose).
`python3 -I scripts/test_auto_melhoria_weekly.py` (3.9+); AMW_UNDER_TEST=<copy that sits beside the real siblings> runs it against a mutant."""
import contextlib, datetime, importlib.util, io, json, os, shutil, sys, tempfile, time, types, unittest  # noqa: E401
from unittest import mock

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SUT = os.environ.get("AMW_UNDER_TEST") or os.path.join(HERE, "auto-melhoria-weekly.py")
_spec = importlib.util.spec_from_file_location("amw", SUT)
W = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(W)

T0 = datetime.datetime(2026, 11, 30, 11, 0, 0, tzinfo=datetime.timezone.utc)  # a Monday, 08:00 in UTC-3: the first second after the 00h-08h silence window
NOW = "2026-11-30T11:00:00Z"
MERGE = "Merge failed after all-PASS verdict"  # a FAIL nobody rejected: no comment is read for it


def at(**kw):
    return (T0 - datetime.timedelta(**kw)).strftime("%Y-%m-%dT%H:%M:%SZ")


def comment(cls):
    return "Blocking reasons:\nBlocking issue 1: x%s\nNon-blocking findings:\nnada" % (" root-class:" + cls if cls else "")


class Base(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="amw-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.city = os.path.join(self.root, "city")
        self.state = os.path.join(self.city, ".gc")
        os.makedirs(self.state)
        os.makedirs(os.path.join(self.city, "scripts"))
        old = os.environ.get("TZ")
        os.environ["TZ"] = "BRT3"  # UTC-3 without tzdata
        time.tzset()
        self.addCleanup(lambda: (os.environ.pop("TZ", None) if old is None else os.environ.update(TZ=old), time.tzset()))
        self.n, self.rows, self.comments, self.reg_rows = 0, [], {}, []
        self.calls, self.rc, self.beads = [], {}, (0, "[]")  # self.rc: what notify / mail answer; self.beads: what `bd list` answers
        self.run_patch, self.meter_patch = mock.patch.object(W, "run", self.fake_run), mock.patch.object(W.M, "run", self.meter_run)
        self.run_patch.start(), self.meter_patch.start()
        self.addCleanup(self.run_patch.stop), self.addCleanup(self.meter_patch.stop)
        self.reg()

    def fake_run(self, argv, timeout):
        self.calls.append(argv)
        if argv[0] == "notify":
            return self.rc.get("notify", (0, ""))
        if argv[:3] == ["gc", "mail", "send"]:
            return self.rc.get("mail", (0, ""))
        if argv[:4] == ["bd", "-C", self.city, "list"]:
            return self.beads
        raise AssertionError("unplanned call: %r" % (argv,))

    def meter_run(self, argv, timeout):
        if argv[1:4] == ["-C", self.city, "comments"]:
            assert argv[0] == "bd", argv
            text = self.comments.get(argv[4])
            return (0, json.dumps([{"text": text}])) if text is not None else (1, "")
        if argv[1:3] == ["rig", "list"]:
            assert argv[0] == "gc", argv
            return 1, ""  # the inventory is not the summary's business: its failure must not leak into the report
        raise AssertionError("unplanned meter call: %r" % (argv,))

    def week(self, back, ok=0, merge=0, refused=()):
        """First verdicts of fresh beads in the week `back` weeks before NOW (0 = the current one). `refused`: one reviewer refusal each, its comment naming that class (None = no label, False = comment unreadable)."""
        for result, reason, cls in [("PASS", "", None)] * ok + [("FAIL", MERGE, None)] * merge + [("FAIL", "Reviewer 1 FAIL: x", c) for c in refused]:
            self.n += 1
            b = "ga-w%03d" % self.n
            self.rows.append({"ts": at(days=7 * back + 1, minutes=self.n), "event": "dispatcher_complete", "bead": b, "rig": "gascity", "result": result, "reason": reason, "gate_run": "gr-" + b, "dry_run": "0"})
            if result == "FAIL" and reason != MERGE and cls is not False:
                self.comments["gr-" + b] = comment(cls)

    def reg(self, *rows):
        self.reg_rows += rows
        with open(os.path.join(self.city, "scripts", "gate-refusal-checks.registry.tsv"), "w") as fh:
            fh.write("class\tstatus\tcheck\tbead\tsince\tnote\n" + "".join(r + "\n" for r in self.reg_rows))

    def trial(self, cls, phase="trial", entrou=None, em=None, since="2026-11-10", status="em-teste", conf_since=None):
        """The registry row and the conf the REAL ratchet writer leaves for it (`conf_since` = the trial the conf records, when it is not the row's)."""
        self.reg("\t".join((cls, status, "packs/town-deltas/assets/%s-check.py (x)" % cls, "ga-c1", since, "n")))
        extra = {"em": em, "why": "porque", "evidence": {}} if em else {}
        self.assertEqual(W.R.put(types.SimpleNamespace(state=self.state), cls, phase, conf_since or since, entrou or at(days=30), **extra), "")

    def clear(self, path):
        shutil.rmtree(path, ignore_errors=True)
        if os.path.exists(path):
            os.remove(path)

    def put(self, path, text=""):
        with open(path, "w") as fh:
            fh.write(text)

    def go(self, *flags, now=NOW, log=True, js=True):
        if log:
            self.put(os.path.join(self.state, "quality-gate.jsonl"), "".join((r if isinstance(r, str) else json.dumps(r)) + "\n" for r in self.rows))
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = W.main((["--json"] if js else []) + ["--city", self.city, "--now", now, "--bd", "bd", "--gc", "gc", "--notify", "notify"] + list(flags))
        return rc, (json.loads(out.getvalue()) if js else out.getvalue()), err.getvalue()

    def lines(self, *flags, **kw):
        rc, j, _ = self.go(*flags, **kw)
        return rc, j, j["message"].split("\n")


class Approval(Base):
    def test_two_weeks_side_by_side_with_the_change_in_points(self):
        for name, cur, prev, want in (("subiu, mas dentro do ruído de 50 beads por semana", (31, 19), (29, 21), "62% (31/50) vs 58% (29/50) na semana anterior (+4 pts, dentro do ruído)"),
                                      ("subiu de verdade", (45, 5), (25, 25), "90% (45/50) vs 50% (25/50) na semana anterior (+40 pts)"), ("caiu de verdade", (25, 25), (45, 5), "50% (25/50) vs 90% (45/50) na semana anterior (-40 pts)"),
                                      ("+16 ainda cabe no acaso", (38, 12), (30, 20), "76% (38/50) vs 60% (30/50) na semana anterior (+16 pts, dentro do ruído)"), ("+20 já não cabe", (40, 10), (30, 20), "80% (40/50) vs 60% (30/50) na semana anterior (+20 pts)"),
                                      ("taxa que não é inteira: arredonda, não trunca", (7, 2), (4, 1), "78% (7/9) vs 80% (4/5) na semana anterior (-2 pts, dentro do ruído)"),
                                      ("cada semana pesa com o seu n (semana anterior pequena)", (30, 20), (1, 4), "60% (30/50) vs 20% (1/5) na semana anterior (+40 pts)"),
                                      ("cada semana pesa com o seu n (semana atual pequena)", (1, 4), (30, 20), "20% (1/5) vs 60% (30/50) na semana anterior (-40 pts)"),
                                      ("caiu, dentro do ruído", (4, 1), (5, 0), "80% (4/5) vs 100% (5/5) na semana anterior (-20 pts, dentro do ruído)"), ("igual", (3, 2), (3, 2), "60% (3/5) vs 60% (3/5) na semana anterior (igual)"),
                                      ("n<5 não conclui", (3, 1), (29, 21), "n<5 (n=4) vs 58% (29/50) na semana anterior"), ("sem dado", (0, 0), (29, 21), "sem dado vs 58% (29/50) na semana anterior")):
            with self.subTest(name):
                self.rows = []
                self.week(0, ok=cur[0], merge=cur[1])
                self.week(1, ok=prev[0], merge=prev[1])
                rc, j, ls = self.lines()
                self.assertEqual((rc, ls[0]), (0, "1ª tentativa: " + want))

    def test_a_verdict_on_the_boundary_belongs_to_exactly_one_week(self):
        for ts, week in ((at(days=7), "cur"), (at(days=7, seconds=1), "prev")):
            with self.subTest(ts):
                self.rows = [{"ts": ts, "event": "dispatcher_complete", "bead": "b", "result": "PASS", "reason": "", "gate_run": "g", "rig": "r", "dry_run": "0"}]
                _, j, _ = self.lines()
                self.assertEqual({k: j["weeks"][k]["n"] for k in ("cur", "prev")}, {"cur": int(week == "cur"), "prev": int(week == "prev")})

    def test_an_unreadable_gate_log_is_not_a_zero_and_the_report_still_goes(self):
        log = os.path.join(self.state, "quality-gate.jsonl")
        for name, put, why in (("ausente", lambda: None, "ausente"), ("vazio", lambda: self.put(log), "sem nenhum veredito"), ("diretório", lambda: os.makedirs(log), "ilegível")):
            with self.subTest(name):
                self.calls[:] = []
                self.clear(log)
                put()
                rc, j, ls = self.lines("--apply", log=False)
                self.assertEqual((rc, j["complete"], j["weeks"]["cur"], j["refusals"]), (2, False, None, None))
                self.assertEqual((ls[0], ls[1]), ("1ª tentativa: NÃO MEDIDO (quality-gate.jsonl %s)" % why, "Recusas do portão: NÃO MEDIDO (quality-gate.jsonl %s)" % why))
                self.assertEqual(sorted(c[0] for c in self.calls if c[0] != "bd"), ["gc", "notify"])  # a blind week is not a quiet week: it is still said

    def test_a_partly_damaged_log_is_said_and_makes_the_report_incomplete(self):
        for name, row in (("linha rasgada", "{not json"), ("veredito sem bead", {"ts": at(days=1), "event": "dispatcher_complete", "bead": "", "result": "PASS", "reason": "", "gate_run": "g", "rig": "r", "dry_run": "0"})):
            with self.subTest(name):
                self.rows = []
                self.week(0, ok=5)
                self.rows.append(row)
                rc, j, ls = self.lines()
                self.assertEqual((rc, j["complete"], len(ls)), (2, False, 4))
                self.assertTrue(ls[3].startswith("⚠ quality-gate.jsonl: 1 ") and "subestimados" in ls[3], ls[3])

    def test_a_damaged_line_that_can_only_belong_to_the_week_before_is_said_too(self):
        self.week(0, ok=5)
        self.rows.append('{"ts":"2026-11-20T05:00:00Z" not json')  # older than the current week, inside the previous one
        rc, j, ls = self.lines()
        self.assertEqual((rc, len(ls), ls[3].startswith("⚠ quality-gate.jsonl: 1 ")), (2, 4, True))

    def test_a_previous_week_that_could_not_be_measured_is_said_and_the_current_one_still_is(self):
        for name, damaged in (("só a semana anterior falhou", False), ("e há linha rasgada: o aviso vem da semana atual", True)):
            with self.subTest(name):
                self.rows = []
                self.week(0, ok=5)
                self.rows += ["{not json"] * damaged
                real, seen = W.M.measure, []

                def second_raises(args, t):
                    seen.append(t)
                    if len(seen) == 2:
                        raise RuntimeError("bug do medidor")
                    return real(args, t)
                with mock.patch.object(W.M, "measure", second_raises):
                    rc, j, ls = self.lines()
                self.assertEqual((rc, j["complete"], ls[0], len(ls)), (2, False, "1ª tentativa: 100% (5/5); semana anterior NÃO MEDIDA (medidor falhou (RuntimeError))", 3 + damaged))
                self.assertTrue(not damaged or ls[3].startswith("⚠ quality-gate.jsonl: 1 "), ls)

    def test_the_inventory_gap_is_not_this_reports_gap(self):
        self.week(0, ok=5)
        rc, j, ls = self.lines()  # meter_run fails `gc rig list`: the meter's own `complete` is False and ours is not
        self.assertEqual((rc, j["complete"], len(ls)), (0, True, 3))


class Classes(Base):
    def test_classes_by_refusals_top_three_the_labelled_fraction_and_the_unread(self):
        self.week(0, ok=3, merge=2, refused=["x-y"] * 2 + ["error-vs-empty"] * 5 + ["outra"] * 2 + ["comentario-mente"] * 3 + [None, None, False])  # x-y and outra tie at 2: the name decides, outra first
        rc, j, ls = self.lines()
        self.assertEqual((rc, j["refusals"]["total"], j["refusals"]["labeled"], j["refusals"]["unread"]), (0, 15, 12, 1))
        self.assertEqual(ls[1], "Recusas do portão: 15 (12 com classe-raiz, 1 sem leitura) · error-vs-empty 5, comentario-mente 3, outra 2, +1 classe(s)")

    def test_a_tie_is_broken_by_name_whatever_order_the_classes_arrive_in(self):
        rep = {"first_attempt": {"n": 5, "approved": 3, "pct": 60.0, "state": "ok"}, "gate_log": {"bad_maybe_in_window": 0, "unusable": 0},
               "refusals": {"total": 6, "labeled": 6, "unread": 0, "classes": {"z-z": {"refusals": 2, "beads": 1}, "m-m": {"refusals": 2, "beads": 1}, "a-a": {"refusals": 2, "beads": 1}}}}
        ok = {"state": "ok", "why": "", "n": 0, "classes": [], "unknown": 0}
        lines, _ = W.compose((rep, ""), (rep, ""), ok, dict(ok, entrou=[], promovida=[], desligada=[], unknown=[]))
        self.assertEqual(lines[1], "Recusas do portão: 6 (6 com classe-raiz) · a-a 2, m-m 2, z-z 2")

    def test_exactly_three_classes_are_all_listed_with_nothing_left_over(self):
        self.week(0, ok=3, refused=["a-a"] * 2 + ["b-b"] + ["c-c"] * 3)
        self.assertEqual(self.lines()[2][1], "Recusas do portão: 6 (6 com classe-raiz) · c-c 3, a-a 2, b-b 1")

    def test_no_refusal_and_no_class_are_real_zeros_not_missing(self):
        self.week(0, ok=5)
        self.assertEqual(self.lines()[2][1], "Recusas do portão: 0 (0 com classe-raiz)")
        self.week(0, refused=[None])
        self.assertEqual(self.lines()[2][1], "Recusas do portão: 1 (0 com classe-raiz)")


class Checks(Base):
    def setUp(self):
        super().setUp()
        self.week(0, ok=5)  # a readable gate log: what these tests move is the checks line

    def test_entered_promoted_and_switched_off_are_counted_by_their_own_dates(self):
        self.trial("entrou-agora", entrou=at(days=2))
        self.trial("promovida-agora", "promovida", entrou=at(days=20), em=at(days=1))
        self.trial("desligada-agora", "desligada", entrou=at(days=20), em=at(days=3))
        self.trial("decidida-antes", "desligada", entrou=at(days=40), em=at(days=9))
        self.trial("entrou-antes", entrou=at(days=8))
        self.trial("outro-teste", entrou=at(days=1), conf_since="2026-10-01")  # the conf records an older trial of the class (since differs): the ratchet will re-enter it, nothing happened this week
        self.trial("ja-ativa", status="ativa", entrou=at(days=1))
        rc, j, ls = self.lines()
        r = j["checks"]["ratchet"]
        self.assertEqual((rc, r["state"], r["entrou"], r["promovida"], r["desligada"], r["unknown"]), (0, "ok", ["entrou-agora"], ["promovida-agora"], ["desligada-agora"], []))
        self.assertEqual(ls[2], "Checagens: 0 pedidas · 1 entrou em teste (entrou-agora) · 1 promovida (promovida-agora) · 1 desligada (desligada-agora)")

    def test_classes_are_listed_by_name_whatever_the_order_of_the_registry(self):
        self.trial("zeta", entrou=at(days=1))
        self.trial("alfa", entrou=at(days=1))
        self.assertEqual(self.lines()[2][2], "Checagens: 0 pedidas · 2 entraram em teste (alfa, zeta) · 0 promovidas · 0 desligadas")

    def test_a_check_that_entered_and_was_decided_in_the_same_week_counts_in_both(self):
        self.trial("rapida", "promovida", entrou=at(days=5), em=at(days=1))
        _, j, _ = self.lines()
        self.assertEqual((j["checks"]["ratchet"]["entrou"], j["checks"]["ratchet"]["promovida"]), (["rapida"], ["rapida"]))

    def test_the_week_edges_count_at_both_ends_and_a_row_the_registry_could_not_read_is_unknown(self):
        edges = [(dict(days=7, seconds=1), False), (dict(days=7), True), (dict(), True), (dict(seconds=-1), False)]  # one second before the week, its first second, now, one second after now
        for i, (ago, _) in enumerate(edges):
            self.trial("borda-%d" % i, "promovida", entrou=at(**ago), em=at(**ago))
        self.reg("\t".join(("estranha", "banana", "x", "ga-c9", "2026-11-10", "n")))  # the registry reader reports a row with a status outside its vocabulary
        rc, j, ls = self.lines()
        want = ["borda-%d" % i for i, (_, counted) in enumerate(edges) if counted]
        r = j["checks"]["ratchet"]
        self.assertEqual((rc, r["entrou"], r["promovida"], len(r["unknown"]), "1 sem leitura" in ls[2]), (2, want, want, 1, True))

    def test_unreadable_registry_is_not_zero(self):
        path = os.path.join(self.city, "scripts", "gate-refusal-checks.registry.tsv")
        self.trial("promovida-agora", "promovida", entrou=at(days=20), em=at(days=1))  # a decision IS there, in the conf: without the registry nobody can tell which check it belongs to
        for name, put, why in (("ausente", lambda: None, "ausente"), ("sem cabeçalho", lambda: self.put(path, "lixo\n"), "sem cabeçalho"), ("diretório", lambda: os.makedirs(path), "ilegível")):
            with self.subTest(name):
                self.clear(path)
                put()
                rc, j, ls = self.lines()
                self.assertEqual((rc, j["checks"]["ratchet"]["state"], j["complete"], j["checks"]["ratchet"]["promovida"]), (2, "nao-medido", False, []))
                self.assertTrue(ls[2].endswith(" · em teste/promovidas/desligadas NÃO MEDIDO (registro %s)" % why), ls[2])

    def test_a_conf_nobody_can_read_or_that_is_not_ours_is_unknown_not_nothing(self):
        self.trial("boa", entrou=at(days=1))
        self.reg("\t".join(("sem-conf", "em-teste", "packs/town-deltas/assets/sem-conf-check.py", "ga-c2", "2026-11-10", "n")))  # no conf yet: the ratchet has not entered it, not a gap
        self.reg("\t".join(("alheia", "em-teste", "packs/town-deltas/assets/alheia-check.py", "ga-c3", "2026-11-10", "n")))
        with open(os.path.join(self.state, "alheia.conf"), "w") as fh:
            fh.write("mode=enforce\nenforce_pct=100\n")  # somebody else's conf: no `# ratchet` line
        self.reg("\t".join(("estragada", "em-teste", "packs/town-deltas/assets/estragada-check.py", "ga-c4", "2026-11-10", "n")))
        with open(os.path.join(self.state, "estragada.conf"), "w") as fh:
            fh.write("mode=banana\n")
        self.reg("\t".join(("sem-caminho", "em-teste", "lixo", "ga-c5", "2026-11-10", "n")))
        rc, j, ls = self.lines()
        r = j["checks"]["ratchet"]
        self.assertEqual((rc, r["entrou"], sorted(u.split(":")[0] for u in r["unknown"]), j["complete"]), (2, ["boa"], ["alheia", "estragada", "sem-caminho"], False))
        self.assertIn("alheia: a conf não é do ciclo", r["unknown"])
        self.assertIn("estragada: conf invalid:mode=banana", r["unknown"])
        self.assertIn("3 sem leitura", ls[2])

    def test_a_decided_record_without_a_readable_time_is_unknown(self):
        self.trial("sem-hora", "promovida", entrou=at(days=20), em="ontem")
        _, j, _ = self.lines()
        self.assertEqual((j["checks"]["ratchet"]["promovida"], j["checks"]["ratchet"]["unknown"]), ([], ["sem-hora: decisão sem hora legível"]))

    def test_requested_beads_of_the_loop_are_counted_by_creation_date(self):
        def b(i, days, *labels, ts=None):
            return {"id": "ga-r%d" % i, "status": "open", "created_at": ts or at(days=days), "labels": ["auto-melhoria:checagem"] + list(labels)}
        for name, out, want in (
                ("na janela e fora dela, nomes em ordem", [b(3, 1, "auto-melhoria:classe:c-d"), b(1, 2, "auto-melhoria:classe:a-b"), b(2, 9, "auto-melhoria:classe:velha")], (2, ["a-b", "c-d"], 0, 0)),
                ("bordas da semana", [b(1, 0, "auto-melhoria:classe:i-1", ts=at(days=7, seconds=1)), b(2, 0, "auto-melhoria:classe:i-2", ts=at(days=7)), b(3, 0, "auto-melhoria:classe:i-3", ts=at()), b(4, 0, "auto-melhoria:classe:i-4", ts=at(seconds=-1))], (2, ["i-2", "i-3"], 0, 0)),
                ("forma {issues: []}", {"issues": [b(1, 2, "auto-melhoria:classe:a-b")]}, (1, ["a-b"], 0, 0)),
                ("nenhuma bead é um zero de verdade", [], (0, [], 0, 0)),
                ("bead da semana sem classe legível conta, sem nome no texto", [b(1, 2), b(2, 2, "auto-melhoria:classe:c-d ruim")], (2, [], 0, 0)),
                ("rótulo que não é texto é ignorado", [b(1, 2, 5, None, "auto-melhoria:classe:a-b")], (1, ["a-b"], 0, 0)),
                ("caractere de controle cru dentro de um texto não derruba a leitura", '[{"id":"ga-r1","created_at":"%s","labels":["auto-melhoria:checagem","auto-melhoria:classe:a-b"],"description":"x\ty"}]' % at(days=2), (1, ["a-b"], 0, 0)),
                ("sem data legível não dá para pôr na semana: sem leitura, não zero", [b(1, 0, "auto-melhoria:classe:x", ts="ontem")], (0, [], 1, 2))):
            with self.subTest(name):
                self.beads = (0, out if isinstance(out, str) else json.dumps(out))
                rc, j, ls = self.lines()
                q = j["checks"]["requested"]
                self.assertEqual((q["state"], q["n"], q["classes"], q["unknown"], rc), ("ok",) + want)
        self.assertIn("1 sem leitura", ls[2])

    def test_the_bead_store_is_read_whole_and_more_than_three_names_are_cut_and_counted(self):
        self.beads = (0, json.dumps([{"id": "ga-r%d" % i, "status": "open", "created_at": at(days=1), "labels": ["auto-melhoria:checagem", "auto-melhoria:classe:c-%d" % i]} for i in (5, 3, 1, 4, 2)]))
        ls = self.lines()[2]
        self.assertIn(["bd", "-C", self.city, "list", "--label", "auto-melhoria:checagem", "--status", "all", "--json", "--limit", "0"], self.calls)
        self.assertTrue(ls[2].startswith("Checagens: 5 pedidas (c-1, c-2, c-3, +2) · "), ls[2])
        self.beads = (0, json.dumps([{"id": "ga-r%d" % i, "status": "open", "created_at": at(days=1), "labels": ["auto-melhoria:checagem", "auto-melhoria:classe:c-%d" % i]} for i in (3, 1, 2)]))
        self.assertTrue(self.lines()[2][2].startswith("Checagens: 3 pedidas (c-1, c-2, c-3) · "))

    def test_the_bead_store_failing_is_not_zero_requests(self):
        for name, ans, why in (("rc 1", (1, ""), "bd falhou (rc=1)"), ("rc 1 com corpo que parece uma resposta boa", (1, "[]"), "bd falhou (rc=1)"), ("não rodou", (None, ""), "bd não rodou ou estourou o prazo"),
                               ("json ruim", (0, "{not json"), "resposta do bd ilegível"), ("não é lista", (0, '"x"'), "resposta do bd ilegível"), ("bead sem labels", (0, '[{"id": "ga-1", "created_at": "%s"}]' % at(days=1)), "resposta do bd ilegível")):
            with self.subTest(name):
                self.beads = ans
                rc, j, ls = self.lines()
                self.assertEqual((rc, j["checks"]["requested"]["state"], j["complete"]), (2, "nao-medido", False))
                self.assertTrue(ls[2].startswith("Checagens: pedidas NÃO MEDIDO (%s) · " % why), ls[2])


class Silence(Base):
    def setUp(self):
        super().setUp()
        self.week(0, ok=5)

    def test_nothing_is_sent_inside_the_00h_08h_window_and_the_first_second_after_it_is_sent(self):
        for now, env, held, at_local in (("2026-11-30T10:59:59Z", {}, True, "07:59"), (NOW, {}, False, "08:00"), ("2026-11-30T03:00:00Z", {}, True, "00:00"), ("2026-11-30T02:59:59Z", {}, False, "23:59"),  # 23:59 is before the window starts
                                         ("2026-11-30T06:00:00Z", {}, True, "03:00"), ("2026-11-30T11:30:00Z", {"NIGHT_END_HOUR": "9"}, True, "08:30"), ("2026-11-30T15:00:00Z", {}, False, "12:00")):
            with self.subTest(at_local), mock.patch.dict(os.environ, env):
                self.calls[:] = []
                rc, j, _ = self.go("--apply", now=now)
                self.assertEqual((rc, j["silence"], bool([c for c in self.calls if c[0] in ("notify", "gc")]), j["delivery"] is not None), (0, {"held": held, "local": at_local}, not held, not held))

    def test_the_text_says_why_nothing_went(self):
        for now, env, want in (("2026-11-30T10:59:59Z", {}, "adiado: 07:59 local está na janela de silêncio"), (NOW, {"NIGHT_END_HOUR": "oito"}, "adiado: não consegui ler a janela de silêncio")):
            with self.subTest(want), mock.patch.dict(os.environ, env):
                rc, out, _ = self.go("--apply", now=now, js=False)
                self.assertTrue(out.startswith("Auto-melhoria da semana\n1ª tentativa:") and want in out.splitlines()[-1] and "nada foi enviado" in out, out)

    def test_a_window_nobody_can_read_holds_the_report_and_says_so(self):
        for name, patch in (("módulo ausente", mock.patch.object(W, "Q", None)), ("hora ilegível", mock.patch.dict(os.environ, {"NIGHT_END_HOUR": "oito"}))):
            with self.subTest(name), patch:
                self.calls[:] = []
                rc, j, _ = self.go("--apply")
                self.assertEqual((rc, j["silence"]["held"], [c for c in self.calls if c[0] in ("notify", "gc")]), (2, None, []))

    def test_the_dry_run_shows_the_hold_too_and_sends_nothing_either_way(self):
        self.assertEqual([self.go(now=n)[1]["silence"]["held"] for n in ("2026-11-30T10:59:59Z", NOW)], [True, False])
        self.assertEqual([c for c in self.calls if c[0] in ("notify", "gc")], [])


class Delivery(Base):
    def test_one_notify_and_one_mail_with_the_same_text(self):
        self.week(0, ok=5)
        rc, j, ls = self.lines("--apply")
        send = [c for c in self.calls if c[0] in ("notify", "gc")]
        self.assertEqual(rc, 0)
        self.assertEqual(send, [["notify", "-t", j["title"], "-p", "3", j["message"]], ["gc", "mail", "send", "mayor", "-s", j["subject"], "-m", j["message"]]])
        self.assertEqual((j["title"], j["subject"], j["delivery"]), ("Auto-melhoria da semana", "Auto-melhoria: resumo da semana 23/11 a 30/11", {"notify": "enviado", "mail": "enviado"}))

    def test_each_channel_is_tried_whatever_the_other_did(self):
        self.week(0, ok=5)
        for name, rc_, want in (("notify falhou", {"notify": (1, "")}, {"notify": "falhou", "mail": "enviado"}), ("mail falhou", {"mail": (3, "")}, {"notify": "enviado", "mail": "falhou"}),
                                ("notify não rodou", {"notify": (None, "")}, {"notify": "nao-rodou", "mail": "enviado"}), ("os dois", {"notify": (1, ""), "mail": (None, "")}, {"notify": "falhou", "mail": "nao-rodou"})):
            with self.subTest(name):
                self.calls[:], self.rc = [], rc_
                rc, j, _ = self.go("--apply")
                self.assertEqual((rc, j["delivery"], len([c for c in self.calls if c[0] in ("notify", "gc")])), (1, want, 2))

    def test_the_dry_run_prints_the_text_and_sends_nothing_and_the_apply_run_says_what_each_channel_did(self):
        self.week(0, ok=5)
        rc, out, _ = self.go(js=False)
        self.assertEqual((rc, [c for c in self.calls if c[0] in ("notify", "gc")]), (0, []))
        self.assertEqual(out.splitlines()[1:], ["1ª tentativa: 100% (5/5) vs sem dado na semana anterior", "Recusas do portão: 0 (0 com classe-raiz)", "Checagens: 0 pedidas · 0 entraram em teste · 0 promovidas · 0 desligadas",
                                                 "dry-run: nada foi enviado; --apply manda notify + mail ao Mayor"])
        self.rc["mail"] = (1, "")
        rc, out, _ = self.go("--apply", js=False)
        self.assertEqual((rc, out.splitlines()[-1]), (1, "notify enviado · mail falhou"))


class Shape(Base):
    def test_the_message_is_three_to_five_short_portuguese_lines_with_no_question(self):
        self.week(0, ok=3, merge=2, refused=["error-vs-empty"] * 5 + ["a-b", "c-d", "e-f", "g-h", None])
        self.week(1, ok=4, merge=3)
        self.trial("promovida-agora", "promovida", entrou=at(days=20), em=at(days=1))
        self.beads = (0, json.dumps([{"id": "ga-r1", "status": "open", "created_at": at(days=1), "labels": ["auto-melhoria:checagem", "auto-melhoria:classe:a-b"]}]))
        for flags in ((), ("--apply",)):
            _, j, ls = self.lines(*flags)
            self.assertTrue(3 <= len(ls) <= 5, ls)
            self.assertTrue(all(0 < len(x) <= 160 and x == x.strip() and "?" not in x and all(ord(c) >= 32 for c in x) for x in ls), ls)
            self.assertTrue(ls[0].startswith("1ª tentativa") and ls[1].startswith("Recusas do portão") and ls[2].startswith("Checagens"), ls)

    def test_the_week_is_named_by_local_dates(self):
        self.week(0, ok=5)
        _, j, _ = self.lines()
        self.assertEqual((j["window"]["from"], j["window"]["to"], j["subject"].endswith("23/11 a 30/11")), (at(days=7), NOW, True))
        self.assertEqual((j["schema"], j["slice"], j["mode"], j["now"], j["evaluator"]["script"]), (1, "ga-mw5gdyu.4", "dry-run", NOW, "gate-refusal-meter.py"))

    def test_a_sibling_that_cannot_be_loaded_is_not_measured_and_the_rest_still_is(self):
        self.week(0, ok=5)
        with mock.patch.object(W, "M", None):
            rc, j, ls = self.lines()
            self.assertEqual((rc, j["complete"], ls[:2]), (2, False, ["1ª tentativa: NÃO MEDIDO (medidor não carregou)", "Recusas do portão: NÃO MEDIDO (medidor não carregou)"]))
        with mock.patch.object(W, "R", None):
            rc, j, ls = self.lines()
            self.assertEqual((rc, j["complete"], len(ls), ls[2]), (2, False, 3, "Checagens: pedidas NÃO MEDIDO (catraca não carregou) · em teste/promovidas/desligadas NÃO MEDIDO (catraca não carregou)"))
        with mock.patch.object(W.R, "T", None):  # the ratchet loaded but not its conf reader: the bead store still answers
            rc, j, ls = self.lines()
            self.assertEqual((rc, ls[2]), (2, "Checagens: 0 pedidas · em teste/promovidas/desligadas NÃO MEDIDO (catraca não carregou)"))
        with mock.patch.object(W.R, "P", None):
            rc, j, ls = self.lines()
            self.assertEqual((rc, ls[2]), (2, "Checagens: pedidas NÃO MEDIDO (catraca não carregou) · em teste/promovidas/desligadas NÃO MEDIDO (catraca não carregou)"))
        with mock.patch.object(W.M, "measure", side_effect=RuntimeError("bug do medidor")):
            rc, j, ls = self.lines()
            self.assertEqual((rc, ls[0], ls[1]), (2, "1ª tentativa: NÃO MEDIDO (medidor falhou (RuntimeError))", "Recusas do portão: NÃO MEDIDO (medidor falhou (RuntimeError))"))


class Entry(Base):
    def test_usage_errors_are_64_with_one_line_and_nothing_runs(self):
        for flags in (["--bogus"], ["--now", "ontem"], ["--now"], ["--apply", "--dry"]):
            with self.subTest(flags):
                err = io.StringIO()
                with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                    rc = W.main(flags)
                self.assertEqual((rc, err.getvalue().count("\n"), self.calls), (64, 1, []))

    def test_a_meter_that_changes_its_report_shape_is_a_loud_failure_and_nothing_is_sent(self):
        self.assertEqual(W.M.SCHEMA, 1)  # the shape this script reads: a bump of the meter's schema fails here first, as it does in the .2 suite
        self.week(0, ok=5)
        err = io.StringIO()
        with mock.patch.object(W.M, "measure", return_value=({"first_attempt": {"n": 5}, "refusals": None}, 0)), contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            rc = W.entry(["--apply", "--city", self.city, "--now", NOW, "--bd", "bd", "--gc", "gc", "--notify", "notify"])
        self.assertEqual((rc, [c for c in self.calls if c[0] in ("notify", "gc")]), (70, []))
        self.assertIn("KeyError", err.getvalue())

    def test_an_exception_nobody_planned_is_70_not_a_silent_zero(self):
        err = io.StringIO()
        with mock.patch.object(W, "cycle", side_effect=RuntimeError("boom")), contextlib.redirect_stderr(err):
            self.assertEqual(W.entry(["--city", self.city]), 70)
        self.assertIn("boom", err.getvalue())

    def test_the_binaries_come_from_the_environment_then_the_defaults_and_the_clock_defaults_to_now(self):
        self.week(0, ok=5)
        seen = []
        rec = lambda argv, timeout: (seen.append(argv[0]), (0, "[]"))[1]  # noqa: E731
        names = ("GATE_REFUSAL_BD", "GATE_REFUSAL_GC", "NOTIFY_BIN")
        base = {k: v for k, v in os.environ.items() if k not in names}
        for env, want in (({"GATE_REFUSAL_BD": "/x/bd", "GATE_REFUSAL_GC": "/x/gc", "NOTIFY_BIN": "/x/notify", "HOME": "/h"}, ["/x/bd", "/x/notify", "/x/gc"]), ({"HOME": "/h"}, ["bd", "/h/.local/bin/notify", "gc"])):
            seen[:] = []
            out = io.StringIO()
            with mock.patch.dict(os.environ, dict(base, **env), clear=True), mock.patch.object(W, "run", rec), contextlib.redirect_stdout(out):
                W.main(["--json", "--apply", "--city", self.city, "--now", "2026-11-30T15:00:00Z"])
            self.assertEqual(seen, want)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            W.main(["--json", "--city", self.city])
        now = datetime.datetime.now(datetime.timezone.utc)
        self.assertLess(abs((now - datetime.datetime.strptime(json.loads(out.getvalue())["now"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)).total_seconds()), 120)

    def test_the_city_comes_from_the_environment_and_the_default_is_the_siblings_and_the_usage_names_every_flag(self):
        self.week(0, ok=5)
        base = {k: v for k, v in os.environ.items() if k not in ("GC_CITY_PATH", "GC_CITY")}
        for env in ({"GC_CITY_PATH": self.city}, {"GC_CITY": self.city}, {"GC_CITY_PATH": self.city, "GC_CITY": "/nonexistent"}):
            out = io.StringIO()
            self.put(os.path.join(self.state, "quality-gate.jsonl"), "".join(json.dumps(r) + "\n" for r in self.rows))
            with mock.patch.dict(os.environ, dict(base, **env), clear=True), contextlib.redirect_stdout(out):
                W.main(["--json", "--now", NOW, "--bd", "bd", "--gc", "gc", "--notify", "notify"])
            self.assertEqual(json.loads(out.getvalue())["weeks"]["cur"]["n"], 5, env)
        self.assertEqual(W.DEFAULT_CITY, W.M.DEFAULT_CITY)
        self.assertEqual(W.DEFAULT_CITY, W.R.DEFAULT_CITY)
        self.assertTrue(W.USAGE.startswith("uso: auto-melhoria-weekly.py") and all(f in W.USAGE for f in ("--apply", "--json", "--now", "--city", "--bd", "--gc", "--notify", "--mayor")))

    def test_a_sibling_that_is_missing_or_does_not_import_loads_as_none(self):
        for f, text in (("ruim.py", "def (:\n"), ("levanta.py", "raise RuntimeError('x')\n"), ("bom.py", "X = 1\n")):
            self.put(os.path.join(self.root, f), text)
        self.assertEqual([W.load("n", os.path.join(self.root, f)) for f in ("ausente.py", "ruim.py", "levanta.py")], [None, None, None])
        self.assertEqual(W.load("n", os.path.join(self.root, "bom.py")).X, 1)

    def test_run_wraps_real_processes_and_reports_a_missing_or_slow_one_as_none(self):
        self.run_patch.stop()
        self.addCleanup(self.run_patch.start)
        self.assertEqual(W.run([sys.executable, "-c", "print('oi')"], 30), (0, "oi\n"))
        self.assertEqual(W.run([sys.executable, "-c", "import sys; sys.exit(3)"], 30)[0], 3)
        self.assertEqual(W.run(["/nonexistent/amw-binary"], 30), (None, ""))
        self.assertEqual(W.run([sys.executable, "-c", "import time; time.sleep(30)"], 1), (None, ""))
        self.assertEqual(W.run([sys.executable, "-c", "pass", "a\0b"], 30), (None, ""))


class Order(unittest.TestCase):
    def test_the_order_runs_monday_08h_local_and_points_at_this_script(self):
        path = os.path.join(HERE, "..", "packs", "town-deltas", "orders", "auto-melhoria-weekly.toml")
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn('trigger = "cron"', text)
        self.assertIn('schedule = "0 11 * * 1"', text)  # cron is UTC: 11:00 UTC is 08:00 in UTC-3
        self.assertNotIn("enabled = false", text)
        ex = [l.split("=", 1)[1].strip().strip('"') for l in text.splitlines() if l.startswith("exec")][0]
        self.assertTrue(ex.startswith("python3 -I $PACK_DIR/../../scripts/auto-melhoria-weekly.py") and ex.endswith("--apply"), ex)
        self.assertTrue(os.path.isfile(os.path.join(HERE, "auto-melhoria-weekly.py")))


if __name__ == "__main__":
    unittest.main()
