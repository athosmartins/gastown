#!/usr/bin/env python3
"""daemon-unverified-sweep.selftest.py — selftest do vigia semanal de delivery:daemon-unverified (ga-iyfe83).

Roda o vigia DE VERDADE (subprocess) num mundo falso mas fiel: repo git real, `bd`/`launchctl`/`ps` falsos que gravam
cada chamada (o `bd` respeita --all e --limit) e um LaunchAgents com plists de verdade.
Protege a regra de TRÊS estados que nunca colapsam (CONFIRMADO · AINDA NÃO VISTO · NÃO CONSEGUI SABER) e, acima de
tudo, que "leitura falhou" NUNCA vira CONFIRMADO.

Uso:  python3 daemon-unverified-sweep.selftest.py        (rc 0 = tudo verde)
"""
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SWEEP = os.environ.get("DUS_SWEEP_UNDER_TEST", os.path.join(HERE, "daemon-unverified-sweep.py"))

T0 = 1_790_000_000          # "agora" fixo do mundo falso (DUS_NOW)
H = 3600
D = 86400

CONFIRMADO = "CONFIRMADO"
AINDA = "AINDA NÃO VISTO"
NCS = "NÃO CONSEGUI SABER"
OUT = "FORA DE ESCOPO"      # bead com o rótulo mas ainda não fechado: fica FORA dos três estados (não é um quarto estado)

FAKE_BD = r'''#!%(py)s
import json, os, sys
fake = os.environ["DUS_FAKE_DIR"]
argv = sys.argv[1:]
with open(os.path.join(fake, "bd.calls"), "a") as f:
    f.write(" ".join(argv) + "\n")
store = ""
if argv[:1] == ["-C"]:
    store = os.path.basename(argv[1].rstrip("/"))
    argv = argv[2:]
if not argv or argv[0] != "list":
    sys.stderr.write("fake bd: so sei 'list'\n"); sys.exit(2)
labels = [argv[i + 1] for i, a in enumerate(argv) if a == "--label" and i + 1 < len(argv)]
if "delivery:daemon-unverified" not in labels:
    sys.stderr.write("fake bd: consulta inesperada %%r\n" %% (labels,)); sys.exit(2)
# falha injetada: sempre (fail/<store>) ou as N primeiras chamadas (flaky/<store>)
failp = os.path.join(fake, "fail", store)
if os.path.exists(failp):
    sys.stderr.write("[mysql] i/o timeout\nError: search count issues: invalid connection\n"); sys.exit(1)
flakyp = os.path.join(fake, "flaky", store)
if os.path.exists(flakyp):
    n = int(open(flakyp).read().strip() or "0")
    if n > 0:
        open(flakyp, "w").write(str(n - 1))
        sys.stderr.write("Error: invalid connection\n"); sys.exit(1)
datap = os.path.join(fake, "stores", store + ".json")
data = json.load(open(datap)) if os.path.exists(datap) else []
if "--all" not in argv:                      # `bd list` sem --all não traz os fechados
    data = [b for b in data if b.get("status") != "closed"]
lim = argv[argv.index("--limit") + 1] if "--limit" in argv else "50"
print(json.dumps(data if lim == "0" else data[:int(lim)]))   # sem `--limit 0` o bd corta em 50 (ga-21kmp)
'''

FAKE_LAUNCHCTL = r'''#!%(py)s
import os, sys
fake = os.environ["DUS_FAKE_DIR"]
with open(os.path.join(fake, "launchctl.calls"), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
if sys.argv[1:2] != ["list"] or len(sys.argv) < 3:
    sys.stderr.write("fake launchctl: so sei 'list <label>'\n"); sys.exit(2)
label = sys.argv[2]
if os.path.exists(os.path.join(fake, "launchctl", label + ".fail")):
    sys.stderr.write("launchctl: Operation not permitted while talking to launchd\n"); sys.exit(1)
p = os.path.join(fake, "launchctl", label)
if not os.path.exists(p):
    sys.stderr.write('Could not find service "%%s" in domain for port\n' %% label); sys.exit(113)
sys.stdout.write(open(p).read())
'''

FAKE_PS = r'''#!%(py)s
import os, sys
fake = os.environ["DUS_FAKE_DIR"]
with open(os.path.join(fake, "ps.calls"), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
pid = sys.argv[sys.argv.index("-p") + 1]
p = os.path.join(fake, "ps", pid)
if not os.path.exists(p):
    sys.exit(1)
sys.stdout.write(open(p).read())
'''


