#!/usr/bin/env bash
# prod-tests/gascity/story-ga-57e7l0.sh — prod test for ga-57e7l0 (a): the E12 write-time doctrine reaches EVERY builder, not only the ones
# the Pilot sends a message to (slice 1 of the story; the reads check and the per-arm report are later slices).
#
# What "deployed and correct" means here:
#   (1) the pieces are in the LIVE tree and parse: the generator, both selftests, the fragment, city.toml, the gate formula;
#   (2) one source: every target (the crews' marked regions AND the town-deltas fragment section) is a fresh render of e12_block_text
#       (e12-crew-doctrine.sh check, three exits: current / stale / could not tell);
#   (3) no builder prompt is uncovered (e12-crew-doctrine.sh coverage: the fragment guard lists dog/ps-worker/wa-worker, city.toml gives each
#       of those roles to an agent, town-deltas is a global fragment, every prompt that says /gate-done is covered);
#   (4) the gate really runs that check: step 2d is in the live formula, once, and carries no backslash (a TOML """ string would eat it);
#   (5) the LIVE engine renders it: `gc prime --strict` on the live city for the pool builders (wa-worker, ps-worker, dog) and for the crews
#       contains the Pilot's block EXACTLY once (the block as the dispatcher gets it, from `e12-arms.sh block`), a reviewer contains it
#       zero times, and the town-deltas core is still there. It reads the RENDERED prompt, not the file: the engine can degrade a template
#       silently (exit 0, nothing on stderr, the block simply absent), so only the render says what the builder will read;
#   (6) both hermetic selftests pass on the live tree (real engine, throw-away cities, controls that must fail).
#
# THREE STATES per agent in (5), never two: rendered with the expected number of blocks / not renderable because the agent is SUSPENDED
# (gc prime prints nothing and exits 0 for a suspended agent; the crews batista-ps, thies-ps and batista-lx are suspended, and their
# regions are still checked in (2) and rendered by the engine in (6)) / failed. An EMPTY render for an agent that is not marked suspended
# is a failure, and the three pool builders must all render live or the check proved nothing.
#
# Not asserted here, and why: that the first-attempt rate improves and the third-state share of FAILs falls (acceptance 7 days) is a
# measurement over a week of gate runs, not a deploy check — that is the later report slice. `gc reload --soft` after the merge acts on
# the live controller, so it is the Mayor's/delivery's step, not a test's.
#
# Nothing is written outside a scratch dir: no live store, no session, no mail. The block is built on a scratch conf with --no-record, and
# `gc prime` without --hook only reads the live config and prints to stdout.
# Called by run.sh after deploy (STORY_ID=ga-57e7l0). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
ARMS="$ASSETS/e12-arms.sh"
GEN="$ASSETS/e12-crew-doctrine.sh"
SELFTEST_NEW="$ASSETS/e12-builder-coverage.selftest.sh"
SELFTEST_OLD="$ASSETS/e12-crew-doctrine.selftest.sh"
FRAGMENT="$CITY/packs/town-deltas/template-fragments/town-deltas.template.md"
FORMULA="$CITY/formulas/mol-quality-gate-runner.toml"
CITY_TOML="$CITY/city.toml"
POOLS="dog wa-worker ps-worker"
CREWS="thies-wa oracle-wa digo-wa mila-wa peter-wa batista-wa batista-ps thies-ps batista-lx"
NOT_BUILDERS="gate-reviewer refino-gate-reviewer"
CORE="REGRA Nº 1 — TODA pergunta ao Athos é MÚLTIPLA ESCOLHA"   # a town-deltas core sentinel: the section must not displace it

log()  { echo "[prod-test:gascity ga-57e7l0] $*"; }
fail() { echo "[prod-test:gascity ga-57e7l0] FAIL: $*" >&2; exit 1; }

# ── 1. the pieces are in the live tree and parse ───────────────────────────────────────────────────────
for f in "$ARMS" "$GEN" "$SELFTEST_NEW" "$SELFTEST_OLD" "$FRAGMENT" "$FORMULA" "$CITY_TOML"; do
  [[ -f "$f" ]] || fail "not deployed: $f"
done
for f in "$ARMS" "$GEN" "$SELFTEST_NEW" "$SELFTEST_OLD"; do
  bash -n "$f" || fail "does not parse under bash: $f"
done
command -v gc >/dev/null 2>&1 || fail "gc not on PATH — the rendered prompt cannot be read"
command -v python3 >/dev/null 2>&1 || fail "python3 missing — the block cannot be counted in a rendered prompt"
log "generator, both selftests, fragment, city.toml and the gate formula are deployed; the scripts parse ✓"

S="$(mktemp -d "${TMPDIR:-/tmp}/prod-ga-57e7l0.XXXXXX")" || fail "no scratch dir"
case "$S" in /?*) ;; *) fail "mktemp printed no usable scratch path ('$S')" ;; esac
trap 'rm -rf "$S"' EXIT

