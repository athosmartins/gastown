#!/usr/bin/env python3
"""false-executing-watchdog.selftest.py — selftest do false-executing-watchdog.py (ga-9exarbg).

Planejamento puro em tabela; run_cycle por um mundo falso (a seam `_run`) cujo `bd`/`gc` FALHAM de todo jeito; e o script de verdade
como subprocesso com `gc`/`bd` de mentira. "Leitura falhou" jamais vira "nada em andamento", "crew ociosa" ou "mail enviado".
Uso:  python3 false-executing-watchdog.selftest.py      (rc 0 = verde; FALSE_EXEC_UNDER_TEST=<copia> roda um mutante)
"""
import fcntl, importlib.util, io, json, os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("FALSE_EXEC_UNDER_TEST", os.path.join(HERE, "false-executing-watchdog.py"))
sys.path.insert(0, HERE)
_spec = importlib.util.spec_from_file_location("false_exec_under_test", SCRIPT)
W = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(W)
W.GC_BIN, W.BD_BIN, W.CITY = "gc", "bd", "/c"   # o ambiente do nó já exporta GC_BIN/BD_BIN: o teste fixa os seus

NOW, H = 1_790_000_000, 3600
OK, BAD = [0], []
TMP = tempfile.mkdtemp(prefix="fe-selftest-")


def check(name, cond, extra=""):
    if cond:
        OK[0] += 1
    else:
        BAD.append(name)
        print("  FAIL %s %s" % (name, extra))


def iso(ago, off=False):
    t = NOW - ago
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t - 3 * H)) + "-03:00" if off else time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def B(i, who="batista-wa", ago=7 * H, labels=(), typ="task", status="in_progress", **kw):
    return dict({"id": i, "assignee": who, "status": status, "issue_type": typ, "updated_at": iso(ago), "labels": list(labels)}, **kw)


def S(name, state="active", ago=3 * H, attached=False, closed=False, template=None, off=False):
    return {"name": name, "session_name": name, "template": template or name, "state": state, "closed": closed, "attached": attached,
            "last_active": "0001-01-01T00:00:00Z" if ago is None else iso(ago, off)}


CREWS = frozenset({"batista-wa", "thies-wa", "mila-wa", "digo-wa"})
ROSTER = [S("batista-wa", ago=5 * H), S("thies-wa", state="asleep", ago=None), S("mila-wa", ago=600), S("digo-wa", ago=None), S("gastown.mayor", ago=10)]
STATES = dict((c, W.crew_state(c, ROSTER, NOW)) for c in CREWS)
print("== false-executing-watchdog selftest ==")

# crew_state
for name, roster, want in [
    ("sem sessão -> absent", [], "absent"),
    ("só sessão fechada -> absent", [S("batista-wa", closed=True)], "absent"),
    ("parada 3 h -> idle", [S("batista-wa")], "idle"),
    ("parada 10 min -> busy", [S("batista-wa", ago=600)], "busy"),
    ("anexada a humano -> busy", [S("batista-wa", attached=True)], "busy"),
    ("last_active zero (sentinela do Go) em sessão ativa -> unknown", [S("batista-wa", ago=None)], "unknown"),
    ("last_active lixo -> unknown", [dict(S("batista-wa"), last_active="garbage")], "unknown"),
    ("dormindo -> asleep", [S("batista-wa", state="asleep", ago=None)], "asleep"),
    ("estado exótico -> unknown", [S("batista-wa", state="creating")], "unknown"),
    ("dormindo + ativa parada -> idle (conta a viva)", [S("batista-wa", state="asleep", ago=None), S("batista-wa-gawispabc", ago=4 * H)], "idle"),
    ("duas vivas, uma ocupada -> busy", [S("batista-wa", ago=4 * H), S("batista-wa-gawispabc", ago=60)], "busy"),
    ("casa por template", [S("x-1", template="batista-wa")], "idle"),
    ("outra crew de nome parecido não casa", [S("batista-wa2"), S("batista-ps")], "absent"),
    ("timestamp com offset local (dialeto do gc)", [S("batista-wa", off=True)], "idle"),
    ("parada exatamente IDLE_SEC -> idle (>=)", [S("batista-wa", ago=W.IDLE_SEC)], "idle"),
    ("parada IDLE_SEC - 1 s -> busy", [S("batista-wa", ago=W.IDLE_SEC - 1)], "busy"),
    ("uma parada e outra de idade desconhecida -> unknown (não chuta)", [S("batista-wa", ago=4 * H), S("batista-wa-gawispabc", ago=None)], "unknown"),
]:
    st = W.crew_state("batista-wa", roster, NOW)
    check("crew_state: " + name, st[0] == want, str(st))
