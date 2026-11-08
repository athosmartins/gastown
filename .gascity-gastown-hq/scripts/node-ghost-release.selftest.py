#!/usr/bin/env python3
"""node-ghost-release.selftest.py — selftest do node-ghost-release.py (ga-moq226t).

Funções puras em tabela (vivacidade do alias, quem é fantasma, relógio); run_cycle contra um MUNDO FALSO que aplica de verdade o `bd update` (guardas --if-*, rótulos, metadata) e
falha de todo jeito (rc 1, lixo, vazio, estouro de tempo, escrita que mente ou que pega e não responde); e o script real como subprocesso. "Não consegui ler" jamais vira "sem sessão".
Leitura lenta sob carga (ga-pdyayy2): o teto das chamadas `gc` vem do plist (NODE_GHOST_CALL_TIMEOUT); o selftest lê o plist e prova cada elo: plist -> script (linha start) -> teto da chamada.
Uso:  python3 node-ghost-release.selftest.py      (rc 0 = verde; NODE_GHOST_UNDER_TEST=<copia> e NODE_GHOST_PLIST_UNDER_TEST=<copia> rodam um mutante)
"""
import fcntl, importlib.util, json, os, plistlib, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("NODE_GHOST_UNDER_TEST", os.path.join(HERE, "node-ghost-release.py"))
PLIST = os.environ.get("NODE_GHOST_PLIST_UNDER_TEST", os.path.join(HERE, "com.gascity.node-ghost-release.plist"))
sys.path.insert(0, HERE)
_spec = importlib.util.spec_from_file_location("node_ghost_under_test", SCRIPT)
N = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(N)
N.GC_BIN, N.BD_BIN, N.CITY = "gc", "bd", "/c"   # o ambiente do nó já exporta GC_BIN/BD_BIN: o teste fixa os seus
CALL_DEFAULT = N.CALL_TIMEOUT                   # o teto das chamadas `gc` como o módulo o calculou ao carregar; as seções 12-14 mexem nele e o devolvem

NOW, H = 1_790_000_000, 3600
OK, BAD, LOGS = [0], [], []
TMP = tempfile.mkdtemp(prefix="ng-selftest-")
N._log = LOGS.append

def check(name, cond, extra=""):
    if cond:
        OK[0] += 1
    else:
        BAD.append(name)
        print("  FAIL %s %s" % (name, extra))

def iso(ago):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW - ago))

def B(i, alias="wa-worker-remote-2", ago=2 * H, labels=("ctx:ready", "exec:auto", "story:approved"), typ="feature", status="in_progress", md=None, **kw):
    m = {"pilot.wa_node_alias": alias, "gc.session_name": "wa-worker-remote-gawispu43v0"} if md is None else md
    return dict({"id": i, "assignee": alias, "status": status, "issue_type": typ, "updated_at": iso(ago), "labels": list(labels), "metadata": dict(m)}, **kw)

def S(alias=None, state="active", name=None, tpl="wa-worker-remote", **kw):
    d = {"id": "ga-wisp-x%s" % (alias or name), "name": name or alias, "session_name": name or alias, "template": tpl, "state": state, "closed": False}
    if alias:
        d["alias"] = alias
    return dict(d, **kw)

R0 = [S("wa-worker-remote-4"), S("wa-worker-remote-1"), S("dog-remote-1", tpl="dog-remote"), S("gastown.mayor", tpl="mayor")]
GH = lambda **kw: dict({"id": "wa-g", "store": "whatsapp_automation", "alias": "wa-worker-remote-2", "tpl": "wa-worker-remote", "age": 2 * H, "sess": "x", "n": 0, "labels": [], "state": "stranded", "detail": "ausente"}, **kw)
KEY = "whatsapp_automation|wa-4vjmkn.4.2|wa-worker-remote-2"
print("== node-ghost-release selftest ==")

# presence: o alias tem sessão não-morta?
for name, roster, want in [
    ("sem sessão do alias -> dead", R0, "dead"),
    ("ativa -> live", [S("wa-worker-remote-2")], "live"),
    ("creating -> live (o create ainda pode terminar)", [S("wa-worker-remote-2", "creating")], "live"),
    ("start-pending -> live", [S("wa-worker-remote-2", "start-pending")], "live"),
    ("estado desconhecido -> live (nunca se conclui morte sem saber)", [S("wa-worker-remote-2", "waiting")], "live"),
    ("estado morto em maiúsculas (ASLEEP) -> dead", [S("wa-worker-remote-2", "ASLEEP")], "dead"),
    ("sessão do alias SEM template (casca re-adotada) -> live", [{"name": "casca-1", "alias": "wa-worker-remote-2", "state": "active"}], "live"),
    ("asleep -> dead", [S("wa-worker-remote-2", "asleep")], "dead"),
    ("failed-create -> dead", [S("wa-worker-remote-2", "failed-create")], "dead"),
    ("stopped -> dead", [S("wa-worker-remote-2", "stopped")], "dead"),
    ("closed=True com state active -> dead", [S("wa-worker-remote-2", closed=True)], "dead"),
    ("fechada + viva do mesmo alias -> live", [S("wa-worker-remote-2", closed=True), S("wa-worker-remote-2", name="wa-worker-remote-gawispnew")], "live"),
    ("casa por agent_name", [S(None, name="wa-worker-remote-gawispq", agent_name="wa-worker-remote-2")], "live"),
    ("casa pelo gc.session_name da bead", [S("wa-worker-remote-7", name="wa-worker-remote-gawispu43v0")], "live"),
    ("identificador que COMEÇA com o alias+'-'", [S(None, name="wa-worker-remote-2-xyz")], "live"),
    ("outro alias do mesmo template não segura", [S("wa-worker-remote-3")], "dead"),
    ("alias de outro template (ps) não segura", [S("ps-worker-remote-2", tpl="ps-worker-remote")], "dead"),
    ("sessão do MBP (com alias) não segura o alias do Hetzner", [S("wa-worker-remote-mbp-2", tpl="wa-worker-remote-mbp")], "dead"),
    ("viva do template SEM alias -> unknown (pode ser a dona)", [S(None, name="wa-worker-remote-gawispz")], "unknown"),
    ("viva SEM alias achada só pelo campo template (nome sem relação) -> unknown", [{"name": "anon-1", "template": "wa-worker-remote", "state": "active"}], "unknown"),
    ("viva SEM alias achada só pelo nome (sem template) -> unknown", [{"name": "wa-worker-remote-gawispz", "state": "active"}], "unknown"),
    ("alias que não é texto conta como sem alias -> unknown", [dict(S(None, name="wa-worker-remote-gawispz"), alias=5)], "unknown"),
    ("SEM alias mas MORTA -> dead", [S(None, "asleep", name="wa-worker-remote-gawispz")], "dead"),
    ("SEM alias de outro template -> dead", [S(None, name="dog-remote-gawispz", tpl="dog-remote")], "dead"),
    ("viva do alias E sem alias -> live", [S(None, name="wa-worker-remote-gawispz"), S("wa-worker-remote-2")], "live"),
    ("roster de lixo (itens que não são dict) -> dead", [5, "x"], "dead"),
]:
    got = N.presence("wa-worker-remote-2", "wa-worker-remote-gawispu43v0", roster, "wa-worker-remote")[0]
    check("presence: " + name, got == want, got)
