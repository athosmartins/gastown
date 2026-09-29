#!/usr/bin/env bash
# cut-output-shadow.sh (ga-wk0qi2, child of ga-aijm2v) -- PostToolUse:Bash AND PostToolUseFailure:Bash hook wrapper.
# SHADOW MODE ONLY: this always emits "{}" (a no-op hookSpecificOutput) on stdout. It never
# blocks, never modifies a real tool result, and every failure mode here is exit 0. See
# cut-output-shadow.py's own header for the full design (fixed-rule + Jev two-tier measurement,
# PASSO 0's updatedToolOutput shape finding, fail-open discipline).
#
# TWO EVENTS, ONE WRAPPER: Claude Code sends a Bash call's output on PostToolUse only when the call SUCCEEDED
# (payload: tool_response.stdout/stderr); a call that exits non-zero fires PostToolUseFailure INSTEAD, with no
# tool_response and the merged output in `error` as "Exit code N\n<output>" (verified live, Claude Code
# 2.1.284, gate_run ga-vrv1tz). Registered for PostToolUse alone, this hook measured only the commands that
# worked. pool-roles.json registers this wrapper on both events; the prefilter below sizes either shape.
#
# FAIL-OPEN BUT COUNTED: nothing here ever blocks or alters the real call, but a large-output call whose
# measurement is LOST (python or the engine missing, mktemp failing, the engine crashing or killed by the
# watchdog, or printing something that is not JSON) leaves ONE row in jev-experiment.jsonl (experiment
# cut-output-error, log_lost() below). A hook that died on every call used to read in the report exactly like a
# quiet day. Only calls past the size gate are counted -- a call small enough to skip was never going to be
# measured. NOT counted, and the report says so: jq missing or an unparseable payload (the call cannot even be
# sized), an unwritable log (nowhere to write the row), and a missing wrapper script (the inline command that
# invokes this file prints {} on its own).
#
# WHY A BASH PREFILTER (same reasoning as home-scan-guard.sh): this hook is registered with
# matcher "^Bash$" in pool-roles.json, so it runs on EVERY Bash call of every pool session
# (dog/wa-worker/ps-worker/reviewer) in the city. python3 costs ~100-280ms to start under this
# city's load. The overwhelming majority of Bash calls have small output that the classifier
# would ignore anyway (cut_output_classifier.MIN_CHARS_TO_CONSIDER), so this wrapper answers
# "is this call even worth a python spawn" with one jq call before ever touching python.
#
# The threshold below (CUT_OUTPUT_SHADOW_MIN_CHARS, default 2000) MUST stay a same-or-smaller
# number than cut_output_classifier.py's MIN_CHARS_TO_CONSIDER -- this is a SUPERSET prefilter
# (same discipline as home-scan-guard.sh's prefilter/classifier split): if this wrapper skipped
# python for something the classifier would have acted on, that measurement is silently lost.
# The size it compares is len(stdout) + len(stderr) plus the one newline the engine inserts
# between them when stderr is non-empty -- i.e. exactly the length of the text the classifier
# gates on -- so at the default thresholds nothing the classifier would have taken is skipped here.
# (Only if someone RAISES this threshold above MIN_CHARS_TO_CONSIDER does the wrapper start hiding
# cases; keep it the same or smaller.)
set -u

# ---- 0. kill switch (checked before anything else, including jq) -------------------------
DISABLED="${CUT_OUTPUT_SHADOW_DISABLED:-/Users/athos/gt/.gascity-gastown-hq/.gc/logs/cut-output-shadow.disabled}"
if [ -f "$DISABLED" ]; then
  echo "{}"
  exit 0
fi

# log_lost <reason> -- one error row for a large-output call whose measurement was lost. `size` (set by the
# prefilter, digits only) and `reason` (a fixed [a-z0-9_] vocabulary, or engine_rc_<digits>) are the only fields
# interpolated, so the line is valid JSON without escaping; no payload text goes in. The mode/experiment names
# are literals because python is what may be broken -- they must equal cut_output_classifier.RECORD_MODE and
# ERROR_EXPERIMENT (cut-output-shadow.selftest.sh compares them). Never fails the hook.
size=0
log_lost() {
  local log ts id
  log="${JEV_EXPERIMENT_LOG:-/Users/athos/gt/.gascity-gastown-hq/.gc/logs/jev-experiment.jsonl}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  id="wrapper-$(date +%s 2>/dev/null)-$$-${RANDOM:-0}"
  printf '{"ts":"%s","mode":"cut-output","experiment":"cut-output-error","entity_id":"%s","stage":"wrapper","error":"%s","size":%s}\n' \
    "$ts" "$id" "$1" "$size" >> "$log" 2>/dev/null || true
}

# ---- 1. read + cheap prefilter (bash + one jq spawn) --------------------------------------
input="$(cat 2>/dev/null)"
if [ -z "$input" ]; then
  echo "{}"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "{}"
  exit 0
fi

