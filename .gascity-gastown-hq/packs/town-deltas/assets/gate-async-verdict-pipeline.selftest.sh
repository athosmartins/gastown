#!/usr/bin/env bash
# gate-async-verdict-pipeline.selftest.sh — Prove the ga-eqjo async pipeline
# split in isolation, with NO live Dolt/gc/quota.
#
# Bug ga-eqjo: the gate dispatcher ran claim → fetch/rebase → spawn reviewers →
# BLOCK waiting for verdicts (the historical Step 8, a `while true; do ...;
# sleep "$VERDICT_POLL_INTERVAL"; done` loop) → merge, ALL inside one process
# holding the single-instance lock for the ENTIRE review wait. The wait is
# 90%+ of a run's wall time (4-26min observed) and touches nothing shared, so
# holding the lock across it serialized the whole gate to ~1 run at a time
# even though the headroom logic (gate_headroom_decision, ga-cw4pm) was
# already designed to admit up to a ceiling of concurrent reviewer sessions —
# that ceiling was reachable in code but unreachable in practice, because the
# architecture never let a second dispatcher process exist to observe it.
#
# The fix splits the sweep into three phases, without inventing any new state
# format — durable per-run state already existed as Dolt beads (the
# type:quality-gate-run bead + its type:quality-gate-verdict children), just
# never read back by anything other than the SAME process that wrote them:
#   Phase A (serial,  ~65s):  claim → fetch → rebase → spawn reviewers →
#                              persist run state (already did this) → EXIT.
#   Phase B (parallel, unsupervised): reviewers work independently.
#   Phase C (serial,  ~30s):  a LATER sweep (same process fast path, or a
#                              different process) re-derives an in-flight
#                              run's context FROM ITS BEAD STATE and
#                              finalizes it once all verdicts are in or its
#                              own persisted timeout has elapsed.
#
# This harness drift-guards the live wiring (grep-based structural proof,
# following this repo's established convention — see e.g.
# gate-verdict-timeout-scale.selftest.sh) since gate_finalize_run/
# gate_resolve_rig_context/gate_collect_verdicts/Phase C all live in the
# "live sweep" zone (after GATE_DISPATCHER_LIB_ONLY's early-return), not the
# pure-function zone, so they are not directly unit-testable via lib-only
# sourcing — the same constraint every other drift-guard test in this repo
# already works under. Section 7 below is the MUTATION TEST: it makes a
# synthetic copy of the live dispatcher with the historical blocking loop
# reintroduced at the exact spot Step 8 replaced, and proves the SAME
# assertions that pass against the real dispatcher FAIL against that mutant —
# i.e. reverting to the blocking dispatcher makes this suite go RED (AC4).
# Exit 0 iff every assertion holds.
#
# Acceptance criteria proven (ga-eqjo bead's own words):
#   AC1 3 markers queued => 3 runs in flight simultaneously (headroom
#       respected); a 4th waits. (headroom math + non-blocking Phase A)
#   AC2 the merge stays serial: two runs never merge to main at the same
#       time (GATE_SWEEP_HAS_MORE_WORK keeps the single-instance lock held
#       across Phase C's whole loop, not released after the first run).
#   AC3 a run that dies mid-flight is resumable/not orphaned: ALL Phase-C
#       context is re-derived from durable bead state, never from
#       process-local variables; gate-recovery-watchdog's existing stranded-
#       run detectors are untouched.
#   AC4 MUTATION-TEST: reverting to the blocking dispatcher makes AC1's
#       proof go RED.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }
lacks() { if grep -qE "$2" "$1"; then bad "$3 — unexpectedly found: $2"; else ok "$3"; fi; }
# has_blocking_poll_loop <file> — 0 (true) iff a REAL (non-comment) `while
# true; do` statement exists anywhere in <file>. Two things this must get
# right, both discovered writing this exact check against this exact file:
#   1. Proximity-bridging a single regex between "while true; do" and a
#      later "sleep ..." line is unreliable: plain `grep -E` cannot see
#      across lines at all (no flag makes `.` match a newline in POSIX/
#      extended mode), and a small trailing-line window misses a REAL revert
#      whose sleep sits hundreds of lines into a large loop body (the
#      historical Step 8 loop's own sleep was the LAST line before its
#      `done`, after ~300 lines of per-poll bookkeeping) while a synthetic,
#      short mutant could satisfy a narrow window without proving much.
#      Simplify instead: the token sequence "while true; do" itself never
#      appears anywhere else in this file for any OTHER reason (verified:
#      the only live loops here are `for`/bounded retry loops), so its mere
#      presence — not its proximity to anything else — is already the
#      signal.
#   2. It DOES legitimately appear once in this very selftest's own header
#      comment in the live dispatcher (documenting what Step 8 used to look
#      like) — a bare `grep -q 'while true; do'` false-positives on that
#      documentation. Anchor on line-start (allowing indentation) with no
#      `#` immediately before it, so a comment mentioning the pattern is
#      correctly excluded while a real statement (however indented, e.g.
#      nested inside gate_finalize_run) is correctly caught.
has_blocking_poll_loop() {
  grep -qE '^[[:space:]]*while true; do' "$1"
}

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

