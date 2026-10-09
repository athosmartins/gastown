#!/usr/bin/env bash
# prod-tests/gascity/story-ga-0nz1wi.sh — prod test for ga-0nz1wi: the named crews (thies/oracle/digo/mila/peter/batista) get the E12
# write-time doctrine, from the SAME text the Pilot appends to a dispatch.
#
# What "deployed and correct" means here:
#   (1) the pieces are in the LIVE tree and parse: the generator, the selftest, the six crew prompt templates;
#   (2) one source: every crew prompt's marked region is a fresh render of e12_block_text (e12-crew-doctrine.sh check, three exits);
#   (3) each crew's template has exactly one begin and one end marker (read here with grep, not through the generator);
#   (4) the LIVE engine renders it: `gc prime --strict <crew>-wa` on the live city contains the Pilot's block exactly once (the block
#       as the dispatcher gets it, from `e12-arms.sh block`), with the town-deltas core still there. This reads the RENDERED prompt, not
#       the file: the engine can degrade a template silently (exit 0, nothing on stderr, the block simply absent), so only the render says
#       what the crew will read;
#   (5) the hermetic selftest (real engine, six real prompts, throw-away cities, controls that must fail) passes on the live tree.
#
# THREE STATES per crew in (4), never two: rendered with the block / not renderable because the agent is SUSPENDED (gc prime prints
# nothing and exits 0 for a suspended agent — measured on batista-wa, suspended by the Athos 2026-10-05) / failed. A suspended crew is
# reported as NOT verified live (its markers are still checked in (2)-(3) and the engine render of its real template is in (5)); an EMPTY
# render for an agent that is not marked suspended is a failure, and at least one crew must render live or the check proved nothing.
#
# Not asserted here, and why: `gc reload --soft` after the merge (acceptance 3 of the story) acts on the live controller, so it is the
# Mayor's/delivery's step, not a test's. It re-reads config and accepts drift on open sessions instead of draining them; without --soft,
# `gc reload` says per-session restarts may still happen when its normal config-drift rules require them.
#
# Nothing is written outside a scratch dir: no live store, no session, no mail. The block is built on a scratch conf with --no-record, and
# `gc prime` without --hook only reads the live config and prints to stdout.
# Called by run.sh after deploy (STORY_ID=ga-0nz1wi). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
ARMS="$ASSETS/e12-arms.sh"
GEN="$ASSETS/e12-crew-doctrine.sh"
SELFTEST="$ASSETS/e12-crew-doctrine.selftest.sh"
CREWS="thies oracle digo mila peter batista"
BEGIN_RE='^{{/\* e12-doctrine:begin'
END_LINE='{{/* e12-doctrine:end */}}'
CORE="REGRA Nº 1 — TODA pergunta ao Athos é MÚLTIPLA ESCOLHA"   # a town-deltas core sentinel: the include must not displace it

log()  { echo "[prod-test:gascity ga-0nz1wi] $*"; }
fail() { echo "[prod-test:gascity ga-0nz1wi] FAIL: $*" >&2; exit 1; }

# ── 1. the pieces are in the live tree and parse ──────────────────────────────────────────────────────────────
for f in "$ARMS" "$GEN" "$SELFTEST"; do
  [[ -f "$f" ]] || fail "not deployed: $f"
done
for f in "$ARMS" "$GEN" "$SELFTEST"; do
  bash -n "$f" || fail "does not parse under bash: $f"
done
command -v gc >/dev/null 2>&1 || fail "gc not on PATH — the rendered prompt cannot be read"
command -v python3 >/dev/null 2>&1 || fail "python3 missing — the block cannot be counted in a rendered prompt"
for c in $CREWS; do
  [[ -f "$CITY/agents/$c-wa/prompt.template.md" ]] || fail "not deployed: $CITY/agents/$c-wa/prompt.template.md"
done
log "generator, selftest and the six crew prompt templates are deployed; the scripts parse ✓"

S="$(mktemp -d "${TMPDIR:-/tmp}/prod-ga-0nz1wi.XXXXXX")" || fail "no scratch dir"
case "$S" in /?*) ;; *) fail "mktemp printed no usable scratch path ('$S')" ;; esac
trap 'rm -rf "$S"' EXIT

# ── 2. one source: every crew prompt's region is a fresh render of the Pilot's text ───────────────────────────────
# exit 0 = current, 1 = stale/missing, 2 = could not tell: each says something different, so none of them is folded into another
rc=0; out="$(bash "$GEN" check 2>&1)" || rc=$?
case "$rc" in
  0) ;;
  1) fail "a crew prompt is STALE or has broken markers against e12_block_text — run 'bash $GEN write' and commit: $out" ;;
  *) fail "the crew-doctrine check could not tell (rc=$rc): $out" ;;
esac
log "e12-crew-doctrine.sh check: all six crew prompts carry a fresh render of e12_block_text ✓"

