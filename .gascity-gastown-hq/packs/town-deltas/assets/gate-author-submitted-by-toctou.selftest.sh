#!/usr/bin/env bash
# gate-author-submitted-by-toctou.selftest.sh (ga-tkvsa, fixes ga-w5agg)
#
# Proves the guard/dispatcher author-derivation TOCTOU race is closed.
#
# ROOT BUG (ga-w5agg): author derivation for a gate marker's source bead
# happened TWICE against the same bead's mutable `assignee` field — once in
# quality-gate-guard.sh (Step 5, at submit time) and again, redundantly, in
# quality-gate-dispatcher.sh (Step 3, at dispatch time, seconds-to-minutes
# later). Between the two, the guard's OWN Step 5 dog-pool detach (ga-e7zk7)
# clears the bead's assignee in the SAME run that resolved it, and
# created_by/owner are never populated on programmatically-created sling
# beads either. So the dispatcher's re-check failed EVERY time for a normal
# dog-submitted fix/* marker (submit, close, exit — dog doctrine, not an edge
# case), hit the author-unresolvable fail-safe, and dead-ended at
# gate-status:deferred — a state nothing ever re-reads.
#
# FIX: the guard persists its already-successful resolution onto the marker
# itself as gate.submitted_by metadata (--set-metadata: overwrite semantics,
# not label-add's append semantics — a worker cannot forge this by pre-seeding
# a label at marker-creation time, since the guard's write at parking time is
# always the final value for that key). The dispatcher reads it back FIRST,
# before falling through to the legacy bead re-derivation (kept as-is for
# markers created before this fix ships).
#
# Strategy: pull the live snippets VERBATIM from both scripts (grep by line
# content, not line number — line numbers drift) and exercise them under the
# SAME `set -euo pipefail` the scripts use, against realistic JSON shapes.
# Drift-guard the shipped source so a future edit can't silently reopen the
# race.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SRC="$SELF_DIR/quality-gate-guard.sh"
DISPATCHER_SRC="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-author-submitted-by-toctou.selftest =="

# ── A. dispatcher metadata-read snippet (pulled verbatim) ───────────────────
echo "A. dispatcher: gate.submitted_by extraction from \$VERIFY_JSON"

READ_LINE="$(grep -F 'AUTHOR=$(printf' "$DISPATCHER_SRC" | grep -F 'gate.submitted_by' | head -1)"
if [ -z "$READ_LINE" ]; then
  bad "could not locate the gate.submitted_by extraction line in dispatcher"
else
  ok "located live extraction line"
fi

run_extract() {
  # $1 = VERIFY_JSON. Echoes the resolved AUTHOR (may be empty).
  bash -c '
    set -euo pipefail
    VERIFY_JSON="$1"
    '"$READ_LINE"'
    printf "%s" "$AUTHOR"
  ' _ "$1" 2>/dev/null
}

R=$(run_extract '{"metadata":{"gate.submitted_by":"dog-abc123"}}')
[ "$R" = "dog-abc123" ] && ok "resolves recorded author from metadata" \
  || bad "expected 'dog-abc123', got '$R'"

R=$(run_extract '[{"metadata":{"gate.submitted_by":"dog-abc123"}}]')
[ "$R" = "dog-abc123" ] && ok "resolves author when show returns an array (bd show shape)" \
  || bad "array-wrapped shape: expected 'dog-abc123', got '$R'"

R=$(run_extract '{"metadata":{}}')
[ -z "$R" ] && ok "empty metadata object yields empty AUTHOR (no crash)" \
  || bad "expected empty, got '$R'"

R=$(run_extract '[]')
[ -z "$R" ] && ok "fetch-failure shape ([]) yields empty AUTHOR (no crash under set -e)" \
  || bad "expected empty for [], got '$R'"

# The extraction line's own `// empty` collapses a JSON null to "" directly;
# the dispatcher's follow-up shell guard additionally treats a literal "null"
# string as empty as a second line of defense. Assert the extraction alone
# already yields empty:
R=$(run_extract '{"metadata":{"gate.submitted_by":null}}')
[ -z "$R" ] && ok "JSON null metadata value yields empty AUTHOR" \
  || bad "JSON null: expected empty, got '$R'"

# ── B. full guard clause: metadata hit skips bead re-derivation entirely ────
echo "B. dispatcher: metadata hit SKIPS the bead-lookup fallback"

# Pull the two lines: the `AUTHOR=""` reset immediately followed by the
# extraction+guard block, up through the `else / AUTHOR="" / fi` that follows
# the log line — verbatim, via anchors that won't drift with line numbers.
BLOCK="$(awk '
  /^AUTHOR=""$/ { grab=1 }
  grab { print }
  grab && /^fi$/ { c++; if (c==1) exit }
