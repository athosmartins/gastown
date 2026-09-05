#!/usr/bin/env bash
# pool-probe-text-veto-family.selftest.sh — regression guard for ga-3ife8.
#
# ga-3ife8: wa-worker's and ps-worker's prompt.template.md each carry a
# hand-typed "Step 1b3" jq probe that duplicates the Go-rendered Step 1b2
# (.RoutedPoolQuery, allegedly poolDemandLabelFilterJQ per ga-42mlf/ga-s1d5o's
# commit messages — NOT independently confirmed to exist in current
# origin/main source, see ga-c2w3k) — it exists because that Go-rendered
# probe is GATED on GC_SESSION_ORIGIN=ephemeral (ga-dbibq) and silently
# skipped for a pilot-spawned worker, so Step 1b3 is the copy such a worker
# ALWAYS runs. Being plain text in a .md file, it does not inherit
# engine-side fixes automatically regardless of whether those fixes actually
# landed. Nine prior fixes (ga-y8qh, ga-nf4x5, ga-en2s, ga-uvfs6, ga-3lsy1,
# ga-7ha7g, ga-znlvl, ga-s1d5o, ga-6bghe) each patched one label this copy
# had drifted behind pilot-dispatcher.sh; ga-3ife8 is the 10th — this time
# pilot:text-veto:<slug> (ga-42mlf's close reason claims an engine-side
# exclusion added 2026-09-02; Step 1b3 never picked it up regardless, and
# offered a bead vetoed by pilot:text-veto:compliance-marker-text-pattern as
# candidate #1 on 2026-09-04).
#
# This guard extracts the LIVE jq program out of Step 1b3 in both
# agents/wa-worker/prompt.template.md and agents/ps-worker/prompt.template.md
# and runs it against synthetic bead JSON — so it fails if either file's
# actual text regresses, not just at the moment this test was written.
#
# Each fixture bead is tested ALONE, wrapped in its own single-element array.
# Step 1b3's jq program ends in `.[:1]` (top-1 candidate only) — feeding it a
# multi-bead array would let one non-excluded bead occupy the single output
# slot and hide whether the OTHER beads would also have been (in)correctly
# excluded. Testing one bead per invocation makes each assertion independent
# of fixture ordering.
#
# Cases:
#   5 known pilot:text-veto:<slug> labels — each must be EXCLUDED (output []).
#   1 hypothetical NEVER-SEEN slug — must ALSO be excluded. This is the
#     literal ga-3ife8 acceptance criterion: matching by FAMILY PREFIX
#     (startswith("pilot:text-veto")) rather than an enumerated slug list
#     means a 6th slug added to pilot-dispatcher's _TEXT_VETO_PATTERNS needs
#     NO prompt edit here.
#   1 lookalike label that merely CONTAINS "text-veto" without the "pilot:"
#     owner prefix — must SURVIVE (proves the match is anchored to the
#     prefix, not a loose substring).
#   1 clean bead with unrelated labels — must SURVIVE (proves no over-match).
#
# Exit 0 iff every scenario, for both files, behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

# extract_step1b3_jq <template-file> — pulls the jq PROGRAM (the single-quoted
# argument to `jq --argjson now_ts "$(date +%s)"`) out of the Step 1b3 line.
# Anchored on the exact opening/closing text every such line shares (verified
# against both files at the time this test was written) so a change to the
# label list is picked up automatically, but a structural rewrite of the line
# fails LOUDLY (empty extraction) rather than silently testing stale text.
extract_step1b3_jq() {
  local tpl="$1"
  local line
  line="$(grep -F '| jq --argjson now_ts "$(date +%s)" ' "$tpl" | grep -F 'bd ready --metadata-field "gc.routed_to=' | head -1)"
  if [ -z "$line" ]; then
    return 1
  fi
  local marker
  marker='| jq --argjson now_ts "$(date +%s)" '"'"
  local after="${line#*$marker}"
  if [ "$after" = "$line" ]; then
    return 1
  fi
  local prog="${after%\'}"
  if [ -z "$prog" ] || [ "$prog" = "$after" ]; then
    return 1
  fi
  printf '%s' "$prog"
}

# check_excluded <label> <jq-program> <bead-json-object> <bead-id>
# Wraps the single bead in its own array and asserts the filter drops it.
check_excluded() {
  local label="$1" prog="$2" bead_json="$3" bead_id="$4"
  local out rc
  out="$(printf '[%s]' "$bead_json" | jq -c --argjson now_ts "$(date +%s)" "$prog" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$label: jq program failed on $bead_id: $out"
    return
  fi
  if [ "$out" = "[]" ]; then
    ok "$label: vetoed bead $bead_id correctly excluded"
  else
    bad "$label: vetoed bead $bead_id was NOT excluded (output: $out)"
  fi
}

# check_survives <label> <jq-program> <bead-json-object> <bead-id>
# Wraps the single bead in its own array and asserts the filter keeps it.
check_survives() {
  local label="$1" prog="$2" bead_json="$3" bead_id="$4"
  local out rc
  out="$(printf '[%s]' "$bead_json" | jq -c --argjson now_ts "$(date +%s)" "$prog" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$label: jq program failed on $bead_id: $out"
    return
  fi
  if printf '%s' "$out" | grep -q "\"$bead_id\""; then
    ok "$label: survivor $bead_id correctly present"
  else
    bad "$label: survivor $bead_id was over-matched / dropped (output: $out)"
  fi
}

run_case() {
  local label="$1" tpl="$2"
  if [ ! -f "$tpl" ]; then
    bad "$label: template not found at $tpl"
    return
  fi
  local prog
  if ! prog="$(extract_step1b3_jq "$tpl")"; then
    bad "$label: could not extract Step 1b3 jq program from $tpl (line shape changed?)"
    return
  fi

  check_excluded "$label" "$prog" '{"id":"tv-engine-rebuild","labels":["pilot:text-veto:engine-rebuild-text-pattern"]}' "tv-engine-rebuild"
  check_excluded "$label" "$prog" '{"id":"tv-decisao-title","labels":["pilot:text-veto:decisao-title-text-pattern"]}' "tv-decisao-title"
  check_excluded "$label" "$prog" '{"id":"tv-athos-decide","labels":["pilot:text-veto:athos-decide-phrase-text-pattern"]}' "tv-athos-decide"
  check_excluded "$label" "$prog" '{"id":"tv-compliance-marker","labels":["area:infra","pilot:text-veto:compliance-marker-text-pattern"]}' "tv-compliance-marker"
  check_excluded "$label" "$prog" '{"id":"tv-diagnostic-only","labels":["pilot:text-veto:diagnostic-only-text-pattern"]}' "tv-diagnostic-only"
  check_excluded "$label" "$prog" '{"id":"tv-future-slug","labels":["pilot:text-veto:some-slug-nobody-has-invented-yet"]}' "tv-future-slug"
  check_survives "$label" "$prog" '{"id":"lookalike-survives","labels":["story:text-veto-mentioned"]}' "lookalike-survives"
  check_survives "$label" "$prog" '{"id":"clean-survives","labels":["area:infra","lane:small"]}' "clean-survives"
}

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

run_case "wa-worker Step 1b3" "$CITY_ROOT/agents/wa-worker/prompt.template.md"
run_case "ps-worker Step 1b3" "$CITY_ROOT/agents/ps-worker/prompt.template.md"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
