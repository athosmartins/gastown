#!/usr/bin/env bash
# home-scan-guard-activate.selftest.sh (ga-02cqk4) -- hermetic tests for
# home-scan-guard-activate.sh. Runs against SCRATCH settings.json files under mktemp -d; never
# touches a live rig file. (Written AFTER the script, so it is mutation-tested: see the bead.)
#
# TEST: bash home-scan-guard-activate.selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTIVATE="$HERE/home-scan-guard-activate.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

STUB="$SCRATCH/guard-stub.sh"
export HOME_SCAN_GUARD_SCRIPT="$STUB"
export HOME_SCAN_GUARD_RIGS_ROOT="$SCRATCH/rigs"

# ours(file) -> number of hooks carrying the marker anywhere in PreToolUse
ours() { jq '[.hooks.PreToolUse[]? | (.hooks // [])[] | select((.command // "") | contains("home-scan-guard"))] | length' "$1" 2>/dev/null; }

# ─────────────────────────────────────────────────────────────────────────
echo "-- case 1: a settings.json with no hooks at all (a batista-style crew) --"
F1="$SCRATCH/no-hooks.json"
echo '{"permissions":{"deny":["Bash(sudo:*)"]},"env":{"X":"1"}}' > "$F1"
chmod 644 "$F1"
bash "$ACTIVATE" "$F1" >"$SCRATCH/o1" 2>&1; RC=$?
if [ "$RC" -eq 0 ] && [ "$(ours "$F1")" = "1" ] \
   && jq -e '.hooks.PreToolUse[0].matcher == "^Bash$" and .hooks.PreToolUse[0].hooks[0].type == "command" and .hooks.PreToolUse[0].hooks[0].timeout == 10' "$F1" >/dev/null \
   && jq -e '.permissions.deny == ["Bash(sudo:*)"] and .env.X == "1"' "$F1" >/dev/null; then
  ok "created ONE dedicated matcher="^Bash$" entry with one command hook (timeout 10); unrelated keys untouched"
else
  bad "no-hooks: rc=$RC ours=$(ours "$F1") file=$(cat "$F1") out=$(cat "$SCRATCH/o1")"
fi
jq -e '.hooks.PreToolUse[0].hooks[0] | has("if") | not' "$F1" >/dev/null \
  && ok "NO \"if\" field (the command-pattern never goes in matcher; this guard needs no if)" || bad "unexpected if field"
[ "$(stat -f '%Lp' "$F1" 2>/dev/null || stat -c '%a' "$F1")" = "644" ] && ok "file mode preserved (644, not mktemp's 600)" || bad "mode changed to $(stat -f '%Lp' "$F1" 2>/dev/null)"
ls "$F1".bak.* >/dev/null 2>&1 && ok "a backup of the previous file was kept" || bad "no backup created"

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- case 2: idempotent -- a second run changes nothing and makes no new backup --"
BEFORE="$(cat "$F1")"; NBAK_BEFORE="$(ls "$F1".bak.* 2>/dev/null | wc -l | tr -d ' ')"
bash "$ACTIVATE" "$F1" >"$SCRATCH/o2" 2>&1; RC=$?
NBAK_AFTER="$(ls "$F1".bak.* 2>/dev/null | wc -l | tr -d ' ')"
if [ "$RC" -eq 0 ] && [ "$BEFORE" = "$(cat "$F1")" ] && [ "$NBAK_BEFORE" = "$NBAK_AFTER" ] && grep -q '^GUARDED:' "$SCRATCH/o2" && [ "$(ours "$F1")" = "1" ]; then
  ok "second run: byte-identical, no new backup, reports GUARDED, still exactly one hook"
else
  bad "not idempotent: rc=$RC bak $NBAK_BEFORE->$NBAK_AFTER ours=$(ours "$F1") out=$(cat "$SCRATCH/o2")"
fi

