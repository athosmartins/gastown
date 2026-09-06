#!/usr/bin/env bash
# variable-session-cap.selftest.sh (ga-jezvn)
#
# Proves the GLOBAL variable-session cap (wa-worker + ps-worker + gate-reviewer
# combined, Athos-decided ceiling via AskUserQuestion/Mayor, 2026-09-06):
#   1. gc_variable_session_count() correctly counts only the 3 target
#      template types, excluding structural sessions (crews/mayor/
#      control-dispatcher) AND the separately-capped gastown.dog pool.
#   2. pilot-dispatcher.sh's and quality-gate-dispatcher.sh's copies of that
#      function are byte-for-byte identical (the "shared by definition, not
#      by sourcing" contract).
#   3. gate's new RAM-pressure reader (_gate_ram_pressure_*) matches
#      pilot-dispatcher.sh's existing OK/WARN/EMERGENCY + stale/corrupt
#      fail-open semantics.
#   4. The reproduction case Mayor's acceptance criteria names explicitly:
#      with 6 "variable" sessions already alive, the count is AT the cap
#      (>= 6 → must queue); with 5, it is UNDER the cap (< 6 → may proceed).
#   5. Drift-guards: both new checks are actually wired into both dispatchers
#      at the right place, in the right order, with the right (queue, never
#      refuse) behavior — not just present somewhere in the file.
#
# Run against the shared root (pre-patch) to confirm RED — functions absent/
# wiring absent — or against a worktree (post-patch, the default here) to
# confirm GREEN. Override via PILOT_DISPATCHER_PATH / GATE_DISPATCHER_PATH.
#
# Subshells below isolate two risky operations (sourcing a huge live
# dispatcher; extracting+sourcing a standalone function) from this script's
# own state. Because a subshell's variable changes never propagate back,
# each subshell tallies its OWN pass/fail into a tmp file on exit, which the
# parent then folds into PASS/FAIL after the subshell closes — ok()/bad()
# calls made *inside* a subshell would otherwise print correctly but vanish
# from the final count.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PILOT="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
GATE="${GATE_DISPATCHER_PATH:-$SELF_DIR/quality-gate-dispatcher.sh}"

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$1" = "$2" ]; then ok "$3 (got: $1)"; else bad "$3 (expected: $2, got: $1)"; fi; }

# fold_tally <tally-file> <label> — add a subshell's counts into PASS/FAIL,
# or record one FAIL if the subshell never got far enough to write the file
# (e.g. it exited early on a missing function — the RED-state case).
fold_tally() {
  local f="$1" label="$2" p f_ fcount
  if [ -f "$f" ]; then
    p=$(cut -d' ' -f1 "$f"); fcount=$(cut -d' ' -f2 "$f")
    PASS=$((PASS + p)); FAIL=$((FAIL + fcount))
  else
    bad "$label: subshell exited before writing its tally (see output above for why)"
  fi
}

TMPDIR_SELFTEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SELFTEST"' EXIT

[ -f "$PILOT" ] || { echo "FATAL: pilot dispatcher not found at $PILOT"; exit 1; }
[ -f "$GATE" ]  || { echo "FATAL: gate dispatcher not found at $GATE"; exit 1; }

echo "── Syntax ──────────────────────────────────────────────────────────────"
if bash -n "$PILOT" 2>/dev/null; then ok "pilot-dispatcher.sh parses"; else bad "pilot-dispatcher.sh has a syntax error"; fi
if bash -n "$GATE" 2>/dev/null; then ok "quality-gate-dispatcher.sh parses"; else bad "quality-gate-dispatcher.sh has a syntax error"; fi

