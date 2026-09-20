#!/usr/bin/env bash
# pool-probe-next-action-family.selftest.sh — regression guard for ga-onrnd6.
#
# ga-onrnd6: wa-worker's and ps-worker's prompt.template.md each carry a
# hand-typed "Step 1b2" jq probe (the un-gated, priority-aware routed-pool
# probe every session runs first — see ga-0pg2o) and a "Step 1b3" fallback
# post-filter wrapped around the Go-rendered {{ .RoutedPoolQuery }}. Neither
# excluded next-action:* — this probe bypasses Pilot's own
# _filter_label_vetoes (pilot-dispatcher.sh) entirely, so it had no
# awareness of this label at all. Live incident: wa-k1sr7 (a mockup task,
# DONE — 3 options posted, presigned S3 link verified live — and correctly
# parked with next-action:athos-decide awaiting Athos's A/B/C pick, zero
# code left to write) was still offered as a fresh candidate by this exact
# probe and dispatched 6 times before a human noticed the loop.
#
# next-action: is OVERLOADED with two opposite meanings (pilot-dispatcher.sh's
# _filter_label_vetoes gate (d) comment is the source of truth this mirrors,
# character-for-character): the original convention (bare next-action:mayor,
# next-action:athos+oracle, next-action:athos-decide) means "blocked on
# Athos/a dependency" and must veto; refino's newer next-action:<crew>-
# constroi/-reconstroi/-corrige-gate/-corrige convention means the OPPOSITE —
# "ready, <crew> is who builds it" (ga-f7bek) — and must survive. Omitting
# that carve-out would reinstate the exact 24h starvation bug ga-f7bek fixed.
#
# Sibling fix, same predicate fragment verbatim: ga-473mkh patched
# poolDemandLabelFilterJQ() (internal/config/config.go — the dog pool's own
# Step 1c probe) for this identical gap one day earlier, confirmed live via
# ga-boftko (bare next-action:mayor, 2026-09-16). This test's fixture set
# mirrors that patch's own Go test
# (TestPoolDemandLabelFilterJQExcludesNextActionParkUnlessBuildVerb)
# case-for-case, so both implementations are provably tested against the
# same behavioral contract.
#
# Deliberately NARROW, matching both the live incidents and the reviewed
# ga-473mkh sibling fix: this only covers next-action:*, not the rest of
# _filter_label_vetoes's family (waiting-on:/blocked-on:/depends-on:), which
# neither probe excludes and which no live incident has named on either
# probe. See the ga-onrnd6 comment in both template files for that known,
# deliberately-unaddressed gap.
#
# This guard extracts the LIVE jq programs (Step 1b2's `bd ready | jq
# --argjson now_ts ...` line, and Step 1b3's `{{ .RoutedPoolQuery }} | jq -c
# ...` line) out of both agents/wa-worker/prompt.template.md and
# agents/ps-worker/prompt.template.md and runs them against synthetic bead
# JSON — so it fails if either file's actual text regresses, not just at the
# moment this test was written.
#
# Each fixture bead is tested ALONE, wrapped in its own single-element array
# (same reasoning as pool-probe-text-veto-family.selftest.sh: Step 1b2 ends
# in `.[:1]`, so a multi-bead array would let one non-excluded bead occupy
# the single output slot and hide whether siblings would also have been
# (in)correctly excluded).
#
# Cases (both probes, both files):
#   next-action:athos-decide, next-action:athos+oracle, bare next-action:mayor
#     — each must be EXCLUDED (output []).
#   next-action:*-constroi, *-reconstroi, *-corrige-gate, *-corrige — each
#     must SURVIVE (the ga-f7bek build-verb carve-out).
#   waiting-on:*, blocked-on:*, depends-on:*, blocked-by:* — each must
#     SURVIVE on THESE two probes (the known, deliberately-unaddressed
#     adjacent gap above) — this pins the CURRENT narrow scope so a future
#     broadening is a deliberate edit here, not a silent behavior change
#     nobody notices either way.
#   a label merely CONTAINING "next-action" without the anchored prefix
#     (story:next-action-mentioned) — must SURVIVE (proves the match is
#     anchored, not a loose substring).
#   a clean bead with unrelated labels — must SURVIVE (proves no over-match).
#
# Exit 0 iff every scenario, for both probes, for both files, behaves as
# expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