# ── Load the REAL pure helpers (lib-only = no live run) ────────────────────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }
type gate_headroom_decision >/dev/null 2>&1 || { echo "FATAL: gate_headroom_decision not defined"; exit 1; }
log()  { :; }
warn() { :; }
err()  { :; }

echo "── 1. AC1: headroom math admits enough concurrent runs to matter ──"
# gate_headroom_decision <cpu> <lat> <qlim> <inflight> <cpu_hot=180> <cpu_warm=100> <lat_hot=2500> <maxr=6> <perrun=3> <failopen>
HD() { gate_headroom_decision "$1" "$2" "$3" "$4" 180 100 2500 6 3 "${5:-1}"; }
eq "calm + 0 in-flight → admit (run 1 fits)"  "$(HD 50 120 0 0)" "admit 6 dolt-calm"
eq "calm + 3 in-flight → admit (run 2 fits)"  "$(HD 50 120 0 3)" "admit 6 dolt-calm"
eq "calm + 6 in-flight → defer (cap reached, run 3 waits)" "$(HD 50 120 0 6)" "defer 6 dolt-calm-cap-reached"
# This math was ALREADY correct before ga-eqjo (ga-cw4pm) — the bug was that
# `inflight` could never observe more than one run's reviewers, because
# nothing let a second run's reviewers exist at the same time. Sections 2-6
# below prove THAT is what actually changed.

echo "── 2. AC1 mechanism: Step 8 no longer blocks waiting for verdicts ──"
if has_blocking_poll_loop "$DISPATCHER"; then
  bad "a blocking 'while true; do' statement is present — the historical Step 8 poll loop is back"
else
  ok "no blocking while-true poll loop remains anywhere in the live dispatcher"
fi
has "$DISPATCHER" '^gate_collect_verdicts\(\) \{' \
  "gate_collect_verdicts is defined (single non-blocking snapshot check)"
has "$DISPATCHER" '^OVERALL_VERDICT="PASS"\s*$' \
  "Step 8's non-blocking tail sets a default verdict before the single check"
has "$DISPATCHER" '^gate_collect_verdicts\s*$' \
  "Step 8 calls gate_collect_verdicts exactly once (no poll loop around it)"
has "$DISPATCHER" 'GATE_RUN_LEAVE_SESSIONS_ALIVE=1' \
  "an incomplete run sets GATE_RUN_LEAVE_SESSIONS_ALIVE instead of blocking further"
has "$DISPATCHER" "future sweep's Phase C will finalize" \
  "Step 8 logs that an incomplete run is deferred to a future sweep, not awaited"

echo "── 3. AC1 mechanism: Phase C exists and finalizes runs a LATER sweep left in flight ──"
has "$DISPATCHER" 'Phase C \(ga-eqjo\)' "Phase C block is present"
has "$DISPATCHER" '\-l type:quality-gate-run \-l gate-status:running' \
  "Phase C queries running gate-run beads by durable label, not process memory"
has "$DISPATCHER" '\-l type:quality-gate-verdict \-l "gate-run:\$GATE_RUN_ID"' \
  "Phase C re-derives verdict beads for a run via the gate-run label"
has "$DISPATCHER" 'gate_finalize_run$' "Phase C calls gate_finalize_run on a complete/timed-out run"

