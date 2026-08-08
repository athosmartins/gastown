#!/usr/bin/env bash
# adhoc-session-reaper.selftest.sh — hermetic test of the reaper's decision logic.
# Stubs `gc` and `tmux` so ZERO real calls hit the live city. Each scenario crafts a
# session-list JSON and asserts which sessions get reaped vs kept by reading the
# jsonl log the reaper writes.
set -uo pipefail

REAPER="${ADHOC_REAPER_PATH:-$(cd "$(dirname "$0")" && pwd)/adhoc-session-reaper.sh}"
[ -f "$REAPER" ] || REAPER="/tmp/adhoc-session-reaper.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# ---- unit tests on the pure helpers (sourced, GC_BIN never invoked) -------------
# Source with a guard: the script runs a sweep on source, but with an empty stub it
# just no-ops. We instead test the helpers by extracting them via a subshell that
# defines a fake list. Simpler: source after pointing GC_BIN at a stub that prints
# nothing, then call the pure functions directly.
export ADHOC_REAPER_GC=/tmp/_ahr_gc_stub_unit
cat > /tmp/_ahr_gc_stub_unit <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x /tmp/_ahr_gc_stub_unit
# shellcheck disable=SC1090
ADHOC_REAPER_SOURCE_ONLY=1 ADHOC_REAPER_ENABLED=0 source "$REAPER" >/dev/null 2>&1

# is_adhoc_eligible
is_adhoc_eligible "auto-refiner-adhoc-abc123"            && ok "eligible: auto-refiner-adhoc"        || nope "auto-refiner-adhoc should be eligible"
is_adhoc_eligible "gastown.dog-adhoc-deadbeef"           && ok "eligible: gastown.dog-adhoc"          || nope "dog-adhoc should be eligible"
is_adhoc_eligible "gate-reviewer-adhoc-99"               && ok "eligible: gate-reviewer-adhoc"        || nope "gate-reviewer-adhoc should be eligible"
is_adhoc_eligible "refino-gate-reviewer-adhoc-77"        && ok "eligible: refino-gate-reviewer-adhoc" || nope "refino-gate-reviewer-adhoc should be eligible"
is_adhoc_eligible "mila-wa-gawispjirrik"                 && nope "mila crew must NOT be eligible"     || ok "excluded: named crew mila"
is_adhoc_eligible "gastown__mayor"                       && nope "mayor must NOT be eligible"         || ok "excluded: gastown__mayor"
is_adhoc_eligible "control-dispatcher"                   && nope "control-dispatcher must NOT be eligible" || ok "excluded: control-dispatcher"
is_adhoc_eligible "auto-refiner-permanent"               && nope "non-adhoc auto-refiner must NOT be eligible" || ok "excluded: non-adhoc (no -adhoc-)"

# session_state_is_drained
[ "$(session_state_is_drained asleep)" = "1" ]   && ok "drained: asleep=1"   || nope "asleep should be drained"
[ "$(session_state_is_drained draining)" = "1" ] && ok "drained: draining=1" || nope "draining should be drained"
[ "$(session_state_is_drained active)" = "0" ]   && ok "drained: active=0"   || nope "active must NOT be in drained-family"

# session_state_is_idle_candidate (active is now a reap-candidate, gated on idle floor)
[ "$(session_state_is_idle_candidate active)" = "1" ]  && ok "idle_cand: active=1"  || nope "active should be an idle candidate"
[ "$(session_state_is_idle_candidate idle)" = "1" ]    && ok "idle_cand: idle=1"    || nope "idle should be an idle candidate"
[ "$(session_state_is_idle_candidate waiting)" = "1" ] && ok "idle_cand: waiting=1" || nope "waiting should be an idle candidate"
[ "$(session_state_is_idle_candidate asleep)" = "0" ]  && ok "idle_cand: asleep=0"  || nope "asleep is drained-family, not idle candidate"
[ "$(session_state_is_idle_candidate running)" = "0" ] && ok "idle_cand: running=0" || nope "running must NOT be a reap candidate"

