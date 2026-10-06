#!/usr/bin/env python3
"""jev_gate_fail_desfecho_report.py (ga-rmzfye, filho de ga-ufskhy) — o Jev "gate-fail-categoria"
acerta o que importa? Mede a sombra contra o DESFECHO real do conserto, sem rótulo humano.

PERGUNTA DE NEGÓCIO: entre as reprovações que o Jev marcou `ajuste_pequeno` com prob >= 0.7,
quantas passaram na rodada SEGUINTE com conserto < 50 linhas — contra a base (`bug_logica`)?
Separação clara (>= 20 pp e n >= 30) => vale propor o A/B de conserto leve; senão, desligar a sombra.

POR QUE ESTE SCRIPT E NÃO O jev_gate_fail_categoria_report.py: aquele conta "repair approved" por
categoria. Faltavam as duas outras pernas do desfecho (tamanho do conserto, tempo até reenvio), o
corte prob>=0.7 / <50 linhas, e os TRÊS ESTADOS de verdade:
  - a sombra só grava a entidade (bead#N) DEPOIS que a revisão do conserto aterrissa, então uma
    reprovação que nunca foi reenviada nem aparece no log do Jev. Ela é contada aqui a partir do
    log do gate como "ainda sem desfecho" — nunca como "falhou" e nunca com categoria (o Jev
    nunca a classificou).
  - a rodada seguinte pode ter reprovado por motivo MECÂNICO (timeout de revisor, merge quebrado
    após all-PASS, veredito não registrado): isso não julga o conserto. Fica fora do denominador
    de "passou", contado à parte. Mesma regra do classify_fail_reason() do gate-rate
    (pool-preamble-measure.py, ga-w3yvoz) — espelhada aqui porque aquele arquivo tem hífen no
    nome e não é importável.
  - tamanho do conserto: "medido" / "nao-medido (motivo)". SHA sumiu ou commit não está no clone
    local NÃO vira 0 linhas.

READ-ONLY: lê quality-gate.jsonl, jev-experiment.jsonl, `bd show` e `git diff`. Não escreve em
nenhum deles, não faz `git fetch`, não muda nada no gate. O único arquivo que pode escrever é o
--cache que VOCÊ passa (default: nenhum, tudo em memória).

TAMANHO DO CONSERTO (linhas adicionadas + removidas entre o SHA reprovado e o seguinte):
  - SHA seguinte descende do reprovado  -> `git diff --numstat reprovado seguinte` (exato).
  - histórico reescrito (rebase)        -> o diff cru incluiria o trabalho que entrou na main
    entre as rodadas e inflaria o "conserto". Aí mede-se a DIFERENÇA ENTRE OS DOIS PATCHES (cada
    um contra a SUA base): linhas +/- que só existem em um deles. A base de cada SHA NÃO é o
    base_commit do marker: o dispatcher rebaseia o branch antes de revisar e registra no marker
    "auto-rebased onto main (X). New tip: Y"; a base de Y é X. (Usar o base_commit velho carregava
    a deriva do main — milhares de linhas — pro "conserto": mediana ~2000 linhas em vez de ~90.)
    Base que não se consegue estabelecer = nao-medido (motivo), nunca chute nem 0.

CORTE "marcadas ajuste_pequeno com prob >= 0.7": as cinco perguntas do Jev são sim/não
independentes, então `bug_logica` costuma vencer o argmax mesmo com `ajuste_pequeno` alto. Leitura
primária (a do enunciado, "marcadas" vs base bug_logica): categoria_jev == ajuste_pequeno E
prob_categoria >= 0.7. Sensibilidade: probabilidades.ajuste_pequeno >= 0.7, independente do argmax.

CLI:
  python3 jev_gate_fail_desfecho_report.py [--json] [--cache PATH] [--workers N] [--limit N]
         [--log PATH] [--gate-log PATH] [--gc-city PATH]
  python3 jev_gate_fail_desfecho_report.py selftest
"""
from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
import tempfile
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import jev_experiment as je  # noqa: E402
import jev_gate_fail_categoria_experiment as fc  # noqa: E402
import jev_gate_fail_categoria_report as cr  # noqa: E402
import jev_gate_verdict_experiment as gv  # noqa: E402
import jev_quem_pensa_experiment as qp  # noqa: E402

MIN_PROB = 0.7
SMALL_LINES = 50
SENSITIVITY_LINES = (50, 200)  # 50 = régua do enunciado; 200 = sensibilidade (piso: <50 é raro)
MIN_DELTA_PP = 20.0
MIN_N = 30
PENDING_FRESH_HOURS = 24.0  # FAIL sem reenvio há menos que isso ainda pode estar a caminho
LIGHT = fc.LIGHT_FIX_CATEGORY
BASE = "bug_logica"
SUBMIT_EVENTS = ("guard_queued", "guard_dispatched")


# ── classificação do FAIL: revisão real x mecânico ───────────────────────────────────────────
def fail_kind(reason: str | None) -> str:
    """'review' (um revisor leu o diff e reprovou) | 'mechanical' (plumbing do gate; não julga o
    código) | 'unknown' (reason ausente: terceiro estado, fora das contas). Mesmas regras de
    classify_fail_reason() em pool-preamble-measure.py."""
    if not reason:
        return "unknown"
    if reason.startswith(("TIMEOUT", "Merge failed", "Post-merge integrity check failed")):
        return "mechanical"
    if "No reviewer judgment was recorded" in reason:
        return "mechanical"
    return "review"


