#!/usr/bin/env python3
"""gate-e5-apuracao.py — apuração do A/B E5 (ga-syxaki): 2º revisor independente no gate.

READ-ONLY, roda a qualquer hora, não escreve em bead nem em repositório. Fonte única:
`$GC_CITY/.gc/quality-gate.jsonl` (os eventos e5_* que o dispatcher escreve quando a flag
está ligada + a linha `dispatcher_complete` de cada run), e — só para o custo — as
transcrições das sessões de revisor em ~/.claude/projects/.

MÉTRICA PRIMÁRIA (relatório E4 §9, proposta 2, fase 2): BINÁRIA, por bead —
  "a bead cujo 1º FAIL de revisor foi nesta janela precisou de uma 2ª rodada de FAIL de
   revisor?"  (36,0% hoje; meta −15 pp; ≈139 beads com 1º FAIL por braço, ≈11 dias).
A contagem de rodadas por bead NÃO serve (desvio-padrão 1,3 para média 0,69).

TRÊS ESTADOS, SEMPRE (lição do E3: vazio ≠ não-sei):
  * desfecho da bead: 2ª-FAIL / resolveu-sem-2ª-FAIL / ainda-não-se-sabe. O "ainda não se sabe"
    NÃO entra na taxa; aparece ao lado, com os limites (melhor/pior caso).
  * custo de uma sessão de revisor: sabido (transcrição completa, preço conhecido) /
    desconhecido (transcrição incompleta, ambígua ou modelo sem preço) / sem registro
    (nenhuma transcrição). Custo "exato" por braço só existe quando TODAS as sessões do braço
    são "sabido"; fora disso o relatório diz quantas faltam e mostra só o piso medido.

O braço gravado em cada e5_admit é auditado: recalculado pela MESMA função do consumidor
(gate_e5_arm_for_bead, extraída da lib viva — nunca reimplementada). Divergência = aborta
alto, porque um braço calculado por outra regra não mede nada.

"SEM e5_admit NA JANELA" TAMBÉM TEM TRÊS ESTADOS (gate ga-syxaki, tentativa 4): o mesmo vazio sai
de "o experimento ainda não começou" e de "a flag está ligada e o E5 não está rodando" (lib que
não carregou, log que não grava) — e só o ARQUIVO DA FLAG diz qual dos dois é. Por isso a
apuração o lê (o mesmo arquivo que o dispatcher lê a cada varredura):
  * flag ausente  e nenhum e5_admit no log       -> "não começou"                      (rc 0)
  * flag ausente  e e5_admit fora da janela      -> "janela sem admissões"             (rc 0)
  * flag ligada desde T, e ≥ 1 run JULGADA que COMEÇOU depois de T + 10 min, zero e5_admit
                                                  -> ERRO ALTO: o E5 não está rodando   (rc 3)
  * flag ligada, mas nenhuma run julgada começou depois disso -> "ainda não dá para dizer" (rc 0)
  * flag existe e não pode ser lida              -> "não consigo saber"                 (rc 4)
"Run julgada" = PASS por quórum ou FAIL que um revisor emitiu: uma run que passou por aí
CERTAMENTE spawnou revisor e, com o E5 sano, CERTAMENTE escreveu e5_admit (o admit sai no spawn
do revisor 1; uma run que aborta antes dele legitimamente não tem). A margem de 10 min cobre a
varredura que leu a flag ANTES de ela ligar e só criou a run depois. Com e5_admit na janela, o
mesmo cruzamento vira aviso: runs julgadas sob a flag SEM e5_admit ficam fora do denominador.

Uso:  gate-e5-apuracao.py [--since YYYY-MM-DD] [--qg-log PATH] [--transcripts DIR]
                          [--lib PATH] [--flag-file PATH] [--price-json PATH] [--no-cost] [--json]
Saída: rc 0 = nada de errado achado; rc 1 = FATAL (auditoria/leitura); rc 3 = E5 ligado e sem
admitir; rc 4 = estado da flag ilegível.
"""
import argparse
import collections
import datetime
import glob
import json
import math
import os
import re
import subprocess
import sys

HQ = os.environ.get("GC_CITY", "/Users/athos/gt/.gascity-gastown-hq")
DEFAULT_LOG = os.path.join(HQ, ".gc", "quality-gate.jsonl")
DEFAULT_LIB = os.path.join(HQ, "packs", "town-deltas", "assets", "gate-e5-second-reviewer.lib.sh")
DEFAULT_TRANSCRIPTS = os.path.expanduser(
    "~/.claude/projects/-Users-athos-gt--gascity-gastown-hq--gc-agents-gate-reviewer")
JUDGED_RE = re.compile(r"^Reviewer \d+ FAIL:")
BEAD_TOKEN_RE = re.compile(r"\bga-(?:wisp-)?[a-z0-9]{4,12}\b")
SESSION_DONE_AGE_S = 15 * 60

