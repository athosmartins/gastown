#!/usr/bin/env bash
# bd-list-cached.sh — a short-TTL, fail-open, per-query cache shim for read-only
# `bd list`/`bd show`/`bd query` calls (ga-48xcv, the bd-flavored sibling of
# gc-session-list-cached.sh).
#
# WHY: ga-7e7a measured ~9 bd invocations/second city-wide, ~70ms of pure
# connection-handshake CPU each — 60% of Dolt's CPU floor is invocations doing
# ZERO useful work. gc-session-list-cached.sh already proved the fix shape for
# `gc session list` (one shared query instead of N identical ones); this is
# the same shape for `bd list`/`show`/`query`, which is where most of the call
# volume actually lives (quality-gate-guard.sh, quality-gate-dispatcher.sh,
# gate-recovery-watchdog.py).
#
# KEY DIFFERENCE from gc-session-list-cached.sh: `gc session list` has no
# arguments, so one cache file suffices. `bd list/show/query` take arbitrary
# arguments (labels, assignee, ids, --all, ...) that change what's being
# asked, so this shim caches PER ARGUMENT SIGNATURE (a hash of the argv),
# not globally — two different queries never collide or share a slot, and
# a lock is held per-key so unrelated queries never serialize behind each
# other.
#
# CONTRACT (drop-in prefix for `bd <args...>`):
#   bd -C "$GC_CITY" list --json --all -l foo
#   →  bash .../bd-list-cached.sh -C "$GC_CITY" list --json --all -l foo
#
# SAFETY — only list|show|query are ever cached. Any other bd subcommand
# (close, comment, label, update, claim, ...) is passed straight through to
# the live `bd` binary, untouched, exactly as if this shim weren't there.
# This is enforced by inspecting argv for the first non-flag token: if it
# isn't list/show/query, or if an unrecognized flag precedes it (only -C /
# --city are understood as taking a value), the shim refuses to cache and
# execs the real bd directly. This is a hard safety boundary, not a
# performance heuristic — caching a write would corrupt state.
#
# CORRECTNESS NOTE (ga-48xcv's own risk callout — read before raising TTL or
# porting a new call site): a cached read is safe for staleness-tolerant
# call sites — liveness probes, input validation, informational listings.
# It is NOT safe, without its own confirming resample, for a call site that
# ITSELF decides to close/supersede/abort/requeue a bead from the result —
# such a call site should either keep TTL very low, use BD_CACHE_FRESH=1 for
# its confirming read, or skip this shim entirely for that one query. Choose
# TTL per call site; do not copy-paste a TTL choice city-wide.
#
# Env knobs:
#   BD_CACHE_TTL             seconds a cache entry stays fresh   (default 5 —
#                            shorter than gc-session-list-cached's 8s: bd data
#                            (labels/status) changes faster than session
#                            liveness and often feeds closer decisions)
#   BD_CACHE_DIR             cache location            (default $GC_CITY/.gc/cache/bd-list)
#   BD_CACHE_OFF=1           kill switch — always go live, never cache (instant rollback)
#   BD_CACHE_FRESH=1         force one live read + refresh (bypass, like --fresh)
#   BD_CACHE_LOCK_STALE_SEC  steal a lock older than this        (default 30)
#   BD_BIN                   the bd binary/command to invoke     (default: bd)
#
# Usage:
#   bd-list-cached.sh <bd args...>     # cached when list/show/query, live otherwise
#   bd-list-cached.sh --selftest       # run the offline self-test
set -uo pipefail

TTL="${BD_CACHE_TTL:-5}"
CITY="${GC_CITY:-$HOME/gt/.gascity-gastown-hq}"
CACHE_DIR="${BD_CACHE_DIR:-$CITY/.gc/cache/bd-list}"
LOCK_STALE_SEC="${BD_CACHE_LOCK_STALE_SEC:-30}"
BD_BIN="${BD_BIN:-bd}"

_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
_now()   { date +%s; }

