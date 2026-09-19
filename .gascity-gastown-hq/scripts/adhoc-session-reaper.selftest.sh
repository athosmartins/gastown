#!/usr/bin/env bash
# adhoc-session-reaper.selftest.sh — hermetic test of the reaper's decision logic.
# Stubs `gc`, `tmux` and (worker-class scenarios) `bd` so ZERO real calls hit the live city. Each scenario crafts a
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

# ga-jn82py: pool WORKER sessions are adhoc too (each Pilot dispatch spawns one that
# then sleeps forever — 37 leaked by 2026-09-19). Persistent numbered workers
# (wa-worker-1) never carry "-adhoc-" and must stay ineligible.
is_adhoc_eligible "wa-worker-adhoc-6bf6646e56"           && ok "eligible: wa-worker-adhoc"            || nope "wa-worker-adhoc should be eligible (ga-jn82py)"
is_adhoc_eligible "ps-worker-adhoc-1a2b3c4d5e"           && ok "eligible: ps-worker-adhoc"            || nope "ps-worker-adhoc should be eligible (ga-jn82py)"
is_adhoc_eligible "wa-worker-1"                          && nope "persistent wa-worker-1 must NOT be eligible" || ok "excluded: persistent wa-worker-1 (no -adhoc-)"
is_adhoc_eligible "ps-worker-2"                          && nope "persistent ps-worker-2 must NOT be eligible" || ok "excluded: persistent ps-worker-2 (no -adhoc-)"
is_adhoc_eligible "wa-worker-adhoc-mayor"                && nope "named-exclude must still beat the worker prefix" || ok "excluded: named-exclude beats worker prefix"

# is_worker_adhoc — the class that gets the extra assigned-bead lock (worker prefixes ONLY)
is_worker_adhoc "wa-worker-adhoc-x"                      && ok "worker class: wa-worker-adhoc"        || nope "wa-worker-adhoc is a worker-class session"
is_worker_adhoc "ps-worker-adhoc-x"                      && ok "worker class: ps-worker-adhoc"        || nope "ps-worker-adhoc is a worker-class session"
is_worker_adhoc "gate-reviewer-adhoc-x"                  && nope "reviewer is NOT worker class"       || ok "not worker class: gate-reviewer-adhoc"
is_worker_adhoc "gastown.dog-adhoc-x"                    && nope "dog-adhoc is NOT worker class"      || ok "not worker class: gastown.dog-adhoc"
is_worker_adhoc "wa-worker-1"                            && nope "wa-worker-1 is NOT worker class"    || ok "not worker class: persistent wa-worker-1"

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

# title_shows_no_task (ga-dd2h0) — empirically confirmed against ga-qfewi's actual
# record (the session that triggered this bead): a self-serve session's title starts
# out EQUAL to its own session name and is only overwritten once it claims a task.
# Empty title is deliberately NOT treated as confirmed-no-task (unconfirmed shape,
# not the empirically-observed one) — must fail safe to 0, same as every other
# "don't know" in this script.
[ "$(title_shows_no_task "gate-reviewer-adhoc-x" "gate-reviewer-adhoc-x")" = "1" ] && ok "no_task: title==name → 1" || nope "title==name should mean no task ever claimed"
[ "$(title_shows_no_task "" "gate-reviewer-adhoc-x")" = "0" ] && ok "no_task: empty title → 0 (unconfirmed, fail safe)" || nope "empty title is NOT confirmed no-task — must fail safe, not auto-reap"
[ "$(title_shows_no_task "gate-reviewer-1: crew/oracle/wa-54egz" "gate-reviewer-adhoc-x")" = "0" ] && ok "no_task: real task title → 0" || nope "task-bearing title should not read as no_task"

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
# AHR_LIST_MODE=fail (ga-dd2h0 gate-feedback round 1) makes the stub itself exit
# non-zero, exercising list_sessions_raw()'s failure path — the real
# gc-session-list-cached.sh breaking or Dolt being down.
SESSION_LIST_STUB="$STUBDIR/gc-session-list-cached.sh"
cat > "$SESSION_LIST_STUB" <<'STUB'
#!/usr/bin/env bash
case "${AHR_LIST_MODE:-ok}" in
  fail) exit 7 ;;
  *) cat "$AHR_FIXTURE" ;;
esac
STUB
chmod +x "$SESSION_LIST_STUB"
export ADHOC_REAPER_SESSION_LIST_SCRIPT="$SESSION_LIST_STUB"
export AHR_LIST_MODE

# fresh created_at helpers (RFC3339 Z)
old_ts()   { python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))'; }
fresh_ts() { python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))'; }

# AHR_LOG (ga-dd2h0 gate-feedback round 1): previously the reaper's jsonl always went
# to the real production path ($CITY/.gc/logs/...) even under test — "harmless" since
# no scenario asserted on it, but not hermetic, and it made the log unusable as a test
# observable (a concurrent real sweep could interleave). Routing it through the
# already-existing ADHOC_REAPER_LOG override into the stub dir fixes both: isolated
# per-run (truncated before each call below) and safe to assert on.
AHR_LOG="$STUBDIR/reaper.jsonl"

run_reaper() { # $1=enabled $2=peekmode ; uses exported $AHR_FIXTURE
  : > "$AHR_CLOSE_LOG"
  : > "$AHR_LOG"
  AHR_PEEK_MODE="$2" ADHOC_REAPER_ENABLED="$1" ADHOC_REAPER_MIN_AGE_MIN=30 ADHOC_REAPER_IDLE_MIN=20 \
    ADHOC_REAPER_LOG="$AHR_LOG" \
    bash "$REAPER" >/dev/null 2>&1
}

# log_last_reason → the "reason" field of the last jsonl line this run wrote (empty
# if none). Plain grep, no jq dependency — reason values here are always bare
# identifiers with no characters that need escaping.
log_last_reason() {
  tail -1 "$AHR_LOG" 2>/dev/null | grep -oE '"reason":"[^"]*"' | head -1 | sed -E 's/"reason":"([^"]*)"/\1/'
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
{"sessions":[{"id":"ga-wisp-a","name":"auto-refiner-adhoc-aaa","state":"asleep","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"auto-refiner: ga-sf661 (attempt 1)","attached":false}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-a"; then ok "(a) drained+old+peek-dead → reaped"; else nope "(a) expected reap of ga-wisp-a, got close-count=$(closed_count)"; fi

# (b) fresh adhoc (<MIN_AGE) → KEPT
AHR_FIXTURE="$STUBDIR/b.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-b","name":"auto-refiner-adhoc-bbb","state":"asleep","closed":false,"created_at":"$(fresh_ts)","last_active":"$(zero_ts)","title":"auto-refiner: ga-x (attempt 1)","attached":false}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "0" ]; then ok "(b) fresh adhoc (<MIN_AGE) → kept"; else nope "(b) fresh session was reaped (count=$(closed_count))"; fi

# (c) ACTIVE adhoc still WORKING (recent last_active) → KEPT even though old created_at
AHR_FIXTURE="$STUBDIR/c.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-c","name":"gate-reviewer-adhoc-ccc","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(recent_ts)","title":"reviewer: ga-y (round 1)","attached":false}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "0" ]; then ok "(c) active+recently-active → kept (working reviewer protected)"; else nope "(c) WORKING active session was reaped (count=$(closed_count)) — CRITICAL"; fi

