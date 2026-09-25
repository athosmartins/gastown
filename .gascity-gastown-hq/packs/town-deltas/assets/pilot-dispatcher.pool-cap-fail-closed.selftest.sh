#!/usr/bin/env bash
# pilot-dispatcher.pool-cap-fail-closed.selftest.sh — ga-oa004t
#
# Incident (2026-09-25 ~15:1x): the wa-worker pool reached 5 ACTIVE sessions with
# PILOT_WA_WORKER_MAX=2 (memory -> swap 9 GB -> disk 4.4 GB, Dolt's floor is 3 GB).
# The bead blamed "a path that opens a session without going through the count".
# Measured instead (pilot-dispatcher.log, gc events, `gc session list`):
#   1. The live-count probe was FAIL-OPEN: `timeout 10 gc session list | jq … || echo "0"`.
#      `gc session list --json` takes 7-10s under load 55+, so a probe that timed out
#      read as "0 live" and the cap read as free capacity — the guard switched itself
#      OFF exactly when the box was most loaded.
#   2. A spawn that timed out (exit 124) was retried blind. `gc session new` takes ~50s
#      under load and creates the session BEFORE it finishes: the session bead landed
#      2s and 6s before the 60s kill (12:54:02, 14:59:49), then the retry opened another.
#   3. `start-pending` (accepted, not yet started — it WILL become a process) was not
#      counted as live.
# (The controller's own pool cap — agents/wa-worker/agent.toml max_active_sessions=4 —
#  is a separate knob the Pilot cannot enforce; that is reported on the bead, not tested here.)
#
# Every scenario below that asserts the FIX is written to FAIL against the unmodified
# dispatcher (run with PILOT_DISPATCHER_PATH pointing at a pre-fix copy to see it RED).
# The bead's own suggested test ("2 active with max=2 -> top-up does NOT open") already
# passes at HEAD — top-up counts by template — so it would prove nothing; the controls
# here (T3, T6) only guard against over-blocking.
#
# Functions are extracted verbatim from the dispatcher (awk) and driven against a fake `gc`
# that is a REAL executable on PATH — `timeout` exec()s its argument, so a shell function
# named gc would be invisible to it (same constraint as topup-spawn-diagnostics).
#
# Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

# fn_src <name> — the function's source verbatim, or nothing if the file does not define it.
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }

FUNCS=""
for _f in gc_json_or_unknown gc_variable_session_count _pilot_live_session_count _pilot_variable_session_count \
          _pilot_topup_spawn _pilot_pool_topup; do
  FUNCS="$FUNCS
$(fn_src "$_f")"
done
[ -n "$(fn_src _pilot_pool_topup)" ]  || { echo "FATAL: _pilot_pool_topup() not found in $DISPATCHER" >&2; exit 2; }
[ -n "$(fn_src _pilot_topup_spawn)" ] || { echo "FATAL: _pilot_topup_spawn() not found in $DISPATCHER" >&2; exit 2; }
HAVE_HELPER=0
[ -n "$(fn_src _pilot_live_session_count)" ] && HAVE_HELPER=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-poolcap-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Fake gc — behaviour steered by files in $SELFTEST_WORK.
cat > "$WORK/bin/gc" <<'GCEOF'
#!/usr/bin/env bash
W="${SELFTEST_WORK:?}"
case "$*" in
  *"session list"*)
    echo x >> "$W/list.calls"
    [ -f "$W/sl.sleep" ] && sleep "$(cat "$W/sl.sleep")"
    if [ -f "$W/sl.fail" ]; then echo "boom" >&2; exit 1; fi
    if [ -f "$W/sl.envelope" ]; then printf '{"ok":false,"error":{"code":"native_store_unavailable"}}'; exit 0; fi
    cat "$W/sl.json"; exit 0 ;;
  *"session new"*)
    echo "$*" >> "$W/new.log"
    rc=0; [ -f "$W/new.rc" ] && rc=$(cat "$W/new.rc")
    [ "$rc" != "0" ] && echo "spawn stderr rc=$rc" >&2
    exit "$rc" ;;
esac
exit 0
GCEOF
chmod +x "$WORK/bin/gc"
# `timeout` shim: drop the duration and exec (deterministic; a slow-probe scenario below uses the real one).
cat > "$WORK/bin/timeout" <<'TOEOF'
#!/usr/bin/env bash
shift
exec "$@"
TOEOF
chmod +x "$WORK/bin/timeout"