# Only list|show|query are read-only+cacheable. Scans argv for the first
# non-flag token; -C/--city are the only recognized flags that consume a
# following value (matches every real call site in this codebase). Any other
# leading flag, or a first non-flag token that isn't list/show/query, bails
# out non-cacheable — conservative by construction, never guesses.
_cacheable_subcommand() {
  local i=1 n=$# a
  while [ "$i" -le "$n" ]; do
    a="${!i}"
    case "$a" in
      -C|--city) i=$((i + 1)) ;;          # skip flag + its value
      -*) return 1 ;;                      # unrecognized leading flag — refuse to guess
      list|show|query) return 0 ;;
      *) return 1 ;;
    esac
    i=$((i + 1))
  done
  return 1
}

# Stable, order-sensitive cache key over the full argv (different arg order
# is a different bd invocation and must not share a cache slot).
_cache_key() {
  { printf '%s\0' "$@" | shasum -a 1 2>/dev/null | cut -d' ' -f1; } \
    || { printf '%s\0' "$@" | md5 -q 2>/dev/null; } \
    || { printf '%s\0' "$@" | md5sum 2>/dev/null | cut -d' ' -f1; } \
    || { printf '%s\0' "$@" | cksum | cut -d' ' -f1; }
}

_cache_age() {
  local f="$1"
  [ -f "$f" ] || { echo 999999; return; }
  echo $(( $(_now) - $(_mtime "$f") ))
}

# stdin → exit 0 iff it is valid JSON and an array (bd list/show/query's shape).
_valid_json_array() {
  python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    sys.exit(0 if isinstance(d, list) else 1)
except Exception:
    sys.exit(1)' 2>/dev/null
}

# Cheap structural sanity for the hot cache-hit path — no python tax. bd's
# JSON output is an array, so a valid cache starts with '['.
_cache_looks_valid() {
  local f="$1"
  [ -f "$f" ] || return 1
  [ "$(head -c 1 "$f" 2>/dev/null)" = "[" ]
}

# Serve $1 iff it passes the sanity check; a corrupt cache is dropped so the
# caller falls through to a live refresh (never serve garbage).
_serve_cache() {
  local f="$1"
  if _cache_looks_valid "$f"; then cat "$f" 2>/dev/null && exit 0; fi
  rm -f "$f" 2>/dev/null
  return 1
}

