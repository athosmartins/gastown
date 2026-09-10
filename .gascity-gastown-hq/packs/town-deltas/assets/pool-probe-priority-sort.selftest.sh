#!/usr/bin/env bash
# pool-probe-priority-sort.selftest.sh — regression guard for ga-x80j1.
#
# ga-x80j1: wa-worker's and ps-worker's prompt.template.md each carry a
# hand-typed "Step 1b3" bd-ready probe (see pool-probe-text-veto-family
# .selftest.sh's header for why this hardcoded copy is the ONLY routed-pool
# query a Pilot-spawned worker ever runs — Step 1b2 is Go-rendered and gated
# on GC_SESSION_ORIGIN=ephemeral, silently skipped for `gc session new`
# spawns). Both copies explicitly passed `--sort oldest`, overriding bd
# ready's own default (`bd ready --help`: "Sort policy: priority (default),
# hybrid, oldest") to raw creation-time FIFO. Verified live 2026-09-10
# against the real WA routed-pool backlog: --sort oldest put a priority=2
# bead ahead of five priority=1 beads created later — a fresh high-priority
# dispatch (e.g. a P0) could sit behind an older, lower-priority backlog
# indefinitely, while the spawned worker self-claimed the wrong bead.
#
# The fix is NOT a plain `--sort priority` swap. The engine's own
# routedReadyTierCommand (internal/config/config.go — renders the gated
# Step 1b2 this file mirrors) deliberately sorts survivors by `updated_at`
# instead of priority (see its ga-w4k2z comment): a repeatedly-reclaimed
# bead's created_at never changes, so ANY static sort key (age OR priority)
# lets that one poisoned bead re-occupy position 0 forever and starve every
# sibling behind it. So the corrected Step 1b3 line does both: `--sort
# priority` bounds the fetched candidate window by priority (a large
# low-priority backlog can't push a fresh P0 out of the --limit=20 window
# before the jq filters even see it), and the jq tail's compound
# `sort_by([.priority, (.updated_at // .created_at // "")])` re-sorts
# survivors with priority as the dominant key and ga-w4k2z's own
# LRU-by-updated_at as the tiebreak WITHIN each priority tier.
#
# This guard runs the ACTUAL jq program extracted from both templates
# against synthetic multi-bead fixtures (not just a text/flag assertion) so
# it catches both a reversion to plain age-sort AND a naive swap to plain
# priority-sort that drops the anti-starvation tiebreak:
#   1. priority dominates: a priority=0 bead with an OLDER updated_at must
#      still lose to nothing — i.e. must win over a priority=1 bead with a
#      NEWER updated_at (proves priority beats recency).
#   2. anti-starvation tiebreak: within the SAME priority, a bead whose
#      updated_at was just bumped (simulating a fresh reclaim) must lose to
#      a same-priority sibling that hasn't been touched since creation
#      (proves a poisoned bead can't re-monopolize position 0 forever).
#   3. the literal reported shape: priority=2/older vs priority=1/newer —
#      the priority=1 bead must win (this is the exact wa-j4bzx repro).
#   4. missing updated_at falls back to created_at without erroring.
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
# Same technique as pool-probe-text-veto-family.selftest.sh's extractor,
# duplicated (not sourced) so this guard fails loudly on its own if the line
# shape changes, rather than silently inheriting a broken extractor.
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

# assert_winner <label> <jq-program> <fixture-array-json> <expected-id>
# Feeds the WHOLE fixture array through the real Step 1b3 filter+sort chain
# (which itself ends in .[:1]) and checks the single survivor's id.
assert_winner() {
  local label="$1" prog="$2" fixture="$3" expected="$4"
  local out rc got_id
  out="$(printf '%s' "$fixture" | jq -c --argjson now_ts "$(date +%s)" "$prog" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$label: jq program failed: $out"
    return
  fi
  got_id="$(printf '%s' "$out" | jq -r '.[0].id // "EMPTY"' 2>/dev/null)"
  if [ "$got_id" = "$expected" ]; then
    ok "$label: winner is $expected as expected"
  else
    bad "$label: expected winner $expected, got $got_id (full output: $out)"
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

  # 1. priority dominates recency: p0/old-touch must beat p1/new-touch.
  assert_winner "$label priority-dominates" "$prog" \
    '[{"id":"p0-old-touch","priority":0,"updated_at":"2026-01-01T00:00:00Z"},{"id":"p1-new-touch","priority":1,"updated_at":"2026-09-10T22:00:00Z"}]' \
    "p0-old-touch"

  # 2. anti-starvation tiebreak: same priority, the just-reclaimed (recently
  # touched) bead must lose to the untouched sibling — mirrors ga-w4k2z.
  assert_winner "$label anti-starvation-tiebreak" "$prog" \
    '[{"id":"just-reclaimed","priority":1,"updated_at":"2026-09-10T22:00:00Z"},{"id":"never-touched","priority":1,"updated_at":"2026-01-01T00:00:00Z"}]' \
    "never-touched"

  # 3. literal reported shape: priority=2/older vs priority=1/newer — the
  # priority=1 bead must win (the exact wa-j4bzx-vs-wa-qjjj6 repro).
  assert_winner "$label literal-repro" "$prog" \
    '[{"id":"wa-j4bzx-like","priority":2,"created_at":"2026-09-10T17:35:12Z","updated_at":"2026-09-10T17:35:12Z"},{"id":"wa-qjjj6-like","priority":1,"created_at":"2026-09-10T19:49:21Z","updated_at":"2026-09-10T19:49:21Z"}]' \
    "wa-qjjj6-like"

  # 4. missing updated_at falls back to created_at without erroring.
  assert_winner "$label updated-at-fallback" "$prog" \
    '[{"id":"no-updated-at","priority":1,"created_at":"2026-01-01T00:00:00Z"},{"id":"has-updated-at","priority":1,"updated_at":"2026-09-10T22:00:00Z","created_at":"2026-01-01T00:00:00Z"}]' \
    "no-updated-at"
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
