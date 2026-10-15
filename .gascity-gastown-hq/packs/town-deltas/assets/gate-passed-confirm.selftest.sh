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
# gate-fix 1 (the gate's verdict on the first attempt): the janitor's grace clock cannot be `updated_at` —
# `bd label add/remove` and `bd comment` do not advance it (only `bd update` does), so the hand-off left it at
# some earlier, unrelated write. gate_passed_confirm therefore also STAMPS the hand-off moment
# (`bd update --set-metadata gate.passed_at=<epoch>`), READS IT BACK, retries once, and records a failure.
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
MOCK_META="$(mktemp 2>/dev/null || mktemp -t gpmeta)"    # the bead's gate.passed_at metadata ('' = none)
MOCK_UPD="$(mktemp 2>/dev/null || mktemp -t gpupd)"      # one line per `update --set-metadata gate.passed_at=`
ERR="$(mktemp 2>/dev/null || mktemp -t gperr)"           # stderr of the last gate_passed_confirm
trap 'rm -f "$CALLS" "$MOCK_STATE" "$MOCK_META" "$MOCK_UPD" "$ERR"' EXIT
bd() {
  printf '%s\n' "$*" >> "$CALLS"
  case "$3" in
    show)
      local has=0; [ "$(cat "$MOCK_STATE")" = "1" ] && has=1
      local meta; meta=$(cat "$MOCK_META"); local mj='{}'; [ -n "$meta" ] && mj="{\"gate.passed_at\":\"$meta\"}"
      case "${MOCK_SHOW:-normal}" in
        nometa)   if [ "$has" = "1" ]; then printf '[{"id":"x","labels":["story:approved","gate:passed"]}]'; else printf '[{"id":"x","labels":["story:approved"]}]'; fi ;;
        fail)     return 1 ;;
        empty)    return 0 ;;
        garbage)  printf 'this is not json'; return 0 ;;
        nolabels) printf '[{"id":"x"}]' ;;
        similar)  printf '[{"id":"x","labels":["story:approved","gate:passed-warn"]}]' ;;
        object)   if [ "$has" = "1" ]; then printf '{"id":"x","labels":["story:approved","gate:passed"],"metadata":%s}' "$mj"; else printf '{"id":"x","labels":["story:approved"],"metadata":%s}' "$mj"; fi ;;
        *)        if [ "$has" = "1" ]; then printf '[{"id":"x","labels":["story:approved","gate:passed"],"metadata":%s}]' "$mj"; else printf '[{"id":"x","labels":["story:approved"],"metadata":%s}]' "$mj"; fi ;;
      esac
      ;;
    label)
      case " $* " in *" add "*"gate:passed"*) [ "${MOCK_ADD_STICKS:-1}" = "1" ] && printf 1 > "$MOCK_STATE" ;; esac
      return 0 ;;
    comment) [ "${MOCK_COMMENT_FAILS:-0}" = "1" ] && return 1; return 0 ;;
    update)
      case " $* " in *" --unset-metadata gate.passed_at "*) : > "$MOCK_META"; return 0 ;; esac
      local a v=""; for a in "$@"; do case "$a" in gate.passed_at=*) v="${a#gate.passed_at=}" ;; esac; done
      [ -n "$v" ] || return 0
      echo x >> "$MOCK_UPD"
      case "${MOCK_STAMP:-sticks}" in
        fail)    return 1 ;;                                   # rc1, nothing written
        dropped) return 0 ;;                                   # rc0, nothing written (the silent failure)
        once)    [ "$(wc -l < "$MOCK_UPD" | tr -d ' ')" -ge 2 ] && printf '%s' "$v" > "$MOCK_META"; return 0 ;;   # first dropped, retry sticks
        *)       printf '%s' "$v" > "$MOCK_META"; return 0 ;;
      esac ;;
  esac
  return 0
}
# run <has gate:passed now 0|1> [show mode] [re-write sticks 0|1] [comment fails 0|1]
# The stamp is opted into per call: STAMP_MODE=sticks|dropped|fail|once (default sticks), META0=<a stale gate.passed_at>.
run() { : > "$CALLS"; : > "$MOCK_UPD"; : > "$ERR"; printf '%s' "$1" > "$MOCK_STATE"; printf '%s' "${META0:-}" > "$MOCK_META"
        MOCK_SHOW="${2:-normal}"; MOCK_ADD_STICKS="${3:-1}"; MOCK_COMMENT_FAILS="${4:-0}"; MOCK_STAMP="${STAMP_MODE:-sticks}"
        RC=0; gate_passed_confirm "/fake/city" "ga-x" 2>"$ERR" || RC=$?; STAMP_MODE=sticks; META0=''; }   # the guard sets -e when sourced: capture rc, do not let it abort