echo "── Fixture: fake 'gc session list --json' (6 variable + assorted structural) ─"
# 6 "variable" sessions counted: s1/s2 wa-worker, s3 ps-worker, s4/s5/s6b
# gate-reviewer (s6 is gate-reviewer but "asleep" — must NOT count, exercises
# the state filter). Everything else is a non-target template (crews, mayor,
# control-dispatcher, and gastown.dog — a 4th elastic pool, deliberately out
# of THIS cap's scope) and must never be counted regardless of state.
FIXTURE_6_JSON="$TMPDIR_SELFTEST/sessions-6-variable.json"
cat > "$FIXTURE_6_JSON" <<'EOF'
{"ok":true,"sessions":[
  {"id":"s1","template":"wa-worker","state":"active"},
  {"id":"s2","template":"wa-worker","state":"creating"},
  {"id":"s3","template":"ps-worker","state":"active"},
  {"id":"s4","template":"gate-reviewer","state":"active"},
  {"id":"s5","template":"gate-reviewer","state":"active"},
  {"id":"s6","template":"gate-reviewer","state":"asleep"},
  {"id":"s6b","template":"gate-reviewer","state":"active"},
  {"id":"s7","template":"gastown.mayor","state":"active"},
  {"id":"s8","template":"control-dispatcher","state":"active"},
  {"id":"s9","template":"batista-lx","state":"active"},
  {"id":"s10","template":"whatsapp_automation/batista-wa","state":"active"},
  {"id":"s11","template":"whatsapp_automation/digo-wa","state":"active"},
  {"id":"s12","template":"whatsapp_automation/peter-wa","state":"active"},
  {"id":"s13","template":"whatsapp_automation/thies-wa","state":"active"},
  {"id":"s14","template":"mila-wa","state":"active"},
  {"id":"s15","template":"gastown.dog","state":"active"}
]}
EOF
# One wa-worker session removed (s2) relative to the fixture above = 5 variable.
FIXTURE_5_JSON="$TMPDIR_SELFTEST/sessions-5-variable.json"
jq 'del(.sessions[1])' "$FIXTURE_6_JSON" > "$FIXTURE_5_JSON"

# Fake `gc` binary: `gc ... session list --json` prints $GC_FAKE_FIXTURE;
# anything else is a no-op success. Shadows the real `gc` via PATH.
FAKE_BIN_DIR="$TMPDIR_SELFTEST/bin"
mkdir -p "$FAKE_BIN_DIR"
cat > "$FAKE_BIN_DIR/gc" <<'EOF'
#!/usr/bin/env bash
if printf '%s\n' "$*" | grep -q 'session list --json'; then
  cat "$GC_FAKE_FIXTURE"
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/gc"

echo "── gc_variable_session_count: pilot vs gate, byte-identical? ────────────"
extract_fn() { awk "/^gc_variable_session_count\\(\\) \\{/,/^\\}/" "$1"; }
PILOT_FN="$(extract_fn "$PILOT")"
GATE_FN="$(extract_fn "$GATE")"
if [ -z "$PILOT_FN" ]; then bad "gc_variable_session_count() not found in pilot-dispatcher.sh"; fi
if [ -z "$GATE_FN" ]; then bad "gc_variable_session_count() not found in quality-gate-dispatcher.sh"; fi
if [ -n "$PILOT_FN" ] && [ -n "$GATE_FN" ]; then
  if [ "$PILOT_FN" = "$GATE_FN" ]; then
    ok "gc_variable_session_count() is byte-for-byte identical in both dispatchers"
  else
    bad "gc_variable_session_count() DIFFERS between pilot-dispatcher.sh and quality-gate-dispatcher.sh"
  fi
fi

