#!/usr/bin/env bash
# gate-6aj348-recall-bar.selftest.sh — Guard for ga-6aj348: replace the
# reviewer's "DROP it" / "be conservative" refutation-pass framing with a
# concrete blocking bar, per the Sonnet 5 review-harness guidance (ga-ttwzqd):
# an instruction like "report only high severity / be conservative" measurably
# hurts recall. The fix is a concrete bar of what blocks (WHAT BLOCKS / WHAT
# DOES NOT BLOCK), a low-confidence directive to re-read instead of silencing
# a finding, and a place for non-blocking findings to be reported (severity-
# tagged) instead of silently dropped. The refutation pass itself stays — but
# only as a FACT check ("does the defect exist?"), never as a severity filter.
#
# REDO of the first attempt (00d526a76, reverted by 79392548f): that change
# left quality-gate-dispatcher.sh unparseable by /bin/bash 3.2 — the
# interpreter the dispatcher really runs under — while Homebrew bash 5.3 (what
# a bare `bash -n` resolves to in PATH) accepted it. The gate then spawned no
# reviewer for ~3h. Two things in this harness exist because of that:
#   * the compile guard calls /bin/bash -n EXPLICITLY (never bare bash), and
#     fails loudly if /bin/bash is missing instead of skipping;
#   * the REVIEW_TASK heredoc body must contain ZERO apostrophes. The prompt is
#     an unquoted heredoc inside REVIEW_TASK=$(cat <<TASK ... TASK), and bash
#     3.2 scans a command substitution body as shell text to find its closing
#     paren, so a stray apostrophe (dont, youre, quoted 'severity') shifts the
#     quote state and the parse error surfaces ~100 lines later, at an
#     unrelated case pattern. Writing prose that "happens to parse" is luck;
#     zero apostrophes is the checkable invariant the pre-fix text already held.
#
# ga-gnr3tw: the prompt no longer lives inside quality-gate-dispatcher.sh. It moved to
# gate-review-task.lib.sh so the builder's pre-gate-review.sh renders the SAME text. The prompt
# assertions below therefore read the lib (TASKLIB_UNDER_TEST overrides the default); the compile
# guard still covers the dispatcher (GATE_UNDER_TEST overrides). To prove this harness fails on an
# older revision, point BOTH at a pre-ga-gnr3tw dispatcher, which carries the prompt inline: the
# prompt checks and the render then fall back to the inline REVIEW_TASK block.
# The render check EXECUTES the real render under /bin/bash 3.2 with stub variables, so "the new
# text reaches the reviewer prompt" is proven on the rendered output, not just on the source text.
# No live Dolt/gc/launchd. Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${GATE_UNDER_TEST:-$SELF_DIR/quality-gate-dispatcher.sh}"
TASKLIB="${TASKLIB_UNDER_TEST:-$SELF_DIR/gate-review-task.lib.sh}"
BASH32=/bin/bash

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
has()    { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }
hasnot() { if grep -qE "$2" "$1"; then bad "$3 — forbidden pattern present: $2"; else ok "$3"; fi; }