def _exe(path, body):
    with open(path, "w") as f:
        f.write(body % {"py": sys.executable})
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)


class World:
    """Um mundo falso mas fiel: repo git real + bd/launchctl/ps falsos."""

    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="dus-selftest-")
        self.fake = os.path.join(self.tmp, "fake")
        for sub in ("stores", "launchctl", "ps", "fail", "flaky"):
            os.makedirs(os.path.join(self.fake, sub))
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        _exe(os.path.join(self.bin, "bd"), FAKE_BD)
        _exe(os.path.join(self.bin, "launchctl"), FAKE_LAUNCHCTL)
        _exe(os.path.join(self.bin, "ps"), FAKE_PS)
        self.la = os.path.join(self.tmp, "LaunchAgents")
        os.makedirs(self.la)
        self.out = os.path.join(self.tmp, "logs")
        self.hq_store = os.path.join(self.tmp, "hq")
        self.rig_store = os.path.join(self.tmp, "rig")
        os.makedirs(self.hq_store)
        os.makedirs(self.rig_store)
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(self.repo)
        self.git("init", "-q", "-b", "main")
        self.beads = {"hq": [], "rig": []}
        self.env_extra = {}
        self._pid = 1000

    def git(self, *args):
        r = subprocess.run(["git", "-C", self.repo, "-c", "user.name=t", "-c", "user.email=t@t", *args],
                           capture_output=True, text=True)
        assert r.returncode == 0, "git %s: %s" % (args, r.stderr)
        return r.stdout.strip()

    def commit(self, files, msg="c"):
        for rel, content in files.items():
            p = os.path.join(self.repo, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as f:
                f.write(content)
            self.git("add", rel)
        self.git("commit", "-q", "-m", msg)
        return self.git("rev-parse", "HEAD")

    def plist(self, label, program_rel, **keys):
        d = {"Label": label, "ProgramArguments": ["/bin/bash", os.path.join(self.repo, program_rel)]}
        d.update(keys)
        with open(os.path.join(self.la, label + ".plist"), "wb") as f:
            plistlib.dump(d, f)

    def loaded(self, label, pid=None, start=None):
        """launchctl list <label> passa a achar o serviço; com pid, o processo (ps) começou em `start`."""
        body = '{\n\t"Label" = "%s";\n\t"LastExitStatus" = 0;\n' % label
        if pid is not None:
            body += '\t"PID" = %d;\n' % pid
        body += "};\n"
        with open(os.path.join(self.fake, "launchctl", label), "w") as f:
            f.write(body)
        if pid is not None and start is not None:
            self.proc_start(pid, start)

    def proc_start(self, pid, epoch):
        with open(os.path.join(self.fake, "ps", str(pid)), "w") as f:
            f.write(time.strftime("%a %b %e %H:%M:%S %Y", time.localtime(epoch)) + "\n")

    def next_pid(self):
        self._pid += 1
        return self._pid

    def bead(self, bid, rig="hq", close_reason="", closed_at=T0, status="closed", title=None):
        self.beads[rig].append({
            "id": bid, "title": title or ("bead " + bid), "status": status,
            "closed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(closed_at)) if closed_at else None,
            "close_reason": close_reason,
            "labels": ["delivery:daemon-unverified"],
        })

    def fail(self, store):
        open(os.path.join(self.fake, "fail", os.path.basename(getattr(self, store + "_store"))), "w").close()

    def flaky(self, store, n):
        with open(os.path.join(self.fake, "flaky", os.path.basename(getattr(self, store + "_store"))), "w") as f:
            f.write(str(n))

    def run(self, *flags, now=T0 + 10 * D, extra_env=None):
        for key, store in (("hq", self.hq_store), ("rig", self.rig_store)):
            with open(os.path.join(self.fake, "stores", os.path.basename(store) + ".json"), "w") as f:
                json.dump(self.beads[key], f)
        env = dict(os.environ)
        env.update({
            "DUS_FAKE_DIR": self.fake, "DUS_BD": os.path.join(self.bin, "bd"),
            "DUS_LAUNCHCTL": os.path.join(self.bin, "launchctl"), "DUS_PS": os.path.join(self.bin, "ps"),
            "DUS_LAUNCH_AGENTS_DIR": self.la,
            "DUS_OUT_DIR": self.out, "DUS_NOW": str(now), "DUS_RETRY_SLEEP": "0", "DUS_RETRIES": "3",
            "DUS_STORES": "hq|%s|%s;rig|%s|%s" % (self.hq_store, self.repo, self.rig_store, self.repo),
        })
        env.update(self.env_extra)
        env.update(extra_env or {})
        r = subprocess.run([sys.executable, SWEEP, *flags], capture_output=True, text=True, env=env, timeout=120)
        self.last = r
        calls = self.calls("launchctl")                 # em QUALQUER teste: só LÊ o launchd, nada de kickstart / bootout / unload / kill
        assert all(c.startswith("list ") for c in calls), calls
        return r

    def report(self):
        with open(os.path.join(self.out, "daemon-unverified-sweep-latest.json")) as f:
            return json.load(f)

    def state_of(self, bid):
        for b in self.report()["beads"]:
            if b["id"] == bid:
                return b
        raise AssertionError("bead %s ausente do relatório" % bid)

    def calls(self, name):
        p = os.path.join(self.fake, name + ".calls")
        if not os.path.exists(p):
            return []
        with open(p) as f:
            return f.read().splitlines()

    def cleanup(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class SweepTest(unittest.TestCase):
    def setUp(self):
        self.w = World()
        self.addCleanup(self.w.cleanup)

    def verdict(self, bid, state, reason=None):
        b = self.w.state_of(bid)
        self.assertEqual(b["state"], state, b)
        if reason:
            self.assertEqual(b["reason"], reason, b)
        return b

    def daemon_world(self, keepalive=True, merge_at=T0 + 5 * D):
        """Um daemon KeepAlive 'svc' dono de bin/svc.sh, e uma entrega mergeada em `merge_at`."""
        w = self.w
        w.commit({"bin/svc.sh": "echo v1\n"}, "feat: svc v1")
        sha = w.commit({"bin/svc.sh": "echo v2\n"}, "fix(ga-aaa111): svc v2")
        w.plist("com.test.svc", "bin/svc.sh", **({"KeepAlive": True} if keepalive else {}))
        w.bead("ga-aaa111", close_reason="Quality gate PASSED — merged (sha=%s, gate_run=ga-r1). Closed." % sha, closed_at=merge_at)
        return sha

    def test_confirmado_quando_o_daemon_subiu_depois_do_merge(self):
        w = self.w
        self.daemon_world(merge_at=T0 + 5 * D)
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 6 * D)       # subiu 1 dia DEPOIS do merge
        r = w.run()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.verdict("ga-aaa111", CONFIRMADO)
        self.assertEqual(w.report()["counts"][CONFIRMADO], 1)
        w.beads["hq"][0]["closed_at"] = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(T0 + 5 * D)) + ".5Z"   # com fração também lê
        w.run()
        self.verdict("ga-aaa111", CONFIRMADO)

    def test_ainda_nao_visto_quando_o_daemon_subiu_antes_do_merge(self):
        w = self.w
        self.daemon_world(merge_at=T0 + 5 * D)
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 4 * D)       # subiu 1 dia ANTES do merge
        w.run()
        self.verdict("ga-aaa111", AINDA)

    def test_ainda_nao_visto_quando_o_daemon_nao_esta_carregado(self):
        w = self.w
        self.daemon_world()                                                # plist existe; launchctl não acha o serviço
        w.run()
        self.verdict("ga-aaa111", AINDA, "not-loaded")

    def test_ncs_quando_daemon_keepalive_carregado_sem_processo(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc")                                           # carregado, sem PID: o início não se lê
        w.run()
        self.verdict("ga-aaa111", NCS, "loaded-no-pid")                    # nem AINDA nem CONFIRMADO (run-to-completion oscila)

    def test_ncs_quando_o_close_reason_nao_traz_sha_ou_o_sha_nao_esta_no_disco(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        w.beads["hq"][0]["close_reason"] = "Story DELIVERED — story:done. DAEMON LIVENESS NOT VERIFIED"
        w.run()
        self.verdict("ga-aaa111", NCS, "no-merge-sha")
        w.beads["hq"][0]["close_reason"] = "PASSED (sha=%s)" % ("ab" * 20)
        w.run()
        self.verdict("ga-aaa111", NCS, "sha-not-on-disk")

    def test_ncs_quando_nenhum_daemon_e_dono_do_codigo_mergeado(self):
        w = self.w
        w.commit({"bin/svc.sh": "echo v1\n"}, "feat: svc")
        sha = w.commit({"docs/notas.md": "só doc\n"}, "docs(ga-bbb222): notas")
        w.plist("com.test.svc", "bin/svc.sh", KeepAlive=True)
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        w.bead("ga-bbb222", close_reason="PASSED (sha=%s)" % sha, closed_at=T0 + 5 * D)
        w.run()
        self.verdict("ga-bbb222", NCS, "no-daemon")

    def test_sha_que_existe_mas_nao_esta_no_checkout_vivo_tem_motivo_proprio(self):
        w = self.w
        self.daemon_world()
        w.git("checkout", "-q", "-b", "atras", "HEAD~1")                   # o checkout vivo está atrás do merge
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        w.run()
        self.verdict("ga-aaa111", NCS, "sha-not-in-checkout")              # ≠ sha-not-on-disk: o sha existe, o código não está lá

    def test_listagem_da_loja_que_falha_so_uma_vez_e_recuperada_pelo_retry(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        w.flaky("hq", 1)                                              # o Dolt estoura timeout UMA vez
        r = w.run()
        self.assertEqual(r.returncode, 0, r.stderr)                         # e a loja NÃO vira "falhou" nem "zero beads"
        self.assertEqual(w.state_of("ga-aaa111")["state"], CONFIRMADO)

    def test_leitura_do_launchctl_falhou_nao_vira_confirmado(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        open(os.path.join(w.fake, "launchctl", "com.test.svc.fail"), "w").close()
        r = w.run()
        self.verdict("ga-aaa111", NCS, "launchctl-read-failed")          # ≠ not-loaded: erro NÃO é "não carregado"
        self.assertNotEqual(r.returncode, 0)

    def test_leitura_do_ps_falhou_nao_vira_confirmado(self):
        w = self.w
        self.daemon_world()
        pid = w.next_pid()
        w.loaded("com.test.svc", pid=pid)                                  # tem PID, mas o ps não responde
        r = w.run()
        self.verdict("ga-aaa111", NCS, "ps-read-failed")
        self.assertNotEqual(r.returncode, 0)
        with open(os.path.join(w.fake, "ps", str(pid)), "w") as f:         # e com o lstart ilegível, também
            f.write("ontem à tarde\n")
        w.run()
        self.verdict("ga-aaa111", NCS, "ps-read-failed")

    def test_repo_git_quebrado_nao_vira_sha_fora_do_disco_nem_confirmado(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)       # sem a falha seria CONFIRMADO
        with open(os.path.join(w.repo, ".git", "HEAD"), "w") as f:         # o git responde 128 pra QUALQUER pergunta
            f.write("garbage\n")
        r = w.run()
        self.verdict("ga-aaa111", NCS, "git-read-failed")                # ≠ sha-not-on-disk: git quebrado NÃO é "sha ausente"
        self.assertNotEqual(r.returncode, 0, "leitura de git que falha tem que falhar ALTO (rc != 0)")

    def test_objeto_ilegivel_na_leitura_dos_arquivos_da_entrega_nao_vira_confirmado(self):
        w = self.w
        sha = self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        tree = w.git("rev-parse", sha + "^{tree}")                         # o commit existe e é ancestral; só a árvore some
        obj = os.path.join(w.repo, ".git", "objects", tree[:2], tree[2:])
        os.chmod(obj, 0o644)
        os.unlink(obj)
        r = w.run()
        self.verdict("ga-aaa111", NCS, "git-read-failed")
        self.assertNotEqual(r.returncode, 0)

    def two_owner_world(self):
        w = self.w
        w.commit({"bin/a.sh": "a1\n", "bin/b.sh": "b1\n"}, "feat: a e b")
        sha = w.commit({"bin/a.sh": "a2\n", "bin/b.sh": "b2\n"}, "fix(ga-ddd444): a e b")
        w.plist("com.test.a", "bin/a.sh", KeepAlive=True)
        w.plist("com.test.b", "bin/b.sh", KeepAlive=True)
        w.bead("ga-ddd444", close_reason="PASSED (sha=%s)" % sha, closed_at=T0 + 5 * D)

    def test_confirmado_exige_todos_os_donos_confirmados(self):
        w = self.w
        self.two_owner_world()
        w.loaded("com.test.a", pid=w.next_pid(), start=T0 + 6 * D)         # a reiniciou
        pb = w.next_pid()
        w.loaded("com.test.b", pid=pb, start=T0 + 4 * D)                    # b NÃO: um dono sem reinício basta pra AINDA
        w.run()
        b = self.verdict("ga-ddd444", AINDA)
        self.assertEqual(sorted(b["owners"]), ["com.test.a", "com.test.b"])
        w.proc_start(pb, T0 + 6 * D)                                        # agora b também: só então CONFIRMADO
        w.run()
        self.verdict("ga-ddd444", CONFIRMADO)

    def test_dono_que_nao_se_sabe_nao_deixa_o_outro_confirmar(self):
        w = self.w
        self.two_owner_world()
        w.loaded("com.test.a", pid=w.next_pid(), start=T0 + 6 * D)
        w.loaded("com.test.b", pid=w.next_pid(), start=T0 + 6 * D)
        open(os.path.join(w.fake, "launchctl", "com.test.b.fail"), "w").close()
        w.run()
        self.verdict("ga-ddd444", NCS)

    def test_dono_sem_reinicio_e_outro_que_nao_se_sabe_fica_ainda_nao_visto(self):
        w = self.w
        self.two_owner_world()
        w.loaded("com.test.a", pid=w.next_pid(), start=T0 + 4 * D)         # a NÃO reiniciou: isso eu sei, com certeza
        w.loaded("com.test.b", pid=w.next_pid(), start=T0 + 6 * D)
        open(os.path.join(w.fake, "launchctl", "com.test.b.fail"), "w").close()   # b eu não consegui ler
        r = w.run()
        b = w.state_of("ga-ddd444")
        self.assertEqual(b["state"], AINDA, b)                             # o que se sabe (a) não some por causa do que não se sabe (b)
        self.assertEqual(b["owner_states"]["com.test.b"], [NCS, "launchctl-read-failed"], b)   # e a falha de b continua visível
        self.assertEqual(r.returncode, 3, r.stderr)                         # ... e conta no rc (o veredito AINDA não a esconde)

    def test_daemon_que_nao_e_keepalive_nao_da_pra_saber_nesta_fatia(self):
        w = self.w
        self.daemon_world(keepalive=False)                                  # plist sem KeepAlive (periódico / por evento)
        w.loaded("com.test.svc")
        w.run()
        self.verdict("ga-aaa111", NCS, "not-keepalive")   # nunca CONFIRMADO só porque carregou

    def test_sha_no_close_reason_mas_bead_sem_closed_at_nao_e_no_merge_sha(self):
        w = self.w
        sha = self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        w.bead("ga-lll333", close_reason="PASSED (sha=%s)" % sha, closed_at=None)   # sabe o sha, não sabe QUANDO
        r = w.run()
        self.verdict("ga-lll333", NCS, "bad-timestamp")       # ≠ no-merge-sha ("não há sha")
        self.assertNotEqual(r.returncode, 0)                                        # leitura que faltou conta como falha

    def test_commit_anterior_do_mesmo_bead_tambem_conta_para_os_donos(self):
        w = self.w
        w.commit({"bin/a.sh": "a1\n", "bin/b.sh": "b1\n"}, "feat: a e b")
        w.commit({"bin/b.sh": "b2\n"}, "fix(ga-fff666): parte 1 (b)")
        tip = w.commit({"bin/a.sh": "a2\n"}, "fix(ga-fff666): parte 2 (a)")     # o sha do merge é só a PONTA
        w.plist("com.test.a", "bin/a.sh", KeepAlive=True)
        w.plist("com.test.b", "bin/b.sh", KeepAlive=True)
        w.loaded("com.test.a", pid=w.next_pid(), start=T0 + 6 * D)             # dono da ponta reiniciou
        w.loaded("com.test.b", pid=w.next_pid(), start=T0 + 4 * D)             # dono do commit anterior NÃO
        w.bead("ga-fff666", close_reason="PASSED (sha=%s)" % tip, closed_at=T0 + 5 * D)
        w.run()
        b = w.state_of("ga-fff666")
        self.assertEqual(b["state"], AINDA, "só a ponta do ff foi vista: falso CONFIRMADO — %s" % (b,))
        self.assertIn("com.test.b", b["owners"])

    def test_commit_de_outro_bead_nao_da_dono_ao_bead(self):
        w = self.w                              # só o ASSUNTO que cita o id inteiro vale: corpo, prefixo e filho não
        w.commit({"bin/a.sh": "1\n", "bin/b.sh": "1\n", "bin/c.sh": "1\n"}, "feat: a, b e c")
        w.commit({"bin/a.sh": "2\n"}, "fix(ga-nnn50): irmão de prefixo")
        w.commit({"bin/b.sh": "2\n"}, "fix(ga-nnn5.2): filho")
        w.commit({"bin/c.sh": "2\n"}, "fix(ga-zzz9): outro\n\nver ga-nnn5, que mexeu em outra coisa")
        sha = w.commit({"docs/n.md": "doc\n"}, "docs(ga-nnn5): notas")
        for x in "abc":
            w.plist("com.test." + x, "bin/%s.sh" % x, KeepAlive=True)
            w.loaded("com.test." + x, pid=w.next_pid(), start=T0 + 9 * D)   # todos subiram DEPOIS: vazar um dono daria CONFIRMADO
        w.bead("ga-nnn5", close_reason="PASSED (sha=%s)" % sha, closed_at=T0 + 5 * D)
        w.run()
        self.verdict("ga-nnn5", NCS, "no-daemon")

    def test_arquivo_com_acento_no_nome_acha_o_dono(self):
        w = self.w
        w.commit({"bin/café.sh": "v1\n"}, "feat: café")
        sha = w.commit({"bin/café.sh": "v2\n"}, "fix(ga-ccc333): café v2")
        w.plist("com.test.cafe", "bin/café.sh", KeepAlive=True)
        w.loaded("com.test.cafe", pid=w.next_pid(), start=T0 + 4 * D)      # subiu ANTES do merge
        w.bead("ga-ccc333", close_reason="PASSED (sha=%s)" % sha, closed_at=T0 + 5 * D)
        w.run()
        self.verdict("ga-ccc333", AINDA)                                   # sem -z o git cita "caf\303\251.sh" e o dono se perdia

    def test_closed_at_ilegivel_vira_nao_consegui_saber_e_os_outros_beads_seguem(self):
        w = self.w
        sha = self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        w.bead("ga-jjj000", close_reason="PASSED (sha=%s)" % sha, closed_at=T0 + 5 * D)
        w.beads["hq"][-1]["closed_at"] = "ontem à tarde"
        r = w.run()
        self.verdict("ga-jjj000", NCS, "bad-timestamp")
        self.assertEqual(w.state_of("ga-aaa111")["state"], CONFIRMADO)          # o vizinho não foi perdido
        self.assertNotEqual(r.returncode, 0)

    def test_plist_que_o_expat_recusa_mas_o_plutil_le_nao_vira_ilegivel(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        with open(os.path.join(w.la, "com.test.comentario.plist"), "w") as f:   # `--` em comentário XML: launchd e plutil leem, o expat não
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>Label</key>'
                    '<string>com.test.comentario</string><!-- roda com --dry-run --></dict></plist>\n')
        r = w.run()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(w.state_of("ga-aaa111")["state"], CONFIRMADO)          # sem o plutil: NCS plist-read-failed
        self.assertEqual(w.report()["plists"]["via_plutil"], ["com.test.comentario.plist"])

    def test_plist_lido_mas_sem_label_nao_e_ilegivel_nem_dono(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        with open(os.path.join(w.la, "com.test.vazio.plist"), "wb") as f:     # `<dict/>`: lê, mas o launchd não o carrega
            plistlib.dump({}, f)
        r = w.run()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(w.state_of("ga-aaa111")["state"], CONFIRMADO)
        p = w.report()["plists"]
        self.assertEqual((p["no_label"], p["unreadable"]), (["com.test.vazio.plist"], []))

    def test_plist_ilegivel_nao_deixa_dizer_que_nao_ha_daemon(self):
        w = self.w
        w.commit({"bin/svc.sh": "echo v1\n"}, "feat: svc")
        sha = w.commit({"docs/notas.md": "só doc\n"}, "docs(ga-kkk111): notas")
        w.plist("com.test.svc", "bin/svc.sh", KeepAlive=True)
        with open(os.path.join(w.la, "com.test.quebrado.plist"), "w") as f:
            f.write("isto não é um plist")
        w.bead("ga-kkk111", close_reason="PASSED (sha=%s)" % sha, closed_at=T0 + 5 * D)
        r = w.run()
        self.verdict("ga-kkk111", NCS, "plist-read-failed")   # ≠ no-daemon
        self.assertNotEqual(r.returncode, 0)

    def test_launchagents_que_nao_le_nao_vira_nenhum_daemon(self):
        w = self.w
        self.daemon_world()
        shutil.rmtree(w.la)                                                 # vazio ≠ falhou: sem plists não dá pra dizer "no-daemon"
        r = w.run()
        self.verdict("ga-aaa111", NCS, "plist-read-failed")
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertLessEqual({"unreadable", "no_label", "via_plutil"}, set(w.report()["plists"]))   # mantém as chaves (a .3 lê)
        w.beads["hq"].clear()                                               # ... e sem bead nenhum pra julgar a falha também conta
        self.assertEqual(w.run().returncode, 3)

    def test_label_duplicado_em_dois_plists_nao_deixa_um_deles_calado(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        shutil.copy(os.path.join(w.la, "com.test.svc.plist"), os.path.join(w.la, "copia.plist"))   # mesmo Label, outro arquivo
        w.run()
        self.verdict("ga-aaa111", NCS, "duplicate-label")                   # o launchd carrega UM deles; qual, não sei

    def test_loja_ilegivel_falha_alto_e_nao_vira_zero(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        w.fail("rig")                                                     # a listagem da loja do rig quebra sempre
        r = w.run()
        self.assertEqual(r.returncode, 3, r.stderr)
        stores = w.report()["stores"]
        self.assertTrue(stores["hq"]["ok"])
        self.assertFalse(stores["rig"]["ok"])
        self.assertIn("rig", r.stderr)
        self.assertEqual(w.state_of("ga-aaa111")["state"], CONFIRMADO)          # a outra loja segue

    def stale_world(self, n=1, first=1):
        """n beads AINDA NÃO VISTO (mesmo daemon, subiu antes do merge)."""
        w = self.w
        sha = self.daemon_world()
        w.beads["hq"].clear()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 4 * D)
        for i in range(first, first + n):
            w.bead("ga-stale%02d" % i, close_reason="PASSED (sha=%s)" % sha, closed_at=T0 + 5 * D)
        return sha

    def test_stdout_resume_as_contagens_por_estado_e_aponta_o_json(self):
        w = self.w
        self.stale_world(n=2)
        r = w.run()
        self.assertRegex(r.stdout, r"CONFIRMADO=0 · AINDA NÃO VISTO=2 · NÃO CONSEGUI SABER=0")
        self.assertIn("daemon-unverified-sweep-latest.json", r.stdout)
        self.assertEqual(w.report()["generated_at"], time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(T0 + 10 * D)))
        self.assertEqual(os.listdir(w.out), ["daemon-unverified-sweep-latest.json"])   # escrita atômica: nenhum .tmp sobra

    def test_loja_com_mais_de_50_beads_nao_e_cortada(self):
        w = self.w
        self.stale_world(n=51)                                              # o bd corta em 50 sem `--limit 0` (ga-21kmp)
        w.run()
        self.assertEqual(w.report()["counts"][AINDA], 51)

    def test_bead_sem_status_nao_vira_fora_de_escopo_nem_confirmado(self):
        w = self.w
        w.bead("ga-mmm444", status=None, closed_at=None)                    # a leitura não trouxe o status: não sei se fechou
        r = w.run()
        self.verdict("ga-mmm444", NCS, "status-unknown")   # ≠ "não fechado" (FORA DE ESCOPO)
        self.assertNotEqual(r.returncode, 0)

    def test_bead_nao_fechado_fica_fora_de_escopo_e_nao_conta_nos_tres_estados(self):
        w = self.w
        w.bead("ga-hhh888", status="open", closed_at=None)
        w.run()
        self.verdict("ga-hhh888", OUT)
        counts = w.report()["counts"]
        self.assertEqual((counts[CONFIRMADO], counts[AINDA], counts[NCS], counts[OUT]), (0, 0, 0, 1))


if __name__ == "__main__":
    unittest.main(verbosity=2)