# extract_step1b2_jq <template-file> — pulls the jq PROGRAM (the single-quoted
# argument to `jq --argjson now_ts "$(date +%s)"`) out of the Step 1b2 line —
# same extraction technique as pool-probe-text-veto-family.selftest.sh's
# extract_step1b3_jq (that helper's name predates ga-0pg2o's Step 1b2/1b3
# renumbering; it extracts the same physical line this function targets).
extract_step1b2_jq() {
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

# extract_step1b3_fallback_jq <template-file> — pulls the jq PROGRAM out of
# the Step 1b3 fallback line: `{{ .RoutedPoolQuery }} | jq -c '...'`. This
# program takes NO --argjson (no now_ts, no pilot:held check — that gate
# lives only in Step 1b2; the fallback only post-filters what the
# Go-rendered query already returned).
extract_step1b3_fallback_jq() {
  local tpl="$1"
  local line
  line="$(grep -F '{{ .RoutedPoolQuery }} | jq -c ' "$tpl" | head -1)"
  if [ -z "$line" ]; then
    return 1
  fi
  local marker='{{ .RoutedPoolQuery }} | jq -c '"'"
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

# check_excluded/check_survives <label> <jq-program> <bead-json-object> <bead-id> [--now]
# Wraps the single bead in its own array and asserts the filter drops/keeps
# it. Pass --now (as a 5th arg) for a Step 1b2 program, which requires
# --argjson now_ts.
run_jq() {
  local prog="$1" bead_json="$2" needs_now="${3:-}"
  if [ "$needs_now" = "--now" ]; then
    printf '[%s]' "$bead_json" | jq -c --argjson now_ts "$(date +%s)" "$prog" 2>&1
  else
    printf '[%s]' "$bead_json" | jq -c "$prog" 2>&1
  fi
}

check_excluded() {
  local label="$1" prog="$2" bead_json="$3" bead_id="$4" needs_now="${5:-}"
  local out rc
  out="$(run_jq "$prog" "$bead_json" "$needs_now")"
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

check_survives() {
  local label="$1" prog="$2" bead_json="$3" bead_id="$4" needs_now="${5:-}"
  local out rc
  out="$(run_jq "$prog" "$bead_json" "$needs_now")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$label: jq program failed on $bead_id: $out"
    return
  fi
  if printf '%s' "$out" | grep "\"$bead_id\"" >/dev/null; then
    ok "$label: survivor $bead_id correctly present"
  else
    bad "$label: survivor $bead_id was over-matched / dropped (output: $out)"
  fi
}

# run_family_cases <label> <jq-program> [--now]
# The full case battery, shared by Step 1b2 and Step 1b3 fallback (the
# fallback program has no priority/id-only fields, but every clause under
# test here only reads .labels, so the same minimal fixtures apply to both).
run_family_cases() {
  local label="$1" prog="$2" needs_now="${3:-}"

  check_excluded "$label" "$prog" '{"id":"na-athos-decide","priority":1,"labels":["next-action:athos-decide"]}' "na-athos-decide" "$needs_now"
  check_excluded "$label" "$prog" '{"id":"na-athos-plus-oracle","priority":1,"labels":["next-action:athos+oracle"]}' "na-athos-plus-oracle" "$needs_now"
  check_excluded "$label" "$prog" '{"id":"na-bare-mayor","priority":1,"labels":["next-action:mayor"]}' "na-bare-mayor" "$needs_now"

  check_survives "$label" "$prog" '{"id":"na-constroi","priority":1,"labels":["next-action:crew-constroi"]}' "na-constroi" "$needs_now"
  check_survives "$label" "$prog" '{"id":"na-reconstroi","priority":1,"labels":["next-action:crew-reconstroi"]}' "na-reconstroi" "$needs_now"
  check_survives "$label" "$prog" '{"id":"na-corrige-gate","priority":1,"labels":["next-action:crew-corrige-gate"]}' "na-corrige-gate" "$needs_now"
  check_survives "$label" "$prog" '{"id":"na-corrige","priority":1,"labels":["next-action:crew-corrige"]}' "na-corrige" "$needs_now"

  # Known, deliberately-unaddressed adjacent gap (see file header + the
  # ga-onrnd6 comment in both templates): these three MUST currently survive
  # on this probe. If this test ever needs to change these three to
  # check_excluded, that is a deliberate scope-widening edit (with its own
  # bead), not a silent regression.
  check_survives "$label" "$prog" '{"id":"waiting-on-oracle","priority":1,"labels":["waiting-on:oracle"]}' "waiting-on-oracle" "$needs_now"
  check_survives "$label" "$prog" '{"id":"blocked-on-dep","priority":1,"labels":["blocked-on:ga-xyz"]}' "blocked-on-dep" "$needs_now"
  check_survives "$label" "$prog" '{"id":"depends-on-dep","priority":1,"labels":["depends-on:ga-xyz"]}' "depends-on-dep" "$needs_now"

  check_survives "$label" "$prog" '{"id":"blocked-by-lookalike","priority":1,"labels":["blocked-by:ga-xyz"]}' "blocked-by-lookalike" "$needs_now"
  check_survives "$label" "$prog" '{"id":"substring-lookalike","priority":1,"labels":["story:next-action-mentioned"]}' "substring-lookalike" "$needs_now"
  check_survives "$label" "$prog" '{"id":"clean-survives","priority":1,"labels":["area:infra","lane:small"]}' "clean-survives" "$needs_now"
}

run_case() {
  local tpl="$1"
  if [ ! -f "$tpl" ]; then
    bad "template not found at $tpl"
    return
  fi

  local prog_1b2
  if ! prog_1b2="$(extract_step1b2_jq "$tpl")"; then
    bad "$tpl Step 1b2: could not extract jq program (line shape changed?)"
  else
    run_family_cases "$tpl Step 1b2" "$prog_1b2" "--now"
  fi

  local prog_1b3
  if ! prog_1b3="$(extract_step1b3_fallback_jq "$tpl")"; then
    bad "$tpl Step 1b3 fallback: could not extract jq program (line shape changed?)"
  else
    run_family_cases "$tpl Step 1b3 fallback" "$prog_1b3"
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

run_case "$CITY_ROOT/agents/wa-worker/prompt.template.md"
run_case "$CITY_ROOT/agents/ps-worker/prompt.template.md"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
