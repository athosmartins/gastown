#!/usr/bin/env python3
"""jev_preambulo_experiment.py (ga-aijm2v.7) — SHADOW MODE, "preambulo por tarefa" (step 2 of the
pool doctrine diet): for a task a pool session got, which OPTIONAL doctrine sections would Jev leave out?

WHY (ga-aijm2v epic): the fixed start of a pool session (doctrine + tools + memory) is re-read on every
turn. Step 1 (ga-aijm2v.6) cut what belongs to OTHER roles. Step 2 asks, per task, whether the sections that
remain are needed for THIS task — a mockup rulebook for a shell-script fix, the engine-rebuild procedure for
a docs edit. The error is asymmetric: keeping a section that was not needed costs ~1-3k tokens, dropping one
that was needed costs a rework. So the bar is LOW (a section stays unless Jev thinks P(needed) < 0.3) and every
doubt keeps it.

NOTHING HERE CHANGES ANY SESSION. Pools keep receiving the full doctrine (`aplicado: false` in every record).
This only records what Jev WOULD have cut, so the Athos can see the size of the prize and the risk BEFORE any
session loses a line. Whether it can ever be applied live is a separate, measured question — see
docs/pool-preamble-per-task.md ("O que a sombra ainda não responde"): `gc prime` renders from the agent's
static env only, and a pool session claims its bead AFTER prime, so a live cut needs an engine-side input.

WHAT IS DECIDED, and by whom (all of it declared in claude-overlays/pool-roles.json -> doctrine.per_task,
proven by `pool-preamble-build.py check`):
  * only sections listed in `eligible` can EVER be cut; the core, `never_cut` and any id not in the manifest
    always stay — whatever Jev says, including ids Jev invents;
  * a section is cut only when ALL hold: it is eligible for this role, Jev answered ITS question, P(needed) <
    threshold, no structural floor (`must_include`: issue_type/metadata/labels/regex) fired, and the task text
    carries no prompt-injection marker;
  * third state, everywhere: Jev down / slow / malformed / partial => that section STAYS ("jev_indisponivel").

THE TASK TEXT IS UNTRUSTED. A bead can carry text written by anyone (a scraped page, a lead's message pasted
into a description). It reaches exactly one place: the `state` field of the Jev call, wrapped in
<conteudo_externo> tags with the delimiter neutralized inside it, and the instructions tell Jev it is data.
Jev answers with numbers; nothing from the text is ever executed, interpolated into a prompt for an agent, or
used to name a section (answers for keys we did not ask are ignored). A marker of injection in the text makes
every section stay and skips the Jev call altogether.

ENTITY = a bead routed to a pool template (`gc.routed_to` = gastown.dog / wa-worker / ps-worker) that a session
has picked up (assigned, in_progress or closed) — "a task the dispatcher handed to a pool". Read from every
rig's bd store (one `bd list` per store; a cross-rig bead lives in the store of its id prefix, which is why all
stores are scanned). One record per bead. The gate outcome is NOT written here: jev_preambulo_report.py joins
quality-gate.jsonl at report time, so a bead approved after its record was written still counts.

`arm` (deterministic 50/50 per bead, jev_experiment.assign_arm) is recorded from day one: while everything is
still delivered in full, the two arms MUST look alike at the gate — an A/A check that the split is not
confounded, and the same assignment the A/B will use.

CLI:
  python3 jev_preambulo_experiment.py run [--gc-city PATH] [--dry-run] [--limit N] [--since-days N]
    One pass: new entities (oldest first, at most --limit) -> Jev -> log. Single instance (flock). Idempotent.
    --dry-run still asks Jev (that is the point of a dry run) but writes nothing.
  python3 jev_preambulo_experiment.py explain --store PATH --bead ID
    No Jev call, no write: role, eligible sections, structural floors and injection verdict for one bead.
  The mocked selftest is scripts/jev-preambulo.selftest.py (via jev-preambulo.selftest.sh).
"""
from __future__ import annotations

import argparse
import http.client
import importlib.util
import json
import math
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
import jev_quem_pensa_experiment as qp  # noqa: E402

