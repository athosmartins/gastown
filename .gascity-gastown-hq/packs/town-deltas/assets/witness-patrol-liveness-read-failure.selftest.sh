#!/usr/bin/env bash
# witness-patrol-liveness-read-failure.selftest.sh — behavioral drift-guard for ga-17f7ap.
#
# Bug ga-17f7ap: recover-orphaned-beads builds its liveness map from two
# `gc`-command reads (live session list, session-beads overlay) without
# checking either read's exit code or output size. A failed session-beads
# read (evidence: 2026-09-14, rc=1, 0 bytes, ~40s each) leaves an empty
# file, which `jq --slurpfile` slurps as `[]` with no error — the overlay
# silently contributes nothing and the step proceeds as if the roster had
# been read successfully. The pre-existing fail-safe only fires when the
# FINAL map is 100% empty; the live session list alone keeps it non-empty,
# so this failure mode never trips it and never surfaces anywhere but the
# runner's own terminal.
#
# Unlike the sibling ga-3v2n4 drift-guard (witness-patrol-wisp-store.
# selftest.sh, a structural grep — appropriate for prose-vs-code that
# can't be cleanly isolated), this defect is entirely inside ONE
# self-contained bash block with no interleaved prose, so this test
# extracts that ACTUAL block from mol-witness-patrol.toml and executes it
# under a stubbed `gc` PATH — a genuine behavioral simulation of each
# failure shape, not a text pattern match.
#
# Verified both directions: 5/16 assertions pass against the original
# pre-fix formula content (HEAD before this fix — the extraction still
# isolates the old first fenced block, which never had the rc/size checks,
# so most assertions correctly fail), 11/11 pass against this fix.
#
# Exit 0 iff all scenarios hold.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOWN_DELTAS_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FORMULA="$TOWN_DELTAS_ROOT/formulas/mol-witness-patrol.toml"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$FORMULA" ]; then
  echo "FATAL: formula override not found at $FORMULA" >&2
  exit 2
fi

echo "witness-patrol-liveness-read-failure.selftest — ga-17f7ap rc/size read-failure guards"