check("presence: o detalhe nomeia o estado morto, ou 'ausente' quando não há sessão", N.presence("wa-worker-remote-2", "", [S("wa-worker-remote-2", "asleep")], "wa-worker-remote")[1] == "asleep"
      and N.presence("wa-worker-remote-2", "", R0, "wa-worker-remote")[1] == "ausente")

def cl(b, roster=R0):
    f, why = N.classify(b, NOW, roster)
    return (f["state"] if f else None), why, f

# classify: 1 linha = 1 bead (o que decide ser fantasma)
for name, b, roster, want in [
    ("alias sem sessão há 2 h -> fantasma", B("a"), R0, "stranded"),
    ("sem rótulo nenhum (bd omite a chave) -> fantasma", {k: v for k, v in B("a").items() if k != "labels"}, R0, "stranded"),
    ("marcas do Pilot (story:in-flight, pilot:dispatched) -> fantasma", B("a", labels=["story:in-flight", "pilot:dispatched"]), R0, "stranded"),
    ("ps-worker-remote-1 -> fantasma", B("a", alias="ps-worker-remote-1"), R0, "stranded"),
    ("gate:needs-fix (histórico) com dono morto -> fantasma", B("a", labels=["gate:needs-fix"]), R0, "gate_failed"),
    ("sessão do alias viva -> nada", B("a"), [S("wa-worker-remote-2")], None),
    ("sessão do alias criando -> nada", B("a"), [S("wa-worker-remote-2", "creating")], None),
    ("sessão viva do template sem alias -> nada (não atribuível)", B("a"), [S(None, name="wa-worker-remote-gawispz")], None),
    ("bead atualizada há GRACE-1 s -> nada (recente)", B("a", ago=N.GRACE_SEC - 1), R0, None),
    ("bead atualizada há GRACE s -> fantasma (>=)", B("a", ago=N.GRACE_SEC), R0, "stranded"),
    ("updated_at no futuro -> nada", B("a", ago=-600), R0, None),
    ("updated_at lixo -> nada", B("a", updated_at="ontem"), R0, None),
    ("updated_at ausente -> nada", B("a", updated_at=None), R0, None),
    ("status open -> nada", B("a", status="open"), R0, None),
    ("épico -> nada", B("a", typ="epic"), R0, None),
    ("dono é alias do MBP -> nada (é do guard)", B("a", alias="wa-worker-remote-mbp-1"), R0, None),
    ("dono dog-remote-1 -> nada", B("a", alias="dog-remote-1"), R0, None),
    ("dono é crew -> nada", B("a", alias="batista-wa"), R0, None),
    ("alias 0 -> nada", B("a", alias="wa-worker-remote-0"), R0, None),
    ("alias com sufixo (…-2x) -> nada", B("a", alias="wa-worker-remote-2x"), R0, None),
    ("dono vazio -> nada", B("a", alias=""), R0, None),
    ("dono que não é texto -> nada", dict(B("a"), assignee=5), R0, None),
    ("id que não é texto -> nada", dict(B("a"), id=5), R0, None),
    ("sem marca do nó -> nada (forma pool/humano: não é a que eu conheço)", B("a", md={}), R0, None),
    ("marca de OUTRO alias -> nada", B("a", md={"pilot.wa_node_alias": "wa-worker-remote-3"}), R0, None),
    ("metadata ausente -> nada", {k: v for k, v in B("a").items() if k != "metadata"}, R0, None),
    ("metadata que não é objeto -> nada", dict(B("a"), metadata="x"), R0, None),
    ("rótulos que não são lista -> nada", dict(B("a"), labels="story:done"), R0, None),
    ("no gate (gate:queued) -> nada", B("a", labels=["gate:queued"]), R0, None),
    ("gate:passed -> nada (entregue)", B("a", labels=["gate:passed"]), R0, None),
    ("story:done -> nada (entregue)", B("a", labels=["story:done"]), R0, None),
    ("delivery:tested -> nada", B("a", labels=["delivery:tested"]), R0, None),
    ("pilot:dispatching (o claim é do Pilot) -> nada", B("a", labels=["pilot:dispatching", "story:in-flight"]), R0, None),
    ("vez do Athos -> nada", B("a", labels=["next-action:athos"]), R0, None),
    ("estacionada (blocked:*) -> nada", B("a", labels=["blocked:external"]), R0, None),
    ("gate:needs-human:technical -> nada", B("a", labels=["gate:needs-human:technical"]), R0, None),
    ("reclaim esgotado (pilot:reclaim-count:3) -> nada", B("a", labels=["pilot:reclaim-count:3"]), R0, None),
]:
    st, why, _ = cl(b, roster)
    check("classify: " + name, st == want, "%r %r" % (st, why))
check("classify: feature, bug, task e chore são trabalho", all(cl(B("a", typ=t))[0] == "stranded" for t in ("feature", "bug", "task", "chore")))
check("_loads: tolera a linha-resumo depois do array e devolve None para lixo/vazio", N._loads('[1]\n3 beads') == [1] and N._loads("x") is None and N._loads("") is None and N._loads(5) is None)
check("classify: status open e épico são fora-do-escopo (o motivo, não só o veredito)", cl(B("a", status="open"))[1] == "fora-do-escopo" and cl(B("a", typ="epic"))[1] == "fora-do-escopo")
f = cl(B("a", labels=["node:ghost-count:1", "story:in-flight", "node:never"], md={"pilot.wa_node_alias": "wa-worker-remote-2", "gc.session_name": "sess-1"}))[2]
check("classify: o achado traz contagem, rótulos, sessão e template", f and (f["n"], f["sess"], f["tpl"], f["alias"], f["id"], f["detail"]) == (1, "sess-1", "wa-worker-remote", "wa-worker-remote-2", "a", "ausente") and "node:never" in f["labels"], str(f))
check("classify: contagem lixo (x / 1x) -> 0; duas contagens -> a maior", cl(B("a", labels=["node:ghost-count:x", "node:ghost-count:1x"]))[2]["n"] == 0 and cl(B("a", labels=["node:ghost-count:1", "node:ghost-count:3"]))[2]["n"] == 3)
check("classify: id com '|' e quebra de linha é higienizado (a chave do estado tem 2 '|')", N.key(dict(cl(B("a|b\nc"))[2], store="s")).count("|") == 2 and "\n" not in N.key(dict(cl(B("a|b\nc"))[2], store="s")))
for vt, n, lab, want in [(2, 0, [], False), (2, 1, [], True), (2, 1, ["node:never"], False), (3, 1, [], False), (3, 2, [], True), (0, 9, [], False), (1, 0, [], True)]:
    N.VETO_AFTER = vt
    check("classify: veto VETO_AFTER=%d n=%d %s -> %s" % (vt, n, lab, want), cl(B("a", labels=lab + (["node:ghost-count:%d" % n] if n else [])))[2]["veto"] is want)
N.VETO_AFTER = 2
real_derive = N.BS.derive
N.BS.derive = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("torto"))
fnd, stt = N.observe({"s": [B("a")]}, R0, NOW)
check("observe: registro que quebra o classificador vira 'erro' contado, não derruba a rodada", fnd == [] and stt == {"erro:RuntimeError": 1}, str(stt))
N.BS.derive = real_derive

