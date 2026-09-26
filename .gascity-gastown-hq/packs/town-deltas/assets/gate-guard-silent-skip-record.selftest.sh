#!/usr/bin/env bash
# gate-guard-silent-skip-record.selftest.sh — Prove the ga-8yinlg fix: the two
# submission-time checks in quality-gate-guard.sh that only run when RIG_PATH,
# BEAD_ID and BRANCH are all non-empty (branch-content-coherence, ga-pj5va; the
# base-commit A/B check, ga-rstae) no longer skip in silence.
#
# THE DEFECT: with any of those inputs empty the blocks did nothing, logged
# nothing and set no label — indistinguishable from "the check never ran", so
# "how many submissions went in unverified" could not be counted. RIG_PATH is
# the one that goes empty in practice (rig list failed, unknown rig, or the
# resolved path is not a directory).
#
# WHY A NEW FILE, NOT MORE CASES IN THE SIBLINGS: gate-guard-submission-time-
# coherence.selftest.sh and gate-guard-ab-base-test-check.selftest.sh both MIRROR
# the block's git plumbing (their own comments say so) instead of running the
# block, and neither ever ran it with an empty input — which is why this went
# unseen. This file extracts both blocks LIVE from the guard and runs them under
# the guard's own `set -euo pipefail`, so it fails when the block goes silent.
#
# What it pins:
#   1. coherence block: every outcome writes ONE COHERENCE-CHECK record — inputs
#      empty, git failing inside the measurement, and the measured yes / no / skip
#      paths. The unmeasured ones are fail-OPEN (rc 0, no refusal) and say
#      verdict=nao-consegui-medir with the empty input shown as <EMPTY>; a
#      measured zero (unique_commits=0) stays distinguishable from a count that
#      never arrived (unique_commits=<EMPTY>). A real refusal still refuses, and
#      the record is written BEFORE the exit.
#   2. A/B block: the unmeasured path writes an AB-SKIP line and NOTHING else —
#      no label (bd is never called), and a line the apuracao's own regex does not
#      match — so it cannot enter either arm's measured population; an unknown
#      arm is logged <UNKNOWN>, never 'A' (gate_ab_arm_for_bead("") defaults to
#      'A'). The measured paths (arm A, arm B) are unchanged.
#
# Runs under PATH bash AND /bin/bash 3.2 (the interpreter launchd uses) — keep it
# 3.2-clean. Exit 0 iff every assertion holds.
# Negative control (run by hand when editing this): point GATE_GUARD_UNDER_TEST at
# a copy of the guard with the COHERENCE-CHECK log line and the AB-SKIP else
# branch removed — the record assertions below must FAIL.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${GATE_GUARD_UNDER_TEST:-$SELF_DIR/quality-gate-guard.sh}"
APURACAO="$SELF_DIR/../../../scripts/gate-ab-apuracao.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — got '$2', want '$3'"; }
# has <label> <haystack-file> <fixed-string>: the string must be in the file.
has() { grep -F -- "$3" "$2" >/dev/null 2>&1 && ok "$1" || bad "$1 — '$3' not in: $(tr '\n' '|' < "$2" | cut -c1-260)"; }
lacks() { grep -F -- "$3" "$2" >/dev/null 2>&1 && bad "$1 — '$3' unexpectedly in: $(tr '\n' '|' < "$2" | cut -c1-260)" || ok "$1"; }

[ -f "$GUARD" ] || { echo "FATAL: missing $GUARD"; exit 1; }

# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # sourcing the guard leaks its `set -e` into this shell (same as the siblings)

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/gate-8yinlg-selftest.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
LOGF="$TMPD/log.txt"
CALLS="$TMPD/calls.txt"

# Stubs for what the live blocks call. Defined AFTER sourcing: the guard's own
# log/err are defined past its GATE_GUARD_LIB_ONLY cutoff, so lib-only sourcing
# never defines them.
log()  { echo "LOG $*" >> "$LOGF"; }
err()  { echo "ERR $*" >> "$LOGF"; }
set_gate_status() { echo "STATUS $*" >> "$CALLS"; }
bd() { echo "BD $*" >> "$CALLS"; return 0; }

