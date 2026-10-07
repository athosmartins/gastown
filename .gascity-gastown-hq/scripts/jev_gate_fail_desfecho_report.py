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

SAÍDA: 0 = relatório impresso (inclusive "0 entidades", dito com os arquivos lidos). 2 = entrada ausente
ou ilegível (log do Jev/do gate inexistente, sem linha JSON legível, ou log do gate sem nenhuma revisão
enquanto há entidades): mensagem em stderr, stdout vazio. Não consegui ler != nada a medir.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import subprocess
import sys
from collections import Counter
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


class InputError(Exception):
    """Entrada ausente ou ilegível. É o TERCEIRO estado ("não consegui saber"): vira erro
    explícito com saída != 0, nunca "nada a medir" — este relatório decide se a sombra se desliga,
    e um log movido/errado de caminho tem de ser distinguível de uma sombra realmente vazia."""


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
                seen = 0
                while seen < count and i + 1 < len(lines):
                    i += 1
                    if lines[i].startswith("\\"):
                        # "\ No newline at end of file" fica ENTRE o último '-' e o primeiro '+' quando se
                        # edita a última linha de um arquivo sem '\n' final: não é linha do patch. Contá-la
                        # como '+' derrubava o '+' de verdade e dois consertos distintos mediam 0.
                        continue
                    acc[(path, sign, lines[i][1:])] += 1
                    seen += 1
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
            try:
                Path(self.path).write_text(json.dumps(self.mem))
            except OSError as e:  # o cache é conveniência: não derruba um relatório já medido
                print(f"AVISO: não gravei o --cache {self.path}: {e}", file=sys.stderr)


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


def sem_prob(r: dict) -> bool:
    """Resposta do Jev sem a probabilidade que os cortes >= 0.7 leem. Probabilidade que não se leu
    não é probabilidade baixa: a linha fica FORA dos grupos de corte (inerte) e é contada em
    `n_sem_prob`, que o relatório mostra — nunca some em silêncio."""
    return r["prob"] is None or r["p_ajuste"] is None


def strict_leve(r: dict, thr: float = MIN_PROB) -> bool:
    return r["categoria"] == LIGHT and r["prob"] is not None and r["prob"] >= thr


def atomic_leve(r: dict, thr: float = MIN_PROB) -> bool:
    return r["p_ajuste"] is not None and r["p_ajuste"] >= thr


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
    # três estados: n insuficiente NÃO é "não separa" — é "não deu pra saber". A regra de decisão
    # ("senão, desligar a sombra") não pode ler amostra pequena como evidência contra a sombra.
    out["veredito"] = "separa" if out["separa"] else ("nao_separa" if enough else "inconclusivo")
    return out


def pending_fails(reviews_by_bead: dict[str, list[dict]], since_ts: str | None, now: datetime | None = None) -> dict:
    """FAILs do log do gate (revisão real) SEM revisão seguinte: 'ainda sem desfecho'. Não têm
    categoria do Jev (a sombra só grava depois da revisão do conserto).

    Três estados também aqui: FAIL sem `ts` legível não cabe na janela nem no "recente/antigo" —
    vai pra `ts_desconhecido`, não vira "antigo"; FAIL sem `reason` não se sabe se é revisão ou
    mecânico — vai pra `sem_motivo`, não some dos contadores (o join os conta em n_prior_mecanico)."""
    now = now or datetime.now(timezone.utc)
    tot = fresh = old = ts_unknown = no_reason = 0
    for revs in reviews_by_bead.values():
        for i, r in enumerate(revs):
            if r["result"] != "FAIL":
                continue
            kind = fail_kind(r.get("reason"))
            if kind == "unknown":
                no_reason += 1
                continue
            if kind != "review":
                continue
            t = gv._parse_ts(r.get("ts"))
            if t is None:
                ts_unknown += 1
                continue
            if since_ts and r["ts"] < since_ts:
                continue
            tot += 1
            if i + 1 < len(revs):
                continue
            if now - t < timedelta(hours=PENDING_FRESH_HOURS):
                fresh += 1
            else:
                old += 1
    return {"fails_revisao": tot, "com_desfecho": tot - fresh - old, "sem_desfecho_recente": fresh,
            "sem_desfecho_antigo": old, "ts_desconhecido": ts_unknown, "sem_motivo": no_reason}


