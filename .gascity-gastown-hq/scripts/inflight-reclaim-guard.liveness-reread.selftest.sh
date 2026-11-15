#!/usr/bin/env bash
# inflight-reclaim-guard.liveness-reread.selftest.sh — o reclaim guard sob carga: timeout das leituras e releitura de liveness na hora do reclaim (ga-9r4zimt).
#
# Contents
#   O que prova · Como roda · O mundo simulado · Casos · Saída
#
# O QUE PROVA: (1) toda leitura gc/bd do guard tem teto de 150 s (era 20 s; `gc session list --json` leva 41-43 s com o mini a load 42 e o guard pulou 4 de 5 ciclos depois do boot de 15/11), com a
#   variável IRG_GC_CALL_TIMEOUT mudando o teto e valor ilegível/zero/negativo caindo no padrão (nunca num teto que mataria toda leitura). (2) Antes de reclamar ou escalar, o Pass 2 RELÊ a liveness: o Pass 1
#   leu a lista de sessões no começo do ciclo e a foto envelhece (15/11 03:06:24: reclaim de wa-adn833.12.2 com a foto de 03:03:37, e o builder tinha subido às 03:04:26). Sessão viva na releitura → não
#   reclama; releitura que FALHA → "não sei" → não reclama (nunca vira "sem sessão"); só "morta" libera. Cada caso roda o `run_cycle` REAL do guard.
# COMO RODA: bash scripts/inflight-reclaim-guard.liveness-reread.selftest.sh   (hermético: sem bd, gc, git nem rede; relógio e mundo simulados; ~1 s)
#   REREAD_GUARD_UNDER_TEST=<arquivo>   aponta para uma cópia do guard (o HEAD anterior, para provar que os casos reprovam lá; a cópia precisa dos irmãos bead_state.py e gc_ledger.py ao lado)
# O MUNDO SIMULADO: beads in_progress de um dono nomeado (crew-x), sem branch, paradas além do teto de encalhe. `list_active_sessions` é trocada por um leitor que devolve a foto VELHA (sem o dono) na
#   1ª leitura do ciclo e a foto do momento (com ou sem o dono vivo, ou falha) nas seguintes. `do_reclaim`/`do_escalate` registram o que o guard pediu e o mundo aplica o reclaim.
# SAÍDA: uma linha ok/FAIL por checagem e `RESULT: <p> passed, <f> failed`; exit 0 só sem falha.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export REREAD_GUARD_UNDER_TEST="${REREAD_GUARD_UNDER_TEST:-$HERE/inflight-reclaim-guard.py}"
[ -f "$REREAD_GUARD_UNDER_TEST" ] || { echo "FATAL: guard ausente: $REREAD_GUARD_UNDER_TEST"; exit 2; }

python3 -I - <<'PY'
import contextlib, copy, datetime, importlib.util, io, os, re, sys, time as _real_time

GUARD = os.environ["REREAD_GUARD_UNDER_TEST"]
spec = importlib.util.spec_from_file_location("irg_reread_under_test", GUARD)
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

T0 = 1_800_000_000.0
OWNER = "crew-x"
POLL = 600.0
PASS = FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("ok    " + name)
    else:
        FAIL += 1
        print("FAIL  " + name + ((" — " + detail) if detail else ""))


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Clock:
    """O `time` do guard: time() devolve o relógio do mundo (parado dentro do ciclo), o resto é o módulo de verdade."""
    def __init__(self, world):
        self.w = world

    def time(self):
        return self.w.now

    def __getattr__(self, name):
        return getattr(_real_time, name)