# "guarded" is decided on the SEMANTIC state: a settings.json that already carries our hook but is
# formatted differently from jq's output (hand-edited, compact, other key order) must not be rewritten
# and re-backed-up on every run.
F2B="$SCRATCH/compact.json"; jq -c . "$F1" > "$F2B"
jq -S . "$F1" > "$SCRATCH/sorted.json"                       # same content, keys sorted
NB_BEFORE="$(ls "$F2B".bak.* 2>/dev/null | wc -l | tr -d ' ')"
bash "$ACTIVATE" "$F2B" "$SCRATCH/sorted.json" >"$SCRATCH/o2b" 2>&1; RC=$?
if [ "$RC" -eq 0 ] && [ "$(jq -c . "$F1")" = "$(cat "$F2B")" ] && [ "$(grep -c '^GUARDED:' "$SCRATCH/o2b")" = "2" ] \
   && [ "$(ls "$F2B".bak.* 2>/dev/null | wc -l | tr -d ' ')" = "$NB_BEFORE" ] && ! ls "$SCRATCH/sorted.json".bak.* >/dev/null 2>&1; then
  ok "already-guarded files that merely FORMAT differently (compact / key-sorted) are left byte-for-byte alone: no rewrite, no backup"
else
  bad "semantic-vs-byte: rc=$RC out=$(cat "$SCRATCH/o2b")"
fi

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- case 3: composes with existing hooks; NO existing entry is touched (engine identity trap) --"
# The engine merges pool overlays by matcher identity: an entry with matcher="Bash" REPLACES a
# base entry with matcher="Bash". This script therefore never adds to / edits a "Bash" entry -- it
# adds its own "^Bash$" entry -- and this case pins that the dangerous-command Bash entry survives
# byte-for-byte.
F3="$SCRATCH/existing.json"
cat > "$F3" <<'JSONEOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash(gh pr create*)", "hooks": [ { "type": "command", "command": "/Users/athos/.local/bin/gt tap guard pr-workflow" } ] },
      { "matcher": "Bash", "hooks": [
          { "type": "command", "command": "/Users/athos/.local/bin/gt tap guard dangerous-command", "if": "Bash(git reset --hard*)" },
          { "type": "command", "command": "/Users/athos/.local/bin/gt tap guard dangerous-command", "if": "Bash(git push -f*)" }
      ] },
      { "matcher": "Edit", "hooks": [ { "type": "command", "command": "echo edit-guard" } ] },
      { "hooks": [ { "type": "command", "command": "echo matcher-less-entry" } ] }
    ],
    "SessionStart": [ { "matcher": "", "hooks": [ { "type": "command", "command": "/Users/athos/.local/bin/gt prime --hook" } ] } ]
  }
}
JSONEOF
jq -c '.hooks.PreToolUse' "$F3" > "$SCRATCH/f3.pre.before"
jq -c '.hooks.SessionStart' "$F3" > "$SCRATCH/f3.ss.before"
bash "$ACTIVATE" "$F3" >"$SCRATCH/o3" 2>&1; RC=$?
jq -c '.hooks.PreToolUse[0:4]' "$F3" > "$SCRATCH/f3.pre.after"
if [ "$RC" -eq 0 ] && [ "$(ours "$F3")" = "1" ] \
   && cmp -s "$SCRATCH/f3.pre.before" "$SCRATCH/f3.pre.after" \
   && [ "$(jq -c '.hooks.SessionStart' "$F3")" = "$(cat "$SCRATCH/f3.ss.before")" ] \
   && jq -e '(.hooks.PreToolUse | length) == 5 and .hooks.PreToolUse[4].matcher == "^Bash$" and (.hooks.PreToolUse[4].hooks | length) == 1' "$F3" >/dev/null; then
  ok "the 4 existing PreToolUse entries (incl. the dangerous-command matcher=Bash one) are byte-identical, SessionStart too; ours is a 5th, separate entry"
else
  bad "existing-hooks: rc=$RC ours=$(ours "$F3") file=$(jq -c . "$F3") out=$(cat "$SCRATCH/o3")"
