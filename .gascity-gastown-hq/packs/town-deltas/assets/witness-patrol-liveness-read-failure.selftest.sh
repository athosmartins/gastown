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
# ga-zo1bzza (store topology): the same block also READS the session beads, which live in the city
# store only. That read carried no -C, so a witness whose cwd resolves to its rig store read the wrong
# one and the overlay never contributed (and nothing said why). The stub now answers `gc bd` by the
# store a call would reach (no -C, or a -C that is not the city: the real "invalid issue type" error)
# and logs every call (the spy). Scenarios 1, 2 and 6-8 pin the read to the city path, require that an
# empty or unset GC_CITY_PATH makes NO call, require the read's own error line in OVERLAY UNKNOWN, and
# EXECUTE the read commands the formula documents and the witness prompt prescribes (a wisp poured from the
# NATIVE text, which a rig can still have, has only the prompt line as its guard) instead of comparing their text.
# Verified both directions: against the pre-fix formula and prompt this file passes 20 and fails 10 (each
# failure one of the symptoms above); against the fix it passes 30/30, also under a real bash 3.2.57
# (harness and extracted block).
#
# Exit 0 iff all scenarios hold.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOWN_DELTAS_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FORMULA="$TOWN_DELTAS_ROOT/formulas/mol-witness-patrol.toml"
TEMPLATE="$TOWN_DELTAS_ROOT/template-fragments/town-deltas.template.md"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$FORMULA" ]; then
  echo "FATAL: formula override not found at $FORMULA" >&2
  exit 2
fi
if [ ! -f "$TEMPLATE" ]; then
  echo "FATAL: template fragment not found at $TEMPLATE" >&2
  exit 2
fi

echo "witness-patrol-liveness-read-failure.selftest — ga-17f7ap rc/size read-failure guards + ga-zo1bzza city-store pin"

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
  if ! printf '%s\n' "$LIVENESS_CODE" | grep -F "$marker" >/dev/null; then
    bad "extracted block missing expected marker: $marker"
  fi
done

# ── Stub `gc`: controlled via env vars, isolates the extracted code from
#    any real session/bead state ─────────────────────────────────────────
STUBDIR="$(mktemp -d)"
trap 'rm -rf "$STUBDIR"' EXIT
mkdir -p "$STUBDIR/bin"

cat > "$STUBDIR/bin/gc" <<'STUB'
#!/usr/bin/env bash
# gc bd [-C <dir>] list ...: every call is logged to BD_LOG (the spy) and answered by the STORE it would
# reach. Session beads exist ONLY in the city store (STUB_CITY_PATH). A call with no -C, or pinned to any
# other directory (the rig root, empty), is answered the way the property_scrapers witness's cwd store
# answered it: this exact error, measured on 2026-11-11 (ga-zo1bzza). Witnesses whose cwd resolves to the
# HQ store would read the city by accident; the stub deliberately models only the case that failed.
if [ "${1:-}" = "bd" ]; then
  printf 'GCBD %s\n' "$*" >> "${BD_LOG:-/dev/null}"
  shift
  pin=""
  if [ "${1:-}" = "-C" ]; then pin="${2:-}"; shift 2; fi
  [ "${1:-}" = "list" ] || { echo "unstubbed gc bd subcommand: $*" >&2; exit 99; }
  if [ -n "$pin" ] && [ "$pin" = "${STUB_CITY_PATH:-}" ]; then
    [ -n "${STUB_BEADS_BODY:-}" ] && printf '%s' "$STUB_BEADS_BODY"
    [ "${STUB_BEADS_RC:-0}" -ne 0 ] && echo "STUB-ERR-city: simulated city-store read failure" >&2
    exit "${STUB_BEADS_RC:-0}"
  fi
  echo 'Error: invalid issue type "session" (valid: bug, feature, task, epic, chore, decision, agent, convoy, event, gate, merge-request, message, molecule, queue, rig, role, slot)' >&2
  exit 1
fi
case "$1 $2" in
  "session list")
    [ -n "${STUB_SESSIONS_BODY:-}" ] && printf '%s' "$STUB_SESSIONS_BODY"
    exit "${STUB_SESSIONS_RC:-0}"
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
chmod +x "$STUBDIR/bin/gc"
# ga-ck3sz7: the extracted patrol code runs on a PATH with NO real gc (selftest-sandbox-path.lib.sh). It calls
# `gc mail send` (the Mayor's inbox) on a read failure; if $STUBDIR vanished under it, the real `gc` further down
# $PATH would send that mail for real. Here "command not found" is the only outcome.
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$STUBDIR" jq || exit 2   # jq: the extracted code's session/bead parse; gc is the stub above

