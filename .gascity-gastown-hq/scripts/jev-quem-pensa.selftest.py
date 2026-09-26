#!/usr/bin/env python3
"""Selftest for jev_quem_pensa_experiment.py + jev_quem_pensa_report.py (ga-aijm2v.9).

Hermetic: no network, no real bd/gc/git/Jev. Every external call goes through the ONE seam the
experiment already uses (jev_gate_verdict_experiment._run), which a fake "world" answers; Jev
is either an injected `ask` function or a mocked urlopen. State (logs, skips, lock) lives in a
temp dir. Run: python3 jev-quem-pensa.selftest.py   (or jev-quem-pensa.selftest.sh)

What is pinned here, and why each is worth a test (all were real failure modes, not theory):
  - the Choice response parser fails CLOSED on every malformed shape (the noul parser once
    shipped parsing nothing while looking live);
  - a confident answer needs BOTH the probability and Jev's own confidence, and Opus can never
    be chosen for a new task;
  - the attempt number counts the bead's WHOLE gate history, not the report window;
  - the state Jev sees never contains the outcome (notes / labels / comments);
  - the run is READ-ONLY (no bd mutation, ever) and the model actually used never changes;
  - Jev down = nao_sei + sonnet, retried a bounded number of times, and a circuit breaker so an
    outage cannot turn a backlog into permanent nao_sei rows;
  - definitive skips are remembered (no poll re-pays them), transient ones are not;
  - the generic Jev report never counts a quem-pensa record as a suppression alert.
"""
from __future__ import annotations

import http.client
import io
import json
import os
import sys
import tempfile
import urllib.error
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import jev_experiment as je  # noqa: E402
import jev_experiment_report as jr  # noqa: E402
import jev_gate_verdict_experiment as gv  # noqa: E402
import jev_quem_pensa_experiment as q  # noqa: E402
import jev_quem_pensa_report as rp  # noqa: E402

PASSED = 0
FAILED = 0


def ok(label: str, cond: bool, detail: str = "") -> None:
    global PASSED, FAILED
    if cond:
        PASSED += 1
        print(f"  ok   {label}")
    else:
        FAILED += 1
        print(f"  FAIL {label}" + (f"  [{detail}]" if detail else ""))


NOW = datetime(2026, 9, 25, 12, 0, 0, tzinfo=timezone.utc)
FAKE_ACCT = "0123456789abcdef0123456789abcdef"

# Verified against the LIVE API 2026-09-25 (probe in the bead's comment): the same double wrapper
# as the noul call, and a choice answer with `probabilities` and `confidence`.
LIVE_SHAPE = {
    "result": {
        "state": "Completed",
        "result": {
            "model": "jev-1.13.0",
            "answers": {
                "dificuldade": {
                    "type": "choice",
                    "choice": "facil",
                    "probabilities": {"facil": 1, "dificil": 0, "media": 0},
                    "confidence": 1,
                }
            },
            "usage": {"input_tokens": 401, "output_tokens": 45},
        },
        "gatewayMetadata": {"keySource": "Unified"},
    },
    "success": True,
    "errors": [],
    "messages": [],
}


def fake_response(body):
    cm = mock.MagicMock()
    cm.read.return_value = body if isinstance(body, bytes) else json.dumps(body).encode()
    cm.__enter__.return_value = cm
    cm.__exit__.return_value = False
    return cm


def answer_json(choice, probs, confidence, key="dificuldade", tokens=(10, 2)):
    return {"result": {"result": {"answers": {key: {"type": "choice", "choice": choice, "probabilities": probs,
                                                    "confidence": confidence}},
                                   "usage": {"input_tokens": tokens[0], "output_tokens": tokens[1]}}}}


def good(choice, prob, conf, options):
    """A validated answer as call_jev_choice returns it, without going through HTTP."""
    others = [k for k in options if k != choice]
    probs = {choice: prob, **{k: round((1 - prob) / max(len(others), 1), 4) for k in others}}
    return {"ok": True, "choice": choice, "prob": prob, "confidence": conf, "probabilities": probs,
            "tokens_in": 10, "tokens_out": 2}


# ── the fake world behind gv._run ───────────────────────────────────────────────────
class World:
    """Answers the exact argv shapes the experiment issues. Every call is recorded so a test can
    assert what was (and was NOT) asked — in particular that nothing ever mutates."""

    def __init__(self):
        self.city = "/city"
        self.rigs = {"gascity": "/city", "whatsapp_automation": "/wa"}
        self.beads: dict[tuple[str, str], dict] = {}
        self.comments: dict[str, list | None] = {}
        self.roots = {"/city": "/city", "/wa": "/wa"}
        self.commits: set[str] = set()
        self.stat: dict[tuple[str, str], str] = {}
        self.calls: list[list[str]] = []
        self.rig_list_ok = True

    def add_gate_run(self, gate_run, author, branch_sha="HEAD1", fail_comment=None):
        self.beads[("/city", gate_run)] = {"id": gate_run, "description": f"author: {author}\nbranch_sha: {branch_sha}\nmarker_id: m-{gate_run}"}
        if fail_comment is not None:
            self.comments[gate_run] = [{"text": "some earlier note"}, {"text": fail_comment}]
        self.beads[("/city", f"m-{gate_run}")] = {"id": f"m-{gate_run}", "description": "base_commit: BASE1"}
        self.commits.update({"BASE1", branch_sha})
        self.stat[("BASE1", branch_sha)] = " a.py | 4 ++--\n 1 file changed, 2 insertions(+), 2 deletions(-)"

    def add_bead(self, store, bead_id, **fields):
        self.beads[(store, bead_id)] = {"id": bead_id, "title": fields.pop("title", f"title {bead_id}"), **fields}

    def run(self, cmd, timeout=None):
        self.calls.append(list(cmd))
        out = lambda rc, text="": SimpleNamespace(returncode=rc, stdout=text, stderr="")  # noqa: E731
        if cmd[0] == "bd" and cmd[1] == "-C":
            store, verb, bead_id = cmd[2], cmd[3], cmd[4]
            if verb == "show":
                b = self.beads.get((store, bead_id))
                return out(1) if b is None else out(0, json.dumps([b]))
            if verb == "comments":
                c = self.comments.get(bead_id)
                return out(1) if c is None else out(0, json.dumps(c))
            return out(2)
        if cmd[:3] == ["gc", "rig", "list"]:
            if not self.rig_list_ok:
                return out(1)
            return out(0, json.dumps({"rigs": [{"name": n, "path": p} for n, p in self.rigs.items()]}))
        if cmd[0] == "git":
            root, sub = cmd[2], cmd[3:]
            if sub[:2] == ["rev-parse", "--show-toplevel"]:
                r = self.roots.get(root)
                return out(1) if r is None else out(0, r + "\n")
            if sub[0] == "cat-file":
                sha = sub[2].split("^")[0]
                return out(0 if sha in self.commits else 1)
            if sub[0] == "fetch":
                return out(0)
            if sub[0] == "diff" and sub[1] == "--stat":
                base, head = sub[2].split("...")
                s = self.stat.get((base, head))
                return out(1) if s is None else out(0, s + "\n")
        return out(127)

    def mutating_calls(self):
        """Anything that is not a plain read. bd show/comments, gc rig list, git rev-parse/cat-file/
        fetch/diff are reads (fetch only refreshes refs). Everything else is a mutation."""
        bad = []
        for c in self.calls:
            if c[0] == "bd" and c[3] in ("show", "comments"):
                continue
            if c[:3] == ["gc", "rig", "list"]:
                continue
            if c[0] == "git" and c[3] in ("rev-parse", "cat-file", "fetch", "diff"):
                continue
            bad.append(c)
        return bad


def ev(ts, bead, result, gate_run, branch, rig="whatsapp_automation", **extra):
    e = {"ts": ts, "event": "dispatcher_complete", "branch": branch, "bead": bead, "rig": rig, "tier": "CODE",
         "result": result, "reason": "x", "gate_run": gate_run, "marker": f"m-{gate_run}", "elapsed_s": 60,
         "reviewers": 1, "dry_run": "0"}
    e.update(extra)
    return e


def write_log(path, events, junk=True):
    with open(path, "w", encoding="utf-8") as f:
        if junk:
            f.write("not json at all\n\n")
            f.write(json.dumps({"ts": "2026-09-25T00:00:00Z", "event": "guard_queued", "bead": "zz", "gate_run": "zz"}) + "\n")
            f.write(json.dumps([1, 2, 3]) + "\n")
        for e in events:
            f.write(json.dumps(e) + "\n")


def read_log(path):
    return q._read_jsonl(path)