def summarize(records: list[dict], reviews_by_bead: dict, first_submit: dict, shas: Shas,
              rig_paths: dict[str, str], workers: int = 3, limit: int | None = None) -> dict:
    rows, skipped = join_records(records, reviews_by_bead)
    joined_total = len(rows)
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
    vs_base = {k: compare(stats[k], base) for k in
               ("ajuste_pequeno_p07_estrito", "ajuste_pequeno_qualquer_prob", "ajuste_pequeno_atomico_p07")}
    for k, c in vs_base.items():
        # linhas que estão no grupo E na base (o grupo atômico ignora o argmax, então pega bug_logica):
        # o IC de Newcombe assume grupos independentes, e com sobreposição ele só aproxima.
        c["n_sobrepoe_base"] = sum(1 for r in groups[k] if r["categoria"] == BASE)
    return {
        "records": len(records), "joined": joined_total, "joined_medidas": len(rows),
        "limit": limit if limit and joined_total > len(rows) else None,
        "skipped": dict(skipped),
        "window": [stamps[0], stamps[-1]] if stamps else None,
        "stats": stats,
        "vs_base": vs_base,
        "size_states": dict(states),
        "n_sem_prob": sum(1 for r in rows if sem_prob(r)),
        "pendentes": pending_fails(reviews_by_bead, stamps[0] if stamps else None),
    }


# ── relatório ────────────────────────────────────────────────────────────────────────────────
def _p(k: int, n: int) -> str:
    return "n/a" if not n else f"{100 * k / n:.0f}% ({k}/{n})"


def _f(x, fmt="{:.1f}") -> str:
    return "n/a" if x is None else fmt.format(x)