TWO_LIVE_SESSIONS='{"sessions":[{"id":"s1","name":"gastown.dog-1","state":"active","closed":false},{"id":"s2","name":"gastown.dog-2","state":"active","closed":false}]}'
ONE_OVERLAY_ROW='[{"metadata":{"configured_named_identity":"lexbh/gastown.witness","state":"active"},"status":"open"}]'

# The witness's session exports its rig root next to GC_CITY_PATH; a read pinned to it (instead of to the
# city) reaches the rig store, so every scenario carries it as the wrong store a mispinned read would hit.
# Neither path has to exist: the stub only compares the strings.
FAKE_CITY="/fake/city"
FAKE_RIG="/fake/rig"

# Printed after the extracted block. The map goes out as one JSON line so a scenario can ask what a given
# assignee resolved to — proving the overlay contributed, not merely that nothing was reported.
TRAILER='echo "RESULT MAP_COUNT=$MAP_COUNT SESSION_COUNT=$SESSION_COUNT"; echo "RESULT_MAP $(printf "%s" "$LIVENESS_MAP" | jq -c .)"'

# run_scenario SESSIONS_RC SESSIONS_BODY BEADS_RC BEADS_BODY [CITY_MODE]
#   CITY_MODE: set (default, GC_CITY_PATH=$FAKE_CITY) | empty (exported empty) | unset (not in the env)
# Sets SCENARIO_OUT (the extracted code's combined stdout+stderr — callers grep it), SCENARIO_RC,
# SCENARIO_MAILED, SCENARIO_MAP (the liveness map JSON, empty if the block never got that far) and the spy:
# SCENARIO_BD_CALLS / SCENARIO_BD_LOG (every `gc bd` call the block made).
run_scenario() {
  local sessions_rc="$1" sessions_body="$2" beads_rc="$3" beads_body="$4" city_mode="${5:-set}"
  local mail_log bd_log city_env="$FAKE_CITY" prefix=""
  mail_log="$(mktemp)"; bd_log="$(mktemp)"
  case "$city_mode" in
    empty) city_env="" ;;
    unset) city_env=""; prefix='unset GC_CITY_PATH; ' ;;
  esac
  local out rc
  out="$(
    STUB_SESSIONS_RC="$sessions_rc" STUB_SESSIONS_BODY="$sessions_body" \
    STUB_BEADS_RC="$beads_rc" STUB_BEADS_BODY="$beads_body" \
    STUB_CITY_PATH="$FAKE_CITY" GC_CITY_PATH="$city_env" GC_RIG_ROOT="$FAKE_RIG" \
    BD_LOG="$bd_log" MAIL_LOG="$mail_log" \
    PATH="$SANDBOX_PATH" \
    bash -c "${prefix}${LIVENESS_CODE}"$'\n'"$TRAILER" 2>&1
  )"
  rc=$?
  SCENARIO_OUT="$out"
  SCENARIO_RC="$rc"
  SCENARIO_MAP="$(printf '%s\n' "$out" | sed -n 's/^RESULT_MAP //p')"
  SCENARIO_MAILED="no"
  [ -s "$mail_log" ] && SCENARIO_MAILED="yes"
  SCENARIO_BD_CALLS="$(grep -c '^GCBD ' "$bd_log")"
  SCENARIO_BD_LOG="$(cat "$bd_log")"
  rm -f "$mail_log" "$bd_log"
}

# map_state KEY — what the last scenario's liveness map resolved KEY to ("absent" if not a key, "nomap" if
# the block never built a map).
map_state() {
  [ -n "$SCENARIO_MAP" ] || { printf 'nomap'; return; }
  printf '%s' "$SCENARIO_MAP" | jq -r --arg k "$1" '.[$k] // "absent"'
}

# run_snippet CODE — runs one command line (a documented or prompted read) under the same stub topology
# with GC_CITY_PATH set. Sets SNIPPET_OUT (stdout+stderr) and SNIPPET_RC.
run_snippet() {
  SNIPPET_OUT="$(
    STUB_BEADS_RC=0 STUB_BEADS_BODY="$ONE_OVERLAY_ROW" \
    STUB_CITY_PATH="$FAKE_CITY" GC_CITY_PATH="$FAKE_CITY" GC_RIG_ROOT="$FAKE_RIG" \
    PATH="$SANDBOX_PATH" \
    bash -c "$1" 2>&1
  )"
  SNIPPET_RC=$?
}

