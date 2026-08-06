#!/usr/bin/env bash
# gate-guard-gap3-ext-show-failure-detection.selftest.sh — regression guard
# for the ga-jto05 gate-FAIL fix (gate_run=ga-wisp-2tfo976).
#
# ROOT BUG: Step 0c.3's EXT_SHOW capture piped `bd show ... 2>/dev/null`
# straight into `jq 'if type=="array" then .[0] else . end'`. bd's own
# failure convention prints a non-empty JSON error object to STDOUT (not
# stderr) with a nonzero exit — jq's else-branch passes that object through
# UNCHANGED, so `[ -z "$EXT_SHOW" ]` never saw an empty string and the
# intended "bd show failed" message never fired. Execution fell through to
# PR-ref extraction, where the error object's missing `.comments` key
# resolved empty, and the sweep logged the WRONG diagnostic ("no GitHub PR
# URL found in comments") — masking that the bead could not even be read.
#
# FIX: capture bd's own exit status directly (`if ! VAR=$(bd ...); then`),
# BEFORE the output ever reaches jq, as a separate step from the
# jq-parseability check.
#
# Strategy: pull the live snippet VERBATIM from quality-gate-guard.sh (grep
# anchored on stable literal substrings, not line numbers) and exercise it
# under the same `set -euo pipefail` the real script uses, against a FAKE
# `bd` that reproduces bd's real error-JSON-on-stdout + nonzero-exit shape.
# Pure bash + grep/awk. Never runs gc/bd, never touches the live city or
# beads — safe to run on a live host.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "== gate-guard-gap3-ext-show-failure-detection.selftest (ga-jto05) =="

if [ ! -f "$GUARD" ]; then
  bad "quality-gate-guard.sh not found next to selftest at $GUARD"
  echo
  echo "── results: $PASS passed, $FAIL failed ──"
  exit 1
fi

# extract_ext_show_snippet <file> — pulls the EXT_SHOW_RAW/EXT_SHOW handling
# block verbatim: from the `if ! EXT_SHOW_RAW=...` opener through the `fi`
# that closes the `returned unparseable data` branch (2 lines after that log
# line: the `continue` and the `fi`). Anchored on literal substrings via
# awk's index(), same technique as gate-guard-gap3-external-pr-ref-capture's
# extractor, since the surrounding shell is full of literal $ and quotes a
# regex would have to escape.
extract_ext_show_snippet() {
  local file="$1"
  awk '
    index($0, "if ! EXT_SHOW_RAW=$(bd -C \"$GC_CITY\" show") > 0 { grabbing=1 }
    grabbing { print }
    grabbing && index($0, "returned unparseable data") > 0 { trail=2; next }
    trail > 0 { trail--; if (trail == 0) exit }
  ' "$file"
}

echo "── 1. live source carries the expected EXT_SHOW handling block ──"
LIVE_SNIPPET="$(extract_ext_show_snippet "$GUARD")"
if [ -z "$LIVE_SNIPPET" ]; then
  bad "could not extract the EXT_SHOW handling block from $GUARD — anchors drifted?"
  echo
  echo "── results: $PASS passed, $FAIL failed ──"
  exit 1
else
  ok "extracted EXT_SHOW handling block from live source"
fi

# Drift-guard: the block must check bd's exit status BEFORE piping to jq —
# if a future edit collapses this back into one pipeline, this assertion
# catches it even before the functional tests below would.
case "$LIVE_SNIPPET" in
  *'if ! EXT_SHOW_RAW=$(bd '*) ok "checks bd's exit status directly (not via jq output shape)" ;;
  *) bad "no longer checks bd's exit status directly — regression risk reopened" ;;
esac

# run_snippet <fake_bd_body> <ext_id> — execs the live snippet in an isolated
# subshell (same set -euo pipefail as the real script) with GC_CITY/EXT_ID
# set and a caller-supplied fake `bd` + a `log` that prefixes captured lines
# so the assertions can tell which branch fired.
run_snippet() {
  local fake_bd_body="$1" ext_id="$2"
  bash -c '
    set -euo pipefail
    GC_CITY="/fake/city"
    EXT_ID="$1"
    bd() { '"$fake_bd_body"'; }
    log() { echo "LOG:$*"; }
    for _once in 1; do
'"$LIVE_SNIPPET"'
      echo "FELL_THROUGH"
    done
  ' _ "$ext_id" 2>&1
}

echo "── 2. bd show fails (nonzero exit, error JSON on stdout) ──"
FAKE_BD_ERROR='echo "{\"error\":\"issue not found\",\"schema_version\":1}"; return 1'
OUT="$(run_snippet "$FAKE_BD_ERROR" "ga-nonexistent")"
case "$OUT" in
  *"LOG:GAP-3: ga-nonexistent — bd show --include-comments failed (nonzero exit) — safe-skip"*)
    ok "bd-show failure logs the FAILED message, distinct from the parse-failure message" ;;
  *)
    bad "expected the bd-show-failed log line, got: $OUT" ;;
esac
case "$OUT" in
  *"no GitHub PR URL found"*|*"returned unparseable data"*)
    bad "bd-show failure incorrectly fell through to a DIFFERENT diagnostic — the exact regression this test guards against: $OUT" ;;
  *) ok "did not fall through to the wrong diagnostic" ;;
esac
case "$OUT" in
  *"FELL_THROUGH"*) bad "loop body did not 'continue' on bd-show failure — kept executing past the guard" ;;
  *) ok "'continue' fired — no code ran past the bd-show-failure guard" ;;
esac

echo "── 3. bd show succeeds with a real array-wrapped bead (happy path) ──"
FAKE_BD_OK='echo "[{\"id\":\"ga-real\",\"comments\":[]}]"; return 0'
OUT="$(run_snippet "$FAKE_BD_OK" "ga-real")"
case "$OUT" in
  *"bd show --include-comments failed"*) bad "happy path incorrectly logged a bd-show-failure: $OUT" ;;
  *) ok "happy path does not log a bd-show-failure" ;;
esac
case "$OUT" in
  *"FELL_THROUGH"*) ok "happy path falls through past both guards (as expected — a real bead continues to PR-ref extraction)" ;;
  *) bad "happy path unexpectedly stopped before reaching PR-ref extraction: $OUT" ;;
esac

echo "── 4. bd show succeeds but returns truly empty output (edge case) ──"
FAKE_BD_EMPTY='printf ""; return 0'
OUT="$(run_snippet "$FAKE_BD_EMPTY" "ga-empty")"
case "$OUT" in
  *"LOG:GAP-3: ga-empty — bd show --include-comments returned unparseable data — safe-skip"*)
    ok "zero-exit + empty output -> the SEPARATE 'unparseable data' message (not the exit-status one)" ;;
  *) bad "expected the 'unparseable data' log line for empty-but-successful output, got: $OUT" ;;
esac

echo "── 5. sanity: quality-gate-guard.sh still parses cleanly ──"
if bash -n "$GUARD" 2>/dev/null; then
  ok "quality-gate-guard.sh parses cleanly (bash -n)"
else
  bad "quality-gate-guard.sh FAILED bash -n"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