# update_argv: a ÚNICA escrita (guardas + dono + status + marca do nó + carimbos do Pilot + rótulos)
G = lambda **kw: dict(GH(), **kw)
base = ["bd", "-C", "/r/wa", "update", "wa-g", "--if-assignee", "wa-worker-remote-2", "--if-status", "in_progress", "--assignee", "", "--status", "open",
        "--unset-metadata", "pilot.wa_node_alias", "--unset-metadata", "pilot.dispatched_at", "--unset-metadata", "pilot.dispatching_at", "--unset-metadata", "pilot.sling_bead"]
check("update_argv: forma exata (1ª devolução, sem veto)", N.update_argv(G(veto=False), "/r/wa") == base + ["--add-label", "node:ghost-count:1", "-q"], str(N.update_argv(G(veto=False), "/r/wa")))
check("update_argv: com veto põe node:never", N.update_argv(G(veto=True, n=1), "/r/wa") == base + ["--add-label", "node:ghost-count:2", "--add-label", "node:never", "-q"])
a = N.update_argv(G(veto=False, n=2, labels=["story:in-flight", "pilot:dispatched", "pilot:dispatching", "node:ghost-count:2", "node:ghost-count:x", "story:approved", "lane:small"]), "/r/wa")
check("update_argv: tira SÓ os rótulos do Pilot que existem (nunca o claim pilot:dispatching) e troca a contagem", a.count("--remove-label") == 3 and "pilot:dispatching" not in a and "story:approved" not in a and "lane:small" not in a
      and "node:ghost-count:x" not in a and "node:ghost-count:3" in a, str(a))
check("update_argv: sem rótulo do Pilot não manda --remove-label", "--remove-label" not in N.update_argv(G(labels=["story:approved"]), "/r/wa"))

# reconcile: o relógio
OLD = {KEY: {"since": NOW - 900, "seen": 3}}
g = [GH(id="wa-4vjmkn.4.2")]
W1 = {"whatsapp_automation"}
new, due_ = N.reconcile(OLD, g, NOW, W1)
check("reconcile: 4ª vista com 900 s -> vence", len(due_) == 1 and new[KEY] == {"since": NOW - 900, "seen": 4})
check("reconcile: 899 s -> ainda não; velha demais mas só a 1ª vista -> não vence (precisa de 2)", not N.reconcile({KEY: {"since": NOW - 899, "seen": 3}}, g, NOW, W1)[1] and not N.reconcile({KEY: {"since": NOW - 5000, "seen": 0}}, g, NOW, W1)[1])
check("reconcile: 1ª vista abre o relógio agora e não vence", N.reconcile({}, g, NOW, W1) == ({KEY: {"since": NOW, "seen": 1}}, []))
check("reconcile: bead que deixou de ser fantasma zera o relógio; loja ilegível -> o relógio fica como estava", N.reconcile(OLD, [], NOW, W1)[0] == {} and N.reconcile(OLD, [], NOW, set())[0] == OLD)
new, _ = N.reconcile(OLD, [GH(id="wa-4vjmkn.4.2", alias="wa-worker-remote-3")], NOW, W1)
check("reconcile: dono novo = relógio novo", list(new) == ["whatsapp_automation|wa-4vjmkn.4.2|wa-worker-remote-3"] and list(new.values())[0]["seen"] == 1)
check("reconcile: entrada com since torto recomeça", N.reconcile({KEY: {"since": "x", "seen": 9}}, g, NOW, W1)[0][KEY] == {"since": NOW, "seen": 1})
check("reconcile: os vencidos saem do mais antigo para o mais novo", [x["id"] for x in N.reconcile({"s|a|wa-worker-remote-2": {"since": NOW - 2000, "seen": 5}, "s|b|wa-worker-remote-2": {"since": NOW - 3000, "seen": 5}},
                                                                                              [GH(id="a", store="s"), GH(id="b", store="s")], NOW, {"s"})[1]] == ["b", "a"])

# ── o mundo falso ───────────────────────────────────────────────────────────────
class World:
    def __init__(self, wa=(), hq=(), roster=None):
        self.db = {"/c": [dict(b) for b in hq], "/r/wa": [dict(b) for b in wa]}
        self.rosters = [R0 if roster is None else roster]
        self.fail, self.cnt, self.calls, self.comments, self.mails, self.mail_argv, self.hooks = {}, {}, [], [], [], [], {}
        self.lie = self.late = self.partial = False   # lie: rc 0 sem aplicar · late: aplica e devolve rc 1 (resposta perdida) · partial: não tira a metadata
        self.slow, self.timeout = {}, 0               # slow: chave -> segundos que a chamada "demora" (simulados, sem dormir) · timeout: o teto que o script passou a ESTA chamada

    def go(self, key, good):
        n = self.cnt[key] = self.cnt.get(key, 0) + 1
        if "%s#%d" % (key, n) in self.hooks:   # alguém mexe na bead NESTE ponto (corrida entre a leitura e a escrita)
            self.hooks["%s#%d" % (key, n)]()
        if self.slow.get(key, 0) > self.timeout:   # demorou mais que o teto: o subprocess.run estoura e o _sh devolve None (a chamada não chega a responder)
            return None
        f = self.fail.get("%s#%d" % (key, n)) or self.fail.get(key)
        ok = lambda: good() if callable(good) else good
        if f is None or f == "rcbody":
            return (0 if f is None else 1), ok()
        if f == "other":
            return 0, json.dumps([dict(x, id="outra") for x in json.loads(ok())])
        return None if f == "timeout" else (0, "not json {") if f == "garbage" else (0, "") if f == "empty" else (1, "")

    def __call__(self, argv, timeout):
        self.calls.append(argv)
        self.timeout = timeout
        a, tool = argv[1:], argv[0]
        if tool == "gc" and a[:2] == ["rig", "list"]:
            return self.go("rig", json.dumps({"rigs": [{"name": "whatsapp_automation", "path": "/r/wa"}]}))
        if tool == "gc" and a[:2] == ["session", "list"]:
            return self.go("roster", lambda: json.dumps({"ok": True, "sessions": self.rosters[min(self.cnt["roster"] - 1, len(self.rosters) - 1)]}))
        if tool == "gc" and a[:2] == ["mail", "send"]:
            r = self.go("mail", "")
            if r and r[0] == 0:
                self.mails.append((a[4], a[6]))   # assunto, corpo (mail send mayor -s S -m B --notify)
                self.mail_argv.append(a)
            return r
        path, rest = a[1], a[2:]
        store = self.db.get(path)
        if store is None:
            return 1, ""
        if rest[:1] == ["list"]:
            return self.go("list:" + path, lambda: json.dumps([b for b in store if b["status"] == "in_progress"]))
        if rest[:1] == ["show"]:
            return self.go("show", lambda: json.dumps([b for b in store if b["id"] == rest[1]])) if [b for b in store if b["id"] == rest[1]] else (1, "")
        if rest[:1] == ["comment"]:
            r = self.go("comment", "")
            if r and r[0] == 0:
                self.comments.append((rest[1], rest[2]))
            return r
        return self.update(store, rest[1], rest[2:]) if rest[:1] == ["update"] else (1, "")

    def update(self, store, bid, flags):
        r = self.go("update", "")
        b = [x for x in store if x["id"] == bid][0]
        o, g, i = {"--add-label": [], "--remove-label": [], "--unset-metadata": []}, {}, 0
        while i < len(flags):
            if flags[i] == "-q":
                i += 1
                continue
            (o[flags[i]].append(flags[i + 1]) if flags[i] in o else g.__setitem__(flags[i], flags[i + 1]))
            i += 2
        if r is None or r[0] != 0 and not self.late:
            return r
        if "--if-assignee" in g and (b.get("assignee") or "") != g["--if-assignee"] or "--if-status" in g and b["status"] != g["--if-status"]:
            return 13, ""
        if not self.lie:
            b["assignee"], b["status"] = g["--assignee"], g["--status"]
            b["labels"] = [x for x in b["labels"] if x not in o["--remove-label"]] + o["--add-label"]
            for k in ([] if self.partial else o["--unset-metadata"]):
                b["metadata"].pop(k, None)
        return (1, "") if self.late else (0, "")

