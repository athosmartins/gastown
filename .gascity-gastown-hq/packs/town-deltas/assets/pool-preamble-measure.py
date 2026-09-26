#!/usr/bin/env python3
"""pool-preamble-measure.py — ga-aijm2v.6: MEDE (não estima) o efeito do "preâmbulo por papel".

    first-turn        tokens do 1º turno de cada sessão de pool, por papel (transcritos reais). Com --cutover mostra ANTES x DEPOIS
                      com o MESMO script — a medição que o critério de aceite pede.
    denied-attempts   depois do corte: alguma sessão TENTOU usar uma tool que o overlay do papel nega? (sinal de que negamos demais)
    gate-rate         guardrail: taxa de aprovação de 1ª tentativa no gate, N horas antes x depois do corte, com intervalo e veredito.

Somente leitura. Só stdlib. Um número de "1º turno" = input + cache_creation + cache_read da 1ª resposta do assistente = o contexto
que o modelo de fato leu no turno 1.

Papel de uma sessão = alias do beacon `[gascity] <alias> • <ts>` (1ª mensagem), NÃO o diretório do projeto: o diretório mistura
revisores, refinadores e dogs (o bucket do HQ tinha 776 revisores + 34 refinadores + ...).

Exemplos:
    pool-preamble-measure.py first-turn --since-hours 24
    pool-preamble-measure.py first-turn --since-hours 96 --cutover 2026-09-26T14:00:00Z
    pool-preamble-measure.py denied-attempts --since-hours 48 --cutover 2026-09-26T14:00:00Z
    pool-preamble-measure.py gate-rate --cutover 2026-09-26T14:00:00Z --window-hours 48
"""
import argparse
import datetime as dt
import glob
import json
import math
import os
import re
import statistics
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

PROJECTS = Path(os.environ.get("PPM_PROJECTS") or os.path.expanduser("~/.claude/projects"))
ASSETS = Path(__file__).resolve().parent
MANIFEST = ASSETS / "claude-overlays" / "pool-roles.json"
GATE_LOG = Path(os.environ.get("PPM_GATE_LOG") or "/Users/athos/gt/.gascity-gastown-hq/.gc/quality-gate.jsonl")

ROLE_RES = [  # ordem importa: refino-gate-reviewer antes de gate-reviewer
    (re.compile(r"^gastown\.dog-\d+"), "dog"),
    (re.compile(r"^wa-worker"), "wa-worker"),
    (re.compile(r"^ps-worker"), "ps-worker"),
    (re.compile(r"^refino-gate-reviewer"), "refino-gate-reviewer"),
    (re.compile(r"^gate-reviewer"), "gate-reviewer"),
    (re.compile(r"^auto-refiner"), "auto-refiner"),
    (re.compile(r"^context-check-reviewer"), "context-check-reviewer"),
    (re.compile(r"^gastown\.mayor"), "mayor"),
]
BEACON = re.compile(r"^\[gascity\]\s+(\S+)")
VANISHED = [0]   # transcritos que sumiram durante a varredura: descartados, mas CONTADOS e mostrados (nunca "sem sessão" calado)


def vanished_note():
    return f"  (transcritos que sumiram durante a varredura e ficaram de fora: {VANISHED[0]})" if VANISHED[0] else ""


def parse_ts(s):
    if s is None:
        return None
    s = str(s).strip()
    if re.fullmatch(r"\d+(\.\d+)?", s):
        return dt.datetime.fromtimestamp(float(s), dt.timezone.utc)
    d = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    return d if d.tzinfo else d.replace(tzinfo=dt.timezone.utc)


def role_of(alias):
    if not alias:
        return "unbeaconed"
    for rx, role in ROLE_RES:
        if rx.match(alias):
            return role
    return "other:" + alias.split("-adhoc-")[0][:28]


def first_text(rec):
    c = (rec.get("message") or {}).get("content")
    if isinstance(c, list):
        c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
    return c or ""


