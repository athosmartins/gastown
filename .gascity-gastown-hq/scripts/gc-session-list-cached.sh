#!/usr/bin/env bash
# gc-session-list-cached.sh — a short-TTL, fail-open cache shim for `gc session list --json`.
#
# WHY (2026-07-02 root fix): 6+ read-only pollers (watchdogs, janitors, telemetry) each
# issue an independent, IDENTICAL `gc session list` query against Dolt. When several fire
# within the same few seconds they form a connect-storm that spikes Dolt CPU; a hot Dolt
# then makes gate reviewers FREEZE mid-review on hung reads (the 9h gate stall). Staggering
# the launchd tiers (done) killed the synchronized bursts but not the steady-state overlap
# — that residual is query VOLUME, and the lever for volume is to STOP issuing the same
# query N times. This shim collapses N reads within a TTL window into ONE: the first caller
# refreshes the cache under a single-refresher lock; everyone else reads the cached bytes.
#
# Only read-only, staleness-tolerant consumers should use it (default TTL 8s — liveness
# does not meaningfully change in 8s). A correctness-sensitive call-site that must see a
# genuinely fresh SECOND read (e.g. a frozen-reviewer RESAMPLE confirming last_active moved
# between two samples) MUST pass --fresh to bypass the cache — otherwise both samples come
# from the same cached bytes and the resample is worthless.
#
# CONTRACT (drop-in for `gc session list --json`):
#   * stdout = the SAME JSON `gc session list --json` emits ({"sessions":[...]}).
#   * exit 0 when it served data (fresh or cached).
#   * FAIL-OPEN: if a live refresh fails but a prior good cache exists, serve the cache. A
#     slightly-stale-but-VALID session list is far safer than empty output — consumers
#     treat empty/None as "cannot verify" and several fail-safe SKIP their action, which
#     would silently DISABLE a watchdog. Stale-by-seconds never does that.
#   * If refresh fails AND no cache exists, pass gc's raw output + exit code straight
#     through (identical to calling gc directly — the shim is never worse than no shim).
#   * NEVER publishes a cache unless it validated as JSON containing a "sessions" list.
#   * Atomic publish (temp + mv) so a reader never sees a half-written file.
#   * Single-refresher (mkdir lock, portable on darwin where flock is absent; stale lock
#     is stolen after LOCK_STALE_SEC so a dead refresher can't wedge the shim).
#
# Env knobs:
#   GC_SESSION_CACHE_TTL     seconds a cache entry stays fresh     (default 8)
#   GC_SESSION_CACHE_DIR     cache location                        (default $GC_CITY/.gc/cache)
#   GC_SESSION_CACHE_OFF=1   kill switch — always go live, never cache (instant rollback)
#   GC_SESSION_LOCK_WAIT_SEC brief wait for a peer's in-flight refresh before we
#                            fall back to our own live call — independent of TTL,
#                            see ga-abrm8                          (default 2)
#
# Usage:
#   gc-session-list-cached.sh            # cached `gc session list --json`
#   gc-session-list-cached.sh --fresh    # force a live read (bypass + refresh the cache)
#   gc-session-list-cached.sh --selftest # run the offline self-test
set -uo pipefail

TTL="${GC_SESSION_CACHE_TTL:-8}"
CITY="${GC_CITY:-$HOME/gt/.gascity-gastown-hq}"
CACHE_DIR="${GC_SESSION_CACHE_DIR:-$CITY/.gc/cache}"
CACHE="$CACHE_DIR/session-list.json"
LOCKDIR="$CACHE_DIR/session-list.refresh.lock.d"
LOCK_STALE_SEC="${GC_SESSION_LOCK_STALE_SEC:-30}"   # steal a lock older than this (dead refresher)
# Brief wait for an in-flight peer refresh to publish before we fall back to our
# own live call (see _wait_for_peer_publish). Deliberately INDEPENDENT of TTL:
# TTL is a cache-freshness window (how stale is acceptable to serve), not a safe
# "how long may a caller sit idle" budget — see ga-abrm8 in the function's own
# comment for why conflating the two was a bug.
LOCK_WAIT_SEC="${GC_SESSION_LOCK_WAIT_SEC:-2}"

