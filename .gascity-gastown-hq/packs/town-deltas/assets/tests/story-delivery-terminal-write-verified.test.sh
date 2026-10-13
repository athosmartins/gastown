#!/usr/bin/env bash
# story-delivery-terminal-write-verified.test.sh — regression test for ga-njpnhv:
# story-delivery's Step 8 (the terminal) logged "story:done set on <id>" and reported
# PASS without ever reading the write back. Its writes were `bd ... -q 2>/dev/null || true`,
# so when bd's writes failed for a few seconds (13/10 ga-mzw9dt.3, 12/10 ga-dzzqvw) the label
# never landed, the bead stayed story:approved + delivery:running, the log said "set", and
# a human closed it by hand. bd's stderr -- the only evidence of why -- went to /dev/null.
#
# Extracts the REAL verified-writes helpers, the REAL Step 8 block and the REAL Step 9 block
# from story-delivery.sh (no duplication) and drives them with a fault-injecting, stateful
# stub bd (what it is told to write shows up in the next `show`), under the script's own
# `set -euo pipefail`:
#   S1 healthy        every write lands -> "story:done set on" is logged, the bead ends
#                     done+closed with the lock released, nothing is reported as FAIL (a
#                     `label remove` of an already-absent label exits 1 in this stub and is
#                     still the state asked for -- the read-back wins over bd's exit code).
#   S2 outage         every write exits 1 -> the log does NOT say "set", it SAYS what failed
#                     with bd's own stderr, delivery:running is KEPT as the lock, the
#                     COMPLETE comment/push become "NOT marked done", and a total outage costs
#                     one retry budget (3 attempts for story:done, 1 for each write after it).
#   S3 silent no-op   bd exits 0 and prints success but writes nothing (the "no-op calado"
#                     family) -> caught by the read-back, never "set".
#   S4 transient      the first two writes fail, then bd recovers -> retried, lands, "set".
#   S5 unreadable     writes exit 0 but the bead cannot be read back -> NOT claimed as set
#                     (three states: landed / did not land / could not tell).
#   S6 close only     only `close` fails -> story:done IS set, the close failure is reported,
#                     and the result stays PASS (merged-bead-janitor backstops the close).
#   S7 Step 9         story:done not landed -> result PASS_TERMINAL_WRITE_FAIL in the jsonl and
#                     in the "sweep complete" line (the name carries FAIL: gate-health-monitor's
#                     [DELIVERY-FAIL] alarm matches "FAIL" in result); landed -> PASS, as before.
#   S9 no capture     mktemp fails -> the FAIL line says stderr was not captured, never "bd said
#                     nothing" (a missing read is not an empty one).
#   S8 text guard     no bare `label ... 2>/dev/null` / `close ... 2>/dev/null` write is left in
#                     Step 8.
# Set DELIVERY_SH to run the same scenarios against another copy of the script (e.g. the
# pre-fix revision, to see them fail).
#
# set -u only at file level (no pipefail -- see story-delivery-staleness.test.sh, ga-uel7sb:
# `X | grep` under load can false-FAIL on SIGPIPE). Assertions use here-strings. The extracted
# code runs WITH `set -euo pipefail`, as in production.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="${DELIVERY_SH:-$SCRIPT_DIR/../story-delivery.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }
has() { [[ "$1" == *"$2"* ]]; }

HELPERS="$(sed -n '/^# BEGIN verified-writes/,/^# END verified-writes/p' "$DELIVERY")"
BLOCK="$(sed -n '/# ── Step 8: Mark story:done/,/# ── Step 9: Log to story-delivery.jsonl/p' "$DELIVERY" | sed '$d')"
STEP9="$(sed -n '/^# ── Step 9: Log to story-delivery.jsonl/,/^done < <(echo/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 8 block"; exit 1; }
[ -n "$STEP9" ] || { echo "FAIL: could not extract Step 9 block"; exit 1; }
[ -n "$HELPERS" ] && ok "H0 the script carries the verified-write helpers" \
                  || nok "H0 the script has NO verified-write helpers (BEGIN/END verified-writes markers)"

