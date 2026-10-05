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
#   2. keep a non-zero status when there already is one (a TERM'd run stays 143);
#   3. report on fd 3, a copy of the real stderr taken when the trap is armed, and print
#      what the aborted step wrote to $SELFTEST_ERR_FILE (when the selftest has one).
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
#     selftest_summary_reached                   # as the LAST step before the final PASS/FAIL line and exit
# Arm it ONCE, and after any early `exit 2` precondition checks: those say why they stopped
# themselves, and arming earlier would add a second, misleading "ended before its summary".

SELFTEST_SUMMARY_REACHED=0
SELFTEST_CLEANUP_FN=""
SELFTEST_ERR_FILE="${SELFTEST_ERR_FILE:-}"

selftest_fail_closed_arm() {  # $1 = optional cleanup function, run on every exit
  SELFTEST_CLEANUP_FN="${1:-}"
  SELFTEST_SUMMARY_REACHED=0
  exec 3>&2
  trap _selftest_fail_closed_on_exit EXIT
}

selftest_summary_reached() { SELFTEST_SUMMARY_REACHED=1; }

_selftest_fail_closed_on_exit() {
  local rc=$?
  if [ "$SELFTEST_SUMMARY_REACHED" != "1" ]; then
    {
      echo ""
      echo "FATAL: selftest ended before its summary (exit status seen: $rc) — the run ABORTED; nothing after the last line above ran. This is not a pass."
      if [ -n "$SELFTEST_ERR_FILE" ] && [ -s "$SELFTEST_ERR_FILE" ]; then
        echo "  stderr of the step that aborted:"
        sed 's/^/    /' "$SELFTEST_ERR_FILE"
      fi
    } >&3
    [ "$rc" -ne 0 ] || rc=1
  fi
  if [ -n "$SELFTEST_CLEANUP_FN" ]; then "$SELFTEST_CLEANUP_FN" || true; fi
  exit "$rc"
}
