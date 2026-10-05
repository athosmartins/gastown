#!/usr/bin/env bash
# crew-model-effort.selftest.sh — Athos, 2026-10-05, verbatim (Mayor session): "pra todos nossos crew
# members, o modelo default ie Sonnet e effor level high. pro mayor, opus com effor high".
# Supersedes ga-n56ase (2026-09-28: crews on Opus 5.5 + effort medium).
#
# Static check against the committed text (same convention as peter-rc-provider.selftest.sh —
# `gc config show` needs untracked local state a clean checkout does not have):
#   1. every named crew is on provider claude-rc-crew and sets effort = "high";
#   2. the set of crews is non-empty (an empty set would pass 1 vacuously);
#   3. no agent.toml is left on the Opus provider claude-rc (that one is the Mayor's, set by the pack);
#   4. claude-rc-crew pins --model sonnet with --remote-control; claude-rc keeps --model opus;
#   5. the Mayor's effort patch in city.toml is "high".
# The model comes from the provider's own --model alias (latest Sonnet / latest Opus), NOT from
# option_defaults.model — the engine's builtin "opus" choice maps to claude-opus-4-8 (a downgrade).
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

EXPECTED_EFFORT="high"
echo "── 1+2. every claude-rc-crew crew runs effort = $EXPECTED_EFFORT ──"
n=0
for f in "$AGENTS_DIR"/*/agent.toml; do
  grep -q '^provider = "claude-rc-crew"$' "$f" || continue
  n=$((n+1))
  crew="$(basename "$(dirname "$f")")"
  if grep -q "^option_defaults = { effort = \"$EXPECTED_EFFORT\" }" "$f"; then
    ok "$crew: effort = $EXPECTED_EFFORT"
  else
    bad "$crew: effort is not $EXPECTED_EFFORT ($(grep '^option_defaults' "$f" || echo 'no option_defaults — builtin default is max'))"
  fi
  if grep -E '^option_defaults.*model' "$f" >/dev/null; then
    bad "$crew: sets option_defaults.model — the model must come from the provider's --model alias"
  fi
done
[ "$n" -gt 0 ] && ok "$n crews on claude-rc-crew checked" || bad "no agent uses provider claude-rc-crew — nothing was checked"

echo "── 3. no crew left on the Opus provider ──"
left="$(grep -l '^provider = "claude-rc"$' "$AGENTS_DIR"/*/agent.toml 2>/dev/null || true)"
[ -z "$left" ] && ok "no agent.toml on claude-rc (Opus is the Mayor's only)" || bad "still on claude-rc (Opus): $left"

echo "── 4. model pins live on the providers ──"
crew_args="$(awk '$0=="[providers.claude-rc-crew]"{f=1; next} /^\[/{f=0} f' "$CITY_TOML" | grep '^args_append' || true)"
echo "$crew_args" | grep -q '"--model", "sonnet"' \
  && ok "claude-rc-crew pins --model sonnet" || bad "claude-rc-crew does not pin --model sonnet: ${crew_args:-<no args_append>}"
echo "$crew_args" | grep -q '"--remote-control"' \
  && ok "claude-rc-crew keeps --remote-control" || bad "claude-rc-crew lost --remote-control: ${crew_args:-<no args_append>}"
rc_args="$(awk '$0=="[providers.claude-rc]"{f=1; next} /^\[/{f=0} f' "$CITY_TOML" | grep '^args_append' || true)"
echo "$rc_args" | grep -q '"--model", "opus"' \
  && ok "claude-rc (Mayor) pins --model opus" || bad "claude-rc does not pin --model opus: ${rc_args:-<no args_append>}"

echo "── 5. the Mayor's effort is high ──"
mayor_eff="$(awk '/^\[\[patches.agent\]\]/{blk=""} {blk=blk"\n"$0} /^option_defaults/ && blk ~ /name = "gastown.mayor"/ {print; exit}' "$CITY_TOML")"
echo "$mayor_eff" | grep -q 'effort = "high"' \
  && ok "gastown.mayor effort = high" || bad "gastown.mayor effort is not high: ${mayor_eff:-<no patch found>}"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
