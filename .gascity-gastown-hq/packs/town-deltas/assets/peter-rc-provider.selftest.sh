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
#   2. claude-rc adds exactly --remote-control + --model opus (the Mayor's), and claude-rc-crew adds exactly
#      --remote-control + --model sonnet (Athos 2026-10-05: crews on Sonnet; supersedes ga-n56ase), no other flags;
#   3. peter-wa uses claude-rc-crew, and its on-demand steady state (ga-3g2rjo, 2026-09-22: no
#      committed suspended=true -- the never-gets-a-bead dispatch-safety guarantee
#      now lives independently in pilot-dispatcher.sh's _crew_is_suspended, see its
#      own selftest Scenario 22e) leaves its session caps unchanged;
#   4. RC did not leak: plain `claude` and `claude-headless` do not carry --remote-control, claude-rc
#      users are exactly the named crews, and only gastown.mayor is patched onto it (ga-mrfgaw).
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
  echo "$rc_block" | grep '^base = "builtin:claude"$' >/dev/null \
    && ok "claude-rc is built on builtin:claude" || bad "claude-rc is not based on builtin:claude"
  args_of claude-rc | grep -- '--remote-control' >/dev/null \
    && ok "claude-rc.args_append carries --remote-control" || bad "claude-rc.args_append is missing --remote-control"
fi

echo "── 2. claude-rc adds only RC + the Opus pin (ga-n56ase), nothing else ──"
# ga-n56ase (Athos 2026-09-28): crews run Opus 5.5 by mandate, pinned here with the CLI's own
# "opus" alias. Exact match on purpose: a different model id, or any extra flag, fails.
if [ "$(args_of claude-rc)" = 'args_append = ["--remote-control", "--model", "opus"]' ]; then
  ok "claude-rc.args_append is exactly RC + --model opus (MCP surface, effort and permissions untouched)"
else
  bad "claude-rc.args_append is not exactly [--remote-control, --model, opus]: $(args_of claude-rc)"
fi
# Athos 2026-10-05: "pra todos nossos crew members, o modelo default é Sonnet" — crews moved to their own
# provider, same RC launch with the CLI's "sonnet" alias. Exact match, same reason as above.
if [ "$(args_of claude-rc-crew)" = 'args_append = ["--remote-control", "--model", "sonnet"]' ]; then
  ok "claude-rc-crew.args_append is exactly RC + --model sonnet"
else
  bad "claude-rc-crew.args_append is not exactly [--remote-control, --model, sonnet]: $(args_of claude-rc-crew)"
fi

echo "── 3. peter-wa uses it and stays in its on-demand steady state (ga-3g2rjo) ──"
grep -q '^provider = "claude-rc-crew"$' "$PETER_TOML" \
  && ok "peter-wa provider = claude-rc-crew" || bad "peter-wa does not use provider claude-rc-crew"
if grep -q '^suspended[[:space:]]*=[[:space:]]*true$' "$PETER_TOML"; then
  bad "peter-wa still commits 'suspended = true' -- ga-3g2rjo made on-demand access (no committed suspension) the steady state; the never-gets-a-bead guarantee now lives independently in pilot-dispatcher.sh's _crew_is_suspended (see its own selftest, Scenario 22e), so this line is expected to stay removed"
else
  ok "peter-wa does not commit 'suspended = true' (ga-3g2rjo: on-demand access is the steady state; dispatch-safety is enforced independently in pilot-dispatcher.sh)"
fi
grep -q '^min_active_sessions = 0$' "$PETER_TOML" && grep -q '^max_active_sessions = 1$' "$PETER_TOML" \
  && ok "peter-wa session caps unchanged (min 0 / max 1)" || bad "peter-wa min/max_active_sessions changed"

echo "── 4. RC did not leak (Athos 2026-08-30: only Mayor + named crews) ──"
if args_of claude | grep -- '--remote-control' >/dev/null; then
  bad "plain claude provider carries --remote-control — this would change the Mayor and every crew"
else
  ok "plain claude provider untouched"
fi
if args_of claude-headless | grep -- '--remote-control' >/dev/null; then
  bad "claude-headless carries --remote-control — pool/autonomous roles must stay headless"
else
  ok "claude-headless has no --remote-control (pool roles stay headless)"
fi
# ga-mrfgaw (Athos 2026-09-28): RC widened from peter-wa alone to the Mayor + ALL named crews.
# Still an exact set, so a pool/autonomous role landing on claude-rc fails here.
EXPECTED_RC_CREWS="batista-lx batista-ps batista-wa digo-wa mila-ma mila-wa oracle-wa peter-wa thies-ps thies-wa "
users="$(grep -l '^provider = "claude-rc-crew"$' "$AGENTS_DIR"/*/agent.toml 2>/dev/null | xargs -n1 dirname 2>/dev/null | xargs -n1 basename 2>/dev/null | sort | tr '\n' ' ' || true)"
if [ "$users" = "$EXPECTED_RC_CREWS" ]; then
  ok "claude-rc-crew users are exactly the named crews"
else
  bad "unexpected claude-rc-crew users: '${users:-none}' (expected '$EXPECTED_RC_CREWS')"
fi
# Which [[patches.agent]] blocks move an agent onto claude-rc: only gastown.mayor may.
patched="$(awk '/^\[\[patches\.agent\]\]$/{n=""} /^\[/ && !/^\[\[patches\.agent\]\]$/{n=""} /^name = /{n=$3} /^provider *= *"claude-rc"/{print n}' "$CITY_TOML" | tr -d '"' | sort | tr '\n' ' ')"
if [ "$patched" = "gastown.mayor " ]; then
  ok "only gastown.mayor is patched onto claude-rc in city.toml"
else
  bad "city.toml patches unexpected agents onto claude-rc: '${patched:-none}' — RC scope must be reviewed against the 2026-08-30 / 2026-09-28 policy"
fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
