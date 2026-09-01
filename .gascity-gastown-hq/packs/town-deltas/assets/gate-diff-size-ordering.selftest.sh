#!/usr/bin/env bash
# gate-diff-size-ordering.selftest.sh (ga-r8u92, ga-faw5o defeito 1)
#
# Proves the SIZE-AWARE SELECTION addition to the live marker-selection block
# (quality-gate-dispatcher.sh, SELFTEST-EXTRACT sentinel "marker-select"):
# within each not-yet-aged healthy tier, the smallest diff (`.diff_lines`,
# annotated by Step 0b-0 before this block runs) now wins first — shortest-job-
# first minimizes mean queue wait — WITHOUT losing any prior invariant:
#   • the is_aged/is_overdue anti-starvation tiers are completely untouched by
#     size: a large diff that ages still promotes exactly like today (ga-tgo7q/
#     ga-ddm76), regardless of how big it is
#   • rebase-fail markers stay at the back regardless of size (ga-q3ig2)
#   • a marker whose size could not be measured (no `.diff_lines`) is treated
#     as the WORST case (GATE_DIFF_SIZE_UNKNOWN_SENTINEL), never the best —
#     it cannot jump the queue by masquerading as tiny
#   • no `.diff_lines` anywhere (annotation skipped, e.g. GATE_DIFF_SIZE_
#     ORDERING_ENABLED=0) collapses to the exact prior newest-first tiebreak
#     (4cae0a2c49) — REVERSIBLE, same convention as GATE_PRIORITY_AUTHORS=""
#
# Strategy mirrors gate-priority-starvation-ceiling.selftest.sh: extract the
# LIVE block via its sentinels (never a hand-copied jq) and run it under the
# host bash with MARKERS_JSON + the NOW/AGE/HARD/PRIORITY/DIFF-SIZE test seams
# set. `.diff_lines` is set DIRECTLY on synthetic fixtures — Step 0b-0's own
# git-based measurement lives OUTSIDE this sentinel (same reason MARKERS_JSON
# itself is built outside and merely consumed here), so no live git/rig setup
# is needed to test the ordering logic this file is scoped to.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-diff-size-ordering.selftest (ga-r8u92) =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract_block() {
  sed -n '/# SELFTEST-EXTRACT marker-select: BEGIN/,/# SELFTEST-EXTRACT marker-select: END/p' "$1"
}

SELECT_BLOCK="$(extract_block "$DISPATCHER")"
if [ -z "$SELECT_BLOCK" ]; then
  echo "FATAL: could not extract marker-select block (sentinels missing?)" >&2
  exit 2
fi
ok "located live marker-select block via sentinel extraction"

# mk <id> <created_at_iso> [diff_lines] [author] [extra-labels-csv]
# diff_lines="" (default) omits the field entirely (unmeasured candidate) —
# mirrors what Step 0b-0 produces when GATE_DIFF_SIZE_ORDERING_ENABLED=0, or
# when a candidate's rig/branch could not be resolved and the outer loop
# never got as far as writing the sentinel into the map for it.
mk() {
  local id="$1" ts="$2" lines="${3:-}" author="${4:-}" labels="${5:-}"
  local labarr='["gate-status:queued"]'
  [ -n "$labels" ] && labarr="$(printf '%s' "$labels" | jq -R 'split(",")')"
  local desc="branch: crew/${author:-unknown}/${id}"
  if [ -n "$lines" ]; then
    jq -cn --arg id "$id" --arg ts "$ts" --arg desc "$desc" --argjson labels "$labarr" --argjson lines "$lines" \
      '{id:$id, created_at:$ts, description:$desc, labels:$labels, diff_lines:$lines}'
  else
    jq -cn --arg id "$id" --arg ts "$ts" --arg desc "$desc" --argjson labels "$labarr" \
      '{id:$id, created_at:$ts, description:$desc, labels:$labels}'
  fi
}

select_marker() {
  # args: $1=MARKERS_JSON $2=now_epoch $3=age_threshold $4=priority_authors $5=diff_unknown_sentinel
  local markers_json="$1" now_epoch="$2" age_threshold="${3:-1800}" prio="${4-}" unknown="${5:-}"
  MARKERS_JSON="$markers_json" \
  GATE_MARKER_NOW_OVERRIDE_EPOCH="$now_epoch" \
  GATE_MARKER_AGE_PROMOTE_SECONDS="$age_threshold" \
  GATE_PRIORITY_AUTHORS="$prio" \
  GATE_DIFF_SIZE_UNKNOWN_SENTINEL="$unknown" \
  bash -c "$SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null
}

