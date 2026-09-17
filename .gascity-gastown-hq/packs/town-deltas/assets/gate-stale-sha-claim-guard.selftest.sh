#!/usr/bin/env bash
# gate-stale-sha-claim-guard.selftest.sh — ga-l7mvtw
#
# Covers Aceite 1 of ga-l7mvtw: "marker na fila com tip ja sha-failed ->
# nenhum revisor, fix-attempt inalterado."
#
# Exercises the "stale-sha-claim-guard" SELFTEST-EXTRACT block in
# quality-gate-dispatcher.sh: a top-level `if` (not a separately-callable
# function) that sits right after "Branch not yet merged... proceeding with
# review" and before the Step 4b-1 sibling guard, and `exit 0`s a marker
# whose branch tip already carries a gate-sha-failed(code) stamp — before
# ANY reviewer-spawning code (Step 4b-1 onward) is ever reached.
#
# Same extraction/sandbox technique as gate-author-branch-fallback.selftest.sh
# and gate-dispatcher-rig-resolve-noabort.selftest.sh: sed the block out
# between its BEGIN/END sentinels, splice it into a `bash -c` sandbox with
# every dispatcher-level function it calls (gate_bead_has_prior_sha_fail,
# set_gate_status, bd, gc, log/warn/err) stubbed, and assert on captured
# stdout + side-effect log files. gate_bead_has_prior_sha_fail's OWN
# correctness (SHA-membership matching) is already covered by
# gate-sha-fail-lock.selftest.sh — here it is stubbed to isolate exactly
# what this block does with its answer.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

BLOCK="$(extract_block "$DISPATCHER" "stale-sha-claim-guard")"
if [ -z "$BLOCK" ]; then
  echo "FATAL: could not extract stale-sha-claim-guard block from $DISPATCHER"
  exit 1
fi

# run_claim_guard <prior_fail: yes|no> <bead_id> <branch_sha> <branch>
#                 <marker_id> <author> <bd_log> <mail_log>
# Runs the extracted block in a sandbox where gate_bead_has_prior_sha_fail
# is stubbed to return $prior_fail verbatim (isolating this block's own
# branching from that helper's separately-tested SHA-matching logic).
run_claim_guard() {
  local prior_fail="$1" bead_id="$2" branch_sha="$3" branch="$4" marker_id="$5" author="$6" bd_log="$7" mail_log="$8"
  : > "$bd_log"
  : > "$mail_log"
  bash -c '
    set -euo pipefail
    PRIOR_FAIL="$1"; BEAD_ID="$2"; BRANCH_SHA="$3"; BRANCH="$4"; MARKER_ID="$5"; AUTHOR="$6"
    BD_LOG="$7"; MAIL_LOG="$8"
    GC_CITY="/fake/city"; BEAD_CITY="/fake/bead-city"; RIG="fake-rig"
    QG_LOG="$(mktemp -u)/qg.log"
    bd()   { echo "$*" >> "$BD_LOG"; return 0; }
    gc()   { echo "$*" >> "$MAIL_LOG"; return 0; }
    log()  { echo "LOG: $*" >&2; }
    warn() { echo "WARN: $*" >&2; }
    err()  { echo "ERR: $*" >&2; }
    set_gate_status() { echo "SET_GATE_STATUS $*" >> "$BD_LOG"; return 0; }
    gate_bead_has_prior_sha_fail() { printf "%s" "$PRIOR_FAIL"; }
    '"$BLOCK"'
    echo "REACHED_END"
  ' _ "$prior_fail" "$bead_id" "$branch_sha" "$branch" "$marker_id" "$author" "$bd_log" "$mail_log"
}

echo "── Claim-time stale-SHA guard ──"

# (1) THE wa-54f62 shape: prior FAIL already stamped on this exact sha →
# guard must fire: no REACHED_END (early exit, so no reviewer-spawn code
# below it in the real dispatcher is ever reached), marker superseded+
# closed, bead commented, fix-attempt never mentioned anywhere.
BD1="$(mktemp)"; MAIL1="$(mktemp)"
OUT1="$(run_claim_guard "yes" "wa-54f62" "4e30a7cbc" "crew/thies/wa-54f62" "ga-ccrjxk" "thies-wa" "$BD1" "$MAIL1" 2>&1)"
case "$OUT1" in
  *REACHED_END*) bad "(1) guard should have exited before REACHED_END, but reached it: $OUT1" ;;
  *)             ok  "(1) guard exits early (no REACHED_END) — no reviewer-spawn code below it runs" ;;
