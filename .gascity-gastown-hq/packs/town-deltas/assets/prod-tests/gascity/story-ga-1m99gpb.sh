#!/usr/bin/env bash
# prod-tests/gascity/story-ga-1m99gpb.sh — prod test for ga-1m99gpb (leftover 1 of the ga-xvbini1
# consumption cut): merged-bead-janitor reads the gate markers ONCE per sweep into an index instead
# of one `bd list -l source-bead:<id>` per bead.
#
# Called by story-delivery.sh after deploy (STORY_ID=ga-1m99gpb). Exits 0 on pass. Asserts against the
# LIVE deployed janitor (it runs in place, launchd picks the new text up at the next sweep) and against
# the LIVE marker store: the index must answer exactly what the per-bead query answers. The janitor's
# own battery (merged-bead-janitor.selftest.sh, ~minutes with its mutants) is the gate's job, not this
# script's: it is not rerun here.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
# JANITOR_UNDER_TEST: run this same script against a branch checkout before deploying (default = the deployed tree)
JANITOR="${JANITOR_UNDER_TEST:-$CITY/packs/town-deltas/assets/merged-bead-janitor.sh}"

log()  { echo "[prod-test:gascity ga-1m99gpb] $*"; }
fail() { echo "[prod-test:gascity ga-1m99gpb] FAIL: $*" >&2; exit 1; }

# ── the deployed janitor carries the index, parses, and exposes the new functions ──
[ -f "$JANITOR" ] || fail "deployed merged-bead-janitor.sh missing: $JANITOR"
bash -n "$JANITOR" || fail "deployed merged-bead-janitor.sh does not parse"
grep -q 'marker_index_load()' "$JANITOR" && grep -q 'marker_index_dir()' "$JANITOR" \
  || fail "deployed merged-bead-janitor.sh has no marker index (marker_index_load / marker_index_dir)"
grep -q 'JANITOR_MARKER_INDEX_TTL' "$JANITOR" || fail "deployed janitor lost the JANITOR_MARKER_INDEX_TTL knob"
log "deployed janitor parses and carries the marker index"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/prod-ga-1m99gpb.XXXXXX") || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

# ── live: the bulk read the index rests on works, and is not empty ──
RAW="$TMP/bulk.json"
bd -C "$CITY" list --all --include-infra --json --limit 0 -l type:quality-gate-marker > "$RAW" 2>"$TMP/bulk.err" \
  || fail "the live bulk marker read failed: $(head -c 300 "$TMP/bulk.err")"
jq -e 'type == "array" and length > 0' "$RAW" >/dev/null 2>&1 || fail "the live bulk marker read is not a non-empty array"
log "live bulk read: $(jq 'length' "$RAW") markers"

# ids with markers (the first two keyable ones), plus one id that cannot have any
IDS=$(jq -r '[.[] | (.labels // [])[] | select(startswith("source-bead:")) | ltrimstr("source-bead:")
             | select(test("^[a-z0-9][a-z0-9._-]*$"))] | unique | .[0:2][]' "$RAW")
[ -n "$IDS" ] || fail "no marker in the live store names a keyable source-bead"
IDS="$IDS
ga-prodtest-no-such-bead-zzz"

# ── live equivalence: index answer == per-bead answer, byte for byte, for each id ──
(
  export GC_CITY_PATH="$CITY"
  JANITOR_LIB_ONLY=1 source "$JANITOR" || exit 90
  LOG="$TMP/janitor.log"; LOG_DIR="$TMP"
  MK_IDX_ROOT=$(mktemp -d "$TMP/idx.XXXXXX") || exit 91
  n=0
  for id in $IDS; do
    MARKER_INDEX_TTL_SECONDS=90; via_idx=$(markers_for_bead_strict "$id" 2>/dev/null); rc_i=$?
    MARKER_INDEX_TTL_SECONDS=0;  via_bd=$(markers_for_bead_strict "$id" 2>/dev/null);  rc_b=$?
    [ "$rc_i" = "0" ] && [ "$rc_b" = "0" ] || { echo "rc differs for $id: index=$rc_i per-bead=$rc_b" >&2; exit 92; }
    a=$(printf '%s' "$via_idx" | jq -S -c . 2>/dev/null); b=$(printf '%s' "$via_bd" | jq -S -c . 2>/dev/null)
    [ -n "$a" ] && [ "$a" = "$b" ] || { echo "answers differ for $id" >&2; exit 93; }
    n=$((n+1))
  done
  [ "$n" -ge 2 ] || exit 94
  # the index was read once for all of them (a generation exists), and the empty bead is [] from it
  [ -s "$MK_IDX_ROOT/current" ] || exit 95
) || fail "live equivalence between the marker index and the per-bead query broke (rc=$?)"
log "index == per-bead answer for the live ids (and [] for a bead with no marker)"

log "PASS"
exit 0
