#!/bin/bash
# e12-builder-coverage.selftest.sh — ga-57e7l0 (a): the write-time doctrine reaches EVERY builder, not only the ones the Pilot messages.
#
# WHY. The Pilot appends the block to a dispatch MESSAGE (e12-arms.sh). Measured 16/10 (roster x gate log, treated_pct=100): 70% of the
# beads the gate reviewed have no roster row, and the Pilot's own pool path never sends the text: dispatch_one() builds DISPATCH_TASK,
# writes the roster row, then spawns a bare `gc session new wa-worker|ps-worker` — the message is dropped. Pool top-up (Step 2d) and a
# gate FAIL (the bead goes back to the pool and a worker serves itself) have no message either. For those builders the PROMPT is the
# only channel, so the prompt carries the block:
#     dog / wa-worker / ps-worker   a guarded section of the town-deltas fragment (TD_ROLE), plain text
#     every other crew that builds  a marked region in its own prompt template (the ga-0nz1wi mechanism)
# both generated from e12_block_text by e12-crew-doctrine.sh, which also has `coverage`: a builder prompt that nothing covers is a failure.
#
#   A. real tree    `check` (every target is a fresh render) and `coverage` pass; the targets are the ones this story added
#   B. real engine  `gc prime --strict` on the REAL wa-worker / ps-worker / batista-ps prompts and the real fragment: the block is in the
#                   rendered prompt exactly once and equals the Pilot's text; a role that must not get it (reviewer) does not
#   C. controls     each way coverage can silently stop being true must FAIL here: a new builder prompt nothing covers, a guard that lost
#                   a role or that shows the block to crews twice, a role no agent has, a city.toml that cannot be read (rc 2, not "ok"),
#                   a fragment section that drifted or lost its guard
#   D. gate wiring  step 2d of formulas/mol-quality-gate-runner.toml, extracted and run against fixture worktrees: it fails the gate (1 gap,
#                   2 cannot tell) when the diff touches a file that decides coverage and the tree is not covered, runs nothing for any
#                   other diff, keeps a prior failure, and is a loud no-op behind its kill switch
# Hermetic: scratch dir only; needs python3 and the `gc` binary (E12B_GC). Env: E12B_HQ (city root, default: three levels up), E12B_KEEP=1.
# bash 3.2 safe: no arrays, no mapfile.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ="${E12B_HQ:-$(cd "$HERE/../../.." && pwd)}"
GC="${E12B_GC:-gc}"
GEN="$HERE/e12-crew-doctrine.sh"
ARMS="$HERE/e12-arms.sh"
FRAG="$HQ/packs/town-deltas/template-fragments/town-deltas.template.md"
HEADER='## Write-time doctrine — experiment E12'

PASS=0; FAILN=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAILN=$((FAILN+1)); printf '  FAIL %s\n' "$1" >&2; }

[ -r "$GEN" ] && [ -r "$ARMS" ] && [ -r "$FRAG" ] && [ -f "$HQ/city.toml" ] || { echo "FATAL: generator/arms/fragment/city.toml not found under $HQ" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 missing" >&2; exit 2; }
W="$(mktemp -d "${TMPDIR:-/tmp}/e12-builder-coverage.XXXXXX")" || { echo "FATAL: no scratch dir" >&2; exit 2; }
case "$W" in /?*) ;; *) echo "FATAL: unusable scratch path '$W'" >&2; exit 2 ;; esac
REACHED_END=0
finish() {
  local rc=$?
  chmod -R u+rw "$W" 2>/dev/null
  if [ "${E12B_KEEP:-0}" = 1 ]; then echo "(kept: $W)"
  elif command -v safe-clean >/dev/null 2>&1 && safe-clean --check "$W" >/dev/null 2>&1; then safe-clean "$W" >/dev/null 2>&1
  else echo "(scratch dir left behind: $W — safe-clean does not cover this location)"; fi
  if [ "$REACHED_END" != 1 ] && [ "$rc" = 0 ]; then echo "FAIL: selftest aborted before its last line" >&2; exit 1; fi
}
trap finish EXIT