check("crew_state: idle devolve idade e nome da sessão", W.crew_state("batista-wa", [S("batista-wa", ago=5 * H)], NOW) == ("idle", 5 * H, "batista-wa"))


# classify: 1 linha = 1 bead
def run(b, states=STATES, crews=CREWS):
    f, why = W.classify(b, NOW, crews, states)
    return (f["kind"] if f else None), why, f


for name, b, want in [
    ("crew ociosa + bead 7 h -> idle-holder", B("a"), "idle-holder"),
    ("bead 30 h -> idle-holder", B("a", ago=30 * H), "idle-holder"),
    ("bead 5 h (recente) -> nada", B("a", ago=5 * H), None),
    ("crew ocupada -> nada", B("a", who="mila-wa"), None),
    ("crew de idade de sessão desconhecida -> nada (não chuta)", B("a", who="digo-wa"), None),
    ("crew dormindo + bead velha -> idle-holder (só mail)", B("a", who="thies-wa"), "idle-holder"),
    ("rótulos de pilot (story:in-flight, pilot:dispatched) são normais", B("a", labels=["story:in-flight", "pilot:dispatched"]), "idle-holder"),
    ("gate:needs-fix é vez da crew", B("a", labels=["gate:needs-fix"]), "idle-holder"),
    ("bd omite a chave labels -> sem rótulo, não ilegível", {k: v for k, v in B("a").items() if k != "labels"}, "idle-holder"),
    ("estacionada (blocked:*) -> nada", B("a", labels=["blocked:external"]), None),
    ("no gate (gate:queued) -> nada", B("a", labels=["gate:queued"]), None),
    ("reclaim esgotado (pilot:reclaim-count:3) -> nada", B("a", labels=["pilot:reclaim-count:3"]), None),
    ("dono é worker efêmero -> nada", B("a", who="dog-remote-1"), None),
    ("dono é o mayor -> nada", B("a", who="gastown.mayor"), None),
    ("épico -> nada", B("a", typ="epic"), None),
    ("sem dono -> nada (é o R3)", B("a", who=""), None),
    ("dono que não é texto -> nada", B("a", who=5), None),
    ("updated_at lixo -> nada", B("a", updated_at="ontem"), None),
    ("updated_at ausente -> nada", B("a", updated_at=None), None),
    ("labels que não é lista -> nada", dict(B("a"), labels="story:done"), None),
    ("bead open com story:done -> nada (só in_progress)", B("a", status="open", ago=2 * H, labels=["story:done"]), None),
    ("bead closed com next-action:athos -> nada", B("a", status="closed", ago=2 * H, labels=["next-action:athos"]), None),
    ("next-action:athos há 2 h -> athos-turn", B("a", ago=2 * H, labels=["next-action:athos"]), "athos-turn"),
    ("next-action:athos-decide (o sufixo do Pilot) -> athos-turn", B("a", ago=2 * H, labels=["next-action:athos-decide"]), "athos-turn"),
    ("story:needs-approval (vocabulário do bead_state) -> athos-turn", B("a", ago=2 * H, labels=["story:needs-approval"]), "athos-turn"),
    ("gate:needs-human:product -> athos-turn", B("a", ago=2 * H, labels=["gate:needs-human:product"]), "athos-turn"),
    ("athos-turn de worker efêmero também conta", B("a", who="dog-remote-1", ago=2 * H, labels=["next-action:athos"]), "athos-turn"),
    ("next-action:mayor não é do Athos", B("a", labels=["next-action:mayor"]), None),
    ("story:done há 2 h -> delivered", B("a", ago=2 * H, labels=["story:done"]), "delivered"),
    ("story:done + delivery:partial -> nada (falta parte)", B("a", ago=2 * H, labels=["story:done", "delivery:partial"]), None),
    ("story:done + next-action:athos -> delivered ganha", B("a", ago=2 * H, labels=["story:done", "next-action:athos"]), "delivered"),
    ("story:done em épico -> nada", B("a", ago=2 * H, labels=["story:done"], typ="epic"), None),
]:
    kind, why, f = run(b)
    check("classify: " + name, kind == want, "got %s/%s" % (kind, why))
for lbl, sec, lab, want in [("STALE_SEC", W.STALE_SEC, [], "idle-holder"), ("GRACE_SEC athos", W.GRACE_SEC, ["next-action:athos"], "athos-turn"),
                            ("GRACE_SEC delivered", W.GRACE_SEC, ["story:done"], "delivered")]:
    check("classify: fronteira %s: exato (>=) acha, 1 s antes não" % lbl, run(B("a", ago=sec, labels=lab))[0] == want and run(B("a", ago=sec - 1, labels=lab))[0] is None)
