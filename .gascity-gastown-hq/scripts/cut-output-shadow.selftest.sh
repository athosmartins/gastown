#!/usr/bin/env bash
# cut-output-shadow.selftest.sh (ga-wk0qi2) -- hermetic tests for cut-output-shadow.sh's own
# prefilter/dispatch/fail-open behavior. cut_output_classifier.py's classification logic and
# cut-output-shadow.py's Jev/logging logic have their OWN selftest subcommands (pure Python,
# mocked network) -- this file only exercises the bash wrapper: does it skip python when it
# should, does it dispatch when it should, and does every failure mode still print "{}"/exit 0.
#
# TEST: bash cut-output-shadow.selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$HERE/cut-output-shadow.sh"
ENGINE="$HERE/cut-output-shadow.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

if [ ! -f "$WRAPPER" ] || [ ! -f "$ENGINE" ]; then
  echo "FATAL: wrapper or engine not found next to this file ($WRAPPER, $ENGINE)"
  exit 1
fi

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# hook_json <tool_name> <stdout> <stderr> [command] -> the PostToolUse JSON on stdin
hook_json() {
  jq -cn --arg t "$1" --arg out "$2" --arg err "$3" --arg cmd "${4-}" \
    '{tool_name:$t, tool_response:{stdout:$out, stderr:$err}, tool_use_id:"tu-test",
      session_id:"sess-test", transcript_path:"/tmp/sess-test.jsonl",
      tool_input:{command:$cmd}}'
}

run() {  # run <stdin-json> [env assignments...]
  local input="$1"; shift
  OUT="$(printf '%s' "$input" | env "$@" bash "$WRAPPER" 2>"$SCRATCH/stderr")"
  RC=$?
}

expect_noop() {  # name stdin-json [env...]
  local name="$1" input="$2"; shift 2
  run "$input" "$@"
  if [ "$RC" -eq 0 ] && [ "$OUT" = "{}" ]; then ok "$name"
  else bad "$name -- rc=$RC out=[$OUT] stderr=[$(cat "$SCRATCH/stderr")]"; fi
}

# ─────────────────────────────────────────────────────────────────────────
echo "-- always a no-op on stdout, regardless of internals (shadow mode contract) --"
# ─────────────────────────────────────────────────────────────────────────
SMALL="$(hook_json Bash 'tiny output' '')"
expect_noop "small Bash output -> {} " "$SMALL"

NONBASH="$(hook_json Read "$(python3 -c 'print("x"*5000)')" '')"
expect_noop "non-Bash tool_name, huge output -> {} " "$NONBASH"

expect_noop "empty stdin -> {} " ""
expect_noop "malformed JSON -> {} " "not json {{{"
expect_noop "JSON array (not object) -> {} " "[1,2,3]"
expect_noop "object missing tool_name -> {} " '{"tool_response":{"stdout":"x"}}'

# disabled sentinel short-circuits BEFORE even jq/stdin content matters
DISABLED_FILE="$SCRATCH/disabled"
: > "$DISABLED_FILE"
BIG_OUT="$(python3 -c 'print("x"*5000)')"
BIG="$(hook_json Bash "$BIG_OUT" '')"
expect_noop "disabled sentinel present -> {} even for huge Bash output" "$BIG" "CUT_OUTPUT_SHADOW_DISABLED=$DISABLED_FILE"
rm -f "$DISABLED_FILE"

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- prefilter: python is NOT spawned for small output --"
# ─────────────────────────────────────────────────────────────────────────
MARKER="$SCRATCH/python-was-invoked"
rm -f "$MARKER"
cat > "$SCRATCH/marker-python" <<EOF
#!/bin/sh
touch "$MARKER"
echo '{}'
EOF
chmod +x "$SCRATCH/marker-python"

run "$SMALL" "CUT_OUTPUT_SHADOW_PY=$SCRATCH/marker-python"
if [ ! -f "$MARKER" ]; then ok "small output: python was never spawned (prefilter short-circuits)"
else bad "small output: python WAS spawned (prefilter did not short-circuit)"; fi

run "$BIG" "CUT_OUTPUT_SHADOW_PY=$SCRATCH/marker-python"
if [ -f "$MARKER" ]; then ok "large output: python WAS spawned (prefilter let it through)"
else bad "large output: python was never spawned (prefilter over-filtered)"; fi
rm -f "$MARKER"

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- fail-open: every way the wrapper or classifier can misbehave still yields {} / rc 0 --"
# ─────────────────────────────────────────────────────────────────────────
expect_noop "python interpreter missing" "$BIG" "CUT_OUTPUT_SHADOW_PY=/nonexistent/python3"

printf '#!/bin/sh\nexit 1\n' > "$SCRATCH/py-crash"; chmod +x "$SCRATCH/py-crash"
expect_noop "classifier crashes (exit 1)" "$BIG" "CUT_OUTPUT_SHADOW_PY=$SCRATCH/py-crash"