' "$DISPATCHER_SRC")"

if ! printf '%s\n' "$BLOCK" | grep -q 'gate.submitted_by'; then
  bad "could not isolate the metadata-check block (awk anchor drift?) — skipping B"
else
  ok "isolated metadata-check block"

  BD_CALLED=0
  RESULT="$(
    bash -c '
      set -euo pipefail
      log() { :; }
      bd_lookup_marker() { echo "$1"; }  # unused stub, keeps namespace tidy
      gc() { echo "CALLED" >> "$2"; echo "{}"; }   # would-be cross-rig lookup
      bd() { echo "CALLED" >> "$2"; echo "{}"; }   # would-be HQ lookup
      CALLFLAG="$1"; shift
      VERIFY_JSON="$1"; BEAD_ID="wa-somebead"
      '"$BLOCK"'
      echo "AUTHOR=${AUTHOR}"
    ' _ "/tmp/gate-toctou-callflag-$$" '{"metadata":{"gate.submitted_by":"trusted-dog"}}' 2>/dev/null
  )"
  case "$RESULT" in
    "AUTHOR=trusted-dog") ok "trusted metadata value wins, bead lookup never reached (\$BEAD_ID was non-empty)" ;;
    *) bad "expected AUTHOR=trusted-dog, got '$RESULT'" ;;
  esac
  rm -f "/tmp/gate-toctou-callflag-$$"
fi

# ── C. backward compat: legacy marker (no metadata) still falls through ─────
echo "C. dispatcher: legacy marker without gate.submitted_by still re-derives from the bead"

# ga-07509: the BEAD_RAW line below now goes through gc_json_or_unknown (the
# same migration quality-gate-guard.sh/-dispatcher.sh got), so this sandbox
# needs its own copy to run against — double-quoted jq filters throughout
# purely to avoid nested-single-quote escaping inside this already-quoted
# bash -c string; behaviorally identical to the production copies (drift-
# guarded separately, byte-for-byte, by gc-json-or-unknown.selftest.sh).
GC_JSON_OR_UNKNOWN_SANDBOX_SRC='
      gc_json_or_unknown() {
        local _gjou_out _gjou_rc
        if _gjou_out=$("$@" 2>/dev/null); then
          _gjou_rc=0
        else
          _gjou_rc=$?
        fi
        [ "$_gjou_rc" -eq 0 ] || return 1
        [ -n "$_gjou_out" ] || return 1
        if ! printf "%s" "$_gjou_out" | jq -e . >/dev/null 2>&1; then return 1; fi
        if printf "%s" "$_gjou_out" | jq -e "has(\"ok\") and (.ok == false)" >/dev/null 2>&1; then return 1; fi
        printf "%s" "$_gjou_out"
        return 0
      }
'

if [ -n "${BLOCK:-}" ]; then
  RESULT="$(
    bash -c '
      set -euo pipefail
      log() { :; }
      bead_field_grep() {
        local raw="$1" field="$2"
        echo "$raw" | grep -o "\"${field}\": *\"[^\"]*\"" \
          | sed "s/\"${field}\": *\"\(.*\)\"/\1/" \
          | head -1 || true
      }
      '"$GC_JSON_OR_UNKNOWN_SANDBOX_SRC"'
      gc() { echo "{\"assignee\":\"legacy-author\"}"; }
      bd() { echo "{\"assignee\":\"legacy-author\"}"; }
      VERIFY_JSON="{\"metadata\":{}}"; BEAD_ID="wa-legacy"
      '"$BLOCK"'
      if [ -z "$AUTHOR" ] && [ -n "$BEAD_ID" ]; then
        BEAD_RAW=$(gc_json_or_unknown gc --city x bd show "$BEAD_ID" --json) || true
        AUTHOR=$(bead_field_grep "$BEAD_RAW" "assignee")
      fi
      echo "AUTHOR=${AUTHOR}"
    ' _ 2>/dev/null
  )"
  case "$RESULT" in
    "AUTHOR=legacy-author") ok "no metadata → falls through to bead assignee (legacy markers unaffected)" ;;
    *) bad "expected AUTHOR=legacy-author, got '$RESULT'" ;;
  esac

  # ga-07509: previously untested here — a FAILING gc bd show (nonzero exit,
  # bare {"error":...} envelope, no "ok" key) must NOT be misread as "bead
  # has no assignee". AUTHOR must stay unresolved (empty), never silently
  # resolve to something derived from the failure envelope itself.
  RESULT_FAIL="$(
    bash -c '
      set -euo pipefail
      log() { :; }
      bead_field_grep() {
        local raw="$1" field="$2"
        echo "$raw" | grep -o "\"${field}\": *\"[^\"]*\"" \
          | sed "s/\"${field}\": *\"\(.*\)\"/\1/" \
          | head -1 || true
      }
      '"$GC_JSON_OR_UNKNOWN_SANDBOX_SRC"'
      gc() { echo "{\"error\":\"no issues found matching the provided IDs\",\"schema_version\":1}"; return 1; }
      bd() { echo "{\"error\":\"no issues found matching the provided IDs\",\"schema_version\":1}"; return 1; }
      VERIFY_JSON="{\"metadata\":{}}"; BEAD_ID="wa-legacy"
      '"$BLOCK"'
      if [ -z "$AUTHOR" ] && [ -n "$BEAD_ID" ]; then
        BEAD_RAW=$(gc_json_or_unknown gc --city x bd show "$BEAD_ID" --json) || true
        AUTHOR=$(bead_field_grep "$BEAD_RAW" "assignee")
      fi
      echo "AUTHOR=${AUTHOR}"
    ' _ 2>/dev/null
  )"
  case "$RESULT_FAIL" in
    "AUTHOR=") ok "ga-07509: a FAILING gc bd show leaves AUTHOR unresolved (empty), not misread as a resolved-but-blank assignee" ;;
    *) bad "ga-07509 REGRESSION: a failing gc call resolved to '$RESULT_FAIL' instead of staying unresolved" ;;
  esac