# ── extract the two live blocks ──────────────────────────────────────────────
COH_FILE="$TMPD/coh-block.sh"
ABT_FILE="$TMPD/abt-block.sh"
sed -n '/# SELFTEST-EXTRACT coherence-check: BEGIN/,/# SELFTEST-EXTRACT coherence-check: END/p' "$GUARD" > "$COH_FILE"
# The A/B block has no sentinels: its siblings extract it from its header up to the
# first column-0 `fi`, which is the same range used here.
awk '/Step 5b-pre2 \(ga-rstae\)/,/^fi$/' "$GUARD" > "$ABT_FILE"

echo "── 0. the live blocks can be extracted ──"
[ -s "$COH_FILE" ] && ok "coherence-check block found between its SELFTEST-EXTRACT sentinels ($(wc -l < "$COH_FILE") lines)" \
  || { bad "coherence-check SELFTEST-EXTRACT sentinels not found in $GUARD"; }
[ -s "$ABT_FILE" ] && ok "A/B block found by its header ($(wc -l < "$ABT_FILE") lines)" \
  || { bad "A/B block (header 'Step 5b-pre2 (ga-rstae)') not found in $GUARD"; }
if [ ! -s "$COH_FILE" ] || [ ! -s "$ABT_FILE" ]; then
  echo "  PASS=$PASS  FAIL=$FAIL"; echo "  RESULT: FAIL"; exit 1
fi

# ── a real repo with an origin, for the measured paths ───────────────────────
GITC="git -c init.defaultBranch=main -c user.email=t@gascity.local -c user.name=Test -c commit.gpgsign=false"
ORIGIN="$TMPD/origin.git"
SEED="$TMPD/seed"
RIG_OK="$TMPD/rig-clone"
$GITC init -q --bare "$ORIGIN"
$GITC clone -q "$ORIGIN" "$SEED" 2>/dev/null
( cd "$SEED" || exit 1
  echo base > README && $GITC add README && $GITC commit -q -m "chore: base"
  $GITC push -q origin HEAD:refs/heads/main
  $GITC checkout -q -b feat/cites
  echo a > a.txt && $GITC add a.txt && $GITC commit -q -m "feat(ga-zz1): a change that cites its bead"
  $GITC push -q origin feat/cites
  $GITC checkout -q main
  $GITC checkout -q -b feat/nocite
  echo b > b.txt && $GITC add b.txt && $GITC commit -q -m "feat: a change that cites nothing"
  $GITC push -q origin feat/nocite
  $GITC push -q origin main:refs/heads/feat/empty      # no unique commits vs main
) >/dev/null 2>&1
$GITC clone -q "$ORIGIN" "$RIG_OK" 2>/dev/null
NOT_A_REPO="$TMPD/plain-dir"; mkdir -p "$NOT_A_REPO"

# run_block <block-file> <RIG_PATH> <BEAD_ID> <BRANCH>  → rc; log/calls in $LOGF/$CALLS.
# A subshell under the guard's real `set -euo pipefail`; `exit 1` in a refusal
# ends only the subshell.
run_block() {
  : > "$LOGF"; : > "$CALLS"
  ( set -euo pipefail
    RIG_PATH="$2"; BEAD_ID="$3"; BRANCH="$4"; MARKER_ID="m-selftest"; GC_CITY="$TMPD/no-city"
    . "$1" ) >/dev/null 2>&1
  return $?
}

# ── 1. coherence block ───────────────────────────────────────────────────────
echo "── 1. coherence block: every outcome leaves one COHERENCE-CHECK record ──"

run_block "$COH_FILE" "" ga-zz1 feat/cites; RC=$?
eq "RIG_PATH empty: fail-open (rc 0, no refusal)" "$RC" "0"
has "RIG_PATH empty: a COHERENCE-CHECK record exists" "$LOGF" "LOG COHERENCE-CHECK bead=ga-zz1 "
has "RIG_PATH empty: verdict is the third state, not a guess" "$LOGF" "verdict=nao-consegui-medir"
has "RIG_PATH empty: the empty input is NAMED" "$LOGF" "rig_path=<EMPTY>"
has "RIG_PATH empty: the count never arrived" "$LOGF" "unique_commits=<EMPTY>"
eq "RIG_PATH empty: nothing was refused or labelled" "$(wc -c < "$CALLS" | tr -d ' ')" "0"

