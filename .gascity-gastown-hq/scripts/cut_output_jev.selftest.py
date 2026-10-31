#!/usr/bin/env python3
"""cut_output_jev.selftest.py (ga-d0hm85, slice 2/4) -- hermetic selftest of cut_output_jev.py: block partition, the three states per
block and per record, the tier decision (OFF unless the enable file says otherwise), the deadline and every failure class of the
Jev call. Pure: the network call is mocked, nothing is sent, nothing is written outside temp dirs.

  python3 cut_output_jev.selftest.py        (or: python3 cut_output_jev.py selftest)
"""
from __future__ import annotations

import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cut_output_classifier as coc  # noqa: E402,F401
import cut_output_jev as _m  # noqa: E402
import jev_experiment as je  # noqa: E402

# the selftest reads like the module it tests: every public name, plus the private ones it pins
globals().update({k: v for k, v in vars(_m).items() if not k.startswith("__")})


def _selftest() -> int:
    import tempfile
    from unittest import mock

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

    def partition_ok(rec: dict) -> bool:
        return (rec["chars_relevant"] + rec["chars_cuttable"] + rec["chars_not_judged"] == rec["chars_before"]
                and rec["blocks_relevant"] + rec["blocks_cuttable"] + rec["blocks_not_judged"] == rec["block_count"]
                and all(e["state"] in (BLOCK_RELEVANT, BLOCK_CUTTABLE, BLOCK_NOT_JUDGED) for e in rec["blocks"]))

    meta = {"entity_id": "tu-1", "session_id": "s", "transcript_path": "/tmp/t.jsonl", "tool_use_id": "tu-1",
            "command": "some-tool --verbose", "hook_event": coc.EVENT_SUCCESS, "exit_code": None}
    paragraphs = [f"paragraph {i}: " + ("generic prose text " * 25) for i in range(12)]
    text12 = "\n\n".join(paragraphs)  # 12 blocks, each ~ 500 chars

    def jev_ok_result(n: int, noul: float) -> dict:
        return {"ok": True, "answers": {f"block_{i}": noul for i in range(n)}, "bad": {}, "tokens_in": 100, "tokens_out": 5}

    # ---- the partition: blocks tile the text for every shape ----
    shapes = {
        "paragraphs": text12,
        "no paragraphs (one line each)": "\n".join(f"line {i} " + "x" * 60 for i in range(80)),
        "one giant line": "x" * 5000,
        "trailing blank lines": text12 + "\n\n\n\n",
        "leading blank lines": "\n\n\n" + text12,
        "CRLF": "\r\n".join(f"crlf line {i} " + "y" * 50 for i in range(60)),
        "unicode line separators": ("alpha beta\x0cgamma\n" * 40),
        "only blank lines": "\n" * 50,
        "no trailing newline": "a\n\nb\n\nc",
    }
    for label, shape in shapes.items():
        bl = build_blocks(shape)
        ok(f"partition ({label}): blocks tile the text exactly (sum of chars == len(text))", sum(b["chars"] for b in bl) == len(shape))
        ok(f"partition ({label}): blocks are contiguous and in order",
           all(bl[i]["end"] == bl[i + 1]["start"] for i in range(len(bl) - 1)) and bl[0]["start"] == 0 and bl[-1]["end"] == len(shape))
        ok(f"partition ({label}): at most MAX_BLOCKS blocks", len(bl) <= MAX_BLOCKS)
    ok("build_blocks: empty text -> no blocks", build_blocks("") == [])
    ok("build_blocks: 12 paragraphs -> 12 blocks", len(build_blocks(text12)) == 12)
    ok("build_blocks: max_blocks merges paragraphs down", len(build_blocks(text12, max_blocks=5)) <= 5)

    # ---- budget and egress guard ----
    bl = build_blocks(text12)
    plan_send(bl, text12, max_chars=10**6)
    ok("plan_send: an output that fits sends every block", all(b["send"] for b in bl))
    plan_send(bl, text12, max_chars=2000)
    left_out = [b for b in bl if not b["send"]]
    ok("plan_send: over budget -> some blocks are left out", 0 < len(left_out) < len(bl))
    ok("plan_send: a block left out is NOT JUDGED with reason over-budget, never silently absent",
       all(b["state"] == BLOCK_NOT_JUDGED and b["reason"] == "over-budget" for b in left_out))
    ok("plan_send: the head and the tail are what is sent (the middle is what is left out)",
       bl[0]["send"] and bl[-1]["send"] and not bl[len(bl) // 2]["send"])
    ok("plan_send: the sent text stays inside the budget", sum(b["chars"] for b in bl if b["send"]) <= 2000)
    giant = build_blocks("z" * 9000)
    plan_send(giant, "z" * 9000, max_chars=4000)
    ok("plan_send: a single block bigger than half the budget is left out whole, never sliced",
       len(giant) == 1 and not giant[0]["send"] and giant[0]["reason"] == "over-budget")

    # a PEM key that spans a block edge: no single block contains BOTH the BEGIN and the END marker, and the middle block
    # (base64 body) matches no pattern by itself
    pem = ("-----BEGIN RSA PRIVATE KEY-----\n" + "\n".join("MIIEowIBAAKCAQEA" + "0123456789abcdef" * 4 for _ in range(5)) + "\n-----END RSA PRIVATE KEY-----\n")
    filler = lambda tag: "\n\n".join(f"{tag} paragraph {i}: " + "ordinary words " * 20 for i in range(4))  # noqa: E731
    pem_text = filler("before") + "\n\n" + pem.replace("\n", "\n\n", 3) + "\n\n" + filler("after")
    pbl = build_blocks(pem_text, max_blocks=13)
    plan_send(pbl, pem_text, max_chars=10**6)
    body_blocks = [b for b in pbl if "MIIEowIBAAKCAQEA" in pem_text[b["start"]:b["end"]]]
    ok("setup: the PEM body is spread over more than one block, and a body block has no BEGIN/END marker of its own",
       len(body_blocks) >= 2 and any("-----" not in pem_text[b["start"]:b["end"]] for b in body_blocks))
    ok("review finding 2: every block the PEM key touches is withheld, including body blocks that look harmless alone",
       all(not b["send"] and b["state"] == BLOCK_NOT_JUDGED and b["reason"].startswith("withheld-") for b in body_blocks))
    ok("review finding 2: the paragraphs well before and after the key are still sent", pbl[0]["send"] and pbl[-1]["send"])
    trunc = filler("before") + "\n\n-----BEGIN OPENSSH PRIVATE KEY-----\n\n" + "b3BlbnNzaC1rZXktdjEAAAAA" * 8
    tbl = build_blocks(trunc, max_blocks=13)
    plan_send(tbl, trunc, max_chars=10**6)
    ok("review finding 2: a key TRUNCATED mid-way (BEGIN, no END) withholds everything after the BEGIN marker",
       not tbl[-1]["send"] and tbl[0]["send"])
    k8s = filler("before") + "\n\napiVersion: v1\nkind: Secret\nmetadata:\n  name: x\ndata:\n  value: dGhpcyBpcyBhIHNlY3JldA==\n\n" + filler("tail")
    kbl = build_blocks(k8s, max_blocks=13)
    plan_send(kbl, k8s, max_chars=10**6)
    ok("review finding 2: a `kind: Secret` manifest withholds the blocks of its document", any(not b["send"] for b in kbl) and kbl[0]["send"])
    # "password:" as the LAST line of one block, the value as the FIRST line of the next
    split_key = filler("before") + "\n\ndb:\n  password:\n\nhunter2hunter2\n\n" + filler("after")
    sbl = build_blocks(split_key, max_blocks=13)
    plan_send(sbl, split_key, max_chars=10**6)
    value_block = next(b for b in sbl if "hunter2hunter2" in split_key[b["start"]:b["end"]])
    ok("review finding 2: a `password:` at the end of a block withholds the NEXT block, where the value is", not value_block["send"])
    # Cost bound on hostile input, production-shaped: the default budget (MAX_STATE_CHARS) caps what is scanned in full, and the
    # whole-output scan (sensitive_spans) is the only thing that sees all of it. The bound is generous on purpose -- a timing
    # assertion on a machine at load 60 must not flake -- yet a quadratic scan of these 100k+ inputs would take minutes.
    t_lin = time.time()
    for hostile in ("A1" * 60000, ("a-" * 30000) + "Z9", "-----BEGIN X-----" * 400, "kind: Secret\n" * 400, "token:" * 20000, ("Ab1" * 40 + " ") * 5000):
        hb = build_blocks(hostile)
        plan_send(hb, hostile)
        egress_withhold_reason(hostile[:MAX_STATE_CHARS // 2])
    ok("the guard + span scan stay linear on hostile 100k+ character inputs (production budget; bound is generous, not tight)", time.time() - t_lin < 10.0)
    bad_text = text12 + "\n\ncpf 123.456.789-09"
    bl = build_blocks(bad_text)
    plan_send(bl, bad_text, max_chars=10**6)
    ok("plan_send: a block with a CPF is withheld (not sent, not-judged, withheld-pii)",
       bl[-1]["send"] is False and bl[-1]["state"] == BLOCK_NOT_JUDGED and bl[-1]["reason"] == "withheld-pii")
    ok("plan_send: the clean blocks next to it are still sent", all(b["send"] for b in bl[:-1]))
    _, qs = build_state_and_questions("curl -H 'Authorization: Bearer abcdef0123456789'", bl, bad_text)
    st, _ = build_state_and_questions("curl -H 'Authorization: Bearer abcdef0123456789'", bl, bad_text)
    ok("build_state_and_questions: a command that carries a credential is withheld from the state", "abcdef0123456789" not in st and COMMAND_WITHHELD in st)
    ok("build_state_and_questions: the withheld block's text is not in the state, and has no question",
       "123.456.789-09" not in st and f"block_{bl[-1]['idx']}" not in qs)
    ok("build_state_and_questions: one question per sent block, keyed by the block's global index", set(qs) == {f"block_{b['idx']}" for b in bl if b["send"]})

    # ---- THE gate verdict ga-nw6sbx: could-not-judge must not read as judged-and-nothing-to-cut ----
    def judged_record(jev_result):
        bls = build_blocks(text12, max_blocks=3)
        plan_send(bls, text12, max_chars=10**6)
        resolve_blocks(bls, jev_result)
        return build_jev_record(jev_result, bls, text12, meta)

    all_bad = judged_record({"ok": True, "answers": {}, "bad": {f"block_{i}": "unparseable_answer: x" for i in range(3)}, "tokens_in": 10, "tokens_out": 1})
    all_relevant = judged_record(jev_ok_result(3, 0.95))
    ok("ga-nw6sbx: an ok call whose every block is unparseable is jev_state not-judged / coverage none", all_bad["jev_state"] == STATE_NOT_JUDGED and all_bad["coverage"] == COVERAGE_NONE)
    ok("ga-nw6sbx: ... and its tokens_would_save is None, NOT 0", all_bad["tokens_would_save"] is None)
    ok("ga-nw6sbx: ... while 'judged everything relevant' is a MEASURED 0 (judged-relevant / full)",
       all_relevant["jev_state"] == STATE_RELEVANT and all_relevant["coverage"] == COVERAGE_FULL and all_relevant["tokens_would_save"] == 0)
    ok("ga-nw6sbx: the two records differ on state, coverage and tokens_would_save (the old tier made them identical)",
       (all_bad["jev_state"], all_bad["coverage"], all_bad["tokens_would_save"]) != (all_relevant["jev_state"], all_relevant["coverage"], all_relevant["tokens_would_save"]))
    ok("ga-nw6sbx: the unjudged blocks are NOT counted as judged (the old chars_judged counted them)", all_bad["chars_relevant"] + all_bad["chars_cuttable"] == 0 and all_bad["chars_not_judged"] == all_bad["chars_before"])
    ok("ga-nw6sbx: the reason is on the record, per block and summed", all_bad["not_judged_reasons"] == {"no-answer:unparseable_answer": 3})
    ok("ga-nw6sbx: a not-judged record has no chars_after/tokens_after to subtract", all_bad["chars_after"] is None and all_bad["tokens_after"] is None)
    ok("ga-nw6sbx: partition holds for both", partition_ok(all_bad) and partition_ok(all_relevant))

    # ---- states and numbers derived from them ----
    cut_all = judged_record(jev_ok_result(3, 0.02))
    ok("all blocks confidently noise -> judged-cuttable / full", cut_all["jev_state"] == STATE_CUTTABLE and cut_all["coverage"] == COVERAGE_FULL)
    ok("all cuttable: a real saving, measured through the classifier (tokens_before - tokens_after)",
       cut_all["tokens_would_save"] == cut_all["tokens_before"] - cut_all["tokens_after"] and cut_all["tokens_would_save"] > 0 and cut_all["cut_rule"] == CUT_RULE)
    ok("all cuttable: the lower bound field is empty for a full record (no second number to average)", cut_all["tokens_saved_lower_bound"] is None)
    ok("all cuttable: signatures come from the cut blocks", isinstance(cut_all["omitted_signatures"], list))
    ok("all cuttable: partition holds", partition_ok(cut_all))
    unsure = judged_record(jev_ok_result(3, 0.30))
    ok("probably-noise-but-not-confident (noul 0.30 < 0.5, confidence 0.70 < 0.85) -> kept: relevant, saving a measured 0",
       unsure["jev_state"] == STATE_RELEVANT and unsure["blocks_cuttable"] == 0 and unsure["tokens_would_save"] == 0)
    ok("... and the raw noul stays in the block entry so 'unsure' is distinguishable from 'sure it matters'",
       all("noul" in e for e in unsure["blocks"]) and unsure["blocks"][0]["noul"] == 0.3)
    edge = judged_record({"ok": True, "answers": {"block_0": 0.5, "block_1": 0.15, "block_2": 0.1500001}, "bad": {}, "tokens_in": 1, "tokens_out": 1})
    ok("threshold edges: noul 0.5 is relevant; noul 0.15 (confidence exactly 0.85) is cuttable; noul 0.1500001 (confidence 0.8499999, "
       "just under the bar) stays relevant -- a lower noul means MORE sure it is noise",
       [e["state"] for e in edge["blocks"]] == [BLOCK_RELEVANT, BLOCK_CUTTABLE, BLOCK_RELEVANT])
    partial = judged_record({"ok": True, "answers": {"block_0": 0.02, "block_1": 0.95}, "bad": {"block_2": "noul_out_of_range: 1.5"}, "tokens_in": 1, "tokens_out": 1})
    ok("a partial call (one block unjudged) -> coverage partial, jev_state from the judged blocks only", partial["coverage"] == COVERAGE_PARTIAL and partial["jev_state"] == STATE_CUTTABLE)
    ok("partial: tokens_would_save is None (never enters an average); the floor is in tokens_saved_lower_bound",
       partial["tokens_would_save"] is None and isinstance(partial["tokens_saved_lower_bound"], int) and partial["tokens_saved_lower_bound"] > 0)
    ok("partial: no chars_after / tokens_after", partial["chars_after"] is None and partial["tokens_after"] is None)
    ok("partial: the unjudged block is counted as not-judged and its reason names the class", partial["blocks_not_judged"] == 1 and partial["not_judged_reasons"] == {"no-answer:noul_out_of_range": 1})
    partial_rel = judged_record({"ok": True, "answers": {"block_0": 0.95, "block_1": 0.95}, "bad": {}, "tokens_in": 1, "tokens_out": 1})
    ok("partial with NOTHING cuttable among the judged blocks: not a measured 0 -- tokens_would_save None, floor 0",
       partial_rel["coverage"] == COVERAGE_PARTIAL and partial_rel["tokens_would_save"] is None and partial_rel["tokens_saved_lower_bound"] == 0 and partial_rel["not_judged_reasons"] == {"no-answer:missing": 1})
    missing = judged_record({"ok": True, "answers": {"block_0": 0.9}, "bad": {}, "tokens_in": 1, "tokens_out": 1})
    ok("a block with neither an answer nor a bad entry is not-judged 'no-answer:missing', never a low probability", missing["blocks"][1]["reason"] == "no-answer:missing")
    for label, junk in (("a bool", True), ("a string", "0.9"), ("None", None), ("nan", float("nan")), ("above 1", 1.5), ("negative", -0.1)):
        r = judged_record({"ok": True, "answers": {"block_0": junk, "block_1": 0.9, "block_2": 0.9}, "bad": {}, "tokens_in": 1, "tokens_out": 1})
        ok(f"an answer that is {label} is not-judged, not a judgement", r["blocks"][0]["state"] == BLOCK_NOT_JUDGED and r["coverage"] == COVERAGE_PARTIAL)
    for label, res in (
        ("deadline", {"ok": False, "error": "deadline"}),
        ("vault", {"ok": False, "error": "vault_unavailable"}),
        ("network with a message", {"ok": False, "error": "network: URLError: <urlopen error secret 123.456.789-09>"}),
        ("not a dict error", {"ok": False, "error": {"x": 1}}),
        ("no error key", {"ok": False}),
    ):
        r = judged_record(res)
        ok(f"whole-call failure ({label}): not-judged / none, tokens_would_save None, partition holds",
           r["jev_state"] == STATE_NOT_JUDGED and r["coverage"] == COVERAGE_NONE and r["tokens_would_save"] is None and partition_ok(r) and r["jev_ok"] is False)
        ok(f"whole-call failure ({label}): the reason is a short class, never the message",
           all(re.fullmatch(r"call-failed:[a-z0-9_:]{1,48}", reason) for reason in r["not_judged_reasons"]) and "123.456" not in str(r))
    ok("whole-call failure: 'network: URLError: ...' is classed as 'network'", judged_record({"ok": False, "error": "network: URLError: boom"})["not_judged_reasons"] == {"call-failed:network": 3})
    ok("a ok=True call whose answers are not even a dict does not raise and judges nothing",
       judged_record({"ok": True, "answers": "garbage", "bad": ["x"]})["jev_state"] == STATE_NOT_JUDGED)
    r = judged_record(None)
    ok("no call made (jev_result None) on blocks that were sendable: not-judged, jev_called False, jev_ok None", r["jev_state"] == STATE_NOT_JUDGED and r["jev_called"] is False and r["jev_ok"] is None)
    ok("token usage is recorded only for an ok call", judged_record(jev_ok_result(3, 0.9))["jev_tokens_in"] == 100 and judged_record({"ok": False, "error": "deadline"})["jev_tokens_in"] == 0)

    # a cut that would not shrink the output is the classifier's own "no-gain", a MEASURED 0 -- not a phantom saving.
    # Fixture: a 1-line block judged cuttable between two big relevant ones; its "[1 lines omitted; ...]" marker is longer
    # than the 2 characters it replaces.
    tiny = ("keep me " * 300 + "\n\n") + "x\n\n" + ("keep me too " * 300 + "\n")
    tb = build_blocks(tiny)
    plan_send(tb, tiny, max_chars=10**6)
    resolve_blocks(tb, {"ok": True, "answers": {f"block_{b['idx']}": (0.01 if b["chars"] < 10 else 0.99) for b in tb}, "bad": {}})
    trec = build_jev_record({"ok": True}, tb, tiny, meta)
    ok("setup: the tiny fixture has exactly one cuttable block", trec["blocks_cuttable"] == 1 and trec["coverage"] == COVERAGE_FULL)
    ok("a cuttable verdict whose marker costs more than the text is cut_rule 'no-gain'", trec["cut_rule"] == "no-gain")
    ok("... a MEASURED 0 (full coverage, judged), not None and not a negative", trec["tokens_would_save"] == 0 and trec["tokens_after"] == trec["tokens_before"])
    ok("... with nothing for the join to look for (nothing was cut)", trec["omitted_signatures"] == [])
    # and a cut that does shrink: the number is exactly what the classifier measured
    noise = "".join(f"noise line {i}\n" for i in range(400))
    nb = build_blocks(noise, max_blocks=4)
    plan_send(nb, noise, max_chars=10**6)
    resolve_blocks(nb, {"ok": True, "answers": {f"block_{b['idx']}": 0.01 for b in nb}, "bad": {}})
    nrec = build_jev_record({"ok": True}, nb, noise, meta)
    ok("a cut that shrinks the output: cut_rule 'jev-cut', saving == tokens_before - tokens_after, positive",
       nrec["cut_rule"] == CUT_RULE and nrec["tokens_would_save"] == nrec["tokens_before"] - nrec["tokens_after"] > 0)

    # a block that is still pending when the record is built is counted as not-judged, never dropped
    pend = build_blocks(text12, max_blocks=3)
    plan_send(pend, text12, max_chars=10**6)
    prec = build_jev_record({"ok": True}, pend, text12, meta)
    ok("a block left pending is counted not-judged 'unresolved' (cannot vanish from the partition)", prec["blocks_not_judged"] == 3 and partition_ok(prec) and prec["tokens_would_save"] is None)

    # ---- the exception record ----
    erec = build_exception_record(ValueError("secret 123.456.789-09 in the message"), text12, meta)
    ok("exception record: not-judged / none, no numbers, class only (no message)", erec["jev_state"] == STATE_NOT_JUDGED and erec["tokens_would_save"] is None and erec["jev_error"] == "exception:valueerror" and "123.456" not in str(erec))
    with mock.patch.object(_m, "build_blocks", side_effect=RuntimeError("boom")):
        jr = judge("cmd", text12, meta)
    ok("judge(): an internal failure becomes an exception record, not a raise", jr["jev_state"] == STATE_NOT_JUDGED and jr["jev_error"] == "exception:runtimeerror")

    # ---- judge() end to end, with the network call mocked ----
    with mock.patch.object(je, "call_jev_multi", return_value=jev_ok_result(12, 0.03)) as m:
        jr = judge("some-tool", text12, meta)
    ok("judge(): makes exactly one call for the whole output", m.call_count == 1)
    ok("judge(): a clean ok call -> judged-cuttable / full, partition holds", jr["jev_state"] == STATE_CUTTABLE and jr["coverage"] == COVERAGE_FULL and partition_ok(jr))
    sent_state, sent_questions = m.call_args[0]
    ok("judge(): the call carried the command and every block, one question each", "Command: some-tool" in sent_state and len(sent_questions) == 12)
    all_secret = "\n\n".join(f"line {i} password=hunter2hunter2" for i in range(6)) + "\n\n" + "x" * 2100
    with mock.patch.object(je, "call_jev_multi", side_effect=AssertionError("nothing sendable: must not call")) as m2:
        mixed = judge("cmd", "token=abcdefgh1234\n\n" * 200, meta)
    ok("judge(): when EVERY block is withheld there is no call at all, and the record says so", m2.call_count == 0 and mixed["jev_called"] is False and mixed["jev_state"] == STATE_NOT_JUDGED and set(mixed["not_judged_reasons"]) == {"withheld-secret"})
    with mock.patch.object(je, "call_jev_multi", return_value=jev_ok_result(12, 0.9)) as m3:
        judge("cmd", all_secret, meta)
    ok("judge(): a withheld block's text is not in what was sent", all("hunter2" not in str(c[0]) for c in m3.call_args_list))
    with mock.patch.object(je, "call_jev_multi", side_effect=lambda s, q: (time.sleep(2), jev_ok_result(12, 0.9))[1]):
        t0 = time.time()
        slow = judge("cmd", text12, meta, deadline_s=0.2)
        took = time.time() - t0
    ok("judge(): a call slower than the deadline is abandoned in about the deadline", took < 1.5)
    ok("judge(): ... and logged as not-judged 'call-failed:deadline', jev_ok False", slow["jev_state"] == STATE_NOT_JUDGED and slow["jev_ok"] is False and set(slow["not_judged_reasons"]) == {"call-failed:deadline"})
    with mock.patch.object(je, "call_jev_multi", side_effect=RuntimeError("boom with 123.456.789-09")):
        boom = judge("cmd", text12, meta)
    ok("judge(): a call_jev_multi that raises is not-judged 'call-failed:exception:runtimeerror', message not kept",
       boom["jev_state"] == STATE_NOT_JUDGED and set(boom["not_judged_reasons"]) == {"call-failed:exception:runtimeerror"} and "123.456" not in str(boom))
    with mock.patch.object(je, "call_jev_multi", return_value="not a dict"):
        nd = judge("cmd", text12, meta)
    ok("judge(): a call that returns a non-dict is not-judged 'call-failed:no_result'", set(nd["not_judged_reasons"]) == {"call-failed:no_result"})
    over = "\n".join("q" * 90 for _ in range(400))
    with mock.patch.object(je, "call_jev_multi", return_value=jev_ok_result(13, 0.9)):
        ov = judge("cmd", over, meta)
    ok("judge(): an output over the budget is partial (the middle is not-judged 'over-budget'), never full", ov["coverage"] == COVERAGE_PARTIAL and "over-budget" in ov["not_judged_reasons"] and ov["tokens_would_save"] is None and partition_ok(ov))

    # ---- the tier decision: OFF unless a human wrote the enable file ----
    mod = _m
    with tempfile.TemporaryDirectory() as td:
        enabled = Path(td) / "jev.enabled"
        sentinel = Path(td) / "jev.disabled"
        with mock.patch.object(mod, "JEV_ENABLED_FILE", enabled), mock.patch.object(mod, "JEV_DISABLED_SENTINEL", sentinel):
            ok("jev_tier: NO enable file -> disabled (the tier ships OFF)", sample_pct() == 0.0 and jev_tier("e") == TIER_DISABLED)
            enabled.write_text("# Athos, resposta ao AskUserQuestion em ga-xxxxxx#c1, 2026-11-01T12:00Z, 'liga a 100'\n\n100\n")
            ok("jev_tier: comment lines (the authorization citation) are skipped; '100' -> attempted", sample_pct() == 100.0 and jev_tier("e") == TIER_ATTEMPTED)
            enabled.write_text("# only a comment, nobody put a number\n")
            ok("jev_tier: a comments-only file is OFF -- a citation alone is not a yes", sample_pct() == 0.0 and jev_tier("e") == TIER_DISABLED)
            enabled.write_text("0\n")
            ok("jev_tier: 0 -> disabled (not 'sampled-out')", jev_tier("e") == TIER_DISABLED)
            for junk in ("lots", "nan", "-5", "250", "1e999", "10 percent", "\x00"):
                enabled.write_text(f"# cited\n{junk}\n")
                ok(f"jev_tier: an unreadable value ({junk!r}) is inert -> disabled, never 'send everything'", jev_tier("e") == TIER_DISABLED)
            enabled.write_bytes(b"\xff\xfe not utf-8 \xff")
            ok("jev_tier: a file that is not UTF-8 is OFF", jev_tier("e") == TIER_DISABLED)
            enabled.unlink()
            enabled.mkdir()
            ok("jev_tier: an enable 'file' that cannot be read (a directory) is OFF", jev_tier("e") == TIER_DISABLED)
            enabled.rmdir()
            enabled.write_text("100\n")
            sentinel.write_text("off")
            ok("jev_tier: the kill-switch sentinel beats 'enabled at 100'", jev_tier("e") == TIER_DISABLED)
            sentinel.unlink()
            enabled.write_text("25\n")
            ids = [f"toolu_{i:05d}" for i in range(4000)]
            tiers = [jev_tier(i) for i in ids]
            share = tiers.count(TIER_ATTEMPTED) / len(tiers)
            ok(f"jev_tier: 25 attempts about a quarter (measured {share:.3f})", 0.21 < share < 0.29)
            ok("jev_tier: the rest are 'sampled-out', and nothing is 'disabled' at 25", set(tiers) == {TIER_ATTEMPTED, TIER_SAMPLED_OUT})
            ok("jev_tier: deterministic per entity_id", [jev_tier(i) for i in ids[:200]] == tiers[:200])

        # a sentinel whose check RAISES (permission denied on the logs dir) is ON: we cannot tell, so we do not send
        class _Unreadable:
            def exists(self) -> bool:
                raise PermissionError(13, "Permission denied")
        enabled.write_text("100\n")
        with mock.patch.object(mod, "JEV_ENABLED_FILE", enabled), mock.patch.object(mod, "JEV_DISABLED_SENTINEL", _Unreadable()):
            ok("jev_tier: a sentinel that cannot be checked (PermissionError) counts as set -> disabled", jev_tier("e") == TIER_DISABLED)

    # ---- env knobs cannot crash the import ----
    ok("_env_number: unset -> default", _env_number("CUT_OUTPUT_SHADOW__NOPE", 7, int, 1, 9) == 7)
    for junk, want in (("abc", 7), ("", 7), ("99", 7), ("0", 7), ("5", 5), ("nan", 7)):
        with mock.patch.dict(os.environ, {"CUT_OUTPUT_SHADOW__X": junk}):
            ok(f"_env_number({junk!r}) -> {want}", _env_number("CUT_OUTPUT_SHADOW__X", 7, float if junk == "nan" else int, 1, 9) == want)
    ok("the Jev deadline default is below the wrapper's 12 s watchdog", JEV_DEADLINE_S < 12.0)

    print(f"cut_output_jev selftest: passed={passed} failed={failed}")
    return 0 if failed == 0 else 1



RC = _selftest()
if __name__ == "__main__":
    sys.exit(RC)
