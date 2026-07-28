#!/usr/bin/env bash
# pkill-blast-guard.selftest.sh (ga-jo3xl) — hermetic tests for
# pkill-blast-guard.py and pkill-blast-guard-activate.sh.
#
# Drives the guard as a real subprocess (feeding it the exact JSON a Claude
# Code PreToolUse:Bash hook receives on stdin) and asserts on its stdout
# JSON + exit code. No mocking of the guard's own logic — this is the real
# script, real shlex tokenizing, real pgrep. The only faked state is a
# handful of throwaway `sleep` decoy processes this file spawns itself (for
# the >N-matches and matches-a-claude-process cases), which it always kills
# in a trap before exiting. Never touches a real claude session or any
# production process.
#
# TEST: bash scripts/pkill-blast-guard.selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/pkill-blast-guard.py"
ACTIVATE="$HERE/pkill-blast-guard-activate.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# decoy PIDs spawned by the >N / matches-claude test cases, always reaped.
DECOY_PIDS=()
cleanup() {
  for pid in "${DECOY_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

# run_guard <command-string> [extra_env...] -> sets OUT (stdout) and RC (exit code)
run_guard() {
  local cmd="$1"; shift
  local payload
  payload="$(jq -n --arg cmd "$cmd" '{tool_name:"Bash",tool_input:{command:$cmd}}')"
  OUT="$(printf '%s' "$payload" | env "$@" python3 "$GUARD" 2>/tmp/pkill-guard-selftest-stderr.$$)"
  RC=$?
}

decision_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "allow-implicit"' 2>/dev/null; }

echo "=== pkill-blast-guard.selftest.sh ==="

# ─────────────────────────────────────────────────────────────────────────────
# AC6(i): the EXACT incident line must be BLOCKED.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC6(i): exact incident line is blocked --"
run_guard 'pkill -f "anuncios_dashboard.py" -U $(id -u)'
if [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ]; then
  ok "incident line denied (pattern not last)"
else
  bad "incident line should be denied, got rc=$RC out=$OUT"
fi
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("PATTERN must be the LAST argument")' >/dev/null 2>&1 \
  && ok "deny reason teaches the correct form (AC5)" \
  || bad "deny reason should teach the correct form, got: $(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // "MISSING"')"

# ─────────────────────────────────────────────────────────────────────────────
# AC6(ii): the 3 AC3 safe forms must PASS (allow).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC6(ii): AC3 safe forms are allowed --"

run_guard "pkill -f 'ANUNCIOS_PORT=8214'"
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "pkill -f 'ANUNCIOS_PORT=8214' allowed" \
  || bad "pkill -f 'ANUNCIOS_PORT=8214' should be allowed, got rc=$RC out=$OUT"

run_guard 'kill $PID'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "kill \$PID allowed (not pkill/killall at all)" \
  || bad "kill \$PID should be allowed untouched, got rc=$RC out=$OUT"

run_guard "pkill -9 -f 'adb.*fork-server'"
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "pkill -9 -f 'adb.*fork-server' allowed" \
  || bad "pkill -9 -f 'adb.*fork-server' should be allowed, got rc=$RC out=$OUT"

# Non-Bash tool calls and non-pkill commands must be untouched too.
run_guard_raw_tool() {
  local payload="$1"
  OUT="$(printf '%s' "$payload" | python3 "$GUARD" 2>/dev/null)"; RC=$?
}
run_guard_raw_tool '{"tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "non-Bash tool_name ignored" \
  || bad "non-Bash tool_name should be a no-op allow, got rc=$RC out=$OUT"

run_guard 'ls -la /tmp'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "ordinary command with no pkill/killall allowed" \
  || bad "ordinary command should be allowed, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────────
# AC6(iii): broken hook (internal error / forced exception) fails OPEN.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC6(iii): internal error fails OPEN --"
run_guard 'pkill -f "anuncios_dashboard.py" -U $(id -u)' PKILL_GUARD_SELFTEST_FORCE_ERROR=1
if [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ]; then
  ok "forced internal error on an otherwise-dangerous command still ALLOWS (fail-open, AC4)"
else
  bad "forced internal error should fail OPEN (allow), got rc=$RC out=$OUT"
fi

# Malformed / unparseable JSON on stdin must also fail open, not crash.
OUT="$(printf 'not json at all' | python3 "$GUARD" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "malformed stdin JSON fails OPEN (rc=0, no deny)" \
  || bad "malformed stdin should fail open, got rc=$RC out=$OUT"

# Unbalanced quotes (unparseable shell string) must fail open too.
run_guard 'pkill -f "unterminated'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "unbalanced quotes in command string fails OPEN" \
  || bad "unbalanced-quote command should fail open, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────────