# ── estatística mínima (sem scipy) ───────────────────────────────────────────────────────────
def wilson(k: int, n: int, z: float = 1.96) -> tuple[float, float] | None:
    if n == 0:
        return None
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return max(0.0, c - h), min(1.0, c + h)


def newcombe_diff(k1: int, n1: int, k2: int, n2: int) -> tuple[float, float] | None:
    """IC 95% (Newcombe, híbrido-score) de p1 - p2, em pontos percentuais."""
    a, b = wilson(k1, n1), wilson(k2, n2)
    if a is None or b is None:
        return None
    p1, p2 = k1 / n1, k2 / n2
    lo = (p1 - p2) - math.sqrt((p1 - a[0]) ** 2 + (b[1] - p2) ** 2)
    hi = (p1 - p2) + math.sqrt((a[1] - p1) ** 2 + (p2 - b[0]) ** 2)
    return 100 * lo, 100 * hi


# ── git: tamanho do conserto ─────────────────────────────────────────────────────────────────
def _numstat_total(repo: str, a: str, b: str) -> int | None:
    out = gv._git_text(repo, ["diff", "--numstat", a, b])
    if out is None:
        return None
    total = 0
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3:
            total += sum(int(x) for x in parts[:2] if x.isdigit())  # '-' (binário) conta 0
    return total


def _patch_size(repo: str, base: str, head: str) -> int | None:
    """Linhas +/- do patch inteiro da rodada (`base...head`): a régua pra dizer se um conserto é
    grande ou pequeno RELATIVO ao que foi reprovado."""
    out = gv._git_text(repo, ["diff", "--numstat", f"{base}...{head}"], timeout=60)
    if out is None:
        return None
    return sum(int(x) for ln in out.splitlines() for x in ln.split("\t")[:2] if x.isdigit())


def _is_ancestor(repo: str, a: str, b: str) -> bool | None:
    r = gv._run(["git", "-C", repo, "merge-base", "--is-ancestor", a, b], timeout=15)
    if r is None or r.returncode not in (0, 1):
        return None
    return r.returncode == 0


_HUNK = re.compile(r"^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@")


def _patch_lines(repo: str, base: str, head: str) -> Counter | None:
    """Multiconjunto de (arquivo, sinal, texto) das linhas +/- de `base...head`. Lê por hunk
    (contagem do cabeçalho), não por prefixo: uma linha adicionada que COMEÇA com '++ ' aparece
    como '+++ ' e seria confundida com cabeçalho de arquivo."""
    out = gv._git_text(repo, ["diff", "-U0", "--no-color", "--no-ext-diff", f"{base}...{head}"], timeout=60)
    if out is None:
        return None
    lines, i, path, acc = out.split("\n"), 0, "", Counter()
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("+++ "):
            path = ln[4:]
        m = _HUNK.match(ln)
        if m:
            n_old = int(m.group(1)) if m.group(1) is not None else 1
            n_new = int(m.group(2)) if m.group(2) is not None else 1
            for sign, count in (("-", n_old), ("+", n_new)):
                for _ in range(count):
                    i += 1
                    if i < len(lines):
                        acc[(path, sign, lines[i][1:])] += 1
        i += 1
    return acc


def repair_size(repo: str | None, prior_sha: str | None, next_sha: str | None,
                prior_base: str | None, next_base: str | None) -> tuple[int | None, str]:
    """(linhas, estado). estado: 'ancestral' | 'delta-de-patch' | 'nao-medido:<motivo>'."""
    if not repo:
        return None, "nao-medido:repo-sem-caminho"
    if not prior_sha or not next_sha:
        return None, "nao-medido:sha-ausente"
    if not (gv._commit_exists(repo, prior_sha) and gv._commit_exists(repo, next_sha)):
        return None, "nao-medido:commit-fora-do-clone"
    anc = _is_ancestor(repo, prior_sha, next_sha)
    if anc is None:
        return None, "nao-medido:git-falhou"
    if anc:
        n = _numstat_total(repo, prior_sha, next_sha)
        return (n, "ancestral") if n is not None else (None, "nao-medido:git-falhou")
    if not prior_base or not next_base:
        return None, "nao-medido:reescrito-sem-base_commit"
    if not (gv._commit_exists(repo, prior_base) and gv._commit_exists(repo, next_base)):
        return None, "nao-medido:base-fora-do-clone"
    a, b = _patch_lines(repo, prior_base, prior_sha), _patch_lines(repo, next_base, next_sha)
    if a is None or b is None:
        return None, "nao-medido:git-falhou"
    return sum(((a - b) + (b - a)).values()), "delta-de-patch"


# ── bd: SHAs (com cache) ─────────────────────────────────────────────────────────────────────
_REBASE = re.compile(r"auto-rebased\s+\S+\s+onto\s+main\s+\(([0-9a-f]{40})\)\.\s+New tip:\s+([0-9a-f]{40})")


def parse_rebases(comment_texts: list[str]) -> dict[str, str]:
    """new_tip -> sha de main sobre o qual o dispatcher rebaseou. O gate rebaseia o branch ANTES de
    revisar, então o `base_commit` do marker (base de quando o autor enviou) fica velho: um patch
    contra ele carrega toda a deriva do main entre as duas bases (milhares de linhas que o autor
    nunca escreveu). A base real de um tip rebaseado é o 'onto' deste comentário."""
    out: dict[str, str] = {}
    for t in comment_texts:
        for onto, tip in _REBASE.findall(t or ""):
            out[tip] = onto
    return out


