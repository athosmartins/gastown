#!/usr/bin/env bash
# pilot-dispatcher.lock.selftest.sh — Regression harness for the single-instance
# lock (ga-7s0or).
#
# Bug ga-7s0or (P0, INFRA): the prior guard did `exec 9>$LOCK; flock -n 9`. fd 9
# had NO close-on-exec, so every gc/bd/sling child — and any long-lived daemon
# they (re)spawned, notably a dolt sql-server or the slung builder session —
# INHERITED fd 9 and held the flock for its ENTIRE life (5h+ observed). Every
# later sweep then logged "backing off" and dispatched ZERO: a silent, unbounded,
# total dispatch deadlock independent of load.
#
# The fix abandons the inheritable-fd flock for an fd-LESS lock that no child can
# ever hold open: an atomic `mkdir` mutex plus a heartbeat file whose mtime marks
# liveness. A held lock whose heartbeat is older than PILOT_LOCK_MAX_AGE is a
# dead/zombie holder and is recovered WITHOUT rm of any flock inode, via an
# atomic rename tiebreak so two concurrent recoverers can never both proceed.
#
# This harness drives the REAL pilot-dispatcher.sh in DRY_RUN against a THROWAWAY
# fixture city with bd/gc shims that return empty, so a successful lock-acquire
# proceeds into the sweep ("=== Pilot sweep start") and a backoff exits before it.
#
# Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

# ── Throwaway workspace ───────────────────────────────────────────────────────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-lock-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

SHIMBIN="$WORK/bin"
FIXCITY="$WORK/city"
FIXTMP="$WORK/tmp"            # isolated TMPDIR so the lock lives in the workspace
mkdir -p "$SHIMBIN" "$FIXCITY/.gc/logs" "$FIXTMP"

# ── Minimal shims: every bd/gc query returns empty so the sweep finds no work
#    and exits cleanly AFTER logging the sweep-start banner. The lock behaviour
#    is all we exercise here. ───────────────────────────────────────────────────
cat > "$SHIMBIN/bd" <<'SHIM'
#!/usr/bin/env bash
printf '[]'
exit 0
SHIM
chmod +x "$SHIMBIN/bd"

cat > "$SHIMBIN/gc" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"rig list"*) printf '{"rigs":[]}' ;;
  *)            : ;;
esac
exit 0
SHIM
chmod +x "$SHIMBIN/gc"

cat > "$SHIMBIN/notify" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
chmod +x "$SHIMBIN/notify"

# The lock path the dispatcher derives from GC_CITY (must mirror the dispatcher).
# We pin TMPDIR=$FIXTMP into every dispatcher invocation, so the dispatcher's
# ${TMPDIR:-/tmp} resolves to $FIXTMP — exactly what we compute here.
LOCK_DIR="$FIXTMP/pilot-dispatcher$(printf '%s' "$FIXCITY" | tr '/ ' '__').lock.d"
LOCK_HB="$LOCK_DIR/heartbeat"

clear_lock() { rm -rf "$LOCK_DIR" "$LOCK_DIR".reaping.* 2>/dev/null || true; }

