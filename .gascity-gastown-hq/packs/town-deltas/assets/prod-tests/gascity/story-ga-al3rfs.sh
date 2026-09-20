#!/usr/bin/env bash
# prod-tests/gascity/story-ga-al3rfs.sh — prod test for ga-al3rfs: the adhoc-session
# reaper must never hand an id-less session row to `gc session close`, and its census
# must keep every column in its own slot when an optional field is absent.
#
# Background: the census is TAB-joined and read back with `IFS=$'\t' read`. TAB is
# IFS-whitespace, so bash COLLAPSES an empty column and shifts every later field one slot
# left, silently. The audit that went with this story (64 tab-IFS readers, 26 files) found
# this reaper the only reader where a shift was actually reachable. ga-jn82py (merged first) already closed the shift
# itself: parse_census gives every column before the title a non-empty "-" placeholder.
# What was still open, reproduced against that code: a session row with NO id became the
# placeholder "-" and was REAPED via `gc session close -`. The `malformed_row_no_id`
# guard rejects it before any decision can reach the close.
#
# The other 59 readers are non-exploitable today (their fields before the last are never
# empty by construction). That is recorded on ga-al3rfs, not enforced here.
#
# Called by run.sh after deploy (STORY_ID=ga-al3rfs). Exits 0 on pass. Hermetic: it only
# READS the deployed scripts and runs the reaper's selftest, which stubs `gc` and `tmux`
# — no live session is listed, peeked or closed. CITY overrides the city dir (scratch runs).

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
REAPER="$CITY/scripts/adhoc-session-reaper.sh"
SELFTEST="$CITY/scripts/adhoc-session-reaper.selftest.sh"

log()  { echo "[prod-test:gascity ga-al3rfs] $*"; }
fail() { echo "[prod-test:gascity ga-al3rfs] FAIL: $*" >&2; exit 1; }

[[ -f "$REAPER" ]]   || fail "deployed reaper missing: $REAPER"
[[ -f "$SELFTEST" ]] || fail "deployed reaper selftest missing: $SELFTEST"
log "Deployed reaper found: $REAPER"

# ── 1. Structural: the guard is actually in the deployed file ──────────────────
# CODE = the non-comment lines only, so a comment alone cannot satisfy the checks below.
# grep -F throughout: the patterns carry a literal `$`, which a regex would read as an anchor.
CODE="$(grep -v '^[[:space:]]*#' "$REAPER")"
printf '%s\n' "$CODE" | grep -F 'malformed_row_no_id' >/dev/null \
  || fail "malformed_row_no_id guard missing from the deployed reaper — an id-less row can reach gc session close"
printf '%s\n' "$CODE" | grep -F '[ "$id" = "-" ]' >/dev/null \
  || fail "the guard does not reject the census placeholder id (\"-\") — an id-less row still reads as a real id"
log "malformed_row_no_id guard (rejects blank AND placeholder id) present in the deployed reaper (code lines) ✓"

# ── 2. Behavioral, against the DEPLOYED parse_census (sourced in a subshell so the
#    reaper's set -u / variables never leak into this test). SOURCE_ONLY returns before
#    any sweep runs, and the reaper's own guard makes a real `gc` call impossible here. ──
RESULT="$(
  ADHOC_REAPER_SOURCE_ONLY=1 ADHOC_REAPER_ENABLED=0 ADHOC_REAPER_GC=/usr/bin/true \
    bash -c '
      # shellcheck disable=SC1090
      source "$1" >/dev/null 2>&1
      command -v parse_census >/dev/null 2>&1 || { echo "NO_PARSE_CENSUS"; exit 0; }
      # a session with ONLY a name: every optional column absent
      row="$(printf "%s" "{\"sessions\":[{\"name\":\"y\"}]}" | parse_census)"
      IFS=$'"'"'\t'"'"' read -r c_id c_name c_state c_closed c_created c_last c_att c_alias c_sess c_title <<< "$row"
      echo "ALIGN=$c_id|$c_name|$c_state|$c_closed|$c_created|$c_last|$c_att|$c_alias|$c_sess|$c_title"
      # a title carrying a newline must not split the row
      row2="$(printf "%s" "{\"sessions\":[{\"id\":\"x\",\"name\":\"y\",\"title\":\"a\\nb\"}]}" | parse_census)"
      echo "ROWS=$(printf "%s\n" "$row2" | awk "END{print NR}")"
    ' _ "$REAPER" 2>/dev/null
)"

echo "$RESULT" | grep -F 'NO_PARSE_CENSUS' >/dev/null \
  && fail "deployed reaper does not define parse_census when sourced"
echo "$RESULT" | grep -F 'ALIGN=-|y|-|-|-|-|unknown|-|-|' >/dev/null \
  || fail "deployed parse_census misaligned or left a column empty for a name-only session — got: $(echo "$RESULT" | grep -F 'ALIGN=' | head -1)"
echo "$RESULT" | grep -F 'ROWS=1' >/dev/null \
  || fail "a newline inside a title split the deployed census into more than one row — got: $(echo "$RESULT" | grep -F 'ROWS=' | head -1)"
log "deployed parse_census keeps absent fields aligned ('-' placeholders) and one row per session ✓"

# ── 3. The reaper's own hermetic selftest, run against the deployed pair. Require the
#    ga-al3rfs scenarios by name so a truncated or stale selftest cannot pass silently. ──
OUT="$(bash "$SELFTEST" 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]] || fail "deployed adhoc-session-reaper selftest failed (rc=$RC): $(echo "$OUT" | grep -E '^(FAIL|selftest:)' | head -5 | tr '\n' ' ')"
for scen in '(n1) ' '(n2) ' '(n) ' '(o) ' '(p) '; do
  echo "$OUT" | grep -F "ok   - $scen" >/dev/null \
    || fail "selftest ran without ga-al3rfs scenario ${scen}— stale or truncated selftest"
done
log "deployed selftest green: $(echo "$OUT" | grep -E '^selftest:' | tail -1) ✓"

log "PASS"
exit 0