run_block "$COH_FILE" "$RIG_OK" "" feat/cites; RC=$?
eq "BEAD_ID empty: fail-open (rc 0)" "$RC" "0"
has "BEAD_ID empty: named in the record" "$LOGF" "bead=<EMPTY>"
has "BEAD_ID empty: verdict nao-consegui-medir" "$LOGF" "verdict=nao-consegui-medir"

run_block "$COH_FILE" "$RIG_OK" ga-zz1 ""; RC=$?
eq "BRANCH empty: fail-open (rc 0)" "$RC" "0"
has "BRANCH empty: named in the record" "$LOGF" "branch=<EMPTY>"
has "BRANCH empty: verdict nao-consegui-medir" "$LOGF" "verdict=nao-consegui-medir"

# The class, not just the cited instance: a skip that happens INSIDE the
# measurement (git cannot answer) must record itself too.
run_block "$COH_FILE" "$NOT_A_REPO" ga-zz1 feat/cites; RC=$?
eq "inputs set but git cannot answer (not a repo): fail-open (rc 0)" "$RC" "0"
has "not a repo: record exists with verdict nao-consegui-medir" "$LOGF" "verdict=nao-consegui-medir"
has "not a repo: the count never arrived" "$LOGF" "unique_commits=<EMPTY>"

run_block "$COH_FILE" "$RIG_OK" ga-zz1 feat/ghost; RC=$?
eq "branch missing on origin: fail-open (rc 0)" "$RC" "0"
has "branch missing on origin: record exists, verdict nao-consegui-medir" "$LOGF" "verdict=nao-consegui-medir"

# Measured paths keep their meaning.
run_block "$COH_FILE" "$RIG_OK" ga-zz1 feat/cites; RC=$?
eq "measured, branch cites its bead: rc 0" "$RC" "0"
has "measured yes: recorded with the real count" "$LOGF" "verdict=yes"
has "measured yes: unique_commits=1" "$LOGF" "unique_commits=1"
eq "measured yes: no refusal" "$(wc -c < "$CALLS" | tr -d ' ')" "0"

run_block "$COH_FILE" "$RIG_OK" ga-zz1 feat/nocite; RC=$?
eq "measured, branch does not cite its bead: still REFUSES (rc 1)" "$RC" "1"
has "refusal: gate-status:error is set" "$CALLS" "STATUS m-selftest error"
has "refusal: the record was written BEFORE the exit" "$LOGF" "LOG COHERENCE-CHECK bead=ga-zz1 verdict=no "

run_block "$COH_FILE" "$RIG_OK" ga-zz1 feat/empty; RC=$?
eq "measured, zero unique commits: rc 0" "$RC" "0"
has "measured zero is verdict=skip" "$LOGF" "verdict=skip"
has "measured zero is unique_commits=0 — NOT <EMPTY> (told apart from a count that never arrived)" "$LOGF" "unique_commits=0"

# ── 2. A/B block ─────────────────────────────────────────────────────────────
echo "── 2. A/B block: an unmeasured submission is recorded and NOTHING else ──"

# Pick one bead id per arm with the real function (no pinned hash values).
ID_A=""; ID_B=""
for _c in ga-rstae ga-kgja ga-pj5va ga-sdkqs ga-qubtx ga-5crlw wa-uthi ga-art5 ga-31ac; do
  _arm=$(gate_ab_arm_for_bead "$_c")
  [ "$_arm" = "A" ] && [ -z "$ID_A" ] && ID_A="$_c"
  [ "$_arm" = "B" ] && [ -z "$ID_B" ] && ID_B="$_c"
done
[ -n "$ID_A" ] && [ -n "$ID_B" ] && ok "found one bead id per arm (A=$ID_A B=$ID_B)" \
  || { bad "could not find a bead id for each arm (A='$ID_A' B='$ID_B')"; ID_A="${ID_A:-ga-rstae}"; ID_B="${ID_B:-ga-pj5va}"; }