MODE = "preambulo"
FASE = "sombra"

MAX_JEV_FAILS = 3
CIRCUIT_BREAK_FAILS = 3
DEFAULT_SINCE_DAYS = 4.0
DEFAULT_LIMIT = 60
HTTP_TIMEOUT_S = max(je.HTTP_TIMEOUT_S, 15)
TEXT_SCAN_BUDGET = 20000  # chars of EACH task-text field (title, description, acceptance) the structural/injection regexes look at
RIG_LIST_TIMEOUT_S = 90  # `gc rig list` takes many seconds under Dolt load (ga-eu2x); a batch job, not latency-sensitive

DEFAULT_LOG_DIR = Path(os.environ.get("JEV_PREAMBULO_DIR", "/Users/athos/gt/.gascity-gastown-hq/.gc/logs"))
LOCK_PATH = DEFAULT_LOG_DIR / "jev-preambulo.lock"
DISABLED_PATH = DEFAULT_LOG_DIR / "jev-preambulo.disabled"

# routed_to (a pool template, sometimes rig-prefixed) -> the TD_ROLE the manifest knows it by
_ROLE_BY_ROUTE = (
    (re.compile(r"(^|[./])dog$"), "dog"),
    (re.compile(r"(^|[./])wa-worker$"), "wa-worker"),
    (re.compile(r"(^|[./])ps-worker$"), "ps-worker"),
)
# The fence's opening sequence in any spelling a tag parser or a model reads as the same tag: whitespace after `<` or
# `/`, attributes, no closing `>`, any case. Only the opener is matched: what follows it is left as plain text, and
# with the opener gone no `>` left behind can close or open anything. (Look-alike glyphs are not neutralized; they are
# not our tag to a parser either, and Jev returns numbers only, so this is defense in depth.)
_DELIMITER_RE = re.compile(r"<\s*/?\s*conteudo_externo", re.I)


class PolicyError(Exception):
    """The per-task policy could not be loaded or does not pass `pool-preamble-build.py check`. The run does
    nothing (no question asked, no record) — an incoherent policy must not drive a single decision."""


# ── policy (manifest + fragment) ─────────────────────────────────────────────────────
def _assets_dir() -> Path:
    return Path(os.environ.get("JEV_PREAMBULO_ASSETS") or (Path(__file__).resolve().parent.parent / "packs" / "town-deltas" / "assets"))


def load_policy(assets: Path | None = None) -> dict:
    """{"ppb", "manifest", "pt", "sizes", "eligible"}: the manifest's per_task policy, the size in chars of every
    fragment section and, per role, the ordered ids Jev may be asked about. Raises PolicyError, never returns a
    half-valid policy."""
    assets = Path(assets or _assets_dir())
    script = assets / "pool-preamble-build.py"
    try:
        spec = importlib.util.spec_from_file_location("pool_preamble_build", script)
        ppb = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ppb)
        manifest = ppb.load_manifest()
        blocks = ppb.parse_fragment(ppb.FRAGMENT.read_text(encoding="utf-8"))
        errs, _adv = ppb.check_per_task(manifest, blocks)
    except (OSError, ValueError, AttributeError, ImportError, SyntaxError, KeyError, TypeError) as e:
        raise PolicyError(f"cannot load {script}: {type(e).__name__}: {e}") from e
    if errs:
        raise PolicyError("doctrine.per_task fails `pool-preamble-build.py check`: " + "; ".join(errs[:3]))
    roles = {r["td_role"] for r in manifest["roles"].values()}
    return {
        "ppb": ppb,
        "manifest": manifest,
        "pt": manifest["doctrine"]["per_task"],
        "sizes": {b["id"]: len("\n".join(b["lines"])) + 1 for b in blocks},
        "eligible": {role: ppb.eligible_for_role(manifest, blocks, role) for role in sorted(roles)},
        "delivered": {
            role: sum(len("\n".join(b["lines"])) + 1 for b in blocks
                      if b["cond"] is None or ppb.receives(manifest["doctrine"]["guarded"][b["id"]], role))
            for role in sorted(roles)
        },
    }


