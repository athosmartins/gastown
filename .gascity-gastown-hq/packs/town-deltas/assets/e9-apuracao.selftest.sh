#!/bin/bash
# e9-apuracao.selftest.sh — ga-798p6w (E9): the contract of scripts/e9-apuracao.py, the experiment's readout.
#
# Run with:   /bin/bash e9-apuracao.selftest.sh
# The readout is run as a SUBPROCESS (the real CLI) against synthetic rosters, meter files and a throwaway git repo. The arms are
# not invented here: the fixtures ask the REAL rule (e9-arms.sh) which synthetic bead ids are `on` and which are `off`, exactly as
# the readout does. The promises held:
#   1. THREE STATES — an unknown cost is "unknown" (counted, out of the comparison), never US$ 0; "no plan_run row" (nothing spent) is
#      not "a run with no proven cost".
#   2. INTENTION TO TREAT — an `on` bead whose planner failed stays in `on`; a bead outside the roster is in neither arm.
#   3. THE PLANNER'S OWN COST IS IN THE PRIMARY METRIC — a plan that saves build cost but costs as much as it saves is not a win.
#   4. THE VERDICT IS THE PRE-REGISTERED RULE — too few beads is INCONCLUSIVO whatever the point estimate says.
#   5. IT NEVER INVENTS — no roster, no readable arms or a bad meter file => exit 2 and "NADA foi apurado", not an empty report.
# The last section is MUTATION CONTROLS: three of these invariants are broken on purpose in a copy of the readout.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE"
SCRIPTS="$(cd "$HERE/../../../scripts" && pwd)"
APUR="$SCRIPTS/e9-apuracao.py"
[ -r "$APUR" ] || { echo "FAIL: $APUR not readable" >&2; exit 1; }
[ -r "$ASSETS/e9-arms.sh" ] || { echo "FAIL: e9-arms.sh not readable" >&2; exit 1; }
[ -r "$SCRIPTS/pre-gate-apuracao.py" ] || { echo "FAIL: pre-gate-apuracao.py (the interval maths) not readable" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 missing" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git missing" >&2; exit 0; }

E9_SELFTEST_ASSETS="$ASSETS" E9_SELFTEST_SCRIPTS="$SCRIPTS" exec python3 - <<'PY'
import json, os, shutil, subprocess, sys, tempfile

ASSETS = os.environ["E9_SELFTEST_ASSETS"]
SCRIPTS = os.environ["E9_SELFTEST_SCRIPTS"]
APUR = os.path.join(SCRIPTS, "e9-apuracao.py")
W = tempfile.mkdtemp(prefix="e9-apuracao-selftest.")
PASS = FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print("  ok   " + m)


def bad(m):
    global FAIL
    FAIL += 1
    print("  FAIL " + m, file=sys.stderr)


def check(name, want, got):
    ok(name) if want == got else bad(f"{name} (got {got!r}, wanted {want!r})")


# a fake hq whose assets dir is the real one (the readout executes e9-arms.sh and E3's pregate rule from there)
HQ = os.path.join(W, "hq")
os.makedirs(os.path.join(HQ, "packs/town-deltas"))
os.symlink(ASSETS, os.path.join(HQ, "packs/town-deltas/assets"))
os.makedirs(os.path.join(HQ, ".gc"))

SALT, PCT = "t1", 50


def arms_of(ids, salt=SALT, pct=PCT):
    """Ask the REAL arm rule for a list of ids: {id: 'on'|'off'}."""
    d = tempfile.mkdtemp(dir=W)
    open(os.path.join(d, "e9-ab.conf"), "w").write(f"planner_pct={pct}\ncomplexity=on\nsalt={salt}\n")
    r = subprocess.run(["/bin/bash", os.path.join(ASSETS, "e9-arms.sh"), "arms", "planner"], input="\n".join(ids) + "\n",
                       capture_output=True, text=True, env=dict(os.environ, E9_STATE_DIR=d))
    assert r.returncode == 0, r.stderr
    return dict(line.split(" ") for line in r.stdout.splitlines())