reset() { rm -f "$WORK"/list.calls "$WORK"/new.log "$WORK"/sl.* "$WORK"/new.rc "$WORK"/log.txt; }
# sessions_json <template:state>... -> {"sessions":[…]}
sessions_json() {
  local _first=1 _s _i=0
  printf '{"sessions":['
  for _s in "$@"; do
    [ "$_first" = 1 ] || printf ','
    _first=0; _i=$((_i+1))
    printf '{"id":"s%d","template":"%s","state":"%s"}' "$_i" "${_s%%:*}" "${_s##*:}"
  done
  printf ']}'
}
spawns() { [ -f "$WORK/new.log" ] && wc -l < "$WORK/new.log" | tr -d ' ' || echo 0; }
list_calls() { [ -f "$WORK/list.calls" ] && wc -l < "$WORK/list.calls" | tr -d ' ' || echo 0; }
logged() { grep -qF -- "$1" "$WORK/log.txt" 2>/dev/null; }

# run_topup <max> <pool>... — one sweep's worth of top-up calls in ONE shell (state such as the
# sticky unreadable flag lives across them, exactly as in the real sweep).
run_topup() {
  local _max="$1"; shift
  (
    PATH="${TOPUP_PATH:-$WORK/bin:$PATH}"
    SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    GC_CITY="test-city"; DRY_RUN=0; GC_VARIABLE_SESSION_MAX=9
    PILOT_DOLT_SATURATED_AT_START=0
    PILOT_SPAWN_TIMEOUT_SECS=5; PILOT_TOPUP_RETRY_DELAY_SECS=0
    PILOT_TEST_WA_WORKER_TOPUP_PENDING="wa-pend1"; PILOT_TEST_PS_WORKER_TOPUP_PENDING="ps-pend1"
    unset GC_VARIABLE_SESSION_COUNT_OVERRIDE PILOT_TEST_WA_WORKER_LIVE_COUNT PILOT_TEST_PS_WORKER_LIVE_COUNT
    log()  { printf 'log\t%s\n'  "$*" >> "$WORK/log.txt"; }
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/log.txt"; }
    eval "$FUNCS"
    local _p
    for _p in "$@"; do _pilot_pool_topup "$_p" "$_max"; done
    log "END (top-up returned normally; the script was not aborted)"
  )
}

echo "pilot-dispatcher.pool-cap-fail-closed.selftest — unreadable count fails CLOSED, timed-out spawn is not retried blind (ga-oa004t)"

# ── T1: the session-list probe FAILS → the pool must NOT be topped up ───────
echo "T1: 'gc session list' fails (probe timeout/error) — top-up must spawn NOTHING (was: read as 0 live, spawned up to the cap)"
reset; : > "$WORK/sl.fail"
run_topup 2 wa-worker
if [ "$(spawns)" = "0" ]; then
  ok "T1: unreadable count → 0 spawns"
else
  bad "T1: $(spawns) session(s) spawned on an UNREADABLE count — the cap guard fails OPEN exactly when the box is loaded"
fi
logged "cannot read" && ok "T1: the blind spot is ANNOUNCED in the log (not a silent skip)" \
  || bad "T1: no 'cannot read …' line — a dead probe would look identical to an idle pool"

# ── T1b: a gc ERROR ENVELOPE (valid JSON, ok:false) is unknown, never a known zero ─
echo "T1b: gc prints {\"ok\":false,…} (parses as JSON, no .sessions) — must read as UNKNOWN, not '0 sessions'"
reset; : > "$WORK/sl.envelope"
run_topup 2 wa-worker
[ "$(spawns)" = "0" ] && ok "T1b: error envelope → 0 spawns" \
  || bad "T1b: $(spawns) session(s) spawned off an error envelope read as an empty pool"

# ── T2: start-pending is a LIVE session ────────────────────────────────────
echo "T2: 1 active + 1 start-pending wa-worker, max=2 — the pool is FULL (start-pending WILL become a process)"
reset; sessions_json "wa-worker:active" "wa-worker:start-pending" > "$WORK/sl.json"
run_topup 2 wa-worker
[ "$(spawns)" = "0" ] && ok "T2: start-pending counted → 0 spawns (pool at 2/2)" \
  || bad "T2: $(spawns) spawn(s) although 2 sessions are live (1 active + 1 start-pending) — start-pending is not counted"

# ── T3 (control): a genuinely free slot still spawns exactly one ───────────
echo "T3 (control): 1 active wa-worker, max=2 — exactly ONE spawn (proves the harness reaches the spawn; guards over-blocking)"
reset; sessions_json "wa-worker:active" "ps-worker:active" "wa-worker:asleep" > "$WORK/sl.json"
run_topup 2 wa-worker
[ "$(spawns)" = "1" ] && ok "T3: 1 live wa-worker (asleep + other templates not counted) → exactly 1 spawn" \
  || bad "T3: expected exactly 1 spawn for 1 free slot, saw $(spawns) — over-blocking or a broken harness"