def pool_role(routed_to: str | None) -> str | None:
    """The TD_ROLE of a pool template, or None when the bead was not routed to a pool (a crew, the Mayor...)."""
    for rx, role in _ROLE_BY_ROUTE:
        if rx.search((routed_to or "").strip()):
            return role
    return None


# ── what Jev is (not) allowed to see, and structural floors ──────────────────────────
def task_text(bead: dict) -> str:
    """What the injection markers and structural floors read. Each field is stripped and capped SEPARATELY, the way
    qp.build_state_nova prepares what Jev is shown (`_cap` strips, then cuts description at 6000 and acceptance at
    3000): a cap on the joined text would let a long description push the acceptance criteria out of the scan while
    Jev still receives them, and leading whitespace would eat the window. TEXT_SCAN_BUDGET per field is above the
    caps Jev's description (6000) and acceptance (3000) get, so the scan covers at least what Jev sees of them; total
    work stays bounded. The title is the one field Jev's state does not cap: a title past the budget would have an
    unscanned tail (not a real case: the longest title in the HQ store, 26/09, is 336 chars)."""
    return "\n".join(str(bead.get(k) or "").strip()[:TEXT_SCAN_BUDGET] for k in ("title", "description", "acceptance_criteria"))


def build_state(bead: dict) -> str:
    """Task text ONLY (title, type, description, acceptance criteria — no notes/comments/labels, where the outcome
    accumulates), fenced as external content. The fence tag is stripped from inside the text so a description cannot
    close it early."""
    body = _DELIMITER_RE.sub("[tag removida]", qp.build_state_nova(bead))
    return f"<conteudo_externo>\n{body}\n</conteudo_externo>"


def injection_marker(bead: dict, pt: dict) -> str | None:
    """The first prompt-injection marker found in the task text (its regex source), else None. A hit only ever makes
    MORE doctrine stay — a false positive costs a full preamble, never a missing rule."""
    text = task_text(bead)
    for pat in pt["injection_markers"]:
        if re.search(pat, text, re.I):
            return pat
    return None


def structural_floors(bead: dict, pt: dict) -> dict[str, str]:
    """section id -> why it must stay regardless of Jev (manifest per_task.must_include). A bead that does not say
    its type cannot rule out being what an `issue_types` floor protects (a molecule step): unknown is not "task",
    so that section stays ("issue_type_desconhecido") — and only that one, the other floors do not depend on it."""
    text = task_text(bead)
    labels = set(bead.get("labels") or [])
    meta = bead.get("metadata") or {}
    itype = bead.get("issue_type") or bead.get("type")
    out: dict[str, str] = {}
    for sid, rule in (pt.get("must_include") or {}).items():
        if sid == "_doc" or not isinstance(rule, dict):
            continue
        if itype and itype in rule.get("issue_types", []):
            out[sid] = f"issue_type={itype}"
        elif not itype and rule.get("issue_types"):
            out[sid] = "issue_type_desconhecido"
        elif any(k in meta for k in rule.get("metadata_keys", [])):
            out[sid] = "metadata:" + next(k for k in rule["metadata_keys"] if k in meta)
        elif labels & set(rule.get("labels", [])):
            out[sid] = "label:" + sorted(labels & set(rule["labels"]))[0]
        elif rule.get("text_regex") and re.search(rule["text_regex"], text, re.I | re.M):
            out[sid] = "texto"
    return out


# ── Jev: several noul questions in ONE call ──────────────────────────────────────────
def _post_jev(body: dict) -> tuple[object | None, str | None]:
    account_id, token, vault_failed = je._credentials()
    if not account_id or not token:
        return None, "vault_unavailable" if vault_failed else "no_credentials"
    if not re.fullmatch(r"[0-9a-f]{32}", account_id):
        return None, "bad_account_id"
    req = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/run",
        data=json.dumps(body).encode("utf-8"),
        method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
            return json.loads(resp.read()), None
    except urllib.error.HTTPError as e:
        return None, f"http_{e.code}"
    except (urllib.error.URLError, TimeoutError, OSError, http.client.HTTPException) as e:
        return None, f"network: {type(e).__name__}: {e}"
    except ValueError as e:  # JSONDecodeError and UnicodeDecodeError
        return None, f"bad_json: {e}"


