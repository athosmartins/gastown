#!/usr/bin/env bash
# gate-0ye7ar-exile-recovery.selftest.sh (ga-0ye7ar, wa-ycyf8, 2026-09-17)
#
# Proves the two invariants of the wa-ycyf8 fix in quality-gate-dispatcher.sh:
#
#   (a) gate_exile_recovery_sweep() — a has_rebase_fail marker whose branch NOW
#       merges cleanly (a real merge-tree recheck) has its exile labels cleared
#       immediately, instead of waiting on the 24h gate_exile_watchdog_sweep
#       escalation or a human. Section A below.
#
#   (b) the "marker-select" tier-selection block — a has_rebase_fail marker
#       whose OWN exile clock (gate:exiled-since) has run past
#       GATE_EXILE_OVERDUE_SECONDS gets one shot in the priority-blind
#       overdue-emergency tier, even if its created_at is young — closing the
#       gap where a queue that never empties down to tier 7 can starve an
#       exiled marker forever (the wa-ycyf8 incident: 7h, queue 6-24 deep the
#       entire time). Section B below.
#
# Strategy: Section A mirrors gate-exile-watchdog.selftest.sh — extract
# gate_exile_recovery_sweep() via its own SELFTEST-EXTRACT sentinel, eval it
# into this shell, stub every function it calls. Section B mirrors
# gate-priority-starvation-ceiling.selftest.sh — extract the "marker-select"
# sentinel and run it under a fresh bash with MARKERS_JSON + test-seam env
# vars set. Neither section hand-copies live logic.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-0ye7ar-exile-recovery.selftest (ga-0ye7ar, wa-ycyf8) =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

echo ""
echo "── SECTION A: gate_exile_recovery_sweep() — invariant (a), clean-merge auto-recovery ──"

RECOVERY_BLOCK="$(extract_block "$DISPATCHER" "gate-exile-recovery")"
if [ -z "$RECOVERY_BLOCK" ]; then
  echo "FATAL: SELFTEST-EXTRACT gate-exile-recovery block not found in $DISPATCHER" >&2
  exit 2
fi
eval "$RECOVERY_BLOCK"
if ! declare -F gate_exile_recovery_sweep >/dev/null 2>&1; then
  echo "FATAL: extracted block did not define gate_exile_recovery_sweep" >&2
  exit 2
fi
ok "located and defined gate_exile_recovery_sweep via sentinel extraction"

# ── stubs: every function/global gate_exile_recovery_sweep depends on ───────
GC_CITY="test-city"
LABEL_REMOVE_LOG=""    # accumulates every `bd label remove <id> <label>` call
COMMENT_LOG=""         # accumulates every `bd comment <id> <text>` call's id
WARN_LOG=""
RESOLVE_CALLS=""       # accumulates every gate_resolve_rig_context call's $RIG
MERGE_CHECK_CALLS=""   # accumulates every rig_merge_has_conflict call's args
STUB_RESOLVE_RC=0      # exit code gate_resolve_rig_context returns
STUB_RESOLVE_COMMIT="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"  # rig_resolve_commit output; "" simulates unfetched ref
STUB_MERGE_VERDICT="0" # rig_merge_has_conflict default output when the branch name carries no explicit hint
STUB_ATTEMPT="2"       # read_rebase_attempt output
STUB_SHOW_STILL_EXILED="false"  # post-removal readback: does the marker STILL carry an exile label?

# Mirrors the real extract() one-liner (quality-gate-dispatcher.sh ~line
# 7739) exactly — trivial enough that duplicating it here does not risk the
# drift a bigger stub would.
extract() { echo "$DESC" | grep -E "^$1:" | head -1 | sed "s/^$1: *//" || true; }

gate_resolve_rig_context() {
  RESOLVE_CALLS="$RESOLVE_CALLS|$RIG"
  [ "$STUB_RESOLVE_RC" = "0" ] || return 1
  RIG_PATH="/fake/rig"; DEFAULT_BRANCH="main"; GIT_DIR_PATH="/fake/rig"
  IS_CONTAINER_RIG=0; BEAD_CITY="/fake/rig"
  return 0
}
rig_resolve_commit() { printf '%s' "$STUB_RESOLVE_COMMIT"; }
rig_merge_has_conflict() {
  MERGE_CHECK_CALLS="$MERGE_CHECK_CALLS|$1,$2"
  case "$2" in
    */cleanbranch-*)  printf '0' ;;
    */brokenbranch-*) printf '1' ;;
    *) printf '%s' "$STUB_MERGE_VERDICT" ;;
  esac
}
read_rebase_attempt() { printf '%s' "$STUB_ATTEMPT"; }
bd() {
  # bd -C "$GC_CITY" label remove "$id" "$label" -q
  # bd -C "$GC_CITY" comment "$id" "text"
  # bd -C "$GC_CITY" show "$id" --json
  if [ "$3" = "label" ] && [ "$4" = "remove" ]; then
    LABEL_REMOVE_LOG="$LABEL_REMOVE_LOG|$5:$6"
    return 0
  fi
  if [ "$3" = "comment" ]; then
    COMMENT_LOG="$COMMENT_LOG|$4"
    return 0
  fi
  if [ "$3" = "show" ]; then
    if [ "$STUB_SHOW_STILL_EXILED" = "true" ]; then
      printf '[{"id":"%s","labels":["gate-status:queued","gate:exiled-tier5:9"]}]' "$4"
    else
      printf '[{"id":"%s","labels":["gate-status:queued"]}]' "$4"
    fi
    return 0
  fi
  return 0
}
warn() { WARN_LOG="$WARN_LOG|$*"; }

