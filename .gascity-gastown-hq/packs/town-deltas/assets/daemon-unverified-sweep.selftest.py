#!/usr/bin/env python3
"""daemon-unverified-sweep.selftest.py — selftest do vigia semanal de delivery:daemon-unverified (ga-iyfe83).

Roda o vigia DE VERDADE (subprocess) contra um mundo falso mas fiel:
  - um repo git real, em tmpdir (sha, diff-tree e is-ancestor são do git, não de mock);
  - `bd`, `launchctl`, `ps` e `notify` falsos, em tmpdir, que gravam cada chamada;
  - um LaunchAgents falso com plists de verdade (plistlib).

O que este arquivo protege é a regra de TRÊS estados que nunca colapsam:
  CONFIRMADO · AINDA NÃO VISTO · NÃO CONSEGUI SABER
e, acima de tudo, que "leitura falhou" NUNCA vira CONFIRMADO.

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
key = None
for l in labels:
    if l.startswith("source-bead:"):
        key = ("markers", l.split(":", 1)[1])
if key is None and "delivery:daemon-unverified" in labels:
    key = ("stores", "du")
if key is None:
    sys.stderr.write("fake bd: consulta inesperada %%r\n" %% (labels,)); sys.exit(2)
tag = key[1]
# falha injetada: sempre (fail/<store>__<tag>) ou as N primeiras chamadas (flaky/<store>__<tag>)
failp = os.path.join(fake, "fail", store + "__" + tag)
if os.path.exists(failp):
    sys.stderr.write("[mysql] i/o timeout\nError: search count issues: invalid connection\n"); sys.exit(1)
flakyp = os.path.join(fake, "flaky", store + "__" + tag)
if os.path.exists(flakyp):
    n = int(open(flakyp).read().strip() or "0")
    if n > 0:
        open(flakyp, "w").write(str(n - 1))
        sys.stderr.write("Error: invalid connection\n"); sys.exit(1)
datap = os.path.join(fake, key[0], store + "__" + tag + ".json")
print(open(datap).read() if os.path.exists(datap) else "[]")
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

FAKE_NOTIFY = r'''#!%(py)s
import os, sys
fake = os.environ["DUS_FAKE_DIR"]
with open(os.path.join(fake, "notify.calls"), "a") as f:
    f.write("\x1f".join(sys.argv[1:]) + "\n")
if os.path.exists(os.path.join(fake, "notify.fail")):
    sys.stderr.write("notify: ntfy fora do ar\n"); sys.exit(1)
'''


def _exe(path, body):
    with open(path, "w") as f:
        f.write(body % {"py": sys.executable})
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)


class World:
    """Um mundo falso mas fiel: repo git real + bd/launchctl/ps/notify falsos."""

    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="dus-selftest-")
        self.fake = os.path.join(self.tmp, "fake")
        for sub in ("stores", "markers", "launchctl", "ps", "fail", "flaky"):
            os.makedirs(os.path.join(self.fake, sub))
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        _exe(os.path.join(self.bin, "bd"), FAKE_BD)
        _exe(os.path.join(self.bin, "launchctl"), FAKE_LAUNCHCTL)
        _exe(os.path.join(self.bin, "ps"), FAKE_PS)
        _exe(os.path.join(self.bin, "notify"), FAKE_NOTIFY)
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

    # ---- git -------------------------------------------------------------
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

    # ---- launchd ---------------------------------------------------------
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

    # ---- bd --------------------------------------------------------------
    def bead(self, bid, rig="hq", close_reason="", closed_at=T0, status="closed", title=None):
        self.beads[rig].append({
            "id": bid, "title": title or ("bead " + bid), "status": status,
            "closed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(closed_at)) if closed_at else None,
            "close_reason": close_reason,
            "labels": ["delivery:daemon-unverified"],
        })

    def marker(self, bid, sha, closed_at, store="hq"):
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(closed_at))
        body = [{"id": "m-" + bid, "status": "closed", "closed_at": ts,
                 "close_reason": "Gate marker terminal: PASSED (branch x merged sha=%s). Closed by dispatcher (ga-jhyu)." % sha,
                 "labels": ["gate-status:passed", "source-bead:" + bid, "type:quality-gate-marker"]}]
        with open(os.path.join(self.fake, "markers", "%s__%s.json" % (os.path.basename(getattr(self, store + "_store")), bid)), "w") as f:
            json.dump(body, f)

    def fail(self, store, tag):
        open(os.path.join(self.fake, "fail", "%s__%s" % (os.path.basename(getattr(self, store + "_store")), tag)), "w").close()

    def flaky(self, store, tag, n):
        with open(os.path.join(self.fake, "flaky", "%s__%s" % (os.path.basename(getattr(self, store + "_store")), tag)), "w") as f:
            f.write(str(n))

    # ---- execução --------------------------------------------------------
    def run(self, *flags, now=T0 + 10 * D, extra_env=None):
        for key, store in (("hq", self.hq_store), ("rig", self.rig_store)):
            with open(os.path.join(self.fake, "stores", os.path.basename(store) + "__du.json"), "w") as f:
                json.dump(self.beads[key], f)
        env = dict(os.environ)
        env.update({
            "DUS_FAKE_DIR": self.fake, "DUS_BD": os.path.join(self.bin, "bd"),
            "DUS_LAUNCHCTL": os.path.join(self.bin, "launchctl"), "DUS_PS": os.path.join(self.bin, "ps"),
            "DUS_NOTIFY": os.path.join(self.bin, "notify"), "DUS_LAUNCH_AGENTS_DIR": self.la,
            "DUS_OUT_DIR": self.out, "DUS_NOW": str(now), "DUS_RETRY_SLEEP": "0", "DUS_RETRIES": "3",
            "DUS_HQ_STORE": self.hq_store,
            "DUS_STORES": "hq|%s|%s;rig|%s|%s" % (self.hq_store, self.repo, self.rig_store, self.repo),
        })
        env.update(self.env_extra)
        env.update(extra_env or {})
        r = subprocess.run([sys.executable, SWEEP, *flags], capture_output=True, text=True, env=env, timeout=120)
        self.last = r
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

    def daemon_world(self, keepalive=True, merge_at=T0 + 5 * D):
        """Um daemon KeepAlive 'svc' dono de bin/svc.sh, e uma entrega mergeada em `merge_at`."""
        w = self.w
        w.commit({"bin/svc.sh": "echo v1\n"}, "feat: svc v1")
        sha = w.commit({"bin/svc.sh": "echo v2\n"}, "fix(ga-aaa111): svc v2")
        w.plist("com.test.svc", "bin/svc.sh", **({"KeepAlive": True} if keepalive else {}))
        w.bead("ga-aaa111", close_reason="Quality gate PASSED — merged (sha=%s, gate_run=ga-r1). Closed." % sha, closed_at=merge_at)
        return sha

    # ---- os três estados -------------------------------------------------
    def test_confirmado_quando_o_daemon_subiu_depois_do_merge(self):
        w = self.w
        self.daemon_world(merge_at=T0 + 5 * D)
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 6 * D)       # subiu 1 dia DEPOIS do merge
        r = w.run()
        self.assertEqual(r.returncode, 0, r.stderr)
        b = w.state_of("ga-aaa111")
        self.assertEqual(b["state"], CONFIRMADO, b)
        self.assertEqual(w.report()["counts"][CONFIRMADO], 1)

    def test_ainda_nao_visto_quando_o_daemon_subiu_antes_do_merge(self):
        w = self.w
        self.daemon_world(merge_at=T0 + 5 * D)
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 4 * D)       # subiu 1 dia ANTES do merge
        w.run()
        b = w.state_of("ga-aaa111")
        self.assertEqual(b["state"], AINDA, b)

    def test_ainda_nao_visto_quando_o_daemon_nao_esta_carregado(self):
        w = self.w
        self.daemon_world()                                                # plist existe; launchctl não acha o serviço
        w.run()
        b = w.state_of("ga-aaa111")
        self.assertEqual(b["state"], AINDA, b)
        self.assertEqual(b["reason"], "not-loaded", b)

    def test_ainda_nao_visto_quando_daemon_keepalive_carregado_sem_processo(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc")                                           # carregado, mas sem PID
        w.run()
        b = w.state_of("ga-aaa111")
        self.assertEqual(b["state"], AINDA, b)
        self.assertEqual(b["reason"], "loaded-no-pid", b)

    # ---- NÃO CONSEGUI SABER: o que não dá pra afirmar --------------------
    def test_ncs_quando_nao_ha_sha_de_merge_em_lugar_nenhum(self):
        w = self.w
        self.daemon_world()
        w.beads["hq"][0]["close_reason"] = "Story DELIVERED — story:done. DAEMON LIVENESS NOT VERIFIED"
        w.run()
        b = w.state_of("ga-aaa111")
        self.assertEqual(b["state"], NCS, b)
        self.assertEqual(b["reason"], "no-merge-sha", b)

    def test_ncs_quando_nenhum_daemon_e_dono_do_codigo_mergeado(self):
        w = self.w
        w.commit({"bin/svc.sh": "echo v1\n"}, "feat: svc")
        sha = w.commit({"docs/notas.md": "só doc\n"}, "docs(ga-bbb222): notas")
        w.plist("com.test.svc", "bin/svc.sh", KeepAlive=True)
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        w.bead("ga-bbb222", close_reason="PASSED (sha=%s)" % sha, closed_at=T0 + 5 * D)
        w.run()
        b = w.state_of("ga-bbb222")
        self.assertEqual(b["state"], NCS, b)
        self.assertEqual(b["reason"], "no-daemon", b)

    def test_ncs_quando_o_sha_nao_esta_no_disco(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        w.beads["hq"][0]["close_reason"] = "PASSED (sha=%s)" % ("ab" * 20)
        w.run()
        b = w.state_of("ga-aaa111")
        self.assertEqual(b["state"], NCS, b)
        self.assertEqual(b["reason"], "sha-not-on-disk", b)

    # ---- "leitura falhou" NUNCA vira CONFIRMADO --------------------------
    def test_leitura_do_marcador_falhou_nao_vira_confirmado(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)       # o daemon estaria CONFIRMADO se lêssemos o sha
        w.beads["hq"][0]["close_reason"] = "Story DELIVERED — story:done"   # sha só existe no marcador
        w.fail("hq", "ga-aaa111")                                           # e a leitura do marcador falha SEMPRE
        r = w.run()
        b = w.state_of("ga-aaa111")
        self.assertEqual(b["state"], NCS, b)
        self.assertEqual(b["reason"], "marker-read-failed", b)             # ≠ no-merge-sha: erro NÃO é vazio
        self.assertNotEqual(b["state"], CONFIRMADO)
        self.assertGreaterEqual(len([c for c in w.calls("bd") if "source-bead:ga-aaa111" in c]), 2,
                                "leitura falha tem que ser re-tentada antes de desistir")
        self.assertNotEqual(r.returncode, 0, "leitura incompleta tem que falhar ALTO (rc != 0)")

    def test_leitura_do_marcador_que_falha_so_uma_vez_e_recuperada_pelo_retry(self):
        w = self.w
        sha = self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        w.beads["hq"][0]["close_reason"] = "Story DELIVERED — story:done"
        w.marker("ga-aaa111", sha, closed_at=T0 + 5 * D)
        w.flaky("hq", "ga-aaa111", 1)
        r = w.run()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(w.state_of("ga-aaa111")["state"], CONFIRMADO)

    def test_leitura_do_launchctl_falhou_nao_vira_confirmado(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        open(os.path.join(w.fake, "launchctl", "com.test.svc.fail"), "w").close()
        r = w.run()
        b = w.state_of("ga-aaa111")
        self.assertEqual(b["state"], NCS, b)
        self.assertEqual(b["reason"], "launchctl-read-failed", b)          # ≠ not-loaded: erro NÃO é "não carregado"
        self.assertNotEqual(r.returncode, 0)

    def test_leitura_do_ps_falhou_nao_vira_confirmado(self):
        w = self.w
        self.daemon_world()
        pid = w.next_pid()
        w.loaded("com.test.svc", pid=pid)                                  # tem PID, mas o ps não responde
        r = w.run()
        b = w.state_of("ga-aaa111")
        self.assertEqual(b["state"], NCS, b)
        self.assertEqual(b["reason"], "ps-read-failed", b)
        self.assertNotEqual(r.returncode, 0)

    def test_repo_git_quebrado_nao_vira_sha_fora_do_disco_nem_confirmado(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)       # sem a falha seria CONFIRMADO
        with open(os.path.join(w.repo, ".git", "HEAD"), "w") as f:         # o git responde 128 pra QUALQUER pergunta
            f.write("garbage\n")
        r = w.run()
        b = w.state_of("ga-aaa111")
        self.assertEqual(b["state"], NCS, b)
        self.assertEqual(b["reason"], "git-read-failed", b)                # ≠ sha-not-on-disk: git quebrado NÃO é "sha ausente"
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
        b = w.state_of("ga-aaa111")
        self.assertEqual(b["state"], NCS, b)
        self.assertEqual(b["reason"], "git-read-failed", b)
        self.assertNotEqual(r.returncode, 0)

    # ---- vários donos: precedência AINDA > NCS > CONFIRMADO ---------------
    def two_owner_world(self):
        w = self.w
        w.commit({"bin/a.sh": "a1\n", "bin/b.sh": "b1\n"}, "feat: a e b")
        sha = w.commit({"bin/a.sh": "a2\n", "bin/b.sh": "b2\n"}, "fix(ga-ddd444): a e b")
        w.plist("com.test.a", "bin/a.sh", KeepAlive=True)
        w.plist("com.test.b", "bin/b.sh", KeepAlive=True)
        w.bead("ga-ddd444", close_reason="PASSED (sha=%s)" % sha, closed_at=T0 + 5 * D)

    def test_um_dono_sem_reinicio_basta_para_ainda_nao_visto(self):
        w = self.w
        self.two_owner_world()
        w.loaded("com.test.a", pid=w.next_pid(), start=T0 + 6 * D)         # a reiniciou
        w.loaded("com.test.b", pid=w.next_pid(), start=T0 + 4 * D)         # b NÃO
        w.run()
        b = w.state_of("ga-ddd444")
        self.assertEqual(b["state"], AINDA, b)
        self.assertEqual(sorted(b["owners"]), ["com.test.a", "com.test.b"])

    def test_dono_que_nao_se_sabe_nao_deixa_o_outro_confirmar(self):
        w = self.w
        self.two_owner_world()
        w.loaded("com.test.a", pid=w.next_pid(), start=T0 + 6 * D)
        w.loaded("com.test.b", pid=w.next_pid(), start=T0 + 6 * D)
        open(os.path.join(w.fake, "launchctl", "com.test.b.fail"), "w").close()
        w.run()
        b = w.state_of("ga-ddd444")
        self.assertEqual(b["state"], NCS, b)

    def test_dono_sem_reinicio_e_outro_que_nao_se_sabe_fica_ainda_nao_visto(self):
        w = self.w
        self.two_owner_world()
        w.loaded("com.test.a", pid=w.next_pid(), start=T0 + 4 * D)         # a NÃO reiniciou: isso eu sei, com certeza
        w.loaded("com.test.b", pid=w.next_pid(), start=T0 + 6 * D)
        open(os.path.join(w.fake, "launchctl", "com.test.b.fail"), "w").close()   # b eu não consegui ler
        w.run()
        b = w.state_of("ga-ddd444")
        self.assertEqual(b["state"], AINDA, b)                             # o que se sabe (a) não some por causa do que não se sabe (b)
        self.assertEqual(b["owner_states"]["com.test.b"], [NCS, "launchctl-read-failed"], b)   # e a falha de b continua visível

    def test_confirmado_exige_todos_os_donos_confirmados(self):
        w = self.w
        self.two_owner_world()
        w.loaded("com.test.a", pid=w.next_pid(), start=T0 + 6 * D)
        w.loaded("com.test.b", pid=w.next_pid(), start=T0 + 6 * D)
        w.run()
        self.assertEqual(w.state_of("ga-ddd444")["state"], CONFIRMADO)

    # ---- daemons periódicos: cada execução é um processo novo --------------
    def periodic_world(self, merge_at, **plist_keys):
        w = self.w
        w.commit({"bin/job.sh": "j1\n"}, "feat: job")
        sha = w.commit({"bin/job.sh": "j2\n"}, "fix(ga-eee555): job")
        w.plist("com.test.job", "bin/job.sh", **plist_keys)
        w.bead("ga-eee555", close_reason="PASSED (sha=%s)" % sha, closed_at=merge_at)

    def test_periodico_com_um_ciclo_inteiro_depois_do_merge_e_confirmado(self):
        w = self.w
        self.periodic_world(T0 + 5 * D, StartInterval=3600)                # now = T0+10D: 5 dias de ciclos de 1h
        w.loaded("com.test.job")
        w.run()
        b = w.state_of("ga-eee555")
        self.assertEqual((b["state"], b["reason"]), (CONFIRMADO, "period-elapsed"), b)

    def test_periodico_cujo_ciclo_ainda_nao_passou_e_ainda_nao_visto(self):
        w = self.w
        self.periodic_world(T0 + 10 * D - 3600, StartInterval=7 * D)       # merge há 1h; ciclo de 7 dias
        w.loaded("com.test.job")
        w.run()
        b = w.state_of("ga-eee555")
        self.assertEqual((b["state"], b["reason"]), (AINDA, "period-not-elapsed"), b)

    def test_periodico_calendario_diario_com_merge_ha_dois_dias_e_confirmado(self):
        w = self.w
        self.periodic_world(T0 + 8 * D, StartCalendarInterval={"Hour": 3, "Minute": 0})
        w.loaded("com.test.job")
        w.run()
        self.assertEqual(w.state_of("ga-eee555")["state"], CONFIRMADO)

    def test_periodico_calendario_semanal_com_merge_ha_tres_dias_e_ainda_nao_visto(self):
        w = self.w
        self.periodic_world(T0 + 7 * D, StartCalendarInterval={"Weekday": 1, "Hour": 3, "Minute": 0})
        w.loaded("com.test.job")
        w.run()
        b = w.state_of("ga-eee555")
        self.assertEqual((b["state"], b["reason"]), (AINDA, "period-not-elapsed"), b)

    def test_periodico_nao_carregado_e_ainda_nao_visto(self):
        w = self.w
        self.periodic_world(T0 + 5 * D, StartInterval=3600)                # plist existe, launchd não carregou
        w.run()
        b = w.state_of("ga-eee555")
        self.assertEqual((b["state"], b["reason"]), (AINDA, "not-loaded"), b)

    def test_daemon_acionado_por_evento_nao_da_pra_saber(self):
        w = self.w
        self.periodic_world(T0 + 5 * D, WatchPaths=["/tmp/x"])
        w.loaded("com.test.job")
        w.run()
        b = w.state_of("ga-eee555")
        self.assertEqual((b["state"], b["reason"]), (NCS, "event-driven"), b)

    def test_plist_sem_gatilho_conhecido_nao_da_pra_saber(self):
        w = self.w
        self.periodic_world(T0 + 5 * D, RunAtLoad=True)
        w.loaded("com.test.job")
        w.run()
        b = w.state_of("ga-eee555")
        self.assertEqual((b["state"], b["reason"]), (NCS, "unknown-kind"), b)

    # ---- entrega em fast-forward com vários commits -------------------------
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

    # ---- onde mora o sha ------------------------------------------------------
    def test_bead_de_rig_acha_o_sha_no_marcador_da_loja_hq(self):
        w = self.w
        sha = self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        w.beads["rig"].append(w.beads["hq"].pop())                             # o bead é da loja do rig…
        w.beads["rig"][0]["id"] = "wa-ggg777"
        w.beads["rig"][0]["close_reason"] = "Story DELIVERED — story:done"
        w.marker("wa-ggg777", sha, closed_at=T0 + 5 * D, store="hq")           # …mas o marcador mora na loja HQ
        w.run()
        b = w.state_of("wa-ggg777")
        self.assertEqual(b["state"], CONFIRMADO, b)
        self.assertEqual(b["rig"], "rig")

    def test_sha_no_close_reason_dispensa_a_consulta_de_marcador(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        w.run()
        self.assertEqual([c for c in w.calls("bd") if "source-bead" in c], [])

    # ---- WA: o closure de deploy_deps.json liga uma lib ao daemon que a importa -----
    def deps_world(self, plist_for_x=True):
        w = self.w
        w.commit({"daemons/x.py": "x1\n", "lib/util.py": "u1\n",
                  "daemons/deploy_deps.json": json.dumps({"daemons": {"daemons/x.py": {
                      "label": "com.test.x", "closure": ["daemons/x.py", "lib/util.py"], "assets": ["tpl/x.html"]}}})}, "feat: x")
        sha = w.commit({"lib/util.py": "u2\n"}, "fix(ga-iii999): util")          # só a LIB mudou, o .py do daemon não
        if plist_for_x:
            w.plist("com.test.x", "daemons/x.py", KeepAlive=True)
        w.bead("ga-iii999", close_reason="PASSED (sha=%s)" % sha, closed_at=T0 + 5 * D)

    def test_lib_mudada_pertence_ao_daemon_que_a_importa_pelo_closure(self):
        w = self.w
        self.deps_world()
        w.loaded("com.test.x", pid=w.next_pid(), start=T0 + 4 * D)
        w.run()
        b = w.state_of("ga-iii999")
        self.assertEqual((b["state"], b["owners"]), (AINDA, ["com.test.x"]), b)

    def test_daemon_do_closure_sem_plist_nao_e_dono(self):
        w = self.w
        self.deps_world(plist_for_x=False)                                      # não existe plist → não roda nesta máquina
        w.run()
        b = w.state_of("ga-iii999")
        self.assertEqual((b["state"], b["reason"]), (NCS, "no-daemon"), b)

    def test_deploy_deps_ilegivel_nao_vira_nenhum_daemon(self):
        w = self.w
        self.deps_world()
        w.loaded("com.test.x", pid=w.next_pid(), start=T0 + 9 * D)
        with open(os.path.join(w.repo, "daemons", "deploy_deps.json"), "w") as f:
            f.write("{ isto não é json")
        r = w.run()
        b = w.state_of("ga-iii999")
        self.assertEqual((b["state"], b["reason"]), (NCS, "deps-read-failed"), b)
        self.assertEqual(r.returncode, 3)

    # ---- robustez: um bead estranho nunca derruba a varredura nem vira CONFIRMADO ----
    def test_closed_at_ilegivel_vira_nao_consegui_saber_e_os_outros_beads_seguem(self):
        w = self.w
        sha = self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        w.bead("ga-jjj000", close_reason="PASSED (sha=%s)" % sha, closed_at=T0 + 5 * D)
        w.beads["hq"][-1]["closed_at"] = "ontem à tarde"
        r = w.run()
        bad = w.state_of("ga-jjj000")
        self.assertEqual((bad["state"], bad["reason"]), (NCS, "bad-timestamp"), bad)
        self.assertEqual(w.state_of("ga-aaa111")["state"], CONFIRMADO)          # o vizinho não foi perdido
        self.assertNotEqual(r.returncode, 0)

    def test_plist_ilegivel_nao_deixa_dizer_que_nao_ha_daemon(self):
        w = self.w
        w.commit({"bin/svc.sh": "echo v1\n"}, "feat: svc")
        sha = w.commit({"docs/notas.md": "só doc\n"}, "docs(ga-kkk111): notas")
        w.plist("com.test.svc", "bin/svc.sh", KeepAlive=True)
        with open(os.path.join(w.la, "com.test.quebrado.plist"), "w") as f:
            f.write("isto não é um plist")
        w.bead("ga-kkk111", close_reason="PASSED (sha=%s)" % sha, closed_at=T0 + 5 * D)
        r = w.run()
        b = w.state_of("ga-kkk111")
        self.assertEqual((b["state"], b["reason"]), (NCS, "plist-read-failed"), b)   # ≠ no-daemon
        self.assertNotEqual(r.returncode, 0)

    def test_loja_ilegivel_falha_alto_e_nao_vira_zero(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        w.fail("rig", "du")                                                     # a listagem da loja do rig quebra sempre
        r = w.run()
        self.assertEqual(r.returncode, 3, r.stderr)
        stores = w.report()["stores"]
        self.assertTrue(stores["hq"]["ok"])
        self.assertFalse(stores["rig"]["ok"])
        self.assertIn("rig", r.stderr)
        self.assertEqual(w.state_of("ga-aaa111")["state"], CONFIRMADO)          # a outra loja segue

    def test_prazo_estourado_marca_o_resto_como_nao_consegui_saber_e_nao_o_descarta(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        r = w.run(extra_env={"DUS_DEADLINE": "0"})
        b = w.state_of("ga-aaa111")
        self.assertEqual((b["state"], b["reason"]), (NCS, "deadline-exceeded"), b)
        self.assertEqual(r.returncode, 3)

    def test_nunca_reinicia_nada_so_le_o_launchd(self):
        w = self.w
        self.two_owner_world()
        w.loaded("com.test.a", pid=w.next_pid(), start=T0 + 4 * D)
        w.loaded("com.test.b", pid=w.next_pid(), start=T0 + 4 * D)
        w.run("--notify")
        calls = w.calls("launchctl")
        self.assertTrue(calls)
        self.assertTrue(all(c.startswith("list ") for c in calls), calls)       # nada de kickstart/bootout/unload/kill

    # ---- relatório -------------------------------------------------------------
    def stale_world(self, n=1, first=1):
        """n beads AINDA NÃO VISTO (mesmo daemon, subiu antes do merge)."""
        w = self.w
        sha = self.daemon_world()
        w.beads["hq"].clear()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 4 * D)
        for i in range(first, first + n):
            w.bead("ga-stale%02d" % i, close_reason="PASSED (sha=%s)" % sha, closed_at=T0 + 5 * D)
        return sha

    def md(self):
        files = [f for f in os.listdir(self.w.out) if f.startswith("daemon-unverified-sweep-") and f.endswith(".md")]
        self.assertEqual(len(files), 1, files)
        with open(os.path.join(self.w.out, files[0])) as f:
            return f.read()

    def test_relatorio_markdown_traz_contagens_por_estado_e_por_daemon(self):
        w = self.w
        self.stale_world(n=3)
        w.run()
        text = self.md()
        self.assertIn("AINDA NÃO VISTO: 3", text)
        self.assertIn("CONFIRMADO: 0", text)
        self.assertIn("NÃO CONSEGUI SABER: 0", text)
        self.assertIn("com.test.svc", text)                       # o que o Mayor precisa pra decidir o reinício: POR DAEMON
        for i in (1, 2, 3):
            self.assertIn("ga-stale%02d" % i, text)
        roll = w.report()["daemons"]["com.test.svc"]
        self.assertEqual((roll["ainda"], sorted(roll["beads"])), (3, ["ga-stale01", "ga-stale02", "ga-stale03"]))

    # ---- notificação: UMA, só pro que é NOVO -----------------------------------
    def notified_msgs(self):
        return [c.split("\x1f")[-1] for c in self.w.calls("notify")]

    def state(self):
        with open(os.path.join(self.w.out, "daemon-unverified-sweep.state.json")) as f:
            return json.load(f)

    def test_primeira_rodada_avisa_uma_vez_e_grava_o_baseline(self):
        w = self.w
        self.stale_world(n=12)
        r = w.run("--notify")
        self.assertEqual(r.returncode, 0, r.stderr)
        msgs = self.notified_msgs()
        self.assertEqual(len(msgs), 1, "UMA notificação, não uma por bead")
        self.assertIn("12", msgs[0])
        self.assertLess(len(msgs[0]), 1000, "o resumo não lista os 300 — aponta pro relatório")
        self.assertIn("daemon-unverified-sweep", msgs[0])
        self.assertEqual(sorted(self.state()["notified"]), ["ga-stale%02d" % i for i in range(1, 13)])

    def test_segunda_rodada_sem_novidade_fica_calada(self):
        w = self.w
        self.stale_world(n=2)
        w.run("--notify")
        w.run("--notify")
        self.assertEqual(len(self.notified_msgs()), 1)

    def test_so_o_novo_ainda_nao_visto_dispara_novo_aviso(self):
        w = self.w
        sha = self.stale_world(n=2)
        w.run("--notify")
        w.bead("ga-stale99", close_reason="PASSED (sha=%s)" % sha, closed_at=T0 + 6 * D)
        w.run("--notify")
        msgs = self.notified_msgs()
        self.assertEqual(len(msgs), 2)
        self.assertIn("ga-stale99", msgs[1])
        self.assertNotIn("ga-stale01", msgs[1])                    # os antigos não são repetidos

    def test_sem_flag_notify_e_dry_run_nao_avisa_nem_grava_estado(self):
        w = self.w
        self.stale_world(n=2)
        w.run()
        self.assertEqual(self.notified_msgs(), [])
        self.assertFalse(os.path.exists(os.path.join(w.out, "daemon-unverified-sweep.state.json")))

    def test_so_confirmado_nao_avisa(self):
        w = self.w
        self.daemon_world()
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 9 * D)
        w.run("--notify")
        self.assertEqual(self.notified_msgs(), [])

    def test_notify_que_falha_nao_avanca_o_baseline_e_a_proxima_rodada_re_tenta(self):
        w = self.w
        self.stale_world(n=2)
        open(os.path.join(w.fake, "notify.fail"), "w").close()
        r = w.run("--notify")
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertFalse(os.path.exists(os.path.join(w.out, "daemon-unverified-sweep.state.json")))
        os.remove(os.path.join(w.fake, "notify.fail"))
        r = w.run("--notify")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.notified_msgs()), 2)             # a 1ª tentativa (falhou) + a que deu certo
        self.assertIn("ga-stale01", self.state()["notified"])

    def test_estado_corrompido_e_dito_em_voz_alta_e_tratado_como_primeira_rodada(self):
        w = self.w
        self.stale_world(n=2)
        os.makedirs(w.out)
        with open(os.path.join(w.out, "daemon-unverified-sweep.state.json"), "w") as f:
            f.write("{ lixo")
        r = w.run("--notify")
        self.assertIn("estado", r.stderr)                          # não engole: diz que o baseline estava ilegível
        self.assertEqual(len(self.notified_msgs()), 1)             # e re-avisa UMA vez (não perde o alerta)
        self.assertEqual(sorted(self.state()["notified"]), ["ga-stale01", "ga-stale02"])   # e regrava um baseline são

    def test_bead_que_oscila_para_nao_consegui_saber_nao_e_re_avisado_ao_voltar(self):
        w = self.w
        self.stale_world(n=1)
        w.run("--notify")
        open(os.path.join(w.fake, "launchctl", "com.test.svc.fail"), "w").close()      # semana 2: launchctl quebrado
        r = w.run("--notify")
        self.assertEqual(w.state_of("ga-stale01")["state"], NCS)
        os.remove(os.path.join(w.fake, "launchctl", "com.test.svc.fail"))              # semana 3: volta a ser AINDA
        w.run("--notify")
        self.assertEqual(w.state_of("ga-stale01")["state"], AINDA)
        self.assertEqual(len(self.notified_msgs()), 1, "voltar do NCS não é 'novo'")

    # ---- operação: log, lock, formatos de data ------------------------------------
    def test_stdout_resume_as_contagens_por_estado_e_aponta_o_relatorio(self):
        w = self.w
        self.stale_world(n=2)
        r = w.run()
        self.assertRegex(r.stdout, r"CONFIRMADO=0 · AINDA NÃO VISTO=2 · NÃO CONSEGUI SABER=0")
        self.assertIn("daemon-unverified-sweep-", r.stdout)

    def test_segunda_instancia_simultanea_nao_corre_nem_mexe_no_relatorio(self):
        import fcntl
        w = self.w
        self.stale_world(n=1)
        os.makedirs(w.out)
        with open(os.path.join(w.out, "daemon-unverified-sweep.lock"), "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            r = w.run("--notify")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("já em execução", r.stdout + r.stderr)
        self.assertEqual(w.calls("bd"), [], "quem não pegou o lock não pode nem consultar o bd")
        self.assertEqual(self.notified_msgs(), [])

    def test_closed_at_com_fracao_de_segundo_e_lido(self):
        w = self.w
        self.daemon_world(merge_at=T0 + 5 * D)
        w.loaded("com.test.svc", pid=w.next_pid(), start=T0 + 6 * D)
        w.beads["hq"][0]["closed_at"] = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(T0 + 5 * D)) + ".5Z"
        w.run()
        self.assertEqual(w.state_of("ga-aaa111")["state"], CONFIRMADO)

    # ---- escopo ----------------------------------------------------------------
    def test_bead_nao_fechado_fica_fora_de_escopo_e_nao_conta_nos_tres_estados(self):
        w = self.w
        w.bead("ga-hhh888", status="open", closed_at=None)
        w.run()
        b = w.state_of("ga-hhh888")
        self.assertEqual(b["state"], OUT, b)
        counts = w.report()["counts"]
        self.assertEqual((counts[CONFIRMADO], counts[AINDA], counts[NCS], counts[OUT]), (0, 0, 0, 1))

    def test_ps_com_saida_ilegivel_nao_vira_confirmado(self):
        w = self.w
        self.daemon_world()
        pid = w.next_pid()
        w.loaded("com.test.svc", pid=pid)
        with open(os.path.join(w.fake, "ps", str(pid)), "w") as f:
            f.write("ontem à tarde\n")
        w.run()
        b = w.state_of("ga-aaa111")
        self.assertEqual(b["state"], NCS, b)
        self.assertEqual(b["reason"], "ps-read-failed", b)


if __name__ == "__main__":
    unittest.main(verbosity=2)
