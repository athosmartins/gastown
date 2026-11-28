#!/usr/bin/env python3
"""test_repro_lock.py (ga-89ix4m4): repro-lock.py e repro-lock-guard.sh com repositórios git REAIS em pastas temporárias e um `bd` de mentira (chamada não planejada falha).
`python3 -I scripts/test_repro_lock.py`; REPRO_LOCK_UNDER_TEST=<cópia.py> / REPRO_LOCK_HOOK_UNDER_TEST=<cópia.sh> rodam contra um mutante. Histórias numa mini-linguagem, um commit por item:
L <arq..> trava · C conserto · E <arq> afrouxa · S <arq> restaura · R <motivo> libera · M <arq> re-trava com outro conteúdo · G merge · LX/LG/LS/LN trava malformada."""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
OVERLAYS = os.path.join(os.path.dirname(HERE), "packs", "town-deltas", "assets", "claude-overlays")
SCRIPT = os.environ.get("REPRO_LOCK_UNDER_TEST") or os.path.join(HERE, "repro-lock.py")
HOOK = os.environ.get("REPRO_LOCK_HOOK_UNDER_TEST") or os.path.join(HERE, "repro-lock-guard.sh")
_spec = importlib.util.spec_from_file_location("repro_lock", SCRIPT)
RL = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(RL)
STRICT, LOOSE, GOOD = "def test_bug():\n    assert f() == 2\n", "def test_bug():\n    assert True\n", "o teste confere 3 mas o contrato diz 2: defeito do teste"
FAKE_BD = """#!/bin/bash
D="${FAKE_BD_DIR:?}"
case "$1" in
  show) [ -f "$D/fail-show" ] && { echo "bd: connection refused" >&2; exit 1; }; cat "$D/$2.json" 2>/dev/null || { echo "bd: no such bead $2" >&2; exit 1; } ;;
  comment) [ -f "$D/fail-comment" ] && { echo "bd: comment refused" >&2; exit 1; }; printf '%s\\t%s\\n' "$2" "$3" >> "$D/comments.log" ;;
  *) echo "bd: unplanned call $*" >&2; exit 99 ;;
esac
"""


def slurp(path):
    return Path(path).read_text(encoding="utf-8") if Path(path).exists() else ""


class Repo:
    def __init__(self, root, env):
        self.root, self.env, self.n = root, env, 0

    def git(self, *args, stdin=None):
        p = subprocess.run(["git", "-C", self.root] + list(args), capture_output=True, env=self.env, input=stdin)
        if p.returncode:
            raise AssertionError("git %s: %s" % (" ".join(args), p.stderr.decode("utf-8", "replace")))
        return p.stdout.decode("utf-8", "replace").strip()

    def write(self, rel, text):
        Path(self.root, rel).parent.mkdir(parents=True, exist_ok=True)
        Path(self.root, rel).write_text(text, encoding="utf-8")

    def commit(self, subject, trailers=(), empty=False):
        self.git("add", "-A")
        self.git("commit", "-q", *(["--allow-empty"] if empty else []), "-F", "-", stdin=(subject + ("\n\n" + "\n".join(trailers) if trailers else "") + "\n").encode())

    def build(self, script):
        for tok in (t.strip() for t in script.split("|")):
            op, _, arg = tok.partition(" ")
            self.n += 1
            files = arg.split()
            if op in ("L", "L:ga-9", "M"):
                for f in files:
                    self.write(f, STRICT + "# v2\n" if op == "M" else STRICT)
                self.commit("test", ["Repro-Lock: ga-9" if op == "L:ga-9" else "Repro-Lock: ga-1"] + ["Repro-Lock-File: " + f for f in files])
            elif op in ("LX", "LG", "LN"):  # a trava leva um arquivo a mais · declara um arquivo que o commit não adiciona · não declara arquivo
                self.write("x.py", STRICT)
                if op == "LX":
                    self.write("src/app.py", "x = 99\n")
                self.commit("test", ["Repro-Lock: ga-1"] + ([] if op == "LN" else ["Repro-Lock-File: x.py"] + (["Repro-Lock-File: ghost.py"] if op == "LG" else [])))
            elif op == "LS":  # o arquivo travado é um link simbólico
                os.symlink("src/app.py", os.path.join(self.root, files[0]))
                self.commit("test", ["Repro-Lock: ga-1", "Repro-Lock-File: " + files[0]])
            elif op == "G":  # merge de um lado inocente (nome e arquivo por item: commit idêntico é o MESMO objeto)
                side = "side%d" % self.n
                self.git("checkout", "-q", "-b", side, "main")
                self.write(side, "o\n")
                self.commit(side)
                self.git("checkout", "-q", "fix/x")
                self.git("merge", "-q", "--no-ff", "-m", "merge " + side, side)
            elif op == "R":
                self.commit("libera", ["Repro-Lock-Release: ga-1"] + (["Repro-Lock-Release-Reason: " + arg] if arg else []), empty=True)
            else:  # C conserto · E afrouxa · S restaura
                self.write(arg or "src/app.py", {"C": "x = %d\n" % (self.n + 10), "E": LOOSE, "S": STRICT}[op])
                self.commit(tok)

    def pile(self, n):  # n commits comuns sobre HEAD num só processo (fast-import): o teto de commits se testa no valor real, sem 500 forks
        self.git("fast-import", "--quiet", stdin="".join("commit refs/heads/fix/x\nmark :%d\ncommitter t <t@e.invalid> %d +0000\ndata 2\nc\nfrom %s\nM 100644 inline src/app.py\ndata 10\nx = %05d\n\n" % (i + 1, 1700000000 + i, ":%d" % i if i else "refs/heads/fix/x^0", i) for i in range(n)).encode())

    def check(self, bead="ga-1"):
        return RL.analyze(self.root, self.git("merge-base", "HEAD", "main"), "HEAD", bead)


