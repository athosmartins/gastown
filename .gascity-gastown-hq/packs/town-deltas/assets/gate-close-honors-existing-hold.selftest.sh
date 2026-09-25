#!/usr/bin/env bash
# gate-close-honors-existing-hold.selftest.sh (ga-hwzzou)
#
# THE BUG (found by code reading while fixing ga-wlhd07; this test is what
# reproduces it): the mirror of ga-wlhd07, in the opposite order.
#
#   1. A bead is delivered as branches in two repos (HQ + whatsapp_automation,
#      the ga-g7x0si shape). Branch A PASSES and merges; its daemon verification
#      says NEEDS_GUARDED_RESTART (or DEPLOY_FAILED / JOB_NOT_INSTALLED), so the
#      dispatcher's ga-l7n3v branch HOLDS the source bead: label
#      delivery:pending-restart, bead left open. A's marker closes as
#      gate-status:passed.
#   2. Branch B later PASSES and merges with a clean daemon verdict, so the
#      dispatcher takes the ELSE branch: gate_sibling_hold_check finds every
#      marker closed (A's included) and the plain gate_close_source_terminal
#      closes the bead — while A's daemon is still unverified. Nothing on that
#      path read the bead's OWN delivery:pending-restart / delivery:partial.
#
# THE FIX: gate_own_hold_check reads the bead's own labels right before the
# close and holds (IS_OWN_HOLD=1, comment, gate:reviewing cleared) when a hold
# applies. Three outcomes, never collapsed: none → close, held → hold,
# unverified (the read failed / came back unusable) → hold.
#
# WHAT THIS RUNS: the REAL `pass-close-decision` region of the live dispatcher
# (sibling check + own-hold check + the close itself), with the real helpers
# extracted verbatim, against a mocked `bd`. The observable is the bug's literal
# symptom — whether `bd close` is called on the bead. Section 5 then MUTATES the
# extracted code (each mutation re-creates one defect) and requires the matching
# scenario to go red: deleting the own-hold block IS the pre-fix code, so the
# "pending-restart is present" scenario must CLOSE the bead under that mutation.
#
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

echo "== gate-close-honors-existing-hold.selftest (ga-hwzzou) =="

# ── 1. extract the real pieces VERBATIM from the live dispatcher ─────────────
echo "── 1. extract the real close-decision region and its helpers ──"
extract() {  # $1 = marker name
  awk -v b="SELFTEST-EXTRACT $1: BEGIN" -v e="SELFTEST-EXTRACT $1: END" \
    'index($0,b){f=1;next} index($0,e){f=0} f' "$DISPATCHER"
}
FN_OWN="$(extract own-hold-check-fn)"
FN_SIB="$(extract sibling-hold-check-fn)"
FN_CLOSE="$(extract gate-close-source-terminal-fn)"
REGION="$(extract pass-close-decision)"
for _n in FN_OWN FN_SIB FN_CLOSE REGION; do
  [ -n "${!_n}" ] || { echo "FATAL: could not extract $_n — SELFTEST-EXTRACT markers moved?" >&2; exit 2; }
  ok "extracted $_n ($(printf '%s\n' "${!_n}" | wc -l | tr -d ' ') lines)"
done

# The region must still contain BOTH the own-hold check and the close, in that
# order — otherwise a later edit could shrink the region until the scenarios
# below stop exercising the close and pass vacuously.
_pos_own=$(printf '%s\n' "$REGION" | grep -n 'gate_own_hold_check "\$BEAD_CITY" "\$BEAD_ID"' | head -1 | cut -d: -f1 || true)
_pos_close=$(printf '%s\n' "$REGION" | grep -n 'gate_close_source_terminal "\$BEAD_ID"' | head -1 | cut -d: -f1 || true)
if [ -n "$_pos_own" ] && [ -n "$_pos_close" ] && [ "$_pos_own" -lt "$_pos_close" ]; then
  ok "region runs gate_own_hold_check (line $_pos_own) BEFORE gate_close_source_terminal (line $_pos_close)"
else
  bad "region no longer orders own-hold check ($_pos_own) before the close ($_pos_close) — the scenarios below would be vacuous"
fi