# ── Scenario 1: baseline healthy — both reads succeed ─────────────────────
echo ""
echo "Scenario 1: both reads healthy"
run_scenario 0 "$TWO_LIVE_SESSIONS" 0 "$ONE_OVERLAY_ROW"
if [ "$SCENARIO_RC" -eq 0 ]; then ok "extracted block exits 0"; else bad "extracted block exited $SCENARIO_RC: $SCENARIO_OUT"; fi
if ! printf '%s' "$SCENARIO_OUT" | grep "FAIL-SAFE\|OVERLAY UNKNOWN" >/dev/null; then
  ok "no fail-safe / overlay-unknown noise on the healthy path"
else
  bad "unexpected fail-safe/overlay-unknown output on healthy path: $SCENARIO_OUT"
fi
if printf '%s' "$SCENARIO_OUT" | grep "RESULT MAP_COUNT=[1-9]" >/dev/null; then
  ok "map is non-empty on the healthy path"
else
  bad "map came back empty on the healthy path: $SCENARIO_OUT"
fi
if [ "$(map_state lexbh/gastown.witness)" = "active" ]; then
  ok "the session-bead overlay contributed (lexbh/gastown.witness resolved to its overlay state)"
else
  bad "the overlay did not contribute on the healthy path (lexbh/gastown.witness -> $(map_state lexbh/gastown.witness)): $SCENARIO_OUT"
fi

# ── Scenario 2: THE BUG — session-beads read fails, rc=1, 0 bytes ─────────
# This is the exact shape from the bug's own evidence (14/09, three
# failures ~40s each, rc=1, 0 bytes). Pre-fix, this scenario produces a
# non-empty map (from the live session list) with ZERO indication the
# overlay read ever failed — the defect this bug exists to close.
echo ""
echo "Scenario 2 (THE BUG): session-beads read fails rc=1, 0 bytes"
run_scenario 0 "$TWO_LIVE_SESSIONS" 1 ""
if printf '%s' "$SCENARIO_OUT" | grep "OVERLAY UNKNOWN" >/dev/null; then
  ok "declares OVERLAY UNKNOWN instead of silently proceeding"
else
  bad "REGRESSION (this is the bug): overlay read failure went undeclared. Output: $SCENARIO_OUT"
fi
if ! printf '%s' "$SCENARIO_OUT" | grep "FAIL-SAFE: empty liveness map" >/dev/null; then
  ok "does NOT spuriously trip the empty-map fail-safe (live list alone is non-empty)"
else
  bad "wrongly tripped the empty-map fail-safe when only the overlay failed"
fi
if printf '%s' "$SCENARIO_OUT" | grep "RESULT MAP_COUNT=[1-9] SESSION_COUNT=2" >/dev/null; then
  ok "still resolves assignees from the live session list (map non-empty, 2 sessions counted)"
else
  bad "live-session-derived map was lost: $SCENARIO_OUT"
fi
# The read's own error line must reach the declaration: `rc=1, 0 bytes` alone cannot tell a wrong store from
# a flaky one, which is how a dead overlay stayed unnoticed (ga-zo1bzza).
if printf '%s' "$SCENARIO_OUT" | grep -F 'STUB-ERR-city: simulated city-store read failure' >/dev/null; then
  ok "OVERLAY UNKNOWN carries the read's own error line, so the cause is visible"
else
  bad "OVERLAY UNKNOWN hides WHY the read failed (its stderr never reaches the output): $SCENARIO_OUT"
fi
if [ "$(map_state lexbh/gastown.witness)" = "absent" ]; then
  ok "a failed overlay read adds nothing to the map (inert, not invented)"
else
  bad "a failed overlay read still put lexbh/gastown.witness in the map as '$(map_state lexbh/gastown.witness)': $SCENARIO_OUT"
fi

# ── Scenario 3: live session list itself fails, rc=1, 0 bytes ─────────────
echo ""
echo "Scenario 3: gc session list itself fails rc=1, 0 bytes"
run_scenario 1 "" 0 "$ONE_OVERLAY_ROW"
if printf '%s' "$SCENARIO_OUT" | grep "FAIL-SAFE: gc session list read failed" >/dev/null; then
  ok "aborts recovery this cycle on a broken live-session-list read"
else
  bad "REGRESSION: broken session-list read was not caught. Output: $SCENARIO_OUT"
fi
if [ "$SCENARIO_MAILED" = "yes" ]; then
  ok "escalates to mayor on a broken live-session-list read"
else
  bad "no mayor escalation on a broken live-session-list read"
