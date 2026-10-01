#!/usr/bin/env python3
"""bead-token-meter.py — ga-5c3msy (E8 do P0 ga-ufskhy): MEDE tokens e US$ por bead, por papel, modelo e effort.

Métrica-norte do Athos (30/09): MAXIMIZAR TASKS APROVADAS COM MENOR USO DE TOKENS. Sem um medidor por bead nenhum A/B de
modelo/effort é decidível — esta ferramenta é o pré-requisito (passo 0 do ga-5c3msy).

    backfill-s3  traz do arquivo permanente (S3) os transcritos que o reaper já apagou — uma vez, para o baseline histórico.
    harvest   varre os transcritos (~/.claude/projects) e grava um LEDGER durável, uma linha por sessão. O transcrito é apagado
              pelo transcript-reaper 24h depois de a sessão morrer; o ledger é o que sobrevive. Idempotente e incremental.
    report    ledger + log do gate -> tokens e US$ por papel/modelo/effort, por bead, e por bead APROVADA.
    prices    a tabela de preços em uso (e de onde veio cada número).

Somente leitura sobre os transcritos e o log do gate; só escreve o ledger. Só stdlib.

O que um transcrito conta (medido em 01/10 nos 1.786 transcritos locais):
  * O Claude Code grava UM registro JSONL por bloco de conteúdo (thinking / text / tool_use) e TODOS repetem o `usage` da mesma
    resposta (512 registros = 187 respostas num worker). Somar linhas inflaria o gasto ~2,7x: a contagem é por message.id.
  * Cada resposta carrega `model` e `effort` — o effort de cada turno está GRAVADO, não precisa ser inferido da config.
  * `cache_creation` separa escrita de cache em 5 min (1,25x o preço de entrada) e 1 h (2x); leitura de cache custa 0,1x.
  * Sessões de subagente vivem em <projeto>/<sessão>/subagents/*.jsonl: entram na sessão-mãe (o gasto é dela).

Como uma sessão vira bead (tentativas, em ordem de confiança):
  * construtor (dog / wa-worker / ps-worker / crew): `bd update <id> --claim` COM resultado "Updated issue". Mensagens depois do
    claim k e antes do claim k+1 são do bead k; mensagens ANTES do 1º claim são o overhead de partida (`_pre`), rateado igual entre
    os beads da sessão. NÃO se usa "id citado na 1ª mensagem": o preâmbulo do papel cita ~93 beads de doutrina (medido).
  * revisor do gate: o cabeçalho "QUALITY GATE REVIEW — … for branch: <ramo>" + a ponte ramo -> bead do log do gate (o log tem os
    dois campos). A pré-revisão do construtor (E3) usa o mesmo cabeçalho mas roda `claude -p --no-session-persistence`: NÃO deixa
    transcrito, então o custo dela não aparece aqui (está nas linhas próprias dela); o caminho `pregate-review` só vale se isso mudar.
  * sessão de pool sem nenhum claim = SPAWN OCIOSO (achou a fila vazia e saiu). É custo real e fica numa linha própria; não é
    "custo de bead zero".

Três estados, nunca colapsados: claim com resultado ok / claim que FALHOU (não conta) / claim sem resultado visível (conta e é
sinalizado); modelo SEM preço = tokens contados, US$ "não precificado" (nunca US$ 0); bead sem sessão de construtor no ledger =
"construtor não medido" (nunca custo zero).

Exemplos:
    bead-token-meter.py harvest
    bead-token-meter.py report --since-days 7
    bead-token-meter.py report --since-days 7 --json
"""
import argparse
import datetime as dt
import fcntl
import glob
import contextlib
import io
import json
import math
import shutil
import subprocess
import os
import re
import statistics
import sys
import tempfile
import time
from collections import Counter, defaultdict
from pathlib import Path

CITY = Path(os.environ.get("GC_CITY_PATH") or "/Users/athos/gt/.gascity-gastown-hq")
LEDGER = Path(os.environ.get("BTM_LEDGER") or CITY / ".gc" / "token-ledger" / "sessions.jsonl")
GATE_LOG = Path(os.environ.get("BTM_GATE_LOG") or CITY / ".gc" / "quality-gate.jsonl")
PROJECTS = [Path(p) for p in (os.environ.get("BTM_PROJECTS") or os.path.expanduser("~/.claude/projects")).split(":") if p]
SCHEMA = 2
AWS = os.environ.get("BTM_AWS") or "aws"
S3_BUCKET = os.environ.get("BTM_S3_BUCKET") or "urblink-claude-history-backup"

# US$ por milhão de tokens (entrada, saída). Fonte: skill claude-api / bead ga-5c3msy (30/09/2026). Modelo fora desta tabela NÃO é
# precificado (aparece como "não precificado"): inventar preço é pior que mostrar a lacuna.
PRICES = {
    "claude-sonnet-5-5": (2.0, 10.0),
    "claude-opus-5-5": (4.0, 20.0),
}
# multiplicadores do preço de ENTRADA (documentação de prompt caching): escrita 5 min 1,25x, escrita 1 h 2x, leitura 0,1x.
ASSUMED = {}   # modelo -> modelo cujo preço se ASSUME (só via --assume-price; sempre rotulado na saída)
CACHE_MULT = {"cw5": 1.25, "cw1": 2.0, "cr": 0.10}

ROLE_RES = [  # ordem importa: refino-gate-reviewer antes de gate-reviewer
    (re.compile(r"^gastown\.dog-\d+"), "dog"),
    (re.compile(r"^wa-worker"), "wa-worker"),
    (re.compile(r"^ps-worker"), "ps-worker"),
    (re.compile(r"^refino-gate-reviewer"), "refino-gate-reviewer"),
    (re.compile(r"^gate-reviewer"), "gate-reviewer"),
    (re.compile(r"^auto-refiner"), "auto-refiner"),
    (re.compile(r"^context-check-reviewer"), "context-check-reviewer"),
    (re.compile(r"^gastown\.mayor"), "mayor"),
    (re.compile(r"^(peter|oracle|batista|thies|mila|digo)-"), "crew"),
]
POOL_BUILDERS = ("dog", "wa-worker", "ps-worker")
BUILDERS = POOL_BUILDERS + ("crew",)
REVIEWERS = ("gate-reviewer", "pregate-review")
BEACON = re.compile(r"^\[gascity\]\s+(\S+)")
REVIEW_HEADER = re.compile(r"QUALITY GATE REVIEW\s+—\s+You are reviewer \d+ of \d+ for branch:\s*(\S+)")
ID_TOKEN = re.compile(r"^[a-z]{2,4}-[a-z0-9]{3,10}(?:\.\d+)*$")
REF_CMD = re.compile(r"\bbd\s+(?:-C\s+\S+\s+)?(?:show|comments?|heartbeat|close|label|update|reopen)\s+([a-z]{2,4}-[a-z0-9]{3,10}(?:\.\d+)*)\b")
UPDATE_CMD = re.compile(r"\bbd\s+(?:-C\s+\S+\s+)?update\b([^;&|\n]*)")
USAGE_KEYS = ("inp", "out", "cw5", "cw1", "cr", "think", "msgs")
CTX_CAPS = (150_000, 250_000, 350_000)   # tetos hipotéticos de contexto por turno (tokens): quanto da leitura de cache está ACIMA deles