POOL = arms_of([f"ga-s{i:04d}" for i in range(2400)])
ON_IDS = [b for b, v in POOL.items() if v == "on"]
OFF_IDS = [b for b, v in POOL.items() if v == "off"]
assert len(ON_IDS) > 400 and len(OFF_IDS) > 400, (len(ON_IDS), len(OFF_IDS))


def write_roster(path, assigns, runs=(), extra_lines=()):
    with open(path, "w") as f:
        for b, a in assigns:
            f.write(json.dumps({"ts": "2026-10-01T00:00:00Z", "event": "assign", "bead": b, "salt": SALT, "planner_arm": a,
                                "planner_pct": str(PCT), "stage": "pilot-dispatch", "store": "/s"}) + "\n")
        for r in runs:
            f.write(json.dumps(r) + "\n")
        for l in extra_lines:
            f.write(l + "\n")


def planned_rows(bead, cost, run_id=None, facts="arquivos=2 superficies=1 externo=0 migracao=0"):
    rid = run_id or f"r-{bead}"
    base = {"event": "plan_run", "bead": bead, "run_id": rid, "salt": SALT, "arm": "on", "launched": "true"}
    return [dict(base, ts="2026-10-01T00:01:00Z", verdict="PENDING", reason="launched", cost_known="false"),
            dict(base, ts="2026-10-01T00:05:00Z", verdict="PLANNED", reason="ok", cost_known="true", cost_usd=f"{cost:.6f}", facts=facts)]


def meter_rec(build, fp, approved=True, unpriced=0, review=1.0):
    return {"role": "wa-worker", "arm": "x", "via": "claim", "first_gate": "PASS" if fp else "FAIL", "ever_pass": approved,
            "gate_runs": 1 if fp else 2, "build_usd": build, "build_tokens": 1, "review_usd": review, "review_tokens": 1,
            "pregate_usd": 0.0, "unpriced_tokens": unpriced}


def run(roster, meter=None, *extra, hq=HQ, repo=None):
    cmd = [sys.executable, APUR, "--hq", hq, "--roster", roster, "--boot", "400", "--seed", "3"]
    if meter:
        cmd += ["--meter", meter]
    if repo:
        cmd += ["--repo", repo, "--ref", "HEAD"]
    cmd += list(extra)
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def verdict_of(out):
    lines = out.splitlines()
    for i, l in enumerate(lines):
        if l.startswith("8. VEREDITO"):
            return lines[i + 1].strip()
    return None


def scenario(n, on_build, off_build, on_fp, off_fp, planner=0.0, unknown_on=0, planner_unknown_on=0, tag="sc"):
    """n beads per arm. build cost = base(i) * factor; first-pass rate set by on_fp/off_fp (0-100). Returns (roster, meter) paths."""
    on, off = ON_IDS[:n], OFF_IDS[:n]
    assigns = [(b, "on") for b in on] + [(b, "off") for b in off]
    runs = []
    for i, b in enumerate(on):
        if i < planner_unknown_on:
            runs.append({"event": "plan_run", "bead": b, "run_id": f"r-{b}", "salt": SALT, "arm": "on", "launched": "true",
                         "ts": "2026-10-01T00:01:00Z", "verdict": "PENDING", "reason": "launched", "cost_known": "false"})
        else:
            runs += planned_rows(b, planner)
    meter = {}
    for i, b in enumerate(on):
        meter[b] = meter_rec((10 + i % 7) * on_build, (i % 100) < on_fp, unpriced=(5 if i < unknown_on else 0))
    for i, b in enumerate(off):
        meter[b] = meter_rec((10 + i % 7) * off_build, (i % 100) < off_fp)
    rp, mp = os.path.join(W, f"{tag}-roster.jsonl"), os.path.join(W, f"{tag}-meter.json")
    write_roster(rp, assigns, runs)
    json.dump({"beads": meter}, open(mp, "w"))
    return rp, mp


