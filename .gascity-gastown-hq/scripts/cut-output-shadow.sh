#!/usr/bin/env bash
# cut-output-shadow.sh (ga-wk0qi2, child of ga-aijm2v) -- PostToolUse:Bash hook wrapper.
# SHADOW MODE ONLY: this always emits "{}" (a no-op hookSpecificOutput) on stdout. It never
# blocks, never modifies a real tool result, and every failure mode here is exit 0. See
# cut-output-shadow.py's own header for the full design (fixed-rule + Jev two-tier measurement,
# PASSO 0's updatedToolOutput shape finding, fail-open discipline).
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
tool=""; size=0; jq_ok=""
{
  IFS= read -r -d '' tool
  IFS= read -r -d '' size
  IFS= read -r -d '' jq_ok
} < <(printf '%s' "$input" | jq -j '
    (if type == "object" then . else {} end) as $h
    | (($h.tool_response.stdout? // "") | if type == "string" then . else "" end | length) as $o
    | (($h.tool_response.stderr? // "") | if type == "string" then . else "" end | length) as $e
    | ($h.tool_name | if type == "string" then . else "" end), "\u0000",
      # the classifier sees stdout + "\n" + stderr when stderr is non-empty (cut-output-shadow.py
      # process()), so count that one joining newline here too -- otherwise a combined length of
      # exactly MIN-1 would be skipped here although the classifier would have taken it.
      (($o + $e + (if $e > 0 then 1 else 0 end)) | tostring), "\u0000",
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
  echo "{}"
  exit 0
fi
ENGINE="$HERE/cut-output-shadow.py"
if [ ! -f "$ENGINE" ]; then
  echo "{}"
  exit 0
fi
PY="${CUT_OUTPUT_SHADOW_PY:-$(command -v python3 2>/dev/null)}"
if [ -z "$PY" ] || [ ! -x "$PY" ]; then
  echo "{}"
  exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cut-output-shadow.XXXXXX" 2>/dev/null)"
if [ -z "$tmp" ]; then
  echo "{}"
  exit 0
fi
trap 'rm -rf "$tmp"' EXIT
printf '%s' "$input" > "$tmp/in" 2>/dev/null || { echo "{}"; exit 0; }

"$PY" "$ENGINE" < "$tmp/in" > "$tmp/out" 2>"$tmp/err" &
pid=$!
( sleep "${CUT_OUTPUT_SHADOW_TIMEOUT:-12}"; kill -9 "$pid" ) >/dev/null 2>&1 &
watchdog=$!
disown "$watchdog" 2>/dev/null
{ wait "$pid"; rc=$?; } 2>/dev/null
kill "$watchdog" >/dev/null 2>&1

# Trust the classifier's own output ONLY if it ran cleanly (rc 0) and printed valid JSON --
# defense in depth on top of cut-output-shadow.py's own fail-open discipline, in case the
# interpreter itself is broken in a way that corrupts stdout instead of erroring.
if [ "$rc" -eq 0 ] && [ -s "$tmp/out" ] && jq -e . >/dev/null 2>&1 < "$tmp/out"; then
  cat "$tmp/out"
else
  echo "{}"
fi
exit 0