# ----------------------------------------------------------------------------- pequenos utilitários
def parse_ts(s):
    d = dt.datetime.fromisoformat(str(s).strip().replace("Z", "+00:00"))
    return d if d.tzinfo else d.replace(tzinfo=dt.timezone.utc)


def role_of(alias, first_text="", has_review_header=False):
    if alias:
        for rx, role in ROLE_RES:
            if rx.match(alias):
                return role
        return "other:" + alias.split("-adhoc-")[0][:28]
    # sem beacon = `claude -p` de script. A pré-revisão do construtor (E3) usa o MESMO cabeçalho do revisor do gate.
    if has_review_header:
        return "pregate-review"
    if first_text.startswith("Summarize the following user message"):
        return "title-summary"
    return "headless"


def text_of(rec):
    c = (rec.get("message") or {}).get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return " ".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    return ""


def msg_usage(msg):
    """usage de UMA resposta -> dict de contadores. Escrita de cache sem divisão de TTL é assumida de 5 min (o padrão)."""
    u = msg.get("usage") or {}
    cwt = int(u.get("cache_creation_input_tokens") or 0)
    cc = u.get("cache_creation") or {}
    if cc:
        w5, w1 = int(cc.get("ephemeral_5m_input_tokens") or 0), int(cc.get("ephemeral_1h_input_tokens") or 0)
        if w5 + w1 < cwt:
            w5 += cwt - (w5 + w1)
    else:
        w5, w1 = cwt, 0
    return dict(inp=int(u.get("input_tokens") or 0), out=int(u.get("output_tokens") or 0), cw5=w5, cw1=w1,
                cr=int(u.get("cache_read_input_tokens") or 0),
                think=int((u.get("output_tokens_details") or {}).get("thinking_tokens") or 0))


def usd_of(model, c):
    """US$ de um conjunto de contadores, ou None se o modelo não tem preço (NUNCA 0 por falta de preço)."""
    p = PRICES.get(model) or PRICES.get(ASSUMED.get(model, ""))
    if p is None:
        return None
    pin, pout = p
    return (c["inp"] * pin + c["out"] * pout + c["cw5"] * pin * CACHE_MULT["cw5"] + c["cw1"] * pin * CACHE_MULT["cw1"]
            + c["cr"] * pin * CACHE_MULT["cr"]) / 1e6


def usd_parts(model, c):
    """O mesmo US$ de usd_of(), aberto por categoria: (entrada nova, saída, escrita de cache, leitura de cache). None sem preço."""
    p = PRICES.get(model) or PRICES.get(ASSUMED.get(model, ""))
    if p is None:
        return None
    pin, pout = p
    return (c["inp"] * pin / 1e6, c["out"] * pout / 1e6,
            (c["cw5"] * CACHE_MULT["cw5"] + c["cw1"] * CACHE_MULT["cw1"]) * pin / 1e6, c["cr"] * CACHE_MULT["cr"] * pin / 1e6)


def total_tokens(c):
    return c["inp"] + c["out"] + c["cw5"] + c["cw1"] + c["cr"]


def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 1.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), min(1.0, c + h))


def claim_target(cmd):
    """`bd update <id> --claim` num comando Bash -> lista de ids reivindicados. O id é o 1º token não-flag com cara de id."""
    out = []
    for m in UPDATE_CMD.finditer(cmd):
        seg = m.group(1)
        if "--claim" not in seg:
            continue
        for tok in seg.split():
            tok = tok.strip("'\"")
            if tok.startswith("-"):
                continue
            if ID_TOKEN.match(tok):
                out.append(tok)
                break
    return out


def all_strings(obj, depth=0):
    """Todas as strings de um registro JSON (o cabeçalho da revisão chega dentro de um tool_result ou de um nudge, não só no 1º prompt)."""
    if depth > 6:
        return
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from all_strings(v, depth + 1)
    elif isinstance(obj, list):
        for v in obj:
            yield from all_strings(v, depth + 1)


def tool_text(block):
    t = block.get("content")
    if isinstance(t, str):
        return t
    if isinstance(t, list):
        return " ".join(x.get("text", "") for x in t if isinstance(x, dict))
    return ""


# ----------------------------------------------------------------------------- varredura de UMA sessão
def session_files(main):
    sub = main.with_suffix("") / "subagents"
    files = [main]
    if sub.is_dir():
        files += sorted(sub.glob("*.jsonl"))
    return files


def fingerprint(main):
    """(size, mtime_ns) do transcrito + resumo dos de subagente: mudou -> reescaneia a sessão."""
    parts = []
    for f in session_files(main):
        try:
            st = f.stat()
        except OSError:
            continue
        parts.append((f.name, st.st_size, st.st_mtime_ns))
    return json.dumps(parts)


