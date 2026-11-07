#!/usr/bin/env python3
"""
false-executing-watchdog.py — bead `in_progress` que ninguém executa não é "Em execução" (ga-9exarbg).

PROBLEMA (medido 07/11 08:2x; o Athos: "16 em execução, metade há ≥1 dia"): das ~31 beads in_progress só ~6 andavam. As outras:
  idle-holder  crew parada no prompt (ou dormindo/suspensa) segurando N beads por dias (batista-wa: 8, a mais velha 176 h). O
               inflight-reclaim-guard NUNCA age em in_progress de crew sem marca do Pilot (SCOPE-CRITICAL: só story:in-flight /
               pilot:dispatched e dono de pool) e segura de propósito as de crew suspensa; o gate-orphaned-label-watchdog (ga-eiaidn)
               conta dono com sessão viva como ACTIVE (viva ≠ trabalhando); o stuck-exec do production-stall-watchdog roda `bd list`
               sem -C (só o store do HQ): nunca viu uma wa-*.
  athos-turn   bead que espera o Athos (next-action:athos*, athos.acao) mas manteve o dono-worker: some da fila dele e infla o
               painel; o guard e o stall-watchdog tratam bead estacionada como vez de OUTRO, então ninguém a move.
  delivered    story:done e ainda in_progress. ("commit no main" é do merged-bead-janitor, ga-tijv5: aqui só o rótulo.)

SÓ DETECTA (ordem do Mayor): nenhuma bead é alterada. Por rodada, 1 nudge a cada crew ociosa (cooldown de 6 h) e 1 mail agregado ao
Mayor (achados novos, ou lembrete a cada 24 h). Devolver ao pool / a open-sem-dono só depois de 1 semana de alertas conferidos: o
registro para conferir são as linhas `ALERT` do .out.

CREW OCIOSA: `last_active` é um relógio de ATIVIDADE DO PANE (pool-idle-nobead-guard mediu: 0-1 s mesmo numa tool call muda de 105 s,
o spinner repinta), então > IDLE_SEC = pane parado. Sessão anexada a humano ou com `last_active` ilegível/zero (sentinela do Go) é
"não sei": nada acontece. Crew dormindo/ausente também segura a bead: só mail, nunca nudge (acordar crew custa RAM; decide o Mayor).
CREWS vêm de agents/*/agent.toml (work_dir .../crew/<slug>, slug != worker, max_active_sessions <= 1: o critério do crew-idle-check.sh);
sem essa lista o ramo idle-holder não roda, nunca se adivinha quem é crew.

FALSE_EXEC_ENABLED=0 → no-op. FALSE_EXEC_DRY_RUN=1 → loga o que faria, não envia nem grava estado. Instância única (flock). Estado:
.gc/state/false-executing-watchdog.json (ilegível → nada é enviado naquela rodada).
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
_IMPORT_ERR = None
try:
    import bead_state as BS
except Exception as _e:  # o vocabulário canônico não é opcional: sem ele nada é classificado, e isso é dito em voz alta
    BS, _IMPORT_ERR = None, _e

CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
GC_BIN = os.environ.get("GC_BIN", "gc")
BD_BIN = os.environ.get("BD_BIN", "bd")
MAYOR = os.environ.get("FALSE_EXEC_MAYOR_ADDR", "mayor")
AGENTS_DIR = os.environ.get("FALSE_EXEC_AGENTS_DIR", os.path.join(CITY, "agents"))
STATE_PATH = os.environ.get("FALSE_EXEC_STATE", os.path.join(CITY, ".gc", "state", "false-executing-watchdog.json"))
LOCK_PATH = os.environ.get("FALSE_EXEC_LOCK", os.path.join(CITY, ".gc", "false-executing-watchdog.lock"))

ENABLED = os.environ.get("FALSE_EXEC_ENABLED", "1") == "1"
DRY_RUN = os.environ.get("FALSE_EXEC_DRY_RUN", "0") == "1"
IDLE_SEC = int(os.environ.get("FALSE_EXEC_IDLE_SEC", "7200"))              # pane da crew parado há tanto = ociosa
STALE_SEC = int(os.environ.get("FALSE_EXEC_STALE_SEC", "21600"))           # bead sem update há tanto (idle-holder)
RETURN_SEC = int(os.environ.get("FALSE_EXEC_RETURN_SEC", "86400"))         # acima disto: listada como candidata a devolução
GRACE_SEC = int(os.environ.get("FALSE_EXEC_GRACE_SEC", "3600"))            # athos-turn/delivered: dá 1 h ao worker para se soltar sozinho
NUDGE_COOLDOWN_SEC = int(os.environ.get("FALSE_EXEC_NUDGE_COOLDOWN_SEC", "21600"))
MAIL_REMIND_SEC = int(os.environ.get("FALSE_EXEC_MAIL_REMIND_SEC", "86400"))
MAX_NUDGES = int(os.environ.get("FALSE_EXEC_MAX_NUDGES", "4"))             # teto por rodada: cada nudge é um turno de LLM
MAX_LIST = int(os.environ.get("FALSE_EXEC_MAX_LIST", "12"))                # linhas por seção do mail
BD_TIMEOUT = int(os.environ.get("FALSE_EXEC_BD_TIMEOUT", "60"))
CALL_TIMEOUT = int(os.environ.get("FALSE_EXEC_CALL_TIMEOUT", "40"))

WORK_TYPES = frozenset({"feature", "bug", "task", "chore"})  # épico é contêiner; marker/molécula/step têm dono próprio
DELIVERY_HOLDS = frozenset({"delivery:partial", "delivery:pending-restart", "scope:needs-review"})  # story:done mas falta algo
KINDS = ("idle-holder", "athos-turn", "delivered")
_STATIC_RIGS = [("whatsapp_automation", "/Users/athos/gt/whatsapp_automation"),
                ("property_scrapers", "/Users/athos/gt/property_scrapers")]

_run = None  # seam de teste: (argv, timeout) -> (rc, stdout) | None


def _log(msg):
    print("[false-exec] %s" % msg, flush=True)


def _sh(argv, timeout):
    """(rc, stdout), ou None quando o comando não rodou / estourou o tempo. Nunca levanta."""
    if _run is not None:
        return _run(argv, timeout)
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except Exception as e:
        _log("WARN: %s falhou: %r" % (" ".join(argv[:4]), e))
        return None


def _loads(raw):
    """JSON → valor, ou None (vazio, lixo). Tolera a linha-resumo que o bd às vezes imprime depois do array."""
    if not isinstance(raw, str) or not raw.strip():
        return None
    try:
        return json.loads(raw)
    except ValueError as e:
        pos = getattr(e, "pos", 0)
        if "Extra data" in str(e) and pos:
            try:
                return json.loads(raw[:pos])
            except ValueError:
                return None
        return None


def _safe(x):
    """Texto de bead/rig entra em log, estado e mail: só caracteres de id (sem quebra de linha nem '|', que é o separador da chave)."""
    return re.sub(r"[^\w.:@/-]", "?", str(x))[:80]


# ── leituras ────────────────────────────────────────────────────────────────────
def _stores():
    # "rigs": [] → só o HQ; falhou/ilegível → None (o chamador usa a lista estática e avisa)
    r = _sh([GC_BIN, "rig", "list", "--json"], CALL_TIMEOUT)
    d = _loads(r[1]) if r and r[0] == 0 else None
    rigs = d.get("rigs") if isinstance(d, dict) else d
    if not isinstance(rigs, list):
        return None
    out = [("hq", CITY)]
    for rig in rigs:
        p = rig.get("path") if isinstance(rig, dict) and rig.get("hq") is not True else None  # o HQ já é o 1º
        if isinstance(p, str) and p and all(p != x[1] for x in out):
            out.append((_safe(rig.get("name") or os.path.basename(p)), p))
    return out


def _in_progress(path):
    # "[]" → [] (nada em andamento); vazio/falhou/ilegível → None: a loja é pulada e contada, nunca lida como "nada em andamento"
    r = _sh([BD_BIN, "-C", path, "list", "--status", "in_progress", "--limit", "0", "--json"], BD_TIMEOUT)
    d = _loads(r[1]) if r and r[0] == 0 else None
    return [x for x in d if isinstance(x, dict)] if isinstance(d, list) else None


def _roster():
    # lista de sessões; falhou/ilegível/VAZIA → None (cidade viva nunca tem 0 sessões: "ninguém" seria um veredito inventado)
    r = _sh([GC_BIN, "session", "list", "--json"], CALL_TIMEOUT)
    d = _loads(r[1]) if r and r[0] == 0 else None
    s = d.get("sessions") if isinstance(d, dict) else d
    return [x for x in s if isinstance(x, dict)] if isinstance(s, list) and s else None


def _crews(agents_dir=None):
    """Nomes das crews nomeadas (camada 1), de agents/*/agent.toml. Falhou (pasta ilegível) → None; pasta sem crew → frozenset()."""
    root = agents_dir or AGENTS_DIR
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return None
    out = set()
    for n in names:
        try:
            with open(os.path.join(root, n, "agent.toml")) as f:  # agente sem toml legível: não é crew
                txt = f.read()
        except OSError:
            continue
        wd = re.search(r'^work_dir\s*=\s*"([^"]*)"', txt, re.M)
        mx = re.search(r"^max_active_sessions\s*=\s*(\d+)", txt, re.M)
        if wd and re.search(r"/crew/(?!worker$)[^/]+$", wd.group(1)) and (not mx or int(mx.group(1)) <= 1):
            out.add(n)
    return frozenset(out)


# ── planejamento puro ───────────────────────────────────────────────────────────
def crew_state(crew, roster, now):
    """('idle'|'busy'|'asleep'|'absent'|'unknown', segundos parada | None, nome da sessão | None). Pura."""
    mine = [s for s in roster if s.get("closed") is not True and any(
        isinstance(i, str) and (i == crew or i.startswith(crew + "-gawisp"))
        for i in (s.get("name"), s.get("session_name"), s.get("alias"), s.get("agent_name"), s.get("template")))]
    if not mine:
        return "absent", None, None
    live = [s for s in mine if s.get("state") in BS.LIVE_SESSION_STATES]
    if not live:
        return ("asleep" if all(s.get("state") in BS.DEAD_SESSION_STATES for s in mine) else "unknown"), None, None
    best, unknown = None, False
    for s in live:
        la, nm = BS.parse_iso_epoch(s.get("last_active")), s.get("name") or s.get("session_name")
        if s.get("attached") is True:
            return "busy", 0, nm
        if la is None or la < 1e9 or not isinstance(nm, str):  # ausente, ilegível ou a sentinela 0001-01-01 do Go: idade desconhecida
            unknown = True
            continue
        age = max(0.0, now - la)
        if best is None or age < best[0]:
            best = (age, nm)
    if best is not None and best[0] < IDLE_SEC:
        return "busy", best[0], best[1]
    if unknown:
        return "unknown", None, None
    return "idle", best[0], best[1]


def classify(b, now, crews, states):
    """(finding | None, motivo de não-achado). Pura. Ordem: delivered > athos-turn > idle-holder."""
    bid, who = b.get("id"), b.get("assignee")
    if b.get("status") != "in_progress" or b.get("issue_type") not in WORK_TYPES:
        return None, "fora-do-escopo"
    if not isinstance(bid, str) or not bid or not isinstance(who, str) or not who:
        return None, "sem-id-ou-dono"  # sem dono = R3 do lifecycle-coherence-janitor
    bid, who = _safe(bid), _safe(who)
    ls = b.get("labels", [])  # o bd omite a chave quando não há rótulo: ausente = nenhum; presente e não-lista = ilegível
    if not isinstance(ls, list):
        return None, "rotulos-ilegiveis"
    labels = set(x for x in ls if isinstance(x, str))
    upd = BS.parse_iso_epoch(b.get("updated_at"))
    if upd is None:
        return None, "idade-ilegivel"
    age = max(0.0, now - upd)
    f = {"id": bid, "who": who, "age": age, "crew": None, "cstate": None, "idle": None, "sess": None, "tier": "", "why": ""}
    if "story:done" in labels:
        if labels & DELIVERY_HOLDS:
            return None, "entregue-com-pendencia"
        if age < GRACE_SEC:
            return None, "entregue-em-carencia"
        return dict(f, kind="delivered", why="story:done"), ""
    nxt = sorted(x for x in labels if x.startswith("next-action:athos"))
    if nxt or BS.is_athos_page(labels):
        if age < GRACE_SEC:
            return None, "athos-em-carencia"
        return dict(f, kind="athos-turn", why=_safe(nxt[0]) if nxt else "vez do Athos"), ""
    if states is None:
        return None, "idle-holder-desligado"
    crew = BS.crew_of(who, crews)
    if crew is None:
        return None, "dono-nao-e-crew"
    st = BS.derive(b, known_crews=crews, now=int(now))
    if st["turn"] != "crew:" + crew:
        return None, "vez-de-outro:" + st["state"]  # estacionada, no gate...
    cstate, idle, sess = states[crew]
    if cstate in ("busy", "unknown"):
        return None, "crew-" + cstate
    if age < STALE_SEC:
        return None, "bead-recente"
    return dict(f, kind="idle-holder", crew=crew, cstate=cstate, idle=idle, sess=sess,
                tier="devolver" if age >= RETURN_SEC else ""), ""


def plan(beads, crews, roster, now):
    """beads: {loja: [bead] | None}. -> (achados, contagem dos motivos de não-achado). Pura."""
    states = None if roster is None or crews is None else dict((c, crew_state(c, roster, now)) for c in crews)
    found, stats = [], {}
    for store in sorted(beads):
        for b in beads[store] or []:
            try:
                f, why = classify(b, now, crews or frozenset(), states)
            except Exception as e:  # um registro torto não derruba a rodada: vira "erro" contado
                f, why = None, "erro:" + type(e).__name__
            if f is not None:
                found.append(dict(f, store=store))
            elif why:
                stats[why] = stats.get(why, 0) + 1
    found.sort(key=lambda f: (KINDS.index(f["kind"]), f["crew"] or "", -f["age"], f["id"]))
    return found, stats


def _key(f):
    return "%s|%s|%s" % (f["kind"], f["store"], f["id"])


def reconcile(state, found, now, fresh, roster_ok):
    """Pura. -> (estado novo, [crews a avisar], achados a listar no mail ou [], chaves novas).
    Achado que sumiu só sai do estado se a leitura que o mostraria respondeu (loja ilegível / roster ilegível = "não sei")."""
    old, nudged = state["findings"], state["nudged"]
    new = dict((k, v) for k, v in old.items()
               if not (k.split("|")[1] in fresh and (k.split("|")[0] != "idle-holder" or roster_ok)))
    fresh_keys = set()
    for f in found:
        k = _key(f)
        if k not in old:
            fresh_keys.add(k)
        new[k] = dict(old.get(k) or {"mailed": 0})
    due = any(k in fresh_keys or now - new[k]["mailed"] >= MAIL_REMIND_SEC  # mailed=0 (o mail não saiu) cai no mesmo teste
              for k in (_key(f) for f in found))
    idle = sorted(set(f["crew"] for f in found if f["kind"] == "idle-holder" and f["cstate"] == "idle"))
    to_nudge = [c for c in idle if now - nudged.get(c, 0) >= NUDGE_COOLDOWN_SEC][:MAX_NUDGES]
    keep = dict((c, t) for c, t in nudged.items() if now - t < 7 * 86400)
    for c in to_nudge:
        keep[c] = int(now)
    return {"findings": new, "nudged": keep}, to_nudge, (found if due else []), fresh_keys


# ── texto ───────────────────────────────────────────────────────────────────────
def _h(sec):
    return "%dh" % (sec // 3600)


def format_nudge(mine):
    ids = ", ".join("%s (%s)" % (f["id"], _h(f["age"])) for f in mine[:8]) + (" +%d" % (len(mine) - 8) if len(mine) > 8 else "")
    return ("[false-executing-watchdog] Sua sessão está parada há %s e você segura %d bead(s) in_progress sem update há mais de %s: %s. "
            "O painel as conta como \"Em execução\". Para CADA uma, agora: retome; ou, se já entregou, feche (bd close --reason); "
            "ou, se não vai fazer já, devolva (bd update <id> --status open --assignee \"\" e tire os rótulos story:in-flight e "
            "pilot:dispatched); ou, se espera o Athos, ponha next-action:athos + o metadado athos.acao e solte o dono. Bead que você já entregou ao gate fica como está. "
            "Não termine o turno deixando bead in_progress \"esperando ordem\"." % (_h(mine[0]["idle"]), len(mine), _h(STALE_SEC), ids))


_TITLES = {
    "idle-holder": "CREW OCIOSA OU AUSENTE segurando beads (pane parado >%s, bead sem update >%s)" % (_h(IDLE_SEC), _h(STALE_SEC)),
    "athos-turn": "VEZ DO ATHOS, mas a bead segue in_progress com dono (some da fila dele e infla o painel)",
    "delivered": "ENTREGUE (story:done) e ainda in_progress",
}
_REMEDY = {
    "idle-holder": "gc session peek <crew> --lines 40 confirma. Crew com sessão ativa e parada recebe nudge (no máx. 1 a cada 6 h). Sem resposta: devolva as não "
                   "iniciadas (pilot-manual-reclaim.sh <id> <rig> se o lease expirou, ou bd update <id> --status open --assignee \"\" "
                   "+ tirar story:in-flight e pilot:dispatched), ou acorde/retome a crew (sem sessão ativa não há nudge).",
    "athos-turn": "devolver a open/sem dono mantendo o rótulo next-action:athos* e o metadado athos.acao: a bead passa à fila do Athos.",
    "delivered": "confirmar a entrega e fechar (bd close <id> --reason ...); se falta parte, tirar o rótulo story:done.",
}


def format_mail(found, fresh_keys):
    out = ["false-executing-watchdog (ga-9exarbg): SÓ DETECÇÃO, nenhuma bead foi alterada. Estas beads estão in_progress e "
           "ninguém as executa agora; o painel as conta em \"Em execução\".", ""]

    def item(f, owner):
        return "%s (%s%s)%s%s" % (f["id"], "dono %s, " % f["who"] if owner else "", _h(f["age"]),
                                  " [nova]" if _key(f) in fresh_keys else "", " [>24h: candidata a devolver]" if f["tier"] else "")
    for kind in KINDS:
        fs = [f for f in found if f["kind"] == kind]
        if not fs:
            continue
        out.append("%s — %d:" % (_TITLES[kind], len(fs)))
        if kind == "idle-holder":
            for crew in sorted(set(f["crew"] for f in fs)):
                mine = [f for f in fs if f["crew"] == crew]
                how = ("sessão ativa, parada há %s" % _h(mine[0]["idle"])) if mine[0]["cstate"] == "idle" else \
                      "sem sessão ativa (%s)" % ("dormindo" if mine[0]["cstate"] == "asleep" else "suspensa/fechada")
                out.append("  %s [%s]: %s%s" % (crew, how, ", ".join(item(f, False) for f in mine[:MAX_LIST]),
                                                " +%d" % (len(mine) - MAX_LIST) if len(mine) > MAX_LIST else ""))
        else:
            out.extend("  " + item(f, True) + (" — " + f["why"] if kind == "athos-turn" else "") for f in fs[:MAX_LIST])
            if len(fs) > MAX_LIST:
                out.append("  +%d" % (len(fs) - MAX_LIST))
        out.extend(["  Remédio: " + _REMEDY[kind], ""])
    return "\n".join(out)


# ── estado e ações ──────────────────────────────────────────────────────────────
def _load_state():
    # ausente → estado vazio (1ª rodada); ilegível/corrompido → None: sem ele não há como deduplicar, então NADA é enviado
    try:
        with open(STATE_PATH) as f:
            d = json.load(f)
    except FileNotFoundError:
        return {"findings": {}, "nudged": {}}
    except (OSError, ValueError):
        return None

    def num(v):
        return isinstance(v, (int, float)) and not isinstance(v, bool)
    ok = (isinstance(d, dict) and isinstance(d.get("findings"), dict) and isinstance(d.get("nudged"), dict)
          and all(isinstance(k, str) and k.count("|") == 2 and isinstance(v, dict) and num(v.get("mailed"))
                  for k, v in d["findings"].items())
          and all(num(v) for v in d["nudged"].values()))
    return d if ok else None  # entrada interna torta = estado ilegível, não uma entrada "nova"


def _save_state(st):
    """True só quando o arquivo relido é o que foi escrito (o rc de uma escrita já mentiu antes)."""
    tmp = STATE_PATH + ".tmp"
    try:
        os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
        with open(tmp, "w") as f:
            json.dump(st, f, sort_keys=True)
        os.replace(tmp, STATE_PATH)
    except OSError as e:
        _log("STATE-ERROR: não consegui gravar %s: %r" % (STATE_PATH, e))
        return False
    if _load_state() != st:
        _log("STATE-ERROR: %s não confere na releitura" % STATE_PATH)
        return False
    return True


def _nudge(sess, msg):
    """'delivered' | 'queued' | 'unreadable' | 'failed'. Só o outcome que o gc declara conta como entregue."""
    r = _sh([GC_BIN, "session", "nudge", sess, msg, "--delivery", "wait-idle", "--json"], CALL_TIMEOUT)
    if r is None or r[0] != 0:
        return "failed"
    d = _loads(r[1])
    oc = d.get("outcome") if isinstance(d, dict) and d.get("ok") is True else None
    return oc if oc in ("delivered", "queued") else "unreadable"


def _mail(subject, body):
    r = _sh([GC_BIN, "mail", "send", MAYOR, "-s", subject, "-m", body, "--notify"], CALL_TIMEOUT + 20)
    return r is not None and r[0] == 0


def run_cycle(now=None):
    """Uma rodada. Devolve o código de saída: 1 se nada pôde ser examinado ou o vocabulário canônico faltou, senão 0."""
    if BS is None:
        _log("FATAL: bead_state não importou (%r) — nada é classificado" % (_IMPORT_ERR,))
        return 1
    now = time.time() if now is None else now
    stores = _stores()
    if stores is None:
        _log("DEGRADED stores: gc rig list falhou — HQ + lista estática")
        stores = [("hq", CITY)] + [s for s in _STATIC_RIGS if os.path.isdir(s[1]) or _run is not None]
    beads, unreadable = {}, 0
    for name, path in stores:
        recs = _in_progress(path)
        if recs is None:
            _log("WARN: bd list in_progress falhou/ilegível em %s — loja pulada (NÃO lida como 'nada em andamento')" % name)
            unreadable += 1
        else:
            beads[name] = recs
    if not beads:
        _log("nenhuma loja legível — nada examinado")
        return 1
    roster, crews = _roster(), _crews()
    if roster is None or crews is None:
        _log("DEGRADED idle-holder desligado nesta rodada: %s ilegível (athos-turn e delivered seguem)"
             % ("gc session list" if roster is None else "agents/*/agent.toml"))
    found, stats = plan(beads, crews, roster, now)
    state = _load_state()
    if state is None and DRY_RUN:  # dry-run não escreve nem renomeia: mostra o que sairia com o estado vazio
        _log("STATE-ERROR: %s ilegível — o dry-run segue com estado vazio e não mexe no arquivo" % STATE_PATH)
        state = {"findings": {}, "nudged": {}}
    elif state is None:
        try:
            os.replace(STATE_PATH, STATE_PATH + ".corrupt")
        except OSError:
            _log("STATE-ERROR: %s ilegível e não consigo pô-lo de lado — nada é enviado, e vai ser assim a cada rodada até alguém olhar" % STATE_PATH)
            return 1
        _log("STATE-ERROR: %s ilegível — sem deduplicação nada é enviado agora; arquivo posto de lado, a próxima rodada recomeça limpa" % STATE_PATH)
        return 0
    new_state, to_nudge, listed, fresh_keys = reconcile(state, found, now, set(beads), roster is not None and crews is not None)
    counts = dict((k, sum(1 for f in found if f["kind"] == k)) for k in KINDS)
    _log("lojas=%d ilegiveis=%d achados=%s mail=%s nudge=%s kept=%s" % (
        len(beads), unreadable, ",".join("%s:%d" % kv for kv in counts.items()), "sim" if listed else "nao",
        ",".join(to_nudge) or "-", ",".join("%s:%d" % kv for kv in sorted(stats.items())) or "-"))
    for f in listed:
        if _key(f) in fresh_keys:
            _log("ALERT %s %s/%s dono=%s idade=%s%s%s" % (f["kind"], f["store"], f["id"], f["who"], _h(f["age"]),
                                                          " crew=%s/%s" % (f["crew"], f["cstate"]) if f["crew"] else "",
                                                          " " + (f["why"] or f["tier"]) if f["why"] or f["tier"] else ""))
    if DRY_RUN:
        _log("DRY_RUN: não envia nem grava estado (nudge a %s; mail %s)" % (",".join(to_nudge) or "ninguém", "sim" if listed else "não"))
        return 1 if unreadable and not found else 0
    if not _save_state(new_state):  # o nudge é gravado ANTES de sair: nudge sem registro se repetiria a cada rodada
        _log("STATE-ERROR: estado não confirmado na releitura — nada é enviado nesta rodada")
        return 1
    for crew in to_nudge:
        mine = [f for f in found if f["kind"] == "idle-holder" and f["crew"] == crew]
        _log("NUDGE %s: %s (%d bead(s))" % (crew, _nudge(mine[0]["sess"], format_nudge(mine)), len(mine)))
    if listed:
        subj = "Falso \"em execução\": %d bead(s) in_progress sem executor (%d nova(s))" % (len(listed), len(fresh_keys))
        if _mail(subj, format_mail(listed, fresh_keys)):
            for f in listed:
                new_state["findings"][_key(f)]["mailed"] = int(now)
            _log("MAIL ao %s: %d bead(s)" % (MAYOR, len(listed)))
            if not _save_state(new_state):  # o mail saiu e não ficou registrado: a próxima rodada o repete, e isto diz por quê
                return 1
        else:
            _log("WARN: gc mail send falhou — as beads seguem 'não avisadas' e entram no próximo mail")
    return 1 if unreadable and not found else 0


def main():
    # loga SEMPRE primeiro: o daemon-presence-watchdog lê o .out como batimento
    _log("start enabled=%s dry_run=%s idle=%ds stale=%ds" % (ENABLED, DRY_RUN, IDLE_SEC, STALE_SEC))
    if not ENABLED:
        _log("kill-switch FALSE_EXEC_ENABLED=0 — no-op")
        return 0
    try:
        os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
        lock = open(LOCK_PATH, "w")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        _log("outra instância segura o lock — saindo")
        return 0
    except OSError as e:
        _log("WARN: sem lock (%r) — NÃO roda sem a trava de instância única" % e)
        return 1
    t0 = time.time()
    rc = run_cycle()
    _log("elapsed=%.1fs rc=%d" % (time.time() - t0, rc))
    return rc


if __name__ == "__main__":
    sys.exit(main())
