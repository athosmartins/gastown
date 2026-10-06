#!/usr/bin/env bash
# selftest-fail-closed.lib.sh — SOURCED by selftests (never run on its own): a selftest
# that dies before its summary must FAIL, not exit 0. ga-avma7j.
#
# THE BUG. A selftest under `set -u` that evals code it extracted from a live script
# (SELFTEST-EXTRACT) dies on the spot when that code reads a variable the harness never
# initialised — and when the selftest also has an EXIT trap whose last command succeeds
# (`trap 'rm -rf "$WORK_DIR"' EXIT`), /bin/bash 3.2 — the shell the dispatcher and the
# gate run on — ends the process with that trap's status, 0. No FAIL line, no summary,
# every assertion after the abort silently never ran, and the run reads as green. Bash 5.x
# keeps the abort's status 1, so the same file looked fine under the PATH bash. A trap
# that merely re-exits with the `$?` it saw does not fix it: on 3.2 that `$?` can already
# be 0 (measured). And when the eval is written `eval "$code" 2>"$ERR_F"`, the shell dies
# with fd 2 still pointed at $ERR_F, so the abort message — the cause — lands in a file
# the cleanup then deletes: nothing is printed anywhere.
#
# THE FIX, in three parts:
#   1. do not trust `$?`: fail the run unless the selftest says it reached its summary;
#   2. keep a non-zero status when there already is one (a deliberate `exit 2` after arming
#      stays 2). A TERM'd run also ends 143, but that is bash re-raising the signal after the
#      trap, not this step — the banner's "exit status seen" can read 0 there;
#   3. report on fd 3, a copy of the real stderr taken when the trap is armed. The file the
#      selftest sends stderr to ($SELFTEST_ERR_FILE) keeps its content after the step that wrote
#      it returns, and the lib cannot tell from the file alone WHICH step wrote it — printing it
#      under "the step that aborted" pointed the reader at the wrong step. So the lib claims only
#      what the selftest declared (selftest_step_begin/_end), and the report says which case it is:
#        - a step is open (the selftest declared steps and the abort was inside one): shows that
#          step's stderr; says so when the file is empty, and that it is unknown when the file is gone;
#        - steps are declared but none is open: says the abort was outside any step and shows nothing
#          (the file is an earlier step's text);
#        - the selftest declares NO steps at all: says it cannot tell which step wrote the file, and
#          shows it anyway under that label (it may be the only record of the cause) — silence or a
#          confident "not inside a step" here would be a claim the lib cannot back;
#        - the selftest sets no $SELFTEST_ERR_FILE: says nothing about any file.
#
# WHY THIS LIVES IN ITS OWN FILE and not inside the selftest: the quality gate's base-commit
# test check (quality-gate-guard.sh, ga-rstae, A/B arm B) overlays the BRANCH's copy of each
# changed `*.selftest.sh` onto a base checkout. A fix written inside the selftest travels to
# the base with its own test and passes there. Here, under a name that is not
# `*.selftest.sh`, it is not carried over: on the base the selftest cannot find this file,
# refuses to start, and fails for the honest reason (same reasoning as
# selftest-tmproot-tripwire.lib.sh).
#
# Usage (the selftest keeps `set -euo pipefail`; this file never calls `set` and only
# defines functions):
#     . "$SELF_DIR/selftest-fail-closed.lib.sh" || { echo "FATAL: cannot source …" >&2; exit 2; }
#     cleanup() { rm -rf "$WORK_DIR"; }          # optional: what the selftest's own EXIT trap did
#     SELFTEST_ERR_FILE="$WORK_DIR/stderr"       # optional: where the selftest sends stderr of evaled code
#     selftest_fail_closed_arm cleanup           # replaces `trap '…' EXIT`
#     …
#     # around EVERY evaluation whose stderr goes to $SELFTEST_ERR_FILE (truncate the file first):
#     : > "$SELFTEST_ERR_FILE"; selftest_step_begin
#     eval "$code" 2>"$SELFTEST_ERR_FILE"
#     selftest_step_end $?                       # returns that status unchanged; never reached if the eval aborts
#     # (optional: a selftest that sets SELFTEST_ERR_FILE but never calls selftest_step_begin still gets
#     #  its file printed on an abort, labelled "unknown which step wrote it" — see part 3)
#     …
#     selftest_summary_reached                   # as the LAST step before the final PASS/FAIL line and exit
# Arm it ONCE, and after any early `exit 2` precondition checks: those say why they stopped
# themselves, and arming earlier would add a second, misleading "ended before its summary".

