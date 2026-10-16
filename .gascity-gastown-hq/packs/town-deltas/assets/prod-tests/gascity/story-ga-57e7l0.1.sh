#!/usr/bin/env bash
# prod-tests/gascity/story-ga-57e7l0.1.sh — prod test for ga-57e7l0.1 (slice 2/3 of ga-57e7l0): /gate-done and the gate runner REFUSE a diff with a new failable
# read that no test makes fail (assets/third-state-reads-check.py).
#
# Deployed and correct means: (1) the checker, its selftest, the gate formula and commands/gate-done.md are in the LIVE tree and parse; (2) the formula
# carries step 2e exactly once, valid TOML, no backslash in the snippet (a TOML """ string would eat it); (3) gate-done.md has the refusal section after
# the third-state self-audit and before Step 1, listed under ## Contents; (4) the hermetic selftest passes on the live tree; (5) the checker runs on a REAL
# diff of the live repo, read-only (scratch state dir, warn mode, --no-record) and prints a verdict line: exit 0, not a crash.
# Not asserted: (a) the mode on the live city -- .gc/third-state-reads.conf is born ABSENT (= "fatia 2 não ligada") and the Mayor writes it after reading
# the calibration on the bead; this test only says which state it is in. (b) the third-state share falling below 30% and first-attempt approval reaching
# 60% is a 7-day measurement (third-state-report.py), not a deploy check. Nothing is written outside a scratch dir. Called by run.sh after deploy.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
CHECK="$ASSETS/third-state-reads-check.py"
SELFTEST="$ASSETS/third-state-reads-check.selftest.sh"
FORMULA="$CITY/formulas/mol-quality-gate-runner.toml"
GATE_DONE="$CITY/commands/gate-done.md"

log()  { echo "[prod-test:gascity ga-57e7l0.1] $*"; }
fail() { echo "[prod-test:gascity ga-57e7l0.1] FAIL: $*" >&2; exit 1; }

# ── 1. the pieces are in the live tree and parse ───────────────────────────────────────────────
for f in "$CHECK" "$SELFTEST" "$FORMULA" "$GATE_DONE"; do
  [[ -f "$f" ]] || fail "not deployed: $f"
done
command -v python3 >/dev/null 2>&1 || fail "python3 missing — the check cannot run"
python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$CHECK" || fail "the checker does not parse as Python"
bash -n "$SELFTEST" || fail "the selftest does not parse under bash"
log "checker, selftest, gate formula and gate-done.md are deployed; the scripts parse ✓"

S="$(mktemp -d "${TMPDIR:-/tmp}/prod-ga-57e7l0.1.XXXXXX")" || fail "no scratch dir"
case "$S" in /?*) ;; *) fail "mktemp printed no usable scratch path ('$S')" ;; esac
trap 'rm -rf "$S"' EXIT

# ── 2. step 2e in the gate formula ─────────────────────────────────────────────────────────────
# falhou → a formula that does not load, or a snippet that is empty, is a failure (the gate would run no check), never "no step"
python3 -I -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$FORMULA" || fail "$FORMULA is not valid TOML"
[[ "$(grep -c 'SELFTEST-EXTRACT third-state-reads-step2e: BEGIN' "$FORMULA")" == 1 ]] || fail "step 2e is not in the live gate formula exactly once"
awk '/SELFTEST-EXTRACT third-state-reads-step2e: BEGIN/{f=1;next} /SELFTEST-EXTRACT third-state-reads-step2e: END/{f=0} f' "$FORMULA" > "$S/step2e.sh"
[[ -s "$S/step2e.sh" ]] || fail "step 2e's snippet is empty"
[[ "$(grep -c '[\\]' "$S/step2e.sh")" == 0 ]] || fail "step 2e's snippet has a backslash — the TOML string would eat it"
/bin/bash -n "$S/step2e.sh" || fail "step 2e's snippet does not parse under /bin/bash"
log "formula: valid TOML, step 2e once, no backslash, parses under /bin/bash ✓"

# ── 3. gate-done.md ────────────────────────────────────────────────────────────────────────────
AUDIT="$(grep -n '^## Pre-flight Self-Audit: THE THIRD STATE' "$GATE_DONE" | head -1 | cut -d: -f1)"
SECT="$(grep -n '^## Pre-flight Check: NEW READS NEED A FAILURE TEST' "$GATE_DONE" | head -1 | cut -d: -f1)"
STEP1="$(grep -n '^## Step 1: Push your branch' "$GATE_DONE" | head -1 | cut -d: -f1)"
[[ -n "$AUDIT" && -n "$SECT" && -n "$STEP1" && "$SECT" -gt "$AUDIT" && "$SECT" -lt "$STEP1" ]] || fail "gate-done.md: refusal section at '$SECT' is not between the audit ('$AUDIT') and Step 1 ('$STEP1')"
sed -n '/^## Contents/,/^## [^C]/p' "$GATE_DONE" | grep -q 'NEW READS NEED A FAILURE TEST' || fail "gate-done.md: the section is not listed under ## Contents"
log "gate-done.md: the refusal section sits between the self-audit and Step 1, listed under ## Contents ✓"

# ── 4. the hermetic selftest on the live tree ──────────────────────────────────────────────────
mkdir -p "$S/tmp" || fail "could not create the selftest's scratch parent"
rc=0; TMPDIR="$S/tmp" TSR_HQ="$CITY" bash "$SELFTEST" > "$S/selftest.out" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then grep -E '^(FAIL|SKIP)|^  (FAIL|SKIP)' "$S/selftest.out" | head -10 >&2; fail "third-state-reads-check.selftest.sh exited $rc on the live tree"; fi
grep -q 'selftest: [0-9]* passed, 0 failed' "$S/selftest.out" || fail "the selftest exited 0 but did not print its '0 failed' line — it did not finish"
log "third-state-reads-check.selftest.sh: $(grep 'selftest:' "$S/selftest.out") ✓"

# ── 5. the checker on a real diff of the live repo, read-only ──────────────────────────────────
# exit 0 + a verdict line = it ran; the live HEAD may be main itself (an empty diff, "0 recognised new read(s)") and that is a real answer, not a skipped check
REPO="$(git -C "$CITY" rev-parse --show-toplevel 2>/dev/null)" || fail "$CITY is not inside a git repository"
mkdir -p "$S/state" && printf 'mode=warn\n' > "$S/state/third-state-reads.conf" || fail "could not write the scratch conf"
rc=0; THIRD_STATE_READS_STATE_DIR="$S/state" python3 -I "$CHECK" --repo "$REPO" --base origin/main --head HEAD --no-record > "$S/live.out" 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || fail "the checker exited $rc on the live repo in warn mode: $(head -3 "$S/live.out")"
grep -qE 'verdict=(ok|reads-without-test|nao-sei) mode=warn' "$S/live.out" || fail "the checker printed no verdict line on the live repo: $(head -3 "$S/live.out")"
log "live repo: $(grep -E 'verdict=' "$S/live.out" | head -1)"
if [[ -e "$CITY/.gc/third-state-reads.conf" ]]; then log "live conf: PRESENT ($(tr '\n' ' ' < "$CITY/.gc/third-state-reads.conf" 2>/dev/null)) — slice 2 is switched on"
else log "live conf: ABSENT — slice 2 is not switched on yet (the Mayor writes .gc/third-state-reads.conf after the calibration on the bead)"; fi

log "PASS"
exit 0