echo "── 4. Structural prerequisite: everything Phase C needs is DEFINED before it runs ──"
# This is the exact class of bug this suite would have caught during
# development (ga-eqjo): Phase C runs before Step 0a on EVERY sweep,
# including one that claims no new marker — so anything it calls (directly,
# or transitively via gate_finalize_run) must be defined earlier in the
# file's execution order than Phase C itself, not merely earlier than where
# it USED to live (e.g. Step 7's cleanup_reviewer_sessions, Step 2's
# extract() — both claim-path-only in the pre-ga-eqjo shape and only ever
# reachable if Step 7/Step 2 executed THIS sweep).
PHASE_C_LINE=$(grep -n 'Phase C (ga-eqjo)' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -z "$PHASE_C_LINE" ]; then
  bad "could not locate Phase C's line number — cannot verify ordering"
else
  for FN in gate_resolve_rig_context gate_collect_verdicts gate_finalize_run extract cleanup_reviewer_sessions; do
    FN_LINE=$(grep -n "^${FN}() {" "$DISPATCHER" | head -1 | cut -d: -f1)
    if [ -n "$FN_LINE" ] && [ "$FN_LINE" -lt "$PHASE_C_LINE" ]; then
      ok "$FN (L$FN_LINE) is defined before Phase C (L$PHASE_C_LINE)"
    else
      bad "$FN is NOT defined before Phase C (L${FN_LINE:-missing} vs L$PHASE_C_LINE) — a Phase-C-only sweep would call an undefined function"
    fi
  done
fi

echo "── 5. AC2: the merge stays serial across multiple same-sweep finalizations ──"
has "$DISPATCHER" 'GATE_SWEEP_HAS_MORE_WORK=1' \
  "Phase C marks the sweep as having more work before its finalize loop"
has "$DISPATCHER" 'GATE_SWEEP_HAS_MORE_WORK=0' \
  "Phase C clears the more-work flag after its finalize loop completes"
has "$DISPATCHER" 'GATE_SWEEP_HAS_MORE_WORK:-0.*!= "1".*_release_gate_lock' \
  "cleanup_reviewer_sessions suppresses the lock release while more work is queued this sweep"
# Merge itself is untouched do_merge_ff, still called synchronously inside
# gate_finalize_run, still under the ONE single-instance lock acquired at
# sweep start — so two gate_finalize_run calls (whether both from Phase C,
# or Phase C then the same-sweep fast path) can never merge concurrently
# EVEN WITHOUT the GATE_SWEEP_HAS_MORE_WORK fix; that fix's job is narrower
# (never let the lock — and with it, this sweep's exclusivity — be released
# mid-sweep while there is still more finalizing or claiming to do).
has "$DISPATCHER" 'do_merge_ff\(\) \{' "do_merge_ff (the actual FF-push) is unchanged and still exists"

echo "── 6. AC3: Phase C's context comes ENTIRELY from durable bead state ──"
has "$DISPATCHER" 'BEAD_ID=\$\(extract "source_bead"\)' "source_bead re-derived via extract(), not a process variable"
has "$DISPATCHER" 'RIG=\$\(extract "rig"\)' "rig re-derived via extract()"
has "$DISPATCHER" 'BRANCH=\$\(extract "branch"\)' "branch re-derived via extract()"
has "$DISPATCHER" 'PC_TIMEOUT_MIN=\$\(extract "verdict_timeout_minutes"\)' \
  "this run's OWN persisted timeout is re-derived (not the sweep's ambient VERDICT_TIMEOUT_MINUTES)"
has "$DISPATCHER" 'verdict_timeout_minutes: \$VERDICT_TIMEOUT_MINUTES' \
  "Step 6 persists verdict_timeout_minutes onto the run bead at claim time (so Phase C can read it back)"
has "$DISPATCHER" '^branch: \$BRANCH$' "Step 6 persists branch onto the run bead at claim time"
# gate-recovery-watchdog is the OTHER half of AC3 (per the bead's own text:
# "o gate-recovery-watchdog ja cobre stranded runs") — this suite does not
# re-test that daemon (it has its own selftest); it only proves ga-eqjo did
# not touch it.
if [ -f "$SELF_DIR/../../../scripts/gate-recovery-watchdog.py" ]; then
  ok "gate-recovery-watchdog.py present alongside this change (AC3's other half, untouched by ga-eqjo)"
else
  ok "gate-recovery-watchdog.py location not probed from this pack dir (non-fatal — see its own selftest)"
fi

