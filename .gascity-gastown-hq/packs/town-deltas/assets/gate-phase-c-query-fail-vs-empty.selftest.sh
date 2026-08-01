#!/usr/bin/env bash
# gate-phase-c-query-fail-vs-empty.selftest.sh (2026-07-31)
#
# GUARDS: Phase C's verdict-bead rehydrate must distinguish "the query FAILED"
# from "this run genuinely has zero verdict beads". They are different facts and
# they must not produce the same action.
#
# WHY (measured, not theorized — 2026-07-31, gate-run ga-wisp-jm34iny):
#   23:19:08  "still in flight (0/1 verdicts, 266s/2040s)"    <- query OK, 1 bead
#   23:24:11  "has ZERO verdict beads — likely died before Step 7"  <- query FAILED
#   23:29:05  "still in flight (0/1 verdicts, 863s/2040s)"    <- query OK again
# The verdict bead (ga-45m6o, verdict:FAIL) existed the whole time and the run
# finalized correctly as FAILED. Nothing died. ONE sweep's query returned
# nothing, `|| echo "[]"` turned that into an empty array, and the emptiness
# guard read it as death.
#
# COST OF THE CONFLATION: that WARN string is what three separate agents grepped
# to size ga-jwnye ("~147 runs died", "426 orphans today", escalated as a
# city-wide gate outage). The per-bead count for the same day was 13 runs
# without a verdict AND without a successor. The instrumentation, not the gate,
# produced the outage narrative.
#
# NON-REGRESSION: a genuine Step-7 death (query SUCCEEDS, returns []) must STILL
# warn — otherwise this fix would trade a false alarm for a blind spot.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$HERE/quality-gate-dispatcher.sh"
REAL_BASH="/bin/bash"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-phase-c-query-fail-vs-empty.selftest =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract_block() {
  sed -n "/# SELFTEST-EXTRACT phase-c-verdict-rehydrate: BEGIN/,/# SELFTEST-EXTRACT phase-c-verdict-rehydrate: END/p" "$1" | sed '1d;$d'
}

# run_case <dispatcher-file> <bd-list-rc> <bd-list-stdout>
# Runs the live rehydrate block with `bd list` stubbed to the given rc/stdout.
run_case() {
  local file="$1" rc="$2" out="$3" block
  block="$(extract_block "$file")"
  [ -z "$block" ] && { echo "COULD_NOT_EXTRACT_BLOCK" >&2; return 99; }
  "$REAL_BASH" -c '
    set -euo pipefail
    GC_CITY="/fake/city"; GATE_RUN_ID="test-run-1"
    LIST_RC="$1"; LIST_OUT="$2"
    bd() {
      case " $* " in
        *" list "*) [ -n "$LIST_OUT" ] && echo "$LIST_OUT"; return "$LIST_RC" ;;
        *" show "*) echo "{\"assignee\":\"fake-session-1\"}"; return 0 ;;
      esac
      return 0
    }
    warn() { echo "WARN: $*"; }
    log()  { echo "LOG: $*"; }
    gate_collect_verdicts() { echo "COLLECT_CALLED"; }
    for _dummy in 1; do
      '"$block"'
    done
  ' _ "$rc" "$out" 2>&1
}

# ── 1. QUERY FAILED (rc=1) — the bug. Must skip, must NOT claim death ────────
OUT="$(run_case "$DISPATCHER" 1 "")"
case "$OUT" in
  *"likely died before Step 7"*)
    bad "query failure still reported as 'likely died before Step 7' — the conflation is live" ;;
  *"query for gate-run"*"failed this sweep"*)
    ok "query failure → explicit 'query failed, will retry' (not a death claim)" ;;
  *) bad "query failure produced neither the death claim nor the retry message — got: $(echo "$OUT" | tr '\n' ';' | cut -c1-160)" ;;
esac
case "$OUT" in
  *COLLECT_CALLED*) bad "query failure still fell through to gate_collect_verdicts (should skip the sweep)" ;;
  *)                ok "query failure skips the sweep (gate_collect_verdicts not reached)" ;;
esac

# ── 2. NON-REGRESSION: genuine zero (rc=0, []) must STILL warn death ─────────
OUT="$(run_case "$DISPATCHER" 0 "[]")"
case "$OUT" in
  *"likely died before Step 7"*) ok "genuine empty result (rc=0, []) STILL warns died-before-Step-7 — no blind spot introduced" ;;
  *) bad "genuine Step-7 death no longer detected — the fix traded a false alarm for a blind spot: $(echo "$OUT" | tr '\n' ';' | cut -c1-160)" ;;
esac

# ── 3. NON-REGRESSION: a real verdict bead still proceeds ────────────────────
OUT="$(run_case "$DISPATCHER" 0 '[{"id":"vb-1","labels":["reviewer-index:1","verdict:FAIL"],"status":"closed"}]')"
case "$OUT" in
  *"likely died"*) bad "a run WITH a verdict bead was reported as died" ;;
  *)               ok "a run WITH a verdict bead is not reported as died" ;;
esac

# ── 4. MUTATION: restore `|| echo \"[]\"` and case 1 must go RED ─────────────
echo "-- mutation: revert to the pre-fix '|| echo \"[]\"' --"
MUT="$(mktemp "${TMPDIR:-/tmp}/gate-qf-mutant-XXXXXX.sh" 2>/dev/null || echo "/tmp/gate-qf-mutant-$$.sh")"
sed -e 's|VB_SENTINEL="__VB_QUERY_FAILED__"||' \
    -e 's|-l "gate-run:\$GATE_RUN_ID" 2>/dev/null \|\| echo "\$VB_SENTINEL")|-l "gate-run:$GATE_RUN_ID" 2>/dev/null \|\| echo "[]")|' \
    -e 's|if \[ "\$VB_JSON" = "\$VB_SENTINEL" \]; then|if false; then|' \
    "$DISPATCHER" > "$MUT" 2>/dev/null
if ! grep -q 'echo "\[\]")' "$MUT" 2>/dev/null; then
  bad "mutation-test: could not construct the mutant (dispatcher shape changed?) — INCONCLUSIVE, treat as FAIL"
else
  OUT_MUT="$(run_case "$MUT" 1 "")"
  case "$OUT_MUT" in
    *"likely died before Step 7"*) ok "mutant (pre-fix) DOES report a mere query failure as death — proves this suite is not vacuous" ;;
    *) bad "mutant did not reproduce the conflation — test may be vacuous: $(echo "$OUT_MUT" | tr '\n' ';' | cut -c1-160)" ;;
  esac
fi
rm -f "$MUT" 2>/dev/null || true

echo ""
echo "== gate-phase-c-query-fail-vs-empty: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