# ── 3. each crew's template has exactly one begin and one end marker ──────────────────────────────────────────────
for c in $CREWS; do
  p="$CITY/agents/$c-wa/prompt.template.md"
  # vazio → 0 matches is a real answer (the marker is missing); falhou/ilegível → grep rc>=2 is its own failure, never a count of 0
  rc=0; nb="$(grep -c -e "$BEGIN_RE" "$p" 2>/dev/null)" || rc=$?
  [[ "$rc" -le 1 ]] || fail "$c-wa: could not read $p (grep rc=$rc)"
  rc=0; ne="$(grep -cxF "$END_LINE" "$p" 2>/dev/null)" || rc=$?
  [[ "$rc" -le 1 ]] || fail "$c-wa: could not read $p (grep rc=$rc)"
  [[ "$nb" == 1 && "$ne" == 1 ]] || fail "$c-wa: $nb begin marker(s) and $ne end marker(s) in $p (expected exactly 1 of each)"
done
log "all six crew templates have exactly one begin and one end marker ✓"

# ── 4. the LIVE engine renders it ─────────────────────────────────────────────────────────────────────────────────
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

n_live=0; n_susp=0
for c in $CREWS; do
  f="$S/render-$c.txt"
  # falhou → gc exits non-zero (a template that cannot be resolved lands here under --strict): one retry for load, then a failure;
  # vazio → empty stdout with rc 0 is NOT "no block": it is what a SUSPENDED agent prints, so it is classified below, not counted as 0
  rc=1; try=0
  while [[ "$rc" -ne 0 && "$try" -lt 2 ]]; do
    rc=0; timeout 120 gc --city "$CITY" prime --strict "$c-wa" > "$f" 2> "$S/render-$c.err" || rc=$?
    try=$((try+1))
  done
  [[ "$rc" -eq 0 ]] || fail "$c-wa: 'gc prime --strict $c-wa' exited $rc on the live city: $(grep -v '^warning: builtin pack' "$S/render-$c.err" | head -3)"
  if [[ ! -s "$f" ]]; then
    # ilegível → grep rc>=2 (cannot read agent.toml) is a failure; rc 1 means "not marked suspended", which makes an empty render a failure
    srcrc=0; grep -Eq '^[[:space:]]*suspended[[:space:]]*=[[:space:]]*true' "$CITY/agents/$c-wa/agent.toml" 2>/dev/null || srcrc=$?
    [[ "$srcrc" -le 1 ]] || fail "$c-wa: rendered an empty prompt and agent.toml could not be read to tell whether it is suspended (grep rc=$srcrc)"
    if [[ "$srcrc" -eq 0 ]]; then
      log "$c-wa: SUSPENDED in agent.toml — gc prime prints nothing for a suspended agent, so it is NOT verified against the live city (markers checked in steps 2-3; engine render of its real template in step 5)"
      n_susp=$((n_susp+1)); continue
    fi
    fail "$c-wa: the live render is EMPTY and agent.toml does not mark it suspended — the crew would start with no prompt"
  fi
  rc=0; n="$(count_block "$f")" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "$c-wa: could not count the block in the rendered prompt (python rc=$rc)"
  [[ "$n" == 1 ]] || fail "$c-wa: the Pilot's block appears $n times in the rendered prompt of the live city (expected exactly 1)"
  grep -qF "$CORE" "$f" || fail "$c-wa: the rendered prompt lost the town-deltas core ('$CORE') — the include displaced it"
  n_live=$((n_live+1))
  log "$c-wa: live 'gc prime --strict' = $(wc -c < "$f" | tr -d ' ') chars, the Pilot's block exactly once, town-deltas core intact ✓"
done
[[ "$n_live" -ge 1 ]] || fail "no crew could be rendered on the live city ($n_susp suspended) — nothing was verified against the live engine"
log "live city: $n_live crew prompt(s) verified, $n_susp suspended (not verifiable by gc prime) ✓"

# ── 5. the hermetic selftest passes on the live tree ──────────────────────────────────────────────────────────────
# Its own scratch dirs go under $S/tmp, which the trap above removes (the selftest only cleans paths safe-clean covers).
mkdir -p "$S/tmp" || fail "could not create the selftest's scratch parent"
rc=0; TMPDIR="$S/tmp" E12C_HQ="$CITY" bash "$SELFTEST" > "$S/selftest.out" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  grep -E '^  (FAIL|bad|not ok)|result:' "$S/selftest.out" | head -10 >&2
  fail "e12-crew-doctrine.selftest.sh exited $rc on the live tree"
fi
grep -q '== result: [0-9]* ok, 0 failure(s) ==' "$S/selftest.out" || fail "e12-crew-doctrine.selftest.sh exited 0 but did not print its '0 failure(s)' result line — it did not finish"
log "e12-crew-doctrine.selftest.sh: $(grep '== result:' "$S/selftest.out") ✓"

log "PASS"
exit 0