# Static drift guard: the flag must gate BOTH the close and the POST-MERGE
# re-spawn exemption (a held-open bead would otherwise false-flag as a re-pick
# vector and mail the Mayor). Exactly two conditions read it.
_n_flag=$(grep -cF '[ "$IS_OWN_HOLD" != "1" ]' "$DISPATCHER" || true)
eq "IS_OWN_HOLD gates exactly two conditions (the close + the POST-MERGE exemption)" "$_n_flag" "2"

# ── 2. harness: mocked bd, real helpers ──────────────────────────────────────
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ERR_F="$WORK_DIR/stderr"; LOG_F="$WORK_DIR/log"; COMMENT_F="$WORK_DIR/comments"
LABEL_F="$WORK_DIR/labels"; CLOSE_F="$WORK_DIR/closes"; SHOW_F="$WORK_DIR/show-calls"

FX=ga-hwzzou-fx
SHOW_MODE=clean
SIB_MODE=none
lbl_json() { printf '[{"id":"%s","labels":%s}]' "$FX" "$1"; }

# Dispatch on the VERB ($3, after `-C <city>`), never on a substring of "$*".
# show-calls goes to a FILE: gate_own_hold_check calls `bd` inside $(...), so a
# counter variable would die with the subshell.
bd() {
  case "${3:-}" in
    show)
      printf 'x\n' >> "$SHOW_F"
      case "$SHOW_MODE" in
        clean)          lbl_json '["gate:passed","lane:small"]' ;;
        nolabels)       printf '[{"id":"%s"}]' "$FX" ;;
        pending)        lbl_json '["gate:passed","delivery:pending-restart"]' ;;
        partial)        lbl_json '["gate:passed","delivery:partial","scope:needs-review"]' ;;
        partial_cov)    lbl_json '["delivery:partial","scope_covered:all"]' ;;
        pending_cov)    lbl_json '["delivery:pending-restart","scope_covered:all"]' ;;
        object_pending) printf '{"id":"%s","labels":["delivery:pending-restart"]}' "$FX" ;;
        fail)           printf '{\n  "error": "no issues found matching the provided IDs",\n  "schema_version": 1\n}\n'
                        echo "Error fetching $4: no issue found matching \"$4\"" >&2
                        return 1 ;;
        errjson0)       printf '{"error":"no issues found matching the provided IDs","schema_version":1}' ;;
        emptyarr)       printf '[]' ;;
        garbage)        printf 'not json at all' ;;
        wrongid)        printf '[{"id":"ga-some-other-bead","labels":["delivery:pending-restart"]}]' ;;
      esac ;;
    close)   printf 'CLOSED:%s\n' "${4:-}" >> "$CLOSE_F" ;;
    comment) printf '%s\n----\n' "${5:-}" >> "$COMMENT_F" ;;
    label)   printf '%s\n' "$*" >> "$LABEL_F" ;;
  esac
  return 0
}
log()  { printf '%s\n' "$*" >> "$LOG_F"; }
warn() { printf '%s\n' "$*" >> "$LOG_F"; }
# Stand-in for quality-gate-guard.sh's helper: rows are "<branch>\t<status>\t<rig>".
gate_bead_sibling_status_lines() {
  if [ "$SIB_MODE" = "open" ]; then printf 'fix/%s-wa\topen\twhatsapp_automation\n' "$FX"; fi
  return 0
}
eval "$FN_SIB"
eval "$FN_OWN"
eval "$FN_CLOSE"

run_region() {  # $1=SHOW_MODE  $2=SIB_MODE  $3=region text (default: the real one)
  SHOW_MODE="$1"; SIB_MODE="${2:-none}"
  : > "$ERR_F"; : > "$LOG_F"; : > "$COMMENT_F"; : > "$LABEL_F"; : > "$CLOSE_F"; : > "$SHOW_F"
  GC_CITY=city; BEAD_CITY=beadcity; BEAD_ID="$FX"; BRANCH="fix/$FX"; RIG=gascity
  DEFAULT_BRANCH=main; MERGE_SHA=abc1234; GATE_RUN_ID=run1; DAEMON_SOFT_WARN=""
  IS_SIBLING_HOLD=0; IS_OWN_HOLD=0; SIBLING_HOLD_KIND=""; OWN_HOLD_KIND=""; OWN_HOLD_LABELS=""
  eval "${3:-$REGION}" 2>"$ERR_F"
}
was_closed() { grep -qF "CLOSED:$FX" "$CLOSE_F"; }
show_calls() { wc -l < "$SHOW_F" | tr -d ' '; }