else
  bad "block not isolated (see section B) — skipping C"
fi

# ── D. guard: --set-metadata call shape (Step 7, argument capture) ──────────
echo "D. guard: Step 7 records gate.submitted_by via --set-metadata (overwrite, not label-add)"

SET_LINE="$(grep -F -- '--set-metadata "gate.submitted_by=$AUTHOR"' "$GUARD_SRC" | head -1)"
if [ -z "$SET_LINE" ]; then
  bad "could not locate the --set-metadata write line in guard"
else
  ok "located live --set-metadata write line"
  CAPTURED=""
  bd() {
    local store="" verb="" rest=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -C) store="$2"; shift 2 ;;
        update) verb="update"; shift ;;
        *) rest+=("$1"); shift ;;
      esac
    done
    [ "$verb" = "update" ] && CAPTURED="store=$store id=${rest[0]:-} args=${rest[*]:-}"
    return 0
  }
  GC_CITY="/fake/hq"; MARKER_ID="ga-wisp-fake1"; AUTHOR="resolved-author-xyz"
  eval "$SET_LINE"
  case "$CAPTURED" in
    "store=/fake/hq id=ga-wisp-fake1 args=ga-wisp-fake1 --set-metadata gate.submitted_by=resolved-author-xyz -q")
      ok "set-metadata call targets \$GC_CITY, \$MARKER_ID, and the resolved \$AUTHOR" ;;
    *)
      bad "unexpected captured call: '$CAPTURED'" ;;
  esac
fi

# ── E. drift guards on the live shipped source ───────────────────────────────
echo "E. Drift-guards (live source still carries the fix):"

grep -q 'metadata\["gate.submitted_by"\]' "$DISPATCHER_SRC" \
  && ok "dispatcher: reads gate.submitted_by from the marker" \
  || bad "dispatcher: gate.submitted_by read MISSING — TOCTOU race reopened?"

grep -qE 'if \[ -z "\$AUTHOR" \] && \[ -n "\$BEAD_ID" \]; then' "$DISPATCHER_SRC" \
  && ok "dispatcher: legacy bead re-derivation is gated on AUTHOR still being empty" \
  || bad "dispatcher: bead re-derivation no longer gated — would clobber a trusted metadata value"

grep -qF -- '--set-metadata "gate.submitted_by=$AUTHOR"' "$GUARD_SRC" \
  && ok "guard: Step 7 still writes gate.submitted_by via --set-metadata" \
  || bad "guard: gate.submitted_by write MISSING — dispatcher would have nothing to read"

# The write must happen in Step 7 (after gate-status:queued is parked), i.e.
# AFTER the guard's own authoritative Step 5 derivation — not before AUTHOR
# is guaranteed resolved.
if awk '/^bd -C "\$GC_CITY" label add    "\$MARKER_ID" "gate-status:queued"/{f=1} f && /set-metadata "gate.submitted_by=\$AUTHOR"/{print; found=1} END{exit !found}' "$GUARD_SRC" >/dev/null; then
  ok "guard: gate.submitted_by write is positioned at/after the queued-parking step"
else
  bad "guard: gate.submitted_by write is not after gate-status:queued parking — ordering drifted"
fi

echo ""
echo "== gate-author-submitted-by-toctou: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
