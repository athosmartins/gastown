#!/usr/bin/env bash
# gate-reviewer-cap-exempt.selftest.sh — Drift-guard for the ga-mzc3h fix.
#
# Bug ga-mzc3h: a TOWN-WIDE quality-gate outage. quality-gate-dispatcher.sh
# spawned each independent reviewer via "gc session new gastown.dog", which
# counts against the gastown.dog pool cap (max_active_sessions=3). The dog pool
# supervisor permanently holds all 3 slots, so the gate could never acquire even
# reviewer slot 1 → every marker landed gate-status:error. Structural deadlock.
#
# The fix:
#   1. Reviewers spawn from a DEDICATED "gate-reviewer" template with its own
#      budget (min_active_sessions=0, max_active_sessions>=3), so they never
#      compete with the dog pool for slots.
#   2. The spawn no longer swallows stderr (was `2>/dev/null`) — failures are
#      captured + logged so the next regression fails LOUD, not silent.
#
# This harness drift-guards the real script + template so a future refactor that
# reintroduces the deadlock (or re-mutes the spawn) fails loudly. No live
# Dolt/gc/launchd required. Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"
# Template lives at <city>/agents/gate-reviewer/agent.toml.
# SELF_DIR = <city>/packs/town-deltas/assets → city root is three levels up.
CITY_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
TPL="$CITY_ROOT/agents/gate-reviewer/agent.toml"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "── gate-reviewer cap-exempt drift-guard (ga-mzc3h) ──"

# 1. Reviewers spawn from the dedicated gate-reviewer template.
if grep -Eq 'session new[[:space:]]+gate-reviewer' "$GATE"; then
  ok "reviewer spawn uses 'gc session new gate-reviewer'"
else
  bad "reviewer spawn does NOT use the gate-reviewer template"
fi

# 2. Reviewers must NOT spawn from the capped dog pool template.
if grep -Eq 'session new[[:space:]]+gastown\.dog' "$GATE"; then
  bad "reviewer spawn STILL uses 'gc session new gastown.dog' (the ga-mzc3h deadlock)"
else
  ok "reviewer spawn no longer uses the capped gastown.dog template"
fi

# 3. The reviewer `session new` command must NOT mute stderr with 2>/dev/null.
#    Extract ONLY the SESSION_JSON=$(gc ... session new gate-reviewer ...) command
#    (from the `session new gate-reviewer` line to the line closing it with
#    `echo "{}"`), so we don't false-positive on unrelated cleanup redirects.
# The command is exactly 5 lines (session new, --no-attach, --title, --json,
# `2>... || echo "{}"`); -A4 captures it and stops before the cleanup line.
SPAWN_CMD="$(grep -A4 'session new[[:space:]]\+gate-reviewer' "$GATE" 2>/dev/null || true)"
if printf '%s' "$SPAWN_CMD" | grep -q '2>/dev/null'; then
  bad "reviewer 'session new' command still swallows stderr with 2>/dev/null"
elif printf '%s' "$SPAWN_CMD" | grep -Eq '2>[[:space:]]*"?\$?[A-Za-z_/]'; then
  ok "reviewer 'session new' redirects stderr to a capture file (fails loud)"
else
  bad "reviewer 'session new' has no explicit stderr capture (cannot log failures)"
fi

# 4. The dedicated template exists.
if [ -f "$TPL" ]; then
  ok "gate-reviewer/agent.toml exists"
else
  bad "gate-reviewer/agent.toml missing at $TPL"
fi

# 5. Template is on-demand (min=0) so it spawns NO permanent pool workers.
if [ -f "$TPL" ] && grep -Eq '^[[:space:]]*min_active_sessions[[:space:]]*=[[:space:]]*0' "$TPL"; then
  ok "gate-reviewer min_active_sessions = 0 (on-demand, no permanent workers)"
else
  bad "gate-reviewer min_active_sessions is not 0 (would create permanent pool workers)"
fi

# 6. Template budget covers at least one full CODE-tier gate run (3 reviewers).
if [ -f "$TPL" ]; then
  MAXS="$(grep -E '^[[:space:]]*max_active_sessions[[:space:]]*=' "$TPL" | head -1 | grep -Eo '[0-9]+' || echo 0)"
  if [ "${MAXS:-0}" -ge 3 ]; then
    ok "gate-reviewer max_active_sessions = $MAXS (>=3, covers a CODE-tier run)"
  else
    bad "gate-reviewer max_active_sessions = $MAXS (<3, cannot run a CODE-tier gate)"
  fi
else
  bad "cannot check max_active_sessions — template missing"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