# The flag the dispatcher reads on every sweep (gate_e5_enabled: readable file -> on). Same default and same
# override variable as gate-e5-switch.sh and the lib, so the three always look at the same file.
DEFAULT_FLAG = os.environ.get("GATE_E5_FLAG_FILE") or os.path.join(HQ, ".gc", "gate-e5-second-reviewer.on")
FLAG_STAMP_RE = re.compile(r"ligado em (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)")
# A sweep reads the flag at Step 5 and creates the run (the clock behind elapsed_s) a minute or two later: a run that
# started within this margin after the flag flipped may legitimately have read it as off.
FLAG_GRACE_S = 10 * 60
RC_NOT_ADMITTING = 3     # flag on, runs judged since, none admitted: the E5 is not running
RC_UNKNOWN = 4           # the flag file exists and cannot be read: no way to tell

# USD por 1M de tokens. PREÇOS DE LISTA ASSUMIDOS (Sonnet-classe) — confira e sobrescreva com
# --price-json {"<substring do modelo>": {"in":..,"out":..,"cache_read":..,"cache_write_5m":..,"cache_write_1h":..}}.
# Modelo sem linha aqui => custo "desconhecido" (nunca um número inventado).
DEFAULT_PRICES = {
    "sonnet": {"in": 3.0, "out": 15.0, "cache_read": 0.30, "cache_write_5m": 3.75, "cache_write_1h": 6.0},
}


# ── estatística ───────────────────────────────────────────────────────────────
def wilson(k, n, z=1.96):
    if n == 0:
        return (None, None)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), min(1.0, c + h))


def two_prop(k1, n1, k2, n2):
    """B − A: diferença, IC (Newcombe), p (z pooled, 2 lados). None quando um braço está vazio."""
    if n1 == 0 or n2 == 0:
        return None
    p1, p2 = k1 / n1, k2 / n2
    l1, u1 = wilson(k1, n1)
    l2, u2 = wilson(k2, n2)
    diff = p2 - p1
    lo = diff - math.sqrt((p2 - l2) ** 2 + (u1 - p1) ** 2)
    hi = diff + math.sqrt((u2 - p2) ** 2 + (p1 - l1) ** 2)
    pp = (k1 + k2) / (n1 + n2)
    se = math.sqrt(pp * (1 - pp) * (1 / n1 + 1 / n2))
    p_value = 1.0 if se == 0 else math.erfc(abs(diff / se) / math.sqrt(2))
    return {"diff": diff, "ci": (lo, hi), "p": p_value}


def pct(x):
    return "n/a" if x is None else "%.1f%%" % (100 * x)


def ci_txt(ci):
    return "[n/a]" if not ci or ci[0] is None else "[%.1f–%.1f]" % (100 * ci[0], 100 * ci[1])


