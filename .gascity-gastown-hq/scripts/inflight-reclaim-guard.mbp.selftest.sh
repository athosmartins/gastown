#!/usr/bin/env bash
# inflight-reclaim-guard.mbp.selftest.sh — o reclaim guard e a bead que um alias do MBP segura (ga-w7qwl1.2.3, corte 3 de 5).
#
# Contents
#   O que prova · Como roda · O mundo simulado · Casos · Saída
#
# O QUE PROVA: o guard (scripts/inflight-reclaim-guard.py) lê "a sessão está viva" no roster do engine (`gc session list`) e na atividade dela. Num notebook esses sinais mentem sem que a sessão tenha morrido: tampa fechada,
#   wifi trocando de rede, o Athos de volta e a árvore rebaixada (renice) quieta por uma hora, `is-running` com erro lido como "parou" (ponto em aberto 5 do gc-session-ssh.md). Sem tratamento o guard reclama a bead no mini
#   enquanto a sessão do MBP ainda a tem — dois construtores — ou, ao contrário, a deixa presa a um alias sem sessão. Cada caso abaixo roda o `run_cycle` REAL do guard e conta, no fim, quantos construtores a bead tem:
#   exatamente UM (o do MBP que segue vivo, ou o do mini depois que a sessão do MBP sumiu de vez), nunca dois, nunca nenhum.
# COMO RODA: bash scripts/inflight-reclaim-guard.mbp.selftest.sh   (hermético: sem bd, gc, git nem rede; o relógio e o mundo são simulados; ~1 s)
#   MBP_GUARD_UNDER_TEST=<arquivo>   aponta para uma cópia do guard (o executor de mutantes usa isto; a cópia precisa dos irmãos bead_state.py e gc_ledger.py ao lado)
#   MBP_GUARD_ST_NOMUT=1             não roda o executor de mutantes ao fim
# O MUNDO SIMULADO: uma bead in_progress com dono wa-worker-remote-mbp-1 e a marca pilot.wa_node_alias (a cara exata do que o `mbp-node-dispatch.sh apply` escreve), o roster que o engine devolveria, e um despachante que
#   entrega ao mini toda bead aberta e sem dono. Os leitores de bd/gc do guard são trocados por leitores do mundo; `do_reclaim` por um que aplica no mundo o que o guard pediu (status open, dono vazio, marcas que ele manda
#   tirar). O `do_reclaim` de verdade é conferido à parte, pelos argumentos que ele passa ao bd.
# SAÍDA: uma linha ok/FAIL por checagem e `RESULT: <p> passed, <f> failed`; exit 0 só sem falha.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export MBP_GUARD_UNDER_TEST="${MBP_GUARD_UNDER_TEST:-$HERE/inflight-reclaim-guard.py}"
export MBP_HERE="$HERE"
[ -f "$MBP_GUARD_UNDER_TEST" ] || { echo "FATAL: guard ausente: $MBP_GUARD_UNDER_TEST"; exit 2; }

python3 -I - <<'PY'
import copy, datetime, importlib.util, os, subprocess, sys, time as _real_time

REAL_RUN = subprocess.run   # o do_reclaim abaixo roda com `subprocess.run` trocado por um falso (o módulo é o mesmo): o executor de mutantes usa este
GUARD = os.environ["MBP_GUARD_UNDER_TEST"]
spec = importlib.util.spec_from_file_location("irg_mbp_under_test", GUARD)
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

T0 = 1_800_000_000.0
ALIAS = "wa-worker-remote-mbp-1"
MARK = "pilot.wa_node_alias"
MINI = "wa-worker-adhoc-1"
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
    """O `time` do guard: time() devolve o relógio do mundo, o resto é o módulo de verdade."""
    def __init__(self, world):
        self.w = world

    def time(self):
        return self.w.now

    def __getattr__(self, name):
        return getattr(_real_time, name)