f = run(B("a", ago=30 * H))[2]
check("classify: >24 h marca o tier e carrega crew/idade/sessão", f["tier"] == "devolver" and f["crew"] == "batista-wa" and f["idle"] == 5 * H and f["sess"] == "batista-wa")
check("classify: tier devolver a partir de RETURN_SEC (>=), antes não", run(B("a", ago=W.RETURN_SEC))[2]["tier"] == "devolver" and run(B("a", ago=W.RETURN_SEC - 1))[2]["tier"] == "")
check("classify: sem roster (states=None) idle-holder desliga", run(B("a"), states=None)[:2] == (None, "idle-holder-desligado"))
check("classify: sem roster, athos-turn e delivered seguem",
      run(B("a", ago=2 * H, labels=["next-action:athos"]), states=None)[0] == "athos-turn" and run(B("a", ago=2 * H, labels=["story:done"]), states=None)[0] == "delivered")
check("classify: crews desconhecidas (frozenset vazio) -> dono não é crew", run(B("a"), crews=frozenset())[:2] == (None, "dono-nao-e-crew"))
f = run(B("a|b\nINJECT", who="x y|z", ago=2 * H, labels=["story:done"]))[2]
check("classify: id/dono do bd entram saneados (sem '|' nem quebra de linha: a chave do estado e o log dependem disso)",
      f["id"] == "a?b?INJECT" and f["who"] == "x?y?z" and W._key(dict(f, store="wa")).count("|") == 2, str(f))
check("classify: nome com sufixo -gawisp resolve a crew", run(B("a", who="batista-wa-gawispxyz"))[0] == "idle-holder")

# plan
beads = {"wa": [B("wa-1", ago=30 * H), B("wa-2"), B("wa-3", who="mila-wa"), B("wa-4", ago=2 * H, labels=["story:done"], who="dog-remote-1")],
         "hq": [B("ga-1", who="dog-remote-1"), B("ga-2", who="thies-wa", ago=50 * H)], "down": None}
found, stats = W.plan(beads, CREWS, ROSTER, NOW)
check("plan: achados em ordem de seção, crew e idade", [f["id"] for f in found] == ["wa-1", "wa-2", "ga-2", "wa-4"], str([f["id"] for f in found]))
check("plan: loja ilegível (None) não acha nem conta como vazia", all(f["store"] != "down" for f in found))
check("plan: motivos de não-achado contados", stats.get("crew-busy") == 1 and stats.get("dono-nao-e-crew") == 1, str(stats))
orig = W.BS.derive
W.BS.derive = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("registro torto"))
found2, stats2 = W.plan({"wa": [B("wa-1"), B("wa-5", ago=2 * H, labels=["story:done"])]}, CREWS, ROSTER, NOW)
W.BS.derive = orig
check("plan: exceção num registro não derruba a rodada (conta como erro e segue)", [f["id"] for f in found2] == ["wa-5"] and stats2.get("erro:RuntimeError") == 1)

# reconcile
def rec(state, fnd, now=NOW, fresh=("wa", "hq"), roster_ok=True):
    return W.reconcile(state, fnd, now, set(fresh), roster_ok)


E = {"findings": {}, "nudged": {}}
st1, nud, listed, fresh_k = rec(E, found)
check("reconcile: 1ª rodada lista tudo, todas novas", len(listed) == 4 and len(fresh_k) == 4 and all(v["mailed"] == 0 for v in st1["findings"].values()))
check("reconcile: nudge só à crew com sessão ativa e ociosa (a dormindo só recebe mail), e fica registrado", nud == ["batista-wa"] and st1["nudged"] == {"batista-wa": NOW}, str(nud))
mailed = {"findings": dict((k, dict(v, mailed=NOW)) for k, v in st1["findings"].items()), "nudged": st1["nudged"]}
_, nud, listed, fresh_k = rec(mailed, found, NOW + 900)
check("reconcile: rodada seguinte sem novidade -> sem mail, sem nudge (cooldown)", not listed and not nud and not fresh_k)
_, nud, listed, _ = rec(mailed, found, NOW + 25 * H)
check("reconcile: após 24 h o mail volta como lembrete e o nudge após o cooldown", len(listed) == 4 and nud == ["batista-wa"])
_, nud, listed, fresh_k = rec(mailed, found + [dict(found[0], id="wa-9")], NOW + 900)
check("reconcile: achado novo reabre o mail com a lista toda", len(listed) == 5 and len(fresh_k) == 1)
st5, _, _, _ = rec(mailed, [f for f in found if f["id"] != "wa-1"])
check("reconcile: achado que sumiu (loja lida) sai do estado", not any(k.endswith("|wa|wa-1") for k in st5["findings"]))
st6, _, _, _ = rec(mailed, [], fresh=("hq",))
check("reconcile: loja que não respondeu mantém seus achados (não sei ≠ resolvido)", any(k.endswith("|wa|wa-1") for k in st6["findings"]) and not any("|hq|" in k for k in st6["findings"]))
st7, _, _, _ = rec(mailed, [], roster_ok=False)
check("reconcile: roster ilegível mantém o idle-holder mas libera athos/delivered resolvidos",
      any(k.startswith("idle-holder|") for k in st7["findings"]) and not any(k.startswith("delivered|") for k in st7["findings"]))
