#!/usr/bin/env python3
"""test_gate_checks_ratchet.py (ga-mw5gdyu.3): hermetic suite for scripts/gate-checks-ratchet.py. Everything is a REAL file in a temp city (registry, gate log, conf, runs); the runs and the conf come out of the REAL gate_check_trial producer and the
first-attempt numbers are the REAL meter's. Scenarios are built from beads whose arm is the real draw.
`python3 -I scripts/test_gate_checks_ratchet.py` (3.9+); GCR_UNDER_TEST=<copy that sits beside the real siblings> runs it against a mutant."""
import contextlib, datetime, importlib.util, io, json, os, shutil, subprocess, sys, tempfile, unittest  # noqa: E401
from unittest import mock

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "packs", "town-deltas", "assets")
SUT = os.environ.get("GCR_UNDER_TEST") or os.path.join(HERE, "gate-checks-ratchet.py")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


R = load("gcr", SUT)
T = load("gct", os.path.join(ASSETS, "gate_check_trial.py"))
ENTRY = datetime.datetime(2026, 11, 10, 12, 0, tzinfo=datetime.timezone.utc)
STEM, CLASS, CHECK, SINCE = "foo", "classe-x", "packs/town-deltas/assets/foo-check.py", "2026-11-10"
TRIAL, PROMO, OFF = ("ok", "enforce", 50), ("ok", "enforce", 100), ("ok", "off", 100)  # what load_conf reads from the conf in each phase


def at(days=0, minutes=0):
    return ENTRY + datetime.timedelta(days=days, minutes=minutes)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def ROW(cls=CLASS, status="em-teste", check=CHECK + " (gate-hard-checks.sh passo 2f)", since=SINCE):
    return "\t".join((cls, status, check, "ga-chk1", since, "nota"))


class World(unittest.TestCase):
    def setUp(self):
        self.city = tempfile.mkdtemp(prefix="gcr-")
        self.addCleanup(shutil.rmtree, self.city, True)
        self.state, self.n, self.conf_path = os.path.join(self.city, ".gc"), 0, os.path.join(self.city, ".gc", STEM + ".conf")
        self.beads = {"enforce": [], "holdout": []}  # what scenario() built, per arm
        os.makedirs(self.state)
        self.reg(ROW())

    def write(self, rel, text):
        path = os.path.join(self.city, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)

    def reg(self, *rows):
        self.write(os.path.join("scripts", "gate-refusal-checks.registry.tsv"), "class\tstatus\tcheck\tbead\tsince\tnote\n" + "".join(r + "\n" for r in rows))

    def run_ratchet(self, *flags, now=None):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            rc = R.main(["--json", "--city", self.city, "--now", iso(now or ENTRY)] + list(flags))
        return rc, (json.loads(out.getvalue()) if out.getvalue() else None)

    def row(self, rep, cls=CLASS):
        return next(c for c in rep["classes"] if c["class"] == cls)

    def conf(self):
        return T.load_conf(self.state, STEM)

    def rec(self):  # the ratchet's own record, the `# ratchet {json}` line of the conf
        return next((json.loads(n[8:]) for n in T.read_conf(self.state, STEM)[3] if n.startswith("ratchet ")), None)

    def enter(self):
        rc, rep = self.run_ratchet("--apply")
        self.assertEqual((rc, self.row(rep)["verdict"]), (0, "entrou"))

    def run_row(self, bead, arm, verdict, t, pontos=(), disp=()):
        self.assertEqual(T.record_run(self.state, STEM, bead, arm, verdict, pontos, disp, ts=iso(t)), "")

    def gate(self, bead, result, t):
        with open(os.path.join(self.state, "quality-gate.jsonl"), "a") as fh:
            fh.write(json.dumps({"event": "dispatcher_complete", "ts": iso(t), "bead": bead, "result": result, "dry_run": 0, "reason": "Reviewer 1 FAIL: x" if result == "FAIL" else ""}) + "\n")

    def bead_of(self, arm):
        while True:
            self.n += 1
            if T.arm_for(STEM, "ga-s%04d" % self.n, 50) == arm:
                return "ga-s%04d" % self.n

    def scenario(self, enf=(0, 0), hold=(0, 0), refused=0, false=0):
        """Beads of both arms, each with a run after ENTRY and a first verdict after the run. `refused` of the enforce beads were first refused (an `achados` run) and then cleared (an `ok` run); `false` of those cleared it by waiving the cited point."""
        seen, i = {"enforce": 0, "holdout": 0}, 0
        for arm, (ok, bad) in (("enforce", enf), ("holdout", hold)):
            for k in range(ok + bad):
                b, i = self.bead_of(arm), i + 1
                seen[arm] += 1
                self.beads[arm].append(b)
                if arm == "enforce" and seen[arm] <= refused:
                    self.run_row(b, arm, "achados", at(minutes=60 + i), ["p-" + b])
                    self.run_row(b, arm, "ok", at(minutes=61 + i), (), ["p-" + b] if seen[arm] <= false else ())
                else:
                    self.run_row(b, arm, "ok", at(minutes=60 + i))
                self.gate(b, "PASS" if k < ok else "FAIL", at(minutes=120 + i))

    def decide(self, **kw):
        self.enter()
        self.scenario(**kw)
        return self.run_ratchet("--apply", now=at(days=15))

    def torn(self, n, cut=None):
        """Give the first n enforce beads whose first verdict is a FAIL a LATER PASS and keep only `cut` characters of that FAIL line (None = leave it whole, the control): a log that lost the FAIL counts the PASS as the bead's FIRST attempt."""
        path = os.path.join(self.state, "quality-gate.jsonl")
        with open(path) as fh:
            lines, out = fh.read().splitlines(), []
        for ln in lines:
            d = json.loads(ln)
            if n and d["result"] == "FAIL" and T.arm_for(STEM, d["bead"], 50) == "enforce":
                n -= 1
                out += [ln[:cut], json.dumps(dict(d, result="PASS", reason="", ts=iso(at(minutes=300 + n))))]
            else:
                out.append(ln)
        with open(path, "w") as fh:
            fh.write("\n".join(out) + "\n")

    def blind(self, arm, k):
        """k MORE runs of `arm`, each answered nao-sei (the check could not verify), spread over the beads scenario() built."""
        for i in range(k):
            self.run_row(self.beads[arm][i % len(self.beads[arm])], arm, "nao-sei", at(minutes=500 + i))