def fresh():
    d = tempfile.mkdtemp(dir=TMP)
    N.STATE_PATH = os.path.join(d, "state", "ng.json")
    del LOGS[:]
    N.DRY_RUN, N.VETO_AFTER, N.MAX_PER_RUN = False, 2, 3

def seed(keys, seen=9, since=5000):
    os.makedirs(os.path.dirname(N.STATE_PATH), exist_ok=True)
    json.dump({"ghosts": dict((k, {"since": NOW - since, "seen": seen}) for k in keys), "unmailed": []}, open(N.STATE_PATH, "w"))

def due(*beads, **kw):
    """Mundo novo com o relógio de cada bead JÁ vencido (5000 s, 9 vistas): a próxima rodada tenta soltar."""
    fresh()
    w = World(wa=list(beads), **kw)
    seed(["whatsapp_automation|%s|%s" % (b["id"], b["assignee"]) for b in beads])
    return w

def cycle(w, t=0):
    N._run = w
    return N.run_cycle(NOW + t)

state = lambda: json.load(open(N.STATE_PATH))
bead = lambda w, bid, path="/r/wa": [b for b in w.db[path] if b["id"] == bid][0]
writes = lambda w: [c for c in w.calls if "update" in c]

outs = lambda: [x.split()[0] for x in LOGS if x.split()[0] in ("RELEASE", "WOULD-RELEASE", "LOST", "FAIL", "UNCONFIRMED")]
# 1) o fantasma real (wa-4vjmkn.4.2, alias -2 sem sessão desde 13:26Z): só a 4ª vista (15 min) solta
fresh()
real = B("wa-4vjmkn.4.2", md={"gc.session_name": "wa-worker-remote-gawispu43v0", "gc.work_dir": "/x", "pilot.wa_node_alias": "wa-worker-remote-2"})
w = World(wa=[real])
rc = [cycle(w, t) for t in (0, 300, 600)]
check("real: 3 vistas (10 min) -> nada escrito, rc 0", not writes(w) and not w.mails and rc == [0, 0, 0])
check("real: o relógio abriu na 1ª vista e conta as vistas", state()["ghosts"][KEY] == {"since": NOW, "seen": 3}, str(state()))
check("real: 4ª vista (900 s) solta", cycle(w, 900) == 0 and bead(w, "wa-4vjmkn.4.2")["status"] == "open")
b = bead(w, "wa-4vjmkn.4.2")
check("real: dono vazio, aberta, sem a marca do nó; guarda gc.session_name e story:approved", not b["assignee"] and "pilot.wa_node_alias" not in b["metadata"] and b["metadata"].get("gc.session_name") and "story:approved" in b["labels"], str(b))
check("real: conta a devolução e NÃO veta na 1ª", "node:ghost-count:1" in b["labels"] and "node:never" not in b["labels"], str(b["labels"]))
check("real: comentou na bead (alias, minutos, ga-moq226t)", len(w.comments) == 1 and w.comments[0][0] == "wa-4vjmkn.4.2" and "wa-worker-remote-2" in w.comments[0][1] and "ga-moq226t" in w.comments[0][1] and "15 min" in w.comments[0][1] and "Devoluções desta bead: 1" in w.comments[0][1], str(w.comments))
check("real: loga um GHOST por fantasma e rodada, com as vistas", any("GHOST whatsapp_automation/wa-4vjmkn.4.2 alias=wa-worker-remote-2" in x and "vistas=3" in x for x in LOGS), str(LOGS[:6]))
check("real: UM mail ao mayor com o id e o alias", len(w.mails) == 1 and "wa-4vjmkn.4.2" in w.mails[0][1] and "wa-worker-remote-2" in w.mails[0][1] and "1 bead" in w.mails[0][0] and w.mail_argv[0][2] == "mayor" and "--notify" in w.mail_argv[0], str(w.mail_argv))
check("real: tirou o relógio do estado e logou RELEASE", KEY not in state()["ghosts"] and outs() == ["RELEASE"] and any(x.startswith("RELEASE whatsapp_automation/wa-4vjmkn.4.2 alias=wa-worker-remote-2") for x in LOGS))
check("real: a ÚNICA escrita é a guardada por dono e status", writes(w) == [N.update_argv(GH(id="wa-4vjmkn.4.2", labels=real["labels"], veto=False, n=0), "/r/wa")])
check("real: roda de novo -> nada mais a fazer", cycle(w, 1200) == 0 and len(writes(w)) == 1 and len(w.mails) == 1)
# 2) a forma com carimbos do Pilot (b618w / 1fw36): rótulos e metadata do despacho saem na mesma escrita
fresh()
stamped = B("wa-2f3l1s", alias="wa-worker-remote-1", labels=["story:approved", "story:in-flight", "pilot:dispatched", "lane:small"], typ="bug",
            md={"pilot.wa_node_alias": "wa-worker-remote-1", "pilot.dispatched_at": "1794052958", "pilot.sling_bead": "wa-2f3l1s", "gc.session_name": "wa-worker-remote-gawispb618w"})
w = World(wa=[stamped], roster=[S("wa-worker-remote-4"), S("wa-worker-remote-1", "failed-create", name="wa-worker-remote-gawispb618w", closed=True)])
for t in (0, 300, 600, 900):
    cycle(w, t)
b = bead(w, "wa-2f3l1s")
check("carimbada: aberta, sem dono, sem marca nem carimbos, sem story:in-flight/pilot:dispatched, mantém o resto", b["status"] == "open" and not b["assignee"] and set(b["metadata"]) == {"gc.session_name"}
      and set(b["labels"]) == {"story:approved", "lane:small", "node:ghost-count:1"}, str(b))
