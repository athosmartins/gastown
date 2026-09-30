#!/usr/bin/env bash
# gate-review-task.lib.sh — the ONE place that decides what a gate reviewer is shown (ga-gnr3tw).
#
# Sourced by quality-gate-dispatcher.sh (the live gate) and by pre-gate-review.sh (the builder's
# self-review before /gate-done). It exists so the builder can run the reviewer's own lens on its own
# diff without a second copy of the prompt: a copy drifts, and a builder that passes a stale copy learns
# nothing about what the gate will say. Everything the reviewer JUDGES BY lives here:
#   gate_reviewer_lens        the per-index lens text
#   gate_diff_summary         the one-line --stat summary
#   gate_build_diff_payload   the diff text + the header that says how much of it is shown
#   gate_render_review_task   the task prompt itself
# Only the last block of the prompt differs between callers: where the verdict goes (a verdict bead for
# the gate, plain text for the builder). That is the `verdict_mode` argument; the judging text above it is
# shared byte for byte.
#
# Contract: pure functions — stdout, plus the two globals gate_build_diff_payload documents. No bd, no gc,
# no network. Safe under `set -euo pipefail` (every positional read is ${N:-}) and under /bin/bash 3.2.
#
# Editing the prompt text below changes what every reviewer is told, and what the builder rehearses against. Keep the
# prose free of apostrophes: while this text sat inside a command substitution in the dispatcher, one stray apostrophe
# made /bin/bash 3.2 misparse the whole file and the gate spawned no reviewer for ~3h (ga-6aj348). It no longer sits in a
# command substitution, but gate-6aj348-recall-bar.selftest.sh still enforces zero apostrophes here — a cheap invariant
# that keeps this text safe to inline again. Re-run gate-6aj348-recall-bar.selftest.sh and pre-gate-review.selftest.sh.

# gate_reviewer_lens <index> — prints the lens for reviewer <index> (1..3); prints nothing for any other index.
gate_reviewer_lens() {
  local _lens=""
  case "${1:-}" in
    1) _lens="CORRECTNESS: focus on logic errors, edge cases, off-by-one bugs, null/empty handling, error propagation, and incorrect assumptions. Be adversarial. (The ga-p5q3 third-state check now lives in the reviewer prompt template as a MANDATORY dimension for ALL lenses — ga-31ac, mila-wa. Do not duplicate it here: saying it twice dilutes both.)" ;;
    2) _lens="SECURITY & ROBUSTNESS: focus on injection risks, unsafe eval/exec, credentials in code, path traversal, race conditions, resource leaks, and missing input validation." ;;
    3) _lens="DESIGN & MAINTAINABILITY: focus on architectural concerns, code duplication, missing tests, test quality, unclear naming, violation of existing conventions, and tech debt introduced." ;;
  esac
  printf '%s' "$_lens"
}

# gate_diff_summary <git_fn> <base_ref> <head_ref> — the --stat tail the reviewer sees under DIFF SUMMARY.
# <git_fn> is the caller's git runner (`git_rig` in the dispatcher, plain `git` for the builder).
gate_diff_summary() {
  local _git_fn="${1:-}" _base="${2:-}" _head="${3:-}"
  "$_git_fn" diff --stat "$_base...$_head" 2>/dev/null | tail -5 | tr '\n' ' ' | cut -c1-300 || true
}