# (c2) old+drained but peek shows it is ALIVE (slow reviewer) → KEPT
AHR_FIXTURE="$STUBDIR/c2.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-c2","name":"refino-gate-reviewer-adhoc-c2","state":"asleep","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"refino-reviewer: ga-z (round 1)","attached":false}]}
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
{"sessions":[{"id":"ga-wisp-c3","name":"gate-reviewer-adhoc-c3","state":"asleep","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"reviewer: ga-w (round 1)","attached":false}]}
EOF
run_reaper 1 silent
if [ "$(closed_count)" = "0" ]; then ok "(c3) old+drained but peek-inconclusive/silent → kept (glitch must never reap — ga-879wu)"; else nope "(c3) CRITICAL: peek-inconclusive session was reaped (count=$(closed_count)) — the ga-879wu regression"; fi

# (d) NAMED crew (mila) old + asleep → NEVER eligible
AHR_FIXTURE="$STUBDIR/d.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-d","name":"mila-wa-gawispjirrik","state":"asleep","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"crew mila","attached":false}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "0" ]; then ok "(d) named crew mila → never eligible"; else nope "(d) NAMED CREW WAS REAPED (count=$(closed_count)) — CRITICAL"; fi

# (d2) NAMED crew (mila) ACTIVE + old + idle-stale → STILL never eligible (idle path must
#      not bypass the named-crew exclude). Guards the new active-idle reap path.
AHR_FIXTURE="$STUBDIR/d2.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-d2","name":"mila-wa-idlecrew","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(idle_ts)","title":"crew mila idle","attached":false}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "0" ]; then ok "(d2) named crew active+idle → STILL never eligible"; else nope "(d2) IDLE NAMED CREW WAS REAPED (count=$(closed_count)) — CRITICAL"; fi

# (e) kill switch OFF → census only, no closes even for a reapable one
AHR_FIXTURE="$STUBDIR/e.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-e","name":"gastown.dog-adhoc-eee","state":"asleep","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"gate repair: ga-q","attached":false}]}
EOF
run_reaper 0 dead
if [ "$(closed_count)" = "0" ]; then ok "(e) ADHOC_REAPER_ENABLED=0 → census only, no close"; else nope "(e) reaped with kill switch OFF (count=$(closed_count))"; fi

# (g) THE ga-tads0 BUG: ACTIVE adhoc that FINISHED its turn — old + idle past IDLE_MIN.
#     Old reaper kept it forever (reason:"active"); fixed reaper reaps it.
AHR_FIXTURE="$STUBDIR/g.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-g","name":"refino-gate-reviewer-adhoc-ggg","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(idle_ts)","title":"refino-reviewer: ga-7rvi5 (round 1)","attached":false}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-g"; then ok "(g) active+old+idle-stale → REAPED (the ga-tads0 fix)"; else nope "(g) the leaked active-idle session was NOT reaped (count=$(closed_count))"; fi

# (g2) same as (g) but peek returns scrollback (alive transcript). The idle floor already
#      proved the turn ended, so leftover scrollback must NOT veto → still REAPED.
AHR_FIXTURE="$STUBDIR/g2.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-g2","name":"gastown.dog-adhoc-ggg2","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(idle_ts)","title":"gate orphan repair: ga-x","attached":false}]}
EOF
run_reaper 1 alive
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-g2"; then ok "(g2) active+idle-stale + peek-scrollback → REAPED (scrollback is stale transcript, not a veto)"; else nope "(g2) idle-active with scrollback was NOT reaped (count=$(closed_count))"; fi

# (h) ACTIVE adhoc, old created_at, but idle UNKNOWN (zero/sentinel last_active) → KEPT
#     (fail SAFE: absence of a recent-activity signal is treated as "might be live").
AHR_FIXTURE="$STUBDIR/h.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-h","name":"gate-reviewer-adhoc-hhh","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"reviewer ga-h","attached":false}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "0" ]; then ok "(h) active+old+idle-unknown → kept (fail safe)"; else nope "(h) idle-unknown active session was reaped (count=$(closed_count)) — unsafe"; fi

# (i) THE ga-dd2h0 BUG: self-serve session that NEVER claimed a task (title==name) —
#     old created_at, but last_active is RECENT because its own poll-for-work loop
#     keeps refreshing it. The idle floor above can NEVER fire for this session (idle
#     stays < IDLE_MIN forever), which is exactly why it leaked (observed live:
#     40-58min alive, 0 beads ever assigned) → REAPED on age alone once title shows no
#     task was ever claimed.
AHR_FIXTURE="$STUBDIR/i.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-i","name":"gate-reviewer-adhoc-iii","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(recent_ts)","title":"gate-reviewer-adhoc-iii","attached":false}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-i"; then ok "(i) ga-dd2h0: never-claimed poll-only session (title==name) + old + recently-active → REAPED"; else nope "(i) THE ga-dd2h0 BUG: poll-only never-claimed session was NOT reaped (count=$(closed_count))"; fi

# (i2) control, paired with (i): IDENTICAL timing (same old created_at, same recent
#      last_active) but title shows a REAL task → must stay KEPT. Isolates that the
#      reap trigger is title==name specifically, not just "old+active+recent" —
#      the control ACEITE #2 requires so this fix can't become the ga-dd2h0-class
#      collateral-damage bug it's meant to prevent.
AHR_FIXTURE="$STUBDIR/i2.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-i2","name":"gate-reviewer-adhoc-i2i2","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(recent_ts)","title":"gate-reviewer-1: crew/oracle/wa-54egz","attached":false}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "0" ]; then ok "(i2) control: same timing as (i) but title shows a real task → kept (ACEITE #2)"; else nope "(i2) CRITICAL: session WITH a real task was reaped (count=$(closed_count)) — collateral damage"; fi

# (i3) title==name but a non-"active" idle-candidate state (idle), to confirm the fix
#      isn't accidentally narrowed to state="active" only → REAPED.
AHR_FIXTURE="$STUBDIR/i3.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-i3","name":"auto-refiner-adhoc-i3i3","state":"idle","closed":false,"created_at":"$(old_ts)","last_active":"$(recent_ts)","title":"auto-refiner-adhoc-i3i3","attached":false}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-i3"; then ok "(i3) title==name + idle state (not active) + old + recently-active → REAPED"; else nope "(i3) never-claimed idle-state session was NOT reaped (count=$(closed_count))"; fi

# (i5) empty title is NOT the same evidence as title==name — only the latter is
#      empirically confirmed against a real no-task session (ga-qfewi). An empty
#      title must fail safe to the existing idle-based check (kept here, since
#      last_active is recent), not auto-reap on an unconfirmed shape.
AHR_FIXTURE="$STUBDIR/i5.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-i5","name":"auto-refiner-adhoc-i5i5","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(recent_ts)","title":"","attached":false}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "0" ]; then ok "(i5) empty title + old + recently-active → kept (unconfirmed shape must fail safe, not auto-reap)"; else nope "(i5) empty-title session was reaped on an unconfirmed signal (count=$(closed_count)) — third-state regression"; fi

# (i4) title==name but FRESH (<MIN_AGE) → still KEPT. The age floor is a separate,
#      independent gate (ACEITE #1 requires "idade > MIN_AGE") — this fix must not
#      bypass it.
AHR_FIXTURE="$STUBDIR/i4.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-i4","name":"gate-reviewer-adhoc-i4i4","state":"active","closed":false,"created_at":"$(fresh_ts)","last_active":"$(recent_ts)","title":"gate-reviewer-adhoc-i4i4","attached":false}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "0" ]; then ok "(i4) fresh (<MIN_AGE) + title==name → kept (age floor still applies)"; else nope "(i4) age floor was bypassed for a never-claimed session (count=$(closed_count))"; fi