check("carimbada: o comentário diz o estado da sessão morta e a última sessão", "failed-create" in w.comments[0][1] and "wa-worker-remote-gawispb618w" in w.comments[0][1], w.comments[0][1])
# 3) a sessão aparece no meio: o relógio zera e nada é solto
fresh()
w = World(wa=[B("wa-4vjmkn.4.2")])
cycle(w, 0); cycle(w, 300)
w.rosters = [R0 + [S("wa-worker-remote-2", "creating")]]
cycle(w, 600)
zerou = KEY not in state()["ghosts"]
w.rosters = [R0]
cycle(w, 900); cycle(w, 1200)
check("sessão apareceu: relógio zerado; sumiu de novo: recomeça (não herda os 15 min) e nada é solto", zerou and state()["ghosts"][KEY] == {"since": NOW + 900, "seen": 2} and bead(w, "wa-4vjmkn.4.2")["status"] == "in_progress")
# 4) o que mudou ENTRE a leitura do planejamento e a escrita: a releitura desmente e nada é escrito
for name, hook in [("a sessão do alias apareceu", None),
                   ("a bead foi para o gate", lambda: bead(w, "wa-4vjmkn.4.2").update(labels=["gate:queued"])),
                   ("alguém atualizou a bead há 1 min", lambda: bead(w, "wa-4vjmkn.4.2").update(updated_at=iso(60))),
                   ("a bead foi reatribuída (sem marca coerente)", lambda: bead(w, "wa-4vjmkn.4.2").update(assignee="wa-worker-remote-3")),
                   ("a bead foi redespachada a OUTRO alias (marca coerente)", lambda: bead(w, "wa-4vjmkn.4.2").update(assignee="wa-worker-remote-3", metadata={"pilot.wa_node_alias": "wa-worker-remote-3"}))]:
    w = due(B("wa-4vjmkn.4.2"))
    if hook is None:
        w.rosters = [R0, R0 + [S("wa-worker-remote-2")]]   # a 1ª leitura (planejamento) sem a sessão, a 2ª (releitura) com ela
    else:
        w.hooks["show#1"] = hook                           # roda ANTES de a releitura montar a resposta
    cycle(w, 0)
    check("releitura: %s -> não escreve nem avisa" % name, not writes(w) and not w.mails and not w.comments and any("SKIP" in x for x in LOGS), str(LOGS[-3:]))
w = due(B("wa-4vjmkn.4.2")); w.fail["roster#2"] = "rc1"
cycle(w, 0)
check("roster ilegível só na releitura: não escreve", not writes(w) and any("SKIP" in x for x in LOGS))
w = due(B("wa-4vjmkn.4.2", labels=["story:in-flight"])); w.partial = True
cycle(w, 0)
check("limpeza incompleta (a marca ficou): solta mesmo assim e diz o que sobrou no log, na bead e no mail", bead(w, "wa-4vjmkn.4.2")["status"] == "open" and any("limpeza incompleta" in x and "pilot.wa_node_alias" in x for x in LOGS)
      and "ATENÇÃO: limpeza incompleta" in w.comments[0][1] and "ATENÇÃO: limpeza incompleta" in w.mails[0][1], str(LOGS[-3:]))
check("bd list varre com --limit 0 e --status in_progress (nunca o padrão de 50)", all("--limit" in c and c[c.index("--limit") + 1] == "0" and "in_progress" in c for c in w.calls if c[0] == "bd" and "list" in c))
# 5) ensaio: decide igual, escreve nada, MANTÉM o relógio
fresh(); N.DRY_RUN = True
w = World(wa=[B("wa-4vjmkn.4.2")])
for t in (0, 300, 600, 900):
    cycle(w, t)
check("ensaio: loga WOULD-RELEASE na 4ª vista", any("WOULD-RELEASE" in x and "wa-4vjmkn.4.2" in x for x in LOGS), str(LOGS[-4:]))
check("ensaio: nenhum update, comentário ou mail; o relógio persiste (senão o ensaio nunca mostraria nada)", not writes(w) and not [c for c in w.calls if "comment" in c or "mail" in c]
      and not w.mails and not w.comments and state()["ghosts"][KEY]["seen"] == 4 and bead(w, "wa-4vjmkn.4.2")["status"] == "in_progress")
N.DRY_RUN = False
fresh(); N.DRY_RUN = True; w = World(); seed([]); st = state(); st["unmailed"] = [{"id": "x"}]; json.dump(st, open(N.STATE_PATH, "w"))
cycle(w, 0)
check("ensaio: o aviso pendente não sai nem se perde", not w.mails and state()["unmailed"] == [{"id": "x"}])
N.DRY_RUN = False
# 6) o veto: a 2ª devolução manda a bead ao mini
for after, n_before, want in [(2, 1, True), (2, 0, False), (3, 1, False), (3, 2, True), (0, 5, False), (1, 0, True)]:
    w = due(B("wa-4vjmkn.4.2", labels=["story:approved"] + (["node:ghost-count:%d" % n_before] if n_before else [])))
    N.VETO_AFTER = after
    cycle(w, 0)
    b = bead(w, "wa-4vjmkn.4.2")
    check("veto: VETO_AFTER=%d, já devolvida %d vez(es) -> node:never=%s" % (after, n_before, want),
          ("node:never" in b["labels"]) == want and "node:ghost-count:%d" % (n_before + 1) in b["labels"] and (n_before == 0 or "node:ghost-count:%d" % n_before not in b["labels"]), str(b["labels"]))
w = due(B("wa-4vjmkn.4.2", labels=["node:never", "node:ghost-count:1"])); cycle(w, 0)
w2 = due(B("wa-4vjmkn.4.2", labels=["node:ghost-count:1"])); cycle(w2, 0)
check("veto: já tem node:never -> não duplica nem anuncia; a 2ª devolução anuncia no comentário e no mail", bead(w, "wa-4vjmkn.4.2")["labels"].count("node:never") == 1 and "veto node:never" not in w.mails[0][1]
      and "node:never" in w2.comments[0][1] and "veto node:never" in w2.mails[0][1], str(w2.comments) + str(w2.mails))
# 7) teto por rodada e duas lojas
w = due(*[B("wa-b%d" % i, alias="wa-worker-remote-%d" % (i + 5), md={"pilot.wa_node_alias": "wa-worker-remote-%d" % (i + 5)}) for i in range(4)])
N.MAX_PER_RUN = 2   # depois do due(): o fresh() dele devolve o padrão
json.dump({"ghosts": dict(("whatsapp_automation|wa-b%d|wa-worker-remote-%d" % (i, i + 5), {"since": NOW - 5000 - 100 * i, "seen": 9}) for i in range(4)), "unmailed": []}, open(N.STATE_PATH, "w"))
cycle(w, 0)
check("teto: solta no máximo MAX_PER_RUN por rodada, o de relógio mais antigo primeiro", sorted(b["id"] for b in w.db["/r/wa"] if b["status"] == "open") == ["wa-b2", "wa-b3"])
cycle(w, 300)
check("teto: o resto sai na rodada seguinte, com um mail por rodada", len([b for b in w.db["/r/wa"] if b["status"] == "open"]) == 4 and len(w.mails) == 2)
N.MAX_PER_RUN = 3
w = due(B("wa-x1"), hq=[B("ga-h1", alias="ps-worker-remote-3", md={"pilot.wa_node_alias": "ps-worker-remote-3"})])
seed(["whatsapp_automation|wa-x1|wa-worker-remote-2", "hq|ga-h1|ps-worker-remote-3"])
cycle(w, 0)
check("lojas: solta nas duas, cada uma com o seu -C", bead(w, "wa-x1")["status"] == "open" and bead(w, "ga-h1", "/c")["status"] == "open" and any(c[2] == "/c" for c in writes(w)))
# 8) terceiro estado das leituras: falhou NUNCA vira "sem sessão"
for kind in ["rc1", "garbage", "empty", "timeout", "rcbody"]:
    w = due(B("wa-4vjmkn.4.2"))
    w.fail["roster"] = kind
    check("roster %s: nada é escrito, o relógio fica e rc 1" % kind, cycle(w, 0) == 1 and not writes(w) and state()["ghosts"][KEY]["seen"] == 9)
    w = due(B("wa-4vjmkn.4.2"))
    w.fail["rig"] = kind
    check("rig list %s: cai na lista estática (HQ), a loja do rig não é lida nem solta" % kind, cycle(w, 0) == 0 and not writes(w) and any("DEGRADED" in x for x in LOGS))
    w = due(B("wa-4vjmkn.4.2"), hq=[B("ga-h1")])
    w.fail["list:/r/wa"] = kind
    cycle(w, 0)
    check("loja do rig ilegível (%s): o relógio dela fica e nada é solto lá" % kind, bead(w, "wa-4vjmkn.4.2")["status"] == "in_progress" and state()["ghosts"][KEY]["seen"] == 9 and any("pulada" in x for x in LOGS))