class patched:
    """Swap module globals for one block, always restoring."""

    def __init__(self, world=None, tmp=None):
        self.world, self.tmp = world, tmp
        self.saved = {}

    def __enter__(self):
        self.saved = {"run": gv._run, "jev_log": je.JEV_LOG, "skips": q.SKIPS_PATH, "lock": q.LOCK_PATH,
                      "disabled": q.DISABLED_PATH, "jr_log": jr.JEV_LOG}
        if self.world:
            gv._run = self.world.run
        if self.tmp:
            je.JEV_LOG = Path(self.tmp) / "jev.jsonl"
            jr.JEV_LOG = je.JEV_LOG
            q.SKIPS_PATH = Path(self.tmp) / "skips.jsonl"
            q.LOCK_PATH = Path(self.tmp) / "x.lock"
            q.DISABLED_PATH = Path(self.tmp) / "x.disabled"
        return self

    def __exit__(self, *a):
        gv._run = self.saved["run"]
        je.JEV_LOG, q.SKIPS_PATH, q.LOCK_PATH = self.saved["jev_log"], self.saved["skips"], self.saved["lock"]
        q.DISABLED_PATH, jr.JEV_LOG = self.saved["disabled"], self.saved["jr_log"]


def section(title):
    print(f"\n{title}")


# ── A. the Choice call ──────────────────────────────────────────────────────────────
def test_call_choice():
    section("A. call_jev_choice: parse, validate, fail closed")
    creds = mock.patch.object(je, "_credentials", return_value=(FAKE_ACCT, "tok", False))
    creds.start()
    try:
        seen = {}

        def capture(req, timeout=None):
            seen["url"], seen["auth"], seen["body"] = req.full_url, req.get_header("Authorization"), json.loads(req.data)
            return fake_response(LIVE_SHAPE)

        with mock.patch("urllib.request.urlopen", side_effect=capture):
            r = q.call_jev_choice("state", "dificuldade", "instr", q.NOVA_OPTIONS)
        ok("live (double-wrapped) shape parses to choice/prob/confidence/probabilities/tokens",
           r == {"ok": True, "choice": "facil", "prob": 1.0, "confidence": 1.0,
                 "probabilities": {"facil": 1.0, "dificil": 0.0, "media": 0.0}, "tokens_in": 401, "tokens_out": 45}, str(r))
        qn = seen["body"]["input"]["questions"]["dificuldade"]
        ok("the request asks a typed CHOICE question with the option keys as criteria",
           qn["type"] == "choice" and set(qn["criteria"]) == {"facil", "media", "dificil"} and qn["instructions"] == "instr")
        ok("request goes to the account URL with the bearer token and the Jev model",
           seen["url"] == f"https://api.cloudflare.com/client/v4/accounts/{FAKE_ACCT}/ai/run" and seen["auth"] == "Bearer tok"
           and seen["body"]["model"] == je.JEV_MODEL)

        flat = {"result": {"answers": LIVE_SHAPE["result"]["result"]["answers"], "usage": {"input_tokens": 3, "output_tokens": 1}}}
        with mock.patch("urllib.request.urlopen", return_value=fake_response(flat)):
            r = q.call_jev_choice("s", "dificuldade", "i", q.NOVA_OPTIONS)
        ok("single-wrapped shape still parses", r["ok"] is True and r["tokens_in"] == 3)

        def call(body):
            # "never raises" is the contract under test: a raise is reported as an ordinary failed
            # check (ok="RAISED"), not allowed to abort the rest of the suite with a traceback.
            with mock.patch("urllib.request.urlopen", return_value=fake_response(body)):
                try:
                    return q.call_jev_choice("s", "dificuldade", "i", q.NOVA_OPTIONS)
                except Exception as e:  # noqa: BLE001
                    return {"ok": "RAISED", "error": f"raised {type(e).__name__}: {e}"}

        for label, body in [
            ("a bare list", []), ("null", None), ("a string", "hello"), ("a number", 7),
            ("no answers at any level", {"result": {"nope": True}}),
        ]:
            r = call(body)
            ok(f"garbage ({label}) fails closed without raising", r["ok"] is False and r["error"] == "unparseable_response_shape", str(r))
        r = call(answer_json("nao_existe", {"nao_existe": 0.9, "facil": 0.1}, 0.9))
        ok("a choice that is not one of the options is refused", r["ok"] is False and r["error"].startswith("choice_not_in_options"), str(r))
        r = call(answer_json("facil", {"media": 0.5, "dificil": 0.5}, 0.9))
        ok("a chosen option with no probability is refused", r["ok"] is False and r["error"].startswith("chosen_option_without_probability"), str(r))
        r = call(answer_json("facil", {"facil": 1.4, "media": 0, "dificil": 0}, 0.9))
        ok("a probability above 1 is refused", r["ok"] is False and r["error"] == "probability_out_of_range", str(r))
        r = call(answer_json("facil", {"facil": 0.9, "media": 0.1, "dificil": 0}, 1.7))
        ok("a confidence above 1 is refused", r["ok"] is False and r["error"] == "probability_out_of_range", str(r))
        r = call(answer_json("facil", {"facil": 0.9, "media": 0.1, "dificil": 0}, None))
        ok("a missing/None confidence is refused, not read as 0", r["ok"] is False and r["error"].startswith("unparseable_answer"), str(r))
        r = call(answer_json("facil", "not-a-dict", 0.9))
        ok("probabilities that are not a mapping are refused, not a crash", r["ok"] is False and r["error"].startswith("unparseable_answer"), str(r))
        raw_inf = (b'{"result":{"result":{"answers":{"dificuldade":{"type":"choice","choice":"facil",'
                   b'"probabilities":{"facil":1,"media":0,"dificil":0},"confidence":1}},'
                   b'"usage":{"input_tokens":Infinity,"output_tokens":0}}}}')
        r = call(raw_inf)
        ok("a non-finite token count (JSON `Infinity`; int(inf) is an OverflowError, not a ValueError) fails closed, never raises",
           r["ok"] is False and r["error"].startswith("unparseable_answer"), str(r))
        raw_big = raw_inf.replace(b"Infinity", b"1e999")
        r = call(raw_big)
        ok("an absurd token count (1e999) fails closed too", r["ok"] is False and r["error"].startswith("unparseable_answer"), str(r))
        raw_nan = (b'{"result":{"result":{"answers":{"dificuldade":{"type":"choice","choice":"facil",'
                   b'"probabilities":{"facil":NaN,"media":0,"dificil":0},"confidence":1}},"usage":{}}}}')
        r = call(raw_nan)
        ok("a NaN probability is refused (NaN compares False to everything, so it must not slip through a range check)",
           r["ok"] is False and r["error"] == "probability_out_of_range", str(r))
        body = answer_json("facil", {"facil": 0.9, "media": 0.1, "dificil": 0}, 0.9)
        del body["result"]["result"]["usage"]
        r = call(body)
        ok("missing usage is tolerated as zero tokens (the answer is still valid)", r["ok"] is True and r["tokens_in"] == 0)

        for label, exc, expect in [
            ("HTTP 429", urllib.error.HTTPError("u", 429, "rate", {}, None), "http_429"),
            ("URLError", urllib.error.URLError("dns"), "network"),
            ("timeout", TimeoutError("slow"), "network"),
            ("connection reset", ConnectionResetError("reset"), "network"),
            ("http.client error", http.client.IncompleteRead(b"x"), "network"),
        ]:
            with mock.patch("urllib.request.urlopen", side_effect=exc):
                r = q.call_jev_choice("s", "dificuldade", "i", q.NOVA_OPTIONS)
            ok(f"{label} -> ok=False ({expect}), never raises", r["ok"] is False and r["error"].startswith(expect), str(r))
        r = call(b"{not json")
        ok("an invalid JSON body -> bad_json", r["ok"] is False and r["error"].startswith("bad_json"), str(r))
        r = call(b"\xff\xfe\x00")
        ok("a non-UTF-8 body -> bad_json (UnicodeDecodeError is a ValueError, not a crash)", r["ok"] is False and r["error"].startswith("bad_json"), str(r))
    finally:
        creds.stop()

    with mock.patch.object(je, "_credentials", return_value=("", "", False)), \
         mock.patch("urllib.request.urlopen", side_effect=AssertionError("network without credentials")):
        r = q.call_jev_choice("s", "k", "i", q.NOVA_OPTIONS)
    ok("no credentials -> no_credentials, and no network call", r == {"ok": False, "error": "no_credentials"})
    with mock.patch.object(je, "_credentials", return_value=("", "", True)), \
         mock.patch("urllib.request.urlopen", side_effect=AssertionError("network without credentials")):
        r = q.call_jev_choice("s", "k", "i", q.NOVA_OPTIONS)
    ok("vault unreadable -> vault_unavailable (not 'no credentials')", r == {"ok": False, "error": "vault_unavailable"})
    with mock.patch.object(je, "_credentials", return_value=("Workers AI token for", "tok", False)), \
         mock.patch("urllib.request.urlopen", side_effect=AssertionError("malformed account id reached the network")):
        r = q.call_jev_choice("s", "k", "i", q.NOVA_OPTIONS)
    ok("a malformed account id is refused before it is spliced into a URL", r == {"ok": False, "error": "bad_account_id"})