class World:
    """reread: o que as leituras 2+ do ciclo devolvem — "dead" (a mesma foto sem o dono), "live" (o dono apareceu), "fail" (None)."""
    def __init__(self, reread, ids=("wa-t1",), reclaim_count=0):
        self.now = T0
        self.reread = reread
        self.beads = [{"id": i, "title": "bead de teste " + i, "issue_type": "task", "status": "in_progress", "assignee": OWNER,
                       "labels": ["story:in-flight", "pilot:dispatched"] + (["pilot:reclaim-count:%d" % reclaim_count] if reclaim_count else []),
                       "metadata": {}, "updated_at": iso(T0 - 7200)} for i in ids]
        self.state, self.alerted = {}, {}
        self.reclaims, self.escalations, self.emitted = [], [], []
        self.reads = 0          # quantas vezes o guard leu a lista de sessões NESTE ciclo
        self._install()

    def roster(self, with_owner):
        out = [{"id": "s-other", "name": "dog-remote-2", "session_name": "dog-remote-2", "alias": "dog-remote-2",
                "template": "dog-remote", "state": "active", "last_active": iso(self.now), "closed": False}]
        if with_owner:
            out.append({"id": "s-owner", "name": OWNER, "session_name": OWNER, "alias": OWNER, "template": "crew",
                        "state": "active", "last_active": iso(self.now - 5), "closed": False})
        return out

    def read_sessions(self):
        self.reads += 1
        if self.reads == 1:                 # a foto do começo do ciclo (Pass 1): o dono NÃO está nela
            return self.roster(False)
        if self.reread == "fail":
            return None
        return self.roster(self.reread == "live")

    def _install(self):
        w = self
        g.time = Clock(w)
        g.emit = lambda msg: w.emitted.append(msg)
        g.list_inflight_beads = lambda: [copy.deepcopy(b) for b in w.beads if b["status"] == "in_progress"]
        g.list_stranded_inprogress_beads = lambda: []
        g.compute_multi_assigned_assignees = lambda beads, parent_reader=None, notes=None: set()
        g.list_active_sessions = w.read_sessions
        g.heal_orphan_sweep_false_resets = lambda *a, **k: None
        g.list_suspended_agents = lambda: set()
        g.list_gate_active_source_beads = lambda: frozenset()
        g.list_live_sling_source_beads = lambda sessions, now: frozenset()
        g.list_refused_sling_source_beads = lambda: {}
        g.account_is_rate_limited = lambda: False
        g.get_branch_recent = lambda *a, **k: False
        g.get_worktree_progress = lambda *a, **k: g.WT_QUIET
        g.session_awaiting_human_input = lambda *a, **k: False
        g._note_query_failure = lambda *a, **k: None
        g._note_query_success = lambda *a, **k: None
        g._check_pool_dead = lambda *a, **k: None
        g.do_reclaim = lambda bead_id, *a, **kw: (w.reclaims.append(bead_id), True)[1]
        g.do_escalate = lambda bead_id, *a, **kw: (w.escalations.append(bead_id), [])[1]

    def cycle(self, dt=POLL):
        self.now += dt
        self.reads = 0
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):       # o DEFERRED sai por print (não por emit): captura o stdout do ciclo, e o log do guard não polui a saída do teste
            g.run_cycle(self.state, self.alerted)
        self.emitted.extend(l for l in buf.getvalue().splitlines() if l.strip())

    def run(self, cycles):
        for _ in range(cycles):
            self.cycle()

    def deferred(self):
        return [m for m in self.emitted if "[DEFERRED]" in m]


# ── T1 (controle): a releitura confirma que o dono segue sem sessão → reclama, uma vez por bead. Sem este caso os outros passariam por não alcançarem o reclaim.
w = World("dead")
w.run(8)   # 80 min: bem além do teto de encalhe de 25 min
check("T1 controle: dono sem sessão nas duas leituras → o guard reclama a bead", w.reclaims.count("wa-t1") >= 1, "reclaims=%r deferred=%r" % (w.reclaims, w.deferred()))
check("T1: nenhuma linha DEFERRED quando a releitura confirma a morte", w.deferred() == [], "deferred=%r" % w.deferred())

# ── T2: a foto do Pass 1 envelhece — o builder subiu depois dela. A releitura vê o dono vivo: NÃO reclama, e diz por quê.
w = World("live")
w.run(8)
check("T2 builder subiu depois da foto: o guard NÃO reclama", w.reclaims == [], "reclaims=%r" % (w.reclaims,))
check("T2: o ciclo registra DEFERRED com a releitura 'live'", any("liveness re-read=live" in m for m in w.deferred()), "deferred=%r" % w.deferred())
check("T2: o relógio de encalhe da bead não é apagado (estado inerte: o próximo ciclo decide)", "wa-t1" in w.state, "estado=%r" % list(w.state))

# ── T3: a releitura FALHA (gc session list estourou o teto). "Não sei" ≠ "sem sessão": não reclama.
w = World("fail")
w.run(8)
check("T3 releitura falhou: o guard NÃO reclama (não sei ≠ sem sessão)", w.reclaims == [], "reclaims=%r" % (w.reclaims,))
check("T3: o ciclo registra DEFERRED com a releitura 'unknown'", any("liveness re-read=unknown" in m for m in w.deferred()), "deferred=%r" % w.deferred())