def _unwrap(raw) -> dict | None:
    """The live API wraps the payload up to twice ({"result": {"state", "result": {"answers", "usage"}}}); take the
    first level that really has an `answers` dict, never guess past that."""
    candidates = [raw]
    if isinstance(raw, dict):
        r1 = raw.get("result")
        if isinstance(r1, dict):
            candidates.append(r1)
            r2 = r1.get("result")
            if isinstance(r2, dict):
                candidates.append(r2)
    return next((c for c in candidates if isinstance(c, dict) and isinstance(c.get("answers"), dict)), None)


def _parse_noul(answers: dict, sid: str) -> dict:
    """One answer, validated on its own: a malformed answer spoils only ITS section, which then stays."""
    a = answers.get(sid)
    if not isinstance(a, dict):
        return {"ok": False, "error": "missing_answer"}
    v = a.get("noul")
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or not (0.0 <= v <= 1.0):
        return {"ok": False, "error": f"bad_noul: {v!r}"}
    return {"ok": True, "noul": float(v)}


def _tokens(usage) -> tuple[int, int]:
    try:
        usage = usage if isinstance(usage, dict) else {}
        return int(usage.get("input_tokens", 0) or 0), int(usage.get("output_tokens", 0) or 0)
    except (TypeError, ValueError, OverflowError):
        return 0, 0


def call_jev_noul_multi(state: str, questions: dict[str, dict], max_per_call: int = 13) -> tuple[dict[str, dict], dict]:
    """(answers, meta). `questions` = {section id: {"instructions", "true", "false"}}. One noul question per section,
    up to `max_per_call` per request (the API's limit; the cost is ~one call's). NEVER raises. Every section id asked
    has an entry in `answers` — {"ok": True, "noul": p} or {"ok": False, "error": ...}. Ids the API returns that we
    did not ask are ignored (the answer set is defined by US). meta: ok (every answer ok), error (first), tokens."""
    answers: dict[str, dict] = {}
    tin = tout = 0
    first_error = None
    ids = list(questions)
    for i in range(0, len(ids), max(1, max_per_call)):
        chunk = ids[i:i + max(1, max_per_call)]
        body = {
            "model": je.JEV_MODEL,
            "input": {
                "state": state,
                "questions": {
                    sid: {"type": "noul", "instructions": questions[sid]["instructions"],
                          "criteria": {"true": questions[sid]["true"], "false": questions[sid]["false"]}}
                    for sid in chunk
                },
            },
        }
        raw, err = _post_jev(body)
        payload = None if err else _unwrap(raw)
        if err is None and payload is None:
            err = "unparseable_response_shape"
        if err:
            first_error = first_error or err
            for sid in chunk:
                answers[sid] = {"ok": False, "error": err}
            continue
        a, b = _tokens(payload.get("usage"))
        tin, tout = tin + a, tout + b
        for sid in chunk:
            answers[sid] = _parse_noul(payload["answers"], sid)
            if not answers[sid]["ok"]:
                first_error = first_error or answers[sid]["error"]
    ok = bool(answers) and all(a["ok"] for a in answers.values())
    return answers, {"ok": ok, "error": None if ok else (first_error or "no_questions"), "tokens_in": tin, "tokens_out": tout}


# ── the decision (pure) ──────────────────────────────────────────────────────────────
def decide_sections(eligible: list[str], answers: dict[str, dict], floors: dict[str, str], threshold: float,
                    injected: bool) -> tuple[list[str], list[str], dict[str, str]]:
    """(incluidas, cortadas, motivos) over the ELIGIBLE sections only. A section is cut only when Jev answered its
    question with P(needed) < threshold AND nothing else says keep it. Everything else stays, each with its reason."""
    kept, cut, why = [], [], {}
    for sid in eligible:
        a = answers.get(sid)
        if injected:
            reason = "suspeita_injecao"
        elif sid in floors:
            reason = "piso_estrutural:" + floors[sid]
        elif not isinstance(a, dict) or not a.get("ok"):
            reason = "jev_indisponivel"
        elif a["noul"] >= threshold:
            reason = "jev_precisa"
        else:
            reason = None
        if reason:
            kept.append(sid)
            why[sid] = reason
        else:
            cut.append(sid)
            why[sid] = "jev_dispensa"
    return kept, cut, why