def scan_session(main):
    """-> dict (registro do ledger) ou None se o transcrito sumiu. Contagem por message.id ENTRE todos os arquivos da sessão."""
    sid = main.stem
    alias = None
    first_text = ""
    branches = []
    cwd = None
    msgs = {}                 # message.id -> dict(ts, model, effort, use)
    dup_lines = 0
    pending = {}              # tool_use id -> (bead, ts) esperando o resultado do claim
    claims = []               # dict(bead, ts, ok)
    refs, ref_first = Counter(), {}   # bead -> nº de comandos `bd <verbo> <id>`; fallback p/ worker com bead JÁ atribuído (sem --claim)
    bad = 0
    no_usage = set()
    nlines = 0
    user_seen = 0
    for f in session_files(main):
        try:
            fh = open(f, errors="replace")
        except OSError:
            if f == main:
                return None
            continue
        with fh:
            for line in fh:
                if len(branches) < 6 and "You are reviewer" in line:
                    try:    # várias citações possíveis (exemplo de doutrina lido pelo revisor): guarda todas, o report fica com a que o gate conhece
                        for txt in all_strings(json.loads(line)):
                            for hm in REVIEW_HEADER.finditer(txt):
                                if hm.group(1) not in branches:
                                    branches.append(hm.group(1))
                    except Exception:
                        pass
                nlines += 1
                is_asst = '"assistant"' in line         # sem depender do espaçamento do JSON ("type":"x" x "type": "x")
                is_user = '"user"' in line
                if not (is_asst or is_user):
                    continue
                if is_user and alias is not None and user_seen >= 3 and not (pending and any(k in line for k in pending)):
                    continue
                try:
                    r = json.loads(line)
                except Exception:
                    bad += 1
                    continue
                t = r.get("type")
                if cwd is None and r.get("cwd"):
                    cwd = r["cwd"]
                if t == "user":
                    c = (r.get("message") or {}).get("content")
                    if user_seen < 3 and not r.get("isSidechain"):
                        txt = text_of(r)
                        user_seen += 1
                        if alias is None:
                            m = BEACON.match(txt.lstrip())
                            alias = m.group(1) if m else ""
                            first_text = txt[:300]
                    if isinstance(c, list) and pending:
                        for b in c:
                            if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id") in pending:
                                bead, ts = pending.pop(b["tool_use_id"])
                                txt = tool_text(b)
                                if "Updated issue" in txt and not b.get("is_error"):
                                    ok = True
                                elif b.get("is_error") or re.search(r"(?i)\b(error|already|failed|not found)\b", txt):
                                    ok = False
                                else:
                                    ok = None
                                claims.append(dict(bead=bead, ts=ts, ok=ok))
                elif t == "assistant":
                    msg = r.get("message") or {}
                    for b in msg.get("content") or []:
                        if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash":
                            cmd = (b.get("input") or {}).get("command") or ""
                            for bead in claim_target(cmd):
                                pending[b.get("id") or f"noid-{len(pending)}"] = (bead, r.get("timestamp") or "")
                            for rm in REF_CMD.finditer(cmd):
                                refs[rm.group(1)] += 1
                                ref_first.setdefault(rm.group(1), r.get("timestamp") or "")
                    mid = msg.get("id")
                    if not mid:
                        continue
                    if not msg.get("usage") and msg.get("model") != "<synthetic>":
                        no_usage.add(mid)                    # resposta real SEM usage: os tokens dela são DESCONHECIDOS, não zero
                    use = msg_usage(msg)
                    rec = msgs.get(mid)
                    if rec is None:
                        msgs[mid] = dict(ts=r.get("timestamp") or "", model=msg.get("model") or "?",
                                         effort=r.get("effort") or r.get("perTurnEffort") or "?", use=use)
                    else:
                        dup_lines += 1
                        for k, v in use.items():     # mesma resposta repetida por bloco: o uso é monotônico, vale o maior
                            if v > rec["use"][k]:
                                rec["use"][k] = v
    for bead, ts in pending.values():               # claim sem resultado visível: conta, sinalizado (ok=None)
        claims.append(dict(bead=bead, ts=ts, ok=None))
    for c in claims:
        c["via"] = "claim"
    live = sorted((c for c in claims if c["ok"] is not False and c["ts"]), key=lambda c: c["ts"])
    role = role_of(alias, first_text, bool(REVIEW_HEADER.search(first_text)))
    if not live and role in POOL_BUILDERS and refs:
        # worker com bead JÁ atribuído (sling/Pilot): não há claim. O bead é o mais citado em `bd show|comment|heartbeat|close…`.
        top = sorted(refs, key=lambda b: (-refs[b], ref_first[b]))[0]
        live = [dict(bead=top, ts=ref_first[top], ok=None, via="ref")]
    failed = sum(1 for c in claims if c["ok"] is False)
    ordered = sorted(((m["ts"], mid, m) for mid, m in msgs.items()), key=lambda x: (x[0], x[1]))
    buckets = defaultdict(lambda: defaultdict(lambda: {k: 0 for k in USAGE_KEYS}))
    days = defaultdict(lambda: defaultdict(lambda: {k: 0 for k in USAGE_KEYS}))   # dia UTC da MENSAGEM x modelo|effort (janela exata)
    days_ctx = defaultdict(lambda: defaultdict(lambda: {str(c): 0 for c in CTX_CAPS}))   # dia -> modelo -> teto -> tokens de cache-read ACIMA do teto
    synthetic = 0
    for ts, mid, m in ordered:
        if m["model"] == "<synthetic>":
            synthetic += 1                           # resposta sintética do cliente (erro/placeholder): não é chamada de modelo
            continue
        key = "_pre"
        for c in live:
            if c["ts"] <= ts:
                key = c["bead"]
            else:
                break
        for cap in CTX_CAPS:
            days_ctx[ts[:10] or "?"][m["model"]][str(cap)] += max(0, m["use"]["cr"] - cap)
        for agg in (buckets[key][f"{m['model']}|{m['effort']}"], days[ts[:10] or "?"][f"{m['model']}|{m['effort']}"]):
            for k in USAGE_KEYS[:-1]:
                agg[k] += m["use"][k]
            agg["msgs"] += 1
    stamps = [m["ts"] for m in msgs.values() if m["ts"]]
    try:
        st = main.stat()
        size, mtime_ns = st.st_size, st.st_mtime_ns
    except OSError:
        size = mtime_ns = 0
    return dict(v=SCHEMA, sid=sid, alias=alias or None, role=role, project=main.parent.name,
                cwd=cwd, first_ts=min(stamps) if stamps else None, last_ts=max(stamps) if stamps else None,
                size=size, mtime_ns=mtime_ns, fp=fingerprint(main), msgs=len(msgs), dup_lines=dup_lines, synthetic=synthetic,
                bad_lines=bad, no_usage=len(no_usage), lines=nlines, branches=branches,
                claims=[dict(bead=c["bead"], ts=c["ts"], ok=c["ok"], via=c["via"]) for c in live],
                refs=[[b, n] for b, n in refs.most_common(3)], claims_failed=failed,
                buckets={k: dict(v) for k, v in buckets.items()}, days={k: dict(v) for k, v in days.items()},
                days_ctx={d: {mo: dict(cc) for mo, cc in v.items()} for d, v in days_ctx.items()})


# ----------------------------------------------------------------------------- ledger
def load_ledger(path=None):
    path = Path(path or LEDGER)
    rows, bad = {}, 0
    if path.exists():
        with open(path, errors="replace") as fh:
            for line in fh:
                if not line.strip():
                    continue
                try:
                    r = json.loads(line)
                except Exception:
                    bad += 1
                    continue
                if r.get("sid"):
                    rows[r["sid"]] = r                  # a última linha de uma sessão vale
    return rows, bad


def write_ledger(rows, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".sessions.", dir=str(path.parent))
    with os.fdopen(fd, "w") as fh:
        for sid in sorted(rows, key=lambda s: (rows[s].get("first_ts") or "", s)):
            fh.write(json.dumps(rows[sid], sort_keys=True) + "\n")
    os.replace(tmp, path)


def merge_session(rows, rec):
    """True se `rec` entrou no ledger. Vence o registro com MAIS mensagens: a cópia do S3 pode ser mais velha que a local."""
    old = rows.get(rec["sid"])
    if old and old.get("v") == SCHEMA and old.get("msgs", 0) > rec["msgs"]:
        return False
    rows[rec["sid"]] = rec
    return True