# Publish $2 to cache file $1 atomically iff it validates. Returns 0 if published.
_publish() {
  local f="$1" out="$2" tmp
  printf '%s' "$out" | _valid_json_array || return 1
  tmp="$f.tmp.$$"
  printf '%s' "$out" > "$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

_live() { "$BD_BIN" "$@" 2>/dev/null; }

# Live-read → publish-on-success → print; fail-open to cache; else raw passthrough.
_refresh_and_emit() {
  local cache="$1"; shift
  local out rc
  out="$(_live "$@")"; rc=$?
  if [ $rc -eq 0 ] && _publish "$cache" "$out"; then
    printf '%s\n' "$out"; exit 0
  fi
  [ -f "$cache" ] && _serve_cache "$cache"        # fail-open: last-good beats empty
  printf '%s\n' "$out"; exit $rc                  # no cache → behave exactly like bd
}

_try_lock() {
  local lockdir="$1"
  if mkdir "$lockdir" 2>/dev/null; then return 0; fi
  local age; age=$(( $(_now) - $(_mtime "$lockdir") ))
  if [ "$age" -ge "$LOCK_STALE_SEC" ]; then
    rmdir "$lockdir" 2>/dev/null || true
    mkdir "$lockdir" 2>/dev/null && return 0
  fi
  return 1
}
_unlock() { rmdir "$1" 2>/dev/null || true; }

# ── self-test (offline unit tests + one end-to-end passthrough/cache check) ──
if [ "${1:-}" = "--selftest" ]; then
  pass=0; fail=0
  ok(){ pass=$((pass+1)); echo "  ✓ $1"; }
  bad(){ fail=$((fail+1)); echo "  ✗ $1"; }
  bash -n "$0" && ok "syntax valid" || bad "syntax error"

  TMP="$(mktemp -d)"
  CACHE="$TMP/q1.json"

  # subcommand classifier
  _cacheable_subcommand -C /some/city list --json && ok "list is cacheable" || bad "list misclassified"
  _cacheable_subcommand -C /some/city show ga-1 --json && ok "show is cacheable" || bad "show misclassified"
  _cacheable_subcommand query 'x=y' && ok "query (no -C) is cacheable" || bad "query misclassified"
  _cacheable_subcommand -C /some/city close ga-1 && bad "close misclassified as cacheable" || ok "close correctly refused"
  _cacheable_subcommand -C /some/city comment ga-1 "hi" && bad "comment misclassified as cacheable" || ok "comment correctly refused"
  _cacheable_subcommand --weird-flag list && bad "unrecognized leading flag guessed cacheable" || ok "unrecognized leading flag refused (safe default)"
  _cacheable_subcommand && bad "empty argv misclassified as cacheable" || ok "empty argv correctly refused"

  # cache-key stability: same argv → same key; different argv → different key
  K1=$(_cache_key -C /city list --json -l foo)
  K2=$(_cache_key -C /city list --json -l foo)
  K3=$(_cache_key -C /city list --json -l bar)
  [ "$K1" = "$K2" ] && ok "same argv -> same key" || bad "same argv produced different keys"
  [ "$K1" != "$K3" ] && ok "different argv -> different key" || bad "different argv collided"

  # validator accepts arrays, rejects junk / wrong-shape (object) / empty
  echo '[]'                 | _valid_json_array && ok "validator accepts []" || bad "validator rejected []"
  echo '[{"id":"a"}]'       | _valid_json_array && ok "validator accepts populated array" || bad "validator rejected populated"
  echo 'not json'           | _valid_json_array && bad "validator accepted junk" || ok "validator rejects junk"
  echo '{"id":"a"}'         | _valid_json_array && bad "validator accepted object" || ok "validator rejects object (bd show's un-listed shape)"
  echo -n ''                | _valid_json_array && bad "validator accepted empty" || ok "validator rejects empty"

  # _publish writes atomically only on valid input
  _publish "$CACHE" '[{"id":"a"}]' && [ -f "$CACHE" ] && ok "_publish wrote valid cache" || bad "_publish failed on valid"
  grep -q '"a"' "$CACHE" && ok "cache content correct" || bad "cache content wrong"
  _publish "$CACHE" 'garbage' && bad "_publish wrote junk" || ok "_publish refused junk"
  grep -q '"a"' "$CACHE" && ok "prior cache intact after refused junk" || bad "junk clobbered good cache"
  [ -z "$(ls "$CACHE".tmp.* 2>/dev/null)" ] && ok "no leftover temp files" || bad "temp file leaked"

  # lock: acquire, re-acquire blocked, steal-when-stale (per-key lockdir)
  LOCKDIR="$TMP/q1.lock.d"
  _try_lock "$LOCKDIR" && ok "lock acquired" || bad "lock not acquired"
  ( _try_lock "$LOCKDIR" ) && bad "second lock acquired (should block)" || ok "second lock blocked while held"
  touch -t 200001010000 "$LOCKDIR" 2>/dev/null
  _try_lock "$LOCKDIR" && ok "stale lock stolen" || bad "stale lock not stolen"
  _unlock "$LOCKDIR"; [ ! -d "$LOCKDIR" ] && ok "unlock removes lockdir" || bad "unlock left lockdir"

  # serving boundary: corrupt / wrong-shape cache is not served and is dropped
  printf '%s' '[{"id":"x"}]' > "$CACHE"
  _cache_looks_valid "$CACHE" && ok "valid cache passes sanity check" || bad "valid cache failed sanity"
  printf '%s' 'CORRUPT[[[' > "$CACHE"
  _cache_looks_valid "$CACHE" && bad "corrupt cache passed sanity check" || ok "corrupt cache fails sanity check"
  ( _serve_cache "$CACHE" ); [ ! -f "$CACHE" ] && ok "_serve_cache dropped corrupt cache" || bad "corrupt cache not dropped"
  printf '%s' '{"other":1}' > "$CACHE"
  _cache_looks_valid "$CACHE" && bad "object-shaped cache passed sanity" || ok "object-shaped cache fails sanity"

  # end-to-end: stub `bd`, verify (a) cache collapses N calls into 1 within TTL,
  # (b) a non-cacheable subcommand always passes through live, uncached.
  STUBDIR="$TMP/stubbin"; mkdir -p "$STUBDIR"
  CALLLOG="$TMP/calls.log"; : > "$CALLLOG"
  cat > "$STUBDIR/bd" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$CALLLOG"
if [ "\$1" = "close" ]; then echo "closed"; exit 0; fi
echo '[{"id":"stub-1"}]'
STUB
  chmod +x "$STUBDIR/bd"

  E2E_DIR="$TMP/e2e-cache"; mkdir -p "$E2E_DIR"
  run_shim() { PATH="$STUBDIR:$PATH" BD_CACHE_DIR="$E2E_DIR" BD_CACHE_TTL=60 bash "$0" "$@"; }

  : > "$CALLLOG"
  run_shim -C testcity list --json -l foo >/dev/null
  run_shim -C testcity list --json -l foo >/dev/null
  run_shim -C testcity list --json -l foo >/dev/null
  CALLS=$(wc -l < "$CALLLOG" | tr -d ' ')
  [ "$CALLS" = "1" ] && ok "3 identical cacheable calls within TTL -> 1 live bd invocation" \
    || bad "expected 1 live invocation for 3 identical calls, got $CALLS"

  : > "$CALLLOG"
  run_shim -C testcity close ga-1 >/dev/null
  run_shim -C testcity close ga-1 >/dev/null
  CALLS=$(wc -l < "$CALLLOG" | tr -d ' ')
  [ "$CALLS" = "2" ] && ok "non-cacheable subcommand always passes through live (2 calls -> 2 invocations)" \
    || bad "expected 2 live invocations for 2 close calls, got $CALLS"

  BD_CACHE_OFF=1 run_shim -C testcity list --json -l foo >/dev/null
  BD_CACHE_OFF=1 run_shim -C testcity list --json -l foo >/dev/null
  CALLS=$(wc -l < "$CALLLOG" | tr -d ' ')
  [ "$CALLS" = "4" ] && ok "BD_CACHE_OFF=1 kill switch bypasses cache" \
    || bad "expected kill switch to force 2 more live calls, got $CALLS total"

  rm -rf "$TMP"
  echo "bd-list-cached selftest: PASS=$pass FAIL=$fail"
  [ "$fail" -eq 0 ]; exit $?
fi

# ── main ───────────────────────────────────────────────────────────────────────
mkdir -p "$CACHE_DIR" 2>/dev/null || true

if ! _cacheable_subcommand "$@"; then
  # Not list/show/query (or an unrecognized leading flag) — never cache a
  # write, and never guess. Exec the real bd directly, unchanged.
  exec "$BD_BIN" "$@"
fi

KEY=$(_cache_key "$@")
CACHE="$CACHE_DIR/$KEY.json"
LOCKDIR="$CACHE_DIR/$KEY.lock.d"

if [ "${BD_CACHE_OFF:-0}" = "1" ] || [ "${BD_CACHE_FRESH:-0}" = "1" ]; then
  _refresh_and_emit "$CACHE" "$@"
fi

# fast path: a fresh-enough cache serves without touching Dolt (the common case)
if [ "$(_cache_age "$CACHE")" -lt "$TTL" ]; then
  _serve_cache "$CACHE"
fi

# stale/absent → become the single refresher for THIS key, or ride someone else's
if _try_lock "$LOCKDIR"; then
  trap '_unlock "$LOCKDIR"' EXIT
  if [ "$(_cache_age "$CACHE")" -lt "$TTL" ]; then _serve_cache "$CACHE"; fi
  _refresh_and_emit "$CACHE" "$@"
else
  [ -f "$CACHE" ] && _serve_cache "$CACHE"
  i=0; while [ "$i" -lt $(( TTL * 4 )) ]; do
    sleep 0.25; i=$(( i + 1 ))
    [ -f "$CACHE" ] && _serve_cache "$CACHE"
  done
  _live "$@"                                    # last resort: refresher never produced
fi