print("== 1. it never invents: unreadable inputs are exit 2, not an empty report ==")
rc, out, err = run(os.path.join(W, "nope.jsonl"))
check("no roster: exit 2", 2, rc)
ok("no roster: says NADA foi apurado") if "NADA foi apurado" in err else bad("no roster: silent: " + err)
empty = os.path.join(W, "empty.jsonl")
open(empty, "w").write("")
rc, out, err = run(empty)
check("an empty roster: exit 2 (an experiment that never ran is not 'zero beads')", 2, rc)
rp = os.path.join(W, "junk.jsonl")
open(rp, "w").write('not json\n12\nnull\n[1]\n{"event":"assign"}\n')
rc, out, err = run(rp)
check("a roster of only junk / assign rows with no bead, salt or arm: exit 2", 2, rc)
rp, mp = scenario(20, 1, 1, 50, 50, tag="badmeter")
open(mp, "w").write("{not json")
rc, out, err = run(rp, mp)
check("a meter file that is not JSON: exit 2", 2, rc)
json.dump({"nope": 1}, open(mp, "w"))
rc, out, err = run(rp, mp)
check("a JSON without 'beads' (not the meter's output): exit 2", 2, rc)
os.makedirs(os.path.join(W, "hq-empty/packs/town-deltas/assets"))
rc, out, err = run(rp, None, hq=os.path.join(W, "hq-empty"))
check("the arm rule (e9-arms.sh) cannot be run: exit 2 — 'no arm' is not 'off'", 2, rc)

print("== 2. roster and arms ==")
rp, mp = scenario(30, 1, 1, 50, 50, tag="s2")
rc, out, err = run(rp)
check("no --meter: exit 0 (a partial report is still a report)", 0, rc)
ok("no --meter: cost/approval are NÃO MEDIDOS, said out loud") if "NÃO MEDIDOS" in out else bad("no --meter: no NÃO MEDIDOS line")
check("no --meter: the verdict is INCONCLUSIVO, never a guess", "INCONCLUSIVO", verdict_of(out))
ok("all 60 assigned beads match the recomputed arm") if "confere com o recomputado: 60" in out else bad("arm match line missing:\n" + out[:600])
# a roster that lies about an arm is an anomaly, out of the count
lie = [(b, "on") for b in ON_IDS[:20]] + [(OFF_IDS[0], "on")] + [(b, "off") for b in OFF_IDS[1:20]]
rp2 = os.path.join(W, "lie.jsonl")
write_roster(rp2, lie)
rc, out, err = run(rp2)
ok("a roster arm that disagrees with the rule is listed as ANOMALIA") if "ANOMALIAS" in out and OFF_IDS[0] in out else bad("anomaly not reported:\n" + out[:600])
ok("... and left out of the count (39 of 40)") if "confere com o recomputado: 39" in out else bad("anomalous bead was counted")
# conflict: same bead assigned twice with different arms
rp3 = os.path.join(W, "conflict.jsonl")
write_roster(rp3, [(ON_IDS[0], "on"), (ON_IDS[0], "off"), (ON_IDS[1], "on")])
rc, out, err = run(rp3)
ok("the same bead with two arms: CONFLITO named, first assignment wins") if "CONFLITO" in out and ON_IDS[0] in out and "confere com o recomputado: 2" in out else bad("conflict not handled:\n" + out[:500])
# junk lines are counted, not ignored
rp4 = os.path.join(W, "junkline.jsonl")
write_roster(rp4, [(b, "on") for b in ON_IDS[:5]], extra_lines=["not json", "42"])
rc, out, err = run(rp4)
ok("unreadable roster lines are COUNTED") if "linhas ilegíveis no roster: 2" in out else bad("junk lines not counted:\n" + out[:500])
# another experiment's rows (a different salt) are not this experiment
rp5 = os.path.join(W, "salts.jsonl")
write_roster(rp5, [(b, "on") for b in ON_IDS[:5]])
with open(rp5, "a") as f:
    f.write(json.dumps({"ts": "2026-09-01T00:00:00Z", "event": "assign", "bead": "ga-old", "salt": "old", "planner_arm": "on", "planner_pct": "50"}) + "\n")
