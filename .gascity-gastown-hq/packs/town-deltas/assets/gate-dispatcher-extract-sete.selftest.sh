#!/usr/bin/env bash
# gate-dispatcher-extract-sete.selftest.sh (ga-7zjs1)
#
# Proves the rig-less-marker fix: a /gate-done marker whose description omits the
# `rig:` field must NOT abort the dispatcher.
#
# ROOT CAUSE it guards: quality-gate-dispatcher.sh runs `set -euo pipefail`. The
# field extractor `echo "$DESC" | grep -E "^$1:" | head -1 | sed ...` exits 1 on a
# no-match (grep) and pipefail propagates it, so `RIG=$(extract "rig")` killed the
# WHOLE dispatcher right after it logged "claimed for dispatching" — before the
# bead-id-prefix rig fallback that exists precisely to handle a missing rig.
# Crew markers omit `rig:`, so every crew marker stalled the gate town-wide.
#
# Strategy: extract the live extract() definition VERBATIM from the dispatcher and
# exercise it under the SAME `set -euo pipefail` the dispatcher uses, against a
# real-shaped rig-less marker description. Then drift-guard the shipped source so a
# future edit that drops the `|| true` re-breaks this test.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-dispatcher-extract-sete.selftest =="

# A real-shaped crew marker description WITHOUT a `rig:` field.
RIGLESS_DESC="branch: crew/digo/wa-v0td
bead_id: wa-v0td
sha: d429ea366f259d4391d5a541f7b2a4d7c54caef3
base_commit: 715d8fd047f66e28d2f5bc147b9ed3d163a20c41
note: example fix.
submitted_at: 2026-06-12T13:17:19Z"

# Pull the LIVE extract() definition verbatim so this test cannot drift from the
# shipped code.
EXTRACT_DEF="$(grep -E '^extract\(\) \{' "$DISPATCHER" | head -1)"
if [ -z "$EXTRACT_DEF" ]; then
  bad "could not locate extract() definition in dispatcher"
else
  ok "located live extract() definition"
fi

# Run the live extract() under the dispatcher's own `set -euo pipefail`, pulling
# every field including the absent `rig:`. The subshell must reach the end and
# exit 0; pre-fix it aborted at `RIG=$(extract "rig")`.
RESULT="$(
  bash -c '
    set -euo pipefail
    DESC="$1"
    '"$EXTRACT_DEF"'
    BRANCH=$(extract "branch")
    BEAD_ID=$(extract "bead_id")
    BASE_COMMIT=$(extract "base_commit")
    RIG=$(extract "rig")
    echo "REACHED|branch=${BRANCH}|bead_id=${BEAD_ID}|rig=${RIG:-unknown}"
  ' _ "$RIGLESS_DESC" 2>/dev/null
)"
RC=$?

if [ "$RC" -eq 0 ]; then ok "extract() survives a rig-less description under set -e"; else bad "extract() aborted under set -e (rc=$RC) on rig-less description"; fi
case "$RESULT" in
  REACHED*) ok "dispatcher field-extraction reached completion (would proceed to rig fallback)";;
  *)        bad "field-extraction did not complete; got: '$RESULT'";;
esac
case "$RESULT" in
  *"|rig=unknown") ok "absent rig: yields empty rig (downstream bead-prefix fallback applies)";;
  *)               bad "rig field not empty as expected; got: '$RESULT'";;
esac
case "$RESULT" in
  *"branch=crew/digo/wa-v0td"*) ok "present fields (branch) still extracted correctly";;
  *)                            bad "present field extraction broke; got: '$RESULT'";;
esac

# Drift-guard: the shipped extract() MUST carry the `|| true` terminator, else the
# set -e abort returns. Match the pipeline tail explicitly.
if grep -Eq '^extract\(\) \{ echo .*\| sed .* \|\| true; \}' "$DISPATCHER"; then
  ok "shipped extract() retains '|| true' terminator (drift guard)"
else
  bad "shipped extract() is missing the '|| true' terminator — set -e abort can recur"
fi

echo "== extract-sete: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