_, nud, _, _ = rec(E, [dict(found[1], crew="c%d" % i, id="m%d" % i) for i in range(7)])
check("reconcile: teto de nudges por rodada", len(nud) == W.MAX_NUDGES)
_, nud, _, _ = rec({"findings": {}, "nudged": {"batista-wa": NOW - 3 * H}}, found)
check("reconcile: nudge de 3 h atrás ainda está no cooldown", nud == [])
st8, _, _, _ = rec({"findings": {}, "nudged": {"velha": NOW - 8 * 86400}}, [])
check("reconcile: nudge de mais de 7 dias é esquecido", "velha" not in st8["nudged"])
_, _, listed, _ = rec({"findings": dict((k, dict(v, mailed=0)) for k, v in mailed["findings"].items()), "nudged": {}}, found, NOW + 900)
check("reconcile: mail que não saiu (mailed=0) volta na rodada seguinte", len(listed) == 4)

# textos
mail = W.format_mail(found, {W._key(found[0])})
check("mail: diz que é só detecção", "SÓ DETECÇÃO" in mail and "nenhuma bead foi alterada" in mail)
check("mail: seção, crew com a idade da sessão, bead com idade e marca de nova",
      "CREW OCIOSA" in mail and "batista-wa [sessão ativa, parada há 5h]" in mail and "wa-1 (30h) [nova] [>24h: candidata a devolver]" in mail, mail)
check("mail: crew dormindo diz que não há sessão ativa", "thies-wa [sem sessão ativa (dormindo)]" in mail and "Remédio: gc session peek" in mail)
check("mail: delivered traz o dono", "wa-4 (dono dog-remote-1, 2h)" in mail and "ENTREGUE" in mail)
check("mail: lista longa é cortada com +N", "+3" in W.format_mail([dict(found[1], id="x%d" % i) for i in range(W.MAX_LIST + 3)], set()))
nd = W.format_nudge([f for f in found if f["crew"] == "batista-wa"])
check("nudge: ids com idade, instrução de devolver e de estacionar", "wa-1 (30h)" in nd and "wa-2 (7h)" in nd and "parada há 5h" in nd
      and "--status open --assignee" in nd and "next-action:athos" in nd and "athos.acao" in nd)

# leituras: três estados
check("_loads: vazio e lixo -> None", all(W._loads(x) is None for x in ("", "  ", "garbage", None, 'oops [{"id":"a"}]')))
check("_loads: array com linha-resumo depois (bd) -> o array", W._loads('[{"id":"a"}]\nShowing 1 issues') == [{"id": "a"}])
fake = {"out": None}
W._run = lambda argv, t: fake["out"]
for fn, out, want, name in [
    (lambda: W._in_progress("/p"), (0, "[]"), [], '"[]" -> [] (nada em andamento)'), (lambda: W._in_progress("/p"), (0, ""), None, "vazio -> None"),
    (lambda: W._in_progress("/p"), (1, "[]"), None, "rc 1 -> None"), (lambda: W._in_progress("/p"), None, None, "não rodou/estourou o tempo -> None"),
    (lambda: W._in_progress("/p"), (0, "garbage"), None, "lixo -> None"), (lambda: W._in_progress("/p"), (0, '{"a":1}'), None, "objeto no lugar de lista -> None"),
    (lambda: W._in_progress("/p"), (0, '[1,{"id":"a"},"x"]'), [{"id": "a"}], "elementos que não são objeto são descartados"),
    (W._roster, (0, '{"sessions":[{"name":"a"}]}'), [{"name": "a"}], "roster: envelope sessions"), (W._roster, (0, '[{"name":"a"}]'), [{"name": "a"}], "roster: array puro"),
    (W._roster, (0, '{"sessions":[]}'), None, "roster: vazio é inventado -> None"), (W._roster, (0, "[]"), None, "roster: [] -> None"),
    (W._roster, (1, '[{"name":"a"}]'), None, "roster: rc 1 -> None"), (W._roster, (0, "garbage"), None, "roster: lixo -> None"), (W._roster, None, None, "roster: não rodou -> None"),
    (W._stores, (0, '{"rigs":[{"name":"x","path":"/x"},{"name":"hq","path":"/c/","hq":true},{"name":"x2","path":"/x"}]}'), [("hq", W.CITY), ("x", "/x")], "stores: pula o hq (path escrito diferente) e a duplicata"),
    (W._stores, (0, '{"rigs":[]}'), [("hq", W.CITY)], "stores: sem rigs -> só o HQ"), (W._stores, (1, "{}"), None, "stores: rc 1 -> None"),
    (W._stores, (0, "garbage"), None, "stores: lixo -> None"), (W._stores, (0, '{"rigs":"x"}'), None, "stores: rigs que não é lista -> None"),
]:
    fake["out"] = out
    check("leitura: " + name, fn() == want, str(fn()))