fi
# The block must actually HALT here, not just print a message and fall
# through (the exact defect a prior gate review caught: a comment saying
# "skip the rest" with no exit/return/continue behind it). Three
# independent signals of a real halt, not a coincidental empty result:
if [ "$SCENARIO_RC" -eq 0 ]; then
  ok "exits cleanly (rc=0) instead of running off the end into jq errors"
else
  bad "REGRESSION: block did not exit cleanly (rc=$SCENARIO_RC): $SCENARIO_OUT"
fi
if ! printf '%s' "$SCENARIO_OUT" | grep "OVERLAY UNKNOWN" >/dev/null; then
  ok "does not fall through into the overlay guard (which would misreport a successful read as failed)"
else
  bad "REGRESSION: fell through into OVERLAY UNKNOWN after the sessions-list guard already fired: $SCENARIO_OUT"
fi
if ! printf '%s' "$SCENARIO_OUT" | grep "RESULT MAP_COUNT=" >/dev/null; then
  ok "never reaches the code after the block (proves the halt, not a coincidental zero)"
else
  bad "REGRESSION: execution reached past the guard into LIVENESS_MAP/SESSION_COUNT: $SCENARIO_OUT"
fi

# ── Scenario 4: live session list returns partial/invalid JSON (rc=0) ─────
# Covers acceptance criterion (c): rc alone isn't the only failure shape —
# a command that "succeeds" but emits garbage must be caught too.
echo ""
echo "Scenario 4: gc session list returns invalid JSON with rc=0"
run_scenario 0 "not valid json {{{" 0 "$ONE_OVERLAY_ROW"
if printf '%s' "$SCENARIO_OUT" | grep "FAIL-SAFE: gc session list read failed" >/dev/null; then
  ok "aborts recovery this cycle on invalid JSON even when rc=0"
else
  bad "REGRESSION: invalid-JSON session-list output was not caught. Output: $SCENARIO_OUT"
fi
if [ "$SCENARIO_RC" -eq 0 ]; then
  ok "exits cleanly (rc=0) instead of running off the end into jq errors"
else
  bad "REGRESSION: block did not exit cleanly (rc=$SCENARIO_RC): $SCENARIO_OUT"
fi
if ! printf '%s' "$SCENARIO_OUT" | grep "OVERLAY UNKNOWN" >/dev/null; then
  ok "does not fall through into the overlay guard (which would misreport a successful read as failed)"
else
  bad "REGRESSION: fell through into OVERLAY UNKNOWN after the sessions-list guard already fired: $SCENARIO_OUT"
fi
if ! printf '%s' "$SCENARIO_OUT" | grep "RESULT MAP_COUNT=" >/dev/null; then
  ok "never reaches the code after the block (proves the halt, not a coincidental zero)"
else
  bad "REGRESSION: execution reached past the guard into LIVENESS_MAP/SESSION_COUNT: $SCENARIO_OUT"
fi

# ── Scenario 5: pre-existing fail-safe still works (schema drift) ─────────
# Both reads succeed (rc=0, non-empty, valid JSON) but the session objects
# carry none of the recognized key fields, so the map-builder legitimately
# produces an empty map despite SESSION_COUNT>0 — the original gc-3tn8g
# schema-drift case this fail-safe was built for.
echo ""
echo "Scenario 5: pre-existing empty-map fail-safe (schema drift) still fires"
run_scenario 0 '{"sessions":[{"unexpected_field":"x"},{"unexpected_field":"y"}]}' 0 "[]"
if printf '%s' "$SCENARIO_OUT" | grep "FAIL-SAFE: empty liveness map" >/dev/null; then
  ok "schema-drift fail-safe still fires unchanged"
else
  bad "REGRESSION: schema-drift fail-safe no longer fires. Output: $SCENARIO_OUT"
fi
if [ "$SCENARIO_MAILED" = "yes" ]; then
  ok "schema-drift fail-safe still escalates to mayor"
else
  bad "schema-drift fail-safe no longer escalates to mayor"
fi

# ── Scenario 6 (ga-zo1bzza): the overlay read targets the CITY store ───────
# Session beads live only in the city store. `gc bd` with no -C reads the store the caller resolves to —
# for a rig witness the RIG store, where the type does not exist — so the overlay silently never
# contributed. The stub answers each call by the store it reaches (see its header), so an unpinned or
# mispinned read fails here the way the real one did.
echo ""
echo "Scenario 6 (THE BUG, ga-zo1bzza): the session-bead read is pinned to the city store"
ctl_out="$("$STUBDIR/bin/gc" bd list --type=session 2>&1)"; ctl_rc=$?
if [ "$ctl_rc" -eq 1 ] && printf '%s' "$ctl_out" | grep -F 'invalid issue type "session"' >/dev/null; then
  ok "control: an unpinned read answers like a rig store (the stub models the real topology)"
