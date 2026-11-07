#!/usr/bin/env python3
"""
node-ghost-release.py — bead de alias do nó Hetzner SEM sessão viva volta ao Pilot (ga-moq226t).

PROBLEMA (07/11; uma P0 parada 32 h): o nó recebe a bead JÁ ATRIBUÍDA ao alias (wa-worker-remote-<1-9> / ps-worker-remote-<1-9>, marca pilot.wa_node_alias); o Pilot abre a sessão; a bead só é solta
na entrega (`release`, à mão). Se a sessão não nasce ou morre antes, ninguém devolve a bead inteira (aberta, sem dono, sem a marca do nó): ela segue "Em execução" e o slot do nó fica preso. Quatro
formas, lidas nos artefatos (docs/runbooks/node-ghost-release.md): create-falhou (lease ~12 min, `failed-create`) · limite-conta ("weekly limit" no meio da obra) · idle-timeout (o worker esperava job em
segundo plano) · reuso-perdido (o apply reaproveitou a sessão 1 min antes do idle_timeout). Quem não cobria: o false-executing-watchdog exige dono crew; o inflight-reclaim-guard só age em bead com marca
do Pilot (a real já não tem) ou dono de pool e só conhece o alias do MBP; o `release` é manual e nem reabre a bead.

REGRA  Por rodada lê as in_progress de todas as lojas e o roster (`gc session list`). FANTASMA = dono é alias do nó + marca pilot.wa_node_alias == dono + bead_state.derive, com o dono dado como
morto, diz stranded (ou gate_failed com devolver_pro_pool) + bead sem update há >= GRACE_SEC + NENHUMA sessão não-morta com o alias (nem pelo gc.session_name da bead) e nenhuma sessão viva do
template sem alias (não dá para saber de quem é). Relógio no estado: só solta com >= 2 vistas e >= GRACE_SEC desde a 1ª; sessão viva, bead que mudou ou loja ilegível zeram ou seguram o
relógio; roster ilegível/vazio suspende a rodada. Antes de escrever relê roster e bead; UMA escrita guardada (--if-assignee/--if-status): dono "", status open, tira a marca do nó, os carimbos
do Pilot e story:in-flight/pilot:dispatched, conta em node:ghost-count:N e, na NODE_GHOST_VETO_AFTER-ésima (2), põe node:never (a bead vai ao mini). Confere relendo, comenta na bead, UM mail ao
Mayor. NÃO FAZ: não toca sessão, worktree nem branch do nó; não olha dog-remote/kimi (outras marcas), o MBP (é do guard) nem a forma `pool`; não mexe em bead com pilot:dispatching.
NODE_GHOST_ENABLED≠1 → no-op. NODE_GHOST_DRY_RUN: só "0" exato escreve (ausente/vazio/lixo = ENSAIO: loga WOULD-RELEASE, guarda o relógio, não escreve nem envia). .gc/node-ghost-release.off → no-op.
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
MAYOR = os.environ.get("NODE_GHOST_MAYOR_ADDR", "mayor")
STATE_PATH = os.environ.get("NODE_GHOST_STATE", os.path.join(CITY, ".gc", "state", "node-ghost-release.json"))
LOCK_PATH = os.environ.get("NODE_GHOST_LOCK", os.path.join(CITY, ".gc", "node-ghost-release.lock"))
OFF_PATH = os.path.join(CITY, ".gc", "node-ghost-release.off")


def _int_env(name, default, lo):
    # vazio/ausente → o padrão; falhou/ilegível (texto, abaixo do mínimo) → o padrão TAMBÉM: erro de digitação nunca encurta a carência nem estica o teto
    try:
        v = int(os.environ.get(name, ""))
    except ValueError:
        return default
    return v if v >= lo else default


ENABLED = os.environ.get("NODE_GHOST_ENABLED", "1") == "1"
DRY_RUN = os.environ.get("NODE_GHOST_DRY_RUN", "1") != "0"        # só "0" exato escreve; qualquer outra coisa é ensaio
GRACE_SEC = _int_env("NODE_GHOST_GRACE_SEC", 900, 300)            # sem sessão + bead sem update há tanto (o lease do create é ~12 min)
MIN_SEEN = 2                                                      # vistas seguidas antes de soltar
MAX_PER_RUN = _int_env("NODE_GHOST_MAX_PER_RUN", 3, 1)            # teto de escritas por rodada
VETO_AFTER = _int_env("NODE_GHOST_VETO_AFTER", 2, 0)              # a N-ésima devolução veta o nó (0 = nunca veta)
BD_TIMEOUT = _int_env("NODE_GHOST_BD_TIMEOUT", 60, 5)
CALL_TIMEOUT = _int_env("NODE_GHOST_CALL_TIMEOUT", 40, 5)

WORK_TYPES = frozenset({"feature", "bug", "task", "chore"})
ALIAS_RE = re.compile(r"^((?:wa|ps)-worker-remote)-[1-9]$")       # o MBP (wa-worker-remote-mbp-N) não casa: é do guard
CNT_RE = re.compile(r"^node:ghost-count:(\d+)$")
MARK = "pilot.wa_node_alias"
UNSET = (MARK, "pilot.dispatched_at", "pilot.dispatching_at", "pilot.sling_bead")
STRIP = ("story:in-flight", "pilot:dispatched")
_STATIC_RIGS = [("whatsapp_automation", "/Users/athos/gt/whatsapp_automation"), ("property_scrapers", "/Users/athos/gt/property_scrapers")]
_run = None  # seam de teste: (argv, timeout) -> (rc, stdout) | None


def _log(msg):
    print("[node-ghost] %s" % msg, flush=True)


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
        try:
            return json.loads(raw[:pos]) if "Extra data" in str(e) and pos else None
        except ValueError:
            return None


def _safe(x):
    """Texto de bead/rig/roster entra em log, estado, comentário e mail: só caracteres de id (sem quebra de linha nem '|', que é o separador da chave)."""
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
    # lista de sessões; falhou/ilegível/VAZIA → None (cidade viva nunca tem 0 sessões: "ninguém" seria um veredito inventado); sem o campo `state` em texto em NENHUMA linha
    # (campo renomeado, maiúscula: formato que não conheço) → None também, senão todo alias pareceria sem sessão
    r = _sh([GC_BIN, "session", "list", "--json"], CALL_TIMEOUT)
    d = _loads(r[1]) if r and r[0] == 0 else None
    s = d.get("sessions") if isinstance(d, dict) else d
    rows = [x for x in s if isinstance(x, dict)] if isinstance(s, list) else []
    return rows if any(isinstance(x.get("state"), str) for x in rows) else None


def _show(path, bid):
    # a bead; vazio/falhou/ilegível/OUTRA bead → None: a releitura que não responde não vira "mudou" nem "continua igual"
    r = _sh([BD_BIN, "-C", path, "show", bid, "--json"], BD_TIMEOUT)
    d = _loads(r[1]) if r and r[0] == 0 else None
    d = d[0] if isinstance(d, list) and len(d) == 1 else d
    return d if isinstance(d, dict) and d.get("id") == bid else None


# ── planejamento puro ───────────────────────────────────────────────────────────
def presence(alias, sess, roster, tpl):
    """('live'|'dead'|'unknown', detalhe). Pura. live = sessão NÃO provadamente morta com o alias (id/name/session_name/alias/agent_name == alias ou começando por alias+'-', ou igual ao
    gc.session_name da bead): estado que não conheço conta como viva, nunca se conclui morte sem saber. unknown = há sessão viva do template SEM alias nomeado, que pode ser a dona."""
    dead_states = BS.DEAD_SESSION_STATES | {"stopped"}
    hit, anon, dead_seen = None, False, None
    for s in roster:
        if not isinstance(s, dict):
            continue
        st = s.get("state").lower() if isinstance(s.get("state"), str) else ""
        ids = [i for i in (s.get(k) for k in ("id", "name", "session_name", "alias", "agent_name")) if isinstance(i, str) and i]
        mine = any(i == alias or i.startswith(alias + "-") or (sess and i == sess) for i in ids)
        if s.get("closed") is True or st in dead_states:
            dead_seen = dead_seen or (st or "closed") if mine else dead_seen
        elif mine:
            hit = hit or st or "?"
        elif not (isinstance(s.get("alias"), str) and s.get("alias")) and (s.get("template") == tpl or any(i.startswith(tpl + "-") for i in ids)):
            anon = True
    if hit:
        return "live", hit
    return ("unknown", "sessao-sem-alias") if anon else ("dead", dead_seen or "ausente")


def classify(b, now, roster):
    """(fantasma | None, motivo de não-achado). Pura."""
    bid, who = b.get("id"), b.get("assignee")
    if b.get("status") != "in_progress" or b.get("issue_type") not in WORK_TYPES:
        return None, "fora-do-escopo"
    if not isinstance(bid, str) or not bid or not isinstance(who, str) or not who:
        return None, "sem-id-ou-dono"
    m = ALIAS_RE.match(who)
    if not m:
        return None, "dono-nao-e-alias-do-no"
    ls, md = b.get("labels", []), b.get("metadata", {})  # o bd omite a chave quando vazia: ausente = nenhum; presente e de outro tipo = ilegível
    if not isinstance(ls, list) or not isinstance(md, dict):
        return None, "rotulos-ou-metadata-ilegiveis"
    if md.get(MARK) != who:
        return None, "sem-marca-do-no"  # forma pool ou dono posto à mão: não é a que eu conheço
    labels = [x for x in ls if isinstance(x, str)]
    if {"story:done", "gate:passed"} & set(labels) or any(x.startswith("delivery:") for x in labels):
        return None, "entregue"
    if "pilot:dispatching" in labels:
        return None, "claim-do-pilot"  # o Pilot está despachando (ou a recuperação por TTL dele é dona do claim): não é comigo
    upd = BS.parse_iso_epoch(b.get("updated_at"))
    if upd is None:
        return None, "idade-ilegivel"
    if now - upd < GRACE_SEC:
        return None, "bead-recente"
    sess = md.get("gc.session_name") if isinstance(md.get("gc.session_name"), str) else ""
    verdict, detail = presence(who, sess, roster, m.group(1))
    if verdict != "dead":
        return None, "sessao-viva" if verdict == "live" else "sessao-nao-atribuivel"
    st = BS.derive(b, live_sessions=frozenset(), known_crews=frozenset(), now=int(now))  # dono dado como morto: só aí o estado canônico diz stranded
    if not (st.get("state") == "stranded" or st.get("state") == "gate_failed" and "devolver_pro_pool" in (st.get("actions") or [])):
        return None, "estado:%s" % st.get("state")
    n = max([int(CNT_RE.match(x).group(1)) for x in labels if CNT_RE.match(x)] or [0])
    return {"id": _safe(bid), "alias": who, "tpl": m.group(1), "age": now - upd, "sess": _safe(sess), "n": n, "labels": labels, "state": st["state"], "detail": _safe(detail),
            "veto": VETO_AFTER > 0 and n + 1 >= VETO_AFTER and "node:never" not in labels}, ""


def observe(beads, roster, now):
    """beads: {loja: [bead] | None}. -> (fantasmas, contagem dos motivos de não-achado). Pura."""
    found, stats = [], {}
    for store in sorted(beads):
        for b in beads[store] or []:
            try:
                f, why = classify(b, now, roster)
            except Exception as e:  # um registro torto não derruba a rodada: vira "erro" contado
                f, why = None, "erro:" + type(e).__name__
            if f is not None:
                found.append(dict(f, store=store))
            elif why:
                stats[why] = stats.get(why, 0) + 1
    return found, stats


def key(f):
    return "%s|%s|%s" % (f["store"], f["id"], f["alias"])


def reconcile(old, ghosts, now, fresh):
    """Pura. -> (relógios novos, fantasmas vencidos, o mais antigo primeiro). Loja ilegível = "não sei": o relógio dela fica como estava. Fantasma que sumiu, ou trocou de dono, sai."""
    new = dict((k, v) for k, v in old.items() if k.split("|")[0] not in fresh)
    due = []
    for f in ghosts:
        o = old.get(key(f)) or {}
        ok = isinstance(o.get("since"), (int, float)) and not isinstance(o.get("since"), bool) and isinstance(o.get("seen"), int)
        since, seen = (o["since"], o["seen"] + 1) if ok else (int(now), 1)
        new[key(f)] = {"since": since, "seen": seen}
        if now - since >= GRACE_SEC and seen >= MIN_SEEN:
            due.append(f)
    due.sort(key=lambda f: (new[key(f)]["since"], f["id"]))
    return new, due


def update_argv(f, path):
    """A ÚNICA escrita: guardada por dono e status (se a bead já mudou de mãos, o bd recusa com rc 13) e a marca do nó sai na MESMA escrita (um novo apply do Pilot, depois dela, não perde a dele)."""
    a = [BD_BIN, "-C", path, "update", f["id"], "--if-assignee", f["alias"], "--if-status", "in_progress", "--assignee", "", "--status", "open"]
    for k in UNSET:
        a += ["--unset-metadata", k]
    for x in f["labels"]:
        if x in STRIP or CNT_RE.match(x):
            a += ["--remove-label", x]
    a += ["--add-label", "node:ghost-count:%d" % (f["n"] + 1)]
    return a + (["--add-label", "node:never"] if f.get("veto") else []) + ["-q"]


def format_comment(f, mins, note):
    return ("nó (ga-moq226t): devolvida ao Pilot — o alias %s ficou sem sessão viva há pelo menos %d min (roster: %s; última sessão da bead: %s). Dono e marca do nó soltos, carimbos do Pilot tirados, "
            "status open: o Pilot redespacha. %sTrabalho não publicado da sessão pode estar no worktree do nó (hetzner-remote-git.sh status lista o PENDENTE; WIP publicado fica em worker/<sessão>-*). "
            "Devoluções desta bead: %d.%s" % (f["alias"], mins, f["detail"], f["sess"] or "—", "Já foi devolvida antes: node:never aplicado, ela vai ao mini. " if f.get("veto") else "", f["n"] + 1,
                                              " ATENÇÃO: " + note if note else ""))


def format_mail(items):
    out = ["node-ghost-release (ga-moq226t): bead(s) de alias do nó Hetzner SEM sessão viva devolvidas ao Pilot (status open, sem dono, sem a marca do nó).", ""]
    out += ["  %s/%s — alias %s, sem sessão há pelo menos %d min%s%s" % (x["store"], x["id"], x["alias"], x["mins"], " (veto node:never: vai ao mini)" if x.get("veto") else "",
                                                           " — ATENÇÃO: " + x["note"] if x.get("note") else "") for x in items]
    return "\n".join(out + ["", "Trabalho não publicado pode estar no worktree do nó: `hetzner-remote-git.sh status <rig>` lista o PENDENTE.",
                            "Desligar: NODE_GHOST_ENABLED=0 no plist (recarregar) ou `touch .gc/node-ghost-release.off`."])


# ── estado e ações ──────────────────────────────────────────────────────────────
def _load_state():
    # ausente → estado vazio (1ª rodada); ilegível/corrompido/torto → None: sem relógio confiável nada é solto naquela rodada
    try:
        with open(STATE_PATH) as f:
            d = json.load(f)
    except FileNotFoundError:
        return {"ghosts": {}, "unmailed": []}
    except (OSError, ValueError):
        return None

    def num(v):
        return isinstance(v, (int, float)) and not isinstance(v, bool)
    ok = (isinstance(d, dict) and isinstance(d.get("ghosts"), dict) and isinstance(d.get("unmailed"), list)
          and all(isinstance(k, str) and k.count("|") == 2 and isinstance(v, dict) and num(v.get("since")) and num(v.get("seen")) for k, v in d["ghosts"].items())
          and all(isinstance(x, dict) and isinstance(x.get("id"), str) for x in d["unmailed"]))
    return d if ok else None


def _save_state(st):
    """True só quando o arquivo relido é o que foi escrito (o rc de uma escrita já mentiu antes)."""
    try:
        os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
        with open(STATE_PATH + ".tmp", "w") as f:
            json.dump(st, f, sort_keys=True)
        os.replace(STATE_PATH + ".tmp", STATE_PATH)
    except OSError as e:
        _log("STATE-ERROR: não consegui gravar %s: %r" % (STATE_PATH, e))
        return False
    if _load_state() != st:
        _log("STATE-ERROR: %s não confere na releitura" % STATE_PATH)
        return False
    return True


def release_one(f, path, now):
    """(resultado, porquê). Relê roster e bead, decide de novo com o dado fresco e faz a ÚNICA escrita guardada; quem diz se pegou é a releitura, não o rc.
    released | would (ensaio) | skip (a releitura desmentiu ou não respondeu) | lost (alguém mexeu antes) | fail (a escrita não pegou) | unconfirmed (escreveu e não deu para conferir)."""
    roster = _roster()
    if roster is None:
        return "skip", "roster ilegível na releitura"
    cur = _show(path, f["id"])
    if cur is None:
        return "skip", "bead ilegível na releitura"
    g, why = classify(cur, now, roster)
    if g is None or g["alias"] != f["alias"]:
        return "skip", "mudou entre as leituras: %s" % why
    if DRY_RUN:
        return "would", ""
    r = _sh(update_argv(g, path), BD_TIMEOUT)
    rc = r[0] if r else None
    if rc == 13:
        return "lost", "bd rc 13: a bead mudou entre a releitura e a escrita"
    after = _show(path, f["id"])
    if after is None:
        return "unconfirmed", "bd update rc=%s e a releitura para conferir falhou" % rc
    if after.get("status") == "open" and not after.get("assignee"):
        lbl, md = after.get("labels") or [], after.get("metadata") or {}
        left = [x for x in STRIP if x in lbl] + [k for k in UNSET if k in md] + ([] if "node:ghost-count:%d" % (g["n"] + 1) in lbl else ["contagem"]) + (["node:never"] if g["veto"] and "node:never" not in lbl else [])
        return "released", ("limpeza incompleta: " + ",".join(left)) if left else ""
    if after.get("assignee") == f["alias"] and after.get("status") == "in_progress":
        return "fail", "a escrita não pegou (bd update rc=%s)" % rc
    return "lost", "a bead mudou de mãos (dono=%s status=%s)" % (_safe(after.get("assignee")), _safe(after.get("status")))


def run_cycle(now=None):
    """Uma rodada. Devolve o código de saída: 1 se nada pôde ser examinado (nenhuma loja, roster ilegível, estado não gravável) ou o vocabulário canônico faltou, senão 0."""
    if BS is None:
        _log("FATAL: bead_state não importou (%r) — nada é classificado" % (_IMPORT_ERR,))
        return 1
    now = time.time() if now is None else now
    stores = _stores()
    if stores is None:
        _log("DEGRADED stores: gc rig list falhou — HQ + lista estática")
        stores = [("hq", CITY)] + [s for s in _STATIC_RIGS if os.path.isdir(s[1]) or _run is not None]
    beads, paths, unreadable = {}, {}, 0
    for name, path in stores:
        recs = _in_progress(path)
        if recs is None:
            _log("WARN: bd list in_progress falhou/ilegível em %s — loja pulada (NÃO lida como 'nada em andamento'; o relógio dela fica como estava)" % name)
            unreadable += 1
        else:
            beads[name], paths[name] = recs, path
    if not beads:
        _log("nenhuma loja legível — nada examinado")
        return 1
    roster = _roster()
    if roster is None:
        _log("DEGRADED: gc session list falhou/ilegível/vazio — nada é decidido nesta rodada (o relógio não anda)")
        return 1
    state = _load_state()
    if state is None:
        try:
            os.replace(STATE_PATH, STATE_PATH + ".corrupt")
        except OSError:
            _log("STATE-ERROR: %s ilegível e não consigo pô-lo de lado — nada é solto, e vai ser assim a cada rodada até alguém olhar" % STATE_PATH)
            return 1
        _log("STATE-ERROR: %s ilegível — sem relógio confiável nada é solto agora; arquivo posto de lado, a próxima rodada recomeça limpa" % STATE_PATH)
        return 0
    ghosts, stats = observe(beads, roster, now)
    state["ghosts"], due = reconcile(state["ghosts"], ghosts, now, set(beads))
    due = due[:MAX_PER_RUN]
    _log("lojas=%d ilegiveis=%d fantasmas=%d vencidas=%d kept=%s" % (len(beads), unreadable, len(ghosts), len(due), ",".join("%s:%d" % kv for kv in sorted(stats.items())) or "-"))
    for g in ghosts:
        c = state["ghosts"][key(g)]
        _log("GHOST %s/%s alias=%s roster=%s desde=%dmin vistas=%d" % (g["store"], g["id"], g["alias"], g["detail"], (now - c["since"]) // 60, c["seen"]))
    if not _save_state(state):  # o relógio é gravado ANTES de agir: sem ele não há como saber desde quando
        return 1
    new = []
    for f in due:
        mins = int((now - state["ghosts"][key(f)]["since"]) // 60)
        res, why = release_one(f, paths[f["store"]], now)
        tag = "%s/%s alias=%s sem-sessao=%dmin%s%s" % (f["store"], f["id"], f["alias"], mins, " veto=node:never" if f["veto"] else "", " — " + why if why else "")
        _log("%s %s" % ({"would": "WOULD-RELEASE", "released": "RELEASE", "skip": "SKIP", "lost": "LOST", "fail": "FAIL", "unconfirmed": "UNCONFIRMED"}[res], tag))
        if res in ("released", "unconfirmed"):
            state["ghosts"].pop(key(f), None)
            if not _save_state(state):
                _log("STATE-ERROR: relógio de %s não saiu do estado (a próxima rodada vê a bead já solta)" % f["id"])
            new.append({"id": f["id"], "store": f["store"], "alias": f["alias"], "mins": mins, "veto": f["veto"], "note": ("escrita não confirmada: " if res == "unconfirmed" else "") + why})
            if res == "released" and not ((_sh([BD_BIN, "-C", paths[f["store"]], "comment", f["id"], format_comment(f, mins, why)], BD_TIMEOUT) or (1,))[0] == 0):
                _log("WARN: comentário em %s não gravado (a soltura vale; o mail leva o aviso)" % f["id"])
    pend = state["unmailed"] + new
    if pend and not DRY_RUN:
        sent = _sh([GC_BIN, "mail", "send", MAYOR, "-s", "Nó Hetzner: %d bead(s) sem sessão do alias devolvida(s) ao Pilot" % len(pend), "-m", format_mail(pend), "--notify"], CALL_TIMEOUT + 20)
        state["unmailed"] = [] if sent and sent[0] == 0 else pend[-40:]
        _log("MAIL ao %s: %d bead(s)" % (MAYOR, len(pend)) if not state["unmailed"] else "WARN: gc mail send falhou — o aviso fica pendente e sai na próxima rodada")
        if not _save_state(state):
            return 1
    return 0


def main():
    # loga SEMPRE primeiro: o daemon-presence-watchdog lê o .out como batimento
    _log("start enabled=%s dry_run=%s grace=%ds max=%d veto_after=%d" % (ENABLED, DRY_RUN, GRACE_SEC, MAX_PER_RUN, VETO_AFTER))
    if not ENABLED or os.path.exists(OFF_PATH):
        _log("kill-switch (NODE_GHOST_ENABLED!=1 ou arquivo %s) — no-op" % OFF_PATH)
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
