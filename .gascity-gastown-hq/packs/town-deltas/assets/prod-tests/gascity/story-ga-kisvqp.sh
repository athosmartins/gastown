#!/usr/bin/env bash
# prod-tests/gascity/story-ga-kisvqp.sh — prod test for ga-kisvqp (E7 of ga-ufskhy): the gate's
# "a new/changed test must FAIL on the pre-fix base" check (ga-rstae, arm B) now also measures
# pytest and JS tests, not only *.selftest.sh.
#
# Why it exists (docs/reports/gate-e4-historico.md item 4): 10.1% of gate FAILs (12.5% after
# 25/09) are "a test that passes without exercising the path", and the base check only ever ran
# bash selftests — a submission whose only new tests were pytest/js read `sem-teste-novo`, the
# same word as "no test at all".
#
# Called by run.sh after deploy (STORY_ID=ga-kisvqp). Exits 0 on pass. It tests the DEPLOYED
# guard in $CITY (not the worktree that built it) and never touches a live marker, bead, rig
# checkout or daemon: every run is in a throwaway repo under mktemp.
#
# Three layers, each one a way the feature could be "merged but not alive":
#   1. structural — the deployed files carry the functions, the plugin, and the call site wired
#      INSIDE the arm-B branch (and not before it: arm A must stay byte-for-byte untouched);
#   2. the selftest's fast sections (pure classifier, sandbox profile + probe, parsers, detection)
#      against the deployed guard — including that the sandbox really denies a write HERE;
#   3. one real measurement through the deployed code: a pytest test that needs the fix reads
#      fails-on-base, one that does not reads passes-on-base. Needs a pytest-capable venv (the
#      WA rig's); on a host without one this layer says so and is skipped — it is reported, not
#      silently counted as a pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
GUARD="$ASSETS/quality-gate-guard.sh"
PLUGIN="$ASSETS/gate_basetest_outcomes.py"
SELFTEST="$ASSETS/gate-guard-ab-base-test-pyjs.selftest.sh"
WA_RIG="${WA_RIG:-/Users/athos/gt/whatsapp_automation}"

log()  { echo "[prod-test:gascity ga-kisvqp] $*"; }
fail() { echo "[prod-test:gascity ga-kisvqp] FAIL: $*" >&2; exit 1; }

# has <extended-regex> <text>: status 0 when the text has a line matching it. NEVER `printf text | grep -q`:
# under pipefail, grep -q exits at its first match while printf is still writing a text bigger than the pipe
# buffer, printf dies of SIGPIPE, and a correct deploy reads as "not wired" (measured: ~1 run in 10 against the
# 18KB arm-B block). grep -c reads ALL of its input, so there is no early exit to race against.
# An empty pattern matches every line, so it is refused (status 1) rather than answered "yes".
has() { [ -n "$1" ] && [ "$(printf '%s\n' "$2" | grep -c -E -- "$1")" -gt 0 ]; }

