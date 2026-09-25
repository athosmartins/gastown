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
# Every assertion below runs against the dispatcher file (GATE_UNDER_TEST
# overrides the default, so this harness can be pointed at an older revision to
# prove it fails there). The render check also EXECUTES the real REVIEW_TASK
# command substitution under /bin/bash 3.2 with stub variables, so "the new
# text reaches the reviewer prompt" is proven on the rendered output, not just
# on the source text. No live Dolt/gc/launchd. Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${GATE_UNDER_TEST:-$SELF_DIR/quality-gate-dispatcher.sh}"
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
# Just the prompt text between the heredoc opener and the TASK terminator.
extract_body() {
  awk '
    /REVIEW_TASK=\$\(cat <<TASK/ { f=1; next }
    f && /^TASK$/ { exit }
    f { print }
  ' "$1"
}

echo "── 1. COMPILE-GUARD: dispatcher parses under /bin/bash 3.2 ──"
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

echo "── 2. REVIEW_TASK HEREDOC HAS ZERO APOSTROPHES (bash 3.2 comsub scan) ──"
_BODY="$(extract_body "$GATE")"
if [ -z "$_BODY" ]; then
  bad "could not locate the REVIEW_TASK heredoc body (marker moved? update extract_body)"
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
hasnot "$GATE" 'If you cannot ground a blocking issue in specific' \
  "the ungrounded DROP-it instruction is gone"
hasnot "$GATE" 'REFUTATION PASS — MANDATORY BEFORE ANY FAIL' \
  "old MANDATORY-BEFORE-ANY-FAIL heading is gone"

echo "── 4. CONCRETE BLOCKING BAR IS IN THE SOURCE ──"
has "$GATE" 'WHAT BLOCKS \(verdict FAIL\)' \
  "concrete WHAT BLOCKS bar is present"
has "$GATE" 'incorrect behavior, a failing test, data loss, or a' \
  "blocking bar names incorrect behavior / failing test / data loss"
has "$GATE" 'misleading result/log/comment' \
  "blocking bar names misleading result/log/comment"
has "$GATE" 'WHAT DOES NOT BLOCK' \
  "explicit non-blocking bar (style/naming) is present"

echo "── 5. REFUTATION PASS IS A FACT-CHECK, NOT A SEVERITY FILTER ──"
has "$GATE" 'FACT-CHECK, NOT A SEVERITY FILTER' \
  "refutation-pass heading names it a fact-check, not a severity filter"
has "$GATE" 'never a filter on how severe or' \
  "prompt states the refutation pass never filters on severity"

echo "── 6. LOW CONFIDENCE ⇒ RE-READ, NEVER SILENCE ──"
has "$GATE" 'never silence' \
  "low-confidence directive tells the reviewer to re-read, never silence a finding"

echo "── 7. NON-BLOCKING FINDINGS ARE REPORTED, NOT DROPPED SILENTLY ──"
has "$GATE" 'nothing you found gets dropped silently' \
  "prompt states findings are never dropped silently"
# The slot must exist in BOTH the PASS and the FAIL comment templates — a
# single has() only proves >=1 occurrence, so count explicitly.
_NBF_COUNT=$(grep -cE "Non-blocking findings: <one per line" "$GATE")
if [ "$_NBF_COUNT" -ge 2 ]; then
  ok "Non-blocking findings slot present in BOTH PASS and FAIL templates ($_NBF_COUNT occurrences)"
else
  bad "Non-blocking findings slot present in BOTH PASS and FAIL templates — found $_NBF_COUNT, need >=2"
fi

echo "── 8. RENDER: the new text reaches the reviewer prompt under /bin/bash 3.2 ──"
_BLOCK="$(extract_block "$GATE")"
if [ -z "$_BLOCK" ] || [ ! -x "$BASH32" ]; then
  bad "could not extract/execute the REVIEW_TASK block (block empty or $BASH32 missing)"
else
  _WORK="$(mktemp -d "${TMPDIR:-/tmp}/gate-6aj348.XXXXXX")"
  {
    echo 'i=2; REQUIRED_REVIEWERS=3; BRANCH=feat/selftest-branch; AUTHOR=selftest-author'
    echo 'RIG=selftest-rig; BRANCH_SHA=0000000; REVIEWER_LENS=selftest-lens'
    echo 'CHANGED_FILES=a.sh; DIFF_SUMMARY=1-file; DIFF_HEADER=hdr; DIFF_FULL=diff-body'
    echo 'GC_CITY=/selftest/city; VERDICT_BEAD_ID=ga-selftest'
    printf '%s\n' "$_BLOCK"
    echo 'printf "%s\n" "$REVIEW_TASK"'
  } > "$_WORK/render.sh"
  _RENDERED="$("$BASH32" "$_WORK/render.sh" 2>"$_WORK/render.err")"
  _RC=$?
  if [ "$_RC" -ne 0 ] || [ -z "$_RENDERED" ]; then
    bad "REVIEW_TASK block failed to render under $BASH32 (rc=$_RC): $(head -n1 "$_WORK/render.err")"
  else
    ok "REVIEW_TASK block renders under $BASH32"
    r_has() { if printf '%s\n' "$_RENDERED" | grep -qF -- "$1"; then ok "$2"; else bad "$2 — not in rendered prompt: $1"; fi; }
    r_has 'reviewer 2 of 3 for branch: feat/selftest-branch' "variables expand into the rendered prompt (sanity)"
    r_has 'WHAT BLOCKS (verdict FAIL)'          "rendered prompt carries the concrete WHAT BLOCKS bar"
    r_has 'WHAT DOES NOT BLOCK'                 "rendered prompt carries the WHAT DOES NOT BLOCK bar"
    r_has 'FACT-CHECK, NOT A SEVERITY FILTER'   "rendered prompt frames the refutation pass as a fact-check"
    r_has 'never silence'                       "rendered prompt tells the reviewer to re-read, never silence"
    r_has 'nothing you found gets dropped silently' "rendered prompt says findings are never dropped silently"
    _R_NBF=$(printf '%s\n' "$_RENDERED" | grep -cF 'Non-blocking findings: <one per line')
    if [ "$_R_NBF" -ge 2 ]; then
      ok "rendered prompt has the Non-blocking findings slot in PASS and FAIL templates ($_R_NBF)"
    else
      bad "rendered prompt has the Non-blocking findings slot $_R_NBF time(s), need >=2"
    fi
    if printf '%s\n' "$_RENDERED" | grep -qF 'DROP it'; then
      bad "rendered prompt still tells the reviewer to DROP findings"
    else
      ok "rendered prompt no longer tells the reviewer to DROP findings"
    fi
  fi
  rm -rf "$_WORK"
fi

echo
echo "── RESULT: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