# idle_minutes — zero/sentinel time and garbage → unknown (""), real old ts → large int
[ -z "$(idle_minutes '0001-01-01T00:00:00Z')" ]      && ok "idle_min: zero-time → unknown" || nope "zero time should be unknown"
[ -z "$(idle_minutes '')" ]                          && ok "idle_min: empty → unknown"     || nope "empty should be unknown"
[ -z "$(idle_minutes 'not-a-date')" ]                && ok "idle_min: garbage → unknown"   || nope "garbage should be unknown"
_im_old="$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
[ "$(idle_minutes "$_im_old")" -ge 100 ] 2>/dev/null && ok "idle_min: 2h-old >=100" || nope "2h-old should be >=100 idle min"

# session_peek_reports_dead
[ "$(session_peek_reports_dead 'gc session peek: session not found: ga-x')" = "1" ] && ok "peek_dead: not-found=1" || nope "not-found should be dead"
[ "$(session_peek_reports_dead 'real scrollback here')" = "0" ] && ok "peek_dead: scrollback=0" || nope "scrollback should be alive"

# ---- integration scenarios via a programmable gc stub ---------------------------
# The stub reads $AHR_FIXTURE (a JSON sessions doc) for `session list --json`,
# returns $AHR_PEEK_MODE for `session peek`, records `session close` calls to
# $AHR_CLOSE_LOG, and never makes a real call.
STUBDIR=$(mktemp -d)
GC_STUB="$STUBDIR/gc"
cat > "$GC_STUB" <<'STUB'
#!/usr/bin/env bash
# args: --city <path> session <sub> ...
sub=""
for a in "$@"; do case "$a" in list|peek|close) sub="$a"; break ;; esac; done
case "$sub" in
  list) cat "$AHR_FIXTURE" ;;
  peek)
    # $AHR_PEEK_MODE: dead → stderr not-found; alive → stdout scrollback; silent → nothing
    case "${AHR_PEEK_MODE:-dead}" in
      dead)   echo "gc session peek: session not found: stub" >&2; exit 1 ;;
      alive)  echo "live scrollback line" ; exit 0 ;;
      silent) exit 0 ;;
    esac ;;
  close)
    # the id is the last arg
    for a in "$@"; do :; done
    echo "$a" >> "$AHR_CLOSE_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$GC_STUB"
export ADHOC_REAPER_GC="$GC_STUB"
export AHR_CLOSE_LOG="$STUBDIR/closed.log"
export AHR_FIXTURE AHR_PEEK_MODE

# ga-879wu gate-feedback: list_sessions() calls gc-session-list-cached.sh directly
# (not through $GC_BIN — see that var's own docstring in the production script for
# why production must keep hitting the real caching shim), so the "list) cat
# $AHR_FIXTURE" branch in $GC_STUB above was DEAD — every scenario below actually
# swept this session's REAL, LIVE city data, not the fixture it looks like it's
# using. Confirmed via a real run before this fix: 58 live sessions surfaced
# instead of the 1-session fixture, sending 4 unrelated scenarios' assertions
# into a false FAIL. This second stub, contract-compatible with the real script
# (stdout = {"sessions":[...]}, same as `gc session list --json`), closes that
# gap the same way GC_STUB already does for peek/close.
SESSION_LIST_STUB="$STUBDIR/gc-session-list-cached.sh"
cat > "$SESSION_LIST_STUB" <<'STUB'
#!/usr/bin/env bash
cat "$AHR_FIXTURE"
STUB
chmod +x "$SESSION_LIST_STUB"
export ADHOC_REAPER_SESSION_LIST_SCRIPT="$SESSION_LIST_STUB"

# fresh created_at helpers (RFC3339 Z)
old_ts()   { python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))'; }
fresh_ts() { python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))'; }

run_reaper() { # $1=enabled $2=peekmode ; uses exported $AHR_FIXTURE
  : > "$AHR_CLOSE_LOG"
  # The reaper writes its jsonl to $CITY/.gc/logs/adhoc-session-reaper.jsonl (a log
  # only — harmless). The observable we assert on is the close-log the gc stub fills.
  AHR_PEEK_MODE="$2" ADHOC_REAPER_ENABLED="$1" ADHOC_REAPER_MIN_AGE_MIN=30 ADHOC_REAPER_IDLE_MIN=20 \
    bash "$REAPER" >/dev/null 2>&1
}

# last_active helpers: idle_ts = stale (well past IDLE_MIN=20 → reapable if active),
# recent_ts = just touched (< IDLE_MIN → still working → kept). zero_ts = sentinel.
idle_ts()   { old_ts; }    # 2h ago
recent_ts() { python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))'; }
zero_ts()   { echo "0001-01-01T00:00:00Z"; }