def base_for(marker: dict | None, sha: str | None) -> tuple[str | None, str | None]:
    """(base, motivo_se_nao). base = onde o patch DESTE sha começa."""
    if marker is None:
        return None, "bd-nao-leu-marker"
    rb = marker.get("rebases") or {}
    if sha and sha in rb:
        return rb[sha], None
    if rb:  # houve rebase mas não registrado pra este tip: o base_commit pode estar velho
        return None, "rebase-sem-registro-do-tip"
    return marker.get("base_commit"), (None if marker.get("base_commit") else "marker-sem-base_commit")


class Shas:
    """bead_id -> {branch_sha, base_commit} (gate-run) e 'm:<id>' -> {base_commit, rebases} (marker)
    via `bd`. None = não consegui ler (≠ campo vazio); falha de leitura não é cacheada."""

    def __init__(self, gc_city: str, cache_path: str | None = None):
        self.city = gc_city
        self.path = cache_path
        self.mem: dict[str, dict | None] = {}
        if cache_path and Path(cache_path).exists():
            try:
                self.mem = json.loads(Path(cache_path).read_text())
            except (OSError, json.JSONDecodeError):
                self.mem = {}

    def get(self, bead_id: str) -> dict | None:
        if bead_id in self.mem:
            return self.mem[bead_id]
        b = gv._bd_show(self.city, bead_id)
        val = None if b is None else {
            "branch_sha": gv._field(b.get("description"), "branch_sha"),
            "base_commit": gv._field(b.get("description"), "base_commit"),
        }
        if val is not None:
            self.mem[bead_id] = val
        return val

    def marker(self, bead_id: str) -> dict | None:
        key = "m:" + bead_id
        if key in self.mem:
            return self.mem[key]
        b = gv._bd_show(self.city, bead_id)
        r = gv._run(["bd", "-C", self.city, "comments", bead_id, "--json"], timeout=30)
        if b is None or r is None or r.returncode != 0:
            return None
        try:
            cs = json.loads(r.stdout)
        except json.JSONDecodeError:
            return None
        if not isinstance(cs, list):
            return None
        val = {"base_commit": gv._field(b.get("description"), "base_commit"),
               "rebases": parse_rebases([c.get("text", "") for c in cs if isinstance(c, dict)])}
        self.mem[key] = val
        return val

    def save(self) -> None:
        if self.path:
            Path(self.path).write_text(json.dumps(self.mem))


# ── join: sombra x log do gate ───────────────────────────────────────────────────────────────
def first_submit_ts(events: list[dict]) -> dict[str, str]:
    """marker -> ts do primeiro evento de ENVIO ao gate (guard_queued/guard_dispatched)."""
    out: dict[str, str] = {}
    for ev in events:
        m, ts = ev.get("marker"), ev.get("ts")
        if ev.get("event") in SUBMIT_EVENTS and m and ts and (m not in out or ts < out[m]):
            out[m] = ts
    return out


def join_records(records: list[dict], reviews_by_bead: dict[str, list[dict]]) -> tuple[list[dict], Counter]:
    """Uma linha por entidade respondida pelo Jev cujo join com o gate-log fecha. O que não fecha
    é contado por motivo em `skipped` — nunca descartado em silêncio, nunca promovido a dado."""
    rows, skipped = [], Counter()
    for rec in records:
        if rec.get("jev_ok") is not True:
            skipped["jev-nao-respondeu"] += 1
            continue
        revs, k = reviews_by_bead.get(rec.get("bead"), []), rec.get("attempt")
        if not isinstance(k, int) or k < 2 or k > len(revs):
            skipped["join-sem-par-de-revisoes"] += 1
            continue
        prior, rv = revs[k - 2], revs[k - 1]
        if prior["result"] != "FAIL" or (rec.get("desfecho_gate_run") and rec["desfecho_gate_run"] != rv["gate_run"]):
            skipped["join-inconsistente"] += 1
            continue
        pk = fail_kind(prior.get("reason"))
        nk = "pass" if rv["result"] == "PASS" else fail_kind(rv.get("reason"))
        probs = rec.get("probabilidades") or {}
        rows.append({
            "entity_id": rec["entity_id"], "bead": rec["bead"], "rig": rv.get("rig"), "attempt": k,
            "categoria": rec.get("categoria_jev") or "incerta",
            "prob": rec.get("prob_categoria"),
            "p_ajuste": probs.get(LIGHT),
            "prior_kind": pk,
            # pass | review (reprovou de verdade) | mechanical | unknown — só pass/review julgam o conserto
            "next": nk,
            "prior": prior, "rv": rv,
            # medição: nasce "não medido" e só measure() promove — linha sem medir nunca vira 0
            "size": None, "size_state": "nao-medido:nao-tentado", "prior_size": None, "resubmit_h": None, "verdict_h": None,
        })
    return rows, skipped


def strict_leve(r: dict, thr: float = MIN_PROB) -> bool:
    return r["categoria"] == LIGHT and (r["prob"] or 0) >= thr


def atomic_leve(r: dict, thr: float = MIN_PROB) -> bool:
    return (r["p_ajuste"] or 0) >= thr


