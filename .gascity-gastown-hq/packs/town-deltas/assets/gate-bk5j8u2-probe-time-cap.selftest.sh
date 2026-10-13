#!/usr/bin/env bash
# gate-bk5j8u2-probe-time-cap.selftest.sh — Guard for ga-bk5j8u.2: the gate reviewer prompt gives test
# execution a concrete time ceiling (about 3 minutes in total), scopes the runs to the files the diff
# changed, and asks for a mutation or reproduction probe only when reading the code leaves a suspected
# defect undecided.
#
# Why: ga-bk5j8u measured the average review at 15 → 27 min. Messages per reviewer session rose from ~20 to
# ~44 and ~9.6 of ~20.5 min per session went to running and waiting on tests on a loaded machine. The
# 07/10 prompt (c629152fc) said probes "are not covered by any of this: run them" — no bound at all.
#
# What must NOT change (the owner protects defect recall, ga-ufskhy): the blocking bar, the rule that a
# defect grounded in the changed lines blocks, the 600 s foreground note, the "never the whole tests/
# directory" rule and the "red on the base for the SAME test id is pre-existing" rule. Asserted below so a
# future edit that trades recall for speed fails here instead of in the verdict statistics.
#
# The assertions run on the RENDERED prompt (bead mode = the gate, text mode = the builder pre-gate), under
# /bin/bash 3.2 — the interpreter the dispatcher really runs under. TASKLIB_UNDER_TEST points the harness at
# another revision of the lib (used to prove the new assertions fail on the pre-change text).
# No live Dolt/gc/launchd. Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKLIB="${TASKLIB_UNDER_TEST:-$SELF_DIR/gate-review-task.lib.sh}"
BASH32=/bin/bash

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

_WORK="$(mktemp -d "${TMPDIR:-/tmp}/gate-bk5j8u2.XXXXXX")"
trap 'rm -rf "$_WORK"' EXIT

render() {   # render <bead|text> — the prompt exactly as that caller would send it
  {
    echo 'set -euo pipefail'
    echo "source \"$TASKLIB\""
    echo "gate_render_review_task 2 3 feat/selftest-branch selftest-author selftest-rig 0000000 selftest-lens a.sh 1-file hdr diff-body /selftest/city ga-selftest $1"
  } > "$_WORK/render-$1.sh"
  "$BASH32" "$_WORK/render-$1.sh" 2>"$_WORK/render-$1.err"
}
# The RUNNING TESTS paragraph: from its label to the first blank line after it.
paragraph() { awk '/^RUNNING TESTS:/ { f=1 } f && /^[[:space:]]*$/ { exit } f { print }'; }

echo "── 1. RENDER: both callers render the prompt under $BASH32 ──"
if [ ! -x "$BASH32" ]; then
  bad "$BASH32 missing — cannot execute the render (refusing to skip)"
elif [ ! -f "$TASKLIB" ]; then
  bad "prompt lib not found: $TASKLIB"
else
  _BEAD="$(render bead)"; _RC_B=$?
  _TEXT="$(render text)"; _RC_T=$?
  if [ "$_RC_B" -ne 0 ] || [ -z "$_BEAD" ]; then bad "bead mode failed to render (rc=$_RC_B): $(head -n1 "$_WORK/render-bead.err")"; else ok "bead mode (the gate) renders"; fi
  if [ "$_RC_T" -ne 0 ] || [ -z "$_TEXT" ]; then bad "text mode failed to render (rc=$_RC_T): $(head -n1 "$_WORK/render-text.err")"; else ok "text mode (the builder pre-gate) renders"; fi
fi