# ── 2. one source: every target is a fresh render of the Pilot's text ─────────────────────────────────────────────
# exit 0 = current, 1 = stale/missing, 2 = could not tell: each says something different, so none of them is folded into another
rc=0; out="$(bash "$GEN" check 2>&1)" || rc=$?
case "$rc" in
  0) ;;
  1) fail "a target is STALE or has broken markers against e12_block_text — run 'bash $GEN write' and commit: $out" ;;
  *) fail "the doctrine check could not tell (rc=$rc): $out" ;;
esac
log "e12-crew-doctrine.sh check: $out ✓"

# ── 3. no builder prompt is uncovered ─────────────────────────────────────────────────────────────────────────
# 0 = covered, 1 = a builder prompt nothing covers (the output names it), 2 = could not tell (city.toml/fragment unreadable): not "covered"
rc=0; out="$(bash "$GEN" coverage 2>&1)" || rc=$?
case "$rc" in
  0) ;;
  1) fail "a builder prompt is NOT covered by the write-time doctrine: $out" ;;
  *) fail "coverage could not tell (rc=$rc): $out" ;;
esac
for who in $POOLS; do
  printf '%s\n' "$out" | grep -q "$who" || fail "coverage passed but does not name $who as covered — it did not look at that role: $out"
done
log "e12-crew-doctrine.sh coverage: dog, wa-worker and ps-worker are covered by the fragment, every other builder prompt by its own region ✓"

# ── 4. the gate runs that check ───────────────────────────────────────────────────────────────────────────────
# vazio → 0 markers is a real answer (step 2d is missing); falhou/ilegível → grep rc>=2 is its own failure, never a count of 0
for tag in BEGIN END; do
  rc=0; n="$(grep -c "SELFTEST-EXTRACT e12-coverage-step2d: $tag" "$FORMULA" 2>/dev/null)" || rc=$?
  [[ "$rc" -le 1 ]] || fail "could not read $FORMULA (grep rc=$rc)"
  [[ "$n" == 1 ]] || fail "$FORMULA has $n 'e12-coverage-step2d: $tag' marker(s) (expected exactly 1) — the gate would not run the coverage check"
done
snippet="$(awk '/SELFTEST-EXTRACT e12-coverage-step2d: BEGIN/{f=1;next} /SELFTEST-EXTRACT e12-coverage-step2d: END/{f=0} f' "$FORMULA" 2>/dev/null)"
[[ -n "$snippet" ]] || fail "step 2d has markers but no body in $FORMULA"
printf '%s' "$snippet" | grep -q '\\' && fail "step 2d carries a backslash — a TOML \"\"\" string would eat it and the gate would run something else"
printf '%s\n' "$snippet" > "$S/2d.body"
/bin/bash -n "$S/2d.body" || fail "step 2d does not parse under /bin/bash (3.2 on this host)"
python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    tomllib.load(fh)
' "$FORMULA" || fail "$FORMULA is not valid TOML — the gate formula would not load"
log "mol-quality-gate-runner.toml: step 2d present once, backslash-free, parses under bash and the formula is valid TOML ✓"

# ── 5. the LIVE engine renders it ─────────────────────────────────────────────────────────────────────────────
# The Pilot's block exactly as the dispatcher captures it: the CLI it calls, treated arm, on a scratch conf, enrolling nothing.
printf 'treated_pct=100\n' > "$S/e12-ab.conf" || fail "could not write the scratch conf"
# vazio → an empty block is a failure here (the Pilot would append nothing); falhou → a non-zero exit is a failure, never "empty"
rc=0; E12_STATE_DIR="$S" bash "$ARMS" block ga-prodtest "$CITY" prod-test --no-record > "$S/pilot.txt" 2>"$S/pilot.err" || rc=$?
[[ "$rc" -eq 0 ]] || fail "e12-arms.sh block exited $rc (the Pilot would append nothing): $(head -3 "$S/pilot.err")"
[[ -s "$S/pilot.txt" ]] || fail "e12-arms.sh block printed nothing under treated_pct=100"
[[ "$(head -1 "$S/pilot.txt")" == "## Write-time doctrine"* ]] || fail "the Pilot's block does not start with the header the dispatcher checks: $(head -1 "$S/pilot.txt")"
[[ -e "$S/e12-roster.jsonl" ]] && fail "the dry-run block call enrolled a bead in the scratch roster (--no-record was ignored)"

# Counts how many times the block text occurs in the rendered prompt. Prints the number and nothing else; exit 0 only if it counted.
count_block() {
  python3 -I -c '
import sys
block = open(sys.argv[1], encoding="utf-8").read().rstrip("\n")
text = open(sys.argv[2], encoding="utf-8").read()
if not block:
    sys.exit(3)
print(text.count(block))
' "$S/pilot.txt" "$1"
}

