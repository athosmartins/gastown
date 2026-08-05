#!/usr/bin/env bash
# pilot-dispatcher.beads-repo-regex.selftest.sh — Regression guard for
# bead_targets_beads_repo() keyword coverage (ga-yn5w8).
#
# Bug ga-yn5w8: bead_targets_beads_repo() only matched six literal repo
# names/paths (steveyegge/beads, gastownhall/beads, athosmartins/beads,
# gt/beads, "beads repo", "beads-repo"). A real beads-CLI-repo fix
# (ga-yp9r8) described itself in "bd binary" terms and cited the HQ memory
# slug "bd-binary-separate-from-gascity-engine" instead of naming the repo
# — none of the six literals matched, so IS_BEADS_REPO_FIX stayed empty and
# Pilot dispatched the normal "no human review required, autonomous
# gate+delivery" doctrine for a fix that actually needed the upstream-PR
# doctrine (commit -> push fork -> gh pr create, /gate-done cannot find
# the branch). This is the second occurrence of this failure class
# (ga-j0f6 fixed a different upstream root cause of the same symptom;
# ga-7r884 flagged a follow-up that was never filed until ga-yn5w8).
#
# Fix: add the memory slug as a seventh literal, same false-positive
# profile as the existing six (specific, narrow, stable compound string).
#
# This harness extracts the REAL function body verbatim (sed -n range,
# matching the convention already used by gate-bd-show-jq-pipeline-guard.
# selftest.sh's read_rebase_attempt() extraction) and calls it directly
# against real and synthetic bead JSON — no bd/gc/Dolt/network, jq only.
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

FN_BLOCK="$(sed -n '/^bead_targets_beads_repo() {/,/^}/p' "$DISPATCHER" 2>/dev/null || true)"
if [ -z "$FN_BLOCK" ]; then
  echo "FATAL: bead_targets_beads_repo() not found in $DISPATCHER (renamed/removed?)" >&2
  exit 2
fi
eval "$FN_BLOCK"

bead_json() {
  # $1=title $2=description
  jq -n --arg t "$1" --arg d "$2" '{title: $t, description: $d, labels: []}'
}

echo "── 1. drift-guard: memory-slug literal present in the live function ──"
if printf '%s' "$FN_BLOCK" | grep -q 'bd-binary-separate-from-gascity-engine'; then
  ok "bd-binary-separate-from-gascity-engine literal present"
else
  bad "bd-binary-separate-from-gascity-engine literal MISSING (ga-yn5w8 regressed)"
fi

echo "── 2. real repro case (ga-yp9r8-shaped): memory slug in description ──"
RESULT=$(bead_targets_beads_repo "$(bead_json 'bd comment has no ID validation' \
  'Suggested fix (bd binary, not gascity engine — see bd-binary-separate-from-gascity-engine for the distinction)')")
if [ "$RESULT" = "1" ]; then
  ok "memory-slug citation in description correctly flags IS_BEADS_REPO_FIX=1"
else
  bad "memory-slug citation in description did NOT flag (got '$RESULT', want '1') — the exact ga-yn5w8 symptom"
fi

echo "── 3. memory slug in title alone also matches ──"
RESULT=$(bead_targets_beads_repo "$(bead_json 'fix per bd-binary-separate-from-gascity-engine' '')")
if [ "$RESULT" = "1" ]; then
  ok "memory-slug citation in title correctly flags IS_BEADS_REPO_FIX=1"
else
  bad "memory-slug citation in title did NOT flag (got '$RESULT', want '1')"
fi

echo "── 4. pre-existing literals still match (no regression on the original six) ──"
for literal in 'steveyegge/beads' 'gastownhall/beads' 'athosmartins/beads' 'gt/beads' 'beads repo' 'beads-repo'; do
  RESULT=$(bead_targets_beads_repo "$(bead_json "fix: $literal thing" '')")
  if [ "$RESULT" = "1" ]; then
    ok "pre-existing literal '$literal' still matches"
  else
    bad "pre-existing literal '$literal' stopped matching (got '$RESULT', want '1')"
  fi
done

echo "── 5. no false-positive widening: bare bd/beads mentions still fail-open ──"
RESULT=$(bead_targets_beads_repo "$(bead_json 'bd list shows stale beads in the dashboard' \
  'The bd command and bead terminology appear here but this is a gascity-rig UI bug, not a beads-CLI-repo fix.')")
if [ "$RESULT" = "" ]; then
  ok "bare 'bd'/'beads' mentions correctly stay fail-open (no widening beyond the memory slug)"
else
  bad "bare 'bd'/'beads' mentions now false-positive (got '$RESULT', want '') — regex widened too far"
fi

echo "── 6. empty bead text stays fail-open ──"
RESULT=$(bead_targets_beads_repo "$(bead_json '' '')")
if [ "$RESULT" = "" ]; then
  ok "empty title+description stays fail-open"
else
  bad "empty title+description unexpectedly matched (got '$RESULT', want '')"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