# (f) mixed batch: reaps eligible+old+drained AND eligible+old+idle-stale-active; leaves
#     crew + recently-active + fresh + idle-unknown.
AHR_FIXTURE="$STUBDIR/f.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[
 {"id":"ga-wisp-f1","name":"auto-refiner-adhoc-f1","state":"asleep","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"auto-refiner: ga-1","attached":false},
 {"id":"ga-wisp-f2","name":"gastown.dog-adhoc-f2","state":"draining","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"dog: ga-2","attached":false},
 {"id":"ga-wisp-f3","name":"oracle-wa-x","state":"asleep","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"crew oracle","attached":false},
 {"id":"ga-wisp-f4","name":"gate-reviewer-adhoc-f4","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(recent_ts)","title":"reviewer ga-4","attached":false},
 {"id":"ga-wisp-f5","name":"auto-refiner-adhoc-f5","state":"asleep","closed":false,"created_at":"$(fresh_ts)","last_active":"$(zero_ts)","title":"auto-refiner ga-5","attached":false},
 {"id":"ga-wisp-f6","name":"refino-gate-reviewer-adhoc-f6","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(idle_ts)","title":"refino-reviewer ga-6 (finished)","attached":false},
 {"id":"ga-wisp-f7","name":"gate-reviewer-adhoc-f7","state":"active","closed":false,"created_at":"$(old_ts)","last_active":"$(recent_ts)","title":"gate-reviewer-adhoc-f7","attached":false}
]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "4" ] && closed_has "ga-wisp-f1" && closed_has "ga-wisp-f2" && closed_has "ga-wisp-f6" && closed_has "ga-wisp-f7" \
   && ! closed_has "ga-wisp-f3" && ! closed_has "ga-wisp-f4" && ! closed_has "ga-wisp-f5"; then
  ok "(f) mixed batch → reaped f1(asleep)+f2(draining)+f6(active-idle)+f7(never-claimed poll-only), kept oracle/working-active/fresh"
else
  nope "(f) mixed batch wrong: closed=[$(tr '\n' ' ' < "$AHR_CLOSE_LOG")] count=$(closed_count)"
fi

# ---- list_sessions() failure-mode distinction (ga-dd2h0 gate-feedback round 1) ----
# GATE-FEEDBACK blocking issue 1: a census FAILURE (list command errors, unparseable
# JSON, missing "sessions" key) used to log the exact same event as a genuinely empty
# session list ("noop"/"no_sessions_or_list_failed") — indistinguishable in the one
# artifact (this jsonl log) built to tell them apart. These four scenarios prove each
# path now writes its own reason, and (m) proves the true-empty case still isn't
# treated as an error.

# (j) the list command itself fails (non-zero exit — e.g. gc-session-list-cached.sh
#     broke, or Dolt is down) → distinct reason, zero closes.
AHR_FIXTURE="$STUBDIR/j.json"   # unread in fail mode, but keep run_reaper's contract happy
printf '{"sessions":[]}' > "$AHR_FIXTURE"
AHR_LIST_MODE=fail run_reaper 1 dead
AHR_LIST_MODE=ok
if [ "$(closed_count)" = "0" ] && [ "$(log_last_reason)" = "list_command_failed" ]; then
  ok "(j) list command fails → reason=list_command_failed (was indistinguishable from empty)"
else
  nope "(j) expected reason=list_command_failed, got '$(log_last_reason)' closed=$(closed_count)"
fi

# (k) the list command succeeds but emits unparseable JSON → distinct reason.
AHR_FIXTURE="$STUBDIR/k.json"
printf 'not valid json at all' > "$AHR_FIXTURE"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(log_last_reason)" = "unparseable_json" ]; then
  ok "(k) unparseable JSON → reason=unparseable_json"
else
  nope "(k) expected reason=unparseable_json, got '$(log_last_reason)' closed=$(closed_count)"
fi

# (l) valid JSON but no "sessions" key at all → distinct reason (schema drift in
#     gc-session-list-cached.sh's output must be visible, never silently read as zero).
AHR_FIXTURE="$STUBDIR/l.json"
printf '{"foo":"bar"}' > "$AHR_FIXTURE"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(log_last_reason)" = "missing_sessions_key" ]; then
  ok "(l) missing sessions key → reason=missing_sessions_key"
else
  nope "(l) expected reason=missing_sessions_key, got '$(log_last_reason)' closed=$(closed_count)"
fi

# (m) control: genuinely empty sessions list (parsed fine, nothing to do) must NOT
#     share a reason with any of (j)/(k)/(l) above — the one truly benign case.
AHR_FIXTURE="$STUBDIR/m.json"
printf '{"sessions":[]}' > "$AHR_FIXTURE"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(log_last_reason)" = "no_eligible_sessions" ]; then
  ok "(m) control: genuinely empty sessions → reason=no_eligible_sessions (distinct from j/k/l)"
else
  nope "(m) expected reason=no_eligible_sessions, got '$(log_last_reason)' closed=$(closed_count)"
fi

# ---- worker classes (ga-jn82py): wa-worker-adhoc-* / ps-worker-adhoc-* -------------
# Every Pilot dispatch spawns a fresh pool worker that sleeps forever once done; the
# reaper's prefix list did not cover them (37 leaked 2026-09-18/19, closed by hand).
# Unlike a reviewer, a worker does REAL long-running work, so adding the prefix alone
# would be dangerous — a worker mid-task can look idle. Beyond every gate above, the
# worker class therefore also gets: (1) the census `attached` veto (every class), and
# (2) an ASSIGNED-BEAD lock — no non-closed bead assigned to any identity of the
# session (id/name/alias/session_name) in ANY store of routes.jsonl — that is
# fail-CLOSED: only an explicit clean answer from every store that exists reaps.
# `bd` is stubbed (bd -C <store> query ...): nothing here touches the live city.
BD_STUB="$STUBDIR/bd"
cat > "$BD_STUB" <<'STUB'
#!/usr/bin/env bash
# stub of: bd -C <store> query "<expr>" --json --limit 0
store=""; expr=""
while [ $# -gt 0 ]; do
  case "$1" in -C) store="$2"; shift 2 ;; query) expr="$2"; shift 2 ;; *) shift ;; esac
done
name="$(basename "$store")"
printf '%s|%s\n' "$name" "$expr" >> "${AHR_BD_LOG:-/dev/null}"
# real `bd query` exits 1 AND prints a JSON *error object* on stdout when Dolt times out
# ("search count wisps: invalid connection", observed live 2026-09-19) — valid JSON that
# is not a result list. Mimic exactly that.
case ",${AHR_BD_FAIL:-}," in *",$name,"*) echo '{"error":"search count wisps: invalid connection","schema_version":1}'; exit 1 ;; esac
case ",${AHR_BD_NOTLIST:-}," in *",$name,"*) echo '{"foo":"bar"}'; exit 0 ;; esac
case ",${AHR_BD_JUNKLIST:-}," in *",$name,"*) echo '["not-a-bead"]'; exit 0 ;; esac
case ",${AHR_BD_HANG:-}," in *",$name,"*) exec sleep 30 ;; esac
fx="${AHR_BD_FIXTURE_DIR:-/nonexistent}/$name.json"
if [ -f "$fx" ]; then
  python3 - "$fx" "$expr" <<'PY'
import json, re, sys
beads = json.load(open(sys.argv[1]))
ids = set(re.findall(r"assignee=([^ )]+)", sys.argv[2]))
print(json.dumps([b for b in beads if b.get("assignee") in ids and b.get("status") != "closed"]))
PY
else
  echo '[]'
fi
STUB
chmod +x "$BD_STUB"
mkdir -p "$STUBDIR/stores/city/.beads" "$STUBDIR/stores/wa/.beads" "$STUBDIR/stores/ps/.beads" "$STUBDIR/stores/nobeads" "$STUBDIR/bdfx"
ROUTES_FIX="$STUBDIR/routes.jsonl"
printf '{"prefix":"ga","path":"%s"}\n{"prefix":"wa","path":"%s"}\n{"prefix":"ps","path":"%s"}\n' \
  "$STUBDIR/stores/city" "$STUBDIR/stores/wa" "$STUBDIR/stores/ps" > "$ROUTES_FIX"
