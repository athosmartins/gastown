#!/usr/bin/env python3
"""jev_gate_fail_categoria_experiment.py (ga-bwzzqd, epic ga-aijm2v) — SHADOW MODE: for a real
quality-gate REJECTION (a review that follows a FAIL), what KIND of rejection is it, and would
it have been a candidate for a "conserto leve" (a repair session with minimal context — just
the diff + the reviewer's comment, possibly a cheaper model — instead of a full fresh-worker
repair)? NOTHING here changes what the gate does or what session repairs a bead: this only logs
Jev's read next to what really happened, exactly like every other front built on
jev_experiment.py's SOMBRA discipline (F0, ga-aijm2v.1).

WHY (see ga-bwzzqd's own description): classify_fail_reason() (ga-w3yvoz, pool-preamble-
measure.py) already separates a MECHANICAL gate FAIL (the gate's own plumbing: reviewer
timeout, an unjudged verdict, a merge that broke) from a REAL review FAIL (a reviewer actually
read the diff and rejected it). This front goes one level deeper into the REAL-review bucket:
five atomic yes/no questions about WHY the reviewer rejected it, so a later measurement (hand-
labeled against real historical FAILs, per ga-bwzzqd's "Medir" section — NOT done by this
script) can tell whether Jev's read of "ajuste pequeno e localizado" reliably predicts a case
where a minimal-context repair session would have been enough.

RULES FROM THE 28/09 RESEARCH (ga-bwzzqd, "Regras obrigatórias" — applied here):
  - ATOMIC questions: five small yes/no questions about ONE state, in ONE call_jev_multi call —
    never one broad "which of these five" ask. (A single broad `choice` call measured 62.6%
    accuracy in an independent test; five atomic yes/no + logistic regression measured 95%.)
    call_jev_multi already bills the state once and prices extra questions at ~nothing
    (ga-aijm2v.4), so this costs about the same as one question.
  - THIRD STATE: Jev down, every question garbled, or no single category clears the 0.5 floor
    -> categoria_jev = "incerta"/"nao_sei" (kept apart in the record: `jev_ok` distinguishes
    "asked, no clear winner" from "could not ask at all"), never silently defaulted to a
    specific category.
  - No calibration against hand labels yet (needs the ~100 hand-labeled historical FAILs from
    ga-bwzzqd's Medir (a); out of scope here) — every probability logged is Jev's own raw
    per-category noul, unadjusted. The report script says so.

DESIGN — reuses jev_quem_pensa_experiment's (F9, ga-aijm2v.9) offline-join machinery instead of
re-deriving it: the exact same "a review that follows a FAIL is a repair" entity, the exact same
GATE REVIEWER'S REJECTION + DIFF STAT state text (build_state_conserto), the exact same
`_bd_comments`/`fail_reason`/`_diffstat` plumbing that already reads quality-gate.jsonl + bd +
git for the "quem-pensa-conserto" front. This front asks a DIFFERENT (wider, 5-way) question
about the SAME state and logs to the SAME jev-experiment.jsonl file under its own mode/
experiment name, per the "Relatório diário" rule (own experiment name -> shows up in the 21:07
report once wired into jev-daily-report.sh). Unlike quem-pensa this front does not filter to
pool-only builders: "would a light-fix session have been enough" is a question about the
rejection itself, not about who is fixing it.

CLI:
  python3 jev_gate_fail_categoria_experiment.py run [--gc-city PATH] [--qg-log PATH]
      [--dry-run] [--limit N] [--since-days N]
    One pass: new repair entities (oldest outcome first, at most --limit) -> Jev (5 atomic
    questions, ONE call) -> log. Idempotent: an entity already answered (jev_ok=True) is
    skipped; one that has failed MAX_JEV_FAILS times stays "nao_sei" and is not retried forever.
  python3 jev_gate_fail_categoria_experiment.py selftest
    Mocked (git/bd/gc/network) — no live credential or repo needed.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import jev_experiment as je  # noqa: E402
import jev_gate_verdict_experiment as gv  # noqa: E402
import jev_quem_pensa_experiment as qp  # noqa: E402

MODE = "gate-fail-categoria"
EXPERIMENT = "gate-fail-categoria"
CONFIDENCE_THRESHOLD = 0.85
CATEGORY_FLOOR = 0.5
MAX_JEV_FAILS = 3
DEFAULT_SINCE_DAYS = 4.0
DEFAULT_LIMIT = 30

DEFAULT_LOG_DIR = Path(os.environ.get("JEV_GATE_FAIL_CATEGORIA_DIR", "/Users/athos/gt/.gascity-gastown-hq/.gc/logs"))
LOCK_PATH = DEFAULT_LOG_DIR / "jev-gate-fail-categoria.lock"
DISABLED_PATH = DEFAULT_LOG_DIR / "jev-gate-fail-categoria.disabled"

# The one category whose confident answer names a "conserto leve" (light-fix) candidate —
# same shape as jev_quem_pensa_report's CANDIDATE table, one entry because this front only
# proposes ONE lighter-session route today (ga-bwzzqd's Mecanismo). A future front could add
# more without changing this one's schema.
LIGHT_FIX_CATEGORY = "ajuste_pequeno"

# ── the five atomic questions, ONE call_jev_multi call ──────────────────────────────────────
# Each entry is (instructions, true_desc, false_desc), the exact tuple shape
# jev_experiment.call_jev_multi expects per key.
CATEGORY_QUESTIONS: dict[str, tuple[str, str, str]] = {
    "ajuste_pequeno": (
        "You are shown a quality-gate reviewer's rejection of a code change and the diff stat "
        "of the rejected change. Decide whether the rejection points at a SMALL, LOCALIZED fix.",
        "The rejection names a small, localized fix — wording, a comment, a rename, a config "
        "value, a missing one-line case, or one clearly-named spot to change. The approach "
        "itself is not in question.",
        "The rejection is not about a small, localized fix.",
    ),
    "falta_teste": (
        "You are shown a quality-gate reviewer's rejection of a code change and the diff stat "
        "of the rejected change. Decide whether the rejection is about a MISSING or INADEQUATE "
        "test.",
        "The rejection says no test covers the change, or the new test would also pass against "
        "the old buggy code (proves nothing) — the gap is in test coverage, not in the "
        "production code's logic.",
        "The rejection is not about missing or inadequate test coverage.",
    ),
    "bug_logica": (
        "You are shown a quality-gate reviewer's rejection of a code change and the diff stat "
        "of the rejected change. Decide whether the rejection is about a real LOGIC or "
        "CORRECTNESS bug in the production code.",
        "The rejection points at an actual defect in the code's behavior (a wrong condition, a "
        "'third state' collapsed into a boolean, a wrong assumption, a race, a case that "
        "silently does the wrong thing) that must be understood before it can be fixed.",
        "The rejection is not about a logic or correctness bug in the code.",
    ),
    "escopo_errado": (
        "You are shown a quality-gate reviewer's rejection of a code change and the diff stat "
        "of the rejected change. Decide whether the rejection is about WRONG or INCOMPLETE "
        "scope.",
        "The rejection says the change fixes only one instance of a class of problem, misses "
        "part of what the task asked for, or does more than the task asked (unrequested "
        "refactor/abstraction).",
        "The rejection is not about the change's scope being wrong or incomplete.",
    ),
    "precisa_rebase": (
        "You are shown a quality-gate reviewer's rejection of a code change and the diff stat "
        "of the rejected change. Decide whether the rejection is about the branch being STALE "
        "or CONFLICTING.",
        "The rejection is about the branch needing a rebase or merge with other work, a "
        "conflicting concurrent edit, or content that is stale relative to the target branch — "
        "not about the code's own logic or tests.",
        "The rejection is not about a stale or conflicting branch.",
    ),
}


def call_jev_categoria(state: str) -> dict:
    """One call_jev_multi call, five atomic questions. Never raises. Returns the raw
    call_jev_multi() result unchanged — derive_categoria() below turns it into a category."""
    return je.call_jev_multi(state, CATEGORY_QUESTIONS)


def derive_categoria(answer: dict, floor: float = CATEGORY_FLOOR) -> tuple[str | None, float | None, dict]:
    """(categoria_jev, prob, per-category noul dict). Argmax of whatever categories answered
    (call_jev_multi already keeps a skipped/garbled question OUT of `answers` -- never guessed).
    None (never a guessed category) when: the whole call failed (answer["ok"] is False), every
    question came back bad, or the winning noul does not clear `floor` — a "no category is
    clearly right" state is its own outcome, not silently the first/last category in the dict."""
    if not answer.get("ok"):
        return None, None, {}
    per_category = dict(answer.get("answers") or {})
    if not per_category:
        return None, None, per_category
    winner = max(per_category, key=per_category.get)
    prob = per_category[winner]
    if prob < floor:
        return None, prob, per_category
    return winner, prob, per_category