export DELIVERY_WRITE_BACKOFF_S=0
T=""

# The stub. bd -C <store> <sub> ...   Faults come from the environment of the run:
#   BD_FAIL="all"|"close"|...   those subcommands exit 1 with a stderr message
#   BD_NOOP=1                   writes exit 0, print success, change nothing
#   BD_SHOW_FAIL=1              `show` fails
#   BD_TRANSIENT=N              the first N writes fail, then bd recovers
bd() {
  local sub="$3"
  if [ "$sub" = "show" ]; then
    if [ "${BD_SHOW_FAIL:-0}" = "1" ]; then echo "dolt: connection refused" >&2; return 1; fi
    printf '{"id":"ga-test","status":"%s","labels":[%s]}\n' "$(cat "$T/status")" \
      "$(sed 's/.*/"&"/' "$T/labels" | paste -sd, -)"
    return 0
  fi
  case "$sub" in
    label)   echo "label $4 $6" >> "$T/calls.log" ;;
    close)   echo "close" >> "$T/calls.log" ;;
    comment) echo "comment" >> "$T/calls.log"; printf '%s\n---\n' "$5" >> "$T/comments.log" ;;
    *)       echo "$sub" >> "$T/calls.log" ;;
  esac
  local left; left="$(cat "$T/transient_left")"
  if [ "$left" -gt 0 ]; then
    echo $((left - 1)) > "$T/transient_left"; echo "dolt: connection was closed" >&2; return 1
  fi
  case " ${BD_FAIL:-} " in *" $sub "*|*" all "*) echo "dolt: connection was closed" >&2; return 1 ;; esac
  if [ "${BD_NOOP:-0}" = "1" ]; then echo "✓ ok (nothing was written)"; return 0; fi
  case "$sub" in
    label)
      if [ "$4" = "add" ]; then
        echo "$6" >> "$T/labels"; echo "✓ Added label '$6' to $5"
      elif grep -qxF -- "$6" "$T/labels"; then
        grep -vxF -- "$6" "$T/labels" > "$T/labels.n"; mv "$T/labels.n" "$T/labels"; echo "✓ Removed label '$6' from $5"
      else
        echo "label '$6' not found on $5" >&2; return 1
      fi ;;
    close)   echo closed > "$T/status"; echo "$6" > "$T/close_reason" ;;
  esac
  return 0
}
notify() { echo "$*" >> "$T/notify.log"; }
log()  { echo "LOG: $*"; }
warn() { echo "WARN: $*"; }
err()  { echo "ERR: $*"; }
refino_criteria_status_line() { echo "criteria: n/a"; }

# run_terminal  -- one story through Step 8 with the faults in the environment; sets
# OUT LABELS STATUS CALLS COMMENTS NOTIFY VARS RC
run_terminal() {
  T="$(mktemp -d)"
  printf 'delivery:running\nstory:approved\ngate:passed\n' > "$T/labels"
  echo open > "$T/status"; echo "${BD_TRANSIENT:-0}" > "$T/transient_left"
  : > "$T/calls.log"; : > "$T/comments.log"; : > "$T/notify.log"
  (
    set -euo pipefail
    GC_CITY="$T/city"; DELIVERY_START=1; DRY_RUN=0; STORY_ID="ga-test"; STORY_STORE="$T/store"
    STORY_LABELS=""; STORY_TITLE="Test story"; RIG="gascity"; DEPLOY_CMD="git pull"
    MISSING_META=""; NO_HARNESS="0"; STORY_TEST_MISSING="0"; PROD_TEST_SCRIPT="/tmp/fake-prod-test.sh"
    REFRESH_PROOF="verified"
    eval "$HELPERS"
    for _t in _once; do eval "$BLOCK"; done
    echo "TWF=[${TERMINAL_WRITE_FAIL-UNSET}] DONE=${STORY_DONE_LANDED-UNSET}" > "$T/vars"
  ) > "$T/out.log" 2>&1
  RC=$?
  OUT="$(cat "$T/out.log")"; LABELS="$(cat "$T/labels")"; STATUS="$(cat "$T/status")"
  CALLS="$(cat "$T/calls.log")"; COMMENTS="$(cat "$T/comments.log")"; NOTIFY="$(cat "$T/notify.log")"
  VARS="$(cat "$T/vars" 2>/dev/null || echo "NO-VARS(the block aborted)")"
  CLOSE_REASON="$(cat "$T/close_reason" 2>/dev/null || true)"
  rm -rf "$T"
}
count() { local n; n="$(grep -c -x -F -- "$2" <<<"$1")"; echo "${n:-0}"; }

