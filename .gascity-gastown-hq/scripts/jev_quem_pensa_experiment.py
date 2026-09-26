#!/usr/bin/env python3
"""jev_quem_pensa_experiment.py (ga-aijm2v.9) — SHADOW MODE, phase 1: which model would Jev
pick for a task a pool worker got, and for a repair after a gate rejection?

WHY (ga-aijm2v epic): 60% of gate reviews FAIL and every FAIL costs a fresh worker session
plus a fresh reviewer session, so the number that matters is the total cost until the gate
approves, not the price per token. Before anyone spends Opus quota blind (or gives a
"trivial" task to Haiku and pays for the retry), measure whether Jev's read of the task
predicts what really happens at the gate. NOTHING here changes which model any session
uses: pools keep running Sonnet; this only records what Jev WOULD have chosen and what the
gate then said.

TWO EXPERIMENTS, one record each, same log as every other Jev front (jev-experiment.jsonl,
mode "quem-pensa"):
  quem-pensa-nova     entity = the bead. Question (Jev `choice`): how hard is this task —
                      facil / media / dificil. Rule: facil AND confident -> haiku, else
                      sonnet. Opus is NEVER an option for a new task (the Athos, 25/09:
                      Opus quota only on repairs of work that already failed).
                      Outcome = verdict of the FIRST gate review of the bead.
  quem-pensa-conserto entity = "<bead>#<k>", one per repair attempt k>=2 (a FAIL review was
                      followed by another review). Question: does fixing this rejection need
                      reasoning (raciocinio) or is it mechanical (mecanico)? Rule:
                      raciocinio AND confident -> opus, else sonnet.
                      Outcome = verdict of the review that judged the repair.
"Confident" means BOTH the calibrated probability of the chosen option AND Jev's own
`confidence` field reach the threshold (0.85, same bar as every other front) — when the two
disagree the safer model (sonnet) wins. Both raw numbers are logged.

THIRD STATE, everywhere: Jev down / error / unparseable -> escolha_jev "nao_sei" and the
model stays sonnet. A failed call is logged (so the outage is visible) but is retried on
later runs, up to MAX_JEV_FAILS times per entity, and the run stops after
CIRCUIT_BREAK_FAILS consecutive failures — a Jev outage must not turn a whole backlog of
tasks into permanent "nao_sei" rows.

DESIGN — offline join, same reasoning as jev_gate_verdict_experiment.py (F5): the real
outcome is only known minutes-to-days after the decision point, so this runs separately and
reads what already happened: quality-gate.jsonl (every review, in order) for the outcome, the
bead for the task text, the gate-run bead's FAIL comment for the reviewer's reason. Jev is
never shown anything that names the outcome: the task state is title + description +
acceptance criteria only (no notes, comments or labels, where "Gate FAILED"/needs-fix
accumulate); the repair state is the reviewer's reason of the PREVIOUS review, the diff stat
and the attempt number. Known limit: the bead text is read when this runs, not at dispatch
time, so a description edited after dispatch would be read in its edited form.

WHICH TASKS COUNT: only work a POOL worker did. Model choice is a dispatch decision for
pools; named crews and the Mayor pick their own model. A review counts as pool work when its
branch is crew/wa-worker/* or crew/ps-worker/*, or the gate-run bead's `author` is a dog
session (gastown.dog-N / dog-<id>). `pilot.dispatched_at` is deliberately NOT used: measured
25/09 it was on 4 of 16 gated beads, and missing even on crew/wa-worker/* branches (the
reclaim guard strips it), so it would keep a biased sample. For a repair the builder is the
author of the review that judged the repair. Everything else is skipped (definitive skips are
remembered in a small file so a poll never re-pays two bd calls per non-pool bead).

NOT MEASURED IN PHASE 1: tokens per attempt (needs mapping a gate run to a worker transcript
span). The proxy is the number of attempts until approval (each attempt = one fresh worker +
one fresh reviewer session), which the report computes from the gate log. Phase 2 can price it.

CLI:
  python3 jev_quem_pensa_experiment.py run [--gc-city PATH] [--qg-log PATH]
      [--dry-run] [--limit N] [--since-days N]
    One pass: new entities (oldest outcome first, at most --limit) -> Jev -> log. Single
    instance (flock). Idempotent: an entity that already has an answered record is skipped.
  The mocked selftest is scripts/jev-quem-pensa.selftest.py (via jev-quem-pensa.selftest.sh).
"""
from __future__ import annotations