for name, rows in (("VAZIO (uma cidade viva nunca tem 0 sessões)", []), ("sem o campo state em nenhuma linha (formato que não conheço)", [dict((k.title(), v) for k, v in x.items()) for x in R0])):
    w = due(B("wa-4vjmkn.4.2"), roster=rows)
    check("roster %s -> não sei: nada escrito, rc 1" % name, cycle(w, 0) == 1 and not writes(w) and state()["ghosts"][KEY]["seen"] == 9)
w = World(); w.fail["list:/r/wa"] = w.fail["list:/c"] = "rc1"; fresh()
check("nenhuma loja legível -> rc 1", cycle(w, 0) == 1)
w = World(); fresh()
check("lojas legíveis e vazias -> rc 0", cycle(w, 0) == 0)
w = due(B("wa-4vjmkn.4.2")); real_bs, N.BS = N.BS, None
check("bead_state ausente -> rc 1 e nada escrito", cycle(w, 0) == 1 and not writes(w) and any("FATAL" in x for x in LOGS))
N.BS = real_bs
# 9) a escrita: o rc não é o estado; quem diz é a releitura
for name, setup, want, why in [
    ("rc 13 (alguém mexeu entre a releitura e a escrita) -> perdeu a corrida", dict(hooks={"update#1": lambda: bead(W9, "wa-4vjmkn.4.2").update(assignee="wa-worker-remote-3")}), "LOST", "rc 13"),
    ("reaberta mas já com outro dono na conferência -> perdida, não solta", dict(hooks={"show#2": lambda: bead(W9, "wa-4vjmkn.4.2").update(assignee="wa-worker-remote-3")}), "LOST", "mudou de mãos"),
    ("bd update rc 1 sem aplicar -> falha, a bead fica como estava", dict(fail={"update": "rc1"}), "FAIL", "não pegou"),
    ("bd update com estouro de tempo sem aplicar -> falha", dict(fail={"update": "timeout"}), "FAIL", "não pegou"),
    ("bd update rc 0 mas não mudou nada (mentiu) -> falha", dict(lie=True), "FAIL", "rc=0"),
    ("bd update pegou e a resposta se perdeu (rc 1) -> solta (a releitura prova)", dict(late=True), "RELEASE", ""),
    ("bd update pegou mas a releitura de conferência falha -> NÃO CONFIRMADA", dict(fail={"show#2": "rc1"}), "UNCONFIRMED", "conferir"),
]:
    W9 = w = due(B("wa-4vjmkn.4.2"))
    for k, v in setup.items():
        (getattr(w, k).update(v) if isinstance(v, dict) else setattr(w, k, v))
    cycle(w, 0)
    check("escrita: " + name, outs() == [want] and why in " ".join(LOGS), str(LOGS[-3:]))
    if want in ("LOST", "FAIL"):
        check("escrita (%s): sem comentário nem mail; falha mantém o relógio" % want, not w.comments and not w.mails and (want == "LOST" or state()["ghosts"][KEY]["seen"] == 10))
    if want == "RELEASE":
        check("escrita (%s): comentou e avisou" % want, len(w.comments) == 1 and len(w.mails) == 1)
    if want == "UNCONFIRMED":
        check("escrita (não confirmada): avisa o mayor com ATENÇÃO e não comenta", len(w.mails) == 1 and "ATENÇÃO" in w.mails[0][1] and "não confirmada" in w.mails[0][1] and not w.comments)
for kind in ["rc1", "garbage", "empty", "timeout", "rcbody", "other"]:
    w = due(B("wa-4vjmkn.4.2"))
    w.fail["show#1"] = kind   # a releitura ANTES de escrever (other = o bd devolveu OUTRA bead)
    cycle(w, 0)
    check("releitura antes de escrever (%s): não escreve e o relógio segue" % kind, not writes(w) and bead(w, "wa-4vjmkn.4.2")["status"] == "in_progress" and state()["ghosts"][KEY]["seen"] == 10)
w = due(B("wa-4vjmkn.4.2"))
w.fail["comment"] = "rc1"
cycle(w, 0)
check("comentário falhou: a soltura vale, o mail sai e o aviso é dito", bead(w, "wa-4vjmkn.4.2")["status"] == "open" and len(w.mails) == 1 and any("comentário" in x for x in LOGS))
w = due(B("wa-4vjmkn.4.2"))
w.fail["mail"] = "rc1"
cycle(w, 0)
check("mail falhou: a soltura vale e o aviso fica pendente no estado", bead(w, "wa-4vjmkn.4.2")["status"] == "open" and [x["id"] for x in state()["unmailed"]] == ["wa-4vjmkn.4.2"], str(state()))
w.fail.pop("mail"); w.cnt.pop("mail")
cycle(w, 300)
check("mail pendente sai na rodada seguinte e some do estado", len(w.mails) == 1 and "wa-4vjmkn.4.2" in w.mails[0][1] and state()["unmailed"] == [])
# 10) estado: ausente, corrompido, torto, que não grava
fresh()
w = World(wa=[B("wa-4vjmkn.4.2")])
os.makedirs(os.path.dirname(N.STATE_PATH))
for dry, junks in ((False, None), (True, 1)):
    N.DRY_RUN = dry
    for junk in ["{not json", "[]", '{"ghosts": 5, "unmailed": []}', '{"ghosts": {"a|b": {"since": 1, "seen": 1}}, "unmailed": []}', '{"ghosts": {"a|b|c": {"since": "x", "seen": 1}}, "unmailed": []}',
                 '{"ghosts": {"a|b|c": {"since": 1, "seen": true}}, "unmailed": []}', '{"ghosts": {}, "unmailed": [5]}'][:junks]:
        open(N.STATE_PATH, "w").write(junk)
        rc = cycle(w, 0)
        check("estado ilegível (%s%s): nada escrito, posto de lado, rc 0, recomeça" % (junk[:18], " ensaio" if dry else ""), rc == 0 and not writes(w) and os.path.exists(N.STATE_PATH + ".corrupt") and not os.path.exists(N.STATE_PATH))
        os.remove(N.STATE_PATH + ".corrupt")