# AC2(c): pattern matching more than N processes is blocked (using disposable
# decoy processes, never real ones). Spawn 7 to safely clear the default N=5.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC2(c): pattern matching more than N processes is blocked --"
MARKER_MANY="pkill-guard-selftest-many-$$"
for _ in 1 2 3 4 5 6 7; do
  bash -c "exec -a $MARKER_MANY sleep 60" &
  DECOY_PIDS+=("$!")
  disown 2>/dev/null || true
done
sleep 0.3   # let the decoys register in the process table before pgrep runs
run_guard "pkill -f '$MARKER_MANY'"
if [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ]; then
  ok "pattern matching 7 decoy processes (> default N=5) denied"
else
  bad "pattern matching 7 processes should be denied, got rc=$RC out=$OUT"
fi
# same pattern, but with the threshold raised via env -> must now be allowed.
run_guard "pkill -f '$MARKER_MANY'" PKILL_GUARD_MAX_MATCHES=50
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "same pattern allowed once PKILL_GUARD_MAX_MATCHES raised above the match count" \
  || bad "raising PKILL_GUARD_MAX_MATCHES should allow it through, got rc=$RC out=$OUT"
for pid in "${DECOY_PIDS[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done
DECOY_PIDS=()

# ─────────────────────────────────────────────────────────────────────────────
# AC2(b): pattern matching a process whose command line contains "claude" is
# blocked, using a disposable decoy (never a real claude session).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC2(b): pattern matching a 'claude'-containing process is blocked --"
MARKER_CLAUDE="pkill-guard-selftest-decoy-claude-proc-$$"
bash -c "exec -a $MARKER_CLAUDE sleep 60" &
DECOY_PIDS+=("$!")
disown 2>/dev/null || true
sleep 0.3
run_guard "pkill -f '$MARKER_CLAUDE'"
if [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ]; then
  ok "pattern matching a decoy process with 'claude' in its command line denied"
else
  bad "pattern matching a 'claude'-named decoy should be denied, got rc=$RC out=$OUT"
fi
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("claude")' >/dev/null 2>&1 \
  && ok "claude-match deny reason names the reason" \
  || bad "claude-match deny reason should mention claude, got: $(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // "MISSING"')"
for pid in "${DECOY_PIDS[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done
DECOY_PIDS=()

# ─────────────────────────────────────────────────────────────────────────────
# Activation script: idempotent compose-not-replace merge into a SCRATCH
# settings.json (never the live file).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- pkill-blast-guard-activate.sh: composes with existing hooks, idempotent --"
TMP_SETTINGS="$(mktemp)"
cat > "$TMP_SETTINGS" <<'JSONEOF'
{
  "awaySummaryEnabled": false,
  "hooks": {
    "SessionStart": [
      { "matcher": "startup", "hooks": [ { "type": "command", "command": "gc prime --hook" } ] }
    ]
  }
}
JSONEOF

PKILL_GUARD_CITY="$(cd "$HERE/.." && pwd)" bash "$ACTIVATE" "$TMP_SETTINGS" >/tmp/pkill-guard-activate-selftest.$$ 2>&1
ACT_RC=$?
if [ "$ACT_RC" -eq 0 ] \
   && jq -e '.hooks.SessionStart[0].hooks[0].command == "gc prime --hook"' "$TMP_SETTINGS" >/dev/null 2>&1 \
   && jq -e '.hooks.PreToolUse[0].matcher == "Bash"' "$TMP_SETTINGS" >/dev/null 2>&1 \
   && jq -e '.hooks.PreToolUse[0].hooks[0].command | contains("pkill-blast-guard.py")' "$TMP_SETTINGS" >/dev/null 2>&1; then
  ok "activate: added PreToolUse:Bash hook, left the existing SessionStart hook untouched (compose, not replace)"
else
  bad "activate: expected SessionStart preserved + PreToolUse added, got: $(cat "$TMP_SETTINGS")"
fi

# Re-run: must stay idempotent (exactly one PreToolUse entry, not two).
PKILL_GUARD_CITY="$(cd "$HERE/.." && pwd)" bash "$ACTIVATE" "$TMP_SETTINGS" >/tmp/pkill-guard-activate-selftest2.$$ 2>&1
COUNT="$(jq '.hooks.PreToolUse | length' "$TMP_SETTINGS" 2>/dev/null)"
[ "$COUNT" = "1" ] && ok "activate: re-running is idempotent (still exactly 1 PreToolUse entry)" \
  || bad "activate: expected exactly 1 PreToolUse entry after re-run, got $COUNT"

rm -f "$TMP_SETTINGS" /tmp/pkill-guard-activate-selftest.$$ /tmp/pkill-guard-activate-selftest2.$$ /tmp/pkill-guard-selftest-stderr.$$ 2>/dev/null || true

echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