reset_stubs() {
  LABEL_REMOVE_LOG=""; COMMENT_LOG=""; WARN_LOG=""; RESOLVE_CALLS=""; MERGE_CHECK_CALLS=""
  STUB_RESOLVE_RC=0; STUB_RESOLVE_COMMIT="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  STUB_MERGE_VERDICT="0"; STUB_ATTEMPT="2"; STUB_SHOW_STILL_EXILED="false"; GATE_EXILE_RECOVERY_ENABLED=1
}

# mk <id> <branch> <labels-csv>
mk() {
  local id="$1" branch="$2" labels="${3:-gate-status:queued}"
  local labarr; labarr="$(printf '%s' "$labels" | jq -R 'split(",")')"
  local desc="branch: ${branch}"$'\n'"rig: testrig"$'\n'"bead_id: wa-${id}"
  jq -cn --arg id "$id" --arg desc "$desc" --argjson labels "$labarr" \
    '{id:$id, description:$desc, labels:$labels}'
}

echo "── (A1) healthy marker (no rebase-fail label): zero work done ──"
reset_stubs
MARKERS=$(printf '[%s]' "$(mk h1 "crew/mila/h1" "gate-status:queued")")
gate_exile_recovery_sweep "$MARKERS"
if [ -z "$LABEL_REMOVE_LOG" ] && [ -z "$COMMENT_LOG" ] && [ -z "$RESOLVE_CALLS" ] && [ -z "$GATE_EXILE_RECOVERY_CLEARED_IDS" ]; then
  ok "healthy marker never even resolves rig context — no false-positive work on a non-exiled marker"
else
  bad "expected zero work, got labels='$LABEL_REMOVE_LOG' resolves='$RESOLVE_CALLS' cleared='$GATE_EXILE_RECOVERY_CLEARED_IDS'"
fi

echo "── (A2) exiled marker, merge-tree STILL conflicts: left exiled, no clear ──"
reset_stubs
STUB_MERGE_VERDICT="1"
MARKERS=$(printf '[%s]' "$(mk m2 "crew/oracle/m2" "gate-status:queued,gate:exiled-tier5:2")")
gate_exile_recovery_sweep "$MARKERS"
if [ -z "$LABEL_REMOVE_LOG" ] && [ -z "$COMMENT_LOG" ] && [ -z "$GATE_EXILE_RECOVERY_CLEARED_IDS" ]; then
  ok "still-conflicting exiled marker (merge-tree=1) is left exiled — no clear, no comment, no false recovery"
else
  bad "expected no clear, got labels='$LABEL_REMOVE_LOG' cleared='$GATE_EXILE_RECOVERY_CLEARED_IDS'"
fi

echo "── (A3) THE FIX: exiled marker, merge-tree now CLEAN: fully cleared ──"
reset_stubs
STUB_MERGE_VERDICT="0"; STUB_ATTEMPT="2"
SINCE_EPOCH=1700000000
MARKERS=$(printf '[%s]' "$(mk m3 "crew/oracle/m3" "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$SINCE_EPOCH")")
gate_exile_recovery_sweep "$MARKERS"
EXPECT="|m3:gate:exiled-tier5:2|m3:gate:rebase-attempt:2|m3:gate:rebase-fail-count:2|m3:gate:exiled-since:$SINCE_EPOCH|m3:gate:exile-escalated"
if [ "$LABEL_REMOVE_LOG" = "$EXPECT" ] && [ "$COMMENT_LOG" = "|m3" ] && [ "$GATE_EXILE_RECOVERY_CLEARED_IDS" = "$(printf '\nm3')" ]; then
  ok "clean-merge-tree exiled marker fully cleared: exiled-tier5/rebase-attempt/rebase-fail-count/exiled-since/exile-escalated all removed at attempt=2, comment posted, id reported cleared"
else
  bad "expected full clear, got labels='$LABEL_REMOVE_LOG' comment='$COMMENT_LOG' cleared='$GATE_EXILE_RECOVERY_CLEARED_IDS'"
fi