class T(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="repro-lock-test.")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.bddir, self.k, bd = os.path.join(self.tmp, "bd"), 0, os.path.join(self.tmp, "fake-bd")
        os.makedirs(self.bddir)
        Path(bd).write_text(FAKE_BD)
        os.chmod(bd, 0o755)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GC_", "REPRO_LOCK_HOOK", "REPRO_LOCK_CHECK"))}
        self.env = dict(env, HOME=self.tmp, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e.invalid", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@e.invalid",
                        REPRO_LOCK_BD=bd, FAKE_BD_DIR=self.bddir, REPRO_LOCK_GUARD_LOG=os.path.join(self.tmp, "guard.log"))
        patch = mock.patch.dict(os.environ, self.env, clear=True)
        patch.start()
        self.addCleanup(patch.stop)

    def repo(self, script=None):
        self.k += 1
        r = Repo(os.path.join(self.tmp, "repo%d" % self.k), self.env)
        os.makedirs(r.root)
        r.git("init", "-q", "-b", "main")
        r.write("README", "base\n")
        r.write("src/app.py", "x = 1\n")
        r.commit("base")
        r.git("checkout", "-q", "-b", "fix/x")
        if script:
            r.build(script)
        return r

    def bead(self, kind="bug"):
        Path(self.bddir, "ga-1.json").write_text(json.dumps([{"id": "ga-1", "issue_type": kind}]))

    def cli(self, cwd, *args, env=None, timeout=120):
        p = subprocess.run([sys.executable, "-I", SCRIPT] + list(args), cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env or self.env, timeout=timeout)
        return p.returncode, p.stdout, p.stderr

    def chk(self, r):  # a linha de comando do passo 2f do gate
        return ("check", "--repo", r.root, "--base", r.git("merge-base", "HEAD", "main"), "--head", r.git("rev-parse", "HEAD"), "--bead", "ga-1")

    def payload(self, r, rel, tool="Edit", key="file_path"):
        return json.dumps({"tool_name": tool, "tool_input": {key: rel if os.path.isabs(rel) else os.path.join(r.root, rel)}, "cwd": r.root})