class Entry(World):
    def test_the_dry_run_enters_nothing_and_the_apply_enters_once_on_half_the_submissions(self):
        rc, rep = self.run_ratchet()
        self.assertEqual((rc, rep["mode"], self.row(rep)["verdict"], self.conf()[0]), (0, "dry-run", "entraria", "absent"))
        rc, rep = self.run_ratchet("--apply")
        self.assertEqual((rc, self.row(rep)["verdict"], self.conf(), self.rec()), (0, "entrou", TRIAL, {"v": 1, "since": SINCE, "fase": "trial", "entrou": iso(ENTRY)}))
        with open(self.conf_path) as fh:
            before = fh.read()
        rc, rep = self.run_ratchet("--apply", now=at(days=1))
        with open(self.conf_path) as fh:
            self.assertEqual((rc, self.row(rep)["verdict"], fh.read(), "nunca gravou" in self.row(rep)["why"]), (0, "em-andamento", before, False))  # the entry is not rewritten (the window would slide); "never recorded a run" is said only when a decision is due

    def test_a_conf_nobody_gave_us_is_never_overwritten(self):
        good = {"v": 1, "since": SINCE, "fase": "trial", "entrou": iso(ENTRY)}  # the record a conf of ours carries; each case below breaks it in ONE way
        note = lambda **kw: "mode=enforce\nenforce_pct=50\n# ratchet " + json.dumps(dict(good, **kw)) + "\n"  # noqa: E731
        for name, text in (("outro pct", "mode=enforce\nenforce_pct=30\n"), ("warn", "mode=warn\n"), ("lixo", "lixo\n"), ("a mesma de sempre, mas sem a nota do ciclo", "mode=enforce\nenforce_pct=50\n"),
                           ("nota que não é JSON", "mode=enforce\nenforce_pct=50\n# ratchet {lixo\n"), ("nota v2", note(v=2)), ("fase desconhecida", note(fase="bogus")), ("fase x", note(fase="x")), ("entrou ilegível", note(entrou="ontem")), ("since que não é texto", note(since=5)),
                           ("sem since", note(since=None).replace('"since": null, ', ""))):
            with self.subTest(name):
                self.setUp()
                self.write(os.path.join(".gc", STEM + ".conf"), text)
                rc, rep = self.run_ratchet("--apply")
                with open(self.conf_path) as fh:
                    self.assertEqual((rc, self.row(rep)["verdict"], fh.read()), (2, "nao-sei", text))
                self.assertEqual("`# ratchet`" in self.row(rep)["why"], "# ratchet" in text)  # a damaged record of ours is said as such, not as somebody else's conf
        self.setUp()
        os.mkdir(self.conf_path)  # a conf that cannot be read is not "absent"
        self.assertEqual((self.run_ratchet("--apply")[0], os.path.isdir(self.conf_path)), (2, True))

    def test_rows_that_are_not_a_trial_or_not_in_the_contract_are_left_alone(self):
        self.reg(ROW("a-ativa", "ativa", "packs/town-deltas/assets/a-check.py"), ROW("b-desligada", "desligada", "packs/town-deltas/assets/b-check.py"), ROW("c-sem-sufixo", check="foo.py (sem o sufixo)"), ROW("d-abs", check="/etc/foo-check.py"), ROW(CLASS))
        rc, rep = self.run_ratchet("--apply")
        self.assertEqual({c["class"]: c["verdict"] for c in rep["classes"]}, {"c-sem-sufixo": "fora-do-contrato", "d-abs": "fora-do-contrato", CLASS: "entrou"})
        self.assertEqual((rc, sorted(f for f in os.listdir(self.state) if f.endswith(".conf"))), (2, [STEM + ".conf"]))  # a row stuck outside the contract is not "all fine"
        self.assertTrue(all("deve começar pelo caminho" in self.row(rep, c)["why"] for c in ("c-sem-sufixo", "d-abs")), rep["classes"])  # each says ITS OWN problem (the check cell), not "shares a check" with the other row that is also outside the contract

    def test_a_check_that_two_rows_name_has_one_conf_so_neither_row_acts(self):
        other = lambda status="em-teste", check=CHECK + " (x)": ROW("outra-classe", status, check, "2026-11-11")  # noqa: E731 - the same script, another class and another `since`
        for name, rows, want, confs in (("duas em-teste", (ROW(), other()), {CLASS: "fora-do-contrato", "outra-classe": "fora-do-contrato"}, []), ("em-teste e ativa", (ROW(), other("ativa")), {CLASS: "fora-do-contrato"}, []),
                                        ("em-teste e desligada", (ROW(), other("desligada")), {CLASS: "fora-do-contrato"}, []), ("scripts diferentes", (ROW(), other(check="packs/town-deltas/assets/bar-check.py")), {CLASS: "entrou", "outra-classe": "entrou"}, ["bar.conf", "foo.conf"])):
            with self.subTest(name):
                self.setUp()
                self.reg(*rows)
                rc, rep = self.run_ratchet("--apply")
                self.assertEqual(({c["class"]: c["verdict"] for c in rep["classes"]}, rc, sorted(f for f in os.listdir(self.state) if f.endswith(".conf"))), (want, 2 if "fora-do-contrato" in want.values() else 0, confs))  # a trial would rewrite the conf another row relies on (two trials: each other's, restarting each other's window at every --apply)
                self.assertEqual("outra-classe" in self.row(rep)["why"], "fora-do-contrato" in want.values())

    def test_a_new_since_is_a_new_trial_over_our_own_old_record_and_deleting_the_conf_restarts(self):
        self.decide(enf=(8, 2), hold=(6, 4), refused=6)
        self.assertEqual((self.conf(), self.rec()["fase"]), (PROMO, "promovida"))
        self.reg(ROW(since="2026-11-26"))
        rc, rep = self.run_ratchet("--apply", now=at(days=16))
        self.assertEqual((rc, self.row(rep)["verdict"], self.conf(), self.rec()), (0, "entrou", TRIAL, {"v": 1, "since": "2026-11-26", "fase": "trial", "entrou": iso(at(days=16))}))
        os.remove(self.conf_path)  # the gesture that resets a class: no conf, no memory
        self.assertEqual(self.row(self.run_ratchet("--apply", now=at(days=17))[1])["verdict"], "entrou")

    def test_a_conf_that_cannot_be_written_is_said_not_assumed(self):
        with mock.patch.object(R.T, "write_conf", return_value="disco cheio"):
            rc, rep = self.run_ratchet("--apply")
        self.assertEqual((rc, self.row(rep)["verdict"], self.conf()[0]), (1, "erro-ao-aplicar", "absent"))
        self.enter()
        self.scenario(enf=(8, 2), hold=(6, 4), refused=6)
        with mock.patch.object(R.T, "write_conf", return_value="disco cheio"):
            rc, rep = self.run_ratchet("--apply", now=at(days=15))
        self.assertEqual((rc, self.row(rep)["verdict"], self.conf(), self.rec()["fase"]), (1, "erro-ao-aplicar", TRIAL, "trial"))  # the next run decides again