# ── leitura ───────────────────────────────────────────────────────────────────
def read_events(path):
    events, bad = [], 0
    with open(path, errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                bad += 1
                continue
            if not isinstance(ev, dict) or "event" not in ev:
                continue
            events.append(ev)
    return events, bad


def audit_arms(lib, beads):
    """Recalcula o braço com a função VIVA da lib. Devolve {bead: arm} (arm "" = a função não deu braço);
    aborta se a função sumiu ou se o bash que a roda falhou — uma auditoria que não rodou não é uma que passou."""
    src = subprocess.run(["sed", "-n", "/^gate_e5_arm_for_bead()/,/^}/p", lib], capture_output=True, text=True).stdout
    if not src.strip():
        sys.exit("FATAL: gate_e5_arm_for_bead() não encontrada em %s — sem a regra de atribuição real o "
                 "experimento não pode ser apurado (um braço adivinhado não mede nada)." % lib)
    script = src + '\nwhile IFS= read -r b; do printf "%s %s\\n" "$b" "$(gate_e5_arm_for_bead "$b")"; done\n'
    proc = subprocess.run(["/bin/bash", "-c", script], input="\n".join(sorted(beads)) + "\n",
                          capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit("FATAL: a auditoria do braço não rodou (bash rc=%d: %s) — sem recalcular o braço pela lib viva "
                 "a apuração não é confiável." % (proc.returncode, (proc.stderr or "").strip()[:200]))
    return dict(line.split(" ", 1) for line in proc.stdout.splitlines() if " " in line)


# ── custo ─────────────────────────────────────────────────────────────────────
class TranscriptIndex:
    """verdict_bead -> [arquivo] : um passe só pelas transcrições (o id do verdict bead aparece
    nos comandos de veredito da tarefa, então identifica a sessão sem depender de session_key)."""

    def __init__(self, directory, wanted):
        self.by_bead = collections.defaultdict(list)
        self.unreadable = 0   # a transcript we could not open may be the one we are looking for
        self.available = bool(directory) and os.path.isdir(directory)
        if not self.available:
            return
        for path in glob.glob(os.path.join(directory, "*.jsonl")):
            try:
                with open(path, errors="replace") as fh:
                    text = fh.read()
            except OSError:
                self.unreadable += 1
                continue
            for tok in set(BEAD_TOKEN_RE.findall(text)) & wanted:
                self.by_bead[tok].append(path)


def transcript_usage(path):
    """{msg_id: {in,out,cache_read,w5,w1,model}} (o streaming repete o mesmo id: fica o maior),
    + (último stop_reason, mtime)."""
    msgs, last_stop = {}, None
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("type") != "assistant":
                continue
            m = o.get("message") or {}
            u = m.get("usage") or {}
            mid = m.get("id") or o.get("uuid")
            cc = u.get("cache_creation") or {}
            w5 = cc.get("ephemeral_5m_input_tokens")
            w1 = cc.get("ephemeral_1h_input_tokens")
            if w5 is None and w1 is None:
                w5, w1 = u.get("cache_creation_input_tokens") or 0, 0
            rec = {"in": u.get("input_tokens") or 0, "out": u.get("output_tokens") or 0,
                   "cache_read": u.get("cache_read_input_tokens") or 0, "w5": w5 or 0, "w1": w1 or 0,
                   "model": m.get("model") or ""}
            cur = msgs.get(mid)
            if cur is None or rec["out"] >= cur["out"]:
                msgs[mid] = rec
            last_stop = m.get("stop_reason")
    return msgs, last_stop, os.path.getmtime(path)


def price_for(model, prices):
    for key, p in prices.items():
        if key in (model or ""):
            return p
    return None


def session_cost(vb, index, prices, now):
    """('sabido', usd) | ('desconhecido', motivo) | ('sem_registro', None)."""
    files = index.by_bead.get(vb, []) if index.available else []
    if not files:
        # "no transcript found" is only "sem registro" when EVERY transcript was readable; with an
        # unreadable one in the directory the missing session may simply be that file.
        if index.available and index.unreadable:
            return ("desconhecido", "%d transcrição(ões) ilegível(is) no diretório" % index.unreadable)
        return ("sem_registro", None)
    total, reasons = 0.0, []
    for path in files:
        try:
            msgs, last_stop, mtime = transcript_usage(path)
        except OSError:
            return ("desconhecido", "transcrição ilegível")
        if not msgs:
            reasons.append("transcrição sem uso registrado")
            continue
        if now - mtime < SESSION_DONE_AGE_S or last_stop != "end_turn":
            reasons.append("sessão sem custo final (ainda ativa ou sem end_turn)")
            continue
        for rec in msgs.values():
            p = price_for(rec["model"], prices)
            if p is None:
                reasons.append("modelo sem preço: %s" % rec["model"])
                continue
            total += (rec["in"] * p["in"] + rec["out"] * p["out"] + rec["cache_read"] * p["cache_read"]
                      + rec["w5"] * p["cache_write_5m"] + rec["w1"] * p["cache_write_1h"]) / 1e6
    if reasons:
        return ("desconhecido", "; ".join(sorted(set(reasons))))
    return ("sabido", total)


# ── análise ───────────────────────────────────────────────────────────────────
def build_runs(events, since):
    runs = {}
    for ev in events:
        g = ev.get("gate_run")
        if since and str(ev.get("ts", ""))[:10] < since:
            continue
        if ev["event"] == "e5_admit" and g:
            runs[g] = {"gate_run": g, "bead": ev.get("bead", ""), "arm": ev.get("arm") or "?", "ts": ev.get("ts", ""),
                       "trigger": ev.get("trigger", "none"), "size_state": ev.get("size_state", ""),
                       "raw_lines": ev.get("raw_lines", ""), "rig": ev.get("rig", ""), "tier": ev.get("tier", ""),
                       "result": None, "reason": "", "extra": None, "declined": None, "abandoned": None,
                       "extra_verdict": None, "sessions": []}
    for ev in events:
        g = ev.get("gate_run")
        r = runs.get(g)
        if r is None:
            continue
        e = ev["event"]
        if e == "dispatcher_complete":
            r["result"], r["reason"] = ev.get("result"), ev.get("reason", "")
        elif e == "e5_extra_spawn":
            r["extra"] = ev
            r["sessions"].append(("extra", ev.get("extra_vb", "")))
        elif e == "e5_extra_declined":
            r["declined"] = ev.get("reason", "")
        elif e == "e5_extra_abandoned":
            r["abandoned"] = ev.get("reason", "")
        elif e == "e5_run_end":
            r["extra_verdict"] = ev.get("extra_verdict")
        elif e == "e5_session":
            r["sessions"].append(("slot%s" % ev.get("slot", "?"), ev.get("verdict_bead", "")))
    return runs


def judged_fail(run):
    return run["result"] == "FAIL" and bool(JUDGED_RE.match(run["reason"] or ""))


def history_of(events):
    """bead -> [{gate_run, ts, result, judged}] de TODAS as runs concluídas (com ou sem flag):
    "1º FAIL" e "1ª tentativa" só têm sentido contra a história inteira da bead."""
    h = collections.defaultdict(list)
    for ev in events:
        if ev["event"] != "dispatcher_complete" or not ev.get("gate_run") or ev.get("gate_run") == "unknown":
            continue
        res = ev.get("result")
        h[ev.get("bead", "")].append({
            "gate_run": ev["gate_run"], "ts": ev.get("ts", ""), "result": res,
            "judged": res == "FAIL" and bool(JUDGED_RE.match(ev.get("reason", "") or ""))})
    for runs in h.values():
        runs.sort(key=lambda r: r["ts"])
    return h


def per_bead(runs, history):
    """Desfecho primário por bead (3 estados) + aprovação na 1ª tentativa. Só entram as beads cuja
    1ª tentativa / cujo 1º FAIL foi uma run ADMITIDA SOB A FLAG (a flag pode ter sido ligada com a
    bead já em andamento: essas ficam de fora e são contadas)."""
    flagged = set(runs)
    # A bead's arm is read from ALL its admitted runs, not from whichever came first: the arm is a pure function of the bead id, so a run
    # recorded "?" (a sha tool that was missing for one sweep) says nothing about the bead — taking the first run's "?" dropped the whole
    # bead from A and B (gate attempt 3, non-blocking). Known arms win over "?"; two different known arms cannot be told apart from a
    # broken rule, so that bead stays "?" (the audit in analyse() already aborts on any recorded arm the live lib disagrees with).
    by_bead = collections.defaultdict(list)
    for r in sorted(runs.values(), key=lambda x: x["ts"]):
        by_bead[r["bead"]].append(r)
    arm_of, meta = {}, {}
    for bead, rs in by_bead.items():
        known = {r["arm"] for r in rs if r["arm"] in ("A", "B")}
        arm_of[bead] = next(iter(known)) if len(known) == 1 else "?"
        meta[bead] = next((r for r in rs if r["arm"] == arm_of[bead]), rs[0])   # the size it was admitted with, under the arm it is filed under
    out, excluded_prior = {}, 0
    for bead, arm in arm_of.items():
        hist = history.get(bead, [])
        first = hist[0] if hist else None
        ff_idx = next((i for i, h in enumerate(hist) if h["judged"]), None)
        outcome = None
        if ff_idx is not None:
            if hist[ff_idx]["gate_run"] not in flagged:
                excluded_prior += 1
                ff_idx = None
            else:
                later = hist[ff_idx + 1:]
                if any(h["judged"] for h in later):
                    outcome = "segunda_fail"
                elif any(h["result"] == "PASS" for h in later):
                    outcome = "resolveu_sem_segunda_fail"
                else:
                    outcome = "ainda_nao_se_sabe"
        m = meta[bead]
        out[bead] = {"arm": arm, "outcome": outcome,
                     "first_result": first["result"] if first and first["gate_run"] in flagged else None,
                     "size_state": m["size_state"], "raw_lines": m["raw_lines"], "rig": m["rig"]}
    return out, excluded_prior


# ── saúde do E5: o que um log SEM e5_admit pode (e não pode) querer dizer ──────────
def parse_ts(s):
    try:
        return datetime.datetime.strptime(str(s), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
    except ValueError:
        return None


def read_flag(path):
    """The flag file as the apuração must see it — three states, like the dispatcher's reader and the switch's status:
    ausente (does not exist) / ligada (readable; since when) / ilegivel (EXISTS but cannot be read — the dispatcher reads
    that as off, which is not the same fact as 'absent')."""
    if not os.path.exists(path):
        return {"estado": "ausente", "arquivo": path}
    try:
        with open(path, errors="replace") as fh:
            first = fh.readline().strip()
    except OSError as exc:
        return {"estado": "ilegivel", "arquivo": path, "motivo": str(exc)}
    since, src = None, None
    m = FLAG_STAMP_RE.search(first)
    if m:
        since, src = parse_ts(m.group(1)), "carimbo 'ligado em' do arquivo"
    if since is None:
        try:
            since, src = os.stat(path).st_mtime, "mtime do arquivo (o carimbo 'ligado em <ts>' não pôde ser lido)"
        except OSError as exc:
            return {"estado": "ilegivel", "arquivo": path, "motivo": "sem como saber desde quando: %s" % exc}
    return {"estado": "ligada", "arquivo": path, "desde": since, "desde_fonte": src, "linha": first[:160]}


def judged_complete(ev):
    """A completed run that CERTAINLY spawned a reviewer — a PASS by quorum, or a FAIL a reviewer judged — and so, with the E5
    healthy, certainly wrote an e5_admit (it is written when reviewer 1 is spawned). A run that aborted before spawning
    (no reviewer, source bead closed, merge failure after the verdict...) legitimately has none, so it is no evidence."""
    res, reason = ev.get("result"), ev.get("reason", "") or ""
    return (res == "PASS" and reason.startswith("quorum_")) or (res == "FAIL" and bool(JUDGED_RE.match(reason)))


def judged_runs_since(events, t0, since):
    """gate_run ids of the judged runs that STARTED at/after t0 (start = completion ts − elapsed_s) and, if --since is given,
    completed inside that window. A completion whose duration or timestamp cannot be read cannot be shown to have started
    after t0, so it is left out — absence of evidence, never evidence of a fault."""
    out = []
    for ev in events:
        g = ev.get("gate_run")
        if ev["event"] != "dispatcher_complete" or not g or g == "unknown" or str(ev.get("dry_run", "0")) == "1":
            continue
        if since and str(ev.get("ts", ""))[:10] < since:
            continue
        end = parse_ts(ev.get("ts"))
        try:
            dur = float(ev.get("elapsed_s"))
        except (TypeError, ValueError):
            continue
        if end is None or end - dur < t0 or not judged_complete(ev):
            continue
        out.append(g)
    return out


def e5_health(events, runs, flag, since):
    """Classify an apuração by what the FLAG says next to what the log holds. 'No e5_admit in the window' alone is ambiguous:
    it is what an experiment that has not started looks like, and also what a flag that is ON while the lib failed to load
    (quality-gate-dispatcher.sh: GATE_E5_LIB_OK=0) or a log that cannot be appended to looks like."""
    h = {"flag": flag, "admits_no_log": sum(1 for ev in events if ev["event"] == "e5_admit"),
         "admits_na_janela": len(runs), "estado": "ok", "rc": 0}
    if flag["estado"] == "ilegivel":
        h.update(estado="flag_ilegivel", rc=RC_UNKNOWN)
        return h
    if flag["estado"] == "ligada":
        t0 = flag["desde"] + FLAG_GRACE_S
        judged = judged_runs_since(events, t0, since)
        h["runs_julgadas_apos_a_flag"] = len(judged)
        h["runs_julgadas_sem_admit"] = sum(1 for g in judged if g not in runs)
        h["lib_nao_carregou_avisos"] = sum(1 for ev in events if ev["event"] == "e5_lib_not_loaded"
                                           and (parse_ts(ev.get("ts")) or 0) >= flag["desde"])
        if not runs:
            if judged:
                h.update(estado="ligado_sem_admitir", rc=RC_NOT_ADMITTING)
            else:
                h["estado"] = "ligado_sem_evidencia"
        return h
    if not runs:
        h["estado"] = "janela_sem_admissoes" if h["admits_no_log"] else "nao_comecou"
    return h


def age_txt(seconds):
    s = max(0, int(seconds))
    return "%dh%02dmin" % (s // 3600, (s % 3600) // 60) if s >= 3600 else "%dmin" % (s // 60)


def health_lines(h):
    """The flag/health part of the report. Every state says what it IS; none borrows another's wording."""
    f = h["flag"]
    now = datetime.datetime.now().timestamp()
    if f["estado"] == "ilegivel":
        return ["  ✗ NÃO CONSIGO SABER SE O E5 ESTÁ RODANDO: o arquivo da flag (%s) EXISTE e não pode ser lido (%s)." % (f["arquivo"], f.get("motivo", "?")),
                "    O dispatcher o lê como DESLIGADO (inerte), então o E5 pode estar parado sem que o log tenha como mostrar isso.",
                "    Corrija a permissão do arquivo, ou rode gate-e5-switch.sh off. (rc=%d)" % RC_UNKNOWN]
    on = ("  flag: LIGADA desde %s (%s) — há %s" % (datetime.datetime.fromtimestamp(f["desde"], datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                                    f["desde_fonte"], age_txt(now - f["desde"]))) if f["estado"] == "ligada" else None
    off = "  flag: DESLIGADA (arquivo %s ausente)" % f["arquivo"]
    st = h["estado"]
    if st == "ligado_sem_admitir":
        return [on,
                "  ✗ ERRO — O E5 ESTÁ LIGADO E NÃO ESTÁ ADMITINDO NADA: %d run(s) julgada(s) COMEÇARAM mais de %d min depois de a flag ligar e NENHUMA tem e5_admit." % (
                    h["runs_julgadas_apos_a_flag"], FLAG_GRACE_S // 60),
                "    Isto NÃO é 'o experimento ainda não começou'. Causas a olhar, nesta ordem:",
                "      · a lib não carregou no dispatcher (GATE_E5_LIB_OK=0 — erro de sintaxe/arquivo ilegível; avisos e5_lib_not_loaded no log desde a flag: %d);" % h["lib_nao_carregou_avisos"],
                "      · o log não grava (procure 'could not append' no log do dispatcher: disco cheio? permissão do quality-gate.jsonl?);",
                "      · o launchd roda outro dispatcher que não é este checkout (confira com ps/launchctl, não com o arquivo). (rc=%d)" % RC_NOT_ADMITTING]
    if st == "ligado_sem_evidencia":
        return [on,
                "  Sem e5_admit na janela, e NENHUMA run julgada começou depois da margem de %d min da flag — ainda não dá para dizer se o E5 está admitindo." % (FLAG_GRACE_S // 60),
                "  (isto não é 'sem problema' nem 'com problema': rode de novo depois que uma run concluir.)"]
    if st == "nao_comecou":
        return [off,
                "  Nenhum e5_admit no log inteiro e a flag está desligada: o experimento ainda não começou. Não há taxa nem custo para ler — isto é a ausência do experimento, não uma medição."]
    if st == "janela_sem_admissoes":
        return [off,
                "  Nenhum e5_admit NA JANELA (há %d no log, fora dela) e a flag está desligada agora — alargue a janela (--since) para ver as admissões anteriores." % h["admits_no_log"]]
    lines = [on or off]
    if h.get("runs_julgadas_sem_admit"):
        lines.append("  ⚠ %d das %d run(s) julgada(s) que começaram depois da flag NÃO têm e5_admit: ficam FORA de A e de B (denominador incompleto) — o E5 perdeu runs "
                     "(lib que falhou numa varredura? append que falhou? veja o log do dispatcher)." % (h["runs_julgadas_sem_admit"], h["runs_julgadas_apos_a_flag"]))
    return lines


SIZE_UNKNOWN = "tamanho desconhecido"


def size_bucket(b):
    try:
        return ">=800" if int(b["raw_lines"]) >= 800 else "<800"
    except (TypeError, ValueError):
        return SIZE_UNKNOWN


def analyse(events, args):
    runs = build_runs(events, args.since)
    res = {"runs_admitidas": len(runs)}
    res["saude"] = e5_health(events, runs, read_flag(args.flag_file), args.since)
    if not runs:
        return res, runs, {}
    # runs recorded with arm "?" (no bead id / no sha tool at admission) have no arm to audit and stay out of A/B: the audit covers exactly
    # the beads that have a recorded A or B, and every one of them must come back with an arm from the live lib.
    recorded = collections.defaultdict(set)
    for r in runs.values():
        if r["bead"] and r["arm"] in ("A", "B"):
            recorded[r["bead"]].add(r["arm"])
    audited = audit_arms(args.lib, set(recorded)) if recorded else {}
    # An audit that came back EMPTY (or short) is not an audit that found no divergence: a bead the live lib gave no arm for was not checked.
    unchecked = sorted(b for b in recorded if audited.get(b) not in ("A", "B"))
    if unchecked:
        sys.exit("FATAL: a auditoria do braço não recalculou %d de %d bead(s) com braço gravado, ex.: %s — o recálculo pela lib viva "
                 "não devolveu braço (sem ferramenta sha256? bash falhou?); sem ele a apuração não é confiável."
                 % (len(unchecked), len(recorded), ", ".join(unchecked[:5])))
    mism = sorted(b for b, arms in recorded.items() if arms - {audited[b]})
    if mism:
        sys.exit("FATAL: braço gravado ≠ braço recalculado pela lib viva em %d bead(s), ex.: %s — a regra de "
                 "atribuição mudou no meio do experimento; a apuração não é confiável." % (len(mism), ", ".join(mism[:5])))
    beads, excluded_prior = per_bead(runs, history_of(events))
    res["beads_com_1o_fail_anterior_a_flag_fora"] = excluded_prior
    if recorded:
        res["braco_auditado"] = "ok (%d beads com braço gravado recalculadas pela lib viva, 0 divergências)" % len(recorded)
    else:
        res["braco_auditado"] = "NADA AUDITADO (nenhuma run admitida tem braço A/B gravado — todas estão sem braço atribuível)"

    arms = {"A": collections.Counter(), "B": collections.Counter()}
    first_pass = {"A": [0, 0], "B": [0, 0]}
    no_arm = 0
    strata = collections.defaultdict(lambda: {"A": collections.Counter(), "B": collections.Counter()})
    for bead, b in beads.items():
        if b["arm"] not in arms:          # arm "?": not assignable -> in neither arm, counted apart
            no_arm += 1
            continue
        a = b["arm"]
        if b["outcome"]:
            arms[a][b["outcome"]] += 1
            strata[("tamanho", size_bucket(b))][a][b["outcome"]] += 1
            strata[("rig", b["rig"] or "?")][a][b["outcome"]] += 1
        if b["first_result"] in ("PASS", "FAIL"):
            first_pass[a][1] += 1
            first_pass[a][0] += 1 if b["first_result"] == "PASS" else 0
    res["beads_sem_braco"] = no_arm
    # the size stratification needs the diff MEASURED in both arms: how many beads per arm have no size (not measured = its own cell)
    res["tamanho_nao_medido"] = {a: sum(1 for b in beads.values() if b["arm"] == a and size_bucket(b) == SIZE_UNKNOWN) for a in ("A", "B")}
    res["beads_por_braco"] = {a: sum(1 for b in beads.values() if b["arm"] == a) for a in ("A", "B")}
    res["primaria"] = {a: dict(c) for a, c in arms.items()}
    res["primeira_tentativa"] = first_pass
    res["strata"] = {"%s=%s" % k: {a: dict(c) for a, c in v.items()} for k, v in sorted(strata.items())}

    delivery = {"B": collections.Counter()}
    for r in runs.values():
        if r["arm"] != "B":
            continue
        if r["extra"]:
            delivery["B"]["extra_disparado"] += 1
            delivery["B"]["gatilho:" + r["extra"].get("trigger", "?")] += 1
            if r["abandoned"]:
                delivery["B"]["extra_abandonado:" + r["abandoned"]] += 1
            elif r["extra_verdict"] in ("PASS", "FAIL"):
                delivery["B"]["extra_entregou:" + r["extra_verdict"]] += 1
            elif r["extra_verdict"] == "NONE":
                delivery["B"]["extra_fechou_sem_veredito"] += 1
            elif r["extra_verdict"] == "UNREADABLE":
                delivery["B"]["extra_comentarios_ilegiveis"] += 1
            elif r["extra_verdict"] == "-":
                delivery["B"]["extra_ainda_pendente_no_fim_da_run"] += 1
            else:
                # no e5_run_end line for this run at all (still running, or the line was lost): unknown, not "delivered nothing"
                delivery["B"]["extra_sem_veredito_registrado"] += 1
        elif r["declined"]:
            delivery["B"]["recusado:" + re.sub(r":.*", "", r["declined"])] += 1
        elif r["trigger"] == "big-diff":
            delivery["B"]["big-diff_sem_extra_registrado"] += 1
        else:
            delivery["B"]["sem_gatilho"] += 1
    res["entrega_do_tratamento"] = dict(delivery["B"])

    if not args.no_cost:
        prices = dict(DEFAULT_PRICES)
        if args.price_json:
            with open(args.price_json) as fh:
                prices = json.load(fh)
        wanted = {vb for r in runs.values() for _, vb in r["sessions"] if vb}
        idx = TranscriptIndex(args.transcripts, wanted)
        now = datetime.datetime.now().timestamp()
        cost = collections.defaultdict(collections.Counter)
        usd = collections.defaultdict(float)
        usd_extra = 0.0
        per_bead_states = collections.defaultdict(lambda: collections.defaultdict(list))
        for r in runs.values():
            for slot, vb in r["sessions"]:
                state, val = session_cost(vb, idx, prices, now)
                cost[r["arm"]][state] += 1
                per_bead_states[r["arm"]][r["bead"]].append(state)
                if state == "sabido":
                    usd[r["arm"]] += val
                    if slot == "extra":
                        usd_extra += val
        res["custo"] = {
            "transcricoes_disponiveis": idx.available,
            "sessoes_por_estado": {a: dict(c) for a, c in cost.items()},
            "usd_sabido_piso": {a: round(v, 2) for a, v in usd.items()},
            "usd_sabido_so_extras": round(usd_extra, 2),
            "beads_com_custo_exato": {a: sum(1 for st in d.values() if all(s == "sabido" for s in st))
                                      for a, d in per_bead_states.items()},
            "beads_total": {a: len(d) for a, d in per_bead_states.items()},
            "precos_usd_por_Mtok_ASSUMIDOS": prices,
        }
    return res, runs, beads


def render(res, args, bad_lines):
    L = ["═══ APURAÇÃO DO A/B E5 — 2º revisor independente (ga-syxaki) ═══"]
    L.append("  janela: %s · fonte: %s" % ("a partir de " + args.since if args.since else "log inteiro", args.qg_log))
    if bad_lines:
        L.append("  ⚠ %d linha(s) ilegíveis no log foram ignoradas" % bad_lines)
    L.append("\n── estado do E5 (a flag que o dispatcher lê, cruzada com o que o log tem) ──")
    L.extend(health_lines(res["saude"]))
    if not res.get("runs_admitidas"):
        return "\n".join(L)
    L.append("\n  runs admitidas sob a flag: %d · braço: %s" % (res["runs_admitidas"], res["braco_auditado"]))
    if res.get("beads_sem_braco"):
        L.append("  ⚠ %d bead(s) sem braço atribuível (sem id ou sem ferramenta sha256 na admissão): fora de A e de B." % res["beads_sem_braco"])
    if res.get("beads_com_1o_fail_anterior_a_flag_fora"):
        L.append("  %d bead(s) já tinham o 1º FAIL ANTES da flag e ficam fora da métrica primária." % res["beads_com_1o_fail_anterior_a_flag_fora"])
    L.append("\n── MÉTRICA PRIMÁRIA: bead com 1º FAIL de revisor precisou de uma 2ª rodada de FAIL? ──")
    a, b = res["primaria"]["A"], res["primaria"]["B"]
    ka, kb = a.get("segunda_fail", 0), b.get("segunda_fail", 0)
    na, nb = ka + a.get("resolveu_sem_segunda_fail", 0), kb + b.get("resolveu_sem_segunda_fail", 0)
    ua, ub = a.get("ainda_nao_se_sabe", 0), b.get("ainda_nao_se_sabe", 0)
    L.append("  %-10s %10s %10s %14s %22s" % ("braço", "2ª FAIL", "resolveu", "taxa [IC95%]", "ainda não se sabe"))
    for name, k, n, u in (("A (ctrl)", ka, na, ua), ("B (2º rev)", kb, nb, ub)):
        lo, hi = wilson(k, n)
        L.append("  %-10s %10d %10d %14s %22d" % (name, k, n - k, "%s %s" % (pct(k / n if n else None), ci_txt((lo, hi))), u))
    d = two_prop(ka, na, kb, nb)
    if d:
        L.append("  B − A: %+.1f pp  IC95%% [%.1f; %.1f]  p=%.3f (2 lados)" % (100 * d["diff"], 100 * d["ci"][0], 100 * d["ci"][1], d["p"]))
        if ua or ub:
            L.append("  ⚠ %d bead(s) ainda sem desfecho (A: %d, B: %d) ficam FORA da taxa; não conclua antes delas resolverem." % (ua + ub, ua, ub))
    else:
        L.append("  (sem beads resolvidas nos dois braços ainda — nada a comparar)")
    L.append("  poder: alvo −15 pp (36%% → 21%%) pede ≈139 beads com 1º FAIL por braço (≈11 dias). Hoje: A=%d B=%d resolvidas%s." % (
        na, nb, "" if min(na, nb) >= 139 else " — AINDA NÃO CONCLUSIVO; não pare o experimento por estar agradável"))
    fa, fb = res["primeira_tentativa"]["A"], res["primeira_tentativa"]["B"]
    L.append("\n── secundária: aprovação na 1ª tentativa (por bead; o braço B tende a cair nos diffs ≥ 800 linhas,")
    L.append("   onde o 2º revisor roda em paralelo e pode reprovar o que 1 revisor aprovaria — é custo esperado, não defeito) ──")
    L.append("  A: %d/%d (%s)   B: %d/%d (%s)" % (fa[0], fa[1], pct(fa[0] / fa[1] if fa[1] else None), fb[0], fb[1], pct(fb[0] / fb[1] if fb[1] else None)))
    L.append("\n── estratos (tamanho do diff, rig): 2ª-FAIL / resolveu por braço ──")
    nm, nb_ = res["tamanho_nao_medido"], res["beads_por_braco"]
    if nm["A"] or nm["B"]:
        L.append("  ⚠ tamanho do diff NÃO medido em A: %d de %d bead(s), B: %d de %d — ficam na linha 'tamanho desconhecido'; "
                 "um braço sem tamanho medido não pode ser comparado por estrato de tamanho." % (nm["A"], nb_["A"], nm["B"], nb_["B"]))
    for k, v in res["strata"].items():
        sa, sb = v["A"], v["B"]
        L.append("  %-28s A: %d/%d   B: %d/%d" % (k, sa.get("segunda_fail", 0), sa.get("segunda_fail", 0) + sa.get("resolveu_sem_segunda_fail", 0),
                                                   sb.get("segunda_fail", 0), sb.get("segunda_fail", 0) + sb.get("resolveu_sem_segunda_fail", 0)))
    L.append("\n── o tratamento foi ENTREGUE? (runs do braço B) ──")
    for k, v in sorted(res["entrega_do_tratamento"].items()):
        L.append("  %-44s %d" % (k, v))
    L.append("  (recusado:* / extra_abandonado:* = braço B que rodou como A; conte-os ao ler o resultado: intenção-de-tratar é por braço,")
    L.append("   a leitura 'o 2º revisor funciona' precisa só dos que o receberam e ele entregou.)")
    if "custo" in res:
        c = res["custo"]
        L.append("\n── custo (3 estados por sessão de revisor) ──")
        if not c["transcricoes_disponiveis"]:
            L.append("  ⚠ diretório de transcrições ausente — TODO o custo é 'sem registro' (isto não é custo zero).")
        for arm in ("A", "B"):
            st = c["sessoes_por_estado"].get(arm, {})
            L.append("  braço %s: sabido=%d desconhecido=%d sem_registro=%d · US$ %.2f medido (PISO — só as sessões 'sabido') · beads com custo exato: %d de %d" % (
                arm, st.get("sabido", 0), st.get("desconhecido", 0), st.get("sem_registro", 0), c["usd_sabido_piso"].get(arm, 0.0),
                c["beads_com_custo_exato"].get(arm, 0), c["beads_total"].get(arm, 0)))
        L.append("  só os revisores EXTRAS (medido): US$ %.2f · preços ASSUMIDOS (lista Sonnet-classe) — sobrescreva com --price-json" % c["usd_sabido_so_extras"])
        L.append("  NUNCA leia 'exato' onde houver sessão desconhecida/sem registro: o número é um piso.")
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", default="")
    ap.add_argument("--qg-log", default=DEFAULT_LOG)
    ap.add_argument("--lib", default=DEFAULT_LIB)
    ap.add_argument("--flag-file", default=DEFAULT_FLAG, help="the E5 flag file the dispatcher reads (default: GATE_E5_FLAG_FILE or $GC_CITY/.gc/gate-e5-second-reviewer.on)")
    ap.add_argument("--transcripts", default=DEFAULT_TRANSCRIPTS)
    ap.add_argument("--price-json", default="")
    ap.add_argument("--no-cost", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    if not os.access(args.qg_log, os.R_OK):
        sys.exit("FATAL: não consigo ler %s" % args.qg_log)
    events, bad = read_events(args.qg_log)
    res, _, _ = analyse(events, args)
    if args.json:
        json.dump(res, sys.stdout, indent=2, default=str)
        print()
    else:
        print(render(res, args, bad))
    # the exit status carries the third state too: 0 only when nothing wrong was found (see the docstring)
    sys.exit(res["saude"]["rc"])


if __name__ == "__main__":
    main()