NOW_EPOCH=1782863814
THRESH=1800   # 30min, matches GATE_MARKER_AGE_PROMOTE_SECONDS default
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
ago() { iso "$((NOW_EPOCH - $1))"; }

echo "── (1) SJF: small-old beats big-newer among non-priority not-aged healthy markers ──"
FIX=$(printf '[%s,%s]' \
  "$(mk small "$(ago 600)" 10)" \
  "$(mk big   "$(ago 60)"  3000)")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH" "" 999999999)
[ "$SEL" = "small" ] && ok "small (10 lines, 10m old) beats big (3000 lines, 1m old) — size now outranks the old pure-recency tiebreak" \
  || bad "expected small, got '$SEL' — SJF not applied in the non-priority fresh tier"

echo "── (2) SJF also holds within the PRIORITY not-aged tier (both authors prioritized) ──"
FIX=$(printf '[%s,%s]' \
  "$(mk psmall "$(ago 600)" 5    oracle)" \
  "$(mk pbig   "$(ago 60)"  2000 oracle)")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH" "oracle" 999999999)
[ "$SEL" = "psmall" ] && ok "within oracle's own queue, smaller (5 lines) beats bigger-newer (2000 lines) — size-awareness reaches the priority tier too" \
  || bad "expected psmall, got '$SEL' — priority fresh tier did not pick up diff_size"

echo "── (3) ANTI-STARVATION: a large diff that AGED still promotes ahead of a tiny fresh diff ──"
FIX=$(printf '[%s,%s]' \
  "$(mk huge_aged  "$(ago 2400)" 5000)" \
  "$(mk tiny_fresh "$(ago 60)"   1)")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH" "" 999999999)
[ "$SEL" = "huge_aged" ] && ok "aged huge diff (5000 lines, 2400s > ${THRESH}s) still wins over a fresh tiny diff — size NEVER overrides the aging safety net (ga-tgo7q untouched)" \
  || bad "expected huge_aged, got '$SEL' — CRITICAL: size-aware ordering broke the anti-starvation bound"

echo "── (4) hard-ceiling tier stays priority-AND-size-blind (ga-ddm76 untouched) ──"
FIX=$(printf '[%s,%s]' \
  "$(mk overdue_huge "$(ago 5500)" 9000 mila)" \
  "$(mk fresh_tiny_priority "$(ago 60)" 1 oracle)")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH" "oracle" 999999999)
[ "$SEL" = "overdue_huge" ] && ok "overdue non-priority marker (9000 lines, 5500s) still beats a fresh tiny priority marker — hard ceiling ignores both priority and size" \
  || bad "expected overdue_huge, got '$SEL' — hard-ceiling tier picked up size or lost its priority-blindness"

echo "── (5) UNKNOWN size (unmeasured) sinks behind ANY measured size, even if far newer ──"
FIX=$(printf '[%s,%s]' \
  "$(mk unmeasured_new  "$(ago 60)"  "")" \
  "$(mk measured_small  "$(ago 600)" 5)")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH" "" 999999999)
[ "$SEL" = "measured_small" ] && ok "unmeasured-but-newer candidate does NOT jump a measured-small older one — unknown maps to worst-case, not best-case" \
  || bad "expected measured_small, got '$SEL' — unknown-size candidates are wrongly treated as tiny (systematic bias toward just-pushed/unfetched branches)"

echo "── (6) REVERSIBILITY: no diff_lines anywhere collapses to the exact prior newest-first tiebreak ──"
FIX=$(printf '[%s,%s]' \
  "$(mk old   "$(ago 600)" "")" \
  "$(mk newer "$(ago 60)"  "")")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH" "" 999999999)
[ "$SEL" = "newer" ] && ok "with zero size data, newest-first (4cae0a2c49) returns unchanged — same REVERSIBLE convention as GATE_PRIORITY_AUTHORS=\"\"" \
  || bad "expected newer, got '$SEL' — feature-off/no-data path no longer matches pre-ga-r8u92 behavior"

echo "── (7) rebase-fail tier ignores size entirely (ga-q3ig2 guarantee, size as distractor) ──"
FIX=$(printf '[%s,%s]' \
  "$(mk broken_huge "$(ago 3600)" 9000 "" "gate-status:queued,gate:exiled-tier5:2")" \
  "$(mk healthy_tiny "$(ago 60)"  1)")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH" "" 999999999)
