#!/usr/bin/env bash
# pilot-dispatcher.crew-stale-reclaim-no-branch.selftest.sh — regression
# harness for ga-5skqtm: _pilot_crew_stale_reclaim (Stage 1.5, ga-c9qj8) calls
# _beadid_branch_signal via a BARE assignment
# (`_cs_bs="$(_beadid_branch_signal "$_cs_id" "$_cs_row")"`, no `|| true`)
# under this file's `set -euo pipefail` (L74). _beadid_branch_signal's OWN
# doc comment (L5449-5451) documents exit 1 + empty stdout as the
# INTENTIONAL, designed "no branch found anywhere" signal — exactly the
# condition this reclaim function exists to detect (a crew-assigned bead
# stale > PILOT_STUCK_INFLIGHT_HOURS with genuinely no crew/fix branch, i.e.
# "never engaged"). Under set -e, that legitimate non-zero exit at the bare
# assignment aborts the WHOLE pilot-dispatcher sweep immediately — before
# the very `if [ -z "$_cs_bs" ]` check that exists to interpret it.
#
# Every sweep hits this whenever ANY stale, crew-assigned, never-branched
# bead exists anywhere in the in-flight set — measured live 2026-09-12
# 04:10-04:23 (wa-90omi): 3/3 sweeps with such a bead died with exit=1
# (auto-heal exhausted, heals-exhausted:3); 5/5 sweeps with no such bead
# completed normally. No dispatch happens city-wide while this holds.
#
# This exact bug CLASS — a bare assignment propagating a legitimate
# non-zero "not found" return through set -e into a fatal script abort —
# was already found and fixed ONCE in a SIBLING function in this very file:
# ga-8w22n, _beadid_matched_crew_branch_ref's own
# `_match=$(grep -m 1 -iE "$_re" <<< "$_refs") || true` (see its comment
# ~L5405-5418: "reproduced live: 15/15 runs died with exit 141 (SIGPIPE)").
# This newer call site (Stage 1.5, added 2026-09-10 for ga-c9qj8) missed the
# same guard.
#
# Acceptance criteria under test (bead ga-5skqtm):
#   AC1 (THE bug). A stale, crew-assigned, NEVER-BRANCHED bead in the input
#        set must not abort the calling script — mirrors dispatcher L6604,
#        where _pilot_crew_stale_reclaim is called as a bare, unprotected
#        statement: any non-zero return there kills the whole sweep, so
#        surviving IS the assertion.
#   AC2 (regression guard). The SAME never-branched bead must still actually
#        be reclaimed (the bd mutation calls fire) — the fix must not
#        accidentally suppress the reclaim itself while merely surviving.
#   AC3 (positive control). A stale, crew-assigned bead WITH a branch found
#        must survive AND must NOT be reclaimed (no bd mutation calls) —
#        proves the fix does not loosen the "leave it alone if a branch
#        exists" safety property the function exists to preserve.
#   AC4 (positive control). A stale bead assigned to a POOL worker
#        (wa-worker-3) must survive AND must NOT be reclaimed (out of scope
#        per the function's own case-statement carve-out) — proves the fix
#        does not disturb the pool-worker exclusion.
#
# Run against the pre-fix dispatcher (bare `_cs_bs=$(...)`, no `|| true`),
# AC1/AC2 fail — the calling context dies instead of completing — that
# failure is what proves this harness catches the bug, not just a syntax
# check. Run again post-fix (`|| true` added), all 4 scenarios pass.
#
# Runs entirely against ONE extracted real function
# (_pilot_crew_stale_reclaim) with every dependency STUBBED
# (_ownership_guard_repos, _beadid_branch_signal, bd, warn) — no live
# bd/gc/Dolt/git required, safe on a live host. Same awk/sed-extraction
# idiom as this file's siblings (e.g.
# pilot-dispatcher.reclaim-anchor-newline.selftest.sh). The
# _beadid_branch_signal stub mirrors ONLY its documented external contract
# (exit 1 + empty stdout = no branch; exit 0 + "block\t<ref>" = found) —
# not its internals — which is exactly the contract this bug is about.
#
# Exit 0 iff all assertions hold.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-stale-reclaim-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

RECLAIM_FN="$(sed -n '/^_pilot_crew_stale_reclaim() {/,/^}$/p' "$DISPATCHER")"
if [ -z "$RECLAIM_FN" ]; then
  echo "FATAL: _pilot_crew_stale_reclaim() not found in $DISPATCHER" >&2
  exit 2