closed_count() {
  if [ -f "$AHR_CLOSE_LOG" ]; then
    awk 'NF{n++} END{print n+0}' "$AHR_CLOSE_LOG" 2>/dev/null
  else
    echo 0
  fi
}
closed_has()   { grep -q "$1" "$AHR_CLOSE_LOG" 2>/dev/null; }

# (a) drained adhoc past MIN_AGE, peek confirms gone → REAPED
AHR_FIXTURE="$STUBDIR/a.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-a","name":"auto-refiner-adhoc-aaa","state":"asleep","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"auto-refiner: ga-sf661 (attempt 1)"}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-a"; then ok "(a) drained+old+peek-dead → reaped"; else nope "(a) expected reap of ga-wisp-a, got close-count=$(closed_count)"; fi

# (b) fresh adhoc (<MIN_AGE) → KEPT
AHR_FIXTURE="$STUBDIR/b.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-b","name":"auto-refiner-adhoc-bbb","state":"asleep","closed":false,"created_at":"$(fresh_ts)","last_active":"$(zero_ts)","title":"auto-refiner: ga-x (attempt 1)"}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "0" ]; then ok "(b) fresh adhoc (<MIN_AGE) → kept"; else nope "(b) fresh session was reaped (count=$(closed_count))"; fi

# (c) ACTIVE adhoc still WORKING (recent last_active) → KEPT even though old created_at
AHR_FIXTURE="$STUBDIR/c.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-c","name":"gate-reviewer-adhoc-ccc","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(recent_ts)","title":"reviewer: ga-y (round 1)"}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "0" ]; then ok "(c) active+recently-active → kept (working reviewer protected)"; else nope "(c) WORKING active session was reaped (count=$(closed_count)) — CRITICAL"; fi

# (c2) old+drained but peek shows it is ALIVE (slow reviewer) → KEPT
AHR_FIXTURE="$STUBDIR/c2.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-c2","name":"refino-gate-reviewer-adhoc-c2","state":"asleep","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"refino-reviewer: ga-z (round 1)"}]}
EOF
run_reaper 1 alive
if [ "$(closed_count)" = "0" ]; then ok "(c2) old+drained but peek-alive → kept (slow reviewer protected)"; else nope "(c2) peek-alive session was reaped (count=$(closed_count))"; fi

# (c3) ga-879wu: old+drained but peek is INCONCLUSIVE (a transient gc/Dolt/tmux
#      glitch — AHR_PEEK_MODE=silent: exit 0, no stdout, no stderr, so neither
#      session_peek_reports_dead nor the peek_out-non-empty check fires) → KEPT.
#      This is the exact case the block's own comment names ("Inconclusive/glitch
#      → treat as alive → keep") but the code did not implement — a real, asleep,
#      >30min-old reviewer/dog session (this reaper's own eligible-name classes
#      ARE reviewer/dog sessions) hit by a momentary peek glitch used to be closed
#      with no recovery path. AHR_PEEK_MODE=silent existed in the stub before this
#      fix but was never exercised by any scenario — confirmed via `grep -c
#      "run_reaper .* silent"` = 0 prior to this test.
AHR_FIXTURE="$STUBDIR/c3.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-c3","name":"gate-reviewer-adhoc-c3","state":"asleep","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"reviewer: ga-w (round 1)"}]}
EOF
run_reaper 1 silent
if [ "$(closed_count)" = "0" ]; then ok "(c3) old+drained but peek-inconclusive/silent → kept (glitch must never reap — ga-879wu)"; else nope "(c3) CRITICAL: peek-inconclusive session was reaped (count=$(closed_count)) — the ga-879wu regression"; fi

# (d) NAMED crew (mila) old + asleep → NEVER eligible
AHR_FIXTURE="$STUBDIR/d.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-d","name":"mila-wa-gawispjirrik","state":"asleep","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"crew mila"}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "0" ]; then ok "(d) named crew mila → never eligible"; else nope "(d) NAMED CREW WAS REAPED (count=$(closed_count)) — CRITICAL"; fi

# (d2) NAMED crew (mila) ACTIVE + old + idle-stale → STILL never eligible (idle path must
#      not bypass the named-crew exclude). Guards the new active-idle reap path.
AHR_FIXTURE="$STUBDIR/d2.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-d2","name":"mila-wa-idlecrew","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(idle_ts)","title":"crew mila idle"}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "0" ]; then ok "(d2) named crew active+idle → STILL never eligible"; else nope "(d2) IDLE NAMED CREW WAS REAPED (count=$(closed_count)) — CRITICAL"; fi

