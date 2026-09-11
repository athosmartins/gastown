#!/usr/bin/env bash
# pool-probe-delivery-pending-restart.selftest.sh — regression guard for ga-q65d8.
#
# ga-q65d8: wa-worker's and ps-worker's hand-typed routed-pool probe (Step
# 1b2 as of ga-0pg2o's 2026-09-10 renumbering; was "Step 1b3" before that)
# excludes pool:refused*, pilot:refused-reason:*, pilot:held/
# pilot:held-until:*, epic titles, blocked:*, gate:needs-human*,
# pilot:text-veto:* and a reclaim-count cap — but did NOT exclude
# delivery:pending-restart. This is the 11th instance of the established
# "probe never learned this label" class (ga-y8qh, ga-nf4x5, ga-en2s,
# ga-uvfs6, ga-3lsy1, ga-7ha7g, ga-znlvl, ga-s1d5o, ga-6bghe, ga-3ife8).
#
# delivery:pending-restart is the canonical, deliberate hold set by the
# daemon-verification mechanism (ga-l7n3v/ga-puq8z) when a bead's fix has
# already passed the quality gate and merged, but a long-lived hot-path
# daemon may still be running the old code: "done as far as any builder is
# concerned," the only remaining step being an operational guarded restart
# (sometimes gated on a domain-specialist's production-timing judgment
# call), never a code change. Live repro: wa-k2j6n (labels ctx:ready,
# delivery:pending-restart, exec:auto, gate:passed, lane:small,
# pilot:reclaim-count:1, scope:advisory; unassigned) cost 3 separate worker
# sessions a full from-scratch re-investigation each, because the gate had
# already passed — no branch-progress liveness signal is ever possible
# again for this bead — and it had already been explicitly routed by the
# Mayor to a named domain owner for a timing decision no generic ephemeral
# worker has the basis to make safely.
#
# The exact-match label is added in two places per template, both checked
# here:
#   1. Step 1b2's hardcoded `bd ready ... --exclude-label` flag list. This
#      filtering happens INSIDE `bd ready` itself, before jq ever sees the
#      results, so it cannot be exercised via a jq fixture — verified with a
#      structural (text) assertion instead, same technique as this file
#      family's assert_probe_before_fallback check.
#   2. Step 1b3's Go-rendered-fallback post-filter ({{ .RoutedPoolQuery }} |
#      jq -c '...'), added by the same "post-filter on the OUTPUT" technique
#      ga-0pg2o's gate-fix round 2 used for the reclaim-count-cap exclusion
#      — the Go-rendered query itself stays off-limits per that Mayor
#      decision, and this file's own documented drift history means an
#      exclusion landing on Step 1b2 is never assumed to reach Step 1b3
#      automatically. This clause IS pure jq, so it is exercised directly.
#
# Exit 0 iff every scenario, for both files, behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

# assert_step1b2_excludes_label <label> <template-file>
# Structural check: the hardcoded Step 1b2 probe line must carry the exact
# CLI flag `--exclude-label "delivery:pending-restart"`. Anchored on the same
# line-shape marker as pool-probe-priority-sort.selftest.sh's
# extract_priority_probe_jq (duplicated, not shared — this file family's own
# convention, so each guard fails loudly and independently if a line shape
# changes) so a structural rewrite of the probe line fails loudly rather than
# silently passing on stale text.
assert_step1b2_excludes_label() {
  local label="$1" tpl="$2"
  local line
  line="$(grep -F 'bd ready --metadata-field "gc.routed_to=' "$tpl" | grep -F '| jq --argjson now_ts "$(date +%s)" ' | head -1)"
  if [ -z "$line" ]; then
    bad "$label: could not locate the hardcoded Step 1b2 probe line in $tpl"
    return
  fi
  case "$line" in
    *'--exclude-label "delivery:pending-restart"'*)
      ok "$label: Step 1b2 probe line carries --exclude-label \"delivery:pending-restart\""
      ;;
    *)
      bad "$label: Step 1b2 probe line is missing --exclude-label \"delivery:pending-restart\""
      ;;
  esac
}

