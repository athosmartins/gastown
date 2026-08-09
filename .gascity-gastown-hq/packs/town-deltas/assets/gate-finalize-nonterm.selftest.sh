#!/usr/bin/env bash
# gate-finalize-nonterm.selftest.sh — ga-xxgej
#
# Regression guard for gate_finalize_run()'s non-termination bug: a gate_run
# whose reviewer verdict was all-PASS, but whose merge attempt then failed
# with a MERGE_RESULT=failed_* (mutating OVERALL_VERDICT to "FAIL" mid-merge
# — e.g. GATE_SHA_FAIL_CLASS="hold" for failed_sha_resolution), never reached
# the terminal set_gate_status/bd-close logic. That logic lived inside the
# ELSE of the SAME outer `if [ "$OVERALL_VERDICT" = "PASS" ]` that bash had
# already committed to its then-branch BEFORE the merge was ever attempted —
# a mid-branch mutation of the condition variable doesn't make bash revisit
# a decision it already made. Live-confirmed: gate-run ga-j1isp (bead
# ga-7ha7g) looped 9x over ~15min on 2026-08-08, re-discovered every ~60-90s
# by Phase C's `-l gate-status:running` sweep, before the underlying
# transient git race happened not to recur on a later attempt — pure luck,
# not a fix. GATE_SHA_FAIL_CLASS has exactly one consumer in the whole file
# (inside that same unreachable branch), so setting it was a complete no-op
# for this case.
#
# Fix: split the single if/else into two SEQUENTIAL ifs — one that just
# gates "attempt the merge", closed immediately after; a second, independent
# `if [ "$OVERALL_VERDICT" = "PASS" ]` (previously nested one level inside
# the first, now a sibling) that is the SOLE, always-reached decision point
# for PASS-terminal vs FAIL-terminal handling, with a NEW else that routes
# to the pre-existing close/notify/fix-attempt-cap logic.
#
# WHY THIS TEST LOOKS DIFFERENT FROM EVERY OTHER *.selftest.sh HERE:
# gate_finalize_run() cannot be dynamically driven through a real scenario
# hermetically — do_merge_ff is a function NESTED inside it that does real
# git operations, and the surrounding ~1500 lines depend on ~10+ external
# commands (bd, git, gc, notify, dolt) throughout. No existing selftest for
# this file even attempts it: every one sources the dispatcher via
# GATE_DISPATCHER_LIB_ONLY=1, whose early-return (~line 2902) sits BEFORE
# gate_finalize_run is even defined (confirmed by grep: zero selftests call
# gate_finalize_run as a bare statement). A plain grep-based drift-guard
# (the usual fallback in this family — see gate-sha-fail-lock.selftest.sh
# §6c) can't distinguish "nested inside the PASS then-branch" from "a
# sibling if" either — indentation in the SOURCE FILE is not normative bash
# structure, which is exactly how this bug hid in plain sight.
#
# Instead: extract gate_finalize_run()'s exact source text and SOURCE it in
# isolation (definition only — it is never CALLED, so none of its external
# dependencies need to exist). Then read back `declare -f`'s output — bash's
# OWN CANONICAL reindentation of the function, computed from its real parsed
# structure, not the source file's literal whitespace. Two stable text
# anchors (the merge-attempt log line; the FAIL-path's own set_gate_status
# call) let this test compare their bash-computed nesting depths directly:
# siblings in the fixed code, nested in the pre-fix code. This is the same
# method used to hand-verify this fix before shipping it.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  bad "could not find quality-gate-dispatcher.sh alongside this selftest"
  echo "gate-finalize-nonterm selftest: PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# --- Extract gate_finalize_run()'s exact source body -------------------------
_start=""
if ! _start=$(grep -n '^gate_finalize_run() {' "$DISPATCHER" | head -1 | cut -d: -f1); then
  _start=""
fi
if [ -z "$_start" ]; then
  bad "could not find 'gate_finalize_run() {' in $DISPATCHER"
  echo "gate-finalize-nonterm selftest: PASS=$PASS FAIL=$FAIL"
  exit 1
fi

_end_rel=""
if ! _end_rel=$(tail -n "+$_start" "$DISPATCHER" | grep -n '^}$' | head -1 | cut -d: -f1); then
  _end_rel=""
fi
if [ -z "$_end_rel" ]; then
  bad "could not find gate_finalize_run()'s closing brace after line $_start"
  echo "gate-finalize-nonterm selftest: PASS=$PASS FAIL=$FAIL"
  exit 1
fi
_end=$((_start + _end_rel - 1))
ok "found gate_finalize_run() spanning lines $_start-$_end"

_tmpd=$(mktemp -d)
trap 'rm -rf "$_tmpd"' EXIT
sed -n "${_start},${_end}p" "$DISPATCHER" > "$_tmpd/gfr.sh"

# --- Source the extracted definition (never called) in a subshell ------------
if ! ( source "$_tmpd/gfr.sh" ) 2> "$_tmpd/source.err"; then
  bad "gate_finalize_run() failed to SOURCE (syntax error?) — see below"
  cat "$_tmpd/source.err"
  echo "gate-finalize-nonterm selftest: PASS=$PASS FAIL=$FAIL"
  exit 1