# gate_build_diff_payload <git_fn> <base_ref> <head_ref> <changed_files> <file_count> <budget> <escape_hatch_cmd>
#   Sets the globals DIFF_FULL and DIFF_HEADER (and DIFF_RAW_TOTAL_LINES) that gate_render_review_task embeds.
#   ga-p4g6: the old `head -2000` truncation sliced through diff hunks mid-file AND the header unconditionally
#   said "FULL DIFF (first 2000 lines)" — "full" and "silently truncated at 45%" rendered as IDENTICAL text,
#   so a reviewer trusting the header had no way to know 9 of 20 changed files (including the one with the
#   real bug) were never shown. Measured: 14% of live branches (3/21 sampled) truncated silently; the worst
#   cases showed reviewers as little as 25-38% of the actual change.
#   Fix: capture the full diff ONCE; if it exceeds the budget, rebuild it by walking <changed_files> in order
#   and including each file's diff WHOLE — stopping before the file that would blow the budget, never inside
#   one. The header then states real numbers and names every omitted file, so "I reviewed the change" and
#   "I reviewed part of the change" can no longer produce the same text.
#   Note: "|| true" suppresses SIGPIPE (exit 141) if a downstream consumer of this output truncates under
#   pipefail — kept from the original for parity.
#   Per-file diffs use the pathspec ":(top,literal)<path>". `git diff --name-only` prints ROOT-relative names, but a plain
#   pathspec is resolved against the runner's cwd, and the gascity rig runs git from `.gascity-gastown-hq/`, a SUBDIRECTORY
#   of the toplevel: there every per-file diff came back EMPTY (measured: 0 lines, versus 104 from the toplevel), so the
#   reviewer read "PARTIAL DIFF — showing N of N files" over a blank body. `:(top)` makes the name mean the same thing from
#   any cwd (the gate's subdirectory and the builder's toplevel then render the same payload) and `literal` keeps a name
#   containing * or [ from being read as a glob. A file whose per-file diff still comes back empty is listed as omitted, never
#   counted as shown: an empty answer is not the same thing as "shown, and there was nothing to see".
#   COVERAGE, for the caller that has to act on it (the header above is prose for the reviewer; these are for code). Three
#   states, because "the reviewer was shown all of it", "shown part of it" and "we cannot tell" must not read the same:
#     DIFF_COVERAGE      full     the whole diff is in the payload (within budget, and it has text)
#                        partial  over budget: DIFF_SHOWN_FILES of the file_count files are in it, DIFF_SHOWN_LINES of the
#                                 DIFF_RAW_TOTAL_LINES lines; DIFF_OMITTED_LIST names the rest (one "  - <file>" per line)
#                        unknown  the whole-diff read came back empty (see KNOWN LIMIT): "shown in full" would be a guess
#     DIFF_SHOWN_FILES / DIFF_SHOWN_LINES / DIFF_OMITTED_LIST as above (0 / 0 / "" for full and unknown).
#   They are reset on entry, so a builder that never ran cannot leave the previous call's answer behind.
#   KNOWN LIMIT (moved verbatim from the dispatcher, not introduced here): the whole-diff call below is `|| true`, so a
#   `git diff` that FAILS reads as an empty diff and renders "FULL DIFF (complete - 0 lines across N file(s), nothing omitted)"
#   over a blank body: a failed read and an empty diff look the same. The promise above holds for a diff that was read, not
#   for one that could not be. A caller that already holds a non-empty file list can tell the two apart from
#   DIFF_RAW_TOTAL_LINES = 0 and should refuse to review: pre-gate-review.sh does (reason diff-text-empty). The gate
#   dispatcher does not yet; changing it means changing what the production gate does on a git failure, a separate bead.
gate_build_diff_payload() {
  local _git_fn="${1:-}" _base="${2:-}" _head="${3:-}" _changed_files="${4:-}"
  local _file_count="${5:-0}" _budget="${6:-2000}" _escape_hatch_cmd="${7:-}"
  local DIFF_RAW="" _df="" _FILE_DIFF="" _FILE_DIFF_LINES=0
  local _DIFF_SHOWN_LINES=0 _DIFF_SHOWN_FILES=0 DIFF_OMITTED_FILES=""
  DIFF_COVERAGE="unknown"; DIFF_SHOWN_FILES=0; DIFF_SHOWN_LINES=0; DIFF_OMITTED_LIST=""

  DIFF_RAW=$("$_git_fn" diff "$_base...$_head" 2>/dev/null || true)
  if [ -z "$DIFF_RAW" ]; then
    DIFF_RAW_TOTAL_LINES=0
  else
    DIFF_RAW_TOTAL_LINES=$(printf '%s\n' "$DIFF_RAW" | wc -l | tr -d ' ')
  fi

  if [ "$DIFF_RAW_TOTAL_LINES" -le "$_budget" ]; then
    DIFF_FULL="$DIFF_RAW"
    DIFF_HEADER="FULL DIFF (complete — $DIFF_RAW_TOTAL_LINES lines across $_file_count file(s), nothing omitted):"
    # An empty read is not "the whole diff was shown" (KNOWN LIMIT above): only a diff that HAS text is full coverage.
    if [ "$DIFF_RAW_TOTAL_LINES" -gt 0 ]; then DIFF_COVERAGE="full"; DIFF_SHOWN_FILES="$_file_count"; DIFF_SHOWN_LINES="$DIFF_RAW_TOTAL_LINES"; fi
  else
    DIFF_FULL=""
    while IFS= read -r _df; do
      [ -z "$_df" ] && continue
      _FILE_DIFF=$("$_git_fn" diff "$_base...$_head" -- ":(top,literal)$_df" 2>/dev/null || true)
      if [ -z "$_FILE_DIFF" ]; then
        DIFF_OMITTED_FILES="${DIFF_OMITTED_FILES}  - ${_df} (its per-file diff came back empty - not shown)
"
        continue
      fi
      _FILE_DIFF_LINES=$(printf '%s\n' "$_FILE_DIFF" | wc -l | tr -d ' ')
      # Always take at least the first file whole (even if it alone exceeds the
      # budget) — one complete file beats zero, and this still never cuts a hunk.
      if [ $((_DIFF_SHOWN_LINES + _FILE_DIFF_LINES)) -le "$_budget" ] || [ "$_DIFF_SHOWN_FILES" = "0" ]; then
        DIFF_FULL="${DIFF_FULL}${_FILE_DIFF}
"
        _DIFF_SHOWN_LINES=$((_DIFF_SHOWN_LINES + _FILE_DIFF_LINES))
        _DIFF_SHOWN_FILES=$((_DIFF_SHOWN_FILES + 1))
      else
        DIFF_OMITTED_FILES="${DIFF_OMITTED_FILES}  - ${_df}
"
      fi
    done <<< "$_changed_files"

    DIFF_HEADER="PARTIAL DIFF — showing $_DIFF_SHOWN_FILES of $_file_count files ($_DIFF_SHOWN_LINES of $DIFF_RAW_TOTAL_LINES total diff lines). DO NOT treat the omitted files below as reviewed — you have not seen them:
OMITTED FILES ($((_file_count - _DIFF_SHOWN_FILES))):
${DIFF_OMITTED_FILES}To review the FULL diff yourself: $_escape_hatch_cmd"
    DIFF_COVERAGE="partial"; DIFF_SHOWN_FILES="$_DIFF_SHOWN_FILES"; DIFF_SHOWN_LINES="$_DIFF_SHOWN_LINES"; DIFF_OMITTED_LIST="$DIFF_OMITTED_FILES"
  fi
  return 0
}