W._run = None
ag = os.path.join(TMP, "agents")
for n, body in [("crew-a", 'work_dir = "/g/wa/crew/batista"\nmax_active_sessions = 1\n'), ("crew-b", 'work_dir = "/g/wa/crew/mila"\n'),
                ("pool", 'work_dir = "/g/wa/crew/worker"\nmax_active_sessions = 1\n'), ("elastic", 'work_dir = "/g/wa/crew/x"\nmax_active_sessions = 4\n'),
                ("rev", 'work_dir = "/g/wa/gate-reviewer"\nmax_active_sessions = 1\n'), ("bad-toml", "garbage = {{{\n"), ("no-toml", None)]:
    os.makedirs(os.path.join(ag, n))
    if body:
        open(os.path.join(ag, n, "agent.toml"), "w").write(body)
check("_crews: só work_dir .../crew/<slug> (slug != worker) e max_active_sessions <= 1", W._crews(ag) == frozenset({"crew-a", "crew-b"}), str(W._crews(ag)))
check("_crews: pasta inexistente (/nonexistent) -> None, não 'sem crews'", W._crews(os.path.join(TMP, "nonexistent")) is None)
os.makedirs(os.path.join(TMP, "empty-agents"))
check("_crews: pasta vazia -> frozenset() (lido, e sem crew)", W._crews(os.path.join(TMP, "empty-agents")) == frozenset())
real = W._crews(os.path.join(HERE, "..", "agents"))
check("_crews: controle positivo no agents/ do repositório (crews sim, pools não)",
      real is not None and len(real) >= 5 and not real & {"wa-worker", "ps-worker", "dog-remote", "gate-reviewer", "auto-refiner"}, str(real))

# estado
W.STATE_PATH = os.path.join(TMP, "st", "state.json")
check("_load_state: ausente -> vazio (1ª rodada)", W._load_state() == E)
check("_save_state: grava, relê e confere", W._save_state(st1) is True and W._load_state() == st1)
_ld = W._load_state
W._load_state = lambda: {"findings": {}, "nudged": {}}
check("_save_state: releitura diferente do escrito -> False (o rc de uma escrita já mentiu)", W._save_state(st1) is False)
W._load_state = _ld
for name, body in [("lixo", "garbage {{{"), ("vazio", ""), ("lista", "[]"), ("sem nudged", '{"findings":{}}'), ("chave sem 2 pipes", '{"findings":{"a|b":{"mailed":0}},"nudged":{}}'),
                   ("entrada que não é objeto", '{"findings":{"a|b|c":"x"},"nudged":{}}'), ("mailed texto", '{"findings":{"a|b|c":{"mailed":"1"}},"nudged":{}}'),
                   ("nudged texto", '{"findings":{},"nudged":{"c":"1"}}'), ("mailed booleano", '{"findings":{"a|b|c":{"mailed":true}},"nudged":{}}')]:
    open(W.STATE_PATH, "w").write(body)
    check("_load_state: %s -> None (ilegível, nunca 'estado novo')" % name, W._load_state() is None)
open(os.path.join(TMP, "blocker"), "w").write("x")
W.STATE_PATH = os.path.join(TMP, "blocker", "sub", "state.json")
check("_save_state: caminho impossível -> False (nada é dado como gravado)", W._save_state(st1) is False)