echo "── (A3b) self-audit catch: label removals ran but a re-read STILL shows the marker exiled -> no false 'cleared' comment, not excluded from the watchdog ──"
reset_stubs
STUB_MERGE_VERDICT="0"; STUB_ATTEMPT="2"; STUB_SHOW_STILL_EXILED="true"
MARKERS=$(printf '[%s]' "$(mk m3b "crew/oracle/m3b" "gate-status:queued,gate:exiled-tier5:2")")
gate_exile_recovery_sweep "$MARKERS"
if [ -n "$LABEL_REMOVE_LOG" ] && [ -z "$COMMENT_LOG" ] && [ -z "$GATE_EXILE_RECOVERY_CLEARED_IDS" ] \
   && echo "$WARN_LOG" | grep -i "still shows it exiled" >/dev/null; then
  ok "the label removes were attempted, but the post-removal re-read still shows an exile label — no bead comment was posted claiming a clear that a silent write failure may have prevented, and the marker was NOT excluded from the watchdog's input (verified before claimed, ga-faw5o rounds 2-3 pattern applied here too)"
else
  bad "expected removals attempted but no false 'cleared' claim, got labels='$LABEL_REMOVE_LOG' comment='$COMMENT_LOG' cleared='$GATE_EXILE_RECOVERY_CLEARED_IDS' warn='$WARN_LOG'"
fi

echo "── (A4) rig context cannot be resolved: skips gracefully, no crash, no clear ──"
reset_stubs
STUB_RESOLVE_RC=1
MARKERS=$(printf '[%s]' "$(mk m4 "crew/oracle/m4" "gate-status:queued,gate:exiled-tier5:1")")
gate_exile_recovery_sweep "$MARKERS"
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$LABEL_REMOVE_LOG" ] && [ -z "$GATE_EXILE_RECOVERY_CLEARED_IDS" ] && echo "$WARN_LOG" | grep -i "cannot resolve rig context" >/dev/null; then
  ok "unresolvable rig context is skipped (warned, not crashed) — sweep continues past it (rc=$RC)"
else
  bad "expected a graceful skip, got rc=$RC labels='$LABEL_REMOVE_LOG' warn='$WARN_LOG'"
fi

echo "── (A5) branch ref not yet fetched (rig_resolve_commit empty): skips gracefully ──"
reset_stubs
STUB_RESOLVE_COMMIT=""
MARKERS=$(printf '[%s]' "$(mk m5 "crew/oracle/m5" "gate-status:queued,gate:exiled-tier5:1")")
gate_exile_recovery_sweep "$MARKERS"
if [ -z "$LABEL_REMOVE_LOG" ] && [ -z "$GATE_EXILE_RECOVERY_CLEARED_IDS" ] && echo "$WARN_LOG" | grep -i "does not resolve" >/dev/null; then
  ok "unresolvable branch ref (not yet fetched) is skipped, not treated as a false conflict or a crash"
else
  bad "expected a graceful skip, got labels='$LABEL_REMOVE_LOG' warn='$WARN_LOG'"
fi

echo "── (A6) GATE_EXILE_RECOVERY_ENABLED=0 disables the sweep entirely ──"
reset_stubs
STUB_MERGE_VERDICT="0"
GATE_EXILE_RECOVERY_ENABLED=0
MARKERS=$(printf '[%s]' "$(mk m6 "crew/oracle/m6" "gate-status:queued,gate:exiled-tier5:2")")
gate_exile_recovery_sweep "$MARKERS"
if [ -z "$LABEL_REMOVE_LOG" ] && [ -z "$RESOLVE_CALLS" ] && [ -z "$GATE_EXILE_RECOVERY_CLEARED_IDS" ]; then
  ok "GATE_EXILE_RECOVERY_ENABLED=0 fully disables the sweep — not even rig context is resolved for an obviously-clean exile"
else
  bad "expected the feature flag to short-circuit everything, got labels='$LABEL_REMOVE_LOG' resolves='$RESOLVE_CALLS'"
fi
GATE_EXILE_RECOVERY_ENABLED=1

echo "── (A7) legacy label name (gate:rebase-attempt:N, pre-ga-gpcx rename) is still recognized ──"
reset_stubs
STUB_MERGE_VERDICT="0"; STUB_ATTEMPT="3"
MARKERS=$(printf '[%s]' "$(mk m7 "crew/oracle/m7" "gate-status:queued,gate:rebase-attempt:3")")
gate_exile_recovery_sweep "$MARKERS"
if echo "$LABEL_REMOVE_LOG" | grep "m7:gate:exiled-tier5:3" >/dev/null && echo "$LABEL_REMOVE_LOG" | grep "m7:gate:rebase-attempt:3" >/dev/null \
   && [ "$GATE_EXILE_RECOVERY_CLEARED_IDS" = "$(printf '\nm7')" ]; then
  ok "legacy gate:rebase-attempt:N label is still recognized and cleared — a marker exiled before the rename is not silently invisible to recovery either"
else
  bad "legacy label not handled, got labels='$LABEL_REMOVE_LOG' cleared='$GATE_EXILE_RECOVERY_CLEARED_IDS'"
fi

echo "── (A8) multiple markers in one sweep: each handled independently ──"
reset_stubs
MARKERS=$(printf '[%s,%s,%s]' \
  "$(mk healthy      "crew/oracle/healthybranch-h8" "gate-status:queued")" \
  "$(mk clean_m      "crew/oracle/cleanbranch-c8"   "gate-status:queued,gate:exiled-tier5:2")" \
  "$(mk still_broken "crew/oracle/brokenbranch-b8"  "gate-status:queued,gate:exiled-tier5:2")")
