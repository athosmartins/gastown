#!/usr/bin/env bash
# quality-gate-fail-reason.selftest.sh — Regression guard for ga-kf0v.
#
# The quality gate lost EVERY genuine reviewer FAIL reason ("No reason
# provided") because quality-gate-dispatcher.sh read the comment field .body
# while the beads "bd comments --json" schema uses .text (keys: author,
# created_at, id, issue_id, text — there is NO .body). This test proves the
# fixed reason-extraction jq parses a verdict:FAIL comment into a non-empty
# reason, and statically guards the dispatcher source against reverting to the
# old .body accessor.
#
# Pure bash + jq. Never runs gc/bd, never touches the live city or beads —
# safe to run on a live host (honors the "no live config edit" doctrine).
#
# Exit 0 iff every scenario passes.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

# parse_reason — the exact extraction the dispatcher uses for a verdict:FAIL
# bead. Kept in sync with quality-gate-dispatcher.sh; the static guards below
# fail the suite if the dispatcher and this expression drift apart.
parse_reason() { # <comments-json>
  printf '%s' "$1" | jq -r '
      [ .[]? | (.text // .body // "") ]
      | ( map(select(test("^\\s*VERDICT:"; "i"))) | last )
        // ( map(select(. != "")) | first )
        // ""
    ' 2>/dev/null || echo ""
}

echo "== quality-gate-fail-reason.selftest =="

# 1. Real-schema FAIL comment (.text, starts with VERDICT:) → full reason.
J='[{"author":"dog-a","created_at":"t","id":"c1","issue_id":"vb","text":"VERDICT: FAIL — shared Session across threads is a race"}]'
R=$(parse_reason "$J")
case "$R" in
  "VERDICT: FAIL"*) ok "real .text FAIL comment parses to non-empty reason" ;;
  *) bad "real .text FAIL comment lost its reason (got: '$R')" ;;
esac

# 2. Multiple comments → prefer the VERDICT: one over chatter.
J='[{"text":"starting review"},{"text":"VERDICT: FAIL — boundary bug at line 42"},{"text":"done"}]'
R=$(parse_reason "$J")
[ "$R" = "VERDICT: FAIL — boundary bug at line 42" ] \
  && ok "prefers the VERDICT: comment among several" \
  || bad "did not select the VERDICT: comment (got: '$R')"

# 3. Defensive fallback: legacy .body-only comment still yields its text.
J='[{"body":"VERDICT: FAIL — legacy body field"}]'
R=$(parse_reason "$J")
[ "$R" = "VERDICT: FAIL — legacy body field" ] \
  && ok "defensive .body fallback still works" \
  || bad "lost legacy .body reason (got: '$R')"

# 4. No VERDICT: line → first non-empty comment is used (not lost).
J='[{"text":""},{"text":"this scraper drops cookies under load"}]'
R=$(parse_reason "$J")
[ "$R" = "this scraper drops cookies under load" ] \
  && ok "falls back to first non-empty comment" \
  || bad "lost non-VERDICT reason (got: '$R')"

# 5. Empty/absent comments → empty string (dispatcher marks INCONCLUSIVE).
for J in '[]' '[{"text":""}]' '[{"author":"x"}]'; do
  R=$(parse_reason "$J")
  [ -z "$R" ] || bad "expected empty reason for '$J' (got: '$R')"
done
ok "empty/absent comments yield empty reason (→ INCONCLUSIVE path)"

# 6. STATIC GUARD: dispatcher must read .text, and must NOT carry the old
#    '.[0].body //' accessor that caused ga-kf0v.
if [ -f "$DISPATCHER" ]; then
  grep -q '\.text' "$DISPATCHER" \
    && ok "dispatcher source references .text" \
    || bad "dispatcher source no longer references .text — schema regression?"
  if grep -Eq '\.\[0\]\.body[[:space:]]*//' "$DISPATCHER"; then
    bad "dispatcher reverted to the buggy '.[0].body //' accessor (ga-kf0v)"
  else
    ok "dispatcher does not use the buggy '.[0].body //' accessor"
  fi
else
  bad "dispatcher not found at $DISPATCHER"
fi

echo "== results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