def format_report(s: dict) -> str:
    L = ["JEV gate-fail-categoria x DESFECHO REAL (sem rótulo humano) — read-only, nada muda no gate", ""]
    inp = s.get("inputs") or {}
    src = ([f"entradas lidas — log do Jev: {inp['jev_log']} ({inp['jev_linhas']} linhas JSON); "
            f"log do gate: {inp['gate_log']} ({inp['gate_revisoes']} revisões)"] if inp else [])
    if not s["joined"]:
        if s["records"]:
            # há entidades e nenhuma fechou o join: isso NÃO é "nada a medir" — é o motivo que tem de aparecer.
            return "\n".join(L + [
                f"{s['records']} entidades na sombra; 0 com join fechado no log do gate"
                + (f"; fora do join: {s['skipped']}" if s["skipped"] else ""), *src,
                "NADA FOI MEDIDO: nenhuma entidade fechou o join. Isto não é uma sombra sem dados — "
                "confira os motivos acima (e o --gate-log) antes de qualquer decisão."])
        return "\n".join(L + ["0 entidades do modo gate-fail-categoria no log do Jev — nada a medir.", *src])
    st = s["stats"]
    trunc = (f" [TRUNCADO por --limit {s['limit']}: só as {s['joined_medidas']} primeiras foram medidas; "
             "'fora do join' e 'sem desfecho' abaixo usam a população inteira]") if s.get("limit") else ""
    L += [
        f"{s['records']} entidades na sombra; {s['joined']} com join fechado no log do gate"
        + (f"; fora do join: {s['skipped']}" if s["skipped"] else "") + trunc,
        *src,
        ("janela dos FAILs classificados: " + (f"{s['window'][0]} .. {s['window'][1]}" if s["window"]
                                               else "desconhecida (nenhum FAIL com ts legível)")),
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
    if s["n_sem_prob"]:
        L.append(f"  respondidas SEM probabilidade legível (prob_categoria / probabilidades.{LIGHT}): {s['n_sem_prob']} — "
                 f"ficam fora dos grupos de corte >= {MIN_PROB} (estrito/atômico), não contam como prob baixa")
    if pe["ts_desconhecido"] or pe["sem_motivo"]:
        L.append(f"  fora dessa conta por não dar pra saber: {pe['ts_desconhecido']} FAILs de revisão sem ts legível, "
                 f"{pe['sem_motivo']} FAILs sem motivo registrado (não se sabe se foi revisão ou mecânico)")
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
            f"  =>  {c['veredito'].replace('_', ' ').upper()}"
            + ("" if c["n_suficiente"] else f"  [n_medido < {MIN_N}: amostra pequena, não é evidência contra]")
            + ("" if c["separa"] or not c["ic_exclui_zero"] else "  [IC exclui 0, mas Δ < régua]")
            + (f"  [{c['n_sobrepoe_base']} linhas também estão na base: o IC assume grupos independentes, "
               "leia como aproximado]" if c.get("n_sobrepoe_base") else "")
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
    """Lê as duas entradas e resume. Os leitores compartilhados (qp._read_jsonl, gv.iter_dispatcher_complete)
    devolvem VAZIO quando o arquivo não existe e pulam linha malformada em silêncio — boa regra pra
    um coletor, errada pra um relatório de go/no-go. Aqui "não consegui ler" levanta InputError."""
    gc_city = gc_city or gv.DEFAULT_GC_CITY
    gate_log = gate_log or f"{gc_city}/.gc/quality-gate.jsonl"
    log = log or je.JEV_LOG
    for label, p in (("log do Jev", log), ("log do gate", gate_log)):
        if not Path(p).is_file():
            raise InputError(f"{label} não encontrado (ou não é arquivo): {p}")
    jev_events = qp._read_jsonl(log)
    if Path(log).stat().st_size > 0 and not jev_events:
        raise InputError(f"log do Jev tem conteúdo mas nenhuma linha JSON legível: {log}")
    records = cr.dedupe_records(jev_events)
    reviews = qp.load_reviews(gate_log)
    n_reviews = sum(len(v) for v in reviews.values())
    if records and not n_reviews:
        raise InputError(f"{len(records)} entidades no log do Jev, mas o log do gate não tem nenhuma revisão "
                         f"(dispatcher_complete PASS/FAIL) legível: {gate_log} — caminho errado, rotacionado ou corrompido?")
    rig_paths = gv._rig_paths() if records else {}
    if records and not rig_paths:
        print("AVISO: `gc rig list` não devolveu rigs — o tamanho do conserto sai todo nao-medido "
              "(repo-sem-caminho); só as colunas de 'passou' valem.", file=sys.stderr)
    s = summarize(records, reviews, first_submit_ts(qp._read_jsonl(gate_log)), Shas(gc_city, cache),
                  rig_paths, workers, limit)
    s["inputs"] = {"jev_log": str(log), "jev_linhas": len(jev_events), "gate_log": str(gate_log),
                   "gate_revisoes": n_reviews}
    return s


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        # o selftest mora em arquivo próprio (*.selftest.py, como jev_recomecar_experiment): o teto E11 do gate
        # não conta teste como código de produção, e um selftest embutido de ~275 linhas estourava o teto sozinho.
        return subprocess.call([sys.executable, str(Path(__file__).with_suffix(".selftest.py"))])
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--log")
    ap.add_argument("--gate-log")
    ap.add_argument("--gc-city")
    ap.add_argument("--cache", help="arquivo JSON onde guardar os SHAs lidos (default: só em memória)")
    ap.add_argument("--workers", type=int, default=3, help="`bd show`s em paralelo — o Dolt é frágil; default 3")
    ap.add_argument("--limit", type=int, help="só as N primeiras entidades (teste rápido)")
    a = ap.parse_args()
    try:
        s = build_summary(a.log, a.gate_log, a.gc_city, a.cache, a.workers, a.limit)
    except (InputError, OSError) as e:
        # stdout fica VAZIO de propósito: quem faz pipe/parse não pode confundir erro com relatório.
        print(f"ERRO: {e}", file=sys.stderr)
        return 2
    print(json.dumps(s, ensure_ascii=False, indent=2, default=str) if a.json else format_report(s))
    return 0


if __name__ == "__main__":
    sys.exit(main())
