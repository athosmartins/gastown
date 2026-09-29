#!/usr/bin/env bash
# cut-output-shadow.selftest.sh (ga-wk0qi2) -- hermetic tests for cut-output-shadow.sh's own
# prefilter/dispatch/fail-open behavior. cut_output_classifier.py's classification logic and
# cut-output-shadow.py's logging logic have their OWN selftest subcommands (pure Python,
# no network) -- this file only exercises the bash wrapper: does it skip python when it
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

# The wrapper now writes an ERROR row into jev-experiment.jsonl whenever a large-output call's measurement is
# lost, so every test below that makes it fail on purpose would append to the LIVE log (a stress run once left
# 40 junk rows in it that way). Point the default at a throwaway file for the whole suite; tests that read a log
# still pass their own JEV_EXPERIMENT_LOG explicitly, this is the net under the ones that don't.
export JEV_EXPERIMENT_LOG="$SCRATCH/jev-experiment.default.jsonl"

# hook_json <tool_name> <stdout> <stderr> [command] -> the PostToolUse JSON on stdin
hook_json() {
  jq -cn --arg t "$1" --arg out "$2" --arg err "$3" --arg cmd "${4-}" \
    '{tool_name:$t, tool_response:{stdout:$out, stderr:$err}, tool_use_id:"tu-test",
      session_id:"sess-test", transcript_path:"/tmp/sess-test.jsonl",
      tool_input:{command:$cmd}}'
}