# run_cycle por um mundo falso
class World:
    def __init__(self, **kw):
        self.calls, self.mail_rc, self.nudge = [], 0, (0, '{"ok":true,"outcome":"delivered"}')
        self.rigs = (0, json.dumps({"rigs": [{"name": "hq", "path": "/c", "hq": True}, {"name": "wa", "path": "/wa"}]}))
        self.roster = (0, json.dumps({"sessions": ROSTER}))
        self.stores = {"/c": [B("ga-1", who="dog-remote-1")], "/wa": [B("wa-1", ago=30 * H), B("wa-2"), B("wa-3", who="thies-wa", ago=50 * H),
                                                                       B("wa-4", who="dog-remote-2", ago=2 * H, labels=["next-action:athos"]), B("wa-5", ago=2 * H, labels=["story:done"])]}
        self.stores.update(kw.pop("stores", {}))
        self.__dict__.update(kw)

    def __call__(self, argv, timeout):
        self.calls.append(argv)
        if argv[:3] == ["gc", "rig", "list"]:
            return self.rigs
        if argv[0] == "bd":
            d = self.stores.get(argv[2], (0, "[]"))   # loja que o mundo não conhece: existe e está vazia
            return d if isinstance(d, tuple) else (0, json.dumps(d))
        if argv[:3] == ["gc", "session", "list"]:
            return self.roster
        if argv[:3] == ["gc", "session", "nudge"]:
            return self.nudge
        if argv[:3] == ["gc", "mail", "send"]:
            return None if self.mail_rc is None else (self.mail_rc, "")
        raise AssertionError("comando inesperado %r" % argv)

    def sent(self, what):
        return [c for c in self.calls if c[1:3] == what]


def go(tag, now=NOW, dry=False, **kw):
    """Uma rodada num mundo falso, com o estado em TMP/<tag>/ (a mesma tag = o mesmo estado, rodadas encadeadas). -> (mundo, rc, log)."""
    W.STATE_PATH = os.path.join(TMP, tag, "state.json")
    w = World(**kw)
    W._run, W.DRY_RUN = w, dry
    buf, old = io.StringIO(), sys.stdout
    sys.stdout = buf
    try:
        rc = W.run_cycle(now)
    finally:
        sys.stdout, W._run, W.DRY_RUN = old, None, False
    return w, rc, buf.getvalue()


def nothing_sent(w):
    return not w.sent(["mail", "send"]) and not w.sent(["session", "nudge"])


W.AGENTS_DIR = os.path.join(TMP, "agents-run")
for n in ("batista-wa", "thies-wa", "mila-wa"):
    os.makedirs(os.path.join(W.AGENTS_DIR, n))
    open(os.path.join(W.AGENTS_DIR, n, "agent.toml"), "w").write('work_dir = "/g/wa/crew/%s"\n' % n)
w, rc, log = go("run1")
check("run_cycle: golden path rc 0 e 1 mail", rc == 0 and len(w.sent(["mail", "send"])) == 1, log)
m = w.sent(["mail", "send"])[0]
check("run_cycle: mail ao mayor com --notify e assunto com os números", m[3] == "mayor" and m[-1] == "--notify" and "5 bead(s)" in m[5] and "5 nova(s)" in m[5], str(m[:6]))
nudges = w.sent(["session", "nudge"])
check("run_cycle: 1 nudge, à sessão ociosa e ativa, wait-idle e --json (a dormindo e a ocupada não)",
      len(nudges) == 1 and nudges[0][3] == "batista-wa" and nudges[0][-3:] == ["--delivery", "wait-idle", "--json"] and "wa-1" in nudges[0][4])
check("run_cycle: lê cada loja com --status in_progress --limit 0 (não os 50 do default)",
      [c for c in w.calls if c[0] == "bd"] == [["bd", "-C", p, "list", "--status", "in_progress", "--limit", "0", "--json"] for p in ("/c", "/wa")])
check("run_cycle: ALERT só das novas, no .out", log.count("ALERT ") == 5 and "ALERT idle-holder wa/wa-1" in log and "NUDGE batista-wa: delivered" in log)
check("run_cycle: estado gravado com mailed e nudge", W._load_state()["nudged"] == {"batista-wa": NOW} and all(v["mailed"] == NOW for v in W._load_state()["findings"].values()))
w, rc, log = go("run1", NOW + 900)
check("run_cycle: 2ª rodada sem novidade não manda nada", rc == 0 and nothing_sent(w) and "ALERT" not in log)
w, rc, log = go("run1", NOW + 25 * H)
check("run_cycle: 24 h depois: lembrete de mail (0 novas, sem ALERT repetido) e novo nudge",
      len(w.sent(["mail", "send"])) == 1 and "0 nova(s)" in w.sent(["mail", "send"])[0][5] and len(w.sent(["session", "nudge"])) == 1 and "ALERT" not in log)