class Decision(World):
    CASES = (("antes do prazo", dict(enf=(8, 2), hold=(6, 4), refused=6), 3, "em-andamento", TRIAL, ""),
             ("30 submissões antes dos 14 dias", dict(enf=(14, 2), hold=(10, 4), refused=6), 2, "promovida", PROMO, "aprovação"),
             ("14 dias com poucos beads", dict(enf=(8, 2), hold=(6, 4), refused=6), 14, "promovida", PROMO, "aprovação"),
             ("empate promove", dict(enf=(6, 4), hold=(6, 4), refused=5), 15, "promovida", PROMO, ""),
             ("aprovação menor desliga", dict(enf=(5, 5), hold=(6, 4), refused=5), 15, "desligada", OFF, "aprovação"),
             ("aprovação é taxa, não contagem", dict(enf=(7, 3), hold=(4, 1), refused=6), 15, "desligada", OFF, "MENOR"),
             ("aprovação menor desliga sem recusas medidas", dict(enf=(4, 6), hold=(8, 2), refused=0), 15, "desligada", OFF, "aprovação"),
             ("recusa falsa acima de 10%", dict(enf=(8, 2), hold=(6, 4), refused=6, false=1), 15, "desligada", OFF, "recusa falsa"),
             ("10% exato promove", dict(enf=(8, 2), hold=(6, 4), refused=10, false=1), 15, "promovida", PROMO, ""),
             ("10% e mais um desliga", dict(enf=(8, 2), hold=(6, 4), refused=10, false=2), 15, "desligada", OFF, "recusa falsa"),
             ("poucos beads no enforce aguarda", dict(enf=(3, 1), hold=(6, 4), refused=4), 15, "aguardando-dados", TRIAL, "por braço"),
             ("poucos beads no holdout aguarda", dict(enf=(8, 2), hold=(2, 1), refused=6), 15, "aguardando-dados", TRIAL, "por braço"),
             ("braço sem dado aguarda", dict(enf=(0, 0), hold=(6, 4)), 15, "aguardando-dados", TRIAL, "enforce sem dado"),
             ("poucas recusas aguarda", dict(enf=(8, 2), hold=(6, 4), refused=4), 15, "aguardando-dados", TRIAL, "recusou 4"),
             ("a checagem nunca recusou: aguarda", dict(enf=(8, 2), hold=(6, 4), refused=0), 15, "aguardando-dados", TRIAL, "recusou 0"),
             ("no teto, poucos beads desliga", dict(enf=(3, 1), hold=(6, 4)), 28, "desligada", OFF, "dados-insuficientes"),
             ("no teto, sem recusas desliga", dict(enf=(8, 2), hold=(6, 4), refused=0), 28, "desligada", OFF, "dados-insuficientes"))

    def test_the_rule_in_every_corner(self):
        for name, kw, days, verdict, conf, why in self.CASES:
            with self.subTest(name):
                self.setUp()
                self.enter()
                self.scenario(**kw)
                rc, rep = self.run_ratchet("--apply", now=at(days=days))
                c = self.row(rep)
                self.assertEqual((rc, c["verdict"], self.conf()), (0, verdict, conf), c["why"])
                self.assertIn(why, c["why"])
                self.assertEqual(self.rec()["fase"], verdict if verdict in ("promovida", "desligada") else "trial")

    def test_the_numbers_are_the_meters_and_a_dry_run_decides_nothing(self):
        self.enter()
        self.scenario(enf=(8, 2), hold=(6, 4), refused=6)
        rc, rep = self.run_ratchet(now=at(days=15))
        c = self.row(rep)
        self.assertEqual((rc, c["verdict"], c["submissions"], round(c["days"], 1), self.conf(), self.rec()["fase"]), (0, "promoveria", 20, 15.0, TRIAL, "trial"))
        self.assertEqual((c["enforce"], c["holdout"], c["refusals"]), ({"n": 10, "approved": 8, "pct": 80.0, "state": "ok"}, {"n": 10, "approved": 6, "pct": 60.0, "state": "ok"}, {"beads": 6, "false": 0}))