else
  bad "control broken: the stub no longer fails an unpinned session read (rc=$ctl_rc): $ctl_out"
fi
run_scenario 0 "$TWO_LIVE_SESSIONS" 0 "$ONE_OVERLAY_ROW"
if [ "$SCENARIO_BD_CALLS" -eq 1 ] && printf '%s\n' "$SCENARIO_BD_LOG" | grep -F "GCBD bd -C $FAKE_CITY list --type=session" >/dev/null; then
  ok "one gc bd call, pinned to the city store"
else
  bad "REGRESSION (this is the bug): the session-bead read is not pinned to the city store. gc bd calls ($SCENARIO_BD_CALLS): $SCENARIO_BD_LOG"
fi

# ── Scenario 7 (ga-zo1bzza): no city path, no read ─────────────────────────
# An empty GC_CITY_PATH must not become `gc bd -C "" ...` (or a bare gc bd): that read resolves from the
# caller's cwd — a different store depending on where the agent-home sits, and it can even succeed by
# accident. The read is not attempted and the overlay is declared unknown: the same inert state as a failed read.
for mode in empty unset; do
  echo ""
  echo "Scenario 7 ($mode): GC_CITY_PATH $mode — the read is not attempted"
  run_scenario 0 "$TWO_LIVE_SESSIONS" 0 "$ONE_OVERLAY_ROW" "$mode"
  if [ "$SCENARIO_BD_CALLS" -eq 0 ]; then
    ok "no gc bd call goes out without a city path to pin it to"
  else
    bad "a gc bd read went out with GC_CITY_PATH $mode (cwd-dependent store): $SCENARIO_BD_LOG"
  fi
  if printf '%s' "$SCENARIO_OUT" | grep "OVERLAY UNKNOWN" >/dev/null && printf '%s' "$SCENARIO_OUT" | grep -F "GC_CITY_PATH" >/dev/null; then
    ok "declares OVERLAY UNKNOWN and says why (GC_CITY_PATH)"
  else
    bad "no OVERLAY UNKNOWN naming GC_CITY_PATH: $SCENARIO_OUT"
  fi
  if [ "$SCENARIO_RC" -eq 0 ] && printf '%s' "$SCENARIO_OUT" | grep "RESULT MAP_COUNT=4 SESSION_COUNT=2" >/dev/null \
     && ! printf '%s' "$SCENARIO_OUT" | grep "FAIL-SAFE" >/dev/null; then
    ok "still resolves from the live session list alone (4 keys, 2 sessions), no fail-safe, exit 0"
  else
    bad "live-list-only roster lost or fail-safe tripped (rc=$SCENARIO_RC): $SCENARIO_OUT"
  fi
done

# ── Scenario 8 (ga-zo1bzza): the reads written down for a witness run clean ─
# The formula documents the roster read once above the recipe, and the prompt tells a witness whose wisp
# text is the NATIVE formula, not this file (a rig can still have one), what to run for the overlay. A
# witness copies those lines, so they are EXECUTED here under the same stub topology, not compared as text.
run_documented_reads() { # $1 = label, $2 = newline-separated command lines
  local label="$1" lines="$2" n=0 failed=0 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n+1))
    run_snippet "$line"
    if [ "$SNIPPET_RC" -ne 0 ] || [ "$SNIPPET_OUT" != "$ONE_OVERLAY_ROW" ]; then
      failed=$((failed+1))
      echo "    ($label) rc=$SNIPPET_RC for: $line :: $SNIPPET_OUT"
    fi
  done <<< "$lines"
  if [ "$n" -eq 0 ]; then
    bad "$label: no session-bead read command found to run"
  elif [ "$failed" -eq 0 ]; then
    ok "$label: all $n session-bead read command(s) read the city store"
  else
    bad "$label: $failed of $n session-bead read command(s) did not reach the city store"
  fi
}
echo ""
echo "Scenario 8 (ga-zo1bzza): the documented and the prompted session-bead reads reach the city store"
run_documented_reads "formula roster listing" "$(grep -E '^gc bd .*--type=session' "$FORMULA")"
run_documented_reads "witness prompt" "$(sed -n '/WITNESS: o Startup Protocol/,$p' "$TEMPLATE" | grep -E '^gc bd .*--type=session')"

# ── Verdict ─────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