for _pair in "A:$ID_A" "B:$ID_B"; do
  _arm="${_pair%%:*}"; _id="${_pair#*:}"
  run_block "$ABT_FILE" "" "$_id" feat/cites; RC=$?
  eq "arm $_arm, RIG_PATH empty: fail-open (rc 0)" "$RC" "0"
  has "arm $_arm, RIG_PATH empty: AB-SKIP record with the bead's real arm" "$LOGF" "LOG AB-SKIP bead=$_id arm=$_arm "
  has "arm $_arm, RIG_PATH empty: the empty input is NAMED" "$LOGF" "rig_path=<EMPTY>"
  has "arm $_arm, RIG_PATH empty: reason is stated" "$LOGF" "reason=inputs-unresolved"
  eq "arm $_arm, RIG_PATH empty: bd never called — no label, so no measured population touched" \
    "$(wc -c < "$CALLS" | tr -d ' ')" "0"
  lacks "arm $_arm, RIG_PATH empty: no AB-BASE-TEST line (the apuracao's verdict series is untouched)" "$LOGF" "AB-BASE-TEST"
  lacks "arm $_arm, RIG_PATH empty: no AB-ARM line either (that one means 'measured')" "$LOGF" "AB-ARM"
done

run_block "$ABT_FILE" "$RIG_OK" "" feat/cites; RC=$?
eq "BEAD_ID empty: fail-open (rc 0)" "$RC" "0"
has "BEAD_ID empty: arm is <UNKNOWN>" "$LOGF" "arm=<UNKNOWN>"
lacks "BEAD_ID empty: NOT filed under the control arm (the function's own default for '' is A)" "$LOGF" "arm=A"

# The AB-SKIP line must not be readable as a measured verdict by the consumer.
run_block "$ABT_FILE" "" "$ID_B" feat/cites
if [ -r "$APURACAO" ]; then
  _HITS=$(grep -c -E 'AB-BASE-TEST bead=[^ ]+ arm=[AB] verdict=[^ ]+' "$LOGF" 2>/dev/null || true)
  eq "the apuracao's own verdict regex matches nothing on an AB-SKIP line" "${_HITS:-0}" "0"
  grep -F "AB-BASE-TEST bead=[^ ]+ arm=[AB] verdict=[^ ]+" "$APURACAO" >/dev/null 2>&1 \
    && ok "that regex is still the one gate-ab-apuracao.sh uses (this check is against the real consumer, not a stale copy)" \
    || bad "gate-ab-apuracao.sh no longer contains the verdict regex this test assumes — re-read what it counts before trusting the line above"
else
  bad "cannot read $APURACAO — the contamination check has no consumer to check against"
fi

# Measured paths unchanged.
run_block "$ABT_FILE" "$RIG_OK" "$ID_A" feat/cites; RC=$?
eq "measured arm A: rc 0" "$RC" "0"
has "measured arm A: the existing AB-ARM record" "$LOGF" "LOG AB-ARM bead=$ID_A arm=A "
lacks "measured arm A: no AB-SKIP" "$LOGF" "AB-SKIP"
eq "measured arm A: still byte-for-byte control — no bd call at all" "$(wc -c < "$CALLS" | tr -d ' ')" "0"

run_block "$ABT_FILE" "$RIG_OK" "$ID_B" feat/cites; RC=$?
eq "measured arm B (no selftest in the range): rc 0" "$RC" "0"
has "measured arm B: AB-BASE-TEST line, verdict sem-teste-novo" "$LOGF" "AB-BASE-TEST bead=$ID_B arm=B verdict=sem-teste-novo"
has "measured arm B: gate-ab:arm-b label still written" "$CALLS" "gate-ab:arm-b"
has "measured arm B: gate-ab-basetest label still written" "$CALLS" "gate-ab-basetest:sem-teste-novo"
lacks "measured arm B: no AB-SKIP" "$LOGF" "AB-SKIP"

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "  RESULT: PASS"
  exit 0
else
  echo "  RESULT: FAIL"
  exit 1
fi