gate_exile_recovery_sweep "$MARKERS"
if echo "$LABEL_REMOVE_LOG" | grep "clean_m:gate:exiled-tier5" >/dev/null \
   && ! echo "$LABEL_REMOVE_LOG" | grep "still_broken:gate:exiled-tier5" >/dev/null \
   && ! echo "$LABEL_REMOVE_LOG" | grep "healthy:" >/dev/null \
   && [ "$GATE_EXILE_RECOVERY_CLEARED_IDS" = "$(printf '\nclean_m')" ]; then
  ok "3 markers in one sweep, each handled independently: healthy untouched, clean_m cleared, still_broken left exiled (log='$LABEL_REMOVE_LOG')"
else
  bad "multi-marker sweep mishandled — labels='$LABEL_REMOVE_LOG' cleared='$GATE_EXILE_RECOVERY_CLEARED_IDS'"
fi

echo "── (A9) defensive: empty markers_json input does not crash ──"
reset_stubs
gate_exile_recovery_sweep ""
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$GATE_EXILE_RECOVERY_CLEARED_IDS" ]; then
  ok "empty markers_json is a clean no-op (rc=$RC)"
else
  bad "empty input should no-op cleanly, got rc=$RC cleared='$GATE_EXILE_RECOVERY_CLEARED_IDS'"
fi

echo ""
echo "── SECTION B: marker-select tier-selection — invariant (b), exile-age overdue ceiling ──"

extract_select_block() {
  sed -n '/# SELFTEST-EXTRACT marker-select: BEGIN/,/# SELFTEST-EXTRACT marker-select: END/p' "$1"
}
SELECT_BLOCK="$(extract_select_block "$DISPATCHER")"
if [ -z "$SELECT_BLOCK" ]; then
  echo "FATAL: could not extract marker-select block (sentinels missing?)" >&2
  exit 2
fi
ok "located live marker-select block via sentinel extraction"

# mkb <id> <created_at_iso> [extra-labels-csv]
mkb() {
  local id="$1" ts="$2" labels="${3:-gate-status:queued}"
  local labarr; labarr="$(printf '%s' "$labels" | jq -R 'split(",")')"
  jq -cn --arg id "$id" --arg ts "$ts" --argjson labels "$labarr" \
    '{id:$id, created_at:$ts, description:"branch: crew/mila/x", labels:$labels}'
}

# select_marker2 <block> <markers_json> <now> [age] [hard] [exile_ceiling]
# exile_ceiling omitted (5 args only) leaves GATE_EXILE_OVERDUE_SECONDS UNSET,
# so the block's own default (falls back to hard_threshold) governs — that
# distinction matters for test (B5) below, so it is never defaulted away here.
select_marker2() {
  local block="$1" markers_json="$2" now_epoch="$3" age_threshold="${4:-1800}" hard_threshold="${5:-5400}"
  if [ "$#" -ge 6 ]; then
    MARKERS_JSON="$markers_json" GATE_MARKER_NOW_OVERRIDE_EPOCH="$now_epoch" \
    GATE_MARKER_AGE_PROMOTE_SECONDS="$age_threshold" GATE_MARKER_HARD_AGE_SECONDS="$hard_threshold" \
    GATE_EXILE_OVERDUE_SECONDS="$6" GATE_PRIORITY_AUTHORS="oracle" \
    bash -c "$block"$'\necho "$MARKER_ID"' 2>/dev/null
  else
    MARKERS_JSON="$markers_json" GATE_MARKER_NOW_OVERRIDE_EPOCH="$now_epoch" \
    GATE_MARKER_AGE_PROMOTE_SECONDS="$age_threshold" GATE_MARKER_HARD_AGE_SECONDS="$hard_threshold" \
    GATE_PRIORITY_AUTHORS="oracle" \
    bash -c "$block"$'\necho "$MARKER_ID"' 2>/dev/null
  fi
}

NOW_EPOCH=1782863814
THRESH=1800   # matches GATE_MARKER_AGE_PROMOTE_SECONDS default
HARD=5400     # matches GATE_MARKER_HARD_AGE_SECONDS default
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
ago() { iso "$((NOW_EPOCH - $1))"; }

echo "── (B1) THE FIX: exile older than its OWN ceiling wins tier 1, even with a young created_at ──"
FIX=$(printf '[%s,%s,%s]' \
  "$(mkb fresh_h   "$(ago 60)"   "gate-status:queued")" \
  "$(mkb aged_h    "$(ago 2000)" "gate-status:queued")" \
  "$(mkb exiled_ov "$(ago 300)"  "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW_EPOCH-5500))")")