# Runs the real dispatcher in DRY_RUN with the shims on PATH; echoes the log.
# $1 (optional): PILOT_LOCK_MAX_AGE override (seconds).
run_dispatch() {
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    TMPDIR="$FIXTMP" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    ${1:+PILOT_LOCK_MAX_AGE="$1"} \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

echo "pilot-dispatcher.lock.selftest — single-instance lock (ga-7s0or)"

# ── Scenario A (AC1): the leaky-fd flock is GONE; lock is fd-less ─────────────
# Strip comment lines first — the rewrite's comment quotes the old `exec 9>` /
# `flock -n 9` idiom on purpose; only ACTIVE code matters for the fd-leak.
echo "Scenario A: no inheritable-fd flock remains (AC1 — lsof can never show a leak)"
CODE_ONLY="$(grep -v '^[[:space:]]*#' "$DISPATCHER")"
if printf '%s' "$CODE_ONLY" | grep -Eq 'exec[[:space:]]+9>|flock[[:space:]]+-n[[:space:]]+9'; then
  bad "REGRESSION: dispatcher still opens fd 9 / calls flock -n 9 (fd leaks into children)"
else
  ok "no active 'exec 9>' / 'flock -n 9' — no fd is held that a child could inherit"
fi
if grep -q 'mkdir "\$PILOT_LOCK_DIR"' "$DISPATCHER"; then
  ok "uses an fd-less mkdir mutex"
else
  bad "no 'mkdir \$PILOT_LOCK_DIR' — expected an fd-less directory lock"
fi

# ── Scenario B: mutual exclusion — a fresh held lock makes a sweep back off ────
echo "Scenario B: a FRESH lock (live holder) forces backoff before sweep start"
clear_lock
mkdir -p "$LOCK_DIR"
date +%s > "$LOCK_HB"            # fresh heartbeat → looks like a live sweep
LOGB="$(run_dispatch)"
if echo "$LOGB" | grep -q "backing off"; then
  ok "backed off while a live sweep holds the lock"
else
  bad "did NOT back off (expected 'backing off' with a fresh lock held)"
fi
if echo "$LOGB" | grep -q "Pilot sweep start"; then
  bad "REGRESSION: proceeded into the sweep despite a live lock holder"
else
  ok "did not enter the sweep (no double-run)"
fi
clear_lock

# ── Scenario C (AC2): stale lock recovers automatically, WITHOUT rm ───────────
echo "Scenario C: a STALE lock (heartbeat older than max-age) is recovered, no rm"
clear_lock
mkdir -p "$LOCK_DIR"
echo "zombie-holder-token" > "$LOCK_HB"
# Backdate the heartbeat mtime well past the max-age we pass in (2s).
touch -t 200001010000 "$LOCK_HB" 2>/dev/null || true
LOGC="$(run_dispatch 2)"         # PILOT_LOCK_MAX_AGE=2s → the 2000 mtime is stale
if echo "$LOGC" | grep -q "Recovered STALE"; then
  ok "recovered the stale lock automatically"
else
  bad "did NOT recover the stale lock (expected 'Recovered STALE')"
fi
if echo "$LOGC" | grep -q "Pilot sweep start"; then
  ok "proceeded into the sweep after recovery"
else
  bad "did not proceed into the sweep after recovering the stale lock"
fi
clear_lock

# ── Scenario D (AC3): two concurrent recoverers — EXACTLY ONE proceeds ────────
echo "Scenario D: two concurrent stale-lock recoverers — no double-dispatch race"
clear_lock
mkdir -p "$LOCK_DIR"
echo "zombie-holder-token" > "$LOCK_HB"
touch -t 200001010000 "$LOCK_HB" 2>/dev/null || true
SHARED_LOG="$FIXCITY/.gc/logs/pilot-dispatcher.log"
: > "$SHARED_LOG"
run_race() {
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" TMPDIR="$FIXTMP" DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_LOCK_MAX_AGE=2 \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
}
# Both racers append (pilot-dispatcher.sh: `exec >> "$LOG"`) to the SAME
# shared log — there is no way to attribute a line to "which process wrote
# it" from a per-racer snapshot taken at an uncoordinated time: a snapshot
# taken right after racer A's own run can still observe lines racer B
# already appended (or will append moments later, before A's own copy is
# even read back). A prior version of this harness captured per-process
# copies via `cp` and counted files containing the banner — that produces
# false positives whenever the loser's copy is taken after the winner's
# (early) recovery line has landed in the shared log, well before the
# winner finishes its full sweep (confirmed via ga-byd3u: reproduced with a
# byte-identical "Recovered STALE" line — same timestamp, same token — that
# had simply leaked into both copies, i.e. ONE real event, not two).
# Counting occurrences directly in the shared log, ONCE, after `wait`
# guarantees both processes are fully done, has no such window: each real
# recovery is exactly one `log "Recovered STALE..."` call, so this is an
# exact, race-free measure of how many times recovery actually fired.
run_race &
P1=$!
run_race &
P2=$!
wait "$P1" "$P2"
RECOVERED=$(grep -c "Recovered STALE" "$SHARED_LOG" 2>/dev/null | tr -d ' ')
RECOVERED=${RECOVERED:-0}
if [ "$RECOVERED" -le 1 ]; then
  ok "at most one recoverer proceeded ($RECOVERED) — no double-dispatch"
else
  bad "TWO recoverers proceeded — double-dispatch race on stale recovery"
fi
clear_lock

# ── Scenario E (ga-6atm7 AC): the numbers actually align — StartInterval <
# default PILOT_LOCK_MAX_AGE, and the default has real margin over a merely
# slow (but alive) sweep instead of the pre-fix 600s that declared a routine
# ~10min sweep dead (measured: p90=523s, 141/2099 sweeps > 600s, 184 sweeps
# taken over mid-run in a 16-day window). ─────────────────────────────────────
echo "Scenario E: PILOT_LOCK_MAX_AGE default has real margin (ga-6atm7)"

DEFAULT_MAX_AGE="$(grep -oE 'PILOT_LOCK_MAX_AGE:-[0-9]+' "$DISPATCHER" | head -1 | grep -oE '[0-9]+$')"
PLIST="$SELF_DIR/../../../scripts/com.gascity.pilot.plist"
if [ -f "$PLIST" ]; then
  PLIST_INTERVAL="$(sed -n '/<key>StartInterval<\/key>/{n;p;}' "$PLIST" | grep -oE '[0-9]+')"
else
  PLIST_INTERVAL=""
fi

if [ -n "$DEFAULT_MAX_AGE" ] && [ -n "$PLIST_INTERVAL" ] && [ "$PLIST_INTERVAL" -lt "$DEFAULT_MAX_AGE" ]; then
  ok "com.gascity.pilot.plist StartInterval (${PLIST_INTERVAL}s) < default PILOT_LOCK_MAX_AGE (${DEFAULT_MAX_AGE}s)"
else
  bad "StartInterval/PILOT_LOCK_MAX_AGE misaligned (plist=${PLIST_INTERVAL:-?}s, default=${DEFAULT_MAX_AGE:-?}s) — a normal sweep can overlap its own next invocation and get its lock stolen"
fi

# A lock aged 900s is well above the historical p90 (523s) a slow-but-alive
# sweep can legitimately take, and above the OLD 600s default that used to
# kill it — but must stay below the new default, so it must NOT be reclaimed.
clear_lock
mkdir -p "$LOCK_DIR"
echo "slow-but-alive-token" > "$LOCK_HB"
touch -t "$(date -v-900S +%Y%m%d%H%M.%S)" "$LOCK_HB" 2>/dev/null || true
LOGE1="$(run_dispatch)"     # no override — exercises the PRODUCTION default
if echo "$LOGE1" | grep -q "Recovered STALE"; then
  bad "REGRESSION: a 900s-old heartbeat was reclaimed under the production default — a routine slow sweep would get its lock stolen mid-work"
else
  ok "a 900s-old heartbeat (slow-but-alive range) backs off, not reclaimed, under the production default"
fi
clear_lock

# A lock aged 1300s is past the new default (1200s) — a genuinely wedged
# holder must still be recovered in bounded time, not left to wedge forever.
mkdir -p "$LOCK_DIR"
echo "zombie-holder-token" > "$LOCK_HB"
touch -t "$(date -v-1300S +%Y%m%d%H%M.%S)" "$LOCK_HB" 2>/dev/null || true
LOGE2="$(run_dispatch)"     # no override — exercises the PRODUCTION default
if echo "$LOGE2" | grep -q "Recovered STALE"; then
  ok "a 1300s-old heartbeat (past the new default) is still recovered under the production default"
else
  bad "a 1300s-old heartbeat was NOT recovered — a genuinely dead holder would wedge the dispatcher indefinitely"
fi
clear_lock

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "lock.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