def load_done(jev_log) -> set[str]:
    """entity_ids that need no further work this run: answered (jev_ok=True), or failed
    MAX_JEV_FAILS times (stays 'nao_sei' rather than being retried forever)."""
    fails: dict[str, int] = {}
    done: set[str] = set()
    for ev in qp._read_jsonl(jev_log):
        if ev.get("mode") != MODE or ev.get("experiment") != EXPERIMENT or not ev.get("entity_id"):
            continue
        if ev.get("jev_ok") is True:
            done.add(ev["entity_id"])
        else:
            fails[ev["entity_id"]] = fails.get(ev["entity_id"], 0) + 1
    done.update(k for k, n in fails.items() if n >= MAX_JEV_FAILS)
    return done


def collect_repair_entities(qg_log, since_days: float, now=None) -> list[dict]:
    """Every review that follows a FAIL (a repair attempt), oldest outcome first -- reuses
    jev_quem_pensa_experiment's own entity collection and keeps only EXP_CONSERTO entities
    (this front does not touch the "brand new task" (EXP_NOVA) side of that module at all)."""
    reviews_by_bead = qp.load_reviews(qg_log)
    entities = qp.collect_entities(reviews_by_bead, since_days, now=now)
    return [e for e in entities if e["experiment"] == qp.EXP_CONSERTO]


