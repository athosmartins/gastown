#!/usr/bin/env bash
# peter-rc-provider.selftest.sh — wa-m6nkr: prove peter-wa's fresh-every-touchpoint session is
# launched with Remote Control, and that RC stays scoped the way Athos decided.
#
# Why (wa-14p4c "Peter só nos horários"): the peter-wa session is now created NEW at each
# 07:00/19:00 touchpoint and closed after it, so it never gets the one-time manual /rc a
# long-lived session used to get — Athos could not see/approve the briefing from his phone.
# Every claude session in this city is launched with `--settings <city>/.gc/settings.json`
# carrying remoteControlAtStartup=false, which beats his global true; the `--remote-control`
# CLI flag is what wins (measured 2026-09-19, claude 2.1.278: the flag → the session file gets a
# bridgeSessionId within 60s; the identical launch without it never does).
#
# Athos's 2026-08-30 policy (city.toml, ga-4kxdc): RC ONLY for the Mayor and named crews;
# autonomous/pool roles stay headless. So this asserts, statically, against the committed text
# (same convention as mcp-strict-headless-provider.selftest.sh — `gc config show` resolution
# needs untracked local state such as .gc/site.toml that a clean checkout does not have):
#   1. [providers.claude-rc] exists, is built on builtin:claude and adds --remote-control;
#   2. it adds NOTHING else that changes behaviour (no MCP/model/settings flags);
#   3. peter-wa uses it, and is still suspended=true (steady state) with its session caps;
#   4. RC did not leak: plain `claude` and `claude-headless` do not carry --remote-control,
#      and no other agent uses claude-rc.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_TOML="${PETER_RC_CITY_TOML:-$SELF_DIR/../../../city.toml}"
AGENTS_DIR="${PETER_RC_AGENTS_DIR:-$SELF_DIR/../../../agents}"
PETER_TOML="$AGENTS_DIR/peter-wa/agent.toml"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$CITY_TOML" ] || { echo "FATAL: city.toml not found at $CITY_TOML"; exit 1; }
[ -f "$PETER_TOML" ] || { echo "FATAL: peter-wa agent.toml not found at $PETER_TOML"; exit 1; }

# One provider's own block, from its exact header to the next [section] header. Comments before the
# header are outside it; only the key lines are inspected, never prose (see the ga-rpejh selftest).
block() { awk -v h="[providers.$1]" '$0==h{f=1; print; next} /^\[/{f=0} f' "$CITY_TOML"; }
args_of() { block "$1" | grep '^args_append' || true; }

echo "── 1. [providers.claude-rc] = builtin:claude + --remote-control ──"
rc_block="$(block claude-rc)"
if [ -z "$rc_block" ]; then
  bad "no [providers.claude-rc] block in city.toml"
else
  echo "$rc_block" | grep -q '^base = "builtin:claude"$' \
    && ok "claude-rc is built on builtin:claude" || bad "claude-rc is not based on builtin:claude"
  args_of claude-rc | grep -q -- '--remote-control' \
    && ok "claude-rc.args_append carries --remote-control" || bad "claude-rc.args_append is missing --remote-control"
fi

echo "── 2. claude-rc adds nothing else that changes behaviour ──"
if args_of claude-rc | grep -q -E -- '--strict-mcp-config|--mcp-config|--model|--settings|remoteControlAtStartup|--effort|--dangerously'; then
  bad "claude-rc.args_append carries a flag beyond --remote-control: $(args_of claude-rc)"
else
  ok "claude-rc.args_append is only the RC flag (Mayor/crew MCP surface, model and permissions untouched)"
fi

echo "── 3. peter-wa uses it and stays in its steady state ──"
grep -q '^provider = "claude-rc"$' "$PETER_TOML" \
  && ok "peter-wa provider = claude-rc" || bad "peter-wa does not use provider claude-rc"
last_line="$(grep -v '^[[:space:]]*$' "$PETER_TOML" | tail -1)"
[ "$last_line" = "suspended = true" ] \
  && ok "peter-wa is still suspended = true, as the LAST line (gc agent suspend/resume edit exactly that line)" \
  || bad "peter-wa lost its steady-state 'suspended = true' as last line (got: '$last_line')"
grep -q '^min_active_sessions = 0$' "$PETER_TOML" && grep -q '^max_active_sessions = 1$' "$PETER_TOML" \
  && ok "peter-wa session caps unchanged (min 0 / max 1)" || bad "peter-wa min/max_active_sessions changed"

echo "── 4. RC did not leak (Athos 2026-08-30: only Mayor + named crews) ──"
if args_of claude | grep -q -- '--remote-control'; then
  bad "plain claude provider carries --remote-control — this would change the Mayor and every crew"
else
  ok "plain claude provider untouched"
fi
if args_of claude-headless | grep -q -- '--remote-control'; then
  bad "claude-headless carries --remote-control — pool/autonomous roles must stay headless"
else
  ok "claude-headless has no --remote-control (pool roles stay headless)"
fi
users="$(grep -l '^provider = "claude-rc"$' "$AGENTS_DIR"/*/agent.toml 2>/dev/null | xargs -n1 dirname 2>/dev/null | xargs -n1 basename 2>/dev/null | sort | tr '\n' ' ' || true)"
if [ "$(echo "$users" | tr -d ' ')" = "peter-wa" ]; then
  ok "only peter-wa uses claude-rc"
else
  bad "unexpected claude-rc users: '${users:-none}'"
fi
if grep -q -E '^provider *= *"claude-rc"' "$CITY_TOML"; then
  bad "city.toml patches an agent onto claude-rc — RC scope must be reviewed against the 2026-08-30 policy"
else
  ok "no [[patches.agent]] moves another agent onto claude-rc"
fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