# ── 3. the three outcomes, through the real region ───────────────────────────
echo "── 3. none → close ─ held → hold ─ unverified → hold (real region, mocked bd) ──"

# NONE: the ordinary case must be unchanged — the bead closes.
run_region clean
was_closed && ok "no hold labels → the bead is CLOSED as before" || bad "clean bead was NOT closed — the fix broke the ordinary close path"
eq "no hold labels → IS_OWN_HOLD stays 0" "$IS_OWN_HOLD" "0"
eq "no hold labels → exactly one live bd show" "$(show_calls)" "1"
! grep -q 'ga-hwzzou' "$COMMENT_F" && ok "no hold labels → no ga-hwzzou comment written" || bad "a hold comment was written for a clean bead"

# "empty" is NOT "unverified": a bead with no labels key at all read fine.
run_region nolabels
was_closed && ok "a bead with NO labels key (read fine) is CLOSED — empty is not 'unverified'" || bad "no-labels bead was held — 'empty' collapsed into 'unverified'"

# HELD — THE BUG: delivery:pending-restart from an earlier branch's daemon hold.
run_region pending
! was_closed && ok "delivery:pending-restart present → the bead is NOT closed (the bug: it used to be)" || bad "REGRESSION: a delivery:pending-restart bead was CLOSED by the PASS path"
eq "pending-restart → IS_OWN_HOLD=1" "$IS_OWN_HOLD" "1"
eq "pending-restart → OWN_HOLD_KIND=held" "$OWN_HOLD_KIND" "held"
grep -q 'NOT closing (ga-hwzzou)' "$COMMENT_F" && grep -q 'delivery:pending-restart' "$COMMENT_F" \
  && ok "comment says it is not closing and names the hold label" || bad "comment missing or does not name the label: [$(cat "$COMMENT_F")]"
grep -q 'already carries a hold from an EARLIER delivery' "$COMMENT_F" \
  && ok "comment says the hold predates this PASS" || bad "comment does not say the hold is from an earlier delivery"
grep -q 'No automatic retry' "$COMMENT_F" && grep -q 'close this bead by hand' "$COMMENT_F" \
  && ok "comment states honestly there is no retry and names the manual action" || bad "comment lacks the no-retry statement or the manual action"
! grep -qE 'Re-checked every|closes automatically|will close (it|this bead) (for you|automatically)' "$COMMENT_F" "$LOG_F" \
  && ok "no false promise of an automatic retry/close (none exists)" || bad "a surface promises an automatic retry/close that nothing implements"
grep -q 'gate:reviewing' "$LABEL_F" && ok "gate:reviewing is cleared on hold (wa-qq33j)" || bad "gate:reviewing not cleared on hold"
grep -q 'holding, NOT closing (ga-hwzzou)' "$LOG_F" && ok "the dispatcher log records the hold" || bad "no log line for the hold: [$(cat "$LOG_F")]"

# HELD — delivery:partial with no override.
run_region partial
! was_closed && ok "delivery:partial (no scope_covered:all) → NOT closed" || bad "a delivery:partial bead was CLOSED"
grep -q 'delivery:partial' "$COMMENT_F" && ok "comment names delivery:partial" || bad "comment does not name delivery:partial"

# THE DOCUMENTED OVERRIDE: nothing ever strips delivery:partial, and the janitor
# documents that scope_covered:all + re-gate closes via the PASS path. Honouring
# delivery:partial unconditionally would break that recovery.
run_region partial_cov
was_closed && ok "delivery:partial + scope_covered:all → CLOSED (the documented override still works)" \
  || bad "delivery:partial + scope_covered:all was HELD — the scope_covered:all recovery path is broken"
# ...but the override is for delivery:partial only.
run_region pending_cov
! was_closed && ok "delivery:pending-restart + scope_covered:all → still NOT closed (the override does not cover it)" \
  || bad "scope_covered:all wrongly released a delivery:pending-restart hold"

run_region object_pending
! was_closed && ok "an object-shaped (non-array) bd show response is read the same way" || bad "object-shaped response was not honoured"