class Blind(World):
    """A run the check answered `nao-sei` (it could not verify) checked nothing: a blind check passes "enforce >= holdout" for free, so a promotion needs it to have been looking. The base scenario promotes (enforce 8/10 vs holdout 6/10, 6 refusals) with 16 enforce runs and 10 holdout runs."""
    CASES = (("sem rodada cega promove", 6, {}, 15, "promovida", PROMO, "enforce 0/16, holdout 0/10"),
             ("20% exato no enforce promove", 6, {"enforce": 4}, 15, "promovida", PROMO, "enforce 4/20, holdout 0/10"),
             ("mais de 20% no enforce aguarda", 6, {"enforce": 5}, 15, "aguardando-dados", TRIAL, "mais de 20% das rodadas do braço enforce"),
             ("20,8% no enforce aguarda (o limite é 20, não 21)", 9, {"enforce": 5}, 15, "aguardando-dados", TRIAL, "mais de 20% das rodadas do braço enforce"),
             ("20% exato no holdout promove", 6, {"holdout": 2}, 15, "promovida", PROMO, "enforce 0/16, holdout 2/12"),
             ("mais de 20% no holdout aguarda", 6, {"holdout": 3}, 15, "aguardando-dados", TRIAL, "mais de 20% das rodadas do braço holdout"),
             ("os dois braços cegos", 6, {"enforce": 9, "holdout": 6}, 15, "aguardando-dados", TRIAL, "braço enforce e holdout"),
             ("no teto, a checagem cega desliga", 6, {"enforce": 5}, 28, "desligada", OFF, "dados-insuficientes"))

    def test_a_check_that_could_not_verify_is_not_promoted_blind(self):
        for name, refused, blind, days, verdict, conf, why in self.CASES:
            with self.subTest(name):
                self.setUp()
                self.enter()
                self.scenario(enf=(8, 2), hold=(6, 4), refused=refused)
                for arm, k in blind.items():
                    self.blind(arm, k)
                rc, rep = self.run_ratchet("--apply", now=at(days=days))
                c = self.row(rep)
                self.assertEqual((rc, c["verdict"], self.conf()), (0, verdict, conf), c["why"])
                self.assertIn(why, c["why"])
                self.assertEqual(c["unknown"], {"enforce": {"runs": 10 + refused + blind.get("enforce", 0), "nao_sei": blind.get("enforce", 0)}, "holdout": {"runs": 10 + blind.get("holdout", 0), "nao_sei": blind.get("holdout", 0)}})  # each refused enforce bead has two runs
                if verdict in ("promovida", "desligada"):
                    self.assertEqual(self.rec()["evidence"]["unknown"], c["unknown"])  # the number the decision rested on is in the conf's record

    def test_a_blind_check_that_also_loses_the_comparison_or_refuses_wrongly_is_switched_off_not_kept_waiting(self):
        for name, kw, why in (("aprovação menor", dict(enf=(5, 5), hold=(6, 4), refused=5), "MENOR"), ("recusa falsa", dict(enf=(8, 2), hold=(6, 4), refused=6, false=2), "recusa falsa")):
            with self.subTest(name):
                self.setUp()
                self.enter()
                self.scenario(**kw)
                self.blind("enforce", 9)
                c = self.row(self.run_ratchet("--apply", now=at(days=15))[1])
                self.assertEqual((c["verdict"], why in c["why"]), ("desligada", True), c["why"])