# gen <root> <check|coverage|write>: the generator, as a subprocess, against the agents/, fragment and city.toml under <root>.
RC=0; ERR=""
gen() {
  E12_CREW_AGENTS_DIR="$1/agents" E12_FRAGMENT="$1/town-deltas.template.md" E12_CITY_TOML="$1/city.toml" /bin/bash "$GEN" "$2" >"$W/gen.out" 2>"$W/gen.err"
  RC=$?; ERR="$(cat "$W/gen.err")"
}
# mkroot <name>: a copy of what the generator reads (all agent prompts, the fragment, city.toml). One directory per scenario.
mkroot() {
  local d="$W/$1"; mkdir -p "$d" && cp -R "$HQ/agents" "$d/agents" && cp "$FRAG" "$d/town-deltas.template.md" && cp "$HQ/city.toml" "$d/city.toml" || return 1
  printf '%s' "$d"
}
edit() { sed "$2" "$1" > "$1.new" && ! cmp -s "$1" "$1.new" && mv "$1.new" "$1"; }   # rc 1 = the edit changed nothing

echo "== A. real tree: every target is current and every builder is covered =="
E12_CREW_AGENTS_DIR="$HQ/agents" E12_FRAGMENT="$FRAG" E12_CITY_TOML="$HQ/city.toml" /bin/bash "$GEN" check >"$W/a.out" 2>"$W/a.err"; rc=$?
[ "$rc" = 0 ] && ok "check on the real tree: $(cat "$W/a.out")" || bad "check on the real tree: rc=$rc $(cat "$W/a.err")"
grep -q '(10 targets)' "$W/a.out" && ok "the targets are the 6 crews + batista-ps, batista-lx, thies-ps + the fragment section" || bad "expected '(10 targets)', got: $(cat "$W/a.out")"
E12_CREW_AGENTS_DIR="$HQ/agents" E12_FRAGMENT="$FRAG" E12_CITY_TOML="$HQ/city.toml" /bin/bash "$GEN" coverage >"$W/a.out" 2>"$W/a.err"; rc=$?
[ "$rc" = 0 ] && ok "coverage on the real tree passes" || bad "coverage on the real tree: rc=$rc $(cat "$W/a.err")"
for who in wa-worker ps-worker batista-ps thies-ps "dog"; do
  grep -q "$who" "$W/a.out" && ok "coverage names $who as covered" || bad "coverage does not mention $who: $(cat "$W/a.out")"
done

echo "== B. real engine: gc prime --strict on the real prompts =="
PILOT="$(E12_STATE_DIR="$W" /bin/bash "$ARMS" block ga-covtest /nonexistent pilot-dispatch --no-record 2>/dev/null)"
printf 'treated_pct=100\n' > "$W/e12-ab.conf"
PILOT="$(E12_STATE_DIR="$W" /bin/bash "$ARMS" block ga-covtest /nonexistent pilot-dispatch --no-record 2>/dev/null)"; printf '%s' "$PILOT" > "$W/pilot.txt"
case "$PILOT" in "$HEADER"*) ok "the Pilot's text (the reference) starts with the E12 header" ;; *) bad "could not get the Pilot's text" ;; esac
cat > "$W/engine.py" <<'PYEOF'
import os, subprocess, sys
from pathlib import Path
hq, gc, work = Path(os.environ["B_HQ"]), os.environ["B_GC"], Path(os.environ["B_WORK"])
pilot = Path(os.environ["B_PILOT"]).read_text(encoding="utf-8")
CITY = ('[workspace]\nprovider = "claude"\nglobal_fragments = ["town-deltas"]\n\n[providers]\n[providers.claude]\nbase = "builtin:claude"\n\n'
        '[imports]\n[imports.town-deltas]\nsource = "packs/town-deltas"\n')