w, rc, log = go("run2", dry=True)
check("run_cycle: DRY_RUN não manda, não grava e diz o que faria", rc == 0 and nothing_sent(w) and not os.path.exists(W.STATE_PATH) and "DRY_RUN" in log and "batista-wa" in log)
w, rc, log = go("run3", mail_rc=1)
check("run_cycle: mail que falha não é dado como enviado", "gc mail send falhou" in log and all(v["mailed"] == 0 for v in W._load_state()["findings"].values()))
w, rc, log = go("run3", NOW + 900)
check("run_cycle: ... e a rodada seguinte tenta o mail de novo, sem repetir o nudge", len(w.sent(["mail", "send"])) == 1 and not w.sent(["session", "nudge"]))
for name, nudge, want in [("queued", (0, '{"ok":true,"outcome":"queued"}'), "queued"), ("rc 1", (1, ""), "failed"), ("lixo", (0, "garbage"), "unreadable"),
                          ("ok false", (0, '{"ok":false,"outcome":"delivered"}'), "unreadable"), ("outcome fora do enum", (0, '{"ok":true,"outcome":"read"}'), "unreadable"),
                          ("não rodou", None, "failed")]:
    check("run_cycle: nudge %s -> %s (só o outcome do gc vale como entregue)" % (name, want), "NUDGE batista-wa: %s" % want in go("n-" + name.replace(" ", ""), nudge=nudge)[2])
_ss, calls_n = W._save_state, [0]
W._save_state = lambda st: (calls_n.__setitem__(0, calls_n[0] + 1) or calls_n[0] == 1) and _ss(st)
w, rc, log = go("run4")
W._save_state = _ss
check("run_cycle: o mail saiu mas o estado não gravou -> rc 1 (a próxima rodada o repete, e o log diz)", rc == 1 and len(w.sent(["mail", "send"])) == 1 and "MAIL ao mayor" in log)
w, rc, log = go("run5", roster=(1, ""))
check("run_cycle: gc session list falhou -> sem nudge, sem idle-holder; athos-turn e delivered ainda saem no mail",
      rc == 0 and not w.sent(["session", "nudge"]) and len(w.sent(["mail", "send"])) == 1 and "2 bead(s)" in w.sent(["mail", "send"])[0][5] and "DEGRADED" in log, log)
w, rc, log = go("run6", rigs=(1, ""))
check("run_cycle: gc rig list falhou -> HQ + lista estática, dito em voz alta", "DEGRADED stores" in log and [c[2] for c in w.calls if c[0] == "bd"][:2] == ["/c", "/Users/athos/gt/whatsapp_automation"])
w, rc, log = go("run7", stores={"/wa": (1, "")})
check("run_cycle: uma loja ilegível é pulada e contada; a outra segue (rc 1: cego em parte e sem nada a mostrar)", "ilegiveis=1" in log and "loja pulada" in log and rc == 1)
w, rc, log = go("run8", stores={"/wa": (0, "garbage"), "/c": (0, "")})
check("run_cycle: nenhuma loja legível -> rc 1, nem lê o roster, nada enviado", rc == 1 and not w.sent(["session", "list"]) and nothing_sent(w))
os.makedirs(os.path.join(TMP, "run9"))
open(os.path.join(TMP, "run9", "state.json"), "w").write("corrupt {{{")
w, rc, log = go("run9")
check("run_cycle: estado corrompido -> nada é enviado, arquivo posto de lado", rc == 0 and nothing_sent(w) and os.path.exists(W.STATE_PATH + ".corrupt") and "STATE-ERROR" in log)
check("run_cycle: ... e a rodada seguinte recomeça limpa e envia", len(go("run9")[0].sent(["mail", "send"])) == 1)
open(os.path.join(TMP, "run9", "state.json"), "w").write("corrupt {{{")
w, rc, log = go("run9", dry=True)
check("run_cycle: DRY_RUN com estado corrompido não renomeia nem escreve; mostra o que sairia", rc == 0 and nothing_sent(w) and open(W.STATE_PATH).read() == "corrupt {{{" and "batista-wa" in log)
w, rc, log = go("blocker/x")
check("run_cycle: estado que não grava -> rc 1 e nada é enviado (nudge sem registro se repetiria)", rc == 1 and nothing_sent(w))
os.makedirs(os.path.join(TMP, "ro"))
W.STATE_PATH = os.path.join(TMP, "ro", "state.json")
W._save_state(E)
os.chmod(os.path.join(TMP, "ro"), 0o555)
w, rc, log = go("ro")
os.chmod(os.path.join(TMP, "ro"), 0o755)
if os.geteuid() == 0:  # root escreve em pasta sem permissão: o cenário não existe, e isto fica dito em vez de passar calado
    print("  SKIP pasta do estado chmod 555 (rodando como root)")
