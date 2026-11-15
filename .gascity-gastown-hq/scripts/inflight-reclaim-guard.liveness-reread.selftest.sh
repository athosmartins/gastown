#!/usr/bin/env bash
# inflight-reclaim-guard.liveness-reread.selftest.sh — o reclaim guard sob carga: timeout das leituras e releitura de liveness na hora do reclaim (ga-9r4zimt).
#
# Contents
#   O que prova · Como roda · O mundo simulado · Casos · Saída
#
# O QUE PROVA: (1) as chamadas gc/bd que tinham timeout=20 (listagens de sessões e de beads, rig list, mails de alerta) têm teto de 150 s (era 20 s; `gc session list --json` leva 41-43 s com o mini a load 42 e o guard pulou 4 de 5 ciclos depois do boot de 15/11), com a
#   variável IRG_GC_CALL_TIMEOUT mudando o teto e valor ilegível/zero/negativo caindo no padrão (nunca num teto que mataria toda leitura). (2) Antes de reclamar ou escalar, o Pass 2 RELÊ a liveness: o Pass 1
#   leu a lista de sessões no começo do ciclo e a foto envelhece (15/11 03:06:24: reclaim de wa-adn833.12.2 com a foto de 03:03:37, e o builder tinha subido às 03:04:26). Sessão viva na releitura → não
#   reclama; releitura que FALHA → "não sei" → não reclama (nunca vira "sem sessão"); só "morta" libera. (3) A releitura que falha ciclo após ciclo é CONTADA e avisa o Mayor ([GUARD-BLIND]) ao passar do limite —
#   fail-closed sem alarme adiaria todo reclaim para sempre em silêncio; o contador zera quando a leitura volta e NÃO zera num ciclo em que nenhuma bead pediu a releitura. Cada caso roda o `run_cycle` REAL do guard.
# COMO RODA: bash scripts/inflight-reclaim-guard.liveness-reread.selftest.sh   (sem bd, gc, git nem rede; relógio e mundo simulados; ~1 s; NENHUMA escrita em ledger de produção: o escalate do T6 chama `_irg_ledger("human-touch", ...)`
#   e aqui essa chamada é trocada por um registro E o gc_ledger é apontado para um diretório descartável com GC_SELFTEST=1 — dois cintos, e o T6b e o FIM provam os dois; ga-9r4zimt gate-fix 2/3)
#   REREAD_GUARD_UNDER_TEST=<arquivo>   aponta para uma cópia do guard (o HEAD anterior, para provar que os casos reprovam lá; a cópia precisa dos irmãos bead_state.py e gc_ledger.py ao lado)
# O MUNDO SIMULADO: beads in_progress de um dono nomeado (crew-x), sem branch, paradas além do teto de encalhe. `list_active_sessions` é trocada por um leitor que devolve a foto VELHA (sem o dono) na
#   1ª leitura do ciclo e a foto do momento (com ou sem o dono vivo, ou falha) nas seguintes. `do_reclaim`/`do_escalate` registram o que o guard pediu e o mundo aplica o reclaim.
# SAÍDA: uma linha ok/FAIL por checagem e `RESULT: <p> passed, <f> failed`; exit 0 só sem falha.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export REREAD_GUARD_UNDER_TEST="${REREAD_GUARD_UNDER_TEST:-$HERE/inflight-reclaim-guard.py}"
[ -f "$REREAD_GUARD_UNDER_TEST" ] || { echo "FATAL: guard ausente: $REREAD_GUARD_UNDER_TEST"; exit 2; }

python3 -I - <<'PY'
import contextlib, copy, datetime, importlib.util, io, os, re, sys, tempfile, time as _real_time

# O guard importa gc_ledger, que lê GC_LEDGER_DIR/GC_SELFTEST NO IMPORT. `python3 -I -` não tem flag --selftest em argv, então o gc_ledger não reconhece este processo como teste sozinho (ga-9d7it9):
# sem as duas linhas abaixo o escalate do T6 anexaria linhas falsas (wa-t1) ao human-touch.jsonl de PRODUÇÃO a cada execução. Tem de vir ANTES do exec_module.
_TMPD = tempfile.TemporaryDirectory(prefix="irg-reread-")
_LEDGER_SCRATCH = os.path.join(_TMPD.name, "ledger")
os.makedirs(_LEDGER_SCRATCH, exist_ok=True)
os.environ["GC_SELFTEST"] = "1"
os.environ["GC_LEDGER_DIR"] = _LEDGER_SCRATCH

GUARD = os.environ["REREAD_GUARD_UNDER_TEST"]
spec = importlib.util.spec_from_file_location("irg_reread_under_test", GUARD)
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

# A contagem de releitura falha grava em STATE_FILE + ".query-fail": aqui o estado vai para um diretório temporário (nunca o .gc/state do cwd) e o `gc mail send` do alerta é registrado, não executado.
g.STATE_FILE = os.path.join(_TMPD.name, "state.json")
QF = g.STATE_FILE + ".query-fail"
MAILS = []
LEDGER_CALLS = []   # o que o guard pediu ao _irg_ledger (trocado no World._install): prova que o escalate chegou lá e que nada foi gravado