def measure(rows: list[dict], shas: Shas, rig_paths: dict[str, str], first_submit: dict[str, str],
            workers: int = 3) -> None:
    """Preenche, in place, size/size_state/resubmit_h/verdict_h. Só mede o que a conta usa: o
    FAIL anterior tem de ser revisão real (um timeout não tem "diff reprovado" a consertar)."""
    repo_cache: dict[str, str | None] = {}

    def repo_for(rig):
        if rig not in repo_cache:
            repo_cache[rig] = gv.resolve_rig_root(rig, rig_paths) if rig else None
        return repo_cache[rig]

    def one(r: dict) -> None:
        prior, rv = r["prior"], r["rv"]
        t0, t1 = gv._parse_ts(prior.get("ts")), gv._parse_ts(rv.get("ts"))
        r["verdict_h"] = (t1 - t0).total_seconds() / 3600 if t0 and t1 else None
        sub = gv._parse_ts(first_submit.get(rv.get("marker") or ""))
        same_marker = prior.get("marker") and prior.get("marker") == rv.get("marker")
        r["resubmit_h"] = ((sub - t0).total_seconds() / 3600
                           if sub and t0 and not same_marker and sub >= t0 else None)
        p_run, n_run = shas.get(prior["gate_run"]), shas.get(rv["gate_run"])
        if p_run is None or n_run is None:
            r["size"], r["size_state"] = None, "nao-medido:bd-nao-leu-gate_run"
            return
        pm = shas.marker(prior["marker"]) if prior.get("marker") else None
        nm = shas.marker(rv["marker"]) if rv.get("marker") else None
        pb, pwhy = base_for(pm, p_run["branch_sha"])
        nb, nwhy = base_for(nm, n_run["branch_sha"])
        repo = repo_for(r["rig"])
        r["size"], r["size_state"] = repair_size(repo, p_run["branch_sha"], n_run["branch_sha"], pb, nb)
        if r["size_state"] == "nao-medido:reescrito-sem-base_commit":
            r["size_state"] = f"nao-medido:{pwhy or nwhy or 'reescrito-sem-base'}"
        if repo and pb and p_run["branch_sha"] and gv._commit_exists(repo, pb) and gv._commit_exists(repo, p_run["branch_sha"]):
            r["prior_size"] = _patch_size(repo, pb, p_run["branch_sha"])

    targets = [r for r in rows if r["prior_kind"] == "review" and r["next"] in ("pass", "review")]
    with ThreadPoolExecutor(max_workers=max(1, workers)) as ex:
        list(ex.map(one, targets))
    shas.save()


# ── agregação ────────────────────────────────────────────────────────────────────────────────
def _med(xs: list[float]) -> float | None:
    return statistics.median(xs) if xs else None


def group_stats(rows: list[dict]) -> dict:
    """Só linhas com prior_kind=='review' entram. `judged` = a rodada seguinte julgou o conserto
    (pass ou reprovação de revisão real); mecânico/desconhecido ficam de fora e são contados."""
    inn = [r for r in rows if r["prior_kind"] == "review"]
    judged = [r for r in inn if r["next"] in ("pass", "review")]
    passed = [r for r in judged if r["next"] == "pass"]
    sized = [r for r in judged if r["size"] is not None]
    ratios = [r["size"] / r["prior_size"] for r in sized if r.get("prior_size")]
    return {
        "n_total": len(rows),
        "n_prior_mecanico": sum(1 for r in rows if r["prior_kind"] != "review"),
        "n": len(inn),
        "beads": len({r["bead"] for r in inn}),
        "n_next_mecanico": sum(1 for r in inn if r["next"] in ("mechanical", "unknown")),
        "judged": len(judged),
        "pass": len(passed),
        "sized": len(sized),
        "nao_medido": len(judged) - len(sized),
        # por limiar de linhas: quantos conserto < L, e quantos desses passaram
        "small": sum(1 for r in sized if r["size"] < SMALL_LINES),
        "small_pass": sum(1 for r in sized if r["next"] == "pass" and r["size"] < SMALL_LINES),
        "thr": {t: (sum(1 for r in sized if r["size"] < t),
                    sum(1 for r in sized if r["next"] == "pass" and r["size"] < t)) for t in SENSITIVITY_LINES},
        "med_size": _med([r["size"] for r in sized]),
        "med_ratio": _med(ratios),
        "n_ratio": len(ratios),
        "med_resubmit_h": _med([r["resubmit_h"] for r in judged if r["resubmit_h"] is not None]),
        "med_verdict_h": _med([r["verdict_h"] for r in judged if r["verdict_h"] is not None]),
        "n_resubmit": sum(1 for r in judged if r["resubmit_h"] is not None),
    }


def compare(g: dict, b: dict) -> dict:
    """Grupo vs base, nas duas métricas. 'separa' segue a régua do enunciado (>= 20 pp e n >= 30)
    sobre a métrica do enunciado (passou E conserto < 50 linhas, entre os de tamanho medido)."""
    out = {}
    for name, k, n in (("passou", "pass", "judged"), ("passou_e_pequeno", "small_pass", "sized")):
        ci = newcombe_diff(g[k], g[n], b[k], b[n])
        out[name] = {
            "g": (g[k], g[n]), "b": (b[k], b[n]),
            "g_pct": 100 * g[k] / g[n] if g[n] else None,
            "b_pct": 100 * b[k] / b[n] if b[n] else None,
            "delta_pp": (100 * g[k] / g[n] - 100 * b[k] / b[n]) if g[n] and b[n] else None,
            "ic95_pp": ci,
        }
    m = out["passou_e_pequeno"]
    enough = g["sized"] >= MIN_N and b["sized"] >= MIN_N
    out["separa"] = bool(enough and m["delta_pp"] is not None and m["delta_pp"] >= MIN_DELTA_PP)
    out["n_suficiente"] = enough
    out["ic_exclui_zero"] = bool(m["ic95_pp"] and m["ic95_pp"][0] > 0)
    return out