def lock_ledger(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    lock = open(str(path) + ".lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return None
    return lock


def cmd_harvest(a):
    path = Path(a.ledger or LEDGER)
    lock = lock_ledger(path)
    if lock is None:
        print("harvest: outra colheita em curso (lock do ledger) — nada feito")
        return 0
    t0 = time.time()
    rows, bad_ledger = load_ledger(path)
    cutoff = time.time() - a.since_hours * 3600 if a.since_hours else 0
    scanned = unchanged = skipped_old = vanished = suspect = big = bad_lines = no_usage = 0
    for proj in PROJECTS:
        for f in sorted(proj.glob("*/*.jsonl")):
            try:
                if cutoff and f.stat().st_mtime < cutoff:
                    skipped_old += 1
                    continue
            except OSError:
                vanished += 1
                continue
            old = rows.get(f.stem)
            if old and old.get("fp") == fingerprint(f) and old.get("v") == SCHEMA and "days_ctx" in old:
                unchanged += 1
                continue
            rec = scan_session(f)
            if rec is None:
                vanished += 1
                continue
            bad_lines += rec["bad_lines"]
            no_usage += rec["no_usage"]
            if rec["lines"] >= 30:
                big += 1
                if rec["msgs"] == 0:
                    suspect += 1
            if merge_session(rows, rec):
                scanned += 1
            else:
                unchanged += 1
    write_ledger(rows, path)
    print(f"harvest: {scanned} sessões (re)escaneadas, {unchanged} inalteradas, {skipped_old} fora da janela, "
          f"{vanished} sumiram no meio; ledger={len(rows)} sessões (linhas ilegíveis no ledger: {bad_ledger}) "
          f"em {time.time() - t0:.1f}s -> {path}")
    if bad_lines or no_usage:
        print(f"⚠ nas sessões escaneadas: {bad_lines} linhas de transcrito ilegíveis e {no_usage} respostas SEM usage (tokens DESCONHECIDOS, "
              f"contados como 0 só no total — o gasto real é maior)")
    # Sessão lançada e morta antes da 1ª resposta existe (~0,7% das sessões: 1 prompt, 0 respostas) — não é alarme. Formato novo de
    # transcrito derruba a LEITURA de todas de uma vez: só acende quando ≥2 e ≥25% das sessões grandes desta colheita vieram com 0 respostas.
    if suspect >= 2 and suspect * 4 >= big:
        print(f"⚠ {suspect} de {big} sessões com ≥30 linhas vieram com 0 respostas lidas: formato do transcrito mudou? (0 respostas NÃO significa 0 gasto)")
    return 0


def s3_list(since_day):
    """-> [(key, size)] dos transcritos de topo (projects/<projeto>/<sessão>.jsonl) modificados desde since_day. Erro do aws = erro, nunca lista vazia."""
    q = f"Contents[?LastModified>='{since_day}'].[Key,Size]"
    p = subprocess.run([AWS, "s3api", "list-objects-v2", "--bucket", S3_BUCKET, "--prefix", "projects/", "--query", q, "--output", "text"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"aws s3api list-objects-v2 falhou (rc={p.returncode}): {p.stderr.strip()[:300]}")
    top, nested, odd = [], [0, 0], 0
    for line in p.stdout.splitlines():
        if "\t" not in line:
            if line.strip() not in ("", "None"):           # "None" = a consulta não casou nada; qualquer outra coisa é listagem que não entendi
                odd += 1
            continue
        key, _, size = line.partition("\t")
        parts = key.split("/")
        if len(parts) == 3 and parts[2].endswith(".jsonl"):
            top.append((key, int(size or 0)))
        else:
            nested[0] += 1
            nested[1] += int(size or 0)
    if odd:
        print(f"backfill-s3: ⚠ {odd} linhas da listagem do aws que não consegui interpretar (ignoradas — a listagem pode estar incompleta)")
    return top, nested


def cmd_backfill_s3(a):
    """Traz do arquivo permanente do S3 os transcritos que o reaper já apagou localmente, em LOTES pequenos (baixa, escaneia, apaga)."""
    path = Path(a.ledger or LEDGER)
    lock = lock_ledger(path)
    if lock is None:
        print("backfill-s3: outra colheita em curso (lock do ledger) — nada feito")
        return 0
    try:
        os.nice(10)
    except OSError:
        pass
    try:
        top, nested = s3_list(a.since)
    except RuntimeError as e:
        print(f"backfill-s3: ERRO — {e}\n  (lista vazia NÃO é o que aconteceu: o aws falhou; nada foi alterado)")
        return 2
    rows, _ = load_ledger(path)
    todo, skipped_scope, skipped_have = [], 0, 0
    for key, size in sorted(top):
        proj, sid = key.split("/")[1], key.split("/")[2][:-6]
        if proj == "-Users-athos-gt-whatsapp-automation" or proj.startswith("-private-tmp"):
            skipped_scope += 1                          # LLM de produto / experimentos de scratch: não são trabalho de bead
            continue
        have = rows.get(sid)
        if have and have.get("v") == SCHEMA and "days_ctx" in have and have.get("size", 0) >= size:
            skipped_have += 1                           # a cópia que o ledger já viu é pelo menos tão completa quanto a do S3
            continue
        todo.append((key, size, proj, sid))
    total_mb = sum(sz for _, sz, _, _ in todo) / 1e6
    print(f"backfill-s3: {len(top)} transcritos no S3 desde {a.since}; {len(todo)} a trazer ({total_mb:.0f} MB), {skipped_have} já no ledger, "
          f"{skipped_scope} fora de escopo (produto/scratch); {nested[0]} objetos aninhados ({nested[1] / 1e6:.0f} MB — subagentes/tool-results) NÃO "
          f"baixados: o gasto de subagente de crew/Mayor restaurado do S3 fica SUBESTIMADO")
    if a.dry_run:
        return 0
    merged = failed = kept = 0
    failures = []
    i = 0
    base = Path(a.tmp_dir) if a.tmp_dir else None
    while i < len(todo):
        batch, bsz = [], 0
        while i < len(todo) and (not batch or bsz + todo[i][1] <= a.batch_mb * 1e6):
            batch.append(todo[i]); bsz += todo[i][1]; i += 1
        tmp = Path(tempfile.mkdtemp(prefix="btm-s3-", dir=str(base) if base else None))
        try:
            free = shutil.disk_usage(tmp).free
            if free < bsz + a.min_free_gb * 1e9:
                print(f"backfill-s3: PARADO — disco livre {free / 1e9:.1f} GB < lote {bsz / 1e6:.0f} MB + piso {a.min_free_gb} GB. "
                      f"O que já entrou fica no ledger; rode de novo quando houver espaço.")
                write_ledger(rows, path)
                return 3
            # UM `aws s3 sync` por projeto com --include por sessão: 1 processo com pool de requisições próprio. Um `aws s3 cp` por objeto
            # media ~0,2 MB/s com a máquina saturada (load 47): a partida do aws custava mais que a transferência.
            by_proj = defaultdict(list)
            for item in batch:
                by_proj[item[2]].append(item)
            sync_err = {}
            for proj, items in by_proj.items():
                (tmp / proj).mkdir(parents=True, exist_ok=True)
                cmd = [AWS, "s3", "sync", f"s3://{S3_BUCKET}/projects/{proj}/", str(tmp / proj), "--only-show-errors", "--exclude", "*"]
                for _, _, _, sid in items:
                    cmd += ["--include", f"{sid}.jsonl"]
                r = subprocess.run(cmd, capture_output=True, text=True)
                if r.returncode != 0:
                    sync_err[proj] = r.stderr.strip()[:160] or f"rc={r.returncode}"
            for key, size, proj, sid in batch:
                dest = tmp / proj / f"{sid}.jsonl"
                if not dest.exists():
                    failed += 1                          # nunca silencioso: cada objeto que não chegou é contado e listado
                    failures.append((key, sync_err.get(proj, "objeto não veio no sync")))
                    continue
                rec = scan_session(dest)
                if rec is None:
                    failed += 1                          # baixou mas não consegui abrir: falha, não "já tinha registro mais completo"
                    failures.append((key, "transcrito baixado e ilegível"))
                elif merge_session(rows, rec):
                    merged += 1
                else:
                    kept += 1
            write_ledger(rows, path)                    # checkpoint a cada lote: interromper não perde o já trazido
            print(f"  lote {len(batch)} objetos ({bsz / 1e6:.0f} MB): acumulado {merged} novos/atualizados, {failed} falhas")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    print(f"backfill-s3: {merged} sessões entraram/atualizaram, {kept} já tinham registro mais completo, {failed} downloads FALHARAM; ledger={len(rows)}")
    for key, err in failures[:10]:
        print(f"  FALHOU {key}: {err}")
    return 0 if not failed else 4


# ----------------------------------------------------------------------------- log do gate
def load_gate(path=None):
    """-> (runs reais PASS/FAIL ordenadas, ponte ramo->bead, linhas ilegíveis). dry_run fora."""
    path = Path(path or GATE_LOG)
    runs, bridge, bad = [], {}, 0
    if not path.exists():
        return None, bridge, 0
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                r = json.loads(line)
            except Exception:
                bad += 1
                continue
            if r.get("branch") and r.get("bead"):
                bridge[r["branch"]] = r["bead"]
            if r.get("event") == "dispatcher_complete" and str(r.get("dry_run")) in ("0", "false", "False", "") \
                    and r.get("result") in ("PASS", "FAIL"):
                try:
                    r["_ts"] = parse_ts(r["ts"])
                except Exception:
                    bad += 1
                    continue
                runs.append(r)
    runs.sort(key=lambda r: r["_ts"])
    return runs, bridge, bad


# ----------------------------------------------------------------------------- report
def flatten(rows, since_day):
    """ledger -> lista de (sessão, dia, model, effort, contadores, usd|None), só dias >= since_day (YYYY-MM-DD, UTC)."""
    out = []
    for s in rows.values():
        for day, keys in (s.get("days") or {}).items():
            if day < since_day:
                continue
            for key, c in keys.items():
                model, _, effort = key.partition("|")
                out.append((s, day, model, effort, c, usd_of(model, c)))
    return out


def fmt_usd(x, unpriced=False):
    return "n/p" if x is None else (f"{x:8.2f}" + ("+" if unpriced else " "))


def cmd_report(a):
    """Texto por padrão; --json imprime SÓ o JSON (o texto das seções vai para o descarte)."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code, result = _report(a)
    if a.json:
        print(json.dumps(dict(result, exit_code=code), indent=1, default=str))
    else:
        print(buf.getvalue(), end="")
    return code


def _report(a):
    rows, bad_ledger = load_ledger(a.ledger)
    if not rows:
        print(f"SEM DADO: ledger vazio ou ausente ({a.ledger or LEDGER}). Rode `harvest` primeiro — vazio não é 'custo zero'.")
        return 2, {"error": "sem ledger"}
    now = dt.datetime.now(dt.timezone.utc)
    since = parse_ts(a.from_day + "T00:00:00Z") if a.from_day else (now - dt.timedelta(days=a.since_days)).replace(hour=0, minute=0, second=0, microsecond=0)
    since_day = since.strftime("%Y-%m-%d")      # janela em DIAS UTC inteiros: o gasto é somado por dia da mensagem, não por início de sessão
    flat = flatten(rows, since_day)
    sess = [s for s in rows.values() if s.get("first_ts") and (s.get("last_ts") or s["first_ts"])[:10] >= since_day]
    if not sess:
        print(f"SEM DADO: nenhuma sessão no ledger desde {since_day}.")
        return 2, {"error": "sem sessões na janela", "from_day": since_day}
    oldest = min(parse_ts(s["first_ts"]) for s in rows.values() if s.get("first_ts"))
    gate_runs, bridge, gate_bad = load_gate(a.gate_log)
    result = {"from_day": since_day, "ledger_oldest": oldest.isoformat(), "sessions": len(sess)}
    pool_floor = min((s["first_ts"] for s in rows.values() if s["role"] in POOL_BUILDERS and s.get("first_ts")), default=None)
    if pool_floor and since_day <= pool_floor[:10]:
        print(f"⚠ JANELA INCOMPLETA: começa em {since_day} mas o 1º transcrito de pool no ledger é de {pool_floor[:16]}Z — os dias antes de "
              f"{(parse_ts(pool_floor) + dt.timedelta(days=1)).strftime('%Y-%m-%d')} subestimam o gasto de pool/revisor (o reaper apaga transcrito "
              f"morto após 24h). Rode `backfill-s3 --since {since_day}` ou comece a janela depois.\n")

    # ---- 1. gasto por papel x modelo x effort
    agg = defaultdict(lambda: dict({k: 0 for k in USAGE_KEYS}, usd=0.0, unpriced=0, sessions=set()))
    for s, _day, model, effort, c, usd in flat:
        g = agg[(s["role"], model, effort)]
        for k in USAGE_KEYS:
            g[k] += c[k]
        g["sessions"].add(s["sid"])
        if usd is None:
            g["unpriced"] += total_tokens(c)
        else:
            g["usd"] += usd
    print(f"== 1. gasto por papel × modelo × effort — desde {since_day} (dias UTC inteiros), {len(sess)} sessões "
          f"(ledger desde {oldest:%Y-%m-%d %H:%MZ}; linhas ilegíveis do ledger: {bad_ledger})")
    print(f"{'papel':24s} {'modelo':20s} {'effort':7s} {'sess':>5s} {'msgs':>7s} {'Mtok total':>10s} {'cache-rd%':>9s} {'US$':>10s}")
    tot_usd, tot_unpriced, assumed_usd = 0.0, 0, 0.0
    by_role = []
    for (role, model, effort), g in sorted(agg.items(), key=lambda kv: -kv[1]["usd"]):
        tt = g["inp"] + g["out"] + g["cw5"] + g["cw1"] + g["cr"]
        if tt == 0:
            continue
        tot_usd += g["usd"]
        tot_unpriced += g["unpriced"]
        by_role.append(dict(role=role, model=model, effort=effort, sessions=len(g["sessions"]), msgs=g["msgs"], tokens=tt,
                            usd=None if g["unpriced"] and not g["usd"] else round(g["usd"], 4), unpriced_tokens=g["unpriced"]))
        usd_s = "n/p (sem preço)" if g["unpriced"] and not g["usd"] else f"{g['usd']:9.2f}" + ("~" if model in ASSUMED else " ")
        if model in ASSUMED:
            assumed_usd += g["usd"]
        print(f"{role:24s} {model:20s} {effort:7s} {len(g['sessions']):5d} {g['msgs']:7d} {tt / 1e6:10.2f} "
              f"{100 * g['cr'] / tt:8.0f}% {usd_s:>10s}")
    print(f"{'TOTAL precificado':24s} {'':20s} {'':7s} {'':5s} {'':7s} {'':10s} {'':9s} {tot_usd:10.2f}"
          + (f"   (+ {tot_unpriced / 1e6:.2f} Mtok de modelo SEM preço, fora do total)" if tot_unpriced else ""))
    if ASSUMED:
        print(f"   ~ = preço ASSUMIDO ({', '.join(f'{k}→{v}' for k, v in ASSUMED.items())}): US$ {assumed_usd:.2f} do total dependem dessa suposição")
    result["assumed_prices"] = dict(ASSUMED)
    result["assumed_usd"] = round(assumed_usd, 4)
    result["by_role"] = by_role
    result["total_usd_priced"] = round(tot_usd, 4)
    result["unpriced_tokens"] = tot_unpriced

    # ---- 1b. composição do custo: ONDE o gasto está (decide qual alavanca vale testar)
    comp = defaultdict(lambda: dict(parts=[0.0, 0.0, 0.0, 0.0], msgs=0, ctx=0, out=0, think=0, sessions=set()))
    for s, _day, model, effort, c, usd in flat:
        pr = usd_parts(model, c)
        if pr is None:
            continue
        g = comp[s["role"]]
        for i in range(4):
            g["parts"][i] += pr[i]
        g["msgs"] += c["msgs"]
        g["ctx"] += c["inp"] + c["cw5"] + c["cw1"] + c["cr"]
        g["out"] += c["out"]
        g["think"] += c["think"]
        g["sessions"].add(s["sid"])
    print(f"\n== 1b. composição do custo por papel (só modelos precificados): % do US$ em entrada nova / SAÍDA (inclui thinking) / escrita de cache / LEITURA de cache")
    print(f"{'papel':24s} {'US$':>9s} {'entr%':>6s} {'saída%':>7s} {'c.wr%':>6s} {'c.rd%':>6s} {'msgs/sessão':>12s} {'ctx/msg (tok)':>14s} {'saída/msg':>10s} {'thinking%':>10s}")
    comp_out = {}
    for role, g in sorted(comp.items(), key=lambda kv: -sum(kv[1]["parts"])):
        tot = sum(g["parts"])
        if tot <= 0 or not g["msgs"]:
            continue
        pct = [100 * x / tot for x in g["parts"]]
        ns = len(g["sessions"])
        print(f"{role:24s} {tot:9.2f} {pct[0]:6.1f} {pct[1]:7.1f} {pct[2]:6.1f} {pct[3]:6.1f} {g['msgs'] / ns:12.1f} {g['ctx'] / g['msgs']:14,.0f} "
              f"{g['out'] / g['msgs']:10,.0f} {100 * g['think'] / g['out'] if g['out'] else 0:9.0f}%")
        comp_out[role] = dict(usd=round(tot, 4), pct_input=round(pct[0], 2), pct_output=round(pct[1], 2), pct_cache_write=round(pct[2], 2),
                              pct_cache_read=round(pct[3], 2), msgs_per_session=round(g["msgs"] / ns, 2),
                              ctx_per_msg=round(g["ctx"] / g["msgs"]), output_per_msg=round(g["out"] / g["msgs"]))
    result["composition"] = comp_out

    # ---- 1c. teto de contexto: quanto da leitura de cache vive ACIMA de um teto (limite superior da economia de uma janela de compactação menor)
    cap_rows = defaultdict(lambda: dict(total_read_usd=0.0, above={str(c): 0.0 for c in CTX_CAPS}, covered=0, sessions=0))
    for s in rows.values():
        if not s.get("days_ctx"):
            continue
        g = cap_rows[s["role"]]
        g["sessions"] += 1
        for day, models in s["days_ctx"].items():
            if day < since_day:
                continue
            for model, caps in models.items():
                p_ = PRICES.get(model) or PRICES.get(ASSUMED.get(model, ""))
                if p_:
                    for cap, tokens in caps.items():
                        g["above"][cap] += tokens * p_[0] * CACHE_MULT["cr"] / 1e6
    for role, g in cap_rows.items():
        g["total_read_usd"] = comp[role]["parts"][3] if role in comp else 0.0
    print(f"\n== 1c. TETO DE CONTEXTO — US$ de LEITURA de cache acima de um teto por turno (limite SUPERIOR da economia de compactar mais cedo; ignora o custo da compactação e o risco de qualidade)")
    print(f"{'papel':14s} {'leitura US$':>11s} {'% do gasto':>10s}   " + "   ".join(f"acima de {c // 1000}k: US$ (% gasto do papel)" for c in CTX_CAPS))
    cap_out = {}
    for role, g in sorted(cap_rows.items(), key=lambda kv: -kv[1]["total_read_usd"]):
        if g["total_read_usd"] <= 0 or role not in comp:
            continue
        role_tot = sum(comp[role]["parts"])
        cells = "   ".join(f"{g['above'][str(c)]:9.2f} ({100 * g['above'][str(c)] / role_tot:4.1f}%)         " for c in CTX_CAPS)
        print(f"{role:14s} {g['total_read_usd']:11.2f} {100 * g['total_read_usd'] / role_tot:9.1f}%   {cells}")
        cap_out[role] = dict(read_usd=round(g["total_read_usd"], 2), role_usd=round(role_tot, 2),
                             above={str(c): round(g["above"][str(c)], 2) for c in CTX_CAPS})
    result["context_caps"] = cap_out

    # ---- 2. spawn ocioso (sessão de pool sem nenhum claim)
    idle = defaultdict(lambda: [0, 0.0])
    for s in sess:
        if s["role"] in POOL_BUILDERS and not s.get("claims"):
            idle[s["role"]][0] += 1
            for keys in (s.get("buckets") or {}).values():
                for key, c in keys.items():
                    u = usd_of(key.partition("|")[0], c)
                    idle[s["role"]][1] += u or 0.0
    print("\n== 2. spawn OCIOSO (sessão de pool que não reivindicou nenhum bead e saiu) — custo real, fora do custo por bead")
    for role in POOL_BUILDERS:
        n_all = sum(1 for s in sess if s["role"] == role)
        n, u = idle.get(role, [0, 0.0])
        print(f"  {role:10s} {n:4d} de {n_all:4d} sessões ociosas ({100 * n / n_all if n_all else 0:3.0f}%)  US$ {u:7.2f}"
              f"  ({u / n if n else 0:.3f}/spawn)")
    result["idle"] = {r: dict(sessions=v[0], usd=round(v[1], 4)) for r, v in idle.items()}

    # ---- 3. custo por bead (construtor + revisão) e 4. por bead APROVADA
    if gate_runs is None:
        print(f"\n== 3/4. SEM DADO: log do gate ausente ({a.gate_log or GATE_LOG}) — sem desfecho não há 'bead aprovada'.")
        return 2, dict(result, error="sem log do gate")
    return report_beads(a, rows, sess, flat, gate_runs, bridge, gate_bad, since, result)


def report_beads(a, rows, sess, flat, gate_runs, bridge, gate_bad, since, result):
    per = defaultdict(lambda: dict(build_usd=0.0, build_tok=0, review_usd=0.0, review_tok=0, pregate_usd=0.0, pregate_tok=0,
                                   unpriced=0, builders=[], first_builder=None))
    unmapped_review = 0
    all_sess = list(rows.values())         # o custo do bead conta mesmo que a sessão tenha começado ANTES da janela
    for s in all_sess:
        role = s["role"]
        beads = sorted({c["bead"] for c in s.get("claims") or []})
        for bucket, keys in (s.get("buckets") or {}).items():
            for key, c in keys.items():
                model, _, effort = key.partition("|")
                usd, tt = usd_of(model, c), total_tokens(c)
                if role in BUILDERS:
                    targets = beads if bucket == "_pre" else [bucket]
                    if bucket == "_pre" and not beads:
                        continue                                  # spawn ocioso: seção 2
                    for b in targets:
                        share = 1.0 / len(targets)
                        p = per[b]
                        if usd is None:
                            p["unpriced"] += tt * share
                        else:
                            p["build_usd"] += usd * share
                        p["build_tok"] += tt * share
                elif role in REVIEWERS:
                    b = next((bridge[x] for x in s.get("branches") or [] if x in bridge), None)
                    if not b:
                        unmapped_review += 1
                        continue
                    p = per[b]
                    fld = "pregate" if role == "pregate-review" else "review"
                    if usd is None:
                        p["unpriced"] += tt
                    else:
                        p[fld + "_usd"] += usd
                    p[fld + "_tok"] += tt
        if role in BUILDERS:
            for b in beads:
                per[b]["builders"].append((s["first_ts"] or "", role, s["alias"]))
    # arm do construtor = 1ª sessão de construtor do bead (intenção de tratar): papel + effort dominante dessa sessão
    first_session = {}
    for s in all_sess:
        if s["role"] in BUILDERS:
            eff = Counter()
            for keys in (s.get("buckets") or {}).values():
                for key, c in keys.items():
                    eff[key] += c["msgs"]
            top = eff.most_common(1)[0][0] if eff else "?|?"
            for c in s.get("claims") or []:
                b = c["bead"]
                cur = first_session.get(b)
                if cur is None or (s["first_ts"] or "") < cur[0]:
                    first_session[b] = (s["first_ts"] or "", s["role"], top, c.get("via") or "claim")
    first_run, ever_pass, nruns = {}, set(), Counter()
    for r in gate_runs:
        first_run.setdefault(r["bead"], r)
        nruns[r["bead"]] += 1
        if r["result"] == "PASS":
            ever_pass.add(r["bead"])
    in_win = [b for b, r in first_run.items() if r["_ts"] >= since]
    measured = [b for b in in_win if b in first_session]
    pool_floor = min((s["first_ts"] for s in all_sess if s["role"] in POOL_BUILDERS and s.get("first_ts")), default=None)
    why = Counter()
    for b in in_win:
        if b in first_session:
            continue
        br = first_run[b].get("branch") or ""
        parts = br.split("/")
        if pool_floor and first_run[b]["_ts"] < parse_ts(pool_floor):
            why["1ª rodada ANTES do 1º transcrito de pool no ledger (já apagado pelo reaper)"] += 1
        elif parts[0] == "crew" and len(parts) > 2 and parts[1] not in ("wa-worker", "ps-worker"):
            why["construído por crew/sessão conversacional (sem atribuição por bead)"] += 1
        elif parts[0] in ("fix", "feat", "chore"):
            why["branch fix/feat (dog, Mayor ou crew — dono não identificável pelo ramo)"] += 1
        else:
            why["wa-worker/ps-worker SEM sessão no ledger (lacuna real da atribuição)"] += 1
    print(f"\n== 3. beads com 1ª rodada do gate na janela: {len(in_win)}; com construtor de pool medido: {len(measured)} "
          f"({100 * len(measured) / len(in_win) if in_win else 0:.0f}%). Os {len(in_win) - len(measured)} sem medida ficam FORA das médias "
          f"(construtor NÃO MEDIDO nunca vira custo zero):")
    for k, n in why.most_common():
        print(f"     {n:4d}  {k}")
    print(f"   1º transcrito de pool no ledger: {pool_floor}; linhas ilegíveis do log do gate: {gate_bad}; "
          f"sessões de revisor sem ramo conhecido do gate: {unmapped_review}")
    result["coverage"] = dict(beads_in_window=len(in_win), measured=len(measured), unmeasured_by_reason=dict(why))
    n_ref = sum(1 for b in measured if first_session[b][3] == "ref")
    print(f"   atribuição dos {len(measured)} medidos: {len(measured) - n_ref} por `bd update --claim` verificado, {n_ref} por referência "
          f"a `bd show|comment|heartbeat|close` (worker com bead já atribuído — menos firme)")
    cohorts = defaultdict(list)
    for b in measured:
        _, role, key, _ = first_session[b]
        model, _, effort = key.partition("|")
        cohorts[(role, model, effort)].append(b)
    print(f"\n== 4. por COORTE do construtor (papel × modelo × effort da 1ª sessão do bead)")
    print(f"{'coorte':40s} {'beads':>5s} {'1ª-PASS':>9s} {'taxa 1ª [IC95%]':>20s} {'build$/bead':>11s} {'rev$/bead':>9s} "
          f"{'tot$/bead':>9s} {'Mtok/bead':>9s} {'$/bead 1ª-aprov.':>16s} {'aprov.(any)':>11s} {'$/bead aprov.':>13s}")
    out_c = []
    for coh, beads in sorted(cohorts.items(), key=lambda kv: -len(kv[1])):
        n = len(beads)
        k = sum(1 for b in beads if first_run[b]["result"] == "PASS")
        lo, hi = wilson(k, n)
        bu = [per[b]["build_usd"] for b in beads]
        ru = [per[b]["review_usd"] + per[b]["pregate_usd"] for b in beads]
        tt = [(per[b]["build_tok"] + per[b]["review_tok"] + per[b]["pregate_tok"]) for b in beads]
        unp = sum(1 for b in beads if per[b]["unpriced"])
        tot = sum(bu) + sum(ru)
        per_ok = tot / k if k else None
        n_ever = sum(1 for b in beads if b in ever_pass)
        per_ever = tot / n_ever if n_ever else None
        label = f"{coh[0]} {coh[1].replace('claude-', '')} {coh[2]}"
        print(f"{label:40s} {n:5d} {k:4d}/{n:<4d} {100 * k / n:6.1f}% [{100 * lo:3.0f},{100 * hi:3.0f}] "
              f"{statistics.mean(bu):11.3f} {statistics.mean(ru):9.3f} {statistics.mean(bu) + statistics.mean(ru):9.3f} "
              f"{statistics.mean(tt) / 1e6:9.2f} {('n/a (0 aprov.)' if per_ok is None else f'{per_ok:.3f}'):>16s} "
              f"{n_ever:5d}/{n:<5d} {('n/a' if per_ever is None else f'{per_ever:.3f}'):>13s}"
              + (f"  [{unp} bead(s) com token SEM preço]" if unp else ""))
        out_c.append(dict(cohort=label, beads=n, first_pass=k, rate=k / n, ci95=[lo, hi], build_usd_mean=statistics.mean(bu),
                          review_usd_mean=statistics.mean(ru), tokens_mean=statistics.mean(tt), usd_per_first_pass=per_ok,
                          ever_pass=n_ever, usd_per_approved=per_ever,
                          usd_total_sd=(statistics.pstdev([a + b for a, b in zip(bu, ru)]) if n > 1 else None),
                          build_usd_median=statistics.median(bu), beads_unpriced=unp))
    result["cohorts"] = out_c
    result["beads"] = {b: dict(role=first_session[b][1], arm=first_session[b][2], via=first_session[b][3],
                               first_gate=first_run[b]["result"], ever_pass=b in ever_pass, gate_runs=nruns[b],
                               build_usd=round(per[b]["build_usd"], 6), build_tokens=round(per[b]["build_tok"]),
                               review_usd=round(per[b]["review_usd"], 6), review_tokens=round(per[b]["review_tok"]),
                               pregate_usd=round(per[b]["pregate_usd"], 6), unpriced_tokens=round(per[b]["unpriced"]))
                       for b in measured}
    # sistema inteiro: US$ da janela / beads aprovadas na janela (não depende de nenhuma ponte sessão->bead)
    approved_win = {r["bead"] for r in gate_runs if r["result"] == "PASS" and r["_ts"] >= since}
    sys_usd = result["total_usd_priced"]
    print(f"\n== 5. SISTEMA INTEIRO (sem ponte sessão→bead): US$ {sys_usd:.2f} (todas as sessões, todos os papéis) ÷ "
          f"{len(approved_win)} beads com PASS no gate na janela = " +
          (f"US$ {sys_usd / len(approved_win):.2f} por bead aprovada" if approved_win else "n/a (nenhum PASS na janela)"))
    print("   inclui produto (LLM de WhatsApp etc.), crews, Mayor, revisores, refino e spawns ociosos — é o teto da métrica-norte.")
    result["system"] = dict(approved_beads=len(approved_win), usd_per_approved=(sys_usd / len(approved_win) if approved_win else None))
    result["power"] = power_section(first_session, first_run, per, ever_pass, measured)
    print("\nLeitura: 'aprovada' = 1ª rodada real do gate (PASS) por coorte; custo de rework (sessões extras do mesmo bead) entra no "
          "build$/bead. A coorte atribui ao braço da 1ª sessão — intenção de tratar.")
    return 0, result


def n_per_arm_mean(cv, delta):
    """beads por braço p/ detectar uma redução relativa `delta` da média (alfa 5% bilateral, poder 80%), dado o coeficiente de variação."""
    return 2 * (1.96 + 0.8416) ** 2 * cv ** 2 / delta ** 2


def n_per_arm_prop(p, diff):
    p2 = max(0.0, p - diff)
    return (1.96 * math.sqrt(2 * ((p + p2) / 2) * (1 - (p + p2) / 2)) + 0.8416 * math.sqrt(p * (1 - p) + p2 * (1 - p2))) ** 2 / diff ** 2


def power_section(first_session, first_run, per, ever_pass, measured):
    """Quanto um A/B POR BEAD enxerga com o volume que existe? O custo por bead tem cauda longa (CV >> 1): o critério 'não cair mais
    que 3 pp' precisa de milhares de beads por braço — sem esta conta o experimento 'inconclusivo' é só falta de poder."""
    out = {}
    print("\n== 6. PODER de um A/B por bead (alfa 5%, poder 80%, braços 50/50) — o que o volume atual permite enxergar")
    print(f"{'papel':10s} {'beads':>6s} {'beads/dia':>9s} {'CV US$/bead':>11s} {'1ª-aprov.':>9s}   n/braço p/ detectar custo −10% / −20% / −30%   |   1ª-aprov. ±10pp / ±5pp / ±3pp   (dias a 50/50)")
    for role in ("wa-worker", "dog"):
        beads = [b for b in measured if first_session[b][1] == role]
        if len(beads) < 20:
            print(f"{role:10s} {len(beads):6d}   (menos de 20 beads medidos: sem poder estatístico para estimar nada)")
            continue
        tot = [per[b]["build_usd"] + per[b]["review_usd"] + per[b]["pregate_usd"] for b in beads]
        mean = statistics.mean(tot)
        cv = statistics.pstdev(tot) / mean if mean else float("nan")
        ts = sorted(first_run[b]["_ts"] for b in beads)
        span = max((ts[-1] - ts[0]).total_seconds() / 86400, 1.0)
        rate = len(beads) / span
        p = sum(1 for b in beads if first_run[b]["result"] == "PASS") / len(beads)
        nm = [n_per_arm_mean(cv, d) for d in (0.10, 0.20, 0.30)]
        npp = [n_per_arm_prop(p, d) for d in (0.10, 0.05, 0.03)]
        days = lambda n: 2 * n / rate
        print(f"{role:10s} {len(beads):6d} {rate:9.1f} {cv:11.2f} {100 * p:8.0f}%   {nm[0]:6.0f} ({days(nm[0]):4.0f}d) / {nm[1]:5.0f} ({days(nm[1]):3.0f}d) / {nm[2]:5.0f} ({days(nm[2]):3.0f}d)"
              f"   |   {npp[0]:5.0f} ({days(npp[0]):3.0f}d) / {npp[1]:5.0f} ({days(npp[1]):4.0f}d) / {npp[2]:6.0f} ({days(npp[2]):4.0f}d)")
        out[role] = dict(beads=len(beads), beads_per_day=round(rate, 2), cv_usd_per_bead=round(cv, 3), first_pass=round(p, 3),
                         n_per_arm_cost=dict(zip(("-10%", "-20%", "-30%"), (round(x) for x in nm))),
                         n_per_arm_first_pass=dict(zip(("10pp", "5pp", "3pp"), (round(x) for x in npp))),
                         days_cost=dict(zip(("-10%", "-20%", "-30%"), (round(days(x)) for x in nm))),
                         days_first_pass=dict(zip(("10pp", "5pp", "3pp"), (round(days(x)) for x in npp))))
    print("   Leitura: dias = 2 × n/braço ÷ beads/dia (todos os beads do papel entrando no A/B). Onde 'dias' passa de ~30, o experimento por bead não fecha\n"
          "   nesse efeito: use métrica por MENSAGEM/turno (milhares de amostras) como primária e a aprovação só como trava de segurança.")
    return out


def cmd_prices(a):
    print("US$ por milhão de tokens (entrada / saída) — modelo fora da tabela NÃO é precificado (n/p):")
    for m, (i, o) in PRICES.items():
        print(f"  {m:22s} {i:6.2f} / {o:6.2f}   escrita cache 5m {i * CACHE_MULT['cw5']:.2f}  1h {i * CACHE_MULT['cw1']:.2f}  leitura {i * CACHE_MULT['cr']:.2f}")
    print("fonte entrada/saída: skill claude-api via bead ga-5c3msy (30/09/2026); multiplicadores de cache: documentação de prompt caching "
          "(5m 1,25x · 1h 2x · leitura 0,1x). Confira antes de decidir com base em US$ — tokens são exatos, preços são parâmetro.")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("harvest"); h.add_argument("--ledger"); h.add_argument("--since-hours", type=float, default=0)
    r = sub.add_parser("report"); r.add_argument("--ledger"); r.add_argument("--gate-log"); r.add_argument("--since-days", type=float, default=7)
    r.add_argument("--from", dest="from_day", metavar="YYYY-MM-DD", help="início da janela (dia UTC); vence --since-days")
    r.add_argument("--json", action="store_true")
    r.add_argument("--assume-price", action="append", default=[], metavar="MODELO=MODELO_PRECIFICADO",
                   help="usa o preço de MODELO_PRECIFICADO para MODELO (ex.: claude-sonnet-5=claude-sonnet-5-5). SUPOSIÇÃO sua: sai rotulada com ~")
    b = sub.add_parser("backfill-s3", help="traz do arquivo S3 os transcritos já apagados localmente (lotes pequenos, guarda de disco)")
    b.add_argument("--ledger"); b.add_argument("--since", required=True, metavar="YYYY-MM-DD", help="LastModified mínimo no S3")
    b.add_argument("--batch-mb", type=float, default=400)
    b.add_argument("--min-free-gb", type=float, default=3.0); b.add_argument("--tmp-dir"); b.add_argument("--dry-run", action="store_true")
    sub.add_parser("prices")
    a = p.parse_args(argv)
    for kv in getattr(a, "assume_price", []):
        old, _, new = kv.partition("=")
        if not old or new not in PRICES:
            p.error(f"--assume-price {kv!r}: o lado direito tem que ser um modelo da tabela ({', '.join(PRICES)})")
        ASSUMED[old] = new
    return {"harvest": cmd_harvest, "report": cmd_report, "prices": cmd_prices, "backfill-s3": cmd_backfill_s3}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