# extract_fallback_postfilter_jq <template-file> — pulls the jq PROGRAM out
# of the Step 1b3 post-filter ({{ .RoutedPoolQuery }} | jq -c '...'). Same
# extraction technique, and the same "duplicated, not shared" choice, as
# pool-probe-priority-sort.selftest.sh's function of the same name.
extract_fallback_postfilter_jq() {
  local tpl="$1"
  local line
  line="$(grep -F '{{ .RoutedPoolQuery }} | jq -c ' "$tpl" | head -1)"
  if [ -z "$line" ]; then
    return 1
  fi
  local marker
  marker='{{ .RoutedPoolQuery }} | jq -c '"'"
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

# assert_fallback_result <label> <jq-program> <fixture-array-json> <expected-array-json>
# Same technique as pool-probe-priority-sort.selftest.sh's function of the
# same name: compares the WHOLE compacted array, since the fallback
# post-filter preserves array shape (0 or 1 items) straight through.
assert_fallback_result() {
  local label="$1" prog="$2" fixture="$3" expected="$4"
  local out rc exp_norm
  out="$(printf '%s' "$fixture" | jq -c "$prog" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$label: jq program failed: $out"
    return
  fi
  exp_norm="$(printf '%s' "$expected" | jq -c '.' 2>/dev/null)"
  if [ "$out" = "$exp_norm" ]; then
    ok "$label: output matches expected ($exp_norm)"
  else
    bad "$label: expected $exp_norm, got $out"
  fi
}

run_case() {
  local label="$1" tpl="$2"
  if [ ! -f "$tpl" ]; then
    bad "$label: template not found at $tpl"
    return
  fi

  assert_step1b2_excludes_label "$label" "$tpl"

  local fallback_prog
  if ! fallback_prog="$(extract_fallback_postfilter_jq "$tpl")"; then
    bad "$label: could not extract Step 1b3 post-filter jq program from $tpl (line shape changed?)"
    return
  fi

  # 1. the literal reported repro: wa-k2j6n's exact label set must be
  # filtered out.
  assert_fallback_result "$label fallback-drops-wa-k2j6n-labels" "$fallback_prog" \
    '[{"id":"wa-k2j6n-like","labels":["ctx:ready","delivery:pending-restart","exec:auto","gate:passed","lane:small","pilot:reclaim-count:1","scope:advisory"]}]' \
    '[]'

  # 2. a clean bead with unrelated labels must survive unchanged.
  assert_fallback_result "$label fallback-keeps-clean-bead" "$fallback_prog" \
    '[{"id":"clean-fallback-bead","labels":["area:infra","lane:small"]}]' \
    '[{"id":"clean-fallback-bead","labels":["area:infra","lane:small"]}]'

  # 3. a genuinely empty fallback result ([]) must stay [] without erroring.
  assert_fallback_result "$label fallback-empty-stays-empty" "$fallback_prog" \
    '[]' \
    '[]'

  # 4. a lookalike label that CONTAINS "pending-restart" without matching
  # delivery:pending-restart exactly must survive — proves the match is an
  # exact-equality check, not a loose substring/prefix.
  assert_fallback_result "$label fallback-lookalike-survives" "$fallback_prog" \
    '[{"id":"lookalike-survives","labels":["delivery:pending-restart-extended"]}]' \
    '[{"id":"lookalike-survives","labels":["delivery:pending-restart-extended"]}]'

  # 5. regression guard on the pre-existing reclaim-cap clause (ga-0pg2o):
  # a capped bead with NO delivery:pending-restart label must still be
  # dropped — proves the new select was added alongside, not in place of,
  # the reclaim-cap exclusion.
  assert_fallback_result "$label fallback-still-drops-capped-bead" "$fallback_prog" \
    '[{"id":"poisoned-p0-at-cap","labels":["pilot:reclaim-count:3"]}]' \
    '[]'
}

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

run_case "wa-worker" "$CITY_ROOT/agents/wa-worker/prompt.template.md"
run_case "ps-worker" "$CITY_ROOT/agents/ps-worker/prompt.template.md"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