def pending_fails(reviews_by_bead: dict[str, list[dict]], since_ts: str | None, now: datetime | None = None) -> dict:
    """FAILs do log do gate (revisão real) SEM revisão seguinte: 'ainda sem desfecho'. Não têm
    categoria do Jev (a sombra só grava depois da revisão do conserto)."""
    now = now or datetime.now(timezone.utc)
    tot = fresh = old = 0
    for revs in reviews_by_bead.values():
        for i, r in enumerate(revs):
            if r["result"] != "FAIL" or fail_kind(r.get("reason")) != "review":
                continue
            if since_ts and (r.get("ts") or "") < since_ts:
                continue
            tot += 1
            if i + 1 < len(revs):
                continue
            t = gv._parse_ts(r.get("ts"))
            if t and now - t < timedelta(hours=PENDING_FRESH_HOURS):
                fresh += 1
            else:
                old += 1
    return {"fails_revisao": tot, "com_desfecho": tot - fresh - old, "sem_desfecho_recente": fresh, "sem_desfecho_antigo": old}


def summarize(records: list[dict], reviews_by_bead: dict, first_submit: dict, shas: Shas,
              rig_paths: dict[str, str], workers: int = 3, limit: int | None = None) -> dict:
    rows, skipped = join_records(records, reviews_by_bead)
    if limit:
        rows = rows[:limit]
    measure(rows, shas, rig_paths, first_submit, workers)
    groups = {
        "ajuste_pequeno_p07_estrito": [r for r in rows if strict_leve(r)],
        "ajuste_pequeno_qualquer_prob": [r for r in rows if r["categoria"] == LIGHT],
        "ajuste_pequeno_atomico_p07": [r for r in rows if atomic_leve(r)],
        BASE: [r for r in rows if r["categoria"] == BASE],
        "falta_teste": [r for r in rows if r["categoria"] == "falta_teste"],
        "escopo_errado": [r for r in rows if r["categoria"] == "escopo_errado"],
        "precisa_rebase": [r for r in rows if r["categoria"] == "precisa_rebase"],
        "incerta": [r for r in rows if r["categoria"] == "incerta"],
        "TODAS": rows,
    }
    stats = {k: group_stats(v) for k, v in groups.items()}
    base = stats[BASE]
    stamps = sorted(t for t in (r["prior"].get("ts") for r in rows) if t)
    states = Counter(r["size_state"] for r in rows if r["prior_kind"] == "review" and r["next"] in ("pass", "review"))
    return {
        "records": len(records), "joined": len(rows), "skipped": dict(skipped),
        "window": [stamps[0], stamps[-1]] if stamps else None,
        "stats": stats,
        "vs_base": {k: compare(stats[k], base) for k in
                    ("ajuste_pequeno_p07_estrito", "ajuste_pequeno_qualquer_prob", "ajuste_pequeno_atomico_p07")},
        "size_states": dict(states),
        "pendentes": pending_fails(reviews_by_bead, stamps[0] if stamps else None),
    }


# ── relatório ────────────────────────────────────────────────────────────────────────────────
def _p(k: int, n: int) -> str:
    return "n/a" if not n else f"{100 * k / n:.0f}% ({k}/{n})"


def _f(x, fmt="{:.1f}") -> str:
    return "n/a" if x is None else fmt.format(x)