import argparse
import fcntl
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import jev_experiment as je  # noqa: E402
import jev_gate_verdict_experiment as gv  # noqa: E402

MODE = "quem-pensa"
EXP_NOVA = "quem-pensa-nova"
EXP_CONSERTO = "quem-pensa-conserto"

# Phase 1 never changes the model. This is what pools run today (Athos + Mayor, 25/09) and
# what every fallback ("nao_sei", not confident) keeps.
MODELO_PADRAO = "sonnet"

CONFIDENCE_THRESHOLD = 0.85
MAX_JEV_FAILS = 3
CIRCUIT_BREAK_FAILS = 3
DEFAULT_SINCE_DAYS = 4.0
DEFAULT_LIMIT = 30
HTTP_TIMEOUT_S = max(je.HTTP_TIMEOUT_S, 15)
STATE_TEXT_BUDGET = 6000
DIFFSTAT_LINE_BUDGET = 60

DEFAULT_LOG_DIR = Path(os.environ.get("JEV_QUEM_PENSA_DIR", "/Users/athos/gt/.gascity-gastown-hq/.gc/logs"))
SKIPS_PATH = DEFAULT_LOG_DIR / "jev-quem-pensa-skips.jsonl"
LOCK_PATH = DEFAULT_LOG_DIR / "jev-quem-pensa.lock"
DISABLED_PATH = DEFAULT_LOG_DIR / "jev-quem-pensa.disabled"

# ── the two questions ────────────────────────────────────────────────────────────────
NOVA_KEY = "dificuldade"
NOVA_INSTRUCTIONS = (
    "You are shown the text of a software task (title, description, acceptance criteria) that "
    "will be handed to an autonomous coding agent working inside an existing codebase it can "
    "read and run. Judge how hard the task is FOR THAT AGENT: how much design, cross-file "
    "reasoning and careful verification it needs — not how long it takes."
)
NOVA_OPTIONS = {
    "facil": (
        "Mechanical or tightly scoped: a small localized change (a few lines, a rename, a "
        "config value, a text or docs fix) whose approach is obvious from the text and needs "
        "no design decisions."
    ),
    "media": (
        "Moderate: several files or steps, some judgment or debugging, but the approach is "
        "reasonably clear from the text."
    ),
    "dificil": (
        "Hard: needs design or architecture decisions, cross-cutting reasoning, subtle "
        "correctness (concurrency, data loss, safety), an unclear root cause, or verification "
        "against live systems."
    ),
}

CONSERTO_KEY = "natureza"
CONSERTO_INSTRUCTIONS = (
    "You are shown a quality-gate reviewer's rejection of a code change, the diff stat of the "
    "rejected change and which attempt this is. Decide what FIXING the rejection demands from "
    "the next agent: mechanical edits to spots the reviewer names, or real reasoning."
)
CONSERTO_OPTIONS = {
    "mecanico": (
        "The rejection points at specific spots to change (wording, a comment, a test "
        "assertion, a name, one small missing case) and states or clearly implies the exact "
        "edit; the approach itself is not in question."
    ),
    "raciocinio": (
        "The rejection exposes a flaw in the approach, an unknown root cause, a whole CLASS of "
        "bug to re-derive, conflicting requirements or a design problem; fixing it takes "
        "reasoning, not only editing."
    ),
}

_POOL_BRANCH_RE = re.compile(r"^crew/(wa-worker|ps-worker)(/|$)")
_POOL_AUTHOR_RE = re.compile(r"^(?:gastown\.)?dog-[A-Za-z0-9]+$")