# hook_failure_json <tool_name> <error> [command] -> the PostToolUseFailure JSON on stdin. Shape captured live
# from Claude Code 2.1.284: NO tool_response; the merged output is in `error` as "Exit code N\n<output>".
hook_failure_json() {
  jq -cn --arg t "$1" --arg err "$2" --arg cmd "${3-}" \
    '{hook_event_name:"PostToolUseFailure", tool_name:$t, error:$err, tool_use_id:"tu-fail",
      session_id:"sess-fail", transcript_path:"/tmp/sess-fail.jsonl", is_interrupt:false, duration_ms:1,
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

# Boundary: cut-output-shadow.py's process() joins stdout and stderr with ONE extra "\n" whenever
# stderr is non-empty, so the text the classifier gates on (len(text) >= 2000) is
# len(stdout) + 1 + len(stderr). The wrapper is documented as a SUPERSET prefilter (it may spawn
# python too often, never too rarely) -- at stdout 999 + stderr 1000 the classifier's text is 2000
# chars and would be classified, so the wrapper must let it through.
EDGE_OUT="$(python3 -c 'print("a" * 999, end="")')"
EDGE_ERR="$(python3 -c 'print("b" * 1000, end="")')"
EDGE="$(hook_json Bash "$EDGE_OUT" "$EDGE_ERR" 'noisy-tool')"
rm -f "$MARKER"
run "$EDGE" "CUT_OUTPUT_SHADOW_PY=$SCRATCH/marker-python"
if [ -f "$MARKER" ]; then ok "boundary: stdout 999 + stderr 1000 (classifier text = 2000 chars) -> python WAS spawned"
else bad "boundary: stdout 999 + stderr 1000 was skipped by the prefilter, but the classifier would have taken it (superset violated)"; fi
rm -f "$MARKER"

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- PostToolUseFailure (a Bash call that exited non-zero): the prefilter must read \`error\`, not tool_response --"
# ─────────────────────────────────────────────────────────────────────────
# gate_run ga-vrv1tz: PostToolUse does not fire for a Bash call that exits non-zero; PostToolUseFailure does, with
# no tool_response at all. The prefilter used to read only .tool_response.stdout/stderr, so a failure payload
# was sized 0 and dropped here -- before python was ever asked -- however large the output.
HDR=$'Exit code 1\n'
rm -f "$MARKER"
run "$(hook_failure_json Bash "${HDR}boom" 'false')" "CUT_OUTPUT_SHADOW_PY=$SCRATCH/marker-python"
if [ ! -f "$MARKER" ]; then ok "failure payload, small output: python was never spawned"
else bad "failure payload, small output: python WAS spawned"; fi

FAIL_BIG_OUT="$(python3 -c 'print("x" * 5000, end="")')"
rm -f "$MARKER"
run "$(hook_failure_json Bash "${HDR}${FAIL_BIG_OUT}" 'pytest')" "CUT_OUTPUT_SHADOW_PY=$SCRATCH/marker-python"
if [ -f "$MARKER" ]; then ok "failure payload, large output: python WAS spawned (the prefilter reads .error)"
else bad "failure payload, large output: python was never spawned -- the prefilter sized it 0 (blocking issue, ga-vrv1tz)"; fi

# The classifier gates on the OUTPUT (header stripped): len(output) >= 2000. The wrapper must agree at the edge
# for every header shape -- one digit, several, negative, and no header at all -- or it hides (or over-admits) a case.
edge_case() {  # edge_case <label> <error-string> <expect: spawn|skip>
  rm -f "$MARKER"
  run "$(hook_failure_json Bash "$2" 'noisy-tool')" "CUT_OUTPUT_SHADOW_PY=$SCRATCH/marker-python"
  if [ "$3" = spawn ]; then
    if [ -f "$MARKER" ]; then ok "boundary: $1 -> python spawned"; else bad "boundary: $1 was SKIPPED but the classifier would take it (superset violated)"; fi
  else
    if [ ! -f "$MARKER" ]; then ok "boundary: $1 -> python skipped"; else bad "boundary: $1 was spawned though the classifier gates it out (header counted as output?)"; fi
  fi
}
A1999="$(python3 -c 'print("a" * 1999, end="")')"; A2000="$(python3 -c 'print("a" * 2000, end="")')"
edge_case "'Exit code 1' + 1999 chars of output" $'Exit code 1\n'"$A1999" skip
edge_case "'Exit code 1' + 2000 chars of output" $'Exit code 1\n'"$A2000" spawn
edge_case "'Exit code 137' + 1999 chars (multi-digit header)" $'Exit code 137\n'"$A1999" skip
edge_case "'Exit code 137' + 2000 chars" $'Exit code 137\n'"$A2000" spawn
edge_case "'Exit code -1' + 1999 chars (negative code)" $'Exit code -1\n'"$A1999" skip
edge_case "'Exit code -1' + 2000 chars" $'Exit code -1\n'"$A2000" spawn
edge_case "'Exit code 1234' + 1999 chars (4 digits: still a header)" $'Exit code 1234\n'"$A1999" skip
A1980="$(python3 -c 'print("a" * 1980, end="")')"
edge_case "'Exit code' + a 20-digit number + 1980 chars: not a header, so the whole 2011 chars count" $'Exit code 99999999999999999999\n'"$A1980" spawn
edge_case "no header, 1999 chars (a timeout/interrupt error)" "$A1999" skip
edge_case "no header, 2000 chars" "$A2000" spawn

rm -f "$MARKER"
run "$(hook_failure_json Read "${HDR}${FAIL_BIG_OUT}" '')" "CUT_OUTPUT_SHADOW_PY=$SCRATCH/marker-python"
if [ ! -f "$MARKER" ]; then ok "failure payload for a non-Bash tool: python was never spawned"
else bad "failure payload for a non-Bash tool: python WAS spawned"; fi
expect_noop "failure payload: always {} on stdout (shadow contract)" "$(hook_failure_json Bash "${HDR}${FAIL_BIG_OUT}" 'pytest')"
expect_noop "error that is not a string -> {}" '{"tool_name":"Bash","error":{"message":"x"}}'
expect_noop "failure payload with no error field -> {}" '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash"}'

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

# The watchdog is `( sleep N && kill -9 pid ) &`. When the classifier finishes normally the wrapper
# stops the watchdog -- and used to kill only the subshell, orphaning its `sleep N` child for up to N
# seconds on EVERY large-output call (harmless one at a time; a process per call on a machine that is
# already at load 56-64). A distinctive N (4177) lets this test tell its own orphan from any other sleep.
# (The `[7]` keeps this script's own command line from matching its own pattern. Cleanup is by pid:
# pkill is blocked in agent sessions.)
kill_test_sleeps() { local p; for p in $(pgrep -f 'sleep 417[7]' 2>/dev/null); do kill "$p" >/dev/null 2>&1 || true; done; }
kill_test_sleeps
printf '#!/bin/sh\necho "{}"\n' > "$SCRATCH/py-fast"; chmod +x "$SCRATCH/py-fast"
run "$BIG" "CUT_OUTPUT_SHADOW_PY=$SCRATCH/py-fast" "CUT_OUTPUT_SHADOW_TIMEOUT=4177"
sleep 0.3
ORPHANS="$(pgrep -f 'sleep 417[7]' 2>/dev/null | wc -l | tr -d ' ')"
kill_test_sleeps  # never leave a 4177s sleep behind, pass or fail
if [ "$RC" -eq 0 ] && [ "$OUT" = "{}" ] && [ "$ORPHANS" = "0" ]; then
  ok "normal run: the watchdog's sleep is stopped with the watchdog -- no orphaned 'sleep' left behind"
else
  bad "watchdog cleanup: rc=$RC out=[$OUT] orphaned sleep processes=$ORPHANS"
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
echo "-- live dispatch to the REAL cut-output-shadow.py (fixed rule only: no network, no credential lookup) --"
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

# unstructured + large -> no fixed rule applies.
UNSTRUCT_OUT=$(python3 -c "
print('\n\n'.join(f'random unstructured paragraph {i} with generic prose text, no test or log shape' for i in range(80)))
")
UNSTRUCT_JSON="$(hook_json Bash "$UNSTRUCT_OUT" '' 'some-tool --verbose')"

# Mayor 28/09 23:1x (7th gate rejection): the Jev tier left this bead (ga-d0hm85), so a large output no fixed rule
# applies to must reach NOTHING outside the process: one 'unmatched' row, {} on stdout. "Jev is never contacted" is
# measured on the real process, not read off the source: JEV_SECRET_BIN points at a script that leaves a marker file
# if anything runs it (the credential lookup was the first thing the old tier did), and the credentials are
# unset so that lookup would have had to run it.
cat > "$SCRATCH/secret-marker" <<MARKER
#!/bin/sh
: > "$SCRATCH/secret-was-run"
exit 1
MARKER
chmod +x "$SCRATCH/secret-marker"
rm -f "$LOG" "$SCRATCH/secret-was-run"
run "$UNSTRUCT_JSON" "JEV_EXPERIMENT_LOG=$LOG" "CLOUDFLARE_ACCOUNT_ID=" "CLOUDFLARE_API_TOKEN=" "JEV_SECRET_BIN=$SCRATCH/secret-marker"
if [ "$RC" -eq 0 ] && [ "$OUT" = "{}" ] && [ ! -e "$SCRATCH/secret-was-run" ] && [ -f "$LOG" ] && [ "$(wc -l < "$LOG" | tr -d ' ')" = "1" ] \
   && [ "$(jq -r .experiment < "$LOG")" = "cut-output-fixed" ] && [ "$(jq -r .rule < "$LOG")" = "unmatched" ] \
   && [ "$(jq -r '.tokens_would_save | type' < "$LOG")" = "null" ] && [ "$(jq -r '.omitted_signatures | length' < "$LOG")" = "0" ]; then
  ok "live: large unstructured output -> the secret CLI is never run, one cut-output-fixed row with rule=unmatched and tokens_would_save=null, {} on stdout"
else
  bad "live unmatched case: rc=$RC out=[$OUT] secret-cli-was-run=[$([ -e "$SCRATCH/secret-was-run" ] && echo YES || echo no)] log=[$(cat "$LOG" 2>/dev/null)]"
fi

# a large FAILING pytest run (exit 1) through the real wrapper and the real engine: measured, and the row says
# it came from PostToolUseFailure with exit code 1 (the population the registration used to miss entirely)
FAIL_PYTEST_OUT=$(python3 -c "
print('=' * 30 + ' test session starts ' + '=' * 30)
for i in range(300):
    print(f't{i} PASSED')
print('_' * 20 + ' test_boom ' + '_' * 20)
print('E   assert 1 == 2')
print('=' * 20 + ' short test summary info ' + '=' * 20)
print('FAILED test_mod.py::test_boom - assert 1 == 2')
print('=' * 20 + ' 1 failed, 300 passed in 1.0s ' + '=' * 20, end='')
")
FAIL_PYTEST_JSON="$(hook_failure_json Bash "Exit code 1"$'\n'"$FAIL_PYTEST_OUT" 'pytest')"
rm -f "$LOG"
run "$FAIL_PYTEST_JSON" "JEV_EXPERIMENT_LOG=$LOG"
if [ "$RC" -eq 0 ] && [ "$OUT" = "{}" ] && [ -f "$LOG" ] && [ "$(wc -l < "$LOG" | tr -d ' ')" = "1" ] \
   && [ "$(jq -r .experiment < "$LOG")" = "cut-output-fixed" ] && [ "$(jq -r .rule < "$LOG")" = "pytest" ] \
   && [ "$(jq -r .hook_event < "$LOG")" = "PostToolUseFailure" ] && [ "$(jq -r .exit_code < "$LOG")" = "1" ] \
   && [ "$(jq -r '.tokens_would_save > 0' < "$LOG")" = "true" ]; then
  ok "live: a large FAILING pytest run (PostToolUseFailure) produces one cut-output-fixed row with hook_event=PostToolUseFailure, exit_code=1, a real saving, and {} on stdout"
else
  bad "live failing pytest case: rc=$RC out=[$OUT] log=[$(cat "$LOG" 2>/dev/null)]"
fi

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- a LOST measurement is COUNTED: every failure after the size gate leaves one error row (never a bare {}) --"
# ─────────────────────────────────────────────────────────────────────────
# gate_run ga-vrv1tz, medium finding: fail-open was silent AND uncounted -- a missing python3, a watchdog SIGKILL,
# an ImportError all ended as a bare "{}", so a dead hook read in the report exactly like a quiet day. Only calls
# that PASSED the size gate are counted: a call small enough to skip was never going to be measured.
row_count() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
error_row_count() { [ -f "$1" ] && jq -c 'select(.experiment == "cut-output-error")' "$1" 2>/dev/null | wc -l | tr -d ' ' || echo 0; }
expect_error_row() {  # expect_error_row <name> <stdin-json> <expected .error> [env...]
  local name="$1" input="$2" want="$3"; shift 3
  rm -f "$LOG"
  run "$input" "JEV_EXPERIMENT_LOG=$LOG" "$@"
  if [ "$RC" -eq 0 ] && [ "$OUT" = "{}" ] && [ "$(row_count "$LOG")" = "1" ] \
     && [ "$(jq -r .experiment < "$LOG")" = "cut-output-error" ] && [ "$(jq -r .stage < "$LOG")" = "wrapper" ] \
     && [ "$(jq -r .error < "$LOG")" = "$want" ] && [ "$(jq -r '.size | type' < "$LOG")" = "number" ]; then
    ok "$name -> {} AND one wrapper error row (error=$want)"
  else
    bad "$name: rc=$RC out=[$OUT] want error=$want log=[$(cat "$LOG" 2>/dev/null)]"
  fi
}
expect_no_error_row() {  # expect_no_error_row <name> <stdin-json> [env...]
  local name="$1" input="$2"; shift 2
  rm -f "$LOG"
  run "$input" "JEV_EXPERIMENT_LOG=$LOG" "$@"
  if [ "$RC" -eq 0 ] && [ "$OUT" = "{}" ] && [ "$(error_row_count "$LOG")" = "0" ]; then ok "$name -> no error row"
  else bad "$name: rc=$RC out=[$OUT] log=[$(cat "$LOG" 2>/dev/null)]"; fi
}

expect_error_row "python interpreter missing" "$BIG" python_missing "CUT_OUTPUT_SHADOW_PY=/nonexistent/python3"
expect_error_row "engine crashes (exit 1)" "$BIG" engine_rc_1 "CUT_OUTPUT_SHADOW_PY=$SCRATCH/py-crash"
expect_error_row "engine hangs -> watchdog SIGKILL (137)" "$BIG" engine_rc_137 "CUT_OUTPUT_SHADOW_PY=$SCRATCH/py-hang" "CUT_OUTPUT_SHADOW_TIMEOUT=2"
expect_error_row "engine prints invalid JSON" "$BIG" engine_bad_output "CUT_OUTPUT_SHADOW_PY=$SCRATCH/py-badjson"
expect_error_row "mktemp fails (TMPDIR unusable)" "$BIG" mktemp_failed "TMPDIR=/nonexistent/dir"
expect_error_row "the same on a PostToolUseFailure payload" "$FAIL_PYTEST_JSON" engine_rc_1 "CUT_OUTPUT_SHADOW_PY=$SCRATCH/py-crash"

mkdir -p "$SCRATCH/no-engine"; cp "$WRAPPER" "$SCRATCH/no-engine/cut-output-shadow.sh"
rm -f "$LOG"
OUT="$(printf '%s' "$BIG" | env "JEV_EXPERIMENT_LOG=$LOG" bash "$SCRATCH/no-engine/cut-output-shadow.sh" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "{}" ] && [ "$(row_count "$LOG")" = "1" ] && [ "$(jq -r .error < "$LOG")" = "engine_missing" ]; then
  ok "engine script missing next to the wrapper -> {} AND one error row (error=engine_missing)"
else bad "engine missing: rc=$RC out=[$OUT] log=[$(cat "$LOG" 2>/dev/null)]"; fi

# no error row where nothing was lost: small output, another tool, a clean engine run, the kill switch
expect_no_error_row "small Bash output (never a candidate)" "$SMALL"
expect_no_error_row "non-Bash tool with huge output" "$NONBASH"
expect_no_error_row "a clean engine run that prints {}" "$BIG" "CUT_OUTPUT_SHADOW_PY=$SCRATCH/py-fast"
: > "$DISABLED_FILE"
expect_no_error_row "kill switch on, huge output (an operator's choice, not a failure)" "$BIG" "CUT_OUTPUT_SHADOW_DISABLED=$DISABLED_FILE"
rm -f "$DISABLED_FILE"
expect_no_error_row "the real engine on a large pytest run (a healthy measurement)" "$PYTEST_JSON"

# The wrapper writes its row with printf (python is what may be broken), so the mode/experiment names are literals
# there. They must be the ones the classifier module defines -- and the report must actually count the row.
rm -f "$LOG"
run "$BIG" "JEV_EXPERIMENT_LOG=$LOG" "CUT_OUTPUT_SHADOW_PY=/nonexistent/python3"
if python3 - "$LOG" "$HERE" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[2])
import cut_output_classifier as coc
row = json.loads(open(sys.argv[1]).read().splitlines()[0])
assert row["mode"] == coc.RECORD_MODE, (row["mode"], coc.RECORD_MODE)
assert row["experiment"] == coc.ERROR_EXPERIMENT, (row["experiment"], coc.ERROR_EXPERIMENT)
assert isinstance(row["ts"], str) and row["entity_id"].startswith("wrapper-"), row
PY
then ok "the wrapper's literal mode/experiment names equal cut_output_classifier.RECORD_MODE / ERROR_EXPERIMENT"
else bad "the wrapper's error row does not match the classifier's constants: $(cat "$LOG")"; fi
REPORT_OUT="$(python3 "$HERE/jev_cut_output_report.py" --log "$LOG" 2>&1)"
if printf '%s' "$REPORT_OUT" | grep -q 'python_missing'; then ok "the real report counts the wrapper's row and names its reason (python_missing)"
else bad "report did not surface the wrapper's error row: $REPORT_OUT"; fi

echo ""
echo "cut-output-shadow.selftest.sh: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
