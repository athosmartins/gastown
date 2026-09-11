#!/usr/bin/env bash
# pool-probe-priority-sort.selftest.sh — regression guard for ga-x80j1 + ga-0pg2o.
#
# ga-x80j1: wa-worker's and ps-worker's prompt.template.md each carry a
# hand-typed routed-pool probe (originally numbered "Step 1b3", renumbered to
# "Step 1b2" by ga-0pg2o — see below). Both copies explicitly passed `--sort
# oldest`, overriding bd ready's own default (`bd ready --help`: "Sort
# policy: priority (default), hybrid, oldest") to raw creation-time FIFO.
# Verified live 2026-09-10 against the real WA routed-pool backlog: --sort
# oldest put a priority=2 bead ahead of five priority=1 beads created later
# — a fresh high-priority dispatch (e.g. a P0) could sit behind an older,
# lower-priority backlog indefinitely, while the spawned worker self-claimed
# the wrong bead.
#
# The fix is NOT a plain `--sort priority` swap. The engine's own
# routedReadyTierCommand (internal/config/config.go — renders the gated
# Go-side query, now Step 1b3) deliberately sorts survivors by `updated_at`
# instead of priority (see its ga-w4k2z comment): a repeatedly-reclaimed
# bead's created_at never changes, so ANY static sort key (age OR priority)
# lets that one poisoned bead re-occupy position 0 forever and starve every
# sibling behind it. So the corrected probe line does both: `--sort
# priority` bounds the fetched candidate window by priority (a large
# low-priority backlog can't push a fresh P0 out of the --limit=20 window
# before the jq filters even see it), and the jq tail's compound
# `sort_by([.priority, (.updated_at // .created_at // "")])` re-sorts
# survivors with priority as the dominant key and ga-w4k2z's own
# LRU-by-updated_at as the tiebreak WITHIN each priority tier.
#
# ga-0pg2o (Mayor decision, 2026-09-10): ga-x80j1's fix only ever reached a
# Pilot-spawned (non-ephemeral-origin) session, because the Go-rendered
# query ({{ .RoutedPoolQuery }}) is GATED on GC_SESSION_ORIGIN=ephemeral
# (ga-dbibq) and was consulted FIRST in file order. A genuinely
# ephemeral-origin session still hit that gated, LRU-only query first and
# could still claim an older, lower-priority routed bead ahead of a fresh
# P0/P1 — the exact ga-x80j1 bug, just for a different origin. ga-0pg2o
# reordered both templates so the hardcoded, un-gated, priority-aware probe
# (renumbered "Step 1b2") now runs FIRST for every origin, and the
# Go-rendered query (renumbered "Step 1b3") is consulted only as a fallback
# if Step 1b2 found nothing. Putting priority first for every origin
# reopens the ga-w4k2z starvation risk in a new shape: a single always-failing
# P0/P1 bead with no same-priority sibling would win Step 1b2 on every
# session indefinitely (the updated_at tiebreak only protects a bead from a
# SIBLING at the same priority, not from being sole occupant of its tier).
# ga-0pg2o closes that gap by also excluding any bead at Pilot's reclaim-count
# cap (pilot-dispatcher.sh's own _FILTER_RECLAIM_CAP=3, mirrored here as a
# literal since the two scripts share no runtime state).
#
# This guard runs the ACTUAL jq program extracted from both templates
# against synthetic multi-bead fixtures (not just a text/flag assertion) so
# it catches a reversion to plain age-sort, a naive swap to plain
# priority-sort that drops the anti-starvation tiebreak, or a dropped
# reclaim-cap exclusion:
#   1. priority dominates: a priority=0 bead with an OLDER updated_at must
#      still lose to nothing — i.e. must win over a priority=1 bead with a
#      NEWER updated_at (proves priority beats recency).
#   2. anti-starvation tiebreak: within the SAME priority, a bead whose
#      updated_at was just bumped (simulating a fresh reclaim) must lose to
#      a same-priority sibling that hasn't been touched since creation
#      (proves a poisoned bead can't re-monopolize position 0 forever
#      against a SIBLING).
#   3. the literal reported shape: priority=2/older vs priority=1/newer —
#      the priority=1 bead must win (this is the exact wa-j4bzx repro).
#   4. missing updated_at falls back to created_at without erroring.
#   5. (ga-0pg2o) reclaim-cap exclusion: a priority=0 bead carrying
#      pilot:reclaim-count:3 (at Pilot's cap) must lose to a priority=1
#      sibling with no reclaim-count label — proves a poisoned bead with NO
#      same-priority sibling still cedes its slot once it hits the cap,
#      closing the gap the tiebreak alone (case 2) cannot close.
#   6. (ga-0pg2o) reclaim-count BELOW the cap must NOT be excluded: a
#      priority=0 bead carrying pilot:reclaim-count:2 must still win over a
#      priority=1 bead — proves the exclusion threshold is exactly ">=3",
#      not an overbroad "any reclaim-count label at all".
#   7. (ga-0pg2o gate-fix round 2, 2026-09-11) Step 1b3's fallback inherits
#      the SAME reclaim-cap exclusion, not just Step 1b2: round 1 excluded a
#      capped bead from Step 1b2 only, so when that bead is the sole
#      occupant of its priority tier, Step 1b2 correctly returns [] and the
#      Go-rendered fallback — which has zero reclaim-count awareness — used
#      to re-surface that SAME bead. Tested as a standalone post-filter (see
#      assert_fallback_result) rather than end-to-end, for the same reason
#      the structural check below is text-based: the Go-rendered query
#      itself is opaque to a pack-level selftest.
#
# A separate, non-jq structural check (test b from the ga-0pg2o bead: "a
# session of ephemeral origin chooses by priority") verifies the ORDERING
# ga-0pg2o's fix actually depends on: the hardcoded probe line must appear
# BEFORE the (real, uncommented) {{ .RoutedPoolQuery }} line in the
# template text. The Go-side gating on GC_SESSION_ORIGIN=ephemeral lives
# entirely inside the rendered template variable and is opaque to a
# pack-level selftest — but since a genuinely ephemeral-origin session is
# the ONLY origin for which that gated query ever produces real output,
# proving this probe precedes it in file order is exactly what guarantees
# an ephemeral-origin session's FIRST real routed-pool result comes from
# the priority-aware probe, not the LRU-only Go path.
#
# Exit 0 iff every scenario, for both files, behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