class Effects(World):
    def test_promotion_and_disabling_are_recorded_in_the_conf_with_their_why_and_then_final(self):
        for name, kw, fase, conf in (("promove", dict(enf=(8, 2), hold=(6, 4), refused=6), "promovida", PROMO), ("desliga", dict(enf=(5, 5), hold=(6, 4), refused=5), "desligada", OFF)):
            with self.subTest(name):
                self.setUp()
                frozen = lambda: {os.path.join(r, f): os.stat(os.path.join(r, f)).st_mtime_ns for d in (HERE, ASSETS, os.path.join(self.city, "scripts")) for r, _, fs in os.walk(d) for f in fs}  # noqa: E731 - the meter, its test, the ruler, the registry...
                before_files = frozen()
                rc, rep = self.decide(**kw)
                self.assertEqual(frozen(), before_files, "a whole trial must not write to the meter, the ruler or the registry")
                rec = self.rec()
                self.assertEqual((rc, self.conf(), rec["fase"], rec["since"], rec["entrou"], rec["em"], rep["gaps"]), (0, conf, fase, SINCE, iso(ENTRY), iso(at(days=15)), []))
                self.assertIn("aprovação", rec["why"])
                self.assertEqual((rec["evidence"]["enforce"]["n"], rec["evidence"]["refusals"]["beads"]), (10, kw["refused"]))
                with open(self.conf_path, encoding="utf-8") as fh:
                    before = fh.read()
                self.assertIn("aprovação de 1ª tentativa", before)  # only the characters that cut a line are escaped: the why stays readable for whoever cats the conf
                rc, rep = self.run_ratchet("--apply", now=at(days=20))  # final for its since: nothing is rewritten or decided again
                with open(self.conf_path) as fh:
                    self.assertEqual((rc, self.row(rep)["verdict"], fh.read(), rep["gaps"]), (0, "ja-decidida", before, []))

    def test_the_conf_the_ratchet_writes_is_one_line_for_every_splitter_whatever_a_bead_id_holds(self):
        # the REAL check reads its conf with str.splitlines(): a U+2028 in the record (the id of a falsely refused bead comes from the check) would leave the rest of the note as a broken setting, and the check would answer NÃO SEI to every submission
        def odd(arm):
            while True:
                self.n += 1
                if T.arm_for(STEM, "ga-s\u2028%04d" % self.n, 50) == arm:
                    return "ga-s\u2028%04d" % self.n
        with mock.patch.object(self, "bead_of", odd):
            rc, rep = self.decide(enf=(8, 2), hold=(6, 4), refused=10, false=1)  # 1 of 10 refusals false: exactly 10%, promoted
        with open(self.conf_path, encoding="utf-8") as fh:
            text = fh.read()
        self.assertEqual((rc, self.conf(), text.splitlines()), (0, PROMO, text.split("\n")[:-1]), text)
        self.assertEqual(self.rec()["evidence"]["false_beads"], self.beads["enforce"][:1])

    def test_a_decided_check_whose_conf_someone_else_changed_is_not_fought(self):
        self.decide(enf=(8, 2), hold=(6, 4), refused=6)
        self.write(os.path.join(".gc", STEM + ".conf"), 'mode=warn\n# ratchet {"v": 1, "since": "2026-11-10", "fase": "promovida", "entrou": "2026-11-10T12:00:00Z"}\n')
        rc, rep = self.run_ratchet("--apply", now=at(days=20))
        self.assertEqual((self.row(rep)["verdict"], self.conf()), ("ja-decidida", ("ok", "warn", 100)))
        self.assertTrue(any(CLASS in g and "conf" in g for g in rep["gaps"]), rep["gaps"])

    def test_the_conf_changing_under_a_trial_holds_it(self):
        self.enter()
        self.scenario(enf=(8, 2), hold=(6, 4), refused=6)
        with open(self.conf_path) as fh:
            text = fh.read()
        self.write(os.path.join(".gc", STEM + ".conf"), text.replace("enforce_pct=50", "enforce_pct=70"))  # the arms recorded so far were drawn at 50
        rc, rep = self.run_ratchet("--apply", now=at(days=15))
        self.assertEqual((rc, self.row(rep)["verdict"], self.conf(), self.rec()["fase"]), (2, "nao-sei", ("ok", "enforce", 70), "trial"))


