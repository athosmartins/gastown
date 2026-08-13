#!/usr/bin/env bash
# gate-burst-addback-retire.selftest.sh (ga-pqbn0)
#
# Follow-up to ga-wcd86 (Step 0a-2 gains a session_is_booting +
# RECONVENE_GRACE_SECS guard, mirroring Step 7b's ACK path). ga-wcd86's own
# comment flagged, without changing, that the ADJACENT "ga-309v3: burst-aware
# correction" block — a flat `GATE_ADMITS_DONE * GATE_REVIEWERS_PER_RUN`
# add-back applied to LIVE_REVIEWERS on every multi-admit continuation round —
# might now be a frequent no-op or an outright double-count, and explicitly
# required "ga-pqbn0's own evidence and non-regression pass" before touching
# it. This is that evidence.
#
# ── The question ──────────────────────────────────────────────────────────
# ga-309v3's add-back exists because Step 0a-2's drained-exclusion USED TO
# read a continuation round's own just-spawned reviewers (state=creating,
# ~30-120s old, per ga-309v3's own timing model) as DRAINED — `gc session
# peek` reports "session not found" identically for a truly-dead session and
# one still inside its ~210s deferred-start boot window (ga-flfo). That read
# LIVE_REVIEWERS as 0 with a genuinely full plane: the 2026-06-12 town-wide
# deadlock. ga-309v3 compensated FROM OUTSIDE Step 0a-2 by adding back
# `admits-so-far * reviewers-per-run`, deliberately over-counting (safe: see
# BLOCKER-2 reasoning in quality-gate-headroom.selftest.sh — over-counting
# only defers admission earlier, it never causes an incorrect admit).
#
# ga-wcd86 later fixed the SAME gap at its source: Step 0a-2 now excludes a
# peek-says-gone reviewer only if it is NOT currently state=creating AND has
# been alive at least RECONVENE_GRACE_SECS (360s deployed, floor 20s)
# seconds. A continuation round's own spawns, at ~30-120s old, are always
# caught by one of those two conjuncts. So: is the add-back now redundant —
# and if it fires anyway, does it double-count reviewers Step 0a-2 already
# counted correctly?
#
# ── What this harness proves ──────────────────────────────────────────────
# AC1: drives a REAL simulated multi-round burst (not a single-session
#      scenario) through the REAL session_is_booting / session_peek_reports_
#      dead / headroom_live_reviewers (sourced from the dispatcher in
#      lib-only mode — no live Dolt/gc/launchd), and shows Step 0a-2 ALONE
#      (post-ga-wcd86) already reaches the ground-truth LIVE_REVIEWERS for
#      the burst's own prior-round spawns — the add-back only ever pushes the
#      result ABOVE ground truth from there (a double-count, not a rescue).
# AC2/non-regression: mutation-tests that this conclusion is CONTINGENT on
#      ga-wcd86's guard — reproducing the pre-ga-wcd86 formula on the exact
#      same inputs reproduces the original 2026-06-12 deadlock precondition
#      (LIVE_REVIEWERS reads 0 against a genuinely-live session), and shows
#      the add-back WAS the correct compensation in that old world. Also
#      drift-guards that ga-wcd86's guard (the sole remaining protection
#      after this retirement) is still wired, and that the add-back's
#      arithmetic has actually been removed from LIVE_REVIEWERS (not just
#      relaxed in this test file).
# Documents (not asserted pass/fail, since there is no code decision to make
# for it — it is a pre-existing, separately-accepted tradeoff, ga-07509): the
# one residual scenario where the add-back's absence changes behavior is a
# total `gc session list` read failure mid-burst, which already reads
# LIVE_REVIEWERS=0 with or without a burst in progress and is documented
# fail-open at that block's own definition.
#
# Adversarially reviewed before implementation (2026-08-13): an independent
# Explore-agent review traced LIVE_REVIEWERS through gate_headroom_decision
# and confirmed over-counting is structurally safe-direction-only in every
# branch (never an incorrect admit), confirmed the deployed-value arithmetic
# below, and flagged that evidence needed a REAL behavioral test (this file)
# rather than merely relaxing the existing static assertions — which is why
# quality-gate-headroom.selftest.sh's BLOCKER-2 / ga-991au add-back checks
# are REPLACED (not deleted) by assertions of the new invariant, wired to
# this file's existence.
#
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
hasF()    { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }
lacksF()  { if grep -qF -- "$2" "$1"; then bad "$3 — pattern still present: $2"; else ok "$3"; fi; }