class World:
    def __init__(self, alias=ALIAS, mark=True, session=None, mbp_alive=True, others=True):
        self.now = T0
        self.others = others            # o roster tem outras sessões da cidade (o normal); sem elas ele está vazio e vazio não prova ausência
        self.bead = {"id": "wa-t1", "title": "bead de teste do MBP", "issue_type": "task", "status": "in_progress",
                     "assignee": alias, "labels": ["story:in-flight", "pilot:dispatched"],
                     "metadata": ({MARK: alias} if mark else {}), "updated_at": iso(T0 - 7200)}
        self.alias = alias
        self.session = session          # None = o engine não tem sessão do alias; senão {"state": s, "age": segundos desde o last_active}
        self.mbp_alive = mbp_alive      # a sessão do notebook segue com a bead na cabeça, mesmo sem ssh
        self.mini = False               # a bead foi entregue a um construtor do mini
        self.state, self.alerted = {}, {}
        self.reclaims, self.emitted = [], []
        self._install()

    def roster(self):
        out = []
        if self.others:
            out.append({"id": "s-other", "name": "dog-remote-2", "session_name": "dog-remote-2", "alias": "dog-remote-2",
                        "template": "dog-remote", "state": "active", "last_active": iso(self.now), "closed": False})
        if self.session is not None:
            out.append({"id": "s-mbp", "name": "wa-worker-remote-mbp-gawisp1", "session_name": "wa-worker-remote-mbp-gawisp1",
                        "alias": self.alias, "template": "wa-worker-remote-mbp", "state": self.session["state"],
                        "last_active": iso(self.now - self.session["age"]), "closed": False})
        if self.mini:
            out.append({"id": "s-mini", "name": MINI, "session_name": MINI, "alias": MINI, "template": "wa-worker",
                        "state": "active", "last_active": iso(self.now), "closed": False})
        return out

    def apply_reclaim(self, bead_id, kw):
        self.reclaims.append(dict(kw))
        b = self.bead
        b["status"], b["assignee"] = "open", ""
        b["labels"] = [x for x in b["labels"] if x not in ("story:in-flight", "pilot:dispatched")]
        for key in (kw.get("unset_metadata") or ()):
            b["metadata"].pop(key, None)
        return True

    def _install(self):
        w = self
        g.time = Clock(w)
        g.emit = lambda msg: w.emitted.append(msg)
        g.list_inflight_beads = lambda: [copy.deepcopy(w.bead)] if w.bead["status"] == "in_progress" else []
        g.list_stranded_inprogress_beads = lambda: []
        g.compute_multi_assigned_assignees = lambda beads, parent_reader=None, notes=None: set()
        g.list_active_sessions = lambda: w.roster()
        g.heal_orphan_sweep_false_resets = lambda *a, **k: None
        g.list_suspended_agents = lambda: set()
        g.list_gate_active_source_beads = lambda: frozenset()
        g.list_live_sling_source_beads = lambda sessions, now: frozenset()
        g.list_refused_sling_source_beads = lambda: {}
        g.account_is_rate_limited = lambda: False
        g.get_branch_recent = lambda *a, **k: False
        g.session_awaiting_human_input = lambda *a, **k: False   # o peek do pane vai por ssh: sem ssh, "não está esperando resposta"
        g._note_query_failure = lambda *a, **k: None
        g._note_query_success = lambda *a, **k: None
        g._check_pool_dead = lambda *a, **k: None
        g.do_reclaim = lambda bead_id, title, rc, idle, labels, **kw: w.apply_reclaim(bead_id, kw)
        g.do_escalate = lambda *a, **k: []

    def cycle(self, dt=POLL):
        self.now += dt
        g.run_cycle(self.state, self.alerted)
        b = self.bead
        if b["status"] == "open" and not b["assignee"]:      # o despachante do mini pega toda bead aberta e sem dono
            b["status"], b["assignee"] = "in_progress", MINI
            b["labels"] = b["labels"] + ["story:in-flight", "pilot:dispatched"]
            self.mini = True

    def run(self, cycles):
        for _ in range(cycles):
            self.cycle()

    def builders(self):
        """Quantos construtores a bead tem: o do mini (a bead foi para lá) e a sessão do notebook (viva, com a bead na cabeça)."""
        return int(self.mini) + int(self.mbp_alive)

    def mbp_alerts(self):
        return [m for m in self.emitted if "MBP-HOLD" in m]


def one_owner(w, name, owner):
    check(name + ": termina com UM construtor", w.builders() == 1, "construtores=%d mini=%s mbp=%s" % (w.builders(), w.mini, w.mbp_alive))
    check(name + ": o dono da bead é " + owner, w.bead["assignee"] == owner, "dono=%r" % w.bead["assignee"])