n_adds()     { grep -c '^-C /fake/city label add ga-x gate:passed' "$CALLS" || true; }   # anchored: the failure comment's text quotes the command
n_comments() { grep -c '^-C /fake/city comment ga-x ' "$CALLS" || true; }
n_stamps()   { grep -c -- '^-C /fake/city update ga-x --set-metadata gate.passed_at=' "$CALLS" || true; }
n_unsets()   { grep -c -- '^-C /fake/city update ga-x --unset-metadata gate.passed_at' "$CALLS" || true; }
stamp_now()  { cat "$MOCK_META"; }

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
echo "── gate_passed_confirm STAMPS the hand-off moment (gate-fix 1): the janitor's clock ──"
# bd's updated_at does not move on `label add/remove` or `comment`, so the label write above leaves it at an
# earlier, unrelated write; the stamp is the only record of WHEN the gate handed the story off.
T0=$(date +%s); run 1; T1=$(date +%s)
eq "label already there -> still rc0"           "$RC" "0"
eq "...gate.passed_at written exactly once"     "$(n_stamps)" "1"
ST=$(stamp_now)
case "$ST" in
  ''|*[!0-9]*) bad "...the stamp is an epoch (got [$ST])" ;;
  *) if [ "$ST" -ge "$T0" ] && [ "$ST" -le "$T1" ]; then ok "...and it is THIS moment ($ST in [$T0,$T1])"; else bad "...stamp $ST is not within [$T0,$T1]"; fi ;;
esac
eq "...no failure comment"                      "$(n_comments)" "0"

run 0 normal 1
eq "label missing, the re-write sticks -> rc0"  "$RC" "0"
eq "...the stamp is written once the label is confirmed" "$(n_stamps)" "1"

run 0 normal 0
eq "label NOT confirmed -> rc1"                 "$RC" "1"
eq "...and NO stamp (a stamp on a story that does not wear the label would outlive a by-hand label add)" "$(n_stamps)" "0"

META0=111 run 1
ST=$(stamp_now)
if [ "$ST" != "111" ] && [ "$ST" -ge "$T0" ] 2>/dev/null; then ok "an older gate.passed_at from an earlier pass is REPLACED ($ST)"; else bad "stale stamp 111 was not replaced (got [$ST])"; fi

STAMP_MODE=once run 1
eq "first stamp write dropped, the retry sticks -> rc0" "$RC" "0"
eq "...two writes, no more"                     "$(n_stamps)" "2"
eq "...nothing to report on the bead"           "$(n_comments)" "0"
case "$(stamp_now)" in ''|*[!0-9]*) bad "...the retried stamp did not land" ;; *) ok "...and the stamp landed" ;; esac

STAMP_MODE=dropped META0=111 run 1
eq "stamp write returns 0 but nothing is written (silent drop) -> label rc still 0" "$RC" "0"
eq "...read back, retried ONCE, not a loop"     "$(n_stamps)" "2"
eq "...the failure is recorded on the bead"     "$(n_comments)" "1"
grep -q 'gate.passed_at' "$CALLS" && grep '^-C /fake/city comment ga-x ' "$CALLS" | grep -q 'gate.passed_at' \
  && ok "...the comment names gate.passed_at" || bad "...the comment does not name gate.passed_at"
eq "...the stale 111 is cleared (an old stamp must not stand for this hand-off)" "$(n_unsets)" "1"
eq "...so the stored stamp is empty"            "$(stamp_now)" ""
grep -q 'gate.passed_at' "$ERR" && ok "...and a line on stderr says so" || bad "...nothing on stderr"

STAMP_MODE=fail run 1
eq "stamp write FAILS (rc1) -> label rc still 0, stamp written twice" "$RC:$(n_stamps)" "0:2"
eq "...recorded on the bead"                    "$(n_comments)" "1"

run 1 nometa
eq "bd show carries no metadata field -> the stamp cannot be confirmed: written twice" "$(n_stamps)" "2"
eq "...recorded on the bead"                    "$(n_comments)" "1"

run 1 object
eq "bd show as an object also reads the stamp: one write" "$(n_stamps)" "1"
eq "...no failure comment"                      "$(n_comments)" "0"

echo ""
echo "── a failed confirm is never invisible (stderr), even when the bead comment fails too ──"
run 0 normal 0 1
eq "label unconfirmed and the comment fails too -> rc1" "$RC" "1"
grep -q 'gate:passed' "$ERR" && ok "...stderr still says gate:passed could not be confirmed" || bad "...nothing on stderr: a failure invisible everywhere"
run 0 normal 0 0
grep -q 'gate:passed' "$ERR" && ok "label unconfirmed, comment lands -> stderr says it too" || bad "...nothing on stderr"
run 1
eq "confirmed hand-off is quiet on stderr"      "$(wc -c < "$ERR" | tr -d ' ')" "0"

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
