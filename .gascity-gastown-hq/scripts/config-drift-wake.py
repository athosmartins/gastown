#!/usr/bin/env python3
"""
config-drift-wake.py — religa a sessão de pool que o config-drift adormeceu com uma bead in_progress na mão (ga-wo99v8w).

PALIATIVO ATÉ A ga-gn35963 ESTAR NO AR. Toda mudança em `.gc/scripts` dispara config-drift e o controller drena as sessões do template; o guarda de "trabalho vivo" do drift olha só o store do agente, e a sessão
de um agente com work_dir fora de rig (dog-remote, wa-worker-remote, ...) lê "sem trabalho": fica `asleep`, motivo `config-drift`, com a bead in_progress dela. Ninguém a religa (12/11, 2 casos no nó, ~40 min
parados: dog-remote-5/ga-5cl2vvn e wa-worker-remote-2/wa-k5k7kj; o node-ghost-release não olha o dog-remote, o pilot-manual-reclaim recusa lease não vencido) e `gc session wake <id>` destravou na hora. O conserto de
verdade é o patch do motor (docs/pending-engine-window/ga-gn35963-*.patch).
SAI QUANDO o patch da ga-gn35963 estiver NO AR: o binário `gc` com o símbolo `sessionHasLiveAssignedWorkForConfigDrift` (`strings $(readlink -f $(which gc)) | grep -c sessionHasLiveAssignedWorkForConfigDrift`) E o
supervisor reiniciado depois da troca. Aí se descarrega o job e se apagam estes arquivos (docs/runbooks/config-drift-wake.md); mergeado ≠ vivo, então a conferência é no binário, não na bead.

REGRA  Por rodada lê o roster (`gc session list --json`). A linha do roster NÃO traz o motivo do sono (o revisor do gate leu as 20 chaves ao vivo, 12/11: nenhuma de motivo): ele mora na BEAD DE SESSÃO, em
`metadata.sleep_reason` (`bd -C <cidade> show <id> --json`; o id da linha é o id da bead, como o revisor leu). A coluna REASON do `gc session list` imprime esse mesmo campo (fonte aberto do motor,
`lifecycleDisplayReasonFromViewInfo`) e `config-drift` é o literal que esse fonte define (`SleepReasonConfigDrift`); o Mayor viu `asleep · config-drift` nela em 12/11. CANDIDATA = sessão de template de pool (CONFIG_DRIFT_WAKE_TEMPLATES: dog, dog-remote, wa-worker, wa-worker-remote, ps-worker, ps-worker-remote; pelo campo `template` OU pelo
nome; o MBP, `-remote-mbp-`, fica fora) com state `asleep` na linha, não fechada, e a bead de sessão dela com `sleep_reason` == `config-drift`. Sem sessão de pool asleep a rodada acaba ali (uma leitura só); com
elas é UMA leitura de bead de sessão por sessão (no máximo CONFIG_DRIFT_WAKE_MAX_PROBES, 30). Com candidata lê as in_progress de todas as lojas (`gc rig list` + `bd -C <loja> list`) e a acorda se há bead
feature/bug/task/chore cujo assignee é um dos nomes dela (id, session_name, name, alias, agent_name), o `bead_state.derive` com o dono dado como morto diz `stranded` (park, gate e entrega ficam de fora), a bead
não tem `pilot:dispatching`, nenhuma outra sessão não-morta responde pelo mesmo nome (gêmea viva = trabalho em dobro) e nenhuma outra candidata aponta para a mesma bead. UMA vez por sessão a cada
CONFIG_DRIFT_WAKE_COOLDOWN_SEC (900), relógio em .gc/state/config-drift-wake.json gravado ANTES do `gc session wake <id>`; no máximo CONFIG_DRIFT_WAKE_MAX_PER_RUN (6) por rodada. Antes de agir relê roster, bead e
bead de sessão e decide de novo. Depois do wake, uma linha de comentário na bead e uma no log: o comando é um PEDIDO de acordar, não prova de que a sessão subiu (se seguir dormindo, a rodada seguinte mostra e a
trava decide a nova tentativa).
NÃO VERIFICADO AO VIVO  uma bead de sessão com `sleep_reason=config-drift` de uma sessão que o drift de fato adormeceu: nenhuma existia quando isto foi escrito (as duas de 12/11 fecharam por idle-timeout e o
motivo foi sobrescrito). A linha `census` de cada rodada traz `motivos=` com os motivos que as sessões de pool asleep carregam (`drained`, `idle-timeout`, `config-drift`...): a 1ª rodada com uma sessão presa
confere o literal. Se NENHUMA sessão de pool asleep trouxer motivo legível, o `.out` diz `WARN BEAD-SEM-MOTIVO` e a rodada sai com rc 1 (o job não pode ficar cego com o batimento fresco).
TRÊS ESTADOS  roster ilegível/vazio = nada é decidido (rc 1); bead de sessão ilegível = "não sei" e não acorda; nenhuma sessão de pool asleep com motivo legível = cego, rc 1; loja ilegível = a candidata cuja bead pode estar lá
é "não sei" e não acorda; relógio ilegível = nada acorda na rodada; releitura que falha = SKIP.
NÃO FAZ  não fecha nem reabre bead, não mexe em worktree, não acorda sessão fora do pool, a do MBP nem a sem bead. CONFIG_DRIFT_WAKE_ENABLED≠1 → no-op. CONFIG_DRIFT_WAKE_DRY_RUN: só "0" exato age (ausente/vazio/
lixo = ENSAIO: loga WOULD-WAKE, sem wake, sem comentário e sem gravar o relógio). .gc/config-drift-wake.off → no-op.
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
STATE_PATH = os.path.join(CITY, ".gc", "state", "config-drift-wake.json")
LOCK_PATH = os.path.join(CITY, ".gc", "config-drift-wake.lock")
OFF_PATH = os.path.join(CITY, ".gc", "config-drift-wake.off")


def _int_env(name, default, lo):
    # vazio/ausente → o padrão; falhou/ilegível (texto, abaixo do mínimo) → o padrão TAMBÉM, em silêncio (a linha start do .out mostra o que vale)
    try:
        v = int(os.environ.get(name, ""))
    except ValueError:
        return default
    return v if v >= lo else default


def _list_env(name, default):
    # ausente/vazio/só separadores → o padrão: uma lista vazia desligaria o vigia em silêncio
    v = [x.strip() for x in os.environ.get(name, "").split(",") if x.strip()]
    return v or default


def _norm(v):
    # texto → minúsculo, sem espaço nas pontas, com espaço e `_` trocados por `-` (Config_Drift == config-drift); o que não é texto → ""
    return re.sub(r"[\s_]+", "-", v.strip().lower()) if isinstance(v, str) else ""


ENABLED = os.environ.get("CONFIG_DRIFT_WAKE_ENABLED", "1") == "1"
DRY_RUN = os.environ.get("CONFIG_DRIFT_WAKE_DRY_RUN", "1") != "0"   # só "0" exato age; qualquer outra coisa é ensaio
COOLDOWN_SEC = _int_env("CONFIG_DRIFT_WAKE_COOLDOWN_SEC", 900, 60)
MAX_PER_RUN = _int_env("CONFIG_DRIFT_WAKE_MAX_PER_RUN", 6, 1)
BD_TIMEOUT = _int_env("CONFIG_DRIFT_WAKE_BD_TIMEOUT", 60, 5)
CALL_TIMEOUT = _int_env("CONFIG_DRIFT_WAKE_CALL_TIMEOUT", 40, 5)    # teto de cada `gc`; o plist põe 150 (sob load 26 o session list levou 58-90 s: ga-pdyayy2)
TEMPLATES = _list_env("CONFIG_DRIFT_WAKE_TEMPLATES", ["dog", "dog-remote", "wa-worker", "wa-worker-remote", "ps-worker", "ps-worker-remote"])
PROBE_MAX = _int_env("CONFIG_DRIFT_WAKE_MAX_PROBES", 30, 1)         # teto de leituras de bead de sessão por rodada (uma por sessão de pool asleep)
REASON = _norm(os.environ.get("CONFIG_DRIFT_WAKE_REASON", "")) or "config-drift"

WORK_TYPES = frozenset({"feature", "bug", "task", "chore"})
NAME_KEYS = ("session_name", "name", "alias", "agent_name")        # os nomes pelos quais uma sessão se chama (a porta "nome" do template)
IDENT_KEYS = ("id",) + NAME_KEYS                                   # e pelos quais o assignee de uma bead aponta para ela
MBP_RE = re.compile(r"-remote-mbp(?:-|$)")
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@-]{0,99}\Z")      # nunca um `-x` (viraria opção do gc/bd) nem texto com espaço ou quebra de linha (`\Z`, não `$`: o `$` do Python aceita um `\n` no fim)
_STATIC_RIGS = [("whatsapp_automation", "/Users/athos/gt/whatsapp_automation"), ("property_scrapers", "/Users/athos/gt/property_scrapers")]


def _log(msg):
    print("[config-drift-wake] %s" % msg, flush=True)


def _sh(argv, timeout):
    """(rc, stdout), ou None quando o comando não rodou / estourou o tempo. Nunca levanta."""
    try:
        r = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace", timeout=timeout)
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
    """Texto de roster/bead entra em log, estado e comentário: só caracteres de id (sem quebra de linha)."""
    return re.sub(r"[^\w.:@/-]", "?", str(x))[:80]


# ── leituras ────────────────────────────────────────────────────────────────────
def _roster():
    # lista de sessões; falhou/ilegível/VAZIA → None (cidade viva nunca tem 0 sessões: "ninguém" seria um veredito inventado); sem `state` em texto em NENHUMA linha (formato que não conheço) → None também
    r = _sh([GC_BIN, "session", "list", "--json"], CALL_TIMEOUT)
    d = _loads(r[1]) if r and r[0] == 0 else None
    s = d.get("sessions") if isinstance(d, dict) else d
    rows = [x for x in s if isinstance(x, dict)] if isinstance(s, list) else []
    return rows if any(isinstance(x.get("state"), str) for x in rows) else None


def _stores():
    # "rigs": [] → só o HQ; falhou/ilegível → None (o chamador usa a lista estática e trata o conjunto como INCOMPLETO)
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


def _show(path, bid):
    # a bead; vazio/falhou/ilegível/OUTRA bead → None: a releitura que não responde não vira "mudou" nem "continua igual"
    r = _sh([BD_BIN, "-C", path, "show", bid, "--json"], BD_TIMEOUT)
    d = _loads(r[1]) if r and r[0] == 0 else None
    d = d[0] if isinstance(d, list) and len(d) == 1 else d
    return d if isinstance(d, dict) and d.get("id") == bid else None


# ── decisão pura ────────────────────────────────────────────────────────────────
def _str(v):
    return v.strip() if isinstance(v, str) else ""


def idents(row):
    return set(v for v in (row.get(k) for k in IDENT_KEYS) if isinstance(v, str) and v)


def pool_template(row):
    """Template de pool da sessão (o campo `template` OU um nome `<t>` / `<t>-...`), ou None. O MBP fica de fora: é de outro host e não sei se está de pé. Pura."""
    names, tpl = [_str(row.get(k)) for k in NAME_KEYS if _str(row.get(k))], _str(row.get("template"))
    if MBP_RE.search(tpl) or any(MBP_RE.search(v) for v in names):
        return None
    for t in sorted(TEMPLATES, key=lambda x: (-len(x), x)):  # o mais específico primeiro: `dog-remote-3` é do `dog-remote`, não do `dog`
        if (tpl and (tpl == t or tpl.endswith("/" + t) or tpl.endswith("." + t))) or any(v == t or v.startswith(t + "-") for v in names):
            return t
    return None


def session_reason(sess):
    """Motivo do sono lido da BEAD DE SESSÃO (`metadata.sleep_reason`), normalizado. "" = a bead respondeu sem motivo (chave ausente, vazia ou de outro tipo); None = não sei (a bead não é objeto ou não tem `metadata` objeto). Pura."""
    md = sess.get("metadata") if isinstance(sess, dict) else None
    return _norm(md.get("sleep_reason")) if isinstance(md, dict) else None


def row_state(row):
    return _str(row.get("state")).lower()


def candidate_row(row, sess):
    """(template, "") se a sessão é candidata: linha de pool, asleep, não fechada E a bead de sessão `sess` (None = não li) diz motivo == REASON; senão (None, porquê). Pura."""
    if row.get("closed") is True:
        return None, "fechada"
    if row_state(row) != "asleep":
        return None, "nao-asleep"
    tpl = pool_template(row)
    if tpl is None:
        return None, "fora-do-pool"
    why = session_reason(sess)
    if not why:  # None (não li / ilegível) e "" (a bead respondeu sem motivo) não são candidatas; o `scan` conta os dois à parte
        return None, "sem-motivo"
    return (tpl, "") if why == REASON else (None, "motivo:" + _safe(why))


def asleep_rows(roster):
    """As linhas asleep e não fechadas, em ordem de id (o teto de leituras corta sempre as mesmas). Pura."""
    return sorted((r for r in roster if r.get("closed") is not True and row_state(r) == "asleep"), key=lambda r: str(r.get("id")))


def probe(roster):
    """{id: bead de sessão | None} para as sessões de pool asleep do roster: UMA chamada de bd por sessão. Id que o bd leria como opção e o que passa de PROBE_MAX não são lidos (sem entrada = não sei). Não levanta."""
    out, over = {}, 0
    for row in (r for r in asleep_rows(roster) if pool_template(r)):
        sid = row.get("id")
        if not (isinstance(sid, str) and SAFE_ID.match(sid)):
            _log("WARN: sessão de pool asleep com id inaceitável (%s) — não leio o motivo, não acordo" % _safe(sid))
        elif len(out) >= PROBE_MAX:
            over += 1
        else:
            # vazio/falhou/ilegível/OUTRA bead → None (não sei): a leitura que não responde nunca vira "sem motivo"
            out[sid] = _show(CITY, sid)
    if over:
        _log("WARN: %d sessões de pool asleep além do teto de %d leituras — não lidas (não sei)" % (over, PROBE_MAX))
    return out


def scan(roster, sessions):
    """`sessions` = o que `probe` leu. -> (candidatas, contagem). O motivo de cada sessão de pool asleep vem da bead de sessão dela, nunca da linha do roster. Pura."""
    cen, cands, why_n = {"sessoes": len(roster), "asleep": 0, "pool_asleep": 0, "com_motivo": 0, "candidatas": 0}, [], {}
    for row in asleep_rows(roster):
        cen["asleep"] += 1
        if not pool_template(row):
            continue
        sid = row.get("id")
        sess = sessions.get(sid) if isinstance(sid, str) else None
        rs, tpl = session_reason(sess), candidate_row(row, sess)[0]
        cen["pool_asleep"] += 1
        cen["com_motivo"] += bool(rs)
        why = rs or ("sem-motivo" if rs == "" else "nao-sei")
        why_n[why] = why_n.get(why, 0) + 1
        if tpl:
            cands.append({"sid": sid, "tpl": tpl, "row": row, "alias": _safe(next((row[k] for k in ("alias",) + NAME_KEYS if _str(row.get(k))), sid))})  # o alias primeiro: é o nome que o assignee da bead usa
            cen["candidatas"] += 1
    cen["motivos"] = ",".join("%s:%d" % (_safe(k), n) for k, n in sorted(why_n.items(), key=lambda kv: (-kv[1], kv[0]))[:6]) or "-"
    return cands, cen


def holds(b, ids):
    who, bid = b.get("assignee"), b.get("id")
    return (isinstance(who, str) and who in ids and b.get("status") == "in_progress" and b.get("issue_type") in WORK_TYPES
            and isinstance(bid, str) and bool(SAFE_ID.match(bid)))   # o id vai a `bd show` e `bd comment`: nunca um `-x` (opção) nem texto com espaço ou quebra de linha


def needs_owner(b, now):
    """(True, "") se a bead pede o dono acordado, senão (False, porquê). Dono dado como morto (a sessão dorme): só `stranded` pede; park, gate e entrega não. Pura."""
    ls = b.get("labels", [])
    if not isinstance(ls, list):  # o bd omite a chave quando não há rótulo: ausente = nenhum; presente e de outro tipo = ilegível
        return False, "rotulos-ilegiveis"
    labels = [x for x in ls if isinstance(x, str)]
    if {"story:done", "gate:passed"} & set(labels) or any(x.startswith("delivery:") for x in labels):
        return False, "entregue"  # entregue ou em entrega: não há trabalho a retomar
    if "pilot:dispatching" in labels:
        return False, "claim-do-pilot"
    st = BS.derive(b, live_sessions=frozenset(), known_crews=frozenset(), now=int(now)).get("state")
    return (st == "stranded"), "estado:%s" % _safe(st)


def twin_alive(assignee, sid, roster):
    """True se OUTRA sessão que responde por `assignee` não está provadamente morta (estado desconhecido conta viva). Pura."""
    dead = BS.DEAD_SESSION_STATES | {"stopped"}
    return any(s.get("id") != sid and assignee in idents(s) and s.get("closed") is not True and row_state(s) not in dead for s in roster)


def pick(c, beads, complete, roster, now):
    """('ok', loja, bead) | ('skip', porquê). Pura."""
    ids = idents(c["row"])
    mine = [(s, b) for s in sorted(beads) for b in beads[s] or [] if holds(b, ids)]
    if not mine:
        return ("skip", "sem-bead") if complete else ("skip", "nao-sei:loja-ilegivel")  # o conjunto de lojas está incompleto: a bead pode estar na que não li
    why = ""
    for s, b in mine:
        ok, why = needs_owner(b, now)
        if ok:
            return ("skip", "gemea-viva") if twin_alive(b["assignee"], c["sid"], roster) else ("ok", s, b)
    return "skip", why


def verify(c, roster, sess, cur, now):
    """"" se a decisão ainda vale com o dado fresco (roster, bead de sessão `sess` e bead `cur` relidos), senão o porquê. Pura."""
    rows = [s for s in roster if s.get("id") == c["sid"]]
    if len(rows) != 1:
        return "a sessão saiu do roster (ou o id se repete)"
    tpl, why = candidate_row(rows[0], sess)
    if tpl is None:
        return "a sessão mudou: " + why
    if not holds(cur, idents(rows[0])):
        return "a bead mudou de dono ou de estado"
    ok, why = needs_owner(cur, now)
    if not ok:
        return "a bead mudou: " + why
    return "gemea viva" if twin_alive(cur["assignee"], c["sid"], roster) else ""


# ── estado (relógio da última tentativa por sessão) e ação ─────────────────────
def _load_state():
    # ausente → {} (1ª rodada); ilegível/corrompido/torto → None: sem o relógio da última tentativa não há como impor o intervalo, e nada é acordado naquela rodada
    try:
        with open(STATE_PATH) as f:
            d = json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        return None
    ok = isinstance(d, dict) and all(isinstance(k, str) and isinstance(v, dict) and isinstance(v.get("at"), (int, float)) and not isinstance(v.get("at"), bool) for k, v in d.items())
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


def wake_one(c, store, path, bead, state, now):
    """(resultado, porquê). Relê roster, bead e bead de sessão, decide de novo e só então grava o relógio e pede o wake. woke | would (ensaio) | skip (a releitura desmentiu ou não respondeu) | fail (o gc recusou) | state-error."""
    roster = _roster()
    if roster is None:
        return "skip", "roster ilegível na releitura"
    cur = _show(path, bead["id"])
    if cur is None:
        return "skip", "bead ilegível na releitura"
    # vazio/falhou/ilegível/OUTRA bead → None → SKIP: a releitura que não responde não vira "o mesmo motivo de antes"
    sess = _show(CITY, c["sid"])
    if sess is None:
        return "skip", "bead de sessão ilegível na releitura"
    why = verify(c, roster, sess, cur, now)
    if why:
        return "skip", why
    if DRY_RUN:
        return "would", ""
    state[c["sid"]] = {"at": int(now), "bead": _safe(bead["id"])}
    if not _save_state(state):  # o relógio é gravado ANTES de agir: sem ele não há como respeitar o intervalo
        return "state-error", "relógio não gravado — não acordo"
    r = _sh([GC_BIN, "session", "wake", c["sid"]], CALL_TIMEOUT)
    if not (r and r[0] == 0):
        return "fail", "gc session wake rc=%s" % (r[0] if r else "sem-resposta")
    note = ("config-drift-wake (ga-wo99v8w): a sessão %s (%s, template %s) estava asleep · %s com esta bead in_progress; `gc session wake %s` emitido às %s UTC (rc 0). É um pedido de acordar, não prova de que a "
            "sessão subiu: se seguir dormindo o vigia tenta de novo daqui a %d min. Paliativo até a ga-gn35963 estar no ar." % (c["sid"], c["alias"], c["tpl"], REASON, c["sid"], time.strftime("%H:%M", time.gmtime(now)), COOLDOWN_SEC // 60))
    if not ((_sh([BD_BIN, "-C", path, "comment", bead["id"], note], BD_TIMEOUT) or (1,))[0] == 0):
        _log("WARN: comentário em %s/%s não gravado (o wake foi pedido)" % (store, _safe(bead["id"])))
    return "woke", ""


def run_cycle(now=None):
    """Uma rodada. Devolve o código de saída: 1 se nada pôde ser examinado (roster ilegível, vocabulário canônico ausente, relógio não gravável, nenhuma sessão de pool asleep com motivo legível), senão 0."""
    if BS is None:
        _log("FATAL: bead_state não importou (%r) — nada é classificado" % (_IMPORT_ERR,))
        return 1
    now = time.time() if now is None else now
    roster = _roster()
    if roster is None:
        _log("DEGRADED: gc session list falhou/ilegível/vazio — nada é decidido nesta rodada")
        return 1
    # vazio (nenhuma sessão de pool asleep) → nenhuma leitura de bead; falhou/ilegível → None por sessão (não sei): o motivo é lido da bead de sessão, nunca da linha do roster
    cands, cen = scan(roster, probe(roster))
    _log("census sessoes=%(sessoes)d asleep=%(asleep)d pool_asleep=%(pool_asleep)d com_motivo=%(com_motivo)d candidatas=%(candidatas)d motivos=%(motivos)s" % cen)
    blind = bool(cen["pool_asleep"]) and not cen["com_motivo"]
    if blind:
        _log("WARN BEAD-SEM-MOTIVO: nenhuma das %d sessões de pool asleep trouxe motivo legível na bead de sessão (metadata.sleep_reason) — o vigia não enxerga o motivo de nenhuma nesta rodada" % cen["pool_asleep"])
    if not cands:
        return 1 if blind else 0
    stores = _stores()
    complete = stores is not None
    if stores is None:
        _log("DEGRADED stores: gc rig list falhou — HQ + lista estática; o conjunto de lojas é INCOMPLETO (candidata sem bead lida = não sei)")
        stores = [("hq", CITY)] + [s for s in _STATIC_RIGS if os.path.isdir(s[1])]
    beads, paths = {}, {}
    for name, path in stores:
        recs = _in_progress(path)
        if recs is None:
            _log("WARN: bd list in_progress falhou/ilegível em %s — loja pulada (NÃO lida como 'nada em andamento')" % name)
            complete = False
        else:
            beads[name], paths[name] = recs, path
    if not beads:
        _log("nenhuma loja legível — nada examinado")
        return 1
    state = _load_state()
    if state is None:
        try:
            os.replace(STATE_PATH, STATE_PATH + ".corrupt")
        except OSError:
            _log("STATE-ERROR: %s ilegível e não consigo pô-lo de lado — nada é acordado, e vai ser assim a cada rodada até alguém olhar" % STATE_PATH)
            return 1
        _log("STATE-ERROR: %s ilegível — sem o relógio nada é acordado agora; arquivo posto de lado, a próxima rodada recomeça limpa" % STATE_PATH)
        return 0
    state = dict((k, v) for k, v in state.items() if abs(now - v["at"]) <= 86400)   # uma tentativa de mais de 24 h (ou do futuro distante) não segura mais ninguém
    plan = []
    for c in cands:
        try:
            p = pick(c, beads, complete, roster, now)
        except Exception as e:  # uma linha torta não derruba a rodada: vira "erro" dito
            p = ("skip", "erro:" + type(e).__name__)
        plan.append((c, p))
    nb = {}
    for c, p in plan:
        if p[0] == "ok":
            nb[p[2]["id"]] = nb.get(p[2]["id"], 0) + 1
    woken = 0
    for c, p in plan:
        tag = "%s alias=%s tpl=%s" % (c["sid"], c["alias"], c["tpl"])
        if p[0] != "ok":
            _log("SKIP %s — %s" % (tag, p[1]))
            continue
        store, bead = p[1], p[2]
        tag += " bead=%s/%s" % (store, _safe(bead["id"]))
        last = state.get(c["sid"])
        if nb[bead["id"]] > 1:
            _log("SKIP %s — ambigua: %d candidatas apontam para a mesma bead" % (tag, nb[bead["id"]]))
        elif last is not None and abs(now - last["at"]) < COOLDOWN_SEC:
            _log("COOLDOWN %s — última tentativa há %d s (< %d)" % (tag, now - last["at"], COOLDOWN_SEC))
        elif woken >= MAX_PER_RUN:
            _log("ADIADA %s — teto de %d por rodada" % (tag, MAX_PER_RUN))
        else:
            try:
                res, why = wake_one(c, store, paths[store], bead, state, now)
            except Exception as e:  # a releitura traz bead torta: vira SKIP dito, não uma rodada morta
                res, why = "skip", "erro:" + type(e).__name__
            woken += res in ("woke", "would", "fail")
            _log("%s %s%s" % ({"woke": "WAKE", "would": "WOULD-WAKE", "skip": "SKIP", "fail": "FAIL", "state-error": "STATE-ERROR"}[res], tag, " — " + why if why else ""))
            if res == "state-error":
                return 1
    return 0


def main():
    # loga SEMPRE primeiro: o .out é o batimento (o daemon-presence-watchdog o lê quando o job for registrado nele)
    _log("start enabled=%s dry_run=%s cooldown=%ds max=%d reason=%s probes=%d call_timeout=%ds" % (ENABLED, DRY_RUN, COOLDOWN_SEC, MAX_PER_RUN, REASON, PROBE_MAX, CALL_TIMEOUT))  # o que VALE: env ilegível volta ao padrão em silêncio
    if not ENABLED or os.path.exists(OFF_PATH):
        _log("kill-switch (CONFIG_DRIFT_WAKE_ENABLED!=1 ou arquivo %s) — no-op" % OFF_PATH)
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