# ── Extract the actual liveness-map bash block ────────────────────────────
# Anchored on the literal first content line (unique in the file) through
# the closing ``` fence, so this only ever executes the real bash the
# witness runs — never the surrounding markdown prose.
LIVENESS_CODE="$(awk '
  /^   SESSIONS_FILE=\$\(mktemp\); SESSION_BEADS_FILE=\$\(mktemp\)$/ { flag=1 }
  flag && /^   ```$/ { exit }
  flag { print }
' "$FORMULA" | sed 's/^   //')"

if [ -z "$LIVENESS_CODE" ]; then
  echo "FATAL: could not isolate the liveness-map bash block (anchors not found — did the step change shape?)" >&2
  exit 2
fi

# Sanity: the extracted block must actually contain the rc/size checks
# this bug asks for — if a future edit drops them without changing the
# anchors above, fail loudly instead of silently exercising stale code.
for marker in 'SESSIONS_RC=$?' 'SESSION_BEADS_RC=$?' 'OVERLAY UNKNOWN' '! -s "$SESSIONS_FILE"' '! -s "$SESSION_BEADS_FILE"'; do
  if ! printf '%s\n' "$LIVENESS_CODE" | grep -qF "$marker"; then
    bad "extracted block missing expected marker: $marker"
  fi
done

# ── Stub `gc`: controlled via env vars, isolates the extracted code from
#    any real session/bead state ─────────────────────────────────────────
STUBDIR="$(mktemp -d)"
trap 'rm -rf "$STUBDIR"' EXIT

cat > "$STUBDIR/gc" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "session list")
    [ -n "${STUB_SESSIONS_BODY:-}" ] && printf '%s' "$STUB_SESSIONS_BODY"
    exit "${STUB_SESSIONS_RC:-0}"
    ;;
  "bd list")
    [ -n "${STUB_BEADS_BODY:-}" ] && printf '%s' "$STUB_BEADS_BODY"
    exit "${STUB_BEADS_RC:-0}"
    ;;
  "mail send")
    echo "MAIL: $*" >> "${MAIL_LOG:-/dev/null}"
    exit 0
    ;;
  *)
    echo "unstubbed gc invocation: $*" >&2
    exit 99
    ;;
esac
STUB
chmod +x "$STUBDIR/gc"

TWO_LIVE_SESSIONS='{"sessions":[{"id":"s1","name":"gastown.dog-1","state":"active","closed":false},{"id":"s2","name":"gastown.dog-2","state":"active","closed":false}]}'
ONE_OVERLAY_ROW='[{"metadata":{"configured_named_identity":"lexbh/gastown.witness","state":"active"},"status":"open"}]'

# run_scenario NAME SESSIONS_RC SESSIONS_BODY BEADS_RC BEADS_BODY
# Prints the extracted code's combined stdout+stderr, one line per output
# line, prefixed nothing — callers grep the captured text.
run_scenario() {
  local sessions_rc="$1" sessions_body="$2" beads_rc="$3" beads_body="$4"
  local mail_log; mail_log="$(mktemp)"
  local out rc
  out="$(
    STUB_SESSIONS_RC="$sessions_rc" STUB_SESSIONS_BODY="$sessions_body" \
    STUB_BEADS_RC="$beads_rc" STUB_BEADS_BODY="$beads_body" \
    MAIL_LOG="$mail_log" \
    PATH="$STUBDIR:$PATH" \
    bash -c "$LIVENESS_CODE"$'\n''echo "RESULT MAP_COUNT=$MAP_COUNT SESSION_COUNT=$SESSION_COUNT"' 2>&1
  )"
  rc=$?
  SCENARIO_OUT="$out"
  SCENARIO_RC="$rc"
  SCENARIO_MAILED="no"
  [ -s "$mail_log" ] && SCENARIO_MAILED="yes"
  rm -f "$mail_log"
}

# ── Scenario 1: baseline healthy — both reads succeed ─────────────────────
echo ""
echo "Scenario 1: both reads healthy"
run_scenario 0 "$TWO_LIVE_SESSIONS" 0 "$ONE_OVERLAY_ROW"
if [ "$SCENARIO_RC" -eq 0 ]; then ok "extracted block exits 0"; else bad "extracted block exited $SCENARIO_RC: $SCENARIO_OUT"; fi
if ! printf '%s' "$SCENARIO_OUT" | grep -q "FAIL-SAFE\|OVERLAY UNKNOWN"; then
  ok "no fail-safe / overlay-unknown noise on the healthy path"
else
  bad "unexpected fail-safe/overlay-unknown output on healthy path: $SCENARIO_OUT"
fi
if printf '%s' "$SCENARIO_OUT" | grep -q "RESULT MAP_COUNT=[1-9]"; then
  ok "map is non-empty on the healthy path"
else
  bad "map came back empty on the healthy path: $SCENARIO_OUT"
fi

# ── Scenario 2: THE BUG — session-beads read fails, rc=1, 0 bytes ─────────
# This is the exact shape from the bug's own evidence (14/09, three
# failures ~40s each, rc=1, 0 bytes). Pre-fix, this scenario produces a
# non-empty map (from the live session list) with ZERO indication the
# overlay read ever failed — the defect this bug exists to close.
echo ""
echo "Scenario 2 (THE BUG): session-beads read fails rc=1, 0 bytes"
run_scenario 0 "$TWO_LIVE_SESSIONS" 1 ""
if printf '%s' "$SCENARIO_OUT" | grep -q "OVERLAY UNKNOWN"; then
  ok "declares OVERLAY UNKNOWN instead of silently proceeding"
else
  bad "REGRESSION (this is the bug): overlay read failure went undeclared. Output: $SCENARIO_OUT"
fi
if ! printf '%s' "$SCENARIO_OUT" | grep -q "FAIL-SAFE: empty liveness map"; then
  ok "does NOT spuriously trip the empty-map fail-safe (live list alone is non-empty)"
else
  bad "wrongly tripped the empty-map fail-safe when only the overlay failed"
fi
if printf '%s' "$SCENARIO_OUT" | grep -q "RESULT MAP_COUNT=[1-9] SESSION_COUNT=2"; then
  ok "still resolves assignees from the live session list (map non-empty, 2 sessions counted)"
else
  bad "live-session-derived map was lost: $SCENARIO_OUT"
fi

# ── Scenario 3: live session list itself fails, rc=1, 0 bytes ─────────────
echo ""
echo "Scenario 3: gc session list itself fails rc=1, 0 bytes"
run_scenario 1 "" 0 "$ONE_OVERLAY_ROW"
if printf '%s' "$SCENARIO_OUT" | grep -q "FAIL-SAFE: gc session list read failed"; then
  ok "aborts recovery this cycle on a broken live-session-list read"
else
  bad "REGRESSION: broken session-list read was not caught. Output: $SCENARIO_OUT"
fi
if [ "$SCENARIO_MAILED" = "yes" ]; then
  ok "escalates to mayor on a broken live-session-list read"
else
  bad "no mayor escalation on a broken live-session-list read"
fi

# ── Scenario 4: live session list returns partial/invalid JSON (rc=0) ─────
# Covers acceptance criterion (c): rc alone isn't the only failure shape —
# a command that "succeeds" but emits garbage must be caught too.
echo ""
echo "Scenario 4: gc session list returns invalid JSON with rc=0"
run_scenario 0 "not valid json {{{" 0 "$ONE_OVERLAY_ROW"
if printf '%s' "$SCENARIO_OUT" | grep -q "FAIL-SAFE: gc session list read failed"; then
  ok "aborts recovery this cycle on invalid JSON even when rc=0"
else
  bad "REGRESSION: invalid-JSON session-list output was not caught. Output: $SCENARIO_OUT"
fi

# ── Scenario 5: pre-existing fail-safe still works (schema drift) ─────────
# Both reads succeed (rc=0, non-empty, valid JSON) but the session objects
# carry none of the recognized key fields, so the map-builder legitimately
# produces an empty map despite SESSION_COUNT>0 — the original gc-3tn8g
# schema-drift case this fail-safe was built for.
echo ""
echo "Scenario 5: pre-existing empty-map fail-safe (schema drift) still fires"
run_scenario 0 '{"sessions":[{"unexpected_field":"x"},{"unexpected_field":"y"}]}' 0 "[]"
if printf '%s' "$SCENARIO_OUT" | grep -q "FAIL-SAFE: empty liveness map"; then
  ok "schema-drift fail-safe still fires unchanged"
else
  bad "REGRESSION: schema-drift fail-safe no longer fires. Output: $SCENARIO_OUT"
fi
if [ "$SCENARIO_MAILED" = "yes" ]; then
  ok "schema-drift fail-safe still escalates to mayor"
else
  bad "schema-drift fail-safe no longer escalates to mayor"
fi

# ── Verdict ─────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