if [ -n "$PILOT_FN" ]; then
  echo "── gc_variable_session_count (pilot's copy, extracted+sourced standalone) ─"
  EXTRACTED="$TMPDIR_SELFTEST/pilot_fn.sh"
  { echo '#!/usr/bin/env bash'; echo "$PILOT_FN"; } > "$EXTRACTED"
  chmod +x "$EXTRACTED"
  (
    p=0; f=0
    ok()  { echo "  ✓ $*"; p=$((p+1)); }
    bad() { echo "  ✗ $*"; f=$((f+1)); }
    eq()  { if [ "$1" = "$2" ]; then ok "$3 (got: $1)"; else bad "$3 (expected: $2, got: $1)"; fi; }

    # shellcheck disable=SC1090
    source "$EXTRACTED"
    export PATH="$FAKE_BIN_DIR:$PATH"
    export GC_CITY="/nonexistent-city"
    unset GC_VARIABLE_SESSION_COUNT_OVERRIDE 2>/dev/null || true

    export GC_FAKE_FIXTURE="$FIXTURE_6_JSON"
    n=$(gc_variable_session_count)
    eq "$n" "6" "pilot: 6-variable fixture → count=6 (non-target templates excluded)"

    export GC_FAKE_FIXTURE="$FIXTURE_5_JSON"
    n=$(gc_variable_session_count)
    eq "$n" "5" "pilot: 5-variable fixture → count=5"

    export GC_VARIABLE_SESSION_COUNT_OVERRIDE="42"
    n=$(gc_variable_session_count)
    eq "$n" "42" "pilot: GC_VARIABLE_SESSION_COUNT_OVERRIDE seam short-circuits the live query"

    echo "$p $f" > "$TMPDIR_SELFTEST/tally_pilot_fn"
  )
  fold_tally "$TMPDIR_SELFTEST/tally_pilot_fn" "pilot gc_variable_session_count"
fi