class Evidence(World):
    def test_runs_file_states(self):
        b = self.bead_of("enforce")
        bad_row = json.dumps({"bead": b, "ts": "ontem", "arm": "enforce", "verdict": "ok"}) + "\n"  # the right arm, not a row of the contract
        leap = json.dumps({"bead": b, "ts": iso(at(minutes=30))[:-3] + "60Z", "arm": "enforce", "verdict": "ok"}) + "\n"  # second 60: time.strptime takes it, the reader's datetime.strptime does not (it used to stop EVERY class with exit 70)
        wrong_arm = lambda: self.run_row("ga-x", "holdout" if T.arm_for(STEM, "ga-x", 50) == "enforce" else "enforce", "ok", at(minutes=5))  # noqa: E731 - an arm the draw would not have given: the check is not using the ruler
        runs = os.path.join(".gc", STEM + "-runs.jsonl")
        for name, setup, want in (("nunca gravou: aguarda", lambda: None, "aguardando-dados"), ("diretório: não consigo ler", lambda: os.mkdir(os.path.join(self.city, runs)), "nao-sei"),
                                  ("só linhas em branco", lambda: self.write(runs, "\n \n"), "aguardando-dados"), ("linha estragada", lambda: self.write(runs, "{estragada\n"), "nao-sei"), ("linha que não é do contrato", lambda: self.write(runs, bad_row), "nao-sei"), ("segundo 60 no ts", lambda: self.write(runs, leap), "nao-sei"), ("braço que o sorteio não daria", wrong_arm, "nao-sei")):
            with self.subTest(name):
                self.setUp()
                self.enter()
                setup()
                self.gate("ga-g1", "PASS", at(minutes=5))  # a readable gate log, so the runs file is the only thing in question
                rc, rep = self.run_ratchet("--apply", now=at(days=15))
                self.assertEqual((rc, self.row(rep)["verdict"], self.conf()), (2 if want == "nao-sei" else 0, want, TRIAL))
                self.assertEqual("nunca gravou uma rodada" in self.row(rep)["why"], name.startswith("nunca"))

    def test_the_writers_row_check_and_the_readers_timestamp_parse_agree_on_every_ts(self):
        # "the reader and the writer judge by one function": a ts the writer accepts and the reader cannot parse is a (None, row) the measure compares with a datetime
        for ts in ("2026-11-10T12:00:00Z", "2026-11-10T12:00:59Z", "2026-11-10T12:00:60Z", "2026-11-10T12:00:61Z", "2024-02-29T00:00:00Z", "2026-02-29T00:00:00Z", "2026-11-31T00:00:00Z", "2026-13-01T00:00:00Z", "2026-11-10T24:00:00Z",
                   "2026-11-10 12:00:00Z", "2026-11-10T12:00:00z", "2026-11-10T12:00:00", " 2026-11-10T12:00:00Z", "2026-11-10T12:00:00Z\n", "", None, 20261110, ["2026-11-10T12:00:00Z"]):
            with self.subTest(ts):
                self.assertEqual(T.row_ok({"bead": "ga-1", "ts": ts, "arm": "enforce", "verdict": "ok"}) == "", R.try_ts(ts) is not None)

    def test_the_damaged_lines_of_the_runs_file_are_named_so_somebody_can_repair_them(self):
        b = self.bead_of("enforce")
        runs = os.path.join(self.state, STEM + "-runs.jsonl")
        self.enter()
        self.run_row(b, "enforce", "ok", at(minutes=10))
        for text in ("{estragada\n", "\n"):
            with open(runs, "a") as fh:
                fh.write(text)
        self.run_row(b, "enforce", "ok", at(minutes=11))
        with open(runs, "a") as fh:
            fh.write("lixo\n")
        c = self.row(self.run_ratchet("--apply", now=at(days=15))[1])
        self.assertEqual(c["verdict"], "nao-sei")
        self.assertIn("2 linha(s) fora do contrato (linhas 2, 5)", c["why"])  # physical line numbers: the blank line 3 is skipped but counted, so `sed -n 5p` finds it
        for more, want in ((3, "5 linha(s) fora do contrato (linhas 2, 5, 6, 7, 8)"), (1, "6 linha(s) fora do contrato (linhas 2, 5, 6, 7, 8, …)")):  # five are named; a sixth is "…"
            with open(runs, "a") as fh:
                fh.write("lixo\n" * more)
            self.assertIn(want, self.row(self.run_ratchet("--apply", now=at(days=15))[1])["why"])

    def test_a_runs_line_written_by_a_stranger_with_a_raw_unicode_separator_is_one_row_not_two_damaged_ones(self):
        b = self.bead_of("enforce")
        runs = os.path.join(self.state, STEM + "-runs.jsonl")
        with open(runs, "w", encoding="utf-8") as fh:  # json.dumps(ensure_ascii=False) leaves U+2028/U+2029/U+0085 raw; str.splitlines() cuts the line there
            fh.write(json.dumps({"bead": b, "ts": iso(at(minutes=30)), "arm": "enforce", "verdict": "achados", "pontos": ["a\u2028b", "c\u2029d", "e\x85f"], "dispensados": []}, ensure_ascii=False) + "\n")
        st, rows, bad = R.read_runs(runs, STEM)
        self.assertEqual((st, [d["pontos"] for _, d in rows], bad), ("ok", [["a\u2028b", "c\u2029d", "e\x85f"]], []))

    def test_only_what_the_check_could_have_changed_counts(self):
        self.enter()
        late = self.bead_of("enforce")
        self.gate(late, "FAIL", at(minutes=30))  # its first verdict came BEFORE the check ever ran on it
        self.run_row(late, "enforce", "ok", at(minutes=90))
        self.gate(late, "PASS", at(minutes=120))
        old = self.bead_of("holdout")
        self.run_row(old, "holdout", "nao-sei", at(minutes=-100))  # runs from before the trial's entry: not counted, nao-sei or not
        self.run_row(old, "holdout", "ok", at(minutes=-90))
        self.gate(old, "PASS", at(minutes=-30))
        self.gate(self.bead_of("enforce"), "PASS", at(minutes=60))  # a verdict for a bead the check never recorded
        edge = self.bead_of("enforce")  # run and verdict at the very instant of the entry: both inside
        self.run_row(edge, "enforce", "ok", at())
        self.gate(edge, "PASS", at())
        mid = self.bead_of("holdout")  # its first verdict falls between its first run and its second: the FIRST run is the one that counts
        self.run_row(mid, "holdout", "ok", at(minutes=60))
        self.gate(mid, "PASS", at(minutes=90))
        self.run_row(mid, "holdout", "ok", at(minutes=120))
        c = self.row(self.run_ratchet(now=at(days=1))[1])
        self.assertEqual((c["submissions"], c["enforce"]["n"], c["holdout"]["n"]), (3, 1, 1))
        self.assertEqual(c["unknown"], {"enforce": {"runs": 2, "nao_sei": 0}, "holdout": {"runs": 2, "nao_sei": 0}})  # late + edge; the two runs of `mid`: the `old` ones are before the entry

    def test_a_gate_log_that_cannot_be_read_or_has_no_verdict_is_nao_sei_and_said(self):
        self.enter()
        log = os.path.join(self.state, "quality-gate.jsonl")
        for name, setup, said in (("ausente", lambda: None, "absent"), ("diretório", lambda: os.mkdir(log), "unreadable"), ("sem veredito", lambda: self.write(os.path.join(".gc", "quality-gate.jsonl"), json.dumps({"event": "outra-coisa", "ts": iso(at())}) + "\n"), "vazio")):
            with self.subTest(name):
                if os.path.isdir(log):
                    os.rmdir(log)
                elif os.path.exists(log):
                    os.remove(log)
                setup()
                rc, rep = self.run_ratchet(now=at(days=15))
                self.assertEqual((rc, self.row(rep)["verdict"]), (2, "nao-sei"))
                self.assertTrue(any("NÃO FOI MEDIDA" in g and said in g for g in rep["gaps"]), rep["gaps"])

    def test_a_gate_log_with_lines_the_meter_cannot_read_never_decides_on_what_is_left(self):
        # the reviewer's probe (gate run ga-qudgsxx): 10 first-attempt beads per arm; whole, enforce approves 5/10 < holdout 6/10 (switch off). With the first FAIL of 2 enforce beads torn, the PASS each of them got later becomes its "first" attempt: 7/10 > 6/10, promote
        for name, cut, want in (("log inteiro: desliga", None, (0, "desligada", OFF, "desligada")), ("2 linhas rasgadas com ts legível: NÃO SEI", 70, (2, "nao-sei", TRIAL, "trial")), ("2 linhas rasgadas sem ts: NÃO SEI", 30, (2, "nao-sei", TRIAL, "trial"))):
            with self.subTest(name):
                self.setUp()
                self.enter()
                self.scenario(enf=(5, 5), hold=(6, 4), refused=5)
                self.torn(2, cut)
                rc, rep = self.run_ratchet("--apply", now=at(days=15))
                c = self.row(rep)
                self.assertEqual((rc, c["verdict"], self.conf(), self.rec()["fase"]), want, c["why"])
                self.assertEqual(any("2 linha(s) ilegível(is)" in g and CLASS in g for g in rep["gaps"]), cut is not None, rep["gaps"])  # said in the report too, with the class and how many
                self.assertEqual("ilegível" in c["why"], cut is not None)

    def test_only_damage_that_can_hide_a_verdict_of_the_trial_holds_it(self):
        # the meter's own rule with the trial's entry as the start of the window: a torn line, or a verdict with no usable bead, whose ts is legible and BEFORE the entry cannot hide a verdict of the trial; at the entry instant, after it, or with no ts it might
        torn = lambda t: '{"event": "dispatcher_complete", "ts": "%s", "bead": "ga-x", "res' % iso(t)  # noqa: E731
        nobead = lambda t: json.dumps({"event": "dispatcher_complete", "ts": iso(t), "bead": "", "result": "PASS", "dry_run": 0})  # noqa: E731
        for name, line, holds in (("rasgada antes da entrada", torn(at(minutes=-1)), False), ("rasgada no instante da entrada", torn(at()), True), ("rasgada depois", torn(at(days=2)), True), ("rasgada sem ts", '{"event": "dispa', True),
                                  ("sem bead antes da entrada", nobead(at(minutes=-1)), False), ("sem bead no instante da entrada", nobead(at()), True), ("sem bead depois", nobead(at(days=2)), True),
                                  ("sem ts", json.dumps({"event": "dispatcher_complete", "bead": "ga-x", "result": "PASS", "dry_run": 0}), True)):
            with self.subTest(name):
                self.setUp()
                self.enter()
                self.scenario(enf=(8, 2), hold=(6, 4), refused=6)
                with open(os.path.join(self.state, "quality-gate.jsonl"), "a") as fh:
                    fh.write(line + "\n")
                rc, rep = self.run_ratchet("--apply", now=at(days=15))
                self.assertEqual((rc, self.row(rep)["verdict"]), (2, "nao-sei") if holds else (0, "promovida"), self.row(rep)["why"])
                self.assertEqual(bool(rep["gaps"]), holds, rep["gaps"])

    def test_damage_is_said_before_the_decision_is_due_and_is_never_dados_insuficientes_at_the_cap(self):
        for days, want in ((3, (0, "em-andamento")), (15, (2, "nao-sei")), (28, (2, "nao-sei"))):  # 28 d with 4 beads in one arm is `dados-insuficientes` on a whole log (see the CASES of Decision)
            with self.subTest(days):
                self.setUp()
                self.enter()
                self.scenario(enf=(3, 1), hold=(6, 4))
                with open(os.path.join(self.state, "quality-gate.jsonl"), "a") as fh:
                    fh.write('{"event": "dispa\n')
                rc, rep = self.run_ratchet("--apply", now=at(days=days))
                self.assertEqual((rc, self.row(rep)["verdict"], self.conf(), self.rec()["fase"], any("1 linha(s) ilegível(is)" in g for g in rep["gaps"])), (want[0], want[1], TRIAL, "trial", True))

    def test_registry_that_cannot_be_read_is_nao_sei(self):
        os.remove(os.path.join(self.city, "scripts", "gate-refusal-checks.registry.tsv"))
        rc, rep = self.run_ratchet("--apply")
        self.assertEqual((rc, rep["classes"], self.conf()[0]), (2, [], "absent"))
        self.write(os.path.join("scripts", "gate-refusal-checks.registry.tsv"), "sem cabecalho\n")
        self.assertEqual(self.run_ratchet("--apply")[0], 2)


