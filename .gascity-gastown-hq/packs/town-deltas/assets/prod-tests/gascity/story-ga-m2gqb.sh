#!/usr/bin/env bash
# prod-tests/gascity/story-ga-m2gqb.sh — prod test for ga-m2gqb: machine-health
# backpressure (deferred remainder of ga-7xne1, the 2026-07-27 jetsam freeze).
#
# AC1: the 3 heavy weekly evals (lexbh, WhatsApp, quality-gate) never run
#      concurrently — at most one at a time, others wait their turn.
# AC2: WARN or EMERGENCY RAM pressure defers BOTH new agent-pool spawns
#      (Pilot dispatch) and new heavy-eval starts — already-running work is
#      never interrupted.
# AC3: repeating the 2026-07-27 convergence scenario does not require a
#      manual reboot.
#
# Verifies the DEPLOYED artifacts + the LIVE launchd wiring, not just that
# code exists — a plist edited but never reloaded would satisfy a grep-only
# check while doing nothing in production. Delegates to each artifact's own
# selftest for behavioral coverage rather than re-asserting every case here.
#
# Called by run.sh after deploy (STORY_ID=ga-m2gqb). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
GASTOWN="${GASTOWN:-${HOME}/.gastown}"
WRAPPER="$CITY/packs/town-deltas/assets/heavy-eval-stagger-lock.sh"
DISPATCHER="$CITY/packs/town-deltas/assets/pilot-dispatcher.sh"
MONITOR="$GASTOWN/scripts/ram-pressure-monitor.sh"

log()  { echo "[prod-test:gascity ga-m2gqb] $*"; }
fail() { echo "[prod-test:gascity ga-m2gqb] FAIL: $*" >&2; exit 1; }

# ── Artifacts exist + are executable ──────────────────────────────────────────
[[ -f "$WRAPPER" ]]    || fail "heavy-eval-stagger-lock.sh missing: $WRAPPER"
[[ -x "$WRAPPER" ]]    || fail "heavy-eval-stagger-lock.sh not executable: $WRAPPER"
[[ -f "$DISPATCHER" ]] || fail "pilot-dispatcher.sh missing: $DISPATCHER"
[[ -f "$MONITOR" ]]    || fail "ram-pressure-monitor.sh missing: $MONITOR (separate ~/.gastown repo)"

# ── AC2 (RAM signal source): ram-pressure-monitor.sh exposes its decided level ─
log "Checking ram-pressure-monitor.sh writes a durable level file..."
grep -q "RPM_LEVEL_FILE" "$MONITOR" || fail "RPM_LEVEL_FILE not found in ram-pressure-monitor.sh — the fix did not deploy"
grep -q "_write_level" "$MONITOR"   || fail "_write_level helper not found in ram-pressure-monitor.sh"
log "  level-file mechanism present ✓"

log "Running ram-pressure-monitor.sh's own selftest (hermetic, covers OK/WARN/EMERGENCY level-file writes)..."
if ! "$MONITOR" --selftest >/tmp/.story-ga-m2gqb-rpm-selftest.$$ 2>&1; then
    tail -20 "/tmp/.story-ga-m2gqb-rpm-selftest.$$" >&2
    rm -f "/tmp/.story-ga-m2gqb-rpm-selftest.$$"
    fail "ram-pressure-monitor.sh selftest did not pass on the deployed artifact"
fi
rm -f "/tmp/.story-ga-m2gqb-rpm-selftest.$$"
log "  ram-pressure-monitor selftest PASS ✓"

# ── AC2 (agent-pool spawns): Pilot dispatch gate wired ────────────────────────
log "Checking pilot-dispatcher.sh's RAM-pressure back-off is wired..."
grep -q '_pilot_ram_pressure_blocks()' "$DISPATCHER" || fail "_pilot_ram_pressure_blocks not found — the Pilot gate did not deploy"
grep -q 'paused: pressão de RAM' "$DISPATCHER"        || fail "RAM pause branch not found in the sweep"
grep -qE '\[ -f "\$PILOT_RAM_LEVEL_FILE" \] \|\| \{ printf .0.; return 0; \}' "$DISPATCHER" \
    || fail "RAM-pressure probe missing its fail-open guard — a stale/absent signal must never block dispatch"
log "  Pilot RAM-pressure gate present + fail-open guard intact ✓"

# ── AC1 + AC2 (heavy evals): stagger-lock wrapper selftest ────────────────────
log "Running heavy-eval-stagger-lock.sh's own selftest (lock mutual-exclusion, stale-reclaim, RAM fail-open, exit-code passthrough)..."
if ! "$WRAPPER" --selftest >/tmp/.story-ga-m2gqb-hesl-selftest.$$ 2>&1; then
    tail -30 "/tmp/.story-ga-m2gqb-hesl-selftest.$$" >&2
    rm -f "/tmp/.story-ga-m2gqb-hesl-selftest.$$"
    fail "heavy-eval-stagger-lock.sh selftest did not pass on the deployed artifact"
fi
rm -f "/tmp/.story-ga-m2gqb-hesl-selftest.$$"
log "  heavy-eval-stagger-lock selftest PASS ✓"

# ── AC1: the 3 heavy eval jobs are LIVE-wired through the wrapper ─────────────
# Checks launchd's LOADED state, not just the plist file on disk — a plist
# edited but never (re)loaded would pass a grep-only check while changing
# nothing in production.
UID_N="$(id -u)"
check_live_wired() {
    local label="$1"
    local live; live="$(launchctl print "gui/${UID_N}/${label}" 2>/dev/null)"
    [[ -n "$live" ]] || fail "$label is not loaded in launchd at all"
    echo "$live" | grep -q "heavy-eval-stagger-lock.sh" \
        || fail "$label is loaded but its live ProgramArguments do NOT reference heavy-eval-stagger-lock.sh — plist was edited but never reloaded, or reverted"
    log "  $label live-wired through the stagger lock ✓"
}
log "Checking the 3 heavy eval jobs are live-wired through the stagger lock..."
check_live_wired "com.lexbh.v_pipeline.weekly"
check_live_wired "com.whatsapp.eval-sampler-weekly"
check_live_wired "com.gascity.quality-gate-eval"

log "PASS — RAM-pressure signal exposed, Pilot dispatch gate wired (fail-open), heavy-eval stagger+backpressure wrapper deployed and live-wired into all 3 weekly eval jobs"
exit 0