[ "$SEL" = "healthy_tiny" ] && ok "a 9000-line rebase-fail marker still sinks behind a 1-line healthy one — size cannot rescue a conflicted branch" \
  || bad "expected healthy_tiny, got '$SEL' — rebase-fail tier picked up size (ga-q3ig2 regression risk)"

echo "── (8) gate-feedback-style regression: malformed diff_lines must not crash the sweep ──"
FIX2=$(printf '[{"id":"bad","created_at":"%s","labels":["gate-status:queued"],"diff_lines":"not-a-number"},%s]' \
  "$(ago 60)" "$(mk good "$(ago 600)" 5)")
SEL=$(MARKERS_JSON="$FIX2" GATE_MARKER_NOW_OVERRIDE_EPOCH="$NOW_EPOCH" GATE_MARKER_AGE_PROMOTE_SECONDS="$THRESH" \
  GATE_PRIORITY_AUTHORS="" GATE_DIFF_SIZE_UNKNOWN_SENTINEL=999999999 \
  bash -c "set -euo pipefail; $SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null)
STATUS=$?
if [ "$STATUS" = "0" ] && [ -n "$SEL" ]; then
  ok "diff_lines=\"not-a-number\" does not crash the sweep under set -euo pipefail (exit=$STATUS, selected=$SEL)"
else
  bad "diff_lines=\"not-a-number\" broke selection (exit=$STATUS, selected='$SEL')"
fi

echo "── (9) boundary: equal diff sizes fall back to the newest-first secondary key ──"
FIX=$(printf '[%s,%s]' \
  "$(mk tie_old "$(ago 600)" 42)" \
  "$(mk tie_new "$(ago 60)"  42)")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH" "" 999999999)
[ "$SEL" = "tie_new" ] && ok "equal-size candidates (42 vs 42 lines) resolve via the newest-first secondary key, not array order" \
  || bad "expected tie_new, got '$SEL' — the compound sort_by([diff_size, -created_epoch]) is not using the secondary key correctly"

echo "── (10) mean-wait-time evidence: synthetic backlog (live queue was near-empty, 1-2 markers, at implementation time — ga-r8u92 AC) ──"
# 10 candidates, all fresh (well under THRESH so aging never interferes — this
# isolates the SJF-vs-recency effect cleanly), 8 "small" PRs + 2 "large" ones
# mixed in among them chronologically — models the bead's own framing ("a
# 3,000-line diff and a 20-line diff occupy the same concurrency slot").
# Drain the same fixed set repeatedly (selecting, then removing the winner)
# under OLD ordering (no diff_lines -> pure newest-first) and NEW ordering
# (diff_lines populated), recording each small marker's 1-indexed drain
# position as a proxy for its queue wait (equal per-marker service time
# assumed, so mean position is monotonic in mean wait).
declare -a IDS=(s1 s2 L1 s3 s4 s5 L2 s6 s7 s8)
declare -a AGO_SECS=(540 480 420 360 300 240 180 120 60 30)
declare -a SIZES=(15 20 3000 12 18 25 2500 10 22 14)

build_json_old() { # no diff_lines at all
  local out="[" i
  for i in "${!IDS[@]}"; do
    [ "$i" -gt 0 ] && out="$out,"
    out="$out$(mk "${IDS[$i]}" "$(ago "${AGO_SECS[$i]}")" "")"
  done
  echo "$out]"
}
build_json_new() { # with diff_lines
  local out="[" i
  for i in "${!IDS[@]}"; do
    [ "$i" -gt 0 ] && out="$out,"
    out="$out$(mk "${IDS[$i]}" "$(ago "${AGO_SECS[$i]}")" "${SIZES[$i]}")"
  done
  echo "$out]"
}

mean_small_position_old() {
  local pool remaining_ids pos=0 sel total=0 count=0
  remaining_ids=("${IDS[@]}")
  local -A ago_of size_of
  for i in "${!IDS[@]}"; do ago_of["${IDS[$i]}"]="${AGO_SECS[$i]}"; done
  while [ "${#remaining_ids[@]}" -gt 0 ]; do
    pos=$((pos+1))
    local json="[" first=1 id
    for id in "${remaining_ids[@]}"; do
      [ "$first" -eq 0 ] && json="$json,"
      first=0
      json="$json$(mk "$id" "$(ago "${ago_of[$id]}")" "")"
    done
    json="$json]"
    sel=$(select_marker "$json" "$NOW_EPOCH" "$THRESH" "" 999999999)
    [ -z "$sel" ] && break
    case "$sel" in L1|L2) : ;; *) total=$((total+pos)); count=$((count+1));; esac
    local newremaining=()
    for id in "${remaining_ids[@]}"; do [ "$id" != "$sel" ] && newremaining+=("$id"); done
    remaining_ids=("${newremaining[@]}")
  done
  [ "$count" -gt 0 ] && echo "$((total * 100 / count))" || echo "0"   # x100 fixed-point avg
}