# UNVERIFIED — every way of not knowing must hold, never read as 'no hold → close'.
run_region fail
! was_closed && ok "bd show FAILS (rc=1 + JSON error object on stdout) → NOT closed" || bad "REGRESSION: a failed label read CLOSED the bead (error read as 'no hold')"
eq "failed read → OWN_HOLD_KIND=unverified" "$OWN_HOLD_KIND" "unverified"
eq "failed read → IS_OWN_HOLD=1" "$IS_OWN_HOLD" "1"
grep -q 'ALERT: gate_own_hold_check could not read' "$LOG_F" && ok "the read-failure ALERT reaches the log" || bad "no ALERT for the failed read: [$(cat "$LOG_F")]"
grep -q 'Error fetching' "$ERR_F" && ok "bd's own error text reaches stderr (\$LOG) — not swallowed by a 2>/dev/null" \
  || bad "bd's stderr was swallowed — stderr was: [$(cat "$ERR_F")]"
grep -q 'UNKNOWN' "$COMMENT_F" && grep -q 'FAILED' "$COMMENT_F" \
  && ok "comment says the read FAILED and the hold labels are UNKNOWN" || bad "comment does not say the read failed: [$(cat "$COMMENT_F")]"
! grep -q 'already carries a hold from an EARLIER delivery' "$COMMENT_F" \
  && ok "comment does NOT assert a hold that was never confirmed (failure not presented as a positive)" \
  || bad "comment claims a hold on a FAILED read (failure presented as a positive)"
grep -qF 'bd -C beadcity show ga-hwzzou-fx' "$COMMENT_F" \
  && ok "the manual check pins the store (bd -C <city> show ...)" || bad "manual check is a bare bd (a wrong-store miss reads as 'no hold')"

# Exit 0 but the payload is not this bead. Exit status alone would read all of
# these as "no hold labels" — the reason the read also demands a matching .id.
for _m in errjson0 emptyarr garbage wrongid; do
  run_region "$_m"
  ! was_closed && eq "rc=0 but payload unusable ($_m) → NOT closed, kind" "$OWN_HOLD_KIND" "unverified" \
    || bad "payload '$_m' (exit 0, not this bead) CLOSED the bead"
done
run_region garbage
[ -s "$ERR_F" ] && ok "unparseable JSON: jq's own message reaches stderr (\$LOG)" || bad "jq's parse error was swallowed"
# The unverified comment names both labels GENERICALLY ("whether ... left it a hold
# (delivery:pending-restart / delivery:partial) is UNKNOWN"), so grepping for the
# label name cannot tell "attributed a foreign bead's label" from that wording.
# The attribution has two exact signatures: OWN_HOLD_LABELS non-empty, and the
# held-kind sentence. Neither may appear for another bead's payload.
run_region wrongid
eq "another bead's labels are never attributed to this one (OWN_HOLD_LABELS empty)" "$OWN_HOLD_LABELS" ""
! grep -q 'already carries a hold from an EARLIER delivery' "$COMMENT_F" \
  && ok "the comment never claims this bead carries a hold that belongs to a DIFFERENT bead" \
  || bad "the comment attributes a FOREIGN bead's hold to this bead"

# ── 4. interplay with the sibling hold ───────────────────────────────────────
echo "── 4. sibling hold interplay ──"
run_region pending open
! was_closed && eq "open sibling + pending-restart → still held" "$IS_SIBLING_HOLD" "1" || bad "held bead was closed"
eq "open sibling → no second bd read (already held)" "$(show_calls)" "0"
eq "open sibling → IS_OWN_HOLD not set (the sibling hold owns it)" "$IS_OWN_HOLD" "0"
run_region clean open
! was_closed && ok "open sibling + clean bead → still NOT closed (ga-rhzbii unchanged)" || bad "ga-rhzbii regressed: a bead with an open sibling was closed"

# ── 5. mutations: each re-creates ONE defect and must turn a scenario red ────
echo "── 5. mutations (each must flip its scenario) ──"
mutate() {  # $1=text $2=pattern $3=replacement ; prints the mutated text, returns 1 if nothing changed
  local out="${1//"$2"/$3}"
  [ "$out" != "$1" ] || return 1
  printf '%s' "$out"
}

# M1: delete the whole own-hold block. That IS the pre-fix code, so the bead that
# carries delivery:pending-restart must come out CLOSED — the bug, reproduced.
REGION_M1="$(printf '%s\n' "$REGION" | awk 'index($0,"SELFTEST-EXTRACT own-hold-block: BEGIN"){s=1} !s{print} index($0,"SELFTEST-EXTRACT own-hold-block: END"){s=0}')"
if [ "$REGION_M1" = "$REGION" ]; then
  bad "M1 did not apply (own-hold-block markers moved?) — the pre-fix reproduction is unproven"