def process_entity(ent: dict, gc_city: str, ctx: dict, ask=call_jev_categoria) -> tuple[str, dict | str]:
    """Returns (status, detail). status=='logged' -> detail is the record ready to append to
    jev_experiment.JEV_LOG; any other status -> detail is a short (transient, retryable) reason
    and Jev was never called."""
    if ctx.get("rig_paths") is None:
        ctx["rig_paths"] = gv._rig_paths()
    rig_paths = ctx["rig_paths"]

    prior = ent["prior"]
    prior_run = gv._bd_show(gc_city, prior["gate_run"])
    if prior_run is None:
        return "skip_prior_gate_run_unreadable", f"gate_run={prior['gate_run']} unreadable"
    comments = qp._bd_comments(gc_city, prior["gate_run"])
    reason = qp.fail_reason(comments) if comments is not None else None
    if reason is None:
        return "skip_no_fail_reason", f"gate_run={prior['gate_run']} has no 'Gate FAILED' comment"
    stat, diffstat_ok = qp._diffstat(gc_city, prior, prior_run, rig_paths)
    state = qp.build_state_conserto(ent["attempt"], reason, stat)

    answer = ask(state)
    categoria, prob, per_category = derive_categoria(answer)
    rv = ent["review"]
    record = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "mode": MODE,
        "experiment": EXPERIMENT,
        "entity_id": ent["entity_id"],
        "bead": ent["bead"],
        "rig": ent.get("rig"),
        "attempt": ent["attempt"],
        "jev_ok": bool(answer.get("ok")),
        "jev_error": None if answer.get("ok") else answer.get("error", "unknown"),
        "jev_tokens_in": int(answer.get("tokens_in", 0) or 0),
        "jev_tokens_out": int(answer.get("tokens_out", 0) or 0),
        "categoria_jev": categoria,  # None = "incerta"/"nao_sei" — see derive_categoria()
        "prob_categoria": prob,
        "probabilidades": per_category or None,
        "seria_leve": categoria == LIGHT_FIX_CATEGORY and prob is not None and prob >= CONFIDENCE_THRESHOLD,
        "limiar": CONFIDENCE_THRESHOLD,
        "diffstat_ok": diffstat_ok,
        "desfecho_veredito": rv["result"],
        "desfecho_gate_run": rv["gate_run"],
        "desfecho_ts": rv.get("ts"),
        "tentativas_ate_agora": ent["reviews_so_far"],
        "aprovada_ate_agora": ent["approved_so_far"],
    }
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
    ask=call_jev_categoria,
    now=None,
) -> dict:
    gc_city = gc_city or gv.DEFAULT_GC_CITY
    qg_log = qg_log or f"{gc_city}/.gc/quality-gate.jsonl"

    entities = collect_repair_entities(qg_log, since_days, now=now)
    done = load_done(je.JEV_LOG)
    todo = [e for e in entities if e["entity_id"] not in done]

    counts: dict[str, int] = {"considered": len(entities), "skipped_done": len(entities) - len(todo)}
    ctx: dict = {}
    for ent in todo[:limit]:
        status, detail = process_entity(ent, gc_city, ctx, ask=ask)
        counts[status] = counts.get(status, 0) + 1
        if status == "logged":
            if not dry_run:
                _append_jsonl(je.JEV_LOG, detail)
            print(
                f"[logged] entity={ent['entity_id']} bead={ent['bead']} "
                f"jev_ok={detail['jev_ok']} categoria={detail['categoria_jev']} "
                f"prob={detail['prob_categoria']} seria_leve={detail['seria_leve']}"
            )
        else:
            print(f"[{status}] entity={ent['entity_id']} bead={ent['bead']} -- {detail}")

    other_skips = sum(v for k, v in counts.items() if k not in ("considered", "skipped_done", "logged"))
    print(
        f"jev_gate_fail_categoria_experiment: considered={counts['considered']} "
        f"skipped_done={counts['skipped_done']} logged={counts.get('logged', 0)} "
        f"other_skips={other_skips}"
    )
    return counts