echo "── gate: source with GATE_DISPATCHER_LIB_ONLY=1 (safe — early-returns before any live work) ─"
(
  p=0; f=0
  ok()  { echo "  ✓ $*"; p=$((p+1)); }
  bad() { echo "  ✗ $*"; f=$((f+1)); }
  eq()  { if [ "$1" = "$2" ]; then ok "$3 (got: $1)"; else bad "$3 (expected: $2, got: $1)"; fi; }

  set +u
  export GATE_DISPATCHER_LIB_ONLY=1
  # shellcheck disable=SC1090
  source "$GATE" >/dev/null 2>&1
  set -u
  # Defensive stub, matching gate-verdict-timeout-scale.selftest.sh's own
  # convention — our functions under test don't call log/warn/err, but stay
  # consistent with house style in case that ever changes.
  log()  { :; }
  warn() { :; }
  err()  { :; }

  if ! type _gate_ram_pressure_blocks >/dev/null 2>&1; then
    bad "_gate_ram_pressure_blocks not defined after GATE_DISPATCHER_LIB_ONLY=1 source"
    echo "$p $f" > "$TMPDIR_SELFTEST/tally_gate"
    exit 0
  fi
  if ! type gc_variable_session_count >/dev/null 2>&1; then
    bad "gc_variable_session_count not defined after GATE_DISPATCHER_LIB_ONLY=1 source"
    echo "$p $f" > "$TMPDIR_SELFTEST/tally_gate"
    exit 0
  fi
  ok "both new functions are defined and callable after a LIB_ONLY source (i.e. before the cutoff)"

  echo "OK
$(date +%s)" > "$TMPDIR_SELFTEST/ram-ok.level"
  echo "WARN
$(date +%s)" > "$TMPDIR_SELFTEST/ram-warn.level"
  echo "EMERGENCY
$(date +%s)" > "$TMPDIR_SELFTEST/ram-emergency.level"
  echo "WARN
1" > "$TMPDIR_SELFTEST/ram-stale.level"          # ts=1 → ancient → stale
  printf 'garbage\nnotanumber\n' > "$TMPDIR_SELFTEST/ram-corrupt.level"

  export GATE_RAM_LEVEL_FILE="$TMPDIR_SELFTEST/ram-ok.level"
  eq "$(_gate_ram_pressure_blocks)" "0" "gate RAM: level=OK, fresh → does not block"
  eq "$(_gate_ram_pressure_unreadable)" "0" "gate RAM: level=OK, fresh → not flagged unreadable"

  export GATE_RAM_LEVEL_FILE="$TMPDIR_SELFTEST/ram-warn.level"
  eq "$(_gate_ram_pressure_blocks)" "1" "gate RAM: level=WARN, fresh → blocks"

  export GATE_RAM_LEVEL_FILE="$TMPDIR_SELFTEST/ram-emergency.level"
  eq "$(_gate_ram_pressure_blocks)" "1" "gate RAM: level=EMERGENCY, fresh → blocks"

  export GATE_RAM_LEVEL_FILE="$TMPDIR_SELFTEST/ram-stale.level"
  eq "$(_gate_ram_pressure_blocks)" "0" "gate RAM: level=WARN but STALE ts → fail-open, does not block"
  eq "$(_gate_ram_pressure_unreadable)" "1" "gate RAM: stale ts → flagged unreadable (visible in log, ga-cgls6 shape)"

  export GATE_RAM_LEVEL_FILE="$TMPDIR_SELFTEST/ram-corrupt.level"
  eq "$(_gate_ram_pressure_blocks)" "0" "gate RAM: corrupt ts → fail-open, does not block"
  eq "$(_gate_ram_pressure_unreadable)" "1" "gate RAM: corrupt ts → flagged unreadable"

  export GATE_RAM_LEVEL_FILE="$TMPDIR_SELFTEST/does-not-exist.level"
  eq "$(_gate_ram_pressure_blocks)" "0" "gate RAM: absent file → does not block (silent, by design)"
  eq "$(_gate_ram_pressure_unreadable)" "0" "gate RAM: absent file → NOT flagged unreadable (ga-cgls6: absence != anomaly)"

  export GATE_RAM_PRESSURE_OVERRIDE="EMERGENCY"
  eq "$(_gate_ram_pressure_blocks)" "1" "gate RAM: GATE_RAM_PRESSURE_OVERRIDE=EMERGENCY seam works"
  unset GATE_RAM_PRESSURE_OVERRIDE

  export PATH="$FAKE_BIN_DIR:$PATH"
  export GC_CITY="/nonexistent-city"
  unset GC_VARIABLE_SESSION_COUNT_OVERRIDE 2>/dev/null || true

  export GC_FAKE_FIXTURE="$FIXTURE_6_JSON"
  n=$(gc_variable_session_count)
  eq "$n" "6" "gate: 6-variable fixture → count=6 (non-target templates excluded)"
  eq "${GC_VARIABLE_SESSION_MAX:-unset}" "6" "gate: GC_VARIABLE_SESSION_MAX defaults to 6"
  if [ "${n:-0}" -ge "${GC_VARIABLE_SESSION_MAX:-6}" ] 2>/dev/null; then
    ok "gate: 6 live == cap 6 — Mayor's acceptance scenario: MUST QUEUE"
  else
    bad "gate: 6 live did not register as >= cap 6 — the reproduction case is broken"
  fi

  export GC_FAKE_FIXTURE="$FIXTURE_5_JSON"
  n=$(gc_variable_session_count)
  eq "$n" "5" "gate: 5-variable fixture → count=5"
  if [ "${n:-0}" -lt "${GC_VARIABLE_SESSION_MAX:-6}" ] 2>/dev/null; then
    ok "gate: 5 live < cap 6 → correctly under cap, may proceed"
  else
    bad "gate: 5 live incorrectly registered as at/over cap"
  fi

  export GC_VARIABLE_SESSION_COUNT_OVERRIDE="0"
  n=$(gc_variable_session_count)
  eq "$n" "0" "gate: GC_VARIABLE_SESSION_COUNT_OVERRIDE seam short-circuits the live query"

  echo "$p $f" > "$TMPDIR_SELFTEST/tally_gate"
)
fold_tally "$TMPDIR_SELFTEST/tally_gate" "gate LIB_ONLY functions"

echo "── Drift-guards: wiring actually present, in the right place/order ──────"

# 1. Both pilot spawn sites call the new check BEFORE their existing per-pool
#    cap comment, and release the claim (return 1) rather than falling
#    through to the existing pool-cap's supervisor hand-off.
PILOT_WA_CALL_LINE=$(grep -n '_gc_variable_count=\$(gc_variable_session_count)' "$PILOT" | sed -n '1p' | cut -d: -f1)
PILOT_WA_POOLCAP_LINE=$(grep -n 'ga-v3o6i: max-cap guard' "$PILOT" | sed -n '1p' | cut -d: -f1)
if [ -n "${PILOT_WA_CALL_LINE:-}" ] && [ -n "${PILOT_WA_POOLCAP_LINE:-}" ] && [ "$PILOT_WA_CALL_LINE" -lt "$PILOT_WA_POOLCAP_LINE" ]; then
  ok "pilot wa-worker branch: global-cap check (L$PILOT_WA_CALL_LINE) precedes the per-pool cap (L$PILOT_WA_POOLCAP_LINE)"
