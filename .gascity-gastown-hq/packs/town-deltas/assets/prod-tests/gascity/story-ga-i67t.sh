#!/usr/bin/env bash
# prod-tests/gascity/story-ga-i67t.sh — prod test for ga-i67t:
# single-session-per-identity mutex (refuse-or-reuse live target).
#
# Verifies that all single-identity crew agents (digo, batista-ps, batista-wa,
# batista, mila, oracle, peter, thies) have max_active_sessions = 1 in their
# effective gc config, preventing the reconciler from spawning phantom
# "{name}-N" duplicate sessions that race on shared branch namespaces.
#
# Called by run.sh after deploy (STORY_ID=ga-i67t). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"

log()  { echo "[prod-test:gascity ga-i67t] $*"; }
fail() { echo "[prod-test:gascity ga-i67t] FAIL: $*" >&2; exit 1; }

SINGLE_IDENTITY_AGENTS=(digo batista-ps batista-wa batista mila oracle peter thies)

# ── 1. Config verification: max_active_sessions = 1 in agent.toml ─────────────
log "Checking max_active_sessions = 1 in agent configs..."
for agent in "${SINGLE_IDENTITY_AGENTS[@]}"; do
    cfg="$CITY/agents/$agent/agent.toml"
    [[ -f "$cfg" ]] || fail "agent config missing: $cfg"
    if ! grep -q "^max_active_sessions = 1" "$cfg"; then
        fail "agent $agent: max_active_sessions = 1 not found in $cfg"
    fi
    log "  $agent: max_active_sessions = 1 ✓"
done

# ── 2. Runtime verification: no duplicate ("{name}-N") sessions active ─────────
log "Checking for duplicate sessions..."
SESSION_LIST=$(gc --city "$CITY" session list 2>/dev/null || true)
DUPLICATES=""
for agent in "${SINGLE_IDENTITY_AGENTS[@]}"; do
    # Duplicate pattern: session target matches "{agent}-{digit}"
    count=$(echo "$SESSION_LIST" \
        | awk -v t="$agent" '$2==t && $3=="active" && $5 ~ "^"t"-[0-9]"' \
        | wc -l | tr -d ' ')
    if [[ "${count:-0}" -gt 0 ]]; then
        DUPLICATES="$DUPLICATES $agent(${count}x)"
    fi
done
if [[ -n "$DUPLICATES" ]]; then
    fail "duplicate sessions still active: $DUPLICATES — reconciler may need a reload (gc reload) to drain them"
fi
log "No duplicate sessions found ✓"

log "PASS — single-session mutex config deployed and no phantom sessions active"
exit 0