def format_report(s: dict) -> str:
    L = ["JEV gate-fail-categoria x DESFECHO REAL (sem rótulo humano) — read-only, nada muda no gate", ""]
    if not s["joined"]:
        return "\n".join(L + ["Nenhuma entidade com join fechado — nada a medir."])
    st = s["stats"]
    L += [
        f"{s['records']} entidades na sombra; {s['joined']} com join fechado no log do gate"
        + (f"; fora do join: {s['skipped']}" if s["skipped"] else ""),
        f"janela dos FAILs classificados: {s['window'][0]} .. {s['window'][1]}",
        "Cada entidade = um FAIL de revisão + a rodada seguinte (o conserto). Só entram FAILs de REVISÃO "
        "real; timeout/merge quebrado não têm diff reprovado a consertar (contados à parte).",
        "",
        f"{'grupo':<30}{'n':>5}{'beads':>6}  {'rodada seguinte passou':<24}{'<50 linhas e passou':<22}"
        f"{'mediana linhas':>15}{'reenvio (h)':>12}{'veredito (h)':>13}",
    ]
    for name, g in st.items():
        if not g["n"]:
            continue
        L.append(
            f"{name:<30}{g['n']:>5}{g['beads']:>6}  {_p(g['pass'], g['judged']):<24}"
            f"{_p(g['small_pass'], g['sized']):<22}{_f(g['med_size'], '{:.0f}'):>15}"
            f"{_f(g['med_resubmit_h']):>12}{_f(g['med_verdict_h']):>13}"
        )
    L += ["", "FORA DO DENOMINADOR (contado, nunca somado a 'falhou'):"]
    a = st["TODAS"]
    L.append(f"  FAIL anterior mecânico (timeout/merge/sem juízo): {a['n_prior_mecanico']} entidades")
    L.append(f"  rodada seguinte SEM juízo sobre o conserto (timeout/merge/sem veredito): {a['n_next_mecanico']}")
    L.append(f"  tamanho do conserto nao-medido: {a['nao_medido']} de {a['judged']} julgadas — motivos: "
             + ", ".join(f"{k}={v}" for k, v in sorted(s["size_states"].items(), key=lambda kv: -kv[1])))
    pe = s["pendentes"]
    L.append(f"  FAILs de revisão na janela SEM nova rodada = 'ainda sem desfecho': "
             f"{pe['sem_desfecho_recente'] + pe['sem_desfecho_antigo']} de {pe['fails_revisao']} "
             f"({pe['sem_desfecho_recente']} há < {PENDING_FRESH_HOURS:.0f}h, {pe['sem_desfecho_antigo']} mais antigos). "
             "Sem categoria do Jev; não são 'conserto que falhou'.")
    L += ["", "GRUPO vs BASE (bug_logica) — métrica do enunciado: passou na rodada seguinte E conserto < "
          f"{SMALL_LINES} linhas (entre os de tamanho medido); régua: >= {MIN_DELTA_PP:.0f} pp e n >= {MIN_N}:"]
    for name, c in s["vs_base"].items():
        m, p = c["passou_e_pequeno"], c["passou"]
        ci = m["ic95_pp"]
        L.append(
            f"  {name}: {_f(m['g_pct'], '{:.0f}')}% vs {_f(m['b_pct'], '{:.0f}')}%  Δ={_f(m['delta_pp'], '{:+.0f}')} pp "
            f"(IC95 {_f(ci[0], '{:+.0f}') if ci else 'n/a'}..{_f(ci[1], '{:+.0f}') if ci else 'n/a'}), "
            f"n_medido={st[name]['sized']} vs {st['bug_logica']['sized']}  |  só 'passou': "
            f"{_f(p['g_pct'], '{:.0f}')}% vs {_f(p['b_pct'], '{:.0f}')}% Δ={_f(p['delta_pp'], '{:+.0f}')} pp"
            f"  =>  {'SEPARA' if c['separa'] else 'NAO SEPARA'}"
            + ("" if c["n_suficiente"] else f"  [n_medido < {MIN_N}]")
            + ("" if c["separa"] or not c["ic_exclui_zero"] else "  [IC exclui 0, mas Δ < régua]")
        )
    L += ["", "SENSIBILIDADE ao limiar de linhas (passou E conserto < L, entre os de tamanho medido):"]
    for name, g in st.items():
        if g["n"]:
            L.append(f"  {name:<30}" + "  ".join(f"<{t}: {_p(g['thr'][t][1], g['sized'])}" for t in SENSITIVITY_LINES)
                     + f"   mediana conserto/FAIL reprovado: {_f(g['med_ratio'], '{:.2f}')}x (n={g['n_ratio']})")
    L += ["", "LIMITES: (1) só conserta quem reenviou — a sombra não vê o FAIL abandonado; (2) uma mesma bead "
          "gera várias entidades (n > beads: não são independentes); (3) 'categoria' é a leitura crua do "
          "Jev, sem calibração contra rótulo humano — aqui ela é testada pelo desfecho, não pela concordância."]
    return "\n".join(L)


# ── execução ─────────────────────────────────────────────────────────────────────────────────
def build_summary(log=None, gate_log=None, gc_city=None, cache=None, workers=3, limit=None) -> dict:
    gc_city = gc_city or gv.DEFAULT_GC_CITY
    gate_log = gate_log or f"{gc_city}/.gc/quality-gate.jsonl"
    records = cr.load_records(log or je.JEV_LOG)
    reviews = qp.load_reviews(gate_log)
    events = qp._read_jsonl(gate_log)
    return summarize(records, reviews, first_submit_ts(events), Shas(gc_city, cache), gv._rig_paths(), workers, limit)


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        return _selftest()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--log")
    ap.add_argument("--gate-log")
    ap.add_argument("--gc-city")
    ap.add_argument("--cache", help="arquivo JSON onde guardar os SHAs lidos (default: só em memória)")
    ap.add_argument("--workers", type=int, default=3, help="`bd show`s em paralelo — o Dolt é frágil; default 3")
    ap.add_argument("--limit", type=int, help="só as N primeiras entidades (teste rápido)")
    a = ap.parse_args()
    s = build_summary(a.log, a.gate_log, a.gc_city, a.cache, a.workers, a.limit)
    print(json.dumps(s, ensure_ascii=False, indent=2, default=str) if a.json else format_report(s))
    return 0