# ── S1 healthy ──
echo "(S1) healthy: every write lands"
unset BD_FAIL BD_NOOP BD_SHOW_FAIL BD_TRANSIENT
run_terminal
[ "$RC" = "0" ] && ok "S1 the block ran to the end under set -euo pipefail" || nok "S1 rc=$RC" "$OUT"
has "$OUT" "LOG: story:done set on ga-test" && ok "S1 'story:done set on' is logged" || nok "S1 no 'set on' line" "$OUT"
has "$LABELS" "story:done" && ! has "$LABELS" "delivery:running" && ! has "$LABELS" "story:approved" \
  && ok "S1 bead ends story:done, lock released, story:approved gone" || nok "S1 labels" "$LABELS"
[ "$STATUS" = "closed" ] && ok "S1 bead closed" || nok "S1 status=$STATUS"
! has "$OUT" "ERR:" && ! has "$OUT" "WARN:" && ok "S1 nothing reported as FAIL/WARN (removing an already-absent label is not a failure)" || nok "S1 spurious FAIL/WARN" "$OUT"
has "$COMMENTS" "Delivery COMPLETE. story:done (delivery:tested)." && ok "S1 the COMPLETE comment is posted" || nok "S1 comment" "$COMMENTS"
has "$VARS" "TWF=[] DONE=1" && ok "S1 no terminal write failed, story:done landed" || nok "S1 vars" "$VARS"
has "$NOTIFY" "Story DONE" && ! has "$NOTIFY" "NOT marked done" && ok "S1 the push says DONE" || nok "S1 notify" "$NOTIFY"

# ── S2 outage ──
echo "(S2) outage: every write exits 1"
BD_FAIL="all"; unset BD_NOOP BD_SHOW_FAIL BD_TRANSIENT
run_terminal
[ "$RC" = "0" ] && ok "S2 the block ran to the end (a failed write does not abort the sweep)" || nok "S2 rc=$RC" "$OUT"
! has "$OUT" "story:done set on" && ok "S2 the log does NOT claim 'story:done set on'" || nok "S2 FALSE CLAIM: 'story:done set on' logged though no write landed" "$OUT"
has "$OUT" "ERR: FAIL: bd label add story:done on ga-test did NOT land" && ok "S2 the failed story:done write is SAID (FAIL line)" || nok "S2 no FAIL line for story:done" "$OUT"
has "$OUT" "connection was closed" && ok "S2 bd's own stderr is in the log (it used to go to /dev/null)" || nok "S2 bd stderr not surfaced" "$OUT"
has "$LABELS" "delivery:running" && ok "S2 delivery:running is KEPT as the lock when story:done did not land" || nok "S2 lock released though story:done is not on the bead" "$LABELS"
has "$VARS" "add:story:done" && has "$VARS" "DONE=0" && ok "S2 TERMINAL_WRITE_FAIL names story:done, DONE=0" || nok "S2 vars" "$VARS"
has "$VARS" "remove:story:approved" && ok "S2 the story:approved removal that did not land is named" || nok "S2 vars (approved)" "$VARS"
! has "$VARS" "remove:story:in-flight" && ok "S2 a removal of a label that was never there is not a failure" || nok "S2 in-flight reported" "$VARS"
[ "$(count "$CALLS" "label add story:done")" = "3" ] && ok "S2 story:done got its 3 attempts" || nok "S2 story:done attempts" "$CALLS"
[ "$(count "$CALLS" "label remove story:approved")" = "1" ] && ok "S2 after one write ran out of retries the rest make ONE attempt (bounded outage cost)" || nok "S2 latch: story:approved attempts" "$CALLS"
has "$COMMENTS" "did NOT land (ga-njpnhv)" && ! has "$COMMENTS" "Delivery COMPLETE" && ok "S2 the comment does not say COMPLETE" || nok "S2 comment claims COMPLETE" "$COMMENTS"
has "$NOTIFY" "NOT marked done" && ! has "$NOTIFY" "Story DONE" && ok "S2 the push says NOT marked done" || nok "S2 notify" "$NOTIFY"