N.DRY_RUN = False
w = due(B("wa-4vjmkn.4.2")); real_load, N._load_state = N._load_state, lambda: {"x": 1}
check("_save_state: arquivo que não confere na releitura -> False", N._save_state({"ghosts": {}, "unmailed": []}) is False)
N._load_state = real_load
real_save, N._save_state = N._save_state, lambda st: False
check("estado que não grava -> rc 1 e nada é escrito (o relógio é gravado ANTES de agir)", cycle(w, 0) == 1 and not writes(w))
N._save_state = real_save
fresh(); N.STATE_PATH = os.path.join(TMP, "arquivo", "x", "ng.json"); open(os.path.join(TMP, "arquivo"), "w").write("x")   # o pai é um ARQUIVO
w = World(wa=[B("wa-4vjmkn.4.2")])
check("estado em caminho impossível -> rc 1 e nada é escrito", cycle(w, 0) == 1 and not writes(w))
# 11) o script de verdade, como subprocesso (linha de comando, lock, chaves de desligar, ensaio por padrão)
FAKE = "#!/usr/bin/env python3\nimport json, os, sys\nD = os.environ['NG_FAKE']\na = sys.argv[1:]\nopen(D + '/calls', 'a').write(os.path.basename(sys.argv[0]) + ' ' + json.dumps(a) + '\\n')\n"
bin_dir = os.path.join(TMP, "bin"); os.makedirs(bin_dir)
open(os.path.join(bin_dir, "gc"), "w").write(FAKE + 'if a[:2] == ["rig", "list"]: print(json.dumps({"rigs": []}))\nelif a[:2] == ["session", "list"]: print(json.dumps({"sessions": [{"name": "gastown.mayor", "alias": "gastown.mayor", "state": "active", "template": "mayor"}]}))\n')
open(os.path.join(bin_dir, "bd"), "w").write(FAKE + 'bs = json.load(open(D + "/beads.json"))\nif a[2] == "list": print(json.dumps([b for b in bs if b["status"] == "in_progress"]))\nelif a[2] == "show": print(json.dumps(bs))\n'
                                              'elif a[2] == "update":\n    for i, x in enumerate(a):\n        if x == "--add-label": bs[0]["labels"].append(a[i + 1])\n'
                                              '        if x == "--unset-metadata": bs[0]["metadata"].pop(a[i + 1], None)\n    bs[0].update(assignee="", status="open")\n    json.dump(bs, open(D + "/beads.json", "w"))\n')
for x in ("gc", "bd"):
    os.chmod(os.path.join(bin_dir, x), 0o755)

def proc(extra_env=None, state_json=None, beads=None, off=False):
    d = tempfile.mkdtemp(dir=TMP)
    city = os.path.join(d, "city"); os.makedirs(os.path.join(city, ".gc", "state"))
    json.dump(beads if beads is not None else [], open(os.path.join(d, "beads.json"), "w"))
    if state_json is not None:
        json.dump(state_json, open(os.path.join(city, ".gc", "state", "node-ghost-release.json"), "w"))
    if off:
        open(os.path.join(city, ".gc", "node-ghost-release.off"), "w").write("")
    env = dict((k, v) for k, v in os.environ.items() if not k.startswith("NODE_GHOST_"))
    env.update(PATH=bin_dir + os.pathsep + os.environ["PATH"], GC_CITY_PATH=city, GC_BIN="gc", BD_BIN="bd", NG_FAKE=d)
    env.update(extra_env or {})
    r = subprocess.run([sys.executable, SCRIPT], capture_output=True, text=True, env=env, timeout=60)
    return r, (open(os.path.join(d, "calls")).read() if os.path.exists(os.path.join(d, "calls")) else "")

r, calls = proc({"NODE_GHOST_ENABLED": "0"})
check("subprocesso: NODE_GHOST_ENABLED=0 -> no-op, loga start e kill-switch, nenhuma chamada", r.returncode == 0 and "start" in r.stdout and "kill-switch" in r.stdout and calls == "", r.stdout + r.stderr)
r, calls = proc({"NODE_GHOST_ENABLED": "talvez"})
r2, calls2 = proc(off=True)
check("subprocesso: NODE_GHOST_ENABLED ilegível -> desligado (o inerte); arquivo .off -> no-op", r.returncode == 0 and calls == "" and r2.returncode == 0 and ".off" in r2.stdout and calls2 == "", r2.stdout)
r, calls = proc()
check("subprocesso: loja vazia -> rc 0, lê rig list e session list; os padrões são enabled, ensaio, 900 s, 3 por rodada, veto na 2ª", r.returncode == 0 and "rig" in calls and "session" in calls
      and "start enabled=True dry_run=True grace=900s max=3 veto_after=2" in r.stdout, r.stdout + r.stderr)
r, calls = proc({"BD_BIN": "/nonexistent/bd"})
check("subprocesso: bd que nem executa -> loja ilegível, rc 1, nada escrito", r.returncode == 1 and "nenhuma loja legível" in r.stdout and "\"update\"" not in calls)
ghost = dict(B("wa-4vjmkn.4.2"), updated_at="2026-01-01T00:00:00Z")
st_old = {"ghosts": {"hq|wa-4vjmkn.4.2|wa-worker-remote-2": {"since": 1, "seen": 99}}, "unmailed": []}
for val in [None, "", "1", "sim", "true", "00"]:
    r, calls = proc({} if val is None else {"NODE_GHOST_DRY_RUN": val}, state_json=st_old, beads=[ghost])
    check("subprocesso: NODE_GHOST_DRY_RUN=%r é ENSAIO (só '0' exato escreve)" % val, "WOULD-RELEASE" in r.stdout and '"update"' not in calls, r.stdout)
r, calls = proc({"NODE_GHOST_DRY_RUN": "0"}, state_json=st_old, beads=[ghost])
check("subprocesso: NODE_GHOST_DRY_RUN=0 escreve (o update guardado sai e a conferência acha a bead solta)", '"update"' in calls and "--if-assignee" in calls and "] RELEASE hq/wa-4vjmkn.4.2" in r.stdout and "WOULD" not in r.stdout, r.stdout + calls)
for val in ["30", "abc", "-5", ""]:
    r, calls = proc({"NODE_GHOST_DRY_RUN": "0", "NODE_GHOST_GRACE_SEC": val}, state_json={"ghosts": {"hq|wa-4vjmkn.4.2|wa-worker-remote-2": {"since": int(time.time()) - 400, "seen": 9}}, "unmailed": []}, beads=[ghost])
    check("subprocesso: NODE_GHOST_GRACE_SEC=%r é recusado (volta a 900 s: erro de digitação nunca encurta a carência)" % val, '"update"' not in calls and "grace=900s" in r.stdout, r.stdout)