# ── T1: o Athos volta com a sessão aberta. A árvore rebaixada fica quieta (last_active velho há 45 min), o roster diz active.
w = World(session={"state": "active", "age": 2700})
w.run(18)   # 3 h
check("T1 Athos volta (sessão aberta, quieta 45 min): o guard não reclama", w.reclaims == [], "reclaims=%d" % len(w.reclaims))
one_owner(w, "T1", ALIAS)
check("T1: a marca do nó continua na bead", w.bead["metadata"].get(MARK) == ALIAS)

# ── T2: o ssh cai com a sessão aberta. O engine leu o erro do is-running como "parou": o roster mostra asleep.
w = World(session={"state": "asleep", "age": 3600})
w.run(18)   # 3 h
check("T2 ssh cai (roster asleep): o guard não reclama", w.reclaims == [], "reclaims=%d" % len(w.reclaims))
one_owner(w, "T2", ALIAS)

# ── T3: o ssh volta. 90 min de queda, depois a sessão responde de novo (active, atividade fresca).
w = World(session={"state": "asleep", "age": 3600})
w.run(9)    # 90 min
w.session = {"state": "active", "age": 30}
w.run(12)   # 2 h
check("T3 ssh volta: nenhuma reclamação, nem na queda nem depois", w.reclaims == [], "reclaims=%d" % len(w.reclaims))
one_owner(w, "T3", ALIAS)
check("T3: o relógio da queda zera quando a sessão responde", "mbp_hold_since" not in w.state.get(w.bead["id"], {}), "estado=%r" % w.state.get(w.bead["id"]))

# ── T4: a sessão some de vez. O engine não tem mais sessão do alias (fechada) e o tmux do notebook morreu.
w = World(session=None, mbp_alive=False)
w.cycle(); w.cycle(); w.cycle()
check("T4 sessão some de vez: a histerese de 25 min vale (nada nos 30 primeiros minutos)", w.reclaims == [], "reclaims=%d" % len(w.reclaims))
w.run(5)
check("T4: a bead é reclamada uma vez, depois do prazo", len(w.reclaims) == 1, "reclaims=%d" % len(w.reclaims))
check("T4: o reclaim manda tirar a marca pilot.wa_node_alias", bool(w.reclaims) and MARK in (w.reclaims[0].get("unset_metadata") or ()), "kw=%r" % (w.reclaims[:1],))
check("T4: a bead não fica com a marca de um alias que não é mais dono", MARK not in w.bead["metadata"], "metadata=%r" % w.bead["metadata"])
one_owner(w, "T4", MINI)

# ── T5: a queda passa do teto. Segurar não é esquecer: um aviso por teto, a bead segue do notebook.
w = World(session={"state": "asleep", "age": 3600})
w.run(42)   # 7 h
check("T5 queda de 7 h: a bead segue segura", w.reclaims == [], "reclaims=%d" % len(w.reclaims))
check("T5: UM aviso (não um por varredura) depois de 6 h", len(w.mbp_alerts()) == 1, "avisos=%d" % len(w.mbp_alerts()))
w.run(36)   # mais 6 h (13 h no total)
check("T5: o segundo aviso só vem um teto depois", len(w.mbp_alerts()) == 2, "avisos=%d" % len(w.mbp_alerts()))
one_owner(w, "T5", ALIAS)

# ── O Mayor soltou a bead à mão (`mbp-node-dispatch.sh release`: sem dono e sem marca, ainda in_progress): o guard a reclama no prazo de sempre, não fica presa.
w = World(alias="", mark=False, session=None, mbp_alive=False)
w.run(8)
check("bead solta à mão (sem dono, in_progress): o guard a reclama uma vez, no prazo", len(w.reclaims) == 1, "reclaims=%d" % len(w.reclaims))
one_owner(w, "bead solta à mão", MINI)

# ── Roster vazio não prova que a sessão sumiu (a lista veio sem nada, o que também acontece com o engine subindo): segura, como o claimant_provably_dead.
w = World(session=None, others=False)
w.run(18)
check("roster vazio: o guard segura (vazio não prova ausência)", w.reclaims == [], "reclaims=%d" % len(w.reclaims))
one_owner(w, "roster vazio", ALIAS)