# ── T4: duas beads acionadas no mesmo ciclo dividem UMA releitura (a leitura custa 40+ s: uma por bead multiplicaria o ciclo).
w = World("dead", ids=("wa-t1", "wa-t2"))
w.run(3)    # 30 min: as duas passam do teto de encalhe no último ciclo
w.reads = 0
w.cycle()
check("T4 duas beads no mesmo ciclo: 1 leitura do Pass 1 + 1 releitura (não 1 + 2)", w.reads == 2, "leituras=%d reclaims=%r" % (w.reads, w.reclaims))
check("T4: as duas beads são reclamadas", set(w.reclaims) >= {"wa-t1", "wa-t2"}, "reclaims=%r" % (w.reclaims,))

# ── T5: a releitura que falha também fica no cache do ciclo — senão cada bead repetiria os 150 s do gc estourado.
w = World("fail", ids=("wa-t1", "wa-t2"))
w.run(3)
w.reads = 0
w.cycle()
check("T5 releitura falhou com duas beads: ainda 1 + 1 leituras (a falha é dividida)", w.reads == 2, "leituras=%d" % w.reads)
check("T5: nenhuma das duas é reclamada", w.reclaims == [], "reclaims=%r" % (w.reclaims,))

# ── T6: o caminho de ESCALATE (bead com o teto de reclaims estourado) passa pela mesma releitura: sessão viva → não escala.
w = World("live", reclaim_count=g.MAX_RECLAIMS)
w.run(8)
check("T6 escalate com o dono vivo na releitura: não escala", w.escalations == [] and w.reclaims == [], "escalations=%r reclaims=%r" % (w.escalations, w.reclaims))
w = World("dead", reclaim_count=g.MAX_RECLAIMS)
w.run(8)
check("T6 controle: com a morte confirmada, o teto estourado escala", len(w.escalations) >= 1, "escalations=%r reclaims=%r" % (w.escalations, w.reclaims))

# ── T7: o teto de cada chamada gc/bd. Constante padrão e a leitura de IRG_GC_CALL_TIMEOUT (vazio/ilegível/≤0 → padrão, nunca um teto que cegue o guard).
default = getattr(g, "GC_CALL_TIMEOUT", None)
check("T7 o teto padrão das leituras é 150 s", default == 150, "GC_CALL_TIMEOUT=%r" % (default,))
fn = getattr(g, "_gc_call_timeout", None)
if fn is None:
    check("T7 _gc_call_timeout existe", False, "função ausente")
else:
    for raw, want in ((None, 150), ("", 150), ("  ", 150), ("abc", 150), ("0", 150), ("-5", 150), ("300", 300), (" 90 ", 90)):
        check("T7 IRG_GC_CALL_TIMEOUT=%r → %d s" % (raw, want), fn(raw) == want, "got=%r" % (fn(raw),))

# ── T8: o teto chega à chamada. `gc session list --json` (a leitura de 41-43 s) e as listagens do bd rodam com timeout=GC_CALL_TIMEOUT, nenhuma com os 20 s antigos.
seen = []


class FakeProc:
    def __init__(self, out="[]"):
        self.returncode, self.stdout, self.stderr = 0, out, ""


def fake_run(cmd, *a, **kw):
    seen.append((list(cmd), kw.get("timeout")))
    return FakeProc("[]")


real_run = g.subprocess.run
g.subprocess.run = fake_run
try:
    spec2 = importlib.util.spec_from_file_location("irg_reread_fresh", GUARD)
    g2 = importlib.util.module_from_spec(spec2)
    spec2.loader.exec_module(g2)          # módulo novo: as funções de leitura de verdade, sem os leitores trocados do mundo
    g2.subprocess.run = fake_run
    for name in ("list_active_sessions", "list_inflight_beads", "list_stranded_inprogress_beads", "list_suspended_agents"):
        try:
            getattr(g2, name)()
        except Exception as exc:                 # a leitura é o que se mede; o que o fake devolve não importa
            print("note  %s levantou %s com o fake (ok: só o teto interessa)" % (name, type(exc).__name__))
finally:
    g.subprocess.run = real_run
sess = [t for c, t in seen if c[:3] == ["gc", "session", "list"]]
check("T8 `gc session list --json` roda com timeout=150", sess == [150], "timeouts=%r" % (sess,))
bd_reads = [t for c, t in seen if c and c[0] == "bd"]
check("T8 as listagens do bd rodam todas com timeout=150 (nenhuma com os 20 s antigos)", bd_reads != [] and all(t == 150 for t in bd_reads), "timeouts=%r" % (bd_reads,))
src = open(GUARD, encoding="utf-8").read()
left = [i + 1 for i, l in enumerate(src.splitlines()) if re.search(r"timeout\s*=\s*20\b", l)]
check("T8 deriva: nenhuma chamada subprocess do guard volta a `timeout=20`", left == [], "linhas=%r" % (left,))

print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