r, calls = proc({"NODE_GHOST_DRY_RUN": "0", "NODE_GHOST_GRACE_SEC": "300"}, state_json={"ghosts": {"hq|wa-4vjmkn.4.2|wa-worker-remote-2": {"since": int(time.time()) - 400, "seen": 9}}, "unmailed": []}, beads=[ghost])
check("subprocesso: NODE_GHOST_GRACE_SEC=300 (o piso) vale: 400 s sem sessão já solta", '"update"' in calls and "grace=300s" in r.stdout, r.stdout)
lockf = os.path.join(tempfile.mkdtemp(dir=TMP), "x.lock"); fh = open(lockf, "w"); fcntl.flock(fh, fcntl.LOCK_EX)
r, calls = proc({"NODE_GHOST_LOCK": lockf})
check("subprocesso: outra instância segura o lock -> sai 0 sem ler nada", r.returncode == 0 and "lock" in r.stdout and calls == "", r.stdout)
fh.close()
# 12) leitura LENTA sob carga (ga-pdyayy2): com o mini a load 26 o `gc session list` levou 58 s a mais de 90 s e estourava os 40 s -> DEGRADED, rc 1, de novo a cada rodada (o watchdog lê CRASH-LOOP).
#     O mundo falso "demora" sem dormir: a chamada que passa do teto devolve None, como o subprocess.run estourado.
LATENCY = 90   # s, medido em 08/11; a medida à mão estourou os próprios 90 s, então a latência real é >= 90
for ceiling in (40, 150):
    N.CALL_TIMEOUT = ceiling
    w = due(B("wa-4vjmkn.4.2")); w.slow["roster"] = LATENCY
    rc = cycle(w, 0)
    if ceiling == 150:
        check("lento: roster de %d s com o teto de 150 s decide normalmente (solta a fantasma vencida; lê o roster 2x, as duas vezes lento)" % LATENCY,
              rc == 0 and bead(w, "wa-4vjmkn.4.2")["status"] == "open" and outs() == ["RELEASE"] and w.cnt["roster"] == 2 and not any("DEGRADED" in x for x in LOGS), str(LOGS[-3:]))
    else:
        check("lento: roster de %d s com o teto de 40 s (o padrão, sem o env do plist) -> DEGRADED, rc 1, nada escrito, o relógio fica" % LATENCY,
              rc == 1 and not writes(w) and any("DEGRADED" in x for x in LOGS) and state()["ghosts"][KEY]["seen"] == 9, str(LOGS[-3:]))
N.CALL_TIMEOUT = 150
w = due(B("wa-4vjmkn.4.2")); w.slow["roster"] = 160
check("lento: roster além do teto de 150 s continua DEGRADED (o teto é teto: o que não respondeu nunca vira «sem sessão»)", cycle(w, 0) == 1 and not writes(w) and state()["ghosts"][KEY]["seen"] == 9)
for ceiling in (40, 150):
    N.CALL_TIMEOUT = ceiling   # o mesmo teto vale para o rig list: lento demais cai na lista estática (a loja do rig não é lida), dentro do teto lê
    w = due(B("wa-4vjmkn.4.2")); w.slow["rig"] = LATENCY
    cycle(w, 0)
    lida = any(c[0] == "bd" and c[2] == "/r/wa" and "list" in c for c in w.calls)
    check("lento: rig list de %d s com o teto de %d s -> %s" % (LATENCY, ceiling, "lê a loja do rig" if ceiling == 150 else "DEGRADED stores, a loja do rig não é lida"),
          lida == (ceiling == 150) and any("DEGRADED stores" in x for x in LOGS) == (ceiling != 150), str(LOGS[:3]))
N.CALL_TIMEOUT = CALL_DEFAULT
# 13) o plist de verdade: o teto que o launchd entrega ao script (fonte ≠ o que roda: o código sozinho, com o padrão de 40 s, é justamente o que falhava)
# vazio → plist sem EnvironmentVariables vira {} e os dois checks do teto reprovam; falhou/ilegível → a exceção derruba o selftest (rc 1): nunca passa em silêncio
with open(PLIST, "rb") as fh:
    PL = plistlib.load(fh)
PE = PL.get("EnvironmentVariables") if isinstance(PL.get("EnvironmentVariables"), dict) else {}
raw, saved = PE.get("NODE_GHOST_CALL_TIMEOUT"), os.environ.get("NODE_GHOST_CALL_TIMEOUT")
os.environ["NODE_GHOST_CALL_TIMEOUT"] = raw if isinstance(raw, str) else ""
resolved = N._int_env("NODE_GHOST_CALL_TIMEOUT", 40, 5)   # o MESMO parser do script: texto ilegível volta em silêncio ao padrão de 40 s
(os.environ.pop("NODE_GHOST_CALL_TIMEOUT") if saved is None else os.environ.__setitem__("NODE_GHOST_CALL_TIMEOUT", saved))
check("plist: NODE_GHOST_CALL_TIMEOUT é texto (o launchd só aceita string no env) e o script o lê como o número posto, não como o padrão de 40 s",
      isinstance(raw, str) and raw.isdigit() and resolved == int(raw) and resolved != 40, repr(raw))
check("plist: o teto passa da latência medida sob carga (90 s) e uma chamada travada não passa de uma rodada (< StartInterval)",
      isinstance(PL.get("StartInterval"), int) and 90 < resolved < PL["StartInterval"], "teto=%r StartInterval=%r" % (resolved, PL.get("StartInterval")))
r, _ = proc(dict((k, v) for k, v in PE.items() if k.startswith("NODE_GHOST_")))
check("plist -> script: o env do plist chega ao script e a linha start diz o teto que vale (call_timeout=%ss)" % raw, r.returncode == 0 and "call_timeout=%ss" % raw in r.stdout, (r.stdout + r.stderr)[:240])
for val, want in ((None, 40), ("150", 150), ("150s", 40), ("", 40), ("4", 40), ("5", 5)):
    r, _ = proc({} if val is None else {"NODE_GHOST_CALL_TIMEOUT": val})
    check("subprocesso: NODE_GHOST_CALL_TIMEOUT=%r -> call_timeout=%ds na linha start (texto ilegível ou abaixo do mínimo volta ao padrão, e o log DIZ isso)" % (val, want), "call_timeout=%ds" % want in r.stdout, r.stdout[:160])
# 14) o _sh de verdade, sem a costura: o teto vale no subprocess real (a chamada que passa dele é cortada; a lenta que cabe responde)
slow_gc = os.path.join(TMP, "slow-gc")
open(slow_gc, "w").write("#!/usr/bin/env python3\nimport json, os, time\ntime.sleep(float(os.environ['NG_SLOW']))\nprint(json.dumps({'sessions': [{'name': 'a', 'state': 'active'}]}))\n")
os.chmod(slow_gc, 0o755)
N._run, N.GC_BIN = None, slow_gc
os.environ["NG_SLOW"], N.CALL_TIMEOUT = "5", 0.5   # a chamada dorme 5 s e o teto é 0,5 s: cortada
t0 = time.time(); cortada = N._roster(); gasto = time.time() - t0
os.environ["NG_SLOW"], N.CALL_TIMEOUT = "0.5", 30   # dorme 0,5 s, o teto é 30 s: lenta mas cabe
lenta = N._roster()
check("_sh real: roster que passa do teto é cortado (None, sem esperar a chamada acabar); o lento que cabe no teto responde",
      cortada is None and gasto < 4 and lenta == [{"name": "a", "state": "active"}], "%r %.1fs %r" % (cortada, gasto, lenta))
N.GC_BIN, N.CALL_TIMEOUT = "gc", CALL_DEFAULT
os.environ.pop("NG_SLOW", None)

print("\n%d checagens ok, %d falharam%s" % (OK[0], len(BAD), (": " + "; ".join(BAD)) if BAD else ""))
sys.exit(1 if BAD else 0)