SEL=$(select_marker2 "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "$HARD")
[ "$SEL" = "exiled_ov" ] && ok "exile age 5500s > ${HARD}s ceiling wins over fresh AND merely-aged healthy markers — created_at (only 300s) is irrelevant, the EXILE clock drove it (wa-ycyf8 shape)" \
  || bad "expected exiled_ov, got '$SEL' — exile-age ceiling did not admit it to tier 1"

echo "── (B2) exile UNDER its ceiling stays excluded — no free pass just for being exiled ──"
FIX=$(printf '[%s,%s]' \
  "$(mkb fresh_h2  "$(ago 60)"  "gate-status:queued")" \
  "$(mkb exiled_un "$(ago 300)" "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW_EPOCH-1000))")")
SEL=$(select_marker2 "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "$HARD")
[ "$SEL" = "fresh_h2" ] && ok "exile age 1000s < ${HARD}s ceiling — still sinks behind the healthy marker as before (feature is bounded, not a blanket exile amnesty)" \
  || bad "expected fresh_h2, got '$SEL'"

echo "── (B3) regression guard: exiled with NO exiled-since label + overdue created_at still excluded ──"
FIX=$(printf '[%s,%s]' \
  "$(mkb broken_noclock "$(ago 10000)" "gate-status:queued,gate:exiled-tier5:2")" \
  "$(mkb fresh3         "$(ago 60)"    "gate-status:queued")")
SEL=$(select_marker2 "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "$HARD")
[ "$SEL" = "fresh3" ] && ok "no gate:exiled-since label at all (never yet observed by the watchdog) reads as not-old-enough, not as instantly-overdue — matches gate-priority-starvation-ceiling.selftest.sh case (4), re-verified here for this new code path" \
  || bad "expected fresh3, got '$SEL' — a missing exiled-since label wrongly admitted the marker to tier 1 (ga-q3ig2 regression)"

echo "── (B4) GATE_EXILE_OVERDUE_SECONDS=0 disables the feature entirely ──"
FIX=$(printf '[%s,%s]' \
  "$(mkb fresh4  "$(ago 60)"  "gate-status:queued")" \
  "$(mkb exiled4 "$(ago 300)" "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW_EPOCH-999999))")")
SEL=$(select_marker2 "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "0")
[ "$SEL" = "fresh4" ] && ok "GATE_EXILE_OVERDUE_SECONDS=0 disables the feature — even a 999999s-old exile stays excluded from tier 1" \
  || bad "expected fresh4, got '$SEL' — the 0-disables convention is not honored"

echo "── (B5) default: leaving GATE_EXILE_OVERDUE_SECONDS unset resolves to GATE_MARKER_HARD_AGE_SECONDS ──"
FIX=$(printf '[%s,%s]' \
  "$(mkb fresh5  "$(ago 60)"  "gate-status:queued")" \
  "$(mkb exiled5 "$(ago 300)" "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW_EPOCH-5500))")")
SEL=$(select_marker2 "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD")
[ "$SEL" = "exiled5" ] && ok "leaving GATE_EXILE_OVERDUE_SECONDS unset defaults to GATE_MARKER_HARD_AGE_SECONDS (5500s exile age > ${HARD}s default ceiling)" \
  || bad "expected exiled5, got '$SEL' — default did not fall back to the hard-age ceiling"

echo "── (B6) tier-1 internal FIFO is untouched: an older overdue-by-created_at healthy marker still beats a younger exile_overdue one ──"
FIX=$(printf '[%s,%s]' \
  "$(mkb old_overdue    "$(ago 8000)" "gate-status:queued")" \
  "$(mkb young_exile_ov "$(ago 300)"  "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW_EPOCH-5500))")")