logged "path=pool-topup" && ok "T3: the spawn log line says WHICH path opened the session (path=pool-topup)" \
  || bad "T3: the spawn is not attributed to a path — 'which path opened this session' stays unanswerable"

# ── T5: spawn TIMED OUT (exit 124) → outcome unknown → NO blind retry ──────
echo "T5: 'gc session new' exits 124 (killed at the budget; the session may already exist) — exactly ONE attempt, no blind retry"
reset; sessions_json "wa-worker:active" > "$WORK/sl.json"; echo 124 > "$WORK/new.rc"
run_topup 2 wa-worker
[ "$(spawns)" = "1" ] && ok "T5: one attempt only after a timeout (a retry would open a SECOND session for the same bead)" \
  || bad "T5: $(spawns) spawn attempts after exit 124 — the blind retry doubles the session (landed 2-6s before the kill in the incident)"
logged "UNKNOWN" && ok "T5: the timeout is logged as an UNKNOWN outcome, not as 'failed'" \
  || bad "T5: a timeout is still reported as a plain failure"

# ── T6 (control): a genuine fast failure (exit 1) keeps its single retry ───
echo "T6 (control): 'gc session new' exits 1 — the ga-kmm6rb single retry is PRESERVED (2 attempts)"
reset; sessions_json "wa-worker:active" > "$WORK/sl.json"; echo 1 > "$WORK/new.rc"
run_topup 2 wa-worker
[ "$(spawns)" = "2" ] && ok "T6: exit 1 → 2 attempts (retry kept for real failures)" \
  || bad "T6: expected 2 attempts for a non-timeout failure, saw $(spawns) — the ga-kmm6rb retry regressed"

# ── T7: one unreadable probe short-circuits the REST of the sweep ──────────
echo "T7: after ONE unreadable probe, the next pool's top-up must not pay another probe (a hung list × N gates would stall the sweep)"
reset; : > "$WORK/sl.fail"
run_topup 2 wa-worker ps-worker
if [ "$(list_calls)" = "1" ]; then
  ok "T7: exactly 1 'session list' probe across both pools (sticky per-sweep flag)"
else
  bad "T7: $(list_calls) 'session list' probes across two pools — each gate pays its own full timeout when the list is hung"
fi
[ "$(spawns)" = "0" ] && ok "T7: and nothing was spawned for either pool" || bad "T7: $(spawns) spawn(s) with an unreadable list"

# ── T8: no `timeout` binary at all (127) — unreadable, and the script must SURVIVE ─────────────
# The old code carried a comment about a bash 5.3 quirk: a bare `x=$(missing-cmd | jq …)` can abort the
# whole script. The new probe only assigns inside `if !`, so a missing `timeout` must read as UNREADABLE
# (0 spawns, announced) and top-up must return normally.
echo "T8: 'timeout' is not on PATH (127) — top-up reads it as UNREADABLE and RETURNS (no abort)"
if [ -n "$(PATH="/usr/bin:/bin" command -v timeout 2>/dev/null)" ]; then
  echo "  (skip T8: a 'timeout' binary exists in /usr/bin:/bin here, cannot simulate its absence)"
else
  mkdir -p "$WORK/bin-nt"; ln -sf "$WORK/bin/gc" "$WORK/bin-nt/gc"
  reset; sessions_json "wa-worker:active" > "$WORK/sl.json"
  TOPUP_PATH="$WORK/bin-nt:/usr/bin:/bin" run_topup 2 wa-worker
  logged "END (top-up returned normally" && ok "T8: top-up RETURNED normally with no 'timeout' binary (no abort)" \
    || bad "T8: the script died inside top-up when 'timeout' was missing (the bash 5.3 bare-assignment abort)"
  logged "cannot read" && [ "$(spawns)" = "0" ] && ok "T8: a missing 'timeout' reads as UNREADABLE — announced, 0 spawns" \
    || bad "T8: a missing 'timeout' was read as a live count (log: $(tr '\t\n' ' |' < "$WORK/log.txt" 2>/dev/null | cut -c1-200))"
fi