class _MailProc:
    returncode, stdout, stderr = 0, b"", b""


_real_subprocess_run = g.subprocess.run


def _mail_run(cmd, *a, **kw):
    if list(cmd)[:3] == ["gc", "mail", "send"]:
        MAILS.append(list(cmd))
        return _MailProc()
    return _real_subprocess_run(cmd, *a, **kw)


g.subprocess.run = _mail_run


_GL = sys.modules["gc_ledger"]   # o módulo que o guard importou (o mesmo LEDGER_DIR/LIVE_LEDGER_DIR que o guard enxerga)
_LIVE_HT = os.path.join(_GL.LIVE_LEDGER_DIR, "human-touch.jsonl")


def live_sig():
    """(tamanho, mtime_ns) do human-touch.jsonl de PRODUÇÃO, ou None se ele não existe nesta máquina. Não existir e existir-igual valem o mesmo aqui: o que se prova é que a execução não o mexeu."""
    try:
        st = os.stat(_LIVE_HT)
        return (st.st_size, st.st_mtime_ns)
    except FileNotFoundError:
        return None


LIVE_BEFORE = live_sig()


def qf_cycles():
    """A contagem persistida de ciclos seguidos com a releitura falha (0 se o arquivo não existe)."""
    return g._load_query_fail_state().get("reread_fail_cycles", 0)


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
    def __init__(self, reread, ids=("wa-t1",), reclaim_count=0, tick_on_reclaim=0):
        try:
            os.remove(QF)               # cada mundo começa sem contagem de releitura falha (o arquivo é compartilhado pelo módulo)
        except FileNotFoundError:
            pass
        MAILS.clear()
        LEDGER_CALLS.clear()
        self.tick_on_reclaim = tick_on_reclaim   # segundos que o relógio anda a cada reclaim pedido (uma leitura lenta entre duas beads do mesmo ciclo)
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
        g._irg_ledger = lambda name, data, **k: LEDGER_CALLS.append((name, data))   # o escalate chama o ledger de human-touch: registra, não grava
        g.do_reclaim = lambda bead_id, *a, **kw: (w.reclaims.append(bead_id), setattr(w, "now", w.now + w.tick_on_reclaim), True)[2]
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

# ── T6b: o escalate do T6 pede o ledger de human-touch — e NADA disso pode chegar ao ledger de produção (ga-9r4zimt gate-fix 2/3: a versão anterior anexava 2 linhas falsas a cada execução no mini).
# Dois cintos independentes: (a) o `_irg_ledger` do guard é trocado por um registro no World; (b) o gc_ledger aponta para um diretório descartável (GC_SELFTEST=1 + GC_LEDGER_DIR antes do import).
check("T6b o escalate chegou ao ledger human-touch (o registro tem o pedido da bead wa-t1)", any(n == "human-touch" and isinstance(d, dict) and d.get("bead_id") == "wa-t1" for n, d in LEDGER_CALLS), "pedidos=%r" % (LEDGER_CALLS,))
_real_ht = os.path.realpath(_GL.ledger_path("human-touch"))
check("T6b gc_ledger.ledger_path('human-touch') cai no diretório descartável", _real_ht.startswith(os.path.realpath(_LEDGER_SCRATCH) + os.sep), "ledger_path=%r scratch=%r" % (_real_ht, _LEDGER_SCRATCH))
check("T6b ... e não no diretório vivo de ledgers", not _real_ht.startswith(os.path.realpath(_GL.LIVE_LEDGER_DIR) + os.sep), "ledger_path=%r live=%r" % (_real_ht, _GL.LIVE_LEDGER_DIR))
_GL.gc_ledger_append("human-touch", {"ts": "2026-01-01T00:00:00Z", "source_daemon": "inflight-reclaim-guard", "bead_id": "selftest-probe", "reason": "sonda do selftest liveness-reread"}, fail_open=False)   # o writer REAL, sem o registro do cinto (a)
check("T6b o writer real do gc_ledger grava no descartável (cinto (b) vale sem o (a))", os.path.isfile(_real_ht) and "selftest-probe" in open(_real_ht, encoding="utf-8").read(), "arquivo=%r" % (_real_ht,))
check("T6b o human-touch.jsonl de produção não mudou nesta execução (tamanho e mtime iguais, ou ausente nos dois lados)", live_sig() == LIVE_BEFORE, "antes=%r depois=%r" % (LIVE_BEFORE, live_sig()))

# ── T7: o teto das chamadas gc/bd que tinham timeout=20. Constante padrão e a leitura de IRG_GC_CALL_TIMEOUT (vazio/ilegível/≤0 → padrão, nunca um teto que cegue o guard).
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