echo "── 0. compile-guard: dispatcher parses cleanly ──"
if bash -n "$DISPATCHER" 2>/dev/null; then ok "dispatcher: bash -n clean"; else bad "dispatcher: bash -n FAILED"; fi

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ───────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

for _fn in session_is_booting session_peek_reports_dead headroom_live_reviewers; do
  type "$_fn" >/dev/null 2>&1 || { echo "FATAL: $_fn not defined"; exit 1; }
done

# Quiet logging noise from sourced helpers.
log()  { :; }
warn() { :; }
err()  { :; }

echo "── 1. sanity: real defaults survived sourcing ──"
eq "RECONVENE_GRACE_SECS defaults to 360 (ga-flfo)" "$RECONVENE_GRACE_SECS" "360"
eq "GATE_MAX_REVIEWERS defaults to 6" "$GATE_MAX_REVIEWERS" "6"

# ── Simulation helpers (self-contained; mirrors gate-drain-boot-grace's
# sim_step0a2_drain_decision(_prefix) exactly — this file does not source
# that one, by this repo's own convention of standalone selftests) ──────────

# sim_step0a2_drain_decision <state> <age_seconds> <grace> <peek_kind: gone|found>
#   → "drained" (excluded from LIVE_REVIEWERS) | "live" — the POST-ga-wcd86
#   per-session gate.
sim_step0a2_drain_decision() {
  local state="$1" age_seconds="$2" grace="$3" peek_kind="$4"
  local booting peek_dead
  booting=$(session_is_booting "$state")
  case "$peek_kind" in
    gone) peek_dead=$(session_peek_reports_dead 'gc session peek: session not found: "sX"') ;;
    *)    peek_dead=$(session_peek_reports_dead 'live terminal scrollback for sX') ;;
  esac
  if [ "$peek_dead" = "1" ] && [ "$booting" != "1" ] && [ "$age_seconds" -ge "$grace" ]; then
    echo "drained"
  else
    echo "live"
  fi
}

# sim_step0a2_drain_decision_prefix <peek_kind> — the ORIGINAL (pre-ga-wcd86)
# formula: trusts session_peek_reports_dead unconditionally. Used ONLY to
# reproduce the historical deadlock precondition for non-regression.
sim_step0a2_drain_decision_prefix() {
  local peek_kind="$1" peek_dead
  case "$peek_kind" in
    gone) peek_dead=$(session_peek_reports_dead 'gc session peek: session not found: "sX"') ;;
    *)    peek_dead=$(session_peek_reports_dead 'live terminal scrollback for sX') ;;
  esac
  if [ "$peek_dead" = "1" ]; then echo "drained"; else echo "live"; fi
}

# sim_burst_round_live_reviewers <reviewers> <admits_done> <reviewers_per_run> <grace> <formula:post|pre> <addback:on|off>
#   <reviewers> = space-separated "state,age_seconds" tokens — one per
#   mocked reviewer session STILL PRESENT in `gc session list` from prior
#   round(s) of this burst. All peek=gone, matching the ga-309v3 scenario
#   being modeled (a freshly-spawned reviewer's peek reads "not found" during
#   its boot window — that IS the bug shape, not an input choice). Runs each
#   through the REAL headroom_live_reviewers() exactly as Step 0a-2 does
#   (session_count, reaped=0 — none of these are TTL-stale, drained=N), then
#   optionally applies the (soon-to-be-retired) ga-309v3 arithmetic on top.
#   → echoes the resulting LIVE_REVIEWERS.
sim_burst_round_live_reviewers() {
  local reviewers="$1" admits_done="$2" reviewers_per_run="$3" grace="$4" formula="$5" addback="$6"
  local n=0 drained=0 tok state age decision live
  for tok in $reviewers; do
    state="${tok%,*}"; age="${tok#*,}"
    n=$((n+1))
    if [ "$formula" = "pre" ]; then
      decision=$(sim_step0a2_drain_decision_prefix gone)
    else
      decision=$(sim_step0a2_drain_decision "$state" "$age" "$grace" gone)
    fi
    [ "$decision" = "drained" ] && drained=$((drained+1))
  done
  live=$(headroom_live_reviewers "$n" 0 "$drained")
  if [ "$addback" = "on" ] && [ "$admits_done" -gt 0 ] 2>/dev/null; then
    live=$(( live + admits_done * reviewers_per_run ))
  fi
  echo "$live"
}