rc, out, err = run(rp5)
ok("the latest salt is the experiment; an older salt's rows are not mixed in") if "salt 't1'" in out and "atribuídas: 5" in out else bad("salts mixed:\n" + out[:400])
rc, out, err = run(rp5, None, "--salt", "old")
ok("--salt picks another experiment") if "salt 'old'" in out else bad("--salt ignored")

print("== 3. the pre-registered verdict ==")
rp, mp = scenario(200, 0.55, 1.0, 55, 55, tag="win")
rc, out, err = run(rp, mp)
check("on is 45% cheaper per approved bead, first-pass equal, n=200/arm: ADOTAR", "ADOTAR", verdict_of(out))
rp, mp = scenario(200, 1.0, 1.0, 55, 55, tag="flat")
rc, out, err = run(rp, mp)
check("no cost difference at n=200/arm: NÃO ADOTAR (the CI cannot reach -30%)", "NÃO ADOTAR", verdict_of(out))
rp, mp = scenario(12, 0.40, 1.0, 55, 55, tag="small")
rc, out, err = run(rp, mp)
check("a spectacular -60% on 12 beads/arm: INCONCLUSIVO (do not stop the experiment when the number pleases)", "INCONCLUSIVO", verdict_of(out))
rp, mp = scenario(200, 0.55, 1.0, 35, 60, tag="fpdrop")
rc, out, err = run(rp, mp)
check("45% cheaper but first-pass down 25 pp: NÃO ADOTAR (the approval guard)", "NÃO ADOTAR", verdict_of(out))
rp, mp = scenario(260, 0.55, 1.0, 55, 55, unknown_on=60, tag="unk")
rc, out, err = run(rp, mp)
check("23% of the on arm has an unknown cost (200 known, enough n): INDETERMINADO (never decided on a shrunken, biased sample)", "INDETERMINADO", verdict_of(out))
ok("the unknown-cost beads are COUNTED and shown, not silently dropped") if "SEM custo: 60" in out else bad("unknown cost not shown:\n" + out[:900])
rc, out, err = run(rp, mp, "--max-unknown-share", "0.5")
check("... --max-unknown-share is the knob (at 50% the same data is decided)", "ADOTAR", verdict_of(out))
# the planner's own cost is in the primary metric
rp, mp = scenario(200, 0.60, 1.0, 55, 55, planner=0.0, tag="p0")
rc, out, err = run(rp, mp)
check("build 40% cheaper, planner free: a win", "ADOTAR", verdict_of(out))
rp, mp = scenario(200, 0.60, 1.0, 55, 55, planner=6.0, tag="p6")
rc, out, err = run(rp, mp)
check("the same build saving, but the planner costs US$ 6 a bead: no longer a win — the planner is in the metric", "NÃO ADOTAR", verdict_of(out))
# a planner run with no proven cost makes the bead's cost UNKNOWN, not planner-free
rp, mp = scenario(260, 0.55, 1.0, 55, 55, planner_unknown_on=60, tag="punk")
rc, out, err = run(rp, mp)
check("60 of 260 on beads whose planner run has no proven cost (PENDING only): INDETERMINADO, not 'planner US$ 0'", "INDETERMINADO", verdict_of(out))
ok("the planner spend is reported as a LOWER BOUND when some runs are unknown") if "LIMITE INFERIOR" in out else bad("no lower-bound warning:\n" + out[:800])
# determinism
rp, mp = scenario(200, 0.55, 1.0, 55, 55, tag="win")
a1 = run(rp, mp)[1]; a2 = run(rp, mp)[1]
check("a rerun with the same seed prints the same report", a1, a2)
j = json.loads(run(rp, mp, "--json")[1])
check("--json: the same verdict, machine-readable", "ADOTAR", j["verdict"])