else:
    check("run_cycle: pasta do estado sem permissão de escrita (chmod 555) -> rc 1 e nada é enviado", rc == 1 and nothing_sent(w), log)
bs, W.BS = W.BS, None
check("run_cycle: bead_state não importou -> rc 1", go("run10")[1] == 1)
W.BS = bs

# o encanamento de verdade
check("_sh: binário inexistente (/nonexistent) -> None", W._sh(["/nonexistent/bin"], 5) is None)
check("_sh: estourou o tempo -> None", W._sh([sys.executable, "-c", "import time; time.sleep(5)"], 1) is None)
real_run = subprocess.run
subprocess.run = lambda *a, **k: (_ for _ in ()).throw(subprocess.TimeoutExpired("gc", 1))
check("_sh: TimeoutExpired -> None, não levanta", W._sh(["gc", "x"], 1) is None)
subprocess.run = real_run
check("_sh: comando que roda devolve (rc, stdout)", W._sh([sys.executable, "-c", "print('oi')"], 10) == (0, "oi\n"))
bin_dir, calls = os.path.join(TMP, "bin"), os.path.join(TMP, "calls.log")
os.makedirs(bin_dir)
FAKE = '#!%s\nimport json, os, sys\nopen(%r, "a").write(os.path.basename(sys.argv[0]) + " " + json.dumps(sys.argv[1:]) + "\\n")\n' % (sys.executable, calls)
open(os.path.join(bin_dir, "bd"), "w").write(FAKE + 'print(json.dumps([{"id":"wa-5","assignee":"x","status":"in_progress","issue_type":"task","labels":["story:done"],"updated_at":"2020-01-01T00:00:00Z"}]))\n')
open(os.path.join(bin_dir, "gc"), "w").write(FAKE + 'a = sys.argv[1:]\nif a[:2] == ["rig", "list"]: print(json.dumps({"rigs": []}))\nelif a[:2] == ["session", "list"]: print(json.dumps({"sessions": [{"name": "gastown.mayor", "state": "active", "last_active": "2020-01-01T00:00:00Z"}]}))\n')
for n in ("bd", "gc"):
    os.chmod(os.path.join(bin_dir, n), 0o755)
env = dict(os.environ, GC_BIN=os.path.join(bin_dir, "gc"), BD_BIN=os.path.join(bin_dir, "bd"), GC_CITY_PATH=os.path.join(TMP, "city"), FALSE_EXEC_AGENTS_DIR=W.AGENTS_DIR)


def sub(**extra):
    return subprocess.run([sys.executable, SCRIPT], env=dict(env, **extra), capture_output=True, text=True, timeout=60)


p = sub()
check("subprocesso: roda de ponta a ponta (rc 0), loga o start primeiro e manda o mail",
      p.returncode == 0 and p.stdout.startswith("[false-exec] start ") and '"send", "mayor"' in open(calls).read(), p.stdout + p.stderr)
check("subprocesso: estado e lock caem sob GC_CITY_PATH", os.path.exists(os.path.join(TMP, "city", ".gc", "state", "false-executing-watchdog.json")))
p = sub(FALSE_EXEC_ENABLED="0")
check("subprocesso: kill-switch FALSE_EXEC_ENABLED=0 -> no-op que ainda loga o start", p.returncode == 0 and "kill-switch" in p.stdout and p.stdout.startswith("[false-exec] start "))
held = open(os.path.join(TMP, "city", ".gc", "false-executing-watchdog.lock"), "w")
fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
os.remove(calls)
p = sub()
check("subprocesso: lock segurado por outro -> sai 0 sem tocar em bd/gc", p.returncode == 0 and "outra instância" in p.stdout and not os.path.exists(calls))
fcntl.flock(held, fcntl.LOCK_UN)
shutil.rmtree(TMP, ignore_errors=True)
print("\n[false-executing-watchdog selftest] %d passed, %d failed" % (OK[0], len(BAD)))
sys.exit(1 if BAD else 0)