echo "── 2. AC1: post-ga-wcd86, Step 0a-2 ALONE already reaches ground truth ──"
# Round 1 of a burst: round-0 already admitted 1 CODE run (deployed
# GATE_CODE_REVIEWERS=1 -> GATE_REVIEWERS_PER_RUN=1), its 1 reviewer is now
# ~60s old, state=creating. Ground truth = 1 genuinely-existing session.
eq "(A) round1, 1 prior reviewer age=60s creating, NO add-back -> live=1 (matches ground truth)" \
  "$(sim_burst_round_live_reviewers "creating,60" 1 1 360 post off)" "1"
eq "(A2) same inputs, WITH add-back -> live=2 (OVER ground truth of 1 — a double-count)" \
  "$(sim_burst_round_live_reviewers "creating,60" 1 1 360 post on)" "2"

echo "── 3. AC1: round 2 of the deployed 3-admit burst (quantifies the +2/6 claim) ──"
# Round 2: round-0's reviewer is now ~120s old, round-1's is ~60s old. Ground
# truth = 2 genuinely-existing sessions. admits_done=2 (per ga-991au: charged
# to real admits, matching the dispatcher's own counter semantics).
eq "(B) round2, 2 prior reviewers (120s,60s) creating, NO add-back -> live=2 (ground truth)" \
  "$(sim_burst_round_live_reviewers "creating,120 creating,60" 2 1 360 post off)" "2"
eq "(B2) same inputs, WITH add-back -> live=4 (double-counts BOTH prior admits)" \
  "$(sim_burst_round_live_reviewers "creating,120 creating,60" 2 1 360 post on)" "4"
# +2 phantom reviewers against GATE_MAX_REVIEWERS=6 (unoverridden) = 33% of
# the ENTIRE calm-path ceiling consumed by double-counting alone.
_phantom=$(( 4 - 2 ))
_ceiling_pct=$(( _phantom * 100 / GATE_MAX_REVIEWERS ))
if [ "$_phantom" = "2" ] && [ "$_ceiling_pct" = "33" ]; then
  ok "(B3) quantified: +$_phantom phantom reviewers = ${_ceiling_pct}% of GATE_MAX_REVIEWERS=$GATE_MAX_REVIEWERS consumed by double-counting alone (deployed GATE_CODE_REVIEWERS=1, GATE_MAX_ADMITS_PER_SWEEP=3)"
else
  bad "(B3) quantification drifted: phantom=$_phantom ceiling_pct=$_ceiling_pct (expected 2, 33 — re-check deployed plist knobs)"
fi

echo "── 4. non-regression: the ORIGINAL 2026-06-12 deadlock precondition ──"
# Same round-1 inputs as §2, but through the PRE-ga-wcd86 formula (no
# booting/age guard at all) — reproduces the historical bug this whole
# mechanism exists to prevent: a genuinely-live session reads as 0.
eq "(C) pre-ga-wcd86 formula, NO add-back -> live=0 (the deadlock precondition: 1 real session reads as EMPTY)" \
  "$(sim_burst_round_live_reviewers "creating,60" 1 1 360 pre off)" "0"
eq "(D) pre-ga-wcd86 formula, WITH add-back -> live=1 (matches ground truth — the add-back WAS the correct fix, before ga-wcd86 existed)" \
  "$(sim_burst_round_live_reviewers "creating,60" 1 1 360 pre on)" "1"
echo "     (C)+(D) prove the add-back was NECESSARY and CORRECT pre-ga-wcd86;"
echo "     (A)+(A2) above prove the SAME unchanged formula becomes a double-count"
echo "     once Step 0a-2 fixes the root cause — the bug moved, the fix followed."