class FalseRefusal(World):
    """A refusal is false when the point it cited shows up WAIVED in a later run of the same bead: the author overrode it instead of fixing it."""
    CASES = (("dispensado depois", [("achados", ["p"], []), ("ok", [], ["p"])], 1),
             ("corrigido (o ponto some)", [("achados", ["p"], []), ("ok", [], [])], 0),
             ("outro ponto dispensado", [("achados", ["p"], []), ("ok", [], ["q"])], 0),
             ("recusada duas vezes, o 1º ponto dispensado no fim", [("achados", ["p"], []), ("achados", ["q"], []), ("ok", [], ["p"])], 1),
             ("dispensada, e recusada de novo depois", [("achados", ["p"], []), ("ok", [], ["p"]), ("achados", ["q"], [])], 1),
             ("dispensa antes da recusa não vale", [("ok", [], ["p"]), ("achados", ["p"], [])], 0),
             ("dispensa na própria linha da recusa não vale", [("achados", ["p"], ["p"])], 0),
             ("nunca recusada", [("ok", [], []), ("ok", [], ["p"])], None))

    def test_which_refusals_were_overridden(self):
        for name, seq, false in self.CASES:
            with self.subTest(name):
                self.setUp()
                self.enter()
                b = self.bead_of("enforce")
                for i, (verdict, pontos, disp) in enumerate(seq):
                    self.run_row(b, "enforce", verdict, at(minutes=10 + i), pontos, disp)
                self.assertEqual(self.row(self.run_ratchet(now=at(days=1))[1])["refusals"], {"beads": 0, "false": 0} if false is None else {"beads": 1, "false": false})

    def test_the_holdout_arm_never_refuses(self):
        self.enter()
        b = self.bead_of("holdout")
        self.run_row(b, "holdout", "achados", at(minutes=10), ["p"])  # it only records what it WOULD have refused
        self.run_row(b, "holdout", "ok", at(minutes=11), (), ["p"])
        self.assertEqual(self.row(self.run_ratchet(now=at(days=1))[1])["refusals"], {"beads": 0, "false": 0})