# render_check <agent> <expected block count> <must render: 1|0>
# Prints one log line and returns 0 when the agent rendered with the expected count, 10 when it is suspended (not verified), and fails the
# test otherwise. <must render> = 1 makes an empty render a failure even if the agent were marked suspended (the pool builders are never suspended).
render_check() {
  local a="$1" want="$2" must="$3" f="$S/render-$1.txt" rc try srcrc n
  # falhou → gc exits non-zero (a template that cannot be resolved lands here under --strict): one retry for load, then a failure;
  # vazio → empty stdout with rc 0 is NOT "no block": it is what a SUSPENDED agent prints, so it is classified below, not counted as 0
  rc=1; try=0
  while [[ "$rc" -ne 0 && "$try" -lt 2 ]]; do
    rc=0; timeout 120 gc --city "$CITY" prime --strict "$a" > "$f" 2> "$S/render-$a.err" || rc=$?
    try=$((try+1))
  done
  [[ "$rc" -eq 0 ]] || fail "$a: 'gc prime --strict $a' exited $rc on the live city: $(grep -v '^warning: builtin pack' "$S/render-$a.err" | head -3)"
  if [[ ! -s "$f" ]]; then
    [[ "$must" == 1 ]] && fail "$a: the live render is EMPTY — a pool builder would start with no prompt"
    # ilegível → grep rc>=2 (cannot read agent.toml) is a failure; rc 1 means "not marked suspended", which makes an empty render a failure
    srcrc=0; grep -Eq '^[[:space:]]*suspended[[:space:]]*=[[:space:]]*true' "$CITY/agents/$a/agent.toml" 2>/dev/null || srcrc=$?
    [[ "$srcrc" -le 1 ]] || fail "$a: rendered an empty prompt and agent.toml could not be read to tell whether it is suspended (grep rc=$srcrc)"
    if [[ "$srcrc" -eq 0 ]]; then
      log "$a: SUSPENDED in agent.toml — gc prime prints nothing for a suspended agent, so it is NOT verified against the live city (its region is checked in step 2, its real template rendered by the engine in step 6)"
      return 10
    fi
    fail "$a: the live render is EMPTY and agent.toml does not mark it suspended — the agent would start with no prompt"
  fi
  rc=0; n="$(count_block "$f")" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "$a: could not count the block in the rendered prompt (python rc=$rc)"
  [[ "$n" == "$want" ]] || fail "$a: the Pilot's block appears $n time(s) in the rendered prompt of the live city (expected exactly $want)"
  grep -qF "$CORE" "$f" || fail "$a: the rendered prompt lost the town-deltas core ('$CORE') — the section displaced it"
  log "$a: live 'gc prime --strict' = $(wc -c < "$f" | tr -d ' ') chars, the Pilot's block $n time(s) (expected $want), town-deltas core intact ✓"
  return 0
}

# Pool builders (TD_ROLE): exactly once, from the fragment section. A crew with no TD_ROLE: exactly once, from its own region (the fragment
# guard must NOT also show it — that would be twice). A reviewer: never.
n_pool=0
for a in $POOLS; do
  render_check "$a" 1 1; n_pool=$((n_pool+1))
done
n_live=0; n_susp=0
for a in $CREWS; do
  rc=0; render_check "$a" 1 0 || rc=$?
  case "$rc" in 0) n_live=$((n_live+1)) ;; 10) n_susp=$((n_susp+1)) ;; *) fail "$a: render check returned $rc" ;; esac
done
[[ "$n_live" -ge 1 ]] || fail "no crew could be rendered on the live city ($n_susp suspended) — the 'exactly once, not twice' property was not verified for crews"
for a in $NOT_BUILDERS; do
  rc=0; render_check "$a" 0 0 || rc=$?
  case "$rc" in 0|10) ;; *) fail "$a: render check returned $rc" ;; esac
done
log "live city: $n_pool pool builders, $n_live crew prompt(s) verified ($n_susp suspended), reviewers carry no block ✓"

# ── 6. the hermetic selftests pass on the live tree ───────────────────────────────────────────────────────────
# Their scratch dirs go under $S/tmp, which the trap above removes (the selftests only clean paths safe-clean covers).
mkdir -p "$S/tmp" || fail "could not create the selftests' scratch parent"
rc=0; TMPDIR="$S/tmp" E12B_HQ="$CITY" bash "$SELFTEST_NEW" > "$S/selftest-new.out" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  grep -E '^  (FAIL|bad|not ok)|result:' "$S/selftest-new.out" | head -10 >&2
  fail "e12-builder-coverage.selftest.sh exited $rc on the live tree"
fi
grep -q '== result: [0-9]* ok, 0 failure(s) ==' "$S/selftest-new.out" || fail "e12-builder-coverage.selftest.sh exited 0 but did not print its '0 failure(s)' result line — it did not finish"
log "e12-builder-coverage.selftest.sh: $(grep '== result:' "$S/selftest-new.out") ✓"

rc=0; TMPDIR="$S/tmp" E12C_HQ="$CITY" bash "$SELFTEST_OLD" > "$S/selftest-old.out" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  grep -E '^  (FAIL|bad|not ok)|result:' "$S/selftest-old.out" | head -10 >&2
  fail "e12-crew-doctrine.selftest.sh exited $rc on the live tree"
fi
grep -q '== result: [0-9]* ok, 0 failure(s) ==' "$S/selftest-old.out" || fail "e12-crew-doctrine.selftest.sh exited 0 but did not print its '0 failure(s)' result line — it did not finish"
log "e12-crew-doctrine.selftest.sh: $(grep '== result:' "$S/selftest-old.out") ✓"

log "PASS"
exit 0