echo "── 5. mutation test: retirement's safety is CONTINGENT on ga-wcd86's guard ──"
# If ga-wcd86's guard were ever reverted (modeled here via the pre-formula)
# while the add-back stays retired, the ORIGINAL symptom returns. This is
# expected and documented, not a defect in this change — it is exactly why
# §7 drift-guards that ga-wcd86's guard is still wired in the REAL dispatcher
# (the sole remaining protection from here on).
_reverted_guard_result="$(sim_burst_round_live_reviewers "creating,60" 1 1 360 pre off)"
if [ "$_reverted_guard_result" = "0" ]; then
  ok "(E) confirmed: a reverted Step-0a-2 guard + retired add-back reproduces live=0 on a real session — this dependency is real, and is why §7 below independently drift-guards the guard's presence"
else
  bad "(E) expected the reverted-guard scenario to reproduce live=0 (got $_reverted_guard_result) — the mutation test itself is broken, investigate before trusting §2-4"
fi

echo "── 6. sanity: a genuinely-dead, non-burst reviewer is still excluded correctly ──"
# admits_done=0 (no burst in progress) + a truly old, truly gone session
# (age=400s > grace=360s, not booting) must still drain exactly as before —
# this retirement touches ONLY the add-back, never Step 0a-2's real-drain path.
eq "(F) round0 (no burst), 1 truly-dead reviewer age=400s -> live=0 (correctly excluded, unaffected by this change)" \
  "$(sim_burst_round_live_reviewers "asleep,400" 0 1 360 post off)" "0"

echo "── 7. drift-guard: the add-back's EFFECT on LIVE_REVIEWERS is gone from the real dispatcher ──"
lacksF "$DISPATCHER" '  _burst_admitted=$(( GATE_ADMITS_DONE * GATE_REVIEWERS_PER_RUN ))' \
  "the retired arithmetic no longer mutates LIVE_REVIEWERS (was the load-bearing line of the old block)"
lacksF "$DISPATCHER" '  LIVE_REVIEWERS=$(( LIVE_REVIEWERS + _burst_admitted ))' \
  "LIVE_REVIEWERS is no longer incremented by the retired add-back"
hasF "$DISPATCHER" 'ga-pqbn0' \
  "a comment trail referencing ga-pqbn0 explains the retirement at the old block's location"
hasF "$DISPATCHER" 'GATE_ADMITS_DONE * GATE_REVIEWERS_PER_RUN' \
  "the formula itself is STILL present as a diagnostic (measures what would have been added, does not apply it — permanent 'Measured' evidence trail, not a silent deletion)"

echo "── 8. drift-guard: Step 0a-2's ga-wcd86 guard — the SOLE remaining protection — is still wired ──"
hasF "$DISPATCHER" 'R_BOOTING=$(session_is_booting "$R_STATE")' \
  "Step 0a-2 still computes R_BOOTING via the real session_is_booting helper"
hasF "$DISPATCHER" 'if [ "$R_BOOTING" != "1" ] && [ "$R_AGE_SECONDS" -ge "$RECONVENE_GRACE_SECS" ]; then' \
  "drain-exclusion still requires not-booting AND past-grace before trusting peek-dead"
hasF "$DISPATCHER" 'DRAINED_REVIEWERS=$((DRAINED_REVIEWERS + 1))' \
  "DRAINED_REVIEWERS still incremented for confirmed drains — untouched by this change"

echo "── 9. drift-guard: surrounding lock/round machinery is UNTOUCHED (out of this bead's scope) ──"
hasF "$DISPATCHER" 'GATE_ADMIT_ROUND="${GATE_ADMIT_ROUND:-0}"' \
  "round counter default untouched"
hasF "$DISPATCHER" 'export GATE_ADMITS_DONE="$((GATE_ADMITS_DONE + 1))"' \
  "admits-done increment site untouched (ga-991au's admits-not-rounds counter still advances the same way)"
hasF "$DISPATCHER" 'GATE_MAX_ADMITS_PER_SWEEP" -le 6' \
  "GATE_MAX_ADMITS_PER_SWEEP upper clamp untouched"
hasF "$DISPATCHER" '[ "${GATE_LOCK_TOKEN%%:*}" = "$$" ]' \
  "lock-token pid-half self-validation untouched"

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" = "0" ]; then
  echo "PASS $PASS/$((PASS+FAIL)) — gate-burst-addback-retire selftest"
  exit 0
else
  echo "FAIL $FAIL/$((PASS+FAIL)) — gate-burst-addback-retire selftest"
  exit 1
fi