mean_small_position_new() {
  local pos=0 sel total=0 count=0
  local remaining_ids=("${IDS[@]}")
  local -A ago_of size_of
  for i in "${!IDS[@]}"; do ago_of["${IDS[$i]}"]="${AGO_SECS[$i]}"; size_of["${IDS[$i]}"]="${SIZES[$i]}"; done
  while [ "${#remaining_ids[@]}" -gt 0 ]; do
    pos=$((pos+1))
    local json="[" first=1 id
    for id in "${remaining_ids[@]}"; do
      [ "$first" -eq 0 ] && json="$json,"
      first=0
      json="$json$(mk "$id" "$(ago "${ago_of[$id]}")" "${size_of[$id]}")"
    done
    json="$json]"
    sel=$(select_marker "$json" "$NOW_EPOCH" "$THRESH" "" 999999999)
    [ -z "$sel" ] && break
    case "$sel" in L1|L2) : ;; *) total=$((total+pos)); count=$((count+1));; esac
    local newremaining=()
    for id in "${remaining_ids[@]}"; do [ "$id" != "$sel" ] && newremaining+=("$id"); done
    remaining_ids=("${newremaining[@]}")
  done
  [ "$count" -gt 0 ] && echo "$((total * 100 / count))" || echo "0"
}

OLD_MEAN_X100=$(mean_small_position_old)
NEW_MEAN_X100=$(mean_small_position_new)
echo "    mean drain-position of the 8 small markers — OLD (pure newest-first): $((OLD_MEAN_X100/100)).$((OLD_MEAN_X100%100)) / NEW (size-aware): $((NEW_MEAN_X100/100)).$((NEW_MEAN_X100%100))"
if [ "$NEW_MEAN_X100" -lt "$OLD_MEAN_X100" ] && [ "$OLD_MEAN_X100" -gt 0 ] && [ "$NEW_MEAN_X100" -gt 0 ]; then
  ok "size-aware ordering measurably reduces mean queue wait for the small-diff majority vs. pure newest-first (synthetic backlog — live queue was near-empty at implementation time, 2026-09-01)"
else
  bad "size-aware ordering did NOT reduce mean small-marker wait (old=$OLD_MEAN_X100 new=$NEW_MEAN_X100) — SJF benefit not demonstrated"
fi

echo "── (11) drift-guards: shipped dispatcher matches tested logic ──"
grep -q 'def diff_size' "$DISPATCHER" \
  && ok "diff_size predicate present" || bad "diff_size predicate missing"
grep -q 'def created_epoch' "$DISPATCHER" \
  && ok "created_epoch predicate present" || bad "created_epoch predicate missing"
grep -q 'GATE_DIFF_SIZE_UNKNOWN_SENTINEL' "$DISPATCHER" \
  && ok "unknown-size sentinel is a configurable GATE_* tunable (matches house convention)" || bad "unknown-size sentinel not configurable"
grep -q 'gate_measure_diff_lines' "$DISPATCHER" \
  && ok "shared diff-line-count helper present (Step 0b-0 / ga-ltr3c reuse the same measurement)" || bad "gate_measure_diff_lines helper missing"
SIZE_SORT_COUNT=$(grep -c 'sort_by(\[diff_size, -created_epoch\])' "$DISPATCHER" || true)
[ "$SIZE_SORT_COUNT" = "2" ] && ok "exactly 2 tiers (priority-fresh, other-fresh) use the size-aware sort — aged/overdue/rebase-fail tiers untouched" \
  || bad "expected exactly 2 occurrences of the size-aware sort, found $SIZE_SORT_COUNT — tier scope drifted"