# (e) kill switch OFF → census only, no closes even for a reapable one
AHR_FIXTURE="$STUBDIR/e.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-e","name":"gastown.dog-adhoc-eee","state":"asleep","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"gate repair: ga-q"}]}
EOF
run_reaper 0 dead
if [ "$(closed_count)" = "0" ]; then ok "(e) ADHOC_REAPER_ENABLED=0 → census only, no close"; else nope "(e) reaped with kill switch OFF (count=$(closed_count))"; fi

# (g) THE ga-tads0 BUG: ACTIVE adhoc that FINISHED its turn — old + idle past IDLE_MIN.
#     Old reaper kept it forever (reason:"active"); fixed reaper reaps it.
AHR_FIXTURE="$STUBDIR/g.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-g","name":"refino-gate-reviewer-adhoc-ggg","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(idle_ts)","title":"refino-reviewer: ga-7rvi5 (round 1)"}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-g"; then ok "(g) active+old+idle-stale → REAPED (the ga-tads0 fix)"; else nope "(g) the leaked active-idle session was NOT reaped (count=$(closed_count))"; fi

# (g2) same as (g) but peek returns scrollback (alive transcript). The idle floor already
#      proved the turn ended, so leftover scrollback must NOT veto → still REAPED.
AHR_FIXTURE="$STUBDIR/g2.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-g2","name":"gastown.dog-adhoc-ggg2","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(idle_ts)","title":"gate orphan repair: ga-x"}]}
EOF
run_reaper 1 alive
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-g2"; then ok "(g2) active+idle-stale + peek-scrollback → REAPED (scrollback is stale transcript, not a veto)"; else nope "(g2) idle-active with scrollback was NOT reaped (count=$(closed_count))"; fi

# (h) ACTIVE adhoc, old created_at, but idle UNKNOWN (zero/sentinel last_active) → KEPT
#     (fail SAFE: absence of a recent-activity signal is treated as "might be live").
AHR_FIXTURE="$STUBDIR/h.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-h","name":"gate-reviewer-adhoc-hhh","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"reviewer ga-h"}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "0" ]; then ok "(h) active+old+idle-unknown → kept (fail safe)"; else nope "(h) idle-unknown active session was reaped (count=$(closed_count)) — unsafe"; fi

# (f) mixed batch: reaps eligible+old+drained AND eligible+old+idle-stale-active; leaves
#     crew + recently-active + fresh + idle-unknown.
AHR_FIXTURE="$STUBDIR/f.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[
 {"id":"ga-wisp-f1","name":"auto-refiner-adhoc-f1","state":"asleep","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"auto-refiner: ga-1"},
 {"id":"ga-wisp-f2","name":"gastown.dog-adhoc-f2","state":"draining","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"dog: ga-2"},
 {"id":"ga-wisp-f3","name":"oracle-wa-x","state":"asleep","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"crew oracle"},
 {"id":"ga-wisp-f4","name":"gate-reviewer-adhoc-f4","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(recent_ts)","title":"reviewer ga-4"},
 {"id":"ga-wisp-f5","name":"auto-refiner-adhoc-f5","state":"asleep","closed":false,"created_at":"$(fresh_ts)","last_active":"$(zero_ts)","title":"auto-refiner ga-5"},
 {"id":"ga-wisp-f6","name":"refino-gate-reviewer-adhoc-f6","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(idle_ts)","title":"refino-reviewer ga-6 (finished)"}
]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "3" ] && closed_has "ga-wisp-f1" && closed_has "ga-wisp-f2" && closed_has "ga-wisp-f6" \
   && ! closed_has "ga-wisp-f3" && ! closed_has "ga-wisp-f4" && ! closed_has "ga-wisp-f5"; then
  ok "(f) mixed batch → reaped f1(asleep)+f2(draining)+f6(active-idle), kept oracle/working-active/fresh"
else
  nope "(f) mixed batch wrong: closed=[$(tr '\n' ' ' < "$AHR_CLOSE_LOG")] count=$(closed_count)"
fi

rm -rf "$STUBDIR" /tmp/_ahr_gc_stub_unit 2>/dev/null
echo
echo "selftest: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