def _selftest() -> int:
    import subprocess

    passed = failed = 0

    def ok(label: str, cond: bool) -> None:
        nonlocal passed, failed
        passed, failed = (passed + 1, failed) if cond else (passed, failed + 1)
        print(f"  {'ok  ' if cond else 'FAIL'} {label}")

    # fail_kind: espelha classify_fail_reason
    ok("FAIL de revisão", fail_kind("Reviewer 1 FAIL: VERDICT: FAIL") == "review")
    ok("TIMEOUT é mecânico", fail_kind("TIMEOUT: reviewers did not submit verdicts within 45 minutes.") == "mechanical")
    ok("merge quebrado é mecânico", fail_kind("Merge failed after all-PASS verdict.") == "mechanical")
    ok("reason ausente é unknown (3º estado), não 'review'", fail_kind(None) == "unknown" and fail_kind("") == "unknown")

    # estatística
    ok("wilson n=0 -> None", wilson(0, 0) is None)
    lo, hi = wilson(5, 10)
    ok("wilson 5/10 contém 0.5", lo < 0.5 < hi)
    d = newcombe_diff(30, 40, 10, 40)
    ok("newcombe: 75% vs 25% exclui 0", d is not None and d[0] > 0)

    # git real, repositório temporário
    with tempfile.TemporaryDirectory() as td:
        def git(*args):
            return subprocess.run(["git", "-C", td, *args], check=True, capture_output=True, text=True,
                                  env={"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                                       "GIT_COMMITTER_EMAIL": "t@t", "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"}).stdout.strip()
        git("init", "-q", "-b", "main")
        (Path(td) / "a.txt").write_text("\n".join(f"l{i}" for i in range(100)) + "\n")
        git("add", "."); git("commit", "-qm", "base")
        base = git("rev-parse", "HEAD")
        git("checkout", "-qb", "feat")
        (Path(td) / "b.txt").write_text("x\n" * 10)
        git("add", "."); git("commit", "-qm", "feat v1")
        v1 = git("rev-parse", "HEAD")
        (Path(td) / "b.txt").write_text("x\n" * 10 + "fix1\nfix2\nfix3\n")
        git("add", "."); git("commit", "-qm", "repair")
        v2 = git("rev-parse", "HEAD")
        n, state = repair_size(td, v1, v2, base, base)
        ok(f"conserto linear: 3 linhas, método ancestral (got {n},{state})", n == 3 and state == "ancestral")

        # main avança 40 linhas; o autor reescreve (rebase) e conserta 3 linhas
        git("checkout", "-q", "main")
        (Path(td) / "a.txt").write_text("\n".join(f"m{i}" for i in range(140)) + "\n")
        git("add", "."); git("commit", "-qm", "main moves")
        base2 = git("rev-parse", "HEAD")
        git("checkout", "-qb", "feat2", "main")
        (Path(td) / "b.txt").write_text("x\n" * 10 + "fix1\nfix2\nfix3\n")
        git("add", "."); git("commit", "-qm", "feat rebased + repair")
        v2r = git("rev-parse", "HEAD")
        raw = _numstat_total(td, v1, v2r)
        n2, state2 = repair_size(td, v1, v2r, base, base2)
        ok(f"reescrito: diff CRU inflaria ({raw} linhas) mas o delta de patch mede só o conserto (got {n2},{state2})",
           raw is not None and raw > 40 and n2 == 3 and state2 == "delta-de-patch")
        ok("reescrito SEM base_commit é nao-medido, não 0 nem o diff cru",
           repair_size(td, v1, v2r, None, base2) == (None, "nao-medido:reescrito-sem-base_commit"))
        ok("commit que não existe é nao-medido", repair_size(td, v1, "0" * 40, base, base)[0] is None)
        ok("sha ausente é nao-medido", repair_size(td, None, v2, base, base) == (None, "nao-medido:sha-ausente"))
        ok("repo sem caminho é nao-medido", repair_size(None, v1, v2, base, base) == (None, "nao-medido:repo-sem-caminho"))
        # o gate rebaseia ANTES de revisar: o base_commit do marker fica velho. Base velha = deriva do main
        # dentro do "conserto"; a base certa vem do comentário do dispatcher.
        txt = f"Gate dispatcher auto-rebased crew/x/y onto main ({base2}). New tip: {v2r}. Proceeding with review."
        mk_m = {"base_commit": base, "rebases": parse_rebases(["lixo", txt])}
        ok("parse_rebases lê 'onto main (X). New tip: Y' (tip -> onto)", mk_m["rebases"] == {v2r: base2})
        nb_ok, why = base_for(mk_m, v2r)
        ok("base_for usa o 'onto' do rebase, não o base_commit velho", nb_ok == base2 and why is None)
        stale = repair_size(td, v1, v2r, base, base)[0]
        fresh = repair_size(td, v1, v2r, base, nb_ok)[0]
        ok(f"base velha infla o conserto ({stale}); base do rebase mede 3 (got {fresh})",
           stale is not None and stale > 40 and fresh == 3)
        # linha adicionada que começa com '++ ' não pode ser lida como cabeçalho de arquivo
        git("checkout", "-q", "feat")
        (Path(td) / "c.txt").write_text("++ not a header\n")
        git("add", "."); git("commit", "-qm", "tricky")
        pl = _patch_lines(td, base, git("rev-parse", "HEAD"))
        ok("linha '++ ...' conta como linha adicionada, sem trocar o arquivo",
           pl is not None and pl[("b/c.txt", "+", "++ not a header")] == 1)

    # base_for: três estados (sei / não sei / não pude saber)
    ok("sem rebase registrado: usa base_commit", base_for({"base_commit": "b" * 40, "rebases": {}}, "t" * 40) == ("b" * 40, None))
    ok("rebase registrado mas não pra este tip: nao-medido (base_commit pode estar velho)",
       base_for({"base_commit": "b" * 40, "rebases": {"x" * 40: "y" * 40}}, "t" * 40) == (None, "rebase-sem-registro-do-tip"))
    ok("marker não lido é motivo próprio, não 'sem base'", base_for(None, "t" * 40) == (None, "bd-nao-leu-marker"))
    ok("marker sem base_commit nem rebase é nao-medido", base_for({"base_commit": None, "rebases": {}}, "t" * 40) == (None, "marker-sem-base_commit"))

    # join + três estados
    def rv(run, res, reason, ts, marker="m"):
        return {"gate_run": run, "result": res, "reason": reason, "ts": ts, "marker": marker, "rig": "r"}
    real = "Reviewer 1 FAIL: VERDICT: FAIL"
    revs = {
        "b1": [rv("g1", "FAIL", real, "2026-10-01T00:00:00Z", "m1"), rv("g2", "PASS", "quorum_1_of_1", "2026-10-01T02:00:00Z", "m2")],
        "b2": [rv("g3", "FAIL", real, "2026-10-01T00:00:00Z", "m3"), rv("g4", "FAIL", "TIMEOUT: x", "2026-10-01T01:00:00Z", "m4")],
        "b3": [rv("g5", "FAIL", real, "2026-10-01T00:00:00Z", "m5")],  # nunca reenviado
        "b4": [rv("g6", "FAIL", "TIMEOUT: x", "2026-10-01T00:00:00Z", "m6"), rv("g7", "PASS", "q", "2026-10-01T01:00:00Z", "m7")],
    }
    recs = [
        {"entity_id": "b1#2", "bead": "b1", "attempt": 2, "jev_ok": True, "categoria_jev": LIGHT, "prob_categoria": 0.9,
         "probabilidades": {LIGHT: 0.9}, "desfecho_gate_run": "g2"},
        {"entity_id": "b2#2", "bead": "b2", "attempt": 2, "jev_ok": True, "categoria_jev": BASE, "prob_categoria": 0.9,
         "probabilidades": {LIGHT: 0.2}, "desfecho_gate_run": "g4"},
        {"entity_id": "b4#2", "bead": "b4", "attempt": 2, "jev_ok": True, "categoria_jev": LIGHT, "prob_categoria": 0.8,
         "probabilidades": {LIGHT: 0.8}, "desfecho_gate_run": "g7"},
        {"entity_id": "b1#9", "bead": "b1", "attempt": 9, "jev_ok": True, "categoria_jev": LIGHT, "prob_categoria": 0.9},
        {"entity_id": "bx#2", "bead": "b1", "attempt": 2, "jev_ok": True, "categoria_jev": LIGHT, "prob_categoria": 0.9,
         "desfecho_gate_run": "OUTRA"},
        {"entity_id": "b5#2", "bead": "b5", "attempt": 2, "jev_ok": False},
    ]
    rows, skipped = join_records(recs, revs)
    ok("join: 3 entidades fecham", len(rows) == 3)
    ok("join: attempt fora do range, gate_run divergente e jev_ok=False são contados, não descartados",
       skipped == Counter({"join-sem-par-de-revisoes": 1, "join-inconsistente": 1, "jev-nao-respondeu": 1}))
    by = {r["entity_id"]: r for r in rows}
    ok("b1#2: próxima passou", by["b1#2"]["next"] == "pass")
    ok("b2#2: TIMEOUT na rodada seguinte NÃO é 'conserto falhou'", by["b2#2"]["next"] == "mechanical")
    ok("b4#2: FAIL anterior mecânico fica marcado", by["b4#2"]["prior_kind"] == "mechanical")
    g = group_stats(rows)
    ok("denominador de 'passou' exclui mecânico (judged=1 de n=2 FAIL-anterior-review)", g["n"] == 2 and g["judged"] == 1 and g["pass"] == 1)
    ok("mecânico da seguinte é contado à parte", g["n_next_mecanico"] == 1 and g["n_prior_mecanico"] == 1)
    pend = pending_fails(revs, None, now=datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc))
    ok("b3 (FAIL de revisão sem nova rodada, 12h) = sem desfecho RECENTE; TIMEOUT de b4 não conta como FAIL de revisão",
       pend == {"fails_revisao": 3, "com_desfecho": 2, "sem_desfecho_recente": 1, "sem_desfecho_antigo": 0})
    fs = first_submit_ts([{"event": "guard_queued", "marker": "m2", "ts": "2026-10-01T01:30:00Z"},
                          {"event": "guard_queued", "marker": "m2", "ts": "2026-10-01T01:10:00Z"},
                          {"event": "dispatcher_complete", "marker": "m2", "ts": "2026-10-01T00:01:00Z"}])
    ok("primeiro envio = menor ts de guard_*, ignora dispatcher_complete", fs == {"m2": "2026-10-01T01:10:00Z"})

    # régua do enunciado
    mk = lambda n, sp, sz: {"judged": n, "pass": sp, "sized": sz, "small_pass": sp}
    ok("separa: +30pp e n>=30", compare(mk(40, 36, 40), mk(40, 24, 40))["separa"] is True)
    ok("não separa: +30pp mas n<30", compare(mk(10, 9, 10), mk(40, 12, 40))["separa"] is False)
    ok("não separa: n ok mas +10pp", compare(mk(40, 24, 40), mk(40, 20, 40))["separa"] is False)

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