class Process(World):
    def test_a_sibling_that_does_not_load_is_nao_sei_and_nothing_is_written(self):
        for what in (mock.patch.object(R, "P", None), mock.patch.object(R, "T", None), mock.patch.object(R.P, "load_meter", return_value=None)):
            with self.subTest(str(what)), what:
                rc, rep = self.run_ratchet("--apply")
                self.assertEqual((rc, rep["line"].startswith("NÃO SEI"), self.conf()[0]), (2, True, "absent"))

    def test_bad_flags_are_usage_not_nao_sei(self):
        for flags in (("--days", "0"), ("--min-submissions", "0"), ("--cap-days", "3"), ("--now", "ontem"), ("--bogus",), ("--days",)):
            with self.subTest(flags):
                self.assertEqual(self.run_ratchet(*flags)[0], 64)

    def test_an_exception_nobody_planned_is_70_with_the_traceback(self):
        err = io.StringIO()
        with mock.patch.object(R, "cycle", side_effect=RuntimeError("bug")), contextlib.redirect_stderr(err):
            rc = R.entry(["--city", self.city])
        self.assertEqual((rc, "RuntimeError" in err.getvalue()), (70, True))

    def test_as_a_real_process_the_siblings_are_found_and_the_report_is_json(self):
        p = subprocess.run([sys.executable, "-I", SUT, "--json", "--city", self.city, "--now", iso(ENTRY)], capture_output=True, text=True, timeout=120)
        self.assertEqual((p.returncode, json.loads(p.stdout)["classes"][0]["verdict"], p.stderr), (0, "entraria", ""))
        p = subprocess.run([sys.executable, "-I", SUT, "--bogus"], capture_output=True, text=True, timeout=120)
        self.assertEqual((p.returncode, p.stdout, p.stderr.startswith("uso:")), (64, "", True))


if __name__ == "__main__":
    unittest.main()