# ── T9: a releitura vale 30 s (LIVENESS_REREAD_MAX_AGE_SECS) e depois EXPIRA. Duas beads acionadas no mesmo ciclo, com uma leitura lenta entre elas (o relógio anda a cada reclaim): passou de 30 s → lê de novo.
w = World("dead", ids=("wa-t1", "wa-t2"), tick_on_reclaim=g.LIVENESS_REREAD_MAX_AGE_SECS + 1)
w.run(3)
w.reads = 0
w.cycle()
check("T9 a releitura de 31 s é velha: a 2ª bead do ciclo relê (1 + 2 leituras)", w.reads == 3, "leituras=%d reclaims=%r" % (w.reads, w.reclaims))
w = World("dead", ids=("wa-t1", "wa-t2"), tick_on_reclaim=5)
w.run(3)
w.reads = 0
w.cycle()
check("T9 controle: a releitura de 5 s ainda vale (1 + 1 leituras)", w.reads == 2, "leituras=%d" % w.reads)

# ── T10: releitura que falha CICLO APÓS CICLO é contada e avisa o Mayor (fail-closed sem alarme adiaria todo reclaim para sempre, em silêncio).
LIM = g.QUERY_FAIL_MIN_CYCLES


def run_until(w, want, limit=60):
    n = 0
    while qf_cycles() < want and n < limit:
        w.cycle()
        n += 1
    return qf_cycles()


def blind_lines(w):
    return [m for m in w.emitted if "[REREAD-BLIND]" in m]


w = World("fail")
check("T10 a contagem começa em 0 (nada lido ainda)", qf_cycles() == 0, "ciclos=%r" % qf_cycles())
check("T10 1º ciclo com a releitura falha: contagem 1 e uma linha [REREAD-BLIND] no log", run_until(w, 1) == 1 and len(blind_lines(w)) == 1, "ciclos=%r linhas=%r" % (qf_cycles(), blind_lines(w)))
check("T10: a linha diz quantas beads ficaram sem verificação", any("1/1 triggered bead(s)" in m for m in blind_lines(w)), "linhas=%r" % blind_lines(w))
run_until(w, LIM - 1)
check("T10 um ciclo abaixo do limite (%d): nenhum aviso ao Mayor" % LIM, qf_cycles() == LIM - 1 and MAILS == [] and not any("[GUARD-BLIND]" in m for m in w.emitted), "ciclos=%r mails=%r" % (qf_cycles(), MAILS))
w.cycle()
check("T10 no limite (%d ciclos seguidos): UM mail [GUARD-BLIND] para o Mayor" % LIM, qf_cycles() == LIM and len(MAILS) == 1 and MAILS[0][3] == "mayor" and "[GUARD-BLIND]" in MAILS[0][5], "ciclos=%r mails=%r" % (qf_cycles(), MAILS))
check("T10: o aviso é emitido no log também, com a contagem", any("[GUARD-BLIND] liveness re-read failed %d consecutive cycles" % LIM in m for m in w.emitted), "emitidos=%r" % [m for m in w.emitted if "GUARD-BLIND" in m])
w.cycle()
check("T10 dentro do cooldown (ciclo seguinte, %d s < %d s): sem 2º mail" % (g.POLL_SEC if hasattr(g, "POLL_SEC") else 600, g.QUERY_FAIL_COOLDOWN), len(MAILS) == 1, "mails=%d" % len(MAILS))
check("T10: a falha persistente nunca virou reclaim (fail-closed segue valendo)", w.reclaims == [] and w.escalations == [], "reclaims=%r escalations=%r" % (w.reclaims, w.escalations))
check("T10: as chaves do [GUARD-BLIND] do Pass 1 não foram tocadas (contador separado)", g._load_query_fail_state().get("consecutive_cycles", 0) == 0, "estado=%r" % g._load_query_fail_state())

# a releitura volta a responder → zera (inclusive quando a resposta é 'viva': a LEITURA funcionou, o veredito é outro assunto)
w = World("fail")
run_until(w, 3)
w.reread = "live"
w.cycle()
check("T10 a releitura voltou a responder: a contagem zera", qf_cycles() == 0, "ciclos=%r" % qf_cycles())
w = World("fail")
run_until(w, 3)
w.reread = "dead"
w.cycle()
check("T10 a releitura voltou (e confirmou a morte): zera e o guard reclama", qf_cycles() == 0 and len(w.reclaims) >= 1, "ciclos=%r reclaims=%r" % (qf_cycles(), w.reclaims))

# ciclo em que NENHUMA bead pediu a releitura: não prova que a leitura voltou → não zera (e não conta)
w = World("fail")
run_until(w, 3)
n_before = len(blind_lines(w))
w.state["wa-t1"]["first_seen_stranded"] = w.now + POLL      # a bead volta para dentro da carência de encalhe: o Pass 1 a classifica noop, ninguém pede a releitura
w.cycle()
check("T10 ciclo sem releitura pedida: a contagem fica onde estava (3), não zera", qf_cycles() == 3, "ciclos=%r estado=%r" % (qf_cycles(), w.state.get("wa-t1")))
check("T10: e esse ciclo não gera linha [REREAD-BLIND] nova", len(blind_lines(w)) == n_before, "linhas=%r" % blind_lines(w))

# ── fim: nenhum dos mundos acima (T1-T10) tocou o human-touch.jsonl de produção.
check("FIM o human-touch.jsonl de produção segue como estava antes da bateria inteira", live_sig() == LIVE_BEFORE, "antes=%r depois=%r" % (LIVE_BEFORE, live_sig()))

print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