esac
if grep -q "SET_GATE_STATUS ga-ccrjxk superseded" "$BD1"; then
  ok "(1) marker transitioned to gate-status:superseded"
else
  bad "(1) marker was NOT transitioned to superseded: $(cat "$BD1")"
fi
if grep -q "close ga-ccrjxk" "$BD1" && grep -q "STALE-SHA" "$BD1"; then
  ok "(1) marker closed terminal with a STALE-SHA reason"
else
  bad "(1) marker was NOT closed with a STALE-SHA reason: $(cat "$BD1")"
fi
if grep -q "comment wa-54f62" "$BD1"; then
  ok "(1) source bead got an explanatory comment"
else
  bad "(1) source bead comment missing: $(cat "$BD1")"
fi
# NOTE: the human-readable comment/close text legitimately SAYS "fix-attempt
# untouched" — a bare grep for the word would false-positive on that prose.
# What must actually be absent is a LABEL WRITE bumping the counter.
if grep -qE '\b(label add|update)\b.*gate:fix-attempt:' "$BD1"; then
  bad "(1) bd log unexpectedly WRITES a gate:fix-attempt: label — this block must never touch the counter: $(cat "$BD1")"
else
  ok "(1) no gate:fix-attempt: label write in any bd call (counter genuinely untouched)"
fi
if grep -q "thies-wa" "$MAIL1"; then
  ok "(1) author mailed"
else
  bad "(1) author was NOT mailed: $(cat "$MAIL1")"
fi
rm -f "$BD1" "$MAIL1"

# (2) No prior FAIL on this sha → guard must NOT fire: falls through to
# REACHED_END, zero bd/mail calls (this block does nothing).
BD2="$(mktemp)"; MAIL2="$(mktemp)"
OUT2="$(run_claim_guard "no" "wa-54f62" "3c40bc245" "crew/thies/wa-54f62" "ga-jjnnno" "thies-wa" "$BD2" "$MAIL2" 2>&1)"
case "$OUT2" in
  *REACHED_END*) ok  "(2) no prior fail → falls through, REACHED_END reached" ;;
  *)             bad "(2) block unexpectedly short-circuited: $OUT2" ;;
esac
[ -s "$BD2" ]   && bad "(2) unexpected bd call(s) on the not-stale path: $(cat "$BD2")"   || ok "(2) zero bd calls (block is a true no-op when the sha is not stale)"
[ -s "$MAIL2" ] && bad "(2) unexpected mail on the not-stale path: $(cat "$MAIL2")"       || ok "(2) zero mail sent"
rm -f "$BD2" "$MAIL2"

# (3) prior_fail=yes but BEAD_ID empty → guard must NOT fire (nothing to
# check staleness against) — falls through.
BD3="$(mktemp)"; MAIL3="$(mktemp)"
OUT3="$(run_claim_guard "yes" "" "4e30a7cbc" "crew/thies/wa-54f62" "ga-ccrjxk" "thies-wa" "$BD3" "$MAIL3" 2>&1)"
case "$OUT3" in
  *REACHED_END*) ok  "(3) empty BEAD_ID → falls through even if prior_fail stub says yes" ;;
  *)             bad "(3) block fired with no BEAD_ID: $OUT3" ;;
esac
rm -f "$BD3" "$MAIL3"

# (4) prior_fail=yes but BRANCH_SHA empty → guard must NOT fire.
BD4="$(mktemp)"; MAIL4="$(mktemp)"
OUT4="$(run_claim_guard "yes" "wa-54f62" "" "crew/thies/wa-54f62" "ga-ccrjxk" "thies-wa" "$BD4" "$MAIL4" 2>&1)"
case "$OUT4" in
  *REACHED_END*) ok  "(4) empty BRANCH_SHA → falls through even if prior_fail stub says yes" ;;
  *)             bad "(4) block fired with no BRANCH_SHA: $OUT4" ;;
esac
rm -f "$BD4" "$MAIL4"

# (5) prior_fail=yes, AUTHOR empty → guard fires (marker/bead still handled)
# but sends no mail (nobody to mail).
BD5="$(mktemp)"; MAIL5="$(mktemp)"
OUT5="$(run_claim_guard "yes" "wa-54f62" "4e30a7cbc" "crew/thies/wa-54f62" "ga-ccrjxk" "" "$BD5" "$MAIL5" 2>&1)"
case "$OUT5" in
  *REACHED_END*) bad "(5) guard should have exited early even with no author: $OUT5" ;;
  *)             ok  "(5) guard still exits early with no author" ;;
