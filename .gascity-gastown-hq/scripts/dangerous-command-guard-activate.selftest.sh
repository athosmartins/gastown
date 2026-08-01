#!/usr/bin/env bash
# dangerous-command-guard-activate.selftest.sh (ga-7j1yu) — hermetic tests
# for dangerous-command-guard-activate.sh. Runs the script against SCRATCH
# settings.json files under mktemp -d; never touches any live rig file.
#
# TEST: bash dangerous-command-guard-activate.selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTIVATE="$HERE/dangerous-command-guard-activate.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────
# Case 1: no bare "Bash" matcher entry yet (mirrors property_scrapers/crew
# pre-fix: has an OLD-style dead matcher="Bash(rm -rf /*)" entry -- fully
# superseded by the if-gated hook this script adds, so it must be REMOVED,
# not left as confusing dead-plus-live duplicate config -- plus an
# unrelated pr-workflow entry, which uses the SAME old-style shape but for
# a DIFFERENT guard and must be left untouched, since fixing that guard is
# outside this bead's scope) -- a NEW matcher="Bash" entry should be
# created holding all 6 if-gated hooks.
# ─────────────────────────────────────────────────────────────────────────
echo "-- case 1: no bare-Bash entry yet (property_scrapers/crew pre-fix shape) --"
F1="$SCRATCH/no-bare.json"
cat > "$F1" <<'JSONEOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash(gh pr create*)", "hooks": [ { "type": "command", "command": "/Users/athos/.local/bin/gt tap guard pr-workflow" } ] },
      { "matcher": "Bash(rm -rf /*)", "hooks": [ { "type": "command", "command": "/Users/athos/.local/bin/gt tap guard dangerous-command" } ] }
    ],
    "SessionStart": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "/Users/athos/.local/bin/gt prime --hook" } ] }
    ]
  }
}
JSONEOF

bash "$ACTIVATE" "$F1" >/tmp/dcg-selftest-1.$$ 2>&1
RC1=$?
BARE_HOOKS_1="$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash")] | length' "$F1" 2>/dev/null)"
NEW_HOOK_COUNT_1="$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]] | length' "$F1" 2>/dev/null)"
if [ "$RC1" -eq 0 ] && [ "$BARE_HOOKS_1" = "1" ] && [ "$NEW_HOOK_COUNT_1" = "6" ] \
   && jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash(gh pr create*)")' "$F1" >/dev/null 2>&1 \
   && jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash(rm -rf /*)")] | length == 0' "$F1" >/dev/null 2>&1 \
   && jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.if == "Bash(git reset --hard*)") | .command | contains("dangerous-command")' "$F1" >/dev/null 2>&1 \
   && jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.if == "Bash(rm -rf /*)") | .command | contains("dangerous-command")' "$F1" >/dev/null 2>&1 \
   && jq -e '.hooks.SessionStart[0].hooks[0].command == "/Users/athos/.local/bin/gt prime --hook"' "$F1" >/dev/null 2>&1; then
  ok "no-bare: created matcher=Bash entry with 6 if-gated hooks, removed superseded old-style dangerous-command entry, left unrelated pr-workflow + SessionStart untouched"
else
  bad "no-bare: expected 1 bare-Bash entry / 6 hooks, old dangerous-command entry gone, pr-workflow preserved, got bare=$BARE_HOOKS_1 hooks=$NEW_HOOK_COUNT_1 file=$(cat "$F1")"
fi

bash "$ACTIVATE" "$F1" >/tmp/dcg-selftest-1b.$$ 2>&1
NEW_HOOK_COUNT_1B="$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]] | length' "$F1" 2>/dev/null)"
[ "$NEW_HOOK_COUNT_1B" = "6" ] && ok "no-bare: re-run is idempotent (still 6 if-gated hooks)" \
  || bad "no-bare: expected 6 after re-run, got $NEW_HOOK_COUNT_1B"

# ─────────────────────────────────────────────────────────────────────────
# Case 2: a bare "Bash" matcher entry already exists with an unrelated
# if-gated hook (mirrors a rig with some other if-gated Bash hook already
# in place) -- new hooks must be appended into the SAME entry, not create
# a second matcher=Bash entry.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- case 2: bare-Bash entry already exists with an unrelated if-gated hook --"
F2="$SCRATCH/has-bare.json"
cat > "$F2" <<'JSONEOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo unrelated-guard; exit 2", "if": "Bash(some-other-thing*)" } ] }
    ]
  }
}
JSONEOF

bash "$ACTIVATE" "$F2" >/tmp/dcg-selftest-2.$$ 2>&1
BARE_HOOKS_2="$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash")] | length' "$F2" 2>/dev/null)"
HOOK_COUNT_2="$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]] | length' "$F2" 2>/dev/null)"
if [ "$BARE_HOOKS_2" = "1" ] && [ "$HOOK_COUNT_2" = "7" ] \
   && jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.if == "Bash(some-other-thing*)")' "$F2" >/dev/null 2>&1; then
  ok "has-bare: appended 6 hooks into the EXISTING matcher=Bash entry (1 entry, 7 hooks total), unrelated hook preserved"