SEL=$(select_marker2 "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "$HARD")
[ "$SEL" = "old_overdue" ] && ok "within tier 1, oldest-created_at-first FIFO still governs — exile admission gets IN to the tier, it does not jump the tier's own ordering" \
  || bad "expected old_overdue, got '$SEL' — exile admission broke tier-1's FIFO invariant"

echo "── (B7) gate-feedback-style regression: malformed GATE_EXILE_OVERDUE_SECONDS must not crash the sweep ──"
FIX2=$(printf '[%s,%s]' "$(mkb hh1 "$(ago 600)" "gate-status:queued")" "$(mkb hh2 "$(ago 60)" "gate-status:queued")")
SEL=$(MARKERS_JSON="$FIX2" GATE_MARKER_NOW_OVERRIDE_EPOCH="$NOW_EPOCH" \
  GATE_MARKER_AGE_PROMOTE_SECONDS="$THRESH" GATE_MARKER_HARD_AGE_SECONDS="$HARD" \
  GATE_EXILE_OVERDUE_SECONDS="not-a-number" GATE_PRIORITY_AUTHORS="oracle" \
  bash -c "set -euo pipefail; $SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null)
STATUS=$?
if [ "$STATUS" = "0" ] && [ "$SEL" = "hh2" ]; then
  ok "malformed GATE_EXILE_OVERDUE_SECONDS falls back to the hard-age default instead of crashing the sweep (exit=$STATUS, selected=$SEL)"
else
  bad "malformed GATE_EXILE_OVERDUE_SECONDS broke selection (exit=$STATUS, selected='$SEL')"
fi

echo ""
echo "── SECTION C: drift-guards ──"
grep -q 'def exile_overdue' "$DISPATCHER" \
  && ok "exile_overdue predicate present in the shipped dispatcher" || bad "exile_overdue predicate missing"
grep -q 'GATE_EXILE_OVERDUE_SECONDS' "$DISPATCHER" \
  && ok "exile-overdue ceiling is a configurable GATE_* tunable" || bad "exile-overdue ceiling not configurable"
grep -q 'gate_exile_recovery_sweep()' "$DISPATCHER" \
  && ok "gate_exile_recovery_sweep is defined in the shipped dispatcher" || bad "gate_exile_recovery_sweep missing"
grep -q 'GATE_EXILE_RECOVERY_ENABLED' "$DISPATCHER" \
  && ok "exile-recovery sweep has a reversible GATE_* enable flag (house convention)" || bad "no enable flag for exile-recovery"
grep -q 'still_exiled=\$(bd -C "\$GC_CITY" show "\$marker_id" --json' "$DISPATCHER" \
  && ok "exile-recovery verifies the clear by re-reading the marker before commenting/excluding it (ga-faw5o rounds 2-3 pattern, applied here too)" \
  || bad "exile-recovery no longer re-reads before claiming success — the comment-claims-more-than-delivered gap is back"
grep -q 'map(select((is_overdue and (has_rebase_fail | not)) or (has_rebase_fail and exile_overdue))' "$DISPATCHER" \
  && ok "tier 1's select expression wires exile_overdue in alongside the existing is_overdue arm" || bad "tier 1 select expression drifted from the tested shape"

echo ""
echo "── SECTION D: INTEGRATION — the literal Aceite #1 shape, both invariants chained ──"
echo "── (D1) 10 healthy markers + 1 exiled-but-clean -> recovery clears it -> next sweep's tier-selection treats it as healthy ──"
reset_stubs
STUB_MERGE_VERDICT="0"; STUB_ATTEMPT="2"
SINCE_EPOCH2=1700000000
HEALTHY_TEN_A="[]"
for i in $(seq 1 10); do
  HEALTHY_TEN_A=$(printf '%s\n' "$HEALTHY_TEN_A" | jq -c --argjson m "$(mk "healthy$i" "crew/mila/healthy$i" "gate-status:queued")" '. + [$m]')
done
SWEEP1=$(printf '%s\n' "$HEALTHY_TEN_A" | jq -c --argjson m "$(mk exiled_clean "crew/oracle/cleanbranch-ic" "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$SINCE_EPOCH2")" '. + [$m]')
gate_exile_recovery_sweep "$SWEEP1"
if [ "$GATE_EXILE_RECOVERY_CLEARED_IDS" = "$(printf '\nexiled_clean')" ]; then
  ok "recovery clears exiled_clean out of a 10-healthy-marker queue on the very first sweep it is checked"
else
  bad "setup failed: recovery did not clear exiled_clean out of the 10-marker queue, cleared='$GATE_EXILE_RECOVERY_CLEARED_IDS'"
fi
HEALTHY_TEN_B="[]"
for i in $(seq 1 10); do
  HEALTHY_TEN_B=$(printf '%s\n' "$HEALTHY_TEN_B" | jq -c --argjson m "$(mkb "healthy$i" "$(ago 600)" "gate-status:queued")" '. + [$m]')
done
SWEEP2=$(printf '%s\n' "$HEALTHY_TEN_B" | jq -c --argjson m "$(mkb exiled_clean "$(ago 10)" "gate-status:queued")" '. + [$m]')
SEL=$(select_marker2 "$SELECT_BLOCK" "$SWEEP2" "$NOW_EPOCH" "$THRESH" "$HARD")
if [ "$SEL" = "exiled_clean" ]; then
  ok "on the NEXT sweep's fresh fetch (exile labels gone from Dolt), exiled_clean competes as an ordinary healthy marker and wins on the normal newest-first tiebreak — this is the literal Aceite #1 shape: 10 healthy + 1 exiled-clean, back to the normal tier on the next sweep"
else
  bad "expected exiled_clean to win the next sweep as an ordinary healthy marker, got '$SEL'"
fi

echo ""
echo "── SECTION E: marker-select tier-selection — ga-r5dsgp, retry-ceiling caps exile_overdue admission ──"
echo "── (the ga-r5dsgp incident: exile_overdue (Section B) admits a marker to tier 1 purely on TIME, with"
echo "──  no regard for how many times it has already been retried — a marker whose auto-rebase keeps"
echo "──  failing IDENTICALLY (gate:rebase-fail-count climbing past 60) stays admitted forever once past"
echo "──  the exile-age ceiling, and because tier 1 sorts oldest-created_at-first it wins EVERY sweep,"
echo "──  starving the whole queue behind it — measured live: 59 consecutive sweeps, 2.5h, marker ga-r6bore) ──"

# select_marker3 <block> <markers_json> <now> <age> <hard> <exile_ceiling> [<retry_ceiling>]
# retry_ceiling omitted leaves GATE_EXILE_RETRY_CEILING UNSET, so the block's
# own default (3) governs — mirrors select_marker2's own exile_ceiling
# omission convention above, for the same reason (test E4 below needs it).
select_marker3() {
  local block="$1" markers_json="$2" now_epoch="$3" age_threshold="$4" hard_threshold="$5" exile_ceiling="$6"
  if [ "$#" -ge 7 ]; then
    MARKERS_JSON="$markers_json" GATE_MARKER_NOW_OVERRIDE_EPOCH="$now_epoch" \
    GATE_MARKER_AGE_PROMOTE_SECONDS="$age_threshold" GATE_MARKER_HARD_AGE_SECONDS="$hard_threshold" \
    GATE_EXILE_OVERDUE_SECONDS="$exile_ceiling" GATE_EXILE_RETRY_CEILING="$7" GATE_PRIORITY_AUTHORS="oracle" \
    bash -c "$block"$'\necho "$MARKER_ID"' 2>/dev/null
  else
    MARKERS_JSON="$markers_json" GATE_MARKER_NOW_OVERRIDE_EPOCH="$now_epoch" \
    GATE_MARKER_AGE_PROMOTE_SECONDS="$age_threshold" GATE_MARKER_HARD_AGE_SECONDS="$hard_threshold" \
    GATE_EXILE_OVERDUE_SECONDS="$exile_ceiling" GATE_PRIORITY_AUTHORS="oracle" \
    bash -c "$block"$'\necho "$MARKER_ID"' 2>/dev/null
  fi
}

echo "── (E1) THE FIX: exile_overdue by TIME but retry count >= ceiling — no longer dominates tier 1 ──"
FIX=$(printf '[%s,%s]' \
  "$(mkb fresh_e1  "$(ago 60)"  "gate-status:queued")" \
  "$(mkb runaway_e1 "$(ago 300)" "gate-status:queued,gate:exiled-tier5:61,gate:exiled-since:$((NOW_EPOCH-999999))")")
SEL=$(select_marker3 "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "$HARD" 3)
[ "$SEL" = "fresh_e1" ] && ok "runaway marker (attempt=61, exiled 999999s ago) no longer wins tier 1 over a fresh healthy marker — the ga-r5dsgp head-of-line block this fix exists to stop" \
  || bad "expected fresh_e1, got '$SEL' — a marker past its own retry ceiling is still dominating tier 1 (ga-r5dsgp regression)"

echo "── (E2) NOT reversed: a marker UNDER the ceiling still gets its exile_overdue admission (Section B1's shape, ceiling explicit) ──"
FIX=$(printf '[%s,%s,%s]' \
  "$(mkb fresh_e2   "$(ago 60)"   "gate-status:queued")" \
  "$(mkb aged_e2    "$(ago 2000)" "gate-status:queued")" \
  "$(mkb exiled_e2  "$(ago 300)"  "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW_EPOCH-5500))")")
SEL=$(select_marker3 "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "$HARD" 3)
[ "$SEL" = "exiled_e2" ] && ok "attempt=2 < ceiling=3 — still admitted to tier 1 by its overdue exile clock, exactly as Section B already proves (no regression)" \
  || bad "expected exiled_e2, got '$SEL' — the ceiling over-applied and blocked a marker still inside its retry budget"

echo "── (E3) boundary: attempt count EXACTLY AT the ceiling is excluded (strict <, matches house convention) ──"
FIX=$(printf '[%s,%s]' \
  "$(mkb fresh_e3    "$(ago 60)"  "gate-status:queued")" \
  "$(mkb atceiling_e3 "$(ago 300)" "gate-status:queued,gate:exiled-tier5:3,gate:exiled-since:$((NOW_EPOCH-999999))")")
SEL=$(select_marker3 "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "$HARD" 3)
[ "$SEL" = "fresh_e3" ] && ok "attempt count exactly AT the ceiling (3) is excluded, not just strictly-above — off-by-one matches MAX_REBASE_ATTEMPTS's own semantics (Step 4c: attempt>=MAX circuit-breaks)" \
  || bad "expected fresh_e3, got '$SEL' — attempt==ceiling should already be excluded"

echo "── (E4) default: leaving GATE_EXILE_RETRY_CEILING unset resolves to 3 ──"
# gate feedback (ga-r5dsgp attempt 1): the runaway must carry gate:exiled-tier5
# (has_rebase_fail) AND an overdue gate:exiled-since, or exile_overdue is never
# even evaluated and a fresh marker wins whatever the default is — the test was
# vacuous (a scratch copy with the default changed to 99 still passed).
FIX=$(printf '[%s,%s]' \
  "$(mkb fresh_e4    "$(ago 60)"  "gate-status:queued")" \
  "$(mkb runaway_e4  "$(ago 300)" "gate-status:queued,gate:exiled-tier5:9,gate:exiled-since:$((NOW_EPOCH-999999))")")
SEL=$(select_marker3 "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "$HARD")
[ "$SEL" = "fresh_e4" ] && ok "leaving GATE_EXILE_RETRY_CEILING unset defaults to 3 — attempt=9 is excluded from exile_overdue admission without an explicit override" \
  || bad "expected fresh_e4, got '$SEL' — default retry ceiling not wired"
# ...and the same fixture WITHOUT the ceiling must admit the runaway, otherwise
# E4 above could pass because the runaway was never a tier-1 candidate at all.
SEL=$(select_marker3 "$SELECT_BLOCK" "$FIX" "$NOW_EPOCH" "$THRESH" "$HARD" "$HARD" 99)
[ "$SEL" = "runaway_e4" ] && ok "E4 control: with the ceiling raised to 99 the SAME runaway IS admitted to tier 1 — so E4's exclusion is the ceiling's doing, not an artifact of the fixture" \
  || bad "E4 control: expected runaway_e4 with ceiling=99, got '$SEL' — the E4 fixture never reaches exile_overdue, so E4 proves nothing"

echo "── (E5) gate-feedback-style regression: malformed GATE_EXILE_RETRY_CEILING must not crash the sweep ──"
# The runaway (attempt=9, exile long overdue) is what makes this meaningful: a
# fallback to the wrong default (or a crash) changes WHO is selected, where the
# old fixture (no exile labels at all) selected the same marker regardless.
FIX5=$(printf '[%s,%s]' "$(mkb e5a "$(ago 300)" "gate-status:queued,gate:exiled-tier5:9,gate:exiled-since:$((NOW_EPOCH-999999))")" "$(mkb e5b "$(ago 60)" "gate-status:queued")")
SEL=$(MARKERS_JSON="$FIX5" GATE_MARKER_NOW_OVERRIDE_EPOCH="$NOW_EPOCH" \
  GATE_MARKER_AGE_PROMOTE_SECONDS="$THRESH" GATE_MARKER_HARD_AGE_SECONDS="$HARD" \
  GATE_EXILE_OVERDUE_SECONDS="$HARD" GATE_EXILE_RETRY_CEILING="not-a-number" GATE_PRIORITY_AUTHORS="oracle" \
  bash -c "set -euo pipefail; $SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null)
STATUS=$?
if [ "$STATUS" = "0" ] && [ "$SEL" = "e5b" ]; then
  ok "malformed GATE_EXILE_RETRY_CEILING falls back to the default (3): the attempt=9 runaway is excluded and the sweep does not crash (exit=$STATUS, selected=$SEL)"
else
  bad "malformed GATE_EXILE_RETRY_CEILING broke selection (exit=$STATUS, selected='$SEL')"
fi

echo "── (E7) ceiling parsing: leading zeros are normalized, zero is NOT a silent off-switch ──"
# "0"/"000" would make `attempt < 0` false for every marker (a silent disable —
# jq 1.8.1 reads "000" as 0, measured); "03" is not valid JSON and is normalized
# so the value does not depend on which jq is installed. All must behave as a
# sane ceiling of 3.
FIX7=$(printf '[%s,%s,%s]' \
  "$(mkb fresh_e7   "$(ago 60)"  "gate-status:queued")" \
  "$(mkb inside_e7  "$(ago 300)" "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW_EPOCH-999999))")" \
  "$(mkb runaway_e7 "$(ago 400)" "gate-status:queued,gate:exiled-tier5:9,gate:exiled-since:$((NOW_EPOCH-999999))")")
for CEIL in 03 0 000 ; do
  SEL=$(select_marker3 "$SELECT_BLOCK" "$FIX7" "$NOW_EPOCH" "$THRESH" "$HARD" "$HARD" "$CEIL")
  [ "$SEL" = "inside_e7" ] && ok "GATE_EXILE_RETRY_CEILING='$CEIL' behaves as a normal ceiling of 3: the attempt=2 marker is admitted, the attempt=9 runaway is not" \
    || bad "GATE_EXILE_RETRY_CEILING='$CEIL' selected '$SEL', expected inside_e7 (zero silently disabled exile_overdue admission, or a leading zero was not normalized)"
done

echo "── (E6) drift-guard: exile_overdue now composes a retry-count cap ──"
grep -q 'def rebase_attempt_count' "$DISPATCHER" \
  && ok "rebase_attempt_count predicate present in the shipped dispatcher" || bad "rebase_attempt_count predicate missing"
grep -q 'GATE_EXILE_RETRY_CEILING' "$DISPATCHER" \
  && ok "exile retry ceiling is a configurable GATE_* tunable" || bad "exile retry ceiling not configurable"
grep -q 'exile_overdue: (\$exile_ceiling > 0) and (exiled_since_epoch != null) and ((\$now - exiled_since_epoch) > \$exile_ceiling) and (rebase_attempt_count < \$retry_ceiling)' "$DISPATCHER" \
  && ok "exile_overdue's own definition composes the retry-count cap (not a separate select-line clause — keeps tier 1's outer shape, and Section C's drift-guard, untouched)" \
  || bad "exile_overdue no longer wires in the retry-count cap the way this fix shipped it"

echo ""
echo "== gate-0ye7ar-exile-recovery.selftest: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