# The REVIEW_TASK block: from its opening line through the lone ")" that closes
# the command substitution (the line right after the TASK terminator).
extract_block() {
  awk '
    /REVIEW_TASK=\$\(cat <<TASK/ { f=1 }
    f { print }
    f && /^TASK$/ { seen=1; next }
    f && seen && /^\)$/ { exit }
  ' "$1"
}
# Just the prompt text between each heredoc opener and its TASK terminator. In the lib that is the three
# `cat <<TASK` bodies (judging text, bead-mode tail, text-mode tail); in a pre-ga-gnr3tw dispatcher it is the
# one inline `REVIEW_TASK=$(cat <<TASK` body — both match `<<TASK`.
extract_body() {
  # Anchored to a real opener line — optional indent, optional `REVIEW_TASK=$(`, then `cat <<TASK` and nothing else — so a
  # COMMENT that merely mentions the heredoc marker can never open a capture (a lib header comment did exactly that once,
  # and the capture swallowed code up to the next TASK line).
  awk '
    /^[[:space:]]*(REVIEW_TASK=\$\()?cat <<TASK[[:space:]]*$/ { f=1; next }
    f && /^TASK$/ { f=0; next }
    f { print }
  ' "$1"
}
# True when the file under test still carries the prompt inline (a pre-ga-gnr3tw dispatcher).
prompt_is_inline() { grep -qE 'REVIEW_TASK=\$\(cat <<TASK' "$1"; }

echo "── 1. COMPILE-GUARD: dispatcher and prompt lib parse under /bin/bash 3.2 ──"
# NEVER bare "bash -n": in PATH that is Homebrew bash 5.3, which accepts what
# the real interpreter rejects (this is exactly how the first attempt slipped).
if [ ! -x "$BASH32" ]; then
  bad "$BASH32 not executable — cannot run the real-interpreter parse check (refusing to skip)"
elif [ ! -f "$GATE" ]; then
  bad "dispatcher not found: $GATE"
else
  _parse_err="$("$BASH32" -n "$GATE" 2>&1)"
  if [ $? -eq 0 ]; then
    ok "dispatcher: $BASH32 -n clean ($("$BASH32" --version | head -n1 | sed 's/ (.*//'))"
  else
    bad "dispatcher: $BASH32 -n FAILED — ${_parse_err##*/}"
  fi
fi
if [ ! -x "$BASH32" ]; then
  :   # already reported above
elif [ ! -f "$TASKLIB" ]; then
  bad "prompt lib not found: $TASKLIB"
else
  _parse_err="$("$BASH32" -n "$TASKLIB" 2>&1)"
  if [ $? -eq 0 ]; then ok "prompt lib: $BASH32 -n clean"; else bad "prompt lib: $BASH32 -n FAILED — ${_parse_err##*/}"; fi
fi

echo "── 2. REVIEW_TASK HEREDOC HAS ZERO APOSTROPHES (bash 3.2 comsub scan) ──"
_BODY="$(extract_body "$TASKLIB")"
if [ -z "$_BODY" ]; then
  bad "could not locate the REVIEW_TASK heredoc body in $TASKLIB (marker moved? update extract_body)"
else
  _APOS=$(printf '%s\n' "$_BODY" | tr -cd "'" | wc -c | tr -d ' ')
  if [ "$_APOS" -eq 0 ]; then
    ok "REVIEW_TASK heredoc body contains no apostrophes"
  else
    _first=$(printf '%s\n' "$_BODY" | grep -n "'" | head -n1)
    bad "REVIEW_TASK heredoc body contains $_APOS apostrophe(s) — first at body line $_first — rewrite the prose without them (do not, you are)"
  fi
fi

echo "── 3. OLD SUPPRESSIVE FRAMING IS GONE ──"
hasnot "$TASKLIB" 'If you cannot ground a blocking issue in specific' \
  "the ungrounded DROP-it instruction is gone"
hasnot "$TASKLIB" 'REFUTATION PASS — MANDATORY BEFORE ANY FAIL' \
  "old MANDATORY-BEFORE-ANY-FAIL heading is gone"

echo "── 4. CONCRETE BLOCKING BAR IS IN THE SOURCE ──"
has "$TASKLIB" 'WHAT BLOCKS \(verdict FAIL\)' \
  "concrete WHAT BLOCKS bar is present"
has "$TASKLIB" 'incorrect output or state, a failing test, data' \
  "blocking bar names incorrect behavior / failing test / data loss"
has "$TASKLIB" 'misdescribes' \
  "blocking bar routes a misdescribing comment/log/docstring to Non-blocking findings (2026-10-07 decision)"
has "$TASKLIB" 'WHAT DOES NOT BLOCK' \
  "explicit non-blocking bar (style/naming) is present"

echo "── 5. REFUTATION PASS IS A FACT-CHECK, NOT A SEVERITY FILTER ──"
has "$TASKLIB" 'FACT-CHECK, NOT A SEVERITY FILTER' \
  "refutation-pass heading names it a fact-check, not a severity filter"
has "$TASKLIB" 'never a filter on how severe or' \
  "prompt states the refutation pass never filters on severity"

echo "── 6. LOW CONFIDENCE ⇒ RE-READ, NEVER SILENCE ──"
has "$TASKLIB" 'never silence' \
  "low-confidence directive tells the reviewer to re-read, never silence a finding"

echo "── 7. NON-BLOCKING FINDINGS ARE REPORTED, NOT DROPPED SILENTLY ──"
has "$TASKLIB" 'nothing you found gets dropped silently' \
  "prompt states findings are never dropped silently"
# The slot must exist in BOTH the PASS and the FAIL comment templates — a
# single has() only proves >=1 occurrence, so count explicitly.
_NBF_COUNT=$(grep -cE "Non-blocking findings: <one per line" "$TASKLIB")
if [ "$_NBF_COUNT" -ge 2 ]; then
  ok "Non-blocking findings slot present in BOTH PASS and FAIL templates ($_NBF_COUNT occurrences)"
else
  bad "Non-blocking findings slot present in BOTH PASS and FAIL templates — found $_NBF_COUNT, need >=2"
fi

echo "── 8. RENDER: the new text reaches the reviewer prompt under /bin/bash 3.2 ──"
# ga-gnr3tw: the gate renders through gate_render_review_task (bead mode). A pre-ga-gnr3tw dispatcher (only
# reachable through the *_UNDER_TEST overrides) still carries the prompt as an inline REVIEW_TASK block.
_WORK="$(mktemp -d "${TMPDIR:-/tmp}/gate-6aj348.XXXXXX")"
if [ ! -x "$BASH32" ]; then
  bad "$BASH32 missing — cannot execute the render"
elif prompt_is_inline "$TASKLIB"; then
  _BLOCK="$(extract_block "$TASKLIB")"
  if [ -z "$_BLOCK" ]; then
    bad "could not extract the inline REVIEW_TASK block from $TASKLIB"
  else
    {
      echo 'i=2; REQUIRED_REVIEWERS=3; BRANCH=feat/selftest-branch; AUTHOR=selftest-author'
      echo 'RIG=selftest-rig; BRANCH_SHA=0000000; REVIEWER_LENS=selftest-lens'
      echo 'CHANGED_FILES=a.sh; DIFF_SUMMARY=1-file; DIFF_HEADER=hdr; DIFF_FULL=diff-body'
      echo 'GC_CITY=/selftest/city; VERDICT_BEAD_ID=ga-selftest'
      printf '%s\n' "$_BLOCK"
      echo 'printf "%s\n" "$REVIEW_TASK"'
    } > "$_WORK/render.sh"
  fi
else
  {
    echo 'set -euo pipefail'
    echo "source \"$TASKLIB\""
    echo 'gate_render_review_task 2 3 feat/selftest-branch selftest-author selftest-rig 0000000 selftest-lens a.sh 1-file hdr diff-body /selftest/city ga-selftest bead'
  } > "$_WORK/render.sh"
fi
if [ -f "$_WORK/render.sh" ]; then
  _RENDERED="$("$BASH32" "$_WORK/render.sh" 2>"$_WORK/render.err")"
  _RC=$?
  if [ "$_RC" -ne 0 ] || [ -z "$_RENDERED" ]; then
    bad "review task failed to render under $BASH32 (rc=$_RC): $(head -n1 "$_WORK/render.err")"
  else
    ok "review task renders under $BASH32"
    # Here-string, not `printf | grep -q`: under `set -o pipefail` grep -q exits on its first match, printf can
    # take SIGPIPE (141) mid-write, and the pipeline then reports FAILURE for a phrase that IS in the prompt.
    # That made this harness fail at random (a different assertion each run) before ga-gnr3tw.
    r_has() { if grep -qF -- "$1" <<<"$_RENDERED"; then ok "$2"; else bad "$2 — not in rendered prompt: $1"; fi; }
    r_has 'reviewer 2 of 3 for branch: feat/selftest-branch' "variables expand into the rendered prompt (sanity)"
    r_has 'WHAT BLOCKS (verdict FAIL)'          "rendered prompt carries the concrete WHAT BLOCKS bar"
    r_has 'WHAT DOES NOT BLOCK'                 "rendered prompt carries the WHAT DOES NOT BLOCK bar"
    r_has 'FACT-CHECK, NOT A SEVERITY FILTER'   "rendered prompt frames the refutation pass as a fact-check"
    r_has 'never silence'                       "rendered prompt tells the reviewer to re-read, never silence"
    r_has 'nothing you found gets dropped silently' "rendered prompt says findings are never dropped silently"
    _R_NBF=$(grep -cF 'Non-blocking findings: <one per line' <<<"$_RENDERED")
    if [ "$_R_NBF" -ge 2 ]; then
      ok "rendered prompt has the Non-blocking findings slot in PASS and FAIL templates ($_R_NBF)"
    else
      bad "rendered prompt has the Non-blocking findings slot $_R_NBF time(s), need >=2"
    fi
    if grep -qF 'DROP it' <<<"$_RENDERED"; then
      bad "rendered prompt still tells the reviewer to DROP findings"
    else
      ok "rendered prompt no longer tells the reviewer to DROP findings"
    fi
    # 2026-10-07 (owner's decision after the gate diagnosis): behavior defects block; a comment/log/docstring that
    # misdescribes the code, or an edge case with no observable effect, is a NON-blocking finding — reported, never dropped.
    r_has 'changes BEHAVIOR' "rendered prompt blocks on BEHAVIOR defects"
    r_has 'misdescribes' "rendered prompt routes misdescribing comments/logs to Non-blocking findings"
    r_has 'no observable effect' "rendered prompt routes no-effect edge cases to Non-blocking findings"
    if grep -qF 'misleading result/log/comment' <<<"$_RENDERED"; then
      bad "rendered prompt still lists a misleading log/comment as BLOCKING"
    else
      ok "rendered prompt no longer blocks on a misleading log/comment alone"
    fi
  fi
fi
rm -rf "$_WORK"

echo
echo "── RESULT: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