# ── entities ─────────────────────────────────────────────────────────────────────────
def picked_up(bead: dict) -> bool:
    """A session took it: assigned, in progress, or already closed. An open + unassigned bead is still waiting."""
    return bool((bead.get("assignee") or "").strip()) or bead.get("status") in ("in_progress", "closed")


def _bd_list(store: str, extra: list[str]) -> list[dict] | None:
    r = gv._run(["bd", "-C", store, "list", "--has-metadata-key", "gc.routed_to", "--all", "--json", "--limit", "0", *extra], timeout=120)
    if r is None or r.returncode != 0:
        return None
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None
    return [b for b in data if isinstance(b, dict)] if isinstance(data, list) else None


def rig_store_paths() -> tuple[dict[str, str], str | None]:
    """(rig name -> path, error). Three states, never two: `error` is None ONLY when `gc rig list` answered and said
    which rigs exist (an empty map then really means "no rig"); otherwise the map is what could be read and `error`
    says why it is not the whole answer. gv._rig_paths() returns {} for a failed call too, so a caller cannot tell
    "no other rigs" from "could not ask" — and this job would then scan the HQ store alone while reporting full
    coverage (whatsapp_automation holds most of the pool-routed beads)."""
    r = gv._run(["gc", "rig", "list", "--json"], timeout=RIG_LIST_TIMEOUT_S)
    if r is None:
        return {}, "rig_list_unavailable"
    if r.returncode != 0:
        return {}, f"rig_list_rc_{r.returncode}"
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return {}, "rig_list_bad_json"
    rigs = data.get("rigs") if isinstance(data, dict) else None
    if not isinstance(rigs, list):
        return {}, "rig_list_bad_shape"
    if data.get("ok") is False:
        return {}, "rig_list_not_ok"
    out: dict[str, str] = {}
    unusable = 0
    for rig in rigs:
        name, path = (rig.get("name"), rig.get("path")) if isinstance(rig, dict) else (None, None)
        if name and path:
            out[name] = path
        else:
            unusable += 1
    return out, (f"rig_list_{unusable}_rig_without_path" if unusable else None)


def discover(stores: list[str], since_days: float, now: datetime | None = None) -> tuple[list[dict], list[str]]:
    """(entities, unreadable stores). Per store: beads CREATED in the window plus beads currently in progress whatever
    their age (an old bead dispatched today is still a task handed to a pool). One entity per bead id; oldest first.
    A store that cannot be read is REPORTED, never read as "no tasks"."""
    after = ((now or datetime.now(timezone.utc)) - timedelta(days=since_days)).strftime("%Y-%m-%d")
    seen: dict[str, dict] = {}
    unreadable: list[str] = []
    for store in stores:
        recent = _bd_list(store, ["--created-after", after])
        active = _bd_list(store, ["--status", "in_progress"])
        if recent is None or active is None:
            unreadable.append(store)  # fully or partly unreadable: said so, never read as "no tasks"
        for bead in (recent or []) + (active or []):
            bead_id = bead.get("id")
            role = pool_role((bead.get("metadata") or {}).get("gc.routed_to"))
            if not bead_id or role is None or not picked_up(bead) or bead_id in seen:
                continue
            seen[bead_id] = {"entity_id": bead_id, "bead": bead, "store": store, "pool": role}
    ents = sorted(seen.values(), key=lambda e: (e["bead"].get("created_at") or "", e["entity_id"]))
    return ents, unreadable


