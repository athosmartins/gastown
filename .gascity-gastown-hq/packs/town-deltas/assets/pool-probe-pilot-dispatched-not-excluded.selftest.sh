#!/usr/bin/env bash
# pool-probe-pilot-dispatched-not-excluded.selftest.sh — regression PIN for ga-7o2c29.
#
# This file pins a DELIBERATE ASYMMETRY, the opposite of its siblings
# (pool-probe-delivery-pending-restart / -next-action-family / -text-veto-family
# each pin an exclusion the worker probe must HAVE). This one pins two labels
# the worker probe must NOT exclude: pilot:dispatched and pilot:dispatching.
#
# Why the temptation exists: pilot-dispatcher.sh's _filter_candidates (and so the
# Pilot's own top-up demand count) DOES exclude both labels, and ga-oc6knj's
# doctrine is "one definition of eligible, not two" — so an agent sweeping for
# drift between the worker probe and the dispatcher's list will see these two as
# a gap. ga-7o2c29 (filed 2026-09-24 by a worker whose probe re-offered a bead
# the Pilot had just dispatched) proposed exactly that: add both to Step 1b2.
#
# Why it must not be done: for pool targets the Pilot dispatches BY LEAVING THE
# BEAD UNASSIGNED, and the worker it spawns finds that bead through this very
# probe (`bd ready --metadata-field gc.routed_to=<pool> --unassigned`) and
# claims it. pilot-dispatcher.sh's ga-dbibq block (grep "ga-dbibq: POOL targets")
# records the incident: a worker that could not see its bead "spawned, found
# nothing, drained WITHOUT building". The ordering that makes the labels
# unavoidable for the intended worker: gc.routed_to is stamped, then
# pilot:dispatching is held THROUGH `gc session new` (which routinely takes >30s
# under load), then story:in-flight is added and confirmed durable, then
# pilot:dispatching is removed and pilot:dispatched added — and pilot:dispatched
# stays for the bead's whole life. So the freshly spawned worker's first probe
# always sees one of the two. The Pilot says so itself, right after stamping
# pilot:dispatched: for rig-native beads "gc.routed_to=wa-worker MUST survive
# here so the spawned worker's RoutedPoolQuery finds the unassigned bead"
# (pilot-dispatcher.sh, grep "ga-ms1jm: strip gc.routed_to"). Excluding the
# labels from the probe would not remove a rare race; it would starve every
# dispatched worker, city-wide.
#
# Why the reported near-miss is not a defect: two workers can see one unassigned
# bead only in the window before the first claim, and `bd update --claim` is the
# atomic arbiter (`bd update --help`: "Atomically claim the issue"; the bd binary
# carries the "issue already claimed" refusal) — that is what the templates'
# CLAIM-FIRST invariant is for. On ga-7o2c29's own subject bead (wa-u2mee) the
# outcome was one branch, one gate marker, one merge.
#
# What IS legitimately excluded, and where: the Pilot side (top-up demand goes
# through _filter_candidates). Do not "fix" the worker side to match it.
#
# Scope of this pin: BOTH templates, BOTH places the demand signal is read —
# Step 1b2 (hardcoded `bd ready` line + its jq tail) and Step 1b3 (the
# {{ .RoutedPoolQuery }} | jq -c post-filter) — at two levels, because the two
# levels fail differently: a textual check catches an --exclude-label flag (which
# runs inside `bd ready`, invisible to a jq fixture); a behavioural check catches
# a jq clause spelled in a way no substring match would find. Each behavioural
# case is paired with a control that MUST be dropped, so a jq program that
# degraded into a pass-through cannot turn this suite into a vacuous green.
#
# Exit 0 iff every scenario, for both files, behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

# Fixed clock for the Step 1b2 program's $now_ts (held-until comparison). No
# fixture below carries a held-until label, so the value only has to be a number.
NOW_TS=1790000000

# locate_step1b2_line <template> — same line-shape anchors as the sibling
# selftests (duplicated, not shared: this family's convention, so each guard
# fails loudly and independently if the line shape changes).
locate_step1b2_line() {
  grep -F 'bd ready --metadata-field "gc.routed_to=' "$1" | grep -F '| jq --argjson now_ts "$(date +%s)" ' | head -1
}

# extract_step1b2_jq <template> — the jq PROGRAM after `| jq --argjson now_ts
# "$(date +%s)" '` on that line, minus the closing quote.
extract_step1b2_jq() {
  local line marker after prog
  line="$(locate_step1b2_line "$1")"
  [ -n "$line" ] || return 1
  marker='| jq --argjson now_ts "$(date +%s)" '"'"
  after="${line#*$marker}"
  [ "$after" != "$line" ] || return 1
  prog="${after%\'}"
  { [ -n "$prog" ] && [ "$prog" != "$after" ]; } || return 1
  printf '%s' "$prog"
}

# extract_fallback_postfilter_jq <template> — the jq PROGRAM of the Step 1b3
# post-filter ({{ .RoutedPoolQuery }} | jq -c '...').
extract_fallback_postfilter_jq() {
  local line marker after prog
  line="$(grep -F '{{ .RoutedPoolQuery }} | jq -c ' "$1" | head -1)"
  [ -n "$line" ] || return 1
  marker='{{ .RoutedPoolQuery }} | jq -c '"'"
  after="${line#*$marker}"
  [ "$after" != "$line" ] || return 1
  prog="${after%\'}"
  { [ -n "$prog" ] && [ "$prog" != "$after" ]; } || return 1
  printf '%s' "$prog"
}

