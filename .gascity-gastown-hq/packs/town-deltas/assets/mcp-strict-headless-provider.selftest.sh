#!/usr/bin/env bash
# mcp-strict-headless-provider.selftest.sh — ga-rpejh: prove city.toml scopes
# --strict-mcp-config to the claude-headless provider only.
#
# Bug ga-rpejh: every claude-headless session (dog, wa-worker, gate-reviewer,
# ps-worker, boot, deacon, auto-refiner, context-check-reviewer,
# refino-gate-reviewer, ...) inherited the FULL user-level ~/.claude.json MCP
# roster (sqlite/playwright/puppeteer/sequential-thinking/etc.) plus every
# enabled plugin, unconditionally — ~30 extra child processes per session,
# ~300 across 15 concurrent sessions, and the resulting swap pushed the
# Dolt data volume's disk headroom to critical twice in one evening.
#
# Fix: append --strict-mcp-config (with no --mcp-config) to
# [providers.claude-headless].args_append in city.toml. Per `claude --help`,
# that flag alone (no --mcp-config) yields zero MCP servers for the session —
# exactly "provavelmente nenhum" for pool/ephemeral roles, none of which has
# any MCP catalog configured today. Mayor and human-attached crews stay on
# the separate, untouched "claude" provider and keep their full MCP surface —
# deciding role-by-role whether any of them should get an MCP catalog (e.g.
# playwright) is explicitly a later, separate step, not this fix's job.
#
# This is a static assertion against the committed city.toml text, not a
# `gc config show` resolution check — resolution depends on untracked
# local-runtime state (.gc/site.toml rig bindings, packs/town-deltas itself
# being present) that a clean checkout / isolated review sandbox does not
# reliably have. Drift-guards the fix: a future edit that removes the flag,
# or widens it onto the plain "claude" provider, fails this loudly.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_TOML="$SELF_DIR/../../../city.toml"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$CITY_TOML" ] || { echo "FATAL: city.toml not found at $CITY_TOML"; exit 1; }

# Isolate each provider's own TOML block (from its exact header to the next
# top-level [section] or [providers.xxx] header), then keep only the
# args_append = [...] line — never the surrounding comments, which are free
# to mention flag names in prose (an explanatory comment on this very fix
# mentions "--mcp-config" in passing; matching against comment text made an
# earlier version of this test self-trigger on its own prose).
claude_block=$(awk '/^\[providers\.claude\]$/{f=1; print; next} /^\[/{f=0} f' "$CITY_TOML" | grep '^args_append' || true)
headless_block=$(awk '/^\[providers\.claude-headless\]$/{f=1; print; next} /^\[/{f=0} f' "$CITY_TOML" | grep '^args_append' || true)

echo "── 1. claude-headless carries --strict-mcp-config ──"
if [ -n "$headless_block" ] && echo "$headless_block" | grep -q -- '--strict-mcp-config'; then
  ok "providers.claude-headless.args_append contains --strict-mcp-config"
else
  bad "providers.claude-headless.args_append is missing --strict-mcp-config"
fi

echo "── 2. plain claude provider is untouched (Mayor/crews keep full MCP) ──"
if [ -n "$claude_block" ] && echo "$claude_block" | grep -q -- '--strict-mcp-config'; then
  bad "providers.claude unexpectedly carries --strict-mcp-config — this would strip MCP from Mayor/crews"
else
  ok "providers.claude has no --strict-mcp-config (Mayor/crews unaffected)"
fi

echo "── 3. no stray --mcp-config (zero servers is the intended outcome today) ──"
if [ -n "$headless_block" ] && echo "$headless_block" | grep -q -- '--mcp-config'; then
  bad "providers.claude-headless carries --mcp-config with no catalog configured for pool roles — verify this is intentional, not stray"
else
  ok "providers.claude-headless has no --mcp-config (matches: no MCP catalog configured for pool roles today)"
fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
