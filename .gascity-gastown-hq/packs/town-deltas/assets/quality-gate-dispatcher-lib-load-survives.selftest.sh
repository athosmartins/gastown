#!/usr/bin/env bash
# quality-gate-dispatcher-lib-load-survives.selftest.sh (ga-92iqox, rewritten ga-q8mr6r)
#
# Proves ONE thing: quality-gate-dispatcher.sh's LIB-LOAD phase — everything it
# runs from the top of the file up to the GATE_DISPATCHER_LIB_ONLY cutoff (the
# sourcing of scripts/git-lock-hygiene.sh and the sibling libs) — survives its
# own `set -euo pipefail` and hands control back. The environment is the
# plist's OWN (derived live from the plist, never hardcoded), cwd=/, and
# /bin/bash 3.2 (what launchd runs).
#
# WHAT IT DOES NOT PROVE (read this before trusting a green run): it does not
# guard the ga-92iqox mechanism itself. That outage (2026-09-15 06:09-06:34,
# ~25min, revert 8e5b87763) came from a bare `_glh_top=$(git rev-parse ...)`
# in git-lock-hygiene.sh's root-resolution loop dying under errexit. Since
# ga-kimlod that loop does not run in lib mode (the mode the dispatcher sources
# in), so this test cannot reach it: dropping the `|| _glh_top=""` guard leaves
# this test green (measured 2026-09-25 on a scratch copy). That mechanism is
# guarded by `git-lock-hygiene.sh --selftest` T23-T25 (hermetic; with the guard
# dropped T23 dies rc=128 and T24/T25 go red, same measurement). What is left
# here is the CLASS: a statement in the lib-load phase that kills the
# dispatcher under errexit before it logs a line, for any reason.
#
# WHY IT LOADS THE LIB PHASE ONLY (ga-q8mr6r): the first version ran a FULL
# `DRY_RUN=1 timeout 90 bash quality-gate-dispatcher.sh` against the production
# city and the production Dolt. That was wrong three ways, all measured:
#   1. It exited 124 deterministically on main. A full sweep is not a 90s job —
#      the dispatcher's own comments record Phase C alone at 500-900s+ under
#      Dolt latency — so "sweep finished inside 90s" measured load, not the fix.
#   2. Its second assertion read the PRODUCTION log for a "Dispatcher sweep
#      start" line, which any real launchd sweep writes during the window —
#      a false positive by construction, it never proved THIS run logged it.
#   3. DRY_RUN=1 is not read-only: the sweep claims markers, spawns reviewers
#      and runs the git-lock hygiene against production, concurrently with the
#      real dispatcher instances.
# Loading to the cutoff removes all three: no sweep runs, and the production
# dispatcher log is neither read nor written by this test (the
# `exec >> "$LOG"` redirect and the `log()` function both come AFTER the
# cutoff).
#
# Survival is proven with a POSITIVE control, not an exit code alone: the
# dispatcher is `source`d by a wrapper that prints a sentinel only if control
# comes back after the lib-load. A dispatcher that dies in the lib-load (errexit
# — the ga-92iqox signature) never reaches the sentinel; one that exits 0
# early is not mistaken for a survivor either.
#
# Side effects: the lib phase is expected to write nothing (lib mode of
# git-lock-hygiene.sh is pure since ga-kimlod). GIT_LOCK_LOG and NOTIFY_BIN are
# still pointed at a scratch dir as a fence, so that if that purity ever
# regressed the write would land in scratch and not in the production hygiene
# log or a real notify. Nothing here asserts that scratch stays empty.
#
# Not a live-system test: no gc, no Dolt, no network. It reads the plist
# (plutil, read-only) and sources the real dispatcher and its libs from the
# production tree, so it depends on that tree and the plist being present.
#
# Test seam (mutation proofs only): QG_LIBLOAD_DISPATCHER points the test at a
# different dispatcher file; QG_LIBLOAD_TIMEOUT overrides the backstop below.
#
# Exit 0 iff the assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${QG_LIBLOAD_DISPATCHER:-$SELF_DIR/quality-gate-dispatcher.sh}"
PLIST="$HOME/Library/LaunchAgents/com.gascity.quality-gate-dispatcher.plist"
# Backstop only. The lib-load has no sweep in it and, since ga-kimlod, makes no
# gc call; it takes a fraction of a second, so anything near this bound is a
# real hang.
LIBLOAD_TIMEOUT="${QG_LIBLOAD_TIMEOUT:-120}"
# launchd runs the dispatcher under /bin/bash (macOS 3.2.57), NOT whichever
# `bash` the plist PATH happens to resolve first (Homebrew 5.x on this host).
# Bash-version differences are exactly what silently break sourced libs here.
LAUNCHD_BASH=/bin/bash

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
finish() {
  echo "== lib-load-survives: PASS=$PASS FAIL=$FAIL =="
  [ "$FAIL" -eq 0 ]
  exit $?
}