# _gate_review_task_body — the judging text. Reads the caller-declared locals of gate_render_review_task
# (dynamic scope), named exactly as the dispatcher always named them so this text is the original heredoc.
_gate_review_task_body() {
  cat <<TASK
QUALITY GATE REVIEW — You are reviewer $i of $REQUIRED_REVIEWERS for branch: $BRANCH
Author (EXCLUDED from reviewing): $AUTHOR
Rig: $RIG
Branch SHA: $BRANCH_SHA

YOUR REVIEW LENS: $REVIEWER_LENS

CHANGED FILES:
$CHANGED_FILES

DIFF SUMMARY:
$DIFF_SUMMARY

$DIFF_HEADER
$DIFF_FULL

--- YOUR TASK ---
Review this diff adversarially using ONLY your assigned lens above.
You must NOT know or consider what the other reviewers think (you are independent).
This author ($AUTHOR) cannot be a reviewer of their own work.

REFUTATION PASS — FACT-CHECK, NOT A SEVERITY FILTER:
For EVERY issue you are about to raise, RE-READ the exact changed lines in the
diff and verify the defect is actually there: is it really present in THIS
diff, at the lines you cite, given the surrounding context — or are you
pattern-matching on superficially-similar code, or assuming context you did not
actually verify in the diff? This refutation pass asks only one question —
does the defect exist in the code? — and is never a filter on how severe or
how certain the issue feels.

WHAT BLOCKS (verdict FAIL): any defect you can ground in specific changed
lines that could cause incorrect behavior, a failing test, data loss, or a
misleading result/log/comment.
WHAT DOES NOT BLOCK: pure style or naming preferences with no behavioral
effect — report these too, just do not fail the verdict on them alone.
LOW CONFIDENCE: if you are not sure whether something is really a defect,
RE-READ the surrounding code until you can decide either way — never silence
or drop a finding just because you are unsure.
Every issue that survives the fact-check gets reported at its real severity,
blocking or not — nothing you found gets dropped silently. Your verdict is
FAIL only if at least one blocking issue survives the fact-check; otherwise
it is PASS, with any non-blocking findings still listed below.
WHY THIS MATTERS: this gate fails on ANY single reviewer FAIL, so a
false-positive FAIL is expensive — it forces a full re-dispatch + re-work cycle
on correct code. Be adversarial about whether the CODE actually has the
defect, never about whether a real finding deserves to be reported: verify
each issue is real, then report everything real you find, at its true severity.
TASK
}