# ── S3 silent no-op ──
echo "(S3) silent no-op: bd exits 0 and writes nothing"
BD_NOOP=1; unset BD_FAIL BD_SHOW_FAIL BD_TRANSIENT
run_terminal
! has "$OUT" "story:done set on" && ok "S3 not claimed: bd's exit 0 is not proof" || nok "S3 FALSE CLAIM on a silent no-op" "$OUT"
has "$OUT" "read-back=not-as-asked" && ok "S3 the FAIL line says the read-back disagreed" || nok "S3 no read-back diagnosis" "$OUT"
has "$VARS" "add:story:done" && ok "S3 story:done counted as not landed" || nok "S3 vars" "$VARS"

# ── S4 transient ──
echo "(S4) transient: two failed writes, then bd recovers"
BD_TRANSIENT=2; unset BD_FAIL BD_NOOP BD_SHOW_FAIL
run_terminal
has "$OUT" "LOG: story:done set on ga-test" && ok "S4 retried, landed, and only THEN claimed" || nok "S4 not set after retries" "$OUT"
[ "$(count "$CALLS" "label add story:done")" = "3" ] && ok "S4 it took 3 attempts" || nok "S4 attempts" "$CALLS"
has "$OUT" "WARN: bd label add story:done on ga-test: attempt 1/3 did not land" && ok "S4 each failed attempt is logged with bd's stderr" || nok "S4 retry not logged" "$OUT"
has "$VARS" "TWF=[] DONE=1" && ok "S4 nothing left failed" || nok "S4 vars" "$VARS"
has "$LABELS" "story:done" && ! has "$LABELS" "delivery:running" && ok "S4 bead ends done, lock released" || nok "S4 labels" "$LABELS"

# ── S5 unreadable ──
echo "(S5) unreadable: bd exits 0 but the bead cannot be read back"
BD_SHOW_FAIL=1; unset BD_FAIL BD_NOOP BD_TRANSIENT
run_terminal
! has "$OUT" "story:done set on" && ok "S5 unconfirmed is not 'set'" || nok "S5 FALSE CLAIM without a read-back" "$OUT"
has "$OUT" "read-back=unreadable" && ok "S5 the FAIL line says it could not tell" || nok "S5 no 'unreadable'" "$OUT"
[ "$RC" = "0" ] && ok "S5 the block still ran to the end" || nok "S5 rc=$RC" "$OUT"

# ── S6 close only ──
echo "(S6) only close fails"
BD_FAIL="close"; unset BD_NOOP BD_SHOW_FAIL BD_TRANSIENT
run_terminal
has "$OUT" "LOG: story:done set on ga-test" && ok "S6 story:done landed and is claimed" || nok "S6 story:done" "$OUT"
has "$OUT" "WARN: Could not close story ga-test" && ok "S6 the close failure is reported" || nok "S6 close failure silent" "$OUT"
has "$OUT" "ERR: FAIL: bd close ga-test did NOT land" && ok "S6 with bd's FAIL line" || nok "S6 no FAIL line for close" "$OUT"
has "$VARS" "TWF=[ close] DONE=1" && ok "S6 only the close is named" || nok "S6 vars" "$VARS"
[ "$(count "$CALLS" "close")" = "3" ] && ok "S6 close was retried (3 attempts)" || nok "S6 close attempts" "$CALLS"