esac
if grep -q "SET_GATE_STATUS ga-ccrjxk superseded" "$BD5"; then
  ok "(5) marker still transitioned to superseded with no author known"
else
  bad "(5) marker handling skipped when author is empty: $(cat "$BD5")"
fi
[ -s "$MAIL5" ] && bad "(5) mail sent with no author to send it to: $(cat "$MAIL5")" || ok "(5) no mail sent (no author to notify)"
rm -f "$BD5" "$MAIL5"

echo ""
echo "── Mutation test: guard neutralized → must go RED ──"
MUT="$(mktemp)"
cp "$DISPATCHER" "$MUT"
python3 - "$MUT" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
begin = "# SELFTEST-EXTRACT stale-sha-claim-guard: BEGIN"
end = "# SELFTEST-EXTRACT stale-sha-claim-guard: END"
i, j = text.index(begin), text.index(end)
block = text[i:j]
# Minimal, syntactically-safe mutation: the call sits inside
# `[ "$(gate_bead_has_prior_sha_fail ...)" = "yes" ]; then` on one physical
# line — an inline `#` comment there eats the rest of the line (closing
# `)"`, `= "yes" ]; then`), breaking the shell grammar outright rather than
# just changing behavior. Retarget the comparison literal instead: the stub
# below only ever returns "yes" or "no", so comparing against a value it
# can never produce makes the guard permanently not-fire without touching
# any quoting/paren structure.
target = '")" = "yes" ]; then'
mutated = block.replace(target, '")" = "ga-l7mvtw-selftest-neutralized" ]; then', 1)
if mutated == block:
    print("MUTATION_NOT_APPLIED", file=sys.stderr)
    sys.exit(1)
text = text[:i] + mutated + text[j:]
open(path, 'w').write(text)
PYEOF
if [ $? -ne 0 ]; then
  bad "mutation could not be applied — anchor text not found (block text drifted?)"
else
  MUT_BLOCK="$(extract_block "$MUT" "stale-sha-claim-guard")"
  BD6="$(mktemp)"; MAIL6="$(mktemp)"
  : > "$BD6"; : > "$MAIL6"
  OUT6="$(bash -c '
    set -euo pipefail
    PRIOR_FAIL="$1"; BEAD_ID="$2"; BRANCH_SHA="$3"; BRANCH="$4"; MARKER_ID="$5"; AUTHOR="$6"
    BD_LOG="$7"; MAIL_LOG="$8"
    GC_CITY="/fake/city"; BEAD_CITY="/fake/bead-city"; RIG="fake-rig"
    QG_LOG="$(mktemp -u)/qg.log"
    bd()   { echo "$*" >> "$BD_LOG"; return 0; }
    gc()   { echo "$*" >> "$MAIL_LOG"; return 0; }
    log()  { echo "LOG: $*" >&2; }
    warn() { echo "WARN: $*" >&2; }
    err()  { echo "ERR: $*" >&2; }
    set_gate_status() { echo "SET_GATE_STATUS $*" >> "$BD_LOG"; return 0; }
    gate_bead_has_prior_sha_fail() { printf "%s" "$PRIOR_FAIL"; }
    '"$MUT_BLOCK"'
    echo "REACHED_END"
  ' _ "yes" "wa-54f62" "4e30a7cbc" "crew/thies/wa-54f62" "ga-ccrjxk" "thies-wa" "$BD6" "$MAIL6" 2>&1)"
  # Same inputs as test (1) above (prior_fail=yes — the guard-firing case),
  # against the MUTATED block: if the mutation is real, the comparison can
  # never match "yes" any more, so the guard fails to fire and REACHED_END
  # DOES appear here — the opposite of test (1)'s assertion against the
  # unmutated block. That flip is what proves (1) is actually exercising
  # this code, not vacuously passing regardless of it.
  case "$OUT6" in
    *REACHED_END*) ok  "mutation flips the outcome (same inputs as test (1), guard neutralized → REACHED_END now appears) — test (1) is NOT vacuous" ;;
    *)             bad "mutation did not change behavior on test (1)'s own inputs — test (1) may be vacuous: $OUT6" ;;
  esac
  rm -f "$BD6" "$MAIL6"
fi
rm -f "$MUT"

echo ""
echo "== gate-stale-sha-claim-guard: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