# ── B/C. decisions and the pool filter ──────────────────────────────────────────────
def test_decide_and_pool():
    section("B. decide(): sonnet unless Jev is confident about the ONE case that earns another model")
    N, C = q.EXP_NOVA, q.EXP_CONSERTO
    ok("new task: facil, P and confidence both high -> haiku", q.decide(N, good("facil", 0.97, 0.95, q.NOVA_OPTIONS)) == ("facil", "haiku"))
    ok("new task: facil but Jev's own confidence low -> sonnet (the stricter number wins)",
       q.decide(N, good("facil", 0.97, 0.70, q.NOVA_OPTIONS)) == ("facil", "sonnet"))
    ok("new task: facil but probability low, confidence high -> sonnet", q.decide(N, good("facil", 0.80, 0.95, q.NOVA_OPTIONS)) == ("facil", "sonnet"))
    ok("new task: exactly at the threshold counts as confident (>=)", q.decide(N, good("facil", 0.85, 0.85, q.NOVA_OPTIONS)) == ("facil", "haiku"))
    ok("new task: just under the threshold does not", q.decide(N, good("facil", 0.8499, 0.85, q.NOVA_OPTIONS)) == ("facil", "sonnet"))
    ok("new task: NEVER opus, even when dificil with certainty (Athos: Opus only on repairs)",
       q.decide(N, good("dificil", 0.99, 0.99, q.NOVA_OPTIONS)) == ("dificil", "sonnet"))
    ok("new task: media -> sonnet", q.decide(N, good("media", 0.99, 0.99, q.NOVA_OPTIONS)) == ("media", "sonnet"))
    ok("repair: raciocinio, P and confidence high -> opus", q.decide(C, good("raciocinio", 0.99, 0.98, q.CONSERTO_OPTIONS)) == ("raciocinio", "opus"))
    ok("repair: raciocinio but confidence low -> sonnet", q.decide(C, good("raciocinio", 0.99, 0.50, q.CONSERTO_OPTIONS)) == ("raciocinio", "sonnet"))
    ok("repair: NEVER haiku (mecanico confident -> still sonnet)", q.decide(C, good("mecanico", 0.99, 0.99, q.CONSERTO_OPTIONS)) == ("mecanico", "sonnet"))
    for exp in (N, C):
        ok(f"{exp}: Jev failed -> nao_sei + sonnet", q.decide(exp, {"ok": False, "error": "http_500"}) == ("nao_sei", "sonnet"))
        ok(f"{exp}: no answer at all -> nao_sei + sonnet", q.decide(exp, None) == ("nao_sei", "sonnet"))
    ok("phase 1 default model is sonnet", q.MODELO_PADRAO == "sonnet")

    section("C. classify_pool: who counts as a pool builder")
    ok("crew/wa-worker/<bead> -> wa-worker", q.classify_pool("crew/wa-worker/wa-1", None) == "wa-worker")
    ok("crew/ps-worker/<bead> -> ps-worker", q.classify_pool("crew/ps-worker/ps-1", None) == "ps-worker")
    ok("a wa-worker branch is pool EVEN when the gate-run author says mayor (measured 25/09)",
       q.classify_pool("crew/wa-worker/wa-1", "mayor") == "wa-worker")
    ok("author gastown.dog-5 -> dog", q.classify_pool("fix/ga-1", "gastown.dog-5") == "dog")
    ok("author dog-gancyeu0 (bare session name) -> dog", q.classify_pool("fix/ga-1", "dog-gancyeu0") == "dog")
    for who in ("mayor", "gastown.mayor", "batista-wa", "oracle-wa", "thies-wa", "dogfood-1", "gastown.dog", "xdog-1", "", None):
        ok(f"author {who!r} on a fix/ branch is NOT pool", q.classify_pool("fix/ga-1", who) is None)
    ok("a named-crew branch is not pool", q.classify_pool("crew/batista/wa-1", "batista-wa") is None)
    ok("crew/wa-worker-2/x is not the wa-worker pool prefix (no accidental prefix match)", q.classify_pool("crew/wa-worker-2/x", None) is None)
    ok("no signal at all -> None (never guessed)", q.classify_pool(None, None) is None)


# ── D. reviews and entities ─────────────────────────────────────────────────────────
def test_entities(tmp):
    section("D. load_reviews / collect_entities")
    qg = os.path.join(tmp, "qg.jsonl")
    W = "crew/wa-worker/"
    events = [
        ev("2026-09-25T01:00:00Z", "b1", "PASS", "g1", W + "b1"),
        ev("2026-09-25T02:00:00Z", "b2", "FAIL", "g2a", W + "b2"),
        ev("2026-09-25T03:00:00Z", "b2", "FAIL", "g2b", W + "b2"),
        ev("2026-09-25T04:00:00Z", "b2", "PASS", "g2c", W + "b2"),
        ev("2026-09-25T05:00:00Z", "b3", "FAIL", "g3", W + "b3"),
        ev("2026-09-25T06:00:00Z", "b4", "PASS", "g4a", W + "b4"),
        ev("2026-09-25T07:00:00Z", "b4", "FAIL", "g4b", W + "b4"),
        ev("2026-09-25T08:00:00Z", "b4", "PASS", "g4c", W + "b4"),
        ev("2026-09-25T09:00:00Z", "b5", "PASS", "g5", W + "b5", dry_run="1"),
        ev("2026-09-25T02:00:00Z", "b2", "FAIL", "g2a", W + "b2"),  # duplicate gate_run
        ev("2026-09-10T01:00:00Z", "b6", "FAIL", "g6a", W + "b6"),  # first review is OLD
        ev("2026-09-25T10:00:00Z", "b6", "PASS", "g6b", W + "b6"),  # repair is recent
        {**ev("2026-09-25T11:00:00Z", "b7", "PASS", "g7", W + "b7"), "event": "guard_queued"},  # not terminal
        {**ev("2026-09-25T11:00:00Z", "b8", "PASS", "g8", W + "b8"), "result": "REQUEUED"},  # not PASS/FAIL
    ]
    write_log(qg, events)
    revs = q.load_reviews(qg)
    ok("beads with real reviews are loaded; dry_run, non-terminal and non-verdict events are not",
       set(revs) == {"b1", "b2", "b3", "b4", "b6"}, str(sorted(revs)))
    ok("a duplicated gate_run counts once", [r["gate_run"] for r in revs["b2"]] == ["g2a", "g2b", "g2c"])
    ents = q.collect_entities(revs, since_days=2, now=NOW)
    ids = [e["entity_id"] for e in ents]
    ok("entities: review 1 of each bead is nova; each review after a FAIL is a conserto",
       set(ids) == {"b1", "b2", "b2#2", "b2#3", "b3", "b4", "b4#3", "b6#2"}, str(ids))
    ok("a FAIL still waiting for its next review is not an entity (b3 has no b3#2)", "b3#2" not in ids)
    ok("a review that follows a PASS is not a repair (b4#2 absent) but the repair after a later FAIL is (b4#3)",
       "b4#2" not in ids and "b4#3" in ids)
    ok("the WHOLE history numbers the attempt: b6's recent review is attempt 2 although its first review is outside the window",
       next(e for e in ents if e["entity_id"] == "b6#2")["attempt"] == 2 and "b6" not in ids)
    ok("oldest outcome first", [e["review"]["ts"] for e in ents] == sorted(e["review"]["ts"] for e in ents))
    e2 = next(e for e in ents if e["entity_id"] == "b2#3")
    ok("entity carries attempt, the FAIL that preceded it, the review count and approval so far",
       e2["experiment"] == q.EXP_CONSERTO and e2["attempt"] == 3 and e2["prior"]["gate_run"] == "g2b"
       and e2["reviews_so_far"] == 3 and e2["approved_so_far"] is True and e2["review"]["gate_run"] == "g2c")
    e3 = next(e for e in ents if e["entity_id"] == "b3")
    ok("a bead with only a FAIL: nova, not approved yet", e3["experiment"] == q.EXP_NOVA and e3["approved_so_far"] is False and e3["prior"] is None)
    ok("a review with a missing/garbled ts is never an entity (excluded, not guessed)",
       q.collect_entities({"x": [{"result": "PASS", "gate_run": "gx", "ts": "garbage"}]}, 2, now=NOW) == [])
    ok("a missing log yields no reviews, not an error", q.load_reviews(os.path.join(tmp, "nope.jsonl")) == {})


