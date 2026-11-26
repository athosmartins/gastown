#!/usr/bin/env python3
"""Testes herméticos de boot-first-turn.py (ga-esorlre.13): mundo falso (tmux, bd, notify), um teste por estado. Rodar: python3 -I scripts/test_boot_first_turn.py"""
import importlib.util
import json
import os
import shutil
import tempfile
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bft", os.path.join(HERE, "boot-first-turn.py"))
bft = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bft)

IDLE = "─── Oracle ─\n❯ \n─────\n  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent\n"
WORKING = "✻ Pensando… (12s · esc to interrupt)\n❯ \n"
DIALOG = "Do you want to proceed?\n ❯ 1. Yes\n  2. No\nEnter to select · Esc to cancel\n"
RIG = "/rig/whatsapp_automation"


class World(bft.Job):
    """Job com subprocess falso: `sessions` = linhas do tmux, `panes` = texto por sessão, `beads` = JSON por store."""

    def __init__(self, tmp, sessions, panes, beads, **fail):
        super().__init__({"GC_CITY_PATH": tmp, "BFT_NOTIFY": "notify"}, False)
        self.sessions_out, self.panes, self.beads, self.fail, self.calls = sessions, panes, beads, fail, []

    def run(self, argv):
        self.calls.append(argv)
        if argv[0] == "notify":
            return 0, ""
        if argv[0] == "bd":
            body = self.beads.get(argv[2])
            return (None, "") if body is None or "bd" in self.fail else (0, body)
        verb = argv[3]
        if verb == "list-sessions":
            return (None, "") if "list" in self.fail else (0, self.sessions_out)
        if verb == "capture-pane":
            name = argv[argv.index("-t") + 1].strip("=:")
            return (1, "") if name in self.fail.get("nopane", ()) or name not in self.panes else (0, self.panes[name])
        return (1, "") if self.fail.get(argv[-1] if argv[-1] == "Enter" else "text") else (0, "")

    def typed(self):
        return [c for c in self.calls if "send-keys" in c]