# ── Controles: o tratamento é só do alias do MBP.
w = World(alias="wa-worker-remote-1", session={"state": "asleep", "age": 3600})
w.run(18)
check("controle: alias do Hetzner (wa-worker-remote-1) continua sendo reclamado como antes", len(w.reclaims) >= 1, "reclaims=%d" % len(w.reclaims))
check("controle: o reclaim do alias do Hetzner não leva unset_metadata (a marca do MBP é só do MBP)", all(not r.get("unset_metadata") for r in w.reclaims), "reclaims=%r" % (w.reclaims[:1],))
w = World(alias="xwa-worker-remote-mbp-1", session={"state": "asleep", "age": 3600})
w.run(18)
check("controle: nome parecido (xwa-worker-remote-mbp-1) continua sendo reclamado", len(w.reclaims) >= 1, "reclaims=%d" % len(w.reclaims))
w = World(alias="wa-worker-remote-mbp-10", session={"state": "asleep", "age": 3600})
w.run(18)
check("controle: wa-worker-remote-mbp-10 (o release só aceita 1..9) continua sendo reclamado", len(w.reclaims) >= 1, "reclaims=%d" % len(w.reclaims))

# ── Dono do MBP sem a marca (atribuída à mão): o dono é um alias do MBP, a liveness dele mente igual.
w = World(mark=False, session={"state": "asleep", "age": 3600})
w.run(18)
check("sem a marca, dono alias do MBP: o guard também segura", w.reclaims == [], "reclaims=%d" % len(w.reclaims))

# ── do_reclaim de verdade: a marca sai por um bd update --unset-metadata, depois de o dono sair.
real = importlib.util.module_from_spec(spec)
spec.loader.exec_module(real)
calls = []


class R:
    returncode, stdout, stderr = 0, "", ""


real.subprocess.run = lambda cmd, **kw: (calls.append(list(cmd)), R())[1]
real.preserve_unpushed_branch = lambda bead_id: []
real._remove_label_verified = lambda bd, bead_id, lbl: True
real.time.sleep = lambda s: None
try:
    real.do_reclaim("wa-t1", "t", 0, 30.0, ["story:in-flight", "pilot:dispatched"], unset_metadata=(MARK,))
    err = ""
except TypeError as exc:
    err = str(exc)
um = [c for c in calls if "--unset-metadata" in c]
check("do_reclaim aceita unset_metadata", err == "", err)
check("do_reclaim: bd update <bead> --unset-metadata pilot.wa_node_alias", any(c[:3] == ["bd", "update", "wa-t1"] and MARK in c for c in um), "chamadas=%r" % um)
i_assign = next((i for i, c in enumerate(calls) if c[:2] == ["bd", "assign"]), -1)
i_unset = next((i for i, c in enumerate(calls) if "--unset-metadata" in c), -1)
check("do_reclaim: a marca sai DEPOIS de o dono sair", 0 <= i_assign < i_unset, "assign=%d unset=%d" % (i_assign, i_unset))
calls.clear()
real.do_reclaim("wa-t1", "t", 0, 30.0, ["story:in-flight", "pilot:dispatched"])
check("do_reclaim sem unset_metadata não mexe em metadata (as outras beads não mudam)", not [c for c in calls if "--unset-metadata" in c], "chamadas=%r" % calls)

# ── O executor de mutantes lê o guard: arquivo que não abre é FATAL rc 2, nunca "0 mutantes, todos mortos".
runner = os.path.join(os.environ["MBP_HERE"], "inflight-reclaim-guard.mbp.mutants.py")
r = REAL_RUN([sys.executable, "-I", runner], env=dict(os.environ, MBP_MUTANTS_GUARD="/nonexistent/inflight-reclaim-guard.py"),
             capture_output=True, text=True, timeout=60)
check("executor de mutantes (inflight-reclaim-guard.mbp.mutants.py): guard que não abre = FATAL rc 2, sem 'MUTANTES:'",
      r.returncode == 2 and "FATAL" in r.stdout and "MUTANTES:" not in r.stdout, "rc=%d saída=%r" % (r.returncode, r.stdout[:120]))

print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
rc=$?
if [ "$rc" = 0 ] && [ "${MBP_GUARD_ST_NOMUT:-0}" != 1 ] && [ -f "$HERE/inflight-reclaim-guard.mbp.mutants.py" ]; then
  python3 -I "$HERE/inflight-reclaim-guard.mbp.mutants.py" || rc=1
fi
exit "$rc"