fi

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- case 4: converges -- stale/duplicate hooks of ours, wherever they sit, become exactly one --"
F4="$SCRATCH/stale.json"
cat > "$F4" <<'JSONEOF'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[
    {"type":"command","command":"/bin/bash /old/checkout/scripts/home-scan-guard.sh"},
    {"type":"command","command":"echo keep-me"},
    {"type":"command","command":"P='/other/home-scan-guard.sh'; exec /bin/bash \"$P\"","timeout":99}
  ]},
  {"matcher":"Bash","hooks":[{"type":"command","command":"/yet/another/home-scan-guard.sh"}]},
  {"matcher":"^Bash$","hooks":[{"type":"command","command":"/stale/in-place/home-scan-guard.sh"}]},
  {"matcher":"Write","hooks":[{"type":"command","command":"echo write-guard"}]},
  {"matcher":"^Bash$","hooks":[{"type":"command","command":"/duplicate/home-scan-guard.sh"}]}
]}}
JSONEOF
bash "$ACTIVATE" "$F4" >"$SCRATCH/o4" 2>&1; RC=$?
if [ "$RC" -eq 0 ] && [ "$(ours "$F4")" = "1" ] \
   && jq -e '(.hooks.PreToolUse | length) == 3' "$F4" >/dev/null \
   && jq -e '.hooks.PreToolUse[0].matcher == "Bash" and (.hooks.PreToolUse[0].hooks | length) == 1 and .hooks.PreToolUse[0].hooks[0].command == "echo keep-me"' "$F4" >/dev/null \
   && jq -e '.hooks.PreToolUse[1].matcher == "^Bash$" and .hooks.PreToolUse[1].hooks[0].timeout == 10 and (.hooks.PreToolUse[1].hooks | length) == 1' "$F4" >/dev/null \
   && jq -e '.hooks.PreToolUse[2].matcher == "Write"' "$F4" >/dev/null; then
  ok "stale hooks pulled out of foreign entries (foreign 'echo keep-me' kept; the entry that held only ours dropped); the ^Bash$ entry converged IN PLACE and its duplicate dropped; Write untouched"
else
  bad "converge: rc=$RC ours=$(ours "$F4") file=$(jq -c . "$F4") out=$(cat "$SCRATCH/o4")"
fi
bash "$ACTIVATE" "$F4" >"$SCRATCH/o4b" 2>&1
grep -q '^GUARDED:' "$SCRATCH/o4b" && ok "and the converged file is then stable (our entry is not moved to the end on every run)" || bad "converged file not stable: $(cat "$SCRATCH/o4b")"
# ours NOT last must stay stable too -- the failure mode of a naive remove-and-append
F4C="$SCRATCH/notlast.json"; echo '{}' > "$F4C"
bash "$ACTIVATE" "$F4C" >/dev/null 2>&1
jq '.hooks.PreToolUse += [{"matcher":"Edit","hooks":[{"type":"command","command":"echo later"}]}]' "$F4C" > "$F4C.t" && mv "$F4C.t" "$F4C"
bash "$ACTIVATE" "$F4C" >"$SCRATCH/o4c" 2>&1
grep -q '^GUARDED:' "$SCRATCH/o4c" && jq -e '.hooks.PreToolUse[0].matcher == "^Bash$" and .hooks.PreToolUse[1].matcher == "Edit"' "$F4C" >/dev/null \
  && ok "an entry added AFTER ours does not make ours move or the file look unguarded" || bad "not-last instability: $(cat "$SCRATCH/o4c") $(jq -c . "$F4C")"

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- case 5: --check writes nothing and reports honestly --"
F5="$SCRATCH/check.json"; echo '{"hooks":{}}' > "$F5"
cp "$F5" "$SCRATCH/check.before"
bash "$ACTIVATE" --check "$F5" >"$SCRATCH/o5" 2>&1; RC=$?
if [ "$RC" -eq 1 ] && grep -q '^NOT-GUARDED:' "$SCRATCH/o5" && cmp -s "$F5" "$SCRATCH/check.before" && ! ls "$F5".bak.* >/dev/null 2>&1; then
  ok "--check on an unguarded file: exit 1, NOT-GUARDED, file and backups untouched"
else
  bad "--check unguarded: rc=$RC out=$(cat "$SCRATCH/o5")"