_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
_now()   { date +%s; }

_cache_age() {
  [ -f "$CACHE" ] || { echo 999999; return; }
  echo $(( $(_now) - $(_mtime "$CACHE") ))
}

# stdin → exit 0 iff it is JSON with a "sessions" list (the only shape we cache).
_valid_json_sessions() {
  python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    sys.exit(0 if isinstance(d,dict) and isinstance(d.get("sessions"),list) else 1)
except Exception:
    sys.exit(1)' 2>/dev/null
}

_live() { gc session list --json 2>/dev/null; }

# Cheap structural sanity for the serving boundary — no python tax on the hot cache-hit
# path. `gc session list --json` emits `{"sessions":[...]}`, so a valid cache starts with
# '{' and contains "sessions" in its first bytes. Catches gross corruption (truncation,
# a non-JSON blob) that atomic writes shouldn't produce but defense-in-depth guards anyway.
_cache_looks_valid() {
  [ -f "$CACHE" ] || return 1
  [ "$(head -c 1 "$CACHE" 2>/dev/null)" = "{" ] || return 1
  head -c 64 "$CACHE" 2>/dev/null | grep -q '"sessions"'
}

# Serve the cache IFF it passes the sanity check; a corrupt cache is dropped and we
# return non-zero so the caller falls through to a live refresh (never serve garbage).
_serve_cache() {
  if _cache_looks_valid; then cat "$CACHE" 2>/dev/null && exit 0; fi
  rm -f "$CACHE" 2>/dev/null
  return 1
}

# Publish $1 to the cache atomically iff it validates. Returns 0 if published.
_publish() {
  local out="$1" tmp
  printf '%s' "$out" | _valid_json_sessions || return 1
  tmp="$CACHE.tmp.$$"
  printf '%s' "$out" > "$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$CACHE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# Live-read → publish-on-success → print; fail-open to cache; else raw passthrough.
_refresh_and_emit() {
  local out rc
  out="$(_live)"; rc=$?
  if [ $rc -eq 0 ] && _publish "$out"; then
    printf '%s\n' "$out"; exit 0
  fi
  [ -f "$CACHE" ] && _serve_cache            # fail-open: last-good beats empty
  printf '%s\n' "$out"; exit $rc             # no cache → behave exactly like gc
}

_try_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then return 0; fi
  # lock held — steal it if the holder looks dead (older than LOCK_STALE_SEC)
  local age; age=$(( $(_now) - $(_mtime "$LOCKDIR") ))
  if [ "$age" -ge "$LOCK_STALE_SEC" ]; then
    rmdir "$LOCKDIR" 2>/dev/null || true
    mkdir "$LOCKDIR" 2>/dev/null && return 0
  fi
  return 1
}
_unlock() { rmdir "$LOCKDIR" 2>/dev/null || true; }

# Another process holds the refresh lock. Wait briefly for its publish (serving
# the moment a valid cache appears — exits via _serve_cache); if nothing shows up
# within the wait window, return 1 so the caller falls back to its own live read.
#
# ga-abrm8: the wait ceiling is LOCK_WAIT_SEC, not TTL. This loop used to bound
# itself on `TTL * 4` (reusing the cache-freshness knob as if it were also a safe
# wait budget). At the default TTL=8s, a caller that raced in here with NO
# fallback cache to serve — e.g. painel-prod's 120s poll cadence, which almost
# never has a fresh-enough cache to take the fast path above — spent up to the
# *entire* TTL doing nothing before even attempting the live call that follows,
# directly violating this shim's own documented "never worse than no shim"
# contract. Measured live: TTL-scaled wait + a live call totaled 12.75s against
# painel-prod's 10s subprocess timeout. LOCK_WAIT_SEC keeps the same intent
# (give an in-flight peer a moment to finish, since it's presumably close to
# done) without scaling with TTL — see the "lock-wait bounded by LOCK_WAIT_SEC"
# selftest case below for the regression proof.
_wait_for_peer_publish() {
  local i=0
  while [ "$i" -lt $(( LOCK_WAIT_SEC * 4 )) ]; do
    sleep 0.25; i=$(( i + 1 ))
    [ -f "$CACHE" ] && _serve_cache
  done
  return 1
}

