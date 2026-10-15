#!/usr/bin/env bash
# gate-passed-confirm.selftest.sh — prove ga-botvu2 part 3 in isolation, with NO live Dolt/gc/launchd:
# a hand-off that writes gate:passed READS IT BACK, retries once, and records a failure on the bead.
#
#   BUG (ga-botvu2): every hand-off wrote the label as
#       bd -C … label add "$BEAD_ID" "gate:passed" -q 2>/dev/null || true
#   — a failed write vanished. A story handed off without gate:passed is invisible to story-delivery
#   (selector: story:approved + gate:passed), and merged-bead-janitor reads "no gate:passed" as "never
#   queued for delivery". The write sites are quality-gate-dispatcher.sh (3: the PASS tail, the
#   already-merged-story hand-off in Step 0a-4, the superseded-story hand-off) and quality-gate-guard.sh
#   (gap2_apply_pass_verdict). Each now calls gate_passed_confirm right after the write.
#
# SOURCES the guard in lib-only mode for the REAL functions (gate_passed_confirm lives in its lib region,
# which the dispatcher sources too), drives them with an in-shell bd mock, then DRIFT-GUARDS the write
# sites. Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

GATE_GUARD_LIB_ONLY=1 source "$GUARD" \
  || { echo "FATAL: could not source guard in lib-only mode"; exit 1; }
for fn in gate_passed_confirm _gate_passed_on_bead; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by guard (lib-only)"; exit 1; }
done

# bd runs inside $(…) in _gate_passed_on_bead, so its call log has to be a FILE, not a variable.
CALLS="$(mktemp 2>/dev/null || mktemp -t gpconfirm)"
trap 'rm -f "$CALLS"' EXIT

# Mock bd: logs every call. MOCK_SHOW picks what `bd show` does; MOCK_ADD_STICKS=1 makes `label add`
# take effect (the label shows up on the next read), 0 drops it silently (rc0, nothing written).
# The label state is a FILE too (MOCK_STATE), for the same subshell reason.
MOCK_STATE="$(mktemp 2>/dev/null || mktemp -t gpstate)"
trap 'rm -f "$CALLS" "$MOCK_STATE"' EXIT
bd() {
  printf '%s\n' "$*" >> "$CALLS"
  case "$3" in
    show)
      local has=0; [ "$(cat "$MOCK_STATE")" = "1" ] && has=1
      case "${MOCK_SHOW:-normal}" in
        fail)     return 1 ;;
        empty)    return 0 ;;
        garbage)  printf 'this is not json'; return 0 ;;
        nolabels) printf '[{"id":"x"}]' ;;
        similar)  printf '[{"id":"x","labels":["story:approved","gate:passed-warn"]}]' ;;
        object)   if [ "$has" = "1" ]; then printf '{"id":"x","labels":["story:approved","gate:passed"]}'; else printf '{"id":"x","labels":["story:approved"]}'; fi ;;
        *)        if [ "$has" = "1" ]; then printf '[{"id":"x","labels":["story:approved","gate:passed"]}]'; else printf '[{"id":"x","labels":["story:approved"]}]'; fi ;;
      esac
      ;;
    label)
      case " $* " in *" add "*"gate:passed"*) [ "${MOCK_ADD_STICKS:-1}" = "1" ] && printf 1 > "$MOCK_STATE" ;; esac
      return 0 ;;
    comment) [ "${MOCK_COMMENT_FAILS:-0}" = "1" ] && return 1; return 0 ;;
  esac
  return 0
}
# run <has gate:passed now 0|1> [show mode] [re-write sticks 0|1] [comment fails 0|1]
run() { : > "$CALLS"; printf '%s' "$1" > "$MOCK_STATE"
        MOCK_SHOW="${2:-normal}"; MOCK_ADD_STICKS="${3:-1}"; MOCK_COMMENT_FAILS="${4:-0}"
        RC=0; gate_passed_confirm "/fake/city" "ga-x" || RC=$?; }   # the guard sets -e when sourced: capture rc, do not let it abort