# extract_priority_probe_jq <template-file> — pulls the jq PROGRAM (the
# single-quoted argument to `jq --argjson now_ts "$(date +%s)"`) out of the
# hardcoded routed-pool probe line (Step 1b2 as of ga-0pg2o; was "Step 1b3"
# before that reorder — this extractor keys off the command shape, not the
# step number, so renumbering alone does not require touching it). Same
# technique as pool-probe-text-veto-family.selftest.sh's extractor,
# duplicated (not sourced) so this guard fails loudly on its own if the line
# shape changes, rather than silently inheriting a broken extractor.
extract_priority_probe_jq() {
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

# extract_fallback_postfilter_jq <template-file> — pulls the jq PROGRAM out
# of the Step 1b3 post-filter added by ga-0pg2o's gate-fix round 2: the
# `{{ .RoutedPoolQuery }} | jq -c '...'` line that re-applies the
# reclaim-cap exclusion to the Go-rendered fallback's own output. Same
# extraction technique as extract_priority_probe_jq above (key off the exact
# line shape, fail loudly if it changes) — deliberately a SEPARATE function
# rather than a shared helper, since the two lines have different anchors
# and mirroring extract_priority_probe_jq's own "duplicated, not shared"
# choice (see its comment) keeps each guard independently diagnosable.
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

# assert_winner <label> <jq-program> <fixture-array-json> <expected-id>
# Feeds the WHOLE fixture array through the real probe's filter+sort chain
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

# assert_fallback_result <label> <jq-program> <fixture-array-json> <expected-array-json>
# Unlike assert_winner (which picks a single winner out of several
# candidates), the Step 1b3 post-filter preserves array shape straight
# through — it receives the Go-rendered query's own already-.[0:1]-sliced
# output (0 or 1 items) and either keeps or drops that one item. So this
# compares the WHOLE compacted array rather than pulling out a single .id;
# no --argjson now_ts is passed since this post-filter clause (copied
# verbatim from Step 1b2) references no $now_ts.
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

# assert_probe_before_fallback <label> <template-file>
# Structural check for ga-0pg2o requirement #1 / reported test (b): the
# un-gated priority probe must appear BEFORE the Go-rendered fallback query
# ({{ .RoutedPoolQuery }}, real directive only — not a comment merely
# mentioning it by name) in the template text, so every session origin,
# including a genuinely ephemeral one, reaches the priority-aware probe
# first. A regression that moves {{ .RoutedPoolQuery }} back ahead of the
# hardcoded bd-ready line would silently revert the fix for ephemeral-origin
# sessions specifically, while a Pilot-spawned session (which never gets
# real output from the gated query regardless of position) would look
# completely unaffected — exactly the kind of regression a jq-fixture-only
# test cannot see, since both probes' jq logic would remain individually
# correct.
assert_probe_before_fallback() {
  local label="$1" tpl="$2"
  local probe_line fallback_line
  probe_line="$(grep -n -F 'bd ready --metadata-field "gc.routed_to=' "$tpl" | grep -F '| jq --argjson now_ts "$(date +%s)" ' | head -1 | cut -d: -f1)"
  fallback_line="$(grep -n -F '{{ .RoutedPoolQuery }}' "$tpl" | grep -v '^[0-9]*:#' | tail -1 | cut -d: -f1)"
  if [ -z "$probe_line" ]; then
    bad "$label: could not locate the hardcoded priority-probe line"
    return
  fi
  if [ -z "$fallback_line" ]; then
    bad "$label: could not locate an uncommented {{ .RoutedPoolQuery }} line"
    return
  fi
  if [ "$probe_line" -lt "$fallback_line" ]; then
    ok "$label: priority probe (line $probe_line) precedes Go-rendered fallback (line $fallback_line)"
  else
    bad "$label: priority probe (line $probe_line) does NOT precede Go-rendered fallback (line $fallback_line) — an ephemeral-origin session would hit the LRU-only Go query first, reopening ga-0pg2o"
  fi
}

run_case() {
  local label="$1" tpl="$2"
  if [ ! -f "$tpl" ]; then
    bad "$label: template not found at $tpl"
    return
  fi
  local prog
  if ! prog="$(extract_priority_probe_jq "$tpl")"; then
    bad "$label: could not extract priority-probe jq program from $tpl (line shape changed?)"
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

  # 5. (ga-0pg2o, reported test a) reclaim-cap exclusion: a P0 bead AT the
  # cap (reclaim-count:3) has no same-priority sibling to lose a tiebreak
  # to, so without this exclusion it would monopolize position 0 forever.
  # The following P1 (no reclaim-count) must win instead.
  assert_winner "$label reclaim-cap-excludes-p0" "$prog" \
    '[{"id":"poisoned-p0-at-cap","priority":0,"updated_at":"2026-01-01T00:00:00Z","labels":["pilot:reclaim-count:3"]},{"id":"clean-p1","priority":1,"updated_at":"2026-09-10T22:00:00Z","labels":[]}]' \
    "clean-p1"

  # 6. (ga-0pg2o) reclaim-count BELOW the cap must NOT be excluded — proves
  # the threshold is exactly ">=3", not "any reclaim-count label at all".
  assert_winner "$label reclaim-count-below-cap-still-wins" "$prog" \
    '[{"id":"reclaimed-p0-below-cap","priority":0,"updated_at":"2026-01-01T00:00:00Z","labels":["pilot:reclaim-count:2"]},{"id":"clean-p1","priority":1,"updated_at":"2026-09-10T22:00:00Z","labels":[]}]' \
    "reclaimed-p0-below-cap"

  # 7-9. (ga-0pg2o gate-fix round 2) Step 1b3's fallback post-filter must
  # apply the SAME reclaim-cap exclusion as Step 1b2 — GATE-FEEDBACK on
  # round 1 named the reopened gap: a capped bead that is the sole occupant
  # of its priority tier makes Step 1b2 correctly return [], and the
  # Go-rendered fallback (zero reclaim-count awareness on its own) used to
  # hand that SAME bead back unfiltered.
  local fallback_prog
  if ! fallback_prog="$(extract_fallback_postfilter_jq "$tpl")"; then
    bad "$label: could not extract Step 1b3 post-filter jq program from $tpl (line shape changed?)"
  else
    # 7. simulates the Go-rendered query handing back its one real result
    # (routedReadyTierCommand's own contract: 0 or 1 items) when that result
    # is at the cap — the post-filter must drop it to [].
    assert_fallback_result "$label fallback-drops-capped-bead" "$fallback_prog" \
      '[{"id":"poisoned-p0-at-cap","labels":["pilot:reclaim-count:3"]}]' \
      '[]'

    # 8. below-cap passthrough — same ">=3" threshold as Step 1b2's own case
    # 6; the post-filter must not eat a legitimate fallback result.
    assert_fallback_result "$label fallback-keeps-clean-bead" "$fallback_prog" \
      '[{"id":"clean-fallback-bead","labels":["pilot:reclaim-count:2"]}]' \
      '[{"id":"clean-fallback-bead","labels":["pilot:reclaim-count:2"]}]'

    # 9. a genuinely empty fallback result ([]) must stay [] without erroring.
    assert_fallback_result "$label fallback-empty-stays-empty" "$fallback_prog" \
      '[]' \
      '[]'
  fi

  # (ga-0pg2o, reported test b) structural: the priority probe must precede
  # the Go-rendered fallback in file order — see assert_probe_before_fallback
  # for why this is what "an ephemeral-origin session chooses by priority"
  # actually reduces to at the pack-level (non-Go-rendered) file.
  assert_probe_before_fallback "$label" "$tpl"
}

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

run_case "wa-worker Step 1b2" "$CITY_ROOT/agents/wa-worker/prompt.template.md"
run_case "ps-worker Step 1b2" "$CITY_ROOT/agents/ps-worker/prompt.template.md"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