fi
bash "$ACTIVATE" --check "$F1" "$F3" >"$SCRATCH/o5b" 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ "$(grep -c '^GUARDED:' "$SCRATCH/o5b")" = "2" ] && ok "--check on guarded files: exit 0, GUARDED x2" || bad "--check guarded: rc=$RC out=$(cat "$SCRATCH/o5b")"

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- case 6: one bad target never takes down the batch --"
FBAD="$SCRATCH/bad.json";  echo 'this is { not json' > "$FBAD"
FARR="$SCRATCH/array.json"; echo '[1,2,3]' > "$FARR"
FOK="$SCRATCH/ok.json";    echo '{}' > "$FOK"
bash "$ACTIVATE" "$FBAD" "$SCRATCH/missing.json" "$FARR" "$FOK" >"$SCRATCH/o6" 2>&1; RC=$?
if [ "$RC" -eq 1 ] && [ "$(ours "$FOK")" = "1" ] && [ "$(cat "$FBAD")" = 'this is { not json' ] && [ "$(cat "$FARR")" = '[1,2,3]' ]; then
  ok "unparseable, missing and non-object targets skipped untouched (exit 1); the good target after them was still guarded"
else
  bad "batch isolation: rc=$RC ok-ours=$(ours "$FOK") out=$(cat "$SCRATCH/o6")"
fi

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- case 7: the registered command really is fail-open and really propagates a block --"
CMD="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$F1")"
printf '#!/bin/bash\ncat >/dev/null\necho BLOCKED-BY-STUB >&2\nexit 2\n' > "$STUB"; chmod +x "$STUB"
OUT="$(echo '{}' | sh -c "$CMD" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 2 ] && [[ "$OUT" == *BLOCKED-BY-STUB* ]] && ok "guard present: its exit 2 and stderr reach Claude Code through the hook command" || bad "propagation: rc=$RC out=$OUT"
printf '#!/bin/bash\nexit 0\n' > "$STUB"
echo '{}' | sh -c "$CMD" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "guard present and allowing: exit 0" || bad "allow path: rc=$RC"
rm -f "$STUB"
OUT="$(echo '{}' | sh -c "$CMD" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "guard file GONE (checkout moved/cleaned): exit 0, silent -- never turns every Bash call into a hook error" || bad "missing guard: rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- case 8: input validation and default discovery --"
HOME_SCAN_GUARD_SCRIPT="relative/path.sh" bash "$ACTIVATE" "$FOK" >"$SCRATCH/o8" 2>&1; RC=$?
[ "$RC" -eq 1 ] && grep -q 'absolute' "$SCRATCH/o8" && ok "relative guard path refused" || bad "relative path: rc=$RC out=$(cat "$SCRATCH/o8")"
HOME_SCAN_GUARD_SCRIPT="/tmp/it's/bad.sh" bash "$ACTIVATE" "$FOK" >"$SCRATCH/o8b" 2>&1; RC=$?
[ "$RC" -eq 1 ] && grep -q 'single quote' "$SCRATCH/o8b" && ok "guard path with a single quote refused (it is embedded in single quotes)" || bad "quote path: rc=$RC out=$(cat "$SCRATCH/o8b")"
mkdir -p "$SCRATCH/rigs/wa/crew/batista/.claude" "$SCRATCH/rigs/wa/crew/.claude" "$SCRATCH/rigs/wa/witness/.claude" "$SCRATCH/rigs/wa/refinery/.claude" "$SCRATCH/rigs/wa/polecats/x/.claude" "$SCRATCH/rigs/ps/crew/worker/.claude"
for d in wa/crew/batista wa/crew wa/witness wa/refinery wa/polecats/x ps/crew/worker; do echo '{}' > "$SCRATCH/rigs/$d/.claude/settings.json"; done
bash "$ACTIVATE" >"$SCRATCH/o8c" 2>&1; RC=$?
N="$(grep -c '^Registered' "$SCRATCH/o8c")"
if [ "$RC" -eq 0 ] && [ "$N" = "5" ] && [ "$(ours "$SCRATCH/rigs/wa/crew/batista/.claude/settings.json")" = "1" ] && [ "$(ours "$SCRATCH/rigs/wa/polecats/x/.claude/settings.json")" = "0" ]; then
  ok "no args: discovers crew/*, crew, witness, refinery settings under the rigs root (5), and nothing else"