class T(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.tmp = self.d.name
        os.makedirs(os.path.join(self.tmp, ".gc", "logs"))
        for name, wd in (("oracle-wa", RIG + "/crew/oracle"), ("wa-worker", RIG + "/crew/worker")):
            os.makedirs(os.path.join(self.tmp, "agents", name))
            with open(os.path.join(self.tmp, "agents", name, "agent.toml"), "w") as fh:
                fh.write('max_active_sessions = 1\nwork_dir = "%s"\n' % wd)
        self.addCleanup(self.d.cleanup)
        p = mock.patch.object(bft.time, "sleep")
        p.start()
        self.addCleanup(p.stop)

    def world(self, age=300, name="oracle-wa-gawispabc", panes=None, beads=None, **fail):
        rows = "%s\t%d\ngastown__mayor\t%d\n" % (name, time.time() - age, time.time() - 5 * 86400)
        city_beads = json.dumps([{"id": "ga-1", "assignee": "oracle-wa-gawispold"}, {"id": "ga-9", "assignee": "peter-wa"}])
        return World(self.tmp, rows, {name: IDLE} if panes is None else panes, {self.tmp: city_beads, RIG + "/crew": "[]", RIG: "[]"} if beads is None else beads, **fail)

    def test_pane_states(self):
        for text, want in ((IDLE, "idle"), ('❯ Try "fix the bug"\n', "idle"), (WORKING, "working"), (DIALOG, "dialog"), ("❯ digitando algo\n", "draft"), ("$ bash\n", "unknown")):
            self.assertEqual(bft.pane_state(text), want, text)

    def test_idle_with_work_types_once_then_never_again(self):
        w = self.world()
        code, c = bft.run_pass(w)
        self.assertEqual((code, c["digitou"]), (0, 1))
        text, enter = w.typed()  # texto e Enter em chamadas separadas
        self.assertEqual(enter[-1], "Enter")
        self.assertIn("-l", text)
        self.assertNotIn("\n", text[-1])  # quebra de linha dentro do texto já enviaria a linha: o Enter é a chamada seguinte
        self.assertTrue(text[-1].startswith(bft.TAG) and "ga-1" in text[-1] and "ga-9" not in text[-1])  # incarnação anterior conta; bead de outro não
        with open(os.path.join(self.tmp, ".gc", "logs", "boot-first-turn.jsonl")) as fh:
            self.assertEqual(json.loads(fh.read())["ids"], ["ga-1"])
        w2 = self.world()
        w2.calls = []
        self.assertEqual(bft.run_pass(w2)[1]["feito"], 1)
        self.assertEqual(w2.typed(), [])

    def test_busy_pane_is_not_typed_into(self):
        for pane, key in ((WORKING, "espera"), (DIALOG, "espera"), ("❯ rascunho do Athos\n", "espera")):
            w = self.world(panes={"oracle-wa-gawispabc": pane})
            self.assertEqual(bft.run_pass(w)[1][key], 1)
            self.assertEqual(w.typed(), [], pane)

    def test_no_work_no_typing(self):
        w = self.world(beads={self.tmp: "[]", RIG: "[]"})
        self.assertEqual(bft.run_pass(w)[1]["sem-trabalho"], 1)
        self.assertEqual(w.typed(), [])

    def test_unreadable_pane_or_store_is_not_idle_nor_empty(self):
        w = self.world(nopane=("oracle-wa-gawispabc",))
        c = bft.run_pass(w)[1]
        self.assertEqual((c["nao-sei"], c["digitou"]), (1, 0))
        self.assertEqual(w.typed(), [])
        w = self.world(bd=True)  # bd não respondeu: não é «sem trabalho»
        c = bft.run_pass(w)[1]
        self.assertEqual((c["nao-sei"], c["sem-trabalho"], c["digitou"]), (1, 0, 0))

    def test_unreadable_agents_is_not_no_crews(self):
        os.makedirs(os.path.join(self.tmp, "agents", "stray"))  # pasta sem agent.toml: não é crew, e isso não é dúvida
        w = self.world()
        self.assertEqual(bft.run_pass(w)[1]["digitou"], 1)
        toml = os.path.join(self.tmp, "agents", "oracle-wa", "agent.toml")
        os.remove(toml)
        os.mkdir(toml)  # existe e não abre: não dá para saber quem é crew
        w = self.world()
        c = bft.run_pass(w)[1]
        self.assertEqual((c["nao-sei"], c["alvos"], c["digitou"]), (1, 0, 0))
        shutil.rmtree(os.path.join(self.tmp, "agents"))  # agents/ sumiu: o mesmo
        w = self.world()
        c = bft.run_pass(w)[1]
        self.assertEqual((c["nao-sei"], c["alvos"], c["digitou"]), (1, 0, 0))
        self.assertEqual(w.typed(), [])

    def test_corrupt_bd_json_is_not_no_work(self):
        for body in ("not json", '{"error": "dolt down"}', '[1, "x"]'):
            w = self.world(beads={self.tmp: body, RIG: "[]"})
            c = bft.run_pass(w)[1]
            self.assertEqual((c["nao-sei"], c["sem-trabalho"], c["digitou"]), (1, 0, 0), body)
            self.assertEqual(w.typed(), [])

    def test_corrupt_state_types_once_and_heals(self):
        for body in ("{corrupt", "[1, 2]", '{"x": "texto"}'):
            w = self.world()
            with open(w.state_path, "w") as fh:
                fh.write(body)
            self.assertEqual(bft.run_pass(w)[1]["digitou"], 1, body)  # pior caso: UMA linha a mais; não trava o 1º turno
            with open(w.state_path) as fh:
                self.assertEqual(len(json.load(fh)), 1)  # estado reescrito legível
            self.assertEqual(bft.run_pass(self.world())[1]["feito"], 1)

    def test_only_boot_window_named_crews_and_mayor(self):
        for age in (30, 3 * 3600):  # nova demais / já passou do boot
            w = self.world(age=age)
            self.assertEqual(bft.run_pass(w)[1]["digitou"], 0)
            self.assertEqual([c for c in w.calls if c[0] == "bd"], [])  # estado de regime: nem chega ao bd
        w = self.world(name="wa-worker-gawispabc")  # pool worker (crew/worker) não é alvo
        self.assertEqual(bft.run_pass(w)[1]["alvos"], 0)

    def test_tmux_list_failure_exits_3_and_types_nothing(self):
        w = self.world(list=True)
        self.assertEqual(bft.run_pass(w)[0], 3)
        self.assertEqual(w.typed(), [])

    def test_failed_typing_is_not_recorded_and_alarms(self):
        w = self.world(text=True)
        self.assertEqual(bft.run_pass(w)[1]["nao-sei"], 1)
        self.assertTrue(any(c[0] == "notify" for c in w.calls))
        self.assertFalse(os.path.exists(os.path.join(self.tmp, ".gc", "boot-first-turn.state.json")))  # tenta de novo no próximo passe

    def test_off_switch_and_dry_run(self):
        w = self.world()
        w.dry = True
        self.assertEqual(bft.run_pass(w)[1]["digitou"], 1)  # conta o que digitaria
        self.assertEqual(w.typed(), [])
        open(w.off_path, "w").close()
        self.assertTrue(bft.is_off(w))
        os.remove(w.off_path)
        os.symlink(w.off_path, w.off_path)  # laço de symlink = ilegível = desligado
        self.assertTrue(bft.is_off(w))


if __name__ == "__main__":
    unittest.main()
