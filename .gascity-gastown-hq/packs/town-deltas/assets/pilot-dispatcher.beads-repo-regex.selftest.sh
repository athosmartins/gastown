#!/usr/bin/env bash
# pilot-dispatcher.beads-repo-regex.selftest.sh — Regression guard for
# bead_targets_beads_repo() keyword coverage (ga-yn5w8, ga-51c63z).
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
# Bug ga-51c63z (3rd recurrence, new failure SOURCE): ga-rmtzrg's body cited
# a beads-repo GitHub URL as supporting EVIDENCE for an unrelated diagnosis
# (found while working dc-6jaq), not as its own fix target — the bug's real,
# only fix target was an HQ file (quality-gate-guard.sh). The literal
# substring "gastownhall/beads" inside that cited URL still matched, so
# IS_BEADS_REPO_FIX false-positived on a normal HQ bugfix. Same defect shape
# as ga-yn5w8/ga-j0f6 (keyword match can't tell subject from incidental
# mention), new source (a URL citation, not doctrine/phrasing text).
#
# Fix: strip URLs from the haystack before matching (mirrors
# _bead_path_haystack's own URL-stripping below in this file, added for
# ga-xzfl) — a bug rarely names its OWN fix target as a bare URL.
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

echo "── 7. ga-51c63z real repro: beads-repo URL cited as EVIDENCE must NOT match ──"
RESULT=$(bead_targets_beads_repo "$(bead_json \
  'quality-gate-guard.sh GAP-3 false-reflip on the new staleness guard' \
  'Found while working an unrelated beads-CLI story (dc-6jaq). See https://github.com/gastownhall/beads/pull/5826#issuecomment-5350930119 for background on how this was found. The actual, only fix target is packs/town-deltas/assets/quality-gate-guard.sh.')")
if [ "$RESULT" = "" ]; then
  ok "beads-repo URL cited only as evidence correctly stays fail-open (got '$RESULT')"
else
  bad "beads-repo URL cited only as evidence FALSE-POSITIVED (got '$RESULT', want '') — the ga-51c63z symptom"
fi

echo "── 8. bare (non-URL) repo mention still matches even beside an unrelated URL ──"
RESULT=$(bead_targets_beads_repo "$(bead_json 'fix the gastownhall/beads CLI parser' \
  'See https://example.com/unrelated/thread for background context.')")
if [ "$RESULT" = "1" ]; then
  ok "bare repo-name mention still matches with an unrelated URL present (URL-strip didn't over-widen)"
else
  bad "bare repo-name mention stopped matching (got '$RESULT', want '1') — URL-strip fix over-widened"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