MIN_CHARS="${CUT_OUTPUT_SHADOW_MIN_CHARS:-2000}"
tool=""; jq_ok=""
{
  IFS= read -r -d '' tool
  IFS= read -r -d '' size
  IFS= read -r -d '' jq_ok
} < <(printf '%s' "$input" | jq -j '
    (if type == "object" then . else {} end) as $h
    # The length of the text the engine will classify (cut-output-shadow.py read_bash_output(); same shape
    # decision, same order: tool_response first). PostToolUse (success): stdout + "\n" + stderr when stderr is
    # non-empty -- count that one joining newline too, or a combined length of exactly MIN-1 would be skipped
    # here although the classifier would have taken it. PostToolUseFailure (non-zero exit): NO tool_response;
    # the output is `error` MINUS its "Exit code N" header (N at most 4 digits, the same bound as the classifier
    # module regex _EXIT_CODE_HEADER_RE; header + ONE newline, at the very start). The old prefilter sized this
    # shape 0, so every failing command was dropped before python was asked.
    | (if ($h.tool_response | type) == "object" then
         ((($h.tool_response.stdout? // "") | if type == "string" then . else "" end | length) as $o
          | (($h.tool_response.stderr? // "") | if type == "string" then . else "" end | length) as $e
          | ($o + $e + (if $e > 0 then 1 else 0 end)))
       elif ($h.error | type) == "string" then
         ($h.error | sub("\\AExit code -?[0-9]{1,4}(\\n|\\z)"; "") | length)
       else 0 end) as $n
    | ($h.tool_name | if type == "string" then . else "" end), "\u0000",
      ($n | tostring), "\u0000",
      "ok", "\u0000"' 2>/dev/null)

if [ "$jq_ok" != "ok" ] || [ "$tool" != "Bash" ]; then
  echo "{}"
  exit 0
fi
case "$size" in
  ''|*[!0-9]*) echo "{}"; exit 0 ;;  # unparseable size -> do nothing, never guess
esac
if [ "$size" -lt "$MIN_CHARS" ]; then
  echo "{}"
  exit 0
fi

# ---- 2. dispatch to the real classifier, under a hard timeout ------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "$HERE" ]; then
  log_lost here_unresolved
  echo "{}"
  exit 0
fi
ENGINE="$HERE/cut-output-shadow.py"
if [ ! -f "$ENGINE" ]; then
  log_lost engine_missing
  echo "{}"
  exit 0
fi
PY="${CUT_OUTPUT_SHADOW_PY:-$(command -v python3 2>/dev/null)}"
if [ -z "$PY" ] || [ ! -x "$PY" ]; then
  log_lost python_missing
  echo "{}"
  exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cut-output-shadow.XXXXXX" 2>/dev/null)"
if [ -z "$tmp" ]; then
  log_lost mktemp_failed
  echo "{}"
  exit 0
fi
trap 'rm -rf "$tmp"' EXIT
printf '%s' "$input" > "$tmp/in" 2>/dev/null || { log_lost tmp_write_failed; echo "{}"; exit 0; }

"$PY" "$ENGINE" < "$tmp/in" > "$tmp/out" 2>"$tmp/err" &
pid=$!
# Watchdog: `sleep N && kill -9 pid`. The sleep is a background child of the watchdog subshell and its pid
# goes to a file, so it can be stopped BY PID once the classifier is done -- killing only the subshell
# used to orphan `sleep N` (up to 12s) on every large-output call. By pid, not pkill: pkill is blocked in
# agent sessions, and these hooks run in exactly those sessions. `wait $! && kill -9`: a sleep stopped
# early exits non-zero, so the kill -9 is skipped.
(
  sleep "${CUT_OUTPUT_SHADOW_TIMEOUT:-12}" &
  echo $! > "$tmp/sleeper.pid"
  wait $! && kill -9 "$pid"
) >/dev/null 2>&1 &
watchdog=$!
disown "$watchdog" 2>/dev/null
{ wait "$pid"; rc=$?; } 2>/dev/null
# Stop the watchdog: its sleep first, then the subshell. The recorded pid is only signalled while it is
# still the watchdog's own child (a pid that already exited could have been reused by anything).
sleeper=""
read -r sleeper 2>/dev/null < "$tmp/sleeper.pid"  # stderr first: a missing file's error must not leak
case "$sleeper" in
  ''|*[!0-9]*) ;;
  *) [ "$(ps -o ppid= -p "$sleeper" 2>/dev/null | tr -d ' ')" = "$watchdog" ] && kill "$sleeper" >/dev/null 2>&1 ;;
esac
kill "$watchdog" >/dev/null 2>&1

# Trust the classifier's own output ONLY if it ran cleanly (rc 0) and printed valid JSON --
# defense in depth on top of cut-output-shadow.py's own fail-open discipline, in case the
# interpreter itself is broken in a way that corrupts stdout instead of erroring. Either way the agent gets a
# valid answer; the difference is only that a lost measurement leaves its row (rc 137 = the watchdog's SIGKILL).
if [ "$rc" -ne 0 ]; then
  log_lost "engine_rc_$rc"
  echo "{}"
elif [ -s "$tmp/out" ] && jq -e . >/dev/null 2>&1 < "$tmp/out"; then
  cat "$tmp/out"
else
  log_lost engine_bad_output
  echo "{}"
fi
exit 0