# ── E. the state Jev sees ───────────────────────────────────────────────────────────
def test_states():
    section("E. state text: the task/rejection only, never the outcome")
    bead = {"title": "Fix the thing", "issue_type": "bug", "description": "Body text.", "acceptance_criteria": "- it works",
            "notes": "Gate FAILED. secret outcome NOTES-LEAK", "labels": ["gate:needs-fix", "LABEL-LEAK"],
            "comments": [{"text": "COMMENT-LEAK"}], "priority": 0}
    s = q.build_state_nova(bead)
    ok("the new-task state has title, type, description and acceptance criteria",
       "TITLE: Fix the thing" in s and "TYPE: bug" in s and "Body text." in s and "- it works" in s)
    ok("notes, labels and comments never reach Jev (that is where the outcome accumulates)",
       not any(x in s for x in ("NOTES-LEAK", "LABEL-LEAK", "COMMENT-LEAK", "needs-fix", "Gate FAILED")))
    ok("priority is not part of the task text", "priority" not in s.lower() and "P0" not in s)
    big = q.build_state_nova({"title": "t", "description": "x" * 20000})
    ok("a huge description is capped and says how much was cut", len(big) < 7000 and "truncated" in big and "more chars" in big)
    ok("no acceptance criteria -> the section is simply absent", "ACCEPTANCE" not in q.build_state_nova({"title": "t", "description": "d"}))
    ok("a bead with no description still yields a state (title only), not a crash", "TITLE: t" in q.build_state_nova({"title": "t"}))
    c = q.build_state_conserto(3, "Gate FAILED.\nBlocking issue 1: X", " a.py | 2 +-")
    ok("the repair state has the attempt, the reviewer's reason and the diff stat",
       "ATTEMPT: 3" in c and "Blocking issue 1: X" in c and " a.py | 2 +-" in c and "attempt 2 of this task was rejected" in c)

    comments = [{"text": "just a note"}, {"text": "Gate FAILED.\nfirst"}, {"text": "  Gate FAILED.\nsecond"}, {"text": ""}]
    ok("fail_reason: the LAST 'Gate FAILED' comment wins", q.fail_reason(comments) == "  Gate FAILED.\nsecond")
    ok("fail_reason: none present -> None (cannot build the state), not ''", q.fail_reason([{"text": "note"}, {}]) is None)
    ok("fail_reason: an empty list -> None", q.fail_reason([]) is None)


# ── F. one entity ───────────────────────────────────────────────────────────────────
def one_entity(events, eid, tmp, now=NOW):
    qg = os.path.join(tmp, "qg1.jsonl")
    write_log(qg, events, junk=False)
    ents = q.collect_entities(q.load_reviews(qg), 30, now=now)
    return next(e for e in ents if e["entity_id"] == eid)


class Spy:
    def __init__(self, answer):
        self.answer, self.states, self.keys = answer, [], []

    def __call__(self, state, key, instructions, options):
        self.states.append(state)
        self.keys.append((key, tuple(options)))
        return self.answer(state) if callable(self.answer) else self.answer