n_adds()     { grep -c '^-C /fake/city label add ga-x gate:passed' "$CALLS" || true; }   # anchored: the failure comment's text quotes the command
n_comments() { grep -c '^-C /fake/city comment ga-x ' "$CALLS" || true; }

echo "── gate_passed_confirm ──"
run 1
eq "label already there -> rc0"                 "$RC" "0"
eq "...no second write"                         "$(n_adds)" "0"
eq "...no failure comment"                      "$(n_comments)" "0"

run 0 normal 1
eq "label missing, the re-write sticks -> rc0"  "$RC" "0"
eq "...exactly one re-write"                    "$(n_adds)" "1"
eq "...no failure comment"                      "$(n_comments)" "0"

run 0 normal 0
eq "label missing and the re-write is dropped -> rc1 (never 'confirmed' on a write's own rc)" "$RC" "1"
eq "...one re-write attempted, not a loop"      "$(n_adds)" "1"
eq "...failure recorded on the bead"            "$(n_comments)" "1"
grep -q 'could NOT confirm gate:passed' "$CALLS" && ok "...the comment names the problem" || bad "...the comment does not say gate:passed could not be confirmed"
grep -q 'bd label add ga-x gate:passed' "$CALLS" && ok "...and says how to fix it by hand" || bad "...and does not say how to fix it"

run 0 fail 1
eq "bd show FAILS -> rc1 (could not read is not 'confirmed')" "$RC" "1"
eq "...failure recorded on the bead"            "$(n_comments)" "1"
run 0 empty 1
eq "bd show returns NOTHING -> rc1"             "$RC" "1"
run 0 garbage 1
eq "bd show returns garbage -> rc1"             "$RC" "1"
run 0 nolabels 1
eq "bead JSON without a labels field -> rc1"    "$RC" "1"
run 0 similar 1
eq "gate:passed-warn is a different label -> rc1 (whole-token match)" "$RC" "1"
run 1 object 1
eq "bd show returning an object (not an array) is read too -> rc0" "$RC" "0"

run 0 normal 0 1
eq "the failure comment itself failing still returns rc1, no abort" "$RC" "1"

echo ""
echo "── the dispatcher gets it too, and every write site calls it ──"
( GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" >/dev/null 2>&1; type gate_passed_confirm >/dev/null 2>&1 ) \
  && ok "gate_passed_confirm is defined once the dispatcher is sourced (it sources the guard lib)" \
  || bad "gate_passed_confirm is NOT defined after sourcing the dispatcher — its call sites would fail"
# Each dispatcher write is followed, on the very next line, by the confirm.
SITES=$(grep -c 'label add "\$BEAD_ID" "gate:passed" -q 2>/dev/null || true' "$DISPATCHER" || true)
CONFS=$(grep -A1 'label add "\$BEAD_ID" "gate:passed" -q 2>/dev/null || true' "$DISPATCHER" | grep -c 'gate_passed_confirm "\$BEAD_CITY" "\$BEAD_ID" || true' || true)
eq "dispatcher: gate:passed write sites"        "$SITES" "3"
eq "dispatcher: each is followed by gate_passed_confirm" "$CONFS" "$SITES"
grep -A1 'label add "\$bead_id" "gate:passed" -q 2>/dev/null || true' "$GUARD" | grep -q 'gate_passed_confirm "\$GC_CITY" "\$bead_id" || true' \
  && ok "guard (gap2_apply_pass_verdict): the write is followed by gate_passed_confirm" \
  || bad "guard: the gate:passed write in gap2_apply_pass_verdict is not followed by gate_passed_confirm"
# The one site that already warns (gate_merged_path_vm_gate, ga-buac0o) must stay as it was.
grep -q 'Could not add gate:passed to \$bead_id' "$DISPATCHER" \
  && ok "the existing warn-on-failure write (ga-buac0o) is untouched" \
  || bad "the ga-buac0o warn-on-failure write changed"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
