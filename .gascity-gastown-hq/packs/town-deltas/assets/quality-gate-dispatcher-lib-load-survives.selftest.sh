#!/usr/bin/env bash
# quality-gate-dispatcher-lib-load-survives.selftest.sh (ga-92iqox, rewritten ga-q8mr6r)
#
# Proves: quality-gate-dispatcher.sh's LIB-LOAD phase — the sourcing of
# scripts/git-lock-hygiene.sh and the sibling libs at the top of the file,
# under the dispatcher's own `set -euo pipefail`, with the plist's OWN
# environment (derived live from the plist, never hardcoded) and cwd=/ —
# survives the live rig list, which includes property_scrapers/lexbh: both
# container rigs whose ".git" is a gitlink into a bare repo (".repo.git"),
# which makes `git rev-parse --show-toplevel` fail (exit 128) for them.
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
# load the real dispatcher, with the real live rig list, and confirm it
# survives — not a synthetic fixture standing in for property_scrapers.
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
# The ga-92iqox bug lives entirely BEFORE the GATE_DISPATCHER_LIB_ONLY cutoff
# (the lib sources at the top of the file), so that is what this loads. The
# cutoff precedes `mkdir -p $LOG_DIR; exec >> $LOG` in the dispatcher, so the
# production dispatcher log is neither read nor written here.
#
# Survival is proven with a POSITIVE control, not an exit code alone: the
# dispatcher is `source`d by a wrapper that prints a sentinel only if control
# comes back after the lib-load. A dispatcher that dies in the lib-load (errexit
# — the ga-92iqox signature) never reaches the sentinel; one that exits 0
# early is not mistaken for a survivor either.
#
# Side effects are pinned away from production: git-lock-hygiene.sh's own log
# (GIT_LOCK_LOG) and its notify hook (NOTIFY_BIN) are redirected to a scratch
# dir. It still runs a real, read-only `gc rig list` (the point of the test).
#
# Three-state outcome for the live rig list, because it is load-dependent
# (`gc rig list` can take 8-17s under Dolt load, ga-eu2x, and git-lock-hygiene.sh
# degrades to a static fallback list when it fails or times out):
#   - live list resolved and a gitlink rig kept  -> PASS
#   - live list resolved but no gitlink rig      -> FAIL (topology changed: update
#     this test; deterministic, not load-dependent)
#   - degraded to the static fallback            -> SKIP, stated out loud. The
#     errexit-prone branch did not run against the live shape this time; survival
#     above is still asserted, and T23-T25 in git-lock-hygiene.sh --selftest
#     remain the primary coverage. A SKIP is never counted as a pass.
#
# NOT hermetic — it shells out to the real `gc` (read-only) and depends on
# property_scrapers/lexbh existing on disk with the gitlink shape above. If
# either ever stops being true, this test's assertions may need updating —
# that is expected, not a false positive in the mechanism it guards.
#
# Test seam (mutation proofs only): QG_LIBLOAD_DISPATCHER points the test at a
# different dispatcher file; QG_LIBLOAD_TIMEOUT overrides the backstop below.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${QG_LIBLOAD_DISPATCHER:-$SELF_DIR/quality-gate-dispatcher.sh}"
PLIST="$HOME/Library/LaunchAgents/com.gascity.quality-gate-dispatcher.plist"
# Backstop only. The lib-load has no sweep in it; its slowest legitimate step is
# git-lock-hygiene.sh's `gc rig list` (bounded at 20s inside the lib) plus one
# 2s-bounded `git rev-parse` per rig, so anything near this bound is a real hang.
LIBLOAD_TIMEOUT="${QG_LIBLOAD_TIMEOUT:-120}"
# launchd runs the dispatcher under /bin/bash (macOS 3.2.57), NOT whichever
# `bash` the plist PATH happens to resolve first (Homebrew 5.x on this host).
# Bash-version differences are exactly what silently break sourced libs here.
LAUNCHD_BASH=/bin/bash

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
skip() { SKIP=$((SKIP+1)); echo "  ~ SKIP: $1"; }
finish() {
  echo "== lib-load-survives: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
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

# Scratch redirects: git-lock-hygiene.sh's log and its notify hook. The stub
# records that it was called (so a degraded run stays visible) and exits 0.
GLH_LOG="$SCRATCH/git-lock-hygiene.jsonl"
NOTIFY_STUB="$SCRATCH/notify-stub"
printf '#!/bin/sh\necho "$@" >> "%s/notify.calls"\nexit 0\n' "$SCRATCH" > "$NOTIFY_STUB"
chmod +x "$NOTIFY_STUB"

# The probe runs INSIDE the sourcing shell, so `set -euo pipefail` from the
# dispatcher's own line 30 stays in force when control returns here — a death in
# the lib-load takes the wrapper down before either marker below prints.
SURVIVED_MARK="__QG_LIBLOAD_SURVIVED__"
ROOTS_MARK="__QG_GLH_ROOTS__="
_probe='source "$1"; printf "%s\n" "'"$SURVIVED_MARK"'"; printf "%s%s\n" "'"$ROOTS_MARK"'" "${GIT_LOCK_RIG_ROOTS:-}"'

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

if [ "$_rc" -eq 0 ] && [ "$_survived" -eq 1 ]; then
  ok "dispatcher lib-load survived under the plist's real environment (/bin/bash, cwd=/, set -euo pipefail) and returned control"
elif [ "$_rc" -eq 124 ]; then
  bad "lib-load did not finish in ${LIBLOAD_TIMEOUT}s — a hang in a sourced lib (the lib phase has no sweep in it) — output: $_out"
elif [ "$_rc" -eq 0 ]; then
  bad "dispatcher exited 0 but never returned control after the lib-load (sentinel missing) — it left early, that is not survival — output: $_out"
else
  bad "dispatcher lib-load died with rc=$_rc before returning control (the ga-92iqox errexit signature) — output: $_out"
fi

# Second assertion: the survival above was against the LIVE rig list including a
# gitlink rig, i.e. the errexit-prone branch (rev-parse fails -> `|| _glh_top=""`
# -> keep the path because it carries its own .git) actually ran. lexbh is not in
# git-lock-hygiene.sh's static fallback, so its presence in the resolved roots is
# proof of the live path + gitlink branch (show-toplevel fails for it).
_roots=$(printf '%s\n' "$_out" | sed -n "s/^${ROOTS_MARK}//p" | tail -n 1)
if [ "$_survived" -ne 1 ]; then
  skip "live rig-list check not evaluated — the lib-load itself did not survive (already reported above)"
elif [ -s "$GLH_LOG" ] && grep -q '"event":"degraded"' "$GLH_LOG" 2>/dev/null; then
  skip "git-lock-hygiene.sh degraded to its static rig-root fallback (gc rig list failed/timed out/empty — load-dependent), so the live gitlink branch did not run this time; survival is still asserted above and git-lock-hygiene.sh --selftest T23-T25 remain the primary coverage"
else
  case ":$_roots:" in
    *lexbh*|*property_scrapers*)
      case ":$_roots:" in
        *lexbh*) ok "live rig list resolved and the gitlink rig lexbh was kept (roots: $_roots)" ;;
        *)       ok "live rig list resolved and the gitlink rig property_scrapers was kept (roots: $_roots)" ;;
      esac ;;
    *) bad "live rig list resolved but neither lexbh nor property_scrapers is among the scan roots ($_roots) — rig topology changed, update this test (or a gitlink rig was dropped: the ga-92iqox class)" ;;
  esac
fi

finish