else
  run_region pending none "$REGION_M1"
  if was_closed; then ok "M1 (own-hold block removed = the pre-fix code): a delivery:pending-restart bead is CLOSED — the bug reproduces, so the scenario above catches it"
  else bad "M1: even without the own-hold block the bead was not closed — the pending-restart scenario cannot catch the bug"; fi
  run_region partial none "$REGION_M1"
  was_closed && ok "M1: delivery:partial is likewise dropped on the pre-fix code" || bad "M1: delivery:partial scenario cannot catch the bug"
fi

# M2: re-add the 2>/dev/null that would swallow bd's failure message.
if FN_M2="$(mutate "$FN_OWN" '--json) || _rc=$?' '--json 2>/dev/null) || _rc=$?')"; then
  eval "$FN_M2"; run_region fail
  if grep -q 'Error fetching' "$ERR_F"; then bad "M2: re-adding 2>/dev/null did NOT hide bd's error — the stderr assertion cannot catch it"
  else ok "M2 (2>/dev/null re-added): bd's failure text is lost → the stderr assertion goes red on that code"; fi
  eval "$FN_OWN"
else bad "M2 did not apply (bd show line changed?) — the stderr assertion is unproven"; fi

# M3: drop the .id guard, so an error-shaped / foreign payload is trusted.
if FN_M3="$(mutate "$FN_OWN" 'select(type == "object" and .id == $id)' 'select(type == "object")')"; then
  eval "$FN_M3"
  run_region errjson0
  if was_closed; then ok "M3 (.id guard dropped): an exit-0 error object reads as 'no hold' and the bead CLOSES → the errjson0 scenario goes red"
  else bad "M3: dropping the .id guard changed nothing for errjson0 — the scenario cannot catch it"; fi
  run_region wrongid
  eq "M3: a FOREIGN bead's labels are attributed to this one (kind=held, wrongly)" "$OWN_HOLD_KIND" "held"
  eval "$FN_OWN"
else bad "M3 did not apply (jq select changed?) — the .id guard is unproven"; fi

# M4: honour delivery:partial unconditionally (drop the scope_covered:all exemption).
if FN_M4="$(mutate "$FN_OWN" 'and ($l | index("scope_covered:all") | not)' '')"; then
  eval "$FN_M4"; run_region partial_cov
  if was_closed; then bad "M4: dropping the exemption still closed the bead — the override scenario cannot catch it"
  else ok "M4 (exemption dropped): delivery:partial + scope_covered:all is HELD → the override scenario goes red"; fi
  eval "$FN_OWN"
else bad "M4 did not apply (exemption text changed?) — the override scenario is unproven"; fi

# M5: let a failed read fall through as 'none' (disable the unverified branch).
if FN_M5="$(mutate "$FN_OWN" 'if [ "$_rc" -ne 0 ] || [ "$_jrc" -ne 0 ]; then' 'if false; then')"; then
  eval "$FN_M5"; run_region fail
  if was_closed; then ok "M5 (failure reads as 'none'): a FAILED read CLOSES the bead → the failed-read scenario goes red"
  else bad "M5: disabling the unverified branch still held the bead — the failed-read scenario cannot catch it"; fi
  eval "$FN_OWN"
else bad "M5 did not apply (unverified condition changed?) — the failed-read scenario is unproven"; fi

# Restore and prove the harness left the real code in place.
run_region pending
! was_closed && ok "after the mutations the real code holds again (harness restored)" || bad "harness did not restore the real helper"

rm -rf "$WORK_DIR"
trap - EXIT

# ── 6. syntax ────────────────────────────────────────────────────────────────
# /bin/bash (3.2), NOT the PATH bash: Homebrew bash 5.x accepts constructs the
# system 3.2 rejects, and the dispatcher is launched by 3.2 in production.
echo "── 6. syntax (/bin/bash -n) ──"
if /bin/bash -n "$DISPATCHER"; then ok "dispatcher passes /bin/bash -n"; else bad "dispatcher /bin/bash -n FAILED"; fi
if /bin/bash -n "${BASH_SOURCE[0]}"; then ok "this selftest passes /bin/bash -n"; else bad "selftest /bin/bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
