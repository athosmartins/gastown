#!/usr/bin/env bash
# crew-model-effort.selftest.sh — ga-n56ase: Athos, 2026-09-28, verbatim: "Para todos crew
# members, o modelo default eh Opus 5.5 e effort medium. Se nao estiver configurado assim, eh
# uma bead p0 resolver isso".
#
# Measured before the fix: all 10 named crews had option_defaults.effort="high" and no model pin
# (they inherited ~/.claude/settings.json's global model, which happened to be "opus").
#
# Static check against the committed text (same convention as peter-rc-provider.selftest.sh —
# `gc config show` needs untracked local state a clean checkout does not have):
#   1. every agent on provider claude-rc (= the named crews; the Mayor gets claude-rc via a
#      city.toml patch, not an agent.toml, and keeps its own xhigh) sets effort = "medium";
#   2. the set of crews is non-empty (an empty set would pass 1 vacuously);
#   3. the model comes from claude-rc's own --model opus (the CLI alias for the latest Opus), NOT
#      from option_defaults.model — the engine's builtin "opus" choice maps to claude-opus-4-8.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_TOML="${CREW_ME_CITY_TOML:-$SELF_DIR/../../../city.toml}"
AGENTS_DIR="${CREW_ME_AGENTS_DIR:-$SELF_DIR/../../../agents}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$CITY_TOML" ] || { echo "FATAL: city.toml not found at $CITY_TOML"; exit 1; }
[ -d "$AGENTS_DIR" ] || { echo "FATAL: agents dir not found at $AGENTS_DIR"; exit 1; }

echo "── 1+2. every claude-rc crew runs effort = medium ──"
n=0
for f in "$AGENTS_DIR"/*/agent.toml; do
  grep -q '^provider = "claude-rc"$' "$f" || continue
  n=$((n+1))
  crew="$(basename "$(dirname "$f")")"
  if grep -q '^option_defaults = { effort = "medium" }$' "$f"; then
    ok "$crew: effort = medium"
  else
    bad "$crew: effort is not medium ($(grep '^option_defaults' "$f" || echo 'no option_defaults — builtin default is max'))"
  fi
  if grep -E '^option_defaults.*model' "$f" >/dev/null; then
    bad "$crew: sets option_defaults.model — the engine maps 'opus' to claude-opus-4-8 (a downgrade)"
  fi
done
[ "$n" -gt 0 ] && ok "$n crews on claude-rc checked" || bad "no agent uses provider claude-rc — nothing was checked"

echo "── 3. the Opus pin lives on the claude-rc provider ──"
rc_args="$(awk '$0=="[providers.claude-rc]"{f=1; next} /^\[/{f=0} f' "$CITY_TOML" | grep '^args_append' || true)"
echo "$rc_args" | grep -q '"--model", "opus"' \
  && ok "claude-rc pins --model opus" || bad "claude-rc does not pin --model opus: ${rc_args:-<no args_append>}"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