def _selftest() -> int:
    import tempfile
    from datetime import datetime, timedelta, timezone
    from unittest import mock

    this = sys.modules[__name__]
    passed = 0
    failed = 0

    def ok(label: str, cond: bool) -> None:
        nonlocal passed, failed
        if cond:
            passed += 1
            print(f"  ok  {label}")
        else:
            failed += 1
            print(f"  FAIL {label}")

    # derive_categoria(): argmax among answered categories.
    ok(
        "derive_categoria: picks the highest-noul category among those answered",
        derive_categoria({"ok": True, "answers": {"ajuste_pequeno": 0.9, "bug_logica": 0.2}})
        == ("ajuste_pequeno", 0.9, {"ajuste_pequeno": 0.9, "bug_logica": 0.2}),
    )
    ok(
        "derive_categoria: below the floor -> categoria=None, prob still reported (not silently guessed)",
        derive_categoria({"ok": True, "answers": {"ajuste_pequeno": 0.4, "bug_logica": 0.3}})
        == (None, 0.4, {"ajuste_pequeno": 0.4, "bug_logica": 0.3}),
    )
    ok(
        "derive_categoria: whole call failed -> (None, None, {}), never a guess",
        derive_categoria({"ok": False, "error": "no_credentials"}) == (None, None, {}),
    )
    ok(
        "derive_categoria: call ok but every question landed in `bad` (empty answers) -> (None, None, {})",
        derive_categoria({"ok": True, "answers": {}, "bad": {"ajuste_pequeno": "unparseable_answer"}})
        == (None, None, {}),
    )
    ok(
        "derive_categoria: a tie picks a category, never raises (dict order breaks ties deterministically)",
        derive_categoria({"ok": True, "answers": {"a": 0.9, "b": 0.9}})[0] in ("a", "b"),
    )

    # call_jev_categoria(): exactly the five categories go into ONE call_jev_multi call.
    captured = {}

    def fake_multi(state, questions):
        captured["state"] = state
        captured["keys"] = sorted(questions)
        return {"ok": True, "answers": {k: 0.1 for k in questions}, "bad": {}, "tokens_in": 1, "tokens_out": 1}

    with mock.patch.object(je, "call_jev_multi", side_effect=fake_multi):
        call_jev_categoria("some state")
    ok(
        "call_jev_categoria: sends exactly the five categories, in ONE call_jev_multi call",
        captured["keys"] == sorted(CATEGORY_QUESTIONS),
    )
    ok("call_jev_categoria: passes the state through unchanged", captured["state"] == "some state")

    # collect_repair_entities(): only EXP_CONSERTO entities from jev_quem_pensa_experiment's
    # own collect_entities() -- a first review (EXP_NOVA) is never included here.
    with tempfile.TemporaryDirectory() as td:
        qg = Path(td) / "quality-gate.jsonl"
        now_ts = datetime.now(timezone.utc)
        recent = (now_ts - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        qg.write_text(
            json.dumps({"event": "dispatcher_complete", "result": "FAIL", "gate_run": "ga-r1",
                        "marker": "ga-m1", "bead": "b1", "rig": "gascity", "ts": recent}) + "\n"
            + json.dumps({"event": "dispatcher_complete", "result": "PASS", "gate_run": "ga-r2",
                          "marker": "ga-m2", "bead": "b1", "rig": "gascity", "ts": recent}) + "\n"
        )
        entities = collect_repair_entities(str(qg), since_days=4.0)
        ok(
            "collect_repair_entities: the review AFTER the FAIL is the one repair entity, "
            "not the FAIL itself",
            [e["entity_id"] for e in entities] == ["b1#2"] and entities[0]["prior"]["gate_run"] == "ga-r1",
        )

    # load_done(): only this MODE+EXPERIMENT's own records count, and a failed-3x entity is
    # marked done (never retried forever) while an entity with fewer failures stays open.
    with tempfile.TemporaryDirectory() as td:
        jl = Path(td) / "jev-experiment.jsonl"
        jl.write_text(
            json.dumps({"mode": MODE, "experiment": EXPERIMENT, "entity_id": "b1#2", "jev_ok": True}) + "\n"
            + json.dumps({"mode": MODE, "experiment": EXPERIMENT, "entity_id": "b2#2", "jev_ok": False}) + "\n"
            + json.dumps({"mode": MODE, "experiment": EXPERIMENT, "entity_id": "b2#2", "jev_ok": False}) + "\n"
            + json.dumps({"mode": "quem-pensa", "experiment": EXPERIMENT, "entity_id": "b3#2", "jev_ok": True}) + "\n"
        )
        d = load_done(jl)
    ok("load_done: an answered entity is done", "b1#2" in d)
    ok("load_done: an entity failed only twice (below MAX_JEV_FAILS=3) is NOT done yet", "b2#2" not in d)
    ok("load_done: a record from a DIFFERENT mode (quem-pensa) is never counted here", "b3#2" not in d)

    with tempfile.TemporaryDirectory() as td:
        jl = Path(td) / "jev-experiment.jsonl"
        jl.write_text("\n".join(
            json.dumps({"mode": MODE, "experiment": EXPERIMENT, "entity_id": "b4#2", "jev_ok": False})
            for _ in range(MAX_JEV_FAILS)
        ) + "\n")
        d = load_done(jl)
    ok(f"load_done: an entity failed {MAX_JEV_FAILS} times stays 'nao_sei' -- marked done, not retried forever",
       "b4#2" in d)

    # process_entity(): end-to-end happy path.
    ent = {
        "entity_id": "b1#2", "bead": "b1", "rig": "gascity", "attempt": 2,
        "review": {"result": "FAIL", "gate_run": "ga-r2", "ts": "2026-09-28T00:00:00Z"},
        "prior": {"gate_run": "ga-r1", "marker": "ga-m1", "rig": "gascity"},
        "reviews_so_far": 2, "approved_so_far": False,
    }

    def fake_bd_show(city, bead_id):
        if bead_id == "ga-r1":
            return {"id": "ga-r1", "description": "branch_sha: head1\n"}
        raise AssertionError(f"unexpected _bd_show({city!r}, {bead_id!r})")

    def fake_bd_comments(city, bead_id):
        assert bead_id == "ga-r1"
        return [{"text": "Gate FAILED. Blocking: rename the helper to match the call site."}]

    def fake_diffstat(gc_city, prior, gate_run_bead, rig_paths):
        return " f.py | 2 +-\n", True

    def fake_ask_confident(state):
        return {"ok": True, "answers": {"ajuste_pequeno": 0.92, "bug_logica": 0.05}, "bad": {},
                "tokens_in": 50, "tokens_out": 5}

    with mock.patch.object(gv, "_bd_show", side_effect=fake_bd_show), \
         mock.patch.object(qp, "_bd_comments", side_effect=fake_bd_comments), \
         mock.patch.object(qp, "_diffstat", side_effect=fake_diffstat):
        status, detail = process_entity(ent, "/city", {"rig_paths": {}}, ask=fake_ask_confident)
    ok(
        "process_entity: happy path logs categoria=ajuste_pequeno with seria_leve=True "
        "(confident + the light-fix category)",
        status == "logged" and detail["categoria_jev"] == "ajuste_pequeno" and detail["seria_leve"] is True
        and detail["entity_id"] == "b1#2" and detail["desfecho_veredito"] == "FAIL",
    )
    ok("process_entity: GATE REVIEWER'S REJECTION text reaches the state Jev sees",
       "rename the helper" in qp.build_state_conserto(2, "Gate FAILED. Blocking: rename the helper to match the call site.", " f.py | 2 +-\n"))

    def fake_ask_uncertain(state):
        return {"ok": True, "answers": {"ajuste_pequeno": 0.6, "escopo_errado": 0.55}, "bad": {},
                "tokens_in": 50, "tokens_out": 5}

    with mock.patch.object(gv, "_bd_show", side_effect=fake_bd_show), \
         mock.patch.object(qp, "_bd_comments", side_effect=fake_bd_comments), \
         mock.patch.object(qp, "_diffstat", side_effect=fake_diffstat):
        status2, detail2 = process_entity(ent, "/city", {"rig_paths": {}}, ask=fake_ask_uncertain)
    ok(
        "process_entity: winning category below CONFIDENCE_THRESHOLD -> seria_leve=False even "
        "though it IS ajuste_pequeno (confident-only route, matches CONFIDENCE_THRESHOLD)",
        status2 == "logged" and detail2["categoria_jev"] == "ajuste_pequeno" and detail2["seria_leve"] is False,
    )

    with mock.patch.object(gv, "_bd_show", side_effect=lambda city, bid: None):
        status3, detail3 = process_entity(ent, "/city", {"rig_paths": {}})
    ok("process_entity: prior gate_run bead unreadable -> skip_prior_gate_run_unreadable, never calls Jev",
       status3 == "skip_prior_gate_run_unreadable")

    with mock.patch.object(gv, "_bd_show", side_effect=fake_bd_show), \
         mock.patch.object(qp, "_bd_comments", side_effect=lambda city, bid: []):
        status4, detail4 = process_entity(ent, "/city", {"rig_paths": {}})
    ok("process_entity: prior review has no 'Gate FAILED' comment -> skip_no_fail_reason, never calls Jev",
       status4 == "skip_no_fail_reason")

    # run(): dry-run doesn't write; a real run does; re-running is idempotent (dedup).
    with tempfile.TemporaryDirectory() as td:
        qg = Path(td) / "quality-gate.jsonl"
        now_ts = datetime.now(timezone.utc)
        recent = (now_ts - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        qg.write_text(
            json.dumps({"event": "dispatcher_complete", "result": "FAIL", "gate_run": "ga-r1",
                        "marker": "ga-m1", "bead": "b1", "rig": "gascity", "ts": recent}) + "\n"
            + json.dumps({"event": "dispatcher_complete", "result": "PASS", "gate_run": "ga-r2",
                          "marker": "ga-m2", "bead": "b1", "rig": "gascity", "ts": recent}) + "\n"
        )
        jl = Path(td) / "jev-experiment.jsonl"

        with mock.patch.object(je, "JEV_LOG", jl), \
             mock.patch.object(gv, "_rig_paths", return_value={}), \
             mock.patch.object(gv, "_bd_show", side_effect=fake_bd_show), \
             mock.patch.object(qp, "_bd_comments", side_effect=fake_bd_comments), \
             mock.patch.object(qp, "_diffstat", side_effect=fake_diffstat):
            counts1 = run(gc_city="/city", qg_log=str(qg), dry_run=True, ask=fake_ask_confident)
            ok("run: dry-run reports one logged entity but writes nothing",
               counts1.get("logged") == 1 and not jl.exists())

            counts2 = run(gc_city="/city", qg_log=str(qg), dry_run=False, ask=fake_ask_confident)
            ok("run: real run writes exactly one line",
               counts2.get("logged") == 1 and len(jl.read_text().strip().splitlines()) == 1)

            counts3 = run(gc_city="/city", qg_log=str(qg), dry_run=False, ask=fake_ask_confident)
            ok(
                "run: re-running the same quality-gate.jsonl does not double-log (dedup by entity_id)",
                counts3.get("logged", 0) == 0 and counts3.get("skipped_done") == 1
                and len(jl.read_text().strip().splitlines()) == 1,
            )

    print(f"\njev_gate_fail_categoria_experiment selftest: PASS={passed} FAIL={failed}")
    return 1 if failed else 0


def acquire_lock(path=None):
    """Single instance: flock is released by the kernel when the process dies, so a crashed
    run never leaves a stale lock behind (same idiom as jev_quem_pensa_experiment.py's own
    acquire_lock()). Returns the open fd, or None if another run holds it."""
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

    sub.add_parser("selftest", help="mocked, no live repo/credential/Dolt needed")

    r = sub.add_parser("run", help="scan quality-gate.jsonl for new repair entities and log a categoria shadow read")
    r.add_argument("--gc-city", default=None)
    r.add_argument("--qg-log", default=None)
    r.add_argument("--dry-run", action="store_true", help="compute and print, but do not write to the jev log")
    r.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help="max number of NEW entities to log this invocation")
    r.add_argument(
        "--since-days", type=float, default=DEFAULT_SINCE_DAYS,
        help=f"ignore repair entities whose review is older than this many days (default {DEFAULT_SINCE_DAYS})",
    )

    args = ap.parse_args()

    if args.cmd == "selftest":
        return _selftest()

    if args.cmd == "run":
        if os.environ.get("JEV_GATE_FAIL_CATEGORIA_ENABLED", "1") == "0" or DISABLED_PATH.exists():
            print("jev_gate_fail_categoria: disabled (JEV_GATE_FAIL_CATEGORIA_ENABLED=0 or the .disabled file) — nothing done")
            return 0
        fd = acquire_lock()
        if fd is None:
            print("jev_gate_fail_categoria: another run holds the lock — nothing done")
            return 0
        try:
            run(gc_city=args.gc_city, qg_log=args.qg_log, dry_run=args.dry_run, limit=args.limit, since_days=args.since_days)
        finally:
            os.close(fd)
        return 0

    return 1  # pragma: no cover -- argparse's required=True on sub already prevents this


if __name__ == "__main__":
    sys.exit(main())
