#!/usr/bin/env bash
# pkill-blast-guard-activate.sh (ga-jo3xl) — idempotently registers
# pkill-blast-guard.py as a PreToolUse:Bash hook in a Claude Code
# settings.json, composing with whatever hooks are already there.
#
# WHY: .gc/ is gitignored city-wide (verified 2026-07-28: `.gascity-
# gastown-hq/.gitignore` ignores `.gc/`, and any dir literally named
# `hooks/` anywhere under the city, and the nested `.claude/`) -- so the
# live settings.json this guard must land in can never itself be a git
# commit. This script is the git-tracked, reviewable, re-runnable
# substitute: run it once to activate, and again any time `gc init`/
# `gc start` resets .gc/settings.json back to the embedded default. It
# replaces only its OWN prior PreToolUse entry (matched by this script's
# basename in the registered command), never any other hook.
#
# USAGE: pkill-blast-guard-activate.sh [path-to-settings.json]
#   Defaults to the live city settings.json. Idempotent -- safe to re-run.
#   PKILL_GUARD_CITY overrides the city root (selftest-only -- lets the
#   selftest point at its own worktree copy of the guard script instead of
#   the live path; production runs never set this).
#
# TEST: exercised by pkill-blast-guard.selftest.sh against a scratch
# settings.json; never runs against the live file from the selftest.
set -euo pipefail

CITY="${PKILL_GUARD_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
GUARD_SCRIPT="$CITY/scripts/pkill-blast-guard.py"
SETTINGS="${1:-$CITY/.gc/settings.json}"

if [ ! -f "$GUARD_SCRIPT" ]; then
  echo "FATAL: guard script not found at $GUARD_SCRIPT -- refusing to register a hook pointing nowhere" >&2
  exit 1
fi
if [ ! -f "$SETTINGS" ]; then
  echo "FATAL: settings.json not found at $SETTINGS" >&2
  exit 1
fi

HOOK_CMD="python3 $GUARD_SCRIPT"
MARKER="pkill-blast-guard.py"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

jq \
  --arg cmd "$HOOK_CMD" \
  --arg marker "$MARKER" \
  '
  (.hooks //= {}) |
  .hooks.PreToolUse = (
    ((.hooks.PreToolUse // [])
      | map(select((.hooks // []) | any(((.command // "") | contains($marker))) | not))
    ) + [ { matcher: "Bash", hooks: [ { type: "command", command: $cmd, timeout: 5 } ] } ]
  )
  ' \
  "$SETTINGS" > "$TMP"

# Validate before overwriting the real file -- never leave settings.json
# truncated/corrupt if jq produced something unexpected.
jq empty "$TMP"

cp "$SETTINGS" "${SETTINGS}.bak.$(date +%s)" 2>/dev/null || true
mv "$TMP" "$SETTINGS"
echo "Registered $GUARD_SCRIPT as a PreToolUse:Bash hook in $SETTINGS"