fi

# run_reclaim <in-flight-json> <branch-signal-mode: noref|found> -> sets
# $RC_EXIT to the exit code of the CALLING context, mirroring dispatcher
# L6604's bare unprotected call exactly (real set -euo pipefail, real
# extracted function, bare top-level invocation — nothing wrapping it).
# Stub bd(1) invocations land in $WORK/bd.log (empty = nothing reclaimed).
run_reclaim() {
  local input="$1" bs_mode="$2"
  : > "$WORK/bd.log"
  cat > "$WORK/run.sh" <<EOF
set -euo pipefail
warn() { echo "[WARN] \$*" >&2; }
PILOT_STUCK_INFLIGHT_HOURS="\${PILOT_STUCK_INFLIGHT_HOURS:-2}"
_ownership_guard_repos() { return 0; }
# Mirrors the REAL _beadid_branch_signal's documented external contract
# (dispatcher L5449-5451): exit 1 + empty stdout = "no branch found
# anywhere" (intentional). exit 0 + "block\t<ref>" = a branch was found.
_beadid_branch_signal() {
  if [ "$bs_mode" = "noref" ]; then
    return 1
  fi
  printf 'block\tsome-ref'
  return 0
}
bd() { echo "bd \$*" >> "$WORK/bd.log"; return 0; }
$RECLAIM_FN
_pilot_crew_stale_reclaim '$input' 9999999999
EOF
  bash "$WORK/run.sh" >"$WORK/run.stdout" 2>"$WORK/run.stderr"
  RC_EXIT=$?
}

BASE='"updated_at":"2020-01-01T00:00:00Z"'

# ════════════════════════════════════════════════════════════════════════════
echo "Scenario 1 (AC1 — THE bug): stale crew bead, NO branch anywhere — must not abort"
IN1="[{\"id\":\"wa-90omi\",\"_rig_db\":\"/fake/wa\",\"assignee\":\"batista-wa\",$BASE}]"
run_reclaim "$IN1" "noref"
[ "$RC_EXIT" -eq 0 ] \
  && ok "AC1: never-branched stale bead does not abort the caller (exit $RC_EXIT)" \
  || bad "AC1: caller aborted (exit $RC_EXIT) — set -e killed the sweep (stderr: $(cat "$WORK/run.stderr" 2>/dev/null))"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 2 (AC2): same bead — the reclaim itself must still fire"
if grep -q "wa-90omi" "$WORK/bd.log" 2>/dev/null; then
  ok "AC2: wa-90omi was actually reclaimed ($(wc -l < "$WORK/bd.log" | tr -d ' ') bd call(s))"
else
  bad "AC2: no bd mutation fired for wa-90omi — reclaim silently suppressed (bd.log: $(cat "$WORK/bd.log" 2>/dev/null))"
fi

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 3 (AC3, positive control): stale crew bead WITH a branch — survive, don't reclaim"
IN3="[{\"id\":\"wa-hasbr1\",\"_rig_db\":\"/fake/wa\",\"assignee\":\"batista-wa\",$BASE}]"
run_reclaim "$IN3" "found"
if [ "$RC_EXIT" -eq 0 ] && ! grep -q "wa-hasbr1" "$WORK/bd.log" 2>/dev/null; then
  ok "AC3: branched bead survives and is left alone (exit $RC_EXIT, not reclaimed)"
else
  bad "AC3: exit=$RC_EXIT, bd.log: $(cat "$WORK/bd.log" 2>/dev/null)"
fi

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 4 (AC4, positive control): stale bead assigned to a POOL worker — out of scope"
IN4="[{\"id\":\"wa-pool1\",\"_rig_db\":\"/fake/wa\",\"assignee\":\"wa-worker-3\",$BASE}]"
run_reclaim "$IN4" "noref"
if [ "$RC_EXIT" -eq 0 ] && ! grep -q "wa-pool1" "$WORK/bd.log" 2>/dev/null; then
  ok "AC4: pool-worker-assigned bead survives and is left alone (exit $RC_EXIT, not reclaimed)"
else
  bad "AC4: exit=$RC_EXIT, bd.log: $(cat "$WORK/bd.log" 2>/dev/null)"
fi

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "SELFTEST PASS"
  exit 0
else
  echo "SELFTEST FAIL"
  exit 1
fi