# _gate_review_task_verdict_bead — where the gate's reviewer records its verdict: a verdict bead.
_gate_review_task_verdict_bead() {
  cat <<TASK
After completing your review, record your verdict with EXACTLY these bash commands:

bd -C "$GC_CITY" label remove "$VERDICT_BEAD_ID" "verdict:pending"
# If PASS:
bd -C "$GC_CITY" label add "$VERDICT_BEAD_ID" "verdict:PASS"
bd -C "$GC_CITY" comment "$VERDICT_BEAD_ID" "VERDICT: PASS
Summary: <2-3 sentence summary of what you checked and why it passes your lens>
Non-blocking findings: <one per line as severity: description, or none>"
bd -C "$GC_CITY" close "$VERDICT_BEAD_ID"

# If FAIL:
# bd -C "$GC_CITY" label add "$VERDICT_BEAD_ID" "verdict:FAIL"
# bd -C "$GC_CITY" comment "$VERDICT_BEAD_ID" "VERDICT: FAIL
# Blocking issue 1: <description>
# Blocking issue 2: <description> (if any)
# Non-blocking findings: <one per line as severity: description, or none>"
# bd -C "$GC_CITY" close "$VERDICT_BEAD_ID"

Run those commands and then exit your session. Do not start other work.
TASK
}

# _gate_review_task_verdict_text — where the builder's pre-gate reviewer records its verdict: its final message.
# There is no verdict bead and no gate here, so the reviewer must NOT run bd or gc.
_gate_review_task_verdict_text() {
  cat <<TASK
After completing your review, deliver your verdict as the FINAL TEXT of your last message.
This is the builder pre-submission run of the gate review: there is no verdict bead and
nothing to record, so do NOT run bd or gc and do not try to write anywhere.
Use EXACTLY this format, starting the verdict at the beginning of a line:

# If PASS:
VERDICT: PASS
Summary: <2-3 sentence summary of what you checked and why it passes your lens>
Non-blocking findings: <one per line as severity: description, or none>

# If FAIL:
VERDICT: FAIL
Blocking issue 1: <description>
Blocking issue 2: <description> (if any)
Non-blocking findings: <one per line as severity: description, or none>

Then stop. Do not start other work.
TASK
}

# gate_render_review_task <reviewer_index> <required_reviewers> <branch> <author> <rig> <branch_sha> <lens>
#                         <changed_files> <diff_summary> <diff_header> <diff_full> <gc_city> <verdict_bead_id>
#                         [verdict_mode]
#   verdict_mode  bead (default) — the gate: the tail tells the reviewer to record its verdict on <verdict_bead_id>.
#                 text           — the builder pre-gate: the tail asks for the verdict as final text;
#                                  <gc_city> and <verdict_bead_id> are unused and may be empty.
#   Returns 2 (and prints nothing on stdout) for an unknown mode, or for bead mode with no verdict bead: a
#   task that tells the reviewer to write to bead "" would be read as a working prompt and is the worst answer.
gate_render_review_task() {
  local i="${1:-}" REQUIRED_REVIEWERS="${2:-}" BRANCH="${3:-}" AUTHOR="${4:-}" RIG="${5:-}" BRANCH_SHA="${6:-}"
  local REVIEWER_LENS="${7:-}" CHANGED_FILES="${8:-}" DIFF_SUMMARY="${9:-}" DIFF_HEADER="${10:-}" DIFF_FULL="${11:-}"
  local GC_CITY="${12:-}" VERDICT_BEAD_ID="${13:-}" _mode="${14:-bead}"
  case "$_mode" in
    bead)
      if [ -z "$VERDICT_BEAD_ID" ] || [ -z "$GC_CITY" ]; then
        echo "gate_render_review_task: bead mode needs gc_city and verdict_bead_id" >&2
        return 2
      fi
      _gate_review_task_body
      printf '\n'
      _gate_review_task_verdict_bead
      ;;
    text)
      _gate_review_task_body
      printf '\n'
      _gate_review_task_verdict_text
      ;;
    *)
      echo "gate_render_review_task: unknown verdict_mode: $_mode" >&2
      return 2
      ;;
  esac
}