def test_process_entity(tmp):
    section("F. process_entity")
    W = "crew/wa-worker/"

    # F1 nova, wa-worker pool, bead read from the RIG store
    w = World()
    w.add_bead("/wa", "wa-1", title="Nova tarefa", description="Fazer X.", acceptance_criteria="- X feito", notes="Gate FAILED NOTES")
    ent = one_entity([ev("2026-09-25T01:00:00Z", "wa-1", "FAIL", "gr1", W + "wa-1")], "wa-1", tmp)
    spy = Spy(good("dificil", 0.9, 0.8, q.NOVA_OPTIONS))
    with patched(w):
        status, rec = q.process_entity(ent, "/city", {"rig_paths": None}, ask=spy)
    ok("nova: logged", status == "logged", str(status))
    ok("nova: the wa- bead was read from the WHATSAPP store, not the HQ one", ["bd", "-C", "/wa", "show", "wa-1", "--json"] in w.calls
       and ["bd", "-C", "/city", "show", "wa-1", "--json"] not in w.calls)
    ok("nova: no gate-run bead is read when the branch already says pool (no wasted call)",
       not any(c[:5] == ["bd", "-C", "/city", "show", "gr1"] for c in w.calls))
    ok("nova: Jev asked exactly once, with the difficulty question and the task text",
       len(spy.states) == 1 and spy.keys[0] == (q.NOVA_KEY, tuple(q.NOVA_OPTIONS)) and "Nova tarefa" in spy.states[0] and "Fazer X." in spy.states[0])
    ok("nova: the outcome never reached Jev", "NOTES" not in spy.states[0] and "FAIL" not in spy.states[0])
    ok("nova: the record has the Jev choice, both confidences and the real gate outcome",
       rec["mode"] == q.MODE and rec["experiment"] == q.EXP_NOVA and rec["entity_id"] == "wa-1" and rec["pool"] == "wa-worker"
       and rec["escolha_jev"] == "dificil" and rec["prob_escolha"] == 0.9 and rec["confianca_jev"] == 0.8
       and rec["desfecho_veredito"] == "FAIL" and rec["desfecho_gate_run"] == "gr1" and rec["attempt"] == 1
       and rec["tentativas_ate_agora"] == 1 and rec["aprovada_ate_agora"] is False and rec["jev_ok"] is True
       and rec["jev_tokens_in"] == 10 and rec["limiar"] == 0.85, json.dumps(rec)[:300])
    ok("nova: no diffstat field on a new task", "diffstat_ok" not in rec)

    # F2 dog author on a gascity-rig bead: needs the gate-run bead for the author
    w = World()
    w.add_bead("/city", "ga-1", title="Infra", description="d")
    w.add_gate_run("gr2", "gastown.dog-3")
    ent = one_entity([ev("2026-09-25T01:00:00Z", "ga-1", "PASS", "gr2", "fix/ga-1", rig="gascity")], "ga-1", tmp)
    with patched(w):
        status, rec = q.process_entity(ent, "/city", {"rig_paths": None}, ask=Spy(good("media", 0.7, 0.6, q.NOVA_OPTIONS)))
    ok("dog: classified by the gate-run author, read from the HQ store", status == "logged" and rec["pool"] == "dog"
       and ["bd", "-C", "/city", "show", "ga-1", "--json"] in w.calls, str(status))

    # F3/F4 not pool: definitive, Jev never asked
    for who, branch, label in [("batista-wa", "crew/batista/wa-2", "named crew"), ("mayor", "fix/ga-2", "the Mayor"), ("gastown.mayor", "feat/x", "gastown.mayor")]:
        w = World()
        w.add_bead("/wa", "wa-2", title="t")
        w.add_gate_run("gr3", who)
        ent = one_entity([ev("2026-09-25T01:00:00Z", "wa-2", "PASS", "gr3", branch)], "wa-2", tmp)
        spy = Spy(good("facil", 0.99, 0.99, q.NOVA_OPTIONS))
        with patched(w):
            status, detail = q.process_entity(ent, "/city", {"rig_paths": None}, ask=spy)
        ok(f"{label}: definitive skip, Jev never asked", status == "skip_definitive_not_pool" and not spy.states, str(status))
        ok(f"{label}: no rig list / bead read was paid for it", not any(c[:3] == ["gc", "rig", "list"] for c in w.calls)
           and not any(c[3] == "show" and c[4] == "wa-2" for c in w.calls if c[0] == "bd"))

    # F5 gate-run unreadable and the branch is not a pool branch: TRANSIENT (unknown != not-pool)
    w = World()
    ent = one_entity([ev("2026-09-25T01:00:00Z", "ga-3", "PASS", "gr4", "fix/ga-3", rig="gascity")], "ga-3", tmp)
    spy = Spy(good("facil", 0.99, 0.99, q.NOVA_OPTIONS))
    with patched(w):
        status, detail = q.process_entity(ent, "/city", {"rig_paths": None}, ask=spy)
    ok("unreadable gate-run: a TRANSIENT skip (cannot tell 'not pool' from 'could not read'), so it is retried, and Jev is not asked",
       status == "skip_gate_run_unreadable" and not status.startswith("skip_definitive") and not spy.states, str(status))

    # F5b a gate-run with NO author line says nothing about who built it: transient, never "not pool"
    w = World()
    w.beads[("/city", "gr-noauth")] = {"id": "gr-noauth", "description": "branch_sha: X\nmarker_id: m"}
    ent = one_entity([ev("2026-09-25T01:00:00Z", "ga-30", "PASS", "gr-noauth", "fix/ga-30", rig="gascity")], "ga-30", tmp)
    spy = Spy(good("facil", 0.99, 0.99, q.NOVA_OPTIONS))
    with patched(w):
        status, detail = q.process_entity(ent, "/city", {"rig_paths": None}, ask=spy)
    ok("gate-run readable but with no `author:` -> TRANSIENT skip (unknown is not 'not pool'), never remembered, Jev not asked",
       status == "skip_gate_run_no_author" and not status.startswith("skip_definitive") and not spy.states, status)

    # F6 the bead's own store is decided by its id prefix, not by the gate event's rig
    ent = one_entity([ev("2026-09-25T01:00:00Z", "wa-4", "PASS", "gr5", W + "wa-4")], "wa-4", tmp)
    w = World()
    w.rigs = {}
    with patched(w):
        status, _ = q.process_entity(ent, "/city", {"rig_paths": None}, ask=Spy(good("facil", 1, 1, q.NOVA_OPTIONS)))
    ok("bead in no readable store -> transient skip_bead_unreadable", status == "skip_bead_unreadable", status)
    w = World()
    with patched(w):
        status, detail = q.process_entity(ent, "/city", {"rig_paths": None}, ask=Spy(good("facil", 1, 1, q.NOVA_OPTIONS)))
    ok("...and the reason lists every store that was tried", status == "skip_bead_unreadable" and "/wa" in detail and "/city" in detail, detail)

    # cross-rig: measured ~6% of gate reviews (229 ga- beads gated in whatsapp_automation, 33 wa- in gascity ...)
    w = World()
    w.add_bead("/city", "ga-20", title="an HQ bead delivered in the whatsapp repo", description="d")
    ent = one_entity([ev("2026-09-25T01:00:00Z", "ga-20", "PASS", "gr20", W + "ga-20", rig="whatsapp_automation")], "ga-20", tmp)
    spy = Spy(good("media", 0.7, 0.7, q.NOVA_OPTIONS))
    with patched(w):
        status, rec = q.process_entity(ent, "/city", {"rig_paths": None}, ask=spy)
    ok("cross-rig: a ga- bead gated in whatsapp_automation is found in the HQ store (not silently dropped)",
       status == "logged" and "an HQ bead" in spy.states[0], status)
    shows = [c[2] for c in w.calls if c[0] == "bd" and c[3] == "show" and c[4] == "ga-20"]
    ok("cross-rig: the event's rig store is tried FIRST, then the HQ store", shows == ["/wa", "/city"], str(shows))
    w = World()
    w.add_bead("/wa", "wa-21", title="a wa bead delivered in the gascity repo", description="d")
    ent = one_entity([ev("2026-09-25T01:00:00Z", "wa-21", "PASS", "gr21", W + "wa-21", rig="gascity")], "wa-21", tmp)
    spy = Spy(good("media", 0.7, 0.7, q.NOVA_OPTIONS))
    with patched(w):
        status, _ = q.process_entity(ent, "/city", {"rig_paths": None}, ask=spy)
    shows = [c[2] for c in w.calls if c[0] == "bd" and c[3] == "show" and c[4] == "wa-21"]
    ok("cross-rig: a wa- bead gated in gascity is found in the wa store after the HQ store misses (each store tried once)",
       status == "logged" and shows == ["/city", "/wa"], f"{status} {shows}")
    w = World()
    w.add_bead("/wa", "wa-22", title="t")
    ent = one_entity([ev("2026-09-25T01:00:00Z", "wa-22", "PASS", "gr22", W + "wa-22")], "wa-22", tmp)
    with patched(w):
        q.process_entity(ent, "/city", {"rig_paths": None}, ask=Spy(good("media", 0.7, 0.7, q.NOVA_OPTIONS)))
    shows = [c for c in w.calls if c[0] == "bd" and c[3] == "show" and c[4] == "wa-22"]
    ok("the common case (bead in the event's rig) costs exactly ONE bd call", len(shows) == 1, str(shows))

    # F7 conserto, full pipeline
    w = World()
    w.add_gate_run("gr-fail", "whatever", branch_sha="HEADX", fail_comment="Gate FAILED.\nBlocking issue 1: comment lies about ALWAYS.")
    w.add_gate_run("gr-fix", "mayor")
    events = [ev("2026-09-25T01:00:00Z", "wa-5", "FAIL", "gr-fail", W + "wa-5"), ev("2026-09-25T05:00:00Z", "wa-5", "PASS", "gr-fix", W + "wa-5")]
    ent = one_entity(events, "wa-5#2", tmp)
    spy = Spy(good("raciocinio", 0.99, 0.98, q.CONSERTO_OPTIONS))
    with patched(w):
        status, rec = q.process_entity(ent, "/city", {"rig_paths": None}, ask=spy)
    ok("conserto: logged, Jev asked the repair question with the reviewer's reason, the attempt and the diff stat",
       status == "logged" and spy.keys[0] == (q.CONSERTO_KEY, tuple(q.CONSERTO_OPTIONS)) and "ALWAYS" in spy.states[0]
       and "ATTEMPT: 2" in spy.states[0] and "a.py | 4" in spy.states[0], str(status))
    ok("conserto: record = attempt 2, entity bead#2, opus candidate, outcome of the repair review (PASS), diffstat_ok",
       rec["experiment"] == q.EXP_CONSERTO and rec["entity_id"] == "wa-5#2" and rec["attempt"] == 2 and rec["modelo_jev"] == "opus"
       and rec["desfecho_veredito"] == "PASS" and rec["desfecho_gate_run"] == "gr-fix" and rec["diffstat_ok"] is True and rec["pool"] == "wa-worker")
    ok("conserto: the repair's OWN review (not the rejected one) is the outcome", rec["desfecho_gate_run"] != "gr-fail")

    # pool of a repair = the builder of the REPAIR, not of the rejected attempt
    w = World()
    w.add_gate_run("g-a", "gastown.dog-2", fail_comment="Gate FAILED.\nx")
    w.add_gate_run("g-b", "batista-wa")
    ent = one_entity([ev("2026-09-25T01:00:00Z", "ga-6", "FAIL", "g-a", "fix/ga-6", rig="gascity"),
                      ev("2026-09-25T05:00:00Z", "ga-6", "PASS", "g-b", "fix/ga-6", rig="gascity")], "ga-6#2", tmp)
    spy = Spy(good("mecanico", 0.9, 0.9, q.CONSERTO_OPTIONS))
    with patched(w):
        status, _ = q.process_entity(ent, "/city", {"rig_paths": None}, ask=spy)
    ok("conserto by a named crew after a dog's FAIL: not a pool decision (the repairer chooses its own model)", status == "skip_definitive_not_pool" and not spy.states, status)

    # F8 diffstat unavailable: still asked, and the record SAYS the stat was missing
    def conserto_world(mutate=None):
        cw = World()
        cw.add_gate_run("gr-fail", "x", fail_comment="Gate FAILED.\nBlocking: y")
        cw.add_gate_run("gr-fix", "x")
        if mutate:
            mutate(cw)
        return cw

    conserto_ent = one_entity([ev("2026-09-25T01:00:00Z", "wa-7", "FAIL", "gr-fail", W + "wa-7"),
                               ev("2026-09-25T05:00:00Z", "wa-7", "PASS", "gr-fix", W + "wa-7")], "wa-7#2", tmp)

    def run_conserto(cw):
        spy_ = Spy(good("mecanico", 0.9, 0.9, q.CONSERTO_OPTIONS))
        with patched(cw):
            st, rc = q.process_entity(conserto_ent, "/city", {"rig_paths": None}, ask=spy_)
        return st, rc, spy_

    status, rec, spy = run_conserto(conserto_world(lambda cw: cw.stat.pop(("BASE1", "HEAD1"))))
    ok("diff stat unavailable: Jev is still asked (the reason is the main input) and the state names the gap",
       status == "logged" and "diff stat unavailable" in spy.states[0], str(status))
    ok("diff stat unavailable: the RECORD says diffstat_ok=False (a reader can tell)", rec["diffstat_ok"] is False)
    status, rec, _ = run_conserto(conserto_world(lambda cw: cw.beads.__setitem__(("/city", "m-gr-fail"), {"id": "m-gr-fail", "description": "no base here"})))
    ok("no base_commit on the marker -> diffstat_ok=False, still logged", status == "logged" and rec["diffstat_ok"] is False)
    status, rec, _ = run_conserto(conserto_world(lambda cw: cw.commits.discard("BASE1")))
    ok("commits pruned from the repo -> diffstat_ok=False, still logged", status == "logged" and rec["diffstat_ok"] is False)
    status, rec, _ = run_conserto(conserto_world(lambda cw: cw.roots.pop("/wa")))
    ok("rig with no resolvable repo root -> diffstat_ok=False, still logged", status == "logged" and rec["diffstat_ok"] is False)

    # F9 no fail reason
    status, _, spy = run_conserto(conserto_world(lambda cw: cw.comments.__setitem__("gr-fail", [{"text": "only a note"}])))
    ok("no 'Gate FAILED' comment -> transient skip_no_fail_reason, Jev not asked (an empty reason is not 'mechanical')",
       status == "skip_no_fail_reason" and not spy.states, status)
    status, _, spy = run_conserto(conserto_world(lambda cw: cw.comments.__setitem__("gr-fail", None)))
    ok("`bd comments` failing is the same transient skip (unknown is not empty)", status == "skip_no_fail_reason" and not spy.states, status)
    status, _, spy = run_conserto(conserto_world(lambda cw: cw.beads.pop(("/city", "gr-fail"))))
    ok("the rejected review's gate-run unreadable -> transient skip", status == "skip_prior_gate_run_unreadable" and not spy.states, status)

    # F10 Jev failure -> nao_sei, sonnet, error kept
    w = World()
    w.add_bead("/wa", "wa-8", title="t", description="d")
    ent = one_entity([ev("2026-09-25T01:00:00Z", "wa-8", "PASS", "gr8", W + "wa-8")], "wa-8", tmp)
    with patched(w):
        status, rec = q.process_entity(ent, "/city", {"rig_paths": None}, ask=Spy({"ok": False, "error": "http_503"}))
    ok("Jev down: logged as nao_sei, model stays sonnet, error kept, no fake probabilities",
       status == "logged" and rec["jev_ok"] is False and rec["jev_error"] == "http_503" and rec["escolha_jev"] == "nao_sei"
       and rec["modelo_jev"] == "sonnet" and rec["prob_escolha"] is None and rec["confianca_jev"] is None and rec["probabilidades"] is None
       and rec["desfecho_veredito"] == "PASS" and rec["jev_tokens_in"] == 0, json.dumps(rec)[:300])

    # F11 the model ACTUALLY used never changes, whatever Jev would pick
    for exp_ans, want in [(good("facil", 0.99, 0.99, q.NOVA_OPTIONS), "haiku"), (good("dificil", 0.99, 0.99, q.NOVA_OPTIONS), "sonnet")]:
        with patched(w):
            status, rec = q.process_entity(ent, "/city", {"rig_paths": None}, ask=Spy(exp_ans))
        ok(f"Jev would pick {want}: modelo_jev={rec['modelo_jev']} but modelo_real stays sonnet", rec["modelo_jev"] == want and rec["modelo_real"] == "sonnet")

    # F12 gc rig list is fetched lazily and ONCE
    w = World()
    w.add_bead("/wa", "wa-9", title="t")
    w.add_bead("/wa", "wa-10", title="t")
    e9 = one_entity([ev("2026-09-25T01:00:00Z", "wa-9", "PASS", "gr9", W + "wa-9")], "wa-9", tmp)
    e10 = one_entity([ev("2026-09-25T01:00:00Z", "wa-10", "PASS", "gr10", W + "wa-10")], "wa-10", tmp)
    ctx = {"rig_paths": None}
    with patched(w):
        q.process_entity(e9, "/city", ctx, ask=Spy(good("media", 0.7, 0.7, q.NOVA_OPTIONS)))
        q.process_entity(e10, "/city", ctx, ask=Spy(good("media", 0.7, 0.7, q.NOVA_OPTIONS)))
    ok("`gc rig list` (slow under Dolt load) is called once for the whole run", sum(1 for c in w.calls if c[:3] == ["gc", "rig", "list"]) == 1)