else
  bad "pilot wa-worker branch: global-cap check is missing or not before the per-pool cap"
fi
PILOT_CALL_COUNT=$(grep -c '_gc_variable_count=\$(gc_variable_session_count)' "$PILOT" 2>/dev/null)
PILOT_CALL_COUNT="${PILOT_CALL_COUNT:-0}"
eq "$PILOT_CALL_COUNT" "2" "pilot: exactly 2 call sites (wa-worker branch + ps-worker branch)"
PILOT_RETURN1_AFTER_CAP=$(awk '/GLOBAL variable-session cap hit/{f=1} f&&/return 1/{c++} f&&/^          fi$/{f=0} END{print c+0}' "$PILOT")
eq "$PILOT_RETURN1_AFTER_CAP" "2" "pilot: both cap-hit branches release the claim via 'return 1' (not fall-through)"

# 2. Gate's new checks sit strictly between quiet-hours and Step 0b-1, and
#    the function DEFINITIONS sit strictly before the LIB_ONLY cutoff.
GATE_QUIET_HOURS_LINE=$(grep -n '^# ── ga-dxyvxr: quiet-hours admission gate' "$GATE" | sed -n '1p' | cut -d: -f1)
GATE_RAM_CALL_LINE=$(grep -n '_gate_ram_pressure_blocks)" = "1"' "$GATE" | sed -n '1p' | cut -d: -f1)
GATE_CAP_CALL_LINE=$(grep -n 'GLOBAL variable-session cap hit' "$GATE" | sed -n '1p' | cut -d: -f1)
GATE_HEADROOM_LINE=$(grep -n 'Step 0b-1 (ga-cw4pm): dynamic-concurrency headroom gate' "$GATE" | sed -n '1p' | cut -d: -f1)
if [ -n "${GATE_QUIET_HOURS_LINE:-}" ] && [ -n "${GATE_RAM_CALL_LINE:-}" ] && [ -n "${GATE_CAP_CALL_LINE:-}" ] && [ -n "${GATE_HEADROOM_LINE:-}" ] \
   && [ "$GATE_QUIET_HOURS_LINE" -lt "$GATE_RAM_CALL_LINE" ] \
   && [ "$GATE_RAM_CALL_LINE" -lt "$GATE_CAP_CALL_LINE" ] \
   && [ "$GATE_CAP_CALL_LINE" -lt "$GATE_HEADROOM_LINE" ]; then
  ok "gate: quiet-hours (L$GATE_QUIET_HOURS_LINE) < RAM-pressure (L$GATE_RAM_CALL_LINE) < global-cap (L$GATE_CAP_CALL_LINE) < headroom (L$GATE_HEADROOM_LINE)"
else
  bad "gate: new checks are missing or out of the expected quiet-hours→RAM→cap→headroom order"
fi
GATE_FN_DEF_LINE=$(grep -n '^gc_variable_session_count() {' "$GATE" | sed -n '1p' | cut -d: -f1)
GATE_LIBONLY_LINE=$(grep -n 'if \[ -n "\${GATE_DISPATCHER_LIB_ONLY:-}" \]; then$' "$GATE" | sed -n '1p' | cut -d: -f1)
if [ -n "${GATE_FN_DEF_LINE:-}" ] && [ -n "${GATE_LIBONLY_LINE:-}" ] && [ "$GATE_FN_DEF_LINE" -lt "$GATE_LIBONLY_LINE" ]; then
  ok "gate: gc_variable_session_count() (L$GATE_FN_DEF_LINE) is defined before the LIB_ONLY cutoff (L$GATE_LIBONLY_LINE)"
else
  bad "gate: gc_variable_session_count() is missing or defined AFTER the LIB_ONLY cutoff (selftests could never reach it)"
fi

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