# ── S7 Step 9 ──
echo "(S7) Step 9: the result follows what landed"
run_step9() {  # run_step9 <STORY_DONE_LANDED> <TERMINAL_WRITE_FAIL>
  T="$(mktemp -d)"
  S9OUT="$( set -euo pipefail
    DRY_RUN=0; NO_HARNESS=0; STORY_ID="ga-test"; STORY_TITLE="t"; RIG="gascity"; DEPLOY_CMD="x"
    PROD_TEST_SCRIPT="y"; ELAPSED=5; DELIVERY_LOG="$T/d.jsonl"; STORY_DONE_LANDED="$1"; TERMINAL_WRITE_FAIL="$2"
    eval "$STEP9" 2>&1 )"
  S9JSON="$(cat "$T/d.jsonl" 2>/dev/null || true)"
  rm -rf "$T"
}
run_step9 0 " add:story:done"
[ "$(jq -r .result <<<"$S9JSON")" = "PASS_TERMINAL_WRITE_FAIL" ] && ok "S7 jsonl result is PASS_TERMINAL_WRITE_FAIL when story:done did not land" || nok "S7 jsonl result" "$S9JSON"
[[ "$(jq -r .result <<<"$S9JSON")" == *FAIL* ]] && ok "S7 the result contains FAIL (gate-health-monitor's [DELIVERY-FAIL] matches it as is)" || nok "S7 monitor would not alarm" "$S9JSON"
[ "$(jq -r .story <<<"$S9JSON")" = "ga-test" ] && ok "S7 the record carries 'story' (the monitor prints it in the alert)" || nok "S7 story field" "$S9JSON"
[ "$(jq -r .terminal_failed <<<"$S9JSON")" = "add:story:done" ] && ok "S7 the record names what did not land" || nok "S7 terminal_failed" "$S9JSON"
has "$S9OUT" "result=PASS_TERMINAL_WRITE_FAIL" && ok "S7 the 'sweep complete' line does not say PASS" || nok "S7 sweep-complete line" "$S9OUT"
run_step9 1 ""
[ "$(jq -r .result <<<"$S9JSON")" = "PASS" ] && has "$S9OUT" "result=PASS elapsed" && ok "S7 (control) landed -> PASS, unchanged" || nok "S7 control" "$S9JSON / $S9OUT"

# ── S9 no capture file ──
echo "(S9) mktemp fails: stderr is NOT captured, and the log must not say bd said nothing"
BD_FAIL="all"; unset BD_NOOP BD_SHOW_FAIL BD_TRANSIENT
OLD_TMPDIR="${TMPDIR:-}"; export TMPDIR="/nonexistent-dir-for-ga-njpnhv"
run_terminal
if [ -n "$OLD_TMPDIR" ]; then export TMPDIR="$OLD_TMPDIR"; else unset TMPDIR; fi
has "$OUT" "<stderr not captured: mktemp failed>" && ! has "$OUT" "<nothing on stderr>" \
  && ok "S9 'could not capture' is not printed as 'bd said nothing'" || nok "S9 stderr-not-captured read as silence" "$OUT"
! has "$OUT" "story:done set on" && ok "S9 the claim still follows the read-back" || nok "S9 false claim" "$OUT"

# ── S8 text guard ──
echo "(S8) no bare swallowed label/close write left in Step 8"
BARE="$(grep -n -E 'bd -C "\$STORY_STORE" (label (add|remove)|close|comment) .*2>/dev/null' <<<"$BLOCK" || true)"
[ -z "$BARE" ] && ok "S8 every Step 8 label/close/comment write goes through the verified helpers" || nok "S8 bare writes remain in Step 8" "$BARE"

echo ""
echo "story-delivery terminal-write-verified tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