def load_done(jev_log) -> set[str]:
    """Bead ids that need no further work: answered (or deliberately not asked because of an injection marker), or
    failed MAX_JEV_FAILS times (then it stays with the fail-open decision)."""
    fails: dict[str, int] = defaultdict(int)
    done: set[str] = set()
    for ev in qp._read_jsonl(jev_log):
        if ev.get("mode") != MODE or not ev.get("entity_id"):
            continue
        if ev.get("jev_status") in ("ok", "nao_chamado_injecao"):
            done.add(ev["entity_id"])
        else:
            fails[ev["entity_id"]] += 1
    done.update(k for k, n in fails.items() if n >= MAX_JEV_FAILS)
    return done


# ── one entity ───────────────────────────────────────────────────────────────────────
def process_entity(ent: dict, policy: dict, ask=call_jev_noul_multi) -> tuple[str, dict | str]:
    """("logged", record) or ("skip_*", reason). Pure but for `ask` (the single Jev seam)."""
    pt, role, bead = policy["pt"], ent["pool"], ent["bead"]
    eligible = policy["eligible"].get(role) or []
    if not eligible:
        return "skip_no_eligible_sections", f"role {role} has no eligible section"

    injected = injection_marker(bead, pt)
    floors = structural_floors(bead, pt)
    answers: dict[str, dict] = {}
    meta = {"ok": False, "error": None, "tokens_in": 0, "tokens_out": 0}
    if injected is None:
        questions = {sid: {k: pt["eligible"][sid][k] for k in ("instructions", "true", "false")} for sid in eligible}
        answers, meta = ask(build_state(bead), questions, pt["max_questions_per_call"])
    kept, cut, why = decide_sections(eligible, answers, floors, pt["threshold"], injected is not None)

    if injected is not None:
        status = "nao_chamado_injecao"
    elif meta["ok"]:
        status = "ok"
    elif any(a.get("ok") for a in answers.values()):
        status = "parcial"
    else:
        status = "falhou"
    chars_cut = sum(policy["sizes"][sid] for sid in cut)
    record = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "mode": MODE,
        "experiment": pt["experiment"],
        "entity_id": ent["entity_id"],
        "bead": ent["entity_id"],
        "store": ent["store"],
        "pool": role,
        "routed_to": (bead.get("metadata") or {}).get("gc.routed_to"),
        "sessao": (bead.get("metadata") or {}).get("gc.session_name"),
        "iniciada_em": bead.get("started_at"),
        "arm": je.assign_arm(ent["entity_id"], pt["experiment"]),
        "fase": FASE,
        "aplicado": False,
        "jev_status": status,
        "jev_ok": status == "ok",
        "jev_error": meta["error"] if status in ("falhou", "parcial") else None,
        "jev_tokens_in": meta["tokens_in"],
        "jev_tokens_out": meta["tokens_out"],
        "limiar": pt["threshold"],
        "elegiveis": eligible,
        "prob": {sid: (answers[sid]["noul"] if answers.get(sid, {}).get("ok") else None) for sid in eligible},
        "incluidas": kept,
        "cortadas": cut,
        "motivos": why,
        "piso_estrutural": floors,
        "injecao_suspeita": injected,
        "chars_cortados": chars_cut,
        "tokens_estimados_poupados": int(round(chars_cut / pt["chars_per_token"])),
        "chars_doutrina_papel": policy["delivered"][role],
        "tarefa_chars": len(task_text(bead)),
    }
    return "logged", record


def _write(record: dict, log_path=None) -> None:
    """The shared Jev experiment log by default; an explicit path only for tests."""
    if log_path is None:
        je._log(record)
    else:
        qp._append_jsonl(log_path, record)