printf '#!/bin/sh\nsleep 30\n' > "$SCRATCH/py-hang"; chmod +x "$SCRATCH/py-hang"
t0=$(date +%s)
run "$BIG" "CUT_OUTPUT_SHADOW_PY=$SCRATCH/py-hang" "CUT_OUTPUT_SHADOW_TIMEOUT=2"
t1=$(date +%s)
if [ "$RC" -eq 0 ] && [ "$OUT" = "{}" ] && [ $((t1 - t0)) -lt 10 ]; then
  ok "classifier hangs -> watchdog kills it within the configured timeout, {} returned"
else
  bad "hang case: rc=$RC out=[$OUT] elapsed=$((t1 - t0))s"
fi

printf '#!/bin/sh\necho "not valid json at all"\n' > "$SCRATCH/py-badjson"; chmod +x "$SCRATCH/py-badjson"
expect_noop "classifier prints invalid JSON" "$BIG" "CUT_OUTPUT_SHADOW_PY=$SCRATCH/py-badjson"

printf '#!/bin/sh\necho \x27{"hookSpecificOutput":{"unexpected":true}}\x27\n' > "$SCRATCH/py-oddjson"; chmod +x "$SCRATCH/py-oddjson"
run "$BIG" "CUT_OUTPUT_SHADOW_PY=$SCRATCH/py-oddjson"
if [ "$RC" -eq 0 ] && [ "$OUT" = '{"hookSpecificOutput":{"unexpected":true}}' ]; then
  ok "classifier prints SOME valid JSON -> relayed verbatim (defense-in-depth only rejects invalid JSON, not unexpected shape)"
else
  bad "valid-but-odd JSON relay: rc=$RC out=[$OUT]"
fi

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- live dispatch to the REAL cut-output-shadow.py (no network: fixed-rule + Jev-unreachable third state) --"
# ─────────────────────────────────────────────────────────────────────────
LOG="$SCRATCH/jev-experiment.jsonl"
PYTEST_OUT=$(python3 -c "
print('=' * 30 + ' test session starts ' + '=' * 30)
for i in range(300):
    print(f't{i} PASSED')
print('=' * 30 + ' 300 passed in 1.0s ' + '=' * 30)
")
PYTEST_JSON="$(hook_json Bash "$PYTEST_OUT" '' 'pytest')"
rm -f "$LOG"
run "$PYTEST_JSON" "JEV_EXPERIMENT_LOG=$LOG"
if [ "$RC" -eq 0 ] && [ "$OUT" = "{}" ] && [ -f "$LOG" ] && [ "$(wc -l < "$LOG" | tr -d ' ')" = "1" ] \
   && [ "$(jq -r .experiment < "$LOG")" = "cut-output-fixed" ]; then
  ok "live: a large pytest output produces exactly one cut-output-fixed shadow log line, and {} on stdout"
else
  bad "live pytest case: rc=$RC out=[$OUT] log=[$(cat "$LOG" 2>/dev/null)]"
fi

# unstructured + large -> Jev tier. Force jev_experiment's credential resolution to fail
# (no_credentials) so this stays fully offline and deterministic, and still checks the wrapper's
# real end-to-end plumbing into cut-output-shadow.py's Jev-unreachable THIRD STATE.
UNSTRUCT_OUT=$(python3 -c "
print('\n\n'.join(f'random unstructured paragraph {i} with generic prose text, no test or log shape' for i in range(80)))
")
UNSTRUCT_JSON="$(hook_json Bash "$UNSTRUCT_OUT" '' 'some-tool --verbose')"
rm -f "$LOG"
run "$UNSTRUCT_JSON" "JEV_EXPERIMENT_LOG=$LOG" "CLOUDFLARE_ACCOUNT_ID=" "CLOUDFLARE_API_TOKEN=" "JEV_SECRET_BIN=/nonexistent/secret"
if [ "$RC" -eq 0 ] && [ "$OUT" = "{}" ] && [ -f "$LOG" ] && [ "$(wc -l < "$LOG" | tr -d ' ')" = "1" ] \
   && [ "$(jq -r .experiment < "$LOG")" = "cut-output-jev" ] \
   && [ "$(jq -r .jev_ok < "$LOG")" = "false" ] && [ "$(jq -r .blocks < "$LOG")" = "null" ]; then
  ok "live: large unstructured output + no Jev credentials -> one cut-output-jev shadow log line, jev_ok=false, blocks=null (third state), {} on stdout"
else
  bad "live unstructured case: rc=$RC out=[$OUT] log=[$(cat "$LOG" 2>/dev/null)]"
fi

echo ""
echo "cut-output-shadow.selftest.sh: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