class Check(T):
    """O gate: o que a história de base..head diz da trava."""

    CASES = [  # (história, veredito, razão)
        ("C | G", "nao-se-aplica", "sem-trava-declarada"),  # merge sem trava: nada a julgar
        ("L t.py | C", "ok", "trava-integra"),
        ("L t.py | C | E t.py", "fail", "teste-travado-alterado"),
        ("L t.py | E t.py | S t.py", "fail", "teste-travado-alterado"),  # tocou e restaurou: a história mostra
        ("L t.py | M t.py", "fail", "teste-travado-alterado"),  # uma 2ª trava que muda arquivo já travado
        ("L t.py | G", "fail", "trava-em-branch-com-merge"),  # a ordem dos commits de um merge não se prova: julgado, nunca «não sei»
        ("C | L t.py", "fail", "trava-nao-e-o-primeiro-commit"),
        ("C | L t.py | R " + GOOD, "aviso", "trava-liberada-com-motivo"),
        ("L t.py | C | R " + GOOD + " | E t.py", "aviso", "trava-liberada-com-motivo"),
        ("L t.py | R " + GOOD + " | M t.py | E t.py", "fail", "teste-travado-alterado"),  # a re-trava vale
        ("L t.py | E t.py | R " + GOOD, "fail", "teste-travado-alterado"),  # liberar DEPOIS de editar não lava
        ("L t.py | R curto", "fail", "liberacao-sem-motivo"),
        ("LX", "fail", "commit-da-trava-mexe-em-outro-arquivo"),
        ("LG", "fail", "arquivo-da-trava-nao-e-regular-nem-novo"),
        ("LS t.py", "fail", "arquivo-da-trava-nao-e-regular-nem-novo"),
        ("LN", "fail", "trava-sem-arquivos"),
        ("L:ga-9 t.py | C", "aviso", "trava-so-de-outra-bead"),  # visível, nunca calada
    ]

    def test_the_verdict_of_each_history_shape(self):
        for script, verdict, reason in self.CASES:
            with self.subTest(script):
                v = self.repo(script).check()
                self.assertEqual((v["verdict"], v["reason"]), (verdict, reason), v)
        v = self.repo("L t.py u.py | C | R " + GOOD).check()
        self.assertEqual((v["locks"], v["files"], v["releases"]), (1, 2, 1))

    def test_long_history_nul_in_a_message_and_a_root_lock_are_judged_never_unknown(self):
        r, r2 = self.repo("L t.py | C | C | C | C"), self.repo("C | C | C | C | C")
        with mock.patch.object(RL, "MAX_COMMITS", 3):  # histórico longo: trava declarada é recusa; sem trava, não se aplica
            self.assertEqual([r.check()[k] for k in ("verdict", "reason")], ["fail", "historia-longa-demais-com-trava"])
            self.assertEqual(r2.check()["reason"], "historia-longa-sem-trava")
            self.assertIn("UNGUARDED mais de 3 commits", RL.guard_cmd(self.payload(r, "t.py"))[1])  # o hook desiste COM contagem do que o gate já recusa por tamanho: sem teto ele estourava o prazo do hook sem dizer nada
        r = self.repo("L t.py")
        r.write("t.py", LOOSE)
        r.git("add", "-A")  # NUL e os separadores de um formato ingênuo no texto do construtor não deslocam o registro seguinte
        hdr = "tree %s\nparent %s\nauthor t <t@e.invalid> 1700000000 +0000\ncommitter t <t@e.invalid> 1700000000 +0000\n\n" % (r.git("write-tree"), r.git("rev-parse", "HEAD"))
        r.git("update-ref", "HEAD", r.git("hash-object", "-t", "commit", "-w", "--stdin", "--literally", stdin=hdr.encode() + b"x\n\nRepro-Lock-Release: ga-9\x00\x1f fim\n\nRepro-Lock: ga-9\n"))
        self.assertEqual(r.check()["reason"], "teste-travado-alterado")
        r = self.repo()
        main_sha = r.git("rev-parse", "main")
        r.git("checkout", "-q", "--orphan", "orph")
        r.git("rm", "-rfq", ".")
        r.build("L t.py")  # a trava é commit-raiz: comparada à árvore vazia
        self.assertEqual(RL.analyze(r.root, main_sha, "HEAD", "ga-1")["verdict"], "ok")
        for repo, base in ((r.root, "0" * 40), (os.path.join(self.tmp, "no-such-dir"), main_sha)):  # só o que o construtor NÃO controla (git que falha) é «não sei»
            with self.assertRaises(RL.Cant):
                RL.analyze(repo, base, "HEAD", "ga-1")
        with mock.patch.object(RL, "gt", return_value="abc"), self.assertRaises(RL.Cant):  # git que responde algo ilegível: «não sei» (Cant), nunca um traceback nem um número inventado
            RL.too_long(r.root, "a", "b")

    def test_the_commit_cap_sits_where_the_docs_say(self):  # runbook e comentário dizem 500: 500 commits passam, 501 com trava é recusa (o custo é um diff-tree por commit comum)
        r = self.repo("L t.py")
        r.pile(499)
        self.assertEqual(r.check()["verdict"], "ok")
        r.pile(1)
        self.assertEqual([r.check()[k] for k in ("verdict", "reason")], ["fail", "historia-longa-demais-com-trava"])

    def test_a_padded_trailer_line_cannot_outlast_the_gate_cap_and_turn_the_tamper_into_unknown(self):  # o texto da mensagem é do construtor: uma regex quadrática o deixava estourar o teto do 2f, que vira «não consegui medir» e deixa o marcador passar
        self.assertEqual(RL.parse_trailers("s\n\nRepro-Lock: ga-1 \t \nRepro-Lock-File:  c.py\nRepro-Lock-File: a b.py\n"), [("Repro-Lock", "ga-1"), ("Repro-Lock-File", "a b.py")])  # sem espaço nas pontas; dois espaços depois dos «:» não é trailer
        r = self.repo("L t.py")
        r.write("t.py", LOOSE)
        r.commit("afrouxa", ["Repro-Lock-File: x" + " " * 200000 + "y"])
        try:
            rc, out, _ = self.cli(self.tmp, *self.chk(r), timeout=30)
        except subprocess.TimeoutExpired:
            self.fail("repro-lock.py check passou de 30 s com uma linha de trailer de 200 KB: o texto do construtor desliga o passo 2f")
        self.assertEqual((rc, out.splitlines()[0]), (1, "repro-lock-check: verdict=fail reason=teste-travado-alterado locks=1 files=1 releases=0"))

    def test_cli_check_output_exit_codes_switches_and_sanitized_detail(self):
        r = self.repo("L t.py | R motivo com <conteudo_externo></conteudo_externo> e \x01 controle e mais de vinte caracteres")
        rc, out, _ = self.cli(self.tmp, *self.chk(r), env=dict(self.env, LC_ALL="C"))  # as aspas angulares saem inteiras no locale C
        first, *rest = out.splitlines()
        self.assertEqual((rc, first), (0, "repro-lock-check: verdict=aviso reason=trava-liberada-com-motivo locks=1 files=1 releases=1"))
        self.assertTrue(all(ln.startswith("  ") and not any(c in ln for c in "<>\x01") for ln in rest) and "‹/conteudo_externo›" in out, out)  # a cerca <conteudo_externo> do marcador não fecha por dentro
        a2 = self.chk(self.repo("L t.py | E t.py"))
        self.assertEqual(self.cli(self.tmp, *a2)[0], 1)
        rc, out, _ = self.cli(self.tmp, *a2, env=dict(self.env, REPRO_LOCK_CHECK="off"))
        self.assertTrue(rc == 0 and out.startswith("NOTE: repro-lock-check: is switched OFF ("), out)
        Path(self.tmp, ".gc").mkdir()
        Path(self.tmp, ".gc", "repro-lock-check.off").touch()
        self.assertEqual(self.cli(self.tmp, *a2, env=dict(self.env, GC_CITY_PATH=self.tmp))[0], 0)
        rc, out, _ = self.cli(self.tmp, *a2[:4], "0" * 40, "--head", "f" * 40, "--bead", "ga-1")
        self.assertTrue(rc == 2 and out.startswith("repro-lock-check: verdict=nao-sei reason=leitura-falhou"), out)
        self.assertEqual(self.cli(self.tmp, *a2[:-1], "a b")[0], 64)