# (agent dir in the repo or None for a synthetic prompt, TD_ROLE, expected number of blocks in the rendered prompt)
cases = [("wa-worker", "wa-worker", 1), ("ps-worker", "ps-worker", 1), (None, "dog", 1), ("batista-ps", None, 1), (None, "reviewer", 0), (None, None, 0)]
root = work / "city"; (root / ".gc").mkdir(parents=True); (root / "gchome").mkdir()
(root / "pack.toml").write_text('[pack]\nname = "scratch"\nschema = 2\n'); (root / "city.toml").write_text(CITY)
os.symlink(hq / "packs", root / "packs")
names = []
for i, (src, role, _) in enumerate(cases):
    name = src or f"synthetic-{role or 'unset'}"; names.append(name)
    d = root / "agents" / name; d.mkdir(parents=True)
    env = f'env = {{ TD_ROLE = "{role}" }}\n' if role else ""
    (d / "agent.toml").write_text('max_active_sessions = 1\nmin_active_sessions = 0\nscope = "city"\n' + env)
    text = (hq / "agents" / src / "prompt.template.md").read_text(encoding="utf-8") if src else f"# {name}\nBODY\n"
    (d / "prompt.template.md").write_text(text)
clean = {k: v for k, v in os.environ.items() if not k.startswith("GC_")}; clean["GC_HOME"] = str(root / "gchome")
for name, (src, role, want) in zip(names, cases):
    r = None
    for _ in range(2):                       # one retry: the gc can be under load; a persistent error fails
        r = subprocess.run([gc, "--city", str(root), "prime", "--strict", name], cwd=root, env=clean, capture_output=True, text=True, timeout=120)
        if r.returncode == 0: break
    if r.returncode != 0:
        print(f"bad {name}: gc prime --strict rc={r.returncode}: {r.stderr.strip()[:200]}"); continue
    n = r.stdout.count(pilot)
    print(("ok" if n == want else "bad") + f" {name} (TD_ROLE={role}): the Pilot's block appears {n} time(s) in the rendered prompt (expected {want})")
PYEOF
if ! command -v "$GC" >/dev/null 2>&1; then bad "gc not found ('$GC') — set E12B_GC"; else
  B_HQ="$HQ" B_GC="$GC" B_WORK="$W" B_PILOT="$W/pilot.txt" python3 -I "$W/engine.py" > "$W/engine.out" 2> "$W/engine.err"; erc=$?
  neng=0
  while IFS= read -r line; do
    case "$line" in "ok "*) neng=$((neng+1)); ok "${line#ok }" ;; "bad "*) neng=$((neng+1)); bad "${line#bad }" ;; *) bad "unexpected engine output: $line" ;; esac
  done < "$W/engine.out"
  [ "$erc" = 0 ] && [ "$neng" = 6 ] && ok "the engine half ran all 6 cases" || bad "the engine half ran $neng case(s), rc=$erc: $(tail -n 3 "$W/engine.err" | tr '\n' ' ')"
fi

echo "== C. controls: every way coverage can silently stop being true must fail =="
d="$(mkroot twin)" || { bad "C: could not copy the real tree"; d=""; }
if [ -n "$d" ]; then
gen "$d" check;    [ "$RC" = 0 ] && ok "twin: an unmutated copy checks current" || bad "twin check: rc=$RC $ERR"
gen "$d" coverage; [ "$RC" = 0 ] && ok "twin: an unmutated copy is fully covered" || bad "twin coverage: rc=$RC $ERR"