ROUTES_NOBEADS="$STUBDIR/routes-nobeads.jsonl"
printf '{"prefix":"zz","path":"%s"}\n' "$STUBDIR/stores/nobeads" > "$ROUTES_NOBEADS"
AHR_BD_FAIL=""; AHR_BD_NOTLIST=""; AHR_BD_JUNKLIST=""; AHR_BD_HANG=""
export ADHOC_REAPER_BD="$BD_STUB" ADHOC_REAPER_ROUTES_FILE="$ROUTES_FIX" ADHOC_REAPER_BD_TIMEOUT_SEC=20
export AHR_BD_LOG="$STUBDIR/bd.log" AHR_BD_FIXTURE_DIR="$STUBDIR/bdfx" AHR_BD_FAIL AHR_BD_NOTLIST AHR_BD_JUNKLIST AHR_BD_HANG

bd_reset()  { rm -f "$STUBDIR"/bdfx/*.json; : > "$AHR_BD_LOG"; AHR_BD_FAIL=""; AHR_BD_NOTLIST=""; AHR_BD_JUNKLIST=""; AHR_BD_HANG=""; }
bd_calls()  { awk 'NF{n++} END{print n+0}' "$AHR_BD_LOG" 2>/dev/null; }
bdfx()      { printf '%s' "$2" > "$STUBDIR/bdfx/$1.json"; }     # $1=store basename $2=JSON list of beads
# mk_sess id name state created last_active title [attached true|false; omitted = key absent]
mk_sess() {
  local att=""
  case "${7:-}" in true|false) att=",\"attached\":$7" ;; esac
  printf '{"id":"%s","name":"%s","alias":"%s","session_name":"%s","state":"%s","closed":false,"created_at":"%s","last_active":"%s","title":"%s"%s}' \
    "$1" "$2" "$2" "$2" "$3" "$4" "$5" "$6" "$att"
}
put_sessions() { printf '{"sessions":[%s]}' "$1" > "$AHR_FIXTURE"; }
keep_field_for() { # $1=session name $2=field → that field of the session's last keep event ("" if none)
  grep '"event":"keep"' "$AHR_LOG" 2>/dev/null | grep -F "\"name\":\"$1\"" | tail -1 \
    | grep -oE "\"$2\":\"[^\"]*\"" | head -1 | sed -E "s/\"$2\":\"([^\"]*)\"/\1/"
}
keep_reason_for() { keep_field_for "$1" reason; }
log_has() { grep -qF -- "$1" "$AHR_LOG" 2>/dev/null; }
OLD="$(old_ts)"; ZERO="$(zero_ts)"; RECENT="$(recent_ts)"; IDLE="$(idle_ts)"; FRESH="$(fresh_ts)"

# (w0)/(w1) THE ga-jn82py BUG: old asleep worker, peek confirms gone, no bead assigned → REAPED.
bd_reset; AHR_FIXTURE="$STUBDIR/w0.json"
put_sessions "$(mk_sess ga-wisp-w0 wa-worker-adhoc-w0 asleep "$OLD" "$ZERO" "Pool top-up wa-cw69y" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-w0"; then ok "(w0) ga-jn82py: asleep+old+peek-dead wa-worker-adhoc, no bead → REAPED"; else nope "(w0) leaked wa-worker-adhoc was NOT reaped (count=$(closed_count)) — the ga-jn82py bug"; fi
bd_reset; AHR_FIXTURE="$STUBDIR/w1.json"
put_sessions "$(mk_sess ga-wisp-w1 ps-worker-adhoc-w1 asleep "$OLD" "$ZERO" "Pool top-up ps-abc" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-w1"; then ok "(w1) ga-jn82py: same for ps-worker-adhoc → REAPED"; else nope "(w1) leaked ps-worker-adhoc was NOT reaped (count=$(closed_count))"; fi

# (w2) a non-closed bead assigned by the session NAME (the format seen live: assignee ==
#      wa-worker-adhoc-<hex>) → KEPT. Paired with (w0): same session, only the bead differs.
bd_reset; AHR_FIXTURE="$STUBDIR/w2.json"
bdfx wa '[{"id":"wa-k8ben","status":"in_progress","assignee":"wa-worker-adhoc-w2","issue_type":"task"}]'
put_sessions "$(mk_sess ga-wisp-w2 wa-worker-adhoc-w2 asleep "$OLD" "$ZERO" "Pool top-up wa-cw69y" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for wa-worker-adhoc-w2)" = "has_assigned_bead" ] && [ "$(keep_field_for wa-worker-adhoc-w2 detail)" = "held wa:wa-k8ben(task)" ]; then ok "(w2) bead assigned by session name → KEPT (has_assigned_bead, detail names store+bead+type)"; else nope "(w2) worker holding an in_progress bead: closed=$(closed_count) reason='$(keep_reason_for wa-worker-adhoc-w2)' detail='$(keep_field_for wa-worker-adhoc-w2 detail)' — CRITICAL"; fi

# (w2b) a MAIL MESSAGE addressed to the session also holds it (observed live 2026-09-19: the
#       auto-handoff "context cycle" note a worker had just sent itself, ephemeral,
#       issue_type=message) — a session with pending mail is not finished.
bd_reset; AHR_FIXTURE="$STUBDIR/w2b.json"
bdfx city '[{"id":"ga-wisp-mail1","status":"open","assignee":"wa-worker-adhoc-w2b","issue_type":"message"}]'
put_sessions "$(mk_sess ga-wisp-w2b wa-worker-adhoc-w2b asleep "$OLD" "$ZERO" "Pool top-up x" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_field_for wa-worker-adhoc-w2b detail)" = "held city:ga-wisp-mail1(message)" ]; then ok "(w2b) pending mail addressed to the session → KEPT (detail shows it is a message)"; else nope "(w2b) mail-holding worker: closed=$(closed_count) detail='$(keep_field_for wa-worker-adhoc-w2b detail)'"; fi

# (w2c) the held detail is capped (5 beads + a +N tail) so one hoarding session cannot write a huge log line.
bd_reset; AHR_FIXTURE="$STUBDIR/w2c.json"
bdfx wa '[{"id":"b1","status":"open","assignee":"wa-worker-adhoc-w2c","issue_type":"task"},{"id":"b2","status":"open","assignee":"wa-worker-adhoc-w2c","issue_type":"task"},{"id":"b3","status":"open","assignee":"wa-worker-adhoc-w2c","issue_type":"task"},{"id":"b4","status":"open","assignee":"wa-worker-adhoc-w2c","issue_type":"task"},{"id":"b5","status":"open","assignee":"wa-worker-adhoc-w2c","issue_type":"task"},{"id":"b6","status":"open","assignee":"wa-worker-adhoc-w2c","issue_type":"task"},{"id":"b7","status":"open","assignee":"wa-worker-adhoc-w2c","issue_type":"task"}]'
put_sessions "$(mk_sess ga-wisp-w2c wa-worker-adhoc-w2c asleep "$OLD" "$ZERO" "Pool top-up x" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_field_for wa-worker-adhoc-w2c detail)" = "held wa:b1(task),b2(task),b3(task),b4(task),b5(task),+2" ]; then ok "(w2c) 7 held beads → detail lists 5 and a +2 tail"; else nope "(w2c) held-detail cap wrong: detail='$(keep_field_for wa-worker-adhoc-w2c detail)'"; fi

# (w3) assigned by the session ID only (the dog start-up protocol treats id/name/alias as
#      equally valid assignee spellings) → KEPT.
bd_reset; AHR_FIXTURE="$STUBDIR/w3.json"
bdfx wa '[{"id":"wa-idonly","status":"open","assignee":"ga-wisp-w3"}]'
put_sessions "$(mk_sess ga-wisp-w3 wa-worker-adhoc-w3 asleep "$OLD" "$ZERO" "Pool top-up x" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for wa-worker-adhoc-w3)" = "has_assigned_bead" ]; then ok "(w3) bead assigned by session id (open status) → KEPT"; else nope "(w3) id-assigned bead ignored: closed=$(closed_count) reason='$(keep_reason_for wa-worker-adhoc-w3)'"; fi

# (w4) the bead lives in the LAST store listed → still KEPT, and all 3 stores were consulted.
bd_reset; AHR_FIXTURE="$STUBDIR/w4.json"
bdfx ps '[{"id":"ps-zzz","status":"in_progress","assignee":"wa-worker-adhoc-w4"}]'
put_sessions "$(mk_sess ga-wisp-w4 wa-worker-adhoc-w4 asleep "$OLD" "$ZERO" "Pool top-up x" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for wa-worker-adhoc-w4)" = "has_assigned_bead" ] && [ "$(bd_calls)" = "3" ]; then ok "(w4) bead in the last store → KEPT (every store consulted)"; else nope "(w4) cross-store lock: closed=$(closed_count) reason='$(keep_reason_for wa-worker-adhoc-w4)' bd_calls=$(bd_calls)"; fi

# (w5) control: beads exist, but for OTHER sessions → this one is REAPED (the lock is
#      "assigned to THIS session", not "any bead in the store").
bd_reset; AHR_FIXTURE="$STUBDIR/w5.json"
bdfx wa '[{"id":"wa-other","status":"in_progress","assignee":"wa-worker-adhoc-someone-else"}]'
put_sessions "$(mk_sess ga-wisp-w5 wa-worker-adhoc-w5 asleep "$OLD" "$ZERO" "Pool top-up x" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-w5"; then ok "(w5) control: beads assigned to OTHER sessions do not hold this one → REAPED"; else nope "(w5) unrelated beads blocked the reap (count=$(closed_count))"; fi

# (w7) bd fails the way it really does under Dolt load (rc=1 + JSON error OBJECT) → KEPT.
#      error must never read as "no bead" (the error==empty class this script polices).
bd_reset; AHR_FIXTURE="$STUBDIR/w7.json"; AHR_BD_FAIL="wa"
put_sessions "$(mk_sess ga-wisp-w7 wa-worker-adhoc-w7 asleep "$OLD" "$ZERO" "Pool top-up x" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for wa-worker-adhoc-w7)" = "bead_lookup_failed" ] && [ "$(keep_field_for wa-worker-adhoc-w7 detail)" = "unknown rc1:wa" ]; then ok "(w7) bd rc=1 + JSON error object → KEPT (bead_lookup_failed, names the store)"; else nope "(w7) bd error was read as clean: closed=$(closed_count) reason='$(keep_reason_for wa-worker-adhoc-w7)' detail='$(keep_field_for wa-worker-adhoc-w7 detail)' — CRITICAL"; fi

# (w8) rc=0 but the payload is not a list (schema drift) → KEPT.
bd_reset; AHR_FIXTURE="$STUBDIR/w8.json"; AHR_BD_NOTLIST="city"
put_sessions "$(mk_sess ga-wisp-w8 wa-worker-adhoc-w8 asleep "$OLD" "$ZERO" "Pool top-up x" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_field_for wa-worker-adhoc-w8 detail)" = "unknown not_a_list:city" ]; then ok "(w8) rc=0 but non-list JSON → KEPT (not_a_list)"; else nope "(w8) non-list payload treated as clean: closed=$(closed_count) detail='$(keep_field_for wa-worker-adhoc-w8 detail)'"; fi

# (w8b) a list whose elements are not bead objects → KEPT (a junk element must not read as "empty").
bd_reset; AHR_FIXTURE="$STUBDIR/w8b.json"; AHR_BD_JUNKLIST="wa"
put_sessions "$(mk_sess ga-wisp-w8b wa-worker-adhoc-w8b asleep "$OLD" "$ZERO" "Pool top-up x" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_field_for wa-worker-adhoc-w8b detail)" = "unknown malformed_element:wa" ]; then ok "(w8b) list of non-bead elements → KEPT (malformed_element)"; else nope "(w8b) junk list element treated as clean: closed=$(closed_count) detail='$(keep_field_for wa-worker-adhoc-w8b detail)'"; fi

# (w9) bd hangs past the timeout → KEPT.
bd_reset; AHR_FIXTURE="$STUBDIR/w9.json"; AHR_BD_HANG="city"
put_sessions "$(mk_sess ga-wisp-w9 wa-worker-adhoc-w9 asleep "$OLD" "$ZERO" "Pool top-up x" false)"
ADHOC_REAPER_BD_TIMEOUT_SEC=2 run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_field_for wa-worker-adhoc-w9 detail)" = "unknown timeout:city" ]; then ok "(w9) bd hangs past the timeout → KEPT (timeout)"; else nope "(w9) hung bd was read as clean: closed=$(closed_count) detail='$(keep_field_for wa-worker-adhoc-w9 detail)'"; fi

# (w10) routes file missing → cannot know which stores exist → KEPT.
bd_reset; AHR_FIXTURE="$STUBDIR/w10.json"
put_sessions "$(mk_sess ga-wisp-w10 wa-worker-adhoc-w10 asleep "$OLD" "$ZERO" "Pool top-up x" false)"
ADHOC_REAPER_ROUTES_FILE="$STUBDIR/does-not-exist.jsonl" run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_field_for wa-worker-adhoc-w10 detail)" = "unknown routes_unreadable" ] && [ "$(bd_calls)" = "0" ]; then ok "(w10) routes file missing → KEPT (routes_unreadable)"; else nope "(w10) missing routes treated as no stores: closed=$(closed_count) detail='$(keep_field_for wa-worker-adhoc-w10 detail)'"; fi

# (w11) routes exist but NO listed store has a .beads dir → zero stores actually checked
#       is not "checked and clean" → KEPT.
bd_reset; AHR_FIXTURE="$STUBDIR/w11.json"
put_sessions "$(mk_sess ga-wisp-w11 wa-worker-adhoc-w11 asleep "$OLD" "$ZERO" "Pool top-up x" false)"
ADHOC_REAPER_ROUTES_FILE="$ROUTES_NOBEADS" run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_field_for wa-worker-adhoc-w11 detail)" = "unknown no_store_checked" ]; then ok "(w11) zero stores checked → KEPT (no_store_checked)"; else nope "(w11) zero stores checked was read as clean: closed=$(closed_count) detail='$(keep_field_for wa-worker-adhoc-w11 detail)'"; fi

# (w11b) a store whose .beads cannot even be stat-ed (EACCES, not ENOENT) is "don't know",
#        not "no store here" → KEPT. Only a DEFINITIVELY absent store may be skipped.
bd_reset; AHR_FIXTURE="$STUBDIR/w11b.json"
mkdir -p "$STUBDIR/stores/noaccess"
printf '{"prefix":"ga","path":"%s"}\n{"prefix":"zz","path":"%s"}\n' "$STUBDIR/stores/city" "$STUBDIR/stores/noaccess" > "$STUBDIR/routes-noaccess.jsonl"
put_sessions "$(mk_sess ga-wisp-w11b wa-worker-adhoc-w11b asleep "$OLD" "$ZERO" "Pool top-up x" false)"
if [ "$(id -u)" = "0" ]; then
  printf 'skip - (w11b) running as root: chmod 000 cannot make a path unreadable\n'
else
  chmod 000 "$STUBDIR/stores/noaccess"
  ADHOC_REAPER_ROUTES_FILE="$STUBDIR/routes-noaccess.jsonl" run_reaper 1 dead
  chmod 755 "$STUBDIR/stores/noaccess"
  if [ "$(closed_count)" = "0" ] && [ "$(keep_field_for wa-worker-adhoc-w11b detail)" = "unknown store_unreadable:noaccess" ]; then ok "(w11b) unreadable store (EACCES) → KEPT (store_unreadable), not skipped as absent"; else nope "(w11b) unreadable store was skipped as if absent: closed=$(closed_count) detail='$(keep_field_for wa-worker-adhoc-w11b detail)' — CRITICAL"; fi
fi

# (w11c) control for (w11b): a route whose store dir DOES NOT EXIST (ENOENT — a stale registry
#        entry) cannot hold beads → skipped, and the remaining stores decide (here: clear → REAPED).
bd_reset; AHR_FIXTURE="$STUBDIR/w11c.json"
printf '{"prefix":"ga","path":"%s"}\n{"prefix":"zz","path":"%s"}\n' "$STUBDIR/stores/city" "$STUBDIR/stores/does-not-exist" > "$STUBDIR/routes-ghost.jsonl"
put_sessions "$(mk_sess ga-wisp-w11c wa-worker-adhoc-w11c asleep "$OLD" "$ZERO" "Pool top-up x" false)"
ADHOC_REAPER_ROUTES_FILE="$STUBDIR/routes-ghost.jsonl" run_reaper 1 dead
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-w11c" && [ "$(bd_calls)" = "1" ]; then ok "(w11c) control: definitively-absent store (ENOENT) is skipped; the store that exists decides → REAPED"; else nope "(w11c) stale route blocked the reap: closed=$(closed_count) bd_calls=$(bd_calls)"; fi

# (w12) an identity that is not a plain token would be spliced into the bd query
#       expression → refuse to query at all → KEPT (never build a query from it).
bd_reset; AHR_FIXTURE="$STUBDIR/w12.json"
put_sessions "$(mk_sess ga-wisp-w12 'wa-worker-adhoc-q)OR(assignee=zzz' asleep "$OLD" "$ZERO" "Pool top-up x" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(bd_calls)" = "0" ] && [ "$(keep_field_for 'wa-worker-adhoc-q)OR(assignee=zzz' detail)" = "unknown identity_unsafe" ]; then ok "(w12) unsafe identity → KEPT, no query built (identity_unsafe)"; else nope "(w12) unsafe identity reached bd: closed=$(closed_count) bd_calls=$(bd_calls)"; fi

# (w13) ATTACHED worker (a human/tmux client is on it), everything else reapable → KEPT,
#       decided before any bd lookup.
bd_reset; AHR_FIXTURE="$STUBDIR/w13.json"
put_sessions "$(mk_sess ga-wisp-w13 wa-worker-adhoc-w13 asleep "$OLD" "$ZERO" "Pool top-up x" true)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for wa-worker-adhoc-w13)" = "attached" ] && [ "$(bd_calls)" = "0" ]; then ok "(w13) attached worker → KEPT (attached), no bd lookup"; else nope "(w13) attached worker: closed=$(closed_count) reason='$(keep_reason_for wa-worker-adhoc-w13)' bd_calls=$(bd_calls) — CRITICAL"; fi

# (w14)/(w14b) the attached veto is universal (legacy classes too); attached=false is the control.
bd_reset; AHR_FIXTURE="$STUBDIR/w14.json"
put_sessions "$(mk_sess ga-wisp-w14 gate-reviewer-adhoc-w14 asleep "$OLD" "$ZERO" "reviewer x" true)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for gate-reviewer-adhoc-w14)" = "attached" ]; then ok "(w14) attached legacy-class session → KEPT (veto is universal)"; else nope "(w14) attached reviewer was reaped or mis-classified: closed=$(closed_count) reason='$(keep_reason_for gate-reviewer-adhoc-w14)'"; fi
bd_reset; AHR_FIXTURE="$STUBDIR/w14b.json"
put_sessions "$(mk_sess ga-wisp-w14b gate-reviewer-adhoc-w14b asleep "$OLD" "$ZERO" "reviewer x" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-w14b" && [ "$(bd_calls)" = "0" ]; then ok "(w14b) control: attached=false legacy → REAPED, no bd lookup (lock is worker-class only)"; else nope "(w14b) legacy control changed behaviour: closed=$(closed_count) bd_calls=$(bd_calls)"; fi

# (w15) `attached` absent / not a boolean is "don't know" → KEPT, in EVERY class (closing a
#       session a human may be looking at cannot be undone). Only an explicit false goes on
#       — every legacy fixture above therefore carries "attached":false.
bd_reset; AHR_FIXTURE="$STUBDIR/w15.json"
put_sessions "$(mk_sess ga-wisp-w15 wa-worker-adhoc-w15 asleep "$OLD" "$ZERO" "Pool top-up x")"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for wa-worker-adhoc-w15)" = "attached_unknown" ]; then ok "(w15) worker with no attached field → KEPT (attached_unknown, fail closed)"; else nope "(w15) unknown attached read as false for a worker: closed=$(closed_count) reason='$(keep_reason_for wa-worker-adhoc-w15)'"; fi
bd_reset; AHR_FIXTURE="$STUBDIR/w15b.json"
put_sessions "$(mk_sess ga-wisp-w15b gate-reviewer-adhoc-w15b asleep "$OLD" "$ZERO" "reviewer x")"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for gate-reviewer-adhoc-w15b)" = "attached_unknown" ]; then ok "(w15b) legacy class with no attached field → KEPT too (fail closed for every class)"; else nope "(w15b) legacy session with unknown attached was reaped: closed=$(closed_count) reason='$(keep_reason_for gate-reviewer-adhoc-w15b)' — CRITICAL"; fi
# (w15c) a STRING "false" is not the boolean false (only a JSON boolean is trusted) → KEPT.
bd_reset; AHR_FIXTURE="$STUBDIR/w15c.json"
put_sessions '{"id":"ga-wisp-w15c","name":"gate-reviewer-adhoc-w15c","state":"asleep","closed":false,"created_at":"'"$OLD"'","last_active":"'"$ZERO"'","title":"reviewer x","attached":"false"}'
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for gate-reviewer-adhoc-w15c)" = "attached_unknown" ]; then ok "(w15c) attached as the STRING \"false\" → KEPT (only a JSON boolean is trusted)"; else nope "(w15c) string attached read as false: closed=$(closed_count) reason='$(keep_reason_for gate-reviewer-adhoc-w15c)'"; fi

# (w16) THE LIVE HAZARD: an ACTIVE worker mid-task whose bead was un-assigned by the
#       reclaim guard (observed live: wa-k8ben in_progress, assignee=null, session still
#       active). Were the bead lock consulted it would see "no bead" — it is the idle floor
#       that protects this session, and the lock is never even reached.
bd_reset; AHR_FIXTURE="$STUBDIR/w16.json"
put_sessions "$(mk_sess ga-wisp-w16 wa-worker-adhoc-w16 active "$OLD" "$RECENT" "Pool top-up wa-cw69y" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for wa-worker-adhoc-w16)" = "recently_active" ] && [ "$(bd_calls)" = "0" ]; then ok "(w16) active worker, recently active, bead un-assigned → KEPT by the idle floor (no lookup needed)"; else nope "(w16) mid-task worker without an assignee was reaped/mis-kept: closed=$(closed_count) reason='$(keep_reason_for wa-worker-adhoc-w16)' — CRITICAL"; fi

# (w17) the idle path works for workers: active + old + idle past the floor + no bead → REAPED.
bd_reset; AHR_FIXTURE="$STUBDIR/w17.json"
put_sessions "$(mk_sess ga-wisp-w17 wa-worker-adhoc-w17 active "$OLD" "$IDLE" "Pool top-up wa-cw69y" false)"
run_reaper 1 alive
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-w17"; then ok "(w17) active+old+idle-stale worker, no bead → REAPED"; else nope "(w17) idle finished worker was NOT reaped (count=$(closed_count))"; fi

# (w18)/(w19) never-claimed worker (title==name) reaps on age alone — but a held bead still wins.
bd_reset; AHR_FIXTURE="$STUBDIR/w18.json"
put_sessions "$(mk_sess ga-wisp-w18 wa-worker-adhoc-w18 active "$OLD" "$RECENT" "wa-worker-adhoc-w18" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-w18"; then ok "(w18) never-claimed worker (title==name), no bead → REAPED (reap_no_task)"; else nope "(w18) never-claimed worker not reaped (count=$(closed_count))"; fi
bd_reset; AHR_FIXTURE="$STUBDIR/w19.json"
bdfx wa '[{"id":"wa-held","status":"in_progress","assignee":"wa-worker-adhoc-w19"}]'
put_sessions "$(mk_sess ga-wisp-w19 wa-worker-adhoc-w19 active "$OLD" "$RECENT" "wa-worker-adhoc-w19" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for wa-worker-adhoc-w19)" = "has_assigned_bead" ]; then ok "(w19) title==name but a bead IS assigned → KEPT (the lock beats the no-task shortcut)"; else nope "(w19) no-task shortcut bypassed the bead lock: closed=$(closed_count) reason='$(keep_reason_for wa-worker-adhoc-w19)' — CRITICAL"; fi

# (w20) young worker → KEPT by the age floor; sessions that fail an earlier gate never
#       cost a bd lookup.
bd_reset; AHR_FIXTURE="$STUBDIR/w20.json"
put_sessions "$(mk_sess ga-wisp-w20 wa-worker-adhoc-w20 asleep "$FRESH" "$ZERO" "Pool top-up x" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for wa-worker-adhoc-w20)" = "too_young" ] && [ "$(bd_calls)" = "0" ]; then ok "(w20) young worker → KEPT (too_young), zero bd lookups"; else nope "(w20) young worker: closed=$(closed_count) reason='$(keep_reason_for wa-worker-adhoc-w20)' bd_calls=$(bd_calls)"; fi

# (w21) circuit breaker: bd down for every store. 3 reapable workers → only 2 lookups are
#       attempted (1 call each: the first store fails), the 3rd is kept WITHOUT a call, all kept.
bd_reset; AHR_FIXTURE="$STUBDIR/w21.json"; AHR_BD_FAIL="city,wa,ps"
put_sessions "$(mk_sess ga-wisp-w21a wa-worker-adhoc-w21a asleep "$OLD" "$ZERO" "t" false),$(mk_sess ga-wisp-w21b wa-worker-adhoc-w21b asleep "$OLD" "$ZERO" "t" false),$(mk_sess ga-wisp-w21c wa-worker-adhoc-w21c asleep "$OLD" "$ZERO" "t" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(bd_calls)" = "2" ] && [ "$(keep_field_for wa-worker-adhoc-w21c detail)" = "unknown circuit_open" ] && [ "$(keep_reason_for wa-worker-adhoc-w21a)" = "bead_lookup_failed" ]; then ok "(w21) bd down → 2 attempts then circuit opens; all 3 kept, third without a call"; else nope "(w21) circuit breaker: closed=$(closed_count) bd_calls=$(bd_calls) w21c detail='$(keep_field_for wa-worker-adhoc-w21c detail)'"; fi

# (w22) kill switch OFF: the dry run reflects the lock — held → keep, clear → would_reap.
bd_reset; AHR_FIXTURE="$STUBDIR/w22.json"
bdfx wa '[{"id":"wa-held22","status":"in_progress","assignee":"wa-worker-adhoc-w22a"}]'
put_sessions "$(mk_sess ga-wisp-w22a wa-worker-adhoc-w22a asleep "$OLD" "$ZERO" "t" false),$(mk_sess ga-wisp-w22b wa-worker-adhoc-w22b asleep "$OLD" "$ZERO" "t" false)"
run_reaper 0 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for wa-worker-adhoc-w22a)" = "has_assigned_bead" ] && log_has '"event":"would_reap","id":"ga-wisp-w22b"' && ! log_has '"event":"would_reap","id":"ga-wisp-w22a"'; then ok "(w22) ENABLED=0 dry run: held worker → keep, clear worker → would_reap, zero closes"; else nope "(w22) dry run does not mirror the lock: closed=$(closed_count)"; fi

# (w23) mixed batch: reaps the clear worker + a legacy reviewer; keeps the held worker, the
#       attached worker and the persistent (non-adhoc) wa-worker-1; counters land in the sweep line.
#       bd calls = 5: m1 (clear) consults all 3 stores, m2 (held in wa) stops at its 2nd store;
#       the reviewer, the attached worker and wa-worker-1 never cost a lookup.
bd_reset; AHR_FIXTURE="$STUBDIR/w23.json"
bdfx wa '[{"id":"wa-held23","status":"in_progress","assignee":"wa-worker-adhoc-m2"}]'
put_sessions "$(mk_sess ga-wisp-m1 wa-worker-adhoc-m1 asleep "$OLD" "$ZERO" "t" false),$(mk_sess ga-wisp-m2 wa-worker-adhoc-m2 asleep "$OLD" "$ZERO" "t" false),$(mk_sess ga-wisp-m3 gate-reviewer-adhoc-m3 asleep "$OLD" "$ZERO" "t" false),$(mk_sess ga-m4 wa-worker-1 asleep "$OLD" "$ZERO" "t" false),$(mk_sess ga-wisp-m5 ps-worker-adhoc-m5 asleep "$OLD" "$ZERO" "t" true)"
run_reaper 1 dead
if [ "$(closed_count)" = "2" ] && closed_has "ga-wisp-m1" && closed_has "ga-wisp-m3" && ! closed_has "ga-wisp-m2" && ! closed_has "ga-m4" && ! closed_has "ga-wisp-m5" \
   && [ "$(bd_calls)" = "5" ] && log_has '"kept_has_bead":1' && log_has '"kept_attached":1' && log_has '"kept_bead_lookup_failed":0'; then
  ok "(w23) mixed batch → reaped clear worker + reviewer; kept held/attached/persistent; sweep counters present"
else
  nope "(w23) mixed batch wrong: closed=[$(tr '\n' ' ' < "$AHR_CLOSE_LOG")] bd_calls=$(bd_calls)"
fi

# (w24) log honesty: a worker that the lock KEEPS must not be announced as a reap decision.
bd_reset; AHR_FIXTURE="$STUBDIR/w24.json"
bdfx wa '[{"id":"wa-held24","status":"in_progress","assignee":"wa-worker-adhoc-w24"}]'
put_sessions "$(mk_sess ga-wisp-w24 wa-worker-adhoc-w24 active "$OLD" "$IDLE" "Pool top-up x" false)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for wa-worker-adhoc-w24)" = "has_assigned_bead" ] && ! log_has '"event":"reap_active_idle"'; then ok "(w24) lock-kept worker is not logged as reap_active_idle (no contradictory decision line)"; else nope "(w24) log announces a reap that never happened: closed=$(closed_count)"; fi

# (w25) an empty last_active used to collapse a tab-separated column and shift every later
#       field. With attached now parsed, that shift would misread it — must stay aligned.
bd_reset; AHR_FIXTURE="$STUBDIR/w25.json"
put_sessions "$(mk_sess ga-wisp-w25 wa-worker-adhoc-w25 active "$OLD" "" "Pool top-up x" true)"
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for wa-worker-adhoc-w25)" = "attached" ]; then ok "(w25) empty last_active does not shift the census columns (attached still read correctly)"; else nope "(w25) census column shift: closed=$(closed_count) reason='$(keep_reason_for wa-worker-adhoc-w25)'"; fi

# (w26) `closed` absent is "don't know", not "open": the session is skipped and never acted on
#       (the placeholder the census parser now emits for an empty column must not read as false).
bd_reset; AHR_FIXTURE="$STUBDIR/w26.json"
put_sessions '{"id":"ga-wisp-w26","name":"gate-reviewer-adhoc-w26","state":"asleep","created_at":"'"$OLD"'","last_active":"'"$ZERO"'","title":"reviewer x","attached":false}'
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for gate-reviewer-adhoc-w26)" = "closed_unknown" ]; then ok "(w26) closed absent → KEPT (closed_unknown), never acted on"; else nope "(w26) session with unknown closed was reaped: closed=$(closed_count) reason='$(keep_reason_for gate-reviewer-adhoc-w26)' — CRITICAL"; fi

# ---- ga-al3rfs: ABSENT-FIELD alignment + id-less rows -------------------------------------
# The census is one TAB-joined row per session, read back with `IFS=$'\t' read`. TAB is
# IFS-whitespace, so an EMPTY column would COLLAPSE and slide every later field one slot left,
# silently (the ga-al3rfs audit of every tab-IFS reader found this reaper the only one where a shift
# was actually reachable). It is safe because parse_census guarantees every column BEFORE the title
# is non-empty: a "-" placeholder (ga-jn82py, col()). (n1)/(n2) pin that invariant at the unit level,
# so an empty column that would shift a later non-empty one fails HERE and not in production;
# (n)/(o) pin the two dangerous directions
# end to end; (p) is the scenario that FAILED before the id guard existed (it reaped an id-less
# row via `gc session close -`). A field that can be empty and has no placeholder must be joined
# with a non-whitespace delimiter (0x1f) instead.

# (n1) unit: a session with ONLY a name — every optional field absent. Every column before the title
#      must still be NON-EMPTY (placeholder) and land in its own slot; `attached` must be the
#      normalised "unknown", not a guess. A column added to parse_census without col() would
#      collapse here (bash `read` merges adjacent TABs) and misalign `attached` and everything after.
_n1_row="$(printf '%s' '{"sessions":[{"name":"y"}]}' | parse_census)"
IFS=$'\t' read -r _c_id _c_name _c_state _c_closed _c_created _c_last _c_att _c_alias _c_sess _c_title <<< "$_n1_row"
if [ "$_c_id|$_c_name|$_c_state|$_c_closed|$_c_created|$_c_last|$_c_att|$_c_alias|$_c_sess|$_c_title" = "-|y|-|-|-|-|unknown|-|-|" ]; then
  ok "(n1) parse_census: a name-only session keeps every pre-title column non-empty and aligned ('-' placeholders, attached=unknown)"
else
  nope "(n1) parse_census misaligned or left a column empty: '$_c_id|$_c_name|$_c_state|$_c_closed|$_c_created|$_c_last|$_c_att|$_c_alias|$_c_sess|$_c_title'"
fi

# (n2) unit: free text cannot split or forge a row — a title carrying a newline and a tab stays ONE row
#      and ONE title field (flattened to spaces), and the columns before it stay in place.
_n2_row="$(printf '%s' '{"sessions":[{"id":"x","name":"y","state":"asleep","closed":false,"created_at":"c","last_active":"l","attached":false,"title":"a\nb\tc"}]}' | parse_census)"
IFS=$'\t' read -r _c_id _c_name _c_state _c_closed _c_created _c_last _c_att _c_alias _c_sess _c_title <<< "$_n2_row"
if [ "$(printf '%s\n' "$_n2_row" | awk 'END{print NR}')" = "1" ] && [ "$_c_created|$_c_last|$_c_att|$_c_title" = "c|l|false|a b c" ]; then
  ok "(n2) parse_census: a newline/tab inside a title is flattened — one row, one title field, columns aligned"
else
  nope "(n2) hostile title split or shifted the row: rows=$(printf '%s\n' "$_n2_row" | awk 'END{print NR}') created='$_c_created' last='$_c_last' att='$_c_att' title='$_c_title'"
fi

# The scenarios below carry "attached":false so the ga-jn82py attached-veto does not mask the path under test.

# (n) created_at ABSENT + drained + OLD last_active + peek dead. Age is unknown, so the reaper must
#     fail SAFE and KEEP (age_unknown). A census that slid last_active into `created` would read that
#     2h-old value as the session's AGE and REAP it — on a field that was never its created_at.
AHR_FIXTURE="$STUBDIR/n.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-n","name":"auto-refiner-adhoc-nnn","state":"asleep","closed":false,"last_active":"$(old_ts)","title":"auto-refiner: ga-n (attempt 1)","attached":false}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "0" ] && [ "$(keep_reason_for auto-refiner-adhoc-nnn)" = "age_unknown" ]; then
  ok "(n) created_at absent + drained + old last_active → kept for age_unknown (last_active NOT read as the age)"
else
  nope "(n) absent created_at was misread: closed=$(closed_count) reason='$(keep_reason_for auto-refiner-adhoc-nnn)' log=$(grep -F ga-wisp-n "$AHR_LOG" | head -1)"
fi

# (o) last_active ABSENT + title==name (never claimed a task) + old created_at: the ga-dd2h0 path must
#     still fire and REAP. A census that slid the title into last_active would leave `title` empty,
#     title_shows_no_task would fail safe to 0 and the session would be KEPT forever — a leak, on
#     exactly the class of session this reaper exists to stop.
AHR_FIXTURE="$STUBDIR/o.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"id":"ga-wisp-o","name":"gate-reviewer-adhoc-ooo","state":"active","closed":false,"created_at":"$(old_ts)","title":"gate-reviewer-adhoc-ooo","attached":false}]}
EOF
run_reaper 1 dead
if [ "$(closed_count)" = "1" ] && closed_has "ga-wisp-o" && log_has '"event":"reap_no_task"'; then
  ok "(o) last_active absent + title==name + old → REAPED via reap_no_task (title stayed in the title slot)"
else
  nope "(o) absent last_active shifted the title out of place: closed=$(closed_count) log=$(grep -F ga-wisp-o "$AHR_LOG" | head -1)"
fi

# (p) id ABSENT on an otherwise reapable, eligible row. An id-less row must be REJECTED as malformed —
#     never handed to `gc session close` (what a blank or placeholder id does there is unverified).
#     Asserted on the RAW close log (-s: an EMPTY-argument call leaves a blank line that closed_count's
#     NF filter skips, a placeholder one leaves "-") AND on the reason, so a row that is skipped by
#     accident does not pass. Before the guard this row was REAPED via `gc session close -`.
AHR_FIXTURE="$STUBDIR/p.json"
cat > "$AHR_FIXTURE" <<EOF
{"sessions":[{"name":"auto-refiner-adhoc-ppp","state":"asleep","closed":false,"created_at":"$(old_ts)","last_active":"$(zero_ts)","title":"auto-refiner: ga-p (attempt 1)","attached":false}]}
EOF
run_reaper 1 dead
if [ ! -s "$AHR_CLOSE_LOG" ] && [ "$(keep_reason_for auto-refiner-adhoc-ppp)" = "malformed_row_no_id" ]; then
  ok "(p) id absent → rejected as malformed_row_no_id, gc session close never called"
else
  nope "(p) id-less row was not rejected as malformed: close-log='$(tr '\n' ' ' < "$AHR_CLOSE_LOG")' reason='$(keep_reason_for auto-refiner-adhoc-ppp)' log=$(grep -F ppp "$AHR_LOG" | head -1)"
fi

rm -rf "$STUBDIR" /tmp/_ahr_gc_stub_unit 2>/dev/null
echo
echo "selftest: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