# ── Jev `choice` call ────────────────────────────────────────────────────────────────
def call_jev_choice(state: str, question_key: str, instructions: str, options: dict) -> dict:
    """One typed `choice` question about ONE state. Never raises. ok=False (any reason) always
    means "unknown" to the caller — the fail-closed policy lives in decide(), not here.

    Response shape verified against the LIVE API 2026-09-25 (not only the docs): the same
    double wrapper the noul call gets ({"result": {"state", "result": {"answers": ...,
    "usage": ...}}}), and the answer is {"type": "choice", "choice": <key>, "probabilities":
    {<key>: p, ...}, "confidence": c}. Nothing is accepted that does not validate: the chosen
    key must be one of `options` and carry a probability, every number must be in [0, 1]."""
    account_id, token, vault_failed = je._credentials()
    if not account_id or not token:
        return {"ok": False, "error": "vault_unavailable" if vault_failed else "no_credentials"}
    if not re.fullmatch(r"[0-9a-f]{32}", account_id):
        return {"ok": False, "error": "bad_account_id"}

    body = json.dumps(
        {
            "model": je.JEV_MODEL,
            "input": {
                "state": state,
                "questions": {
                    question_key: {"type": "choice", "instructions": instructions, "criteria": dict(options)}
                },
            },
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/run",
        data=body,
        method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
            raw = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"http_{e.code}"}
    except (urllib.error.URLError, TimeoutError, OSError, http.client.HTTPException) as e:
        return {"ok": False, "error": f"network: {type(e).__name__}: {e}"}
    except ValueError as e:  # JSONDecodeError and UnicodeDecodeError
        return {"ok": False, "error": f"bad_json: {e}"}

    candidates = [raw]
    if isinstance(raw, dict):
        r1 = raw.get("result")
        if isinstance(r1, dict):
            candidates.append(r1)
            r2 = r1.get("result")
            if isinstance(r2, dict):
                candidates.append(r2)
    payload = next((c for c in candidates if isinstance(c, dict) and isinstance(c.get("answers"), dict)), None)
    if payload is None:
        return {"ok": False, "error": "unparseable_response_shape"}
    try:
        answer = payload["answers"][question_key]
        choice = answer["choice"]
        probabilities = {str(k): float(v) for k, v in answer["probabilities"].items()}
        confidence = float(answer["confidence"])
        usage = payload.get("usage", {}) or {}
        tokens_in = int(usage.get("input_tokens", 0) or 0)
        tokens_out = int(usage.get("output_tokens", 0) or 0)
    except (KeyError, TypeError, ValueError, AttributeError, OverflowError) as e:
        # OverflowError: Python's JSON reader accepts `Infinity`/`1e999`, and int(inf) raises it —
        # not a ValueError. "Never raises" is this function's contract, so it is listed here.
        return {"ok": False, "error": f"unparseable_answer: {e}"}

    if choice not in options:
        return {"ok": False, "error": f"choice_not_in_options: {choice!r}"}
    if choice not in probabilities:
        return {"ok": False, "error": f"chosen_option_without_probability: {choice!r}"}
    if not all(0.0 <= p <= 1.0 for p in probabilities.values()) or not (0.0 <= confidence <= 1.0):
        return {"ok": False, "error": "probability_out_of_range"}
    return {
        "ok": True,
        "choice": choice,
        "prob": probabilities[choice],
        "confidence": confidence,
        "probabilities": probabilities,
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
    }


def decide(experiment: str, answer: dict | None, threshold: float = CONFIDENCE_THRESHOLD) -> tuple[str, str]:
    """(escolha_jev, modelo_jev). Sonnet unless Jev is confident about the ONE case that earns
    a different model: facil -> haiku (new task), raciocinio -> opus (repair). A failed or
    missing answer is "nao_sei" — never a guess in either direction."""
    if not answer or not answer.get("ok"):
        return "nao_sei", MODELO_PADRAO
    choice = answer["choice"]
    confident = answer["prob"] >= threshold and answer["confidence"] >= threshold
    if experiment == EXP_NOVA:
        return choice, ("haiku" if choice == "facil" and confident else MODELO_PADRAO)
    return choice, ("opus" if choice == "raciocinio" and confident else MODELO_PADRAO)


def classify_pool(branch: str | None, author: str | None) -> str | None:
    """Which pool built this attempt: "wa-worker", "ps-worker", "dog", or None (a named crew or
    the Mayor — not a pool choice, out of scope)."""
    m = _POOL_BRANCH_RE.match(branch or "")
    if m:
        return m.group(1)
    if _POOL_AUTHOR_RE.match(author or ""):
        return "dog"
    return None


# ── reviews and entities ─────────────────────────────────────────────────────────────
def load_reviews(qg_log) -> dict[str, list[dict]]:
    """bead -> its gate reviews (PASS/FAIL, real runs only), oldest first. The WHOLE log is
    read on purpose: the attempt number of a review is its position among ALL the bead's
    reviews, so a since-window here would call a bead's 5th review its 1st."""
    by_bead: dict[str, list[dict]] = defaultdict(list)
    seen_runs: set[str] = set()
    for ev in gv.iter_dispatcher_complete(qg_log):
        if str(ev.get("dry_run", "0")) == "1" or not ev.get("bead"):
            continue
        if ev["gate_run"] in seen_runs:
            continue
        seen_runs.add(ev["gate_run"])
        by_bead[ev["bead"]].append(ev)
    for revs in by_bead.values():
        revs.sort(key=lambda r: (r.get("ts", ""), r["gate_run"]))
    return dict(by_bead)


def collect_entities(reviews_by_bead: dict[str, list[dict]], since_days: float, now: datetime | None = None) -> list[dict]:
    """The decision points whose outcome is known and recent: review 1 of a bead (a new task)
    and every review that follows a FAIL (a repair). A FAIL still waiting for its next review
    is not an entity yet — no outcome. Oldest outcome first, so a backlog drains in order."""
    cutoff = (now or datetime.now(timezone.utc)) - timedelta(days=since_days)
    out: list[dict] = []
    for bead, revs in reviews_by_bead.items():
        approved = any(r["result"] == "PASS" for r in revs)
        for i, rv in enumerate(revs):
            if i > 0 and revs[i - 1]["result"] != "FAIL":
                continue
            ts = gv._parse_ts(rv.get("ts"))
            if ts is None or ts < cutoff:
                continue
            nova = i == 0
            out.append(
                {
                    "experiment": EXP_NOVA if nova else EXP_CONSERTO,
                    "entity_id": bead if nova else f"{bead}#{i + 1}",
                    "bead": bead,
                    "rig": rv.get("rig"),
                    "attempt": i + 1,
                    "review": rv,
                    "prior": None if nova else revs[i - 1],
                    "reviews_so_far": len(revs),
                    "approved_so_far": approved,
                }
            )
    out.sort(key=lambda e: (e["review"].get("ts", ""), e["entity_id"]))
    return out


def _read_jsonl(path) -> list[dict]:
    p = Path(path)
    if not p.exists():
        return []
    out = []
    with p.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(ev, dict):
                out.append(ev)
    return out


def load_done(jev_log, skips_path) -> set[tuple[str, str]]:
    """(experiment, entity_id) that need no further work: answered by Jev, failed
    MAX_JEV_FAILS times (stays "nao_sei"), or a definitive skip (not pool work)."""
    fails: dict[tuple[str, str], int] = defaultdict(int)
    done: set[tuple[str, str]] = set()
    for ev in _read_jsonl(jev_log):
        if ev.get("mode") != MODE or not ev.get("entity_id"):
            continue
        key = (ev.get("experiment", ""), ev["entity_id"])
        if ev.get("jev_ok") is True:
            done.add(key)
        else:
            fails[key] += 1
    done.update(k for k, n in fails.items() if n >= MAX_JEV_FAILS)
    for ev in _read_jsonl(skips_path):
        if ev.get("experiment") and ev.get("entity_id"):
            done.add((ev["experiment"], ev["entity_id"]))
    return done


# ── state text ───────────────────────────────────────────────────────────────────────
def _cap(text: str | None, budget: int) -> str:
    text = (text or "").strip()
    return text if len(text) <= budget else text[:budget] + f"\n[... truncated, {len(text) - budget} more chars]"


def build_state_nova(bead: dict) -> str:
    """Task text ONLY: title, type, description, acceptance criteria. No notes/comments/labels —
    that is where "Gate FAILED", needs-fix and the whole outcome accumulate, and Jev must
    judge the task the way a dispatcher saw it."""
    parts = [f"TITLE: {(bead.get('title') or '').strip()}"]
    if bead.get("issue_type"):
        parts.append(f"TYPE: {bead['issue_type']}")
    parts += ["", "DESCRIPTION:", _cap(bead.get("description"), STATE_TEXT_BUDGET)]
    acceptance = (bead.get("acceptance_criteria") or "").strip()
    if acceptance:
        parts += ["", "ACCEPTANCE CRITERIA:", _cap(acceptance, STATE_TEXT_BUDGET // 2)]
    return "\n".join(parts)


def build_state_conserto(attempt: int, reason: str, diffstat: str) -> str:
    return "\n".join(
        [
            f"ATTEMPT: {attempt} (attempt {attempt - 1} of this task was rejected by the quality gate; "
            "the next agent must fix what follows)",
            "",
            "GATE REVIEWER'S REJECTION:",
            _cap(reason, STATE_TEXT_BUDGET),
            "",
            "DIFF STAT OF THE REJECTED CHANGE:",
            diffstat,
        ]
    )


def _bd_comments(city: str, bead_id: str) -> list[dict] | None:
    r = gv._run(["bd", "-C", city, "comments", bead_id, "--json"], timeout=30)
    if r is None or r.returncode != 0:
        return None
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None
    return [c for c in data if isinstance(c, dict)] if isinstance(data, list) else None


def fail_reason(comments: list[dict]) -> str | None:
    """The gate's own rejection comment ("Gate FAILED. ... Blocking reasons: ..."). The LAST
    one wins if a run was annotated twice; None when the run carries none — the caller must
    treat that as "cannot build the state", not as an empty reason."""
    texts = [c.get("text") or "" for c in comments if (c.get("text") or "").lstrip().startswith("Gate FAILED")]
    return texts[-1] if texts else None


def _diffstat(gc_city: str, prior: dict, gate_run_bead: dict, rig_paths: dict[str, str]) -> tuple[str, bool]:
    """(text, ok). The stat of the change that was rejected. When any piece is missing the text
    says which, ok is False, and the run still asks Jev — the reason is the main input — but the
    record says the stat was not there."""
    rig = prior.get("rig")
    repo_root = gv.resolve_rig_root(rig, rig_paths) if rig else None
    if not repo_root:
        return f"(diff stat unavailable: rig {rig!r} has no resolvable repo)", False
    marker = prior.get("marker")
    marker_bead = gv._bd_show(gc_city, marker) if marker else None
    base = gv._field((marker_bead or {}).get("description", ""), "base_commit")
    head = gv._field(gate_run_bead.get("description", ""), "branch_sha")
    if not base or not head:
        return "(diff stat unavailable: base_commit/branch_sha not recorded)", False
    if not gv.ensure_commits_available(repo_root, base, head):
        return "(diff stat unavailable: commits no longer in the repo)", False
    raw = gv._git_text(repo_root, ["diff", "--stat", f"{base}...{head}"])
    if raw is None:
        return "(diff stat unavailable: git diff --stat failed)", False
    lines = raw.strip().splitlines()
    if not lines:
        return "(no changes)", True
    if len(lines) > DIFFSTAT_LINE_BUDGET:
        lines = lines[:DIFFSTAT_LINE_BUDGET] + [f"[... {len(lines) - DIFFSTAT_LINE_BUDGET} more lines]"]
    return "\n".join(lines), True


def find_bead(bead_id: str, rig: str | None, gc_city: str, rig_paths: dict[str, str]) -> tuple[dict | None, list[str]]:
    """The bead's own store is decided by its id prefix, NOT by the rig of the gate event (which is
    where the branch was delivered): measured 25/09 on the whole gate log, ~6% of reviews are
    cross-rig (229 `ga-` beads delivered in whatsapp_automation, 33 `wa-` beads in gascity, 22
    `ga-` in property_scrapers ...). Reading only the event's rig store would drop exactly those
    silently. Order: the event's rig first (right ~94% of the time, one call), then the HQ store,
    then every other rig — the first store that has the bead wins. (bead, stores tried)."""
    order = [rig_paths.get(rig or ""), gc_city, *rig_paths.values()]
    tried: list[str] = []
    for store in order:
        if not store or store in tried:
            continue
        tried.append(store)
        bead = gv._bd_show(store, bead_id)
        if bead is not None:
            return bead, tried
    return None, tried


# ── one entity ───────────────────────────────────────────────────────────────────────
def process_entity(ent: dict, gc_city: str, ctx: dict, ask=call_jev_choice, threshold: float = CONFIDENCE_THRESHOLD):
    """Returns (status, detail). status "logged" -> detail is the record; "skip_definitive_*"
    -> detail is a reason to remember; any other "skip_*" is transient (retried next run).
    `ctx["rig_paths"]` is filled on first need (gc rig list is slow under Dolt load)."""
    rv = ent["review"]
    experiment = ent["experiment"]
    gate_run_bead = None

    pool = classify_pool(rv.get("branch"), None)
    if pool is None:
        gate_run_bead = gv._bd_show(gc_city, rv["gate_run"])
        if gate_run_bead is None:
            return "skip_gate_run_unreadable", f"gate_run={rv['gate_run']} unreadable"
        author = gv._field(gate_run_bead.get("description", ""), "author")
        if not author:
            # A gate-run with no `author:` line says nothing about who built it. "Not pool" is a
            # fact only when an author IS there and is not a pool one; an unknown author must
            # stay retryable, never be remembered as a definitive skip.
            return "skip_gate_run_no_author", f"gate_run={rv['gate_run']} has no author field"
        pool = classify_pool(rv.get("branch"), author)
        if pool is None:
            return "skip_definitive_not_pool", "builder is a named crew or the Mayor"

    if ctx.get("rig_paths") is None:
        ctx["rig_paths"] = gv._rig_paths()
    rig_paths = ctx["rig_paths"]

    diffstat_ok = None
    if experiment == EXP_NOVA:
        bead, tried = find_bead(ent["bead"], ent.get("rig"), gc_city, rig_paths)
        if bead is None:
            return "skip_bead_unreadable", f"bead={ent['bead']} not readable in any of {tried}"
        state, key, instructions, options = build_state_nova(bead), NOVA_KEY, NOVA_INSTRUCTIONS, NOVA_OPTIONS
    else:
        prior = ent["prior"]
        prior_run = gv._bd_show(gc_city, prior["gate_run"])
        if prior_run is None:
            return "skip_prior_gate_run_unreadable", f"gate_run={prior['gate_run']} unreadable"
        comments = _bd_comments(gc_city, prior["gate_run"])
        reason = fail_reason(comments) if comments is not None else None
        if reason is None:
            return "skip_no_fail_reason", f"gate_run={prior['gate_run']} has no 'Gate FAILED' comment"
        stat, diffstat_ok = _diffstat(gc_city, prior, prior_run, rig_paths)
        state, key, instructions, options = (
            build_state_conserto(ent["attempt"], reason, stat), CONSERTO_KEY, CONSERTO_INSTRUCTIONS, CONSERTO_OPTIONS,
        )

    answer = ask(state, key, instructions, options)
    escolha, modelo = decide(experiment, answer, threshold)
    record = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "mode": MODE,
        "experiment": experiment,
        "entity_id": ent["entity_id"],
        "bead": ent["bead"],
        "rig": ent.get("rig"),
        "pool": pool,
        "attempt": ent["attempt"],
        "jev_ok": bool(answer.get("ok")),
        "jev_error": None if answer.get("ok") else answer.get("error", "unknown"),
        "jev_tokens_in": int(answer.get("tokens_in", 0) or 0),
        "jev_tokens_out": int(answer.get("tokens_out", 0) or 0),
        "escolha_jev": escolha,
        "prob_escolha": answer.get("prob") if answer.get("ok") else None,
        "confianca_jev": answer.get("confidence") if answer.get("ok") else None,
        "probabilidades": answer.get("probabilities") if answer.get("ok") else None,
        "limiar": threshold,
        "modelo_jev": modelo,
        "modelo_real": MODELO_PADRAO,
        "desfecho_veredito": rv["result"],
        "desfecho_gate_run": rv["gate_run"],
        "desfecho_ts": rv.get("ts"),
        "tentativas_ate_agora": ent["reviews_so_far"],
        "aprovada_ate_agora": ent["approved_so_far"],
    }
    if diffstat_ok is not None:
        record["diffstat_ok"] = diffstat_ok
    return "logged", record


def _append_jsonl(path, entry: dict) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def run(
    gc_city: str | None = None,
    qg_log: str | None = None,
    dry_run: bool = False,
    limit: int = DEFAULT_LIMIT,
    since_days: float = DEFAULT_SINCE_DAYS,
    ask=call_jev_choice,
    skips_path=None,
    now: datetime | None = None,
) -> dict:
    """One pass. Returns counters (also printed by main): entities found/new, per-status
    counts, how many were logged and whether the Jev circuit breaker stopped the run."""
    gc_city = gc_city or gv.DEFAULT_GC_CITY
    qg_log = qg_log or f"{gc_city}/.gc/quality-gate.jsonl"
    skips_path = skips_path or SKIPS_PATH

    entities = collect_entities(load_reviews(qg_log), since_days, now=now)
    done = load_done(je.JEV_LOG, skips_path)
    todo = [e for e in entities if (e["experiment"], e["entity_id"]) not in done]

    counts: dict = {"entities": len(entities), "new": len(todo), "processed": 0, "logged": 0,
                    "jev_failed": 0, "circuit_break": False, "statuses": defaultdict(int)}
    ctx: dict = {"rig_paths": None}
    consecutive_fails = 0
    for ent in todo:
        if counts["processed"] >= limit:
            break
        counts["processed"] += 1
        status, detail = process_entity(ent, gc_city, ctx, ask=ask)
        counts["statuses"][status] += 1
        if status.startswith("skip_definitive"):
            if not dry_run:
                _append_jsonl(skips_path, {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                           "experiment": ent["experiment"], "entity_id": ent["entity_id"], "reason": detail})
            continue
        if status != "logged":
            continue
        if not dry_run:
            je._log(detail)
        counts["logged"] += 1
        if detail["jev_ok"]:
            consecutive_fails = 0
        else:
            counts["jev_failed"] += 1
            consecutive_fails += 1
            if consecutive_fails >= CIRCUIT_BREAK_FAILS:
                counts["circuit_break"] = True
                break
    counts["statuses"] = dict(counts["statuses"])
    return counts


def acquire_lock(path=None):
    """Single instance: flock is released by the kernel when the process dies, so a crashed
    run never leaves a stale lock behind. Returns the open fd, or None if another run holds it."""
    p = Path(path or LOCK_PATH)
    p.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(p), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--gc-city", default=None)
    r.add_argument("--qg-log", default=None)
    r.add_argument("--dry-run", action="store_true")
    r.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    r.add_argument("--since-days", type=float, default=DEFAULT_SINCE_DAYS)
    args = ap.parse_args()

    if os.environ.get("JEV_QUEM_PENSA_ENABLED", "1") == "0" or DISABLED_PATH.exists():
        print("jev_quem_pensa: disabled (JEV_QUEM_PENSA_ENABLED=0 or the .disabled file) — nothing done")
        return 0
    fd = acquire_lock()
    if fd is None:
        print("jev_quem_pensa: another run holds the lock — nothing done")
        return 0
    t0 = time.time()
    counts = run(gc_city=args.gc_city, qg_log=args.qg_log, dry_run=args.dry_run, limit=args.limit, since_days=args.since_days)
    counts["seconds"] = round(time.time() - t0, 1)
    counts["dry_run"] = args.dry_run
    print(json.dumps(counts, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