TMPROOT=""
cleanup() { [ -n "$TMPROOT" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT

[[ -f "$GUARD" ]]    || fail "deployed guard missing: $GUARD"
[[ -f "$PLUGIN" ]]   || fail "deployed pytest plugin missing: $PLUGIN"
[[ -f "$SELFTEST" ]] || fail "deployed selftest missing: $SELFTEST"

# ── 1. Structural ────────────────────────────────────────────────────────────
for fn in gate_base_test_kind gate_base_test_is_support gate_base_test_file_state gate_base_test_sandbox_ok \
          gate_base_test_run_table gate_base_test_pyjs_measure gate_base_test_pyjs_scan gate_base_test_totals_field; do
  grep -q "^${fn}()" "$GUARD" || fail "$fn() missing from the deployed guard — the feature is not deployed"
done
log "all eight functions present in the deployed guard ✓"

BLOCK=$(awk '/Step 5b-pre2 \(ga-rstae\)/,/^fi$/' "$GUARD")
[[ -n "$BLOCK" ]] || fail "could not extract the arm-B block from the deployed guard"
ARM_LINE=$(printf '%s\n' "$BLOCK" | grep -n '"\$_ABT_ARM" = "B"' | head -1 | cut -d: -f1)
SCAN_LINE=$(printf '%s\n' "$BLOCK" | grep -n 'gate_base_test_pyjs_scan "\$RIG_PATH"' | head -1 | cut -d: -f1)
[[ -n "$ARM_LINE" && -n "$SCAN_LINE" ]] || fail "call site not wired (arm gate line='${ARM_LINE:-}', scan call line='${SCAN_LINE:-}')"
[[ "$ARM_LINE" -lt "$SCAN_LINE" ]] || fail "the py/js scan (block line $SCAN_LINE) is NOT after the arm-B gate (line $ARM_LINE) — arm A would run it"
log "py/js scan is wired after the arm-B gate (block lines $ARM_LINE < $SCAN_LINE) ✓"
has 'AB-BASE-TEST-PYJS bead=' "$BLOCK" \
  || fail "the AB-BASE-TEST-PYJS breakdown line is not wired — the apuração could not split py/js from sh"
has 'AB-BASE-TEST bead=.*unclassified=\$_ABT_UNCLASSIFIED outside-subtree=\$_ABT_OUTSIDE"$' "$BLOCK" \
  || fail "the AB-BASE-TEST line no longer ends with outside-subtree= — gate-ab-apuracao.sh / ga-x4mkk2 would break"
log "AB-BASE-TEST keeps its shape; py/js breakdown rides on its own line ✓"

# ── 2. The selftest's fast sections, against the DEPLOYED guard ──────────────
OUT=$(GATE_SELFTEST_ONLY=none bash "$SELFTEST" 2>&1) || {
  printf '%s\n' "$OUT" | grep -E '^  FAIL' | head -10 >&2
  fail "the selftest's fast sections fail against the deployed guard"
}
has 'RESULT: PASS' "$OUT" || fail "selftest did not report PASS"
log "selftest fast sections pass: $(printf '%s\n' "$OUT" | grep 'PASS=') ✓"

# ── 3. One real measurement through the deployed code ────────────────────────
if [[ ! -x "$WA_RIG/venv/bin/python" ]] || ! "$WA_RIG/venv/bin/python" -c 'import pytest' >/dev/null 2>&1; then
  log "SKIPPED layer 3: no pytest-capable venv at $WA_RIG/venv on this host (layers 1-2 passed)"
  log "PASS"
  exit 0
fi

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/prodtest-kisvqp.XXXXXX") || fail "mktemp failed"
R="$TMPROOT/rig"; mkdir -p "$R/lib" "$R/tests"
git -C "$R" init -q . && git -C "$R" config user.email prod@test && git -C "$R" config user.name prodtest
printf '[pytest]\npythonpath = . lib\ntestpaths = tests\n' > "$R/pytest.ini"
: > "$R/lib/__init__.py"
printf 'def double(x):\n    return x\n' > "$R/lib/mod.py"            # the BUG: double() does not double
printf '/venv\n' > "$R/.gitignore"
ln -s "$WA_RIG/venv" "$R/venv"
git -C "$R" add -A && git -C "$R" commit -q -m base
BASE=$(git -C "$R" rev-parse HEAD)
printf 'def double(x):\n    return x + x\n' > "$R/lib/mod.py"         # the FIX
printf 'from lib.mod import double\n\ndef test_needs_fix():\n    assert double(2) == 4\n' > "$R/tests/test_needs_fix.py"
printf 'from lib.mod import double\n\ndef test_proves_nothing():\n    assert callable(double)\n' > "$R/tests/test_proves_nothing.py"
git -C "$R" add -A && git -C "$R" commit -q -m fix
TIP=$(git -C "$R" rev-parse HEAD)

# The measurement gets a PRIVATE TMPDIR: other guard runs on this host create their own gate-kisvqp-basetest.*
# scratch dirs in the shared one, so "nothing left behind" is only checkable against a directory that is ours.
PRIV="$TMPROOT/private-tmp"; mkdir -p "$PRIV"
RESULT=$(TMPDIR="$PRIV" GATE_ABT_RUN_TIMEOUT=90 bash -c '
  GATE_GUARD_LIB_ONLY=1 . "$1"; set +e
  gate_base_test_pyjs_scan "$2" "$3" "$4"' _ "$GUARD" "$R" "$BASE" "$TIP") || fail "the scan itself crashed"

NEEDS=$(printf '%s\n' "$RESULT" | grep 'FILE tests/test_needs_fix.py ' | sed -n 's/.* state=\([^ ]*\).*/\1/p')
NOTHING=$(printf '%s\n' "$RESULT" | grep 'FILE tests/test_proves_nothing.py ' | sed -n 's/.* state=\([^ ]*\).*/\1/p')
[[ "$NEEDS" == "fails-on-base" ]]      || fail "a test that needs the fix read '$NEEDS', want fails-on-base. Output:
$RESULT"
[[ "$NOTHING" == "passes-on-base" ]]   || fail "a test that does not need the fix read '$NOTHING', want passes-on-base. Output:
$RESULT"
log "real pytest through the deployed code: needs-fix=$NEEDS, proves-nothing=$NOTHING ✓"

# And the verdict the guard would hand down for exactly that submission: one test that fails on base is
# the GOOD case (reprovou-na-base), so the pair must not be refused.
V=$(bash -c '
  GATE_GUARD_LIB_ONLY=1 . "$1"; set +e
  gate_base_test_verdict "$(gate_base_test_totals_field "$2" counted)" "$(gate_base_test_totals_field "$2" copy_ok)" \
    "$(gate_base_test_totals_field "$2" ran)" "$(gate_base_test_totals_field "$2" failed)" \
    "$(gate_base_test_totals_field "$2" repaired)" "$(gate_base_test_totals_field "$2" unclassified)"' _ "$GUARD" "$RESULT")
[[ "$V" == "reprovou-na-base" ]] || fail "verdict for {needs-fix, proves-nothing} was '$V', want reprovou-na-base (one genuine test makes the submission fine)"
log "verdict for the pair: $V ✓"

# Nothing may be left behind by the measurement itself (worktrees registered in the throwaway repo, scratch dirs).
[[ "$(git -C "$R" worktree list | wc -l | tr -d ' ')" == "1" ]] || fail "a throwaway worktree was left registered"
LEFT=$(ls -A "$PRIV" 2>/dev/null | wc -l | tr -d ' ')
[[ "$LEFT" == "0" ]] || fail "$LEFT entr(y/ies) left in the measurement's private TMPDIR: $(ls -A "$PRIV" | tr '\n' ' ')"
log "no worktree or scratch left behind ✓"

log "PASS"
exit 0