echo "== quality-gate-dispatcher-lib-load-survives.selftest =="

if [ ! -r "$DISPATCHER" ]; then
  bad "dispatcher not found/readable at $DISPATCHER"
  finish
fi
if [ ! -r "$PLIST" ]; then
  bad "plist not found/readable at $PLIST — cannot derive its real environment (never hardcode it, it drifts)"
  finish
fi
if [ ! -x "$LAUNCHD_BASH" ]; then
  bad "$LAUNCHD_BASH not executable — cannot reproduce launchd's shell"
  finish
fi

# Derive the plist's ACTUAL environment rather than hardcoding a copy of it
# here (a hardcoded copy is exactly the kind of doc-vs-live drift this city's
# memory repeatedly warns about). Mirrors the diagnostic recipe already
# established for this exact daemon (gate-dispatcher-sourced-lib-set-e-
# silent-exit-128 memory).
PLIST_PATH="$(plutil -extract EnvironmentVariables.PATH raw "$PLIST" 2>/dev/null)"
PLIST_GC_CITY="$(plutil -extract EnvironmentVariables.GC_CITY_PATH raw "$PLIST" 2>/dev/null)"
PLIST_DOLT_PORT="$(plutil -extract EnvironmentVariables.BEADS_DOLT_PORT raw "$PLIST" 2>/dev/null)"
if [ -z "$PLIST_PATH" ] || [ -z "$PLIST_GC_CITY" ]; then
  bad "could not extract PATH/GC_CITY_PATH from $PLIST — plist shape drifted, update this test's extraction"
  finish
fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/qg-libload.XXXXXX")" || { bad "mktemp -d failed"; finish; }
trap '[ -n "${SCRATCH:-}" ] && [ -d "$SCRATCH" ] && rm -rf "$SCRATCH"' EXIT

# Scratch fence for the lib's log and notify hook (see "Side effects" above).
# The stub, if ever called, just records that and exits 0.
GLH_LOG="$SCRATCH/git-lock-hygiene.jsonl"
NOTIFY_STUB="$SCRATCH/notify-stub"
printf '#!/bin/sh\necho "$@" >> "%s/notify.calls"\nexit 0\n' "$SCRATCH" > "$NOTIFY_STUB"
chmod +x "$NOTIFY_STUB"

# The probe runs INSIDE the sourcing shell, so `set -euo pipefail` from the
# dispatcher's own line 30 stays in force when control returns here — a death in
# the lib-load takes the wrapper down before the sentinel below prints.
SURVIVED_MARK="__QG_LIBLOAD_SURVIVED__"
_probe='source "$1"; printf "%s\n" "'"$SURVIVED_MARK"'"'

# The real check: load the dispatcher's lib phase exactly as launchd would
# (minimal env, cwd=/, no WorkingDirectory, /bin/bash), stopping at the
# GATE_DISPATCHER_LIB_ONLY cutoff so no sweep runs and no production log is
# touched.
_out=$(cd / && env -i HOME="$HOME" PATH="$PLIST_PATH" GC_CITY_PATH="$PLIST_GC_CITY" \
  ${PLIST_DOLT_PORT:+BEADS_DOLT_PORT="$PLIST_DOLT_PORT"} \
  GATE_DISPATCHER_LIB_ONLY=1 GIT_LOCK_LOG="$GLH_LOG" NOTIFY_BIN="$NOTIFY_STUB" \
  timeout "$LIBLOAD_TIMEOUT" "$LAUNCHD_BASH" -c "$_probe" _ "$DISPATCHER" 2>&1)
_rc=$?

case "$_out" in
  *"$SURVIVED_MARK"*) _survived=1 ;;
  *)                  _survived=0 ;;
esac

# Four failure shapes are told apart, because each points somewhere different:
# a hang, an early clean exit, a death before control returned, and a nonzero
# exit AFTER control returned.
if [ "$_rc" -eq 0 ] && [ "$_survived" -eq 1 ]; then
  ok "dispatcher lib-load survived under the plist's real environment (/bin/bash, cwd=/, set -euo pipefail) and returned control"
elif [ "$_rc" -eq 124 ]; then
  bad "lib-load did not finish in ${LIBLOAD_TIMEOUT}s — a hang in the lib-load phase (it has no sweep in it) — output: $_out"
elif [ "$_rc" -eq 0 ]; then
  bad "dispatcher exited 0 but never returned control after the lib-load (sentinel missing) — it left early, that is not survival — output: $_out"
elif [ "$_survived" -eq 1 ]; then
  bad "lib-load returned control (sentinel printed) but the shell then exited rc=$_rc — something armed in the lib-load phase (an EXIT trap?) fails on the way out — output: $_out"
else
  bad "dispatcher lib-load died with rc=$_rc before returning control (the ga-92iqox errexit signature) — output: $_out"
fi

finish