# ids_1b2 <prog> <fixture> / ids_1b3 <prog> <fixture> — run the program, print
# the compacted array of surviving ids ("ERR:..." if jq itself failed, so a
# broken program never reads as an empty result).
ids_1b2() {
  local out
  if out="$(printf '%s' "$2" | jq -c --argjson now_ts "$NOW_TS" "$1" 2>&1)"; then
    printf '%s' "$out" | jq -c '[.[].id]' 2>&1
  else
    printf 'ERR:%s' "$out"
  fi
}
ids_1b3() {
  local out
  if out="$(printf '%s' "$2" | jq -c "$1" 2>&1)"; then
    printf '%s' "$out" | jq -c '[.[].id]' 2>&1
  else
    printf 'ERR:%s' "$out"
  fi
}

# assert_ids <label> <actual> <expected-json-array>
assert_ids() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    ok "$label -> $expected"
  else
    bad "$label: expected $expected, got $actual"
  fi
}

# A bead exactly as the Pilot leaves it while its dedicated worker is on the way
# (routed, UNASSIGNED, in-flight): the shape the intended worker MUST still find.
dispatched_bead() {  # <id> <extra-label-json-fragment, may be empty, leading comma>
  printf '[{"id":"%s","priority":1,"created_at":"2026-09-24T21:17:02Z","updated_at":"2026-09-24T21:24:18Z","labels":["exec:auto","lane:small","story:in-flight","pilot:dispatched"%s]}]' "$1" "$2"
}
dispatching_bead() {  # mid-spawn: the claim label is still held
  printf '[{"id":"%s","priority":1,"created_at":"2026-09-24T21:17:02Z","updated_at":"2026-09-24T21:23:40Z","labels":["exec:auto","lane:small","pilot:dispatching"%s]}]' "$1" "$2"
}

run_case() {
  local label="$1" tpl="$2"
  if [ ! -f "$tpl" ]; then
    bad "$label: template not found at $tpl"
    return
  fi

  # ── textual level: the hardcoded Step 1b2 line ────────────────────────────
  local line
  line="$(locate_step1b2_line "$tpl")"
  if [ -z "$line" ]; then
    bad "$label: could not locate the hardcoded Step 1b2 probe line in $tpl (line shape changed?)"
    return
  fi
  case "$line" in
    *pilot:dispatched*|*pilot:dispatching*)
      bad "$label: Step 1b2 probe line mentions pilot:dispatched/pilot:dispatching — that starves the worker the Pilot just spawned (ga-7o2c29; pilot-dispatcher.sh ga-dbibq)"
      ;;
    *)
      ok "$label: Step 1b2 probe line does not mention pilot:dispatched/pilot:dispatching"
      ;;
  esac

  # ── behavioural level: Step 1b2 jq tail ───────────────────────────────────
  local prog12
  if ! prog12="$(extract_step1b2_jq "$tpl")"; then
    bad "$label: could not extract the Step 1b2 jq program from $tpl (line shape changed?)"
    return
  fi
  assert_ids "$label 1b2 keeps a pilot:dispatched bead (the intended worker must find it)" \
    "$(ids_1b2 "$prog12" "$(dispatched_bead disp-1 '')")" '["disp-1"]'
  assert_ids "$label 1b2 keeps a pilot:dispatching bead (spawn still in progress)" \
    "$(ids_1b2 "$prog12" "$(dispatching_bead spawn-1 '')")" '["spawn-1"]'
  # controls: the same shape, made ineligible for an unrelated reason, MUST drop —
  # proves the program is a live filter and the two keeps above are not a pass-through.
  assert_ids "$label 1b2 control: dispatched + pilot:held is still dropped" \
    "$(ids_1b2 "$prog12" "$(dispatched_bead ctl-held ',"pilot:held"')")" '[]'
  assert_ids "$label 1b2 control: dispatched + reclaim cap (3) is still dropped" \
    "$(ids_1b2 "$prog12" "$(dispatched_bead ctl-cap ',"pilot:reclaim-count:3"')")" '[]'

  # ── behavioural level: Step 1b3 post-filter ───────────────────────────────
  local prog13
  if ! prog13="$(extract_fallback_postfilter_jq "$tpl")"; then
    bad "$label: could not extract the Step 1b3 post-filter jq program from $tpl (line shape changed?)"
    return
  fi
  assert_ids "$label 1b3 keeps a pilot:dispatched bead" \
    "$(ids_1b3 "$prog13" "$(dispatched_bead disp-1 '')")" '["disp-1"]'
  assert_ids "$label 1b3 keeps a pilot:dispatching bead" \
    "$(ids_1b3 "$prog13" "$(dispatching_bead spawn-1 '')")" '["spawn-1"]'
  assert_ids "$label 1b3 control: dispatched + reclaim cap (3) is still dropped" \
    "$(ids_1b3 "$prog13" "$(dispatched_bead ctl-cap ',"pilot:reclaim-count:3"')")" '[]'
  assert_ids "$label 1b3 control: dispatched + delivery:pending-restart is still dropped" \
    "$(ids_1b3 "$prog13" "$(dispatched_bead ctl-dpr ',"delivery:pending-restart"')")" '[]'
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