SELFTEST_SUMMARY_REACHED=0
SELFTEST_CLEANUP_FN=""
SELFTEST_ERR_FILE="${SELFTEST_ERR_FILE:-}"
SELFTEST_STEP_OPEN=0
SELFTEST_STEPS_USED=0   # 1 once the selftest has called selftest_step_begin: it declares its steps

selftest_fail_closed_arm() {  # $1 = optional cleanup function, run on every exit
  SELFTEST_CLEANUP_FN="${1:-}"
  SELFTEST_SUMMARY_REACHED=0
  SELFTEST_STEP_OPEN=0
  SELFTEST_STEPS_USED=0
  exec 3>&2
  trap _selftest_fail_closed_on_exit EXIT
}

selftest_summary_reached() { SELFTEST_SUMMARY_REACHED=1; }

# A "step" is one evaluation whose stderr goes to $SELFTEST_ERR_FILE. Call selftest_step_begin right
# after truncating the file, so that whatever the file holds while the step is open was written BY it.
# A selftest that never calls this declares no steps: the lib cannot tell whether an abort was inside one.
selftest_step_begin() { SELFTEST_STEP_OPEN=1; SELFTEST_STEPS_USED=1; }
# $1 = the status of the step; returned unchanged, so wrapping an eval does not change what the caller sees.
selftest_step_end() { SELFTEST_STEP_OPEN=0; return "${1:-0}"; }

_selftest_fail_closed_on_exit() {
  local rc=$?
  if [ "$SELFTEST_SUMMARY_REACHED" != "1" ]; then
    {
      echo ""
      echo "FATAL: selftest ended before its summary (exit status seen: $rc) — the run ABORTED; nothing after the last line above ran. This is not a pass."
      if [ -n "$SELFTEST_ERR_FILE" ]; then
        if [ "$SELFTEST_STEPS_USED" != "1" ]; then
          # No step was ever declared, so "was the abort inside a step?" has no answer here — it must not
          # be answered "no" (that drops the cause for a selftest that redirects 2>"$ERR_F" without the
          # step API). Say it is unknown, and show the file: it may be the only record of the cause.
          if [ -s "$SELFTEST_ERR_FILE" ]; then
            echo "  this selftest declares no captured steps (selftest_step_begin/_end), so it is unknown which step wrote $SELFTEST_ERR_FILE — it may hold the cause of the abort or the stderr of an earlier step:"
            sed 's/^/    /' "$SELFTEST_ERR_FILE"
          elif [ -e "$SELFTEST_ERR_FILE" ]; then
            echo "  this selftest declares no captured steps, so it is unknown whether the abort was inside one; $SELFTEST_ERR_FILE is empty."
          else
            echo "  this selftest declares no captured steps, so it is unknown whether the abort was inside one, and $SELFTEST_ERR_FILE does not exist, so what was written to it is unknown."
          fi
        elif [ "$SELFTEST_STEP_OPEN" = "1" ]; then
          if [ -s "$SELFTEST_ERR_FILE" ]; then
            echo "  the abort happened INSIDE a captured step; that step's stderr:"
            sed 's/^/    /' "$SELFTEST_ERR_FILE"
          elif [ -e "$SELFTEST_ERR_FILE" ]; then
            echo "  the abort happened INSIDE a captured step, which had written nothing to its stderr."
          else
            # -s is false for an empty file AND for a missing one; only the first is "wrote nothing".
            echo "  the abort happened INSIDE a captured step, but $SELFTEST_ERR_FILE does not exist, so what that step wrote to stderr is unknown."
          fi
        else
          echo "  the abort did NOT happen inside a captured step (selftest_step_begin/_end): $SELFTEST_ERR_FILE is not shown, because anything in it predates the abort — look at the lines above."
        fi
      fi
    } >&3
    [ "$rc" -ne 0 ] || rc=1
  fi
  if [ -n "$SELFTEST_CLEANUP_FN" ]; then "$SELFTEST_CLEANUP_FN" || true; fi
  exit "$rc"
}