def run(gc_city: str | None = None, dry_run: bool = False, limit: int = DEFAULT_LIMIT, since_days: float = DEFAULT_SINCE_DAYS,
        ask=call_jev_noul_multi, policy: dict | None = None, stores: list[str] | None = None, now: datetime | None = None,
        log_path=None) -> dict:
    """One pass. Returns counters (also printed by main). Raises PolicyError when the policy is unusable."""
    gc_city = gc_city or gv.DEFAULT_GC_CITY
    policy = policy or load_policy()
    rig_list_error = None
    if stores is None:
        rigs, rig_list_error = rig_store_paths()
        stores = [gc_city] + [p for p in rigs.values() if os.path.realpath(p) != os.path.realpath(gc_city)]
    entities, unreadable = discover(stores, since_days, now=now)
    if rig_list_error:
        unreadable.append("rig-list")  # the other rigs' stores were never even attempted: partial coverage, said so
    done = load_done(log_path or je.JEV_LOG)
    todo = [e for e in entities if e["entity_id"] not in done]
    counts: dict = {"entities": len(entities), "new": len(todo), "processed": 0, "logged": 0, "jev_failed": 0,
                    "circuit_break": False, "unreadable_stores": unreadable, "rig_list_error": rig_list_error,
                    "statuses": defaultdict(int), "would_cut": 0, "tokens_estimados_poupados": 0}
    consecutive_fails = 0
    for ent in todo:
        if counts["processed"] >= limit:
            break
        counts["processed"] += 1
        status, detail = process_entity(ent, policy, ask=ask)
        counts["statuses"][status] += 1
        if status != "logged":
            continue
        if not dry_run:
            _write(detail, log_path)
        counts["logged"] += 1
        counts["statuses"]["jev_" + detail["jev_status"]] += 1
        counts["would_cut"] += 1 if detail["cortadas"] else 0
        counts["tokens_estimados_poupados"] += detail["tokens_estimados_poupados"]
        # The streak counts consecutive Jev CALLS. Only an answered call clears it and only a failed one extends it;
        # "nao_chamado_injecao" made no call, so it says nothing about Jev and leaves the streak as it was.
        if detail["jev_status"] == "ok":
            consecutive_fails = 0
        elif detail["jev_status"] in ("falhou", "parcial"):
            counts["jev_failed"] += 1
            consecutive_fails += 1
            if consecutive_fails >= CIRCUIT_BREAK_FAILS:
                counts["circuit_break"] = True
                break
    counts["statuses"] = dict(counts["statuses"])
    return counts


def explain(store: str, bead_id: str) -> dict:
    """What the policy says about one bead, without asking Jev or writing anything."""
    policy = load_policy()
    bead = gv._bd_show(store, bead_id)
    if bead is None:
        return {"bead": bead_id, "error": f"not readable in {store}"}
    role = pool_role((bead.get("metadata") or {}).get("gc.routed_to"))
    return {
        "bead": bead_id,
        "routed_to": (bead.get("metadata") or {}).get("gc.routed_to"),
        "pool": role,
        "picked_up": picked_up(bead),
        "eligible": policy["eligible"].get(role, []) if role else [],
        "piso_estrutural": structural_floors(bead, policy["pt"]),
        "injecao_suspeita": injection_marker(bead, policy["pt"]),
        "arm": je.assign_arm(bead_id, policy["pt"]["experiment"]),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--gc-city", default=None)
    r.add_argument("--dry-run", action="store_true")
    r.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    r.add_argument("--since-days", type=float, default=DEFAULT_SINCE_DAYS)
    e = sub.add_parser("explain")
    e.add_argument("--store", required=True)
    e.add_argument("--bead", required=True)
    args = ap.parse_args()

    try:
        if args.cmd == "explain":
            print(json.dumps(explain(args.store, args.bead), ensure_ascii=False, indent=2))
            return 0
        if os.environ.get("JEV_PREAMBULO_ENABLED", "1") == "0" or DISABLED_PATH.exists():
            print("jev_preambulo: disabled (JEV_PREAMBULO_ENABLED=0 or the .disabled file) — nothing done")
            return 0
        fd = qp.acquire_lock(LOCK_PATH)
        if fd is None:
            print("jev_preambulo: another run holds the lock — nothing done")
            return 0
        t0 = time.time()
        counts = run(gc_city=args.gc_city, dry_run=args.dry_run, limit=args.limit, since_days=args.since_days)
    except PolicyError as e:
        print(f"jev_preambulo: POLICY UNUSABLE — nothing done: {e}", file=sys.stderr)
        return 2
    counts["seconds"] = round(time.time() - t0, 1)
    counts["dry_run"] = args.dry_run
    print(json.dumps(counts, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
