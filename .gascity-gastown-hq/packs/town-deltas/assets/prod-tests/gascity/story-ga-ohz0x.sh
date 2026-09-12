#!/usr/bin/env bash
# prod-tests/gascity/story-ga-ohz0x.sh — prod test for ga-ohz0x: VERDICTS_RE dead pattern
# removed from pipeline-throughput-heartbeat.py's _fresh_review_in_progress().
#
# Path choice: pipeline-throughput-heartbeat.plist's ProgramArguments points launchd
# DIRECTLY at $CITY/scripts/pipeline-throughput-heartbeat.py (verified by reading the
# plist, not assumed) — the gascity rig's own delivery-runbooks.toml doctrine holds for
# this file: "the HQ framework scripts run IN PLACE from the repo working tree ... the
# live scripts ARE the deployed versions the moment they exist on disk". So this checks
# $CITY/scripts/ and $CITY/packs/town-deltas/assets/ (the tracked, canonical locations),
# NOT any .gc/scripts/ copy — that directory holds a same-named but functionally distinct
# artifact family (confirmed by direct comparison: none of the three
# pipeline-throughput-heartbeat*.selftest.sh files under .gc/scripts/ is a live-updated
# mirror of what this bead touches) and checking it here would test the wrong file.
#
# Note (ga-ohz0x scope): pipeline-throughput-heartbeat.plist has KeepAlive=true — a
# persistent process, not a periodic relaunch — so a resident daemon does not reload this
# module just because the on-disk file changed. That matters for a BEHAVIOR-changing fix;
# it does not matter for this one, because the removed VERDICTS_RE branch was provably
# dead (confirmed against the live 19.8k-line dispatcher log, ga-z0xx1) — old and new code
# are behaviorally identical, so an un-restarted resident process poses no correctness gap
# for THIS diff. (The daemon_restarts gap this exposed — com.gascity.pipeline-throughput-
# heartbeat is absent from gascity's daemon_restarts list in delivery-runbooks.toml, so a
# FUTURE behavior-changing fix to this script would silently not take effect on the
# resident process until it next restarts on its own — is filed separately, not folded
# into this diff.)
#
# Called by story-delivery.sh after deploy (STORY_ID=ga-ohz0x). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
LIVE_PY="$CITY/scripts/pipeline-throughput-heartbeat.py"
LIVE_SELFTEST="$CITY/packs/town-deltas/assets/pipeline-throughput-heartbeat.selftest.sh"
LIVE_SCALED_TIMEOUT_TEST="$CITY/scripts/pipeline-throughput-heartbeat.gate-merge-scaled-timeout.selftest.sh"

log()  { echo "[prod-test:gascity ga-ohz0x] $*"; }
fail() { echo "[prod-test:gascity ga-ohz0x] FAIL: $*" >&2; exit 1; }

# ── 1. Live artifacts exist ─────────────────────────────────────────────────────
[[ -f "$LIVE_PY" ]] || fail "missing live script: $LIVE_PY"
[[ -f "$LIVE_SELFTEST" ]] || fail "missing live selftest: $LIVE_SELFTEST"
[[ -f "$LIVE_SCALED_TIMEOUT_TEST" ]] || fail "missing live selftest: $LIVE_SCALED_TIMEOUT_TEST"
log "live artifacts present ✓"

# ── 2. The dead VERDICTS_RE identifier is gone ──────────────────────────────────
# Matches only an actual definition or usage (`VERDICTS_RE = re.compile(...)` /
# `VERDICTS_RE.search(...)`) — deliberately NOT a bare substring match, since this fix's
# own explanatory comments correctly mention the removed identifier's name by way of
# documenting its removal; a substring match would false-fail on that prose.
if grep -qE '^\s*VERDICTS_RE\s*=|VERDICTS_RE\.search' "$LIVE_PY"; then
    fail "VERDICTS_RE still defined/used in $LIVE_PY — dead code not removed"
fi
log "VERDICTS_RE no longer defined or used ✓"

# ── 3. PHASE_C_INFLIGHT_RE (the real, current in-flight signal) is still intact ─
# Guards against an over-broad removal that took the live signal down with the dead one.
grep -q "PHASE_C_INFLIGHT_RE" "$LIVE_PY" \
    || fail "PHASE_C_INFLIGHT_RE missing from $LIVE_PY — the real in-flight signal must survive this cleanup"
log "PHASE_C_INFLIGHT_RE still present ✓"

# ── 4. Selftest source no longer references the removed dead format ────────────
if grep -q "Verdicts:" "$LIVE_SELFTEST"; then
    fail "selftest still references the removed 'Verdicts: ...' log format: $LIVE_SELFTEST"
fi
log "selftest source clean of 'Verdicts:' references ✓"

# ── 5. Comprehensive selftest runs to completion, no stale reference ───────────
# NOTE: this suite carries a known, PRE-EXISTING, UNRELATED failure pair (2 tests gated on
# an "imp14 TSW flow-authority" hysteresis behavior this bead does not touch) — so this
# step checks the harness completes and produces a summary line (proves the module still
# imports and the removed test code didn't leave a dangling reference), not a zero-failure
# count. Asserting an exact pass/fail count here would make this prod test a permanent
# false-negative gate over a pre-existing, unrelated issue this bead was never asked to fix.
out=$(bash "$LIVE_SELFTEST" 2>&1) || true
echo "$out" | grep -qE '^pipeline-throughput-heartbeat selftest: [0-9]+ passed, [0-9]+ failed$' \
    || { echo "$out" >&2; fail "comprehensive selftest did not complete (no summary line — likely a crash or import error)"; }
if echo "$out" | grep -qi "VERDICTS_RE\|NameError"; then
    echo "$out" >&2
    fail "comprehensive selftest output mentions VERDICTS_RE or a NameError — stale reference"
fi
log "comprehensive selftest ran to completion, no stale VERDICTS_RE reference ✓"

# ── 6. Dedicated PHASE_C_INFLIGHT_RE (ga-z0xx1 scaled-timeout) selftest passes ──
# This is the suite that actually exercises the signal _fresh_review_in_progress() now
# relies on exclusively — unlike step 5's suite, it has no pre-existing unrelated noise,
# so it IS held to a strict full-pass bar.
log "running scaled-timeout selftest ..."
bash "$LIVE_SCALED_TIMEOUT_TEST" >/tmp/ga-ohz0x-scaled-timeout.$$ 2>&1 \
    || { cat /tmp/ga-ohz0x-scaled-timeout.$$ >&2; rm -f /tmp/ga-ohz0x-scaled-timeout.$$; fail "scaled-timeout selftest failed"; }
rm -f /tmp/ga-ohz0x-scaled-timeout.$$
log "scaled-timeout selftest PASS ✓"

log "PASS"
exit 0