print("== 4. intention to treat and the roster as the denominator ==")
rp, mp = scenario(200, 0.55, 1.0, 55, 55, tag="itt")
# turn 40 of the on-arm planner runs into failures: those beads must STAY in `on`
rows = [json.loads(l) for l in open(rp)]
failed = 0
for r in rows:
    if r.get("event") == "plan_run" and r["verdict"] == "PLANNED" and failed < 40:
        r.update(verdict="INCONCLUSIVE", reason="machine-guard:disk-low:8GiB<10GiB", cost_known="false")
        r.pop("cost_usd", None)
        failed += 1
with open(rp, "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
rc, out, err = run(rp, mp)
ok("40 on beads whose planner was INCONCLUSIVE are still in the on arm (n=200 on)") if "on 200 / off 200" in out else bad("ITT: arm sizes changed:\n" + out[:500])
ok("... and the adherence line says 160/200 = 80%, apart from the comparison") if "aderência (planejado / atribuídas on): 80%" in out else bad("adherence wrong:\n" + out[:900])
ok("... the failure reason is its own row") if "inconclusivo: machine-guard" in out else bad("failure class missing")
# a meter bead outside the roster is in neither arm
mt = json.load(open(mp))
mt["beads"]["ga-ghost1"] = meter_rec(5.0, True)
mt["beads"]["ga-ghost2"] = meter_rec(5.0, False)
json.dump(mt, open(mp, "w"))
rc, out, err = run(rp, mp)
ok("meter beads that were never on the roster are COUNTED as fora do roster (2) and excluded") if "fora do roster (não receberam a dica; não entram): 2" in out else bad("ghosts not counted:\n" + out[:700])
# a roster bead the meter HAS but the gate has not ruled on (first_gate missing, or null) is out of the comparison and COUNTED per arm —
# before this was counted nowhere: the report said "N with a verdict, 0 not yet measured" while those beads simply vanished, and if
# beads stalled more in one arm the comparison would have dropped them without a trace
mt = json.load(open(mp))
for b in ON_IDS[:3]:
    mt["beads"][b].pop("first_gate", None)
mt["beads"][OFF_IDS[0]]["first_gate"] = None
json.dump(mt, open(mp, "w"))
rc, out, err = run(rp, mp)
ok("meter beads with no gate verdict yet are COUNTED per arm (on 3 / off 1), not silently dropped") \
    if "SEM veredito do gate ainda (fora da conta; contadas): on 3 / off 1" in out else bad("no-verdict beads not counted:\n" + out[:900])
ok("... and they are out of the comparison (the verdict population shrank by 4)") \
    if "beads do medidor com veredito do gate: 396" in out else bad("no-verdict beads leaked into the population:\n" + out[:900])
# on beads with NO plan_run row at all = nothing spent
rp, mp = scenario(30, 0.9, 1.0, 55, 55, tag="norow")
rows = [json.loads(l) for l in open(rp)]
kept = [r for r in rows if not (r.get("event") == "plan_run" and r["bead"] in ON_IDS[:10])]
with open(rp, "w") as f:
    for r in kept:
        f.write(json.dumps(r) + "\n")
rc, out, err = run(rp, mp)
ok("an on bead with no run row is 'sem run lançado' (10), NOT claimed to be a builder that ignored the hint — and its planner cost is a KNOWN zero, so it is not an unknown-cost bead") \
    if "sem run lançado (recusa antes de lançar OU dica ignorada" in out and "nunca rodou" not in out and "SEM custo" not in out else bad("no-row handling wrong:\n" + out[:900])

print("== 5. realized size, calibration, PLAN-DEVIATION (git) ==")
REPO = os.path.join(W, "repo")
os.makedirs(REPO)
env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
def git(*a, **kw):
    return subprocess.run(["git", "-C", REPO] + list(a), capture_output=True, text=True, env=env, **kw)
git("init", "-q", "-b", "main")
rp, mp = scenario(30, 0.9, 1.0, 55, 55, tag="git")
def commit(bead, files, body=""):
    for f in files:
        p = os.path.join(REPO, f)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "a").write(bead + "\n")
    git("add", "-A")
    msg = f"fix({bead}): change" + (f"\n\n{body}" if body else "")
    git("commit", "-q", "-m", msg)
