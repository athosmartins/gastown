#!/usr/bin/env bash
# prod-tests/gascity/story-ga-hpdpij.sh — prod test for ga-hpdpij: the reaper's DOG_DONE summary is DURABLE
# (one line per run in .gc/runtime/reaper-summary.log, rotated) and the orphan child rows of wisps that no longer
# exist are COUNTED every run — whether or not the orphan sweep runs — with a read that failed reading "unknown",
# never 0.
#
# Background: the summary only ever left the script as `gc session nudge deacon/ ... || true` and a stdout echo (0
# hits in .gc/events.jsonl or the deacon transcript), and while the sweep was stopped by its free-disk floor no NEW
# orphan was counted or alerted, so with the backlog at 0 their return would have been invisible.
#
# Called by run.sh after deploy (STORY_ID=ga-hpdpij). Exits 0 on pass. Hermetic: it only READS the deployed reaper
# and runs the story's selftest against it, which uses throwaway local Dolt repos with stub gc/bd/df — no live
# database is queried, no mail or nudge is sent. It deliberately does NOT assert that the LIVE log already exists:
# the reaper is an order that fires every 30 min, so right after a deploy the first live line may be minutes away
# (look for it with `tail -2 $CITY/.gc/runtime/reaper-summary.log`). CITY overrides the city dir (scratch runs; it
# is the directory that CONTAINS packs/town-deltas).
#
# NO `printf ... | grep -q` ANYWHERE below: under `set -o pipefail` (and this script's inputs are 70 KB) a grep that
# matches and exits early can leave its writer with SIGPIPE, and the pipeline then reports FAILURE although the
# pattern was found — measured 20/09: 44 false negatives in 4000 tries even on a 130-byte input. A prod test that
# fails against a correct deploy is worse than none, so every check greps a FILE.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
REAPER="$ASSETS/scripts/reaper.sh"
SELFTEST="$ASSETS/reaper-orphan-count.selftest.sh"
ORDER="$CITY/packs/town-deltas/orders/mol-dog-reaper.toml"

log()  { echo "[prod-test:gascity ga-hpdpij] $*"; }
fail() { echo "[prod-test:gascity ga-hpdpij] FAIL: $*" >&2; exit 1; }

[[ -f "$REAPER" ]]   || fail "deployed reaper missing: $REAPER"
[[ -f "$SELFTEST" ]] || fail "deployed selftest missing: $SELFTEST"
[[ -f "$ORDER" ]]    || fail "deployed reaper order missing: $ORDER"
log "Deployed reaper found: $REAPER"

CODE_FILE="$(mktemp "${TMPDIR:-/tmp}/story-ga-hpdpij-code.XXXXXX")" || fail "cannot create a temp file"
OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/story-ga-hpdpij-out.XXXXXX")"   || fail "cannot create a temp file"
trap 'rm -f "$CODE_FILE" "$OUT_FILE"' EXIT

# ── 1. Structural: the feature is in the deployed file, as CODE ────────────────────────────────
# CODE = the non-comment lines only, so a comment alone cannot satisfy a check below.
# grep -F throughout: the patterns carry literal `$`, `(` and `"`, which a regex would read as syntax.
grep -v '^[[:space:]]*#' "$REAPER" > "$CODE_FILE"
[[ -s "$CODE_FILE" ]] || fail "the deployed reaper has no code lines at all: $REAPER"
need() {  # need <fixed string> <what its absence would mean>
  grep -F -q -- "$1" "$CODE_FILE" || fail "$2 — missing from the deployed reaper: $1"
}
need 'count_orphan_children() {'                     "the orphan COUNT phase is not defined"
need 'orphan_count:$ORPHAN_COUNT_TEXT'               "the summary does not carry orphan_count"
need 'if [ "$SQL_COUNT_FAILED" -eq 1 ]; then'        "a failed count read is not told apart from a counted zero"
need 'append_summary_log "$SUMMARY"'                 "the summary line is not written to the durable log"
need 'summary_log:FAILED'                            "an unwritable durable log would be silent"
need 'summary_log:UNCAPPED'                          "a durable log that cannot be size-capped would grow silently"
need 'reaper-summary.log'                            "the durable log has no default path"
need 'field_listed() {'                              "the schema probe is not the pipe-free whole-line test (it false-negatives under pipefail)"
# The count must be CALLED (a defined-but-never-called function delivers nothing): a line that is just the name.
grep -x -q 'count_orphan_children' "$CODE_FILE" \
  || fail "count_orphan_children is defined but never called in the deployed reaper — the count would never run"
log "orphan COUNT (defined, called, three-state) + durable summary log present in the deployed reaper (code lines) ✓"

# ── 2. The story's selftest, against the DEPLOYED reaper (it resolves scripts/reaper.sh next to itself). ──
# Require the scenarios that ARE the story by name, so a truncated or stale selftest cannot pass silently.
for tool in dolt jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "'$tool' is required by the selftest and is not installed on this host"
done
bash "$SELFTEST" > "$OUT_FILE" 2>&1; RC=$?
[[ "$RC" -eq 0 ]] || fail "deployed reaper-orphan-count selftest failed (rc=$RC): $(grep -E '^  FAIL|BAIL' "$OUT_FILE" | head -5 | tr '\n' ' ')"
for scen in \
  'C1 orphan_count:1 although the sweep is halted' \
  'C3 every probe failed -> orphan_count:unknown' \
  'C3 a failed read never reads as orphan_count:0' \
  'C5 130 orphan events with alert 3' \
  'C7 zz'"'"'s last purge statement' \
  'C8 the last log line is the run'"'"'s own summary' \
  'C9 rotated into .1 and .2' \
  'C11 zz is skipped by the reaper for its schema yet its 4 orphans are COUNTED' \
  'C12 timeout' \
  'C13 the columns are found in a 140 KB column list' ; do
  grep -F -q -- "ok   - $scen" "$OUT_FILE" \
    || fail "selftest ran without the ga-hpdpij scenario '$scen' — stale or truncated selftest"
done
log "deployed selftest green: $(grep -E 'selftest \(ga-hpdpij\)' "$OUT_FILE" | tail -1) ✓"

log "PASS"
exit 0