# ── Helper unit tests (need the new helper; skipped when run against a pre-fix copy) ──
echo "Helper: _pilot_live_session_count"
if [ "$HAVE_HELPER" = "1" ]; then
  run_helper() { # <sl.json-writer-fn-args…> ; prints "rc=<rc> n=<_PLSC_N>"
    (
      PATH="$WORK/bin:$PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK; GC_CITY="test-city"
      unset GC_VARIABLE_SESSION_COUNT_OVERRIDE
      eval "$FUNCS"
      "$@"; _rc=$?
      printf 'rc=%s n=%s' "$_rc" "${_PLSC_N:-}"
    )
  }
  reset; sessions_json "wa-worker:active" "wa-worker:start-pending" "wa-worker:asleep" "wa-worker:closed" "ps-worker:active" "gate-reviewer:active" "gastown.dog:active" > "$WORK/sl.json"
  [ "$(run_helper _pilot_live_session_count wa-worker)" = "rc=0 n=2" ] \
    && ok "H1: wa-worker live = active + start-pending only (asleep/closed/other templates excluded)" \
    || bad "H1: wrong wa-worker count: $(run_helper _pilot_live_session_count wa-worker)"
  [ "$(run_helper _pilot_variable_session_count)" = "rc=0 n=4" ] \
    && ok "H2: global variable-session count = wa-worker+ps-worker+gate-reviewer live (dogs excluded)" \
    || bad "H2: wrong global count: $(run_helper _pilot_variable_session_count)"
  reset; echo '{"sessions":[]}' > "$WORK/sl.json"
  [ "$(run_helper _pilot_live_session_count wa-worker)" = "rc=0 n=0" ] \
    && ok "H3: a genuinely EMPTY pool is a KNOWN zero (rc=0), distinct from unreadable (rc=1)" \
    || bad "H3: an empty pool did not read as a known 0: $(run_helper _pilot_live_session_count wa-worker)"
  reset; : > "$WORK/sl.fail"
  [ "$(run_helper _pilot_live_session_count wa-worker)" = "rc=1 n=" ] \
    && ok "H4: a failing probe → rc=1 with NO count" || bad "H4: failing probe leaked a count: $(run_helper _pilot_live_session_count wa-worker)"
  # The measured failure mode itself: a list slower than the budget is UNREADABLE, not 0.
  REAL_TIMEOUT="$(PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" command -v timeout 2>/dev/null || true)"
  if [ -n "$REAL_TIMEOUT" ]; then
    reset; sessions_json "wa-worker:active" "wa-worker:active" > "$WORK/sl.json"; echo 4 > "$WORK/sl.sleep"
    _slow=$(
      PATH="$WORK/bin-real:$WORK/bin:$PATH"
      mkdir -p "$WORK/bin-real"; ln -sf "$REAL_TIMEOUT" "$WORK/bin-real/timeout"
      SELFTEST_WORK="$WORK"; export SELFTEST_WORK; GC_CITY="test-city"; PILOT_SESSION_LIST_TIMEOUT_SECS=1
      eval "$FUNCS"; _pilot_live_session_count wa-worker; _rc=$?; printf 'rc=%s n=%s' "$_rc" "${_PLSC_N:-}"
    )
    [ "$_slow" = "rc=1 n=" ] \
      && ok "H5: a list slower than the budget (2 live sessions, 4s vs 1s) is UNREADABLE — was: silently '0 live'" \
      || bad "H5: a slow list was read as a count: $_slow"
  else
    echo "  (skip H5: no real 'timeout' binary on this machine)"
  fi
else
  echo "  (skipped — pre-fix dispatcher has no _pilot_live_session_count; that absence is itself the RED)"
  bad "H0: _pilot_live_session_count is not defined — the fail-closed helper is missing"
fi

# ── Drift guards: the four fail-open probes must not come back into a spawn gate ──
echo "Drift guards"
_old_wa=$(grep -c 'select(\.template=="wa-worker" and (\.state=="active" or \.state=="creating"))' "$DISPATCHER" 2>/dev/null); _old_wa="${_old_wa:-0}"
_old_ps=$(grep -c 'select(\.template=="ps-worker" and (\.state=="active" or \.state=="creating"))' "$DISPATCHER" 2>/dev/null); _old_ps="${_old_ps:-0}"
_old_t=$(grep -c 'select(\.template==\$t and (\.state=="active" or \.state=="creating"))' "$DISPATCHER" 2>/dev/null); _old_t="${_old_t:-0}"
if [ "$((_old_wa + _old_ps + _old_t))" = "0" ]; then
  ok "D1: no inline 'active or creating' count probe is left in the dispatcher (one shared definition of 'live')"
else
  bad "D1: $((_old_wa + _old_ps + _old_t)) inline fail-open count probe(s) remain (wa=$_old_wa ps=$_old_ps generic=$_old_t) — a spawn gate can still read a timeout as '0 live'"
fi
_users=$(grep -c '_pilot_live_session_count' "$DISPATCHER" 2>/dev/null); _users="${_users:-0}"
[ "$_users" -ge 5 ] && ok "D2: the shared probe is wired into the gates (>=5 references: def + top-up + 2 dispatch arms + pre-claim)" \
  || bad "D2: only $_users reference(s) to _pilot_live_session_count — the gates are not all on the shared probe"

echo ""
echo "pilot-dispatcher.pool-cap-fail-closed.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