fi
ok "gate_finalize_run() sources cleanly in isolation (no syntax error)"

( source "$_tmpd/gfr.sh"; declare -f gate_finalize_run ) > "$_tmpd/declared.sh" 2>/dev/null || true
if [ ! -s "$_tmpd/declared.sh" ]; then
  bad "declare -f gate_finalize_run produced no output — function not defined?"
  echo "gate-finalize-nonterm selftest: PASS=$PASS FAIL=$FAIL"
  exit 1
fi
ok "declare -f gate_finalize_run produced bash's canonical reindented parse"

# --- Compare the merge-attempt if against the re-check if --------------------
# The exact text `if [ "$OVERALL_VERDICT" = "PASS" ]; then` (end-anchored —
# this deliberately excludes the OTHER, compound-condition variants earlier
# in the function, e.g. `... ] && [ -n "$BEAD_ID" ]; then`, which are
# unrelated checks) appears exactly 3 times in gate_finalize_run(): the
# merge-attempt if (1st), the re-check right after the merge/retry logic
# (2nd) — this pair is what this bug is about — and an unrelated Step-11
# logging check (3rd, `REASON=...`), which this test ignores.
#
# THE DISCRIMINATOR (verified empirically against both the pre-fix and
# post-fix source before writing this test — this is not a guess): bash's
# `declare -f` reindents based on TRUE nesting depth, not the source file's
# literal whitespace. Pre-fix, the 2nd if is NESTED one level inside the
# 1st if's then-branch (its own line sits 4 columns deeper). Post-fix, the
# 2nd if is a SIBLING of the 1st (split into two sequential ifs by this
# fix) — same depth, because the 1st if now closes (via a new `fi`)
# immediately before the 2nd begins. A naive "is the FAIL-close code
# reachable at all" check does NOT discriminate here: in BOTH versions the
# FAIL-close content ends up exactly one level below *some* if at the 1st
# if's own depth (pre-fix: the 1st if's OWN else, which fires only when
# verdict was FAIL before this function ever ran; post-fix: the 2nd if's
# else, which fires whenever verdict is FAIL when the 2nd if is reached,
# including a mid-merge mutation) — those are semantically opposite but
# numerically identical to measure that way. Comparing the two ifs' own
# depths directly is what actually tells them apart.
# bash 3.2 (this system's only bash — verified, no mapfile/readarray) so this
# is plain grep+sed, not an array read: `if ! VAR=$(pipeline); then VAR=""`
# guards the same set -e assignment-exit-code trap this session already hit
# and fixed twice today elsewhere — grep exits 1 on zero matches, and under
# pipefail that propagates through `| cut` to the assignment.
_pass_if_lines=""
if ! _pass_if_lines=$(grep -n 'OVERALL_VERDICT" = "PASS" \]; then$' "$_tmpd/declared.sh" | cut -d: -f1); then
  _pass_if_lines=""
fi
_pass_if_count=$(printf '%s\n' "$_pass_if_lines" | grep -c . || true)

if [ -z "$_pass_if_lines" ] || [ "$_pass_if_count" -lt 2 ]; then
  bad "expected >=2 occurrences of the exact merge-attempt/re-check if text in bash's canonical parse, found ${_pass_if_count:-0} — anchor text may have drifted"
  echo "gate-finalize-nonterm selftest: PASS=$PASS FAIL=$FAIL"
  exit 1
fi
_merge_if_line=$(printf '%s\n' "$_pass_if_lines" | sed -n '1p')
_recheck_if_line=$(printf '%s\n' "$_pass_if_lines" | sed -n '2p')
ok "found $_pass_if_count occurrences of the exact if-text in bash's canonical parse (using the first 2: merge-attempt @ declared-line $_merge_if_line, re-check @ declared-line $_recheck_if_line)"

_merge_if_indent=$(sed -n "${_merge_if_line}p" "$_tmpd/declared.sh" | sed 's/[^ ].*//' | wc -c | tr -d ' ')
_recheck_if_indent=$(sed -n "${_recheck_if_line}p" "$_tmpd/declared.sh" | sed 's/[^ ].*//' | wc -c | tr -d ' ')

if [ "$_recheck_if_indent" -eq "$_merge_if_indent" ]; then
  ok "re-check if is a SIBLING of the merge-attempt if (both at indent $_merge_if_indent) — it is the SOLE, always-reached decision point for PASS vs FAIL, not buried inside the merge-attempt if's own then-branch"
else
  bad "ga-xxgej REGRESSION: re-check if (indent $_recheck_if_indent) is NOT at the same depth as the merge-attempt if (indent $_merge_if_indent) — it is nested inside the merge-attempt if's then-branch again, exactly the pre-fix shape. A mid-merge PASS->FAIL mutation of OVERALL_VERDICT (e.g. a failed_* MERGE_RESULT) will fall through to nothing: no set_gate_status, no bd close, no notify — Phase C will re-discover and re-process the same gate_run forever. Re-verify by hand: sed -n '${_start},${_end}p' '$DISPATCHER' > /tmp/gfr.sh; (source /tmp/gfr.sh; declare -f gate_finalize_run) | less"
fi

echo
echo "gate-finalize-nonterm selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