# ── G. run() end to end ─────────────────────────────────────────────────────────────
def build_world(n_wa=6):
    w = World()
    events = []
    for i in range(1, n_wa + 1):
        b = f"wa-{i}"
        w.add_bead("/wa", b, title=f"task {i}", description=f"do {i}")
        events.append(ev(f"2026-09-25T0{i}:00:00Z", b, "PASS", f"g{i}", f"crew/wa-worker/{b}"))
    return w, events


def test_run(tmp):
    section("G. run(): idempotent, read-only, bounded, fail-open")
    qg = os.path.join(tmp, "qg-run.jsonl")

    # G1 happy path + idempotency + read-only
    w, events = build_world(4)
    w.add_bead("/wa", "wa-crew", title="crew task")
    w.add_gate_run("g-crew", "batista-wa")
    events.append(ev("2026-09-25T09:00:00Z", "wa-crew", "PASS", "g-crew", "crew/batista/wa-crew"))
    write_log(qg, events)
    with tempfile.TemporaryDirectory() as td, patched(w, td):
        spy = Spy(good("media", 0.7, 0.6, q.NOVA_OPTIONS))
        c1 = q.run(gc_city="/city", qg_log=qg, ask=spy, now=NOW)
        recs = read_log(je.JEV_LOG)
        ok("first run: 5 entities, 4 logged (pool), 1 definitive skip (a named crew)",
           c1["entities"] == 5 and c1["logged"] == 4 and c1["statuses"].get("skip_definitive_not_pool") == 1 and len(recs) == 4, str(c1))
        ok("every logged line is mode quem-pensa and names its experiment", all(r["mode"] == q.MODE and r["experiment"] == q.EXP_NOVA for r in recs))
        ok("the definitive skip is remembered in the skips file", [s["entity_id"] for s in read_log(q.SKIPS_PATH)] == ["wa-crew"])
        calls_before = len(spy.states)
        w.calls.clear()
        c2 = q.run(gc_city="/city", qg_log=qg, ask=spy, now=NOW)
        ok("second run is a no-op: nothing new, nothing logged, Jev not called again",
           c2["new"] == 0 and c2["logged"] == 0 and len(spy.states) == calls_before and len(read_log(je.JEV_LOG)) == 4, str(c2))
        ok("second run does not re-pay the bd calls for the remembered skip", not any(c[0] == "bd" and c[4] == "g-crew" for c in w.calls))
        ok("READ-ONLY: across both runs no bd/gc/git call ever mutated anything", w.mutating_calls() == [], str(w.mutating_calls()))

    # G2 dry run writes nothing. The world MUST hold a non-pool bead: without one no definitive skip
    # ever happens and "the skips file is not written" would be asserted about nothing (a mutation
    # that made dry-run write it survived exactly that way).
    w, events = build_world(3)
    w.add_bead("/wa", "wa-crew", title="crew task")
    w.add_gate_run("g-crew", "batista-wa")
    events.append(ev("2026-09-25T09:00:00Z", "wa-crew", "PASS", "g-crew", "crew/batista/wa-crew"))
    write_log(qg, events)
    with tempfile.TemporaryDirectory() as td, patched(w, td):
        c = q.run(gc_city="/city", qg_log=qg, dry_run=True, ask=Spy(good("media", 0.7, 0.6, q.NOVA_OPTIONS)), now=NOW)
        ok("dry-run: the non-pool bead WAS classified as a definitive skip (so the check below is not vacuous)",
           c["statuses"].get("skip_definitive_not_pool") == 1, str(c))
        ok("dry-run: work is done and counted but NO log line and NO skips file is written",
           c["logged"] == 3 and not je.JEV_LOG.exists() and not q.SKIPS_PATH.exists(), str(c))

    # G3 limit
    w, events = build_world(6)
    write_log(qg, events)
    with tempfile.TemporaryDirectory() as td, patched(w, td):
        c = q.run(gc_city="/city", qg_log=qg, limit=2, ask=Spy(good("media", 0.7, 0.6, q.NOVA_OPTIONS)), now=NOW)
        ok("--limit bounds the work per run and the OLDEST outcomes go first",
           c["processed"] == 2 and [r["entity_id"] for r in read_log(je.JEV_LOG)] == ["wa-1", "wa-2"], str(c))
        c = q.run(gc_city="/city", qg_log=qg, limit=2, ask=Spy(good("media", 0.7, 0.6, q.NOVA_OPTIONS)), now=NOW)
        ok("the next run continues where the last stopped", [r["entity_id"] for r in read_log(je.JEV_LOG)] == ["wa-1", "wa-2", "wa-3", "wa-4"])

    # G4 Jev down: nao_sei rows, circuit breaker, bounded retries, recovery
    w, events = build_world(6)
    write_log(qg, events)
    down = lambda *a: {"ok": False, "error": "http_503"}  # noqa: E731
    with tempfile.TemporaryDirectory() as td, patched(w, td):
        c = q.run(gc_city="/city", qg_log=qg, ask=down, now=NOW)
        recs = read_log(je.JEV_LOG)
        ok("Jev down: the circuit breaker stops the run after 3 failures (a backlog is not burned)",
           c["circuit_break"] is True and c["processed"] == 3 and len(recs) == 3 and all(r["escolha_jev"] == "nao_sei" and r["modelo_jev"] == "sonnet" for r in recs), str(c))
        ok("the failures ARE logged (the outage is visible) and the untouched entities have no row",
           {r["entity_id"] for r in recs} == {"wa-1", "wa-2", "wa-3"})
        q.run(gc_city="/city", qg_log=qg, ask=down, now=NOW)
        ok("a failed entity is RETRIED next run, not written off after one failure",
           [r["entity_id"] for r in read_log(je.JEV_LOG)].count("wa-1") == 2)
        q.run(gc_city="/city", qg_log=qg, ask=down, now=NOW)
        done = q.load_done(je.JEV_LOG, q.SKIPS_PATH)
        ok(f"after {q.MAX_JEV_FAILS} failures an entity is done (stays nao_sei) so an outage cannot pin the queue",
           {("quem-pensa-nova", f"wa-{i}") for i in (1, 2, 3)} <= done and ("quem-pensa-nova", "wa-4") not in done)
        c = q.run(gc_city="/city", qg_log=qg, ask=Spy(good("media", 0.7, 0.6, q.NOVA_OPTIONS)), now=NOW)
        ok("Jev back: the untouched entities get real answers; the written-off ones stay nao_sei",
           c["circuit_break"] is False and {r["entity_id"] for r in read_log(je.JEV_LOG) if r["jev_ok"]} == {"wa-4", "wa-5", "wa-6"}, str(c))
    # one failure then success: done
    with tempfile.TemporaryDirectory() as td, patched(w, td):
        je._log({"mode": q.MODE, "experiment": q.EXP_NOVA, "entity_id": "x", "jev_ok": False})
        ok("1 failure alone is not done", ("quem-pensa-nova", "x") not in q.load_done(je.JEV_LOG, q.SKIPS_PATH))
        je._log({"mode": q.MODE, "experiment": q.EXP_NOVA, "entity_id": "x", "jev_ok": True})
        ok("an answered record makes it done", ("quem-pensa-nova", "x") in q.load_done(je.JEV_LOG, q.SKIPS_PATH))
        je._log({"mode": "shadow", "experiment": q.EXP_NOVA, "entity_id": "y", "jev_ok": True})
        je._log({"mode": q.MODE, "experiment": "other", "entity_id": "z", "jev_ok": True})
        d = q.load_done(je.JEV_LOG, q.SKIPS_PATH)
        ok("another front's records (different mode) never mark an entity done", ("quem-pensa-nova", "y") not in d)
        ok("the experiment is part of the key (a nova and a conserto with the same id are different)", ("quem-pensa-conserto", "z") not in d)

    # G5 transient skips are not remembered
    w, events = build_world(1)
    w.beads.pop(("/wa", "wa-1"))
    write_log(qg, events)
    with tempfile.TemporaryDirectory() as td, patched(w, td):
        q.run(gc_city="/city", qg_log=qg, ask=Spy(good("media", 0.7, 0.6, q.NOVA_OPTIONS)), now=NOW)
        ok("a transient skip leaves no trace, so the next run tries again", not q.SKIPS_PATH.exists() and not je.JEV_LOG.exists())
        w.add_bead("/wa", "wa-1", title="now readable")
        c = q.run(gc_city="/city", qg_log=qg, ask=Spy(good("media", 0.7, 0.6, q.NOVA_OPTIONS)), now=NOW)
        ok("...and it succeeds once the bead is readable", c["logged"] == 1)

    # G6 records are JSON-safe (ensure the log stays parseable)
    with tempfile.TemporaryDirectory() as td, patched(w, td):
        q.run(gc_city="/city", qg_log=qg, ask=Spy(good("media", 0.7, 0.6, q.NOVA_OPTIONS)), now=NOW)
        raw = Path(je.JEV_LOG).read_text(encoding="utf-8").splitlines()
        ok("each log line is one valid JSON object", all(isinstance(json.loads(l), dict) for l in raw) and len(raw) == 1)