if [ -n "${_BEAD:-}" ] && [ -n "${_TEXT:-}" ]; then
  _PB_RAW="$(paragraph <<<"$_BEAD")"
  _PT_RAW="$(paragraph <<<"$_TEXT")"
  # Phrases are matched on the paragraph with its line wraps joined, so a phrase that wraps in the source still matches.
  _PB="$(tr '\n' ' ' <<<"$_PB_RAW" | sed 's/  */ /g')"
  _PT="$(tr '\n' ' ' <<<"$_PT_RAW" | sed 's/  */ /g')"
  # Here-strings, not `printf | grep -q`: under pipefail grep -q can SIGPIPE the printf and fail a phrase that IS there.
  p_has()    { if grep -qF -- "$1" <<<"$_PB"; then ok "$2"; else bad "$2 — not in the RUNNING TESTS paragraph: $1"; fi; }
  p_hasnot() { if grep -qF -- "$1" <<<"$_PB"; then bad "$2 — still in the paragraph: $1"; else ok "$2"; fi; }

  echo "── 2. THE PARAGRAPH EXISTS AND THE BUILDER REHEARSES THE SAME TEXT ──"
  if [ -n "$_PB" ]; then ok "RUNNING TESTS paragraph found in the rendered prompt"; else bad "no RUNNING TESTS paragraph in the rendered prompt (label moved? update paragraph())"; fi
  if [ "$_PB_RAW" = "$_PT_RAW" ]; then ok "gate and builder pre-gate paragraphs are byte-identical"; else bad "gate and builder pre-gate paragraphs differ — the builder would rehearse against another prompt"; fi

  echo "── 3. THE NEW BAR: about 3 minutes, changed files only, probe only when reading cannot decide ──"
  p_has 'about 3 minutes of execution'          "a concrete execution ceiling of about 3 minutes, tests and probes together"
  p_has 'test files this diff changed'           "runs are scoped to the test files the diff changed"
  p_has 'the tests it adds'                      "runs include the tests the diff adds"
  p_has 'one file at a time'                     "files run one at a time, so the ceiling can be tracked"
  p_has 'only when reading the code leaves'      "a probe is written only when reading the code leaves a suspected defect undecided"
  p_has 'shared with the whole city'             "the prompt explains WHY (shared machine)"
  p_has 'gate queue waits on every'              "the prompt explains WHY (the gate queue waits on every review)"
  p_has 'named as not run'                       "hitting the ceiling with a check open is reported as not run, never silently passed"

  echo "── 4. THE OLD UNBOUNDED INVITATION IS GONE ──"
  p_hasnot 'are not covered by any of this'      "probes are no longer exempt from the rules"
  p_hasnot 'they are the best defence the gate has' "the unbounded run-them sentence is gone"

  echo "── 5. RECALL IS NOT TRADED FOR SPEED (the owner's bar, ga-ufskhy) ──"
  p_has 'limits execution, never scrutiny'       "the ceiling limits execution, not how closely the diff is read"
  p_has 'blocks exactly as it did'               "a defect grounded in the changed lines blocks exactly as before"
  if grep -qF 'WHAT BLOCKS (verdict FAIL)' <<<"$_BEAD" && grep -qF 'changes BEHAVIOR' <<<"$_BEAD"; then ok "the WHAT BLOCKS bar is untouched"; else bad "the WHAT BLOCKS bar changed"; fi
  p_has 'capped at 600 s'                        "the 600 s foreground note is kept"
  p_has 'run_in_background or nohup'             "the background-run instruction is kept"
  p_has 'whole tests/ directory'                 "the never-the-whole-tests/ rule is kept"
  p_has 'SAME'                                   "the same-test-id pre-existing rule is kept"
  p_has 'a failing test blocks only when this diff'  "a failing test still blocks when this diff made it fail"

  echo "── 6. PROMPT STYLE FOR THE CURRENT MODELS (CLAUDE.md, Modelos atuais item 6) ──"
  if grep -qE 'CRITICAL|MUST|NEVER|ALWAYS|IMPORTANT' <<<"$_PB"; then
    bad "the paragraph shouts (CRITICAL/MUST/NEVER/ALWAYS/IMPORTANT): $(grep -oE 'CRITICAL|MUST|NEVER|ALWAYS|IMPORTANT' <<<"$_PB" | sort -u | tr '\n' ' ')"
  else
    ok "no emphasis words in capitals — the reason is stated instead"
  fi
  if grep -qiE 'pense passo a passo|think step by step|step-by-step reasoning' <<<"$_PB"; then bad "the paragraph asks for step-by-step reasoning (refused on Opus 5.5)"; else ok "no step-by-step reasoning request"; fi
fi

echo
echo "── RESULT: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