# ── self-test (offline: stubs `gc`, exercises TTL / validate / atomic / fail-open) ──
if [ "${1:-}" = "--selftest" ]; then
  pass=0; fail=0
  ok(){ pass=$((pass+1)); echo "  ✓ $1"; }
  bad(){ fail=$((fail+1)); echo "  ✗ $1"; }
  bash -n "$0" && ok "syntax valid" || bad "syntax error"
  TMP="$(mktemp -d)"; export GC_SESSION_CACHE_DIR="$TMP"
  CACHE="$TMP/session-list.json"; LOCKDIR="$TMP/session-list.refresh.lock.d"
  # validator accepts good shape, rejects junk / wrong shape / empty
  echo '{"sessions":[]}'        | _valid_json_sessions && ok "validator accepts {sessions:[]}" || bad "validator rejected good"
  echo '{"sessions":[{"id":1}]}'| _valid_json_sessions && ok "validator accepts populated" || bad "validator rejected populated"
  echo 'not json'               | _valid_json_sessions && bad "validator accepted junk" || ok "validator rejects junk"
  echo '{"other":1}'            | _valid_json_sessions && bad "validator accepted wrong-shape" || ok "validator rejects wrong-shape"
  echo -n ''                    | _valid_json_sessions && bad "validator accepted empty" || ok "validator rejects empty"
  # _publish writes atomically only on valid input
  _publish '{"sessions":[{"id":"a"}]}' && [ -f "$CACHE" ] && ok "_publish wrote valid cache" || bad "_publish failed on valid"
  grep -q '"a"' "$CACHE" && ok "cache content correct" || bad "cache content wrong"
  _publish 'garbage' && bad "_publish wrote junk" || ok "_publish refused junk"
  grep -q '"a"' "$CACHE" && ok "prior cache intact after refused junk" || bad "junk clobbered good cache"
  # no leftover temp files from either publish
  [ -z "$(ls "$TMP"/session-list.json.tmp.* 2>/dev/null)" ] && ok "no leftover temp files" || bad "temp file leaked"
  # lock: acquire, re-acquire blocked, steal-when-stale
  _try_lock && ok "lock acquired" || bad "lock not acquired"
  ( _try_lock ) && bad "second lock acquired (should block)" || ok "second lock blocked while held"
  # make the lock look stale → stealable
  touch -t 200001010000 "$LOCKDIR" 2>/dev/null
  _try_lock && ok "stale lock stolen" || bad "stale lock not stolen"
  _unlock; [ ! -d "$LOCKDIR" ] && ok "unlock removes lockdir" || bad "unlock left lockdir"
  # serving boundary: a corrupt cache is NOT served and is dropped (defense-in-depth)
  printf '%s' '{"sessions":[{"id":"x"}]}' > "$CACHE"
  _cache_looks_valid && ok "valid cache passes sanity check" || bad "valid cache failed sanity"
  printf '%s' 'CORRUPT{{{' > "$CACHE"
  _cache_looks_valid && bad "corrupt cache passed sanity check" || ok "corrupt cache fails sanity check"
  ( _serve_cache ) ; [ ! -f "$CACHE" ] && ok "_serve_cache dropped corrupt cache" || bad "corrupt cache not dropped"
  printf '%s' '{"other":1}' > "$CACHE"
  _cache_looks_valid && bad "wrong-shape cache passed sanity" || ok "wrong-shape cache fails sanity"

  # regression (ga-abrm8): the lock-wait ceiling in _wait_for_peer_publish must be
  # governed by LOCK_WAIT_SEC (a small, independent knob) — NOT by TTL (a cache-
  # freshness window). Before this fix the wait loop scaled with TTL, so a caller
  # with no fallback cache to serve could burn nearly the *entire* TTL doing
  # nothing before even ATTEMPTING a live call: at the default TTL=8s, measured
  # live (ga-abrm8) to total 12.75s against painel-prod's 10s caller budget —
  # the shim's own documented "never worse than no shim" contract broken.
  #
  # Proven without literally blocking the selftest for TTL seconds: run the wait
  # in the background with a deliberately huge TTL, and after a short probe
  # window assert it has ALREADY RETURNED (bound to LOCK_WAIT_SEC) rather than
  # still sleeping (bound to TTL, the pre-fix bug).
  rm -f "$CACHE"
  TTL=100
  ( _wait_for_peer_publish >/dev/null 2>&1 ) &
  _wfpp_pid=$!
  sleep 3
  if kill -0 "$_wfpp_pid" 2>/dev/null; then
    bad "lock-wait still running after 3s probe with TTL=100 (wait ceiling scales with TTL, not LOCK_WAIT_SEC)"
    kill "$_wfpp_pid" 2>/dev/null; wait "$_wfpp_pid" 2>/dev/null
  else
    wait "$_wfpp_pid" 2>/dev/null
    ok "lock-wait returns quickly (bounded by LOCK_WAIT_SEC) even with TTL=100"
  fi

  # a cache published mid-wait short-circuits immediately rather than riding out
  # the full wait window (this property must survive the fix unchanged)
  rm -f "$CACHE"
  TTL=100
  ( sleep 1; printf '%s' '{"sessions":[]}' > "$CACHE" ) &
  _pub_pid=$!
  t0=$(_now)
  out="$( _wait_for_peer_publish )"; rc=$?
  t1=$(_now)
  wait "$_pub_pid" 2>/dev/null
  elapsed=$(( t1 - t0 ))
  if [ "$rc" -eq 0 ] && [ "$elapsed" -le 3 ]; then
    ok "wait short-circuits the moment a peer publishes (${elapsed}s)"
  else
    bad "wait did not short-circuit on publish (rc=$rc, ${elapsed}s)"
  fi
  rm -f "$CACHE"
  rm -rf "$TMP"
  echo "gc-session-list-cached selftest: PASS=$pass FAIL=$fail"
  [ "$fail" -eq 0 ]; exit $?
fi

# ── main ───────────────────────────────────────────────────────────────────────
FRESH=0
[ "${1:-}" = "--fresh" ] && FRESH=1
mkdir -p "$CACHE_DIR" 2>/dev/null || true

# kill switch or explicit fresh → live read (still refreshes the cache for others)
if [ "${GC_SESSION_CACHE_OFF:-0}" = "1" ] || [ "$FRESH" = "1" ]; then
  _refresh_and_emit
fi

# fast path: a fresh-enough cache serves without touching Dolt (the common case)
if [ "$(_cache_age)" -lt "$TTL" ]; then
  _serve_cache
fi

# stale/absent → become the single refresher, or ride someone else's refresh
if _try_lock; then
  trap '_unlock' EXIT
  # re-check under lock: a refresher just ahead of us may have published
  if [ "$(_cache_age)" -lt "$TTL" ]; then _serve_cache; fi
  _refresh_and_emit
else
  # another process is refreshing. Serve current cache if we have one (a hair stale is
  # fine + fail-open); else wait briefly for the publish, then serve or go live.
  [ -f "$CACHE" ] && _serve_cache
  _wait_for_peer_publish
  _live                                       # last resort: refresher never produced
fi