def scan_session(path):
    """-> dict(role, start, first, turns, tools Counter) ou None. Ignora sidechain (subagentes).

    O Claude Code grava UM registro JSONL por bloco de conteúdo (thinking / text / tool_use) e todos levam o MESMO message.id
    (medido nos 1.354 transcritos retidos em 26/09: o dedup por message.id antes de contar via 3.858 dos 35.781 tool_use dos papéis
    de pool, ~11%). Por isso são DUAS contagens com chaves diferentes:
      * tokens / turnos  -> dedup por message.id (o uso se repete em cada registro da mesma mensagem: somar duplicaria)
      * tool_use         -> dedup por id do BLOCO (toolu_...), contado em TODO registro — nunca atrás do dedup de mensagem,
                            senão "nenhuma tentativa de tool negada" passa a significar "não consegui ver as tentativas"."""
    alias = start = first = None
    turns, seen, seen_tools, tools = 0, set(), set(), Counter()
    try:
        fh = open(path, errors="replace")
    except OSError:
        VANISHED[0] += 1
        return None
    with fh:
        for line in fh:
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("isSidechain"):
                continue
            if start is None and r.get("timestamp"):
                try:
                    start = parse_ts(r["timestamp"])
                except Exception:
                    pass
            t = r.get("type")
            if t == "user" and alias is None:
                m = BEACON.match(first_text(r).lstrip())
                alias = m.group(1) if m else ""
            elif t == "assistant":
                msg = r.get("message") or {}
                for i, b in enumerate(msg.get("content") or []):    # tool_use: por BLOCO, antes de qualquer dedup de mensagem
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        key = b.get("id") or (msg.get("id"), i, b.get("name"))
                        if key not in seen_tools:
                            seen_tools.add(key)
                            tools[b.get("name")] += 1
                if msg.get("id") in seen:
                    continue
                seen.add(msg.get("id"))
                u = msg.get("usage")
                total = sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")) if u else 0
                if total == 0:
                    continue                      # mensagem <synthetic> (uso 0) não é um turno de modelo: contá-la como "1º turno = 0" corromperia a cauda baixa
                if first is None:
                    first = total
                turns += 1
    if first is None:
        return None
    return dict(role=role_of(alias), alias=alias, start=start, first=first, turns=turns, tools=tools, path=str(path))


def sessions(since_hours, roles=None):
    if not PROJECTS.is_dir():
        raise SystemExit(f"diretório de transcritos não encontrado: {PROJECTS} (defina PPM_PROJECTS) — sem ele não há como medir, e uma tabela vazia pareceria 'nenhuma sessão'")
    cut = time.time() - since_hours * 3600
    for p in glob.glob(str(PROJECTS / "*" / "*.jsonl")):
        try:
            if os.path.getmtime(p) < cut:
                continue
        except OSError:                       # transcrito apagado entre o glob e o stat (a limpeza de sessões de pool roda em paralelo)
            VANISHED[0] += 1
            continue
        s = scan_session(p)
        if s and (not roles or s["role"] in roles):
            yield s


def med(xs):
    return int(statistics.median(xs)) if xs else None