else
  bad "default discovery: rc=$RC registered=$N out=$(cat "$SCRATCH/o8c")"
fi
HOME_SCAN_GUARD_RIGS_ROOT="$SCRATCH/empty" bash "$ACTIVATE" >"$SCRATCH/o8d" 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok "nothing to target -> exit 1, not a silent success" || bad "empty discovery: rc=$RC"
bash "$ACTIVATE" --check >"$SCRATCH/o8e" 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "--check over the discovered set after activation: exit 0" || bad "--check discovered: rc=$RC out=$(cat "$SCRATCH/o8e")"
grep -q "/Users/athos/gt/.gascity-gastown-hq/scripts/home-scan-guard.sh" "$ACTIVATE" && ok "default guard path is the MAIN checkout, not a worktree" || bad "default guard path is not the main checkout"

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- case 8b: destructive-write hygiene --"
# a failed backup must stop the write: overwriting a live settings file we could not preserve is a destructive write on "don't know"
mkdir -p "$SCRATCH/ro"; F8B="$SCRATCH/ro/settings.json"; echo '{"keep":"me"}' > "$F8B"; chmod 555 "$SCRATCH/ro"
bash "$ACTIVATE" "$F8B" >"$SCRATCH/o8f" 2>&1; RC=$?
chmod 755 "$SCRATCH/ro"
if [ "$RC" -eq 1 ] && grep -q 'could not back up' "$SCRATCH/o8f" && [ "$(cat "$F8B")" = '{"keep":"me"}' ]; then
  ok "backup cannot be made -> exit 1, 'could not back up', file left exactly as it was"
else
  bad "unwritable backup dir: rc=$RC out=$(cat "$SCRATCH/o8f") file=$(cat "$F8B")"
fi
# a non-default mode survives the rewrite (no reliance on reading the mode: the write goes through a cp -p copy)
F8M="$SCRATCH/mode.json"; echo '{}' > "$F8M"; chmod 640 "$F8M"
bash "$ACTIVATE" "$F8M" >/dev/null 2>&1
[ "$(stat -f '%Lp' "$F8M" 2>/dev/null || stat -c '%a' "$F8M")" = "640" ] && ok "mode 640 preserved across the rewrite" || bad "mode changed to $(stat -f '%Lp' "$F8M" 2>/dev/null)"
ls "$SCRATCH"/*.new.* >/dev/null 2>&1 && bad "a temp .new file was left behind" || ok "no temp files left behind after a write"

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- case 9: the crew channel (this script) and the pool channel (role overlays) write the SAME entry --"
# Two channels, one hook: if they drifted, a workdir that is both (property_scrapers/crew/worker is a
# ps-worker workdir AND an activation target) would carry two different guards, or the engine's
# matcher-identity merge would replace one with the other.
F9="$SCRATCH/cross.json"; echo '{}' > "$F9"
env -u HOME_SCAN_GUARD_SCRIPT bash "$ACTIVATE" "$F9" >/dev/null 2>&1
A="$(jq -cS '.hooks.PreToolUse[0]' "$F9" 2>/dev/null)"
OVDIR="$HERE/../packs/town-deltas/assets/claude-overlays"
for role in pool-dog pool-wa-worker pool-ps-worker pool-reviewer; do
  B="$(jq -cS '.hooks.PreToolUse[0]' "$OVDIR/$role/.claude/settings.json" 2>/dev/null)"
  if [ -n "$A" ] && [ "$A" != "null" ] && [ "$A" = "$B" ]; then
    ok "$role overlay's PreToolUse entry == what the activation script writes for a crew (byte for byte, key-sorted)"
  else
    bad "$role overlay diverges from the activation script's entry: activation=$A overlay=$B"
  fi
done

echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