OVERDUE_LINE=$(grep -n 'map(select(is_overdue' "$DISPATCHER" | head -1 | cut -d: -f1)
PRIO_AGED_LINE=$(grep -n 'is_aged))' "$DISPATCHER" | grep -v 'is_aged | not' | head -1 | cut -d: -f1)
BROKEN_LINE=$(grep -n 'map(select(has_rebase_fail))' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$OVERDUE_LINE" ] && [ -n "$PRIO_AGED_LINE" ] && [ -n "$BROKEN_LINE" ] \
   && [ "$OVERDUE_LINE" -lt "$PRIO_AGED_LINE" ] && [ "$PRIO_AGED_LINE" -lt "$BROKEN_LINE" ]; then
  ok "tier order unchanged: overdue-ceiling, then priority-aged/other tiers, then rebase-fail"
else
  bad "tier order drifted (overdue=$OVERDUE_LINE prio-aged=$PRIO_AGED_LINE broken=$BROKEN_LINE) — re-check concat order"
fi

echo "── (12)-(16) Step 0b-0 own annotate/merge logic (gate-feedback gate_run=ga-k5r6r) ──"
# The tests above (1)-(11) only exercise the SELFTEST-EXTRACT "marker-select"
# block, which consumes .diff_lines already set directly on synthetic
# fixtures — by design it never touches Step 0b-0's own annotation/merge
# logic (the jq calls that BUILD .diff_lines from a measured size). That gap
# is exactly what let the gate_run=ga-k5r6r defect ship with zero coverage:
# `VAR=$(jq ...) || VAR="$VAR"` looks like a recovery but re-assigns the
# already-corrupted (empty) value onto itself, so one malformed record could
# silently wipe every marker's annotation, or MARKERS_JSON entirely. The fix
# extracted the two vulnerable steps into gate_diff_size_map_accumulate /
# gate_diff_size_map_merge (own "diff-size-merge" sentinel, right before
# Step 0b-0) so they're testable the same sentinel-extraction way, without
# needing the surrounding loop's real git/rig calls.
extract_merge_block() {
  sed -n '/# SELFTEST-EXTRACT diff-size-merge: BEGIN/,/# SELFTEST-EXTRACT diff-size-merge: END/p' "$1"
}
MERGE_BLOCK="$(extract_merge_block "$DISPATCHER")"
if [ -z "$MERGE_BLOCK" ]; then
  bad "could not extract diff-size-merge helper block (sentinels missing?)"
else
  ok "located live diff-size-merge helper block via sentinel extraction"
fi

# Loads gate_diff_size_map_accumulate/_merge as real functions in THIS shell
# (not a fresh bash -c per call, unlike select_marker() above) so multiple
# calls below can chain naturally, mirroring how Step 0b-0's loop calls them
# repeatedly against the same accumulator. `log` is stubbed to stdout (the
# real one — line ~3747 — also just echoes) since every real call site
# redirects it `>&2`; the stub lets test (13) observe that a failure IS
# logged, not just that the return value survived.
log() { printf '%s\n' "$*"; }
eval "$MERGE_BLOCK"

echo "── (12) baseline: normal accumulate+merge round trip is unaffected by the refactor ──"
MAP1=$(gate_diff_size_map_accumulate "{}" "m1" "10")
[ "$MAP1" = '{"m1":10}' ] && ok "accumulate: first entry recorded correctly ($MAP1)" \
  || bad "accumulate: expected {\"m1\":10}, got '$MAP1'"
MAP2=$(gate_diff_size_map_accumulate "$MAP1" "m2" "20")
[ "$MAP2" = '{"m1":10,"m2":20}' ] && ok "accumulate: second entry appended without disturbing the first ($MAP2)" \
  || bad "accumulate: expected {\"m1\":10,\"m2\":20}, got '$MAP2'"
MARKERS2=$(printf '[{"id":"m1","created_at":"2026-01-01T00:00:00Z"},{"id":"m2","created_at":"2026-01-01T00:00:00Z"}]')
MERGED2=$(gate_diff_size_map_merge "$MARKERS2" "$MAP2")
M1_LINES=$(printf '%s' "$MERGED2" | jq -r '.[] | select(.id=="m1") | .diff_lines')
M2_LINES=$(printf '%s' "$MERGED2" | jq -r '.[] | select(.id=="m2") | .diff_lines')
[ "$M1_LINES" = "10" ] && [ "$M2_LINES" = "20" ] && ok "merge: both markers correctly annotated in the no-failure path" \
  || bad "merge: expected m1=10 m2=20, got m1='$M1_LINES' m2='$M2_LINES'"

echo "── (13) gate-feedback repro 1: a failed per-marker accumulate leaves PRIOR entries intact ──"
# _ds_size="not-a-number" is exactly what a misbehaving gate_measure_diff_lines
# (or any other unexpected non-numeric _ds_size) would produce — it makes
# --argjson sz fail. Pre-fix, the buggy idiom silently reset the ENTIRE map
# (m1's already-recorded entry included) to empty on this single failure.
BEFORE_FAIL='{"m1":10}'
AFTER_FAIL=$(gate_diff_size_map_accumulate "$BEFORE_FAIL" "m2" "not-a-number" 2>/dev/null)
[ "$AFTER_FAIL" = "$BEFORE_FAIL" ] && ok "accumulate: malformed size for m2 leaves m1's prior entry intact, map='$AFTER_FAIL' (pre-fix this collapsed to empty)" \
  || bad "accumulate: expected unchanged '$BEFORE_FAIL', got '$AFTER_FAIL' — a bad marker corrupted sibling entries"
LOGGED=$(gate_diff_size_map_accumulate "$BEFORE_FAIL" "m2" "not-a-number" 2>&1 1>/dev/null)
[ -n "$LOGGED" ] && ok "accumulate: the failure is logged, not silent ('$LOGGED')" \
  || bad "accumulate: expected a log line on failure, got none"

echo "── (14) gate-feedback repro 2: a corrupted diff-size map does not wipe MARKERS_JSON ──"
# Mirrors the pre-fix final-merge hard-fail: --argjson sizes "" (or any
# invalid-JSON map) used to empty MARKERS_JSON for the WHOLE sweep via
# `|| true`, which swallows the exit code but cannot undo the assignment
# that already ran.
MARKERS_BEFORE=$(printf '[{"id":"m1","created_at":"2026-01-01T00:00:00Z"}]')
MERGED_BAD=$(gate_diff_size_map_merge "$MARKERS_BEFORE" "not-valid-json" 2>/dev/null)
[ "$MERGED_BAD" = "$MARKERS_BEFORE" ] && ok "merge: invalid diff-size map leaves MARKERS_JSON unchanged (pre-fix this collapsed to empty for the whole sweep)" \
  || bad "merge: expected unchanged '$MARKERS_BEFORE', got '$MERGED_BAD'"

echo "── (15) gate-feedback repro 3: numeric .id (malformed record) no longer errors the whole batch ──"
# The reviewer's own repro: one marker's .id as a JSON number breaks
# $sizes[.id] (jq cannot index an object with a number) unless normalized via
# tostring. A healthy sibling marker in the SAME batch must still annotate.
MARKERS_MIXED=$(printf '[{"id":123,"created_at":"2026-01-01T00:00:00Z"},{"id":"healthy","created_at":"2026-01-01T00:00:00Z"}]')
SIZES_MIXED=$(gate_diff_size_map_accumulate "{}" "healthy" "7")
MERGED_MIXED=$(gate_diff_size_map_merge "$MARKERS_MIXED" "$SIZES_MIXED" 2>/dev/null)
HEALTHY_LINES=$(printf '%s' "$MERGED_MIXED" | jq -r '.[] | select(.id=="healthy") | .diff_lines' 2>/dev/null)
[ -n "$MERGED_MIXED" ] && [ "$HEALTHY_LINES" = "7" ] && ok "merge: numeric .id sibling does not error the whole batch — healthy marker still annotated (diff_lines=7)" \
  || bad "merge: numeric .id in the batch broke annotation for the healthy sibling (merged='$MERGED_MIXED', healthy_lines='$HEALTHY_LINES')"

echo "── (16) drift-guards: old self-clobbering idiom gone, new helpers wired in ──"
command grep -qE '_DIFF_SIZE_MAP="\$_DIFF_SIZE_MAP"' "$DISPATCHER" \
  && bad "old self-clobbering idiom (_DIFF_SIZE_MAP=\$(...) || _DIFF_SIZE_MAP=\"\$_DIFF_SIZE_MAP\") still present" \
  || ok "old self-clobbering accumulate idiom removed"
grep -q 'gate_diff_size_map_accumulate' "$DISPATCHER" \
  && ok "gate_diff_size_map_accumulate helper present" || bad "gate_diff_size_map_accumulate helper missing"
grep -q 'gate_diff_size_map_merge' "$DISPATCHER" \
  && ok "gate_diff_size_map_merge helper present" || bad "gate_diff_size_map_merge helper missing"
grep -q '.id | tostring' "$DISPATCHER" \
  && ok "final merge normalizes .id via tostring before indexing \$sizes" || bad "tostring normalization missing from final merge"

echo ""
echo "== gate-diff-size-ordering: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