# bead A (on, planned arquivos=2): realized 2 code files + a doc  -> S, within ±1
commit(ON_IDS[0], ["lib/a.py", "lib/b.py", "docs/note.md"])
# bead B (on, planned arquivos=2): realized 9 files, declares a deviation -> L, prediction off by 7
commit(ON_IDS[1], [f"src/f{i}.py" for i in range(9)], body="PLAN-DEVIATION: the guard lived in another module")
# bead C (off): 4 files -> M
commit(OFF_IDS[0], [f"m/{i}.py" for i in range(4)])
# a fix attempt for bead C in a second commit: the files UNION, not the last commit
commit(OFF_IDS[0], ["m/9.py"])
rc, out, err = run(rp, mp, repo=REPO)
check("with --repo: exit 0", 0, rc)
ok("bead A (2 code files + a doc) is class S: docs do not count") if "S on  n=  1" in out or "S on  n=1" in out.replace("  ", " ") else bad("class S missing:\n" + out)
ok("bead B (9 files) is class L") if "L on  n=  1" in out else bad("class L wrong:\n" + out)
ok("bead C's two commits are one bead: 5 files = class M (the UNION, not the last commit)") if "M off n=  1" in out else bad("class M/union wrong:\n" + out)
ok("a bead with no merged commit is in the NÃO MEDIDA bucket, not in a class") if "sem commit mergeado achado" in out else bad("no-commit bucket missing")
ok("calibration: 2 beads, predicted 2 and 2 vs realized 2 and 9 -> ±1 file for 50%") if "n=2" in out and "±1 arquivo: 50%" in out else bad("calibration wrong:\n" + out)
ok("PLAN-DEVIATION: 1 of 2 planned+merged beads declared one") if "PLAN-DEVIATION declarado: 1/2" in out else bad("deviation count wrong:\n" + out)
rc, out, err = run(rp, mp, repo=os.path.join(W, "not-a-repo"))
ok("a --repo that is not a checkout: strata/calibration are NÃO MEDIDOS (not zero files)") if "NÃO MEDIDO: git log" in out else bad("bad repo not reported:\n" + out[:900])
rc, out, err = run(rp, mp)
ok("no --repo: the same, asked for out loud") if "passe --repo" in out else bad("no --repo hint")

print("== 6. independence from E3's coin ==")
rp, mp = scenario(200, 0.55, 1.0, 55, 55, tag="ind")
rc, out, err = run(rp, mp)
ok("the E9 and pregate arms are independent on 400 beads (chi-square p >= 0.05)") if "(independentes)" in out else bad("independence line:\n" + "\n".join(l for l in out.splitlines() if "independência" in l))