def test_lock_and_switches(tmp):
    section("H. single instance and off switches")
    lp = os.path.join(tmp, "l.lock")
    fd1 = q.acquire_lock(lp)
    ok("first acquire gets the lock", fd1 is not None)
    ok("a second instance is refused while the first runs", q.acquire_lock(lp) is None)
    os.close(fd1)
    fd3 = q.acquire_lock(lp)
    ok("released on close (the kernel does the same on a crash), so it is never stale", fd3 is not None)
    os.close(fd3)

    def main_with(argv, env=None, disabled_file=False, lock_held=False):
        called = []
        with tempfile.TemporaryDirectory() as td, patched(None, td), mock.patch.object(sys, "argv", ["x"] + argv), \
             mock.patch.dict(os.environ, env or {}, clear=False), \
             mock.patch.object(q, "run", side_effect=lambda **kw: called.append(kw) or {"entities": 0, "statuses": {}}), \
             mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            if disabled_file:
                Path(q.DISABLED_PATH).write_text("x")
            held = q.acquire_lock() if lock_held else None
            rc = q.main()
            if held is not None:
                os.close(held)
        return rc, called, out.getvalue()

    rc, called, out = main_with(["run"])
    ok("main(): a normal invocation runs once with the default limit", rc == 0 and len(called) == 1 and called[0]["limit"] == q.DEFAULT_LIMIT
       and called[0]["since_days"] == q.DEFAULT_SINCE_DAYS and called[0]["dry_run"] is False)
    rc, called, out = main_with(["run", "--dry-run", "--limit", "7", "--since-days", "1.5"])
    ok("main(): flags reach run()", called and called[0]["dry_run"] is True and called[0]["limit"] == 7 and called[0]["since_days"] == 1.5)
    rc, called, out = main_with(["run"], env={"JEV_QUEM_PENSA_ENABLED": "0"})
    ok("main(): JEV_QUEM_PENSA_ENABLED=0 -> nothing runs", rc == 0 and not called and "disabled" in out)
    rc, called, out = main_with(["run"], disabled_file=True)
    ok("main(): the .disabled file -> nothing runs", rc == 0 and not called and "disabled" in out)
    rc, called, out = main_with(["run"], lock_held=True)
    ok("main(): another instance holds the lock -> nothing runs, exit 0 (an order must not flap)", rc == 0 and not called and "lock" in out)


# ── I. report ───────────────────────────────────────────────────────────────────────
def rec(exp, eid, ok_, choice, p, conf, modelo, verdict, bead, ts="2026-09-24T00:00:00Z"):
    return {"mode": q.MODE, "experiment": exp, "entity_id": eid, "bead": bead, "jev_ok": ok_, "escolha_jev": choice,
            "prob_escolha": p, "confianca_jev": conf, "modelo_jev": modelo, "desfecho_veredito": verdict, "desfecho_ts": ts}


