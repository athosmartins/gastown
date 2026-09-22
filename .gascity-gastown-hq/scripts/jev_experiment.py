#!/usr/bin/env python3
"""jev_experiment.py (wa-dln9g) — A/B harness: Jev (TypeSafe, via Cloudflare Workers AI)
as an alert-escalation pre-filter, with a real control/experiment split and an honest
token-accounting log. Built for gate-orphaned-label-watchdog.sh first; any other
bash/python watchdog can reuse it the same way.

WHY: most of a night's Mayor token spend on routine watchdog mail isn't the fix — it's
re-deriving "is this actually actionable" for something that turns out to be noise
(confirmed 4x tonight for one specific reminder class alone). Jev is a decision-only
model: you hand it a `state` (text) + a typed yes/no question, it returns a CALIBRATED
probability in ~100ms at $0.042/M input tokens, output free — no chat, no code, no
arithmetic. That is exactly the shape of "does this alert need a human/Mayor now."

DESIGN (see wa-dln9g's own description for the full write-up):
  - Split is DETERMINISTIC per entity id (sha256(experiment:entity_id) mod 2), not
    random-per-run — the same recurring alert always lands in the same arm, so a
    comparison across days isn't confounded by flip-flopping.
  - CONTROL: unchanged. If the caller's own heuristic says "escalate", it escalates.
  - EXPERIMENT: heuristic decides the same way; if it says "escalate", ALSO ask Jev.
    Only suppress when Jev is confident (>= JEV_CONFIDENCE_THRESHOLD) that this does
    NOT need review. Anything else — Jev says yes, is unsure, errors, times out, or no
    credential is configured — escalates exactly like control. Third state (don't know)
    NEVER collapses into "safe to suppress"; the default under any doubt is to escalate.
  - Every evaluation is logged (JEV_LOG), win or lose, suppressed or not, so a human can
    audit exactly what would have been silenced and why. Nothing about the underlying
    watchdog's own detection/comment-on-bead logic changes — only whether THIS cycle's
    mail wakes Mayor.

WHAT THIS FILE DOES NOT DO: it does not decide anything on its own. It answers one
question a caller poses, and logs the answer. The caller (e.g. the watchdog bash script)
is still the one deciding whether an alert exists at all.

CREDENTIALS: reads CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN from the environment.
Neither is set as of 2026-09-22 (checked via `secret` against Bitwarden — nothing found;
see wa-dln9g) — until they are, call_jev() always returns ok=False, error=no_credentials,
which the suppression logic (by design, not by accident) treats as "escalate anyway".
The HTTP client itself is written against Cloudflare's documented request/response shape
(developers.cloudflare.com/ai/models/typesafe/jev/) but has never been exercised against
the live API — it defends against BOTH a bare model response and Cloudflare's usual
{"result": ..., "success": ...} v4 envelope, and fails closed (ok=False) on anything it
can't parse, rather than guessing.

CLI:
  python3 jev_experiment.py evaluate --entity-id <id> --experiment <name> \\
      --state-file <path> --question-key <key> --instructions <text> \\
      --true-desc <text> --false-desc <text> [--confidence 0.85]
    -> prints one JSON line to stdout: {arm, would_escalate_is_moot, suppress, jev_ok,
       jev_noul, jev_error, jev_tokens_in, jev_tokens_out}. Always exit 0 (a Jev/network
       failure is data, not a script failure — the caller's fallback is "escalate").
    Only writes a log line when --heuristic-would-escalate is passed (no-op evaluations
    where the underlying watchdog wasn't going to alert anyway aren't experiment data).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

JEV_LOG = Path(os.environ.get("JEV_EXPERIMENT_LOG", "/Users/athos/gt/.gascity-gastown-hq/.gc/logs/jev-experiment.jsonl"))
CF_ACCOUNT_ID = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "").strip()
CF_API_TOKEN = os.environ.get("CLOUDFLARE_API_TOKEN", "").strip()
JEV_MODEL = "typesafe/jev"
DEFAULT_CONFIDENCE_THRESHOLD = 0.85
HTTP_TIMEOUT_S = 8


def assign_arm(entity_id: str, experiment_name: str) -> str:
    """Deterministic 50/50 split, stable per (experiment, entity) — never per-run random."""
    digest = hashlib.sha256(f"{experiment_name}:{entity_id}".encode("utf-8")).hexdigest()
    return "experiment" if int(digest[:8], 16) % 2 == 0 else "control"


def call_jev(state: str, question_key: str, instructions: str, true_desc: str, false_desc: str) -> dict:
    """Never raises. Returns a dict with ok=True/False; ok=False always means 'treat as
    unknown, do not suppress' to the caller — this function does not make that call
    itself, evaluate() below does, so the fail-open policy lives in exactly one place."""
    if not CF_ACCOUNT_ID or not CF_API_TOKEN:
        return {"ok": False, "error": "no_credentials"}

    endpoint = f"https://api.cloudflare.com/client/v4/accounts/{CF_ACCOUNT_ID}/ai/run"
    body = json.dumps(
        {
            "model": JEV_MODEL,
            "input": {
                "state": state,
                "questions": {
                    question_key: {
                        "type": "noul",
                        "instructions": instructions,
                        "criteria": {"true": true_desc, "false": false_desc},
                    }
                },
            },
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        endpoint,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {CF_API_TOKEN}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
            raw = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"http_{e.code}"}
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return {"ok": False, "error": f"network: {type(e).__name__}: {e}"}
    except json.JSONDecodeError as e:
        return {"ok": False, "error": f"bad_json: {e}"}

    # Cloudflare's v4 API normally wraps model output in {"result": ..., "success": ...};
    # the model docs' own example shows the inner shape directly. Accept either — but
    # never guess past a KeyError/TypeError, that's exactly the third-state bug this
    # whole file exists to avoid on the CALLER's side.
    payload = raw.get("result", raw) if isinstance(raw, dict) else None
    if not isinstance(payload, dict):
        return {"ok": False, "error": "unparseable_response_shape"}
    try:
        answer = payload["answers"][question_key]
        noul = float(answer["noul"])
        usage = payload.get("usage", {}) or {}
        tokens_in = int(usage.get("input_tokens", 0) or 0)
        tokens_out = int(usage.get("output_tokens", 0) or 0)
    except (KeyError, TypeError, ValueError) as e:
        return {"ok": False, "error": f"unparseable_answer: {e}"}

    if not (0.0 <= noul <= 1.0):
        return {"ok": False, "error": f"noul_out_of_range: {noul}"}

    return {"ok": True, "noul": noul, "tokens_in": tokens_in, "tokens_out": tokens_out}


def evaluate(
    entity_id: str,
    experiment: str,
    state: str,
    question_key: str,
    instructions: str,
    true_desc: str,
    false_desc: str,
    confidence_threshold: float,
) -> dict:
    arm = assign_arm(entity_id, experiment)
    result = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "experiment": experiment,
        "entity_id": entity_id,
        "arm": arm,
        "jev_ok": False,
        "jev_noul": None,
        "jev_error": None,
        "jev_tokens_in": 0,
        "jev_tokens_out": 0,
        "suppress": False,
    }

    if arm != "experiment":
        # Control arm never calls Jev — that IS the control. Zero Jev cost, zero
        # suppression, by construction.
        result["jev_error"] = "control_arm_skips_jev"
        return result

    jr = call_jev(state, question_key, instructions, true_desc, false_desc)
    result["jev_ok"] = jr["ok"]
    if jr["ok"]:
        result["jev_noul"] = jr["noul"]
        result["jev_tokens_in"] = jr["tokens_in"]
        result["jev_tokens_out"] = jr["tokens_out"]
        # noul is P(true) where true = "needs review". Suppress only when Jev is
        # confidently on the FALSE side — i.e. P(needs review) is low.
        not_needed_confidence = 1.0 - jr["noul"]
        result["suppress"] = not_needed_confidence >= confidence_threshold
    else:
        result["jev_error"] = jr["error"]
        # ok=False (no credential, network error, unparseable response, whatever) ->
        # suppress stays False. This is the one line that makes the fail-open policy
        # real instead of a comment.

    return result


def _log(entry: dict) -> None:
    JEV_LOG.parent.mkdir(parents=True, exist_ok=True)
    with JEV_LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    ev = sub.add_parser("evaluate")
    ev.add_argument("--entity-id", required=True)
    ev.add_argument("--experiment", required=True)
    ev.add_argument("--state-file", required=True, help="path to a text file with the alert's own text")
    ev.add_argument("--question-key", default="needs_review")
    ev.add_argument("--instructions", required=True)
    ev.add_argument("--true-desc", required=True)
    ev.add_argument("--false-desc", required=True)
    ev.add_argument("--confidence", type=float, default=DEFAULT_CONFIDENCE_THRESHOLD)
    ev.add_argument(
        "--heuristic-would-escalate",
        action="store_true",
        help="only pass this when the caller's OWN rules already decided to alert; "
        "suppresses log-writing for the (uninteresting) case where nothing was going to fire anyway",
    )

    args = ap.parse_args()

    if args.cmd == "evaluate":
        state_text = Path(args.state_file).read_text(encoding="utf-8", errors="replace")
        result = evaluate(
            entity_id=args.entity_id,
            experiment=args.experiment,
            state=state_text,
            question_key=args.question_key,
            instructions=args.instructions,
            true_desc=args.true_desc,
            false_desc=args.false_desc,
            confidence_threshold=args.confidence,
        )
        if args.heuristic_would_escalate:
            _log(result)
        else:
            result["suppress"] = False  # nothing to suppress if it wasn't going to fire
        print(json.dumps(result, ensure_ascii=False))
        return 0

    return 1  # pragma: no cover — argparse's `required=True` on sub already prevents this


if __name__ == "__main__":
    sys.exit(main())