d="$(mkroot newbuilder)"; mkdir -p "$d/agents/zed-wa"; printf '# zed\nWhen done run /gate-done.\n' > "$d/agents/zed-wa/prompt.template.md"
gen "$d" coverage
if [ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'zed-wa'; then ok "a new builder prompt (mentions /gate-done) that nothing covers: rc 1, names zed-wa"; else bad "uncovered builder: rc=$RC $ERR"; fi

d="$(mkroot lostrole)"; edit "$d/town-deltas.template.md" 's/(eq .TD_ROLE "dog") (eq .TD_ROLE "ps-worker") (eq .TD_ROLE "wa-worker") -}}{{\/\* td:e12-write-time-doctrine/(eq .TD_ROLE "ps-worker") (eq .TD_ROLE "wa-worker") -}}{{\/\* td:e12-write-time-doctrine/' || bad "lost-role control: the edit changed nothing"
gen "$d" coverage
if [ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'dog'; then ok "the guard lost the dog role: rc 1, names dog"; else bad "lost role: rc=$RC $ERR"; fi

d="$(mkroot showunset)"; edit "$d/town-deltas.template.md" 's/{{ if or (eq .TD_ROLE "dog")\(.*td:e12-write-time-doctrine\)/{{ if or (not .TD_ROLE) (eq .TD_ROLE "dog")\1/' || bad "show-unset control: the edit changed nothing"
gen "$d" coverage
if [ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'no TD_ROLE'; then ok "the guard shows the block to agents with no TD_ROLE (crews would carry it twice): rc 1"; else bad "show-unset: rc=$RC $ERR"; fi

d="$(mkroot norole)"; python3 -I - "$d/city.toml" <<'PYEOF' || bad "no-role control: could not edit city.toml"
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
n = re.sub(r'(name = "wa-worker"\noverlay_dir = "[^"]*"\n)env = \{ TD_ROLE = "wa-worker" \}\n', r'\1', s, count=1)
if n == s: sys.exit(1)
open(p, "w", encoding="utf-8").write(n)
PYEOF
gen "$d" coverage
if [ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'wa-worker'; then ok "no agent has TD_ROLE=wa-worker any more (the section would never render): rc 1"; else bad "no role: rc=$RC $ERR"; fi

d="$(mkroot nocity)"; rm -f "$d/city.toml"
gen "$d" coverage
[ "$RC" = 2 ] && ok "city.toml cannot be read: coverage says CANNOT TELL (rc 2), not 'covered'" || bad "no city.toml: rc=$RC (expected 2) $ERR"

d="$(mkroot drift)"; edit "$d/town-deltas.template.md" "s/in last week's gate reviews/in the last weeks' gate reviews/" || bad "drift control: the edit changed nothing"
gen "$d" check
if [ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'town-deltas.template.md'; then ok "a drifted fragment section: check says STALE (rc 1) and names the fragment"; else bad "drift: rc=$RC $ERR"; fi
gen "$d" write; rc_w=$RC; gen "$d" check
if [ "$rc_w" = 0 ] && [ "$RC" = 0 ] && cmp -s "$d/town-deltas.template.md" "$FRAG"; then ok "write restores the fragment section byte for byte, and check agrees"; else bad "write after drift: write rc=$rc_w check rc=$RC identical=$(cmp -s "$d/town-deltas.template.md" "$FRAG" && echo yes || echo NO)"; fi

d="$(mkroot noguard)"; edit "$d/town-deltas.template.md" 's/td:e12-write-time-doctrine/td:e12-gone/' || bad "no-guard control: the edit changed nothing"
before="$(cksum < "$d/town-deltas.template.md")"
gen "$d" check; rc_c=$RC; gen "$d" write; rc_w=$RC
if [ "$rc_c" = 1 ] && [ "$rc_w" = 2 ] && [ "$before" = "$(cksum < "$d/town-deltas.template.md")" ]; then ok "the fragment lost its section: check rc 1, write refuses (rc 2) and touches nothing"; else bad "no guard: check rc=$rc_c write rc=$rc_w"; fi
fi


echo "== D. gate wiring: step 2d of mol-quality-gate-runner.toml =="
FORMULA="$HQ/formulas/mol-quality-gate-runner.toml"
# vazio (markers/body ausentes) → FAIL "snippet present" and no wiring test runs; falhou (formula ilegível) → awk gives empty = the same FAIL, never a pass
SNIPPET="$(awk '/SELFTEST-EXTRACT e12-coverage-step2d: BEGIN/{f=1;next} /SELFTEST-EXTRACT e12-coverage-step2d: END/{f=0} f' "$FORMULA" 2>/dev/null)"
if [ -z "$SNIPPET" ]; then
  bad "step 2d snippet present in the formula (no SELFTEST-EXTRACT e12-coverage-step2d markers/body in $FORMULA)"
else
  ok "step 2d snippet present in the formula"
  printf '%s' "$SNIPPET" | grep -q '\\' && bad "snippet has no backslash (a TOML basic string would eat it)" || ok "snippet has no backslash (TOML \"\"\" strings would eat it)"
  printf '%s\n' "$SNIPPET" > "$W/snippet.body"
  { printf 'TEST_EXIT=${PRE_TEST_EXIT:-0}\nTEST_OUTPUT=""\nCHANGED_FILES="$CHG"\n'; cat "$W/snippet.body"; printf '\necho "__TEST_EXIT=$TEST_EXIT"\necho "__TEST_OUTPUT_BEGIN"\necho "$TEST_OUTPUT"\n'; } > "$W/snippet.sh"
  /bin/bash -n "$W/snippet.sh" 2>/dev/null && ok "snippet parses under /bin/bash (3.2)" || bad "snippet parses under /bin/bash (syntax error)"
  python3 -I - "$FORMULA" "$W/snippet.body" <<'PYEOF' && ok "formula is valid TOML and the snippet round-trips verbatim" || bad "TOML round-trip: formula invalid or snippet mangled"
import sys, tomllib
f = tomllib.load(open(sys.argv[1], "rb"))
snip = open(sys.argv[2], encoding="utf-8").read().strip()
steps = [s for s in f["steps"] if s.get("id") == "run-tests"]
assert len(steps) == 1, "run-tests step missing"
assert snip in steps[0]["description"], "snippet altered by TOML parsing"
PYEOF

  # mkwt <name>: a worktree with the city under .gascity-gastown-hq/ (what the gascity rig's repo looks like) and a city with the generator
  mkwt() {
    local d="$W/$1" h="$W/$1/wt/.gascity-gastown-hq" a
    a="$h/packs/town-deltas/assets"
    mkdir -p "$a" "$h/packs/town-deltas/template-fragments" "$h/packs/town-deltas/assets/claude-overlays" "$W/$1/city/.gc" || return 1
    cp -R "$HQ/agents" "$h/agents" && cp "$HQ/city.toml" "$h/city.toml" && cp "$FRAG" "$h/packs/town-deltas/template-fragments/" \
      && cp "$ARMS" "$GEN" "$a/" && cp "$HQ/packs/town-deltas/assets/claude-overlays/pool-roles.json" "$a/claude-overlays/" || return 1
    printf '%s' "$d"
  }
  # run2d <scenario dir> <changed files, one per line> [VAR=value ...] → W_OUT (everything the snippet printed), W_RC (the TEST_EXIT it ended with)
  run2d() {
    local d="$1" chg="$2"; shift 2
    W_OUT="$(env "$@" CHG="$chg" WORKTREE_PATH="$d/wt" GC_CITY_PATH="$d/city" /bin/bash "$W/snippet.sh" 2>&1)"
    # vazio (the snippet died before printing __TEST_EXIT) → W_RC empty and every check below counts it as FAIL; none accepts empty as 0
    W_RC="$(printf '%s\n' "$W_OUT" | sed -n 's/^__TEST_EXIT=//p' | tail -1)"
  }
  HQP=".gascity-gastown-hq"
  TOUCH_PROMPT="$HQP/agents/thies-ps/prompt.template.md"

  d="$(mkwt clean)"
  run2d "$d" "$TOUCH_PROMPT"
  if [ "$W_RC" = 0 ] && printf '%s' "$W_OUT" | grep -q 'coverage ok' && printf '%s' "$W_OUT" | grep -q 'current (10 targets)'; then ok "a covered tree: a prompt in the diff -> check and coverage run, TEST_EXIT 0"; else bad "covered tree: TEST_EXIT=$W_RC :: $W_OUT"; fi

  d="$(mkwt drift)"; edit "$d/wt/$HQP/packs/town-deltas/template-fragments/town-deltas.template.md" "s/in last week's gate reviews/in the last weeks' gate reviews/" || bad "drift fixture: the edit changed nothing"
  for f in "$TOUCH_PROMPT" "$HQP/city.toml" "$HQP/packs/town-deltas/template-fragments/town-deltas.template.md" "$HQP/packs/town-deltas/assets/e12-arms.sh" \
           "$HQP/packs/town-deltas/assets/e12-crew-doctrine.sh" "$HQP/packs/town-deltas/assets/claude-overlays/pool-roles.json"; do
    run2d "$d" "$f"
    if [ "$W_RC" = 1 ] && printf '%s' "$W_OUT" | grep -q 'E12 COVERAGE FAILED' && printf '%s' "$W_OUT" | grep -q 'town-deltas.template.md'; then ok "a stale fragment + a diff touching ${f#$HQP/} -> TEST_EXIT 1, names the fragment"; else bad "stale fragment + ${f#$HQP/}: TEST_EXIT=$W_RC :: $W_OUT"; fi
  done
  for f in "$HQP/agents/thies-ps/agent.toml" "elsewhere/agents/thies-ps/prompt.template.md" "$HQP/docs/note.md"; do
    run2d "$d" "$f"
    if [ "$W_RC" = 0 ] && ! printf '%s' "$W_OUT" | grep -q 'current\|coverage ok\|FAILED'; then ok "the same stale tree + a diff touching only '$f' -> nothing runs, TEST_EXIT 0"; else bad "unrelated diff '$f': TEST_EXIT=$W_RC :: $W_OUT"; fi
  done
  run2d "$d" "$TOUCH_PROMPT" PRE_TEST_EXIT=1
  [ "$W_RC" = 1 ] && ok "a prior test failure (1) stays a failure" || bad "prior failure: TEST_EXIT=$W_RC"
  run2d "$d" "$TOUCH_PROMPT" E12_COVERAGE_GATE=off
  if [ "$W_RC" = 0 ] && printf '%s' "$W_OUT" | grep -q 'switched OFF'; then ok "kill switch (env): the same stale tree passes, loudly"; else bad "kill switch env: TEST_EXIT=$W_RC :: $W_OUT"; fi
  : > "$d/city/.gc/e12-coverage-gate.off"
  run2d "$d" "$TOUCH_PROMPT"
  if [ "$W_RC" = 0 ] && printf '%s' "$W_OUT" | grep -q 'switched OFF'; then ok "kill switch (flag file): the same stale tree passes, loudly"; else bad "kill switch flag: TEST_EXIT=$W_RC :: $W_OUT"; fi

  d="$(mkwt newbuilder)"; mkdir -p "$d/wt/$HQP/agents/zed-wa"; printf '# zed\nWhen done run /gate-done.\n' > "$d/wt/$HQP/agents/zed-wa/prompt.template.md"
  run2d "$d" "$HQP/agents/zed-wa/prompt.template.md"
  if [ "$W_RC" = 1 ] && printf '%s' "$W_OUT" | grep -q 'zed-wa'; then ok "a new builder prompt nothing covers -> TEST_EXIT 1, names zed-wa"; else bad "new builder: TEST_EXIT=$W_RC :: $W_OUT"; fi

  d="$(mkwt nocity)"; rm -f "$d/wt/$HQP/city.toml"
  run2d "$d" "$HQP/city.toml"
  if [ "$W_RC" = 2 ] && printf '%s' "$W_OUT" | grep -q 'could not tell\|CANNOT TELL'; then ok "city.toml unreadable -> TEST_EXIT 2 (cannot tell is a failure, not a pass)"; else bad "unreadable city.toml: TEST_EXIT=$W_RC :: $W_OUT"; fi

  d="$(mkwt cityfallback)"; rm -f "$d/wt/$HQP/packs/town-deltas/assets/e12-crew-doctrine.sh"
  mkdir -p "$d/city/packs/town-deltas/assets" && cp "$GEN" "$ARMS" "$d/city/packs/town-deltas/assets/"
  mkdir -p "$d/wt/$HQP/agents/zed-wa"; printf '# zed\nWhen done run /gate-done.\n' > "$d/wt/$HQP/agents/zed-wa/prompt.template.md"
  run2d "$d" "$HQP/agents/zed-wa/prompt.template.md"
  if [ "$W_RC" = 1 ] && printf '%s' "$W_OUT" | grep -q 'zed-wa'; then ok "a branch without the generator: the city's is used on the branch's files -> the uncovered prompt is still caught"; else bad "city fallback: TEST_EXIT=$W_RC :: $W_OUT"; fi

  d="$(mkwt nogen)"; rm -f "$d/wt/$HQP/packs/town-deltas/assets/e12-crew-doctrine.sh"
  run2d "$d" "$TOUCH_PROMPT"
  if [ "$W_RC" = 0 ] && printf '%s' "$W_OUT" | grep -q 'NOTE: e12-crew-doctrine.sh not found'; then ok "no generator in the branch or the city (pre-story snapshot): NOTE and skip, no block"; else bad "no generator: TEST_EXIT=$W_RC :: $W_OUT"; fi
fi

echo
echo "== result: $PASS ok, $FAILN failure(s) =="
REACHED_END=1
[ "$FAILN" = 0 ]
