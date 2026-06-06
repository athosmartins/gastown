#!/usr/bin/env bash
# prod-tests/gascity/story-ga-khuz1.sh — prod test for ga-khuz1: the crew-hang
# detector is installed, registered in launchd, ran fresh after this deploy, and
# its decision logic passes its hermetic selftest against the deployed code.
#
# Called by story-delivery.sh after deploy (STORY_ID=ga-khuz1). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
STATE_DIR="$CITY/.gc/state"
ASSETS="$CITY/packs/town-deltas/assets"
LABEL="com.gascity.crew-hang-detector"
MARKER="$STATE_DIR/crew-hang-detector.startup"
FRESHNESS_WINDOW=360   # kickstart in delivery Step 5 just ran it; allow launchd latency

log()  { echo "[prod-test:gascity ga-khuz1] $*"; }
fail() { echo "[prod-test:gascity ga-khuz1] FAIL: $*" >&2; exit 1; }

# ── 1. Deployed assets exist ──────────────────────────────────────────────────
for f in crew-hang-detector.sh crew-hang-detector.plist crew-hang-detector.selftest.sh; do
    [[ -f "$ASSETS/$f" ]] || fail "missing deployed asset: $ASSETS/$f"
done
log "deployed assets present ✓"

# ── 2. Hermetic selftest passes against the DEPLOYED code ─────────────────────
log "running deployed selftest ..."
bash "$ASSETS/crew-hang-detector.selftest.sh" >/tmp/khuz1-selftest.$$ 2>&1 \
    || { cat /tmp/khuz1-selftest.$$ >&2; rm -f /tmp/khuz1-selftest.$$; fail "deployed selftest failed"; }
rm -f /tmp/khuz1-selftest.$$
log "selftest PASS ✓"

# ── 3. launchd label registered (StartInterval job; PID may be '-' between runs) ─
uid="$(id -u)"
launchd_line="$(launchctl list 2>/dev/null | awk -v lbl="$LABEL" '$3==lbl{print}')"
[[ -n "$launchd_line" ]] || fail "$LABEL not registered in launchd (skill-integrity-install did not load it)"
log "$LABEL registered in launchd ✓"

# ── 4. Startup marker is fresh — proves the LIVE process ran the new code ──────
# The daemon writes the marker at the top of every pass; the post-deploy
# kickstart forces an immediate pass.
waited=0
while (( waited < 30 )); do
    [[ -f "$MARKER" ]] && break
    sleep 2; (( waited += 2 ))
done
[[ -f "$MARKER" ]] || fail "startup marker missing after ${waited}s ($MARKER) — daemon did not run after deploy"

read -r _pid epoch < "$MARKER" 2>/dev/null || fail "could not read startup marker ($MARKER)"
[[ -n "$epoch" ]] || fail "startup marker malformed: $(cat "$MARKER")"
now="$(date +%s)"; age=$(( now - epoch ))
(( age <= FRESHNESS_WINDOW )) \
    || fail "startup marker ${age}s old (> ${FRESHNESS_WINDOW}s) — daemon was NOT kickstarted by this deploy"
log "startup marker fresh — ran ${age}s ago (within ${FRESHNESS_WINDOW}s) ✓"

log "PASS — crew-hang detector installed, registered, fresh, and logic-verified"
exit 0