print("== 7. mutation controls — invariants broken on purpose in a copy of the readout ==")
MUT = os.path.join(W, "mut-scripts")
os.makedirs(MUT)
shutil.copy(os.path.join(SCRIPTS, "pre-gate-apuracao.py"), MUT)
def mutant(name, old, new, scenario_fn, expect_unmutated, expect_mutant_differs=True):
    src = open(APUR).read()
    if old not in src:
        bad(f"mutant '{name}': the target text is not in e9-apuracao.py any more — the selftest is stale")
        return
    open(os.path.join(MUT, "e9-apuracao.py"), "w").write(src.replace(old, new, 1))
    got_mut = scenario_fn(os.path.join(MUT, "e9-apuracao.py"))
    got_ok = scenario_fn(APUR)
    if got_ok != expect_unmutated:
        bad(f"mutant '{name}': the UNMUTATED readout gives {got_ok!r}, not {expect_unmutated!r} — the control is broken")
    elif got_mut == got_ok:
        bad(f"mutant '{name}' SURVIVED (same verdict {got_ok!r}) — nothing in this selftest notices: {new}")
    else:
        ok(f"mutant '{name}' killed ({got_ok} -> {got_mut})")
def with_script(path):
    def f(rp, mp):
        r = subprocess.run([sys.executable, path, "--hq", HQ, "--roster", rp, "--meter", mp, "--boot", "400", "--seed", "3"], capture_output=True, text=True)
        return verdict_of(r.stdout)
    return f
rp_p6, mp_p6 = scenario(200, 0.60, 1.0, 55, 55, planner=6.0, tag="m1")
mutant("the planner's cost is left out of the metric",
       "mc, pc = meter_cost(rec), planner_cost(runs_by_bead.get(b, []))", "mc, pc = meter_cost(rec), 0.0",
       lambda p: with_script(p)(rp_p6, mp_p6), "NÃO ADOTAR")
rp_unk, mp_unk = scenario(260, 0.55, 1.0, 55, 55, unknown_on=60, tag="m2")
mutant("an unknown (unpriced) cost counts as US$ 0",
       'if unpriced is None or unpriced > 0:\n        return None', 'if unpriced is None:\n        return None',
       lambda p: with_script(p)(rp_unk, mp_unk), "INDETERMINADO")
rp_small, mp_small = scenario(12, 0.40, 1.0, 55, 55, tag="m3")
mutant("the minimum-n rule is dropped",
       "if min(n_known.values()) < a.min_n:", "if False:",
       lambda p: with_script(p)(rp_small, mp_small), "INCONCLUSIVO")
rp_fp, mp_fp = scenario(200, 0.55, 1.0, 35, 60, tag="m4")
mutant("the approval guard is dropped (fp_bad ignored, fp_ok forced)",
       "fp_ok = (d >= -a.max_fp_drop) and (dlo >= -a.fp_ci_floor)", "fp_ok = True",
       lambda p: with_script(p)(rp_fp, mp_fp), "NÃO ADOTAR")
rp_itt, mp_itt = scenario(200, 0.55, 1.0, 55, 55, tag="m5")
rows = [json.loads(l) for l in open(rp_itt)]
n_fail = 0
for r in rows:
    if r.get("event") == "plan_run" and r["verdict"] == "PLANNED" and n_fail < 120:
        r.update(verdict="INCONCLUSIVE", reason="timeout:900s", cost_known="false"); r.pop("cost_usd", None); n_fail += 1
with open(rp_itt, "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
def itt_adopt(p):
    r = subprocess.run([sys.executable, p, "--hq", HQ, "--roster", rp_itt, "--meter", mp_itt, "--boot", "400", "--seed", "3"], capture_output=True, text=True)
    first = [l for l in r.stdout.splitlines() if l.strip().startswith("on  beads com custo conhecido")]
    return first[0].split("beads com custo conhecido")[1].split()[0] if first else None
mutant("intention to treat is broken: an on bead whose planner failed leaves the arm",
       "arm[b] = rc", "if not (rc == 'on' and not any(x.get('bead') == b and x.get('verdict') == 'PLANNED' for x in run_rows)): arm[b] = rc",
       itt_adopt, "80/200")

shutil.rmtree(W, ignore_errors=True)
print(f"\ne9-apuracao selftest: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
PY
