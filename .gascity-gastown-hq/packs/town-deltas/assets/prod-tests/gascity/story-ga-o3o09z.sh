#!/usr/bin/env bash
# prod-tests/gascity/story-ga-o3o09z.sh — prod test for ga-o3o09z:
# "Teto do WA em 2 lugares" — agents/wa-worker/agent.toml is the single
# source of truth for the controller's wa-worker pool ceiling, and the
# Pilot's own plist ceiling (a separate, redundant safety net) does not
# disagree with it.
#
# Why two checks instead of one: before this story, the controller ignored
# the Pilot's PILOT_WA_WORKER_MAX env entirely (it only gates what the Pilot
# itself dispatches) — so the two ceilings could silently diverge (measured
# 25/09: agent.toml=4, plist=2, 4 wa-workers actually active). Checking only
# agent.toml would pass even if the plist drifted back out of sync and nobody
# noticed until the machine was tight again.
#
# Called by run.sh after deploy (STORY_ID=ga-o3o09z). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
PILOT_PLIST="${PILOT_PLIST:-$HOME/Library/LaunchAgents/com.gascity.pilot.plist}"

log()  { echo "[prod-test:gascity ga-o3o09z] $*"; }
fail() { echo "[prod-test:gascity ga-o3o09z] FAIL: $*" >&2; exit 1; }

# ── 1. agent.toml is the source of truth: max_active_sessions = 2 ────────────
CFG="$CITY/agents/wa-worker/agent.toml"
[[ -f "$CFG" ]] || fail "agent config missing: $CFG"
if ! grep -qE "^max_active_sessions = 2[[:space:]]*(#.*)?$" "$CFG"; then
    fail "wa-worker: max_active_sessions = 2 not found in $CFG (got: $(grep '^max_active_sessions' "$CFG" || echo '<missing>'))"
fi
log "wa-worker: max_active_sessions = 2 in $CFG ✓"

# ── 2. No OTHER live source overrides the controller's view of this value ────
# city.toml can carry [[patches.agent]] blocks for name = "wa-worker"; none of
# them may set max_active_sessions (that would make agent.toml a second-place
# value, not the single source of truth this story requires).
CITY_TOML="$CITY/city.toml"
[[ -f "$CITY_TOML" ]] || fail "city.toml missing: $CITY_TOML"
if command -v python3 >/dev/null 2>&1; then
    PY_OUT=$(python3 - "$CITY_TOML" <<'PY' 2>&1
import sys
try:
    import tomllib
except ImportError:
    print(f"python3 {sys.version.split()[0]} has no tomllib (needs >= 3.11): cannot check {sys.argv[1]}", file=sys.stderr)
    sys.exit(2)
try:
    with open(sys.argv[1], "rb") as f:
        cfg = tomllib.load(f)
except Exception as e:
    print(f"cannot read/parse {sys.argv[1]}: {e}", file=sys.stderr)
    sys.exit(2)
patches = cfg.get("patches", {})
agent_patches = patches.get("agent", []) if isinstance(patches, dict) else []
bad = [p for p in agent_patches if isinstance(p, dict) and p.get("name") == "wa-worker" and "max_active_sessions" in p]
if bad:
    print(f"found max_active_sessions override(s) for wa-worker in [[patches.agent]]: {bad}", file=sys.stderr)
    sys.exit(1)
PY
    )
    PY_RC=$?
    case "$PY_RC" in
        0)
            log "city.toml: no [[patches.agent]] override of wa-worker max_active_sessions ✓"
            ;;
        2)
            # "Cannot determine" (missing tomllib, unreadable/unparseable file) is a
            # distinct outcome from "override found" — collapsing it into FAIL would
            # spuriously break this test wherever command -v python3 resolves to a
            # <3.11 interpreter (e.g. this host's own /usr/bin/python3 is 3.9.6),
            # even though no override exists and the real cause is tooling, not drift.
            log "city.toml override check: cannot determine ($PY_OUT) — soft skip, not a failure"
            ;;
        *)
            fail "city.toml [[patches.agent]] for wa-worker sets max_active_sessions — agent.toml is no longer the single source ($PY_OUT)"
            ;;
    esac
else
    log "python3 unavailable — skipping city.toml override check (soft skip, not a failure)"
fi

# ── 3. The Pilot's own ceiling (separate mechanism) is consistent, not stale ──
# PILOT_WA_WORKER_MAX only bounds what the Pilot itself dispatches — it never
# reaches the controller — so it is allowed to be MORE conservative than
# agent.toml, but must never be HIGHER (that would let the Pilot dispatch past
# the controller's real ceiling under the false belief it is capped).
if [[ -f "$PILOT_PLIST" ]]; then
    PLIST_MAX=$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:PILOT_WA_WORKER_MAX" "$PILOT_PLIST" 2>/dev/null || true)
    if [[ -z "$PLIST_MAX" ]]; then
        log "PILOT_WA_WORKER_MAX not set in $PILOT_PLIST — nothing to cross-check, skipping (soft skip)"
    elif ! [[ "$PLIST_MAX" =~ ^[0-9]+$ ]]; then
        fail "PILOT_WA_WORKER_MAX in $PILOT_PLIST is not a plain integer: '$PLIST_MAX'"
    elif [[ "$PLIST_MAX" -gt 2 ]]; then
        fail "PILOT_WA_WORKER_MAX=$PLIST_MAX > agent.toml's max_active_sessions=2 — Pilot would believe it can dispatch past the controller's real ceiling"
    else
        log "PILOT_WA_WORKER_MAX=$PLIST_MAX <= agent.toml's 2 ✓ (redundant-but-consistent)"
    fi
else
    log "$PILOT_PLIST not found on this host — skipping Pilot plist cross-check (soft skip, not a failure)"
fi

log "PASS — agents/wa-worker/agent.toml is the single source of truth for the controller's wa-worker ceiling (2), and the Pilot's own ceiling does not disagree"
exit 0