else
  bad "has-bare: expected 1 entry / 7 hooks, got entries=$BARE_HOOKS_2 hooks=$HOOK_COUNT_2 file=$(cat "$F2")"
fi

bash "$ACTIVATE" "$F2" >/tmp/dcg-selftest-2b.$$ 2>&1
HOOK_COUNT_2B="$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]] | length' "$F2" 2>/dev/null)"
[ "$HOOK_COUNT_2B" = "7" ] && ok "has-bare: re-run is idempotent (still 7 hooks, no duplicates)" \
  || bad "has-bare: expected 7 after re-run, got $HOOK_COUNT_2B"

# ─────────────────────────────────────────────────────────────────────────
# Case 2b: an old-style entry's matcher happens to equal one of our
# canonical patterns, but its hooks are MIXED (one dangerous-command hook
# plus one unrelated hook riding on the same matcher) -- the cleanup pass
# must NOT drop this entry wholesale, since that would silently delete the
# unrelated hook too. Safer to leave a redundant-but-harmless old entry
# than to ever delete a hook this script doesn't own.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- case 2b: old-style entry with MIXED hooks (dangerous-command + unrelated) is not dropped --"
F2B="$SCRATCH/mixed.json"
cat > "$F2B" <<'JSONEOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash(rm -rf /*)", "hooks": [
          { "type": "command", "command": "/Users/athos/.local/bin/gt tap guard dangerous-command" },
          { "type": "command", "command": "echo also-does-something-else" }
        ]
      }
    ]
  }
}
JSONEOF

bash "$ACTIVATE" "$F2B" >/tmp/dcg-selftest-2c.$$ 2>&1
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash(rm -rf /*)") | .hooks | length == 2' "$F2B" >/dev/null 2>&1 \
   && jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.if == "Bash(rm -rf /*)")' "$F2B" >/dev/null 2>&1; then
  ok "mixed: old entry with a non-dangerous-command hook mixed in is preserved untouched, if-gated hook still added"
else
  bad "mixed: expected old mixed entry preserved (2 hooks) AND new if-gated hook added, got file=$(cat "$F2B")"
fi

# ─────────────────────────────────────────────────────────────────────────
# Case 3: multiple files in one invocation, each processed independently.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- case 3: multiple files in one invocation --"
F3A="$SCRATCH/multi-a.json"
F3B="$SCRATCH/multi-b.json"
echo '{}' > "$F3A"
echo '{}' > "$F3B"
bash "$ACTIVATE" "$F3A" "$F3B" >/tmp/dcg-selftest-3.$$ 2>&1
CA="$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]] | length' "$F3A" 2>/dev/null)"
CB="$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]] | length' "$F3B" 2>/dev/null)"
[ "$CA" = "6" ] && [ "$CB" = "6" ] && ok "multi: both files got all 6 if-gated hooks from a single invocation" \
  || bad "multi: expected 6/6, got a=$CA b=$CB"

# ─────────────────────────────────────────────────────────────────────────
# Case 4: backup file is created on write, not on a no-op idempotent run.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- case 4: backup created only when the file actually changes --"
BAK_COUNT_AFTER_WRITE="$(ls "$SCRATCH"/multi-a.json.bak.* 2>/dev/null | wc -l | tr -d ' ')"
bash "$ACTIVATE" "$F3A" >/tmp/dcg-selftest-4.$$ 2>&1
BAK_COUNT_AFTER_NOOP="$(ls "$SCRATCH"/multi-a.json.bak.* 2>/dev/null | wc -l | tr -d ' ')"
[ "$BAK_COUNT_AFTER_WRITE" = "1" ] && [ "$BAK_COUNT_AFTER_NOOP" = "1" ] \
  && ok "backup: 1 backup after the mutating run, no extra backup on the idempotent no-op run" \
  || bad "backup: expected 1 then 1, got $BAK_COUNT_AFTER_WRITE then $BAK_COUNT_AFTER_NOOP"

# ─────────────────────────────────────────────────────────────────────────
# Case 5: missing file is a hard failure, not a silent skip.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- case 5: missing target file fails loudly --"
bash "$ACTIVATE" "$SCRATCH/does-not-exist.json" >/tmp/dcg-selftest-5.$$ 2>&1
RC5=$?
[ "$RC5" -ne 0 ] && grep -q "FATAL" /tmp/dcg-selftest-5.$$ \
  && ok "missing file: non-zero exit with FATAL message" \
  || bad "missing file: expected non-zero exit + FATAL, got rc=$RC5 out=$(cat /tmp/dcg-selftest-5.$$)"

rm -f /tmp/dcg-selftest-*.$$ 2>/dev/null || true

echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