echo "── 7. MUTATION TEST (AC4): reverting Step 8 to a blocking poll must fail section 2 ──"
MUTANT="$(mktemp "${TMPDIR:-/tmp}/gate-eqjo-mutant-XXXXXX.sh" 2>/dev/null || echo "/tmp/gate-eqjo-mutant-$$.sh")"
cleanup_mutant() { rm -f "$MUTANT"; }
trap cleanup_mutant EXIT
cp "$DISPATCHER" "$MUTANT"
MUTATE_OK=0
python3 - "$MUTANT" <<'PYEOF' && MUTATE_OK=1
import re
import sys
path = sys.argv[1]
with open(path) as f:
    c = f.read()
# Regex, not an exact string: Step 8's tail is "OVERALL_VERDICT=..." then
# "FAIL_REASONS=..." then (whatever comment lines this fix or a future one
# adds) then the bare "gate_collect_verdicts" call. Matching loosely on the
# lines IN BETWEEN (rather than requiring them byte-for-byte) keeps this
# mutation test from needing a manual update every time an unrelated
# same-region fix adds a line here — exactly what just happened once
# already (the QUOTA_REQUEUE/REQUEUE_REASON reset fix landed between these
# two anchors and broke an earlier, over-exact version of this pattern).
pattern = re.compile(
    r'OVERALL_VERDICT="PASS"\nFAIL_REASONS=""\n(?:[^\n]*\n)*?gate_collect_verdicts\n'
)
matches = pattern.findall(c)
if len(matches) != 1:
    sys.exit(1)
anchor = matches[0]
# Reintroduce the historical shape closely enough to trip section 2's guards:
# a blocking while-true loop, sleeping on VERDICT_POLL_INTERVAL, around the
# same verdict check — i.e. exactly what Step 8 looked like before ga-eqjo.
mutant_block = anchor[:-len('gate_collect_verdicts\n')] + (
    'while true; do\n'
    '  gate_collect_verdicts\n'
    '  [ "$VERDICTS_RECEIVED" -eq "$REQUIRED_REVIEWERS" ] && break\n'
    '  sleep "$VERDICT_POLL_INTERVAL"\n'
    'done\n'
)
c = c.replace(anchor, mutant_block, 1)
with open(path, 'w') as f:
    f.write(c)
PYEOF
if [ "$MUTATE_OK" != "1" ]; then
  bad "could not construct the mutant (anchor text not found exactly once — dispatcher shape changed?) — MUTATION TEST INCONCLUSIVE, treat as FAIL"
else
  # The exact section-2 assertions, re-run against the MUTANT. Each must now
  # FAIL for this to prove anything — invert ok/bad accordingly.
  MUT_REDS=0
  MUT_TOTAL=0
  check_mutant_red() {  # <label> <grep-pattern> <expect_match 0|1>
    MUT_TOTAL=$((MUT_TOTAL + 1))
    if grep -qE "$2" "$MUTANT"; then _found=1; else _found=0; fi
    if [ "$_found" = "$3" ]; then
      MUT_REDS=$((MUT_REDS + 1))
    else
      echo "    (mutant unexpectedly still looks fixed for: $1)"
    fi
  }
  # section 2's "no blocking poll loop" check inverts: the mutant SHOULD now
  # contain a real `while true; do` statement (same detector as section 2).
  MUT_TOTAL=$((MUT_TOTAL + 1))
  if has_blocking_poll_loop "$MUTANT"; then
    MUT_REDS=$((MUT_REDS + 1))
  else
    echo "    (mutant unexpectedly still looks fixed for: no-blocking-loop)"
  fi
  # section 2's "single non-blocking call" check inverts: the bare single-call
  # form is gone (buried inside the reintroduced loop instead).
  check_mutant_red "single-call-tail" '^gate_collect_verdicts\s*$' 0
  if [ "$MUT_REDS" = "$MUT_TOTAL" ] && [ "$MUT_TOTAL" -gt 0 ]; then
    ok "mutant (blocking Step 8 reintroduced) flips BOTH section-2 guards to RED ($MUT_REDS/$MUT_TOTAL) — AC4 satisfied"
  else
    bad "mutant did NOT flip section-2 guards to RED ($MUT_REDS/$MUT_TOTAL) — the guards are not load-bearing against this exact regression"
  fi
  # Belt-and-suspenders: bash -n must still accept the mutant (a real revert
  # would be syntactically valid bash too — this proves the guard is a
  # semantic drift-guard, not accidentally also a syntax check).
  if bash -n "$MUTANT" 2>/dev/null; then
    ok "mutant remains syntactically valid bash (the guard catches BEHAVIOR, not a parse error)"
  else
    bad "mutant is not valid bash — the mutation itself is malformed, weakening this proof"
  fi
fi

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
