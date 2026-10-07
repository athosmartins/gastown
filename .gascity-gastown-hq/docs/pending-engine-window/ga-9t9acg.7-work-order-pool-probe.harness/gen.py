#!/usr/bin/env python3
"""Build the generated work-query shell commands WITHOUT compiling Go (ga-9t9acg.7).

Baseline  = the real commands printed by the live gc (`gc prime gastown.dog`), same tier assembly as
            engine-window-20260926 (only the label-filter jq differs between 0919 and 0926; the patch does
            not touch it).
Patched   = the baseline with the SAME textual edits the Go patch makes, where every new fragment is read
            out of the patched config.go (the raw-string literals of workOrderPickFunctionScript and the
            body of workOrderHeadStage), never retyped here. The edits are asserted to hit the number of
            sites the Go diff has, so a drift between this script and the Go fails loudly.
"""
import re, shlex, sys

PROMPT = sys.argv[1] if len(sys.argv) > 1 else None
GO = sys.argv[2] if len(sys.argv) > 2 else None


def go_func_body(src, name):
    m = re.search(r"^func " + re.escape(name) + r"\(.*?\) string \{\n(.*?)^\}\n", src, re.S | re.M)
    assert m, name
    return m.group(1)


def go_raw_literals(body):
    """Concatenate, in order, every backtick literal of a Go function made only of raw strings and '+'."""
    lits = re.findall(r"`([^`]*)`", body)
    # reject anything that is not a plain literal concatenation (a call, an if, a variable)
    stripped = re.sub(r"`[^`]*`", "", body)
    stripped = re.sub(r"return|\+|\s", "", stripped)
    assert stripped == "", "not a pure raw-literal function: %r" % stripped
    return "".join(lits)


def load(prompt_path, go_path):
    lines = open(prompt_path).read().split("\n")
    base = {}
    # The three commands are the only lines that start with `sh -c ` in `gc prime gastown.dog` (Step 1a, 1b, 1c, in
    # that order); the shipped baseline file holds just those three lines. Selected by shape, not by line number.
    cmds = [ln for ln in lines if ln.startswith("sh -c ")]
    assert len(cmds) == 3, "expected exactly 3 `sh -c ` command lines (in-progress, ready, routed), got %d" % len(cmds)
    for key, line in zip(("inprogress", "ready", "routed"), cmds):
        argv = shlex.split(line.strip())
        assert argv[:2] == ["sh", "-c"], (key, argv[:2])
        base[key] = argv  # ['sh','-c',script,('--',target)]
    src = open(go_path).read()
    wo_def = go_raw_literals(go_func_body(src, "workOrderPickFunctionScript"))
    # workOrderHeadStage: stage := `wo_pick`; if fallback != "" { stage += ` '` + fb + `'` }; return stage + `<tail>`
    hs = go_func_body(src, "workOrderHeadStage")
    tail = re.search(r"return stage \+ `([^`]*)`", hs).group(1)
    assert tail == " | jq -c '.[0:1]' 2>/dev/null", tail
    assert re.search(r"stage \+= ` '` \+ fallbackJQ \+ `'`", hs), "head-stage fallback shape changed"
    lru = re.search(r"const workOrderLRUFallbackJQ = `([^`]*)`", src).group(1)
    return base, wo_def, tail, lru, src


def head_stage(tail, fallback=""):
    return "wo_pick" + (" '" + fallback + "'" if fallback else "") + tail


def patch_script(key, script, tail, lru):
    """Mirror the Go diff on one baseline script (without the wo_pick definition, which every Go
    entry point prepends ONCE: workOrderPickFunctionScript())."""
    old_tail = " | jq -c '.[0:1]' 2>/dev/null"
    n_head = 0
    # tier 1 (routed): sort_by + slice in one jq -> wo_pick with the LRU fallback, then slice
    old_t1 = "| jq -c '" + lru + " | .[0:1]' 2>/dev/null; }"
    new_t1 = "| " + head_stage(tail, lru) + "; }"
    c = script.count(old_t1)
    script = script.replace(old_t1, new_t1)
    # every other tier: `... 2>/dev/null | jq -c '.[0:1]' 2>/dev/null)` -> `... 2>/dev/null | wo_pick | jq ...)`
    old_gen = " 2>/dev/null" + old_tail + ");"
    new_gen = " 2>/dev/null | " + head_stage(tail) + ");"
    g = script.count(old_gen)
    script = script.replace(old_gen, new_gen)
    # windows -> whole population
    s_asg = script.count("--json --limit=20")
    script = script.replace("--assignee=\"$id\" --json --limit=20", "--assignee=\"$id\" --json --limit 0")
    s_rt = script.count("--json --sort oldest --limit=20")
    script = script.replace("--json --sort oldest --limit=20", "--json --sort oldest --limit 0")
    # legacy ephemeral tier: `| sort_by(.created_at // "") | .[:20]` -> no slice
    s_eph = script.count(' | sort_by(.created_at // "") | .[:20]\'')
    script = script.replace(' | sort_by(.created_at // "") | .[:20]\'', ' | sort_by(.created_at // "")\'')
    expect = {
        "inprogress": dict(t1=0, gen=2, rt=0, eph=0),
        "ready": dict(t1=0, gen=2, rt=0, eph=0),
        "routed": dict(t1=1, gen=2, rt=2, eph=1),
    }[key]
    got = dict(t1=c, gen=g, rt=s_rt, eph=s_eph)
    assert got == expect, (key, got, expect)
    assert "--limit=20" not in script, key
    return script


if __name__ == "__main__":
    base, wo_def, tail, lru, src = load(PROMPT, GO)
    for k, argv in base.items():
        new = wo_def + patch_script(k, argv[2], tail, lru)
        print(k, "baseline", len(argv[2]), "-> patched", len(new), "chars; wo_pick uses:", new.count("wo_pick "))