def test_report(tmp):
    section("I. report")
    ok("band edges: 0.85 is the top band", rp.band_of(0.85) == "P>=0.85" and rp.band_of(1.0) == "P>=0.85")
    ok("band edges: 0.8499 / 0.70 are the middle band", rp.band_of(0.8499) == "0.70-0.85" and rp.band_of(0.70) == "0.70-0.85")
    ok("band edges: 0.69 is the bottom band", rp.band_of(0.69) == "P<0.70" and rp.band_of(0.0) == "P<0.70")

    ok("attempts until approval: FAIL,FAIL,PASS -> 3", rp.attempts_until_approval({"b": [{"result": "FAIL"}, {"result": "FAIL"}, {"result": "PASS"}]}) == {"b": 3})
    ok("attempts until approval: PASS first -> 1, even if re-reviewed later", rp.attempts_until_approval({"b": [{"result": "PASS"}, {"result": "FAIL"}, {"result": "PASS"}]}) == {"b": 1})
    ok("attempts until approval: never passed -> None (pending), not 0", rp.attempts_until_approval({"b": [{"result": "FAIL"}]}) == {"b": None})

    lp = os.path.join(tmp, "rep.jsonl")
    N = q.EXP_NOVA
    lines = [
        rec(N, "b5", False, "nao_sei", None, None, "sonnet", "PASS", "b5"),          # first attempt failed...
        rec(N, "b5", True, "media", 0.72, 0.6, "sonnet", "PASS", "b5"),               # ...then answered: counts ONCE, as answered
        rec(N, "b1", True, "facil", 0.97, 0.95, "haiku", "PASS", "b1"),
        rec(N, "b2", True, "facil", 0.90, 0.60, "sonnet", "FAIL", "b2"),
        rec(N, "b3", True, "dificil", 0.90, 0.90, "sonnet", "FAIL", "b3"),
        rec(N, "b6", False, "nao_sei", None, None, "sonnet", "PASS", "b6"),           # only ever failed -> nao_sei
        {"mode": "shadow", "experiment": "gate-verdict", "entity_id": "g1", "jev_ok": True},   # another front
        {"mode": q.MODE, "experiment": q.EXP_NOVA},                                      # no entity id
        rec(q.EXP_CONSERTO, "b2#2", True, "raciocinio", 0.99, 0.98, "opus", "FAIL", "b2"),
        rec(q.EXP_CONSERTO, "b2#3", True, "mecanico", 0.9, 0.9, "sonnet", "PASS", "b2"),
    ]
    with open(lp, "w", encoding="utf-8") as f:
        f.write("garbage line\n")
        for l in lines:
            f.write(json.dumps(l) + "\n")
    records = rp.load_records(lp)
    by = {(r["experiment"], r["entity_id"]): r for r in records}
    ok("load_records: one record per entity; a later answer replaces an earlier nao_sei", by[(N, "b5")]["jev_ok"] is True)
    ok("load_records: a failure AFTER an answer does not erase the answer",
       rp.dedupe_records([rec(N, "z", True, "media", 0.7, 0.7, "sonnet", "PASS", "z"), rec(N, "z", False, "nao_sei", None, None, "sonnet", "PASS", "z")])[0]["jev_ok"] is True)
    ok("load_records: other fronts, id-less lines and garbage are ignored", not any(k[1] in ("g1", None) for k in by) and len(records) == 7, str(len(records)))

    attempts = {"b1": 1, "b2": 3, "b3": None, "b5": 1, "b6": 1}
    s = rp.summarize(records, attempts)
    n = s[N]
    ok("nova: 5 decisions, 4 answered, 1 nao_sei counted APART", n["total"] == 5 and n["answered"] == 4 and n["nao_sei"] == 1)
    ok("nova: the base rate is over ANSWERED decisions only (2 of 4 approved first), nao_sei excluded",
       n["base"]["n"] == 4 and n["base"]["pass"] == 2)
    ok("nova: rows group by choice x probability band",
       n["rows"]["facil|P>=0.85"]["n"] == 2 and n["rows"]["facil|P>=0.85"]["pass"] == 1
       and n["rows"]["dificil|P>=0.85"]["n"] == 1 and n["rows"]["dificil|P>=0.85"]["pass"] == 0
       and n["rows"]["media|0.70-0.85"]["n"] == 1, json.dumps({k: v["n"] for k, v in n["rows"].items()}))
    ok("nova: the haiku-candidate group is the model Jev would use, not the raw choice (facil with low confidence is not in it)",
       n["candidate"]["n"] == 1 and n["candidate"]["pass"] == 1)
    ok("nova: attempts are recomputed from the gate log; a bead not approved yet is 'pending', never counted as 0",
       sorted(n["base"]["attempts"]) == [1, 1, 3] and n["base"]["pending"] == 1)
    k = s[q.EXP_CONSERTO]
    ok("conserto: opus candidate group and base", k["candidate"]["n"] == 1 and k["candidate"]["pass"] == 0 and k["base"]["n"] == 2 and k["base"]["pass"] == 1)
    ok("models Jev would have used are counted", n["models"] == {"haiku": 1, "sonnet": 3} and k["models"] == {"opus": 1, "sonnet": 1})
    s_none = rp.summarize(records, None)
    ok("gate log unreadable: attempts are UNAVAILABLE, not zero", s_none[N]["attempts_measured"] is False and s_none[N]["base"]["attempts"] == [])

    span = rp.summarize([rec(N, "a", True, "media", 0.7, 0.7, "sonnet", "PASS", "a", ts="2026-09-23T00:00:00Z"),
                         rec(N, "c", True, "media", 0.7, 0.7, "sonnet", "PASS", "c", ts="2026-09-25T06:00:00Z")], {"a": 1, "c": 1})
    ok("span in hours is measured from the gate outcome timestamps", abs(span[N]["span_hours"] - 54.0) < 0.01)

    text = rp.format_report(s)
    ok("report states the model is unchanged and that nothing alters a session", "UNCHANGED" in text and "sonnet" in text)
    ok("report flags PRELIMINARY when under 48h of outcomes", "PRELIMINARY" in text)
    ok("report flags small samples", "small sample" in text)
    ok("report says tokens per attempt are NOT measured in phase 1 (attempts are the proxy)", "NOT measured" in text and "tokens per attempt" in text)
    ok("report shows the base-rate row and both candidate groups", "base rate" in text and "HAIKU candidates" in text and "OPUS candidates" in text)
    ok("report counts nao_sei apart", "1 nao_sei" in text)
    ok("no PRELIMINARY flag once 48h+ of outcomes exist", "PRELIMINARY" not in rp.format_report(span).split("quem-pensa-conserto")[0])
    ok("empty log -> an explicit 'no records yet', not a table of zeros", "No quem-pensa records yet" in rp.format_report(rp.summarize([], {})))
    ok("gate log unreadable is stated in the table, not shown as attempts=0", "gate log unreadable" in rp.format_report(s_none))

    pt = rp.format_resumo_pt(s)
    ok("PT summary says it is observation only and the real model stays Sonnet", "so observacao" in pt and "Sonnet" in pt)
    ok("PT summary names both candidates and the base rate", "Haiku" in pt and "Opus" in pt and "geral" in pt)
    ok("PT summary carries the nao_sei count and the preliminary flag", "nao_sei" in pt and "preliminar" in pt)
    ok("PT summary with no data says so", "sem dados" in rp.format_resumo_pt(rp.summarize([], {})))

    # build_summary end to end against files
    qg = os.path.join(tmp, "qg-rep.jsonl")
    write_log(qg, [ev("2026-09-24T01:00:00Z", "b1", "PASS", "g1", "crew/wa-worker/b1"), ev("2026-09-24T02:00:00Z", "b2", "FAIL", "g2a", "crew/wa-worker/b2"),
                   ev("2026-09-24T03:00:00Z", "b2", "FAIL", "g2b", "crew/wa-worker/b2"), ev("2026-09-24T04:00:00Z", "b2", "PASS", "g2c", "crew/wa-worker/b2")])
    bs = rp.build_summary(lp, qg)
    ok("build_summary reads both files: b2 took 3 attempts, b1 took 1, b3 (not in the gate log) is pending",
       sorted(bs[N]["base"]["attempts"]) == [1, 3] and bs[N]["base"]["pending"] == 2, json.dumps(bs[N]["base"]))
    ok("build_summary with a missing gate log marks attempts unmeasured", rp.build_summary(lp, os.path.join(tmp, "missing.jsonl"))[N]["attempts_measured"] is False)


def test_generic_report_ignores_us(tmp):
    section("J. the generic Jev report must not count these records")
    lp = os.path.join(tmp, "generic.jsonl")
    normal = {"ts": "2026-09-20T03:00:00Z", "experiment": "gate-orphaned-label", "entity_id": "c", "arm": "experiment", "jev_ok": True,
              "jev_noul": 0.05, "jev_tokens_in": 300, "jev_tokens_out": 20, "suppress": True}
    mine = {**rec(q.EXP_NOVA, "wa-x", True, "facil", 0.97, 0.95, "haiku", "PASS", "wa-x"), "ts": "2026-09-20T05:00:00Z", "jev_tokens_in": 400, "jev_tokens_out": 45}
    with open(lp, "w", encoding="utf-8") as f:
        f.write(json.dumps(normal) + "\n" + json.dumps(mine) + "\n")
    with patched(None, tmp):
        jr.JEV_LOG = Path(lp)
        events = jr.load_events(None, None)
        summary = jr.summarize(events)
    ok("load_events drops quem-pensa records", [e.get("experiment") for e in events] == ["gate-orphaned-label"])
    ok("summarize() never sees a 'quem-pensa-nova' suppression experiment (it would count as a fired alert)", "quem-pensa-nova" not in summary)
    ok("the Jev tokens of quem-pensa are not added to the suppression experiment's cost",
       summary["gate-orphaned-label"]["jev_tokens_in"] == 300)
    with patched(None, tmp):
        jr.JEV_LOG = Path(lp)
        ok("asking for the quem-pensa experiment by name through the generic loader returns nothing (it has its own report)",
           jr.load_events(None, q.EXP_NOVA) == [])


def test_wiring():
    section("K. wiring on disk")
    here = Path(__file__).resolve().parent
    city = here.parent
    order = city / "packs/town-deltas/orders/jev-quem-pensa.toml"
    wrapper = city / "packs/town-deltas/assets/scripts/jev-quem-pensa.sh"
    text = order.read_text(encoding="utf-8") if order.exists() else ""
    ok("the order exists, is a cooldown trigger and runs the wrapper", 'trigger = "cooldown"' in text and "assets/scripts/jev-quem-pensa.sh" in text)
    ok("the order's cadence is hourly", 'interval = "1h"' in text)
    ok("the wrapper exists and is executable", wrapper.exists() and os.access(wrapper, os.X_OK))
    wt = wrapper.read_text(encoding="utf-8") if wrapper.exists() else ""
    ok("the wrapper bounds the run with timeout and runs the experiment's `run`", "timeout" in wt and "jev_quem_pensa_experiment.py" in wt and " run " in wt)
    daily = (here / "jev-daily-report.sh").read_text(encoding="utf-8")
    ok("the daily report script reads the quem-pensa report", "jev_quem_pensa_report.py" in daily)
    src = Path(q.__file__).read_text(encoding="utf-8")
    ok("static check: the experiment issues no mutating bd/gc verb and never passes --model to anything",
       not any(w in src for w in ('"update"', '"label"', '"close"', '"sling"', '"--model"', "'--model'")))


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        test_call_choice()
        test_decide_and_pool()
        test_entities(tmp)
        test_states()
        test_process_entity(tmp)
        test_run(tmp)
        test_lock_and_switches(tmp)
        test_report(tmp)
        test_generic_report_ignores_us(tmp)
        test_wiring()
    print(f"\njev-quem-pensa selftest: PASS={PASSED} FAIL={FAILED}")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