# ----------------------------------------------------------------------------- first-turn
def cmd_first_turn(a):
    roles = set(filter(None, a.roles.split(",")))
    cutover = parse_ts(a.cutover) if a.cutover else None
    by = defaultdict(lambda: {"before": [], "after": []})
    unknown_ts = 0
    for s in sessions(a.since_hours, roles):
        if cutover is None:
            by[s["role"]]["after"].append(s["first"])
        elif s["start"] is None:
            unknown_ts += 1
        else:
            by[s["role"]]["after" if s["start"] >= cutover else "before"].append(s["first"])
    if not by:
        why = (f"{unknown_ts} sessão(ões) de pool existem mas têm timestamp ilegível e não dá pra separar antes/depois do corte" if unknown_ts
               else f"nenhuma sessão de pool com transcrito nas últimas {a.since_hours:g}h" + (f" (papéis: {a.roles})" if roles else ""))
        print(f"SEM AMOSTRA: {why}. Isto NÃO é medição de zero — é ausência de dado." + vanished_note())
        return 2
    out = {}
    for role, d in sorted(by.items()):
        out[role] = {k: {"n": len(v), "median": med(v), "p10": med(sorted(v)[: max(1, len(v) // 10)]) if v else None,
                          "p90": sorted(v)[min(len(v) - 1, math.ceil(len(v) * 0.9) - 1)] if v else None} for k, v in d.items()}
    if a.json:
        json.dump({"cutover": a.cutover, "unknown_ts": unknown_ts, "vanished": VANISHED[0], "roles": out}, sys.stdout, indent=2, ensure_ascii=False)
        print()
        return 0
    if cutover is None:
        print(vanished_note().strip() or "(nenhum transcrito sumiu durante a varredura)")
        print(f"{'papel':24s} {'n':>5s} {'mediana 1º turno':>17s} {'p10':>9s} {'p90':>9s}")
        for role, d in out.items():
            x = d["after"]
            print(f"{role:24s} {x['n']:5d} {x['median']:17,d} {x['p10']:9,d} {x['p90']:9,d}")
        return 0
    print(f"corte = {a.cutover}   (sessões sem timestamp legível: {unknown_ts})")
    print(vanished_note().strip() or "(nenhum transcrito sumiu durante a varredura)")
    print(f"{'papel':24s} {'ANTES n':>8s} {'mediana':>10s} {'DEPOIS n':>9s} {'mediana':>10s} {'delta':>10s} {'%':>6s}")
    for role, d in out.items():
        b, f = d["before"], d["after"]
        if b["n"] and f["n"]:
            delta = f["median"] - b["median"]
            print(f"{role:24s} {b['n']:8d} {b['median']:10,d} {f['n']:9d} {f['median']:10,d} {delta:+10,d} {round(delta * 100 / b['median']):5d}%")
        else:
            print(f"{role:24s} {b['n']:8d} {b['median'] or 0:10,d} {f['n']:9d} {f['median'] or 0:10,d} {'(falta amostra de um dos lados)':>28s}")
    return 0


# ----------------------------------------------------------------------------- denied-attempts
def cmd_denied(a):
    m = json.load(open(MANIFEST, encoding="utf-8"))
    cutover = parse_ts(a.cutover) if a.cutover else None
    deny = {}
    for r in m["roles"].values():
        d = set(m["common"]["deny_tools"]) | set(r.get("deny_tools_extra", []))
        for ag in r["agents"]:
            deny[role_of("gastown.dog-0" if ag == "gastown.dog" else ag)] = d   # o beacon do dog é gastown.dog-N
    hits = defaultdict(Counter); n_sessions = Counter()
    for s in sessions(a.since_hours):
        if cutover and (s["start"] is None or s["start"] < cutover):
            continue
        d = deny.get(s["role"])
        if d is None:
            continue
        n_sessions[s["role"]] += 1
        for tool, c in s["tools"].items():
            if tool in d:
                hits[s["role"]][tool] += c
    print(f"sessões avaliadas (depois do corte): {dict(n_sessions) or 'nenhuma'}" + vanished_note())
    if not n_sessions:
        print("SEM AMOSTRA: nenhuma sessão de papel de pool depois do corte — não dá pra dizer que 'não há tentativas'. Espere spawns novos.")
        return 2
    no_data = sorted(r for r in deny if not n_sessions[r])
    if no_data:
        print(f"SEM DADO (nenhuma sessão na amostra — NÃO é 'sem tentativas'; a lista de deny desse papel não foi testada): {', '.join(no_data)}")
    if not hits:
        print("nenhuma tentativa de tool negada nos papéis com sessão — os cortes não parecem estar fazendo falta." + (" (papéis SEM DADO acima não foram avaliados)" if no_data else ""))
        return 0
    for role, c in hits.items():
        print(f"  ⚠ {role}: tentou tool NEGADA: {dict(c)}  -> reavaliar se essa tool deve sair de deny_tools no manifesto")
    return 1 if a.strict else 0


# ----------------------------------------------------------------------------- gate-rate
def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    den = 1 + z * z / n
    c = (p + z * z / (2 * n)) / den
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return (max(0.0, c - h), min(1.0, c + h))


def norm_cdf(x):
    return 0.5 * (1 + math.erf(x / math.sqrt(2)))


def load_gate():
    runs, bad = [], 0
    if not GATE_LOG.exists():
        raise SystemExit(f"log do gate não encontrado: {GATE_LOG}")
    with open(GATE_LOG, errors="replace") as fh:
        for line in fh:
            try:
                r = json.loads(line)
            except Exception:
                bad += 1
                continue
            if r.get("event") == "dispatcher_complete" and str(r.get("dry_run")) in ("0", "false", "False", "") and r.get("result") in ("PASS", "FAIL"):
                try:
                    r["_ts"] = parse_ts(r["ts"])
                except Exception:
                    bad += 1
                    continue
                runs.append(r)
    return sorted(runs, key=lambda r: r["_ts"]), bad


def cmd_gate_rate(a):
    cut = parse_ts(a.cutover)
    w = dt.timedelta(hours=a.window_hours)
    runs, bad = load_gate()
    first = {}
    for r in runs:                                   # 1ª execução EVER de cada bead (a "1ª tentativa")
        first.setdefault(r["bead"], r)
    now = dt.datetime.now(dt.timezone.utc)
    def bucket(lo, hi, rig=None):
        xs = [r for r in first.values() if lo <= r["_ts"] < hi and (rig is None or r["rig"] == rig)]
        k = sum(1 for r in xs if r["result"] == "PASS")
        return k, len(xs)
    lo_b, hi_b, lo_a, hi_a = cut - w, cut, cut, min(cut + w, now)
    kb, nb = bucket(lo_b, hi_b); ka, na = bucket(lo_a, hi_a)
    rig_names = sorted({r["rig"] for r in first.values() if lo_b <= r["_ts"] < hi_a})
    print(f"corte {a.cutover} | janela {a.window_hours}h antes x {(hi_a - lo_a).total_seconds() / 3600:.0f}h depois (linhas ilegíveis do log ignoradas: {bad})")
    print("métrica: 1ª execução do gate de cada bead == PASS  (TODOS os beads do gate: o log não registra quem construiu — gate.submitted_by vem vazio)\n")
    def line(lbl, k, n):
        lo, hi = wilson(k, n)
        print(f"  {lbl:22s} {k:4d}/{n:<4d} = {100 * k / n:5.1f}%   IC95% [{100 * lo:4.1f}%, {100 * hi:4.1f}%]" if n else f"  {lbl:22s}    0/0")
    line("ANTES", kb, nb); line("DEPOIS", ka, na)
    for rig in rig_names:
        k1, n1 = bucket(lo_b, hi_b, rig); k2, n2 = bucket(lo_a, hi_a, rig)
        if n1 + n2:
            print(f"    rig {rig:22s} antes {k1}/{n1}   depois {k2}/{n2}")
    if not nb or not na:
        print("\nVEREDITO: SEM AMOSTRA de um dos lados — não dá pra concluir (não é 'ok', é 'não sei'). Espere mais horas.")
        return 2
    # CONTROLE: a taxa do gate muda de regime sozinha (outras mudanças, mistura de beads). Sem ver a variação histórica, um teste de
    # significância dá falso alarme — medido: com um corte ARBITRÁRIO (sem nenhuma mudança) a taxa "caiu" 25 pontos, p~0.
    hist = []
    for i in range(1, a.history_windows + 1):
        h_hi = lo_b - w * (i - 1); h_lo = h_hi - w
        k, n = bucket(h_lo, h_hi)
        if n >= 20:
            hist.append((h_lo, k, n))
    if hist:
        rates = [k / n for _, k, n in hist]
        print(f"\n  histórico ({len(hist)} janelas de {a.window_hours:.0f}h anteriores, n>=20): " + "  ".join(f"{100 * k / n:.0f}%(n={n})" for _, k, n in hist))
        print(f"  faixa histórica: {100 * min(rates):.0f}% a {100 * max(rates):.0f}%")
    pb, pa = kb / nb, ka / na
    pool = (kb + ka) / (nb + na); se = math.sqrt(pool * (1 - pool) * (1 / nb + 1 / na)) or 1e-9
    z = (pa - pb) / se; p_drop = norm_cdf(z)         # P(depois < antes) unilateral sob H0 de igualdade
    print(f"\n  delta = {100 * (pa - pb):+.1f} pontos   (z={z:+.2f}; P(queda por acaso)={p_drop:.2f})")
    small = " [amostra pequena: <40 beads num lado]" if min(nb, na) < 40 else ""
    below_hist = bool(hist) and pa < min(rates)
    if pa >= pb:
        print(f"VEREDITO: OK — sem queda.{small}"); return 0
    if p_drop < 0.10 and below_hist:
        print(f"VEREDITO: ALERTA — queda significativa (p={p_drop:.2f}) E abaixo de TODAS as janelas históricas.{small}\n  Reverta a seção cortada que explica (doctrine.guarded em claude-overlays/pool-roles.json) ou o overlay do papel suspeito, e rode de novo.")
        return 1
    if p_drop < 0.10 and not hist:
        print(f"VEREDITO: SEM CONTROLE HISTÓRICO — queda significativa (p={p_drop:.2f}) mas nenhuma janela histórica com n>=20 pra separar queda real de variação do gate.{small}\n  Não dá pra concluir (não é 'ok', é 'não sei'): aumente --history-windows / --window-hours e meça de novo.")
        return 2
    why = "abaixo do ANTES mas dentro da faixa histórica (o gate varia sozinho)" if hist and not below_hist else "abaixo do ANTES mas sem significância"
    print(f"VEREDITO: {why} (p={p_drop:.2f}).{small}\n  Não reverta ainda: estenda --window-hours e meça de novo; com ~110 beads por janela o ruído é ~±4 pontos.")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("first-turn"); p.add_argument("--since-hours", type=float, default=24); p.add_argument("--cutover"); p.add_argument("--roles", default=""); p.add_argument("--json", action="store_true")
    p = sub.add_parser("denied-attempts"); p.add_argument("--since-hours", type=float, default=48); p.add_argument("--cutover"); p.add_argument("--strict", action="store_true")
    p = sub.add_parser("gate-rate"); p.add_argument("--cutover", required=True); p.add_argument("--window-hours", type=float, default=48); p.add_argument("--history-windows", type=int, default=6)
    a = ap.parse_args(argv)
    return {"first-turn": cmd_first_turn, "denied-attempts": cmd_denied, "gate-rate": cmd_gate_rate}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