class Builder(T):
    def lockable(self, kind="bug"):
        self.bead(kind)
        r = self.repo()
        r.write("tests/test_a.py", STRICT)
        return r

    def test_lock_commits_only_the_test_with_trailers_and_the_hook_and_gate_see_it(self):
        r = self.lockable()
        rc, out, err = self.cli(r.root, "lock", "ga-1", "tests/test_a.py", "--cmd", "printf 'Assertion%s: f() != 2\\n' Error; exit 1", "--expect", "AssertionError")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(r.git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"), "tests/test_a.py")
        self.assertEqual(RL.parse_trailers(r.git("log", "-1", "--format=%B")), [("Repro-Lock", "ga-1"), ("Repro-Lock-File", "tests/test_a.py")])
        comments = slurp(os.path.join(self.bddir, "comments.log"))
        self.assertIn("[repro-lock] TRAVADO: tests/test_a.py @ " + r.git("rev-parse", "--short=7", "HEAD"), comments)
        self.assertNotIn("AssertionError", comments)  # a saída do teste pode ter dado: não vai para a bead
        self.assertEqual(r.check()["verdict"], "ok")
        self.assertEqual(RL.guard_cmd(self.payload(r, "tests/test_a.py"))[0], 2)  # o hook lê a mesma história: nenhum estado local

    def test_lock_refuses_every_case_it_cannot_vouch_for_and_leaves_no_commit(self):
        def refused(r, want, *args):
            head = r.git("rev-parse", "HEAD")
            rc, out, err = self.cli(r.root, "lock", "ga-1", *args)
            self.assertEqual((rc, want in err, r.git("rev-parse", "HEAD")), (2, True, head), (args, err))

        t0 = time.monotonic()
        refused(self.lockable("feature"), "tipo 'feature'", "tests/test_a.py", "--cmd", "exit 1")
        r = self.lockable()
        Path(self.bddir, "fail-show").touch()  # bd fora do ar: «não sei o tipo» não vira «pode travar»
        refused(r, "NÃO SEI", "tests/test_a.py", "--cmd", "exit 1")
        os.unlink(os.path.join(self.bddir, "fail-show"))
        Path(self.bddir, "ga-1.json").write_text("{não é json")  # JSON ilegível: também não vira «pode travar»
        refused(r, "NÃO SEI", "tests/test_a.py", "--cmd", "exit 1")
        self.bead()
        for want, args in (("não é arquivo regular", ("tests/test_nao_existe.py",)), ("não é arquivo regular", ("/etc/hostname",)), ("PASSA no código de hoje", ("tests/test_a.py", "--cmd", "true")),
                           ("rc 127", ("tests/test_a.py", "--cmd", "comando-que-nao-existe-xyz")), ("AMBIENTE", ("tests/test_a.py", "--cmd", "echo 'ModuleNotFoundError: x'; exit 1")),
                           ("não casa --expect", ("tests/test_a.py", "--cmd", "echo outro; exit 1", "--expect", "AssertionError")), ("passou de 1s", ("tests/test_a.py", "--cmd", "sleep 20 & sleep 20", "--timeout", "1"))):
            refused(r, want, *(args if "--cmd" in args else args + ("--cmd", "exit 1")))  # TimeoutExpired: «não sei» não é «reproduz»
        r.git("commit", "-q", "--allow-empty", "-m", "comum antes da trava")
        refused(r, "1º commit", "tests/test_a.py", "--cmd", "exit 1")
        refused(self.repo(), "mudança nova", "README", "--cmd", "exit 1")
        for dirty in (lambda x: (x.write("src/app.py", "x = 2\n"), x.git("add", "src/app.py")), lambda x: x.write("src/app.py", "x = 2\n"), lambda x: x.write("src/novo.py", "y = 1\n")):  # no índice · só alterada · arquivo novo: «falha no código de hoje» mede o HEAD, não um código alterado à mão
            x = self.lockable()
            dirty(x)
            refused(x, "fora dos arquivos de teste", "tests/test_a.py", "--cmd", "exit 1")
        self.assertLess(time.monotonic() - t0, 15)  # o estouro mata o GRUPO: um neto segurando o pipe não segura o comando por 20 s


class Guard(T):
    """O motor do hook (guard_cmd): a trava vem da história, sem estado local."""

    def test_a_locked_file_is_blocked_for_every_edit_tool_and_the_rest_passes(self):
        r = self.repo("L tests/t.py | C")
        for tool, key in (("Edit", "file_path"), ("Write", "file_path"), ("MultiEdit", "file_path"), ("NotebookEdit", "notebook_path")):
            rc, err = RL.guard_cmd(self.payload(r, "tests/t.py", tool, key))
            self.assertEqual(rc, 2, tool)
            self.assertTrue(err.startswith("repro-lock-guard: BLOCKED — «tests/t.py» está TRAVADO pela bead ga-1"), err)
            self.assertTrue(all(n in err for n in ("NÃO contorne por Bash", "OUTRO arquivo de teste", "bd comment ga-1", "Repro-Lock-Release: ga-1")), err)
        for rel, tool in (("src/app.py", "Edit"), ("tests/new.py", "Write"), ("tests/t.py", "Read"), ("tests/t.py", "Bash")):
            self.assertEqual(RL.guard_cmd(self.payload(r, rel, tool)), (0, ""), (rel, tool))
        self.assertEqual(RL.guard_cmd(json.dumps({"tool_name": "Edit", "tool_input": {"file_path": "tests/t.py"}, "cwd": r.root}))[0], 2)  # caminho relativo ao cwd do payload
        target, link = os.path.join(r.root, "tests", "t.py"), os.path.join(r.root, "src", "alias.py")
        os.link(target, link)  # o mesmo inode com outro nome: editar o alias edita o teste travado no lugar
        self.assertEqual(RL.guard_cmd(self.payload(r, link))[0], 2)
        shutil.rmtree(os.path.dirname(target))
        os.unlink(link)  # a pasta inteira sumiu (rm -r por Bash) e um Write a recriaria com outro conteúdo
        self.assertEqual(RL.guard_cmd(self.payload(r, "tests/../tests/t.py", "Write"))[0], 2)
        r3 = self.repo("L t.py | L:ga-9 u.py")  # duas beads na mesma história: cada trava com a sua
        self.assertEqual(RL.locked_now(r3.root, r3.git("merge-base", "HEAD", "main")), {"t.py": "ga-1", "u.py": "ga-9"})

    def test_a_release_frees_it_and_every_doubt_fails_open_and_says_so(self):
        r = self.repo("L tests/t.py | R " + GOOD)
        self.assertEqual(RL.guard_cmd(self.payload(r, "tests/t.py")), (0, ""))
        self.assertEqual(RL.guard_cmd("{not json"), (0, "UNGUARDED payload do hook não é JSON"))
        for text in (json.dumps([1]), json.dumps({"tool_name": "Edit", "tool_input": "x"}), json.dumps({"tool_name": "Edit", "tool_input": {}}), json.dumps({"tool_name": "Write", "tool_input": {"file_path": ""}}), json.dumps({"tool_input": {"file_path": "tests/t.py"}})):
            rc, err = RL.guard_cmd(text)
            self.assertTrue(rc == 0 and err.startswith("UNGUARDED payload sem"), (text, err))  # payload de outro formato: dúvida CONTADA, nunca o silêncio de «nada a guardar»
        fora = os.path.join(self.tmp, "fora")
        os.makedirs(fora)
        self.assertEqual(RL.guard_cmd(self.payload(r, os.path.join(fora, "a.py"))), (0, ""))  # fora de qualquer repo o arquivo não pode estar travado: nada a guardar, e fora da contagem (cada rascunho fora do repo a enchia de ruído)
        Path(fora, ".git").write_text("lixo\n")
        self.assertIn("UNGUARDED", RL.guard_cmd(self.payload(r, os.path.join(fora, "a.py")))[1])  # um .git que o git não consegue ler é dúvida de verdade: contada
        r2 = self.repo("L tests/t.py")
        r2.git("branch", "-m", "main", "other")  # sem origin/main nem main: não sei a base
        self.assertIn("UNGUARDED não achei origin/main nem main", RL.guard_cmd(self.payload(r2, "tests/t.py"))[1])


class Wrapper(T):
    """repro-lock-guard.sh de verdade (bash) e o comando REAL dos overlays gerados."""

    POOL = {"GC_TEMPLATE": "gastown.dog"}

    def setUp(self):
        super().setUp()
        self.sd = os.path.join(self.tmp, "gt", ".gascity-gastown-hq", "scripts")
        os.makedirs(self.sd)
        shutil.copy(HOOK, os.path.join(self.sd, "repro-lock-guard.sh"))
        shutil.copy(SCRIPT, os.path.join(self.sd, "repro-lock.py"))
        self.hk = os.path.join(self.sd, "repro-lock-guard.sh")

    def hook(self, payload, env=None, script=None):
        p = subprocess.run(["/bin/bash", script or self.hk], input=payload, capture_output=True, text=True, env=dict(self.env, **(self.POOL if env is None else env)), timeout=60)
        return p.returncode, p.stderr

    def test_blocks_the_locked_file_only_for_builders_and_the_switches_turn_it_off(self):
        r = self.repo("L tests/t.py | C")
        p = self.payload(r, "tests/t.py")
        rc, err = self.hook(p)
        self.assertEqual(rc, 2, err)
        self.assertTrue(err.startswith("repro-lock-guard: BLOCKED — «tests/t.py» está TRAVADO pela bead ga-1"), err)
        self.assertIn("BLOCKED", slurp(self.env["REPRO_LOCK_GUARD_LOG"]))
        self.assertEqual(self.hook(self.payload(r, "src/app.py")), (0, ""))
        for env in ({}, {"GC_AGENT": "mayor"}, {"GC_TEMPLATE": "gate-reviewer"}, {"GC_TEMPLATE": "ps-worker"}, {"GC_TEMPLATE": "gastown.mayor", "GC_AGENT": "dog-remote-1"}):  # revisor, Mayor, crews e identidade incoerente passam
            self.assertEqual(self.hook(p, env=env), (0, ""), env)
        for env in ({"GC_TEMPLATE": "dog-remote"}, {"GC_TEMPLATE": "wa-worker"}, {"GC_TEMPLATE": "wa-worker-remote"}, {"GC_AGENT": "dog-remote-1"}, {"GC_ALIAS": "wa-worker-3"}):
            self.assertEqual(self.hook(p, env=env)[0], 2, env)
        self.assertEqual(self.hook(p, env=dict(self.POOL, REPRO_LOCK_HOOK="0")), (0, ""))
        Path(self.tmp, ".gc").mkdir()
        Path(self.tmp, ".gc", "repro-lock-hook.off").touch()
        self.assertEqual(self.hook(p, env=dict(self.POOL, GC_CITY_PATH=self.tmp)), (0, ""))

    def test_every_way_the_wrapper_cannot_do_its_job_fails_open_and_is_counted(self):
        p = self.payload(self.repo("L tests/t.py"), "tests/t.py")
        broken = os.path.join(self.tmp, "broken")
        os.makedirs(broken)
        shutil.copy(HOOK, os.path.join(broken, "repro-lock-guard.sh"))

        def run(what, want, payload=p, code=None, env=None, real=False):
            if code is not None:
                Path(broken, "repro-lock.py").write_text(code)
            Path(self.env["REPRO_LOCK_GUARD_LOG"]).write_text("")
            rc, _ = self.hook(payload, env=dict(self.POOL, **(env or {})), script=None if real else os.path.join(broken, "repro-lock-guard.sh"))
            self.assertEqual(rc, 0, what)
            self.assertIn(want, slurp(self.env["REPRO_LOCK_GUARD_LOG"]), what)

        run("empty payload", "hook input was empty", payload="", real=True)
        run("engine missing", "motor ausente")
        run("rc 2 without the BLOCKED mark", "rc=2", code="import sys\nsys.exit(2)\n")

    def test_the_generated_overlay_command_blocks_builders_fails_open_without_the_script_and_others_have_none(self):
        r = self.repo("L tests/t.py")
        for role in ("pool-dog", "pool-wa-worker", "pool-ps-worker", "pool-reviewer"):
            groups = json.loads(slurp(os.path.join(OVERLAYS, role, ".claude", "settings.json")))["hooks"]["PreToolUse"]
            mine = [g for g in groups if any("repro-lock-guard" in h.get("command", "") for h in g["hooks"])]
            self.assertEqual(len({g["matcher"] for g in groups}), len(groups))  # o motor mescla por identidade de matcher: nenhum repetido
            if role in ("pool-reviewer", "pool-ps-worker"):
                self.assertEqual(mine, [], role)
                continue
            self.assertEqual([g["matcher"] for g in mine], ["^(Edit|Write|MultiEdit|NotebookEdit)$"])
            cmd = mine[0]["hooks"][0]["command"].replace("/Users/athos/gt", os.path.join(self.tmp, "gt"))

            def run(tpl):
                p = subprocess.run(["/bin/bash", "-c", cmd], input=self.payload(r, "tests/t.py"), capture_output=True, text=True, env=dict(self.env, GC_TEMPLATE=tpl), timeout=60)
                return p.returncode, p.stderr.startswith("repro-lock-guard: BLOCKED")

            self.assertEqual((run("gastown.dog"), run("gastown.mayor")), ((2, True), (0, False)), role)
            os.rename(self.hk, self.hk + ".gone")  # script ausente: inerte (e `live` acusa)
            self.assertEqual(run("gastown.dog"), (0, False))
            os.rename(self.hk + ".gone", self.hk)


if __name__ == "__main__":
    unittest.main(verbosity=1)
