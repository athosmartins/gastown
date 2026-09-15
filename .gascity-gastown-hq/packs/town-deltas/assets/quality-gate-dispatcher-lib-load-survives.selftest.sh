#!/usr/bin/env bash
# quality-gate-dispatcher-lib-load-survives.selftest.sh (ga-92iqox)
#
# Proves: quality-gate-dispatcher.sh, run with the plist's OWN environment
# (derived live from the plist, never hardcoded — see below) and DRY_RUN=1,
# completes a full sweep (logs "Dispatcher sweep start" and exits 0) even
# though the live rig list includes property_scrapers/lexbh — both container
# rigs whose ".git" is a gitlink into a bare repo (".repo.git"), which makes
# `git rev-parse --show-toplevel` fail (exit 128) for them.
#
# ROOT CAUSE it guards: quality-gate-dispatcher.sh sources scripts/git-lock-
# hygiene.sh with GIT_LOCK_HYGIENE_LIB=1 under its own `set -euo pipefail`,
# cwd=/ (the plist sets no WorkingDirectory). A prior fix for the gitlink
# case (a2575edb5) replaced a `||`-guarded assignment in that file's root-
# resolution loop with a bare one; the bare assignment's command substitution
# failing (exactly what git rev-parse does against property_scrapers) is a
# live errexit trigger there, and killed the dispatcher before it logged a
# single line — a real ~25min outage, 2026-09-15 06:09-06:34. Revert:
# 8e5b87763. Fix + full root-cause: scripts/git-lock-hygiene.sh's own
# --selftest T23-T25 (the primary, hermetic, mutation-tested regression
# coverage for the actual mechanism). THIS file is the coarser end-to-end
# check Mayor's ga-92iqox comment (2026-09-15 09:35) additionally asked for:
# run the real dispatcher, with the real live rig list, and confirm it
# survives — not a synthetic fixture standing in for property_scrapers.
#
# NOT hermetic — unlike git-lock-hygiene.sh's own --selftest, this test
# shells out to the real `gc`/`bd` and depends on property_scrapers/lexbh
# actually existing on disk with the gitlink shape described above. If
# either ever stops being true (rigs restructured, gc unavailable), this
# test's assertions may need updating — that's expected, not a false
# positive in the mechanism it's guarding.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
PLIST="$HOME/Library/LaunchAgents/com.gascity.quality-gate-dispatcher.plist"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== quality-gate-dispatcher-lib-load-survives.selftest =="

if [ ! -r "$DISPATCHER" ]; then
  bad "dispatcher not found/readable at $DISPATCHER"
  echo "== lib-load-survives: PASS=$PASS FAIL=$FAIL =="
  exit 1
fi
if [ ! -r "$PLIST" ]; then
  bad "plist not found/readable at $PLIST — cannot derive its real environment (never hardcode it, it drifts)"
  echo "== lib-load-survives: PASS=$PASS FAIL=$FAIL =="
  exit 1
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
  echo "== lib-load-survives: PASS=$PASS FAIL=$FAIL =="
  exit 1
fi

LOG="$PLIST_GC_CITY/.gc/logs/quality-gate-dispatcher.log"
_before_lines=0
[ -r "$LOG" ] && _before_lines=$(wc -l < "$LOG" 2>/dev/null || echo 0)

# The real check: run the dispatcher exactly as launchd does (minimal env,
# cwd=/, no WorkingDirectory), DRY_RUN=1 so it never merges/pushes anything.
_out=$(cd / && env -i HOME="$HOME" PATH="$PLIST_PATH" GC_CITY_PATH="$PLIST_GC_CITY" \
  ${PLIST_DOLT_PORT:+BEADS_DOLT_PORT="$PLIST_DOLT_PORT"} \
  DRY_RUN=1 timeout 90 bash "$DISPATCHER" 2>&1)
_rc=$?

if [ "$_rc" -eq 0 ]; then
  ok "dispatcher completed a sweep and exited 0 under the plist's real environment"
else
  bad "dispatcher exited $_rc (expected 0) — output: $_out"
fi

if [ -r "$LOG" ]; then
  _after_tail=$(tail -n +"$((_before_lines + 1))" "$LOG" 2>/dev/null)
  case "$_after_tail" in
    *"Dispatcher sweep start"*) ok "dispatcher logged a fresh 'Dispatcher sweep start' line" ;;
    *) bad "no fresh 'Dispatcher sweep start' line in $LOG since this run started — dispatcher likely died before logging anything (the ga-92iqox outage signature)" ;;
  esac
else
  bad "dispatcher log not readable at $LOG — cannot confirm 'Dispatcher sweep start' was logged"
fi

echo "== lib-load-survives: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
